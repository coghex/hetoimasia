-- | Stand-ins for the controller's two native boundaries, and a rig that runs
-- a whole Vulkan graphics host over the GLFW package's scripted seam.
--
-- Everything the controller does natively goes through one of two records —
-- the roots' native layer and the surface bridge — so these stand-ins drive
-- the real controller, the real graphics owner and the real protected host
-- exactly as a native run does, and can be told to fail, report device loss,
-- hold, or report a validation message into the session's real capture from
-- inside the call, as a layer does, at any step — which a native run cannot be
-- asked to do on demand.
-- Every call is journalled with the thread that made it, and the seam's own
-- window and session releases are journalled into the same place, so an
-- example can read one order across all of them.
module Test.GPU.Vulkan.GLFW.StandIn
  ( -- * The journal
    Event (..)
  , Journal
  , journal
  , threadsOf
  , awaitEvent
  , journalHas

    -- * The native layer
  , Native
  , Step (..)
  , Scripted (..)
  , scriptNative
  , declareUnsupported
  , StandInFailure (..)
  , StandInLoss (..)
  , StandInSurfaceLost (..)
  , injectedMessageId
  , reportErrorNow
  , reportWarningNow
  , awaitSinkRecorded
  , claimSinkFirst
  , awaitHeld

    -- * The surface bridge
  , Bridge
  , SurfaceScript (..)
  , scriptSurface
  , raiseAfterAttach
  , afterRefusal
  , bridgeLeaseAnswer

    -- * The rendering layers
  , Rendering
  , submissionsComplete
  , presentationsRetire
  , scriptPresentStatus
  , slowNativeCalls
  , holdAcquisitions
  , stallSwapchain
  , raiseOnPresent
  , suboptimalWhileStale
  , swapchainsCreated
  , frameEvents
  , fenceQueries
  , presentsOf
  , presentRounds
  , awaitPresents
  , retireNextPresentations

    -- * The rig
  , Rig (..)
  , Scene
  , newRig
  , newRigOf
  , visibleRig
  , visibleRigOf
  , scriptedRigOf
  , advanceClock
  , setClock
  , clockNow
  , holdPump
  , pumpHeld
  , setVisible
  , resizeFramebuffer
  , publishObservation
  , nudgeOwner
  , offerExtent
  , twoWindows
  , failingSink
  , sinkHasFailed
  , creationsBegun
  , runRig
  , runRigCaught
  , quietLogger
  , pumpUntil
  , handedOver
  , windowsOf
  , awaitStanding
  , awaitTerminal
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , check
  , modifyTVar'
  , newTVarIO
  , orElse
  , registerDelay
  , readTVar
  , readTVarIO
  , retry
  , stateTVar
  , writeTVar
  )
import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeException, fromException, rethrowIO, throwIO, try, tryWithContext, uninterruptibleMask_)
import Control.Monad (void, when)
import Data.ByteString (ByteString)
import qualified Data.Vector as Vector
import Foreign.Ptr (FunPtr, castFunPtr, castPtr)
import Vulkan.CStruct (withCStruct)
import Vulkan.Extensions.VK_EXT_debug_utils (DebugUtilsMessengerCallbackDataEXT (..))
import Vulkan.Zero (zero)
import Hetoimasia.GPU.Vulkan.Native.Diagnostics (captureMessengerCallback)
import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr, nullPtr, plusPtr)
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLoggerWith, systemMetadata)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import qualified Hetoimasia.Foundation.Worker as Worker
import Hetoimasia.GLFW.Seam
  ( Seam
  , SeamScript (..)
  , WindowAttribute (VisibleAttribute)
  , asProcessMainThread
  , defaultIntegrationScript
  , defaultScript
  , newSeam
  , seamIntegratedSession
  , seamIntegration
  )
