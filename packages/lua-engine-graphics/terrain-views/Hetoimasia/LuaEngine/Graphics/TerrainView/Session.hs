{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}

-- | The session-owned terrain views (TRA-9): one view per target incarnation, prepared and published by the
-- graphics owner in bounded steps, retired first in, first out.
--
-- = One owner
--
-- Every step of every view runs on the graphics owner's thread, inside one owner action, between frames
-- ('stepOwner'). Nothing else builds, publishes, disposes or plans. A step is asked for by a /kick/: one transaction
-- that admits the next owner action unless one is already queued, and never waits. Kicks come from the controls,
-- the regional snapshot's settlement, the scene ledger's adoptions and releases, the host's frame events, the
-- release lane's barrier actions, a step that leaves work it can do at once, and one signal-only watcher thread
-- ('withTerrainViews' starts and joins it) that blocks on the views' arena mark cells and the terrain service's
-- authority epoch, so an edit, a discovery or a lost lease reaches an idle window. A kick the owner's queue
-- refused is admitted again by the watcher once the queue has room. Nothing waits for capacity: an unaffordable
-- replacement is refused, the target keeps its drawing, and a later relevant change prompts a fresh attempt.
--
-- = A view's preparation
--
-- @copying → planning → building → publication@, one bounded unit per step: one regional snapshot request in
-- flight at a time (taken and its borrow returned in one transaction as soon as it settles), one planning quantum,
-- or at most 'profileBuilds' chunks. A preparation that the view's intent, its target's metrics or its arena's
-- content or knowledge has overtaken is abandoned, its private builds discarded, and the newer state prepared.
-- Publication rechecks the claim, the target, the arena's revisions, the intent and the metrics in the
-- transaction that publishes, so every published revision is one coherent plan.
--
-- = Retirement
--
-- A chunk occupies one of its target's slots from its build to its physical disposal. What a published revision no
-- longer lists asks the host's FIFO release lane for a barrier, in publication order, and is disposed of once that
-- barrier is met and no adopted revision holds it; a private build that never reached a revision is disposed of
-- once its upload has ended. Independent chunks may finish in either order. A disposal that fails keeps the
-- chunk's identity, its slot and its cause, and the others go on.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Session
  ( -- * The service
    TerrainViewsConfig (..)
  , defaultTerrainViewsConfig
  , TerrainViewsPorts (..)
  , TerrainViewsRefused (..)
  , TerrainViews
  , withTerrainViews
  , stepOwner
  , kick

    -- * Targets
  , ViewTarget (..)

    -- * Opening and closing
  , OpenRequest (..)
  , OpenRefusal (..)
  , TerrainView
  , viewIncarnation
  , viewTargetKey
  , openView
  , CloseOutcome (..)
  , closeView

    -- * Controls
  , ControlRefusal (..)
  , MoveOutcome (..)
  , PendingMove
  , moveView
  , moveSettled
  , Configure (..)
  , noConfigure
  , configureView

    -- * Observation
  , ViewStatus (..)
  , Ending (..)
  , BindingLimit (..)
  , ViewReading (..)
  , readView
  , DrawnPlan (..)
  , viewDrawn
  , ServiceReading (..)
  , readTerrainViews
  ) where

import Control.Concurrent.STM
import Control.Exception (Exception, mask, onException, throwIO, uninterruptibleMask_)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Foldable (for_, toList)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, isNothing, mapMaybe)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare)
import Hetoimasia.Foundation.Worker (StartOutcome (..), closeWorkerGroup, requestStop, startWorker, stopRequested, withWorkerGroup, workerDefinition)
import Hetoimasia.LuaEngine.Graphics.Scene.Claims (SceneClaims, claimOf, Claim (..), markClaimPublished, newClaimHolder, releaseClaim, takeClaim)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene, SceneLedger, ledgerChunkHeld, ledgerDropInterest, ledgerListen, ledgerRetainInterest, worldGraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Scene.Receipts (DrawReceipts, Drawn (..), forgetReceipt, readReceipt, receiptsListen)
import Hetoimasia.LuaEngine.Graphics.Scene.World (SceneWorld (..), WorldTag (..))
import Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs (CopySet (..), combineCopies, planInputs)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Owner (BuildFailure (..), Hands (..), OwnerPorts (..))
import Hetoimasia.LuaEngine.Graphics.TerrainView.Profile
import Hetoimasia.LuaEngine.Graphics.TerrainView.Style (AcquiredStyle, StyleRefusal, StyleRequest, acquireStyle, releaseStyle, styleAssets, styleIdentities, styleTextures)
import Hetoimasia.LuaEngine.Texture (RenderAccount, accountRelease, accountReserve)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Chunk (ChunkRef)
import Hetoimasia.Render.TwoD.Material (MaterialData (..), MaterialRecord, materialRecordLayout, recordLayoutBytes)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot (ClearColour (..), Instance, Layer (WorldLayerWith), LayerDepth (DepthEnabled), Viewport (..))
import Hetoimasia.Render.TwoD.Vulkan.Chunks (ChunkStanding (..))
import Hetoimasia.Render.TwoD.Vulkan.Layout (clipEntryBytes)
import Hetoimasia.Terrain.Changes (ChangeLimits (..))
import Hetoimasia.Terrain.Coordinate (AxisCoord, RegionCoord (..), axisValue)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Render2D.Camera (CameraConfig, CameraError, CameraState, Command (..), JumpEvent (..), JumpId (..), JumpTarget (..), PendingJump (..), Step (..), applyCommand, cancelJump, camAnchorX, camAnchorY, camClip, camPending, completeJump, defaultCameraConfig, newCamera, refollow)
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Facts (ChunkDemand (..), ChunkKey (..), Demand (..), TerrainFacts (..))
import Hetoimasia.Terrain.Render2D.Material (Adapted (..), AdaptedQuad (..), adaptCells, adaptedInstance, terrainView)
import Hetoimasia.Terrain.Render2D.Presentation (LightSettings)
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..))
import Hetoimasia.Terrain.Residency (ArenaId (..), RegionDemand (..), Revision (..), coverageBox, limitCameraRegions)
import Hetoimasia.Terrain.Runtime (ArenaMark (..), ArenaView (viewGeneration, viewKnowledgeRevision, viewRevision), RegionPart (..), Settlement (..))
import qualified Hetoimasia.Terrain.Runtime as Runtime
import Hetoimasia.Terrain.Runtime.Settlement (Endpoint (..), TakeOutcome (..), cancel, regionsWith, retireSTM, takeSTM)
import Hetoimasia.Terrain.Shape (ViewFacing)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Configuration and ports

-- | What the service is built with.
data TerrainViewsConfig = TerrainViewsConfig
  { tvProfile ∷ !ViewProfile
  , tvCamera ∷ !CameraConfig
  , tvCells ∷ !CellConfig
    -- ^ The band, margins and query bounds; its limits are replaced by the profile's.
  , tvClear ∷ !ClearColour
  }

defaultTerrainViewsConfig ∷ TerrainViewsConfig
defaultTerrainViewsConfig = TerrainViewsConfig defaultViewProfile defaultCameraConfig defaultCellConfig (ClearColour 0 0 0 1)

-- | What the service is built over: the graphics owner, the scene session's ledger, claims and receipts, the real
-- empty revision a claim is handed back with, the terrain service and the client its views are opened under, and
-- the shared render/staging account the views' allowance is reserved in.
data TerrainViewsPorts k = TerrainViewsPorts
  { portOwner ∷ !OwnerPorts
  , portLedger ∷ !(SceneLedger k)
  , portClaims ∷ !(SceneClaims k)
  , portReceipts ∷ !DrawReceipts
  , portInitial ∷ !(Prepared GraphicsScene)
  , portTerrain ∷ !Runtime.Service
  , portClient ∷ !Runtime.Client
  , portAccount ∷ !RenderAccount
  }

-- | Why the service could not be made. Nothing was reserved or started.
data TerrainViewsRefused
  = TerrainViewsProfile !ProfileRefusal
  | -- | The account cannot hold the allowance: the allowance, and what the account had free.
    TerrainViewsAccount !Integer !Integer
  | TerrainViewsWatcher !Text
  deriving (Eq, Show)

instance Exception TerrainViewsRefused

-- | A target a view attaches to: its incarnation's key, whether it is usable, its latest-value publication as the
-- host's own transaction, whether its frames carry the qualified depth image and the metrics its next frame is
-- recorded with.
data ViewTarget k = ViewTarget
  { vtKey ∷ !k
  , vtUsable ∷ STM Bool
  , vtPublish ∷ Prepared GraphicsScene → STM Bool
  , vtDepth ∷ !Bool
  , vtMetrics ∷ STM (Maybe TargetMetrics)
  }

