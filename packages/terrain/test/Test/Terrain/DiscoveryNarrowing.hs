-- | Discovery through cells narrowed to a corner mask: the pure model stages a narrowing, joins the
-- cell's void to the voids it contains and reaches through its current openings, and answers what is
-- known of every cell exactly as an independent flood over the same cells does.
--
-- The oracle shares nothing with the model's forest: it applies the same edits to a
-- @@0@@ value (the tagged overlay of the narrowing contract), reads every cell of a
-- bounded window from that value, joins two cells' voids where their exact openings overlap over positive
-- area, and floods from the sky cell by cell. Every example compares the model against it, or against a
-- named fact that follows from the opening geometry.
module Test.Terrain.DiscoveryNarrowing (spec) where

import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Hetoimasia.Terrain.Cell (Column, IntervalError, ZRange, cellShapeKey, mkColumn, mkZRange, zRangeHi, zRangeLo)
import Hetoimasia.Terrain.Changes
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), axisMaxValue, tileCoord)
import Hetoimasia.Terrain.Discovery
import Hetoimasia.Terrain.Geometry (FaceKind (..))
import Hetoimasia.Terrain.Opening (airOpenings, cellComponents, connectCells, keyOpenings, openingArea, portalOpening, portalsOn)
import Hetoimasia.Terrain.Query (cellAt)
import Hetoimasia.Terrain.Residency (ArenaId (..), Revision (..))
import Hetoimasia.Terrain.Shape (CornerMask, mkCornerMask)
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), Source, SourceSpec (..))
import Test.Hspec
import Test.Terrain.ConnectivityFixtures (compiled, keyAt)
import Test.Terrain.ConnectivityOracle (Cell3, Window (..), inWindow, windowCells)
import Test.Terrain.DiscoveryHarness (Delay (..), Rig (..), Scene (..), delayedProvider, groundScene, newRig, noDelay)
import Test.Terrain.Model (mustSource, mustTile, topEnd)

-- ---------------------------------------------------------------------------
-- Worlds

-- | A world: the scene, the source, and environments over the default limits and over a batch of one
-- connection, so a drain can be taken in the largest and in the smallest steps.
data World = World
  { worldScene ∷ Scene
  , worldSource ∷ Source
  , worldEnv ∷ Env
  , worldSlow ∷ Env
  }

-- | Stone below level 4 over a window of 5 x 5 columns from level -2 to level 6 (everything at or above
-- level 4 is open sky), and the given patches.
world ∷ [PatchSpec] → World
world patches = worldOf (groundScene "narrowed" 4 (0, 5) (0, 5) 6 patches)

worldOf ∷ Scene → World
worldOf scene =
  World
    { worldScene = scene
    , worldSource = mustSource (sceneSpec scene)
    , worldEnv = rigEnv (newRig defaultDiscoveryLimits scene)
    , worldSlow = rigEnv (newRig oneAtATime scene)
    }

oneAtATime ∷ DiscoveryLimits
oneAtATime =
  either
    (error . show)
    id
    ( mkDiscoveryLimits
        DiscoverySpec
          { specBatchUpdates = 1
          , specInspectedRecords = 100000
          , specDeltaRecords = 100000
          , specDeltaBytes = 1048576
          , specScratchBytes = 4194304
          , specPendingObligations = 65536
          , specRetainedBytes = 50331648
          , specBoundaryFaces = 1024
          }
    )

mask ∷ Int → CornerMask
mask = either (error . show) id . mkCornerMask

fresh ∷ Retained
fresh = newRetained (ArenaId 1)

-- ---------------------------------------------------------------------------
-- Driving the model

allowance ∷ Env → Allowance
allowance = allowanceOf . envLimits

applied ∷ Candidate → Retained → Retained
applied candidate = either (error . show) id . applyCandidate candidate

-- | A candidate within the worst-case figures of an edit that may meet narrowed cells.
checked ∷ Candidate → Candidate
checked candidate
  | nReads <= worstNarrowReads && nWrites <= worstNarrowWrites = candidate
  | otherwise = error ("an edit read " <> show nReads <> " and wrote " <> show nWrites)
  where
    report = candidateReport candidate
    nReads = reportReads report
    nWrites = reportWrites report

-- | Narrow a cell and apply the staged candidate.
narrowTo ∷ Env → Retained → Cell3 → Int → Retained
narrowTo env ret (x, y, z) m = case stageNarrowing env (retainedHeader ret) (retainedProvider ret) (allowance env) (mustTile x y z) (mask m) of
  Right (NarrowStaged candidate) → applied (checked candidate) ret
  other → error ("narrow " <> show (x, y, z, m) <> ": " <> show other)

-- | Remove a whole cell and apply the staged candidate.
removeAt ∷ Env → Retained → Cell3 → Retained
removeAt env ret (x, y, z) = case stageRemoval env (retainedHeader ret) (retainedProvider ret) (allowance env) (mustTile x y z) of
  Right (Staged candidate) → applied (checked candidate) ret
  other → error ("remove " <> show (x, y, z) <> ": " <> show other)

-- | One discovery batch, or 'Nothing' when no obligation is unfinished.
batch ∷ Env → Retained → Maybe Retained
batch env ret = case stepDiscovery env (retainedHeader ret) (retainedProvider ret) (allowance env) of
  Right (Progress candidate _) → Just (applied candidate ret)
  Right Idle → Nothing
  other → error ("step: " <> show other)

