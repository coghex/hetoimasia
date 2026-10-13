-- | The representation of an application material's reference and of the data a
-- view and a chunk hold for it (R2D-11).
--
-- __Ownership.__ A hidden module of @hetoimasia-render-2d@. The public
-- "Hetoimasia.Render.TwoD.Material" exports the type abstractly and its readers,
-- and "Hetoimasia.Render.TwoD.Material.Backend" builds one; the snapshot, the
-- chunk, validation, planning and encoding import this module for the
-- representation.
--
-- __Dependencies.__ @base@, @bytestring@ and @hetoimasia-render-api@ for the
-- texture handle.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Internal.Material
  ( MaterialRef (..)
  , MaterialFacts (..)
  , RecordLayout (..)
  , MaterialRecord (..)
  , MaterialData (..)
  , defaultMaterialIdentity
  , defaultMaterialFacts
  , defaultMaterial
  , recordLayoutIsEmpty
  , recordLayoutBytes
  , recordMatches
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word32, Word64)
import Hetoimasia.Render.Api.Texture (TextureHandle)

-- | An identity a backend chose and the facts it declared for the material. The
-- facts are part of the value, so two references are equal only when both agree:
-- a reference that carries another material's identity with different facts is
-- another reference.
data MaterialRef = MaterialRef
  { materialRefIdentity ∷ {-# UNPACK #-} !Word64
  , materialRefFacts ∷ !MaterialFacts
  }
  deriving stock (Eq, Ord, Show)

-- | What a material declares about itself, which every reader of a reference
-- may rely on: whether it routes to the cutout path, the layout of its records
-- and the size of its push block.
data MaterialFacts = MaterialFacts
  { factCutoutCapable ∷ !Bool
  -- ^ Its output alpha is binary wherever its primary texture's is, so it may
  -- take the cutout path.
  , factRecordLayout ∷ !RecordLayout
  , factPushBytes ∷ {-# UNPACK #-} !Word32
  -- ^ The size of its application push block in bytes, a multiple of four;
  -- zero for none.
  }
  deriving stock (Eq, Ord, Show)

-- | The fixed layout of a material's records: this many full texture handles,
-- then this many 32-bit words.
data RecordLayout = RecordLayout
  { layoutHandles ∷ {-# UNPACK #-} !Word32
  , layoutWords ∷ {-# UNPACK #-} !Word32
  }
  deriving stock (Eq, Ord, Show)

-- | One record: the full handles it holds, then its words.
data MaterialRecord = MaterialRecord
  { recordHandles ∷ ![TextureHandle]
  , recordWords ∷ ![Word32]
  }
  deriving stock (Eq, Ord, Show)

-- | What a view holds for one material: its records, which the parameter words
-- of its instances index, and the bytes of its push block.
data MaterialData = MaterialData
  { materialRecords ∷ ![MaterialRecord]
  , materialPushBlock ∷ !ByteString
  }
  deriving stock (Eq, Ord, Show)

-- | The identity of the built-in default material, which no backend issues.
defaultMaterialIdentity ∷ Word64
defaultMaterialIdentity = 0

-- | The default material's facts: cutout-capable, an empty record, no push block.
defaultMaterialFacts ∷ MaterialFacts
defaultMaterialFacts = MaterialFacts True (RecordLayout 0 0) 0

-- | The built-in default material.
defaultMaterial ∷ MaterialRef
defaultMaterial = MaterialRef defaultMaterialIdentity defaultMaterialFacts

-- | Whether a layout holds nothing: a material with such a layout has no records,
-- and its parameter word indexes nothing.
recordLayoutIsEmpty ∷ RecordLayout → Bool
recordLayoutIsEmpty (RecordLayout handles wordCount) = handles == 0 && wordCount == 0

-- | The bytes of one record: eight for each handle (its lookup index, then its
-- generation) and four for each word.
recordLayoutBytes ∷ RecordLayout → Word64
recordLayoutBytes (RecordLayout handles wordCount) = 8 * fromIntegral handles + 4 * fromIntegral wordCount

-- | Whether a record has exactly the handles and words a layout declares.
recordMatches ∷ RecordLayout → MaterialRecord → Bool
recordMatches (RecordLayout handles wordCount) (MaterialRecord held values) =
  toInteger (length held) == toInteger handles && toInteger (length values) == toInteger wordCount
