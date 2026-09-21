-- | What the native examples share: the fixture over the production session,
-- native thread evidence, the platform gate, and small helpers.
--
-- The shared session is acquired by 'sharedSessionOwner' on the owner thread,
-- which 'Main' makes the process main thread. Its native thread identity is
-- checked and recorded at setup, inside every operation 'owned' dispatches,
-- before the session is released, and after it has been; any check that fails
-- fails its operation or its release, and 'Main' reports the whole record.
--
-- Nothing reaches the session without consent. Every example that uses the
-- session or starts a child runs under 'consented', a hook that asks the run's
-- 'Gate' before the example's body: a run whose environment carries no consent
-- ("Test.GLFW.Native.Consent") has the example fail with
-- 'NativeSessionRefused' before it forks, waits, or dispatches anything, so
-- nothing is left waiting on an operation that never ran. Every operation
-- 'owned' dispatches asks the gate again on the example's own thread, and the
-- owner's acquisition asks once more before initializing GLFW, so no path
-- around the hook enters a session either. The gate counts what it refused,
-- and 'Main' reports the refusal once; the report shows no acquisition.
--
-- On Linux the session is entered only inside the isolation its consent names.
-- Under the desktop or isolated X11 consent that is an X11 display: @DISPLAY@
-- must name one, @WAYLAND_DISPLAY@ must be absent, and the session's backend
-- must be X11. Under the isolated Wayland consent it is the compositor's
-- socket: @WAYLAND_DISPLAY@ must name exactly the socket the consent
-- authorized, @DISPLAY@ must be unset so no XWayland display can stand in, the
-- session requests Wayland by name, and its backend must be Wayland. On macOS
-- it must be Cocoa. Anything else is 'DisplayUnavailable' at acquisition,
-- which every native example then fails with; nothing selects another platform
-- instead, and no request falls back to the other backend.
module Test.GLFW.Native.Support
  ( -- * The shared session
    Shared (..)
  , sharedSessionOwner
  , owned
  , acquisitions

    -- * Consent
  , Gate
  , newGate
  , gateConsent
  , admit
  , consented
  , gated
  , refusals

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
  , consentBackend
  , sharedBackend
  , consentSessionConfig
  , DisplayUnavailable (..)

    -- * Helpers
  , expectFailure
  , failed
  , onThread
  , currentObservation
  , requestClose
  , platformSizeLimits
  ) where

