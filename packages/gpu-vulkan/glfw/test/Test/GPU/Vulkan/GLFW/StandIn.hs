-- | Stand-ins for the controller's two native boundaries, and a rig that runs
-- a whole Vulkan graphics host over the GLFW package's scripted seam.
--
-- Everything the controller does natively goes through one of two records —
-- the roots' native layer and the surface bridge — so these stand-ins drive
-- the real controller, the real graphics owner and the real protected host
-- exactly as a native run does, and can be told to fail, report device loss,
-- or hold at any step, which a native run cannot be asked to do on demand.
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

    -- * The native layer
  , Native
  , Step (..)
  , Scripted (..)
  , scriptNative
  , declareUnsupported
  , StandInFailure (..)
  , StandInLoss (..)

    -- * The surface bridge
  , Bridge
  , SurfaceScript (..)
  , scriptSurface
  , bridgeLeaseAnswer

    -- * The rig
  , Rig (..)
  , Scene
  , newRig
  , newRigOf
  , twoWindows
  , creationsBegun
  , runRig
  , runRigCaught
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
import Control.Exception (Exception, SomeException, fromException, throwIO, try, tryWithContext, uninterruptibleMask_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Foreign.Ptr (Ptr, nullPtr, plusPtr)
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLoggerWith, systemMetadata)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import qualified Hetoimasia.Foundation.Worker as Worker
import Hetoimasia.GLFW.Seam
  ( Seam
  , SeamScript (..)
  , asProcessMainThread
  , defaultIntegrationScript
  , defaultScript
  , newSeam
  , seamIntegratedSession
  , seamIntegration
  )
