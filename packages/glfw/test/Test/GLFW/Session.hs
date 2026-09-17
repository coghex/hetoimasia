-- | Examples for the GLFW session model, driven through the private test seam.
--
-- Every example enters a session over "Hetoimasia.GLFW.Seam"'s scripted native
-- library, which initializes nothing: the thread checks, exclusivity, error
-- attribution, rollback, and poisoning under test are the production model's.
-- Each example asserts on the ordered 'NativeCall's the seam recorded, so a
-- rejection is shown to have happened before any native call, and no example
-- ever reaches GLFW itself.
--
-- The process main thread is scripted: 'asProcessMainThread' runs an action in
-- a bound thread the seam treats as the main thread. Worker threads are
-- 'forkOS' and 'forkIO' threads the seam does not. Threads are coordinated with
-- 'MVar's, never with a sleep; 'boundedExample' only stops an example that has
-- already hung.
module Test.GLFW.Session (spec) where

import Control.Concurrent (ThreadId, forkIO, forkOS, isCurrentThreadBound)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( ErrorCall (ErrorCall)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , displayException
  , fromException
  , throwIO
  , try
  )
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , failureEvidence
  , failureEvidenceInContext
  , operationText
  )
import Hetoimasia.Foundation.Log (componentText)
import Hetoimasia.Foundation.Resource
  ( cleanupFailureException
  , cleanupFailureLabel
  , cleanupFailures
  , withScoped
  )
import Hetoimasia.GLFW.Seam
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window (hiddenTestWindowConfig, withWindow)
import System.Timeout (timeout)
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldReturn
  )

spec ∷ Spec
spec = do
  describe "GLFW session entry" $ do
    it "enters and ends a session in its declared order, then enters again after the complete teardown"
      (boundedExample testEnterTwice)
    it "rejects a bound worker thread that is not the process main thread before any native call"
      (boundedExample testBoundWorkerRejected)
    it "rejects an unbound thread even when it runs as the process main thread"
      (boundedExample testUnboundThreadRejected)
    it "rejects a nested entry from the owner thread before any further native call"
      (boundedExample testNestedEntryRejected)
    it "rejects a concurrent entry from another main-thread candidate while a session is active"
      (boundedExample testConcurrentEntryRejected)
    it "answers a Wayland request, or a Wayland-only platform, as unsupported before any native call"
      (boundedExample testWaylandUnsupported)
    it "answers another platform's backend, or one the library reports unavailable, as unsupported"
      (boundedExample testOtherBackendsUnsupported)

  describe "GLFW session construction rollback" $ do
    it "rolls back a failed initialization without terminating, keeping its reports as evidence"
      (boundedExample testInitializationFailureRollsBack)
    it "terminates an initialization that returned but reported an error, before raising it"
      (boundedExample testInitializationReportTerminates)
    it "terminates when the initialized platform is not the selected backend"
      (boundedExample testBackendMismatchTerminates)
    it "keeps a rolled-back failure primary beside a failing rollback, and poisons the guard"
      (boundedExample testRollbackFailurePoisons)

  describe "GLFW native error evidence" $ do
    it "keeps the first reports up to capacity, counts the rest, and still fails a call that returned"
      (boundedExample testOwnerReportsSaturate)
    it "copies a bounded description, records truncation, and decodes invalid UTF-8 leniently"
      (boundedExample testDescriptionsBounded)
    it "does not attribute a report made on another thread during an owner call to that call"
      (boundedExample testOffOwnerReportUnattributed)
    it "bounds asynchronous reports the same way"
      (boundedExample testAsynchronousReportsSaturate)
    it "retains asynchronous reports nobody read as cleanup evidence, without poisoning"
      (boundedExample testUnreadReportsRetained)
    it "contains a failure inside the callback instead of unwinding into the native caller"
      (boundedExample testCallbackFaultContained)

  describe "GLFW session teardown" $ do
    it "keeps a failing body primary beside release-time native errors, then refuses entry once poisoned"
      (boundedExample testBodyFailureWithUnsafeTeardown)
    it "retains a release-time native error without poisoning when every teardown step returned"
      (boundedExample testReleaseErrorWithoutPoison)

  describe "GLFW owner-only operations" $ do
    it "rejects use from another thread and after the session ended, before any native call"
      (boundedExample testOwnerOnlyOperations)

