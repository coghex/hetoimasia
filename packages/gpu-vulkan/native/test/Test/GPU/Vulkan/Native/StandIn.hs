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

    -- * Naming
  , offerNaming
  , failNaming
  , restoreNaming
  , NamingFailure (..)
  , namesGiven

    -- * Surfaces' presentation
  , standInOffer
  , offerSurface
  , returnImages
  , duringCreation

    -- * Surfaces
  , surfaceNumbered
  , surfaceFailing
  , surfaceThrowing
  , surfaceWaiting
  , unsupportedSurface

    -- * Roots over it
  , StandInRoots
  , newStandInRoots
  , standardRequest
  , testBudgets
  ) where

import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, fromException, throwIO, tryWithContext, uninterruptibleMask_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.ByteString (ByteString)
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
  , validationFeaturesExtension
  , swapchainMaintenance1Extension
  )
import Hetoimasia.GPU.Vulkan.Native.Naming (Instrumentation (..), NativeObjectKind)
import Hetoimasia.GPU.Vulkan.Native.Presentation
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( GenerationOps (..)
  , RootOps (..)
  , Roots
  , SwapchainRequest (..)
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
  | QueriedSurface !Word64
  | CreatedSwapchain !Word64 !Word64 !(Word32, Word32) !(Maybe Word64)
    -- ^ The swapchain made, the surface, the extent, and the swapchain handed
    -- over as @oldSwapchain@.
  | EnumeratedImages !Word64
  | CreatedView !Word64 !Word64
    -- ^ The view made, and the image it views.
  | DestroyedView !Word64
  | DestroyedSwapchain !Word64
  | QueriedQueue !Word32
    -- ^ The device's queue of that family, asked for to name it.
  | Named !NativeObjectKind !Word64 !ByteString
    -- ^ A naming call: the kind, the handle and the name. One that raised is
    -- recorded too, before it raised.
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
  | AtSurfaceOffer
  | AtCreateSwapchain
  | AtSwapchainImages
  | AtCreateView
  | AtDestroyView
  | AtDestroySwapchain
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
  | SucceedsThenFails !Int
    -- ^ Succeeds this many more times, then behaves as 'Fails'.
  | WaitsInterruptibly !(TVar Bool)
    -- ^ Blocks, interruptibly, until the variable is true, then succeeds — so
    -- a cancellation can end the call part-way, leaving its outcome unknown.

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
  , standSurfaceOffer ∷ !(TVar SurfaceOffer)
  , standImages ∷ !(TVar Int)
    -- ^ How many images a swapchain creation returns.
  , standDuring ∷ !(TVar (IO ()))
    -- ^ Run inside the next swapchain creation, once.
  , standHandles ∷ !(TVar Word64)
  , standNaming ∷ !(TVar Bool)
    -- ^ Whether the device offers naming; off unless an example turns it on.
  , standNameFails ∷ !(TVar [NativeObjectKind])
    -- ^ Kinds whose naming raises 'NamingFailure'.
  }

newStandIn ∷ IO StandIn
newStandIn = do
  recorded ← newTVarIO []
  scripted ← newTVarIO Map.empty
  StandIn recorded scripted [standInDevice] (packApiVersion 1 3 296)
    <$> newTVarIO standInOffer
    <*> newTVarIO 3
    <*> newTVarIO (pure ())
    <*> newTVarIO 100
    <*> newTVarIO False
    <*> newTVarIO []

-- | A surface that supplies a concrete 640 by 480 extent and offers the
-- profile's BGRA sRGB format, FIFO, color attachment and opaque composition,
-- with at least two images and at most eight.
standInOffer ∷ SurfaceOffer
standInOffer =
  SurfaceOffer
    { offerCapabilities =
        SurfaceCapabilities
          { capabilityMinImages = 2
          , capabilityMaxImages = 8
          , capabilityCurrentExtent = Just (SurfaceExtent 640 480)
          , capabilityMinExtent = SurfaceExtent 1 1
          , capabilityMaxExtent = SurfaceExtent 4096 4096
          , capabilityUsage = imageUsageColorAttachment
          , capabilityCurrentTransform = 1
          , capabilityCompositeAlpha = compositeAlphaOpaque
          }
    , offerFormats = [SurfaceFormat 44 colorSpaceSrgbNonlinear, SurfaceFormat formatB8G8R8A8Srgb colorSpaceSrgbNonlinear]
    , offerPresentModes = [0, presentModeFifo]
    }

