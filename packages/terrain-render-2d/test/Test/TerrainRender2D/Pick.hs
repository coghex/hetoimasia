-- | Picking: exact identity, boundary conventions, snapping, version identity and
-- the refusal to answer through terrain nothing is known about.
module Test.TerrainRender2D.Pick (spec) where

import Control.Monad (forM_)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), ZoomMode (..), defaultViewSettings)
import Hetoimasia.Terrain.Cell (ZRange, mkZRange)
import Hetoimasia.Terrain.Changes (emptyChanges)
import Hetoimasia.Terrain.Coordinate (TileCoord, axisMaxValue, axisMinValue)
import Hetoimasia.Terrain.Geometry (FaceKind (..))
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Render2D.Pick
import Hetoimasia.Terrain.Render2D.Plan
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..), mkRenderView, snapCompatible)
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Hetoimasia.Terrain.Shape (Side (..))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.TerrainRender2D.Fixtures
import Test.TerrainRender2D.Oracle (Cell3, sceneSource)

isRight' ∷ Either a b → Bool
isRight' (Right _) = True
isRight' _ = False

zr ∷ Integer → Integer → ZRange
zr lo hi = either (\e → error (show e)) id (mkZRange lo hi)

-- | The window point of a render-world position in the 288 x 144 test view,
-- whose logical and framebuffer extents are equal.
at ∷ Float → Float → V2
at x y = V2 (144 + x) (72 + y)

pickAt ∷ Plan → V2 → Either PickError PickResult
pickAt p point = pickPlan p (PickQuery (planIdentity p) point)

hit ∷ Either PickError PickResult → Maybe (TileCoord, FaceKind)
hit (Right (PickHit f)) = Just (faceCell f, faceViewKind f)
hit _ = Nothing

