-- | Deterministic tiny-budget traces of the residency and admission model.
--
-- Every example drives 'step' with controlled events: no thread, no sleep and
-- no deadline. After each step the examples check the structural invariants
-- and recompute every ledger from the model's observable records
-- ("Test.Terrain.ResidencySupport"); the expected outcomes below are hand
-- computed from the contract's charge table, not read from the model:
--
-- * a one-cell region job reserves 256 (region metadata) + 48 (column entry) +
--   32 (segment) + 64 (the dense payload bound for its interval) = 400 resident
--   bytes and 258 bytes of scratch, and stores 338 when its cell needs 2 payload
--   bytes;
-- * an interest record is 64 staging bytes and an accepted command naming one
--   region is 160;
-- * a whole-cell removal reserves 64 retained-edit bytes, 512 staging bytes and
--   62 resident bytes for its rebuilt segment (a segment's payload is between 2
--   and 64 bytes).
module Test.Terrain.Residency (spec) where

import Control.Monad (foldM, forM_)
import Data.List (sort)
import Data.Maybe (fromMaybe, listToMaybe)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), TileCoord, tileCoord)
import Hetoimasia.Terrain.Residency
import Test.Hspec
import Test.Terrain.ResidencySupport

spec ∷ Spec
spec = describe "Residency model" $ do
  limitSpec
  ledgerSpec
  fullBankSpec
  sharingSpec
  cancellationSpec
  fundedEvictionSpec
  lruSpec
  descentSpec
  holdSpec
  cameraSpec
  schedulingSpec
  editSpec
  handoffSpec
  retirementSpec
  contractSpec

-- ---------------------------------------------------------------------------
-- Helpers

roomy ∷ Limits
roomy = limitsWith $ \s → s {specResidentBytes = 4000, specStagingBytes = 8192, specLoadJobs = 5}

-- | Room for camera work beside the explicit headroom (994 staging bytes and two job
-- slots stay free for explicit requests), and cells up to level 1 of a region.
roomy2 ∷ Limits
roomy2 = limitsWith $ \s → s {specResidentBytes = 4000, specStagingBytes = 8192, specLoadJobs = 5, specExtentZ = 2}

-- | Room for cells up to level 10 of a region: two regions per request.
tall ∷ Limits
tall = limitsWith $ \s → s {specResidentBytes = 4000, specStagingBytes = 4096, specExtentZ = 11}

-- | The approved initial limits as a specification.
defaultSpec ∷ LimitsSpec
defaultSpec =
  LimitsSpec
    { specResidentBytes = 256 * 1048576
    , specEditBytes = 64 * 1048576
    , specStagingBytes = 128 * 1048576
    , specLoadJobs = 128
    , specQueuedCommands = 256
    , specPinsPerView = 2
    
    , specAgingQuanta = 8
    , specQueryRegions = 257
    , specExtentX = 16
    , specExtentY = 16
    , specExtentZ = 32
    , specHoldRegions = 16384
    , specCameraRegions = 16384
    }

opened ∷ Limits → IO Model
opened limits = fst <$> stepOk (newModel limits) (OpenArena a1 rev0)

q ∷ Integer → RegionCoord → Coverage → Event
q = qAt rev0

-- | A query of two one-cell regions at the revision the arena has reached.
q2 ∷ Revision → Integer → RegionCoord → RegionCoord → Event
q2 rv rid r1 r2 = SubmitQuery (RequestId (fromInteger rid)) a1 rv [demand r1 (cell 0 0 0), demand r2 (cell 0 0 0)]

-- | A query at the revision the arena has reached.
qAt ∷ Revision → Integer → RegionCoord → Coverage → Event
qAt rv rid r c = SubmitQuery (RequestId (fromInteger rid)) a1 rv [demand r c]

admission ∷ Report → Admission
admission r = case reportDecision r of
  Accepted a → a
  d → error ("not an admission: " <> show d)

jobsOf ∷ Report → [JobId]
jobsOf = map fst . admissionJobs . admission

-- | The one job an admission created.
onlyJob ∷ Report → IO JobId
onlyJob r = case jobsOf r of
  [j] → pure j
  other → expectationFailure ("expected one job, got " <> show other) >> fail "no single job"

-- | Submit, dispatch and complete a one-cell query; the request stays open.
loadCell ∷ Model → Integer → RegionCoord → Coverage → IO Model
loadCell m rid r c = do
  (m1, accepted) ← stepOk m (q rid r c)
  case jobsOf accepted of
    [j] → do
      (m2, dispatched) ← stepOk m1 Dispatch
      reportDecision dispatched `shouldBe` Dispatched j (a1, r) c
      (m3, done) ← stepOk m2 (JobCompleted j oneCellCost)
      reportDecision done `shouldBe` Published j [OwnerRequest (RequestId (fromInteger rid))]
      pure m3
    other → expectationFailure ("expected one job, got " <> show other) >> pure m1

withdraw ∷ Model → Integer → IO Model
withdraw m rid = fst <$> stepOk m (Withdraw (RequestId (fromInteger rid)))

tileAt ∷ Integer → Integer → Integer → TileCoord
tileAt x y z = either (error . show) id (tileCoord x y z)

