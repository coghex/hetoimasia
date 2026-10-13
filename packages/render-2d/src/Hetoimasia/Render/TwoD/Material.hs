-- | An application material's reference and what a view holds for it (R2D-11,
-- decisions D-5, D-25, P-6).
--
-- A material is a fragment function an application defines and checks at build
-- time ("Hetoimasia.Render.TwoD.Vulkan.Material" is the renderer's splice); the
-- engine owns the vertex stage, the instance format and the table bindings, and
-- wraps the material's colour in tint, brightness and the cutout discard or the
-- blend output, so no material can omit them. This module is the pure side of
-- it: the reference an instance names a material by, and the facts the planner
-- and validation read from the reference without any GPU package.
--
-- = The reference
--
-- A 'MaterialRef' carries an opaque identity a backend chose and the material's
-- declared facts ('MaterialFacts'): whether it is cutout-capable, the layout of
-- its records and the size of its push block. Game code can compare and show a
-- reference and read its facts. It cannot construct one, nor rewrite a fact of
-- one: the type is exported without its constructor or a field.
-- "Hetoimasia.Render.TwoD.Material.Backend" builds one from an identity and
-- facts, for the backend that registers materials and for a test that stands in
-- for it. 'defaultMaterial' is the built-in material's reference, a constant:
-- cutout-capable, an empty record and no push block. An instance names it unless
-- it says otherwise, and it needs neither a record nor a push block in its view.
--
-- = Records and push blocks
--
-- A material's record has a fixed layout, the 'RecordLayout' its reference
-- declares: a number of full texture handles, then a number of 32-bit words. A
-- view holds, for each material it uses, the material's records and the bytes of
-- its push block ('MaterialData'); an instance's parameter word indexes the
-- records its view holds for the instance's material, and a retained chunk
-- carries records of its own for its instances. A material whose layout is empty
-- has no records, and its instances' parameter words index nothing: they reach
-- the material as plain values, as the built-in default's are ignored.
--
-- Every handle in a record is a full handle, lookup index and generation, and
-- resolves through the texture table's lookup with its generation check, so a
-- handle released and reused samples the transparent placeholder.
--
-- __Dependencies.__ @base@, @bytestring@, @hetoimasia-render-api@ and the
-- package's hidden representation module.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Material
  ( -- * References
    MaterialRef
  , defaultMaterial
  , materialFacts
  , materialCutoutCapable
  , materialRecordLayout
  , materialPushBytes

    -- * Declared facts
  , MaterialFacts (..)
  , RecordLayout (..)
  , recordLayoutIsEmpty
  , recordLayoutBytes

    -- * What a view holds
  , MaterialRecord (..)
  , MaterialData (..)
  , noMaterialData
  ) where

import Data.Word (Word32)
import Hetoimasia.Render.TwoD.Internal.Material
  ( MaterialData (..)
  , MaterialFacts (..)
  , MaterialRecord (..)
  , MaterialRef (..)
  , RecordLayout (..)
  , defaultMaterial
  , recordLayoutBytes
  , recordLayoutIsEmpty
  )
import qualified Data.ByteString as ByteString

-- | The facts the material declared.
materialFacts ∷ MaterialRef → MaterialFacts
materialFacts = materialRefFacts

-- | Whether the material routes to the cutout path: its output alpha is binary
-- wherever its primary texture's is.
materialCutoutCapable ∷ MaterialRef → Bool
materialCutoutCapable = factCutoutCapable . materialRefFacts

-- | The layout of the material's records.
materialRecordLayout ∷ MaterialRef → RecordLayout
materialRecordLayout = factRecordLayout . materialRefFacts

-- | The size of the material's push block in bytes; zero for none.
materialPushBytes ∷ MaterialRef → Word32
materialPushBytes = factPushBytes . materialRefFacts

-- | Nothing held: no record and an empty push block.
noMaterialData ∷ MaterialData
noMaterialData = MaterialData [] ByteString.empty
