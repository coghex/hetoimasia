-- | Examples for the discovery model (TRA-19).
--
-- Every scene is an authored world small enough for the explicit oracle of
-- "Test.Terrain.DiscoveryHarness" to flood cell by cell. Each trace is a list of
-- ordered events (removals, discovery batches, drains); after every event the
-- retained state is checked for legitimacy and the production knowledge is
-- checked against the oracle's sandwich (see the harness), and when the
-- obligations are drained against the oracle exactly. A failure names the
-- scene, the event and the cell. Generated traces are pure functions of a
-- printed seed.
module Test.Terrain.Discovery (spec) where

import Control.Monad (forM_)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Hetoimasia.Terrain.Cell (Column (..))
import Hetoimasia.Terrain.Changes (ChangeLimits (..), changesFromIntervals, removedIntervals)
import Hetoimasia.Terrain.Coordinate (TileCoord, axisFromInteger)
import Hetoimasia.Terrain.Discovery
import Hetoimasia.Terrain.Query (cellAt)
import Hetoimasia.Terrain.Residency (ArenaId (..), Revision (..))
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..))
import Test.Hspec
import Test.Terrain.ConnectivityFixtures (R, below, runR)
import Test.Terrain.ConnectivityOracle (Cell3, Window (..))
import Test.Terrain.DiscoveryHarness
import Test.Terrain.Model (highest, lowest, mustSource, mustTile, topEnd)

-- ---------------------------------------------------------------------------
-- Traces

data Action
  = Edit Cell3
  | Batch Allowance
  | Drain Allowance
  | Replay
  -- ^ Rebuild the retained value from its own records alone.

showAction ∷ Action → String
showAction (Edit c) = "edit " <> show c
showAction (Batch _) = "batch"
showAction (Drain _) = "drain"
showAction Replay = "replay"

apply ∷ Action → Rig → Rig
apply (Edit c) rig = fst (editRig fullAllowance c rig)
apply (Batch a) rig = fst (batchRig a rig)
apply (Drain a) rig = drainRig a rig
apply Replay rig = case retainedFromRecords (retainedHeader (rigRetained rig)) (retainedRecords (rigRetained rig)) of
  Right retained → rig {rigRetained = retained}
  Left e → rig {rigLog = ("replay refused " <> show e) : rigLog rig}

-- | Run a trace, collecting the violations after every action.
runTrace ∷ Rig → [Action] → (Rig, [String])
runTrace rig0 = foldl step (rig0, check "start" rig0)
  where
    step (rig, bad) action =
      let rig' = apply action rig
       in (rig', bad <> check (showAction action) rig')
    check label rig = map ((sceneName (rigScene rig) <> ", after " <> label <> ": ") <>) (invariants rig <> compareKnowledge rig)

-- | The violations of a trace, including the exact comparison at its end.
violations ∷ Rig → [Action] → [String]
violations rig actions =
  let (end, bad) = runTrace rig actions
   in bad <> map ((sceneName (rigScene rig) <> ", at end: ") <>) (if pendingOf end == 0 then compareDrained end else [])

cleanly ∷ Rig → [Action] → Expectation
cleanly rig actions = violations rig actions `shouldBe` []

fullAllowance ∷ Allowance
fullAllowance = allowanceOf defaultDiscoveryLimits

limitsWith ∷ Integer → DiscoveryLimits
limitsWith batch = either (error . show) id (mkDiscoveryLimits baseSpec {specBatchUpdates = batch})

baseSpec ∷ DiscoverySpec
baseSpec =
  DiscoverySpec
    { specBatchUpdates = 64
    , specInspectedRecords = 100000
    , specDeltaRecords = 100000
    , specDeltaBytes = 1048576
    , specScratchBytes = 4194304
    , specPendingObligations = 65536
    , specRetainedBytes = 50331648
    }

-- ---------------------------------------------------------------------------
-- Scenes

