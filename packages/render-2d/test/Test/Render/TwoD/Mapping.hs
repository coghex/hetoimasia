-- | The view mapping: every equation against hand-computed values, round trips
-- within a stated tolerance for generated views and metrics, every combination
-- of pixel snap, zoom mode and smooth or discrete step zoom across resizes and
-- content scales, the half-pixel property, and each degenerate and numeric
-- refusal.
--
-- __Tolerance.__ A round trip goes through 32-bit arithmetic twice, so it is
-- compared within @1e-4 × (1 + m)@, where @m@ is the largest magnitude the
-- calculation held: the point, the camera, the transform's translation and
-- that translation divided by the scale. The generated domain keeps every
-- quantity well inside the range where that is a few thousand ulps at most.
-- Analytic fixtures use exact values where the arithmetic is exact and
-- @1e-3@ where a rotation by a 32-bit @π/2@ is involved.
module Test.Render.TwoD.Mapping (spec) where

import Control.Monad (forM_)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Hetoimasia.Math.Affine2 (toColumnMajor)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Mapping
import Hetoimasia.Render.TwoD.Metrics
import Hetoimasia.Render.TwoD.Settings
import Hetoimasia.Render.TwoD.Snapshot (Camera (..), View (..), Viewport (..))
import Hetoimasia.Render.TwoD.Validation (viewReasons)
import Hetoimasia.Render.TwoD.ZoomSteps (defaultZoomSteps, stepZoomIn, stepZoomOut)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
  ( Gen
  , Property
  , arbitrary
  , choose
  , counterexample
  , cover
  , elements
  , forAll
  , oneof
  , property
  , vectorOf
  , (.&&.)
  , (===)
  )
import Test.Render.TwoD.Support (plainCamera, wildFloat)

spec ∷ Spec
spec = describe "Mapping" $ do
  worldEquations
  uiEquations
  windowEquations
  snapping
  combinations
  degenerate
  numeric
  properties

-- Fixtures ------------------------------------------------------------------

-- | A view with no layers.
viewOf ∷ Camera → Viewport → ViewSettings → View
viewOf camera viewport config = View camera viewport config []

snapSettings ∷ Bool → ZoomMode → ViewSettings
snapSettings snap mode = defaultViewSettings {settingPixelSnap = snap, settingZoomMode = mode}

-- | Metrics of a window whose framebuffer is @ratio@ times its logical extent
-- and whose content scale is as given.
windowMetrics ∷ (Int, Int) → (Int, Int) → (Float, Float) → TargetMetrics
windowMetrics (lw, lh) (fw, fh) (kx, ky) = TargetMetrics (PixelExtent lw lh) (PixelExtent fw fh) kx ky

-- | Metrics of an offscreen target, which has logical extent = pixel extent.
pixels ∷ Int → Int → TargetMetrics
pixels w h = offscreenMetrics (PixelExtent w h)

mapping ∷ TargetMetrics → View → ViewMapping
mapping metrics view = fromMaybe (error ("no mapping for " <> show (metrics, view))) (viewMapping metrics view)

shouldBeNear ∷ Maybe V2 → (V2, Float) → Expectation
shouldBeNear actual (expected@(V2 ex ey), tolerance) = case actual of
  Just (V2 x y) | abs (x - ex) <= tolerance && abs (y - ey) <= tolerance → pure ()
  _ → expectationFailure ("expected " <> show expected <> " within " <> show tolerance <> ", got " <> show actual)

-- Equations -----------------------------------------------------------------

