{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}

-- | A window's frame as a plain value: the candidate snapshot game code builds.
--
-- A snapshot is an ordered list of passes. A pass names its target, its clear
-- and its ordered views; a view is a camera, a viewport within the target, its
-- per-view settings, its clip table and its ordered layers; a layer declares its
-- space, lists the retained chunks it draws (R2D-10) and holds its dynamic instances in
-- submission order. The window's pass comes last. A view also holds, for each
-- application material (R2D-11) its instances use, the material's records and
-- the bytes of its push block, and, for animation (R2D-18), its frame tables
-- and its animation time. Nothing
-- here is a native handle, and nothing is checked on construction: the
-- constructors are public because a candidate is only data, and
-- "Hetoimasia.Render.TwoD.Validation" is what turns one into a value the
-- encoder accepts.
--
-- __Conventions.__ Y points down everywhere: in world space, in UI space (in
-- logical pixels from the upper left), in texture coordinates and in clip space.
-- World positions are 32-bit floats in game units. A depth key is an unsigned
-- integer below 'depthKeyLimit', and a larger key is nearer.
--
-- __Dependencies.__ @base@, @containers@ for a view's materials,
-- @hetoimasia-math@ for the camera's position and the instance's transform,
-- @hetoimasia-render-api@ for the texture handle, and this package's clip,
-- material, settings, target and chunk-reference modules.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Snapshot
  ( -- * The frame
    Snapshot (..)
  , Pass (..)
  , Target (..)
  , ClearColour (..)

    -- * Views
  , View (ViewWith, View, viewCamera, viewViewport, viewSettings, viewClips, viewMaterials, viewFrameTables, viewAnimationTime, viewLayers)
  , FrameTable (..)
  , Viewport (..)
  , Camera (..)

    -- * Layers
  , Layer (WorldLayerWith, UiLayerWith, WorldLayer, UiLayer)
  , LayerDepth (..)
  , layerInstances
  , layerChunks

    -- * Instances
  , Instance (..)
  , UvRect (..)
  , Tint (..)
  , Sampler (..)
  , depthKeyLimit
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word16, Word32, Word8)
import Hetoimasia.Math.Affine2 (Affine2)
import Hetoimasia.Math.Vector (V2)
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Clip (ClipEntry)
import Hetoimasia.Render.TwoD.Internal.ChunkRef (ChunkRef)
import Hetoimasia.Render.TwoD.Internal.Material (MaterialData, MaterialRef)
import Hetoimasia.Render.TwoD.Settings (ViewSettings)
import Hetoimasia.Render.TwoD.Target (TargetRef)

-- | A window's frame: its passes in the order they run. The window's pass, if
-- there is one, is last, and there is at most one.
newtype Snapshot = Snapshot
  { snapshotPasses ∷ [Pass]
  }
  deriving stock (Eq, Show)

-- | One pass: what it draws into, how it starts and which views it draws.
data Pass = Pass
  { passTarget ∷ !Target
  , passClear ∷ !ClearColour
  , passViews ∷ [View]
  }
  deriving stock (Eq, Show)

-- | What a pass draws into.
data Target
  = -- | The window the snapshot is published to.
    WindowTarget
  | -- | An offscreen target a backend owns, named by an opaque reference.
    OffscreenTarget !TargetRef
  deriving stock (Eq, Show)

-- | A pass's clear colour: red, green, blue and alpha, each in [0, 1].
data ClearColour = ClearColour !Float !Float !Float !Float
  deriving stock (Eq, Show)

