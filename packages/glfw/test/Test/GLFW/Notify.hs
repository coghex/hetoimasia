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

import Control.Concurrent (ThreadId, forkIO, killThread, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
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
import Control.Monad (forM, forM_, replicateM_, void, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sort)
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (..), threadStatus)
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
  ( attemptDegradationReport
  , sessionNotifier
  , wakeComponent
  )
import Hetoimasia.GLFW.Internal.Seam
import Hetoimasia.GLFW.Internal.Session (sessionWakePath)
import Hetoimasia.GLFW.Internal.Window (EventProcessing (..), processWindowEvents)
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window
import Test.GLFW.Window (boundedExample, caughtAs, entered, unexpected)
import Numeric.Natural (Natural)
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
    it "leaves every command a cancelled waiter admitted with its own wake, whichever side of the commit the cancellation lands"
      (boundedExample testCancellationRacesCapacity)

  describe "GLFW demand publication and wake" $ do
    it "combines concurrent immediate and deadline demand, keeping the earliest deadline, and wakes once for each"
      (boundedExample testConcurrentPublishers)
    it "coalesces continuous republication into one pending request the next capture takes"
      (boundedExample testCoalescedRepublication)
    it "captures a live publisher in both commit orders, taking every revision in order and coalescing what falls between two captures"
      (boundedExample testCaptureRacesPublication)
    it "publishes and wakes nothing for a request demanding nothing, or for a closed slot"
      (boundedExample testRefusedPublication)
    it "records and wakes for a publication cancelled after its commit, and records neither before it"
      (boundedExample testPublicationCancellation)

  describe "GLFW wake degradation" $ do
    it "degrades once on an expected platform failure, keeping tickets and skipping later wakes across hosts sharing the session"
      (boundedExample testDegradationSharedBySession)
    it "degrades once for two failures overlapping inside their posts, keeping the evidence of the one that degraded first"
      (boundedExample testOverlappingFailuresDegradeOnce)
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

-- | Every combination the contract names: both admission operations, on the
-- host's port and on a window's own, admitted before the owner's wait, while it
-- is inside one, and while none is in progress. Each of the twelve admissions
-- posts its own wake, each wait ends on the post that preceded or reached it,
-- and every ticket settles exactly once.
testAdmissionWakesAroundWait ∷ Expectation
testAdmissionWakesAroundWait = do
  platform ← newPlatform
  seam ← newSeam (platformScript platform defaultScript)
  (queued, waits, dispositions) ← withPorts seam $ \session hostCommands windowCommands window → do
    let command = observeOf window
        portOf HostPort = windowCommandPort hostCommands
        portOf WindowPort = windowCommandPort windowCommands
        admit Immediately kind = submitWindowCommand (portOf kind) [] command >>= accepted
        admit Waiting kind = awaitSubmitWindowCommand (portOf kind) [] command >>= admittedWaited

        -- Before the wait: the post it left is already pending, so the wait
        -- returns on it at once.
        around BeforeTheWait operation kind = do
          ticket ← onWorker (admit operation kind)
          processWindowEvents session (AwaitEventsFor 1)
          pure ticket
        -- During the wait: the worker admits only once the owner is inside it,
        -- and the wait returns on that post.
        around DuringTheWait operation kind = do
          admitted' ← newEmptyMVar
          _ ← forkIO $ do
            atomically (readTVar (platformWaiting platform) >>= check)
            try (admit operation kind) >>= putMVar admitted'
          processWindowEvents session (AwaitEventsFor 1)
          takeMVar admitted' >>= either (throwIO ∷ SomeException → IO a) pure
        -- Outside any wait, each still posts.
        around AfterTheWait operation kind = onWorker (admit operation kind)

    tickets ←
      forM
        [ (timing, operation, kind)
        | timing ← [BeforeTheWait, DuringTheWait, AfterTheWait]
        , operation ← [Immediately, Waiting]
        , kind ← [HostPort, WindowPort]
        ]
        (\(timing, operation, kind) → around timing operation kind)

    queued ←
      atomically ((+) <$> (commandsQueued <$> commandStatistics hostCommands) <*> (commandsQueued <$> commandStatistics windowCommands))
    waits ← readTVarIO (platformWaitsEntered platform)
    -- One command is executed and the rest are settled by closure, so every one
    -- of the twelve settles exactly once.
    _ ← seamExecuteNext seam hostCommands [window]
    mapM_ settleHost [hostCommands, windowCommands]
    dispositions ← mapM settledOnce tickets
    pure (queued, waits, dispositions)
  -- Twelve admissions, twelve posts, and the eight waits each ended on one.
  queued `shouldBe` 12
  waits `shouldBe` 8
  posts seam `shouldReturn` 12
  length dispositions `shouldBe` 12
  filter (== "performed") (map (settledKind . Just) dispositions) `shouldBe` ["performed"]
  filter (/= "performed") (map (settledKind . Just) dispositions) `shouldBe` replicate 11 "not executed"

