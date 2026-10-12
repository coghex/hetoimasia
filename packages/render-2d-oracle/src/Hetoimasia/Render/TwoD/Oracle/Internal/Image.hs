-- | A checked, sampleable image.
--
-- 'DecodedImage' has a public constructor, so a value of it can claim an
-- extent and levels that disagree. 'checkImage' refuses every such value and
-- returns an 'Image' whose levels are RGBA8 texels, each exactly the size its
-- extent says, decoding BC7 levels in software with @asset-image@'s decoder.
-- Byte counts are checked in 'Integer', so an extent near 2³² cannot wrap.
--
-- __Dependencies.__ @base@, @bytestring@, @text@, @hetoimasia-asset@ and
-- @hetoimasia-asset-image@.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Oracle.Internal.Image
  ( ImageFault (..)
  , Image (..)
  , Level (..)
  , checkImage
  ) where

import Data.Bits (shiftR)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (..))
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.Asset.Image.Bc7 (Bc7Format (..), bc7Image, decodeBc7)

-- | Why a decoded image cannot be sampled.
data ImageFault
  = -- | A width or height of zero.
    ZeroExtent
  | -- | No level at all, or more levels than the extent's mip chain has. The
    -- count is the number supplied.
    LevelCountInvalid !Int
  | -- | A level whose byte count is not the one its extent and format need;
    -- the index counts from zero.
    LevelSizeWrong !Int
  | -- | The BC7 decoder refused the levels.
    Bc7Refused
  deriving stock (Eq, Show)

-- | One level of RGBA8 texels.
data Level = Level
  { levelWidth ∷ !Int
  , levelHeight ∷ !Int
  , levelTexels ∷ !ByteString
  }

-- | A checked image: every level as RGBA8, and whether its colour channels are
-- sRGB-encoded.
data Image = Image
  { imageSrgb ∷ !Bool
  , imageLevels ∷ [Level]
  }

-- | Check a decoded image and read its levels.
checkImage ∷ DecodedImage → Either ImageFault Image
checkImage decoded = do
  let width = toInteger (decodedWidth decoded)
      height = toInteger (decodedHeight decoded)
      levels = decodedLevels decoded
      count = length levels
  if width == 0 || height == 0 then Left ZeroExtent else Right ()
  if count < 1 || count > chainLength width height then Left (LevelCountInvalid count) else Right ()
  mapM_ (checkLevel width height) (zip [0 ..] levels)
  texels ← case decodedFormat decoded of
    TexelRgba8Srgb → Right levels
    TexelRgba8Linear → Right levels
    TexelBc7Srgb → softwareDecode Bc7Srgb width height levels
    TexelBc7Linear → softwareDecode Bc7Linear width height levels
  Right
    Image
      { imageSrgb = case decodedFormat decoded of
          TexelRgba8Srgb → True
          TexelBc7Srgb → True
          TexelRgba8Linear → False
          TexelBc7Linear → False
      , imageLevels =
          [ Level (fromInteger w) (fromInteger h) bytes
          | (level, bytes) ← zip [0 ..] texels
          , let (w, h) = extentAt width height level
          ]
      }
  where
    checkLevel width height (level, bytes)
      | toInteger (ByteString.length bytes) == levelBytes (decodedFormat decoded) (extentAt width height level) = Right ()
      | otherwise = Left (LevelSizeWrong level)

softwareDecode ∷ Bc7Format → Integer → Integer → [ByteString] → Either ImageFault [ByteString]
softwareDecode format width height levels =
  case bc7Image oracleAsset format (fromInteger width) (fromInteger height) levels of
    Left _ → Left Bc7Refused
    Right image → Right (decodedLevels (decodeBc7 image))

-- | The asset the software decoder is told it is decoding. Its refusals name
-- it; the oracle reports its own fault instead.
oracleAsset ∷ Asset
oracleAsset = Asset (AssetId (Text.pack "render-2d-oracle")) (FromMemory (Text.pack "render-2d-oracle"))

-- | The extent of a level.
extentAt ∷ Integer → Integer → Int → (Integer, Integer)
extentAt width height level = (max 1 (width `shiftR` level), max 1 (height `shiftR` level))

-- | The number of levels in the full mip chain of an extent.
chainLength ∷ Integer → Integer → Int
chainLength width height = length (takeWhile (> 0) (iterate (`shiftR` 1) (max width height)))

-- | The bytes a level of this extent holds in a format: four per texel for
-- RGBA8, sixteen per four-by-four block for BC7.
levelBytes ∷ TexelFormat → (Integer, Integer) → Integer
levelBytes format (width, height) = case format of
  TexelRgba8Srgb → width * height * 4
  TexelRgba8Linear → width * height * 4
  TexelBc7Srgb → blocks width * blocks height * 16
  TexelBc7Linear → blocks width * blocks height * 16
  where
    blocks size = (size + 3) `div` 4
