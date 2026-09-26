-- | Host access to readback buffers for the managed recording
-- ("Hetoimasia.GPU.Vulkan.Native.Recording"): reading bytes a completed
-- submission wrote, filling a buffer from the host, and the atom-aligned range
-- non-coherent memory is invalidated or flushed over. Bytes are exposed only
-- with completion evidence — the copying batch recorded as submitted and the
-- buffer owing no recorded reference and no submitted use — or after the host
-- wrote them.
--
-- The copy itself is recorded by the recorder
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Recorder"), and the
-- submission evidence by the batch lifecycle
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Batches"). This module
-- advances only a buffer's contents on a host write, in the recording's state
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State"); it owns no state
-- of its own.
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Readback
  ( readReadback
  , fillReadback
  , mappedRange
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception (mask_)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Foldable (for_)
import Data.Word (Word8)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model (HoldKind (..), HoldView (..), holdView)
import Hetoimasia.GPU.Model.Identity (HoldSubject (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer (ReadbackAllocation (..), RecordingOps (..))
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( ManagedRecord (..)
  , NativeResource (..)
  , Readback (..)
  , ReadbackContents (..)
  , Recording (..)
  , Refusal (..)
  , editManaged
  , liveNative
  , owned
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (readRootsDevice, rootsCall, stateRootsModel)

-- | The range of the mapped memory a flush or an invalidation of these bytes
-- of the buffer covers: its start rounded down and its end rounded up to the
-- non-coherent atom, and the end clamped to the memory's size. Answers the
-- offset and the size.
mappedRange ∷ Natural → Natural → Natural → Natural → (Natural, Natural)
mappedRange atom memorySize offset size = (start, end - start)
  where
    step = max 1 atom
    start = (offset `div` step) * step
    end = min memorySize (((offset + size + step - 1) `div` step) * step)

-- | Read bytes a completed submission wrote. Refused unless the batch that
-- recorded the copy was recorded as submitted ('noteBatchSubmitted') and the
-- buffer owes no recorded reference and no submitted use — which the model
-- discharges only on that submission's completion fact; or unless the host
-- wrote them.
-- Non-coherent memory is invalidated over the aligned range first.
readReadback ∷ Recording q inst msgr phys dev cmd → Readback → Natural → Natural → IO (Either Refusal ByteString)
readReadback recording (Readback readback) offset size =
  owned recording $
    liveNative recording readback >>= \case
      Left refusal → pure (Left refusal)
      Right (NativeReadback allocation contents)
        | offset + size > allocationSize allocation → pure (Left (RefusedOutOfBounds (offset + size) (allocationSize allocation)))
        | otherwise → do
            evidence ← atomically $ do
              model ← stateRootsModel roots (\model → (model, model))
              let holds = maybe [] viewOutstanding (holdView (ResourceSubject readback) model)
                  pending = filter (`elem` [RecordedReferenceOwed, SubmittedUseOwed]) holds
              pure $ case contents of
                ContentsUndefined → Left (RefusedNotWritten "nothing has written the buffer")
                ContentsHostWritten
                  | null pending → Right ()
                  | otherwise → Left RefusedInUse
                -- Positive evidence only: the batch that copies into it was
                -- recorded as submitted ('noteBatchSubmitted'), and the buffer
                -- owes no submitted use, which the model discharges only on
                -- that submission's completion fact. A batch the model merely
                -- no longer holds proves nothing: a skip or a reset in the
                -- model removes one without submitting it.
                ContentsCopyRecorded _
                  | not (null pending) → Left (RefusedNotWritten "a batch or a submission still holds the buffer")
                  | otherwise → Left (RefusedNotWritten "no submission of the batch that copies into it is recorded")
                ContentsCopySubmitted _
                  | not (null pending) → Left (RefusedNotWritten "a batch or a submission still holds the buffer")
                  | otherwise → Right ()
            case evidence of
              Left refusal → pure (Left refusal)
              -- An empty read reads nothing, and its range would be an invalid
              -- one to invalidate.
              Right () | size == 0 → pure (Right ByteString.empty)
              Right () → Right <$> readMapped allocation
      Right _ → pure (Left RefusedWrongKind)
  where
    roots = recordingRoots recording
    readMapped allocation = do
      device ← fmap snd <$> atomically (readRootsDevice roots)
      unless (allocationCoherent allocation) $
        for_ device $ \handle →
          rootsCall roots "vkInvalidateMappedMemoryRanges" $
            opsInvalidate (recordingOps recording) handle allocation (mappedRange (allocationAtom allocation) (allocationMemorySize allocation) offset size)
      opsReadMapped (recordingOps recording) allocation offset size

-- | Fill the whole buffer with one byte from the host — a sentinel a later
-- copy must overwrite — and flush it if the memory is not coherent. Refused
-- while any batch or submission holds the buffer: that would change, in
-- place, data a recorded or submitted use depends on.
fillReadback ∷ Recording q inst msgr phys dev cmd → Readback → Word8 → IO (Either Refusal ())
fillReadback recording (Readback readback) byte =
  owned recording $
    liveNative recording readback >>= \case
      Left refusal → pure (Left refusal)
      Right (NativeReadback allocation _) → do
        held ← atomically $ do
          model ← stateRootsModel roots (\model → (model, model))
          pure (maybe [] viewOutstanding (holdView (ResourceSubject readback) model))
        if any (`elem` [RecordedReferenceOwed, SubmittedUseOwed]) held
          then pure (Left RefusedInUse)
          else mask_ $ do
            -- The bytes are unreadable from before the write changes the first
            -- of them until the write and any flush have both returned, so a
            -- write or flush that raised part-way exposes nothing under the
            -- old contents' evidence.
            atomically (setContents ContentsUndefined)
            opsWriteMapped (recordingOps recording) allocation 0 (ByteString.replicate (fromIntegral (allocationSize allocation)) byte)
            device ← fmap snd <$> atomically (readRootsDevice roots)
            unless (allocationCoherent allocation) $
              for_ device $ \handle →
                rootsCall roots "vkFlushMappedMemoryRanges" $
                  opsFlush (recordingOps recording) handle allocation (mappedRange (allocationAtom allocation) (allocationMemorySize allocation) 0 (allocationSize allocation))
            atomically (setContents ContentsHostWritten)
            pure (Right ())
      Right _ → pure (Left RefusedWrongKind)
  where
    roots = recordingRoots recording
    setContents contents = editManaged recording readback $ \entry → case managedNative entry of
      NativeReadback kept _ → entry {managedNative = NativeReadback kept contents}
      _ → entry
