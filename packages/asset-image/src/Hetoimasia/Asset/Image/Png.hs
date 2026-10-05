-- | PNG decoding into one upload-ready RGBA8 level.
--
-- Every PNG JuicyPixels reads decodes here — greyscale, greyscale with alpha,
-- palette (with @tRNS@ alpha), RGB and RGBA, at every bit depth, interlaced or
-- not — into one level at the image's width and height, tightly packed, top
-- row first. The caller's 'ImageKind' decides the colour space; the file's
-- colour-space chunks (@gAMA@, @cHRM@, @sRGB@, @iCCP@) never change a texel.
--
-- * 'ColourImage' yields 'TexelRgba8Srgb': each colour channel decoded to
--   linear light, multiplied by alpha ÷ 255, re-encoded and rounded to
--   nearest. Alpha is unchanged.
-- * 'DataImage' yields 'TexelRgba8Linear', with texels exactly as decoded.
--
-- A greyscale or truecolour image's @tRNS@ colour key is honoured: a texel
-- whose stored samples exactly equal the key, compared at the file's own bit
-- depth (1, 2, 4, 8 or 16) before any reduction, has alpha 0, and every other
-- texel alpha 255. Any other missing alpha channel becomes 255. 16-bit
-- components, alpha included, are then rounded to the nearest 8-bit value. Either kind
-- carries whether the level's alpha is binary.
module Hetoimasia.Asset.Image.Png
  ( pngDecoder
  , decodePng
  )
where

import Codec.Picture.Png (decodePngWithPaletteAndMetadata)
import Codec.Picture.Png.Internal.Type (PngIHdr (colourType))
import Control.DeepSeq (force)
import Control.Exception (SomeAsyncException, SomeException, displayException, evaluate, fromException, throwTo, try)
import Control.Concurrent (myThreadId)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Asset (Asset, AssetRefusal (..), Decoder (..))
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (..), TexelFormat (..))
import Hetoimasia.Asset.Image.Internal.PngStructure (checkStructure)
import Hetoimasia.Asset.Image.Internal.Texels (binaryAlpha, rgba8Level)
import System.IO.Unsafe (unsafePerformIO)

-- | The PNG codec for one kind of image.
pngDecoder ∷ ImageKind → Decoder DecodedImage
pngDecoder kind = Decoder (decodePng kind)

-- | Decode a PNG's bytes as the given kind, or refuse them naming the asset.
-- The result is fully evaluated: no exception escapes, and a refusal never
-- comes with part of an image.
decodePng ∷ ImageKind → Asset → ByteString → Either AssetRefusal DecodedImage
decodePng kind asset bytes = either (Left . AssetRefusal asset) Right (contained (decode kind bytes))

decode ∷ ImageKind → ByteString → Either Text DecodedImage
decode kind bytes = do
  (ihdr, key) ← checkStructure bytes
  (paletted, _) ← either (Left . ("JuicyPixels cannot decode the PNG: " <>) . Text.pack) Right (decodePngWithPaletteAndMetadata bytes)
  (w, h, texels) ← rgba8Level kind (colourType ihdr) key paletted
  Right
    DecodedImage
      { decodedFormat = case kind of
          ColourImage → TexelRgba8Srgb
          DataImage → TexelRgba8Linear
      , decodedWidth = fromIntegral w
      , decodedHeight = fromIntegral h
      , decodedLevels = [texels]
      , decodedBinaryAlpha = binaryAlpha texels
      }

-- | The result fully evaluated, with any synchronous exception that
-- evaluating it throws turned into a refusal. JuicyPixels inflates lazily and
-- reports some failures by throwing from pure code; none of them may escape.
--
-- An asynchronous exception is not the decoder's to absorb. It is re-raised
-- asynchronously at this thread, so the suspended evaluation resumes, rather
-- than being cached as this value's result, if the value is demanded again.
contained ∷ Either Text DecodedImage → Either Text DecodedImage
contained value = unsafePerformIO attempt
  where
    attempt =
      try (evaluate (force value)) >>= \case
        Right result → pure result
        Left (failure ∷ SomeException)
          | Just (_ ∷ SomeAsyncException) ← fromException failure → do
              self ← myThreadId
              throwTo self failure
              attempt
          | otherwise → pure (Left ("decoding failed: " <> Text.pack (displayException failure)))
{-# NOINLINE contained #-}