import Hetoimasia.GLFW.Vulkan (Replacement (..), replaceWindowSurface, requiredInstanceExtensions)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.GLFW.Command (WaitedSubmission (..), awaitSubmitWindowCommand, clientObservations, hideWindowCommand, setWindowSizeCommand, showWindowCommand)
import Hetoimasia.GLFW.Window (Extent (Extent), WindowConfig, WindowId, hiddenTestWindowConfig, observedRevision)
import Numeric.Natural (Natural)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass)
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig, DiagnosticCapture, DiagnosticVerdict, Quiesced, afterLastCallback, captureSinkFailure, captureUserData, defaultCaptureConfig, diagnosticVerdictInContext, requestDrain)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Bridge (Created (..), Discharged (..), LeaseAnswer (..), SurfaceBridge (..))
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), Instant, addDuration, deadlineReached, durationFromNanoseconds, scriptedInstant, scriptedSource, zeroDuration)
import Hetoimasia.GPU.Vulkan.Native.Frames (AcquireResult (..), FrameOps (..), PresentRequest (..), PresentStatus (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (RecordingOps (..))
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
  ( FrameEvent (..)
  , RenderingOps (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , Readiness (..)
  , ControllerHooks (..)
  , handOverVulkanTarget
  , readReadiness
  , vulkanHostConfig
  , withVulkanOwnerHostHooked
  )
import Hetoimasia.GPU.Vulkan.Native.Profile
  ( DeviceOffer (..)
  , DevicePlan (..)
  , InstanceOffer (..)
  , QueueFamilyOffer (..)
  , debugUtilsExtension
  , getSurfaceCapabilities2Extension
  , packApiVersion
  , surfaceMaintenance1Extension
  , swapchainExtension
  , swapchainMaintenance1Extension
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation
  ( GenerationPlan (..)
  , SurfaceCapabilities (..)
  , SurfaceExtent (..)
  , SurfaceFormat (..)
  , SurfaceOffer (..)
  , colorSpaceSrgbNonlinear
  , compositeAlphaOpaque
  , formatB8G8R8A8Srgb
  , imageUsageColorAttachment
  , presentModeFifo
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (GenerationOps (..), NativeFailure (..), RootOps (..), SwapchainRequest (..))
import Hetoimasia.Runtime.GLFW
  ( AttachmentId
  , acknowledgedAttachment
  , AttachmentProtocol (..)
  , GraphicsOwner
  , GraphicsOwnerConfig (..)
  , ownerTimer
  , GraphicsService
  , HostConfig (..)
  , LoopHooks (..)
  , TargetStanding (..)
  , OwnerStatus (..)
  , readOwnerStatusNow
  , TerminalRecord
  , Turn (..)
  , TurnStep (..)
  , attachWindowGraphics
  , defaultHostConfig
  , graphicsAttachment
  , graphicsOwnerWorker
  , hostCommandPort
  , hostWindowClient
  , publishGraphicsObservation
  , windowRenderEligibility
  , hostWindowIdentities
  , noApplicationEvents
  , readTargetStanding
  , readTargetTerminalsNow
  , runGraphicsOwnerApplication
  , runOwnerLoop
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)

-- ---------------------------------------------------------------------------
-- The journal

-- | One thing that happened at a native boundary.
data Event
  = InstanceCreated
  | MessengerCreated
  | DevicesQueried !Word64
  | DeviceCreated
  | SupportQueried !Word64
  | SurfaceCreated !Word64
  | SurfaceDestroyStarted !Word64
    -- ^ A destruction scripted to hold has begun and is holding.
  | SurfaceDestroyed !Word64
  | DeviceDestroyed
  | MessengerDestroyed
  | InstanceDestroyed
  | SwapchainCreated !Word64 !(Word32, Word32) !(Maybe Word64)
    -- ^ The swapchain made, its extent, and the one handed over as
    -- @oldSwapchain@.
  | ViewCreated !Word64
  | ViewDestroyed !Word64
  | SwapchainDestroyed !Word64
  | WindowGone !Bool
    -- ^ The seam destroyed a window; whether the graphics owner's worker had
    -- already completed by then.
  | SessionEnded
  | FenceQueried !Word64
    -- ^ A fence's status was asked, without waiting.
  | ImageAcquired !Word64 !Word32
    -- ^ A swapchain's image was acquired.
  | QueueSubmitted !Word64
    -- ^ A submission was made, with this fence.
  | ImagePresented !Word64 !Word32
    -- ^ A swapchain's image was presented.
  | ImageReleased !Word64 ![Word32]
  | OwnerTimerArmed
    -- ^ The owner armed its timer, with a scripted clock.
  deriving (Eq, Show)

-- | Every event, newest first, with the thread that caused it.
type Journal = TVar [(ThreadId, Event)]

record ∷ Journal → Event → IO ()
record events event = do
  caller ← myThreadId
  atomically (modifyTVar' events ((caller, event) :))

-- | Every event so far, oldest first.
journal ∷ Rig → IO [Event]
journal rig = map snd . reverse <$> readTVarIO (rigJournal rig)

-- | The threads the events matching this test were caused on.
threadsOf ∷ Rig → (Event → Bool) → IO [ThreadId]
threadsOf rig wanted = map fst . filter (wanted . snd) . reverse <$> readTVarIO (rigJournal rig)

-- | Wait until this event has happened.
awaitEvent ∷ Rig → Event → IO ()
awaitEvent rig event = atomically (journalHas rig event >>= check)

-- | Whether this event has happened.
journalHas ∷ Rig → Event → STM Bool
journalHas rig event = elem event . map snd <$> readTVar (rigJournal rig)

-- ---------------------------------------------------------------------------
-- The native layer

-- | A step of the native layer that can be scripted.
data Step
  = AtCreateInstance
  | AtCreateMessenger
  | AtQueryDevices
  | AtCreateDevice
  | AtSupport
  | AtDestroyDevice
  | AtDestroyMessenger
  | AtDestroyInstance
  | AtCreateSwapchain
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What a scripted step does instead of simply succeeding.
data Scripted
  = Fails
    -- ^ Raises 'StandInFailure': neither success nor device loss.
  | Loses
    -- ^ Raises 'StandInLoss', which this layer classifies as device loss.
  | HoldsUntil !(TVar Bool)
    -- ^ Holds, uninterruptibly as a native call does, until released.
  | ReportsError !ByteString
    -- ^ Reports one error-severity validation message with this text into the
    -- session's capture from inside the call, as a layer does, then succeeds.
  | ReportsWarning !ByteString
    -- ^ The same at warning severity, which is a diagnostic and never a
    -- failure.
  | LosesSurface
    -- ^ Raises 'StandInSurfaceLost', which this layer classifies as the
    -- surface's loss (VK-14).

-- | @VK_ERROR_SURFACE_LOST_KHR@, as the stand-in raises it.
newtype StandInSurfaceLost = StandInSurfaceLost Text
  deriving (Eq, Show)

instance Exception StandInSurfaceLost

newtype StandInFailure = StandInFailure Text
  deriving (Eq, Show)

instance Exception StandInFailure

newtype StandInLoss = StandInLoss Text
  deriving (Eq, Show)

instance Exception StandInLoss

data Native = Native
  { nativeScript ∷ !(TVar (Map Step Scripted))
  , nativeUnsupported ∷ !(TVar (Set Word64))
  , nativeHandles ∷ !(TVar Word64)
    -- ^ The next swapchain or view handle, from 500.
  , nativeCurrentExtent ∷ !(TVar (Maybe SurfaceExtent))
    -- ^ The concrete current extent every surface reports, or 'Nothing' for
    -- the application to choose.
  , nativeCapture ∷ !(TVar (Maybe DiagnosticCapture))
    -- ^ The session's capture, once the owner's startup has asked the layer
    -- anything.
  , nativeHeld ∷ !(TVar (Set Step))
    -- ^ The steps a 'HoldsUntil' script is holding a call at now.
  }

-- | Wait until a call is holding at this step.
awaitHeld ∷ Rig → Step → IO ()
awaitHeld rig at = atomically (readTVar (nativeHeld (rigNative rig)) >>= check . Set.member at)

-- | Report one error-severity message into the session's capture now, from
-- the calling thread, as a layer reporting from inside some other call would.
reportErrorNow ∷ Rig → ByteString → IO ()
reportErrorNow rig text = sessionCapture rig >>= \capture → report capture severityError text

-- | The same at warning severity; the worker is asked to drain at once.
reportWarningNow ∷ Rig → ByteString → IO ()
reportWarningNow rig text = sessionCapture rig >>= \capture → report capture severityWarning text >> requestDrain capture

-- | Claim the capture's first-failure cell for its sink, as the worker does the
-- moment a delivery's failure returns to it, and publish nothing: the capture
-- is left where a worker paused between its claim and its publication.
claimSinkFirst ∷ Rig → IO ()
claimSinkFirst rig = sessionCapture rig >>= \capture → void (noteSinkFailure (captureUserData capture))

-- The storage's own entry, which the capture's worker calls; linked in with the
-- diagnostics package's C sources.
foreign import ccall unsafe "hetoimasia_capture_note_sink_failure"
  noteSinkFailure ∷ Ptr () → IO CInt

-- | Wait until the capture has recorded its sink's failure.
awaitSinkRecorded ∷ Rig → IO ()
awaitSinkRecorded rig = sessionCapture rig >>= \capture → atomically (captureSinkFailure capture >>= check . isJust)

sessionCapture ∷ Rig → IO DiagnosticCapture
sessionCapture rig =
  readTVarIO (nativeCapture (rigNative rig))
    >>= maybe (throwIO (StandInFailure "the session has no capture yet")) pure

-- | Have every surface report this concrete current extent from now on, or
-- leave the extent to the application.
offerExtent ∷ Rig → Maybe SurfaceExtent → IO ()
offerExtent rig extent = atomically (writeTVar (nativeCurrentExtent (rigNative rig)) extent)

scriptNative ∷ Rig → Step → Scripted → IO ()
scriptNative rig at scripted = atomically (modifyTVar' (nativeScript (rigNative rig)) (Map.insert at scripted))

-- | Declare a surface the stand-in device's queue family cannot present to.
declareUnsupported ∷ Rig → Word64 → IO ()
declareUnsupported rig surface = atomically (modifyTVar' (nativeUnsupported (rigNative rig)) (Set.insert surface))

stepWith ∷ DiagnosticCapture → Journal → Native → Step → Event → IO ()
stepWith capture events native at event = do
  scripted ← Map.lookup at <$> readTVarIO (nativeScript native)
  case scripted of
    Just (HoldsUntil gate) → uninterruptibleMask_ $ do
      atomically (modifyTVar' (nativeHeld native) (Set.insert at))
      atomically (readTVar gate >>= check)
      atomically (modifyTVar' (nativeHeld native) (Set.delete at))
    Just (ReportsError text) → report capture severityError text
    Just (ReportsWarning text) → report capture severityWarning text
    _ → pure ()
  record events event
  case scripted of
    Just Fails → throwIO (StandInFailure (Text.pack (show at)))
    Just Loses → throwIO (StandInLoss (Text.pack (show at)))
    Just LosesSurface → throwIO (StandInSurfaceLost (Text.pack (show at)))
    _ → pure ()

-- | The message identifier every report the stand-in injects carries, so an
-- example can tell it from anything else the capture received.
injectedMessageId ∷ ByteString
injectedMessageId = "VUID-hetoimasia-stand-in-injected"

severityError, severityWarning ∷ Word32
severityError = 0x1000
severityWarning = 0x100

foreign import ccall "dynamic"
  callMessenger ∷ FunPtr (Word32 → Word32 → Ptr () → Ptr () → IO Word32) → Word32 → Word32 → Ptr () → Ptr () → IO Word32

-- | Report one validation message into the capture through the production C
-- callback, as the validation layer does from inside a Vulkan call: the
-- record is copied, and an error latched, exactly as a native report is.
report ∷ DiagnosticCapture → Word32 → ByteString → IO ()
report capture severity text =
  withCStruct payload $ \pointer →
    void (callMessenger (castFunPtr captureMessengerCallback) severity 0x2 (castPtr pointer) (captureUserData capture))
  where
    payload =
      DebugUtilsMessengerCallbackDataEXT
        { next = ()
        , flags = zero
        , messageIdName = Just injectedMessageId
        , messageIdNumber = 0
        , message = Just text
        , queueLabels = Vector.empty
        , cmdBufLabels = Vector.empty
        , objects = Vector.empty
        }
        ∷ DebugUtilsMessengerCallbackDataEXT '[]

-- | The stand-in native layer. The instance is 1, the messenger 2 and the
-- device 3; one device, one queue family, presenting to every surface but the
-- ones declared unsupported.
nativeLayer ∷ Journal → Native → DiagnosticCapture → RootOps Quiesced Int Int Text Int
nativeLayer events native capture =
  RootOps
    { opsInstanceOffer = do
        atomically (writeTVar (nativeCapture native) (Just capture))
        pure
          InstanceOffer
            { offerLoaderVersion = packApiVersion 1 3 296
            , offerInstanceExtensions =
                ["VK_KHR_surface", "VK_KHR_wayland_surface", debugUtilsExtension, getSurfaceCapabilities2Extension, surfaceMaintenance1Extension]
            , offerLayers = []
            , offerLayerExtensions = []
            }
    , opsCreateInstance = \_ → 1 <$ step events native AtCreateInstance InstanceCreated
    , opsCreateMessenger = \_ → 2 <$ step events native AtCreateMessenger MessengerCreated
    , opsDestroyMessenger = \_ _ → step events native AtDestroyMessenger MessengerDestroyed
    , -- The destruction's return is the capture's quiescence evidence, as the
      -- production layer's is.
      opsDestroyInstance = \_ → afterLastCallback capture (step events native AtDestroyInstance InstanceDestroyed)
    , opsDeviceOffers = \_ surface → do
        step events native AtQueryDevices (DevicesQueried surface)
        unsupported ← readTVarIO (nativeUnsupported native)
        pure
          [ DeviceOffer
              { offerDevice = "stand-in device"
              , offerDeviceName = "stand-in device"
              , offerDeviceApiVersion = packApiVersion 1 3 0
              , offerDeviceExtensions = [swapchainExtension, swapchainMaintenance1Extension]
              , offerDynamicRendering = True
              , offerSynchronization2 = True
              , offerSwapchainMaintenance1 = True
              , offerQueueFamilies = [QueueFamilyOffer 0 True (surface `Set.notMember` unsupported)]
              }
          ]
    , opsCreateDevice = \_ plan → 3 <$ (planQueueFamily plan `seq` step events native AtCreateDevice DeviceCreated)
    , opsDestroyDevice = \_ → step events native AtDestroyDevice DeviceDestroyed
    , opsSurfaceSupport = \_ _ _ surface → do
        step events native AtSupport (SupportQueried surface)
        Set.notMember surface <$> readTVarIO (nativeUnsupported native)
    , opsDeviceLoss = \failure → isJust (fromException failure ∷ Maybe StandInLoss)
    , opsNativeFailure = \failure → FailedSurfaceLost <$ (fromException failure ∷ Maybe StandInSurfaceLost)
    , -- The stand-in device offers no naming, so nothing is named and its
      -- queue is never asked for.
      opsDeviceHandle = fromIntegral
    , opsDeviceQueue = \_ _ → pure 4
    , opsInstrumentation = \_ → pure Nothing
    , opsGenerations =
        GenerationOps
          { opsSurfaceOffer = \_ _ → do
              current ← readTVarIO (nativeCurrentExtent native)
              pure
                SurfaceOffer
                  { offerCapabilities =
                      SurfaceCapabilities
                        { capabilityMinImages = 2
                        , capabilityMaxImages = 3
                        , capabilityCurrentExtent = current
                        , capabilityMinExtent = SurfaceExtent 1 1
                        , capabilityMaxExtent = SurfaceExtent 16384 16384
                        , capabilityUsage = imageUsageColorAttachment
                        , capabilityCurrentTransform = 1
                        , capabilityCompositeAlpha = compositeAlphaOpaque
                        }
                  , offerFormats = [SurfaceFormat formatB8G8R8A8Srgb colorSpaceSrgbNonlinear]
                  , offerPresentModes = [presentModeFifo]
                  }
          , opsCreateSwapchain = \_ request → do
              handle ← fresh
              let extent = planExtent (requestPlan request)
              handle <$ step events native AtCreateSwapchain (SwapchainCreated handle (extentWidth extent, extentHeight extent) (requestOldSwapchain request))
          , opsSwapchainImages = \_ swapchain → pure [swapchain * 10 + index | index ← [0 .. 2]]
          , opsCreateImageView = \_ _ _ → do
              handle ← fresh
              handle <$ record events (ViewCreated handle)
          , opsDestroyImageView = \_ view → record events (ViewDestroyed view)
          , opsDestroySwapchain = \_ swapchain → record events (SwapchainDestroyed swapchain)
          }
    }
  where
    fresh = atomically (stateTVar (nativeHandles native) (\next → (next, next + 1)))
    step = stepWith capture

-- ---------------------------------------------------------------------------
-- The surface bridge

-- | How the stand-in bridge treats one surface, by its number. Surfaces are
-- numbered from 100 in the order they are created.
data SurfaceScript
  = CreateUnusable
    -- ^ Created, then handed back as its obligation alone.
  | CreateFails
    -- ^ Nothing is created.
  | CreateHolds !(TVar Bool)
    -- ^ Created once released, uninterruptibly as the native call is.
  | DestroyFails
    -- ^ Its destruction raises.
  | DestroyHolds !(TVar Bool)
    -- ^ Its destruction holds until released.
  | CreateReusing !Word64
    -- ^ Created with the handle an earlier surface had, as a driver may reuse
    -- one: a distinct obligation under the same handle.

data Lease = Lease
  { leaseAdmitting ∷ !(TVar Bool)
  , leaseInFlight ∷ !(TVar Int)
  , leaseOwed ∷ !(TVar (Map Word64 Obligation))
  }

data Obligation = Obligation
  { obligationKey ∷ !Word64
    -- ^ Its number in creation order, which scripts it; unique.
  , obligationSurface ∷ !Word64
    -- ^ Its handle.
  , obligationTarget ∷ !AttachmentId
  , obligationState ∷ !(TVar ObligationState)
  }

data ObligationState = Owed | Gone | Uncertain
  deriving (Eq, Show)

data Bridge = Bridge
  { bridgeScripts ∷ !(TVar (Map Word64 [SurfaceScript]))
  , bridgeRaiseAfterAttach ∷ !(TVar (Maybe SomeException))
    -- ^ Raised once by the next attach, after the host has published it: an
    -- answer lost between the attachment's publication and its caller.
  , bridgeNext ∷ !(TVar Word64)
  , bridgeLeases ∷ !(TVar [Lease])
  }

-- | Run this on the main thread right after the owner's full port refuses a
-- handover's announcement, before the handover answers.
afterRefusal ∷ Rig → (AttachmentId → IO ()) → IO ()
afterRefusal rig action = atomically (writeTVar (rigAfterRefusal rig) action)

-- | Have the next attach raise this, once, after the host has published it.
raiseAfterAttach ∷ Rig → SomeException → IO ()
raiseAfterAttach rig failure = atomically (writeTVar (bridgeRaiseAfterAttach (rigBridge rig)) (Just failure))

scriptSurface ∷ Rig → Word64 → SurfaceScript → IO ()
scriptSurface rig surface scripted =
  atomically (modifyTVar' (bridgeScripts (rigBridge rig)) (Map.insertWith (<>) surface [scripted]))

-- | What releasing the one lease the owner took would answer now, without
-- closing it. 'Nothing' before the owner has leased an instance.
bridgeLeaseAnswer ∷ Rig → STM (Maybe LeaseAnswer)
bridgeLeaseAnswer rig =
  readTVar (bridgeLeases (rigBridge rig)) >>= \case
    lease : _ → Just <$> standing lease
    [] → pure Nothing

standing ∷ Lease → STM LeaseAnswer
standing lease = do
  inFlight ← readTVar (leaseInFlight lease)
  owed ← readTVar (leaseOwed lease)
  pure $
    if inFlight > 0
      then LeaseInFlight
      else if Map.null owed then LeaseReleasable else LeaseOwed

surfaceBridge ∷ Journal → Bridge → SurfaceBridge Lease Obligation
surfaceBridge events bridge =
  SurfaceBridge
    { bridgeLease = \_ → do
        lease ← Lease <$> newTVarIO True <*> newTVarIO 0 <*> newTVarIO Map.empty
        atomically (modifyTVar' (bridgeLeases bridge) (lease :))
        pure lease
    , bridgeAttach = \host window build → do
        -- The production bridge knows its attachment through its access; the
        -- stand-in learns it from the construction step it wraps.
        cell ← newIORef Nothing
        let protocol = build (\lease → readIORef cell >>= maybe (throwIO (StandInFailure "a surface was created outside a construction step")) (\attachment → create attachment lease))
        answered ← attachWindowGraphics host window protocol {protocolConstruct = \attachment acknowledgement → writeIORef cell (Just attachment) >> protocolConstruct protocol attachment acknowledgement}
        atomically (stateTVar (bridgeRaiseAfterAttach bridge) (\pending → (pending, Nothing))) >>= maybe (pure answered) throwIO
    , -- The replacement's admission is the GLFW package's own, over the
      -- seam's loader-aware session and protected host: only the
      -- acknowledgement's attachment, active, with its window not closing.
      -- What it creates is the stand-in's.
      bridgeReplace = \host acknowledgement lease →
        replaceWindowSurface host acknowledgement (\_ → create (acknowledgedAttachment acknowledgement) lease) >>= \case
          ReplacementRan created → pure (Right created)
          ReplacementRefused refusal → pure (Left (Text.pack (show refusal)))
    , bridgeObligations = \lease → Map.elems <$> readTVar (leaseOwed lease)
    , bridgeObligationAttachment = obligationTarget
    , bridgeObligationHandle = obligationSurface
    , bridgeSameObligation = \left right → obligationKey left == obligationKey right
    , bridgeDischarge = discharge
    , bridgeRelease = \lease → writeTVar (leaseAdmitting lease) False >> standing lease
    }
  where
    scriptsFor surface = Map.findWithDefault [] surface <$> readTVarIO (bridgeScripts bridge)
    create attachment lease = do
      admitted ← atomically $ do
        open ← readTVar (leaseAdmitting lease)
        if open
          then do
            modifyTVar' (leaseInFlight lease) (+ 1)
            Just <$> stateTVar (bridgeNext bridge) (\next → (next, next + 1))
          else pure Nothing
      case admitted of
        Nothing → pure (CreationFailed "the lease has begun releasing")
        Just surface → do
          scripted ← scriptsFor surface
          uninterruptibleMask_ $ do
            sequence_ [atomically (readTVar gate >>= check) | CreateHolds gate ← scripted]
            if any isCreateFails scripted
              then do
                atomically (modifyTVar' (leaseInFlight lease) (subtract 1))
                pure (CreationFailed "scripted")
              else do
                let handle = last (surface : [reused | CreateReusing reused ← scripted])
                record events (SurfaceCreated handle)
                obligation ← Obligation surface handle attachment <$> newTVarIO Owed
                atomically $ do
                  modifyTVar' (leaseOwed lease) (Map.insert surface obligation)
                  modifyTVar' (leaseInFlight lease) (subtract 1)
                pure $
                  if any isCreateUnusable scripted
                    then CreatedUnusable obligation "scripted"
                    else CreatedLive obligation
    discharge obligation = uninterruptibleMask_ $ do
      claimed ← atomically $
        readTVar (obligationState obligation) >>= \case
          Owed → pure True
          _ → pure False
      stateNow ← readTVarIO (obligationState obligation)
      if not claimed
        then case stateNow of
          Gone → pure DischargeDone
          _ → either DischargeStillUncertain (\() → DischargeDone) <$> tryWithContext (throwIO (StandInFailure "an earlier destruction did not complete"))
        else do
          scripted ← scriptsFor (obligationKey obligation)
          sequence_
            [ record events (SurfaceDestroyStarted (obligationSurface obligation)) >> atomically (readTVar gate >>= check)
            | DestroyHolds gate ← scripted
            ]
          record events (SurfaceDestroyed (obligationSurface obligation))
          if any isDestroyFails scripted
            then do
              atomically (writeTVar (obligationState obligation) Uncertain)
              uncertain "scripted"
            else do
              atomically $ do
                writeTVar (obligationState obligation) Gone
                leases ← readTVar (bridgeLeases bridge)
                mapM_ (\lease → modifyTVar' (leaseOwed lease) (Map.delete (obligationKey obligation))) leases
              pure DischargeDone
    uncertain reason = either DischargeUncertain (\() → DischargeDone) <$> tryWithContext (throwIO (StandInFailure reason))
    isCreateFails = \case
      CreateFails → True
      _ → False
    isCreateUnusable = \case
      CreateUnusable → True
      _ → False
    isDestroyFails = \case
      DestroyFails → True
      _ → False


-- ---------------------------------------------------------------------------
-- The rendering layers

-- | The stand-in frames' and recording's native layers.
--
-- Every swapchain has three images. An acquisition takes the lowest one the
-- application does not own and the presentation engine does not hold, and
-- answers not ready when there is none. A submission's fence and a present
-- fence are pending until asked: each then answers signalled if the example
-- lets that kind complete ('submissionsComplete', 'presentationsRetire'),
-- which both do by default, and a present fence that signalled gives its image
-- back to the swapchain. Each call is journalled with the thread that made it.
data Rendering = Rendering
  { renderingHandles ∷ !(TVar Word64)
    -- ^ The next fence, semaphore, pool or command buffer, from 9000.
  , renderingFences ∷ !(TVar (Map Word64 FenceKind))
  , renderingBusy ∷ !(TVar (Map Word64 (Set Word32)))
    -- ^ Per swapchain, the images the application owns or the presentation
    -- engine holds.
  , renderingPresented ∷ !(TVar (Map Word64 (Word64, Word32)))
    -- ^ Each pending present fence's swapchain and image.
  , renderingSubmissions ∷ !(TVar Bool)
  , renderingPresentations ∷ !(TVar Bool)
  , renderingStatus ∷ !(TVar PresentStatus)
  , renderingAdvance ∷ !(TVar (Maybe Integer))
    -- ^ Milliseconds every presentation and every fence query moves the
    -- scripted clock on, as a slow native call would.
  , renderingHold ∷ !(TVar (Maybe (TVar Bool)))
    -- ^ When set, every acquisition holds until the gate opens.
  , renderingHolding ∷ !(TVar Bool)
    -- ^ Whether an acquisition is holding now.
  , renderingStalled ∷ !(TVar (Set Word64))
    -- ^ Swapchains whose acquisitions always answer not ready.
  , renderingRaise ∷ !(TVar (Maybe SomeException))
    -- ^ Raised, once, by the next presentation, after its entry is written.
  , renderingRetireCount ∷ !(TVar (Maybe Int))
    -- ^ When set, how many more present fences may answer signalled.
  , renderingStale ∷ !(TVar (Maybe (TVar (Maybe SurfaceExtent))))
    -- ^ When set, the extent the surfaces report: a presentation to a
    -- swapchain built at another extent answers suboptimal.
  }

data FenceKind = FenceIdle | FenceSubmission | FencePresent | FenceDone
  deriving (Eq, Show)

newRendering ∷ IO Rendering
newRendering =
  Rendering
    <$> newTVarIO 9000
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO True
    <*> newTVarIO True
    <*> newTVarIO PresentStatusSuccess
    <*> newTVarIO Nothing
    <*> newTVarIO Nothing
    <*> newTVarIO False
    <*> newTVarIO Set.empty
    <*> newTVarIO Nothing
    <*> newTVarIO Nothing
    <*> newTVarIO Nothing

-- | Whether a submission's fence answers signalled when it is next asked.
submissionsComplete ∷ Rig → Bool → IO ()
submissionsComplete rig = atomically . writeTVar (renderingSubmissions (rigRendering rig))

-- | Whether a present fence answers signalled when it is next asked.
presentationsRetire ∷ Rig → Bool → IO ()
presentationsRetire rig = atomically . writeTVar (renderingPresentations (rigRendering rig))

-- | What every later presentation writes for its swapchain.
scriptPresentStatus ∷ Rig → PresentStatus → IO ()
scriptPresentStatus rig = atomically . writeTVar (renderingStatus (rigRendering rig))

-- | Have every later presentation and fence query move the scripted clock on
-- by this many milliseconds, as a slow call would, or stop doing so.
slowNativeCalls ∷ Rig → Maybe Integer → IO ()
slowNativeCalls rig = atomically . writeTVar (renderingAdvance (rigRendering rig))

-- | Hold every later acquisition until the gate opens, and answer a
-- transaction that says whether one is holding now.
holdAcquisitions ∷ Rig → TVar Bool → IO (STM Bool)
holdAcquisitions rig gate = do
  atomically (writeTVar (renderingHold (rigRendering rig)) (Just gate))
  pure (readTVar (renderingHolding (rigRendering rig)))

-- | Answer not ready to every later acquisition from this swapchain.
stallSwapchain ∷ Rig → Word64 → IO ()
stallSwapchain rig swapchain = atomically (modifyTVar' (renderingStalled (rigRendering rig)) (Set.insert swapchain))

-- | Have the next presentation raise this, once, after writing its entry.
raiseOnPresent ∷ Rig → SomeException → IO ()
raiseOnPresent rig failure = atomically (writeTVar (renderingRaise (rigRendering rig)) (Just failure))

-- | Have every later presentation answer suboptimal while its swapchain was
-- built at another extent than the surfaces report now, as MoltenVK's do while
-- a window is resized, and what 'scriptPresentStatus' says otherwise.
suboptimalWhileStale ∷ Rig → IO ()
suboptimalWhileStale rig = atomically (writeTVar (renderingStale (rigRendering rig)) (Just (nativeCurrentExtent (rigNative rig))))

-- | How many swapchains have been created.
swapchainsCreated ∷ Rig → IO Int
swapchainsCreated rig = length . filter created <$> journal rig
  where
    created = \case
      SwapchainCreated {} → True
      _ → False

-- | Every frame event the owner reported, oldest first.
frameEvents ∷ Rig → IO [FrameEvent]
frameEvents rig = readTVarIO (rigFrameEvents rig)

-- | How many fence queries the frames have made.
fenceQueries ∷ Rig → IO Int
fenceQueries rig = length . filter isQuery <$> journal rig
  where
    isQuery = \case
      FenceQueried _ → True
      _ → False

-- | How many presentations have been made to this attachment's target.
presentsOf ∷ Rig → AttachmentId → IO Int
presentsOf rig = atomically . presentsNow rig

-- | The owner's completed rounds at each presentation, oldest first.
presentRounds ∷ Rig → IO [Natural]
presentRounds = readTVarIO . rigPresentRounds

-- | Wait until this attachment's target has had this many presentations.
awaitPresents ∷ Rig → AttachmentId → Int → IO ()
awaitPresents rig attachment count = atomically (presentsNow rig attachment >>= check . (>= count))

presentsNow ∷ Rig → AttachmentId → STM Int
presentsNow rig attachment = length . filter presented <$> readTVar (rigFrameEvents rig)
  where
    presented = \case
      FramePresented at _ _ _ → at == attachment
      _ → False

-- | Let only the next this many present fences asked answer signalled, and no
-- later one, whatever 'presentationsRetire' says; or, given 'Nothing', every
-- one 'presentationsRetire' allows.
retireNextPresentations ∷ Rig → Maybe Int → IO ()
retireNextPresentations rig = atomically . writeTVar (renderingRetireCount (rigRendering rig))

renderingLayers ∷ Journal → Rendering → Maybe (TVar Instant) → RenderingOps Text Int Word64
renderingLayers events rendering clock =
  RenderingOps
    { renderingRecordingOps = \_ → pure recordingLayer
    , renderingFrameOps = frameLayer
    }
  where
    fresh = atomically (stateTVar (renderingHandles rendering) (\next → (next, next + 1)))
    fence handle kind = atomically (modifyTVar' (renderingFences rendering) (Map.insert handle kind))
    recordingLayer =
      RecordingOps
        { opsCreatePipelineLayout = \_ → fresh
        , opsDestroyPipelineLayout = \_ _ → pure ()
        , opsCreatePipeline = \_ _ _ → fresh
        , opsDestroyPipeline = \_ _ → pure ()
        , opsCreateStorage = \_ _ → (,) <$> fresh <*> fresh
        , opsResetStorage = \_ _ → pure ()
        , opsDestroyStorage = \_ _ → pure ()
        , opsCreateReadback = \_ _ → throwIO (StandInFailure "the stand-in makes no readback")
        , opsDestroyReadback = \_ _ → pure ()
        , opsInvalidate = \_ _ _ → pure ()
        , opsFlush = \_ _ _ → pure ()
        , opsReadMapped = \_ _ _ → pure mempty
        , opsWriteMapped = \_ _ _ → pure ()
        , opsBeginCommands = \_ → pure ()
        , opsEndCommands = \_ → pure ()
        , opsRecord = \_ _ → pure ()
        , opsCommandBufferHandle = id
        }
    frameLayer =
      FrameOps
        { opsCreateSemaphore = \_ → fresh
        , opsDestroySemaphore = \_ _ → pure ()
        , opsCreateFence = \_ → do
            handle ← fresh
            handle <$ fence handle FenceIdle
        , opsDestroyFence = \_ handle → atomically (modifyTVar' (renderingFences rendering) (Map.delete handle))
        , opsResetFence = \_ handle → fence handle FenceIdle
        , opsFenceSignalled = \_ handle → do
            record events (FenceQueried handle)
            slow
            atomically $ do
              kind ← Map.lookup handle <$> readTVar (renderingFences rendering)
              submissions ← readTVar (renderingSubmissions rendering)
              presentations ← readTVar (renderingPresentations rendering)
              counted ← readTVar (renderingRetireCount rendering)
              case kind of
                Just FenceDone → pure True
                Just FenceSubmission | submissions → True <$ modifyTVar' (renderingFences rendering) (Map.insert handle FenceDone)
                Just FencePresent | presentations && maybe True (> 0) counted → do
                  writeTVar (renderingRetireCount rendering) (subtract 1 <$> counted)
                  modifyTVar' (renderingFences rendering) (Map.insert handle FenceDone)
                  held ← Map.lookup handle <$> readTVar (renderingPresented rendering)
                  for_ held $ \(swapchain, index) → do
                    modifyTVar' (renderingPresented rendering) (Map.delete handle)
                    modifyTVar' (renderingBusy rendering) (Map.adjust (Set.delete index) swapchain)
                  pure True
                _ → pure False
        , opsAcquireImage = \_ swapchain _ → do
            readTVarIO (renderingHold rendering) >>= \case
              Nothing → pure ()
              Just gate → uninterruptibleMask_ $ do
                atomically (writeTVar (renderingHolding rendering) True)
                atomically (readTVar gate >>= check)
                atomically (writeTVar (renderingHolding rendering) False)
            taken ← atomically $ do
              busy ← Map.findWithDefault Set.empty swapchain <$> readTVar (renderingBusy rendering)
              stalled ← Set.member swapchain <$> readTVar (renderingStalled rendering)
              case [index | not stalled, index ← [0 .. 2], Set.notMember index busy] of
                index : _ → Just index <$ modifyTVar' (renderingBusy rendering) (Map.insert swapchain (Set.insert index busy))
                [] → pure Nothing
            case taken of
              Just index → AcquiredIndex index <$ record events (ImageAcquired swapchain index)
              Nothing → pure AcquiringNotReady
        , opsSubmit = \_ _ _ handle → do
            fence handle FenceSubmission
            record events (QueueSubmitted handle)
        , opsNoEffect = const False
        , opsReleaseImages = \_ swapchain indices → do
            atomically (modifyTVar' (renderingBusy rendering) (Map.adjust (\held → foldr Set.delete held indices) swapchain))
            record events (ImageReleased swapchain indices)
        , opsPresent = \_ _ request status → do
            answer ← stale (presentSwapchain request) >>= maybe (readTVarIO (renderingStatus rendering)) pure
            writeIORef status answer
            fence (presentFence request) FencePresent
            atomically (modifyTVar' (renderingPresented rendering) (Map.insert (presentFence request) (presentSwapchain request, presentIndex request)))
            record events (ImagePresented (presentSwapchain request) (presentIndex request))
            slow
            atomically (stateTVar (renderingRaise rendering) (\pending → (pending, Nothing))) >>= maybe (pure ()) throwIO
        , opsWaitFence = \_ handle _ → atomically ((== Just FenceDone) . Map.lookup handle <$> readTVar (renderingFences rendering))
        }

    stale swapchain =
      readTVarIO (renderingStale rendering) >>= \case
        Nothing → pure Nothing
        Just current → do
          reported ← readTVarIO current
          built ← readTVarIO events
          pure $ case (reported, [size | (_, SwapchainCreated handle size _) ← built, handle == swapchain]) of
            (Just (SurfaceExtent width height), size : _) | size /= (width, height) → Just PresentStatusSuboptimal
            _ → Nothing
    slow = do
      advance ← readTVarIO (renderingAdvance rendering)
      for_ ((,) <$> advance <*> clock) $ \(milliseconds, cell) →
        atomically (modifyTVar' cell (\now → either (const now) id (addDuration now (millisecondsOf milliseconds))))

millisecondsOf ∷ Integer → Duration
millisecondsOf milliseconds = either (error . show) id (durationFromNanoseconds AllowZero (milliseconds * 1000000))

-- ---------------------------------------------------------------------------
-- The rig

type Scene = ()

-- | Everything an example needs to run one Vulkan graphics host.
data Rig = Rig
  { rigSeam ∷ !Seam
  , rigJournal ∷ !Journal
  , rigNative ∷ !Native
  , rigBridge ∷ !Bridge
  , rigHostConfig ∷ !HostConfig
  , rigOwner ∷ !(TVar (Maybe (GraphicsOwner Scene)))
  , rigVerdict ∷ !(TVar (Maybe DiagnosticVerdict))
  , rigPortCapacity ∷ !(Maybe Int)
    -- ^ The owner's lifetime port capacity, when an example narrows it.
  , rigAfterRefusal ∷ !(TVar (AttachmentId → IO ()))
    -- ^ What runs on the main thread right after the owner's full port
    -- refuses a handover's announcement.
  , rigFramebuffer ∷ !(TVar (Int, Int))
    -- ^ What every window's framebuffer size query answers.
  , rigNudges ∷ !(TVar Natural)
    -- ^ How many times 'nudgeOwner' has republished an observation.
  , rigCapture ∷ !CaptureConfig
    -- ^ The session's capture limits, when an example narrows them.
  , rigSinkFailing ∷ !(TVar Bool)
    -- ^ Whether the capture's sink raises on the records it is given.
  , rigSinkFailed ∷ !(TVar Bool)
    -- ^ Whether it has raised.
  , rigRendering ∷ !Rendering
  , rigFrameEvents ∷ !(TVar [FrameEvent])
  , rigPresentRounds ∷ !(TVar [Natural])
    -- ^ For every presentation, oldest first, the owner's completed rounds at
    -- the instant it was reported: the round that made it is the next one.
  , rigClock ∷ !(Maybe (TVar Instant))
    -- ^ The scripted clock the host and the owner read, when the example
    -- scripts one: it moves only when the example moves it, and the owner's
    -- timer expires only when it has passed the instant it was armed for.
  , rigArmings ∷ !(TVar [Duration])
    -- ^ Every duration the owner armed its timer for, with a scripted clock.
  , rigPumpHold ∷ !(TVar Bool)
    -- ^ While set, the native event wait holds, whatever wakes it, as a
    -- platform modal loop inside it does.
  , rigPumpHeld ∷ !(TVar Bool)
    -- ^ Whether the wait is holding now.
  , rigVisible ∷ !(TVar Bool)
    -- ^ What every window's visibility query answers.
  }

-- | Make the capture's sink raise on every record it is given from now on.
failingSink ∷ Rig → IO ()
failingSink rig = atomically (writeTVar (rigSinkFailing rig) True)

-- | Whether the capture's sink has raised.
sinkHasFailed ∷ Rig → STM Bool
sinkHasFailed = readTVar . rigSinkFailed

-- | A rig over one hidden window.
newRig ∷ IO Rig
newRig = newRigWith [hiddenTestWindowConfig "first" 64 48]

-- | A rig over two hidden windows.
twoWindows ∷ IO Rig
twoWindows = newRigOf 2

-- | A rig over this many hidden windows.
newRigOf ∷ Int → IO Rig
newRigOf count = newRigWith [hiddenTestWindowConfig (Text.pack ("window " <> show number)) 64 48 | number ← [1 .. count]]

-- | How many surface creations the bridge has admitted, held ones included.
creationsBegun ∷ Rig → STM Word64
creationsBegun rig = subtract 100 <$> readTVar (bridgeNext (rigBridge rig))

-- | A rig over one window the seam reports visible, with a 640 by 480
-- framebuffer, so its target is eligible to render and its generations are
-- built.
visibleRig ∷ IO Rig
visibleRig = newRigVisible True [hiddenTestWindowConfig "visible" 64 48]

-- | A rig over this many windows the seam reports visible, each with a 640 by
-- 480 framebuffer.
visibleRigOf ∷ Int → IO Rig
visibleRigOf count = newRigVisible True [hiddenTestWindowConfig (Text.pack ("visible " <> show number)) 64 48 | number ← [1 .. count]]

-- | Change what the window's framebuffer size query answers, and resize it
-- through the host's command port, from the calling thread, so the owner loop
-- samples and publishes the new framebuffer. The loop must be turning.
resizeFramebuffer ∷ Rig → VulkanHost Scene → WindowId → (Int, Int) → IO ()
resizeFramebuffer rig host window (width, height) = do
  atomically (writeTVar (rigFramebuffer rig) (width, height))
  awaitSubmitWindowCommand (hostCommandPort (vulkanWindowHost host)) [("client", "integration-tests")] (setWindowSizeCommand window (Extent width height)) >>= \case
    WaitAccepted _ → pure ()
    WaitClosed → throwIO (StandInFailure "the host's command port closed")

-- | Publish the window's latest observation for its target to the owner, as
-- an application that drives its own loop does; 'runVulkanOwnerLoop' does it
-- every turn for one that runs the composed loop.
publishObservation ∷ VulkanHost Scene → GraphicsService → WindowId → IO ()
publishObservation host service window = do
  client ← atomically (hostWindowClient (vulkanWindowHost host) window) >>= maybe (throwIO (StandInFailure "the window has no client")) pure
  observation ← preparedValue . observedValue <$> atomically (readSnapshot (clientObservations client))
  -- The attachment's revisions start after the slot's initial zero, and rise
  -- with the window's own.
  void (publishGraphicsObservation (vulkanGraphicsOwner host) service (observedRevision observation + 1) observation (windowRenderEligibility observation) Nothing)

-- | Republish the window's unchanged observation at a revision above every
-- one published so far, which takes the owner a round. A result reported
-- from another thread wakes nothing, so an example that reports one — as an
-- acquisition or a presentation on the owner's thread would — nudges the
-- owner this way.
nudgeOwner ∷ Rig → VulkanHost Scene → GraphicsService → WindowId → IO ()
nudgeOwner rig host service window = do
  client ← atomically (hostWindowClient (vulkanWindowHost host) window) >>= maybe (throwIO (StandInFailure "the window has no client")) pure
  observation ← preparedValue . observedValue <$> atomically (readSnapshot (clientObservations client))
  bump ← atomically (stateTVar (rigNudges rig) (\held → (held + 1, held + 1)))
  void (publishGraphicsObservation (vulkanGraphicsOwner host) service (observedRevision observation + 1 + bump * 1000) observation (windowRenderEligibility observation) Nothing)

newRigWith ∷ [WindowConfig] → IO Rig
newRigWith = newRigVisible False

newRigVisible ∷ Bool → [WindowConfig] → IO Rig
newRigVisible visible windows = newRigClocked visible windows Nothing

-- | A rig over this many visible windows whose host and owner read a scripted
-- clock, starting at zero.
scriptedRigOf ∷ Int → IO Rig
scriptedRigOf count = do
  clock ← newTVarIO (scriptedInstant zeroDuration)
  newRigClocked True [hiddenTestWindowConfig (Text.pack ("scripted " <> show number)) 64 48 | number ← [1 .. count]] (Just clock)

-- | Move the scripted clock on by this many milliseconds.
advanceClock ∷ Rig → Integer → IO ()
advanceClock rig milliseconds = case rigClock rig of
  Nothing → throwIO (StandInFailure "the rig has no scripted clock")
  Just cell → atomically (modifyTVar' cell (\now → either (const now) id (addDuration now (millisecondsOf milliseconds))))

-- | Set the scripted clock to this instant, which must not be earlier.
setClock ∷ Rig → Instant → IO ()
setClock rig instant = case rigClock rig of
  Nothing → throwIO (StandInFailure "the rig has no scripted clock")
  Just cell → atomically (modifyTVar' cell (max instant))

-- | The scripted clock's instant.
clockNow ∷ Rig → IO Instant
clockNow rig = maybe (throwIO (StandInFailure "the rig has no scripted clock")) readTVarIO (rigClock rig)

-- | Hold the main thread's next native event wait until 'holdPump' is given
-- 'False', as a platform modal loop inside the call would; or release it.
holdPump ∷ Rig → Bool → IO ()
holdPump rig = atomically . writeTVar (rigPumpHold rig)

-- | Whether the main thread is inside a held wait now.
pumpHeld ∷ Rig → STM Bool
pumpHeld = readTVar . rigPumpHeld

-- | Make every window report itself shown or hidden, and show or hide this
-- one through the host's command port so the owner loop samples it again.
-- The loop must be turning.
setVisible ∷ Rig → VulkanHost Scene → WindowId → Bool → IO ()
setVisible rig host window shown = do
  atomically (writeTVar (rigVisible rig) shown)
  awaitSubmitWindowCommand
    (hostCommandPort (vulkanWindowHost host))
    [("client", "integration-tests")]
    ((if shown then showWindowCommand else hideWindowCommand) window)
    >>= \case
      WaitAccepted _ → pure ()
      WaitClosed → throwIO (StandInFailure "the host's command port closed")

newRigClocked ∷ Bool → [WindowConfig] → Maybe (TVar Instant) → IO Rig
newRigClocked visible windows clock = do
  pumpHold ← newTVarIO False
  heldNow ← newTVarIO False
  visibility ← newTVarIO visible
  framebuffer ← newTVarIO (640, 480)
  nudges ← newTVarIO 0
  events ← newTVarIO []
  owner ← newTVarIO Nothing
  posts ← newTVarIO (0 ∷ Int)
  seam ←
    newSeam
      defaultScript
        { -- The finite wait really waits, as GLFW's does: until the session's
          -- own wake posts an empty event, or its bound elapses. A seam whose
          -- wait returned at once would keep the main thread spinning through
          -- every wait, which no native session does.
          scriptWaitEvents = \bound _ → do
            -- A held pump is a modal loop: nothing ends it but the example.
            held ← readTVarIO pumpHold
            when held $ do
              atomically (writeTVar heldNow True)
              atomically (readTVar pumpHold >>= check . not)
              atomically (writeTVar heldNow False)
            expired ← registerDelay (max 1 (round (bound * 1e6)))
            atomically $
              (readTVar posts >>= \pending → if pending <= 0 then retry else writeTVar posts (pending - 1))
                `orElse` (readTVar expired >>= check)
        , scriptPostEmptyEvent = \_ → atomically (modifyTVar' posts (+ 1))
        , scriptDestroyWindow = \_ → do
            -- Whether the owner's worker was joined before this window's
            -- release, read at the release itself.
            joined ←
              readTVarIO owner >>= \case
                Nothing → pure False
                Just graphics → isJust <$> atomically (Worker.pollCompletion (graphicsOwnerWorker graphics))
            record events (WindowGone joined)
        , scriptTerminate = \_ → record events SessionEnded
        , scriptFramebufferSize = \_ → readTVarIO framebuffer
        , scriptWindowAttribute = \attribute _ → (&& attribute == VisibleAttribute) <$> readTVarIO visibility
        }
  native ← Native <$> newTVarIO Map.empty <*> newTVarIO Set.empty <*> newTVarIO 500 <*> newTVarIO Nothing <*> newTVarIO Nothing <*> newTVarIO Set.empty
  bridge ← Bridge <$> newTVarIO Map.empty <*> newTVarIO Nothing <*> newTVarIO 100 <*> newTVarIO []
  verdict ← newTVarIO Nothing
  refusalHook ← newTVarIO (\_ → pure ())
  sinkFailing ← newTVarIO False
  sinkFailed ← newTVarIO False
  rendering ← newRendering
  frameLog ← newTVarIO []
  presentRounds' ← newTVarIO []
  armings ← newTVarIO []
  let defaults = (defaultHostConfig windows) {hostIdleWait = 0.005}
  pure
    Rig
      { rigSeam = seam
      , rigJournal = events
      , rigNative = native
      , rigBridge = bridge
      , rigHostConfig = maybe defaults (\cell → defaults {hostClock = scriptedSource (readTVarIO cell)}) clock
      , rigOwner = owner
      , rigVerdict = verdict
      , rigPortCapacity = Nothing
      , rigAfterRefusal = refusalHook
      , rigFramebuffer = framebuffer
      , rigNudges = nudges
      , rigCapture = defaultCaptureConfig
      , rigSinkFailing = sinkFailing
      , rigSinkFailed = sinkFailed
      , rigRendering = rendering
      , rigFrameEvents = frameLog
      , rigPresentRounds = presentRounds'
      , rigClock = clock
      , rigArmings = armings
      , rigPumpHold = pumpHold
      , rigPumpHeld = heldNow
      , rigVisible = visibility
      }

-- | Run a whole Vulkan graphics host under the application runner, on a bound
-- thread the seam designates as the process main thread.
runRig ∷ Rig → (VulkanHost Scene → RuntimeControl → IO a) → IO a
runRig rig body = asProcessMainThread (rigSeam rig) (runRigHere rig body)

-- | 'runRig', catching on the seam's own thread.
runRigCaught ∷ Rig → (VulkanHost Scene → RuntimeControl → IO a) → IO (Either SomeException a)
runRigCaught rig body = asProcessMainThread (rigSeam rig) (try (runRigHere rig body))

runRigHere ∷ Rig → (VulkanHost Scene → RuntimeControl → IO a) → IO a
runRigHere rig body = do
  integration ← seamIntegration (rigSeam rig) defaultIntegrationScript
  scene ← prepare ()
  budgets ← either (throwIO . StandInFailure . Text.pack . show) pure (validateBudgets defaultBudgetRequest)
  let config =
        (vulkanHostConfig (rigHostConfig rig) (rigCapture rig) budgets scene)
          { vulkanFrameObserver = \event → atomically $ do
              modifyTVar' (rigFrameEvents rig) (<> [event])
              case event of
                FramePresented {} → do
                  owner ← readTVar (rigOwner rig)
                  rounds ← maybe (pure 0) (fmap statusRounds . readOwnerStatusNow) owner
                  modifyTVar' (rigPresentRounds rig) (<> [rounds])
                _ → pure ()
          }
      timed owner = case rigClock rig of
        Nothing → owner
        Just cell →
          owner
            { ownerClockTimer = ownerTimer $ \duration → do
                atomically (modifyTVar' (rigArmings rig) (<> [duration]))
                record (rigJournal rig) OwnerTimerArmed
                start ← readTVarIO cell
                pure $ case addDuration start duration of
                  Left _ → pure False
                  Right due → (`deadlineReached` due) <$> readTVar cell
            }
  runGraphicsOwnerApplication
    (withLoggingLifetime quietLogger)
    "vulkan-controller-example"
    ( \_ use → do
        -- The verdict is kept whichever way the host ends: a failed one
        -- carries it on its failure.
        (result, verdict) ← keepVerdict $
          withVulkanOwnerHostHooked
            (ControllerHooks (\attachment → readTVarIO (rigAfterRefusal rig) >>= ($ attachment)))
            (captureLogger rig)
            (nativeLayer (rigJournal rig) (rigNative rig))
            (renderingLayers (rigJournal rig) (rigRendering rig) (rigClock rig))
            instanceAddress
            (surfaceBridge (rigJournal rig) (rigBridge rig))
            (seamIntegratedSession (rigSeam rig) integration)
            requiredInstanceExtensions
            config {vulkanOwner = \owner → timed (maybe owner (\capacity → owner {ownerEventCapacity = capacity}) (rigPortCapacity rig))}
            (\host → atomically (writeTVar (rigOwner rig) (Just (vulkanGraphicsOwner host))) >> use host)
        atomically (writeTVar (rigVerdict rig) (Just verdict))
        pure result
    )
    vulkanWindowHost
    (\host _ → pure host)
    body
  where
    keepVerdict ∷ IO (b, DiagnosticVerdict) → IO (b, DiagnosticVerdict)
    keepVerdict action =
      tryWithContext action >>= \case
        Right answer → pure answer
        Left failure@(ExceptionWithContext context _) → do
          atomically (writeTVar (rigVerdict rig) (diagnosticVerdictInContext context))
          rethrowIO (failure ∷ ExceptionWithContext SomeException)

-- | The stand-in instance's "handle", a pointer the stand-in bridge never
-- dereferences.
instanceAddress ∷ Int → Ptr ()
instanceAddress handle = nullPtr `plusPtr` handle

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))

-- | The capture's logger: quiet, until the example makes its sink fail.
captureLogger ∷ Rig → Logger
captureLogger rig =
  mkLoggerWith defaultLogFilter systemMetadata . callbackSink $ \_ → do
    failing ← readTVarIO (rigSinkFailing rig)
    when failing $ do
      atomically (writeTVar (rigSinkFailed rig) True)
      throwIO (StandInFailure "the diagnostic sink failed")

-- | Run owner turns on the main thread until the condition holds: an
-- attachment retires on a turn, when the main thread folds what the owner
-- published.
pumpUntil ∷ VulkanHost Scene → RuntimeControl → String → IO Bool → IO ()
pumpUntil host control what ready =
  runOwnerLoop
    (vulkanWindowHost host)
    control
    LoopHooks
      { loopLogger = quietLogger
      , loopEvent = noApplicationEvents
      , loopUpdate = \turn → do
          done ← ready
          if done
            then pure (Finish ())
            else
              if turnNumber turn > 20000
                then throwIO (StandInFailure (Text.pack ("the loop never reached " <> what)))
                else pure Continue
      }

-- | The host's windows, in the order it created them.
windowsOf ∷ VulkanHost Scene → IO [WindowId]
windowsOf host = atomically (hostWindowIdentities (vulkanWindowHost host))

-- | Hand a window over, failing the example unless the owner was told.
--
-- It waits first for the owner to have leased its instance, as an application
-- does: a window offered before that is answered 'VulkanRootsNotReady'.
handedOver ∷ VulkanHost Scene → WindowId → TargetClass → IO GraphicsService
handedOver host window classification = do
  atomically (readReadiness (vulkanController host) >>= check . (/= RootsPending))
  handOverVulkanTarget (vulkanController host) (vulkanWindowHost host) (vulkanGraphicsOwner host) window classification >>= \case
    VulkanTargetHandedOver service → pure service
    other → throwIO (StandInFailure (Text.pack ("the target was not handed over: " <> show other)))

-- | Wait until the owner's construction of this target has settled.
awaitStanding ∷ VulkanHost Scene → GraphicsService → IO TargetStanding
awaitStanding host service = atomically $
  readTargetStanding (vulkanGraphicsOwner host) (graphicsAttachment service) >>= \case
    Just TargetConstructing → retry
    Just settled → pure settled
    Nothing → retry

-- | Wait until the owner has written this target's terminal record.
awaitTerminal ∷ VulkanHost Scene → GraphicsService → IO TerminalRecord
awaitTerminal host service = atomically $
  readTargetTerminalsNow (vulkanGraphicsOwner host) >>= maybe retry pure . Map.lookup (graphicsAttachment service)
