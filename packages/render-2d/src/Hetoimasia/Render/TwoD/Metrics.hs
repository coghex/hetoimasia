-- | A target's metrics: the plain values a view mapping needs to know about the
-- surface it draws to.
--
-- A window observes three things, and the mapping needs all of them: the
-- logical extent (the size window coordinates and the cursor are measured in),
-- the framebuffer extent (the size in pixels) and a per-axis content scale. The
-- caller fills a 'TargetMetrics' from the window layer's observation, copying
-- its fields; this package depends on no window package, so nothing here names
-- one. An offscreen target has no such distinction: 'offscreenMetrics' gives
-- its logical extent equal to its pixel extent and a content scale of 1.
--
-- __Units.__ Extents are whole numbers of pixels, never negative; a zero extent
-- is an ordinary observation (an iconified window reports a zero framebuffer)
-- and not an error, but no window point can be converted on it. A content
-- scale component must be finite and strictly positive. A value that breaks
-- either rule is not refused here, because a metrics value is only data: the
-- mapping built from it in "Hetoimasia.Render.TwoD.Mapping" is refused.
--
-- __Dependencies.__ @base@.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Metrics
  ( TargetMetrics (..)
  , PixelExtent (..)
  , offscreenMetrics
  , validMetrics
  ) where

import Hetoimasia.Render.TwoD.Internal.Check (positiveFinite)

-- | A width and a height in whole pixels. The fields are 'Int', as the window
-- layer reports them, so they can be copied across; a negative one makes the
-- metrics invalid.
data PixelExtent = PixelExtent
  { pixelWidth ∷ !Int
  , pixelHeight ∷ !Int
  }
  deriving stock (Eq, Show)

-- | What a view mapping needs to know about its target.
data TargetMetrics = TargetMetrics
  { metricsLogical ∷ !PixelExtent
  -- ^ The extent window coordinates are measured in.
  , metricsFramebuffer ∷ !PixelExtent
  -- ^ The extent in pixels, in which viewports and mapped positions are
  -- measured.
  , metricsScaleX ∷ !Float
  -- ^ The horizontal content scale, finite and positive.
  , metricsScaleY ∷ !Float
  -- ^ The vertical content scale, finite and positive.
  }
  deriving stock (Eq, Show)

-- | The metrics of an offscreen target of this pixel extent: the same logical
-- extent and a content scale of 1 on both axes.
offscreenMetrics ∷ PixelExtent → TargetMetrics
offscreenMetrics extent = TargetMetrics extent extent 1 1

-- | Whether the metrics are usable: no negative extent, and a finite, positive
-- content scale on both axes. A zero extent is valid.
validMetrics ∷ TargetMetrics → Bool
validMetrics metrics =
  all (>= 0) [lw, lh, fw, fh]
    && positiveFinite (metricsScaleX metrics)
    && positiveFinite (metricsScaleY metrics)
  where
    PixelExtent lw lh = metricsLogical metrics
    PixelExtent fw fh = metricsFramebuffer metrics
