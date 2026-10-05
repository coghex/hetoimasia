-- | Turning what JuicyPixels decodes into one tightly packed RGBA8 level.
--
-- Every PNG colour type and bit depth arrives here as one of JuicyPixels'
-- image or palette types and leaves as four bytes per texel, R, G, B, A, top
-- row first:
--
-- * a greyscale or truecolour image with a @tRNS@ colour key gives alpha 0 to
--   every texel whose stored samples equal the key's, compared at the image's
--   own bit depth before any reduction to 8 bits, and alpha 255 to the rest;
-- * any other missing alpha channel becomes 255;
-- * a 16-bit component, alpha included, becomes nearest(v × 255 ÷ 65535);
-- * a palette index must name an entry of the palette;
-- * a colour image's channels are then premultiplied in linear light, and a
--   data image's are left exactly as decoded.
module Hetoimasia.Asset.Image.Internal.Texels
  ( rgba8Level
  , binaryAlpha
  )
where

import Codec.Picture.Png.Internal.Type (PngImageType (PngGreyscale))
import Hetoimasia.Asset.Image.Internal.PngStructure (ColourKey (..))
import Codec.Picture.Types
  ( DynamicImage (..)
  , Image (imageData, imageHeight, imageWidth)
  , PalettedImage (..)
  , Palette' (_paletteData, _paletteSize)
  , Pixel (PixelBaseComponent)
  , Pixel8
  )
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Internal as ByteString (unsafeCreate)
import qualified Data.ByteString.Unsafe as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector.Storable as Vector
import Data.Word (Word16, Word32, Word8)
import Foreign.Storable (pokeByteOff)
import Hetoimasia.Asset.Image (ImageKind (..))
import Hetoimasia.Asset.Image.Internal.Premultiply (premultiplyChannel)

data Texel = Texel !Word8 !Word8 !Word8 !Word8

