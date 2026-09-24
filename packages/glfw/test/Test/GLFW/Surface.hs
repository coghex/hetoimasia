-- | Examples for the surface bridge: window surfaces created under a protected
-- attachment, handed over as a live surface or an owned destruction
-- obligation, and destroyed through the capability's Vulkan operation before
-- the attachment can retire or the instance be released.
--
-- Every example runs a protected host over a loader-aware seam session whose
-- scripted capability records each surface it creates and destroys, so an
-- example asserts both what the bridge answered and which native calls it made
-- — in particular, that a refusal made none. The graphics owner that would
-- receive a surface is not built here (VK-7): each example discharges its
-- obligations itself, as a scripted owner would, and certifies the attachment's
-- retirement facts directly. Threads are coordinated with 'MVar's and STM, and
-- the one wait on another thread's state polls its status with 'yield', never
-- a sleep. Nothing here initializes GLFW, finds a Vulkan loader, or needs a
-- display.
module Test.GLFW.Surface (spec) where

import Control.Concurrent (ThreadId, forkIO, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), ExceptionWithContext (ExceptionWithContext), SomeException, fromException, throwIO, try)
import Control.Monad (forM, unless, void)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Foreign.Ptr (Ptr, intPtrToPtr)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked), threadStatus)
import Hetoimasia.Foundation.Recovery (Disposition (Required))
import Hetoimasia.GLFW.Command (SubmitResult (..), observeWindowCommand, submitWindowCommand)
import Hetoimasia.GLFW.Internal.Attachment (AttachmentPhase (..), AttachmentView (..), ConstructionState (..))
import Hetoimasia.GLFW.Seam
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import Hetoimasia.Runtime.GLFW.Internal.Retirement (releaseAttachmentHold)
import Hetoimasia.Runtime.GLFW.Internal.Surface
import Test.GLFW.Support (boundedExample, onThread, quietLogger, unexpected, windowNamed)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldReturn)

spec ∷ Spec
spec = describe "GLFW surface bridge" $ do
  it "creates a surface inside the construction step, holding the attachment and the lease until it is destroyed"
    (boundedExample testCreatedInConstruction)
  it "refuses creation outside a running step, and a foreign or released instance, before any native call"
    (boundedExample testRefusedBeforeNativeEffect)
  it "refuses creation on a host whose session took no loader capability"
    (boundedExample testRefusedWithoutCapability)
  it "admits a replacement on a live attachment and refuses one on a retiring attachment or a closing window"
    (boundedExample testReplacementAdmission)
  it "answers a native failure with its VkResult and GLFW's report, holding nothing"
    (boundedExample testNativeFailure)
  it "propagates an exception raised before a native result as itself, holding nothing"
    (boundedExample testExceptionBeforeResult)
  it "hands back only the obligation for a surface GLFW reported errors about"
    (boundedExample testReportedCreation)
  it "keeps a surface whose creator lost the answer to a cancellation, and refuses a rollback's claim of safety for it"
    (boundedExample testCancellationKeepsObligation)
  it "lets a rollback that discharges the lost surface's obligation retire the attachment"
    (boundedExample testRollbackDischarges)
  it "hands back only the obligation when the window begins closing during creation"
    (boundedExample testCloseDuringCreation)
  it "creates and delivers a surface while the ordinary command queue is full"
    (boundedExample testFullCommandQueue)
  it "discharges an obligation once, from another thread, and refuses the second"
    (boundedExample testDoubleDischarge)
  it "retains both holds for an uncertain destruction and never retries it"
    (boundedExample testUncertainDestruction)
  it "keeps the attachment and the lease while a second obligation remains after the first is discharged"
    (boundedExample testSecondObligationRetains)
  it "keeps the attachment and the lease while an admitted construction is still in its native call"
    (boundedExample testConstructionInFlightRetains)

-- ---------------------------------------------------------------------------
-- Examples

