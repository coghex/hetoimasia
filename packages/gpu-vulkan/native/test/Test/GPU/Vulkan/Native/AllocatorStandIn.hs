-- | A stand-in device-memory allocator: the shape VMA has for the engine
-- ("Hetoimasia.GPU.Vulkan.Native.Allocator"), with its blocks kept here, every
-- call and every block opened or freed recorded in order, and any step made to
-- fail.
--
-- It follows the rules the allocation protocol relies on, as VMA keeps them:
--
-- * A placement in held memory opens nothing, and answers out of memory when
--   nothing held fits.
-- * An allocating call places in a held block if one fits, and otherwise opens
--   one block of the type's block size — or, for a request larger than the
--   preferred block or one the driver requires dedicated, a dedicated
--   allocation of exactly its size. Only the memory type it was given is ever
--   used.
-- * Freeing an allocation that empties its block frees the block unless it is
--   the type's only empty block, which is kept; a dedicated allocation is
--   freed with it.
-- * Destroying the allocator frees every block still held.
--
-- Space inside a block is counted, not laid out: a request fits a block whose
-- free bytes cover its size. Handles are numbers.
module Test.GPU.Vulkan.Native.AllocatorStandIn
  ( -- * The stand-in
    AllocatorStandIn (..)
  , newAllocatorStandIn
  , allocatorStandInOps
  , AllocatorCall (..)
  , allocatorCalls
  , AllocatorStep (..)
  , failAllocatorAt
  , clearAllocatorAt
  , allocatorOutOfMemory
  , duringAllocating
  , StandInResult (..)
  , AllocatorFailure (..)

    -- * What it is configured with
  , standInMemoryTypes
  , standInBlockSize
  , hostCoherentType
  , hostCachedType
  , nonCoherentType
  , deviceLocalType
  , allowTypes
  , nonCoherentReadback
  , requireDedicated
  , openBlocksOf
  , openExtra
  , limitDeviceMemory

    -- * What it holds
  , heldBlocks
  , heldBytes
  , liveAllocations
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, SomeException, throwIO, toException)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Vulkan.Native.Allocator
import Hetoimasia.GPU.Vulkan.Native.Roots (NativeFailure (..))

-- | A native result recovery acts on, raised at a step — named, so every
-- layer's stand-in can raise it, and the roots' stand-in classifies it.
data StandInResult = StandInResult !Text !NativeFailure
  deriving (Eq, Show)

instance Exception StandInResult

-- | What a failing step raises, or answers, after recording the call.
newtype AllocatorFailure = AllocatorFailure AllocatorStep
  deriving (Eq, Show)

instance Exception AllocatorFailure

-- | One call the engine made, or one block the allocator opened or freed, in
-- the order they happened.
data AllocatorCall
  = AskedRequirements !Natural
  | Placing !Natural !Word32 !Placement
    -- ^ A creation was asked for: the size, the memory type, and where it may
    -- be placed.
  | OpenedMemory !Word64 !Word32 !Natural !Bool
    -- ^ A block or dedicated allocation opened: its handle, its type, its
    -- size, and whether it is dedicated.
  | FreedMemory !Word64 !Natural
  | MadeBuffer !Word64 !Word64 !Word64
    -- ^ The buffer, its allocation, and the device memory it lies in.
  | BindFailed !Word64
    -- ^ The buffer's bind failed: its allocation and buffer were destroyed.
  | DestroyedBuffer !Word64
  | FreedAllocation !Word64
  | Mapped !Word64
  | Unmapped !Word64
  | Flushed !Word64 !(Natural, Natural)
  | Invalidated !Word64 !(Natural, Natural)
  | NamedAllocation !Word64 !ByteString
  | DestroyedAllocator
  deriving (Eq, Show)