worldEquations ∷ Spec
worldEquations = describe "world space" $ do
  let viewport = Viewport (V2 100 50) (V2 640 480) -- centre (420, 290)
      at cam mode = mapping (pixels 1000 700) (viewOf cam viewport (snapSettings False mode))
      camera = Camera (V2 3 4) 1 Nothing

  it "puts the camera position at the viewport's centre" $
    worldToTarget (at camera PixelsPerUnit) (V2 3 4) `shouldBe` Just (V2 420 290)

  it "puts the camera position at the centre in fixed-half-height mode too, rotated or not" $ do
    worldToTarget (at camera (FixedHalfHeight 10)) (V2 3 4) `shouldBe` Just (V2 420 290)
    worldToTarget (at camera {cameraRotation = Just 1.2} PixelsPerUnit) (V2 3 4) `shouldBeNear` (V2 420 290, 1.0e-3)

  it "spans the zoom in pixels per world unit, so a whole-number zoom gives exact pixel spacing" $ do
    let m = at camera {cameraZoom = 4} PixelsPerUnit
    worldToTarget m (V2 4 4) `shouldBe` Just (V2 424 290)
    worldToTarget m (V2 3 5) `shouldBe` Just (V2 420 294)
    worldToTarget m (V2 13 4) `shouldBe` Just (V2 460 290)
    worldToTarget m (V2 (-1) 0) `shouldBe` Just (V2 404 274)

  it "shows more of the world in a larger window at the same zoom" $ do
    let top size = targetToWorld (mapping (pixels 4000 4000) (viewOf camera {cameraZoom = 2} (Viewport (V2 0 0) size) (snapSettings False PixelsPerUnit))) (V2 0 0)
    top (V2 640 480) `shouldBe` Just (V2 (3 - 160) (4 - 120))
    top (V2 1280 960) `shouldBe` Just (V2 (3 - 320) (4 - 240))

  describe "a fixed half-height" $ do
    let sized w h zoom =
          mapping (pixels 4000 4000) (viewOf camera {cameraZoom = zoom} (Viewport (V2 0 0) (V2 w h)) (snapSettings False (FixedHalfHeight 10)))

    it "shows the same vertical extent at two window sizes" $
      forM_ [(640, 480), (1920, 1080)] $ \(w, h) → do
        let m = sized w h 1
        targetToWorld m (V2 (w / 2) 0) `shouldBeNear` (V2 3 (4 - 10), 1.0e-4)
        targetToWorld m (V2 (w / 2) h) `shouldBeNear` (V2 3 (4 + 10), 1.0e-4)

    it "spans h ÷ zoom world units from the centre to the top edge" $ do
      let m = sized 800 600 2
      targetToWorld m (V2 400 0) `shouldBeNear` (V2 3 (4 - 5), 1.0e-4)
      -- 600 px high / (2 * 10) * 2 = 60 px per world unit on both axes.
      worldToTarget m (V2 4 4) `shouldBe` Just (V2 460 300)

    it "scales both axes alike, so the horizontal extent follows the aspect ratio" $ do
      -- Same height, double the width: the same scale, twice the horizontal extent.
      targetToWorld (sized 800 600 1) (V2 0 300) `shouldBeNear` (V2 (3 - 400 / 30) 4, 1.0e-4)
      targetToWorld (sized 1600 600 1) (V2 0 300) `shouldBeNear` (V2 (3 - 800 / 30) 4, 1.0e-4)

  describe "rotation" $ do
    let quarter = at camera {cameraZoom = 10, cameraRotation = Just (pi / 2)} PixelsPerUnit
    it "turns the camera by a positive angle, +X toward +Y, about the viewport's centre" $ do
      -- A quarter turn: world +Y lies to the right of the centre, world +X above it.
      worldToTarget quarter (V2 3 5) `shouldBeNear` (V2 430 290, 1.0e-3)
      worldToTarget quarter (V2 4 4) `shouldBeNear` (V2 420 280, 1.0e-3)
      worldToTarget quarter (V2 3 3) `shouldBeNear` (V2 410 290, 1.0e-3)
      worldToTarget quarter (V2 2 4) `shouldBeNear` (V2 420 300, 1.0e-3)
    it "gives a transform whose columns are the signed basis images" $ do
      -- The images of the world's +X and +Y directions, and the translation.
      case toColumnMajor (worldTransform quarter) of
        [a, b, c, d, _, _] → do
          (abs a < 1.0e-5, abs (b + 10) < 1.0e-4) `shouldBe` (True, True)
          (abs (c - 10) < 1.0e-4, abs d < 1.0e-5) `shouldBe` (True, True)
        other → expectationFailure ("six coefficients expected, got " <> show other)
    it "keeps the centre fixed at any angle" $
      forM_ [0.3, 1, 2, 3, -2, 7] $ \angle →
        worldToTarget (at camera {cameraRotation = Just angle} PixelsPerUnit) (V2 3 4) `shouldBeNear` (V2 420 290, 1.0e-3)
    it "treats no rotation as a zero angle" $
      worldTransform (at camera PixelsPerUnit) `shouldBe` worldTransform (at camera {cameraRotation = Just 0} PixelsPerUnit)

uiEquations ∷ Spec
uiEquations = describe "UI space" $ do
  let viewport = Viewport (V2 100 50) (V2 640 480)
      ui scale snap metrics = mapping metrics (viewOf plainCamera viewport (defaultViewSettings {settingUiScale = scale, settingPixelSnap = snap}))

  it "maps a UI point by viewport origin + point × (UI scale × content scale), per axis" $ do
    uiToTarget (ui 1 False (windowMetrics (800, 600) (800, 600) (1, 1))) (V2 10 20) `shouldBe` Just (V2 110 70)
    uiToTarget (ui 2 False (windowMetrics (800, 600) (1600, 1200) (2, 1.5))) (V2 10 20) `shouldBe` Just (V2 140 110)
    uiToTarget (ui 0.5 False (windowMetrics (800, 600) (800, 600) (1, 4))) (V2 10 20) `shouldBe` Just (V2 105 90)

  it "is independent of the camera" $ do
    let withCamera camera = mapping (pixels 800 600) (viewOf camera viewport defaultViewSettings)
    uiToTarget (withCamera plainCamera) (V2 7 9)
      `shouldBe` uiToTarget (withCamera (Camera (V2 1000 (-3)) 17 (Just 2))) (V2 7 9)

  it "gives UI the same physical size on content scale 1 and 2" $ do
    -- A 640 x 480 logical window, once with a framebuffer of the same size and
    -- once with a framebuffer of twice the size and content scale 2.
    let plain = windowMetrics (640, 480) (640, 480) (1, 1)
        retina = windowMetrics (640, 480) (1280, 960) (2, 2)
        fullWindow = Viewport (V2 0 0)
        viewFor extent = viewOf plainCamera (fullWindow extent) defaultViewSettings
        plainM = mapping plain (viewFor (V2 640 480))
        retinaM = mapping retina (viewFor (V2 1280 960))
    -- A 100 x 50 UI element spans 100 x 50 pixels, and 200 x 100 pixels,
    -- which are the same fraction of the window.
    uiToTarget plainM (V2 100 50) `shouldBe` Just (V2 100 50)
    uiToTarget retinaM (V2 100 50) `shouldBe` Just (V2 200 100)
    -- The same window point lands on the same UI point.
    windowToUi plainM (V2 320 240) `shouldBe` Just (V2 320 240)
    windowToUi retinaM (V2 320 240) `shouldBe` Just (V2 320 240)

  it "inverts the UI mapping" $
    targetToUi (ui 2 False (windowMetrics (800, 600) (1600, 1200) (2, 1.5))) (V2 140 110) `shouldBeNear` (V2 10 20, 1.0e-4)