drain ∷ Env → Retained → Retained
drain env ret = maybe ret (drain env) (batch env ret)

-- | Every state of a drain taken a batch at a time, the first state included.
drainStates ∷ Env → Retained → [Retained]
drainStates env ret = ret : maybe [] (drainStates env) (batch env ret)

-- | An edit of the oracle's value and of the model.
data Edit = Narrow Cell3 Int | Remove Cell3
  deriving stock (Show)

applyEdit ∷ Env → Retained → Edit → Retained
applyEdit env ret (Narrow cell m) = narrowTo env ret cell m
applyEdit env ret (Remove cell) = removeAt env ret cell

-- | The model's value after the edits, all staged and none drained.
staged ∷ Env → [Edit] → Retained
staged env = foldl (applyEdit env) fresh

-- ---------------------------------------------------------------------------
-- The oracle

limitless ∷ ChangeLimits
limitless = ChangeLimits 1000000

-- | The overlay value after the same edits, by the tagged overlay's own operations.
oracleChanges ∷ World → [Edit] → Changes
oracleChanges w = foldl step emptyChanges
  where
    source = worldSource w
    step changes (Narrow (x, y, z) m) =
      let tile = mustTile x y z
       in either (error . show) id (narrowCell limitless source tile (cellAt source changes tile) (mask m) changes)
    step changes (Remove (x, y, z)) = either (error . show) removeResult (removeCell limitless source (mustTile x y z) changes)

-- | The cells whose void is known under the overlay: those a flood over the window reaches from the open
-- sky, joining two cells' voids where their openings overlap over positive area.
oracleKnown ∷ World → Changes → Set Cell3
oracleKnown w changes = flood Set.empty seeds
  where
    scene = worldScene w
    window = sceneWindow scene
    source = worldSource w
    cellOf (x, y, z) = cellAt source changes (mustTile x y z)
    openingsAt c = maybe airOpenings keyOpenings (cellShapeKey (cellOf c))
    hasVoid c = not (null (cellComponents (openingsAt c)))
    joined a@(ax, ay, az) b@(bx, by, bz) = not (null (connectCells (mustTile ax ay az) (openingsAt a) (mustTile bx by bz) (openingsAt b)))
    topOpen c = any ((> 0) . openingArea . portalOpening) (portalsOn TopFace (openingsAt c))
    seeds = [c | c@(_, _, z) ← windowCells window, hasVoid c, maybe False (z >=) (sceneSky scene) || (z == topEnd - 1 && topOpen c)]
    neighbours (x, y, z) = [n | n ← [(x + 1, y, z), (x - 1, y, z), (x, y + 1, z), (x, y - 1, z), (x, y, z + 1), (x, y, z - 1)], inWindow window n, hasVoid n]
    flood seen [] = seen
    flood seen (c : rest)
      | Set.member c seen = flood seen rest
      | otherwise = flood (Set.insert c seen) ([n | n ← neighbours c, joined c n] <> rest)

-- ---------------------------------------------------------------------------
-- What the model knows

knowledgeOf ∷ Env → Retained → Cell3 → CellKnowledge
knowledgeOf env ret (x, y, z) = case observedValue (queryCell env (retainedProvider ret) (mustTile x y z)) of
  Right k → k
  Left e → error (show e)

-- | The cells of the window whose void the model knows.
knownVoids ∷ World → Retained → Set Cell3
knownVoids w ret = Set.fromList [c | c ← windowCells (sceneWindow (worldScene w)), cellVoid (knowledgeOf (worldEnv w) ret c) == VoidKnown]

-- | Every cell of a region whose compressed answer differs from 'queryCell'.
regionMismatches ∷ Env → Retained → RegionCoord → [String]
regionMismatches env ret region@(RegionCoord rx ry rz) = case assembled of
  Nothing → ["the plan's answers do not assemble"]
  Just rk →
    [ show (x, y, z) <> ": region " <> show got <> ", queryCell " <> show want
    | x ← [16 * toInteger rx .. 16 * toInteger rx + 15]
    , y ← [16 * toInteger ry .. 16 * toInteger ry + 15]
    , z ← [32 * toInteger rz .. 32 * toInteger rz + 31]
    , let tile = mustTile x y z
          got = regionKnowledgeAt rk tile
          want = either (const Nothing) Just (observedValue (queryCell env provider tile))
    , got /= want || got == Nothing
    ]
  where
    provider = retainedProvider ret
    runs ∷ Map.Map Column [(Int64, Int64, Replacement)]
    runs = Map.fromListWith (flip (<>)) [(column, [(fromInteger (zRangeLo range), fromInteger (zRangeHi range), p)]) | (column, range, p) ← retainedReplacements ret]
    plan = planRegionKnowledge env region runs
    answers = [either (error . show) id (observedValue (queryCell env provider tile)) | tile ← planTiles plan]
    assembled = assembleRegionKnowledge plan answers

-- | The regions of the world's window.
regionsOf ∷ World → [RegionCoord]
regionsOf w = [RegionCoord 0 0 (fromInteger rz) | rz ← [z0 `div` 32 .. (z1 - 1) `div` 32]]
  where
    Window _ _ (z0, z1) = sceneWindow (worldScene w)

-- | The model's retained runs by column, in the tagged form of the overlay.
runsOf ∷ Retained → [(Column, [(Integer, Integer, Replacement)])]
runsOf ret = Map.toAscList (Map.fromListWith (flip (<>)) [(column, [(zRangeLo range, zRangeHi range, p)]) | (column, range, p) ← retainedReplacements ret])

