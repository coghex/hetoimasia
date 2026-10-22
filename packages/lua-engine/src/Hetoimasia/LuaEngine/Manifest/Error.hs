-- | The refusals of the manifest parser: every one is a plain value that names
-- what was refused and where, in bounded text.
--
-- __Ownership.__ This module holds only data. Nothing here prints, exits or
-- performs IO. Every offending string a refusal carries is an 'Excerpt', cut
-- to 'excerptLimit' code points, so a refusal's size never grows with the
-- manifest's: a path has at most eight segments (the nesting bound), and each
-- key segment is an excerpt.
module Hetoimasia.LuaEngine.Manifest.Error
  ( -- * Bounded text
    Excerpt (..)
  , excerptLimit
  , excerptOf

    -- * Locations
  , PathSegment (..)
  , FieldPath

    -- * Refusals
  , ManifestError (..)
  , SyntaxError (..)
  , SchemaError (..)
  , ValueKind (..)
  , ExpectedType (..)
  , IdProblem (..)
  , TickProblem (..)
  , Role (..)
  ) where

import Data.Text (Text)
import qualified Data.Text as Text

-- | Offending text, cut to at most 'excerptLimit' code points.
data Excerpt = Excerpt
  { excerptText ∷ !Text
    -- ^ The first code points of the text.
  , excerptTruncated ∷ !Bool
    -- ^ Whether more followed.
  }
  deriving (Eq, Show)

-- | The most code points an 'Excerpt' keeps.
excerptLimit ∷ Int
excerptLimit = 64

-- | The excerpt of a text.
excerptOf ∷ Text → Excerpt
excerptOf text =
  Excerpt
    { excerptText = Text.take excerptLimit text
    , excerptTruncated = Text.compareLength text excerptLimit == GT
    }

-- | One step into a document.
data PathSegment
  = PathKey !Excerpt
    -- ^ An object member.
  | PathIndex !Int
    -- ^ An array element, from zero.
  deriving (Eq, Show)

-- | Where in the document, outermost first. At most eight segments long.
type FieldPath = [PathSegment]

-- | The roles a manifest can select. Only these two exist in M1.
data Role = Gameplay | Presentation
  deriving (Eq, Ord, Show, Bounded, Enum)

-- | Why a manifest was refused, in the order the checks run: the byte limit,
-- then the whole document's syntax, then its schema.
data ManifestError
  = ManifestTooLarge !Int !Int
    -- ^ The bytes supplied and the limit.
  | ManifestSyntax !SyntaxError
  | ManifestSchema !SchemaError
  deriving (Eq, Show)

-- | A refusal of the document's syntax. Offsets are byte offsets into the
-- supplied bytes.
data SyntaxError
  = InvalidUtf8
    -- ^ The bytes are not well-formed UTF-8.
  | ByteOrderMark
    -- ^ The document begins with a UTF-8 byte order mark.
  | UnexpectedEnd !Int
    -- ^ The input ended inside the document (or held nothing).
  | UnexpectedByte !Int !Int
    -- ^ The byte value at the offset cannot continue the document there.
  | RootNotObject !Int
    -- ^ The first significant byte, at the offset, does not begin an object.
  | ControlCharacter !Int
    -- ^ An unescaped U+0000 to U+001F inside a string.
  | InvalidEscape !Int
    -- ^ A backslash escape that is not one of the eight, or a @\\u@ without
    -- four hexadecimal digits.
  | UnpairedSurrogate !Int
    -- ^ A @\\u@ escape of a surrogate that is not half of a high-then-low pair.
  | InvalidNumber !Int
    -- ^ A number that is not RFC 8259's grammar.
  | NestingTooDeep !Int
    -- ^ A container opened at the offset deeper than the profile allows.
  | DuplicateKey !FieldPath !Excerpt
    -- ^ The object at the path has the key twice after escape decoding.
  | TrailingData !Int
    -- ^ Something other than whitespace follows the object.
  deriving (Eq, Show)

-- | A refusal of the schema, found only in a syntactically valid document.
-- Fields are checked in a fixed order (unknown fields first, then @format@,
-- @id@, @entry@, @vms@, @tick_seconds@) and unknown keys are chosen by the
-- least decoded key, so member order never changes which refusal is returned.
data SchemaError
  = UnknownField !FieldPath !Excerpt
    -- ^ The object at the path has a field the schema does not define.
  | MissingField !FieldPath
    -- ^ A required field, named by its full path, is absent.
  | NullValue !FieldPath
    -- ^ The field at the path is @null@.
  | WrongType !FieldPath !ExpectedType !ValueKind
    -- ^ The field at the path has another kind of value.
  | UnsupportedFormat
    -- ^ @format@ is a number whose exact value is not 1.
  | InvalidId !IdProblem
  | EmptyVms
    -- ^ @vms@ is an empty array.
  | TooManyVms !Int
    -- ^ @vms@ has more than the two role declarations; the count is given.
  | UnknownRole !FieldPath !Excerpt
    -- ^ A role other than @gameplay@ and @presentation@.
  | UnknownClock !FieldPath !Excerpt
    -- ^ A clock other than @logical@ and @elapsed@.
  | ClockMismatch !Role !Int
    -- ^ The declaration at the index gives the role the other role's clock.
  | DuplicateRole !Role !Int
    -- ^ The declaration at the index repeats an earlier declaration's role.
  | MissingEntry !Role
    -- ^ The role has neither an explicit entry nor a common one to fall back on.
  | TickRequired
    -- ^ Gameplay is present and @tick_seconds@ is absent.
  | TickForbidden
    -- ^ Only presentation is present and @tick_seconds@ is given.
  | InvalidTick !TickProblem
  deriving (Eq, Show)

-- | The kind of a value, as a refusal reports it.
data ValueKind
  = KindNull
  | KindBool
  | KindNumber
  | KindString
  | KindArray
  | KindObject
  deriving (Eq, Show)

-- | The kind of value a field requires.
data ExpectedType
  = ExpectedNumber
  | ExpectedString
  | ExpectedArray
  | ExpectedObject
  deriving (Eq, Show)

-- | Why an @id@ was refused. Checked in this order.
data IdProblem
  = IdEmpty
  | IdTooLong !Int
    -- ^ More than 64 characters; the length is given.
  | IdBadCharacter !Int
    -- ^ The first character, at the code-point index, outside @[a-z]@ at the
    -- start or @[a-z0-9_-]@ afterwards.
  deriving (Eq, Show)

-- | Why @tick_seconds@ was refused.
data TickProblem
  = TickEmpty
  | TickNoLeadingDigit
    -- ^ The text begins with the decimal point.
  | TickBadCharacter !Int
    -- ^ The first character, at the code-point index, that the grammar does
    -- not allow there: a sign, a space, an exponent, a second point, anything
    -- not an ASCII digit.
  | TickFractionEmpty
    -- ^ A decimal point with no digit after it.
  | TickFractionTooLong !Int
    -- ^ More than nine fraction digits; the count is given.
  | TickZero
  | TickAboveMaximum
    -- ^ More than 2^64 − 1 nanoseconds, or the profile's smaller maximum.
  deriving (Eq, Show)
