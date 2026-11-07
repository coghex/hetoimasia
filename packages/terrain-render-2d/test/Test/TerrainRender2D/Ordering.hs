-- | Front/back order and picking against an independent visibility oracle.
--
-- Each scene is a small explicit list of cells. For a lattice of render-world
-- points the oracle ('sceneHit') casts an exact ray through every cell of the
-- scene below the cut and reports the nearest face it enters; the plan's pick
-- at the same point must name the same tile and face kind, or the plan must
-- report open sky. A reversed order, a missing cap, a face shown above the cut
-- or a pick through a nearer face each disagrees with the oracle somewhere.
module Test.TerrainRender2D.Ordering (spec, Scene (..), scenes, withFacing, targetOf) where

import Control.Monad (forM_)
import Data.List (sortOn)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Geometry (FaceKind)
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.Pick
import Hetoimasia.Terrain.Render2D.Plan
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.TerrainRender2D.Fixtures
import Test.TerrainRender2D.Oracle

-- | A named scene and the cut it is viewed at.
data Scene = Scene
  { sceneName ∷ String
  , sceneCut ∷ Integer
  , sceneCells ∷ [Cell3]
  }

flatSlab ∷ Integer → Integer → [Integer] → [Cell3]
flatSlab lo hi zs = [(x, y, z, 0) | x ← [lo .. hi], y ← [lo .. hi], z ← zs]

scenes ∷ [Scene]
scenes =
  [ -- Ground, with a tower floating three levels above it: a gap, a roof.
    Scene "ground with a floating tower" 10 (flatSlab (-3) 3 [0] <> [(0, 0, 3, 0), (0, 0, 4, 0), (1, 1, 2, 0)])
  , -- Ramps and corners meeting a higher block.
    Scene
      "ramps, corners and a high block"
      10
      ( flatSlab (-2) 3 [0]
          <> [(0, 0, 1, 1), (1, 0, 1, 3), (0, 1, 1, 5), (-1, -1, 1, 12), (2, 2, 1, 0), (2, 2, 2, 0)]
      )
  , -- A roof over a cavity; viewed below the roof the cavity is open.
    Scene
      "roof over a cavity, cut below the roof"
      1
      (flatSlab (-2) 2 [0] <> [(x, y, 2, 0) | x ← [-1 .. 1], y ← [-1 .. 1]] <> [(-1, -1, 1, 0), (1, 1, 1, 0)])
  , Scene
      "roof over a cavity, cut at the roof"
      2
      (flatSlab (-2) 2 [0] <> [(x, y, 2, 0) | x ← [-1 .. 1], y ← [-1 .. 1]] <> [(-1, -1, 1, 0), (1, 1, 1, 0)])
  , -- Every shape, in a grid, with a stepped block behind.
    Scene
      "all sixteen shapes"
      5
      ([(toInteger (i `mod` 4) - 1, toInteger (i `div` 4) - 1, 0, i) | i ← [0 .. 15 ∷ Int]] <> [(-2, -2, 0, 0), (-2, -2, 1, 0), (3, 3, 0, 0), (3, 3, 1, 0), (3, 3, 2, 0)])
  , -- Two disconnected spans in one column with a long gap between them.
    Scene "disconnected spans" 8 ([(0, 0, 0, 0), (0, 0, 6, 0), (0, 0, 7, 4), (1, 0, 6, 0), (0, 1, 7, 0), (1, 1, 2, 0)])
  ]

-- | The camera of a request at a facing, the zoom and anchor unchanged.
withFacing ∷ ViewFacing → CameraState → CameraState
withFacing facing camera =
  either (\e → error (show e)) stepCamera (applyCommand defaultCameraConfig (factsOf flatWorld) (SetFacing facing) camera)

-- | The target pixel of a render-world point for the 480 x 320 test view.
targetOf ∷ (Rational, Rational) → V2
targetOf (x, y) = V2 (fromRational (x + 240)) (fromRational (y + 160))

spec ∷ Spec
spec = describe "Ordering and visibility against the ray oracle" $ do
  forM_ scenes $ \scene →
    forM_ allFacings $ \facing →
      it (sceneName scene <> " seen from " <> show facing <> ": every sampled pick equals the nearest ray hit") $ do
        let cells = sceneCells scene
            facts = factsOf (sceneSource cells)
            camera = withFacing facing (manualCamera 0 0 (sceneCut scene))
            p = plan (setup 480 320) camera facts
            ref = sceneCut scene + 1
            samples = lattice (-230) 230 (-150) 150 13
            mismatches =
              [ (point, expected, actual)
              | point ← samples
              , let expected = sceneHit facing ref (sceneCut scene) cells point
              , let actual = case pickPlan p (PickQuery (planIdentity p) (targetOf point)) of
                      Right (PickHit face) → Just (faceCell face, faceViewKind face)
                      Right PickNoHit → Nothing
                      other → error ("unexpected pick " <> show other)
              , expected /= actual
              ]
        planCompleteness p `shouldBe` Complete
        -- The lattice must actually meet terrain, or agreement would be vacuous.
        length [() | point ← samples, Just _ ← [sceneHit facing ref (sceneCut scene) cells point]] `shouldSatisfy` (> 60)
        case mismatches of
          [] → pure ()
          (first : _) → expectationFailure (show (length mismatches) <> " mismatches, first: " <> show first)

  it "gives the same faces and keys whatever order the scene is enumerated in" $ do
    let scene = scenes !! 1
        facts cells = factsOf (sceneSource cells)
        camera = manualCamera 0 0 (sceneCut scene)
        keys cells = faceKeys (plan (setup 480 320) camera (facts cells))
    keys (sceneCells scene) `shouldBe` keys (reverse (sceneCells scene))
    keys (sceneCells scene) `shouldBe` keys (sortOn (\(x, y, z, _) → (y, z, x)) (sceneCells scene))

  it "gives every face a distinct key below 2^24, back to front" $ do
    let scene = scenes !! 4
        p = plan (setup 480 320) (manualCamera 0 0 (sceneCut scene)) (factsOf (sceneSource (sceneCells scene)))
        keys = map faceDepthKey (planFaces p)
    keys `shouldBe` [0 .. fromIntegral (length keys) - 1]
    keys `shouldSatisfy` all (< 16777216)

faceKeys ∷ Plan → [(TileCoord, FaceKind, Int, Double)]
faceKeys p = [(faceCell f, faceViewKind f, faceIndex f, fromIntegral (faceDepthKey f)) | f ← planFaces p]