testCreatedInConstruction ∷ Expectation
testCreatedInConstruction = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    created ← newIORef Nothing
    (service, acknowledgement) ←
      attachWith host window (\access → createWindowSurface access lease >>= writeIORef created . Just)
    surface ←
      readIORef created >>= \case
        Just (SurfaceCreated surface) → pure surface
        other → unexpected ("the construction step created " <> show other)
    surfaceHandle surface `shouldBe` 1001
    surfaceAttachment surface `shouldBe` graphicsAttachment service
    atomically (readLeaseStanding lease) `shouldReturn` LeaseStanding True 0 1 0
    detachWindowGraphics host service `shouldReturn` DetachBegun
    certifyAllBut host acknowledgement
    -- The surface still exists, so its attachment cannot certify that its
    -- dependents are disposed, and its instance cannot be released.
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Nothing
    atomically (releaseSurfaceInstance lease) `shouldReturn` InstanceRetained (LeaseStanding False 0 1 0)
    -- The graphics owner discharges it from its own thread.
    discharged ← onThread forkIO (dischargeSurfaceObligation (surfaceObligation surface))
    show discharged `shouldBe` "SurfaceDestroyed"
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Just AttachmentNowRetired
    atomically (releaseSurfaceInstance lease) `shouldReturn` InstanceReleasable
  surfaceCalls seam `shouldReturn` [CreateWindowSurface 1, DestroyWindowSurface 1001]

testRefusedBeforeNativeEffect ∷ Expectation
testRefusedBeforeNativeEffect = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript
  unused ← seamIntegration seam defaultIntegrationScript
  lease ← leaseSurfaceInstance integration instancePointer
  foreignLease ← leaseSurfaceInstance unused instancePointer
  releasing ← leaseSurfaceInstance integration instancePointer
  _ ← atomically (releaseSurfaceInstance releasing)
  bridged seam integration $ \host window → do
    kept ← newIORef Nothing
    answers ← newIORef []
    (service, acknowledgement) ←
      attachWith host window $ \access → do
        writeIORef kept (Just access)
        foreignAnswer ← createWindowSurface access foreignLease
        releasingAnswer ← createWindowSurface access releasing
        writeIORef answers [foreignAnswer, releasingAnswer]
    map show <$> readIORef answers
      `shouldReturn` [show (SurfaceRefused SurfaceForeignInstance), show (SurfaceRefused SurfaceInstanceReleasing)]
    access ← readIORef kept >>= maybe (unexpected "the step kept no access") pure
    -- The step has returned, so the access it was given is closed.
    show <$> createWindowSurface access lease `shouldReturn` show (SurfaceRefused SurfaceAccessClosed)
    retireFully host service acknowledgement
  surfaceCalls seam `shouldReturn` []

testRefusedWithoutCapability ∷ Expectation
testRefusedWithoutCapability = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript
  lease ← leaseSurfaceInstance integration instancePointer
  answered ← newIORef Nothing
  asProcessMainThread seam $
    withProtectedWindowHostIn quietLogger (seamSession seam defaultSessionConfig) (defaultHostConfig [windowNamed "bridge"]) $ \host → do
      window ← onlyWindow host
      (service, acknowledgement) ←
        attachWith host window (\access → createWindowSurface access lease >>= writeIORef answered . Just)
      retireFully host service acknowledgement
  show <$> readIORef answered `shouldReturn` show (Just (SurfaceRefused SurfaceSessionNotLoaderAware))
  surfaceCalls seam `shouldReturn` []

