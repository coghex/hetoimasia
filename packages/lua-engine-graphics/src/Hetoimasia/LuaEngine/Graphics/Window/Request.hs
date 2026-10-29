-- | What a window request asks for, and the checks made of it before anything native happens (LFE-18).
--
-- The agreed call is @api.window.open({title = TEXT, width = INTEGER, height = INTEGER})@; every field
-- is required, and there is no optional flag and no tick offset. The eventual binding (LFE-21) owns the
-- exact Lua table traversal and hands this module the three typed values; this module owns the
-- bounds, so that the service refuses a bad request as an ordinary error before it reserves a bank,
-- issues a command or touches a native object.
--
-- = The rules
--
-- * /Title/: valid UTF-8, at most 'titleBytesLimit' bytes /encoded/, and no Unicode general category
--   @Cc@ character (U+0000 to U+001F, U+007F and U+0080 to U+009F). The UTF-8 check comes first, the
--   control check second, so the control rule is decided over decoded characters and never over a byte
--   of a multibyte sequence. The empty title is allowed.
-- * /Width and height/: whole values from 'dimensionMinimum' to 'dimensionMaximum' in native window
--   screen-coordinate units. They are preferences, never observations of an actual logical or
--   framebuffer size. They arrive as the Lua integer subtype ('Int64'): an integral float such as
--   @640.0@ is refused by the binding, which is where @1.0@ is refused where an integer is declared.
--   Conversion to the host's @Int@ is checked and never wraps or clamps: a value outside the range is
--   refused whole, whatever the machine's integer width.
--
-- The host's own configuration check rejects only a NUL title (@Config.hs@); the stricter rule here is
-- the adapter's, so every control character is refused before a command exists.
module Hetoimasia.LuaEngine.Graphics.Window.Request
  ( -- * The request
    WindowRequest
  , requestTitle
  , requestWidth
  , requestHeight
  , windowRequest

    -- * Why a request is refused
  , RequestRefusal (..)
  , refusalText

    -- * The bounds
  , titleBytesLimit
  , dimensionMinimum
  , dimensionMaximum
  , isControl
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding

-- | A request the service can act on: a title already known to be valid and a size already known to
-- be in range. The constructor is not exported, so a value of this type is its own proof.
data WindowRequest = WindowRequest
  { requestTitle ∷ !Text
  , requestWidth ∷ !Int
  , requestHeight ∷ !Int
  }
  deriving (Eq, Show)

-- | Why a request cannot be made. Every one is an ordinary refusal before any action.
data RequestRefusal
  = -- | The title is not valid UTF-8.
    TitleNotUtf8
  | -- | The encoded title is longer than 'titleBytesLimit'.
    TitleTooLong !Int
  | -- | The title has a Unicode @Cc@ character, at this character position.
    TitleControl !Int
  | -- | The width is outside 'dimensionMinimum' to 'dimensionMaximum'.
    WidthOutOfRange !Int64
  | -- | The height is outside the same range.
    HeightOutOfRange !Int64
  deriving (Eq, Show)

-- | The longest title, in encoded UTF-8 bytes.
titleBytesLimit ∷ Int
titleBytesLimit = 512

-- | The smallest width or height, in native window screen-coordinate units.
dimensionMinimum ∷ Int64
dimensionMinimum = 1

-- | The largest width or height, in native window screen-coordinate units.
dimensionMaximum ∷ Int64
dimensionMaximum = 4096

-- | Make a request from the three values a binding hands over. The checks run in a fixed order, the
-- title's length and encoding first, so which refusal a request with several faults meets does not
-- depend on how the caller built it.
windowRequest ∷ ByteString → Int64 → Int64 → Either RequestRefusal WindowRequest
windowRequest titleBytes width height = do
  title ← checkTitle titleBytes
  checkedWidth ← dimension WidthOutOfRange width
  checkedHeight ← dimension HeightOutOfRange height
  Right (WindowRequest title checkedWidth checkedHeight)

checkTitle ∷ ByteString → Either RequestRefusal Text
checkTitle bytes
  | ByteString.length bytes > titleBytesLimit = Left (TitleTooLong (ByteString.length bytes))
  | otherwise = case Encoding.decodeUtf8' bytes of
      Left _ → Left TitleNotUtf8
      Right title → case [position | (position, character) ← zip [0 ..] (Text.unpack title), isControl character] of
        position : _ → Left (TitleControl position)
        [] → Right title

-- | Unicode general category @Cc@: U+0000 to U+001F, U+007F, U+0080 to U+009F.
isControl ∷ Char → Bool
isControl character = code <= 0x1F || (code >= 0x7F && code <= 0x9F)
  where
    code = fromEnum character

-- The width and height are compared as 'Int64' before any narrowing, so a value beyond 'Int' on a
-- narrower machine, or beyond Int32 or Int64, is refused rather than wrapped.
dimension ∷ (Int64 → RequestRefusal) → Int64 → Either RequestRefusal Int
dimension refusal value
  | value < dimensionMinimum || value > dimensionMaximum = Left (refusal value)
  | otherwise = Right (fromIntegral value)

-- | The refusal as bounded text for an ordinary Lua error. It names the field and the rule, and
-- never echoes the title.
refusalText ∷ RequestRefusal → Text
refusalText = \case
  TitleNotUtf8 → "window title is not valid UTF-8"
  TitleTooLong _ → "window title is longer than " <> Text.pack (show titleBytesLimit) <> " bytes"
  TitleControl _ → "window title has a control character"
  WidthOutOfRange _ → "window width must be a whole value from " <> range
  HeightOutOfRange _ → "window height must be a whole value from " <> range
  where
    range = Text.pack (show dimensionMinimum) <> " to " <> Text.pack (show dimensionMaximum)
