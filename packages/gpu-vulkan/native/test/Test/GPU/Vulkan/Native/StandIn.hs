-- | A stand-in native layer for the roots: every call recorded in order, any
-- step made to fail, to report device loss, or to hold until released.
--
-- It is the same idea as the VK-2 harness's construction examples: the roots'
-- ownership decisions are written once against an open native layer, so a
-- stand-in that can be told to fail its fourth call drives exactly the
-- decisions a native run obeys, which a native run cannot be asked to do on
-- demand. Handles are small numbers, so a record says which object each call
-- touched.
module Test.GPU.Vulkan.Native.StandIn
  ( -- * The stand-in
    StandIn (..)
  , newStandIn
  , standInOps
  , Call (..)
  , calls
  , awaitCall
  , Step (..)
  , Scripted (..)
  , script
  , standInDevice
  , StandInFailure (..)
  , StandInLoss (..)

    -- * Surfaces
  , surfaceNumbered
  , surfaceFailing
  , unsupportedSurface

    -- * Roots over it
  , StandInRoots
  , newStandInRoots
  , standardRequest
  , testBudgets
  ) where

import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO)
import Control.Exception (Exception, fromException, throwIO, tryWithContext, uninterruptibleMask_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Hetoimasia.Foundation.Time (scriptedInstant, scriptedSource, zeroDuration)
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), Budgets, defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Vulkan.Native.Profile
  ( DeviceOffer (..)
  , DevicePlan (..)
  , InstanceOffer (..)
  , InstancePlan (..)
  , InstanceRequest (..)
  , QueueFamilyOffer (..)
  , debugUtilsExtension
  , getSurfaceCapabilities2Extension
  , packApiVersion
  , portabilityEnumerationExtension
  , surfaceMaintenance1Extension
  , swapchainExtension
  , swapchainMaintenance1Extension
  )
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( RootOps (..)
  , Roots
  , SurfaceDestruction (..)
  , TargetSurface (..)
  , newRoots
  )
import qualified Data.Text.Encoding as Encoding

-- | One native call the roots made, in the order they made it.
data Call
  = OfferedInstance
  | CreatedInstance ![Text]
  | CreatedMessenger
  | QueriedDevices !Word64
  | CreatedDevice !Text !Word32
  | QueriedSupport !Word64
  | DestroyedSurface !Word64
  | DestroyedDevice
  | DestroyedMessenger
  | DestroyedInstance
  deriving (Eq, Show)

-- | A step the stand-in can be scripted at.
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

-- | What a scripted step does instead of succeeding.
data Scripted
  = Fails
    -- ^ Raises 'StandInFailure' after recording the call: an outcome that is
    -- neither success nor device loss.
  | Loses
    -- ^ Raises 'StandInLoss', which the stand-in classifies as device loss.
  | HoldsUntil !(TVar Bool)
    -- ^ Blocks until the variable is true, then succeeds.

newtype StandInFailure = StandInFailure Step
  deriving (Eq, Show)

instance Exception StandInFailure

newtype StandInLoss = StandInLoss Step
  deriving (Eq, Show)

instance Exception StandInLoss

data StandIn = StandIn
  { standCalls ∷ !(TVar [Call])
    -- ^ Newest first.
  , standScript ∷ !(TVar (Map Step Scripted))
  , standOffers ∷ ![DeviceOffer Text]
  , standLoaderVersion ∷ !Word32
  }

newStandIn ∷ IO StandIn
newStandIn = do
  recorded ← newTVarIO []
  scripted ← newTVarIO Map.empty
  pure (StandIn recorded scripted [standInDevice] (packApiVersion 1 3 296))

-- | One device satisfying the whole profile, whose single queue family answers
-- graphics and presentation to every surface but 'unsupportedSurface'.
standInDevice ∷ DeviceOffer Text
standInDevice =
  DeviceOffer
    { offerDevice = "stand-in device"
    , offerDeviceName = "stand-in device"
    , offerDeviceApiVersion = packApiVersion 1 3 0
    , offerDeviceExtensions = [swapchainExtension, swapchainMaintenance1Extension]
    , offerDynamicRendering = True
    , offerSynchronization2 = True
    , offerSwapchainMaintenance1 = True
    , offerQueueFamilies = [QueueFamilyOffer 0 True True]
    }

-- | A surface no queue family of the stand-in device presents to.
unsupportedSurface ∷ Word64
unsupportedSurface = 666

