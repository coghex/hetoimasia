-- | The sample's drawing as a @render-2d@ snapshot (R2D-8): the PNG in a world
-- layer, the KTX2 image beside it, and the PNG again in a UI layer at a fixed
-- logical size.
--
-- One view covers the target, with the camera at the world origin at one pixel
-- per world unit, so the world copies are 64 pixels square whatever the
-- display; the UI copy is 48 logical pixels, which the view's UI scale and the
-- window's content scale multiply, so it has one physical size on any display
-- and the @--ui-scale@ option changes it. The world copies are centred on the
-- target and the UI copy sits at the upper left.
--
-- The same layers are drawn into a window ('WindowTarget') or into an
-- offscreen target of the evidence ('OffscreenTarget'); only the pass's target
-- differs.
module Hetoimasia.Sample.Image2d.Scene
  ( Handles (..)
  , Layout (..)
  , evidenceLayout
  , evidenceMetrics
  , snapshotFor
  , uiLogicalSize
  ) where

import Data.Word (Word32)
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot

-- | The textures the scene draws.
data Handles = Handles
  { handlePng ∷ !TextureHandle
  , handleKtx2 ∷ !TextureHandle
  }

-- | What the snapshot is built for: the target's pixel extent, which the
-- view's viewport spans, and the UI scale.
data Layout = Layout
  { layoutFramebuffer ∷ !(Word32, Word32)
  , layoutUiScale ∷ !Float
  }
  deriving (Eq, Show)

-- | The evidence frame: a 256×256 target, UI scale 1.
evidenceLayout ∷ Layout
evidenceLayout = Layout (256, 256) 1

-- | The metrics the evidence frame is drawn and judged under: logical extent
-- 128×128, framebuffer 256×256, content scale 2 on both axes.
evidenceMetrics ∷ TargetMetrics
evidenceMetrics = TargetMetrics (PixelExtent 128 128) (PixelExtent 256 256) 2 2

-- | The UI copy's side, in logical pixels.
uiLogicalSize ∷ Float
uiLogicalSize = 48

-- | The snapshot: one pass over this target, cleared to opaque black, with
-- one view and a world layer and a UI layer.
snapshotFor ∷ Target → Handles → Layout → Snapshot
snapshotFor target handles layout =
  Snapshot [Pass target (ClearColour 0 0 0 1) [view]]
  where
    (width, height) = layoutFramebuffer layout
    view =
      View
        { viewCamera = Camera (V2 0 0) 1 Nothing
        , viewViewport = Viewport (V2 0 0) (V2 (fromIntegral width) (fromIntegral height))
        , viewSettings = defaultViewSettings {settingUiScale = layoutUiScale layout}
        , viewClips = []
        , viewLayers =
            [ WorldLayer DepthDisabled [sprite (handlePng handles) (-80, 0) 64, sprite (handleKtx2 handles) (16, 0) 64]
            , UiLayer [sprite (handlePng handles) (8, 8) uiLogicalSize]
            ]
        }

-- | A square sprite of this side with its origin at this position, whole
-- texture, no tint.
sprite ∷ TextureHandle → (Float, Float) → Float → Instance
sprite handle (x, y) side =
  Instance
    { instanceTransform = fromColumns (V2 side 0) (V2 0 side) (V2 x y)
    , instanceUv = UvRect 0 0 1 1
    , instanceTexture = handle
    , instanceDepthKey = 0
    , instanceTint = Tint 255 255 255 255
    , instanceSampler = SamplerDefault
    , instanceTranslucent = False
    , instanceAdditive = False
    , instanceClip = 0
    , instanceMaterial = 0
    }