-- | A cave along X with a side branch, sealed in stone below a sky at level 8.
twoOpenings ∷ Scene
twoOpenings =
  groundScene "two openings" 8 (-3, 13) (-3, 6) 6 $
    caveRow 0 5 2 8 <> [PatchSpec 5 y 5 6 SpecAir | y ← [1 .. 3]]

-- | The wall cell and shaft up to the sky at each end of the cave.
openingA, openingB ∷ [Cell3]
openingA = [(1, 0, z) | z ← [5 .. 7]]
openingB = [(9, 0, z) | z ← [5 .. 7]]

-- | Two sealed pockets, a sealed stack of cells that a long run will fill, and a
-- cave that will be opened to the sky.
pockets ∷ Scene
pockets =
  groundScene "sealed pockets" 8 (-3, 14) (-3, 5) 6 $
    caveRow 0 5 2 3 <> caveRow 0 5 5 6 <> caveRow 0 5 8 9

-- | A known corridor beside an N ramp whose empty side is unknown and a barrier
-- with a separate sealed cavity behind it.
ramps ∷ Scene
ramps =
  groundScene "ramp and barrier" 8 (-3, 12) (-5, 6) 6 $
    caveRow 1 5 1 7
      <> [PatchSpec 4 0 5 6 (SpecSolid "slab" 1)]
      <> [PatchSpec 4 0 6 7 (SpecSolid "stone" 0)]
      <> [PatchSpec 2 (-3) 5 6 SpecAir, PatchSpec 2 (-2) 5 6 SpecAir]

-- ---------------------------------------------------------------------------
-- Generated scenes

-- | A random 4 × 4 core of patches and a random removal sequence inside and
-- around it. All sixteen shape identities, and so all four rotations of every
-- orientable one, occur as patch content.
generatedScene ∷ Int → (Scene, [Cell3])
generatedScene seed = runR build seed
  where
    build = do
      patches ← concat <$> mapM column [(x, y) | x ← [0 .. 3], y ← [0 .. 3]]
      removals ← mapM (const removal) [1 .. 9 ∷ Int]
      pure (groundScene ("generated " <> show seed) 8 (-2, 6) (-2, 6) 6 patches, removals)
    column (x, y) = do
      present ← pick 4
      if present == 0
        then pure []
        else do
          lo ← (+ 3) <$> pick 3
          len ← (+ 1) <$> pick 2
          content ← randomContent
          pure [PatchSpec x y (toInteger lo) (toInteger (lo + len)) content]
    removal = do
      x ← pick 4
      y ← pick 4
      z ← (+ 3) <$> pick 6
      pure (toInteger x, toInteger y, toInteger z)

pick ∷ Int → R Int
pick = below

randomContent ∷ R CellSpec
randomContent = do
  r ← pick 12
  if r < 4
    then pure SpecAir
    else
      if r < 6
        then pure (SpecSolid "stone" 0)
        else (\s → SpecSolid "slab" s) <$> pick 16

-- ---------------------------------------------------------------------------

spec ∷ Spec
spec = describe "Discovery" $ do
  limitSpecs
  openingSpecs
  sealedSpecs
  shapeSpecs
  replaySpecs
  authoritySpecs

-- ---------------------------------------------------------------------------

