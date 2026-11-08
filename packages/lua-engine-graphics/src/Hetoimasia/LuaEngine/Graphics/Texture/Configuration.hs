-- | The native configuration the M1 texture backend runs under (LFE-17), derived from the fixed profile
-- and checked against the validated native model.
--
-- Nothing here is tunable. 'configurationFor' reads the limits of a validated 'Profile' (#517's fixed M1
-- profile in production, a smaller validated test profile in tests), maps them onto the native
-- backend's own validated types, and refuses, with a structured reason, any profile whose numbers
-- cannot be mapped. A mapped configuration is the host's to be built with ('configureHost') or to be
-- checked against ('checkHostConfig'): a host without it fails at startup, never as a per-request
-- 'Hetoimasia.GPU.Vulkan.GLFW.UploadOversized' that would look like the content's fault.
--
-- = What is mapped, and from what
--
-- +------------------------------------+---------------------------------------------------------------+
-- | Native configuration               | Source                                                         |
-- +====================================+===============================================================+
-- | target records, frame slots per    | 'NativeTargetRecords' (2), 'FrameSlotsPerWindow' (2),         |
-- | target, aggregate frame slots      | 'FrameSlotsAggregate' (4)                                      |
-- | frame-less batches, generations,   | 'FramelessBatches' (4), 'GenerationsPerTarget' (2),           |
-- | tracked images                     | 'TrackedImagesPerGeneration' (16)                              |
-- | accounted bytes, objects           | 'NativeAccountedBytes' (2 GiB), 'NativeObjects' (4,096)        |
-- | reclaim pass, progress actions,    | 'ReclaimPassRecords' (64), 'ProgressActionsPerTurn' (32),     |
-- | idle backoff                       | 'MaximumIdleBackoff' (100 ms)                                  |
-- | staging buffer                     | one maximum level (the profile's PNG output bytes, 16 MiB)    |
-- |                                    | for each texture lane (2): 32 MiB                              |
-- | upload turn budget                 | a quarter of a maximum level: 4 MiB                            |
-- | upload queue                       | four for each lane: 8                                          |
-- | texture table capacity             | the session's texture bytes over the minimum charge of a       |
-- |                                    | texture, plus slot 0's placeholder: 1 GiB / 4 KiB + 1 = 262,145 |
-- | texture table lookup versions      | aggregate frame slots + frame-less batches + 2: 10             |
-- | ring and region window             | see below                                                      |
-- +------------------------------------+---------------------------------------------------------------+
--
-- The sample's own smaller configuration (a 1 MiB staging buffer, a table of 16 slots) is not the
-- engine's: its staging cannot admit the approved 16 MiB level, which this configuration's can,
-- padded to the staging's granule (a power of two no larger than a page), and its table has room for
-- every texture the session's byte bank can hold. A constrained device is still not promised every maximum
-- allocation at once; the native backend answers a budget it cannot give as backpressure, and the
-- backend retains the work.
--
-- /The turn budget/ must be at least four bytes for each texel of the widest image the device allows
-- (@maxImageDimension2D@, at most 32,768 on any supported device, so 128 KiB): the native uploads check
-- it against the device when they are made, and 4 MiB satisfies it everywhere. /The ring and region
-- window/ are the renderer's, for batches the scene slices record: the ring holds the instance bytes
-- of every batch that can be in flight (frame slots plus frame-less batches) at the scene limit of
-- 4,096 sprites, twice over, and the region window holds a clip-table entry (16 bytes) for each of
-- three times as many sprites as the scene limit, which leaves room for the material records.
-- 'Hetoimasia.Render.TwoD.Vulkan.defaultConfiguration' is left as it is.
--
-- = The table's capacity is derived, not chosen
--
-- There is no count of textures to size the table from (owner decision 2026-11-08: memory is the only bound). The
-- table's capacity is /derived/ from the byte bank: every texture is charged at least
-- 'Hetoimasia.LuaEngine.Profile.textureMinimumChargeBytes' in the session's bank, so the bank cannot hold more than
-- 'Hetoimasia.LuaEngine.Profile.textureRoomPerSession' textures, and the table has that many slots and slot 0's
-- placeholder. The bank therefore always refuses before the table can be full (a texture admitted past the bank would be
-- a defect of the pipeline, not a refusal here), and the table's startup checks against the device's update-after-bind
-- limits ('validateTableConfig' and the native table's own) are what a profile that asks for more than a device
-- offers meets, at startup. The initial size equals the capacity, as before; the table's growth is the native
-- backend's and is unchanged. Owner: this configuration (immutable once derived); the table's owner is the native
-- renderer, on its thread, for the life of the host.
--
-- = Native accounting
--
-- 'accountedNativeBytes' is the sum the configuration asks of the native byte budget at its most: the
-- staging buffer, the ring, the lookup versions (eight bytes an entry), and the nominal bytes of every
-- texture the profile lets a session hold. It must fit the profile's accounted native bytes, and does:
-- for the fixed profile it is 1,132,462,160 bytes (32 MiB staging, 4 MiB ring, 20,971,600 bytes of lookup entries
-- and 1 GiB of texture bytes) against 2 GiB. These are the allocations the native accounting charges, once each: the decoded
-- level the pipeline charges to its lane is CPU payload, the staging copy of it is the native
-- accounting's, and the texture's image is charged for its lifetime and no other; a view of a level is
-- never charged again.
module Hetoimasia.LuaEngine.Graphics.Texture.Configuration
  ( -- * The configuration
    TextureGraphicsConfiguration
  , configurationBudgets
  , configurationUploads
  , configurationRenderer
  , configurationAccounting
  , configurationFor
  , ConfigurationRefused (..)

    -- * What it accounts for
  , Accounting (..)

    -- * The host
  , configureHost
  , checkHostConfig
  , HostProblem (..)
  ) where

import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Foundation.Time (durationNanoseconds)
import Hetoimasia.GPU.Model.Budget
  ( BudgetRejected
  , BudgetRequest (..)
  , Budgets
  , defaultBudgetRequest
  , validateBudgets
  )
import Hetoimasia.GPU.Vulkan.GLFW
  ( RingSizeRefused
  , StorageWindowRefused
  , TableConfigRefused
  , UploadConfig
  , UploadConfigRefused
  , VulkanDeviceStart (DeviceSurfaceFree)
  , VulkanHostConfig (..)
  , validateRingSize
  , validateStorageWindow
  , validateTableConfig
  , validateUploadConfig
  )
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (..)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (..)
  , DurationLimit (..)
  , Profile
  , bytesLimit
  , countLimit
  , durationLimit
  , pngOutputBytes
  , textureRoomPerSession
  )
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Layout (instanceStride)

-- | The native configuration of a session that serves the M1 texture backend.
data TextureGraphicsConfiguration = TextureGraphicsConfiguration
  { configurationBudgets ∷ !Budgets
  , configurationUploads ∷ !UploadConfig
  , configurationRenderer ∷ !Render.Configuration
  , configurationAccounting ∷ !Accounting
  }

-- | The numbers the configuration was derived from and what it asks of the native budgets.
data Accounting = Accounting
  { accountingLevelBytes ∷ !Word64
    -- ^ One maximum RGBA8 level: what one upload may need in staging.
  , accountingLanes ∷ !Word64
  , accountingStagingBytes ∷ !Word64
  , accountingTurnBytes ∷ !Word64
  , accountingQueue ∷ !Word64
  , accountingTableSlots ∷ !Word64
    -- ^ The non-placeholder slots: the textures the session's byte bank can hold at the minimum charge
    -- ('textureRoomPerSession'). Derived from bytes; not a limit beside them.
  , accountingTableCapacity ∷ !Word64
    -- ^ Those, and slot 0's placeholder.
  , accountingTableVersions ∷ !Word64
  , accountingRingBytes ∷ !Word64
  , accountingRegionWindowBytes ∷ !Word64
  , accountingTextureBytes ∷ !Word64
    -- ^ The nominal bytes of every texture a session may hold at once.
  , accountingNativeBytes ∷ !Word64
    -- ^ The most the configuration asks of the native byte budget.
  , accountingNativeLimit ∷ !Word64
  }
  deriving (Eq, Show)

-- | Why a profile could not be mapped. Nothing is clamped or defaulted.
data ConfigurationRefused
  = -- | A profile value does not fit the native model's integer: which.
    LimitUnusable !Text
  | BudgetsRefused !BudgetRejected
  | UploadsRefused !UploadConfigRefused
  | TableRefused !TableConfigRefused
  | RingRefused !RingSizeRefused
  | WindowRefused !StorageWindowRefused
  | -- | The staging cannot admit one maximum level, padded: staging and level bytes.
    StagingBelowLevel !Word64 !Word64
  | -- | The configuration asks more of the native byte budget than the profile allows: asked, allowed.
    NativeBytesExceeded !Word64 !Word64
  deriving (Eq, Show)

-- | Map a validated profile onto the native configuration.
configurationFor ∷ Profile → Either ConfigurationRefused TextureGraphicsConfiguration
configurationFor profile = do
  let count limit = let Count value = countLimit profile limit in value
      bytes limit = let Bytes value = bytesLimit profile limit in value
      Bytes level = pngOutputBytes profile
      idleMilliseconds = toInteger (durationNanoseconds (durationLimit profile MaximumIdleBackoff)) `div` 1000000
  budgets ←
    either (Left . BudgetsRefused) Right . validateBudgets $
      defaultBudgetRequest
        { requestedTargetRecords = toInteger (count NativeTargetRecords)
        , requestedFrameSlots = toInteger (count FrameSlotsPerWindow)
        , requestedAggregateFrameSlots = toInteger (count FrameSlotsAggregate)
        , requestedFramelessBatches = toInteger (count FramelessBatches)
        , requestedGenerations = toInteger (count GenerationsPerTarget)
        , requestedImageTracking = toInteger (count TrackedImagesPerGeneration)
        , requestedBytes = toInteger (bytes NativeAccountedBytes)
        , requestedObjects = toInteger (count NativeObjects)
        , requestedReclaimExamination = toInteger (count ReclaimPassRecords)
        , requestedProgressActions = toInteger (count ProgressActionsPerTurn)
        , requestedIdleBackoffMilliseconds = idleMilliseconds
        }
  let lanes = count TexturePipelineLanes
      sprites = count SceneSprites
      batches = count FrameSlotsAggregate + count FramelessBatches
      staging = lanes * level
      turn = level `div` 4
      queue = 4 * lanes
      slots = textureRoomPerSession profile
      capacity = slots + 1
      versions = count FrameSlotsAggregate + count FramelessBatches + 2
      ring = alignUp (2 * batches * sprites * fromIntegral instanceStride) mebibyte
      window = 3 * sprites * 16
      textureBytes = bytes TextureBytesPerSession
      native = staging + ring + versions * capacity * 8 + textureBytes
      limit = bytes NativeAccountedBytes
  uploads ← either (Left . UploadsRefused) Right (validateUploadConfig (toInteger staging) (toInteger turn) (toInteger queue))
  table ← either (Left . TableRefused) Right (validateTableConfig (toInteger capacity) (toInteger capacity) (toInteger versions))
  ringSize ← either (Left . RingRefused) Right (validateRingSize (toInteger ring))
  regionWindow ← either (Left . WindowRefused) Right (validateStorageWindow (toInteger window))
  if staging < level
    then Left (StagingBelowLevel staging level)
    else
      if native > limit
        then Left (NativeBytesExceeded native limit)
        else
          Right
            TextureGraphicsConfiguration
              { configurationBudgets = budgets
              , configurationUploads = uploads
              , configurationRenderer =
                  Render.Configuration
                    { Render.configurationRing = ringSize
                    , Render.configurationTable = table
                    , Render.configurationRegionWindow = regionWindow
                    }
              , configurationAccounting =
                  Accounting
                    { accountingLevelBytes = level
                    , accountingLanes = lanes
                    , accountingStagingBytes = staging
                    , accountingTurnBytes = turn
                    , accountingQueue = queue
                    , accountingTableSlots = slots
                    , accountingTableCapacity = capacity
                    , accountingTableVersions = versions
                    , accountingRingBytes = ring
                    , accountingRegionWindowBytes = window
                    , accountingTextureBytes = textureBytes
                    , accountingNativeBytes = native
                    , accountingNativeLimit = limit
                    }
              }
  where
    mebibyte = 1024 * 1024
    alignUp value granule = ((value + granule - 1) `div` granule) * granule

-- | Build a host configuration for the texture backend: the budgets, the uploads and the device started
-- without a surface, which is the only start that lets texture work finish before a window exists. Every
-- other field of the host's configuration is the assembler's.
configureHost ∷ TextureGraphicsConfiguration → VulkanHostConfig scene → VulkanHostConfig scene
configureHost configuration host =
  host
    { vulkanBudgets = configurationBudgets configuration
    , vulkanUploads = Just (configurationUploads configuration)
    , vulkanDeviceStart = DeviceSurfaceFree
    }

-- | What is wrong with a host configuration for the texture backend.
data HostProblem
  = HostBudgetsDiffer
  | HostUploadsDiffer
  | HostUploadsNotConfigured
  | HostDeviceNeedsWindow
  deriving (Eq, Show)

-- | Check the configuration a borrowed host was built with, before any texture work is admitted.
checkHostConfig ∷ TextureGraphicsConfiguration → VulkanHostConfig scene → [HostProblem]
checkHostConfig configuration host =
  [HostBudgetsDiffer | vulkanBudgets host /= configurationBudgets configuration]
    <> ( case vulkanUploads host of
           Nothing → [HostUploadsNotConfigured]
           Just uploads → [HostUploadsDiffer | uploads /= configurationUploads configuration]
       )
    <> [HostDeviceNeedsWindow | vulkanDeviceStart host /= DeviceSurfaceFree]
