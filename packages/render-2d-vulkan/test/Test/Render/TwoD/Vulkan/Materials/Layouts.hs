{-# LANGUAGE TemplateHaskell #-}

-- | Materials whose records hold only handles, or only words: the splice must
-- generate their record loads (a zero count counts down from nothing, not from
-- the largest 'Word32'), so these are spliced to compile.
module Test.Render.TwoD.Vulkan.Materials.Layouts
  ( handlesOnlyMaterial
  , wordsOnlyMaterial
  , terrainShapedMaterial
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

-- | The terrain material's record layout and push block, with a trivial function (TRA-17): two handles (the colour and
-- the normal parent), thirteen words (the regions and the depth word) and a push block of three @vec4@s. The real
-- terrain material lives in a package that depends on this one, so this package's examples declare a material of the
-- same shape to record frames from the terrain adapter's own records.
terrainShapedMaterial ∷ DefinedMaterial
terrainShapedMaterial =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = True
         , declaredRecord = RecordLayout 2 13
         , declaredPush = [PushField "lightSun" PushVec4, PushField "lightDepth" PushVec4, PushField "lightHaze" PushVec4]
         , declaredSource =
             unlines
               [ "vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record) {"
               , "    vec4 colour = sampleTexture(record.handles[0], uv);"
               , "    vec4 data = sampleTexture(record.handles[1], uv);"
               , "    float depth = float(record.words[12]) * pushed.lightDepth.w;"
               , "    return vec4(colour.rgb * data.a * pushed.lightSun.w * (1.0 - depth), colour.a * data.a);"
               , "}"
               ]
         }
   )
