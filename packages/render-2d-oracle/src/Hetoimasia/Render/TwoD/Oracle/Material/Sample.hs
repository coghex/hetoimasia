-- | The model of the sample material (R2D-11), which samples a second texture
-- through its record and mixes it with the instance's texel.
--
-- The material's GLSL is "Hetoimasia.Render.TwoD.Vulkan.Material.Sample"'s; this
-- is its model, over the same inputs. They are written to agree, and the
-- evidence compares the device's pixels with this model's. The material
-- declares:
--
-- * a record of one full handle and one 32-bit word: the second texture, and a
--   mixing weight in 255ths;
-- * an application push block of two floats, @strength@ at byte 0 and @bias@ at
--   byte 4;
-- * that it is cutout-capable.
--
-- With @t@ the instance's texel, @s@ the second texture sampled at the same
-- coordinates (a handle the lookup does not hold, such as a released one, is the
-- transparent placeholder), and @w = clamp(strength × word ÷ 255 + bias, 0, 1)@:
--
-- > rgb = mix(t.rgb, s.rgb × t.a, w)
-- > a   = t.a
--
-- so the second texture's colour is weighted by the primary's own coverage, and
-- the alpha is the primary's: the output alpha is binary wherever the primary
-- texture's is, which is what a cutout-capable material promises. A record that
-- does not have the layout leaves the texel as it is.
--
-- __Dependencies.__ @base@ and this package's material module.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Oracle.Material.Sample
  ( mixModel
  , mixWeight
  ) where

import Hetoimasia.Render.TwoD.Material (MaterialRecord (..))
import Hetoimasia.Render.TwoD.Oracle.Material
  ( Colour (..)
  , MaterialInput (..)
  , MaterialModel (..)
  , mixColour
  , pushFloat
  )

-- | The sample material's model.
mixModel ∷ MaterialModel
mixModel = MaterialModel $ \input → case materialRecord input of
  MaterialRecord [handle] [weighted] → do
    let Colour tr tg tb ta = materialTexel input
    Colour sr sg sb _ ← materialSample input handle (materialUv input)
    let covered = Colour (sr * ta) (sg * ta) (sb * ta) ta
        weight = mixWeight (pushFloat (materialPush input) 0) (pushFloat (materialPush input) 4) (fromIntegral weighted)
        Colour mr mg mb _ = mixColour (Colour tr tg tb ta) covered weight
    pure (Colour mr mg mb ta)
  _ → Right (materialTexel input)

-- | @clamp(strength × word ÷ 255 + bias, 0, 1)@.
mixWeight ∷ Double → Double → Double → Double
mixWeight strength bias word = max 0 (min 1 (strength * (word / 255) + bias))
