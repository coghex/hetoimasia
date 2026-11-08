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

import Control.Exception (evaluate)
import Data.IORef (newIORef, readIORef)
import Data.List (sort)
import Control.Monad (foldM, forM_, unless)
import Data.Word (Word64)
import GHC.Stats (RTSStats (allocated_bytes), getRTSStats, getRTSStatsEnabled)
import System.Mem (performMajorGC)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Hetoimasia.Terrain.Cell (Column (..), mkColumn)
import Hetoimasia.Terrain.Connectivity (BoundaryFace, ComponentKey, componentBoundary, componentOf, defaultConnectivityLimits)
import Hetoimasia.Terrain.Changes (ChangeLimits (..), changesFromIntervals, removedIntervals)
import Hetoimasia.Terrain.Coordinate (TileCoord, axisFromInteger)
import Hetoimasia.Terrain.Discovery
import Hetoimasia.Terrain.Query (cellAt)
import Hetoimasia.Terrain.Residency (ArenaId (..), Revision (..))
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..))
import Test.Hspec
import Test.Terrain.ConnectivityFixtures (R, below, mustCompile, runR)
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
    , specBoundaryFaces = 1024
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

-- | A cave opened to the sky beside two sealed pockets that touch it along an
-- edge and at a corner only.
diagonal ∷ Scene
diagonal =
  groundScene "edge and point contact" 8 (-3, 10) (-4, 5) 6 $
    caveRow 0 5 2 4 <> [PatchSpec 5 0 5 6 (SpecSolid "stone" 0), PatchSpec 5 1 5 6 SpecAir, PatchSpec 5 (-1) 6 7 SpecAir]

-- | An N ramp beside an S ramp (a quarter-face overlap), reached by a shaft.
rampPair ∷ Scene
rampPair =
  groundScene "ramp pair" 8 (-3, 6) (-3, 4) 6 $
    [PatchSpec 1 0 5 6 (SpecSolid "slab" 1), PatchSpec 2 0 5 6 (SpecSolid "slab" 4)]

-- ---------------------------------------------------------------------------
-- Generated scenes

