-- | Examples for the protected host lifetime and its owner-thread retirement
-- boundary, over the test seam.
--
-- Each example runs a whole application through
-- 'runProtectedWindowApplication' on a thread the seam treats as the process
-- main thread, with a protected host built over a seam session. The exit order,
-- the drain, the stall policy, and the outcome settling are the production
-- code, and nothing initializes GLFW.
--
-- Every example asserts an /order of flags/, never a time. One journal collects
-- them all: the scripted graphics owners note the obligations they end and the
-- dependents they dispose, the seam's own destroy and terminate hooks note the
-- native calls, and a scripted parent notes its release. One list therefore
-- shows admission closing, each chain retiring, each window being destroyed,
-- the session ending, and the parent being released, in the order they really
-- happened.
--
-- Threads are coordinated with STM and 'MVar's, never with a sleep. The seam's
-- finite wait blocks until an empty event has been posted, which is what the
-- session's internal wake does, so a drain round with nothing to do really
-- waits and a completion published from another thread really ends that wait.
module Test.GLFW.Protected (spec) where

import Control.Concurrent (ThreadId, killThread, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , check
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , finally
  , fromException
  , catch
  , mask_
  , throw
  , throwIO
  , try
  , tryWithContext
  , uninterruptibleMask_
  )
import Data.Unique (newUnique)
import Control.Monad (forM, forM_, unless, void, when)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)
import GHC.Conc (BlockReason (BlockedOnMVar, BlockedOnException, BlockedOnSTM), ThreadStatus (..), threadStatus)
import qualified Data.Map.Strict as Map
import Data.List (sort)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log
  ( Component
  , LogEntry (..)
  , Logger
  , callbackSink
  , componentText
  , defaultLogFilter
  , mkLoggerWith
  , systemMetadata
  , unsafeComponent
  )
import Hetoimasia.Foundation.Recovery (Disposition (..))
import Hetoimasia.Foundation.Resource
  ( Scoped
  , allocResource
  , cleanupFailureException
  , cleanupFailureLabel
  , cleanupFailures
  , withScoped
  )
import Hetoimasia.Foundation.Worker (WorkerDefinition, awaitStopRequest, workerDefinition)
import Hetoimasia.GLFW.Internal.Attachment
  ( AttachmentConfigRejected
  , AttachmentEvidence (..)
  , AttachmentModel
  , OwnerAuthority
  , Registered (..)
  , attachWindow
  , hostIdentity
  , newAttachmentModel
  , registerWindow
  , AttachmentFailure (..)
  , AttachmentPhase (..)
  , AttachmentView (..)
  )
import Hetoimasia.GLFW.Internal.Window (windowSessionIdentity)
import Hetoimasia.GLFW.Internal.Seam
  ( NativeCall (DestroyWindow)
  , Reporter
  , Seam
  , SeamScript (..)
  , asProcessMainThread
  , defaultScript
  , newSeam
  , reportError
  , seamCalls
  , seamSession
  )
import Hetoimasia.GLFW.Command (SubmitResult (SubmitClosed), createWindowCommand, submitWindowCommand)
import Hetoimasia.GLFW.Demand (PublishResult (DemandSlotClosed), immediateDemand, publishDemand)
import Hetoimasia.GLFW.Internal.Connection (ConnectionStatus (..))
import Hetoimasia.GLFW.Session
  ( Backend (Wayland)
  , ConnectionCause (..)
  , ConnectionFailed (..)
  , EventBoundary (..)
  , SessionConfig (requestedBackend)
  , defaultSessionConfig
  )
import Hetoimasia.GLFW.Window
import Hetoimasia.Runtime.Application (runManagedApplication)
import Hetoimasia.Runtime.GLFW.Internal
import Hetoimasia.Runtime.GLFW.Internal.Retirement (retainedFailureLimit)
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import qualified Hetoimasia.Runtime.Logging as Logging
import Hetoimasia.Runtime.Reporting (DiagnosticFailure (..))
import Hetoimasia.Runtime.Supervision
  ( Recognition (..)
  , Role (..)
  , RuntimeControl
  , SupervisedStart (..)
  , SupervisedWorker
  , WorkerPolicy (..)
  , awaitSupervised
  , startSupervised
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Test.GLFW.Support
  ( Ending (..)
  , Scope
  , SinkFailed (..)
  , SinkMark (..)
  , awaitParked
  , boundedExample
  , caughtAs
  , diagnosticMarks
  , failingSink
  , flushed
  , newSinkTrace
  , exitFinishes
  , ownedEnds
  , endedAndJoined
  , recordingThreads
  , runEnding
  , withMainThreadKeepingContextVia
  , raisedWith
  , retainedAs
  , retainedDiagnostics
  , sinkFailingOn
  , sinkMarks
  , traced
  , unexpected
  , unownedLeaks
  , withMainThread
  , withMainThreadVia
  )
import Test.Hspec (Expectation, Spec, before_, describe, it, shouldBe, shouldReturn, shouldSatisfy)
import Test.Support.Owned (withOwnedBoundThreadOpening, withOwnedThread, withOwnedThreadOpening)
import Data.Foldable (for_)

spec ∷ Spec
spec = before_ clearRegistered $ describe "GLFW protected host" $ do
  describe "exit paths" $ do
    it "retires its attachment, then destroys the window and ends the session, on a normal return"
      (boundedExample (testExitPath ReturnsNormally))
    it "keeps the action's failure primary and still retires before any window or session is released"
      (boundedExample (testExitPath ActionFails))
    it "retires after a failed startup, with its workers already drained"
      (boundedExample (testExitPath StartupFails))
    it "retires after the owner loop fails"
      (boundedExample (testExitPath LoopFails))
    it "retires after a latched supervised failure, which asked its workers to stop before quiescence"
      (boundedExample (testExitPath SupervisionLatches))
    it "retires before it re-raises a cancellation delivered to the action"
      (boundedExample testCancelledAction)
    it "retires after a dependent construction that failed before supervision was ever entered"
      (boundedExample testDependencyConstructionFails)

  describe "the host's own close" $ do
    it "closes attachment admission and retires even when the application installed no quiescence hook"
      (boundedExample testOmittedQuiescence)
    it "refuses an attachment to a host built with allocWindowHost, before any effect"
      (boundedExample testUnprotectedHostRefuses)

  describe "construction ownership" $ do
    it "retires a construction whose owned rollback established safety, publishing nothing usable"
      (boundedExample (testConstructionFailure RollbackSafe))
    it "retains a construction whose rollback could not, keeping its original failure and every owed fact"
      (boundedExample (testConstructionFailure RollbackUnsafe))
    it "enters no consumer, and attaches nothing, when the host's own setup fails"
      (boundedExample testHostSetupFails)
    it "counts a cancellation delivered during construction and still retires what it left registered"
      (boundedExample testCancelledConstruction)
    it "drains an attachment made on the handoff into the consumer, which then fails"
      (boundedExample (testHandoffAttachmentDrained ByFailure))
    it "drains one made there and then cancelled"
      (boundedExample (testHandoffAttachmentDrained ByCancellation))
    it "retains an attachment whose rollback itself failed, rather than stranding it in construction"
      (boundedExample testRollbackFails)
    it "retains one whose rollback was cancelled too, keeping both cancellations and finishing the drain"
      (boundedExample testCancelledRollback)
    it "re-raises a cancellation the rollback received after a construction that failed synchronously"
      (boundedExample testRollbackCancelledAfterFailure)
    it "catches a construction and a rollback whose results raise only when demanded"
      (boundedExample testLazyCallbackResults)

  describe "the drain" $ do
    it "retains repeated cancellation as evidence, establishes no fact, and re-raises one only once retirement is safe"
      (boundedExample testRepeatedCancellation)
    it "destroys a safely retired chain's closed window while another chain, the session, and a parent are retained"
      (boundedExample testIndependentChains)
    it "keeps a stalled attachment and its window until independent evidence arrives, reporting the stall once"
      (boundedExample testStalledThenEvidence)
    for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) → do
      it ("has ended and joined a runner parked in the drain's first wait, which absorbs the cleanup's one kill, when the example body " <> label) $
        boundedExample (ownedEnds ending repeatedCancellationEndedEarlyScenario True)
      it ("negative control: a plain forkOS start leaves the runner parked in the drain's wait when the example body " <> label) $
        boundedExample (unownedLeaks ending repeatedCancellationEndedEarlyScenario True)
      it ("has ended and joined a runner parked between its first attachment and the publication of its handles when the example body " <> label) $
        boundedExample (ownedEnds ending runnerPartialScenario True)
      for_ [0 .. 5] $ \k →
        it ("finishes the exit when the example body " <> label <> " at setup step " <> show k <> " of the two-chain fixture (#593)") $
          boundedExample (ownedEnds ending (protectedSetupScenario k) False)
      it ("has ended and joined a runner parked in its construction, whose rollback waits at a second gate, when the example body " <> label) $
        boundedExample (ownedEnds ending parkedConstructionScenario True)
      it ("negative control: a plain forkOS start leaves the runner parked in its construction when the example body " <> label) $
        boundedExample (unownedLeaks ending parkedConstructionScenario True)
      it ("finishes the exit when the example body " <> label <> " before the runner has registered its owner, which then registers and attaches after the cleanup began, one that may be absorbed (#593)") $
        boundedExample (ownedEnds ending runnerBeforeRegistrationScenario True)
      it ("finishes the exit when the example body " <> label <> " while the runner's owner is registered and under construction, and attached after the cleanup began (#593)") $
        boundedExample (ownedEnds ending runnerDuringConstructionScenario True)
      for_ [0 .. 5] $ \k →
        it ("finishes the exit when the example body " <> label <> " at step " <> show k <> " of the inbox fixture (#593)") $
          boundedExample (exitFinishes ending (inboxSetupScenario k))
      it ("has ended and joined an evidence supplier waiting for an owner that never exists when the example body " <> label) $
        boundedExample (ownedEnds ending supplierScenario False)
      it ("negative control: an unowned start leaves the evidence supplier waiting for an owner that never exists when the example body " <> label) $
        boundedExample (unownedLeaks ending supplierScenario False)
    for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) →
      for_ [("after its first owner attached", True), ("while the runner is parked before its host", False)] $ \(where', after) →
        it ("finishes the exit when the example body " <> label <> " " <> where' <> ", before the explicit rescue (#593)") $
          boundedExample (ownedEnds ending (stickyBeforeRescueScenario after) True)
    it "releases an owner the runner registers after the cleanup began, before it built its host (#593)"
      (boundedExample (stickyRegistration False))
    it "releases an owner the runner registers after the cleanup began, after the snapshot that cleanup took (#593)"
      (boundedExample (stickyRegistration True))
    it "contains a declaration that fails after acquisition, retiring on independent evidence before it settles"
      (boundedExample testMetadataFailsInDrain)
    it "retains a stalled diagnostic's own failure without unwinding anything it is holding"
      (boundedExample testStallDiagnosticFails)
    it "destroys a window that became safe before the drain, in a round that made no progress at all"
      (boundedExample testDeferredWindowRetired)
    it "admits one completion notice per fact per window the host may hold"
      (boundedExample testInboxHoldsEveryFact)
    it "settles a cancellation queued in the handoff out of construction, rather than skipping its exit"
      (boundedExample testCancelledAtHandoff)
    it "refuses a completion published once it has found retirement complete"
      (boundedExample testPublicationCloses)
    it "withdraws an interrupted step rather than running it again, and reports the stall"
      (boundedExample testInterruptedStepWithdrawn)
    it "revives a withdrawn path for new evidence only, never for a duplicate or a refused notice"
      (boundedExample testOnlyNewEvidenceRevives)
    it "defers a cancellation queued as the last fact is certified until the window is destroyed"
      (boundedExample testCancelledIntoDisposal)
    it "refuses a command or a demand admitted after its exit has closed the host"
      (boundedExample testLateAdmissionRefused)
    it "reports a stalled chain even while another chain answers that it may still progress"
      (boundedExample testStallReportedBesideAwaiting)
    it "keeps the body's failure primary with the drain's retained beside it"
      (boundedExample testBodyFailureStaysPrimary)
    it "retains two drain failures in the order it found them"
      (boundedExample testRetainedEvidenceOrder)
    it "catches a stall diagnostic whose sink's result raises only when demanded"
      (boundedExample testLazyStallDiagnosticFails)

  describe "a failed stall warning" $ do
    it "settles as a diagnostic failure, with no second write and no final flush"
      (boundedExample testStallWarningFailsIsDiagnostic)
    it "keeps the body's failure primary, retaining the warning's own failure beside it unreported"
      (boundedExample testStallWarningFailsBesideAPrimary)
    it "defers a cancellation delivered at its sink as a cancellation, unmarked and unflushed"
      (boundedExample testStallWarningCancelledAtItsSink)
    for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) → do
      it ("finishes, with the supplier and the runner ended and joined, when the example body " <> label <> " while the runner is inside its first retirement opportunity, before the stall is counted (#612)") $
        boundedExample $ do
          recorded ← newIORef []
          runEnding ending (stallSinkEndedEarly (recordingThreads recorded withOwnedThreadOpening) (recordingThreads recorded withOwnedBoundThreadOpening))
          endedAndJoined recorded >>= (`shouldBe` True)
      it ("negative control: the same example with nothing opened before the cleanup kill does not finish when the body " <> label <> " (#612)") $
        boundedExample (stallSinkStrands ending)
    it "is retained rather than elided when the drain's retained-failure budget is already full"
      (boundedExample testStallWarningSurvivesAFullBudget)

  describe "a failed wake warning at the protected exit" $ do
    it "settles as a diagnostic failure, with no second write and no final flush"
      (boundedExample testProtectedWakeWarningFailsAtExit)
    it "keeps the action's failure primary, retaining the warning's own failure beside it unreported"
      (boundedExample testProtectedWakeWarningFailsBesideAPrimary)

  describe "failed retirement steps" $ do
    it "keeps a required step's failure and evidence, never marks the attachment safe, and never replays the step"
      (boundedExample (testFailedStep Required))
    it "leaves a recognized optional step unavailable with its evidence, which is still no permission to destroy"
      (boundedExample (testFailedStep Optional))

  describe "a confirmed Wayland connection loss" $ do
    it "is the primary failure when it initiates the failure, and retirement still precedes the window and the session"
      (boundedExample testLossInitiatesFailure)
    it "leaves an earlier failure primary when the drain finds it, retaining the loss beside it"
      (boundedExample testLossFoundDuringCleanup)
    it "supplies no attachment-completion fact: the attachment stays unretired until its own evidence arrives"
      (boundedExample testLossSuppliesNoFacts)

  describe "configuration" $
    it "refuses a window limit below one, below its configured windows, or above the bound its counts derive from"
      (boundedExample testWindowLimitBounds)

  describe "closing an attached window during the run" $ do
    it "begins retirement without destroying it, and destroys it only once every fact is certified"
      (boundedExample testEarlyClose)
    for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) →
      for_ [0 .. 3] $ \k →
        it ("finishes the exit when the example body " <> label <> " at step " <> show k <> " of the early-close fixture (#593)") $
          boundedExample (exitFinishes ending (earlyCloseScenario k))

-- ---------------------------------------------------------------------------
-- The journal

-- | The independent facts an example asserts the order of. Each is set by the
-- party that owns it: a scripted graphics owner, the seam's own native calls,
-- or a scripted parent's release.
data Flag
  = AdmissionClosed
    -- ^ A worker saw its attachment stop admitting new graphics use, with the
    -- windows still live and while the worker drain was still under way.
  | CpuUsesEnded !Text
  | WorkEnded !Text
  | PresentationSettled !Text
  | DependentsGone !Text
  | WindowGone !Int
    -- ^ The seam's own destroy call, named by the window's creation order.
  | SessionEnded
  | ParentReleased !Text
  deriving (Eq, Show)

-- | The flag one certified fact sets.
flagOf ∷ Text → RetirementFact → Flag
flagOf name = \case
  CpuUseRetired → CpuUsesEnded name
  SubmittedWorkEnded → WorkEnded name
  PresentationEnded → PresentationSettled name
  DependentsDisposed → DependentsGone name

note ∷ TVar [Flag] → Flag → STM ()
note journal flag = modifyTVar' journal (<> [flag])

-- | Every flag a whole retirement sets, in the order the owner sets them.
retiring ∷ Text → [Flag]
retiring name = map (flagOf name) allRetirementFacts