-- ---------------------------------------------------------------------------
-- State

-- | A chunk's place in a revision: its render region of the rotated view frame and its part of that region.
type PartKey = (Integer, Integer, Int)

-- | One built chunk of a view, with what it was built from (so an equal part is reused, never rebuilt).
data Part = Part
  { partChunk ∷ !ChunkRef
  , partInstances ∷ ![Instance]
  , partRecords ∷ ![MaterialRecord]
  }

-- | What a preparation was started from.
data Basis = Basis
  { basisIntent ∷ !Word64
  , basisMetrics ∷ !(Maybe TargetMetrics)
  , basisArena ∷ !(Maybe (Revision, Revision))
  }
  deriving (Eq, Show)

-- | What a refused view waits on: its basis, the arena's residency and the slots freed when it was refused.
data RefusedAt = RefusedAt !Basis !(Maybe Word64) !Natural
  deriving (Eq, Show)

data InFlight = InFlight
  { flightRequest ∷ !Runtime.Request
  , flightBox ∷ !(TMVar Settlement)
  }

data Prep = Prep
  { prepBasis ∷ !Basis
  , prepMetrics ∷ !TargetMetrics
  , prepRounds ∷ !Int
    -- ^ Copy rounds left after this one.
  , prepRegions ∷ !(Set RegionCoord)
    -- ^ Every region asked for so far.
  }

data Stage
  = Idle
  | Copying !Prep ![RegionCoord] ![Runtime.RegionSnapshot] !(Maybe InFlight)
  | Planning !Prep !CopySet !CellInputs !CellPrep
  | Building !Prep !Candidate

data Candidate = Candidate
  { cdPlan ∷ !CellPlan
  , cdCopies ∷ !CopySet
  , cdAdapted ∷ !Adapted
  , cdWanted ∷ ![(PartKey, [Instance], [MaterialRecord])]
  , cdBuilt ∷ !(Map PartKey Part)
  , cdReused ∷ !(Map PartKey Part)
  }

-- | A plan a view keeps for its target: the drawn revision's and one successor's.
data Pinned = Pinned
  { pinPlan ∷ !CellPlan
  , pinCopies ∷ !(ArenaId, Revision, Revision, Word64)
  }

-- | What a view's preparation is waiting on, for observation.
data ViewStatus
  = ViewOpen
  | ViewEnded !Ending
  deriving (Eq, Show)

-- | How a view ended.
data Ending
  = EndClosed
  | EndRevoked
    -- ^ Its arena lease, client or arena ended.
  | EndTargetGone
  | EndStopped
    -- ^ The service or its graphics owner ended.
  deriving (Eq, Show)

-- | The limit a refused replacement met. It is reported once, on entering refusal.
data BindingLimit
  = LimitSlots !Int !Int
    -- ^ The chunks the candidate needs beyond those it reuses, and the target's free slots.
  | LimitRecorderWindow !Word64 !Word64
    -- ^ The candidate's material records, as a frame binds them, and the renderer's storage window.
  | LimitRuns !Int !Int
    -- ^ The copies' input runs and intervals, and the profile's limit.
  | LimitRuntime !Text
    -- ^ The terrain service refused or failed the copy.
  | LimitFailure !Text
    -- ^ A failure of the plan, its adaptation or a build: its cause.
  deriving (Eq, Show)

data ViewState k = ViewState
  { vsId ∷ !Word64
  , vsTarget ∷ !(ViewTarget k)
  , vsLease ∷ !Runtime.ArenaLease
  , vsRuntime ∷ !Runtime.View
  , vsStyle ∷ !AcquiredStyle
  , vsStyleIds ∷ !(Set Word64)
  , vsMarkCell ∷ STM (Maybe ArenaMark)
  , vsSeen ∷ !(TVar (Maybe ArenaMark, Word64))
    -- ^ The watcher's last reading of the arena's mark and the authority epoch.
  , vsStatus ∷ !(TVar ViewStatus)
  , vsCamera ∷ !(TVar CameraState)
  , vsLight ∷ !(TVar LightSettings)
  , vsIntent ∷ !(TVar Word64)
  , vsMoves ∷ !(TVar (Map Word64 (TVar (Maybe MoveOutcome))))
  , vsFacts ∷ !(TVar (Maybe TerrainFacts))
  , vsStage ∷ !(TVar Stage)
  , vsStageSerial ∷ !(TVar Word64)
    -- ^ Moves whenever the stage is replaced from outside a step (an ending), so a step's write-back can tell.
  , vsPublished ∷ !(TVar (Maybe (Word64, Basis)))
  , vsParts ∷ !(TVar (Map PartKey Part))
    -- ^ The chunks the published revision lists.
  , vsPins ∷ !(TVar (Map Word64 Pinned))
  , vsNextRevision ∷ !(TVar Word64)
  , vsRefused ∷ !(TVar (Maybe (BindingLimit, RefusedAt)))
  , vsRefusals ∷ !(TVar Natural)
  , vsDemand ∷ !(TVar [RegionCoord])
    -- ^ The regions the last plan drew from and still wanted, which seed the next preparation's copies.
  }

-- | A view: a capability over one view incarnation.
data TerrainView k = TerrainView !(TerrainViews k) !(ViewState k)

viewIncarnation ∷ TerrainView k → Word64
viewIncarnation (TerrainView _ vs) = vsId vs

viewTargetKey ∷ TerrainView k → k
viewTargetKey (TerrainView _ vs) = vtKey (vsTarget vs)

data Barrier = Unasked | Asked !(STM (Maybe Bool)) | Met

-- | Chunks a published revision no longer lists, in publication order.
data Retiring k = Retiring
  { rtTarget ∷ !k
  , rtView ∷ !Word64
  , rtChunks ∷ ![ChunkRef]
  , rtBarrier ∷ !Barrier
  , rtProtected ∷ !Bool
    -- ^ A failed handback left the scene that lists them current: kept until the service ends.
  }

data TerrainViews k = TerrainViews
  { svConfig ∷ !TerrainViewsConfig
  , svPorts ∷ !(TerrainViewsPorts k)
  , svViews ∷ !(TVar (Map Word64 (ViewState k)))
  , svSlots ∷ !(TVar (Map k Int))
  , svRetiring ∷ !(TVar (Seq (Retiring k)))
  , svPrivate ∷ !(TVar [(k, Word64, ChunkRef)])
    -- ^ Built chunks no revision listed: disposed of once their upload has ended.
  , svFailed ∷ !(TVar [(k, Maybe ChunkRef, Text)])
    -- ^ Terminal failures, with their causes: a chunk whose disposal failed keeps its identity and its slot.
  , svOpen ∷ !(TVar Bool)
  , svScheduled ∷ !(TVar Bool)
  , svKickWanted ∷ !(TVar Bool)
  , svFreed ∷ !(TVar Natural)
  , svPlanningFrame ∷ !(TVar Word64)
  , svPlanningMax ∷ !(TVar Word64)
  , svReserved ∷ !Integer
  }

-- ---------------------------------------------------------------------------
-- The service's scope

-- | Make the service, run the body, and on every exit end every view, drain every retirement (with the graphics
-- owner live) and return the reservation. Refused before anything is reserved or started for a profile that cannot
-- work or an account that cannot hold the allowance.
withTerrainViews ∷ (Ord k, Show k) ⇒ TerrainViewsConfig → TerrainViewsPorts k → (TerrainViews k → IO a) → IO a
withTerrainViews config ports body = do
  profile ← either (throwIO . TerrainViewsProfile) pure (checkProfile (tvProfile config))
  let allowance = reserveTotal (reservation profile)
      account = portAccount ports
  reserved ←
    atomically $
      if allowance > toInteger (maxBound ∷ Word64)
        then pure False
        else accountReserve account (fromInteger allowance)
  unless reserved $ throwIO (TerrainViewsAccount allowance (-1))
  service ←
    TerrainViews config ports
      <$> newTVarIO Map.empty
      <*> newTVarIO Map.empty
      <*> newTVarIO Seq.empty
      <*> newTVarIO []
      <*> newTVarIO []
      <*> newTVarIO True
      <*> newTVarIO False
      <*> newTVarIO False
      <*> newTVarIO 0
      <*> newTVarIO 0
      <*> newTVarIO 0
      <*> pure allowance
  let listen = do
        ledgerListen (portLedger ports) (kick service)
        receiptsListen (portReceipts ports) (\presented → when presented (frameEnded service) >> kick service)
      unlisten = do
        ledgerListen (portLedger ports) (pure ())
        receiptsListen (portReceipts ports) (const (pure ()))
  mask $ \restore → do
    atomically listen
    let cleanup = do
          shutdown service
          atomically unlisten
          atomically (accountRelease account (fromInteger allowance))
    outcome ←
      restore
        ( withWorkerGroup $ \group → do
            started ← startWorker group (workerDefinition "terrain-views-watcher" (\_ → pure ()) (\token () → watch service (stopRequested token)))
            case started of
              Started worker → do
                result ← body service `onException` (atomically (requestStop worker) >> void (closeWorkerGroup group))
                atomically (requestStop worker)
                _ ← closeWorkerGroup group
                pure result
              _ → throwIO (TerrainViewsWatcher "the watcher did not start")
        )
        `onException` cleanup
    cleanup
    pure outcome

