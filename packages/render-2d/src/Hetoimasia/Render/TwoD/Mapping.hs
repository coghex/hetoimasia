-- | The pure mapping of one view between window, framebuffer, UI and world
-- space, shared by drawing and by picking.
--
-- 'viewMapping' builds a 'ViewMapping' from a target's 'TargetMetrics' and a
-- 'View'. The value holds the view's world and UI affine transforms to target
-- pixels with their inverses, and the window-to-framebuffer ratio. It knows the
-- logical size, the framebuffer size and the content scale; nothing in it is
-- read from a window.
--
-- __Spaces and units.__ Y points down in every space. /World/ space is in game
-- units. /UI/ space is in logical pixels from the upper left. /Target pixels/
-- are the pixels of the target's framebuffer (or of an offscreen target), with
-- the origin at the upper left; a viewport is a rectangle of target pixels, and
-- every mapped position is in them. /Window/ points are in the logical extent's
-- coordinates, as a cursor position is. Converting target pixels to Vulkan clip
-- space belongs to the recorder, not here.
--
-- __World equation.__ Let @C@ be the viewport's centre, @p@ the camera
-- position, @θ@ its rotation in radians (0 when there is none) and @s@ the
-- uniform scale on both axes:
--
-- > target = C + s · R(−θ) · (world − p)
-- > s = zoom                       pixels per world unit
-- > s = viewportHeight · zoom / (2 · h)   fixed half-height h
--
-- so the camera's position appears at the viewport's centre, and in pixels per
-- world unit a unit of world spans @zoom@ pixels. In fixed-half-height mode
-- half the viewport's height spans @h ÷ zoom@ world units, so the same vertical
-- extent of world is visible at any resolution; the horizontal extent follows
-- the viewport's aspect ratio, so the same total area is visible only while the
-- aspect ratio is unchanged. @R(φ)@ is the rotation by @φ@ in the convention of
-- "Hetoimasia.Math.Affine2": a positive angle takes +X toward +Y, which is
-- clockwise on a Y-down screen. The camera is turned by @θ@ about the
-- viewport's centre, so the target's +X axis points along world
-- @(cos θ, sin θ)@ and the world appears turned by @−θ@. A quarter turn
-- (@θ = π/2@) puts world +Y to the right of the centre and world +X above it.
--
-- __UI equation.__ With UI scale @u@ and content scale @(kx, ky)@, independent
-- of the camera:
--
-- > target = viewportOrigin + uiPoint · (u · kx, u · ky)      per axis
--
-- so a UI element has the same physical size on any display.
--
-- __Window equation.__ A window point maps to a framebuffer pixel by the ratio
-- of the framebuffer extent to the logical extent, per axis, and content scale
-- plays no part:
--
-- > framebuffer = window · framebufferExtent / logicalExtent    per axis
--
-- 'windowToWorld' and 'windowToUi' compose this with the inverse transforms, and
-- 'worldToWindow' and 'uiToWindow' go back.
--
-- __Pixel snap.__ When the view's pixel snap is on, the world transform's
-- translation, which is the camera's, is rounded to the device pixel grid with
-- 'snapPixel'. The UI transform stays the continuous equation above, with the
-- viewport's origin as it is: UI snaps in device pixels through the rounding of
-- UI /instance/ origins, which is 'snapPoint', exposed separately. Every inverse
-- is the inverse of the transform drawing uses, with its snapped translation
-- where it has one, subject to floating-point rounding: it is calculated in
-- double precision from that transform's 32-bit coefficients and rounded to
-- 32-bit ones, so it inverts what the transform holds to within that rounding and
-- not exactly. No result is snapped to the pixel grid, so picking uses the
-- transform drawing uses and not a snapped variant of it. The per-instance
-- origin rounding the recorder later applies rigidly in the shader is
-- 'snapPoint' too: a consumer reproduces a snapped sprite's origin as
-- @snapPoint (worldToTarget m origin)@ or @snapPoint (uiToTarget m origin)@, when
-- 'mappingPixelSnap' says the view snaps. For the transform @F@ drawing uses, @|snapPoint (F p) − F p| ≤ 0.5@
-- per axis, which is the whole promise: the unsnapped inverse differs from a
-- snapped sprite's drawn origin by at most half a device pixel per axis. It
-- cannot be measured against a separate transform whose camera translation is
-- not snapped: with the viewport centre at 50, zoom 1, camera position 0.25
-- and an instance origin at 0.5, the ideal position is 50.25, the
-- camera-snapped position 50.5 and the drawn origin 51. With snap on, the
-- camera's position appears within half a pixel of the viewport's centre, and
-- exactly at it with snap off.
--
-- __Float resolution.__ The transforms hold 32-bit coefficients, so a position
-- is only as exact as the coefficients: the translation is the viewport's
-- centre minus the scale times the camera position, and once that product
-- exceeds 2²³ pixels one ulp of it is more than a pixel. The mapping is still
-- finite and still inverts what it holds, to within floating-point rounding, but
-- the camera position then appears at the centre only to that resolution, in
-- either snap setting. The half-pixel promise above is unaffected: it compares
-- a position with its own rounding. A game with such ranges keeps its camera near
-- the origin.
--
-- __Degenerate input.__ Nothing is clamped, and every refusal is 'Nothing':
--
-- * A view that validation would refuse (see 'viewReasons'), and metrics with a
--   negative extent or a content scale that is not finite and positive, give no
--   mapping.
-- * A mapping whose coefficients, or whose inverse for a non-empty viewport,
--   cannot be represented as finite 'Float's gives no mapping: a position of
--   2e38 at zoom 2 overflows, and a subnormal scale has no representable
--   inverse.
-- * A viewport with a zero width or height draws nothing ('viewportIsEmpty'),
--   and its inverse transforms and inverse conversions are 'Nothing'.
-- * A metrics value with a zero logical or framebuffer extent has no window
--   conversion: all of them are 'Nothing', while world and UI conversions
--   still work.
-- * A conversion whose input is not finite, or whose result would overflow, is
--   'Nothing'.
-- * Points outside the viewport still convert; 'viewportContains' says whether
--   a target-pixel point lies inside it.
--
-- No conversion produces a NaN or an infinity. Every function is pure and
-- total. Which instance lies under a point is the game's question.
--
-- __Dependencies.__ @base@, @hetoimasia-math@ for the affine type, and this
-- package's snapshot, settings, metrics and validation modules.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Mapping
  ( -- * The mapping
    ViewMapping
  , viewMapping
  , mappingPixelSnap

    -- * Transforms
  , worldTransform
  , worldInverse
  , uiTransform
  , uiInverse

    -- * World and UI points
  , worldToTarget
  , targetToWorld
  , uiToTarget
  , targetToUi

    -- * Window points
  , windowToTarget
  , targetToWindow
  , windowToWorld
  , worldToWindow
  , windowToUi
  , uiToWindow

    -- * The viewport
  , viewportIsEmpty
  , viewportContains

    -- * Pixel snap
  , snapPixel
  , snapPoint
  ) where

