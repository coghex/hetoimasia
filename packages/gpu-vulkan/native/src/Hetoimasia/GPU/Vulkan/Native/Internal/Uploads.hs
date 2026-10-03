-- | The session's uploads (GRS-6; resource services design D-9, D-11, D-20,
-- D-21, D-30): bytes reach a fresh texture, vertex buffer or index buffer
-- through one bounded, host-visible staging buffer the graphics owner holds,
-- recorded into frame-less batches in chunks under a per-turn byte budget,
-- with a ticket that reports completion only on the final chunk's completion.
--
-- Admission runs on any thread. In one transaction it validates the request,
-- reserves its target, a place in the bounded queue and a region of the
-- staging buffer, then copies the caller's bytes into that region on the
-- caller's own thread, so they are free when admission returns. A full queue
-- or a staging buffer with no room is 'UploadBackpressure', answered at once;
-- an upload larger than the whole staging buffer can never fit and is
-- 'UploadOversized', a distinct, permanent refusal.
--
-- The graphics owner progresses uploads on its own thread
-- ('progressUploads'): it observes the batches it recorded, settles what they
-- finished, and records the next copies of waiting uploads — every chunk a
-- band of whole block rows of one mip level, or a byte range of a buffer —
-- into one frame-less batch, up to the turn's budget. An upload has at most
-- one batch in flight: its next chunk waits for the last one's completion.
--
-- This module owns the uploads' state — the queue's entries, the staging
-- regions they hold and their tickets — and adds and removes upload targets in
-- the recording's upload-held set
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State"), which keeps every
-- other batch from using a target, and disposal from destroying it, until its
-- upload has settled. Admission and cancellation run on any thread, in STM;
-- everything else on the graphics owner's.
module Hetoimasia.GPU.Vulkan.Native.Internal.Uploads
  ( -- * Configuration
    UploadConfig
  , uploadStagingBytes
  , uploadTurnBudget
  , uploadQueueCapacity
  , UploadConfigRefused (..)
  , validateUploadConfig

    -- * The uploads
  , Uploads
  , newUploads
  , uploadsSupportBC7

    -- * Admission
  , UploadRequest (..)
  , UploadRefusal (..)
  , UploadPressure (..)
  , submitUpload
  , submitUploadGated

    -- * Tickets
  , UploadTicket
  , ticketUpload
  , UploadState (..)
  , readUploadTicket
  , awaitUploadTicket
  , CancelRefusal (..)
  , cancelUpload

    -- * Progress
  , UploadProgress (..)
  , progressUploads
  , uploadsWaiting
  , closeUploads
  , retireUploads

    -- * Observation
  , UploadPhase (..)
  , UploadView (..)
  , UploadsView (..)
  , readUploads
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVar, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (SomeException, mask, rethrowIO, tryWithContext)
import Control.Monad (forM, forM_, unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)
import System.Timeout (timeout)

import Hetoimasia.Foundation.Time (Duration, durationNanoseconds)
import Hetoimasia.GPU.Model
  ( HoldKind (..)
  , HoldView (..)
  , Initialization (..)
  , endResourceCpuUse
  , holdView
  , releaseResource
  , resourceInitialization
  )
import Hetoimasia.GPU.Model.Access (ResourceKind)
import Hetoimasia.GPU.Model.Identity (HoldSubject (..), IdentityKind (..), Misuse (..), ResourceId, resourceSession)
import Hetoimasia.GPU.Vulkan.Native.Allocator (BoundMemory (memoryResource))
import Hetoimasia.GPU.Vulkan.Native.Internal.Allocation (AllocatedBuffer (..), flushBuffer)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Frameless (recordFramelessIn, withFramelessScope)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State (Frames, framesRecording, lossObserved)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Construction (createStaging)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer
  ( BufferKind (..)
  , FormatBlock (..)
  , ImageDescription (..)
  , ImageFormat
  , ImageKind (TextureImage)
  , ImageUse (..)
  , ReadbackAllocation (..)
  , RecordingLimits (..)
  , RecordingOps (..)
  , bufferResourceKind
  , formatBlock
  , formatNeedsCompressionBC
  , imageKindUse
  , imageResourceKind
  , levelBytes
  , levelExtent
  , levelRows
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Recorder (UploadCopy (..), recordUploadCopies)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( BatchTicket
  , Buffer (..)
  , Image (..)
  , ManagedRecord (..)
  , ManagedStanding (..)
  , NativeResource (..)
  , Recording (..)
  , Refusal (..)
  , TicketState (..)
  , modelEdit
  , owned
  , readTicket
  , tshow
  )
import Hetoimasia.GPU.Vulkan.Native.Profile (DevicePlan (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (TerminalCause, TerminalReport (reportPrimary), readRootsDevice, readRootsModel, readRootsTerminal, rootsSessionIdentity)

-- ---------------------------------------------------------------------------
-- Configuration

-- | The application's upload configuration (D-11): the staging buffer's size
-- in bytes, the bytes the owner records into upload copies in one turn, and
-- how many uploads its queue holds at once. Validated once
-- ('validateUploadConfig'), never clamped.
data UploadConfig = UploadConfig
  { uploadStagingBytes ∷ !Natural
  , uploadTurnBudget ∷ !Natural
  , uploadQueueCapacity ∷ !Natural
  }
  deriving (Eq, Show)

-- | Why an upload configuration was refused.
data UploadConfigRefused
  = StagingNotPositive !Integer
  | StagingUnrepresentable !Integer
    -- ^ Larger than any Vulkan size can hold.
  | BudgetNotPositive !Integer
  | BudgetUnrepresentable !Integer
  | QueueNotPositive !Integer
  | QueueUnrepresentable !Integer
    -- ^ More uploads than the queue can count.
  deriving (Eq, Show)

-- | Validate a configured staging size, turn budget and queue capacity, in
-- that order: zero and negative values, sizes no @VkDeviceSize@ can hold and
-- capacities no 'Int' can count are refused, never clamped. Whether the
-- device can make a staging buffer that large, and whether the budget holds
-- one block row of the widest level any image may have, are asked when the
-- uploads are made ('newUploads').
validateUploadConfig ∷ Integer → Integer → Integer → Either UploadConfigRefused UploadConfig
validateUploadConfig staging budget queue
  | staging <= 0 = Left (StagingNotPositive staging)
  | staging > largestSize = Left (StagingUnrepresentable staging)
  | budget <= 0 = Left (BudgetNotPositive budget)
  | budget > largestSize = Left (BudgetUnrepresentable budget)
  | queue <= 0 = Left (QueueNotPositive queue)
  | queue > toInteger (maxBound ∷ Int) = Left (QueueUnrepresentable queue)
  | otherwise = Right (UploadConfig (fromInteger staging) (fromInteger budget) (fromInteger queue))
  where
    largestSize = 2 ^ (64 ∷ Int) - 1

-- ---------------------------------------------------------------------------
-- The uploads

-- | The session's uploads: the frames whose frame-less batches carry their
-- copies, their configuration, the staging buffer, whether the device can
-- take BC7, and their shared state.
data Uploads q inst msgr phys dev cmd = Uploads
  { uploadsFrames ∷ !(Frames q inst msgr phys dev cmd)
  , uploadsConfig ∷ !UploadConfig
  , uploadsStaging ∷ !Staging
  , uploadsCompressionBC ∷ !Bool
  , uploadsState ∷ !(TVar UploadsState)
  }

-- | The staging buffer: its managed generation, its mapping, its size, and
-- the granularity a region is aligned and padded to.
data Staging = Staging
  { stagingResource ∷ !ResourceId
  , stagingMapping ∷ !ReadbackAllocation
  , stagingBytes ∷ !Natural
  , stagingGranule ∷ !Natural
    -- ^ The larger of the non-coherent atom — one on coherent memory — and
    -- sixteen, which every copy's offset into the staging buffer must be a
    -- multiple of for a BC7 block and for four-byte texels alike. Both are
    -- powers of two.
  }

data UploadsState = UploadsState
  { stateOpen ∷ !Bool
  , stateNext ∷ !Natural
    -- ^ The number the next upload is issued: never reissued.
  , stateHead ∷ !Natural
    -- ^ Where the next region is first tried: the end of the last one.
  , stateEntries ∷ !(Map Natural Entry)
    -- ^ Every upload not yet settled, by its number, so in admission order.
  , stateStalled ∷ !Bool
    -- ^ Whether the last turn could not open a frame-less batch for its
    -- copies: no upload then wakes the owner, whose later turns — the ones
    -- that observe the batches holding the frame-less slots complete — try
    -- again, rather than spinning while every slot is held.
  }

-- | One upload not yet settled.
data Entry = Entry
  { entryTarget ∷ !ResourceId
  , entryShape ∷ !Shape
  , entryRegion ∷ !(Natural, Natural)
    -- ^ Its staging region: where it starts, and the bytes it holds, padded.
  , entryPhase ∷ !UploadPhase
  , entryCursor ∷ !Cursor
    -- ^ The next bytes to copy.
  , entryStarted ∷ !Bool
    -- ^ Whether a batch that copies into its target was submitted: its first
    -- copies are recorded, and it may no longer be cancelled.
  , entryFlight ∷ !(Maybe Flight)
    -- ^ The batch carrying its latest copies, until that batch's completion
    -- or discard is observed.
  , entryClaimed ∷ !Bool
    -- ^ Whether the owner is recording its copies now: claimed in the
    -- transaction that plans the turn, so no cancellation, close or release
    -- can settle it — freeing its staging — while copies from that staging
    -- are being recorded and submitted.
  , entryTicket ∷ !(TVar UploadState)
  , entryIndices ∷ !(Maybe ByteString)
    -- ^ What it writes into an index buffer, which a completed upload leaves
    -- for indexed draws to read.
  }

-- | What an upload writes into: a buffer — its native handle, kind and size
-- — or a texture — its native image, aspect, mip levels, block, base extent,
-- and where each level starts in the upload's bytes.
data Shape
  = ShapeBuffer !Word64 !ResourceKind !Natural
  | ShapeImage !Word64 !Word32 !Word32 !FormatBlock !(Word32, Word32) ![Natural]

-- | Where an upload's next copy starts: a byte offset into a buffer, or a
-- mip level and a block row of it. 'CursorDone' once every copy is recorded.
data Cursor
  = CursorBytes !Natural
  | CursorRows !Word32 !Natural
  | CursorDone
  deriving (Eq, Show)

-- | A batch carrying an upload's copies: its ticket, where its copies began,
-- and whether they were the upload's first and its final ones.
data Flight = Flight
  { flightTicket ∷ !BatchTicket
  , flightFrom ∷ !Cursor
  , flightFirst ∷ !Bool
  , flightFinal ∷ !Bool
  }

-- | Make the session's uploads, on the graphics owner's thread, once the
-- device exists: the configuration is checked against the device — the turn
-- budget must hold one block row of the widest level any image may have,
-- four bytes a texel of @maxImageDimension2D@ (D-30), otherwise
-- 'RefusedOutOfBounds' naming that row and the budget — and the staging
-- buffer is made ('createStaging'), its refusals answered as they are.
newUploads
  ∷ Frames q inst msgr phys dev cmd
  → UploadConfig
  → IO (Either Refusal (Uploads q inst msgr phys dev cmd))
newUploads frames config =
  owned recording $ do
    device ← atomically (readRootsDevice roots)
    limits ← opsRecordingLimits (recordingOps recording)
    let row = 4 * fromIntegral (limitImageDimension limits)
    case device of
      Nothing → pure (Left RefusedDeviceAbsent)
      Just (devicePlan, _)
        | uploadTurnBudget config < row → pure (Left (RefusedOutOfBounds row (uploadTurnBudget config)))
        | otherwise →
            createStaging recording (uploadStagingBytes config) >>= \case
              Left refusal → pure (Left refusal)
              Right (resource, mapping, atom) → do
                state ← newTVarIO (UploadsState True 0 0 Map.empty False)
                pure (Right (Uploads frames config (Staging resource mapping (uploadStagingBytes config) (max 16 atom)) (planTextureCompressionBC devicePlan) state))
  where
    recording = framesRecording frames
    roots = recordingRoots recording

-- | Whether the device takes BC7 (D-21): queried from the device, reported,
-- and never assumed. Where it does not, a BC7 texture is refused at its
-- creation, so no upload into one can be admitted.
uploadsSupportBC7 ∷ Uploads q inst msgr phys dev cmd → Bool
uploadsSupportBC7 = uploadsCompressionBC

-- ---------------------------------------------------------------------------
-- Admission

-- | What an upload writes: every mip level of a texture, base level first,
-- each tightly packed in its format's blocks; or the whole contents of a
-- vertex or index buffer.
data UploadRequest
  = UploadImage !Image ![ByteString]
  | UploadBuffer !Buffer !ByteString

-- | Why an upload was not admitted. Nothing was reserved and nothing copied.
data UploadRefusal
  = UploadBackpressure !UploadPressure
    -- ^ Not now: the queue is full, or the staging buffer has no room for it
    -- until earlier uploads settle.
  | UploadOversized !Natural !Natural
    -- ^ Never: the bytes it needs in staging, padded, and all the staging
    -- buffer holds.
  | UploadNotFresh
    -- ^ The target is not fresh: an initialized texture, one another batch
    -- is initializing, or a buffer an upload was already admitted into or a
    -- batch or submission still holds.
  | UploadAlreadyTargeted
    -- ^ Another upload not yet settled writes into the target.
  | UploadWrongKind
    -- ^ The target is not a texture, a vertex buffer or an index buffer.
  | UploadMalformed !Text
    -- ^ The bytes do not initialize the target exactly: a texture's level
    -- count or a level's size, or a buffer's size.
  | UploadUnsupportedFormat !ImageFormat
    -- ^ BC7, on a device that cannot take it.
  | UploadMisuse !Misuse
    -- ^ The target is another session's, no longer managed, or released.
  | UploadClosed
    -- ^ The owner's exit has begun: nothing more is admitted.
  | UploadSessionFailed !TerminalCause
    -- ^ The session has failed, and this is its primary failure.
  deriving (Eq, Show)

-- | What an upload waits for when it is refused as backpressure.
data UploadPressure = QueueFull | StagingFull
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Admit one upload, from any thread (D-20). In one transaction, before
-- anything is copied: the session must be running and admission open; the
-- target this session's, still managed and not released; a texture, vertex
-- buffer or index buffer; fresh, and no other unsettled upload's target; and
-- the bytes must initialize it exactly — every mip level the texture
-- declares, each the size its format's blocks and extent need, or the
-- buffer's whole size — in a format the device takes. Then the upload's
-- padded size is checked against the whole staging buffer, a permanent
-- refusal, and a place in the queue and a region of the staging buffer are
-- reserved, each a refusal as backpressure when there is none, with the
-- target and the ticket.
--
-- The bytes are then copied into the region on this thread, and the upload
-- is queued to the owner; the caller's bytes are free when this returns. A
-- copy that raised, or was cancelled, gives back every reservation and is
-- re-raised; one that finished after the owner's exit began gives them back
-- too, answering 'UploadClosed'.
submitUpload ∷ Uploads q inst msgr phys dev cmd → UploadRequest → IO (Either UploadRefusal UploadTicket)
submitUpload = submitUploadGated (pure Nothing)

-- | 'submitUpload' under a caller's gate, read in the transaction that
-- reserves the upload and again in the one that queues it: a refusal it
-- answers in either refuses the upload, giving back every reservation. The
-- window integration gates admission on its owner's, so no upload is queued
-- once the owner's admission has closed.
submitUploadGated
  ∷ STM (Maybe UploadRefusal)
  → Uploads q inst msgr phys dev cmd
  → UploadRequest
  → IO (Either UploadRefusal UploadTicket)
submitUploadGated gate uploads request = mask $ \restore →
  atomically (gate >>= maybe (admit uploads request) (pure . Left)) >>= \case
    Left refusal → pure (Left refusal)
    Right (number, ticket, offset, pieces) → do
      written ← tryWithContext @SomeException (restore (writePieces uploads offset pieces))
      case written of
        Left failure → do
          atomically (forget uploads number)
          rethrowIO failure
        Right () →
          atomically $ do
            state ← readTVar (uploadsState uploads)
            refused ← gate
            case refused of
              Just refusal → Left refusal <$ forget uploads number
              Nothing
                | stateOpen state → do
                    modifyTVar' (uploadsState uploads) (\current → current {stateEntries = Map.adjust (\entry → entry {entryPhase = PhaseQueued}) number (stateEntries current)})
                    pure (Right ticket)
                | otherwise → Left UploadClosed <$ forget uploads number

-- | Copy the request's bytes into the staging buffer, level after level.
writePieces ∷ Uploads q inst msgr phys dev cmd → Natural → [ByteString] → IO ()
writePieces uploads offset pieces =
  forM_ (zip (scanl (+) offset (map (fromIntegral . ByteString.length) pieces)) pieces) $ \(start, piece) →
    unless (ByteString.null piece) $
      opsWriteMapped (recordingOps (framesRecording (uploadsFrames uploads))) (stagingMapping (uploadsStaging uploads)) start piece

-- | Everything admission decides and reserves, in one transaction.
admit
  ∷ Uploads q inst msgr phys dev cmd
  → UploadRequest
  → STM (Either UploadRefusal (Natural, UploadTicket, Natural, [ByteString]))
admit uploads request = do
  state ← readTVar (uploadsState uploads)
  primary ← reportPrimary <$> readRootsTerminal roots
  managed ← readTVar (recordingManaged recording)
  uploading ← readTVar (recordingUploading recording)
  filled ← readTVar (recordingFilled recording)
  model ← readRootsModel roots
  let decided = do
        whenLeft (fmap UploadSessionFailed primary)
        unless (stateOpen state) (Left UploadClosed)
        when (resourceSession target /= rootsSessionIdentity roots) (Left (UploadMisuse (ForeignIdentity ResourceIdentity)))
        record ← maybe (Left (UploadMisuse (StaleIdentity ResourceIdentity))) Right (Map.lookup target managed)
        unless (managedStanding record == ManagedLive) (Left (UploadMisuse (WrongPhase ResourceIdentity)))
        when (Set.member target uploading) (Left UploadAlreadyTargeted)
        (shape, indices) ← shapeOf (managedNative record)
        case shape of
          ShapeImage {}
            | resourceInitialization target model /= Just Uninitialized → Left UploadNotFresh
          ShapeBuffer {}
            | Set.member target filled → Left UploadNotFresh
            | any (`elem` [RecordedReferenceOwed, SubmittedUseOwed]) (maybe [] viewOutstanding (holdView (ResourceSubject target) model)) → Left UploadNotFresh
          _ → Right ()
        let padded = roundUp total (stagingGranule staging)
        when (padded > stagingBytes staging) (Left (UploadOversized padded (stagingBytes staging)))
        when (fromIntegral (Map.size (stateEntries state)) >= uploadQueueCapacity (uploadsConfig uploads)) (Left (UploadBackpressure QueueFull))
        offset ← maybe (Left (UploadBackpressure StagingFull)) Right (place state padded)
        pure (shape, indices, offset, padded)
  case decided of
    Left refusal → pure (Left refusal)
    Right (shape, indices, offset, padded) → do
      ticket ← newTVar UploadQueued
      let number = stateNext state
          cursor = case shape of
            ShapeBuffer {} → CursorBytes 0
            ShapeImage {} → CursorRows 0 0
          entry = Entry target shape (offset, padded) PhaseAdmitting cursor False Nothing False ticket indices
          next = offset + padded
      writeTVar
        (uploadsState uploads)
        state
          { stateNext = number + 1
          , stateHead = if next >= stagingBytes staging then 0 else next
          , stateEntries = Map.insert number entry (stateEntries state)
          }
      case shape of
        ShapeBuffer {} → modifyTVar' (recordingFilled recording) (Set.insert target)
        ShapeImage {} → pure ()
      modifyTVar' (recordingUploading recording) (Set.insert target)
      pure (Right (number, UploadTicket number ticket (recordingOwner recording), offset, pieces))
  where
    recording = framesRecording (uploadsFrames uploads)
    roots = recordingRoots recording
    staging = uploadsStaging uploads
    (target, pieces) = case request of
      UploadImage (Image resource) levels → (resource, levels)
      UploadBuffer (Buffer resource) bytes → (resource, [bytes])
    total = sum (map (fromIntegral . ByteString.length) pieces)
    whenLeft = maybe (Right ()) Left
    shapeOf = \case
      NativeImage description memory _
        | imageKind description /= TextureImage → Left UploadWrongKind
        | formatNeedsCompressionBC (imageFormat description) && not (uploadsCompressionBC uploads) → Left (UploadUnsupportedFormat (imageFormat description))
        | Just block ← formatBlock (imageFormat description) → do
            let base = (imageWidth description, imageHeight description)
                expected = [levelBytes block (levelExtent (fst base) (snd base) level) | level ← [0 .. imageMipLevels description - 1]]
                given = map (fromIntegral . ByteString.length) pieces
            when (length given /= length expected) $
              Left (UploadMalformed ("the texture has " <> tshow (length expected) <> " mip levels, and " <> tshow (length given) <> " were given"))
            forM_ (zip3 [0 ∷ Int ..] expected given) $ \(level, wanted, got) →
              when (wanted /= got) (Left (UploadMalformed ("mip level " <> tshow level <> " needs " <> tshow wanted <> " bytes, and " <> tshow got <> " were given")))
            Right
              ( ShapeImage (memoryResource memory) (useAspect (imageKindUse TextureImage)) (imageMipLevels description) block base (init (scanl (+) 0 expected))
              , Nothing
              )
        | otherwise → Left UploadWrongKind
      NativeBuffer kind bytes allocated
        | kind `notElem` [VertexBuffer, IndexBuffer] → Left UploadWrongKind
        | total /= bytes → Left (UploadMalformed ("the buffer holds " <> tshow bytes <> " bytes, and " <> tshow total <> " were given"))
        | otherwise →
            Right
              ( ShapeBuffer (memoryResource (allocatedMemory allocated)) (bufferResourceKind kind) bytes
              , if kind == IndexBuffer then Just (ByteString.copy (mconcat pieces)) else Nothing
              )
      _ → Left UploadWrongKind
    -- The first gap that holds the region, tried from where the last one
    -- ended and then from the start, so regions wrap round.
    place state padded =
      let taken = sortOn fst [(offset, offset + span') | entry ← Map.elems (stateEntries state), let (offset, span') = entryRegion entry]
          ends = map snd taken
          gaps = zip (0 : ends) (map fst taken <> [stagingBytes staging])
          start = stateHead state
          ahead = [(max low start, high) | (low, high) ← gaps, high > start]
          fits (low, high) = let offset = roundUp low (stagingGranule staging) in if offset + padded <= high then Just offset else Nothing
       in case [offset | Just offset ← map fits (ahead <> gaps)] of
            offset : _ → Just offset
            [] → Nothing

-- | Forget an upload that was never queued: its entry, its region and its
-- target's hold. Its ticket was never answered.
forget ∷ Uploads q inst msgr phys dev cmd → Natural → STM ()
forget uploads number = do
  state ← readTVar (uploadsState uploads)
  for' (Map.lookup number (stateEntries state)) $ \entry → do
    writeTVar (uploadsState uploads) state {stateEntries = Map.delete number (stateEntries state)}
    modifyTVar' (recordingFilled (framesRecording (uploadsFrames uploads))) (Set.delete (entryTarget entry))
    unhold uploads (entryTarget entry)

-- ---------------------------------------------------------------------------
-- Tickets

-- | Where one upload stands. It only advances, and 'UploadComplete',
-- 'UploadCancelled' and 'UploadLost' are terminal.
data UploadState
  = UploadQueued
    -- ^ Admitted, and none of its copies recorded yet: it may be cancelled.
  | UploadUploading
    -- ^ Its first copies are recorded: it completes, and may not be
    -- cancelled.
  | UploadComplete
    -- ^ Its final copies' batch was observed complete: its target is
    -- initialized, rests in its kind's resting use, and other batches may use
    -- it.
  | UploadCancelled
    -- ^ Cancelled before any copy was recorded — by its caller, its target's
    -- release, or the owner's exit — or left unfinished by the exit. Its
    -- target was not initialized by it.
  | UploadLost
    -- ^ The device was lost before it completed.
  deriving (Eq, Show)

-- | One upload's ticket, read from any thread without a native call.
data UploadTicket = UploadTicket
  { ticketUpload ∷ !Natural
    -- ^ The upload's number, never reissued.
  , ticketCell ∷ !(TVar UploadState)
  , ticketOwner ∷ !ThreadId
    -- ^ The graphics owner's thread, on which no wait may block.
  }

instance Eq UploadTicket where
  left == right = ticketUpload left == ticketUpload right

instance Show UploadTicket where
  showsPrec precedence ticket = showParen (precedence > 10) (showString "UploadTicket " . showsPrec 11 (ticketUpload ticket))

-- | The upload's state now. It never waits.
readUploadTicket ∷ UploadTicket → STM UploadState
readUploadTicket = readTVar . ticketCell

-- | Wait, at most this long, for the upload to settle, and answer its state
-- then — still queued or uploading if the deadline passed first. The wait is
-- the caller's alone: its expiry, or its cancellation, cancels nothing and
-- completes nothing. It is refused on the graphics owner's thread, whose own
-- progress the upload needs.
awaitUploadTicket ∷ UploadTicket → Duration → IO (Either Refusal UploadState)
awaitUploadTicket ticket limit = do
  current ← myThreadId
  if current == ticketOwner ticket
    then pure (Left RefusedOwnerWait)
    else do
      _ ← timeout microseconds (atomically (readUploadTicket ticket >>= \state → if settled state then pure state else retry))
      Right <$> atomically (readUploadTicket ticket)
  where
    microseconds = fromInteger (min (toInteger (maxBound ∷ Int)) (toInteger (durationNanoseconds limit) `div` 1000))

settled ∷ UploadState → Bool
settled = (`elem` [UploadComplete, UploadCancelled, UploadLost])

-- | Why a cancellation was refused. Nothing changed.
data CancelRefusal
  = CancelStarted
    -- ^ Its first copies are recorded: it completes.
  | CancelSettled !UploadState
    -- ^ It has already settled, so.
  | CancelUnknown
    -- ^ Not one of these uploads'.
  deriving (Eq, Show)

-- | Cancel an upload, from any thread, before its first copies are recorded:
-- its bytes and its staging region are freed, its ticket answers
-- 'UploadCancelled', and its target is left as it was — uninitialized, and
-- free for another upload. Once the owner has claimed it to record its first
-- copies, it is refused, and the upload completes.
cancelUpload ∷ Uploads q inst msgr phys dev cmd → UploadTicket → STM (Either CancelRefusal ())
cancelUpload uploads ticket = do
  state ← readTVar (uploadsState uploads)
  current ← readUploadTicket ticket
  case Map.lookup (ticketUpload ticket) (stateEntries state) of
    _ | settled current → pure (Left (CancelSettled current))
    Nothing → pure (Left CancelUnknown)
    Just entry
      | entryTicket entry /= ticketCell ticket → pure (Left CancelUnknown)
      | entryStarted entry || isFlying entry || entryClaimed entry → pure (Left CancelStarted)
      | otherwise → Right () <$ settle uploads (ticketUpload ticket) UploadCancelled
  where
    isFlying = maybe False (const True) . entryFlight

-- | Settle one upload: its ticket, its entry, its region, its target's hold
-- — releasing, now, a target its owner released while the upload held it —
-- and, for a completed index buffer upload, the indices it wrote. A buffer
-- left uninitialized by a cancellation may be uploaded into again.
settle ∷ Uploads q inst msgr phys dev cmd → Natural → UploadState → STM ()
settle uploads number outcome = do
  state ← readTVar (uploadsState uploads)
  for' (Map.lookup number (stateEntries state)) $ \entry → do
    writeTVar (entryTicket entry) outcome
    writeTVar (uploadsState uploads) state {stateEntries = Map.delete number (stateEntries state)}
    when (outcome == UploadCancelled && not (entryStarted entry)) $
      modifyTVar' (recordingFilled recording) (Set.delete (entryTarget entry))
    when (outcome == UploadComplete) $
      for' (entryIndices entry) $ \indices → modifyTVar' (recordingIndexData recording) (Map.insert (entryTarget entry) indices)
    unhold uploads (entryTarget entry)
  where
    recording = framesRecording (uploadsFrames uploads)

-- | End an upload's hold on its target, and release the target in the model
-- if its owner released it meanwhile.
unhold ∷ Uploads q inst msgr phys dev cmd → ResourceId → STM ()
unhold uploads target = do
  modifyTVar' (recordingUploading recording) (Set.delete target)
  deferred ← Set.member target <$> readTVar (recordingReleaseDeferred recording)
  when deferred $ do
    modifyTVar' (recordingReleaseDeferred recording) (Set.delete target)
    modelEdit roots (releaseResource target)
    modelEdit roots (endResourceCpuUse target)
  where
    recording = framesRecording (uploadsFrames uploads)
    roots = recordingRoots recording

-- ---------------------------------------------------------------------------
-- Progress

-- | What a progress step did: whether it recorded or settled anything, and
-- whether an upload is still waiting to record copies with no batch of its
-- own in flight — work the next turn has.
data UploadProgress = UploadProgress
  { progressAdvanced ∷ !Bool
  , progressWaiting ∷ !Bool
  }
  deriving (Eq, Show)

-- | One owner turn's uploads, on the graphics owner's thread:
--
-- 1. After the device's loss, every upload not yet settled is lost.
-- 2. Each batch in flight is observed: one complete moves its upload on, and
--    completes it if it carried the final copies; one discarded — never
--    submitted — returns its upload to where those copies began, to be
--    recorded again; one lost loses its upload.
-- 3. An upload not yet started whose target was released is cancelled.
-- 4. Every queued or uploading upload with copies left and no batch in
--    flight — in admission order, while admission is open and the session is
--    running — has its next copies recorded into one frame-less batch, up to
--    the turn's budget: whole block rows of one level at a time, or a byte
--    range of a buffer. Its staging bytes are flushed first on non-coherent
--    memory. A frame-less batch the budget cannot open now records nothing
--    this turn. The batch is submitted as the turn's scope ends; one the
--    queue did not accept moves nothing on.
progressUploads ∷ Uploads q inst msgr phys dev cmd → IO (Either Refusal UploadProgress)
progressUploads uploads =
  owned (framesRecording frames) . fmap Right $ do
    lost ← atomically (lossObserved frames)
    if lost
      then do
        changed ← atomically (loseAll uploads)
        pure (UploadProgress changed False)
      else do
        observed ← atomically (observeFlights uploads)
        released ← atomically (cancelReleased uploads)
        recorded ← recordTurn uploads
        waiting ← atomically (uploadsWaiting uploads)
        pure (UploadProgress (observed || released || recorded) waiting)
  where
    frames = uploadsFrames uploads

-- | Whether an upload is waiting for the owner: admission open, the last
-- turn not refused a frame-less batch, and one queued or uploading with
-- copies left and no batch of its own in flight. Any thread may ask; the
-- window integration's wake asks it, so admission makes an idle owner
-- runnable.
uploadsWaiting ∷ Uploads q inst msgr phys dev cmd → STM Bool
uploadsWaiting uploads = do
  state ← readTVar (uploadsState uploads)
  pure (stateOpen state && not (stateStalled state) && any recordable (Map.elems (stateEntries state)))

recordable ∷ Entry → Bool
recordable entry =
  entryPhase entry `elem` [PhaseQueued, PhaseUploading]
    && entryCursor entry /= CursorDone
    && maybe True (const False) (entryFlight entry)
    && not (entryClaimed entry)

-- | Settle every upload not yet settled as lost — except those whose caller
-- is still copying its bytes into staging, whose region stays its own until
-- that caller finishes; it is lost on a later turn.
loseAll ∷ Uploads q inst msgr phys dev cmd → STM Bool
loseAll uploads = do
  entries ← Map.toList . stateEntries <$> readTVar (uploadsState uploads)
  let numbers = [number | (number, entry) ← entries, entryPhase entry /= PhaseAdmitting]
  forM_ numbers (\number → settle uploads number UploadLost)
  pure (not (null numbers))

-- | Observe every batch in flight, as step 2 of 'progressUploads' says.
observeFlights ∷ Uploads q inst msgr phys dev cmd → STM Bool
observeFlights uploads = do
  entries ← Map.toList . stateEntries <$> readTVar (uploadsState uploads)
  results ← forM entries $ \(number, entry) → case entryFlight entry of
    Nothing → pure False
    Just flight →
      readTicket (flightTicket flight) >>= \case
        TicketPending → pure False
        TicketComplete
          | flightFinal flight → True <$ settle uploads number UploadComplete
          | otherwise → True <$ edit number (\held → held {entryFlight = Nothing})
        TicketDiscarded →
          True <$ edit number (\held → held {entryFlight = Nothing, entryCursor = flightFrom flight, entryStarted = entryStarted held && not (flightFirst flight)})
        TicketLost → True <$ settle uploads number UploadLost
  pure (or results)
  where
    edit number change = modifyTVar' (uploadsState uploads) (\state → state {stateEntries = Map.adjust change number (stateEntries state)})

-- | Cancel every upload not yet started whose target its owner released.
cancelReleased ∷ Uploads q inst msgr phys dev cmd → STM Bool
cancelReleased uploads = do
  deferred ← readTVar (recordingReleaseDeferred (framesRecording (uploadsFrames uploads)))
  entries ← Map.toList . stateEntries <$> readTVar (uploadsState uploads)
  let released =
        [ number
        | (number, entry) ← entries
        , entryPhase entry == PhaseQueued
        , not (entryStarted entry)
        , maybe True (const False) (entryFlight entry)
        , not (entryClaimed entry)
        , Set.member (entryTarget entry) deferred
        ]
  forM_ released (\number → settle uploads number UploadCancelled)
  pure (not (null released))

-- | One planned upload's copies in this turn's batch.
data Planned = Planned
  { plannedNumber ∷ !Natural
  , plannedEntry ∷ !Entry
  , plannedCopies ∷ ![UploadCopy]
  , plannedNext ∷ !Cursor
  , plannedRange ∷ !(Natural, Natural)
    -- ^ The staging bytes its copies read: where they start, and how many.
  }

-- | Plan and record this turn's copies, as step 4 of 'progressUploads' says.
recordTurn ∷ Uploads q inst msgr phys dev cmd → IO Bool
recordTurn uploads = do
  -- Planned and claimed in one transaction, so nothing settles a planned
  -- upload, freeing its staging, while its copies are recorded and
  -- submitted. A recording that raised leaves its uploads claimed: what it
  -- recorded or submitted is unknown, so their staging stays held until the
  -- owner's retirement settles them.
  planned ← atomically $ do
    state ← readTVar (uploadsState uploads)
    primary ← reportPrimary <$> readRootsTerminal roots
    let candidates = [(number, entry) | stateOpen state, Nothing ← [primary], (number, entry) ← Map.toList (stateEntries state), recordable entry]
        chosen = plan (uploadTurnBudget (uploadsConfig uploads)) candidates
    forM_ chosen (\item → edit (plannedNumber item) (\held → held {entryClaimed = True}))
    pure chosen
  if null planned
    then pure False
    else do
      forM_ planned flush
      outcome ← withFramelessScope frames $ \scope →
        recordFramelessIn scope $ \recorder →
          forM planned $ \item →
            let entry = plannedEntry item
                (object, kind, image) = case entryShape entry of
                  ShapeBuffer handle kind' _ → (handle, kind', Nothing)
                  ShapeImage handle aspect levels _ _ _ → (handle, imageResourceKind TextureImage, Just (aspect, levels))
                first = entryCursor entry == startCursor (entryShape entry)
                final = plannedNext item == CursorDone
             in (,) item <$> recordUploadCopies recorder (entryTarget entry) object kind image (stagingResource staging) (allocationBuffer (stagingMapping staging)) first final (plannedCopies item)
      atomically $ do
        modifyTVar' (uploadsState uploads) (\current → current {stateStalled = either (const True) (const False) outcome})
        forM_ planned (\item → edit (plannedNumber item) (\held → held {entryClaimed = False}))
      case outcome of
        Left _ → pure False
        Right (ticket, results) → do
          accepted ← (/= TicketDiscarded) <$> atomically (readTicket ticket)
          atomically $
            forM_ [item | (item, Right ()) ← results, accepted] $ \item →
              let entry = plannedEntry item
                  first = entryCursor entry == startCursor (entryShape entry)
                  final = plannedNext item == CursorDone
               in modifyTVar' (uploadsState uploads) $ \current →
                    current
                      { stateEntries =
                          Map.adjust
                            ( \held →
                                held
                                  { entryPhase = PhaseUploading
                                  , entryCursor = plannedNext item
                                  , entryStarted = True
                                  , entryFlight = Just (Flight ticket (entryCursor held) first final)
                                  }
                            )
                            (plannedNumber item)
                            (stateEntries current)
                      }
          atomically $
            forM_ [item | (item, Right ()) ← results, accepted] $ \item →
              -- Only a ticket still unsettled: a ticket only advances.
              readTVar (entryTicket (plannedEntry item)) >>= \current →
                when (current == UploadQueued) (writeTVar (entryTicket (plannedEntry item)) UploadUploading)
          pure accepted
  where
    frames = uploadsFrames uploads
    roots = recordingRoots (framesRecording frames)
    staging = uploadsStaging uploads
    edit number change = modifyTVar' (uploadsState uploads) (\state → state {stateEntries = Map.adjust change number (stateEntries state)})
    -- Make the bytes a planned upload's copies read visible to the device on
    -- non-coherent memory: aligned to the atom, never beyond its region.
    flush item =
      unless (allocationCoherent mapping) $ do
        let (offset, span') = entryRegion (plannedEntry item)
            (start, count) = plannedRange item
            low = roundDown start atom
            high = min (offset + span') (roundUp (start + count) atom)
        flushBuffer roots (AllocatedBuffer (allocationMemory mapping) False (Just (allocationMapped mapping))) (low, high - low)
      where
        mapping = stagingMapping staging
        atom = stagingGranule staging

-- | Where an upload's copies start.
startCursor ∷ Shape → Cursor
startCursor = \case
  ShapeBuffer {} → CursorBytes 0
  ShapeImage {} → CursorRows 0 0

-- | This turn's copies: uploads in admission order, each as many whole block
-- rows of one level at a time — or as many bytes of a buffer — as the budget
-- has left, until it has none left for the next row.
plan ∷ Natural → [(Natural, Entry)] → [Planned]
plan budget = go budget
  where
    go _ [] = []
    go left ((number, entry) : rest) =
      case chunk left entry of
        Nothing → []
        Just (copies, next, range, used) → Planned number entry copies next range : go (left - used) rest

-- | The copies one upload records with this much budget: 'Nothing' when not
-- one block row, or byte, fits.
chunk ∷ Natural → Entry → Maybe ([UploadCopy], Cursor, (Natural, Natural), Natural)
chunk budget entry = case (entryShape entry, entryCursor entry) of
  (ShapeBuffer _ _ bytes, CursorBytes from)
    | budget == 0 → Nothing
    | otherwise →
        let count = min budget (bytes - from)
            next = if from + count >= bytes then CursorDone else CursorBytes (from + count)
         in Just ([CopyBytes (base + from) from count], next, (base + from, count), count)
  (ShapeImage _ _ levels block extent offsets, CursorRows level row) → rows budget levels block extent offsets level row
  _ → Nothing
  where
    base = fst (entryRegion entry)
    rows left levels block (width, height) offsets level row
      | level >= levels = Nothing
      | otherwise =
          let levelSize@(levelWidth, levelHeight) = levelExtent width height level
              (total, rowBytes) = levelRows block levelSize
              take' = min (total - row) (left `div` rowBytes)
           in if take' == 0
                then Nothing
                else
                  let start = base + (offsets !! fromIntegral level) + row * rowBytes
                      firstTexel = fromIntegral row * blockHeight block
                      lastTexel = min levelHeight (fromIntegral (row + take') * blockHeight block)
                      copy = CopyRows start level firstTexel levelWidth (lastTexel - firstTexel)
                      used = take' * rowBytes
                      (next, more) =
                        if row + take' < total
                          then (CursorRows level (row + take'), Nothing)
                          else
                            if level + 1 < levels
                              then (CursorRows (level + 1) 0, rows (left - used) levels block (width, height) offsets (level + 1) 0)
                              else (CursorDone, Nothing)
                   in case more of
                        Just (copies, after, (_, moreCount), moreUsed) → Just (copy : copies, after, (start, used + moreCount), used + moreUsed)
                        Nothing → Just ([copy], next, (start, used), used)

-- ---------------------------------------------------------------------------
-- Exit

-- | Close admission, from the owner's exit: nothing more is admitted, and
-- every upload not yet started is cancelled, its staging freed and its
-- target left as it was. Those started go on with the other frame-less work.
closeUploads ∷ Uploads q inst msgr phys dev cmd → STM ()
closeUploads uploads = do
  modifyTVar' (uploadsState uploads) (\state → state {stateOpen = False})
  entries ← Map.toList . stateEntries <$> readTVar (uploadsState uploads)
  forM_ [number | (number, entry) ← entries, entryPhase entry == PhaseQueued, not (entryStarted entry), maybe True (const False) (entryFlight entry), not (entryClaimed entry)] $ \number →
    settle uploads number UploadCancelled

-- | Settle every upload at the owner's retirement, once its frame-less work
-- has drained: admission closes; every caller still copying its bytes into
-- staging is waited for, so the staging buffer, released with the recording
-- after this, is never unmapped under a writer — each finds admission closed
-- and gives its reservations back; each batch in flight is observed once
-- more; and every upload still unsettled is lost if the device was lost, and
-- otherwise cancelled — left unfinished by the exit, its target released
-- with the rest of the recording. The wait is for copies into mapped memory
-- already under way, which no other thread's progress holds up.
retireUploads ∷ Uploads q inst msgr phys dev cmd → IO (Either Refusal ())
retireUploads uploads = owned (framesRecording (uploadsFrames uploads)) . fmap Right $ do
  atomically (closeUploads uploads)
  atomically $ do
    entries ← Map.elems . stateEntries <$> readTVar (uploadsState uploads)
    when (any ((== PhaseAdmitting) . entryPhase) entries) retry
  lost ← atomically (lossObserved (uploadsFrames uploads))
  atomically $ do
    unless lost (() <$ observeFlights uploads)
    numbers ← Map.keys . stateEntries <$> readTVar (uploadsState uploads)
    forM_ numbers (\number → settle uploads number (if lost then UploadLost else UploadCancelled))

-- ---------------------------------------------------------------------------
-- Observation

-- | Where an unsettled upload stands for the owner.
data UploadPhase
  = PhaseAdmitting
    -- ^ Its bytes are being copied in by its caller.
  | PhaseQueued
  | PhaseUploading
  deriving (Eq, Show)

-- | One unsettled upload as an observer sees it.
data UploadView = UploadView
  { uploadNumber ∷ !Natural
  , uploadTarget ∷ !ResourceId
  , uploadPhase ∷ !UploadPhase
  , uploadRegion ∷ !(Natural, Natural)
    -- ^ Its staging region: where it starts, and the bytes it holds, padded.
  , uploadStarted ∷ !Bool
    -- ^ Whether a batch carrying its first copies was submitted.
  , uploadInFlight ∷ !Bool
    -- ^ Whether a batch carrying its copies is in flight.
  , uploadCopied ∷ !Bool
    -- ^ Whether every copy is recorded.
  }
  deriving (Eq, Show)

-- | Every unsettled upload, in admission order, whether admission is open,
-- and the staging buffer's generation and size.
data UploadsView = UploadsView
  { uploadsAdmitting ∷ !Bool
    -- ^ Whether admission is open.
  , uploadsStagingBuffer ∷ !ResourceId
  , uploadsStagingSize ∷ !Natural
  , uploadsUnsettled ∷ ![UploadView]
  }
  deriving (Eq, Show)

readUploads ∷ Uploads q inst msgr phys dev cmd → STM UploadsView
readUploads uploads = do
  state ← readTVar (uploadsState uploads)
  pure
    UploadsView
      { uploadsAdmitting = stateOpen state
      , uploadsStagingBuffer = stagingResource (uploadsStaging uploads)
      , uploadsStagingSize = stagingBytes (uploadsStaging uploads)
      , uploadsUnsettled =
          [ UploadView number (entryTarget entry) (entryPhase entry) (entryRegion entry) (entryStarted entry) (maybe False (const True) (entryFlight entry)) (entryCursor entry == CursorDone)
          | (number, entry) ← Map.toList (stateEntries state)
          ]
      }

-- ---------------------------------------------------------------------------
-- Helpers

roundUp ∷ Natural → Natural → Natural
roundUp value granule = ((value + granule - 1) `div` granule) * granule

roundDown ∷ Natural → Natural → Natural
roundDown value granule = (value `div` granule) * granule

for' ∷ Applicative f ⇒ Maybe a → (a → f ()) → f ()
for' held action = maybe (pure ()) action held
