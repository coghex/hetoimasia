{-# LANGUAGE TemplateHaskell #-}

-- | The terrain material (TRA-8): the application material the terrain arena's
-- faces are drawn with, defined at build time through the 2D renderer's checked
-- material splice (R2D-11, D-5, D-25) and registered by the caller with
-- 'Hetoimasia.Render.TwoD.Vulkan.registerMaterial'.
--
-- It declares:
--
-- * a record of one full handle (the art sheet) and 'recordWordCount' words, the
--   layout "Hetoimasia.Terrain.Render2D.Material" packs and models;
-- * no application push block: everything a face needs is in its record, and the
--   engine's own tint, brightness and cutout wrapping apply as for any material;
-- * that it is cutout-capable, because its output alpha is binary wherever the
--   sheet's is (the mask is a binary coverage, and the adapter's instances sample
--   the sheet nearest).
--
-- No descriptor binding, no vertex or instance format and no depth output is
-- added: the quad and its depth key are the engine's, and a face the mask does
-- not cover writes neither colour nor depth.
--
-- Immutable configuration: the declaration. Owner: the build; there is no
-- service, window publisher, global registry or live shader loader. The
-- registered reference belongs to the renderer that issued it, and the caller
-- owns that renderer. Nothing here has a thread, a lifetime or a disposal.
module Hetoimasia.Terrain.Render2D.Vulkan.Material
  ( terrainMaterial
  ) where

import Hetoimasia.Render.TwoD.Vulkan.Material
import Hetoimasia.Terrain.Render2D.Material (recordLayout)
import Hetoimasia.Terrain.Render2D.Vulkan.Source (terrainSource)

-- | The terrain material, cutout-capable, with its checked variants.
terrainMaterial ∷ DefinedMaterial
terrainMaterial =
  $( defineMaterial
       MaterialDeclaration
         { declaredCutoutCapable = True
         , declaredRecord = recordLayout
         , declaredPush = []
         , declaredSource = terrainSource
         }
   )
