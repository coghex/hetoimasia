-- | Examples for the /public/ exclusive attachment contract: attaching a
-- graphics owner to an open window, the opaque service that hands back,
-- observing the slot without inference, detaching, and the bounded retirement
-- progress a running owner turn offers.
--
-- "Test.GLFW.Protected" covers the protected lifetime and its exit drain
-- through the package's private seam. This module covers what an application
-- outside the package can reach — 'attachWindowGraphics',
-- 'detachWindowGraphics', 'windowGraphicsStatus', 'readGraphicsService',
-- 'hostRetirementDemand', and the completion publisher — and the behaviour that
-- is new with it: retirement that runs while the application runs, on owner
-- turns, bounded and rotating, and feeding the scheduled loop's own wait.
--
-- Every example asserts an /order of flags/ or an observed state, never a time,
-- and coordinates threads with STM and 'MVar's. Nothing here initializes GLFW,
-- opens a window, needs a display, or sleeps for a concurrency outcome.
module Test.GLFW.Attachments (spec) where

import Control.Concurrent (forkIO, forkOS, killThread, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
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
  , fromException
  , throw
  , throwIO
  , try
  )
import Control.Monad (forM, forM_, void, when)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Log (Component, Logger, unsafeComponent)
import Hetoimasia.Foundation.Recovery (Disposition (Required))
import Hetoimasia.Foundation.Resource (allocResource, withScoped)
import Hetoimasia.Foundation.Worker (WorkerDefinition, awaitStopRequest, workerDefinition)
import Hetoimasia.Foundation.Time (Instant, MonotonicSource)
import Hetoimasia.GLFW.Command
  ( SubmitResult (..)
  , clientCommandPort
  , closeWindowCommand
  , observeWindowCommand
  , pollCompletion
  , submitWindowCommand
  )
import Hetoimasia.GLFW.Internal.Attachment
  ( AttachmentEvidence (evidenceFirstFailure)
  , AttachmentFailure (DisposalFailure)
  , AttachmentView (viewEvidence)
  )
import Hetoimasia.GLFW.Internal.Seam
  ( NativeCall (CreateWindow, DestroyWindow)
  , Seam
  , SeamScript (..)
  , asProcessMainThread
  , defaultScript
  , designateProcessMainThread
  , newSeam
  , seamCalls
  , seamSession
  )
import Hetoimasia.GLFW.Session (defaultSessionConfig)
import Hetoimasia.GLFW.Window (WindowConfig, WindowId, WindowResult (..))
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Recognition (Unrecognized)
  , Role (Job)
  , RuntimeControl
  , SupervisedStart (..)
  , SupervisedWorker
  , WorkerPolicy (..)
  , startSupervised
  )
import Numeric.Natural (Natural)
import Test.GLFW.Support
  ( at
  , boundedExample
  , durationOf
  , millis
  , quietLogger
  , scriptedClock
  , unexpected
  , windowNamed
  )
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "GLFW window attachments" $ do
  describe "attaching" $ do
    it "refuses a closing window, an ended window, an occupied window, a foreign session, and an unprotected host"
      (boundedExample testRefusals)
    it "publishes the opaque service only once construction and registration have both completed"
      (boundedExample testPublishedAfterRegistration)
    it "publishes nothing usable when the host's admission closes while the construction runs"
      (boundedExample testSupersededByQuiescence)
    it "publishes nothing usable when admission closes in the handoff between construction and publication"
      (boundedExample testSupersededAtHandoff)
    it "retires a construction whose rollback established safety, and frees the slot for a fresh incarnation"
      (boundedExample testRollbackSafeFreesSlot)
    it "retains one whose rollback could not, keeping the window, the slot, and every owed fact"
      (boundedExample testRollbackUnsafeRetains)
    it "counts a cancellation delivered before publication and still publishes nothing"
      (boundedExample testCancelledConstruction)
    it "retires an attachment its caller was interrupted out of, so a turn frees the slot"
      (boundedExample testCancelledAtPublication)
    it "hands a published attachment back by window, so a caller that lost the answer can still detach it"
      (boundedExample testServiceRecoverableFromHost)
    it "publishes nothing usable when the construction closes its own window, and keeps it for retirement"
      (boundedExample testClosedDuringConstruction)
    it "asks for a turn at once after a cancelled construction its rollback could not make safe"
      (boundedExample testCancelledRollbackWantsATurn)
    it "answers a declaration that raises when it is demanded, having reserved and constructed nothing"
      (boundedExample testMetadataRejectedBeforeConstruction)

  describe "observing the slot" $ do
    it "separates the close from the destruction, which follows the last retirement fact"
      (boundedExample testCloseThenDestruction)
    it "keeps a retained service's terminal answers after the host has forgotten the window"
      (boundedExample testTerminalObservationRetained)
    it "keeps a failed native release distinct from a failed retirement step"
      (boundedExample testDisposalFailureDistinct)
    it "reports a closed and a quiesced owner to a retained service in the transaction that ends its admission"
      (boundedExample testAdmissionVisibleAtOnce)
    it "never credits a window's disposal to an incarnation the slot moved past"
      (boundedExample testDisposalNeverCreditedToEarlier)
    it "never credits it to one whose successor was cancelled before it could publish"
      (boundedExample testDisposalNeverCreditedAfterCancellation)
    it "tells a service retained across a normal exit how the window it never closed was released"
      (boundedExample (testDisposalAtHostExit DisposalCompleted))
    it "tells it when that release failed instead"
      (boundedExample (testDisposalAtHostExit DisposalFailed))
    it "finalizes a service whose last facts a draining worker published between quiescence and the exit"
      (boundedExample testRetiredByNoticesAtExit)

  describe "detaching" $ do
    it "frees the slot only after safe disposal, and a later attachment gets a fresh incarnation"
      (boundedExample testDetachThenReattach)
    it "refuses a stale acknowledgement from the retired incarnation and releases nothing"
      (boundedExample testStaleAcknowledgementRefused)
    it "refuses a second owner while the first is still retiring"
      (boundedExample testSlotHeldWhileRetiring)
    it "answers a typed no-op for an absent or already retiring owner"
      (boundedExample testDetachNoOps)
    it "stays bounded across repeated detaching and reattaching"
      (boundedExample testRepeatedCyclesBounded)

  describe "independent progress" $ do
    it "serves one window's commands and retirement while another window's retirement is pending"
      (boundedExample testIndependentWindows)
    it "destroys a stalled owner's neighbour, and finishes the stalled one on independent evidence"
      (boundedExample testStalledNeighbour)
    it "offers opportunities under a rotating bounded budget"
      (boundedExample testRotatingBudget)
    it "counts an unserved attachment as deferred even when the one it served withdrew"
      (boundedExample testUnservedCountedAsDeferred)
    it "refuses an owner that declares a blocking step, without running it, and reports the refusal"
      (boundedExample testBlockingOwnerRefused)
    it "contains a declaration that fails after acquisition, retaining the window until independent evidence"
      (boundedExample testMetadataFailsOnTurn)
    it "ends the owner's idle wait with a completion published from another thread, and folds it in the next round"
      (boundedExample testCompletionWakesTurn)

  describe "reviving a withdrawn path" $ do
    it "offers one further opportunity for a fact certified on the owner thread, and none for a duplicate of it"
      (boundedExample testDirectCertificationRevives)
    it "offers one further opportunity for the same fact folded from a notice, and none for a duplicate of it"
      (boundedExample testNoticeRevives)
    it "offers the restored registration the exit drain's opportunities too, not only a running turn's"
      (boundedExample testDirectCertificationRevivesForTheDrain)
    it "revives nothing for a report the model refuses, on the owner thread or through a notice"
      (boundedExample testRefusedReportRevivesNothing)

  describe "the schedule" $ do
    it "polls the turn a detach begins, shortens the next wait to the instant the owner named, and polls once a round advanced"
      (boundedExample testRetirementSchedule)
    it "waits once every owner beyond the budget has been offered one opportunity and is awaiting"
      (boundedExample testWaitingOwnersBeyondBudgetWait)
    it "waits to an instant an earlier round learned, polls for it when it comes due unserved, and clears it when its owner names none"
      (boundedExample testRetainedDeadlinesBoundLaterWaits)
    it "keeps the turn immediate for an owner whose latest opportunity advanced, through rounds that leave it unserved"
      (boundedExample testAdvancedOwnerStaysImmediate)
    it "polls while a stalled owner's neighbour is still owed its first opportunity, then waits beside the stalled one"
      (boundedExample testStalledNeighbourThenWaits)
    it "polls again for a retirement begun between two waiting turns"
      (boundedExample testNewRetirementEndsTheWaiting)
    it "polls again for an owner whose waiting assessment new evidence outdated"
      (boundedExample testNewEvidenceEndsTheWaiting)

  describe "the application exit" $
    it "retires every attached owner, then destroys the windows and ends the session"
      (boundedExample testExitWithOwners)

  describe "ordinary window-only callers" $
    it "see no slot, no demand, and no change to their turns"
      (boundedExample testOrdinaryHostUnaffected)

-- ---------------------------------------------------------------------------
-- The journal

-- | The independent facts an example asserts the order of.
data Note
  = Certified !Text !RetirementFact
  | Constructed !Text
  | Rendered !Text
    -- ^ One scripted render an owner's service admitted.
  | WindowGone !Int
    -- ^ The seam's own destroy call, named by the window's creation order.
  | SessionEnded
  deriving (Eq, Show)

note ∷ TVar [Note] → Note → STM ()
note journal entry = modifyTVar' journal (<> [entry])

-- | Every flag one whole retirement sets, in the order the owner sets them.
retiring ∷ Text → [Note]
retiring name = map (Certified name) allRetirementFacts

newtype Scripted = Scripted Text
  deriving (Eq, Show)

instance Exception Scripted

-- ---------------------------------------------------------------------------
-- The scripted owner

-- | What one scripted opportunity does. A plan that runs out stalls, so an
-- example never silently retires an attachment it did not certify.
data Step
  = Certify !RetirementFact
  | Await
  | AwaitUntil !Instant
  | Stall
  deriving (Eq, Show)

data OwnerScript = OwnerScript
  { scriptName ∷ Text
  , scriptConstruct ∷ IO ()
  , scriptRollback ∷ IO RollbackOutcome
  , scriptPlan ∷ [Step]
  , scriptCompletion ∷ CompletionPolicy
  , scriptDisposition ∷ Disposition
  }

-- | An owner that constructs without effect and certifies every fact, one per
-- opportunity.
ownerNamed ∷ Text → OwnerScript
ownerNamed name =
  OwnerScript name (pure ()) (pure RollbackSafe) (map Certify allRetirementFacts) FiniteCompletion Required

-- | One attached scripted owner, as the example observes it.
data Owner = Owner
  { ownerName ∷ !Text
  , ownerAcknowledgement ∷ !(TVar (Maybe Acknowledgement))
  , ownerPlan ∷ !(TVar [Step])
  , ownerSteps ∷ !(TVar Int)
    -- ^ Every opportunity the boundary offered, so an example can prove a step
    -- was refused without being run, or not replayed.
  }

newOwner ∷ OwnerScript → IO Owner
newOwner script =
  Owner (scriptName script)
    <$> newTVarIO Nothing
    <*> newTVarIO (scriptPlan script)
    <*> newTVarIO 0

attachScripted
  ∷ TVar [Note] → WindowHost → WindowId → OwnerScript → IO (Owner, GraphicsAttachment)
attachScripted journal host window script = do
  owner ← newOwner script
  outcome ← attachWindowGraphics host window (protocolFor journal host owner script)
  pure (owner, outcome)

-- | The one owner an example expects to be established, beside its service.
attachedOwner ∷ TVar [Note] → WindowHost → WindowId → OwnerScript → IO (Owner, GraphicsService)
attachedOwner journal host window script =
  attachScripted journal host window script >>= \case
    (owner, GraphicsAttached service) → pure (owner, service)
    (_, other) → unexpected ("the attachment was not established: " <> show other)

protocolFor ∷ TVar [Note] → WindowHost → Owner → OwnerScript → AttachmentProtocol
protocolFor journal host owner script =
  AttachmentProtocol
    { protocolConstruct = \_ acknowledgement → do
        atomically $ do
          writeTVar (ownerAcknowledgement owner) (Just acknowledgement)
          note journal (Constructed (scriptName script))
        scriptConstruct script
    , protocolRollback = scriptRollback script
    , protocolStep = \_ acknowledgement → do
        step ← atomically $ do
          modifyTVar' (ownerSteps owner) (+ 1)
          readTVar (ownerPlan owner) >>= \case
            [] → pure Stall
            next : rest → next <$ writeTVar (ownerPlan owner) rest
        perform acknowledgement step
    , protocolCompletion = scriptCompletion script
    , protocolDisposition = scriptDisposition script
    , protocolRecognizes = \_ → pure False
    }
  where
    perform acknowledgement = \case
      Await → pure RetirementAwaiting
      AwaitUntil due → pure (RetirementAwaitingUntil due)
      Stall → pure RetirementStalled
      Certify fact → do
        atomically (note journal (Certified (ownerName owner) fact))
        void (certifyGraphicsFact host acknowledgement fact)
        pure RetirementAdvanced

-- | The owner's own completion authority, once its construction has stored it.
heldAcknowledgement ∷ Owner → IO Acknowledgement
heldAcknowledgement owner = atomically (readTVar (ownerAcknowledgement owner) >>= maybe retry pure)