windowEquations ∷ Spec
windowEquations = describe "window points" $ do
  let full w h = viewOf plainCamera (Viewport (V2 0 0) (V2 w h)) defaultViewSettings
      under logical framebuffer scale = mapping (windowMetrics logical framebuffer scale) (full 640 480)

  it "maps by the framebuffer-to-window ratio at ratio 1" $
    windowToTarget (under (640, 480) (640, 480) (1, 1)) (V2 123 45) `shouldBe` Just (V2 123 45)

  it "maps by the framebuffer-to-window ratio at ratio 2" $ do
    windowToTarget (under (640, 480) (1280, 960) (2, 2)) (V2 123 45) `shouldBe` Just (V2 246 90)
    targetToWindow (under (640, 480) (1280, 960) (2, 2)) (V2 246 90) `shouldBe` Just (V2 123 45)

  it "maps by a different ratio on each axis" $ do
    windowToTarget (under (800, 600) (1200, 1200) (1, 1)) (V2 100 100) `shouldBe` Just (V2 150 200)
    targetToWindow (under (800, 600) (1200, 1200) (1, 1)) (V2 150 200) `shouldBe` Just (V2 100 100)

  it "uses no content scale, even when it differs from the extent ratio" $ do
    -- A ratio of 2 with a content scale of 1.25: the cursor ignores the scale.
    let m = under (800, 600) (1600, 1200) (1.25, 1.25)
    windowToTarget m (V2 100 100) `shouldBe` Just (V2 200 200)
    -- The UI, in contrast, is drawn at UI scale × content scale.
    uiToTarget m (V2 100 100) `shouldBe` Just (V2 125 125)

  it "composes with the world and UI mappings and back" $ do
    let viewport = Viewport (V2 0 0) (V2 1280 960)
        m = mapping (windowMetrics (640, 480) (1280, 960) (2, 2)) (viewOf (Camera (V2 10 20) 4 Nothing) viewport defaultViewSettings)
    -- The window centre is the framebuffer centre, which is the camera position.
    windowToWorld m (V2 320 240) `shouldBe` Just (V2 10 20)
    worldToWindow m (V2 10 20) `shouldBe` Just (V2 320 240)
    -- The UI scale is 1 and the content scale 2, so a UI point is two pixels per unit.
    windowToUi m (V2 320 240) `shouldBe` Just (V2 320 240)
    uiToWindow m (V2 320 240) `shouldBe` Just (V2 320 240)

-- Snapping ------------------------------------------------------------------

snapping ∷ Spec
snapping = describe "pixel snap" $ do
  let viewport = Viewport (V2 0 0) (V2 100 100) -- centre (50, 50)
      camera = Camera (V2 0.25 0.25) 1 Nothing
      on = mapping (pixels 100 100) (viewOf camera viewport (snapSettings True PixelsPerUnit))
      off = mapping (pixels 100 100) (viewOf camera viewport (snapSettings False PixelsPerUnit))

  it "snaps the camera's translation when on, and leaves it alone when off" $ do
    -- The translation is 50 − 0.25: 49.75 off, and 50 on.
    take 2 (drop 4 (toColumnMajor (worldTransform off))) `shouldBe` [49.75, 49.75]
    take 2 (drop 4 (toColumnMajor (worldTransform on))) `shouldBe` [50, 50]

  it "puts the camera position at the centre exactly with snap off, and within half a pixel with snap on" $ do
    worldToTarget off (V2 0.25 0.25) `shouldBe` Just (V2 50 50)
    worldToTarget on (V2 0.25 0.25) `shouldBe` Just (V2 50.25 50.25)

  it "keeps the half-pixel promise against the transform drawing uses, not an unsnapped one" $ do
    -- The ideal position of an instance origin at 0.5 is 50.25; the snapped
    -- camera moves it to 50.5, and the drawn origin is 51. The promise is the
    -- 0.5 between 50.5 and 51, not the 0.75 between 50.25 and 51.
    let origin = V2 0.5 0.5
    worldToTarget off origin `shouldBe` Just (V2 50.25 50.25)
    worldToTarget on origin `shouldBe` Just (V2 50.5 50.5)
    fmap snapPoint (worldToTarget on origin) `shouldBe` Just (V2 51 51)

  it "inverts the transform drawing uses, with its snapped translation, rounding nothing" $ do
    targetToWorld on (V2 50.5 50.5) `shouldBe` Just (V2 0.5 0.5)
    targetToWorld on (V2 51 51) `shouldBe` Just (V2 1 1)
    targetToWorld off (V2 50.25 50.25) `shouldBe` Just (V2 0.5 0.5)

  describe "UI" $ do
    let uiView snap = viewOf plainCamera (Viewport (V2 10.4 20.6) (V2 100 100)) defaultViewSettings {settingPixelSnap = snap}
        uiOn = mapping (pixels 200 200) (uiView True)
        uiOff = mapping (pixels 200 200) (uiView False)

    it "keeps the continuous equation and its inverse with snap on: the transform does not change" $ do
      uiTransform uiOn `shouldBe` uiTransform uiOff
      uiToTarget uiOn (V2 0 0) `shouldBe` Just (V2 10.4 20.6)
      uiToTarget uiOn (V2 1 1) `shouldBe` Just (V2 11.4 21.6)
      targetToUi uiOn (V2 10.4 20.6) `shouldBeNear` (V2 0 0, 1.0e-5)
      targetToUi uiOn (V2 11.4 21.6) `shouldBeNear` (V2 1 1, 1.0e-5)

    it "rounds a UI instance origin through snapPoint, separately, and leaves the inverse unrounded" $ do
      fmap snapPoint (uiToTarget uiOn (V2 1 1)) `shouldBe` Just (V2 11 22)
      targetToUi uiOn (V2 11 22) `shouldBeNear` (V2 0.6 1.4, 1.0e-5)

  it "keeps the camera at the centre to the 32-bit resolution of its translation, far from the origin" $ do
    -- Scale 40960 pixels per unit at position 999.99: the translation is about
    -- 4e7, where one ulp is 4 pixels, so the camera lands pixels from the centre
    -- (2056, 2068 against 2058.4, 2068.6) and the mapping is still finite and
    -- inverts what it holds. The tolerance states that resolution.
    let far = viewOf (Camera (V2 999.99 999.99) 10 (Just 0.7)) (Viewport (V2 10.4 20.6) (V2 4096 4096)) (snapSettings True (FixedHalfHeight 0.5))
    isJust (viewMapping (pixels 4096 4096) far) `shouldBe` True
    centreTolerance far > 2.4 `shouldBe` True
    fmap (\(dx, dy) → abs dx <= centreTolerance far && abs dy <= centreTolerance far) (centreOffset (pixels 4096 4096) far)
      `shouldBe` Just True

  it "reports whether the view snaps" $ do
    mappingPixelSnap on `shouldBe` True
    mappingPixelSnap off `shouldBe` False