-- | The decoded image as one RGBA8 level of the given kind, with its width
-- and height; or the reason it cannot be one. The PNG colour type is the
-- header's, which tells a low-bit greyscale image (that JuicyPixels returns
-- as a palette) from an indexed one; the colour key is the file's, if any.
rgba8Level ∷ ImageKind → PngImageType → Maybe ColourKey → PalettedImage → Either Text (Int, Int, ByteString)
rgba8Level kind colourType key = \case
  TrueColorImage dynamic → case dynamic of
    ImageY8 image → direct image 1 (\v i → let y = v ! i in Texel y y y (greyAlpha (fromIntegral y)))
    ImageY16 image → direct image 1 (\v i → let y = narrow (v ! i) in Texel y y y (greyAlpha (v ! i)))
    ImageYA8 image → direct image 2 (\v i → let y = v ! i in Texel y y y (v ! (i + 1)))
    ImageYA16 image → direct image 2 (\v i → let y = narrow (v ! i) in Texel y y y (narrow (v ! (i + 1))))
    ImageRGB8 image →
      direct image 3 $ \v i →
        Texel (v ! i) (v ! (i + 1)) (v ! (i + 2)) (rgbAlpha (fromIntegral (v ! i)) (fromIntegral (v ! (i + 1))) (fromIntegral (v ! (i + 2))))
    ImageRGB16 image →
      direct image 3 $ \v i →
        Texel (narrow (v ! i)) (narrow (v ! (i + 1))) (narrow (v ! (i + 2))) (rgbAlpha (v ! i) (v ! (i + 1)) (v ! (i + 2)))
    ImageRGBA8 image → direct image 4 (\v i → Texel (v ! i) (v ! (i + 1)) (v ! (i + 2)) (v ! (i + 3)))
    ImageRGBA16 image →
      direct image 4 (\v i → Texel (narrow (v ! i)) (narrow (v ! (i + 1))) (narrow (v ! (i + 2))) (narrow (v ! (i + 3))))
    _ → Left "JuicyPixels returned a pixel type no PNG decodes to"
  -- A 1-, 2- or 4-bit greyscale image arrives as indices into a generated
  -- grey palette, and each index is the stored sample. Its tRNS chunk is a
  -- two-byte colour key, which JuicyPixels applies to that palette as if it
  -- were a table of alphas; the key is applied to the index instead.
  PalettedRGB8 indices palette
    | PngGreyscale ← colourType → paletted indices palette 3 (\p x → let j = 3 * x in Texel (p ! j) (p ! (j + 1)) (p ! (j + 2)) (greyAlpha (fromIntegral x)))
    | otherwise → paletted indices palette 3 (\p x → let j = 3 * x in Texel (p ! j) (p ! (j + 1)) (p ! (j + 2)) 255)
  PalettedRGBA8 indices palette
    | PngGreyscale ← colourType → paletted indices palette 4 (\p x → let j = 4 * x in Texel (p ! j) (p ! (j + 1)) (p ! (j + 2)) (greyAlpha (fromIntegral x)))
    | otherwise → paletted indices palette 4 (\p x → let j = 4 * x in Texel (p ! j) (p ! (j + 1)) (p ! (j + 2)) (p ! (j + 3)))
  _ → Left "JuicyPixels returned a palette type no PNG decodes to"
  where
    (!) ∷ Vector.Storable a ⇒ Vector.Vector a → Int → a
    (!) = Vector.unsafeIndex

    -- Alpha for a greyscale or truecolour texel's stored samples, at the
    -- image's own bit depth.
    greyAlpha ∷ Word16 → Word8
    greyAlpha y = case key of
      Just (GreyKey k) | y == k → 0
      _ → 255

    rgbAlpha ∷ Word16 → Word16 → Word16 → Word8
    rgbAlpha r g b = case key of
      Just (RgbKey kr kg kb) | r == kr && g == kg && b == kb → 0
      _ → 255

    direct
      ∷ Vector.Storable (PixelBaseComponent p)
      ⇒ Image p → Int → (Vector.Vector (PixelBaseComponent p) → Int → Texel) → Either Text (Int, Int, ByteString)
    direct image components texel
      | Vector.length samples /= count * components = Left "JuicyPixels returned an image whose samples do not match its extent"
      | otherwise = Right (imageWidth image, imageHeight image, level kind count (\n → texel samples (n * components)))
      where
        count = imageWidth image * imageHeight image
        samples = imageData image

    paletted
      ∷ PixelBaseComponent q ~ Word8
      ⇒ Image Pixel8 → Palette' q → Int → (Vector.Vector Word8 → Int → Texel) → Either Text (Int, Int, ByteString)
    paletted indices palette components texel
      | Vector.length chosen /= count = Left "JuicyPixels returned an image whose indices do not match its extent"
      | Vector.length entries < size * components = Left "JuicyPixels returned a palette shorter than its size"
      | not (Vector.null chosen) && fromIntegral (Vector.maximum chosen) >= size =
          Left ("a palette index " <> tshow (Vector.maximum chosen) <> " is outside the " <> tshow size <> "-entry palette")
      | otherwise =
          Right (imageWidth indices, imageHeight indices, level kind count (\n → texel entries (fromIntegral (chosen ! n))))
      where
        count = imageWidth indices * imageHeight indices
        chosen = imageData indices
        entries = _paletteData palette
        size = _paletteSize palette

-- | One level of @count@ texels, premultiplied when the kind is colour.
level ∷ ImageKind → Int → (Int → Texel) → ByteString
level kind count texel = ByteString.unsafeCreate (count * 4) $ \pointer →
  let go n
        | n >= count = pure ()
        | otherwise = do
            let Texel r g b a = finish (texel n)
            pokeByteOff pointer (4 * n) r
            pokeByteOff pointer (4 * n + 1) g
            pokeByteOff pointer (4 * n + 2) b
            pokeByteOff pointer (4 * n + 3) a
            go (n + 1)
   in go 0
  where
    finish = case kind of
      ColourImage → \(Texel r g b a) → Texel (premultiplyChannel a r) (premultiplyChannel a g) (premultiplyChannel a b) a
      DataImage → id
{-# INLINE level #-}

-- | nearest(v × 255 ÷ 65535). The division never ties, since 65535 is odd.
narrow ∷ Word16 → Word8
narrow v = fromIntegral ((fromIntegral v * 255 + 32767) `div` (65535 ∷ Word32))

-- | Whether every texel of an RGBA8 level has alpha 0 or 255.
binaryAlpha ∷ ByteString → Bool
binaryAlpha bytes = go 3
  where
    go i
      | i >= ByteString.length bytes = True
      | otherwise =
          let a = ByteString.unsafeIndex bytes i
           in (a == 0 || a == 255) && go (i + 4)

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
