-- | The values the content identity policy is made of: the narrow limits a
-- caller supplies, the bounded root value a key is scoped by, the checked
-- logical path, and the structured refusals.
--
-- Everything here is immutable data owned by whoever holds it. Nothing is
-- shared, cached or registered, and nothing prints. The constructors of the
-- checked values ('IdentityLimits', 'RootKey', 'LogicalPath') are exported by
-- this internal module only; the public "Hetoimasia.Content.Identity" module
-- exposes them abstractly, so a client can build one only through the check
-- that guards it.
module Hetoimasia.Content.Internal.Identity.Types
  ( -- * Limits
    IdentityLimits (..)
  , identityLimits
  , LimitName (..)
  , LimitsRefusal (..)

    -- * The root value
  , RootKey (..)
  , rootKey
  , rootKeyBytes
  , maxRootKeyBytes
  , RootKeyRefusal (..)

    -- * Logical paths
  , LogicalPath (..)
  , ContentKey (..)
  , logicalPathBytes
  , logicalPathSegments

    -- * Bounded diagnostics
  , Excerpt (..)
  , excerpt
  , excerptOfPath
  , excerptCap
  , renderExcerpt

    -- * Reference refusals
  , ReferenceRefusal (..)
  , ReferenceReason (..)
  , SegmentProblem (..)
  , Forbidden (..)
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.List.NonEmpty (NonEmpty)
import Hetoimasia.Content.Internal.Types (maxNameBytes, renderBytes)

-- | The path and count bounds a caller narrows the policy with.
--
-- The M1 assembly passes the approved profile's numbers (1,024 bytes per
-- relative path, 255 per segment, 32 segments); this package holds no such
-- default of its own. The constructor is exported by this internal module only.
data IdentityLimits = IdentityLimits
  { limitPathBytes ∷ !Int
  -- ^ The most UTF-8 bytes a whole relative path may have, separators included.
  , limitSegmentBytes ∷ !Int
  -- ^ The most UTF-8 bytes one segment may have.
  , limitSegments ∷ !Int
  -- ^ The most segments a relative path may have.
  , limitEntries ∷ !Int
  -- ^ The most inventory entries a mapping accepts.
  }
  deriving (Eq, Show)

-- | The limit a 'LimitsRefusal' names.
data LimitName = PathBytes | SegmentBytes | Segments | Entries
  deriving (Eq, Show)

-- | Why a set of limits is not usable.
data LimitsRefusal
  = LimitNotPositive !LimitName !Int
  | -- | A segment limit above the path limit, or above the longest native
    -- name the content service accepts.
    SegmentLimitTooLarge !Int !Int
  deriving (Eq, Show)

-- | Checked limits. Path bytes, segment bytes and segments are at least one;
-- entries is at least zero. A segment limit may not exceed the path limit or
-- 'maxNameBytes', the longest native name the content service enumerates, so
-- every accepted segment is a possible native name.
identityLimits ∷ Int → Int → Int → Int → Either LimitsRefusal IdentityLimits
identityLimits pathBytes segmentBytes segments entries
  | pathBytes < 1 = Left (LimitNotPositive PathBytes pathBytes)
  | segmentBytes < 1 = Left (LimitNotPositive SegmentBytes segmentBytes)
  | segments < 1 = Left (LimitNotPositive Segments segments)
  | entries < 0 = Left (LimitNotPositive Entries entries)
  | segmentBytes > min pathBytes maxNameBytes = Left (SegmentLimitTooLarge segmentBytes (min pathBytes maxNameBytes))
  | otherwise = Right (IdentityLimits pathBytes segmentBytes segments entries)

-- | The selected content root, as the caller names it in keys and diagnostics:
-- a bounded, non-empty byte string. It is deliberately not the native root
-- handle, so the pure policy has no native prerequisite; joining the two is the
-- inventory's job.
newtype RootKey = RootKey ByteString
  deriving (Eq, Ord)

-- | Shown escaped and bounded, never decoded.
instance Show RootKey where
  showsPrec _ (RootKey bytes) = showString (renderBytes bytes)

-- | Why a byte string is not a root key.
data RootKeyRefusal = EmptyRootKey | RootKeyTooLong !Int
  deriving (Eq, Show)

-- | The longest root key. It bounds every diagnostic that names a root.
maxRootKeyBytes ∷ Int
maxRootKeyBytes = 128

rootKey ∷ ByteString → Either RootKeyRefusal RootKey
rootKey bytes
  | BS.null bytes = Left EmptyRootKey
  | BS.length bytes > maxRootKeyBytes = Left (RootKeyTooLong (BS.length bytes))
  | otherwise = Right (RootKey (BS.copy bytes))

rootKeyBytes ∷ RootKey → ByteString
rootKeyBytes (RootKey bytes) = bytes

-- | A checked root-relative logical path: the NFC form of a reference that
-- satisfies the grammar, within the limits it was checked against.
--
-- Two paths are equal exactly when their NFC bytes are equal, so case is
-- significant and a composed spelling equals its decomposed spelling.
data LogicalPath = LogicalPath
  { pathBytes ∷ !ByteString
  , pathSegments ∷ !(NonEmpty ByteString)
  }
  deriving (Eq, Ord)

