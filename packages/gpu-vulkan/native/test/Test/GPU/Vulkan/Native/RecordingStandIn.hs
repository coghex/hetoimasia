-- | A stand-in native layer for the recording: every call recorded in order,
-- any step made to fail, and a hook run inside a storage's reset or a
-- command's recording so an example can observe the model at that instant.
--
-- Handles are small numbers, so a record says which object each call touched.
-- A readback buffer's memory is a byte string the stand-in keeps, mapped at
-- the buffer's own number, whose size is the buffer's rounded up to 256 bytes
-- and whose coherence and atom the example chooses.
module Test.GPU.Vulkan.Native.RecordingStandIn
  ( RecordingStandIn (..)
  , newRecordingStandIn
  , recordingStandInOps
  , RecordingCall (..)
  , recordingCalls
  , RecordingStep (..)
  , failAt
  , succeedAt
  , duringReset
  , duringRecord
  , RecordingFailure (..)
  , standInMemorySize
  , standInAtom
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, throwIO)
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Vulkan.Native.Recording

-- | One native call the recording made, in the order it made it.
data RecordingCall
  = CreatedLayout !Word64
  | DestroyedLayout !Word64
  | CreatedPipeline !Word64 !Word64 !Word32
    -- ^ The pipeline, the layout it was built over, and its color format.
  | DestroyedPipeline !Word64
  | CreatedStorage !Word64 !Word64
    -- ^ The pool and its command buffer.
  | ResetStorage !Word64
  | DestroyedStorage !Word64
  | CreatedReadback !Word64 !Natural !Bool
    -- ^ The buffer, its size, and whether its memory is coherent.
  | DestroyedReadback !Word64
  | Invalidated !(Natural, Natural)
  | Flushed !(Natural, Natural)
  | ReadMapped !Natural !Natural
  | WroteMapped !Natural !Natural
  | Began !Word64
  | Ended !Word64
  | Recorded !Word64 !NativeCommand
  deriving (Eq, Show)

-- | A step the stand-in can be made to fail at.
data RecordingStep
  = AtCreateLayout
  | AtCreatePipeline
  | AtCreateStorage
  | AtResetStorage
  | AtDestroyLayout
  | AtDestroyPipeline
  | AtDestroyStorage
  | AtCreateReadback
  | AtBegin
  | AtEnd
  | AtRecord
    -- ^ Every recorded command but a label's.
  | AtBeginLabel
  | AtEndLabel
  | AtFlush
  deriving (Eq, Ord, Show)

-- | What a failing step raises, after recording the call.
newtype RecordingFailure = RecordingFailure RecordingStep
  deriving (Eq, Show)

instance Exception RecordingFailure

data RecordingStandIn = RecordingStandIn
  { recordingJournal ∷ !(TVar [RecordingCall])
    -- ^ Newest first.
  , recordingFailing ∷ !(TVar (Set RecordingStep))
  , recordingHandles ∷ !(TVar Word64)
  , recordingMemory ∷ !(TVar (Map Word64 ByteString))
  , recordingCoherent ∷ !(TVar Bool)
    -- ^ Whether the next readback's memory is coherent.
  , recordingDuringReset ∷ !(TVar (IO ()))
  , recordingDuringRecord ∷ !(TVar (NativeCommand → IO ()))
  }

newRecordingStandIn ∷ IO RecordingStandIn
newRecordingStandIn =
  RecordingStandIn
    <$> newTVarIO []
    <*> newTVarIO Set.empty
    <*> newTVarIO 500
    <*> newTVarIO Map.empty
    <*> newTVarIO True
    <*> newTVarIO (pure ())
    <*> newTVarIO (\_ → pure ())

-- | Every call so far, oldest first.
recordingCalls ∷ RecordingStandIn → IO [RecordingCall]
recordingCalls standIn = reverse <$> readTVarIO (recordingJournal standIn)