-- ---------------------------------------------------------------------------
-- Entry

testEnterTwice ∷ Expectation
testEnterTwice = do
  seam ← newSeam defaultScript
  backends ← asProcessMainThread seam $ do
    first ← entered seam defaultSessionConfig (pure . sessionBackend)
    second ← entered seam defaultSessionConfig (pure . sessionBackend)
    pure [first, second]
  backends `shouldBe` [X11, X11]
  seamCalls seam `shouldReturn` concat [entryCalls, exitCalls, entryCalls, exitCalls]
  seamLiveCallbacks seam `shouldReturn` 0

testBoundWorkerRejected ∷ Expectation
testBoundWorkerRejected = do
  seam ← newSeam defaultScript
  (bound, (misuse, caught)) ← onThread forkOS $ do
    bound ← isCurrentThreadBound
    rejected ← caughtAs (entered seam defaultSessionConfig (\_ → pure ()))
    pure (bound, rejected)
  bound `shouldBe` True
  misuse `shouldBe` NotProcessMainThread
  originOf caught `shouldBe` Just ("glfw", "enter session", x11)
  seamCalls seam `shouldReturn` []

testUnboundThreadRejected ∷ Expectation
testUnboundThreadRejected = do
  seam ← newSeam defaultScript
  (bound, (misuse, _)) ← onThread forkIO $ do
    designateProcessMainThread seam
    bound ← isCurrentThreadBound
    rejected ← caughtAs (entered seam defaultSessionConfig (\_ → pure ()))
    pure (bound, rejected)
  bound `shouldBe` False
  misuse `shouldBe` NotProcessMainThread
  seamCalls seam `shouldReturn` []

testNestedEntryRejected ∷ Expectation
testNestedEntryRejected = do
  seam ← newSeam defaultScript
  misuse ← asProcessMainThread seam $ entered seam defaultSessionConfig $ \_ →
    fst <$> caughtAs (entered seam defaultSessionConfig (\_ → pure ()))
  misuse `shouldBe` SessionAlreadyActive
  seamCalls seam `shouldReturn` entryCalls <> exitCalls

testConcurrentEntryRejected ∷ Expectation
testConcurrentEntryRejected = do
  seam ← newSeam defaultScript
  misuse ← asProcessMainThread seam $ entered seam defaultSessionConfig $ \_ →
    onThread forkOS $ do
      designateProcessMainThread seam
      fst <$> caughtAs (entered seam defaultSessionConfig (\_ → pure ()))
  misuse `shouldBe` SessionAlreadyActive
  seamCalls seam `shouldReturn` entryCalls <> exitCalls

testWaylandUnsupported ∷ Expectation
testWaylandUnsupported = do
  seam ← newSeam defaultScript
  (unsupported, caught) ←
    asProcessMainThread seam (caughtAs (entered seam (SessionConfig (Just Wayland)) (\_ → pure ())))
  unsupported `shouldBe` UnsupportedBackend (Just Wayland) (Just X11)
  originOf caught `shouldBe` Just ("glfw", "enter session", [("backend", "wayland")])
  seamCalls seam `shouldReturn` []

  waylandOnly ← newSeam defaultScript {scriptHostBackend = Just Wayland}
  (fallback, _) ←
    asProcessMainThread waylandOnly (caughtAs (entered waylandOnly defaultSessionConfig (\_ → pure ())))
  fallback `shouldBe` UnsupportedBackend Nothing (Just Wayland)
  seamCalls waylandOnly `shouldReturn` []

