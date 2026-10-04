-- | The sprites scene's independent oracle (GRS-8): every probe's expected
-- value, computed from the fixtures' decoded texels, the scene's geometry and
-- texture coordinates, each draw's filter and the premultiplied-alpha blend
-- equation — never from an observed image.
--
-- At a probe's pixel centre, every instance covering it is visited in
-- painter order: draws in the scene's order, instances in each draw's. Each
-- samples its texture at the coordinate its rectangle maps the centre to,
-- clamped to the edge — nearest filtering takes the texel containing the
-- coordinate, linear filtering weighs the four texels around @coordinate ×
-- extent − 0.5@ — and is blended over what is below as
-- @result = source + destination × (1 − source alpha)@, channel by channel,
-- starting from the transparent clear. The result is rounded to 8 bits.
--
-- A probe is exact when only nearest samples reached it and no blend mixed
-- a translucent source into a non-clear destination: opaque nearest samples
-- and untouched clear pixels. Wherever linear filtering or such a blend
-- contributes, a channel may differ by one, for the device's rounding.
module Hetoimasia.Sample.Sprites.Oracle
  ( Expectation (..)
  , expectation
  , expectationWith
  , ProbeResult (..)
  , evaluateProbes
  , evaluateProbesWith
  , probesPassed
  , pixelAt
  , within
  ) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.List (foldl')

import Hetoimasia.GPU.Vulkan.Native.Recording (TableSampler (..))
import Hetoimasia.Sample.Sprites.Fixtures (Fixture (..), FixtureName, Rgba (..), UvRect (..), fixture, texelAt, transparent)
import Hetoimasia.Sample.Sprites.Scene (Draw (..), Instance (..), Probe (..), sceneDraws, sceneProbes, targetSide)

-- | What a probe must read, and by how much each channel may differ.
data Expectation = Expectation
  { expectedRgba ∷ !Rgba
  , expectedTolerance ∷ !Int
  }
  deriving (Eq, Show)

-- | A colour in progress, in 8-bit units, and whether anything inexact has
-- reached it.
data Accumulated = Accumulated !Double !Double !Double !Double !Bool

-- | The probe's expectation in the scene drawn with or without the BC7
-- draw.
expectation ∷ Bool → Probe → Expectation
expectation = expectationWith fixture

-- | 'expectation' with each fixture name drawing this texture: the swap case
-- (GRS-9) draws the atlas's handle with its replacement after the swap.
expectationWith ∷ (FixtureName → Fixture) → Bool → Probe → Expectation
expectationWith textureOf withBc7 probe =
  let Accumulated r g b a inexact = foldl' over (Accumulated 0 0 0 0 False) covering
   in Expectation (Rgba (byte r) (byte g) (byte b) (byte a)) (if inexact then 1 else 0)
  where
    (x, y) = probePixel probe
    centre = (fromIntegral x + 0.5, fromIntegral y + 0.5)
    covering = [(drawFilter draw, item) | draw ← sceneDraws withBc7, item ← drawInstances draw, covers item centre]
    over (Accumulated r g b a inexact) (sampler, item) =
      let (Sampled sr sg sb sa linear) = sampleInstance textureOf sampler item centre
          keep = 1 - sa / 255
          mixed = sa /= 255 && sa /= 0 && (r, g, b, a) /= (0, 0, 0, 0)
       in Accumulated (sr + r * keep) (sg + g * keep) (sb + b * keep) (sa + a * keep) (inexact || linear || mixed)
    byte = fromIntegral . (round ∷ Double → Integer) . max 0 . min 255

-- | Whether a pixel centre lies inside an instance's rectangle.
covers ∷ Instance → (Double, Double) → Bool
covers item (cx, cy) =
  let (left, top, width, height) = instanceRect item
   in cx >= left && cx < left + width && cy >= top && cy < top + height

-- | A sample, and whether linear filtering made it.
data Sampled = Sampled !Double !Double !Double !Double !Bool

-- | The instance's texture sampled at the coordinate its rectangle maps the
-- centre to.
sampleInstance ∷ (FixtureName → Fixture) → TableSampler → Instance → (Double, Double) → Sampled
sampleInstance textureOf sampler item (cx, cy) =
  let (left, top, width, height) = instanceRect item
      UvRect u0 v0 u1 v1 = instanceUv item
      u = u0 + (cx - left) / width * (u1 - u0)
      v = v0 + (cy - top) / height * (v1 - v0)
      texture = textureOf (instanceTexture item)
      w = fromIntegral (fixtureWidth texture)
      h = fromIntegral (fixtureHeight texture)
   in case sampler of
        NearestClamp → nearest texture (floor (u * w)) (floor (v * h))
        NearestRepeat → nearest texture (floor (u * w) `mod` round w) (floor (v * h) `mod` round h)
        LinearClamp → linear texture (u * w - 0.5) (v * h - 0.5)
        LinearRepeat → linear texture (u * w - 0.5) (v * h - 0.5)
  where
    nearest texture tx ty = let Rgba r g b a = texelAt texture tx ty in Sampled (d r) (d g) (d b) (d a) False
    linear texture tx ty =
      let x0 = floor tx
          y0 = floor ty
          wx = tx - fromIntegral x0
          wy = ty - fromIntegral y0
          weighted =
            [ ((1 - wx) * (1 - wy), texelAt texture x0 y0)
            , (wx * (1 - wy), texelAt texture (x0 + 1) y0)
            , ((1 - wx) * wy, texelAt texture x0 (y0 + 1))
            , (wx * wy, texelAt texture (x0 + 1) (y0 + 1))
            ]
          channel pick = sum [weight * d (pick texel) | (weight, texel) ← weighted]
       in Sampled (channel red) (channel green) (channel blue) (channel alpha) True
    d = fromIntegral
    red (Rgba r _ _ _) = r
    green (Rgba _ g _ _) = g
    blue (Rgba _ _ b _) = b
    alpha (Rgba _ _ _ a) = a

-- | Whether an observed pixel is within the expectation's tolerance in every
-- channel.
within ∷ Expectation → Rgba → Bool
within (Expectation (Rgba er eg eb ea) tolerance) (Rgba r g b a) =
  all (\(e, o) → abs (fromIntegral e - fromIntegral o ∷ Int) <= tolerance) [(er, r), (eg, g), (eb, b), (ea, a)]

-- | One probe's outcome.
data ProbeResult = ProbeResult
  { resultProbe ∷ !Probe
  , resultExpected ∷ !Expectation
  , resultObserved ∷ !Rgba
  , resultPassed ∷ !Bool
  }
  deriving (Eq, Show)

-- | Every probe of the scene, drawn with or without the BC7 draw, against a
-- readback of the target.
evaluateProbes ∷ Bool → ByteString → [ProbeResult]
evaluateProbes = evaluateProbesWith fixture

-- | 'evaluateProbes' with each fixture name drawing this texture.
evaluateProbesWith ∷ (FixtureName → Fixture) → Bool → ByteString → [ProbeResult]
evaluateProbesWith textureOf withBc7 bytes =
  [ ProbeResult probe expected observed (within expected observed)
  | probe ← sceneProbes withBc7
  , let expected = expectationWith textureOf withBc7 probe
        observed = pixelAt bytes (probePixel probe)
  ]

probesPassed ∷ [ProbeResult] → Bool
probesPassed results = not (null results) && all resultPassed results

-- | A pixel of a tightly packed RGBA8 readback of the target; transparent
-- black past its end, which no probe passes against a covered pixel.
pixelAt ∷ ByteString → (Int, Int) → Rgba
pixelAt bytes (x, y) = case ByteString.unpack (ByteString.take 4 (ByteString.drop ((y * targetSide + x) * 4) bytes)) of
  [r, g, b, a] → Rgba r g b a
  _ → transparent