-- | One scripted graphics use through an attached service.
--
-- There is no surface and no submission at this boundary, so what "new use"
-- means here is exactly what the contract says it means: a use may begin only
-- while the owner's own slot still admits one. The service's retained
-- observation and the host's own reading of the slot must agree, and the use is
-- noted only when it was really admitted.
renderThrough ∷ TVar [Note] → WindowHost → Text → GraphicsService → IO Bool
renderThrough journal host name service = atomically $ do
  observed ← readGraphicsService service
  held ← windowGraphicsStatus host (graphicsWindow service)
  let admits = case held of
        GraphicsPresent seen → observedSlot seen == SlotAttached
        _ → False
      usable = observedSlot observed == SlotAttached && admits
  when usable (note journal (Rendered name))
  pure usable

-- | Publish an owner's certified facts from a thread that is not the owner.
publishFacts ∷ TVar [Note] → WindowHost → Owner → [RetirementFact] → IO ()
publishFacts journal host owner facts = do
  publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
  acknowledgement ← heldAcknowledgement owner
  let target = acknowledgedAttachment acknowledgement
  forM_ facts $ \fact → do
    atomically (note journal (Certified (ownerName owner) fact))
    publishCompletion publisher (completionNotice target acknowledgement fact) >>= \case
      CompletionOffered NoticeRejectedFull → unexpected "the completion inbox refused a notice"
      CompletionClosed → unexpected "the boundary had already closed publication"
      _ → pure ()

-- ---------------------------------------------------------------------------
-- The seam and the runner

-- | A seam that journals its own destroy and terminate calls, and whose finite
-- wait returns at once so ordinary owner turns keep coming.
pollingSeam ∷ TVar [Note] → IO Seam
pollingSeam = seamWith False (\_ → pure ())

-- | 'pollingSeam' whose finite wait blocks until an empty event has been
-- posted, which is exactly what the session's internal wake does. An idle turn
-- therefore really waits, and a completion published from another thread really
-- ends that wait.
blockingSeam ∷ TVar [Note] → IO Seam
blockingSeam = seamWith True (\_ → pure ())

-- | 'pollingSeam' whose destroy call fails for the window at this creation
-- order, so a native release failure can be told apart from a retirement one.
failingDestroySeam ∷ Int → TVar [Note] → IO Seam
failingDestroySeam key = seamWith False $ \destroyed →
  when (destroyed == key) (throwIO (Scripted "destroy"))

seamWith ∷ Bool → (Int → IO ()) → TVar [Note] → IO Seam
seamWith blocking onDestroy journal = do
  posts ← newTVarIO (0 ∷ Int)
  held ← newIORef Nothing
  seam ←
    newSeam
      defaultScript
        { scriptDestroyWindow = \_ → do
            destroyed ← readIORef held >>= maybe (pure 0) (fmap latestDestroyed . seamCalls)
            atomically (note journal (WindowGone destroyed))
            onDestroy destroyed
        , scriptTerminate = \_ → atomically (note journal SessionEnded)
        , scriptWaitEvents = \_ _ →
            when blocking $
              atomically (readTVar posts >>= \pending → if pending <= 0 then retry else writeTVar posts (pending - 1))
        , scriptPostEmptyEvent = \_ → atomically (modifyTVar' posts (+ 1))
        }
  writeIORef held (Just seam)
  pure seam

-- | The window being destroyed now: the seam records the call before it runs
-- the destroy hook, so the last one recorded is this one.
latestDestroyed ∷ [NativeCall] → Int
latestDestroyed calls = last (0 : [key | DestroyWindow key ← calls])

-- | Run one application over a protected host in the seam's session, on a bound
-- thread designated as the process main thread.
protectedRun
  ∷ Seam
  → HostConfig
  → (WindowHost → IO ())
  → (WindowHost → RuntimeControl → IO a)
  → IO a
protectedRun seam config inside action =
  asProcessMainThread seam (protectedRunHere seam quietLogger config inside action)

protectedRunHere
  ∷ Seam
  → Logger
  → HostConfig
  → (WindowHost → IO ())
  → (WindowHost → RuntimeControl → IO a)
  → IO a
protectedRunHere seam logger config inside action =
  runProtectedWindowApplication
    (withLoggingLifetime logger)
    "attachment-example"
    ( \_ use →
        withProtectedWindowHostIn logger (seamSession seam defaultSessionConfig) config $ \host →
          inside host >> use host
    )
    id
    (\host _ → pure host)
    action

-- | Run owner turns until @ready@ answers, failing the example rather than
-- looping if it never does.
turnsUntil ∷ WindowHost → RuntimeControl → String → IO Bool → IO ()
turnsUntil host control what ready =
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
              if turnNumber turn > turnBound
                then unexpected ("the loop never reached " <> what)
                else pure Continue
      }

-- | Enough turns for any example here to settle, and few enough that one that
-- cannot settle fails rather than running until the example's own bound.
turnBound ∷ Natural
turnBound = 200

-- | Run a fixed number of turns, whatever they find.
turnsExactly ∷ WindowHost → RuntimeControl → Natural → IO ()
turnsExactly host control count =
  runOwnerLoop
    host
    control
    LoopHooks
      { loopLogger = quietLogger
      , loopEvent = noApplicationEvents
      , loopUpdate = \turn → pure (if turnNumber turn >= count then Finish () else Continue)
      }

settings ∷ [WindowConfig] → HostConfig
settings windows =
  (defaultHostConfig windows)
    { hostCommandCapacity = 8
    , hostCommandBudget = 3
    , hostEventBudget = 2
    , hostIdleWait = 0.25
    }

onlyWindow ∷ WindowHost → IO WindowId
onlyWindow host =
  atomically (hostWindowIdentities host) >>= \case
    [identity] → pure identity
    windows → unexpected ("expected one window, found " <> show (length windows))

threeWindows ∷ WindowHost → IO (WindowId, WindowId, WindowId)
threeWindows host =
  atomically (hostWindowIdentities host) >>= \case
    [alpha, beta, gamma] → pure (alpha, beta, gamma)
    windows → unexpected ("expected three windows, found " <> show (length windows))

twoWindows ∷ WindowHost → IO (WindowId, WindowId)
twoWindows host =
  atomically (hostWindowIdentities host) >>= \case
    [alpha, beta] → pure (alpha, beta)
    windows → unexpected ("expected two windows, found " <> show (length windows))

-- | Whether the host still holds an attachment for this window.
slotOccupied ∷ WindowHost → WindowId → IO Bool
slotOccupied host window =
  atomically (windowGraphicsStatus host window) >>= \case
    GraphicsPresent _ → pure True
    _ → pure False

observation ∷ GraphicsService → IO GraphicsObservation
observation = atomically . readGraphicsService

destroyCalls ∷ Seam → IO [Int]
destroyCalls seam = (\calls → [key | DestroyWindow key ← calls]) <$> seamCalls seam

createCalls ∷ Seam → IO Int
createCalls seam = (\calls → length [() | CreateWindow{} ← calls]) <$> seamCalls seam

-- ---------------------------------------------------------------------------
-- Attaching