testOtherBackendsUnsupported ∷ Expectation
testOtherBackendsUnsupported = do
  seam ← newSeam defaultScript
  (other, _) ← asProcessMainThread seam (caughtAs (entered seam (SessionConfig (Just Cocoa)) (\_ → pure ())))
  other `shouldBe` UnsupportedBackend (Just Cocoa) (Just X11)
  seamCalls seam `shouldReturn` []

  unavailable ← newSeam defaultScript {scriptPlatformSupported = False}
  refusals ← asProcessMainThread unavailable $ do
    (first, _) ← caughtAs (entered unavailable defaultSessionConfig (\_ → pure ()))
    (second, _) ← caughtAs (entered unavailable defaultSessionConfig (\_ → pure ()))
    pure [first, second]
  -- The second refusal is the same answer, not SessionAlreadyActive: the
  -- first released the guard it had claimed.
  refusals `shouldBe` replicate 2 (UnsupportedBackend (Just X11) (Just X11))
  seamCalls unavailable `shouldReturn` replicate 2 (QueryPlatformSupported X11)

-- ---------------------------------------------------------------------------
-- Construction rollback

testInitializationFailureRollsBack ∷ Expectation
testInitializationFailureRollsBack = do
  firstAttempt ← firstTimeOnly
  seam ←
    newSeam
      defaultScript
        { scriptInitialize = \reporter → do
            failing ← firstAttempt
            if failing
              then do
                reportError reporter 0x00010008 "X11: The DISPLAY environment variable is missing"
                pure False
              else pure True
        }
  (failure, caught) ← asProcessMainThread seam (caughtAs (entered seam defaultSessionConfig (\_ → pure ())))
  nativeOutcome failure `shouldBe` NativeCallFailed
  map errorSummary (reportedErrors (nativeReports failure))
    `shouldBe` [(0x00010008, "X11: The DISPLAY environment variable is missing", False, ProcessMainThread)]
  originOf caught `shouldBe` Just ("glfw", "initialize", x11)
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` []
  seamCalls seam
    `shouldReturn` [ QueryPlatformSupported X11
                   , CreateErrorCallback
                   , AttachErrorCallback
                   , SetInitHints X11
                   , Initialize
                   , DetachErrorCallback
                   , FreeErrorCallback
                   ]
  seamLiveCallbacks seam `shouldReturn` 0
  asProcessMainThread seam (entered seam defaultSessionConfig (pure . sessionBackend)) `shouldReturn` X11

testInitializationReportTerminates ∷ Expectation
testInitializationReportTerminates = do
  seam ←
    newSeam defaultScript {scriptInitialize = \reporter → reportError reporter 0x00010008 "X11: warned" >> pure True}
  (failure, caught) ← asProcessMainThread seam (caughtAs (entered seam defaultSessionConfig (\_ → pure ())))
  nativeOutcome failure `shouldBe` NativeCallReturned
  originOf caught `shouldBe` Just ("glfw", "initialize", x11)
  seamCalls seam
    `shouldReturn` [ QueryPlatformSupported X11
                   , CreateErrorCallback
                   , AttachErrorCallback
                   , SetInitHints X11
                   , Initialize
                   ]
      <> initializationExitCalls
  seamLiveCallbacks seam `shouldReturn` 0

testBackendMismatchTerminates ∷ Expectation
testBackendMismatchTerminates = do
  seam ← newSeam defaultScript {scriptReportedPlatform = const (Just Wayland)}
  (mismatch, caught) ← asProcessMainThread seam (caughtAs (entered seam defaultSessionConfig (\_ → pure ())))
  mismatch `shouldBe` BackendNotSelected X11 (Just Wayland)
  originOf caught `shouldBe` Just ("glfw", "verify backend", x11)
  seamCalls seam `shouldReturn` initializationCalls <> initializationExitCalls

testRollbackFailurePoisons ∷ Expectation
testRollbackFailurePoisons = do
  seam ←
    newSeam
      defaultScript
        { scriptInitialize = \reporter → reportError reporter 0x00010008 "failed" >> pure False
        , scriptDetachErrorCallback = \_ → throwIO (userError "detach failed")
        }
  (failure, caught) ← asProcessMainThread seam (caughtAs (entered seam defaultSessionConfig (\_ → pure ())))
  nativeOutcome failure `shouldBe` NativeCallFailed
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` ["glfw error callback"]
  let attempted =
        [ QueryPlatformSupported X11
        , CreateErrorCallback
        , AttachErrorCallback
        , SetInitHints X11
        , Initialize
        , DetachErrorCallback
        ]
  seamCalls seam `shouldReturn` attempted
  -- Detaching raised, so the callback's storage is kept rather than freed.
  seamLiveCallbacks seam `shouldReturn` 1
  (poisoned, _) ← asProcessMainThread seam (caughtAs (entered seam defaultSessionConfig (\_ → pure ())))
  poisoned `shouldBe` SessionPoisoned
  seamCalls seam `shouldReturn` attempted

