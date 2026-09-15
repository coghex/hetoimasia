-- | The shared native fixture: an owner on the thread that runs it, and a
-- test-only dispatcher lending the owner's resource to a borrower elsewhere.
--
-- GLFW's session belongs to the process main thread, and Hspec runs examples on
-- threads of its own, so neither can call the other directly. 'runOwned' makes
-- its calling thread the owner: it forks the borrower — the Hspec run — and
-- then serves, one at a time and on its own thread, the operations the
-- borrower 'dispatch'es. The resource is acquired lazily, by the first
-- operation that needs it, and at most once. A run that dispatches nothing — a
-- dry run, a listing, a selection outside the native examples — acquires
-- nothing.
--
-- = Settlement
--
-- Neither side can strand the other:
--
-- * A borrower waiting for a reply also watches the owner. An owner that stops
--   serving wakes every waiter, with the owner's own failure when it failed.
-- * A borrower cancelled while its request is queued abandons it, and the owner
--   settles it without running it. A borrower cancelled while its request runs
--   leaves the owner to finish that operation, whose reply is then dropped.
-- * An acquisition failure is the answer to every request, and is never
--   retried.
-- * A failure crossing between the two sides is rethrown with the context it
--   was raised with, so failure evidence and retained cleanup failures survive.
-- * The owner releases the resource only once the borrower has finished — after
--   normal completion, cancellation, and the owner's own failure alike — and
--   settles whatever is still queued unexecuted first. Release goes through
--   "Hetoimasia.Foundation.Resource", so a release failure beside a primary one
--   is retained as cleanup evidence rather than replacing it.
--
-- = State
--
-- The request queue, the acquisition count, and the ended signal are written by
-- 'dispatch' on any thread and by the owner loop on the owner thread, through
-- STM; the served and declined counts are the owner's alone. All of them live
-- exactly as long as one 'runOwned' call. This is a test adapter: it owns no
-- process-wide state and supervises nothing but the one borrower it forked.
module Test.GLFW.Native.Fixture
  ( -- * Owners
    Owner (..)
  , OwnerReport (..)
  , runOwned

    -- * Borrowing
  , Fixture
  , dispatch
  , Unserved (..)

    -- * Observation
  , ownerThread
  , acquisitionCount
  , queuedCount
  , awaitQueued
  ) where

import Control.Concurrent (ThreadId, forkFinally, myThreadId)
import Control.Concurrent.STM
  ( STM
  , TMVar
  , TQueue
  , TVar
  , atomically
  , check
  , flushTQueue
  , modifyTVar'
  , newEmptyTMVarIO
  , newTQueueIO
  , newTVarIO
  , orElse
  , readTMVar
  , readTQueue
  , readTVar
  , readTVarIO
  , takeTMVar
  , tryPutTMVar
  , writeTQueue
  , writeTVar
  )
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException (SomeAsyncException)
  , SomeException
  , catch
  , fromException
  , mask
  , onException
  , rethrowIO
  , someExceptionContext
  , toException
  , try
  , tryJust
  )
import Control.Monad (unless, void)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Hetoimasia.Foundation.Resource (Scoped, withScoped)

-- | What an owner holds and how it ends its borrowers' use of it.
data Owner r = Owner
  { ownerAcquire ∷ Scoped r
    -- ^ The resource, acquired on the owner thread by the first operation that
    -- needs it and released when 'runOwned' ends.
  , ownerSettled ∷ IO ()
    -- ^ Runs on the owner thread once the borrower has finished and the queue is
    -- settled, and before the resource is released.
  }

-- | What one 'runOwned' call did.
data OwnerReport = OwnerReport
  { reportAcquisitions ∷ Int
    -- ^ Acquisitions attempted: 0 when nothing was dispatched, never above 1.
  , reportServed ∷ Int
  , reportDeclined ∷ Int
  , reportFailure ∷ Maybe SomeException
    -- ^ The owner's failure: an acquisition failure, a failure while serving,
    -- or a release failure. Borrowers were answered with the same exception.
  }

-- | The borrower's handle on an owner.
data Fixture r = Fixture
  { fixtureRequests ∷ TQueue (Request r)
  , fixtureQueued ∷ TVar Int
  , fixtureEnded ∷ TMVar SomeException
  , fixtureAcquisitions ∷ TVar Int
  , fixtureOwner ∷ ThreadId
  }

data Request r = Request
  { requestAbandoned ∷ TVar Bool
  , requestPerform ∷ r → IO ()
  , requestDecline ∷ SomeException → STM ()
  }

-- | Why a dispatched operation was never run.
data Unserved
  = OwnerFinished
    -- ^ The owner had already released its resource.
  | NotExecuted
    -- ^ The request was abandoned, or its borrower had finished, before the
    -- owner reached it.
  deriving (Eq, Show)

instance Exception Unserved

-- | The thread the owner serves on.
ownerThread ∷ Fixture r → ThreadId
ownerThread = fixtureOwner

-- | How many acquisitions the owner has attempted so far.
acquisitionCount ∷ Fixture r → IO Int
acquisitionCount = readTVarIO . fixtureAcquisitions

-- | How many requests have ever been queued.
queuedCount ∷ Fixture r → IO Int
queuedCount = readTVarIO . fixtureQueued

