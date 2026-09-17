-- | Examples for the session's wake capability, driven through the private test
-- seam.
--
-- Every example enters a session over "Hetoimasia.GLFW.Seam"'s scripted native
-- library, so the admission, attribution, and lifetime protocol under test are
-- the production model's, and no example reaches GLFW. The scripted platform
-- models an empty-event post as a pending count and a finite wait as a wait for
-- that count, so an example can wake the owner before, during, and after its
-- wait.
--
-- Threads are coordinated with 'MVar's, STM, and the runtime's own report of
-- what a thread is blocked on, never with a sleep; 'boundedExample' only stops
-- an example that has already hung.
module Test.GLFW.Wake (spec) where

import Control.Concurrent (ThreadId, forkIO, forkOS, killThread, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , SomeException
  , displayException
  , finally
  , fromException
  , mask_
  , throwIO
  , try
  )
import Control.Monad (forM, void, when)
import qualified Data.ByteString.Char8 as Char8
import Data.Either (isLeft)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Text as Text
import GHC.Conc (BlockReason (..), ThreadStatus (..), threadStatus)
import Hetoimasia.Foundation.Failure (FailureCause (..), FailureEvidence (..), FailureOrigin (..), failureEvidence, operationText)
import Hetoimasia.Foundation.Log (componentText)
import Hetoimasia.Foundation.Resource (withScoped)
import Hetoimasia.GLFW.Internal.Window (EventProcessing (..), processWindowEvents)
import Hetoimasia.GLFW.Seam
import Hetoimasia.GLFW.Session
import System.Timeout (timeout)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = do
  describe "GLFW session wake" $ do
    it "wakes the owner before, during, and after its wait, from unbound, bound, and owner threads"
      (boundedExample testWakeAroundWait)
    it "answers a platform failure reported during the post as that call's expected failure, without retrying"
      (boundedExample testPlatformFailure)
    it "raises a programming or lifetime error reported during the post, alone or beside a platform failure, as an attributed failure"
      (boundedExample testUnexpectedErrorRaised)

  describe "GLFW session wake error attribution" $ do
    it "attributes each of two overlapping wakes its own report, apart from a concurrent owner operation's and an unrelated asynchronous report"
      (boundedExample testOverlappingAttribution)
    it "bounds one wake's reports as the capture does, raises lost or faulted evidence, and leaves nothing for later reads or teardown"
      (boundedExample testWakeEvidenceBounded)
    it "raises a wake whose report could not be attributed, from the error the call left behind"
      (boundedExample testUnattributableReport)

  describe "GLFW session wake lifetime" $ do
    it "lets a wake admitted before close finish before termination, and answers wakes during the drain as terminal"
      (boundedExample testAdmittedWakeDrainsBeforeTerminate)
    it "never enters GLFW for a wake racing or following the start of close"
      (boundedExample testWakesRacingClose)
    it "keeps a retained capability terminal after close and against a later session"
      (boundedExample testRetainedCapability)
    it "never lends a capability when construction rolls back"
      (boundedExample testRollbackNeverLends)

  describe "GLFW session wake cancellation" $ do
    it "settles a waker cancelled inside its native call, leaving none of its reports behind"
      (boundedExample testCancelledInsideCall)
    it "settles a wake that completes with a cancellation pending, which stays observable"
      (boundedExample testCancellationPendingAtCompletion)
    it "drains an admitted wake before termination when the owner is cancelled during close, without poisoning"
      (boundedExample testOwnerCancelledDuringDrain)

-- ---------------------------------------------------------------------------
-- Waking

