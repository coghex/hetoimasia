-- | #661's removals and discovery replayed through the page-resident store.
--
-- Every step is planned by the production planner against pages read back from the
-- disk (never a heap index), committed through the transaction model, and compared
-- with the plain reference ('Retained') that applies the very candidate #661
-- produced. Knowledge is then read through fresh windows (the caches dropped) and
-- must equal the reference's, so known solid, known void and pending work keep
-- their distinct meanings across the round trip, two openings keep their obligations
-- and a pending continuation survives between batches.
module Test.TerrainRuntime.Store.Replay (spec) where

import Control.Monad (foldM, forM_)
import Data.Either (isRight)
import Hetoimasia.Terrain.Discovery
import Hetoimasia.Terrain.Residency (ArenaId (..), Revision (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference (diskWrites)
import Test.TerrainRuntime.Store.Scenes

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

cellsOf ∷ [(Integer, Integer, Integer)] → [Integer] → Run → Either String Run
cellsOf cells _ run = foldM (\r (x, y, z) → removeCell r (tileAt x y z)) run cells

probes ∷ [(Integer, Integer, Integer)]
probes = [(x, y, z) | x ← [0 .. 10], y ← [-1 .. 4], z ← [4 .. 8]]

spec ∷ Spec
spec = describe "#661's records replayed through the page-resident store" $ do
  it "opens one end, drains the discovery and reads the same knowledge back through fresh windows" $ do
    let run0 = newRun smallSpec twoOpenings 64
    r1 ← must (cellsOf openingA [] run0)
    (r2, batches) ← must (drain r1)
    batches `shouldSatisfy` (> 0)
    pendingObligations (storeHeader (hStore (runH r2))) `shouldBe` 0
    must (compareKnowledge r2 [tileAt x y z | (x, y, z) ← probes])
    -- the cave is known, the side branch too; a sealed wall beyond is still unknown
    must (knowledgeThrough (runH r2) (\p → queryCell (runEnv r2) p (tileAt 5 3 5)))
      `shouldReturn` CellKnowledge NoSolid VoidKnown
  it "keeps the known, unknown and pending distinction before any batch runs" $ do
    let run0 = newRun smallSpec twoOpenings 64
    r1 ← must (cellsOf openingA [] run0)
    -- nothing is discovered until a batch inspects the obligations, yet they are stored
    pendingObligations (storeHeader (hStore (runH r1))) `shouldSatisfy` (> 0)
    pend ← must (knowledgeThrough (runH r1) (\p → queryObligation (runEnv r1) (storeHeader (hStore (runH r1))) p 0))
    pend `shouldSatisfy` (/= Nothing)
    must (compareKnowledge r1 [tileAt x y z | (x, y, z) ← probes])
  it "takes two openings with partial batches and a pending continuation between them" $ do
    let run0 = newRun smallSpec twoOpenings 1
    r1 ← must (cellsOf openingA [] run0)
    (r2, _) ← must (batchStep r1)
    pendingObligations (storeHeader (hStore (runH r2))) `shouldSatisfy` (> 0)
    r3 ← must (cellsOf openingB [] r2)
    (r4, _) ← must (drain r3)
    pendingObligations (storeHeader (hStore (runH r4))) `shouldBe` 0
    must (compareKnowledge r4 [tileAt x y z | (x, y, z) ← probes])
    -- every plan stayed inside the transaction bounds
    forM_ (runPlans r4) $ \p → do
      mPagesWritten (plMeasure p) `shouldSatisfy` (<= 256)
      ramTotal (mRam (plMeasure p)) `shouldSatisfy` (<= 4 * 1024 * 1024)
      mUpdates (plMeasure p) `shouldSatisfy` (<= 64)
  it "joins runs and aliases in a stack and reads them back" $ do
    let run0 = newRun smallSpec sealedStack 4
        col = [(3, 3, z) | z ← [4, 6, 5, 7, 3]]
    r1 ← must (cellsOf col [] run0)
    (r2, _) ← must (drain r1)
    must (compareKnowledge r2 [tileAt 3 3 z | z ← [0 .. 9]])
  it "appends nothing for air and for a cell already removed" $ do
    let run0 = newRun smallSpec sealedStack 64
    r1 ← must (removeCell run0 (tileAt 0 0 3))
    let v1 = storeVersion (hStore (runH r1))
    r2 ← must (removeCell r1 (tileAt 0 0 3)) -- already removed
    r3 ← must (removeCell r2 (tileAt 0 0 20)) -- air above the sky
    storeVersion (hStore (runH r3)) `shouldBe` v1
    diskWrites (hDisk (runH r3)) `shouldBe` diskWrites (hDisk (runH r1))
  it "refuses a stale plan and plans again against the new base instead of relabelling" $ do
    let run0 = newRun smallSpec sealedStack 64
        h = runH run0
        env = runEnv run0
    (a, _, _) ← must (fillWith h (\w → planRemoval env (hStore h) w (tileAt 1 1 3)))
    (b, _, _) ← must (fillWith h (\w → planRemoval env (hStore h) w (tileAt 2 2 3)))
    case (a, b) of
      (Planned pa, Planned pb) → do
        h1 ← must (commitPlan h pa)
        either Just (const Nothing) (admit pb (hStore h1)) `shouldBe` Just StalePlan
        (c, _, _) ← must (fillWith h1 (\w → planRemoval env (hStore h1) w (tileAt 2 2 3)))
        c `shouldSatisfy` (\p → case p of Planned _ → True; _ → False)
      _ → expectationFailure "both removals should plan"
  it "reports which revision a plan advances and checks the arithmetic" $ do
    let run0 = newRun smallSpec twoOpenings 64
    r1 ← must (cellsOf [(1, 0, 5)] [] run0)
    case runPlans r1 of
      (p : _) → do
        effTerrain (plEffects p) `shouldBe` True
        effFrontier (plEffects p) `shouldBe` False
        let Authority (ArenaId a) (Revision c) (Revision k) (Revision s) = effAuthority (plEffects p)
        (a, c, k, s) `shouldBe` (1, 1, 0, 1)
      [] → expectationFailure "a plan was expected"
    isRight (checkH (runH r1)) `shouldBe` True