-- | Let the owner carry out everything asked of it, each job storing the least it
-- can, and service the camera demand until nothing more is admitted.
drainDemand ∷ Model → IO Model
drainDemand = go (60 ∷ Int)
  where
    go 0 _ = expectationFailure "the demand did not settle" >> fail "no settle"
    go n m =
      case victims m <> running m <> queued m of
        (ev : _) → stepOk m ev >>= go (n - 1) . fst
        [] → do
          (m', r) ← stepOk m Service
          case reportDecision r of
            Serviced [] → pure m'
            _ → go (n - 1) m'
    victims m = [VictimReleased (regionArena r) (regionCoord r) | r ← modelRegions m, regionEvicting r]
    running m = [JobCompleted (jobId j) (honestCost m j) | j ← modelJobs m, jobPhase j == JobRunningPhase]
    queued m = [Dispatch | any ((== JobQueued) . jobPhase) (modelJobs m)]

-- | Remove a cell and take the edit through its commit; returns the new model
-- and revision.
removeCellAt ∷ Model → ArenaId → Revision → Integer → TileCoord → IO (Model, Revision)
removeCellAt m a rev rid tile = do
  (m1, accepted) ← stepOk m (SubmitRemoval (RequestId (fromInteger rid)) a rev tile)
  case jobsOf accepted of
    [j] → do
      m1d ← stepsOk m1 [Dispatch]
      let cost = maybe oneCellCost (honestCost m1d) (listToMaybe [x | x ← modelJobs m1d, jobId x == j])
      m2 ← stepsOk m1d [JobCompleted j cost]
      let Revision n = rev
          next = Revision (n + 1)
      (m3, committed) ← stepOk m2 (RemovalCommitted (RequestId (fromInteger rid)) next 64 0)
      reportDecision committed `shouldBe` Committed next 0 [] [] []
      pure (m3, next)
    other → expectationFailure ("expected one job, got " <> show other) >> pure (m1, rev)

-- ---------------------------------------------------------------------------

limitSpec ∷ Spec
limitSpec = describe "validated limits" $ do
  it "accepts the approved initial CPU limits, which meet the minimum budgets" $ do
    let l = defaultLimits
    (limitBytes l ResidentBank, limitBytes l EditBank, limitBytes l StagingBank) `shouldBe` (256 * 1048576, 64 * 1048576, 128 * 1048576)
    (limitSlot l LoadJobSlot, limitSlot l CommandSlot, limitSlot l ViewPinSlot) `shouldBe` (128, 256, 2)
    -- The explicit request caps: 257 regions in a query (the approved 8,192-level column
    -- spans up to 257) and a region's whole 16 x 16 x 32 extent. Camera demand has no
    -- cap: it is best effort. A hold names at most 16,384 regions, and a stored camera
    -- description is bounded at 16,384 (more than the approved view envelope needs).
    (limitQueryRegions l, limitExtent l) `shouldBe` (257, (16, 16, 32))
    (limitHoldRegions l, limitCameraRegions l) `shouldBe` (16384, 16384)
    mkLimits defaultSpec `shouldBe` Right l
    -- The worst cases, computed by hand. A region at the extent's maximum, every cell
    -- its own segment, stores 256 + 256 columns x 48 + 8,192 cells x (32 + 2) =
    -- 291,072 bytes; the largest job beyond it reserves 256 x 48 + 4,096 x 96 =
    -- 405,504; a 257-region query needs 179,020,032 resident bytes of the 268,435,456
    -- available.
    limitRegionStoredBytes l `shouldBe` 291072
    explicitMinimumBytes defaultSpec ResidentBank `shouldBe` 257 * (291072 + 405504)
    limitExplicitResidentBytes l `shouldBe` 179020032
    -- Staging for a 257-region query: command 128 + 32 x 257, an interest each (64 x
    -- 257) and the scratch of each load, 256 + 2 x 8,192 = 16,640: 4,301,280, which
    -- camera work and holds always leave free; a hold adds 64 per region of its 16,384.
    explicitMinimumBytes defaultSpec StagingBank `shouldBe` 128 + 32 * 257 + 64 * 257 + 257 * 16640
    limitExplicitStagingBytes l `shouldBe` 4301280
    minimumBytes defaultSpec StagingBank `shouldBe` 4301280 + 64 * 16384
    minimumBytes defaultSpec EditBank `shouldBe` 64
  it "refuses a zero, negative or unrepresentable limit by field, without clamping" $ do
    let spec0 = baseSpec
    fmap (const ()) (mkLimits spec0) `shouldBe` (Right () ∷ Either LimitError ())
    mkLimits spec0 {specResidentBytes = 0} `shouldBe` Left (LimitNotPositive FieldResidentBytes 0)
    mkLimits spec0 {specLoadJobs = -5} `shouldBe` Left (LimitNotPositive FieldLoadJobs (-5))
    mkLimits spec0 {specPinsPerView = 0} `shouldBe` Left (LimitNotPositive FieldPinsPerView 0)
    mkLimits spec0 {specStagingBytes = limitCeiling + 1} `shouldBe` Left (LimitUnrepresentable FieldStagingBytes (limitCeiling + 1))
    mkLimits spec0 {specEditBytes = 2 ^ (70 ∷ Int)} `shouldBe` Left (LimitUnrepresentable FieldEditBytes (2 ^ (70 ∷ Int)))
    mkLimits spec0 {specAgingQuanta = 0} `shouldBe` Left (LimitNotPositive FieldAgingQuanta 0)
    mkLimits spec0 {specQueryRegions = 0} `shouldBe` Left (LimitNotPositive FieldQueryRegions 0)
    mkLimits spec0 {specExtentX = 0} `shouldBe` Left (LimitNotPositive FieldExtentX 0)
    -- A region is 16 x 16 x 32; an extent cannot exceed it, and the whole of it is accepted.
    mkLimits spec0 {specExtentX = 17} `shouldBe` Left (LimitUnrepresentable FieldExtentX 17)
    mkLimits spec0 {specExtentY = 17} `shouldBe` Left (LimitUnrepresentable FieldExtentY 17)
    mkLimits spec0 {specExtentZ = 33} `shouldBe` Left (LimitUnrepresentable FieldExtentZ 33)
    fmap limitExtent (mkLimits defaultSpec {specExtentX = 16, specExtentY = 16, specExtentZ = 32}) `shouldBe` Right (16, 16, 32)
  it "reports the first refused field in declaration order" $
    mkLimits baseSpec {specResidentBytes = 0, specEditBytes = 0, specExtentZ = 0} `shouldBe` Left (LimitNotPositive FieldResidentBytes 0)
  it "refuses a configuration below the worst-case footprint at construction, naming the bank and the shortfall" $ do
    -- Two regions of one cell: each region may already hold 338 bytes and then load
    -- a 144-byte job (48 column + 96 segment), so a request needs 2 x 482 = 964.
    mkLimits baseSpec {specResidentBytes = 963} `shouldBe` Left (BankBelowMinimum ResidentBank 964 963)
    fmap (const ()) (mkLimits baseSpec {specResidentBytes = 964}) `shouldBe` Right ()
    -- A removal is the largest explicit staging request here: command 160 + removal 512 +
    -- interest 64 + the scratch of its one cell, 258.
    -- (plus 64 for each of the four regions of the largest hold: 994 + 256)
    mkLimits baseSpec {specStagingBytes = 1249} `shouldBe` Left (BankBelowMinimum StagingBank 1250 1249)
    fmap (const ()) (mkLimits baseSpec {specStagingBytes = 1250}) `shouldBe` Right ()
    -- One removal retains 64 bytes.
    mkLimits baseSpec {specEditBytes = 63} `shouldBe` Left (BankBelowMinimum EditBank 64 63)
    -- A query may name more regions than there are load-job slots: a slot is taken at
    -- dispatch.
    fmap (const ()) (mkLimits baseSpec {specQueryRegions = 3, specLoadJobs = 1, specResidentBytes = 4000}) `shouldBe` Right ()
    -- The first bank below its minimum, in the order resident, edit, staging.
    mkLimits baseSpec {specResidentBytes = 100, specStagingBytes = 100} `shouldBe` Left (BankBelowMinimum ResidentBank 964 100)
  it "admits the largest request even when every region it names already holds the most its extent allows" $ do
    -- Extent 2 x 1 x 6. A region stores at most 256 + 2 x 48 + 12 x 34 = 760 bytes (every
    -- cell its own segment, which removals can make of it), and a job over the extent
    -- reserves at most 2 x 48 + 6 x 96 = 672 more: two such regions need exactly 2,864
    -- bytes.
    let spec' = baseSpec {specResidentBytes = 2864, specStagingBytes = 1250, specExtentX = 2, specExtentZ = 6}
        cols zs = foldr1 coverageUnion [cell x 0 z | x ← [0, 1], z ← zs]
        odds = cols [1, 3, 5]
        evens = cols [0, 2, 4]
        pair' rid c = SubmitQuery (RequestId rid) a1 rev0 [demand (reg 0 0 0) c, demand (reg 1 0 0) c]
    minimumBytes spec' ResidentBank `shouldBe` 2864
    limits ← either (\e → expectationFailure (show e) >> fail "limits") pure (mkLimits spec')
    mkLimits spec' {specResidentBytes = 2863} `shouldBe` Left (BankBelowMinimum ResidentBank 2864 2863)
    m0 ← opened limits
    (m1, first) ← stepOk m0 (pair' 1 odds)
    let jobs = jobsOf first
    length jobs `shouldBe` 2
    m2 ← stepsOk m1 (Dispatch : Dispatch : [JobCompleted j (Cost 2 6 24) | j ← jobs])
    map regionBytes (modelRegions m2) `shouldBe` [568, 568]
    m3 ← withdraw m2 1
    -- Every region holds what two queries made of it; the largest job fits with room to spare.
    (m4, second) ← stepOk m3 (pair' 2 evens)
    admissionVictims (admission second) `shouldBe` []
    admissionDeferred (admission second) `shouldBe` 0
    (ledgerOccupied (bankLedger m4 ResidentBank), ledgerReserved (bankLedger m4 ResidentBank)) `shouldBe` (1136, 1344)
  it "refuses a request over its caps as invalid, from any state, with a typed reason" $ do
    m0 ← opened tiny
    let three = [demand (reg i 0 0) (cell 0 0 0) | i ← [0 .. 2]]
    stepRefused m0 (SubmitQuery (RequestId 1) a1 rev0 three) `shouldReturn` Invalid (DemandTooLarge 3 2)
    -- The same from a model that holds a resident region and a running job.
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0)
    (m2, _) ← stepOk m1 (q 2 (reg 1 0 0) (cell 0 0 0))
    stepRefused m2 (SubmitQuery (RequestId 3) a1 rev0 three) `shouldReturn` Invalid (DemandTooLarge 3 2)
    -- A cell outside the one-cell extent, in each axis.
    forM_ [cell 1 0 0, cell 0 1 0, cell 0 0 1] $ \c → do
      stepRefused m0 (q 1 (reg 0 0 0) c) `shouldReturn` Invalid (OutsideExtent (reg 0 0 0))
      -- A camera demand is normalized, not refused: cells outside the extent are clipped
      -- away and a region left with none is excluded and reported.
      (_, clipped) ← stepOk m2 (SetCameraDemand (ViewId 1) a1 [demand (reg 2 0 0) c])
      case reportDecision clipped of
        CameraSet _ _ _ _ _ excluded _ → excluded `shouldBe` [reg 2 0 0]
        other → expectationFailure (show other)
    stepRefused m0 (SubmitRemoval (RequestId 1) a1 rev0 (tileAt 1 0 0)) `shouldReturn` Invalid (OutsideExtent (reg 0 0 0))
    stepRefused m0 (SubmitQuery (RequestId 1) a1 rev0 []) `shouldReturn` Invalid EmptyDemand
    stepRefused m0 (SubmitQuery (RequestId 1) a1 rev0 [demand (reg 0 0 0) (cell 0 0 0), demand (reg 0 0 0) (cell 0 0 0)])
      `shouldReturn` Invalid (DuplicateRegion (reg 0 0 0))
  it "answers any shortfall with busy, however long it lasts, and admits once the room is released" $ do
    -- 1000 resident bytes. Regions A and C are resident and pinned by open requests
    -- (676); a request for B needs 400 and only 324 are free.
    m0 ← opened tiny
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0)
    m2 ← loadCell m1 2 (reg 2 0 0) (cell 0 0 0)
    r ← stepRefused m2 (q 3 (reg 1 0 0) (cell 0 0 0))
    r `shouldBe` Busy (NoEligibleEviction 76 0 (Blockers 0 0 0 0 2 0 0))
    m3 ← withdraw m2 1
    (_, ok) ← stepOk m3 (q 3 (reg 1 0 0) (cell 0 0 0))
    admissionVictims (admission ok) `shouldBe` [(a1, reg 0 0 0)]
  it "refuses a region key that names no supported tile, at the exact boundary of each axis" $ do
    m0 ← opened tiny
    -- The supported tile range is [-2^62, 2^62 - 1]: regions of 16, 16 and 32
    -- tiles reach exactly -2^58..2^58-1 on X and Y and -2^57..2^57-1 on Z.
    let edge = 2 ^ (58 ∷ Int) ∷ Integer
        edgeZ = 2 ^ (57 ∷ Int) ∷ Integer
        accepted' = [reg (edge - 1) 0 0, reg (negate edge) 0 0, reg 0 (edge - 1) 0, reg 0 (negate edge) 0, reg 0 0 (edgeZ - 1), reg 0 0 (negate edgeZ)]
        refused' = [reg edge 0 0, reg (negate edge - 1) 0 0, reg 0 edge 0, reg 0 (negate edge - 1) 0, reg 0 0 edgeZ, reg 0 0 (negate edgeZ - 1), RegionCoord maxBound 0 0, RegionCoord 0 minBound 0]
    forM_ accepted' $ \r → stepOk m0 (q 1 r (cell 0 0 0))
    forM_ refused' $ \r → do
      stepRefused m0 (q 1 r (cell 0 0 0)) `shouldReturn` Invalid (UnsupportedRegion r)
      -- A camera description excludes and reports the key; nothing is loaded for it.
      (_, camera) ← stepOk m0 (SetCameraDemand (ViewId 1) a1 [demand r (cell 0 0 0)])
      case reportDecision camera of
        CameraSet admitted _ _ _ _ excluded _ → (length admitted, excluded) `shouldBe` (0, [r])
        other → expectationFailure (show other)

-- ---------------------------------------------------------------------------

ledgerSpec ∷ Spec
ledgerSpec = describe "separate resident, edit and staging ledgers" $ do
  it "shows each bank before and after reservation, completion and cancellation" $ do
    m0 ← opened tiny
    ledgersOf m0 `shouldBe` Ledgers (0, 0) (0, 0) (0, 0)
    (m1, accepted) ← stepOk m0 (q 1 (reg 0 0 0) (cell 0 0 0))
    admission accepted `shouldBe` Admission [(JobId 0, reg 0 0 0)] [] [] 0
    -- Reserved, not yet occupied: 400 resident, 258 scratch; occupied staging is
    -- the command (160) and the interest (64).
    ledgersOf m1 `shouldBe` Ledgers (0, 400) (0, 0) (224, 258)
    -- A job holds only its reservation until it is dispatched; a load-job slot is
    -- taken at dispatch.
    (slotInUse m1 LoadJobSlot, slotInUse m1 CommandSlot) `shouldBe` (0, 1)
    (m2, _) ← stepOk m1 Dispatch
    ledgersOf m2 `shouldBe` ledgersOf m1
    (slotInUse m2 LoadJobSlot, slotInUse m2 CommandSlot) `shouldBe` (1, 1)
    (m3, done) ← stepOk m2 (JobCompleted (JobId 0) oneCellCost)
    reportDecision done `shouldBe` Published (JobId 0) [OwnerRequest (RequestId 1)]
    ledgersOf m3 `shouldBe` Ledgers (338, 0) (0, 0) (224, 0)
    (slotInUse m3 LoadJobSlot, slotInUse m3 CommandSlot) `shouldBe` (0, 1)
    m4 ← withdraw m3 1
    -- The request is settled; the detail stays resident but unused.
    ledgersOf m4 `shouldBe` Ledgers (338, 0) (0, 0) (0, 0)
    slotInUse m4 CommandSlot `shouldBe` 0
  it "returns the surplus when the data layer stores less than was reserved" $ do
    m0 ← opened tiny
    (m1, _) ← stepOk m0 (q 1 (reg 0 0 0) (cell 0 0 0))
    m2 ← stepsOk m1 [Dispatch, JobCompleted (JobId 0) (Cost 1 1 0)]
    -- 256 + 48 + 32 + 0 occupied; the payload bytes were not needed.
    ledgersOf m2 `shouldBe` Ledgers (336, 0) (0, 0) (224, 0)
  it "charges region metadata for a region holding almost no cells, so vertical regions cannot be free" $ do
    m0 ← opened roomy
    -- Eight regions down one column hold one cell each; each is 338 bytes, the
    -- metadata (256) being most of it.
    m1 ← foldM (\m i → loadCell m i (reg 0 0 (negate i)) (cell 0 0 0) >>= \m' → withdraw m' i) m0 [1 .. 8]
    ledgersOf m1 `shouldBe` Ledgers (8 * 338, 0) (0, 0) (0, 0)

-- ---------------------------------------------------------------------------

fullBankSpec ∷ Spec
fullBankSpec = describe "each bank and slot full independently" $ do
  it "resident bank: busy, with no eligible victim and the reason why" $ do
    m0 ← opened tiny
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0)
    m2 ← loadCell m1 2 (reg 1 0 0) (cell 0 0 0)
    ledgersOf m2 `shouldBe` Ledgers (676, 0) (0, 0) (448, 0)
    -- 324 bytes are free and 400 are needed: 76 short, and both resident regions
    -- are held by an open request.
    r ← stepRefused m2 (q 3 (reg 2 0 0) (cell 0 0 0))
    r `shouldBe` Busy (NoEligibleEviction 76 0 (Blockers 0 0 0 0 2 0 0))
  it "staging bank: busy, naming the bank, its limit, what is in use and what was asked" $ do
    -- 1,250 staging bytes is the tiny configuration's minimum. Each one-cell query
    -- holds 224 occupied (interest 64 + command 160) and 258 reserved scratch.
    m0 ← opened (limitsWith $ \s → s {specStagingBytes = 1250, specResidentBytes = 4000})
    m2 ← foldM (\m i → fst <$> stepOk m (q i (reg i 0 0) (cell 0 0 0))) m0 [1, 2]
    -- 964 in use; 286 free; 482 asked.
    r ← stepRefused m2 (q 3 (reg 3 0 0) (cell 0 0 0))
    r `shouldBe` Busy (BankFull StagingBank 1250 964 482)
  it "job slot: an admitted job waits queued for a slot and is dispatched when one frees" $ do
    m0 ← opened (limitsWith $ \s → s {specLoadJobs = 1, specResidentBytes = 4000})
    m1 ← fst <$> stepOk m0 (q 1 (reg 0 0 0) (cell 0 0 0))
    -- Admission does not need a slot: the second query is admitted and queued.
    (m2, second) ← stepOk m1 (q 2 (reg 1 0 0) (cell 0 0 0))
    jobsOf second `shouldBe` [JobId 1]
    (m3, first) ← stepOk m2 Dispatch
    reportDecision first `shouldBe` Dispatched (JobId 0) (a1, reg 0 0 0) (cell 0 0 0)
    slotInUse m3 LoadJobSlot `shouldBe` 1
    -- The one slot is taken: nothing more is dispatched until the running job completes.
    (m4, none) ← stepOk m3 Dispatch
    reportDecision none `shouldBe` NothingToDispatch
    m5 ← stepsOk m4 [JobCompleted (JobId 0) oneCellCost]
    (_, next) ← stepOk m5 Dispatch
    reportDecision next `shouldBe` Dispatched (JobId 1) (a1, reg 1 0 0) (cell 0 0 0)
  it "command slot: busy even for a request that would need no new job" $ do
    m0 ← opened (limitsWith $ \s → s {specQueuedCommands = 1})
    m1 ← fst <$> stepOk m0 (q 1 (reg 0 0 0) (cell 0 0 0))
    r ← stepRefused m1 (q 2 (reg 0 0 0) (cell 0 0 0))
    r `shouldBe` Busy (SlotFull CommandSlot 1 1 1)
    -- Settling the first command frees the slot.
    m2 ← withdraw m1 1
    _ ← stepOk m2 (q 2 (reg 0 0 0) (cell 0 0 0))
    pure ()
  it "edit bank: outstanding reservations are busy, committed bytes are exhaustion" $ do
    let limits = limitsWith $ \s → s {specEditBytes = 128, specStagingBytes = 4096, specLoadJobs = 3, specResidentBytes = 4000}
    m0 ← opened limits
    (m1, _) ← stepOk m0 (SubmitRemoval (RequestId 1) a1 rev0 (tileAt 0 0 0))
    (m2, _) ← stepOk m1 (SubmitRemoval (RequestId 2) a1 rev0 (tileAt 16 0 0))
    -- Each removal reserves its job (400) and its rebuilt segment's growth (62).
    ledgersOf m2 `shouldBe` Ledgers (0, 2 * (400 + 62)) (0, 128) (2 * (160 + 64), 2 * (258 + 512))
    -- Nothing is committed, so the third removal fits the bank once the others
    -- settle: it is busy, not exhausted.
    r ← stepRefused m2 (SubmitRemoval (RequestId 3) a1 rev0 (tileAt 32 0 0))
    r `shouldBe` Busy (BankFull EditBank 128 128 64)
    m3 ← withdraw m2 1
    _ ← stepOk m3 (SubmitRemoval (RequestId 3) a1 rev0 (tileAt 32 0 0))
    pure ()
  it "rolls back a request that fails in a later bank: no partial interest, job or reservation" $ do
    m0 ← opened tiny
    m1 ← loadCell m0 1 (reg 9 9 9) (cell 0 0 0)
    let two = SubmitQuery (RequestId 2) a1 rev0 [demand (reg i 0 0) (cell 0 0 0) | i ← [0 .. 1]]
    -- Staging and the job slots pass; the resident bank (662 free, 800 needed, the
    -- only resident region held) does not.
    r ← stepRefused m1 two
    r `shouldBe` Busy (NoEligibleEviction 138 0 (Blockers 0 0 0 0 1 0 0))
    length (modelJobs m1) `shouldBe` 0
    length (modelInterests m1) `shouldBe` 1
    -- The moment a bank has room the same request is admitted whole.
    m2 ← withdraw m1 1
    (m3, ok) ← stepOk m2 two
    length (admissionJobs (admission ok)) `shouldBe` 2
    admissionVictims (admission ok) `shouldBe` [(a1, reg 9 9 9)]
    admissionDeferred (admission ok) `shouldBe` 138
    length (modelJobs m3) `shouldBe` 2

-- ---------------------------------------------------------------------------

sharingSpec ∷ Spec
sharingSpec = describe "shared work and coverage" $ do
  it "shares one job between callers asking for the same cells, keeping both interests" $ do
    m0 ← opened tiny
    (m1, first) ← stepOk m0 (q 1 (reg 0 0 0) (cell 0 0 0))
    (m2, second) ← stepOk m1 (q 2 (reg 0 0 0) (cell 0 0 0))
    admissionJobs (admission first) `shouldBe` [(JobId 0, reg 0 0 0)]
    admission second `shouldBe` Admission [] [reg 0 0 0] [] 0
    length (modelJobs m2) `shouldBe` 1
    sort [o | InterestInfo o _ _ _ ← modelInterests m2] `shouldBe` [OwnerRequest (RequestId 1), OwnerRequest (RequestId 2)]
    -- One reservation, two interests and two commands.
    ledgersOf m2 `shouldBe` Ledgers (0, 400) (0, 0) (2 * 224, 258)
  it "grows coverage with a job for the difference only and never fills the cells between" $ do
    m0 ← opened tall
    (m1, _) ← stepOk m0 (q 1 (reg 0 0 0) (cell 0 0 0))
    -- Cells z 0..2 of the same column: only z 1..2 are new.
    (m2, grown) ← stepOk m1 (q 2 (reg 0 0 0) (box 0 1 0 1 0 3))
    admissionJobs (admission grown) `shouldBe` [(JobId 1, reg 0 0 0)]
    map (coverageIntervals . jobCoverage) (modelJobs m2) `shouldBe` [[((0, 0), [(0, 1)])], [((0, 0), [(1, 3)])]]
    -- A disjoint demand in the same region: z 10 only.
    (m3, far) ← stepOk m2 (q 3 (reg 0 0 0) (cell 0 0 10))
    admissionJobs (admission far) `shouldBe` [(JobId 2, reg 0 0 0)]
    -- All three run before any reports; the first to report makes the region
    -- resident, so metadata is charged once.
    m4 ← stepsOk m3 [Dispatch, Dispatch, Dispatch, JobCompleted (JobId 0) oneCellCost, JobCompleted (JobId 1) (Cost 0 1 4), JobCompleted (JobId 2) (Cost 0 1 2)]
    case modelRegions m4 of
      [region] → do
        coverageIntervals (regionCoverage region) `shouldBe` [((0, 0), [(0, 3), (10, 11)])]
        coverageCells (regionCoverage region) `shouldBe` 4
        -- 338 for the first job, then 32 + 4 and 32 + 2.
        regionBytes region `shouldBe` 338 + 36 + 34
      other → expectationFailure ("expected one region, got " <> show other)
  it "funds each job's own column, so cancelling or reordering another job never leaves it short" $ do
    -- Two cells of one initially absent column: each job reserves its own column
    -- entry, metadata, segment and payload bound (400), none depends on the other.
    m0 ← opened tall
    m1 ← stepsOk m0 [q 1 (reg 0 0 0) (cell 0 0 0), q 2 (reg 0 0 0) (cell 0 0 5)]
    map jobActive (modelJobs m1) `shouldBe` [400, 400]
    -- The first caller leaves; the surviving job still stores a valid one-cell
    -- result (338 bytes) within its own reservation.
    m2 ← stepsOk m1 [Withdraw (RequestId 1), Dispatch]
    (m3, done) ← stepOk m2 (JobCompleted (JobId 1) oneCellCost)
    reportDecision done `shouldBe` Published (JobId 1) [OwnerRequest (RequestId 2)]
    map regionBytes (modelRegions m3) `shouldBe` [338]
    -- And the other completion order, with no caller leaving.
    m4 ← stepsOk m1 [Dispatch, Dispatch]
    m5 ← stepsOk m4 [JobCompleted (JobId 1) oneCellCost, JobCompleted (JobId 0) oneCellCost]
    -- Two cells of one column: the column entry is charged once, with two segments.
    map regionBytes (modelRegions m5) `shouldBe` [338 + 34]
  it "keeps jobs apart across arena incarnations and content revisions" $ do
    m0 ← opened roomy
    (m1, _) ← stepOk m0 (OpenArena a2 rev0)
    (m2, _) ← stepOk m1 (q 1 (reg 0 0 0) (cell 0 0 0))
    (m3, other) ← stepOk m2 (SubmitQuery (RequestId 2) a2 rev0 [demand (reg 0 0 0) (cell 0 0 0)])
    admissionJobs (admission other) `shouldBe` [(JobId 1, reg 0 0 0)]
    sort (map jobArena (modelJobs m3)) `shouldBe` [a1, a2]
    -- A request naming a revision the arena has left is stale, not merged.
    r ← stepRefused m3 (SubmitQuery (RequestId 3) a1 (Revision 5) [demand (reg 0 0 0) (cell 0 0 0)])
    r `shouldBe` Stale (RevisionMismatch rev0 (Revision 5))

-- ---------------------------------------------------------------------------

cancellationSpec ∷ Spec
cancellationSpec = describe "cancellation and late results" $ do
  it "keeps a shared job when one caller cancels and releases it with the last" $ do
    m0 ← opened tiny
    m1 ← stepsOk m0 [q 1 (reg 0 0 0) (cell 0 0 0), q 2 (reg 0 0 0) (cell 0 0 0), Dispatch]
    (m2, one) ← stepOk m1 (Withdraw (RequestId 1))
    reportDecision one `shouldBe` Withdrawn [] []
    length (modelJobs m2) `shouldBe` 1
    -- Running work another still needs keeps its whole reservation.
    ledgersOf m2 `shouldBe` Ledgers (0, 400) (0, 0) (224, 258)
    (m3, last') ← stepOk m2 (Withdraw (RequestId 2))
    -- Nobody needs it, but it is running: its resident reservation and scratch
    -- stay until it acknowledges.
    reportDecision last' `shouldBe` Withdrawn [] [JobId 0]
    ledgersOf m3 `shouldBe` Ledgers (0, 400) (0, 0) (0, 258)
    map jobPhase (modelJobs m3) `shouldBe` [JobCancellingPhase]
    -- A late result for the withdrawn demand is dropped and publishes nothing.
    (m4, late) ← stepOk m3 (JobCompleted (JobId 0) oneCellCost)
    reportDecision late `shouldBe` Discarded (JobId 0)
    ledgersOf m4 `shouldBe` Ledgers (0, 0) (0, 0) (0, 0)
    modelRegions m4 `shouldBe` []
    -- And a second report for the same job is stale.
    stepRefused m4 (JobCompleted (JobId 0) oneCellCost) `shouldReturn` Stale (UnknownJob (JobId 0))
  it "releases a queued job's credits at once when its last interest cancels" $ do
    m0 ← opened tiny
    m1 ← fst <$> stepOk m0 (q 1 (reg 0 0 0) (cell 0 0 0))
    (m2, gone) ← stepOk m1 (Withdraw (RequestId 1))
    reportDecision gone `shouldBe` Withdrawn [JobId 0] []
    ledgersOf m2 `shouldBe` Ledgers (0, 0) (0, 0) (0, 0)
    slotInUse m2 LoadJobSlot `shouldBe` 0
  it "does not let a cancelling job's result reinstate demand or steal another job's reservation" $ do
    m0 ← opened tiny
    m1 ← stepsOk m0 [q 1 (reg 0 0 0) (cell 0 0 0), Dispatch, Withdraw (RequestId 1)]
    -- A new caller for the same cells does not share the cancelling job.
    (m2, fresh) ← stepOk m1 (q 2 (reg 0 0 0) (cell 0 0 0))
    admissionJobs (admission fresh) `shouldBe` [(JobId 1, reg 0 0 0)]
    ledgersOf m2 `shouldBe` Ledgers (0, 800) (0, 0) (224, 516)
    -- The old job reports first; its result is dropped.
    (m3, dropped) ← stepOk m2 (JobCompleted (JobId 0) oneCellCost)
    reportDecision dropped `shouldBe` Discarded (JobId 0)
    modelRegions m3 `shouldBe` []
    ledgersOf m3 `shouldBe` Ledgers (0, 400) (0, 0) (224, 258)
    map jobId (modelJobs m3) `shouldBe` [JobId 1]
  it "treats a failed job as nothing stored and drops only the interests it served" $ do
    m0 ← opened tiny
    m1 ← stepsOk m0 [q 1 (reg 0 0 0) (cell 0 0 0), Dispatch]
    (m2, failed) ← stepOk m1 (JobFailed (JobId 0))
    reportDecision failed `shouldBe` JobFailedFor (JobId 0) [OwnerRequest (RequestId 1)] [] []
    ledgersOf m2 `shouldBe` Ledgers (0, 0) (0, 0) (160, 0)
    modelInterests m2 `shouldBe` []
  it "acknowledges a cancelled running job and refuses an acknowledgement of live work" $ do
    m0 ← opened tiny
    m1 ← stepsOk m0 [q 1 (reg 0 0 0) (cell 0 0 0), Dispatch]
    stepRefused m1 (JobAcknowledged (JobId 0)) `shouldReturn` ContractFailure (JobNotCancelling (JobId 0))
    m2 ← stepsOk m1 [Withdraw (RequestId 1)]
    (m3, acked) ← stepOk m2 (JobAcknowledged (JobId 0))
    reportDecision acked `shouldBe` Discarded (JobId 0)
    ledgersOf m3 `shouldBe` Ledgers (0, 0) (0, 0) (0, 0)

-- ---------------------------------------------------------------------------

fundedEvictionSpec ∷ Spec
fundedEvictionSpec = describe "admission funded by a committed eviction" $ do
  it "is accepted whole, waits only for the victim's release and is never refused afterwards" $ do
    m0 ← opened tiny
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0)
    m2 ← loadCell m1 2 (reg 1 0 0) (cell 0 0 0)
    m3 ← withdraw m2 1 >>= \m → withdraw m 2
    ledgersOf m3 `shouldBe` Ledgers (676, 0) (0, 0) (0, 0)
    -- 324 free, 400 needed: 324 is funded now, 76 by the least recently used
    -- region, which is committed as a victim in this same step.
    (m4, accepted) ← stepOk m3 (q 3 (reg 2 0 0) (cell 0 0 0))
    admission accepted `shouldBe` Admission [(JobId 2, reg 2 0 0)] [] [(a1, reg 0 0 0)] 76
    ledgersOf m4 `shouldBe` Ledgers (676, 324) (0, 0) (224, 258)
    map jobPhase (modelJobs m4) `shouldBe` [JobWaiting]
    (jobActive <$> jobFor m4 (reg 2 0 0), jobDeferred <$> jobFor m4 (reg 2 0 0)) `shouldBe` (Just 324, Just 76)
    -- Nothing can be dispatched before the release.
    (_, none) ← stepOk m4 Dispatch
    reportDecision none `shouldBe` NothingToDispatch
    -- A committed victim cannot regain an interest or a hold.
    stepRefused m4 (q 4 (reg 0 0 0) (cell 0 0 0)) `shouldReturn` Busy (RegionEvicting (reg 0 0 0))
    stepRefused m4 (AcquireHold (HoldId 1) a1 Borrow [reg 0 0 0]) `shouldReturn` Stale (NotResident (reg 0 0 0))
    -- The release arrives later: the credit moves to the job and it is queued.
    (m5, released) ← stepOk m4 (VictimReleased a1 (reg 0 0 0))
    reportDecision released `shouldBe` VictimFreed
    reportFunded released `shouldBe` [JobId 2]
    ledgersOf m5 `shouldBe` Ledgers (338, 400) (0, 0) (224, 258)
    map jobPhase (modelJobs m5) `shouldBe` [JobQueued]
    (_, next) ← stepOk m5 Dispatch
    reportDecision next `shouldBe` Dispatched (JobId 2) (a1, reg 2 0 0) (cell 0 0 0)
  it "never promises a victim's bytes twice when several jobs of one admission share it" $ do
    -- V1 holds two cells in two columns (338 + 82 = 420 bytes), V2 one cell (338), and
    -- a pinned region P (338): 1,096 resident of 1,416 (the least this configuration
    -- allows), so 320 are free.
    m0 ← opened (limitsWith $ \s → s {specResidentBytes = 1416, specStagingBytes = 4096, specExtentX = 2, specQueuedCommands = 8})
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0)
    (m2, extra) ← stepOk m1 (q 2 (reg 0 0 0) (cell 1 0 0))
    jobsOf extra `shouldBe` [JobId 1]
    m3 ← stepsOk m2 [Dispatch, JobCompleted (JobId 1) (Cost 1 1 2)]
    m4 ← loadCell m3 3 (reg 1 0 0) (cell 0 0 0)
    m4' ← loadCell m4 5 (reg 4 0 0) (cell 0 0 0)
    m5 ← foldM withdraw m4' [1, 2, 3]
    ledgersOf m5 `shouldBe` Ledgers (1096, 0) (0, 0) (224, 0)
    -- Two 400-byte jobs: 320 free covers part of the first; the rest, 80 and 400,
    -- is 480 bytes. V1 (the older) gives 420 in all (80 to the first job and 340 to
    -- the second), so V2 gives the other 60: both are victims, and no byte is
    -- promised to two jobs.
    let two = SubmitQuery (RequestId 4) a1 rev0 [demand (reg 2 0 0) (cell 0 0 0), demand (reg 3 0 0) (cell 0 0 0)]
    (m6, accepted) ← stepOk m5 two
    admission accepted `shouldBe` Admission [(JobId 4, reg 2 0 0), (JobId 5, reg 3 0 0)] [] [(a1, reg 0 0 0), (a1, reg 1 0 0)] 480
    ledgersOf m6 `shouldBe` Ledgers (1096, 320) (0, 0) (224 + 320, 2 * 258)
    -- V1's release funds the first job and part of the second; the second job
    -- is queued only when V2 has been released too.
    (m7, firstRelease) ← stepOk m6 (VictimReleased a1 (reg 0 0 0))
    reportFunded firstRelease `shouldBe` [JobId 4]
    ledgersOf m7 `shouldBe` Ledgers (676, 740) (0, 0) (224 + 320, 516)
    (m8, secondRelease) ← stepOk m7 (VictimReleased a1 (reg 1 0 0))
    reportFunded secondRelease `shouldBe` [JobId 5]
    ledgersOf m8 `shouldBe` Ledgers (338, 800) (0, 0) (224 + 320, 516)
  it "keeps a committed victim evicting when the admission it funded is cancelled" $ do
    m0 ← opened tiny
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0)
    m2 ← loadCell m1 2 (reg 1 0 0) (cell 0 0 0)
    m3 ← withdraw m2 1 >>= \m → withdraw m 2
    m4 ← fst <$> stepOk m3 (q 3 (reg 2 0 0) (cell 0 0 0))
    (m5, _) ← stepOk m4 (Withdraw (RequestId 3))
    ledgersOf m5 `shouldBe` Ledgers (676, 0) (0, 0) (0, 0)
    [e | e ← modelRegions m5, regionEvicting e] `shouldSatisfy` ((== 1) . length)
    (m6, freed) ← stepOk m5 (VictimReleased a1 (reg 0 0 0))
    reportFunded freed `shouldBe` []
    ledgersOf m6 `shouldBe` Ledgers (338, 0) (0, 0) (0, 0)
    -- A release nobody asked for is stale.
    stepRefused m6 (VictimReleased a1 (reg 0 0 0)) `shouldReturn` Stale (NotEvicting (reg 0 0 0))

