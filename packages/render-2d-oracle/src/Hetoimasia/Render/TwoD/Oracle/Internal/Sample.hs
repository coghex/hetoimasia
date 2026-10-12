-- | Mip level selection and texture filtering.
--
-- A fragment's texture coordinates are affine in target pixels, so their
-- derivatives are constants of the placed quad, and Vulkan's level of detail is
-- @λ = log₂ ρmax@ with @ρmax@ the larger of the lengths of the two columns of
-- the matrix of derivatives, in texels of level 0. The oracle takes the
-- derivatives exactly, in 'Rational's, and decides:
--
-- * a texture with one level, or a magnified probe (@λ ≤ 0@, that is
--   @ρmax² ≤ 1@), reads level 0;
-- * a minified probe whose derivatives are axis-aligned (no shear, no rotation
--   other than quarter turns) and whose @λ@ is exactly a whole number, or at
--   least the last level's index, reads that level or the last;
-- * any other minified probe is refused, never guessed.
--
-- Every one of those decisions is exact: @λ@ is the whole number @k@ when
-- @ρmax² = 4ᵏ@ in 'Rational's, and an axis is aligned when its off-axis
-- derivatives are exactly zero, so no tolerance has to be argued through the
-- shading, blending and store that follow. A 32-bit quarter turn that is not
-- exactly one is therefore not axis-aligned, and a minified probe through it is
-- refused. Addressing is clamp-to-edge. Nearest takes
-- the texel containing the coordinate and, within 1/16 texel of an interior
-- texel boundary, where the recorder's rounding picks either side, is refused
-- unless the texels on both sides are alike;
-- linear weighs the four texels around @coordinate × extent − ½@, which is
-- continuous across a boundary and needs no refusal.
--
-- __Dependencies.__ @base@, @bytestring@ and this package's image and
-- pipeline modules.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Oracle.Internal.Sample
  ( Derivatives (..)
  , derivatives
  , LevelRefusal (..)
  , chooseLevel
  , SampleRefusal (..)
  , sampleLevel
  , placeholder
  ) where

import qualified Data.ByteString as ByteString
import Data.List (find)
import qualified Data.ByteString.Unsafe as ByteString
import Data.Word (Word8)
import Hetoimasia.Render.TwoD.Oracle.Internal.Image (Image (..), Level (..))
import Hetoimasia.Render.TwoD.Oracle.Internal.Pipeline (Chan (..), Quad (..), Source, pinChan, zeroChan)
import Hetoimasia.Render.TwoD.Oracle.Colour (srgbToLinear)
import Hetoimasia.Render.TwoD.Settings (TextureFilter (..))

-- | The derivatives of the texel coordinates of level 0 with respect to target
-- pixels: @∂U/∂x@, @∂U/∂y@, @∂V/∂x@, @∂V/∂y@.
data Derivatives = Derivatives !Rational !Rational !Rational !Rational
  deriving stock (Eq, Show)

-- | The derivatives of a placed quad: the inverse of its linear part (local
-- @x@ then local @y@, each as the pair of its coefficients on target @x@ and
-- @y@), the UV rectangle and level 0's extent.
derivatives ∷ ((Rational, Rational), (Rational, Rational)) → (Rational, Rational, Rational, Rational) → (Int, Int) → Derivatives
derivatives ((m00, m01), (m10, m11)) (u0, v0, u1, v1) (width, height) =
  Derivatives
    ((u1 - u0) * w * m00)
    ((u1 - u0) * w * m01)
    ((v1 - v0) * h * m10)
    ((v1 - v0) * h * m11)
  where
    w = fromIntegral width
    h = fromIntegral height

-- | Why a minified probe has no determinate level.
data LevelRefusal
  = -- | The derivatives are sheared or rotated by other than a quarter turn.
    NotAxisAligned
  | -- | The level of detail falls between two levels.
    FractionalLevel
  deriving stock (Eq, Show)

-- | The level a probe reads, given the texture's level count. Every decision is
-- exact: @λ@ is a whole number @k@ exactly when @ρmax² = 4ᵏ@, and an axis is
-- aligned when its off-axis derivatives are exactly zero.
chooseLevel ∷ Int → Derivatives → Either LevelRefusal Int
chooseLevel levelCount (Derivatives a b c e)
  | levelCount <= 1 = Right 0
  | rhoSquared <= 1 = Right 0
  | not axisAligned = Left NotAxisAligned
  | rhoSquared >= 4 ^ lastLevel = Right lastLevel
  | otherwise = maybe (Left FractionalLevel) Right (find (\level → rhoSquared == 4 ^ level) [1 .. lastLevel - 1])
  where
    lastLevel = levelCount - 1
    rhoSquared = max (a * a + c * c) (b * b + e * e)
    axisAligned = (b == 0 && c == 0) || (a == 0 && e == 0)

