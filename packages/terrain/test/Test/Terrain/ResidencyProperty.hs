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
--   is released;
-- * the owner can always do what the model has asked of it: every running job
--   can report completion or failure, every cancelling job can be acknowledged,
--   every committed victim released, every handoff settled, every hold released
--   and every request and camera demand withdrawn, each accepted by the model;
-- * doing all of that, from any reachable state, leaves nothing reserved, no job,
--   no victim, no hold and no retiring arena behind.
--
-- No example here sleeps, starts a thread or reads a clock.
module Test.Terrain.ResidencyProperty (spec) where

import Control.Monad (forM_, unless)
import Data.Maybe (fromMaybe, listToMaybe)
import Hetoimasia.Terrain.Coordinate (decomposeTile, tileCoord)
import Hetoimasia.Terrain.Residency
import Test.Hspec
import Test.QuickCheck
import Test.Terrain.ResidencyOracle (Verdict (..), oracle)
import Test.Terrain.ResidencySupport

-- | Tight enough that every kind of pressure occurs within a few events: the
-- smallest resident bank its caps allow is 4,384 bytes (two regions, each at its
-- stored maximum of 760 bytes plus a job of 672, and two held regions at 760), and the extent is two columns, one row and six levels.
pressure ∷ Limits
pressure =
  limitsWith $ \s →
    s
      { specResidentBytes = 5000
      , specEditBytes = 640
      , specStagingBytes = 3000
      , specLoadJobs = 4
      , specQueuedCommands = 4
      , specPinsPerView = 2
      
      , specAgingQuanta = 2
      , specQueryRegions = 2
      , specExtentX = 2
      , specExtentY = 1
      , specExtentZ = 6
      , specHoldRegions = 2
      , specCameraRegions = 64
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
  6 → if b `mod` 4 == 0 then Withdraw (maybe fresh requestId (pick (modelRequests m) a)) else advanceEdit
  7 → Service
  8 → Dispatch
  9 → Dispatch
  10 → Dispatch
  11 → maybe (JobCompleted (JobId 99) (Cost 0 0 0)) completion (pick (editJobsFirst (running JobRunningPhase)) a)
  12 → maybe (JobCompleted (JobId 99) (Cost 0 0 0)) completion (pick (editJobsFirst (running JobRunningPhase)) a)
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
  -- Arenas end rarely, so long-lived arenas see the commits, replacements and
  -- acknowledgements the properties are about.
  20 → if b `mod` 6 == 0 then maybe (RetireArena (ArenaId 99)) (RetireArena . arenaId) (pick (modelArenas m) a) else Dispatch
  _ → case pick [r | r ← modelRequests m, requestRemoval r] a of
    Just r → RemovalCommitted (requestId r) (Revision (revisionNumber (requestArena r) + 1)) (fromIntegral (b `mod` 66)) (fromIntegral (b `mod` 63))
    Nothing → SubmitRemoval fresh arena (revisionOf arena) (tileFor a b)
  where
    fresh = RequestId (modelClock m + 1)
    arena = maybe (ArenaId 1) arenaId (pick [x | x ← modelArenas m, arenaPhase x == ArenaLive] a)
    revisionNumber a' = case [r | x ← modelArenas m, arenaId x == a', let Revision r = arenaRevision x] of
      (r : _) → r
      [] → 0
    revisionNumberOf a' = Revision (revisionNumber a')
    revisionOf a' = case [arenaRevision x | x ← modelArenas m, arenaId x == a'] of
      (r : _) → if b `mod` 11 == 0 then Revision 12345 else r
      [] → rev0
    -- The cells the demands also name, so removals meet the work of the region.
    tileFor i j =
      let (x, z) = fromMaybe (0, 0) (pick regions i)
       in either (error . show) id (tileCoord (x * 16 + toInteger (j `mod` 2)) 0 (z * 32 + fromMaybe 0 (pick [0, 5, 1, 2] j)))
    running phase = [j | j ← modelJobs m, jobPhase j == phase]
    -- Take one removal a step toward its commit: finish the running job of its
    -- region, or dispatch, or (nothing left to wait for) commit it. The interleaving
    -- with every other event is still the random one.
    advanceEdit = case pick [r | r ← modelRequests m, requestRemoval r] a of
      Nothing → Dispatch
      Just r
        -- Sometimes put competing work in the removal's own region first, so a later
        -- commit finds other jobs there to supersede.
        | b `mod` 2 == 1
        , (region : _) ← requestRegions r →
            SubmitQuery fresh (requestArena r) (revisionNumberOf (requestArena r)) [RegionDemand region (fromMaybe (cell 0 0 3) (pick demandCoverages a))]
        | otherwise →
            let regionJobs = [j | j ← modelJobs m, (jobArena j, jobRegion j) `elem` [(requestArena r, g) | g ← requestRegions r]]
                own = [j | j ← regionJobs, Just c ← [requestRemovalCell r], coverageIntersects (jobCoverage j) c]
             in case ([j | j ← own, jobPhase j == JobRunningPhase], [j | j ← own, jobPhase j == JobQueued]) of
                  -- Finish the removal's own job (and only that one), then commit with
                  -- the region's other work still queued or running.
                  (j : _, _) → completion j
                  (_, _ : _) → Dispatch
                  _ → RemovalCommitted (requestId r) (Revision (revisionNumber (requestArena r) + 1)) (fromIntegral (b `mod` 66)) (fromIntegral (b `mod` 63))
    resident p = [r | r ← modelRegions m, p r]
    -- A removal's own job comes first (the cell it is waiting on), so removals get
    -- to commit while competing work of their region is still queued or running.
    editJobsFirst js =
      let ownCells = [(requestArena r, g, c) | r ← modelRequests m, requestRemoval r, g ← requestRegions r, Just c ← [requestRemovalCell r]]
          isOwn j = or [(jobArena j, jobRegion j) == (ar, g) && coverageIntersects (jobCoverage j) c | (ar, g, c) ← ownCells]
          (first, rest) = (filter isOwn js, filter (not . isOwn) js)
       in if null first then rest else first
    completion j = JobCompleted (jobId j) (honestCost m j)