import Hetoimasia.GLFW.Vulkan (requiredInstanceExtensions)
import Hetoimasia.GLFW.Window (WindowConfig, WindowId, hiddenTestWindowConfig)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass)
import Hetoimasia.GPU.Vulkan.Diagnostics (DiagnosticCapture, DiagnosticVerdict, Quiesced, afterLastCallback, defaultCaptureConfig)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Bridge (Created (..), Discharged (..), LeaseAnswer (..), SurfaceBridge (..))
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
  ( VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , Readiness (..)
  , handOverVulkanTarget
  , readReadiness
  , vulkanHostConfig
  , withVulkanOwnerHostOver
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
import Hetoimasia.GPU.Vulkan.Native.Roots (RootOps (..))
import Hetoimasia.Runtime.GLFW
  ( AttachmentId
  , AttachmentProtocol (..)
  , GraphicsOwner
  , GraphicsOwnerConfig (..)
  , GraphicsService
  , HostConfig (..)
  , LoopHooks (..)
  , TargetStanding (..)
  , TerminalRecord
  , Turn (..)
  , TurnStep (..)
  , attachWindowGraphics
  , defaultHostConfig
  , graphicsAttachment
  , graphicsOwnerWorker
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
  | WindowGone !Bool
    -- ^ The seam destroyed a window; whether the graphics owner's worker had
    -- already completed by then.
  | SessionEnded
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
awaitEvent rig event = atomically (readTVar (rigJournal rig) >>= check . elem event . map snd)

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
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What a scripted step does instead of simply succeeding.
data Scripted
  = Fails
    -- ^ Raises 'StandInFailure': neither success nor device loss.
  | Loses
    -- ^ Raises 'StandInLoss', which this layer classifies as device loss.
  | HoldsUntil !(TVar Bool)
    -- ^ Holds, uninterruptibly as a native call does, until released.

newtype StandInFailure = StandInFailure Text
  deriving (Eq, Show)

instance Exception StandInFailure

newtype StandInLoss = StandInLoss Text
  deriving (Eq, Show)

instance Exception StandInLoss

data Native = Native
  { nativeScript ∷ !(TVar (Map Step Scripted))
  , nativeUnsupported ∷ !(TVar (Set Word64))
  }

scriptNative ∷ Rig → Step → Scripted → IO ()
scriptNative rig at scripted = atomically (modifyTVar' (nativeScript (rigNative rig)) (Map.insert at scripted))

-- | Declare a surface the stand-in device's queue family cannot present to.
declareUnsupported ∷ Rig → Word64 → IO ()
declareUnsupported rig surface = atomically (modifyTVar' (nativeUnsupported (rigNative rig)) (Set.insert surface))

step ∷ Journal → Native → Step → Event → IO ()
step events native at event = do
  scripted ← Map.lookup at <$> readTVarIO (nativeScript native)
  case scripted of
    Just (HoldsUntil gate) → uninterruptibleMask_ (atomically (readTVar gate >>= check))
    _ → pure ()
  record events event
  case scripted of
    Just Fails → throwIO (StandInFailure (Text.pack (show at)))
    Just Loses → throwIO (StandInLoss (Text.pack (show at)))
    _ → pure ()

-- | The stand-in native layer. The instance is 1, the messenger 2 and the
-- device 3; one device, one queue family, presenting to every surface but the
-- ones declared unsupported.
nativeLayer ∷ Journal → Native → DiagnosticCapture → RootOps Quiesced Int Int Text Int
nativeLayer events native capture =
  RootOps
    { opsInstanceOffer =
        pure
          InstanceOffer
            { offerLoaderVersion = packApiVersion 1 3 296
            , offerInstanceExtensions =
                ["VK_KHR_surface", "VK_KHR_wayland_surface", debugUtilsExtension, getSurfaceCapabilities2Extension, surfaceMaintenance1Extension]
            , offerLayers = []
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
    }

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

data Lease = Lease
  { leaseAdmitting ∷ !(TVar Bool)
  , leaseInFlight ∷ !(TVar Int)
  , leaseOwed ∷ !(TVar (Map Word64 Obligation))
  }

data Obligation = Obligation
  { obligationSurface ∷ !Word64
  , obligationTarget ∷ !AttachmentId
  , obligationState ∷ !(TVar ObligationState)
  }

data ObligationState = Owed | Gone | Uncertain
  deriving (Eq, Show)

data Bridge = Bridge
  { bridgeScripts ∷ !(TVar (Map Word64 [SurfaceScript]))
  , bridgeNext ∷ !(TVar Word64)
  , bridgeLeases ∷ !(TVar [Lease])
  }

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
        let protocol = build (create cell)
        attachWindowGraphics host window protocol {protocolConstruct = \attachment acknowledgement → writeIORef cell (Just attachment) >> protocolConstruct protocol attachment acknowledgement}
    , bridgeObligations = \lease → Map.elems <$> readTVar (leaseOwed lease)
    , bridgeObligationAttachment = obligationTarget
    , bridgeObligationHandle = obligationSurface
    , bridgeDischarge = discharge
    , bridgeRelease = \lease → writeTVar (leaseAdmitting lease) False >> standing lease
    }
  where
    scriptsFor surface = Map.findWithDefault [] surface <$> readTVarIO (bridgeScripts bridge)
    create cell lease = do
      attachment ← readIORef cell >>= maybe (throwIO (StandInFailure "a surface was created outside a construction step")) pure
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
                record events (SurfaceCreated surface)
                obligation ← Obligation surface attachment <$> newTVarIO Owed
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
          _ → uncertain "an earlier destruction did not complete"
        else do
          scripted ← scriptsFor (obligationSurface obligation)
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
                mapM_ (\lease → modifyTVar' (leaseOwed lease) (Map.delete (obligationSurface obligation))) leases
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
  }

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

newRigWith ∷ [WindowConfig] → IO Rig
newRigWith windows = do
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
        }
  native ← Native <$> newTVarIO Map.empty <*> newTVarIO Set.empty
  bridge ← Bridge <$> newTVarIO Map.empty <*> newTVarIO 100 <*> newTVarIO []
  verdict ← newTVarIO Nothing
  pure
    Rig
      { rigSeam = seam
      , rigJournal = events
      , rigNative = native
      , rigBridge = bridge
      , rigHostConfig = (defaultHostConfig windows) {hostIdleWait = 0.005}
      , rigOwner = owner
      , rigVerdict = verdict
      , rigPortCapacity = Nothing
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
  let config = vulkanHostConfig (rigHostConfig rig) defaultCaptureConfig budgets scene
  runGraphicsOwnerApplication
    (withLoggingLifetime quietLogger)
    "vulkan-controller-example"
    ( \_ use → do
        (result, verdict) ←
          withVulkanOwnerHostOver
            quietLogger
            (nativeLayer (rigJournal rig) (rigNative rig))
            instanceAddress
            (surfaceBridge (rigJournal rig) (rigBridge rig))
            (seamIntegratedSession (rigSeam rig) integration)
            requiredInstanceExtensions
            config {vulkanOwner = \owner → maybe owner (\capacity → owner {ownerEventCapacity = capacity}) (rigPortCapacity rig)}
            (\host → atomically (writeTVar (rigOwner rig) (Just (vulkanGraphicsOwner host))) >> use host)
        atomically (writeTVar (rigVerdict rig) (Just verdict))
        pure result
    )
    vulkanWindowHost
    (\host _ → pure host)
    body

-- | The stand-in instance's "handle", a pointer the stand-in bridge never
-- dereferences.
instanceAddress ∷ Int → Ptr ()
instanceAddress handle = nullPtr `plusPtr` handle

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))

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