-- | Every refusal requirement 1 names, each answered before any acquisition:
-- the construction of a refused owner never runs, so the journal records none
-- of them.
testRefusals ∷ Expectation
testRefusals = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  unprotected ← newIORef Nothing
  answers ← newIORef []
  -- A window of a session that is not this host's, taken from a host of its
  -- own over a second scripted platform and outliving it as a bare identity.
  elsewhere ← newSeam defaultScript
  foreignWindow ←
    asProcessMainThread elsewhere $
      withScoped
        (allocWindowHostIn (seamSession elsewhere defaultSessionConfig) (settings [windowNamed "elsewhere"]))
        onlyWindow
  -- A host built as an ordinary scoped dependency owns no retirement state, so
  -- it was issued no identity an attachment could name.
  asProcessMainThread seam $
    runWindowApplication
      (withLoggingLifetime quietLogger)
      "ordinary-host"
      (allocWindowHostIn (seamSession seam defaultSessionConfig) (settings [windowNamed "plain"]))
      id
      ( \host _ → do
          window ← onlyWindow host
          (_, outcome) ← attachScripted journal host window (ownerNamed "plain")
          writeIORef unprotected (Just outcome)
      )
      (\() _ → pure ())
  readIORef unprotected >>= \case
    Just GraphicsHostUnprotected → pure ()
    other → unexpected ("the unprotected host did not refuse: " <> show other)

  -- Two protected hosts over one session, so a window of one can be offered to
  -- the other beside one that really has ended.
  asProcessMainThread seam . withScoped (seamSession seam defaultSessionConfig) $ \session →
    withProtectedWindowHostIn
      quietLogger
      (pure session)
      (settings [windowNamed "outer", windowNamed "spare", windowNamed "doomed"])
      $ \outer →
        withProtectedWindowHostIn quietLogger (pure session) (settings [windowNamed "inner"]) $ \inner → do
          (outerWindow, spare, doomed) ← threeWindows outer
          innerWindow ← onlyWindow inner
          -- Another session's window.
          (_, foreign') ← attachScripted journal inner foreignWindow (ownerNamed "foreign")
          -- Another host's window, of this very session: this host holds no
          -- such window, which is the one answer it can give without keeping a
          -- record of every window it ever held.
          (_, otherHost) ← attachScripted journal inner outerWindow (ownerNamed "borrowed")
          -- Occupied: the slot is exclusive from the reservation on.
          void (attachedOwner journal inner innerWindow (ownerNamed "inner"))
          (_, occupied) ← attachScripted journal inner innerWindow (ownerNamed "intruder")
          -- Ended: nothing borrows and nothing attaches, so this window is
          -- destroyed and forgotten by its own close.
          void (closeHostWindow outer doomed)
          identities ← atomically (hostWindowIdentities outer)
          when (doomed `elem` identities) (unexpected "the doomed window was not retired by its close")
          (_, ended) ← attachScripted journal outer doomed (ownerNamed "gone")
          -- Closing: the close protocol has begun and a borrow of the spare
          -- window defers the retirement, so the window is still held.
          closing ←
            withHostWindow outer spare $ \_ → do
              void (closeHostWindow outer outerWindow)
              snd <$> attachScripted journal outer outerWindow (ownerNamed "late")
          -- Quiesced: attachment admission has closed for good.
          atomically (quiesceWindowHost outer)
          (_, admission) ← attachScripted journal outer spare (ownerNamed "too late")
          writeIORef answers [foreign', otherHost, occupied, ended, refusalAnswer closing, admission]
  map refusalOfAnswer <$> readIORef answers
    `shouldReturn` [ Just "foreign session"
                   , Just "unavailable"
                   , Just "occupied"
                   , Just "unavailable"
                   , Just "closing"
                   , Just "admission ended"
                   ]
  -- Only the one owner that was established was ever constructed.
  entries ← readTVarIO journal
  [name | Constructed name ← entries] `shouldBe` ["inner"]

-- | The answer a borrowed window's callback handed back, which 'withHostWindow'
-- wraps in its own result.
refusalAnswer ∷ WindowResult GraphicsAttachment → GraphicsAttachment
refusalAnswer = \case
  WindowAvailable answer → answer
  WindowEnded _ → GraphicsRefused GraphicsSlotUnavailable

-- | A short name for the refusal an answer carries, so an example asserts the
-- refusal rather than an identity it cannot spell.
refusalOfAnswer ∷ GraphicsAttachment → Maybe String
refusalOfAnswer = \case
  GraphicsRefused (GraphicsWindowOccupied _) → Just "occupied"
  GraphicsRefused (GraphicsWindowClosing _) → Just "closing"
  GraphicsRefused (GraphicsWindowUnavailable _) → Just "unavailable"
  GraphicsRefused GraphicsForeignSession → Just "foreign session"
  GraphicsRefused GraphicsAdmissionEnded → Just "admission ended"
  _ → Nothing

-- | The service is published after the construction has returned and the
-- registration has committed: the slot is observable as taken from the
-- reservation on, and the value that names it appears only at the end.
testPublishedAfterRegistration ∷ Expectation
testPublishedAfterRegistration = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  during ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    owner ← newOwner (ownerNamed "alpha")
    let script = ownerNamed "alpha"
        watching =
          (protocolFor journal host owner script)
            { protocolConstruct = \_ acknowledgement → do
                -- Inside the construction: the reservation has committed, so
                -- the window's slot already reports an owner, and no service
                -- exists yet for anybody to use.
                seen ← atomically (windowGraphicsStatus host window)
                writeIORef during (Just seen)
                atomically (writeTVar (ownerAcknowledgement owner) (Just acknowledgement))
            }
    outcome ← attachWindowGraphics host window watching
    case outcome of
      GraphicsAttached service → do
        graphicsWindow service `shouldBe` window
        graphicsIncarnation service `shouldBe` 1
        observed ← observation service
        observedSlot observed `shouldBe` SlotAttached
        observedMissing observed `shouldBe` allRetirementFacts
        observedDisposal observed `shouldBe` DisposalPending
      other → unexpected ("the attachment was not established: " <> show other)
    void (closeHostWindow host window)
    atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
    turnsUntil host control "alpha's destruction" (not . null <$> destroyCalls seam)
  readIORef during >>= \case
    Just (GraphicsPresent observed) → do
      observedIncarnation observed `shouldBe` 1
      observedSlot observed `shouldBe` SlotAttached
    other → unexpected ("the slot was not reserved during construction: " <> show other)

-- | A construction that finishes after admission closed publishes nothing
-- usable: the dependents it made stay registered for retirement, and the
-- answer says so.
testSupersededByQuiescence ∷ Expectation
testSupersededByQuiescence = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  answered ← newIORef Nothing
  constructing ← newEmptyMVar
  closed ← newEmptyMVar
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host _ → do
    window ← onlyWindow host
    owner ← newOwner (ownerNamed "alpha")
    let script = ownerNamed "alpha"
        blocking =
          (protocolFor journal host owner script)
            { protocolConstruct = \_ acknowledgement → do
                atomically (writeTVar (ownerAcknowledgement owner) (Just acknowledgement))
                putMVar constructing ()
                takeMVar closed
            }
    -- Another thread closes the host's admission while the construction runs.
    _ ← forkIO (takeMVar constructing >> atomically (quiesceWindowHost host) >> putMVar closed ())
    outcome ← attachWindowGraphics host window blocking
    writeIORef answered (Just outcome)
    -- The facts are certified from another thread, so the exit drain can end.
    _ ← forkIO (publishFacts journal host owner allRetirementFacts)
    pure ()
  readIORef answered >>= \case
    Just (GraphicsSuperseded _) → pure ()
    other → unexpected ("the superseded construction was not answered: " <> show other)
  entries ← readTVarIO journal
  entries `shouldSatisfy` (WindowGone 1 `elem`)

-- | The window between a construction settling and its service being published
-- is not a window in which a service can appear for an owner that may admit no
-- use.
--
-- The private publication hook puts another thread's quiescence exactly there:
-- the model has already recorded the attachment active, and the publication
-- must nonetheless answer superseded rather than hand back a service.
testSupersededAtHandoff ∷ Expectation
testSupersededAtHandoff = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  answered ← newIORef Nothing
  observedThen ← newIORef Nothing
  atHandoff ← newEmptyMVar
  quiesced ← newEmptyMVar
  owned ← newTVarIO Nothing
  asProcessMainThread seam $
    runProtectedWindowApplication
      (withLoggingLifetime quietLogger)
      "attachment-example"
      ( \_ use →
          Private.withProtectedWindowHostWith
            Private.noHostHooks
              { Private.beforePublication = do
                  pending ← readTVarIO owned
                  forM_ pending $ \_ → putMVar atHandoff () >> takeMVar quiesced
              }
            quietLogger
            (seamSession seam defaultSessionConfig)
            (settings [windowNamed "alpha"])
            $ \host → do
              window ← onlyWindow host
              owner ← newOwner (ownerNamed "alpha")
              atomically (writeTVar owned (Just owner))
              -- Another thread closes the host's admission once the attachment
              -- has been constructed and registered, and before it is published.
              _ ←
                forkIO
                  ( takeMVar atHandoff
                      >> atomically (quiesceWindowHost host)
                      >> putMVar quiesced ()
                  )
              outcome ←
                attachWindowGraphics host window (protocolFor journal host owner (ownerNamed "alpha"))
              writeIORef answered (Just outcome)
              seen ← atomically (windowGraphicsStatus host window)
              writeIORef observedThen (Just seen)
              -- The facts are certified from another thread, so the exit drain
              -- can end.
              _ ← forkIO (publishFacts journal host owner allRetirementFacts)
              use host
      )
      id
      (\host _ → pure host)
      (\_ _ → pure ())
  readIORef answered >>= \case
    Just (GraphicsSuperseded _) → pure ()
    other → unexpected ("the handoff published a service: " <> show other)
  -- The dependents the construction made are still registered for retirement.
  readIORef observedThen >>= \case
    Just (GraphicsPresent observed) → observedSlot observed `shouldBe` SlotRetiring
    other → unexpected ("the superseded attachment was not retiring: " <> show other)
  entries ← readTVarIO journal
  entries `shouldSatisfy` (WindowGone 1 `elem`)

-- | A rollback that established safety leaves nothing to retire, publishes
-- nothing usable, and frees the slot: a later owner attaches with the next
-- incarnation.
testRollbackSafeFreesSlot ∷ Expectation
testRollbackSafeFreesSlot = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  answered ← newIORef Nothing
  incarnation ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (_, failed) ←
      attachScripted
        journal
        host
        window
        (ownerNamed "failing") {scriptConstruct = throwIO (Scripted "construction"), scriptRollback = pure RollbackSafe}
    writeIORef answered (Just failed)
    slotOccupied host window `shouldReturn` False
    (owner, service) ← attachedOwner journal host window (ownerNamed "later")
    writeIORef incarnation (Just (graphicsIncarnation service))
    void (closeHostWindow host window)
    atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
    turnsUntil host control "the later owner's destruction" (not . null <$> destroyCalls seam)
  readIORef answered >>= \case
    Just (GraphicsRolledBack settled) → rolledBackOutcome settled `shouldBe` RollbackSafe
    other → unexpected ("the rollback was not answered: " <> show other)
  -- Incarnations are never reissued, so the second owner is the second one.
  readIORef incarnation `shouldReturn` Just 2

-- | A rollback that could not establish safety keeps the window, the exclusive
-- slot, and every owed fact, with its evidence, exactly as the design requires
-- of a construction that never published a service.
testRollbackUnsafeRetains ∷ Expectation
testRollbackUnsafeRetains = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  retained ← newIORef Nothing
  refusedLater ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host _ → do
    window ← onlyWindow host
    owner ← newOwner (ownerNamed "failing")
    let script = ownerNamed "failing"
        failing =
          (protocolFor journal host owner script)
            { protocolConstruct = \_ acknowledgement → do
                atomically (writeTVar (ownerAcknowledgement owner) (Just acknowledgement))
                throwIO (Scripted "construction")
            , protocolRollback = pure RollbackUnsafe
            }
    outcome ← attachWindowGraphics host window failing
    case outcome of
      GraphicsRolledBack settled → rolledBackOutcome settled `shouldBe` RollbackUnsafe
      other → unexpected ("the rollback was not answered: " <> show other)
    seen ← atomically (windowGraphicsStatus host window)
    writeIORef retained (Just seen)
    -- The slot is not free, so no second owner may take it.
    (_, second) ← attachScripted journal host window (ownerNamed "second")
    writeIORef refusedLater (Just second)
    _ ← forkIO (publishFacts journal host owner allRetirementFacts)
    pure ()
  readIORef retained >>= \case
    Just (GraphicsPresent observed) → do
      observedSlot observed `shouldBe` SlotRetiring
      observedMissing observed `shouldBe` allRetirementFacts
    other → unexpected ("the unsafe rollback did not retain its slot: " <> show other)
  readIORef refusedLater >>= \answer →
    refusalOfAnswer <$> answer `shouldBe` Just (Just "occupied")

-- | A declaration the protocol carries that raises when it is demanded is
-- answered before anything is reserved.
--
-- Both declarations this boundary reads are covered: nothing is constructed,
-- no rollback runs, no attachment is registered, and the window's exclusive
-- slot is left exactly as it was found — so the next valid owner takes it with
-- the very first incarnation, which no rejected attempt consumed.
testMetadataRejectedBeforeConstruction ∷ Expectation
testMetadataRejectedBeforeConstruction = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  rolledBack ← newIORef (0 ∷ Int)
  answers ← newIORef []
  incarnation ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    let counting =
          (ownerNamed "faulty") {scriptRollback = modifyIORef' rolledBack (+ 1) >> pure RollbackSafe}
        faulty =
          [ counting {scriptCompletion = throw (Scripted "completion")}
          , counting {scriptDisposition = throw (Scripted "disposition")}
          ]
    forM_ faulty $ \script → do
      (_, answer) ← attachScripted journal host window script
      modifyIORef' answers (<> [answer])
      slotOccupied host window `shouldReturn` False
      atomically (hostPendingAttachments host) `shouldReturn` []
    -- No construction ran, so no rollback could have been owed one.
    readTVarIO journal `shouldReturn` []
    readIORef rolledBack `shouldReturn` 0
    (owner, service) ← attachedOwner journal host window (ownerNamed "alpha")
    writeIORef incarnation (Just (graphicsIncarnation service))
    void (closeHostWindow host window)
    atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
  readIORef answers >>= \case
    [completion, disposition] → do
      declarationFailureOf completion `shouldBe` Just (Scripted "completion")
      declarationFailureOf disposition `shouldBe` Just (Scripted "disposition")
    other → unexpected ("expected two answers, found " <> show (length other))
  -- Incarnations are issued by the reservation, and neither rejection made one.
  readIORef incarnation `shouldReturn` Just 1

-- | The typed failure the model recorded as one attachment's own evidence.
recordedFailureOf ∷ WindowHost → AttachmentId → IO (Maybe Scripted)
recordedFailureOf host target = do
  seen ← atomically (Private.hostAttachmentView host target)
  pure $ case evidenceFirstFailure . viewEvidence =<< seen of
    Just (DisposalFailure (ExceptionWithContext _ failure)) → fromException failure
    _ → Nothing

-- | The typed failure a rejected declaration was answered with.
declarationFailureOf ∷ GraphicsAttachment → Maybe Scripted
declarationFailureOf = \case
  GraphicsMetadataRejected rejected →
    case rejectedDeclaration rejected of
      ExceptionWithContext _ failure → fromException failure
  _ → Nothing

-- | A declaration that fails once the attachment has been acquired is contained
-- on the ordinary owner turn rather than raised out of it.
--
-- Metadata is demanded when the attachment is made, so this state is reached
-- through the package's own after-acquisition seam. The turn records the
-- failure as that attachment's evidence and withdraws its progress path: its
-- step is never entered, its window is not destroyed, and only independent
-- certified evidence retires it.
testMetadataFailsOnTurn ∷ Expectation
testMetadataFailsOnTurn = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  reported ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (owner, service) ← attachedOwner journal host window (ownerNamed "alpha")
    void (closeHostWindow host window)
    atomically
      ( Private.faultHostAttachmentMetadata
          host
          (graphicsAttachment service)
          (throw (Scripted "declaration"))
      )
    turnsExactly host control 3
    demand ← atomically (hostRetirementDemand host)
    writeIORef reported (Just demand)
    -- The step was never entered, and nothing the declaration failed at
    -- authorized destroying the window.
    atomically (readTVar (ownerSteps owner)) `shouldReturn` 0
    destroyCalls seam `shouldReturn` []
    slotOccupied host window `shouldReturn` True
    -- The failure the turn contained is the attachment's own evidence, kept
    -- exactly as a failed step's is.
    recordedFailureOf host (graphicsAttachment service) `shouldReturn` Just (Scripted "declaration")
    _ ← forkIO (publishFacts journal host owner allRetirementFacts)
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
  entries ← readTVarIO journal
  -- Every fact was certified independently, and all of them precede the
  -- destruction.
  takeWhile (/= WindowGone 1) entries `shouldSatisfy` \before →
    length [() | Certified{} ← before] == length allRetirementFacts
  readIORef reported >>= \case
    Just demand → retirementStalled demand `shouldBe` 1
    Nothing → unexpected "the turn reported no retirement demand"

-- | A cancellation delivered inside the construction is counted as evidence,
-- establishes no fact, and publishes nothing; the run's own cancellation is
-- what the caller sees.
testCancelledConstruction ∷ Expectation
testCancelledConstruction = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  constructing ← newEmptyMVar
  never ← newEmptyMVar
  finished ← newEmptyMVar
  runner ←
    forkOS $ do
      designateProcessMainThread seam
      outcome ←
        try . protectedRunHere seam quietLogger (settings [windowNamed "alpha"]) (\_ → pure ()) $
          \host _ → do
            window ← onlyWindow host
            owner ← newOwner (ownerNamed "alpha")
            let script = ownerNamed "alpha"
                parking =
                  (protocolFor journal host owner script)
                    { protocolConstruct = \_ acknowledgement → do
                        atomically (writeTVar (ownerAcknowledgement owner) (Just acknowledgement))
                        putMVar constructing ()
                        takeMVar never
                    , protocolRollback = pure RollbackSafe
                    }
            void (attachWindowGraphics host window parking)
      putMVar finished (outcome ∷ Either SomeException ())
  takeMVar constructing
  killThread runner
  takeMVar finished >>= \case
    Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
    Right () → unexpected "the cancelled run returned"
  -- Nothing was published, and the window was still destroyed on the way out.
  entries ← readTVarIO journal
  [name | Certified name _ ← entries] `shouldBe` []
  entries `shouldSatisfy` (WindowGone 1 `elem`)

-- | An interruption delivered in the handoff between an attachment becoming
-- active and its caller receiving the service must not strand the exclusive
-- slot.
--
-- The caller catches it and keeps running, so nothing else will clean up after
-- it: no service exists to detach with, and a running turn offers no
-- opportunity to an attachment that has not begun retiring. The attachment must
-- therefore already be retiring when the failure arrives, and ordinary turns
-- must then retire it and free the slot.
testCancelledAtPublication ∷ Expectation
testCancelledAtPublication = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  atHandoff ← newEmptyMVar
  never ← newEmptyMVar
  armed ← newTVarIO False
  caught ← newIORef Nothing
  afterwards ← newIORef Nothing
  reattached ← newIORef Nothing
  owned ← newTVarIO Nothing
  asProcessMainThread seam $
    runProtectedWindowApplication
      (withLoggingLifetime quietLogger)
      "attachment-example"
      ( \_ use →
          Private.withProtectedWindowHostWith
            Private.noHostHooks
              { Private.beforePublication = do
                  armedNow ← readTVarIO armed
                  when armedNow (putMVar atHandoff () >> takeMVar never)
              }
            quietLogger
            (seamSession seam defaultSessionConfig)
            (settings [windowNamed "alpha"])
            use
      )
      id
      (\host _ → pure host)
      ( \host control → do
          window ← onlyWindow host
          owner ← newOwner (ownerNamed "alpha")
          atomically (writeTVar owned (Just owner))
          -- The owner thread is interrupted while it is inside the handoff, and
          -- catches that interruption itself.
          me ← myThreadId
          _ ← forkIO (takeMVar atHandoff >> killThread me)
          atomically (writeTVar armed True)
          interrupted ←
            try (attachWindowGraphics host window (protocolFor journal host owner (ownerNamed "alpha")))
          atomically (writeTVar armed False)
          case (interrupted ∷ Either SomeException GraphicsAttachment) of
            Left failure → writeIORef caught (fromException failure ∷ Maybe AsyncException)
            Right answered → unexpected ("the interrupted handoff answered: " <> show answered)
          -- Already retiring, though nothing ever held a service for it.
          seen ← atomically (windowGraphicsStatus host window)
          writeIORef afterwards (Just seen)
          -- Ordinary turns retire it and free the slot, and the window is then
          -- open for a later owner with a fresh incarnation.
          turnsUntil host control "the stranded attachment's retirement" (not <$> slotOccupied host window)
          (later, service) ← attachedOwner journal host window (ownerNamed "later")
          writeIORef reattached (Just (graphicsIncarnation service))
          void (closeHostWindow host window)
          atomically (writeTVar (ownerPlan later) (map Certify allRetirementFacts))
          turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
      )
  readIORef caught `shouldReturn` Just ThreadKilled
  readIORef afterwards >>= \case
    Just (GraphicsPresent observed) → do
      observedSlot observed `shouldBe` SlotRetiring
      observedMissing observed `shouldBe` allRetirementFacts
    other → unexpected ("the stranded attachment was not retiring: " <> show other)
  -- Incarnations are never reissued, so the later owner is the second.
  readIORef reattached `shouldReturn` Just 2

-- | A value returned from an operation is not something the runtime can promise
-- to deliver: an interruption can reach the calling thread at the instant the
-- attach restores its masking state, beyond any handler it could install, with
-- the attachment already active and its service already published.
--
-- What the contract promises instead is that such an attachment is never
-- unreachable. The host hands the very same service back by window, and
-- detaching with it retires the slot exactly as detaching with the original
-- would. This example throws the answer away to prove it.
testServiceRecoverableFromHost ∷ Expectation
testServiceRecoverableFromHost = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  recovered ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (owner, published) ← attachedOwner journal host window (ownerNamed "alpha")
    -- Everything the caller kept of the attachment, discarded.
    same ← atomically (windowGraphicsService host window)
    writeIORef recovered ((== published) <$> same)
    service ← maybe (unexpected "the host handed back no service") pure same
    graphicsIncarnation service `shouldBe` graphicsIncarnation published
    detachWindowGraphics host service `shouldReturn` DetachBegun
    turnsUntil host control "the recovered owner's retirement" (not <$> slotOccupied host window)
    -- A free slot has no service to hand back, and neither has a window the
    -- host no longer holds.
    atomically (windowGraphicsService host window) >>= \case
      Nothing → pure ()
      Just _ → unexpected "a free slot handed back a service"
    atomically (readTVar (ownerSteps owner)) >>= \offered → offered `shouldSatisfy` (> 0)
    void (closeHostWindow host window)
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
    atomically (windowGraphicsService host window) >>= \case
      Nothing → pure ()
      Just _ → unexpected "an ended window handed back a service"
  readIORef recovered `shouldReturn` Just True

-- | A construction that closes its own window, reentrantly, on the very thread
-- the attach is running on.
--
-- The close begins the attachment's retirement before the construction has
-- returned, so the publication is superseded: nothing usable is handed over,
-- and whatever the construction built stays registered for retirement rather
-- than being abandoned.
testClosedDuringConstruction ∷ Expectation
testClosedDuringConstruction = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  answered ← newIORef Nothing
  begun ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    owner ← newOwner (ownerNamed "alpha")
    let script = ownerNamed "alpha"
        closing =
          (protocolFor journal host owner script)
            { protocolConstruct = \_ acknowledgement → do
                atomically (writeTVar (ownerAcknowledgement owner) (Just acknowledgement))
                atomically (note journal (Constructed "alpha"))
                -- Reentrant, on the owner thread, inside the attach itself.
                closeHostWindow host window >>= writeIORef begun . Just
            }
    outcome ← attachWindowGraphics host window closing
    writeIORef answered (Just outcome)
    -- Nothing usable was published, and the attachment is still the window's.
    atomically (windowGraphicsService host window) >>= \case
      Nothing → pure ()
      Just _ → unexpected "a superseded construction published a service"
    atomically (windowGraphicsStatus host window) >>= \case
      GraphicsPresent observed → do
        observedSlot observed `shouldBe` SlotRetiring
        observedMissing observed `shouldBe` allRetirementFacts
      other → unexpected ("the superseded attachment was not retained: " <> show other)
    destroyCalls seam `shouldReturn` []
    -- It retires through its own protocol, and only then is the window
    -- destroyed.
    atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
  readIORef begun `shouldReturn` Just CloseStarted
  readIORef answered >>= \case
    Just (GraphicsSuperseded _) → pure ()
    other → unexpected ("the reentrant close did not supersede the publication: " <> show other)
  entries ← readTVarIO journal
  filter (/= Constructed "alpha") entries `shouldBe` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A construction cancelled with a rollback that could not establish safety
-- re-raises rather than answering, so nothing settles its outcome — but it
-- leaves an attachment retiring all the same, and a caller that catches the
-- cancellation must not enter a loop that waits before offering it a turn.
testCancelledRollbackWantsATurn ∷ Expectation
testCancelledRollbackWantsATurn = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  (clock, _) ← scriptedClock (concatMap (\turn → [turn, turn]) (map millis [0 .. 7]))
  pacings ← newTVarIO []
  owned ← newTVarIO Nothing
  let config = (settings [windowNamed "alpha"]) {hostIdleWait = 0.25, hostClock = clock}
  protectedRun seam config (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    owner ← newOwner (ownerNamed "alpha")
    atomically (writeTVar owned (Just owner))
    let script = ownerNamed "alpha"
        cancelling =
          (protocolFor journal host owner script)
            { protocolConstruct = \_ acknowledgement → do
                atomically (writeTVar (ownerAcknowledgement owner) (Just acknowledgement))
                throwIO ThreadKilled
            , protocolRollback = pure RollbackUnsafe
            }
    interrupted ← try (attachWindowGraphics host window cancelling)
    case (interrupted ∷ Either SomeException GraphicsAttachment) of
      Left failure → (fromException failure ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
      Right answered → unexpected ("the cancelled construction answered: " <> show answered)
    -- Retained, owing everything, and never offered an opportunity.
    atomically (windowGraphicsStatus host window) >>= \case
      GraphicsPresent observed → observedMissing observed `shouldBe` allRetirementFacts
      other → unexpected ("the cancelled construction retained nothing: " <> show other)
    void
      ( runScheduledOwnerLoop host control $
          (defaultScheduledHooks quietLogger (\_ → pure (FinishWith ())))
            { scheduledUpdate = \turn → do
                atomically (modifyTVar' pacings (<> [scheduledPacing turn]))
                pure (if turnNumber (scheduledTurn turn) >= 2 then FinishWith () else ContinueWith NoUpdateDemand)
            }
      )
    atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
    void (closeHostWindow host window)
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
  readTVarIO pacings >>= \case
    first' : _ → first' `shouldBe` PolledForWork
    [] → unexpected "the scheduled loop ran no turns"

-- ---------------------------------------------------------------------------
-- Observing the slot

-- | Accepting a close is not acknowledging a destruction. The close settles its
-- own ticket at once, the slot reports retiring, and the window is destroyed
-- only after the last fact is certified.
testCloseThenDestruction ∷ Expectation
testCloseThenDestruction = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  afterClose ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (owner, service) ← attachedOwner journal host window (ownerNamed "alpha")
    -- Nothing is certified yet, so the close cannot be followed by a
    -- destruction however many turns run. The owner keeps its progress path:
    -- it answers that it may still progress rather than withdrawing.
    atomically (writeTVar (ownerPlan owner) (repeat Await))
    closeHostWindow host window `shouldReturn` CloseStarted
    turnsExactly host control 3
    seen ← observation service
    writeIORef afterClose (Just seen)
    destroyCalls seam `shouldReturn` []
    -- Now the owner certifies, one fact per opportunity.
    atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
    turnsUntil host control "alpha's destruction" (not . null <$> destroyCalls seam)
    final ← observation service
    observedSlot final `shouldBe` SlotFree
    observedMissing final `shouldBe` []
    observedDisposal final `shouldBe` DisposalCompleted
  readIORef afterClose >>= \case
    Just observed → do
      observedSlot observed `shouldBe` SlotRetiring
      observedMissing observed `shouldBe` allRetirementFacts
      observedDisposal observed `shouldBe` DisposalPending
    Nothing → unexpected "nothing was observed after the close"
  entries ← readTVarIO journal
  -- The destruction follows the last retirement fact, never precedes one.
  filter (/= Constructed "alpha") entries `shouldBe` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A retained service keeps answering after the host has forgotten its window
-- and after the whole application has ended, without the host owning any
-- history of its own.
testTerminalObservationRetained ∷ Expectation
testTerminalObservationRetained = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  kept ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (_, service) ← attachedOwner journal host window (ownerNamed "alpha")
    writeIORef kept (Just service)
    void (closeHostWindow host window)
    turnsUntil host control "alpha's destruction" (not . null <$> destroyCalls seam)
    -- The host holds no window, and so no slot, any more.
    atomically (windowGraphicsStatus host window) `shouldReturn` GraphicsWindowUnknown
    atomically (hostPendingAttachments host) `shouldReturn` []
  service ← readIORef kept >>= maybe (unexpected "no service was retained") pure
  observed ← observation service
  observedIncarnation observed `shouldBe` 1
  observedSlot observed `shouldBe` SlotFree
  observedMissing observed `shouldBe` []
  observedDisposal observed `shouldBe` DisposalCompleted

-- | A failed native release and a failed retirement step are separate
-- outcomes. The release failure is never reported as a successful destruction,
-- and it is never retried.
testDisposalFailureDistinct ∷ Expectation
testDisposalFailureDistinct = do
  journal ← newTVarIO []
  seam ← failingDestroySeam 1 journal
  kept ← newIORef Nothing
  outcome ←
    try . protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
      window ← onlyWindow host
      (_, service) ← attachedOwner journal host window (ownerNamed "alpha")
      writeIORef kept (Just service)
      void (closeHostWindow host window)
      turnsUntil host control "alpha's release attempt" (not . null <$> destroyCalls seam)
      -- One attempt only: a latched release failure is never attempted again.
      turnsExactly host control 3
      destroyCalls seam `shouldReturn` [1]
  case (outcome ∷ Either SomeException ()) of
    Left _ → pure ()
    Right () → unexpected "the failed release did not reach the caller"
  service ← readIORef kept >>= maybe (unexpected "no service was retained") pure
  observed ← observation service
  -- The retirement itself succeeded: every fact was certified and the slot is
  -- free. The disposal is separately reported as failed.
  observedSlot observed `shouldBe` SlotFree
  observedMissing observed `shouldBe` []
  observedDisposal observed `shouldBe` DisposalFailed

-- | A retained service must never report an attached owner after the
-- transaction that ended that owner's admission has committed.
--
-- Both transactions are checked with no owner turn in between: the close, whose
-- own commit publishes the window's closing phase, and quiescence, which ends
-- attachment admission for every window at once.
testAdmissionVisibleAtOnce ∷ Expectation
testAdmissionVisibleAtOnce = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  afterClose ← newIORef Nothing
  afterQuiescence ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha", windowNamed "beta"]) (\_ → pure ()) $ \host control → do
    (alpha, beta) ← twoWindows host
    (alphaOwner, alphaService) ← attachedOwner journal host alpha (ownerNamed "alpha")
    (betaOwner, betaService) ← attachedOwner journal host beta (ownerNamed "beta")
    -- No turn runs between the close and this read.
    closeHostWindow host alpha `shouldReturn` CloseStarted
    observation alphaService >>= writeIORef afterClose . Just
    -- Beta is untouched by alpha's close.
    betaBefore ← observation betaService
    observedSlot betaBefore `shouldBe` SlotAttached
    -- Quiescence ends beta's admission without closing its window, so the
    -- retained service must report it retiring though nothing has closed.
    atomically (quiesceWindowHost host)
    observation betaService >>= writeIORef afterQuiescence . Just
    forM_ [alphaOwner, betaOwner] $ \owner →
      atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
    -- Only a close destroys a window, so beta's is asked for here.
    void (closeHostWindow host beta)
    turnsUntil host control "both destructions" ((== 2) . length <$> destroyCalls seam)
  readIORef afterClose >>= \case
    Just observed → do
      observedSlot observed `shouldBe` SlotRetiring
      observedMissing observed `shouldBe` allRetirementFacts
    Nothing → unexpected "nothing was observed after the close"
  readIORef afterQuiescence >>= \case
    Just observed → observedSlot observed `shouldBe` SlotRetiring
    Nothing → unexpected "nothing was observed after quiescence"

-- | A window's disposal belongs to whichever incarnation is its last, and to no
-- earlier one — including when the later incarnation never published a service
-- at all.
testDisposalNeverCreditedToEarlier ∷ Expectation
testDisposalNeverCreditedToEarlier = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  kept ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (_, first') ← attachedOwner journal host window (ownerNamed "first")
    writeIORef kept (Just first')
    void (detachWindowGraphics host first')
    turnsUntil host control "the first owner's retirement" (not <$> slotOccupied host window)
    -- A later incarnation reserves the slot and then rolls back safely, so it
    -- publishes no service of its own. The earlier one is still not the
    -- window's last.
    (_, rolled) ←
      attachScripted
        journal
        host
        window
        (ownerNamed "second") {scriptConstruct = throwIO (Scripted "construction"), scriptRollback = pure RollbackSafe}
    case rolled of
      GraphicsRolledBack settled → rolledBackOutcome settled `shouldBe` RollbackSafe
      other → unexpected ("the second reservation was not rolled back: " <> show other)
    void (closeHostWindow host window)
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
  service ← readIORef kept >>= maybe (unexpected "no service was retained") pure
  observed ← observation service
  observedIncarnation observed `shouldBe` 1
  observedSlot observed `shouldBe` SlotFree
  -- The destruction that followed a later reservation is not this one's to
  -- report.
  observedDisposal observed `shouldBe` DisposalPending

-- | The reservation itself is what stops the host holding an earlier
-- incarnation's cell, so a later reservation that never returns at all — a
-- cancellation in its construction, which the boundary re-raises — cannot leave
-- the earlier one to collect the window's disposal.
testDisposalNeverCreditedAfterCancellation ∷ Expectation
testDisposalNeverCreditedAfterCancellation = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  kept ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (_, first') ← attachedOwner journal host window (ownerNamed "first")
    writeIORef kept (Just first')
    void (detachWindowGraphics host first')
    turnsUntil host control "the first owner's retirement" (not <$> slotOccupied host window)
    -- The second reservation commits and its construction is then cancelled, so
    -- the attach raises rather than answering at all.
    cancelled ←
      try . attachScripted journal host window $
        (ownerNamed "second") {scriptConstruct = throwIO ThreadKilled, scriptRollback = pure RollbackSafe}
    case (cancelled ∷ Either SomeException (Owner, GraphicsAttachment)) of
      Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
      Right _ → unexpected "the cancelled construction answered instead of raising"
    void (closeHostWindow host window)
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
  service ← readIORef kept >>= maybe (unexpected "no service was retained") pure
  observed ← observation service
  observedIncarnation observed `shouldBe` 1
  observedSlot observed `shouldBe` SlotFree
  observedDisposal observed `shouldBe` DisposalPending

-- | A window nobody ever closed is released by the host's own exit, and the
-- service retained across that exit must learn what the release settled as —
-- a destruction that happened, or one that failed.
testDisposalAtHostExit ∷ NativeDisposal → Expectation
testDisposalAtHostExit expected = do
  journal ← newTVarIO []
  seam ← case expected of
    DisposalFailed → failingDestroySeam 1 journal
    _ → pollingSeam journal
  kept ← newIORef Nothing
  outcome ←
    try . protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host _ → do
      window ← onlyWindow host
      (_, service) ← attachedOwner journal host window (ownerNamed "alpha")
      writeIORef kept (Just service)
      -- Nothing closes the window: the owner retires on the exit drain and the
      -- collection's own exit is what releases it.
      pure ()
  case (outcome ∷ Either SomeException (), expected) of
    (Right (), DisposalCompleted) → pure ()
    (Left _, DisposalFailed) → pure ()
    (Right (), DisposalFailed) → unexpected "the failed release did not reach the caller"
    (Left caught, _) → unexpected ("the run failed: " <> show caught)
    (_, other) → unexpected ("unexpected disposal expectation: " <> show other)
  service ← readIORef kept >>= maybe (unexpected "no service was retained") pure
  observed ← observation service
  observedSlot observed `shouldBe` SlotFree
  observedMissing observed `shouldBe` []
  observedDisposal observed `shouldBe` expected

-- | The ordinary shutdown shape: quiescence begins every retirement, a worker
-- publishes what it has ended as it drains, and the exit's own drain folds
-- those notices and finds nothing left pending on that very round.
--
-- The retirement is then complete before the drain has offered a single
-- opportunity, and a service retained across the exit must say so — free, owing
-- nothing, and with the disposal its window really ended with.
testRetiredByNoticesAtExit ∷ Expectation
testRetiredByNoticesAtExit = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  kept ← newIORef Nothing
  owned ← newTVarIO Nothing
  protectedRun
    seam
    (settings [windowNamed "alpha"])
    ( \host → do
        window ← onlyWindow host
        -- Its own opportunities establish nothing, so only the published
        -- notices can retire it.
        (owner, service) ← attachedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Stall]}
        atomically (writeTVar owned (Just owner))
        writeIORef kept (Just service)
    )
    ( \host control → do
        owner ← readTVarIO owned >>= maybe (unexpected "no owner was attached") pure
        void (startSupervised control workerPolicy (publishingWorker journal host owner) >>= started)
    )
  service ← readIORef kept >>= maybe (unexpected "no service was retained") pure
  observed ← observation service
  observedSlot observed `shouldBe` SlotFree
  observedMissing observed `shouldBe` []
  observedDisposal observed `shouldBe` DisposalCompleted
  entries ← readTVarIO journal
  filter (/= Constructed "alpha") entries `shouldBe` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A worker whose own release publishes its owner's certified facts.
--
-- Supervision runs that release while draining, which the runtime orders after
-- the host's quiescence and before the protected host's own exit: the facts are
-- therefore admitted — quiescence has already begun the retirement — and they
-- are all pending before the drain folds anything.
publishingWorker ∷ TVar [Note] → WindowHost → Owner → WorkerDefinition ()
publishingWorker journal host owner =
  workerDefinition
    "renderer"
    (\_ → allocResource (pure ()) (\() → publishFacts journal host owner allRetirementFacts))
    (\token () → atomically (awaitStopRequest token))

workerPolicy ∷ WorkerPolicy
workerPolicy = WorkerPolicy Job Required testComponent (\_ → pure Unrecognized)

testComponent ∷ Component
testComponent = unsafeComponent "test.attachments"

started ∷ SupervisedStart r → IO (SupervisedWorker r)
started = \case
  WorkerStarted worker → pure worker
  WorkerStartUnavailable _ _ → unexpected "the worker was unavailable"
  WorkerStartRejected → unexpected "the worker's start was rejected"

-- ---------------------------------------------------------------------------
-- Detaching

-- | Detaching runs the same retirement a close runs: the slot frees only once
-- every fact is recorded, and the window is never destroyed for it.
testDetachThenReattach ∷ Expectation
testDetachThenReattach = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  incarnations ← newIORef []
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (first', firstService) ← attachedOwner journal host window (ownerNamed "first")
    detachWindowGraphics host firstService `shouldReturn` DetachBegun
    turnsUntil host control "the first owner's retirement" (not <$> slotOccupied host window)
    -- The window stayed open: nothing was created and nothing destroyed.
    destroyCalls seam `shouldReturn` []
    createCalls seam `shouldReturn` 1
    atomically (windowGraphicsStatus host window) `shouldReturn` GraphicsAbsent
    (second', secondService) ← attachedOwner journal host window (ownerNamed "second")
    writeIORef incarnations [graphicsIncarnation firstService, graphicsIncarnation secondService]
    destroyCalls seam `shouldReturn` []
    createCalls seam `shouldReturn` 1
    void (closeHostWindow host window)
    atomically (writeTVar (ownerPlan second') (map Certify allRetirementFacts))
    turnsUntil host control "the second owner's destruction" (not . null <$> destroyCalls seam)
    atomically (readTVar (ownerSteps first')) >>= \steps →
      steps `shouldSatisfy` (> 0)
  readIORef incarnations `shouldReturn` [1, 2]

-- | The retired incarnation's acknowledgement is refused against the fresh
-- one, on the owner thread and through a published notice alike, and releases
-- nothing.
testStaleAcknowledgementRefused ∷ Expectation
testStaleAcknowledgementRefused = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  answered ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (first', firstService) ← attachedOwner journal host window (ownerNamed "first")
    stale ← heldAcknowledgement first'
    void (detachWindowGraphics host firstService)
    turnsUntil host control "the first owner's retirement" (not <$> slotOccupied host window)
    (second', secondService) ← attachedOwner journal host window (ownerNamed "second")
    -- The owner thread refuses it: the window now holds a later incarnation.
    refused ← certifyGraphicsFact host stale CpuUseRetired
    writeIORef answered (Just refused)
    -- And so does a notice published for it from another thread.
    publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
    void
      ( publishCompletion
          publisher
          (completionNotice (acknowledgedAttachment stale) stale SubmittedWorkEnded)
      )
    turnsExactly host control 3
    -- The replacement owes exactly what it owed: nothing was credited to it.
    observed ← observation secondService
    observedMissing observed `shouldBe` allRetirementFacts
    observedSlot observed `shouldBe` SlotAttached
    void (closeHostWindow host window)
    atomically (writeTVar (ownerPlan second') (map Certify allRetirementFacts))
    turnsUntil host control "the second owner's destruction" (not . null <$> destroyCalls seam)
  readIORef answered >>= \case
    Just Nothing → pure ()
    other → unexpected ("the stale acknowledgement was not refused: " <> show other)

-- | The exclusive slot is not free while its owner retires, however the
-- retirement began.
testSlotHeldWhileRetiring ∷ Expectation
testSlotHeldWhileRetiring = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  refused ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (owner, service) ← attachedOwner journal host window (ownerNamed "first")
    atomically (writeTVar (ownerPlan owner) (repeat Await))
    void (detachWindowGraphics host service)
    turnsExactly host control 2
    (_, second') ← attachScripted journal host window (ownerNamed "second")
    writeIORef refused (Just second')
    atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
    turnsUntil host control "the first owner's retirement" (not <$> slotOccupied host window)
  readIORef refused >>= \answer →
    refusalOfAnswer <$> answer `shouldBe` Just (Just "occupied")

-- | Detaching an owner that has already retired, or one that is already
-- retiring, answers a typed no-op and changes nothing.
testDetachNoOps ∷ Expectation
testDetachNoOps = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  answers ← newIORef []
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (owner, service) ← attachedOwner journal host window (ownerNamed "alpha")
    atomically (writeTVar (ownerPlan owner) (repeat Await))
    begun ← detachWindowGraphics host service
    again ← detachWindowGraphics host service
    atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
    turnsUntil host control "the owner's retirement" (not <$> slotOccupied host window)
    gone ← detachWindowGraphics host service
    writeIORef answers [begun, again, gone]
  readIORef answers `shouldReturn` [DetachBegun, DetachAlreadyRetiring, DetachAbsent]

-- | Repeated detaching and reattaching leaves the host holding one window, one
-- slot, and no history: each service keeps only its own answers.
testRepeatedCyclesBounded ∷ Expectation
testRepeatedCyclesBounded = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  observed ← newIORef []
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    services ← forM [1 .. 3 ∷ Int] $ \_ → do
      (_, service) ← attachedOwner journal host window (ownerNamed "cycle")
      void (detachWindowGraphics host service)
      turnsUntil host control "a cycle's retirement" (not <$> slotOccupied host window)
      -- Nothing accumulates: one window, no pending attachment, one command
      -- port beside the host's.
      atomically (hostPendingAttachments host) `shouldReturn` []
      bookkeeping ← hostBookkeeping host
      bookkeepingWindows bookkeeping `shouldBe` 1
      bookkeepingPorts bookkeeping `shouldBe` 2
      pure service
    seen ← traverse observation services
    writeIORef observed (zip (map graphicsIncarnation services) (map observedSlot seen))
    -- Nothing was created or destroyed natively across the whole cycle.
    createCalls seam `shouldReturn` 1
    destroyCalls seam `shouldReturn` []
    void (closeHostWindow host window)
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
  readIORef observed `shouldReturn` [(1, SlotFree), (2, SlotFree), (3, SlotFree)]

-- ---------------------------------------------------------------------------
-- Independent progress

-- | One window's pending retirement never blocks another's commands, its own
-- retirement, or its destruction.
testIndependentWindows ∷ Expectation
testIndependentWindows = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  protectedRun seam (settings [windowNamed "alpha", windowNamed "beta"]) (\_ → pure ()) $ \host control → do
    (alpha, beta) ← twoWindows host
    (alphaOwner, alphaService) ← attachedOwner journal host alpha (ownerNamed "alpha")
    (betaOwner, betaService) ← attachedOwner journal host beta (ownerNamed "beta")
    -- Alpha's owner never makes progress of its own.
    atomically (writeTVar (ownerPlan alphaOwner) [])
    void (closeHostWindow host alpha)
    -- Beta keeps executing commands while alpha's retirement is pending.
    client ← atomically (hostWindowClient host beta) >>= maybe (unexpected "beta has no client") pure
    ticket ←
      submitWindowCommand (clientCommandPort client) [] (observeWindowCommand beta) >>= \case
        SubmitAccepted ticket → pure ticket
        other → unexpected ("beta's port refused an observation: " <> show other)
    turnsUntil host control "beta's observation" (hasSettled <$> atomically (pollCompletion ticket))
    -- And beta keeps rendering: its owner's slot still admits new use, turn
    -- after turn, while alpha's owner is pending and its window is retained.
    renders ← forM [1 .. 3 ∷ Int] $ \_ → do
      admitted ← renderThrough journal host "beta" betaService
      turnsExactly host control 1
      pure admitted
    renders `shouldBe` [True, True, True]
    -- Alpha admits none of it, and none of beta's work advanced alpha by a
    -- single fact.
    renderThrough journal host "alpha" alphaService `shouldReturn` False
    alphaSeen ← observation alphaService
    observedSlot alphaSeen `shouldBe` SlotRetiring
    observedMissing alphaSeen `shouldBe` allRetirementFacts
    -- Beta's own close, retirement, and destruction then run to the end while
    -- alpha is still pending, and beta admits no use once it has closed.
    void (closeHostWindow host beta)
    renderThrough journal host "beta" betaService `shouldReturn` False
    turnsUntil host control "beta's destruction" (elem 2 <$> destroyCalls seam)
    destroyCalls seam `shouldReturn` [2]
    atomically (windowGraphicsStatus host alpha) >>= \case
      GraphicsPresent seen → observedSlot seen `shouldBe` SlotRetiring
      other → unexpected ("alpha's slot was not retiring: " <> show other)
    -- Independent evidence finishes alpha, and its window follows.
    _ ← forkIO (publishFacts journal host alphaOwner allRetirementFacts)
    turnsUntil host control "alpha's destruction" (elem 1 <$> destroyCalls seam)
    void (atomically (readTVar (ownerSteps betaOwner)))
  entries ← readTVarIO journal
  -- Beta rendered exactly while it was attached, and its whole retirement and
  -- destruction happened before alpha's.
  [name | Rendered name ← entries] `shouldBe` ["beta", "beta", "beta"]
  takeWhile (/= WindowGone 1) entries `shouldSatisfy` (WindowGone 2 `elem`)

-- | Whether a ticket has settled at all; which way it settled is the command
-- suites' business, not this one's.
hasSettled ∷ Maybe a → Bool
hasSettled = \case
  Just _ → True
  Nothing → False

-- | A stalled owner retains its own window and nothing else: its neighbour's
-- close, retirement, and destruction all complete, and the stalled one
-- finishes only when independent evidence arrives.
testStalledNeighbour ∷ Expectation
testStalledNeighbour = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  protectedRun seam (settings [windowNamed "alpha", windowNamed "beta"]) (\_ → pure ()) $ \host control → do
    (alpha, beta) ← twoWindows host
    (alphaOwner, _) ← attachedOwner journal host alpha (ownerNamed "alpha") {scriptPlan = [Stall]}
    (_, _) ← attachedOwner journal host beta (ownerNamed "beta")
    void (closeHostWindow host alpha)
    void (closeHostWindow host beta)
    turnsUntil host control "beta's destruction" (elem 2 <$> destroyCalls seam)
    destroyCalls seam `shouldReturn` [2]
    -- The stalled owner was offered its one opportunity and withdrew; it is
    -- never replayed.
    steps ← atomically (readTVar (ownerSteps alphaOwner))
    turnsExactly host control 3
    atomically (readTVar (ownerSteps alphaOwner)) `shouldReturn` steps
    _ ← forkIO (publishFacts journal host alphaOwner allRetirementFacts)
    turnsUntil host control "alpha's destruction" (elem 1 <$> destroyCalls seam)
  entries ← readTVarIO journal
  takeWhile (/= WindowGone 1) entries `shouldSatisfy` (WindowGone 2 `elem`)

-- | Opportunities are bounded per turn and rotate, so a pending retirement
-- never starves another.
--
-- The budget falling short of the pending attachments is not itself work: it
-- keeps the next turn immediate only while some attachment is still owed a
-- first opportunity. Once the rotation has reached every one of them and each
-- is waiting, the demand stops asking for another turn at once — which is what
-- lets more waiting attachments than the budget settle into ordinary idle waits
-- rather than an unbounded stream of polling turns.
testRotatingBudget ∷ Expectation
testRotatingBudget = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  counts ← newIORef []
  let config = (settings [windowNamed "alpha", windowNamed "beta", windowNamed "gamma"]) {hostRetirementBudget = 1}
  protectedRun seam config (\_ → pure ()) $ \host control → do
    windows ← atomically (hostWindowIdentities host)
    owners ← forM (zip windows ["alpha", "beta", "gamma"]) $ \(window, name) → do
      (owner, _) ← attachedOwner journal host window (ownerNamed name) {scriptPlan = repeat Await}
      void (closeHostWindow host window)
      pure owner
    -- Two turns, two opportunities, to a different owner each time: the third
    -- owner has still had none, which is what keeps the next turn immediate
    -- however short the budget fell.
    turnsExactly host control 2
    partway ← atomically (hostRetirementDemand host)
    retirementImmediate partway `shouldBe` True
    -- One more turn reaches the third. Now every owner has been offered exactly
    -- one opportunity and every one of them is waiting, so the budget the round
    -- could not spend on all three is no longer a reason to come back at once.
    turnsExactly host control 1
    offered ← traverse (atomically . readTVar . ownerSteps) owners
    writeIORef counts offered
    demand ← atomically (hostRetirementDemand host)
    retirementPending demand `shouldBe` 3
    retirementImmediate demand `shouldBe` False
    forM_ owners $ \owner → atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
    turnsUntil host control "every destruction" ((== 3) . length <$> destroyCalls seam)
  readIORef counts `shouldReturn` [1, 1, 1]

-- | An owner that declares a blocking step is refused the opportunity without
-- its step being run, and the refusal is reported in the demand the turn
-- publishes.
testBlockingOwnerRefused ∷ Expectation
testBlockingOwnerRefused = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  reported ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (owner, _) ←
      attachedOwner journal host window (ownerNamed "blocking") {scriptCompletion = BlockingCompletion}
    void (closeHostWindow host window)
    -- One turn is enough: the refusal withdraws the path, so a later round has
    -- nothing left to refuse and the demand reports it stalled instead.
    turnsExactly host control 1
    demand ← atomically (hostRetirementDemand host)
    writeIORef reported (Just demand)
    turnsExactly host control 3
    -- The step was never entered, so it could not have blocked anything.
    atomically (readTVar (ownerSteps owner)) `shouldReturn` 0
    destroyCalls seam `shouldReturn` []
    _ ← forkIO (publishFacts journal host owner allRetirementFacts)
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
  readIORef reported >>= \case
    Just demand → do
      retirementRefused demand `shouldSatisfy` (> 0)
      retirementStalled demand `shouldBe` 1
    Nothing → unexpected "the turn reported no retirement demand"

-- | A completion published from another thread is what revives a withdrawn
-- path while the application runs, and the wake it registers is what ends the
-- owner's idle wait so the next bounded round folds it.
--
-- The seam's finite wait returns only once an empty event has been posted, so
-- an idle turn here really parks: without that wake nothing would fold the
-- notice, and without the notice nothing could retire the stalled owner.
testCompletionWakesTurn ∷ Expectation
testCompletionWakesTurn = do
  journal ← newTVarIO []
  seam ← blockingSeam journal
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (owner, service) ← attachedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Stall]}
    void (closeHostWindow host window)
    -- The owner withdrew its own path on its one opportunity, so no turn can
    -- advance it and the loop goes idle. The facts are published only once the
    -- owner has really entered that wait, so the wake is what ends it rather
    -- than a fold that happened to come first.
    _ ←
      forkIO $ do
        atomically (hostActivity host >>= check . activityWaiting)
        publishFacts journal host owner allRetirementFacts
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
    observed ← observation service
    observedSlot observed `shouldBe` SlotFree
    observedMissing observed `shouldBe` []
    -- One opportunity, which stalled and established nothing; the retirement is
    -- entirely the published evidence's.
    atomically (readTVar (ownerSteps owner)) `shouldReturn` 1
  entries ← readTVarIO journal
  filter (/= Constructed "alpha") entries `shouldBe` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | An attachment the budget never reached is deferred work, however the one it
-- did reach answered.
--
-- With a budget of one and a first owner that withdraws its path, the round
-- serves nobody: counting deferred work by subtracting the round's own size
-- from what is left would report none, and the next turn could wait before ever
-- offering the second owner or learning its deadline.
testUnservedCountedAsDeferred ∷ Expectation
testUnservedCountedAsDeferred = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  reported ← newIORef Nothing
  offered ← newIORef []
  let config = (settings [windowNamed "alpha", windowNamed "beta"]) {hostRetirementBudget = 1}
  protectedRun seam config (\_ → pure ()) $ \host control → do
    (alpha, beta) ← twoWindows host
    (alphaOwner, _) ← attachedOwner journal host alpha (ownerNamed "alpha") {scriptPlan = [Stall]}
    (betaOwner, _) ← attachedOwner journal host beta (ownerNamed "beta") {scriptPlan = repeat Await}
    void (closeHostWindow host alpha)
    void (closeHostWindow host beta)
    -- One turn, one opportunity, and it went to the owner that then withdrew.
    turnsExactly host control 1
    demand ← atomically (hostRetirementDemand host)
    writeIORef reported (Just demand)
    counts ← traverse (atomically . readTVar . ownerSteps) [alphaOwner, betaOwner]
    writeIORef offered counts
    forM_ [alphaOwner, betaOwner] $ \owner →
      atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
    _ ← forkIO (publishFacts journal host alphaOwner allRetirementFacts)
    turnsUntil host control "both destructions" ((== 2) . length <$> destroyCalls seam)
  readIORef offered `shouldReturn` [1, 0]
  readIORef reported >>= \case
    Just demand → do
      retirementPending demand `shouldBe` 2
      retirementStalled demand `shouldBe` 1
      -- The unserved owner is why the next turn must not wait.
      retirementImmediate demand `shouldBe` True
    Nothing → unexpected "the turn reported no retirement demand"

-- ---------------------------------------------------------------------------
-- Reviving a withdrawn path

-- | What one revival example observed, recorded while the application ran and
-- asserted once it has exited.
--
-- The assertions are deliberately not made inside the owner's own action. One
-- that fails there leaves an attachment pending with no progress path, which the
-- protected exit would then wait on for as long as the process lives: an example
-- that is wrong about revival must fail, not hang.
data Revival = Revival
  { revivalWithdrawn ∷ !Int
    -- ^ Opportunities offered before any evidence arrived: the one that stalled.
  , revivalAnswers ∷ ![Maybe FactAnswer]
    -- ^ What the transport answered for the new fact and then for a duplicate
    -- of it. A notice is answered when it is folded rather than when it is
    -- offered, so the queued transport records 'Nothing' for both.
  , revivalOffered ∷ !Int
    -- ^ Opportunities offered once the new evidence had arrived.
  , revivalDestroyed ∷ ![Int]
    -- ^ The windows destroyed by then, which must be none: disposal still waits
    -- for every fact the attachment owes.
  , revivalSlot ∷ !SlotState
  , revivalMissing ∷ ![RetirementFact]
  , revivalAfterDuplicate ∷ !Int
    -- ^ Opportunities offered after a duplicate of that same fact, which
    -- establishes nothing and must therefore change nothing.
  }
  deriving (Eq, Show)

-- | How an example delivers one certified fact to the owner thread.
--
-- The two transports the contract names are the direct owner-thread operation
-- and a notice another thread publishes. Answering with the model's own answer
-- is what lets the direct transport assert what it established.
type Deliver = WindowHost → Acknowledgement → RetirementFact → IO (Maybe FactAnswer)

-- | What revives a withdrawn path is the evidence, never the transport that
-- carried it: a fact the model did not already hold earns exactly one further
-- opportunity, and a duplicate of it earns none.
--
-- Both transports are asserted through this one shape, at the same points and
-- against the same expectations, so they are compared rather than merely both
-- exercised. Every assertion is made while the attachment still owes facts:
-- completing the retirement prunes its registration, which would hide the
-- difference between a revived path and a forgotten one.
revivalThrough ∷ Deliver → [Maybe FactAnswer] → Expectation
revivalThrough deliver answered = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  seen ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (owner, service) ← attachedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Stall]}
    acknowledgement ← heldAcknowledgement owner
    void (closeHostWindow host window)
    -- One opportunity, which stalled and withdrew the path. Every turn after it
    -- offers nothing at all, so what the evidence below changes is unambiguous.
    turnsExactly host control 4
    withdrawn ← atomically (readTVar (ownerSteps owner))
    recorded ← deliver host acknowledgement CpuUseRetired
    -- Exactly one further opportunity, which stalls and withdraws again: new
    -- evidence restores eligibility, it does not replay the step indefinitely.
    turnsExactly host control 4
    offered ← atomically (readTVar (ownerSteps owner))
    destroyed ← destroyCalls seam
    observed ← observation service
    -- The same fact again establishes nothing, so it revives nothing. A
    -- completed round is what proves that, rather than the absence of one.
    duplicate ← deliver host acknowledgement CpuUseRetired
    turnsExactly host control 4
    afterDuplicate ← atomically (readTVar (ownerSteps owner))
    writeIORef seen . Just $
      Revival
        { revivalWithdrawn = withdrawn
        , revivalAnswers = [recorded, duplicate]
        , revivalOffered = offered
        , revivalDestroyed = destroyed
        , revivalSlot = observedSlot observed
        , revivalMissing = observedMissing observed
        , revivalAfterDuplicate = afterDuplicate
        }
    -- The facts it still owes then retire it, and its window follows. This runs
    -- whatever was observed above, so the application always exits.
    forM_ (stillOwedAfter CpuUseRetired) (void . deliver host acknowledgement)
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
  readIORef seen
    `shouldReturn` Just
      Revival
        { revivalWithdrawn = 1
        , revivalAnswers = answered
        , revivalOffered = 2
        , revivalDestroyed = []
        , revivalSlot = SlotRetiring
        , revivalMissing = stillOwedAfter CpuUseRetired
        , revivalAfterDuplicate = 2
        }

-- | The direct owner-thread transport. Before this, an owner-thread integration
-- — the ordinary shape for GLFW rendering — had to queue a fact to itself
-- through the cross-thread publisher to obtain progress its own certification
-- had already established.
testDirectCertificationRevives ∷ Expectation
testDirectCertificationRevives =
  revivalThrough
    certifyOne
    [Just (FactRecorded (stillOwedAfter CpuUseRetired)), Just FactAlreadyRecorded]

-- | The queued transport, which behaved this way already, asserted identically.
testNoticeRevives ∷ Expectation
testNoticeRevives = revivalThrough publishOne [Nothing, Nothing]

-- | A fact certified on the owner thread restores the registration for the
-- protected exit's drain too, not only for another running owner turn.
--
-- The two paths filter withdrawn registrations independently, so one of them
-- honouring the revival proves nothing about the other. Here the path is
-- withdrawn while the application runs, the evidence is certified on the owner
-- thread with three facts still outstanding, and the application then exits: the
-- drain must offer the restored registration its opportunities before the
-- window, the session, and every parent are released.
testDirectCertificationRevivesForTheDrain ∷ Expectation
testDirectCertificationRevivesForTheDrain = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  observed ← newIORef Nothing
  owner ← protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (owner, _) ←
      attachedOwner
        journal
        host
        window
        (ownerNamed "alpha") {scriptPlan = Stall : map Certify (stillOwedAfter CpuUseRetired)}
    acknowledgement ← heldAcknowledgement owner
    void (closeHostWindow host window)
    -- The one running turn stalled and withdrew the path, and nothing has been
    -- destroyed.
    turnsExactly host control 4
    withdrawn ← atomically (readTVar (ownerSteps owner))
    recorded ← certifyGraphicsFact host acknowledgement CpuUseRetired
    destroyed ← destroyCalls seam
    writeIORef observed (Just (withdrawn, recorded, destroyed))
    pure owner
  readIORef observed
    `shouldReturn` Just (1, Just (FactRecorded (stillOwedAfter CpuUseRetired)), [])
  -- The drain offered the restored registration one opportunity per outstanding
  -- fact, so the owner certified each of them and the window and the session
  -- were released. Without the revival it would have offered none and waited on
  -- an attachment whose evidence the model already held.
  atomically (readTVar (ownerSteps owner)) `shouldReturn` 4
  readTVarIO journal
    `shouldReturn` ( [Constructed "alpha"]
                       <> map (Certified "alpha") (stillOwedAfter CpuUseRetired)
                       <> [WindowGone 1, SessionEnded]
                   )

-- | A report the model refuses establishes nothing and therefore revives
-- nothing, on either transport.
--
-- The refusal names a replaced incarnation, and the incarnation that replaced it
-- is the one holding a withdrawn path: a refusal that revived the replacement
-- would make a withdrawn step run again on evidence about an attachment that is
-- gone. Its own evidence then revives it, so the path was revivable throughout
-- and the refusal is why nothing happened.
testRefusedReportRevivesNothing ∷ Expectation
testRefusedReportRevivesNothing = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  seen ← newIORef Nothing
  protectedRun seam (settings [windowNamed "alpha"]) (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (first', firstService) ← attachedOwner journal host window (ownerNamed "first")
    stale ← heldAcknowledgement first'
    void (detachWindowGraphics host firstService)
    turnsUntil host control "the first owner's retirement" (not <$> slotOccupied host window)
    (second', secondService) ← attachedOwner journal host window (ownerNamed "second") {scriptPlan = [Stall]}
    fresh ← heldAcknowledgement second'
    void (closeHostWindow host window)
    turnsExactly host control 4
    withdrawn ← atomically (readTVar (ownerSteps second'))
    -- The retired incarnation's acknowledgement, on the owner thread and then as
    -- a notice. Both are refused, and a refusal establishes nothing.
    refused ← certifyGraphicsFact host stale CpuUseRetired
    void (publishOne host stale SubmittedWorkEnded)
    turnsExactly host control 4
    afterRefusal ← atomically (readTVar (ownerSteps second'))
    destroyed ← destroyCalls seam
    observed ← observation secondService
    void (certifyGraphicsFact host fresh CpuUseRetired)
    turnsExactly host control 4
    afterEvidence ← atomically (readTVar (ownerSteps second'))
    writeIORef seen . Just $
      Unrevived
        { unrevivedWithdrawn = withdrawn
        , unrevivedAnswer = refused
        , unrevivedOffered = afterRefusal
        , unrevivedDestroyed = destroyed
        , unrevivedSlot = observedSlot observed
        , unrevivedMissing = observedMissing observed
        , unrevivedAfterEvidence = afterEvidence
        }
    forM_ (stillOwedAfter CpuUseRetired) (void . certifyGraphicsFact host fresh)
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
  readIORef seen
    `shouldReturn` Just
      Unrevived
        { unrevivedWithdrawn = 1
        , unrevivedAnswer = Nothing
        , unrevivedOffered = 1
        , unrevivedDestroyed = []
        , unrevivedSlot = SlotRetiring
        , unrevivedMissing = allRetirementFacts
        , unrevivedAfterEvidence = 2
        }

-- | What the refusal example observed, recorded while the application ran and
-- asserted once it has exited, for the same reason 'Revival' is.
data Unrevived = Unrevived
  { unrevivedWithdrawn ∷ !Int
    -- ^ Opportunities offered before the refused reports: the one that stalled.
  , unrevivedAnswer ∷ !(Maybe FactAnswer)
    -- ^ What the owner thread answered the refused report. A refusal records
    -- nothing and answers nothing.
  , unrevivedOffered ∷ !Int
    -- ^ Opportunities offered after both refused reports, which must still be
    -- only the one the stall withdrew.
  , unrevivedDestroyed ∷ ![Int]
  , unrevivedSlot ∷ !SlotState
  , unrevivedMissing ∷ ![RetirementFact]
    -- ^ Nothing may be credited to the replacement either.
  , unrevivedAfterEvidence ∷ !Int
    -- ^ Opportunities offered once the replacement's own new evidence arrived,
    -- which is what proves the path was revivable throughout and the refusal is
    -- why nothing happened.
  }
  deriving (Eq, Show)

-- | Every fact an attachment still owes once this one has been recorded.
stillOwedAfter ∷ RetirementFact → [RetirementFact]
stillOwedAfter fact = filter (/= fact) allRetirementFacts

-- | Deliver one fact by certifying it directly on the owner thread.
certifyOne ∷ Deliver
certifyOne = certifyGraphicsFact

-- | Deliver one fact as a notice published from a thread that is not the owner,
-- without journalling it.
--
-- 'publishFacts' notes each fact it publishes, which is what an example
-- asserting the order of a whole retirement wants. An example offering evidence
-- that establishes nothing wants the opposite: a duplicate and a refusal change
-- no attachment, so noting them would claim a certification that never happened.
publishOne ∷ Deliver
publishOne host acknowledgement fact = do
  publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
  let notice = completionNotice (acknowledgedAttachment acknowledgement) acknowledgement fact
  publishCompletion publisher notice >>= \case
    CompletionOffered NoticeRejectedFull → unexpected "the completion inbox refused a notice"
    CompletionClosed → unexpected "the boundary had already closed publication"
    _ → pure Nothing

-- ---------------------------------------------------------------------------
-- The schedule

-- | A retirement is never delayed by the idle bound, from its very first
-- opportunity onwards.
--
-- The turn after a detach polls, because that retirement has never been offered
-- one; the turn after an owner named an instant waits only until that instant;
-- and the turn after a round advanced polls again.
testRetirementSchedule ∷ Expectation
testRetirementSchedule = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  (clock, _) ← scriptedClock (concatMap (\turn → [turn, turn]) (map millis [0 .. 11]))
  pacings ← newTVarIO []
  let config = (settings [windowNamed "alpha"]) {hostIdleWait = 0.25, hostClock = clock}
  protectedRun seam config (\_ → pure ()) $ \host control → do
    window ← onlyWindow host
    (owner, service) ←
      attachedOwner
        journal
        host
        window
        (ownerNamed "alpha") {scriptPlan = AwaitUntil (at (millis 10)) : map Certify allRetirementFacts}
    detachWindowGraphics host service `shouldReturn` DetachBegun
    void
      ( runScheduledOwnerLoop host control $
          (defaultScheduledHooks quietLogger (\_ → pure (FinishWith ())))
            { scheduledUpdate = \turn → do
                atomically (modifyTVar' pacings (<> [scheduledPacing turn]))
                pure (if turnNumber (scheduledTurn turn) >= 4 then FinishWith () else ContinueWith NoUpdateDemand)
            }
      )
    atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
    void (closeHostWindow host window)
    turnsUntil host control "the window's destruction" (not . null <$> destroyCalls seam)
  observed ← readTVarIO pacings
  case observed of
    first' : second' : rest → do
      -- The detach began a retirement no turn had offered an opportunity to, so
      -- the first turn polls rather than waiting its configured bound.
      first' `shouldBe` PolledForWork
      -- That turn's own opportunity named an instant nearer than the bound, so
      -- the next wait is the time remaining to it.
      second' `shouldSatisfy` \case
        WaitedForDeadline _ → True
        _ → False
      -- Once a round advanced, the turn after it polls again.
      rest `shouldSatisfy` all (== PolledForWork)
    _ → unexpected ("the scheduled loop ran too few turns: " <> show observed)

-- ---------------------------------------------------------------------------
-- Waiting beyond the budget

-- | Run a fixed number of scheduled turns, collecting the pacing each one
-- chose, and run @between@ on the owner thread at the end of every turn.
--
-- The pacing is recorded before @between@ runs, so a turn's own choice is never
-- confused with what the example arranged after it: a wake arranged at the end
-- of turn @n@ is a question about turn @n + 1@.
pacingsOver ∷ WindowHost → RuntimeControl → Natural → (Natural → IO ()) → IO [TurnPacing]
pacingsOver host control count between = do
  pacings ← newTVarIO []
  void
    ( runScheduledOwnerLoop host control $
        (defaultScheduledHooks quietLogger (\_ → pure (FinishWith ())))
          { scheduledUpdate = \turn → do
              let number = turnNumber (scheduledTurn turn)
              atomically (modifyTVar' pacings (<> [scheduledPacing turn]))
              between number
              pure (if number >= count then FinishWith () else ContinueWith NoUpdateDemand)
          }
    )
  readTVarIO pacings

-- | Whether a turn waited its configured fallback bound, which is what an owner
-- with nothing else to do does.
waitedTheBound ∷ TurnPacing → Bool
waitedTheBound = \case
  WaitedForFallback _ → True
  _ → False

-- | One detached, scripted owner per window, in the order given.
detachedOwners ∷ TVar [Note] → WindowHost → [(WindowId, Text, [Step])] → IO [Owner]
detachedOwners journal host scripted =
  forM scripted $ \(window, name, plan) → do
    (owner, service) ← attachedOwner journal host window (ownerNamed name) {scriptPlan = plan}
    detachWindowGraphics host service `shouldReturn` DetachBegun
    pure owner

-- | Let every scripted owner certify what it owes on its next opportunity,
-- close every window, and run ordinary turns until each has been destroyed.
--
-- The assertions an example makes about pacing are made after this has run and
-- the application has exited: one made while an attachment is still pending
-- would leave the protected exit waiting for a retirement that can no longer
-- happen, and an example that is wrong must fail rather than hang.
finishOwners ∷ WindowHost → RuntimeControl → Seam → [WindowId] → [Owner] → IO ()
finishOwners host control seam windows owners = do
  forM_ owners $ \owner → atomically (writeTVar (ownerPlan owner) (map Certify allRetirementFacts))
  forM_ windows $ \window → void (closeHostWindow host window)
  turnsUntil
    host
    control
    "every destruction"
    ((== length windows) . length <$> destroyCalls seam)

-- | A clock held at one instant, for an example whose pacing turns on what the
-- owners answered rather than on time passing.
heldClock ∷ IO MonotonicSource
heldClock = fst <$> scriptedClock (replicate 16 0)

-- | More waiting owners than the budget is an idle host, not a polling one.
--
-- Two owners, a budget of one, and no deadline between them: the first two
-- turns poll because an owner is still owed its first opportunity, and once the
-- rotation has reached both, the turns wait their configured bound. Counting
-- every unserved owner as work instead makes this an unbounded stream of
-- polling turns, which is the defect.
testWaitingOwnersBeyondBudgetWait ∷ Expectation
testWaitingOwnersBeyondBudgetWait = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  clock ← heldClock
  observed ← newIORef []
  offered ← newIORef []
  let config =
        (settings [windowNamed "alpha", windowNamed "beta"])
          {hostRetirementBudget = 1, hostClock = clock}
  protectedRun seam config (\_ → pure ()) $ \host control → do
    (alpha, beta) ← twoWindows host
    owners ←
      detachedOwners journal host [(alpha, "alpha", repeat Await), (beta, "beta", repeat Await)]
    pacingsOver host control 4 (\_ → pure ()) >>= writeIORef observed
    traverse (atomically . readTVar . ownerSteps) owners >>= writeIORef offered
    finishOwners host control seam [alpha, beta] owners
  -- Rotation is unchanged: four turns of one opportunity each reached both
  -- owners twice.
  readIORef offered `shouldReturn` [2, 2]
  readIORef observed >>= \case
    [firstTurn, secondTurn, thirdTurn, fourthTurn] → do
      firstTurn `shouldBe` PolledForWork
      secondTurn `shouldBe` PolledForWork
      thirdTurn `shouldSatisfy` waitedTheBound
      fourthTurn `shouldSatisfy` waitedTheBound
    other → unexpected ("the scheduled loop paced too few turns: " <> show other)

-- | A deadline an earlier round learned still bounds a later round's wait, is
-- still served when it comes due while its owner is unserved, and is cleared
-- when that owner next names none.
--
-- Three owners, a budget of one, and three different instants. The round that
-- learns the nearest of them is not the round the loop waits after, so a demand
-- carrying only the instants its own round named would wait straight past it.
testRetainedDeadlinesBoundLaterWaits ∷ Expectation
testRetainedDeadlinesBoundLaterWaits = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  -- Held at the origin while the three instants are learned, then moved past
  -- the nearest of them. Each turn samples twice: once to choose its pacing,
  -- once to give the update.
  (clock, _) ←
    scriptedClock (concatMap (\turn → [turn, turn]) [0, 0, 0, 0, millis 60, millis 60, millis 60])
  observed ← newIORef []
  let config =
        (settings [windowNamed "alpha", windowNamed "beta", windowNamed "gamma"])
          {hostRetirementBudget = 1, hostClock = clock}
  protectedRun seam config (\_ → pure ()) $ \host control → do
    (alpha, beta, gamma) ← threeWindows host
    owners ←
      detachedOwners
        journal
        host
        [ (alpha, "alpha", AwaitUntil (at (millis 80)) : repeat Await)
        , (beta, "beta", AwaitUntil (at (millis 40)) : repeat Await)
        , (gamma, "gamma", AwaitUntil (at (millis 120)) : repeat Await)
        ]
    pacingsOver host control 7 (\_ → pure ()) >>= writeIORef observed
    finishOwners host control seam [alpha, beta, gamma] owners
  readIORef observed >>= \case
    [firstTurn, secondTurn, thirdTurn, fourthTurn, fifthTurn, sixthTurn, seventhTurn] → do
      -- One first opportunity per turn while any owner is still owed one.
      [firstTurn, secondTurn, thirdTurn] `shouldSatisfy` all (== PolledForWork)
      -- Beta named the nearest instant on the second turn and the third turn
      -- served gamma instead; the wait is still beta's.
      fourthTurn `shouldBe` WaitedForDeadline (durationOf (millis 40))
      -- That instant came due while beta was unserved, so the turn polls for it
      -- however little else the last round left owed.
      fifthTurn `shouldBe` PolledForDeadline
      -- Beta's second opportunity named no instant, which clears the one it
      -- named before rather than leaving it standing; gamma's is now nearest.
      sixthTurn `shouldBe` WaitedForDeadline (durationOf (millis 60))
      -- And once gamma's is cleared too, the owner is simply idle.
      seventhTurn `shouldSatisfy` waitedTheBound
    other → unexpected ("the scheduled loop paced too few turns: " <> show other)

-- | An owner whose latest opportunity advanced keeps the next turn immediate
-- while later rounds leave it unserved.
--
-- Alpha advances on the first turn and is not reached again until the fourth.
-- The second and third turns are immediate because another owner is still owed
-- a first opportunity; the fourth is immediate because of alpha alone.
testAdvancedOwnerStaysImmediate ∷ Expectation
testAdvancedOwnerStaysImmediate = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  clock ← heldClock
  observed ← newIORef []
  let config =
        (settings [windowNamed "alpha", windowNamed "beta", windowNamed "gamma"])
          {hostRetirementBudget = 1, hostClock = clock}
  protectedRun seam config (\_ → pure ()) $ \host control → do
    (alpha, beta, gamma) ← threeWindows host
    fact ← case allRetirementFacts of
      known : _ → pure known
      [] → unexpected "the attachment model declares no retirement facts"
    owners ←
      detachedOwners
        journal
        host
        [ (alpha, "alpha", Certify fact : repeat Await)
        , (beta, "beta", repeat Await)
        , (gamma, "gamma", repeat Await)
        ]
    pacingsOver host control 5 (\_ → pure ()) >>= writeIORef observed
    finishOwners host control seam [alpha, beta, gamma] owners
  readIORef observed >>= \case
    [firstTurn, secondTurn, thirdTurn, fourthTurn, fifthTurn] → do
      [firstTurn, secondTurn, thirdTurn, fourthTurn] `shouldSatisfy` all (== PolledForWork)
      -- Alpha's fourth-turn opportunity named no instant either, so by the
      -- fifth every owner has been inspected and is waiting.
      fifthTurn `shouldSatisfy` waitedTheBound
    other → unexpected ("the scheduled loop paced too few turns: " <> show other)

-- | A stalled owner never starves its unserved neighbour, and never keeps the
-- turns polling once that neighbour has been inspected.
--
-- The one opportunity the budget allows goes to the owner that withdraws its
-- path, so the round serves nobody at all: the next turn must still poll,
-- because the neighbour has had none. Once it has had one and is waiting, the
-- stalled owner — which only independent evidence revives — is no reason to
-- keep polling, and its one step is never replayed.
testStalledNeighbourThenWaits ∷ Expectation
testStalledNeighbourThenWaits = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  clock ← heldClock
  observed ← newIORef []
  offered ← newIORef []
  let config =
        (settings [windowNamed "alpha", windowNamed "beta"])
          {hostRetirementBudget = 1, hostClock = clock}
  protectedRun seam config (\_ → pure ()) $ \host control → do
    (alpha, beta) ← twoWindows host
    owners ← detachedOwners journal host [(alpha, "alpha", [Stall]), (beta, "beta", repeat Await)]
    pacingsOver host control 4 (\_ → pure ()) >>= writeIORef observed
    traverse (atomically . readTVar . ownerSteps) owners >>= writeIORef offered
    -- Alpha withdrew its own path, so only independent evidence can finish it.
    forM_ (take 1 owners) $ \owner →
      void (forkIO (publishFacts journal host owner allRetirementFacts))
    finishOwners host control seam [alpha, beta] owners
  -- Alpha stalled on its one opportunity and was never offered another; beta
  -- was offered one on every turn the budget could no longer spend on alpha.
  readIORef offered `shouldReturn` [1, 3]
  readIORef observed >>= \case
    [firstTurn, secondTurn, thirdTurn, fourthTurn] → do
      firstTurn `shouldBe` PolledForWork
      secondTurn `shouldBe` PolledForWork
      thirdTurn `shouldSatisfy` waitedTheBound
      fourthTurn `shouldSatisfy` waitedTheBound
    other → unexpected ("the scheduled loop paced too few turns: " <> show other)

-- | A retirement begun between two waiting turns makes the next turn immediate,
-- exactly as the first ones did.
testNewRetirementEndsTheWaiting ∷ Expectation
testNewRetirementEndsTheWaiting = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  clock ← heldClock
  observed ← newIORef []
  let config =
        (settings [windowNamed "alpha", windowNamed "beta", windowNamed "gamma"])
          {hostRetirementBudget = 1, hostClock = clock}
  protectedRun seam config (\_ → pure ()) $ \host control → do
    (alpha, beta, gamma) ← threeWindows host
    waiting ←
      detachedOwners journal host [(alpha, "alpha", repeat Await), (beta, "beta", repeat Await)]
    late ← newIORef []
    pacings ←
      pacingsOver host control 4 $ \number →
        when (number == 3) $
          detachedOwners journal host [(gamma, "gamma", repeat Await)] >>= writeIORef late
    writeIORef observed pacings
    arrived ← readIORef late
    finishOwners host control seam [alpha, beta, gamma] (waiting <> arrived)
  readIORef observed >>= \case
    [firstTurn, secondTurn, thirdTurn, fourthTurn] → do
      firstTurn `shouldBe` PolledForWork
      secondTurn `shouldBe` PolledForWork
      -- Both owners inspected and waiting, so the third turn is idle.
      thirdTurn `shouldSatisfy` waitedTheBound
      -- A third retirement began at the end of it, and no round has offered it
      -- anything.
      fourthTurn `shouldBe` PolledForWork
    other → unexpected ("the scheduled loop paced too few turns: " <> show other)

-- | Evidence that arrives between two waiting turns invalidates that owner's
-- waiting assessment, so a turn is immediate again once a round has left it
-- unserved.
--
-- The notice ends the wait it is published into, but the turn it wakes is still
-- recorded as the wait that turn chose, and that turn's own round is what folds
-- the evidence. The owner it revived is the one the rotation does not reach, so
-- the turn after it polls rather than waiting on an assessment the new evidence
-- has already outdated.
testNewEvidenceEndsTheWaiting ∷ Expectation
testNewEvidenceEndsTheWaiting = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  clock ← heldClock
  observed ← newIORef []
  let config =
        (settings [windowNamed "alpha", windowNamed "beta"])
          {hostRetirementBudget = 1, hostClock = clock}
  protectedRun seam config (\_ → pure ()) $ \host control → do
    (alpha, beta) ← twoWindows host
    owners ←
      detachedOwners journal host [(alpha, "alpha", repeat Await), (beta, "beta", repeat Await)]
    alphaOwner ← case owners of
      held : _ → pure held
      [] → unexpected "no owner was attached"
    fact ← case allRetirementFacts of
      known : _ → pure known
      [] → unexpected "the attachment model declares no retirement facts"
    pacings ←
      pacingsOver host control 6 $ \number →
        when (number == 3) (publishFacts journal host alphaOwner [fact])
    writeIORef observed pacings
    finishOwners host control seam [alpha, beta] owners
  readIORef observed >>= \case
    [firstTurn, secondTurn, thirdTurn, fourthTurn, fifthTurn, sixthTurn] → do
      firstTurn `shouldBe` PolledForWork
      secondTurn `shouldBe` PolledForWork
      thirdTurn `shouldSatisfy` waitedTheBound
      -- The notice was published at the end of the third turn, so the fourth
      -- had already chosen its wait; folding the evidence is that turn's own
      -- round's work.
      fourthTurn `shouldSatisfy` waitedTheBound
      -- That round served beta, leaving the revived owner owed an opportunity.
      fifthTurn `shouldBe` PolledForWork
      -- Which that turn gave it, and which found it waiting again.
      sixthTurn `shouldSatisfy` waitedTheBound
    other → unexpected ("the scheduled loop paced too few turns: " <> show other)

-- ---------------------------------------------------------------------------
-- The application exit

-- | The whole application exit path of the protected lifetime, with owners
-- attached through the public contract.
testExitWithOwners ∷ Expectation
testExitWithOwners = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  protectedRun
    seam
    (settings [windowNamed "alpha", windowNamed "beta"])
    ( \host → do
        (alpha, beta) ← twoWindows host
        void (attachedOwner journal host alpha (ownerNamed "alpha"))
        void (attachedOwner journal host beta (ownerNamed "beta"))
    )
    (\_ _ → pure ())
  entries ← readTVarIO journal
  let certifications = [entry | entry@Certified{} ← entries]
      natives = [entry | entry ← entries, entry `elem` [WindowGone 1, WindowGone 2, SessionEnded]]
  certifications `shouldSatisfy` \recorded →
    length recorded == 2 * length allRetirementFacts
  natives `shouldBe` [WindowGone 2, WindowGone 1, SessionEnded]
  -- Every certification precedes every destruction.
  takeWhile (/= WindowGone 2) entries `shouldSatisfy` \before →
    length [() | Certified{} ← before] == 2 * length allRetirementFacts

-- ---------------------------------------------------------------------------
-- Ordinary callers

-- | A window-only application sees no slot, no retirement demand, and turns
-- that behave exactly as they did.
testOrdinaryHostUnaffected ∷ Expectation
testOrdinaryHostUnaffected = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  asProcessMainThread seam $
    runWindowApplication
      (withLoggingLifetime quietLogger)
      "ordinary-host"
      (allocWindowHostIn (seamSession seam defaultSessionConfig) (settings [windowNamed "plain"]))
      id
      ( \host control → do
          window ← onlyWindow host
          atomically (windowGraphicsStatus host window) `shouldReturn` GraphicsWindowUnknown
          atomically (hostRetirementDemand host) `shouldReturn` noRetirementDemand
          atomically (hostPendingAttachments host) `shouldReturn` []
          case hostGraphicsPublisher host of
            Nothing → pure ()
            Just _ → unexpected "an ordinary host published a completion capability"
          client ← atomically (hostWindowClient host window) >>= maybe (unexpected "no client") pure
          ticket ←
            submitWindowCommand (clientCommandPort client) [] (closeWindowCommand window) >>= \case
              SubmitAccepted ticket → pure ticket
              other → unexpected ("the port refused a close: " <> show other)
          turnsUntil host control "the close" (hasSettled <$> atomically (pollCompletion ticket))
          atomically (hostRetirementDemand host) `shouldReturn` noRetirementDemand
      )
      (\() _ → pure ())
  entries ← readTVarIO journal
  entries `shouldBe` [WindowGone 1, SessionEnded]