-- | For an explicit query or removal that is otherwise well formed, the class the
-- brute-force oracle says the answer must be, and the class the model gave.
oracleClasses ∷ Model → Event → Either Refusal Report → Maybe (Verdict, Verdict)
oracleClasses prior event result = do
  (rid, arena, rev, demands, removal) ← case event of
    SubmitQuery r a v ds → Just (r, a, v, ds, False)
    SubmitRemoval r a v tile → let (region, local) = decomposeTile tile in Just (r, a, v, [RegionDemand region (coverageTile local)], True)
    _ → Nothing
  info ← listToMaybe [x | x ← modelArenas prior, arenaId x == arena, arenaPhase x == ArenaLive]
  if arenaRevision info == rev && rid `notElem` [requestId r | r ← modelRequests prior] then Just () else Nothing
  if not (null demands) && length demands <= 2 && distinct (map demandRegion demands) then Just () else Nothing
  got ← case result of
    Right _ → Just Admit
    Left (Busy _) → Just NotNow
    Left (Invalid _) → Just Never
    Left (RetainedEditsExhausted {}) → Just Exhausted
    Left _ → Nothing
  Just (oracle prior arena demands removal, got)
  where
    distinct xs = length xs == length (foldr (\x acc → if x `elem` acc then acc else x : acc) [] xs)

-- | The properties after one event; 'Nothing' means all hold.
check ∷ Event → Model → Model → Either Refusal Report → Maybe String
check event prior latest result = case result of
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
      , ownerCanSettle latest
      , case oracleClasses prior event result of
          Just (expected, got) | expected /= got → Just ("the model answered " <> show got <> " where the brute-force oracle says " <> show expected <> " for " <> show event)
          _ → Nothing
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

-- | What the owner would do to carry out everything the model has asked of it,
-- each as an event.
ownerActions ∷ Model → [Event]
ownerActions m =
  [JobCompleted (jobId j) (Cost 0 0 0) | j ← modelJobs m, jobPhase j `elem` [JobRunningPhase, JobCancellingPhase]]
    <> [Dispatch | any ((== JobQueued) . jobPhase) (modelJobs m)]
    <> [VictimReleased (regionArena r) (regionCoord r) | r ← modelRegions m, regionEvicting r]
    <> [HandoffConfirmed (regionArena r) (regionCoord r) | r ← modelRegions m, Just _ ← [regionHandoff r]]
    <> [ReleaseHold h | (h, _, _, _) ← modelHolds m]
    <> [Withdraw (requestId r) | r ← modelRequests m]
    <> [ClearCameraDemand (viewId v) | v ← modelViews m]

-- | Every action the owner might be asked to take is accepted by the model.
ownerCanSettle ∷ Model → Maybe String
ownerCanSettle m =
  listToMaybe
    [ "the owner's " <> show ev <> " was refused: " <> show r
    | ev ← ownerActions m <> alternatives
    , (_, Left r) ← [step m ev]
    ]
  where
    alternatives =
      [JobFailed (jobId j) | j ← modelJobs m, jobPhase j == JobRunningPhase]
        <> [JobAcknowledged (jobId j) | j ← modelJobs m, jobPhase j == JobCancellingPhase]
        <> [HandoffFailed (regionArena r) (regionCoord r) | r ← modelRegions m, Just _ ← [regionHandoff r]]

-- | Carry out every action in turn until none remains; the result is nothing
-- reserved, no job, victim, hold or retiring arena.
settleEverything ∷ Model → Either String Model
settleEverything = settleWith True