import Control.Concurrent (ThreadId, isCurrentThreadBound, myThreadId, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (Exception, SomeException, displayException, fromException, throwIO, try)
import Control.Monad (unless, when)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import Data.Maybe (isJust)
import Foreign.Ptr (Ptr)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (allocResource)
import Hetoimasia.GLFW.Internal.Native (checkHelperBackends, productionNative, requestCloseForCheck, sizeLimitsForCheck)
import Hetoimasia.GLFW.Internal.Session (Native (nativeIsProcessMainThread), NativeWindow)
import Hetoimasia.GLFW.Session
  ( Backend (..)
  , Session
  , SessionConfig (requestedBackend)
  , allocSession
  , defaultSessionConfig
  , sessionBackend
  )
import Hetoimasia.GLFW.Window (Window, WindowObservation, windowObservations)
import System.Environment (lookupEnv)
import System.Info (os)
import Test.GLFW.Native.Consent (Consent (..), NativeSessionRefused (..), Refusal)
import Test.GLFW.Native.Fixture (Fixture, Owner (..), acquisitionCount, dispatch)
import Test.Hspec (SpecWith, before_, expectationFailure)

-- | The fixture over the shared production session, its thread evidence, and
-- the run's consent gate.
data Shared = Shared
  { sharedFixture ∷ Fixture Session
  , sharedEvidence ∷ ThreadEvidence
  , sharedGate ∷ Gate
  }

-- | The run's consent, read once, and a count of what it has refused.
--
-- The count is written by whichever thread asked and read by 'Main' once the
-- run has finished.
data Gate = Gate
  { gateConsent ∷ Either Refusal Consent
  , gateRefusals ∷ IORef Int
  }

newGate ∷ Either Refusal Consent → IO Gate
newGate consent = Gate consent <$> newIORef 0

-- | The consent this run carries, or the refusal raised on the calling thread,
-- counted.
admit ∷ Gate → IO Consent
admit gate = case gateConsent gate of
  Right consent → pure consent
  Left refusal → do
    atomicModifyIORef' (gateRefusals gate) (\count → (count + 1, ()))
    throwIO (NativeSessionRefused refusal)

-- | Dispatch an operation to a fixture only once the gate admits the run. A
-- refused operation is never dispatched, so the owner never attempts its
-- acquisition.
gated ∷ Gate → Fixture r → (r → IO a) → IO a
gated gate fixture action = do
  _ ← admit gate
  dispatch fixture action

-- | Run these examples only under consent: each is refused before its body,
-- so a body that forks, waits, or dispatches never starts without it. A dry
-- run and a listing run no hook and refuse nothing.
consented ∷ Gate → SpecWith a → SpecWith a
consented gate = before_ (() <$ admit gate)

-- | How many examples, operations, or launches the gate has refused so far.
refusals ∷ Gate → IO Int
refusals = readIORef . gateRefusals

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
-- The gate is asked before GLFW is initialized, so a refusal that somehow
-- reached the owner fails the acquisition rather than entering a session.
-- Releases run in reverse: the check before release, the session itself, then
-- the check after it.
sharedSessionOwner ∷ ThreadEvidence → Gate → Owner Session
sharedSessionOwner evidence gate =
  Owner
    { ownerAcquire = do
        allocResource claimOwner (\() → recordCheck evidence AfterReleaseCheck)
        consent ← allocResource (admit gate >>= \granted → requireDisplay granted >> pure granted) (\_ → pure ())
        session ← allocSession (consentSessionConfig consent)
        allocResource
          (recordCheck evidence SetupCheck >> requireBackend consent session)
          (\() → recordCheck evidence BeforeReleaseCheck)
        pure session
    , ownerSettled = pure ()
    }
  where
    claimOwner = myThreadId >>= atomicWriteIORef (evidenceOwner evidence) . Just

-- | Run an operation on the shared session's owner thread, once the run's gate
-- admits it, checking native thread identity there first.
owned ∷ Shared → (Session → IO a) → IO a
owned shared action =
  gated (sharedGate shared) (sharedFixture shared) $ \session → do
    recordCheck (sharedEvidence shared) OperationCheck
    action session

-- | How many times the shared session has been acquired so far.
acquisitions ∷ Shared → IO Int
acquisitions = acquisitionCount . sharedFixture

-- | The backend this platform's session selects when nothing requests another.
hostBackend ∷ Backend
hostBackend = if os == "darwin" then Cocoa else X11

-- | The backend the shared session must select under one consent. Only the
-- isolated compositor's consent asks for Wayland, and it asks explicitly; every
-- other consent takes the platform's own backend, exactly as before.
consentBackend ∷ Consent → Backend
consentBackend = \case
  IsolatedWayland _ → Wayland
  Desktop → hostBackend
  IsolatedX11 _ → hostBackend

-- | The backend the shared session selects under this run's consent, for the
-- examples that assert on it. A run carrying no consent enters no session, so
-- the platform's own backend is the only answer it could be asked for.
sharedBackend ∷ Gate → Backend
sharedBackend = either (const hostBackend) consentBackend . gateConsent

-- | How the shared session is entered under one consent. The compositor's
-- consent requests Wayland by name, because nothing selects it otherwise.
consentSessionConfig ∷ Consent → SessionConfig
consentSessionConfig consent = case consent of
  IsolatedWayland _ → defaultSessionConfig {requestedBackend = Just Wayland}
  _ → defaultSessionConfig

-- | The private environment one consent requires before a session is entered.
--
-- This is the fixture's rule, not the session's: the session resolves a
-- backend from what it was asked for, while the suite additionally refuses to
-- run anywhere but the isolation its consent names.
requireDisplay ∷ Consent → IO ()
requireDisplay consent = case os of
  "darwin" → pure ()
  "linux" → case consent of
    IsolatedWayland socket → do
      wayland ← lookupEnv "WAYLAND_DISPLAY"
      display ← lookupEnv "DISPLAY"
      unless (wayland == Just socket) . throwIO . DisplayUnavailable $
        "WAYLAND_DISPLAY is "
          <> maybe "not set" show wayland
          <> ", not the isolated socket "
          <> show socket
          <> " this run was authorized for"
      when (isJust display) . throwIO $
        DisplayUnavailable
          "DISPLAY is set; the Wayland examples require the isolated compositor alone, never an X11 or XWayland display"
    _ → do
      display ← lookupEnv "DISPLAY"
      wayland ← lookupEnv "WAYLAND_DISPLAY"
      when (maybe True null display) . throwIO $
        DisplayUnavailable
          "DISPLAY is not set, so there is no X11 display to run on, and the native examples never select another platform"
      when (isJust wayland) . throwIO $
        DisplayUnavailable
          "WAYLAND_DISPLAY is set; the native examples require an isolated X11 display, not a Wayland or XWayland session"
  other → throwIO (DisplayUnavailable ("the native examples run on Linux X11 and Wayland and macOS Cocoa, not " <> other))

requireBackend ∷ Consent → Session → IO ()
requireBackend consent session =
  unless (sessionBackend session == wanted) . throwIO . DisplayUnavailable $
    "the session selected " <> show (sessionBackend session) <> ", not " <> show wanted
  where
    wanted = consentBackend consent

-- | Ask the platform to close a window as its close button would, failing the
-- example when the driver could not deliver the request.
--
-- The driver is unavailable on a backend that exposes no Cocoa or X11 handle,
-- and answers so rather than doing nothing observable, which is why every
-- example that drives a close asks through here: an unavailable driver fails
-- its example instead of leaving it waiting for a request nobody sent. The
-- backends that expose a handle are 'checkHelperBackends'.
requestClose ∷ Ptr NativeWindow → IO ()
requestClose handle = do
  delivered ← requestCloseForCheck handle
  unless delivered . failed $
    "the close-request driver is unavailable on this session's backend; it reaches a window through "
      <> show checkHelperBackends
      <> " handles only, and what is unavailable is the driver, not window closure"

-- | The size limits the platform itself holds for a window, failing the
-- example when this session's backend exposes no handle to read them through.
-- A 'Nothing' from the reader is never evidence that the window holds no
-- constraints.
platformSizeLimits ∷ Ptr NativeWindow → IO (Maybe Int, Maybe Int, Maybe Int, Maybe Int)
platformSizeLimits handle =
  sizeLimitsForCheck handle >>= \case
    Just limits → pure limits
    Nothing →
      failed $
        "the platform size-limit reader is unavailable on this session's backend; it reads back through "
          <> show checkHelperBackends
          <> " handles only, and says nothing about the constraints GLFW holds"

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