-- ---------------------------------------------------------------------------
-- Error evidence

testOwnerReportsSaturate ∷ Expectation
testOwnerReportsSaturate = do
  let codes = [0x00010100 + code | code ← [1 .. errorEvidenceCapacity + 3]]
  seam ←
    newSeam
      defaultScript
        { scriptInitialize = \reporter → do
            mapM_ (\code → reportError reporter code "reported") codes
            pure True
        }
  (failure, _) ← asProcessMainThread seam (caughtAs (entered seam defaultSessionConfig (\_ → pure ())))
  nativeOutcome failure `shouldBe` NativeCallReturned
  map nativeErrorCode (reportedErrors (nativeReports failure)) `shouldBe` take errorEvidenceCapacity codes
  reportsLost (nativeReports failure) `shouldBe` 3
  callbackFaults (nativeReports failure) `shouldBe` 0

testDescriptionsBounded ∷ Expectation
testDescriptionsBounded = do
  let long = Char8.replicate (errorDescriptionLimit + 10) 'a'
      exact = Char8.replicate errorDescriptionLimit 'b'
      invalid = ByteString.pack [0x58, 0xff, 0x59]
  seam ←
    newSeam
      defaultScript
        { scriptInitialize = \reporter → do
            reportError reporter 1 long
            reportError reporter 2 exact
            reportError reporter 3 invalid
            pure False
        }
  (failure, _) ← asProcessMainThread seam (caughtAs (entered seam defaultSessionConfig (\_ → pure ())))
  map errorSummary (reportedErrors (nativeReports failure))
    `shouldBe` [ (1, Text.replicate errorDescriptionLimit "a", True, ProcessMainThread)
               , (2, Text.replicate errorDescriptionLimit "b", False, ProcessMainThread)
               , (3, "X\xFFFDY", False, ProcessMainThread)
               ]

testOffOwnerReportUnattributed ∷ Expectation
testOffOwnerReportUnattributed = do
  seam ←
    newSeam
      defaultScript
        { scriptInitialize = \reporter → do
            reportErrorFromOtherThread reporter 0x00010005 "reported elsewhere"
            pure True
        }
  (backend, first, second) ← asProcessMainThread seam $ entered seam defaultSessionConfig $ \session → do
    first ← takeAsynchronousReports session
    second ← takeAsynchronousReports session
    pure (sessionBackend session, first, second)
  backend `shouldBe` X11
  first `shouldBe` Reports [NativeError 0x00010005 "reported elsewhere" False OtherThread] 0 0
  second `shouldBe` Reports [] 0 0
  seamCalls seam `shouldReturn` entryCalls <> exitCalls

testAsynchronousReportsSaturate ∷ Expectation
testAsynchronousReportsSaturate = do
  seam ←
    newSeam
      defaultScript
        { scriptInitialize = \reporter → do
            mapM_ (\code → reportErrorFromOtherThread reporter code "elsewhere") [1 .. errorEvidenceCapacity + 2]
            pure True
        }
  reports ← asProcessMainThread seam (entered seam defaultSessionConfig takeAsynchronousReports)
  map nativeErrorCode (reportedErrors reports) `shouldBe` [1 .. errorEvidenceCapacity]
  reportsLost reports `shouldBe` 2

