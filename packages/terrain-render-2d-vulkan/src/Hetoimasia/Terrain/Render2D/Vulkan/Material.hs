{-# LANGUAGE TemplateHaskell #-}

-- | The terrain material (TRA-17): the application material the terrain arena's
-- whole-cell quads are drawn with, defined at build time through the 2D renderer's checked
-- material splice (R2D-11, D-5, D-25) and registered by the caller with
-- 'Hetoimasia.Render.TwoD.Vulkan.registerMaterial'.
--
-- It declares:
--
-- * a record of two full handles (the colour atlas and the normal atlas) and
--   'recordWordCount' words, the layout "Hetoimasia.Terrain.Render2D.Material" packs
--   and models;
-- * an application push block of three @vec4@s, 48 bytes, the most the engine leaves
--   (the view's sun and ambient; the effective sun strength, darkening, haze and
--   reciprocal depth range; the haze colour in linear light), as
--   "Hetoimasia.Terrain.Render2D.Presentation" packs them;
-- * that it is cutout-capable, because its output alpha, the colour's alpha times the
--   map's, is binary wherever both are (each is a binary coverage, and both are sampled
--   nearest at a texel centre).
--
-- No descriptor binding, no vertex or instance format and no depth output is
-- added: the quad and its depth key are the engine's, and a texel the colour or the
-- map leaves transparent writes neither colour nor depth.
--
-- Immutable configuration: the declaration. Owner: the build; there is no
-- service, window publisher, global registry or live shader loader. The
-- registered reference belongs to the renderer that issued it, and the caller
-- owns that renderer. Nothing here has a thread, a lifetime or a disposal.
module Hetoimasia.Terrain.Render2D.Vulkan.Material
  ( terrainMaterial
  , terrainMaterialEquivalent
  , terrainMaterialInsetControl
  , terrainMaterialUnbiasedControl
  , terrainMaterialStaleBiasControl
  , terrainMaterialWrongOrderControl
  , lightPush
  ) where

import Hetoimasia.Render.TwoD.Vulkan.Material
import Hetoimasia.Terrain.Render2D.Material (recordLayout)
import Hetoimasia.Terrain.Render2D.Vulkan.Source (lightPush, terrainSource, terrainSourceEquivalent, terrainSourceInsetControl, terrainSourceUnbiasedControl, terrainSourceStaleBiasControl, terrainSourceWrongOrderControl)

-- | The terrain material, cutout-capable, with its checked variants.
terrainMaterial ∷ DefinedMaterial
terrainMaterial =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = True
         , declaredRecord = recordLayout
         , declaredPush = lightPush
         , declaredSource = terrainSource
         }
   )

-- | A second, behaviourally identical material with its own checked variants, so
-- that the renderer issues a second reference: the evidence assigns it to some
-- faces to change the grouping of a plan into runs by material.
terrainMaterialEquivalent ∷ DefinedMaterial
terrainMaterialEquivalent =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = True
         , declaredRecord = recordLayout
         , declaredPush = lightPush
         , declaredSource = terrainSourceEquivalent
         }
   )

-- | A negative control's material, never a terrain material: the same declaration with the
-- half-texel-inset interpolation of the region coordinate, which shifts interior texel boundaries.
-- It exists so the evidence can show its judge rejecting that rule; nothing draws terrain with it.
terrainMaterialInsetControl ∷ DefinedMaterial
terrainMaterialInsetControl =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = True
         , declaredRecord = recordLayout
         , declaredPush = lightPush
         , declaredSource = terrainSourceInsetControl
         }
   )

-- | A negative control's material, never a terrain material: the terrain's own declaration with the
-- texel bias removed from the local index, the rule the Q-13 counterexample was measured under. The
-- evidence shows its judge rejecting it on the exact-boundary fixtures; nothing draws terrain with it.
terrainMaterialUnbiasedControl ∷ DefinedMaterial
terrainMaterialUnbiasedControl =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = True
         , declaredRecord = recordLayout
         , declaredPush = lightPush
         , declaredSource = terrainSourceUnbiasedControl
         }
   )

-- | A negative control's material, never a terrain material: the terrain's own declaration with the
-- first amendment's @1/10000@ bias, measured too small at pixel-snapped zooms 9/8 and 5/4. The
-- evidence shows its judge rejecting it there; nothing draws terrain with it.
terrainMaterialStaleBiasControl ∷ DefinedMaterial
terrainMaterialStaleBiasControl =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = True
         , declaredRecord = recordLayout
         , declaredPush = lightPush
         , declaredSource = terrainSourceStaleBiasControl
         }
   )

-- | A negative control's material, never a terrain material: the terrain's own declaration with the depth
-- effects composed in the wrong order (haze first, then darkening). The evidence shows its judge rejecting it
-- on the depth stack, where both effects are on; nothing draws terrain with it.
terrainMaterialWrongOrderControl ∷ DefinedMaterial
terrainMaterialWrongOrderControl =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = True
         , declaredRecord = recordLayout
         , declaredPush = lightPush
         , declaredSource = terrainSourceWrongOrderControl
         }
   )
