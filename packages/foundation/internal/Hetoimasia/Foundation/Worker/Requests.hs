-- | Requests made of a started worker: the cooperative stop, cancellation and
-- the group-owned helper that delivers it, and the protected single-worker
-- drain a failing starter waits in.
--
-- This module belongs to the package's private @internal@ sublibrary and is
-- not exposed even there: "Hetoimasia.Foundation.Worker.Internal" re-exports
-- 'requestStop' and 'requestCancel' for the rest of the package, and the other
-- worker modules import this module directly. It is private because
-- 'requestCancelEntry' and 'drainWorker' act on a group entry no client can
-- name.
--
-- It imports "Hetoimasia.Foundation.Worker.Base",
-- "Hetoimasia.Foundation.Worker.Outcome", "Hetoimasia.Foundation.Worker.Types",
-- and "Hetoimasia.Foundation.Worker.Observation", whose settled retirement a
-- helper triggers when it deregisters. Both
-- "Hetoimasia.Foundation.Worker.Startup" and
-- "Hetoimasia.Foundation.Worker.Group" import it.
--
-- = State
--
-- It strengthens a worker's request, and it alone writes the helper count, the
-- sent flag, and the delivered flag. It reads the worker's thread identity and
-- runs the group's coordination probe on each helper.
module Hetoimasia.Foundation.Worker.Requests
  ( requestStop
  , requestCancel
  , requestCancelEntry
  , deliverCancellation
  , drainWorker
  ) where

import Control.Concurrent (forkIO, throwTo)
import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar, retry, writeTVar)
import Control.Exception (mask_, rethrowIO)
import Control.Monad (when)
import Data.Foldable (traverse_)
import Data.Maybe (isJust)
import Hetoimasia.Foundation.Worker.Base (Requested (..), WorkerCancelled (..))
import Hetoimasia.Foundation.Worker.Observation (retireIfSettled, settledSummary)
import Hetoimasia.Foundation.Worker.Outcome (WorkerSummary, trySome)
import Hetoimasia.Foundation.Worker.Types (Entry (..), GroupProbe (..), Worker (..), WorkerGroup (..))

-- | Request a cooperative stop.
--
-- A non-blocking transition of the worker's stop token: it runs no callback,
-- is idempotent, and never weakens a cancellation request or resets the token.
-- The worker decides how to exit. Requesting a stop of a terminal worker
-- changes nothing observable.
requestStop ∷ Worker r → STM ()
requestStop worker = modifyTVar' (entryRequests (workerEntry worker)) (max StopWasRequested)

-- | Request cancellation.
--
-- The request is recorded at once, and it is also a stop request. The first
-- request of a live worker registers and forks one group-owned helper thread
-- that delivers 'WorkerCancelled' to the worker with 'throwTo'. Delivery can
-- block, for as long as the worker is inside an uninterruptible region or a
-- foreign call, so it never runs on the requesting thread and never inside a
-- resource release. The helper is joined by the group's drain; it is never
-- detached. Later requests fork nothing.
--
-- A worker already terminal forks no helper.
requestCancel ∷ Worker r → IO ()
requestCancel worker = requestCancelEntry (workerGroup worker) (workerEntry worker)

-- | 'requestCancel' for a group entry, as the group's escalation reaches it.
requestCancelEntry ∷ WorkerGroup → Entry → IO ()
requestCancelEntry group entry = mask_ $ do
  send ← atomically $ do
    writeTVar (entryRequests entry) CancelWasRequested
    settled ← isJust <$> readTVar (entrySummary entry)
    sent ← readTVar (entryCancelSent entry)
    if settled || sent
      then pure False
      else do
        writeTVar (entryCancelSent entry) True
        modifyTVar' (entryHelpers entry) (+ 1)
        pure True
  when send $ do
    forked ← trySome (forkIO (deliverCancellation group entry))
    case forked of
      Right _ → pure ()
      Left failure → do
        atomically $ do
          writeTVar (entryCancelSent entry) False
          modifyTVar' (entryHelpers entry) (subtract 1)
          retireIfSettled group entry
        rethrowIO failure

-- | The helper: wait for the worker's thread, deliver the cancellation unless
-- the worker is already terminal, and deregister, recording a delivery in the
-- same transaction.
deliverCancellation ∷ WorkerGroup → Entry → IO ()
deliverCancellation group entry = do
  attempt ← trySome $ do
    target ← atomically $
      readTVar (entrySummary entry) >>= \case
        Just _ → pure Nothing
        Nothing → readTVar (entryThread entry) >>= maybe retry (pure . Just)
    traverse_ (`throwTo` WorkerCancelled) target
    pure (isJust target)
  _ ← trySome (probeHelperSettling (groupProbe group) (entryId entry))
  atomically $ do
    when (either (const False) id attempt) $
      writeTVar (entryCancelDelivered entry) True
    modifyTVar' (entryHelpers entry) (subtract 1)
    retireIfSettled group entry

-- | Request cancellation of one worker and wait for it and its helper,
-- absorbing interruptions, for a starter that is already failing.
drainWorker ∷ Worker r → IO WorkerSummary
drainWorker worker = do
  _ ← trySome (requestCancelEntry (workerGroup worker) (workerEntry worker))
  let loop = trySome (atomically (settledSummary (workerEntry worker))) >>= either (const loop) pure
  loop
