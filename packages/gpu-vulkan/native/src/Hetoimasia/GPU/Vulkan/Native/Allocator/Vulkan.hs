{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The production allocator under "Hetoimasia.GPU.Vulkan.Native.Allocator":
-- VMA, through the engine's own shim.
--
-- One allocator per device, created right after the device by the roots and
-- destroyed right before it. It is externally synchronised, and every call is
-- made on the graphics owner's thread. Its Vulkan entry points are the
-- backend's own dispatch: the instance's @vkGetInstanceProcAddr@ and the
-- device's @vkGetDeviceProcAddr@ from the binding's command tables, from which
-- VMA fetches the rest. The large-heap block size is stated explicitly
-- ('largeHeapBlockSize'), so the engine's reservation bound computes the
-- preferred block size exactly as VMA does.
--
-- Every VMA call goes through the private shim module, imported @unsafe@ with
-- the device-memory callbacks counting in C; see docs/gpu_backend.md, "The
-- allocator". The memory requirements of a buffer not yet created are the
-- binding's own @vkGetDeviceBufferMemoryRequirements@ (Vulkan 1.3).
module Hetoimasia.GPU.Vulkan.Native.Allocator.Vulkan
  ( vmaAllocatorOps
  , memoryTypeOffers
  , creationAnswer
  ) where

import Control.Exception (throwIO, toException)
import Control.Monad (unless, when)
import Data.Bits ((.&.))
import qualified Data.ByteString as ByteString
import qualified Data.Vector as Vector
import Foreign.ForeignPtr (mallocForeignPtrBytes)
import Foreign.Marshal.Alloc (alloca)
import Data.Int (Int32)
import Foreign.Ptr (Ptr, castFunPtrToPtr, castPtr)
import Foreign.Storable (peek)
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Core10 hiding (MemoryRequirements)
import Vulkan.Core11 (MemoryRequirements2 (..))
import Vulkan.Core13 (DeviceBufferMemoryRequirements (..), getDeviceBufferMemoryRequirements, data API_VERSION_1_3)
import Vulkan.Dynamic (DeviceCmds (..), InstanceCmds (..))
import Vulkan.Exception (VulkanException (..))
import Vulkan.Zero (zero)

import Hetoimasia.GPU.Vulkan.Native.Allocator
  ( AllocatorOps (..)
  , BufferMemory (..)
  , BufferRequest (..)
  , Creation (..)
  , MemoryProperty (..)
  , MemoryRequirements (..)
  , MemoryTypeOffer (..)
  , Placement (..)
  , largeHeapBlockSize
  , preferredBlockSize
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Vma

-- | Create the device's allocator. A creation that failed raised the
-- binding's 'VulkanException' for its result, having made nothing.
vmaAllocatorOps ∷ Instance → PhysicalDevice → Device → IO AllocatorOps
vmaAllocatorOps created physical device = do
  declared ← c_resultSize
  unless (fromIntegral declared == resultBytes) $
    fail ("the VMA shim's result record is " <> show declared <> " bytes, and " <> show resultBytes <> " are read")
  properties ← getPhysicalDeviceMemoryProperties physical
  result ← mallocForeignPtrBytes resultBytes
  state ← alloca $ \out → do
    code ←
      c_create
        (castPtr (instanceHandle created))
        (castPtr (physicalDeviceHandle physical))
        (castPtr (deviceHandle device))
        (castFunPtrToPtr (pVkGetInstanceProcAddr created.instanceCmds))
        (castFunPtrToPtr (pVkGetDeviceProcAddr device.deviceCmds))
        API_VERSION_1_3
        (fromIntegral largeHeapBlockSize)
        out
    failing code
    peek out
  let call ∷ (Ptr VmaResult → IO a) → IO a
      call = withResult result
      allocation memory = fromIntegral (memoryAllocation memory)
  pure
    AllocatorOps
      { allocatorMemoryTypes = memoryTypeOffers properties
      , allocatorBufferRequirements = \request → do
          needs ←
            getDeviceBufferMemoryRequirements
              device
              DeviceBufferMemoryRequirements {createInfo = SomeStruct (bufferCreateInfo request)}
              ∷ IO (MemoryRequirements2 '[])
          pure
            MemoryRequirements
              { requirementSize = fromIntegral needs.memoryRequirements.size
              , requirementTypes = needs.memoryRequirements.memoryTypeBits
              }
      , allocatorCreateBuffer = \request kind placement → call $ \out → do
          code ←
            c_createBuffer
              state
              (fromIntegral (requestBufferSize request))
              (requestBufferUsage request)
              kind
              (case placement of InHeldMemory → 1; MayOpenMemory → 0)
              out
          events ← resultEvents out
          case creationAnswer placement code of
            Just answer → pure (events, answer)
            Nothing → do
              made ←
                BufferMemory
                  <$> resultBuffer out
                  <*> resultAllocation out
                  <*> resultDeviceMemory out
                  <*> (fromIntegral <$> resultOffset out)
                  <*> (fromIntegral <$> resultSize out)
                  <*> resultMemoryType out
              pure (events, Created made)
      , allocatorDestroyBuffer = \memory → call $ \out → do
          c_destroyBuffer state (memoryBuffer memory) (allocation memory) out
          resultEvents out
      , allocatorMap = \memory → call $ \out → do
          c_map state (allocation memory) out >>= failing
          resultMapped out
      , allocatorUnmap = \memory → c_unmap state (allocation memory)
      , allocatorFlush = \memory (offset, size) →
          c_flush state (allocation memory) (fromIntegral offset) (fromIntegral size) >>= failing
      , allocatorInvalidate = \memory (offset, size) →
          c_invalidate state (allocation memory) (fromIntegral offset) (fromIntegral size) >>= failing
      , allocatorName = \memory name → ByteString.useAsCString name (c_setName state (allocation memory))
      , allocatorDestroy = call $ \out → do
          c_destroy state out
          resultEvents out
      }
  where
    failing code = when (code /= 0) (throwIO (VulkanException (Result code)))

-- | What a creation's result means, 'Nothing' for success. In held memory
-- only, VMA answers a request nothing held fits with
-- @VK_ERROR_OUT_OF_DEVICE_MEMORY@, and one the driver requires dedicated with
-- @VK_ERROR_FEATURE_NOT_PRESENT@, since a dedicated allocation is never made
-- in held memory: both are 'NotPlaced'. Any other result, and every failure
-- of an allocating call, is the binding's 'VulkanException' for it.
creationAnswer ∷ Placement → Int32 → Maybe Creation
creationAnswer placement code
  | code == 0 = Nothing
  | placement == InHeldMemory, Result code `elem` [ERROR_OUT_OF_DEVICE_MEMORY, ERROR_FEATURE_NOT_PRESENT] = Just NotPlaced
  | otherwise = Just (CreationFailed (toException (VulkanException (Result code))))

-- | A buffer's create info for a request: exclusive to one queue family.
bufferCreateInfo ∷ BufferRequest → BufferCreateInfo '[]
bufferCreateInfo request =
  zero
    { size = fromIntegral (requestBufferSize request)
    , usage = BufferUsageFlagBits (requestBufferUsage request)
    , sharingMode = SHARING_MODE_EXCLUSIVE
    }

-- | Every memory type the device offers, with the properties the engine
-- speaks of and the preferred block size VMA computes from its heap.
memoryTypeOffers ∷ PhysicalDeviceMemoryProperties → [MemoryTypeOffer]
memoryTypeOffers properties =
  [ MemoryTypeOffer
      { offerTypeIndex = index
      , offerProperties = [property | (property, flag) ← flags, kind.propertyFlags .&. flag /= zero]
      , offerPreferredBlock = preferredBlockSize (heapSize kind.heapIndex)
      }
  | (index, kind) ← zip [0 ..] (take (fromIntegral properties.memoryTypeCount) (Vector.toList properties.memoryTypes))
  ]
  where
    flags =
      [ (DeviceLocal, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
      , (HostVisible, MEMORY_PROPERTY_HOST_VISIBLE_BIT)
      , (HostCoherent, MEMORY_PROPERTY_HOST_COHERENT_BIT)
      , (HostCached, MEMORY_PROPERTY_HOST_CACHED_BIT)
      ]
    heapSize heap = case drop (fromIntegral heap) (Vector.toList properties.memoryHeaps) of
      found : _ → fromIntegral found.size
      [] → 0