-- | The overlay's runs of every column the model holds, in the same form.
overlayRuns ∷ Changes → [(Column, [(Integer, Integer, Replacement)])]
overlayRuns changes = [(column, [(zRangeLo range, zRangeHi range, p) | (range, p) ← replacementRuns changes column]) | column ← replacedColumns changes]

-- ---------------------------------------------------------------------------
-- The examples

spec ∷ Spec
spec = describe "Discovery of narrowed cells" $ do
  openingsSpec
  stackSpec
  bankStackSpec
  editsSpec
  restoreSpec
  boundariesSpec
  refusalSpec
  accountingSpec
  limitSpec

-- | A pocket of sealed air at (2, 2, 2), another at (0, 4, 0), and the ground cell (2, 2, 3) between the
-- first and the sky.
pocketWorld ∷ World
pocketWorld = world [PatchSpec 2 2 2 3 SpecAir, PatchSpec 0 4 0 1 SpecAir]

openingsSpec ∷ Spec
openingsSpec = describe "a sealed space under a narrowed cell" $ do
  it "opens below a single-high cell and reveals nothing else" $ do
    let w = pocketWorld
        env = worldEnv w
        settled = drain env (narrowTo env fresh (2, 2, 3) 1)
        known = knownVoids w settled
    known `shouldBe` oracleKnown w (oracleChanges w [Narrow (2, 2, 3) 1])
    (Set.member (2, 2, 2) known, Set.member (2, 2, 3) known, Set.member (0, 4, 0) known) `shouldBe` (True, True, False)
    -- what was known stays known
    knownVoids w fresh `shouldSatisfy` (`Set.isSubsetOf` known)
  it "stays sealed under the closed base of an opposite-high cell, which is itself open to the sky" $
    mapM_
      ( \m → do
          let w = pocketWorld
              env = worldEnv w
              settled = drain env (narrowTo env fresh (2, 2, 3) m)
              known = knownVoids w settled
          known `shouldBe` oracleKnown w (oracleChanges w [Narrow (2, 2, 3) m])
          (Set.member (2, 2, 2) known, Set.member (2, 2, 3) known) `shouldBe` (False, True)
      )
      [5, 10]
  it "knows nothing of the sealed space until the obligation is drained" $ do
    let w = pocketWorld
        env = worldEnv w
        queued = narrowTo env fresh (2, 2, 3) 1
    Set.member (2, 2, 2) (knownVoids w queued) `shouldBe` False
    Set.member (2, 2, 2) (knownVoids w (drain env queued)) `shouldBe` True
  it "agrees with the flood after each step of 15 to 14, 12, 8 and air, and an air cell is the removal's" $ do
    let w = pocketWorld
        env = worldEnv w
        steps = [14, 12, 8, 0]
        edits = [Narrow (2, 2, 3) m | m ← steps]
        states = scanl (\ret m → drain env (narrowTo env ret (2, 2, 3) m)) fresh steps
    mapM_ (\(n, ret) → (n, knownVoids w ret) `shouldBe` (n, oracleKnown w (oracleChanges w (take n edits)))) (zip [0 ..] states)
    -- narrowing to zero stages exactly what removing the cell stages
    let removal = stageRemoval env (retainedHeader fresh) (retainedProvider fresh) (allowance env) (mustTile 2 2 3)
        zero = stageNarrowing env (retainedHeader fresh) (retainedProvider fresh) (allowance env) (mustTile 2 2 3) (mask 0)
    case (removal, zero) of
      (Right (Staged a), Right (NarrowStaged b)) → a `shouldBe` b
      other → expectationFailure (show other)
  it "keeps an authored cell's known void known from the edit, before any face is inspected" $ do
    let w = world [PatchSpec 2 2 3 4 (SpecCorner "stone" 5)]
        env = worldEnv w
        queued = narrowTo env fresh (2, 2, 3) 1
        voidAt ret = cellVoid (knowledgeOf env ret (2, 2, 3))
    voidAt fresh `shouldBe` VoidKnown
    -- the edit has staged its obligation and inspected nothing, yet the widened void is still the known one
    pendingObligations (retainedHeader queued) `shouldBe` 1
    voidAt queued `shouldBe` VoidKnown
    -- the authored void and the narrowed cell's void are one class, not two classes that both read as known
    case keyAt (compiled (sceneSpec (worldScene w))) (2, 2, 3) of
      Nothing → expectationFailure "the authored cell has no void"
      Just key → do
        let classOf node = observedValue (queryNodeClass env (retainedProvider queued) node)
        classOf (SrcNode key) `shouldSatisfy` either (const False) (const True)
        classOf (CellNode (columnOf 2 2) 3) `shouldBe` classOf (SrcNode key)
    knownVoids w (drain env queued) `shouldBe` oracleKnown w (oracleChanges w [Narrow (2, 2, 3) 1])
  it "joins a narrowed cell's void into the air that replaces it" $ do
    let w = pocketWorld
        env = worldEnv w
        edits = [Narrow (2, 2, 3) 1, Remove (2, 2, 3)]
        settled = drain env (foldl (applyEdit env) fresh edits)
    knownVoids w settled `shouldBe` oracleKnown w (oracleChanges w edits)
    retainedReplacements settled `shouldSatisfy` (not . null)
    Set.member (2, 2, 2) (knownVoids w settled) `shouldBe` True
  it "coalesces air from either operation into one run" $ do
    let w = pocketWorld
        env = worldEnv w
        edits = [Remove (3, 3, 0), Narrow (3, 3, 1) 0, Remove (3, 3, 2)]
        settled = drain env (foldl (applyEdit env) fresh edits)
    runsOf settled `shouldBe` overlayRuns (oracleChanges w edits)
    runsOf settled `shouldBe` [(columnOf 3 3, [(0, 3, ReplaceAir)])]
    knownVoids w settled `shouldBe` oracleKnown w (oracleChanges w edits)

