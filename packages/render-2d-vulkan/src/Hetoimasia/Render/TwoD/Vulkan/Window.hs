-- | The per-window host adapter (R2D-8): publishing 2D snapshots to windows,
-- holding what an adopted snapshot references, releasing textures behind the
-- window host's barrier, and rendering a window's adopted snapshot with the
-- recorder.
--
-- The adapter is written over a 'Host' of plain functions, never over the
-- window integration's own types, for the same reason the recorder is written
-- over 'Builders': this package depends on the native backend alone, so the
-- integration's native suite — which lives in the integration's package — can
-- exercise it without a package cycle. The window integration's
-- @publishVulkanWindowScene@, @requestVulkanRelease@ and scene lifecycle are
-- what the host record is filled from, by the sample and by the native case;
-- the adapter is generic over the window's identity.
--
-- = Publishing (D-18, D-28)
--
-- 'publish2DSnapshot' validates a candidate snapshot and publishes it for one
-- window. It is refused: with validation's reasons when it is invalid; naming
-- the pass when it holds an offscreen pass, since windowed snapshots hold none
-- until R2D-13 issues target references; when it holds no window pass — an
-- empty snapshot is refused, and removing textures publishes a window pass
-- with no layers, while validation refuses a second one; naming the layer when
-- it holds a depth-enabled world layer and the session's depth format is not
-- @D32_SFLOAT@ (D-23; a snapshot with none is unaffected on any device);
-- naming the texture when it references one whose release has been requested,
-- and the chunk likewise; and naming the chunk when it lists one whose upload
-- ended without completing (R2D-10). Chunks are resolved against the registry
-- ("Hetoimasia.Render.TwoD.Vulkan.Chunks"): a reference it does not hold, stale
-- or never issued, is validation's refusal naming the layer and the chunk. A
-- chunk whose upload is still under way is not refused: publication never waits
-- (D-28), and a frame that would draw it is skipped instead.
--
-- = Holds (D-28)
--
-- When the owner adopts a revision of a window, 'adapterAdopted' records a
-- hold on every texture the revision's snapshot references, once for each
-- texture however often it is referenced, and on every chunk it lists, whether
-- or not a view culls the chunk: the textures a chunk's instances name are
-- among the snapshot's references and held with it. When the revision is
-- released, 'adapterReleased' drops its holds. A texture or a chunk is held
-- while any adopted revision of any window holds it, so two windows sharing one
-- hold it twice, a window's closure drops its hold when the host reports its
-- revisions released, and a superseded revision's hold ends only when its last
-- recording is over: a superseding revision alone never lets a chunk's buffer
-- go.
--
-- = Releasing (D-28, D-31)
--
-- 'release2DTexture' and 'release2DChunk' mark the object released at once, for
-- publication's check, in one transaction with its entry in the pending set,
-- and ask the host to run a release after the revisions the window host must
-- have adopted first, naming the windows it holds at the request. That action
-- releases the object in the table, or the chunk's buffer, only if no adopted
-- revision still holds it; otherwise it keeps rendering wherever an adopted
-- snapshot shows it, the barrier counts as met, and the release is made when
-- the last holding revision's release is reported ('adapterReleased'): by a
-- further action that waits for nothing, so a window that appeared after the
-- request delays nothing. If the host's queue refuses that action for lack of
-- room, the object stays eligible and 'retryReleases', which the hooks and the
-- end of every release action call, queues it again; nothing blocks.
-- Publication and release are serialized, so a snapshot accepted before the
-- marker is published before the request captures its barrier and is adopted,
-- with its holds, before the release can run; one offered after the marker is
-- refused. Rebuilding a chunk is building a new one, publishing a snapshot that
-- lists it and releasing the old.
--
-- = Rendering
--
-- 'renderWindowFrame' records a window's adopted scene into the frame's image:
-- the window pass, with 'TargetMetrics' built from the frame's own framebuffer
-- extent and the window's latest logical extent and content scale (D-29). A
-- frame whose request carries neither is skipped, as a refusal, through the
-- host's existing backoff; nothing is invented. The snapshot is planned with
-- the registered handles' marks (R2D-9), and a host that enabled windowed depth
-- supplies the frame's depth image ('frameDepthImage'). A scene that lists a
-- chunk whose upload has not completed is not recorded: the frame is skipped
-- through the same backoff, with its demand kept, and nothing of an incomplete
-- chunk is drawn (D-28); 'pendingChunkUploads' names the chunks it waits for. A
-- chunk whose upload ended without completing can never be drawn, and no retry
-- changes that, so the frame is recorded without it ('failedChunkUploads' names
-- it) rather than refused: the host retries every refused frame.
--
-- = State
--
-- An 'Adapter' owns the holds, the textures and chunks whose release is pending,
-- and the lock that serializes publication with release; it is made over the
-- texture registry, the chunk registry and the renderer, whose session depth
-- format publication checks. The holds and the pending set are written on the
-- graphics owner's thread by the lifecycle's hooks and by the release action,
-- and read from any; publication and release run on any application thread,
-- behind the lock.
module Hetoimasia.Render.TwoD.Vulkan.Window
  ( -- * The scene a window holds
    Scene2D (..)
  , sceneOf
  , blankScene
    -- * The host's side
  , Host (..)
  , HostPublication (..)
  , ReleaseBody
    -- * The adapter
  , Adapter
  , newAdapter
  , adapterTextures
  , adapterRetained
    -- * Publishing and releasing
  , PublishRefusal (..)
  , publish2DSnapshot
  , ReleaseRefusal (..)
  , release2DTexture
  , release2DChunk
    -- * Adoption and release of revisions
  , adapterAdopted
  , adapterReleased
  , retryReleases
  , textureHolds
  , chunkHolds
  , pendingReleases
  , pendingChunkReleases
    -- * Rendering
  , FrameInfo (..)
  , pendingChunkUploads
  , failedChunkUploads
  , renderWindowFrame
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (mask, onException)
import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO)
import Control.DeepSeq (NFData (rnf))
import Control.Monad (forM_)
import Data.Kind (Type)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Recording (Image, ImageFormat (..), Recorder, Refusal (..))
import Hetoimasia.GPU.Vulkan.Native.Uploads (UploadState)
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.TwoD.Chunk (ChunkRef, chunkTextures)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..), validMetrics)
import qualified Hetoimasia.Render.TwoD.Snapshot as Snapshot
import Hetoimasia.Render.TwoD.Snapshot
  ( ClearColour (..)
  , Instance (..)
  , Pass (..)
  , Snapshot (..)
  , Target (..)
  , layerInstances
  )