openingSpecs ∷ Spec
openingSpecs = describe "two opposite openings" $ do
  let rig = newRig (limitsWith 64) twoOpenings
      small = newRig (limitsWith 1) twoOpenings
      batchOf n = Batch (allowanceOf (limitsWith n))
  it "start unknown, then discover the whole cavern, side branch and walls" $ do
    let (opened, _) = runTrace rig ([Edit c | c ← openingA] <> [Drain fullAllowance])
        provider = retainedProvider (rigRetained opened)
        knowledgeOf c = observedValue (queryCell (rigEnv opened) provider (mustTile3 c))
    observedValue (queryCell (rigEnv rig) (retainedProvider (rigRetained rig)) (mustTile 5 0 5)) `shouldBe` Right (CellKnowledge NoSolid VoidUnknown)
    knowledgeOf (5, 0, 5) `shouldBe` Right (CellKnowledge NoSolid VoidKnown)
    knowledgeOf (5, 3, 5) `shouldBe` Right (CellKnowledge NoSolid VoidKnown)
    -- the wall beyond the side branch is exposed to it; stone further away is not.
    (cellSolid <$> knowledgeOf (5, 4, 5)) `shouldBe` Right SolidKnown
    (cellSolid <$> knowledgeOf (5, 5, 5)) `shouldBe` Right SolidUnknown
  it "agrees with the oracle in both orders" $ do
    forM_ [openingA <> openingB, openingB <> openingA] $ \order →
      cleanly rig ([Edit c | c ← order] <> [Drain fullAllowance])
  it "agrees across every interleaving of the two openings with partial batches" $ do
    forM_ [1, 2, 3, 64] $ \n →
      forM_ (interleavings openingA openingB) $ \order →
        cleanly (newRig (limitsWith n) twoOpenings) (concat [[Edit c, batchOf n] | c ← order] <> [Drain (allowanceOf (limitsWith n))])
  it "takes the second opening immediately after the first, between batches and after partial expansion" $ do
    let one = Edit <$> openingA
        two = Edit <$> openingB
    cleanly rig (one <> two <> [Drain fullAllowance])
    cleanly small (one <> [batchOf 1] <> two <> [Drain fullAllowance])
    cleanly small (one <> [batchOf 1, batchOf 1] <> take 1 two <> [batchOf 1] <> drop 1 two <> [Drain fullAllowance])
  it "finds an exit to known exterior without ending the discovery of the rest" $ do
    -- one opening reaches the sky first; the obligations of the other front,
    -- queued behind it, must still be inspected.
    let (end, bad) = runTrace small ([Edit c | c ← openingA <> openingB] <> [batchOf 1])
    bad `shouldBe` []
    pendingOf end `shouldSatisfy` (> 0)
    compareDrained (drainRig fullAllowance end) `shouldBe` []

interleavings ∷ [a] → [a] → [[a]]
interleavings [] ys = [ys]
interleavings xs [] = [xs]
interleavings (x : xs) (y : ys) = map (x :) (interleavings xs (y : ys)) <> map (y :) (interleavings (x : xs) ys)

mustTile3 ∷ Cell3 → TileCoord
mustTile3 (x, y, z) = mustTile x y z

-- ---------------------------------------------------------------------------

