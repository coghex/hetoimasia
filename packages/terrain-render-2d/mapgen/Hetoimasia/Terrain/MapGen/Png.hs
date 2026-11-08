-- | The repository's pinned PNG encoder path for the generated maps (TRA-14).
--
-- Bytes are produced only by JuicyPixels' 'encodePng', whose deflate runs
-- through the @zlib@ package. The project forces that package to
-- @+bundled-c-zlib -pkg-config@ (cabal.project.common), so the compressed
-- stream, and with it every committed hash, is the same on Linux CI and macOS.
-- No host libz and no external image tool is involved.
--
-- State, ownership and lifetime: none. Pure.
module Hetoimasia.Terrain.MapGen.Png
  ( encodeRgba
  , decodeRgba
  ) where

import Codec.Picture (DynamicImage (..), Image (..), PixelRGBA8 (..), decodePng, encodePng, generateImage, pixelAt)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy

-- | An RGBA8 canvas of the given size, top row first, as PNG bytes.
encodeRgba ∷ Int → Int → ByteString → ByteString
encodeRgba width height bytes = Lazy.toStrict (encodePng image)
  where
    image = generateImage texel width height
    texel x y =
      let base = 4 * (y * width + x)
       in PixelRGBA8 (at base) (at (base + 1)) (at (base + 2)) (at (base + 3))
    at = ByteString.index bytes

-- | The size and RGBA8 texels of a PNG, top row first, or why it is not an
-- 8-bit RGBA PNG.
decodeRgba ∷ ByteString → Either String (Int, Int, ByteString)
decodeRgba png = case decodePng png of
  Left why → Left why
  Right (ImageRGBA8 image) →
    Right
      ( imageWidth image
      , imageHeight image
      , ByteString.pack
          [ channel
          | y ← [0 .. imageHeight image - 1]
          , x ← [0 .. imageWidth image - 1]
          , let PixelRGBA8 r g b a = pixelAt image x y
          , channel ← [r, g, b, a]
          ]
      )
  Right _ → Left "not an 8-bit RGBA PNG"