-- | A camera, the part of the target it draws to, its settings, its clip table,
-- the data it holds for the application materials its instances use, its frame
-- tables and animation time, and its layers.
--
-- The clip table is ordered: entry @i@ is the one an instance with clip index
-- @i + 1@ selects, and a layer's instances can reference only their own view's
-- table ("Hetoimasia.Render.TwoD.Clip"). An empty table is a view whose
-- instances all have clip index 0.
--
-- 'viewMaterials' holds, for each application material (R2D-11), its records,
-- which the parameter words of the view's instances index, and the bytes of its
-- push block. A material the view holds nothing for has no record and an empty
-- push block, which is all the built-in default needs.
--
-- 'viewFrameTables' is the ordered list of frame tables (R2D-18) the view's
-- instances select by index: table @i@ is the one an instance whose frame-table
-- index is @i + 1@ shows, and index 0 means the instance is not animated. An
-- index refers to the tables of the view the instance is drawn in, so a retained
-- chunk drawn in two views shows each view's frames. 'viewAnimationTime' is the
-- view's time in seconds, which every table of the view is read at: a finite,
-- non-negative number, so that a view's frames are determined by its snapshot
-- alone.
--
-- 'View' is the view that holds no material data and no frame table, at
-- animation time 0: as a constructor it builds one, and as a pattern it matches
-- one.
data View = ViewWith
  { viewCamera ∷ !Camera
  , viewViewport ∷ !Viewport
  , viewSettings ∷ !ViewSettings
  , viewClips ∷ [ClipEntry]
  , viewMaterials ∷ !(Map MaterialRef MaterialData)
  , viewFrameTables ∷ [FrameTable]
  , viewAnimationTime ∷ !Double
  , viewLayers ∷ [Layer]
  }
  deriving stock (Eq, Show)

-- | A view holding no data for any material, no frame table, and an animation
-- time of 0.
pattern View ∷ Camera → Viewport → ViewSettings → [ClipEntry] → [Layer] → View
pattern View camera viewport settings clips layers ← ViewWith camera viewport settings clips (Map.null → True) (null → True) ((== 0) → True) layers
  where
    View camera viewport settings clips layers = ViewWith camera viewport settings clips Map.empty [] 0 layers

-- | A frame table (R2D-18): a number of frames, how long each lasts, and the
-- part of the texture each shows. The frame an animated instance shows at a
-- view's time @t@ is @floor (t / duration) mod count@, the quotient being the
-- 'Double' division and the floor an exact integer ("Hetoimasia.Render.TwoD.Animation"),
-- and that frame's rectangle is shown in place of the instance's own.
--
-- The count must be at least 1, the duration finite and positive, the
-- rectangles exactly one for each frame and all finite, and the count times the
-- duration, and the view's time over the duration, finite in 'Double'.
data FrameTable = FrameTable
  { frameTableCount ∷ !Int
  -- ^ How many frames the table cycles through.
  , frameTableDuration ∷ !Double
  -- ^ How long each frame lasts, in seconds.
  , frameTableFrames ∷ [UvRect]
  -- ^ The rectangle of each frame, in order.
  }
  deriving stock (Eq, Show)

-- | A rectangle within the target: its upper-left corner and its extent, both
-- finite and the extent not negative. A zero extent is accepted and draws
-- nothing.
data Viewport = Viewport
  { viewportOrigin ∷ !V2
  , viewportExtent ∷ !V2
  }
  deriving stock (Eq, Show)

-- | A position, a zoom and an optional rotation, with nothing game-specific.
-- The position, the rotation in radians and the zoom must be finite, and the
-- zoom positive.
data Camera = Camera
  { cameraPosition ∷ !V2
  , cameraZoom ∷ !Float
  , cameraRotation ∷ !(Maybe Float)
  }
  deriving stock (Eq, Show)

-- | A layer: the space it declares, the retained chunks it lists in order and
-- its dynamic instances in submission order, in that space.
--
-- A chunk is named by a 'ChunkRef' (R2D-10) and is drawn beside the layer's
-- dynamic instances, in the layer's space and under its rules. A chunk is built
-- for exactly one kind of layer, and validation refuses a layer that lists one
-- built for another. A chunk listed twice is drawn twice, once for each
-- listing, and each listing takes its own place in the layer's order.
--
-- 'WorldLayer' and 'UiLayer' are the layer that lists no chunks: as
-- constructors they build one, and as patterns they match one.
data Layer
  = -- | World space, in game units through the view's camera, with depth
    -- enabled or not: its chunks, then its dynamic instances.
    WorldLayerWith !LayerDepth [ChunkRef] [Instance]
  | -- | UI space, in logical pixels from the upper left: its chunks, then its
    -- dynamic instances.
    UiLayerWith [ChunkRef] [Instance]
  deriving stock (Eq, Show)

