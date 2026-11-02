-- | The hosted subprocess (#608): a place where scoped children are run so that each one's process group is /not/ ended when the
-- call that ran it returns, and every one is ended and reaped, in reverse order of its start, when the host's own scope ends.
--
-- The display-helper suites need it. A helper's stub servers and clients sit in the helper's process group, and an example asserts,
-- after the helper has returned, that it stopped what it owned and left alone what it did not start (a "holder" it was never told
-- about). A one-shot owned call ends the group when it returns, so the example could not look. On a host the example looks first and
-- the host's end ends whatever the example left. Every child meets the rules of "Test.Support.Subprocess" unchanged (a group of its
-- own, SIGTERM then the grace then SIGKILL, a confirmed reap, the reap and drain bounds, explicit run bounds with no default, a
-- body's own failure raised as itself); the host adds exactly one thing, which is that it keeps ownership of a child after the call
-- that ran it has answered.
--
-- = The state machine
--
-- A host is in one of six states, as a submitter or the owner sees it ('HostState'):
--
-- * 'Starting': opened, the worker not yet serving. Requests are admitted as in every accepting state.
-- * 'Idle': serving, nothing held.
-- * 'ServingEmpty': a request is being served (its child starting, or its body running) and the slot is empty.
-- * 'ServingQueued': the same, with one request waiting in the slot.
-- * 'Stopping': the stop is recorded, the worker not yet finished.
-- * 'Ended': the worker has finished, for any cause.
--
-- and five things happen to it: a submission; the passing of a request's run bound, or the cancellation of its submitter, before it
-- is answered; the stop (the owner's scope returns normally); the owner's own failure or cancellation; and the worker ending by
-- itself. The outcome of every cell is in the table of @tools/test-support/README.md@, and each cell has an example in
-- @tools/test/OwnedHost.hs@, named after it.
--
-- = Ownership
--
-- State owner: 'withHostUsing', which creates the host, its one worker thread and every shared cell, and ends them. Readers and
-- writers: the worker (the slot, the lifecycle and answer of the request it serves, the phase), the submitters (the slot, to place a
-- request and to withdraw one; the answer; the phase) and the owner (the phase, to record the stop). Thread: one owned worker
-- ("Test.Support.Owned"), which serves the requests /nested/: the child of each request is run by 'withScopedChildUsing', whose
-- body answers the request and then goes on serving, so the scopes unwind latest first. Lifetime: the owner's scope. Disposal: the
-- stop is recorded in the owned scope's opening, which runs first in the uninterruptible release and before the worker is
-- cancelled, so the worker is cancelled wherever it is waiting, a running body included, and never waited for; every child is then
-- ended and reaped by its own scope as the worker unwinds, and the join returns after all of them.
--
-- /Handles./ A request may supply handles for the child's streams ('CallerHandle'). At every point exactly one party owns them:
--
-- * the submitter, until the worker has claimed the request. The claim and the withdrawal are each one atomic step on the request's
--   lifecycle, so a request is claimed or withdrawn, never both. A request that is refused, whose bound passes, whose submitter is
--   cancelled, or that is still queued when the host stops or ends is withdrawn, and its submitter closes the handles before its
--   call returns or raises;
-- * the worker, from the claim until the request's body is entered. A claimed request whose child cannot be started, whose worker
--   is cancelled before the body, or whose submitter gave up before the entry was decided, has its handles closed by the worker.
--   The entry is one atomic step that reads whether the submitter gave up: the body is entered or the handles are closed, never
--   both;
-- * the caller, once the body is entered.
--
-- (The facility also closes a handle when its own scope ends before its body is entered; closing a closed handle is a no-op, so
-- the handle is closed once and stays closed.)
--
-- /Cancellation./ Hosted bodies are expected to be cancellable (@docs/workers.md@, "Test.Support.Owned"): a body does not catch a
-- cancellation without rethrowing it, and does not block in an uninterruptible region without an opening registered for the scope
-- ('hostOpen'). The guarantees that no submission waits past the host's stop and that shutdown never waits for a body hold for such
-- bodies. A body outside that precondition is not interrupted by anything here: the stop is recorded and every waiting submitter is
-- answered, but the scope's join waits for the body, its child is not ended until the body lets go, and nothing is reported ended or
-- reaped that is not. The owner's own failure is still raised as itself once it has.
module Test.Support.Subprocess.Host
  ( -- * The host
    Host
  , HostState (..)
  , withHost
  , withHostUsing
  , hostState
  , hostQueued
  , awaitQueued
  , awaitHostState
  , recordStop
    -- * Failures
  , HostFailure (..)
    -- * Running a child on the host
  , hosted
  , hostedCaptured
    -- * Seams
  , HostSeams (..)
  , Site (..)
  , Deadline (..)
  , noHostSeams
  ) where

import Control.Concurrent.STM
  ( STM
  , TMVar
  , TVar
  , atomically
  , check
  , modifyTVar'
  , newEmptyTMVarIO
  , newTVarIO
  , orElse
  , putTMVar
  , readTMVar
  , readTVar
  , readTVarIO
  , retry
  , takeTMVar
  , tryPutTMVar
  , tryReadTMVar
  , writeTVar
  )
import Control.Exception
  ( Exception (displayException, fromException)
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , SomeAsyncException
  , SomeException
  , catch
  , mask
  , mask_
  , rethrowIO
  , throwIO
  , try
  , tryWithContext
  )
import Control.Applicative ((<|>))
import Control.Exception.Context (addExceptionAnnotation, getExceptionAnnotations)
import Control.Monad (forM_, unless, void, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.Exit (ExitCode)
import System.IO (Handle, hClose, hPutStr)
import System.Process (CreateProcess, waitForProcess)
import System.Timeout (timeout)
import Test.Support.Owned (withOwnedThread, withOwnedThreadOpening)
import Test.Support.Subprocess
  ( Bounds (boundDrain, boundReap)
  , Child
  , ChildSpec (specBound, specProcess, specStderr, specStdin, specStdout)
  , Drain (DrainGivenUp, Drained)
  , Output (Stderr, Stdout)
  , RetainedFailure (RetainedFailure)
  , RunBound (Unbounded, Within)
  , Seams
  , Stream (CallerHandle, Piped)
  , SubprocessFailure (SubprocessFailure)
  , awaitDrain
  , captured
  , childProcess
  , childSpec
  , childStdin
  , defaultBounds
  , describeBound
  , describeCommand
  , noSeams
  , withScopedChildUsing
  )

-- --------------------------------------------------------------------------
-- States, failures and seams

-- | Where a host is, as a submitter or the owner sees it. See the module header.
data HostState = Starting | Idle | ServingEmpty | ServingQueued | Stopping | Ended
  deriving (Eq, Show)

-- | What is recorded: the part of the state that is one cell. 'Idle', 'ServingEmpty' and 'ServingQueued' are all 'PhaseServing';
-- they differ by what the worker holds and what the slot holds.
data Phase = PhaseStarting | PhaseServing | PhaseStopping | PhaseEnded
  deriving (Eq, Show)

-- | Why a submission did not get an answer from a child: the host was stopping, or had ended.
data HostFailure
  = -- | The stop was recorded (the owner's scope ended or failed) before the request was answered.
    HostStopped String
  | -- | The worker had ended, for any cause, before the request was answered.
    HostEnded String
  deriving (Eq)

instance Show HostFailure where
  show (HostStopped command) = "the host of " <> command <> " stopped before it answered; the request was not served to its end"
  show (HostEnded command) = "the host of " <> command <> " ended before it answered; the request was not served to its end"

instance Exception HostFailure

-- | Where a run bound is measured (a seam: an example makes either expire without waiting for a clock).
data Site
  = -- | Around everything from the call being made: the wait for the slot, the wait for the worker, the wait for the answer.
    AtSubmission
  | -- | Around the body, on the worker.
    AtBody
  deriving (Eq, Show)

-- | The moment a request's run bound passes, on the monotonic clock, or never.
data Deadline = NoDeadline | DeadlineAt !Word64
  deriving (Eq, Show)

-- | The test-side hooks of the host's own examples. Production use is 'noHostSeams'. The facility's own hooks ('Seams') reach the
-- child of every request through 'withHostUsing'.
data HostSeams = HostSeams
  { hostBeforeServing ∷ IO ()
  -- ^ Run by the worker before it serves, in 'Starting': where an example holds the host in that state.
  , hostTaking ∷ IO ()
  -- ^ Run by the worker once it has claimed a request and before the child is acquired, masked: where an example holds the race of
  -- an abandonment with the worker taking the request.
  , hostEntering ∷ IO ()
  -- ^ Run by the worker inside the child's scope, before the entry of the body is decided: where an example holds the race of an
  -- abandonment with the entry of the body.
  , hostAbandoning ∷ String → IO ()
  -- ^ Run by a submitter that was not answered, given its command, in its cleanup and before it withdraws its request, where a
  -- cancellation that lands is remembered and the hold run again: where an example holds a request in the slot while the host is
  -- stopping or has ended.
  , hostClosing ∷ IO ()
  -- ^ Run before the host closes the handles a request supplied (by the submitter that withdrew it, or by the worker that claimed
  -- it), where a cancellation that lands is remembered and the close run again: where an example delivers a cancellation into that
  -- cleanup.
  , hostLimit ∷ ∀ a. Site → Deadline → IO a → IO (Maybe a)
  -- ^ Run the action under the request's run bound: 'Nothing' when the bound passed first. An example that wants an expiry without
  -- a clock gives one that expires when the example says so.
  , hostOpen ∷ IO ()
  -- ^ Run in the owned scope's opening, which runs first in the uninterruptible release: whatever an example's seam or body is
  -- parked at is let go here. It must not block and must be safe to run twice.
  }

noHostSeams ∷ HostSeams
noHostSeams =
  HostSeams
    { hostBeforeServing = pure ()
    , hostTaking = pure ()
    , hostEntering = pure ()
    , hostAbandoning = \_ → pure ()
    , hostClosing = pure ()
    , hostLimit = realLimit
    , hostOpen = pure ()
    }

realLimit ∷ Site → Deadline → IO a → IO (Maybe a)
realLimit _ NoDeadline action = Just <$> action
realLimit _ (DeadlineAt moment) action = do
  now ← getMonotonicTimeNSec
  let microseconds = if moment > now then (moment - now) `div` 1000 else 0
  timeout (fromIntegral (min microseconds (fromIntegral (maxBound ∷ Int)))) action

deadlineFor ∷ RunBound → IO Deadline
deadlineFor Unbounded = pure NoDeadline
deadlineFor (Within microseconds) = do
  now ← getMonotonicTimeNSec
  pure (DeadlineAt (now + fromIntegral (max 0 microseconds) * 1000))

-- --------------------------------------------------------------------------
-- The shared cells

-- | Where a request is. Each move is one atomic step, which is what makes the owner of its handles unambiguous.
data Lifecycle
  = -- | Made by the submitter and not yet in the slot.
    Unplaced
  | -- | In the slot, waiting for the worker.
    Placed
  | -- | Taken by the worker; its child is being started or its body is about to be entered.
    Claimed
  | -- | The body has been entered; the handles are the caller's.
    Entered
  | -- | Given up before it was claimed, or before the entry was decided: never started or never entered, its handles closed.
    Withdrawn
  deriving (Eq, Show)

-- | One request, as the worker sees it. The type of the answer is inside the two closures.
data Pending = Pending
  { pendSpec ∷ !ChildSpec
  , pendCommand ∷ !String
  , pendHandles ∷ ![Handle]
  , pendLife ∷ !(TVar Lifecycle)
  , pendAbandoned ∷ !(TVar Bool)
  -- ^ Set by a submitter that gave up while the request was claimed, and read by the entry of the body.
  , pendExecute ∷ Child → IO (Maybe (ExceptionWithContext SomeException))
  -- ^ Run the body under the request's bound and answer; the cancellation the body received, if it did (service must then end).
  , pendFail ∷ ExceptionWithContext SomeException → STM ()
  -- ^ Answer the submitter with a failure (once).
  }

data Host = Host
  { hostPhase ∷ !(TVar Phase)
  , hostSlot ∷ !(TMVar Pending)
  , hostRunning ∷ !(TVar Bool)
  -- ^ A request is claimed and not yet answered.
  , hostStopSeen ∷ !(TVar Bool)
  -- ^ The stop was recorded, once and for good: a submitter told that the host is gone says which it was, whichever of the stop and
  -- the end it happens to observe first.
  , hostBounds ∷ !Bounds
  , hostFacility ∷ !Seams
  , hostHooks ∷ !HostSeams
  }

-- | The host's state, as one consistent look. The part that a request holds is visible only to the worker; a request that is just
-- in the slot of a serving, idle host is about to be claimed and counts as 'Idle'.
hostStateSTM ∷ Host → STM HostState
hostStateSTM host =
  readTVar (hostPhase host) >>= \case
    PhaseStarting → pure Starting
    PhaseStopping → pure Stopping
    PhaseEnded → pure Ended
    PhaseServing → do
      busy ← readTVar (hostRunning host)
      if not busy
        then pure Idle
        else do
          queued ← tryReadTMVar (hostSlot host)
          pure (if isJust queued then ServingQueued else ServingEmpty)

hostState ∷ Host → IO HostState
hostState = atomically . hostStateSTM

-- | Wait, without a clock, until a request is, or is not, waiting in the slot.
awaitQueued ∷ Host → Bool → IO ()
awaitQueued host wanted = atomically (tryReadTMVar (hostSlot host) >>= check . (== wanted) . isJust)

-- | Whether a request is waiting in the slot, in any state.
hostQueued ∷ Host → IO Bool
hostQueued host = isJust <$> atomically (tryReadTMVar (hostSlot host))

-- | Record the stop: one non-blocking, idempotent step, independent of what the slot holds. Every submitter waiting is answered and
-- no later one is accepted; it does not itself cancel the worker (the owner's scope does, next). Recording it again, or after the
-- host has ended, changes nothing.
recordStop ∷ Host → IO ()
recordStop host =
  atomically $ do
    modifyTVar' (hostPhase host) (\recorded → if recorded == PhaseEnded then PhaseEnded else PhaseStopping)
    writeTVar (hostStopSeen host) True

-- | Wait, without a clock, until the host is in a state that satisfies the condition.
awaitHostState ∷ Host → (HostState → Bool) → IO ()
awaitHostState host condition = atomically (hostStateSTM host >>= check . condition)

-- --------------------------------------------------------------------------
-- The owner's scope

-- | The worker's own result: how it ended.
type WorkerResult = Either (ExceptionWithContext SomeException) ()

-- | 'withHostUsing' with the facility's fixed bounds and no seams.
withHost ∷ (Host → IO a) → IO a
withHost = withHostUsing defaultBounds noSeams noHostSeams

-- | Run the use with a host. However the use ends, the stop is recorded (so every waiting submitter is answered and no later one is
-- accepted), the worker is cancelled and joined, and every child has been ended and reaped, latest first, before this returns or
-- raises. The use's own failure or cancellation is raised as itself, with the worker's failure and any cleanup that was not
-- confirmed retained beside it; otherwise the worker's failure is raised, once. A cancellation of the worker is never raised in the
-- owner.
withHostUsing ∷ Bounds → Seams → HostSeams → (Host → IO a) → IO a
withHostUsing bounds facility hooks use = do
  phase ← newTVarIO PhaseStarting
  slot ← newEmptyTMVarIO
  running ← newTVarIO False
  stopSeen ← newTVarIO False
  outcome ← newEmptyTMVarIO
  observed ← newIORef Nothing
  let host = Host phase slot running stopSeen bounds facility hooks
      stop = recordStop host >> hostOpen hooks
  scoped ←
    tryWithContext @SomeException . withOwnedThreadOpening stop (workerMain host outcome) $ \_ _ →
      tryWithContext @SomeException (use host) >>= writeIORef observed . Just
  -- Past the join, nothing can be interrupted: the host is Ended (a worker cancelled before it ran anything never said so), the
  -- result is decided and raised.
  conclusion ← mask_ $ do
    atomically (writeTVar phase PhaseEnded >> void (tryPutTMVar outcome (Right ())))
    worker ← atomically (readTMVar outcome) >>= workerFailure
    owner ← readIORef observed
    pure (conclude scoped owner worker)
  conclusion

-- | What the owner's scope raises or returns, from how the owned scope ended, how the use ended and how the worker did.
conclude
  ∷ Either (ExceptionWithContext SomeException) ()
  → Maybe (Either (ExceptionWithContext SomeException) a)
  → Maybe (ExceptionWithContext SomeException)
  → IO a
conclude scoped owner worker = case (scoped, owner) of
  -- A cancellation reached the scope after the use had ended (the release is uninterruptible, so it arrives as the mask ends): it is
  -- raised, with the use's own failure and the worker's retained.
  (Left interruption, _) → rethrowIO (withWorker (withOwner interruption))
  (Right (), Just (Left failure)) → rethrowIO (withWorker failure)
  (Right (), Just (Right result)) → maybe (pure result) rethrowIO worker
  (Right (), Nothing) → maybe (throwIO (SubprocessFailure "the host's scope ended without running its body")) rethrowIO worker
  where
    withOwner interruption = case owner of
      Just (Left failure) → retain "the failure of what was being run" failure interruption
      _ → interruption
    withWorker failure = case worker of
      Just failed → retain "the host's worker failed" failed failure
      Nothing → failure

-- | How the worker's end matters to the owner: a failure that is not a cancellation is raised as itself; a cancellation (the
-- owner's own stop, or anyone's) is not, except for the cleanup that was not confirmed on its way, which becomes a failure.
workerFailure ∷ WorkerResult → IO (Maybe (ExceptionWithContext SomeException))
workerFailure (Right ()) = pure Nothing
workerFailure (Left failure@(ExceptionWithContext context _))
  | isAsync failure = case [text | RetainedFailure _ text ← getExceptionAnnotations context] of
      [] → pure Nothing
      problems → Just <$> captureFailure (SubprocessFailure ("a cleanup was not confirmed: " <> intercalate "; " problems))
  | otherwise = pure (Just failure)

-- | The worker: serve until the stop is recorded or the worker is cancelled. However it ends, the host is Ended in the same step that
-- announces it, so no submitter is left waiting and no later one is queued.
workerMain ∷ Host → TMVar WorkerResult → IO ()
workerMain host outcome = mask $ \restore → do
  result ← tryWithContext @SomeException . restore $ do
    hostBeforeServing (hostHooks host)
    atomically (modifyTVar' (hostPhase host) (\recorded → if recorded == PhaseStarting then PhaseServing else recorded))
    serve host
  atomically (writeTVar (hostPhase host) PhaseEnded >> void (tryPutTMVar outcome result))

-- --------------------------------------------------------------------------
-- The worker's service

data Step = Finished | Again

-- | Serve requests, nested: a request's body answers it and then runs this again inside the child's scope. The stop is looked at
-- before the slot, and it is a cell of its own, so a full slot never hides it.
serve ∷ Host → IO ()
serve host =
  step >>= \case
    Finished → pure ()
    Again → serve host
  where
    step = mask $ \restore → do
      next ← atomically $ (Nothing <$ (readTVar (hostPhase host) >>= check . stopRecorded)) `orElse` (Just <$> claim)
      case next of
        Nothing → pure Finished
        Just pending → do
          -- Claimed under the mask: from here to the scope's own acquisition nothing can be delivered, and a request that never
          -- enters its body is released below, by the lifecycle it was left in.
          attempt ← tryWithContext @SomeException $ do
            hostTaking (hostHooks host)
            restore (withScopedChildUsing (hostBounds host) (hostFacility host) (pendSpec pending) (runBody host pending))
          case attempt of
            Right () → pure Finished
            Left failure → do
              life ← readTVarIO (pendLife pending)
              if life /= Claimed
                then rethrowIO failure
                else do
                  -- The child could not be started, or the worker was cancelled before the body: its own submitter is told, its
                  -- handles are closed, and the host, which has lost nothing, goes on unless the failure was a cancellation.
                  interruption ← releaseClaimed host pending failure
                  case interruption of
                    Just interrupted → rethrowIO interrupted
                    Nothing
                      | isAsync failure → rethrowIO failure
                      | otherwise → pure Again
    claim = do
      pending ← takeTMVar (hostSlot host)
      writeTVar (pendLife pending) Claimed
      writeTVar (hostRunning host) True
      pure pending

stopRecorded ∷ Phase → Bool
stopRecorded phase = phase == PhaseStopping || phase == PhaseEnded

-- | The body of a request's scope: decide the entry, run the body, answer, and go on serving inside the scope.
runBody ∷ Host → Pending → Child → IO ()
runBody host pending child = do
  hostEntering (hostHooks host)
  entered ← atomically $ do
    gaveUp ← readTVar (pendAbandoned pending)
    writeTVar (pendLife pending) (if gaveUp then Withdrawn else Entered)
    pure (not gaveUp)
  if entered
    then
      pendExecute pending child >>= \case
        Just cancellation → rethrowIO cancellation
        Nothing → serve host
    else do
      -- The submitter gave up before the entry: the body is not entered, the handles are closed, and the child, which exists, stays
      -- hosted with the others.
      failure ← captureFailure (SubprocessFailure (pendCommand pending <> " was abandoned before its body was entered"))
      interruption ← releaseClaimed host pending failure
      maybe (serve host) rethrowIO interruption

-- | A claimed request that will not enter its body: close the handles, remembering a cancellation that lands, and answer its
-- submitter, with the failure itself or, when that was a cancellation, with the fact that the host stopped or ended. Answers the
-- cancellation that interrupted the close, if one did, ready to be raised: it keeps the failure that was being handled and every
-- diagnostic of the close beside it.
releaseClaimed ∷ Host → Pending → ExceptionWithContext SomeException → IO (Maybe (ExceptionWithContext SomeException))
releaseClaimed host pending failure = do
  (problems, interruption) ← closeRemembering (hostBounds host) (hostClosing (hostHooks host)) (pendHandles pending)
  told ←
    if isAsync failure
      then stoppedOrEnded host (pendCommand pending) >>= captureFailure
      else pure failure
  atomically (pendFail pending (retainProblems problems told) >> writeTVar (hostRunning host) False)
  pure (retainProblems problems . retain "the failure of what was being run" failure <$> interruption)

-- | Why a request that will not be answered by a child is told so: the stop was recorded, or the worker ended without it.
stoppedOrEnded ∷ Host → String → IO HostFailure
stoppedOrEnded host command = fromMaybe (HostEnded command) <$> atomically (readTVar (hostPhase host) >>= refusalFor host command)

-- | The failure for a host that is stopping or has ended; 'Nothing' while it is serving.
refusalFor ∷ Host → String → Phase → STM (Maybe HostFailure)
refusalFor host command = \case
  PhaseStopping → pure (Just (HostStopped command))
  PhaseEnded → do
    stopped ← readTVar (hostStopSeen host)
    pure (Just (if stopped then HostStopped command else HostEnded command))
  _ → pure Nothing

-- --------------------------------------------------------------------------
-- Running a child on the host

-- | Run a scoped child on the host and answer what the body answered. The child's group is not ended when this returns, whatever
-- state the child and its descendants are in: the host keeps ownership of it and ends and reaps it, with the others and latest
-- first, when the host's scope ends. The spec's run bound is the request's: it covers everything from the call being made, the wait
-- for the slot, the wait for the worker and the body, and not how long the host keeps the child.
--
-- A submission made after the stop or the end is refused at once, and a submitter already waiting when either is recorded is
-- answered 'HostStopped' or 'HostEnded' at once, not at its bound; neither is ever started and its handles are closed. The call
-- raises the body's own failure as itself, the failure of starting the child as itself, a failure naming the command and the bound
-- when the bound passes, and the submitter's own cancellation unchanged.
hosted ∷ ∀ a. Host → ChildSpec → (Child → IO a) → IO a
hosted host spec body = mask $ \restore → do
  deadline ← deadlineFor (specBound spec)
  reply ← newEmptyTMVarIO
  life ← newTVarIO Unplaced
  abandoned ← newTVarIO False
  let command = describeCommand (specProcess spec)
      hooks = hostHooks host
      answer ∷ Either (ExceptionWithContext SomeException) a → STM ()
      answer result = void (tryPutTMVar reply result) >> writeTVar (hostRunning host) False
      expiry = SubprocessFailure (command <> " did not finish within its run bound of " <> describeBound (specBound spec))
      execute child = do
        result ← tryWithContext @SomeException (hostLimit hooks AtBody deadline (body child))
        case result of
          Right (Just value) → atomically (answer (Right value)) >> pure Nothing
          Right Nothing → do
            failure ← captureFailure expiry
            atomically (answer (Left failure))
            pure Nothing
          Left failure
            | isAsync failure → do
                -- A cancellation of the body is the host's stop, or the worker's own: the submitter is told which, and service ends.
                told ← stoppedOrEnded host command >>= captureFailure
                atomically (answer (Left told))
                pure (Just failure)
            | otherwise → atomically (answer (Left failure)) >> pure Nothing
      pending =
        Pending
          { pendSpec = spec {specBound = Unbounded}
          , pendCommand = command
          , pendHandles = suppliedHandles spec
          , pendLife = life
          , pendAbandoned = abandoned
          , pendExecute = execute
          , pendFail = answer . Left
          }
      -- Everything from the call being made until it is answered.
      admitAndAwait = do
        admitted ← atomically $ do
          phase ← readTVar (hostPhase host)
          refusalFor host command phase >>= \case
            Just refusal → pure (Just refusal)
            Nothing → do
              putTMVar (hostSlot host) pending
              writeTVar life Placed
              pure Nothing
        case admitted of
          Just refusal → pure (Left refusal)
          Nothing →
            atomically $
              (Right <$> readTMVar reply) `orElse` (Left <$> (readTVar (hostPhase host) >>= refusalFor host command >>= maybe retry pure))
      -- The submitter's last step when it was not answered: an answer that arrived is kept; otherwise the request is withdrawn if it
      -- is still the submitter's (it then closes the handles), or marked abandoned if the worker has it.
      abandon = do
        answered ← tryReadTMVar reply
        state ← readTVar life
        case (answered, state) of
          (Just result, _) → pure (Just result, False)
          (Nothing, Unplaced) → writeTVar life Withdrawn >> pure (Nothing, True)
          (Nothing, Placed) → do
            queued ← tryReadTMVar (hostSlot host)
            when (fmap pendLife queued == Just life) (void (takeTMVar (hostSlot host)))
            writeTVar life Withdrawn
            pure (Nothing, True)
          (Nothing, Claimed) → writeTVar abandoned True >> pure (Nothing, False)
          (Nothing, _) → pure (Nothing, False)
      -- The submitter's cleanup when it was not answered: the test-side hold, then the withdrawal (one atomic step), then the close
      -- of the handles it owns, where a cancellation that lands is remembered and raised after, with the failure retained.
      giveUp = do
        held ← rememberingInterruption (hostAbandoning hooks command)
        (answered, mustClose) ← atomically abandon
        pure (answered, mustClose, held)
      raiseAfterClosing held mustClose primary = do
        (problems, interrupted) ← if mustClose then closeRemembering (hostBounds host) (hostClosing hooks) (pendHandles pending) else pure ([], Nothing)
        let interruption = held <|> interrupted
        rethrowIO (retainProblems problems (maybe primary (retain "the failure of what was being run" primary) interruption))
  verdict ← tryWithContext @SomeException (restore (hostLimit hooks AtSubmission deadline admitAndAwait))
  case verdict of
    Right (Just (Right (Right value))) → pure value
    -- The body's own failure, or the failure of starting the child, as itself.
    Right (Just (Right (Left failure))) → rethrowIO failure
    Right (Just (Left refusal)) → do
      (_, mustClose, held) ← giveUp
      captureFailure refusal >>= raiseAfterClosing held mustClose
    Right Nothing → do
      (answered, mustClose, held) ← giveUp
      case answered of
        Just (Right value) → pure value
        Just (Left failure) → rethrowIO failure
        Nothing → captureFailure expiry >>= raiseAfterClosing held mustClose
    -- The submitter's own cancellation, unchanged.
    Left cancelled → do
      (_, mustClose, held) ← giveUp
      raiseAfterClosing held mustClose cancelled

-- | 'Test.Support.Subprocess.runCaptured' on a host: the answer the one-shot call gives, and the child's group stays unended until the
-- host ends.
hostedCaptured ∷ Host → RunBound → CreateProcess → String → IO (ExitCode, String, String)
hostedCaptured host bound process input = do
  (status, out, err, drain) ← hosted host (childSpec bound process) {specStdin = Piped} (complete input)
  case drain of
    Drained → pure (status, out, err)
    DrainGivenUp →
      throwIO
        ( SubprocessFailure
            ( describeCommand process
                <> " exited, but a descendant kept its output open past the drain bound of "
                <> describeBound (Within (boundDrain (hostBounds host)))
                <> "; read so far: "
                <> show out
                <> " and on stderr "
                <> show err
            )
        )

-- | What a run to completion does with a child whose standard input is piped: give it the input and the end of it, wait for it to
-- exit, give up on pipes a descendant keeps open past the drain bound, and answer.
complete ∷ String → Child → IO (ExitCode, String, String, Drain)
complete input child = feeding $ do
  status ← waitForProcess (childProcess child)
  drain ← awaitDrain child
  out ← captured child Stdout
  err ← captured child Stderr
  pure (status, out, err, drain)
  where
    feeding run = case childStdin child of
      Nothing → run
      Just stdinHandle
        | null input → closeQuietly stdinHandle >> run
        | otherwise →
            withOwnedThread
              ((hPutStr stdinHandle input >> closeQuietly stdinHandle) `catch` \(_ ∷ IOException) → closeQuietly stdinHandle)
              (\_ _ → run)

-- --------------------------------------------------------------------------
-- Handles and failures

suppliedHandles ∷ ChildSpec → [Handle]
suppliedHandles spec = [handle | CallerHandle handle ← [specStdin spec, specStdout spec, specStderr spec]]

closeQuietly ∷ Handle → IO ()
closeQuietly handle = void (try (hClose handle) ∷ IO (Either IOException ()))

-- | Close the handles a request supplied, each within the reap bound, where a cancellation can reach the close: a cancellation that
-- lands is remembered, the close run again (closing a closed handle is a no-op, and an interrupted close still closes the
-- descriptor), and answered beside what could not be flushed.
closeRemembering ∷ Bounds → IO () → [Handle] → IO ([String], Maybe (ExceptionWithContext SomeException))
closeRemembering bounds before handles = do
  problems ← newIORef []
  interruption ← rememberingInterruption (before >> forM_ handles (closeBounded bounds problems))
  (,interruption) . reverse <$> readIORef problems

closeBounded ∷ Bounds → IORef [String] → Handle → IO ()
closeBounded bounds problems handle = do
  closed ← timeout (max 0 (boundReap bounds)) (try (hClose handle) ∷ IO (Either IOException ()))
  when (isNothing closed) $ do
    let text =
          "a handle a hosted request supplied could not be flushed and closed within "
            <> describeBound (Within (boundReap bounds))
            <> ": its peer is not reading it, so what it still buffered was discarded"
    known ← readIORef problems
    unless (text `elem` known) (modifyIORef' problems (text :))

-- | Run a cleanup, remembering the first cancellation that lands in it and running it again until it completes (the steps are
-- idempotent). Any other failure is raised.
rememberingInterruption ∷ IO () → IO (Maybe (ExceptionWithContext SomeException))
rememberingInterruption action = go Nothing
  where
    go pending =
      tryWithContext @SomeException action >>= \case
        Right () → pure pending
        Left interruption
          | isAsync interruption → go (Just (fromMaybe interruption pending))
          | otherwise → rethrowIO interruption

isAsync ∷ ExceptionWithContext SomeException → Bool
isAsync (ExceptionWithContext _ failure) = isJust (fromException failure ∷ Maybe SomeAsyncException)

annotate ∷ RetainedFailure → ExceptionWithContext SomeException → ExceptionWithContext SomeException
annotate retained (ExceptionWithContext context failure) = ExceptionWithContext (addExceptionAnnotation retained context) failure

-- | The failure that was unwinding, kept beside the exception that replaces it: its own text under the label, and every failure it
-- was already retaining.
retain ∷ String → ExceptionWithContext SomeException → ExceptionWithContext SomeException → ExceptionWithContext SomeException
retain label (ExceptionWithContext context inner) replacement =
  foldl (flip annotate) (annotate (RetainedFailure label (displayException inner)) replacement) (getExceptionAnnotations context)

retainProblems ∷ [String] → ExceptionWithContext SomeException → ExceptionWithContext SomeException
retainProblems problems failure = foldl (\acc text → annotate (RetainedFailure "the cleanup was not confirmed" text) acc) failure problems

-- | An exception as the value 'rethrowIO' raises, with the context it is raised with.
captureFailure ∷ Exception e ⇒ e → IO (ExceptionWithContext SomeException)
captureFailure failure =
  tryWithContext @SomeException (throwIO failure) >>= \case
    Left captured' → pure captured'
    Right () → throwIO (SubprocessFailure "a throw did not throw")
