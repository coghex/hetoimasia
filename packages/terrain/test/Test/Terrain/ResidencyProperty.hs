-- | Randomized event sequences against the structural properties of the
-- residency model.
--
-- A sequence is a list of small integers. Each is read against the model's
-- current state, so most events are valid (they name a live arena, a running
-- job, a resident region) and some are deliberately wrong (an unknown job, a
-- stale revision), which exercises the refusals as much as the transitions.
-- After every event, accepted or refused, the properties below are checked
-- against figures recomputed from the model's observable records, not from the
-- model's own totals:
--
-- * a refusal returns the model it was given;
-- * every bank's occupied plus reserved bytes stay within its limit and every
--   slot within its count, and the ledgers equal the records' charges;
-- * the structural invariants hold (nothing is evicted while in use, funding
--   matches the victims awaited, no hold protects a missing region);
-- * a live arena's retained edit bytes never decrease;
-- * a changed region stays resident until its handoff is confirmed or its arena
--   is released.
--
-- No example here sleeps, starts a thread or reads a clock.
module Test.Terrain.ResidencyProperty (spec) where

import Data.Maybe (fromMaybe, listToMaybe)
import Hetoimasia.Terrain.Coordinate (tileCoord)
import Hetoimasia.Terrain.Residency
import Test.Hspec
import Test.QuickCheck
import Test.Terrain.ResidencySupport

-- | Tight enough that every kind of pressure occurs within a few events.
pressure ∷ Limits
pressure =
  limitsWith $ \s →
    s
      { specResidentBytes = 800
      , specEditBytes = 192
      , specStagingBytes = 3000
      , specLoadJobs = 4
      , specQueuedCommands = 4
      , specPinsPerView = 2
      , specDemandRegions = 3
      , specAgingQuanta = 2
      }

pick ∷ [a] → Int → Maybe a
pick [] _ = Nothing
pick xs i = Just (xs !! (i `mod` length xs))

-- | The small universe of regions the sequences draw from: x in 0..2, z in 0..1.
regions ∷ [(Integer, Integer)]
regions = [(x, z) | x ← [0 .. 2], z ← [0, 1]]

coverages ∷ [Coverage]
coverages = [cell 0 0 0, cell 0 0 5, box 0 1 0 1 0 3]

demandFor ∷ Int → Int → RegionDemand
demandFor i j =
  let (x, z) = fromMaybe (0, 0) (pick regions i)
      c = fromMaybe (cell 0 0 0) (pick coverages j)
   in demand (reg x 0 z) c

-- | Read three small integers against the model's state as the next event.
eventFor ∷ Model → (Int, Int, Int) → Event
eventFor m (k, a, b) = case k `mod` 22 of
  0 → OpenArena (ArenaId (modelClock m + 1)) (Revision 0)
  1 → SubmitQuery fresh arena (revisionOf arena) [demandFor a b, demandFor (a + b) (a + 1)]
  2 → SubmitQuery fresh arena (revisionOf arena) [demandFor a b]
  3 → SubmitRemoval fresh arena (revisionOf arena) (tileFor a b)
  4 → SetCameraDemand (ViewId (fromIntegral (a `mod` 2))) arena [demandFor b a, demandFor (b + 1) (a + 2)]
  5 → ClearCameraDemand (ViewId (fromIntegral (a `mod` 2)))
  6 → Withdraw (maybe fresh requestId (pick (modelRequests m) a))
  7 → Service
  8 → Dispatch
  9 → Dispatch
  10 → Dispatch
  11 → maybe (JobCompleted (JobId 99) (Cost 0 0 0)) completion (pick (running JobRunningPhase) a)
  12 → maybe (JobCompleted (JobId 99) (Cost 0 0 0)) completion (pick (running JobRunningPhase) a)
  13 → maybe (JobFailed (JobId 98)) (JobFailed . jobId) (pick (running JobRunningPhase) a)
  14 → maybe (JobAcknowledged (JobId 97)) (JobAcknowledged . jobId) (pick (running JobCancellingPhase) a)
  15 → case pick [r | r ← modelRequests m, requestRemoval r] a of
    Just r → RemovalCommitted (requestId r) (Revision (revisionNumber (requestArena r) + 1)) (fromIntegral (b `mod` 66)) (fromIntegral (b `mod` 63))
    Nothing → RemovalCommitted (RequestId 99) (Revision 1) 0 0
  16 → case pick (resident (const True)) a of
    Just r → AcquireHold (HoldId (modelClock m + 1)) (regionArena r) (if even b then Borrow else Pin (ViewId (fromIntegral (b `mod` 2)))) [regionCoord r]
    Nothing → ReleaseHold (HoldId 99)
  17 → maybe (ReleaseHold (HoldId 99)) (\(h, _, _, _) → ReleaseHold h) (pick (modelHolds m) a)
  18 → case pick (resident regionDirty) a of
    Just r
      | even b → BeginHandoff (regionArena r) (regionCoord r) (fromIntegral (b `mod` 40))
      | otherwise → if even a then HandoffConfirmed (regionArena r) (regionCoord r) else HandoffFailed (regionArena r) (regionCoord r)
    Nothing → HandoffConfirmed (ArenaId 99) (reg 0 0 0)
  19 → case pick (resident regionEvicting) a of
    Just r → VictimReleased (regionArena r) (regionCoord r)
    Nothing → VictimReleased (ArenaId 99) (reg 0 0 0)
  20 → maybe (RetireArena (ArenaId 99)) (RetireArena . arenaId) (pick (modelArenas m) a)
  _ → SubmitQuery fresh (ArenaId 99) rev0 [demandFor a b]
  where
    fresh = RequestId (modelClock m + 1)
    arena = maybe (ArenaId 1) arenaId (pick [x | x ← modelArenas m, arenaPhase x == ArenaLive] a)
    revisionNumber a' = case [r | x ← modelArenas m, arenaId x == a', let Revision r = arenaRevision x] of
      (r : _) → r
      [] → 0
    revisionOf a' = case [arenaRevision x | x ← modelArenas m, arenaId x == a'] of
      (r : _) → if b `mod` 11 == 0 then Revision 12345 else r
      [] → rev0
    tileFor i j =
      let (x, z) = fromMaybe (0, 0) (pick regions i)
       in either (error . show) id (tileCoord (x * 16 + toInteger (j `mod` 16)) 0 (z * 32 + toInteger (j `mod` 32)))
    running phase = [j | j ← modelJobs m, jobPhase j == phase]
    resident p = [r | r ← modelRegions m, p r]
    completion j =
      let c = jobCoverage j
       in JobCompleted (jobId j) (Cost 0 (coverageSegments c) (coverageCells c))

