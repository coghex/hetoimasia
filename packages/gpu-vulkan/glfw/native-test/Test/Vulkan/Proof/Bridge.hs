{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-5's native cases: the production loader capability and surface bridge
-- of the GLFW package's Vulkan interop component, in a real GLFW session.
--
-- A third session, after the VK-2 run and VK-6's, in the environment the VK-2
-- run established. It uses no stand-in for anything it proves: the capability
-- is 'allocLoaderIntegration', the session is the GLFW package's own
-- loader-aware session behind a protected window host, the surface comes from
-- 'createWindowSurface' inside an attachment's construction step, and it is
-- destroyed by 'dischargeSurfaceObligation' on a thread that is not the owner.
--
-- It observes, in order:
--
-- * that the capability was made from the binding's own @vkGetInstanceProcAddr@
--   — the same address, in the same image — and that during the session GLFW
--   resolves @vkGetInstanceProcAddr@ to that exact address, and an instance
--   entry point into the same image as the binding does;
-- * the instance extensions the session copied, which the instance is then
--   created with;
-- * one surface created for an attached window, a handle the binding accepts
--   in a surface query, the attachment's disposal fact and the instance's
--   release both refused while it is owed, and both granted once another
--   thread has destroyed it;
-- * the loader setting the interop shim holds after the session terminated;
-- * and, where the platform lets an application make @glfwInit@ fail, the
--   same after a failed initialization.
--
-- GLFW offers no way to read back its loader hint, so the setting observed is
-- the value the interop shim last handed it — the shim is its only production
-- writer. The VK-2 run's throwaway shim also sets that hint, and never resets
-- it; this session restores GLFW's default through it first and says so.
--
-- Like "Test.Vulkan.Proof.Run", nothing here asserts. It records what it saw,
-- and "Test.Vulkan.Proof.BridgeSpec" decides.
module Test.Vulkan.Proof.Bridge
  ( BridgeOutcome (..)
  , BridgeFacts (..)
  , FailedInitialization (..)
  , runBridge
  , failedInitializationBackend
  ) where

import Control.Concurrent (forkOS, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, bracket, displayException, throwIO, try)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.Vector as Vector
import Data.Word (Word64)
import Foreign.Ptr (Ptr, castFunPtrToPtr, castPtr, nullFunPtr, nullPtr)
import System.Directory (canonicalizePath)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Info (os)

import Vulkan.Core10
import Vulkan.Dynamic (InstanceCmds (..), getInstanceProcAddr')
import Vulkan.Extensions.VK_KHR_portability_enumeration
import Vulkan.Extensions.VK_KHR_surface (SurfaceKHR (..), getPhysicalDeviceSurfaceSupportKHR)
import Vulkan.Zero (zero)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogFilter (..)
  , LogLevel (Info)
  , Logger
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Recovery (Disposition (Required))
import Hetoimasia.GLFW.Session
  ( Backend (..)
  , IntegrationUse (..)
  , SessionConfig (..)
  , defaultSessionConfig
  , readIntegrationUse
  )
import Hetoimasia.GLFW.Vulkan
import Hetoimasia.GLFW.Vulkan.Provenance (capabilityLoaderEntry, glfwResolvedEntry, installedLoaderEntry)
import Hetoimasia.GLFW.Window (hiddenTestWindowConfig)
import Hetoimasia.Runtime.GLFW
  ( AttachmentProtocol (..)
  , CompletionPolicy (FiniteCompletion)
  , FactAnswer (..)
  , GraphicsAttachment (..)
  , RetirementFact (..)
  , RetirementProgress (RetirementAdvanced, RetirementAwaiting)
  , RollbackOutcome (RollbackUnsafe)
  , certifyGraphicsFact
  , defaultHostConfig
  , detachWindowGraphics
  , hostWindowIdentities
  , withProtectedWindowHostIn
  )
import Test.Vulkan.Proof.Interop (Provenance (..), describeProvenance, initVulkanLoader, provenanceOf)
import Test.Vulkan.Proof.Journal (Journal, heading, note)

-- | What a failed initialization left, where one could be provoked.
data FailedInitialization
  = FailedInitializationObserved
      { failedBackend ∷ Text
      , failedReason ∷ Text
        -- ^ What the session raised.
      , failedInstalledAfter ∷ Ptr ()
        -- ^ The setting the shim held afterwards.
      , failedUseAfter ∷ IntegrationUse
      }
  | FailedInitializationUnreachable Text
    -- ^ Why this platform offers no failure an application can provoke.
  | FailedInitializationSucceeded Text
    -- ^ The initialization meant to fail did not.
  deriving (Show)

data BridgeFacts = BridgeFacts
  { factsBindingEntry ∷ Provenance
    -- ^ The binding's own @vkGetInstanceProcAddr@, as it answers for itself.
  , factsCapabilityEntry ∷ Provenance
    -- ^ The entry point the capability was made from.
  , factsInstalledDuring ∷ Provenance
    -- ^ The setting the shim held while the session was live.
  , factsGlfwEntry ∷ Provenance
    -- ^ What GLFW resolved @vkGetInstanceProcAddr@ to while the session was live.
  , factsBindingInstanceSample ∷ Provenance
  , factsGlfwInstanceSample ∷ Provenance
  , factsUseDuring ∷ IntegrationUse
  , factsExtensions ∷ [Text]
  , factsCreation ∷ Text
  , factsSurfaceHandle ∷ Word64
  , factsSurfaceQuery ∷ Text
    -- ^ What the binding answered when asked about the surface: evidence the
    -- handle is a live surface of this instance.
  , factsReleaseWhileOwed ∷ Text
  , factsDisposedWhileOwed ∷ Maybe FactAnswer
  , factsDischarge ∷ Text
  , factsDischargedOffOwner ∷ Bool
  , factsDisposedAfter ∷ Maybe FactAnswer
  , factsReleaseAfter ∷ Text
  , factsInstalledAfterTermination ∷ Ptr ()
  , factsUseAfterTermination ∷ IntegrationUse
  , factsFailedInitialization ∷ FailedInitialization
  }
  deriving (Show)

data BridgeOutcome
  = BridgeProved BridgeFacts
  | BridgeStopped Text
  deriving (Show)

-- | The backend a failed initialization is provoked on, where one can be:
-- Wayland on Linux, pointed at a display that does not exist. Cocoa has no
-- initialization failure an application can provoke.
failedInitializationBackend ∷ Maybe Backend
failedInitializationBackend = if os == "linux" then Just Wayland else Nothing

-- | A Wayland display name no compositor serves.
absentWaylandDisplay ∷ String
absentWaylandDisplay = "hetoimasia-vulkan-proof-no-such-display"

-- | Run the session on the process main thread.
runBridge ∷ Journal → IO BridgeOutcome
runBridge journal = do
  heading journal "VK-5: the loader-aware GLFW surface bridge"
  -- The VK-2 case hands GLFW this same entry point through its throwaway shim
  -- and never takes it back. This session has a process of its own, but it
  -- restores the default first all the same, so every setting it observes is
  -- one the production shim made whatever ran before it.
  initVulkanLoader nullFunPtr
  note journal "restored GLFW's default loader through the VK-2 shim before the production shim's first setting"
  outcome ← try @SomeException (session journal)
  case outcome of
    Left failure → do
      note journal ("the bridge session stopped: " <> Text.pack (displayException failure))
      pure (BridgeStopped (Text.pack (displayException failure)))
    Right facts → pure (BridgeProved facts)

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

session ∷ Journal → IO BridgeFacts
session journal = do
  bindingEntry ←
    Char8.useAsCString "vkGetInstanceProcAddr" (getInstanceProcAddrOf nullPtr) >>= canonical
  (live, afterTermination) ←
    withLoaderIntegration $ \integration → do
      capabilityEntry ← canonical (castFunPtrToPtr (capabilityLoaderEntry integration))
      note journal ("the capability was made from " <> describeProvenance capabilityEntry)
      live ← withLoaderSession integration defaultSessionConfig $ \glfw → do
        use ← readIntegrationUse (loaderCapability integration)
        installed ← installedLoaderEntry >>= canonical
        note journal ("while the session is live the shim holds " <> describeProvenance installed)
        glfwEntry ← glfwResolvedEntry glfw nullPtr "vkGetInstanceProcAddr" >>= canonical
        note journal ("GLFW resolves vkGetInstanceProcAddr to " <> describeProvenance glfwEntry)
        names ← requiredInstanceExtensions glfw
        note journal ("the session copied the required extensions " <> Text.intercalate ", " (map decode names))
        -- The instance outlives the host, so even a stopped run's exit drain
        -- destroys every surface before the instance goes.
        attached ←
          withProofInstance names $ \inst →
            withProtectedWindowHostIn quietLogger (pure glfw) (defaultHostConfig [hiddenTestWindowConfig "hetoimasia VK-5 proof" 320 240]) $ \host → do
              bindingSample ← canonical (castFunPtrToPtr (pVkCreateDevice inst.instanceCmds))
              glfwSample ← glfwResolvedEntry glfw (castPtr (instanceHandle inst)) "vkCreateDevice" >>= canonical
              note journal ("the binding resolves vkCreateDevice to " <> describeProvenance bindingSample)
              note journal ("GLFW resolves vkCreateDevice to " <> describeProvenance glfwSample)
              window ←
                atomically (hostWindowIdentities host) >>= \case
                  [only] → pure only
                  other → stopWith ("the host holds " <> tshow (length other) <> " windows, not one")
              lease ← leaseSurfaceInstance integration (castPtr (instanceHandle inst))
              created ← newIORef Nothing
              heard ← newIORef Nothing
              answered ←
                attachWindowGraphicsWithSurfaces host window $ \access →
                  AttachmentProtocol
                    { protocolConstruct = \_ acknowledgement → do
                        writeIORef heard (Just acknowledgement)
                        createWindowSurface access lease >>= writeIORef created . Just
                    , protocolRollback = pure RollbackUnsafe
                      -- Reached only if this session stops before retiring the
                      -- attachment itself: the exit drain then destroys what
                      -- is still owed and certifies what it can.
                    , protocolStep = \_ acknowledgement → do
                        owed ← atomically (leasedObligations lease)
                        mapM_ dischargeSurfaceObligation owed
                        answers ← mapM (certifyGraphicsFact host acknowledgement) [minBound .. maxBound]
                        pure (if any established answers then RetirementAdvanced else RetirementAwaiting)
                    , protocolCompletion = FiniteCompletion
                    , protocolDisposition = Required
                    , protocolRecognizes = \_ → pure False
                    }
              service ← case answered of
                GraphicsAttached service → pure service
                other → stopWith ("the attachment answered " <> tshow other)
              acknowledgement ← readIORef heard >>= maybe (stopWith "no acknowledgement was issued") pure
              surface ←
                readIORef created >>= \case
                  Just (SurfaceCreated surface) → pure surface
                  other → stopWith ("the construction step's surface creation answered " <> tshow other)
              note journal ("created surface " <> tshow (surfaceHandle surface) <> " for the attached window")
              query ← surfaceQuery inst (surfaceHandle surface)
              note journal ("the binding answered a query about it: " <> query)
              releaseWhileOwed ← tshow <$> atomically (releaseSurfaceInstance lease)
              _ ← detachWindowGraphics host service
              mapM_ (certifyGraphicsFact host acknowledgement) [CpuUseRetired, SubmittedWorkEnded, PresentationEnded]
              disposedWhileOwed ← certifyGraphicsFact host acknowledgement DependentsDisposed
              note journal ("while it was owed, the disposal fact answered " <> tshow disposedWhileOwed <> " and the instance release " <> releaseWhileOwed)
              owner ← myThreadId
              finished ← newEmptyMVar
              _ ← forkOS $ do
                discharger ← myThreadId
                outcome ← dischargeSurfaceObligation (surfaceObligation surface)
                putMVar finished (outcome, discharger /= owner)
              (discharge, offOwner) ← takeMVar finished
              note journal ("another thread discharged it: " <> tshow discharge)
              disposedAfter ← certifyGraphicsFact host acknowledgement DependentsDisposed
              releaseAfter ← tshow <$> atomically (releaseSurfaceInstance lease)
              note journal ("afterwards the disposal fact answered " <> tshow disposedAfter <> " and the instance release " <> releaseAfter)
              pure
                ( bindingSample
                , glfwSample
                , tshow (SurfaceCreated surface)
                , surfaceHandle surface
                , query
                , releaseWhileOwed
                , disposedWhileOwed
                , tshow discharge
                , offOwner
                , disposedAfter
                , releaseAfter
                )
        pure (capabilityEntry, installed, glfwEntry, use, map decode names, attached)
      afterEntry ← installedLoaderEntry
      afterUse ← readIntegrationUse (loaderCapability integration)
      note journal ("after termination the shim holds " <> tshow afterEntry <> " and the capability is " <> tshow afterUse)
      pure (live, (afterEntry, afterUse))
  failed ← failedInitialization journal
  let (capabilityEntry, installed, glfwEntry, use, names, attached) = live
      ( bindingSample
        , glfwSample
        , creation
        , handle
        , query
        , releaseWhileOwed
        , disposedWhileOwed
        , discharge
        , offOwner
        , disposedAfter
        , releaseAfter
        ) = attached
  pure
    BridgeFacts
      { factsBindingEntry = bindingEntry
      , factsCapabilityEntry = capabilityEntry
      , factsInstalledDuring = installed
      , factsGlfwEntry = glfwEntry
      , factsBindingInstanceSample = bindingSample
      , factsGlfwInstanceSample = glfwSample
      , factsUseDuring = use
      , factsExtensions = names
      , factsCreation = creation
      , factsSurfaceHandle = handle
      , factsSurfaceQuery = query
      , factsReleaseWhileOwed = releaseWhileOwed
      , factsDisposedWhileOwed = disposedWhileOwed
      , factsDischarge = discharge
      , factsDischargedOffOwner = offOwner
      , factsDisposedAfter = disposedAfter
      , factsReleaseAfter = releaseAfter
      , factsInstalledAfterTermination = fst afterTermination
      , factsUseAfterTermination = snd afterTermination
      , factsFailedInitialization = failed
      }

-- | Enter a loader-aware session whose @glfwInit@ fails, and read what the
-- capability and the shim hold afterwards.
failedInitialization ∷ Journal → IO FailedInitialization
failedInitialization journal = case failedInitializationBackend of
  Nothing → do
    let reason = "GLFW 3.4's Cocoa initialization has no failure an application can provoke, and Cocoa is the only backend this platform admits"
    note journal ("a failed initialization is not reachable here: " <> reason)
    pure (FailedInitializationUnreachable reason)
  Just backend → do
    previous ← lookupEnv "WAYLAND_DISPLAY"
    setEnv "WAYLAND_DISPLAY" absentWaylandDisplay
    outcome ←
      withLoaderIntegration $ \integration → do
        entered ←
          try @SomeException $
            withLoaderSession integration defaultSessionConfig {requestedBackend = Just backend} (\_ → pure ())
        afterEntry ← installedLoaderEntry
        afterUse ← readIntegrationUse (loaderCapability integration)
        pure (entered, afterEntry, afterUse)
    maybe (unsetEnv "WAYLAND_DISPLAY") (setEnv "WAYLAND_DISPLAY") previous
    case outcome of
      (Right (), _, _) → do
        note journal "the Wayland session meant to fail initialized"
        pure (FailedInitializationSucceeded "a Wayland session on a display that does not exist initialized")
      (Left failure, afterEntry, afterUse) → do
        let reason = Text.pack (displayException failure)
        note journal ("the Wayland initialization failed: " <> firstLine reason)
        note journal ("after it the shim holds " <> tshow afterEntry <> " and the capability is " <> tshow afterUse)
        pure (FailedInitializationObserved "wayland" reason afterEntry afterUse)

-- | Create an instance with the copied extensions, and destroy it once the
-- body has returned, whatever it answered.
withProofInstance ∷ [ByteString] → (Instance → IO a) → IO a
withProofInstance names body = do
  (_, available) ← enumerateInstanceExtensionProperties Nothing
  let advertised name = name `elem` [extension.extensionName | extension ← Vector.toList available]
      portability = advertised KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
  unless (all advertised names) $
    stopWith "the loader does not advertise every extension GLFW requires"
  let info =
        InstanceCreateInfo
          { next = ()
          , flags = if portability then INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR else zero
          , applicationInfo = Nothing
          , enabledLayerNames = Vector.empty
          , enabledExtensionNames = Vector.fromList (names <> [KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME | portability])
          }
          ∷ InstanceCreateInfo '[]
  bracket (createInstance info Nothing) (\inst → destroyInstance inst Nothing) body

-- | Ask the binding about the surface on the first physical device's first
-- queue family: an answer at all, rather than an invalid-handle failure, is
-- evidence the handle is a live surface of this instance.
surfaceQuery ∷ Instance → Word64 → IO Text
surfaceQuery inst handle = do
  (_, devices) ← enumeratePhysicalDevices inst
  case Vector.toList devices of
    [] → pure "no physical device to ask"
    device : _ → do
      supported ← getPhysicalDeviceSurfaceSupportKHR device 0 (SurfaceKHR handle)
      pure ("presentation support on queue family 0 of the first device: " <> tshow supported)

getInstanceProcAddrOf ∷ Ptr Instance_T → Ptr a → IO (Ptr ())
getInstanceProcAddrOf handle name = castFunPtrToPtr <$> getInstanceProcAddr' handle (castPtr name)

-- | Provenance with its image canonicalized, as the VK-6 session reads it.
canonical ∷ Ptr () → IO Provenance
canonical address = do
  located ← provenanceOf address
  image ← traverse (fmap Text.pack . canonicalizePath . Text.unpack) located.provenanceImage
  pure located {provenanceImage = image}

quietLogger ∷ Logger
quietLogger =
  mkLogger
    LogFilter
      { filterEnabled = True
      , filterGlobalLevel = Info
      , filterComponentLevels = Map.empty
      , filterDebug = DebugAll
      , filterSource = False
      }
    (callbackSink (\_ → pure ()))

-- | Whether a certification recorded evidence the model did not already hold.
established ∷ Maybe FactAnswer → Bool
established = \case
  Just (FactRecorded _) → True
  Just AttachmentNowRetired → True
  _ → False

decode ∷ ByteString → Text
decode = Encoding.decodeUtf8Lenient

firstLine ∷ Text → Text
firstLine = Text.takeWhile (/= '\n')

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
