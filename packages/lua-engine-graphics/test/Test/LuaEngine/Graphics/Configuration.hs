-- | The native configuration the fixed M1 profile maps to: every native budget the design fixes, a staging
-- that admits the largest legal level, a table that holds the approved two instances' slots, and the
-- refusals of a profile or a host that does not fit. Pure, and so run without a device.
module Test.LuaEngine.Graphics.Configuration (spec) where

import Data.Word (Word64)
import Hetoimasia.Foundation.Time (durationNanoseconds)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.GPU.Model.Budget
  ( aggregateFrameSlotLimit
  , byteLimit
  , defaultBudgetRequest
  , validateBudgets
  , frameSlotLimit
  , framelessBatchLimit
  , generationLimit
  , idleBackoffCap
  , imageTrackingLimit
  , objectLimit
  , progressActionLimit
  , reclaimExaminationLimit
  , targetRecordLimit
  )
import Hetoimasia.GPU.Vulkan.Diagnostics (defaultCaptureConfig)
import Hetoimasia.GPU.Vulkan.GLFW (VulkanHostConfig (..), validateUploadConfig, vulkanHostConfig)
import Hetoimasia.GPU.Vulkan.Native.Uploads (uploadQueueCapacity, uploadStagingBytes, uploadTurnBudget)
import Hetoimasia.LuaEngine.Graphics.Texture.Configuration
import Hetoimasia.LuaEngine.Profile
import Hetoimasia.Runtime.GLFW (defaultHostConfig)
import Test.Hspec

spec ∷ Spec
spec = describe "the native configuration the profile maps to" $ do
  it "carries every native budget the design fixes, without tuning" $ do
    let configuration = mapped fixedM1Profile
        budgets = configurationBudgets configuration
    targetRecordLimit budgets `shouldBe` 2
    frameSlotLimit budgets `shouldBe` 2
    aggregateFrameSlotLimit budgets `shouldBe` 4
    framelessBatchLimit budgets `shouldBe` 4
    generationLimit budgets `shouldBe` 2
    imageTrackingLimit budgets `shouldBe` 16
    byteLimit budgets `shouldBe` 2 * 1024 * 1024 * 1024
    objectLimit budgets `shouldBe` 4096
    reclaimExaminationLimit budgets `shouldBe` 64
    progressActionLimit budgets `shouldBe` 32
    durationNanoseconds (idleBackoffCap budgets) `shouldBe` 100000000

  it "admits one legal maximum level, padded, and two at once, with the device's least turn budget met" $ do
    let configuration = mapped fixedM1Profile
        uploads = configurationUploads configuration
        accounting = configurationAccounting configuration
        Bytes level = pngOutputBytes fixedM1Profile
    level `shouldBe` 2048 * 2048 * 4
    accountingLevelBytes accounting `shouldBe` level
    fromIntegral (uploadStagingBytes uploads) `shouldBe` 2 * level
    -- Four bytes a texel of the widest image any device allows (32,768), one block row of it.
    fromIntegral (uploadTurnBudget uploads) `shouldSatisfy` (>= (4 * 32768 ∷ Word64))
    uploadQueueCapacity uploads `shouldBe` 8

  it "holds the approved texture slots of two instances, and a version ring from the frame and frame-less budgets" $ do
    let accounting = configurationAccounting (mapped fixedM1Profile)
    accountingTextureSlots accounting `shouldBe` 32
    accountingTableCapacity accounting `shouldBe` 33
    accountingTableVersions accounting `shouldBe` 4 + 4 + 2

  it "accounts the native bytes it asks for within the profile's, apart from the CPU workspace" $ do
    let accounting = configurationAccounting (mapped fixedM1Profile)
    accountingNativeBytes accounting `shouldSatisfy` (<= accountingNativeLimit accounting)
    accountingNativeLimit accounting `shouldBe` 2 * 1024 * 1024 * 1024
    accountingTextureBytes accounting `shouldBe` 256 * 1024 * 1024

  it "refuses a profile whose native bytes cannot hold what the configuration asks, without clamping" $
    case configurationFor (smaller [] [(NativeAccountedBytes, 64 * 1024 * 1024)]) of
      Left (NativeBytesExceeded asked allowed) → (asked > allowed) `shouldBe` True
      other → expectationFailure ("expected the native bytes refused, found " <> either show (const "a configuration") other)

  it "scales with a smaller validated profile and refuses nothing the fixed one does not" $ do
    let profile = smaller [(TexturePipelineLanes, 1), (InstancesPerVm, 1), (TextureLeasesPerUiInstance, 4)] []
        accounting = configurationAccounting (mapped profile)
    accountingStagingBytes accounting `shouldBe` accountingLevelBytes accounting
    accountingTableCapacity accounting `shouldBe` 5

  it "names what is wrong with a host that was not built for the backend, before any texture work is admitted" $ do
    let configuration = mapped fixedM1Profile
    initial ← prepare ()
    budgets ← either (\refused → fail (show refused)) pure (validateBudgets defaultBudgetRequest)
    let plain = vulkanHostConfig (defaultHostConfig []) defaultCaptureConfig budgets initial
    -- A host as the samples build it by default: the sample's budgets, no uploads, the device at the first window.
    checkHostConfig configuration plain `shouldBe` [HostBudgetsDiffer, HostUploadsNotConfigured, HostDeviceNeedsWindow]
    -- The sample's own small uploads are not the engine's: its staging cannot admit the approved level.
    let sampleUploads = either (\refused → error (show refused)) id (validateUploadConfig (1024 * 1024) (128 * 1024) 8)
    checkHostConfig configuration (configureHost configuration plain) {vulkanUploads = Just sampleUploads} `shouldBe` [HostUploadsDiffer]
    -- Built for the backend, it is accepted.
    checkHostConfig configuration (configureHost configuration plain) `shouldBe` []
  where
    mapped profile = either (\refused → error ("the profile was refused: " <> show refused)) id (configurationFor profile)

smaller ∷ [(CountLimit, Word64)] → [(ByteLimit, Word64)] → Profile
smaller countChanges byteChanges = case validateProfile changed of
  Right profile → profile
  Left refused → error ("the injected profile is refused: " <> show refused)
  where
    base = profileSpec fixedM1Profile
    changed =
      base
        { specCounts = \limit → maybe (specCounts base limit) Count (lookup limit countChanges)
        , specBytes = \limit → maybe (specBytes base limit) Bytes (lookup limit byteChanges)
        }
