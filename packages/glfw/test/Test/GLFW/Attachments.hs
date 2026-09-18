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

import Control.Concurrent (forkIO, forkOS, killThread)
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
  , SomeException
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forM, forM_, void, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Recovery (Disposition (Required))
import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.Foundation.Resource (withScoped)
import Hetoimasia.GLFW.Command
  ( SubmitResult (..)
  , clientCommandPort
  , closeWindowCommand
  , observeWindowCommand
  , pollCompletion
  , submitWindowCommand
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
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Numeric.Natural (Natural)
import Test.GLFW.Support (at, boundedExample, millis, quietLogger, scriptedClock, unexpected, windowNamed)
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
    it "ends the owner's idle wait with a completion published from another thread, and folds it in the next round"
      (boundedExample testCompletionWakesTurn)

  describe "the schedule" $
    it "shortens the wait to a retirement's own instant and polls once a round advanced"
      (boundedExample testRetirementSchedule)

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
  }

-- | An owner that constructs without effect and certifies every fact, one per
-- opportunity.
ownerNamed ∷ Text → OwnerScript
ownerNamed name =
  OwnerScript name (pure ()) (pure RollbackSafe) (map Certify allRetirementFacts) FiniteCompletion

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
    , protocolDisposition = Required
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
    (alphaOwner, _) ← attachedOwner journal host alpha (ownerNamed "alpha")
    (betaOwner, _) ← attachedOwner journal host beta (ownerNamed "beta")
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
    -- And beta's own close, retirement, and destruction run to the end while
    -- alpha is still pending.
    void (closeHostWindow host beta)
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
  -- Beta's whole retirement and destruction happened before alpha's.
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
    -- One opportunity per turn, to a different owner each turn: after three
    -- turns every owner has been offered exactly one.
    turnsExactly host control 3
    offered ← traverse (atomically . readTVar . ownerSteps) owners
    writeIORef counts offered
    demand ← atomically (hostRetirementDemand host)
    retirementPending demand `shouldBe` 3
    -- Work the budget could not reach keeps the next turn immediate.
    retirementImmediate demand `shouldBe` True
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
-- The schedule

-- | A retirement that named an instant shortens the scheduled wait to it, and
-- a round that advanced makes the next turn poll: a due retirement step is
-- never delayed by the idle bound.
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
      -- Nothing was owed before the first round ran, so the turn waited the
      -- configured fallback bound.
      first' `shouldSatisfy` \case
        WaitedForFallback _ → True
        _ → False
      -- The instant the owner named is nearer than the fallback, so the wait
      -- is the time remaining to it, not the bound.
      second' `shouldSatisfy` \case
        WaitedForDeadline _ → True
        _ → False
      -- Once a round advanced, the turn after it polls rather than waiting.
      rest `shouldSatisfy` all (== PolledForWork)
    _ → unexpected ("the scheduled loop ran too few turns: " <> show observed)

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