import Hetoimasia.Render.TwoD.Validation (Location, ValidSnapshot, validLayerChunks, validLayers, validSnapshot, validateSnapshot, validateSnapshotWith)
import qualified Hetoimasia.Render.TwoD.Validation as Validation
import Hetoimasia.Render.TwoD.Vulkan (Renderer, prepareSnapshot, rendererDepthFormat)
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders)
import Hetoimasia.Render.TwoD.Vulkan.Frame (Attachment (..), DepthBinding (..), FrameInput (..), FrameRefusal (..), worldDepthShortfall)
import Hetoimasia.Render.TwoD.Vulkan.Chunks
  ( ChunkStanding (..)
  , Retained
  , RetainedView (..)
  , chunkStandingSTM
  , markChunkReleasedSTM
  , releaseChunkNow
  , retainedBuffers
  , retainedViewSTM
  )
import Hetoimasia.Render.TwoD.Vulkan.Textures (Textures, isReleased, markReleasedSTM, registeredMarks, releaseTextureNow)
import Numeric.Natural (Natural)

-- | What a window's published revision holds: the validated snapshot, which
-- carries the chunks its layers list, the textures it references, and the
-- chunks.
data Scene2D = Scene2D
  { sceneSnapshot ∷ !ValidSnapshot
  , sceneReferences ∷ !(Set Api.TextureHandle)
  -- ^ Every texture any instance names, dynamic or in a chunk, in any layer of
  -- any view, whether or not it is visible.
  , sceneChunks ∷ !(Set ChunkRef)
  -- ^ Every chunk any layer lists, whether or not a view culls it.
  }

