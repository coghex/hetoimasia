-- | Examples for the wake an admission or a publication owes the owner, for
-- the bounded demand slots, and for the degradation policy over an expected
-- platform wake failure.
--
-- They drive the production admission, publication, and notification code over
-- "Hetoimasia.GLFW.Seam"'s scripted native library: the scripted platform
-- counts an empty-event post as pending for the next finite wait, so an example
-- can wake an owner before, during, and after a wait it genuinely entered,
-- without initializing GLFW and without a sleep. Threads are coordinated with
-- 'MVar's, STM, and the runtime's own report of what a thread is blocked on.
module Test.GLFW.Notify (spec) where

import Control.Concurrent (forkIO, killThread, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , check
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception (AsyncException (ThreadKilled), SomeException, fromException, throwIO, try)
import Control.Monad (forM, forM_, replicateM_, void)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Hetoimasia.Foundation.Log
  ( LogEntry (..)
  , LogLevel (Error)
  , Logger
  , callbackSink
  , componentText
  , LogFilter (filterEnabled)
  , defaultLogFilter
  , mkLoggerWith
  , systemMetadata
  )
import Hetoimasia.Foundation.Time (Duration, Instant, durationFromNanoseconds, DurationRequirement (AllowZero), scriptedInstant)
import Hetoimasia.GLFW.Command
import Hetoimasia.GLFW.Internal.Command (commandHostNotifier, newWindowPortHost)
import Hetoimasia.GLFW.Internal.Demand
import Hetoimasia.GLFW.Internal.Notify
  ( DegradationAttempt (..)
  , attemptDegradationReport
  , sessionNotifier
  , wakeComponent
  )
import Hetoimasia.GLFW.Internal.Seam
import Hetoimasia.GLFW.Internal.Session (DegradationReport (..), WakePath (..), sessionWakePath)
import Hetoimasia.GLFW.Internal.Window (EventProcessing (..), processWindowEvents)
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window
import Test.GLFW.Window (boundedExample, caughtAs, entered, unexpected)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = do
  describe "GLFW admission wake" $ do
    it "wakes the owner after each admission, before, during, and after its wait, through both admission operations and both port kinds"
      (boundedExample testAdmissionWakesAroundWait)
    it "wakes nothing for a full or closed admission, and admits nothing"
      (boundedExample testRefusedAdmissionWakesNothing)
    it "admits and wakes nothing for a cancellation before the admission commits"
      (boundedExample testCancelledBeforeCommit)
    it "keeps the command, its wake, and its settlement for a cancellation after the admission commits"
      (boundedExample testCancelledAfterCommit)
    it "keeps a waiting admission's command and wake for a cancellation after its commit"
      (boundedExample testWaitedAdmissionCancelledAfterCommit)

  describe "GLFW demand publication and wake" $ do
    it "combines concurrent immediate and deadline demand, keeping the earliest deadline, and wakes once for each"
      (boundedExample testConcurrentPublishers)
    it "coalesces continuous republication into one pending request the next capture takes"
      (boundedExample testCoalescedRepublication)
    it "captures a publication that committed first and leaves a later one pending with a newer revision"
      (boundedExample testCaptureRacesPublication)
    it "publishes and wakes nothing for a request demanding nothing, or for a closed slot"
      (boundedExample testRefusedPublication)
    it "records and wakes for a publication cancelled after its commit, and records neither before it"
      (boundedExample testPublicationCancellation)

  describe "GLFW wake degradation" $ do
    it "degrades once on an expected platform failure, keeping tickets and skipping later wakes across hosts sharing the session"
      (boundedExample testDegradationSharedBySession)
    it "reports the degradation once through the injected logger, and spends the attempt on a filtered entry"
      (boundedExample testDegradationReported)
    it "records a failing report without retrying it or undoing the degradation"
      (boundedExample testDegradationReportFails)
    it "keeps a lifetime violation typed, degrading nothing and admitting the command"
      (boundedExample testLifetimeViolationStaysTyped)
    it "starts a later session healthy, and answers a retained port and publisher without a native call"
      (boundedExample testStaleCapabilities)

-- ---------------------------------------------------------------------------
-- Admission

testAdmissionWakesAroundWait ∷ Expectation
testAdmissionWakesAroundWait = do
  platform ← newPlatform
  seam ← newSeam (platformScript platform defaultScript)
  (queued, waits) ← withPorts seam $ \session hostCommands windowCommands window → do
    let hostPort = windowCommandPort hostCommands
        windowPort = windowCommandPort windowCommands
        command = observeOf window
    -- Before the wait: the post it left is pending, so the wait returns at once.
    _ ← onWorker (submitWindowCommand hostPort [] command) >>= accepted
    processWindowEvents session (AwaitEventsFor 1)
    -- During the wait: the worker admits only once the owner is inside it.
    during ← newEmptyMVar
    _ ← forkIO $ do
      atomically (readTVar (platformWaiting platform) >>= check)
      try (awaitSubmitWindowCommand windowPort [] command) >>= putMVar during
    processWindowEvents session (AwaitEventsFor 1)
    _ ← takeMVar during >>= either (throwIO ∷ SomeException → IO a) pure >>= admittedWaited
    -- After the wait, with no wait in progress, each still posts.
    _ ← onWorker (submitWindowCommand windowPort [] command) >>= accepted
    _ ← onWorker (awaitSubmitWindowCommand hostPort [] command) >>= admittedWaited
    queued ←
      atomically ((+) <$> (commandsQueued <$> commandStatistics hostCommands) <*> (commandsQueued <$> commandStatistics windowCommands))
    waits ← readTVarIO (platformWaitsEntered platform)
    pure (queued, waits)
  -- Four admissions, four posts, and both waits returned on one.
  queued `shouldBe` 4
  waits `shouldBe` 2
  posts seam `shouldReturn` 4

testRefusedAdmissionWakesNothing ∷ Expectation
testRefusedAdmissionWakesNothing = do
  seam ← newSeam defaultScript
  (full, closed, waitClosed, statistics) ← withPortsOf seam 1 $ \_ hostCommands _ window → do
    let port = windowCommandPort hostCommands
        command = observeOf window
    _ ← submitWindowCommand port [] command >>= accepted
    postsAfterOne ← countPosts seam
    full ← submitWindowCommand port [] command
    _ ← atomically (closeWindowCommands hostCommands)
    closed ← submitWindowCommand port [] command
    waitClosed ← onWorker (awaitSubmitWindowCommand port [] command)
    postsAfterRefusals ← countPosts seam
    postsAfterRefusals `shouldBe` postsAfterOne
    (,,,) full closed waitClosed <$> atomically (commandStatistics hostCommands)
  full `shouldBe` SubmitFull
  closed `shouldBe` SubmitClosed
  waitClosed `shouldBe` WaitClosed
  -- The one admitted command was settled by closure; nothing else was reserved.
  commandsPending statistics `shouldBe` 0
  posts seam `shouldReturn` 1

testCancelledBeforeCommit ∷ Expectation
testCancelledBeforeCommit = do
  seam ← newSeam defaultScript
  withPorts seam $ \_ hostCommands _ window → do
    held ← newEmptyMVar
    entered' ← newEmptyMVar
    outcome ← newEmptyMVar
    submitter ← forkIO $ do
      let hooks = noAdmissionHooks {beforeAdmission = putMVar entered' () >> takeMVar held}
      try (submitWith hooks (windowCommandPort hostCommands) [] (observeOf window)) >>= putMVar outcome
    takeMVar entered'
    killThread submitter
    cancelled ← takeMVar outcome
    cancelled `shouldSatisfy` cancellation
    statistics ← atomically (commandStatistics hostCommands)
    commandsQueued statistics `shouldBe` 0
    commandsPending statistics `shouldBe` 0
    posts seam `shouldReturn` 0

testCancelledAfterCommit ∷ Expectation
testCancelledAfterCommit = do
  seam ← newSeam defaultScript
  withPorts seam $ \_ hostCommands _ window → do
    committed ← newEmptyMVar
    release ← newEmptyMVar
    outcome ← newEmptyMVar
    -- The hook runs inside the protection the admission owes its wake, so the
    -- cancellation requested while it is held cannot be delivered until the
    -- wake has been posted.
    submitter ← forkIO $ do
      let hooks = noAdmissionHooks {afterAdmission = putMVar committed () >> takeMVar release}
      try (submitWith hooks (windowCommandPort hostCommands) [] (observeOf window)) >>= putMVar outcome
    takeMVar committed
    _ ← forkIO (throwTo submitter ThreadKilled)
    queuedWhileHeld ← atomically (commandsQueued <$> commandStatistics hostCommands)
    postsWhileHeld ← countPosts seam
    putMVar release ()
    cancelled ← takeMVar outcome
    cancelled `shouldSatisfy` cancellation
    queuedWhileHeld `shouldBe` 1
    postsWhileHeld `shouldBe` 0
    -- The wake happened after the cancellation was requested, and the command,
    -- whose ticket its submitter never received, still settles exactly once.
    posts seam `shouldReturn` 1
    step ← seamExecuteNext seam hostCommands [window]
    step `shouldSatisfy` \case
      Executed _ (Performed (ObservationPublished _ _)) → True
      _ → False
    again ← seamExecuteNext seam hostCommands [window]
    again `shouldBe` NothingQueued
    statistics ← atomically (commandStatistics hostCommands)
    commandsPending statistics `shouldBe` 0

-- | The waiting admission owes its wake from its commit onward exactly as the
-- immediate one does, and its own wait for capacity stays cancellable.
testWaitedAdmissionCancelledAfterCommit ∷ Expectation
testWaitedAdmissionCancelledAfterCommit = do
  seam ← newSeam defaultScript
  withPortsOf seam 2 $ \_ _ windowCommands window → do
    committed ← newEmptyMVar
    release ← newEmptyMVar
    outcome ← newEmptyMVar
    submitter ← forkIO $ do
      let hooks = noAdmissionHooks {afterAdmission = putMVar committed () >> takeMVar release}
      try (awaitSubmitWith hooks (windowCommandPort windowCommands) [] (observeOf window)) >>= putMVar outcome
    takeMVar committed
    _ ← forkIO (throwTo submitter ThreadKilled)
    postsWhileHeld ← countPosts seam
    putMVar release ()
    takeMVar outcome >>= (`shouldSatisfy` cancellation)
    postsWhileHeld `shouldBe` 0
    posts seam `shouldReturn` 1
    step ← seamExecuteNext seam windowCommands [window]
    step `shouldSatisfy` \case
      Executed _ (Performed (ObservationPublished _ _)) → True
      _ → False
    statistics ← atomically (commandStatistics windowCommands)
    commandsPending statistics `shouldBe` 0

-- ---------------------------------------------------------------------------
-- Demand

testConcurrentPublishers ∷ Expectation
testConcurrentPublishers = do
  seam ← newSeam defaultScript
  (results, captured, afterCapture) ← withSlot seam $ \_ slot publisher → do
    results ←
      forM [deadlineDemand (instantAt 900), immediateDemand, deadlineDemand (instantAt 300), deadlineDemand (instantAt 1200)] $ \request →
        onWorker (publishDemand publisher request)
    captured ← atomically (captureDemand slot)
    afterCapture ← atomically (captureDemand slot)
    pure (results, captured, afterCapture)
  results `shouldBe` map DemandPublished [1, 2, 3, 4]
  -- Immediate demand from one publisher, the earliest deadline of the three,
  -- and no later publication displacing it.
  fmap capturedRevision captured `shouldBe` Just 4
  fmap (demandIsImmediate . capturedRequest) captured `shouldBe` Just True
  fmap (demandDeadline . capturedRequest) captured `shouldBe` Just (Just (instantAt 300))
  afterCapture `shouldBe` Nothing
  posts seam `shouldReturn` 4

testCoalescedRepublication ∷ Expectation
testCoalescedRepublication = do
  seam ← newSeam defaultScript
  (status, captured, next) ← withSlot seam $ \_ slot publisher → do
    replicateM_ 20 (void (publishDemand publisher immediateDemand))
    status ← atomically (demandStatus slot)
    captured ← atomically (captureDemand slot)
    next ← atomically (captureDemand slot)
    pure (status, captured, next)
  -- Twenty publications, one pending request: the slot's state does not grow.
  statusRevision status `shouldBe` 20
  fmap capturedRevision captured `shouldBe` Just 20
  next `shouldBe` Nothing

testCaptureRacesPublication ∷ Expectation
testCaptureRacesPublication = do
  seam ← newSeam defaultScript
  (firstCapture, secondCapture, third) ← withSlot seam $ \_ slot publisher → do
    _ ← publishDemand publisher (deadlineDemand (instantAt 500))
    firstCapture ← atomically (captureDemand slot)
    -- Committed after the capture: it is a newer revision and stays pending,
    -- which the capture that took the older one cannot erase.
    _ ← publishDemand publisher (deadlineDemand (instantAt 700))
    secondCapture ← atomically (captureDemand slot)
    third ← atomically (captureDemand slot)
    pure (firstCapture, secondCapture, third)
  fmap capturedRevision firstCapture `shouldBe` Just 1
  fmap (demandDeadline . capturedRequest) firstCapture `shouldBe` Just (Just (instantAt 500))
  fmap capturedRevision secondCapture `shouldBe` Just 2
  fmap (demandDeadline . capturedRequest) secondCapture `shouldBe` Just (Just (instantAt 700))
  third `shouldBe` Nothing

testRefusedPublication ∷ Expectation
testRefusedPublication = do
  seam ← newSeam defaultScript
  (nothing, pending, closedResult, closedNothing, afterClose) ← withSlot seam $ \_ slot publisher → do
    nothing ← publishDemand publisher noDemand
    pending ← atomically (demandStatus slot)
    _ ← publishDemand publisher immediateDemand
    atomically (closeDemandSlot slot)
    closedResult ← publishDemand publisher immediateDemand
    closedNothing ← publishDemand publisher noDemand
    afterClose ← atomically (captureDemand slot)
    pure (nothing, pending, closedResult, closedNothing, afterClose)
  nothing `shouldBe` NoDemandPublished
  statusPending pending `shouldBe` Nothing
  statusRevision pending `shouldBe` 0
  closedResult `shouldBe` DemandSlotClosed
  closedNothing `shouldBe` DemandSlotClosed
  afterClose `shouldBe` Nothing
  -- One post: the accepted publication's. Neither refusal entered the library.
  posts seam `shouldReturn` 1

testPublicationCancellation ∷ Expectation
testPublicationCancellation = do
  seam ← newSeam defaultScript
  withSlot seam $ \_ slot publisher → do
    -- Cancelled before the commit: nothing is recorded and nothing is woken.
    entered' ← newEmptyMVar
    held ← newEmptyMVar
    beforeOutcome ← newEmptyMVar
    early ← forkIO $ do
      let hooks = noDemandHooks {beforePublication = putMVar entered' () >> takeMVar held}
      try (publishDemandWith hooks publisher immediateDemand) >>= putMVar beforeOutcome
    takeMVar entered'
    killThread early
    takeMVar beforeOutcome >>= (`shouldSatisfy` cancellation)
    atomically (demandStatus slot) >>= \status → statusPending status `shouldBe` Nothing
    posts seam `shouldReturn` 0

    -- Cancelled after the commit: the request stays pending and is woken.
    committed ← newEmptyMVar
    release ← newEmptyMVar
    afterOutcome ← newEmptyMVar
    late ← forkIO $ do
      let hooks = noDemandHooks {afterPublication = putMVar committed () >> takeMVar release}
      try (publishDemandWith hooks publisher (deadlineDemand (instantAt 42))) >>= putMVar afterOutcome
    takeMVar committed
    _ ← forkIO (throwTo late ThreadKilled)
    heldStatus ← atomically (demandStatus slot)
    postsWhileHeld ← countPosts seam
    putMVar release ()
    takeMVar afterOutcome >>= (`shouldSatisfy` cancellation)
    statusPending heldStatus `shouldSatisfy` \case
      Just request → demandDeadline request == Just (instantAt 42)
      Nothing → False
    postsWhileHeld `shouldBe` 0
    posts seam `shouldReturn` 1
    captured ← atomically (captureDemand slot)
    fmap capturedRevision captured `shouldBe` Just 1

-- ---------------------------------------------------------------------------
-- Degradation

testDegradationSharedBySession ∷ Expectation
testDegradationSharedBySession = do
  seam ← newSeam (failingPost platformErrorCode defaultScript)
  (first, second, third, path, dispositions) ← withPorts seam $ \session hostCommands _ window → do
    let port = windowCommandPort hostCommands
        command = observeOf window
    -- Two concurrent failures degrade once; the answer and the ticket are the
    -- ordinary ones either way.
    first ← onWorker (submitWindowCommand port [] command) >>= accepted
    second ← onWorker (submitWindowCommand port [] command) >>= accepted
    afterTwo ← countPosts seam
    afterTwo `shouldBe` 1
    -- A second host over the same session inherits the degradation.
    laterCommands ← newWindowCommandHost session 4
    third ← submitWindowCommand (windowCommandPort laterCommands) [] command >>= accepted
    path ← readTVarIO (sessionWakePath session)
    forM_ [hostCommands, hostCommands] (\host → void (seamExecuteNext seam host [window]))
    dispositions ← atomically (mapM pollCompletion [first, second])
    void (seamExecuteNext seam laterCommands [window])
    thirdDisposition ← atomically (pollCompletion third)
    pure (first, second, third, path, dispositions <> [thirdDisposition])
  first `shouldSatisfy` (/= second)
  third `shouldSatisfy` (/= first)
  path `shouldSatisfy` \case
    WakePathDegraded reports DegradationOwed →
      map nativeErrorCode (reportedErrors reports) == [platformErrorCode]
    _ → False
  -- Only the first wake entered the library, and every ticket settled once.
  posts seam `shouldReturn` 1
  map settledKind dispositions `shouldBe` ["performed", "performed", "performed"]

testDegradationReported ∷ Expectation
testDegradationReported = do
  seam ← newSeam (failingPost platformErrorCode defaultScript)
  entries ← newIORef []
  filtered ← newIORef []
  (firstAttempt, secondAttempt, (), path) ← withPorts seam $ \session hostCommands _ window → do
    let notifier = commandHostNotifier hostCommands
    _ ← submitWindowCommand (windowCommandPort hostCommands) [] (observeOf window) >>= accepted
    firstAttempt ← attemptDegradationReport (recording entries) notifier
    secondAttempt ← attemptDegradationReport (recording entries) notifier
    path ← readTVarIO (sessionWakePath session)
    pure (firstAttempt, secondAttempt, (), path)
  firstAttempt `shouldBe` DegradationReportAttempted
  secondAttempt `shouldBe` NoDegradationDue
  path `shouldSatisfy` \case
    WakePathDegraded _ DegradationReported → True
    _ → False
  written ← readIORef entries
  map (componentText . entryComponent) written `shouldBe` [componentText wakeComponent]
  map entryLevel written `shouldSatisfy` all (/= Error)

  -- The same degradation, reported through a logger that filters it out: the
  -- attempt is spent, and nothing is written.
  quiet ← newSeam (failingPost platformErrorCode defaultScript)
  (attempt, quietPath) ← withPorts quiet $ \session hostCommands _ window → do
    _ ← submitWindowCommand (windowCommandPort hostCommands) [] (observeOf window) >>= accepted
    attempt ← attemptDegradationReport (dropping filtered) (commandHostNotifier hostCommands)
    (,) attempt <$> readTVarIO (sessionWakePath session)
  attempt `shouldBe` DegradationReportAttempted
  readIORef filtered `shouldReturn` []
  quietPath `shouldSatisfy` \case
    WakePathDegraded _ DegradationReported → True
    _ → False

testDegradationReportFails ∷ Expectation
testDegradationReportFails = do
  seam ← newSeam (failingPost platformErrorCode defaultScript)
  (failure, second, path) ← withPorts seam $ \session hostCommands _ window → do
    _ ← submitWindowCommand (windowCommandPort hostCommands) [] (observeOf window) >>= accepted
    let notifier = commandHostNotifier hostCommands
    failure ← try (attemptDegradationReport failingLogger notifier) ∷ IO (Either SomeException DegradationAttempt)
    second ← attemptDegradationReport failingLogger notifier
    (,,) failure second <$> readTVarIO (sessionWakePath session)
  failure `shouldSatisfy` \case
    Left _ → True
    Right _ → False
  -- The attempt is spent and the degradation stands.
  second `shouldBe` NoDegradationDue
  path `shouldSatisfy` \case
    WakePathDegraded _ DegradationReportFailed → True
    _ → False

testLifetimeViolationStaysTyped ∷ Expectation
testLifetimeViolationStaysTyped = do
  seam ← newSeam (failingPost notInitialisedCode defaultScript)
  (failure, queued, path) ← withPorts seam $ \session hostCommands _ window → do
    (raised, _) ← caughtAs (submitWindowCommand (windowCommandPort hostCommands) [] (observeOf window))
    queued ← atomically (commandsQueued <$> commandStatistics hostCommands)
    -- A programming or lifetime violation is not degraded around, so the next
    -- admission tries the wake again.
    _ ← try (submitWindowCommand (windowCommandPort hostCommands) [] (observeOf window)) ∷ IO (Either SomeException SubmitResult)
    (,,) raised queued <$> readTVarIO (sessionWakePath session)
  nativeOutcome failure `shouldBe` NativeCallReturned
  map nativeErrorCode (reportedErrors (nativeReports failure)) `shouldBe` [notInitialisedCode]
  -- The admission that raised still committed its command.
  queued `shouldBe` 1
  path `shouldSatisfy` \case
    WakePathHealthy → True
    _ → False
  posts seam `shouldReturn` 2

testStaleCapabilities ∷ Expectation
testStaleCapabilities = do
  seam ← newSeam (failingPost platformErrorCode defaultScript)
  (retainedPort, retainedPublisher, retainedSlot) ← withPorts seam $ \session hostCommands _ window → do
    _ ← submitWindowCommand (windowCommandPort hostCommands) [] (observeOf window) >>= accepted
    slot ← newDemandSlot
    let publisher = demandPublisher slot (sessionNotifier session)
    _ ← publishDemand publisher immediateDemand
    void (atomically (closeWindowCommands hostCommands))
    atomically (closeDemandSlot slot)
    pure (windowCommandPort hostCommands, publisher, slot)
  postsAfterFirst ← countPosts seam
  -- A later session starts healthy, and the retained capabilities of the
  -- earlier one answer typed rejections without entering the library.
  (closedSubmission, closedPublication, freshPath) ← withPorts seam $ \session _ _ window → do
    closedSubmission ← submitWindowCommand retainedPort [] (observeOf window)
    closedPublication ← publishDemand retainedPublisher immediateDemand
    (,,) closedSubmission closedPublication <$> readTVarIO (sessionWakePath session)
  closedSubmission `shouldBe` SubmitClosed
  closedPublication `shouldBe` DemandSlotClosed
  freshPath `shouldSatisfy` \case
    WakePathHealthy → True
    _ → False
  atomically (captureDemand retainedSlot) `shouldReturn` Nothing
  posts seam `shouldReturn` postsAfterFirst

-- ---------------------------------------------------------------------------
-- Support

-- | A session with the host's command host, one window's port host, and that
-- window, on a designated process main thread.
withPorts ∷ Seam → (Session → WindowCommandHost → WindowCommandHost → Window → IO a) → IO a
withPorts seam = withPortsOf seam 8

withPortsOf ∷ Seam → Integer → (Session → WindowCommandHost → WindowCommandHost → Window → IO a) → IO a
withPortsOf seam capacity body =
  asProcessMainThread seam $ entered seam $ \session →
    withWindow session (hiddenTestWindowConfig "notified" 64 48) $ \window → do
      hostCommands ← newWindowCommandHost session capacity
      windowCommands ← newWindowPortHost session capacity (windowIdentity window)
      body session hostCommands windowCommands window

-- | A session with one demand slot and its publisher.
withSlot ∷ Seam → (Session → DemandSlot → DemandPublisher → IO a) → IO a
withSlot seam body =
  asProcessMainThread seam $ entered seam $ \session → do
    slot ← newDemandSlot
    body session slot (demandPublisher slot (sessionNotifier session))

-- | The scripted platform: how many posts are pending for the next wait,
-- whether an owner is inside one, and how many waits were entered.
data Platform = Platform
  { platformPending ∷ TVar Int
  , platformWaiting ∷ TVar Bool
  , platformWaitsEntered ∷ TVar Int
  }

newPlatform ∷ IO Platform
newPlatform = Platform <$> newTVarIO 0 <*> newTVarIO False <*> newTVarIO 0

-- | A post counts as pending; a finite wait blocks until one is, then consumes
-- every pending post. So a wait only ends because something woke the owner.
platformScript ∷ Platform → SeamScript → SeamScript
platformScript platform script =
  script
    { scriptPostEmptyEvent = \reporter → do
        atomically (modifyTVar' (platformPending platform) (+ 1))
        scriptPostEmptyEvent script reporter
    , scriptWaitEvents = \seconds reporter → do
        atomically $ do
          modifyTVar' (platformWaitsEntered platform) (+ 1)
          writeTVar (platformWaiting platform) True
        atomically $ do
          readTVar (platformPending platform) >>= check . (> 0)
          writeTVar (platformPending platform) 0
          writeTVar (platformWaiting platform) False
        scriptWaitEvents script seconds reporter
    }

-- | A post that reports one error of the given code.
failingPost ∷ Int → SeamScript → SeamScript
failingPost code script =
  script {scriptPostEmptyEvent = \reporter → reportError reporter code "scripted wake failure"}

-- | @GLFW_PLATFORM_ERROR@, the expected platform failure.
platformErrorCode ∷ Int
platformErrorCode = 0x00010008

-- | @GLFW_NOT_INITIALIZED@: a programming or lifetime violation.
notInitialisedCode ∷ Int
notInitialisedCode = 0x00010001

observeOf ∷ Window → WindowCommand
observeOf = observeWindowCommand . windowIdentity

accepted ∷ SubmitResult → IO CompletionTicket
accepted (SubmitAccepted ticket) = pure ticket
accepted other = unexpected ("the submission was not admitted: " <> show other)

admittedWaited ∷ WaitedSubmission → IO CompletionTicket
admittedWaited (WaitAccepted ticket) = pure ticket
admittedWaited other = unexpected ("the waiting submission was not admitted: " <> show other)

-- | Run an action on a new, unbound thread, which is never the owner, and wait
-- for its outcome.
onWorker ∷ IO a → IO a
onWorker action = do
  finished ← newEmptyMVar
  _ ← forkIO (try action >>= putMVar finished)
  takeMVar finished >>= either (throwIO ∷ SomeException → IO a) pure

cancellation ∷ Either SomeException a → Bool
cancellation (Left caught) = fromException caught == Just ThreadKilled
cancellation (Right _) = False

-- | How many empty-event posts the seam recorded.
countPosts ∷ Seam → IO Int
countPosts seam = length . filter (== PostEmptyEvent) <$> seamCalls seam

posts ∷ Seam → IO Int
posts = countPosts

settledKind ∷ Maybe Disposition → String
settledKind = \case
  Nothing → "pending"
  Just (Performed _) → "performed"
  Just (Rejected _) → "rejected"
  Just NotExecuted → "not executed"
  Just (Interrupted _) → "interrupted"
  Just (Unsupported _) → "unsupported"
  Just (Attempted _) → "attempted"
  Just (Transitioned _) → "transitioned"

-- | An instant this many nanoseconds into a scripted clock domain.
instantAt ∷ Integer → Instant
instantAt nanoseconds = scriptedInstant (scriptedDuration nanoseconds)

scriptedDuration ∷ Integer → Duration
scriptedDuration nanoseconds = case durationFromNanoseconds AllowZero nanoseconds of
  Right duration → duration
  Left rejected → error ("the scripted duration was rejected: " <> show rejected)

recording ∷ IORef [LogEntry] → Logger
recording entries = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\entry → modifyIORef' entries (<> [entry])))

dropping ∷ IORef [LogEntry] → Logger
dropping entries =
  mkLoggerWith
    defaultLogFilter {filterEnabled = False}
    systemMetadata
    (callbackSink (\entry → modifyIORef' entries (<> [entry])))

failingLogger ∷ Logger
failingLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → ioError (userError "the scripted sink failed")))