failAt ∷ RecordingStandIn → RecordingStep → IO ()
failAt standIn at = atomically (modifyTVar' (recordingFailing standIn) (Set.insert at))

succeedAt ∷ RecordingStandIn → RecordingStep → IO ()
succeedAt standIn at = atomically (modifyTVar' (recordingFailing standIn) (Set.delete at))

-- | Run this inside every storage reset, before it is recorded.
duringReset ∷ RecordingStandIn → IO () → IO ()
duringReset standIn action = atomically (writeTVar (recordingDuringReset standIn) action)

-- | Run this inside every recorded command, before it is recorded.
duringRecord ∷ RecordingStandIn → (NativeCommand → IO ()) → IO ()
duringRecord standIn action = atomically (writeTVar (recordingDuringRecord standIn) action)

-- | The memory a readback of this many bytes is given.
standInMemorySize ∷ Natural → Natural
standInMemorySize bytes = ((bytes + 255) `div` 256) * 256

-- | The stand-in device's non-coherent atom.
standInAtom ∷ Natural
standInAtom = 64

journal ∷ RecordingStandIn → RecordingCall → IO ()
journal standIn call = atomically (modifyTVar' (recordingJournal standIn) (call :))

-- | Record the call, then fail if the step is scripted to.
step ∷ RecordingStandIn → RecordingStep → RecordingCall → IO ()
step standIn at call = do
  journal standIn call
  failing ← Set.member at <$> readTVarIO (recordingFailing standIn)
  when failing (throwIO (RecordingFailure at))

fresh ∷ RecordingStandIn → IO Word64
fresh standIn = atomically $ do
  next ← readTVar (recordingHandles standIn)
  writeTVar (recordingHandles standIn) (next + 1)
  pure next

-- | The stand-in's recording layer. The device is whatever the roots hold; a
-- command buffer is a number.
recordingStandInOps ∷ RecordingStandIn → RecordingOps Int Word64
recordingStandInOps standIn =
  RecordingOps
    { opsCreatePipelineLayout = \_ → do
        handle ← fresh standIn
        handle <$ step standIn AtCreateLayout (CreatedLayout handle)
    , opsDestroyPipelineLayout = \_ handle → step standIn AtDestroyLayout (DestroyedLayout handle)
    , opsCreatePipeline = \_ request → do
        handle ← fresh standIn
        handle <$ step standIn AtCreatePipeline (CreatedPipeline handle (requestLayout request) (requestColorFormat request))
    , opsDestroyPipeline = \_ handle → step standIn AtDestroyPipeline (DestroyedPipeline handle)
    , opsCreateStorage = \_ _ → do
        pool ← fresh standIn
        commands ← fresh standIn
        (pool, commands) <$ step standIn AtCreateStorage (CreatedStorage pool commands)
    , opsResetStorage = \_ pool → do
        action ← readTVarIO (recordingDuringReset standIn)
        action
        step standIn AtResetStorage (ResetStorage pool)
    , opsDestroyStorage = \_ pool → step standIn AtDestroyStorage (DestroyedStorage pool)
    , opsCreateReadback = \_ bytes → do
        buffer ← fresh standIn
        memory ← fresh standIn
        coherent ← readTVarIO (recordingCoherent standIn)
        step standIn AtCreateReadback (CreatedReadback buffer bytes coherent)
        let size = standInMemorySize bytes
        atomically (modifyTVar' (recordingMemory standIn) (Map.insert buffer (ByteString.replicate (fromIntegral size) 0)))
        pure
          ReadbackAllocation
            { allocationBuffer = buffer
            , allocationMemory = memory
            , allocationSize = bytes
            , allocationMemorySize = size
            , allocationCoherent = coherent
            , allocationAtom = standInAtom
            , allocationMapped = buffer
            }
    , opsDestroyReadback = \_ allocation → journal standIn (DestroyedReadback (allocationBuffer allocation))
    , opsInvalidate = \_ _ range → journal standIn (Invalidated range)
    , opsFlush = \_ _ range → step standIn AtFlush (Flushed range)
    , opsReadMapped = \allocation offset size → do
        journal standIn (ReadMapped offset size)
        bytes ← Map.findWithDefault ByteString.empty (allocationMapped allocation) <$> readTVarIO (recordingMemory standIn)
        pure (ByteString.take (fromIntegral size) (ByteString.drop (fromIntegral offset) bytes))
    , opsWriteMapped = \allocation offset bytes → do
        journal standIn (WroteMapped offset (fromIntegral (ByteString.length bytes)))
        atomically $ modifyTVar' (recordingMemory standIn) $
          Map.adjust
            ( \held →
                ByteString.take (fromIntegral offset) held
                  <> bytes
                  <> ByteString.drop (fromIntegral offset + ByteString.length bytes) held
            )
            (allocationMapped allocation)
    , opsBeginCommands = \commands → step standIn AtBegin (Began commands)
    , opsEndCommands = \commands → step standIn AtEnd (Ended commands)
    , opsRecord = \commands native → do
        action ← readTVarIO (recordingDuringRecord standIn)
        action native
        let at = case native of
              CommandBeginLabel _ → AtBeginLabel
              CommandEndLabel → AtEndLabel
              _ → AtRecord
        step standIn at (Recorded commands native)
    , opsCommandBufferHandle = id
    }