-- | Wait until at least this many requests have ever been queued, so an example
-- can coordinate with a request it cannot otherwise observe.
awaitQueued ∷ Fixture r → Int → IO ()
awaitQueued fixture wanted = atomically (readTVar (fixtureQueued fixture) >>= check . (>= wanted))

-- | Run an operation on the owner thread and wait for its result.
--
-- A synchronous failure inside the operation is rethrown here unchanged, with
-- the exception context it carried. If the
-- owner stops serving first, the owner's own failure is thrown, or
-- 'OwnerFinished'; if the request was settled unrun, 'NotExecuted'. Cancelling
-- the waiting thread abandons the request.
dispatch ∷ Fixture r → (r → IO a) → IO a
dispatch fixture action = do
  reply ← newEmptyTMVarIO
  abandoned ← newTVarIO False
  let request =
        Request
          { requestAbandoned = abandoned
          , requestPerform = \resource → do
              outcome ← tryJust synchronous (action resource)
              atomically (void (tryPutTMVar reply outcome))
          , requestDecline = \reason → void (tryPutTMVar reply (Left reason))
          }
  outcome ←
    mask $ \restore → do
      atomically $ do
        writeTQueue (fixtureRequests fixture) request
        modifyTVar' (fixtureQueued fixture) (+ 1)
      restore (atomically (takeTMVar reply `orElse` (Left <$> readTMVar (fixtureEnded fixture))))
        `onException` atomically (writeTVar abandoned True)
  either rethrow pure outcome

data Next r = BorrowerFinished | Serve (Request r)

-- | Make the calling thread the owner, fork the borrower, serve it until it
-- finishes, and release the resource. The borrower's own outcome is returned
-- beside the owner's report; neither is thrown.
runOwned ∷ Owner r → (Fixture r → IO a) → IO (Either SomeException a, OwnerReport)
runOwned owner borrower = do
  me ← myThreadId
  fixture ← Fixture <$> newTQueueIO <*> newTVarIO 0 <*> newEmptyTMVarIO <*> newTVarIO 0 <*> pure me
  finished ← newEmptyTMVarIO
  served ← newIORef (0 ∷ Int)
  declined ← newIORef (0 ∷ Int)
  _ ← forkFinally (borrower fixture) (atomically . void . tryPutTMVar finished)
  let next =
        atomically
          ( (BorrowerFinished <$ readTMVar finished)
              `orElse` (Serve <$> readTQueue (fixtureRequests fixture))
          )
      decline reason request = do
        atomically (requestDecline request reason)
        modifyIORef' declined (+ 1)
      drain = atomically (flushTQueue (fixtureRequests fixture)) >>= mapM_ (decline (toException NotExecuted))
      perform resource request = do
        gone ← readTVarIO (requestAbandoned request)
        if gone
          then decline (toException NotExecuted) request
          else requestPerform request resource >> modifyIORef' served (+ 1)
      -- Stop serving: wake every waiter with the reason, let the borrower
      -- finish, and settle what it left queued. Idempotent.
      stopServing reason = do
        atomically (void (tryPutTMVar (fixtureEnded fixture) reason))
        void (atomically (readTMVar finished))
        drain
      held resource first = serving `catch` \failure → stopServing failure >> rethrow failure
        where
          serving = perform resource first >> loop
          loop =
            next >>= \case
              BorrowerFinished → drain >> ownerSettled owner
              Serve request → perform resource request >> loop
      refusing failure =
        next >>= \case
          BorrowerFinished → drain
          Serve request → decline failure request >> refusing failure
      -- A failure is returned rather than rethrown, so the report carries
      -- exactly the exception the scope produced, with any cleanup evidence
      -- it retained.
      acquireFor request = do
        atomically (modifyTVar' (fixtureAcquisitions fixture) (+ 1))
        entered ← newIORef False
        outcome ←
          try . withScoped (ownerAcquire owner) $ \resource → do
            writeIORef entered True
            held resource request
        case outcome of
          Right () → pure Nothing
          Left failure → do
            inside ← readIORef entered
            unless inside $ do
              decline failure request
              refusing failure
            pure (Just failure)
      idle =
        next >>= \case
          BorrowerFinished → drain >> pure Nothing
          Serve request → do
            gone ← readTVarIO (requestAbandoned request)
            if gone
              then decline (toException NotExecuted) request >> idle
              else acquireFor request
  outcome ← try idle
  let failure = either Just id outcome
  stopServing (maybe (toException OwnerFinished) id failure)
  borrowed ← atomically (readTMVar finished)
  report ←
    OwnerReport
      <$> readTVarIO (fixtureAcquisitions fixture)
      <*> readIORef served
      <*> readIORef declined
      <*> pure failure
  pure (borrowed, report)

-- | Rethrow a failure caught on one side on the other, keeping the context it
-- was raised with rather than starting a fresh one, so failure evidence and
-- retained cleanup failures cross the dispatcher intact.
rethrow ∷ SomeException → IO a
rethrow failure = rethrowIO (ExceptionWithContext (someExceptionContext failure) failure)

-- | Everything but an asynchronous exception, which belongs to the thread it
-- was aimed at rather than to the operation that happened to be running.
synchronous ∷ SomeException → Maybe SomeException
synchronous failure = case fromException failure of
  Just (SomeAsyncException _) → Nothing
  Nothing → Just failure
