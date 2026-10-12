-- | A pure reader for a target's readback.
--
-- A readback is the target's level 0, tightly packed, rows top first, in the
-- target's own format and with no conversion: four bytes a pixel, and for a
-- @B8G8R8A8@ format the blue byte first. 'readPixel' returns the pixel at a
-- coordinate in red, green, blue, alpha order, swizzling a blue-first format
-- and leaving every byte, an sRGB-encoded one included, as stored.
--
-- A readback that is not exactly @width × height × 4@ bytes, or a coordinate
-- outside the extent, is a fault and never a pixel. The size is compared in
-- 'Integer', so no extent can wrap it.
--
-- __Dependencies.__ @base@, @bytestring@ and @hetoimasia-render-2d@ for the
-- pixel extent.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Oracle.Readback
  ( ReadbackFault (..)
  , readPixel
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Unsafe as ByteString
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..))
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat, Rgba8 (..), formatIsBgra)

-- | Why a readback has no pixel at a coordinate.
data ReadbackFault
  = -- | An extent with a negative width or height.
    ReadbackExtentInvalid
  | -- | A readback that does not hold exactly the bytes its extent needs: the
    -- bytes needed, then the bytes supplied.
    ReadbackSizeWrong !Integer !Int
  | -- | A pixel outside the extent.
    ReadbackPixelOutside !Int !Int
  deriving stock (Eq, Show)

-- | The pixel at a column and row of a tightly packed readback of this format
-- and extent.
readPixel ∷ ColourFormat → PixelExtent → ByteString → Int → Int → Either ReadbackFault Rgba8
readPixel format (PixelExtent width height) bytes x y
  | width < 0 || height < 0 = Left ReadbackExtentInvalid
  | needed /= toInteger (ByteString.length bytes) = Left (ReadbackSizeWrong needed (ByteString.length bytes))
  | x < 0 || y < 0 || x >= width || y >= height = Left (ReadbackPixelOutside x y)
  | formatIsBgra format = Right (Rgba8 (byte 2) (byte 1) (byte 0) (byte 3))
  | otherwise = Right (Rgba8 (byte 0) (byte 1) (byte 2) (byte 3))
  where
    needed = toInteger width * toInteger height * 4
    offset = (y * width + x) * 4
    byte n = ByteString.unsafeIndex bytes (offset + n)
