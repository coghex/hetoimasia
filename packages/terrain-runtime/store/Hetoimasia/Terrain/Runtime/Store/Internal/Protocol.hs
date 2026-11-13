-- | The caller protocol of the temporary store's planner (#662), as one resumable
-- driver every consumer in this package shares.
--
-- A plan reads through a 'Window', and the window is the only state a caller carries
-- from one call to the next. This module is that caller, as a pure state machine so the
-- terrain owner can run it a step at a time between waits: it never reads a page, it
-- /asks/ for one ('NeedPages', 'NeedProbes') and is /given/ it ('supplyPage',
-- 'supplyProbe'), so the owner never blocks inside a quantum and the page reads are the
-- storage backend's jobs.
--
-- == Every outcome of the planner has a handler
--
-- +-----------------------------------------+--------------------------------------------------+
-- | Planner outcome                         | What the driver does                             |
-- +=========================================+==================================================+
-- | @Planned plan@                          | 'Ready': the caller admits and writes it         |
-- | @NoWork@                                | 'NothingToDo': nothing is appended               |
-- | @BlockedByReader v o@                   | 'WaitsForReader': a reader's release unblocks it |
-- | @Pending p@                             | 'NeedPages': read it, 'supplyPage', plan again   |
-- | @PendingProbes ps@                      | 'NeedProbes': classify each, 'supplyProbe'       |
-- | @Checkpoint facts@                      | a fresh window of the same version keeps the     |
-- |                                         | facts ('windowCheckpoint'); the driver goes on   |
-- |                                         | by itself, with no I/O                           |
-- | @Refused (Capacity window-bound)@       | a fresh window with half the work ('reduceWork') |
-- | @Refused (Capacity LooseExceeded)@      | the same; at the smallest unit 'NeedMaintenance' |
-- | @Refused (Stale _)@                     | 'Replan': the candidate is the caller's to remake|
-- | @Refused other@                         | 'Refuse', classified by 'classifyPlan'           |
-- +-----------------------------------------+--------------------------------------------------+
--
-- A driver that follows this protocol never ends in an @Invalid@, @Integrity@ or @Stale@
-- refusal on valid input, and always makes progress at its smallest step (the property
-- of @Test.TerrainRuntime.Store.Protocol@, here exercised over every limit). When it
-- cannot make progress it says so as a 'Stall', which is a defect of the caller or the
-- planner, never a domain outcome and never an @Invalid@.
--
-- == State, owner, thread, lifetime
--
-- A 'Driver' is an immutable value held by the one terrain owner for the length of one
-- planning attempt. It owns no resource: the pages it holds in its window are copies
-- the window made, and the window is dropped with the driver.
module Hetoimasia.Terrain.Runtime.Store.Internal.Protocol
  ( -- * The planner a driver runs
    Planner
  , removalPlanner
  , discoveryPlanner
  , maintenancePlanner

    -- * The driver
  , Driver
  , newDriver
  , newDriverIn
  , Step (..)
  , Stall (..)
  , advance
  , supplyPage
  , supplyProbe
  , driverStore
  , driverWindow
  , driverWindowWork
  , driverCheckpoints
  , driverReductions
  , driverReadPeak
  , driverFactPeak
  , maxCheckpoints
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word64)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Discovery (Env, worstEditReads)
import Hetoimasia.Terrain.Runtime.Store.Internal.Admission (Failure, classifyPlan)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageError, PageNo, maxTxnPages)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (Store, planDiscovery, planMaintenance, planRemoval, storeConfig, storeWindow)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (CapacityWhy (..), Plan, PlanRefusal (..), Planned (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.State (cfgTotalPages, maxReclaimPages)
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree (Facts, Window, reduceWork, windowCheckpoint, windowInsert, windowPageNumbers, windowProbe, windowReadFactCount, windowSize, windowWork)

-- | One planning call through a window. The production planners are the three below;
-- a suite that plans under tighter bounds supplies its own, so the protocol it checks
-- is this driver's, never a copy of it.
type Planner = Window → Planned

-- | A removal of one cell, prepared against a discovery environment.
removalPlanner ∷ Env → Store → TileCoord → Planner
removalPlanner env store tile window = planRemoval env store window tile

-- | One discovery batch.
discoveryPlanner ∷ Env → Store → Planner
discoveryPlanner env store window = planDiscovery env store window

-- | One reclamation transaction.
maintenancePlanner ∷ Store → Planner
maintenancePlanner store window = planMaintenance store window

-- | One planning attempt against one committed version of one store.
data Driver = Driver
  { dvStore ∷ !Store
  , dvPlanner ∷ !Planner
  , dvWindow ∷ !Window
  , dvCheckpoints ∷ !Int
  , dvReductions ∷ !Int
  , dvReadPeak ∷ !Int
  -- ^ the most pages a window held when a checkpoint was taken from it
  , dvFactPeak ∷ !Int
  -- ^ the most read facts a window carried at a checkpoint
  , dvAsked ∷ ![PageNo]
  -- ^ what the last 'Step' asked for and has not yet been given: a plan is only run
  -- again once every page it named is in the window
  , dvProbing ∷ !Bool
  }

-- | Where a driver stopped, and what the caller does next.
data Step
  = -- | Pages the plan needs (the first of them; the plan is run again once given). The
    -- caller reads each from the backing and calls 'supplyPage'.
    NeedPages ![PageNo]
  | -- | Pages the plan must classify before it overwrites or frees them. The caller
    -- reads each (a page never written is nothing, not an error) and calls 'supplyProbe'.
    NeedProbes ![PageNo]
  | -- | The plan, complete. It is admitted, written and published by the owner.
    Ready !Plan
  | -- | The candidate changes no page and no header, or there is nothing to reclaim.
    NothingToDo
  | -- | The oldest retirement entry is still held: its version and the oldest pinned
    -- version. A reader's release and a maintenance transaction unblock it.
    WaitsForReader !Word64 !Word64
  | -- | The loose list would outgrow its cap at the smallest unit of work: run
    -- maintenance (which hands loose pages on to the allocator) and plan again.
    NeedMaintenance
  | -- | The candidate was prepared against another authority or version than the
    -- store's: the caller remakes it against the current store and plans again.
    Replan
  | -- | A refusal the driver cannot resolve, and its class. 'FailDisk' is the pause
    -- @storage_full@, 'FailIntegrity' @storage_integrity@; none of them is a retry.
    Refuse !PlanRefusal !Failure
  | -- | The protocol could not make progress. A defect, never a domain outcome.
    Stuck !Stall

-- | Why a driver could not make progress.
data Stall
  = -- | A refusal that the window is too small, at a window already at its smallest unit
    -- of work: the unit must fit, so this is a defect of the planner or of the bounds.
    UnitDidNotFit !CapacityWhy
  | -- | The plan named a page the window already holds.
    PageAlreadyHeld !PageNo
  | -- | The plan was run again before every page it named was supplied.
    PlanRunBeforeSupply ![PageNo]
  | -- | A page the plan did not ask for was supplied.
    UnaskedPage !PageNo
  | -- | More checkpoints than a plan can take: the bound is 'maxCheckpoints'.
    TooManyCheckpoints !Int
  | -- | A page the backing returned failed validation. It is an integrity failure of the
    -- backing, never absent history.
    PageRefused !PageNo !PageError
  deriving stock (Show)

-- | The checkpoints one plan can take. A checkpoint always carries a new fact; a
-- transaction takes at most as many as the pages it writes plus the pages it verifies
-- consumed by an entry it frees, and a read phase one more for each record it reads.
maxCheckpoints ∷ Int
maxCheckpoints = maxTxnPages + maxReclaimPages + worstEditReads

-- | Begin planning against a store through a fresh window.
newDriver ∷ Store → Planner → Driver
newDriver store planner = newDriverIn store (storeWindow store) planner

-- | Begin planning through a given window of the store's committed version (one that may
-- carry a work limit or facts). A window of another version is refused by the planner.
newDriverIn ∷ Store → Window → Planner → Driver
newDriverIn store window planner = Driver store planner window 0 0 0 0 [] False

driverStore ∷ Driver → Store
driverStore = dvStore

-- | The window the next planner call runs through.
driverWindow ∷ Driver → Window
driverWindow = dvWindow

-- | The work the current window allows.
driverWindowWork ∷ Driver → Int
driverWindowWork = windowWork . dvWindow

driverCheckpoints, driverReductions, driverReadPeak, driverFactPeak ∷ Driver → Int
driverCheckpoints = dvCheckpoints
driverReductions = dvReductions
driverReadPeak = dvReadPeak
driverFactPeak = dvFactPeak

-- | The planner, run through the driver's window.
runTask ∷ Driver → Planned
runTask d = dvPlanner d (dvWindow d)

-- | Run the planner until it needs the caller. Checkpoints and window reductions are
-- the driver's own: they cost no I/O, so the owner's quantum does them in one step.
advance ∷ Driver → (Driver, Step)
advance d
  | not (null (dvAsked d)) = (d, Stuck (PlanRunBeforeSupply (dvAsked d)))
  | otherwise = case runTask d of
      Planned plan → (d, Ready plan)
      NoWork → (d, NothingToDo)
      BlockedByReader version oldest → (d, WaitsForReader version oldest)
      Pending page
        | page `elem` windowPageNumbers (dvWindow d) → (d, Stuck (PageAlreadyHeld page))
        | otherwise → (d {dvAsked = [page], dvProbing = False}, NeedPages [page])
      PendingProbes pages → (d {dvAsked = pages, dvProbing = True}, NeedProbes pages)
      Checkpoint facts → checkpoint facts d
      Refused refusal → refused refusal d

checkpoint ∷ Facts → Driver → (Driver, Step)
checkpoint facts d
  | dvCheckpoints d >= maxCheckpoints = (d, Stuck (TooManyCheckpoints (dvCheckpoints d)))
  | otherwise =
      advance
        d
          { dvWindow = windowCheckpoint facts (dvWindow d)
          , dvCheckpoints = dvCheckpoints d + 1
          , dvReadPeak = max (dvReadPeak d) (windowSize (dvWindow d))
          , dvFactPeak = max (dvFactPeak d) (windowReadFactCount (windowCheckpoint facts (dvWindow d)))
          }

-- | A refusal that says the window (or the loose list) was too big for the unit of work
-- it was given is retried through a fresh window of the same version with half the
-- work; the unit (one page, or the three writes of one connection) always fits. Every
-- other refusal is the caller's to classify.
refused ∷ PlanRefusal → Driver → (Driver, Step)
refused refusal d = case refusal of
  Capacity why
    | windowBound why → shrink why
    | LooseExceeded _ ← why → shrink why
  Stale _ → (d, Replan)
  _ → (d, Refuse refusal (classifyPlan refusal))
  where
    shrink why
      | windowWork (dvWindow d) <= 1 = case why of
          LooseExceeded _ → (d, NeedMaintenance)
          _ → (d, Stuck (UnitDidNotFit why))
      | otherwise =
          advance
            d
              { dvWindow = reduceWork (dvWindow d) (storeWindow (dvStore d))
              , dvReductions = dvReductions d + 1
              }
    windowBound = \case
      WindowExceeded _ → True
      WindowBytesExceeded _ → True
      ProbesExceeded _ → True
      DiskFull {} → False
      TxnPagesExceeded _ → False
      TxnRamExceeded _ → False
      OverlayExceeded _ → False
      TreeTooTall _ → False
      ListTooLarge _ → False
      RetirementBacklog _ _ → False
      BookkeepingExceeded _ → False
      LooseExceeded _ → False

-- | Give the driver a page it asked for. The page is validated against the store
-- (arena, source, number, checksum, structure) by the window; a page that fails is the
-- backing's integrity failure, never an empty index.
supplyPage ∷ PageNo → ByteString → Driver → Either Stall Driver
supplyPage page bytes d
  | dvProbing d || page `notElem` dvAsked d = Left (UnaskedPage page)
  | otherwise = case windowInsert (cfgTotalPages (storeConfig (dvStore d))) page bytes (dvWindow d) of
      Left err → Left (PageRefused page err)
      Right w → Right d {dvWindow = w, dvAsked = filter (/= page) (dvAsked d)}

-- | Give the driver the classification of a page it asked to have probed. A buffer
-- that is not a page of this store is recorded as nothing, never refused.
supplyProbe ∷ PageNo → ByteString → Driver → Either Stall Driver
supplyProbe page bytes d
  | not (dvProbing d) || page `notElem` dvAsked d = Left (UnaskedPage page)
  | otherwise =
      Right
        d
          { dvWindow = windowProbe (cfgTotalPages (storeConfig (dvStore d))) page bytes (dvWindow d)
          , dvAsked = filter (/= page) (dvAsked d)
          }