sealedSpecs ∷ Spec
sealedSpecs = describe "raw buried removals" $ do
  let rig = newRig (limitsWith 64) pockets
      knownVoid rg c = fmap cellVoid (observedValue (queryCell (rigEnv rg) (retainedProvider (rigRetained rg)) (mustTile3 c)))
      join' = [(4, 0, 5)]
      run' = [(7, 0, 5)]
      buried = [(0, 3, z) | z ← [1 .. 6]]
      reveal = [(1, 0, z) | z ← [5 .. 7]]
  it "stay undiscovered until a real opening connects them" $ do
    let (raw, bad) = runTrace rig ([Edit c | c ← join' <> run' <> buried] <> [Drain fullAllowance])
    bad `shouldBe` []
    knownVoid raw (2, 0, 5) `shouldBe` Right VoidUnknown
    knownVoid raw (5, 0, 5) `shouldBe` Right VoidUnknown
    knownVoid raw (8, 0, 5) `shouldBe` Right VoidUnknown
    knownVoid raw (0, 3, 3) `shouldBe` Right VoidUnknown
    let (opened, bad') = runTrace raw ([Edit c | c ← reveal] <> [Drain fullAllowance])
    bad' `shouldBe` []
    -- the first pocket, the pocket the raw removal joined to it and the pocket
    -- the second removal joined are all known; the sealed stack is not.
    knownVoid opened (2, 0, 5) `shouldBe` Right VoidKnown
    knownVoid opened (5, 0, 5) `shouldBe` Right VoidKnown
    knownVoid opened (0, 3, 3) `shouldBe` Right VoidUnknown
  it "add no history for air or a repeated removal and keep outstanding work" $ do
    let (one, _) = runTrace rig [Edit (4, 0, 5)]
        (again, kind) = editRig fullAllowance (4, 0, 5) one
        (air, kindAir) = editRig fullAllowance (3, 0, 5) one
    kind `shouldBe` EditNoOp
    kindAir `shouldBe` EditNoOp
    retainedRecords (rigRetained again) `shouldBe` retainedRecords (rigRetained one)
    retainedHeader (rigRetained air) `shouldBe` retainedHeader (rigRetained one)
    pendingOf again `shouldBe` 1
  it "agrees with the oracle for a long coalesced run built in any order" $ do
    let cells = [(0, 3, z) | z ← [1 .. 6]]
    forM_ [cells, reverse cells, [cells !! 0, cells !! 2, cells !! 4, cells !! 1, cells !! 3, cells !! 5]] $ \order →
      cleanly rig ([Edit c | c ← order] <> [Drain fullAllowance] <> [Edit c | c ← reveal] <> [Drain fullAllowance])
  it "discover a removal made beside an already expanded known region" $ do
    -- open the first pocket to the sky and drain; then connect another pocket
    -- through a cell beside the already expanded region.
    cleanly rig ([Edit c | c ← reveal] <> [Drain fullAllowance, Edit (4, 0, 5), Drain fullAllowance, Edit (7, 0, 5), Drain fullAllowance])
  it "keeps known solid and known void separate" $ do
    let r = newRig (limitsWith 64) ramps
        (end, bad) = runTrace r ([Edit c | c ← [(0, 1, z) | z ← [5 .. 7]]] <> [Drain fullAllowance])
        view c = observedValue (queryCell (rigEnv end) (retainedProvider (rigRetained end)) (mustTile3 c))
    bad `shouldBe` []
    -- the corridor south of the ramp exposes its solid south face; its empty
    -- side stays unknown. The barrier between the corridor and the sealed
    -- cavity is known, the cavity is not.
    view (4, 0, 5) `shouldBe` Right (CellKnowledge SolidKnown VoidUnknown)
    (presentation <$> view (4, 0, 5)) `shouldBe` Right KnownSolidUnknownVoid
    view (2, -2, 5) `shouldBe` Right (CellKnowledge NoSolid VoidUnknown)
    (presentation <$> view (2, -2, 5)) `shouldBe` Right FullyUnknown
    (cellSolid <$> view (2, 0, 5)) `shouldBe` Right SolidKnown
    (cellSolid <$> view (2, -1, 5)) `shouldBe` Right SolidUnknown
    (presentation <$> view (2, 1, 5)) `shouldBe` Right Ordinary

-- ---------------------------------------------------------------------------

shapeSpecs ∷ Spec
shapeSpecs = describe "geometry" $ do
  it "agrees with the oracle over generated traces (all sixteen identities)" $ do
    forM_ [1 .. 40 ∷ Int] $ \seed → do
      let (scene, removals) = generatedScene seed
          rig = newRig (limitsWith 3) scene
          events = concat [[Edit c, Batch (allowanceOf (limitsWith 3))] | c ← removals] <> [Drain fullAllowance]
      cleanly rig events

-- ---------------------------------------------------------------------------

replaySpecs ∷ Spec
replaySpecs = describe "replay" $ do
  it "resumes from the retained records alone after every batch" $ do
    let rig = newRig (limitsWith 2) twoOpenings
        steps = concat [[Edit c, Batch (allowanceOf (limitsWith 2)), Replay] | c ← openingA <> openingB]
        withReplay = steps <> [Drain (allowanceOf (limitsWith 2))]
        plain = filter (not . isReplay) withReplay
    (end, bad) <- pure (runTrace rig withReplay)
    bad `shouldBe` []
    let (uninterrupted, _) = runTrace rig plain
    retainedRecords (rigRetained end) `shouldBe` retainedRecords (rigRetained uninterrupted)
    retainedHeader (rigRetained end) `shouldBe` retainedHeader (rigRetained uninterrupted)
  it "distinguishes a record not yet supplied from confirmed unknown, and resumes when it arrives" $ do
    let rig0 = newRig (limitsWith 64) twoOpenings
        (rig1, _) = runTrace rig0 [Edit c | c ← openingA]
        delayedKey = KeyTodo (hHead (retainedHeader (rigRetained rig1)))
        withheld = rig1 {rigDelay = Delay mempty (Set.singleton delayedKey)}
        (_, kind) = batchRig fullAllowance withheld
    kind `shouldBe` BatchStalled delayedKey
    pendingOf withheld `shouldBe` 3
    -- the cell's own run is not served: the query is unresolved, not unknown.
    let col = Column <$> axisFromInteger 1 <*> axisFromInteger 0
        blocked = rig1 {rigDelay = Delay (maybe mempty Set.singleton (either (const Nothing) Just col)) mempty}
    case observedValue (queryCell (rigEnv blocked) (rigProvider blocked) (mustTile3 (1, 0, 5))) of
      Left (MissingRecord _) → pure ()
      other → expectationFailure ("expected a missing record, got " <> show other)
    -- restored, the drain completes and matches the oracle.
    let restored = withheld {rigDelay = noDelay}
    compareDrained (drainRig fullAllowance restored) `shouldBe` []
  it "keeps existing logical queries independent of knowledge" $ do
    let rig = newRig (limitsWith 64) twoOpenings
        (drained, _) = runTrace rig ([Edit c | c ← openingA] <> [Drain fullAllowance])
        (partial, _) = runTrace rig [Edit c | c ← openingA]
        changesOf rg = either (error . show) id (changesFromIntervals (ChangeLimits 1000) (retainedRemovals (rigRetained rg)))
        src = mustSource (sceneSpec twoOpenings)
        answers rg = [cellAt src (changesOf rg) (mustTile3 c) | c ← cellsOfWindow twoOpenings]
    answers drained `shouldBe` answers partial
    removedIntervals (changesOf drained) (fromMaybe (error "column") (Column <$> either (const Nothing) Just (axisFromInteger 1) <*> either (const Nothing) Just (axisFromInteger 0)))
      `shouldSatisfy` (not . null)
  where
    isReplay Replay = True
    isReplay _ = False

-- ---------------------------------------------------------------------------

limitSpecs ∷ Spec
limitSpecs = describe "limits" $ do
  it "validates every field and refuses rather than clamps" $ do
    mkDiscoveryLimits baseSpec {specBatchUpdates = 0} `shouldBe` Left (LimitNotPositive FieldBatchUpdates 0)
    mkDiscoveryLimits baseSpec {specBatchUpdates = -1} `shouldBe` Left (LimitNotPositive FieldBatchUpdates (-1))
    mkDiscoveryLimits baseSpec {specBatchUpdates = 65} `shouldBe` Left (LimitUnrepresentable FieldBatchUpdates 65 64)
    mkDiscoveryLimits baseSpec {specInspectedRecords = 1} `shouldBe` Left (LimitBelowProgress FieldInspectedRecords 1 (toInteger worstEditReads))
    mkDiscoveryLimits baseSpec {specDeltaRecords = 4} `shouldBe` Left (LimitBelowProgress FieldDeltaRecords 4 (toInteger worstEditWrites))
    mkDiscoveryLimits baseSpec {specPendingObligations = 0} `shouldBe` Left (LimitNotPositive FieldPendingObligations 0)
    mkDiscoveryLimits baseSpec {specRetainedBytes = 1} `shouldBe` Left (LimitBelowProgress FieldRetainedBytes 1 (toInteger minimumRetainedBytes))
    mkDiscoveryLimits baseSpec {specScratchBytes = 2 ^ (41 ∷ Int)} `shouldBe` Left (LimitUnrepresentable FieldScratchBytes (2 ^ (41 ∷ Int)) (2 ^ (40 ∷ Int)))
    forM_ [1, 64] $ \n → mkDiscoveryLimits baseSpec {specBatchUpdates = n} `shouldSatisfy` either (const False) (const True)
  it "stops at the batch limit and continues an operation of more than 64 updates" $ do
    -- twelve removals queue 84 connections, more than one batch of 64.
    let rig0 = newRig (limitsWith 64) twoOpenings
        cells = openingA <> openingB <> [(0, 3, z) | z ← [1 .. 6]]
        (queued, _) = runTrace rig0 [Edit c | c ← cells]
        (rig1, first) = batchRig fullAllowance queued
    case first of
      BatchProgress report HaltBatchFull → reportUpdates report `shouldBe` 64
      other → expectationFailure ("expected a full batch, got " <> show other)
    pendingOf rig1 `shouldSatisfy` (> 0)
    let (rig2, second) = batchRig fullAllowance rig1
    case second of
      BatchProgress report HaltDrained → reportUpdates report `shouldBe` 20
      other → expectationFailure ("expected the last batch, got " <> show other)
    pendingOf rig2 `shouldBe` 0
    compareDrained rig2 `shouldBe` []
  it "makes progress under a batch limit of 1" $ do
    let rig0 = newRig (limitsWith 1) twoOpenings
        (queued, _) = runTrace rig0 [Edit (1, 0, 5)]
        (rig1, kind) = batchRig (allowanceOf (limitsWith 1)) queued
    case kind of
      BatchProgress report HaltBatchFull → reportUpdates report `shouldBe` 1
      other → expectationFailure ("expected one update, got " <> show other)
    pendingOf rig1 `shouldBe` 1
  it "refuses an allowance too small for one step, leaving the work pending" $ do
    let rig0 = newRig (limitsWith 64) twoOpenings
        (queued, _) = runTrace rig0 [Edit (1, 0, 5)]
        tight = fullAllowance {allowScratchBytes = 1}
        (same, kind) = batchRig tight queued
    kind `shouldSatisfy` isBlocked
    retainedRecords (rigRetained same) `shouldBe` retainedRecords (rigRetained queued)
    pendingOf same `shouldBe` 1
    -- an edit that cannot fit is refused and records nothing.
    let (nothing, editKind) = editRig fullAllowance {allowReads = 1} (1, 0, 6) queued
    editKind `shouldSatisfy` isRefused
    retainedRecords (rigRetained nothing) `shouldBe` retainedRecords (rigRetained queued)
  it "stops below the batch limit when the allowance is tighter and resumes with more" $ do
    let rig0 = newRig (limitsWith 64) twoOpenings
        (queued, _) = runTrace rig0 [Edit c | c ← openingA]
        (_, full) = batchRig fullAllowance queued
        needed = case full of BatchProgress report _ → reportWrites report; _ → 0
    needed `shouldSatisfy` (> 3)
    -- exactly the writes of the full batch is enough; one fewer stops earlier.
    let (_, exact) = batchRig fullAllowance {allowWrites = needed} queued
        (partial, fewer) = batchRig fullAllowance {allowWrites = needed - 1} queued
    case (exact, fewer) of
      (BatchProgress a HaltDrained, BatchProgress b (HaltCapacity CapacityWrites)) → do
        reportUpdates b `shouldSatisfy` (< reportUpdates a)
        pendingOf partial `shouldSatisfy` (> 0)
      other → expectationFailure ("unexpected " <> show other)
    compareDrained (drainRig fullAllowance partial) `shouldBe` []
  where
    isBlocked (BatchRefused (CapacityBlocked _ _ _)) = True
    isBlocked _ = False
    isRefused (EditRefused (CapacityBlocked _ _ _)) = True
    isRefused _ = False

-- ---------------------------------------------------------------------------

authoritySpecs ∷ Spec
authoritySpecs = describe "authority" $ do
  let rig0 = newRig (limitsWith 64) twoOpenings
  it "refuses a stale candidate and a candidate from another incarnation" $ do
    let provider = rigProvider rig0
        header = retainedHeader (rigRetained rig0)
        stage tile = case stageRemoval (rigEnv rig0) header provider fullAllowance tile of
          Right (Staged c) → c
          other → error ("expected a candidate, got " <> show other)
        a = stage (mustTile 1 0 5)
        b = stage (mustTile 9 0 5)
    applied ← either (\e → expectationFailure (show e) >> pure (rigRetained rig0)) pure (applyCandidate a (rigRetained rig0))
    applyCandidate b applied `shouldSatisfy` isStale
    applyCandidate a applied `shouldSatisfy` isStale
    applyCandidate a (newRetained (ArenaId 2)) `shouldSatisfy` isWrongArena
  it "does not apply the same frontier work twice" $ do
    let (queued, _) = runTrace rig0 [Edit c | c ← openingA]
        header = retainedHeader (rigRetained queued)
        stepOf = stepDiscovery (rigEnv queued) header (rigProvider queued) fullAllowance
    case stepOf of
      Right (Progress c _) → do
        candidateFrontierOnly c `shouldBe` False
        applied ← either (\e → expectationFailure (show e) >> pure (rigRetained queued)) pure (applyCandidate c (rigRetained queued))
        applyCandidate c applied `shouldSatisfy` isStale
      other → expectationFailure ("unexpected " <> show other)
  it "rejects revision and sequence overflow instead of wrapping" $ do
    let header = retainedHeader (rigRetained rig0)
        withAuthority f = header {hAuthority = f (hAuthority header)}
        attempt h = stageRemoval (rigEnv rig0) h (rigProvider rig0) fullAllowance (mustTile 1 0 5)
    attempt (header {hHead = maxBound, hTail = maxBound}) `shouldBe` Left AuthorityOverflow
    attempt (withAuthority (\a → a {authContent = Revision maxBound})) `shouldBe` Left AuthorityOverflow
    attempt (withAuthority (\a → a {authStore = Revision maxBound})) `shouldBe` Left AuthorityOverflow
  it "records the extreme legal coordinates without wrapping" $ do
    let scene =
          Scene
            { sceneName = "extremes"
            , sceneSpec = SourceSpec ["stone", "slab"] [LayerSpec Nothing Nothing "stone" 0] [PatchSpec (highest - 1) 0 (topEnd - 3) (topEnd - 2) SpecAir]
            , sceneWindow = Window (highest - 4, highest + 1) (-3, 3) (topEnd - 6, topEnd)
            , sceneSky = Nothing
            }
        rig = newRig (limitsWith 64) scene
    cleanly rig ([Edit (highest - 1, 0, z) | z ← [topEnd - 2, topEnd - 1]] <> [Drain fullAllowance])
    cleanly rig ([Edit (highest, 0, topEnd - 1), Edit (highest, 0, topEnd - 2), Edit (highest - 1, 0, topEnd - 1), Edit (highest - 1, 0, topEnd - 2), Drain fullAllowance])
    let floorScene = scene {sceneSpec = (sceneSpec scene) {specPatches = [PatchSpec 0 0 lowest (lowest + 2) SpecAir]}, sceneWindow = Window (-3, 3) (-3, 3) (lowest, lowest + 6)}
    cleanly (newRig (limitsWith 64) floorScene) [Edit (0, 0, lowest + 2), Edit (0, 0, lowest + 3), Drain fullAllowance]
  where
    isStale (Left (StaleBase _ _)) = True
    isStale _ = False
    isWrongArena (Left (WrongArena _ _)) = True
    isWrongArena _ = False
