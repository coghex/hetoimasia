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

-- | Tight enough that every kind of pressure occurs within a few events.
pressure ∷ Limits
pressure =
  limitsWith $ \s →
    s
      { specResidentBytes = 800
      , specEditBytes = 640
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
    completion j =
      let c = jobCoverage j
       in JobCompleted (jobId j) (Cost 0 (coverageSegments c) (coverageCells c))

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
  if not (null demands) && length demands <= 3 && distinct (map demandRegion demands) then Just () else Nothing
  got ← case result of
    Right _ → Just Admit
    Left (Busy _) → Just NotNow
    Left (Invalid (ExceedsBank _ _ _)) → Just Never
    Left (Invalid (ExceedsSlot _ _ _)) → Just Never
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
settleEverything = go (500 ∷ Int)
  where
    go 0 _ = Left "the owner's actions did not settle the model"
    go n m = case ownerActions m of
      [] → leftovers m
      (ev : _) → case step m ev of
        (m', Right _) → go (n - 1) m'
        (_, Left r) → Left ("the owner's " <> show ev <> " was refused: " <> show r)
    leftovers m =
      case concat
        [ ["a job remains: " <> show j | j ← modelJobs m]
        , ["a bank still reserves bytes: " <> show b <> " " <> show (bankLedger m b) | b ← allBanks, ledgerReserved (bankLedger m b) /= 0]
        , ["staging still occupied: " <> show (bankLedger m StagingBank) | ledgerOccupied (bankLedger m StagingBank) /= 0]
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
      { specResidentBytes = 6000
      , specEditBytes = 2048
      , specStagingBytes = 12000
      , specLoadJobs = 8
      , specQueuedCommands = 8
      , specPinsPerView = 2
      , specDemandRegions = 3
      , specAgingQuanta = 2
      }

runSequenceWith ∷ Limits → [(Int, Int, Int)] → (Either String Model, Stats)
runSequenceWith limits seeds = go (newModel limits) seeds (Stats 0 0 0 0 0 0 0 0 0 0 0 0 0)
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
  , oracleNever ∷ !Int
  , oracleExhausted ∷ !Int
  }
  deriving stock (Eq, Show)

tally ∷ Model → Event → Either Refusal Report → Stats → Stats
tally prior event result st0 = withOracle (tallyResult event result st0)
  where
    withOracle st = case oracleClasses prior event result of
      Just (Admit, _) → st {oracleAdmit = oracleAdmit st + 1}
      Just (NotNow, _) → st {oracleNotNow = oracleNotNow st + 1}
      Just (Never, _) → st {oracleNever = oracleNever st + 1}
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

-- | Coverages of every size and shape the feasibility bound has to tell apart:
-- one cell, two cells in one column, two columns, two separate intervals, a
-- whole column and a block.
demandCoverages ∷ [Coverage]
demandCoverages =
  [ cell 0 0 0
  , box 0 1 0 1 0 2
  , coverageUnion (cell 0 0 0) (cell 1 0 0)
  , coverageUnion (cell 0 0 0) (cell 0 0 9)
  , box 0 1 0 1 0 32
  , box 0 3 0 2 0 4
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
      leastCost j = let c = jobCoverage j in Cost (coverageColumns c) (coverageSegments c) (2 * coverageSegments c)
      m3 = foldl (\mm j → fst (step mm (JobCompleted (jobId j) (leastCost j)))) m2 running
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
   in [demandAt x j | x ← take 4 xs, Just j ← [lookup x picks]]

limitsOf ∷ (Integer, Integer, Integer) → Maybe Limits
limitsOf (resident, staging, jobs) = either (const Nothing) Just (mkLimits (LimitsSpec resident 192 staging jobs 3 2 4 3))

-- | A camera demand the model accepts completes when it is alone in an empty
-- model. The permanent check is exact for that case: it is the feasibility bound
-- in the order regions are admitted, and the model admits them in that order. (From
-- other states a shortfall may be busy for as long as other work holds the room, so
-- nothing is claimed there.)
acceptedDemandCompletes ∷ (Integer, Integer, Integer) → [(Int, Int)] → Property
acceptedDemandCompletes triple picks =
  case limitsOf triple of
    Nothing → property True
    Just limits →
      let start = fst (step (newModel limits) (OpenArena (ArenaId 1) (Revision 0)))
          demands = distinctDemands picks
       in if null demands
            then property True
            else case step start (SetCameraDemand (ViewId 1) (ArenaId 1) demands) of
              (_, Left _) → property True
              (m, Right _) → case converge 200 m of
                Left why → counterexample why False
                Right done →
                  counterexample
                    ("demand accepted but left pending: " <> show (map viewPending (modelViews done)) <> " with " <> show (demands, limits))
                    (all (null . viewPending) (modelViews done))

-- | Whether a request is permanently invalid: by the owner's rule only when its
-- footprint cannot fit from an empty model, and so independent of the state the
-- model is in.
permanentlyInvalid ∷ Either Refusal a → Bool
permanentlyInvalid r = case r of
  Left (Invalid (ExceedsBank {})) → True
  Left (Invalid (ExceedsSlot {})) → True
  _ → False

-- | By the rule that invalidity needs a footprint that cannot fit, a request that
-- is invalid in any state is also invalid from an empty model (it only ever sheds
-- cells already covered), and a request whose cells are all covered is never
-- invalid. Checked for a query, a removal and a camera demand, from a model with
-- resident leftovers and an earlier demand of the same view.
permanentClassIsOnlyNarrower ∷ (Integer, Integer, Integer) → [(Int, Int)] → [(Int, Int)] → [(Int, Int)] → Property
permanentClassIsOnlyNarrower triple leftovers firstPicks picks =
  case limitsOf triple of
    Nothing → property True
    Just limits →
      let empty = fst (step (newModel limits) (OpenArena (ArenaId 1) (Revision 0)))
          loaded = withLeftovers limits leftovers
          earlier = distinctDemands firstPicks
          base = case step loaded (SetCameraDemand (ViewId 1) (ArenaId 1) earlier) of
            (m, Right _) | not (null earlier) → either (const loaded) id (converge 200 m)
            _ → loaded
          demands = distinctDemands picks
          tile = case picks of
            ((x, j) : _) → either (const Nothing) Just (tileCoord (toInteger x * 16) 0 (toInteger (j `mod` 4)))
            [] → Nothing
          requests =
            [("query", SubmitQuery (RequestId 7) (ArenaId 1) (Revision 0) demands) | not (null demands)]
              <> [("removal", SubmitRemoval (RequestId 8) (ArenaId 1) (Revision 0) t) | Just t ← [tile]]
              <> [("camera", SetCameraDemand (ViewId 2) (ArenaId 1) demands) | not (null demands)]
       in conjoin
            [ counterexample
                (what <> " is invalid in the loaded model but not from an empty one: " <> show (event, limits))
                (not (permanentlyInvalid (snd (step base event))) || permanentlyInvalid (snd (step empty event)))
            | (what, event) ← requests
            ]

spec ∷ Spec
spec = describe "Residency model properties" $ do
  it "holds its invariants over random sequences" $
    withNumTests 200 $
      forAll (vectorOf 250 ((,,) <$> chooseInt (0, 1000) <*> chooseInt (0, 1000) <*> chooseInt (0, 1000))) $ \seeds →
        case runSequence seeds of
          (Left why, _) → counterexample why False
          (Right _, _) → property True
  it "completes every camera demand the model accepts when it is alone in an empty model, under random tiny budgets" $
    withNumTests 2000 $
      forAll ((,,) <$> chooseInteger (300, 4000) <*> chooseInteger (300, 3000) <*> chooseInteger (1, 3)) $ \limitsTriple →
        forAll (vectorOf 4 pair) $ \picks →
          acceptedDemandCompletes limitsTriple picks
  it "never calls a request invalid in a loaded model unless it is invalid from an empty one" $
    withNumTests 3000 $
      forAll ((,,) <$> chooseInteger (300, 4000) <*> chooseInteger (300, 3000) <*> chooseInteger (1, 3)) $ \limitsTriple →
        forAll (vectorOf 3 pair) $ \leftovers →
          forAll (vectorOf 4 pair) $ \firstPicks →
            forAll (vectorOf 4 pair) $ \picks →
              permanentClassIsOnlyNarrower limitsTriple leftovers firstPicks picks
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
      , ("oracle: invalid", oracleNever, 5)
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
    pair = (,) <$> chooseInt (0, 5) <*> chooseInt (0, 5)
    reaches stats floors =
      forM_ floors $ \(name, field, floor') →
        unless (field stats >= floor') $ expectationFailure ("the sequence reached " <> name <> " only " <> show (field stats) <> " times: " <> show stats)