-- | The same, optionally leaving the cameras' demands (and so their interests and
-- descriptions) in place: everything else the owner can release is released.
settleWith ∷ Bool → Model → Either String Model
settleWith clearViews = go (500 ∷ Int)
  where
    go 0 _ = Left "the owner's actions did not settle the model"
    go n m = case filter keep (ownerActions m) of
      [] → leftovers m
      (ev : _) → case step m ev of
        (m', Right _) → go (n - 1) m'
        (_, Left r) → Left ("the owner's " <> show ev <> " was refused: " <> show r)
    keep ev = clearViews || case ev of ClearCameraDemand _ → False; _ → True
    leftovers m =
      case concat
        [ ["a job remains: " <> show j | j ← modelJobs m]
        , ["a bank still reserves bytes: " <> show b <> " " <> show (bankLedger m b) | b ← allBanks, ledgerReserved (bankLedger m b) /= 0]
        , ["staging still occupied: " <> show (bankLedger m StagingBank) | clearViews, ledgerOccupied (bankLedger m StagingBank) /= 0]
        , ["a victim remains: " <> show (regionCoord r) | r ← modelRegions m, regionEvicting r]
        , ["an arena is still retiring: " <> show (arenaId a) | a ← modelArenas m, arenaPhase a == ArenaRetiringPhase]
        ] of
        [] → Right m
        (problem : _) → Left problem

-- | Run a sequence; return the first failure and the event that caused it.
runSequence ∷ [(Int, Int, Int)] → (Either String Model, Stats)
runSequence = runSequenceWith pressure

-- | The same sequences under room for more concurrent work, where commits meet
-- queued and running jobs of their region far more often.
roomyPressure ∷ Limits
roomyPressure =
  limitsWith $ \s →
    s
      { specResidentBytes = 9000
      , specEditBytes = 2048
      , specStagingBytes = 12000
      , specLoadJobs = 8
      , specQueuedCommands = 8
      , specPinsPerView = 2
      
      , specAgingQuanta = 2
      , specQueryRegions = 2
      , specExtentX = 2
      , specExtentY = 1
      , specExtentZ = 6
      , specHoldRegions = 2
      , specCameraRegions = 64
      }

-- | The pressure configuration with its resident and staging banks as given, which must
-- meet the minimum budgets (4,384 and 1,530 here: the explicit reserve plus a camera
-- share that holds one camera unit).
limitsNear ∷ Integer → Integer → Maybe Limits
limitsNear resident staging =
  either (const Nothing) Just . mkLimits $
    LimitsSpec
      { specResidentBytes = resident
      , specEditBytes = 640
      , specStagingBytes = staging
      , specLoadJobs = 4
      , specQueuedCommands = 4
      , specPinsPerView = 2
      , specAgingQuanta = 2
      , specQueryRegions = 2
      , specExtentX = 2
      , specExtentY = 1
      , specExtentZ = 6
      , specHoldRegions = 2
      , specCameraRegions = 64
      }

runSequenceWith ∷ Limits → [(Int, Int, Int)] → (Either String Model, Stats)
runSequenceWith limits seeds = go (newModel limits) seeds (Stats 0 0 0 0 0 0 0 0 0 0 0 0)
  where
    go m [] st = (settleEverything m, st)
    go m (s : rest) st =
      let event = eventFor m s
          (m', result) = step m event
       in case check event m m' result of
            Just why → (Left (why <> " after " <> show event), st)
            Nothing → go m' rest (tally m event result st)

data Stats = Stats
  { accepted ∷ !Int
  , refused ∷ !Int
  , completed ∷ !Int
  , victims ∷ !Int
  , committed ∷ !Int
  , retired ∷ !Int
  , -- | Commits that superseded queued or running work of their region.
    superseded ∷ !Int
  , -- | Cancellation acknowledgements the model accepted.
    acknowledged ∷ !Int
  , -- | Camera replacements that cancelled or dropped obsolete work.
    replaced ∷ !Int
  , -- | Decisions the brute-force oracle checked, by the class it expected.
    oracleAdmit ∷ !Int
  , oracleNotNow ∷ !Int
  , oracleExhausted ∷ !Int
  }
  deriving stock (Eq, Show)

tally ∷ Model → Event → Either Refusal Report → Stats → Stats
tally prior event result st0 = withOracle (tallyResult event result st0)
  where
    withOracle st = case oracleClasses prior event result of
      Just (Admit, _) → st {oracleAdmit = oracleAdmit st + 1}
      Just (NotNow, _) → st {oracleNotNow = oracleNotNow st + 1}
      Just (Never, _) → st
      Just (Exhausted, _) → st {oracleExhausted = oracleExhausted st + 1}
      Nothing → st

tallyResult ∷ Event → Either Refusal Report → Stats → Stats
tallyResult _ (Left _) st = st {refused = refused st + 1}
tallyResult event (Right report) st =
  let st' = st {accepted = accepted st + 1, retired = retired st + length (reportSettled report)}
   in case reportDecision report of
        Published _ _ → st' {completed = completed st' + 1}
        Accepted a → st' {victims = victims st' + length (admissionVictims a)}
        Committed _ _ _ dropped stale
          | null dropped && null stale → st' {committed = committed st' + 1}
          | otherwise → st' {committed = committed st' + 1, superseded = superseded st' + 1}
        Discarded _ | JobAcknowledged _ ← event → st' {acknowledged = acknowledged st' + 1}
        CameraSet {cameraCancelled = gone, cameraAwaitingAck = awaiting}
          | not (null gone && null awaiting) → st' {replaced = replaced st' + 1}
        _ → st'

-- | A fixed pseudo-random sequence (a linear congruential generator).
lcg ∷ Int → Int → [(Int, Int, Int)]
lcg seed n = take n (triples (drop 1 (iterate next seed)))
  where
    next x = (x * 1103515245 + 12345) `mod` 2147483648
    triples (x : y : z : rest) = (x `div` 65536, y `div` 65536, z `div` 65536) : triples rest
    triples _ = []

-- | Coverages of every size and shape within the extent: one cell, two cells in
-- one column, two columns, two separate intervals, a whole column and a block.
demandCoverages ∷ [Coverage]
demandCoverages =
  [ cell 0 0 0
  , box 0 1 0 1 0 2
  , coverageUnion (cell 0 0 0) (cell 1 0 0)
  , coverageUnion (cell 0 0 0) (cell 0 0 4)
  , box 0 1 0 1 0 6
  , box 0 2 0 1 0 4
  ]

