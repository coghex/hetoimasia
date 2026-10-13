{-# LANGUAGE TemplateHaskell #-}

-- | The sample's committed images, embedded in the library, and what decoding
-- them gives (R2D-8).
--
-- The PNG files are read with @hetoimasia-asset-image@'s @decodePng@ as colour
-- art, and the KTX2 file with its @decodeKtx2@, which returns an RGBA8 image
-- for the profile the file is in. Both are 'ColourImage's, so their texels are
-- sRGB-encoded and premultiplied in linear light, as the asset contract says,
-- and the upload's format is the one 'imageFormatOf' maps. The files are made
-- by @samples/image2d/tools/make_fixtures.py@; see the sample's README.
module Hetoimasia.Sample.Image2d.Assets
  ( ImageName (..)
  , allImages
  , assetPath
  , embeddedBytes
  , decodeImage
  , imageFormatOf
  , describeImage
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Asset (Asset (..), AssetId (..), AssetRefusal (..), Provenance (..))
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (..), TexelFormat (..))
import Hetoimasia.Asset.Image.Ktx2 (Ktx2Image (..), decodeKtx2)
import Hetoimasia.Asset.Image.Png (decodePng)
import Hetoimasia.GPU.Vulkan.Native.Recording (ImageDescription (..), ImageFormat (..))
import qualified Hetoimasia.GPU.Vulkan.Native.Recording as Native
import Hetoimasia.Sample.Image2d.Embed (embedFile)

-- | The sample's three images.
data ImageName
  = -- | The PNG drawn in the world and again in UI space: four quadrants.
    Quadrants
  | -- | A PNG of non-binary alpha, the replacement a swap is refused for.
    Fade
  | -- | The RGBA8 KTX2 file drawn beside the PNG: four bands.
    Stripes
  deriving (Eq, Ord, Show, Enum, Bounded)

allImages ∷ [ImageName]
allImages = [minBound .. maxBound]

-- | Where the file is committed, relative to the repository root.
assetPath ∷ ImageName → FilePath
assetPath = \case
  Quadrants → "samples/image2d/renderer/assets/quadrants.png"
  Fade → "samples/image2d/renderer/assets/fade.png"
  Stripes → "samples/image2d/renderer/assets/stripes.ktx2"

-- | The file's bytes, as committed.
embeddedBytes ∷ ImageName → ByteString
embeddedBytes = \case
  Quadrants → $(embedFile "assets/quadrants.png")
  Fade → $(embedFile "assets/fade.png")
  Stripes → $(embedFile "assets/stripes.ktx2")

-- | Decode the image with @asset-image@, as colour art.
decodeImage ∷ ImageName → Either Text DecodedImage
decodeImage name = case name of
  Stripes → case decodeKtx2 ColourImage asset bytes of
    Left (AssetRefusal _ reason) → Left reason
    Right (Ktx2Rgba8 image) → Right image
    Right (Ktx2Bc7 _) → Left "the KTX2 file decoded to BC7, not RGBA8"
  _ → either (\(AssetRefusal _ reason) → Left reason) Right (decodePng ColourImage asset bytes)
  where
    bytes = embeddedBytes name
    asset = Asset (AssetId (Text.pack (show name))) (FromMemory ("embedded from " <> Text.pack (assetPath name)))

-- | The upload endpoint's format for a decoded image's, the mapping
-- @Hetoimasia.Asset.Image@ names.
imageFormatOf ∷ TexelFormat → ImageFormat
imageFormatOf = \case
  TexelRgba8Srgb → Rgba8Srgb
  TexelRgba8Linear → Rgba8Linear
  TexelBc7Srgb → Bc7Srgb
  TexelBc7Linear → Bc7Linear

-- | The texture the decoded image uploads into: its format and extent, with
-- every level it carries.
describeImage ∷ DecodedImage → ImageDescription
describeImage decoded =
  ImageDescription Native.TextureImage (imageFormatOf (decodedFormat decoded)) (decodedWidth decoded) (decodedHeight decoded) (fromIntegral (length (decodedLevels decoded)))
