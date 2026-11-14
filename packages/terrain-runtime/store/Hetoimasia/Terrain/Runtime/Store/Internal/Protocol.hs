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
-- | @Checkpoint facts@                      | 'Continue': a fresh window of the same version   |
-- |                                         | keeps the facts ('windowCheckpoint'); no I/O     |
-- | @Refused (Capacity window-bound)@       | 'Continue' with a fresh window, half the work    |
-- |                                         | ('reduceWork'), and a fresh checkpoint count     |
-- | @Refused (Capacity LooseExceeded)@      | the same; at the smallest unit 'NeedMaintenance' |
-- | @Refused (Stale _)@                     | 'Replan': the candidate is the caller's to remake|
-- | @Refused other@ (each constructor named) | 'Refuse', classified by 'classifyPlan'           |
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
  , Supply (..)
  , advance
  , supplyPage
  , supplyProbe
  , driverStore
  , driverWindow
  , driverWindowWork
  , driverCheckpoints
  , driverWindowCheckpoints
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
  -- ^ in the CURRENT window: a reduction starts a fresh window and a fresh count
  , dvTotalCheckpoints ∷ !Int
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
--
-- 'advance' runs the planner EXACTLY ONCE. A step is therefore bounded by one planner run
-- (the planner's own bounds: at most 4 MiB of RAM, at most 'worstEditReads' records read, at most
-- 256 pages written), and the owner serves its cancellation, closure and other arenas between
-- steps. A checkpoint and a window reduction cost no I/O but are steps of their own ('Continue').
data Step
  = -- | The planner ran, and a checkpoint or a window reduction gave a fresh window: call
    -- 'advance' again. No I/O is owed.
    Continue
  | -- | Pages the plan needs (the first of them; the plan is run again once given). The
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

-- | Why a driver could not make progress: the protocol's OWN errors, the caller's or the planner's
-- defects. A page the backing returned that the window refuses is not one of them ('Supply').
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
  | -- | More checkpoints in ONE window than a plan can take: the bound is 'maxCheckpoints'. A
    -- reduction starts a fresh window and a fresh count (the facts are gone with the window).
    TooManyCheckpoints !Int
  deriving stock (Show)

-- | Why a page could not be given to the driver. The two kinds are never confused: a page that
-- is not the authoritative page it should be is the BACKING's integrity failure (the arena
-- pauses for @storage_integrity@, never absent history, air or the source), and a protocol
-- error is a defect of the caller.
data Supply
  = -- | The window refused the page the backing returned (checksum, format, identity, place).
    -- The backend validates every page it reads against the same store, so it refuses it first
    -- and this is reached only if the two validations ever disagree; either way it is the
    -- same classification.
    PageRefusedByWindow !PageNo !PageError
  | ProtocolError !Stall
  deriving stock (Show)

-- | The checkpoints ONE window can take. A checkpoint always carries a new fact; a
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
newDriverIn store window planner = Driver store planner window 0 0 0 0 0 [] False

driverStore ∷ Driver → Store
driverStore = dvStore

-- | The window the next planner call runs through.
driverWindow ∷ Driver → Window
driverWindow = dvWindow

-- | The work the current window allows.
driverWindowWork ∷ Driver → Int
driverWindowWork = windowWork . dvWindow

-- | Over the driver's whole life (every window it used).
driverCheckpoints, driverWindowCheckpoints, driverReductions, driverReadPeak, driverFactPeak ∷ Driver → Int
driverCheckpoints = dvTotalCheckpoints
driverWindowCheckpoints = dvCheckpoints
driverReductions = dvReductions
driverReadPeak = dvReadPeak
driverFactPeak = dvFactPeak

-- | Run the planner ONCE and say what the caller owes.
advance ∷ Driver → (Driver, Step)
advance d
  | not (null (dvAsked d)) = (d, Stuck (PlanRunBeforeSupply (dvAsked d)))
  | otherwise = case dvPlanner d (dvWindow d) of
      Planned plan → (d, Ready plan)
      NoWork → (d, NothingToDo)
      BlockedByReader version oldest → (d, WaitsForReader version oldest)
      Pending page
        | page `elem` windowPageNumbers (dvWindow d) → (d, Stuck (PageAlreadyHeld page))
        | otherwise → (d {dvAsked = [page], dvProbing = False}, NeedPages [page])
      PendingProbes pages → (d {dvAsked = pages, dvProbing = True}, NeedProbes pages)
      Checkpoint facts → checkpoint facts d
      Refused refusal → refused refusal d