-- Combinations --------------------------------------------------------------

-- | The window sizes, framebuffer-to-window ratios and content scales that
-- every combination below runs across: resizes with a fixed content scale and
-- content scales with a fixed size.
extents ∷ [(Int, Int)]
extents = [(640, 480), (1280, 720), (1920, 1080), (1, 1), (333, 777)]

scales ∷ [((Int, Int), (Float, Float))]
scales = [((1, 1), (1, 1)), ((2, 2), (2, 2)), ((3, 2), (1.5, 1.25)), ((1, 1), (0.5, 4))]

combinations ∷ Spec
combinations = describe "every combination of pixel snap, zoom mode and zoom kind" $
  forM_ [False, True] $ \snap →
    forM_ [("pixels per unit", PixelsPerUnit), ("a fixed half-height of 7", FixedHalfHeight 7)] $ \(modeName, mode) →
      forM_ zoomKinds $ \(zoomName, zoom) →
        it (unwords ["snap", if snap then "on" else "off", "with", modeName, "and", zoomName, "across resizes and content scales"]) $
          forM_ extents $ \(logicalW, logicalH) →
            forM_ scales $ \((ratioX, ratioY), content) → do
              let metrics = windowMetrics (logicalW, logicalH) (logicalW * ratioX, logicalH * ratioY) content
                  viewport = Viewport (V2 0 0) (V2 (fromIntegral (logicalW * ratioX)) (fromIntegral (logicalH * ratioY)))
                  camera = Camera (V2 12.5 (-3.75)) zoom Nothing
                  view = viewOf camera viewport (snapSettings snap mode)
                  context = show (metrics, view)
              case viewMapping metrics view of
                Nothing → expectationFailure ("no mapping for " <> context)
                Just m → do
                  let centre = V2 (fromIntegral (logicalW * ratioX) / 2) (fromIntegral (logicalH * ratioY) / 2)
                  -- The camera position is at the centre, or within half a pixel of it.
                  assertWithin (if snap then 0.5 else 1.0e-2) context centre (worldToTarget m (V2 12.5 (-3.75)))
                  forM_ [V2 0 0, V2 12.5 (-3.75), V2 (-100) 250.5, V2 3.3 (-7.7)] $ \p → do
                    assertRoundTrip context (worldToTarget m) (targetToWorld m) p (1.0e-3 * (1 + 400 / zoom))
                    assertHalfPixel context (worldToTarget m) p
                  forM_ [V2 0 0, V2 5 6, V2 (-40) 1000] $ \p → do
                    assertRoundTrip context (uiToTarget m) (targetToUi m) p 1.0e-2
                    assertHalfPixel context (uiToTarget m) p
                  forM_ [V2 0 0, V2 (fromIntegral logicalW / 2) (fromIntegral logicalH / 3), V2 (fromIntegral logicalW) (fromIntegral logicalH)] $ \p → do
                    assertRoundTrip context (windowToWorld m) (worldToWindow m) p (1.0e-2 * (1 + 400 / zoom))
                    assertRoundTrip context (windowToUi m) (uiToWindow m) p 1.0e-2
  where
    -- Smooth zoom is a plain value; discrete zoom is one the step functions give.
    zoomKinds ∷ [(String, Float)]
    zoomKinds =
      [ ("smooth zoom 1.37", 1.37)
      , ("a discrete step in from 1.37", stepZoomIn defaultZoomSteps 1.37)
      , ("a discrete step out from 1.37", stepZoomOut defaultZoomSteps 1.37)
      , ("a discrete step in from the top", stepZoomIn defaultZoomSteps 8)
      ]

assertWithin ∷ Float → String → V2 → Maybe V2 → Expectation
assertWithin tolerance context expected actual =
  case actual of
    Just (V2 x y) | abs (x - ex) <= tolerance && abs (y - ey) <= tolerance → pure ()
    _ → expectationFailure (context <> ": expected " <> show expected <> " within " <> show tolerance <> ", got " <> show actual)
  where
    V2 ex ey = expected

assertRoundTrip ∷ String → (V2 → Maybe V2) → (V2 → Maybe V2) → V2 → Float → Expectation
assertRoundTrip context forward back p tolerance =
  assertWithin tolerance (context <> " at " <> show p) p (forward p >>= back)

-- | The half-pixel property: snapping the position drawing computes moves it by
-- at most half a pixel on each axis.
assertHalfPixel ∷ String → (V2 → Maybe V2) → V2 → Expectation
assertHalfPixel context forward p = case forward p of
  Just t@(V2 x y) →
    let V2 sx sy = snapPoint t
     in if abs (sx - x) <= 0.5 && abs (sy - y) <= 0.5
          then pure ()
          else expectationFailure (context <> ": snapping " <> show t <> " moved it to " <> show (V2 sx sy))
  Nothing → expectationFailure (context <> ": no position for " <> show p)

-- Degenerate and numeric input ------------------------------------------------

