-- | The projection, view mapping and facing turns, against hand-stated numbers.
module Test.TerrainRender2D.Projection (spec) where

import Control.Monad (forM_)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Mapping (worldToTarget, worldToWindow)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot (Viewport (..))
import Hetoimasia.Terrain.Render2D.Plan
import Hetoimasia.Terrain.Render2D.Projection
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.TerrainRender2D.Fixtures

spec ∷ Spec
spec = describe "Projection" $ do
  it "uses the 96-pixel tile, 48-pixel top and 16-pixel elevation proportions" $ do
    (tileWidthPixels, tileTopPixels, elevationPixels) `shouldBe` (96, 48, 16)
    isoProject (1, 0, 0) `shouldBe` (48, 24)
    isoProject (0, 1, 0) `shouldBe` (-48, 24)
    isoProject (1, 1, 0) `shouldBe` (0, 48)
    isoProject (0, 0, 1) `shouldBe` (0, -16)
    -- The direction toward the camera projects to a single point.
    isoProject (1, 1, 3) `shouldBe` (0, 0)
    isoProject (2, 2, 6) `shouldBe` (0, 0)

  describe "facing turns" $ do
    it "takes East to South, South to West and West to North, as a compass turn" $ do
      turnOffset 1 (1, 0) `shouldBe` (0, 1)
      turnOffset 2 (1, 0) `shouldBe` (-1, 0)
      turnOffset 3 (1, 0) `shouldBe` (0, -1)
      turnOffset 1 (0, 1) `shouldBe` (-1, 0)
      turnOffset 4 (3, -2) `shouldBe` (3, -2)
      turnOffset (-1) (1, 0) `shouldBe` (0, -1)
    it "turns the offsets of the four facings the way the shape facings turn masks" $ do
      -- An East mask becomes North at the West facing: the world East
      -- offset is the view North offset (0, -1).
      viewOffset FaceSouth (1, 0) `shouldBe` (1, 0)
      viewOffset FaceWest (1, 0) `shouldBe` (0, -1)
      viewOffset FaceNorth (1, 0) `shouldBe` (-1, 0)
      viewOffset FaceEast (1, 0) `shouldBe` (0, 1)
    it "is undone by the inverse for every facing and offset" $
      forM_ allFacings $ \facing →
        forM_ [(x, y) | x ← [-3, 0, 2, 7], y ← [-5, 1, 4]] $ \offset →
          worldOffset facing (viewOffset facing offset) `shouldBe` offset

  describe "the render view" $ do
    let view facing frac zoom vs = either (\e → error (show e)) id (mkRenderView vs zoom facing frac)
        vs0 = setup 288 144
    it "puts the camera at the origin when it is at the anchor tile's centre, in every facing" $
      forM_ allFacings $ \facing →
        rvCentre (view facing (1 / 2, 1 / 2) 1 vs0) `shouldBe` (0, 0)
    it "projects the turned fractional offset of the camera" $ do
      -- Offset (1/4, 0) from the centre: iso (12, 6) at South; one turn makes
      -- it (0, 1/4), which is (-12, 6).
      rvCentre (view FaceSouth (3 / 4, 1 / 2) 1 vs0) `shouldBe` (12, 6)
      rvCentre (view FaceEast (3 / 4, 1 / 2) 1 vs0) `shouldBe` (-12, 6)
      rvCentre (view FaceNorth (3 / 4, 1 / 2) 1 vs0) `shouldBe` (-12, -6)
      rvCentre (view FaceWest (3 / 4, 1 / 2) 1 vs0) `shouldBe` (12, -6)
    it "shows the anchor at the viewport centre, scaled by zoom, with a viewport offset" $ do
      let vs = ViewSetup (TargetMetrics (PixelExtent 400 200) (PixelExtent 400 200) 1 1) (Viewport (V2 100 50) (V2 200 100)) defaultViewSettings
          v1 = view FaceSouth (1 / 2, 1 / 2) 1 vs
          v2 = view FaceSouth (1 / 2, 1 / 2) 2 vs
      worldToTarget (rvMapping v1) (V2 0 0) `shouldBe` Just (V2 200 100)
      worldToTarget (rvMapping v1) (V2 48 24) `shouldBe` Just (V2 248 124)
      worldToTarget (rvMapping v2) (V2 48 24) `shouldBe` Just (V2 296 148)
    it "maps through unequal logical and framebuffer extents" $ do
      let vs = ViewSetup (TargetMetrics (PixelExtent 200 100) (PixelExtent 400 200) 2 2) (Viewport (V2 0 0) (V2 400 200)) defaultViewSettings
          v = view FaceSouth (1 / 2, 1 / 2) 1 vs
      -- The centre is framebuffer (200, 100), window (100, 50).
      worldToWindow (rvMapping v) (V2 0 0) `shouldBe` Just (V2 100 50)
      worldToWindow (rvMapping v) (V2 48 24) `shouldBe` Just (V2 124 62)
    it "refuses a non-finite zoom and non-finite metrics" $ do
      mkRenderView vs0 (0 / 0) FaceSouth (1 / 2, 1 / 2) `shouldSatisfy` isLeft
      mkRenderView vs0 (1 / 0) FaceSouth (1 / 2, 1 / 2) `shouldSatisfy` isLeft
      mkRenderView vs0 0 FaceSouth (1 / 2, 1 / 2) `shouldSatisfy` isLeft
      mkRenderView (vs0 {setupViewport = Viewport (V2 (0 / 0) 0) (V2 10 10)}) 1 FaceSouth (1 / 2, 1 / 2) `shouldSatisfy` isLeft
    it "keeps the half-pixel snapping promise of render-2d for the camera" $ do
      let snap = vs0 {setupSettings = defaultViewSettings {settingPixelSnap = True}}
          frac = (1 / 2 + 1 / 96, 1 / 2)
          snapped = view FaceSouth frac 1 snap
          loose = view FaceSouth frac 1 vs0
      -- The camera sits at the centre (144, 72) unsnapped, and within half a
      -- pixel of it snapped.
      worldToTarget (rvMapping loose) (V2 0.5 0.25) `shouldBe` Just (V2 144 72)
      case worldToTarget (rvMapping snapped) (V2 0.5 0.25) of
        Just (V2 sx sy) → do
          abs (sx - 144) `shouldSatisfy` (<= 0.5)
          abs (sy - 72) `shouldSatisfy` (<= 0.5)
        Nothing → expectationFailure "the snapped mapping must convert the camera position"

  describe "an empty or invalid view in a plan" $ do
    it "plans no faces for a zero extent, and refuses an invalid view" $ do
      let camera = manualCamera 0 0 0
          facts = factsOf flatWorld
          empty = plan (setup 0 0) camera facts
      planFaces empty `shouldBe` []
      planCompleteness empty `shouldBe` Complete
      planWith id ((setup 288 144) {setupViewport = Viewport (V2 0 0) (V2 (0 / 0) 10)}) camera facts `shouldSatisfy` isLeft

isLeft ∷ Either a b → Bool
isLeft (Left _) = True
isLeft _ = False
