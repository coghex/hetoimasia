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
-- with no layers, while validation refuses a second one; and naming the
-- texture when it references one whose release has been requested.
--
-- = Holds (D-28)
--
-- When the owner adopts a revision of a window, 'adapterAdopted' records a
-- hold on every texture the revision's snapshot references, once for each
-- texture however often it is referenced; when the revision is released,
-- 'adapterReleased' drops it. A texture is held while any adopted revision of
-- any window holds it, so two windows sharing one hold it twice, a window's
-- closure drops its hold when the host reports its revisions released, and a
-- superseded revision's hold ends only when its last recording is over.
--
-- = Releasing (D-28)
--
-- 'release2DTexture' marks the texture released at once, for publication's
-- check, and asks the host to run a release after the revisions the window
-- host must have adopted first. That action releases the texture in the table
-- only if no adopted revision still holds it; otherwise the texture keeps
-- rendering wherever an adopted snapshot shows it, and the release is made
-- when the last holding revision's release is reported ('adapterReleased'
-- asks again). Publication and release are serialized, so a snapshot accepted
-- before the marker is published before the request captures its barrier and
-- is adopted, with its holds, before the release can run; one offered after
-- the marker is refused.
--
-- = Rendering
--
-- 'renderWindowFrame' records a window's adopted scene into the frame's image:
-- the window pass, with 'TargetMetrics' built from the frame's own framebuffer
-- extent and the window's latest logical extent and content scale (D-29). A
-- frame whose request carries neither is skipped, as a refusal, through the
-- host's existing backoff; nothing is invented.
--
-- = State
--
-- An 'Adapter' owns the holds, the textures whose release is pending, and the
-- lock that serializes publication with release. The holds and the pending set
-- are written on the graphics owner's thread by the lifecycle's hooks and by
-- the release action, and read from any; publication and release run on any
-- application thread, behind the lock.
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
    -- * Publishing and releasing
  , PublishRefusal (..)
  , publish2DSnapshot
  , ReleaseRefusal (..)
  , release2DTexture
    -- * Adoption and release of revisions
  , adapterAdopted
  , adapterReleased
  , textureHolds
  , pendingReleases
    -- * Rendering
  , FrameInfo (..)
  , renderWindowFrame
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO)
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
import Hetoimasia.GPU.Vulkan.Native.Recording (Recorder, Refusal (..))
import qualified Hetoimasia.Render.Api.Texture as Api
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
import Hetoimasia.Render.TwoD.Validation (ValidSnapshot, validSnapshot, validateSnapshot)
import qualified Hetoimasia.Render.TwoD.Validation as Validation
import Hetoimasia.Render.TwoD.Vulkan (Renderer, prepareSnapshot)
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders)
import Hetoimasia.Render.TwoD.Vulkan.Frame (Attachment (..), FrameInput (..), FrameRefusal (..))
import Hetoimasia.Render.TwoD.Vulkan.Textures (Textures, isReleased, markReleased, releaseTextureNow)
import Numeric.Natural (Natural)

-- | What a window's published revision holds: the validated snapshot, and the
-- textures it references.
data Scene2D = Scene2D
  { sceneSnapshot ∷ !ValidSnapshot
  , sceneReferences ∷ !(Set Api.TextureHandle)
  }

instance NFData Scene2D where
  rnf scene = Set.size (sceneReferences scene) `seq` sceneSnapshot scene `seq` ()

-- | The scene a validated snapshot makes: every texture any of its instances
-- names, in any layer of any view, whether or not it is visible.
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
    )
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
    -- must have adopted first; 'Left' says why it was refused.
  }

-- | A window host's adapter: its holds, its pending releases and the lock that
-- serializes publication with release.
data Adapter window = Adapter
  { adapterHost ∷ !(Host window)
  , adapterTextures ∷ !Textures
  , adapterLock ∷ !(MVar ())
  , adapterHolds ∷ !(TVar (Map (window, Natural) (Set Api.TextureHandle)))
  , adapterPending ∷ !(TVar (Set Api.TextureHandle))
  }

