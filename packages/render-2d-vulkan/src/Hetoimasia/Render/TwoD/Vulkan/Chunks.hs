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
-- 3. it reserves, in one transaction, a reference private until registration
--    and, when there are cutout bytes, one place in the uploads' queue and one
--    staging region for exactly that many bytes, in the decision the uploads make
--    for every caller ('admitRetainedChunk'). A chunk with no cutout instance,
--    which is every chunk of a world layer without depth and of a UI layer,
--    reserves no room and makes no buffer and no upload: a zero-byte buffer is
--    refused by the backend, and an ordered-path instance is written to the ring
--    each frame, never retained on the device;
-- 4. only then does it make a device-local vertex buffer of exactly that size,
--    spend the reserved room on the upload that fills it, and register the
--    description with the buffer and the upload's ticket under the reserved
--    reference ('spendChunkGrant').
--
-- Steps 1–2 are 'prepareRetainedChunk', pure; a caller that must take its own
-- capacity with the chunk's runs step 3 inside its own transaction and step 4
-- after it, and 'chunkRoom' reads step 3's decision without reserving.
--
-- A refusal before the buffer is made holds nothing and made nothing:
-- 'BuildUploadBackpressure' is the queue or the staging buffer full now, and
-- asking again later can succeed; 'BuildUploadRefused' is every other refusal,
-- none of which asking again changes, among them 'UploadOversized' (a chunk whose
-- cutout bytes cannot fit the staging buffer at all: build it as smaller chunks)
-- and a failed or closed session. After the buffer is made, a failure releases it
-- at one site, once, gives the grant back, and says what became of the buffer
-- ('BuildRefused'): a released buffer is destroyed only once the backend confirms
-- it, and a caller that charges the buffer's capacity keeps it charged until
-- then; a release that raised is a cleanup failure naming the buffer. A
-- synchronous exception after the buffer was made is answered as such a refusal
-- ('BuildRaised').
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
  , BuildRefused (..)
  , RefusedAllocation (..)
  , buildRetainedChunk
  , buildRetainedChunkWith
  , PreparedChunk
  , preparedChunk
  , preparedBytes
  , prepareRetainedChunk
  , ChunkGrant
  , chunkRoom
  , admitRetainedChunk
  , abandonChunkGrant
  , spendChunkGrant
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

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVar, newTVarIO, readTVar, readTVarIO, writeTVar)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeAsyncException, SomeException, displayException, fromException, mask, mask_, rethrowIO, throwIO, try, tryWithContext)
import Control.Monad (when)
import qualified Data.ByteString as ByteString
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Recording (Buffer, Refusal, releasedBufferOf)
import Hetoimasia.GPU.Vulkan.Native.Uploads (UploadGrant, UploadPressure, UploadRefusal (..), UploadState (..), UploadTicket, readUploadTicket)
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
import Hetoimasia.Render.TwoD.Vulkan.Builders (BufferUploadRefusal (..), BufferUploads (..), Builders (..))
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
  | -- | A synchronous exception after the buffer was made, with its text.
    BuildRaised !Text
  | -- | The grant was already spent or given back, or is another registry's.
    BuildGrantSpent
  | -- | The host's uploads are configured and not yet made: their startup can
    -- make them, so a later build can succeed.
    BuildUploadsNotReady
  | -- | The host has no uploads, or their startup failed: the cause.
    BuildUploadsUnavailable !Text
  deriving (Eq, Show)

-- | A refused build and what became of the buffer it made, if it made one.
data BuildRefused = BuildRefused
  { buildRefusal ∷ !BuildRefusal
  , buildAllocation ∷ !RefusedAllocation
  }
  deriving (Eq, Show)

-- | A refused build made no buffer, or made one and released it: the release's answer, and the buffer whose physical
-- destruction the backend confirms later (until then the buffer still occupies its capacity); or one whose release
-- raised, with the buffer and the cause: a cleanup failure, its capacity kept.
data RefusedAllocation
  = NoAllocation
  | AllocationReleased !Buffer !(Either Refusal ())
  | AllocationReleaseRaised !Buffer !Text
  deriving (Eq, Show)

