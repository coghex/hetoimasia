-- | The integration suite's example bound, which knows the rigs it bounds.
--
-- A plain 'System.Timeout.timeout' cannot end a rig example. 'runRig' runs its
-- body through @runInBoundThread@, so the example's own thread waits inside a
-- safe foreign call while a bound thread runs the body, and an exception
-- thrown to the example's thread is deferred until that call returns. Even an
-- exception delivered to the bound thread would not end the run: the graphics
-- owner's protected exit absorbs cancellation until it has real destruction
-- evidence, and in a scripted rig that evidence waits on what the rig
-- withholds — presentations it does not retire, holds it has not opened, a
-- clock that moves only when the example moves it.
--
-- So the bound here, on expiry:
--
-- 1. starts its own watchdog for one short cleanup grace;
-- 2. rescues every rig the example made: each stops withholding anything
--    ("Test.GPU.Vulkan.GLFW.StandIn" documents what that releases);
-- 3. only then cancels each rig run's bound thread, and the example's own
--    thread, with 'BoundExpired';
-- 4. waits for the example to settle — its own thread ended, every rig run it
--    started ended, every cancellation delivered — which the owner's protected
--    exit allows once it has completed on real destruction evidence; and
-- 5. fails the example, whatever the example's thread ended with.
--
-- The budget is the whole example's: it does not restart at each rig run. The
-- hard total is the bound plus the grace. If the example has not settled
-- when the grace expires, the last resort names the example on standard
-- error and ends the test process with a failure status, without unwinding
-- anything: operator termination is the protected exit's documented escape,
-- and this suite takes it rather than waiting for ever.
--
-- A rig rescues itself, too, when a synchronous failure or 'BoundExpired'
-- escapes its body, before the protected teardown begins; that is how an
-- example that fails before releasing its gates still reports its own failure.
--
-- __State.__ One process-wide cell names the bound of the example running
-- now. This module owns it. 'runBounded' writes it on the example's Hspec
-- thread on entry, and restores the enclosing bound, if any, on exit. A rig's
-- constructor reads it, on whatever thread makes the rig, and keeps what it
-- found for the rig's lifetime. The suite runs its examples one at a time,
-- which is what makes the example running now a single bound; a bound run
-- inside another one shadows it until it returns.
module Test.GPU.Vulkan.GLFW.Bound
  ( -- * Bounding an example
    BoundSettings (..)
  , boundOf
  , cleanupGrace
  , boundedIt
  , runBounded

    -- * What a rig reads
  , BoundScope
  , currentBound
  , boundRescuing
  , withBoundThread
  , BoundExpired (..)
  , isBoundExpiry
  ) where

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, throwTo)
import Control.Concurrent.STM
  ( STM
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
  , registerDelay
  , stateTVar
  , throwSTM
  , writeTVar
  )