-- | Why a sample is refused.
data SampleRefusal
  = -- | A nearest-filter coordinate within 1/16 texel of an interior boundary
    -- between texels that differ.
    AtTexelBoundary
  deriving stock (Eq, Show)

-- | The transparent black of slot 0's placeholder: a handle with no texture
-- samples this, whatever its sampler.
placeholder ∷ Source
placeholder = Quad zeroChan zeroChan zeroChan zeroChan

-- | Sample a level at a texture coordinate. The first argument says whether the
-- target stores sRGB-encoded colour, which decides whether a carried colour
-- byte survives to the store unchanged.
sampleLevel ∷ Bool → TextureFilter → Image → Int → (Rational, Rational) → Either SampleRefusal Source
sampleLevel targetSrgb filtering image levelIndex (u, v) = case filtering of
  FilterNearest → nearest
  FilterLinear → Right linear
  where
    Level width height texels = imageLevels image !! levelIndex
    w = toInteger width
    h = toInteger height
    x = u * fromIntegral w
    y = v * fromIntegral h
    clampTo size index = fromInteger (max 0 (min (size - 1) index)) ∷ Int
    fetch ix iy = texelSource (imageSrgb image) targetSrgb texels ((iy * width + ix) * 4)

    nearest =
      case [fetch ix iy | ix ← candidates x w, iy ← candidates y h] of
        first : rest | all (== first) rest → Right first
        _ → Left AtTexelBoundary
    -- The texel containing the coordinate; or, within 1/16 texel of an interior
    -- boundary, the texels on both sides of it.
    candidates coordinate size
      | edge > 0 && edge < size && abs (coordinate - fromInteger edge) <= 1 / 16 =
          [clampTo size (edge - 1), clampTo size edge]
      | otherwise = [clampTo size (floor coordinate)]
      where
        edge = round coordinate ∷ Integer

    linear =
      mixTexels
        [ ((1 - fx) * (1 - fy), fetch ix0 iy0)
        , (fx * (1 - fy), fetch ix1 iy0)
        , ((1 - fx) * fy, fetch ix0 iy1)
        , (fx * fy, fetch ix1 iy1)
        ]
    (i0, fx) = split (x - 1 / 2)
    (j0, fy) = split (y - 1 / 2)
    ix0 = clampTo w i0
    ix1 = clampTo w (i0 + 1)
    iy0 = clampTo h j0
    iy1 = clampTo h (j0 + 1)
    split coordinate = let whole = floor coordinate ∷ Integer in (whole, coordinate - fromInteger whole)

-- | The texel at a byte offset, as a source in linear light. A colour channel
-- is exact when the texture and the target store it alike, and always when it
-- is 0 or 255; alpha is linear in both.
texelSource ∷ Bool → Bool → ByteString.ByteString → Int → Source
texelSource imageSrgbEncoded targetSrgb texels offset =
  Quad (colour 0) (colour 1) (colour 2) (alpha 3)
  where
    byteAt n = ByteString.unsafeIndex texels (offset + n)
    colour n = pinChan (Chan (decode (byteAt n)) (imageSrgbEncoded == targetSrgb || byteAt n == 255 || byteAt n == 0))
    alpha n = Chan (fromIntegral (byteAt n) / 255) True
    decode ∷ Word8 → Double
    decode byte
      | imageSrgbEncoded = srgbToLinear (fromIntegral byte / 255)
      | otherwise = fromIntegral byte / 255

-- | Weight texels: the one that carries all the weight, or any set that agrees,
-- unchanged; otherwise the weighted sum, which rounds.
mixTexels ∷ [(Rational, Source)] → Source
mixTexels weighted = Quad (mix (\(Quad r _ _ _) → r)) (mix (\(Quad _ g _ _) → g)) (mix (\(Quad _ _ b _) → b)) (mix (\(Quad _ _ _ a) → a))
  where
    mix channel = mixChannel [(weight, channel texel) | (weight, texel) ← weighted]

mixChannel ∷ [(Rational, Chan)] → Chan
mixChannel weighted = case filter ((/= 0) . fst) weighted of
  [] → zeroChan
  [(_, only)] → only
  live@((_, first) : rest)
    | all ((== first) . snd) rest → first
    | otherwise → pinChan (Chan (sum [fromRational weight * chanValue chan | (weight, chan) ← live]) False)
