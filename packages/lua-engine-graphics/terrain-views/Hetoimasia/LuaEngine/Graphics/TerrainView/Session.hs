{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}

-- | The session-owned terrain views (TRA-9): one view per target incarnation, prepared and published by the
-- graphics owner in bounded steps, retired first in, first out.
--
-- = One owner
--
-- Every step of every view runs on the graphics owner's thread, inside one owner action, between frames
-- ('stepOwner'). Nothing else builds, publishes or disposes. A step is asked for by a /kick/: one transaction that
-- admits the next owner action unless one is already queued, and never waits. Kicks come from the controls, the
-- regional snapshot's settlement, the scene ledger's adoptions and releases, the host's frame events, the release
-- lane's barrier actions, a step that leaves work it can do at once, and one signal-only watcher thread
-- ('withTerrainViews' starts and joins it). The watcher blocks on the views' arena mark cells and the terrain
-- service's authority epoch (so an edit, a discovery or a lost lease reaches an idle window) and on the views' own
-- outstanding work: a kick the owner's queue refused, a release-lane barrier it can now ask for, a chunk it can now
-- dispose of, a disposal the backend confirmed, an offscreen batch that completed. It also observes the owner's end:
-- an admission refused for good, or an admitted step the owner refused or that raised, stops admission and ends every
-- view. Nothing waits for capacity: an unaffordable replacement is refused, the target keeps its drawing, and a later
-- relevant change prompts a fresh attempt.
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
-- A chunk occupies one of its target's slots from its build to its physical disposal, which the backend confirms. At
-- every moment a chunk has exactly one holder: the stage's candidate, the published revision, the retirement queue,
-- the private builds, the owner's hand while it releases the chunk, the disposals awaiting confirmation, or the
-- failures; it leaves one in the transaction that hands it to the next. What a published revision no longer lists
-- asks the host's FIFO release lane for a barrier, in publication order, and is released once that barrier is met
-- and no adopted revision holds it; a private build that never reached a revision is released once its upload has
-- ended. Independent chunks may finish in either order. A release or disposal that fails keeps the chunk's
-- identity, its slot and its cause, and the others go on.
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

    -- * Targets and styles
  , ViewTarget (..)
  , ViewStyle (..)
  , retainedStyle

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
  , viewReadings
  , DrawnPlan (..)
  , viewDrawn
  , viewCellConfig
  , viewSetup
  , ServiceReading (..)
  , readTerrainViews
  ) where

import Control.Concurrent.STM
import Control.Applicative ((<|>))
import Control.Exception (Exception, SomeAsyncException, SomeException, displayException, evaluate, fromException, mask, onException, rethrowIO, throwIO, try, tryWithContext, uninterruptibleMask_)
import Control.Monad (filterM, forM, forM_, unless, void, when)
import Data.Foldable (for_, toList)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, mapMaybe, maybeToList)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare)
import Hetoimasia.Foundation.Resource (composeCleanup, withResourceLabelled)
import Hetoimasia.Foundation.Worker (StartOutcome (..), closeWorkerGroup, requestStop, startWorker, stopRequested, withWorkerGroup, workerDefinition)
import Hetoimasia.LuaEngine.Graphics.Scene.Claims (SceneClaims, claimOf, Claim (..), markClaimPublished, newClaimHolder, releaseClaim, takeClaim)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene, SceneLedger, ledgerChunkHeld, ledgerDropInterest, ledgerListen, ledgerRetainInterest, ledgerTagHeld, worldGraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Scene.Receipts (DrawReceipts, Drawn (..), forgetReceipt, openReceipt, readReceipt, receiptsListen, sweepOffscreen)
import Hetoimasia.LuaEngine.Graphics.Scene.World (SceneWorld (..), WorldTag (..))
import Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs (CopySet (..), combineCopies, planInputs, plannerRuns)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Owner (BuildFailure (..), ConstructedDisposal (..), Hands (..), OwnerPorts (..), ScheduleRefusal (..), StepOutcome (..))
import Hetoimasia.LuaEngine.Graphics.TerrainView.Profile
import Hetoimasia.LuaEngine.Graphics.TerrainView.Style (StyleRefusal (..), StyleRequest (styleColourLease, styleLeases, styleNormalLease), acquireStyle, releaseStyle, styleAssets, styleIdentities, styleMappedMaterials, styleTextures)
import Hetoimasia.Scripting.Lua.Lease (leaseLiveSTM)
import Hetoimasia.Terrain.Cell (MaterialId)
import Hetoimasia.Terrain.Palette (paletteMaterials)
import Hetoimasia.Terrain.Render2D.Assets (AssetSnapshot)
import Hetoimasia.Terrain.Render2D.Material (AtlasTextures)
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
import Hetoimasia.Terrain.Render2D.Camera (CameraConfig, CameraError, CameraState, Command (..), FollowOutcome (..), JumpEvent (..), JumpId (..), JumpTarget (..), PendingJump (..), Step (..), applyCommand, cancelJump, camAnchorX, camAnchorY, camClip, camPending, completeJump, defaultCameraConfig, newCamera, refollow)
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Facts (ChunkDemand (..), ChunkKey (..), Demand (..), TerrainFacts (..))
import Hetoimasia.Terrain.Render2D.Knowledge (Knowledge)
import Hetoimasia.Terrain.Render2D.Material (Adapted (..), AdaptedQuad (..), adaptCells, adaptedInstance, terrainView)
import Hetoimasia.Terrain.Render2D.Presentation (LightSettings)
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..))
import Hetoimasia.Terrain.Residency (ArenaId (..), RegionDemand (..), Revision (..), coverageBox, limitCameraRegions)
import Hetoimasia.Terrain.Runtime (ArenaMark (..), ArenaView (viewGeneration, viewKnowledgeRevision, viewPalette, viewRevision), Settlement (..))
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