testReplacementAdmission ∷ Expectation
testReplacementAdmission = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    (service, acknowledgement) ← attachWith host window (\_ → pure ())
    kept ← newIORef Nothing
    replaced ←
      replaceWindowSurface host acknowledgement $ \access → do
        writeIORef kept (Just access)
        createWindowSurface access lease
    surface ← case replaced of
      ReplacementRan (SurfaceCreated surface) → pure surface
      other → unexpected ("the replacement answered " <> show other)
    access ← readIORef kept >>= maybe (unexpected "the replacement kept no access") pure
    show <$> createWindowSurface access lease `shouldReturn` show (SurfaceRefused SurfaceAccessClosed)
    detachWindowGraphics host service `shouldReturn` DetachBegun
    retiring ← replaceWindowSurface host acknowledgement (\_ → unexpected "a retiring attachment ran a replacement" ∷ IO ())
    show retiring `shouldBe` show (ReplacementRefused @() (SurfaceAttachmentNotAdmitting (Just AttachmentRetiring)))
    void (dischargeSurfaceObligation (surfaceObligation surface))
    certifyAll host acknowledgement `shouldReturn` Just AttachmentNowRetired
    -- A second attachment on the same window, then its window begins closing.
    (_, again) ← attachWith host window (\_ → pure ())
    closeHostWindow host window `shouldReturn` CloseStarted
    closing ← replaceWindowSurface host again (\_ → unexpected "a closing window ran a replacement" ∷ IO ())
    show closing `shouldBe` show (ReplacementRefused @() SurfaceWindowClosing)
    certifyAll host again `shouldReturn` Just AttachmentNowRetired
  surfaceCalls seam `shouldReturn` [CreateWindowSurface 1, DestroyWindowSurface 1001]

testNativeFailure ∷ Expectation
testNativeFailure = do
  seam ← newSeam defaultScript
  integration ←
    seamIntegration
      seam
      defaultIntegrationScript
        { integrationCreate = \_ reporter → do
            reportError reporter 0x00010006 "Vulkan: Window surface creation extensions not found"
            pure (-7, 0)
        }
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    answered ← newIORef Nothing
    (service, acknowledgement) ←
      attachWith host window (\access → createWindowSurface access lease >>= writeIORef answered . Just)
    readIORef answered >>= \case
      Just (SurfaceCreationFailed result reports) → do
        result `shouldBe` (-7)
        map (\reported → (nativeErrorCode reported, nativeErrorDescription reported)) (reportedErrors reports)
          `shouldBe` [(0x00010006, "Vulkan: Window surface creation extensions not found")]
      other → unexpected ("the failed creation answered " <> show other)
    atomically (readLeaseStanding lease) `shouldReturn` LeaseStanding True 0 0 0
    retireFully host service acknowledgement
    atomically (releaseSurfaceInstance lease) `shouldReturn` InstanceReleasable

testExceptionBeforeResult ∷ Expectation
testExceptionBeforeResult = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript {integrationCreate = \_ _ → throwIO (ErrorCall "no surface support")}
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    attached ← attachWindowGraphicsWithSurfaces host window (\access → protocolOf (\_ → void (createWindowSurface access lease)) (pure RollbackSafe))
    case attached of
      GraphicsRolledBack settled → do
        rolledBackOutcome settled `shouldBe` RollbackSafe
        -- The construction's own failure, not a fabricated VkResult.
        fromException (exceptionOf (rolledBackFailure settled)) `shouldBe` Just (ErrorCall "no surface support")
      other → unexpected ("the attachment answered " <> show other)
    atomically (readLeaseStanding lease) `shouldReturn` LeaseStanding True 0 0 0
  surfaceCalls seam `shouldReturn` [CreateWindowSurface 1]

testReportedCreation ∷ Expectation
testReportedCreation = do
  seam ← newSeam defaultScript
  integration ←
    seamIntegration
      seam
      defaultIntegrationScript
        { integrationCreate = \key reporter → do
            reportError reporter 0x00010008 "Wayland: a stray report"
            pure (0, 1000 + fromIntegral key)
        }
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    answered ← newIORef Nothing
    (service, acknowledgement) ←
      attachWith host window (\access → createWindowSurface access lease >>= writeIORef answered . Just)
    obligation ←
      readIORef answered >>= \case
        Just (SurfaceUnpublished obligation (CreatedWithReports _)) → pure obligation
        other → unexpected ("the reported creation answered " <> show other)
    obligationHandle obligation `shouldBe` 1001
    detachWindowGraphics host service `shouldReturn` DetachBegun
    certifyAllBut host acknowledgement
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Nothing
    void (dischargeSurfaceObligation obligation)
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Just AttachmentNowRetired