-- The watcher: signals only. It blocks until a view's arena mark or the authority epoch moves, or a refused kick
-- can be admitted, and asks for the owner's next step.
watch ∷ (Ord k, Show k) ⇒ TerrainViews k → STM Bool → IO ()
watch service stopping = loop
  where
    loop = do
      continue ← atomically ((stopping >>= check >> pure False) `orElse` (changed >> pure True))
      when continue loop
    changed = do
      views ← Map.elems <$> readTVar (svViews service)
      epoch ← Runtime.authorityEpochSTM (portTerrain (svPorts service))
      moved ← fmap or . forM views $ \vs → do
        mark ← vsMarkCell vs
        seen ← readTVar (vsSeen vs)
        if seen == (mark, epoch) then pure False else True <$ writeTVar (vsSeen vs) (mark, epoch)
      wanted ← readTVar (svKickWanted service)
      scheduled ← readTVar (svScheduled service)
      if moved
        then kick service
        else
          if wanted && not scheduled
            then admit service >>= check
            else retry

-- | Ask for the owner's next step: one admission, unless one is already queued. Never waits.
kick ∷ (Ord k, Show k) ⇒ TerrainViews k → STM ()
kick service = do
  scheduled ← readTVar (svScheduled service)
  unless scheduled (void (admit service))

admit ∷ (Ord k, Show k) ⇒ TerrainViews k → STM Bool
admit service = do
  admitted ← ownerSchedule (portOwner (svPorts service)) (stepOwner service)
  writeTVar (svScheduled service) admitted
  writeTVar (svKickWanted service) (not admitted)
  pure admitted

-- A presentation was enqueued: the planning time of the frame it ends is recorded.
frameEnded ∷ TerrainViews k → STM ()
frameEnded service = do
  spent ← readTVar (svPlanningFrame service)
  modifyTVar' (svPlanningMax service) (max spent)
  writeTVar (svPlanningFrame service) 0

-- Close admission, end every view, and drain what retires, with the owner live: the drain waits in STM for the
-- retirements, asking the release lane and the owner itself, until they are done or the owner has ended.
shutdown ∷ (Ord k, Show k) ⇒ TerrainViews k → IO ()
shutdown service = uninterruptibleMask_ $ do
  views ← atomically $ do
    writeTVar (svOpen service) False
    Map.elems <$> readTVar (svViews service)
  forM_ views $ \vs → endView service vs EndStopped
  drain
  where
    drain = do
      next ← atomically $ do
        done ← drained service
        if done
          then pure Nothing
          else
            ownerEnded (portOwner (svPorts service)) >>= \case
              Just why → Just (Left why) <$ abandonRetirements service why
              Nothing → do
                asked ← askBarriers service
                scheduled ← readTVar (svScheduled service)
                admitted ← if scheduled then pure False else admit service
                if asked || admitted then pure (Just (Right ())) else retry
      case next of
        Nothing → pure ()
        Just (Left _) → pure ()
        Just (Right ()) → drain

drained ∷ TerrainViews k → STM Bool
drained service = do
  retiring ← readTVar (svRetiring service)
  private ← readTVar (svPrivate service)
  pure (Seq.null retiring && null private)

-- The owner ended for good: what it can no longer dispose of ends as a failure with that cause. The session's managed
-- resources are destroyed with it.
abandonRetirements ∷ TerrainViews k → Text → STM ()
abandonRetirements service why = do
  retiring ← readTVar (svRetiring service)
  private ← readTVar (svPrivate service)
  let cause = "the graphics owner ended before disposal: " <> why
  modifyTVar' (svFailed service) (<> ([(rtTarget r, Just chunk, cause) | r ← toList retiring, chunk ← rtChunks r] <> [(k, Just chunk, cause) | (k, _, chunk) ← private]))
  writeTVar (svRetiring service) Seq.empty
  writeTVar (svPrivate service) []

-- ---------------------------------------------------------------------------
-- Opening

-- | What an attachment names.
data OpenRequest k = OpenRequest
  { openTarget ∷ !(ViewTarget k)
  , openLease ∷ !Runtime.ArenaLease
  , openStyle ∷ !StyleRequest
  , openAnchor ∷ !(AxisCoord, AxisCoord, AxisCoord)
    -- ^ The camera's starting column and level.
  , openLight ∷ !LightSettings
  }

data OpenRefusal
  = OpenStyle !StyleRefusal
  | -- | The target's frames carry no @D32_SFLOAT@ depth image, or the session's depth format is not @D32_SFLOAT@.
    OpenNoDepth
  | OpenTargetUnusable
  | -- | A terrain view holds the target already.
    OpenTargetClaimed
  | -- | The profile's views are all open.
    OpenTooManyViews
  | OpenArena !Runtime.Refused
  | OpenCamera !CameraError
  | OpenStopped
  deriving (Eq, Show)

-- | Open a view of an arena on a target. It settles here, at attachment: the style is retained and checked, the
-- session, the depth support, the view count, the target and the exclusive claim shared with M1 are checked, and
-- the claim, the style's interests and the view are taken in one transaction. A refusal leaves nothing behind.
openView ∷ (Ord k, Show k) ⇒ TerrainViews k → OpenRequest k → IO (Either OpenRefusal (TerrainView k))
openView service request = mask $ \restore → do
  let ports = svPorts service
      target = openTarget request
      (x, y, z) = openAnchor request
  open ← readTVarIO (svOpen service)
  if not open
    then pure (Left OpenStopped)
    else
      if not (vtDepth target && ownerDepthQualified (portOwner ports))
        then pure (Left OpenNoDepth)
        else case newCamera (tvCamera (svConfig service)) x y z of
          Left why → pure (Left (OpenCamera why))
          Right camera →
            restore (acquireStyle (openStyle request)) >>= \case
              Left why → pure (Left (OpenStyle why))
              Right style → do
                let undo = releaseStyle style
                runtimeView ← Runtime.openView (portTerrain ports) (portClient ports) `onException` undo
                case runtimeView of
                  Left why → undo >> pure (Left (OpenArena why))
                  Right rview → do
                    let closeRuntime = Runtime.closeView (portTerrain ports) rview
                    cell ← atomically (Runtime.arenaMarkSTM (portTerrain ports) (openLease request))
                    case cell of
                      Left why → closeRuntime >> undo >> pure (Left (OpenArena why))
                      Right markCell → do
                        vs ← newViewState service request style rview markCell camera `onException` (closeRuntime >> undo)
                        committed ← atomically (commitOpen service vs) `onException` (closeRuntime >> undo)
                        case committed of
                          Left why → closeRuntime >> undo >> pure (Left why)
                          Right () → do
                            atomically (kick service)
                            pure (Right (TerrainView service vs))

newViewState ∷ TerrainViews k → OpenRequest k → AcquiredStyle → Runtime.View → STM (Maybe ArenaMark) → CameraState → IO (ViewState k)
newViewState service request style rview markCell camera = do
  incarnation ← atomically (newClaimHolder (portClaims (svPorts service)))
  ViewState incarnation (openTarget request) (openLease request) rview style (styleIdentities style) markCell
    <$> newTVarIO (Nothing, 0)
    <*> newTVarIO ViewOpen
    <*> newTVarIO camera
    <*> newTVarIO (openLight request)
    <*> newTVarIO 0
    <*> newTVarIO Map.empty
    <*> newTVarIO Nothing
    <*> newTVarIO Idle
    <*> newTVarIO 0
    <*> newTVarIO Nothing
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO 1
    <*> newTVarIO Nothing
    <*> newTVarIO 0
    <*> newTVarIO []

commitOpen ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → STM (Either OpenRefusal ())
commitOpen service vs = do
  let ports = svPorts service
      target = vsTarget vs
  open ← readTVar (svOpen service)
  usable ← vtUsable target
  views ← readTVar (svViews service)
  arena ← Runtime.inspectArenaSTM (portTerrain ports) (vsLease vs)
  if
    | not open → pure (Left OpenStopped)
    | not usable → pure (Left OpenTargetUnusable)
    | isNothing arena → pure (Left (OpenArena Runtime.RefusedAuthority))
    | Map.size views >= profileTargets (tvProfile (svConfig service)) → pure (Left OpenTooManyViews)
    | otherwise →
        takeClaim (portClaims ports) (vtKey target) (vsId vs) >>= \case
          False → pure (Left OpenTargetClaimed)
          True → do
            forM_ (Set.toList (vsStyleIds vs)) (ledgerRetainInterest (portLedger ports))
            writeTVar (svViews service) (Map.insert (vsId vs) vs views)
            pure (Right ())

