-- | The terrain's texel-index rule (TRA-17, owner amendment @owner-decision:659-q13-texel-bias-v2@),
-- stated once for every terrain consumer: the shader's colour and normal samples (the GLSL literal is
-- made from 'texelBias'), CPU coverage and picking, and the material's pure model.
--
-- For a region of @n@ texels along an axis and a normalized coordinate @u@,
--
-- > i = min (n - 1) (floor (clamp u 0 1 × n + texelBias))        texelBias = 1/128
--
-- evaluated exactly: the coordinate is converted with 'toRational' before the product, so no floating
-- rounding can move an index. An interior boundary selects the higher index, as does a coordinate
-- within the bias below it (float32 interpolation on the device lands a hair below a boundary: no bias
-- selected the lower texel at exact boundaries, and 1/10000 was still too small at pixel-snapped zooms
-- 9/8 and 5/4), and the outer edge selects the last texel. The index is applied before a region's
-- origin is added. The neutral region primitive
-- ("Hetoimasia.Asset.Image.Region") does not know this rule and samples without a bias; a terrain
-- consumer computes its biased integer index here and reads 'Hetoimasia.Asset.Image.Region.regionViewCoverageAt'.
--
-- The independent expectation ("Hetoimasia.Terrain.Render2D.Evidence") restates 1/128 on its own and
-- imports nothing from here.
--
-- State, ownership and lifetime: none. Pure.
module Hetoimasia.Terrain.Render2D.TexelRule
  ( texelBias
  , texelIndexWith
  , texelIndexExact
  , texelIndex
  , texelIndexDoubleWith
  ) where

import Data.Ratio ((%))
import Data.Word (Word32)

-- | The texel bias, in texels: @1/128@.
texelBias ∷ Rational
texelBias = 1 % 128

-- | The rule with a given bias for an exact coordinate, in an extent of @n@ (at least 1) texels. A
-- bias other than 'texelBias' exists only for the evidence's negative controls.
texelIndexWith ∷ Rational → Word32 → Rational → Word32
texelIndexWith bias n u = fromInteger (min (toInteger n - 1) (floor (clamped * toRational n + bias)))
  where
    clamped = min 1 (max 0 u)

-- | The rule for an exact coordinate.
texelIndexExact ∷ Word32 → Rational → Word32
texelIndexExact = texelIndexWith texelBias

-- | The rule for a 'Double' coordinate, evaluated exactly: 'Nothing' for a coordinate that is not a
-- number and for an extent of zero.
texelIndex ∷ Word32 → Double → Maybe Word32
texelIndex = texelIndexDoubleWith texelBias

-- | 'texelIndexWith' for a 'Double' coordinate, converted exactly before the product.
texelIndexDoubleWith ∷ Rational → Word32 → Double → Maybe Word32
texelIndexDoubleWith bias n u
  | n == 0 || isNaN u = Nothing
  | otherwise = Just (texelIndexWith bias n (toRational (min 1 (max 0 u))))
