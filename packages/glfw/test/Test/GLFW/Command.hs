-- | Examples for window command admission and completion, driven through the
-- test seam's private command executor.
--
-- They live in the package's own @glfw-tests@ suite because the executor and
-- the admission hooks belong to the private @seam-core@ sublibrary. Hosts, ports, and tickets are the public "Hetoimasia.GLFW.Command"
-- interface, over a session and windows of "Hetoimasia.GLFW.Seam"'s scripted
-- native library: admission, claim, settlement, closure, and the observation
-- request's execution are the production protocol, and nothing initializes
-- GLFW.
--
-- Threads are coordinated with 'MVar's and 'threadStatus', never with a sleep.
module Test.GLFW.Command (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, retry, throwSTM)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), SomeException, fromException, throwIO, try)
import Control.Monad (forM_, replicateM, replicateM_, when)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (..), threadStatus)
import Hetoimasia.Foundation.Failure (FailureSite (..), operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, SourceLocation (..), unsafeComponent)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (cursorRevision, observedCursor, observedValue, readSnapshot)
import Hetoimasia.GLFW.Command
import Hetoimasia.GLFW.Internal.Seam
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window
import Test.GLFW.Window
  ( boundedExample
  , caughtAs
  , contextsOf
  , current
  , entered
  , onThread
  , operationOf
  , originOf
  , stashed
  , unexpected
  )
import Test.Hspec (Expectation, Spec, describe, it, shouldBe)

spec ∷ Spec
spec = do
  describe "GLFW window command admission" $ do
    it "answers Full at capacity and Closed after closure, changing nothing"
      (boundedExample testImmediateAdmission)
    it "waits for capacity cancellably, admitting nothing when cancelled, and ends the wait at closure"
      (boundedExample testCapacityWait)
    it "leaves nothing reserved after a rolled-back or cancelled admission, and keeps a command whose admission committed"
      (boundedExample testAdmissionBoundaries)
    it "keeps the submission site, caller context, and window and request identity intact across the queue"
      (boundedExample testOriginSurvives)

  describe "GLFW window command execution" $ do
    it "claims commands in committed admission order"
      (boundedExample testFifoClaim)
    it "settles an interruption after the claim, after effects, or in preparation as interrupted, without replay"
      (boundedExample testInterruptedWithoutReplay)
    it "carries a native failure as prepared data and keeps a Haskell exception's context on the failure path"
      (boundedExample testFailures)
    it "keeps pending bookkeeping within capacity plus active work across repeated cycles"
      (boundedExample testBoundedBookkeeping)

  describe "GLFW window command completion" $ do
    it "returns one settled disposition to repeated and cancelled waits, and after leaving the bookkeeping"
      (boundedExample testTicketWaits)
    it "never waits on the owner thread for work only the owner thread can do"
      (boundedExample testOwnerThreadNeverWaits)

  describe "GLFW window command closure" $ do
    it "settles every queued command as not executed, wakes its waiters, and executes nothing afterwards"
      (boundedExample testClosureBeforeClaim)
    it "leaves a command claimed before closure to settle through its execution"
      (boundedExample testClaimBeforeClosure)

  describe "GLFW window observation requests" $
    it "settle with a committed revision of the addressed window, published first, and reject unserved and ended windows"
      (boundedExample testObservationRequests)

-- ---------------------------------------------------------------------------
-- Admission

testImmediateAdmission ∷ Expectation
testImmediateAdmission = withCommands defaultScript 2 $ \_ host window → do
  let port = windowCommandPort host
      command = observeOf window
  first ← submitWindowCommand port [] command >>= accepted
  second ← submitWindowCommand port [] command >>= accepted
  queued ← statistics host
  full ← submitWindowCommand port [] command
  afterFull ← statistics host
  settled ← atomically (closeWindowCommands host)
  closed ← submitWindowCommand port [] command
  afterClosed ← statistics host
  again ← atomically (closeWindowCommands host)
  dispositions ← atomically (mapM pollCompletion [first, second])
  queued `shouldBe` CommandStatistics 2 2 0 2
  full `shouldBe` SubmitFull
  afterFull `shouldBe` queued
  settled `shouldBe` 2
  closed `shouldBe` SubmitClosed
  afterClosed `shouldBe` CommandStatistics 2 0 0 0
  again `shouldBe` 0
  dispositions `shouldBe` [Just NotExecuted, Just NotExecuted]

