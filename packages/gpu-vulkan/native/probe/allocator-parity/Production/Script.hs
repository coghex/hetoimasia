-- | What GRS-18's drivers replay: scripts of resource operations over a small
-- table of resource classes, each a deterministic Vulkan descriptor and
-- allocation policy. Both drivers receive the same script, encoded once.
--
-- The retained traces carry only identities, sizes, alignments, frees and
-- checkpoints. 'traceScript' is the deterministic translation of each into
-- real resources under D-16's usages (README.md, "GRS-18's trace-to-resource
-- mapping"); 'callScript' is the fixed sequence the per-call figures time.
module Production.Script
  ( ClassSpec (..)
  , ResourceClass (..)
  , ResourceOp (..)
  , Script (..)
  , OpCode (..)
  , opCode
  , opCodeWord
  , sheetSpec
  , geometrySpec
  , stagingSpec
  , readbackSpec
  , classSpecs
  , traceScript
  , callScript
  , encodeScript
  , mappingLines
  , sheetExtent
  ) where

import Data.Bits (countTrailingZeros, popCount, (.|.))
import qualified Data.Vector as Vector
import qualified Data.Vector.Storable as Storable
import qualified Data.Vector.Unboxed as Unboxed
import Data.Word (Word32, Word64, Word8)
import Foreign.Marshal.Utils (fillBytes)
import Foreign.Ptr (plusPtr)
import Foreign.Storable (pokeByteOff)
import qualified Data.Vector.Storable.Mutable as StorableMutable
import Parity.Trace (Trace (..))

-- | A resource class before a device has chosen its memory type.
data ClassSpec = ClassSpec
  { specName ∷ !String
  , specPurpose ∷ !String
  , specIsImage ∷ !Bool
  , specUsage ∷ !Word32
    -- ^ @VkBufferUsageFlags@ or @VkImageUsageFlags@.
  , specFormat ∷ !Word32
    -- ^ The image's @VkFormat@; zero for a buffer.
  , specRequired ∷ !Word32
  , specPreferred ∷ !Word32
  , specAvoided ∷ !Word32
  , specAllocationFlags ∷ !Word32
    -- ^ The @VmaAllocationCreateFlags@ every request of the class carries.
  }
  deriving (Eq, Show)

-- | A class with the memory type the engine chose for it on this device.
data ResourceClass = ResourceClass
  { classSpec ∷ !ClassSpec
  , classMemoryType ∷ !Word32
  , classTypeBits ∷ !Word32
    -- ^ The @memoryTypeBits@ a probe resource of the class reported.
  , classPreferredBlockSize ∷ !Word64
    -- ^ VMA's preferred block size for that type: D-40's bound.
  }
  deriving (Eq, Show)

-- | One operation of a script.
data ResourceOp = ResourceOp
  { opKind ∷ !Word32
  , opId ∷ !Word32
  , opClass ∷ !Word32
  , opWidth ∷ !Word32
  , opHeight ∷ !Word32
  , opSize ∷ !Word64
  }
  deriving (Eq, Show)

-- | The operations, as the C driver's @hetoimasia_resource_op@ codes them.
data OpCode = CreateD40 | Destroy | Checkpoint | CreatePlain | Map | Unmap | Flush | Invalidate
  deriving (Eq, Ord, Show, Enum, Bounded)

opCodeWord ∷ OpCode → Word32
opCodeWord code = case code of
  CreateD40 → 0
  Destroy → 1
  Checkpoint → 2
  CreatePlain → 3
  Map → 4
  Unmap → 5
  Flush → 6
  Invalidate → 7