-- | Build a chunk on the graphics owner's thread: prepare it, reserve its
-- reference and its upload's room, then make its buffer, spend the room on the
-- upload that fills it and register it. The instances are routed against the
-- registered marks the caller gives. A refusal before the buffer is made holds
-- and made nothing; one after says what became of the buffer.
buildRetainedChunk
  ∷ Builders q inst msgr phys dev cmd
  → Retained
  → CutoutMarks
  → ChunkKind
  → BoundsRequest
  → [Instance]
  → IO (Either BuildRefused ChunkRef)
buildRetainedChunk builders retained marks kind bounds =
  buildRetainedChunkWith builders retained marks kind bounds Map.empty

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
  → IO (Either BuildRefused ChunkRef)
buildRetainedChunkWith builders retained marks kind bounds records instances =
  case prepareRetainedChunk marks kind bounds records instances of
    Left refusal → pure (Left (BuildRefused refusal NoAllocation))
    Right prepared →
      mask_ $
        atomically (admitRetainedChunk (bufferUploads builders) retained prepared) >>= \case
          Left refusal → pure (Left (BuildRefused refusal NoAllocation))
          Right grant → spendChunkGrant builders retained grant (\_ → pure ())

-- | A chunk ready to be built: described, routed and bounded for one kind of
-- layer, and its cutout instances encoded — before anything is reserved or made.
data PreparedChunk = PreparedChunk
  { preparedChunk ∷ !Chunk
    -- ^ Its immutable description.
  , preparedEncoded ∷ !ByteString.ByteString
  }

-- | The exact bytes its vertex buffer and upload hold: zero for a chunk with no
-- cutout instance, which makes neither.
preparedBytes ∷ PreparedChunk → Natural
preparedBytes = fromIntegral . ByteString.length . preparedEncoded

-- | Prepare a chunk, refusing the instances, the records or the bounds that do
-- not validate, with every reason. Pure, and evaluated when its answer is: a
-- prepared chunk's description and encoded bytes are computed by then, so
-- admission reads only their size. Nothing is reserved.
prepareRetainedChunk
  ∷ CutoutMarks
  → ChunkKind
  → BoundsRequest
  → Map MaterialRef [MaterialRecord]
  → [Instance]
  → Either BuildRefusal PreparedChunk
prepareRetainedChunk marks kind bounds records instances =
  case buildChunkWith marks kind bounds records instances of
    Left refusals → Left (BuildInvalid refusals)
    Right described →
      let prepared = PreparedChunk described (encodeChunkCutouts described)
       in prepared `seq` Right prepared

-- | A prepared chunk's admission: a reference, private until the chunk is
-- registered under it, and for a chunk with bytes the upload's reserved room.
-- It belongs to the registry and the uploads that issued it, and moves once
-- from reserved to spending ('spendChunkGrant'), whose cleanup is the spend's
-- own, or from reserved to given back ('abandonChunkGrant').
data ChunkGrant = ChunkGrant
  { grantReference ∷ !ChunkRef
  , grantPrepared ∷ !PreparedChunk
  , grantUpload ∷ !(Maybe UploadGrant)
  , grantRegistry ∷ !(TVar Ledger)
    -- ^ The registry that reserved the reference.
  , grantUploads ∷ !BufferUploads
    -- ^ The uploads that reserved the room, which spend or free it.
  , grantStanding ∷ !(TVar GrantStanding)
  }

-- | Where a grant stands: reserved; being spent, its capacity the spend's to
-- account for; or done (registered, or given back).
data GrantStanding = GrantReserved | GrantSpending | GrantDone
  deriving (Eq, Show)

-- | Whether a chunk of this many bytes would be admitted now, read-only: the
-- decision 'admitRetainedChunk' makes, with the uploads' room observed through
-- this reading.
chunkRoom ∷ (Natural → STM (Either BufferUploadRefusal ())) → Retained → Natural → STM (Either BuildRefusal ())
chunkRoom room (Retained ledger) bytes = do
  held ← readTVar ledger
  case nextReference held of
    Nothing → pure (Left BuildReferencesExhausted)
    Just _
      | bytes == 0 → pure (Right ())
      | otherwise → either (Left . uploadRefusal) Right <$> room bytes