testCapacityWait ∷ Expectation
testCapacityWait = withCommands defaultScript 1 $ \seam host window → do
  let port = windowCommandPort host
      command = observeOf window
  held ← submitWindowCommand port [("client", "held")] command >>= accepted
  (cancelled, cancelledOutcome) ← forked (awaitSubmitWindowCommand port [("client", "cancelled")] command)
  awaitBlockedOnSTM cancelled
  beforeCancel ← statistics host
  killThread cancelled
  cancelledResult ← takeMVar cancelledOutcome
  afterCancel ← statistics host
  -- Capacity freed by the executor admits the next waiter.
  (waiting, waitingOutcome) ← forked (awaitSubmitWindowCommand port [("client", "waited")] command)
  awaitBlockedOnSTM waiting
  step ← seamExecuteNext seam host [window]
  waited ← takeMVar waitingOutcome >>= either throwIO pure >>= waitAccepted
  -- Closure ends a wait that capacity never would.
  (ending, endingOutcome) ← forked (awaitSubmitWindowCommand port [("client", "closed")] command)
  awaitBlockedOnSTM ending
  settled ← atomically (closeWindowCommands host)
  ended ← takeMVar endingOutcome >>= either throwIO pure
  dispositions ← atomically (mapM pollCompletion [held, waited])
  let performed = Performed (ObservationPublished (windowIdentity window) 0)
  beforeCancel `shouldBe` CommandStatistics 1 1 0 1
  isCancellation cancelledResult `shouldBe` True
  afterCancel `shouldBe` beforeCancel
  step `shouldBe` Executed (ticketOrigin held) performed
  submittedContext (ticketOrigin waited) `shouldBe` [("client", "waited")]
  settled `shouldBe` 1
  ended `shouldBe` WaitClosed
  dispositions `shouldBe` [Just performed, Just NotExecuted]
  where
    waitAccepted (WaitAccepted ticket) = pure ticket
    waitAccepted WaitClosed = unexpected "the waiting submission was not admitted"

testAdmissionBoundaries ∷ Expectation
testAdmissionBoundaries = withCommands defaultScript 2 $ \seam host window → do
  let port = windowCommandPort host
      command = observeOf window
  (rolledBack, _) ←
    caughtAs (submitWith noAdmissionHooks {duringAdmission = throwSTM (ErrorCall "rolled back")} port [] command)
  afterRollback ← statistics host
  (cancelledBefore, _) ←
    caughtAs (submitWith noAdmissionHooks {beforeAdmission = throwIO ThreadKilled} port [] command)
  afterCancelledBefore ← statistics host
  -- The caller never receives this ticket, but the command was admitted.
  (cancelledAfter, _) ←
    caughtAs
      (submitWith noAdmissionHooks {afterAdmission = throwIO ThreadKilled} port [("client", "unreturned")] command)
  afterCommit ← statistics host
  step ← seamExecuteNext seam host [window]
  final ← statistics host
  rolledBack `shouldBe` ErrorCall "rolled back"
  afterRollback `shouldBe` CommandStatistics 2 0 0 0
  cancelledBefore `shouldBe` ThreadKilled
  afterCancelledBefore `shouldBe` afterRollback
  cancelledAfter `shouldBe` ThreadKilled
  afterCommit `shouldBe` CommandStatistics 2 1 0 1
  case step of
    Executed origin disposition → do
      submittedContext origin `shouldBe` [("client", "unreturned")]
      requestLocalIdentity (submittedRequest origin) `shouldBe` 3
      disposition `shouldBe` Performed (ObservationPublished (windowIdentity window) 0)
    other → unexpected ("the admitted command was not executed: " <> show other)
  final `shouldBe` CommandStatistics 2 0 0 0

testOriginSurvives ∷ Expectation
testOriginSurvives = withCommands defaultScript 2 $ \seam host window → do
  let port = windowCommandPort host
      command = observeOf window
      context = [("client", "inspector"), ("purpose", "refresh \"panel\"\nnow")]
  ticket ← onThread forkIO (submitWindowCommand port context command >>= accepted)
  claimed ← newIORef Nothing
  step ← seamExecuteNextScripted seam host $ \origin received → do
    writeIORef claimed (Just (origin, received))
    pure (Right (ObservationPublished (windowIdentity window) 0))
  (origin, received) ← readIORef claimed >>= maybe (unexpected "nothing was executed") pure
  origin `shouldBe` ticketOrigin ticket
  received `shouldBe` command
  submittedWindow origin `shouldBe` Just (windowIdentity window)
  requestLocalIdentity (submittedRequest origin) `shouldBe` 1
  submittedContext origin `shouldBe` context
  fmap (sourceFunction . siteLocation) (submittedAt origin) `shouldBe` Just "submitWindowCommand"
  fmap (("Test/GLFW/Command.hs" `Text.isSuffixOf`) . sourceFile . siteLocation) (submittedAt origin)
    `shouldBe` Just True
  step `shouldBe` Executed origin (Performed (ObservationPublished (windowIdentity window) 0))

