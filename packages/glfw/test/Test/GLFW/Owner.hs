-- | Examples for the supervised graphics owner: its cross-thread handoffs, its
-- own scheduling, its cancellation and retirement, and the D-33 exit order it
-- composes with the protected host.
--
-- Every backend operation here is a /fake/, injected through
-- 'GraphicsOperations' exactly as VK-7's Vulkan operations will be. The fakes
-- hold no GLFW capability at all, which is the first half of the evidence that
-- the owner makes no GLFW call; the second half is
-- @testOwnerMakesNoGlfwCall@, which reads the seam's own record of every
-- native call and the thread that made each one.
--
-- Nothing here initializes GLFW, opens a window, needs a display, or sleeps
-- for a concurrency outcome: every example asserts an order of recorded facts
-- or an observed state, and coordinates threads with STM and 'MVar's.
module Test.GLFW.Owner (spec) where

import Control.Concurrent (ThreadId, forkIO, myThreadId, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.DeepSeq (NFData (rnf))
import Control.Concurrent.STM
  ( STM
  , TVar
  , stateTVar
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
  , MaskingState (MaskedInterruptible)
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , SomeAsyncException
  , SomeException
  , fromException
  , throwIO
  , getMaskingState
  , throwTo
  , try
  )
import Control.Exception (finally)
import Control.Monad (forM, forM_, unless, void, when)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailures)
import Hetoimasia.Foundation.Messaging.Snapshot (Publication (..))
import Hetoimasia.Foundation.Time
  ( Duration
  , MonotonicSource
  , scriptedSource
  )
import qualified Hetoimasia.Foundation.Worker as Worker
import Hetoimasia.Foundation.Worker (requestCancel)
import Hetoimasia.GLFW.Command
  ( CommandResult (ObservationPublished)
  , Disposition (Performed)
  , SubmitResult (SubmitAccepted)
  , observeWindowCommand
  , pollCompletion
  , submitWindowCommand
  )
import Hetoimasia.GLFW.Internal.Seam
  ( NativeCall (..)
  , Seam
  , SeamScript (..)
  , asProcessMainThread
  , defaultScript
  , newSeam
  , seamCalls
  , seamSession
  )
import Hetoimasia.GLFW.Internal.Attachment (AttachmentPhase (..), viewPhase)
import Hetoimasia.GLFW.Session (defaultSessionConfig)
import Hetoimasia.GLFW.Window
  ( Extent (..)
  , WindowId
  , WindowObservation
  , WindowResult (..)
  )
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import qualified Hetoimasia.Runtime.GLFW.Internal.Owner as Private
import qualified Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff as Private
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( RuntimeControl
  , SupervisedStart (..)
  , cancelSupervised
  , checkRuntime
  , supervisedWorker
  )
import Numeric.Natural (Natural)
import Hetoimasia.Foundation.Log (Logger)
import Test.GLFW.Support
  ( SinkTrace
  , at
  , boundedExample
  , caughtAs
  , current
  , millis
  , newSinkTrace
  , quietLogger
  , sinkFailingOn
  , traced
  , unexpected
  , windowNamed
  )
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "GLFW graphics owner" $ do
  describe "handing a target over" $ do
    it "registers the attachment, tells the owner, and only then constructs the backend's target"
      (boundedExample testHandoffOrder)
    it "refuses an observation whose revision does not advance, and one for an incarnation the slot moved past"
      (boundedExample testRevisionMonotonicity)
    it "retains a partially constructed target and retires it, publishing nothing usable"
      (boundedExample testPartialConstruction)
    it "keeps a construction that was interrupted as unverified, and retires that too"
      (boundedExample testCancelledConstruction)
    it "certifies a verified rollback's facts without a retirement of its own"
      (boundedExample testVerifiedRollback)
    it "leaks no port reservation when a handover is refused, and tells the owner about an attachment whose answer was lost"
      (boundedExample testHandoverRecovery)
    it "leaves no attachment the owner never hears of, however a handover is cancelled"
      (boundedExample testCancelledHandover)
    it "refuses a delayed announcement of an incarnation the slot has moved past"
      (boundedExample testStaleAnnouncementRefused)
    it "keeps its retained per-target cells bounded across repeated detach-and-reattach cycles"
      (boundedExample testReattachmentBounded)

  describe "independent progress" $ do
    it "keeps taking rounds while the main thread is blocked"
      (boundedExample testBlockedMainThread)
    it "serves the main thread's window commands while the owner is blocked inside a step"
      (boundedExample testBlockedOwner)
    it "progresses with the main loop's wake withheld entirely"
      (boundedExample testWakeWithheld)
    it "meets a deadline of its own from its own timer, with nothing else waking it"
      (boundedExample testOwnDeadline)
    it "wakes an idle owner for newly published demand and a newer scene"
      (boundedExample testPublicationWakesIdleOwner)

  describe "the bounded lifetime port" $ do
    it "reports a full port as backpressure, having reserved and attached nothing"
      (boundedExample testPortFullReported)
    it "prevents neither the stop, nor terminal evidence, nor owner progress when it is full"
      (boundedExample testFullPortDoesNotBlockExit)

  describe "cancellation" $
    it "honours it at each wait in dependency order, and repeated cancellation releases nothing early"
      (boundedExample testRepeatedCancellation)

  describe "the D-33 exit" $ do
    it "retires each target, then the owner, then destroys it, then joins, and only then releases the windows"
      (boundedExample testExitOrder)
    it "acknowledges one released target while the owner and a second target stay live"
      (boundedExample testIndividualRelease)
    it "retires the target of a window closed through its own port, with no detach at all"
      (boundedExample testWindowCloseRetiresTarget)
    it "strands nothing when the host's admission closes during a handover"
      (boundedExample testSupersededHandover)
    it "services the main thread's bounded housekeeping while it awaits the owner"
      (boundedExample testHousekeepingDuringDrain)
    it "keeps the backend's own startup evidence readable through retirement"
      (boundedExample testStartupEvidenceRetained)
    it "closes every publication for an ordinary stop, and drains an announcement admitted before it"
      (boundedExample testNormalStopClosesPublications)
    it "settles a direct attachment whose announcement was refused, rather than reporting a release"
      (boundedExample testUnannouncedDirectAttachSettles)
    it "settles one whose window is then closed, with no release of its own"
      (boundedExample testUnannouncedClosedSettles)
    it "settles a published attachment whose answer was lost while the owner was closing"
      (boundedExample testLostAnswerWithClosedOwner)
    it "attaches nothing at all once the owner's admission has ended"
      (boundedExample testHandoverAfterStopAttachesNothing)
    it "retires and destroys the whole owner with no target ever attached"
      (boundedExample testWholeOwnerWithoutTargets)
    it "retires and destroys it after the last target has already detached"
      (boundedExample testWholeOwnerAfterLastTarget)
    it "reads a destruction and completion that both land inside its wait as verified, declaring nothing"
      (boundedExample testCoherentDestructionSnapshot)

  describe "failure" $ do
    it "drains a failed startup through the same retirement, and says startup never returned"
      (boundedExample testFailedStartup)
    it "preserves a failure raised before application supervision exists, and delivers it at the first checkpoint"
      (boundedExample testFailureBeforeSupervision)
    it "publishes a fatal failure to application checkpoints while retirement is still pending"
      (boundedExample testEarlyFatalWhileRetiring)
    it "retains an unexpected completion without retirement evidence, and disposes nothing on it"
      (boundedExample testCompletionWithoutEvidence)
    it "retains terminal facts the completion publisher refused, and transports them at the next opportunity"
      (boundedExample testRefusedNoticeRetained)
    it "closes the owner's admission and begins its retirement as soon as a required failure is latched"
      (boundedExample testRequiredFailureClosesAdmission)
    it "retains the windows, the session and every parent when whole-owner destruction fails, with no target at all"
      (boundedExample testUnverifiedDestructionRetains)
    it "refuses every publication into the handoff once the owner has quiesced"
      (boundedExample testPublicationsClosedAtExit)
    it "refuses every one of them as soon as the owner's own run has failed"
      (boundedExample testPublicationsClosedOnFailure)
    it "reports a whole-owner retirement that failed even though the destruction after it did not"
      (boundedExample testDrainFailureSurfaces)
    it "retains every failed operation, and offers a failed target retirement exactly once"
      (boundedExample testRetirementFailsOnce)
    it "keeps every one of them when more targets fail than an arbitrary cap would hold"
      (boundedExample testEveryRetirementFailureRetained)
    it "honours a cancellation inside construction, target retirement and destruction alike"
      (boundedExample testCancellationAtEachBackendCall)
    it "settles a construction the cancellation escaped as unverified, and retires it in order"
      (boundedExample testEscapedConstructionCancellation)
    it "manufactures no evidence for a target retirement the cancellation escaped, and offers it once"
      (boundedExample testEscapedRetirementCancellation)
    it "retains everything until independent evidence when the cancellation escaped the destruction"
      (boundedExample testEscapedDestructionCancellation)
    it "reports a failure it retained while it ran exactly once, not once again as cleanup"
      (boundedExample testRetainedFailureReportedOnce)
    it "reports one that escaped its run exactly once as well"
      (boundedExample testEscapingRunFailureReportedOnce)
    it "reports a supervised owner failure once, though the sentinel raised it at a checkpoint"
      (boundedExample testSupervisedFailureReportedOnce)
    it "reports a supervised failure it survived once as well"
      (boundedExample testSupervisedRetainedFailureReportedOnce)
    it "suppresses nothing for a sentinel that was cancelled before it delivered"
      (boundedExample testUndeliveredSentinelSuppressesNothing)
    it "records a target retirement that returned, however it is then cancelled"
      (boundedExample testRetirementRecordSurvivesCancellation)
    it "commits every injected operation's answer with no interruption point after it"
      (boundedExample testOperationAnswersCommitUninterrupted)
    it "waits for a terminal group report however the join is interrupted"
      (boundedExample testJoinAwaitsTerminalReport)

  describe "the owner's GLFW discipline" $
    it "makes no GLFW call of its own: every native call from its thread is the authorized wake"
      (boundedExample testOwnerMakesNoGlfwCall)

  describe "the extent seam" $ do
    it "takes the backend's concrete extent when it supplies one"
      testExtentFromBackend
    it "falls back to the last coherent observation, clamped to the reported bounds"
      testExtentFromObservation
    it "checks eligibility and zero area before it clamps"
      testExtentWithheld
    it "keeps the last coherent observation when a later one reports none"
      testGeometryKeepsLastCoherent

-- ---------------------------------------------------------------------------
-- The journal

-- | The independent facts an example asserts the order of.
data Note
  = OwnerStartup
  | Constructed !Text
  | Stepped
  | TargetRetirement !Text
  | OwnerRetirement
  | OwnerDestruction
  | DestroyRaised !Text
  | WindowGone !Int
    -- ^ The seam's own destroy call, named by the window's creation order.
  | SessionEnded
  deriving (Eq, Show)