degenerate ∷ Spec
degenerate = describe "degenerate input" $ do
  let camera = Camera (V2 1 2) 3 Nothing
      metrics = windowMetrics (800, 600) (1600, 1200) (2, 2)
      viewIn viewport = viewOf camera viewport defaultViewSettings

  describe "a zero-width or zero-height viewport" $
    forM_ [("width", Viewport (V2 10 10) (V2 0 100)), ("height", Viewport (V2 10 10) (V2 100 0)), ("both", Viewport (V2 10 10) (V2 0 0))] $ \(name, viewport) → do
      let m = mapping metrics (viewIn viewport)
      it ("draws nothing with a zero " <> name) $ do
        viewportIsEmpty viewport `shouldBe` True
        viewportContains viewport (V2 10 10) `shouldBe` False
      it ("has no inverse mapping with a zero " <> name) $ do
        worldInverse m `shouldBe` Nothing
        uiInverse m `shouldBe` Nothing
        targetToWorld m (V2 10 10) `shouldBe` Nothing
        targetToUi m (V2 10 10) `shouldBe` Nothing
        windowToWorld m (V2 10 10) `shouldBe` Nothing
        windowToUi m (V2 10 10) `shouldBe` Nothing
      it ("still maps forward, finitely, with a zero " <> name) $ do
        isJust (worldToTarget m (V2 1 2)) `shouldBe` True
        isJust (uiToTarget m (V2 1 2)) `shouldBe` True

  it "also has no inverse for a zero viewport in fixed-half-height mode" $ do
    let m = mapping metrics (viewOf camera (Viewport (V2 0 0) (V2 100 0)) (snapSettings False (FixedHalfHeight 5)))
    targetToWorld m (V2 1 1) `shouldBe` Nothing
    isJust (worldToTarget m (V2 1 2)) `shouldBe` True

  it "has an inverse for a non-empty viewport" $ do
    let m = mapping metrics (viewIn (Viewport (V2 0 0) (V2 100 100)))
    (isJust (worldInverse m), isJust (uiInverse m)) `shouldBe` (True, True)

  describe "a zero logical or framebuffer extent" $
    forM_
      [ ("a zero logical width", windowMetrics (0, 600) (1600, 1200) (2, 2))
      , ("a zero logical height", windowMetrics (800, 0) (1600, 1200) (2, 2))
      , ("a zero framebuffer width", windowMetrics (800, 600) (0, 1200) (2, 2))
      , ("a minimized window's zero framebuffer", windowMetrics (800, 600) (0, 0) (2, 2))
      , ("all extents zero", windowMetrics (0, 0) (0, 0) (1, 1))
      ]
      $ \(name, zeroMetrics) → do
        let m = mapping zeroMetrics (viewIn (Viewport (V2 0 0) (V2 100 100)))
        it ("gives no window point conversion with " <> name) $ do
          windowToTarget m (V2 5 5) `shouldBe` Nothing
          targetToWindow m (V2 5 5) `shouldBe` Nothing
          windowToWorld m (V2 5 5) `shouldBe` Nothing
          worldToWindow m (V2 5 5) `shouldBe` Nothing
          windowToUi m (V2 5 5) `shouldBe` Nothing
          uiToWindow m (V2 5 5) `shouldBe` Nothing
        it ("still maps world and UI points with " <> name) $ do
          isJust (worldToTarget m (V2 5 5)) `shouldBe` True
          isJust (uiToTarget m (V2 5 5)) `shouldBe` True

  describe "containment" $ do
    let viewport = Viewport (V2 10 20) (V2 100 50) -- x in [10, 110), y in [20, 70)
        inside = viewportContains viewport
    it "includes the left and top edges and the interior" $ do
      inside (V2 10 20) `shouldBe` True
      inside (V2 10 69.5) `shouldBe` True
      inside (V2 109.5 20) `shouldBe` True
      inside (V2 60 45) `shouldBe` True
    it "excludes the right and bottom edges" $ do
      inside (V2 110 45) `shouldBe` False
      inside (V2 60 70) `shouldBe` False
      inside (V2 110 70) `shouldBe` False
    it "excludes points just outside every edge" $ do
      inside (V2 9.999 45) `shouldBe` False
      inside (V2 60 19.999) `shouldBe` False
      inside (V2 110.001 45) `shouldBe` False
      inside (V2 60 70.001) `shouldBe` False
    it "contains no point of an empty viewport, edges included" $
      forM_ [V2 10 20, V2 10.5 20.5, V2 0 0] $ \p → do
        viewportContains (Viewport (V2 10 20) (V2 0 50)) p `shouldBe` False
        viewportContains (Viewport (V2 10 20) (V2 100 0)) p `shouldBe` False
    it "contains no NaN or infinite point" $
      forM_ [V2 (0 / 0) 30, V2 30 (1 / 0), V2 (-1 / 0) 30] $ \p → viewportContains viewport p `shouldBe` False
    it "reports points outside the viewport still mapping" $ do
      let m = mapping (pixels 1000 1000) (viewOf camera viewport (snapSettings False PixelsPerUnit))
      fmap (viewportContains viewport) (worldToTarget m (V2 1000 1000)) `shouldBe` Just False
      fmap (viewportContains viewport) (worldToTarget m (V2 1 2)) `shouldBe` Just True