import Control.Monad (guard)
import GHC.Float (double2Float, float2Double)
import Hetoimasia.Math.Affine2 (Affine2, applyPoint, fromColumns, inverse)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Internal.Check (allFinite, finite)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..), validMetrics)
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), ZoomMode (..))
import Hetoimasia.Render.TwoD.Snapshot (Camera (..), View (..), Viewport (..))
import Hetoimasia.Render.TwoD.Validation (viewReasons)

-- | One view's mapping, built by 'viewMapping'. The constructor is private, so
-- every value passed every check above and holds a transform with its inverse.
data ViewMapping = ViewMapping
  { mappingWorld ∷ !Affine2
  , mappingWorldInverse ∷ !(Maybe Affine2)
  , mappingUi ∷ !Affine2
  , mappingUiInverse ∷ !(Maybe Affine2)
  , mappingWindow ∷ !(Maybe WindowRatio)
  , mappingSnap ∷ !Bool
  }
  deriving stock (Eq, Show)

-- | Framebuffer width and height, then logical width and height, all positive.
data WindowRatio = WindowRatio !Double !Double !Double !Double
  deriving stock (Eq, Show)

-- | The mapping of a view on a target, or 'Nothing' for a view or metrics that
-- are refused or whose transform is unrepresentable; see the module header.
viewMapping ∷ TargetMetrics → View → Maybe ViewMapping
viewMapping metrics view = do
  guard (null (viewReasons view) && validMetrics metrics)
  world ← worldAffine view
  ui ← uiAffine metrics view
  worldBack ← invertible empty world
  uiBack ← invertible empty ui
  pure (ViewMapping world worldBack ui uiBack (windowRatio metrics) (settingPixelSnap (viewSettings view)))
  where
    empty = viewportIsEmpty (viewViewport view)