-- | Admit a prepared chunk in one transaction: its reference, and for a chunk
-- with bytes its upload's room, reserved in the decision every upload shares.
-- A refusal reserves nothing: 'BuildUploadBackpressure', 'BuildUploadsNotReady'
-- and 'BuildReferencesExhausted' can change, every other refusal (an oversized
-- chunk among them) cannot.
admitRetainedChunk ∷ BufferUploads → Retained → PreparedChunk → STM (Either BuildRefusal ChunkGrant)
admitRetainedChunk uploads (Retained ledger) prepared = do
  held ← readTVar ledger
  case nextReference held of
    Nothing → pure (Left BuildReferencesExhausted)
    Just (reference, afterwards) → do
      upload ←
        if preparedBytes prepared == 0
          then pure (Right Nothing)
          else fmap Just <$> reserveRoom uploads (preparedBytes prepared)
      case upload of
        Left refusal → pure (Left (uploadRefusal refusal))
        Right granted → do
          writeTVar ledger afterwards
          standing ← newTVar GrantReserved
          pure (Right (ChunkGrant reference prepared granted ledger uploads standing))

uploadRefusal ∷ BufferUploadRefusal → BuildRefusal
uploadRefusal = \case
  BufferUploadRefused (UploadBackpressure pressure) → BuildUploadBackpressure pressure
  BufferUploadRefused refusal → BuildUploadRefused refusal
  BufferUploadsNotReady → BuildUploadsNotReady
  BufferUploadsUnavailable cause → BuildUploadsUnavailable cause

-- | Give back a reserved grant, through the registry that issued it: its
-- reference is free again, and its upload's room, through the uploads that
-- reserved it. A grant being spent, spent or given back, or another registry's,
-- changes nothing.
abandonChunkGrant ∷ Retained → ChunkGrant → STM ()
abandonChunkGrant (Retained ledger) grant =
  when (grantRegistry grant == ledger) $
    readTVar (grantStanding grant) >>= \case
      GrantReserved → giveBack grant
      _ → pure ()

-- The grant's capacity returned: its reference to its registry's free list, its
-- upload's room to its uploads (a room the upload has spent is not freed by this).
giveBack ∷ ChunkGrant → STM ()
giveBack grant = do
  writeTVar (grantStanding grant) GrantDone
  mapM_ (abandonRoom (grantUploads grant)) (grantUpload grant)
  modifyTVar' (grantRegistry grant) (\held → held {ledgerFree = chunkRefIndex (grantReference grant) : ledgerFree held})

-- | Spend a grant on the graphics owner's thread: move it from reserved to
-- spending in one transaction (a grant not reserved, or another registry's, is
-- refused and changed in nothing), then make the chunk's buffer, spend the
-- reserved room on the upload that fills it and register the chunk under the
-- granted reference. Nothing competes for capacity again. Every exit before
-- registration gives the grant back. From the buffer's making on, the buffer is
-- released at one site, at most once, and a refusal says what became of it
-- ('RefusedAllocation'): a released buffer is destroyed only once the backend
-- confirms it, and its capacity stays occupied until then. An exception or a
-- cancellation releases it too, and hands the refusal it would have answered
-- (the exception as its cause) to @interrupted@ before it goes on, so the caller
-- keeps the buffer's identity and its release's outcome.
spendChunkGrant
  ∷ Builders q inst msgr phys dev cmd
  → Retained
  → ChunkGrant
  → (BuildRefused → IO ())
  → IO (Either BuildRefused ChunkRef)