testWakeAroundWait ∷ Expectation
testWakeAroundWait = do
  platform ← newPlatform
  seam ← newSeam (platformScript platform defaultScript)
  (outcomes, retained) ← asProcessMainThread seam $ entered seam $ \session → do
    let wake = sessionWake session
    before ← onThread forkIO (wakeSession wake)
    -- The pending post ends this wait at once.
    processWindowEvents session (AwaitEventsFor 1)
    during ← newEmptyMVar
    _ ← forkIO $ do
      atomically (readTVar (platformWaiting platform) >>= check)
      try (wakeSession wake) >>= putMVar during
    processWindowEvents session (AwaitEventsFor 1)
    duringOutcome ← takeMVar during >>= either (throwIO ∷ SomeException → IO a) pure
    fromOwner ← wakeSession wake
    fromBound ← onThread forkOS (wakeSession wake)
    pure ([before, duringOutcome, fromOwner, fromBound], wake)
  outcomes `shouldBe` replicate 4 WakePosted
  wakeSession retained `shouldReturn` WakeTerminal
  seamCalls seam
    `shouldReturn` entryCalls
      <> [PostEmptyEvent, WaitEvents 1, WaitEvents 1, PostEmptyEvent, PostEmptyEvent, PostEmptyEvent]
      <> exitCalls

testPlatformFailure ∷ Expectation
testPlatformFailure = do
  seam ←
    newSeam
      defaultScript
        { scriptPostEmptyEvent = \reporter →
            reportError reporter 0x00010008 "X11: Failed to write to the empty event pipe"
        }
  (fromWorker, fromOwner, asynchronous) ← asProcessMainThread seam $ entered seam $ \session → do
    let wake = sessionWake session
    fromWorker ← onThread forkIO (wakeSession wake)
    fromOwner ← wakeSession wake
    asynchronous ← takeAsynchronousReports session
    pure (fromWorker, fromOwner, asynchronous)
  fromWorker `shouldBe` WakeFailed (Reports [NativeError 0x00010008 "X11: Failed to write to the empty event pipe" False OtherThread] 0 0)
  fromOwner `shouldBe` WakeFailed (Reports [NativeError 0x00010008 "X11: Failed to write to the empty event pipe" False ProcessMainThread] 0 0)
  asynchronous `shouldBe` Reports [] 0 0
  -- One post per call: a failed wake is not retried.
  seamCalls seam `shouldReturn` entryCalls <> [PostEmptyEvent, PostEmptyEvent] <> exitCalls

testUnexpectedErrorRaised ∷ Expectation
testUnexpectedErrorRaised = do
  step ← newIORef (0 ∷ Int)
  seam ←
    newSeam
      defaultScript
        { scriptPostEmptyEvent = \reporter → do
            call ← atomicModifyIORef' step (\next → (next + 1, next))
            case call of
              0 → reportError reporter notInitialized "The GLFW library is not initialized"
              1 → do
                reportError reporter platformErrorCode "platform"
                reportError reporter notInitialized "not initialized"
              _ → pure ()
        }
  (alone, beside, afterwards, asynchronous) ← asProcessMainThread seam $ entered seam $ \session → do
    let wake = sessionWake session
    alone ← onThread forkIO (caughtWakeFailure (wakeSession wake))
    beside ← onThread forkIO (caughtWakeFailure (wakeSession wake))
    -- Both calls left, so the gate still admits and close will not wait.
    afterwards ← onThread forkIO (wakeSession wake)
    asynchronous ← takeAsynchronousReports session
    pure (alone, beside, afterwards, asynchronous)
  fst alone
    `shouldBe` NativeFailure NativeCallReturned (Reports [NativeError notInitialized "The GLFW library is not initialized" False OtherThread] 0 0)
  originOf (snd alone) `shouldBe` Just ("glfw", "wake session")
  fst beside
    `shouldBe` NativeFailure
      NativeCallReturned
      (Reports [NativeError platformErrorCode "platform" False OtherThread, NativeError notInitialized "not initialized" False OtherThread] 0 0)
  afterwards `shouldBe` WakePosted
  asynchronous `shouldBe` Reports [] 0 0
  seamCalls seam `shouldReturn` entryCalls <> [PostEmptyEvent, PostEmptyEvent, PostEmptyEvent] <> exitCalls
  where
    notInitialized = 0x00010001

-- ---------------------------------------------------------------------------
-- Attribution

