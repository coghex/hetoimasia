-- | The per-view settings: plain data, validated and refused rather than
-- clamped.
--
-- A view carries these beside its camera. UI scale and brightness have closed
-- ranges; a fixed half-height must be positive and finite. A value outside its
-- range is never corrected: "Hetoimasia.Render.TwoD.Validation" refuses the
-- snapshot that holds it and says where. The defaults are UI scale 1.0, pixel
-- snap off, nearest filtering, brightness 100% and pixels per world unit.
--
-- Discrete step zoom is a separate, application-wide setting that is not part
-- of a view: see "Hetoimasia.Render.TwoD.ZoomSteps".
--
-- __Dependencies.__ @base@.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Settings
  ( -- * Per-view settings
    ViewSettings (..)
  , defaultViewSettings
  , TextureFilter (..)
  , ZoomMode (..)

    -- * Ranges
  , uiScaleRange
  , brightnessRange
  ) where

-- | A view's settings.
data ViewSettings = ViewSettings
  { settingUiScale ∷ !Float
  -- ^ The scale applied to UI space, within 'uiScaleRange'.
  , settingPixelSnap ∷ !Bool
  -- ^ Whether the camera's translation and each instance's origin snap to the
  -- device pixel grid.
  , settingFilter ∷ !TextureFilter
  -- ^ The filter an instance's default sampler choice resolves to.
  , settingBrightness ∷ !Float
  -- ^ The view's brightness as a factor, 1.0 being 100%, within
  -- 'brightnessRange'.
  , settingZoomMode ∷ !ZoomMode
  -- ^ How the camera's zoom relates to world units.
  }
  deriving stock (Eq, Show)

-- | The texture filter a default sampler choice resolves to.
data TextureFilter = FilterNearest | FilterLinear
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | How a camera's zoom relates to world units.
data ZoomMode
  = -- | The zoom is pixels per world unit, so enlarging the window shows more
    -- of the world. This is the default.
    PixelsPerUnit
  | -- | The view always spans this many world units from its centre to its top
    -- edge, whatever the resolution. The value must be positive and finite.
    FixedHalfHeight !Float
  deriving stock (Eq, Show)

-- | UI scale 1.0, pixel snap off, nearest filtering, brightness 100% and
-- pixels per world unit.
defaultViewSettings ∷ ViewSettings
defaultViewSettings =
  ViewSettings
    { settingUiScale = 1.0
    , settingPixelSnap = False
    , settingFilter = FilterNearest
    , settingBrightness = 1.0
    , settingZoomMode = PixelsPerUnit
    }

-- | The accepted UI scales, inclusive: 0.5 to 4.0.
uiScaleRange ∷ (Float, Float)
uiScaleRange = (0.5, 4.0)

-- | The accepted brightness factors, inclusive: 0.5 to 3.0, that is 50% to
-- 300%.
brightnessRange ∷ (Float, Float)
brightnessRange = (0.5, 3.0)