numeric ∷ Spec
numeric = describe "unrepresentable results" $ do
  let viewport = Viewport (V2 0 0) (V2 100 100)
      metrics = pixels 100 100
      refused camera mode = viewMapping metrics (viewOf camera viewport (snapSettings False mode))

  it "refuses a camera whose transform overflows, without clamping" $ do
    -- A position of 2e38 at zoom 2 puts the translation beyond the largest Float.
    refused (Camera (V2 2.0e38 0) 2 Nothing) PixelsPerUnit `shouldBe` Nothing
    refused (Camera (V2 0 (-2.0e38)) 2 Nothing) PixelsPerUnit `shouldBe` Nothing

  it "refuses a subnormal scale, whose inverse has no representation" $ do
    refused (Camera (V2 0 0) 1.0e-45 Nothing) PixelsPerUnit `shouldBe` Nothing
    refused (Camera (V2 0 0) 1.0e-40 Nothing) PixelsPerUnit `shouldBe` Nothing

  it "accepts a scale whose inverse still fits" $
    isJust (refused (Camera (V2 0 0) 1.0e-30 Nothing) PixelsPerUnit) `shouldBe` True

  it "refuses a fixed half-height whose scale overflows or underflows" $ do
    refused (Camera (V2 0 0) 1.0e30 Nothing) (FixedHalfHeight 1.0e-30) `shouldBe` Nothing
    refused (Camera (V2 0 0) 1.0e-30 Nothing) (FixedHalfHeight 1.0e30) `shouldBe` Nothing

  it "refuses a UI scale that underflows" $
    viewMapping (windowMetrics (100, 100) (100, 100) (1.0e-40, 1)) (viewOf plainCamera viewport defaultViewSettings) `shouldBe` Nothing

  it "refuses a point conversion whose result overflows" $ do
    let m = mapping metrics (viewOf (Camera (V2 0 0) 1.0e30 Nothing) viewport (snapSettings False PixelsPerUnit))
    worldToTarget m (V2 1.0e10 0) `shouldBe` Nothing
    worldToTarget m (V2 1.0e5 0) `shouldBe` Just (V2 (50 + 1.0e35) 50)
    let big = mapping (windowMetrics (1, 1) (2147483647, 2147483647) (1, 1)) (viewOf plainCamera viewport defaultViewSettings)
    windowToTarget big (V2 3.0e38 0) `shouldBe` Nothing

  it "refuses non-finite points" $ do
    let m = mapping metrics (viewOf plainCamera viewport defaultViewSettings)
    forM_ [V2 (0 / 0) 0, V2 0 (1 / 0), V2 (-1 / 0) 1] $ \p → do
      worldToTarget m p `shouldBe` Nothing
      targetToWorld m p `shouldBe` Nothing
      uiToTarget m p `shouldBe` Nothing
      targetToUi m p `shouldBe` Nothing
      windowToTarget m p `shouldBe` Nothing
      targetToWindow m p `shouldBe` Nothing

  describe "refuses what validation refuses" $
    forM_
      [ ("a NaN camera position", Camera (V2 (0 / 0) 0) 1 Nothing)
      , ("an infinite camera position", Camera (V2 0 (1 / 0)) 1 Nothing)
      , ("a zero zoom", Camera (V2 0 0) 0 Nothing)
      , ("a negative zoom", Camera (V2 0 0) (-1) Nothing)
      , ("a NaN zoom", Camera (V2 0 0) (0 / 0) Nothing)
      , ("an infinite zoom", Camera (V2 0 0) (1 / 0) Nothing)
      , ("a NaN rotation", Camera (V2 0 0) 1 (Just (0 / 0)))
      , ("an infinite rotation", Camera (V2 0 0) 1 (Just (1 / 0)))
      ]
      $ \(name, camera) →
        it ("gives no mapping for " <> name) $ refused camera PixelsPerUnit `shouldBe` Nothing

  it "refuses a negative or non-finite viewport, a bad UI scale and a bad half-height" $ do
    let try v = viewMapping metrics v
    try (viewOf plainCamera (Viewport (V2 0 0) (V2 (-1) 5)) defaultViewSettings) `shouldBe` Nothing
    try (viewOf plainCamera (Viewport (V2 (0 / 0) 0) (V2 5 5)) defaultViewSettings) `shouldBe` Nothing
    try (viewOf plainCamera (Viewport (V2 0 0) (V2 (1 / 0) 5)) defaultViewSettings) `shouldBe` Nothing
    try (viewOf plainCamera viewport defaultViewSettings {settingUiScale = 5}) `shouldBe` Nothing
    try (viewOf plainCamera viewport (snapSettings False (FixedHalfHeight 0))) `shouldBe` Nothing
    try (viewOf plainCamera viewport (snapSettings False (FixedHalfHeight (0 / 0)))) `shouldBe` Nothing

  describe "refuses unusable metrics" $
    forM_
      [ ("a negative logical extent", TargetMetrics (PixelExtent (-1) 5) (PixelExtent 5 5) 1 1)
      , ("a negative framebuffer extent", TargetMetrics (PixelExtent 5 5) (PixelExtent 5 (-1)) 1 1)
      , ("a zero content scale", windowMetrics (5, 5) (5, 5) (0, 1))
      , ("a negative content scale", windowMetrics (5, 5) (5, 5) (1, -1))
      , ("a NaN content scale", windowMetrics (5, 5) (5, 5) (0 / 0, 1))
      , ("an infinite content scale", windowMetrics (5, 5) (5, 5) (1, 1 / 0))
      ]
      $ \(name, bad) →
        it ("gives no mapping for " <> name) $
          viewMapping bad (viewOf plainCamera viewport defaultViewSettings) `shouldBe` Nothing

  it "treats an offscreen target's metrics as logical = pixels, content scale 1" $
    offscreenMetrics (PixelExtent 7 9) `shouldBe` TargetMetrics (PixelExtent 7 9) (PixelExtent 7 9) 1 1

-- | How far the camera position may appear from the viewport's centre: half a
-- pixel with snap on, plus the resolution of the 32-bit translation, which is
-- the centre minus the scale times the camera position. One ulp of that
-- product is about 1.2e-7 of its size, and a few ulps of rounding accumulate
-- through the coefficients, so the allowance is 4e-7 of the magnitudes held,
-- and 1e-3 beside.
centreTolerance ∷ View → Float
centreTolerance view = snapPart + 1.0e-3 + 4.0e-7 * magnitude
  where
    Viewport (V2 ox oy) (V2 w h) = viewViewport view
    V2 px py = cameraPosition (viewCamera view)
    zoom = cameraZoom (viewCamera view)
    scale = case settingZoomMode (viewSettings view) of
      PixelsPerUnit → zoom
      FixedHalfHeight half → h * zoom / (2 * half)
    snapPart = if settingPixelSnap (viewSettings view) then 0.5 else 0
    magnitude = abs ox + abs oy + w + h + scale * (abs px + abs py)