columnOf ∷ Integer → Integer → Column
columnOf x y = either (error . show) id (mkColumn x y)

-- | A sealed tunnel that reaches the sky only at (1, 0): its cells are known, and it passes beside
-- (2, 2, 1) alone of the column (2, 2).
tunnelWorld ∷ World
tunnelWorld =
  world
    [ PatchSpec 1 2 1 2 SpecAir
    , PatchSpec 1 1 1 2 SpecAir
    , PatchSpec 1 0 1 4 SpecAir
    ]

-- | The four cells of a stack at (2, 2), levels 0 to 3, every one narrowed to the same opposite-high mask.
stack ∷ [Edit]
stack = [Narrow (2, 2, z) 5 | z ← [0 .. 3]]

stackSpec ∷ Spec
stackSpec = describe "a stack of equal masks" $ do
  let w = tunnelWorld
      env = worldEnv w
      queued = staged env stack
      drained = drain env queued
      oracle = oracleKnown w (oracleChanges w stack)
  it "shares one run and keeps a separate void in every cell" $ do
    runsOf drained `shouldBe` [(columnOf 2 2, [(0, 4, ReplaceMask (mask 5))])]
    runsOf drained `shouldBe` overlayRuns (oracleChanges w stack)
    [Set.member (2, 2, z) (knownVoids w drained) | z ← [0 .. 3]] `shouldBe` [False, True, False, True]
    knownVoids w drained `shouldBe` oracle
    -- the two sealed cells are separate classes of their own; the known cells are the one known class
    let classOf z = observedValue (queryNodeClass env (retainedProvider drained) (CellNode (columnOf 2 2) z))
    [classOf 0 == classOf 2, classOf 1 == classOf 3, classOf 0 == classOf 1, classOf 2 == classOf 1] `shouldBe` [False, True, False, False]
  it "answers a whole region with the answer of every cell, drained and with every obligation unfinished" $
    mapM_
      ( \(name, ret) → mapM_ (\region → (name, region, regionMismatches env ret region) `shouldBe` (name, region, [])) (regionsOf w)
      )
      [("queued", queued), ("one batch", maybe queued id (batch (worldSlow w) queued)), ("drained", drained)]
  it "keeps the outer cells' knowledge and voids through a split of the run, and through a restore" $ do
    let edited = drain env (narrowTo env drained (2, 2, 2) 1)
        earlier z = knowledgeOf env drained (2, 2, z)
        settled z = knowledgeOf env edited (2, 2, z)
        classOf ret z = observedValue (queryNodeClass env (retainedProvider ret) (CellNode (columnOf 2 2) z))
    [settled z | z ← [0, 1, 3]] `shouldBe` [earlier z | z ← [0, 1, 3]]
    [classOf edited z | z ← [0, 1, 3]] `shouldBe` [classOf drained z | z ← [0, 1, 3]]
    classOf edited 0 == classOf edited 1 `shouldBe` False
    -- the edited cell opens onto the known cell below it and is known
    (settled 2, earlier 2) `shouldBe` (CellKnowledge SolidKnown VoidKnown, CellKnowledge SolidKnown VoidUnknown)
    runsOf edited `shouldBe` overlayRuns (oracleChanges w (stack <> [Narrow (2, 2, 2) 1]))
    runsOf edited `shouldBe` [(columnOf 2 2, [(0, 2, ReplaceMask (mask 5)), (2, 3, ReplaceMask (mask 1)), (3, 4, ReplaceMask (mask 5))])]
    knownVoids w edited `shouldBe` oracleKnown w (oracleChanges w (stack <> [Narrow (2, 2, 2) 1]))
    restored (retainedHeader edited) (retainedRecords edited) `shouldBe` Right edited
    case restored (retainedHeader edited) (retainedRecords edited) of
      Right again → do
        [knowledgeOf env again (2, 2, z) | z ← [0 .. 3]] `shouldBe` [settled z | z ← [0 .. 3]]
        [classOf again z | z ← [0, 1, 3]] `shouldBe` [classOf edited z | z ← [0, 1, 3]]
      Left e → expectationFailure (show e)