-- | Whether the view snaps to the device pixel grid: whether the world
-- transform's translation is rounded, and whether the recorder rounds instance
-- origins (with 'snapPoint'), in the world and in the UI.
mappingPixelSnap ∷ ViewMapping → Bool
mappingPixelSnap = mappingSnap

-- | The world-to-target transform: a uniform scale, the camera's rotation and
-- the viewport's centre, with the translation snapped when pixel snap is on.
worldTransform ∷ ViewMapping → Affine2
worldTransform = mappingWorld

-- | The inverse of 'worldTransform', subject to floating-point rounding (see
-- "Float resolution" above); 'Nothing' for an empty viewport.
worldInverse ∷ ViewMapping → Maybe Affine2
worldInverse = mappingWorldInverse

-- | The UI-to-target transform: the scale UI scale × content scale, then the
-- viewport's origin. Pixel snap does not change it.
uiTransform ∷ ViewMapping → Affine2
uiTransform = mappingUi

-- | The inverse of 'uiTransform', subject to floating-point rounding (see
-- "Float resolution" above); 'Nothing' for an empty viewport.
uiInverse ∷ ViewMapping → Maybe Affine2
uiInverse = mappingUiInverse

-- | A world point in target pixels.
worldToTarget ∷ ViewMapping → V2 → Maybe V2
worldToTarget = convert . Just . mappingWorld

-- | A target-pixel point as a world point: the continuous inverse, which rounds
-- nothing. 'Nothing' for an empty viewport.
targetToWorld ∷ ViewMapping → V2 → Maybe V2
targetToWorld = convert . mappingWorldInverse

-- | A UI point in target pixels.
uiToTarget ∷ ViewMapping → V2 → Maybe V2
uiToTarget = convert . Just . mappingUi

-- | A target-pixel point as a UI point: the continuous inverse, which rounds
-- nothing. 'Nothing' for an empty viewport.
targetToUi ∷ ViewMapping → V2 → Maybe V2
targetToUi = convert . mappingUiInverse

-- | A window point (a cursor position) in framebuffer pixels: the ratio of the
-- framebuffer extent to the logical extent, per axis. 'Nothing' when either
-- extent has a zero component.
windowToTarget ∷ ViewMapping → V2 → Maybe V2
windowToTarget mapping (V2 x y) = do
  WindowRatio framebufferW framebufferH logicalW logicalH ← mappingWindow mapping
  checked (V2 (ratio x framebufferW logicalW) (ratio y framebufferH logicalH))

-- | A framebuffer pixel as a window point, the inverse of 'windowToTarget'.
targetToWindow ∷ ViewMapping → V2 → Maybe V2
targetToWindow mapping (V2 x y) = do
  WindowRatio framebufferW framebufferH logicalW logicalH ← mappingWindow mapping
  checked (V2 (ratio x logicalW framebufferW) (ratio y logicalH framebufferH))

-- | A window point as a world point.
windowToWorld ∷ ViewMapping → V2 → Maybe V2
windowToWorld mapping point = windowToTarget mapping point >>= targetToWorld mapping

-- | A world point as a window point.
worldToWindow ∷ ViewMapping → V2 → Maybe V2
worldToWindow mapping point = worldToTarget mapping point >>= targetToWindow mapping

-- | A window point as a UI point.
windowToUi ∷ ViewMapping → V2 → Maybe V2
windowToUi mapping point = windowToTarget mapping point >>= targetToUi mapping

-- | A UI point as a window point.
uiToWindow ∷ ViewMapping → V2 → Maybe V2
uiToWindow mapping point = uiToTarget mapping point >>= targetToWindow mapping

-- | Whether the viewport draws nothing: a width or a height that is not
-- positive.
viewportIsEmpty ∷ Viewport → Bool
viewportIsEmpty (Viewport _ (V2 width height)) = not (width > 0 && height > 0)

-- | Whether a target-pixel point lies inside the viewport. The left and top
-- edges are inside and the right and bottom edges are outside, and an empty
-- viewport contains no point. The far edges are computed in double precision.
viewportContains ∷ Viewport → V2 → Bool
viewportContains viewport@(Viewport (V2 ox oy) (V2 width height)) (V2 x y) =
  not (viewportIsEmpty viewport)
    && x >= ox
    && y >= oy
    && float2Double x < float2Double ox + float2Double width
    && float2Double y < float2Double oy + float2Double height