-- ---------------------------------------------------------------------------
-- Controls

-- | Why a control was not admitted. Nothing changed.
data ControlRefusal
  = -- | The view has ended.
    ControlEnded
  | -- | Recoverable pressure: the view has no terrain facts yet to move its camera with.
    ControlBusy
  | ControlInvalid !CameraError
  deriving (Eq, Show)

-- | How a move settled, once.
data MoveOutcome
  = MoveLanded
  | -- | A newer admitted move or camera change cancelled it.
    MoveSuperseded
  | -- | The view ended first.
    MoveEnded !Ending
  deriving (Eq, Show)

newtype PendingMove = PendingMove (TVar (Maybe MoveOutcome))

moveSettled ∷ PendingMove → STM (Maybe MoveOutcome)
moveSettled (PendingMove box) = readTVar box

-- | Move the camera: a jump to a column, with a level for manual depth or without one to follow the surface. It
-- settles at the camera's eligible transition, at once when the destination's facts are already copied, otherwise
-- when a step has copied them. A newer move or camera change cancels it; a lighting change does not.
moveView ∷ (Ord k, Show k) ⇒ TerrainView k → JumpTarget → STM (Either ControlRefusal PendingMove)
moveView (TerrainView service vs) target =
  controlled vs $ \facts camera → case applyCommand (tvCamera (svConfig service)) facts (Jump target) camera of
    Left why → pure (Left (ControlInvalid why))
    Right step → do
      supersede vs
      writeTVar (vsCamera vs) (stepCamera step)
      bumpIntent service vs
      box ← newTVar Nothing
      case stepJump step of
        JumpApplied _ → writeTVar box (Just MoveLanded)
        JumpPending (JumpId number) _ → modifyTVar' (vsMoves vs) (Map.insert number box)
        _ → writeTVar box (Just MoveLanded)
      pure (Right (PendingMove box))

-- | A partial update of the camera, depth and lighting.
data Configure = Configure
  { configureZoom ∷ !(Maybe Float)
  , configureFacing ∷ !(Maybe ViewFacing)
  , configureDepth ∷ !(Maybe AxisCoord)
    -- ^ Manual depth at this level. A move without a level restores following.
  , configureLight ∷ !(Maybe LightSettings)
  }

noConfigure ∷ Configure
noConfigure = Configure Nothing Nothing Nothing Nothing

-- | Apply a validated partial update atomically, or nothing. A camera field needs the view's terrain facts and is
-- busy until it has them; a camera change cancels a pending move, a lighting change does not.
configureView ∷ (Ord k, Show k) ⇒ TerrainView k → Configure → STM (Either ControlRefusal ())
configureView (TerrainView service vs) update
  | null commands = do
      status ← readTVar (vsStatus vs)
      case (status, configureLight update) of
        (ViewEnded _, _) → pure (Left ControlEnded)
        (_, Nothing) → pure (Right ())
        (_, Just light) → Right () <$ (writeTVar (vsLight vs) light >> bumpIntent service vs)
  | otherwise =
      controlled vs $ \facts camera →
        case foldl (\acc command → acc >>= \c → stepCamera <$> applyCommand (tvCamera (svConfig service)) facts command c) (Right camera) commands of
          Left why → pure (Left (ControlInvalid why))
          Right moved → do
            supersede vs
            writeTVar (vsCamera vs) (maybe moved (\p → cancelJump (pendingId p) moved) (camPending moved))
            for_ (configureLight update) (writeTVar (vsLight vs))
            bumpIntent service vs
            pure (Right ())
  where
    commands = catMaybes [SetZoom <$> configureZoom update, SetFacing <$> configureFacing update, SelectSlice <$> configureDepth update]

controlled ∷ ViewState k → (TerrainFacts → CameraState → STM (Either ControlRefusal a)) → STM (Either ControlRefusal a)
controlled vs body =
  readTVar (vsStatus vs) >>= \case
    ViewEnded _ → pure (Left ControlEnded)
    ViewOpen →
      readTVar (vsFacts vs) >>= \case
        Nothing → pure (Left ControlBusy)
        Just facts → readTVar (vsCamera vs) >>= body facts

-- Settle every pending move as superseded and cancel the camera's pending jump.
supersede ∷ ViewState k → STM ()
supersede vs = do
  moves ← readTVar (vsMoves vs)
  forM_ (Map.elems moves) (settleOnce MoveSuperseded)
  writeTVar (vsMoves vs) Map.empty
  modifyTVar' (vsCamera vs) (\camera → maybe camera (\p → cancelJump (pendingId p) camera) (camPending camera))

settleOnce ∷ MoveOutcome → TVar (Maybe MoveOutcome) → STM ()
settleOnce outcome box = readTVar box >>= maybe (writeTVar box (Just outcome)) (const (pure ()))

bumpIntent ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → STM ()
bumpIntent service vs = modifyTVar' (vsIntent vs) (+ 1) >> kick service

-- ---------------------------------------------------------------------------
-- Endings

-- | What a close found.
data CloseOutcome
  = -- | The view's chunks are still retiring.
    CloseRetiring
  | -- | Nothing of the view is left.
    CloseDone
  | CloseAlreadyReleased
  deriving (Eq, Show)

-- | Close a view now, through its own capability: revoke it, hand a published claim back with a real empty revision
-- (an unpublished one directly), withdraw its demand and settle its pending moves. It needs no frame and no step,
-- so it completes on a minimized target; its chunks retire through the owner.
closeView ∷ (Ord k, Show k) ⇒ TerrainView k → IO CloseOutcome
closeView (TerrainView service vs) =
  endView service vs EndClosed >>= \case
    False → pure CloseAlreadyReleased
    True →
      atomically $ do
        retiring ← readTVar (svRetiring service)
        private ← readTVar (svPrivate service)
        pure (if any ((== vsId vs) . rtView) retiring || any (\(_, v, _) → v == vsId vs) private then CloseRetiring else CloseDone)

-- End a view, once: 'False' when it had already ended. The transaction does every state change; the terrain service's
-- calls and the style's release follow it.
endView ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Ending → IO Bool
endView service vs ending = uninterruptibleMask_ $ do
  ended ← atomically (endViewSTM service vs ending)
  case ended of
    Nothing → pure False
    Just flight → do
      for_ flight (abandonFlight service)
      Runtime.closeView (portTerrain (svPorts service)) (vsRuntime vs)
      releaseStyle (vsStyle vs)
      pure True

endViewSTM ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Ending → STM (Maybe (Maybe InFlight))
endViewSTM service vs ending =
  readTVar (vsStatus vs) >>= \case
    ViewEnded _ → pure Nothing
    ViewOpen → do
      let ports = svPorts service
          target = vsTarget vs
          key = vtKey target
      writeTVar (vsStatus vs) (ViewEnded ending)
      -- the claim: a published one is handed back with a real empty revision in this transaction
      handed ←
        releaseClaim (portClaims ports) key (vsId vs) >>= \case
          Just claim | claimPublished claim, ending /= EndTargetGone → do
            usable ← vtUsable target
            if usable then vtPublish target (portInitial ports) else pure False
          _ → pure True
      forM_ (Set.toList (vsStyleIds vs)) (ledgerDropInterest (portLedger ports))
      moves ← readTVar (vsMoves vs)
      forM_ (Map.elems moves) (settleOnce (MoveEnded ending))
      writeTVar (vsMoves vs) Map.empty
      forgetReceipt (portReceipts ports) (vsId vs)
      writeTVar (vsPins vs) Map.empty
      flight ← takeStage service vs
      parts ← readTVar (vsParts vs)
      writeTVar (vsParts vs) Map.empty
      unless (Map.null parts) $
        modifyTVar' (svRetiring service) (|> Retiring key (vsId vs) (map partChunk (Map.elems parts)) Unasked (not handed))
      modifyTVar' (svViews service) (Map.delete (vsId vs))
      kick service
      pure (Just flight)

-- Take the view's stage from outside a step: its private builds go to disposal, and its request in flight is handed
-- back for cancellation.
takeStage ∷ TerrainViews k → ViewState k → STM (Maybe InFlight)
takeStage service vs = do
  stage ← readTVar (vsStage vs)
  writeTVar (vsStage vs) Idle
  modifyTVar' (vsStageSerial vs) (+ 1)
  case stage of
    Building _ candidate → do
      privately service vs (map partChunk (Map.elems (cdBuilt candidate)))
      pure Nothing
    Copying _ _ _ flight → pure flight
    _ → pure Nothing

