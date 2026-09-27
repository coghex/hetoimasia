-- | Starting a worker: registration, the masked fork, the preparation and
-- startup handoff, the child thread, and the terminal publication.
--
-- This module belongs to the package's private @internal@ sublibrary and is
-- not exposed even there: "Hetoimasia.Foundation.Worker.Internal" re-exports
-- 'startWorker' and 'startWorkerWith' for the rest of the package. It is
-- private because 'register', 'runChild', and 'publish' write group state no
-- client can name.
--
-- It imports every worker module below it — "Hetoimasia.Foundation.Worker.Base",
-- "Hetoimasia.Foundation.Worker.Outcome", "Hetoimasia.Foundation.Worker.Types",
-- "Hetoimasia.Foundation.Worker.Observation",
-- "Hetoimasia.Foundation.Worker.Requests", and
-- "Hetoimasia.Foundation.Worker.Evidence" — and the resource family's
-- "Hetoimasia.Foundation.Resource.Scoped". It never imports
-- "Hetoimasia.Foundation.Worker.Group", which never imports it: a start
-- reaches the group only through its state.
--
-- = State
--
-- It advances the group's registration counter and inserts each new entry into
-- the active set. For each worker it writes the thread identity, opens the
-- start gate, and — on the child thread — writes the acknowledgement, the
-- run-exit record, and the terminal completion and summary.
module Hetoimasia.Foundation.Worker.Startup
  ( startWorker
  , startWorkerWith
  , register
  , runChild
  , publish
  ) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.STM (STM, atomically, check, modifyTVar', newTVar, readTVar, writeTVar)
import Control.Exception (evaluate, mask, rethrowIO)
import Control.Monad (void)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Hetoimasia.Foundation.Resource.Scoped (Scoped, withScoped)
import Hetoimasia.Foundation.Worker.Base (Phase (..), Requested (..), StopToken (..), WorkerId (..))
import Hetoimasia.Foundation.Worker.Evidence (WorkerEvidence (..), attachEvidence)
import Hetoimasia.Foundation.Worker.Observation (awaitStartup)
import Hetoimasia.Foundation.Worker.Outcome
  ( Completion (..)
  , Result (..)
  , RunEnd (..)
  , RunExit (..)
  , StartRejection (..)
  , Startup (..)
  , failureResult
  , resultCleanup
  , trySome
  )
import Hetoimasia.Foundation.Worker.Requests (drainWorker)
import Hetoimasia.Foundation.Worker.Types
  ( Entry (..)
  , StartOutcome (..)
  , Worker (..)
  , WorkerDefinition (..)
  , WorkerGroup (..)
  )

-- | Start a worker and wait cancellably for its startup.
--
-- This is 'startWorkerWith' with no preparation and 'awaitStartup' as the
-- wait. A failed or cancelled wait drains the worker before propagating, as
-- 'startWorkerWith' describes.
startWorker ∷ WorkerGroup → WorkerDefinition r → IO (StartOutcome r)
startWorker group definition = do
  started ← startWorkerWith group definition (\_ → pure ()) awaitStartup
  pure $ case started of
    Left rejection → StartRejected rejection
    Right (worker, Acknowledged) → Started worker
    Right (worker, NotAcknowledged completion) → StartupFailed worker completion

-- | Start a worker with an explicit preparation step and a caller-composed
-- startup wait.
--
-- The handoff, in order:
--
-- 1. Registration: in one transaction the group is checked for open
--    registration and the worker is registered in it. A closed group returns
--    @'Left' 'RegistrationClosed'@ and forks nothing.
-- 2. The fork, masked and with nothing interruptible between registration and
--    it. The child starts at a closed gate: it runs none of its definition.
--    If the fork itself fails, the worker is published as a terminal failure
--    with 'RunNotEntered' and the failure propagates.
-- 3. @prepare@ runs with the caller's masking state and the worker handle,
--    before any of the child's user code. A later supervisor registers its
--    own policy for the worker here.
-- 4. The gate opens and @wait@ runs with the caller's masking state. It is an
--    STM transaction the caller composes, typically 'awaitStartup' combined
--    with another condition, and its result is returned with the handle.
--
-- If @prepare@ or @wait@ fails or is cancelled, cancellation of the worker is
-- requested and the starter waits, absorbing further interruptions, until the
-- worker is terminal and its helper has finished. The failure then propagates
-- with its own context, an 'AbandonedStart' 'WorkerEvidence' annotation, and
-- the worker's cleanup failures retained. The worker cannot outlive the
-- dependencies the starter borrowed.
--
-- A @wait@ that returns without acknowledgement leaves the worker running and
-- owned by the group.
startWorkerWith
  ∷ WorkerGroup
  → WorkerDefinition r
  → (Worker r → IO ())
  → (Worker r → STM a)
  → IO (Either StartRejection (Worker r, a))
startWorkerWith group (WorkerDefinition label startup) prepare wait = mask $ \restore → do
  declared ← evaluate label
  reserved ← atomically (register group declared)
  case reserved of
    Nothing → pure (Left RegistrationClosed)
    Just worker → do
      let entry = workerEntry worker
      forked ← trySome (forkIOWithUnmask (runChild worker startup))
      case forked of
        Left failure → do
          atomically (publish worker (failureResult failure))
          rethrowIO failure
        Right thread → atomically (writeTVar (entryThread entry) (Just thread))
      handoff ← trySome $ do
        restore (prepare worker)
        atomically (writeTVar (entryGate entry) True)
        restore (atomically (wait worker))
      case handoff of
        Right waited → pure (Right (worker, waited))
        Left failure → do
          summary ← drainWorker worker
          rethrowIO (attachEvidence (AbandonedStart summary) (completionCleanup summary) failure)

-- | Register a new worker if registration is open.
register ∷ WorkerGroup → Text → STM (Maybe (Worker r))
register group label = do
  phase ← readTVar (groupPhase group)
  if phase /= Open
    then pure Nothing
    else do
      next ← readTVar (groupNextId group)
      writeTVar (groupNextId group) (next + 1)
      entry ←
        Entry (WorkerId next) label
          <$> newTVar Nothing
          <*> newTVar NothingRequested
          <*> newTVar False
          <*> newTVar False
          <*> newTVar RunNotEntered
          <*> newTVar Nothing
          <*> newTVar False
          <*> newTVar 0
          <*> newTVar False
          <*> newTVar False
      completion ← newTVar Nothing
      modifyTVar' (groupActive group) (Map.insert (entryId entry) entry)
      pure (Just (Worker group entry completion))

-- | The child thread. It starts masked, with its outcome handler installed
-- before anything interruptible, waits at the gate, and publishes exactly one
-- terminal outcome after its scope has unwound.
runChild ∷ Worker r → (StopToken → Scoped (IO r)) → (∀ x. IO x → IO x) → IO ()
runChild worker startup unmask = do
  outcome ← trySome $ do
    atomically (readTVar (entryGate entry) >>= check)
    unmask $ withScoped (startup (StopToken (entryRequests entry))) $ \run →
      mask $ \restore → do
        atomically (writeTVar (entryAcknowledged entry) True)
        exited ← trySome (restore (run >>= evaluate))
        atomically $ do
          requested ← readTVar (entryRequests entry)
          writeTVar (entryExit entry) (RunExited (runEnd exited) requested)
        either rethrowIO pure exited
  atomically (publish worker (either failureResult Succeeded outcome))
  where
    entry = workerEntry worker
    runEnd (Right _) = RunReturned
    runEnd (Left failure) = case failureResult failure of
      Cancelled _ → RunCancelled
      _ → RunFailed

-- | Publish the terminal outcome: the typed completion for the handle and the
-- summary the group reads, in one transaction.
publish ∷ Worker r → Result r → STM ()
publish worker result = do
  exit ← readTVar (entryExit entry)
  let completion = Completion (entryId entry) (entryLabel entry) exit result (resultCleanup result)
  writeTVar (workerCompletion worker) (Just completion)
  writeTVar (entrySummary entry) (Just (void completion))
  where
    entry = workerEntry worker