-- | Eight equal banks at (2, 2), levels 0 to 7 under open sky, narrowed top first. The banks join one
-- another, so while the work drains the known cells are those the finished obligations have reached from
-- the top: adjacent interior levels of the one run differ in knowledge with no lattice cut or run end
-- between them, and a plan that evaluated only the first, second and last level of the run would give every
-- interior level the answer of the second.
bankStackSpec ∷ Spec
bankStackSpec = describe "a stack of equal banks narrowed from the top down" $ do
  let w = worldOf (groundScene "banks" 8 (0, 5) (0, 5) 10 [])
      env = worldEnv w
      slow = worldSlow w
      edits = [Narrow (2, 2, z) 1 | z ← [7, 6 .. 0]]
      queued = staged env edits
      states = drainStates slow queued
      pattern ret = [cellVoid (knowledgeOf env ret (2, 2, z)) == VoidKnown | z ← [0 .. 7]]
      interiorDiffers ret = or (zipWith (/=) (take 4 (drop 2 (pattern ret))) (take 4 (drop 3 (pattern ret))))
      region = RegionCoord 0 0 0
      plansEveryLevel ret =
        let runs = Map.fromListWith (flip (<>)) [(column, [(fromInteger (zRangeLo range), fromInteger (zRangeHi range), p)]) | (column, range, p) ← retainedReplacements ret]
         in planPerLevelTiles (planRegionKnowledge env region runs)
  it "shares one run, drains to what the flood finds, and has states whose interior levels differ" $ do
    runsOf queued `shouldBe` [(columnOf 2 2, [(0, 8, ReplaceMask (mask 1))])]
    knownVoids w (drain env queued) `shouldBe` oracleKnown w (oracleChanges w edits)
    length (filter interiorDiffers states) `shouldSatisfy` (> 3)
  it "answers a whole region with the answer of every cell while the obligations drain, and evaluates every level" $ do
    let sampled = [ret | (n, ret) ← zip [0 ∷ Int ..] states, n `elem` [0, 9, 18, 27, 36, 45], interiorDiffers ret || n == 0] <> [last states]
    length sampled `shouldSatisfy` (>= 3)
    mapM_ (\ret → regionMismatches env ret region `shouldBe` []) sampled
    mapM_ (\ret → plansEveryLevel ret `shouldSatisfy` (>= 8)) sampled

restored ∷ Header → [(RecordKey, Record)] → Either Integrity Retained
restored = retainedFromRecords