instance NFData Scene2D where
  rnf scene = Set.size (sceneReferences scene) `seq` Set.size (sceneChunks scene) `seq` sceneSnapshot scene `seq` ()

-- | The scene a validated snapshot makes: every texture any of its instances
-- names, and any instance of a chunk it lists, in any layer of any view, whether
-- or not it is visible, and every chunk it lists.
sceneOf ∷ ValidSnapshot → Scene2D
sceneOf valid =
  Scene2D
    valid
    ( Set.fromList
        [ instanceTexture candidate
        | pass ← snapshotPasses (validSnapshot valid)
        , view ← passViews pass
        , layer ← viewLayers view
        , candidate ← layerInstances layer
        ]
        <> Set.unions [chunkTextures chunk | held ← validLayers valid, (_, chunk) ← validLayerChunks held]
    )
    (Set.fromList [reference | held ← validLayers valid, (reference, _) ← validLayerChunks held])
  where
    snapshotPasses = Snapshot.snapshotPasses
    passViews = Snapshot.passViews
    viewLayers = Snapshot.viewLayers

-- | The scene a window holds before any publication, revision 0: one window
-- pass cleared to opaque black, referencing nothing.
blankScene ∷ Scene2D
blankScene = case validateSnapshot (Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) []]) of
  Right valid → sceneOf valid
  Left refused → error ("the blank scene was refused: " <> show refused)

-- | What the window host answered a publication.
data HostPublication
  = -- | Accepted, at this revision of the window.
    HostPublished !Natural
  | -- | The host holds no such window.
    HostWindowUnknown
  | -- | The host's publications have ended with its exit.
    HostClosed
  | -- | The host carries one scene for every window, not one for each.
    HostSharedScenes
  deriving (Eq, Show)

-- | A release the host runs on the graphics owner's thread, once its barrier is
-- met, with the builders of the construction it lends.
type ReleaseBody = ∀ (q ∷ Type) (inst ∷ Type) (msgr ∷ Type) (phys ∷ Type) (dev ∷ Type) (cmd ∷ Type). Builders q inst msgr phys dev cmd → IO (Either Refusal ())

-- | What the adapter needs of the window host, as plain functions. Filled from
-- the window integration's publication and release-request operations.
data Host window = Host
  { hostPublish ∷ window → Scene2D → IO HostPublication
    -- ^ Publish the window's scene; revisions rise for each accepted one.
  , hostRequestRelease ∷ (ReleaseBody → IO (Either Text ()))
    -- ^ Queue an owner-thread action that waits for the revisions the host
    -- must have adopted first, naming every window the host holds at the
    -- request and no later one; 'Left' says why it was refused.
  , hostRunOnOwner ∷ (ReleaseBody → IO (Either Text ()))
    -- ^ Queue an owner-thread action that waits for nothing. It is admitted
    -- and bounded as the request is, and never waits for room.
  }

-- | An object a published revision holds and an application releases: a texture
-- or a retained chunk.
data Held
  = HeldTexture !Api.TextureHandle
  | HeldChunk !ChunkRef
  deriving (Eq, Ord, Show)

-- | The holds of a scene: its textures, and its chunks.
heldBy ∷ Scene2D → Set Held
heldBy scene = Set.map HeldTexture (sceneReferences scene) <> Set.map HeldChunk (sceneChunks scene)

