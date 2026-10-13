{-# LANGUAGE RecordWildCards #-}

-- | Builders and generators the render-2d component specs share.
--
-- __Builders.__ A plain instance, view and pass, each valid, so an example
-- changes exactly the one component it is about and every other one stays
-- accepted.
--
-- __Generated domain.__ Ordinary generated floats lie in @[−1e6, 1e6]@, depth
-- keys in @[0, 2²⁴ − 1]@, and every other field takes its whole range, with
-- the clip index zero because a non-zero one is refused. The wild generator is
-- the opposite: it reaches NaN, both infinities, signed zeros, the largest
-- finite values and subnormals, and is used only where the contract is that
-- validation answers, deterministically, whatever it is given.
module Test.Render.TwoD.Support
  ( -- * Builders
    plainInstance
  , plainCamera
  , plainViewport
  , plainView
  , plainPass
  , offscreen
  , windowPass
  , snapshotWithInstance
  , snapshotWithView
  , snapshotWithPass
  , refusalsOf
  , validLayerOf
  , singleLayer

    -- * Generators
  , validInstance
  , anyInstance
  , validLayerGen
  , validSnapshotGen
  , wildFloat
  , float
  ) where

import Data.Either (fromRight)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Hetoimasia.Math.Affine2 (Affine2, fromColumns, identity)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Material (defaultMaterial)
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), ZoomMode (..), defaultViewSettings, TextureFilter (..))
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation
  ( Refusal
  , ValidLayer
  , validLayers
  , validateSnapshot
  )
import Test.QuickCheck
  ( Gen
  , arbitrary
  , choose
  , elements
  , frequency
  , listOf
  , oneof
  , resize
  )

-- | A valid instance with every default: the identity placement, the whole
-- texture, handle (1, 1), depth key 0, an opaque white tint, the default
-- sampler, no flags, no clip and material word 0.
plainInstance ∷ Instance
plainInstance =
  Instance
    { instanceTransform = identity
    , instanceUv = UvRect 0 0 1 1
    , instanceTexture = textureHandle 1 1
    , instanceDepthKey = 0
    , instanceTint = Tint 255 255 255 255
    , instanceSampler = SamplerDefault
    , instanceTranslucent = False
    , instanceAdditive = False
    , instanceClip = 0
    , instanceParameter = 0
    , instanceMaterial = defaultMaterial
    }

-- | A camera at the origin with zoom 1 and no rotation.
plainCamera ∷ Camera
plainCamera = Camera (V2 0 0) 1 Nothing

-- | A 640 × 480 viewport at the origin.
plainViewport ∷ Viewport
plainViewport = Viewport (V2 0 0) (V2 640 480)

-- | A view of the plain camera and viewport, the default settings and these
-- layers.
plainView ∷ [Layer] → View
plainView = View plainCamera plainViewport defaultViewSettings

-- | A pass with an opaque black clear.
plainPass ∷ Target → [View] → Pass
plainPass target = Pass target (ClearColour 0 0 0 1)

-- | An offscreen target, by index.
offscreen ∷ Int → Target
offscreen index = OffscreenTarget (targetRef (fromIntegral index) 1)

-- | A pass drawing into the window.
windowPass ∷ [View] → Pass
windowPass = plainPass WindowTarget

-- | A snapshot of one window pass, one view and one world layer holding the
-- instance.
snapshotWithInstance ∷ Instance → Snapshot
snapshotWithInstance candidate =
  snapshotWithView (plainView [WorldLayer DepthEnabled [candidate]])

-- | A snapshot of one window pass holding the view.
snapshotWithView ∷ View → Snapshot
snapshotWithView view = Snapshot [windowPass [view]]

-- | A snapshot of the pass alone.
snapshotWithPass ∷ Pass → Snapshot
snapshotWithPass pass = Snapshot [pass]

-- | Every refusal validation reports, in its order; empty when it accepts.
refusalsOf ∷ Snapshot → [Refusal]
refusalsOf = either NonEmpty.toList (const []) . validateSnapshot