-- ---------------------------------------------------------------------------

lruSpec ∷ Spec
lruSpec = describe "least-recently-used selection" $ do
  it "skips a held region and a region in use, and chooses the oldest of the rest" $ do
    -- (1,302 resident bytes: the 964 an explicit request may need stay unpinned, so a
    -- hold may pin 338 of them.)
    let limits = limitsWith $ \s → s {specResidentBytes = 1302, specStagingBytes = 4096}
    m0 ← opened limits
    -- B is loaded first and held, so B is the oldest and must be skipped.
    mB ← loadCell m0 1 (reg 1 0 0) (cell 0 0 0)
    (mHeld, _) ← stepOk mB (AcquireHold (HoldId 1) a1 Borrow [reg 1 0 0])
    mA ← loadCell mHeld 2 (reg 0 0 0) (cell 0 0 0)
    mC ← loadCell mA 3 (reg 2 0 0) (cell 0 0 0)
    -- A and B and C are all resident (1,014 of 1,302); settle A's and B's
    -- requests; C's request stays open, so C is in use.
    mFree ← withdraw mC 1 >>= \m → withdraw m 2
    ledgersOf mFree `shouldBe` Ledgers (1014, 0) (0, 0) (64 + 160 + 64, 0)
    -- 288 free, 400 needed: 112 from victims. B is oldest but held, C is in use,
    -- so A is the only candidate.
    (_, accepted) ← stepOk mFree (q 4 (reg 3 0 0) (cell 0 0 0))
    admissionVictims (admission accepted) `shouldBe` [(a1, reg 0 0 0)]
    admissionDeferred (admission accepted) `shouldBe` 112
  it "touches a region when a new interest reuses it, moving it to the back" $ do
    let limits = limitsWith $ \s → s {specResidentBytes = 1100, specStagingBytes = 4096}
    m0 ← opened limits
    mA ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0) >>= \m → withdraw m 1
    mB ← loadCell mA 2 (reg 1 0 0) (cell 0 0 0) >>= \m → withdraw m 2
    mC ← loadCell mB 3 (reg 2 0 0) (cell 0 0 0) >>= \m → withdraw m 3
    -- Re-using A (no new job) makes B the oldest.
    (mReuse, reuse) ← stepOk mC (q 4 (reg 0 0 0) (cell 0 0 0))
    admissionShared (admission reuse) `shouldBe` [reg 0 0 0]
    mTouched ← withdraw mReuse 4
    (_, accepted) ← stepOk mTouched (q 5 (reg 3 0 0) (cell 0 0 0))
    admissionVictims (admission accepted) `shouldBe` [(a1, reg 1 0 0)]
  it "evicts old regions one at a time, in order, as demand moves" $ do
    let limits = limitsWith $ \s → s {specResidentBytes = 1100, specStagingBytes = 4096}
    m0 ← opened limits
    m1 ← foldM (\m i → loadCell m i (reg i 0 0) (cell 0 0 0) >>= \m' → withdraw m' i) m0 [1, 2, 3]
    -- Demand for regions 4, 5 and 6 evicts 1, 2 and 3 in that order.
    (_, victims) ← foldM
      ( \(m, acc) i → do
          (m', accepted) ← stepOk m (q i (reg i 0 0) (cell 0 0 0))
          j ← onlyJob accepted
          let vs = admissionVictims (admission accepted)
          m'' ← foldM (\mm v → fst <$> stepOk mm (VictimReleased (fst v) (snd v))) m' vs
          m''' ← stepsOk m'' [Dispatch, JobCompleted j oneCellCost]
          mW ← withdraw m''' i
          pure (mW, acc <> vs)
      )
      (m1, [])
      [4, 5, 6]
    victims `shouldBe` [(a1, reg 1 0 0), (a1, reg 2 0 0), (a1, reg 3 0 0)]

descentSpec ∷ Spec
descentSpec = describe "bounded residency in both directions" $ do
  it "turns old vertical regions over in one column under fixed caps" $ do
    -- Room for two resident regions (676 stored of 964 bytes, and a third job's
    -- 400 reserved does not fit beside them).
    let limits = limitsWith $ \s → s {specResidentBytes = 964}
    m0 ← opened limits
    (final, evicted, peak) ← foldM
      ( \(m, ev, pk) i → do
          (m1, accepted) ← stepOk m (q i (reg 0 0 (negate i)) (cell 0 0 0))
          j ← onlyJob accepted
          let vs = admissionVictims (admission accepted)
          m2 ← foldM (\mm v → fst <$> stepOk mm (VictimReleased (fst v) (snd v))) m1 vs
          m3 ← stepsOk m2 [Dispatch, JobCompleted j oneCellCost]
          m4 ← withdraw m3 i
          let resident = length (modelRegions m4)
          pure (m4, ev <> map snd vs, max pk resident)
      )
      (m0, [], 0)
      [1 .. 10]
    peak `shouldBe` 2
    evicted `shouldBe` [reg 0 0 (negate i) | i ← [1 .. 8]]
    sort (map regionCoord (modelRegions final)) `shouldBe` sort [reg 0 0 (-9), reg 0 0 (-10)]
    ledgersOf final `shouldBe` Ledgers (676, 0) (0, 0) (0, 0)
  it "turns old columns over as travel moves horizontally" $ do
    let limits = limitsWith $ \s → s {specResidentBytes = 964}
    m0 ← opened limits
    final ← foldM
      ( \m i → do
          (m1, accepted) ← stepOk m (q i (reg i 0 0) (cell 0 0 0))
          j ← onlyJob accepted
          let vs = admissionVictims (admission accepted)
          m2 ← foldM (\mm v → fst <$> stepOk mm (VictimReleased (fst v) (snd v))) m1 vs
          m3 ← stepsOk m2 [Dispatch, JobCompleted j oneCellCost]
          withdraw m3 i
      )
      m0
      [1 .. 12]
    sort (map regionCoord (modelRegions final)) `shouldBe` [reg 11 0 0, reg 12 0 0]

-- ---------------------------------------------------------------------------

holdSpec ∷ Spec
holdSpec = describe "borrowed data and pinned view revisions" $ do
  it "never selects a held region and says so" $ do
    -- 1,302 resident bytes: a hold may pin 338 of them. A held region, and two
    -- regions pinned by open requests, fill all but 288.
    m0 ← opened (limitsWith $ \s → s {specResidentBytes = 1302})
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0) >>= \m → withdraw m 1
    m1' ← loadCell m1 3 (reg 2 0 0) (cell 0 0 0)
    m1'' ← loadCell m1' 4 (reg 3 0 0) (cell 0 0 0)
    (m2, _) ← stepOk m1'' (AcquireHold (HoldId 1) a1 Borrow [reg 0 0 0])
    -- The hold costs 64 staging bytes and protects the region from eviction; the
    -- others are pinned by their open requests (224 staging bytes each).
    ledgersOf m2 `shouldBe` Ledgers (1014, 0) (0, 0) (64 + 448, 0)
    -- 288 free; a 400-byte job is 112 short and no resident region may be taken.
    r ← stepRefused m2 (q 2 (reg 1 0 0) (cell 0 0 0))
    r `shouldBe` Busy (NoEligibleEviction 112 0 (Blockers 0 0 0 1 2 0 0))
    -- Released, the same region becomes the victim.
    m3 ← fst <$> stepOk m2 (ReleaseHold (HoldId 1))
    (_, accepted) ← stepOk m3 (q 2 (reg 1 0 0) (cell 0 0 0))
    admissionVictims (admission accepted) `shouldBe` [(a1, reg 0 0 0)]
  it "limits pinned view revisions per view and counts them independently" $ do
    m0 ← opened roomy
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0)
    m2 ← stepsOk m1 [AcquireHold (HoldId 1) a1 (Pin (ViewId 1)) [reg 0 0 0], AcquireHold (HoldId 2) a1 (Pin (ViewId 1)) [reg 0 0 0]]
    viewPins m2 (ViewId 1) `shouldBe` 2
    r ← stepRefused m2 (AcquireHold (HoldId 3) a1 (Pin (ViewId 1)) [reg 0 0 0])
    r `shouldBe` Busy (SlotFull ViewPinSlot 2 2 1)
    -- Another view has its own two; a plain borrow is not a pin.
    m3 ← stepsOk m2 [AcquireHold (HoldId 3) a1 (Pin (ViewId 2)) [reg 0 0 0], AcquireHold (HoldId 4) a1 Borrow [reg 0 0 0]]
    viewPins m3 (ViewId 2) `shouldBe` 1
    m4 ← fst <$> stepOk m3 (ReleaseHold (HoldId 1))
    _ ← stepOk m4 (AcquireHold (HoldId 5) a1 (Pin (ViewId 1)) [reg 0 0 0])
    stepRefused m4 (ReleaseHold (HoldId 1)) `shouldReturn` Stale (UnknownHold (HoldId 1))
  it "refuses a hold on detail that is not resident, and a duplicate hold" $ do
    m0 ← opened roomy
    stepRefused m0 (AcquireHold (HoldId 1) a1 Borrow [reg 0 0 0]) `shouldReturn` Stale (NotResident (reg 0 0 0))
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0)
    m2 ← fst <$> stepOk m1 (AcquireHold (HoldId 1) a1 Borrow [reg 0 0 0])
    stepRefused m2 (AcquireHold (HoldId 1) a1 Borrow [reg 0 0 0]) `shouldReturn` Invalid (DuplicateHold (HoldId 1))

