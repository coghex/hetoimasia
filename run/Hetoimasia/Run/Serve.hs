-- | Serving the native owner's loop on the process main thread while the session runs on a thread of its own, and
-- unwinding them together when the loop fails. It names nothing native: the owner is a record of the three things
-- it needs, so the shutdown rules are examined without a device or a window.
--
-- = Who owns what
--
-- The /session thread/ owns every scope the session uses (the texture adapter, the pool, the pipeline, the window
-- provider, the roles): it is started by 'spawn' and ends them itself. The /main thread/ owns only the native
-- owner application (GLFW, the device and the loop) and the root. That is what lets the main thread give the owner
-- back to its application's own protected exit while the session is still unwinding, which is the only thing that
-- can destroy a window when the loop can no longer be served.
--
-- = The rules
--
-- * The session is started, its handle recorded where the caller's join will find it, and the loop entered, in
--   /one/ masked step ('serveSpawned'): the loop's guard is installed before asynchronous exceptions are enabled
--   at all, so a cancellation already pending when the loop is entered lands inside the guard and stops the
--   session like any other failure of the loop. There is no point between the thread's creation and that guard
--   at which a cancellation can escape.
-- * The application that owns the loop is itself run in one masked step ('runOwned'): whatever ends it, the
--   capture of its failure, the stop of the session, the join and the evidence are one sequence in which a
--   cancellation is only /remembered/, never allowed to leave the sequence. A caught failure's continuation does
--   not resume unmasked.
-- * When the loop ends because the session ended, the session's own result (or failure, with its context) is the
--   answer.
-- * When the loop /fails/ (or the main thread is cancelled in it), the session is asked to stop and the owner is
--   served /again/ by a drain loop until the session has settled, because the session's cleanup closes windows
--   and waits for their native destruction, which only this thread's loop performs. The drain is independent of
--   the supervision checkpoints that already failed (the owner makes its own). A drain that itself fails is
--   logged and run again, 'drainAttempts' times in all.
-- * If the session is /still/ unsettled after that, the owner cannot be served any more. The loop's failure is then
--   raised at once, without joining: the application's protected exit performs the verified destruction of what
--   the loop could not, and the session, whose providers then see a finished owner, settles. The caller joins it
--   with 'joinFailure' after the application has torn down, which retains the session's failure beside the loop's.
-- * Every cancellation, in the drain or the join, is remembered across the whole sequence and raised after it,
--   with the loop's failure and the session's failure retained beside it, never instead of them.
module Hetoimasia.Run.Serve
  ( Owner (..)
  , Spawned
  , serveSpawned
  , runOwned
  , joinFailure
  , drainAttempts
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryReadMVar)
import Control.Exception (ExceptionWithContext, SomeException, displayException, mask, rethrowIO, tryWithContext)
import Control.Monad (unless, void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (Component, logError, unsafeComponent)
import Hetoimasia.Run.Output (reportText)
import Hetoimasia.Run.Settle (attemptSync, bestEffort, combine, reportDiagnostic, rememberingInterruption)
import Hetoimasia.Runtime.Logging (LoggingLifetime, lifetimeLogger)

-- | What the main thread serves.
data Owner = Owner
  { ownerServe ∷ IO () → IO Bool → IO ()
  -- ^ Run the owner's loop on this thread: do the first action on every turn, and finish when the second answers
  -- True. A failure of the loop, or of a turn's action, ends it and propagates.
  , ownerDrain ∷ IO Bool → IO ()
  -- ^ Run a loop that does nothing but serve the owner's retirement until the action answers True, independent of
  -- the supervision checkpoints the ordinary loop has already failed.
  , ownerWake ∷ IO ()
  -- ^ Wake the loop so it sees that the session has ended.
  }

-- | A session thread, started and not yet joined.
data Spawned a = Spawned
  { spawnedDone ∷ !(MVar (Either (ExceptionWithContext SomeException) a))
  , spawnedAttached ∷ !(IORef Bool)
  -- ^ Whether the session's own failure has already been retained beside a failure being raised.
  }

component ∷ Component
component = unsafeComponent "run.serve"

-- | How many times a failing drain is run before the owner is given up on.
drainAttempts ∷ Int
drainAttempts = 3

-- | Start the session on a thread of its own, which wakes the owner's loop when it ends. Only called with
-- asynchronous exceptions masked.
spawn ∷ Owner → IO a → IO (Spawned a)
spawn owner session = do
  done ← newEmptyMVar
  attached ← newIORef False
  _ ← forkIOWithUnmask $ \unmask → do
    result ← unmask (tryWithContext session)
    putMVar done result
    ownerWake owner
  pure (Spawned done attached)

-- | Start the session, hand its handle to the recorder, and serve the owner on this thread until the session has
-- ended, all in one masked step; see the module header for the failure rules. The recorder runs masked and before the
-- loop's guard exists, so it must neither block nor throw.
serveSpawned ∷ ∀ a. LoggingLifetime → Owner → (Spawned a → IO ()) → IO () → IO () → IO a → IO a
serveSpawned lifetime owner record stopSession turn session = mask $ \restore → do
  spawned ← spawn owner session
  record spawned
  serve restore lifetime owner stopSession turn spawned

-- | The loop and its failure rules. Called inside the mask of 'serveSpawned', with that mask's @restore@, which is
-- the only place asynchronous exceptions are enabled, and then only inside the guard.
serve ∷ ∀ a. (∀ x. IO x → IO x) → LoggingLifetime → Owner → IO () → IO () → Spawned a → IO a
serve restore lifetime owner stopSession turn spawned = do
  let over = isJust <$> tryReadMVar (spawnedDone spawned)
  tryWithContext (restore (ownerServe owner turn over)) >>= \case
    Right () → do
      interruption ← rememberingInterruption (void (readMVar (spawnedDone spawned)))
      outcome ← readMVar (spawnedDone spawned)
      case (interruption, outcome) of
        (Just interrupted, Left failure) → rethrowIO =<< combine interrupted [("the session", failure)]
        (Just interrupted, Right _) → rethrowIO interrupted
        (Nothing, _) → do
          -- The session's failure, when it has one, is the primary here: it is not retained beside itself later.
          atomicModifyIORef' (spawnedAttached spawned) (const (True, ()))
          either rethrowIO pure outcome
    Left failure → do
      stopped ← stopRemembering stopSession
      drainedSo ← rememberingInterruption (drain over)
      let drained = stopped <|> drainedSo
      settled ← over
      if settled
        then rethrowIO =<< joinFailure spawned drained failure
        else
          -- The owner cannot be served any more: the application's protected exit must do what the loop could not.
          rethrowIO =<< maybe (pure failure) (\interrupted → combine interrupted [("the owner loop failure", failure)]) drained
  where
    drain over = go 0
      where
        go attempt
          | attempt >= drainAttempts = pure ()
          | otherwise =
              over >>= \finished →
                unless finished $
                  attemptSync (ownerDrain owner over) >>= \case
                    Right () → pure ()
                    Left again → do
                      -- A failed write has been recorded on the lifetime by the sink that refused it.
                      reportDiagnostic (logError (lifetimeLogger lifetime) component "the owner loop failed while the session was draining" [("reason", reportText (Text.pack (displayException again)))])
                      go (attempt + 1 ∷ Int)

-- | Ask the session to stop, once, remembering a cancellation that arrives meanwhile (the request is made again
-- until it has been made undisturbed) and ignoring a synchronous failure of it: the stop is idempotent, and the
-- join that follows never depends on it having succeeded.
stopRemembering ∷ IO () → IO (Maybe (ExceptionWithContext SomeException))
stopRemembering stopSession = rememberingInterruption (bestEffort stopSession)

-- | Run the owner's application, which runs the session through 'serveSpawned' (recording its handle in the slot),
-- and settle the session after it, whatever the way out.
--
-- /The whole sequence is one masked step./ The application alone runs with asynchronous exceptions enabled. What
-- follows its failure (reading the slot, stopping the session, joining it, combining the evidence) is the
-- application's own continuation, and a caught failure's continuation would otherwise resume unmasked: a
-- cancellation queued while the failure was being caught would land before the stop, skip the join and let the
-- scopes the session borrows be released under it. Here every wait is made with the cancellation remembered
-- ('stopRemembering', 'joinFailure'), and the cancellation, if one arrived, is raised last as the primary failure
-- with the application's failure and the session's retained beside it.
--
-- A success is the application's result unchanged: 'serveSpawned' has already joined the session on that path.
runOwned ∷ ∀ a b. IORef (Maybe (Spawned a)) → IO () → IO b → IO b
runOwned slot stopSession application = mask $ \restore → do
  result ← tryWithContext (restore application)
  case result of
    Right value → pure value
    Left failure →
      readIORef slot >>= \case
        Nothing → rethrowIO failure
        Just session → do
          stopped ← stopRemembering stopSession
          rethrowIO =<< joinFailure session stopped failure

-- | Join the session, waiting without a bound and remembering a cancellation meanwhile, and answer the failure that
-- is being raised with the session's own failure retained beside it (and with an interruption, if one was
-- remembered, as the primary). The session's failure is retained once, however many times this is asked.
joinFailure ∷ Spawned a → Maybe (ExceptionWithContext SomeException) → ExceptionWithContext SomeException → IO (ExceptionWithContext SomeException)
joinFailure spawned earlier primary = do
  already ← atomicModifyIORef' (spawnedAttached spawned) (\done → (True, done))
  if already
    then pure (maybe primary id earlier)
    else do
      later ← rememberingInterruption (void (readMVar (spawnedDone spawned)))
      outcome ← readMVar (spawnedDone spawned)
      let secondary = [("the session, which had to unwind after the owner loop failed", failure) | Left failure ← [outcome]]
      case earlier <|> later of
        Just interrupted → combine interrupted ([("the owner loop failure", primary)] <> secondary)
        Nothing → combine primary secondary
