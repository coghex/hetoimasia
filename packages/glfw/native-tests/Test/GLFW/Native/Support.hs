-- | What the native examples share: the fixture over the production session,
-- native thread evidence, the platform gate, and small helpers.
--
-- The shared session is acquired by 'sharedSessionOwner' on the owner thread,
-- which 'Main' makes the process main thread. Its native thread identity is
-- checked and recorded at setup, inside every operation 'owned' dispatches,
-- before the session is released, and after it has been; any check that fails
-- fails its operation or its release, and 'Main' reports the whole record.
--
-- On Linux the session is only entered on an isolated X11 display: @DISPLAY@
-- must name one and @WAYLAND_DISPLAY@ must be absent, and the session's backend
-- must be X11. On macOS it must be Cocoa. Anything else is 'DisplayUnavailable'
-- at acquisition, which every native example then fails with; nothing selects
-- another platform instead.
module Test.GLFW.Native.Support
  ( -- * The shared session
    Shared (..)
  , sharedSessionOwner
  , owned
  , acquisitions

    -- * Native thread identity
  , ThreadEvidence
  , newThreadEvidence
  , ThreadCheck (..)
  , ThreadFacts (..)
  , onOwnerThread
  , threadFacts
  , threadChecks
  , OffOwnerThread (..)

    -- * Platform
  , hostBackend
  , DisplayUnavailable (..)

    -- * Helpers
  , expectFailure
  , failed
  , onThread
  , currentObservation
  ) where

