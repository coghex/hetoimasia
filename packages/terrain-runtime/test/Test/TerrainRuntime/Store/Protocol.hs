-- | The caller protocol of the facade, followed EXACTLY as documented, over valid stores.
--
-- The work limit of a window counts units of a planner's own work (the pages a maintenance transaction frees, the record
-- writes of a discovery batch), and a planner never does less than its atomic unit: a limit below it means the unit.
-- Round 16 found a limit of one and two answering a refusal the caller could not get past (a connection inspection stages
-- three writes), so the retry the protocol prescribes was not a way out. These examples drive a caller that does exactly what
-- the facade documents, for EVERY starting work limit from 1 to 64, for discovery, a standalone removal and maintenance, under
-- the standard bounds and under the tightest window the at-once bounds allow: pending work always drains, and no step
-- ever answers 'Invalid', 'Integrity', 'Stale' or any capacity the protocol does not name.
module Test.TerrainRuntime.Store.Protocol (spec) where

import Control.Monad (foldM, forM, forM_)
import qualified Data.ByteString as BS
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Discovery (Env, Node (..), ReadSet (..), Record (..), RecordKey (..), Root (..), allowanceOf, envLimits, pendingObligations, retainedHeader, retainedProvider, stepDiscoveryTraced, worstEdgeReads, worstEdgeWrites, worstEditReads, worstEditWrites)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Admission (Class (..), EditBankSpec (..), defaultEditBankSpec, mkEditBankConfig, newAdmission, reserve, transactionCredits)
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference
import Test.TerrainRuntime.Store.Scattered (fragmented)
import Test.TerrainRuntime.Store.Scenes

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | What the caller did to get a plan through.
data Counts = Counts {cReductions ∷ !Int, cCheckpoints ∷ !Int, cPages ∷ !Int, cMaintenance ∷ !Int, cReadPeak ∷ !Int, cFacts ∷ !Int, cProbePeak ∷ !Int}

noCounts ∷ Counts
noCounts = Counts 0 0 0 0 0 0 0

addCounts ∷ Counts → Counts → Counts
addCounts (Counts a b c d e f g) (Counts a' b' c' d' e' f' g') = Counts (a + a') (b + b') (c + c') (d + d') (max e e') (max f f') (max g g')

windowResult ∷ CapacityWhy → Bool
windowResult c = case c of
  WindowExceeded _ → True
  WindowBytesExceeded _ → True
  ProbesExceeded _ → True
  _ → False

-- | One plan, driven as the facade documents: 'Pending' and 'PendingProbes' fetch, 'Checkpoint' builds a fresh window with the
-- facts, a window result builds a fresh window with the work halved ('reduceWork'), 'LooseExceeded' shrinks like any other
-- batch and, at the smallest unit, runs maintenance and plans again; anything else that is refused is a failure. Starts at the
-- given work limit. Returns the store (maintenance may have committed), the outcome ('Planned', 'NoWork' or 'BlockedByReader')
-- and what the caller did.
drive ∷ H → Int → (H → Window → Planned) → Either String (H, Planned, Counts)
drive h0 limit = driveFrom h0 (limitWork limit (storeWindow (hStore h0)))

-- | The most steps (pages fetched and checkpoints) a plan through the protocol may take: every checkpoint carries at least one new
-- read fact, a removal reads at most 'worstEditReads' records (+1 for the end of its read phase) and a window fetches at most
-- 'maxWindowPages' pages between two checkpoints.
maxProtocolSteps ∷ Int
maxProtocolSteps = (worstEditReads + 1) * (maxWindowPages + 1) + 1000

