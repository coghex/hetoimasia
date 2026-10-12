-- | A window's frame as a plain value: the candidate snapshot game code builds.
--
-- A snapshot is an ordered list of passes. A pass names its target, its clear
-- and its ordered views; a view is a camera, a viewport within the target, its
-- per-view settings and its ordered layers; a layer declares its space and
-- holds its instances in submission order. The window's pass comes last. Nothing
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
-- __Dependencies.__ @base@, @hetoimasia-math@ for the camera's position and the
-- instance's transform, @hetoimasia-render-api@ for the texture handle, and
-- this package's settings and target modules.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Snapshot
  ( -- * The frame
    Snapshot (..)
  , Pass (..)
  , Target (..)
  , ClearColour (..)

    -- * Views
  , View (..)
  , Viewport (..)
  , Camera (..)

    -- * Layers
  , Layer (..)
  , LayerDepth (..)
  , layerInstances

    -- * Instances
  , Instance (..)
  , UvRect (..)
  , Tint (..)
  , Sampler (..)
  , depthKeyLimit
  ) where

import Data.Word (Word16, Word32, Word8)
import Hetoimasia.Math.Affine2 (Affine2)
import Hetoimasia.Math.Vector (V2)
import Hetoimasia.Render.Api.Texture (TextureHandle)
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

-- | A camera, the part of the target it draws to, its settings and its layers.
data View = View
  { viewCamera ∷ !Camera
  , viewViewport ∷ !Viewport
  , viewSettings ∷ !ViewSettings
  , viewLayers ∷ [Layer]
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

-- | A layer's instances in submission order, in the space the layer declares.
data Layer
  = -- | World space, in game units through the view's camera, with depth
    -- enabled or not.
    WorldLayer !LayerDepth [Instance]
  | -- | UI space, in logical pixels from the upper left.
    UiLayer [Instance]
  deriving stock (Eq, Show)

-- | Whether a world layer is depth-tested.
data LayerDepth = DepthEnabled | DepthDisabled
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The instances of a layer, in submission order.
layerInstances ∷ Layer → [Instance]
layerInstances (WorldLayer _ instances) = instances
layerInstances (UiLayer instances) = instances

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
  -- ^ A clip index, 0 meaning none. A non-zero index is refused until clip
  -- tables exist.
  , instanceMaterial ∷ !Word32
  -- ^ The material parameter word.
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