-- | A step the stand-in can be made to fail at.
data AllocatorStep
  = AtRequirements
  | AtCreate
    -- ^ The buffer's creation, before any placement: no effect.
  | AtBind
    -- ^ The bind after the allocation was made: VMA frees the allocation and
    -- destroys the buffer, inside the same call.
  | AtMap
  | AtFlush
  | AtInvalidate
  | AtName
  | AtDestroyBuffer
  | AtDestroyAllocator
  deriving (Eq, Ord, Show, Enum, Bounded)

data Block = Block
  { blockType ∷ !Word32
  , blockSize ∷ !Natural
  , blockUsed ∷ !Natural
  , blockAllocations ∷ !(Set Word64)
  , blockDedicated ∷ !Bool
  }

data AllocatorStandIn = AllocatorStandIn
  { allocatorJournal ∷ !(TVar [AllocatorCall])
    -- ^ Newest first.
  , allocatorFailing ∷ !(TVar (Set AllocatorStep))
  , allocatorExhausted ∷ !(TVar Int)
    -- ^ How many more allocating calls answer out of memory, having opened
    -- nothing.
  , allocatorDuring ∷ !(TVar (Maybe (IO ())))
    -- ^ What the next allocating call runs, once, before anything else.
  , allocatorHandles ∷ !(TVar Word64)
  , allocatorBlocks ∷ !(TVar (Map Word64 Block))
  , allocatorPlaced ∷ !(TVar (Map Word64 (Word64, Natural)))
    -- ^ Each live allocation: its block and its size.
  , allocatorDedicated ∷ !(TVar Bool)
  , allocatorBlockSize ∷ !(TVar (Maybe Natural))
    -- ^ The size a new block opens at, when not the preferred size.
  , allocatorExtra ∷ !(TVar Natural)
    -- ^ Bytes every block or dedicated allocation opens beyond what it
    -- should: a defect the engine must catch.
  , allocatorLimit ∷ !(TVar (Maybe Natural))
    -- ^ The device memory there is; opening more answers out of memory.
  , allocatorAllowed ∷ !(TVar Word32)
    -- ^ The memory types a buffer's requirements allow.
  }

newAllocatorStandIn ∷ IO AllocatorStandIn
newAllocatorStandIn =
  AllocatorStandIn
    <$> newTVarIO []
    <*> newTVarIO Set.empty
    <*> newTVarIO 0
    <*> newTVarIO Nothing
    <*> newTVarIO 700
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO False
    <*> newTVarIO Nothing
    <*> newTVarIO 0
    <*> newTVarIO Nothing
    <*> newTVarIO 0x7

-- | The stand-in's preferred block size: 64 KiB for every type.
standInBlockSize ∷ Natural
standInBlockSize = 64 * 1024

deviceLocalType, hostCoherentType, hostCachedType, nonCoherentType ∷ Word32
deviceLocalType = 0
hostCoherentType = 1
hostCachedType = 2
nonCoherentType = 3

-- | Four memory types: device-local; host-visible and coherent;
-- host-visible, coherent and cached; and host-visible and cached but not
-- coherent. A buffer may live in the first three unless 'allowTypes' says
-- otherwise, so a readback lands in the coherent cached type.
standInMemoryTypes ∷ [MemoryTypeOffer]
standInMemoryTypes =
  [ MemoryTypeOffer deviceLocalType [DeviceLocal] standInBlockSize
  , MemoryTypeOffer hostCoherentType [HostVisible, HostCoherent] standInBlockSize
  , MemoryTypeOffer hostCachedType [HostVisible, HostCoherent, HostCached] standInBlockSize
  , MemoryTypeOffer nonCoherentType [HostVisible, HostCached] standInBlockSize
  ]

-- | The memory types every buffer's requirements allow from now on, as a bit
-- mask.
allowTypes ∷ AllocatorStandIn → Word32 → IO ()
allowTypes standIn mask = atomically (writeTVar (allocatorAllowed standIn) mask)