-- ---------------------------------------------------------------------------
-- The scripted graphics owner

-- | What one scripted opportunity does. A plan that runs out stalls, so an
-- example never silently retires an attachment it did not certify.
data Step
  = Certify !RetirementFact
    -- ^ Note the obligation's flag and certify the fact on the owner thread.
  | Await
    -- ^ No progress this round; the path is kept.
  | Stall
    -- ^ No safe progress path; the path is withdrawn.
  | FailWith !Text
  | Blocking
    -- ^ A step that begins disposing and never returns, so an example can
    -- interrupt it partway.
  | Parked !(MVar ()) !(MVar ())
    -- ^ A step that says it has been entered and waits to be let go before it stalls, so an example can cancel the runner
    -- inside its first retirement opportunity, before the stall has been counted (#612).
  deriving (Eq)

-- | Shown by name: the cells of 'Parked' have no 'Show' of their own.
instance Show Step where
  show = \case
    Certify fact → "Certify " <> show fact
    Await → "Await"
    Stall → "Stall"
    FailWith message → "FailWith " <> show message
    Blocking → "Blocking"
    Parked _ _ → "Parked"

-- | What an example scripts one owner to do.
data OwnerScript = OwnerScript
  { scriptName ∷ Text
  , scriptConstruct ∷ IO ()
  , scriptRollback ∷ IO RollbackOutcome
  , scriptPlan ∷ [Step]
  , scriptCompletion ∷ CompletionPolicy
  , scriptDisposition ∷ Disposition
  , scriptRecognizes ∷ Bool
  }

-- | An owner that constructs without effect and certifies every fact, one per
-- opportunity.
ownerNamed ∷ Text → OwnerScript
ownerNamed name =
  OwnerScript name (pure ()) (pure RollbackSafe) (map Certify allRetirementFacts) FiniteCompletion Required False

-- | One attached scripted owner, as the example observes it.
data Owner = Owner
  { ownerName ∷ !Text
  , ownerAcknowledgement ∷ !(TVar (Maybe Acknowledgement))
    -- ^ Stored by the construction, so another thread can publish notices.
  , ownerPlan ∷ !(TVar [Step])
  , ownerStalls ∷ !(TVar Int)
  , ownerAwaits ∷ !(TVar Int)
  , ownerSteps ∷ !(TVar Int)
    -- ^ Every opportunity the boundary offered, so an example can prove a step
    -- was not replayed and a withdrawn path was not revived.
  , ownerViews ∷ !(TVar [AttachmentView Evidence])
    -- ^ The view each certifying opportunity saw before it certified, so an
    -- example can assert the evidence an attachment carried while it was live.
  }

type Evidence = ExceptionWithContext SomeException

newtype Scripted = Scripted Text
  deriving (Eq, Show)

instance Exception Scripted

-- | Attach one scripted owner to a window of a protected host.
attachOwner ∷ TVar [Flag] → WindowHost → WindowId → OwnerScript → IO (Owner, AttachmentOutcome)
attachOwner journal host window script = do
  -- Created and registered with the rescue in one masked step, before the attachment exists.
  owner ← mask_ $ do
    created ←
      Owner (scriptName script)
        <$> newTVarIO Nothing
        <*> newTVarIO (scriptPlan script)
        <*> newTVarIO 0
        <*> newTVarIO 0
        <*> newTVarIO 0
        <*> newTVarIO []
    registerOwner host created
    pure created
  -- Whenever the attachment ends, an owner registered after the cleanup began (or attached while it began) is released by this
  -- code itself, now that its attachment can take the notices.
  outcome ← attachHostWindow host window (protocolFor journal host owner script) `finally` releaseIfBegun host owner
  pure (owner, outcome)

-- | The one scripted owner established, or why it was not.
establishedOwner ∷ TVar [Flag] → WindowHost → WindowId → OwnerScript → IO Owner
establishedOwner journal host window script =
  attachOwner journal host window script >>= \case
    (owner, AttachmentEstablished _ _) → pure owner
    (_, other) → unexpected ("the attachment was not established: " <> show other)

protocolFor ∷ TVar [Flag] → WindowHost → Owner → OwnerScript → AttachmentProtocol
protocolFor journal host owner script =
  AttachmentProtocol
    { protocolConstruct = \_ acknowledgement → do
        atomically (writeTVar (ownerAcknowledgement owner) (Just acknowledgement))
        scriptConstruct script
    , protocolRollback = scriptRollback script
    , protocolStep = \target acknowledgement → do
        step ← atomically $ do
          modifyTVar' (ownerSteps owner) (+ 1)
          plan ← readTVar (ownerPlan owner)
          case plan of
            [] → pure Stall
            next : rest → next <$ writeTVar (ownerPlan owner) rest
        perform target acknowledgement step
    , protocolCompletion = scriptCompletion script
    , protocolDisposition = scriptDisposition script
    , protocolRecognizes = \_ → pure (scriptRecognizes script)
    , protocolBeforeHide = \_ → pure (pure ())
    }
  where
    perform target acknowledgement = \case
      Await → RetirementAwaiting <$ atomically (modifyTVar' (ownerAwaits owner) (+ 1))
      Stall → RetirementStalled <$ atomically (modifyTVar' (ownerStalls owner) (+ 1))
      FailWith message → throwIO (Scripted message)
      -- Reads a variable another thread writes, so this is a park rather than a
      -- deadlock the runtime would break.
      Blocking → atomically (readTVar (ownerPlan owner) >> retry)
      Parked entered proceed → do
        void (tryPutMVar entered ())
        takeMVar proceed
        RetirementStalled <$ atomically (modifyTVar' (ownerStalls owner) (+ 1))
      Certify fact → do
        atomically $ do
          seen ← hostAttachmentView host target
          forM_ seen (\view → modifyTVar' (ownerViews owner) (<> [view]))
          note journal (flagOf (ownerName owner) fact)
        void (reportHostRetirementFact host acknowledgement fact)
        pure RetirementAdvanced

-- | Publish an owner's certified facts from a thread that is not the owner.
-- Each admitted notice wakes the owner exactly as a command admission does.
publishFacts ∷ TVar [Flag] → WindowHost → Owner → [RetirementFact] → IO ()
publishFacts journal host owner facts = do
  publisher ← maybe (unexpected "the host publishes no completions") pure (hostCompletionPublisher host)
  acknowledgement ← atomically (readTVar (ownerAcknowledgement owner) >>= maybe retry pure)
  let target = acknowledgedAttachment acknowledgement
  forM_ facts $ \fact → do
    atomically (note journal (flagOf (ownerName owner) fact))
    publishCompletion publisher (completionNotice target acknowledgement fact) >>= \case
      CompletionOffered NoticeRejectedFull → unexpected "the completion inbox refused a notice"
      CompletionClosed → unexpected "the boundary had already closed publication"
      _ → pure ()

-- | A supervised job that waits until its attachment stops admitting new
-- graphics use and notes it.
--
-- It proves the close happened with the windows live and while the workers were
-- still being drained, rather than during retirement: nothing in the drain can
-- run until this job has completed.
admissionWatcher ∷ TVar [Flag] → WindowHost → Owner → WorkerDefinition ()
admissionWatcher journal host owner =
  workerDefinition
    "renderer"
    (\_ → allocResource (pure ()) (\() → noteClosedAdmission journal host owner))
    (\token () → atomically (awaitStopRequest token))

-- | The worker's own release, which supervision runs while draining it: by then
-- the quiescence transaction has already committed, so the attachment must have
-- stopped admitting new graphics use. It waits for nothing.
noteClosedAdmission ∷ TVar [Flag] → WindowHost → Owner → IO ()
noteClosedAdmission journal host owner = atomically $ do
  held ← readTVar (ownerAcknowledgement owner)
  forM_ held $ \acknowledgement → do
    seen ← hostAttachmentView host (acknowledgedAttachment acknowledgement)
    case seen of
      Just view | viewPhase view == AttachmentActive → pure ()
      _ → note journal AdmissionClosed

-- ---------------------------------------------------------------------------
-- A confirmed Wayland connection loss

-- | A 'pollingSeam' whose sessions are Wayland ones, with the connection-status
-- probe answering the status held in the 'IORef'.
connectionSeam ∷ TVar [Flag] → IORef ConnectionStatus → IO Seam
connectionSeam journal status = do
  held ← newIORef Nothing
  seam ←
    newSeam
      defaultScript
        { scriptDestroyWindow = \_ → do
            destroyed ← readIORef held >>= maybe (pure 0) (fmap latestDestroyed . seamCalls)
            atomically (note journal (WindowGone destroyed))
        , scriptTerminate = \_ → atomically (note journal SessionEnded)
        , scriptConnectionProbe = Right (readIORef status)
        }
  writeIORef held (Just seam)
  pure seam

-- | 'protectedRunHere' over a Wayland session of the seam, caught on the
-- designated main thread itself so the failure keeps the cleanup evidence its
-- context carries.
waylandProtectedRun
  ∷ Seam
  → HostConfig
  → (WindowHost → IO ())
  → (WindowHost → RuntimeControl → IO a)
  → IO (ConnectionFailed, SomeException)
waylandProtectedRun seam config inside action =
  waylandProtectedRunAs seam config inside action

waylandProtectedRunAs
  ∷ Exception e
  ⇒ Seam
  → HostConfig
  → (WindowHost → IO ())
  → (WindowHost → RuntimeControl → IO a)
  → IO (e, SomeException)
waylandProtectedRunAs seam config inside action =
  asProcessMainThread seam . caughtAs $
    runProtectedWindowApplication
      (withLoggingLifetime quietLogger)
      "protected-host-example"
      ( \_ use →
          withProtectedWindowHostIn
            quietLogger
            (seamSession seam defaultSessionConfig {requestedBackend = Just Wayland})
            config
            (\host → (inside host >> use host) `rescuedUnlessDesigned` ())
      )
      id
      (\host _ → pure host)
      action

-- | Owner turns that lose the connection during the first update: the next
-- turn's event processing is the first to find it.
losingTurns ∷ IORef ConnectionStatus → WindowHost → RuntimeControl → IO ()
losingTurns status host control =
  runOwnerLoop host control $
    LoopHooks
      { loopLogger = quietLogger
      , loopEvent = noApplicationEvents
      , loopUpdate = \_ → Continue <$ atomicWriteIORef status lostConnection
      }

lostConnection ∷ ConnectionStatus
lostConnection = ConnectionEnded (TransportClosed (Just 32))

-- | The owner loop's event processing finds the loss, so it is the primary
-- failure; the attachment still retires, by its owner's own certified facts,
-- before its window is destroyed and the session ends.
testLossInitiatesFailure ∷ Expectation
testLossInitiatesFailure = do
  journal ← newTVarIO []
  status ← newIORef ConnectionHealthy
  seam ← connectionSeam journal status
  owned ← newTVarIO Nothing
  (primary, _) ←
    waylandProtectedRun seam (settings [windowNamed "alpha"]) (attaching journal owned) (losingTurns status)
  connectionCause primary `shouldBe` TransportClosed (Just 32)
  connectionBoundary primary `shouldBe` BeforeEvents
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | The action fails first; the loss is found only by the drain's own event
-- processing, so the action's failure stays primary and the loss is retained
-- beside it under the boundary's label.
testLossFoundDuringCleanup ∷ Expectation
testLossFoundDuringCleanup = do
  journal ← newTVarIO []
  status ← newIORef ConnectionHealthy
  seam ← connectionSeam journal status
  owned ← newTVarIO Nothing
  (primary, caught) ←
    waylandProtectedRunAs
        seam
        (settings [windowNamed "alpha"])
        ( \host → do
            window ← onlyWindow host
            -- The owner has nothing to certify at the drain's first
            -- opportunity, so that round pumps events before any fact.
            owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = Await : map Certify allRetirementFacts}
            atomically (writeTVar owned (Just owner))
        )
        (\_ _ → atomicWriteIORef status lostConnection >> throwIO (Scripted "action"))
  primary `shouldBe` Scripted "action"
  map (fmap connectionCause) (retainedAs' "glfw protected retirement" caught)
    `shouldBe` [Just (TransportClosed (Just 32))]
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | An owner with no safe progress path keeps its attachment through the loss:
-- once the drain has found the loss and the owner has stalled, the attachment
-- holds no fact at all, and only its own evidence, published independently,
-- retires it.
testLossSuppliesNoFacts ∷ Expectation
testLossSuppliesNoFacts = do
  journal ← newTVarIO []
  status ← newIORef ConnectionHealthy
  seam ← connectionSeam journal status
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  seen ← newTVarIO Nothing
  withEvidenceThread
    ( do
        owner ← awaitHeld owned
        host ← awaitHeld hostHeld
        view ← atomically $ do
          afterStall owner
          held ← readTVar (ownerAcknowledgement owner) >>= maybe retry pure
          hostAttachmentView host (acknowledgedAttachment held) >>= maybe retry pure
        atomically (writeTVar seen (Just view))
        publishFacts journal host owner allRetirementFacts
    )
    $ \helper _ → do
    (primary, _) ←
      waylandProtectedRun
          seam
          (settings [windowNamed "alpha"])
          ( \host → do
              window ← onlyWindow host
              owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Stall]}
              atomically (writeTVar owned (Just owner) >> writeTVar hostHeld (Just host))
          )
          (losingTurns status)
    void (pure helper)
    connectionCause primary `shouldBe` TransportClosed (Just 32)
    stalled ← readTVarIO seen >>= maybe (unexpected "the helper saw no stalled attachment") pure
    viewRecorded stalled `shouldBe` Map.empty
    sort (viewMissing stalled) `shouldBe` sort allRetirementFacts
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | The connection failures a failure retained under one cleanup label.
retainedAs' ∷ Text → SomeException → [Maybe ConnectionFailed]
retainedAs' label caught =
  [ fromException (exceptionOf (cleanupFailureException failure))
  | failure ← cleanupFailures caught
  , cleanupFailureLabel failure == label
  ]

-- ---------------------------------------------------------------------------
-- The seam and the runner

-- | A seam that journals its own destroy and terminate calls, so the native
-- lifetime appears in the same list as the flags the owners set.
--
-- Its finite wait blocks until an empty event has been posted, which is exactly
-- what the session's internal wake does, so a drain round with nothing to do
-- really waits and a completion published from another thread really ends it.
journallingSeam ∷ TVar [Flag] → IO Seam
journallingSeam = journallingSeamWaiting True

-- | 'journallingSeam' whose finite wait returns at once, for an example that
-- runs ordinary owner turns and would otherwise park in an idle turn's wait.
pollingSeam ∷ TVar [Flag] → IO Seam
pollingSeam = journallingSeamWaiting False

journallingSeamWaiting ∷ Bool → TVar [Flag] → IO Seam
journallingSeamWaiting blocking = journallingSeamPosting blocking (\_ → pure ())

-- | 'journallingSeamWaiting' whose empty-event post runs an extra scripted step
-- before it is counted, for an example that needs the post itself to report a
-- platform failure.
journallingSeamPosting ∷ Bool → (Reporter → IO ()) → TVar [Flag] → IO Seam
journallingSeamPosting blocking posting journal = do
  posts ← newTVarIO (0 ∷ Int)
  held ← newIORef Nothing
  seam ←
    newSeam
      defaultScript
        { scriptDestroyWindow = \_ → do
            destroyed ← readIORef held >>= maybe (pure 0) (fmap latestDestroyed . seamCalls)
            atomically (note journal (WindowGone destroyed))
        , scriptTerminate = \_ → atomically (note journal SessionEnded)
        , scriptWaitEvents = \_ _ →
            when blocking $
              atomically (readTVar posts >>= \pending → if pending <= 0 then retry else writeTVar posts (pending - 1))
        , scriptPostEmptyEvent = \reporter → posting reporter >> atomically (modifyTVar' posts (+ 1))
        }
  writeIORef held (Just seam)
  pure seam

-- | The window being destroyed now: the seam records the call before it runs
-- the destroy hook, so the last one recorded is this one.
latestDestroyed ∷ [NativeCall] → Int
latestDestroyed calls = last (0 : [key | DestroyWindow key ← calls])

-- | Run one application over a protected host in the seam's session, on a bound
-- thread designated as the process main thread.
--
-- @inside@ runs inside the protected lifetime, after its exit handler is
-- installed and before the consumer is entered: it is where an example attaches
-- its owners and constructs dependents, exactly where an integration would.
protectedRun
  ∷ Seam
  → Logger
  → HostConfig
  → (WindowHost → IO ())
  → (WindowHost → RuntimeControl → IO s)
  → (s → RuntimeControl → IO a)
  → IO a
protectedRun seam logger config inside startup action =
  asProcessMainThread seam (protectedRunHere seam logger config inside startup action)

protectedRunHere
  ∷ Seam
  → Logger
  → HostConfig
  → (WindowHost → IO ())
  → (WindowHost → RuntimeControl → IO s)
  → (s → RuntimeControl → IO a)
  → IO a
protectedRunHere seam logger config inside startup action =
  runProtectedWindowApplication
    (withLoggingLifetime logger)
    "protected-host-example"
    (\_ use → protectedHost seam logger config (\host → inside host >> use host))
    id
    startup
    action

protectedHost ∷ Seam → Logger → HostConfig → (WindowHost → IO r) → IO r
protectedHost seam logger config body = do
  withProtectedWindowHostIn logger (seamSession seam defaultSessionConfig) config $ \host →
    -- The rescue is the first thing acquired inside the protected lifetime (#593): it wraps the whole callback, the setup and
    -- everything the example does with the host, so a failure or cancellation at any point after the host exists reaches it
    -- before the host drains, and every owner is registered with it as it is created.
    body host `rescuedUnlessDesigned` ()

-- | The structural rescue of the protected examples (#593): every owner registered since the host was built gets its remaining plan
-- released ("certify every fact") and every fact published for it directly, which also wakes a drain parked in a wait. It
-- blocks on nothing, raises nothing, adds nothing an owner has no acknowledgement for, and is idempotent. It runs only on an
-- exceptional exit, where the suppliers the examples start up front may be waiting for cells a half-built fixture never filled.
rescueRegistered ∷ IO ()
rescueRegistered = do
  isArmed ← readIORef rescueArmed
  when isArmed rescueNow

-- | 'rescueRegistered' without the arming: the runner scopes call it from their opening, which runs only when the scope ends.
rescueNow ∷ IO ()
rescueNow = do
  -- Sticky (#593): the cleanup is marked begun and the owners are read in one atomic step, before anything is released, so an
  -- owner registered after this step finds the mark and releases itself, and one registered before it is in the snapshot.
  known ← atomicModifyIORef' registeredOwners (\registry → (registry {registryBegun = True}, registryOwners registry))
  forM_ known (uncurry releaseOwner)

-- | Release one owner: its remaining plan becomes "certify every fact", and every fact is published for it directly if it holds
-- an acknowledgement. It blocks on nothing, raises nothing and is idempotent.
releaseOwner ∷ WindowHost → Owner → IO ()
releaseOwner host owner = do
  atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
  acknowledgement ← readTVarIO (ownerAcknowledgement owner)
  case (hostGraphicsPublisher host, acknowledgement) of
    (Just publisher, Just acknowledged) →
      forM_ allRetirementFacts $ \fact →
        void (publishCompletion publisher (completionNotice (acknowledgedAttachment acknowledged) acknowledged fact))
    _ → pure ()

-- | Register an owner with the rescue as it is created. If the cleanup has begun already, the registering code releases the owner
-- itself, at once: nothing is left for a later pass to find.
registerOwner ∷ WindowHost → Owner → IO ()
registerOwner host owner = do
  begun ← atomicModifyIORef' registeredOwners (\registry → (registry {registryOwners = (host, owner) : registryOwners registry}, registryBegun registry))
  when begun (releaseOwner host owner)

-- | After an attachment ended (or failed): release the owner again if the cleanup has begun, since its notices could not have been
-- accepted before the attachment was established.
releaseIfBegun ∷ WindowHost → Owner → IO ()
releaseIfBegun host owner = do
  registry ← readIORef registeredOwners
  when (registryBegun registry) (releaseOwner host owner)

-- | The failures an example raises on purpose as its subject (the scripted failure of a step, a startup or an action): the drain's own
-- behaviour on them is what the example asserts, so the rescue leaves them alone and acts only on what nobody scripted, a
-- cancellation or a failed assertion.
rescuedUnlessDesigned ∷ IO a → () → IO a
rescuedUnlessDesigned act () =
  act `catch` \(thrown ∷ SomeException) → do
    unless (isDesignedFailure thrown) rescueRegistered
    throwIO thrown

isDesignedFailure ∷ SomeException → Bool
isDesignedFailure thrown = case (fromException thrown, fromException thrown) of
  (Just (Scripted _), _) → True
  (_, Just (_ ∷ ConnectionFailed)) → True
  _ → False

-- | The rescue is armed only by the examples whose drain depends on evidence an up-front supplier would publish: in every other
-- example the drain's own behaviour on an exceptional exit is the subject, and an early rescue would change it.
rescueArmed ∷ IORef Bool
rescueArmed = unsafePerformIO (newIORef False)
{-# NOINLINE rescueArmed #-}

-- | Start an evidence supplier for the length of the body with the structural rescue armed (#593).
withEvidenceThread ∷ IO () → (ThreadId → IO () → IO a) → IO a
withEvidenceThread action body = armed (withOwnedThread action body)

armed ∷ IO a → IO a
armed act = (atomicWriteIORef rescueArmed True >> act) `finally` atomicWriteIORef rescueArmed False

-- | The owners created since the current example began, with their hosts. One example is active at a time (the suite's examples
-- run one after another), and the spec empties the registry before each.
registeredOwners ∷ IORef Registry
registeredOwners = unsafePerformIO (newIORef (Registry False []))
{-# NOINLINE registeredOwners #-}

-- | Whether the cleanup has begun (sticky until the next example), and the owners registered.
data Registry = Registry {registryBegun ∷ Bool, registryOwners ∷ [(WindowHost, Owner)]}

-- | Reset between examples (the spec runs @before_@ every one), never inside a lifetime: a cleanup that begins before the runner
-- reaches its host must stay begun.
clearRegistered ∷ IO ()
clearRegistered = writeIORef registeredOwners (Registry False [])

-- ---------------------------------------------------------------------------
-- Exit paths

-- | The exits the protected boundary covers that differ only in how the
-- consumer ends.
data ExitPath
  = ReturnsNormally
  | ActionFails
  | StartupFails
  | LoopFails
  | SupervisionLatches
  deriving (Eq, Show)

testExitPath ∷ ExitPath → Expectation
testExitPath path = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  outcome ←
    try $
      protectedRun
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        (attaching journal owned)
        ( \host control → do
            owner ← heldOwner owned
            void (startSupervised control workerPolicy (admissionWatcher journal host owner) >>= started)
            case path of
              StartupFails → throwIO (Scripted "startup")
              SupervisionLatches → do
                void (startSupervised control workerPolicy breaking >>= started)
                awaitSupervised control retry
              _ → pure ()
            pure host
        )
        ( \host control → case path of
            ActionFails → throwIO (Scripted "action")
            LoopFails →
              runOwnerLoop host control $
                LoopHooks
                  { loopLogger = quietLogger
                  , loopEvent = noApplicationEvents
                  , loopUpdate = \_ → throwIO (Scripted "owner loop")
                  }
            _ → pure ()
        )
  case (path, outcome ∷ Either SomeException ()) of
    (ReturnsNormally, Right ()) → pure ()
    (ReturnsNormally, Left caught) → unexpected ("the run failed: " <> show caught)
    (_, Left _) → pure ()
    (_, Right ()) → unexpected "the failing run returned"
  readTVarIO journal `shouldReturn` ([AdmissionClosed] <> retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | Attach one owner named @alpha@ inside the protected lifetime and stash it.
attaching ∷ TVar [Flag] → TVar (Maybe Owner) → WindowHost → IO ()
attaching journal owned host = do
  window ← onlyWindow host
  owner ← establishedOwner journal host window (ownerNamed "alpha")
  atomically (writeTVar owned (Just owner))

heldOwner ∷ TVar (Maybe Owner) → IO Owner
heldOwner owned = readTVarIO owned >>= maybe (unexpected "no owner was attached") pure

testCancelledAction ∷ Expectation
testCancelledAction = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  inside ← newEmptyMVar
  never ← newEmptyMVar
  withMainThread seam (void (tryPutMVar never ()))
    ( protectedRunHere
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        (attaching journal owned)
        ( \host control → do
            owner ← heldOwner owned
            void (startSupervised control workerPolicy (admissionWatcher journal host owner) >>= started)
        )
        (\() _ → putMVar inside () >> takeMVar never)
    )
    $ \runner finished → do
    takeMVar inside
    killThread runner
    takeMVar finished >>= \case
      Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
      Right () → unexpected "the cancelled run returned"
    readTVarIO journal `shouldReturn` ([AdmissionClosed] <> retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A dependent construction that fails after the host is built never enters
-- supervision, so no quiescence hook exists and no worker is drained. The
-- protected host still closes attachment admission itself and retires what the
-- construction left registered.
testDependencyConstructionFails ∷ Expectation
testDependencyConstructionFails = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  entered ← newIORef False
  (failure, _) ←
    caughtAs $
      protectedRun
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        ( \host → do
            window ← onlyWindow host
            void (establishedOwner journal host window (ownerNamed "alpha"))
            throwIO (Scripted "dependent")
        )
        (\_ _ → writeIORef entered True)
        (\() _ → pure ())
  failure `shouldBe` Scripted "dependent"
  readIORef entered `shouldReturn` False
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- ---------------------------------------------------------------------------
-- The host's own close

-- | The runner's own quiescence hook is what closes admission before the worker
-- drain. An application that installs none still cannot leave an attachment
-- admitting new use: the protected host closes it itself on the way out, and
-- the retirement facts an owner then certifies prove it, because the model
-- refuses every one of them before retirement has begun.
testOmittedQuiescence ∷ Expectation
testOmittedQuiescence = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  pending ← newIORef []
  asProcessMainThread seam $
    runManagedApplication
      (withLoggingLifetime quietLogger)
      "protected-host-example"
      ( \use →
          protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
            window ← onlyWindow host
            void (establishedOwner journal host window (ownerNamed "alpha"))
            use host
      )
      -- No quiescence: the application omits the host entirely.
      (\_ → pure ())
      (\host _ → pure host)
      ( \host _ → do
          held ← atomically (hostPendingAttachments host)
          writeIORef pending held
      )
  held ← readIORef pending
  length held `shouldBe` 1
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A host built by 'allocWindowHost' is issued no attachment identity, so a
-- registration against it is refused before any effect and nothing is retired.
testUnprotectedHostRefuses ∷ Expectation
testUnprotectedHostRefuses = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  refused ← newIORef Nothing
  asProcessMainThread seam $
    runWindowApplication
      (withLoggingLifetime quietLogger)
      "host-example"
      (allocWindowHostIn (seamSession seam defaultSessionConfig) (settings [windowNamed "alpha"]))
      id
      ( \host _ → do
          hostAttachmentIdentity host `shouldSatisfy` \case
            Nothing → True
            Just _ → False
          window ← onlyWindow host
          (_, outcome) ← attachOwner journal host window (ownerNamed "alpha")
          writeIORef refused (Just outcome)
          atomically (hostPendingAttachments host) `shouldReturn` []
      )
      (\() _ → pure ())
  readIORef refused >>= \case
    Just AttachmentHostUnprotected → pure ()
    other → unexpected ("the unprotected host did not refuse: " <> show other)
  readTVarIO journal `shouldReturn` [WindowGone 1, SessionEnded]

-- ---------------------------------------------------------------------------
-- Construction ownership

testConstructionFailure ∷ RollbackOutcome → Expectation
testConstructionFailure rollback = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  answered ← newIORef Nothing
  observed ← newIORef Nothing
  asProcessMainThread seam $
    runProtectedWindowApplication
      (withLoggingLifetime quietLogger)
      "protected-host-example"
      ( \_ use →
          protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
            window ← onlyWindow host
            (_, outcome) ←
              attachOwner
                journal
                host
                window
                (ownerNamed "alpha")
                  { scriptConstruct = throwIO (Scripted "construction")
                  , scriptRollback = pure rollback
                  }
            writeIORef answered (Just outcome)
            held ← atomically (hostPendingAttachments host)
            views ← traverse (atomically . hostAttachmentView host) held
            writeIORef observed (Just (length held, concatMap (maybe [] pure) views))
            use host
      )
      id
      (\host _ → pure host)
      (\_ _ → pure ())
  readIORef answered >>= \case
    Just (AttachmentRolledBack settled) → do
      rolledBackOutcome settled `shouldBe` rollback
      -- The original failure comes back whatever the model kept: a safe
      -- rollback retired the attachment and removed its evidence with it.
      (fromException (exceptionOf (rolledBackFailure settled)) ∷ Maybe Scripted)
        `shouldBe` Just (Scripted "construction")
      rolledBackRollback settled `shouldSatisfy` \case
        Nothing → True
        Just _ → False
    other → unexpected ("the construction failure was not answered: " <> show other)
  (count, views) ← readIORef observed >>= maybe (unexpected "nothing was observed") pure
  case rollback of
    RollbackSafe → do
      -- A safe rollback discharged every obligation the construction never
      -- created: nothing is left to retire, and nothing usable was published.
      count `shouldBe` 0
      readTVarIO journal `shouldReturn` [WindowGone 1, SessionEnded]
    RollbackUnsafe → do
      count `shouldBe` 1
      map viewMissing views `shouldBe` [allRetirementFacts]
      map (constructionEvidence . viewEvidence) views `shouldBe` [Just rollback]
      readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

constructionEvidence ∷ AttachmentEvidence Evidence → Maybe RollbackOutcome
constructionEvidence evidence = case evidenceFirstFailure evidence of
  Just (ConstructionFailure _ outcome) → Just outcome
  _ → Nothing

-- | A configuration the host itself refuses leaves no consumer to enter and no
-- attachment to make.
testHostSetupFails ∷ Expectation
testHostSetupFails = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  attached ← newIORef False
  begun ← newIORef False
  (rejection, _) ←
    caughtAs $
      protectedRun
        seam
        quietLogger
        (settings [windowNamed "alpha", windowNamed "bad\NUL"])
        (\_ → writeIORef attached True)
        (\_ _ → writeIORef begun True)
        (\() _ → pure ())
  rejection `shouldBe` WindowTitleRejected
  readIORef attached `shouldReturn` False
  readIORef begun `shouldReturn` False
  readTVarIO journal `shouldReturn` [WindowGone 1, SessionEnded]

-- | A cancellation delivered inside a construction is counted as the
-- attachment's evidence, establishes no fact, and leaves nothing outside
-- registration: the drain still retires what the construction left behind.
testCancelledConstruction ∷ Expectation
testCancelledConstruction = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  constructing ← newEmptyMVar
  never ← newEmptyMVar
  withMainThread seam (void (tryPutMVar never ()))
    ( protectedRunHere
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        ( \host → do
            window ← onlyWindow host
            void $
              attachOwner
                journal
                host
                window
                (ownerNamed "alpha")
                  { scriptConstruct = putMVar constructing () >> takeMVar never
                  , scriptRollback = pure RollbackUnsafe
                  }
        )
        (\_ _ → pure ())
        (\() _ → pure ())
    )
    $ \runner finished → do
    takeMVar constructing
    killThread runner
    takeMVar finished >>= \case
      Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
      Right () → unexpected "the cancelled construction returned"
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A rollback is trusted but not infallible. One that raises establishes no
-- safety, so the attachment is retained owing every fact — never left pending,
-- where no fact could be recorded and the drain could never finish.
testRollbackFails ∷ Expectation
testRollbackFails = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  answered ← newIORef Nothing
  owned ← newTVarIO Nothing
  asProcessMainThread seam $
    runProtectedWindowApplication
      (withLoggingLifetime quietLogger)
      "protected-host-example"
      ( \_ use →
          protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
            window ← onlyWindow host
            (owner, outcome) ←
              attachOwner
                journal
                host
                window
                (ownerNamed "alpha")
                  { scriptConstruct = throwIO (Scripted "construction")
                  , scriptRollback = throwIO (Scripted "rollback")
                  }
            writeIORef answered (Just outcome)
            atomically (writeTVar owned (Just owner))
            use host
      )
      id
      (\host _ → pure host)
      (\_ _ → pure ())
  readIORef answered >>= \case
    Just (AttachmentRolledBack settled) → do
      -- A rollback that did not complete established no safety.
      rolledBackOutcome settled `shouldBe` RollbackUnsafe
      (fromException (exceptionOf (rolledBackFailure settled)) ∷ Maybe Scripted)
        `shouldBe` Just (Scripted "construction")
      (fromException . exceptionOf <$> rolledBackRollback settled) `shouldBe` Just (Just (Scripted "rollback"))
    other → unexpected ("the failed rollback was not answered: " <> show other)
  owner ← awaitHeld owned
  seen ← readTVarIO (ownerViews owner)
  -- The construction failure stays first, with the rollback's own counted after
  -- it, and every fact is still owed.
  map (constructionEvidence . viewEvidence) (take 1 seen) `shouldBe` [Just RollbackUnsafe]
  map (evidenceLaterFailures . viewEvidence) (take 1 seen) `shouldBe` [1]
  map viewMissing (take 1 seen) `shouldBe` [allRetirementFacts]
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A cancellation delivered inside the rollback is retained beside the one
-- that cancelled the construction, and neither strands the attachment.
testCancelledRollback ∷ Expectation
testCancelledRollback = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  constructing ← newEmptyMVar
  rollingBack ← newEmptyMVar
  never ← newEmptyMVar
  neverRolls ← newEmptyMVar
  withMainThread seam (void (tryPutMVar never ()) >> void (tryPutMVar neverRolls RollbackUnsafe))
    ( protectedRunHere
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        ( \host → do
            window ← onlyWindow host
            void $
              attachOwner
                journal
                host
                window
                (ownerNamed "alpha")
                  { scriptConstruct = putMVar constructing () >> takeMVar never
                  , scriptRollback = putMVar rollingBack () >> takeMVar neverRolls
                  }
        )
        (\_ _ → pure ())
        (\() _ → pure ())
    )
    $ \runner finished → do
    takeMVar constructing
    killThread runner
    takeMVar rollingBack
    killThread runner
    takeMVar finished >>= \case
      Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
      Right () → unexpected "the cancelled rollback returned"
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | The fixture of 'testIndependentChains' (two windows, alpha stalled, a supplier started up front that waits for cells the
-- fixture fills last) ended at the boundary before setup step @k@ (#593): 0 is the setup callback (the host exists, nothing is
-- attached), 1 follows the window lookup, 2 follows alpha's attachment, 3 follows beta's, 4 and 5 follow each published cell. At
-- 2 to 4 alpha is already retained and the supplier still waits for cells, so the drain would wait for ever without the rescue
-- that was acquired with the host and told of each owner as it was created.
protectedSetupScenario ∷ Int → Scope → IO () → IO ()
protectedSetupScenario k scope atParked = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  let step i = when (i == k) atParked
  withEvidenceSupplier scope journal hostHeld owned $ \_ →
    asProcessMainThread seam $
      runProtectedWindowApplication
        (withLoggingLifetime quietLogger)
        "protected-host-example"
        ( \_ use →
            protectedHost seam quietLogger (settings [windowNamed "alpha", windowNamed "beta"]) $ \host → do
              step 0
              (alpha, beta) ← twoWindows host
              step 1
              alphaOwner ← establishedOwner journal host alpha (ownerNamed "alpha") {scriptPlan = [Stall]}
              step 2
              void (establishedOwner journal host beta (ownerNamed "beta"))
              step 3
              atomically (writeTVar owned (Just alphaOwner))
              step 4
              atomically (writeTVar hostHeld (Just host))
              step 5
              use host
        )
        id
        (\host _ → pure host)
        (\_ _ → pure ())

-- | The fixture of the main-thread runners that publish their handles after attaching (#593, 'testRepeatedCancellation',
-- 'testInterruptedStepWithdrawn', 'testOnlyNewEvidenceRevives'), ended while the runner is parked between its first attachment and
-- the publication of its handles. The owner still has its scripted 'Await' steps to take and nothing left to publish for it, so
-- the runner's drain would wait for ever: the scope's opening must release what the registered owner owes without the handles.
runnerPartialScenario ∷ Scope → IO () → IO ()
runnerPartialScenario scope atParked = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  attached ← newEmptyMVar
  resume ← newEmptyMVar
  withMainThreadVia scope seam (supplyIfHeld journal hostHeld owned allRetirementFacts)
    ( runProtectedWindowApplication
        (withLoggingLifetime quietLogger)
        "protected-host-example"
        ( \_ use →
            protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
              window ← onlyWindow host
              owner ←
                establishedOwner
                  journal
                  host
                  window
                  (ownerNamed "alpha") {scriptPlan = [Await, Await] <> map Certify allRetirementFacts}
              -- Parked between the attachment and the publication of the handles.
              putMVar attached () >> takeMVar resume
              atomically (writeTVar owned (Just owner) >> writeTVar hostHeld (Just host))
              use host
        )
        id
        (\host _ → pure host)
        (\_ _ → pure ())
    )
    $ \_ _ → takeMVar attached >> atParked

-- | The sticky rescue, without a cancellation (#593): the cleanup begins while the runner has not yet registered the owner that
-- decides how the drain ends, and the runner then registers and attaches it. Nothing is killed; the only thing that can finish the
-- drain is the registering code releasing the owner itself, because the cleanup's one pass has already been made. With @after@ false
-- the cleanup begins before the runner builds its host (the registry must not be reset by the host); with it true, after the
-- runner attached a first owner and before it attaches a second, so the second is not in the snapshot the cleanup took.
stickyRegistration ∷ Bool → Expectation
stickyRegistration after = stickyRegistrationFixture after withOwnedBoundThreadOpening (pure ())

-- | The same fixture ended before its own explicit @rescueNow@ (#593): the example body fails or is cancelled while the runner has
-- attached its first owner (or, with @after@ false, while it is parked before its host), so the cleanup that follows is the owning
-- scope's own, whose opening calls @rescueNow@ before the kill.
stickyBeforeRescueScenario ∷ Bool → Scope → IO () → IO ()
stickyBeforeRescueScenario after scope atParked = stickyRegistrationFixture after scope atParked

stickyRegistrationFixture ∷ Bool → Scope → IO () → Expectation
stickyRegistrationFixture after scope beforeRescue = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  attached ← newEmptyMVar
  go ← newEmptyMVar
  let pending name = (ownerNamed name) {scriptPlan = [Await, Await] <> map Certify allRetirementFacts}
      callback host
        | after = do
            (alpha, beta) ← twoWindows host
            void (establishedOwner journal host alpha (pending "alpha"))
            putMVar attached () >> takeMVar go
            void (establishedOwner journal host beta (pending "beta"))
        | otherwise = do
            window ← onlyWindow host
            void (establishedOwner journal host window (pending "alpha"))
      windows = if after then ["alpha", "beta"] else ["alpha"]
  -- The scope's opening begins the cleanup before it kills the runner, and lets go of the runner's gate, however the example ended.
  withMainThreadVia scope seam (rescueNow >> void (tryPutMVar go ()))
    ( do
        unless after (takeMVar go)
        protectedRunHere seam quietLogger (settings (map windowNamed windows)) callback (\_ _ → pure ()) (\() _ → pure ())
    )
    $ \_ finished → do
    when after (takeMVar attached)
    beforeRescue
    rescueNow
    putMVar go ()
    takeMVar finished >>= either throwIO pure

-- | The runner of 'testRepeatedCancellation' held before it has registered its owner (#593), with the example body ended the way the
-- ending says: the scope's opening begins the cleanup while the runner has registered nothing, then lets it go on, so the owner is
-- registered and attached after the cleanup began. Nothing in the snapshot covers it; the registering code must release it itself,
-- or the drain waits for ever on an owner whose plan awaits and whose facts nobody publishes.
runnerBeforeRegistrationScenario ∷ Scope → IO () → IO ()
runnerBeforeRegistrationScenario scope atParked = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  reached ← newEmptyMVar
  proceed ← newEmptyMVar
  withMainThreadVia scope seam (rescueNow >> void (tryPutMVar proceed ()))
    ( protectedRunHere
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        ( \host → do
            window ← onlyWindow host
            putMVar reached () >> takeMVar proceed
            void (establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Await, Await] <> map Certify allRetirementFacts})
        )
        (\_ _ → pure ())
        (\() _ → pure ())
    )
    $ \runner _ → takeMVar reached >> awaitParked runner >> atParked

-- | The same runner held inside its owner's construction (#593): the owner is registered and holds its acknowledgement, but its
-- attachment is not established, so a notice published for it by the cleanup's snapshot may be refused. The attachment is established
-- after the cleanup began, and the registering code releases the owner again then.
runnerDuringConstructionScenario ∷ Scope → IO () → IO ()
runnerDuringConstructionScenario scope atParked = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  constructing ← newEmptyMVar
  proceed ← newEmptyMVar
  withMainThreadVia scope seam (rescueNow >> void (tryPutMVar proceed ()))
    ( protectedRunHere
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        ( \host → do
            window ← onlyWindow host
            void $
              establishedOwner
                journal
                host
                window
                (ownerNamed "alpha")
                  { scriptPlan = [Await, Await] <> map Certify allRetirementFacts
                  , scriptConstruct = putMVar constructing () >> takeMVar proceed
                  }
        )
        (\_ _ → pure ())
        (\() _ → pure ())
    )
    $ \runner _ → takeMVar constructing >> awaitParked runner >> atParked

-- | The scenario of 'testCancelledRollback' up to the moment its runner is parked in the construction, with the example body ended
-- the way the ending says (#593): a kill sent by the scope's release interrupts the construction, which starts a rollback that
-- waits at a second gate, so the scope opens both gates before it kills and joins the runner.
parkedConstructionScenario ∷ Scope → IO () → IO ()
parkedConstructionScenario scope atParked = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  constructing ← newEmptyMVar
  never ← newEmptyMVar
  neverRolls ← newEmptyMVar
  withMainThreadVia scope seam (void (tryPutMVar never ()) >> void (tryPutMVar neverRolls RollbackUnsafe))
    ( protectedRunHere
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        ( \host → do
            window ← onlyWindow host
            void $
              attachOwner
                journal
                host
                window
                (ownerNamed "alpha")
                  { scriptConstruct = putMVar constructing () >> takeMVar never
                  , scriptRollback = takeMVar neverRolls
                  }
        )
        (\_ _ → pure ())
        (\() _ → pure ())
    )
    $ \runner _ → takeMVar constructing >> awaitParked runner >> atParked

-- ---------------------------------------------------------------------------
-- The drain

-- | Cancellation during the drain is deferred: it is counted against every
-- pending attachment, establishes no fact, releases nothing, and is re-raised
-- only once the last fact has been certified.
testRepeatedCancellation ∷ Expectation
testRepeatedCancellation = repeatedCancellation withMainThread Nothing

-- | The scenario of 'testRepeatedCancellation' up to the moment its runner is parked in the drain's first finite wait, with the
-- example body ended the way the ending says before its first planned cancellation (#593): the drain absorbs the one kill of the
-- scope's cleanup, advances to its second wait, and would block there with nothing to wake it, so the cleanup must release every
-- remaining wait (the owner's plan, and a notice to wake the wait).
repeatedCancellationEndedEarlyScenario ∷ Scope → IO () → IO ()
repeatedCancellationEndedEarlyScenario scope atParked = repeatedCancellation (withMainThreadVia scope) (Just atParked)

repeatedCancellation
  ∷ (Seam → IO () → IO () → (ThreadId → MVar (Either SomeException ()) → IO ()) → IO ())
  → Maybe (IO ())
  → Expectation
repeatedCancellation start endEarly = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  start seam (supplyIfHeld journal hostHeld owned allRetirementFacts)
    ( protectedRunHere
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        ( \host → do
            window ← onlyWindow host
            owner ←
              establishedOwner
                journal
                host
                window
                (ownerNamed "alpha") {scriptPlan = [Await, Await] <> map Certify allRetirementFacts}
            atomically (writeTVar owned (Just owner) >> writeTVar hostHeld (Just host))
        )
        (\_ _ → pure ())
        (\() _ → pure ())
    )
    $ \runner finished → do
    owner ← awaitHeld owned
    case endEarly of
     Just atParked → atomically (readTVar (ownerAwaits owner) >>= check . (>= 1)) >> atParked
     Nothing → do
      -- Each cancellation is delivered while the drain is inside a finite wait it
      -- has no progress to skip, which is where the deferral must hold.
      forM_ [1 .. 2 ∷ Int] $ \round' → do
        atomically (readTVar (ownerAwaits owner) >>= check . (>= round'))
        killThread runner
      takeMVar finished >>= \case
        Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
        Right () → unexpected "the cancelled drain returned"
      seen ← readTVarIO (ownerViews owner)
      map viewPhase (take 1 seen) `shouldBe` [AttachmentRetiring]
      map (evidenceCancellations . viewEvidence) (take 1 seen) `shouldSatisfy` \case
        [counted] → counted >= 2
        _ → False
      map viewMissing (take 1 seen) `shouldBe` [allRetirementFacts]
      readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

exceptionOf ∷ Evidence → SomeException
exceptionOf (ExceptionWithContext _ failure) = failure

-- | Wait for a value another thread publishes, parked in a transaction rather
-- than spinning: a busy loop here would keep a capability from ever reaching a
-- safe point.
awaitHeld ∷ TVar (Maybe a) → IO a
awaitHeld held = atomically (readTVar held >>= maybe retry pure)

-- | Two chains, one of which cannot retire. The chain that can retires, and its
-- closed window is destroyed, while the other chain's window, the session they
-- share, and a parent borrowed outside the protected lifetime all stay live.
testIndependentChains ∷ Expectation
testIndependentChains = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  betaHeld ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  -- Beta's independent evidence arrives only once alpha's chain is already
  -- safe and its own window destroyed, so the order below is the order the
  -- boundary produced and not one the example imposed.
  withEvidenceThread (supplyEvidence journal hostHeld betaHeld (afterAlphaDestroyed journal) allRetirementFacts) $ \helper _ → do
    asProcessMainThread seam $
      runProtectedWindowApplication
        (withLoggingLifetime quietLogger)
        "protected-host-example"
        ( \_ use →
            withScoped (scriptedParent journal "parent") $ \() →
              protectedHost seam quietLogger (settings [windowNamed "alpha", windowNamed "beta"]) $ \host → do
                (alpha, beta) ← twoWindows host
                void (establishedOwner journal host alpha (ownerNamed "alpha"))
                betaOwner ← establishedOwner journal host beta (ownerNamed "beta") {scriptPlan = [Stall]}
                atomically (writeTVar betaHeld (Just betaOwner))
                atomically (writeTVar hostHeld (Just host))
                use host
        )
        id
        (\host _ → pure host)
        ( \host _ → do
            -- The chain that can retire is closed during the run, so its own
            -- window is destroyed as soon as it is safe, and not before.
            (alpha, _) ← twoWindows host
            closeHostWindow host alpha `shouldReturn` CloseStarted
        )
    void (pure helper)
    readTVarIO journal
      `shouldReturn` ( retiring "alpha"
                     <> [WindowGone 1]
                     <> retiring "beta"
                     <> [WindowGone 2, SessionEnded, ParentReleased "parent"]
                 )

-- | Once the owner has declared its stall, publish its certified facts from
-- another thread. Each notice wakes the owner out of its finite wait.
supplyEvidence
  ∷ TVar [Flag]
  → TVar (Maybe WindowHost)
  → TVar (Maybe Owner)
  → (Owner → STM ())
  → [RetirementFact]
  → IO ()
supplyEvidence journal hostHeld owned ready facts = do
  owner ← awaitHeld owned
  host ← awaitHeld hostHeld
  atomically (ready owner)
  publishFacts journal host owner facts

-- | The owner has declared it has no safe progress path.
afterStall ∷ Owner → STM ()
afterStall owner = readTVar (ownerStalls owner) >>= check . (> 0)

-- | Alpha's chain is safe and its own closed window has already been destroyed.
afterAlphaDestroyed ∷ TVar [Flag] → Owner → STM ()
afterAlphaDestroyed journal _ = readTVar journal >>= \flags → check (WindowGone 1 `elem` flags)

-- | A parent borrowed outside the protected lifetime, which may not be released
-- until every dependent is safe.
scriptedParent ∷ TVar [Flag] → Text → Scoped ()
scriptedParent journal name = allocResource (pure ()) (\() → atomically (note journal (ParentReleased name)))

-- | An attachment with no safe progress path keeps its window, the session, and
-- every parent, reports the stall exactly once, and finishes when independent
-- evidence arrives.
testStalledThenEvidence ∷ Expectation
testStalledThenEvidence = do
  journal ← newTVarIO []
  entries ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  withEvidenceSupplier withOwnedThreadOpening journal hostHeld owned $ \helper → do
    let logger = recordingLogger entries
    asProcessMainThread seam $
      runProtectedWindowApplication
        (withLoggingLifetime logger)
        "protected-host-example"
        ( \_ use →
            protectedHost seam logger (settings [windowNamed "alpha"]) $ \host → do
              window ← onlyWindow host
              owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Stall]}
              atomically (writeTVar owned (Just owner))
              atomically (writeTVar hostHeld (Just host))
              use host
        )
        id
        (\host _ → pure host)
        (\_ _ → pure ())
    void (pure helper)
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])
    stallReports entries `shouldReturn` 1

-- | The evidence supplier of the stalled-owner examples, started through the given scope (#593): the example, or the negative
-- control that starts it without ownership. It waits for the owner and the host the example's run publishes, so an example that
-- fails before the run publishes them leaves it parked for ever unless the scope stops it.
withEvidenceSupplier
  ∷ Scope
  → TVar [Flag]
  → TVar (Maybe WindowHost)
  → TVar (Maybe Owner)
  → (ThreadId → IO r)
  → IO r
withEvidenceSupplier scope journal hostHeld owned body =
  armed $ scope (pure ()) (supplyEvidence journal hostHeld owned afterStall allRetirementFacts) (\helper _ → body helper)

-- | The scenario of 'testStalledThenEvidence' for an example that fails before the run ever publishes the owner the supplier
-- waits for: the supplier is parked, waiting for an owner that never exists, and the example body ends the way the ending says.
supplierScenario ∷ Scope → IO () → IO ()
supplierScenario scope atParked = do
  journal ← newTVarIO []
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  withEvidenceSupplier scope journal hostHeld owned $ \helper → awaitParked helper >> atParked

-- | A declaration of the protocol that raises while the drain demands it is
-- contained, exactly as a failed step is.
--
-- Declarations are demanded when the attachment is made, so this state is
-- reached through the package's own after-acquisition seam. 'drainRetirement'
-- raises nothing for it either: the failure becomes that attachment's own
-- evidence, withdraws its progress path, and is settled against the body's
-- outcome only once retirement is safe. The window and the session are retained
-- until independent certified evidence retires the attachment — which is the
-- whole difference from an exception escaping the drain, where the window and
-- the session are released with every fact still owed.
testMetadataFailsInDrain ∷ Expectation
testMetadataFailsInDrain = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  withEvidenceThread (supplyEvidenceAfterFault journal hostHeld owned) $ \helper _ → do
    (failure, _) ←
      caughtAs . asProcessMainThread seam $
        runProtectedWindowApplication
          (withLoggingLifetime quietLogger)
          "protected-host-example"
          ( \_ use →
              protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
                window ← onlyWindow host
                owner ← establishedOwner journal host window (ownerNamed "alpha")
                acknowledgement ← awaitAcknowledgement owner
                atomically
                  ( faultHostAttachmentMetadata
                      host
                      (acknowledgedAttachment acknowledgement)
                      (throw (Scripted "declaration"))
                  )
                atomically (writeTVar owned (Just owner))
                atomically (writeTVar hostHeld (Just host))
                use host
          )
          id
          (\host _ → pure host)
          (\_ _ → pure ())
    void (pure helper)
    owner ← awaitHeld owned
    -- The step was never entered: the declaration is demanded before it.
    readTVarIO (ownerSteps owner) `shouldReturn` 0
    -- Every fact was certified independently, and the window and the session were
    -- released only afterwards.
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])
    -- It is the drain's own retained evidence, settled after retirement was safe.
    failure `shouldBe` Scripted "declaration"

-- | The owner's completion authority, once its construction has stored it.
awaitAcknowledgement ∷ Owner → IO Acknowledgement
awaitAcknowledgement owner =
  atomically (readTVar (ownerAcknowledgement owner) >>= maybe retry pure)

-- | Publish independent evidence once the drain has recorded the faulted
-- declaration against the attachment and withdrawn its progress path.
supplyEvidenceAfterFault ∷ TVar [Flag] → TVar (Maybe WindowHost) → TVar (Maybe Owner) → IO ()
supplyEvidenceAfterFault journal hostHeld owned = do
  owner ← awaitHeld owned
  host ← awaitHeld hostHeld
  atomically (afterDeclarationFailed host owner)
  publishFacts journal host owner allRetirementFacts

-- | The opening of a main-thread runner's scope (#593): release everything the registered owners still owe, from the moment each
-- owner was created, whether or not the example has published any handle yet. The arguments are the cells the example would
-- publish; they are no longer consulted, because a cancellation that lands after an attachment exists and before they are filled
-- would otherwise leave this with nothing to release while the runner's drain waits for it. It never blocks and never raises, and
-- it adds nothing once the run has finished: the boundary has closed publication, and a refused notice establishes nothing.
supplyIfHeld ∷ TVar [Flag] → TVar (Maybe WindowHost) → TVar (Maybe Owner) → [RetirementFact] → IO ()
supplyIfHeld _ _ _ _ = rescueNow

afterDeclarationFailed ∷ WindowHost → Owner → STM ()
afterDeclarationFailed host owner = do
  held ← readTVar (ownerAcknowledgement owner) >>= maybe retry pure
  seen ← hostAttachmentView host (acknowledgedAttachment held)
  case seen of
    Just view | disposalEvidence (viewEvidence view) → pure ()
    _ → retry

-- | The stall diagnostic is claimed once, and its own failure may not unwind
-- what the stall is retaining: the window is destroyed only after the evidence
-- arrives, and the diagnostic's failure becomes the run's outcome afterwards.
testStallDiagnosticFails ∷ Expectation
testStallDiagnosticFails = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  withEvidenceThread (supplyEvidence journal hostHeld owned afterStall allRetirementFacts) $ \helper _ → do
    let logger = failingLogger "glfw.retirement"
    (failure, _) ←
      caughtAs . asProcessMainThread seam $
        runProtectedWindowApplication
          (withLoggingLifetime logger)
          "protected-host-example"
          ( \_ use →
              protectedHost seam logger (settings [windowNamed "alpha"]) $ \host → do
                window ← onlyWindow host
                owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Stall]}
                atomically (writeTVar owned (Just owner))
                atomically (writeTVar hostHeld (Just host))
                use host
          )
          id
          (\host _ → pure host)
          (\_ _ → pure ())
    void (pure helper)
    failure `shouldBe` Scripted "sink"
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A chain that became safe before the drain, and whose destruction was
-- deferred while it was not, must not stay tied to a chain that stalls: the
-- drain retries closing windows in every round, not only one that progressed.
--
-- Nothing here progresses in the round that destroys the window — the only
-- other attachment stalls — so the retry is the whole reason it is destroyed
-- before the stalled chain finishes rather than after it.
testDeferredWindowRetired ∷ Expectation
testDeferredWindowRetired = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  betaHeld ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  duringRun ← newIORef Nothing
  withEvidenceThread (supplyEvidence journal hostHeld betaHeld afterStall allRetirementFacts) $ \helper _ → do
    asProcessMainThread seam $
      runProtectedWindowApplication
        (withLoggingLifetime quietLogger)
        "protected-host-example"
        ( \_ use →
            protectedHost seam quietLogger (settings [windowNamed "alpha", windowNamed "beta"]) $ \host → do
              (alpha, beta) ← twoWindows host
              alphaOwner ← establishedOwner journal host alpha (ownerNamed "alpha") {scriptPlan = []}
              betaOwner ← establishedOwner journal host beta (ownerNamed "beta") {scriptPlan = [Stall]}
              atomically (writeTVar betaHeld (Just betaOwner))
              atomically (writeTVar hostHeld (Just host))
              alphaAcknowledgement ←
                atomically (readTVar (ownerAcknowledgement alphaOwner) >>= maybe retry pure)
              -- Closing alpha's window begins its attachment's retirement and
              -- destroys nothing: its own veto defers that.
              closeHostWindow host alpha `shouldReturn` CloseStarted
              -- Alpha then becomes safe on the owner thread, before anything
              -- drains. Nothing retries its deferred destruction during the run,
              -- because the application runs no owner turn.
              forM_ allRetirementFacts $ \fact → do
                atomically (note journal (flagOf "alpha" fact))
                void (reportHostRetirementFact host alphaAcknowledgement fact)
              atomically (hostPendingAttachments host) >>= \pending → length pending `shouldBe` 1
              use host
        )
        id
        (\host _ → pure host)
        (\_ _ → destroyedWindows seam >>= writeIORef duringRun . Just)
    void (pure helper)
    readIORef duringRun `shouldReturn` Just []
    readTVarIO journal
      `shouldReturn` ( retiring "alpha"
                         <> [WindowGone 1]
                         <> retiring "beta"
                         <> [WindowGone 2, SessionEnded]
                     )

-- | The completion inbox holds one notice per retirement fact per window the
-- host may hold, so an integration can publish every obligation it has ended
-- without being refused.
testInboxHoldsEveryFact ∷ Expectation
testInboxHoldsEveryFact = inboxFixture (\_ → pure ())

-- | The fixture ended at the boundary before step @k@ (#593): 0 is the setup callback (nothing attached), 1 follows the window
-- lookup, 2 alpha's attachment, 3 beta's, 4 is the action before the publishers, 5 follows alpha's producer starting (before beta's
-- publication). Both plans are empty, so only published notices retire either chain, and the rescue registered with the host, which
-- certifies every fact for every owner registered so far, must be what finishes the exit from any of these.
inboxSetupScenario ∷ Int → Scope → IO () → IO ()
inboxSetupScenario k _ atParked = inboxFixture (\i → when (i == k) atParked)

inboxFixture ∷ (Int → IO ()) → Expectation
inboxFixture step = armed $ do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  asProcessMainThread seam $
    runProtectedWindowApplication
      (withLoggingLifetime quietLogger)
      "protected-host-example"
      ( \_ use →
          protectedHost seam quietLogger (settings [windowNamed "alpha", windowNamed "beta"]) $ \host → do
            step 0
            (alpha, beta) ← twoWindows host
            step 1
            alphaOwner ← establishedOwner journal host alpha (ownerNamed "alpha") {scriptPlan = []}
            step 2
            betaOwner ← establishedOwner journal host beta (ownerNamed "beta") {scriptPlan = []}
            step 3
            use (host, alphaOwner, betaOwner)
      )
      (\(host, _, _) → host)
      (\dependencies _ → pure dependencies)
      ( \(host, alphaOwner, betaOwner) _ → do
          step 4
          -- Every fact of every window at once: none may be refused, and the
          -- plans are empty, so only these notices can retire either chain.
          withPublisher (publishFacts journal host alphaOwner allRetirementFacts) $ \published → do
            step 5
            publishFacts journal host betaOwner allRetirementFacts
            takeMVar published
      )
  entries ← readTVarIO journal
  -- Both chains retired from notices alone, whichever order the two publishers
  -- interleaved in.
  filter isWindowGone entries `shouldBe` [WindowGone 2, WindowGone 1]
  length (filter (not . isWindowGone) entries) `shouldBe` 2 * length allRetirementFacts + 1
  where
    isWindowGone = \case
      WindowGone _ → True
      _ → False

-- | Run the work on an owned thread (#593) for the length of the body, which is given the cell the thread fills when the work
-- is done and waits for it itself. However the body ends, the thread has been stopped and joined before this returns.
withPublisher ∷ IO () → (MVar () → IO r) → IO r
withPublisher work body = do
  done ← newEmptyMVar
  withOwnedThread (work >> putMVar done ()) $ \_ _ → body done

-- | The window limit is refused below one, below the configured windows, and
-- above the bound every count a host derives from it stays exact within.
testWindowLimitBounds ∷ Expectation
testWindowLimitBounds = do
  let base = settings [windowNamed "alpha"]
  validateHostConfig base {hostWindowLimit = 1} `shouldBe` Right ()
  validateHostConfig base {hostWindowLimit = maximumWindowLimit} `shouldBe` Right ()
  validateHostConfig base {hostWindowLimit = 0} `shouldBe` Left (WindowLimitRejected 0)
  validateHostConfig base {hostWindowLimit = maximumWindowLimit + 1}
    `shouldBe` Left (WindowLimitRejected (maximumWindowLimit + 1))
  validateHostConfig base {hostWindowLimit = maxBound} `shouldBe` Left (WindowLimitRejected maxBound)
  validateHostConfig (settings [windowNamed "alpha", windowNamed "beta"]) {hostWindowLimit = 1}
    `shouldBe` Left (WindowLimitRejected 1)


-- | A construction that failed synchronously and a rollback that was then
-- cancelled: the cancellation is this thread's to answer and is never traded
-- for the synchronous failure, which is retained beside it.
testRollbackCancelledAfterFailure ∷ Expectation
testRollbackCancelledAfterFailure = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  rollingBack ← newEmptyMVar
  never ← newEmptyMVar
  withMainThread seam (void (tryPutMVar never RollbackUnsafe))
    ( protectedRunHere
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        ( \host → do
            window ← onlyWindow host
            void $
              attachOwner
                journal
                host
                window
                (ownerNamed "alpha")
                  { scriptConstruct = throwIO (Scripted "construction")
                  , scriptRollback = putMVar rollingBack () >> takeMVar never
                  }
        )
        (\_ _ → pure ())
        (\() _ → pure ())
    )
    $ \runner finished → do
    takeMVar rollingBack
    killThread runner
    takeMVar finished >>= \case
      Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
      Right () → unexpected "the cancelled rollback returned"
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A cancellation queued in the handoff out of the scope's own construction.
--
-- It is queued while the construction is uninterruptible — the killer is waited
-- for until it is itself parked delivering it — so it lands at the first point
-- the boundary restores, which is the handoff into the consumer. Nothing on the
-- protected consumer path runs, which is what pins where it landed, and the
-- host still tears down through its exit rather than escaping it.
testCancelledAtHandoff ∷ Expectation
testCancelledAtHandoff = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  registered ← newEmptyMVar
  proceed ← newEmptyMVar
  reached ← newIORef False
  entered ← newIORef False
  let hooks =
        noHostHooks
          { afterRegistration = putMVar registered () >> uninterruptibleMask_ (takeMVar proceed)
          , beforeConsumer = \_ → writeIORef reached True
          }
  withMainThread seam (void (tryPutMVar proceed ()))
    ( runProtectedWindowApplication
        (withLoggingLifetime quietLogger)
        "protected-host-example"
        ( \_ use →
            withProtectedWindowHostWith hooks quietLogger (seamSession seam defaultSessionConfig) (settings [windowNamed "alpha"]) use
        )
        id
        (\host _ → writeIORef entered True >> pure host)
        (\_ _ → pure ())
    )
    $ \runner finished → do
    takeMVar registered
    awaitBlockedOn BlockedOnMVar runner
    withOwnedThread (killThread runner) $ \killer _ → do
      awaitBlockedOn BlockedOnException killer
      putMVar proceed ()
      takeMVar finished >>= \case
        Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
        Right () → unexpected "the cancelled handoff returned"
      -- Delivered in the handoff itself: neither the protected consumer path nor
      -- the application's own startup began.
      readIORef reached `shouldReturn` False
      readIORef entered `shouldReturn` False
      readTVarIO journal `shouldReturn` [WindowGone 1, SessionEnded]

-- | Whether the boundary has closed completion publication, asked with a notice
-- of its own that names nothing the model can accept.
closedPublication ∷ CompletionPublisher → IO Bool
closedPublication publisher = do
  (_, acknowledgement) ← strayAttachment
  publishCompletion publisher (completionNotice (acknowledgedAttachment acknowledgement) acknowledgement CpuUseRetired)
    >>= \case
      CompletionClosed → pure True
      _ → pure False

-- | An identity and acknowledgement from a model of another host entirely: the
-- owner refuses every notice naming it, so offering one asks about admission
-- and nothing else.
strayAttachment ∷ IO (AttachmentId, Acknowledgement)
strayAttachment = do
  seam ← newSeam defaultScript
  identity ← hostIdentity <$> newUnique
  window ←
    asProcessMainThread seam $
      withScoped (seamSession seam defaultSessionConfig) $ \built →
        withWindow built (windowNamed "stray") (pure . windowIdentity)
  let session = windowSessionIdentity window
  case newAttachmentModel identity session 1 ∷ Either AttachmentConfigRejected (OwnerAuthority, AttachmentModel ()) of
    Left rejected → unexpected ("the stray model was refused: " <> show rejected)
    Right (authority, model) →
      case registerWindow authority window model >>= \(_, registered) → attachWindow authority identity window registered of
        Left refusal → unexpected ("the stray attachment was refused: " <> show refusal)
        Right (reserved, _) → pure (registeredAttachment reserved, registeredAcknowledgement reserved)

-- | Once the boundary has found retirement complete it closes publication in
-- that same transaction, so no later notice can register a notification the one
-- degradation report has already passed.
testPublicationCloses ∷ Expectation
testPublicationCloses = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  captured ← newIORef Nothing
  duringRun ← newIORef Nothing
  asProcessMainThread seam $
    runProtectedWindowApplication
      (withLoggingLifetime quietLogger)
      "protected-host-example"
      ( \_ use →
          withProtectedWindowHostWith
            noHostHooks {beforeConsumer = writeIORef captured . Just}
            quietLogger
            (seamSession seam defaultSessionConfig)
            (settings [windowNamed "alpha"])
            ( \host →
                ( do
                    window ← onlyWindow host
                    void (establishedOwner journal host window (ownerNamed "alpha"))
                    use host
                )
                  `rescuedUnlessDesigned` ()
            )
      )
      id
      (\host _ → pure host)
      ( \host _ → do
          publisher ← maybe (unexpected "the host publishes no completions") pure (hostCompletionPublisher host)
          closedPublication publisher >>= writeIORef duringRun . Just
      )
  -- Open while the application runs, closed once the drain has finished.
  readIORef duringRun `shouldReturn` Just False
  host ← readIORef captured >>= maybe (unexpected "the host was not captured") pure
  publisher ← maybe (unexpected "the host publishes no completions") pure (hostCompletionPublisher host)
  closedPublication publisher `shouldReturn` True
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A step interrupted partway may have disposed part of what it owns, and
-- nothing knows whether running it again would be safe, so its path is
-- withdrawn exactly as a failed step's is — which the stall diagnostic, owed
-- only when no path is left, is the evidence of.
testInterruptedStepWithdrawn ∷ Expectation
testInterruptedStepWithdrawn = do
  journal ← newTVarIO []
  entries ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  let logger = recordingLogger entries
  withMainThread seam (supplyIfHeld journal hostHeld owned allRetirementFacts)
    ( runProtectedWindowApplication
        (withLoggingLifetime logger)
        "protected-host-example"
        ( \_ use →
            protectedHost seam logger (settings [windowNamed "alpha"]) $ \host → do
              window ← onlyWindow host
              owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Blocking]}
              atomically (writeTVar owned (Just owner))
              atomically (writeTVar hostHeld (Just host))
              use host
        )
        id
        (\host _ → pure host)
        (\_ _ → pure ())
    )
    $ \runner finished → do
    owner ← awaitHeld owned
    host ← awaitHeld hostHeld
    -- The step has begun disposing and cannot return.
    atomically (readTVar (ownerSteps owner) >>= check . (>= 1))
    awaitBlockedOn BlockedOnSTM runner
    killThread runner
    -- With the path withdrawn, and no other, the boundary owes its one stall
    -- diagnostic; the step is never offered again until evidence arrives.
    atomically (afterStallReported entries)
    readTVarIO (ownerSteps owner) `shouldReturn` 1
    publishFacts journal host owner allRetirementFacts
    takeMVar finished >>= \case
      Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
      Right () → unexpected "the cancelled drain returned"
    stallReports entries `shouldReturn` 1
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A refused notice and a duplicate fact establish nothing, so neither may
-- revive a withdrawn path and make a failed disposal run again.
testOnlyNewEvidenceRevives ∷ Expectation
testOnlyNewEvidenceRevives = do
  journal ← newTVarIO []
  entries ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  let logger = recordingLogger entries
  withMainThread seam (supplyIfHeld journal hostHeld owned allRetirementFacts)
    ( runProtectedWindowApplication
        (withLoggingLifetime logger)
        "protected-host-example"
        ( \_ use →
            protectedHost seam logger (settings [windowNamed "alpha"]) $ \host → do
              window ← onlyWindow host
              owner ←
                establishedOwner
                  journal
                  host
                  window
                  (ownerNamed "alpha") {scriptPlan = [Certify CpuUseRetired, FailWith "disposal"]}
              atomically (writeTVar owned (Just owner))
              atomically (writeTVar hostHeld (Just host))
              use host
        )
        id
        (\host _ → pure host)
        (\_ _ → pure ())
    )
    $ \runner finished → do
    owner ← awaitHeld owned
    host ← awaitHeld hostHeld
    publisher ← maybe (unexpected "the host publishes no completions") pure (hostCompletionPublisher host)
    acknowledgement ← atomically (readTVar (ownerAcknowledgement owner) >>= maybe retry pure)
    -- The first fact was certified and the second step failed, so nothing has a
    -- path left and the stall is owed.
    atomically (afterStallReported entries)
    awaitBlockedOn BlockedOnSTM runner
    stepsBefore ← readTVarIO (ownerSteps owner)
    -- A duplicate of the fact already recorded, and a notice for another host's
    -- attachment entirely. Both are folded and both establish nothing.
    (stray, strayAcknowledgement) ← strayAttachment
    let target = acknowledgedAttachment acknowledgement
    void (publishCompletion publisher (completionNotice target acknowledgement CpuUseRetired))
    void (publishCompletion publisher (completionNotice stray strayAcknowledgement CpuUseRetired))
    -- The round that folded them has finished and parked again.
    awaitBlockedOn BlockedOnSTM runner
    readTVarIO (ownerSteps owner) `shouldReturn` stepsBefore
    -- Real evidence does revive it, and the run then finishes.
    publishFacts journal host owner (filter (/= CpuUseRetired) allRetirementFacts)
    takeMVar finished >>= \case
      Right () → unexpected "the required step's failure did not fail the run"
      Left caught → (fromException caught ∷ Maybe Scripted) `shouldBe` Just (Scripted "disposal")
    stallReports entries `shouldReturn` 1
    -- The first flag is the step's own certification; the rest are the published
    -- facts. The duplicate and the refused notice are offered directly, so they
    -- journal nothing and, having established nothing, change nothing.
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A cancellation queued as the last fact is certified, while the window's own
-- destruction is under way, is deferred: the destruction completes once, the
-- session and the parent outlive it, and the cancellation is the outcome only
-- afterwards.
testCancelledIntoDisposal ∷ Expectation
testCancelledIntoDisposal = do
  journal ← newTVarIO []
  destroying ← newEmptyMVar
  proceed ← newEmptyMVar
  seam ← destroyGatedSeam journal destroying proceed
  withMainThread seam (void (tryPutMVar proceed ()))
    ( runProtectedWindowApplication
        (withLoggingLifetime quietLogger)
        "protected-host-example"
        ( \_ use →
            withScoped (scriptedParent journal "parent") $ \() →
              protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
                window ← onlyWindow host
                void (establishedOwner journal host window (ownerNamed "alpha"))
                use host
        )
        id
        (\host _ → pure host)
        ( \host _ → do
            window ← onlyWindow host
            closeHostWindow host window `shouldReturn` CloseStarted
        )
    )
    $ \runner finished → do
    -- The drain certified the last fact and is inside the window's destruction,
    -- which runs uninterruptibly.
    takeMVar destroying
    withOwnedThread (killThread runner) $ \killer _ → do
      awaitBlockedOn BlockedOnException killer
      putMVar proceed ()
      takeMVar finished >>= \case
        Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
        Right () → unexpected "the cancelled disposal returned"
      -- Destroyed exactly once, and the session and the parent released only after
      -- it, whatever was queued during it.
      readTVarIO journal
        `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded, ParentReleased "parent"])

-- | 'journallingSeam' whose destroy hook parks until the example releases it,
-- so a cancellation can be queued while the destruction is in flight.
destroyGatedSeam ∷ TVar [Flag] → MVar () → MVar () → IO Seam
destroyGatedSeam journal destroying proceed = do
  posts ← newTVarIO (0 ∷ Int)
  held ← newIORef Nothing
  seam ←
    newSeam
      defaultScript
        { scriptDestroyWindow = \_ → do
            destroyed ← readIORef held >>= maybe (pure 0) (fmap latestDestroyed . seamCalls)
            atomically (note journal (WindowGone destroyed))
            putMVar destroying ()
            takeMVar proceed
        , scriptTerminate = \_ → atomically (note journal SessionEnded)
        , scriptWaitEvents = \_ _ →
            atomically (readTVar posts >>= \pending → if pending <= 0 then retry else writeTVar posts (pending - 1))
        , scriptPostEmptyEvent = \_ → atomically (modifyTVar' posts (+ 1))
        }
  writeIORef held (Just seam)
  pure seam

-- ---------------------------------------------------------------------------
-- Failed retirement steps

-- | A failed step keeps its evidence, withdraws the attachment's progress path
-- rather than replaying it, and never makes the attachment safe. A required
-- failure fails the application; a recognized optional one leaves the component
-- unavailable — and neither is permission to destroy the dependent.
testFailedStep ∷ Disposition → Expectation
testFailedStep disposition = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  withEvidenceThread (supplyEvidence journal hostHeld owned afterFailedStep [CpuUseRetired]) $ \helper _ → do
    outcome ←
      try . asProcessMainThread seam $
        runProtectedWindowApplication
          (withLoggingLifetime quietLogger)
          "protected-host-example"
          ( \_ use →
              protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
                window ← onlyWindow host
                owner ←
                  establishedOwner
                    journal
                    host
                    window
                    (ownerNamed "alpha")
                      { scriptPlan = FailWith "disposal" : map Certify allRetirementFacts
                      , scriptDisposition = disposition
                      , scriptRecognizes = disposition == Optional
                      }
                atomically (writeTVar owned (Just owner))
                atomically (writeTVar hostHeld (Just host))
                use host
          )
          id
          (\host _ → pure host)
          (\_ _ → pure ())
    void (pure helper)
    owner ← awaitHeld owned
    seen ← readTVarIO (ownerViews owner)
    -- The step ran once, its evidence is the attachment's, and the only fact it
    -- no longer owed by the next opportunity is the one the notice certified.
    map (disposalEvidence . viewEvidence) (take 1 seen) `shouldBe` [True]
    map viewMissing (take 1 seen) `shouldBe` [filter (/= CpuUseRetired) allRetirementFacts]
    readTVarIO (ownerPlan owner) `shouldReturn` []
    -- The notice certifies CPU-use retirement; the revived plan then certifies
    -- every fact, the first of which the model has already recorded.
    readTVarIO journal
      `shouldReturn` ([CpuUsesEnded "alpha"] <> retiring "alpha" <> [WindowGone 1, SessionEnded])
    case (disposition, outcome ∷ Either SomeException ()) of
      (Required, Left caught) → (fromException caught ∷ Maybe Scripted) `shouldBe` Just (Scripted "disposal")
      (Required, Right ()) → unexpected "the required failure did not fail the run"
      (Optional, Right ()) → pure ()
      (Optional, Left caught) → unexpected ("the optional failure failed the run: " <> show caught)

-- | The independent safe evidence that revives a withdrawn progress path: one
-- certified fact, published from a thread that is not the owner, once the step
-- that failed has been taken and withdrawn.
-- | The step that fails has been taken, so its path has been withdrawn.
afterFailedStep ∷ Owner → STM ()
afterFailedStep owner = readTVar (ownerPlan owner) >>= \plan → check (FailWith "disposal" `notElem` plan)

disposalEvidence ∷ AttachmentEvidence Evidence → Bool
disposalEvidence evidence = case evidenceFirstFailure evidence of
  Just (DisposalFailure _) → True
  _ → False


-- | An attachment made on the protected lifetime's own consumer path, which
-- then fails, is drained exactly as the consumer's own are: the handler is
-- already installed when it runs.
testHandoffAttachmentDrained ∷ Failing → Expectation
testHandoffAttachmentDrained failing = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  entered ← newIORef False
  reaching ← newEmptyMVar
  never ← newEmptyMVar
  let onHandoff host = do
        window ← onlyWindow host
        void (establishedOwner journal host window (ownerNamed "alpha"))
        case failing of
          ByFailure → throwIO (Scripted "handoff")
          ByCancellation → putMVar reaching () >> takeMVar never
      hooks = noHostHooks {beforeConsumer = onHandoff}
      run =
        runProtectedWindowApplication
          (withLoggingLifetime quietLogger)
          "protected-host-example"
          ( \_ use →
              withProtectedWindowHostWith hooks quietLogger (seamSession seam defaultSessionConfig) (settings [windowNamed "alpha"]) use
          )
          id
          (\_ _ → writeIORef entered True)
          (\() _ → pure ())
  case failing of
    ByFailure → do
      (failure, _) ← caughtAs (asProcessMainThread seam run)
      failure `shouldBe` Scripted "handoff"
    ByCancellation → do
      withMainThread seam (pure ()) run $ \runner finished → do
        takeMVar reaching
        killThread runner
        takeMVar finished >>= \case
          Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
          Right () → unexpected "the cancelled handoff returned"
  readIORef entered `shouldReturn` False
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | How the attachment made on the handoff ends.
data Failing = ByFailure | ByCancellation
  deriving (Eq, Show)

-- | The protected exit closes the host's whole admission, not only its
-- attachments', before it drains and reports: a command admitted or a demand
-- published afterwards would register a notification obligation the wake
-- path's one report has already waited past.
--
-- The application installs no quiescence hook, so this exit is the only thing
-- that closes anything.
testLateAdmissionRefused ∷ Expectation
testLateAdmissionRefused = do
  journal ← newTVarIO []
  entries ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  refusals ← newEmptyMVar
  let logger = recordingLogger entries
  withEvidenceThread
    ( do
        owner ← awaitHeld owned
        host ← awaitHeld hostHeld
        -- The drain has begun and has nothing it can do.
        atomically (afterStallReported entries)
        submitted ← submitWindowCommand (hostCommandPort host) [] (createWindowCommand (windowNamed "late"))
        published ← publishDemand (hostDemandPublisher host) immediateDemand
        putMVar refusals (submitted, published)
        publishFacts journal host owner allRetirementFacts
    )
    $ \helper _ → do
    asProcessMainThread seam $
      runManagedApplication
        (withLoggingLifetime logger)
        "protected-host-example"
        ( \use →
            protectedHost seam logger (settings [windowNamed "alpha"]) $ \host → do
              window ← onlyWindow host
              owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Stall]}
              atomically (writeTVar owned (Just owner))
              atomically (writeTVar hostHeld (Just host))
              use host
        )
        -- No quiescence: the protected exit is the only close.
        (\_ → pure ())
        (\host _ → pure host)
        (\_ _ → pure ())
    void (pure helper)
    (submitted, published) ← takeMVar refusals
    submitted `shouldBe` SubmitClosed
    published `shouldBe` DemandSlotClosed
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A chain with no safe path is retaining its window, the session, and its
-- parents from that round on, and a chain beside it that only ever awaits must
-- not be able to keep that from being reported.
testStallReportedBesideAwaiting ∷ Expectation
testStallReportedBesideAwaiting = do
  journal ← newTVarIO []
  entries ← newTVarIO []
  seam ← journallingSeam journal
  stalledHeld ← newTVarIO Nothing
  awaitingHeld ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  let logger = recordingLogger entries
  withEvidenceThread
    ( do
        stalled ← awaitHeld stalledHeld
        awaiting ← awaitHeld awaitingHeld
        host ← awaitHeld hostHeld
        -- The diagnostic is owed although the other chain keeps answering that it
        -- may yet progress.
        atomically (afterStallReported entries)
        publishFacts journal host stalled allRetirementFacts
        publishFacts journal host awaiting allRetirementFacts
    )
    $ \helper _ → do
    asProcessMainThread seam $
      runProtectedWindowApplication
        (withLoggingLifetime logger)
        "protected-host-example"
        ( \_ use →
            protectedHost seam logger (settings [windowNamed "alpha", windowNamed "beta"]) $ \host → do
              (alpha, beta) ← twoWindows host
              stalled ← establishedOwner journal host alpha (ownerNamed "alpha") {scriptPlan = [Stall]}
              -- Never runs out: every opportunity answers that progress may still
              -- become possible, so this chain never loses its own path.
              awaiting ← establishedOwner journal host beta (ownerNamed "beta") {scriptPlan = replicate 200 Await}
              atomically (writeTVar stalledHeld (Just stalled))
              atomically (writeTVar awaitingHeld (Just awaiting))
              atomically (writeTVar hostHeld (Just host))
              use host
        )
        id
        (\host _ → pure host)
        (\_ _ → pure ())
    void (pure helper)
    stallReports entries `shouldReturn` 1
    stallCounts entries `shouldReturn` [Just ("1", "2")]
    readTVarIO journal
      `shouldReturn` ( retiring "alpha"
                         <> retiring "beta"
                         <> [WindowGone 2, WindowGone 1, SessionEnded]
                     )

-- | How many of the attachments still pending each stall diagnostic named as
-- stalled, and how many were pending at all.
stallCounts ∷ TVar [LogEntry] → IO [Maybe (Text, Text)]
stallCounts entries = map counted . stalls <$> readTVarIO entries
  where
    counted entry =
      (,) <$> Map.lookup "stalled" (entryFields entry) <*> Map.lookup "attachments" (entryFields entry)

-- | A body failure stays the primary exception, with the drain's own failure
-- retained beside it under the protected boundary's cleanup label — never the
-- other way round, and never instead of it.
testBodyFailureStaysPrimary ∷ Expectation
testBodyFailureStaysPrimary = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  withEvidenceThread (supplyEvidence journal hostHeld owned afterFailedStep [CpuUseRetired]) $ \helper _ → do
    (primary, caught) ←
      asProcessMainThread seam . caughtAs $
        runProtectedWindowApplication
          (withLoggingLifetime quietLogger)
          "protected-host-example"
          ( \_ use →
              protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
                window ← onlyWindow host
                owner ←
                  establishedOwner
                    journal
                    host
                    window
                    (ownerNamed "alpha") {scriptPlan = FailWith "disposal" : map Certify allRetirementFacts}
                atomically (writeTVar owned (Just owner))
                atomically (writeTVar hostHeld (Just host))
                use host
          )
          id
          (\host _ → pure host)
          (\_ _ → throwIO (Scripted "action"))
    void (pure helper)
    -- The action's own failure, unchanged.
    primary `shouldBe` Scripted "action"
    -- The drain's failure beside it, under this boundary's label.
    retainedUnder "glfw protected retirement" caught `shouldBe` [Just (Scripted "disposal")]
    -- The notice certifies CPU-use retirement, then the revived plan certifies
    -- every fact, the first of which the model already holds.
    readTVarIO journal
      `shouldReturn` ([CpuUsesEnded "alpha"] <> retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | The exceptions a failure retained under one cleanup label, in the order
-- inspection reports them.
retainedUnder ∷ Text → SomeException → [Maybe Scripted]
retainedUnder label caught =
  [ fromException (exceptionOf (cleanupFailureException failure))
  | failure ← cleanupFailures caught
  , cleanupFailureLabel failure == label
  ]


-- | A callback may return a value that raises only when it is demanded. Both
-- construction and its rollback are forced inside the boundary that catches
-- them, so neither leaves the reservation pending with nothing able to settle
-- it and the drain unable ever to finish.
testLazyCallbackResults ∷ Expectation
testLazyCallbackResults = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  answered ← newIORef Nothing
  asProcessMainThread seam $
    runProtectedWindowApplication
      (withLoggingLifetime quietLogger)
      "protected-host-example"
      ( \_ use →
          protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
            window ← onlyWindow host
            (_, outcome) ←
              attachOwner
                journal
                host
                window
                (ownerNamed "alpha")
                  { scriptConstruct = pure (throw (Scripted "lazy construction"))
                  , scriptRollback = pure (throw (Scripted "lazy rollback"))
                  }
            writeIORef answered (Just outcome)
            use host
      )
      id
      (\host _ → pure host)
      (\_ _ → pure ())
  readIORef answered >>= \case
    Just (AttachmentRolledBack settled) → do
      -- A rollback whose own result raised established no safety.
      rolledBackOutcome settled `shouldBe` RollbackUnsafe
      (fromException (exceptionOf (rolledBackFailure settled)) ∷ Maybe Scripted)
        `shouldBe` Just (Scripted "lazy construction")
      (fromException . exceptionOf <$> rolledBackRollback settled)
        `shouldBe` Just (Just (Scripted "lazy rollback"))
    other → unexpected ("the lazy construction was not answered: " <> show other)
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A sink whose result raises only when demanded is caught inside the stall
-- attempt, so it is retained like any other diagnostic failure and unwinds
-- nothing the stall is holding.
testLazyStallDiagnosticFails ∷ Expectation
testLazyStallDiagnosticFails = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  withEvidenceThread (supplyEvidence journal hostHeld owned afterStall allRetirementFacts) $ \helper _ → do
    let logger = lazilyFailingLogger "glfw.retirement"
    (failure, _) ←
      asProcessMainThread seam . caughtAs $
        runProtectedWindowApplication
          (withLoggingLifetime logger)
          "protected-host-example"
          ( \_ use →
              protectedHost seam logger (settings [windowNamed "alpha"]) $ \host → do
                window ← onlyWindow host
                owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Stall]}
                atomically (writeTVar owned (Just owner))
                atomically (writeTVar hostHeld (Just host))
                use host
          )
          id
          (\host _ → pure host)
          (\_ _ → pure ())
    void (pure helper)
    failure `shouldBe` Scripted "lazy sink"
    -- Retained, not raised through the scope: the window outlived the stall.
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A logger whose sink returns, for one component, a unit that raises when it
-- is demanded rather than raising as it is run.
lazilyFailingLogger ∷ Text → Logger
lazilyFailingLogger component =
  mkLoggerWith defaultLogFilter systemMetadata . callbackSink $ \entry →
    pure (if componentText (entryComponent entry) == component then throw (Scripted "lazy sink") else ())

-- | Two chains whose steps both fail, so the boundary retains two failures
-- beside the body's own: inspection reports them in the order the drain found
-- them, not reversed by the scopes that carry them.
testRetainedEvidenceOrder ∷ Expectation
testRetainedEvidenceOrder = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  firstHeld ← newTVarIO Nothing
  secondHeld ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  withEvidenceThread
    ( do
        alpha ← awaitHeld firstHeld
        beta ← awaitHeld secondHeld
        host ← awaitHeld hostHeld
        atomically (afterFailedStep alpha >> afterFailedStep beta)
        publishFacts journal host alpha [CpuUseRetired]
        publishFacts journal host beta [CpuUseRetired]
    )
    $ \helper _ → do
    (primary, caught) ←
      asProcessMainThread seam . caughtAs $
        runProtectedWindowApplication
          (withLoggingLifetime quietLogger)
          "protected-host-example"
          ( \_ use →
              protectedHost seam quietLogger (settings [windowNamed "alpha", windowNamed "beta"]) $ \host → do
                (alpha, beta) ← twoWindows host
                -- Stepped in registration order, so the failures happen in this
                -- order too.
                first ← establishedOwner journal host alpha (failingOwner "alpha" "first")
                second ← establishedOwner journal host beta (failingOwner "beta" "second")
                atomically (writeTVar firstHeld (Just first))
                atomically (writeTVar secondHeld (Just second))
                atomically (writeTVar hostHeld (Just host))
                use host
          )
          id
          (\host _ → pure host)
          (\_ _ → throwIO (Scripted "action"))
    void (pure helper)
    primary `shouldBe` Scripted "action"
    retainedUnder "glfw protected retirement" caught
      `shouldBe` [Just (Scripted "first"), Just (Scripted "second")]
    destructions journal `shouldReturn` [WindowGone 2, WindowGone 1]

-- | An owner whose first opportunity fails and whose later ones certify.
failingOwner ∷ Text → Text → OwnerScript
failingOwner name message =
  (ownerNamed name) {scriptPlan = FailWith message : map Certify allRetirementFacts}

destructions ∷ TVar [Flag] → IO [Flag]
destructions journal = filter isWindowGone <$> readTVarIO journal
  where
    isWindowGone = \case
      WindowGone _ → True
      _ → False

-- ---------------------------------------------------------------------------
-- Closing an attached window during the run

-- | Closing an attached window begins its retirement and destroys nothing. The
-- window stays alive — with its close acknowledged — until every one of its
-- attachment's facts is certified, and a later owner turn then destroys it.
testEarlyClose ∷ Expectation
testEarlyClose = earlyCloseFixture (\_ → pure ())

-- | The fixture ended at the boundary before step @k@ (#593): 0 is the setup callback (nothing attached), 1 follows the attachment (the
-- owner's plan is empty, so only the facts the action's loop reports can retire it), 2 is the action's start, 3 is the loop's first
-- turn. The rescue registered with the host certifies every fact for every owner registered so far.
earlyCloseScenario ∷ Int → Scope → IO () → IO ()
earlyCloseScenario k _ atParked = earlyCloseFixture (\i → when (i == k) atParked)

earlyCloseFixture ∷ (Int → IO ()) → Expectation
earlyCloseFixture step = armed $ do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  owned ← newTVarIO Nothing
  whileRetiring ← newIORef Nothing
  afterSafety ← newIORef Nothing
  asProcessMainThread seam $
    runProtectedWindowApplication
      (withLoggingLifetime quietLogger)
      "protected-host-example"
      ( \_ use →
          protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
            step 0
            window ← onlyWindow host
            owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = []}
            step 1
            atomically (writeTVar owned (Just owner))
            use host
      )
      id
      (\host _ → pure host)
      ( \host control → do
          step 2
          window ← onlyWindow host
          owner ← heldOwner owned
          acknowledgement ← atomically (readTVar (ownerAcknowledgement owner) >>= maybe retry pure)
          runOwnerLoop host control $
            LoopHooks
              { loopLogger = quietLogger
              , loopEvent = noApplicationEvents
              , loopUpdate = \turn → case turnNumber turn of
                  1 → Continue <$ (step 3 >> (closeHostWindow host window `shouldReturn` CloseStarted))
                  2 → do
                    -- The close is acknowledged and the attachment is retiring,
                    -- but the window is not destroyed: its attachment vetoes it.
                    destroyed ← destroyedWindows seam
                    writeIORef whileRetiring (Just destroyed)
                    forM_ allRetirementFacts (void . reportHostRetirementFact host acknowledgement)
                    pure Continue
                  3 → pure Continue
                  _ → do
                    destroyed ← destroyedWindows seam
                    writeIORef afterSafety (Just destroyed)
                    pure (Finish ())
              }
      )
  readIORef whileRetiring `shouldReturn` Just []
  readIORef afterSafety `shouldReturn` Just [1]
  readTVarIO journal `shouldReturn` [WindowGone 1, SessionEnded]

destroyedWindows ∷ Seam → IO [Int]
destroyedWindows seam = (\calls → [key | DestroyWindow key ← calls]) <$> seamCalls seam

-- ---------------------------------------------------------------------------
-- Failed stall warnings

-- | The drain's retained-failure budget is already full when the stall
-- diagnostic's sink fails.
--
-- Ten attachment steps fail in the first round: one becomes the drain's first
-- failure, eight fill the retained bound, and the tenth is only counted. The
-- generic retention would elide the diagnostic's own failure next, and with it
-- the mark the runtime reads — so the boundary would report through the sink
-- that had just failed, and the lifetime would flush through it. It is kept
-- past the bound instead, which is one entry, because a drain claims exactly
-- one such diagnostic.
testStallWarningSurvivesAFullBudget ∷ Expectation
testStallWarningSurvivesAFullBudget = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  established ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  trace ← newSinkTrace
  declared ← newEmptyMVar
  withEvidenceThread
    ( do
        owners ← awaitHeld established
        host ← awaitHeld hostHeld
        -- The diagnostic has reached its sink, so every step in that round has
        -- already failed and the budget is full. Independent evidence then finishes
        -- the retirement the failed steps withdrew.
        takeMVar declared
        forM_ owners (\owner → publishFacts journal host owner allRetirementFacts)
    )
    $ \helper _ → do
    let logger =
          failingSink defaultLogFilter "glfw.retirement" (\_ → putMVar declared ()) trace
        faulty = [windowNamed ("faulty " <> Text.pack (show n)) | n ← [1 .. failingChains]]
    (failure, context) ←
      raisedWith
        =<< protectedFailure seam logger (settings faulty)
          ( \host → do
              identities ← atomically (hostWindowIdentities host)
              owners ← forM (zip [1 ..] identities) $ \(n ∷ Int, window) →
                establishedOwner journal host window $
                  (ownerNamed ("faulty " <> Text.pack (show n)))
                    {scriptPlan = FailWith "step" : map Certify allRetirementFacts}
              atomically (writeTVar established (Just owners))
              atomically (writeTVar hostHeld (Just host))
          )
          (\host _ → pure host)
          (\_ _ → pure ())
    void (pure helper)
    -- The body returned, so the drain's first failure is the run's own: a failed
    -- step, not the diagnostic.
    failure `shouldBe` Scripted "step"
    diagnosticMarks context `shouldBe` []
    -- One attempt through the sink, and no terminal report after it.
    traced trace `shouldReturn` ["glfw.retirement"]
    flushed trace `shouldReturn` 0
    -- The bound really was full: exactly its own number of step failures were
    -- retained beside the primary, though ten failed, so one did not fit.
    [step | (Just step, _) ← retainedAs "glfw protected retirement" context]
      `shouldBe` replicate retainedFailureLimit (Scripted "step")
    -- Those, the count of the one the bound elided, and the diagnostic kept past
    -- the bound, and nothing else.
    let retained = retainedDiagnostics context
    length retained `shouldBe` retainedFailureLimit + 2
    -- Exactly one of them was raised by a diagnostic, and it is the sink's own
    -- exception with the context it raised it with.
    filter snd retained `shouldBe` [("glfw protected retirement", True)]
    [kept | kept@(Just _, _) ← retainedAs "glfw protected retirement" context]
      `shouldBe` [(Just (SinkFailed "glfw.retirement"), [SinkMark])]
    -- Which is what the lifetime was told, so nothing was written or flushed.
    length (Logging.failedReportsInContext context) `shouldBe` 1
    -- Every window went and the session after them. Which chain's window goes
    -- first is the ordering examples' claim, not this one's.
    (sort <$> destroyedWindows seam) `shouldReturn` [1 .. failingChains]
    (last <$> readTVarIO journal) `shouldReturn` SessionEnded

-- | Enough failing chains to fill the retained bound and overflow it before the
-- stall diagnostic is claimed: one becomes primary, 'retainedFailureLimit' are
-- retained, and the rest are counted.
failingChains ∷ Int
failingChains = retainedFailureLimit + 2

-- | Run a protected application over a seam host and hand back the failure it
-- raised, with its context.
--
-- The catch is inside the thread the seam designates because
-- 'Control.Concurrent.runInBoundThread' carries an outcome back out by
-- rethrowing a plain 'SomeException', which leaves an example nothing to
-- inspect, and every assertion below is about evidence the exception carries.
protectedFailure
  ∷ Seam
  → Logger
  → HostConfig
  → (WindowHost → IO ())
  → (WindowHost → RuntimeControl → IO s)
  → (s → RuntimeControl → IO a)
  → IO (ExceptionWithContext SomeException)
protectedFailure seam logger config inside startup action = do
  outcome ←
    asProcessMainThread seam . tryWithContext $
      protectedRunHere seam logger config inside startup action
  either pure (\_ → unexpected "the run returned instead of failing") outcome

-- | The wake path's own warning fails at the protected exit's boundary, which
-- claims it after the drain has retired every attachment.
--
-- It is the same policy the [stall diagnostic] follows and the same one the
-- ordinary runner's boundary follows, reached through the protected lifetime:
-- the failure leaves carrying the diagnostic-failure identity, the runtime
-- writes nothing further through the sink that just failed, and the logging
-- lifetime attempts no final flush through it. Nothing is released early — the
-- window and the session go only after the report, at the ordinary unwind.
testProtectedWakeWarningFailsAtExit ∷ Expectation
testProtectedWakeWarningFailsAtExit = do
  journal ← newTVarIO []
  seam ← wakeFailingSeam journal
  trace ← newSinkTrace
  live ← newTVarIO []
  let logger =
        failingSink defaultLogFilter "glfw.wake" (\_ → readTVarIO journal >>= atomically . writeTVar live) trace
  (failure, context) ←
    raisedWith
      =<< protectedFailure seam logger (settings [windowNamed "alpha"])
        (\_ → pure ())
        (\host _ → pure host)
        -- Admitted with the wake failing, so the degradation is owed and only
        -- the protected exit's own boundary, after the drain, can claim it.
        (\host _ → degradeWakePath host)
  failure `shouldBe` SinkFailed "glfw.wake"
  traced trace `shouldReturn` ["glfw.wake"]
  flushed trace `shouldReturn` 0
  diagnosticMarks context `shouldBe` [DiagnosticFailure]
  sinkMarks context `shouldBe` [SinkMark]
  length (Logging.failedReportsInContext context) `shouldBe` 1
  -- The window and the session were still live when the warning was written.
  readTVarIO live `shouldReturn` []
  readTVarIO journal `shouldReturn` [WindowGone 1, SessionEnded]

-- | The same warning fails at that boundary while the action's failure is
-- already primary: the action's failure stays primary and unmarked, and the
-- warning's own is retained beside it under this boundary's own
-- @glfw protected retirement@ label, which is where the protected exit retains
-- everything its drain and its report found. The lifetime is still told, so
-- nothing further is written or flushed through the sink.
testProtectedWakeWarningFailsBesideAPrimary ∷ Expectation
testProtectedWakeWarningFailsBesideAPrimary = do
  journal ← newTVarIO []
  seam ← wakeFailingSeam journal
  trace ← newSinkTrace
  (failure, context) ←
    raisedWith
      =<< protectedFailure seam (sinkFailingOn "glfw.wake" trace) (settings [windowNamed "alpha"])
        (\_ → pure ())
        (\host _ → pure host)
        (\host _ → degradeWakePath host >> throwIO (Scripted "action"))
  failure `shouldBe` Scripted "action"
  traced trace `shouldReturn` ["glfw.wake"]
  flushed trace `shouldReturn` 0
  diagnosticMarks context `shouldBe` []
  retainedDiagnostics context `shouldBe` [("glfw protected retirement", True)]
  retainedAs "glfw protected retirement" context
    `shouldBe` [(Just (SinkFailed "glfw.wake"), [SinkMark])]
  length (Logging.failedReportsInContext context) `shouldBe` 1
  readTVarIO journal `shouldReturn` [WindowGone 1, SessionEnded]

-- | A journalling seam whose empty-event post reports an expected platform
-- failure, so the first notification degrades the session's wake path. Its wait
-- does not block: these examples register no attachment, so the drain has
-- nothing to be woken for.
wakeFailingSeam ∷ TVar [Flag] → IO Seam
wakeFailingSeam =
  journallingSeamPosting False (\reporter → reportError reporter 0x00010008 "scripted wake failure")

-- | Admit one command, whose wake fails and degrades the session's wake path.
-- Nothing executes it: the exit's quiescence settles it as unexecuted.
degradeWakePath ∷ WindowHost → IO ()
degradeWakePath host =
  void (submitWindowCommand (hostCommandPort host) [] (createWindowCommand (windowNamed "waker")))

-- | The stall diagnostic's sink fails during the protected shutdown, after a
-- body that returned. The drain retains that failure rather than raising it
-- through the scopes the stall is holding, independent evidence then finishes
-- retirement, and the exit settles the warning's failure as the run's own.
--
-- It carries the runtime's diagnostic-failure identity, so the runtime attempts
-- no terminal report through the sink that just failed, and the logging
-- lifetime attempts no final flush through it.
testStallWarningFailsIsDiagnostic ∷ Expectation
testStallWarningFailsIsDiagnostic = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  trace ← newSinkTrace
  withEvidenceThread (supplyEvidence journal hostHeld owned afterStall allRetirementFacts) $ \helper _ → do
    let logger = sinkFailingOn "glfw.retirement" trace
    (failure, context) ←
      raisedWith
        =<< protectedFailure seam logger (settings [windowNamed "alpha"])
          ( \host → do
              window ← onlyWindow host
              owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Stall]}
              atomically (writeTVar owned (Just owner))
              atomically (writeTVar hostHeld (Just host))
          )
          (\host _ → pure host)
          (\_ _ → pure ())
    void (pure helper)
    failure `shouldBe` SinkFailed "glfw.retirement"
    -- One attempt through the sink and nothing after it: no second write.
    traced trace `shouldReturn` ["glfw.retirement"]
    flushed trace `shouldReturn` 0
    diagnosticMarks context `shouldBe` [DiagnosticFailure]
    -- The exception the sink raised, with the context it raised it with.
    sinkMarks context `shouldBe` [SinkMark]
    length (Logging.failedReportsInContext context) `shouldBe` 1
    -- Nothing the stall was retaining was unwound early: the window and the
    -- session went only once independent evidence made the attachment safe.
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | The same warning fails while the action's failure is already primary.
--
-- That failure stays primary and is not marked as a diagnostic's, because no
-- diagnostic raised it; the warning's own failure is retained beside it under
-- the protected boundary's label, carrying the mark. The runtime still makes no
-- second write and the lifetime still no flush.
testStallWarningFailsBesideAPrimary ∷ Expectation
testStallWarningFailsBesideAPrimary = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  trace ← newSinkTrace
  withEvidenceThread (supplyEvidence journal hostHeld owned afterStall allRetirementFacts) $ \helper _ → do
    let logger = sinkFailingOn "glfw.retirement" trace
    (failure, context) ←
      raisedWith
        =<< protectedFailure seam logger (settings [windowNamed "alpha"])
          ( \host → do
              window ← onlyWindow host
              owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Stall]}
              atomically (writeTVar owned (Just owner))
              atomically (writeTVar hostHeld (Just host))
          )
          (\host _ → pure host)
          (\_ _ → throwIO (Scripted "action"))
    void (pure helper)
    failure `shouldBe` Scripted "action"
    traced trace `shouldReturn` ["glfw.retirement"]
    flushed trace `shouldReturn` 0
    diagnosticMarks context `shouldBe` []
    retainedDiagnostics context `shouldBe` [("glfw protected retirement", True)]
    -- Retained as the sink raised it: the diagnostic's own exception, not a copy.
    retainedAs "glfw protected retirement" context
      `shouldBe` [(Just (SinkFailed "glfw.retirement"), [SinkMark])]
    length (Logging.failedReportsInContext context) `shouldBe` 1
    readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A cancellation delivered while the stall diagnostic's sink is running is
-- never turned into a synchronous logging failure.
--
-- The drain defers it exactly as it defers any other, finishes on the
-- independent evidence that arrives, and re-raises it only once retirement is
-- safe: it leaves unmarked, with no report and no flush behind it.
--
-- The evidence supplier and the dedicated runner are owned starts (#612). The scope that owns the runner opens, before it kills it,
-- what the protected drain would otherwise wait for: every registered owner is released and the sink's hold is let go. Both are
-- idempotent and block on nothing, and they are not part of the scenario, which is what the sink's hold is for: the example kills the
-- runner while it is inside the sink, and that cancellation is the subject.
testStallWarningCancelledAtItsSink ∷ Expectation
testStallWarningCancelledAtItsSink = do
  recorded ← newIORef []
  probe ← newStallProbe
  stallSink (recordingThreads recorded withOwnedThreadOpening) (recordingThreads recorded withOwnedBoundThreadOpening) True probe Nothing
  endedAndJoined recorded >>= (`shouldBe` True)

-- | What the stall-sink fixture lets its caller see and let go.
data StallProbe = StallProbe
  { probeReached ∷ !(MVar ())
    -- ^ Filled when the sink has been entered.
  , probeNever ∷ !(MVar ())
    -- ^ The sink's hold: nothing fills it but the runner's scope, or a control's rescue.
  , probeEntered ∷ !(MVar ())
    -- ^ Filled when the runner is inside its first retirement opportunity of a scenario.
  , probeProceed ∷ !(MVar ())
    -- ^ What that opportunity waits for; a scenario never fills it before the cleanup kill.
  , probeOwned ∷ !(TVar (Maybe Owner))
  , probeJournal ∷ !(TVar [Flag])
  , probeOpened ∷ !(TVar Bool)
    -- ^ Whether the scope that owns the runner opened what the drain waits for. A control that sees the drain parked in the sink sees
    -- whether anything had been opened before it.
  }

newStallProbe ∷ IO StallProbe
newStallProbe =
  StallProbe <$> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar <*> newTVarIO Nothing <*> newTVarIO [] <*> newTVarIO False

-- | Everything the scope that owns the runner opens before it kills it: the registered owners are released, and the sink's hold is let
-- go. Idempotent and non-blocking.
openStallSink ∷ StallProbe → IO ()
openStallSink probe = atomically (writeTVar (probeOpened probe) True) >> rescueNow >> void (tryPutMVar (probeNever probe) ())

-- | The fixture. With @scenario@ absent it is the example: the runner enters the sink, the example cancels it there and judges the
-- deferral. With @scenario@ present the example's body is ended by it, while the runner is inside its first retirement opportunity and
-- the stall has not been counted: the opportunity is withdrawn when the cleanup kill interrupts it, the drain declares the stall it
-- never counted, enters the sink with that cancellation already spent, and the supplier waits for a stall that was never counted.
-- @rescued@ false leaves the scope's opening empty, which is the unrescued fixture the control runs.
stallSink ∷ Scope → Scope → Bool → StallProbe → Maybe (IO ()) → Expectation
stallSink supplierScope runnerScope rescued probe scenario = do
  let journal = probeJournal probe
  seam ← journallingSeam journal
  hostHeld ← newTVarIO Nothing
  trace ← newSinkTrace
  let owned = probeOwned probe
      logger =
        failingSink defaultLogFilter "glfw.retirement" (\_ → void (tryPutMVar (probeReached probe) ()) >> takeMVar (probeNever probe)) trace
      plan = maybe [Stall] (\_ → [Parked (probeEntered probe) (probeProceed probe)]) scenario
  outcome ← try @SomeException . armed . supplierScope (pure ()) (supplyEvidence journal hostHeld owned afterStall allRetirementFacts) $ \_ _ →
    withMainThreadKeepingContextVia runnerScope seam (when rescued (openStallSink probe))
      ( protectedRunHere seam logger (settings [windowNamed "alpha"])
          ( \host → do
              window ← onlyWindow host
              owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = plan}
              atomically (writeTVar owned (Just owner))
              atomically (writeTVar hostHeld (Just host))
          )
          (\host _ → pure host)
          (\_ _ → pure ())
      )
      $ \runner finished → case scenario of
        Just endEarly → takeMVar (probeEntered probe) >> endEarly
        Nothing → do
          -- The drain has declared the stall and is inside the diagnostic's sink.
          takeMVar (probeReached probe)
          killThread runner
          (failure, context) ←
            takeMVar finished >>= either raisedWith (\_ → unexpected "the cancelled run returned")
          failure `shouldBe` ThreadKilled
          diagnosticMarks context `shouldBe` []
          null (Logging.failedReportsInContext context) `shouldBe` True
          -- The attempt was spent and never retried, and nothing was flushed.
          traced trace `shouldReturn` ["glfw.retirement"]
          flushed trace `shouldReturn` 0
          -- The cancellation was re-raised only after retirement was safe.
          readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])
  case scenario of
    Nothing → either (\failure → throwIO failure) pure outcome
    Just _ → do
      -- Ended by the scenario: the supplier and the runner are gone and the session was torn down, whatever the ending was.
      flags ← readTVarIO journal
      flags `shouldSatisfy` elem (WindowGone 1)
      flags `shouldSatisfy` elem SessionEnded
      either (\failure → throwIO failure) (\() → unexpected "the ended example returned") outcome

-- | The example ended, the way the ending says, while the runner waits in its first retirement opportunity (#612).
stallSinkEndedEarly ∷ Scope → Scope → IO () → IO ()
stallSinkEndedEarly supplierScope runnerScope atParked = do
  probe ← newStallProbe
  stallSink supplierScope runnerScope True probe (Just atParked)

-- | The control: the fixture of 'stallSinkEndedEarly' with nothing opened before the kill. It is run on a thread of its own because it
-- does not finish: the drain is parked in the sink with the cancellation spent, and the supplier waits for a stall that was never
-- counted. That is recorded first. Then the rescue, which depends on neither of them, is made from here, and the run is joined.
stallSinkStrands ∷ Ending → Expectation
stallSinkStrands ending = do
  probe ← newStallProbe
  done ← newEmptyMVar @(Either SomeException ())
  let rescue = openStallSink probe >> void (tryPutMVar (probeProceed probe) ())
      scenario = runEnding ending (\atParked → stallSink withOwnedThreadOpening withOwnedBoundThreadOpening False probe (Just atParked))
  withOwnedThreadOpening rescue (try scenario >>= putMVar done) $ \_ _ →
    ( do
        -- The sink has been entered: the drain declared a stall it never counted.
        readMVar (probeReached probe)
        stranded ← isNothing <$> tryReadMVar done
        counted ← readTVarIO (probeOwned probe) >>= maybe (pure 0) (readTVarIO . ownerStalls)
        opened ← readTVarIO (probeOpened probe)
        opened `shouldBe` False
        stranded `shouldBe` True
        counted `shouldBe` 0
      )
      `finally` (rescue >> void (readMVar done))

-- ---------------------------------------------------------------------------
-- Support

settings ∷ [WindowConfig] → HostConfig
settings windows =
  (defaultHostConfig windows)
    { hostCommandCapacity = 8
    , hostCommandBudget = 3
    , hostEventBudget = 2
    , hostIdleWait = 0.25
    }

windowNamed ∷ Text → WindowConfig
windowNamed name = hiddenTestWindowConfig name 64 48

onlyWindow ∷ WindowHost → IO WindowId
onlyWindow host =
  atomically (hostWindowIdentities host) >>= \case
    [identity] → pure identity
    windows → unexpected ("expected one window, found " <> show (length windows))

twoWindows ∷ WindowHost → IO (WindowId, WindowId)
twoWindows host =
  atomically (hostWindowIdentities host) >>= \case
    [alpha, beta] → pure (alpha, beta)
    windows → unexpected ("expected two windows, found " <> show (length windows))

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))

recordingLogger ∷ TVar [LogEntry] → Logger
recordingLogger entries =
  mkLoggerWith defaultLogFilter systemMetadata (callbackSink (atomically . modifyTVar' entries . flip (<>) . pure))

-- | A logger whose sink fails for one component's entries alone.
failingLogger ∷ Text → Logger
failingLogger component =
  mkLoggerWith defaultLogFilter systemMetadata . callbackSink $ \entry →
    when (componentText (entryComponent entry) == component) (throwIO (Scripted "sink"))

stallReports ∷ TVar [LogEntry] → IO Int
stallReports = fmap (length . stalls) . readTVarIO

stalls ∷ [LogEntry] → [LogEntry]
stalls = filter ((== "glfw.retirement") . componentText . entryComponent)

-- | The stall diagnostic has been written.
afterStallReported ∷ TVar [LogEntry] → STM ()
afterStallReported entries = readTVar entries >>= check . not . null . stalls

-- | Wait until a thread is parked for this reason, so an example can act at a
-- point the boundary has actually reached rather than one it hopes for.
awaitBlockedOn ∷ BlockReason → ThreadId → IO ()
awaitBlockedOn reason target =
  threadStatus target >>= \case
    ThreadBlocked blocked | blocked == reason → pure ()
    ThreadFinished → unexpected "the thread finished instead of parking"
    ThreadDied → unexpected "the thread died instead of parking"
    _ → yield >> awaitBlockedOn reason target

workerPolicy ∷ WorkerPolicy
workerPolicy = WorkerPolicy Job Supervision.Required testComponent (\_ → pure Unrecognized)

testComponent ∷ Component
testComponent = unsafeComponent "test.protected"

started ∷ SupervisedStart r → IO (SupervisedWorker r)
started = \case
  WorkerStarted worker → pure worker
  WorkerStartUnavailable _ _ → unexpected "the worker was unavailable"
  WorkerStartRejected → unexpected "the worker's start was rejected"

breaking ∷ WorkerDefinition ()
breaking = workerDefinition "breaker" (\_ → pure ()) (\_ () → throwIO (Scripted "worker"))
