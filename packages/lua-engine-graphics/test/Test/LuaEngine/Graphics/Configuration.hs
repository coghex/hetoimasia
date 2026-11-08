-- | The native configuration the fixed M1 profile maps to: every native budget the design fixes, a staging
-- that admits the largest legal level, a table whose capacity is derived from the session's byte bank (there is no
-- count of textures to size it from), and the refusals of a profile or a host that does not fit. Pure, and so run without a device.
module Test.LuaEngine.Graphics.Configuration (spec) where

import Data.Word (Word64)
import Hetoimasia.LuaEngine.Graphics.Facade (facadeLeaseCapacity)
import Test.QuickCheck (Gen, choose, conjoin, counterexample, elements, forAll, property, withNumTests, (===))
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

  it "derives the table's capacity from the session's bytes, 1 GiB over the 4 KiB minimum charge plus slot 0's placeholder, and a version ring from the frame and frame-less budgets" $ do
    let accounting = configurationAccounting (mapped fixedM1Profile)
    accountingTableSlots accounting `shouldBe` 262144
    accountingTableCapacity accounting `shouldBe` 262145
    accountingTableVersions accounting `shouldBe` 4 + 4 + 2
    -- the lookup ring is versions times capacity times eight bytes, and the native accounting counts it
    accountingTableVersions accounting * accountingTableCapacity accounting * 8 `shouldBe` 20971600

  it "accounts the native bytes it asks for within the profile's, apart from the CPU workspace" $ do
    let accounting = configurationAccounting (mapped fixedM1Profile)
    accountingNativeBytes accounting `shouldSatisfy` (<= accountingNativeLimit accounting)
    accountingNativeLimit accounting `shouldBe` 2 * 1024 * 1024 * 1024
    accountingTextureBytes accounting `shouldBe` 1024 * 1024 * 1024
    -- 32 MiB of staging, 4 MiB of ring, 20,971,600 bytes of lookup entries and 1 GiB of texture bytes
    accountingNativeBytes accounting `shouldBe` 32 * 1048576 + 4 * 1048576 + 20971600 + 1073741824
    accountingNativeBytes accounting `shouldBe` 1132462160

  it "refuses a profile whose native bytes cannot hold what the configuration asks, without clamping" $
    case configurationFor (smaller [] [(NativeAccountedBytes, 64 * 1024 * 1024)]) of
      Left (NativeBytesExceeded asked allowed) → (asked > allowed) `shouldBe` True
      other → expectationFailure ("expected the native bytes refused, found " <> either show (const "a configuration") other)

  it "refuses, with the existing structured reason, a profile whose derived table would exceed the native budget, without clamping" $
    -- 1 GiB of texture bytes derives a 20 MiB ring; a 40 MiB native budget cannot hold it with the staging and the bytes
    case configurationFor (smaller [] [(NativeAccountedBytes, 40 * 1024 * 1024)]) of
      Left (NativeBytesExceeded asked allowed) → (asked, allowed) `shouldBe` (1132462160, 40 * 1024 * 1024)
      other → expectationFailure ("expected the native bytes refused, found " <> either show (const "a configuration") other)

  it "scales with a smaller validated profile and refuses nothing the fixed one does not" $ do
    let profile = smaller [(TexturePipelineLanes, 1), (InstancesPerVm, 1), (PngPixels, 1024), (PngAxisMaximum, 32)] [(TextureBytesPerUiInstance, 16384), (TextureBytesPerSession, 20480)]
        accounting = configurationAccounting (mapped profile)
    accountingStagingBytes accounting `shouldBe` accountingLevelBytes accounting
    -- 20,480 bytes hold five textures of the 4,096-byte minimum charge, and the placeholder takes slot 0
    accountingTableSlots accounting `shouldBe` 5
    accountingTableCapacity accounting `shouldBe` 6

  it "gives every validated profile a table with a slot for each texture its session bytes can hold, and a lease scope with room for each its instance bytes can hold, its windows and one more (property)" $
    withNumTests 200 $
      forAll generatedProfile $ \profile →
        case configurationFor profile of
          -- native configuration rejection stays a separate, structured outcome
          Left _ → property True
          Right configuration → do
            let accounting = configurationAccounting configuration
                Bytes sessionBytes = bytesLimit profile TextureBytesPerSession
                Bytes instanceBytes = bytesLimit profile TextureBytesPerUiInstance
                Count windows = countLimit profile WindowSlotsPerUiInstance
            conjoin
              [ counterexample "table slots are session bytes over the minimum charge" (accountingTableSlots accounting === sessionBytes `div` textureMinimumChargeBytes)
              , counterexample "slot 0 is the placeholder" (accountingTableCapacity accounting === accountingTableSlots accounting + 1)
              , counterexample "the lease scope holds every texture the instance bytes can, its windows and one lease of headroom, so bytes answer first with a window held" (fromIntegral (facadeLeaseCapacity profile) === instanceBytes `div` textureMinimumChargeBytes + windows + 1)
              , counterexample "the table never fills before the session bytes do" (instanceBytes `div` textureMinimumChargeBytes <= accountingTableSlots accounting)
              , counterexample "the ring is counted" (accountingNativeBytes accounting >= accountingTableVersions accounting * accountingTableCapacity accounting * 8 + accountingTextureBytes accounting)
              ]

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

-- | A validated profile whose texture banks are any size the validation allows: a pixel limit whose reservation is at or
-- below the minimum charge or above it, an instance bank that is not a multiple of anything, and a session bank at least as
-- large (up to the fixed profile's).
generatedProfile ∷ Gen Profile
generatedProfile = do
  pixels ← elements [1, 16, 1024, 4096, 65536, 4194304]
  let reservation = max textureMinimumChargeBytes (4 * pixels)
  axis ← pure (if pixels <= 1024 then 32 else if pixels <= 4096 then 64 else if pixels <= 65536 then 256 else 2048)
  instanceBytes ← choose (reservation, 512 * 1024 * 1024)
  sessionBytes ← choose (instanceBytes, 1024 * 1024 * 1024)
  lanes ← elements [1, 2]
  pure (smaller [(PngPixels, pixels), (PngAxisMaximum, axis), (TexturePipelineLanes, lanes)] [(TextureBytesPerUiInstance, instanceBytes), (TextureBytesPerSession, sessionBytes)])