testUnreadReportsRetained ∷ Expectation
testUnreadReportsRetained = do
  firstAttempt ← firstTimeOnly
  seam ←
    newSeam
      defaultScript
        { scriptInitialize = \reporter → do
            reporting ← firstAttempt
            if reporting then reportErrorFromOtherThread reporter 0x00010005 "never read" else pure ()
            pure True
        }
  (AsynchronousErrorsUnobserved unread, caught) ←
    asProcessMainThread seam (caughtAs (entered seam defaultSessionConfig (\_ → pure (5 ∷ Int))))
  unread `shouldBe` Reports [NativeError 0x00010005 "never read" False OtherThread] 0 0
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` ["glfw error callback"]
  originOf caught `shouldBe` Just ("glfw", "detach error callback", [])
  seamCalls seam `shouldReturn` entryCalls <> exitCalls
  asProcessMainThread seam (entered seam defaultSessionConfig (pure . sessionBackend)) `shouldReturn` X11

testCallbackFaultContained ∷ Expectation
testCallbackFaultContained = do
  seam ←
    newSeam
      defaultScript
        { scriptInitialize = \reporter → do
            -- This returns only if nothing escaped the callback.
            reportErrorWithFailingIdentity reporter 0x00010001 "unidentified"
            pure True
        }
  reports ← asProcessMainThread seam (entered seam defaultSessionConfig takeAsynchronousReports)
  reports `shouldBe` Reports [] 0 1

-- ---------------------------------------------------------------------------
-- Teardown

testBodyFailureWithUnsafeTeardown ∷ Expectation
testBodyFailureWithUnsafeTeardown = do
  seam ←
    newSeam
      defaultScript
        { scriptTerminate = \reporter → reportError reporter 0x00010008 "terminate reported"
        , scriptDetachErrorCallback = \_ → throwIO (userError "detach failed")
        }
  (primary, caught) ←
    asProcessMainThread seam $
      caughtAs (entered seam defaultSessionConfig (\_ → throwIO (ErrorCall "body failed") ∷ IO ()))
  primary `shouldBe` ErrorCall "body failed"
  let retained = cleanupFailures caught
  map cleanupFailureLabel retained `shouldBe` ["glfw terminate", "glfw error callback"]
  case retained of
    terminateFailure : _ → case cleanupFailureException terminateFailure of
      ExceptionWithContext context exception → do
        (nativeReports <$> fromException exception)
          `shouldBe` Just (Reports [NativeError 0x00010008 "terminate reported" False ProcessMainThread] 0 0)
        originIn (failureEvidenceInContext context) `shouldBe` Just ("glfw", "terminate", x11)
    [] → expectationFailure "no cleanup evidence was retained"
  let attempted = entryCalls <> [DetachMonitorCallback, Terminate, DetachErrorCallback]
  seamCalls seam `shouldReturn` attempted
  seamLiveCallbacks seam `shouldReturn` 1
  (poisoned, _) ← asProcessMainThread seam (caughtAs (entered seam defaultSessionConfig (\_ → pure ())))
  poisoned `shouldBe` SessionPoisoned
  seamCalls seam `shouldReturn` attempted

testReleaseErrorWithoutPoison ∷ Expectation
testReleaseErrorWithoutPoison = do
  firstAttempt ← firstTimeOnly
  seam ←
    newSeam
      defaultScript
        { scriptTerminate = \reporter → do
            reporting ← firstAttempt
            if reporting then reportError reporter 0x00010008 "terminate reported" else pure ()
        }
  (failure, caught) ← asProcessMainThread seam (caughtAs (entered seam defaultSessionConfig (\_ → pure ())))
  failure
    `shouldBe` NativeFailure
      NativeCallReturned
      (Reports [NativeError 0x00010008 "terminate reported" False ProcessMainThread] 0 0)
  originOf caught `shouldBe` Just ("glfw", "terminate", x11)
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` ["glfw terminate"]
  asProcessMainThread seam (entered seam defaultSessionConfig (pure . sessionBackend)) `shouldReturn` X11
  seamCalls seam `shouldReturn` concat [entryCalls, exitCalls, entryCalls, exitCalls]

-- ---------------------------------------------------------------------------
-- Owner-only operations