testCancellationKeepsObligation ∷ Expectation
testCancellationKeepsObligation = do
  seam ← newSeam defaultScript
  thrower ← newEmptyMVar
  integration ←
    seamIntegration
      seam
      defaultIntegrationScript
        { integrationCreate = \key _ → do
            -- A cancellation is posted to the owner while the native call runs,
            -- and is pending by the time the call returns.
            owner ← myThreadId
            posting ← forkIO (throwTo owner ThreadKilled)
            putMVar thrower posting
            awaitBlockedThrow posting
            pure (0, 1000 + fromIntegral key)
        }
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    heard ← newIORef Nothing
    received ← newIORef False
    attempted ←
      try $
        attachWindowGraphicsWithSurfaces host window $ \access →
          protocolOf
            (\acknowledgement → do
                writeIORef heard (Just acknowledgement)
                _ ← createWindowSurface access lease
                writeIORef received True)
            -- A rollback that claims safety without discharging anything.
            (pure RollbackSafe)
    _ ← takeMVar thrower
    case attempted of
      Left ThreadKilled → pure ()
      Left other → unexpected ("the attachment raised " <> show other)
      Right answered → unexpected ("the attachment answered " <> show answered)
    -- The creator never received the answer.
    readIORef received `shouldReturn` False
    acknowledgement ← readIORef heard >>= maybe (unexpected "no acknowledgement was issued") pure
    -- The surface is still owned: its obligation is on the lease, and it holds
    -- the attachment, whose rollback could not be safe.
    obligations ← atomically (leasedObligations lease)
    map obligationHandle obligations `shouldBe` [1001]
    view ← atomically (Private.hostAttachmentView host (acknowledgedAttachment acknowledgement))
    fmap viewConstruction view `shouldBe` Just (ConstructionFailed RollbackUnsafe)
    certifyAllBut host acknowledgement
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Nothing
    discharged ← forM obligations dischargeSurfaceObligation
    map show discharged `shouldBe` ["SurfaceDestroyed"]
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Just AttachmentNowRetired
  surfaceCalls seam `shouldReturn` [CreateWindowSurface 1, DestroyWindowSurface 1001]

testRollbackDischarges ∷ Expectation
testRollbackDischarges = do
  seam ← newSeam defaultScript
  thrower ← newEmptyMVar
  integration ←
    seamIntegration
      seam
      defaultIntegrationScript
        { integrationCreate = \key _ → do
            owner ← myThreadId
            posting ← forkIO (throwTo owner ThreadKilled)
            putMVar thrower posting
            awaitBlockedThrow posting
            pure (0, 1000 + fromIntegral key)
        }
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    attempted ←
      try $
        attachWindowGraphicsWithSurfaces host window $ \access →
          protocolOf
            (\_ → void (createWindowSurface access lease))
            -- The owned rollback finds what the lost answer created, and
            -- discharges it before claiming safety.
            ( do
                owed ← atomically (leasedObligations lease)
                results ← forM owed dischargeSurfaceObligation
                pure (if all ((== "SurfaceDestroyed") . show) results then RollbackSafe else RollbackUnsafe)
            )
    _ ← takeMVar thrower
    case attempted of
      Left ThreadKilled → pure ()
      other → unexpected ("the attachment ended with " <> either show show other)
    -- The rollback was safe, so the attachment has retired and the window's
    -- slot is free.
    status ← atomically (windowGraphicsStatus host window)
    show status `shouldBe` show GraphicsAbsent
    atomically (releaseSurfaceInstance lease) `shouldReturn` InstanceReleasable
  surfaceCalls seam `shouldReturn` [CreateWindowSurface 1, DestroyWindowSurface 1001]

testCloseDuringCreation ∷ Expectation
testCloseDuringCreation = do
  seam ← newSeam defaultScript
  closer ← newIORef (pure ())
  integration ←
    seamIntegration
      seam
      defaultIntegrationScript
        { integrationCreate = \key _ → do
            -- The window begins closing while its surface is being created.
            readIORef closer >>= id
            pure (0, 1000 + fromIntegral key)
        }
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    writeIORef closer (void (closeHostWindow host window))
    answered ← newIORef Nothing
    heard ← newIORef Nothing
    attached ←
      attachWindowGraphicsWithSurfaces host window $ \access →
        protocolOf
          (\acknowledgement → do
              writeIORef heard (Just acknowledgement)
              createWindowSurface access lease >>= writeIORef answered . Just)
          (pure RollbackUnsafe)
    case attached of
      GraphicsSuperseded _ → pure ()
      other → unexpected ("the attachment answered " <> show other)
    obligation ←
      readIORef answered >>= \case
        Just (SurfaceUnpublished obligation (CreatedAfterAdmissionEnded SurfaceWindowClosing)) → pure obligation
        other → unexpected ("the creation answered " <> show other)
    acknowledgement ← readIORef heard >>= maybe (unexpected "no acknowledgement was issued") pure
    certifyAllBut host acknowledgement
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Nothing
    void (dischargeSurfaceObligation obligation)
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Just AttachmentNowRetired