-- | Where the camera position lands, relative to the viewport's centre.
centreOffset ∷ TargetMetrics → View → Maybe (Float, Float)
centreOffset metrics view =
  (\(V2 x y) → (x - (ox + w / 2), y - (oy + h / 2))) <$> worldToTarget (mapping metrics view) (cameraPosition (viewCamera view))
  where
    Viewport (V2 ox oy) (V2 w h) = viewViewport view

centreWithinTolerance ∷ TargetMetrics → View → Property
centreWithinTolerance metrics view = case centreOffset metrics view of
  Just (dx, dy) →
    counterexample
      (show (dx, dy) <> " from the centre, within " <> show tolerance)
      (property (abs dx <= tolerance && abs dy <= tolerance))
  Nothing → counterexample "no result" (property False)
  where
    tolerance = centreTolerance view

-- Properties ----------------------------------------------------------------

-- | A target, and a view valid on it, in the domain the tolerance is stated for.
data Case = Case TargetMetrics View
  deriving stock (Show)

genCase ∷ Gen Case
genCase = do
  lw ← choose (1, 4096)
  lh ← choose (1, 4096)
  fw ← choose (1, 8192)
  fh ← choose (1, 8192)
  kx ← choose (0.5, 3)
  ky ← choose (0.5, 3)
  origin ← V2 <$> choose (-200, 2000) <*> choose (-200, 2000)
  extent ← V2 <$> choose (1, 4096) <*> choose (1, 4096)
  position ← V2 <$> choose (-1000, 1000) <*> choose (-1000, 1000)
  (mode, zoom) ←
    oneof
      [ (,) PixelsPerUnit <$> choose (0.05, 50)
      , (,) <$> (FixedHalfHeight <$> choose (0.5, 500)) <*> choose (0.1, 10)
      ]
  rotation ← oneof [pure Nothing, Just <$> choose (-7, 7)]
  snap ← oneof [pure False, pure True]
  uiScale ← choose (0.5, 4)
  pure
    ( Case
        (windowMetrics (lw, lh) (fw, fh) (kx, ky))
        (viewOf (Camera position zoom rotation) (Viewport origin extent) (snapSettings snap mode) {settingUiScale = uiScale})
    )

-- | A point of the world in the generated domain.
genPoint ∷ Gen V2
genPoint = V2 <$> choose (-1000, 1000) <*> choose (-1000, 1000)

mappingOf ∷ Case → ViewMapping
mappingOf (Case metrics view) = mapping metrics view

-- | Equal within @1e-4 × (1 + magnitude)@ on each axis.
closeTo ∷ Float → V2 → Maybe V2 → Property
closeTo magnitude expected@(V2 ex ey) actual = case actual of
  Just (V2 x y) →
    counterexample
      (show actual <> " is not within " <> show tolerance <> " of " <> show expected)
      (property (abs (x - ex) <= tolerance && abs (y - ey) <= tolerance))
  Nothing → counterexample "no result" (property False)
  where
    tolerance = 1.0e-4 * (1 + magnitude)

-- | The largest magnitude a world calculation held: the point, the transform's
-- translation, and that translation in world units.
worldMagnitude ∷ ViewMapping → V2 → Float
worldMagnitude m (V2 x y) = maximum [abs x, abs y, abs tx / scale, abs ty / scale, abs tx, abs ty]
  where
    (scale, tx, ty) = case toColumnMajor (worldTransform m) of
      [a, b, _, _, ex, ey] → (max 1.0e-30 (sqrt (a * a + b * b)), ex, ey)
      _ → (1, 0, 0)

uiMagnitude ∷ ViewMapping → V2 → Float
uiMagnitude m (V2 x y) = maximum [abs x, abs y, abs tx, abs ty]
  where
    (tx, ty) = case toColumnMajor (uiTransform m) of
      [_, _, _, _, ex, ey] → (ex, ey)
      _ → (0, 0)