-- | Which admission operation an example uses.
data AdmissionOperation = Immediately | Waiting
  deriving (Eq, Show)

-- | Which port kind an example admits through.
data PortKind = HostPort | WindowPort
  deriving (Eq, Show)

-- | Where an admission falls relative to the owner's finite wait.
data AdmissionTiming = BeforeTheWait | DuringTheWait | AfterTheWait
  deriving (Eq, Show)

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
    settleHost hostCommands
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
    settleHost hostCommands

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
    settleHost windowCommands

-- | A cancellation delivered while a waiter is blocked for capacity, racing the
-- capacity that would admit it. Both outcomes are correct; what must hold either
-- way is that an admission that committed left a wake behind, so the owner is
-- never left with a command it was not told about.
testCancellationRacesCapacity ∷ Expectation
testCancellationRacesCapacity = do
  seam ← newSeam defaultScript
  withPortsOf seam 1 $ \_ hostCommands _ window → do
    let port = windowCommandPort hostCommands
        command = observeOf window

        oneRound = do
          -- One command fills the capacity, so the next waiter blocks.
          _ ← submitWindowCommand port [] command >>= accepted
          outcome ← newEmptyMVar
          waiter ← forkIO (try (awaitSubmitWindowCommand port [] command) >>= putMVar outcome)
          awaitBlockedOnSTM waiter
          before ← countPosts seam
          -- The cancellation and the capacity that would admit the waiter are
          -- requested together, so neither order is scripted.
          _ ← forkIO (throwTo waiter ThreadKilled)
          _ ← seamExecuteNext seam hostCommands [window]
          settled ← takeMVar outcome
          after ← countPosts seam
          -- Whether the admission committed is the host's bookkeeping, not the
          -- waiter's answer: a cancellation delivered as the masked admission
          -- returns keeps its command and its wake while the caller still sees
          -- the cancellation.
          statistics ← atomically (commandStatistics hostCommands)
          let admitted = commandsPending statistics > 0
          after `shouldBe` before + (if admitted then 1 else 0)
          case settled of
            Right (WaitAccepted _) → admitted `shouldBe` True
            Right WaitClosed → unexpected "the port closed unexpectedly"
            Left caught
              | fromException caught == Just ThreadKilled → pure ()
            Left caught → unexpected ("the waiter failed with " <> show caught)
          -- Leave the port empty for the next round.
          drainCommands seam hostCommands window
          pure admitted

    rounds ← mapM (const oneRound) [1 .. 20 ∷ Int]
    -- Whatever the split between the two outcomes, every round held the
    -- invariant, and nothing is left pending.
    length rounds `shouldBe` 20
    settleHost hostCommands

-- | Execute whatever is queued, so the next round starts from an empty port.
drainCommands ∷ Seam → WindowCommandHost → Window → IO ()
drainCommands seam host window =
  seamExecuteNext seam host [window] >>= \case
    Executed _ _ → drainCommands seam host window
    _ → pure ()

-- | Wait until a thread is blocked in a transaction, so an example knows a wait
-- has begun without guessing at a delay.
awaitBlockedOnSTM ∷ ThreadId → IO ()
awaitBlockedOnSTM target =
  threadStatus target >>= \case
    ThreadBlocked BlockedOnSTM → pure ()
    ThreadFinished → unexpected "the thread finished instead of waiting"
    ThreadDied → unexpected "the thread died instead of waiting"
    _ → yield *> awaitBlockedOnSTM target

-- ---------------------------------------------------------------------------
-- Demand