testFullCommandQueue ∷ Expectation
testFullCommandQueue = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    (service, acknowledgement) ← attachWith host window (\_ → pure ())
    let fill = do
          submitted ← submitWindowCommand (hostCommandPort host) [] (observeWindowCommand window)
          case submitted of
            SubmitAccepted _ → fill
            SubmitFull → pure ()
            SubmitClosed → unexpected "the host port closed while it was being filled"
    fill
    replaced ← replaceWindowSurface host acknowledgement (\access → createWindowSurface access lease)
    surface ← case replaced of
      ReplacementRan (SurfaceCreated surface) → pure surface
      other → unexpected ("the replacement answered " <> show other)
    void (dischargeSurfaceObligation (surfaceObligation surface))
    retireFully host service acknowledgement

testDoubleDischarge ∷ Expectation
testDoubleDischarge = do
  seam ← newSeam defaultScript
  during ← newIORef (pure ())
  integration ← seamIntegration seam defaultIntegrationScript {integrationDestroy = \_ → readIORef during >>= id}
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    created ← newIORef Nothing
    (service, acknowledgement) ←
      attachWith host window (\access → createWindowSurface access lease >>= writeIORef created . Just)
    obligation ←
      readIORef created >>= \case
        Just (SurfaceCreated surface) → pure (surfaceObligation surface)
        other → unexpected ("the construction step created " <> show other)
    detachWindowGraphics host service `shouldReturn` DetachBegun
    certifyAllBut host acknowledgement
    -- While the destruction runs, the instance is still held.
    seen ← newEmptyMVar
    writeIORef during (atomically (releaseSurfaceInstance lease) >>= putMVar seen)
    first ← onThread forkIO (dischargeSurfaceObligation obligation)
    readMVar seen `shouldReturn` InstanceRetained (LeaseStanding False 0 1 0)
    show first `shouldBe` "SurfaceDestroyed"
    second ← onThread forkIO (dischargeSurfaceObligation obligation)
    show second `shouldBe` show (DischargeRefused AlreadyDischarged)
    atomically (readObligationState obligation) `shouldReturn` ObligationDischarged
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Just AttachmentNowRetired
    atomically (releaseSurfaceInstance lease) `shouldReturn` InstanceReleasable
  surfaceCalls seam `shouldReturn` [CreateWindowSurface 1, DestroyWindowSurface 1001]

testUncertainDestruction ∷ Expectation
testUncertainDestruction = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript {integrationDestroy = \_ → throwIO (ErrorCall "device lost")}
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    created ← newIORef Nothing
    (service, acknowledgement) ←
      attachWith host window (\access → createWindowSurface access lease >>= writeIORef created . Just)
    obligation ←
      readIORef created >>= \case
        Just (SurfaceCreated surface) → pure (surfaceObligation surface)
        other → unexpected ("the construction step created " <> show other)
    detachWindowGraphics host service `shouldReturn` DetachBegun
    certifyAllBut host acknowledgement
    first ← dischargeSurfaceObligation obligation
    show first `shouldBe` "DestructionUncertain"
    second ← dischargeSurfaceObligation obligation
    show second `shouldBe` show (DischargeRefused DestructionWasUncertain)
    atomically (readObligationState obligation) `shouldReturn` ObligationUncertain
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Nothing
    atomically (releaseSurfaceInstance lease) `shouldReturn` InstanceRetained (LeaseStanding False 0 0 1)
    -- The attachment would now wait for good, as it should. Only so that this
    -- example's host can exit, independent evidence is simulated through the
    -- private retirement seam; nothing in production can do this.
    case Private.hostRetirementOf host of
      Nothing → unexpected "the protected host has no retirement state"
      Just retirement → atomically (releaseAttachmentHold retirement (acknowledgedAttachment acknowledgement))
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Just AttachmentNowRetired
  -- The uncertain destruction was attempted once.
  surfaceCalls seam `shouldReturn` [CreateWindowSurface 1, DestroyWindowSurface 1001]