editsSpec ∷ Spec
editsSpec = describe "edits made before earlier work drains" $ do
  let w = tunnelWorld
      env = worldEnv w
      slow = worldSlow w
      stackIn order = [stack !! i | i ← order]
      knowledgeIn ret = knownVoids w ret
  it "finds every connection in any order of edits and any size of batch" $ do
    let orders = [[0, 1, 2, 3], [3, 2, 1, 0], [1, 3, 0, 2]]
        outcomes = [drain e (staged env (stackIn order)) | order ← orders, e ← [env, slow]]
        expected = oracleKnown w (oracleChanges w stack)
    mapM_ (\ret → knowledgeIn ret `shouldBe` expected) outcomes
    mapM_ (\ret → runsOf ret `shouldBe` runsOf (drain env (staged env stack))) outcomes
  it "keeps what is known, reveals only what the finished work reaches, and finds the rest when drained" $ do
    let queued = staged env stack
        states = drainStates slow queued
        final = oracleKnown w (oracleChanges w stack)
        earlier = knowledgeIn fresh
    length states `shouldSatisfy` (> 4)
    mapM_ (\ret → (knowledgeIn ret `Set.isSubsetOf` final, earlier `Set.isSubsetOf` knowledgeIn ret) `shouldBe` (True, True)) states
    -- each state is a sound restore point and drains to the same result
    mapM_ (\ret → fmap (knowledgeIn . drain env) (restored (retainedHeader ret) (retainedRecords ret)) `shouldBe` Right final) states
    -- known space only grows
    let sizes = map (Set.size . knowledgeIn) states
    and (zipWith (<=) sizes (drop 1 sizes)) `shouldBe` True
  it "finds the connection a later edit opens across a face an earlier obligation already inspected" $ do
    -- level 1 is sealed under the full ground cell at level 2, the top ground cell under open sky; narrowing
    -- level 2 to a bank opens its bottom onto level 1's top and its top onto the sky
    let wf = worldOf (groundScene "faces" 3 (0, 5) (0, 5) 5 [])
        ef = worldEnv wf
        sf = worldSlow wf
        edits = [Narrow (2, 2, 1) 5, Narrow (2, 2, 2) 1]
        queuedFirst = staged ef [Narrow (2, 2, 1) 5]
        halfInspected = maybe queuedFirst id (batch sf queuedFirst)
        finished = drain ef queuedFirst
        expected = oracleKnown wf (oracleChanges wf edits)
    -- the first obligation has inspected a face and has more to do, and nothing is known of level 1
    pendingObligations (retainedHeader halfInspected) `shouldBe` 1
    Set.member (2, 2, 1) (knownVoids wf halfInspected) `shouldBe` False
    mapM_
      ( \ret → do
          let settled = drain ef (narrowTo ef ret (2, 2, 2) 1)
          knownVoids wf settled `shouldBe` expected
          Set.member (2, 2, 1) (knownVoids wf settled) `shouldBe` True
      )
      [halfInspected, finished]
  it "narrows the same cell again before its first obligation drains" $ do
    let edits = [Narrow (2, 2, 3) 14, Narrow (2, 2, 3) 12, Narrow (2, 2, 3) 8]
        w' = pocketWorld
        e' = worldEnv w'
        queued = staged e' edits
    pendingObligations (retainedHeader queued) `shouldBe` 3
    knownVoids w' (drain e' queued) `shouldBe` oracleKnown w' (oracleChanges w' edits)
    runsOf queued `shouldBe` overlayRuns (oracleChanges w' edits)
  it "advances content on every narrowing and knowledge only when known space grows" $ do
    let w' = pocketWorld
        e' = worldEnv w'
        stageOne ret cell m = case stageNarrowing e' (retainedHeader ret) (retainedProvider ret) (allowance e') (uncurry3 mustTile cell) (mask m) of
          Right (NarrowStaged c) → c
          other → error (show other)
        uncurry3 f (a, b, c) = f a b c
        buried = stageOne fresh (3, 3, 0) 5
        top = stageOne fresh (2, 2, 3) 1
        topApplied = applied top fresh
        widened = stageOne (drain e' topApplied) (2, 2, 3) 0
        revisions ret = let a = hAuthority (retainedHeader ret) in (authContent a, authKnowledge a, authStore a)
        next (Revision n) = Revision (n + 1)
        advanced (c, k, s) (content, knowledge) = (if content then next c else c, if knowledge then next k else k, next s)
        from ret = revisions ret
    -- a narrowing inside sealed stone: new content, no known space
    (candidateTerrain buried, candidateKnowledge buried, candidateFrontierOnly buried) `shouldBe` (True, False, False)
    revisions (applied buried fresh) `shouldBe` advanced (from fresh) (True, False)
    -- a narrowed ground cell has no void before the edit: the edit alone reaches nothing known
    (candidateTerrain top, candidateKnowledge top) `shouldBe` (True, False)
    revisions topApplied `shouldBe` advanced (from fresh) (True, False)
    -- the batch that joins it to the sky makes space known and changes no content
    case stepDiscovery e' (retainedHeader topApplied) (retainedProvider topApplied) (allowance e') of
      Right (Progress c _) → do
        (candidateTerrain c, candidateFrontierOnly c) `shouldBe` (False, False)
        candidateKnowledge c `shouldBe` True
        revisions (applied c topApplied) `shouldBe` advanced (from topApplied) (False, True)
      other → expectationFailure (show other)
    -- widening a cell whose void is already known grows known space
    (candidateTerrain widened, candidateKnowledge widened) `shouldBe` (True, True)
    revisions (applied widened (drain e' topApplied)) `shouldBe` advanced (from (drain e' topApplied)) (True, True)
  it "gives a removal-only history the same retained runs it always had" $ do
    let w' = pocketWorld
        e' = worldEnv w'
        edits = [Remove (3, 3, 0), Remove (3, 3, 2), Remove (3, 3, 1)]
        settled = drain e' (staged e' edits)
    retainedRemovals settled `shouldSatisfy` (\runs → length runs == 1)
    runsOf settled `shouldBe` [(columnOf 3 3, [(0, 3, ReplaceAir)])]
    [(col, zRangeLo r, zRangeHi r) | (col, r) ← retainedRemovals settled] `shouldBe` [(columnOf 3 3, 0, 3)]
  it "reads every retained run in the tagged form and removals as air only" $ do
    let w' = pocketWorld
        e' = worldEnv w'
        edits = [Narrow (3, 3, 0) 5, Narrow (3, 3, 2) 5, Narrow (3, 3, 1) 5, Narrow (3, 3, 1) 1, Remove (3, 3, 1), Narrow (3, 3, 0) 0]
        states = scanl (applyEdit e') fresh edits
        oracle n = oracleChanges w' (take n edits)
    mapM_ (\(n, ret) → (n, runsOf ret) `shouldBe` (n, overlayRuns (oracle n))) (zip [0 ..] states)
    let final = last states
    runsOf final `shouldBe` [(columnOf 3 3, [(0, 2, ReplaceAir), (2, 3, ReplaceMask (mask 5))])]
    [(zRangeLo r, zRangeHi r) | (_, r) ← retainedRemovals final] `shouldBe` [(0, 2)]
    knownVoids w' (drain e' final) `shouldBe` oracleKnown w' (oracle (length edits))

