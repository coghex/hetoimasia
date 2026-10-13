{-# LANGUAGE TemplateHaskell #-}

-- | Materials whose records hold only handles, or only words: the splice must
-- generate their record loads (a zero count counts down from nothing, not from
-- the largest 'Word32'), so these are spliced to compile.
module Test.Render.TwoD.Vulkan.Materials.Layouts
  ( handlesOnlyMaterial
  , wordsOnlyMaterial
  ) where

import Hetoimasia.Render.TwoD.Vulkan.Material

-- | One handle and no words: the second texture, mixed in half.
handlesOnlyMaterial ∷ DefinedMaterial
handlesOnlyMaterial =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = True
         , declaredRecord = RecordLayout 1 0
         , declaredPush = []
         , declaredSource =
             unlines
               [ "vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record) {"
               , "    vec4 second = sampleTexture(record.handles[0], uv);"
               , "    return vec4(mix(texel.rgb, second.rgb * texel.a, 0.5), texel.a);"
               , "}"
               ]
         }
   )

-- | No handle and one word: the word brightens the texel.
wordsOnlyMaterial ∷ DefinedMaterial
wordsOnlyMaterial =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = False
         , declaredRecord = RecordLayout 0 1
         , declaredPush = []
         , declaredSource =
             unlines
               [ "vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record) {"
               , "    return vec4(texel.rgb * (float(record.words[0]) / 255.0), texel.a);"
               , "}"
               ]
         }
   )