privately ∷ TerrainViews k → ViewState k → [ChunkRef] → STM ()
privately service vs chunks = modifyTVar' (svPrivate service) (<> [(vtKey (vsTarget vs), vsId vs, chunk) | chunk ← chunks])

-- Cancel a request in flight; a borrow that settlement won is taken and returned.
abandonFlight ∷ TerrainViews k → InFlight → IO ()
abandonFlight service flight = do
  let terrain = portTerrain (svPorts service)
  _ ← cancel terrain (flightRequest flight)
  atomically $
    tryReadTMVar (flightBox flight) >>= \case
      Just (Succeeded (Runtime.ARegions borrow)) →
        takeSTM terrain (flightRequest flight) >>= \case
          Taken → Runtime.releaseRegionBorrowSTM terrain borrow
          TakeReleased → pure ()
      Just _ → retireSTM terrain (flightRequest flight)
      Nothing → pure ()

-- ---------------------------------------------------------------------------
-- The owner's step

-- | One owner step, on the graphics owner's thread with its hands: one bounded unit of each open view, then the
-- retirements. It asks for the next step when it leaves work it can do at once.
stepOwner ∷ (Ord k, Show k) ⇒ TerrainViews k → Hands → IO ()
stepOwner service hands = do
  atomically (writeTVar (svScheduled service) False)
  views ← Map.elems <$> readTVarIO (svViews service)
  busy ← or <$> forM views (stepView service hands)
  retired ← retire service hands
  when (busy || retired) (atomically (kick service))

-- Whether the view did something a further step can continue at once.
stepView ∷ (Ord k, Show k) ⇒ TerrainViews k → Hands → ViewState k → IO Bool
stepView service hands vs = do
  let ports = svPorts service
      target = vsTarget vs
  ending ← atomically $ do
    status ← readTVar (vsStatus vs)
    usable ← vtUsable target
    arena ← Runtime.inspectArenaSTM (portTerrain ports) (vsLease vs)
    pure $ case status of
      ViewEnded _ → Just Nothing
      ViewOpen
        | not usable → Just (Just EndTargetGone)
        | isNothing arena → Just (Just EndRevoked)
        | otherwise → Nothing
  case ending of
    Just Nothing → pure False
    Just (Just why) → False <$ endView service vs why
    Nothing → do
      checkPublished service vs
      (serial, stage, basis) ← atomically ((,,) <$> readTVar (vsStageSerial vs) <*> readTVar (vsStage vs) <*> currentBasis service vs)
      case stage of
        Idle → startIfDue service vs basis
        Copying prep wanted taken flight
          | stale prep basis → abandon service vs serial >> pure True
          | otherwise → stepCopying service vs serial prep wanted taken flight
        Planning prep copies inputs prepared
          | stale prep basis → abandon service vs serial >> pure True
          | otherwise → stepPlanning service vs serial prep copies inputs prepared
        Building prep candidate
          | stale prep basis → abandon service vs serial >> pure True
          | otherwise → stepBuilding service hands vs serial prep candidate
  where
    stale prep basis = prepBasis prep /= basis

currentBasis ∷ TerrainViews k → ViewState k → STM Basis
currentBasis service vs = do
  intent ← readTVar (vsIntent vs)
  metrics ← vtMetrics (vsTarget vs)
  arena ← Runtime.inspectArenaSTM (portTerrain (svPorts service)) (vsLease vs)
  pure (Basis intent metrics ((\a → (viewRevision a, viewKnowledgeRevision a)) <$> arena))

currentResidency ∷ TerrainViews k → ViewState k → STM (Maybe Word64)
currentResidency service vs = fmap (fromIntegral . viewGeneration) <$> Runtime.inspectArenaSTM (portTerrain (svPorts service)) (vsLease vs)

-- A published revision whose chunk failed its upload can never draw: its parts are dropped, so the next preparation
-- rebuilds them, and the view prepares again.
checkPublished ∷ TerrainViews k → ViewState k → IO ()
checkPublished service vs = atomically $ do
  parts ← readTVar (vsParts vs)
  standings ← forM (Map.toList parts) $ \(key, part) → (,) key <$> ownerStanding (portOwner (svPorts service)) (partChunk part)
  let failed = [(key, standing) | (key, Just standing@(ChunkFailed _)) ← standings]
  unless (null failed) $ do
    modifyTVar' (svFailed service) (<> [(vtKey (vsTarget vs), partChunk <$> Map.lookup key parts, "a published chunk's upload ended without completing: " <> Text.pack (show standing)) | (key, standing) ← failed])
    writeTVar (vsPublished vs) Nothing
    writeTVar (vsRefused vs) Nothing

-- Start a preparation when the published revision is not of the current basis and the view is not refused at it.
startIfDue ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Basis → IO Bool
startIfDue service vs basis = atomically $ do
  published ← readTVar (vsPublished vs)
  refused ← readTVar (vsRefused vs)
  residency ← currentResidency service vs
  freed ← readTVar (svFreed service)
  let due = fmap snd published /= Just basis
      stillRefused = case refused of
        Just (_, RefusedAt at seen count) → at == basis && seen == residency && count == freed
        Nothing → False
  case basisMetrics basis of
    Just metrics | due && not stillRefused → do
      camera ← readTVar (vsCamera vs)
      demand ← readTVar (vsDemand vs)
      let profile = tvProfile (svConfig service)
          anchor = anchorRegion camera
          jumpTo = maybe [] (\p → [targetRegion (pendingTarget p) (camClip camera)]) (camPending camera)
          wanted = take (profileRegions profile) (ordered anchor (anchor : jumpTo <> demand))
      writeTVar (vsStage vs) (Copying (Prep basis metrics (profileRounds profile - 1) (Set.fromList wanted)) wanted [] Nothing)
      pure True
    _ → pure False

-- The regions in admission order: the anchor's first, then the nearest to it, each once.
ordered ∷ RegionCoord → [RegionCoord] → [RegionCoord]
ordered anchor regions = map snd (sortOn fst [(distance region, region) | region ← Set.toList (Set.fromList regions)])
  where
    distance r = (abs (regionX r - regionX anchor) `max` abs (regionY r - regionY anchor), abs (toInteger (regionZ r) - toInteger (regionZ anchor)))

anchorRegion ∷ CameraState → RegionCoord
anchorRegion camera = RegionCoord (fromIntegral (axisValue (camAnchorX camera) `div` 16)) (fromIntegral (axisValue (camAnchorY camera) `div` 16)) (fromIntegral (axisValue (camClip camera) `div` 32))

targetRegion ∷ JumpTarget → AxisCoord → RegionCoord
targetRegion target clip = RegionCoord (fromIntegral (axisValue (jumpX target) `div` 16)) (fromIntegral (axisValue (jumpY target) `div` 16)) (fromIntegral (axisValue (fromMaybe clip (jumpZ target)) `div` 32))

-- Abandon the stage a newer basis overtook: its private builds go to disposal and its request is cancelled.
abandon ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → IO ()
abandon service vs serial = do
  flight ← atomically $ do
    current ← readTVar (vsStageSerial vs)
    if current /= serial then pure Nothing else takeStage service vs
  for_ flight (abandonFlight service)

-- Write a step's new stage back, unless an ending replaced the stage meanwhile: then what the step made goes to
-- disposal ('False').
writeBack ∷ TerrainViews k → ViewState k → Word64 → Stage → STM Bool
writeBack service vs serial stage = do
  current ← readTVar (vsStageSerial vs)
  status ← readTVar (vsStatus vs)
  if current == serial && status == ViewOpen
    then True <$ writeTVar (vsStage vs) stage
    else False <$ case stage of
      Building _ candidate → privately service vs (map partChunk (Map.elems (cdBuilt candidate)))
      _ → pure ()

