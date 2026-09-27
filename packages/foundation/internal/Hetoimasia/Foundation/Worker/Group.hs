-- | The group lifetime: the owning boundary and its 'Scoped' adapter, group
-- creation, closing and its snapshot, the report, and the protected drain with
-- its escalation.
--
-- This module belongs to the package's private @internal@ sublibrary and is
-- not exposed even there: "Hetoimasia.Foundation.Worker.Internal" re-exports
-- the lifetime operations for the rest of the package, including the
-- coordination probe's 'withWorkerGroupProbed', which the public module then
-- hides. It is private because closing, the report, and the drain write group
-- state no client can name.
--
-- It imports every worker module below it — "Hetoimasia.Foundation.Worker.Base",
-- "Hetoimasia.Foundation.Worker.Outcome", "Hetoimasia.Foundation.Worker.Types",
-- "Hetoimasia.Foundation.Worker.Observation",
-- "Hetoimasia.Foundation.Worker.Requests", and
-- "Hetoimasia.Foundation.Worker.Evidence" — and the resource family's
-- "Hetoimasia.Foundation.Resource.Scoped". It never imports
-- "Hetoimasia.Foundation.Worker.Startup", which never imports it: the group
-- sees a started worker only through its state.
--
-- = State
--
-- It creates every group variable and fixes the group's coordination probe. It
-- alone writes the group's phase, the closing snapshot, and the report;
-- closing strengthens each live worker's request to a stop, and the report
-- empties the active set and the retained map.
module Hetoimasia.Foundation.Worker.Group
  ( withWorkerGroup
  , withWorkerGroupProbed
  , allocWorkerGroup
  , closeWorkerGroup
  , newWorkerGroup
  , beginClosing
  , awaitReport
  , drainGroup
  , escalate
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (ExceptionWithContext, SomeException, mask, rethrowIO)
import Control.Monad (when)
import Data.Foldable (for_, traverse_)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Resource.Scoped (Scoped (Scoped))
import Hetoimasia.Foundation.Worker.Base (Phase (..), Requested (..))
import Hetoimasia.Foundation.Worker.Evidence (WorkerEvidence (..), attachEvidence)
import Hetoimasia.Foundation.Worker.Observation (settledSummary)
import Hetoimasia.Foundation.Worker.Outcome
  ( Completion (..)
  , GroupReport (..)
  , reportCleanup
  , succeeded
  , trySome
  )
import Hetoimasia.Foundation.Worker.Requests (requestCancelEntry)
import Hetoimasia.Foundation.Worker.Types
  ( ClosingSnapshot (..)
  , Entry (..)
  , GroupProbe
  , WorkerGroup (..)
  , noProbe
  )

-- | Run a body that owns a worker group, and drain every worker before
-- returning or rethrowing.
--
-- Call this inside the scopes of every component the workers borrow. The body
-- runs with the caller's masking state. When it returns or throws:
--
-- 1. Closing begins, if the body did not already close the group with
--    'closeWorkerGroup': the report's snapshot is taken, registration closes,
--    and a stop is requested from every live worker, all in one transaction.
-- 2. If the body failed or was cancelled, cancellation is requested of every
--    live worker.
-- 3. The owner waits until every worker is terminal and every cancellation
--    helper has finished. An asynchronous exception delivered during this wait
--    does not end it. If the body had returned normally, the first such
--    exception becomes the owner's pending failure and cancellation is
--    requested of the live workers; later ones are absorbed.
--
-- Then the body's result is returned, or the pending failure is rethrown with
-- its own type, value, and context, a 'GroupExit' 'WorkerEvidence' annotation,
-- and every cleanup failure the report's workers retained, which
-- 'Hetoimasia.Foundation.Resource.cleanupFailures' reads back.
--
-- If a worker never becomes terminal, this never returns. A normal return
-- discards the report; a body that needs it calls 'closeWorkerGroup' itself.
withWorkerGroup ∷ (WorkerGroup → IO a) → IO a
withWorkerGroup = withWorkerGroupProbed noProbe

-- | 'withWorkerGroup' with a coordination probe installed on the group.
withWorkerGroupProbed ∷ GroupProbe → (WorkerGroup → IO a) → IO a
withWorkerGroupProbed probe body = mask $ \restore → do
  group ← newWorkerGroup probe
  outcome ← trySome (restore (body group))
  atomically (beginClosing group)
  initial ← case outcome of
    Left failure → Just <$> escalate group failure
    Right _ → pure Nothing
  (report, pending) ← drainGroup group initial
  let attach = attachEvidence (GroupExit report) (reportCleanup report)
  case pending of
    Just failure → rethrowIO (attach failure)
    Nothing → either (rethrowIO . attach) pure outcome

-- | 'withWorkerGroup' composed in 'Scoped'.
--
-- The group's lifetime is the rest of the enclosing
-- 'Hetoimasia.Foundation.Resource.withScoped' continuation. Allocations made
-- before this line outlive the drain; allocations made after it are released
-- before the drain begins and must not be borrowed by the group's workers.
allocWorkerGroup ∷ Scoped WorkerGroup
allocWorkerGroup = Scoped withWorkerGroup

-- | Close the group and wait for its report.
--
-- Closing begins as in step 1 of 'withWorkerGroup', and then this waits for
-- every worker and helper. The wait is cancellable: a cancellation escapes to
-- the owner, whose exit then requests cancellation of the remaining workers and
-- performs the protected drain. Calling it again, or after the owner has
-- drained, returns the same report. A worker of this group must not call it,
-- since the wait includes that worker.
closeWorkerGroup ∷ WorkerGroup → IO GroupReport
closeWorkerGroup group = do
  atomically (beginClosing group)
  atomically (awaitReport group)

newWorkerGroup ∷ GroupProbe → IO WorkerGroup
newWorkerGroup probe =
  WorkerGroup
    <$> newTVarIO Open
    <*> newTVarIO 0
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Nothing
    <*> newTVarIO Nothing
    <*> pure probe

-- | Take the closing snapshot, close registration, and request a stop from
-- every live worker, once. Every outcome published before this commits is in
-- the snapshot, and every run exit recorded after it sees the stop request.
beginClosing ∷ WorkerGroup → STM ()
beginClosing group = do
  phase ← readTVar (groupPhase group)
  when (phase == Open) $ do
    entries ← Map.elems <$> readTVar (groupActive group)
    states ← traverse entryState entries
    retained ← Map.elems <$> readTVar (groupRetained group)
    let exited = [summary | (_, Just summary, False) ← states]
        observed =
          sortOn completionWorker $
            retained <> [summary | (_, Just summary, True) ← states, not (succeeded summary)]
        live = [entry | (entry, Nothing, _) ← states]
    for_ live $ \entry → modifyTVar' (entryRequests entry) (max StopWasRequested)
    writeTVar (groupClosing group) (Just (ClosingSnapshot exited observed live))
    writeTVar (groupPhase group) Closing
  where
    entryState entry =
      (,,) entry <$> readTVar (entrySummary entry) <*> readTVar (entryObserved entry)

-- | Retry until every worker is terminal and every helper has finished, then
-- publish the report and mark the group closed, once.
awaitReport ∷ WorkerGroup → STM GroupReport
awaitReport group =
  readTVar (groupReport group) >>= \case
    Just report → pure report
    Nothing → do
      snapshot ← readTVar (groupClosing group) >>= maybe retry pure
      entries ← Map.elems <$> readTVar (groupActive group)
      traverse_ settledSummary entries
      drained ← traverse settledSummary (closingLive snapshot)
      let report = GroupReport (closingExited snapshot) drained (closingObserved snapshot)
      writeTVar (groupReport group) (Just report)
      writeTVar (groupPhase group) Closed
      writeTVar (groupClosing group) Nothing
      writeTVar (groupActive group) Map.empty
      writeTVar (groupRetained group) Map.empty
      pure report

-- | The protected drain: wait for the report, absorbing interruptions.
drainGroup
  ∷ WorkerGroup
  → Maybe (ExceptionWithContext SomeException)
  → IO (GroupReport, Maybe (ExceptionWithContext SomeException))
drainGroup group = loop
  where
    loop pending = do
      settled ← trySome (atomically (awaitReport group))
      case settled of
        Right report → pure (report, pending)
        Left interruption → case pending of
          Just _ → loop pending
          Nothing → escalate group interruption >>= loop . Just

-- | Request cancellation of every live worker on behalf of a failing owner,
-- keeping the owner's failure primary. A helper that cannot be forked leaves
-- that worker's stop and cancellation requests in place, and the drain still
-- waits for it.
escalate
  ∷ WorkerGroup
  → ExceptionWithContext SomeException
  → IO (ExceptionWithContext SomeException)
escalate group failure = do
  entries ← atomically (Map.elems <$> readTVar (groupActive group))
  for_ entries $ \entry → trySome (requestCancelEntry group entry)
  pure failure
