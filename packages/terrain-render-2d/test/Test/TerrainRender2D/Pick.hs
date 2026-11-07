-- | Picking: exact identity, boundary conventions, snapping, version identity and
-- the refusal to answer through terrain nothing is known about.
module Test.TerrainRender2D.Pick (spec) where

import Control.Monad (forM_)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Terrain.Cell (ZRange, mkZRange)
import Hetoimasia.Terrain.Changes (emptyChanges)
import Hetoimasia.Terrain.Coordinate (TileCoord, axisMaxValue, axisMinValue)
import Hetoimasia.Terrain.Geometry (FaceKind (..))
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Render2D.Pick
import Hetoimasia.Terrain.Render2D.Plan
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..))
import Hetoimasia.Terrain.Shape (Side (..))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.TerrainRender2D.Fixtures
import Test.TerrainRender2D.Oracle (Cell3, sceneSource)

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
  it "agrees with the drawn, pixel-snapped quad, and not with the unsnapped one" $ do
    let sized settings = (setup 288 144) {setupSettings = settings}
        scene snap =
          let base = manualCamera 0 0 0
              moved = stepCamera (either (error . show) id (applyCommand defaultCameraConfig (factsOf flatWorld) (SetZoom 0.3125) base))
              panned = stepCamera (either (error . show) id (applyCommand defaultCameraConfig (factsOf flatWorld) (Pan (1 / 96) 0) moved))
           in plan (sized defaultViewSettings {settingPixelSnap = snap}) panned (factsOf (isolated 0))
        snapped = scene True
        loose = scene False
    -- Snapped, the top diamond is drawn half a pixel lower, so a point just
    -- above its upper-right edge is outside; unsnapped it is inside.
    hit (pickAt snapped (V2 150 67.75)) `shouldBe` Nothing
    hit (pickAt loose (V2 150 67.75)) `shouldBe` Just (tileAt 0 0 0, TopFace)
    hit (pickAt snapped (V2 150 70)) `shouldBe` Just (tileAt 0 0 0, TopFace)
    hit (pickAt loose (V2 150 70)) `shouldBe` Just (tileAt 0 0 0, TopFace)
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