testSecondObligationRetains ∷ Expectation
testSecondObligationRetains = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    created ← newIORef Nothing
    (service, acknowledgement) ←
      attachWith host window (\access → createWindowSurface access lease >>= writeIORef created . Just)
    initial ← createdSurface created
    replaced ← replaceWindowSurface host acknowledgement (\access → createWindowSurface access lease)
    replacement ← case replaced of
      ReplacementRan (SurfaceCreated surface) → pure surface
      other → unexpected ("the replacement answered " <> show other)
    detachWindowGraphics host service `shouldReturn` DetachBegun
    certifyAllBut host acknowledgement
    void (dischargeSurfaceObligation (surfaceObligation initial))
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Nothing
    atomically (releaseSurfaceInstance lease) `shouldReturn` InstanceRetained (LeaseStanding False 0 1 0)
    void (dischargeSurfaceObligation (surfaceObligation replacement))
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Just AttachmentNowRetired
    atomically (releaseSurfaceInstance lease) `shouldReturn` InstanceReleasable

testConstructionInFlightRetains ∷ Expectation
testConstructionInFlightRetains = do
  seam ← newSeam defaultScript
  during ← newIORef (\_ → pure ())
  integration ←
    seamIntegration
      seam
      defaultIntegrationScript
        { integrationCreate = \key _ → do
            hook ← readIORef during
            hook key
            pure (0, 1000 + fromIntegral key)
        }
  lease ← leaseSurfaceInstance integration instancePointer
  bridged seam integration $ \host window → do
    created ← newIORef Nothing
    (_, acknowledgement) ←
      attachWith host window (\access → createWindowSurface access lease >>= writeIORef created . Just)
    initial ← createdSurface created
    inFlight ← newIORef Nothing
    -- While the replacement's native call runs: the window begins closing, so
    -- the attachment retires; the first surface is discharged; and every fact
    -- is offered. The construction still in flight holds both.
    writeIORef during $ \_ → do
      _ ← closeHostWindow host window
      _ ← dischargeSurfaceObligation (surfaceObligation initial)
      certifyAllBut host acknowledgement
      disposed ← certifyGraphicsFact host acknowledgement DependentsDisposed
      released ← atomically (releaseSurfaceInstance lease)
      writeIORef inFlight (Just (disposed, released))
    replaced ← replaceWindowSurface host acknowledgement (\access → createWindowSurface access lease)
    readIORef inFlight `shouldReturn` Just (Nothing, InstanceRetained (LeaseStanding False 1 0 0))
    obligation ← case replaced of
      ReplacementRan (SurfaceUnpublished obligation (CreatedAfterAdmissionEnded SurfaceWindowClosing)) → pure obligation
      other → unexpected ("the replacement answered " <> show other)
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Nothing
    void (dischargeSurfaceObligation obligation)
    certifyGraphicsFact host acknowledgement DependentsDisposed `shouldReturn` Just AttachmentNowRetired
    atomically (releaseSurfaceInstance lease) `shouldReturn` InstanceReleasable

-- ---------------------------------------------------------------------------
-- Fixtures

-- | A stand-in for a dispatchable instance handle. The scripted capability
-- never dereferences it.
instancePointer ∷ Ptr ()
instancePointer = intPtrToPtr 0x77

-- | Run a body on the process main thread, on a protected host over a
-- loader-aware seam session with one window.
bridged ∷ Seam → SessionIntegration → (WindowHost → WindowId → IO a) → IO a
bridged seam integration body =
  asProcessMainThread seam $
    withProtectedWindowHostIn
      quietLogger
      (seamIntegratedSession seam integration defaultSessionConfig)
      (defaultHostConfig [windowNamed "bridge"])
      (\host → onlyWindow host >>= body host)

