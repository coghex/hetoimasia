-- | Shared helpers for the residency examples.
--
-- Nothing here reads a model's own totals to produce an expectation. The
-- constants below restate the charge table of the contract by hand
-- ('Hetoimasia.Terrain.Residency' documents it), and 'independentLedgers'
-- recomputes every bank from the model's observable records, so a step that
-- left a ledger out of step with its records fails here.
module Test.Terrain.ResidencySupport
  ( -- * Constants restated from the contract
    metaBytes
  , oneCellResident
  , oneCellStored
  , removalGrowth
  , oneCellScratch
  , interestBytes
  , commandBytes1
  , removalReserve
  , removalStaging

    -- * Building blocks
  , tiny
  , limitsWith
  , baseSpec
  , a1
  , a2
  , a3
  , rev0
  , reg
  , cell
  , box
  , demand
  , oneCellCost
  , honestCost

    -- * Stepping with checks
  , Ledgers (..)
  , independentLedgers
  , checkModel
  , stepOk
  , stepRefused
  , stepsOk
  , decisionOf
  , ledgersOf
  , jobFor
  ) where

import Control.Monad (foldM, forM_, unless)
import Data.Maybe (listToMaybe)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), mkLocalCoord)
import Hetoimasia.Terrain.Residency
import Test.Hspec (HasCallStack, expectationFailure, shouldBe)

-- | Region metadata, as the contract charges each resident region.
metaBytes ∷ Word
metaBytes = 256

-- | What a one-cell region job reserves: metadata 256, one column entry 48, one
-- segment 32 and the dense payload bound of 64.
oneCellResident ∷ Word
oneCellResident = 256 + 48 + 32 + 64

-- | What the data layer stores for one isolated cell: the same, with the payload
-- it actually needs (two bytes).
oneCellStored ∷ Word
oneCellStored = 256 + 48 + 32 + 2

-- | The resident growth a removal reserves for its rebuilt segment.
removalGrowth ∷ Word
removalGrowth = 62

-- | Scratch of a one-cell load: a 256-byte frame and two bytes per cell.
oneCellScratch ∷ Word
oneCellScratch = 256 + 2

interestBytes ∷ Word
interestBytes = 64

-- | A command naming one region: 128 plus 32 per region.
commandBytes1 ∷ Word
commandBytes1 = 128 + 32

removalReserve ∷ Word
removalReserve = 16 + 48

removalStaging ∷ Word
removalStaging = 512

-- | What a data layer reports for one stored cell.
oneCellCost ∷ Cost
oneCellCost = Cost {costColumns = 1, costSegments = 1, costPayloadBytes = 2}

-- | What an honest data layer reports for a job: the net growth of what it stores.
-- Its cells are new to the region, so each adds two payload bytes, and the segments
-- are those the region gains once the new cells merge into the ones it has (columns
-- are charged by the model from the coverage, whatever is reported).
honestCost ∷ Model → JobInfo → Cost
honestCost m j =
  let prior = [regionCoverage r | r ← modelRegions m, regionArena r == jobArena j, regionCoord r == jobRegion j]
      united = foldr coverageUnion (jobCoverage j) prior
      before = sum (map coverageSegments prior)
      gained = if coverageSegments united > before then coverageSegments united - before else 0
   in Cost 0 gained (2 * coverageCells (jobCoverage j))

-- | The tiny budget the traces share: two one-cell regions fit, three do not. Its
-- caps are two regions per request and a one-cell extent, so its banks satisfy
-- the minimum budgets (a request of two regions needs 964 resident bytes).
tiny ∷ Limits
tiny = limitsWith id

-- | The tiny specification: two regions per query, a one-cell extent, no holds and
-- no camera (each needs room beyond the explicit minimum), and banks that meet the minimum budgets (a query
-- of two regions needs 964 resident bytes and 994 staging bytes; each region of the
-- largest hold adds 338 and 64).
baseSpec ∷ LimitsSpec
baseSpec =
  LimitsSpec
    { specResidentBytes = 1000
    , specEditBytes = 192
    , specStagingBytes = 2048
    , specLoadJobs = 3
    , specQueuedCommands = 3
    , specPinsPerView = 2
    
    , specAgingQuanta = 3
    , specQueryRegions = 2
    , specExtentX = 1
    , specExtentY = 1
    , specExtentZ = 1
    , specHoldRegions = 0
    , specCameraRegions = 0
    }

-- | Validated limits from the tiny budget with some figures changed. A change
-- that breaks the minimum budgets is an error in the example, not a refusal.
limitsWith ∷ (LimitsSpec → LimitsSpec) → Limits
limitsWith change = either (error . show) id (mkLimits (change baseSpec))