-- | A target a view attaches to: its incarnation's key, whether it is usable, the caller's original authority over it
-- (its window lease, checked in the open's commit), its latest-value publication as the host's own transaction,
-- what the view binds and unbinds on it from its open to its close, whether its frames carry the qualified depth
-- image and the metrics its next frame is recorded with.
data ViewTarget k = ViewTarget
  { vtKey ∷ !k
  , vtUsable ∷ STM Bool
  , vtAuthority ∷ STM Bool
  , vtBind ∷ STM ()
  , vtUnbind ∷ STM ()
  , vtPublish ∷ Prepared GraphicsScene → STM Bool
  , vtDepth ∷ !Bool
  , vtMetrics ∷ STM (Maybe TargetMetrics)
  }

-- | A view's style: the checked asset snapshot over the two atlas parents' shared coverage planes, the bound
-- textures, the parents' complete identities (which the view holds interests in and its revisions name), the
-- materials its mapping gives a region (the arena's palette must be among them), whether the original leases of its
-- parents are still live (checked in the open's commit, with the interests taken in the same transaction), and the
-- release of what was retained for it, run once when the view ends.
data ViewStyle = ViewStyle
  { styleSnapshot ∷ !AssetSnapshot
  , styleBound ∷ !AtlasTextures
  , styleParents ∷ !(Set Word64)
  , styleMapped ∷ !(Set MaterialId)
  , styleLive ∷ STM Bool
  , styleRelease ∷ IO ()
  }

-- | The style of an owning instance's two retained parents ("Hetoimasia.LuaEngine.Graphics.TerrainView.Style").
retainedStyle ∷ StyleRequest → IO (Either StyleRefusal ViewStyle)
retainedStyle request =
  acquireStyle request >>= pure . fmap (\style → ViewStyle (styleAssets style) (styleTextures style) (styleIdentities style) (styleMappedMaterials style) live (releaseStyle style))
  where
    live = (&&) <$> leaseLiveSTM (styleLeases request) (styleColourLease request) <*> leaseLiveSTM (styleLeases request) (styleNormalLease request)

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
  , prepRuns ∷ !Int
    -- ^ The input runs and intervals of the copies taken so far, as the planner is handed them.
  }

data Stage
  = Idle
  | Copying !Prep ![RegionCoord] ![Runtime.RegionSnapshot] !(Maybe InFlight)
  | Inputting !Prep ![Runtime.RegionSnapshot] !(TMVar (Either BindingLimit (CopySet, TerrainFacts, Knowledge)))
    -- ^ The planner makes the copies' inputs.
  | Planning !Prep !CopySet !(TMVar (Either BindingLimit Planned))
    -- ^ The planner makes the plan and, when its copies suffice, the candidate's parts.
  | Building !Prep !Candidate

-- What the planner hands back for a plan: the plan, its visible and prefetch regions, and either the regions another
-- copy round asks for or the adapted candidate's parts (with whether the visible demand was left incomplete).
data Planned = Planned
  { plannedPlan ∷ !CellPlan
  , plannedCamera ∷ !CameraState
  , plannedVisible ∷ ![RegionCoord]
  , plannedPrefetch ∷ ![RegionCoord]
  , plannedNext ∷ !(Either [RegionCoord] (Adapted, [(PartKey, [Instance], [MaterialRecord])], Bool))
  }

data Candidate = Candidate
  { cdPlan ∷ !CellPlan
  , cdCopies ∷ !CopySet
  , cdAdapted ∷ !Adapted
  , cdWanted ∷ ![(PartKey, [Instance], [MaterialRecord])]
  , cdBuilt ∷ !(Map PartKey Part)
  , cdReused ∷ !(Map PartKey Part)
  , cdCamera ∷ !CameraState
  , cdIncomplete ∷ !Bool
    -- ^ The plan's visible demand names regions its copies did not ask for: the published revision is coherent, with
    -- that coverage loading, and the view prepares again to copy it.
  }

-- | A plan a view keeps for its target: the drawn revision's and one successor's.
data Pinned = Pinned
  { pinPlan ∷ !CellPlan
  , pinCopies ∷ !(ArenaId, Revision, Revision, Word64)
  , pinRegions ∷ !(Set RegionCoord)
  , pinCamera ∷ !CameraState
  , pinMetrics ∷ !TargetMetrics
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
  | LimitRegions !Int !Int
    -- ^ The regions a preparation needed, and those its copy rounds and the profile's regions could ask for.
  | LimitPlan !HaltReason
    -- ^ The plan met one of the profile's plan-wide bounds (columns, levels, quads, pending spans).
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
  , vsStyle ∷ !ViewStyle
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
  , vsPublished ∷ !(TVar (Maybe (Word64, Basis, Bool)))
    -- ^ The published revision, the basis it was prepared from, and whether its visible demand was incomplete.
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

data Barrier = Unasked | Asked !(STM (Maybe (Either Text ()))) | Met

-- | Chunks a published revision no longer lists, in publication order.
data Retiring k = Retiring
  { rtTarget ∷ !k
  , rtView ∷ !Word64
  , rtChunks ∷ ![ChunkRef]
  , rtBarrier ∷ !Barrier
  , rtProtected ∷ !Bool
    -- ^ A failed handback left the scene that lists them current: kept until the service ends.
  }

-- | A chunk a view built, with its target and view.
type Held k = (k, Word64, ChunkRef)

data TerrainViews k = TerrainViews
  { svConfig ∷ !TerrainViewsConfig
  , svPorts ∷ !(TerrainViewsPorts k)
  , svViews ∷ !(TVar (Map Word64 (ViewState k)))
  , svSlots ∷ !(TVar (Map k Int))
    -- ^ Each target's occupied slots: candidate, drawn, retiring, disposing and failed chunks.
  , svRetiring ∷ !(TVar (Seq (Retiring k)))
  , svPrivate ∷ !(TVar [Held k])
    -- ^ Built chunks no revision listed: released once their upload has ended.
  , svInHand ∷ !(TVar [Held k])
    -- ^ Chunks the owner is releasing now.
  , svDisposing ∷ !(TVar [(Held k, STM ConstructedDisposal)])
    -- ^ Released chunks whose physical disposal the backend has not yet confirmed.
  , svFailed ∷ !(TVar [(k, Maybe ChunkRef, Text)])
    -- ^ Terminal failures, with their causes: a chunk whose release or disposal failed keeps its identity and its slot.
  , svOpen ∷ !(TVar Bool)
  , svScheduled ∷ !(TVar Bool)
    -- ^ A step was admitted and has not started.
  , svStep ∷ !(TVar (Maybe (STM (Maybe StepOutcome))))
    -- ^ How the latest admitted step ended, once it has.
  , svEnded ∷ !(TVar (Maybe Text))
    -- ^ The graphics owner takes no more steps, and why: admission is stopped.
  , svKickWanted ∷ !(TVar Bool)
  , svFreed ∷ !(TVar Natural)
  , svPlanningFrame ∷ !(TVar Word64)
  , svPlanningMax ∷ !(TVar Word64)
  , svPlanningStep ∷ !(TVar Word64)
    -- ^ The planning time of the owner step under way.
  , svPlanningStepMax ∷ !(TVar Word64)
    -- ^ The greatest planning time of one owner step.
  , svOwnerFrame ∷ !(TVar Word64)
    -- ^ The owner's time in the views' steps since the last presentation's enqueue.
  , svOwnerMax ∷ !(TVar Word64)
  , svOwnerStepMax ∷ !(TVar Word64)
  , svJobs ∷ !(TVar (Map Word64 (IO ())))
    -- ^ The planner's queue: each view's latest job, which a newer one replaces before it starts.
  , svReserved ∷ !Integer
  }

-- ---------------------------------------------------------------------------
-- The service's scope

-- | Make the service, run the body, and on every exit end every view, drain every retirement (with the graphics
-- owner live) and return the reservation. Refused before anything is reserved or started for a profile that cannot
-- work or an account that cannot hold the allowance.
--
-- The reservation is a resource scope ("Hetoimasia.Foundation.Resource"): reserved masked, returned however the rest
-- ends. Inside it the listeners are installed, the watcher and the planner run beside the body, and on every exit the
-- views end and their retirements drain (masked, its wait for the owner interruptible) before the listeners are
-- removed. The drain's failure is kept beside the body's ('composeCleanup'), or raised when the body succeeded.
withTerrainViews ∷ (Ord k, Show k) ⇒ TerrainViewsConfig → TerrainViewsPorts k → (TerrainViews k → IO a) → IO a
withTerrainViews config ports body = do
  profile ← either (throwIO . TerrainViewsProfile) pure (checkProfile (tvProfile config))
  let allowance = reserveTotal (reservation profile)
      account = portAccount ports
      reserve = do
        reserved ←
          atomically $
            if allowance > toInteger (maxBound ∷ Word64)
              then pure False
              else accountReserve account (fromInteger allowance)
        unless reserved $ throwIO (TerrainViewsAccount allowance (-1))
  withResourceLabelled "terrain views: the account reservation" reserve (\() → atomically (accountRelease account (fromInteger allowance))) $ \() → do
    service ← newService config ports allowance
    let listen = do
          ledgerListen (portLedger ports) (kick service)
          receiptsListen (portReceipts ports) (\presented → when presented (frameEnded service) >> kick service)
        unlisten = do
          ledgerListen (portLedger ports) (pure ())
          receiptsListen (portReceipts ports) (const (pure ()))
    mask $ \restore → do
      atomically listen
      outcome ←
        tryWithContext . restore . withWorkerGroup $ \group → do
          started ← startWorker group (workerDefinition "terrain-views-watcher" (\_ → pure ()) (\token () → watch service (stopRequested token)))
          planner ← startWorker group (workerDefinition "terrain-views-planner" (\_ → pure ()) (\token () → runPlanner service (stopRequested token)))
          case (started, planner) of
            (Started worker, Started planning) → do
              let stop = atomically (requestStop worker >> requestStop planning)
              result ← body service `onException` (stop >> void (closeWorkerGroup group))
              stop
              _ ← closeWorkerGroup group
              pure result
            _ → throwIO (TerrainViewsWatcher "the watcher or the planner did not start")
      drainedOrNot ← tryWithContext (shutdown service)
      atomically unlisten
      case (outcome, drainedOrNot) of
        (Right result, Right ()) → pure result
        (Right _, Left failure) → rethrowIO failure
        (Left primary, Right ()) → rethrowIO primary
        (Left primary, Left failure) → composeCleanup (Just primary) [("terrain views: the drain", failure)] >>= maybe (rethrowIO primary) rethrowIO

newService ∷ TerrainViewsConfig → TerrainViewsPorts k → Integer → IO (TerrainViews k)
newService config ports allowance = do
  views ← newTVarIO Map.empty
  slots ← newTVarIO Map.empty
  retiring ← newTVarIO Seq.empty
  private ← newTVarIO []
  inHand ← newTVarIO []
  disposing ← newTVarIO []
  failed ← newTVarIO []
  open ← newTVarIO True
  scheduled ← newTVarIO False
  step ← newTVarIO Nothing
  ended ← newTVarIO Nothing
  wanted ← newTVarIO False
  freed ← newTVarIO 0
  [planningFrame, planningMax, planningStep, planningStepMax, ownerFrame, ownerMax, ownerStepMax] ← mapM newTVarIO (replicate 7 0)
  jobs ← newTVarIO Map.empty
  pure
    TerrainViews
      { svConfig = config
      , svPorts = ports
      , svViews = views
      , svSlots = slots
      , svRetiring = retiring
      , svPrivate = private
      , svInHand = inHand
      , svDisposing = disposing
      , svFailed = failed
      , svOpen = open
      , svScheduled = scheduled
      , svStep = step
      , svEnded = ended
      , svKickWanted = wanted
      , svFreed = freed
      , svPlanningFrame = planningFrame
      , svPlanningMax = planningMax
      , svPlanningStep = planningStep
      , svPlanningStepMax = planningStepMax
      , svOwnerFrame = ownerFrame
      , svOwnerMax = ownerMax
      , svOwnerStepMax = ownerStepMax
      , svJobs = jobs
      , svReserved = allowance
      }

-- The watcher: signals only. It blocks until a view's arena mark or the authority epoch moves, until the views' own
-- outstanding work can go on (a refused kick, a barrier to ask, a chunk to release, a confirmed disposal, a completed
-- offscreen batch), or until the owner has ended; then it asks for the owner's next step, or ends every view.
watch ∷ (Ord k, Show k) ⇒ TerrainViews k → STM Bool → IO ()
watch service stopping = loop
  where
    loop =
      atomically ((Nothing <$ (stopping >>= check)) `orElse` (Just <$> wake)) >>= \case
        Nothing → pure ()
        Just ending → do
          forM_ ending $ \vs → endView service vs EndStopped
          loop
    wake =
      ownerGone service >>= \case
        Just _ → do
          -- admission is stopped: every view ends, which settles its pending moves
          views ← Map.elems <$> readTVar (svViews service)
          if null views then retry else pure views
        Nothing → [] <$ (marks `orElse` work)
    marks = do
      views ← Map.elems <$> readTVar (svViews service)
      epoch ← Runtime.authorityEpochSTM (portTerrain (svPorts service))
      moved ← fmap or . forM views $ \vs → do
        mark ← vsMarkCell vs
        seen ← readTVar (vsSeen vs)
        if seen == (mark, epoch) then pure False else True <$ writeTVar (vsSeen vs) (mark, epoch)
      if moved then kick service else retry
    work = do
      swept ← sweepOffscreen (portReceipts (svPorts service))
      asked ← askBarriers service
      queued ← stepQueued service
      wanted ← readTVar (svKickWanted service)
      ready ← if queued then pure False else retirementReady service
      if
        | swept || asked → kick service
        | not queued && (wanted || ready) → admit service >>= check
        | otherwise → retry

-- The planner: one thread that runs the views' pure planning, latest job first come, and hands each result back to
-- its stage, asking for the owner's next step. It owns nothing; a result whose stage was abandoned is dropped.
runPlanner ∷ (Ord k, Show k) ⇒ TerrainViews k → STM Bool → IO ()
runPlanner service stopping = loop
  where
    loop =
      atomically ((stopping >>= check >> pure Nothing) `orElse` (Just <$> takeJob)) >>= \case
        Nothing → pure ()
        Just job → job >> loop
    takeJob = do
      jobs ← readTVar (svJobs service)
      case Map.minViewWithKey jobs of
        Nothing → retry
        Just ((_, job), rest) → job <$ writeTVar (svJobs service) rest

-- Queue a view's planning job: the work, evaluated on the planner's thread, then its result handed to the box and the
-- owner kicked. A failure of the pure work is the job's result, never the planner's end.
submitJob ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → (() → Either BindingLimit a) → TMVar (Either BindingLimit a) → STM ()
submitJob service vs work box =
  modifyTVar' (svJobs service) . Map.insert (vsId vs) $ do
    result ←
      try (evaluate (work ())) >>= \case
        Left failure | Just (_ ∷ SomeAsyncException) ← fromException failure → throwIO failure
        Left failure → pure (Left (LimitFailure ("the planner raised: " <> Text.pack (displayException failure))))
        Right value → pure value
    atomically (void (tryPutTMVar box result) >> kick service)

-- | Ask for the owner's next step: one admission, unless one is already queued or the owner has ended. Never waits.
kick ∷ (Ord k, Show k) ⇒ TerrainViews k → STM ()
kick service = do
  queued ← stepQueued service
  ended ← readTVar (svEnded service)
  unless (queued || isJust ended) (void (admit service))

-- Admit one step. Answers whether anything changed: a step admitted, or the owner found ended (a full queue or a
-- device not yet ready leaves the kick wanted, for the watcher to admit once the queue changes).
admit ∷ (Ord k, Show k) ⇒ TerrainViews k → STM Bool
admit service =
  ownerSchedule (portOwner (svPorts service)) (stepOwner service) >>= \case
    Right reading → do
      writeTVar (svScheduled service) True
      writeTVar (svStep service) (Just reading)
      writeTVar (svKickWanted service) False
      pure True
    Left ScheduleBusy → False <$ writeTVar (svKickWanted service) True
    Left (ScheduleEnded why) → True <$ endOwner service ("the graphics owner takes no more steps: " <> why)

-- Whether an admitted step has not yet started (a step the owner refused before it ran has ended).
stepQueued ∷ TerrainViews k → STM Bool
stepQueued service = do
  scheduled ← readTVar (svScheduled service)
  if not scheduled then pure False else stepUnsettled service

-- Whether the latest admitted step is queued or running.
stepUnsettled ∷ TerrainViews k → STM Bool
stepUnsettled service = readTVar (svStep service) >>= maybe (pure False) (fmap isNothing)

-- Stop admission for good, with the cause.
endOwner ∷ TerrainViews k → Text → STM ()
endOwner service why = do
  readTVar (svEnded service) >>= \case
    Nothing → writeTVar (svEnded service) (Just why)
    Just _ → pure ()
  writeTVar (svScheduled service) False

-- Whether the owner has ended: its session failed, it refused admission for good, or it refused or failed an admitted
-- step. The first answer stops admission.
ownerGone ∷ TerrainViews k → STM (Maybe Text)
ownerGone service =
  readTVar (svEnded service) >>= \case
    Just why → pure (Just why)
    Nothing → do
      failed ← ownerEnded (portOwner (svPorts service))
      outcome ← readTVar (svStep service) >>= maybe (pure Nothing) id
      let refused = case outcome of
            Just (StepRefused why) → Just ("the graphics owner refused a step: " <> why)
            Just (StepRaised why) → Just ("a step raised: " <> why)
            _ → Nothing
          gone = (("the graphics owner ended: " <>) <$> failed) <|> refused
      for_ gone (endOwner service)
      pure gone

-- A presentation was enqueued: the planning time of the frame it ends is recorded.
frameEnded ∷ TerrainViews k → STM ()
frameEnded service = do
  spent ← readTVar (svPlanningFrame service)
  modifyTVar' (svPlanningMax service) (max spent)
  writeTVar (svPlanningFrame service) 0
  owned ← readTVar (svOwnerFrame service)
  modifyTVar' (svOwnerMax service) (max owned)
  writeTVar (svOwnerFrame service) 0

-- Close admission, end every view, and drain what retires, with the owner live: the drain waits in STM for the
-- outstanding step and the retirements, asking the release lane and the owner itself, until they are done or the owner
-- has ended. Chunks a failed handback protects, which a live target's current scene still lists, are handed to the
-- session's teardown (which destroys what its managed resources hold) and recorded as such.
--
-- It runs masked, not uninterruptibly: the drain's wait for the owner stays interruptible. An interruption is answered: what was still retiring is recorded as failures with that cause and
-- the interruption is raised, after a view's ending failure if one came first, both kept by the scope.
shutdown ∷ (Ord k, Show k) ⇒ TerrainViews k → IO ()
shutdown service = do
  views ← atomically $ do
    writeTVar (svOpen service) False
    Map.elems <$> readTVar (svViews service)
  endings ← forM views $ \vs → try (endView service vs EndStopped)
  drainedOrNot ← try drain
  case drainedOrNot of
    Right () → pure ()
    Left interruption → atomically (abandonRetirements service ("the drain was interrupted: " <> Text.pack (displayException (interruption ∷ SomeException))))
  forM_ [failure | Left failure ← endings] (throwIO ∷ SomeException → IO ())
  either throwIO pure drainedOrNot
  where
    drain = do
      again ← atomically $ do
        ownerGone service >>= \case
          Just why → False <$ abandonRetirements service ("the graphics owner ended before disposal: " <> why)
          Nothing → do
            handOffProtected service
            running ← stepUnsettled service
            done ← drained service
            if
              | running → retry
              | done → pure False
              | otherwise → do
                  asked ← askBarriers service
                  ready ← retirementReady service
                  if asked || ready then admit service >>= check >> pure True else retry
      when again drain

-- Whether nothing of the views' chunks is left to dispose of.
drained ∷ TerrainViews k → STM Bool
drained service = do
  retiring ← readTVar (svRetiring service)
  private ← readTVar (svPrivate service)
  inHand ← readTVar (svInHand service)
  disposing ← readTVar (svDisposing service)
  pure (Seq.null retiring && null private && null inHand && null disposing)

-- At the service's end: chunks a failed handback protects that an adopted revision still holds go to the session's
-- teardown, recorded with that cause; their slots stay occupied.
handOffProtected ∷ TerrainViews k → STM ()
handOffProtected service = do
  entries ← readTVar (svRetiring service)
  entries' ← forM entries $ \entry →
    if not (rtProtected entry)
      then pure entry
      else do
        held ← filterM (ledgerChunkHeld (portLedger (svPorts service))) (rtChunks entry)
        unless (null held) $
          modifyTVar' (svFailed service) (<> [(rtTarget entry, Just chunk, "a failed handback left it in its target's current scene: the session's teardown disposes of it") | chunk ← held])
        pure entry {rtChunks = filter (`notElem` held) (rtChunks entry), rtProtected = False}
  writeTVar (svRetiring service) (Seq.filter (not . null . rtChunks) entries')

-- The owner ended for good: what it can no longer dispose of ends as a failure with that cause. The session's managed
-- resources are destroyed with it.
abandonRetirements ∷ TerrainViews k → Text → STM ()
abandonRetirements service cause = do
  retiring ← readTVar (svRetiring service)
  private ← readTVar (svPrivate service)
  inHand ← readTVar (svInHand service)
  disposing ← readTVar (svDisposing service)
  modifyTVar' (svFailed service) $ \failed →
    failed
      <> [(rtTarget r, Just chunk, cause) | r ← toList retiring, chunk ← rtChunks r]
      <> [(k, Just chunk, cause) | (k, _, chunk) ← private <> inHand <> map fst disposing]
  writeTVar (svRetiring service) Seq.empty
  writeTVar (svPrivate service) []
  writeTVar (svInHand service) []
  writeTVar (svDisposing service) []

-- ---------------------------------------------------------------------------
-- Opening

-- | What an attachment names.
data OpenRequest k = OpenRequest
  { openTarget ∷ !(ViewTarget k)
  , openLease ∷ !Runtime.ArenaLease
  , openStyle ∷ IO (Either StyleRefusal ViewStyle)
    -- ^ How the view's style is retained and checked: 'retainedStyle' in production.
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
  | -- | The profile's targets are all in use: by an open view, or by chunks still occupying a closed one's slots.
    OpenTooManyViews
  | -- | The caller's original lease of the window or of a style parent ended before the open's commit.
    OpenLeaseEnded
  | OpenArena !Runtime.Refused
  | OpenCamera !CameraError
  | OpenStopped
  deriving (Eq, Show)

-- | Open a view of an arena on a target. It settles here, at attachment: the style is retained and checked, then
-- one transaction checks the session, the original window and style leases, the target, the arena, the style's
-- coverage of the arena's palette, the targets in use and the exclusive claim shared with M1, and takes the claim,
-- the style's GPU interests, the receipt and the view. A target with no frame metrics yet is published the real empty
-- revision in that transaction, which asks it for the first frame its views plan for. A refusal leaves nothing
-- behind.
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
            restore (openStyle request) >>= \case
              Left why → pure (Left (OpenStyle why))
              Right style → do
                let undo = styleRelease style
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

newViewState ∷ TerrainViews k → OpenRequest k → ViewStyle → Runtime.View → STM (Maybe ArenaMark) → CameraState → IO (ViewState k)
newViewState service request style rview markCell camera = do
  incarnation ← atomically (newClaimHolder (portClaims (svPorts service)))
  ViewState incarnation (openTarget request) (openLease request) rview style markCell
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
      key = vtKey target
      style = vsStyle vs
  open ← readTVar (svOpen service)
  ended ← readTVar (svEnded service)
  authority ← (&&) <$> vtAuthority target <*> styleLive style
  usable ← vtUsable target
  views ← readTVar (svViews service)
  slots ← readTVar (svSlots service)
  arena ← Runtime.inspectArenaSTM (portTerrain ports) (vsLease vs)
  let inUse = Set.fromList (map (vtKey . vsTarget) (Map.elems views)) <> Map.keysSet slots
      unmapped = maybe [] (filter (`Set.notMember` styleMapped style) . paletteMaterials . viewPalette) arena
  if
    | not open || isJust ended → pure (Left OpenStopped)
    | not authority → pure (Left OpenLeaseEnded)
    | not usable → pure (Left OpenTargetUnusable)
    | isNothing arena → pure (Left (OpenArena Runtime.RefusedAuthority))
    | not (null unmapped) → pure (Left (OpenStyle (StyleMissingMaterials unmapped)))
    | Set.notMember key inUse && Set.size inUse >= profileTargets (tvProfile (svConfig service)) → pure (Left OpenTooManyViews)
    | otherwise →
        takeClaim (portClaims ports) key (vsId vs) >>= \case
          False → pure (Left OpenTargetClaimed)
          True → do
            forM_ (Set.toList (styleParents style)) (ledgerRetainInterest (portLedger ports))
            writeTVar (svViews service) (Map.insert (vsId vs) vs views)
            openReceipt (portReceipts ports) (vsId vs)
            vtBind target
            metrics ← vtMetrics target
            when (isNothing metrics) (void (vtPublish target (portInitial ports)))
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
  | -- | Recoverable pressure: the preparation that would land it met this limit. The camera stays where it was.
    MovePressure !BindingLimit
  deriving (Eq, Show)

newtype PendingMove = PendingMove (TVar (Maybe MoveOutcome))

moveSettled ∷ PendingMove → STM (Maybe MoveOutcome)
moveSettled (PendingMove box) = readTVar box

-- | Move the camera: a jump to a column, with a level for manual depth or without one to follow the surface. It
-- settles at the camera's eligible transition, at once when the destination's facts are already copied, otherwise
-- when a step has copied them; with recoverable pressure when the preparation that would copy them is refused or
-- cannot ask for them within its copy rounds and regions. A newer move or camera change cancels it; a lighting
-- change does not.
moveView ∷ (Ord k, Show k) ⇒ TerrainView k → JumpTarget → STM (Either ControlRefusal PendingMove)
moveView (TerrainView service vs) target =
  controlled service vs $ \facts camera → case applyCommand (tvCamera (svConfig service)) facts (Jump target) camera of
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
      ended ← readTVar (svEnded service)
      case (status, configureLight update) of
        (ViewEnded _, _) → pure (Left ControlEnded)
        _ | isJust ended → pure (Left ControlEnded)
        (_, Nothing) → pure (Right ())
        (_, Just light) → Right () <$ (writeTVar (vsLight vs) light >> bumpIntent service vs)
  | otherwise =
      controlled service vs $ \facts camera →
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

controlled ∷ TerrainViews k → ViewState k → (TerrainFacts → CameraState → STM (Either ControlRefusal a)) → STM (Either ControlRefusal a)
controlled service vs body = do
  ended ← readTVar (svEnded service)
  readTVar (vsStatus vs) >>= \case
    ViewEnded _ → pure (Left ControlEnded)
    ViewOpen | isJust ended → pure (Left ControlEnded)
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
        held ← (\a b c → a <> b <> map fst c) <$> readTVar (svPrivate service) <*> readTVar (svInHand service) <*> readTVar (svDisposing service)
        pure (if any ((== vsId vs) . rtView) retiring || any (\(_, v, _) → v == vsId vs) held then CloseRetiring else CloseDone)

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
      styleRelease (vsStyle vs)
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
      forM_ (Set.toList (styleParents (vsStyle vs))) (ledgerDropInterest (portLedger ports))
      moves ← readTVar (vsMoves vs)
      forM_ (Map.elems moves) (settleOnce (MoveEnded ending))
      writeTVar (vsMoves vs) Map.empty
      forgetReceipt (portReceipts ports) (vsId vs)
      vtUnbind target
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
  modifyTVar' (svJobs service) (Map.delete (vsId vs))
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
  start ← getMonotonicTimeNSec
  atomically (writeTVar (svScheduled service) False >> writeTVar (svPlanningStep service) 0)
  views ← Map.elems <$> readTVarIO (svViews service)
  busy ← or <$> forM views (stepView service hands)
  retired ← retire service hands
  end ← getMonotonicTimeNSec
  atomically $ do
    readTVar (svPlanningStep service) >>= \spent → modifyTVar' (svPlanningStepMax service) (max spent)
    -- the whole step: everything the views asked of the owner's thread in it
    modifyTVar' (svOwnerFrame service) (+ (end - start))
    modifyTVar' (svOwnerStepMax service) (max (end - start))
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
        Inputting prep taken box
          | stale prep basis → abandon service vs serial >> pure True
          | otherwise → stepInputting service vs serial prep taken box
        Planning prep copies box
          | stale prep basis → abandon service vs serial >> pure True
          | otherwise → stepPlanning service vs serial prep copies box
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
  let failed = [key | (key, Just (ChunkFailed _)) ← standings]
  unless (null failed) $ do
    -- the revision that lists them stays published until a rebuilt one replaces it; they retire behind it
    writeTVar (vsParts vs) (foldr Map.delete parts failed)
    modifyTVar' (svRetiring service) (|> Retiring (vtKey (vsTarget vs)) (vsId vs) (mapMaybe (fmap partChunk . (`Map.lookup` parts)) failed) Unasked False)
    modifyTVar' (vsPublished vs) (fmap (\(revision, at, _) → (revision, at, True)))
    writeTVar (vsRefused vs) Nothing

-- Start a preparation when the published revision is not of the current basis and the view is not refused at it.
startIfDue ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Basis → IO Bool
startIfDue service vs basis = atomically $ do
  published ← readTVar (vsPublished vs)
  refused ← readTVar (vsRefused vs)
  residency ← currentResidency service vs
  freed ← readTVar (svFreed service)
  let due = case published of
        Nothing → True
        Just (_, at, incomplete) → at /= basis || incomplete
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
          -- the anchor's region and a pending jump's destination first, then the demand nearest the anchor
          wanted = take (profileRegions profile) (nubOrdered (anchor : jumpTo <> ordered anchor demand))
      writeTVar (vsStage vs) (Copying (Prep basis metrics (profileRounds profile - 1) (Set.fromList wanted) 0) wanted [] Nothing)
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

-- Write a step's new stage back, unless an ending or an abandonment replaced the stage meanwhile ('False'). No stage
-- written back holds a chunk the step made: a build is handed to the stage, or to disposal, in its own transaction.
writeBack ∷ TerrainViews k → ViewState k → Word64 → Stage → STM Bool
writeBack _ vs serial stage = do
  current ← readTVar (vsStageSerial vs)
  status ← readTVar (vsStatus vs)
  if current == serial && status == ViewOpen
    then True <$ writeTVar (vsStage vs) stage
    else pure False

-- Enter refusal: the current drawing stays; the binding limit is reported once, on entering; the private builds go
-- to disposal, and the pending moves settle with that pressure.
refuse ∷ TerrainViews k → ViewState k → Word64 → Basis → BindingLimit → STM ()
refuse service vs serial basis limit = do
  current ← readTVar (vsStageSerial vs)
  when (current == serial) $ do
    stage ← readTVar (vsStage vs)
    case stage of
      Building _ candidate → privately service vs (map partChunk (Map.elems (cdBuilt candidate)))
      _ → pure ()
    writeTVar (vsStage vs) Idle
    pressure vs limit
    residency ← currentResidency service vs
    freed ← readTVar (svFreed service)
    before ← readTVar (vsRefused vs)
    when (isNothing before) (modifyTVar' (vsRefusals vs) (+ 1))
    writeTVar (vsRefused vs) (Just (limit, RefusedAt basis residency freed))

-- Settle every pending move with recoverable pressure, once, and cancel the camera's pending jump: the camera stays
-- where it was.
pressure ∷ ViewState k → BindingLimit → STM ()
pressure vs limit = do
  moves ← readTVar (vsMoves vs)
  forM_ (Map.elems moves) (settleOnce (MovePressure limit))
  writeTVar (vsMoves vs) Map.empty
  modifyTVar' (vsCamera vs) (\camera → maybe camera (\p → cancelJump (pendingId p) camera) (camPending camera))

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
      Just (Right snapshot) → do
        -- the cumulative input runs, counted as the planner is handed them, are checked as each copy is accepted
        runs ← timed service (\() → prepRuns prep + plannerRuns snapshot)
        let limit = profileRuns (tvProfile (svConfig service))
        if runs > limit
          then False <$ atomically (refuse service vs serial (prepBasis prep) (LimitRuns runs limit))
          else atomically (writeBack service vs serial (Copying prep {prepRuns = runs} wanted (snapshot : taken) Nothing))
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

-- The copies are complete: the planner makes their inputs.
toPlanning ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Prep → [Runtime.RegionSnapshot] → IO Bool
toPlanning service vs serial prep taken = atomically $ do
  box ← newEmptyTMVar
  kept ← writeBack service vs serial (Inputting prep taken box)
  when kept (submitJob service vs (\() → inputsOf (tvProfile (svConfig service)) taken) box)
  pure False

-- The copies' inputs (whose runs were counted as they were accepted): combined into one version, as the planner's
-- facts and knowledge.
inputsOf ∷ ViewProfile → [Runtime.RegionSnapshot] → Either BindingLimit (CopySet, TerrainFacts, Knowledge)
inputsOf profile taken = case combineCopies taken of
  Left _ → Left (LimitRuntime "the copies are of different versions")
  Right copies → case planInputs (ChangeLimits (profileRuns profile)) copies of
    Left why → Left (LimitFailure ("the copies could not be planned from: " <> Text.pack (show why)))
    Right (facts, knowledge) → facts `seq` knowledge `seq` Right (copies, facts, knowledge)

-- The inputs are made: the camera settles with their facts (on the owner, where the camera lives), then another copy
-- round for what the camera itself lacks, or the plan, which the planner makes.
stepInputting ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Prep → [Runtime.RegionSnapshot] → TMVar (Either BindingLimit (CopySet, TerrainFacts, Knowledge)) → IO Bool
stepInputting service vs serial prep taken box =
  atomically $
    tryReadTMVar box >>= \case
      Nothing → pure False
      Just (Left limit) → False <$ refuse service vs serial (prepBasis prep) limit
      Just (Right (copies, facts, knowledge)) → do
        (settled, extra) ← settleCamera service vs facts
        let asked = Set.size (prepRegions prep)
            room = max 0 (profileRegions (tvProfile (svConfig service)) - asked)
            fresh = filter (`Set.notMember` prepRegions prep) (nubOrdered extra)
            fits = take room fresh
        if not (null fits) && prepRounds prep > 0
          then writeBack service vs serial (Copying prep {prepRounds = prepRounds prep - 1, prepRegions = prepRegions prep <> Set.fromList fits} fits taken Nothing)
          else do
            -- a pending jump this preparation cannot land settles with pressure, and the camera stays
            when (isJust (camPending settled)) $
              pressure vs $
                if null fresh
                  then LimitFailure "the jump's destination cannot be reached with its copied facts"
                  else LimitRegions (asked + length fresh) asked
            camera ← readTVar (vsCamera vs)
            light ← readTVar (vsLight vs)
            planned ← newEmptyTMVar
            let inputs = CellInputs (CellRequest (factsVersions facts) camera (setupFor (prepMetrics prep)) (cellConfig service)) facts knowledge (styleSnapshot (vsStyle vs))
            kept ← writeBack service vs serial (Planning prep copies planned)
            when kept (submitJob service vs (\() → planned' inputs light) planned)
            pure False
  where
    planned' inputs light = forcedPlanned (planOf service (vsStyle vs) light inputs prep)

-- The facts are the view's from now on: a followed surface they supply is adopted and a pending jump they allow
-- lands, settling its move. Answers the camera and the regions it still lacks facts for (a followed column or a
-- jump's destination), which the next copy round asks for.
settleCamera ∷ TerrainViews k → ViewState k → TerrainFacts → STM (CameraState, [RegionCoord])
settleCamera service vs facts = do
  writeTVar (vsFacts vs) (Just facts)
  camera ← readTVar (vsCamera vs)
  let config = tvCamera (svConfig service)
      (followed, followNeed) = case refollow config facts camera of
        Left _ → (camera, [])
        Right result → (stepCamera result, case stepFollow result of FollowUnavailable demand → regionsOf demand; _ → [])
  (landed, jumpNeed) ← case camPending followed of
    Nothing → pure (followed, [])
    Just pending → case completeJump config facts (pendingId pending) followed of
      Right result → case stepJump result of
        JumpApplied (JumpId number) → do
          moves ← readTVar (vsMoves vs)
          for_ (Map.lookup number moves) (settleOnce MoveLanded)
          writeTVar (vsMoves vs) (Map.delete number moves)
          pure (stepCamera result, [])
        JumpPending _ demand → pure (stepCamera result, regionsOf demand)
        _ → pure (stepCamera result, [])
      Left _ → pure (followed, [targetRegion (pendingTarget pending) (camClip followed)])
  writeTVar (vsCamera vs) landed
  pure (landed, followNeed <> jumpNeed)

-- The planner's configuration under the profile's limits.
cellConfig ∷ TerrainViews k → CellConfig
cellConfig = viewCellConfig . svConfig

-- | The planner's configuration a view plans with: the configuration's band, margins and query bounds under the
-- profile's limits.
viewCellConfig ∷ TerrainViewsConfig → CellConfig
viewCellConfig config =
  let profile = tvProfile config
      base = tvCells config
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

-- | The view setup a plan is made for at these metrics: the whole framebuffer, default settings.
viewSetup ∷ TargetMetrics → ViewSetup
viewSetup = setupFor

setupFor ∷ TargetMetrics → ViewSetup
setupFor metrics =
  let PixelExtent width height = metricsFramebuffer metrics
   in ViewSetup metrics (Viewport (V2 0 0) (V2 (fromIntegral width) (fromIntegral height))) defaultViewSettings

-- ---------------------------------------------------------------------------
-- Planning

-- The planner's whole work for one preparation, pure: the plan run to its end, then either another copy round for the
-- visible demand its copies lack, or the candidate's parts.
planOf ∷ TerrainViews k → ViewStyle → LightSettings → CellInputs → Prep → Either BindingLimit Planned
planOf service style light inputs prep = do
  started ← either (failed "the plan could not start") Right (startCells inputs)
  finished ← steps started
  plan ← either (failed "the plan could not finish") Right (cellPlanOf inputs finished)
  let profile = tvProfile (svConfig service)
      camera = crCamera (inputsRequest inputs)
      visible = regionsOf (cdVisible (cellPlanDemand plan))
      prefetch = regionsOf (cdPrefetch (cellPlanDemand plan))
      room = max 0 (profileRegions profile - Set.size (prepRegions prep))
      unasked = filter (`Set.notMember` prepRegions prep) (ordered (anchorRegion (crCamera (inputsRequest inputs))) visible)
      -- what fits the profile's regions; what is beyond them stays loading in the published revision
      fits = take room unasked
  if not (null fits) && prepRounds prep > 0
    then Right (Planned plan camera visible prefetch (Left fits))
    else do
      (adapted, parts) ← candidateOf service style plan light
      -- regions that fit but had no copy round left: the view prepares again to copy them
      Right (Planned plan camera visible prefetch (Right (adapted, parts, not (null fits))))
  where
    failed what why = Left (LimitFailure (what <> ": " <> Text.pack (show why)))
    -- a plan-wide bound is a refusal: a halted plan is never published as if it were complete
    steps prepared = case cellPrepProgress prepared of
      Working → either (failed "a plan step failed") Right (stepCells inputs prepared) >>= steps
      Halted reason → Left (LimitPlan reason)
      Settled → Right prepared

-- The planner's work done before it is handed back: the plan's quads, pending spans and demand, every part's
-- instances and records.
forcedPlanned ∷ Either BindingLimit Planned → Either BindingLimit Planned
forcedPlanned = \case
  Right planned →
    let plan = plannedPlan planned
        parts = case plannedNext planned of
          Right (_, made, _) → foldr (\(_, instances, records) rest → foldr seq () instances `seq` foldr seq () records `seq` rest) () made
          Left missing → foldr seq () missing
     in length (cellPlanQuads plan) `seq` length (cellPlanPending plan) `seq` length (plannedVisible planned) `seq` length (plannedPrefetch planned) `seq` parts `seq` Right planned
  other → other

-- The plan is made: another copy round, or the candidate's admission, on the owner: its parts equal to a published
-- part are reused by reference, and what is left must fit the target's free slots.
stepPlanning ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Prep → CopySet → TMVar (Either BindingLimit Planned) → IO Bool
stepPlanning service vs serial prep copies box =
  atomically (tryReadTMVar box) >>= \case
    Nothing → pure False
    Just (Left limit) → False <$ atomically (refuse service vs serial (prepBasis prep) limit)
    Just (Right planned) → case plannedNext planned of
      Left missing → atomically (writeBack service vs serial (Copying prep {prepRounds = prepRounds prep - 1, prepRegions = prepRegions prep <> Set.fromList missing} missing (copySnapshots copies) Nothing))
      Right (adapted, wanted, incomplete) → do
        let profile = tvProfile (svConfig service)
            plan = plannedPlan planned
        atomically (writeTVar (vsDemand vs) (Set.toList (prepRegions prep) <> plannedVisible planned))
        setDemand service vs (plannedVisible planned <> plannedPrefetch planned)
        parts ← readTVarIO (vsParts vs)
        -- the reuse comparison is the owner's own planning work, timed into the frame's total
        (reused, toBuild) ← timed service $ \() →
          let byKey = Map.fromList [(key, (instances, records)) | (key, instances, records) ← wanted]
              kept = Map.mapMaybe id (Map.intersectionWith (\part (instances, records) → if partInstances part == instances && partRecords part == records then Just part else Nothing) parts byKey)
              fresh = [w | w@(key, _, _) ← wanted, Map.notMember key kept]
           in Map.size kept `seq` length fresh `seq` (kept, fresh)
        atomically $ do
          occupied ← Map.findWithDefault 0 (vtKey (vsTarget vs)) <$> readTVar (svSlots service)
          let free = profileSlots profile - occupied
          if length toBuild > free
            then False <$ refuse service vs serial (prepBasis prep) (LimitSlots (length toBuild) free)
            else writeBack service vs serial (Building prep (Candidate plan copies adapted toBuild Map.empty reused (plannedCamera planned) incomplete))

-- Time the owner's own pure work, into the current frame's and the current step's planning totals.
{-# NOINLINE timed #-}

-- The work is a function of @()@, applied and evaluated between the two readings of the clock, so the compiler cannot
-- evaluate it before the first.
timed ∷ TerrainViews k → (() → a) → IO a
timed service work = do
  start ← getMonotonicTimeNSec
  result ← evaluate (work ())
  end ← getMonotonicTimeNSec
  atomically $ do
    modifyTVar' (svPlanningFrame service) (+ (end - start))
    modifyTVar' (svPlanningStep service) (+ (end - start))
  pure result

-- Adapt the plan and group it into the candidate's chunks: render regions of 16 x 16 cells of the rotated view frame,
-- each split into parts of at most a chunk's instances, each part with the distinct records its quads use. Refused
-- when its records cannot fit the renderer's storage window as a frame binds them.
candidateOf ∷ TerrainViews k → ViewStyle → CellPlan → LightSettings → Either BindingLimit (Adapted, [(PartKey, [Instance], [MaterialRecord])])
candidateOf service style plan light = do
  adapted ← either (Left . LimitFailure . ("the plan could not be adapted: " <>) . Text.pack . show) Right (adaptCells (styleBound style) light (styleSnapshot style) plan)
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

-- Each region once, in the order first named.
nubOrdered ∷ [RegionCoord] → [RegionCoord]
nubOrdered = go Set.empty
  where
    go _ [] = []
    go seen (r : rs)
      | Set.member r seen = go seen rs
      | otherwise = r : go (Set.insert r seen) rs

-- ---------------------------------------------------------------------------
-- Building and publication

stepBuilding ∷ (Ord k, Show k) ⇒ TerrainViews k → Hands → ViewState k → Word64 → Prep → Candidate → IO Bool
stepBuilding service hands vs serial prep candidate = case cdWanted candidate of
  _ : _ →
    buildEach (take (profileBuilds (tvProfile (svConfig service))) (cdWanted candidate)) >>= \case
      Nothing → pure True
      -- the staging is full now: an upload's completion asks for the next step
      Just (BuildBackpressure _) → pure False
      Just (BuildFailed why) → False <$ atomically (refuse service vs serial (prepBasis prep) (LimitFailure ("a chunk could not be built: " <> why)))
  [] → do
    standings ← atomically (forM (Map.elems (cdBuilt candidate)) (ownerStanding (portOwner (svPorts service)) . partChunk))
    case () of
      _
        | any failedStanding standings → False <$ atomically (refuse service vs serial (prepBasis prep) (LimitFailure ("a chunk's upload ended without completing: " <> Text.pack (show [s | s ← standings, failedStanding s]))))
        | all (== Just ChunkReady) standings → do
            -- two earlier revisions that can still be drawn hold publication back (the transaction rechecks)
            room ← (< 2) . Set.size <$> atomically (pinsKept service vs)
            if room then publish service vs serial prep candidate else pure False
        | otherwise → pure False
  where
    failedStanding = \case
      Just (ChunkFailed _) → True
      Nothing → True
      _ → False
    -- Each chunk is handed on in the transaction after its build: it occupies its target's slot, and goes to the
    -- candidate while the stage is still this step's, otherwise to disposal. A stage replaced meanwhile stops the batch.
    buildEach [] = pure Nothing
    buildEach ((key, instances, records) : more) = do
      mine ← atomically ((== serial) <$> readTVar (vsStageSerial vs))
      if not mine
        then pure Nothing
        else do
          outcome ← mask $ \_ →
            handBuild hands instances records >>= \case
              Left why → pure (Just why)
              Right chunk → Nothing <$ atomically (handOn key (Part chunk instances records))
          maybe (buildEach more) (pure . Just) outcome
    handOn key part = do
      occupy service (vtKey (vsTarget vs)) 1
      current ← readTVar (vsStageSerial vs)
      status ← readTVar (vsStatus vs)
      stage ← readTVar (vsStage vs)
      case stage of
        Building p c
          | current == serial && status == ViewOpen →
              writeTVar (vsStage vs) (Building p c {cdBuilt = Map.insert key part (cdBuilt c), cdWanted = filter (\(k, _, _) → k /= key) (cdWanted c)})
        _ → privately service vs [partChunk part]

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
              , worldTextures = styleParents (vsStyle vs)
              }
      scene ← prepare (worldGraphicsScene world)
      atomically $ do
        keep ← pinsKept service vs
        current ← readTVar (vsStageSerial vs)
        status ← readTVar (vsStatus vs)
        basis ← currentBasis service vs
        claim ← claimOf (portClaims ports) (vtKey (vsTarget vs))
        usable ← vtUsable (vsTarget vs)
        open ← readTVar (svOpen service)
        let mine = fmap claimView claim == Just (vsId vs)
        if
          | current /= serial || status /= ViewOpen || not open || not mine || not usable || basis /= prepBasis prep → do
              -- overtaken: the private builds go, and the newer state is prepared next
              _ ← takeStage service vs
              pure True
          | Set.size keep >= 2 →
              -- two earlier revisions can still be drawn (the drawn one and an adopted successor): publication waits
              -- for one of them to stop being drawable, which a frame or the ledger reports with a kick
              pure False
          | otherwise →
            vtPublish (vsTarget vs) scene >>= \case
              False → False <$ refuse service vs serial (prepBasis prep) (LimitFailure "the host refused the publication")
              True → do
                _ ← markClaimPublished (portClaims ports) (vtKey (vsTarget vs)) (vsId vs)
                old ← readTVar (vsParts vs)
                let superseded = [partChunk part | (key, part) ← Map.toList old, Map.notMember key (cdReused candidate)]
                unless (null superseded) $
                  modifyTVar' (svRetiring service) (|> Retiring (vtKey (vsTarget vs)) (vsId vs) superseded Unasked False)
                writeTVar (vsParts vs) parts
                writeTVar (vsPublished vs) (Just (revision, prepBasis prep, cdIncomplete candidate))
                writeTVar (vsRefused vs) Nothing
                writeTVar (vsStage vs) Idle
                -- the pins: those of the revisions that can still be drawn, and this successor's
                let copies = cdCopies candidate
                    pin = Pinned plan (copyArena copies, copyContent copies, copyKnowledge copies, copyGeneration copies) (copyRegions copies) (cdCamera candidate) (prepMetrics prep)
                modifyTVar' (vsPins vs) (Map.insert revision pin . Map.filterWithKey (\r _ → Set.member r keep))
                pure False

-- The revisions of a view that can still be drawn: the one its receipt names, and every later one the scene ledger
-- holds adopted. At most two are pinned: a third waits.
pinsKept ∷ Eq k ⇒ TerrainViews k → ViewState k → STM (Set Word64)
pinsKept service vs = do
  let ports = svPorts service
  drawn ← fmap (tagRevision . drawnTag) <$> readReceipt (portReceipts ports) (vsId vs)
  pinned ← Map.keys <$> readTVar (vsPins vs)
  later ← filterM (\r → ledgerTagHeld (portLedger ports) (vtKey (vsTarget vs)) (WorldTag (vsId vs) r)) [r | r ← pinned, maybe True (r >) drawn]
  pure (Set.fromList (maybeToList drawn <> later))

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
          Just (Right ()) → go open True (done |> entry {rtBarrier = Met}) rest
          -- the entry ends here, its chunks failures with the host's answer (they keep their slots)
          Just (Left why) → failChunks entry why >> go open True done rest
          Nothing → go open moved (done |> entry) rest
      Met → go open moved (done |> entry) rest
    failChunks entry why = modifyTVar' (svFailed service) (<> [(rtTarget entry, Just chunk, why) | chunk ← rtChunks entry])

-- Release what can go now, on the owner's thread: private builds whose upload has ended, and retiring chunks whose
-- barrier is met and that no adopted revision holds; then confirm the disposals the backend has finished. Each chunk
-- leaves its holder for the owner's hand in one transaction, is released once, and leaves the hand for the
-- disposals awaiting confirmation (or the failures) in the next. Disposed, its slot is freed; failed, it keeps its
-- identity, its slot and its cause. Answers whether anything moved.
retire ∷ (Ord k, Show k) ⇒ TerrainViews k → Hands → IO Bool
retire service hands = do
  _ ← atomically (askBarriers service)
  confirmed ← atomically (confirmDisposals service)
  picked ← atomically $ do
    chosen ← take budget <$> disposable service
    let taken (key, view, chunk) = (key, view, chunk) `elem` chosen
    modifyTVar' (svPrivate service) (filter (not . taken))
    modifyTVar' (svRetiring service) (Seq.filter (not . null . rtChunks) . fmap (\entry → entry {rtChunks = filter (\chunk → not (taken (rtTarget entry, rtView entry, chunk))) (rtChunks entry)}))
    modifyTVar' (svInHand service) (<> chosen)
    pure chosen
  forM_ picked releaseOne
  pure (confirmed || not (null picked))
  where
    budget = 64
    releaseOne held@(key, _, chunk) =
      mask $ \_ → do
        outcome ← handDispose hands chunk
        atomically $ do
          inHand ← readTVar (svInHand service)
          -- a chunk abandoned meanwhile (the owner's end, an interrupted drain) is already accounted for
          when (held `elem` inHand) $ do
            writeTVar (svInHand service) (filter (/= held) inHand)
            case outcome of
              Right reading → modifyTVar' (svDisposing service) (<> [(held, reading)])
              Left why → modifyTVar' (svFailed service) (<> [(key, Just chunk, "the chunk's release failed: " <> why)])

-- What can be released now: private builds whose upload has ended, and chunks of met retirements that no adopted
-- revision holds (a failed handback's while the service is open excepted).
disposable ∷ Ord k ⇒ TerrainViews k → STM [Held k]
disposable service = do
  private ← readTVar (svPrivate service)
  ready ← filterM (\(_, _, chunk) → notUploading chunk) private
  entries ← readTVar (svRetiring service)
  open ← readTVar (svOpen service)
  met ← fmap concat . forM (toList entries) $ \entry → case rtBarrier entry of
    Met
      | not (rtProtected entry && open) →
          filterM (\(_, _, chunk) → (&&) <$> (not <$> ledgerChunkHeld (portLedger (svPorts service)) chunk) <*> notUploading chunk) [(rtTarget entry, rtView entry, chunk) | chunk ← rtChunks entry]
    _ → pure []
  pure (ready <> met)
  where
    notUploading chunk = (/= Just ChunkUploading) <$> ownerStanding (portOwner (svPorts service)) chunk

-- The disposals the backend has finished: a done one frees its slot, a failed one becomes a failure with its cause and
-- keeps its slot. Answers whether any finished.
confirmDisposals ∷ Ord k ⇒ TerrainViews k → STM Bool
confirmDisposals service = do
  disposing ← readTVar (svDisposing service)
  readings ← forM disposing $ \entry@(_, reading) → (,) entry <$> reading
  forM_ readings $ \(((key, _, chunk), _), standing) → case standing of
    DisposalDone → occupy service key (-1) >> modifyTVar' (svFreed service) (+ 1)
    DisposalFailed why → modifyTVar' (svFailed service) (<> [(key, Just chunk, "the chunk's disposal failed: " <> why)])
    DisposalPending → pure ()
  let pending = [entry | (entry, DisposalPending) ← readings]
  when (length pending /= length disposing) (writeTVar (svDisposing service) pending)
  pure (length pending /= length disposing)

-- Whether the owner has retirement work it can do now.
retirementReady ∷ Ord k ⇒ TerrainViews k → STM Bool
retirementReady service = do
  candidates ← disposable service
  disposing ← readTVar (svDisposing service)
  finished ← or <$> forM disposing (\(_, reading) → (/= DisposalPending) <$> reading)
  pure (not (null candidates) || finished)

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
  , readingListed ∷ !Int
    -- ^ Chunks the published revision lists.
  , readingStage ∷ !Text
    -- ^ Where its preparation is: idle, copying, planning or building.
  }
  deriving (Eq, Show)

readView ∷ TerrainView k → STM ViewReading
readView (TerrainView service vs) = do
  _ ← sweepOffscreen (portReceipts (svPorts service))
  ViewReading
    <$> readTVar (vsStatus vs)
    <*> (fmap (\(revision, _, _) → revision) <$> readTVar (vsPublished vs))
    <*> readReceipt (portReceipts (svPorts service)) (vsId vs)
    <*> (fmap fst <$> readTVar (vsRefused vs))
    <*> readTVar (vsRefusals vs)
    <*> (Map.size <$> readTVar (vsParts vs))
    <*> (stageName <$> readTVar (vsStage vs))
  where
    stageName = \case
      Idle → "idle"
      Copying _ wanted taken flight → "copying (" <> Text.pack (show (length wanted)) <> " to ask, " <> Text.pack (show (length taken)) <> " taken, " <> (if isNothing flight then "none" else "one") <> " in flight)"
      Inputting {} → "making inputs"
      Planning {} → "planning"
      Building _ candidate → "building (" <> Text.pack (show (length (cdWanted candidate))) <> " to build)"

-- | Every open view's reading.
viewReadings ∷ TerrainViews k → STM [ViewReading]
viewReadings service = readTVar (svViews service) >>= mapM (readView . TerrainView service) . Map.elems

-- | The revision a view's target drew, for picking (#715): its tag, the frame's metrics, how many drawings the view
-- has had, and the drawn plan with the arena version it was copied from while it is pinned ('Nothing' once a
-- successor's pin replaced it).
data DrawnPlan k = DrawnPlan
  { drawnPlanTarget ∷ !k
    -- ^ The target incarnation the view, and so the receipt, is bound to.
  , drawnPlanReceipt ∷ !Drawn
  , drawnPlanPlan ∷ !(Maybe CellPlan)
  , drawnPlanArena ∷ !(Maybe (ArenaId, Revision, Revision, Word64))
  , drawnPlanRegions ∷ !(Maybe (Set RegionCoord))
    -- ^ The regions the plan's copies hold.
  , drawnPlanCamera ∷ !(Maybe CameraState)
    -- ^ The camera the plan was made for.
  , drawnPlanMetrics ∷ !(Maybe TargetMetrics)
    -- ^ The metrics the plan was made for.
  }

viewDrawn ∷ TerrainView k → STM (Maybe (DrawnPlan k))
viewDrawn (TerrainView service vs) = do
  _ ← sweepOffscreen (portReceipts (svPorts service))
  readReceipt (portReceipts (svPorts service)) (vsId vs) >>= \case
    Nothing → pure Nothing
    Just drawn → do
      pin ← Map.lookup (tagRevision (drawnTag drawn)) <$> readTVar (vsPins vs)
      pure (Just (DrawnPlan (vtKey (vsTarget vs)) drawn (pinPlan <$> pin) (pinCopies <$> pin) (pinRegions <$> pin) (pinCamera <$> pin) (pinMetrics <$> pin)))

-- | The service's resources now.
data ServiceReading k = ServiceReading
  { serviceViews ∷ !Int
  , serviceOccupied ∷ !(Map k Int)
    -- ^ Each target's occupied slots: candidate, drawn, retiring and failed chunks.
  , serviceRetiring ∷ !Int
  , servicePrivate ∷ !Int
  , serviceDisposing ∷ !Int
    -- ^ Chunks released and awaiting the backend's confirmation of their disposal (or in the owner's hand).
  , serviceFailures ∷ ![(k, Maybe ChunkRef, Text)]
  , serviceReserved ∷ !Integer
  , servicePlanningMax ∷ !Word64
    -- ^ The greatest owner-thread planning time between two presentations' enqueues, in nanoseconds.
  , servicePlanningStepMax ∷ !Word64
    -- ^ The greatest planning time of one owner step, in nanoseconds: a step runs alone in its owner round, so no frame
    -- waits on more than one.
  , serviceOwnerMax ∷ !Word64
    -- ^ The greatest time of the views' whole work on the owner's thread between two presentations' enqueues, in
    -- nanoseconds: planning, the camera, builds, publication and retirement.
  , serviceOwnerStepMax ∷ !Word64
    -- ^ The greatest time of one owner step, in nanoseconds.
  }

readTerrainViews ∷ TerrainViews k → STM (ServiceReading k)
readTerrainViews service =
  ServiceReading
    <$> (Map.size <$> readTVar (svViews service))
    <*> readTVar (svSlots service)
    <*> (sum . fmap (length . rtChunks) <$> readTVar (svRetiring service))
    <*> (length <$> readTVar (svPrivate service))
    <*> ((+) <$> (length <$> readTVar (svInHand service)) <*> (length <$> readTVar (svDisposing service)))
    <*> readTVar (svFailed service)
    <*> pure (svReserved service)
    <*> ((\a b → max a b) <$> readTVar (svPlanningMax service) <*> readTVar (svPlanningFrame service))
    <*> readTVar (svPlanningStepMax service)
    <*> ((\a b → max a b) <$> readTVar (svOwnerMax service) <*> readTVar (svOwnerFrame service))
    <*> readTVar (svOwnerStepMax service)