-- ---------------------------------------------------------------------------
-- Execution

testFifoClaim ∷ Expectation
testFifoClaim = withCommands defaultScript 4 $ \seam host window → do
  let port = windowCommandPort host
      submitAs name = onThread forkIO (submitWindowCommand port [("client", name)] (observeOf window) >>= accepted)
  first ← submitAs "first"
  second ← submitAs "second"
  claimedFirst ← claimNext seam host window
  third ← submitAs "third"
  fourth ← submitAs "fourth"
  claimedRest ← replicateM 3 (claimNext seam host window)
  idle ← seamExecuteNext seam host [window]
  (claimedFirst : claimedRest) `shouldBe` map ticketOrigin [first, second, third, fourth]
  idle `shouldBe` NothingQueued
  where
    claimNext seam host window =
      seamExecuteNext seam host [window] >>= \case
        Executed origin _ → pure origin
        other → unexpected ("nothing was claimed: " <> show other)

testInterruptedWithoutReplay ∷ Expectation
testInterruptedWithoutReplay = withCommands defaultScript 5 $ \seam host window → do
  let port = windowCommandPort host
  interrupted ← replicateM 4 (submitWindowCommand port [] (observeOf window) >>= accepted)
  following ← submitWindowCommand port [] (observeOf window) >>= accepted
  callsBefore ← length <$> seamCalls seam
  (claimFault, claimCaught) ←
    caughtAs (seamExecuteNextInterrupted seam host (throwIO (ErrorCall "after claim")) [window])
  callsAfterClaim ← length <$> seamCalls seam
  effects ← newIORef (0 ∷ Int)
  (effectsFault, _) ←
    caughtAs $
      seamExecuteNextScripted seam host $ \_ _ → do
        modifyIORef' effects (+ 1)
        throwIO (ErrorCall "after effects")
  (preparationFault, _) ←
    caughtAs $
      seamExecuteNextScripted seam host $ \_ _ →
        pure (Right (ObservationPublished (windowIdentity window) (error "unprepared revision")))
  (cancellation, cancellationCaught) ←
    caughtAs (seamExecuteNextScripted seam host (\_ _ → throwIO ThreadKilled))
  -- The next claim is the next command: no interrupted command is replayed.
  next ← seamExecuteNext seam host [window]
  idle ← seamExecuteNext seam host [window]
  effectCount ← readIORef effects
  dispositions ← atomically (mapM pollCompletion interrupted)
  final ← statistics host
  claimFault `shouldBe` ErrorCall "after claim"
  map (\(component, name, _) → (component, name)) (contextsOf claimCaught)
    `shouldBe` [("glfw", "execute window command")]
  callsAfterClaim `shouldBe` callsBefore
  effectsFault `shouldBe` ErrorCall "after effects"
  effectCount `shouldBe` 1
  preparationFault `shouldBe` ErrorCall "unprepared revision"
  cancellation `shouldBe` ThreadKilled
  contextsOf cancellationCaught `shouldBe` []
  dispositions `shouldBe` map (Just . Interrupted . submittedRequest . ticketOrigin) interrupted
  next `shouldBe` Executed (ticketOrigin following) (Performed (ObservationPublished (windowIdentity window) 0))
  idle `shouldBe` NothingQueued
  final `shouldBe` CommandStatistics 5 0 0 0