import Control.Concurrent (ThreadId, isCurrentThreadBound, myThreadId, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (Exception, SomeException, displayException, fromException, throwIO, try)
import Control.Monad (unless, when)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import Data.Maybe (isJust)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (allocResource)
import Hetoimasia.GLFW.Internal.Native (productionNative)
import Hetoimasia.GLFW.Internal.Session (Native (nativeIsProcessMainThread))
import Hetoimasia.GLFW.Session (Backend (..), Session, allocSession, defaultSessionConfig, sessionBackend)
import Hetoimasia.GLFW.Window (Window, WindowObservation, windowObservations)
import System.Environment (lookupEnv)
import System.Info (os)
import Test.GLFW.Native.Fixture (Fixture, Owner (..), acquisitionCount, dispatch)
import Test.Hspec (expectationFailure)

-- | The fixture over the shared production session, and its thread evidence.
data Shared = Shared
  { sharedFixture ∷ Fixture Session
  , sharedEvidence ∷ ThreadEvidence
  }

-- | Where native thread identity was checked.
data ThreadCheck
  = SetupCheck
    -- ^ Once the session is entered, before any example uses it.
  | OperationCheck
    -- ^ Inside each dispatched operation.
  | BeforeReleaseCheck
    -- ^ Once every borrower has finished, before the session is released.
  | AfterReleaseCheck
    -- ^ After the session has been released.
  deriving (Eq, Ord, Show)

-- | What one check observed about the thread it ran on.
data ThreadFacts = ThreadFacts
  { factProcessMainThread ∷ Bool
    -- ^ The OS thread that entered the process main function, by the native shim.
  , factBound ∷ Bool
  , factOwnerThread ∷ Bool
    -- ^ The Haskell thread that entered the shared session.
  }
  deriving (Eq, Show)

onOwnerThread ∷ ThreadFacts → Bool
onOwnerThread (ThreadFacts processMain bound owner) = processMain && bound && owner

-- | The owner's thread and every check made against it. Written only on the
-- owner thread; read by 'Main' once the owner has finished.
data ThreadEvidence = ThreadEvidence
  { evidenceOwner ∷ IORef (Maybe ThreadId)
  , evidenceChecks ∷ IORef [(ThreadCheck, ThreadFacts)]
  }

-- | A native operation or release ran somewhere other than the owner thread.
data OffOwnerThread = OffOwnerThread ThreadCheck ThreadFacts
  deriving (Show)

instance Exception OffOwnerThread

-- | The session could not be entered on the platform this run requires.
newtype DisplayUnavailable = DisplayUnavailable String
  deriving (Show)

instance Exception DisplayUnavailable

newThreadEvidence ∷ IO ThreadEvidence
newThreadEvidence = ThreadEvidence <$> newIORef Nothing <*> newIORef []

-- | The facts about the calling thread.
threadFacts ∷ ThreadEvidence → IO ThreadFacts
threadFacts evidence = do
  processMain ← nativeIsProcessMainThread productionNative
  bound ← isCurrentThreadBound
  me ← myThreadId
  owner ← readIORef (evidenceOwner evidence)
  pure (ThreadFacts processMain bound (owner == Just me))

-- | Every check made so far, in order.
threadChecks ∷ ThreadEvidence → IO [(ThreadCheck, ThreadFacts)]
threadChecks = fmap reverse . readIORef . evidenceChecks

recordCheck ∷ ThreadEvidence → ThreadCheck → IO ()
recordCheck evidence check = do
  facts ← threadFacts evidence
  atomicModifyIORef' (evidenceChecks evidence) (\checks → ((check, facts) : checks, ()))
  unless (onOwnerThread facts) (throwIO (OffOwnerThread check facts))

-- | The production session as the fixture's owner.
--
-- Releases run in reverse: the check before release, the session itself, then
-- the check after it.
sharedSessionOwner ∷ ThreadEvidence → Owner Session
sharedSessionOwner evidence =
  Owner
    { ownerAcquire = do
        allocResource claimOwner (\() → recordCheck evidence AfterReleaseCheck)
        allocResource requireDisplay pure
        session ← allocSession defaultSessionConfig
        allocResource
          (recordCheck evidence SetupCheck >> requireBackend session)
          (\() → recordCheck evidence BeforeReleaseCheck)
        pure session
    , ownerSettled = pure ()
    }
  where
    claimOwner = myThreadId >>= atomicWriteIORef (evidenceOwner evidence) . Just

-- | Run an operation on the shared session's owner thread, checking native
-- thread identity there first.
owned ∷ Shared → (Session → IO a) → IO a
owned shared action =
  dispatch (sharedFixture shared) $ \session → do
    recordCheck (sharedEvidence shared) OperationCheck
    action session

-- | How many times the shared session has been acquired so far.
acquisitions ∷ Shared → IO Int
acquisitions = acquisitionCount . sharedFixture

-- | The backend this platform's session must select.
hostBackend ∷ Backend
hostBackend = if os == "darwin" then Cocoa else X11

requireDisplay ∷ IO ()
requireDisplay = case os of
  "darwin" → pure ()
  "linux" → do
    display ← lookupEnv "DISPLAY"
    wayland ← lookupEnv "WAYLAND_DISPLAY"
    when (maybe True null display) . throwIO $
      DisplayUnavailable
        "DISPLAY is not set, so there is no X11 display to run on, and the native examples never select another platform"
    when (isJust wayland) . throwIO $
      DisplayUnavailable
        "WAYLAND_DISPLAY is set; the native examples require an isolated X11 display, not a Wayland or XWayland session"
  other → throwIO (DisplayUnavailable ("the native examples run on Linux X11 and macOS Cocoa, not " <> other))

requireBackend ∷ Session → IO ()
requireBackend session =
  unless (sessionBackend session == hostBackend) . throwIO . DisplayUnavailable $
    "the session selected " <> show (sessionBackend session) <> ", not " <> show hostBackend

-- | Run an action that must fail with one exception type, and return it.
expectFailure ∷ Exception e ⇒ IO a → IO e
expectFailure action =
  try action >>= \case
    Right _ → failed "expected a rejection, but the action returned"
    Left caught →
      maybe
        (failed ("unexpected failure: " <> displayException (caught ∷ SomeException)))
        pure
        (fromException caught)

-- | Fail the current example.
failed ∷ String → IO a
failed message = expectationFailure message >> ioError (userError message)

-- | Run an action on a thread started by the given fork, and wait for it.
onThread ∷ (IO () → IO ThreadId) → IO a → IO a
onThread fork action = do
  finished ← newEmptyMVar
  _ ← fork (try action >>= putMVar finished)
  takeMVar finished >>= either (\failure → failed (displayException (failure ∷ SomeException))) pure

-- | A window's latest published observation.
currentObservation ∷ Window → IO WindowObservation
currentObservation window =
  preparedValue . observedValue <$> atomically (readSnapshot (windowObservations window))