-- | Change what every surface reports from now on.
offerSurface ∷ StandIn → (SurfaceOffer → SurfaceOffer) → IO ()
offerSurface standIn edit = atomically (modifyTVar' (standSurfaceOffer standIn) edit)

-- | Have every later swapchain creation return this many images.
returnImages ∷ StandIn → Int → IO ()
returnImages standIn count = atomically (writeTVar (standImages standIn) count)

-- | Run an action inside the next swapchain creation, after it is recorded
-- and before it returns — as something the owner observes only later, such as
-- a newer resize or a close, would arrive while a native call is in flight.
duringCreation ∷ StandIn → IO () → IO ()
duringCreation standIn action = atomically (writeTVar (standDuring standIn) action)

fresh ∷ StandIn → IO Word64
fresh standIn = atomically $ do
  next ← readTVar (standHandles standIn)
  writeTVar (standHandles standIn) (next + 1)
  pure next

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

-- | Have the device offer naming from now on.
offerNaming ∷ StandIn → IO ()
offerNaming standIn = atomically (writeTVar (standNaming standIn) True)

-- | Have every later naming of an object of this kind raise 'NamingFailure'
-- once it is recorded.
failNaming ∷ StandIn → NativeObjectKind → IO ()
failNaming standIn kind = atomically (modifyTVar' (standNameFails standIn) (kind :))

-- | Have naming of this kind succeed again.
restoreNaming ∷ StandIn → NativeObjectKind → IO ()
restoreNaming standIn kind = atomically (modifyTVar' (standNameFails standIn) (filter (/= kind)))

-- | A naming call the stand-in was told to fail.
newtype NamingFailure = NamingFailure NativeObjectKind
  deriving (Eq, Show)

instance Exception NamingFailure

-- | Every naming call so far, oldest first.
namesGiven ∷ StandIn → IO [(NativeObjectKind, Word64, ByteString)]
namesGiven standIn = (\recorded → [(kind, handle, name) | Named kind handle name ← recorded]) <$> calls standIn

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
  scripted ← atomically $ do
    held ← Map.lookup at <$> readTVar (standScript standIn)
    case held of
      Just (SucceedsThenFails remaining)
        | remaining > 0 → Nothing <$ modifyTVar' (standScript standIn) (Map.insert at (SucceedsThenFails (remaining - 1)))
        | otherwise → pure (Just Fails)
      other → pure other
  case scripted of
    Nothing → pure ()
    Just Fails → throwIO (StandInFailure at)
    Just Loses → throwIO (StandInLoss at)
    Just (SucceedsThenFails _) → pure ()
    -- Held as a native call is: nothing interrupts it part-way, and a
    -- cancellation aimed at its thread meanwhile is delivered once it returns.
    Just (HoldsUntil gate) → uninterruptibleMask_ (atomically (readTVar gate >>= check))
    Just (WaitsInterruptibly gate) → atomically (readTVar gate >>= check)

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
            , offerLayerExtensions = [("VK_LAYER_KHRONOS_validation", [validationFeaturesExtension])]
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
    , opsDeviceHandle = fromIntegral
    , opsDeviceQueue = \_ family → 4 <$ record standIn (QueriedQueue family)
    , opsInstrumentation = \_ → do
        offered ← readTVarIO (standNaming standIn)
        pure $
          if not offered
            then Nothing
            else Just $ Instrumentation $ \kind handle name → do
              record standIn (Named kind handle name)
              failing ← elem kind <$> readTVarIO (standNameFails standIn)
              if failing then throwIO (NamingFailure kind) else pure ()
    , opsGenerations =
        GenerationOps
          { opsSurfaceOffer = \_ surface → do
              step standIn AtSurfaceOffer (QueriedSurface surface)
              readTVarIO (standSurfaceOffer standIn)
          , opsCreateSwapchain = \_ request → do
              handle ← fresh standIn
              let extent = planExtent (requestPlan request)
              step standIn AtCreateSwapchain (CreatedSwapchain handle (requestSurface request) (extentWidth extent, extentHeight extent) (requestOldSwapchain request))
              during ← atomically $ do
                action ← readTVar (standDuring standIn)
                writeTVar (standDuring standIn) (pure ())
                pure action
              during
              pure handle
          , opsSwapchainImages = \_ swapchain → do
              step standIn AtSwapchainImages (EnumeratedImages swapchain)
              count ← readTVarIO (standImages standIn)
              pure [swapchain * 1000 + fromIntegral index | index ← [0 .. count - 1]]
          , opsCreateImageView = \_ image _ → do
              handle ← fresh standIn
              handle <$ step standIn AtCreateView (CreatedView handle image)
          , opsDestroyImageView = \_ view → step standIn AtDestroyView (DestroyedView view)
          , opsDestroySwapchain = \_ swapchain → step standIn AtDestroySwapchain (DestroyedSwapchain swapchain)
          }
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

-- | A surface whose destruction the stand-in records and which then raises
-- outright, rather than answering that it was uncertain.
surfaceThrowing ∷ StandIn → Word64 → TargetSurface
surfaceThrowing standIn handle =
  TargetSurface handle (record standIn (DestroyedSurface handle) >> throwIO (StandInFailure AtDestroyDevice))

-- | A surface whose destruction the stand-in records and which then waits,
-- interruptibly, until the variable is true — so a cancellation can end it
-- part-way, leaving its outcome unknown.
surfaceWaiting ∷ StandIn → Word64 → TVar Bool → TargetSurface
surfaceWaiting standIn handle gate =
  TargetSurface handle $ do
    record standIn (DestroyedSurface handle)
    atomically (readTVar gate >>= check)
    pure SurfaceDestroyed

type StandInRoots = Roots () Int Int Text Int

-- | Roots over the stand-in, with a model clock that never moves.
newStandInRoots ∷ StandIn → Budgets → IO StandInRoots
newStandInRoots standIn budgets = newRoots (standInOps standIn) budgets (scriptedSource (pure (scriptedInstant zeroDuration)))

-- | The request a GLFW session on the stand-in platform would make.
standardRequest ∷ InstanceRequest
standardRequest = InstanceRequest ["VK_KHR_surface", "VK_KHR_stand_in_surface"] [] []

-- | The model's default budgets, with the target-record limit given.
testBudgets ∷ Integer → Budgets
testBudgets records = case validateBudgets defaultBudgetRequest {requestedTargetRecords = records} of
  Right budgets → budgets
  Left rejected → error ("the test budgets were rejected: " <> show rejected)