testFailures ∷ Expectation
testFailures = do
  failing ← newIORef False
  let script =
        defaultScript
          { scriptWindowSize = \reporter → do
              failed ← readIORef failing
              when failed (reportError reporter platformErrorCode "The window size could not be queried")
              pure (800, 600)
          }
  withCommands script 2 $ \seam host window → do
    let port = windowCommandPort host
        command = observeOf window
    native ← submitWindowCommand port [] command >>= accepted
    haskell ← submitWindowCommand port [("client", "faulting")] command >>= accepted
    writeIORef failing True
    nativeStep ← seamExecuteNext seam host [window]
    writeIORef failing False
    unchanged ← current window
    nativeDisposition ← atomically (pollCompletion native)
    (fault, caught) ←
      caughtAs $
        seamExecuteNextScripted seam host $ \_ _ →
          throwFailure testComponent (operation "simulated effect") [("step", "2")] (ErrorCall "engine fault")
    haskellDisposition ← atomically (pollCompletion haskell)
    case nativeStep of
      Executed origin disposition@(Rejected (WindowNativeFailure target failed outcome reports)) → do
        origin `shouldBe` ticketOrigin native
        target `shouldBe` windowIdentity window
        failed `shouldBe` Just "sample window"
        outcome `shouldBe` NativeCallReturned
        [(nativeErrorCode reported, nativeErrorDescription reported) | reported ← reportedErrors reports]
          `shouldBe` [(platformErrorCode, "The window size could not be queried")]
        nativeDisposition `shouldBe` Just disposition
      other → unexpected ("the native failure was not a rejection: " <> show other)
    observedRevision unchanged `shouldBe` 0
    fault `shouldBe` ErrorCall "engine fault"
    -- The origin stays at the operation that failed; the submission is context.
    originOf caught `shouldBe` Just ("test.commands", "simulated effect", [("step", "2")])
    case contextsOf caught of
      [("glfw", "execute window command", identifiers)] → do
        lookup "request" identifiers `shouldBe` Just "2"
        lookup "window" identifiers `shouldBe` Just "1"
        lookup "client" identifiers `shouldBe` Just "faulting"
        fmap ("Test/GLFW/Command.hs:" `Text.isInfixOf`) (lookup "submitted-at" identifiers) `shouldBe` Just True
      other → unexpected ("unexpected operation contexts: " <> show other)
    haskellDisposition `shouldBe` Just (Interrupted (submittedRequest (ticketOrigin haskell)))

testBoundedBookkeeping ∷ Expectation
testBoundedBookkeeping = withCommands defaultScript 3 $ \seam host window → do
  let port = windowCommandPort host
      command = observeOf window
      performed = Performed (ObservationPublished (windowIdentity window) 0)
  during ← newIORef []
  forM_ [1 .. 25 ∷ Int] $ \_ → do
    tickets ← replicateM 3 (submitWindowCommand port [] command >>= accepted)
    full ← submitWindowCommand port [] command
    queued ← statistics host
    replicateM_ 3 $
      seamExecuteNextScripted seam host $ \_ _ → do
        observed ← statistics host
        modifyIORef' during (observed :)
        pure (Right (ObservationPublished (windowIdentity window) 0))
    settled ← statistics host
    dispositions ← atomically (mapM pollCompletion tickets)
    full `shouldBe` SubmitFull
    queued `shouldBe` CommandStatistics 3 3 0 3
    settled `shouldBe` CommandStatistics 3 0 0 0
    dispositions `shouldBe` replicate 3 (Just performed)
  observations ← readIORef during
  length observations `shouldBe` 75
  filter (not . bounded) observations `shouldBe` []
  where
    bounded observed =
      commandsActive observed == 1
        && commandsPending observed == commandsQueued observed + commandsActive observed
        && commandsPending observed <= commandsCapacity observed + commandsActive observed

-- ---------------------------------------------------------------------------
-- Completion

testTicketWaits ∷ Expectation
testTicketWaits = withCommands defaultScript 2 $ \seam host window → do
  let port = windowCommandPort host
  ticket ← submitWindowCommand port [] (observeOf window) >>= accepted
  (patient, patientOutcome) ← forked (awaitCompletion ticket)
  (cancelled, cancelledOutcome) ← forked (awaitCompletion ticket)
  awaitBlockedOnSTM patient
  awaitBlockedOnSTM cancelled
  killThread cancelled
  cancelledResult ← takeMVar cancelledOutcome
  unaffected ← statistics host
  step ← seamExecuteNext seam host [window]
  first ← takeMVar patientOutcome >>= either throwIO pure
  second ← onThread forkIO (awaitCompletion ticket)
  onOwner ← awaitCompletion ticket
  polled ← atomically (pollCompletion ticket)
  removed ← statistics host
  let performed = Performed (ObservationPublished (windowIdentity window) 0)
  isCancellation cancelledResult `shouldBe` True
  unaffected `shouldBe` CommandStatistics 2 1 0 1
  step `shouldBe` Executed (ticketOrigin ticket) performed
  [first, second, onOwner] `shouldBe` replicate 3 performed
  polled `shouldBe` Just performed
  removed `shouldBe` CommandStatistics 2 0 0 0

