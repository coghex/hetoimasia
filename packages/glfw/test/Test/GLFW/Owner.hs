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

import Control.Concurrent (ThreadId, forkIO, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.DeepSeq (NFData (rnf))
import Control.Concurrent.STM
  ( TVar
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
  , SomeAsyncException
  , SomeException
  , fromException
  , throwIO
  , throwTo
  , try
  )
import Control.Monad (forM_, void)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Recovery (Disposition (Required))
import Hetoimasia.Foundation.Time
  ( Duration
  , MonotonicSource
  , scriptedSource
  )
import Hetoimasia.Foundation.Worker (pollCompletion, requestCancel)
import Hetoimasia.GLFW.Command
  ( SubmitResult (SubmitAccepted)
  , observeWindowCommand
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
import Hetoimasia.GLFW.Session (defaultSessionConfig)
import Hetoimasia.GLFW.Window
  ( Extent (..)
  , WindowId
  , WindowObservation
  , WindowResult (..)
  )
import Hetoimasia.Runtime.GLFW
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( RuntimeControl
  , SupervisedStart (..)
  , checkRuntime
  )
import Numeric.Natural (Natural)
import Test.GLFW.Support
  ( at
  , boundedExample
  , caughtAs
  , current
  , millis
  , quietLogger
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

  describe "independent progress" $ do
    it "keeps taking rounds while the main thread is blocked"
      (boundedExample testBlockedMainThread)
    it "serves the main thread's window commands while the owner is blocked inside a step"
      (boundedExample testBlockedOwner)
    it "progresses with the main loop's wake withheld entirely"
      (boundedExample testWakeWithheld)
    it "meets a deadline of its own from its own timer, with nothing else waking it"
      (boundedExample testOwnDeadline)

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
    it "services the main thread's bounded housekeeping while it awaits the owner"
      (boundedExample testHousekeepingDuringDrain)
    it "retires and destroys the whole owner with no target ever attached"
      (boundedExample testWholeOwnerWithoutTargets)
    it "retires and destroys it after the last target has already detached"
      (boundedExample testWholeOwnerAfterLastTarget)

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
        readTVarIO (fakeDestroy fake) >>= ($ destroy)
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
ownedHost seam config ownerConfig action =
  asProcessMainThread seam $
    runGraphicsOwnerApplication
      (withLoggingLifetime quietLogger)
      (Text.pack "owner-example")
      ( \_ use →
          withGraphicsOwnerHostIn
            quietLogger
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
            { ownerClockTimer = injected
            , ownerFailureDisposition = Required
            }
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
  terminalPublished record `shouldBe` allRetirementFacts
  map retiringConstructed retirements `shouldBe` [False]

-- | A construction whose failure the backend did not verify a rollback for
-- leaves the owner owning something, so the owner retires it.
testCancelledConstruction ∷ IO ()
testCancelledConstruction = do
  rig ← newRig
  script (fakeConstruct (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "transfer")))
  observedStanding ← newTVarIO Nothing
  observedRecord ← newTVarIO Nothing
  -- The owner's disposition is required, so the failure it kept is terminal
  -- and the whole run reports it. What the example asserts is what the owner
  -- did with the target /before/ that: it kept it, and it retired it.
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      window ← theWindow host
      service ← handedOver host owner window
      standing ← awaitStanding owner service
      atomically (writeTVar observedStanding (Just standing))
      _ ← releaseGraphicsTarget host owner service
      record ← awaitTerminal owner service
      atomically (writeTVar observedRecord (Just record))
      pumpUntilRetired host _control
  raised `shouldBe` Scripted (Text.pack "transfer")
  -- Neither accepted nor verifiably rolled back, so the owner still owned
  -- whatever the interrupted construction left, and retired that.
  readTVarIO observedStanding `shouldReturn` Just (TargetUnusable True)
  record ← readTVarIO observedRecord
  fmap terminalPublished record `shouldBe` Just allRetirementFacts
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
  terminalPublished record `shouldBe` allRetirementFacts
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
    awaitRound owner 5
  statusRounds status `shouldSatisfy` (> 5)

-- | An owner blocked inside its own step does not stop the main thread's
-- window commands.
testBlockedOwner ∷ IO ()
testBlockedOwner = do
  rig ← newRig
  gate ← newTVarIO False
  entered ← newEmptyMVar
  script (fakeStep (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure noStepWork
  submitted ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    _ ← handedOver host owner window
    takeMVar entered
    -- The owner is inside its step. The main thread's own port still admits,
    -- and its own turn still executes.
    admitted ← submitWindowCommand (hostCommandPort host) [] (observeWindowCommand window)
    atomically (writeTVar gate True)
    pure admitted
  submitted `shouldSatisfy` \case
    SubmitAccepted _ → True
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
    pure (statusRounds status)
  rounds `shouldSatisfy` (> 3)

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
          settled ← atomically (pollCompletion (graphicsOwnerWorker owner))
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
    isPump = \case
      PollEvents → True
      WaitEvents _ → True
      _ → False

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
  retiring ← newEmptyMVar
  -- The owner fails after it has started, and its whole-owner retirement is
  -- deliberately held open while the application checkpoints.
  script (fakeStep (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "fatal step")))
  script (fakeRetireOwner (rigFake rig)) $ \_ → do
    putMVar retiring ()
    atomically (readTVar release >>= check)
    pure (ownerRetired (Text.pack "retired after the checkpoint"))
  (raised, phaseAtCheckpoint) ← do
    observedPhase ← newTVarIO OwnerStarting
    (caught, _) ← caughtAs @Scripted $
      ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner control → do
        started ← superviseGraphicsOwner control owner
        case started of
          WorkerStarted _ → pure ()
          other → unexpected ("the sentinel did not start: " <> describeStart other)
        takeMVar retiring
        status ← atomically (readOwnerStatusNow owner)
        atomically (writeTVar observedPhase (statusPhase status))
        -- Retirement is deliberately unfinished, and the checkpoint still
        -- raises. Released here so the exit can complete afterwards.
        _ ← forkIO (atomically (writeTVar release True))
        checkRuntime control
    phase ← readTVarIO observedPhase
    pure (caught, phase)
  raised `shouldBe` Scripted (Text.pack "fatal step")
  phaseAtCheckpoint `shouldBe` OwnerRetiring

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
  -- Nothing the backend is asked for succeeds after startup, so the owner ends
  -- with no record for its target and no destruction evidence of its own.
  script (fakeStep (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "step")))
  script (fakeRetireTarget (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire target")))
  script (fakeRetireOwner (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire owner")))
  script (fakeDestroy (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "destroy")))
  (unverified, _) ← caughtAs @OwnerDestructionUnverified $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
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
      -- only thing that can retire it — which is what lets this example's own
      -- exit finish rather than retaining the window forever.
      publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
      acknowledgement ←
        atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
          >>= maybe (unexpected "the attachment kept no acknowledgement") pure
      void . forkIO . forM_ allRetirementFacts $ \fact →
        void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
  unverifiedRetired unverified `shouldBe` False
  unverifiedTargets unverified `shouldBe` 1

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
    _ ← releaseGraphicsTarget host owner first
    _ ← awaitTerminal owner first
    pumpUntilRetired host _control
    second ← handedOver host owner window
    -- Fill the inbox with the retired incarnation's notices. Each is a
    -- distinct value, so none coalesces; each will be refused by the model
    -- when the owner thread folds it, and none establishes anything.
    publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
    stale ←
      atomically (ownerTargetAcknowledgement owner (graphicsAttachment first))
        >>= maybe (unexpected "the first incarnation kept no acknowledgement") pure
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