-- | The validated form of a layer, when validation accepts it.
validLayerOf ∷ Layer → Either (NonEmpty Refusal) ValidLayer
validLayerOf layer =
  validateSnapshot (snapshotWithView (plainView [layer])) >>= \valid →
    case validLayers valid of
      first : _ → Right first
      [] → Left (error "a snapshot of one layer validated to no layers")

-- | The one validated layer of a snapshot built from this layer; a layer the
-- caller knows is valid.
singleLayer ∷ Layer → ValidLayer
singleLayer layer = fromRight (error "the layer was refused") (validLayerOf layer)

-- | A finite float in the ordinary domain.
float ∷ Gen Float
float = choose (-1.0e6, 1.0e6)

-- | A float anywhere in the range: NaN, infinities, signed zeros, the largest
-- and smallest magnitudes, and ordinary values.
wildFloat ∷ Gen Float
wildFloat =
  frequency
    [ (3, arbitrary)
    , (2, float)
    , ( 4
      , elements
          [ 0
          , -0
          , 1
          , -1
          , 0.5
          , 4
          , 3
          , 1.0e-45
          , 3.4028235e38
          , -3.4028235e38
          , 1 / 0
          , -1 / 0
          , 0 / 0
          ]
      )
    ]

affine ∷ Gen Affine2
affine = fromColumns <$> v2 <*> v2 <*> v2
  where
    v2 = V2 <$> float <*> float

uv ∷ Gen UvRect
uv = UvRect <$> float <*> float <*> float <*> float

-- | A valid instance: finite values, a depth key below 2²⁴ and no clip.
validInstance ∷ Gen Instance
validInstance = do
  instanceTransform ← affine
  instanceUv ← uv
  instanceTexture ← textureHandle <$> arbitrary <*> arbitrary
  instanceDepthKey ← choose (0, depthKeyLimit - 1)
  instanceTint ← Tint <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
  instanceSampler ← elements [minBound .. maxBound]
  instanceTranslucent ← arbitrary
  instanceAdditive ← arbitrary
  instanceParameter ← arbitrary
  pure Instance {instanceClip = 0, instanceMaterial = defaultMaterial, ..}

-- | An instance whose every field takes its whole range, including a clip
-- index and a depth key beyond the limit. For the flags word and the encoder's
-- layout, not for validation.
anyInstance ∷ Gen Instance
anyInstance = do
  base ← validInstance
  clip ← arbitrary
  key ← arbitrary
  pure base {instanceClip = clip, instanceDepthKey = key}

-- | A layer of valid instances.
validLayerGen ∷ Gen Layer
validLayerGen = do
  instances ← resize 6 (listOf validInstance)
  oneof
    [ WorldLayer <$> elements [minBound .. maxBound] <*> pure instances
    , pure (UiLayer instances)
    ]

-- | A valid snapshot of up to three passes, ending in a window pass half the
-- time, each with up to three views of up to three layers.
validSnapshotGen ∷ Gen Snapshot
validSnapshotGen = do
  count ← choose (0, 3)
  withWindow ← arbitrary
  offscreenPasses ← mapM (\index → pass (offscreen index)) [0 .. count - 1]
  windowPasses ← if withWindow then (: []) <$> pass WindowTarget else pure []
  pure (Snapshot (offscreenPasses <> windowPasses))
  where
    pass target = do
      clear ← ClearColour <$> unit <*> unit <*> unit <*> unit
      views ← resize 3 (listOf view)
      pure (Pass target clear views)
    unit = choose (0, 1)
    view = do
      camera ← Camera <$> (V2 <$> float <*> float) <*> choose (0.01, 100) <*> oneof [pure Nothing, Just <$> float]
      viewport ← Viewport <$> (V2 <$> float <*> float) <*> (V2 <$> choose (0, 4096) <*> choose (0, 4096))
      settings ← settings'
      layers ← resize 3 (listOf validLayerGen)
      pure (View camera viewport settings layers)
    settings' = do
      scale ← choose (0.5, 4)
      snap ← arbitrary
      filtering ← elements [FilterNearest, FilterLinear]
      brightness ← choose (0.5, 3)
      zoom ← oneof [pure PixelsPerUnit, FixedHalfHeight <$> choose (0.01, 1000)]
      pure (ViewSettings scale snap filtering brightness zoom)
