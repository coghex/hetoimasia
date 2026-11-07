-- | The evidence scenes on the CPU: for the whole 16 x 4 shape and facing matrix,
-- for roofs over cavities, disconnected spans, ramps and corners, cutaways at
-- several depths, the automatic follow, a deep floor and the view variants, the
-- planner's coverage and depth order, the terrain material's pure model and the
-- pure pick agree, pixel centre by pixel centre, with the hand-stated
-- line-of-sight expectation; and the judge rejects reversed overlap, an incorrect
-- coverage mask and a pick through a nearer face.
module Test.TerrainRender2D.Scenes (spec) where

import Control.Monad (forM_, unless)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import Hetoimasia.Terrain.Render2D.Evidence
import Hetoimasia.Terrain.Render2D.Plan (PlannedFace (..))
import Hetoimasia.Terrain.Render2D.Scenes
import Hetoimasia.Terrain.Shape (ViewFacing (..), allViewFacings)
import Test.Hspec (Spec, beforeAll, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Hetoimasia.Terrain.Render2D.Agreement
import Test.TerrainRender2D.Art

loadEnv ∷ IO Env
loadEnv = do
  loam ← loadApproved "loam"
  granite ← loadApproved "granite"
  pure (envWith [("loam", artPixelsOf (approvedDecoded loam)), ("granite", artPixelsOf (approvedDecoded granite)), ("diagnostic", diagnosticSheet)])

-- | The pixels judged of a scene: about this many.
budget ∷ Int
budget = 3000

zip' ∷ Ord k ⇒ Map.Map k v → [(k, v)]
zip' = Map.toList

agrees ∷ Env → Scene → IO Judged
agrees env sc = do
  let judged = judge env normal (stride budget (sceneTarget sc)) sc
  unless (null (judgedMismatches judged)) $
    expectationFailure (unlines (take 8 (judgedMismatches judged)) <> show (length (judgedMismatches judged)) <> " mismatches of " <> show (judgedCompared judged))
  judgedCompared judged `shouldSatisfy` (>= 100)
  judgedCovered judged `shouldSatisfy` (> 0)
  pure judged

spec ∷ Spec
spec = beforeAll loadEnv $ describe "Terrain scenes against the hand-stated expectation" $ do
  describe "the 16 shapes in the 4 facings" $ do
    forM_ allViewFacings $ \facing →
      it ("agree for every identity facing " <> show facing) $ \env →
        forM_ [0 .. 15] $ \shape → do
          _ ← agrees env (singleShape shape facing)
          pure ()

    forM_ allViewFacings $ \facing →
      it ("divide their hexagon into faces of their own for every identity but 0 and 15, which share the flat one, facing " <> show facing) $ \env → do
        let partitions = [(shape, surfaces env (singleShape shape facing) 2) | shape ← [0 .. 15 ∷ Int]]
        [(a, b) | (a, sa) ← partitions, (b, sb) ← partitions, a < b, sa == sb] `shouldBe` [(0, 15)]

  describe "occlusion and cutaway" $ do
    forM_ allViewFacings $ \facing → do
      it ("roofs over a cavity, with the roof and with it cut away, facing " <> show facing) $ \env → do
        _ ← agrees env (roofOverCavity 2 facing)
        _ ← agrees env (roofOverCavity 1 facing)
        pure ()
      it ("a column with air between its spans beside nearer columns, facing " <> show facing) $ \env → () <$ agrees env (disconnectedSpans facing)
      it ("ramps and corners around a block, facing " <> show facing) $ \env → () <$ agrees env (rampsCorners facing)

    forM_ [1, 3, 5] $ \cut →
      it ("a staircase cut at level " <> show cut) $ \env → () <$ agrees env (staircase cut FaceSouth)

    it "the follow with its own 25-level headroom over authored varied heights" $ \env → () <$ agrees env (followHeadroom FaceSouth)
    it "a floor 34 levels below the cut, deeper than a 32-level band and inside the 250-level cap" $ \env → () <$ agrees env (deepFloor FaceSouth)

  describe "view variants" $ do
    forM_ [0.125, 0.5, 1, 1.5, 4, 8] $ \zoom →
      it ("zoom " <> show zoom) $ \env → () <$ agrees env (zoomEndpoint zoom)
    it "a fractional camera at an intermediate zoom" $ \env → () <$ agrees env fractionalCamera
    it "a viewport away from the target's corner" $ \env → () <$ agrees env viewportOffset
    it "a target of content scale 2" $ \env → () <$ agrees env scaledTarget
    it "pixel snapping at a zoom whose scale is a multiple of 1/8" $ \env → () <$ agrees env snapped

  describe "transparent coverage" $ do
    forM_ allViewFacings $ \facing →
      it ("a transparent part of a nearer cell's sheet shows what lies behind it, and does not change what is picked, facing " <> show facing) $ \env → do
        let sc = diagnosticOverlap facing
        contacts sc `shouldBe` []
        -- Every pixel: a hole is a few pixels of a few cells' overlap.
        let judged = judge env normal 1 sc
        judgedMismatches judged `shouldBe` []
        judgedHoles judged `shouldSatisfy` (> 0)
        judgedReveals judged `shouldSatisfy` (> 0)

  describe "the expectation in Double arithmetic (what the native scenario judges every pixel with)" $
    it "decides what the exact model decides, on every compared pixel of several scenes" $ \env → do
      let Env sheets = env
          art name = lookup name (zip' sheets)
          scenesChecked = [singleShape 5 FaceSouth, rampsCorners FaceWest, roofOverCavity 1 FaceNorth, disconnectedSpans FaceEast, followHeadroom FaceSouth, diagnosticOverlap FaceWest]
          answer = \case
            ExpectedHit {expectedFront = hit, expectedShown = shown} → Just (Just (hitCell hit, hitKind hit, hitSurface hit, fmap (\(h, rgba) → (hitCell h, rgba)) shown))
            ExpectedClear → Just Nothing
            Ambiguous _ → Nothing
      forM_ scenesChecked $ \sc → do
        let camera = sceneCameraFollowed sc
            plan = either (\e → error (show e)) id (scenePlan sc)
            step = stride 2500 (sceneTarget sc)
            (w, h) = sceneTarget sc
            pixels = [(x, y) | y ← [1, 1 + step .. h - 1], x ← [1, 1 + step .. w - 1]]
            pairs = [(answer (expectedAt art sc camera plan p), answer (expectedAtFast art sc camera plan p)) | p ← pixels]
            decided = [(exact, fast) | (Just exact, Just fast) ← pairs]
        [(exact, fast) | (exact, fast) ← decided, exact /= fast] `shouldBe` []
        length decided `shouldSatisfy` (> length pairs `div` 2)

  describe "negative controls (each is broken once, here, on the scene that makes the behaviour matter)" $ do
    let overlap = disconnectedSpans FaceSouth
        ramps = rampsCorners FaceSouth
        compared env config sc = judge env config 2 sc

    it "rejects reversed overlap: every depth key negated in order" $ \env → do
      let reversed faces =
            let keys = sortOn Down (map faceDepthKey faces)
             in [f {faceDepthKey = k} | (f, k) ← zip (sortOn faceDepthKey faces) keys]
      judgedMismatches (compared env normal overlap) `shouldBe` []
      judgedMismatches (compared env normal {configFaces = reversed} overlap) `shouldSatisfy` (not . null)

    it "rejects an incorrect coverage mask: every face covered by the whole of its quad" $ \env → do
      let wholeQuad faces = [f {faceMask = [(0, 0), (1, 0), (1, 1), (0, 1)]} | f ← faces]
      judgedMismatches (compared env normal ramps) `shouldBe` []
      judgedMismatches (compared env normal {configFaces = wholeQuad} ramps) `shouldSatisfy` (not . null)

    it "rejects picking through a nearer face: the backmost face under the point answers" $ \env → do
      judgedMismatches (compared env normal overlap) `shouldBe` []
      judgedMismatches (compared env backmost overlap) `shouldSatisfy` (not . null)
