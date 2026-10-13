{-# LANGUAGE TemplateHaskell #-}

-- | The sample material (R2D-11): it samples a second texture through its record
-- and mixes it with the instance's texel. It is the reference an application's
-- own material follows, and the evidence's and the tests' material.
--
-- Its record holds one full handle (the second texture) and one word (a mixing
-- weight in 255ths); its push block is two floats, @strength@ at byte 0 and
-- @bias@ at byte 4. With @t@ the instance's texel, @s@ the second texture sampled
-- at the same coordinates (the transparent placeholder when the record's handle
-- was released or its index reused), and
-- @w = clamp(strength × word ÷ 255 + bias, 0, 1)@:
--
-- > rgb = mix(t.rgb, s.rgb × t.a, w)
-- > a   = t.a
--
-- so the second texture's colour is weighted by the primary's coverage and the
-- alpha is the primary's: the output alpha is binary wherever the primary
-- texture's is, which is what its declared cutout capability promises, and the
-- engine's wrapping applies in both paths. The oracle's model of it is
-- "Hetoimasia.Render.TwoD.Oracle.Material.Sample".
--
-- __Dependencies.__ @base@ and this package's material splice.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Vulkan.Material.Sample
  ( mixMaterial
  , translucentMixMaterial
  , tintOnlyMaterial
  ) where

import Hetoimasia.Render.TwoD.Vulkan.Material

-- | The sample material, cutout-capable.
mixMaterial ∷ DefinedMaterial
mixMaterial =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = True
         , declaredRecord = RecordLayout 1 1
         , declaredPush = [PushField "strength" PushFloat, PushField "bias" PushFloat]
         , declaredSource =
             unlines
               [ "vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record) {"
               , "    vec4 second = sampleTexture(record.handles[0], uv);"
               , "    float weight = clamp(pushed.strength * (float(record.words[0]) / 255.0) + pushed.bias, 0.0, 1.0);"
               , "    return vec4(mix(texel.rgb, second.rgb * texel.a, weight), texel.a);"
               , "}"
               ]
         }
   )

-- | The same function declared not cutout-capable (the weight's sum is written
-- the other way round, which gives the same value and its own SPIR-V): it has no
-- cutout variant and routes to the ordered path whatever its texture says.
translucentMixMaterial ∷ DefinedMaterial
translucentMixMaterial =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = False
         , declaredRecord = RecordLayout 1 1
         , declaredPush = [PushField "strength" PushFloat, PushField "bias" PushFloat]
         , declaredSource =
             unlines
               [ "vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record) {"
               , "    vec4 second = sampleTexture(record.handles[0], uv);"
               , "    float weight = clamp(pushed.bias + pushed.strength * (float(record.words[0]) / 255.0), 0.0, 1.0);"
               , "    return vec4(mix(texel.rgb, second.rgb * texel.a, weight), texel.a);"
               , "}"
               ]
         }
   )

-- | A material with no record and a push block of 16 bytes: it multiplies the
-- texel's colour by one the view's push block gives, and keeps the texel's alpha
-- (so it is cutout-capable). It shows a material that needs
-- nothing from its records, whose parameter word reaches it as a plain value.
tintOnlyMaterial ∷ DefinedMaterial
tintOnlyMaterial =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = True
         , declaredRecord = RecordLayout 0 0
         , declaredPush = [PushField "colour" PushVec4]
         , declaredSource =
             unlines
               [ "vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record) {"
               , "    return vec4(texel.rgb * pushed.colour.rgb, texel.a);"
               , "}"
               ]
         }
   )