spec ∷ Spec
spec = describe "Pick" $ do
  let isolatedPlan = plan (setup 288 144) (manualCamera 0 0 0) (factsOf (isolated 0))
  it "returns the frontmost face with its cell and kind under a point inside each face" $ do
    hit (pickAt isolatedPlan (at 0 0)) `shouldBe` Just (tileAt 0 0 0, TopFace)
    hit (pickAt isolatedPlan (at 24 20)) `shouldBe` Just (tileAt 0 0 0, WallFace East)
    hit (pickAt isolatedPlan (at (-24) 20)) `shouldBe` Just (tileAt 0 0 0, WallFace South)
  it "hits nothing in open sky, outside the viewport and in a zero extent" $ do
    pickAt isolatedPlan (at 100 (-60)) `shouldBe` Right PickNoHit
    pickAt isolatedPlan (V2 (-1) 10) `shouldBe` Right PickNoHit
    pickAt isolatedPlan (V2 288 72) `shouldBe` Right PickNoHit
    pickAt isolatedPlan (V2 100 144) `shouldBe` Right PickNoHit
    let zero = plan (setup 0 0) (manualCamera 0 0 0) (factsOf (isolated 0))
    pickAt zero (V2 0 0) `shouldBe` Right PickNoHit
  it "refuses a non-finite point" $ do
    pickAt isolatedPlan (V2 (0 / 0) 1) `shouldBe` Left PickInvalidPoint
    pickAt isolatedPlan (V2 1 (1 / 0)) `shouldBe` Left PickInvalidPoint
  it "recovers the exact integer identity of adjacent cells at both supported extremes" $ do
    let high = axisMaxValue
        low = axisMinValue
        ofCells x cells = plan (setup 288 144) (manualCamera x 0 0) (factsOf (sceneSource cells))
        flatAt x = (x, 0, 0, 0) ∷ Cell3
        pHigh = ofCells high [flatAt (high - 1), flatAt high]
        pLow = ofCells low [flatAt low, flatAt (low + 1)]
    hit (pickAt pHigh (at 0 0)) `shouldBe` Just (tileAt high 0 0, TopFace)
    hit (pickAt pHigh (at (-48) (-24))) `shouldBe` Just (tileAt (high - 1) 0 0, TopFace)
    hit (pickAt pLow (at 0 0)) `shouldBe` Just (tileAt low 0 0, TopFace)
    hit (pickAt pLow (at 48 24)) `shouldBe` Just (tileAt (low + 1) 0 0, TopFace)
  it "gives a point on an edge shared by two faces to exactly one, by the left-and-top rule" $ do
    let two = plan (setup 288 144) (manualCamera 0 0 0) (factsOf (sceneSource [(0, 0, 0, 0), (1, 0, 0, 0)]))
    -- The shared edge runs from (48, 0) to (0, 24). It is the lower-right edge of
    -- the first cell's top and the upper-left edge of the second's.
    hit (pickAt two (at 24 12)) `shouldBe` Just (tileAt 1 0 0, TopFace)
  describe "pixel snapping" $ do
    let sizedSnap = (setup 288 144) {setupSettings = defaultViewSettings {settingPixelSnap = True}}
        camAt zoom dx =
          let base = manualCamera 0 0 0
              zoomed = stepCamera (either (error . show) id (applyCommand defaultCameraConfig (factsOf flatWorld) (SetZoom zoom) base))
           in stepCamera (either (error . show) id (applyCommand defaultCameraConfig (factsOf flatWorld) (Pan dx 0) zoomed))
    it "refuses a snapped view at a zoom that would move adjacent faces apart" $ do
      planTerrain (request sizedSnap (camAt 0.3125 (1 / 96))) (factsOf flatWorld) `shouldBe` Left (PixelSnapUnsupported 0.3125)
      planTerrain (request sizedSnap (camAt 0.3 0)) (factsOf flatWorld) `shouldBe` Left (PixelSnapUnsupported 0.3)
      -- The same zooms are fine when the view does not snap.
      planTerrain (request (setup 288 144) (camAt 0.3125 (1 / 96))) (factsOf flatWorld) `shouldSatisfy` isRight'
    it "keeps continuous terrain continuous under a snapped view: no point of the viewport falls through a seam" $
      forM_ [0.125, 0.5, 1, 2.5, 8] $ \zoom → do
        let p = either (error . show) id (planTerrain (request sizedSnap (camAt zoom (1 / 96))) (factsOf flatWorld))
            points = [V2 (fromIntegral x / 2) (fromIntegral y / 2) | x ← [0 .. 575 ∷ Int], y ← [0 .. 287 ∷ Int], x `mod` 7 == 0, y `mod` 5 == 0]
            holes = [pt | pt ← points, hit (pickAt p pt) == Nothing]
        holes `shouldBe` []
    it "places a snapped face where the drawn quad is, by its own rounding of the origin" $ do
      -- Zoom 1/8 keeps every origin on a whole pixel, so the drawn face is the
      -- exact quad: a point just inside the top diamond's right vertex hits it.
      let p = either (error . show) id (planTerrain (request sizedSnap (camAt 0.125 0)) (factsOf (isolated 0)))
      hit (pickAt p (V2 144 72)) `shouldBe` Just (tileAt 0 0 0, TopFace)
      let viewAt zoom = either (error . show) id (mkRenderView sizedSnap zoom FaceSouth (1 / 2, 1 / 2))
      snapCompatible (viewAt 0.125) `shouldBe` True
      snapCompatible (viewAt 0.3125) `shouldBe` False
      snapCompatible (viewAt 3) `shouldBe` True
    it "judges the mapping's actual scale, so a fixed-half-height mode that gives a bad scale is refused" $ do
      -- 144 pixels high, zoom 1: half-height 230.4 gives scale 0.3125; 72 gives 1.
      let fixed h = sizedSnap {setupSettings = (setupSettings sizedSnap) {settingZoomMode = FixedHalfHeight h}}
          camera = manualCamera 0 0 0
      planTerrain (request (fixed 230.4) camera) (factsOf flatWorld) `shouldBe` Left (PixelSnapUnsupported 0.3125)
      let p = either (error . show) id (planTerrain (request (fixed 72) camera) (factsOf flatWorld))
          points = [V2 (fromIntegral x / 2) (fromIntegral y / 2) | x ← [0 .. 575 ∷ Int], y ← [0 .. 287 ∷ Int], x `mod` 7 == 0, y `mod` 5 == 0]
      [pt | pt ← points, hit (pickAt p pt) == Nothing] `shouldBe` []
  it "never picks terrain above the cut, and picks the cap the cut exposes" $ do
    let slab = sceneSource [(x, y, z, 0) | x ← [-2 .. 2], y ← [-2 .. 2], z ← [0 .. 5]]
        atCut c = plan (setup 288 144) (manualCamera 0 0 c) (factsOf slab)
    hit (pickAt (atCut 5) (at 0 0)) `shouldBe` Just (tileAt 0 0 5, TopFace)
    hit (pickAt (atCut 2) (at 0 0)) `shouldBe` Just (tileAt 0 0 2, TopFace)
    case pickAt (atCut 2) (at 0 0) of
      Right (PickHit f) → faceRole f `shouldBe` RoleCap
      other → fail ("expected a hit: " <> show other)
  it "does not turn terrain nothing is known about into an authoritative answer" $ do
    let two = sceneSource [(15, 0, 0, 0), (16, 0, 0, 0)]
        ready = [ChunkKey cx cy | cx ← [-8 .. 8], cy ← [-8 .. 8], (cx, cy) /= (1, 0)]
        facts = factsWith two emptyChanges (mkAvailability [(k, [zr (-300) 300]) | k ← ready])
        p = plan (setup 288 144) (manualCamera 15 0 0) facts
    planCompleteness p `shouldBe` Incomplete
    -- Inside the known cell, away from the unknown neighbour: authoritative.
    hit (pickAt p (at (-10) 0)) `shouldBe` Just (tileAt 15 0 0, TopFace)
    -- Where the unknown neighbour would be: not a hit, and not open sky.
    pickAt p (at 60 30) `shouldBe` Right (PickIncomplete Nothing)
  it "refuses a pick whose presented identity is not the plan's" $ do
    let p = plan (setup 288 144) (manualCamera 0 0 0) (factsOf (isolated 0))
        other = (planIdentity p) {identityMaterialVersion = 8}
        newer = (planIdentity p) {identityCameraRevision = identityCameraRevision (planIdentity p) + 1}
        elsewhere = (planIdentity p) {identityVersions = Versions 1 1 2}
        cut = (planIdentity p) {identityCut = axis 1}
    forM_ [other, newer, elsewhere, cut] $ \identity →
      pickPlan p (PickQuery identity (at 0 0)) `shouldBe` Left PickStale
