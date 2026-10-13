-- | Retained chunks in the backend (R2D-10; decisions D-1, D-28, D-31): building
-- one, its device-local buffer and the upload that fills it, the logical
-- release marker, and the buffer's release.
--
-- = Building
--
-- 'buildRetainedChunk', on the graphics owner's thread inside an action that
-- lends the host's 'Builders', turns a list of instances into a 'ChunkRef':
--
-- 1. it builds the immutable description with @render-2d@'s 'buildChunk' (or
--    'buildChunkWith', for a chunk that carries its own records for the
--    application materials its instances use, R2D-11) for one kind of layer,
--    routing the instances once against the textures' registered marks (D-3,
--    D-22), and refuses the instances, the records or the bounds that do not
--    validate, with every reason;
-- 2. it encodes the cutout-path instances, 64 bytes each in the order the buffer
--    holds them ('encodeChunkCutouts');
-- 3. when there are any, it makes a device-local vertex buffer of exactly that
--    size and admits the upload that fills it through the bounded staging
--    uploads. A chunk with no cutout instance, which is every chunk of a world
--    layer without depth and of a UI layer, makes no buffer and no upload: a
--    zero-byte buffer is refused by the backend, and an ordered-path instance is
--    written to the ring each frame, never retained on the device;
-- 4. it registers the description with the buffer and the upload's ticket under
--    a fresh reference.
--
-- A refusal changes nothing the registry holds. A buffer made for a chunk whose
-- upload was refused is released at once, and so is one made when an exception
-- or a cancellation interrupts the build after it was made, so no refusal and no
-- interruption leaves a buffer behind. The refusals say what to do about them:
-- 'BuildUploadBackpressure' is the staging buffer or its queue being full now,
-- and asking again later can succeed; 'BuildUploadRefused' is every other
-- refusal, none of which asking again changes, among them 'UploadOversized'
-- (a chunk whose cutout bytes cannot fit the staging buffer at all: build it as
-- smaller chunks) and a failed or closed session.
--
-- A chunk's records are not retained on the device: they are written into the
-- batch's storage region each frame, beside the view's, and the textures their
-- handles name are held with the chunk's, so a snapshot that lists the chunk
-- holds them as it holds the instances' own. A chunk's records follow the hold
-- and release rules of the chunk itself ("Hetoimasia.Render.TwoD.Vulkan.Window").
--
-- = Standing
--
-- A built chunk is /uploading/ until its ticket reports the upload complete. A
-- frame that draws a scene referencing an uploading chunk is skipped and its
-- demand kept (D-28), and nothing renders an incomplete chunk; a ticket that
-- ended without completing (cancelled, or the device lost) is /failed/, an
-- outcome of its own that a frame and a publication report instead of waiting
-- for it. 'chunkStanding' reads it from any thread without a native call.
--
-- = Release
--
-- 'markChunkReleased' is the logical release: it marks the chunk released at
-- once, for publication's check, and answers 'False' for one never built or
-- already marked. The buffer's release ('releaseChunkNow') is the backend's, run
-- on the owner's thread once no adopted revision holds the chunk; the window
-- adapter ("Hetoimasia.Render.TwoD.Vulkan.Window") sequences the two. Releasing
-- the chunk ends its reference: the registry forgets the chunk, the index goes
-- back to the free list with the next generation, and the old reference resolves
-- to nothing from then on, never to content built later.
--
-- = State
--
-- A 'Retained' owns, in one transaction variable, the chunk of each live
-- reference, its buffer and ticket, its release flag, the generation of every
-- index and the indices free to reuse. Building, the buffer's release and
-- 'releaseChunkNow' run on the graphics owner's thread; every read is from any
-- thread, in STM. A reference lives from its build until the buffer's release
-- and is never reissued while it lives.
module Hetoimasia.Render.TwoD.Vulkan.Chunks
  ( Retained
  , newRetained
  , BuildRefusal (..)
  , buildRetainedChunk
  , buildRetainedChunkWith
  , ChunkStanding (..)
  , chunkStanding
  , chunkStandingSTM
  , retainedChunks
  , RetainedView (..)
  , retainedViewSTM
  , retainedBuffers
  , chunkBufferOf
  , markChunkReleased
  , markChunkReleasedSTM
  , isChunkReleased
  , releaseChunkNow
  , liveChunks
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (mask_, onException)
import Control.Monad (when)
import qualified Data.ByteString as ByteString
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Recording (Buffer, Refusal)
import Hetoimasia.GPU.Vulkan.Native.Uploads (UploadPressure, UploadRefusal (..), UploadState (..), UploadTicket, readUploadTicket)
import Hetoimasia.Render.TwoD.Chunk
  ( BoundsRequest
  , Chunk
  , ChunkKind
  , ChunkRef
  , ChunkRefusal
  , Chunks
  , buildChunkWith
  , chunksFrom
  )
import Hetoimasia.Render.TwoD.Material (MaterialRecord, MaterialRef)
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef, chunkRefGeneration, chunkRefIndex)
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks)
import Hetoimasia.Render.TwoD.Encoding (encodeChunkCutouts)
import Hetoimasia.Render.TwoD.Snapshot (Instance)
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders (..))
import Numeric.Natural (Natural)