-- | A world layer listing no chunks.
pattern WorldLayer ∷ LayerDepth → [Instance] → Layer
pattern WorldLayer depth instances ← WorldLayerWith depth [] instances
  where
    WorldLayer depth instances = WorldLayerWith depth [] instances

-- | A UI layer listing no chunks.
pattern UiLayer ∷ [Instance] → Layer
pattern UiLayer instances ← UiLayerWith [] instances
  where
    UiLayer instances = UiLayerWith [] instances

-- | Whether a world layer is depth-tested.
data LayerDepth = DepthEnabled | DepthDisabled
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The dynamic instances of a layer, in submission order. The instances of its
-- chunks are not among them.
layerInstances ∷ Layer → [Instance]
layerInstances (WorldLayerWith _ _ instances) = instances
layerInstances (UiLayerWith _ instances) = instances

-- | The chunks a layer lists, in the order it lists them.
layerChunks ∷ Layer → [ChunkRef]
layerChunks (WorldLayerWith _ chunks _) = chunks
layerChunks (UiLayerWith chunks _) = chunks

-- | One sprite instance.
data Instance = Instance
  { instanceTransform ∷ !Affine2
  -- ^ Its placement in the layer's space. Every coefficient must be finite.
  , instanceUv ∷ !UvRect
  -- ^ The part of the texture it shows. Every value must be finite.
  , instanceTexture ∷ !TextureHandle
  , instanceDepthKey ∷ !Word32
  -- ^ Below 'depthKeyLimit'; a larger key is nearer.
  , instanceTint ∷ !Tint
  , instanceSampler ∷ !Sampler
  , instanceTranslucent ∷ !Bool
  -- ^ The translucent override.
  , instanceAdditive ∷ !Bool
  , instanceClip ∷ !Word16
  -- ^ A clip index, 0 meaning none. A non-zero index @k@ selects entry @k − 1@
  -- of the view's clip table, and must lie within it.
  , instanceFrameTable ∷ !Word16
  -- ^ A frame-table index (R2D-18), 0 meaning the instance is not animated. A
  -- non-zero index @k@ selects table @k − 1@ of the view the instance is drawn
  -- in, and must lie within it; it is encoded in the flags word's bits 4–15, so
  -- it is at most 4095.
  , instanceParameter ∷ !Word32
  -- ^ The material parameter word, encoded at byte offset 60. It indexes the
  -- records the view (or the chunk) holds for the instance's material, and
  -- reaches the material itself as a value. The built-in default material
  -- ignores it.
  , instanceMaterial ∷ !MaterialRef
  -- ^ The material the instance is drawn with: the built-in default
  -- ('Hetoimasia.Render.TwoD.Material.defaultMaterial') unless an application
  -- material is named. The planner reads it, and it is not encoded: the 64-byte
  -- layout is unchanged.
  }
  deriving stock (Eq, Show)

-- | A texture rectangle: @UvRect u0 v0 u1 v1@, with Y pointing down.
data UvRect = UvRect !Float !Float !Float !Float
  deriving stock (Eq, Show)

-- | A tint: red, green, blue and alpha bytes, a componentwise multiplier.
data Tint = Tint !Word8 !Word8 !Word8 !Word8
  deriving stock (Eq, Ord, Show)

-- | Which sampler an instance asks for. 'SamplerDefault' takes the view's
-- default filter.
data Sampler = SamplerDefault | SamplerNearest | SamplerLinear
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The exclusive upper bound of a depth key, 2²⁴. A key at or above it is
-- refused, never wrapped or collapsed.
depthKeyLimit ∷ Word32
depthKeyLimit = 16777216
