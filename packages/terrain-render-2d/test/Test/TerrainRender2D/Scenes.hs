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
import Hetoimasia.Terrain.Coordinate (axisValue)
import Hetoimasia.Terrain.Render2D.Camera (camAnchorX, camAnchorY, camClip, camRef, camSurface)
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

    it "the follow with its own 25-level headroom over authored varied heights, on the anchor column it follows" $ \env → do
      let sc = followHeadroom FaceSouth
          camera = sceneCameraFollowed sc
          plan = either (\e → error (show e)) id (scenePlan sc)
          Env sheets = env
          art = (`Map.lookup` sheets)
          (w, h) = sceneTarget sc
          hits = [hit | y ← [0 .. h - 1], x ← [0 .. w - 1], ExpectedHit {expectedFront = hit} ← [expectedAt art sc camera plan (x, y)]]
      -- Hand-stated: the anchor column (0, 0) holds levels 0 to 3, so the surface is 3, the cut is the surface plus 25 and the reference the surface's top plane.
      (axisValue (camAnchorX camera), axisValue (camAnchorY camera)) `shouldBe` (0, 0)
      fmap axisValue (camSurface camera) `shouldBe` Just 3
      (axisValue (camClip camera), camRef camera) `shouldBe` (28, 4)
      -- The cut shows the tall columns' tops at level 28 and nothing above it.
      maximum [z | Hit {hitCell = (_, _, z)} ← hits] `shouldBe` 28
      length [() | Hit {hitCell = (2, 1, 28), hitKind = Top} ← hits] `shouldSatisfy` (> 0)
      () <$ agrees env sc
    it "a floor 34 levels below the cut, deeper than a 32-level band and inside the 250-level cap" $ \env → () <$ agrees env (deepFloor FaceSouth)

  describe "view variants" $ do
    forM_ [0.125, 0.5, 1, 1.5, 4, 8] $ \zoom →
      it ("zoom " <> show zoom) $ \env → () <$ agrees env (zoomEndpoint zoom)
    it "a fractional camera at an intermediate zoom" $ \env → () <$ agrees env fractionalCamera
    it "a viewport away from the target's corner, the rest of the target left clear" $ \env → do
      let sc = viewportOffset 0.5
          (vx, vy, vw, vh) = sceneViewport sc
          (w, h) = sceneTarget sc
          camera = sceneCameraFollowed sc
          plan = either (\e → error (show e)) id (scenePlan sc)
          fullPlan = either (\e → error (show e)) id (scenePlan sc {sceneViewport = (0, 0, fromIntegral w, fromIntegral h)})
          Env sheets = env
          art = (`Map.lookup` sheets)
          outside = [(x, y) | x ← [0 .. w - 1], y ← [0 .. h - 1], fromIntegral x + 0.5 < vx || fromIntegral x + 0.5 > vx + vw || fromIntegral y + 0.5 < vy || fromIntegral y + 0.5 > vy + vh]
          covered e = case e of
            ExpectedHit {} → True
            _ → False
      -- The viewport is a real offset: it does not start at the corner and stops short of the far edges.
      (vx > 0, vy > 0, vx + vw < fromIntegral w, vy + vh < fromIntegral h) `shouldBe` (True, True, True, True)
      -- Nothing is drawn outside it, though the scene would cover pixels there without it.
      length [p | p ← outside, covered (expectedAt art sc camera plan p)] `shouldBe` 0
      length [p | p ← outside, covered (expectedAt art sc camera fullPlan p)] `shouldSatisfy` (> 50)
      _ ← agrees env sc
      pure ()
    it "a target of content scale 2" $ \env → () <$ agrees env scaledTarget
    it "pixel snapping at native scale with the camera off the pixel grid, which moves pixels the unsnapped view keeps" $ \env → do
      let unsnapped = snapped {sceneSnap = False}
          Env sheets = env
          art = (`Map.lookup` sheets)
          expectation sc = [expectedAt art sc (sceneCameraFollowed sc) (either (\e → error (show e)) id (scenePlan sc)) p | p ← [(x, y) | x ← [0 .. fst (sceneTarget sc) - 1], y ← [0 .. snd (sceneTarget sc) - 1]]]
          decided e = case e of
            Ambiguous _ → False
            _ → True
          differing = [() | (a, b) ← zip (expectation snapped) (expectation unsnapped), decided a, decided b, a /= b]
      length differing `shouldSatisfy` (> 20)
      () <$ agrees env snapped

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
