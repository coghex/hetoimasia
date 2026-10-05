-- | Turning what JuicyPixels decodes into one tightly packed RGBA8 level.
--
-- Every PNG colour type and bit depth arrives here as one of JuicyPixels'
-- image or palette types and leaves as four bytes per texel, R, G, B, A, top
-- row first:
--
-- * a missing alpha channel becomes 255, including on a greyscale or truecolour
--   image carrying a @tRNS@ colour key, which this decoder does not apply;
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
-- as a palette) from an indexed one.
rgba8Level ∷ ImageKind → PngImageType → PalettedImage → Either Text (Int, Int, ByteString)
rgba8Level kind colourType = \case
  TrueColorImage dynamic → case dynamic of
    ImageY8 image → direct image 1 (\v i → let y = v ! i in Texel y y y 255)
    ImageY16 image → direct image 1 (\v i → let y = narrow (v ! i) in Texel y y y 255)
    ImageYA8 image → direct image 2 (\v i → let y = v ! i in Texel y y y (v ! (i + 1)))
    ImageYA16 image → direct image 2 (\v i → let y = narrow (v ! i) in Texel y y y (narrow (v ! (i + 1))))
    ImageRGB8 image → direct image 3 (\v i → Texel (v ! i) (v ! (i + 1)) (v ! (i + 2)) 255)
    ImageRGB16 image → direct image 3 (\v i → Texel (narrow (v ! i)) (narrow (v ! (i + 1))) (narrow (v ! (i + 2))) 255)
    ImageRGBA8 image → direct image 4 (\v i → Texel (v ! i) (v ! (i + 1)) (v ! (i + 2)) (v ! (i + 3)))
    ImageRGBA16 image →
      direct image 4 (\v i → Texel (narrow (v ! i)) (narrow (v ! (i + 1))) (narrow (v ! (i + 2))) (narrow (v ! (i + 3))))
    _ → Left "JuicyPixels returned a pixel type no PNG decodes to"
  PalettedRGB8 indices palette → paletted indices palette 3 (\p j → Texel (p ! j) (p ! (j + 1)) (p ! (j + 2)) 255)
  PalettedRGBA8 indices palette
    -- A greyscale tRNS chunk is a two-byte colour key, which JuicyPixels
    -- applies to its generated grey palette as if it were a table of alphas.
    | PngGreyscale ← colourType → paletted indices palette 4 (\p j → Texel (p ! j) (p ! (j + 1)) (p ! (j + 2)) 255)
    | otherwise → paletted indices palette 4 (\p j → Texel (p ! j) (p ! (j + 1)) (p ! (j + 2)) (p ! (j + 3)))
  _ → Left "JuicyPixels returned a palette type no PNG decodes to"
  where
    (!) ∷ Vector.Storable a ⇒ Vector.Vector a → Int → a
    (!) = Vector.unsafeIndex

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
          Right (imageWidth indices, imageHeight indices, level kind count (\n → texel entries (fromIntegral (chosen ! n) * components)))
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