-- ---------------------------------------------------------------------------

cameraSpec ∷ Spec
cameraSpec = describe "camera demand is latest-value state" $ do
  it "survives a replacement storm with one description and only the last interests" $ do
    m0 ← opened roomy
    -- View 2 keeps an interest in region 1 throughout.
    m1 ← fst <$> stepOk m0 (SetCameraDemand (ViewId 2) a1 [demand (reg 1 0 0) (cell 0 0 0)])
    final ← foldM
      ( \m i → fst <$> stepOk m (SetCameraDemand (ViewId 1) a1 [demand (reg i 0 0) (cell 0 0 0), demand (reg (i + 1) 0 0) (cell 0 0 0)])
      )
      m1
      [1 .. 40]
    -- View 1 names regions 40 and 41; view 2 still names region 1.
    sort [(o, r) | InterestInfo o _ r _ ← modelInterests final]
      `shouldBe` sort [(OwnerView (ViewId 1), reg 40 0 0), (OwnerView (ViewId 1), reg 41 0 0), (OwnerView (ViewId 2), reg 1 0 0)]
    -- Each job that survived is the one created when its region first appeared:
    -- region k + 1 got job k at replacement k.
    sort [(jobRegion j, jobId j) | j ← modelJobs final]
      `shouldBe` sort [(reg 1 0 0, JobId 0), (reg 40 0 0, JobId 39), (reg 41 0 0, JobId 40)]
    -- Staging holds one description per view (256 and 192), three interests and
    -- three scratch reservations; nothing from the 39 replaced demands.
    ledgersOf final `shouldBe` Ledgers (0, 3 * 400) (0, 0) (256 + 192 + 3 * 64, 3 * 258)
    map viewPending (modelViews final) `shouldBe` [[], []]
  it "replaces a view's demand without touching the other views' interests or shared work" $ do
    m0 ← opened roomy
    m1 ← stepsOk m0 [SetCameraDemand (ViewId 1) a1 [demand (reg 0 0 0) (cell 0 0 0)], SetCameraDemand (ViewId 2) a1 [demand (reg 0 0 0) (cell 0 0 0)]]
    length (modelJobs m1) `shouldBe` 1
    (m2, replaced) ← stepOk m1 (SetCameraDemand (ViewId 1) a1 [demand (reg 5 0 0) (cell 0 0 0)])
    -- The shared job survives for view 2; view 1 has a job of its own.
    case reportDecision replaced of
      CameraSet _ waiting withdrawn cancelled awaiting _ _ → (waiting, withdrawn, cancelled, awaiting) `shouldBe` ([], [reg 0 0 0], [], [])
      other → expectationFailure (show other)
    sort (map jobRegion (modelJobs m2)) `shouldBe` [reg 0 0 0, reg 5 0 0]
  it "admits what fits, keeps the rest as coalesced pending demand and reserves nothing for it" $ do
    -- 964 resident bytes hold two 400-byte jobs; four regions are named.
    m0 ← opened (limitsWith $ \x → x {specResidentBytes = 964, specStagingBytes = 8192})
    let four = [demand (reg i 0 0) (cell 0 0 0) | i ← [0 .. 3]]
    (m1, set) ← stepOk m0 (SetCameraDemand (ViewId 1) a1 four)
    case reportDecision set of
      CameraSet admitted waiting _ _ _ _ _ → (length admitted, waiting) `shouldBe` (2, [reg 2 0 0, reg 3 0 0])
      other → expectationFailure (show other)
    -- The unadmitted regions hold no job, interest or reservation.
    ledgersOf m1 `shouldBe` Ledgers (0, 2 * 400) (0, 0) (128 + 4 * 64 + 2 * 64, 2 * 258)
    map viewPending (modelViews m1) `shouldBe` [[reg 2 0 0, reg 3 0 0]]
    -- Pending demand is retried on a service quantum, and only when there is room.
    (m2, idle) ← stepOk m1 Service
    reportDecision idle `shouldBe` Serviced []
    m3 ← stepsOk m2 [Dispatch, JobCompleted (JobId 0) oneCellCost]
    (_, still) ← stepOk m3 Service
    reportDecision still `shouldBe` Serviced []
  it "cuts the end of a description that does not fit the camera's staging, reports it and still serves the rest" $ do
    -- 2,000 staging bytes, of which camera work leaves 994 for explicit requests: the
    -- view's 192-byte description, its interest (64) and the region job's scratch (258)
    -- are 514; an open request holds 482 more, which leaves camera work 10.
    m0 ← opened (limitsWith $ \s → s {specStagingBytes = 2000, specResidentBytes = 4000, specLoadJobs = 5})
    m1 ← fst <$> stepOk m0 (SetCameraDemand (ViewId 1) a1 [demand (reg 0 0 0) (cell 0 0 0)])
    ledgersOf m1 `shouldBe` Ledgers (0, 400) (0, 0) (192 + 64, 258)
    (m2, _) ← stepOk m1 (q 1 (reg 5 0 0) (cell 0 0 0))
    ledgersOf m2 `shouldBe` Ledgers (0, 800) (0, 0) (256 + 224, 516)
    -- A description of two regions needs 256 bytes, 64 more than is held; the camera
    -- may use 10 more, so the second region is cut (the lowest priority), reported, and
    -- the first keeps being served: the description stays one region.
    (m3, replaced) ← stepOk m2 (SetCameraDemand (ViewId 1) a1 [demand (reg 0 0 0) (cell 0 0 0), demand (reg 1 0 0) (cell 0 0 0)])
    case reportDecision replaced of
      CameraSet _ _ _ _ _ excluded truncated → (excluded, truncated) `shouldBe` ([], [reg 1 0 0])
      other → expectationFailure (show other)
    map (map demandRegion . viewDemand) (modelViews m3) `shouldBe` [[reg 0 0 0]]
  it "ignores a late failure of work a commit superseded, and keeps the replacement work" $ do
    m0 ← opened roomy2
    -- A camera load is running when a removal commits in its region.
    m1 ← stepsOk m0 [SetCameraDemand (ViewId 1) a1 [demand (reg 0 0 0) (cell 0 0 0)], Dispatch]
    (m2, _) ← stepOk m1 (SubmitRemoval (RequestId 1) a1 rev0 (tileAt 0 0 1))
    m3 ← stepsOk m2 [Dispatch, JobCompleted (JobId 1) oneCellCost]
    (m4, committed) ← stepOk m3 (RemovalCommitted (RequestId 1) (Revision 1) 64 0)
    reportDecision committed `shouldBe` Committed (Revision 1) 0 [OwnerView (ViewId 1)] [] [JobId 0]
    -- The next service quantum admits replacement work at the new revision.
    (m5, serviced) ← stepOk m4 Service
    case reportDecision serviced of
      Serviced [(ViewId 1, replacement)] → map snd (admissionJobs replacement) `shouldBe` [reg 0 0 0]
      other → expectationFailure (show other)
    -- The original job fails late: nothing of the current demand is touched.
    (m6, late) ← stepOk m5 (JobFailed (JobId 0))
    reportDecision late `shouldBe` Discarded (JobId 0)
    map viewFailed (modelViews m6) `shouldBe` [[]]
    map jobPhase (modelJobs m6) `shouldBe` [JobQueued]
    [interestOwner i | i ← modelInterests m6] `shouldBe` [OwnerView (ViewId 1)]
    -- And a late completion of superseded work is dropped the same way.
    m7 ← stepsOk m5 [JobFailed (JobId 0)]
    (_, none) ← stepOk m7 Service
    reportDecision none `shouldBe` Serviced []
  it "accepts the owner's cancellation acknowledgement of work a commit superseded" $ do
    m0 ← opened roomy2
    m1 ← stepsOk m0 [SetCameraDemand (ViewId 1) a1 [demand (reg 0 0 0) (cell 0 0 0)], Dispatch]
    (m2, _) ← stepOk m1 (SubmitRemoval (RequestId 1) a1 rev0 (tileAt 0 0 1))
    m3 ← stepsOk m2 [Dispatch, JobCompleted (JobId 1) oneCellCost]
    (m4, committed) ← stepOk m3 (RemovalCommitted (RequestId 1) (Revision 1) 64 0)
    -- The commit reports the running job; it is cancelling, still holding its slot,
    -- scratch and reservation until the owner acknowledges.
    reportDecision committed `shouldBe` Committed (Revision 1) 0 [OwnerView (ViewId 1)] [] [JobId 0]
    map jobPhase (modelJobs m4) `shouldBe` [JobCancellingPhase]
    -- (Staging holds the view's 192-byte description and its 64-byte interest.)
    ledgersOf m4 `shouldBe` Ledgers (338, 400) (64, 0) (256, 258)
    (m5, acked) ← stepOk m4 (JobAcknowledged (JobId 0))
    reportDecision acked `shouldBe` Discarded (JobId 0)
    modelJobs m5 `shouldBe` []
    ledgersOf m5 `shouldBe` Ledgers (338, 0) (64, 0) (256, 0)
  it "completes a demand of mixed sizes in either order" $ do
    -- Extent 2 x 1 x 1. A: one cell (reserves 400, stores 338). B: two cells in two
    -- columns (reserves 256 + 96 + 64 + 128 = 544, stores 420). Two regions of this
    -- extent need 2 x (420 + 288) = 1,416 resident bytes at the least.
    let regionA = demand (reg 0 0 0) (cell 0 0 0)
        regionB = demand (reg 1 0 0) (coverageUnion (cell 0 0 0) (cell 1 0 0))
        costB = Cost 2 2 4
        mixed = limitsWith $ \x → x {specResidentBytes = 1416, specStagingBytes = 4096, specLoadJobs = 4, specExtentX = 2}
    forM_ [([regionA, regionB], [oneCellCost, costB]), ([regionB, regionA], [costB, oneCellCost])] $ \(order, costs) → do
      m0 ← opened mixed
      (m1, set) ← stepOk m0 (SetCameraDemand (ViewId 1) a1 order)
      case reportDecision set of
        CameraSet admitted waiting _ _ _ _ _ → (length admitted, waiting) `shouldBe` (2, [])
        other → expectationFailure (show other)
      m2 ← stepsOk m1 (Dispatch : Dispatch : [JobCompleted (JobId (fromIntegral i)) c | (i, c) ← zip [0 ∷ Int ..] costs])
      sum (map regionBytes (modelRegions m2)) `shouldBe` 420 + 338
      map viewPending (modelViews m2) `shouldBe` [[]]
  it "admits regions strictly in demand order, so a later region never takes room an earlier one needs" $ do
    -- Extent 2 x 1 x 4, three regions per demand: a region stores at most 496 and a
    -- job reserves at most 480 more, so the bank holds 3 x 976 = 2,928 at the least.
    -- Five unrelated regions are pinned (5 x 338 = 1,690), leaving 1,238. A (two
    -- columns) reserves 544, leaving 694; B (two intervals in each column) reserves
    -- 256 + 96 + 4 x 96 = 736 and must wait; C (one cell, 400) would fit the 694 but
    -- may not take room B is waiting for.
    let a' = demand (reg 10 0 0) (coverageUnion (cell 0 0 0) (cell 1 0 0))
        b' = demand (reg 11 0 0) (foldr1 coverageUnion [cell x 0 z | x ← [0, 1], z ← [0, 2]])
        c' = demand (reg 12 0 0) (cell 0 0 0)
        limits = limitsWith $ \x → x {specResidentBytes = 2928, specStagingBytes = 4096, specLoadJobs = 4, specQueuedCommands = 8, specExtentX = 2, specExtentZ = 4}
    m0 ← opened limits
    pinned ← foldM (\m i → loadCell m i (reg i 0 0) (cell 0 0 0)) m0 [1 .. 5]
    (m1, set) ← stepOk pinned (SetCameraDemand (ViewId 1) a1 [a', b', c'])
    case reportDecision set of
      CameraSet admitted waiting _ _ _ _ _ → (length admitted, waiting) `shouldBe` (1, [reg 11 0 0, reg 12 0 0])
      other → expectationFailure (show other)
    [jobRegion j | j ← modelJobs m1] `shouldBe` [reg 10 0 0]
    -- A service quantum keeps the order too: C fits the room that is left but may not
    -- be admitted ahead of B.
    (m1', idle) ← stepOk m1 Service
    reportDecision idle `shouldBe` Serviced []
    [jobRegion j | j ← modelJobs m1'] `shouldBe` [reg 10 0 0]
    -- Release the pins and let the owner finish everything: the whole demand completes.
    m2 ← foldM withdraw m1' [1 .. 5]
    m3 ← drainDemand m2
    map viewPending (modelViews m3) `shouldBe` [[]]
    sort [regionCoord r | r ← modelRegions m3, regionCoord r `elem` [reg 10 0 0, reg 11 0 0, reg 12 0 0]] `shouldBe` [reg 10 0 0, reg 11 0 0, reg 12 0 0]
  it "waits, rather than failing, when what a replacement retains leaves too little room, and completes once room appears" $ do
    -- 1,000 resident bytes: A is resident (338) and view 1 keeps it pinned; another
    -- request pins a second region (338), leaving 324 free. Replacing the demand with
    -- [A, B] needs B's 400-byte job: B waits, holds nothing, and A is kept.
    let regionA = demand (reg 0 0 0) (cell 0 0 0)
        regionB = demand (reg 1 0 0) (cell 0 0 0)
    m0 ← opened tiny
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0) >>= \m → withdraw m 1
    m2 ← fst <$> stepOk m1 (SetCameraDemand (ViewId 1) a1 [regionA])
    m2' ← loadCell m2 2 (reg 2 0 0) (cell 0 0 0)
    (m3, set) ← stepOk m2' (SetCameraDemand (ViewId 1) a1 [regionA, regionB])
    case reportDecision set of
      CameraSet admitted waiting _ _ _ _ _ → (map admissionShared admitted, waiting) `shouldBe` ([[reg 0 0 0]], [reg 1 0 0])
      other → expectationFailure (show other)
    map viewPending (modelViews m3) `shouldBe` [[reg 1 0 0]]
    -- Once the other request lets go, its region is evicted for B and the demand completes.
    m4 ← withdraw m3 2
    m5 ← drainDemand m4
    map viewPending (modelViews m5) `shouldBe` [[]]
  it "keeps a replacement stageable at the minimum staging bank: the interests it retains are counted" $ do
    -- 1,636 staging bytes: 994 stay free for explicit requests and 642 are the camera's.
    -- View 1 holds B and its 192-byte description; replacing the demand with [A, B] keeps
    -- B's 64-byte interest, holds a 256-byte description, takes A's interest and 258
    -- bytes of scratch: 256 + 2 x 64 + 258 = 642, which fits and completes rather than
    -- stalling.
    let regionA = demand (reg 0 0 0) (cell 0 0 0)
        regionB = demand (reg 1 0 0) (cell 0 0 0)
        minimal = limitsWith $ \x → x {specStagingBytes = 1636}
    m0 ← opened minimal
    m1 ← loadCell m0 1 (reg 1 0 0) (cell 0 0 0) >>= \m → withdraw m 1
    m2 ← fst <$> stepOk m1 (SetCameraDemand (ViewId 1) a1 [regionB])
    (m3, set) ← stepOk m2 (SetCameraDemand (ViewId 1) a1 [regionA, regionB])
    case reportDecision set of
      CameraSet admitted waiting _ _ _ _ _ → (length admitted, waiting) `shouldBe` (2, [])
      other → expectationFailure (show other)
    ledgersOf m3 `shouldBe` Ledgers (338, 400) (0, 0) (256 + 2 * 64, 258)
    m4 ← drainDemand m3
    map viewPending (modelViews m4) `shouldBe` [[]]
  it "never evicts a region of its own demand to load an earlier one" $ do
    -- B is resident (338) and named second; another request pins a third region
    -- (338). Loading A (400) needs 400 and only 324 are free. Evicting B would make
    -- room, but the demand needs B, so the model must not: A waits (busy).
    let regionA = demand (reg 0 0 0) (cell 0 0 0)
        regionB = demand (reg 1 0 0) (cell 0 0 0)
    m0 ← opened tiny
    m1 ← loadCell m0 1 (reg 1 0 0) (cell 0 0 0) >>= \m → withdraw m 1
    m1' ← loadCell m1 2 (reg 2 0 0) (cell 0 0 0)
    (m2, held) ← stepOk m1' (SetCameraDemand (ViewId 1) a1 [regionA, regionB])
    case reportDecision held of
      -- B waits behind A: regions are admitted strictly in demand order.
      CameraSet admitted waiting _ _ _ _ _ → (concatMap admissionVictims admitted, waiting) `shouldBe` ([], [reg 0 0 0, reg 1 0 0])
      other → expectationFailure (show other)
    [regionCoord r | r ← modelRegions m2, regionEvicting r] `shouldBe` []
    -- With the pin gone, A is funded from that region, not from B.
    m3 ← withdraw m2 2
    m4 ← drainDemand m3
    map viewPending (modelViews m4) `shouldBe` [[]]
    sort [regionCoord r | r ← modelRegions m4] `shouldBe` [reg 0 0 0, reg 1 0 0]
  it "counts the interests a view already holds in the regions still to come when admitting" $ do
    -- View 1 holds an interest in resident region 0 and a borrower holds it too.
    -- Replacing the demand with [region 2 (new), region 0] keeps that interest, holds
    -- a 256-byte description and takes region 2's interest and 258 bytes of scratch;
    -- in the tiny configuration this is accepted whole and completes.
    let regionN = demand (reg 2 0 0) (cell 0 0 0)
        regionR = demand (reg 0 0 0) (cell 0 0 0)
    m0 ← opened (limitsWith $ \s → s {specResidentBytes = 1302})
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0) >>= \m → withdraw m 1
    m2 ← fst <$> stepOk m1 (SetCameraDemand (ViewId 1) a1 [regionR])
    (m3, holdRes) ← stepOk m2 (AcquireHold (HoldId 1) a1 Borrow [reg 0 0 0])
    reportDecision holdRes `shouldBe` HoldAcquired
    (m4, set) ← stepOk m3 (SetCameraDemand (ViewId 1) a1 [regionN, regionR])
    case reportDecision set of
      CameraSet admitted waiting _ _ _ _ _ → (length admitted, waiting) `shouldBe` (2, [])
      other → expectationFailure (show other)
    m5 ← drainDemand m4
    map viewPending (modelViews m5) `shouldBe` [[]]
  it "reports the job a successful same-region replacement made obsolete, queued or running" $ do
    -- View 1 names level 0 of region 0 (job 0). Replacing it with level 1 of the same
    -- region is admitted whole (job 1) and leaves job 0 without an interest.
    let level z = demand (reg 0 0 0) (cell 0 0 z)
    m0 ← opened roomy2
    (m1, _) ← stepOk m0 (SetCameraDemand (ViewId 1) a1 [level 0])
    (_, queued) ← stepOk m1 (SetCameraDemand (ViewId 1) a1 [level 1])
    case reportDecision queued of
      CameraSet admitted waiting _ dropped awaiting _ _ → (map admissionJobs admitted, waiting, dropped, awaiting) `shouldBe` ([[(JobId 1, reg 0 0 0)]], [], [JobId 0], [])
      other → expectationFailure (show other)
    -- Running, the job is cancelling and awaits the owner's acknowledgement.
    m2 ← stepsOk m1 [Dispatch]
    (_, running) ← stepOk m2 (SetCameraDemand (ViewId 1) a1 [level 1])
    case reportDecision running of
      CameraSet _ _ _ dropped awaiting _ _ → (dropped, awaiting) `shouldBe` ([], [JobId 0])
      other → expectationFailure (show other)
  it "reports the jobs a failure leaves without an interest" $ do
    -- Caller 1 asks for level 0 (job 0) and caller 2 for levels 0 and 1 (job 1 covers
    -- level 1 only; level 0 is shared). Job 0 fails: both callers lose their interest in
    -- it, and job 1, which only they needed, is reported as cancelling.
    m0 ← opened roomy2
    m1 ← stepsOk m0 [q 1 (reg 0 0 0) (cell 0 0 0), q 2 (reg 0 0 0) (box 0 1 0 1 0 2), Dispatch, Dispatch]
    (_, failed) ← stepOk m1 (JobFailed (JobId 0))
    reportDecision failed `shouldBe` JobFailedFor (JobId 0) [OwnerRequest (RequestId 1), OwnerRequest (RequestId 2)] [] [JobId 1]
  it "admits a zoom-out sized demand partially, nearest first, never invalid, and an explicit request still takes what it needs" $ do
    -- 964 resident bytes hold two regions; the camera names 40, nearest first.
    let far = [demand (reg i 0 0) (cell 0 0 0) | i ← [0 .. 39]]
        limits = limitsWith $ \x → x {specResidentBytes = 964, specStagingBytes = 8192, specLoadJobs = 6}
    m0 ← opened limits
    (m1, set) ← stepOk m0 (SetCameraDemand (ViewId 1) a1 far)
    case reportDecision set of
      CameraSet admitted waiting _ _ _ _ _ → (map (map snd . admissionJobs) admitted, waiting) `shouldBe` ([[reg 0 0 0], [reg 1 0 0]], [reg i 0 0 | i ← [2 .. 39]])
      other → expectationFailure (show other)
    -- Nothing is refused or reserved for the rest, and the camera still leaves explicit
    -- work its job slots and staging.
    map viewPending (modelViews m1) `shouldBe` [[reg i 0 0 | i ← [2 .. 39]]]
    let staging = bankLedger m1 StagingBank
    (ledgerLimit staging - ledgerOccupied staging - ledgerReserved staging) `shouldSatisfy` (>= limitExplicitStagingBytes limits)
    m2 ← stepsOk m1 [Dispatch, Dispatch, JobCompleted (JobId 0) oneCellCost, JobCompleted (JobId 1) oneCellCost]
    (m3, idle) ← stepOk m2 Service
    reportDecision idle `shouldBe` Serviced []
    -- An explicit query for two other regions needs 800 bytes and only 288 are free;
    -- the camera's regions yield: both are taken as victims and the view's demand for
    -- them is pending again, ahead of the rest.
    (m4, explicit) ← stepOk m3 (q2 rev0 1 (reg 100 0 0) (reg 101 0 0))
    admissionVictims (admission explicit) `shouldBe` [(a1, reg 0 0 0), (a1, reg 1 0 0)]
    map viewPending (modelViews m4) `shouldBe` [[reg i 0 0 | i ← [0 .. 39]]]
    -- The explicit work finishes and lets go; the camera resumes nearest first.
    m5 ← drainDemand m4
    m6 ← withdraw m5 1
    m7 ← drainDemand m6
    sort [regionCoord r | r ← modelRegions m7, regionCoord r `elem` [reg i 0 0 | i ← [0 .. 39]]] `shouldBe` [reg 0 0 0, reg 1 0 0]
    -- Panning on releases the old interests: the demand moves to the next regions.
    (m8, panned) ← stepOk m7 (SetCameraDemand (ViewId 1) a1 (drop 2 far))
    case reportDecision panned of
      CameraSet admitted _ _ _ _ _ _ → length admitted `shouldSatisfy` (>= 1)
      other → expectationFailure (show other)
    m9 ← drainDemand m8
    sort [regionCoord r | r ← modelRegions m9, regionCoord r `elem` [reg i 0 0 | i ← [0 .. 39]]] `shouldBe` [reg 2 0 0, reg 3 0 0]
  it "keeps the staging an explicit request needs free of camera interests and scratch" $ do
    -- 1,636 staging bytes: 994 stay free for explicit requests, so the camera may use 642.
    -- Its 256-byte description and the first region (interest 64 + scratch 258) take 578;
    -- the second region would take 322 more and waits.
    let limits = limitsWith $ \x → x {specResidentBytes = 40000, specStagingBytes = 1636, specLoadJobs = 6}
    m0 ← opened limits
    (m1, set) ← stepOk m0 (SetCameraDemand (ViewId 1) a1 [demand (reg 0 0 0) (cell 0 0 0), demand (reg 1 0 0) (cell 0 0 0)])
    case reportDecision set of
      CameraSet admitted waiting _ _ _ _ _ → (length admitted, waiting) `shouldBe` (1, [reg 1 0 0])
      other → expectationFailure (show other)
    ledgersOf m1 `shouldBe` Ledgers (0, 400) (0, 0) (256 + 64, 258)
    -- The largest explicit request here (a removal, 994 bytes of staging) is admitted.
    (_, removal) ← stepOk m1 (SubmitRemoval (RequestId 1) a1 rev0 (tileAt 16 0 0))
    length (admissionJobs (admission removal)) `shouldBe` 1
  it "withdraws the interest in the coverage a busy replacement replaced" $ do
    -- 1,508 staging bytes: 994 stay free for explicit requests. View 1 holds level 0 of
    -- region A (description 192 + interest 64 once the job's scratch is released) and a
    -- borrower's record takes 64 more. The replacement, both levels of A, needs 258
    -- bytes of scratch for level 1 beside the headroom and only 1,188 - 994 = 194 are
    -- left: it is busy, and the old interest must not survive it.
    let both = demand (reg 0 0 0) (box 0 1 0 1 0 2)
        limits = limitsWith $ \x → x {specResidentBytes = 4000, specStagingBytes = 1508, specExtentZ = 2}
    m0 ← opened limits
    m1a ← stepsOk m0 [SetCameraDemand (ViewId 1) a1 [demand (reg 0 0 0) (cell 0 0 0)], Dispatch, JobCompleted (JobId 0) oneCellCost]
    -- A borrower's 64-byte record takes the room the replacement's scratch needs.
    (m1, _) ← stepOk m1a (AcquireHold (HoldId 1) a1 Borrow [reg 0 0 0])
    (m2, replaced) ← stepOk m1 (SetCameraDemand (ViewId 1) a1 [both])
    case reportDecision replaced of
      CameraSet admitted waiting withdrawn _ _ _ _ → (length admitted, waiting, withdrawn) `shouldBe` (0, [reg 0 0 0], [reg 0 0 0])
      other → expectationFailure (show other)
    [o | InterestInfo o _ r _ ← modelInterests m2, r == reg 0 0 0] `shouldBe` []
    map viewPending (modelViews m2) `shouldBe` [[reg 0 0 0]]
  it "admits explicit work however the camera pins and re-pins: pinned bytes never take the explicit headroom" $ do
    -- 1,302 resident bytes: 964 stay unpinned for explicit work, so pins may cover 338.
    -- A camera view fills the bank with six regions' worth of demand (three fit) and keeps
    -- one pin; a second pin over another region is busy. Every quantum the view moves its
    -- pin to another resident region, and an explicit query for two fresh regions
    -- (800 bytes) arrives each time: it is admitted, taking the unpinned camera regions.
    let far = [demand (reg i 0 0) (cell 0 0 0) | i ← [0 .. 5]]
        limits = limitsWith $ \x → x {specResidentBytes = 1302, specStagingBytes = 8192, specLoadJobs = 6, specQueuedCommands = 8}
    m0 ← opened limits
    m1 ← fst <$> stepOk m0 (SetCameraDemand (ViewId 1) a1 far)
    m2 ← drainDemand m1
    length (modelRegions m2) `shouldBe` 3
    (m3, _) ← stepOk m2 (AcquireHold (HoldId 1) a1 (Pin (ViewId 1)) [reg 0 0 0])
    stepRefused m3 (AcquireHold (HoldId 2) a1 (Pin (ViewId 1)) [reg 1 0 0]) `shouldReturn` Busy (BankFull ResidentBank 338 338 338)
    let round' (m, held) k = do
          (mq, admitted) ← stepOk m (q2 rev0 (10 + k) (reg (100 + 2 * k) 0 0) (reg (101 + 2 * k) 0 0))
          length (admissionJobs (admission admitted)) `shouldBe` 2
          mFinished ← drainDemand mq >>= \x → withdraw x (10 + k) >>= drainDemand
          -- Move the pin to another resident region of the demand.
          let target = fromMaybe held (listToMaybe [regionCoord r | r ← modelRegions mFinished, regionCoord r `elem` map demandRegion far, regionCoord r /= held])
          (mr, _) ← stepOk mFinished (ReleaseHold (HoldId (fromInteger k)))
          (mp, _) ← stepOk mr (AcquireHold (HoldId (fromInteger k + 1)) a1 (Pin (ViewId 1)) [target])
          pure (mp, target)
    _ ← foldM round' (m3, reg 0 0 0) [1 .. 4]
    pure ()
  it "admits an 8,192-level column of 257 regions at the default 128 load-job slots, running 128 at a time" $ do
    -- Levels 5 to 8,196 of one column: 257 regions, the first and last partial.
    m0 ← fst <$> stepOk (newModel defaultLimits) (OpenArena a1 rev0)
    let column = [demand (reg 0 0 z) (if z == 0 then box 0 1 0 1 5 32 else if z == 256 then box 0 1 0 1 0 5 else box 0 1 0 1 0 32) | z ← [0 .. 256]]
    (m1, accepted) ← stepOk m0 (SubmitQuery (RequestId 1) a1 rev0 column)
    length (admissionJobs (admission accepted)) `shouldBe` 257
    ledgerReserved (bankLedger m1 ResidentBank) `shouldSatisfy` (<= limitExplicitResidentBytes defaultLimits)
    -- Slots are taken at dispatch: 128 run, the rest wait, and one completion frees one.
    m2 ← foldM (\m _ → fst <$> stepOk m Dispatch) m1 [1 .. 128 ∷ Int]
    slotInUse m2 LoadJobSlot `shouldBe` 128
    (m3, none) ← stepOk m2 Dispatch
    reportDecision none `shouldBe` NothingToDispatch
    m4 ← stepsOk m3 [JobCompleted (JobId 0) (Cost 0 1 54)]
    (_, next) ← stepOk m4 Dispatch
    case reportDecision next of
      Dispatched j _ _ → j `shouldBe` JobId 128
      other → expectationFailure (show other)
    -- A column of 258 regions is over the query cap, invalid from any state.
    stepRefused m1 (SubmitQuery (RequestId 2) a1 rev0 (column <> [demand (reg 1 0 0) (cell 0 0 0)])) `shouldReturn` Invalid (DemandTooLarge 258 257)
  it "normalizes a camera description: empty withdraws, repeated keys coalesce, bad keys are excluded and reported" $ do
    let level z = demand (reg 0 0 0) (cell 0 0 z)
        other' = demand (reg 1 0 0) (cell 0 0 0)
        bad = RegionCoord maxBound 0 0
    m0 ← opened roomy2
    -- Repeated keys coalesce into the first occurrence, keeping its priority; an
    -- unsupported key and a region whose cells all lie outside the extent are excluded,
    -- reported, and do not stop the valid entries.
    (m1, set) ← stepOk m0 (SetCameraDemand (ViewId 1) a1 [level 0, other', level 1, demand bad (cell 0 0 0), demand (reg 2 0 0) (cell 1 0 0)])
    case reportDecision set of
      CameraSet admitted _ _ _ _ excluded truncated → (map (map snd . admissionJobs) admitted, excluded, truncated) `shouldBe` ([[reg 0 0 0], [reg 1 0 0]], [bad, reg 2 0 0], [])
      other → expectationFailure (show other)
    [coverageCells (jobCoverage j) | j ← modelJobs m1, jobRegion j == reg 0 0 0] `shouldBe` [2]
    map (map demandRegion . viewDemand) (modelViews m1) `shouldBe` [[reg 0 0 0, reg 1 0 0]]
    -- An empty description withdraws the view's demand, its interests and its jobs.
    (m2, cleared) ← stepOk m1 (SetCameraDemand (ViewId 1) a1 [])
    case reportDecision cleared of
      CameraSet admitted waiting withdrawn dropped _ _ _ → (length admitted, waiting, withdrawn, length dropped) `shouldBe` (0, [], [reg 0 0 0, reg 1 0 0], 2)
      other → expectationFailure (show other)
    modelViews m2 `shouldBe` []
    modelInterests m2 `shouldBe` []
  it "cuts a camera description at its structural maximum, lowest priority first, and reports the rest" $ do
    let named = [demand (reg i 0 0) (cell 0 0 0) | i ← [0 .. 5]]
    m0 ← opened (limitsWith $ \x → x {specResidentBytes = 40000, specStagingBytes = 8192, specLoadJobs = 6, specCameraRegions = 4})
    (m1, set) ← stepOk m0 (SetCameraDemand (ViewId 1) a1 named)
    case reportDecision set of
      CameraSet _ _ _ _ _ excluded truncated → (excluded, truncated) `shouldBe` ([], [reg 4 0 0, reg 5 0 0])
      other → expectationFailure (show other)
    map (map demandRegion . viewDemand) (modelViews m1) `shouldBe` [[reg i 0 0 | i ← [0 .. 3]]]
  it "bounds a hold by a static region cap and draws its records on the camera's share of staging" $ do
    let four = [reg i 0 0 | i ← [0 .. 3]]
    m0 ← opened (limitsWith $ \x → x {specResidentBytes = 40000, specStagingBytes = 4096, specLoadJobs = 6, specQueryRegions = 2, specQueuedCommands = 8})
    m1 ← foldM (\m i → loadCell m i (reg i 0 0) (cell 0 0 0) >>= \x → withdraw x i) m0 [0 .. 4]
    stepRefused m1 (AcquireHold (HoldId 1) a1 Borrow (four <> [reg 4 0 0])) `shouldReturn` Invalid (DemandTooLarge 5 4)
    (m2, _) ← stepOk m1 (AcquireHold (HoldId 1) a1 Borrow four)
    ledgersOf m2 `shouldBe` Ledgers (5 * 338, 0) (0, 0) (4 * 64, 0)
    -- With 1,250 staging bytes, 994 of which stay free for explicit work, an open
    -- request's 224 leave the camera's share 32: the same hold is busy though 1,026
    -- bytes are free.
    tight ← opened (limitsWith $ \x → x {specResidentBytes = 40000, specStagingBytes = 1250, specQueryRegions = 2, specQueuedCommands = 8})
    t1 ← foldM (\m i → loadCell m i (reg i 0 0) (cell 0 0 0) >>= \x → if i == 4 then pure x else withdraw x i) tight [0 .. 4]
    stepRefused t1 (AcquireHold (HoldId 1) a1 Borrow four) `shouldReturn` Busy (BankFull StagingBank 1250 224 256)
  it "clears a view's demand and cancels the work only it needed" $ do
    m0 ← opened roomy
    m1 ← fst <$> stepOk m0 (SetCameraDemand (ViewId 1) a1 [demand (reg 0 0 0) (cell 0 0 0)])
    (m2, cleared) ← stepOk m1 (ClearCameraDemand (ViewId 1))
    reportDecision cleared `shouldBe` CameraCleared [reg 0 0 0] [JobId 0] []
    ledgersOf m2 `shouldBe` Ledgers (0, 0) (0, 0) (0, 0)
    stepRefused m2 (ClearCameraDemand (ViewId 1)) `shouldReturn` Stale (UnknownView (ViewId 1))

-- ---------------------------------------------------------------------------

schedulingSpec ∷ Spec
schedulingSpec = describe "deterministic scheduling" $ do
  it "serves foreground work before prefetch" $ do
    m0 ← opened roomy
    -- The camera job is queued first; a query arrives later and goes first.
    m1 ← stepsOk m0 [SetCameraDemand (ViewId 1) a1 [demand (reg 0 0 0) (cell 0 0 0)], q 1 (reg 1 0 0) (cell 0 0 0)]
    (m2, first) ← stepOk m1 Dispatch
    reportDecision first `shouldBe` Dispatched (JobId 1) (a1, reg 1 0 0) (cell 0 0 0)
    (_, second) ← stepOk m2 Dispatch
    reportDecision second `shouldBe` Dispatched (JobId 0) (a1, reg 0 0 0) (cell 0 0 0)
  it "lets continuously arriving foreground work delay an accepted prefetch job only for the aging threshold" $ do
    m0 ← opened roomy
    m1 ← fst <$> stepOk m0 (SetCameraDemand (ViewId 1) a1 [demand (reg 0 0 0) (cell 0 0 0)])
    -- A new foreground query arrives before every dispatch (aging is 3).
    (_, order) ← foldM
      ( \(m, acc) i → do
          (m', accepted) ← stepOk m (q i (reg i 0 0) (cell 0 0 0))
          j ← onlyJob accepted
          (m'', dispatched) ← stepOk m' Dispatch
          case reportDecision dispatched of
            Dispatched d _ _ → do
              m3 ← case d == j of
                True → stepsOk m'' [JobCompleted j oneCellCost, Withdraw (RequestId (fromInteger i))]
                False → pure m''
              pure (m3, acc <> [d])
            other → expectationFailure (show other) >> pure (m'', acc)
      )
      (m1, [])
      [1 .. 4]
    -- Foreground jobs 1, 2 and 3 go first; the prefetch job, passed over three
    -- times, is then served ahead of the fourth arrival.
    order `shouldBe` [JobId 1, JobId 2, JobId 3, JobId 0]
  it "counts the passes of an eligible job" $ do
    m0 ← opened roomy
    m1 ← stepsOk m0 [SetCameraDemand (ViewId 1) a1 [demand (reg 0 0 0) (cell 0 0 0)], q 1 (reg 1 0 0) (cell 0 0 0), Dispatch]
    jobSkips <$> jobFor m1 (reg 0 0 0) `shouldBe` Just 1
  it "takes turns between callers, not between regions" $ do
    m0 ← opened roomy
    let two = SubmitQuery (RequestId 1) a1 rev0 [demand (reg 0 0 0) (cell 0 0 0), demand (reg 1 0 0) (cell 0 0 0)]
    m1 ← stepsOk m0 [two, q 2 (reg 2 0 0) (cell 0 0 0)]
    (_, order) ← foldM
      ( \(m, acc) _ → do
          (m', dispatched) ← stepOk m Dispatch
          case reportDecision dispatched of
            Dispatched _ (_, r) _ → pure (m', acc <> [r])
            other → expectationFailure (show other) >> pure (m', acc)
      )
      (m1, [])
      [1 ∷ Int, 2, 3]
    -- Caller 1's first region, then caller 2's, then caller 1's second.
    order `shouldBe` [reg 0 0 0, reg 2 0 0, reg 1 0 0]
  it "never dispatches a job still waiting for its victims" $ do
    m0 ← opened tiny
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0) >>= \m → withdraw m 1
    m2 ← loadCell m1 2 (reg 1 0 0) (cell 0 0 0) >>= \m → withdraw m 2
    m3 ← fst <$> stepOk m2 (q 3 (reg 2 0 0) (cell 0 0 0))
    (_, none) ← stepOk m3 Dispatch
    reportDecision none `shouldBe` NothingToDispatch

-- ---------------------------------------------------------------------------

editSpec ∷ Spec
editSpec = describe "retained edits" $ do
  it "reserves the worst-case growth and staging before a removal and settles them at commit" $ do
    m0 ← opened tiny
    (m1, accepted) ← stepOk m0 (SubmitRemoval (RequestId 1) a1 rev0 (tileAt 0 0 0))
    admissionJobs (admission accepted) `shouldBe` [(JobId 0, reg 0 0 0)]
    -- 64 edit bytes reserved; resident reserves the job (400) and the rebuilt
    -- segment's growth (62); staging reserves scratch 258 and the staged overlay
    -- 512; the command (160) and interest (64) are occupied.
    ledgersOf m1 `shouldBe` Ledgers (0, 400 + 62) (0, 64) (224, 258 + 512)
    m2 ← stepsOk m1 [Dispatch, JobCompleted (JobId 0) oneCellCost]
    (m3, committed) ← stepOk m2 (RemovalCommitted (RequestId 1) (Revision 1) 64 0)
    reportDecision committed `shouldBe` Committed (Revision 1) 0 [] [] []
    -- The retained 64 bytes are now occupied; reservations and the command are gone.
    ledgersOf m3 `shouldBe` Ledgers (338, 0) (64, 0) (0, 0)
    [arenaRevision a | a ← modelArenas m3] `shouldBe` [Revision 1]
    [regionDirty r | r ← modelRegions m3] `shouldBe` [True]
  it "returns the unused part of a reservation, down to nothing for an adjacent removal" $ do
    m0 ← opened (limitsWith $ \s → s {specExtentZ = 2, specResidentBytes = 1100})
    (m1, _) ← removeCellAt m0 a1 rev0 1 (tileAt 0 0 0)
    (m2, accepted) ← stepOk m1 (SubmitRemoval (RequestId 2) a1 (Revision 1) (tileAt 0 0 1))
    admissionJobs (admission accepted) `shouldBe` [(JobId 1, reg 0 0 0)]
    -- The region is resident, so the job needs no metadata: a column entry (48),
    -- a segment (32) and the payload bound (64), plus the growth (62).
    ledgersOf m2 `shouldBe` Ledgers (338, 144 + 62) (64, 64) (224, 258 + 512)
    -- The cell above is in the same removed interval: no retained growth, so the
    -- whole 64-byte reservation returns.
    -- (The adjacent cell joins the existing segment: two payload bytes, no new segment.)
    m3 ← stepsOk m2 [Dispatch, JobCompleted (JobId 1) (Cost 0 0 2)]
    (m4, committed) ← stepOk m3 (RemovalCommitted (RequestId 2) (Revision 2) 0 0)
    reportDecision committed `shouldBe` Committed (Revision 2) 64 [] [] []
    ledgersOf m4 `shouldBe` Ledgers (338 + 2, 0) (64, 0) (0, 0)
    [arenaRetainedBytes a | a ← modelArenas m4] `shouldBe` [64]
  it "returns every reservation when a removal is abandoned before commit" $ do
    m0 ← opened tiny
    m1 ← fst <$> stepOk m0 (SubmitRemoval (RequestId 1) a1 rev0 (tileAt 0 0 0))
    m2 ← stepsOk m1 [Dispatch, JobCompleted (JobId 0) oneCellCost]
    m3 ← withdraw m2 1
    ledgersOf m3 `shouldBe` Ledgers (338, 0) (0, 0) (0, 0)
    [arenaRevision a | a ← modelArenas m3] `shouldBe` [rev0]
    -- A cancellation that arrives after the commit has nothing to undo.
    (m4, _) ← removeCellAt m3 a1 rev0 2 (tileAt 16 0 0)
    stepRefused m4 (Withdraw (RequestId 2)) `shouldReturn` Stale (UnknownRequest (RequestId 2))
    ledgersOf m4 `shouldBe` Ledgers (676, 0) (64, 0) (0, 0)
  it "refuses a commit before the cell is resident, over its reservation or not past the revision" $ do
    m0 ← opened tiny
    m1 ← fst <$> stepOk m0 (SubmitRemoval (RequestId 1) a1 rev0 (tileAt 0 0 0))
    stepRefused m1 (RemovalCommitted (RequestId 1) (Revision 1) 64 0) `shouldReturn` ContractFailure (EditBeforeResident (RequestId 1))
    m2 ← stepsOk m1 [Dispatch, JobCompleted (JobId 0) oneCellCost]
    stepRefused m2 (RemovalCommitted (RequestId 1) (Revision 1) 65 0) `shouldReturn` ContractFailure (CommitExceedsReservation 64 65)
    stepRefused m2 (RemovalCommitted (RequestId 1) rev0 64 0) `shouldReturn` ContractFailure (RevisionNotAdvancing rev0 rev0)
    -- A query is not an edit.
    m3 ← fst <$> stepOk m2 (q 2 (reg 0 0 0) (cell 0 0 0))
    stepRefused m3 (RemovalCommitted (RequestId 2) (Revision 1) 0 0) `shouldReturn` ContractFailure (NotAnEdit (RequestId 2))
    -- Two removals planned against revision 0: the second commit is stale.
    (m4, _) ← stepOk m3 (SubmitRemoval (RequestId 3) a1 rev0 (tileAt 16 0 0))
    m5 ← stepsOk m4 [Dispatch, JobCompleted (JobId 1) oneCellCost]
    m6 ← fst <$> stepOk m5 (RemovalCommitted (RequestId 1) (Revision 1) 64 0)
    stepRefused m6 (RemovalCommitted (RequestId 3) (Revision 2) 64 0) `shouldReturn` Stale (RevisionMismatch (Revision 1) rev0)
  it "treats more resident growth than was reserved, or growth still awaiting its victims, as a contract failure" $ do
    m0 ← opened tiny
    m1 ← fst <$> stepOk m0 (SubmitRemoval (RequestId 1) a1 rev0 (tileAt 0 0 0))
    m2 ← stepsOk m1 [Dispatch, JobCompleted (JobId 0) oneCellCost]
    -- 62 bytes were reserved for the rebuilt segment.
    stepRefused m2 (RemovalCommitted (RequestId 1) (Revision 1) 64 63) `shouldReturn` ContractFailure (ResidentGrowthExceedsReservation 62 63)
    (m3, committed) ← stepOk m2 (RemovalCommitted (RequestId 1) (Revision 1) 64 62)
    reportDecision committed `shouldBe` Committed (Revision 1) 0 [] [] []
    -- The growth is occupied: 338 + 62.
    ledgersOf m3 `shouldBe` Ledgers (400, 0) (64, 0) (0, 0)
    -- Growth funded by a committed eviction is not occupied before the release:
    -- 676 stored of 1,000 leave 324; the job (400) takes it and the growth (62) waits.
    m4 ← loadCell m0 1 (reg 5 0 0) (cell 0 0 0) >>= \m → withdraw m 1
    m5 ← loadCell m4 2 (reg 6 0 0) (cell 0 0 0) >>= \m → withdraw m 2
    (m6, waiting) ← stepOk m5 (SubmitRemoval (RequestId 3) a1 rev0 (tileAt 0 0 0))
    admissionDeferred (admission waiting) `shouldBe` 76 + 62
    ledgersOf m6 `shouldBe` Ledgers (676, 324) (0, 64) (224, 258 + 512)
    -- The job waits; the removal cannot commit before its growth is funded.
    map requestResidentDeferred (modelRequests m6) `shouldBe` [62]
    stepRefused m6 (RemovalCommitted (RequestId 3) (Revision 1) 64 0) `shouldReturn` ContractFailure (EditNotFunded (RequestId 3))
  it "counts a removal's growth in the minimum resident budget: 543 refuses the configuration, 544 admits" $ do
    -- With one region per request the removal is the largest resident request: the
    -- region may already hold 338, the cell's job reserves 144 more (a column and a
    -- segment) and 62 more are reserved for the rebuilt segment.
    let one = baseSpec {specQueryRegions = 1, specStagingBytes = 4096}
    mkLimits one {specResidentBytes = 543} `shouldBe` Left (BankBelowMinimum ResidentBank 544 543)
    m0 ← opened (limitsWith $ const one {specResidentBytes = 544})
    -- Removing the cell of an empty region reserves its 400-byte job and the 62 bytes.
    (m1, ok) ← stepOk m0 (SubmitRemoval (RequestId 1) a1 rev0 (tileAt 0 0 0))
    admissionJobs (admission ok) `shouldBe` [(JobId 0, reg 0 0 0)]
    ledgersOf m1 `shouldBe` Ledgers (0, 462) (0, 64) (224, 258 + 512)
  it "refuses new edits at the retained bound while reads and navigation continue" $ do
    m0 ← opened roomy
    (m3, _) ← foldM (\(m, rv) i → removeCellAt m a1 rv i (tileAt (16 * i) 0 0)) (m0, rev0) [1, 2, 3]
    ledgersOf m3 `shouldBe` Ledgers (3 * 338, 0) (192, 0) (0, 0)
    -- Neither busy nor invalid: exhausted, with the bank's figures.
    stepRefused m3 (SubmitRemoval (RequestId 9) a1 (Revision 3) (tileAt 64 0 0)) `shouldReturn` RetainedEditsExhausted EditBank 192 192 64
    -- Reading, navigating and demanding new terrain still work.
    (m4, read') ← stepOk m3 (qAt (Revision 3) 10 (reg 1 0 0) (cell 0 0 0))
    admissionShared (admission read') `shouldBe` [reg 1 0 0]
    _ ← stepOk m4 (SetCameraDemand (ViewId 1) a1 [demand (reg 7 0 0) (cell 0 0 0)])
    -- Even a removal that would be a no-op is refused before it can be judged.
    stepRefused m4 (SubmitRemoval (RequestId 11) a1 (Revision 3) (tileAt 0 0 0)) `shouldReturn` RetainedEditsExhausted EditBank 192 192 64
    -- Nothing was erased to make room.
    [arenaRetainedBytes a | a ← modelArenas m4] `shouldBe` [192]
  it "does not evict changed regions to relieve pressure" $ do
    m0 ← opened tiny
    (m1, rv) ← removeCellAt m0 a1 rev0 1 (tileAt 0 0 0)
    r ← stepRefused m1 (q2 rv 2 (reg 1 0 0) (reg 2 0 0))
    -- 662 free, 800 needed; the only resident region has unsettled changes.
    r `shouldBe` Busy (NoEligibleEviction 138 0 (Blockers 0 0 1 0 0 0 0))

-- ---------------------------------------------------------------------------

handoffSpec ∷ Spec
handoffSpec = describe "edit handoff" $ do
  let limits = tiny
  it "protects the detail until the transfer is confirmed, without a new edit allocation" $ do
    m0 ← opened limits
    (m1, rv) ← removeCellAt m0 a1 rev0 1 (tileAt 0 0 0)
    (m2, started) ← stepOk m1 (BeginHandoff a1 (reg 0 0 0) 64)
    reportDecision started `shouldBe` HandoffStarted
    -- The temporary duplicate is accounted in staging until released.
    ledgersOf m2 `shouldBe` Ledgers (338, 0) (64, 0) (64, 0)
    stepRefused m2 (q2 rv 2 (reg 1 0 0) (reg 2 0 0)) `shouldReturn` Busy (NoEligibleEviction 138 0 (Blockers 0 1 0 0 0 0 0))
    (m3, settled) ← stepOk m2 (HandoffConfirmed a1 (reg 0 0 0))
    reportDecision settled `shouldBe` HandoffSettled
    -- The retained bytes were funded at the removal and are unchanged.
    ledgersOf m3 `shouldBe` Ledgers (338, 0) (64, 0) (0, 0)
    (m4, accepted) ← stepOk m3 (q2 rv 2 (reg 1 0 0) (reg 2 0 0))
    admissionVictims (admission accepted) `shouldBe` [(a1, reg 0 0 0)]
    ledgersOf m4 `shouldBe` Ledgers (338, 662) (64, 0) (320, 516)
  it "keeps the changes, the protection and the retained bytes when the handoff fails, and does not retry" $ do
    m0 ← opened limits
    (m1, rv) ← removeCellAt m0 a1 rev0 1 (tileAt 0 0 0)
    m2 ← fst <$> stepOk m1 (BeginHandoff a1 (reg 0 0 0) 64)
    (m3, failed) ← stepOk m2 (HandoffFailed a1 (reg 0 0 0))
    reportDecision failed `shouldBe` HandoffAbandoned
    ledgersOf m3 `shouldBe` Ledgers (338, 0) (64, 0) (0, 0)
    [regionDirty r | r ← modelRegions m3] `shouldBe` [True]
    -- Still protected: dirty, not evictable, nothing retried by the model.
    stepRefused m3 (q2 rv 2 (reg 1 0 0) (reg 2 0 0)) `shouldReturn` Busy (NoEligibleEviction 138 0 (Blockers 0 0 1 0 0 0 0))
    -- Only the owner's explicit decision starts another attempt.
    m4 ← stepsOk m3 [BeginHandoff a1 (reg 0 0 0) 64, HandoffConfirmed a1 (reg 0 0 0)]
    [regionDirty r | r ← modelRegions m4] `shouldBe` [False]
  it "does not let an older handoff clear a newer committed change" $ do
    m0 ← opened roomy2
    (m1, rv1) ← removeCellAt m0 a1 rev0 1 (tileAt 0 0 0)
    m2 ← fst <$> stepOk m1 (BeginHandoff a1 (reg 0 0 0) 64)
    -- Another removal commits in the same region while the handoff is pending.
    (m3, rv2) ← removeCellAt m2 a1 rv1 2 (tileAt 0 0 1)
    map regionGeneration (modelRegions m3) `shouldBe` [2]
    -- The older transfer confirms: the region stays changed, and protected.
    (m4, settled) ← stepOk m3 (HandoffConfirmed a1 (reg 0 0 0))
    reportDecision settled `shouldBe` HandoffSettled
    map regionDirty (modelRegions m4) `shouldBe` [True]
    -- A new handoff is accepted (the newer change still has to be transferred),
    -- and only its confirmation makes the region clean.
    m5 ← stepsOk m4 [BeginHandoff a1 (reg 0 0 0) 64, HandoffConfirmed a1 (reg 0 0 0)]
    map regionDirty (modelRegions m5) `shouldBe` [False]
    rv2 `shouldBe` Revision 2
  it "refuses a handoff the protocol does not allow" $ do
    m0 ← opened limits
    m1 ← loadCell m0 1 (reg 0 0 0) (cell 0 0 0)
    stepRefused m1 (BeginHandoff a1 (reg 0 0 0) 64) `shouldReturn` ContractFailure (HandoffNotNeeded (reg 0 0 0))
    stepRefused m1 (HandoffConfirmed a1 (reg 0 0 0)) `shouldReturn` ContractFailure (HandoffNotPending (reg 0 0 0))
    stepRefused m1 (BeginHandoff a1 (reg 5 0 0) 64) `shouldReturn` Stale (NotResident (reg 5 0 0))
  it "refuses a handoff duplicate larger than a region can ever be, from any state, and accepts the largest" $ do
    m0 ← opened tiny
    (m1, _) ← removeCellAt m0 a1 rev0 1 (tileAt 0 0 0)
    -- A one-cell extent stores at most 338 bytes; the duplicate is at most that.
    limitRegionStoredBytes tiny `shouldBe` 338
    stepRefused m1 (BeginHandoff a1 (reg 0 0 0) 339) `shouldReturn` Invalid (HandoffTooLarge 339 338)
    (_, started) ← stepOk m1 (BeginHandoff a1 (reg 0 0 0) 338)
    reportDecision started `shouldBe` HandoffStarted

-- ---------------------------------------------------------------------------

retirementSpec ∷ Spec
retirementSpec = describe "arena retirement" $ do
  it "restores exhausted edit capacity, leaves another arena's charges alone and conserves every bank" $ do
    m0 ← opened roomy
    (m1, rv) ← foldM (\(m, r) i → removeCellAt m a1 r i (tileAt (16 * i) 0 0)) (m0, rev0) [1, 2]
    rv `shouldBe` Revision 2
    m2 ← fst <$> stepOk m1 (OpenArena a2 rev0)
    (m3, _) ← removeCellAt m2 a2 rev0 3 (tileAt 0 0 0)
    ledgersOf m3 `shouldBe` Ledgers (3 * 338, 0) (192, 0) (0, 0)
    stepRefused m3 (SubmitRemoval (RequestId 9) a2 (Revision 1) (tileAt 16 0 0)) `shouldReturn` RetainedEditsExhausted EditBank 192 192 64
    let untouched = [(regionCoord r, regionBytes r) | r ← modelRegions m3, regionArena r == a2]
    (m4, retired) ← stepOk m3 (RetireArena a1)
    reportSettled retired `shouldBe` [a1]
    -- Arena 1's 128 retained bytes and two regions are gone; arena 2 is untouched.
    ledgersOf m4 `shouldBe` Ledgers (338, 0) (64, 0) (0, 0)
    [(regionCoord r, regionBytes r) | r ← modelRegions m4] `shouldBe` untouched
    [(arenaId a, arenaRetainedBytes a) | a ← modelArenas m4] `shouldBe` [(a2, 64)]
    -- A fresh incarnation can retain edits again, and the same arena can take more.
    m5 ← fst <$> stepOk m4 (OpenArena a3 rev0)
    (m6, _) ← removeCellAt m5 a3 rev0 4 (tileAt 0 0 0)
    ledgersOf m6 `shouldBe` Ledgers (2 * 338, 0) (128, 0) (0, 0)
    _ ← stepOk m6 (SubmitRemoval (RequestId 10) a2 (Revision 1) (tileAt 16 0 0))
    pure ()
  it "releases only after in-flight work, borrowers and pins acknowledge" $ do
    m0 ← opened roomy
    (m1, _) ← removeCellAt m0 a1 rev0 1 (tileAt 0 0 0)
    m2 ← stepsOk m1 [AcquireHold (HoldId 1) a1 (Pin (ViewId 1)) [reg 0 0 0], qAt (Revision 1) 2 (reg 5 0 0) (cell 0 0 0), Dispatch]
    ledgersOf m2 `shouldBe` Ledgers (338, 400) (64, 0) (64 + 160 + 64, 258)
    (m3, retiring) ← stepOk m2 (RetireArena a1)
    reportDecision retiring `shouldBe` ArenaRetirement [] [JobId 1]
    reportSettled retiring `shouldBe` []
    -- Demand is withdrawn at once but every physical charge stays.
    ledgersOf m3 `shouldBe` Ledgers (338, 400) (64, 0) (64, 258)
    -- New demand and late results for the retiring incarnation are refused or dropped.
    stepRefused m3 (q 3 (reg 6 0 0) (cell 0 0 0)) `shouldReturn` Stale (ArenaRetiring a1)
    (m4, late) ← stepOk m3 (JobCompleted (JobId 1) oneCellCost)
    reportDecision late `shouldBe` Discarded (JobId 1)
    reportSettled late `shouldBe` []
    -- The pin is the last thing holding the arena.
    (m5, released) ← stepOk m4 (ReleaseHold (HoldId 1))
    reportSettled released `shouldBe` [a1]
    ledgersOf m5 `shouldBe` Ledgers (0, 0) (0, 0) (0, 0)
    stepRefused m5 (q 3 (reg 6 0 0) (cell 0 0 0)) `shouldReturn` Stale (UnknownArena a1)
    stepRefused m5 (RetireArena a1) `shouldReturn` Stale (UnknownArena a1)
  it "waits for a committed victim's release before settling its arena, so its credit is not reused early" $ do
    -- 964 resident bytes: arena 1 holds two regions (676); arena 2's 400-byte job is
    -- funded by committing arena 1's older region as its victim.
    m0 ← opened (limitsWith $ \s → s {specResidentBytes = 964, specStagingBytes = 4096})
    m1 ← fst <$> stepOk m0 (OpenArena a2 rev0)
    m1a ← loadCell m1 1 (reg 0 0 0) (cell 0 0 0) >>= \m → withdraw m 1
    m2 ← loadCell m1a 3 (reg 1 0 0) (cell 0 0 0) >>= \m → withdraw m 3
    (m3, funded) ← stepOk m2 (SubmitQuery (RequestId 2) a2 rev0 [demand (reg 0 0 0) (cell 0 0 0)])
    admissionVictims (admission funded) `shouldBe` [(a1, reg 0 0 0)]
    ledgersOf m3 `shouldBe` Ledgers (676, 288) (0, 0) (224, 258)
    -- The owner has not yet released the victim's detail: retiring arena 1 must
    -- not hand its credit to arena 2's job.
    (m4, retiring) ← stepOk m3 (RetireArena a1)
    reportSettled retiring `shouldBe` []
    reportFunded retiring `shouldBe` []
    ledgersOf m4 `shouldBe` Ledgers (676, 288) (0, 0) (224, 258)
    (_, nothing) ← stepOk m4 Dispatch
    reportDecision nothing `shouldBe` NothingToDispatch
    -- The release is the acknowledgement: arena 1 settles and arena 2's job is funded.
    (m5, released) ← stepOk m4 (VictimReleased a1 (reg 0 0 0))
    reportSettled released `shouldBe` [a1]
    reportFunded released `shouldBe` [JobId 2]
    ledgersOf m5 `shouldBe` Ledgers (0, 400) (0, 0) (224, 258)
    stepRefused m5 (VictimReleased a1 (reg 0 0 0)) `shouldReturn` Stale (NotEvicting (reg 0 0 0))
  it "requires incarnations to increase and never reuses one" $ do
    m0 ← fst <$> stepOk (newModel tiny) (OpenArena (ArenaId 5) rev0)
    stepRefused m0 (OpenArena (ArenaId 5) rev0) `shouldReturn` Invalid (ArenaNotIncreasing (ArenaId 5))
    stepRefused m0 (OpenArena (ArenaId 4) rev0) `shouldReturn` Invalid (ArenaNotIncreasing (ArenaId 4))
    m1 ← stepsOk m0 [RetireArena (ArenaId 5)]
    -- A retired incarnation's number is not available again.
    stepRefused m1 (OpenArena (ArenaId 5) rev0) `shouldReturn` Invalid (ArenaNotIncreasing (ArenaId 5))
    let top = ArenaId maxBound
    m2 ← fst <$> stepOk m1 (OpenArena top rev0)
    stepRefused m2 (OpenArena top rev0) `shouldReturn` Invalid (ArenaNotIncreasing top)

-- ---------------------------------------------------------------------------

contractSpec ∷ Spec
contractSpec = describe "checked arithmetic and identity boundaries" $ do
  it "treats a larger cost than reserved as a contract failure, never growth" $ do
    m0 ← opened tiny
    m1 ← stepsOk m0 [q 1 (reg 0 0 0) (cell 0 0 0), Dispatch]
    -- One payload byte over the dense bound: 401 stored against 400 reserved.
    stepRefused m1 (JobCompleted (JobId 0) (Cost 1 1 65)) `shouldReturn` ContractFailure (CostExceedsReservation 400 401)
    -- The job is still running and can complete with a valid cost.
    (m2, done) ← stepOk m1 (JobCompleted (JobId 0) oneCellCost)
    reportDecision done `shouldBe` Published (JobId 0) [OwnerRequest (RequestId 1)]
    ledgersOf m2 `shouldBe` Ledgers (338, 0) (0, 0) (224, 0)
  it "refuses a completion that would take a region past the most its extent allows" $ do
    -- A one-cell extent stores at most 338 bytes. The job reserves 400, so 339 fits the
    -- reservation but is an impossible figure for the region: a contract failure, and the
    -- job stays running.
    m0 ← opened tiny
    m1 ← stepsOk m0 [q 1 (reg 0 0 0) (cell 0 0 0), Dispatch]
    stepRefused m1 (JobCompleted (JobId 0) (Cost 1 1 3)) `shouldReturn` ContractFailure (RegionExceedsMaximum 339 338)
    (_, done) ← stepOk m1 (JobCompleted (JobId 0) oneCellCost)
    reportDecision done `shouldBe` Published (JobId 0) [OwnerRequest (RequestId 1)]
  it "refuses a cost whose byte total does not fit 64 bits" $ do
    m0 ← opened tiny
    m1 ← stepsOk m0 [q 1 (reg 0 0 0) (cell 0 0 0), Dispatch]
    stepRefused m1 (JobCompleted (JobId 0) (Cost 0 maxBound 0)) `shouldReturn` ContractFailure CostOverflow
    stepRefused m1 (JobCompleted (JobId 0) (Cost 0 0 maxBound)) `shouldReturn` ContractFailure CostOverflow
    stepRefused m1 (JobCompleted (JobId 0) (Cost 1 0 maxBound)) `shouldReturn` ContractFailure CostOverflow
    -- (The reported column count is not charged: the model charges the columns the
    -- region's coverage gains.)
  it "refuses a report for work that was never dispatched" $ do
    m0 ← opened tiny
    m1 ← fst <$> stepOk m0 (q 1 (reg 0 0 0) (cell 0 0 0))
    stepRefused m1 (JobCompleted (JobId 0) oneCellCost) `shouldReturn` ContractFailure (JobNotRunning (JobId 0))
    stepRefused m1 (JobFailed (JobId 0)) `shouldReturn` ContractFailure (JobNotRunning (JobId 0))
  it "never wraps a revision" $ do
    m0 ← fst <$> stepOk (newModel tiny) (OpenArena a1 (Revision maxBound))
    (m1, _) ← stepOk m0 (SubmitRemoval (RequestId 1) a1 (Revision maxBound) (tileAt 0 0 0))
    m2 ← stepsOk m1 [Dispatch, JobCompleted (JobId 0) oneCellCost]
    stepRefused m2 (RemovalCommitted (RequestId 1) (Revision maxBound) 64 0) `shouldReturn` ContractFailure (RevisionNotAdvancing (Revision maxBound) (Revision maxBound))
  it "refuses duplicate identities and unknown arenas" $ do
    m0 ← opened tiny
    m1 ← fst <$> stepOk m0 (q 1 (reg 0 0 0) (cell 0 0 0))
    stepRefused m1 (q 1 (reg 1 0 0) (cell 0 0 0)) `shouldReturn` Invalid (DuplicateRequest (RequestId 1))
    stepRefused m1 (SubmitQuery (RequestId 2) a2 rev0 [demand (reg 0 0 0) (cell 0 0 0)]) `shouldReturn` Stale (UnknownArena a2)
    stepRefused m1 (SetCameraDemand (ViewId 1) a2 [demand (reg 0 0 0) (cell 0 0 0)]) `shouldReturn` Stale (UnknownArena a2)
    stepRefused m1 (Withdraw (RequestId 7)) `shouldReturn` Stale (UnknownRequest (RequestId 7))
  it "checks the cell arithmetic of coverage and the conservative reservation" $ do
    coverageBox 0 0 0 1 0 1 `shouldBe` Left EmptyBox
    coverageBox 0 17 0 1 0 1 `shouldBe` Left BoxOutsideRegion
    coverageBox 0 1 0 1 0 33 `shouldBe` Left BoxOutsideRegion
    coverageBox (-1) 1 0 1 0 1 `shouldBe` Left BoxOutsideRegion
    -- A whole region: 256 columns, one segment each, 16 x 16 x 32 = 8,192 cells.
    let whole = box 0 16 0 16 0 32
    (coverageColumns whole, coverageSegments whole, coverageCells whole) `shouldBe` (256, 256, 8192)
    -- 256 columns, 256 intervals of one segment each, and the dense bound of 64
    -- payload bytes per interval.
    reserveCost whole `shouldBe` Cost 256 256 (64 * 256)
    costBytes (Cost 256 256 32768) `shouldBe` Just (256 * 48 + 256 * 32 + 32768)
    costBytes (Cost maxBound 1 0) `shouldBe` Nothing
    costBytes (Cost 0 0 maxBound) `shouldBe` Just maxBound
    costBytes (Cost 1 0 maxBound) `shouldBe` Nothing
  it "unions and subtracts exactly, leaving separated cells separate" $ do
    let low = box 0 1 0 1 0 2
        high = box 0 1 0 1 10 12
        u = coverageUnion low high
    coverageIntervals u `shouldBe` [((0, 0), [(0, 2), (10, 12)])]
    coverageIntervals (coverageUnion low (box 0 1 0 1 2 4)) `shouldBe` [((0, 0), [(0, 4)])]
    coverageIntervals (coverageDifference u (box 0 1 0 1 1 11)) `shouldBe` [((0, 0), [(0, 1), (11, 12)])]
    coverageSubset low u `shouldBe` True
    coverageSubset u low `shouldBe` False
    coverageIntersects low high `shouldBe` False
    coverageIsEmpty (coverageDifference low low) `shouldBe` True