-- | The registry of retained chunks.
newtype Retained = Retained (TVar Ledger)

data Ledger = Ledger
  { ledgerEntries ∷ !(Map ChunkRef Entry)
  , ledgerGenerations ∷ !(Map Word32 Word32)
    -- ^ The generation each index has now, issued or free.
  , ledgerFree ∷ ![Word32]
    -- ^ The indices free to reuse, with the generation they will be issued under.
  , ledgerNext ∷ !Word32
    -- ^ The next index never issued.
  }

data Entry = Entry
  { entryChunk ∷ !Chunk
  , entryDevice ∷ !(Maybe (Buffer, UploadTicket))
    -- ^ The cutout instances' buffer and the upload that fills it; 'Nothing' for
    -- a chunk with none.
  , entryReleased ∷ !Bool
  }

-- | A registry holding no chunk.
newRetained ∷ IO Retained
newRetained = Retained <$> newTVarIO (Ledger Map.empty Map.empty [] 0)

-- | Why a chunk was not built. Nothing is held for any of them.
data BuildRefusal
  = -- | The instances or the bounds, with every reason.
    BuildInvalid !(NonEmpty ChunkRefusal)
  | -- | The backend refused the buffer.
    BuildBufferRefused !Refusal
  | -- | The staging buffer or its queue is full now: nothing is held, and a later
    -- build can succeed.
    BuildUploadBackpressure !UploadPressure
  | -- | The backend refused the upload for good, or the session has ended: the
    -- refusal says which.
    BuildUploadRefused !UploadRefusal
  | -- | Every reference this registry can issue is in use.
    BuildReferencesExhausted
  deriving (Eq, Show)

-- | Build a chunk on the graphics owner's thread: describe, route and bound it,
-- encode its cutout instances, make their buffer, admit their upload and register
-- it. The instances are routed against the registered marks the caller gives.
buildRetainedChunk
  ∷ Builders q inst msgr phys dev cmd
  → Retained
  → CutoutMarks
  → ChunkKind
  → BoundsRequest
  → [Instance]
  → IO (Either BuildRefusal ChunkRef)
buildRetainedChunk builders retained marks kind bounds = buildRetainedChunkWith builders retained marks kind bounds Map.empty

-- | 'buildRetainedChunk' for a chunk that carries its own records (R2D-11, D-31)
-- for the application materials its instances use: each must have the layout its
-- material declares and each instance's parameter word must index the records
-- the chunk holds for its material, or the build is refused with every reason
-- ('BuildInvalid'). Whether the materials were issued to the renderer the chunk
-- is drawn by is checked at publication and at recording, naming the instance.
buildRetainedChunkWith
  ∷ Builders q inst msgr phys dev cmd
  → Retained
  → CutoutMarks
  → ChunkKind
  → BoundsRequest
  → Map MaterialRef [MaterialRecord]
  → [Instance]
  → IO (Either BuildRefusal ChunkRef)