-- | Where a pending release stands.
data Stage
  = -- | The host's request, which waits for the revisions named when it was
    -- made, is queued, or has not been admitted.
    AwaitingBarrier
  | -- | That request has run — every window it named had adopted what it
    -- waited for — and an adopted revision still held the object. What
    -- remains is the holds: no further barrier is asked, so a window that
    -- appeared since delays nothing.
    BarrierMet
  deriving (Eq, Show)

-- | A window host's adapter: its holds, its pending releases and the lock that
-- serializes publication with release.
data Adapter window = Adapter
  { adapterHost ∷ !(Host window)
  , adapterTextures ∷ !Textures
  , adapterRetained ∷ !Retained
    -- ^ The retained chunks scenes list.
  , adapterRenderer ∷ !Renderer
    -- ^ The renderer the window's frames record with, whose session depth
    -- format publication checks a snapshot's depth-enabled world layers against.
  , adapterLock ∷ !(MVar ())
  , adapterHolds ∷ !(TVar (Map (window, Natural) (Set Held)))
  , adapterPending ∷ !(TVar (Map Held Stage))
  , adapterQueued ∷ !(TVar (Set Held))
    -- ^ The objects whose release action, after the barrier was met, is queued
    -- in the host.
  }

-- | An adapter over the host, the texture and chunk registries, and the renderer
-- its frames record with. The renderer's session depth format is what
-- publication requires of a snapshot holding a depth-enabled world layer (D-23).
newAdapter ∷ Host window → Textures → Retained → Renderer → IO (Adapter window)
newAdapter host textures retained renderer = Adapter host textures retained renderer <$> newMVar () <*> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newTVarIO Set.empty

-- | Why a snapshot was not published.
data PublishRefusal
  = -- | Validation's reasons, each naming where.
    SnapshotInvalid !(NonEmpty Validation.Refusal)
  | -- | The pass at this index is offscreen: a windowed snapshot holds none
    -- until offscreen targets are issued (R2D-13).
    OffscreenPassHeld !Int
  | -- | The snapshot has no window pass; an empty one is refused.
    NoWindowPass
  | -- | The snapshot holds a depth-enabled world layer at this location and the
    -- session's depth format is not @D32_SFLOAT@ (D-23): the session's format,
    -- 'Nothing' when it offers none. A layer is never degraded to a
    -- lower-precision depth.
    WorldDepthRefused !Location !(Maybe ImageFormat)
  | -- | The snapshot references this texture, whose release was requested.
    TextureReleasedInSnapshot !Api.TextureHandle
  | -- | The snapshot lists this chunk, whose release was requested.
    ChunkReleasedInSnapshot !ChunkRef
  | -- | The snapshot lists this chunk, whose cutout instances' upload ended
    -- without completing: how it ended.
    ChunkUploadFailedInSnapshot !ChunkRef !UploadState
  | -- | The host holds no such window.
    PublishWindowUnknown
  | -- | The host's publications have ended.
    PublishHostClosed
  | -- | The host carries one shared scene, not a scene for each window.
    PublishHostShared
  deriving (Eq, Show)