-- | Script one step.
script ∷ StandIn → Step → Scripted → IO ()
script standIn at scripted = atomically (modifyTVar' (standScript standIn) (Map.insert at scripted))

-- | Wait until the stand-in has seen this call.
awaitCall ∷ StandIn → Call → IO ()
awaitCall standIn call = atomically (readTVar (standCalls standIn) >>= check . elem call)

-- | Every call so far, oldest first.
calls ∷ StandIn → IO [Call]
calls standIn = reverse <$> readTVarIO (standCalls standIn)

record ∷ StandIn → Call → IO ()
record standIn call = atomically (modifyTVar' (standCalls standIn) (call :))

-- | Record the call, then do what the step is scripted to do.
step ∷ StandIn → Step → Call → IO ()
step standIn at call = do
  record standIn call
  scripted ← Map.lookup at <$> readTVarIO (standScript standIn)
  case scripted of
    Nothing → pure ()
    Just Fails → throwIO (StandInFailure at)
    Just Loses → throwIO (StandInLoss at)
    -- Held as a native call is: nothing interrupts it part-way, and a
    -- cancellation aimed at its thread meanwhile is delivered once it returns.
    Just (HoldsUntil gate) → uninterruptibleMask_ (atomically (readTVar gate >>= check))

-- | The stand-in's native layer. Handles are numbers: the instance is 1, the
-- messenger 2 and the device 3; a surface is whatever number it was made with.
standInOps ∷ StandIn → RootOps () Int Int Text Int
standInOps standIn =
  RootOps
    { opsInstanceOffer = do
        record standIn OfferedInstance
        pure
          InstanceOffer
            { offerLoaderVersion = standLoaderVersion standIn
            , offerInstanceExtensions =
                [ "VK_KHR_surface"
                , "VK_KHR_stand_in_surface"
                , debugUtilsExtension
                , getSurfaceCapabilities2Extension
                , surfaceMaintenance1Extension
                , portabilityEnumerationExtension
                ]
            , offerLayers = ["VK_LAYER_KHRONOS_validation"]
            }
    , opsCreateInstance = \plan → do
        step standIn AtCreateInstance (CreatedInstance (map decode (planInstanceExtensions plan)))
        pure 1
    , opsCreateMessenger = \_ → 2 <$ step standIn AtCreateMessenger CreatedMessenger
    , opsDestroyMessenger = \_ _ → step standIn AtDestroyMessenger DestroyedMessenger
    , opsDestroyInstance = \_ → step standIn AtDestroyInstance DestroyedInstance
    , opsDeviceOffers = \_ surface → do
        step standIn AtQueryDevices (QueriedDevices surface)
        pure
          [ offer {offerQueueFamilies = [family {familyPresents = familyPresents family && surface /= unsupportedSurface} | family ← offerQueueFamilies offer]}
          | offer ← standOffers standIn
          ]
    , opsCreateDevice = \_ plan → 3 <$ step standIn AtCreateDevice (CreatedDevice (planDeviceName plan) (planQueueFamily plan))
    , opsDestroyDevice = \_ → step standIn AtDestroyDevice DestroyedDevice
    , opsSurfaceSupport = \_ _ _ surface → do
        step standIn AtSupport (QueriedSupport surface)
        pure (surface /= unsupportedSurface)
    , opsDeviceLoss = \failure → isJust (fromException failure ∷ Maybe StandInLoss)
    }
  where
    decode = Encoding.decodeUtf8Lenient

-- | A surface whose destruction the stand-in records and which succeeds.
surfaceNumbered ∷ StandIn → Word64 → TargetSurface
surfaceNumbered standIn handle =
  TargetSurface handle (SurfaceDestroyed <$ record standIn (DestroyedSurface handle))

-- | A surface whose destruction the stand-in records and which raises.
surfaceFailing ∷ StandIn → Word64 → TargetSurface
surfaceFailing standIn handle =
  TargetSurface handle $ do
    record standIn (DestroyedSurface handle)
    either SurfaceDestructionUncertain (\() → SurfaceDestroyed) <$> tryWithContext (throwIO (StandInFailure AtDestroyDevice))

type StandInRoots = Roots () Int Int Text Int

-- | Roots over the stand-in, with a model clock that never moves.
newStandInRoots ∷ StandIn → Budgets → IO StandInRoots
newStandInRoots standIn budgets = newRoots (standInOps standIn) budgets (scriptedSource (pure (scriptedInstant zeroDuration)))

-- | The request a GLFW session on the stand-in platform would make.
standardRequest ∷ InstanceRequest
standardRequest = InstanceRequest ["VK_KHR_surface", "VK_KHR_stand_in_surface"] []

-- | The model's default budgets, with the target-record limit given.
testBudgets ∷ Integer → Budgets
testBudgets records = case validateBudgets defaultBudgetRequest {requestedTargetRecords = records} of
  Right budgets → budgets
  Left rejected → error ("the test budgets were rejected: " <> show rejected)