buildRetainedChunkWith builders (Retained ledger) marks kind bounds records instances =
  case buildChunkWith marks kind bounds records instances of
    Left refusals → pure (Left (BuildInvalid refusals))
    Right described → mask_ $ do
      made ← deviceFor (encodeChunkCutouts described)
      case made of
        Left refusal → pure (Left refusal)
        Right held → do
          registered ← atomically (issue described held) `onException` abandon held
          case registered of
            Left refusal → Left refusal <$ abandon held
            Right reference → pure (Right reference)
  where
    deviceFor bytes
      | ByteString.null bytes = pure (Right Nothing)
      | otherwise =
          buildVertexBuffer builders (fromIntegral (ByteString.length bytes) ∷ Natural) >>= \case
            Left refusal → pure (Left (BuildBufferRefused refusal))
            Right buffer →
              (uploadBuffer builders buffer bytes `onException` releaseBuffer builders buffer) >>= \case
                Left (UploadBackpressure pressure) → Left (BuildUploadBackpressure pressure) <$ releaseBuffer builders buffer
                Left refusal → Left (BuildUploadRefused refusal) <$ releaseBuffer builders buffer
                Right ticket → pure (Right (Just (buffer, ticket)))
    issue described held = do
      current ← readTVar ledger
      case nextReference current of
        Nothing → pure (Left BuildReferencesExhausted)
        Just (reference, afterwards) → do
          writeTVar ledger afterwards {ledgerEntries = Map.insert reference (Entry described held False) (ledgerEntries afterwards)}
          pure (Right reference)
    -- A buffer made for a chunk that was not registered is released at once.
    abandon = maybe (pure ()) (\(buffer, _) → () <$ releaseBuffer builders buffer)

-- | The reference the registry issues next and the ledger with it taken.
nextReference ∷ Ledger → Maybe (ChunkRef, Ledger)
nextReference ledger = case ledgerFree ledger of
  index : rest →
    let generation = Map.findWithDefault 1 index (ledgerGenerations ledger)
     in Just (chunkRef index generation, ledger {ledgerFree = rest})
  []
    | ledgerNext ledger == maxBound → Nothing
    | otherwise →
        let index = ledgerNext ledger
         in Just (chunkRef index 1, ledger {ledgerNext = index + 1, ledgerGenerations = Map.insert index 1 (ledgerGenerations ledger)})

-- | Where a built chunk stands.
data ChunkStanding
  = -- | Its cutout instances' upload has not completed.
    ChunkUploading
  | -- | Ready to draw: the upload completed, or the chunk has no cutout
    -- instance and so no upload.
    ChunkReady
  | -- | The upload ended without completing: cancelled, or the device lost.
    ChunkFailed !UploadState
  deriving (Eq, Show)

-- | The standing of a chunk in the registry, 'Nothing' for one never built or
-- since released.
chunkStanding ∷ Retained → ChunkRef → IO (Maybe ChunkStanding)
chunkStanding retained reference = atomically (chunkStandingSTM retained reference)

-- | 'chunkStanding' as a transaction.
chunkStandingSTM ∷ Retained → ChunkRef → STM (Maybe ChunkStanding)
chunkStandingSTM (Retained ledger) reference = do
  held ← readTVar ledger
  case Map.lookup reference (ledgerEntries held) of
    Nothing → pure Nothing
    Just entry → case entryDevice entry of
      Nothing → pure (Just ChunkReady)
      Just (_, ticket) →
        Just . standing <$> readUploadTicket ticket
  where
    standing = \case
      UploadComplete → ChunkReady
      UploadQueued → ChunkUploading
      UploadUploading → ChunkUploading
      ended → ChunkFailed ended

-- | The chunks a snapshot may be validated against: every chunk the registry
-- holds, including one whose release was requested but has not yet been made,
-- since an adopted snapshot still shows it.
retainedChunks ∷ Retained → IO Chunks
retainedChunks (Retained ledger) = do
  held ← readTVarIO ledger
  pure (chunksFrom [(reference, entryChunk entry) | (reference, entry) ← Map.toList (ledgerEntries held)])

-- | What the registry holds at one instant, read in one transaction: the chunks a
-- snapshot may be validated against, and for each the release flag and the
-- standing. Everything publication checks is read from one such view, so a chunk
-- the owner's thread releases meanwhile can neither be resolved by one read and
-- missed by another.
data RetainedView = RetainedView
  { viewChunks ∷ !Chunks
  , viewReleased ∷ !(Map ChunkRef Bool)
    -- ^ Whether each held chunk has been marked released.
  , viewStandings ∷ !(Map ChunkRef ChunkStanding)
  }