testOverlappingAttribution ∷ Expectation
testOverlappingAttribution = do
  names ← newIORef []
  inside ← newTVarIO (0 ∷ Int)
  opened ← newTVarIO False
  captured ← newEmptyMVar
  seam ←
    newSeam
      defaultScript
        { scriptPostEmptyEvent = \reporter → do
            self ← myThreadId
            name ← fromMaybe "unnamed" . lookup self <$> readIORef names
            reportError reporter platformErrorCode name
            _ ← tryPutMVar captured reporter
            atomically (modifyTVar' inside (+ 1))
            atomically (readTVar opened >>= check)
        , scriptWaitEvents = \_ reporter → reportError reporter 0x00010003 "owner wait"
        }
  (ownerFailure, outcomes, asynchronous) ← asProcessMainThread seam $ entered seam $ \session → do
    let wake = sessionWake session
    results ← forM [(forkIO, "unbound waker"), (forkOS, "bound waker")] $ \(fork, name) → do
      result ← newEmptyMVar
      _ ← fork $ do
        self ← myThreadId
        atomicModifyIORef' names (\known → ((self, name) : known, ()))
        try (wakeSession wake) >>= putMVar result
      pure result
    -- Both wake calls are inside their native calls, and each has reported.
    atomically (readTVar inside >>= check . (== 2))
    reporter ← readMVar captured
    reportErrorFromOtherThread reporter 0x00010005 "unrelated"
    ownerFailure ← expectFailure (processWindowEvents session (AwaitEventsFor 0.5))
    atomically (writeTVar opened True)
    outcomes ← mapM (\result → takeMVar result >>= either (throwIO ∷ SomeException → IO a) pure) results
    asynchronous ← takeAsynchronousReports session
    pure (ownerFailure, outcomes, asynchronous)
  outcomes
    `shouldBe` [ WakeFailed (Reports [NativeError platformErrorCode "unbound waker" False OtherThread] 0 0)
               , WakeFailed (Reports [NativeError platformErrorCode "bound waker" False OtherThread] 0 0)
               ]
  nativeReports ownerFailure `shouldBe` Reports [NativeError 0x00010003 "owner wait" False ProcessMainThread] 0 0
  asynchronous `shouldBe` Reports [NativeError 0x00010005 "unrelated" False OtherThread] 0 0
  -- The session ended without unobserved reports: no wake's report was left
  -- behind to be raised again.
  seamCalls seam `shouldReturn` entryCalls <> [PostEmptyEvent, PostEmptyEvent, WaitEvents 0.5] <> exitCalls

testWakeEvidenceBounded ∷ Expectation
testWakeEvidenceBounded = do
  step ← newIORef (0 ∷ Int)
  let long = Char8.replicate (errorDescriptionLimit + 5) 'w'
      count = errorEvidenceCapacity + 2
  seam ←
    newSeam
      defaultScript
        { scriptPostEmptyEvent = \reporter → do
            call ← atomicModifyIORef' step (\next → (next + 1, next))
            case call of
              0 → mapM_ (\index → reportError reporter platformErrorCode (if index == (1 ∷ Int) then long else "kept")) [1 .. count]
              1 → reportErrorWithFailingIdentity reporter platformErrorCode "unidentified"
              _ → pure ()
        }
  (saturated, faulted, clean, asynchronous) ← asProcessMainThread seam $ entered seam $ \session → do
    let wake = sessionWake session
    saturated ← onThread forkIO (fst <$> caughtWakeFailure (wakeSession wake))
    faulted ← onThread forkIO (fst <$> caughtWakeFailure (wakeSession wake))
    clean ← onThread forkIO (wakeSession wake)
    -- An owner operation claims none of the wakes' reports.
    processWindowEvents session (AwaitEventsFor 0.5)
    asynchronous ← takeAsynchronousReports session
    pure (saturated, faulted, clean, asynchronous)
  -- Every report is the platform error, but lost or faulted evidence cannot be
  -- classified as an expected failure, so both calls raise it.
  let reports = nativeReports saturated
  map nativeErrorCode (reportedErrors reports) `shouldBe` replicate errorEvidenceCapacity platformErrorCode
  map nativeErrorTruncated (reportedErrors reports) `shouldBe` (True : replicate (errorEvidenceCapacity - 1) False)
  map (Text.length . nativeErrorDescription) (take 1 (reportedErrors reports)) `shouldBe` [errorDescriptionLimit]
  reportsLost reports `shouldBe` 2
  callbackFaults reports `shouldBe` 0
  faulted `shouldBe` NativeFailure NativeCallReturned (Reports [] 0 1)
  clean `shouldBe` WakePosted
  asynchronous `shouldBe` Reports [] 0 0
  seamCalls seam `shouldReturn` entryCalls <> [PostEmptyEvent, PostEmptyEvent, PostEmptyEvent, WaitEvents 0.5] <> exitCalls

testUnattributableReport ∷ Expectation
testUnattributableReport = do
  seam ←
    newSeam defaultScript {scriptPostEmptyEvent = \reporter → reportErrorWithFailingWakeMark reporter 0x00010008 "unmarked"}
  (outcome, asynchronous) ← asProcessMainThread seam $ entered seam $ \session →
    (,) <$> onThread forkIO (fst <$> caughtWakeFailure (wakeSession (sessionWake session))) <*> takeAsynchronousReports session
  -- The callback could not tell which call the report belonged to, so it kept
  -- it as an asynchronous fault; the wake still raises, from the error code the
  -- post left in its own thread's error state that no report recorded.
  outcome `shouldBe` NativeFailure NativeCallReturned (Reports [] 0 1)
  asynchronous `shouldBe` Reports [] 0 1

-- ---------------------------------------------------------------------------
-- Lifetime

testAdmittedWakeDrainsBeforeTerminate ∷ Expectation
testAdmittedWakeDrainsBeforeTerminate = do
  platform ← newPlatform
  held ← newHeldPost
  seam ← newSeam (platformScript platform (holdingFirstPost held defaultScript))
  owner ← startOwner seam
  wake ← sessionWake <$> readMVar (ownerSession owner)
  waker ← newEmptyMVar
  _ ← forkIO (try (wakeSession wake) >>= putMVar waker)
  takeMVar (heldEntered held)
  putMVar (ownerRelease owner) ()
  -- The owner has closed the gate and is waiting for the admitted call.
  awaitBlocked (ownerThread owner) (== BlockedOnSTM)
  duringDrain ← wakeSession wake
  callsDuringDrain ← seamCalls seam
  putMVar (heldRelease held) ()
  (takeMVar waker >>= either (throwIO ∷ SomeException → IO a) pure) `shouldReturn` WakePosted
  takeMVar (ownerResult owner) >>= either (\failure → expectationFailure (displayException failure)) pure
  duringDrain `shouldBe` WakeTerminal
  callsDuringDrain `shouldBe` entryCalls <> [PostEmptyEvent]
  readIORef (platformTerminateSaw platform) `shouldReturn` [0]
  seamCalls seam `shouldReturn` entryCalls <> [PostEmptyEvent] <> exitCalls
  asProcessMainThread seam (entered seam (pure . sessionBackend)) `shouldReturn` X11

testWakesRacingClose ∷ Expectation
testWakesRacingClose = do
  platform ← newPlatform
  lent ← newEmptyMVar
  duringTeardown ← newIORef []
  let atTeardown = do
        wake ← readMVar lent
        fromWorker ← onThread forkIO (wakeSession wake)
        fromOwner ← wakeSession wake
        modifyIORef' duringTeardown (<> [fromWorker, fromOwner])
      base =
        defaultScript
          { scriptTerminate = \_ → atTeardown
          , scriptDetachErrorCallback = \_ → atTeardown
          }
  seam ← newSeam (platformScript platform base)
  posted ← newTVarIO (0 ∷ Int)
  hammer ← newEmptyMVar
  asProcessMainThread seam $ entered seam $ \session → do
    let wake = sessionWake session
    putMVar lent wake
    -- A worker wakes until its capability turns terminal, racing the close
    -- that begins once it has posted at least once.
    _ ← forkIO $
      let loop count =
            wakeSession wake >>= \case
              WakePosted → atomically (writeTVar posted (count + 1)) >> loop (count + 1)
              WakeTerminal → pure count
              other → throwIO (userError ("unexpected wake outcome " <> show other))
       in try (loop 0) >>= putMVar hammer
    atomically (readTVar posted >>= check . (>= 1))
  count ← takeMVar hammer >>= either (throwIO ∷ SomeException → IO a) pure
  count `shouldSatisfy` (>= 1)
  readTVarIO posted `shouldReturn` count
  readIORef duringTeardown `shouldReturn` replicate 4 WakeTerminal
  readIORef (platformTerminateSaw platform) `shouldReturn` [0]
  seamCalls seam `shouldReturn` entryCalls <> replicate count PostEmptyEvent <> exitCalls

testRetainedCapability ∷ Expectation
testRetainedCapability = do
  seam ← newSeam defaultScript
  (afterClose, duringLater, fresh) ← asProcessMainThread seam $ do
    stale ← entered seam (pure . sessionWake)
    afterClose ← wakeSession stale
    (duringLater, fresh) ← entered seam $ \session →
      (,) <$> onThread forkIO (wakeSession stale) <*> wakeSession (sessionWake session)
    pure (afterClose, duringLater, fresh)
  afterClose `shouldBe` WakeTerminal
  duringLater `shouldBe` WakeTerminal
  fresh `shouldBe` WakePosted
  seamCalls seam `shouldReturn` concat [entryCalls, exitCalls, entryCalls, [PostEmptyEvent], exitCalls]

testRollbackNeverLends ∷ Expectation
testRollbackNeverLends = do
  seam ← newSeam defaultScript {scriptInitialize = \reporter → reportError reporter 0x00010008 "failed" >> pure False}
  lent ← newIORef False
  outcome ← asProcessMainThread seam $
    try (entered seam (\session → writeIORef lent True >> wakeSession (sessionWake session)))
  isLeft (outcome ∷ Either NativeFailure WakeOutcome) `shouldBe` True
  readIORef lent `shouldReturn` False
  seamCalls seam
    `shouldReturn` [ QueryPlatformSupported X11
                   , CreateErrorCallback
                   , AttachErrorCallback
                   , SetInitHints X11
                   , Initialize
                   , DetachErrorCallback
                   , FreeErrorCallback
                   ]

-- ---------------------------------------------------------------------------
-- Cancellation

testCancelledInsideCall ∷ Expectation
testCancelledInsideCall = do
  platform ← newPlatform
  held ← newHeldPost
  let reporting =
        defaultScript
          { scriptPostEmptyEvent = \reporter → reportError reporter 0x00010008 "reported before cancellation"
          }
  seam ← newSeam (platformScript platform (holdingFirstPost held reporting))
  (cancelled, later, asynchronous) ← asProcessMainThread seam $ entered seam $ \session → do
    let wake = sessionWake session
    result ← newEmptyMVar
    waker ← forkIO (try (wakeSession wake) >>= putMVar result)
    takeMVar (heldEntered held)
    killThread waker
    cancelled ← takeMVar result
    -- The cancelled call left, so the gate still admits and close will not wait.
    later ← onThread forkIO (wakeSession wake)
    asynchronous ← takeAsynchronousReports session
    pure (cancelled, later, asynchronous)
  either (Just . fromException) (const Nothing) cancelled `shouldBe` Just (Just ThreadKilled)
  later `shouldBe` WakeFailed (Reports [NativeError 0x00010008 "reported before cancellation" False OtherThread] 0 0)
  asynchronous `shouldBe` Reports [] 0 0
  readIORef (platformTerminateSaw platform) `shouldReturn` [0]
  seamCalls seam `shouldReturn` entryCalls <> [PostEmptyEvent, PostEmptyEvent] <> exitCalls
  asProcessMainThread seam (entered seam (pure . sessionBackend)) `shouldReturn` X11

testCancellationPendingAtCompletion ∷ Expectation
testCancellationPendingAtCompletion = do
  delivered ← newEmptyMVar
  seam ←
    newSeam
      defaultScript
        { scriptPostEmptyEvent = \_ → do
            waker ← myThreadId
            void (forkIO (throwTo waker ThreadKilled >> putMVar delivered ()))
        }
  (recorded, cancelled) ← asProcessMainThread seam $ entered seam $ \session → do
    recorded ← newIORef Nothing
    result ← newEmptyMVar
    _ ← forkIO $ do
      outcome ← try . mask_ $ do
        wakeSession (sessionWake session) >>= writeIORef recorded . Just
        -- The first blocking point: the cancellation requested inside the post
        -- is delivered here, after the wake completed and left.
        takeMVar delivered
      putMVar result outcome
    cancelled ← takeMVar result
    (,) <$> readIORef recorded <*> pure cancelled
  recorded `shouldBe` Just WakePosted
  either (Just . fromException) (const Nothing) cancelled `shouldBe` Just (Just ThreadKilled)
  seamCalls seam `shouldReturn` entryCalls <> [PostEmptyEvent] <> exitCalls
  asProcessMainThread seam (entered seam (pure . sessionBackend)) `shouldReturn` X11

testOwnerCancelledDuringDrain ∷ Expectation
testOwnerCancelledDuringDrain = do
  platform ← newPlatform
  held ← newHeldPost
  seam ← newSeam (platformScript platform (holdingFirstPost held defaultScript))
  owner ← startOwner seam
  wake ← sessionWake <$> readMVar (ownerSession owner)
  waker ← newEmptyMVar
  _ ← forkIO (try (wakeSession wake) >>= putMVar waker)
  takeMVar (heldEntered held)
  putMVar (ownerRelease owner) ()
  awaitBlocked (ownerThread owner) (== BlockedOnSTM)
  killer ← forkIO (throwTo (ownerThread owner) ThreadKilled)
  -- The cancellation is requested and waiting for the uninterruptible close.
  awaitBlocked killer (== BlockedOnException)
  callsBeforeRelease ← seamCalls seam
  putMVar (heldRelease held) ()
  (takeMVar waker >>= either (throwIO ∷ SomeException → IO a) pure) `shouldReturn` WakePosted
  ownerOutcome ← takeMVar (ownerResult owner)
  either (Just . fromException) (const Nothing) ownerOutcome `shouldBe` Just (Just ThreadKilled)
  callsBeforeRelease `shouldBe` entryCalls <> [PostEmptyEvent]
  readIORef (platformTerminateSaw platform) `shouldReturn` [0]
  seamCalls seam `shouldReturn` entryCalls <> [PostEmptyEvent] <> exitCalls
  -- The close was safe, so the guard was vacated rather than poisoned.
  asProcessMainThread seam (entered seam (pure . sessionBackend)) `shouldReturn` X11

-- ---------------------------------------------------------------------------
-- Support

-- | The scripted platform: posts pending for the next wait, whether an owner is
-- waiting, how many posts are inside the native call, and what each
-- termination observed of them.
data Platform = Platform
  { platformPending ∷ TVar Int
  , platformWaiting ∷ TVar Bool
  , platformInFlight ∷ TVar Int
  , platformTerminateSaw ∷ IORef [Int]
  }

newPlatform ∷ IO Platform
newPlatform = Platform <$> newTVarIO 0 <*> newTVarIO False <*> newTVarIO 0 <*> newIORef []

-- | A script over the platform: a post counts as pending and in flight around
-- the given script's own step, a wait blocks until a post is pending and
-- consumes every pending post, and termination records the posts in flight
-- before running the given script's own step.
platformScript ∷ Platform → SeamScript → SeamScript
platformScript platform script =
  script
    { scriptPostEmptyEvent = \reporter → do
        atomically (modifyTVar' (platformInFlight platform) (+ 1))
        ( do
            atomically (modifyTVar' (platformPending platform) (+ 1))
            scriptPostEmptyEvent script reporter
          )
          `finally` atomically (modifyTVar' (platformInFlight platform) (subtract 1))
    , scriptWaitEvents = \seconds reporter → do
        atomically (writeTVar (platformWaiting platform) True)
        atomically $ do
          readTVar (platformPending platform) >>= check . (> 0)
          writeTVar (platformPending platform) 0
          writeTVar (platformWaiting platform) False
        scriptWaitEvents script seconds reporter
    , scriptTerminate = \reporter → do
        inFlight ← readTVarIO (platformInFlight platform)
        modifyIORef' (platformTerminateSaw platform) (<> [inFlight])
        scriptTerminate script reporter
    }

-- | A post that, the first time only, signals that it has entered and then
-- waits to be released.
data HeldPost = HeldPost
  { heldFirst ∷ IORef Bool
  , heldEntered ∷ MVar ()
  , heldRelease ∷ MVar ()
  }

newHeldPost ∷ IO HeldPost
newHeldPost = HeldPost <$> newIORef True <*> newEmptyMVar <*> newEmptyMVar

holdingFirstPost ∷ HeldPost → SeamScript → SeamScript
holdingFirstPost held script =
  script
    { scriptPostEmptyEvent = \reporter → do
        scriptPostEmptyEvent script reporter
        first ← atomicModifyIORef' (heldFirst held) (\flag → (False, flag))
        when first $ do
          putMVar (heldEntered held) ()
          takeMVar (heldRelease held)
    }

-- | A session entered on a designated process main thread in the background,
-- held open until released.
data Owner = Owner
  { ownerThread ∷ ThreadId
  , ownerSession ∷ MVar Session
  , ownerRelease ∷ MVar ()
  , ownerResult ∷ MVar (Either SomeException ())
  }

startOwner ∷ Seam → IO Owner
startOwner seam = do
  thread ← newEmptyMVar
  session ← newEmptyMVar
  release ← newEmptyMVar
  result ← newEmptyMVar
  _ ← forkIO $ do
    outcome ← try . asProcessMainThread seam $ do
      myThreadId >>= putMVar thread
      entered seam (\lent → putMVar session lent >> takeMVar release)
    putMVar result outcome
  Owner <$> readMVar thread <*> pure session <*> pure release <*> pure result

-- | Wait until the runtime reports a thread blocked for the wanted reason.
awaitBlocked ∷ ThreadId → (BlockReason → Bool) → IO ()
awaitBlocked thread wanted =
  threadStatus thread >>= \case
    ThreadBlocked reason | wanted reason → pure ()
    ThreadFinished → expectationFailure "the thread finished instead of blocking"
    ThreadDied → expectationFailure "the thread died instead of blocking"
    _ → yield >> awaitBlocked thread wanted

entered ∷ Seam → (Session → IO r) → IO r
entered seam = withScoped (seamSession seam defaultSessionConfig)

-- | The native calls of a successful entry on the default script's platform.
entryCalls ∷ [NativeCall]
entryCalls =
  [ QueryPlatformSupported X11
  , CreateErrorCallback
  , AttachErrorCallback
  , SetInitHints X11
  , Initialize
  , QueryPlatform
  , CreateMonitorCallback
  , AttachMonitorCallback
  , QueryMonitors
  , QueryPrimaryMonitor
  ]

-- | The native calls of a complete, safe teardown.
exitCalls ∷ [NativeCall]
exitCalls = [DetachMonitorCallback, Terminate, DetachErrorCallback, FreeErrorCallback, FreeMonitorCallback]

-- | Run an action on a new thread and wait for its outcome.
onThread ∷ (IO () → IO ThreadId) → IO a → IO a
onThread fork action = do
  finished ← newEmptyMVar
  _ ← fork (try action >>= putMVar finished)
  takeMVar finished >>= either (throwIO ∷ SomeException → IO a) pure

-- | @GLFW_PLATFORM_ERROR@, the code the seam treats as an expected platform
-- failure.
platformErrorCode ∷ Int
platformErrorCode = 0x00010008

-- | The failure a wake raised, beside the exception as caught.
caughtWakeFailure ∷ IO WakeOutcome → IO (NativeFailure, SomeException)
caughtWakeFailure action =
  try action >>= \case
    Right outcome → unexpected ("the wake answered " <> show outcome <> " instead of failing")
    Left caught → maybe (unexpected ("the wake failed with " <> displayException caught)) (\failure → pure (failure, caught)) (fromException caught)

originOf ∷ SomeException → Maybe (Text.Text, Text.Text)
originOf caught = case failureCause (failureEvidence caught) of
  EngineOrigin origin → Just (componentText (originComponent origin), operationText (originOperation origin))
  NativeCause → Nothing

-- | The typed failure an action raised.
expectFailure ∷ Exception e ⇒ IO a → IO e
expectFailure action =
  try action >>= \case
    Right _ → unexpected "the action returned instead of failing"
    Left caught → maybe (unexpected ("the action failed with " <> displayException caught)) pure (fromException caught)

unexpected ∷ String → IO a
unexpected message = expectationFailure message >> ioError (userError message)

boundedExample ∷ Expectation → Expectation
boundedExample action = do
  finished ← timeout (30 * 1000 * 1000) action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"