-- | Have buffers allowed only device-local and non-coherent cached memory, so
-- a readback lands in non-coherent memory.
nonCoherentReadback ∷ AllocatorStandIn → IO ()
nonCoherentReadback standIn = allowTypes standIn (bit deviceLocalType + bit nonCoherentType)
  where
    bit index = 2 ^ index

-- | Every call so far, oldest first.
allocatorCalls ∷ AllocatorStandIn → IO [AllocatorCall]
allocatorCalls standIn = reverse <$> readTVarIO (allocatorJournal standIn)

failAllocatorAt ∷ AllocatorStandIn → AllocatorStep → IO ()
failAllocatorAt standIn at = atomically (modifyTVar' (allocatorFailing standIn) (Set.insert at))

clearAllocatorAt ∷ AllocatorStandIn → AllocatorStep → IO ()
clearAllocatorAt standIn at = atomically (modifyTVar' (allocatorFailing standIn) (Set.delete at))

-- | Have the next this many allocating calls answer out of memory having
-- opened nothing: a no-effect failure.
allocatorOutOfMemory ∷ AllocatorStandIn → Int → IO ()
allocatorOutOfMemory standIn times = atomically (writeTVar (allocatorExhausted standIn) times)

-- | Run this, once, at the start of the next allocating call. What it raises,
-- the call raises, having made nothing.
duringAllocating ∷ AllocatorStandIn → IO () → IO ()
duringAllocating standIn action = atomically (writeTVar (allocatorDuring standIn) (Just action))

-- | Have the driver require a dedicated allocation for every buffer.
requireDedicated ∷ AllocatorStandIn → IO ()
requireDedicated standIn = atomically (writeTVar (allocatorDedicated standIn) True)

-- | Open new blocks at this size rather than the preferred one, as VMA does
-- while a type's blocks are still growing.
openBlocksOf ∷ AllocatorStandIn → Natural → IO ()
openBlocksOf standIn size = atomically (writeTVar (allocatorBlockSize standIn) (Just size))

-- | Open this many bytes more than the allocator should, in every block and
-- dedicated allocation from now on.
openExtra ∷ AllocatorStandIn → Natural → IO ()
openExtra standIn bytes = atomically (writeTVar (allocatorExtra standIn) bytes)

-- | Have the device hold at most this much memory.
limitDeviceMemory ∷ AllocatorStandIn → Natural → IO ()
limitDeviceMemory standIn bytes = atomically (writeTVar (allocatorLimit standIn) (Just bytes))

-- | Every block and dedicated allocation held: its handle, type, size, and
-- how many allocations it holds.
heldBlocks ∷ AllocatorStandIn → IO [(Word64, Word32, Natural, Int)]
heldBlocks standIn =
  map (\(handle, block) → (handle, blockType block, blockSize block, Set.size (blockAllocations block))) . Map.toAscList
    <$> readTVarIO (allocatorBlocks standIn)

-- | The device memory held, in bytes.
heldBytes ∷ AllocatorStandIn → IO Natural
heldBytes standIn = sum . map blockSize . Map.elems <$> readTVarIO (allocatorBlocks standIn)

-- | How many allocations are live.
liveAllocations ∷ AllocatorStandIn → IO Int
liveAllocations standIn = Map.size <$> readTVarIO (allocatorPlaced standIn)

journal ∷ AllocatorStandIn → AllocatorCall → STM ()
journal standIn call = modifyTVar' (allocatorJournal standIn) (call :)

failing ∷ AllocatorStandIn → AllocatorStep → IO Bool
failing standIn at = Set.member at <$> readTVarIO (allocatorFailing standIn)

fresh ∷ AllocatorStandIn → STM Word64
fresh standIn = do
  next ← readTVar (allocatorHandles standIn)
  writeTVar (allocatorHandles standIn) (next + 1)
  pure next

outOfMemory ∷ Text → SomeException
outOfMemory during = toException (StandInResult during FailedOutOfMemory)

-- | The stand-in's allocator: requirements are the request's size, in any of
-- the three types.
allocatorStandInOps ∷ AllocatorStandIn → AllocatorOps
allocatorStandInOps standIn =
  AllocatorOps
    { allocatorMemoryTypes = standInMemoryTypes
    , allocatorBufferRequirements = \request → do
        atomically (journal standIn (AskedRequirements (requestBufferSize request)))
        refused ← failing standIn AtRequirements
        when refused (throwIO (AllocatorFailure AtRequirements))
        MemoryRequirements (requestBufferSize request) <$> readTVarIO (allocatorAllowed standIn)
    , allocatorCreateBuffer = \request kind placement → create (requestBufferSize request) kind placement
    , allocatorDestroyBuffer = \memory → do
        refused ← failing standIn AtDestroyBuffer
        when refused $ do
          atomically (journal standIn (DestroyedBuffer (memoryBuffer memory)))
          throwIO (AllocatorFailure AtDestroyBuffer)
        atomically $ do
          journal standIn (DestroyedBuffer (memoryBuffer memory))
          journal standIn (FreedAllocation (memoryAllocation memory))
          release (memoryAllocation memory)
    , allocatorMap = \memory → do
        atomically (journal standIn (Mapped (memoryAllocation memory)))
        refused ← failing standIn AtMap
        when refused (throwIO (AllocatorFailure AtMap))
        pure (memoryAllocation memory)
    , allocatorUnmap = \memory → atomically (journal standIn (Unmapped (memoryAllocation memory)))
    , allocatorFlush = \memory range → do
        atomically (journal standIn (Flushed (memoryAllocation memory) range))
        refused ← failing standIn AtFlush
        when refused (throwIO (AllocatorFailure AtFlush))
    , allocatorInvalidate = \memory range → do
        atomically (journal standIn (Invalidated (memoryAllocation memory) range))
        refused ← failing standIn AtInvalidate
        when refused (throwIO (AllocatorFailure AtInvalidate))
    , allocatorName = \memory name → do
        atomically (journal standIn (NamedAllocation (memoryAllocation memory) name))
        refused ← failing standIn AtName
        when refused (throwIO (AllocatorFailure AtName))
    , allocatorDestroy = do
        atomically (journal standIn DestroyedAllocator)
        refused ← failing standIn AtDestroyAllocator
        when refused (throwIO (AllocatorFailure AtDestroyAllocator))
        atomically $ do
          blocks ← readTVar (allocatorBlocks standIn)
          writeTVar (allocatorBlocks standIn) Map.empty
          writeTVar (allocatorPlaced standIn) Map.empty
          mapM_ (\(handle, block) → journal standIn (FreedMemory handle (blockSize block))) (Map.toAscList blocks)
          pure (MemoryEvents 0 0 (fromIntegral (Map.size blocks)) (sum (map blockSize (Map.elems blocks))))
    }
  where
    create size kind placement = do
      atomically (journal standIn (Placing size kind placement))
      during ←
        if placement == MayOpenMemory
          then atomically $ do
            held ← readTVar (allocatorDuring standIn)
            writeTVar (allocatorDuring standIn) Nothing
            pure held
          else pure Nothing
      sequence_ during
      refused ← failing standIn AtCreate
      if refused
        then pure (noMemoryEvents, Left (toException (AllocatorFailure AtCreate)))
        else do
          bindFails ← failing standIn AtBind
          atomically $ do
            exhausted ← readTVar (allocatorExhausted standIn)
            if placement == MayOpenMemory && exhausted > 0
              then do
                writeTVar (allocatorExhausted standIn) (exhausted - 1)
                pure (noMemoryEvents, Left (outOfMemory "vmaCreateBuffer"))
              else place size kind placement bindFails

    -- Place in a held block that fits, or open memory if the placement allows.
    place size kind placement bindFails = do
      dedicated ← readTVar (allocatorDedicated standIn)
      blocks ← readTVar (allocatorBlocks standIn)
      let fits (_, block) = blockType block == kind && not (blockDedicated block) && blockSize block - blockUsed block >= size
          preferred = maybe standInBlockSize offerPreferredBlock (find ((== kind) . offerTypeIndex) standInMemoryTypes)
          candidate = if dedicated then Nothing else find fits (sortOn fst (Map.toList blocks))
      case candidate of
        Just (handle, _) → allocate handle size (MemoryEvents 0 0 0 0) bindFails
        Nothing
          | placement == InHeldMemory → pure (noMemoryEvents, Left (outOfMemory "vmaCreateBuffer"))
          | otherwise → do
              extra ← readTVar (allocatorExtra standIn)
              growing ← readTVar (allocatorBlockSize standIn)
              limit ← readTVar (allocatorLimit standIn)
              let alone = dedicated || size > preferred
                  opening = (if alone then size else maybe preferred (max size) growing) + extra
                  held = sum (map blockSize (Map.elems blocks))
              case limit of
                Just most | held + opening > most → pure (noMemoryEvents, Left (outOfMemory "vmaCreateBuffer"))
                _ → do
                  handle ← fresh standIn
                  modifyTVar' (allocatorBlocks standIn) (Map.insert handle (Block kind opening 0 Set.empty alone))
                  journal standIn (OpenedMemory handle kind opening alone)
                  allocate handle size (MemoryEvents 1 opening 0 0) bindFails

    allocate block size opened bindFails = do
      allocation ← fresh standIn
      buffer ← fresh standIn
      offset ← maybe 0 blockUsed . Map.lookup block <$> readTVar (allocatorBlocks standIn)
      modifyTVar' (allocatorBlocks standIn) (Map.adjust (\held → held {blockUsed = blockUsed held + size, blockAllocations = Set.insert allocation (blockAllocations held)}) block)
      modifyTVar' (allocatorPlaced standIn) (Map.insert allocation (block, size))
      if bindFails
        then do
          journal standIn (BindFailed allocation)
          freed ← release allocation
          pure (sumEvents opened freed, Left (toException (AllocatorFailure AtBind)))
        else do
          journal standIn (MadeBuffer buffer allocation block)
          kind ← maybe 0 blockType . Map.lookup block <$> readTVar (allocatorBlocks standIn)
          pure (opened, Right (BufferMemory buffer allocation block offset size kind))

    -- Free an allocation, and its block if that leaves it empty and it is
    -- dedicated or not the type's only empty block.
    release allocation = do
      placed ← Map.lookup allocation <$> readTVar (allocatorPlaced standIn)
      case placed of
        Nothing → pure noMemoryEvents
        Just (handle, size) → do
          modifyTVar' (allocatorPlaced standIn) (Map.delete allocation)
          modifyTVar' (allocatorBlocks standIn) (Map.adjust (\held → held {blockUsed = blockUsed held - min size (blockUsed held), blockAllocations = Set.delete allocation (blockAllocations held)}) handle)
          blocks ← readTVar (allocatorBlocks standIn)
          case Map.lookup handle blocks of
            Just block | Set.null (blockAllocations block) → do
              let otherEmpty = any (\(other, candidate) → other /= handle && blockType candidate == blockType block && not (blockDedicated candidate) && Set.null (blockAllocations candidate)) (Map.toList blocks)
              if blockDedicated block || otherEmpty
                then do
                  modifyTVar' (allocatorBlocks standIn) (Map.delete handle)
                  journal standIn (FreedMemory handle (blockSize block))
                  pure (MemoryEvents 0 0 1 (blockSize block))
                else pure noMemoryEvents
            _ → pure noMemoryEvents

    sumEvents (MemoryEvents a b c d) (MemoryEvents e f g h) = MemoryEvents (a + e) (b + f) (c + g) (d + h)
