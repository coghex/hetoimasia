-- | Ending a rig run at each boundary of the graphics owner's start (#612).
--
-- The six examples that hold the owner inside its startup, and the one whose exit hook waits for an owner the body publishes, strand
-- the protected exit when the run ends before the body has begun to release what they hold. This module is the harness that proves
-- they no longer do: a 'Cutting' says where the run is cut, how, and whether the fixture's rescue is in force, and the examples it
-- builds judge that the exit finishes and propagates what was injected, or (for the control) that the same fixture without its
-- rescue does not.
--
-- = The boundaries
--
-- Derived from the source (@Owner/Start.hs@, @Owner/Lifetime.hs@, @Foundation/Worker/Startup.hs@, @Runtime/Application.hs@):
--
-- * 'BeforePublication': the owner's worker is registered and forked and its handle is not yet published. The host hook
--   'Private.ownerBoundary' is called with 'Private.OwnerBeforePublication' at the start of the preparation step.
-- * 'AfterPublication': the handle is published, at the end of the preparation step and before the gate that lets the worker run
--   any of its definition opens (#613). The same hook, with 'Private.OwnerPublished'.
-- * 'AwaitingStartup': the gate is open and the start is about to wait for the worker's startup (#613). The same hook, with
--   'Private.OwnerAwaitingStartup'. The worker is held, by the worker hook 'Private.ownerWorkerBoundary', in its startup before it
--   acknowledges, so it has not entered its run action however the scheduler runs it, and the cut waits until it is observed held.
-- * 'AwaitingEntry': the same instant of the starting thread, with the worker held instead after it acknowledged and before the run
--   action's first masked step (#613): its run exit is recorded and the action never ran.
-- * 'AfterStart': the owner has started and its handle is published; the start has not returned it. The same hook, with
--   'Private.OwnerStarted'.
-- * 'StartupCallback': the application's startup callback, which the runner calls after supervision, the quiescence guard and the
--   first runtime check, and before the second. The rig's own callback ('ownedHostAt').
-- * 'BodyEntry': the example's body, at its first statement and before its first masked step.
--
-- The first four are cut before the owner's run action has begun, so the worker is drained without ever running it and the protected
-- exit withdraws the owner (#613): the judgement for them is that the exit finished without waiting for destruction evidence, that
-- nothing the backend owns was asked for, and that the failure carries the abandoned-start evidence of the worker that was drained.
--
-- = The states
--
-- Each boundary is crossed with three ways of ending the run: a failure the boundary raises ('CutFails'), a cancellation that is
-- already pending when the run reaches the boundary and is received at the first point the run is unmasked ('CutPending'), and a
-- cancellation delivered while the run is parked at the boundary ('CutDelivered').
module Test.GLFW.Owner.Fixture.Cut
  ( Boundary (..)
  , allBoundaries
  , CutState (..)
  , allStates
  , Cutting (..)
  , uncut
  , withCutting
  , ownedHostCut
  , heldBody
  , boundaryExamples
  , boundaryControls
  , stalledSnapshots
  , pendingProtocolExample
  ) where

import Control.Concurrent (ThreadId, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , check
  , modifyTVar'
  , newTVarIO
  , orElse
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception
  ( AsyncException (UserInterrupt)
  , SomeException
  , finally
  , fromException
  , mask
  , throwIO
  , try
  , uninterruptibleMask_
  )
import Control.Monad (forM_, join, replicateM_, unless, void, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isJust, isNothing)
import GHC.Conc (BlockReason (BlockedOnException, BlockedOnMVar), ThreadStatus (..), threadCapability, threadStatus)
import GHC.IO (unsafeUnmask)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Worker (Completion (..), RunEnd (..), RunExit (..), WorkerEvidence (..), pollCompletion, workerEvidence)
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import Hetoimasia.GLFW.Internal.Seam (Seam)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Test.GLFW.Owner.Fixture.Journal (Note (..), Scene, journalled, ordered)
import Test.GLFW.Owner.Fixture.Rig (Observer (..), Rig (..), ownedHostObserved)
import Test.GLFW.Support
  ( Boom (..)
  , Scope
  , boundedExample
  , endedAndJoined
  , holdForever
  , recordingThreads
  , unexpected
  , withDeferredThreadVia
  )
import Test.Hspec (Expectation, Spec, it, shouldBe, shouldSatisfy)
import Test.Support.Owned (withOwnedBoundThreadOpening, withOwnedThreadOn, withOwnedThreadOpening)

-- | Where a run is cut.
data Boundary
  = BeforePublication
  | AfterPublication
  | AwaitingStartup
  | AwaitingEntry
  | AfterStart
  | StartupCallback
  | BodyEntry
  deriving (Eq, Ord, Show, Enum, Bounded)

allBoundaries ∷ [Boundary]
allBoundaries = [minBound .. maxBound]

-- | The boundaries cut before the owner's run action has begun (#613): the owner owns nothing, and the exit withdraws it.
neverRan ∷ Boundary → Bool
neverRan boundary = boundary `elem` [BeforePublication, AfterPublication, AwaitingStartup, AwaitingEntry]

-- | The boundary whose hook performs the cut: 'AwaitingEntry' is 'AwaitingStartup''s instant with a different worker hold.
hookOf ∷ Boundary → Boundary
hookOf AwaitingEntry = AwaitingStartup
hookOf boundary = boundary

-- | Where the worker is held for a cut at this boundary, if it is.
workerHold ∷ Boundary → Maybe Private.OwnerWorkerBoundary
workerHold = \case
  AwaitingStartup → Just Private.OwnerWorkerStarting
  AwaitingEntry → Just Private.OwnerWorkerEntering
  _ → Nothing

-- | How a run is cut at a boundary.
data CutState
  = -- | The boundary raises a failure of its own.
    CutFails
  | -- | A cancellation is queued for the run while it is masked and is received when it is next unmasked after the boundary.
    CutPending
  | -- | The run parks at the boundary and a cancellation is delivered to it there.
    CutDelivered
  deriving (Eq, Show, Enum, Bounded)

allStates ∷ [CutState]
allStates = [minBound .. maxBound]

-- | What a fixture is run under: where it is cut (nowhere, for an ordinary run), whether its own rescue is in force, the gate it
-- holds the owner at, and what the harness reads afterwards.
data Cutting = Cutting
  { cuttingBoundary ∷ !(Maybe Boundary)
  , cuttingAction ∷ IO ()
    -- ^ The cut itself, performed on the run's main thread at the boundary.
  , cuttingRescued ∷ !Bool
    -- ^ Whether the fixture's rescue is in force. The control runs the fixture without it.
  , cuttingGate ∷ !(TVar Bool)
    -- ^ The gate the fixture holds its owner at. A fixture takes it from here instead of creating its own, so the harness can open it
    -- from outside the run when the control must end.
  , cuttingRig ∷ !(IORef (Maybe Rig))
    -- ^ The fixture's rig, recorded by the fixture, so the harness can read its journal.
  , cuttingSnapshots ∷ !(TVar Int)
    -- ^ How many turns of the exit's wait for the owner's destruction have taken their snapshot.
  , cuttingFinished ∷ !(TVar Bool)
    -- ^ Set by a control when the unrescued fixture's run ended, so the control never waits for a strand that did not happen.
  , cuttingCrossed ∷ !(IORef [Boundary])
    -- ^ Every boundary the run crossed, oldest first, recorded as it was reached and before the cut was performed there: the observed
    -- boundary of a cell, and the proof that a failure meant for a pre-callback boundary was not raised after the body began.
  , cuttingParked ∷ !(TVar Bool)
    -- ^ Set by the worker hook when the worker is held where the cutting holds it: a cut at 'AwaitingStartup' or 'AwaitingEntry'
    -- waits for it, so the worker's state at the cut is observed, not assumed.
  , cuttingFailure ∷ !(IORef (Maybe SomeException))
    -- ^ The failure the run ended with, caught on the designated main thread where it still carries its context (#613).
  , cuttingOwner ∷ !(IORef (Maybe (GraphicsOwner Scene)))
    -- ^ The owner, recorded the moment its handle was published, which a start that is abandoned never returns (#613).
  , cuttingRelease ∷ !(IORef (IO ()))
    -- ^ What else the control does, besides opening the gate, to end a run the unrescued fixture stranded somewhere other than at
    -- its gate. A fixture that strands only there leaves it alone.
  }

-- | An ordinary run: no cut, the rescue in force.
uncut ∷ IO Cutting
uncut = do
  gate ← newTVarIO False
  rigs ← newIORef Nothing
  snapshots ← newTVarIO 0
  release ← newIORef (pure ())
  crossed ← newIORef []
  finished ← newTVarIO False
  parked ← newTVarIO False
  failure ← newIORef Nothing
  owner ← newIORef Nothing
  pure (Cutting Nothing (pure ()) True gate rigs snapshots finished crossed parked failure owner release)

-- | Build a cutting for one cell and run the body with it, inside the scope of the thread that delivers the cancellation.
-- The thread is owned: however the body ends it has been stopped and joined before this returns, and the thread is recorded so the
-- caller can judge it.
withCutting ∷ IORef [ThreadId] → CutState → Boundary → Bool → (Cutting → IO r) → IO r
withCutting recorded state boundary rescued body = do
  gate ← newTVarIO False
  rigs ← newIORef Nothing
  snapshots ← newTVarIO 0
  release ← newIORef (pure ())
  crossed ← newIORef []
  let scope ∷ Scope
      scope = recordingThreads recorded withOwnedThreadOpening
  withDeferredThreadVia scope (pure ()) (\target → throwTo target UserInterrupt) $ \_ handOver → do
    let cut = case state of
          CutFails → throwIO Boom
          CutDelivered → myThreadId >>= handOver >> holdForever
          -- Masked so the cancellation cannot be received before the boundary has been left: the thread that delivers it is blocked
          -- in its throw, which is the one state a cancellation can be pending in.
          -- The sender and the target share a capability (#610's pinned start). On one capability a throw to a masked thread is settled
          -- where it is made: the exception is on the target's queue before the sender is recorded as blocked delivering. Across
          -- capabilities the throw is a message the target's capability takes in when it next looks at its inbox, so no wait on the
          -- sender's status establishes receipt, and the cancellation could arrive anywhere later, away from the boundary it
          -- was made pending at. The run's main thread is a bound thread and can change capability whenever it yields, so the throw is made
          -- while it is blocked on the sender's own hand-over: the sender is started on the capability the target is on, says it is
          -- there, and throws in the same turn, with the target woken on that capability and masked uninterruptibly. The cancellation is
          -- received as that mask ends, inside the scope, which then stops and joins the sender.
          CutPending → pending recorded
    finished ← newTVarIO False
    parked ← newTVarIO False
    failure ← newIORef Nothing
    owner ← newIORef Nothing
    body (Cutting (Just boundary) cut rescued gate rigs snapshots finished crossed parked failure owner release)

-- | Make a cancellation pending against the calling thread, which is protected before the senders exist and receives the cancellation
-- as it is unprotected, inside their scope.
--
-- The whole is under an uninterruptible mask, so the target is protected before anything else is started. The sender is started on the
-- capability the target is on and does three things in this order: it waits until the target is __observed parked__ on the protected
-- hand-over (a runnable thread proves nothing: it may be preempted, and the scheduler can move a runnable bound thread to another
-- capability between any check and the throw); it then checks that the parked target is on its own capability, which a blocked thread
-- stays on; and it throws, on the target's own capability, where the throw is settled where it is made, so that the sender is blocked
-- delivering with the exception queued against the target. The target is not woken by the sender (a bound thread woken by the thread
-- that then throws can move to another capability before the throw is made) but by a second thread on the same capability, which waits
-- for the sender to be blocked delivering and only then hands the target the confirmation. The target lifts the mask for the instant
-- it takes to receive the cancellation, inside the scope, which stops and joins both threads (recorded for the caller's judgement). A
-- sender that found the parked target elsewhere reports it and the whole is tried again.
pending ∷ IORef [ThreadId] → IO ()
pending recorded = newIORef Nothing >>= pendingWith (pure ()) recorded

-- | 'pending' with an action the target performs, masked, before it parks (the cut where it is preempted before it parks), and the
-- status the sender saw the target in when it threw.
pendingWith ∷ IO () → IORef [ThreadId] → IORef (Maybe ThreadStatus) → IO ()
pendingWith beforePark recorded sawAtThrow = do
  settled ← uninterruptibleMask_ $ do
    me ← myThreadId
    (capability, _) ← threadCapability me
    there ← newEmptyMVar
    let sender = do
          awaitParked me
          (now, _) ← threadCapability me
          threadStatus me >>= writeIORef sawAtThrow . Just
          if now == capability then throwTo me UserInterrupt else void (tryPutMVar there False)
        waker thread = do
          awaitSettled thread
          void (tryPutMVar there True)
    withOwnedThreadOn capability sender $ \sendingThread _ →
      withOwnedThreadOn capability (waker sendingThread) $ \wakingThread _ → do
        atomicModifyIORef' recorded (\known → (sendingThread : wakingThread : known, ()))
        beforePark
        same ← takeMVar there
        when same $ do
          -- Pending, confirmed: the sender is blocked delivering on the target's own capability.
          unsafeUnmask (pure ())
        pure same
  -- Raised above when it was made. Reached only when the sender found the target elsewhere: again, from where it is now.
  -- The preemption is the first attempt's alone: a target that is made to yield again moves again, for ever.
  unless settled (pendingWith (pure ()) recorded sawAtThrow)

-- | Wait, by yielding, until the thread is blocked on an @MVar@: observed, not assumed.
awaitParked ∷ ThreadId → IO ()
awaitParked thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnMVar → pure ()
    _ → yield >> awaitParked thread

-- | The pending protocol's own regression: the target is preempted before it parks (it keeps yielding the capability, runnable, while
-- the sender is ready), and the sender must still throw only once it observes the target parked. The cancellation is raised, both
-- threads are ended and joined, and the status the sender saw when it threw was the parked one.
pendingProtocolExample ∷ Spec
pendingProtocolExample =
  it "makes a cancellation pending only against a target it has observed parked, however long the target is preempted first (#612)" $
    boundedExample $ do
      recorded ← newIORef []
      saw ← newIORef Nothing
      finished ← newEmptyMVar
      -- A bound thread, as the run's main thread is: an unbound one is moved between capabilities while it yields, and the sender's
      -- check would keep finding it elsewhere.
      withOwnedBoundThreadOpening (pure ()) (try (pendingWith (replicateM_ 500 yield) recorded saw) >>= putMVar finished) $ \_ _ → do
        outcome ← readMVar finished
        case outcome of
          Left caught → caught `shouldSatisfy` (\failure → fromException failure == Just UserInterrupt)
          Right () → unexpected "the cancellation was never raised"
        readIORef saw >>= (`shouldBe` Just (ThreadBlocked BlockedOnMVar))
        endedAndJoined recorded >>= (`shouldBe` True)

-- | Wait, by yielding, until the thread is blocked delivering its exception or has ended.
awaitSettled ∷ ThreadId → IO ()
awaitSettled thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnException → pure ()
    ThreadFinished → pure ()
    ThreadDied → pure ()
    _ → yield >> awaitSettled thread

-- | 'ownedHostAt' with the cutting's boundaries and its exit rescue. The cut is performed at its boundary and nowhere else. When the
-- rescue is in force the exit's wait for the owner's destruction opens the cutting's gate on every turn, whatever the run was cut in
-- the middle of, which is the earliest the exit can; the body's own rescue is 'heldBody'.
ownedHostCut
  ∷ Cutting
  → Private.HostHooks
  → Logger
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHostCut cutting hooks logger seam config ownerConfig action =
  ownedHostObserved hooked observer (at StartupCallback) logger seam config ownerConfig $ \host owner control →
    at BodyEntry >> action host owner control
  where
    observer =
      Observer
        { observedOwner = \owner → writeIORef (cuttingOwner cutting) (Just owner)
        , observedFailure = \failure → writeIORef (cuttingFailure cutting) (Just failure)
        }
    -- Records the boundary the run reached and performs the cut there. The two boundaries that share a hook are told apart by the
    -- cutting's own boundary, and the cut waits for the worker to be observed held where the cutting holds it.
    at boundary = do
      atomicModifyIORef' (cuttingCrossed cutting) (\crossed → (crossed <> [boundary], ()))
      when (fmap hookOf (cuttingBoundary cutting) == Just boundary) $ do
        when (isJust (workerHold boundary')) (atomically (readTVar (cuttingParked cutting) >>= check))
        cuttingAction cutting
      where
        boundary' = maybe boundary id (cuttingBoundary cutting)
    hooked =
      hooks
        { Private.ownerBoundary = \reached → do
            case reached of
              Private.OwnerBeforePublication → at BeforePublication
              Private.OwnerPublished → at AfterPublication
              Private.OwnerAwaitingStartup → at AwaitingStartup
              Private.OwnerStarted → at AfterStart
            Private.ownerBoundary hooks reached
        , -- Held until the starter cancels it, which is how production ends a worker whose start was abandoned.
          Private.ownerWorkerBoundary = \reached → do
            when ((cuttingBoundary cutting >>= workerHold) == Just reached) $ do
              atomically (writeTVar (cuttingParked cutting) True)
              holdForever
            Private.ownerWorkerBoundary hooks reached
        , Private.afterDestructionSnapshot = do
            -- Opened before the snapshot is counted: a control that has seen the count has seen whether the gate was opened.
            when (cuttingRescued cutting) (atomically (writeTVar (cuttingGate cutting) True))
            atomically (modifyTVar' (cuttingSnapshots cutting) (+ 1))
            Private.afterDestructionSnapshot hooks
        }

-- | The body of a fixture that holds its owner at the cutting's gate: when the rescue is in force the gate is opened however the body
-- ends. The step is masked, so a cancellation cannot land between its being installed and the body's start; one that lands before it
-- (the body's entry) is the exit's to rescue.
heldBody ∷ Cutting → IO a → IO a
heldBody cutting body
  | cuttingRescued cutting = mask $ \restore → restore body `finally` open
  | otherwise = body
  where
    open = atomically (writeTVar (cuttingGate cutting) True)

-- | Wait until the exit's wait for the owner's destruction has taken at least this many snapshots.
stalledSnapshots ∷ Cutting → Int → STM ()
stalledSnapshots cutting count = readTVar (cuttingSnapshots cutting) >>= check . (>= count)

-- | The examples that cut one fixture at every boundary in every state. Each judges that the run raised what was injected and
-- nothing else, that the thread that delivered it has ended and been joined, that the owner terminated and was destroyed once the
-- gate it was held at was released, and that the session was torn down.
boundaryExamples ∷ String → (Cutting → IO ()) → Spec
boundaryExamples what fixture =
  forM_ allBoundaries $ \boundary →
    forM_ allStates $ \state →
      it (describeCut what boundary state <> (if neverRan boundary && boundary /= BeforePublication then " (#613)" else " (#612)")) $ boundedExample (cutRuns state boundary fixture)

-- | The negative controls for the cells where the fixture without its rescue strands (a held owner exists, which is every boundary
-- after the owner's run action began; the earlier ones leave nothing held, because the exit withdraws the owner, #613): the unrescued fixture's exit waits for the held owner, which is recorded first, and only
-- then is the gate opened from outside the run and the run joined.
boundaryControls ∷ String → (Cutting → IO ()) → Spec
boundaryControls what fixture =
  forM_ [boundary | boundary ← allBoundaries, not (neverRan boundary)] $ \boundary →
    forM_ allStates $ \state →
      it ("negative control: " <> describeCut what boundary state <> ", unrescued (#612)") $
        boundedExample (cutStrands state boundary fixture)

describeCut ∷ String → Boundary → CutState → String
describeCut what boundary state =
  "finishes the exit of " <> what <> " when the run " <> describeState state <> " " <> describeBoundary boundary
  where
    describeState = \case
      CutFails → "fails"
      CutPending → "is cancelled, the cancellation pending"
      CutDelivered → "is cancelled while parked"
    describeBoundary = \case
      BeforePublication → "before the owner's handle is published"
      AfterPublication → "after the owner's handle is published and before its worker may run"
      AwaitingStartup → "while the start waits for a worker held in its startup"
      AwaitingEntry → "while the start waits for a worker held after it acknowledged, before its run action"
      AfterStart → "after the owner has started and before the start returns it"
      StartupCallback → "in the application's startup callback"
      BodyEntry → "at the body's entry, before its first masked step"

-- | What the injected cut raises, as itself.
raisedAsInjected ∷ CutState → SomeException → Bool
raisedAsInjected CutFails caught = fromException caught == Just Boom
raisedAsInjected _ caught = fromException caught == Just UserInterrupt

cutRuns ∷ CutState → Boundary → (Cutting → IO ()) → Expectation
cutRuns state boundary fixture = do
  recorded ← newIORef []
  withCutting recorded state boundary True $ \cutting → do
    -- Run unmasked, as an application's main thread is. The run's bound thread inherits the state of its caller, and an example's own
    -- thread may be masked; a cancellation that is pending is then received at whatever interruptible point comes first instead of at
    -- the boundary, which can be the startup wait.
    outcome ← try (unsafeUnmask (fixture cutting))
    case outcome of
      Right () → unexpected "the cut run returned instead of raising what was injected"
      Left caught → caught `shouldSatisfy` raisedAsInjected state
    -- The run reached the boundary it was cut at, having crossed every earlier one in order and none after it: a failure meant for a
    -- boundary before the body never became one raised by the body.
    -- The run reached the boundary it was cut at, having crossed every earlier one in order and none after it: a failure meant for a
    -- boundary before the body never became one raised by the body.
    readIORef (cuttingCrossed cutting) >>= (`shouldBe` [reached | reached ← allBoundaries, reached /= AwaitingEntry, reached <= hookOf boundary])
    judgeFinished boundary cutting
  endedAndJoined recorded >>= (`shouldBe` True)

-- | The exit finished: the session is torn down, and an owner whose run action began has been destroyed after its gate was released.
-- An owner cut before its run action began (#613) owned nothing: the exit never waited for its destruction, the backend was asked for
-- nothing, and the failure carries the evidence of the worker that was drained without running.
judgeFinished ∷ Boundary → Cutting → IO ()
judgeFinished boundary cutting = do
  rig ← readIORef (cuttingRig cutting) >>= maybe (unexpected "the fixture recorded no rig") pure
  notes ← journalled (rigJournal rig)
  notes `shouldSatisfy` elem SessionEnded
  if neverRan boundary
    then do
      -- Nothing the backend owns was asked for, acquired or released.
      filter backendNote notes `shouldBe` []
      -- The exit never began the wait for the owner's destruction, which is the wait that cannot end.
      readTVarIO (cuttingSnapshots cutting) >>= (`shouldBe` 0)
      readTVarIO (cuttingGate cutting) >>= (`shouldBe` False)
      judgeAbandoned boundary cutting
    else do
      -- The owner was destroyed before the session was released (D-33's order), and its held gate was opened to let it.
      ordered notes [OwnerDestruction, SessionEnded]
      readTVarIO (cuttingGate cutting) >>= (`shouldBe` True)
      -- The start had returned: no abandoned-start evidence, and the exit had an owner to wait for.
      failure ← readIORef (cuttingFailure cutting) >>= maybe (unexpected "the run's failure was not observed") pure
      length [() | AbandonedStart _ ← workerEvidence failure] `shouldBe` 0
  where
    backendNote = \case
      OwnerStartup → True
      Constructed _ → True
      Stepped → True
      TargetRetirement _ → True
      OwnerRetirement → True
      OwnerDestruction → True
      DestroyRaised _ → True
      _ → False

-- | The failure the run ended with, caught where it still carries its context, holds the abandoned-start evidence of exactly one
-- worker, drained: the one the owner was published for, whose run action never began (#613). For a worker held in its startup the
-- foundation records that it never entered a run; for one held after it acknowledged it records a run that was cancelled, which the
-- owner's own flag, not that record, tells apart from an action that ran.
judgeAbandoned ∷ Boundary → Cutting → IO ()
judgeAbandoned boundary cutting = do
  failure ← readIORef (cuttingFailure cutting) >>= maybe (unexpected "the run's failure was not observed") pure
  case [summary | AbandonedStart summary ← workerEvidence failure] of
    [summary] → case (boundary, completionExit summary) of
      (AwaitingEntry, RunExited RunCancelled _) → pure ()
      (AwaitingEntry, other) → unexpected ("the held worker's run exit was " <> show other)
      (_, RunNotEntered) → pure ()
      (_, other) → unexpected ("the drained worker's run exit was " <> show other)
    other → unexpected ("the failure carried " <> show (length other) <> " abandoned starts")
  -- The owner was published to the exit and then withdrawn from it: it exists, and its worker is terminal.
  published ← readIORef (cuttingOwner cutting)
  case (boundary, published) of
    (BeforePublication, Nothing) → pure ()
    (BeforePublication, Just _) → unexpected "an owner was published before its publication"
    (_, Nothing) → unexpected "the owner was never published"
    (_, Just owner) → atomically (isJust <$> pollCompletion (graphicsOwnerWorker owner)) >>= (`shouldBe` True)

cutStrands ∷ CutState → Boundary → (Cutting → IO ()) → Expectation
cutStrands state boundary fixture = do
  recorded ← newIORef []
  done ← newEmptyMVar @(Either SomeException ())
  withCutting recorded state boundary False $ \cutting → do
    let open = atomically (writeTVar (cuttingGate cutting) True)
    withOwnedThreadOpening open (try (fixture cutting) >>= \ended → atomically (writeTVar (cuttingFinished cutting) True) >> putMVar done ended) $ \_ _ →
      ( do
          -- The exit is waiting for a destruction that cannot come: it has taken its first snapshot of the owner's terminal record, which
          -- holds no evidence, and its owner is held at its gate, so nothing can end the wait but the release below.
          atomically (stalledSnapshots cutting 1 `orElse` (readTVar (cuttingFinished cutting) >>= check))
          stranded ← isNothing <$> tryReadMVar done
          rig ← readIORef (cuttingRig cutting) >>= maybe (unexpected "the fixture recorded no rig") pure
          notes ← journalled (rigJournal rig)
          gate ← readTVarIO (cuttingGate cutting)
          -- The judgement, recorded before anything is released: the owner is still held at its gate, which nothing opened, and the
          -- run has not finished.
          gate `shouldBe` False
          stranded `shouldBe` True
          -- Nothing was released while the owner was unfinished: the session is still open.
          notes `shouldSatisfy` notElem SessionEnded
        )
        `finally` ( do
                      -- The rescue that does not depend on the stuck exit: the gate opened from here, then the run joined.
                      open
                      join (readIORef (cuttingRelease cutting))
                      void (readMVar done)
                  )
