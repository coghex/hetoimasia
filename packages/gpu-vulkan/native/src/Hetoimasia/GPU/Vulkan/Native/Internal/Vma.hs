-- | The engine's VMA shim, imported (GRS-11, #333): the only module that names
-- a VMA object or calls one.
--
-- Every entry is the C shim's (@cbits/hetoimasia_vma.cpp@), imported
-- @unsafe@, taking only scalars and the one result record its allocator
-- reuses for every call — the shape #361 (GRS-18) qualified. The device-memory
-- callbacks count in C, so no call made here can enter Haskell, which is what
-- makes @unsafe@ sound: an unsafe call holds its capability, and a callback
-- into Haskell under one would deadlock or corrupt the runtime.
--
-- It is private to the package. A VMA allocator is a 'VmaState' here and
-- nowhere else; every public module sees only the engine's
-- 'Hetoimasia.GPU.Vulkan.Native.Allocator.AllocatorOps' built over it.
module Hetoimasia.GPU.Vulkan.Native.Internal.Vma
  ( VmaState
  , VmaResult
  , resultBytes
  , withResult
  , c_create
  , c_destroy
  , c_createBuffer
  , c_destroyBuffer
  , c_createImage
  , c_destroyImage
  , c_map
  , c_unmap
  , c_flush
  , c_invalidate
  , c_setName
  , c_resultSize
  , resultResource
  , resultAllocation
  , resultDeviceMemory
  , resultOffset
  , resultSize
  , resultMapped
  , resultMemoryType
  , resultEvents
  ) where

import Data.Int (Int32)
import Data.Word (Word32, Word64)
import Foreign.C.String (CString)
import Foreign.ForeignPtr (ForeignPtr, withForeignPtr)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekByteOff)

import Hetoimasia.GPU.Vulkan.Native.Allocator (MemoryEvents (..))

-- | One allocator and the events its callbacks count into: the shim's
-- @hetoimasia_vma_allocator@, which it allocates and frees.
data VmaState

-- | The shim's @hetoimasia_vma_result@, which every call writes.
data VmaResult

-- | The size of a result record, as this module reads it. 'c_resultSize'
-- answers the shim's own, and the allocator refuses to start if they differ.
resultBytes ∷ Int
resultBytes = 88

withResult ∷ ForeignPtr VmaResult → (Ptr VmaResult → IO a) → IO a
withResult = withForeignPtr

foreign import ccall unsafe "hetoimasia_vma_result_size"
  c_resultSize ∷ IO Word64

foreign import ccall unsafe "hetoimasia_vma_create"
  c_create ∷ Ptr () → Ptr () → Ptr () → Ptr () → Ptr () → Word32 → Word64 → Ptr (Ptr VmaState) → IO Int32

foreign import ccall unsafe "hetoimasia_vma_destroy"
  c_destroy ∷ Ptr VmaState → Ptr VmaResult → IO ()

foreign import ccall unsafe "hetoimasia_vma_create_buffer"
  c_createBuffer ∷ Ptr VmaState → Word64 → Word32 → Word32 → Word32 → Ptr VmaResult → IO Int32

foreign import ccall unsafe "hetoimasia_vma_destroy_buffer"
  c_destroyBuffer ∷ Ptr VmaState → Word64 → Word64 → Ptr VmaResult → IO ()

foreign import ccall unsafe "hetoimasia_vma_create_image"
  c_createImage ∷ Ptr VmaState → Word32 → Word32 → Word32 → Word32 → Word32 → Word32 → Word32 → Ptr VmaResult → IO Int32

foreign import ccall unsafe "hetoimasia_vma_destroy_image"
  c_destroyImage ∷ Ptr VmaState → Word64 → Word64 → Ptr VmaResult → IO ()

foreign import ccall unsafe "hetoimasia_vma_map"
  c_map ∷ Ptr VmaState → Word64 → Ptr VmaResult → IO Int32

foreign import ccall unsafe "hetoimasia_vma_unmap"
  c_unmap ∷ Ptr VmaState → Word64 → IO ()

foreign import ccall unsafe "hetoimasia_vma_flush"
  c_flush ∷ Ptr VmaState → Word64 → Word64 → Word64 → IO Int32

foreign import ccall unsafe "hetoimasia_vma_invalidate"
  c_invalidate ∷ Ptr VmaState → Word64 → Word64 → Word64 → IO Int32

foreign import ccall unsafe "hetoimasia_vma_set_name"
  c_setName ∷ Ptr VmaState → Word64 → CString → IO ()

-- | The buffer or image a creation made.
resultResource, resultAllocation, resultDeviceMemory, resultOffset, resultSize, resultMapped ∷ Ptr VmaResult → IO Word64
resultResource pointer = peekByteOff pointer 0
resultAllocation pointer = peekByteOff pointer 8
resultDeviceMemory pointer = peekByteOff pointer 16
resultOffset pointer = peekByteOff pointer 24
resultSize pointer = peekByteOff pointer 32
resultMapped pointer = peekByteOff pointer 40

resultMemoryType ∷ Ptr VmaResult → IO Word32
resultMemoryType pointer = peekByteOff pointer 48

-- | The events the call that wrote the record counted.
resultEvents ∷ Ptr VmaResult → IO MemoryEvents
resultEvents pointer =
  MemoryEvents
    <$> (fromIntegral <$> (peekByteOff pointer 56 ∷ IO Word64))
    <*> (fromIntegral <$> (peekByteOff pointer 64 ∷ IO Word64))
    <*> (fromIntegral <$> (peekByteOff pointer 72 ∷ IO Word64))
    <*> (fromIntegral <$> (peekByteOff pointer 80 ∷ IO Word64))