-- | Service, dispatch every queued job and complete each with the least it can
-- store, until a round does no work.
converge ∷ Int → Model → Either String Model
converge 0 _ = Left "did not converge"
converge n m0 =
  -- The owner discards what the model committed as victims and reports it.
  let m = foldl (\mm r → fst (step mm (VictimReleased (regionArena r) (regionCoord r)))) m0 [r | r ← modelRegions m0, regionEvicting r]
      (m1, serviced) = step m Service
      admittedAny = case serviced of
        Right r | Serviced xs ← reportDecision r → not (null xs)
        _ → False
      (m2, dispatched) = dispatchAll m1 (0 ∷ Int)
      running = [j | j ← modelJobs m2, jobPhase j == JobRunningPhase]
      m3 = foldl (\mm j → fst (step mm (JobCompleted (jobId j) (honestCost mm j)))) m2 running
   in if not admittedAny && dispatched == 0 && null running && null [() | r ← modelRegions m3, regionEvicting r]
        then Right m3
        else converge (n - 1) m3
  where
    dispatchAll mm k = case step mm Dispatch of
      (mm', Right r) | Dispatched {} ← reportDecision r → dispatchAll mm' (k + 1)
      _ → (mm, k)

-- | A model with some regions left resident and unpinned: explicit queries for
-- them completed with the least they can store and then withdrawn.
withLeftovers ∷ Limits → [(Int, Int)] → Model
withLeftovers limits picks =
  let start = fst (step (newModel limits) (OpenArena (ArenaId 1) (Revision 0)))
      load (m, i) (x, j) =
        let (m1, _) = step m (SubmitQuery (RequestId i) (ArenaId 1) (Revision 0) [demandAt x j])
            m2 = either (const m1) id (converge 50 m1)
         in (fst (step m2 (Withdraw (RequestId i))), i + 1)
   in fst (foldl load (start, 100) picks)

demandAt ∷ Int → Int → RegionDemand
demandAt x j = demand (reg (toInteger x) 0 0) (fromMaybe (cell 0 0 0) (pick demandCoverages j))

distinctDemands ∷ [(Int, Int)] → [RegionDemand]
distinctDemands picks =
  let xs = foldl (\acc (x, _) → if x `elem` acc then acc else acc <> [x]) [] picks
   in [demandAt x j | x ← take 2 xs, Just j ← [lookup x picks]]

limitsOf ∷ (Integer, Integer, Integer) → Maybe Limits
limitsOf (resident, staging, jobs) =
  either (const Nothing) Just . mkLimits $
    LimitsSpec
      { specResidentBytes = resident
      , specEditBytes = 192
      , specStagingBytes = staging
      , specLoadJobs = jobs
      , specQueuedCommands = 3
      , specPinsPerView = 2
      
      , specAgingQuanta = 3
      , specQueryRegions = 2
      , specExtentX = 2
      , specExtentY = 1
      , specExtentZ = 6
      , specHoldRegions = 0
      , specCameraRegions = 64
      }

-- | A camera demand completes when it is alone and the camera's share of the banks
-- (what is left beyond the explicit headroom) holds it, whatever resident regions
-- are left over: none of it can stay pending once the work that holds the room has
-- finished.
acceptedDemandCompletes ∷ (Integer, Integer, Integer) → [(Int, Int)] → [(Int, Int)] → Property
acceptedDemandCompletes triple leftovers picks =
  case limitsOf triple of
    Nothing → property True
    Just limits →
      let start = withLeftovers limits leftovers
          demands = distinctDemands picks
       in if null demands
            then property True
            else case step start (SetCameraDemand (ViewId 1) (ArenaId 1) demands) of
              (_, Left r) → counterexample ("an in-cap camera demand was refused: " <> show (r, demands, limits)) False
              (m, Right _) → case converge 200 m of
                Left why → counterexample why False
                Right done →
                  counterexample
                    ("demand accepted but left pending: " <> show (map viewPending (modelViews done)) <> " with " <> show (demands, limits))
                    (all (null . viewPending) (modelViews done))

-- | The model a run of the sequence's events leaves behind, whatever they did.
modelAfter ∷ Limits → [(Int, Int, Int)] → Model
modelAfter limits = foldl (\m s → fst (step m (eventFor m s))) (fst (step (newModel limits) (OpenArena (ArenaId 1) (Revision 0))))

-- | In-cap requests built against a state: the first live arena, at its current
-- revision, and fresh identities.
inCapRequests ∷ Model → [(Int, Int)] → [(String, Event)]
inCapRequests m picks = case [a | a ← modelArenas m, arenaPhase a == ArenaLive] of
  [] → []
  (arena : _) →
    let a = arenaId arena
        rev = arenaRevision arena
        demands = distinctDemands picks
        tile = case picks of
          ((x, j) : _) → either (const Nothing) Just (tileCoord (toInteger (x `mod` 3) * 16 + toInteger (j `mod` 2)) 0 (toInteger (fromMaybe (0 ∷ Int) (pick [0, 5, 1, 2] j))))
          [] → Nothing
     in [("query", SubmitQuery (RequestId 1000000) a rev demands) | not (null demands)]
          <> [("removal", SubmitRemoval (RequestId 1000001) a rev t) | Just t ← [tile]]
          <> [("camera", SetCameraDemand (ViewId 7) a demands) | not (null demands)]

-- | A request within its caps is never invalid for capacity in any state: the
-- reasons the model can still call invalid are about the request alone.
inCapNeverInvalid ∷ [(Int, Int, Int)] → [(Int, Int)] → Property
inCapNeverInvalid seeds picks =
  let m = modelAfter pressure seeds
   in conjoin
        [ counterexample (what <> " within its caps was invalid: " <> show r) (case r of Left (Invalid _) → False; _ → True)
        | (what, event) ← inCapRequests m picks
        , let r = snd (step m event)
        ]

-- | Every busy request in a quiescent model, one where the owner has released
-- everything releasable (jobs finished, victims released, handoffs confirmed,
-- holds released, requests and camera demands withdrawn), is admitted at once.
busyEndsWhenReleased ∷ [(Int, Int, Int)] → [(Int, Int)] → Property
busyEndsWhenReleased seeds picks =
  let m0 = modelAfter pressure seeds
   in case quiesce m0 of
        Left why → counterexample why False
        Right m →
          conjoin
            [ counterexample (what <> " was not admitted in a quiescent model: " <> show r) (admitted what r)
            | (what, event) ← inCapRequests m picks
            , let r = step m event
            ]
  where
    admitted what (_, result) = case result of
      Right _ → True
      Left (RetainedEditsExhausted {}) → what == "removal"
      Left _ → False

-- | Carry out everything the model has asked of the owner, then offload every
-- changed region (begin and confirm its handoff), until nothing is left.
quiesce ∷ Model → Either String Model
quiesce m0 = do
  m1 ← settleEverything m0
  let dirty = [r | r ← modelRegions m1, regionDirty r, regionHandoff r == Nothing]
      offload m r = fst (step (fst (step m (BeginHandoff (regionArena r) (regionCoord r) 0))) (HandoffConfirmed (regionArena r) (regionCoord r)))
  settleEverything (foldl offload m1 dirty)

-- | The reservation admission computes for an in-cap explicit request, into a model
-- that holds nothing, never exceeds the worst case the construction check assumed:
-- resident and staging bytes (reserved and occupied) stay within the explicit
-- minimum for their bank.
reservationWithinMinimum ∷ [(Int, Int)] → Property
reservationWithinMinimum picks =
  let empty = modelAfter pressure []
   in conjoin
        [ counterexample (what <> " reserved more than the construction-time worst case: " <> show (ledgersOf m)) $
            conjoin
              [ resident ledgersOfModel <= toInteger (limitExplicitResidentBytes pressure)
              , staging ledgersOfModel <= toInteger (limitExplicitStagingBytes pressure)
              ]
        | (what, event) ← inCapRequests empty picks
        , what /= "camera"
        , (m, Right _) ← [step empty event]
        , let ledgersOfModel = ledgersOf m
        ]
  where
    resident l = let (o, r) = (\(Ledgers a _ _) → a) l in toInteger (o + r)
    staging l = let (o, r) = (\(Ledgers _ _ c) → c) l in toInteger (o + r)

-- | The owner finishes the explicit-only work and nothing of the camera's: it
-- withdraws every request, finishes every running job (finite work), releases every
-- victim, offloads every changed region and dispatches only what a request needs. It
-- releases no hold, withdraws no camera demand and leaves every camera job that has not
-- been dispatched queued.
settleExplicitOnly ∷ Model → Either String Model
settleExplicitOnly = go (800 ∷ Int)
  where
    go 0 _ = Left "the explicit-only work did not drain"
    go n m = case actions m of
      [] → Right m
      (ev : _) → case step m ev of
        (m', Right _) → go (n - 1) m'
        (_, Left r) → Left ("the owner's " <> show ev <> " was refused: " <> show r)
    actions m =
      [Withdraw (requestId r) | r ← modelRequests m]
        <> [JobCompleted (jobId j) (honestCost m j) | j ← modelJobs m, jobPhase j `elem` [JobRunningPhase, JobCancellingPhase]]
        <> [VictimReleased (regionArena r) (regionCoord r) | r ← modelRegions m, regionEvicting r]
        <> [HandoffConfirmed (regionArena r) (regionCoord r) | r ← modelRegions m, Just _ ← [regionHandoff r]]
        <> [BeginHandoff (regionArena r) (regionCoord r) 0 | r ← modelRegions m, regionDirty r, regionHandoff r == Nothing, regionArena r `elem` [arenaId a | a ← modelArenas m, arenaPhase a == ArenaLive]]
        <> [Dispatch | any (neededByRequest m) [j | j ← modelJobs m, jobPhase j == JobQueued]]
    neededByRequest m j = or [True | i ← modelInterests m, requestOwned (interestOwner i), interestArena i == jobArena j, interestRegion i == jobRegion j, coverageIntersects (interestCoverage i) (jobCoverage j)]
    requestOwned (OwnerRequest _) = True
    requestOwned (OwnerView _) = False

-- | Explicit requests are never blocked by camera activity: with every camera demand,
-- pin, interest and undispatched camera job left exactly as the sequence left them,
-- once the explicit-only work has drained an in-cap query or removal is admitted at once.
explicitWithCameraPresent ∷ [(Int, Int, Int)] → [(Int, Int)] → Property
explicitWithCameraPresent seeds picks =
  let m0 = modelAfter pressure seeds
   in case settleExplicitOnly m0 of
        Left why → counterexample why False
        Right m →
          conjoin
            [ counterexample (what <> " was blocked by the camera once the explicit work drained: " <> show r) (admitted what r)
            | (what, event) ← take 2 (inCapRequests m picks)
            , let r = snd (step m event)
            ]
  where
    admitted what result = case result of
      Right _ → True
      Left (RetainedEditsExhausted {}) → what == "removal"
      Left _ → False

-- | A camera description is never kept longer than the camera can start: whatever the
-- staging, a non-empty description that is retained has its first region admitted at
-- once (an interest or a job), so the camera never sits pending with nothing in flight.
cameraStartsWhatItKeeps ∷ Integer → [(Int, Int)] → Property
cameraStartsWhatItKeeps staging picks = case limitsNear 4384 staging of
  Nothing → counterexample ("a configuration at the minimum was refused: " <> show staging) False
  Just limits →
    let start = fst (step (newModel limits) (OpenArena (ArenaId 1) (Revision 0)))
        demands = [demandAt x j | (x, j) ← picks]
        distinct = foldr (\d acc → if demandRegion d `elem` map demandRegion acc then acc else d : acc) [] demands
     in case step start (SetCameraDemand (ViewId 1) (ArenaId 1) distinct) of
          (m, Right _) →
            conjoin
              [ counterexample ("a retained description of " <> show (length (viewDemand v)) <> " regions started none of them at " <> show staging) $
                  length (viewPending v) < length (viewDemand v)
              | v ← modelViews m
              , not (null (viewDemand v))
              ]
          (_, Left r) → counterexample ("the camera demand was refused: " <> show r) False

-- | The same for a replacement: a camera that has loaded one description and pans to
-- another (the owner has completed everything in between, or has not yet dispatched the
-- first one's queued work, or its load is running and the replacement cancels it, and
-- nothing else holds the room) never loses the new description. Whatever the staging, a
-- non-empty replacement keeps the view with a non-empty description; when no cancelled
-- work still holds its scratch it also starts its first region at once; and once the owner
-- has completed or acknowledged everything it has made progress (a demand larger than the
-- camera's share is admitted partially, as always).
data FirstWork = Settled | Queued | Running deriving stock (Eq, Show)

cameraReplacementStarts ∷ FirstWork → Integer → [(Int, Int)] → [(Int, Int)] → Property
cameraReplacementStarts firstWork staging firstPicks nextPicks = case limitsNear 4384 staging of
  Nothing → counterexample ("a configuration at the minimum was refused: " <> show staging) False
  Just limits →
    let start = fst (step (newModel limits) (OpenArena (ArenaId 1) (Revision 0)))
        distinctOf picks = foldr (\d acc → if demandRegion d `elem` map demandRegion acc then acc else d : acc) [] [demandAt x j | (x, j) ← picks]
        settle ∷ Int → Model → Maybe Model
        settle 0 _ = Nothing
        settle n m = case events m of
          (ev : _) → case step m ev of (m', Right _) → settle (n - 1) m'; _ → Nothing
          [] → case step m Service of
            (m', Right r) | reportDecision r /= Serviced [] → settle (n - 1) m'
            _ → Just m
        events m =
          [VictimReleased (regionArena r) (regionCoord r) | r ← modelRegions m, regionEvicting r]
            <> [JobCompleted (jobId j) (honestCost m j) | j ← modelJobs m, jobPhase j `elem` [JobRunningPhase, JobCancellingPhase]]
            <> [Dispatch | any ((== JobQueued) . jobPhase) (modelJobs m)]
        -- Dispatch whatever is queued, leaving every load running.
        dispatchAll ∷ Int → Model → Maybe Model
        dispatchAll 0 _ = Nothing
        dispatchAll n m
          | any ((== JobQueued) . jobPhase) (modelJobs m) = case step m Dispatch of
              (m', Right r) | reportDecision r /= NothingToDispatch → dispatchAll (n - 1) m'
              (m', Right _) → Just m'
              _ → Nothing
          | otherwise = Just m
        firstDemand = distinctOf firstPicks
        nextDemand = distinctOf nextPicks
     in case step start (SetCameraDemand (ViewId 1) (ArenaId 1) firstDemand) of
          (m1, Right _) → case (case firstWork of Settled → settle 200 m1; Queued → Just m1; Running → dispatchAll 50 m1) of
            Nothing → counterexample "the first description did not settle" False
            Just m2 → case step m2 (SetCameraDemand (ViewId 1) (ArenaId 1) nextDemand) of
              (m3, Right _)
                | null nextDemand → property True
                | otherwise → case modelViews m3 of
                    [v] →
                      let cancelled = any ((== JobCancellingPhase) . jobPhase) (modelJobs m3)
                          summary = show (length nextDemand) <> " regions kept " <> show (length (viewDemand v)) <> " and started " <> show (length (viewDemand v) - length (viewPending v)) <> " at " <> show staging <> " after " <> show firstWork
                       in counterexample ("a replacement of " <> summary) (not (null (viewDemand v)))
                            .&&. counterexample ("a replacement with nothing cancelled did not start its first region: " <> summary) (cancelled || length (viewPending v) < length (viewDemand v))
                            .&&. case settle 400 m3 of
                              Nothing → counterexample "the replacement did not settle" False
                              Just m4 → case modelViews m4 of
                                [w] → counterexample ("the replacement made no progress after the owner acknowledged everything: " <> summary) (not (null (viewDemand w)) && length (viewPending w) < length (viewDemand w))
                                ws → counterexample ("the view did not survive settling: " <> show (length ws) <> " views") False
                    vs → counterexample ("the view did not survive a non-empty replacement: " <> show (length vs) <> " views") False
              (_, Left r) → counterexample ("the replacement was refused: " <> show r) False
          (_, Left r) → counterexample ("the first demand was refused: " <> show r) False

-- | Replacing a view's camera demand is exactly withdrawing the old one and admitting the
-- new one afresh: at every state a random sequence reaches, for each view that has a
-- demand and a random new description, the model after the replacement equals the model
-- after the withdrawal followed by the fresh demand.
replacementIsWithdrawThenAdmit ∷ Limits → [(Int, Int, Int)] → Property
replacementIsWithdrawThenAdmit limits seeds = go (newModel limits) seeds (0 ∷ Int)
  where
    go _ [] n = cover 60 (n > 0) "a replacement was compared" (property True)
    go m (s@(x, y, z) : rest) n =
      let (m', _) = step m (eventFor m s)
          description = [demandFor (y + i) (x + i) | i ← [0 .. z `mod` 5]]
          cases = [v | v ← modelViews m', not (null (viewDemand v))]
          agrees v =
            let direct = step m' (SetCameraDemand (viewId v) (ArenaId 1) description)
                staged = case step m' (ClearCameraDemand (viewId v)) of
                  (mw, Right _) → step mw (SetCameraDemand (viewId v) (ArenaId 1) description)
                  other → other
             in case (direct, staged) of
                  ((md, Right _), (ms, Right _)) → counterexample ("view " <> show (viewId v) <> ": the replacement differs from withdraw-then-admit") (observed md == observed ms)
                  -- A refused replacement changes nothing; only an accepted one is compared.
                  ((_, Left _), _) → property True
                  ((_, Right _), (_, Left r)) → counterexample ("the fresh demand after a withdrawal was refused: " <> show r) False
       in conjoin (map agrees cases) .&&. go m' rest (n + length cases)

-- | Everything a model exposes except its logical clock, which a second event advances
-- (and which only orders eviction): two models that differ only in it are the same.
observed ∷ Model → (String, String, String, [(ArenaId, String, Coverage, Integer)], [Ledger])
observed m =
  ( show (modelViews m)
  , show (modelJobs m)
  , show (modelInterests m)
  , [(regionArena r, show (regionCoord r), regionCoverage r, toInteger (regionBytes r)) | r ← modelRegions m]
  , [bankLedger m b | b ← allBanks]
  )

-- | A request over its caps is invalid from every state, with a typed reason.
overCapAlwaysInvalid ∷ [(Int, Int, Int)] → Property
overCapAlwaysInvalid seeds =
  let m = modelAfter pressure seeds
   in case [a | a ← modelArenas m, arenaPhase a == ArenaLive] of
        [] → property True
        (arena : _) →
          let a = arenaId arena
              rev = arenaRevision arena
              three = [demand (reg x 0 0) (cell 0 0 0) | x ← [0, 1, 2]]
              outside z x = [demand (reg 0 0 0) (cell x 0 z)]
           in conjoin
                [ expect "a three-region query" (SubmitQuery (RequestId 1000000) a rev three) (Invalid (DemandTooLarge 3 2))
                , expect "a cell above the extent" (SubmitQuery (RequestId 1000000) a rev (outside 6 0)) (Invalid (OutsideExtent (reg 0 0 0)))
                , expect "a cell beyond the extent's columns" (SubmitQuery (RequestId 1000000) a rev (outside 0 2)) (Invalid (OutsideExtent (reg 0 0 0)))
                ]
          where
            expect what event want = case snd (step m event) of
              Left got → counterexample (what <> ": " <> show got) (got == want)
              Right _ → counterexample (what <> " was accepted") False

-- | A configuration is refused at construction exactly when a bank (or the load
-- jobs) is below the worst-case footprint of the largest admissible explicit
-- request, restated here by hand: the region at its stored maximum, the largest
-- job beyond it, and the staging each kind of request holds.
minimumBudgetsAreEnforced ∷ (Integer, Integer, Integer, Integer) → (Integer, Integer, Integer, Integer) → Property
minimumBudgetsAreEnforced (resident, edit, staging, jobs) (query, x, y, z) =
  let spec' =
        LimitsSpec
          { specResidentBytes = resident
          , specEditBytes = edit
          , specStagingBytes = staging
          , specLoadJobs = jobs
          , specQueuedCommands = 3
          , specPinsPerView = 2
          , specAgingQuanta = 3
          , specQueryRegions = query
          , specExtentX = x
          , specExtentY = y
          , specExtentZ = z
          , specHoldRegions = 4
          , specCameraRegions = 64
          }
      columns = x * y
      intervals = columns * ((z + 1) `div` 2)
      stored = 256 + 48 * columns + 34 * columns * z
      job = 48 * columns + 96 * intervals
      scratch = 256 + 2 * columns * z
      needResident = maximum [4 * stored, stored + job] + maximum [query * (stored + job), stored + 48 + 96 + 62]
      needStaging = maximum [64 * 4, 192 + 64 + scratch] + maximum [128 + 32 * query + 64 * query + query * scratch, 160 + 512 + 64 + 258, stored]
      expected
        | resident < needResident = Just (BankBelowMinimum ResidentBank needResident resident)
        | edit < 64 = Just (BankBelowMinimum EditBank 64 edit)
        | staging < needStaging = Just (BankBelowMinimum StagingBank needStaging staging)
        | otherwise = Nothing
   in counterexample (show (spec', expected)) $ case (mkLimits spec', expected) of
        (Right _, Nothing) → property True
        (Left got, Just want) → got === want
        (other, _) → counterexample ("unexpected " <> either show (const "accepted") other) False

spec ∷ Spec
spec = describe "Residency model properties" $ do
  it "refuses a configuration exactly when a bank is below the worst-case footprint of its largest request" $
    withNumTests 5000 $
      forAll ((,,,) <$> chooseInteger (1, 12000) <*> chooseInteger (1, 200) <*> chooseInteger (1, 12000) <*> chooseInteger (1, 4)) $ \banks →
        forAll ((,,,) <$> chooseInteger (1, 4) <*> chooseInteger (1, 4) <*> chooseInteger (1, 3) <*> chooseInteger (1, 12)) $ \caps →
          minimumBudgetsAreEnforced banks caps
  it "holds its invariants over random sequences" $
    withNumTests 200 $
      forAll (vectorOf 250 ((,,) <$> chooseInt (0, 1000) <*> chooseInt (0, 1000) <*> chooseInt (0, 1000))) $ \seeds →
        case runSequence seeds of
          (Left why, _) → counterexample why False
          (Right _, _) → property True
  it "completes every in-cap camera demand when it is alone, under random valid budgets and leftovers" $
    withNumTests 2000 $
      forAll ((,,) <$> chooseInteger (4800, 6500) <*> chooseInteger (3000, 8000) <*> chooseInteger (4, 6)) $ \limitsTriple →
        forAll (vectorOf 3 pair) $ \leftovers →
          forAll (vectorOf 4 pair) $ \picks →
            acceptedDemandCompletes limitsTriple leftovers picks
  it "never refuses an in-cap request as invalid, from any state the sequences reach" $
    withNumTests 300 $
      forAll seedsOf $ \seeds → forAll (vectorOf 3 pair) $ \picks → inCapNeverInvalid seeds picks
  it "admits every in-cap request once everything releasable has been released" $
    withNumTests 300 $
      forAll seedsOf $ \seeds → forAll (vectorOf 3 pair) $ \picks → busyEndsWhenReleased seeds picks
  it "keeps every charge rule across load, complete, pin, unpin, camera expansion, withdraw, removal, handoff and eviction under budgets at and just above the minimum" $
    withNumTests 300 $
      forAll ((,) <$> chooseInteger (4384, 6400) <*> chooseInteger (1530, 3600)) $ \(resident, staging) →
        forAll seedsOf $ \seeds → case limitsNear resident staging of
          Nothing → counterexample ("a configuration at or above the minimum was refused: " <> show (resident, staging)) False
          Just limits → case runSequenceWith limits seeds of
            (Left why, _) → counterexample why False
            (Right _, _) → property True
  it "keeps every charge rule over a long sequence at exactly the minimum budgets" $ do
    case limitsNear 4384 1530 of
      Nothing → expectationFailure "the minimum configuration was refused"
      Just limits → do
        let (outcome, stats) = runSequenceWith limits (lcg 21 12000)
        outcome `shouldSatisfy` either (const False) (const True)
        accepted stats `shouldSatisfy` (> 1000)
  it "starts the first region of every camera description it retains, at any staging from the minimum" $
    withNumTests 2000 $
      forAll (chooseInteger (1530, 4000)) $ \staging → forAll (vectorOf 5 pair) $ \picks → cameraStartsWhatItKeeps staging picks
  it "starts the first region of every replacement of a settled camera description, at any staging from the minimum" $
    withNumTests 2000 $
      forAll (chooseInteger (1530, 4000)) $ \staging → forAll (vectorOf 5 pair) $ \a → forAll (vectorOf 5 pair) $ \b → cameraReplacementStarts Settled staging a b
  it "starts the first region of every replacement of a camera description whose work is still queued, at any staging from the minimum" $
    withNumTests 2000 $
      forAll (chooseInteger (1530, 4000)) $ \staging → forAll (vectorOf 5 pair) $ \a → forAll (vectorOf 5 pair) $ \b → cameraReplacementStarts Queued staging a b
  it "keeps and completes every replacement of a camera description whose load is running, at any staging from the minimum" $
    withNumTests 2000 $
      forAll (chooseInteger (1530, 4000)) $ \staging → forAll (vectorOf 5 pair) $ \a → forAll (vectorOf 5 pair) $ \b → cameraReplacementStarts Running staging a b
  it "replaces a view's demand exactly as a withdrawal followed by a fresh demand, at every state random sequences reach" $
    withNumTests 300 $
      forAll ((,) <$> chooseInteger (4384, 6400) <*> chooseInteger (1530, 3600)) $ \(resident, staging) →
        forAll seedsOf $ \seeds → case limitsNear resident staging of
          Nothing → counterexample ("a configuration at or above the minimum was refused: " <> show (resident, staging)) False
          Just limits → replacementIsWithdrawThenAdmit limits seeds
  it "never reserves more for an explicit request than the construction-time worst case" $
    withNumTests 2000 $
      forAll (vectorOf 3 pair) reservationWithinMinimum
  it "never blocks an explicit request on camera holdings, whatever demands the cameras left" $
    withNumTests 300 $
      forAll seedsOf $ \seeds → forAll (vectorOf 3 pair) $ \picks → explicitWithCameraPresent seeds picks
  it "refuses an over-cap request as invalid from every state" $
    withNumTests 200 $
      forAll seedsOf overCapAlwaysInvalid
  it "exercises completion, eviction, commit, refusal and retirement in a fixed long sequence" $ do
    let (outcome, stats) = runSequence (lcg 7 12000)
    outcome `shouldSatisfy` either (const False) (const True)
    -- Guards against a degenerate workload: the sequence must reach the
    -- transitions the properties are about.
    reaches
      stats
      [ ("accepted", accepted, 1000)
      , ("refused", refused, 500)
      , ("completed", completed, 50)
      , ("evictions", victims, 10)
      , ("commits", committed, 10)
      , ("retired arenas", retired, 1)
      , ("acknowledged", acknowledged, 1)
      , ("replaced", replaced, 1)
      , ("oracle: admitted", oracleAdmit, 100)
      , ("oracle: busy", oracleNotNow, 100)
      ]
  it "reaches supersede, cancel and acknowledge interleavings under room for concurrent work" $ do
    let (outcome, stats) = runSequenceWith roomyPressure (lcg 11 12000)
    outcome `shouldSatisfy` either (const False) (const True)
    reaches
      stats
      [ ("accepted", accepted, 4000)
      , ("completed", completed, 200)
      , ("commits", committed, 40)
      , ("superseded", superseded, 1)
      , ("acknowledged", acknowledged, 20)
      , ("replaced", replaced, 20)
      ]
  where
    seedsOf = vectorOf 150 ((,,) <$> chooseInt (0, 1000) <*> chooseInt (0, 1000) <*> chooseInt (0, 1000))
    pair = (,) <$> chooseInt (0, 5) <*> chooseInt (0, 5)
    reaches stats floors =
      forM_ floors $ \(name, field, floor') →
        unless (field stats >= floor') $ expectationFailure ("the sequence reached " <> name <> " only " <> show (field stats) <> " times: " <> show stats)
