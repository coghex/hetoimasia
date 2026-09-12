-- | A fake buffer with a backing allocation, used to exercise
-- 'Hetoimasia.Foundation.Resource.withComposite' against a composite owner
-- whose parts must be released in acquisition order.
--
-- This is test support, not a graphics API. It models exactly the four
-- construction steps the composite contract needs — create the buffer, query
-- what its memory must satisfy, allocate that memory, bind the two — plus the
-- two releases, and it lets an example inject a failure into any one of them.
-- It ships in no library: only the test suite builds this module.
module Test.Engine.Resources.Buffer
  ( -- * The fake device
    Device
  , newDevice
  , deviceTrail

    -- * Injected outcomes
  , Outcomes (..)
  , workingDevice

    -- * The composite
  , Buffer (..)
  , BufferHandle
  , MemoryHandle
  , bufferAssembly
  , bufferLabels
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (throwIO)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource
  ( Assembly
  , acquirePart
  , releaseRank
  , restoredStep
  )

-- | A created buffer. The number distinguishes one from another in a trail.
newtype BufferHandle = BufferHandle Int
  deriving (Eq, Show)

-- | Memory allocated for a buffer.
newtype MemoryHandle = MemoryHandle Int
  deriving (Eq, Show)

-- | What a buffer's memory must satisfy, as the fake device reports it.
newtype Requirements = Requirements Int
  deriving (Eq, Show)

-- | A finished buffer: the handle and the allocation bound behind it.
data Buffer = Buffer
  { bufferHandle ∷ !BufferHandle
  , bufferMemory ∷ !MemoryHandle
  }
  deriving (Eq, Show)

-- | Every operation the fake device performed, in order, and the next handle
-- number to issue.
data Device = Device
  { deviceOperations ∷ MVar [Text]
  , deviceNextHandle ∷ MVar Int
  }

newDevice ∷ IO Device
newDevice = Device <$> newMVar [] <*> newMVar 1

-- | The operations the device performed, oldest first.
deviceTrail ∷ Device → IO [Text]
deviceTrail device = readMVar (deviceOperations device)

note ∷ Device → Text → IO ()
note device entry = modifyMVar_ (deviceOperations device) (pure . (<> [entry]))

issue ∷ Device → IO Int
issue device = modifyMVar (deviceNextHandle device) (\next → pure (next + 1, next))

-- | A failure to inject into one step, or 'Nothing' to let it succeed. The
-- 'String' becomes the message of the 'IOError' that step raises.
type Outcome = Maybe String

-- | The outcome of each construction and release step.
--
-- Every field is a separate injection point, so an example can fail one step
-- and observe exactly which parts were released.
data Outcomes = Outcomes
  { onCreateBuffer ∷ Outcome
  , onQueryRequirements ∷ Outcome
  , onAllocateMemory ∷ Outcome
  , onBindMemory ∷ Outcome
  , onDestroyBuffer ∷ Outcome
  , onFreeMemory ∷ Outcome
  }

-- | A device on which every step succeeds. Examples override one field.
workingDevice ∷ Outcomes
workingDevice =
  Outcomes
    { onCreateBuffer = Nothing
    , onQueryRequirements = Nothing
    , onAllocateMemory = Nothing
    , onBindMemory = Nothing
    , onDestroyBuffer = Nothing
    , onFreeMemory = Nothing
    }

-- | Record one step and then apply its injected outcome. The step is recorded
-- before it can fail, so a trail shows every step that was attempted.
step ∷ Device → Text → Outcome → IO a → IO a
step device entry outcome produce = do
  note device entry
  case outcome of
    Just message → throwIO (userError message)
    Nothing → produce

-- | The labels 'bufferAssembly' retains cleanup failures under, in the
-- declared release order.
bufferLabels ∷ [Text]
bufferLabels = ["buffer", "buffer memory"]

-- | Construct a buffer with its memory bound behind it.
--
-- The buffer is created before its memory is allocated, and the declared
-- release order destroys the buffer before freeing that memory: acquisition
-- order, not the reverse of it. Querying the requirements and binding acquire
-- nothing, so they are restored steps.
bufferAssembly ∷ Device → Outcomes → Assembly Buffer
bufferAssembly device outcomes = do
  handle ←
    acquirePart
      "buffer"
      (releaseRank 0)
      (createBuffer device outcomes)
      (destroyBuffer device outcomes)
  requirements ← restoredStep (queryRequirements device outcomes handle)
  memory ←
    acquirePart
      "buffer memory"
      (releaseRank 1)
      (allocateMemory device outcomes requirements)
      (freeMemory device outcomes)
  restoredStep (bindMemory device outcomes handle memory)
  pure (Buffer handle memory)

createBuffer ∷ Device → Outcomes → IO BufferHandle
createBuffer device outcomes =
  step device "create buffer" (onCreateBuffer outcomes) (BufferHandle <$> issue device)

queryRequirements ∷ Device → Outcomes → BufferHandle → IO Requirements
queryRequirements device outcomes (BufferHandle handle) =
  step
    device
    ("query requirements " <> number handle)
    (onQueryRequirements outcomes)
    (pure (Requirements (handle * 64)))

allocateMemory ∷ Device → Outcomes → Requirements → IO MemoryHandle
allocateMemory device outcomes (Requirements size) =
  step
    device
    ("allocate memory " <> number size)
    (onAllocateMemory outcomes)
    (MemoryHandle <$> issue device)

bindMemory ∷ Device → Outcomes → BufferHandle → MemoryHandle → IO ()
bindMemory device outcomes (BufferHandle handle) (MemoryHandle memory) =
  step
    device
    ("bind " <> number handle <> " to " <> number memory)
    (onBindMemory outcomes)
    (pure ())

destroyBuffer ∷ Device → Outcomes → BufferHandle → IO ()
destroyBuffer device outcomes (BufferHandle handle) =
  step device ("destroy buffer " <> number handle) (onDestroyBuffer outcomes) (pure ())

freeMemory ∷ Device → Outcomes → MemoryHandle → IO ()
freeMemory device outcomes (MemoryHandle memory) =
  step device ("free memory " <> number memory) (onFreeMemory outcomes) (pure ())

number ∷ Int → Text
number = Text.pack . show