a1, a2, a3 ∷ ArenaId
a1 = ArenaId 1
a2 = ArenaId 2
a3 = ArenaId 3

rev0 ∷ Revision
rev0 = Revision 0

reg ∷ Integer → Integer → Integer → RegionCoord
reg x y z = RegionCoord (fromInteger x) (fromInteger y) (fromInteger z)

-- | One cell by region-local offset.
cell ∷ Integer → Integer → Integer → Coverage
cell x y z = either (error . show) coverageTile (mkLocalCoord x y z)

-- | Region-local cells @[x0,x1) x [y0,y1) x [z0,z1)@.
box ∷ Int → Int → Int → Int → Int → Int → Coverage
box x0 x1 y0 y1 z0 z1 = either (error . show) id (coverageBox x0 x1 y0 y1 z0 z1)

demand ∷ RegionCoord → Coverage → RegionDemand
demand = RegionDemand

-- ---------------------------------------------------------------------------
-- Independent ledgers

-- | Occupied and reserved bytes of the three banks, recomputed from records.
data Ledgers = Ledgers
  { resident ∷ (Word, Word)
  , edit ∷ (Word, Word)
  , staging ∷ (Word, Word)
  }
  deriving stock (Eq, Show)

w ∷ Integral a ⇒ a → Word
w = fromIntegral

-- | The expected ledgers from the observable records alone: resident regions,
-- jobs, interests, requests, holds, views, handoff duplicates and arenas, with
-- the contract's per-record charges.
independentLedgers ∷ Model → Ledgers
independentLedgers m =
  Ledgers
    { resident = (sum [w (regionBytes r) | r ← modelRegions m], sum [w (jobActive j) | j ← modelJobs m] + sum [w (requestResidentActive r) | r ← modelRequests m])
    , edit = (sum [w (arenaRetainedBytes a) | a ← modelArenas m], removalReserve * w (length removals))
    , staging =
        ( interestBytes * w (length (modelInterests m))
            + sum [128 + 32 * w (length (requestRegions r)) | r ← modelRequests m]
            + sum [64 * w (length rs) | (_, _, _, rs) ← modelHolds m]
            + sum [128 + 64 * w (length (viewDemand v)) | v ← modelViews m]
            + sum [w d | r ← modelRegions m, Just d ← [regionHandoff r]]
        , sum [w (jobScratch j) | j ← modelJobs m] + removalStaging * w (length removals)
        )
    }
  where
    removals = filter requestRemoval (modelRequests m)

ledgersOf ∷ Model → Ledgers
ledgersOf m = Ledgers (pair ResidentBank) (pair EditBank) (pair StagingBank)
  where
    pair b = let l = bankLedger m b in (w (ledgerOccupied l), w (ledgerReserved l))

-- | The checks that must hold after every step, accepted or refused.
checkModel ∷ HasCallStack ⇒ String → Model → IO ()
checkModel label m = do
  let problems = modelInvariants m
  unless (null problems) $ expectationFailure (label <> ": invariants broken: " <> show problems)
  ledgersOf m `shouldBe` independentLedgers m
  forM_ allBanks $ \b → do
    let l = bankLedger m b
    unless (ledgerOccupied l + ledgerReserved l <= ledgerLimit l) $
      expectationFailure (label <> ": " <> show b <> " exceeds its limit: " <> show l)
  forM_ [LoadJobSlot, CommandSlot, ViewPinSlot] $ \s →
    unless (slotInUse m s <= limitSlot (modelLimits m) s) $
      expectationFailure (label <> ": " <> show s <> " exceeds its limit")

-- | Apply an event that must be accepted, then check the model.
stepOk ∷ HasCallStack ⇒ Model → Event → IO (Model, Report)
stepOk m event = case step m event of
  (m', Right report) → checkModel (show event) m' >> pure (m', report)
  (_, Left refusal) → expectationFailure (show event <> " was refused: " <> show refusal) >> fail "refused"

-- | Apply an event that must be refused; the model must come back unchanged.
stepRefused ∷ HasCallStack ⇒ Model → Event → IO Refusal
stepRefused m event = case step m event of
  (m', Left refusal) → do
    m' `shouldBe` m
    checkModel (show event) m'
    pure refusal
  (_, Right report) → expectationFailure (show event <> " was accepted: " <> show report) >> fail "accepted"

-- | Apply a list of events that must all be accepted.
stepsOk ∷ HasCallStack ⇒ Model → [Event] → IO Model
stepsOk = foldM (\m e → fst <$> stepOk m e)

decisionOf ∷ Report → Decision
decisionOf = reportDecision

-- | The job created for a region, if any.
jobFor ∷ Model → RegionCoord → Maybe JobInfo
jobFor m r = listToMaybe [j | j ← modelJobs m, jobRegion j == r]
