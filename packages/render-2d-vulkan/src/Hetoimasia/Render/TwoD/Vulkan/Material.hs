{-# LANGUAGE TemplateHaskell #-}

-- | Defining an application material (R2D-11, decisions D-5, D-25, D-26, P-6):
-- a Template Haskell splice over a GLSL function of a fixed signature that
-- generates the material's variants and checks them against their interfaces
-- while the application builds.
--
-- > mixMaterial ∷ DefinedMaterial
-- > mixMaterial = $(defineMaterial MaterialDeclaration
-- >   { declaredCutoutCapable = True
-- >   , declaredRecord = RecordLayout 1 1
-- >   , declaredPush = [PushField "strength" PushFloat]
-- >   , declaredSource = unlines
-- >       [ "vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record) {"
-- >       , "    vec4 second = sampleTexture(record.handles[0], uv);"
-- >       , "    return mix(texel, second, pushed.strength);"
-- >       , "}" ] })
--
-- The declaration is evaluated while the module compiles, so a value the splice
-- names must be defined in another module, as for any splice, and the splice
-- needs the shader toolchain's fingerprint the build generates
-- (@tools/vulkan/run.sh@; see the native backend's README). The function's
-- signature, the declarations around it and the layout of the records and the
-- push block are documented in "Hetoimasia.Render.TwoD.Vulkan.MaterialSources".
--
-- = What the splice does
--
-- * It generates the material's /translucent/ variant, for the ordered path, and,
--   only when the material is declared cutout-capable, its /cutout/ variant (D-26).
--   Each variant is the same vertex stage, the same function, and the engine's
--   own wrapping and output: the tint, the brightness, the additive flag's
--   absence of coverage, and the cutout discard. A material replaces the colour
--   alone and cannot omit any of them.
-- * It checks both stages of both variants against interface descriptions it
--   generates from the declaration (GRS-16, D-19): the push-constant block's
--   members, the vertex input, and the descriptor bindings the shader reads,
--   which are the texture table's and, for a material that has records, the
--   storage table's. A shader that declares more, or less, or differently than
--   the declaration fails the build, naming the stage, the splice's position and
--   every mismatch. So does GLSL that does not compile.
-- * It refuses a declaration that is itself wrong: a push block beyond
--   'applicationPushLimit', a record beyond 'maxRecordHandles' handles or
--   'maxRecordWords' words, a member name the shader may not declare or the
--   engine's block already has, or a source with no function named @material@.
--   Each is a compile error naming the problem.
-- * It records the facts a 'DefinedMaterial' carries and registration issues a
--   reference with: whether the material is cutout-capable, its record layout and
--   its push-block size.
--
-- Materials come only from the application's build: there is no live shader
-- loading.
--
-- __Dependencies.__ @base@, @template-haskell@, the native backend's checked
-- shader splices and interface descriptions, @hetoimasia-render-2d@ and this
-- package's material-source module.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Vulkan.Material
  ( -- * Declaring
    MaterialDeclaration (..)
  , PushField (..)
  , PushType (..)
  , PushOffset (..)
  , RecordLayout (..)
  , defineMaterial

    -- * What is defined
  , DefinedMaterial (..)
  , definedPushBytes

    -- * Limits
  , applicationPushOffset
  , applicationPushLimit
  , maxRecordHandles
  , maxRecordWords
  ) where

import Data.List (intercalate)
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShaders (..), checkedFragmentShader, checkedVertexShader)
import Hetoimasia.Render.TwoD.Material (MaterialFacts (..), RecordLayout (..))
import Hetoimasia.Render.TwoD.Vulkan.Layout (applicationPushLimit, applicationPushOffset)
import Hetoimasia.Render.TwoD.Vulkan.MaterialSources
import Hetoimasia.Render.TwoD.Vulkan.ShaderSources (cutoutTail, orderedTail)
import Language.Haskell.TH (Exp, Q)
import Language.Haskell.TH.Syntax (lift)

-- | A material the application's build checked: its declared facts, where each
-- push member sits, and its two variants' shaders. The cutout variant is present
-- exactly when the material is cutout-capable.
data DefinedMaterial = DefinedMaterial
  { definedFacts ∷ !MaterialFacts
  , definedPush ∷ ![PushOffset]
  -- ^ Where each member of the push block sits from the block's start, for a
  -- host to pack the bytes a view holds for the material.
  , definedTranslucent ∷ !CheckedShaders
  , definedCutout ∷ !(Maybe CheckedShaders)
  }
  deriving (Eq, Show)

-- | The size of the material's push block in bytes.
definedPushBytes ∷ DefinedMaterial → Word32
definedPushBytes = factPushBytes . definedFacts

-- | Define a material: generate and check its variants, and record its facts. A
-- declaration or a shader that is wrong fails the build, naming what is. See the
-- module's description.
defineMaterial ∷ MaterialDeclaration → Q Exp
defineMaterial declaration = case declarationProblems declaration of
  problems@(_ : _) →
    fail
      ( intercalate
          "\n"
          ("the material's declaration is refused:" : map ("    " <>) problems)
      )
  [] → do
    translucent ← variant orderedTail
    cutout ←
      if declaredCutoutCapable declaration
        then (\shaders → [|Just $(pure shaders)|]) <$> variant cutoutTail
        else pure [|Nothing|]
    [|
      DefinedMaterial
        (MaterialFacts $(lift (declaredCutoutCapable declaration)) (RecordLayout $(lift handles) $(lift wordCount)) $(lift (laidBytes laid)))
        $(lift (laidOffsets laid))
        $(pure translucent)
        $(cutout)
      |]
  where
    laid = layOut (declaredPush declaration)
    RecordLayout handles wordCount = declaredRecord declaration
    variant tailSource = do
      vertex ← checkedVertexShader (materialVertexInterface laid) (materialVertexSource laid)
      fragment ← checkedFragmentShader (materialFragmentInterface (declaredRecord declaration) laid) (materialFragmentSource declaration laid tailSource)
      [|CheckedShaders $(pure vertex) $(pure fragment)|]