-- | The registry as it stands, in one transaction.
retainedViewSTM ∷ Retained → STM RetainedView
retainedViewSTM (Retained ledger) = do
  held ← readTVar ledger
  standings ← traverse standingOf (ledgerEntries held)
  pure
    RetainedView
      { viewChunks = chunksFrom [(reference, entryChunk entry) | (reference, entry) ← Map.toList (ledgerEntries held)]
      , viewReleased = Map.map entryReleased (ledgerEntries held)
      , viewStandings = standings
      }
  where
    standingOf entry = case entryDevice entry of
      Nothing → pure ChunkReady
      Just (_, ticket) → standingFor <$> readUploadTicket ticket
    standingFor = \case
      UploadComplete → ChunkReady
      UploadQueued → ChunkUploading
      UploadUploading → ChunkUploading
      ended → ChunkFailed ended

-- | The references the registry holds.
liveChunks ∷ Retained → IO [ChunkRef]
liveChunks (Retained ledger) = Map.keys . ledgerEntries <$> readTVarIO ledger

-- | The device buffer of every chunk that has one, for a frame to draw from.
retainedBuffers ∷ Retained → IO (ChunkRef → Maybe Buffer)
retainedBuffers (Retained ledger) = do
  held ← readTVarIO ledger
  let buffers = Map.mapMaybe (fmap fst . entryDevice) (ledgerEntries held)
  pure (`Map.lookup` buffers)

-- | The device buffer of one chunk, if it has one.
chunkBufferOf ∷ Retained → ChunkRef → IO (Maybe Buffer)
chunkBufferOf retained reference = ($ reference) <$> retainedBuffers retained

-- | Mark a chunk released, at once, for publication's check. 'False' for one
-- never built here or already marked.
markChunkReleased ∷ Retained → ChunkRef → IO Bool
markChunkReleased retained reference = atomically (markChunkReleasedSTM retained reference)

-- | 'markChunkReleased' as a transaction, for a caller that commits the marker
-- together with its own state.
markChunkReleasedSTM ∷ Retained → ChunkRef → STM Bool
markChunkReleasedSTM (Retained ledger) reference = do
  held ← readTVar ledger
  case Map.lookup reference (ledgerEntries held) of
    Just entry | not (entryReleased entry) → True <$ writeTVar ledger held {ledgerEntries = Map.insert reference entry {entryReleased = True} (ledgerEntries held)}
    _ → pure False

-- | Whether the chunk has been marked released.
isChunkReleased ∷ Retained → ChunkRef → STM Bool
isChunkReleased (Retained ledger) reference =
  maybe False entryReleased . Map.lookup reference . ledgerEntries <$> readTVar ledger

-- | Release a chunk's buffer on the owner's thread and forget the chunk: its
-- index is free to reuse, under the next generation. The buffer's own destruction
-- waits for the batches that recorded it. A buffer the backend refuses to release
-- leaves the chunk as it was.
releaseChunkNow ∷ Builders q inst msgr phys dev cmd → Retained → ChunkRef → IO (Either Refusal ())
releaseChunkNow builders (Retained ledger) reference = do
  held ← readTVarIO ledger
  case Map.lookup reference (ledgerEntries held) >>= entryDevice of
    Nothing → forget
    Just (buffer, _) →
      releaseBuffer builders buffer >>= \case
        Left refusal → pure (Left refusal)
        Right () → forget
  where
    forget = do
      atomically $ do
        current ← readTVar ledger
        when (Map.member reference (ledgerEntries current)) $
          writeTVar ledger (retire current)
      pure (Right ())
    retire current =
      let index = chunkRefIndex reference
          next = chunkRefGeneration reference + 1
          generations = Map.insert index next (ledgerGenerations current)
       in -- A generation that would wrap retires its index for good.
          current
            { ledgerEntries = Map.delete reference (ledgerEntries current)
            , ledgerGenerations = generations
            , ledgerFree = if next == 0 then ledgerFree current else ledgerFree current <> [index]
            }
