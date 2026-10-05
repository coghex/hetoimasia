-- | BC7 images, their software decoder, and the fallback for devices that
-- cannot sample BC7.
--
-- A 'Bc7Image' holds BC7 levels exactly as the GPU upload endpoint (#342)
-- takes them: every level, base level first, each its rows of 4 × 4 blocks,
-- sixteen bytes a block, top row first. 'bc7Image' checks that shape and
-- computes the cutout mark by decoding level 0's alpha, on every device.
--
-- 'decodeBc7' decodes every level to RGBA8 in the same colour space, exactly
-- as the BC7 format defines each texel: no transfer function is applied and
-- nothing is premultiplied, since BC7 colour content is premultiplied when it
-- is encoded.
--
-- 'bc7Fallback' chooses between the two from the device's reported BC7
-- support, which the caller passes in. Its result states whether it decoded
-- in software, so the caller — never this package — can log the condition.
-- Everything here is pure: nothing logs, holds a logger or keeps state.
module Hetoimasia.Asset.Image.Bc7
  ( -- * BC7 images
    Bc7Format (..)
  , Bc7Image
  , bc7Image
  , bc7Asset
  , bc7Format
  , bc7Width
  , bc7Height
  , bc7Levels
  , bc7BinaryAlpha
  , bc7DecodedImage

    -- * Decoding
  , decodeBc7

    -- * Devices without BC7
  , Bc7Support (..)
  , Bc7Fallback (..)
  , SoftwareDecode (..)
  , bc7Fallback
  , fallbackImage
  , fallbackSoftwareDecode
  )
where

import Control.DeepSeq (NFData (rnf))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Internal as ByteString (unsafeCreate)
import Data.Foldable (for_)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Foreign.Storable (pokeByteOff)
import Hetoimasia.Asset (Asset, AssetRefusal (..))
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.Asset.Image.Internal.Bc7Block (Texel (..), blockTexel)

-- | A BC7 image's colour space, corresponding one-to-one to the upload
-- endpoint's @Bc7Srgb@ and @Bc7Linear@.
data Bc7Format
  = -- | Colour channels decode sRGB-encoded; alpha is linear.
    Bc7Srgb
  | -- | Every channel decodes linear UNORM.
    Bc7Linear
  deriving (Eq, Ord, Show, Enum, Bounded)

instance NFData Bc7Format where
  rnf format = format `seq` ()

-- | A BC7 image whose shape 'bc7Image' has checked, and its cutout mark.
data Bc7Image = Bc7Image
  { bc7Asset ∷ !Asset
    -- ^ The asset the image was constructed for.
  , bc7Format ∷ !Bc7Format
  , bc7Width ∷ !Word32
  , bc7Height ∷ !Word32
  , bc7Levels ∷ ![ByteString]
    -- ^ Every level, base level first, in the endpoint's layout.
  , bc7BinaryAlpha ∷ !Bool
    -- ^ Whether every texel of level 0, decoded, has alpha 0 or 255.
  }
  deriving (Eq, Show)

instance NFData Bc7Image where
  rnf (Bc7Image asset format width height levels binary) =
    rnf asset `seq` rnf format `seq` rnf width `seq` rnf height `seq` rnf levels `seq` rnf binary

-- | A BC7 image of the asset, or a refusal naming it. The width and height
-- must be positive; between one level and the extent's full chain
-- (@floor (log2 (max width height)) + 1@) must be supplied, base level
-- first; and level @L@, at extent @max 1 (width >> L)@ ×
-- @max 1 (height >> L)@, must hold exactly @ceil (w / 4) × ceil (h / 4) × 16@
-- bytes. The mark is computed here, from level 0's decoded alpha.
bc7Image ∷ Asset → Bc7Format → Word32 → Word32 → [ByteString] → Either AssetRefusal Bc7Image
bc7Image asset format width height levels = either (Left . AssetRefusal asset) Right $ do
  check (width > 0 && height > 0) $
    "a BC7 image's width and height must be positive; this one is " <> extent (width, height)
  base ← case levels of
    first : _ → Right first
    [] → Left "a BC7 image needs at least one level; none was supplied"
  check (supplied <= chain) $
    "a " <> extent (width, height) <> " BC7 image has at most " <> tshow chain <> " levels; " <> tshow supplied <> " were supplied"
  for_ (zip [0 ..] levels) $ \(level, bytes) → do
    let size = levelExtent width height level
        needed = levelBytes size
        actual = toInteger (ByteString.length bytes)
    check (actual == needed) $
      "BC7 level " <> tshow level <> " (" <> extent size <> ") needs " <> tshow needed <> " bytes; " <> tshow actual <> " were supplied"
  Right
    Bc7Image
      { bc7Asset = asset
      , bc7Format = format
      , bc7Width = width
      , bc7Height = height
      , bc7Levels = levels
      , bc7BinaryAlpha = binaryAlpha width height base
      }
  where
    supplied = length levels
    chain = fullChain width height
    check condition reason = if condition then Right () else Left reason
    extent (w, h) = tshow w <> " × " <> tshow h

-- | The BC7 image as a decoded image the upload endpoint takes unchanged, in
-- 'TexelBc7Srgb' or 'TexelBc7Linear'.
bc7DecodedImage ∷ Bc7Image → DecodedImage
bc7DecodedImage image =
  DecodedImage
    { decodedFormat = case bc7Format image of
        Bc7Srgb → TexelBc7Srgb
        Bc7Linear → TexelBc7Linear
    , decodedWidth = bc7Width image
    , decodedHeight = bc7Height image
    , decodedLevels = bc7Levels image
    , decodedBinaryAlpha = bc7BinaryAlpha image
    }

-- | Every level of the BC7 image decoded to tightly packed RGBA8, at the
-- same extents: 'TexelRgba8Srgb' from 'Bc7Srgb' and 'TexelRgba8Linear' from
-- 'Bc7Linear', texels exactly as the blocks encode them. Texels of a block
-- outside its level's extent are discarded. The result carries the BC7
-- image's mark.
decodeBc7 ∷ Bc7Image → DecodedImage
decodeBc7 image =
  DecodedImage
    { decodedFormat = case bc7Format image of
        Bc7Srgb → TexelRgba8Srgb
        Bc7Linear → TexelRgba8Linear
    , decodedWidth = bc7Width image
    , decodedHeight = bc7Height image
    , decodedLevels = zipWith (\level bytes → decodeLevel (levelExtent (bc7Width image) (bc7Height image) level) bytes) [0 ..] (bc7Levels image)
    , decodedBinaryAlpha = bc7BinaryAlpha image
    }

-- | Whether the device takes BC7, as its BC support query reports it. The
-- caller asks the device; this package never does.
data Bc7Support
  = DeviceTakesBc7
  | DeviceLacksBc7
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What a software decode converted: the asset and the BC7 format it was
-- stored in. Everything a caller needs to log the fallback.
data SoftwareDecode = SoftwareDecode
  { softwareDecodedAsset ∷ !Asset
  , softwareDecodedFormat ∷ !Bc7Format
  }
  deriving (Eq, Show)

instance NFData SoftwareDecode where
  rnf (SoftwareDecode asset format) = rnf asset `seq` rnf format

-- | Which way 'bc7Fallback' went. It reports only whether this step converted
-- the BC7 storage to RGBA8; level 0's alpha is decoded for the mark either
-- way.
data Bc7Fallback
  = -- | The device takes BC7: the image, unchanged.
    KeptBc7 !Bc7Image
  | -- | The device lacks BC7: the image decoded in software by 'decodeBc7'.
    DecodedInSoftware !SoftwareDecode !DecodedImage
  deriving (Eq, Show)

instance NFData Bc7Fallback where
  rnf = \case
    KeptBc7 image → rnf image
    DecodedInSoftware decode image → rnf decode `seq` rnf image

-- | The BC7 image for a device with the given support: unchanged where the
-- device takes BC7, decoded to RGBA8 where it does not. Logging the fallback
-- is the caller's: one @Warning@ per fallback instance, normally once per
-- device.
bc7Fallback ∷ Bc7Support → Bc7Image → Bc7Fallback
bc7Fallback = \case
  DeviceTakesBc7 → KeptBc7
  DeviceLacksBc7 → \image → DecodedInSoftware (SoftwareDecode (bc7Asset image) (bc7Format image)) (decodeBc7 image)

-- | The image to upload, in whichever format the fallback chose.
fallbackImage ∷ Bc7Fallback → DecodedImage
fallbackImage = \case
  KeptBc7 image → bc7DecodedImage image
  DecodedInSoftware _ image → image

-- | What was decoded in software, if anything.
fallbackSoftwareDecode ∷ Bc7Fallback → Maybe SoftwareDecode
fallbackSoftwareDecode = \case
  KeptBc7 _ → Nothing
  DecodedInSoftware decode _ → Just decode

-- | One level, decoded to RGBA8, its blocks' texels outside the extent
-- discarded.
decodeLevel ∷ (Int, Int) → ByteString → ByteString
decodeLevel (width, height) bytes = ByteString.unsafeCreate (4 * width * height) $ \pointer →
  for_ [0 .. blocksDown - 1] $ \by →
    for_ [0 .. blocksAcross - 1] $ \bx → do
      let texel = blockTexel bytes (16 * (by * blocksAcross + bx))
      for_ [0 .. min 4 (height - 4 * by) - 1] $ \ty →
        for_ [0 .. min 4 (width - 4 * bx) - 1] $ \tx → do
          let Texel r g b a = texel (4 * ty + tx)
              at = 4 * ((4 * by + ty) * width + 4 * bx + tx)
          pokeByteOff pointer at r
          pokeByteOff pointer (at + 1) g
          pokeByteOff pointer (at + 2) b
          pokeByteOff pointer (at + 3) a
  where
    blocksAcross = (width + 3) `div` 4
    blocksDown = (height + 3) `div` 4

-- | Whether every texel of level 0 inside the extent has alpha 0 or 255.
binaryAlpha ∷ Word32 → Word32 → ByteString → Bool
binaryAlpha width height bytes =
  and
    [ a == 0 || a == 255
    | by ← [0 .. blocksDown - 1]
    , bx ← [0 .. blocksAcross - 1]
    , let texel = blockTexel bytes (16 * (by * blocksAcross + bx))
    , ty ← [0 .. min 4 (h - 4 * by) - 1]
    , tx ← [0 .. min 4 (w - 4 * bx) - 1]
    , let Texel _ _ _ a = texel (4 * ty + tx)
    ]
  where
    (w, h) = (fromIntegral width, fromIntegral height) ∷ (Int, Int)
    blocksAcross = (w + 3) `div` 4
    blocksDown = (h + 3) `div` 4

-- | Level @level@'s extent: the base extent halved per level, never below one.
levelExtent ∷ Word32 → Word32 → Int → (Int, Int)
levelExtent width height level =
  (max 1 (fromIntegral width `div` 2 ^ level), max 1 (fromIntegral height `div` 2 ^ level))

-- | The bytes a level of this extent takes: every block, partial ones whole.
-- Computed without wraparound.
levelBytes ∷ (Int, Int) → Integer
levelBytes (w, h) = ((toInteger w + 3) `div` 4) * ((toInteger h + 3) `div` 4) * 16

-- | One more than the base-two logarithm of the larger side, rounded down.
fullChain ∷ Word32 → Word32 → Int
fullChain width height = length (takeWhile (> 0) (iterate (`div` 2) (max width height)))

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
