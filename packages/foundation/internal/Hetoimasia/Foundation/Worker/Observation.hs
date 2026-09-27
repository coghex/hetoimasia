-- | Reading a group and its workers: the drain status, the active count,
-- startup acknowledgement, raw completion, and the owner's committed
-- observation with the settled retirement it triggers.
--
-- This module belongs to the package's private @internal@ sublibrary and is
-- not exposed even there: "Hetoimasia.Foundation.Worker.Internal" re-exports
-- its public operations for the rest of the package, and the other worker
-- modules import it directly. It is private because 'retireIfSettled' and
-- 'settledSummary' act on group state no client can name.
--
-- It imports "Hetoimasia.Foundation.Worker.Base",
-- "Hetoimasia.Foundation.Worker.Outcome", and
-- "Hetoimasia.Foundation.Worker.Types". It owns the one settled-retirement
-- operation, which observation here and cancellation in
-- "Hetoimasia.Foundation.Worker.Requests" both use, and the one settled read
-- that single-worker and group drains both wait on.
--
-- = State
--
-- It writes a worker's observed flag and, through 'retireIfSettled', removes a
-- settled worker from the group's active set and keeps a retired failure in
-- the group's retained map. Everything else here only reads.
module Hetoimasia.Foundation.Worker.Observation
  ( -- * Group
    groupStatus
  , activeWorkerCount

    -- * One worker
  , awaitStartup
  , awaitCompletion
  , pollCompletion
  , observeCompletion

    -- * Settlement
  , retireIfSettled
  , settledSummary
  ) where

import Control.Concurrent.STM (STM, check, modifyTVar', readTVar, retry, writeTVar)
import Control.Monad (unless)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, isJust)
import Hetoimasia.Foundation.Worker.Base (GroupPhase (..), Phase (..))
import Hetoimasia.Foundation.Worker.Outcome (Completion, Startup (..), WorkerSummary, succeeded)
import Hetoimasia.Foundation.Worker.Types
  ( Entry (..)
  , GroupStatus (GroupStatus)
  , Outstanding (..)
  , OutstandingWorker (OutstandingWorker)
  , Worker (..)
  , WorkerGroup (..)
  )

-- Group ----------------------------------------------------------------------

-- | One coherent snapshot of the group's phase and of every worker its drain
-- would still wait for.
--
-- A worker is outstanding while it has not published its terminal outcome or
-- a cancellation helper still targets it; a settled worker, including one kept
-- only for the report or for observation, is not. Workers are listed in
-- registration order, and none once the report is published.
--
-- The query only reads: it never retries, waits for lifecycle progress, or
-- writes group state, so reading it from any thread changes neither the drain
-- nor its report. It names no cause for a stall and says nothing about
-- whether a worker's resources are safe to release. Elapsed time, sampling,
-- output, and any deadline belong to the caller.
groupStatus ∷ WorkerGroup → STM GroupStatus
groupStatus group =
  readTVar (groupPhase group) >>= \case
    Closed → pure (GroupStatus GroupClosed [])
    phase → do
      entries ← Map.elems <$> readTVar (groupActive group)
      GroupStatus (publicPhase phase) . catMaybes <$> traverse outstanding entries
  where
    publicPhase Open = GroupOpen
    publicPhase Closing = GroupClosing
    publicPhase Closed = GroupClosed
    outstanding entry = do
      terminal ← isJust <$> readTVar (entrySummary entry)
      helpers ← readTVar (entryHelpers entry)
      if terminal && helpers == 0
        then pure Nothing
        else
          fmap Just $
            OutstandingWorker (entryId entry) (entryLabel entry)
              <$> readTVar (entryAcknowledged entry)
              <*> readTVar (entryRequests entry)
              <*> readTVar (entryCancelDelivered entry)
              <*> pure (if terminal then AwaitingHelpers else AwaitingTerminal)
              <*> pure helpers

-- | How many workers the group still keeps in active bookkeeping: every worker
-- not yet retired by 'observeCompletion'. Zero once the group has closed.
activeWorkerCount ∷ WorkerGroup → STM Int
activeWorkerCount group = Map.size <$> readTVar (groupActive group)

-- One worker -----------------------------------------------------------------

-- | Retry until the worker acknowledges startup or ends without acknowledging.
--
-- Acknowledgement is independent of completion: a worker that acknowledged and
-- has already finished reports 'Acknowledged', and its completion is ready
-- too.
awaitStartup ∷ Worker r → STM (Startup r)
awaitStartup worker = do
  acknowledged ← readTVar (entryAcknowledged (workerEntry worker))
  if acknowledged
    then pure Acknowledged
    else readTVar (workerCompletion worker) >>= maybe retry (pure . NotAcknowledged)

-- | Retry until the worker's terminal outcome is published.
--
-- This is a raw read: any number of readers may wait, it consumes nothing, it
-- does not stop, cancel, or retire the worker, and a reader cancelled while
-- waiting leaves the worker untouched.
awaitCompletion ∷ Worker r → STM (Completion r)
awaitCompletion worker = readTVar (workerCompletion worker) >>= maybe retry pure

-- | The terminal outcome if it has been published. A raw read, like
-- 'awaitCompletion'.
pollCompletion ∷ Worker r → STM (Maybe (Completion r))
pollCompletion worker = readTVar (workerCompletion worker)

-- | Commit the owner's observation of a terminal outcome, if one is published.
--
-- Once observed and once its cancellation helper, if any, has finished, the
-- worker is retired from active bookkeeping. A retired success is dropped from
-- the group; a retired 'Hetoimasia.Foundation.Worker.Failed' or
-- 'Hetoimasia.Foundation.Worker.Cancelled' outcome is kept for the
-- 'Hetoimasia.Foundation.Worker.GroupReport'. The handle still exposes the
-- same outcome. A worker that is not terminal is neither observed nor retired,
-- and raw readers never retire anything.
observeCompletion ∷ Worker r → STM (Maybe (Completion r))
observeCompletion worker =
  readTVar (workerCompletion worker) >>= \case
    Nothing → pure Nothing
    Just completion → do
      writeTVar (entryObserved (workerEntry worker)) True
      retireIfSettled (workerGroup worker) (workerEntry worker)
      pure (Just completion)

-- Settlement -----------------------------------------------------------------

-- | Retire a worker that is terminal, observed, and targeted by no helper,
-- while the group is not closed.
retireIfSettled ∷ WorkerGroup → Entry → STM ()
retireIfSettled group entry = do
  observed ← readTVar (entryObserved entry)
  summary ← readTVar (entrySummary entry)
  helpers ← readTVar (entryHelpers entry)
  phase ← readTVar (groupPhase group)
  case summary of
    Just settled | observed, helpers == 0, phase /= Closed → do
      modifyTVar' (groupActive group) (Map.delete (entryId entry))
      unless (succeeded settled) $
        modifyTVar' (groupRetained group) (Map.insert (entryId entry) settled)
    _ → pure ()

-- | The worker's summary once it is terminal and no helper targets it.
settledSummary ∷ Entry → STM WorkerSummary
settledSummary entry = do
  summary ← readTVar (entrySummary entry) >>= maybe retry pure
  helpers ← readTVar (entryHelpers entry)
  check (helpers == 0)
  pure summary