properties ∷ Spec
properties = describe "properties" $ do
  prop "world → target → world returns the point, within 1e-4 × (1 + magnitude)" $
    forAll ((,) <$> genCase <*> genPoint) $ \(c, p) →
      let m = mappingOf c in closeTo (worldMagnitude m p) p (worldToTarget m p >>= targetToWorld m)

  prop "target → world → target returns the point, within the same tolerance" $
    forAll ((,) <$> genCase <*> genPoint) $ \(c, p) →
      let m = mappingOf c
          scale = case toColumnMajor (worldTransform m) of
            (a : b : _) → max 1 (sqrt (a * a + b * b))
            _ → 1
       in closeTo (worldMagnitude m p * scale) p (targetToWorld m p >>= worldToTarget m)

  prop "UI → target → UI returns the point, within the same tolerance" $
    forAll ((,) <$> genCase <*> genPoint) $ \(c, p) →
      let m = mappingOf c in closeTo (uiMagnitude m p * 4) p (uiToTarget m p >>= targetToUi m)

  prop "window → target → window returns the point" $
    forAll ((,) <$> genCase <*> genPoint) $ \(c, p) →
      let m = mappingOf c
          V2 px py = p
       in closeTo (maximum [abs px, abs py] * 0.1) p (windowToTarget m p >>= targetToWindow m)

  prop "window → world → window and window → UI → window return the point" $
    forAll ((,) <$> genCase <*> genPoint) $ \(c@(Case metrics _), p) →
      let m = mappingOf c
          V2 px py = p
          window = maximum [abs px, abs py] * 8
          -- The error made in target pixels reaches the window scaled by the
          -- logical-to-framebuffer ratio, which a tiny framebuffer makes large.
          PixelExtent lw lh = metricsLogical metrics
          PixelExtent fw fh = metricsFramebuffer metrics
          amplify = maximum [1, fromIntegral lw / fromIntegral fw, fromIntegral lh / fromIntegral fh]
       in closeTo (amplify * (window + 2 * worldMagnitude m p)) p (windowToWorld m p >>= worldToWindow m)
            .&&. closeTo (amplify * (window + 2 * uiMagnitude m p)) p (windowToUi m p >>= uiToWindow m)

  prop "the camera position appears at the viewport's centre, to the stated tolerance" $
    forAll genCase $ \(Case metrics view) → centreWithinTolerance metrics view

  prop "snapping the position drawing computes moves it by at most half a pixel per axis" $
    forAll ((,) <$> genCase <*> genPoint) $ \(c, p) →
      let m = mappingOf c
          within f = case f m p of
            Just t@(V2 x y) → let V2 sx sy = snapPoint t in abs (sx - x) <= 0.5 && abs (sy - y) <= 0.5
            Nothing → False
       in property (within worldToTarget && within uiToTarget)

  prop "the world translation is on the pixel grid with snap on, and the UI transform never changes with snap" $
    forAll genCase $ \c@(Case metrics view) →
      let m = mappingOf c
          grid f = case drop 4 (toColumnMajor f) of
            [tx, ty] → snapPixel tx == tx && snapPixel ty == ty
            _ → False
          flipped = mapping metrics view {viewSettings = (viewSettings view) {settingPixelSnap = not (settingPixelSnap (viewSettings view))}}
       in property
            ( (not (settingPixelSnap (viewSettings view)) || grid (worldTransform m))
                && uiTransform m == uiTransform flipped
            )

  prop "gives a mapping only for a valid view and valid metrics, whatever the floats" $
    forAll anyCase $ \(Case metrics view, _) →
      isJust (viewMapping metrics view) `implies` (null (viewReasons view) && validMetrics metrics)

  prop "never produces a non-finite value from any input, and stays total" $
    forAll anyCase $ \(Case metrics view, points) →
      let built = viewMapping metrics view
          results m = [f m p | f ← conversions, p ← points]
       in -- The cases must reach both a built mapping and every kind of refusal,
          -- or the property would hold vacuously.
          cover 15 (isJust built) "a mapping is built" $
            cover 15 (isNothing built) "a mapping is refused" $
              cover 5 (maybe False (any isNothing . results) built) "a conversion is refused" $
                cover 5 (maybe False (any isJust . results) built) "a conversion succeeds" $
                  case built of
                    Nothing → property True
                    Just m → property (all (maybe True pointFinite) (results m))

  prop "builds the same mapping from the same input" $
    forAll anyCase $ \(Case metrics view, _) → viewMapping metrics view === viewMapping metrics view
  where
    pointFinite (V2 x y) = not (any (\v → isNaN v || isInfinite v) [x, y])
    implies a b = not a || b
    conversions = [worldToTarget, targetToWorld, uiToTarget, targetToUi, windowToTarget, targetToWindow, windowToWorld, worldToWindow, windowToUi, uiToWindow]

-- | A generated case with a mixed set of points: wild floats, and a case whose
-- view and metrics are wild, extreme but valid, or ordinary.
anyCase ∷ Gen (Case, [V2])
anyCase = (,) <$> oneof [wildCase, extremeCase, genCase] <*> points
  where
    points = vectorOf 8 (V2 <$> pointFloat <*> pointFloat)
    pointFloat = oneof [wildFloat, elements [1.0e10, -1.0e30, 3.0e38, 0.5, -0.5, 8388609]]

-- | Every float field of the view and the metrics takes its whole range.
wildCase ∷ Gen Case
wildCase = do
  sizes ← vectorOf 4 (oneof [choose (-2, 3), choose (0, 100000), choose (0, 2147483647)])
  metrics ← case sizes of
    [a, b, c, d] → windowMetrics (a, b) (c, d) <$> ((,) <$> wildFloat <*> wildFloat)
    _ → pure (pixels 1 1)
  position ← V2 <$> wildFloat <*> wildFloat
  zoom ← wildFloat
  rotation ← oneof [pure Nothing, Just <$> wildFloat]
  origin ← V2 <$> wildFloat <*> wildFloat
  extent ← V2 <$> wildFloat <*> wildFloat
  mode ← oneof [pure PixelsPerUnit, FixedHalfHeight <$> wildFloat]
  snap ← arbitrary
  uiScale ← oneof [wildFloat, choose (0.5, 4)]
  pure (Case metrics (viewOf (Camera position zoom rotation) (Viewport origin extent) (snapSettings snap mode) {settingUiScale = uiScale}))

-- | Valid views and metrics at the edges of the range, where the transform or
-- a point conversion can overflow or underflow.
extremeCase ∷ Gen Case
extremeCase = do
  let big = elements [0, 1, 1.0e30, 2.0e38, 3.4028235e38, 1.0e-30, 1.0e-45]
  position ← V2 <$> ((*) <$> elements [1, -1] <*> big) <*> big
  zoom ← elements [1.0e-45, 1.0e-30, 1.0e-5, 1, 1.0e5, 1.0e30, 3.4028235e38]
  origin ← V2 <$> big <*> big
  extent ← V2 <$> big <*> big
  mode ← oneof [pure PixelsPerUnit, FixedHalfHeight <$> elements [1.0e-45, 1.0e-30, 1, 1.0e30, 3.4028235e38]]
  rotation ← oneof [pure Nothing, Just <$> elements [0, 1, 1.0e30]]
  size ← elements [0, 1, 2147483647]
  scale ← elements [1.0e-45, 1.0e-30, 1, 1.0e30, 3.4028235e38]
  snap ← arbitrary
  pure
    ( Case
        (windowMetrics (size, 1) (1, size) (scale, 1))
        (viewOf (Camera position zoom rotation) (Viewport origin extent) (snapSettings snap mode))
    )