newAdapter ∷ Host window → Textures → IO (Adapter window)
newAdapter host textures = Adapter host textures <$> newMVar () <*> newTVarIO Map.empty <*> newTVarIO Set.empty

-- | Why a snapshot was not published.
data PublishRefusal
  = -- | Validation's reasons, each naming where.
    SnapshotInvalid !(NonEmpty Validation.Refusal)
  | -- | The pass at this index is offscreen: a windowed snapshot holds none
    -- until offscreen targets are issued (R2D-13).
    OffscreenPassHeld !Int
  | -- | The snapshot has no window pass; an empty one is refused.
    NoWindowPass
  | -- | The snapshot references this texture, whose release was requested.
    TextureReleasedInSnapshot !Api.TextureHandle
  | -- | The host holds no such window.
    PublishWindowUnknown
  | -- | The host's publications have ended.
    PublishHostClosed
  | -- | The host carries one shared scene, not a scene for each window.
    PublishHostShared
  deriving (Eq, Show)

-- | Validate a candidate and publish it for the window, answering its
-- revision. Admission is serialized with 'release2DTexture'.
publish2DSnapshot ∷ Adapter window → window → Snapshot → IO (Either PublishRefusal Natural)
publish2DSnapshot adapter window candidate = withMVar (adapterLock adapter) $ \_ →
  case validateSnapshot candidate of
    Left reasons → pure (Left (SnapshotInvalid reasons))
    Right valid → case ([index | (index, Pass {passTarget = OffscreenTarget _}) ← zip [0 ..] (Snapshot.snapshotPasses candidate)], length [() | Pass {passTarget = WindowTarget} ← Snapshot.snapshotPasses candidate]) of
      (index : _, _) → pure (Left (OffscreenPassHeld index))
      ([], 0) → pure (Left NoWindowPass)
      -- Validation has refused a second window pass already.
      ([], _) → do
        let scene = sceneOf valid
        released ← atomically (filterReleased (Set.toList (sceneReferences scene)))
        case released of
          handle : _ → pure (Left (TextureReleasedInSnapshot handle))
          [] →
            hostPublish (adapterHost adapter) window scene >>= \case
              HostPublished revision → pure (Right revision)
              HostWindowUnknown → pure (Left PublishWindowUnknown)
              HostClosed → pure (Left PublishHostClosed)
              HostSharedScenes → pure (Left PublishHostShared)
  where
    filterReleased handles = fmap concat (traverse (\handle → (\flagged → [handle | flagged]) <$> isReleased (adapterTextures adapter) handle) handles)

-- | Why a release was not requested.
data ReleaseRefusal
  = -- | The texture was never registered, or its release has already run.
    ReleaseUnknown !Api.TextureHandle
  | -- | The window host refused the request, saying why.
    ReleaseRequestRefused !Text
  deriving (Eq, Show)