-- | The properties after one event; 'Nothing' means all hold.
check ∷ Model → Model → Either Refusal Report → Maybe String
check prior latest result = case result of
  Left _
    | latest /= prior → Just "a refusal changed the model"
  _ →
    firstJust
      [ if null (modelInvariants latest) then Nothing else Just ("invariants: " <> show (modelInvariants latest))
      , if ledgersOf latest == independentLedgers latest then Nothing else Just "ledgers disagree with records"
      , listToMaybe
          [ show b <> " over its limit"
          | b ← allBanks
          , let l = bankLedger latest b
          , ledgerOccupied l + ledgerReserved l > ledgerLimit l
          ]
      , listToMaybe
          [ "retained edits of " <> show (arenaId old) <> " decreased"
          | old ← modelArenas prior
          , new ← modelArenas latest
          , arenaId old == arenaId new
          , arenaRetainedBytes new < arenaRetainedBytes old
          ]
      , listToMaybe
          [ "changed region " <> show (regionCoord r) <> " lost without a handoff"
          | r ← modelRegions prior
          , regionDirty r
          , arenaId' ← [regionArena r]
          , arenaId' `elem` map arenaId (modelArenas latest)
          , null [() | r' ← modelRegions latest, regionArena r' == regionArena r, regionCoord r' == regionCoord r, not (regionEvicting r')]
          ]
      ]
  where
    firstJust = listToMaybe . concatMap (maybe [] pure)

-- | Run a sequence; return the first failure and the event that caused it.
runSequence ∷ [(Int, Int, Int)] → (Either String Model, Stats)
runSequence seeds = go (newModel pressure) seeds (Stats 0 0 0 0 0 0)
  where
    go m [] st = (Right m, st)
    go m (s : rest) st =
      let event = eventFor m s
          (m', result) = step m event
       in case check m m' result of
            Just why → (Left (why <> " after " <> show event), st)
            Nothing → go m' rest (tally event result st)

data Stats = Stats
  { accepted ∷ !Int
  , refused ∷ !Int
  , completed ∷ !Int
  , victims ∷ !Int
  , committed ∷ !Int
  , retired ∷ !Int
  }
  deriving stock (Eq, Show)

tally ∷ Event → Either Refusal Report → Stats → Stats
tally _ (Left _) st = st {refused = refused st + 1}
tally _ (Right report) st =
  let st' = st {accepted = accepted st + 1, retired = retired st + length (reportSettled report)}
   in case reportDecision report of
        Published _ _ → st' {completed = completed st' + 1}
        Accepted a → st' {victims = victims st' + length (admissionVictims a)}
        Committed {} → st' {committed = committed st' + 1}
        _ → st'

-- | A fixed pseudo-random sequence (a linear congruential generator).
lcg ∷ Int → Int → [(Int, Int, Int)]
lcg seed n = take n (triples (drop 1 (iterate next seed)))
  where
    next x = (x * 1103515245 + 12345) `mod` 2147483648
    triples (x : y : z : rest) = (x `div` 65536, y `div` 65536, z `div` 65536) : triples rest
    triples _ = []

spec ∷ Spec
spec = describe "Residency model properties" $ do
  it "holds its invariants over random sequences" $
    withNumTests 200 $
      forAll (vectorOf 250 ((,,) <$> chooseInt (0, 1000) <*> chooseInt (0, 1000) <*> chooseInt (0, 1000))) $ \seeds →
        case runSequence seeds of
          (Left why, _) → counterexample why False
          (Right _, _) → property True
  it "exercises completion, eviction, commit, refusal and retirement in a fixed long sequence" $ do
    let (outcome, stats) = runSequence (lcg 7 30000)
    outcome `shouldSatisfy` either (const False) (const True)
    -- Guards against a degenerate workload: the sequence must reach the
    -- transitions the properties are about.
    accepted stats `shouldSatisfy` (> 2000)
    refused stats `shouldSatisfy` (> 1000)
    completed stats `shouldSatisfy` (> 200)
    victims stats `shouldSatisfy` (> 20)
    committed stats `shouldSatisfy` (> 10)
    retired stats `shouldSatisfy` (> 3)