testConcurrentPublishers ∷ Expectation
testConcurrentPublishers = do
  seam ← newSeam defaultScript
  (results, captured, afterCapture) ← withSlot seam $ \_ slot publisher → do
    -- Every publisher is started, waits at the gate, and publishes when it
    -- opens, so the four publications race rather than follow one another.
    results ←
      concurrently
        [ publishDemand publisher request
        | request ←
            [ deadlineDemand (instantAt 900)
            , immediateDemand
            , deadlineDemand (instantAt 300)
            , deadlineDemand (instantAt 1200)
            ]
        ]
    captured ← atomically (captureDemand slot)
    afterCapture ← atomically (captureDemand slot)
    pure (results, captured, afterCapture)
  -- Each publication was accepted and given its own revision; which publisher
  -- took which is the race's business.
  sort (map acceptedRevision results) `shouldBe` [1, 2, 3, 4]
  -- Immediate demand because one publisher asked for it, the earliest deadline
  -- of the three, and no later publication displacing it.
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

-- | A publisher and the owner's capture interleaved without a sleep: the
-- publisher stops halfway and waits, so the first capture is taken while half
-- the revisions are still to come, and the capture that follows it sees an empty
-- slot the resumed publisher then fills. Both commit orders are forced, and the
-- coalescing each capture performs is checked exactly: with deadlines that
-- increase by revision, a capture carries the earliest deadline of the
-- revisions it covers.
testCaptureRacesPublication ∷ Expectation
testCaptureRacesPublication = do
  seam ← newSeam defaultScript
  (published, halfway, emptyAfterCapture, rest, afterwards) ← withSlot seam $ \_ slot publisher → do
    let rounds = 50 ∷ Integer
        half = rounds `div` 2
    reached ← newEmptyMVar
    resume ← newEmptyMVar
    finished ← newEmptyMVar
    _ ← forkIO $ do
      outcomes ← forM [1 .. rounds] $ \index → do
        outcome ← publishDemand publisher (deadlineDemand (instantAt index))
        when (index == half) (putMVar reached () >> takeMVar resume)
        pure outcome
      putMVar finished outcomes
    -- Publication before capture: half the revisions are pending, and half are
    -- still to be published.
    takeMVar reached
    halfway ← atomically (captureDemand slot)
    -- Capture before publication: the slot it just cleared is empty, and the
    -- publisher is still holding its next publication.
    emptyAfterCapture ← atomically (captureDemand slot)
    putMVar resume ()
    let capture taken
          | any ((== fromIntegral rounds) . capturedRevision) taken = pure (reverse taken)
          | otherwise =
              atomically (captureDemand slot) >>= \case
                Just captured → capture (captured : taken)
                Nothing → yield >> capture taken
    rest ← capture []
    published ← takeMVar finished
    afterwards ← atomically (captureDemand slot)
    pure (published, halfway, emptyAfterCapture, rest, afterwards)
  map acceptedRevision published `shouldBe` [1 .. 50]
  -- The first capture took the twenty-five revisions published so far,
  -- coalesced, with the earliest deadline among them.
  fmap capturedRevision halfway `shouldBe` Just 25
  fmap (demandDeadline . capturedRequest) halfway `shouldBe` Just (Just (instantAt 1))
  emptyAfterCapture `shouldBe` Nothing
  -- Everything published after that capture stayed pending for a later one, in
  -- revision order, each carrying the earliest deadline of what it covered.
  map capturedRevision rest `shouldSatisfy` increasing
  map capturedRevision rest `shouldSatisfy` ((== Just 50) . lastOf)
  zip (25 : map capturedRevision rest) rest
    `shouldSatisfy` all (\(previous, captured) → demandDeadline (capturedRequest captured) == Just (instantAt (fromIntegral previous + 1)))
  afterwards `shouldBe` Nothing

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
    void (seamExecuteNext seam laterCommands [window])
    mapM_ settleHost [hostCommands, laterCommands]
    dispositions ← mapM (fmap Just . settledOnce) [first, second, third]
    pure (first, second, third, path, dispositions)
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
    settleHost hostCommands
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
    quietPath ← readTVarIO (sessionWakePath session)
    settleHost hostCommands
    pure (attempt, quietPath)
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
    path ← readTVarIO (sessionWakePath session)
    settleHost hostCommands
    pure (failure, second, path)
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
    path ← readTVarIO (sessionWakePath session)
    -- Both commands the raising admissions committed settle through closure.
    settleHost hostCommands
    pure (raised, queued, path)
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
    settleHost hostCommands
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