note ∷ TVar [Note] → Note → IO ()
note journal entry = atomically (modifyTVar' journal (<> [entry]))

journalled ∷ TVar [Note] → IO [Note]
journalled = readTVarIO

-- | The scene an example publishes. It is the application's own type, so the
-- owner carries it without knowing anything about it — including how to force
-- it, which is why the application prepares its own payloads.
newtype Scene = Scene Int
  deriving (Eq, Show)

instance NFData Scene where
  rnf (Scene revision) = rnf revision

newtype Scripted = Scripted Text
  deriving (Eq, Show)

instance Exception Scripted

-- ---------------------------------------------------------------------------
-- The fake backend

-- | Every injected operation, as a cell an example may replace before or
-- during a run, beside the record of what each was called with.
data Fake = Fake
  { fakeJournal ∷ !(TVar [Note])
  , fakeStart ∷ !(TVar (OwnerStart → IO OwnerReady))
  , fakeConstruct ∷ !(TVar (TargetStart → IO TargetHandoff))
  , fakeStep ∷ !(TVar (OwnerStep Scene → IO StepReport))
  , fakeDeadline ∷ !(TVar (IO NextDeadline))
  , fakeRetireTarget ∷ !(TVar (TargetRetire → IO TargetRetired))
  , fakeRetireOwner ∷ !(TVar (OwnerRetire → IO OwnerRetired))
  , fakeDestroy ∷ !(TVar (OwnerDestroy → IO OwnerDestroyed))
  , fakeSteps ∷ !(TVar [[TargetStepView]])
    -- ^ Every step's target views, oldest first.
  , fakeScenes ∷ !(TVar [Scene])
  , fakeRetirements ∷ !(TVar [TargetRetire])
  , fakeOwnerRetirements ∷ !(TVar [OwnerRetire])
  , fakeThreads ∷ !(TVar [ThreadId])
    -- ^ The threads the operations ran on, which is how an example knows which
    -- thread is the owner's without the owner telling it.
  }

newFake ∷ TVar [Note] → IO Fake
newFake journal =
  Fake journal
    <$> newTVarIO (\_ → pure (ownerReady "started"))
    <*> newTVarIO (\start → pure (TargetConstructed (targetEvidence (describeTarget start))))
    <*> newTVarIO (\_ → pure noStepWork)
    <*> newTVarIO (pure NoOwnerDemand)
    <*> newTVarIO (\retire → pure (targetRetired (Text.pack (show (retiringWindow retire)))))
    <*> newTVarIO (\_ → pure (ownerRetired "retired"))
    <*> newTVarIO (\_ → pure (ownerDestroyed "destroyed"))
    <*> newTVarIO []
    <*> newTVarIO []
    <*> newTVarIO []
    <*> newTVarIO []
    <*> newTVarIO []

describeTarget ∷ TargetStart → Text
describeTarget start = Text.pack (show (startingWindow start))

-- | The operation record the owner is given. It has no GLFW capability of any
-- kind: no session, no window handle, no event pump, no command port.
fakeOperations ∷ Fake → GraphicsOperations Scene
fakeOperations fake =
  GraphicsOperations
    { graphicsStartOwner = \start → do
        mark
        note (fakeJournal fake) OwnerStartup
        readTVarIO (fakeStart fake) >>= ($ start)
    , graphicsConstructTarget = \start → do
        mark
        note (fakeJournal fake) (Constructed (describeTarget start))
        readTVarIO (fakeConstruct fake) >>= ($ start)
    , graphicsStep = \step → do
        mark
        atomically $ do
          modifyTVar' (fakeSteps fake) (<> [stepTargets step])
          modifyTVar' (fakeScenes fake) (<> [stepScene step])
        note (fakeJournal fake) Stepped
        readTVarIO (fakeStep fake) >>= ($ step)
    , graphicsNextDeadline = mark >> readTVarIO (fakeDeadline fake) >>= id
    , graphicsRetireTarget = \retire → do
        mark
        atomically (modifyTVar' (fakeRetirements fake) (<> [retire]))
        note (fakeJournal fake) (TargetRetirement (Text.pack (show (retiringWindow retire))))
        readTVarIO (fakeRetireTarget fake) >>= ($ retire)
    , graphicsRetireOwner = \retire → do
        mark
        atomically (modifyTVar' (fakeOwnerRetirements fake) (<> [retire]))
        note (fakeJournal fake) OwnerRetirement
        readTVarIO (fakeRetireOwner fake) >>= ($ retire)
    , graphicsDestroyOwner = \destroy → do
        mark
        note (fakeJournal fake) OwnerDestruction
        outcome ← try (readTVarIO (fakeDestroy fake) >>= ($ destroy))
        case outcome ∷ Either SomeException OwnerDestroyed of
          Right evidence → pure evidence
          Left caught → do
            note (fakeJournal fake) (DestroyRaised (Text.pack (show caught)))
            throwIO caught
    }
  where
    mark = do
      caller ← myThreadId
      atomically $ modifyTVar' (fakeThreads fake) $ \seen →
        if caller `elem` seen then seen else seen <> [caller]

-- | Replace one operation for the rest of the run.
script ∷ TVar a → a → IO ()
script cell = atomically . writeTVar cell

-- ---------------------------------------------------------------------------
-- The timer

-- | A timer nothing but the example fires. Arming it records the duration
-- asked for; firing it releases every wait armed so far.
data ScriptedTimer = ScriptedTimer
  { timerArmings ∷ !(TVar [Duration])
  , timerFired ∷ !(TVar Bool)
  }

newScriptedTimer ∷ IO (ScriptedTimer, OwnerTimer)
newScriptedTimer = do
  armings ← newTVarIO []
  fired ← newTVarIO False
  let timer = ScriptedTimer armings fired
  pure
    ( timer
    , ownerTimer $ \duration → do
        atomically (modifyTVar' armings (<> [duration]))
        pure (readTVar fired)
    )

fireTimer ∷ ScriptedTimer → IO ()
fireTimer timer = atomically (writeTVar (timerFired timer) True)

-- ---------------------------------------------------------------------------
-- The seam, the clock, and the runner

-- | A clock that advances one millisecond per reading and never runs out, so
-- an example that cannot predict how often the owner and the main thread each
-- read it still gets a monotonic, deterministic answer.
countingClock ∷ IO MonotonicSource
countingClock = do
  ticks ← newIORef (0 ∷ Integer)
  pure (scriptedSource (at . millis <$> atomicModifyIORef' ticks (\n → (n + 1, n))))

-- | A seam that journals its own destroy and terminate calls, records the
-- thread each native call was made from, and whose finite wait returns at once
-- so the main thread's housekeeping keeps turning.
ownerSeam ∷ TVar [Note] → IO (Seam, TVar [(ThreadId, NativeCall)])
ownerSeam journal = do
  threaded ← newTVarIO []
  posts ← newTVarIO (0 ∷ Int)
  held ← newIORef Nothing
  let recordFrom call = do
        caller ← myThreadId
        atomically (modifyTVar' threaded (<> [(caller, call)]))
  seam ←
    newSeam
      defaultScript
        { scriptDestroyWindow = \_ → do
            destroyed ← readIORef held >>= maybe (pure 0) (fmap latestDestroyed . seamCalls)
            note journal (WindowGone destroyed)
            recordFrom (DestroyWindow destroyed)
        , scriptTerminate = \_ → note journal SessionEnded >> recordFrom Terminate
        , scriptPollEvents = \_ → recordFrom PollEvents
        , -- The finite wait really waits, as a native one does, and the
          -- session's own internal wake is what ends it. That is what makes
          -- "the owner's publication woke the main thread" an observation
          -- rather than an assumption.
          scriptWaitEvents = \bound _ → do
            recordFrom (WaitEvents bound)
            atomically $
              readTVar posts >>= \pending →
                if pending <= 0 then retry else writeTVar posts (pending - 1)
        , scriptPostEmptyEvent = \_ → do
            recordFrom PostEmptyEvent
            atomically (modifyTVar' posts (+ 1))
        , scriptCreateWindow = \_ → True <$ recordFrom (CreateWindow 0 0 (Text.pack "window"))
        }
  atomicModifyIORef' held (\_ → (Just seam, ()))
  pure (seam, threaded)

latestDestroyed ∷ [NativeCall] → Int
latestDestroyed calls = last (0 : [key | DestroyWindow key ← calls])

-- | A host configuration for these examples: one window, small budgets, and
-- the counting clock.
ownerSettings ∷ MonotonicSource → HostConfig
ownerSettings clock =
  (defaultHostConfig [windowNamed (Text.pack "owned")])
    { hostCommandCapacity = 8
    , hostCommandBudget = 3
    , hostEventBudget = 2
    , hostIdleWait = 0.01
    , hostClock = clock
    }

-- | Run a graphics-owner host under the full application runner, in the
-- seam's session, on a bound thread designated as the process main thread.
--
-- Every example uses it, because everything a main thread owes an attachment
-- happens on owner turns and nowhere else: this is the composition an
-- application really has.
ownedHost
  ∷ Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHost = ownedHostWith quietLogger

-- | 'ownedHost' over a logger the example supplies, for the one example that
-- must observe the diagnostic an unverified destruction writes.
ownedHostWith
  ∷ Logger
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHostWith = ownedHostHooked Private.noHostHooks

-- | 'ownedHost' over the package's private host hooks.
--
-- `beforePublication` runs inside 'handOverGraphicsTarget''s own attachment,
-- after the construction has settled and before the service is published,
-- which is the one handoff an example cannot otherwise reach: the whole
-- sequence is masked, and the attachment itself runs on the main thread, so
-- there is no instant a helper could aim at from outside.
ownedHostHooked
  ∷ Private.HostHooks
  → Logger
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHostHooked hooks logger seam config ownerConfig action =
  asProcessMainThread seam (ownedHostRun hooks logger seam config ownerConfig action)

-- | 'ownedHost', catching inside the seam's own bound thread.
--
-- Cleanup evidence lives in a failure's own context, and an exception that
-- crosses out of 'asProcessMainThread' arrives with none of it, so an example
-- that inspects what the exit retained beside its primary has to catch on
-- this side of that boundary.
ownedHostCaught
  ∷ Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO (Either SomeException a)
ownedHostCaught seam config ownerConfig action =
  asProcessMainThread seam (try (ownedHostRun Private.noHostHooks quietLogger seam config ownerConfig action))

-- | The composition itself, already on the designated main thread.
ownedHostRun
  ∷ Private.HostHooks
  → Logger
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHostRun hooks logger seam config ownerConfig action =
    runGraphicsOwnerApplication
      (withLoggingLifetime logger)
      (Text.pack "owner-example")
      ( \_ use →
          Private.withGraphicsOwnerHostWith
            hooks
            logger
            (seamSession seam defaultSessionConfig)
            config
            ownerConfig
            (\host owner → use (host, owner))
      )
      fst
      (\dependencies _ → pure dependencies)
      (\(host, owner) control → action host owner control)

-- | Everything an example needs to drive one owner.
data Rig = Rig
  { rigSeam ∷ !Seam
  , rigNative ∷ !(TVar [(ThreadId, NativeCall)])
  , rigJournal ∷ !(TVar [Note])
  , rigFake ∷ !Fake
  , rigTimer ∷ !ScriptedTimer
  , rigHostConfig ∷ !HostConfig
  , rigOwnerConfig ∷ !(GraphicsOwnerConfig Scene)
  }

newRig ∷ IO Rig
newRig = newRigWith id

newRigWith ∷ (GraphicsOwnerConfig Scene → GraphicsOwnerConfig Scene) → IO Rig
newRigWith adjust = do
  journal ← newTVarIO []
  (seam, threaded) ← ownerSeam journal
  fake ← newFake journal
  (timer, injected) ← newScriptedTimer
  clock ← countingClock
  scene ← prepare (Scene 0)
  let ownerConfig =
        adjust
          (graphicsOwnerConfig (fakeOperations fake) scene)
            {ownerClockTimer = injected}
  pure (Rig seam threaded journal fake timer (ownerSettings clock) ownerConfig)

-- | Run owner turns on the main thread until the condition holds.
--
-- An attachment retires on an owner turn, because that is when the main thread
-- folds the notices the owner published and offers each registration its
-- bounded opportunity. An example that waits for a retirement without turning
-- would be waiting for something nothing does.
pumpUntil ∷ WindowHost → RuntimeControl → String → IO Bool → IO ()
pumpUntil host control what ready =
  runOwnerLoop
    host
    control
    LoopHooks
      { loopLogger = quietLogger
      , loopEvent = noApplicationEvents
      , loopUpdate = \turn → do
          done ← ready
          if done
            then pure (Finish ())
            else
              if turnNumber turn > 2000
                then unexpected ("the loop never reached " <> what)
                else pure Continue
      }

-- | Turn until the host holds no pending attachment at all.
pumpUntilRetired ∷ WindowHost → RuntimeControl → IO ()
pumpUntilRetired host control =
  pumpUntil host control "an empty attachment set" (null <$> atomically (hostPendingAttachments host))

-- | The window the host configured, which every example attaches to.
theWindow ∷ WindowHost → IO WindowId
theWindow host =
  atomically (hostWindowIdentities host) >>= \case
    identity : _ → pure identity
    [] → unexpected "the host created no window"

-- | Hand the host's one window over, failing the example if it was not taken.
handedOver ∷ WindowHost → GraphicsOwner Scene → WindowId → IO GraphicsService
handedOver host owner window =
  handOverGraphicsTarget host owner window >>= \case
    TargetHandedOver service → pure service
    other → unexpected ("the target was not handed over: " <> show other)

-- | Every fact one terminal record established, published or still owed.
--
-- A record is written before its facts are offered to the transport, so which
-- side of the split a fact is on at the instant an example reads it is a
-- race. That they are all on one side or the other is not: it is exactly what
-- the record retaining them means.
accountedFor ∷ TerminalRecord → [RetirementFact]
accountedFor record = terminalPublished record <> terminalOwed record

-- | Wait until the owner has recorded a terminal record for this target.
awaitTerminal ∷ GraphicsOwner Scene → GraphicsService → IO TerminalRecord
awaitTerminal owner service = atomically $ do
  records ← readTargetTerminalsNow owner
  maybe retry pure (Map.lookup (graphicsAttachment service) records)

-- | Wait until the owner's own construction of this target has settled, and
-- answer what it settled as.
awaitStanding ∷ GraphicsOwner Scene → GraphicsService → IO TargetStanding
awaitStanding owner service = atomically $ do
  standing ← readTargetStanding owner (graphicsAttachment service)
  case standing of
    Just TargetConstructing → retry
    Just settled → pure settled
    Nothing → retry

-- | Wait until the owner's own construction of this target has settled, which
-- an example sees as the backend having been called for it.
awaitConstructed ∷ Rig → Text → IO ()
awaitConstructed rig name = atomically $ do
  notes ← readTVar (rigJournal rig)
  check (Constructed name `elem` notes)

-- | Wait until the owner has taken a round beyond the one given.
awaitRound ∷ GraphicsOwner Scene → Natural → IO OwnerStatus
awaitRound owner seen = atomically (awaitOwnerRound owner seen)

-- | Publish one observation for a target, at the revision given.
observed ∷ GraphicsOwner Scene → GraphicsService → Natural → WindowObservation → IO ObservationPublication
observed owner service revision observation =
  publishGraphicsObservation owner service revision observation RenderEligible Nothing

-- ---------------------------------------------------------------------------
-- Handing a target over

-- | The order is the contract: the attachment is registered on the main
-- thread, the owner is told through the bounded port, and only then does the
-- backend construct anything. Nothing the backend builds can precede the
-- window's exclusive slot being reserved.
testHandoffOrder ∷ IO ()
testHandoffOrder = do
  rig ← newRig
  gate ← newTVarIO False
  entered ← newEmptyMVar
  -- The owner is held inside its startup, so it can have drained no lifetime
  -- event and constructed nothing while the main thread reserves the slot.
  script (fakeStart (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure (ownerReady (Text.pack "started"))
  (pendingBeforeConstruction, notesBefore, views) ←
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      takeMVar entered
      window ← theWindow host
      service ← handedOver host owner window
      pending ← atomically (hostPendingAttachments host)
      before ← journalled (rigJournal rig)
      atomically (writeTVar gate True)
      awaitConstructed rig (Text.pack (show window))
      seen ← sampledObservation host window
      _ ← observed owner service 1 seen
      _ ← awaitRound owner 0
      steps ← readTVarIO (fakeSteps (rigFake rig))
      pure (pending, before, steps)
  -- Registered before the backend was asked for anything at all.
  length pendingBeforeConstruction `shouldBe` 1
  filter isConstruction notesBefore `shouldBe` []
  notes ← journalled (rigJournal rig)
  ordered notes [OwnerStartup, Constructed (Text.pack "WindowId 1")]
  -- What the backend is then stepped with is the target it accepted.
  concat views `shouldSatisfy` all viewConstructed
  where
    isConstruction = \case
      Constructed _ → True
      _ → False

-- | A target's observations carry their own monotonic revision, and the slot
-- is keyed by the exact attachment.
testRevisionMonotonicity ∷ IO ()
testRevisionMonotonicity = do
  rig ← newRig
  answers ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    service ← handedOver host owner window
    seen ← sampledObservation host window
    first ← observed owner service 1 seen
    repeated ← observed owner service 1 seen
    backwards ← observed owner service 0 seen
    forwards ← observed owner service 2 seen
    -- Release this incarnation and take a fresh one: the old service names an
    -- attachment the slot has moved past, so the owner holds no slot for it.
    released ← releaseGraphicsTarget host owner service
    released `shouldSatisfy` \case
      ReleaseBegun → True
      _ → False
    _ ← awaitTerminal owner service
    pumpUntilRetired host _control
    later ← handedOver host owner window
    stale ← observed owner service 9 seen
    fresh ← observed owner later 1 seen
    pure [first, repeated, backwards, forwards, stale, fresh]
  answers
    `shouldBe` [ ObservationAccepted 1
               , ObservationStale 1
               , ObservationStale 1
               , ObservationAccepted 2
               , ObservationUnknownTarget
               , ObservationAccepted 1
               ]

sampledObservation ∷ WindowHost → WindowId → IO WindowObservation
sampledObservation host window =
  withHostWindow host window current >>= \case
    WindowAvailable seen → pure seen
    other → unexpected ("the window was not available: " <> show other)

-- | A construction that left something behind is the owner's to retire, and
-- publishes nothing usable.
testPartialConstruction ∷ IO ()
testPartialConstruction = do
  rig ← newRig
  script
    (fakeConstruct (rigFake rig))
    (\_ → pure (TargetPartial (targetEvidence (Text.pack "half"))))
  (standing, record, retirements) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    service ← handedOver host owner window
    -- Reported, not released: the owner keeps what the construction left and
    -- says the target cannot be used. The attachment is still the main
    -- thread's to retire.
    standing ← awaitStanding owner service
    held ← atomically (hostPendingAttachments host)
    length held `shouldBe` 1
    _ ← releaseGraphicsTarget host owner service
    record ← awaitTerminal owner service
    retirements ← readTVarIO (fakeRetirements (rigFake rig))
    pumpUntilRetired host _control
    pure (standing, record, retirements)
  standing `shouldBe` TargetUnusable True
  accountedFor record `shouldBe` allRetirementFacts
  map retiringConstructed retirements `shouldBe` [False]

-- | A construction whose failure the backend did not verify a rollback for
-- leaves the owner owning something, so the owner retires it.
testCancelledConstruction ∷ IO ()
testCancelledConstruction = do
  rig ← newRig
  script (fakeConstruct (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "transfer")))
  observedStanding ← newTVarIO Nothing
  observedRecord ← newTVarIO Nothing
  -- Its retirement is held until the example has read the standing, because
  -- a required failure takes the owner into its drain at once and the drain
  -- retires the target it kept.
  gate ← newTVarIO False
  script (fakeRetireTarget (rigFake rig)) $ \retire → do
    atomically (readTVar gate >>= check)
    pure (targetRetired (Text.pack (show (retiringWindow retire))))
  -- The owner's disposition is required, so the failure it kept is terminal
  -- and the whole run reports it. What the example asserts is what the owner
  -- did with the target /before/ that: it kept it, and it retired it.
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      window ← theWindow host
      service ← handedOver host owner window
      standing ← awaitStanding owner service
      atomically (writeTVar observedStanding (Just standing))
      atomically (writeTVar gate True)
      _ ← releaseGraphicsTarget host owner service
      record ← awaitTerminal owner service
      atomically (writeTVar observedRecord (Just record))
      pumpUntilRetired host _control
  raised `shouldBe` Scripted (Text.pack "transfer")
  -- Neither accepted nor verifiably rolled back, so the owner still owned
  -- whatever the interrupted construction left, and retired that.
  readTVarIO observedStanding `shouldReturn` Just (TargetUnusable True)
  record ← readTVarIO observedRecord
  fmap accountedFor record `shouldBe` Just allRetirementFacts
  retirements ← readTVarIO (fakeRetirements (rigFake rig))
  map retiringConstructed retirements `shouldBe` [False]

-- | A verified rollback is the one answer that lets the owner certify without
-- a retirement of its own.
testVerifiedRollback ∷ IO ()
testVerifiedRollback = do
  rig ← newRig
  script
    (fakeConstruct (rigFake rig))
    (\_ → pure (TargetRolledBack (rollbackEvidence (Text.pack "rolled back"))))
  (standing, record, retirements) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    service ← handedOver host owner window
    standing ← awaitStanding owner service
    _ ← releaseGraphicsTarget host owner service
    record ← awaitTerminal owner service
    pumpUntilRetired host _control
    retirements ← readTVarIO (fakeRetirements (rigFake rig))
    pure (standing, record, retirements)
  -- Nothing left for the owner to own, so nothing for it to retire.
  standing `shouldBe` TargetUnusable False
  terminalEvidence record `shouldBe` Text.pack "rolled back"
  accountedFor record `shouldBe` allRetirementFacts
  retirements `shouldBe` []

-- ---------------------------------------------------------------------------
-- Independent progress

-- | A main thread that is not turning at all does not stop the owner.
testBlockedMainThread ∷ IO ()
testBlockedMainThread = do
  rig ← newRig
  -- Work is always owed, so the owner takes rounds without waiting for any
  -- wake at all.
  script (fakeStep (rigFake rig)) (\_ → pure (StepReport True True))
  status ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    _ ← handedOver host owner window
    -- The main thread does nothing at all from here: no turn, no pump, no
    -- publication. The owner's rounds are its own.
    observed' ← awaitRound owner 5
    script (fakeStep (rigFake rig)) (\_ → pure noStepWork)
    pure observed'
  statusRounds status `shouldSatisfy` (> 5)

-- | An owner blocked inside its own step does not stop the main thread's
-- window commands.
testBlockedOwner ∷ IO ()
testBlockedOwner = do
  rig ← newRig
  gate ← newTVarIO False
  blocked ← newTVarIO False
  entered ← newEmptyMVar
  script (fakeStep (rigFake rig)) $ \_ → do
    atomically (writeTVar blocked True)
    putMVar entered ()
    atomically (readTVar gate >>= check)
    atomically (writeTVar blocked False)
    pure noStepWork
  settled ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    _ ← handedOver host owner window
    takeMVar entered
    -- The owner is inside its step and stays there. The main thread's own
    -- port still admits, its own turn still executes, and the command really
    -- completes — all before anything releases the owner.
    admitted ← submitWindowCommand (hostCommandPort host) [] (observeWindowCommand window)
    ticket ← case admitted of
      SubmitAccepted ticket → pure ticket
      other → unexpected ("the command was not admitted: " <> show other)
    pumpUntil host control "the command's completion" $
      isJust <$> atomically (pollCompletion ticket)
    settled ← atomically (pollCompletion ticket)
    -- Only now, so nothing above could have been served by an owner that had
    -- already left its step.
    stepping ← atomically (readTVar blocked)
    stepping `shouldBe` True
    atomically (writeTVar gate True)
    pure settled
  settled `shouldSatisfy` \case
    Just (Performed (ObservationPublished {})) → True
    _ → False

-- | The owner's rounds do not depend on the main loop waking it.
testWakeWithheld ∷ IO ()
testWakeWithheld = do
  rig ← newRig
  script (fakeStep (rigFake rig)) (\_ → pure (StepReport True True))
  rounds ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
    -- No target, no observation, no demand, no scene, and no pump: nothing at
    -- all crosses from the main thread, and the owner still progresses.
    status ← awaitRound owner 3
    -- Stop owing work before the exit, so what it asserts is the owner's
    -- progress rather than a hot loop racing its own retirement.
    script (fakeStep (rigFake rig)) (\_ → pure noStepWork)
    pure (statusRounds status)
  rounds `shouldSatisfy` (> 3)
  journalled (rigJournal rig) >>= \notes → filter raised notes `shouldBe` []
  where
    raised = \case
      DestroyRaised _ → True
      _ → False

-- | A deadline the backend named is met from the owner's own timer.
testOwnDeadline ∷ IO ()
testOwnDeadline = do
  rig ← newRig
  script (fakeDeadline (rigFake rig)) (pure (OwnerDeadline (at (millis 1000000))))
  (before, after, armings) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
    first ← awaitRound owner 0
    -- The owner is now waiting on a deadline far in its own future. Nothing
    -- else can wake it: no event, no observation, no stop.
    atomically (check . not . null =<< readTVar (timerArmings (rigTimer rig)))
    fireTimer (rigTimer rig)
    later ← awaitRound owner (statusRounds first)
    armings ← readTVarIO (timerArmings (rigTimer rig))
    pure (statusRounds first, statusRounds later, armings)
  before `shouldSatisfy` (>= 1)
  after `shouldSatisfy` (> before)
  armings `shouldSatisfy` (not . null)

-- ---------------------------------------------------------------------------
-- The bounded lifetime port

-- | A port with no room refuses the handover before anything is reserved.
testPortFullReported ∷ IO ()
testPortFullReported = do
  rig ← newRigWith (\config → config {ownerEventCapacity = 1})
  gate ← newTVarIO False
  entered ← newEmptyMVar
  -- The owner is held inside its first startup, so it drains no event at all
  -- and the one-slot port really is full.
  script (fakeStart (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure (ownerReady (Text.pack "late"))
  (second, pending) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    takeMVar entered
    window ← theWindow host
    _ ← handedOver host owner window
    -- The one slot is spent and undrained. A second handover cannot be told to
    -- the owner, so it reserves nothing and attaches nothing.
    refused ← handOverGraphicsTarget host owner window
    pending ← atomically (hostPendingAttachments host)
    atomically (writeTVar gate True)
    pure (refused, pending)
  second `shouldSatisfy` \case
    HandoverPortFull → True
    _ → False
  -- Exactly the one attachment the first handover made.
  length pending `shouldBe` 1

-- | A full ordinary port stops neither the stop, nor the terminal evidence,
-- nor the owner's own progress.
testFullPortDoesNotBlockExit ∷ IO ()
testFullPortDoesNotBlockExit = do
  rig ← newRigWith (\config → config {ownerEventCapacity = 1})
  gate ← newTVarIO False
  entered ← newEmptyMVar
  script (fakeStart (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure (ownerReady (Text.pack "late"))
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    takeMVar entered
    window ← theWindow host
    _ ← handedOver host owner window
    refused ← handOverGraphicsTarget host owner window
    refused `shouldSatisfy` \case
      HandoverPortFull → True
      _ → False
    atomically (writeTVar gate True)
  notes ← journalled (rigJournal rig)
  -- The exit still reached every phase, in order, with a full port behind it.
  notes `shouldContain` [OwnerRetirement, OwnerDestruction]
  ordered notes [OwnerRetirement, OwnerDestruction, SessionEnded]

-- ---------------------------------------------------------------------------
-- Cancellation

-- | Cancellation is honoured at the owner's waits and absorbed by its drain.
--
-- The backend's whole-owner retirement absorbs the cancellations delivered to
-- it and finishes, which is exactly the shape a real one has: a cancellation
-- is not permission to abandon retirement. What the example asserts is that no
-- number of them released anything before the evidence existed.
testRepeatedCancellation ∷ IO ()
testRepeatedCancellation = do
  rig ← newRig
  cancellations ← newTVarIO (0 ∷ Int)
  release ← newTVarIO False
  stepping ← newEmptyMVar
  retiring ← newEmptyMVar
  -- The owner is held inside a step, so the first cancellation is delivered at
  -- a wait rather than wherever it happens to land.
  script (fakeStep (rigFake rig)) $ \_ → do
    putMVar stepping ()
    atomically (readTVar release >>= check)
    pure noStepWork
  -- Its whole-owner retirement absorbs every cancellation delivered to it and
  -- finishes, which is the shape a real one has: a cancellation is not
  -- permission to abandon retirement.
  script (fakeRetireOwner (rigFake rig)) $ \_ → do
    putMVar retiring ()
    absorbing cancellations (atomically (readTVar release >>= check))
    pure (ownerRetired (Text.pack "retired under cancellation"))
  terminal ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    _ ← handedOver host owner window
    takeMVar stepping
    -- The first cancellation ends the run action at that wait and enters the
    -- drain, which retires the target before it retires the owner.
    requestCancel (graphicsOwnerWorker owner)
    takeMVar retiring
    -- Two more land inside the drain, where they are absorbed. They are
    -- delivered directly, because a worker's own cancellation request forks
    -- exactly one delivery however often it is made, and what this example
    -- must show is what /repeated/ delivery cannot do.
    ownerThread ← atomically (readTVar (fakeThreads (rigFake rig)) >>= \seen → case seen of
      thread : _ → pure thread
      [] → retry)
    throwTo ownerThread ThreadKilled
    atomically (readTVar cancellations >>= check . (>= 1))
    throwTo ownerThread ThreadKilled
    atomically (readTVar cancellations >>= check . (>= 2))
    atomically (writeTVar release True)
    held ← atomically $ do
      terminal ← readOwnerTerminalNow owner
      check (isJust (ownerDestroyedEvidence terminal))
      pure terminal
    -- Nothing released this target, so its attachment is still the main
    -- thread's until the exit begins its retirement. What the example asserts
    -- is the exit's own order, below.
    pure held
  ownerRetiredEvidence terminal `shouldBe` Just (Text.pack "retired under cancellation")
  ownerDestroyedEvidence terminal `shouldBe` Just (Text.pack "destroyed")
  notes ← journalled (rigJournal rig)
  -- Dependency order held through every cancellation: the target, then the
  -- owner, then its destruction, and the window and the session only after
  -- all three.
  ordered
    notes
    [TargetRetirement (Text.pack "WindowId 1"), OwnerRetirement, OwnerDestruction, WindowGone 1, SessionEnded]

-- | Absorb every asynchronous exception delivered while an action finishes.
absorbing ∷ TVar Int → IO () → IO ()
absorbing counter action = go
  where
    go =
      try action >>= \case
        Right () → pure ()
        Left caught
          | isJust (fromException caught ∷ Maybe SomeAsyncException) → do
              atomically (modifyTVar' counter (+ 1))
              go
          | otherwise → throwIO (caught ∷ SomeException)

-- ---------------------------------------------------------------------------
-- The D-33 exit

-- | The whole-session exit order.
testExitOrder ∷ IO ()
testExitOrder = do
  rig ← newRig
  workerAtExit ← newTVarIO Nothing
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    _ ← handedOver host owner window
    awaitConstructed rig (Text.pack (show window))
    atomically (writeTVar workerAtExit (Just ()))
  notes ← journalled (rigJournal rig)
  ordered
    notes
    [ OwnerStartup
    , Constructed (Text.pack "WindowId 1")
    , TargetRetirement (Text.pack "WindowId 1")
    , OwnerRetirement
    , OwnerDestruction
    , WindowGone 1
    , SessionEnded
    ]

-- | An individual release retires one target and leaves everything else live.
testIndividualRelease ∷ IO ()
testIndividualRelease = do
  rig ← newRigWith id
  clock ← countingClock
  let config =
        (ownerSettings clock)
          { hostWindowConfigs = [windowNamed (Text.pack "first"), windowNamed (Text.pack "second")]
          }
  (livingWorker, terminals, secondStillPending) ←
    ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner _control → do
      windows ← atomically (hostWindowIdentities host)
      case windows of
        [first, second] → do
          firstService ← handedOver host owner first
          _second ← handedOver host owner second
          awaitConstructed rig (Text.pack (show second))
          _ ← releaseGraphicsTarget host owner firstService
          _ ← awaitTerminal owner firstService
          -- The released target's attachment retires and its window may be
          -- released; the other one is untouched and the owner is still live.
          pumpUntil host _control "one retired attachment" $
            (== 1) . length <$> atomically (hostPendingAttachments host)
          settled ← atomically (Worker.pollCompletion (graphicsOwnerWorker owner))
          records ← atomically (readTargetTerminalsNow owner)
          pending ← atomically (windowGraphicsStatus host second)
          pure (isNothing settled, Map.keys records, pending)
        other → unexpected ("the host created " <> show (length other) <> " windows")
  livingWorker `shouldBe` True
  length terminals `shouldBe` 1
  secondStillPending `shouldSatisfy` \case
    GraphicsPresent observation → observedSlot observation == SlotAttached
    _ → False

-- | The main thread services the host's own bounded housekeeping while it
-- awaits the owner, and performs no owner work.
testHousekeepingDuringDrain ∷ IO ()
testHousekeepingDuringDrain = do
  rig ← newRig
  release ← newTVarIO False
  entered ← newEmptyMVar
  -- The owner's destruction is held open, so the main thread has to wait for
  -- it with something to do.
  script (fakeDestroy (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar release >>= check)
    pure (ownerDestroyed (Text.pack "destroyed late"))
  mainThread ← newTVarIO Nothing
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    _ ← handedOver host owner window
    awaitConstructed rig (Text.pack (show window))
    caller ← myThreadId
    atomically (writeTVar mainThread (Just caller))
    _ ← forkIO $ do
      takeMVar entered
      -- The main thread is inside the exit's own wait for the owner. It keeps
      -- pumping, and this releases the owner once it has.
      atomically . check . (> 0) . length . housekeeping =<< readTVarIO (rigNative rig)
      atomically (writeTVar release True)
    pure ()
  calls ← readTVarIO (rigNative rig)
  owner ← readTVarIO mainThread
  housekeeping calls `shouldSatisfy` (not . null)
  -- Whatever pumped, pumped on the main thread.
  maybe True (\main → all ((== main) . fst) (filter (isPump . snd) calls)) owner `shouldBe` True
  where
    housekeeping = filter (isPump . snd)

-- | Whole-owner retirement does not depend on there ever having been a target.
testWholeOwnerWithoutTargets ∷ IO ()
testWholeOwnerWithoutTargets = do
  rig ← newRig
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control →
    void (awaitRound owner 0)
  requests ← readTVarIO (fakeOwnerRetirements (rigFake rig))
  notes ← journalled (rigJournal rig)
  map retiringUnverified requests `shouldBe` [[]]
  map retiringStarted requests `shouldBe` [True]
  ordered notes [OwnerStartup, OwnerRetirement, OwnerDestruction, SessionEnded]

-- | Nor on a target still being attached when the exit begins.
testWholeOwnerAfterLastTarget ∷ IO ()
testWholeOwnerAfterLastTarget = do
  rig ← newRig
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    service ← handedOver host owner window
    _ ← releaseGraphicsTarget host owner service
    _ ← awaitTerminal owner service
    pumpUntilRetired host _control
  requests ← readTVarIO (fakeOwnerRetirements (rigFake rig))
  notes ← journalled (rigJournal rig)
  map retiringUnverified requests `shouldBe` [[]]
  ordered notes [TargetRetirement (Text.pack "WindowId 1"), OwnerRetirement, OwnerDestruction]

-- | A successful teardown whose evidence and completion are both committed
-- between the exit reading its snapshot and acting on it is still verified.
--
-- The owner's destruction waits until the exit has read its first snapshot,
-- and the exit's private hook then holds it, before it acts, until the owner
-- has published both its evidence and its run's end. An exit that decided from
-- any read after that snapshot would see the run ended and the evidence
-- missing, and would declare 'OwnerDestructionUnverified' for an owner that
-- destroyed everything: one that decides from the snapshot alone only waits,
-- and its next turn finds the evidence.
testCoherentDestructionSnapshot ∷ IO ()
testCoherentDestructionSnapshot = do
  rig ← newRig
  trace ← newSinkTrace
  let recording = sinkFailingOn (Text.pack "never") trace
  held ← newTVarIO Nothing
  snapshotRead ← newTVarIO False
  turns ← newTVarIO (0 ∷ Int)
  releasedWhileHeld ← newTVarIO Nothing
  script (fakeDestroy (rigFake rig)) $ \_ → do
    atomically (readTVar snapshotRead >>= check)
    pure (ownerDestroyed "destroyed")
  let hooks =
        Private.noHostHooks
          { Private.afterDestructionSnapshot = do
              first ← atomically (stateTVar turns (\n → (n == 0, n + 1)))
              when first $ do
                owner ← atomically (readTVar held >>= maybe retry pure)
                atomically (writeTVar snapshotRead True)
                atomically $ do
                  terminal ← readOwnerTerminalNow owner
                  check (isJust (ownerDestroyedEvidence terminal) && ownerRunEnded terminal)
                notes ← journalled (rigJournal rig)
                atomically (writeTVar releasedWhileHeld (Just (filter released notes)))
          }
  outcome ← try @SomeException $
    ownedHostHooked hooks recording (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
      atomically (writeTVar held (Just owner))
      void (awaitRound owner 0)
  case outcome of
    Right () → pure ()
    Left failure → unexpected ("the exit failed after a successful teardown: " <> show failure)
  -- The forced ordering really happened: the snapshot the hook held was read
  -- before the destruction could answer, and a later turn followed it.
  readTVarIO snapshotRead `shouldReturn` True
  readTVarIO turns >>= (`shouldSatisfy` (>= 2))
  components ← traced trace
  components `shouldSatisfy` notElem (Text.pack "glfw.graphics-owner")
  -- Nothing was released until the evidence existed, and everything was
  -- released after it.
  readTVarIO releasedWhileHeld `shouldReturn` Just []
  notes ← journalled (rigJournal rig)
  ordered notes [OwnerDestruction, SessionEnded]
  where
    released = \case
      WindowGone _ → True
      SessionEnded → True
      _ → False

-- ---------------------------------------------------------------------------
-- Failure

-- | A startup that failed enters the same drain, and the drain is told.
testFailedStartup ∷ IO ()
testFailedStartup = do
  rig ← newRig
  script (fakeStart (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "startup")))
  observedTerminal ← newTVarIO noOwnerTerminal
  -- The owner's disposition is required, so its startup failure is terminal
  -- and the run reports it. That it was /drained/ first is what this asserts.
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
      held ← atomically $ do
        terminal ← readOwnerTerminalNow owner
        check (ownerRunEnded terminal)
        pure terminal
      atomically (writeTVar observedTerminal held)
  raised `shouldBe` Scripted (Text.pack "startup")
  requests ← readTVarIO (fakeOwnerRetirements (rigFake rig))
  map retiringStarted requests `shouldBe` [False]
  terminal ← readTVarIO observedTerminal
  ownerDestroyedEvidence terminal `shouldBe` Just (Text.pack "destroyed")
  notes ← journalled (rigJournal rig)
  ordered notes [OwnerStartup, OwnerRetirement, OwnerDestruction]

-- | A failure raised before the application has any supervision is kept, and
-- the sentinel delivers it as soon as it is registered.
testFailureBeforeSupervision ∷ IO ()
testFailureBeforeSupervision = do
  rig ← newRig
  script (fakeStart (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "before supervision")))
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner control → do
      -- The owner has already failed: its startup ran inside the managed
      -- construction, before the application's own startup callback.
      atomically (readOwnerFailure owner >>= check . isJust)
      _ ← superviseGraphicsOwner control owner
      checkRuntime control
  raised `shouldBe` Scripted (Text.pack "before supervision")

-- | A fatal owner failure reaches an application checkpoint while the owner is
-- still retiring.
testEarlyFatalWhileRetiring ∷ IO ()
testEarlyFatalWhileRetiring = do
  rig ← newRig
  release ← newTVarIO False
  failing ← newTVarIO False
  retiring ← newEmptyMVar
  -- The step fails only once the example says so, so the sentinel is
  -- certainly registered before the failure it must deliver exists.
  script (fakeStep (rigFake rig)) $ \_ →
    readTVarIO failing >>= \doomed →
      if doomed then throwIO (Scripted (Text.pack "fatal step")) else pure noStepWork
  -- Its whole-owner retirement is held open across the checkpoint below.
  script (fakeRetireOwner (rigFake rig)) $ \_ → do
    putMVar retiring ()
    atomically (readTVar release >>= check)
    pure (ownerRetired (Text.pack "retired after the checkpoint"))
  observedPhase ← newTVarIO OwnerStarting
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner control →
      -- However this body leaves, the held retirement is released, so a path
      -- the example did not intend fails it rather than hanging it.
      flip finally (atomically (writeTVar release True)) $ do
        started ← superviseGraphicsOwner control owner
        case started of
          WorkerStarted _ → pure ()
          other → unexpected ("the sentinel did not start: " <> describeStart other)
        atomically (writeTVar failing True)
        -- Immediate demand wakes the idle owner into the step that fails.
        demand ← prepare (OwnerDemand True Nothing)
        _ ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
        takeMVar retiring
        status ← atomically (readOwnerStatusNow owner)
        atomically (writeTVar observedPhase (statusPhase status))
        -- Retirement is deliberately unfinished, and the checkpoint still
        -- raises.
        checkRuntime control
  raised `shouldBe` Scripted (Text.pack "fatal step")
  readTVarIO observedPhase `shouldReturn` OwnerRetiring

describeStart ∷ SupervisedStart () → String
describeStart = \case
  WorkerStarted _ → "started"
  WorkerStartUnavailable _ _ → "unavailable"
  WorkerStartRejected → "rejected"

-- | An owner that ended without retirement evidence retains its dependencies,
-- and its completion is never permission to dispose them.
testCompletionWithoutEvidence ∷ IO ()
testCompletionWithoutEvidence = do
  rig ← newRig
  trace ← newSinkTrace
  let recording = sinkFailingOn (Text.pack "never") trace
  -- Nothing the backend is asked for succeeds once it holds a target, so the
  -- owner ends with no record for it and no destruction evidence of its own.
  -- The step fails only after the target exists, so the handover below is the
  -- ordinary one rather than a race with the owner's own admission closing.
  script (fakeStep (rigFake rig)) $ \step →
    if null (stepTargets step) then pure noStepWork else throwIO (Scripted (Text.pack "step"))
  script (fakeRetireTarget (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire target")))
  script (fakeRetireOwner (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire owner")))
  script (fakeDestroy (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "destroy")))
  (unverified, _) ← caughtAs @OwnerDestructionUnverified $
    ownedHostWith recording (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      window ← theWindow host
      service ← handedOver host owner window
      -- The owner's run has ended and it established nothing.
      atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
      records ← atomically (readTargetTerminalsNow owner)
      Map.keys records `shouldBe` []
      held ← atomically (readOwnerTargets owner)
      length held `shouldBe` 1
      -- The window's slot is still occupied and every fact is still owed: the
      -- worker's completion changed none of that.
      observation ← atomically (readGraphicsService service)
      observedMissing observation `shouldBe` allRetirementFacts
      pending ← atomically (hostPendingAttachments host)
      length pending `shouldBe` 1
      -- Independent evidence, from a thread that is not the main one, is the
      -- only thing that can retire any of this — the attachment's facts, and
      -- then the owner's own destruction. Without both, the boundary retains
      -- the window, the session and every parent for good, which is the whole
      -- point; with them, this example's exit can finish.
      publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
      acknowledgement ←
        atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
          >>= maybe (unexpected "the attachment kept no acknowledgement") pure
      void . forkIO $ do
        -- The attachment is still the main thread's and is only retiring once
        -- the exit's quiescence has begun it, so the facts are published into
        -- a model that can record them rather than refuse them.
        atomically (readGraphicsService service >>= check . (== SlotRetiring) . observedSlot)
        forM_ allRetirementFacts $ \fact →
          void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
        -- Then the owner's own destruction, once the boundary is demonstrably
        -- retaining everything for the want of it: the attachment drain has
        -- finished and the exit has said, once, what it is retaining.
        atomically (check . null =<< hostPendingAttachments host)
        awaitDiagnostic trace
        publishOwnerDestruction owner (ownerDestroyed (Text.pack "destroyed independently"))
  unverifiedRetired unverified `shouldBe` False
  unverifiedTargets unverified `shouldBe` 1
  -- Said exactly once, whatever the wait then had to do.
  components ← traced trace
  length (filter (== Text.pack "glfw.graphics-owner") components) `shouldBe` 1

-- | A terminal fact the completion publisher could not carry stays owed, and
-- nothing loses it.
--
-- The host's completion inbox holds one notice per retirement fact per window
-- it may hold, so a host's own live attachments can never fill it between
-- them. What can is a notice naming an incarnation the slot has already moved
-- past: admission bounds capacity and coalescing only, and the model refuses
-- such a notice later, when the owner thread folds it. This example fills the
-- inbox exactly that way, so the owner's next publication really is refused.
testRefusedNoticeRetained ∷ IO ()
testRefusedNoticeRetained = do
  rig ← newRig
  clock ← countingClock
  -- One window, so the inbox holds exactly one notice per fact.
  let config = (ownerSettings clock) {hostWindowLimit = 1}
  (record, admissions) ← ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    first ← handedOver host owner window
    -- Captured before the retirement below, because the owner forgets an
    -- acknowledgement as soon as its attachment has validated its facts.
    stale ←
      atomically (ownerTargetAcknowledgement owner (graphicsAttachment first))
        >>= maybe (unexpected "the first incarnation kept no acknowledgement") pure
    _ ← releaseGraphicsTarget host owner first
    _ ← awaitTerminal owner first
    pumpUntilRetired host _control
    second ← handedOver host owner window
    -- Fill the inbox with the retired incarnation's notices. Each is a
    -- distinct value, so none coalesces; each will be refused by the model
    -- when the owner thread folds it, and none establishes anything.
    publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
    admissions ← mapM (offer publisher (graphicsAttachment first) stale) allRetirementFacts
    -- The inbox is now full and nothing on the main thread is folding it, so
    -- every fact the owner establishes for the live incarnation is refused.
    _ ← releaseGraphicsTarget host owner second
    record ← awaitTerminal owner second
    pure (record, admissions)
  admissions `shouldBe` replicate (length allRetirementFacts) (CompletionOffered NoticeAdmitted)
  -- Refused, therefore still owed — and nothing was lost: the record accounts
  -- for every fact its own injected retirement established.
  terminalPublished record `shouldBe` []
  terminalOwed record `shouldBe` allRetirementFacts
  where
    offer publisher target acknowledgement fact =
      publishCompletion publisher (completionNotice target acknowledgement fact)

-- ---------------------------------------------------------------------------
-- The owner's GLFW discipline

-- | Every native call made from the owner's thread is the authorized wake, and
-- nothing else.
testOwnerMakesNoGlfwCall ∷ IO ()
testOwnerMakesNoGlfwCall = do
  rig ← newRig
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    service ← handedOver host owner window
    seen ← sampledObservation host window
    _ ← observed owner service 1 seen
    -- Folded, so the owner really did consume the observation rather than
    -- merely having been handed it.
    atomically (readOwnerGeometry owner >>= check . Map.member (graphicsAttachment service))
    _ ← releaseGraphicsTarget host owner service
    _ ← awaitTerminal owner service
    pure ()
  calls ← readTVarIO (rigNative rig)
  threads ← readTVarIO (fakeThreads (rigFake rig))
  -- The operations all ran on one thread, which is the owner's.
  fromOwner ← case threads of
    [ownerThread] → pure [call | (caller, call) ← calls, caller == ownerThread]
    other → unexpected ("the fake operations ran on " <> show (length other) <> " threads")
  -- Everything that thread reached across for is the wake, which is
  -- publication and not a GLFW operation of the owner's.
  filter (/= PostEmptyEvent) fromOwner `shouldBe` []
  -- And the wake really was used, so the assertion above is not vacuous.
  fromOwner `shouldSatisfy` (not . null)

-- ---------------------------------------------------------------------------
-- Reservations, cancellation, and bounded retention

-- | A refused handover spends no reservation, and an attachment whose answer
-- was lost is still announced.
testHandoverRecovery ∷ IO ()
testHandoverRecovery = do
  -- One event of room, so a leaked reservation makes the next handover fail.
  rig ← newRigWith (\config → config {ownerEventCapacity = 1})
  clock ← countingClock
  let config =
        (ownerSettings clock)
          { hostWindowConfigs = [windowNamed (Text.pack "closing"), windowNamed (Text.pack "open")]
          }
  gate ← newTVarIO False
  entered ← newEmptyMVar
  -- The owner is held inside its startup, so it drains no event: the one slot
  -- has to be given back by each refusal for the last handover to fit at all.
  script (fakeStart (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure (ownerReady (Text.pack "late"))
  (refusals, announced, owned) ← ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner _control → do
    takeMVar entered
    windows ← atomically (hostWindowIdentities host)
    case windows of
      [closing, open] → do
        _ ← closeHostWindow host closing
        -- Refused before any effect, three times over, each of which must
        -- give its held reservation back.
        refusals ← mapM (\_ → handOverGraphicsTarget host owner closing) [1 ∷ Int .. 3]
        -- The recovery path an interrupted handover takes: attach with the
        -- owner's own protocol, then announce. It spends the one slot every
        -- refusal above returned, so a leak would refuse it.
        attached ← attachWindowGraphics host open (graphicsTargetProtocol host owner)
        announced ← case attached of
          GraphicsAttached service → announceGraphicsTarget owner service
          other → unexpected ("the direct attachment failed: " <> show other)
        atomically (writeTVar gate True)
        awaitConstructed rig (Text.pack (show open))
        owned ← atomically (readOwnerTargets owner)
        pure (refusals, announced, owned)
      other → unexpected ("the host created " <> show (length other) <> " windows")
  map describeHandover refusals `shouldBe` replicate 3 "refused"
  announced `shouldBe` EventAdmitted
  length owned `shouldBe` 1

-- | A handover cancelled at the one handoff that matters leaves no
-- attachment the owner was not told about.
--
-- The cancellation is delivered at the instant the attachment's construction
-- has settled and its service is about to be published: the attachment is
-- registered, its acknowledgement recorded, and the caller is about to lose
-- the answer. A helper delivers it to the main thread, because the attachment
-- is the main thread's and a handover on any other thread never reaches this
-- point at all.
testCancelledHandover ∷ IO ()
testCancelledHandover = do
  rig ← newRig
  arming ← newTVarIO Nothing
  let hooks =
        Private.noHostHooks
          { Private.beforePublication =
              readTVarIO arming >>= \case
                Nothing → pure ()
                Just target → throwTo target ThreadKilled
          }
  (answers, stranded, known) ←
    ownedHostHooked hooks quietLogger (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
      window ← theWindow host
      main ← myThreadId
      answers ← forM [1 ∷ Int .. 6] $ \_ → do
        atomically (writeTVar arming (Just main))
        outcome ← try (handOverGraphicsTarget host owner window)
        atomically (writeTVar arming Nothing)
        -- Whatever the attach settled as, every attachment the host still has
        -- pending is one the owner has an acknowledgement for, so its
        -- evidence has somewhere to come from.
        pending ← atomically (hostPendingAttachments host)
        acknowledgements ← atomically (readOwnerAcknowledged owner)
        let unknown = filter (`notElem` acknowledgements) pending
        -- Put the window back for the next attempt.
        case outcome ∷ Either SomeException GraphicsHandover of
          Right (TargetHandedOver service) → void (releaseGraphicsTarget host owner service)
          _ →
            atomically (windowGraphicsService host window)
              >>= mapM_ (void . releaseGraphicsTarget host owner)
        pumpUntilRetired host control
        pure (either (const "cancelled") describeHandover outcome, unknown)
      -- Nothing is attached, and the owner is holding no acknowledgement for
      -- an incarnation that no longer exists.
      pumpUntil host control "the forgotten acknowledgements" $
        null <$> atomically (readOwnerAcknowledged owner)
      known ← atomically (readOwnerAcknowledged owner)
      pure (map fst answers, concatMap snd answers, known)
  -- The gate really fired: every attempt was interrupted there.
  answers `shouldBe` replicate 6 "cancelled"
  stranded `shouldBe` []
  known `shouldBe` []

-- | Repeated detach-and-reattach leaves one window's worth of retained cells,
-- not one per incarnation.
testReattachmentBounded ∷ IO ()
testReattachmentBounded = do
  rig ← newRig
  (records, geometry, acknowledged) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    forM_ [1 ∷ Int .. 4] $ \_ → do
      service ← handedOver host owner window
      seen ← sampledObservation host window
      _ ← observed owner service 1 seen
      awaitStanding owner service `shouldReturn` TargetUsable
      _ ← releaseGraphicsTarget host owner service
      _ ← awaitTerminal owner service
      pumpUntilRetired host control
    -- The round after the last validation prunes what it established.
    pumpUntil host control "the pruned round" (Map.null <$> atomically (readTargetTerminalsNow owner))
    (,,)
      <$> atomically (readTargetTerminalsNow owner)
      <*> atomically (readOwnerGeometry owner)
      <*> atomically (readOwnerAcknowledged owner)
  Map.size records `shouldBe` 0
  Map.size geometry `shouldBe` 0
  length acknowledged `shouldBe` 0

-- | An idle owner wakes for demand and for a scene, not only for an event, an
-- observation or its own timer.
testPublicationWakesIdleOwner ∷ IO ()
testPublicationWakesIdleOwner = do
  rig ← newRig
  (afterDemand, afterScene, scenes) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
    -- The owner is idle: no target, no deadline, no event, and its step owes
    -- nothing. Only a publication can wake it.
    first ← awaitIdle owner
    demand ← prepare (OwnerDemand True Nothing)
    published ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
    published `shouldBe` Published
    afterDemand ← atomically (awaitOwnerRound owner (statusRounds first))
    second ← awaitIdle owner
    scene ← prepare (Scene 7)
    _ ← atomically (publishOwnerScene (ownerHandoff owner) scene)
    afterScene ← atomically (awaitOwnerRound owner (statusRounds second))
    scenes ← readTVarIO (fakeScenes (rigFake rig))
    pure (statusRounds afterDemand, statusRounds afterScene, scenes)
  afterDemand `shouldSatisfy` (> 0)
  afterScene `shouldSatisfy` (> afterDemand)
  -- The scene the owner stepped with is the one that was published.
  last scenes `shouldBe` Scene 7

-- | Wait until the owner has settled into a round it will not leave by itself.
--
-- It is the owner's own idleness the example needs, not a count: the round
-- number is read once the owner has stopped advancing it, so the wait the
-- example then makes can only be ended by the publication it makes.
awaitIdle ∷ GraphicsOwner Scene → IO OwnerStatus
awaitIdle owner = do
  status ← atomically (awaitOwnerRound owner 0)
  settled ← atomically (readOwnerStatusNow owner)
  if statusRounds settled == statusRounds status then pure settled else awaitIdle owner

-- | A required failure closes the owner's admission and takes it into its
-- retirement at once, rather than waiting for the exit.
testRequiredFailureClosesAdmission ∷ IO ()
testRequiredFailureClosesAdmission = do
  rig ← newRig
  release ← newTVarIO False
  retiring ← newEmptyMVar
  script (fakeStep (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "fatal step")))
  script (fakeRetireOwner (rigFake rig)) $ \_ → do
    putMVar retiring ()
    atomically (readTVar release >>= check)
    pure (ownerRetired (Text.pack "retired"))
  observedRefusal ← newTVarIO Nothing
  observedPhase ← newTVarIO OwnerStarting
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      window ← theWindow host
      takeMVar retiring
      -- The owner is already retiring and its admission is already closed, so
      -- a handover now leaves nothing attached at all.
      answer ← handOverGraphicsTarget host owner window
      pending ← atomically (hostPendingAttachments host)
      length pending `shouldBe` 0
      status ← atomically (readOwnerStatusNow owner)
      atomically $ do
        writeTVar observedRefusal (Just (describeHandover answer))
        writeTVar observedPhase (statusPhase status)
      void (forkIO (atomically (writeTVar release True)))
  raised `shouldBe` Scripted (Text.pack "fatal step")
  readTVarIO observedRefusal `shouldReturn` Just "owner closed"
  readTVarIO observedPhase `shouldReturn` OwnerRetiring

describeHandover ∷ GraphicsHandover → String
describeHandover = \case
  TargetHandedOver _ → "handed over"
  HandoverRefused _ → "refused"
  HandoverPortFull → "port full"
  HandoverOwnerClosed → "owner closed"
  HandoverSuperseded _ → "superseded"
  HandoverRolledBack _ → "rolled back"

-- | Whole-owner destruction that produced no evidence retains everything the
-- owner borrowed, with no target involved at all.
testUnverifiedDestructionRetains ∷ IO ()
testUnverifiedDestructionRetains = do
  rig ← newRig
  trace ← newSinkTrace
  let recording = sinkFailingOn (Text.pack "never") trace
  script (fakeDestroy (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "destroy")))
  releasedWhileRetained ← newTVarIO Nothing
  (unverified, _) ← caughtAs @OwnerDestructionUnverified $
    ownedHostWith recording (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
      _ ← awaitRound owner 0
      -- From another thread: wait until the exit has said, once, what it is
      -- retaining and why — which it does before it settles into the wait —
      -- then record what has been released, and only then supply the
      -- independent evidence that lets the boundary finish.
      void . forkIO $ do
        atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
        awaitDiagnostic trace
        notes ← journalled (rigJournal rig)
        atomically (writeTVar releasedWhileRetained (Just (filter released notes)))
        publishOwnerDestruction owner (ownerDestroyed (Text.pack "destroyed independently"))
  unverifiedRetired unverified `shouldBe` True
  unverifiedTargets unverified `shouldBe` 0
  -- Nothing of the host's was released while the evidence was missing.
  readTVarIO releasedWhileRetained `shouldReturn` Just []
  -- And it was released in the end, after the evidence existed.
  notes ← journalled (rigJournal rig)
  notes `shouldContain` [SessionEnded]
  where
    released = \case
      WindowGone _ → True
      SessionEnded → True
      _ → False

-- | Wait until the graphics owner's own component has written its one
-- diagnostic, which the exit writes before it settles into retaining.
-- The sink's record is an ordinary cell rather than a transaction, so this
-- polls it; 'yield' between polls is a scheduler hint, not a wait for a
-- timing outcome, and it keeps the poll from starving the thread it is
-- waiting for.
awaitDiagnostic ∷ SinkTrace → IO ()
awaitDiagnostic trace = do
  components ← traced trace
  unless (Text.pack "glfw.graphics-owner" `elem` components) (yield >> awaitDiagnostic trace)

isPump ∷ NativeCall → Bool
isPump = \case
  PollEvents → True
  WaitEvents _ → True
  _ → False

-- | Every publication into the handoff is refused once the owner has quiesced.
testPublicationsClosedAtExit ∷ IO ()
testPublicationsClosedAtExit = do
  rig ← newRig
  escaped ← newEmptyMVar
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    service ← handedOver host owner window
    _ ← releaseGraphicsTarget host owner service
    _ ← awaitTerminal owner service
    pumpUntilRetired host control
    putMVar escaped (ownerHandoff owner)
  handoff ← takeMVar escaped
  demand ← prepare (OwnerDemand True Nothing)
  scene ← prepare (Scene 1)
  atomically (publishOwnerDemand handoff demand) `shouldReturn` PublicationClosed
  atomically (publishOwnerScene handoff scene) `shouldReturn` ScenePublication PublicationClosed
  atomically (targetEventsOpen handoff) `shouldReturn` False

-- | An owner whose run has failed refuses every publication, not only the
-- lifetime port: it reads none of them again.
testPublicationsClosedOnFailure ∷ IO ()
testPublicationsClosedOnFailure = do
  rig ← newRig
  escaped ← newEmptyMVar
  script (fakeStep (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "fatal step")))
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
      atomically (readOwnerFailure owner >>= check . isJust)
      -- The owner has failed and is retiring; the host has not quiesced and
      -- the run has not ended. Every endpoint must already refuse.
      let handoff = ownerHandoff owner
      demand ← prepare (OwnerDemand True Nothing)
      scene ← prepare (Scene 2)
      atomically (publishOwnerDemand handoff demand) `shouldReturn` PublicationClosed
      atomically (publishOwnerScene handoff scene) `shouldReturn` ScenePublication PublicationClosed
      atomically (targetEventsOpen handoff) `shouldReturn` False
      putMVar escaped ()
  raised `shouldBe` Scripted (Text.pack "fatal step")
  takeMVar escaped

-- | A whole-owner retirement that failed is reported even when the
-- destruction after it succeeded.
--
-- Nothing else records it: the destruction evidence exists, so the exit's
-- wait is satisfied and writes no diagnostic, and the failure was the
-- /drain's/ rather than the run's, so no latch holds it. The joined worker's
-- own outcome is the only place it lives.
testDrainFailureSurfaces ∷ IO ()
testDrainFailureSurfaces = do
  rig ← newRig
  script (fakeRetireOwner (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire owner")))
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control →
      void (awaitRound owner 0)
  raised `shouldBe` Scripted (Text.pack "retire owner")
  terminal ← readTVarIO (rigJournal rig)
  -- The destruction after it still ran, and still established its evidence,
  -- so nothing was retained for want of it.
  terminal `shouldContain` [OwnerDestruction]

-- | Closing a window through its own port retires that window's target,
-- although nothing detached it.
--
-- The close begins the attachment's retirement in the host's model, and no
-- event passes through the owner's lifetime port at all. An owner that waited
-- to be told would leave the target unretired, its evidence unproduced, and
-- the window unable to finish closing while the owner stayed live.
testWindowCloseRetiresTarget ∷ IO ()
testWindowCloseRetiresTarget = do
  rig ← newRig
  clock ← countingClock
  let config =
        (ownerSettings clock)
          { hostWindowConfigs = [windowNamed (Text.pack "closing"), windowNamed (Text.pack "staying")]
          }
  (retirements, livingWorker, other) ← ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner control → do
    windows ← atomically (hostWindowIdentities host)
    case windows of
      [closing, staying] → do
        first ← handedOver host owner closing
        second ← handedOver host owner staying
        awaitConstructed rig (Text.pack (show staying))
        -- The close, and nothing else. No detach, no release, no event.
        _ ← closeHostWindow host closing
        _ ← awaitTerminal owner first
        pumpUntil host control "the closed window's retirement" $
          (== 1) . length <$> atomically (hostPendingAttachments host)
        -- The owner is still live and still holds the other target.
        settled ← atomically (Worker.pollCompletion (graphicsOwnerWorker owner))
        retirements ← readTVarIO (fakeRetirements (rigFake rig))
        other ← atomically (windowGraphicsStatus host (graphicsWindow second))
        pure (retirements, isNothing settled, other)
      other → unexpected ("the host created " <> show (length other) <> " windows")
  -- Exactly the closed window's target, and only it.
  map (Text.pack . show . retiringWindow) retirements `shouldBe` [Text.pack "WindowId 1"]
  livingWorker `shouldBe` True
  other `shouldSatisfy` \case
    GraphicsPresent observation → observedSlot observation == SlotAttached
    _ → False

-- | A handover the host's admission closes under strands nothing.
--
-- Quiescence is delivered at exactly the handoff between the attachment's
-- construction and its publication, which is what makes the boundary answer
-- 'GraphicsSuperseded': a registered, retiring attachment with its
-- acknowledgement recorded and nothing usable published. Nothing but the
-- handover itself could produce its evidence, so an exit that waited for it
-- would never return.
testSupersededHandover ∷ IO ()
testSupersededHandover = do
  rig ← newRig
  quiescing ← newTVarIO Nothing
  let hooks =
        Private.noHostHooks
          { Private.beforePublication =
              readTVarIO quiescing >>= mapM_ (atomically . quiesceWindowHost)
          }
  (answer, pending, acknowledgements) ←
    ownedHostHooked hooks quietLogger (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      window ← theWindow host
      atomically (writeTVar quiescing (Just host))
      answer ← handOverGraphicsTarget host owner window
      -- The attachment the supersession left behind is retired: the host
      -- holds none pending, and the ledger settled that incarnation and
      -- forgot it in the same breath, so nothing can announce it again and
      -- nothing is retained for an owner round that may never come.
      stage ← case answer of
        HandoverSuperseded target → atomically (custodyOf owner target)
        _ → pure Nothing
      (,,) (describeHandover answer)
        <$> atomically (hostPendingAttachments host)
        <*> pure stage
  answer `shouldBe` "superseded"
  pending `shouldBe` []
  acknowledgements `shouldBe` Nothing

-- ---------------------------------------------------------------------------
-- The settlement ledger, failure evidence, and the join gate

-- | A failed target retirement is retained, marked unverified, and never
-- offered again — not by a later round, and not by the drain.
testRetirementFailsOnce ∷ IO ()
testRetirementFailsOnce = do
  rig ← newRig
  attempts ← newTVarIO (0 ∷ Int)
  -- Fails the first time and would succeed on any replay, so a replay is
  -- visible as a target that retired after all.
  script (fakeRetireTarget (rigFake rig)) $ \retire → do
    seen ← atomically (stateTVar attempts (\n → (n, n + 1)))
    if seen == 0
      then throwIO (Scripted (Text.pack "retire target"))
      else pure (targetRetired (Text.pack (show (retiringWindow retire))))
  observedFailures ← newTVarIO 0
  observedTargets ← newTVarIO []
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
      window ← theWindow host
      service ← handedOver host owner window
      awaitStanding owner service `shouldReturn` TargetUsable
      _ ← releaseGraphicsTarget host owner service
      -- The failure is latched and retained; the target stays, unverified.
      atomically (readOwnerFailure owner >>= check . isJust)
      atomically $ do
        held ← readOwnerTargets owner
        check (graphicsAttachment service `elem` held)
      -- Turns and rounds go by, and nothing offers the operation again.
      _ ← awaitRound owner 2
      atomically . writeTVar observedFailures . length =<< atomically (readOwnerFailures owner)
      atomically . writeTVar observedTargets =<< atomically (readOwnerTargets owner)
      -- Independent evidence is the only thing that retires it, which is what
      -- lets this example's own exit finish.
      publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
      acknowledgement ←
        atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
          >>= maybe (unexpected "the attachment kept no acknowledgement") pure
      forM_ allRetirementFacts $ \fact →
        void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
      pumpUntilRetired host control
  raised `shouldBe` Scripted (Text.pack "retire target")
  -- Offered exactly once, over the whole run and its drain.
  readTVarIO attempts `shouldReturn` 1
  -- And the failure is evidence, not only a latch.
  readTVarIO observedFailures `shouldReturn` 1
  readTVarIO observedTargets >>= \held → length held `shouldBe` 1
  -- No terminal record was manufactured for it.
  records ← readTVarIO (rigJournal rig)
  length [() | TargetRetirement _ ← records] `shouldBe` 1

-- | The join is re-entered until it answers a terminal group report,
-- whatever is delivered to the thread waiting in it.
--
-- The exception delivered is an ordinary 'IOException', not an asynchronous
-- one: its type says nothing about how it arrived, and a join that returned
-- on it would let the protected host unwind with the owner never proved
-- terminal. The owner publishes its destruction evidence independently and
-- then stays inside its backend call, so the exit is certainly in the join
-- and not in the wait before it.
testJoinAwaitsTerminalReport ∷ IO ()
testJoinAwaitsTerminalReport = do
  rig ← newRig
  release ← newTVarIO False
  joining ← newEmptyMVar
  script (fakeDestroy (rigFake rig)) $ \_ → do
    putMVar joining ()
    atomically (readTVar release >>= check)
    pure (ownerDestroyed (Text.pack "destroyed"))
  released ← newTVarIO Nothing
  (raised, _) ← caughtAs @IOException $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
      main ← myThreadId
      void . forkIO $ do
        takeMVar joining
        -- The owner's destruction evidence exists, so the exit leaves its
        -- wait and enters the join; the owner is still inside the call.
        publishOwnerDestruction owner (ownerDestroyed (Text.pack "published early"))
        atomically (readOwnerTerminalNow owner >>= check . isJust . ownerDestroyedEvidence)
        throwTo main (userError "delivered during the join")
        -- Nothing of the host's may be released while the owner is unjoined.
        notes ← journalled (rigJournal rig)
        atomically (writeTVar released (Just (filter ended notes)))
        atomically (writeTVar release True)
      void (awaitRound owner 0)
  show raised `shouldContain` "delivered during the join"
  readTVarIO released `shouldReturn` Just []
  notes ← journalled (rigJournal rig)
  notes `shouldContain` [SessionEnded]
  where
    ended = \case
      WindowGone _ → True
      SessionEnded → True
      _ → False

-- | The backend's own startup evidence is recorded as it came back and stays
-- readable after the owner has retired and ended.
testStartupEvidenceRetained ∷ IO ()
testStartupEvidenceRetained = do
  rig ← newRig
  script (fakeStart (rigFake rig)) (\_ → pure (ownerReady (Text.pack "device 7, queue 2")))
  escaped ← newEmptyMVar
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
    _ ← awaitRound owner 0
    putMVar escaped owner
  -- Read from the owner's own record after it has retired, destroyed and
  -- ended, rather than from a copy taken while it was running: a retirement
  -- that cleared the record would pass the second and fail this.
  owner ← takeMVar escaped
  terminal ← atomically (readOwnerTerminalNow owner)
  ownerRunEnded terminal `shouldBe` True
  ownerDestroyedEvidence terminal `shouldSatisfy` isJust
  ownerStartedEvidence terminal `shouldBe` Just (Text.pack "device 7, queue 2")

-- | An ordinary public stop closes every publication, and an announcement
-- admitted just before it is still drained.
--
-- 'graphicsOwnerWorker' is public, so any caller can stop the owner without a
-- failure to latch. If the stop closed nothing, a handover admitted after the
-- drain's single take would never be processed and the host drain would wait
-- for evidence forever.
testNormalStopClosesPublications ∷ IO ()
testNormalStopClosesPublications = do
  rig ← newRig
  gate ← newTVarIO False
  stepping ← newEmptyMVar
  -- The owner is held inside a step, so the announcement below is admitted
  -- and certainly not yet consumed when the stop arrives.
  script (fakeStep (rigFake rig)) $ \_ → do
    putMVar stepping ()
    atomically (readTVar gate >>= check)
    pure noStepWork
  (stage, refused) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    takeMVar stepping
    service ← handedOver host owner window
    stage ← atomically (custodyOf owner (graphicsAttachment service))
    -- An ordinary stop, from the public handle, with no failure anywhere.
    atomically (Worker.requestStop (graphicsOwnerWorker owner))
    atomically (writeTVar gate True)
    -- The owner's run ends. Its drain must still take that announcement and
    -- retire the target it names: a stop that closed nothing would leave the
    -- event unread and no record would ever appear here.
    _ ← awaitTerminal owner service
    demand ← prepare (OwnerDemand True Nothing)
    refused ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
    pure (stage, refused)
  -- The owner owed it from the instant the announcement was admitted.
  stage `shouldBe` Just CustodyAnnounced
  refused `shouldBe` PublicationClosed

-- | A direct attachment whose announcement was refused is settled by its
-- release, not reported as one the owner will retire.
--
-- The port is full and stays full, so the owner is never told. A release that
-- answered 'ReleaseBegun' would be claiming an evidence path that does not
-- exist, and the host drain would wait on it forever.
testUnannouncedDirectAttachSettles ∷ IO ()
testUnannouncedDirectAttachSettles = do
  rig ← newRigWith (\config → config {ownerEventCapacity = 1})
  gate ← newTVarIO False
  entered ← newEmptyMVar
  script (fakeStart (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure (ownerReady (Text.pack "late"))
  clock ← countingClock
  let config =
        (ownerSettings clock)
          { hostWindowConfigs = [windowNamed (Text.pack "first"), windowNamed (Text.pack "second")]
          }
  (admitted, answer, stage, pending) ← ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner _control → do
    takeMVar entered
    windows ← atomically (hostWindowIdentities host)
    case windows of
      [first, second] → do
        -- The one slot is spent by a handover the owner cannot drain.
        _ ← handedOver host owner first
        -- A direct attach, then an announcement the full port refuses.
        attached ← attachWindowGraphics host second (graphicsTargetProtocol host owner)
        service ← case attached of
          GraphicsAttached service → pure service
          other → unexpected ("the direct attachment failed: " <> show other)
        admitted ← announceGraphicsTarget owner service
        stageBefore ← atomically (custodyOf owner (graphicsAttachment service))
        stageBefore `shouldBe` Just CustodyRegistered
        answer ← releaseGraphicsTarget host owner service
        stage ← atomically (custodyOf owner (graphicsAttachment service))
        pending ← atomically (hostPendingAttachments host)
        atomically (writeTVar gate True)
        pure (admitted, describeRelease answer, stage, pending)
      other → unexpected ("the host created " <> show (length other) <> " windows")
  admitted `shouldBe` EventRefusedFull
  -- Settled here, and said so: the owner was never told and owes nothing.
  answer `shouldBe` "settled here"
  -- Settled and forgotten together: the owner is held in its startup and
  -- will take no round that could have pruned it.
  stage `shouldBe` Nothing
  -- Only the first handover's attachment is left pending.
  length pending `shouldBe` 1

describeRelease ∷ ReleaseAnswer → String
describeRelease = \case
  ReleaseBegun → "begun"
  ReleaseSettled → "settled here"
  ReleaseOwnerRetires → "owner retires it"
  ReleaseNoOp answer → "no-op " <> show answer
  ReleasePortFull → "port full"

-- | A direct attachment whose announcement was refused is settled by its
-- window's close, with no release of its own.
--
-- Nothing ever told the owner about it and nothing ever will, so the only
-- place its evidence can come from is the attachment's own protocol step —
-- which is the backstop every path that begins a retirement without a
-- release arrives at.
testUnannouncedClosedSettles ∷ IO ()
testUnannouncedClosedSettles = do
  rig ← newRigWith (\config → config {ownerEventCapacity = 1})
  gate ← newTVarIO False
  entered ← newEmptyMVar
  script (fakeStart (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure (ownerReady (Text.pack "late"))
  clock ← countingClock
  let config =
        (ownerSettings clock)
          { hostWindowConfigs = [windowNamed (Text.pack "first"), windowNamed (Text.pack "second")]
          }
  (admitted, stage, retirements) ← ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner control → do
    takeMVar entered
    windows ← atomically (hostWindowIdentities host)
    case windows of
      [first, second] → do
        _ ← handedOver host owner first
        attached ← attachWindowGraphics host second (graphicsTargetProtocol host owner)
        service ← case attached of
          GraphicsAttached service → pure service
          other → unexpected ("the direct attachment failed: " <> show other)
        admitted ← announceGraphicsTarget owner service
        -- The close, and nothing else: no release, no detach.
        _ ← closeHostWindow host second
        pumpUntil host control "the closed window's retirement" $
          (== 1) . length <$> atomically (hostPendingAttachments host)
        stage ← atomically (custodyOf owner (graphicsAttachment service))
        retirements ← readTVarIO (fakeRetirements (rigFake rig))
        atomically (writeTVar gate True)
        pure (admitted, stage, retirements)
      other → unexpected ("the host created " <> show (length other) <> " windows")
  admitted `shouldBe` EventRefusedFull
  -- Settled, and forgotten in the same breath: the owner takes no round that
  -- could have pruned it.
  stage `shouldBe` Nothing
  -- The backend was asked to retire nothing: it never had this target.
  retirements `shouldBe` []

-- | Once the owner's admission has ended, a handover attaches nothing at all.
--
-- Discovering the closure only at the announcement would mean reserving a
-- window's slot and settling it again on every attempt, against an owner that
-- will take no further round — one ledger entry per attempt, outside any
-- bound the configuration sets.
testHandoverAfterStopAttachesNothing ∷ IO ()
testHandoverAfterStopAttachesNothing = do
  rig ← newRig
  (answers, entries, pending) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    -- An ordinary public stop, and the owner runs out.
    atomically (Worker.requestStop (graphicsOwnerWorker owner))
    atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
    answers ← forM [1 ∷ Int .. 12] $ \_ → describeHandover <$> handOverGraphicsTarget host owner window
    (,,) answers <$> atomically (readOwnerCustody owner) <*> atomically (hostPendingAttachments host)
  answers `shouldBe` replicate 12 "owner closed"
  -- Nothing was attached, so nothing was registered and nothing settled.
  entries `shouldBe` []
  pending `shouldBe` []

-- | Every failed target retirement is retained, not the first few.
--
-- A host of this size can offer more retirements in one round than any
-- arbitrary cap would keep, and each failure is evidence the contract says
-- stays readable.
testEveryRetirementFailureRetained ∷ IO ()
testEveryRetirementFailureRetained = do
  rig ← newRig
  clock ← countingClock
  let windows = [windowNamed (Text.pack ("window " <> show n)) | n ← [1 ∷ Int .. 12]]
      config = (ownerSettings clock) {hostWindowConfigs = windows, hostWindowLimit = 12}
  script (fakeRetireTarget (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire target")))
  keptCount ← newTVarIO 0
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner control → do
      identities ← atomically (hostWindowIdentities host)
      services ← mapM (handedOver host owner) identities
      forM_ services (awaitStanding owner)
      forM_ services (releaseGraphicsTarget host owner)
      -- Every one of them fails its retirement, and every failure is kept.
      atomically $ do
        kept ← readOwnerFailures owner
        check (length kept >= length services)
      atomically . writeTVar keptCount . length =<< atomically (readOwnerFailures owner)
      -- Independent evidence lets this example's own exit finish.
      publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
      forM_ services $ \service → do
        acknowledgement ←
          atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
            >>= maybe (unexpected "the attachment kept no acknowledgement") pure
        forM_ allRetirementFacts $ \fact →
          void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
      pumpUntilRetired host control
  raised `shouldBe` Scripted (Text.pack "retire target")
  -- Twelve, which is more than the cap this used to have.
  readTVarIO keptCount >>= \kept → kept `shouldSatisfy` (>= 12)
  -- And the bound is the configuration's, not a number chosen here.
  retainedFailureBound 12 `shouldSatisfy` (>= 12)

-- | A delayed announcement of an incarnation the window's slot has moved past
-- is refused, and touches the replacement not at all.
testStaleAnnouncementRefused ∷ IO ()
testStaleAnnouncementRefused = do
  rig ← newRig
  (admitted, staleStage, owned, laterStage) ←
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
      window ← theWindow host
      first ← handedOver host owner window
      _ ← releaseGraphicsTarget host owner first
      _ ← awaitTerminal owner first
      pumpUntilRetired host control
      -- A fresh incarnation now holds the window's slot.
      later ← handedOver host owner window
      awaitStanding owner later `shouldReturn` TargetUsable
      -- The old service, announced now. It names an incarnation the slot has
      -- moved past, so nothing may be reopened for it.
      admitted ← announceGraphicsTarget owner first
      (,,,) admitted
        <$> atomically (custodyOf owner (graphicsAttachment first))
        <*> atomically (readOwnerTargets owner)
        <*> atomically (custodyOf owner (graphicsAttachment later))
  admitted `shouldBe` EventPortClosed
  -- The retired incarnation was not reopened, and no ghost target was made.
  staleStage `shouldSatisfy` (`notElem` [Just CustodyAnnounced, Just CustodyOwned])
  -- Only the replacement is held, and it is untouched.
  length owned `shouldBe` 1
  laterStage `shouldBe` Just CustodyOwned

-- | An attachment whose service was published and whose answer was then lost,
-- while the owner's admission closed in the same moment, is settled — not
-- marked settled with nothing recorded.
--
-- Certifying a fact is refused for an attachment that is still active, so a
-- settlement that did not first begin its retirement would leave the ledger
-- terminal, the facts unrecorded, and the drain waiting for good. The answer
-- is lost from 'Private.afterPublication', which is the one seam that reaches
-- an attachment in exactly that state: published, /active/, and outside the
-- handler that would otherwise have begun its retirement for us.
testLostAnswerWithClosedOwner ∷ IO ()
testLostAnswerWithClosedOwner = do
  rig ← newRig
  closing ← newTVarIO Nothing
  observedPhases ← newTVarIO Nothing
  let hooks =
        Private.noHostHooks
          { Private.afterPublication =
              readTVarIO closing >>= \case
                Nothing → pure ()
                Just (host, owner) → do
                  -- The owner's admission ends, and the caller's answer is
                  -- lost, at the one instant the attachment is published and
                  -- active.
                  atomically (Private.closeOwnerPublications (ownerHandoff owner))
                  phases ← atomically (attachmentPhases host)
                  atomically (writeTVar observedPhases (Just phases))
                  throwIO (Scripted (Text.pack "answer lost"))
          }
  (answer, pending, stage) ←
    ownedHostHooked hooks quietLogger (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      window ← theWindow host
      atomically (writeTVar closing (Just (host, owner)))
      answer ← try (handOverGraphicsTarget host owner window)
      (,,) (either (const "raised") describeHandover (answer ∷ Either SomeException GraphicsHandover))
        <$> atomically (hostPendingAttachments host)
        <*> atomically (readOwnerCustody owner)
  answer `shouldBe` "raised"
  -- The state the recovery actually met: one attachment, active. Nothing had
  -- begun its retirement, so 'retireStranded' had to begin it itself before a
  -- single fact could be certified.
  readTVarIO observedPhases `shouldReturn` Just [Just AttachmentActive]
  -- Settled for real: nothing is left pending for a drain to wait on, and
  -- nothing is left in the ledger claiming to be finished.
  pending `shouldBe` []
  stage `shouldBe` []

-- | Every pending attachment's phase, in the host's own order.
attachmentPhases ∷ WindowHost → STM [Maybe AttachmentPhase]
attachmentPhases host = do
  pending ← hostPendingAttachments host
  map (fmap viewPhase) <$> traverse (Private.hostAttachmentView host) pending

-- | Cancellation is honoured inside each backend call in turn, and releases
-- nothing early in any of them.
--
-- The delivery point is chosen rather than raced: each call signals that it
-- has been entered and then waits, and the example throws to the owner's own
-- thread while it is there.
testCancellationAtEachBackendCall ∷ IO ()
testCancellationAtEachBackendCall =
  forM_ [BackendConstruct, BackendRetireTarget, BackendDestroy] $ \at' → do
    rig ← newRig
    inside ← newTVarIO False
    release ← newTVarIO False
    absorbed ← newTVarIO (0 ∷ Int)
    releasedEarly ← newTVarIO Nothing
    -- Saying it has been entered is itself inside the absorbing loop, so a
    -- cancellation that arrives before the wait is reached is absorbed like
    -- any other rather than escaping the call the example means to interrupt.
    let gated ∷ IO a → IO a
        gated answer = do
          absorbing absorbed $ do
            atomically (writeTVar inside True)
            atomically (readTVar release >>= check)
          answer
    case at' of
      BackendConstruct →
        script (fakeConstruct (rigFake rig)) $ \start →
          gated (pure (TargetConstructed (targetEvidence (Text.pack (show (startingWindow start))))))
      BackendRetireTarget →
        script (fakeRetireTarget (rigFake rig)) $ \retire →
          gated (pure (targetRetired (Text.pack (show (retiringWindow retire)))))
      BackendDestroy →
        script (fakeDestroy (rigFake rig)) $ \_ → gated (pure (ownerDestroyed (Text.pack "destroyed")))
    -- The destruction is only ever entered during the exit, when the main
    -- thread is no longer in the body, so every case delivers from a helper
    -- rather than from the body itself.
    let deliver = do
          atomically (readTVar inside >>= check)
          ownerThread ← atomically $
            readTVar (fakeThreads (rigFake rig)) >>= \case
              thread : _ → pure thread
              [] → retry
          -- Delivered twice while the backend call is running, and absorbed
          -- by the call itself: a cancellation is not permission to abandon
          -- it.
          throwTo ownerThread ThreadKilled
          atomically (readTVar absorbed >>= check . (>= 1))
          throwTo ownerThread ThreadKilled
          atomically (readTVar absorbed >>= check . (>= 2))
          -- Nothing of the host's was released while the call was unfinished.
          notes ← journalled (rigJournal rig)
          atomically (writeTVar releasedEarly (Just (filter released notes)))
          atomically (writeTVar release True)
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
      window ← theWindow host
      void (forkIO deliver)
      service ← handedOver host owner window
      -- The body must not return before a call that happens during the run
      -- has been entered and interrupted, or the exit would stop the owner
      -- first and the gate would never be reached at all. The destruction is
      -- the exception: it is only ever entered during the exit.
      case at' of
        BackendConstruct → atomically (readTVar release >>= check)
        BackendRetireTarget → do
          void (awaitStanding owner service)
          _ ← releaseGraphicsTarget host owner service
          atomically (readTVar release >>= check)
          _ ← awaitTerminal owner service
          pumpUntilRetired host control
        BackendDestroy → void (awaitStanding owner service)
    readTVarIO releasedEarly >>= \seen → (show at', seen) `shouldBe` (show at', Just [])
    readTVarIO absorbed >>= \count → count `shouldSatisfy` (>= 2)
    -- And the exit still completed in dependency order.
    notes ← journalled (rigJournal rig)
    ordered notes [OwnerRetirement, OwnerDestruction, SessionEnded]
  where
    released = \case
      WindowGone _ → True
      SessionEnded → True
      _ → False

-- | Which backend call an example delivers its cancellation inside.
data BackendCall
  = BackendConstruct
  | BackendRetireTarget
  | BackendDestroy
  deriving (Eq, Show)


-- | A cancellation that /escapes/ each injected operation, rather than being
-- absorbed by it, and what the owner then does with the call it interrupted.
--
-- The example above proves that a call which absorbs a cancellation is not
-- abandoned. This one asks the opposite question: the fake absorbs nothing,
-- so the exception really does leave the operation, and what is asserted is
-- the owner's own conduct — which is not observable at all while the fake
-- keeps swallowing it.

-- | A construction the cancellation escaped is settled unverified, and the
-- owner retires what it must therefore assume it owns, in dependency order.
testEscapedConstructionCancellation ∷ IO ()
testEscapedConstructionCancellation = do
  rig ← newRig
  inside ← newTVarIO False
  never ← newTVarIO False
  observedStanding ← newTVarIO Nothing
  script (fakeConstruct (rigFake rig)) $ \_ → do
    atomically (writeTVar inside True)
    atomically (readTVar never >>= check)
    unexpected "the interrupted construction returned"
  -- The retirement is held until the example has read the standing: the
  -- cancellation takes the owner into its drain at once, and the drain
  -- retires — and so forgets — the very target the standing is about.
  gate ← newTVarIO False
  script (fakeRetireTarget (rigFake rig)) $ \retire → do
    atomically (readTVar gate >>= check)
    pure (targetRetired (Text.pack (show (retiringWindow retire))))
  (raised, _) ← caughtAs @AsyncException $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
      window ← theWindow host
      void (forkIO (killInside rig inside))
      service ← handedOver host owner window
      -- Neither accepted nor verifiably rolled back: the owner records what
      -- it knows, which is that it may own whatever the call had built.
      standing ← awaitStanding owner service
      atomically (writeTVar observedStanding (Just standing))
      atomically (writeTVar gate True)
      _ ← releaseGraphicsTarget host owner service
      _ ← awaitTerminal owner service
      pumpUntilRetired host control
  raised `shouldBe` ThreadKilled
  readTVarIO observedStanding `shouldReturn` Just (TargetUnusable True)
  -- Retired as an unconstructed target, and the whole exit kept its order.
  retirements ← readTVarIO (fakeRetirements (rigFake rig))
  map retiringConstructed retirements `shouldBe` [False]
  notes ← journalled (rigJournal rig)
  ordered
    notes
    [ TargetRetirement (Text.pack "WindowId 1")
    , OwnerRetirement
    , OwnerDestruction
    , WindowGone 1
    , SessionEnded
    ]

-- | A target retirement the cancellation escaped manufactures no evidence and
-- is never offered again — not by a later round, and not by the drain.
--
-- It is the same contract a synchronous failure has, and it must not depend
-- on which kind of exception ended the call: the operation was entered, what
-- it did is unknown, and asking again could dispose something twice.
testEscapedRetirementCancellation ∷ IO ()
testEscapedRetirementCancellation = do
  rig ← newRig
  inside ← newTVarIO False
  never ← newTVarIO False
  script (fakeRetireTarget (rigFake rig)) $ \_ → do
    atomically (writeTVar inside True)
    atomically (readTVar never >>= check)
    unexpected "the interrupted target retirement returned"
  observedTargets ← newTVarIO []
  observedRecords ← newTVarIO []
  (raised, _) ← caughtAs @AsyncException $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
      window ← theWindow host
      service ← handedOver host owner window
      awaitStanding owner service `shouldReturn` TargetUsable
      void (forkIO (killInside rig inside))
      _ ← releaseGraphicsTarget host owner service
      -- The run has ended and its drain has finished, so nothing is still to
      -- come that could offer the operation a second time.
      atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
      atomically . writeTVar observedRecords . Map.keys =<< atomically (readTargetTerminalsNow owner)
      atomically . writeTVar observedTargets =<< atomically (readOwnerTargets owner)
      -- Independent evidence is the only thing that can retire it now, which
      -- is what lets this example's own exit finish.
      publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
      acknowledgement ←
        atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
          >>= maybe (unexpected "the attachment kept no acknowledgement") pure
      forM_ allRetirementFacts $ \fact →
        void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
      pumpUntilRetired host control
  raised `shouldBe` ThreadKilled
  -- No acknowledgement was manufactured for a call whose outcome is unknown.
  readTVarIO observedRecords `shouldReturn` []
  -- The target stays the owner's, explicitly unverified.
  readTVarIO observedTargets >>= \held → length held `shouldBe` 1
  -- And it was offered exactly once, over the whole run and its drain.
  notes ← journalled (rigJournal rig)
  length [() | TargetRetirement _ ← notes] `shouldBe` 1

-- | A destruction the cancellation escaped establishes nothing, so the host,
-- its windows, its session and every parent stay retained until independent
-- evidence arrives — and nothing is released early on the way there.
testEscapedDestructionCancellation ∷ IO ()
testEscapedDestructionCancellation = do
  rig ← newRig
  inside ← newTVarIO False
  never ← newTVarIO False
  trace ← newSinkTrace
  let recording = sinkFailingOn (Text.pack "never") trace
  script (fakeDestroy (rigFake rig)) $ \_ → do
    atomically (writeTVar inside True)
    atomically (readTVar never >>= check)
    unexpected "the interrupted destruction returned"
  releasedEarly ← newTVarIO Nothing
  (unverified, _) ← caughtAs @OwnerDestructionUnverified $
    ownedHostWith recording (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
      window ← theWindow host
      service ← handedOver host owner window
      awaitStanding owner service `shouldReturn` TargetUsable
      _ ← releaseGraphicsTarget host owner service
      _ ← awaitTerminal owner service
      pumpUntilRetired host control
      -- The destruction is only ever entered during the exit, when the main
      -- thread is no longer in the body, so both the interruption and the
      -- independent evidence come from a thread of the example's own.
      void . forkIO $ do
        killInside rig inside
        -- The owner's run has ended with nothing established, and the exit
        -- has said once what it is retaining for the want of it.
        atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
        awaitDiagnostic trace
        notes ← journalled (rigJournal rig)
        atomically (writeTVar releasedEarly (Just (filter released notes)))
        publishOwnerDestruction owner (ownerDestroyed (Text.pack "destroyed independently"))
  -- Nothing was released for a destruction that established nothing: the
  -- windows and the session both outlast the whole retained wait.
  readTVarIO releasedEarly `shouldReturn` Just []
  -- The owner retired; only its destruction is unverified, and no target is.
  unverifiedRetired unverified `shouldBe` True
  unverifiedTargets unverified `shouldBe` 0
  -- The destruction raised and was offered exactly once: an operation whose
  -- outcome is unknown is not repeated, and no evidence was manufactured for
  -- it. Only the independent publication ended the wait.
  notes ← journalled (rigJournal rig)
  length [() | OwnerDestruction ← notes] `shouldBe` 1
  length [() | DestroyRaised _ ← notes] `shouldBe` 1
  where
    released = \case
      WindowGone _ → True
      SessionEnded → True
      _ → False

-- | Wait until an injected call has been entered, then cancel the thread it
-- is running on — which is the owner's, because the owner is the only thread
-- that makes one.
killInside ∷ Rig → TVar Bool → IO ()
killInside rig inside = do
  atomically (readTVar inside >>= check)
  ownerThread ← atomically $
    readTVar (fakeThreads (rigFake rig)) >>= \case
      thread : _ → pure thread
      [] → retry
  throwTo ownerThread ThreadKilled

-- ---------------------------------------------------------------------------
-- One failure, reported once

-- | A failure the owner retained while it kept running is reported exactly
-- once, not once as the exit's own primary and again as its retained cleanup.
--
-- The latch and the retained store hold the same first failure by design —
-- one is notification, what a supervision sentinel waits on, and the other is
-- evidence with its own context — so an exit that raised both would report a
-- single failed operation twice and invent a second one that never happened.
--
-- The application's own action fails as well, so the boundary keeps that
-- failure primary and retains everything the exit found beside it, which is
-- where inspection can count them.
testRetainedFailureReportedOnce ∷ IO ()
testRetainedFailureReportedOnce = do
  rig ← newRig
  script (fakeRetireTarget (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire target")))
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    service ← handedOver host owner window
    awaitStanding owner service `shouldReturn` TargetUsable
    _ ← releaseGraphicsTarget host owner service
    -- Latched and retained together, which is the pair this example is about.
    atomically (readOwnerFailure owner >>= check . isJust)
    atomically (readOwnerFailures owner >>= check . not . null)
    -- Nothing offers the failed retirement again, so independent evidence is
    -- what retires the attachment and lets this exit finish at all.
    publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
    acknowledgement ←
      atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
        >>= maybe (unexpected "the attachment kept no acknowledgement") pure
    forM_ allRetirementFacts $ \fact →
      void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
    pumpUntilRetired host control
    throwIO (Scripted (Text.pack "body"))
  caught ← raisedBy outcome
  fromException caught `shouldBe` Just (Scripted (Text.pack "body"))
  -- Once over the primary and every cleanup failure retained beside it.
  occurrencesOf (Scripted (Text.pack "retire target")) caught `shouldBe` 1

-- | A failure that escaped the owner's own run is reported exactly once too.
--
-- This one is latched /and/ carried out by the worker's own outcome, so it is
-- the other way a single failure could be told twice.
testEscapingRunFailureReportedOnce ∷ IO ()
testEscapingRunFailureReportedOnce = do
  rig ← newRig
  script (fakeStep (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "step")))
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_host owner _control → do
    atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
    throwIO (Scripted (Text.pack "body"))
  caught ← raisedBy outcome
  fromException caught `shouldBe` Just (Scripted (Text.pack "body"))
  occurrencesOf (Scripted (Text.pack "step")) caught `shouldBe` 1

-- | The production composition reports a supervised owner failure exactly
-- once: the sentinel raises it at the application's checkpoint, and the exit
-- does not raise it again.
--
-- This is the shape a real application has, and the one the two examples
-- above cannot reach: without 'superviseGraphicsOwner' the exit is the only
-- reporter and nothing can duplicate. With it, the latched failure has a
-- designated reporter, and everything the exit still owes — each distinct
-- failure the drain found — has to survive that.
testSupervisedFailureReportedOnce ∷ IO ()
testSupervisedFailureReportedOnce = do
  rig ← newRig
  failing ← newTVarIO False
  -- The step fails only once the example says so, so the sentinel is
  -- certainly registered before the failure it must deliver exists.
  script (fakeStep (rigFake rig)) $ \_ →
    readTVarIO failing >>= \doomed →
      if doomed then throwIO (Scripted (Text.pack "fatal step")) else pure noStepWork
  -- A distinct failure in the drain, which the worker's outcome retains
  -- beside the run's own. It must still be reported exactly once, which is
  -- what makes this more than "drop the worker's outcome".
  script (fakeRetireOwner (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire owner")))
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_host owner control → do
    started ← superviseGraphicsOwner control owner
    case started of
      WorkerStarted _ → pure ()
      other → unexpected ("the sentinel did not start: " <> describeStart other)
    atomically (writeTVar failing True)
    -- Immediate demand wakes the idle owner into the step that fails.
    demand ← prepare (OwnerDemand True Nothing)
    _ ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
    atomically (readOwnerFailure owner >>= check . isJust)
    -- The checkpoint is where the sentinel's failure reaches the application,
    -- and from there it is the composition's primary failure.
    checkRuntime control
  caught ← raisedBy outcome
  fromException caught `shouldBe` Just (Scripted (Text.pack "fatal step"))
  -- Once over the primary and every cleanup failure retained beside it.
  occurrencesOf (Scripted (Text.pack "fatal step")) caught `shouldBe` 1
  -- And the drain's own failure, which nothing else reported, is still there
  -- exactly once: suppressing the duplicate may not swallow a distinct one.
  occurrencesOf (Scripted (Text.pack "retire owner")) caught `shouldBe` 1

-- | A supervised failure the owner /survived/ is reported exactly once too.
--
-- It latches from the retained store rather than from the run's end, which is
-- the other source the exit has to account for.
testSupervisedRetainedFailureReportedOnce ∷ IO ()
testSupervisedRetainedFailureReportedOnce = do
  rig ← newRig
  script (fakeRetireTarget (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire target")))
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    started ← superviseGraphicsOwner control owner
    case started of
      WorkerStarted _ → pure ()
      other → unexpected ("the sentinel did not start: " <> describeStart other)
    window ← theWindow host
    service ← handedOver host owner window
    awaitStanding owner service `shouldReturn` TargetUsable
    _ ← releaseGraphicsTarget host owner service
    atomically (readOwnerFailure owner >>= check . isJust)
    -- Nothing offers the failed retirement again, so independent evidence is
    -- what retires the attachment and lets this exit finish at all.
    publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
    acknowledgement ←
      atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
        >>= maybe (unexpected "the attachment kept no acknowledgement") pure
    forM_ allRetirementFacts $ \fact →
      void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
    pumpUntilRetired host control
    checkRuntime control
  caught ← raisedBy outcome
  fromException caught `shouldBe` Just (Scripted (Text.pack "retire target"))
  occurrencesOf (Scripted (Text.pack "retire target")) caught `shouldBe` 1

-- | A sentinel that never delivered may not make the exit suppress anything.
--
-- The exit leaves out the failure supervision has already reported, so the
-- record that it /was/ reported has to mean it really was. This cancels the
-- sentinel while it is still waiting, before any failure exists for it to
-- take, and then makes one: nothing was delivered, nothing is recorded, and
-- the exit reports the failure in full.
--
-- The remaining window — between the transaction that records the delivery
-- and the raise it promises — is closed by masking rather than by an example,
-- because once masked there is no instant at which it can be observed.
testUndeliveredSentinelSuppressesNothing ∷ IO ()
testUndeliveredSentinelSuppressesNothing = do
  rig ← newRig
  failing ← newTVarIO False
  script (fakeStep (rigFake rig)) $ \_ →
    readTVarIO failing >>= \doomed →
      if doomed then throwIO (Scripted (Text.pack "fatal step")) else pure noStepWork
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_host owner control → do
    started ← superviseGraphicsOwner control owner
    sentinel ← case started of
      WorkerStarted worker → pure worker
      other → unexpected ("the sentinel did not start: " <> describeStart other)
    -- Cancelled while it waits, which is the one part of it that is
    -- interruptible, and before any failure exists for it to take.
    cancelSupervised sentinel
    atomically (Worker.pollCompletion (supervisedWorker sentinel) >>= check . isJust)
    -- Only now does the owner fail, so the sentinel certainly delivered
    -- nothing.
    atomically (writeTVar failing True)
    demand ← prepare (OwnerDemand True Nothing)
    _ ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
    atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
  caught ← raisedBy outcome
  -- Reported by the exit, because nothing else reported it, and reported once.
  fromException caught `shouldBe` Just (Scripted (Text.pack "fatal step"))
  occurrencesOf (Scripted (Text.pack "fatal step")) caught `shouldBe` 1

-- | Every injected operation's answer is committed with no interruption
-- point between the two.
--
-- This is the window itself, observed from inside it. A cancellation
-- delivered between a /successful/ backend call and the record of what it
-- returned would discard evidence the backend really established: a
-- construction would stay pending and be built a second time, and a target
-- retirement would be neither recorded nor marked, so the drain would offer
-- it again — disposing a second time what the backend has already disposed.
--
-- There is nothing to race here, and deliberately so. The seam only /looks/:
-- anything that blocked in this window would itself be the interruption point
-- the mask exists to keep out, so what an example can assert is that the
-- window is masked, at every site that has one.
testOperationAnswersCommitUninterrupted ∷ IO ()
testOperationAnswersCommitUninterrupted = do
  rig ← newRig
  states ← newTVarIO []
  let hooks =
        Private.noHostHooks
          { Private.afterOwnerOperation =
              getMaskingState >>= \state → atomically (modifyTVar' states (<> [state]))
          }
  ownedHostHooked hooks quietLogger (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    service ← handedOver host owner window
    awaitStanding owner service `shouldReturn` TargetUsable
    _ ← releaseGraphicsTarget host owner service
    _ ← awaitTerminal owner service
    pumpUntilRetired host control
  -- The owner's startup, one construction and one target retirement, each
  -- masked from the answer through the commit.
  seen ← readTVarIO states
  length seen `shouldSatisfy` (>= 3)
  filter (/= MaskedInterruptible) seen `shouldBe` []

-- | A target retirement that returned is recorded, whatever is delivered to
-- the owner as it returns — so it is never offered a second time.
--
-- The call itself stays interruptible, and a cancellation inside it leaves
-- the target explicitly unverified and the operation spent. What must not
-- happen is a cancellation between the answer and the record of it: the
-- target would be neither retired nor marked, and the drain would offer the
-- operation again, disposing a second time what the backend already disposed.
testRetirementRecordSurvivesCancellation ∷ IO ()
testRetirementRecordSurvivesCancellation = do
  rig ← newRig
  entered ← newTVarIO False
  attempts ← newTVarIO (0 ∷ Int)
  recorded ← newTVarIO []
  script (fakeRetireTarget (rigFake rig)) $ \retire → do
    atomically (modifyTVar' attempts (+ 1))
    atomically (writeTVar entered True)
    pure (targetRetired (Text.pack (show (retiringWindow retire))))
  -- Delivered again and again from the instant the call is entered, so one of
  -- them lands wherever the owner is least protected — inside the call, on
  -- its way out, or after the record.
  let harry = do
        atomically (readTVar entered >>= check)
        ownerThread ← atomically $
          readTVar (fakeThreads (rigFake rig)) >>= \case
            thread : _ → pure thread
            [] → retry
        forM_ [1 ∷ Int .. 20] (\_ → throwTo ownerThread ThreadKilled)
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    service ← handedOver host owner window
    awaitStanding owner service `shouldReturn` TargetUsable
    void (forkIO harry)
    _ ← releaseGraphicsTarget host owner service
    atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
    -- Independent evidence, so this exit finishes whichever way the
    -- retirement settled.
    publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
    acknowledgement ←
      atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
        >>= maybe (unexpected "the attachment kept no acknowledgement") pure
    forM_ allRetirementFacts $ \fact →
      void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
    pumpUntilRetired host control
    -- Captured here rather than returned: the run itself raises the
    -- cancellation at its exit, so the body's value never reaches the caller.
    atomically . writeTVar recorded . Map.keys =<< atomically (readTargetTerminalsNow owner)
  -- However it ended, it ended by raising the cancellation rather than
  -- swallowing it.
  void (raisedBy outcome)
  -- Offered exactly once, over the whole run and its drain, however many
  -- cancellations arrived.
  readTVarIO attempts `shouldReturn` 1
  -- And because it returned, its record exists: a retirement the owner
  -- performed is never one the owner then forgets, and never one the drain
  -- performs a second time.
  readTVarIO recorded >>= \terminals → length terminals `shouldBe` 1

-- | The failure a caught run raised, failing the example if it returned.
raisedBy ∷ Either SomeException a → IO SomeException
raisedBy = either pure (\_ → unexpected "the run returned instead of failing")

-- | How many times one failure appears in a raised exception: as the
-- exception itself, and in every cleanup failure retained beside it.
occurrencesOf ∷ Scripted → SomeException → Int
occurrencesOf wanted caught =
  length (filter (== Just wanted) (fromException caught : retained))
  where
    retained =
      [ fromException (exceptionOf (cleanupFailureException failure))
      | failure ← cleanupFailures caught
      ]

exceptionOf ∷ ExceptionWithContext SomeException → SomeException
exceptionOf (ExceptionWithContext _ failure) = failure

-- ---------------------------------------------------------------------------
-- The extent seam

testExtentFromBackend ∷ IO ()
testExtentFromBackend =
  chooseTargetExtent RenderEligible geometry (BackendSupplied (Extent 1280 720))
    `shouldBe` ExtentFromBackend (Extent 1280 720)
  where
    geometry = TargetGeometry (Just (Extent 100 100)) (Just (ExtentBounds (Extent 1 1) (Extent 200 200)))

testExtentFromObservation ∷ IO ()
testExtentFromObservation = do
  chooseTargetExtent RenderEligible geometry ApplicationChooses
    `shouldBe` ExtentFromObservation (Extent 200 200)
  chooseTargetExtent RenderEligible unbounded ApplicationChooses
    `shouldBe` ExtentFromObservation (Extent 640 480)
  chooseTargetExtent RenderEligible noTargetGeometry ApplicationChooses
    `shouldBe` ExtentWithheld ExtentUnobserved
  where
    geometry = TargetGeometry (Just (Extent 640 480)) (Just (ExtentBounds (Extent 1 1) (Extent 200 200)))
    unbounded = TargetGeometry (Just (Extent 640 480)) Nothing

testExtentWithheld ∷ IO ()
testExtentWithheld = do
  -- Suspended first: a clamp must never resume a target the observation
  -- suspended.
  chooseTargetExtent RenderSuspended blank ApplicationChooses
    `shouldBe` ExtentWithheld (ExtentNotEligible RenderSuspended)
  -- Then zero area, before the clamp that would otherwise raise it to the
  -- reported minimum.
  chooseTargetExtent RenderEligible blank ApplicationChooses
    `shouldBe` ExtentWithheld (ExtentZeroArea (Extent 0 480))
  chooseTargetExtent RenderEligible blank (BackendSupplied (Extent 0 0))
    `shouldBe` ExtentWithheld (ExtentZeroArea (Extent 0 0))
  where
    blank = TargetGeometry (Just (Extent 0 480)) (Just (ExtentBounds (Extent 16 16) (Extent 4096 4096)))

testGeometryKeepsLastCoherent ∷ IO ()
testGeometryKeepsLastCoherent = do
  geometryFramebuffer folded `shouldBe` Just (Extent 640 480)
  geometryBounds folded `shouldBe` Just (ExtentBounds (Extent 1 1) (Extent 8 8))
  where
    -- A later observation the platform could report neither for leaves both.
    folded = observeGeometry Nothing Nothing once
    once = observeGeometry (Just (Extent 640 480)) (Just (ExtentBounds (Extent 1 1) (Extent 8 8))) noTargetGeometry

-- ---------------------------------------------------------------------------
-- Small helpers

-- | Assert that these notes appear, in this order, among the journal's.
ordered ∷ [Note] → [Note] → IO ()
ordered journal expected = go journal expected
  where
    go _ [] = pure ()
    go [] remaining =
      unexpected
        ("the journal never reached " <> show remaining <> "; it held " <> show journal)
    go (entry : rest) (wanted : remaining)
      | entry == wanted = go rest remaining
      | otherwise = go rest (wanted : remaining)