-- | A fresh window of the same version that keeps what the plan proved and read.
checkpoint ∷ Facts → Driver → (Driver, Step)
checkpoint facts d
  | dvCheckpoints d >= maxCheckpoints = (d, Stuck (TooManyCheckpoints (dvCheckpoints d)))
  | otherwise =
      let next = windowCheckpoint facts (dvWindow d)
       in ( d
              { dvWindow = next
              , dvCheckpoints = dvCheckpoints d + 1
              , dvTotalCheckpoints = dvTotalCheckpoints d + 1
              , dvReadPeak = max (dvReadPeak d) (windowSize (dvWindow d))
              , dvFactPeak = max (dvFactPeak d) (windowReadFactCount next)
              }
          , Continue
          )

-- | Every refusal of the planner has a case. A refusal that says the window (or the loose list) was too
-- big for the unit of work it was given is retried through a fresh window of the same version with half
-- the work (the unit, one page or the three writes of one connection, always fits, and the work strictly
-- halves, so there are at most six reductions); the fresh window has no facts, so its checkpoints count
-- afresh. Every other refusal is the caller's to classify.
refused ∷ PlanRefusal → Driver → (Driver, Step)
refused refusal d = case refusal of
  Stale _ → (d, Replan)
  Invalid _ → refuse
  Integrity _ → refuse
  Capacity why → case why of
    WindowExceeded _ → shrink why
    WindowBytesExceeded _ → shrink why
    ProbesExceeded _ → shrink why
    LooseExceeded _ → shrink why
    DiskFull {} → refuse
    TxnPagesExceeded _ → refuse
    TxnRamExceeded _ → refuse
    OverlayExceeded _ → refuse
    TreeTooTall _ → refuse
    ListTooLarge _ → refuse
    RetirementBacklog _ _ → refuse
    BookkeepingExceeded _ → refuse
  where
    refuse = (d, Refuse refusal (classifyPlan refusal))
    shrink why
      | windowWork (dvWindow d) <= 1 = case why of
          LooseExceeded _ → (d, NeedMaintenance)
          WindowExceeded _ → (d, Stuck (UnitDidNotFit why))
          WindowBytesExceeded _ → (d, Stuck (UnitDidNotFit why))
          ProbesExceeded _ → (d, Stuck (UnitDidNotFit why))
          DiskFull {} → (d, Stuck (UnitDidNotFit why))
          TxnPagesExceeded _ → (d, Stuck (UnitDidNotFit why))
          TxnRamExceeded _ → (d, Stuck (UnitDidNotFit why))
          OverlayExceeded _ → (d, Stuck (UnitDidNotFit why))
          TreeTooTall _ → (d, Stuck (UnitDidNotFit why))
          ListTooLarge _ → (d, Stuck (UnitDidNotFit why))
          RetirementBacklog _ _ → (d, Stuck (UnitDidNotFit why))
          BookkeepingExceeded _ → (d, Stuck (UnitDidNotFit why))
      | otherwise =
          ( d
              { dvWindow = reduceWork (dvWindow d) (storeWindow (dvStore d))
              , dvReductions = dvReductions d + 1
              , dvCheckpoints = 0
              }
          , Continue
          )

-- | Give the driver a page it asked for. The page is validated against the store
-- (arena, source, number, checksum, structure) by the window; a page that fails is the
-- backing's integrity failure, never an empty index.
supplyPage ∷ PageNo → ByteString → Driver → Either Supply Driver
supplyPage page bytes d
  | dvProbing d || page `notElem` dvAsked d = Left (ProtocolError (UnaskedPage page))
  | otherwise = case windowInsert (cfgTotalPages (storeConfig (dvStore d))) page bytes (dvWindow d) of
      Left err → Left (PageRefusedByWindow page err)
      Right w → Right d {dvWindow = w, dvAsked = filter (/= page) (dvAsked d)}

-- | Give the driver the classification of a page it asked to have probed. A buffer
-- that is not a page of this store is recorded as nothing, never refused.
supplyProbe ∷ PageNo → ByteString → Driver → Either Supply Driver
supplyProbe page bytes d
  | not (dvProbing d) || page `notElem` dvAsked d = Left (ProtocolError (UnaskedPage page))
  | otherwise =
      Right
        d
          { dvWindow = windowProbe (cfgTotalPages (storeConfig (dvStore d))) page bytes (dvWindow d)
          , dvAsked = filter (/= page) (dvAsked d)
          }