spendChunkGrant builders (Retained ledger) grant interrupted = mask $ \restore → do
  taken ← atomically $
    if grantRegistry grant /= ledger
      then pure False
      else
        readTVar (grantStanding grant) >>= \case
          GrantReserved → True <$ writeTVar (grantStanding grant) GrantSpending
          _ → pure False
  if not taken
    then pure (Left (BuildRefused BuildGrantSpent NoAllocation))
    else do
      made ← newIORef NotMade
      done ← newIORef False
      let releaseOnce buffer = do
            already ← atomicModifyIORef' done (\d → (True, d))
            if already then pure Nothing else Just <$> trySync (releaseBuffer builders buffer)
          allocationOf buffer released = case released of
            Just (Right outcome) → AllocationReleased buffer outcome
            Just (Left raised) → AllocationReleaseRaised buffer (raisedText raised)
            Nothing → AllocationReleased buffer (Right ())
          -- every exit that does not register: the buffer released once, the grant given back
          failed refusal = do
            allocation ← readIORef made >>= \case
              NotMade → pure NoAllocation
              MadeAndReleased buffer → pure (AllocationReleased buffer (Right ()))
              Made buffer → allocationOf buffer <$> releaseOnce buffer
            atomically (spendingGiveBack grant)
            pure (BuildRefused refusal allocation)
      outcome ← tryWithContext @SomeException (restore (attempt made))
      case outcome of
        Right (Right reference) → pure (Right reference)
        Right (Left refusal) → Left <$> failed refusal
        Left (ExceptionWithContext context raised) → do
          buffer ← readIORef made
          lost ← failed (BuildRaised (Text.pack (displayException raised)))
          case (fromException raised ∷ Maybe SomeAsyncException, buffer) of
            -- a synchronous exception once a buffer was made is answered as such a refusal
            (Nothing, Made _) → pure (Left lost)
            -- a cancellation, or an exception before any buffer: the caller is handed the refusal, and it goes on
            _ → interrupted lost >> rethrowIO (ExceptionWithContext context raised)
  where
    uploads = grantUploads grant
    prepared = grantPrepared grant
    bytes = preparedEncoded prepared
    -- the steps that can be refused; the buffer, once made, is noted for the one release site
    attempt made = case grantUpload grant of
      Nothing → atomically (register Nothing)
      Just upload →
        madeOrRaised (buildVertexBuffer builders (preparedBytes prepared)) >>= \case
          -- the buffer's construction raised after it made and released the buffer: no handle, but its identity, and
          -- the release already made
          Left (buffer, raised) → Left (BuildRaised raised) <$ writeIORef made (MadeAndReleased buffer)
          Right (Left refusal) → pure (Left (BuildBufferRefused refusal))
          Right (Right buffer) → do
            writeIORef made (Made buffer)
            uploadGranted uploads upload buffer bytes >>= \case
              Left refusal → pure (Left (uploadRefusal refusal))
              Right ticket → atomically (register (Just (buffer, ticket)))
    register held = do
      writeTVar (grantStanding grant) GrantDone
      modifyTVar' ledger (\current → current {ledgerEntries = Map.insert (grantReference grant) (Entry (preparedChunk prepared) held False) (ledgerEntries current)})
      pure (Right (grantReference grant))
    raisedText raised = Text.pack (displayException (raised ∷ SomeException))
    -- a construction that raised naming the buffer it made and released; any other exception goes on (with no buffer
    -- named, nothing says whether one was made)
    madeOrRaised action =
      tryWithContext action >>= \case
        Left (ExceptionWithContext context raised)
          | Nothing ← fromException raised ∷ Maybe SomeAsyncException
          , Just buffer ← releasedBufferOf context →
              pure (Left (buffer, Text.pack (displayException raised)))
        Left failure → rethrowIO failure
        Right value → pure (Right value)
    -- a synchronous exception as a value; an asynchronous one (a cancellation) goes on
    trySync action =
      try action >>= \case
        Left raised | Just (_ ∷ SomeAsyncException) ← fromException raised → throwIO raised
        other → pure other

-- What a spend made of its buffer, for its one release site.
data MadeBuffer = NotMade | Made !Buffer | MadeAndReleased !Buffer

-- A spending grant given back by its spend: once.
spendingGiveBack ∷ ChunkGrant → STM ()
spendingGiveBack grant =
  readTVar (grantStanding grant) >>= \case
    GrantSpending → giveBack grant
    _ → pure ()

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
