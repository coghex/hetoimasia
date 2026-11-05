{-# LANGUAGE OverloadedRecordDot #-}

-- | The shared Vulkan fixture: one production graphics session — a GLFW
-- session on the process main thread, the supervised graphics owner, and the
-- native roots it owns — shared by every compatible example of a run.
--
-- It is built on the GLFW native suite's ownership lessons, not on a generic
-- fixture framework, and it composes nothing of its own: the session is the
-- window integration package's 'withVulkanOwnerHost' over the production
-- native layer and surface bridge, run by 'runGraphicsOwnerApplication' with
-- the validation layer and 'validationFeatures' enabled through the instance's
-- own create info. What the fixture adds is the dispatch:
--
-- * Hspec runs on a worker thread, and the process main thread owns the
--   session. An example that needs the main thread — to hand a window's
--   surface over, which GLFW creates there, or to close a window — submits an
--   operation with 'onMain'; the main thread runs it between two turns of the
--   host's owner loop, and the result or the original failure comes back. A
--   window is created by submitting a command through the host's own command
--   port, which the owner loop executes, exactly as an application's worker
--   would.
-- * Every dispatched operation checks, before it runs, that it is on the
--   bound process main thread that entered the session — the Haskell thread,
--   the bound flag, and the OS thread read through @pthread_self@ — and a
--   failed check fails the operation and the run. The graphics owner's native
--   calls are recorded where they run by a 'NativeObserver', so an example
--   shows which identity ran each native step from the calls themselves, not
--   from the name of an Hspec hook.
-- * The session is acquired lazily, by the first dispatched operation, and at
--   most once. Building, listing and filtering the Hspec tree, a dry run, and a
--   selection that dispatches nothing acquire nothing.
-- * The roots — the instance, its explicit messenger and the one shared
--   device — are shared: once created they serve every later example's
--   targets. Each example's windows and targets are its own, created and
--   closed inside it. An example that must destroy or poison the roots runs in
--   a child process instead ("Test.GPU.Vulkan.Native.Private").
-- * The session is released only once the Hspec run has finished: the loop
--   finishes, the host retires every target and destroys the device, the
--   messenger and the instance on the owner's thread, and only then is the
--   capture's verdict computed. 'runShared' returns it with every native call
--   the owner made, for the checks the run applies after teardown.
module Test.GPU.Vulkan.Native.Fixture
  ( Fixture
  , SharedReport (..)
  , ThreadCheck (..)
  , runShared
    -- * The test-side seams
  , Request
  , Session
  , Seams (..)
  , afterFailureBound
  , runSharedWith
  , fixtureConsent
  , onMain
  , sharedHost
  , nativeCalls
  , mainOsThread
  , fixtureMainThread
  , createWindow
  , commandWindow
  , publishObservation
  , readObservation
  , closeWindow
  , awaitWithin
  ) where

import Control.Concurrent (ThreadId, isCurrentThreadBound, myThreadId)
import Control.Concurrent.STM
  ( STM
  , TMVar
  , TQueue
  , TVar
  , atomically
  , check
  , newEmptyTMVarIO
  , newTQueueIO
  , newTVarIO
  , orElse
  , putTMVar
  , readTMVar
  , readTQueue
  , readTVar
  , readTVarIO
  , registerDelay
  , retry
  , takeTMVar
  , tryPutTMVar
  , tryReadTQueue
  , writeTQueue
  , writeTVar
  )
import Control.Exception
  ( Exception (..)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask
  , onException
  , throwIO
  , try
  , tryJust
  )
import Control.Monad (unless, void)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Data.Word (Word64)
import System.Timeout (timeout)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogEntry
  , LogFilter (..)
  , LogLevel (Info)
  , Logger
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.GLFW.Command
  ( WaitedSubmission (..)
  , WindowCommand
  , awaitSubmitWindowCommand
  , clientObservations
  , clientWindow
  , createWindowCommand
  , pollCompletion
  , pollWindowClient
  )
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (WindowId, WindowObservation, hiddenTestWindowConfig, observedRevision)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Vulkan.Diagnostics (DiagnosticVerdict)
import Hetoimasia.GPU.Vulkan.GLFW
  ( VulkanHost (..)
  , VulkanHostConfig (..)
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.Runtime.GLFW
  ( CloseStart (..)
  , GraphicsService
  , HostConfig (..)
  , LoopHooks (..)
  , ObservationPublication
  , TurnStep (..)
  , closeHostWindow
  , defaultHostConfig
  , hostCommandPort
  , hostWindowClient
  , hostWindowIdentities
  , noApplicationEvents
  , publishGraphicsObservation
  , runGraphicsOwnerApplication
  , runOwnerLoop
  , windowRenderEligibility
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Test.GPU.Vulkan.Native.Environment (checkValidationFeatures, validationFeatures)
import Test.GPU.Vulkan.Native.Consent (Consent, Refusal, consentBackend)
import Test.GPU.Vulkan.Native.Gate (Gate, admit, gateConsent)
import Test.GPU.Vulkan.Native.Platform (requestingBackend)
import Test.Support.Owned (withOwnedThreadOpening)
import Test.Vulkan.Proof.Interop (osThread)
import Test.Vulkan.Proof.Roots (NativeCall, nativeCallObserver, rootsCaptureConfig)

-- | Where a dispatched operation's thread identity was checked.
data ThreadCheck = ThreadCheck
  { checkedOn ∷ !Text
  , checkedPassed ∷ !Bool
  }
  deriving (Show)

-- | One dispatched operation, waiting for the main thread.
data Request = Request
  { requestAbandoned ∷ !(TVar Bool)
  , requestPerform ∷ VulkanHost () → IO ()
  , requestDecline ∷ SomeException → IO ()
  }

data Fixture = Fixture
  { fixtureGate ∷ !Gate
  , fixtureRequests ∷ !(TQueue Request)
  , fixtureBorrowerDone ∷ !(TVar Bool)
  , fixtureEnded ∷ !(TMVar SomeException)
    -- ^ Filled once the session can serve nothing more, with why.
  , fixtureHost ∷ !(TMVar (VulkanHost ()))
  , fixtureCalls ∷ !(IORef [NativeCall])
  , fixtureChecks ∷ !(IORef [ThreadCheck])
  , fixtureAcquisitions ∷ !(IORef Int)
  , fixtureMainThread ∷ !ThreadId
  , fixtureMainOs ∷ !Word64
  , fixtureEntries ∷ !(IORef [LogEntry])
  }

-- | What the run's shared session did, read after it was released.
data SharedReport = SharedReport
  { reportAcquisitions ∷ !Int
  , reportCalls ∷ ![NativeCall]
    -- ^ Every native call the session made, in the order they returned.
  , reportVerdict ∷ !(Maybe DiagnosticVerdict)
    -- ^ The capture's verdict, computed after the last teardown callback;
    -- 'Nothing' when nothing was acquired.
  , reportFailure ∷ !(Maybe Text)
    -- ^ How the session ended, when it did not end cleanly.
  , reportChecks ∷ ![ThreadCheck]
  , reportMainOs ∷ !Word64
  , reportMainThread ∷ !ThreadId
  , reportEntries ∷ ![LogEntry]
    -- ^ Every diagnostic record the capture delivered, kept for a report
    -- whose verdict is not clean.
  }

data Finished = Finished

instance Show Finished where
  show Finished = "the shared session has already been released"

instance Exception Finished

-- | The consent the run was started with, which names the backend the shared
-- session requests.
fixtureConsent ∷ Fixture → Either Refusal Consent
fixtureConsent = gateConsent . fixtureGate

-- | What serves the first operation once the session is acquired: the production session, or a test's stand-in. It
-- answers when the borrower has finished and the session has been released, and it is given the cell the verdict is
-- written to. It is the only place the native layer is entered.
type Session = Fixture → IORef (Maybe DiagnosticVerdict) → Request → IO ()

-- | The two seams a test of the dispatch itself needs, and nothing a run uses by default ('runShared' gives the
-- production values). Neither changes what a run does: a test substitutes a stand-in session so that the dispatch can be
-- exercised without a native acquisition, and the start of the borrower so that the unowned start it replaced can be
-- compared with the owned one.
data Seams = Seams
  { seamSession ∷ Session
  , seamBorrow ∷ ∀ b. IO () → IO () → (ThreadId → IO () → IO b) → IO b
    -- ^ How the borrower is started for the length of the dispatch: what must be let go before it can end (idempotent,
    -- non-blocking), its action, and the body that serves it. Production: 'withOwnedThreadOpening'.
  , seamFailureBound ∷ Int
    -- ^ How long, in microseconds, the dispatch waits for the borrower to finish on its own once the session has failed and
    -- been reported (see 'runSharedWith'). Production: 'afterFailureBound'. A test that wants the expiry states zero, which
    -- expires at once and needs no timing.
  }

-- | The bound on the wait for the borrower after a session failure: fifteen minutes, an order of magnitude beyond what the whole
-- profile takes on the slowest runner, so it only ever turns a borrower that nothing will finish into a failure, never a slow
-- run into one. It is a failure bound and not a coordination: the wait ends earlier, on the borrower's result, in every run
-- that is not stuck.
afterFailureBound ∷ Int
afterFailureBound = 15 * 60 * 1000000

-- | Run the borrower — the Hspec run — on a thread of its own, and serve its
-- operations on this one, which must be the process main thread.
--
-- The borrower is owned (#596): however serving ends — a return, a failure, a timeout of the example, a cancellation, in
-- the idle wait, in the session or in the wait for the borrower's result — the borrower has ended and been joined before
-- this returns or raises. Its start and its stop-and-join are one masked step, and the release first fills the cell that
-- ends every wait on the session (an idempotent, non-blocking opening), so a borrower held at the session's end is let
-- go before it is killed. The wait for the borrower's result stays: it is what lets the Hspec run finish and report after a
-- session that could not be served, and ownership adds only that no exit leaves the borrower behind. That wait is the one place
-- a session failure that was caught and reported could keep the scope from reaching its release, when the borrower is parked
-- where nothing now ends it, so it is bounded ('seamFailureBound'): a borrower still running when the bound expires is stopped
-- and joined by the scope's release, and the dispatch raises, naming the failure that was reported. Every other path already
-- holds the borrower's result when it gets here (the serving loop ends only when the borrower has), so the wait there takes it
-- at once.
--
-- State owner: this function owns the borrower's thread, and the request queue, the cells and the counters the borrower
-- shares with the serving thread. Readers/writers: the borrower (requests, its result, its done flag) and the serving thread
-- (the replies). Thread: the borrower's, one per call. Lifetime: the call. Disposal: the scope's release.
runShared ∷ Gate → (Fixture → IO a) → IO (a, SharedReport)
runShared = runSharedWith Seams {seamSession = nativeSession, seamBorrow = withOwnedThreadOpening, seamFailureBound = afterFailureBound}

-- | 'runShared' with its seams given (see 'Seams'); a test-side entry only.
runSharedWith ∷ Seams → Gate → (Fixture → IO a) → IO (a, SharedReport)
runSharedWith seams gate borrower = do
  requests ← newTQueueIO
  done ← newTVarIO False
  ended ← newEmptyTMVarIO
  host ← newEmptyTMVarIO
  calls ← newIORef []
  checks ← newIORef []
  acquisitions ← newIORef 0
  entries ← newIORef []
  mainThread ← myThreadId
  mainOs ← osThread
  let fixture = Fixture gate requests done ended host calls checks acquisitions mainThread mainOs entries
  result ← newEmptyTMVarIO
  let -- What 'forkFinally' did, so the borrower's result and done flag are published however it ended.
      borrow = mask $ \restore → try @SomeException (restore (borrower fixture)) >>= \outcome → atomically (putTMVar result outcome >> writeTVar done True)
      -- Anything waiting on the session is answered, once, by whoever gets there first.
      release = void (atomically (tryPutTMVar ended (toException Finished)))
  seamBorrow seams release borrow $ \_ _ → do
    verdictCell ← newIORef Nothing
    failure ← idle (seamSession seams) fixture verdictCell
    -- Anything still queued, or submitted from now on, is answered: the session
    -- has gone.
    void (atomically (tryPutTMVar ended (maybe (toException Finished) id failure)))
    declineQueued fixture
    outcome ← case failure of
      Nothing → atomically (takeTMVar result)
      Just reported →
        timeout (seamFailureBound seams) (atomically (takeTMVar result))
          >>= maybe
            (throwIO (userError ("the borrower had not finished when the bound on waiting for it after the session failed expired; the session failed: " <> displayException reported)))
            pure
    report ←
      SharedReport
        <$> readIORef acquisitions
        <*> (reverse <$> readIORef calls)
        <*> readIORef verdictCell
        <*> pure (Text.pack . displayException <$> failure)
        <*> (reverse <$> readIORef checks)
        <*> pure mainOs
        <*> pure mainThread
        <*> (reverse <$> readIORef entries)
    either throwIO (\value → pure (value, report)) outcome

-- | Wait for the first operation, or for the borrower to finish without one.
idle ∷ Session → Fixture → IORef (Maybe DiagnosticVerdict) → IO (Maybe SomeException)
idle session fixture verdictCell = do
  next ← atomically ((Just <$> readTQueue (fixtureRequests fixture)) `orElse` (Nothing <$ (readTVar (fixtureBorrowerDone fixture) >>= check)))
  case next of
    Nothing → pure Nothing
    Just request → do
      gone ← readTVarIO (requestAbandoned request)
      if gone
        then requestDecline request (toException Finished) >> idle session fixture verdictCell
        else acquire session fixture verdictCell request

-- | Enter the session for the first operation, serve every operation until
-- the borrower finishes, and release it.
--
-- A failure of the session is answered and reported, never retried. A cancellation is not a failure of the session: it is
-- answered to the operation that was waiting for the session, and then raised again, so that it ends the dispatch (and the
-- scope that owns the borrower) instead of being read as a session that failed and followed by a wait for a borrower that
-- nothing now ends.
acquire ∷ Session → Fixture → IORef (Maybe DiagnosticVerdict) → Request → IO (Maybe SomeException)
acquire session fixture verdictCell first = do
  modifyIORef' (fixtureAcquisitions fixture) (+ 1)
  outcome ← try @SomeException (session fixture verdictCell first)
  case outcome of
    Left failure → do
      -- An acquisition that failed is never retried: the first operation and
      -- every later one are answered with the failure.
      requestDecline first failure
      case fromException failure of
        Just (_ ∷ SomeAsyncException) → throwIO failure
        Nothing → pure (Just failure)
    Right () → pure Nothing

-- | The production session: the shared graphics session, entered for the first operation.
nativeSession ∷ Session
nativeSession fixture verdictCell first = do
  -- Consent is asked again before anything native is initialized, so an
  -- operation that reached the owner without passing the gate is refused
  -- here. It also names the backend the session requests.
  consent ← admit (fixtureGate fixture)
  checkValidationFeatures >>= either (throwIO . userError . Text.unpack) pure
  scene ← prepare ()
  budgets ← either (throwIO . userError . show) pure (validateBudgets defaultBudgetRequest)
  let logger = collectingLogger (fixtureEntries fixture)
      host = requestingBackend (consentBackend consent) (defaultHostConfig []) {hostIdleWait = 0.02, hostWindowLimit = 8}
      config =
        (vulkanHostConfig host rootsCaptureConfig budgets scene)
          { vulkanLayers = [Encoding.encodeUtf8 "VK_LAYER_KHRONOS_validation"]
          , vulkanValidationFeatures = validationFeatures
          , vulkanObserver = nativeCallObserver (fixtureCalls fixture)
          }
  withLoaderIntegration $ \integration →
    runGraphicsOwnerApplication
      (withLoggingLifetime logger)
      "vulkan-native-tests"
      ( \_ use → do
          (served, verdict) ← withVulkanOwnerHost logger integration config use
          writeIORef verdictCell (Just verdict)
          pure served
      )
      vulkanWindowHost
      (\vulkan _ → pure vulkan)
      (serve fixture first)

-- | Turn the owner loop, running each queued operation between turns, until
-- the borrower has finished.
serve ∷ Fixture → Request → VulkanHost () → RuntimeControl → IO ()
serve fixture first vulkan control = do
  atomically (putTMVar (fixtureHost fixture) vulkan)
  perform fixture vulkan first
  runOwnerLoop
    (vulkanWindowHost vulkan)
    control
    LoopHooks
      { loopLogger = quietLogger
      , loopEvent = noApplicationEvents
      , loopUpdate = \_ → do
          drain
          finished ← readTVarIO (fixtureBorrowerDone fixture)
          pure (if finished then Finish () else Continue)
      }
  where
    drain =
      atomically (tryReadTQueue (fixtureRequests fixture)) >>= \case
        Nothing → pure ()
        Just request → perform fixture vulkan request >> drain

-- | Run one operation on this thread, checking first that it is the one that
-- entered the session.
perform ∷ Fixture → VulkanHost () → Request → IO ()
perform fixture vulkan request = do
  gone ← readTVarIO (requestAbandoned request)
  if gone
    then requestDecline request (toException Finished)
    else do
      here ← myThreadId
      bound ← isCurrentThreadBound
      os ← osThread
      let passed = here == fixtureMainThread fixture && bound && os == fixtureMainOs fixture
      atomicModifyIORef' (fixtureChecks fixture) (\checks → (ThreadCheck "a dispatched operation" passed : checks, ()))
      if passed
        then requestPerform request vulkan
        else requestDecline request (toException (userError "a dispatched operation ran off the session's main thread"))

-- | Answer everything still queued once the session has gone.
declineQueued ∷ Fixture → IO ()
declineQueued fixture =
  atomically (tryReadTQueue (fixtureRequests fixture)) >>= \case
    Nothing → pure ()
    Just request → requestDecline request (toException Finished) >> declineQueued fixture

-- | Run an operation on the process main thread, against the shared session,
-- and return its result or rethrow its failure here. The first one acquires
-- the session.
onMain ∷ Fixture → (VulkanHost () → IO a) → IO a
onMain fixture action = do
  _ ← admit (fixtureGate fixture)
  reply ← newEmptyTMVarIO
  abandoned ← newTVarIO False
  let request =
        Request
          { requestAbandoned = abandoned
          , requestPerform = \vulkan → do
              outcome ← tryJust synchronous (action vulkan)
              atomically (void (tryPutTMVar reply outcome))
          , requestDecline = \reason → atomically (void (tryPutTMVar reply (Left reason)))
          }
  outcome ←
    mask $ \restore → do
      atomically (writeTQueue (fixtureRequests fixture) request)
      restore (atomically (takeTMVar reply `orElse` (Left <$> readTMVar (fixtureEnded fixture))))
        `onException` atomically (writeTVar abandoned True)
  either throwIO pure outcome
  where
    synchronous failure = case fromException failure of
      Just (_ ∷ SomeAsyncException) → Nothing
      Nothing → Just failure

-- | The shared session, acquiring it if no example has yet.
sharedHost ∷ Fixture → IO (VulkanHost ())
sharedHost fixture = onMain fixture pure

-- | Every native call the session has made so far, in the order they returned.
nativeCalls ∷ Fixture → IO [NativeCall]
nativeCalls = fmap reverse . readIORef . fixtureCalls

mainOsThread ∷ Fixture → Word64
mainOsThread = fixtureMainOs

-- | Create a hidden window through the host's command port, from the calling
-- thread, while the main thread turns the loop that executes it.
createWindow ∷ Fixture → Text → IO WindowId
createWindow fixture name = do
  vulkan ← sharedHost fixture
  awaitSubmitWindowCommand (hostCommandPort (vulkanWindowHost vulkan)) [("client", "vulkan-native-tests")] (createWindowCommand (hiddenTestWindowConfig name 160 120)) >>= \case
    WaitClosed → throwIO (userError "the host's command port closed before the creation was admitted")
    WaitAccepted ticket → do
      settled ← awaitWithin 10 ("the creation of " <> name) (pollCompletion ticket)
      atomically (pollWindowClient ticket) >>= \case
        Just client → pure (clientWindow client)
        Nothing → throwIO (userError ("the creation of " <> Text.unpack name <> " settled without a window: " <> show settled))

-- | Submit a control command for a window through the host's command port,
-- from the calling thread, and wait until the main thread's loop has executed
-- it.
commandWindow ∷ Fixture → Text → WindowCommand → IO ()
commandWindow fixture what command = do
  vulkan ← sharedHost fixture
  awaitSubmitWindowCommand (hostCommandPort (vulkanWindowHost vulkan)) [("client", "vulkan-native-tests")] command >>= \case
    WaitClosed → throwIO (userError ("the host's command port closed before " <> Text.unpack what <> " was admitted"))
    WaitAccepted ticket → void (awaitWithin 10 what (pollCompletion ticket))

-- | The window's latest observation, as its client reads it.
readObservation ∷ Fixture → WindowId → IO WindowObservation
readObservation fixture window = do
  vulkan ← sharedHost fixture
  atomically (hostWindowClient (vulkanWindowHost vulkan) window) >>= \case
    Nothing → throwIO (userError "the window has no client")
    Just client → preparedValue . observedValue <$> atomically (readSnapshot (clientObservations client))

-- | Publish the window's latest observation for its target to the graphics
-- owner, on the main thread, with the eligibility the main thread classifies
-- it as, as an application that drives its own loop does: the fixture's loop
-- is the unscheduled owner loop, which publishes nothing, whereas
-- 'runVulkanOwnerLoop' would publish it every turn. The attachment's revisions
-- start after the slot's initial zero and rise with the window's own.
publishObservation ∷ Fixture → GraphicsService → WindowId → IO ObservationPublication
publishObservation fixture service window = do
  observation ← readObservation fixture window
  onMain fixture $ \vulkan →
    publishGraphicsObservation
      (vulkanGraphicsOwner vulkan)
      service
      (observedRevision observation + 1)
      observation
      (windowRenderEligibility observation)
      Nothing

-- | Close a window on the main thread and wait until the host no longer holds
-- it — its attachment retired, its surface destroyed on the owner's thread and
-- the window released.
closeWindow ∷ Fixture → WindowId → IO ()
closeWindow fixture window = do
  started ← onMain fixture (\vulkan → closeHostWindow (vulkanWindowHost vulkan) window)
  unless (started `elem` [CloseStarted, CloseAlreadyStarted]) $
    throwIO (userError ("closing a window answered " <> show started))
  vulkan ← sharedHost fixture
  void $
    awaitWithin 10 "the window's release" $ do
      held ← hostWindowIdentities (vulkanWindowHost vulkan)
      pure (if window `elem` held then Nothing else Just ())

-- | Wait for a transaction to answer, failing after the given seconds rather
-- than waiting forever on a session that stopped progressing.
awaitWithin ∷ Double → Text → STM (Maybe a) → IO a
awaitWithin seconds what transaction = do
  expired ← registerDelay (round (seconds * 1000000))
  atomically ((transaction >>= maybe retry (pure . Just)) `orElse` (Nothing <$ (readTVar expired >>= check)))
    >>= maybe (throwIO (userError (Text.unpack what <> " did not happen within " <> show seconds <> " seconds"))) pure

-- | A logger that keeps every delivered record, for a report whose verdict is
-- not clean.
collectingLogger ∷ IORef [LogEntry] → Logger
collectingLogger entries =
  mkLogger
    LogFilter
      { filterEnabled = True
      , filterGlobalLevel = Info
      , filterComponentLevels = Map.empty
      , filterDebug = DebugAll
      , filterSource = False
      }
    (callbackSink (\entry → atomicModifyIORef' entries (\kept → (entry : kept, ()))))

quietLogger ∷ Logger
quietLogger =
  mkLogger
    LogFilter
      { filterEnabled = True
      , filterGlobalLevel = Info
      , filterComponentLevels = Map.empty
      , filterDebug = DebugAll
      , filterSource = False
      }
    (callbackSink (\_ → pure ()))