-- | Two notifications failing inside their own posts at the same time. Only one
-- degradation is recorded, with that call's evidence, and only one report is
-- ever owed.
testOverlappingFailuresDegradeOnce ∷ Expectation
testOverlappingFailuresDegradeOnce = do
  inside ← newTVarIO (0 ∷ Int)
  released ← newTVarIO False
  seam ←
    newSeam
      defaultScript
        { scriptPostEmptyEvent = \reporter → do
            reportError reporter platformErrorCode "overlapping failure"
            -- Both calls report, then wait inside their own post, so neither
            -- has classified its evidence when the other reports.
            atomically (modifyTVar' inside (+ 1))
            atomically (readTVar released >>= check)
        }
  entries ← newIORef []
  (submissions, path, first, second, afterwards) ← withPorts seam $ \session hostCommands _ window → do
    let port = windowCommandPort hostCommands
        command = observeOf window
    outcomes ← mapM (const (forkResult (submitWindowCommand port [] command))) [1 .. 2 ∷ Int]
    atomically (readTVar inside >>= check . (== 2))
    atomically (writeTVar released True)
    submissions ← mapM awaitResult outcomes
    path ← readTVarIO (sessionWakePath session)
    let notifier = commandHostNotifier hostCommands
    first ← attemptDegradationReport (recording entries) notifier
    second ← attemptDegradationReport (recording entries) notifier
    -- A third admission over the degraded path enters nothing.
    afterwards ← submitWindowCommand port [] command
    settleHost hostCommands
    pure (submissions, path, first, second, afterwards)
  map accepting submissions `shouldBe` [True, True]
  accepting afterwards `shouldBe` True
  -- Both calls entered the library, and exactly one degradation was recorded,
  -- keeping the evidence of one failing call rather than merging them.
  posts seam `shouldReturn` 2
  path `shouldSatisfy` \case
    WakePathDegraded reports DegradationOwed →
      map nativeErrorCode (reportedErrors reports) == [platformErrorCode]
        && reportsLost reports == 0
    _ → False
  first `shouldBe` DegradationReportAttempted
  second `shouldBe` NoDegradationDue
  readIORef entries >>= \written → length written `shouldBe` 1

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

-- | Start every action on its own unbound thread, hold them at one gate, and
-- release them together, so they run concurrently rather than in sequence.
concurrently ∷ [IO a] → IO [a]
concurrently actions = do
  gate ← newTVarIO False
  ready ← newTVarIO (0 ∷ Int)
  waiting ← forM actions $ \action → do
    outcome ← newEmptyMVar
    _ ← forkIO $ do
      atomically (modifyTVar' ready (+ 1))
      atomically (readTVar gate >>= check)
      try action >>= putMVar outcome
    pure outcome
  atomically (readTVar ready >>= check . (== length actions))
  atomically (writeTVar gate True)
  mapM awaitResult waiting

-- | Run an action on a new, unbound thread and hand back its outcome.
forkResult ∷ IO a → IO (MVar (Either SomeException a))
forkResult action = do
  outcome ← newEmptyMVar
  _ ← forkIO (try action >>= putMVar outcome)
  pure outcome

awaitResult ∷ MVar (Either SomeException a) → IO a
awaitResult outcome = takeMVar outcome >>= either (throwIO ∷ SomeException → IO a) pure

-- | The revision an accepted publication was given.
acceptedRevision ∷ PublishResult → Natural
acceptedRevision = \case
  DemandPublished revision → revision
  other → error ("the publication was not accepted: " <> show other)

-- | Whether a submission was accepted, without naming its ticket.
accepting ∷ SubmitResult → Bool
accepting = \case
  SubmitAccepted _ → True
  _ → False

increasing ∷ Ord a ⇒ [a] → Bool
increasing values = and (zipWith (<) values (drop 1 values))

lastOf ∷ [a] → Maybe a
lastOf [] = Nothing
lastOf values = Just (last values)

-- | The disposition a ticket settled to, read twice so a settled cell is shown
-- to be written once and never written again.
settledOnce ∷ CompletionTicket → IO Disposition
settledOnce ticket = do
  first ← atomically (pollCompletion ticket)
  again ← atomically (pollCompletion ticket)
  case (first, again) of
    (Just disposition, Just repeated)
      | disposition == repeated → pure disposition
    _ → unexpected ("the ticket did not settle exactly once: " <> show (first, again))

-- | End a host's admission, settling whatever it still holds, and check that it
-- keeps no cell afterwards. Every example that admits a command ends this way,
-- so no example leaves a ticket unsettled.
settleHost ∷ WindowCommandHost → IO ()
settleHost host = do
  _ ← atomically (closeWindowCommands host)
  statistics ← atomically (commandStatistics host)
  (commandsQueued statistics, commandsPending statistics) `shouldBe` (0, 0)

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

