-- | Decoded images, shaped for the GPU upload endpoint (#342).
--
-- A 'DecodedImage' carries exactly what an upload of a texture takes: a
-- format, an extent, and every mip level, base level first, each tightly
-- packed in the format's blocks. A consumer passes 'decodedLevels' to the
-- endpoint's @UploadImage@ unchanged and maps only the format. This package
-- does not import the GPU packages, so the mapping is the consumer's:
--
-- > TexelRgba8Srgb   ↦ Rgba8Srgb
-- > TexelRgba8Linear ↦ Rgba8Linear
-- > TexelBc7Srgb     ↦ Bc7Srgb
-- > TexelBc7Linear   ↦ Bc7Linear
module Hetoimasia.Asset.Image
  ( ImageKind (..)
  , TexelFormat (..)
  , DecodedImage (..)
  )
where

import Control.DeepSeq (NFData (rnf))
import Data.ByteString (ByteString)
import Data.Word (Word32)

-- | What a texture holds, stated by the caller with every decode. The kind,
-- never the file, decides the colour space.
data ImageKind
  = -- | Colour art: sRGB, with alpha premultiplied in linear light.
    ColourImage
  | -- | Data such as masks and face maps: linear, never premultiplied.
    DataImage
  deriving (Eq, Ord, Show, Enum, Bounded)

instance NFData ImageKind where
  rnf kind = kind `seq` ()

-- | How a decoded image's texels are stored. Each value corresponds to
-- exactly one of the upload endpoint's formats, named in the module header.
data TexelFormat
  = -- | Four bytes per texel, R, G, B, A in that order; colour channels are
    -- sRGB-encoded and premultiplied in linear light, alpha is linear.
    TexelRgba8Srgb
  | -- | Four bytes per texel, R, G, B, A in that order, all linear UNORM and
    -- not premultiplied.
    TexelRgba8Linear
  | -- | BC7 blocks: four by four texels in sixteen bytes, decoding to RGBA8
    -- with sRGB-encoded colour channels. Colour content with alpha is
    -- premultiplied when it is encoded, never at load.
    TexelBc7Srgb
  | -- | BC7 blocks: four by four texels in sixteen bytes, decoding to linear
    -- UNORM RGBA8.
    TexelBc7Linear
  deriving (Eq, Ord, Show, Enum, Bounded)

instance NFData TexelFormat where
  rnf format = format `seq` ()

-- | A decoded image.
--
-- Level 0 is 'decodedWidth' × 'decodedHeight' texels, and level @L@ is
-- @max 1 (width >> L)@ × @max 1 (height >> L)@. Each level holds its rows of
-- blocks top row first, with no padding between them, in 'decodedFormat': a
-- block is one texel for RGBA8, and four by four texels for BC7, where a
-- block that crosses the level's right or bottom edge is stored whole.
data DecodedImage = DecodedImage
  { decodedFormat ∷ !TexelFormat
  , decodedWidth ∷ !Word32
  , decodedHeight ∷ !Word32
  , decodedLevels ∷ ![ByteString]
    -- ^ Every mip level, base level first, as the endpoint takes them.
  , decodedBinaryAlpha ∷ !Bool
    -- ^ Whether level 0's alpha is binary: true exactly when every texel's
    -- alpha is 0 or 255. The 2D renderer takes it as a texture's default
    -- cutout mark.
  }
  deriving (Eq, Show)

instance NFData DecodedImage where
  rnf (DecodedImage format width height levels binary) =
    rnf format `seq` rnf width `seq` rnf height `seq` rnf levels `seq` rnf binary
