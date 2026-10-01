-- | A stand-in native layer for the recording: every call recorded in order,
-- any step made to fail, and a hook run inside a storage's reset, a command's
-- recording or one call at a step, so an example can observe the model at that
-- instant.
--
-- Handles are small numbers, so a record says which object each call touched.
-- A readback buffer's memory, and its mapping, are the stand-in allocator's
-- ("Test.GPU.Vulkan.Native.AllocatorStandIn"); the bytes behind a mapping are
-- a byte string this stand-in keeps under the mapped address, made on the
-- first write.
module Test.GPU.Vulkan.Native.RecordingStandIn
  ( RecordingStandIn (..)
  , newRecordingStandIn
  , recordingStandInOps
  , RecordingCall (..)
  , recordingCalls
  , RecordingStep (..)
  , failAt
  , succeedAt
  , outOfMemoryAt
  , onceAt
  , duringReset
  , duringRecord
  , RecordingFailure (..)
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, throwIO)
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Vulkan.Native.Naming (ShaderStage (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Roots (NativeFailure (FailedOutOfMemory))
import Test.GPU.Vulkan.Native.StandIn (StandInResult (..))

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
  | AtBegin
  | AtEnd
  | AtRecord
    -- ^ Every recorded command but a label's.
  | AtBeginLabel
  | AtEndLabel
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
  , recordingDuringReset ∷ !(TVar (IO ()))
  , recordingDuringRecord ∷ !(TVar (NativeCommand → IO ()))
  , recordingOutOfMemory ∷ !(TVar (Map RecordingStep Int))
    -- ^ How many more calls at each step answer out of memory (VK-14).
  , recordingOnce ∷ !(TVar (Map RecordingStep (IO ())))
    -- ^ What the next call at each step runs, once, if it did not answer out
    -- of memory.
  }

newRecordingStandIn ∷ IO RecordingStandIn
newRecordingStandIn =
  RecordingStandIn
    <$> newTVarIO []
    <*> newTVarIO Set.empty
    <*> newTVarIO 500
    <*> newTVarIO Map.empty
    <*> newTVarIO (pure ())
    <*> newTVarIO (\_ → pure ())
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty

-- | Every call so far, oldest first.
recordingCalls ∷ RecordingStandIn → IO [RecordingCall]
recordingCalls standIn = reverse <$> readTVarIO (recordingJournal standIn)

failAt ∷ RecordingStandIn → RecordingStep → IO ()
failAt standIn at = atomically (modifyTVar' (recordingFailing standIn) (Set.insert at))

succeedAt ∷ RecordingStandIn → RecordingStep → IO ()
succeedAt standIn at = atomically (modifyTVar' (recordingFailing standIn) (Set.delete at))

-- | Have the next this many calls at the step answer out of memory, as the
-- roots' stand-in classifies it: a creation that raised, having created
-- nothing.
outOfMemoryAt ∷ RecordingStandIn → RecordingStep → Int → IO ()
outOfMemoryAt standIn at times = atomically (modifyTVar' (recordingOutOfMemory standIn) (Map.insert at times))

-- | Run this, once, inside the step's next call that does not answer out of
-- memory, after it is recorded: what it raises, the call raises.
onceAt ∷ RecordingStandIn → RecordingStep → IO () → IO ()
onceAt standIn at action = atomically (modifyTVar' (recordingOnce standIn) (Map.insert at action))

-- | Run this inside every storage reset, before it is recorded.
duringReset ∷ RecordingStandIn → IO () → IO ()
duringReset standIn action = atomically (writeTVar (recordingDuringReset standIn) action)

-- | Run this inside every recorded command, before it is recorded.
duringRecord ∷ RecordingStandIn → (NativeCommand → IO ()) → IO ()
duringRecord standIn action = atomically (writeTVar (recordingDuringRecord standIn) action)

journal ∷ RecordingStandIn → RecordingCall → IO ()
journal standIn call = atomically (modifyTVar' (recordingJournal standIn) (call :))

-- | Record the call, then fail if the step is scripted to.
step ∷ RecordingStandIn → RecordingStep → RecordingCall → IO ()
step standIn at call = do
  journal standIn call
  failing ← Set.member at <$> readTVarIO (recordingFailing standIn)
  when failing (throwIO (RecordingFailure at))
  exhausted ← atomically $ do
    remaining ← Map.findWithDefault 0 at <$> readTVar (recordingOutOfMemory standIn)
    if remaining > 0
      then True <$ modifyTVar' (recordingOutOfMemory standIn) (Map.insert at (remaining - 1))
      else pure False
  when exhausted (throwIO (StandInResult (Text.pack (show at)) FailedOutOfMemory))
  once ← atomically $ do
    held ← Map.lookup at <$> readTVar (recordingOnce standIn)
    held <$ modifyTVar' (recordingOnce standIn) (Map.delete at)
  sequence_ once

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
    , opsCreatePipeline = \_ request name → do
        -- Its shader modules are numbers too, named as the production layer
        -- names them and gone once it returns.
        vertex ← fresh standIn
        name VertexStage vertex
        fragment ← fresh standIn
        name FragmentStage fragment
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
    , opsReadMapped = \allocation offset size → do
        journal standIn (ReadMapped offset size)
        bytes ← Map.findWithDefault ByteString.empty (allocationMapped allocation) <$> readTVarIO (recordingMemory standIn)
        pure (ByteString.take (fromIntegral size) (ByteString.drop (fromIntegral offset) bytes))
    , opsWriteMapped = \allocation offset bytes → do
        journal standIn (WroteMapped offset (fromIntegral (ByteString.length bytes)))
        atomically $ modifyTVar' (recordingMemory standIn) $
          Map.alter
            ( \held →
                let current = fromMaybe (ByteString.replicate (fromIntegral (allocationSize allocation)) 0) held
                 in Just
                      ( ByteString.take (fromIntegral offset) current
                          <> bytes
                          <> ByteString.drop (fromIntegral offset + ByteString.length bytes) current
                      )
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