testOwnerOnlyOperations ∷ Expectation
testOwnerOnlyOperations = do
  seam ← newSeam defaultScript
  let config = hiddenTestWindowConfig "elsewhere" 64 48
  (reportsElsewhere, windowElsewhere, afterEnd) ← asProcessMainThread seam $ do
    (reportsElsewhere, windowElsewhere, session) ← entered seam defaultSessionConfig $ \session → do
      reportsElsewhere ← onThread forkOS (fst <$> caughtAs (takeAsynchronousReports session))
      windowElsewhere ← onThread forkOS (fst <$> caughtAs (withWindow session config (\_ → pure ())))
      pure (reportsElsewhere, windowElsewhere, session)
    -- Deliberate misuse: the session escaped its scope to prove it is refused.
    (afterEnd, _) ← caughtAs (takeAsynchronousReports session)
    pure (reportsElsewhere, windowElsewhere, afterEnd)
  reportsElsewhere `shouldBe` NotSessionOwner
  windowElsewhere `shouldBe` NotSessionOwner
  afterEnd `shouldBe` SessionEnded
  seamCalls seam `shouldReturn` entryCalls <> exitCalls

-- ---------------------------------------------------------------------------
-- Support

entered ∷ Seam → SessionConfig → (Session → IO r) → IO r
entered seam config = withScoped (seamSession seam config)

-- | The native calls of a successful entry on the default script's platform,
-- which has no monitor.
entryCalls ∷ [NativeCall]
entryCalls = initializationCalls <> [CreateMonitorCallback, AttachMonitorCallback, QueryMonitors, QueryPrimaryMonitor]

-- | The native calls of entry through the verified backend, before the monitor
-- inventory's stages.
initializationCalls ∷ [NativeCall]
initializationCalls =
  [ QueryPlatformSupported X11
  , CreateErrorCallback
  , AttachErrorCallback
  , SetInitHints X11
  , Initialize
  , QueryPlatform
  ]

-- | The native calls of a complete, safe teardown.
exitCalls ∷ [NativeCall]
exitCalls = [DetachMonitorCallback, Terminate, DetachErrorCallback, FreeErrorCallback, FreeMonitorCallback]

-- | The native calls of a safe teardown of a session whose entry failed before
-- the monitor inventory's stages.
initializationExitCalls ∷ [NativeCall]
initializationExitCalls = [Terminate, DetachErrorCallback, FreeErrorCallback]

x11 ∷ [(Text, Text)]
x11 = [("backend", "x11")]

errorSummary ∷ NativeError → (Int, Text, Bool, ReportingThread)
errorSummary entry =
  (nativeErrorCode entry, nativeErrorDescription entry, nativeErrorTruncated entry, nativeErrorThread entry)

-- | An action answering 'True' the first time it runs and 'False' after.
firstTimeOnly ∷ IO (IO Bool)
firstTimeOnly = do
  flag ← newIORef True
  pure (atomicModifyIORef' flag (\first → (False, first)))

-- | Run an action on a new thread and wait for its outcome.
onThread ∷ (IO () → IO ThreadId) → IO a → IO a
onThread fork action = do
  finished ← newEmptyMVar
  _ ← fork (try action >>= putMVar finished)
  outcome ← takeMVar finished
  either (throwIO ∷ SomeException → IO a) pure outcome

-- | The typed failure an action raised, beside the exception as caught.
caughtAs ∷ Exception e ⇒ IO a → IO (e, SomeException)
caughtAs action = do
  outcome ← try action
  case outcome of
    Right _ → unexpected "the action returned instead of failing"
    Left caught → case fromException caught of
      Just typed → pure (typed, caught)
      Nothing → unexpected ("the action failed with " <> displayException caught)

unexpected ∷ String → IO a
unexpected message = expectationFailure message >> ioError (userError message)

originOf ∷ SomeException → Maybe (Text, Text, [(Text, Text)])
originOf = originIn . failureEvidence

originIn ∷ FailureEvidence → Maybe (Text, Text, [(Text, Text)])
originIn evidence = case failureCause evidence of
  EngineOrigin origin →
    Just
      ( componentText (originComponent origin)
      , operationText (originOperation origin)
      , originIdentifiers origin
      )
  NativeCause → Nothing

boundedExample ∷ Expectation → Expectation
boundedExample action = do
  finished ← timeout (30 * 1000 * 1000) action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"
