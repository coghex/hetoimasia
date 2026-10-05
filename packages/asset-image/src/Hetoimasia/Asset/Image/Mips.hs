-- | Mip chains for decoded images, generated only on request.
--
-- A caller that wants mips decodes as usual and then applies
-- 'generateMips' to the decoded image; a caller that does not never reaches
-- this module, and its decode is exactly what it was without it. Pixel art
-- drawn with nearest filtering needs no mips; smoothly zoomed art does
-- (asset design D-6).
--
-- A generated chain holds level 0 unchanged, followed by every level down to
-- 1 × 1: level @L@ is @max 1 (width >> L)@ by @max 1 (height >> L)@, as the
-- upload endpoint (#342) takes them. The format, extent and cutout mark are
-- unchanged.
--
-- Every generated level is computed from level 0 directly. Output texel
-- (x, y) of a w × h level is the area-weighted average of level 0's
-- rectangle [x·W÷w, (x+1)·W÷w) × [y·H÷h, (y+1)·H÷h), so every level 0 texel
-- contributes, at odd extents too.
--
-- * 'TexelRgba8Srgb': colour is decoded with the sRGB transfer function to
--   linear premultiplied values (level 0 is already premultiplied, so it is
--   not multiplied by alpha again), averaged with alpha, and re-encoded.
-- * 'TexelRgba8Linear': all four channels are averaged as stored, with no
--   premultiplication.
--
-- Every channel is rounded to nearest, halves up.
--
-- Coverage preservation, when it applies (see 'Coverage'), keeps each level's
-- fraction of covered texels — alpha at least 128, the 8-bit form of the 2D
-- renderer's 0.5 cutout threshold — as close to level 0's as any scaling of
-- that level's alpha allows (asset design D-10). See
-- "Hetoimasia.Asset.Image.Internal.MipChain" for the rule that picks the
-- scale.
--
-- Generation is pure: the same image and request always give the same
-- levels.
module Hetoimasia.Asset.Image.Mips
  ( MipRequest (..)
  , Coverage (..)
  , mipRequest
  , generateMips
  , mipmapped
  )
where

import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Asset (AssetRefusal (..), Decoder (..))
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.Asset.Image.Internal.MipChain (Channels (..), generatedLevels)

-- | What a caller asks of a mip chain.
newtype MipRequest = MipRequest
  { mipCoverage ∷ Coverage
    -- ^ Whether generated levels preserve cutout coverage.
  }
  deriving (Eq, Show)

-- | Whether a chain's generated levels preserve coverage at the cutout
-- threshold.
data Coverage
  = -- | The decoded image's cutout mark decides: preserved exactly when
    -- 'decodedBinaryAlpha' is true.
    CoverageFromMark
  | -- | Preserved, whatever the mark.
    PreserveCoverage
  | -- | Not preserved, whatever the mark: every level is the plain average.
    PlainAverages
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A request that leaves coverage to the image's cutout mark.
mipRequest ∷ MipRequest
mipRequest = MipRequest {mipCoverage = CoverageFromMark}

-- | The image with its full mip chain, generated from level 0. Any levels
-- after level 0 are replaced. An image whose level 0 does not hold width ×
-- height four-byte texels is refused with the reason.
generateMips ∷ MipRequest → DecodedImage → Either Text DecodedImage
generateMips request image = case decodedLevels image of
  base : _
    | ByteString.length base == expected →
        Right image {decodedLevels = base : generatedLevels channels preserve width height base}
    | otherwise → Left (misshapen (ByteString.length base))
  [] → Left "the image has no level 0"
  where
    width = fromIntegral (decodedWidth image)
    height = fromIntegral (decodedHeight image)
    expected = width * height * 4
    channels = case decodedFormat image of
      TexelRgba8Srgb → SrgbPremultiplied
      TexelRgba8Linear → LinearStraight
    preserve = case mipCoverage request of
      CoverageFromMark → decodedBinaryAlpha image
      PreserveCoverage → True
      PlainAverages → False
    misshapen ∷ Int → Text
    misshapen actual =
      "level 0 holds " <> tshow actual <> " bytes, not the " <> tshow expected <> " that "
        <> tshow width <> " × " <> tshow height <> " four-byte texels take"

-- | A decoder whose images carry the requested mip chain. A refusal of the
-- underlying decoder passes through; an image 'generateMips' refuses is
-- refused naming the asset.
mipmapped ∷ MipRequest → Decoder DecodedImage → Decoder DecodedImage
mipmapped request (Decoder decode) = Decoder $ \asset bytes →
  decode asset bytes >>= either (Left . AssetRefusal asset) Right . generateMips request

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