-- | A random 4 × 4 core of patches and a random removal sequence inside and
-- around it, placed at an origin and a sky level so that the traces cross the
-- negative region seams (X and Y at zero, Z at multiples of 32). All sixteen
-- shape identities, and so all four rotations of every orientable one, occur
-- as patch content.
generatedScene ∷ (Integer, Integer, Integer) → Int → (Scene, [Cell3])
generatedScene (ox, oy, sky) seed = runR build seed
  where
    build = do
      patches ← concat <$> mapM column [(x, y) | x ← [0 .. 3], y ← [0 .. 3]]
      removals ← mapM (const removal) [1 .. 9 ∷ Int]
      pure (groundScene ("generated " <> show (ox, oy, sky, seed)) sky (ox - 2, ox + 6) (oy - 2, oy + 6) 6 patches, removals)
    column (x, y) = do
      present ← pick 4
      if present == 0
        then pure []
        else do
          lo ← (+ (sky - 5)) . toInteger <$> pick 3
          len ← (+ 1) . toInteger <$> pick 2
          content ← randomContent
          pure [PatchSpec (ox + x) (oy + y) lo (lo + len) content]
    removal = do
      x ← pick 4
      y ← pick 4
      z ← pick 6
      pure (ox + toInteger x, oy + toInteger y, sky - 5 + toInteger z)

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
  familySpecs
  accountingSpecs
  revisionSpecs
  windowSpecs
  boundarySpecs
  controlSpecs
  evidenceSpecs

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
  it "agrees with the oracle over generated traces (all sixteen identities, across the negative seams)" $ do
    forM_ [(0, 0, 8), (-2, -2, 8), (-3, -3, 32), (-2, -2, -32)] $ \origin →
      forM_ [1 .. 12 ∷ Int] $ \seed → do
        let (scene, removals) = generatedScene origin seed
            rig = newRig (limitsWith 3) scene
            events = concat [[Edit c, Batch (allowanceOf (limitsWith 3))] | c ← removals] <> [Drain fullAllowance]
        cleanly rig events
  it "does not connect edge-only or point-only contacts" $ do
    let rig = newRig (limitsWith 64) diagonal
        (end, bad) = runTrace rig ([Edit c | c ← [(1, 0, z) | z ← [5 .. 7]]] <> [Drain fullAllowance])
        known c = fmap cellVoid (observedValue (queryCell (rigEnv end) (retainedProvider (rigRetained end)) (mustTile3 c)))
    bad `shouldBe` []
    known (3, 0, 5) `shouldBe` Right VoidKnown
    -- an edge contact and a point contact with the known cave stay sealed.
    known (5, 1, 5) `shouldBe` Right VoidUnknown
    known (5, -1, 6) `shouldBe` Right VoidUnknown
  it "discovers through a real diagonal opening of shaped cells and not through a sealed one" $ do
    -- an N ramp and an S ramp across X each open half of the shared face but
    -- overlap over a quarter of it, so the two voids connect.
    cleanly (newRig (limitsWith 64) rampPair) ([Edit c | c ← [(0, 0, z) | z ← [5 .. 7]]] <> [Drain fullAllowance])

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
  it "reports each obligation as unseen, pending or expanded" $ do
    let rig0 = newRig (limitsWith 1) twoOpenings
        (queued, _) = runTrace rig0 [Edit (1, 0, 5), Edit (9, 0, 5)]
        stateOf rig n = observedValue (queryObligation (rigEnv rig) (retainedHeader (rigRetained rig)) (rigProvider rig) n)
    stateOf queued 0 `shouldBe` Right (Just Unseen)
    stateOf queued 2 `shouldBe` Right Nothing
    let (started, _) = batchRig (allowanceOf (limitsWith 1)) queued
    stateOf started 0 `shouldBe` Right (Just Pending)
    stateOf started 1 `shouldBe` Right (Just Unseen)
    stateOf (drainRig fullAllowance queued) 0 `shouldBe` Right (Just Expanded)
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
    -- twelve removals queue 72 face connections, more than one batch of 64.
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
      BatchProgress report HaltDrained → reportUpdates report `shouldBe` 8
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
  it "stops exactly at an exact allowance of each resource and below it" $ do
    let rig0 = newRig (limitsWith 64) twoOpenings
        (queued, _) = runTrace rig0 [Edit c | c ← openingA <> openingB]
        (_, full) = batchRig fullAllowance queued
        report = case full of BatchProgress r _ → r; _ → error "expected progress"
        updatesWith allow = case snd (batchRig allow queued) of
          BatchProgress r _ → reportUpdates r
          BatchRefused _ → 0
          _ → -1
        exact = reportUpdates report
    forM_
      [ ("reads", \n → fullAllowance {allowReads = n}, reportReads report)
      , ("writes", \n → fullAllowance {allowWrites = n}, reportWrites report)
      , ("delta bytes", \n → fullAllowance {allowDeltaBytes = n}, reportDeltaBytes report)
      , ("scratch bytes", \n → fullAllowance {allowScratchBytes = n}, reportScratchBytes report)
      ]
      $ \(label, with, amount) → do
        (label, updatesWith (with amount)) `shouldBe` (label, exact)
        (label, updatesWith (with (amount - 1)) < exact) `shouldBe` (label, True)
  it "refuses at the retained-byte and obligation limits and resumes once there is room" $ do
    let tinyPending = either (error . show) id (mkDiscoveryLimits baseSpec {specPendingObligations = 2})
        rig0 = newRig tinyPending twoOpenings
        (two, _) = runTrace rig0 [Edit (1, 0, 5), Edit (9, 0, 5)]
        (refusedRig, kind) = editRig fullAllowance (1, 0, 6) two
    kind `shouldBe` EditRefused (CapacityBlocked CapacityObligations 3 2)
    retainedRecords (rigRetained refusedRig) `shouldBe` retainedRecords (rigRetained two)
    -- the committed edits are not reissued: after a drain the same edit fits.
    let drained = drainRig fullAllowance two
        (resumed, kind') = editRig fullAllowance (1, 0, 6) drained
    kind' `shouldSatisfy` (\k → case k of EditApplied _ → True; _ → False)
    compareDrained (drainRig fullAllowance resumed) `shouldBe` []
    let tinyBytes = either (error . show) id (mkDiscoveryLimits baseSpec {specRetainedBytes = toInteger minimumRetainedBytes})
        grow rig n
          | n > (40 ∷ Int) = (rig, Nothing)
          | otherwise = case editRig fullAllowance (-2 - toInteger n, 0, 4) rig of
              (rig', EditRefused r) → (rig', Just r)
              (rig', _) → grow rig' (n + 1)
        (fullRig, refusal) = grow (newRig tinyBytes twoOpenings) 0
    refusal `shouldSatisfy` (\r → case r of Just (CapacityBlocked CapacityRetainedBytes _ _) → True; _ → False)
    invariants fullRig `shouldBe` []
  it "stages a later removal while older discovery is suspended, then resumes" $ do
    let rig0 = newRig (limitsWith 1) twoOpenings
        (queued, _) = runTrace rig0 [Edit c | c ← openingA]
        withheld = queued {rigDelay = Delay mempty (Set.singleton (KeyTodo 0))}
        (staged, kind) = editRig fullAllowance (9, 0, 5) withheld
        (_, stalled) = batchRig fullAllowance staged
    kind `shouldSatisfy` (\k → case k of EditApplied _ → True; _ → False)
    stalled `shouldBe` BatchStalled (KeyTodo 0)
    pendingOf staged `shouldBe` 4
    let resumed = staged {rigDelay = noDelay}
    compareDrained (drainRig (allowanceOf (limitsWith 1)) resumed) `shouldBe` []
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

-- ---------------------------------------------------------------------------
-- Huge families, bounded windows and allocation

-- | A uniform N-ramp layer on @[0, w)@ under open sky, with a patch exception:
-- every row and every level is its own component.
rampFamily ∷ Integer → Scene
rampFamily w =
  Scene
    { sceneName = "ramp family " <> show w
    , sceneSpec =
        SourceSpec
          ["stone", "slab"]
          [LayerSpec Nothing (Just 0) "stone" 0, LayerSpec (Just 0) (Just w) "slab" 1]
          [PatchSpec 3 1 (w - 3) (w - 2) (SpecSolid "stone" 0)]
    , sceneWindow = Window (-1, 5) (-1, 5) (w - 6, w + 3)
    , sceneSky = Just w
    }

familyEdits ∷ Integer → [Cell3]
familyEdits w = [(1, 1, w - 2), (2, 1, w - 3), (1, 1, w - 1)]

spans ∷ [Integer]
spans = [2 ^ (20 ∷ Int), 2 ^ (60 ∷ Int)]

familySpecs ∷ Spec
familySpecs = describe "huge families" $ do
  it "joins only the components a removal reaches, at 2^20 and 2^60 alike" $ do
    reports ← mapM runFamily spans
    case reports of
      [small, large] → small `shouldBe` large
      _ → expectationFailure "two spans expected"
  it "looks up a known component's compressed boundary without enumerating tiles" $ do
    sizes ← mapM boundaryOf spans
    case sizes of
      [small, large] → small `shouldBe` large
      _ → expectationFailure "two spans expected"
  it "keeps a bounded working window while the retained history grows" $ do
    let base = newRig (limitsWith 64) (rampFamily (2 ^ (60 ∷ Int)))
        with n = base {rigRetained = historyOf n}
        trace rig = map reportCost (rigReports (drainRig fullAllowance (foldl (\r c → fst (editRig fullAllowance c r)) rig (familyEdits (2 ^ (60 ∷ Int))))))
    trace (with 0) `shouldBe` trace (with 100000)
    trace (with 0) `shouldSatisfy` all (\(reads', writes, bytes) → reads' <= limitInspectedRecords defaultDiscoveryLimits && writes <= limitDeltaRecords defaultDiscoveryLimits && bytes <= limitDeltaBytes defaultDiscoveryLimits)
  it "allocates alike for spans of 2^20 and 2^60 and for short and long histories" $ do
    rigs ← mapM (\w → let r = newRig (limitsWith 64) (rampFamily w) in evaluate (envSharedBytes (rigEnv r)) >> pure r) spans
    let work rig = evaluate (retainedBytes (rigRetained (drainRig fullAllowance (foldl (\r c → fst (editRig fullAllowance c r)) rig (familyEdits (sceneTop rig))))))
    costs ← mapM (\r → allocatedBy (repeatN 20 (work r))) rigs
    case costs of
      [small, large] → do
        putStrLn ("allocation, 20 repetitions, span 2^20: " <> show small <> " B; span 2^60: " <> show large <> " B")
        sameCost "span" small large
      _ → expectationFailure "two spans expected"
    let base = newRig (limitsWith 64) (rampFamily (2 ^ (60 ∷ Int)))
        shortRig = base {rigRetained = historyOf 100}
        longRig = base {rigRetained = historyOf 100000}
    _ ← evaluate (retainedBytes (rigRetained shortRig) + retainedBytes (rigRetained longRig))
    short ← allocatedBy (repeatN 20 (work shortRig))
    long ← allocatedBy (repeatN 20 (work longRig))
    putStrLn ("allocation, 20 repetitions, history 100 runs: " <> show short <> " B; history 100000 runs: " <> show long <> " B")
    sameCost "history" short long
  where
    sceneTop rig = case sceneSky (rigScene rig) of Just w → w; Nothing → 0
    reportCost r = (reportReads r, reportWrites r, reportDeltaBytes r)
    -- the sizes of the boundary descriptions of a known and of an unknown
    -- component, and whether each is reported known.
    boundaryOf w = do
      let rig = newRig (limitsWith 64) (rampFamily w)
          compiledFor = fst (mustCompile defaultConnectivityLimits (sceneSpec (rampFamily w)))
          keyAt' c = componentOf compiledFor (mustTile3 c)
          provider = rigProvider rig
          boundary key = observedValue (queryKnownBoundary (rigEnv rig) provider key 0)
          known key = observedValue (queryComponentKnown (rigEnv rig) provider key)
      case (keyAt' (1, 1, w - 1), keyAt' (1, 3, w - 2)) of
        (Just topRow, Just lowerRow) → do
          known topRow `shouldBe` Right True
          known lowerRow `shouldBe` Right False
          boundary lowerRow `shouldBe` Right Nothing
          pages <- allBoundaryPages (rigEnv rig) provider topRow
          pages `shouldSatisfy` (not . null)
          pure (length pages)
        other → expectationFailure ("components expected, got " <> show other) >> pure 0
    runFamily w = do
      let rig = newRig (limitsWith 64) (rampFamily w)
          events = [Edit c | c ← familyEdits w] <> [Drain fullAllowance]
          (end, bad) = runTrace rig events
      bad `shouldBe` []
      compareDrained end `shouldBe` []
      -- the top row's neighbours stay unknown: only the reached components joined.
      let known c = fmap cellVoid (observedValue (queryCell (rigEnv end) (retainedProvider (rigRetained end)) (mustTile3 c)))
      known (1, 3, w - 2) `shouldBe` Right VoidUnknown
      known (1, 1, w - 3) `shouldBe` Right VoidKnown
      known (1, 2, w - 2) `shouldBe` Right VoidKnown
      pure (map reportShape (reverse (rigReports end)))
    reportShape r = (reportUpdates r, reportJoins r, reportRetired r, reportReads r, reportWrites r, reportDeltaBytes r, reportScratchBytes r, length (reportNewlyKnown r))

-- | A retained value holding @n@ unrelated removed runs far from the scene.
historyOf ∷ Int → Retained
historyOf n =
  either (error . show) id (retainedFromRecords header records)
  where
    records = [(KeyRun col 1000, RecRun 1001) | i ← [0 .. n - 1], Right col ← [mkColumn (1000 + toInteger i) 1000]]
    header = (retainedHeader (newRetained (ArenaId 1))) {hBytes = sum [entryBytes k r | (k, r) ← records]}

-- | Bytes the runtime allocated while an action ran, measured across major
-- collections, exactly as the growth specs measure it.
allocatedBy ∷ IO a → IO Word64
allocatedBy action = do
  enabled ← getRTSStatsEnabled
  unless enabled $ expectationFailure "GHC runtime statistics are disabled; build the suite with -with-rtsopts=-T"
  performMajorGC
  began ← allocated_bytes <$> getRTSStats
  _ ← action
  performMajorGC
  ended ← allocated_bytes <$> getRTSStats
  pure (ended - began)

repeatN ∷ Int → IO a → IO ()
repeatN n action = forM_ [1 .. n] (const action)

sameCost ∷ String → Word64 → Word64 → Expectation
sameCost label a b = do
  (label, a <= 64 * 1024 * 1024) `shouldBe` (label, True)
  (label, b <= 64 * 1024 * 1024) `shouldBe` (label, True)
  (label, a <= 2 * b + 65536) `shouldBe` (label, True)
  (label, b <= 2 * a + 65536) `shouldBe` (label, True)

-- ---------------------------------------------------------------------------
-- Negative controls

-- | The independent expectations must reject three wrong behaviours that keep
-- each scenario's premise. A mutant here is a transformation applied to the
-- real result; the production code is mutated separately, locally, and the
-- results recorded with the evidence.
controlSpecs ∷ Spec
controlSpecs = describe "negative controls" $ do
  it "reject ending the whole reveal on reaching the sky" $ do
    let rig = newRig (limitsWith 1) pockets
        queued = fst (runTrace rig ([Edit c | c ← [(1, 0, z) | z ← [5 .. 7]]] <> [Edit (4, 0, 5), Edit (7, 0, 5)]))
        stopAtSky batch r = case batch of
          BatchProgress report _ | not (null (reportNewlyKnown report)) → forgetObligations r
          _ → r
        mutant = drainWith stopAtSky (allowanceOf (limitsWith 1)) queued
        honest = drainRig (allowanceOf (limitsWith 1)) queued
    compareDrained honest `shouldBe` []
    compareDrained mutant `shouldNotBe` []
  it "reject treating pending work as complete" $ do
    let rig = newRig (limitsWith 1) twoOpenings
        (queued, _) = runTrace rig [Edit c | c ← openingA]
        (partial, _) = batchRig (allowanceOf (limitsWith 1)) queued
    pendingOf partial `shouldSatisfy` (> 0)
    -- a model that called this complete would claim knowledge the oracle
    -- already has and the state lacks.
    filter (\m → "void known" `isInfixOfS` m || "solid known" `isInfixOfS` m) (compareDrained partial) `shouldNotBe` []
  it "reject deriving a known void from a known solid" $ do
    let rig = newRig (limitsWith 64) ramps
        (end, _) = runTrace rig ([Edit c | c ← [(0, 1, z) | z ← [5 .. 7]]] <> [Drain fullAllowance])
        mutant ck = if cellSolid ck == SolidKnown then ck {cellVoid = if cellVoid ck == NoVoidHere then NoVoidHere else VoidKnown} else ck
    compareDrained end `shouldBe` []
    compareDrainedWith mutant end `shouldNotBe` []
  where
    isInfixOfS needle hay = any (\i → take (length needle) (drop i hay) == needle) [0 .. length hay - length needle]

-- | The mutant: forget every unfinished obligation.
forgetObligations ∷ Rig → Rig
forgetObligations rig =
  rig
    { rigRetained =
        either (error . show) id $
          retainedFromRecords
            header {hHead = hTail header, hBytes = sum [entryBytes k r | (k, r) ← records]}
            records
    }
  where
    header = retainedHeader (rigRetained rig)
    records = [(k, r) | (k, r) ← retainedRecords (rigRetained rig), notTodo k]
    notTodo (KeyTodo _) = False
    notTodo _ = True

-- ---------------------------------------------------------------------------
-- Evidence

-- | Print the measured figures of the required traces, for the retained
-- evidence. These are accounting counts, not heap or process memory.
evidenceSpecs ∷ Spec
evidenceSpecs = describe "evidence" $ do
  it "reports bounds for the required traces" $ do
    forM_ traces $ \(label, rig, events) → do
      let (end, bad) = runTrace rig events
          reports = reverse (rigReports end)
          batches = [r | r ← reports, reportUpdates r > 0]
      bad `shouldBe` []
      putStrLn $
        label
          <> ": edits "
          <> show (length (rigRemovals end))
          <> ", reports "
          <> show (length batches)
          <> ", max updates "
          <> show (maximum (0 : map reportUpdates batches))
          <> ", max reads "
          <> show (maximum (0 : map reportReads batches))
          <> ", max writes "
          <> show (maximum (0 : map reportWrites batches))
          <> ", max delta bytes "
          <> show (maximum (0 : map reportDeltaBytes batches))
          <> ", max scratch bytes "
          <> show (maximum (0 : map reportScratchBytes batches))
          <> ", retained records "
          <> show (length (retainedRecords (rigRetained end)))
          <> ", retained bytes "
          <> show (retainedBytes (rigRetained end))
          <> ", pending "
          <> show (pendingOf end)
          <> ", resident detail 0"
  it "prints the per-step expected and observed knowledge of one interleaved trace" $ do
    let rig0 = newRig (limitsWith 1) twoOpenings
        events =
          concat
            [ [Edit a, Batch (allowanceOf (limitsWith 1)), Edit b, Batch (allowanceOf (limitsWith 1)), Batch (allowanceOf (limitsWith 1))]
            | (a, b) ← zip openingA openingB
            ]
            <> [Drain fullAllowance]
        counts rig =
          let provider = retainedProvider (rigRetained rig)
              inner = [c | c@(x, y, z) ← cellsOfWindow (rigScene rig), x > -3, x < 12, y > -3, y < 5, z > 2, z < 10]
              answers = [r | c ← inner, Right r ← [modelKnowledge (rigEnv rig) provider c]]
              scene = rigScene rig
              lowerV = (rigOracle rig) !! min (fromIntegral (hHead (retainedHeader (rigRetained rig)))) (length (rigOracle rig) - 1)
              upperV = last (rigOracle rig)
              within f set = length [() | c ← inner, f c, Set.member c set]
           in ( length (filter fst answers)
              , within (const True) lowerV
              , within (const True) upperV
              , length (filter snd answers)
              , within (const True) (oracleKnownSolid scene (rigRemovals rig) upperV)
              )
        step (rig, n) action = do
          let rig' = apply action rig
              (mv, lv, uv, ms, us) = counts rig'
          putStrLn ("step " <> show n <> " " <> showAction action <> ": pending " <> show (pendingOf rig') <> ", known voids " <> show mv <> " (oracle between " <> show lv <> " and " <> show uv <> "), known solids " <> show ms <> " (oracle after every removal " <> show us <> ")")
          pure (rig', n + 1 ∷ Int)
    _ ← foldM step (rig0, 1) events
    pure ()
  where
    small = limitsWith 64
    traces =
      [ ("two openings", newRig small twoOpenings, [Edit c | c ← openingA <> openingB] <> [Drain fullAllowance])
      , ("sealed pockets", newRig small pockets, [Edit c | c ← [(4, 0, 5), (7, 0, 5)] <> [(0, 3, z) | z ← [1 .. 6]] <> [(1, 0, z) | z ← [5 .. 7]]] <> [Drain fullAllowance])
      , ("ramp family 2^20", newRig small (rampFamily (2 ^ (20 ∷ Int))), [Edit c | c ← familyEdits (2 ^ (20 ∷ Int))] <> [Drain fullAllowance])
      , ("ramp family 2^60", newRig small (rampFamily (2 ^ (60 ∷ Int))), [Edit c | c ← familyEdits (2 ^ (60 ∷ Int))] <> [Drain fullAllowance])
      ]

-- ---------------------------------------------------------------------------
-- Accounting before the work, authority of derived knowledge, restored runs,
-- source structure and replay after every batch

-- | A world with a flat ground at level 0 and the given extra patches.
flatGround ∷ String → [PatchSpec] → Scene
flatGround name patches = groundScene name 0 (-4, 8) (-4, 6) 6 patches

accountingSpecs ∷ Spec
accountingSpecs = describe "accounting before the work" $ do
  it "never asks the provider for more than the allowance, on every exit" $ do
    let limits = limitsWith 64
        rig0 = newRig limits twoOpenings
        (queued, _) = runTrace rig0 [Edit c | c ← openingA <> [(0, 3, 2)]]
        header = retainedHeader (rigRetained queued)
        grid =
          [ fullAllowance {allowReads = r, allowScratchBytes = sc, allowWrites = w, allowDeltaBytes = d}
          | r ← [1, 3, 4, 6, 9, 14, 40]
          , sc ← [255, 392, 504, 900, 2500, 12000]
          , w ← [1, 2, 5, 100]
          , d ← [300, 700, 4000, 100000]
          ]
    forM_ grid $ \allow → do
      ref ← newIORef 0
      let result = stepDiscovery (rigEnv queued) header (countingProvider ref (rigProvider queued)) allow
      _ ← evaluate (length (show result))
      count ← readIORef ref
      (show allow, count <= allowReads allow, count * maxRecordBytes <= allowScratchBytes allow) `shouldBe` (show allow, True, True)
      case result of
        Right (Progress c _) → do
          let report = candidateReport c
          (show allow, reportAttemptedReads report) `shouldBe` (show allow, count)
          (show allow, reportScratchBytes report >= count * maxRecordBytes) `shouldBe` (show allow, True)
          (show allow, reportScratchBytes report <= allowScratchBytes allow, reportWrites report <= allowWrites allow, reportDeltaBytes report <= allowDeltaBytes allow) `shouldBe` (show allow, True, True, True)
        _ → pure ()
    -- the same bound holds for an edit and for a suspended exit.
    forM_ grid $ \allow → do
      ref ← newIORef 0
      let result = stageRemoval (rigEnv queued) header (countingProvider ref (rigProvider queued)) allow (mustTile 9 0 5)
      _ ← evaluate (length (show result))
      count ← readIORef ref
      (show allow, count <= allowReads allow, count * maxRecordBytes <= allowScratchBytes allow) `shouldBe` (show allow, True, True)
    let withheld = queued {rigDelay = Delay mempty (Set.singleton (KeyTodo 1))}
    ref ← newIORef 0
    let suspended = stepDiscovery (rigEnv withheld) (retainedHeader (rigRetained withheld)) (countingProvider ref (rigProvider withheld)) fullAllowance
    _ ← evaluate (length (show suspended))
    seen ← readIORef ref
    seen `shouldSatisfy` (<= limitInspectedRecords limits)
    case suspended of
      Right (Progress c (HaltSuspended _)) → reportAttemptedReads (candidateReport c) `shouldBe` seen
      other → expectationFailure ("expected a suspension after progress, got " <> show other)
  it "reports the reads of a rejected inspection" $ do
    let rig0 = newRig (limitsWith 64) twoOpenings
        (queued, _) = runTrace rig0 [Edit (1, 0, 5)]
        outcomes = [(sc, snd (batchRig fullAllowance {allowScratchBytes = sc} queued)) | sc ← [600, 650 .. 4000]]
        rejected = [(sc, r) | (sc, BatchProgress r (HaltCapacity CapacityScratchBytes)) ← outcomes]
    -- some allowance fits the first inspections and rejects a later one, and the
    -- rejected inspection's reads are reported, never above what the scratch pays for.
    rejected `shouldSatisfy` (not . null)
    forM_ rejected $ \(sc, r) → do
      (sc, reportScratchBytes r <= sc) `shouldBe` (sc, True)
      (sc, reportAttemptedReads r * maxRecordBytes <= sc) `shouldBe` (sc, True)
      (sc, reportAttemptedReads r >= reportReads r) `shouldBe` (sc, True)
    any (\(_, r) → reportAttemptedReads r > reportReads r) rejected `shouldBe` True
  it "reports the peak scratch of a rejected inspection, independently counted" $ do
    let rig0 = newRig (limitsWith 64) twoOpenings
        (queued, _) = runTrace rig0 [Edit (1, 0, 5)]
        header = retainedHeader (rigRetained queued)
        allow = fullAllowance {allowScratchBytes = 1400}
    ref ← newIORef 0
    let result = stepDiscovery (rigEnv queued) header (countingProvider ref (rigProvider queued)) allow
    _ ← evaluate (length (show result))
    count ← readIORef ref
    -- five requests reach the provider, each charged the largest record, plus the
    -- staged obligation entry: 5 x 256 + 104 = 1384, and the sixth is refused.
    count `shouldBe` 5
    case result of
      Right (Progress c (HaltCapacity CapacityScratchBytes)) → do
        reportAttemptedReads (candidateReport c) `shouldBe` 5
        reportScratchBytes (candidateReport c) `shouldBe` 1384
        reportReads (candidateReport c) `shouldSatisfy` (< 5)
      other → expectationFailure ("expected a scratch halt, got " <> show other)
  it "advances the knowledge revision when a removal extends a known run" $ do
    let scene = flatGround "extend a known run" []
        rig0 = newRig (limitsWith 64) scene
        (known, bad) = runTrace rig0 ([Edit c | c ← [(0, 0, -3), (1, 0, -3), (1, 0, -2), (1, 0, -1)]] <> [Drain fullAllowance])
        header = retainedHeader (rigRetained known)
    bad `shouldBe` []
    case stageRemoval (rigEnv known) header (rigProvider known) fullAllowance (mustTile 0 0 (-2)) of
      Right (Staged c) → do
        candidateKnowledge c `shouldBe` True
        authKnowledge (hAuthority (candidateNext c)) `shouldNotBe` authKnowledge (candidateBase c)
        reportNewlyKnown (candidateReport c) `shouldSatisfy` (not . null)
      other → expectationFailure ("expected a candidate, got " <> show other)
    -- the edit exposes a wall that was not known before, so the revision was owed.
    let (extended, _) = runTrace known [Edit (0, 0, -2), Drain fullAllowance]
    compareDrained extended `shouldBe` []
    -- the knowledge revision is checked like the others.
    let atMax = header {hAuthority = (hAuthority header) {authKnowledge = Revision maxBound}}
    stageRemoval (rigEnv known) atMax (rigProvider known) fullAllowance (mustTile 0 0 (-2)) `shouldBe` Left AuthorityOverflow
  it "refuses restored runs outside the supported range and accepts the legal limits" $ do
    let header0 = retainedHeader (newRetained (ArenaId 1))
        column = either (error . show) id (mkColumn 0 0)
        restored runs =
          let records = [(KeyRun column lo, RecRun hi) | (lo, hi) ← runs]
           in retainedFromRecords header0 {hBytes = sum [entryBytes k r | (k, r) ← records]} records
        lowest' = negate (2 ^ (62 ∷ Int))
        top = 2 ^ (62 ∷ Int)
    restored [(lowest', 0)] `shouldSatisfy` isRight'
    restored [(top - 1, top)] `shouldSatisfy` isRight'
    restored [(lowest', top)] `shouldSatisfy` isRight'
    restored [(lowest' - 1, 0)] `shouldSatisfy` isLeft'
    restored [(0, top + 1)] `shouldSatisfy` isLeft'
    restored [(top, top + 1)] `shouldSatisfy` isLeft'
    -- discovery and the existing Changes consumers agree on every legal run.
    case restored [(lowest', 0), (5, top)] of
      Right r → length (retainedRemovals r) `shouldBe` 2
      Left e → expectationFailure (show e)
  it "does not charge the work of a class to a lookup: allocation is independent of the source's structure" $ do
    let withPatches n =
          Scene
            { sceneName = "structure " <> show n
            , sceneSpec = SourceSpec ["stone"] [LayerSpec Nothing (Just 0) "stone" 0] [PatchSpec (3 * i) 0 3 4 (SpecSolid "stone" 0) | i ← [1 .. n]]
            , sceneWindow = Window (-1, 2) (-1, 2) (-3, 3)
            , sceneSky = Just 0
            }
        work rig = evaluate (retainedBytes (rigRetained (drainRig fullAllowance (fst (editRig fullAllowance (400, 400, -1) rig)))))
    rigs ← mapM (\n → let r = newRig (limitsWith 64) (withPatches n) in evaluate (envSharedBytes (rigEnv r)) >> pure r) [0, 200]
    costs ← mapM (\r → allocatedBy (repeatN 20 (work r))) rigs
    case costs of
      [few, many] → do
        putStrLn ("allocation, 20 repetitions, 0 patches: " <> show few <> " B; 200 patches: " <> show many <> " B")
        sameCost "source structure" few many
      _ → expectationFailure "two sources expected"
  it "stays identical to an uninterrupted run when the records are rebuilt after every batch, a drain included" $ do
    let scenes =
          [ (newRig (limitsWith 2) twoOpenings, [Edit c | c ← openingA <> openingB])
          , (newRig (limitsWith 1) pockets, [Edit c | c ← [(1, 0, 5), (1, 0, 6), (1, 0, 7), (4, 0, 5), (7, 0, 5)]])
          , (newRig (limitsWith 3) (rampFamily (2 ^ (60 ∷ Int))), [Edit c | c ← familyEdits (2 ^ (60 ∷ Int))])
          ]
            <> [ (newRig (limitsWith 3) scene, [Edit c | c ← removals])
               | origin ← [(0, 0, 8), (-3, -3, 32)]
               , seed ← [1 .. 5 ∷ Int]
               , let (scene, removals) = generatedScene origin seed
               ]
    forM_ scenes $ \(rig, edits) → lockstep rig edits `shouldBe` []
  where
    isRight' = either (const False) (const True)
    isLeft' = either (const True) (const False)

-- | Run the same edits on two rigs and drain them batch by batch. One rig is
-- rebuilt from its own records (through a fresh provider) after every edit and
-- every batch; the other is never interrupted. After each batch the two must
-- hold the same records and header, and the replayed rig must satisfy every
-- invariant and the oracle bounds.
lockstep ∷ Rig → [Action] → [String]
lockstep start edits = go (replayedStart, plainStart) (100000 ∷ Int)
  where
    editCells = [c | Edit c ← edits]
    replayedStart = foldl (\rg c → apply Replay (apply (Edit c) rg)) start editCells
    plainStart = foldl (\rg c → apply (Edit c) rg) start editCells
    go (a, b) fuel
      | fuel == 0 = ["lockstep did not finish"]
      | otherwise =
          let (a', ka) = batchRig fullAllowance' a
              (b', kb) = batchRig fullAllowance' b
              replayed = apply Replay a'
              same = retainedRecords (rigRetained replayed) == retainedRecords (rigRetained b') && retainedHeader (rigRetained replayed) == retainedHeader (rigRetained b')
              problems = [sceneName (rigScene a) <> ": replayed run differs from the uninterrupted one" | not same] <> map ((sceneName (rigScene a) <> " during lockstep: ") <>) (stateViolations replayed)
           in case (ka, kb) of
                (BatchProgress _ _, BatchProgress _ _) → problems <> go (replayed, b') (fuel - 1)
                (BatchIdle, BatchIdle) → problems <> map ((sceneName (rigScene a) <> " at the end: ") <>) (compareDrained replayed)
                other → [sceneName (rigScene a) <> ": the two runs diverged: " <> show other]
    fullAllowance' = allowanceOf (envLimits (rigEnv start))

-- ---------------------------------------------------------------------------
-- The revision rule

-- | A random action sequence over a scene's removals, always ending in a drain.
data WAction = WEdit Cell3 | WBatch | WDrain | WForget | WReplay
  deriving stock (Eq, Show)

genActions ∷ [Cell3] → R [WAction]
genActions cells = go cells (24 ∷ Int)
  where
    go cs 0 = pure (map WEdit cs <> [WDrain])
    go cs n = do
      r ← below 10
      case (r, cs) of
        (_, c : rest) | r < 4 → (WEdit c :) <$> go rest (n - 1)
        _ | r < 7 → (WBatch :) <$> go cs (n - 1)
        _ | r == 7 → (WForget :) <$> go cs (n - 1)
        _ | r == 8 → (WReplay :) <$> go cs (n - 1)
        _ → (WDrain :) <$> go cs (n - 1)

-- | The void and solid cells reported known over the compared cells.
knownFacts ∷ Rig → (Set.Set Cell3, Set.Set Cell3)
knownFacts rig = (Set.fromList [c | (c, (True, _)) ← answers], Set.fromList [c | (c, (_, True)) ← answers])
  where
    provider = retainedProvider (rigRetained rig)
    answers = [(c, r) | c ← innerCells (rigScene rig), Right r ← [modelKnowledge (rigEnv rig) provider c]]

revisionSpecs ∷ Spec
revisionSpecs = describe "the revision rule" $ do
  it "advances the knowledge revision when a removal bridges runs of one known class, or extends a known run" $ do
    let scene = flatGround "bridge known runs" []
        rig0 = newRig (limitsWith 64) scene
        (known, bad) = runTrace rig0 ([Edit c | c ← [(0, 0, -3), (1, 0, -3), (1, 0, -2), (1, 0, -1), (0, 0, -1)]] <> [Drain fullAllowance])
        header = retainedHeader (rigRetained known)
        staged tile = stageRemoval (rigEnv known) header (rigProvider known) fullAllowance tile
    bad `shouldBe` []
    -- the removal at (0,0,-2) bridges two runs already in the same known class.
    case staged (mustTile 0 0 (-2)) of
      Right (Staged c) → do
        candidateKnowledge c `shouldBe` True
        authKnowledge (hAuthority (candidateNext c)) `shouldNotBe` authKnowledge (candidateBase c)
        reportNewlyKnown (candidateReport c) `shouldSatisfy` (not . null)
      other → expectationFailure ("expected a candidate, got " <> show other)
    let atMax = header {hAuthority = (hAuthority header) {authKnowledge = Revision maxBound}}
    stageRemoval (rigEnv known) atMax (rigProvider known) fullAllowance (mustTile 0 0 (-2)) `shouldBe` Left AuthorityOverflow
    -- a removal in an unrelated sealed place changes no knowledge and no revision of it.
    case staged (mustTile 5 5 (-6)) of
      Right (Staged c) → candidateKnowledge c `shouldBe` False
      other → expectationFailure ("expected a candidate, got " <> show other)
  it "holds over random edit, batch, forget, replay and drain sequences (generated property)" $ do
    forM_ [(0, 0, 8), (-3, -3, 32), (-2, -2, -32)] $ \origin →
      forM_ [1 .. 14 ∷ Int] $ \seed → do
        let (scene, removals) = generatedScene origin seed
            limits = limitsWith (case seed `mod` 4 of 0 → 1; 1 → 2; 2 → 3; _ → 64)
            actions = runR (genActions removals) seed
        revisionProperty (newRig limits scene) actions `shouldBe` []

-- | Check the one revision rule over a sequence. After every action: content
-- advances exactly with an applied removal; store with every applied candidate;
-- knowledge never decreases, by at most one per candidate, and advances whenever
-- known void or known solid space appeared in the compared cells; known voids
-- never shrink and a known solid is lost only by removing it; and a candidate
-- staged against the state before the action is refused afterwards if anything
-- was applied.
revisionProperty ∷ Rig → [WAction] → [String]
revisionProperty rig0 = go rig0
  where
    label rig act = sceneName (rigScene rig) <> " after " <> show act <> ": "
    go _ [] = []
    go rig (act : rest) =
      let oldHeader = retainedHeader (rigRetained rig)
          authBefore = hAuthority oldHeader
          (voidsBefore, solidsBefore) = knownFacts rig
          staleEdit = case stepDiscovery (rigEnv rig) oldHeader (rigProvider rig) (allowanceOf (envLimits (rigEnv rig))) of
            Right (Progress c _) → Just c
            _ → Nothing
          (rig', removedNow) = case act of
            WEdit c → let (r, k) = editRig fullAllowance c rig in (r, [c | EditApplied _ ← [k]])
            WBatch → (fst (batchRig (allowanceOf (envLimits (rigEnv rig))) rig), [])
            WDrain → (drainRig (allowanceOf (envLimits (rigEnv rig))) rig, [])
            WForget → (rig, [])
            WReplay → (apply Replay rig, [])
          newAuthority = hAuthority (retainedHeader (rigRetained rig'))
          (voidsAfter, solidsAfter) = knownFacts rig'
          applied = newAuthority /= authBefore
          grew = not (Set.null (Set.difference voidsAfter voidsBefore)) || not (Set.null (Set.difference solidsAfter solidsBefore))
          kRev (Revision n) = toInteger n
          problems =
            [ label rig act <> "content revision " <> show (authContent authBefore, authContent newAuthority) <> ", removal applied " <> show (not (null removedNow))
            | (authContent newAuthority /= authContent authBefore) /= not (null removedNow)
            ]
              <> [label rig act <> "knowledge revision went backwards" | kRev (authKnowledge newAuthority) < kRev (authKnowledge authBefore)]
              <> [ label rig act <> "knowledge revision advanced by more than one for a single candidate"
                 | act /= WDrain, kRev (authKnowledge newAuthority) - kRev (authKnowledge authBefore) > 1
                 ]
              <> [label rig act <> "known space appeared without a knowledge revision" | grew, authKnowledge newAuthority == authKnowledge authBefore]
              <> [label rig act <> "a known void was lost" | not (Set.null (Set.difference voidsBefore voidsAfter))]
              <> [ label rig act <> "a known solid was lost without being removed"
                 | c ← Set.toList (Set.difference solidsBefore solidsAfter)
                 , c `notElem` removedNow
                 ]
              <> [label rig act <> "the store revision did not advance with an applied candidate" | applied && authStore newAuthority == authStore authBefore]
              <> [ label rig act <> "a candidate staged oldHeader the action was not refused afterwards"
                 | applied
                 , Just c ← [staleEdit]
                 , either (const False) (const True) (applyCandidate c (rigRetained rig'))
                 ]
              <> map (label rig act <>) (stateViolations rig')
       in problems <> go rig' rest

-- ---------------------------------------------------------------------------
-- Replay through a bounded window

data WStats = WStats {suspensions ∷ !Int, evictions ∷ !Int}

-- | Run the actions with a provider that exposes only the @w@ most recently
-- loaded records. A request outside the window suspends the operation (nothing
-- is lost); the record is then loaded, evicting the oldest, and the operation
-- retried. After every applied candidate the retained value is rebuilt from its
-- own records, and after every batch the state and the oracle bounds are
-- checked. A forget action empties the window.
runWindowed ∷ Int → Rig → [WAction] → (Rig, WStats, [String])
runWindowed w rig0 = go rig0 [] (WStats 0 0) []
  where
    full rig = allowanceOf (envLimits (rigEnv rig))
    load k window stats =
      let window' = take w (k : filter (/= k) window)
          evicted = if length (k : filter (/= k) window) > w then 1 else 0
       in (window', stats {suspensions = suspensions stats + 1, evictions = evictions stats + evicted})
    windowed rig window = windowProvider window (retainedProvider (rigRetained rig))
    check rig problems label = problems <> map (label <>) (stateViolations rig)
    go rig _ stats problems [] = (rig, stats, problems)
    go rig window stats problems (act : rest) = case act of
      WForget → go rig [] stats problems rest
      WReplay → go (apply Replay rig) window stats problems rest
      WEdit c → editLoop rig window stats problems c (500 ∷ Int) rest
      WBatch → batchLoop rig window stats problems (500 ∷ Int) False rest
      WDrain → batchLoop rig window stats problems (100000 ∷ Int) True rest
    editLoop rig window stats problems c fuel rest
      | fuel == 0 = (rig, stats, problems <> ["window too small to finish an edit"])
      | otherwise = case editRigP (windowed rig window) (full rig) c rig of
          (rig', EditSuspendedOn k) → let (window', stats') = load k window stats in editLoop rig' window' stats' problems c (fuel - 1) rest
          (rig', EditApplied _) → go (apply Replay rig') window stats (check (apply Replay rig') problems ("edit " <> show c <> ": ")) rest
          (rig', EditNoOp) → go rig' window stats problems rest
          (rig', EditRefused r) → (rig', stats, problems <> ["edit refused: " <> show r])
    batchLoop rig window stats problems fuel drain rest
      | fuel == 0 = (rig, stats, problems <> ["window too small to finish a batch"])
      | otherwise = case batchRigP (windowed rig window) (full rig) rig of
          (rig', BatchStalled k) → let (window', stats') = load k window stats in batchLoop rig' window' stats' problems (fuel - 1) drain rest
          (rig', BatchProgress _ halt) →
            let replayed = apply Replay rig'
                (window', stats') = case halt of HaltSuspended k → load k window stats; _ → (window, stats)
                problems' = check replayed problems "batch: "
             in if drain then batchLoop replayed window' stats' problems' (fuel - 1) True rest else go replayed window' stats' problems' rest
          (rig', BatchIdle) → go rig' window stats problems rest
          (rig', BatchRefused r) → (rig', stats, problems <> ["batch refused: " <> show r])

windowSpecs ∷ Spec
windowSpecs = describe "replay through a bounded window" $ do
  it "matches the uninterrupted run for generated scenes, windows, batch sizes and interleavings" $ do
    results ←
      sequence
        [ do
            let (scene, removals) = generatedScene origin seed
                limits = limitsWith (case seed `mod` 4 of 0 → 1; 1 → 2; 2 → 3; _ → 64)
                window = [16, 24, 40] !! (seed `mod` 3)
                actions = runR (genActions removals) (seed + 1000)
                start = newRig limits scene
                (windowedEnd, stats, problems) = runWindowed window start actions
                plainEnd = foldl (\rg act → case act of WEdit c → fst (editRig fullAllowance c rg); WBatch → fst (batchRig (allowanceOf limits) rg); WDrain → drainRig (allowanceOf limits) rg; WReplay → apply Replay rg; WForget → rg) start actions
                runsOf rg = [(k, r) | (k@(KeyRun _ _), r) ← retainedRecords (rigRetained rg)]
                headerOf rg = let h = retainedHeader (rigRetained rg) in (authArena (hAuthority h), authContent (hAuthority h), hHead h, hTail h)
            (scene `seq` problems) `shouldBe` []
            runsOf windowedEnd `shouldBe` runsOf plainEnd
            headerOf windowedEnd `shouldBe` headerOf plainEnd
            compareDrained windowedEnd `shouldBe` []
            pure stats
        | origin ← [(0, 0, 8), (-3, -3, 32)]
        , seed ← [1 .. 12 ∷ Int]
        ]
    -- the window was small enough that operations really suspended and records
    -- were really replaced.
    sum (map suspensions results) `shouldSatisfy` (> 100)
    sum (map evictions results) `shouldSatisfy` (> 0)
    putStrLn ("windowed replay: " <> show (length results) <> " generated runs, " <> show (sum (map suspensions results)) <> " suspensions, " <> show (sum (map evictions results)) <> " evicted records")
  it "serves nothing outside its window" $ do
    let rig = newRig (limitsWith 64) twoOpenings
        (queued, _) = runTrace rig [Edit (1, 0, 5)]
        provider = windowProvider [] (retainedProvider (rigRetained queued))
    fetchRecord provider (KeyTodo 0) `shouldBe` Unavailable (KeyTodo 0)
    case fetchFloorRun provider (Column (either (error . show) id (axisFromInteger 1)) (either (error . show) id (axisFromInteger 0))) 5 of
      Unavailable _ → pure ()
      other → expectationFailure ("expected Unavailable, got " <> show (const () <$> Just other))

-- ---------------------------------------------------------------------------
-- Bounded boundary queries

-- | Every face of a known component, page by page.
allBoundaryPages ∷ Env → Provider → ComponentKey → IO [BoundaryFace]
allBoundaryPages env provider key = go 0 (1000000 ∷ Int)
  where
    go _ 0 = expectationFailure "boundary paging did not finish" >> pure []
    go from fuel = case observedValue (queryKnownBoundary env provider key from) of
      Right (Just page) → do
        length (pageFaces page) `shouldSatisfy` (<= max (limitBoundaryFaces (envLimits env)) minimumBoundaryFaces)
        -- the traversal is bounded too, on every page and the late ones above all:
        -- a page visits at most the limit's member entries and moves forward.
        pageVisited page `shouldSatisfy` (<= max (limitBoundaryFaces (envLimits env)) minimumBoundaryFaces)
        forM_ (pageNext page) $ \next → next `shouldSatisfy` (> from)
        rest ← maybe (pure []) (\next → go next (fuel - 1)) (pageNext page)
        pure (pageFaces page <> rest)
      other → expectationFailure ("unexpected page " <> show (const () <$> Just other)) >> pure []

boundarySpecs ∷ Spec
boundarySpecs = describe "bounded boundary queries" $ do
  let patchedSource n =
        SourceSpec ["stone"] [LayerSpec Nothing (Just 0) "stone" 0] [PatchSpec (3 * i) 0 3 4 (SpecSolid "stone" 0) | i ← [1 .. n]]
      sceneOf n = Scene {sceneName = "patched " <> show n, sceneSpec = patchedSource n, sceneWindow = Window (-1, 2) (-1, 2) (-3, 3), sceneSky = Just 0}
      small = either (error . show) id (mkDiscoveryLimits baseSpec {specBoundaryFaces = 64})
  it "pages a vast boundary within the limit and reproduces the whole description" $ do
    let rig = newRig small (sceneOf 200)
        compiled = fst (mustCompile defaultConnectivityLimits (patchedSource 200))
        provider = retainedProvider (rigRetained rig)
    case componentOf compiled (mustTile3 (1, 5, 5)) of
      Nothing → expectationFailure "no sky component"
      Just key → do
        faces ← allBoundaryPages (rigEnv rig) provider key
        -- the pages go by box identity, the whole description by class order: the same faces.
        Just (sort (map show faces)) `shouldBe` fmap (sort . map show) (componentBoundary compiled key)
        length faces `shouldSatisfy` (> 10000)
        -- one page costs one read of the representative and a bounded charge.
        let first = queryKnownBoundary (rigEnv rig) provider key 0
        observedReads first `shouldSatisfy` (<= limitInspectedRecords small)
  it "allocates alike for a full page of a source with 200 and with 400 patches" $ do
    let page n = do
          let rig = newRig small (sceneOf n)
              compiled = fst (mustCompile defaultConnectivityLimits (patchedSource n))
          _ ← evaluate (envSharedBytes (rigEnv rig))
          pure (rig, componentOf compiled (mustTile3 (1, 5, 5)))
    (few, keyFew) ← page 200
    (many, keyMany) ← page 400
    -- the keys are built before anything is timed.
    _ ← evaluate (maybe 0 (const (1 ∷ Int)) keyFew + maybe 0 (const 1) keyMany)
    let first rig key = evaluate (maybe 0 (\k → either (const 0) (maybe 0 (length . pageFaces)) (observedValue (queryKnownBoundary (rigEnv rig) (retainedProvider (rigRetained rig)) k 0))) key)
    a ← allocatedBy (repeatN 20 (first few keyFew))
    b ← allocatedBy (repeatN 20 (first many keyMany))
    putStrLn ("allocation, 20 first boundary pages of 64 boxes, 200 patches: " <> show a <> " B; 400 patches: " <> show b <> " B")
    sameCost "boundary page" a b
  it "answers a query under exactly the smallest accepted scratch, for a singleton and a linked class" $ do
    let exact = either (error . show) id (mkDiscoveryLimits baseSpec {specScratchBytes = toInteger (boundaryQueryScratch 1024), specBoundaryFaces = 1024})
        flat = flatGround "flat" []
        rigFlat = newRig exact flat
        compiledFlat = fst (mustCompile defaultConnectivityLimits (sceneSpec flat))
    case componentOf compiledFlat (mustTile3 (1, 1, 3)) of
      Nothing → expectationFailure "no sky component"
      Just key → case observedValue (queryKnownBoundary (rigEnv rigFlat) (retainedProvider (rigRetained rigFlat)) key 0) of
        Right (Just page) → pageFaces page `shouldSatisfy` (not . null)
        other → expectationFailure ("singleton class: expected a page, got " <> show (const () <$> Just other))
    -- a class linked by a removal: the lookup walks a chain before the page.
    let linked = newRig exact twoOpenings
        (opened, _) = runTrace linked ([Edit c | c ← openingA] <> [Drain fullAllowance])
        compiledCave = fst (mustCompile defaultConnectivityLimits (sceneSpec twoOpenings))
    case componentOf compiledCave (mustTile3 (5, 0, 5)) of
      Nothing → expectationFailure "no cave component"
      Just key → do
        observedValue (queryComponentKnown (rigEnv opened) (retainedProvider (rigRetained opened)) key) `shouldBe` Right True
        case observedValue (queryKnownBoundary (rigEnv opened) (retainedProvider (rigRetained opened)) key 0) of
          Right (Just page) → pageFaces page `shouldSatisfy` (not . null)
          other → expectationFailure ("linked class: expected a page, got " <> show (const () <$> Just other))
  it "visits at most a page of entries on the last page of a vast class" $ do
    let rig = newRig small (sceneOf 200)
        compiled = fst (mustCompile defaultConnectivityLimits (patchedSource 200))
        provider = retainedProvider (rigRetained rig)
        cursors key from = case observedValue (queryKnownBoundary (rigEnv rig) provider key from) of
          Right (Just page) → from : maybe [] (cursors key) (pageNext page)
          _ → [from]
    case componentOf compiled (mustTile3 (1, 5, 5)) of
      Nothing → expectationFailure "no sky component"
      Just key → do
        let starts = cursors key 0
            lastStart = last starts
        length starts `shouldSatisfy` (> 100)
        case observedValue (queryKnownBoundary (rigEnv rig) provider key lastStart) of
          Right (Just page) → do
            pageVisited page `shouldSatisfy` (<= 64)
            pageNext page `shouldBe` Nothing
          other → expectationFailure ("last page: " <> show (const () <$> Just other))
  it "refuses a page the scratch cannot hold, at validation and never at the query" $ do
    mkDiscoveryLimits baseSpec {specScratchBytes = 52224, specBoundaryFaces = 1024}
      `shouldBe` Left (LimitBelowProgress FieldScratchBytes 52224 (toInteger (boundaryQueryScratch 1024)))
    -- the lookup of the class is part of the query: a page alone is not enough.
    mkDiscoveryLimits baseSpec {specScratchBytes = toInteger (boundaryPageBytes 1024), specBoundaryFaces = 1024}
      `shouldBe` Left (LimitBelowProgress FieldScratchBytes (toInteger (boundaryPageBytes 1024)) (toInteger (boundaryQueryScratch 1024)))
    mkDiscoveryLimits baseSpec {specScratchBytes = toInteger (boundaryQueryScratch 1024) - 1, specBoundaryFaces = 1024}
      `shouldBe` Left (LimitBelowProgress FieldScratchBytes (toInteger (boundaryQueryScratch 1024) - 1) (toInteger (boundaryQueryScratch 1024)))
    mkDiscoveryLimits baseSpec {specBoundaryFaces = 5} `shouldBe` Left (LimitBelowProgress FieldBoundaryFaces 5 6)
    mkDiscoveryLimits baseSpec {specBoundaryFaces = 65537} `shouldBe` Left (LimitUnrepresentable FieldBoundaryFaces 65537 65536)