-- | Validate a candidate against the chunks the registry holds and publish it for
-- the window, answering its revision. Admission is serialized with the releases.
publish2DSnapshot ∷ Adapter window → window → Snapshot → IO (Either PublishRefusal Natural)
publish2DSnapshot adapter window candidate = withMVar (adapterLock adapter) $ \_ → do
  -- One transaction reads what the registry holds, each chunk's release flag and
  -- its standing, so the checks below are made against the chunks the snapshot
  -- was resolved against: a release the owner's thread runs meanwhile removes a
  -- chunk from the view it can no longer change.
  view ← atomically (retainedViewSTM (adapterRetained adapter))
  case validateSnapshotWith (viewChunks view) candidate of
    Left reasons → pure (Left (SnapshotInvalid reasons))
    Right valid → case ([index | (index, Pass {passTarget = OffscreenTarget _}) ← zip [0 ..] (Snapshot.snapshotPasses candidate)], length [() | Pass {passTarget = WindowTarget} ← Snapshot.snapshotPasses candidate]) of
      (index : _, _) → pure (Left (OffscreenPassHeld index))
      ([], 0) → pure (Left NoWindowPass)
      -- Validation has refused a second window pass already.
      ([], _) → case worldDepthShortfall sessionDepth valid of
        Just (location, held) → pure (Left (WorldDepthRefused location held))
        Nothing → do
          let scene = sceneOf valid
              chunkRefs = Set.toList (sceneChunks scene)
              releasedChunks = [reference | reference ← chunkRefs, Map.findWithDefault True reference (viewReleased view)]
              failedChunks = [(reference, ended) | reference ← chunkRefs, Just (ChunkFailed ended) ← [Map.lookup reference (viewStandings view)]]
          released ← atomically (filterReleased (Set.toList (sceneReferences scene)))
          case (released, releasedChunks, failedChunks) of
            (handle : _, _, _) → pure (Left (TextureReleasedInSnapshot handle))
            ([], reference : _, _) → pure (Left (ChunkReleasedInSnapshot reference))
            ([], [], (reference, ended) : _) → pure (Left (ChunkUploadFailedInSnapshot reference ended))
            ([], [], []) →
              hostPublish (adapterHost adapter) window scene >>= \case
                HostPublished revision → pure (Right revision)
                HostWindowUnknown → pure (Left PublishWindowUnknown)
                HostClosed → pure (Left PublishHostClosed)
                HostSharedScenes → pure (Left PublishHostShared)
  where
    sessionDepth = rendererDepthFormat (adapterRenderer adapter)
    filterReleased handles = fmap concat (traverse (\handle → (\flagged → [handle | flagged]) <$> isReleased (adapterTextures adapter) handle) handles)

-- | Why a release was not requested.
data ReleaseRefusal
  = -- | The texture was never registered, or its release has already run.
    ReleaseUnknown !Api.TextureHandle
  | -- | The chunk was never built, or its release has already run.
    ReleaseChunkUnknown !ChunkRef
  | -- | The window host refused the request, saying why.
    ReleaseRequestRefused !Text
  deriving (Eq, Show)

-- | Mark the texture released and ask the host to release it behind its
-- barrier, once no adopted revision holds it. The marker and the texture's
-- entry in the pending set are one transaction, so a cancellation before the
-- host is asked leaves a texture that asking again recovers. A request the host
-- refused leaves the texture marked and pending, and asking again for the same
-- handle repeats it; nothing else is asked twice, and a handle whose release
-- has run, or that was never registered, is refused as unknown.
release2DTexture ∷ Adapter window → Api.TextureHandle → IO (Either ReleaseRefusal ())
release2DTexture adapter handle = releaseHeld adapter (HeldTexture handle) (markReleasedSTM (adapterTextures adapter) handle) (ReleaseUnknown handle)

-- | The same for a retained chunk (D-31): mark it released, so a snapshot that
-- lists it is refused, and ask the host to release its buffer behind its barrier,
-- once no adopted revision holds it. Rebuilding a chunk is building a new one
-- and releasing the old.
release2DChunk ∷ Adapter window → ChunkRef → IO (Either ReleaseRefusal ())
release2DChunk adapter reference = releaseHeld adapter (HeldChunk reference) (markChunkReleasedSTM (adapterRetained adapter) reference) (ReleaseChunkUnknown reference)

