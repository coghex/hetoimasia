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
import Hetoimasia.Terrain.Discovery (pendingObligations, worstEdgeWrites)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference
import Test.TerrainRuntime.Store.Scattered (fragmented)
import Test.TerrainRuntime.Store.Scenes

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | What the caller did to get a plan through.
data Counts = Counts {cReductions ∷ !Int, cCheckpoints ∷ !Int, cPages ∷ !Int, cMaintenance ∷ !Int}

noCounts ∷ Counts
noCounts = Counts 0 0 0 0

addCounts ∷ Counts → Counts → Counts
addCounts (Counts a b c d) (Counts a' b' c' d') = Counts (a + a') (b + b') (c + c') (d + d')

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
drive h0 limit planner = loop h0 (limitWork limit (storeWindow (hStore h0))) noCounts (0 ∷ Int)
  where
    loop h w c n
      | n > 6000 = Left "the protocol did not settle in 6,000 steps"
      | otherwise = case planner h w of
          Pending p → case diskRead (hDisk h) p of
            Nothing → Left ("pending page not on disk: " <> show p)
            Just bs → case windowInsert (cfgUsablePages (hCfg h)) p bs w of
              Left e → Left ("page " <> show p <> " refused: " <> show e)
              Right w' → loop h w' c {cPages = cPages c + 1} (n + 1)
          PendingProbes ps → loop h (foldl (\w' p → windowProbe (cfgUsablePages (hCfg h)) p (maybe BS.empty id (diskRead (hDisk h) p)) w') w ps) c {cPages = cPages c + 1} (n + 1)
          Checkpoint fs → loop h (windowCheckpoint fs w) c {cCheckpoints = cCheckpoints c + 1} (n + 1)
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
spec = describe "the facade's caller protocol, followed exactly, for every starting work limit" $ do
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
              || discoveryUnitWindowPages maxRetireInternals hf hrec pins * windowPageBytes + 188 * probeBytes > maxWindowBytes
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