import Control.Exception
  ( Exception (..)
  , ExceptionWithContext
  , SomeException
  , asyncExceptionFromException
  , asyncExceptionToException
  , bracket
  , bracket_
  , mask_
  , rethrowIO
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (void, when)
import Data.List (intercalate)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Unique (Unique, newUnique)
import Foreign.C.Types (CInt (..))
import System.IO (hFlush, hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec (Spec, expectationFailure, it)
import Test.Hspec.Core.Spec (getSpecDescriptionPath)

-- ---------------------------------------------------------------------------
-- Bounding an example

-- | How one example is bounded.
data BoundSettings = BoundSettings
  { boundExpiry ∷ IO (STM ())
    -- ^ Arms the example's bound as it starts: the transaction succeeds once
    -- the bound has expired.
  , boundGrace ∷ IO (STM ())
    -- ^ Arms the cleanup grace as rescue begins: the transaction succeeds once
    -- the grace has expired.
  , boundTerminate ∷ String → IO ()
    -- ^ The last resort, given the example's name. The suite's ends the
    -- process; an example of the bound itself observes it instead.
  , boundStarted ∷ ThreadId → IO ()
    -- ^ Told of every thread the bound starts, so an example of the bound
    -- itself can see that each has ended.
  }

-- | A bound of this many seconds, with 'cleanupGrace' after it, whose last
-- resort ends the process.
boundOf ∷ Int → BoundSettings
boundOf seconds =
  BoundSettings
    { boundExpiry = delay (seconds * 1000000)
    , boundGrace = delay cleanupGrace
    , boundTerminate = terminateProcess
    , boundStarted = \_ → pure ()
    }
  where
    delay micros = (\expired → readTVar expired >>= check) <$> registerDelay micros

-- | How long, in microseconds, a rescued example has to end after its bound
-- expired before the last resort: ten seconds.
cleanupGrace ∷ Int
cleanupGrace = 10 * 1000000

-- | An example under this bound, named by its whole description path.
boundedIt ∷ BoundSettings → String → IO () → Spec
boundedIt settings requirement test = do
  path ← getSpecDescriptionPath
  it requirement (runBounded settings (intercalate "/" (path <> [requirement])) test)

-- | Run one example under this bound, on a thread of its own, failing it with
-- "the example did not finish within its bound" if the bound expires first.
--
-- If the calling thread is itself interrupted while it waits — an enclosing
-- bound cancelling it — this example is rescued and cancelled the same way
-- before the interruption is rethrown.
runBounded ∷ BoundSettings → String → IO () → IO ()
runBounded settings name test = do
  scope ← BoundScope <$> newTVarIO False <*> newTVarIO Map.empty
  expired ← boundExpiry settings
  bracket (enter scope) leave $ \_ → do
    result ← newEmptyTMVarIO
    worker ← mask_ $ forkIOWithUnmask (\unmask → tryWithContext @SomeException (unmask test) >>= atomically . putTMVar result)
    boundStarted settings worker
    waited ← tryWithContext (atomically ((Just <$> readTMVar result) `orElse` (Nothing <$ expired)))
    case waited of
      Right (Just finished) → either rethrowIO pure finished
      Right Nothing → do
        rescue settings name scope worker (void (readTMVar result))
        expectationFailure "the example did not finish within its bound"
      Left interrupted → do
        rescue settings name scope worker (void (readTMVar result))
        rethrowIO (interrupted ∷ ExceptionWithContext SomeException)
  where
    enter scope = atomically (stateTVar currentCell (\enclosing → (enclosing, Just scope)))
    leave enclosing = atomically (writeTVar currentCell enclosing)

-- | Rescue the example's rigs, then cancel its threads, then wait for the
-- example to settle — under a watchdog started first, so nothing here can keep
-- the grace from expiring — and join every thread this started before
-- returning.
--
-- The example has settled only once its own thread has ended, every rig run it
-- started has ended, and every cancellation has been delivered: a rig run on a
-- thread of the example's own can outlive the example's thread, its
-- cancellation held off by an uninterruptible call, and the watchdog stays
-- armed until it too is over.
rescue ∷ BoundSettings → String → BoundScope → ThreadId → STM () → IO ()
rescue settings name scope worker ended = do
  settled ← newTVarIO False
  watchdog ← started settings $ do
    grace ← boundGrace settings
    -- Settlement first: an example that ended as the grace expired has ended.
    over ← atomically ((False <$ (readTVar settled >>= check)) `orElse` (True <$ grace))
    when over (boundTerminate settings name)
  -- One transaction: a rig run that enlists after this sees the rescue and
  -- raises at once, and one that enlisted before is cancelled below.
  runs ← atomically $ do
    writeTVar (scopeRescuing scope) True
    Map.elems <$> readTVar (scopeThreads scope)
  -- Each delivery from a thread of its own: one held off by an
  -- uninterruptible call must not hold up the others, or this thread.
  cancellers ← mapM (\thread → started settings (throwTo thread BoundExpired)) (runs <> [worker])
  uninterruptibleMask_ . atomically $ do
    ended
    mapM_ joined cancellers
    readTVar (scopeThreads scope) >>= check . Map.null
  atomically (writeTVar settled True)
  atomically (joined watchdog)
  where
    joined done = readTVar done >>= check

-- | Start a thread, tell the settings of it, and answer a cell that becomes
-- true once it has ended.
started ∷ BoundSettings → IO () → IO (TVar Bool)
started settings action = do
  done ← newTVarIO False
  thread ← mask_ $ forkIOWithUnmask (\unmask → void (tryWithContext (unmask action) ∷ IO (Either (ExceptionWithContext SomeException) ())) >> atomically (writeTVar done True))
  boundStarted settings thread
  pure done

-- | Name the example on standard error and end the process with a failure
-- status, at once, unwinding nothing. The message is written from a thread of
-- its own and waited for a second at most, so a blocked standard error cannot
-- become another unbounded wait.
terminateProcess ∷ String → IO ()
terminateProcess name = do
  written ← newTVarIO False
  _ ← forkIO $ do
    hPutStrLn stderr ("integration-tests: \"" <> name <> "\" did not end within its bound and its cleanup grace; ending the test process")
    hFlush stderr
    atomically (writeTVar written True)
  limit ← registerDelay 1000000
  atomically ((readTVar written >>= check) `orElse` (readTVar limit >>= check))
  exitImmediately 1

foreign import ccall unsafe "stdlib.h _Exit"
  exitImmediately ∷ CInt → IO ()

-- ---------------------------------------------------------------------------
-- What a rig reads

-- | The bound of one running example, as its rigs see it.
data BoundScope = BoundScope
  { scopeRescuing ∷ !(TVar Bool)
    -- ^ Whether the bound has expired and rescue has begun.
  , scopeThreads ∷ !(TVar (Map Unique ThreadId))
    -- ^ The bound thread of each rig run now under way.
  }

-- | The process-wide cell naming the bound of the example running now.
currentCell ∷ TVar (Maybe BoundScope)
currentCell = unsafePerformIO (newTVarIO Nothing)
{-# NOINLINE currentCell #-}

-- | The bound of the example running now, if any.
currentBound ∷ IO (Maybe BoundScope)
currentBound = readTVarIO currentCell

-- | Whether this bound has expired and its rigs are being rescued.
boundRescuing ∷ BoundScope → STM Bool
boundRescuing = readTVar . scopeRescuing

-- | Run this on the calling thread as a rig run's bound thread: the bound
-- cancels it with 'BoundExpired' once it has rescued the example's rigs. A
-- run that starts after rescue has begun raises 'BoundExpired' at once.
withBoundThread ∷ Maybe BoundScope → ThreadId → IO a → IO a
withBoundThread Nothing _ action = action
withBoundThread (Just scope) self action = do
  key ← newUnique
  bracket_
    ( atomically $ do
        rescuing ← readTVar (scopeRescuing scope)
        when rescuing (throwSTM BoundExpired)
        modifyTVar' (scopeThreads scope) (Map.insert key self)
    )
    (atomically (modifyTVar' (scopeThreads scope) (Map.delete key)))
    action

-- | What the bound delivers to the threads it cancels: asynchronous, so the
-- owner's protected exit treats it as the cancellation it is.
data BoundExpired = BoundExpired
  deriving (Eq, Show)

instance Exception BoundExpired where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException
  displayException _ = "the example's bound expired"

-- | Whether this is the bound's cancellation.
isBoundExpiry ∷ SomeException → Bool
isBoundExpiry raised = isJust (fromException raised ∷ Maybe BoundExpired)