onlyWindow ∷ WindowHost → IO WindowId
onlyWindow host =
  atomically (hostWindowIdentities host) >>= \case
    [window] → pure window
    other → unexpected ("the host holds " <> show (length other) <> " windows, not one")

-- | A protocol whose construction step runs the given action with the
-- acknowledgement it was issued, whose rollback is the given one, and whose
-- retirement step never progresses: every example here certifies its facts
-- directly.
protocolOf ∷ (Acknowledgement → IO ()) → IO RollbackOutcome → AttachmentProtocol
protocolOf construct rollback =
  AttachmentProtocol
    { protocolConstruct = \_ acknowledgement → construct acknowledgement
    , protocolRollback = rollback
    , protocolStep = \_ _ → pure RetirementAwaiting
    , protocolCompletion = FiniteCompletion
    , protocolDisposition = Required
    , protocolRecognizes = \_ → pure False
    }

-- | Attach with a construction step that runs the given action on its open
-- access, answering the published service and its acknowledgement.
attachWith ∷ WindowHost → WindowId → (SurfaceAccess → IO ()) → IO (GraphicsService, Acknowledgement)
attachWith host window construct = do
  heard ← newIORef Nothing
  attached ←
    attachWindowGraphicsWithSurfaces host window $ \access →
      protocolOf (\acknowledgement → writeIORef heard (Just acknowledgement) >> construct access) (pure RollbackUnsafe)
  acknowledgement ← readIORef heard >>= maybe (unexpected "no acknowledgement was issued") pure
  case attached of
    GraphicsAttached service → pure (service, acknowledgement)
    other → unexpected ("the attachment answered " <> show other)

createdSurface ∷ IORef (Maybe SurfaceCreation) → IO WindowSurface
createdSurface created =
  readIORef created >>= \case
    Just (SurfaceCreated surface) → pure surface
    other → unexpected ("the construction step created " <> show other)

-- | Certify every retirement fact except 'DependentsDisposed', each of which
-- must record.
certifyAllBut ∷ WindowHost → Acknowledgement → Expectation
certifyAllBut host acknowledgement =
  mapM_
    ( \fact → do
        answered ← certifyGraphicsFact host acknowledgement fact
        unless (isRecorded answered) (unexpected ("certifying " <> show fact <> " answered " <> show answered))
    )
    [CpuUseRetired, SubmittedWorkEnded, PresentationEnded]
  where
    isRecorded = \case
      Just (FactRecorded _) → True
      _ → False

-- | Certify every retirement fact, answering what the last one did.
certifyAll ∷ WindowHost → Acknowledgement → IO (Maybe FactAnswer)
certifyAll host acknowledgement = do
  certifyAllBut host acknowledgement
  certifyGraphicsFact host acknowledgement DependentsDisposed

-- | Detach an attachment with nothing outstanding and retire it at once.
retireFully ∷ WindowHost → GraphicsService → Acknowledgement → Expectation
retireFully host service acknowledgement = do
  detachWindowGraphics host service `shouldReturn` DetachBegun
  certifyAll host acknowledgement `shouldReturn` Just AttachmentNowRetired

-- | The surface calls the seam recorded, in order.
surfaceCalls ∷ Seam → IO [NativeCall]
surfaceCalls seam = filter surfaceCall <$> seamCalls seam
  where
    surfaceCall = \case
      CreateWindowSurface _ → True
      DestroyWindowSurface _ → True
      _ → False

exceptionOf ∷ ExceptionWithContext SomeException → SomeException
exceptionOf (ExceptionWithContext _ failure) = failure

-- | Wait until a thread is blocked posting an exception to a masked target:
-- then that exception is pending, and is delivered as soon as the target
-- unmasks.
awaitBlockedThrow ∷ ThreadId → IO ()
awaitBlockedThrow posting =
  threadStatus posting >>= \case
    ThreadBlocked BlockedOnException → pure ()
    _ → yield >> awaitBlockedThrow posting