-- Enter refusal: the current drawing stays; the binding limit is reported once, on entering.
refuse ∷ TerrainViews k → ViewState k → Word64 → Basis → BindingLimit → STM ()
refuse service vs serial basis limit = do
  current ← readTVar (vsStageSerial vs)
  when (current == serial) $ do
    stage ← readTVar (vsStage vs)
    case stage of
      Building _ candidate → privately service vs (map partChunk (Map.elems (cdBuilt candidate)))
      _ → pure ()
    writeTVar (vsStage vs) Idle
    residency ← currentResidency service vs
    freed ← readTVar (svFreed service)
    before ← readTVar (vsRefused vs)
    when (isNothing before) (modifyTVar' (vsRefusals vs) (+ 1))
    writeTVar (vsRefused vs) (Just (limit, RefusedAt basis residency freed))

-- ---------------------------------------------------------------------------
-- Copying

stepCopying ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Prep → [RegionCoord] → [Runtime.RegionSnapshot] → Maybe InFlight → IO Bool
stepCopying service vs serial prep wanted taken = \case
  Just flight → do
    -- the settled borrow is taken and returned in one transaction: the copy is an immutable value
    outcome ← atomically $ do
      tryReadTMVar (flightBox flight) >>= \case
        Nothing → pure Nothing
        Just settlement → Just <$> takeCopy (portTerrain (svPorts service)) flight settlement
    case outcome of
      Nothing → pure False
      Just (Right snapshot) → atomically (writeBack service vs serial (Copying prep wanted (snapshot : taken) Nothing))
      Just (Left why) → False <$ atomically (refuse service vs serial (prepBasis prep) (LimitRuntime why))
  Nothing → case wanted of
    [] → toPlanning service vs serial prep taken
    _ → do
      let (batch, rest) = splitAt (profileRequestRegions (tvProfile (svConfig service))) wanted
      box ← newEmptyTMVarIO
      let endpoint = Endpoint (pure ()) (pure True) (\settlement → void (tryPutTMVar box settlement) >> kick service) Nothing
      mask $ \_ →
        regionsWith (portTerrain (svPorts service)) endpoint (vsLease vs) batch >>= \case
          Left why → False <$ atomically (refuse service vs serial (prepBasis prep) (LimitRuntime (Text.pack (show why))))
          Right request → do
            let flight = InFlight request box
            kept ← atomically (writeBack service vs serial (Copying prep rest taken (Just flight)))
            unless kept (abandonFlight service flight)
            pure False

takeCopy ∷ Runtime.Service → InFlight → Settlement → STM (Either Text Runtime.RegionSnapshot)
takeCopy terrain flight = \case
  Succeeded (Runtime.ARegions borrow) →
    takeSTM terrain (flightRequest flight) >>= \case
      Taken → do
        Runtime.releaseRegionBorrowSTM terrain borrow
        pure (Right (Runtime.regionBorrowSnapshot borrow))
      TakeReleased → pure (Left "the copy was released before it was taken")
  Succeeded other → Left ("the copy answered " <> Text.pack (show other)) <$ retireSTM terrain (flightRequest flight)
  Failed why → Left ("the copy failed: " <> Text.pack (show why)) <$ retireSTM terrain (flightRequest flight)
  Cancelled → pure (Left "the copy was cancelled")

-- Combine the copies, settle the camera with their facts, and start planning (or copy again for what the camera
-- itself still needs).
toPlanning ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Prep → [Runtime.RegionSnapshot] → IO Bool
toPlanning service vs serial prep taken = do
  let profile = tvProfile (svConfig service)
      basis = prepBasis prep
  case combineCopies taken of
    Left _ → False <$ atomically (refuse service vs serial basis (LimitRuntime "the copies are of different versions"))
    Right copies
      | runs > profileRuns profile → False <$ atomically (refuse service vs serial basis (LimitRuns runs (profileRuns profile)))
      | otherwise → case planInputs (ChangeLimits (profileRuns profile)) copies of
          Left why → False <$ atomically (refuse service vs serial basis (LimitFailure ("the copies could not be planned from: " <> Text.pack (show why))))
          Right (facts, knowledge) → atomically $ do
            camera ← settleCamera service vs facts
            let extra = missingFor camera
                fresh = filter (`Set.notMember` prepRegions prep) extra
            if not (null fresh) && prepRounds prep > 0
              then writeBack service vs serial (Copying prep {prepRounds = prepRounds prep - 1, prepRegions = prepRegions prep <> Set.fromList fresh} fresh taken Nothing)
              else do
                let inputs = CellInputs (CellRequest (factsVersions facts) camera (setupFor (prepMetrics prep)) (cellConfig service)) facts knowledge (styleAssets (vsStyle vs))
                case startCells inputs of
                  Left why → False <$ refuse service vs serial basis (LimitFailure ("the plan could not start: " <> Text.pack (show why)))
                  Right prepared → writeBack service vs serial (Planning prep copies inputs prepared)
  where
    runs = sum (map copyRuns taken)
    missingFor camera = maybe [] (\p → [targetRegion (pendingTarget p) (camClip camera)]) (camPending camera)

-- The input runs and intervals of one copy: every removed interval, and every knowledge run of a region that is not
-- one class.
copyRuns ∷ Runtime.RegionSnapshot → Int
copyRuns snapshot =
  sum
    [ terrainRuns region + knowledgeRuns region
    | region ← Runtime.regionSnapshotRegions snapshot
    ]
  where
    terrainRuns region = case Runtime.regionTerrain snapshot region of
      PartReady intervals → length intervals
      _ → 0
    knowledgeRuns region = case Runtime.regionKnowledge snapshot region of
      PartReady known
        | [[_]] ← D.regionKnowledgeClasses known → 1
        | otherwise → sum (map length (D.regionKnowledgeClasses known))
      _ → 0

-- The facts are the view's from now on: a followed surface they supply is adopted and a pending jump they allow
-- lands, settling its move.
settleCamera ∷ TerrainViews k → ViewState k → TerrainFacts → STM CameraState
settleCamera service vs facts = do
  writeTVar (vsFacts vs) (Just facts)
  camera ← readTVar (vsCamera vs)
  let config = tvCamera (svConfig service)
      followed = either (const camera) stepCamera (refollow config facts camera)
  landed ← case camPending followed of
    Nothing → pure followed
    Just pending → case completeJump config facts (pendingId pending) followed of
      Right result → do
        case stepJump result of
          JumpApplied (JumpId number) → do
            moves ← readTVar (vsMoves vs)
            for_ (Map.lookup number moves) (settleOnce MoveLanded)
            writeTVar (vsMoves vs) (Map.delete number moves)
          _ → pure ()
        pure (stepCamera result)
      Left _ → pure followed
  writeTVar (vsCamera vs) landed
  pure landed

-- The planner's configuration under the profile's limits.
cellConfig ∷ TerrainViews k → CellConfig
cellConfig service =
  let profile = tvProfile (svConfig service)
      base = tvCells (svConfig service)
   in base
        { ccLimits =
            (ccLimits base)
              { clColumns = profileColumns profile
              , clLevels = profileLevels profile
              , clInstances = profileQuads profile
              , clPending = profilePending profile
              , clStepWork = profileStepWork profile
              }
        }

setupFor ∷ TargetMetrics → ViewSetup
setupFor metrics =
  let PixelExtent width height = metricsFramebuffer metrics
   in ViewSetup metrics (Viewport (V2 0 0) (V2 (fromIntegral width) (fromIntegral height))) defaultViewSettings

-- ---------------------------------------------------------------------------
-- Planning

-- One planning quantum, timed on the owner's thread; at its end, another copy round for the visible demand the copies
-- lack, or the candidate's chunks and its admission.
stepPlanning ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Prep → CopySet → CellInputs → CellPrep → IO Bool
stepPlanning service vs serial prep copies inputs prepared = case cellPrepProgress prepared of
  Working → timed service (pure $! stepCells inputs prepared) >>= \case
    Left why → False <$ atomically (refuse service vs serial (prepBasis prep) (LimitFailure ("a plan step failed: " <> Text.pack (show why))))
    Right next → atomically (writeBack service vs serial (Planning prep copies inputs next))
  _ → case cellPlanOf inputs prepared of
    Left why → False <$ atomically (refuse service vs serial (prepBasis prep) (LimitFailure ("the plan could not finish: " <> Text.pack (show why))))
    Right plan → do
      let profile = tvProfile (svConfig service)
          visible = regionsOf (cdVisible (cellPlanDemand plan))
          room = profileRegions profile - Set.size (prepRegions prep)
          missing = take room (filter (`Set.notMember` prepRegions prep) (ordered (anchorRegion (crCamera (inputsRequest inputs))) visible))
      if not (null missing) && prepRounds prep > 0
        then atomically (writeBack service vs serial (Copying prep {prepRounds = prepRounds prep - 1, prepRegions = prepRegions prep <> Set.fromList missing} missing (copySnapshots copies) Nothing))
        else do
          light ← readTVarIO (vsLight vs)
          admitted ← timed service (pure $! candidateOf service vs plan copies light)
          case admitted of
            Left limit → False <$ atomically (refuse service vs serial (prepBasis prep) limit)
            Right (adapted, wanted) → do
              atomically (writeTVar (vsDemand vs) (Set.toList (prepRegions prep) <> visible))
              setDemand service vs (visible <> regionsOf (cdPrefetch (cellPlanDemand plan)))
              parts ← readTVarIO (vsParts vs)
              let reused = Map.mapMaybe id (Map.intersectionWith (\part (_, instances, records) → if partInstances part == instances && partRecords part == records then Just part else Nothing) parts (Map.fromList [(key, (key, i, r)) | (key, i, r) ← wanted]))
                  toBuild = [w | w@(key, _, _) ← wanted, Map.notMember key reused]
              atomically $ do
                occupied ← Map.findWithDefault 0 (vtKey (vsTarget vs)) <$> readTVar (svSlots service)
                let free = profileSlots profile - occupied
                if length toBuild > free
                  then False <$ refuse service vs serial (prepBasis prep) (LimitSlots (length toBuild) free)
                  else writeBack service vs serial (Building prep (Candidate plan copies adapted toBuild Map.empty reused))

-- Time pure work on the owner's thread, into the current frame's planning total.
timed ∷ TerrainViews k → IO a → IO a
timed service work = do
  start ← getMonotonicTimeNSec
  result ← work
  end ← getMonotonicTimeNSec
  atomically (modifyTVar' (svPlanningFrame service) (+ (end - start)))
  pure result

-- Adapt the plan and group it into the candidate's chunks: render regions of 16 x 16 cells of the rotated view frame,
-- each split into parts of at most a chunk's instances, each part with the distinct records its quads use. Refused
-- when its records cannot fit the renderer's storage window as a frame binds them.
candidateOf ∷ TerrainViews k → ViewState k → CellPlan → CopySet → LightSettings → Either BindingLimit (Adapted, [(PartKey, [Instance], [MaterialRecord])])
candidateOf service vs plan _ light = do
  adapted ← either (Left . LimitFailure . ("the plan could not be adapted: " <>) . Text.pack . show) Right (adaptCells (styleTextures (vsStyle vs)) light (styleAssets (vsStyle vs)) plan)
  let owner = portOwner (svPorts service)
      material = ownerMaterial owner
      perPart = chunkInstances (tvProfile (svConfig service))
      regions = Map.fromListWith (flip (<>)) [(regionKey (adaptedQuad quad), [quad]) | quad ← adaptedQuads adapted]
      table = Map.fromList (zip [0 ..] (adaptedRecords adapted))
      parts =
        [ ((rx, ry, index), instances, records)
        | ((rx, ry), quads) ← Map.toList regions
        , (index, slice) ← zip [0 ..] (slices perPart quads)
        , let used = Set.toAscList (Set.fromList [adaptedParameter quad | quad ← slice])
              renumber = Map.fromList (zip used [0 ..])
              records = mapMaybe (`Map.lookup` table) used
              instances = [adaptedInstance material adapted quad {adaptedParameter = Map.findWithDefault 0 (adaptedParameter quad) renumber} | quad ← slice]
        ]
      perRecord = recordLayoutBytes (materialRecordLayout material)
      need = fromIntegral clipEntryBytes + sum [perRecord * fromIntegral (length records) | (_, _, records) ← parts]
      window = ownerRegionWindow owner
  if need > window then Left (LimitRecorderWindow need window) else Right (adapted, parts)
  where
    regionKey quad = let CellKey _ _ vx vy _ = quadKey quad in (vx `div` 16, vy `div` 16)
    slices n xs = case splitAt n xs of
      (chunk, []) → [chunk]
      (chunk, rest) → chunk : slices n rest

regionsOf ∷ Demand → [RegionCoord]
regionsOf (Demand chunks) = [RegionCoord cx cy (fromInteger level) | ChunkDemand (ChunkKey cx cy) _ levels ← chunks, level ← levels]

-- The view's runtime demand: its visible regions before its prefetch, latest value only, at most the service's camera
-- regions. A refusal is the terrain service's to explain; the copies do not depend on residency.
setDemand ∷ TerrainViews k → ViewState k → [RegionCoord] → IO ()
setDemand service vs regions = do
  let terrain = portTerrain (svPorts service)
      cap = fromIntegral (limitCameraRegions (Runtime.configLimits (Runtime.inspectConfig terrain)))
      demands = [RegionDemand region coverage | region ← take cap (nubOrdered regions), Right coverage ← [coverageBox 0 16 0 16 0 32]]
  void (Runtime.setViewDemand terrain (vsRuntime vs) (vsLease vs) demands)
  where
    nubOrdered = go Set.empty
    go _ [] = []
    go seen (r : rs)
      | Set.member r seen = go seen rs
      | otherwise = r : go (Set.insert r seen) rs

-- ---------------------------------------------------------------------------
-- Building and publication

stepBuilding ∷ (Ord k, Show k) ⇒ TerrainViews k → Hands → ViewState k → Word64 → Prep → Candidate → IO Bool
stepBuilding service hands vs serial prep candidate = case cdWanted candidate of
  _ : _ → do
    let (batch, rest) = splitAt (profileBuilds (tvProfile (svConfig service))) (cdWanted candidate)
    built ← buildEach batch []
    case built of
      (made, Nothing) → do
        let candidate' = candidate {cdWanted = drop (length made) batch <> rest, cdBuilt = cdBuilt candidate <> Map.fromList made}
        atomically (writeBack service vs serial (Building prep candidate'))
      (made, Just (BuildBackpressure _)) → do
        -- the staging is full now: the built prefix is kept, and an upload's completion asks for the next step
        let candidate' = candidate {cdWanted = drop (length made) batch <> rest, cdBuilt = cdBuilt candidate <> Map.fromList made}
        False <$ atomically (writeBack service vs serial (Building prep candidate'))
      (made, Just (BuildFailed why)) → do
        let candidate' = candidate {cdBuilt = cdBuilt candidate <> Map.fromList made}
        _ ← atomically (writeBack service vs serial (Building prep candidate'))
        False <$ atomically (refuse service vs serial (prepBasis prep) (LimitFailure ("a chunk could not be built: " <> why)))
  [] → do
    standings ← atomically (forM (Map.elems (cdBuilt candidate)) (ownerStanding (portOwner (svPorts service)) . partChunk))
    case () of
      _
        | any failedStanding standings → False <$ atomically (refuse service vs serial (prepBasis prep) (LimitFailure ("a chunk's upload ended without completing: " <> Text.pack (show [s | s ← standings, failedStanding s]))))
        | all (== Just ChunkReady) standings → publish service vs serial prep candidate
        | otherwise → pure False
  where
    failedStanding = \case
      Just (ChunkFailed _) → True
      Nothing → True
      _ → False
    -- each chunk occupies its target's slot in the transaction that records it
    buildEach [] acc = pure (reverse acc, Nothing)
    buildEach ((key, instances, records) : more) acc =
      mask $ \_ →
        handBuild hands instances records >>= \case
          Left why → pure (reverse acc, Just why)
          Right chunk → do
            atomically (occupy service (vtKey (vsTarget vs)) 1)
            buildEach more ((key, Part chunk instances records) : acc)

occupy ∷ Ord k ⇒ TerrainViews k → k → Int → STM ()
occupy service key n = modifyTVar' (svSlots service) (Map.alter (\held → nonZero (fromMaybe 0 held + n)) key)
  where
    nonZero 0 = Nothing
    nonZero v = Just v

-- Publish the candidate as one revision, in the transaction that rechecks the claim, the target, the arena's
-- revisions, the intent and the metrics; what the revision no longer lists starts retiring.
publish ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Prep → Candidate → IO Bool
publish service vs serial prep candidate = do
  let ports = svPorts service
      parts = cdReused candidate <> cdBuilt candidate
      chunks = map partChunk (Map.elems parts)
      material = ownerMaterial (portOwner ports)
      plan = cdPlan candidate
  revision ← atomically (stateTVar (vsNextRevision vs) (\r → (r, r + 1)))
  case terrainView plan (cdAdapted candidate) [(material, MaterialData [] (adaptedPush (cdAdapted candidate)))] [WorldLayerWith DepthEnabled chunks []] of
    Left why → False <$ atomically (refuse service vs serial (prepBasis prep) (LimitFailure ("the view could not be made: " <> Text.pack (show why))))
    Right view → do
      let world =
            SceneWorld
              { worldTag = WorldTag (vsId vs) revision
              , worldClear = tvClear (svConfig service)
              , worldView = view
              , worldMetrics = prepMetrics prep
              , worldChunks = Set.fromList chunks
              , worldTextures = vsStyleIds vs
              }
      scene ← prepare (worldGraphicsScene world)
      atomically $ do
        current ← readTVar (vsStageSerial vs)
        status ← readTVar (vsStatus vs)
        basis ← currentBasis service vs
        claim ← claimOf (portClaims ports) (vtKey (vsTarget vs))
        usable ← vtUsable (vsTarget vs)
        open ← readTVar (svOpen service)
        let mine = fmap claimView claim == Just (vsId vs)
        if current /= serial || status /= ViewOpen || not open || not mine || not usable || basis /= prepBasis prep
          then do
            -- overtaken: the private builds go, and the newer state is prepared next
            _ ← takeStage service vs
            pure True
          else
            vtPublish (vsTarget vs) scene >>= \case
              False → False <$ refuse service vs serial (prepBasis prep) (LimitFailure "the host refused the publication")
              True → do
                _ ← markClaimPublished (portClaims ports) (vtKey (vsTarget vs)) (vsId vs)
                old ← readTVar (vsParts vs)
                let superseded = [partChunk part | (key, part) ← Map.toList old, Map.notMember key (cdReused candidate)]
                unless (null superseded) $
                  modifyTVar' (svRetiring service) (|> Retiring (vtKey (vsTarget vs)) (vsId vs) superseded Unasked False)
                writeTVar (vsParts vs) parts
                writeTVar (vsPublished vs) (Just (revision, prepBasis prep))
                writeTVar (vsRefused vs) Nothing
                writeTVar (vsStage vs) Idle
                -- the pins: the drawn revision's plan and this successor's
                drawn ← fmap (tagRevision . drawnTag) <$> readReceipt (portReceipts ports) (vsId vs)
                let copies = cdCopies candidate
                    pin = Pinned plan (copyArena copies, copyContent copies, copyKnowledge copies, copyGeneration copies)
                modifyTVar' (vsPins vs) (Map.insert revision pin . Map.filterWithKey (\r _ → Just r == drawn))
                pure False

-- ---------------------------------------------------------------------------
-- Retirement

-- Ask the release lane for every retirement's barrier in publication order, stopping at the first the lane refuses;
-- read the answers of those asked. Answers whether anything moved.
askBarriers ∷ (Ord k, Show k) ⇒ TerrainViews k → STM Bool
askBarriers service = do
  open ← readTVar (svOpen service)
  entries ← readTVar (svRetiring service)
  (moved, entries') ← go open False Seq.empty (toList entries)
  when moved (writeTVar (svRetiring service) entries')
  pure moved
  where
    go _ moved done [] = pure (moved, done)
    go open moved done (entry : rest) = case rtBarrier entry of
      _ | rtProtected entry && open → go open moved (done |> entry) rest
      Unasked →
        ownerRelease (portOwner (svPorts service)) (kick service) >>= \case
          Left _ → pure (moved, done <> Seq.fromList (entry : rest))
          Right reading → go open True (done |> entry {rtBarrier = Asked reading}) rest
      Asked reading →
        reading >>= \case
          Just True → go open True (done |> entry {rtBarrier = Met}) rest
          Just False → failChunks entry "the release lane will never meet the barrier" >> go open True (done |> entry {rtBarrier = Met, rtChunks = []}) rest
          Nothing → go open moved (done |> entry) rest
      Met → go open moved (done |> entry) rest
    failChunks entry why = modifyTVar' (svFailed service) (<> [(rtTarget entry, Just chunk, why) | chunk ← rtChunks entry])

-- Dispose of what can go now, on the owner's thread: private builds whose upload has ended, and retiring chunks whose
-- barrier is met and that no adopted revision holds. Each chunk on its own; a failed disposal keeps its identity, its
-- slot and its cause. Answers whether it disposed of anything.
retire ∷ (Ord k, Show k) ⇒ TerrainViews k → Hands → IO Bool
retire service hands = do
  _ ← atomically (askBarriers service)
  (private, retiring) ← atomically $ do
    private ← readTVar (svPrivate service)
    ready ← filterM' (\(_, _, chunk) → notUploading chunk) private
    entries ← readTVar (svRetiring service)
    open ← readTVar (svOpen service)
    candidates ← fmap concat . forM (toList entries) $ \entry → case rtBarrier entry of
      Met | not (rtProtected entry && open) → filterM' (\(_, chunk) → (&&) <$> (not <$> ledgerChunkHeld (portLedger (svPorts service)) chunk) <*> notUploading chunk) [(rtTarget entry, chunk) | chunk ← rtChunks entry]
      _ → pure []
    pure (ready, candidates)
  disposedPrivate ← forM (take budget private) $ \(key, _, chunk) → disposeOne key chunk >>= \ok → pure (ok, chunk)
  disposedRetiring ← forM (take budget retiring) $ \(key, chunk) → disposeOne key chunk >>= \ok → pure (ok, chunk)
  let gone = Set.fromList (map snd (disposedPrivate <> disposedRetiring))
  atomically $ do
    modifyTVar' (svPrivate service) (filter (\(_, _, chunk) → Set.notMember chunk gone))
    modifyTVar' (svRetiring service) (Seq.filter (not . null . rtChunks) . fmap (\entry → entry {rtChunks = filter (`Set.notMember` gone) (rtChunks entry)}))
  pure (not (Set.null gone))
  where
    budget = 64
    notUploading chunk = (/= Just ChunkUploading) <$> ownerStanding (portOwner (svPorts service)) chunk
    disposeOne key chunk =
      mask $ \_ →
        handDispose hands chunk >>= \case
          Right () → do
            atomically $ do
              occupy service key (-1)
              modifyTVar' (svFreed service) (+ 1)
            pure ()
          Left why → atomically (modifyTVar' (svFailed service) (<> [(key, Just chunk, "the chunk's release failed: " <> why)]))

filterM' ∷ Monad m ⇒ (a → m Bool) → [a] → m [a]
filterM' p = fmap catMaybes . mapM (\x → (\keep → if keep then Just x else Nothing) <$> p x)

-- ---------------------------------------------------------------------------
-- Observation

-- | What a view shows now.
data ViewReading = ViewReading
  { readingStatus ∷ !ViewStatus
  , readingPublished ∷ !(Maybe Word64)
    -- ^ The view's latest published revision.
  , readingDrawn ∷ !(Maybe Drawn)
    -- ^ What its target drew, at the last presentation's enqueue or offscreen submission.
  , readingRefusal ∷ !(Maybe BindingLimit)
    -- ^ The limit the view is refused at, while it is.
  , readingRefusals ∷ !Natural
    -- ^ How many times the view entered refusal.
  , readingChunks ∷ !Int
    -- ^ Chunks the published revision lists.
  }
  deriving (Eq, Show)

readView ∷ TerrainView k → STM ViewReading
readView (TerrainView service vs) =
  ViewReading
    <$> readTVar (vsStatus vs)
    <*> (fmap fst <$> readTVar (vsPublished vs))
    <*> readReceipt (portReceipts (svPorts service)) (vsId vs)
    <*> (fmap fst <$> readTVar (vsRefused vs))
    <*> readTVar (vsRefusals vs)
    <*> (Map.size <$> readTVar (vsParts vs))

-- | The revision a view's target drew, for picking (#715): its tag, the frame's metrics, how many drawings the view
-- has had, and the drawn plan with the arena version it was copied from while it is pinned ('Nothing' once a
-- successor's pin replaced it).
data DrawnPlan = DrawnPlan
  { drawnPlanReceipt ∷ !Drawn
  , drawnPlanPlan ∷ !(Maybe CellPlan)
  , drawnPlanArena ∷ !(Maybe (ArenaId, Revision, Revision, Word64))
  }

viewDrawn ∷ TerrainView k → STM (Maybe DrawnPlan)
viewDrawn (TerrainView service vs) =
  readReceipt (portReceipts (svPorts service)) (vsId vs) >>= \case
    Nothing → pure Nothing
    Just drawn → do
      pin ← Map.lookup (tagRevision (drawnTag drawn)) <$> readTVar (vsPins vs)
      pure (Just (DrawnPlan drawn (pinPlan <$> pin) (pinCopies <$> pin)))

-- | The service's resources now.
data ServiceReading k = ServiceReading
  { serviceViews ∷ !Int
  , serviceOccupied ∷ !(Map k Int)
    -- ^ Each target's occupied slots: candidate, drawn, retiring and failed chunks.
  , serviceRetiring ∷ !Int
  , servicePrivate ∷ !Int
  , serviceFailures ∷ ![(k, Maybe ChunkRef, Text)]
  , serviceReserved ∷ !Integer
  , servicePlanningMax ∷ !Word64
    -- ^ The greatest owner-thread planning time within one frame, in nanoseconds.
  }

readTerrainViews ∷ TerrainViews k → STM (ServiceReading k)
readTerrainViews service =
  ServiceReading
    <$> (Map.size <$> readTVar (svViews service))
    <*> readTVar (svSlots service)
    <*> (sum . fmap (length . rtChunks) <$> readTVar (svRetiring service))
    <*> (length <$> readTVar (svPrivate service))
    <*> readTVar (svFailed service)
    <*> pure (svReserved service)
    <*> ((\a b → max a b) <$> readTVar (svPlanningMax service) <*> readTVar (svPlanningFrame service))