releaseHeld ∷ Adapter window → Held → STM Bool → ReleaseRefusal → IO (Either ReleaseRefusal ())
releaseHeld adapter held mark unknown = withMVar (adapterLock adapter) $ \_ → do
  next ← atomically $ do
    marked ← mark
    stage ← Map.lookup held <$> readTVar (adapterPending adapter)
    case stage of
      Just BarrierMet → pure (Just BarrierMet)
      Just AwaitingBarrier → pure (Just AwaitingBarrier)
      Nothing
        | marked → Just AwaitingBarrier <$ modifyTVar' (adapterPending adapter) (Map.insert held AwaitingBarrier)
        | otherwise → pure Nothing
  case next of
    Nothing → pure (Left unknown)
    Just AwaitingBarrier → either (Left . ReleaseRequestRefused) Right <$> hostRequestRelease (adapterHost adapter) (releaseBody adapter held)
    Just BarrierMet → do
      -- The barrier was met already: only the holds remain.
      answer ← followUp adapter held
      pure (either (Left . ReleaseRequestRefused) Right answer)

-- | Queue the release after the barrier was met, once, with no barrier of its
-- own. The reservation and the admission are protected together: a refusal,
-- or a cancellation before the host admitted the action, gives the reservation
-- back, so the next 'retryReleases' queues it. (A cancellation after the host
-- admitted it leaves a second action possible, which the release's own recheck
-- makes harmless.)
followUp ∷ Adapter window → Held → IO (Either Text ())
followUp adapter held = mask $ \restore → do
  fresh ← atomically $ do
    queued ← readTVar (adapterQueued adapter)
    if Set.member held queued
      then pure False
      else True <$ modifyTVar' (adapterQueued adapter) (Set.insert held)
  if not fresh
    then pure (Right ())
    else do
      answer ← restore (hostRunOnOwner (adapterHost adapter) (releaseBody adapter held)) `onException` unreserve
      case answer of
        Left _ → unreserve
        Right () → pure ()
      pure answer
  where
    unreserve = atomically (modifyTVar' (adapterQueued adapter) (Set.delete held))

-- | Queue the release of every pending object whose barrier was met and that
-- no adopted revision holds, and whose release action is not already queued.
-- It never blocks: a refusal (the host's queue full) leaves the object for
-- the next call. The lifecycle hooks and the end of every release action call
-- it, and an application whose host may refuse for lack of room calls it from
-- its own loop.
retryReleases ∷ Adapter window → IO ()
retryReleases adapter = do
  ready ← atomically $ do
    pending ← readTVar (adapterPending adapter)
    held ← Set.unions . Map.elems <$> readTVar (adapterHolds adapter)
    queued ← readTVar (adapterQueued adapter)
    pure [object | (object, BarrierMet) ← Map.toList pending, not (Set.member object held), not (Set.member object queued)]
  forM_ ready (followUp adapter)

-- | The release as the host runs it: only an object still pending and held by
-- no adopted revision is released, a texture in the table and a chunk's buffer
-- with its registration. One an adopted revision still holds is marked as having
-- met its barrier, and 'adapterReleased' asks for the rest when the last hold
-- ends.
releaseBody ∷ Adapter window → Held → ReleaseBody
releaseBody adapter object builders = do
  due ← atomically $ do
    pending ← readTVar (adapterPending adapter)
    held ← Set.unions . Map.elems <$> readTVar (adapterHolds adapter)
    modifyTVar' (adapterQueued adapter) (Set.delete object)
    case Map.lookup object pending of
      Nothing → pure False
      Just _
        | Set.member object held → False <$ modifyTVar' (adapterPending adapter) (Map.insert object BarrierMet)
        | otherwise → True <$ modifyTVar' (adapterPending adapter) (Map.delete object)
  answer ←
    if due
      then case object of
        HeldTexture handle → releaseTextureNow builders (adapterTextures adapter) handle
        HeldChunk reference → releaseChunkNow builders (adapterRetained adapter) reference
      else pure (Right ())
  -- Room was just made, and what this action did may have left others due.
  retryReleases adapter
  pure answer

-- | The owner adopted this revision of the window with this scene: hold every
-- texture and chunk it references until the revision is released.
adapterAdopted ∷ Ord window ⇒ Adapter window → window → Natural → Scene2D → IO ()
adapterAdopted adapter window revision scene = do
  atomically (modifyTVar' (adapterHolds adapter) (Map.insert (window, revision) (heldBy scene)))
  retryReleases adapter

-- | This revision of the window has been released: drop its holds, and queue
-- the release of each object that was waiting only for them.
adapterReleased ∷ Ord window ⇒ Adapter window → window → Natural → IO ()
adapterReleased adapter window revision = do
  atomically (modifyTVar' (adapterHolds adapter) (Map.delete (window, revision)))
  retryReleases adapter

-- | How many adopted revisions hold the texture.
textureHolds ∷ Adapter window → Api.TextureHandle → IO Int
textureHolds adapter handle = holdsOf adapter (HeldTexture handle)

-- | How many adopted revisions hold the chunk.
chunkHolds ∷ Adapter window → ChunkRef → IO Int
chunkHolds adapter reference = holdsOf adapter (HeldChunk reference)

holdsOf ∷ Adapter window → Held → IO Int
holdsOf adapter object = length . filter (Set.member object) . Map.elems <$> readTVarIO (adapterHolds adapter)

-- | The textures whose release was requested and is not yet made in the table.
pendingReleases ∷ Adapter window → IO (Set Api.TextureHandle)
pendingReleases adapter = Set.fromList . (\pending → [handle | HeldTexture handle ← Map.keys pending]) <$> readTVarIO (adapterPending adapter)

-- | The chunks whose release was requested and is not yet made.
pendingChunkReleases ∷ Adapter window → IO (Set ChunkRef)
pendingChunkReleases adapter = Set.fromList . (\pending → [reference | HeldChunk reference ← Map.keys pending]) <$> readTVarIO (adapterPending adapter)

-- | What a frame's request says of its image and its window, in the terms
-- the window integration's request names them.
data FrameInfo = FrameInfo
  { frameExtent ∷ !(Word32, Word32)
    -- ^ The frame image's extent: the framebuffer extent the views map to.
  , frameFormat ∷ !Word32
    -- ^ The image's colour format, a @VkFormat@ code.
  , frameLogical ∷ !(Maybe (Word32, Word32))
    -- ^ The window's logical extent, if the platform has reported one.
  , frameScale ∷ !(Maybe (Float, Float))
    -- ^ The window's content scale, per axis, if it has reported one.
  , frameDepthImage ∷ !(Maybe Image)
    -- ^ The frame's generation depth image, which a host that enabled windowed
    -- depth is given with the request. A pass holding a depth-enabled world
    -- layer is refused, naming the layer, without it.
  }
  deriving (Eq, Show)

-- | The chunks of a scene whose cutout instances' upload has not completed, in
-- the order the scene's chunk set lists them. A frame that draws the scene waits
-- for them: it is skipped and its demand kept (D-28).
pendingChunkUploads ∷ Adapter window → Scene2D → IO [ChunkRef]
pendingChunkUploads adapter scene =
  atomically $ do
    states ← traverse (\reference → (,) reference <$> chunkStandingSTM (adapterRetained adapter) reference) (Set.toList (sceneChunks scene))
    pure [reference | (reference, Just ChunkUploading) ← states]

-- | Record a window's adopted scene into the frame's image: the window pass,
-- mapped under metrics built from the frame's extent and the window's own
-- observation. Refused, skipping the frame through the host's backoff, when
-- the request carries no logical extent or no content scale, when they make no
-- valid metrics, when the scene lists a chunk whose upload has not completed, and
-- as 'prepareSnapshot' and the recording refuse. A chunk whose upload failed is
-- left out of the frame.
renderWindowFrame
  ∷ Adapter window
  → Builders q inst msgr phys dev cmd
  → FrameInfo
  → Scene2D
  → Recorder q inst msgr phys dev cmd
  → IO (Either Refusal ())
renderWindowFrame adapter builders info scene recorder = case (frameLogical info, frameScale info) of
  (Nothing, _) → pure (Left (RefusedIllegal "the frame names no logical extent for its window, so no view can be mapped"))
  (_, Nothing) → pure (Left (RefusedIllegal "the frame names no content scale for its window, so no view can be mapped"))
  (Just (logicalWidth, logicalHeight), Just (scaleX, scaleY)) →
    let (width, height) = frameExtent info
        metrics = TargetMetrics (PixelExtent (fromIntegral logicalWidth) (fromIntegral logicalHeight)) (PixelExtent (fromIntegral width) (fromIntegral height)) scaleX scaleY
     in if not (validMetrics metrics)
          then pure (Left (RefusedIllegal ("the window's metrics are not usable: " <> Text.pack (show metrics))))
          else
            chunkOutcome adapter scene >>= \case
              Left refusal → pure (Left refusal)
              Right omitted → do
                marks ← registeredMarks (adapterTextures adapter)
                buffers ← retainedBuffers (adapterRetained adapter)
                prepareSnapshot
                  builders
                  (adapterRenderer adapter)
                  FrameInput
                    { frameSnapshot = sceneSnapshot scene
                    , frameMarks = marks
                    , frameTarget = const Nothing
                    , frameWindow = Just (Attachment (frameFormat info) width height metrics)
                    , frameWindowDepth = (`DepthBinding` Depth32Float) <$> frameDepthImage info
                    , frameChunks = buffers
                    , frameOmitted = omitted
                    }
                  >>= \case
                    Left refusal → pure (Left (refused refusal))
                    Right recording → either (Left . refused) Right <$> recording recorder
  where
    refused = \case
      RefusedByBackend refusal → refusal
      other → RefusedIllegal (Text.pack (show other))

-- | What the scene's chunks make of recording it now: a refusal for an upload still
-- under way, which is pressure — the frame is skipped and retried — or for a chunk
-- the registry no longer holds; otherwise the chunks the frame leaves out. A chunk
-- whose upload ended without completing can never be drawn, and refusing the frame
-- for it would be retried at the host's backoff for ever, so the frame is recorded
-- without it, as if every view skipped it ('layerCulled' names it), and
-- 'failedChunkUploads' names it for whoever must publish without it.
chunkOutcome ∷ Adapter window → Scene2D → IO (Either Refusal (Set ChunkRef))
chunkOutcome adapter scene = do
  states ← atomically (traverse (\reference → (,) reference <$> chunkStandingSTM (adapterRetained adapter) reference) (Set.toList (sceneChunks scene)))
  pure $ case ([reference | (reference, Just ChunkUploading) ← states], [reference | (reference, Just (ChunkFailed _)) ← states], [reference | (reference, Nothing) ← states]) of
    (_, _, reference : _) → Left (RefusedIllegal ("a retained chunk the scene lists is no longer held: " <> Text.pack (show reference)))
    (reference : _, _, _) → Left (RefusedIllegal ("a retained chunk's upload has not completed, so the frame waits: " <> Text.pack (show reference)))
    ([], failed, []) → Right (Set.fromList failed)

-- | The chunks of a scene whose cutout instances' upload ended without completing,
-- and how it ended. A frame of the scene is recorded without them (see
-- 'renderWindowFrame'); no retry can draw them, so the application publishes a
-- snapshot that lists a rebuilt chunk instead, and publication refuses one that
-- lists these ('ChunkUploadFailedInSnapshot').
failedChunkUploads ∷ Adapter window → Scene2D → IO [(ChunkRef, UploadState)]
failedChunkUploads adapter scene =
  atomically $ do
    states ← traverse (\reference → (,) reference <$> chunkStandingSTM (adapterRetained adapter) reference) (Set.toList (sceneChunks scene))
    pure [(reference, ended) | (reference, Just (ChunkFailed ended)) ← states]
