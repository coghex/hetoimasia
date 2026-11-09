-- | The discovery scenes the store specs replay, and the driver that runs #661's
-- operations against the page-resident store and against its plain reference
-- ('Retained') on the same candidates.
--
-- A removal or a batch is planned by the production store planner through a window
-- filled page by page from the disk; the reference applies the candidate #661
-- itself produces from its own in-memory records; after every committed step the
-- store's records, read back from pages, must equal the reference's.
module Test.TerrainRuntime.Store.Scenes
  ( Scene (..)
  , twoOpenings
  , openingA
  , openingB
  , sealedStack
  , limitsWith
  , envFor
  , Run (..)
  , newRun
  , removeCell
  , batchStep
  , drain
  , knowledgeThrough
  , compareKnowledge
  ) where

import Control.Monad (foldM)
import Hetoimasia.Terrain.Connectivity (defaultConnectivityLimits, prepareConnectivity)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Discovery
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..), defaultSourceLimits, mkSource)
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State (StoreSpec, cfgUsablePages)
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference (diskRead)

-- | A source and the cells the specs remove.
data Scene = Scene
  { sceneName ∷ String
  , sceneSpec ∷ SourceSpec
  }

-- | A cave along X with a side branch, sealed in stone below a sky at level 8: the
-- two ends are opened by removing the wall and shaft cells at either end.
twoOpenings ∷ Scene
twoOpenings =
  Scene "two openings" $
    SourceSpec
      ["stone", "slab"]
      [LayerSpec Nothing (Just 8) "stone" 0]
      ([PatchSpec x 0 5 6 SpecAir | x ← [2 .. 8]] <> [PatchSpec 5 y 5 6 SpecAir | y ← [1 .. 3]])

openingA, openingB ∷ [(Integer, Integer, Integer)]
openingA = [(1, 0, z) | z ← [5 .. 7]]
openingB = [(9, 0, z) | z ← [5 .. 7]]

-- | Solid ground to a sky at level 8 with no cave: a stack of cells removed in one
-- column makes a shaft that joins runs.
sealedStack ∷ Scene
sealedStack = Scene "sealed stack" (SourceSpec ["stone", "slab"] [LayerSpec Nothing (Just 8) "stone" 0] [])

limitsWith ∷ Integer → DiscoveryLimits
limitsWith batch = either (error . show) id (mkDiscoveryLimits spec)
  where
    spec =
      DiscoverySpec
        { specBatchUpdates = batch
        , specInspectedRecords = 100000
        , specDeltaRecords = 100000
        , specDeltaBytes = 1048576
        , specScratchBytes = 4194304
        , specPendingObligations = 65536
        , specRetainedBytes = 50331648
        , specBoundaryFaces = 1024
        }

envFor ∷ DiscoveryLimits → Scene → Env
envFor limits scene = case mkSource defaultSourceLimits (sceneSpec scene) of
  Left e → error ("source refused: " <> show e)
  Right src → case prepareConnectivity defaultConnectivityLimits src of
    Left e → error ("compilation refused: " <> show e)
    Right (conn, _) → mkEnv limits src conn

-- | The store, its disk, the plain reference and the environment.
data Run = Run
  { runH ∷ H
  , runRef ∷ Retained
  , runScene ∷ Scene
  , runBatch ∷ Integer
  , runEnv ∷ Env
  , runPlans ∷ [Plan]
  }

-- | A fresh store and reference for a scene, with the batch size of its
-- environment.
newRun ∷ StoreSpec → Scene → Integer → Run
newRun spec scene batch = Run (newH spec ident0) (newRetained (ArenaId 1)) scene batch (envFor (limitsWith batch) scene) []

-- | Remove one cell through the store's planner and apply the reference candidate.
removeCell ∷ Run → TileCoord → Either String Run
removeCell run tile = do
  let h = runH run
      env = runEnv run
      refOutcome = stageRemoval env (retainedHeader (runRef run)) (retainedProvider (runRef run)) (allowanceOf (envLimits env)) tile
  (planned, _, _) ← fillWith h (\w → planRemoval env (hStore h) w tile)
  case (refOutcome, planned) of
    (Right NoChange, NoWork) → Right run
    (Right (Staged cand), Planned plan) → do
      ref' ← either (Left . ("reference apply: " <>) . show) Right (applyCandidate cand (runRef run))
      h' ← commitPlan h plan
      let run' = run {runH = h', runRef = ref', runPlans = plan : runPlans run}
      compareRecords (retainedRecords ref') h'
      checkH h'
      Right run'
    other → Left ("reference and store disagree: " <> show other)

-- | One discovery batch through the store, mirrored on the reference with the same
-- number of structural updates.
batchStep ∷ Run → Either String (Run, Bool)
batchStep run = do
  let h = runH run
      env = runEnv run
  (planned, _, _) ← fillWith h (planDiscovery env (hStore h))
  case planned of
    NoWork → Right (run, False)
    Planned plan → do
      let n = toInteger (mUpdates (plMeasure plan))
          envN = envFor (limitsWith n) (runScene run)
      refStep ← either (Left . ("reference: " <>) . show) Right (stepDiscovery envN (retainedHeader (runRef run)) (retainedProvider (runRef run)) (allowanceOf (envLimits envN)))
      cand ← case refStep of
        Progress c _ → Right c
        other → Left ("reference did not progress: " <> show other)
      ref' ← either (Left . show) Right (applyCandidate cand (runRef run))
      h' ← commitPlan h plan
      compareRecords (retainedRecords ref') h'
      checkH h'
      Right (run {runH = h', runRef = ref', runPlans = plan : runPlans run}, True)
    other → Left ("discovery planning: " <> show other)

-- | Run batches until no obligation remains.
drain ∷ Run → Either String (Run, Int)
drain = go 0
  where
    go n run
      | n > (2000 ∷ Int) = Left "discovery did not drain"
      | otherwise = do
          (run', progressed) ← batchStep run
          if progressed then go (n + 1) run' else Right (run', n)

-- | A knowledge query through the store, fetching pages as the provider needs them.
knowledgeThrough ∷ H → (Provider → Observed a) → Either String a
knowledgeThrough h q = go (storeWindow (hStore h)) (0 ∷ Int)
  where
    go w n
      | n > 500 = Left "query did not settle"
      | otherwise = case either (const (Left (MissingRecord (KeyTodo 0)))) (\prov → observedValue (q prov)) (providerAt (hStore h) w) of
          Right a → Right a
          Left (MissingRecord key) → case missingAt (hStore h) w key of
            Right (Right (Just p)) → case diskRead (hDisk h) p of
              Nothing → Left ("missing page " <> show p)
              Just bs → either (Left . show) (\w' → go w' (n + 1)) (windowInsert (cfgUsablePages (hCfg h)) p bs w)
            Right (Right Nothing) → Left "record unavailable but no page named"
            Right (Left why) → Left (show why)
            Left refusal → Left (show refusal)
          Left other → Left ("query unresolved: " <> show other)

compareKnowledge ∷ Run → [TileCoord] → Either String ()
compareKnowledge run tiles = foldM one () tiles
  where
    env = runEnv run
    one () t = do
      let expected = observedValue (queryCell env (retainedProvider (runRef run)) t)
      actual ← knowledgeThrough (runH run) (\p → queryCell env p t)
      if expected == Right actual then Right () else Left ("knowledge differs at " <> show t <> ": " <> show (expected, actual))
