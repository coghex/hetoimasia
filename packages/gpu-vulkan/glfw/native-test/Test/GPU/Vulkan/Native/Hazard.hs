{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The negative control for synchronization validation: a deliberate hazard,
-- recorded with test-only commands on private roots, that only an active
-- synchronization validation can report.
--
-- The instance is created by the production native layer
-- ("Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan") from the same request the
-- shared fixture's roots are planned from — the validation layer, with
-- 'validationFeatures' through the instance's own create info — so what this
-- proves active is the configuration every other native case runs under, not
-- a chain written for this example. Two @vkCmdFillBuffer@ writes to one buffer
-- with no barrier between them are a write-after-write hazard: core validation
-- has nothing to say about them, and synchronization validation reports
-- @SYNC-HAZARD-WRITE-AFTER-WRITE@ from inside the second. Nothing is submitted
-- and no production recording API is added; the device, the buffer and the
-- command buffer are this module's own, and all of it is destroyed before the
-- instance, whose destruction is the capture lifetime's quiescence evidence.
--
-- The verdict here is expected to fail, and that is the pass: the capture has
-- to carry the report, complete, and latch the error, and nothing else may
-- have been wrong. It is reported apart from the clean profile's zero-error
-- verdict and never filtered out of it.
module Test.GPU.Vulkan.Native.Hazard
  ( HazardOutcome (..)
  , HazardFacts (..)
  , HazardStep (..)
  , runHazard
  , hazardMessageId
  , hazardSection
  , spec
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (SomeException, displayException, mask, onException, throwIO, try)
import Data.Bits ((.&.), (.|.))
import qualified Data.ByteString as ByteString
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.Vector as Vector
import Data.Word (Word32, Word64)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Core10
import Vulkan.Extensions.VK_KHR_portability_subset (data KHR_PORTABILITY_SUBSET_EXTENSION_NAME)
import Vulkan.Zero (zero)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogEntry (..)
  , LogFilter (..)
  , LogLevel (Info)
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Resource (withResourceLabelled)
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureConfig (..)
  , CaptureCounters (..)
  , CaptureStatus (..)
  , ConsumerOutcome (..)
  , DiagnosticCapture
  , DiagnosticVerdict (..)
  , Quiesced
  , VerdictIssue (..)
  , captureStatus
  , defaultCaptureConfig
  , diagnosticVerdict
  , verdictIssues
  , withDiagnosticCapture
  )
import Hetoimasia.GPU.Vulkan.Native.Profile (InstancePlan (..), InstanceRequest (..), planInstance)
import Hetoimasia.GPU.Vulkan.Native.Roots (RootOps (..))
import Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan (vulkanRootOps)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.Vulkan.Proof.Journal (Journal, heading, note)

-- | One native step, and what the capture received during it.
data HazardStep = HazardStep
  { stepName ∷ !Text
  , stepReports ∷ !Word64
  , stepErrors ∷ !Word64
  }
  deriving (Show)

data HazardFacts = HazardFacts
  { hazardSteps ∷ ![HazardStep]
  , hazardEntries ∷ ![LogEntry]
    -- ^ Every record the lifetime delivered to the logger.
  , hazardDevice ∷ !Text
  , hazardVerdict ∷ !DiagnosticVerdict
  }
  deriving (Show)

data HazardOutcome
  = HazardRecorded HazardFacts
  | HazardStopped Text (Maybe DiagnosticVerdict) [HazardStep]
  deriving (Show)

-- | The report synchronization validation gives two unordered writes.
hazardMessageId ∷ Text
hazardMessageId = "SYNC-HAZARD-WRITE-AFTER-WRITE"

-- | The step whose command is the hazard.
secondFill ∷ Text
secondFill = "vkCmdFillBuffer, the second write with no barrier"

-- | The capture limits: the ones the shared roots run under.
hazardCaptureConfig ∷ CaptureConfig
hazardCaptureConfig = defaultCaptureConfig {captureTextBudget = 16384}

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

-- | Run the scenario on the calling thread. It opens no window and needs no
-- display, but it creates a device, so it runs under the suite's consent like
-- every native case.
runHazard ∷ Journal → IO HazardOutcome
runHazard journal = do
  heading journal "Synchronization validation: a deliberate write-after-write hazard"
  logged ← newTVarIO []
  steps ← newIORef []
  let logger =
        mkLogger
          LogFilter
            { filterEnabled = True
            , filterGlobalLevel = Info
            , filterComponentLevels = Map.empty
            , filterDebug = DebugAll
            , filterSource = False
            }
          (callbackSink (\entry → atomically (modifyTVar' logged (entry :))))
  outcome ← try @SomeException (withDiagnosticCapture hazardCaptureConfig logger (session journal steps))
  entries ← reverse <$> readTVarIO logged
  seen ← reverse <$> readIORef steps
  case outcome of
    Left failure → do
      note journal ("the hazard session stopped: " <> Text.pack (displayException failure))
      pure (HazardStopped (Text.pack (displayException failure)) (diagnosticVerdict failure) seen)
    Right (device, verdict) → do
      note journal ("the lifetime delivered " <> tshow (verdictDelivered verdict) <> " records")
      pure (HazardRecorded HazardFacts {hazardSteps = seen, hazardEntries = entries, hazardDevice = device, hazardVerdict = verdict})

-- | Count what the capture received during one step.
measure ∷ DiagnosticCapture → IORef [HazardStep] → Text → IO a → IO a
measure capture steps name action = do
  before ← statusCounters <$> captureStatus capture
  result ← action
  after ← statusCounters <$> captureStatus capture
  modifyIORef' steps (HazardStep name (countOffered after - countOffered before) (countErrors after - countErrors before) :)
  pure result

session ∷ Journal → IORef [HazardStep] → DiagnosticCapture → IO (Text, Quiesced)
session journal steps capture = do
  let ops = vulkanRootOps capture
      step ∷ Text → IO a → IO a
      step = measure capture steps
  offer ← step "the loader's offer" (opsInstanceOffer ops)
  -- The surface extension is asked for only because the profile's surface
  -- maintenance extension depends on it; no surface is created.
  plan ←
    either (stopWith . Text.pack . displayException) pure $
      planInstance (InstanceRequest ["VK_KHR_surface"] ["VK_LAYER_KHRONOS_validation"] validationFeatures) offer
  note journal ("the production layer enables " <> tshow plan.planValidationFeatures <> " through the instance's create info")
  mask $ \restore → do
    vulkan ← step "vkCreateInstance" (opsCreateInstance ops plan)
    let quiesce = step "vkDestroyInstance" (opsDestroyInstance ops vulkan)
    device ←
      restore
        ( withResourceLabelled
            "the hazard's explicit messenger"
            (step "vkCreateDebugUtilsMessengerEXT" (opsCreateMessenger ops vulkan))
            (step "vkDestroyDebugUtilsMessengerEXT" . opsDestroyMessenger ops vulkan)
            (\_ → hazard journal step vulkan)
        )
        `onException` quiesce
    token ← quiesce
    pure (device, token)

-- | The device, the buffer, and the two writes.
hazard ∷ Journal → (∀ a. Text → IO a → IO a) → Instance → IO Text
hazard journal step vulkan = do
  (_, physicals) ← enumeratePhysicalDevices vulkan
  physical ← maybe (stopWith "the instance enumerated no physical device") pure (Vector.headM physicals)
  properties ← getPhysicalDeviceProperties physical
  let name = Encoding.decodeUtf8Lenient (ByteString.takeWhile (/= 0) properties.deviceName)
  families ← getPhysicalDeviceQueueFamilyProperties physical
  family ←
    maybe (stopWith "no queue family accepts transfer commands") (pure . fromIntegral) $
      Vector.findIndex (\f → f.queueFlags .&. (QUEUE_GRAPHICS_BIT .|. QUEUE_TRANSFER_BIT) /= zero) families
  (_, extensions) ← enumerateDeviceExtensionProperties physical Nothing
  let portability = [KHR_PORTABILITY_SUBSET_EXTENSION_NAME | KHR_PORTABILITY_SUBSET_EXTENSION_NAME `elem` fmap (.extensionName) extensions]
      deviceInfo =
        DeviceCreateInfo
          { next = ()
          , flags = zero
          , queueCreateInfos =
              Vector.singleton
                ( SomeStruct
                    ( DeviceQueueCreateInfo
                        { next = ()
                        , flags = zero
                        , queueFamilyIndex = family
                        , queuePriorities = Vector.singleton 1.0
                        }
                    )
                )
          , enabledLayerNames = Vector.empty
          , enabledExtensionNames = Vector.fromList portability
          , enabledFeatures = Nothing
          }
  memory ← getPhysicalDeviceMemoryProperties physical
  withResourceLabelled "the hazard's device" (step "vkCreateDevice" (createDevice physical deviceInfo Nothing)) (\device → step "vkDestroyDevice" (destroyDevice device Nothing)) $ \device → do
    let bufferInfo =
          BufferCreateInfo
            { next = ()
            , flags = zero
            , size = 256
            , usage = BUFFER_USAGE_TRANSFER_DST_BIT
            , sharingMode = SHARING_MODE_EXCLUSIVE
            , queueFamilyIndices = Vector.empty
            }
    withResourceLabelled "the hazard's buffer" (step "vkCreateBuffer" (createBuffer device bufferInfo Nothing)) (\buffer → step "vkDestroyBuffer" (destroyBuffer device buffer Nothing)) $ \buffer → do
      requirements ← getBufferMemoryRequirements device buffer
      memoryType ← maybe (stopWith "no memory type can back the buffer") pure (compatible memory requirements.memoryTypeBits)
      let allocation = MemoryAllocateInfo {next = (), allocationSize = requirements.size, memoryTypeIndex = memoryType}
      withResourceLabelled "the hazard's memory" (step "vkAllocateMemory" (allocateMemory device allocation Nothing)) (\bound → step "vkFreeMemory" (freeMemory device bound Nothing)) $ \bound → do
        step "vkBindBufferMemory" (bindBufferMemory device buffer bound 0)
        let poolInfo = CommandPoolCreateInfo {next = (), flags = zero, queueFamilyIndex = family}
        withResourceLabelled "the hazard's command pool" (step "vkCreateCommandPool" (createCommandPool device poolInfo Nothing)) (\pool → step "vkDestroyCommandPool" (destroyCommandPool device pool Nothing)) $ \pool → do
          -- The command buffer is owned through its pool, which frees it.
          buffers ←
            step "vkAllocateCommandBuffers" $
              allocateCommandBuffers device CommandBufferAllocateInfo {commandPool = pool, level = COMMAND_BUFFER_LEVEL_PRIMARY, commandBufferCount = 1}
          commands ← maybe (stopWith "no command buffer was allocated") pure (Vector.headM buffers)
          step "vkBeginCommandBuffer" $
            beginCommandBuffer commands CommandBufferBeginInfo {next = (), flags = COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, inheritanceInfo = Nothing}
          step "vkCmdFillBuffer, the first write" (cmdFillBuffer commands buffer 0 WHOLE_SIZE 0)
          step secondFill (cmdFillBuffer commands buffer 0 WHOLE_SIZE 1)
          step "vkEndCommandBuffer" (endCommandBuffer commands)
          note journal "recorded two writes to one buffer with no barrier between them, and submitted nothing"
  pure name
  where
    compatible ∷ PhysicalDeviceMemoryProperties → Word32 → Maybe Word32
    compatible memory bits =
      find (\index → bits .&. (2 ^ index) /= 0) [0 .. memory.memoryTypeCount - 1]

-- | The record's section: every step with what the capture received during
-- it, the error reports by message id, and the verdict's issues.
hazardSection ∷ HazardOutcome → [Text]
hazardSection = \case
  HazardStopped reason verdict steps →
    ["", "## The session stopped", "", reason, ""]
      <> stepTable steps
      <> ["", "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) verdict]
  HazardRecorded facts →
    [ ""
    , "## Two writes to one buffer with no barrier between them"
    , ""
    , "- device: " <> facts.hazardDevice
    ]
      <> [""]
      <> stepTable facts.hazardSteps
      <> [ ""
         , "- error reports, by message id: " <> joined (idsOfSeverity "error" facts)
         , "- records delivered: " <> tshow facts.hazardVerdict.verdictDelivered
         , "- undelivered: " <> tshow facts.hazardVerdict.verdictUndelivered
         , "- verdict issues: " <> tshow (verdictIssues facts.hazardVerdict)
         ]
  where
    joined [] = "none"
    joined ids = Text.intercalate ", " ids
    stepTable steps =
      ["| step | reports | errors |", "| --- | --- | --- |"]
        <> ["| " <> step.stepName <> " | " <> tshow step.stepReports <> " | " <> tshow step.stepErrors <> " |" | step ← steps]

-- ---------------------------------------------------------------------------
-- The verdict

spec ∷ HazardOutcome → Spec
spec outcome = describe "Synchronization validation's negative control" $ do
  it "established every step of its private roots" $
    onFacts outcome $ \_ → pure ()

  it "reported the deliberate write-after-write hazard from inside the second write" $
    onFacts outcome $ \facts → do
      let during = find ((== secondFill) . (.stepName)) facts.hazardSteps
      fmap (.stepErrors) during `shouldSatisfy` maybe False (> 0)
      idsOfSeverity "error" facts `shouldSatisfy` elem hazardMessageId

  it "reported no error but the hazard it provoked, from no other step" $
    onFacts outcome $ \facts → do
      let errors = idsOfSeverity "error" facts
      errors `shouldSatisfy` (not . null)
      for_ errors (`shouldBe` hazardMessageId)
      [step.stepName | step ← facts.hazardSteps, step.stepErrors > 0, step.stepName /= secondFill] `shouldBe` []

  it "completed its capture: every report admitted and delivered, and its worker finished" $
    onFacts outcome $ \facts → do
      let verdict = facts.hazardVerdict
          counters = verdict.verdictStatus.statusCounters
      counters.countAdmitted `shouldBe` counters.countOffered
      verdict.verdictDelivered `shouldBe` counters.countAdmitted
      verdict.verdictUndelivered `shouldBe` 0
      fromIntegral (length facts.hazardEntries) `shouldBe` verdict.verdictDelivered
      verdict.verdictQuiescent `shouldBe` True
      completed verdict.verdictConsumer `shouldBe` True

  it "failed its verdict, after its last teardown callback, for the latched error and nothing else" $
    onFacts outcome $ \facts →
      -- A clean verdict here would mean synchronization validation never ran;
      -- any other issue would mean the capture was incomplete.
      verdictIssues facts.hazardVerdict `shouldBe` [ErrorLatched]
  where
    completed = \case
      ConsumerCompleted → True
      _ → False

onFacts ∷ HazardOutcome → (HazardFacts → Expectation) → Expectation
onFacts outcome assertion = case outcome of
  HazardStopped reason _ _ → expectationFailure ("the hazard session stopped: " <> Text.unpack reason)
  HazardRecorded facts → assertion facts

idsOfSeverity ∷ Text → HazardFacts → [Text]
idsOfSeverity severity facts =
  [ Map.findWithDefault "" "message.id" entry.entryFields
  | entry ← facts.hazardEntries
  , Map.lookup "severity" entry.entryFields == Just severity
  ]

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
