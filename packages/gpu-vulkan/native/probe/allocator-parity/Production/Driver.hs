{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}

-- | GRS-18's two drivers over one script: the C driver in
-- @cbits/vma_production.cpp@, and the same calls made from Haskell through
-- the Hackage @VulkanMemoryAllocator@ binding — the calls the engine will
-- make, with the binding's own marshalling and wrappers.
--
-- Each pass creates a fresh allocator through the binding, with the
-- configuration every pass shares — @VMA_ALLOCATOR_CREATE_EXTERNALLY_SYNCHRONIZED_BIT@,
-- an explicit preferred block size, Vulkan 1.3, the loader's two
-- @Get*ProcAddr@ entries — and with device-memory callbacks into C or into
-- Haskell. Both kinds of callback update one @hetoimasia_block_counters@
-- identically. The pass replays the script, frees what it left live, reads
-- what VMA still holds, destroys the allocator and reads what it released.
-- Allocator creation and destruction are never timed.
module Production.Driver
  ( Session (..)
  , withSession
  , CallSafety (..)
  , callSafetyLabel
  , detectCallSafety
  , CallbackDestination (..)
  , Driver (..)
  , Configuration (..)
  , configurationLabel
  , driverLabel
  , Mode (..)
  , Counters (..)
  , BlockEvent (..)
  , PassResult (..)
  , runPass
  , checkProductionLayouts
  , preferredBlockSize
  , preferredLargeHeapBlockSize
  , resolveClasses
  , summaryWord
  , SummaryField (..)
  , evidenceWords
  , checkpointWords
  , bufferInfo
  , imageInfo
  , allocationInfo
  , neverAllocate
  , allocatorCreateInfo
  , cOnAllocate
  , cOnFree
  , probeNow
  , safeDestroyAllocator
  , Api (..)
  , hackageApi
  , shimApi
  , Prepared (..)
  , prepare
  , shimResultBytes
  , callbacksFor
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (bracket, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Bits (shiftL, testBit, (.&.), (.|.))
import qualified Data.Vector as Vector
import qualified Data.Vector.Storable as Storable
import qualified Data.Vector.Storable.Mutable as StorableMutable
import qualified Data.Vector.Unboxed as Unboxed
import qualified Data.Vector.Unboxed.Mutable as UnboxedMutable
import Data.Int (Int32)
import Data.Word (Word32, Word64, Word8)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (allocaBytes, callocBytes, free, mallocBytes)
import Foreign.Ptr (FunPtr, Ptr, castFunPtr, castPtr, freeHaskellFunPtr, intPtrToPtr, nullFunPtr, nullPtr, plusPtr)
import Foreign.Storable (peekByteOff, pokeByteOff)
import Production.Device (Device (..), MemoryTypeOffer (..), chooseMemoryType)
import Production.Script
import Vulkan.CStruct (FromCStruct (peekCStruct), ToCStruct (cStructSize, withCStruct))
import qualified Vulkan.Core10 as Vk
import Vulkan.Core13 (data API_VERSION_1_3)
import Vulkan.Exception (VulkanException (..))
import Vulkan.Zero (zero)
import qualified VulkanMemoryAllocator as Vma

foreign import ccall unsafe "hetoimasia_probe_now"
  probeNow ∷ IO Word64

foreign import ccall "&vkGetInstanceProcAddr"
  loaderGetInstanceProcAddr ∷ FunPtr ()

foreign import ccall "&vkGetDeviceProcAddr"
  loaderGetDeviceProcAddr ∷ FunPtr ()

foreign import ccall "&hetoimasia_vma_on_allocate"
  cOnAllocate ∷ Vma.PFN_vmaAllocateDeviceMemoryFunction

foreign import ccall "&hetoimasia_vma_on_free"
  cOnFree ∷ Vma.PFN_vmaFreeDeviceMemoryFunction

foreign import ccall "&hetoimasia_detect_on_allocate"
  cDetectOnAllocate ∷ Vma.PFN_vmaAllocateDeviceMemoryFunction

foreign import ccall "wrapper"
  wrapMemoryCallback ∷ Vma.FN_vmaAllocateDeviceMemoryFunction → IO Vma.PFN_vmaAllocateDeviceMemoryFunction

foreign import ccall unsafe "hetoimasia_block_counters_size"
  c_countersSize ∷ IO Word64

foreign import ccall unsafe "hetoimasia_vma_held_bytes"
  c_heldBytes ∷ Vma.Allocator → Word32 → IO Word64

foreign import ccall unsafe "hetoimasia_detect_reset"
  c_detectReset ∷ IO ()

foreign import ccall unsafe "hetoimasia_detect_entered_now"
  c_detectEntered ∷ IO CInt

foreign import ccall unsafe "hetoimasia_detect_release"
  c_detectRelease ∷ IO ()

foreign import ccall unsafe "hetoimasia_detect_result"
  c_detectResult ∷ IO CInt

foreign import ccall unsafe "hetoimasia_vma_production_check_create_info"
  c_checkCreateInfo
    ∷ Ptr Vma.AllocationCreateInfo → Word32 → Int32 → Word32 → Word32 → Word32 → Word64 → Ptr () → Float → Word64 → IO CInt

foreign import ccall unsafe "hetoimasia_vma_production_fill_allocation_info"
  c_fillAllocationInfo ∷ Ptr Vma.AllocationInfo → Word64 → IO Word64

foreign import ccall unsafe "hetoimasia_vma_production_fill_budget"
  c_fillBudget ∷ Ptr Vma.Budget → Word64 → IO Word64

foreign import ccall unsafe "hetoimasia_shim_result_size"
  c_shimResultSize ∷ IO Word64

-- The engine-owned shim, imported unsafe and safe.
foreign import ccall unsafe "hetoimasia_shim_create_buffer"
  u_shimCreateBuffer ∷ Vma.Allocator → Word64 → Word32 → Word32 → Word32 → Word32 → Word32 → Ptr Word8 → IO Int32
foreign import ccall safe "hetoimasia_shim_create_buffer"
  s_shimCreateBuffer ∷ Vma.Allocator → Word64 → Word32 → Word32 → Word32 → Word32 → Word32 → Ptr Word8 → IO Int32
foreign import ccall unsafe "hetoimasia_shim_create_image"
  u_shimCreateImage ∷ Vma.Allocator → Word32 → Word32 → Word32 → Word32 → Word32 → Word32 → Word32 → Word32 → Ptr Word8 → IO Int32
foreign import ccall safe "hetoimasia_shim_create_image"
  s_shimCreateImage ∷ Vma.Allocator → Word32 → Word32 → Word32 → Word32 → Word32 → Word32 → Word32 → Word32 → Ptr Word8 → IO Int32
foreign import ccall unsafe "hetoimasia_shim_destroy_buffer"
  u_shimDestroyBuffer ∷ Vma.Allocator → Word64 → Word64 → IO ()
foreign import ccall safe "hetoimasia_shim_destroy_buffer"
  s_shimDestroyBuffer ∷ Vma.Allocator → Word64 → Word64 → IO ()
foreign import ccall unsafe "hetoimasia_shim_destroy_image"
  u_shimDestroyImage ∷ Vma.Allocator → Word64 → Word64 → IO ()
foreign import ccall safe "hetoimasia_shim_destroy_image"
  s_shimDestroyImage ∷ Vma.Allocator → Word64 → Word64 → IO ()
foreign import ccall unsafe "hetoimasia_shim_map"
  u_shimMap ∷ Vma.Allocator → Word64 → IO (Ptr ())
foreign import ccall safe "hetoimasia_shim_map"
  s_shimMap ∷ Vma.Allocator → Word64 → IO (Ptr ())
foreign import ccall unsafe "hetoimasia_shim_unmap"
  u_shimUnmap ∷ Vma.Allocator → Word64 → IO ()
foreign import ccall safe "hetoimasia_shim_unmap"
  s_shimUnmap ∷ Vma.Allocator → Word64 → IO ()
foreign import ccall unsafe "hetoimasia_shim_flush"
  u_shimFlush ∷ Vma.Allocator → Word64 → IO Int32
foreign import ccall safe "hetoimasia_shim_flush"
  s_shimFlush ∷ Vma.Allocator → Word64 → IO Int32
foreign import ccall unsafe "hetoimasia_shim_invalidate"
  u_shimInvalidate ∷ Vma.Allocator → Word64 → IO Int32
foreign import ccall safe "hetoimasia_shim_invalidate"
  s_shimInvalidate ∷ Vma.Allocator → Word64 → IO Int32

-- | @hetoimasia_shim_result@'s size.
shimResultBytes ∷ Int
shimResultBytes = 40

-- Destroying an allocator frees the blocks VMA retained, which runs the free
-- callback, so it is always a safe call: under the unsafe build the binding's
-- own import would let an unsafe call reach a Haskell callback.
foreign import ccall safe "vmaDestroyAllocator"
  safeDestroyAllocator ∷ Vma.Allocator → IO ()

-- A whole script is one call: its safety is paid once per pass, outside every
-- timed interval. The C driver only ever runs with C callbacks.
foreign import ccall safe "hetoimasia_vma_replay_script"
  c_replayScript
    ∷ Vma.Allocator → Ptr Vk.Device_T → Word32 → Ptr Word8 → Ptr Word8 → Word64 → Word64
    → Ptr Word64 → Ptr Word64 → Word32 → Ptr Word64 → Ptr Word64 → Ptr Word64 → Ptr Word64 → Ptr Word64
    → IO CInt

-- | VMA's preferred block size for large heaps, which the allocator's
-- configuration states explicitly (D-40): VMA's own default, 256 MiB.
preferredLargeHeapBlockSize ∷ Word64
preferredLargeHeapBlockSize = 256 * 1024 * 1024

-- | VMA 3.3.0's @CalcPreferredBlockSize@: an eighth of a heap of at most
-- 1 GiB, otherwise the configured large-heap size, aligned up to 32 bytes.
preferredBlockSize ∷ Device → Word32 → Word64
preferredBlockSize device memoryType =
  let heapSize = case [offerHeap o | o ← deviceMemoryTypes device, offerIndex o == memoryType] of
        heap : _ | fromIntegral heap < length (deviceHeaps device) → fst (deviceHeaps device !! fromIntegral heap)
        _ → error ("no memory type " <> show memoryType)
      raw = if heapSize <= 1024 * 1024 * 1024 then heapSize `div` 8 else preferredLargeHeapBlockSize
   in ((raw + 31) `div` 32) * 32

-- | What every pass shares, created once per device.
data Session = Session
  { sessionDevice ∷ !Device
  , sessionHaskellOnAllocate ∷ !Vma.PFN_vmaAllocateDeviceMemoryFunction
  , sessionHaskellOnFree ∷ !Vma.PFN_vmaFreeDeviceMemoryFunction
  , sessionCountersSize ∷ !Int
  }

withSession ∷ Device → (Session → IO a) → IO a
withSession device action = do
  size ← fromIntegral <$> c_countersSize
  unless (size == countersBytes) $
    fail ("hetoimasia_block_counters is " <> show size <> " bytes in C and " <> show countersBytes <> " here")
  resultSize ← fromIntegral <$> c_shimResultSize
  unless (resultSize == shimResultBytes) $
    fail ("hetoimasia_shim_result is " <> show resultSize <> " bytes in C and " <> show shimResultBytes <> " here")
  bracket
    ((,) <$> wrapMemoryCallback haskellOnAllocate <*> wrapMemoryCallback haskellOnFree)
    (\(a, f) → freeHaskellFunPtr a >> freeHaskellFunPtr f)
    (\(a, f) → action (Session device a f size))

-- ---------------------------------------------------------------------------
-- Counters: the C callbacks' layout, which the Haskell callbacks update alike

countersBytes ∷ Int
countersBytes = 80

counterOpenedCount, counterOpenedBytes, counterFreedCount, counterFreedBytes, counterHeld, counterPeak, counterLogCapacity, counterLogCount, counterLog, counterCursor ∷ Int
counterOpenedCount = 0
counterOpenedBytes = 8
counterFreedCount = 16
counterFreedBytes = 24
counterHeld = 32
counterPeak = 40
counterLogCapacity = 48
counterLogCount = 56
counterLog = 64
counterCursor = 72

haskellOnAllocate ∷ Vma.FN_vmaAllocateDeviceMemoryFunction
haskellOnAllocate _ memoryType _ size user = do
  let p = castPtr user ∷ Ptr Word8
  bump p counterOpenedCount 1
  bump p counterOpenedBytes size
  held ← (+ size) <$> peekByteOff p counterHeld
  pokeByteOff p counterHeld held
  peak ← peekByteOff p counterPeak ∷ IO Word64
  when (held > peak) $ pokeByteOff p counterPeak held
  logEvent p (fromIntegral memoryType) size

haskellOnFree ∷ Vma.FN_vmaFreeDeviceMemoryFunction
haskellOnFree _ memoryType _ size user = do
  let p = castPtr user ∷ Ptr Word8
  bump p counterFreedCount 1
  bump p counterFreedBytes size
  held ← peekByteOff p counterHeld ∷ IO Word64
  pokeByteOff p counterHeld (held - size)
  logEvent p (fromIntegral memoryType .|. (1 `shiftL` 32)) size

bump ∷ Ptr Word8 → Int → Word64 → IO ()
bump p offset by = do
  value ← peekByteOff p offset ∷ IO Word64
  pokeByteOff p offset (value + by)
{-# INLINE bump #-}

logEvent ∷ Ptr Word8 → Word64 → Word64 → IO ()
logEvent p word size = do
  logPointer ← peekByteOff p counterLog ∷ IO (Ptr Word64)
  capacity ← peekByteOff p counterLogCapacity ∷ IO Word64
  count ← peekByteOff p counterLogCount ∷ IO Word64
  when (logPointer /= nullPtr && count < capacity) $ do
    let entry = logPointer `plusPtr` (fromIntegral count * 24)
    cursor ← peekByteOff p counterCursor ∷ IO Word64
    pokeByteOff entry 0 word
    pokeByteOff entry 8 size
    pokeByteOff entry 16 cursor
  pokeByteOff p counterLogCount (count + 1)

-- | One device-memory event VMA reported.
data BlockEvent = BlockEvent
  { eventFree ∷ !Bool
  , eventType ∷ !Word32
  , eventSize ∷ !Word64
  , eventOperation ∷ !Word64
  }
  deriving (Eq, Show)

-- | What the callbacks had counted at one moment.
data Counters = Counters
  { countersOpened ∷ !Word64
  , countersOpenedBytes ∷ !Word64
  , countersFreed ∷ !Word64
  , countersFreedBytes ∷ !Word64
  , countersHeld ∷ !Word64
  , countersPeakHeld ∷ !Word64
  , countersEvents ∷ ![BlockEvent]
  , countersEventsLost ∷ !Word64
  }
  deriving (Eq, Show)

readCounters ∷ Ptr Word8 → IO Counters
readCounters p = do
  let word offset = peekByteOff p offset ∷ IO Word64
  opened ← word counterOpenedCount
  openedBytes ← word counterOpenedBytes
  freed ← word counterFreedCount
  freedBytes ← word counterFreedBytes
  held ← word counterHeld
  peak ← word counterPeak
  capacity ← word counterLogCapacity
  count ← word counterLogCount
  logPointer ← peekByteOff p counterLog ∷ IO (Ptr Word64)
  events ←
    if logPointer == nullPtr
      then pure []
      else forM (takeWhile (< min capacity count) [0 ..]) $ \i → do
        let entry = logPointer `plusPtr` (fromIntegral i * 24)
        w ← peekByteOff entry 0 ∷ IO Word64
        size ← peekByteOff entry 8
        cursor ← peekByteOff entry 16
        pure (BlockEvent (testBit w 32) (fromIntegral (w .&. 0xffffffff)) size cursor)
  pure (Counters opened openedBytes freed freedBytes held peak (if count == 0 then [] else events) (if count > capacity then count - capacity else 0))

-- ---------------------------------------------------------------------------
-- Configurations

-- | Which call safety the binding's imports were compiled with.
data CallSafety = SafeCalls | UnsafeCalls
  deriving (Eq, Ord, Show)

callSafetyLabel ∷ CallSafety → String
callSafetyLabel SafeCalls = "safe-foreign-calls"
callSafetyLabel UnsafeCalls = "default unsafe calls"

-- | Where VMA's device-memory callbacks run.
data CallbackDestination = CallbacksInC | CallbacksInHaskell
  deriving (Eq, Ord, Show)

-- | Who makes the calls.
data Driver
  = DriverC
    -- ^ The C driver, the baseline.
  | DriverHackage
    -- ^ Haskell, through the Hackage binding, with the call safety the build
    -- chose.
  | DriverShim !CallSafety
    -- ^ Haskell, through the engine-owned shim, imported with this safety.
  deriving (Eq, Ord, Show)

-- | One measured side.
data Configuration = Configuration
  { configurationDriver ∷ !Driver
  , configurationCallbacks ∷ !CallbackDestination
  }
  deriving (Eq, Ord, Show)

-- | A configuration by name, given the call safety the build chose for the
-- Hackage binding.
configurationLabel ∷ CallSafety → Configuration → String
configurationLabel safety (Configuration driver callbacks) =
  driverLabel safety driver <> ", " <> (if callbacks == CallbacksInC then "C callbacks" else "Haskell callbacks")

-- | A driver by name, given the call safety the build chose for the Hackage
-- binding.
driverLabel ∷ CallSafety → Driver → String
driverLabel safety driver = case driver of
  DriverC → "C driver"
  DriverHackage → "Hackage binding (" <> callSafetyLabel safety <> ")"
  DriverShim SafeCalls → "engine shim (safe calls)"
  DriverShim UnsafeCalls → "engine shim (unsafe calls)"

-- ---------------------------------------------------------------------------
-- Allocators

withAllocator
  ∷ Session
  → Vma.PFN_vmaAllocateDeviceMemoryFunction
  → Vma.PFN_vmaFreeDeviceMemoryFunction
  → Ptr ()
  → (Vma.Allocator → IO a)
  → IO a
withAllocator session onAllocate onFree user =
  bracket (Vma.createAllocator (allocatorCreateInfo (sessionDevice session) onAllocate onFree user)) safeDestroyAllocator

-- | The allocator configuration every pass shares; only the callbacks vary.
allocatorCreateInfo
  ∷ Device
  → Vma.PFN_vmaAllocateDeviceMemoryFunction
  → Vma.PFN_vmaFreeDeviceMemoryFunction
  → Ptr ()
  → Vma.AllocatorCreateInfo
allocatorCreateInfo device onAllocate onFree user =
  Vma.AllocatorCreateInfo
    { Vma.flags = Vma.ALLOCATOR_CREATE_EXTERNALLY_SYNCHRONIZED_BIT
    , Vma.physicalDevice = Vk.physicalDeviceHandle (devicePhysical device)
    , Vma.device = Vk.deviceHandle (deviceVulkan device)
    , Vma.preferredLargeHeapBlockSize = preferredLargeHeapBlockSize
    , Vma.allocationCallbacks = Nothing
    , Vma.deviceMemoryCallbacks =
        Just Vma.DeviceMemoryCallbacks {Vma.pfnAllocate = onAllocate, Vma.pfnFree = onFree, Vma.userData = user}
    , Vma.heapSizeLimit = nullPtr
    , Vma.vulkanFunctions =
        Just
          (zero ∷ Vma.VulkanFunctions)
            { Vma.vkGetInstanceProcAddr = castFunPtr loaderGetInstanceProcAddr
            , Vma.vkGetDeviceProcAddr = castFunPtr loaderGetDeviceProcAddr
            }
    , Vma.instance' = Vk.instanceHandle (deviceInstance device)
    , Vma.vulkanApiVersion = API_VERSION_1_3
    , Vma.typeExternalMemoryHandleTypes = nullPtr
    }

-- | Which call safety the binding was built with, decided by behaviour: a
-- C device-memory callback waits, inside a binding call that opens a block,
-- for another Haskell thread to release it. A safe call releases the
-- capability, so that thread runs; an unsafe call holds it, and on one
-- capability the wait times out after two seconds. No Haskell callback is
-- installed, so the check is harmless under either build.
detectCallSafety ∷ Session → ResourceClass → IO (Either String CallSafety)
detectCallSafety session geometry = do
  c_detectReset
  outcome ←
    withAllocator session cDetectOnAllocate nullFunPtr nullPtr $ \allocator → do
      watcher ← forkIO watch
      created ← try (Vma.createBuffer allocator (bufferInfo (64 * 1024) (specUsage (classSpec geometry))) (allocationInfo geometry 0))
      killThread watcher
      case created of
        Left (VulkanException result) → pure (Left ("the call-safety check's buffer failed with " <> show result))
        Right (buffer, allocation, _) → do
          Vma.destroyBuffer allocator buffer allocation
          Right <$> c_detectResult
  pure $ case outcome of
    Left problem → Left problem
    Right 1 → Right SafeCalls
    Right 0 → Right UnsafeCalls
    Right _ → Left "the call-safety check's callback never ran, so the binding's call safety is unknown"
  where
    watch = do
      entered ← c_detectEntered
      if entered /= 0 then c_detectRelease else threadDelay 100 >> watch

-- | Each class's memory type, chosen by the engine's rule from the
-- @memoryTypeBits@ of one probe resource of the class.
resolveClasses ∷ Device → IO (Either String (Vector.Vector ResourceClass))
resolveClasses device = do
  resolved ← forM classSpecs $ \spec → do
    bits ←
      if specIsImage spec
        then do
          image ← Vk.createImage (deviceVulkan device) (imageInfo 256 256 spec) Nothing
          requirements ← Vk.getImageMemoryRequirements (deviceVulkan device) image
          Vk.destroyImage (deviceVulkan device) image Nothing
          pure (Vk.memoryTypeBits (requirements ∷ Vk.MemoryRequirements))
        else do
          buffer ← Vk.createBuffer (deviceVulkan device) (bufferInfo (64 * 1024) (specUsage spec)) Nothing
          requirements ← Vk.getBufferMemoryRequirements (deviceVulkan device) buffer
          Vk.destroyBuffer (deviceVulkan device) buffer Nothing
          pure (Vk.memoryTypeBits (requirements ∷ Vk.MemoryRequirements))
    pure $ case chooseMemoryType (deviceMemoryTypes device) bits (specRequired spec) (specPreferred spec) (specAvoided spec) of
      Left problem → Left (specName spec <> ": " <> problem)
      Right chosen →
        Right
          ResourceClass
            { classSpec = spec
            , classMemoryType = offerIndex chosen
            , classTypeBits = bits
            , classPreferredBlockSize = preferredBlockSize device (offerIndex chosen)
            }
  pure (Vector.fromList <$> sequence resolved)

bufferInfo ∷ Word64 → Word32 → Vk.BufferCreateInfo '[]
bufferInfo size usage =
  Vk.BufferCreateInfo
    { Vk.next = ()
    , Vk.flags = zero
    , Vk.size = size
    , Vk.usage = Vk.BufferUsageFlagBits usage
    , Vk.sharingMode = Vk.SHARING_MODE_EXCLUSIVE
    , Vk.queueFamilyIndices = Vector.empty
    }

imageInfo ∷ Word32 → Word32 → ClassSpec → Vk.ImageCreateInfo '[]
imageInfo width height spec =
  Vk.ImageCreateInfo
    { Vk.next = ()
    , Vk.flags = zero
    , Vk.imageType = Vk.IMAGE_TYPE_2D
    , Vk.format = Vk.Format (fromIntegral (specFormat spec))
    , Vk.extent = Vk.Extent3D width height 1
    , Vk.mipLevels = 1
    , Vk.arrayLayers = 1
    , Vk.samples = Vk.SAMPLE_COUNT_1_BIT
    , Vk.tiling = Vk.IMAGE_TILING_OPTIMAL
    , Vk.usage = Vk.ImageUsageFlagBits (specUsage spec)
    , Vk.sharingMode = Vk.SHARING_MODE_EXCLUSIVE
    , Vk.queueFamilyIndices = Vector.empty
    , Vk.initialLayout = Vk.IMAGE_LAYOUT_UNDEFINED
    }

-- | A class's allocation request, with extra VMA flags.
allocationInfo ∷ ResourceClass → Word32 → Vma.AllocationCreateInfo
allocationInfo resourceClass extra =
  Vma.AllocationCreateInfo
    { Vma.flags = Vma.AllocationCreateFlagBits (specAllocationFlags spec .|. extra)
    , Vma.usage = Vma.MEMORY_USAGE_UNKNOWN
    , Vma.requiredFlags = Vk.MemoryPropertyFlagBits (specRequired spec)
    , Vma.preferredFlags = Vk.MemoryPropertyFlagBits (specPreferred spec)
    , Vma.memoryTypeBits = 1 `shiftL` fromIntegral (classMemoryType resourceClass)
    , Vma.pool = Vma.Pool 0
    , Vma.userData = nullPtr
    , Vma.priority = 0
    }
  where
    spec = classSpec resourceClass

neverAllocate ∷ Word32
neverAllocate = let Vma.AllocationCreateFlagBits bits = Vma.ALLOCATION_CREATE_NEVER_ALLOCATE_BIT in bits

-- | Marshal each struct the C driver restates through the binding's layout
-- and have C read it back, and the reverse for those C writes. Any
-- disagreement stops the probe before a pass.
checkProductionLayouts ∷ IO ()
checkProductionLayouts = do
  let Vma.MemoryUsage usage = Vma.MEMORY_USAGE_AUTO_PREFER_HOST
      userData = intPtrToPtr 0x5a5a5a
      request =
        Vma.AllocationCreateInfo
          { Vma.flags = Vma.ALLOCATION_CREATE_MAPPED_BIT .|. Vma.ALLOCATION_CREATE_NEVER_ALLOCATE_BIT
          , Vma.usage = Vma.MEMORY_USAGE_AUTO_PREFER_HOST
          , Vma.requiredFlags = Vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT
          , Vma.preferredFlags = Vk.MEMORY_PROPERTY_HOST_CACHED_BIT
          , Vma.memoryTypeBits = 0x2a
          , Vma.pool = Vma.Pool 0x123456
          , Vma.userData = userData
          , Vma.priority = 0.75
          }
  requestOk ←
    withCStruct request $ \pointer →
      c_checkCreateInfo pointer 0x6 usage 0x2 0x8 0x2a 0x123456 userData 0.75 (fromIntegral (cStructSize @Vma.AllocationCreateInfo))
  when (requestOk == 0) $ fail "the C driver's VmaAllocationCreateInfo does not match the binding's layout"
  info ←
    allocaBytes (cStructSize @Vma.AllocationInfo) $ \pointer → do
      size ← c_fillAllocationInfo pointer 100
      unless (size == fromIntegral (cStructSize @Vma.AllocationInfo)) $
        fail ("VmaAllocationInfo is " <> show size <> " bytes in C and " <> show (cStructSize @Vma.AllocationInfo) <> " in the binding")
      peekCStruct pointer
  let Vma.AllocationInfo {Vma.memoryType, Vma.deviceMemory = Vk.DeviceMemory memory, Vma.offset, Vma.size, Vma.mappedData, Vma.userData = infoUser, Vma.name} = info
  unless
    ( (memoryType, memory, offset, size) == (101, 102, 103, 104)
        && mappedData == intPtrToPtr 105
        && infoUser == intPtrToPtr 106
        && name == Nothing
    )
    $ fail "the C driver's VmaAllocationInfo does not match the binding's layout"
  budget ←
    allocaBytes (cStructSize @Vma.Budget) $ \pointer → do
      size' ← c_fillBudget pointer 200
      unless (size' == fromIntegral (cStructSize @Vma.Budget)) $
        fail ("VmaBudget is " <> show size' <> " bytes in C and " <> show (cStructSize @Vma.Budget) <> " in the binding")
      peekCStruct pointer
  let Vma.Budget {Vma.statistics = Vma.Statistics {Vma.blockCount, Vma.allocationCount, Vma.blockBytes, Vma.allocationBytes}, Vma.usage = budgetUsage, Vma.budget = budgetBytes} = budget
  unless ((blockCount, allocationCount) == (201, 202) && (blockBytes, allocationBytes, budgetUsage, budgetBytes) == (203, 204, 205, 206)) $
    fail "the C driver's VmaBudget does not match the binding's layout"

-- ---------------------------------------------------------------------------
-- Passes

-- | What a pass records beyond its summary.
data Mode
  = EvidenceMode
  | PerOperation !(StorableMutable.IOVector Word64) !(StorableMutable.IOVector Word64)
    -- ^ Each operation's accumulated nanoseconds, and an allocation's
    -- allocating call's alone.
  | Whole

-- | The summary words, as the C driver writes them.
data SummaryField
  = SummaryChecksum
  | SummaryCreates
  | SummaryDestroys
  | SummaryHits
  | SummaryMisses
  | SummaryOther
  | SummaryTimed
  | SummaryBoundBroken
  | SummaryPeakRequested
  | SummaryPeakAllocated
  | SummaryHeldMismatches
  | SummaryFailures
  | SummaryLeftLive
  | SummaryRetained
  deriving (Eq, Show, Enum, Bounded)

summaryWord ∷ PassResult → SummaryField → Word64
summaryWord pass field = passSummary pass Unboxed.! fromEnum field

summaryWords, evidenceWords, checkpointWords ∷ Int
summaryWords = 16
evidenceWords = 8
checkpointWords = 6

data PassResult = PassResult
  { passSummary ∷ !(Unboxed.Vector Word64)
  , passRetained ∷ !Counters
    -- ^ The callbacks' counts once the script's resources were freed, before
    -- the allocator was destroyed: what VMA retained.
  , passReleased ∷ !Counters
    -- ^ After the allocator was destroyed.
  , passEvidence ∷ !(Unboxed.Vector Word64)
    -- ^ 'evidenceWords' per operation; empty outside the evidence mode.
  , passCheckpoints ∷ !(Unboxed.Vector Word64)
    -- ^ 'checkpointWords' per checkpoint; empty outside the evidence mode.
  }

-- | The device-memory callbacks a configuration installs.
callbacksFor ∷ Session → Configuration → (Vma.PFN_vmaAllocateDeviceMemoryFunction, Vma.PFN_vmaFreeDeviceMemoryFunction)
callbacksFor session configuration = case configurationCallbacks configuration of
  CallbacksInC → (cOnAllocate, cOnFree)
  CallbacksInHaskell → (sessionHaskellOnAllocate session, sessionHaskellOnFree session)

-- | Replay a script once in one configuration.
runPass ∷ Session → Configuration → Script → Mode → IO PassResult
runPass session configuration script mode = do
  let count = Unboxed.length (scriptKinds script)
      evidence = case mode of EvidenceMode → True; _ → False
      logCapacity = if evidence then 65536 else 0 ∷ Int
      (onAllocate, onFree) = callbacksFor session configuration
  when (configurationDriver configuration == DriverC && configurationCallbacks configuration /= CallbacksInC) $
    fail "the C driver runs with C callbacks only"
  when (configurationDriver configuration == DriverShim UnsafeCalls && configurationCallbacks configuration /= CallbacksInC) $
    fail "an unsafe call may not reach a Haskell callback"
  bracket (callocBytes countersBytes) free $ \counters →
    bracket (if evidence then mallocBytes (logCapacity * 24) else pure nullPtr) (\p → when (p /= nullPtr) (free p)) $ \logBuffer → do
      pokeByteOff counters counterLogCapacity (fromIntegral logCapacity ∷ Word64)
      pokeByteOff counters counterLog (logBuffer ∷ Ptr Word64)
      summary ← StorableMutable.replicate summaryWords 0
      rows ← StorableMutable.replicate (if evidence then max 1 count * evidenceWords else 1) 0
      checkpointRows ← StorableMutable.replicate (if evidence then max 1 (length (scriptCheckpoints script)) * checkpointWords else 1) 0
      retained ←
        withAllocator session onAllocate onFree (castPtr counters) $ \allocator → do
          case configurationDriver configuration of
            DriverC → replayC session allocator (castPtr counters) script mode summary rows checkpointRows
            DriverHackage →
              bracket (callocBytes shimResultBytes) free $ \out →
                replayHaskell (hackageApi out) out session allocator (castPtr counters) script mode summary rows checkpointRows
            -- Each API is passed statically, so that once the replay is
            -- inlined every call site is the import itself, as engine code's
            -- would be, rather than a call through a record.
            DriverShim UnsafeCalls →
              bracket (callocBytes shimResultBytes) free $ \out →
                replayHaskell (shimApi UnsafeCalls out) out session allocator (castPtr counters) script mode summary rows checkpointRows
            DriverShim SafeCalls →
              bracket (callocBytes shimResultBytes) free $ \out →
                replayHaskell (shimApi SafeCalls out) out session allocator (castPtr counters) script mode summary rows checkpointRows
          readCounters counters
      released ← readCounters counters
      frozenSummary ← Unboxed.fromList . Storable.toList <$> Storable.freeze summary
      frozenRows ← if evidence then Unboxed.fromList . Storable.toList . Storable.take (count * evidenceWords) <$> Storable.freeze rows else pure Unboxed.empty
      frozenCheckpoints ←
        if evidence
          then Unboxed.fromList . Storable.toList . Storable.take (length (scriptCheckpoints script) * checkpointWords) <$> Storable.freeze checkpointRows
          else pure Unboxed.empty
      pure (PassResult frozenSummary retained released frozenRows frozenCheckpoints)

modeCode ∷ Mode → Word32
modeCode EvidenceMode = 0
modeCode (PerOperation _ _) = 1
modeCode Whole = 2

replayC
  ∷ Session → Vma.Allocator → Ptr Word64 → Script → Mode
  → StorableMutable.IOVector Word64 → StorableMutable.IOVector Word64 → StorableMutable.IOVector Word64 → IO ()
replayC session allocator counters script mode summary rows checkpointRows = do
  unused ← StorableMutable.replicate 1 0
  let (elapsed, allocating) = case mode of
        PerOperation e a → (e, a)
        _ → (unused, unused)
      device = sessionDevice session
  result ←
    Storable.unsafeWith (scriptEncodedClasses script) $ \classes →
      Storable.unsafeWith (scriptEncodedOps script) $ \ops →
        Storable.unsafeWith (scriptPreferredBlockSizes script) $ \preferred →
          StorableMutable.unsafeWith elapsed $ \elapsedPointer →
            StorableMutable.unsafeWith allocating $ \allocatingPointer →
              StorableMutable.unsafeWith rows $ \rowsPointer →
                StorableMutable.unsafeWith checkpointRows $ \checkpointPointer →
                  StorableMutable.unsafeWith summary $ \summaryPointer →
                    c_replayScript
                      allocator
                      (Vk.deviceHandle (deviceVulkan device))
                      (fromIntegral (length (deviceHeaps device)))
                      (castPtr classes)
                      (castPtr ops)
                      (fromIntegral (Unboxed.length (scriptKinds script)))
                      (fromIntegral (scriptIdentities script))
                      preferred
                      counters
                      (modeCode mode)
                      elapsedPointer
                      allocatingPointer
                      rowsPointer
                      checkpointPointer
                      summaryPointer
  unless (result == 0) $ fail ("the C driver failed with " <> show result)

-- | One class, prepared once per pass with the values each API takes.
data Prepared = Prepared
  { preparedImage ∷ !Bool
  , preparedSpec ∷ !ClassSpec
  , preparedNever ∷ !Vma.AllocationCreateInfo
  , preparedAllocating ∷ !Vma.AllocationCreateInfo
  , preparedUsage ∷ !Word32
  , preparedFormat ∷ !Word32
  , preparedFlags ∷ !Word32
  , preparedRequired ∷ !Word32
  , preparedPreferred ∷ !Word32
  , preparedTypeBits ∷ !Word32
  }

prepare ∷ ResourceClass → Prepared
prepare c =
  Prepared
    { preparedImage = specIsImage spec
    , preparedSpec = spec
    , preparedNever = allocationInfo c neverAllocate
    , preparedAllocating = allocationInfo c 0
    , preparedUsage = specUsage spec
    , preparedFormat = specFormat spec
    , preparedFlags = specAllocationFlags spec
    , preparedRequired = specRequired spec
    , preparedPreferred = specPreferred spec
    , preparedTypeBits = 1 `shiftL` fromIntegral (classMemoryType c)
    }
  where
    spec = classSpec c

-- | The calls a Haskell driver makes. Each is the whole call as the engine
-- would make it through that API, marshalling included. A creation answers
-- its @VkResult@ and, on success, writes the handle, the allocation and the
-- allocation's memory type, offset and size into the pass's output record
-- (@hetoimasia_shim_result@'s layout), so that nothing but the call itself
-- runs inside the timed interval.
data Api = Api
  { apiCreateBuffer ∷ Vma.Allocator → Prepared → Word64 → Bool → IO Int32
  , apiCreateImage ∷ Vma.Allocator → Prepared → Word32 → Word32 → Bool → IO Int32
  , apiDestroyBuffer ∷ Vma.Allocator → Word64 → Word64 → IO ()
  , apiDestroyImage ∷ Vma.Allocator → Word64 → Word64 → IO ()
  , apiMap ∷ Vma.Allocator → Word64 → IO Bool
  , apiUnmap ∷ Vma.Allocator → Word64 → IO ()
  , apiFlush ∷ Vma.Allocator → Word64 → IO ()
  , apiInvalidate ∷ Vma.Allocator → Word64 → IO ()
  }

-- | The Hackage binding, which raises a failed call as a 'VulkanException':
-- that is how @NEVER_ALLOCATE@'s refusal arrives. Storing what the binding
-- returned is part of its call, as reading the record is part of the shim's.
hackageApi ∷ Ptr Word8 → Api
{-# INLINE hackageApi #-}
hackageApi out =
  Api
    { apiCreateBuffer = \allocator p size never → do
        r ← try (Vma.createBuffer allocator (bufferInfo size (preparedUsage p)) (if never then preparedNever p else preparedAllocating p))
        case r of
          Right (Vk.Buffer h, Vma.Allocation a, info) → store h a info
          Left (VulkanException (Vk.Result e)) → pure e
    , apiCreateImage = \allocator p width height never → do
        r ← try (Vma.createImage allocator (imageInfo width height (preparedSpec p)) (if never then preparedNever p else preparedAllocating p))
        case r of
          Right (Vk.Image h, Vma.Allocation a, info) → store h a info
          Left (VulkanException (Vk.Result e)) → pure e
    , apiDestroyBuffer = \allocator h a → Vma.destroyBuffer allocator (Vk.Buffer h) (Vma.Allocation a)
    , apiDestroyImage = \allocator h a → Vma.destroyImage allocator (Vk.Image h) (Vma.Allocation a)
    , apiMap = \allocator a → Vma.mapMemory allocator (Vma.Allocation a) >>= \p → pure (p /= nullPtr)
    , apiUnmap = \allocator a → Vma.unmapMemory allocator (Vma.Allocation a)
    , apiFlush = \allocator a → Vma.flushAllocation allocator (Vma.Allocation a) 0 Vk.WHOLE_SIZE
    , apiInvalidate = \allocator a → Vma.invalidateAllocation allocator (Vma.Allocation a) 0 Vk.WHOLE_SIZE
    }
  where
    store h a Vma.AllocationInfo {Vma.memoryType, Vma.offset, Vma.size} = do
      pokeByteOff out 0 h
      pokeByteOff out 8 a
      pokeByteOff out 16 memoryType
      pokeByteOff out 24 offset
      pokeByteOff out 32 size
      pure 0

-- | The engine-owned shim through imports of one safety, answering into the
-- pass's output record.
shimApi ∷ CallSafety → Ptr Word8 → Api
{-# INLINE shimApi #-}
shimApi safety out =
  Api
    { apiCreateBuffer = \allocator p size never →
        createBuffer allocator size (preparedUsage p) (flags p never) (preparedRequired p) (preparedPreferred p) (preparedTypeBits p) out
    , apiCreateImage = \allocator p width height never →
        createImage allocator width height (preparedFormat p) (preparedUsage p) (flags p never) (preparedRequired p) (preparedPreferred p) (preparedTypeBits p) out
    , apiDestroyBuffer = destroyBuffer
    , apiDestroyImage = destroyImage
    , apiMap = \allocator a → (/= nullPtr) <$> mapMemory allocator a
    , apiUnmap = unmapMemory
    , apiFlush = \allocator a → flush allocator a >>= check "vmaFlushAllocation"
    , apiInvalidate = \allocator a → invalidate allocator a >>= check "vmaInvalidateAllocation"
    }
  where
    flags p never = preparedFlags p .|. (if never then neverAllocate else 0)
    check what r = unless (r == 0) $ fail (what <> " failed with " <> show r)
    (createBuffer, createImage, destroyBuffer, destroyImage, mapMemory, unmapMemory, flush, invalidate) = case safety of
      UnsafeCalls → (u_shimCreateBuffer, u_shimCreateImage, u_shimDestroyBuffer, u_shimDestroyImage, u_shimMap, u_shimUnmap, u_shimFlush, u_shimInvalidate)
      SafeCalls → (s_shimCreateBuffer, s_shimCreateImage, s_shimDestroyBuffer, s_shimDestroyImage, s_shimMap, s_shimUnmap, s_shimFlush, s_shimInvalidate)

fnvPrime, fnvOffset ∷ Word64
fnvPrime = 1099511628211
fnvOffset = 1469598103934665603

-- | The C driver's loop, made from Haskell through one API: the same
-- operations in the same order, the same timed intervals, the same D-40
-- reconciliation and the same evidence.
{-# INLINE replayHaskell #-}
replayHaskell
  ∷ Api → Ptr Word8 → Session → Vma.Allocator → Ptr Word64 → Script → Mode
  → StorableMutable.IOVector Word64 → StorableMutable.IOVector Word64 → StorableMutable.IOVector Word64 → IO ()
replayHaskell api out session allocator counters script mode summary rows checkpointRows = do
  let count = Unboxed.length (scriptKinds script)
      identities = max 1 (scriptIdentities script)
      device = sessionDevice session
      heapCount = fromIntegral (length (deviceHeaps device))
      prepared = Vector.map prepare (scriptClasses script)
      perOperation = case mode of PerOperation _ _ → True; _ → False
      evidence = case mode of EvidenceMode → True; _ → False
      counter offset = peekByteOff counters offset ∷ IO Word64
      clock = if perOperation then probeNow else pure 0
  handles ← UnboxedMutable.replicate identities (0 ∷ Word64)
  allocations ← UnboxedMutable.replicate identities (0 ∷ Word64)
  requestedBytes ← UnboxedMutable.replicate identities (0 ∷ Word64)
  allocatedBytes ← UnboxedMutable.replicate identities (0 ∷ Word64)
  isImage ← UnboxedMutable.replicate identities False
  live ← UnboxedMutable.replicate identities False
  -- checksum, creates, destroys, hits, misses, other, timed, bound broken,
  -- peak requested, peak allocated, held mismatches, failures, then the live
  -- requested and allocated bytes and resources.
  acc ← UnboxedMutable.replicate 16 (0 ∷ Word64)
  UnboxedMutable.write acc 0 fnvOffset
  -- A creation's allocating-call time, and what its attempt left opened.
  scratch ← UnboxedMutable.replicate 2 (0 ∷ Word64)
  let add field by = UnboxedMutable.unsafeModify acc (+ by) field
      mix value = UnboxedMutable.unsafeModify acc (\h → h * fnvPrime + value) 0
      elapsedAt i by = case mode of
        PerOperation e _ → StorableMutable.unsafeModify e (+ by) i
        _ → pure ()
      allocatingAt i by = case mode of
        PerOperation _ a → StorableMutable.unsafeModify a (+ by) i
        _ → pure ()
      -- Everything a creation needs is evaluated before its clock starts, as
      -- the C driver builds its create infos before its own; inside the
      -- interval are the calls and, after the NEVER_ALLOCATE attempt, the
      -- read of what it opened, exactly as in C.
      create !i !code = do
        let !spec = Vector.unsafeIndex prepared (fromIntegral (Unboxed.unsafeIndex (scriptClassIndices script) i))
            !size = Unboxed.unsafeIndex (scriptSizes script) i
            !width = Unboxed.unsafeIndex (scriptWidths script) i
            !height = Unboxed.unsafeIndex (scriptHeights script) i
            !identity = fromIntegral (Unboxed.unsafeIndex (scriptIds script) i)
            !d40 = code == CreateD40
            !image = preparedImage spec
            attempt never
              | image = apiCreateImage api allocator spec width height never
              | otherwise = apiCreateBuffer api allocator spec size never
        pokeByteOff counters counterCursor (fromIntegral i ∷ Word64)
        openedBefore ← counter counterOpenedBytes
        UnboxedMutable.unsafeWrite scratch 0 0
        start ← clock
        first ← if d40 then attempt True else pure (-1)
        when d40 $ counter counterOpenedBytes >>= UnboxedMutable.unsafeWrite scratch 1
        let !hit = d40 && first == 0
        result ←
          if hit
            then pure first
            else do
              allocatingStart ← clock
              r ← attempt False
              allocatingEnd ← clock
              UnboxedMutable.unsafeWrite scratch 0 (allocatingEnd - allocatingStart)
              pure r
        when perOperation $ do
          end ← clock
          allocatingTime ← UnboxedMutable.unsafeRead scratch 0
          elapsedAt i (end - start)
          allocatingAt i allocatingTime
          add 6 (end - start)
        openedByAttempt ← if d40 then subtract openedBefore <$> UnboxedMutable.unsafeRead scratch 1 else pure 0
        opened ← subtract openedBefore <$> counter counterOpenedBytes
        let placed = result == 0
            allocated = not hit && placed
        handle ← peekByteOff out 0 ∷ IO Word64
        allocation ← peekByteOff out 8 ∷ IO Word64
        memoryType ← peekByteOff out 16 ∷ IO Word32
        offset ← peekByteOff out 24 ∷ IO Word64
        allocationSize ← peekByteOff out 32 ∷ IO Word64
        let openedByAllocating = opened - openedByAttempt
            preferred = scriptPreferredBlockSizes script Storable.! fromIntegral memoryType
            broken = placed && (openedByAllocating > max allocationSize preferred || openedByAttempt /= 0)
        when broken $ add 7 1
        add 1 1
        if not placed
          then do
            add 11 1
            UnboxedMutable.unsafeWrite live identity False
          else do
            when hit $ add 3 1
            when (d40 && allocated) $ add 4 1
            mix (fromIntegral i + 1)
            mix (fromIntegral memoryType + 1)
            mix offset
            mix allocationSize
            UnboxedMutable.unsafeWrite handles identity handle
            UnboxedMutable.unsafeWrite allocations identity allocation
            UnboxedMutable.unsafeWrite requestedBytes identity size
            UnboxedMutable.unsafeWrite allocatedBytes identity allocationSize
            UnboxedMutable.unsafeWrite isImage identity image
            UnboxedMutable.unsafeWrite live identity True
            add 12 size
            add 13 allocationSize
            add 14 1
            liveRequested ← UnboxedMutable.unsafeRead acc 12
            liveAllocated ← UnboxedMutable.unsafeRead acc 13
            UnboxedMutable.unsafeModify acc (max liveRequested) 8
            UnboxedMutable.unsafeModify acc (max liveAllocated) 9
        when evidence $ do
          let at k = StorableMutable.unsafeWrite rows (evidenceWords * i + k)
              outcome =
                (if placed then 1 else 0)
                  .|. (if hit then 2 else 0)
                  .|. (if allocated then 4 else 0)
                  .|. (if broken then 8 else 0)
                  .|. (if openedByAttempt /= 0 then 16 else 0)
          at 0 outcome
          when placed $ do
            at 1 (fromIntegral memoryType)
            at 2 offset
            at 3 allocationSize
          at 4 opened
      destroyAt i = do
        let identity = fromIntegral (scriptIds script Unboxed.! i)
        alive ← UnboxedMutable.unsafeRead live identity
        when alive $ do
          handle ← UnboxedMutable.unsafeRead handles identity
          allocation ← UnboxedMutable.unsafeRead allocations identity
          image ← UnboxedMutable.unsafeRead isImage identity
          pokeByteOff counters counterCursor (fromIntegral i ∷ Word64)
          start ← clock
          if image
            then apiDestroyImage api allocator handle allocation
            else apiDestroyBuffer api allocator handle allocation
          when perOperation $ do
            end ← clock
            elapsedAt i (end - start)
            add 6 (end - start)
          add 2 1
          UnboxedMutable.unsafeRead requestedBytes identity >>= \r → UnboxedMutable.unsafeModify acc (subtract r) 12
          UnboxedMutable.unsafeRead allocatedBytes identity >>= \a → UnboxedMutable.unsafeModify acc (subtract a) 13
          UnboxedMutable.unsafeModify acc (subtract 1) 14
          UnboxedMutable.unsafeWrite live identity False
      memoryOp i code = do
        let identity = fromIntegral (scriptIds script Unboxed.! i)
        alive ← UnboxedMutable.unsafeRead live identity
        when alive $ do
          allocation ← UnboxedMutable.unsafeRead allocations identity
          pokeByteOff counters counterCursor (fromIntegral i ∷ Word64)
          start ← clock
          mapped ← case code of
            Map → apiMap api allocator allocation
            Unmap → apiUnmap api allocator allocation >> pure False
            Flush → apiFlush api allocator allocation >> pure False
            _ → apiInvalidate api allocator allocation >> pure False
          when perOperation $ do
            end ← clock
            elapsedAt i (end - start)
            add 6 (end - start)
          add 5 1
          mix (if code == Map && mapped then 1 else 0)
      checkpointAt i = when evidence $ do
        let ordinal = fromIntegral (scriptIds script Unboxed.! i)
            at k = StorableMutable.unsafeWrite checkpointRows (checkpointWords * ordinal + k)
        liveRequested ← UnboxedMutable.unsafeRead acc 12
        liveAllocated ← UnboxedMutable.unsafeRead acc 13
        resources ← UnboxedMutable.unsafeRead acc 14
        held ← counter counterHeld
        heldByVma ← c_heldBytes allocator heapCount
        opened ← counter counterOpenedCount
        at 0 liveRequested
        at 1 liveAllocated
        at 2 held
        at 3 heldByVma
        at 4 resources
        at 5 opened
        when (held /= heldByVma) $ add 10 1
      step i = case opCode (Unboxed.unsafeIndex (scriptKinds script) i) of
        CreateD40 → create i CreateD40
        CreatePlain → create i CreatePlain
        Destroy → destroyAt i
        Checkpoint → checkpointAt i
        code → memoryOp i code
      loop i
        | i >= count = pure ()
        | otherwise = step i >> loop (i + 1)
  wholeStart ← case mode of Whole → probeNow; _ → pure 0
  loop 0
  case mode of
    Whole → probeNow >>= \end → UnboxedMutable.write acc 6 (end - wholeStart)
    _ → pure ()
  -- Whatever the script left live is freed untimed.
  pokeByteOff counters counterCursor (fromIntegral count ∷ Word64)
  leftLive ←
    sum <$> forM [0 .. identities - 1] (\identity → do
      alive ← UnboxedMutable.read live identity
      if not alive
        then pure 0
        else do
          handle ← UnboxedMutable.read handles identity
          allocation ← UnboxedMutable.read allocations identity
          image ← UnboxedMutable.read isImage identity
          if image
            then apiDestroyImage api allocator handle allocation
            else apiDestroyBuffer api allocator handle allocation
          UnboxedMutable.write live identity False
          pure (1 ∷ Word64))
  when evidence $ do
    held ← counter counterHeld
    heldByVma ← c_heldBytes allocator heapCount
    when (held /= heldByVma) $ add 10 1
  retained ← counter counterHeld
  forM_ [0 .. 11] $ \k → UnboxedMutable.read acc k >>= StorableMutable.write summary k
  StorableMutable.write summary 12 leftLive
  StorableMutable.write summary 13 retained
