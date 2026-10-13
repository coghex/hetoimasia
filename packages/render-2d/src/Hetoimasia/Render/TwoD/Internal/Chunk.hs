-- | The representation of a retained chunk (R2D-10): what validation resolves a
-- reference to, what the draw plan and the encoder read, and what a backend
-- uploads.
--
-- __Ownership.__ A hidden module of @hetoimasia-render-2d@. The public
-- "Hetoimasia.Render.TwoD.Chunk" builds a 'Chunk' and exports it abstractly;
-- validation imports this module to resolve references, and the plan, the
-- encoder and the oracle read a chunk through the public module's accessors.
--
-- __Dependencies.__ @base@, @array@, @containers@, @hetoimasia-math@,
-- @hetoimasia-render-api@ and this package's snapshot, material and
-- chunk-reference modules.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Internal.Chunk
  ( ChunkKind (..)
  , layerChunkKind
  , Bounds (..)
  , Chunk (..)
  , Chunks (..)
  ) where

import Data.Array (Array)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Hetoimasia.Math.Vector (V2)
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Internal.ChunkRef (ChunkRef)
import Hetoimasia.Render.TwoD.Internal.Material (MaterialRecord, MaterialRef)
import Hetoimasia.Render.TwoD.Snapshot (Instance, Layer (..), LayerDepth (..))

-- | The one kind of layer a chunk is built for.
data ChunkKind
  = -- | A world layer with depth enabled: the only kind whose instances can take
    -- the cutout path.
    ChunkWorldDepth
  | -- | A world layer without depth.
    ChunkWorldFlat
  | -- | A UI layer.
    ChunkUi
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The kind of chunk a layer takes.
layerChunkKind ∷ Layer → ChunkKind
layerChunkKind = \case
  WorldLayerWith DepthEnabled _ _ → ChunkWorldDepth
  WorldLayerWith DepthDisabled _ _ → ChunkWorldFlat
  UiLayerWith _ _ → ChunkUi

-- | An axis-aligned rectangle in a layer's space: its lower and its upper
-- corner, componentwise. Y points down, so the lower corner is the upper left.
data Bounds = Bounds
  { boundsMin ∷ !V2
  , boundsMax ∷ !V2
  }
  deriving stock (Eq, Show)

-- | A built chunk: immutable, and with no native handle in it.
data Chunk = Chunk
  { chunkKindField ∷ !ChunkKind
  , chunkBoundsField ∷ !Bounds
  , chunkInstanceArray ∷ !(Array Int Instance)
  -- ^ Every instance, in the order the application gave them: its build order.
  , chunkCutoutOrder ∷ ![Int]
  -- ^ The build positions of the instances routed to the cutout path, in the
  -- order the chunk's device buffer holds them: by material and then by build
  -- position.
  , chunkOrderedOrder ∷ ![Int]
  -- ^ The build positions of the instances routed to the ordered path, by
  -- ascending depth key and then build position.
  , chunkTextureSet ∷ !(Set TextureHandle)
  -- ^ Every texture any instance names, and every handle any record holds.
  , chunkRecordTables ∷ !(Map MaterialRef [MaterialRecord])
  -- ^ The chunk's own records for each application material (R2D-11, D-31),
  -- which its instances' parameter words index.
  , chunkMaterialSet ∷ !(Set MaterialRef)
  -- ^ Every material any instance names.
  , chunkMagnitudeField ∷ !Double
  -- ^ The largest magnitude any term of placing an instance reaches:
  -- @max (|a| + |c| + |tx|) (|b| + |d| + |ty|)@ over the instances (the unit
  -- square's coordinates being at most 1). The 32-bit arithmetic that places an
  -- instance rounds at the size of these terms, however little of them is left
  -- in the result.
  }
  deriving stock (Eq, Show)

-- | A set of chunks by the reference each was issued under. Resolution is
-- exact: a reference of another generation finds nothing, so a stale reference
-- never reaches rebuilt content.
newtype Chunks = Chunks (Map ChunkRef Chunk)
  deriving stock (Eq, Show)