testOwnerThreadNeverWaits ∷ Expectation
testOwnerThreadNeverWaits = withCommands defaultScript 1 $ \seam host window → do
  let port = windowCommandPort host
      command = observeOf window
      performed = Performed (ObservationPublished (windowIdentity window) 0)
  ticket ← submitWindowCommand port [] command >>= accepted
  (awaitMisuse, awaitCaught) ← caughtAs (awaitCompletion ticket)
  (submitMisuse, submitCaught) ← caughtAs (awaitSubmitWindowCommand port [] command)
  refused ← statistics host
  direct ← performWindowCommand host [window] command
  (offOwner, _) ← onThread forkIO (caughtAs (seamExecuteNext seam host [window]))
  unclaimed ← statistics host
  step ← seamExecuteNext seam host [window]
  settled ← awaitCompletion ticket
  awaitMisuse `shouldBe` OwnerThreadWouldWait
  operationOf awaitCaught `shouldBe` Just ("glfw", "await window command")
  submitMisuse `shouldBe` OwnerThreadWouldWait
  operationOf submitCaught `shouldBe` Just ("glfw", "submit window command")
  refused `shouldBe` CommandStatistics 1 1 0 1
  direct `shouldBe` performed
  offOwner `shouldBe` NotSessionOwner
  unclaimed `shouldBe` refused
  step `shouldBe` Executed (ticketOrigin ticket) performed
  settled `shouldBe` performed

-- ---------------------------------------------------------------------------
-- Closure

testClosureBeforeClaim ∷ Expectation
testClosureBeforeClaim = withCommands defaultScript 3 $ \seam host window → do
  let port = windowCommandPort host
      command = observeOf window
  tickets ← replicateM 3 (submitWindowCommand port [] command >>= accepted)
  (waiter, waiterOutcome) ← forked (awaitCompletion (last tickets))
  awaitBlockedOnSTM waiter
  callsBefore ← length <$> seamCalls seam
  settled ← atomically (closeWindowCommands host)
  woken ← takeMVar waiterOutcome >>= either throwIO pure
  step ← seamExecuteNext seam host [window]
  direct ← performWindowCommand host [window] command
  callsAfter ← length <$> seamCalls seam
  final ← statistics host
  retained ← onThread forkIO (mapM awaitCompletion tickets)
  settled `shouldBe` 3
  woken `shouldBe` NotExecuted
  step `shouldBe` CommandsEnded
  direct `shouldBe` NotExecuted
  callsAfter `shouldBe` callsBefore
  final `shouldBe` CommandStatistics 3 0 0 0
  retained `shouldBe` replicate 3 NotExecuted

testClaimBeforeClosure ∷ Expectation
testClaimBeforeClosure = withCommands defaultScript 3 $ \seam host window → do
  let port = windowCommandPort host
      performed = Performed (ObservationPublished (windowIdentity window) 0)
  claimedTicket ← submitWindowCommand port [] (observeOf window) >>= accepted
  queuedTickets ← replicateM 2 (submitWindowCommand port [] (observeOf window) >>= accepted)
  duringClosure ← newIORef Nothing
  step ← seamExecuteNextScripted seam host $ \_ _ → do
    settled ← atomically (closeWindowCommands host)
    own ← atomically (pollCompletion claimedTicket)
    observed ← statistics host
    writeIORef duringClosure (Just (settled, own, observed))
    synchronizeWindow window >>= \case
      WindowAvailable observation →
        pure (Right (ObservationPublished (windowIdentity window) (observedRevision observation)))
      WindowEnded _ → unexpected "a live window answered as ended"
  closure ← readIORef duringClosure
  after ← seamExecuteNext seam host [window]
  dispositions ← atomically (mapM pollCompletion (claimedTicket : queuedTickets))
  final ← statistics host
  closure `shouldBe` Just (2, Nothing, CommandStatistics 3 0 1 1)
  step `shouldBe` Executed (ticketOrigin claimedTicket) performed
  after `shouldBe` CommandsEnded
  dispositions `shouldBe` [Just performed, Just NotExecuted, Just NotExecuted]
  final `shouldBe` CommandStatistics 3 0 0 0

-- ---------------------------------------------------------------------------
-- Observation requests