-- | Shown escaped and bounded, never decoded.
instance Show LogicalPath where
  showsPrec _ path = showString (renderBytes (pathBytes path))

-- | The NFC UTF-8 bytes of the path, segments joined by @/@.
logicalPathBytes ∷ LogicalPath → ByteString
logicalPathBytes = pathBytes

-- | The NFC UTF-8 bytes of each segment.
logicalPathSegments ∷ LogicalPath → NonEmpty ByteString
logicalPathSegments = pathSegments

-- | A logical path within its selected root: the complete content key.
-- Paths in different roots are different keys and never override each other.
data ContentKey = ContentKey
  { keyRoot ∷ !RootKey
  , keyPath ∷ !LogicalPath
  }
  deriving (Eq, Ord, Show)

-- | A bounded copy of some bytes for a diagnostic: at most 'excerptCap' bytes
-- copied out, and the length of the whole. It owns its memory, so a refusal
-- never keeps an arbitrarily large rejected input alive.
data Excerpt = Excerpt
  { excerptBytes ∷ !ByteString
  , excerptLength ∷ !Int
  }
  deriving (Eq, Ord)

-- | Shown escaped, with the length of the whole when it was cut.
instance Show Excerpt where
  showsPrec _ = showString . renderExcerpt

-- | The most bytes an 'Excerpt' keeps.
excerptCap ∷ Int
excerptCap = 64

excerpt ∷ ByteString → Excerpt
excerpt bytes = Excerpt (BS.copy (BS.take excerptCap bytes)) (BS.length bytes)

-- | The excerpt of the path the components spell, joined by @/@, without
-- joining more than the excerpt keeps. The length is that of the whole and
-- saturates at 'maxBound'.
excerptOfPath ∷ [ByteString] → Excerpt
excerptOfPath components = Excerpt (BS.copy (BS.take excerptCap (BS.intercalate "/" (takeEnough excerptCap components)))) total
  where
    total = case components of
      [] → 0
      _ → foldr (\c acc → saturatingAdd (BS.length c) (saturatingAdd 1 acc)) 0 components - 1
    takeEnough _ [] = []
    takeEnough budget (c : rest)
      | budget <= 0 = []
      | otherwise = c : takeEnough (budget - BS.length c - 1) rest
    saturatingAdd a b = let s = a + b in if s < a then maxBound else s

renderExcerpt ∷ Excerpt → String
renderExcerpt (Excerpt bytes total) =
  renderBytes bytes <> (if total > BS.length bytes then " (" <> show total <> " bytes)" else "")

-- | A reference the policy refused: the root it was meant for, a bounded copy
-- of the reference and why. This is an argument error: nothing was looked up
-- and no file system was touched.
data ReferenceRefusal = ReferenceRefusal
  { refusalRoot ∷ !RootKey
  , refusalReference ∷ !Excerpt
  , refusalReason ∷ !ReferenceReason
  }
  deriving (Eq, Show)

-- | Why a reference is refused. Offsets are byte offsets and segment numbers
-- count from zero, in the reference as supplied. The checks run in the order
-- the constructors are listed.
data ReferenceReason
  = EmptyReference
  | -- | Supplied bytes, then the limit.
    ReferenceTooLong !Int !Int
  | -- | Segments counted in the reference, then the limit.
    TooManySegments !Int !Int
  | LeadingSlash
  | TrailingSlash
  | -- | The number of the empty segment between two slashes.
    RepeatedSlash !Int
  | BadSegment !Int !SegmentProblem
  | -- | NFC bytes of the whole path, then the limit.
    NormalizedTooLong !Int !Int
  deriving (Eq, Show)

-- | What is wrong with one segment, shared by references and native names.
-- Offsets are within the segment.
data SegmentProblem
  = -- | Only for a native name: an empty one.
    SegmentEmpty
  | -- | Bytes, then the limit.
    SegmentTooLong !Int !Int
  | -- | Only for a native name: a @/@ inside a component, at this offset.
    SegmentSeparator !Int
  | SegmentDot
  | SegmentDotDot
  | -- | The offset of the first ill-formed UTF-8 sequence.
    SegmentMalformedUtf8 !Int
  | -- | A forbidden character: which kind, its offset and its code point.
    SegmentForbidden !Forbidden !Int !Int
  | -- | NFC bytes, then the limit.
    SegmentNormalizedTooLong !Int !Int
  | -- | The NFC form broke the grammar at this code point. The grammar is
    -- checked on the identity as returned, not assumed to survive
    -- normalization.
    SegmentNormalizedGrammar !Int
  deriving (Eq, Show)

-- | The characters the grammar forbids inside a segment. 'Control' is Unicode
-- General_Category Cc, U+0001..U+001F and U+007F..U+009F; U+0000 is 'Nul'.
-- Format characters, U+2028 and U+2029 and noncharacters stay literal.
data Forbidden = Backslash | Colon | Nul | Control
  deriving (Eq, Show)