-- | Mark the texture released and ask the host to release it behind its
-- barrier, once no adopted revision holds it. A request the host refused
-- leaves the texture marked and pending, and asking again for the same handle
-- repeats the request; nothing else is asked twice, and a handle whose release
-- has run, or that was never registered, is refused as unknown.
release2DTexture ∷ Adapter window → Api.TextureHandle → IO (Either ReleaseRefusal ())
release2DTexture adapter handle = withMVar (adapterLock adapter) $ \_ → do
  marked ← markReleased (adapterTextures adapter) handle
  waiting ← Set.member handle <$> readTVarIO (adapterPending adapter)
  if not (marked || waiting)
    then pure (Left (ReleaseUnknown handle))
    else do
      atomically (modifyTVar' (adapterPending adapter) (Set.insert handle))
      either (Left . ReleaseRequestRefused) Right <$> requestRelease adapter handle

-- | Ask the host to run the release of this texture after its barrier.
requestRelease ∷ Adapter window → Api.TextureHandle → IO (Either Text ())
requestRelease adapter handle = hostRequestRelease (adapterHost adapter) (releaseBody adapter handle)

-- | The release as the host runs it: only a texture still pending and held by
-- no adopted revision is released in the table; otherwise nothing, and
-- 'adapterReleased' asks again when a hold ends.
releaseBody ∷ Adapter window → Api.TextureHandle → ReleaseBody
releaseBody adapter handle builders = do
  due ← atomically $ do
    pending ← readTVar (adapterPending adapter)
    held ← readTVar (adapterHolds adapter)
    pure (Set.member handle pending && not (any (Set.member handle) (Map.elems held)))
  if not due
    then pure (Right ())
    else do
      atomically (modifyTVar' (adapterPending adapter) (Set.delete handle))
      releaseTextureNow builders (adapterTextures adapter) handle

-- | The owner adopted this revision of the window with this scene: hold every
-- texture it references until the revision is released.
adapterAdopted ∷ Ord window ⇒ Adapter window → window → Natural → Scene2D → IO ()
adapterAdopted adapter window revision scene =
  atomically (modifyTVar' (adapterHolds adapter) (Map.insert (window, revision) (sceneReferences scene)))

-- | This revision of the window has been released: drop its holds, and ask the
-- host again for the release of each texture that was waiting only for them.
adapterReleased ∷ Ord window ⇒ Adapter window → window → Natural → IO ()
adapterReleased adapter window revision = do
  ready ← atomically $ do
    modifyTVar' (adapterHolds adapter) (Map.delete (window, revision))
    pending ← readTVar (adapterPending adapter)
    held ← readTVar (adapterHolds adapter)
    pure (Set.toList (pending `Set.difference` Set.unions (Map.elems held)))
  forM_ ready (requestRelease adapter)

-- | How many adopted revisions hold the texture.
textureHolds ∷ Adapter window → Api.TextureHandle → IO Int
textureHolds adapter handle = length . filter (Set.member handle) . Map.elems <$> readTVarIO (adapterHolds adapter)

-- | The textures whose release was requested and is not yet made in the table.
pendingReleases ∷ Adapter window → IO (Set Api.TextureHandle)
pendingReleases adapter = readTVarIO (adapterPending adapter)

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
  }
  deriving (Eq, Show)

-- | Record a window's adopted scene into the frame's image: the window pass,
-- mapped under metrics built from the frame's extent and the window's own
-- observation. Refused, skipping the frame through the host's backoff, when
-- the request carries no logical extent or no content scale, when they make no
-- valid metrics, and as 'prepareSnapshot' and the recording refuse.
renderWindowFrame
  ∷ Builders q inst msgr phys dev cmd
  → Renderer
  → FrameInfo
  → Scene2D
  → Recorder q inst msgr phys dev cmd
  → IO (Either Refusal ())
renderWindowFrame builders renderer info scene recorder = case (frameLogical info, frameScale info) of
  (Nothing, _) → pure (Left (RefusedIllegal "the frame names no logical extent for its window, so no view can be mapped"))
  (_, Nothing) → pure (Left (RefusedIllegal "the frame names no content scale for its window, so no view can be mapped"))
  (Just (logicalWidth, logicalHeight), Just (scaleX, scaleY)) →
    let (width, height) = frameExtent info
        metrics = TargetMetrics (PixelExtent (fromIntegral logicalWidth) (fromIntegral logicalHeight)) (PixelExtent (fromIntegral width) (fromIntegral height)) scaleX scaleY
     in if not (validMetrics metrics)
          then pure (Left (RefusedIllegal ("the window's metrics are not usable: " <> Text.pack (show metrics))))
          else
            prepareSnapshot builders renderer (FrameInput {frameSnapshot = sceneSnapshot scene, frameTarget = const Nothing, frameWindow = Just (Attachment (frameFormat info) width height metrics)}) >>= \case
              Left refusal → pure (Left (refused refusal))
              Right recording → either (Left . refused) Right <$> recording recorder
  where
    refused = \case
      RefusedByBackend refusal → refusal
      other → RefusedIllegal (Text.pack (show other))