restoreSpec ∷ Spec
restoreSpec = describe "restored records" $ do
  let w = tunnelWorld
      env = worldEnv w
      drained = drain env (staged env stack)
      ret' = drain env (staged env [Narrow (3, 3, 0) 5, Narrow (3, 3, 1) 1])
  it "reproduce the same facts and outstanding work" $ do
    let queued = staged env stack
    mapM_
      ( \ret → do
          restored (retainedHeader ret) (retainedRecords ret) `shouldBe` Right ret
          fmap (\r → (pendingObligations (retainedHeader r), knownVoids w r)) (restored (retainedHeader ret) (retainedRecords ret))
            `shouldBe` Right (pendingObligations (retainedHeader ret), knownVoids w ret)
      )
      [fresh, queued, drained, ret']
  it "accept runs that touch with different payloads and refuse two that touch with the same one" $ do
    let touching = [(k, r) | (k@(KeyRun _ _), r) ← retainedRecords ret']
        others = [(k, r) | (k, r) ← retainedRecords ret', not (isRun k)]
        isRun k = case k of KeyRun _ _ → True; _ → False
        column = columnOf 3 3
    touching `shouldBe` [(KeyRun column 0, RecMaskRun 1 (mask 5)), (KeyRun column 1, RecMaskRun 2 (mask 1))]
    fmap retainedReplacements (restored (retainedHeader ret') (retainedRecords ret'))
      `shouldBe` Right [(column, either (error . show) id (mkZRangeFor 0 1), ReplaceMask (mask 5)), (column, either (error . show) id (mkZRangeFor 1 2), ReplaceMask (mask 1))]
    let same = [(KeyRun column 0, RecMaskRun 1 (mask 5)), (KeyRun column 1, RecMaskRun 2 (mask 5))]
    restored (retainedHeader ret') (same <> others) `shouldBe` Left (MalformedRecord (KeyRun column 1))
    let air = [(KeyRun column 0, RecRun 1), (KeyRun column 1, RecRun 2)]
    restored (retainedHeader ret') (air <> others) `shouldBe` Left (MalformedRecord (KeyRun column 1))
    let overlap = [(KeyRun column 0, RecMaskRun 2 (mask 5)), (KeyRun column 1, RecMaskRun 3 (mask 1))]
    restored (retainedHeader ret') (overlap <> others) `shouldBe` Left (MalformedRecord (KeyRun column 1))
    restored (retainedHeader ret') ([(KeyRun column 0, RecMaskRun 1 (mask 0))] <> others) `shouldBe` Left (MalformedRecord (KeyRun column 0))
  it "suspend staging and a step on a withheld record and give the same answer once it is supplied" $ do
    let w' = pocketWorld
        e' = worldEnv w'
        column = columnOf 2 2
        withheld = delayedProvider (Delay (Set.singleton column) Set.empty)
        stageWith provider = stageNarrowing e' (retainedHeader fresh) provider (allowance e') (mustTile 2 2 3) (mask 1)
        plain = stageWith (retainedProvider fresh)
    case stageWith (withheld (retainedProvider fresh)) of
      Right (NarrowSuspended _) → pure ()
      other → expectationFailure ("staging did not suspend: " <> show other)
    case plain of
      Right (NarrowStaged _) → pure ()
      other → expectationFailure (show other)
    stageWith (retainedProvider fresh) `shouldBe` plain
    let queued = narrowTo e' fresh (2, 2, 3) 1
        stepWith provider = stepDiscovery e' (retainedHeader queued) provider (allowance e')
    case stepWith (withheld (retainedProvider queued)) of
      Right (Stalled _) → pure ()
      other → expectationFailure ("the step did not suspend: " <> show other)
    stepWith (retainedProvider queued) `shouldSatisfy` (\r → case r of Right (Progress _ _) → True; _ → False)
    -- nothing was staged, so the work is the same before and after
    knownVoids w' (drain e' queued) `shouldBe` oracleKnown w' (oracleChanges w' [Narrow (2, 2, 3) 1])
    noDelay `seq` pure ()

mkZRangeFor ∷ Integer → Integer → Either IntervalError ZRange
mkZRangeFor = mkZRange

boundariesSpec ∷ Spec
boundariesSpec = describe "the edges of the world" $ do
  let spec' = SourceSpec ["stone"] [LayerSpec Nothing Nothing "stone" 0] []
      scene = Scene "edges" spec' (Window (0, 1) (0, 1) (0, 1)) Nothing
      w = worldOf scene
      env = worldEnv w
      at x y z = either (error . show) id (tileCoord x y z)
      voidAt ret x y z = case observedValue (queryCell env (retainedProvider ret) (at x y z)) of
        Right k → cellVoid k
        Left e → error (show e)
      narrowAt ret x y z m = case stageNarrowing env (retainedHeader ret) (retainedProvider ret) (allowance env) (at x y z) (mask m) of
        Right (NarrowStaged c) → applied c ret
        other → error (show other)
      edge = toInteger axisMaxValue
  it "connects a narrowed cell with an open top at the highest level to the exterior" $ do
    let settled = drain env (narrowAt fresh 0 0 (topEnd - 1) 1)
    voidAt settled 0 0 (topEnd - 1) `shouldBe` VoidKnown
  it "reveals nothing through a bank's bottom opening at the lowest level or a side opening at an X or Y limit" $ do
    let lowest = drain env (narrowAt fresh 0 0 (negate topEnd) 1)
        limits = foldl (\ret (x, y) → drain env (narrowAt ret x y 5 1)) fresh [(edge, 0), (0, edge), (edge, edge)]
    voidAt lowest 0 0 (negate topEnd) `shouldBe` VoidUnknown
    [voidAt limits x y 5 | (x, y) ← [(edge, 0), (0, edge), (edge, edge)]] `shouldBe` replicate 3 VoidUnknown
    -- and no unrelated cell is revealed
    voidAt lowest 0 0 (negate topEnd + 1) `shouldBe` NoVoidHere
    voidAt limits 1 0 5 `shouldBe` NoVoidHere

refusalSpec ∷ Spec
refusalSpec = describe "a narrowing the transition refuses" $ do
  let w = world [PatchSpec 3 3 3 4 (SpecSolid "stone" 3)]
      env = worldEnv w
      narrowed = narrowTo env fresh (1, 1, 3) 5
      outcome ret cell m = stageNarrowing env (retainedHeader ret) (retainedProvider ret) (allowance env) (uncurry3 mustTile cell) (mask m)
      uncurry3 f (a, b, c) = f a b c
  it "leaves no record, obligation or revision, and is not a suspension" $ do
    outcome fresh (2, 2, 6) 1 `shouldBe` Right NarrowRefused
    outcome fresh (3, 3, 3) 1 `shouldBe` Right NarrowRefused
    outcome fresh (2, 2, 3) 15 `shouldBe` Right NarrowRefused
    mapM_ (\m → outcome narrowed (1, 1, 3) m `shouldBe` Right NarrowRefused) [5, 7, 15]
    -- a withheld record leaves the question open instead
    case stageNarrowing env (retainedHeader fresh) (delayedProvider (Delay (Set.singleton (columnOf 2 2)) Set.empty) (retainedProvider fresh)) (allowance env) (mustTile 2 2 3) (mask 1) of
      Right (NarrowSuspended _) → pure ()
      other → expectationFailure (show other)
  it "narrows from corner 15 as it does from side 0, and leaves a refused cell as it was" $ do
    let corner = SourceSpec ["stone"] [LayerSpec Nothing (Just 4) "stone" 0] [PatchSpec 2 2 3 4 (SpecCorner "stone" 15)]
        wc = worldOf (Scene "corner" corner (Window (0, 5) (0, 5) (-2, 7)) (Just 4))
        ec = worldEnv wc
    case stageNarrowing ec (retainedHeader fresh) (retainedProvider fresh) (allowance ec) (mustTile 2 2 3) (mask 15) of
      Right NarrowRefused → pure ()
      other → expectationFailure (show other)
    case stageNarrowing ec (retainedHeader fresh) (retainedProvider fresh) (allowance ec) (mustTile 2 2 3) (mask 14) of
      Right (NarrowStaged _) → pure ()
      other → expectationFailure (show other)
    narrowed `shouldSatisfy` ((== 1) . pendingObligations . retainedHeader)

accountingSpec ∷ Spec
accountingSpec = describe "the bytes of an edit" $ do
  let w = pocketWorld
      env = worldEnv w
  it "charges the deletion of a mask run what that run holds, so a tight allowance refuses" $ do
    -- narrowing the cell below an equal mask run coalesces with it and deletes the upper run's key
    let base = narrowTo env fresh (3, 3, 1) 5
        stageWith allow = stageNarrowing env (retainedHeader base) (retainedProvider base) allow (mustTile 3 3 0) (mask 5)
        full = allowance env
        retained = Map.fromList (retainedRecords base)
    case stageWith full of
      Right (NarrowStaged c) → do
        let expected = headerBytes + sum [maybe (maybe 0 (entryBytes k) (Map.lookup k retained)) (entryBytes k) v | (k, v) ← candidateWrites c]
            needed = reportDeltaBytes (candidateReport c)
        [k | (k, Nothing) ← candidateWrites c] `shouldBe` [KeyRun (columnOf 3 3) 1]
        needed `shouldBe` expected
        reportScratchBytes (candidateReport c) `shouldSatisfy` (>= needed)
        case stageWith full {allowDeltaBytes = needed - 1} of
          Left (CapacityBlocked CapacityDeltaBytes _ _) → pure ()
          other → expectationFailure ("a tight allowance did not refuse: " <> show (const () <$> Just other))
        stageWith full {allowDeltaBytes = needed} `shouldSatisfy` (\r → case r of Right (NarrowStaged _) → True; _ → False)
      other → expectationFailure (show other)
  it "refuses a floor answer that names mask zero, when staging and when querying" $ do
    let col = columnOf 2 2
        broken = Provider {fetchRecord = const Absent, fetchFloorRun = \_ _ → Found (0, 4, ReplaceMask (mask 0))}
    case stageNarrowing env (retainedHeader fresh) broken (allowance env) (mustTile 2 2 3) (mask 1) of
      Left (Corrupt (BadFloor c _)) → c `shouldBe` col
      other → expectationFailure (show other)
    case observedValue (queryCell env broken (mustTile 2 2 3)) of
      Left (Inconsistent (BadFloor c _)) → c `shouldBe` col
      other → expectationFailure (show other)
  it "refuses a floor answer outside the supported levels, so a staged run can always be restored" $ do
    let col = columnOf 2 2
        top = fromInteger topEnd
        outside run = Provider {fetchRecord = const Absent, fetchFloorRun = \_ _ → Found run}
    mapM_
      ( \run → case stageNarrowing env (retainedHeader fresh) (outside run) (allowance env) (mustTile 2 2 1) (mask 1) of
          Left (Corrupt (BadFloor c _)) → c `shouldBe` col
          other → expectationFailure (show run <> ": " <> show other)
      )
      [(0, top + 1, ReplaceMask (mask 5)), (negate top - 1, 4, ReplaceMask (mask 5)), (0, top + 1, ReplaceAir)]

limitSpec ∷ Spec
limitSpec = describe "the figures of an edit" $ do
  it "keeps the figures of a history of removals and names the larger ones of a history with narrowed cells" $ do
    (worstEditReads, worstEditWrites, worstEdgeReads, worstEdgeWrites) `shouldBe` (197, 7, 132, 3)
    (worstNarrowReads, worstNarrowWrites) `shouldBe` (198, 8)
  it "refuses a configuration below the larger figures" $ do
    let spec' =
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
    mkDiscoveryLimits spec' {specInspectedRecords = toInteger worstEditReads}
      `shouldBe` Left (LimitBelowProgress FieldInspectedRecords (toInteger worstEditReads) (toInteger worstNarrowReads))
    mkDiscoveryLimits spec' {specDeltaRecords = toInteger worstEditWrites}
      `shouldBe` Left (LimitBelowProgress FieldDeltaRecords (toInteger worstEditWrites) (toInteger worstNarrowWrites))
    mkDiscoveryLimits spec' {specInspectedRecords = toInteger worstNarrowReads, specDeltaRecords = toInteger worstNarrowWrites}
      `shouldSatisfy` either (const False) (const True)