testObservationRequests ∷ Expectation
testObservationRequests = do
  extent ← newIORef (800, 600)
  seam ← newSeam defaultScript {scriptWindowSize = \_ → readIORef extent}
  stash ← newIORef Nothing
  asProcessMainThread seam $ entered seam $ \session → do
    withWindow session (hiddenTestWindowConfig "ended" 32 24) (writeIORef stash . Just)
    -- Deliberate misuse: the handle escaped its scope to prove it is rejected.
    ended ← stashed stash
    withWindow session (hiddenTestWindowConfig "first" 64 48) $ \first →
      withWindow session (hiddenTestWindowConfig "second" 64 48) $ \second → do
        host ← newWindowCommandHost session 4
        let port = windowCommandPort host
            submitFor window = onThread forkIO (submitWindowCommand port [] (observeOf window) >>= accepted)
        writeIORef extent (1024, 768)
        requested ← submitFor second
        -- The transaction that first sees the settlement also reads the snapshot.
        (observer, observed) ← forked $ atomically $ do
          disposition ← pollCompletion requested >>= maybe retry pure
          observation ← readSnapshot (windowObservations second)
          pure (disposition, observation)
        awaitBlockedOnSTM observer
        step ← seamExecuteNext seam host [first, second]
        (disposition, observation) ← takeMVar observed >>= either throwIO pure
        firstUnsampled ← current first
        unserved ← submitFor second
        callsBefore ← length <$> seamCalls seam
        unservedStep ← seamExecuteNext seam host [first]
        callsAfter ← length <$> seamCalls seam
        endedTicket ← submitFor ended
        endedStep ← seamExecuteNext seam host [ended, first, second]
        direct ← performWindowCommand host [first, second] (observeOf first)
        firstSampled ← current first
        let published = preparedValue (observedValue observation)
        disposition `shouldBe` Performed (ObservationPublished (windowIdentity second) 1)
        step `shouldBe` Executed (ticketOrigin requested) disposition
        cursorRevision (observedCursor observation) `shouldBe` 1
        observedRevision published `shouldBe` 1
        observedWindow published `shouldBe` windowIdentity second
        observedLogicalExtent published `shouldBe` Observed (Extent 1024 768)
        observedRevision firstUnsampled `shouldBe` 0
        unservedStep `shouldBe` Executed (ticketOrigin unserved) (Rejected (WindowNotServed (windowIdentity second)))
        callsAfter `shouldBe` callsBefore
        endedStep `shouldBe` Executed (ticketOrigin endedTicket) (Rejected (WindowAlreadyEnded (windowIdentity ended)))
        direct `shouldBe` Performed (ObservationPublished (windowIdentity first) 1)
        observedLogicalExtent firstSampled `shouldBe` Observed (Extent 1024 768)

-- ---------------------------------------------------------------------------
-- Support

-- | A seam session with one hidden window and a command host of the given
-- capacity, on the designated process main thread.
withCommands ∷ SeamScript → Integer → (Seam → WindowCommandHost → Window → IO a) → IO a
withCommands script capacity body = do
  seam ← newSeam script
  asProcessMainThread seam $ entered seam $ \session →
    withWindow session (hiddenTestWindowConfig "commanded" 64 48) $ \window → do
      host ← newWindowCommandHost session capacity
      body seam host window

observeOf ∷ Window → WindowCommand
observeOf = observeWindowCommand . windowIdentity

accepted ∷ SubmitResult → IO CompletionTicket
accepted (SubmitAccepted ticket) = pure ticket
accepted other = unexpected ("the submission was not admitted: " <> show other)

statistics ∷ WindowCommandHost → IO CommandStatistics
statistics host = atomically (commandStatistics host)

-- | Run an action on a new, unbound thread, which is never the owner.
forked ∷ IO a → IO (ThreadId, MVar (Either SomeException a))
forked action = do
  outcome ← newEmptyMVar
  thread ← forkIO (try action >>= putMVar outcome)
  pure (thread, outcome)

-- | Wait until @target@ is blocked in a transaction, so an example knows a wait
-- has begun without guessing at a delay.
awaitBlockedOnSTM ∷ ThreadId → IO ()
awaitBlockedOnSTM target =
  threadStatus target >>= \case
    ThreadBlocked BlockedOnSTM → pure ()
    ThreadFinished → unexpected "the thread finished instead of waiting"
    ThreadDied → unexpected "the thread died instead of waiting"
    _ → yield *> awaitBlockedOnSTM target

isCancellation ∷ Either SomeException a → Bool
isCancellation (Left caught) = fromException caught == Just ThreadKilled
isCancellation (Right _) = False

testComponent ∷ Component
testComponent = unsafeComponent "test.commands"

-- | @GLFW_PLATFORM_ERROR@.
platformErrorCode ∷ Int
platformErrorCode = 0x00010008