-- | 'drive' from a given window (one that may carry facts).
driveFrom ∷ H → Window → (H → Window → Planned) → Either String (H, Planned, Counts)
driveFrom h0 w0 planner = loop h0 w0 noCounts (0 ∷ Int)
  where
    loop h w c0 n
      | n > maxProtocolSteps = Left ("the protocol did not settle in " <> show maxProtocolSteps <> " steps")
      | otherwise = let c = c0 {cProbePeak = max (cProbePeak c0) (windowProbeCount w)} in case planner h w of
          Pending p → case diskRead (hDisk h) p of
            Nothing → Left ("pending page not on disk: " <> show p)
            Just bs → case windowInsert (cfgUsablePages (hCfg h)) p bs w of
              Left e → Left ("page " <> show p <> " refused: " <> show e)
              Right w' → loop h w' c {cPages = cPages c + 1} (n + 1)
          PendingProbes ps → loop h (foldl (\w' p → windowProbe (cfgUsablePages (hCfg h)) p (maybe BS.empty id (diskRead (hDisk h) p)) w') w ps) c {cPages = cPages c + 1} (n + 1)
          Checkpoint fs → let w' = windowCheckpoint fs w in loop h w' c {cCheckpoints = cCheckpoints c + 1, cReadPeak = max (cReadPeak c) (windowSize w), cFacts = max (cFacts c) (windowReadFactCount w')} (n + 1)
          Refused (Capacity why)
            | windowResult why →
                if windowWork w <= 1
                  then Left ("a window result at the smallest work limit, which must fit: " <> show why)
                  else loop h (reduceWork w (storeWindow (hStore h))) c {cReductions = cReductions c + 1} (n + 1)
            | LooseExceeded _ ← why →
                if windowWork w > 1
                  then loop h (reduceWork w (storeWindow (hStore h))) c {cReductions = cReductions c + 1} (n + 1)
                  else do
                    -- the smallest unit: run maintenance, then plan again
                    (h', m, c') ← drive h 1 (\hh ww → planMaintenance (hStore hh) ww)
                    case m of
                      Planned plan → do
                        h'' ← commitPlan h' plan
                        loop h'' (limitWork 1 (storeWindow (hStore h''))) (addCounts c c') {cMaintenance = cMaintenance c + 1} (n + 1)
                      other → Left ("the loose list is over its bound and maintenance answered " <> take 120 (show other))
          Refused why → Left ("the protocol met a refusal it does not name: " <> take 300 (show why))
          other → Right (h, other, c)

-- | The window bounds that are exactly the at-once bound of a unit of discovery (one connection inspection) for the heights of
-- the store's trees: the tightest window the bounds allow it.
discoveryTight ∷ H → Bounds
discoveryTight h = tightBounds (discoveryUnitWindowPages (retireInternalsOf h) (heightOf h TreeFree) (recordHeight h) 0)

-- | The same for a unit of maintenance of one page.
maintenanceTight ∷ H → Bounds
maintenanceTight h = tightBounds (workOneWindowPages (heightOf h TreeRetire) (heightOf h TreeFree) (recordHeight h) 0)

-- | The same for a standalone removal.
removalTight ∷ H → Bounds
removalTight h = tightBounds (removalWindowPages (retireInternalsOf h) (heightOf h TreeFree) (recordHeight h) 0)

-- | The same plan with no read-phase checkpoint at all: a window as large as any plan can fill and no residue rule.
unboundedReads ∷ Bounds
unboundedReads = standardBounds {bdWindowPages = 1000000, bdWindowBytes = maxBound `div` 2, bdReadResidue = maxBound}

tightBounds ∷ Int → Bounds
tightBounds lim = standardBounds {bdWindowPages = lim, bdWindowBytes = lim * windowPageBytes}

recordHeight ∷ H → Int
recordHeight h = maximum [heightOf h t | t ← [TreeRuns, TreeLinks, TreeTodo]]

retireInternalsOf ∷ H → Int
retireInternalsOf h = max 0 (heightOf h TreeRetire - 1)

-- | A discovery drain through the protocol: every batch planned by 'drive', mirrored on the reference and compared.
discoveryDrain ∷ Bounds → Int → Run → Either String (Run, Int)
discoveryDrain bounds limit = go 0
  where
    go n run
      | n > (4000 ∷ Int) = Left "discovery did not drain"
      | otherwise = do
          (run', progressed) ← batchStepWith (\hh env → (\(hh', p, _) → (hh', p)) <$> drive hh limit (\h2 w → planDiscoveryWith bounds env (hStore h2) w)) run
          if progressed then go (n + 1) run' else Right (run', n)

-- | Reclaim until nothing is left, through the protocol: every transaction committed, the checker agreeing after each.
maintenanceDrain ∷ (H → Bounds) → Int → H → Either String (H, Int, Counts)
maintenanceDrain = maintenanceUntil (const False)

-- | 'maintenanceDrain' that also stops as soon as a predicate of the store holds (checked before each transaction).
maintenanceUntil ∷ (H → Bool) → (H → Bounds) → Int → H → Either String (H, Int, Counts)
maintenanceUntil done boundsOf limit = go 0 noCounts
  where
    go n c h
      | done h = Right (h, n, c)
      | n > (9000 ∷ Int) = Left "maintenance did not drain in 9,000 transactions"
      | otherwise = do
          (h1, p, c') ← drive h limit (\hh w → planMaintenanceWith (boundsOf hh) (hStore hh) w)
          case p of
            NoWork → Right (h1, n, addCounts c c')
            Planned plan → do
              h2 ← commitPlan h1 plan
              checkH h2
              go (n + 1) (addCounts c c') h2
            other → Left ("maintenance answered " <> take 200 (show other))

spec ∷ Spec
spec = readPhaseSpec >> protocolSpec

protocolSpec ∷ Spec
protocolSpec = describe "the facade's caller protocol, followed exactly, for every starting work limit" $ do
  let limits = [1 .. 64 ∷ Int]
      withScene = do
        let run0 = newRun smallSpec twoOpenings 64
        r1 ← must (foldM (\r (x, y, z) → removeCell r (tileAt x y z)) run0 openingA)
        pure (run0, r1)
  it "defines the atomic unit of each planner once, and the window of the smallest unit of each fits at every height and pin count" $ do
    -- the unit of discovery is #661's own constant (the figure its planner refuses a smaller allowance with), the unit of maintenance
    -- one page; a work limit below a unit means the unit
    discoveryUnitWrites `shouldBe` worstEdgeWrites
    maintenanceUnitPages `shouldBe` 1
    windowWorkAtLeast discoveryUnitWrites (limitWork 1 (emptyWindow ident0 0)) `shouldBe` worstEdgeWrites
    windowWorkAtLeast discoveryUnitWrites (limitWork 64 (emptyWindow ident0 0)) `shouldBe` 64
    -- one connection inspection (at most 3 writes) holds a window no larger than the standalone removal's (7 writes), which fits
    -- the byte limit at every height of every tree and every number of pinned readers (and the unit of maintenance is bounded alike)
    let hs = [1 .. maxLevel + 1]
        bad =
          [ (hf, hrec, pins)
          | hf ← hs
          , hrec ← hs
          , pins ← [0 .. maxReaders]
          , discoveryUnitWindowPages maxRetireInternals hf hrec pins > removalWindowPages maxRetireInternals hf hrec pins
              || discoveryUnitWindowPages maxRetireInternals hf hrec pins * windowPageBytes + discoveryUnitWorstProbes * probeBytes > maxWindowBytes
          ]
    bad `shouldBe` []
    putStrLn ("PROTOCOL bounds: unit of discovery (3 writes) at (8,8,16) = " <> show (discoveryUnitWindowPages maxRetireInternals 8 8 16) <> " pages, removal (7 writes) = " <> show (removalWindowPages maxRetireInternals 8 8 16) <> ", limit " <> show (maxWindowBytes `div` windowPageBytes))
  it "the reviewer's repro: after one batch through a work limit of one, the remaining discovery plans at limits 1, 2 and 3 (it was refused at 1 and 2)" $ do
    (_, r1) ← withScene
    forM_ [1, 2, 3 ∷ Int] $ \lim → do
      let env = runEnv r1
          h = runH r1
      -- one discovery batch through a limit of one, committed
      (p0, _, _) ← must (fillWith h (\w → planDiscovery env (hStore h) (limitWork 1 w)))
      h1 ← case p0 of
        Planned plan → must (commitPlan h plan)
        other → expectationFailure ("the first batch was not planned: " <> take 200 (show other)) >> fail "first"
      -- then the rest, at the limit under test
      (p1, _, _) ← must (fillWith h1 (\w → planDiscovery env (hStore h1) (limitWork lim w)))
      case p1 of
        Planned _ → pure ()
        NoWork → pure ()
        other → expectationFailure ("at limit " <> show lim <> " the remaining discovery was " <> take 200 (show other))
  it "drains discovery through the protocol at every starting limit 1..64, under the standard bounds and under the tightest window the unit of discovery allows" $ do
    (_, r1) ← withScene
    -- the tightest window is the at-once bound of one connection inspection at the heights the scenario reaches
    (rFull, _) ← must (drain r1)
    let tight = discoveryTight (runH rFull)
    rows ← forM limits $ \lim → do
      (a, na) ← must (discoveryDrain standardBounds lim r1)
      (b, nb) ← must (discoveryDrain tight lim r1)
      pendingObligations (storeHeader (hStore (runH a))) `shouldBe` 0
      pendingObligations (storeHeader (hStore (runH b))) `shouldBe` 0
      must (checkH (runH a))
      must (checkH (runH b))
      pure (lim, na, nb, maximum (0 : map (mWindowPages . plMeasure) (runPlans b)))
    putStrLn ("PROTOCOL discovery: " <> show (length rows) <> " starting limits x 2 bounds (the tight window is " <> show (bdWindowPages tight) <> " pages); batches (standard, tight) at limits 1, 2, 3, 64: " <> show [(l, a, b) | (l, a, b, _) ← rows, l `elem` [1, 2, 3, 64]] <> "; total batches " <> show (sum [a + b | (_, a, b, _) ← rows]) <> "; the most pages a plan held in the tight window " <> show (maximum [m | (_, _, _, m) ← rows]) <> " of " <> show (bdWindowPages tight))
    -- the tight window is not slack for the unit: no plan held more than it allows, and the bound is reached
    (maximum [m | (_, _, _, m) ← rows] <= bdWindowPages tight) `shouldBe` True
  it "plans the smallest unit of discovery (one connection inspection) in a window of exactly its at-once bound, over deep trees, a free space with no tail and 16 pinned versions, from a starting limit of 3 and of 64" $ do
    (_, r1) ← withScene
    let preloadKeys = [runKey x y 10 | x ← [500 .. 560], y ← [0 .. 99]]
        chunks [] = []
        chunks xs = let (q, rest) = splitAt 40 xs in q : chunks rest
        preload h ks = do
          (h', out) ← commitDelta h Ordinary (deltaFor (hStore h) False False 1 [(k, Just (runRec 20)) | k ← ks])
          case out of
            Committed _ → Right h'
            other → Left ("preload: " <> show other)
    hLoaded ← must (foldM preload (runH r1) (chunks preloadKeys))
    hNoTail ← must (noTailWithOldLeaves TreeRuns 200 hLoaded)
    (hP, _) ← must (withPins (\i → (runKey (toInteger (500 + 3 * i)) (toInteger (7 * i)) 10, runRec 30)) 16 hNoTail)
    let hrec = recordHeight hP
        hf = heightOf hP TreeFree
        lim = discoveryUnitWindowPages (retireInternalsOf hP) hf hrec 16
        bounds = tightBounds lim
        env = runEnv r1
    forM_ [3, 64] $ \start → do
      (_, p, c) ← must (drive hP start (\hh w → planDiscoveryWith bounds env (hStore hh) w))
      case p of
        Planned pl → do
          (mWindowPages (plMeasure pl) <= lim) `shouldBe` True
          putStrLn ("PROTOCOL discovery at once: heights " <> show (hrec, hf, retireInternalsOf hP) <> ", 16 pinned, start " <> show start <> ", bound " <> show lim <> ", held " <> show (mWindowPages (plMeasure pl)) <> ", " <> show (cCheckpoints c) <> " checkpoints, " <> show (cReductions c) <> " reductions")
        other → expectationFailure ("start " <> show start <> ": " <> take 300 (show other))
  it "plans a standalone removal through the protocol at every starting limit 1..64 as it does with no limit (it is atomic and reads none)" $ do
    let run0 = newRun smallSpec sealedStack 64
        env = runEnv run0
        h = runH run0
        tile = tileAt 2 2 3
    (_, base, _) ← must (drive h 64 (\hh w → planRemovalWith standardBounds env (hStore hh) w tile))
    pages0 ← case base of
      Planned pl → pure (mPagesWritten (plMeasure pl))
      other → expectationFailure (show other) >> fail "base"
    forM_ limits $ \lim → do
      (_, a, _) ← must (drive h lim (\hh w → planRemovalWith standardBounds env (hStore hh) w tile))
      (_, b, _) ← must (drive h lim (\hh w → planRemovalWith (removalTight hh) env (hStore hh) w tile))
      forM_ [a, b] $ \p → case p of
        Planned pl → mPagesWritten (plMeasure pl) `shouldBe` pages0
        other → expectationFailure ("at limit " <> show lim <> " the removal was " <> take 200 (show other))
  it "drains maintenance through the protocol at every starting limit 1..64, under the standard bounds and under the tightest window a unit of one page allows" $ do
    (_, r1) ← withScene
    (rFull, _) ← must (drain r1)
    r2 ← must (foldM (\r (x, y, z) → removeCell r (tileAt x y z)) rFull openingB)
    (r3, _) ← must (drain r2)
    let h0 = runH r3
    rRetiredPages (storeRoots (hStore h0)) `shouldSatisfy` (> 0)
    rows ← forM limits $ \lim → do
      (a, na, _) ← must (maintenanceDrain (const standardBounds) lim h0)
      (b, nb, _) ← must (maintenanceDrain (const (maintenanceTight h0)) lim h0)
      rRetiredPages (storeRoots (hStore a)) `shouldBe` 0
      rRetiredPages (storeRoots (hStore b)) `shouldBe` 0
      pure (lim, na, nb)
    putStrLn ("PROTOCOL maintenance: " <> show (length rows) <> " starting limits x 2 bounds, " <> show (rRetiredPages (storeRoots (hStore h0))) <> " retired pages each; transactions (standard, tight) at limits 1, 2, 3, 64: " <> show [r | r@(l, _, _) ← rows, l `elem` [1, 2, 3, 64]] <> "; total " <> show (sum [a + b | (_, a, b) ← rows]))
  it "reclaims the oldest entry of the fragmented store (64 dispersed pages) through the protocol at the limits 1, 2, 3, 7, 8, 16, 33, 63 and 64, standard and tight" $ do
    let (hF, _, _) = fragmented
        retired0 = rRetiredPages (storeRoots (hStore hF))
        entryDone h = rRetiredPages (storeRoots (hStore h)) + 64 <= retired0
    rows ← forM [1, 2, 3, 7, 8, 16, 33, 63, 64] $ \lim → do
      (a, na, _) ← must (maintenanceUntil entryDone (const standardBounds) lim hF)
      (b, nb, _) ← must (maintenanceUntil entryDone (const (maintenanceTight hF)) lim hF)
      must (checkH a)
      must (checkH b)
      entryDone a `shouldBe` True
      entryDone b `shouldBe` True
      pure (lim, na, nb)
    putStrLn ("PROTOCOL fragmented entry: transactions (standard, tight) per starting limit " <> show rows)

-- ---------------------------------------------------------------------------
-- The read phase

-- | A store whose links tree is deep (the fillers) and holds two union-find chains of @hops@ links, one under each of the runs
-- [1,2) and [3,4) of the column (2,2): every link of a chain is a node of a distinct leaf. Removing the cell between the runs
-- joins them, and joining reads both chains one record at a time, each a lookup through the whole links tree.
chainStore ∷ Int → Int → Either String (H, Env, TileCoord)
chainStore hops fillers = do
  let run0 = newRun smallSpec sealedStack 64
      spacing = max 1 (fillers `div` (2 * hops + 2))
      node tag i = RunNode (columnAt (toInteger (10 + (2 * i + tag) * spacing)) 101) 0
      colRun lo = RunNode (columnAt 2 2) lo
      chain tag start = [(linkKey (if i == 0 then start else node tag i), if i == hops then rootRec 1 False else childRec (node tag (i + 1))) | i ← [0 .. hops]]
      runs = [(runKey 2 2 1, runRec 2), (runKey 2 2 3, runRec 4)]
      star = [(linkKey (RunNode (columnAt (toInteger x) 100) 0), if x == 0 then rootRec 1 False else childRec (RunNode (columnAt 0 100) 0)) | x ← [0 .. fillers - 1]]
      writes = [(k, Just v) | (k, v) ← runs ++ chain 0 (colRun 1) ++ chain 1 (colRun 3) ++ star]
      chunks [] = []
      chunks xs = let (a, b) = splitAt 60 xs in a : chunks b
  h ← foldM (\h ws → do
               (h', out) ← commitDelta h Ordinary (deltaFor (hStore h) False False 1 ws)
               case out of
                 Committed _ → Right h'
                 other → Left ("the chain store was not built: " <> show other)) (runH run0) (chunks writes)
  Right (h, runEnv run0, tileAt 2 2 2)

-- | The tightest bounds a removal and a discovery unit promise, at the heights of the store's own trees.
removalPromise ∷ H → Int
removalPromise h = removalWindowPages (retireInternalsOf h) (heightOf h TreeFree) (recordHeight h) 0

discoveryPromise ∷ H → Int
discoveryPromise h = discoveryUnitWindowPages (retireInternalsOf h) (heightOf h TreeFree) (recordHeight h) 0

cOf ∷ Driven → Counts
cOf = runCounts

-- | What one plan through the protocol did, and the plan: the outcome, the pages of the window it ended in, the largest window
-- a checkpoint was taken from (the read phase's peak), and the facts it carried.
data Driven = Driven {runPlan ∷ Plan, runCounts ∷ Counts}

runThrough ∷ H → Int → (H → Window → Planned) → Either String Driven
runThrough h limit planner = do
  (_, p, c) ← drive h limit planner
  case p of
    Planned plan → Right (Driven plan c)
    other → Left ("not planned: " <> take 200 (show other))

-- | The smallest window bound (in pages) a plan succeeds under through the protocol, by search, and the evidence that it is the
-- smallest: the plan succeeds at it and fails one page below it.
minimalBound ∷ H → (Bounds → H → Window → Planned) → Int → Either String Int
minimalBound h planner hi = go 1 hi
  where
    ok b = either (const False) (const True) (runThrough h 64 (planner (tightBounds b)))
    go lo up
      | not (ok up) = Left ("no success even at " <> show up <> " pages")
      | lo >= up = if up > 1 && ok (up - 1) then Left "not minimal" else Right up
      | otherwise = let mid = (lo + up) `div` 2 in if ok mid then go lo mid else go (mid + 1) up

samePlan ∷ Plan → Plan → Bool
samePlan a b = plPages a == plPages b && plNext a == plNext b && plEffects a == plEffects b


-- | A store after the removal of an opening, whose obligations are inspected through long chains: every union-find root the first
-- inspection reads is replaced by the head of a chain of @hops@ links, each in a leaf of its own, ending in the same root record.
chainedDiscovery ∷ Int → Int → Either String (H, Env)
chainedDiscovery hops fillers = do
  let run0 = newRun smallSpec twoOpenings 64
  r1 ← foldM (\r (x, y, z) → removeCell r (tileAt x y z)) run0 openingA
  let env = runEnv r1
      (_, ReadSet rs _) = stepDiscoveryTraced env (retainedHeader (runRef r1)) (retainedProvider (runRef r1)) (allowanceOf (envLimits env))
      -- the nodes it read as a root (a stored one, or the implicit one of a node with no record): each becomes the head of a chain
      -- ending in the root it had
      targets = [(node, root) | (KeyLink node, v) ← rs, Just root ← [case v of Just (RecRoot r) → Just r; Nothing → Just (Root 1 False); _ → Nothing]]
      n = max 1 (length targets)
      spacing = max 1 (fillers `div` (n * (hops + 1) + 2))
      cn i k = RunNode (columnAt (toInteger (10 + (k * n + i) * spacing)) 102) 0
      chainFor (i, (node, root)) = (KeyLink node, RecChild (cn i 1)) : [(KeyLink (cn i k), RecChild (cn i (k + 1))) | k ← [1 .. hops - 1]] ++ [(KeyLink (cn i hops), RecRoot root)]
      star = [(KeyLink (RunNode (columnAt (toInteger x) 100) 0), if x == 0 then rootRec 1 False else childRec (RunNode (columnAt 0 100) 0)) | x ← [0 .. fillers - 1]]
      writes = [(k, Just v) | (k, v) ← concatMap chainFor (zip [0 ..] targets) ++ star]
      chunks [] = []
      chunks xs = let (a, b) = splitAt 60 xs in a : chunks b
  if null targets then Left "the first inspection read no union-find root" else Right ()
  h ← foldM (\hh ws → do
               (h', out) ← commitDelta hh Ordinary (deltaFor (hStore hh) False False 1 ws)
               case out of
                 Committed _ → Right h'
                 other → Left ("the chained store was not built: " <> show other)) (runH r1) (chunks writes)
  Right (h, env)

-- | Every record of a store, for comparing two stores that were drained through different batches.
recordsOfStore ∷ H → Either String [(RecordKey, Record)]
recordsOfStore = storeRecords

-- | Discovery drained through the protocol, every batch committed: the store, the batches and what the caller did in all.
drainThrough ∷ H → Int → (H → Window → Planned) → Either String (H, Int, Counts)
drainThrough h0 limit planner = go h0 (0 ∷ Int) noCounts
  where
    go h n c
      | n > 400 = Left "discovery did not drain"
      | otherwise = do
          (h1, p, c') ← drive h limit planner
          case p of
            NoWork → Right (h1, n, addCounts c c')
            Planned plan → do
              h2 ← commitPlan h1 plan
              go h2 (n + 1) (addCounts c c')
            other → Left ("discovery answered " <> take 200 (show other))

readPhaseSpec ∷ Spec
readPhaseSpec = describe "the read phase: records are facts, a window never holds more than the plan's bounds, the edit starts from what it needs" $ do
  it "the bounds hold one whole read, fit the window and its bytes, and the residue is derived from them: at every height 1..8 and 0..16 pinned versions" $ do
    let hs = [1 .. maxLevel + 1]
        grid = [(hf, hrec, pins) | hf ← hs, hrec ← hs, pins ← [0 .. maxReaders]]
        bad p = [g | g@(hf, hrec, pins) ← grid, p hf hrec pins]
        oneRead hrec = readPathPages hrec
    -- every promised bound holds one whole logical-record read (or a retry could never make progress)
    bad (\hf hrec pins → removalWindowPages maxRetireInternals hf hrec pins < oneRead hrec || discoveryUnitWindowPages maxRetireInternals hf hrec pins < oneRead hrec) `shouldBe` []
    -- every promised bound fits the window's pages and bytes (the removal's proofs hold up to 'removalWorstProbes' probes)
    bad (\hf hrec pins → removalWindowPages maxRetireInternals hf hrec pins > maxWindowPages || removalWindowPages maxRetireInternals hf hrec pins * windowPageBytes + removalWorstProbes * probeBytes > maxWindowBytes) `shouldBe` []
    bad (\hf hrec pins → discoveryUnitWindowPages maxRetireInternals hf hrec pins * windowPageBytes + removalWorstProbes * probeBytes > maxWindowBytes) `shouldBe` []
    -- the residue is what the worst removal leaves free in the byte limit, and no more
    readResiduePages `shouldBe` 6
    -- the probe figures are counted from the pages written, in one place
    (removalWorstProbes, discoveryUnitWorstProbes) `shouldBe` (worstEditWrites * worstUpdatePages (maxLevel + 1) + 1 + bookkeepingReserve, discoveryUnitWrites * worstUpdatePages (maxLevel + 1) + 1 + bookkeepingReserve)
    (removalWorstProbes, discoveryUnitWorstProbes, minimumRemovalPages) `shouldBe` (188, 120, 188)
    ((removalWindowPages maxRetireInternals (maxLevel + 1) (maxLevel + 1) maxReaders) * windowPageBytes + removalWorstProbes * probeBytes <= maxWindowBytes) `shouldBe` True
    ((removalWindowPages maxRetireInternals (maxLevel + 1) (maxLevel + 1) maxReaders + 1) * windowPageBytes + removalWorstProbes * probeBytes > maxWindowBytes) `shouldBe` True
    -- the facts of the worst removal and of a discovery unit are RAM the feasibility proofs count, and they fit
    (worstEditReads * recordFactBytes <= maxReadFactBytes, worstEdgeReads * recordFactBytes <= maxReadFactBytes) `shouldBe` (True, True)
    putStrLn ("READPHASE bounds: residue " <> show readResiduePages <> " pages; promised removal at (8,8,16) = " <> show (removalWindowPages maxRetireInternals 8 8 16) <> ", discovery unit = " <> show (discoveryUnitWindowPages maxRetireInternals 8 8 16) <> ", one read at 8 levels = " <> show (readPathPages 8) <> "; facts: removal " <> show (worstEditReads * recordFactBytes) <> " B, discovery unit " <> show (worstEdgeReads * recordFactBytes) <> " B, ceiling " <> show maxReadFactBytes)
  it "removes the cell between two runs whose chains are 12 and 64 links long at EXACTLY the promised bound, and plans what the standard bounds plan" $ do
    forM_ [12, 64] $ \hops → do
      (h, env, tile) ← must (chainStore hops 8192)
      let promise = removalPromise h
          planner bounds hh w = planRemovalWith bounds env (hStore hh) w tile
      std ← must (runThrough h 64 (planner standardBounds))
      tight ← must (runThrough h 64 (planner (tightBounds promise)))
      free ← must (runThrough h 64 (planner unboundedReads))
      -- the same plan with checkpoints (at the tightest bound, at the standard bounds) and with none at all
      (samePlan (runPlan std) (runPlan tight), samePlan (runPlan free) (runPlan tight), cCheckpoints (cOf free)) `shouldBe` (True, True, 0)
      -- the window the plan ends in holds no more than the promise, and the read phase peaked at exactly the bound it ran under
      (mWindowPages (plMeasure (runPlan tight)) <= promise) `shouldBe` True
      (cReadPeak (cOf tight) <= promise) `shouldBe` True
      putStrLn ("READPHASE removal " <> show hops <> " hops: heights (records " <> show (recordHeight h) <> ", free " <> show (heightOf h TreeFree) <> "), promised " <> show promise <> ", read peak (tight " <> show (cReadPeak (cOf tight)) <> ", standard " <> show (cReadPeak (cOf std)) <> "), edit window " <> show (mWindowPages (plMeasure (runPlan tight))) <> ", checkpoints (tight " <> show (cCheckpoints (cOf tight)) <> ", standard " <> show (cCheckpoints (cOf std)) <> "), facts " <> show (cFacts (cOf tight)))
      -- the continuation was used: the reads do not fit the bound without it
      (cCheckpoints (cOf tight) > 0) `shouldBe` True
      -- how much of the promise the plan needs: the smallest bound it succeeds under, and one page less fails (the formula is an
      -- upper bound over every shape of tree and read; the edit phase of this fixture is far from it, the read phase is at it)
      bmin ← must (minimalBound h planner promise)
      putStrLn ("READPHASE removal " <> show hops <> " hops: smallest bound the plan succeeds under " <> show bmin <> " of the promised " <> show promise)
      (bmin <= promise, bmin >= readPathPages (recordHeight h)) `shouldBe` (True, True)
      -- the proof phase holds no more probes than the pages the removal writes, which 'removalWorstProbes' is derived from
      (cProbePeak (cOf tight) <= removalWorstProbes, cProbePeak (cOf std) <= removalWorstProbes) `shouldBe` (True, True)
      putStrLn ("READPHASE removal " <> show hops <> " hops: most probes a window held " <> show (cProbePeak (cOf tight)) <> " (tight), " <> show (cProbePeak (cOf std)) <> " (standard) of " <> show removalWorstProbes)
  it "a checkpoint is never taken with no new fact: a window that cannot hold one read is the typed window result, never a loop" $ do
    (h, env, tile) ← must (chainStore 12 8192)
    -- a bound of two pages cannot hold the three pages of one read of the links tree
    let tiny = tightBounds 2
        loop w n
          | n > (4000 ∷ Int) = expectationFailure "the plan did not settle" >> pure Nothing
          | otherwise = case planRemovalWith tiny env (hStore h) w tile of
              Pending p → case diskRead (hDisk h) p >>= \bs → either (const Nothing) Just (windowInsert (cfgUsablePages (hCfg h)) p bs w) of
                Just w' → loop w' (n + 1)
                Nothing → expectationFailure "page" >> pure Nothing
              Checkpoint fs → loop (windowCheckpoint fs w) (n + 1)
              Refused (Capacity c) → pure (Just c)
              other → expectationFailure (take 200 (show other)) >> pure Nothing
    r ← loop (storeWindow (hStore h)) 0
    r `shouldSatisfy` (\c → case c of Just (WindowExceeded _) → True; Just (WindowBytesExceeded _) → True; _ → False)
  it "discovers through chains of 40 links at EXACTLY the promised bound of a unit, and drains to the same records as the standard bounds" $ do
    (h, env) ← must (chainedDiscovery 40 8192)
    let promise = discoveryPromise h
        planner bounds hh w = planDiscoveryWith bounds env (hStore hh) w
    -- the unit (limit 3): the same plan at the tight bound as at the standard bounds
    std ← must (runThrough h 3 (planner standardBounds))
    free ← must (runThrough h 3 (planner unboundedReads))
    tight ← must (runThrough h 3 (planner (tightBounds promise)))
    -- with the checkpoint of the end of the read phase (standard bounds) and with none: the same plan. (A tight window may complete
    -- fewer inspections of a batch, since a batch is what the pages the window holds complete; its plan is compared by what it
    -- drains to, below)
    (samePlan (runPlan std) (runPlan free), cCheckpoints (cOf free)) `shouldBe` (True, 0)
    -- and a batch of up to 64 updates: with the end-of-read checkpoint and with none, the same plan
    std64 ← must (runThrough h 64 (planner standardBounds))
    free64 ← must (runThrough h 64 (planner unboundedReads))
    samePlan (runPlan std64) (runPlan free64) `shouldBe` True
    (mWindowPages (plMeasure (runPlan tight)) <= promise, cReadPeak (cOf tight) <= promise, cCheckpoints (cOf tight) > 0) `shouldBe` (True, True, True)
    bminD ← must (minimalBound h planner promise)
    putStrLn ("READPHASE discovery unit: smallest bound the plan succeeds under " <> show bminD <> " of the promised " <> show promise)
    (bminD <= promise, bminD >= readPathPages (recordHeight h)) `shouldBe` (True, True)
    (cProbePeak (cOf tight) <= discoveryUnitWorstProbes, cProbePeak (cOf std) <= discoveryUnitWorstProbes) `shouldBe` (True, True)
    putStrLn ("READPHASE discovery unit: most probes a window held " <> show (cProbePeak (cOf tight)) <> " (tight), " <> show (cProbePeak (cOf std)) <> " (standard) of " <> show discoveryUnitWorstProbes)
    -- a 64-update batch: the batch is whatever the pages the window holds complete, so only the end state is the same: drained
    -- through tight and through standard bounds, the stores hold the same records
    (hStd, nStd, cStd) ← must (drainThrough h 64 (planner standardBounds))
    (hTight, nTight, cTight) ← must (drainThrough h 64 (planner (tightBounds promise)))
    recStd ← must (recordsOfStore hStd)
    recTight ← must (recordsOfStore hTight)
    recTight `shouldBe` recStd
    pendingObligations (storeHeader (hStore hStd)) `shouldBe` 0
    pendingObligations (storeHeader (hStore hTight)) `shouldBe` 0
    putStrLn ("READPHASE discovery 40 links: promised " <> show promise <> ", unit: read peak " <> show (cReadPeak (cOf tight)) <> ", edit window " <> show (mWindowPages (plMeasure (runPlan tight))) <> ", checkpoints " <> show (cCheckpoints (cOf tight)) <> ", facts " <> show (cFacts (cOf tight)) <> "; drained: standard " <> show nStd <> " batches / " <> show (cCheckpoints cStd) <> " checkpoints, tight " <> show nTight <> " batches / " <> show (cCheckpoints cTight) <> " checkpoints")
  it "counts the read facts a plan holds in its RAM, and the feasibility proofs count the most a removal and a discovery unit read" $ do
    (h, env, tile) ← must (chainStore 64 8192)
    pl ← must (runThrough h 64 (\hh w → planRemovalWith (tightBounds (removalPromise h)) env (hStore hh) w tile))
    -- the plan was made through windows that carried facts: its continuation charge holds them
    (ramContinuation (mRam (plMeasure (runPlan pl))) >= cFacts (cOf pl) * recordFactBytes) `shouldBe` True
    -- the supported minimum removal and the smallest unit of discovery, with the facts of their most reads, fit the RAM bound
    (minimumRemovalRam <= txnRamLimit, minimumDiscoveryUnitRam <= txnRamLimit) `shouldBe` (True, True)
    putStrLn ("READPHASE RAM: facts held " <> show (cFacts (cOf pl)) <> " x " <> show recordFactBytes <> " B; minimum removal " <> show minimumRemovalRam <> " B, discovery unit " <> show minimumDiscoveryUnitRam <> " B of " <> show txnRamLimit)
  it "facts are for one state only: facts a plan took are ignored by a plan at another version, which plans what a clean window plans" $ do
    (h, env, tile) ← must (chainStore 12 8192)
    let planner bounds hh w = planRemovalWith bounds env (hStore hh) w tile
        firstCheckpoint w n
          | n > (4000 ∷ Int) = expectationFailure "no checkpoint" >> fail "cp"
          | otherwise = case planner standardBounds h w of
              Pending p → case diskRead (hDisk h) p >>= \bs → either (const Nothing) Just (windowInsert (cfgUsablePages (hCfg h)) p bs w) of
                Just w' → firstCheckpoint w' (n + 1)
                Nothing → expectationFailure "page" >> fail "page"
              Checkpoint fs → pure fs
              other → expectationFailure ("no checkpoint: " <> take 200 (show other)) >> fail "cp"
    facts ← firstCheckpoint (storeWindow (hStore h)) 0
    -- the committed state changes under the facts: the end of the first chain gets another root record
    let endOfChain = linkKey (RunNode (columnAt (toInteger (10 + (2 * 12 + 0) * max 1 (8192 `div` (2 * 12 + 2)) ∷ Int)) 101) 0)
    (h2, out) ← must (commitDelta h Ordinary (deltaFor (hStore h) False False 1 [(endOfChain, Just (rootRec 5 True))]))
    case out of
      Committed _ → pure ()
      other → expectationFailure ("the change was not committed: " <> show other)
    old ← must (runThrough h 64 (planner standardBounds))
    clean ← must (runThrough h2 64 (planner standardBounds))
    (_, stale, _) ← must (driveFrom h2 (windowCheckpoint facts (storeWindow (hStore h2))) (planner standardBounds))
    -- the change matters (the plans differ), and the stale facts did not carry the old state into the new plan
    samePlan (runPlan old) (runPlan clean) `shouldBe` False
    case stale of
      Planned pl → samePlan pl (runPlan clean) `shouldBe` True
      other → expectationFailure ("the stale-facts window did not plan: " <> take 200 (show other))
  it "funds the ACTUAL credits of a removal, of a discovery unit and of a 64-update batch against the tightest configuration mkEditBankConfig accepts" $ do
    (h, env, tile) ← must (chainStore 64 8192)
    removal ← must (runThrough h 64 (\hh w → planRemovalWith standardBounds env (hStore hh) w tile))
    (hd, envd) ← must (chainedDiscovery 40 8192)
    unit ← must (runThrough hd 3 (\hh w → planDiscoveryWith standardBounds envd (hStore hh) w))
    batch ← must (runThrough hd 64 (\hh w → planDiscoveryWith standardBounds envd (hStore hh) w))
    let plans = [("removal", runPlan removal), ("discovery unit", runPlan unit), ("64-update batch", runPlan batch)]
        accepted sp = either (const False) (const True) (mkEditBankConfig sp)
        smallest ok = go 1 (2 ^ (30 ∷ Int))
          where
            go lo hi
              | lo >= hi = hi
              | ok mid = go lo mid
              | otherwise = go (mid + 1) hi
              where
                mid = (lo + hi) `div` 2
        tightest arenas readers = do
          let base = defaultEditBankSpec {ebsArenas = arenas, ebsReadersPerArena = readers, ebsEditBank = 2 ^ (36 ∷ Int)}
              control = smallest (\c → accepted base {ebsControl = c})
              staging = smallest (\p → accepted base {ebsStaging = p, ebsProtectedStaging = p})
              cache = smallest (\c → accepted base {ebsCache = c})
              tightSpec = base {ebsControl = control, ebsStaging = staging, ebsProtectedStaging = staging, ebsCache = cache, ebsEditBank = control + staging + cache}
          -- tight: each account one byte lower is refused
          accepted tightSpec `shouldBe` True
          [accepted tightSpec {ebsControl = control - 1, ebsEditBank = ebsEditBank tightSpec - 1}, accepted tightSpec {ebsStaging = staging - 1, ebsProtectedStaging = staging - 1, ebsEditBank = ebsEditBank tightSpec - 1}, accepted tightSpec {ebsCache = cache - 1, ebsEditBank = ebsEditBank tightSpec - 1}] `shouldBe` [False, False, False]
          cfg ← either (\e → expectationFailure (show e) >> fail "config") pure (mkEditBankConfig tightSpec)
          -- every actual plan is funded from fresh accounts: never refused as a credit no account could ever hold
          forM_ plans $ \(name, plan) →
            case reserve Foreground (transactionCredits (ArenaId 1) (mRam (plMeasure plan))) (newAdmission cfg) of
              Right _ → pure ()
              Left why → expectationFailure (name <> " was not funded by the tightest accepted configuration (" <> show arenas <> " arenas, " <> show readers <> " readers): " <> show why)
          pure (control, staging, cache)
    (c1, s1, ch1) ← tightest 1 1
    (c2, s2, ch2) ← tightest 4 (toInteger maxReaders)
    -- the default configuration holds the control account the worst case needs
    (c2 <= ebsControl defaultEditBankSpec, c1 <= c2) `shouldBe` (True, True)
    putStrLn ("READPHASE funding: tightest accepted (control, protected staging, cache) at 1x1 = " <> show (c1, s1, ch1) <> ", at 4x" <> show maxReaders <> " = " <> show (c2, s2, ch2) <> "; default control " <> show (ebsControl defaultEditBankSpec) <> "; credits of the actual plans " <> show [(n, transactionCredits (ArenaId 1) (mRam (plMeasure p))) | (n, p) ← plans])