opCode ∷ Word32 → OpCode
opCode word = case word of
  0 → CreateD40
  1 → Destroy
  2 → Checkpoint
  3 → CreatePlain
  4 → Map
  5 → Unmap
  6 → Flush
  _ → Invalidate
{-# INLINE opCode #-}

-- | A script ready for both drivers.
data Script = Script
  { scriptName ∷ !String
  , scriptClasses ∷ !(Vector.Vector ResourceClass)
  , scriptKinds ∷ !(Unboxed.Vector Word32)
  , scriptIds ∷ !(Unboxed.Vector Word32)
  , scriptClassIndices ∷ !(Unboxed.Vector Word32)
  , scriptWidths ∷ !(Unboxed.Vector Word32)
  , scriptHeights ∷ !(Unboxed.Vector Word32)
  , scriptSizes ∷ !(Unboxed.Vector Word64)
  , scriptIdentities ∷ !Int
  , scriptCheckpoints ∷ ![String]
  , scriptEncodedOps ∷ !(Storable.Vector Word8)
    -- ^ 32 bytes per operation, as @hetoimasia_resource_op@.
  , scriptEncodedClasses ∷ !(Storable.Vector Word8)
    -- ^ 32 bytes per class, as @hetoimasia_resource_class@.
  , scriptPreferredBlockSizes ∷ !(Storable.Vector Word64)
    -- ^ By memory type.
  }

-- Flags, by the Vulkan headers' values.
bufferTransferSrc, bufferTransferDst, bufferIndex, bufferVertex ∷ Word32
bufferTransferSrc = 0x1
bufferTransferDst = 0x2
bufferIndex = 0x40
bufferVertex = 0x80

imageTransferDst, imageSampled ∷ Word32
imageTransferDst = 0x2
imageSampled = 0x4

deviceLocal, hostVisible, hostCoherent, hostCached ∷ Word32
deviceLocal = 0x1
hostVisible = 0x2
hostCoherent = 0x4
hostCached = 0x8

formatRgba8Unorm ∷ Word32
formatRgba8Unorm = 37

-- | @VMA_ALLOCATION_CREATE_MAPPED_BIT@: persistent mapping, which D-38
-- leaves to VMA for host-visible allocations.
vmaMapped ∷ Word32
vmaMapped = 0x4

-- | D-16's texture: an atlas sheet, staged into device-local memory.
sheetSpec ∷ ClassSpec
sheetSpec =
  ClassSpec
    { specName = "sheet"
    , specPurpose = "D-16 texture: an RGBA8 atlas sheet, optimally tiled, staged into device-local memory"
    , specIsImage = True
    , specUsage = imageTransferDst .|. imageSampled
    , specFormat = formatRgba8Unorm
    , specRequired = deviceLocal
    , specPreferred = 0
    , specAvoided = hostVisible
    , specAllocationFlags = 0
    }

-- | D-16's static geometry, staged into device-local memory.
geometrySpec ∷ ClassSpec
geometrySpec =
  ClassSpec
    { specName = "geometry"
    , specPurpose = "D-16 static geometry: a vertex and index buffer staged into device-local memory"
    , specIsImage = False
    , specUsage = bufferVertex .|. bufferIndex .|. bufferTransferDst
    , specFormat = 0
    , specRequired = deviceLocal
    , specPreferred = 0
    , specAvoided = hostVisible
    , specAllocationFlags = 0
    }

-- | D-16's staging: host-visible, persistently mapped, a transfer source.
stagingSpec ∷ ClassSpec
stagingSpec =
  ClassSpec
    { specName = "staging"
    , specPurpose = "D-16 staging: a host-visible, persistently mapped transfer source"
    , specIsImage = False
    , specUsage = bufferTransferSrc
    , specFormat = 0
    , specRequired = hostVisible
    , specPreferred = hostCoherent
    , specAvoided = 0
    , specAllocationFlags = vmaMapped
    }

-- | D-16's readback: host-visible, persistently mapped, a transfer
-- destination, preferably cached.
readbackSpec ∷ ClassSpec
readbackSpec =
  ClassSpec
    { specName = "readback"
    , specPurpose = "D-16 readback: a host-visible, persistently mapped transfer destination, cached where offered"
    , specIsImage = False
    , specUsage = bufferTransferDst
    , specFormat = 0
    , specRequired = hostVisible
    , specPreferred = hostCached .|. hostCoherent
    , specAvoided = 0
    , specAllocationFlags = vmaMapped
    }

-- | Every class, in the order of the class table both drivers receive.
classSpecs ∷ [ClassSpec]
classSpecs = [sheetSpec, geometrySpec, stagingSpec, readbackSpec]

classIndex ∷ ClassSpec → Word32
classIndex spec = case lookup (specName spec) (zip (map specName classSpecs) [0 ..]) of
  Just i → i
  Nothing → error ("no class " <> specName spec)

-- | A sheet's extent from its RGBA8 bytes: @4 × 2^k@ bytes are a
-- @2^⌈k/2⌉ × 2^⌊k/2⌋@ image. Nothing for any other size.
sheetExtent ∷ Word64 → Maybe (Word32, Word32)
sheetExtent bytes
  | bytes < 4 || bytes `mod` 4 /= 0 = Nothing
  | popCount pixels /= 1 = Nothing
  | otherwise =
      let k = countTrailingZeros pixels
       in Just (2 ^ ((k + 1) `div` 2), 2 ^ (k `div` 2))
  where
    pixels = bytes `div` 4

-- | The deterministic translation of a retained trace into resources:
--
-- * @synarchy-sheets@: every allocation is a sheet image of 'sheetExtent'.
-- * the small-buffer traces: every allocation is a buffer of the trace's size,
--   whose class follows its alignment — 16 bytes static geometry, 64 bytes
--   staging, 256 bytes readback.
--
-- Every allocation follows D-40: @NEVER_ALLOCATE@ first, then the allocating
-- call. A free destroys the resource; a checkpoint records the byte
-- quantities. The trace's capacity, its alignments beyond choosing a class,
-- and the virtual block's refusals have no counterpart on a real allocator.
traceScript ∷ Trace → Either String [ResourceOp]
traceScript trace = mapM translate (zip [0 ..] (Unboxed.toList (traceKinds trace)))
  where
    sheets = traceName trace == "synarchy-sheets"
    translate (i ∷ Int, kind) =
      let identity = traceIds trace Unboxed.! i
          size = traceSizes trace Unboxed.! i
          alignment = traceAlignments trace Unboxed.! i
       in case kind of
            0
              | sheets → case sheetExtent size of
                  Just (w, h) → Right (ResourceOp (opCodeWord CreateD40) identity (classIndex sheetSpec) w h size)
                  Nothing → Left (traceName trace <> ": allocation " <> show identity <> " of " <> show size <> " bytes is no RGBA8 power-of-two sheet")
              | otherwise → case alignment of
                  16 → Right (ResourceOp (opCodeWord CreateD40) identity (classIndex geometrySpec) 0 0 size)
                  64 → Right (ResourceOp (opCodeWord CreateD40) identity (classIndex stagingSpec) 0 0 size)
                  256 → Right (ResourceOp (opCodeWord CreateD40) identity (classIndex readbackSpec) 0 0 size)
                  _ → Left (traceName trace <> ": allocation " <> show identity <> " has alignment " <> show alignment <> ", which no class maps")
            1 → Right (ResourceOp (opCodeWord Destroy) identity 0 0 0 0)
            _ → Right (ResourceOp (opCodeWord Checkpoint) identity 0 0 0 0)

-- | The fixed sequence the per-call figures time, each phase on resources of
-- one class (README.md, "GRS-18's per-call script"):
--
-- 1. 512 staging buffers of 64 KiB, one allocating call each; then each is
--    mapped, flushed, invalidated and unmapped; then all are freed.
-- 2. 512 sheet images of 256 × 256, one allocating call each; then freed.
-- 3. 512 geometry buffers of 64 KiB through D-40, which held memory places;
--    then freed.
-- 4. 64 geometry buffers of 64 MiB through D-40, which keep filling the
--    blocks VMA holds, so each block's first placement fails and opens one;
--    then freed.
-- 5. 16 geometry buffers of 160 MiB through D-40, each freed at once: larger
--    than half a preferred block, so VMA gives each a dedicated allocation.
callScript ∷ [ResourceOp]
callScript = concat [staging, sheets, reuse, blocks, dedicated]
  where
    op code identity spec w h size = ResourceOp (opCodeWord code) identity (classIndex spec) w h size
    kib = 1024
    mib = 1024 * kib
    staging =
      let ids = [0 .. 511]
       in [op CreatePlain i stagingSpec 0 0 (64 * kib) | i ← ids]
            <> concat [[op Map i stagingSpec 0 0 0, op Flush i stagingSpec 0 0 0, op Invalidate i stagingSpec 0 0 0, op Unmap i stagingSpec 0 0 0] | i ← ids]
            <> [op Destroy i stagingSpec 0 0 0 | i ← ids]
    sheets =
      let ids = [512 .. 1023]
       in [op CreatePlain i sheetSpec 256 256 (256 * 256 * 4) | i ← ids] <> [op Destroy i sheetSpec 0 0 0 | i ← ids]
    reuse =
      let ids = [1024 .. 1535]
       in [op CreateD40 i geometrySpec 0 0 (64 * kib) | i ← ids] <> [op Destroy i geometrySpec 0 0 0 | i ← ids]
    blocks =
      let ids = [1536 .. 1599]
       in [op CreateD40 i geometrySpec 0 0 (64 * mib) | i ← ids] <> [op Destroy i geometrySpec 0 0 0 | i ← ids]
    dedicated = concat [[op CreateD40 i geometrySpec 0 0 (160 * mib), op Destroy i geometrySpec 0 0 0] | i ← [1600 .. 1615]]

-- | The mapping, stated for the report.
mappingLines ∷ [String]
mappingLines =
  [ "- `synarchy-sheets`: every allocation `a ID SIZE ALIGNMENT` is a **sheet**: a 2D `VK_FORMAT_R8G8B8A8_UNORM` image, optimal tiling, one mip level and layer, usage `TRANSFER_DST | SAMPLED`, initial layout `UNDEFINED`, of extent `2^⌈k/2⌉ × 2^⌊k/2⌋` for `SIZE = 4 × 2^k` bytes (16 MiB is 2048 × 2048). A size of any other form is refused before anything runs."
  , "- `small-steady`, `small-bursty`, `small-mixed`: every allocation is a buffer of exactly `SIZE` bytes, exclusive sharing, whose class follows `ALIGNMENT`: 16 is **geometry** (`VERTEX_BUFFER | INDEX_BUFFER | TRANSFER_DST`, device-local), 64 is **staging** (`TRANSFER_SRC`, host-visible, persistently mapped), 256 is **readback** (`TRANSFER_DST`, host-visible, persistently mapped, cached where offered). Any other alignment is refused."
  , "- Every allocation is made by D-40's protocol: `VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT` first, and only if that fails the allocating call, both with `memoryTypeBits` pinned to the one type the engine chose and `VMA_MEMORY_USAGE_UNKNOWN`."
  , "- `f ID` destroys the resource and its allocation (`vmaDestroyBuffer`, `vmaDestroyImage`). `c LABEL` records the byte quantities and does nothing else."
  , "- **Fields with no counterpart.** The trace's `capacity` is not applied: a real allocator has no single block; VMA opens blocks of its preferred size, recorded below. `ALIGNMENT` only chooses a class: size and alignment come from the device's memory requirements, recorded per class. The virtual-block replay refused some requests (#331's refused bytes); here every request is made, and a request the device refuses makes the run invalid."
  , "- **Identical work.** Both drivers receive the same encoded script and class table, start from a fresh allocator, and must place every allocation in the same memory type, at the same offset, with the same size, in the same order, with the same D-40 outcomes and block events; a self-check compares them."
  ]

-- | Encode a script for the C driver and attach the class table.
encodeScript ∷ String → Vector.Vector ResourceClass → Storable.Vector Word64 → [ResourceOp] → [String] → IO Script
encodeScript name classes preferred ops labels = do
  let count = length ops
  buffer ← StorableMutable.replicate (max 1 count * 32) 0
  StorableMutable.unsafeWith buffer $ \pointer → do
    fillBytes pointer 0 (max 1 count * 32)
    mapM_
      ( \(i, o) → do
          let at = pointer `plusPtr` (i * 32)
          pokeByteOff at 0 (opKind o)
          pokeByteOff at 4 (opId o)
          pokeByteOff at 8 (opClass o)
          pokeByteOff at 12 (opWidth o)
          pokeByteOff at 16 (opHeight o)
          pokeByteOff at 24 (opSize o)
      )
      (zip [0 ..] ops)
  encodedOps ← Storable.freeze buffer
  classBuffer ← StorableMutable.replicate (max 1 (Vector.length classes) * 32) 0
  StorableMutable.unsafeWith classBuffer $ \pointer →
    mapM_
      ( \(i, c) → do
          let at = pointer `plusPtr` (i * 32)
              spec = classSpec c
          pokeByteOff at 0 (if specIsImage spec then 1 else 0 ∷ Word32)
          pokeByteOff at 4 (specUsage spec)
          pokeByteOff at 8 (specFormat spec)
          pokeByteOff at 12 (classMemoryType c)
          pokeByteOff at 16 (specAllocationFlags spec)
          pokeByteOff at 20 (specRequired spec)
          pokeByteOff at 24 (specPreferred spec)
      )
      (zip [0 ..] (Vector.toList classes))
  encodedClasses ← Storable.freeze classBuffer
  let column ∷ Unboxed.Unbox a ⇒ (ResourceOp → a) → Unboxed.Vector a
      column f = Unboxed.fromList (map f ops)
  pure
    Script
      { scriptName = name
      , scriptClasses = classes
      , scriptKinds = column opKind
      , scriptIds = column opId
      , scriptClassIndices = column opClass
      , scriptWidths = column opWidth
      , scriptHeights = column opHeight
      , scriptSizes = column opSize
      , scriptIdentities = maximum (0 : [1 + fromIntegral (opId o) | o ← ops, opCode (opKind o) /= Checkpoint])
      , scriptCheckpoints = labels
      , scriptEncodedOps = encodedOps
      , scriptEncodedClasses = encodedClasses
      , scriptPreferredBlockSizes = preferred
      }