-- | Round to the device pixel grid by @floor (x + 0.5)@, evaluated exactly:
-- halves round up, so @−0.5@ gives 0 and @−1.5@ gives @−1@. Every 'Float' of
-- magnitude 2²³ or more is already a whole number and is returned as it is, so
-- no integer is moved by the rounding of @x + 0.5@; NaN and the infinities are
-- returned unchanged.
snapPixel ∷ Float → Float
snapPixel x
  | not (finite x) = x
  | abs x >= 8388608 = x
  | otherwise = fromIntegral (floor (float2Double x + 0.5) ∷ Int)

-- | 'snapPixel' on both axes: an instance origin in target pixels, rounded.
snapPoint ∷ V2 → V2
snapPoint (V2 x y) = V2 (snapPixel x) (snapPixel y)

-- The world transform, in double precision and rounded once to 'Float'.
worldAffine ∷ View → Maybe Affine2
worldAffine view = affine snaps a b c d tx ty
  where
    snaps = settingPixelSnap (viewSettings view)
    camera = viewCamera view
    V2 positionX positionY = cameraPosition camera
    px = float2Double positionX
    py = float2Double positionY
    Viewport (V2 ox oy) (V2 width height) = viewport
    viewport = viewViewport view
    angle = maybe 0 float2Double (cameraRotation camera)
    zoom = float2Double (cameraZoom camera)
    scale = case settingZoomMode (viewSettings view) of
      PixelsPerUnit → zoom
      FixedHalfHeight half → float2Double height * zoom / (2 * float2Double half)
    -- target = centre + scale · R(−angle) · (world − position)
    a = scale * cos angle
    b = 0 - scale * sin angle
    c = scale * sin angle
    d = scale * cos angle
    tx = float2Double ox + float2Double width / 2 - (a * px + c * py)
    ty = float2Double oy + float2Double height / 2 - (b * px + d * py)

-- The UI transform.
uiAffine ∷ TargetMetrics → View → Maybe Affine2
uiAffine metrics view = affine False kx 0 0 ky (float2Double ox) (float2Double oy)
  where
    settings = viewSettings view
    Viewport (V2 ox oy) _ = viewViewport view
    kx = float2Double (settingUiScale settings) * float2Double (metricsScaleX metrics)
    ky = float2Double (settingUiScale settings) * float2Double (metricsScaleY metrics)

-- Six coefficients rounded to 'Float', refused if any is not finite, with the
-- translation snapped when asked.
affine ∷ Bool → Double → Double → Double → Double → Double → Double → Maybe Affine2
affine snaps a b c d tx ty = do
  guard (allFinite [a', b', c', d', tx', ty'])
  pure (fromColumns (V2 a' b') (V2 c' d') (V2 (snapped tx') (snapped ty')))
  where
    a' = double2Float a
    b' = double2Float b
    c' = double2Float c
    d' = double2Float d
    tx' = double2Float tx
    ty' = double2Float ty
    snapped = if snaps then snapPixel else id

-- The inverse of a transform for a non-empty viewport, which must exist; no
-- inverse for an empty one.
invertible ∷ Bool → Affine2 → Maybe (Maybe Affine2)
invertible empty transform
  | empty = Just Nothing
  | otherwise = Just <$> inverse transform

-- A point through a transform, refused unless both are finite.
convert ∷ Maybe Affine2 → V2 → Maybe V2
convert Nothing _ = Nothing
convert (Just transform) point = do
  guard (isFinitePoint point)
  checked (applyPoint transform point)

checked ∷ V2 → Maybe V2
checked point = point <$ guard (isFinitePoint point)

isFinitePoint ∷ V2 → Bool
isFinitePoint (V2 x y) = allFinite [x, y]

-- One coordinate times a ratio of whole extents, in double precision.
ratio ∷ Float → Double → Double → Float
ratio value numerator denominator = double2Float (float2Double value * numerator / denominator)

windowRatio ∷ TargetMetrics → Maybe WindowRatio
windowRatio metrics = do
  guard (all (> 0) [framebufferW, framebufferH, logicalW, logicalH])
  pure (WindowRatio framebufferW framebufferH logicalW logicalH)
  where
    PixelExtent lw lh = metricsLogical metrics
    PixelExtent fw fh = metricsFramebuffer metrics
    framebufferW = fromIntegral fw
    framebufferH = fromIntegral fh
    logicalW = fromIntegral lw
    logicalH = fromIntegral lh
