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
-- view. A replacement that cannot fit is refused, the target keeps its drawing, and a later relevant change prompts a
-- fresh attempt; one that can fit and finds the target's slots or the uploads' room taken for now keeps what it built
-- and waits, armed, on the same admission decision and its own chunks' standings, which the watcher observes.
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
  , admitDue
  , ledgerNoticed

    -- * Targets and styles
  , ViewTarget (..)
  , ViewSurface (..)
  , Authority (..)
  , ViewGeometry (..)
  , geometryOfMetrics
  , CopyHooks (..)
  , noCopyHooks
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
import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeAsyncException, SomeException, displayException, evaluate, finally, fromException, mask, mask_, onException, rethrowIO, throwIO, try, tryWithContext, uninterruptibleMask_)
import Control.Monad (filterM, forM, forM_, unless, void, when)
import Data.Foldable (for_, toList)
import Data.Functor ((<&>))
import Data.List (sort, sortOn)
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
import qualified Hetoimasia.Foundation.Exit as Exit
import Hetoimasia.Foundation.Exit (IssuerStanding (..))
import Hetoimasia.Foundation.OwnerTx (OwnerTx, commit)
import Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM)
import Control.DeepSeq (NFData (..))
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare, preparedValue)
import Hetoimasia.Foundation.Resource (composeCleanup, withResourceLabelled)
import Hetoimasia.Foundation.Worker (StartOutcome (..), closeWorkerGroup, requestStop, startWorker, stopRequested, withWorkerGroup, workerDefinition)
import Hetoimasia.LuaEngine.Graphics.Scene.Claims (SceneClaims, claimOf, Claim (..), markClaimPublished, newClaimHolder, releaseClaim, takeClaim)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene, SceneLedger, ledgerChunkHeld, ledgerChanges, ledgerDropInterest, ledgerRetainInterest, ledgerTagHeld, worldGraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Scene.Receipts (DrawReceipts, Drawn (..), forgetReceipt, offscreenSweepDue, openReceipt, readReceipt, receiptsFrames, sweepOffscreen)
import Hetoimasia.LuaEngine.Graphics.Scene.World (SceneWorld (..), WorldTag (..))
import Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs (CopySet (..), combineCopies, planInputs, plannerRuns)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Owner (Admission (..), Allocated (..), BuildFailure (..), ConstructedDisposal (..), Grant (..), Hands (..), Receipt (..), OwnerPorts (..), ScheduleRefusal (..), StepOutcome (..))
import Hetoimasia.LuaEngine.Graphics.TerrainView.Profile
import Hetoimasia.LuaEngine.Graphics.TerrainView.Style (StyleRefusal (..), StyleRequest (styleColourLease, styleLeases, styleNormalLease), acquireStyle, releaseStyle, styleAssets, styleIdentities, styleMappedMaterials, styleTextures)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Surface
import Hetoimasia.Terrain.Cell (Column, MaterialId)
import Hetoimasia.Terrain.Palette (paletteMaterials)
import Hetoimasia.Terrain.Render2D.Assets (AssetSnapshot)
import Hetoimasia.Terrain.Render2D.Material (AtlasTextures)
import Hetoimasia.LuaEngine.Texture (RenderAccount, accountReleaseTx, accountReserveTx)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Chunk (ChunkRef)
import Hetoimasia.Render.TwoD.Material (MaterialData (..), MaterialRecord, materialRecordLayout, recordLayoutBytes)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot (ClearColour (..), Instance, Layer (WorldLayerWith), LayerDepth (DepthEnabled), Viewport (..))
import Hetoimasia.Render.TwoD.Vulkan.Chunks (ChunkStanding (..), PreparedChunk, preparedBytes)
import Hetoimasia.Render.TwoD.Vulkan.Layout (clipEntryBytes)
import Hetoimasia.Terrain.Changes (ChangeLimits (..))
import Hetoimasia.Terrain.Coordinate (AxisCoord, RegionCoord (..), axisValue)
import Hetoimasia.Terrain.Render2D.Camera (CameraConfig, CameraError, CameraState, Command (..), FollowOutcome (..), JumpEvent (..), JumpId (..), JumpTarget (..), KnownSurface (..), PendingJump (..), Step (..), applyLocal, camAnchorX, camAnchorY, camClip, camFacing, camFrac, camPending, camRef, camZoom, cancelJump, completeJump, completeJumpKnown, defaultCameraConfig, followKnown, followedColumn, newCamera, prospectiveCamera, requestJump)
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Facts (TerrainFacts (..), Versions (..))
import Hetoimasia.Terrain.Render2D.Knowledge (Knowledge)
import Hetoimasia.Terrain.Render2D.Material (Adapted (..), AdaptedQuad (..), adaptCells, adaptedInstance, terrainView)
import Hetoimasia.Terrain.Render2D.Presentation (LightSettings)
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..))
import Hetoimasia.Terrain.Query (Occupied (..))
import Hetoimasia.Terrain.Residency (ArenaId (..), RegionDemand (..), Revision (..), coverageBox, limitCameraRegions, limitHoldRegions, limitQueryRegions)
import Hetoimasia.Terrain.Runtime (ArenaMark (..), ArenaView (viewGeneration, viewKnowledgeRevision, viewPalette, viewRevision), Settlement (..))
import qualified Hetoimasia.Terrain.Runtime as Runtime
import Hetoimasia.Terrain.Runtime.Settlement (TakeOutcome (..))
import Hetoimasia.Terrain.Runtime.Transactions (ViewRequest, cancelViewRequest, attachViewTx, closeViewTx, releaseRegionBorrowTx, requestViewRegions, requestViewSurface, retireViewRequestTx, setViewDemandTx, takeViewRequestTx, viewRequestSettled)
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
  , portCopyHooks ∷ !CopyHooks
  }

-- | What the views read at their copy and demand boundaries besides the terrain service: the regions whose terrain
-- part a copy is read as unavailable (a storage fault, in a suite); an action run inside the run count of a held copy,
-- once its total is counted and before the copy is accepted or refused, its batch and the total named (a gate a suite
-- observes the held charge at); and a refusal answered for a demand installation in place of the terrain service's
-- (a suite's deterministic refusal); and an action run on the owner's thread after a build's revalidation succeeded
-- and before its collection, outside both transactions (a suite changes a source there). 'noCopyHooks' in production.
data CopyHooks = CopyHooks
  { hookUnavailable ∷ STM (Set RegionCoord)
  , hookCounting ∷ [RegionCoord] → Int → IO ()
  , hookDemandRefused ∷ [RegionCoord] → STM (Maybe Text)
  , hookCollecting ∷ IO ()
  , hookRequested ∷ STM Bool → IO ()
    -- ^ A regional request was made and its stage is not yet written: the seam where a request settles first, given
    -- a reading of whether it has (nothing in production).
  , hookTaken ∷ IO ()
    -- ^ A settled copy's borrow was just taken, masked, before its count (nothing in production).
  , hookAccounting ∷ STM ()
    -- ^ Inside the commit that returns a taken copy's borrow and accounts the copy (nothing in production).
  }

noCopyHooks ∷ CopyHooks
noCopyHooks = CopyHooks (pure Set.empty) (\_ _ → pure ()) (\_ → pure Nothing) (pure ()) (\_ → pure ()) (pure ()) (pure ())

-- | Why the service could not be made. Nothing was reserved or started.
data TerrainViewsRefused
  = TerrainViewsProfile !ProfileRefusal
  | -- | The account cannot hold the allowance: the allowance, and what the account had free.
    TerrainViewsAccount !Integer !Integer
  | TerrainViewsWatcher !Text
  deriving (Eq, Show)

instance Exception TerrainViewsRefused

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
  , styleAuthority ∷ ![Authority]
    -- ^ The original leases of its parents, live until they end.
  , styleRelease ∷ IO ()
  }

-- | The style of an owning instance's two retained parents ("Hetoimasia.LuaEngine.Graphics.TerrainView.Style").
retainedStyle ∷ StyleRequest → IO (Either StyleRefusal ViewStyle)
retainedStyle request =
  acquireStyle request >>= \case
    Left refusal → pure (Left refusal)
    Right style → do
      -- the parents' leases as their table publishes them: a lease gone meanwhile is an authority already ended
      leases ← atomically (mapM (leaseAuthority (styleLeases request)) [styleColourLease request, styleNormalLease request])
      pure (Right (ViewStyle (styleAssets style) (styleTextures style) (styleIdentities style) (styleMappedMaterials style) leases (releaseStyle style)))

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
  , basisGeometry ∷ !ViewGeometry
  , basisArena ∷ !(Maybe (ArenaId, Revision, Revision))
    -- ^ The arena's incarnation and its content and knowledge revisions.
  }
  deriving (Eq, Show)

-- | What a refusal is keyed by: the attempt's basis; for a refusal over the target's free slots, the slots the attempt
-- needed (a change of the target's free slots to that many is the one other input that can make it fit); and for a
-- refused demand replacement, the list refused (suppressed while the basis and the desired list stay as they were).
data RefusedAt = RefusedAt !Basis !(Maybe Int) !(Maybe [RegionCoord])
  deriving (Eq, Show)

-- | The terrain revision the view's target accepted: its basis, its runtime demand (the visible-first prefix it was
-- planned with) and how many parts it lists. It is valid while every one of them is.
data Accepted = Accepted
  { accRevision ∷ !Word64
  , accBasis ∷ !Basis
  , accDemand ∷ ![RegionCoord]
  , accPrepared ∷ !(Prepared [RegionDemand])
    -- ^ Its runtime demand, prepared before the commit that installs it.
  , accParts ∷ !Int
  }

newtype InFlight = InFlight
  { flightRequest ∷ ViewRequest
    -- ^ The view's sealed request: its settlement is in its own box ('viewRequestSettled'), which the watcher observes.
  }

-- The request's settlement once it has one.
flightSettled ∷ InFlight → STM (Maybe Settlement)
flightSettled = viewRequestSettled . flightRequest

-- What the watcher compares of a view: its arena mark, the authority epoch, its target's usability and geometry, its
-- original authority and each authority's revision, and its request in flight with whether it has settled.
type Marks = (Maybe ArenaMark, Word64, Bool, ViewGeometry, Bool, [AuthorityMark], Maybe (ViewRequest, Bool))

-- The revisions of a view's original authority: the window's leases and the style's.
authorityRevisions ∷ ViewState k → STM [AuthorityMark]
authorityRevisions vs = (<>) <$> surfaceAuthorityMarks (vtSurface (vsTarget vs)) <*> authorityMarks (styleAuthority (vsStyle vs))

-- The request a view's stage holds in flight, and whether it has settled.
flightMark ∷ ViewState k → STM (Maybe (ViewRequest, Bool))
flightMark vs =
  readTVar (vsStage vs) >>= \case
    Surfacing _ _ _ flight → marked flight
    Copying _ _ _ (Just (_, flight)) → marked flight
    _ → pure Nothing
  where
    marked flight = Just . (,) (flightRequest flight) . isJust <$> flightSettled flight

-- The views' own transaction, embedded in a commit: their cells, and this package's scene claims, ledger, receipts and
-- window capabilities, which read only cells their issuers own and never wait or raise. Every other issuer's change
-- enters a commit as that issuer's own ownership operation.
own ∷ STM a → OwnerTx a
own = fromIssuerSTM

-- | One preparation: what it was started from, and the destination camera it copies and plans for.
data Prep = Prep
  { prepBasis ∷ !Basis
  , prepMetrics ∷ !(Maybe TargetMetrics)
    -- ^ The extent the preparation plans and publishes for; 'Nothing' at a zero geometry, where it only settles a move.
  , prepCamera ∷ !CameraState
    -- ^ The camera as it will be once settled: a pending jump's destination landed, and the followed surface as the
    -- terrain service answered it ('prospectiveCamera'). The copies and the plan are for it.
  , prepSurface ∷ !(Maybe (KnownSurface, Revision))
    -- ^ The followed column's surface, and the content revision it was answered at.
  , prepJump ∷ !(Maybe JumpId)
    -- ^ The pending jump the preparation was started for: only it may be settled by it.
  , prepZJump ∷ !Bool
    -- ^ Whether that jump has a level: its destination part is checked in the copies.
  , prepFootprint ∷ ![RegionCoord]
    -- ^ F: every region the cell planner can read for the camera, nearest its anchor first. The runtime demand is
    -- made from it alone.
  , prepExtra ∷ ![RegionCoord]
    -- ^ A pending jump with Z's destination region when F does not hold it: copied and charged, never demanded.
  , prepRuns ∷ !Int
    -- ^ The input runs and intervals of the copies taken so far, as the planner is handed them.
  }

-- | F and how it is copied, made on the planner and handed back fully evaluated: F nearest the anchor first, a
-- pending jump with Z's destination region when F lacks it, and their disjoint request batches, each ascending as a
-- copy lists its regions.
data Footprint = Footprint
  { fpKeys ∷ ![RegionCoord]
  , fpExtra ∷ ![RegionCoord]
  , fpBatches ∷ ![[RegionCoord]]
  }

data Stage
  = Idle
  | Surfacing !Basis !(Maybe TargetMetrics) !Column !InFlight
    -- ^ The terrain service is asked for the followed column's surface.
  | Footprinting !Prep !(TMVar (Either BindingLimit Footprint))
    -- ^ The planner enumerates F for the camera, and its batches.
  | Copying !Prep ![[RegionCoord]] ![Runtime.RegionSnapshot] !(Maybe ([RegionCoord], InFlight))
    -- ^ F's batches still to ask for, the copies taken, and the batch in flight.
  | Inputting !Prep ![Runtime.RegionSnapshot] !(TMVar (Either BindingLimit (CopySet, TerrainFacts, Knowledge)))
    -- ^ The planner makes the copies' inputs.
  | Planning !Prep !CopyIdentity !CameraState !(TMVar (Either BindingLimit Planned))
    -- ^ The planner makes the plan, for the settled camera, and the candidate's parts.
  | Building !Prep !Candidate

-- What the planner hands back for a plan: the plan, its prefetch regions outside F, and the adapted candidate's parts.
data Planned = Planned
  { plannedPlan ∷ !CellPlan
  , plannedPrefetch ∷ ![RegionCoord]
  , plannedAdapted ∷ !Adapted
  , plannedParts ∷ ![(PartKey, [Instance], [MaterialRecord])]
  }

-- What a revision's pin keeps of its copies: their arena, content and knowledge revisions, residency generation and
-- regions; not the copies themselves.
type CopyIdentity = ((ArenaId, Revision, Revision, Word64), Set RegionCoord)

copyIdentity ∷ CopySet → CopyIdentity
copyIdentity copies = ((copyArena copies, copyContent copies, copyKnowledge copies, copyGeneration copies), copyRegions copies)

data Candidate = Candidate
  { cdPlan ∷ !CellPlan
  , cdCopies ∷ !CopyIdentity
  , cdAdapted ∷ !Adapted
  , cdWanted ∷ ![(PartKey, [Instance], [MaterialRecord])]
    -- ^ The fresh parts not yet prepared.
  , cdPrepared ∷ !(Seq (PartKey, PreparedChunk, [Instance], [MaterialRecord]))
    -- ^ The fresh parts prepared and not yet built: the live remainder, built in this order from its head. A batch is
    -- appended and the built head removed, each in time bounded by the remainder's logarithm.
  , cdFresh ∷ !Int
    -- ^ How many fresh parts the candidate needs in all, after reuse.
  , cdLargest ∷ !(Maybe PreparedChunk)
    -- ^ Its largest prepared part. Whether a part can ever fit the staging is the candidate's property, and the
    -- largest decides it; a part already built fitted, so the largest of all is as good as the largest remaining.
  , cdBuilt ∷ !(Map PartKey Part)
  , cdReused ∷ !(Map PartKey Part)
  , cdCamera ∷ !CameraState
  , cdMetrics ∷ !TargetMetrics
  , cdDemand ∷ ![RegionCoord]
    -- ^ The runtime demand its publication applies: F nearest the anchor first, then the prefetch, cut at the
    -- service's camera regions.
  , cdDemandPrepared ∷ !(Prepared [RegionDemand])
    -- ^ That demand, prepared on the owner before the commits that install it.
  }

-- The next part's admission, decided in one transaction by the owner (which reserves its room) and by the watcher
-- (which only observes it): granted; blocked for now on the target's slots or the uploads' room; impossible, with the
-- candidate's whole fresh requirement and what a fresh attempt could have; a part larger than the whole staging; or an
-- end no wait changes.
data NextPart a
  = NextGranted a
  | NextBlocked
  | NextImpossible !Int !Int
  | NextOversized !Text
  | NextEnded !Text
  | NextFailed !Text
  | NextPublish

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
  | LimitOversized !Text
    -- ^ A part is larger than the whole staging buffer: the request and the ceiling.
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
  , vsSeen ∷ !(TVar Marks)
    -- ^ The watcher's last reading of the arena's mark, the authority epoch, the target's usability and its geometry,
    -- and the view's original authority.
  , vsStatus ∷ !(TVar ViewStatus)
  , vsCamera ∷ !(TVar CameraState)
  , vsLight ∷ !(TVar LightSettings)
  , vsIntent ∷ !(TVar Word64)
  , vsMoves ∷ !(TVar (Map Word64 (TVar (Maybe MoveOutcome))))
  , vsSettled ∷ !(TVar (Maybe CameraState))
    -- ^ The last camera a preparation settled ('Nothing' until one has): a camera field can be configured from then on.
  , vsStage ∷ !(TVar Stage)
  , vsStageSerial ∷ !(TVar Word64)
    -- ^ Moves whenever the stage is replaced from outside a step (an ending), so a step's write-back can tell.
  , vsPublished ∷ !(TVar (Maybe Accepted))
    -- ^ The terrain revision the target accepted.
  , vsParts ∷ !(TVar (Map PartKey Part))
    -- ^ The chunks the published revision lists.
  , vsPins ∷ !(TVar (Map Word64 Pinned))
  , vsNextRevision ∷ !(TVar Word64)
  , vsRefused ∷ !(TVar (Maybe (BindingLimit, RefusedAt)))
  , vsRefusals ∷ !(TVar Natural)
  , vsAsked ∷ !(TVar [RegionCoord])
    -- ^ The runtime demand last installed successfully, in order (initially empty).
  , vsReceipt ∷ !(TVar (Maybe Runtime.DemandReceipt))
  , vsInstalls ∷ !(TVar Natural)
    -- ^ How many demand lists were installed with the terrain service (for observation).
    -- ^ The terrain service's receipt for it.
  , vsSurface ∷ !(TVar (Maybe (Column, Revision, KnownSurface)))
    -- ^ The last surface answer: reused for the same column at the same content revision.
  , vsArmed ∷ !(TVar Bool)
    -- ^ The owner found the candidate blocked, in the transaction that decided so: the watcher asks for a step once the
    -- same decision, or the candidate's chunk standings, let it go on.
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

-- | A granted build not yet collected: its receipt, the target its slot is charged to, the view and the attempt (stage
-- serial) that took it and the part it builds. Relinquished to the sweep, with why, it is collected by none but the
-- sweep.
data PendingBuild k = PendingBuild
  { pbReceipt ∷ !Receipt
  , pbTarget ∷ !k
  , pbView ∷ !Word64
  , pbSerial ∷ !Word64
  , pbPart ∷ !PartKey
  , pbSweep ∷ !(Maybe Text)
  }

-- | What a disposal is of: a released chunk, or the buffer a refused build made (no chunk was registered), with its
-- target and view.
data Disposal k
  = DisposeChunk !(Held k)
  | DisposeAllocation !k !Word64 !Text !Text
    -- ^ A failed build's buffer: its target, view, identity and the build's own cause.

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
  , svDisposing ∷ !(TVar [(Disposal k, STM ConstructedDisposal)])
    -- ^ Released chunks, and buffers refused builds made, whose physical disposal the backend has not yet confirmed:
    -- each keeps its slot until then.
  , svFailed ∷ !(TVar [(k, Maybe ChunkRef, Text)])
    -- ^ Terminal failures, with their causes: a chunk whose release or disposal failed keeps its identity and its slot.
  , svPending ∷ !(TVar (Map Word64 (PendingBuild k)))
    -- ^ Granted builds not yet collected, by their receipt's key: each is one build of its view and holds its slot.
  , svSwept ∷ !(TVar (Seq (k, Word64, Text)))
    -- ^ The latest builds the sweep collected in their views' place: target, view, what the build left and why the
    -- sweep took it (at most 64).
  , svNoticed ∷ !(TVar (Natural, Natural, Natural))
    -- ^ The ledger's change count, and the receipts' frame events and presentations, as the watcher last saw them.
  , svUnheld ∷ !(TVar (Seq (Word64, Text)))
    -- ^ The latest builds the registry's teardown sweep claimed that no view held: the receipt's key and what each
    -- left, its cause included (at most 64).
  , svOrphans ∷ !(TVar [ChunkRef])
    -- ^ Registered chunks the registry's teardown sweep found with no pending build: released by the owner, charged to
    -- no target.
  , svOrphanInHand ∷ !(TVar (Maybe ChunkRef))
    -- ^ The orphan the owner is releasing now: it stays named here until its release's outcome is recorded.
  , svOrphansDisposing ∷ !(TVar [(Text, STM ConstructedDisposal)])
    -- ^ Those released, until the backend confirms their disposal.
  , svOrphanFailures ∷ !(TVar [(Text, Text)])
    -- ^ Those whose release or disposal failed, with the cause.
  , svOpen ∷ !(TVar Bool)
  , svScheduled ∷ !(TVar Bool)
    -- ^ A step was admitted and has not started.
  , svStep ∷ !(TVar (Maybe (STM (Maybe StepOutcome))))
    -- ^ How the latest admitted step ended, once it has.
  , svEnded ∷ !(TVar (Maybe Text))
    -- ^ The graphics owner takes no more steps, and why: admission is stopped.
  , svKickWanted ∷ !(TVar Bool)
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
  , svRunning ∷ !(TVar (Maybe Word64))
    -- ^ The view whose job the planner is running: that view starts no preparation until it ends, so a superseded
    -- job's inputs are released before another preparation's copies are taken.
    -- ^ The planner's queue: each view's latest job, which a newer one replaces before it starts.
  , svReserved ∷ !Integer
  , svNoDemand ∷ !(Prepared [RegionDemand])
    -- ^ The empty demand, prepared once: a view's attachment and its withdrawal install it.
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
          if allowance > toInteger (maxBound ∷ Word64)
            then pure False
            else prepare (fromInteger allowance ∷ Word64) >>= commit . accountReserveTx account
        unless reserved $ throwIO (TerrainViewsAccount allowance (-1))
      -- a return past what the account holds is its defect, raised once the commit is over
      release = prepare (fromInteger allowance ∷ Word64) >>= commit . accountReleaseTx account >>= either throwIO pure
  withResourceLabelled "terrain views: the account reservation" reserve (\() → release) $ \() → do
    service ← newService config ports allowance
    mask $ \restore → do
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
      case (outcome, drainedOrNot) of
        (Right result, Right ()) → pure result
        (Right _, Left failure) → rethrowIO failure
        (Left primary, Right ()) → rethrowIO primary
        (Left primary, Left failure) → composeCleanup (Just primary) [("terrain views: the drain", failure)] >>= maybe (rethrowIO primary) rethrowIO

newService ∷ TerrainViewsConfig → TerrainViewsPorts k → Integer → IO (TerrainViews k)
newService config ports allowance = do
  noDemand ← prepare []
  views ← newTVarIO Map.empty
  slots ← newTVarIO Map.empty
  retiring ← newTVarIO Seq.empty
  private ← newTVarIO []
  inHand ← newTVarIO []
  disposing ← newTVarIO []
  failed ← newTVarIO []
  pending ← newTVarIO Map.empty
  swept ← newTVarIO Seq.empty
  unheld ← newTVarIO Seq.empty
  noticed ← newTVarIO (0, 0, 0)
  orphans ← newTVarIO []
  orphanInHand ← newTVarIO Nothing
  orphansDisposing ← newTVarIO []
  orphanFailures ← newTVarIO []
  open ← newTVarIO True
  scheduled ← newTVarIO False
  step ← newTVarIO Nothing
  ended ← newTVarIO Nothing
  wanted ← newTVarIO False
  [planningFrame, planningMax, planningStep, planningStepMax, ownerFrame, ownerMax, ownerStepMax] ← mapM newTVarIO (replicate 7 0)
  jobs ← newTVarIO Map.empty
  running ← newTVarIO Nothing
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
      , svPending = pending
      , svSwept = swept
      , svUnheld = unheld
      , svNoticed = noticed
      , svOrphans = orphans
      , svOrphanInHand = orphanInHand
      , svOrphansDisposing = orphansDisposing
      , svOrphanFailures = orphanFailures
      , svOpen = open
      , svScheduled = scheduled
      , svStep = step
      , svEnded = ended
      , svKickWanted = wanted
      , svPlanningFrame = planningFrame
      , svPlanningMax = planningMax
      , svPlanningStep = planningStep
      , svPlanningStepMax = planningStepMax
      , svOwnerFrame = ownerFrame
      , svOwnerMax = ownerMax
      , svOwnerStepMax = ownerStepMax
      , svJobs = jobs
      , svRunning = running
      , svReserved = allowance
      , svNoDemand = noDemand
      }

-- The watcher: signals only. It blocks until a view's arena mark, the authority epoch, its target's usability or its
-- target's metrics move (an idle target's retirement or first frame), until the views' own
-- outstanding work can go on (a refused kick, a barrier to ask, a chunk to release, a confirmed disposal, a completed
-- offscreen batch), or until the owner has ended; then it asks for the owner's next step, or ends every view.
watch ∷ (Ord k, Show k) ⇒ TerrainViews k → STM Bool → IO ()
watch service stopping = loop
  where
    -- each round waits in a read-only transaction of its own, outside every commit, on what is due; the commit that
    -- acts on it then runs on its own and decides again from what it reads, so a change between the two is met there
    loop =
      atomically ((Nothing <$ (stopping >>= check)) `orElse` (Just <$> due)) >>= \case
        Nothing → pure ()
        Just act → act >> loop
    due =
      (void (commit (sweepPending service)) <$ (sweepDue service >>= check))
        `orElse` (void (atomically (orphanedBuilds service)) <$ (orphansDue service >>= check))
        `orElse` wake
    wake =
      ownerGoneReading service >>= \case
        Just _ → do
          -- admission is stopped: every view ends, which settles its pending moves
          views ← Map.elems <$> readTVar (svViews service)
          if null views then retry else pure (atomically (void (ownerGone service)) >> forM_ views (\vs → endView service vs EndStopped))
        Nothing → (commit (applyMarks service) <$ (marksDue service >>= check)) `orElse` work
    work = do
      noticed ← noticeDue service
      swept ← offscreenSweepDue (portReceipts (svPorts service))
      askable ← barriersDue service
      queued ← stepQueued service
      let wanting = (||) <$> readTVar (svKickWanted service) <*> stepRefusedForNow service
          stepDue = (||) <$> wanting <*> retirementReady service
      wanted ← if queued then pure False else stepDue
      admits ← ownerAdmits (portOwner (svPorts service))
      if
        | noticed || swept → pure (commit (own ((||) <$> notice service <*> sweepOffscreen (portReceipts (svPorts service))) >>= \moved → when moved (kick service)))
        | askable → pure (commit (askBarriers service >>= \asked → when asked (kick service)))
        -- the decision is taken again in the admitting commit
        | wanted && admits → pure (void (commit (admitDue service stepDue)))
        | otherwise → retry

-- Each open view's marks as the watcher compares them, with whether its armed candidate can go on and what the
-- watcher last saw of it. Read-only.
viewMarks ∷ Ord k ⇒ TerrainViews k → STM [(ViewState k, Bool, Marks, Marks)]
viewMarks service = do
  views ← Map.elems <$> readTVar (svViews service)
  epoch ← Runtime.authorityEpochSTM (portTerrain (svPorts service))
  forM views $ \vs → do
    armed ← readTVar (vsArmed vs)
    actionable ← if armed then buildActionable service vs else pure False
    mark ← vsMarkCell vs
    usable ← surfaceUsable (vtSurface (vsTarget vs))
    geometry ← surfaceGeometry (vtSurface (vsTarget vs))
    authority ← authorityOf vs
    revisions ← authorityRevisions vs
    -- the view's request in flight and whether it has settled: its settlement asks for the owner's step, once for each
    -- request, whether it settled before the watcher first saw it or after
    flight ← flightMark vs
    seen ← readTVar (vsSeen vs)
    pure (vs, actionable, (mark, epoch, usable, geometry, authority, revisions, flight), seen)

-- | Whether a view's marks moved or its armed candidate can go on: the watcher's wait, read-only.
marksDue ∷ Ord k ⇒ TerrainViews k → STM Bool
marksDue service = any (\(_, actionable, now, seen) → actionable || now /= seen) <$> viewMarks service

-- The commit that acts on moved marks: an armed view whose candidate can go on is disarmed, the marks seen are recorded,
-- and the owner's step is asked for when either moved.
applyMarks ∷ (Ord k, Show k) ⇒ TerrainViews k → OwnerTx ()
applyMarks service = do
  moved ← own $ do
    marks ← viewMarks service
    fmap or . forM marks $ \(vs, actionable, now, seen) → do
      when actionable (writeTVar (vsArmed vs) False)
      unless (now == seen) (writeTVar (vsSeen vs) now)
      pure (actionable || now /= seen)
  when moved (kick service)

-- The ledger's and the receipts' counts against those the watcher last saw: a change since asks for the owner's next
-- step, and a presentation ends the frame's accounting. Read in the watcher's own transaction: no view's code runs in
-- an adoption, a release or a frame event.
notice ∷ TerrainViews k → STM Bool
notice service = do
  changes ← ledgerChanges (portLedger (svPorts service))
  (events, presentations) ← receiptsFrames (portReceipts (svPorts service))
  seen@(_, _, presented) ← readTVar (svNoticed service)
  let now = (changes, events, presentations)
  when (presentations /= presented) (frameEnded service)
  if now == seen then pure False else True <$ writeTVar (svNoticed service) now

-- Whether the ledger's or the receipts' counts moved since the watcher last saw them: the watcher's wait, read-only.
noticeDue ∷ TerrainViews k → STM Bool
noticeDue service = do
  changes ← ledgerChanges (portLedger (svPorts service))
  (events, presentations) ← receiptsFrames (portReceipts (svPorts service))
  (/= (changes, events, presentations)) <$> readTVar (svNoticed service)

-- Whether builds no step will collect are pending: the decision 'orphanedBuilds' records, read-only.
orphansDue ∷ TerrainViews k → STM Bool
orphansDue service = do
  running ← stepUnsettled service
  if running
    then pure False
    else readTVar (svPending service) >>= fmap or . mapM (\entry → if isNothing (pbSweep entry) then isJust <$> receiptOutcome (pbReceipt entry) else pure False) . Map.elems

-- Whether a failed handback still protects a retirement: what 'handOffProtected' hands to the session's teardown.
protectedDue ∷ TerrainViews k → STM Bool
protectedDue service = any rtProtected . toList <$> readTVar (svRetiring service)

-- | The ledger's change count as the views' watcher last saw it: once it has reached a change, the watcher has asked for
-- the owner's step that change may need.
ledgerNoticed ∷ TerrainViews k → STM Natural
ledgerNoticed service = (\(changes, _, _) → changes) <$> readTVar (svNoticed service)

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
        Just ((key, job), rest) → do
          writeTVar (svJobs service) rest
          writeTVar (svRunning service) (Just key)
          pure (job `finally` commit (own (writeTVar (svRunning service) Nothing) >> kick service))

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
    commit (own (void (tryPutTMVar box result)) >> kick service)

-- | Ask for the owner's next step: one admission, unless one is already queued or the owner has ended. Never waits.
kick ∷ (Ord k, Show k) ⇒ TerrainViews k → OwnerTx ()
kick service = do
  (queued, ended) ← own ((,) <$> stepQueued service <*> readTVar (svEnded service))
  unless (queued || isJust ended) (void (admit service))

-- | Admit one step if, in this commit, none is queued, the owner has not ended, and the work its waiter found is still
-- due: a waiter decides to admit outside any commit, and a kick may have queued a step before its commit. Never two
-- queued steps.
admitDue ∷ (Ord k, Show k) ⇒ TerrainViews k → STM Bool → OwnerTx Bool
admitDue service due =
  own ((,,) <$> stepQueued service <*> readTVar (svEnded service) <*> due) >>= \case
    (False, Nothing, True) → admit service
    _ → pure False

-- Admit one step, through the owner's own admission. Answers whether anything changed: a step admitted, or the owner
-- found ended (a full queue or a device not yet ready leaves the kick wanted, for the watcher to admit once the queue
-- changes).
admit ∷ (Ord k, Show k) ⇒ TerrainViews k → OwnerTx Bool
admit service =
  ownerSchedule (portOwner (svPorts service)) (stepOwner service) >>= \case
    Right reading → own $ do
      writeTVar (svScheduled service) True
      writeTVar (svStep service) (Just reading)
      writeTVar (svKickWanted service) False
      pure True
    Left ScheduleBusy → own (False <$ writeTVar (svKickWanted service) True)
    Left (ScheduleEnded why) → own (True <$ endOwner service ("the graphics owner takes no more steps: " <> why))

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
ownerGone service = ownerGoneReading service >>= \gone → gone <$ for_ gone (endOwner service)

-- Whether the owner has ended, read-only: the decision 'ownerGone' records.
ownerGoneReading ∷ TerrainViews k → STM (Maybe Text)
ownerGoneReading service =
  readTVar (svEnded service) >>= \case
    Just why → pure (Just why)
    Nothing → do
      failed ← ownerEnded (portOwner (svPorts service))
      outcome ← readTVar (svStep service) >>= maybe (pure Nothing) id
      -- a step's own failure while the owner lives, or a refusal that can change, ends nothing: the owner goes on (a
      -- refused step is asked for again) and the step's work is the sweep's; a cancellation or a terminal exit ends
      -- admission
      let refused = case outcome of
            Just (StepExit (Exit.Terminal (Left why))) → Just ("the graphics owner refused a step: " <> why)
            Just (StepExit (Exit.Cancelled _)) → Just "a step was cancelled"
            Just (StepExit (Exit.Terminal (Right _))) → Just "a step raised once the graphics owner had ended"
            _ → Nothing
          gone = (("the graphics owner ended: " <>) <$> failed) <|> refused
      pure gone

-- Whether the latest step was refused for now (the owner's queue full, its device not ready): it is asked for again.
stepRefusedForNow ∷ TerrainViews k → STM Bool
stepRefusedForNow service =
  readTVar (svStep service) >>= maybe (pure Nothing) id <&> \case
    Just (StepExit (Exit.Refused _)) → True
    _ → False

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
      -- the views' builds were left to the sweep when they ended: in-flight ones are swept once they seal
      _ ← atomically (orphanedBuilds service)
      _ ← commit (sweepPending service)
      -- the drain waits read-only, outside every commit, on what is due; the commit that acts on it decides again
      due ← atomically $
        ownerGoneReading service >>= \case
          Just _ → pure DrainAbandon
          Nothing → do
            protected ← protectedDue service
            running ← stepUnsettled service
            done ← drained service
            if
              | protected → pure DrainHandOff
              | running → retry
              | done → pure DrainFinish
              | otherwise → do
                  sweepable ← anySealed service
                  askable ← barriersDue service
                  ready ← (||) <$> retirementReady service <*> stepRefusedForNow service
                  admits ← ownerAdmits (portOwner (svPorts service))
                  if
                    | sweepable → pure DrainAgain
                    | askable → pure DrainBarriers
                    | ready && admits → pure DrainAdmit
                    | otherwise → retry
      case due of
        DrainAbandon → void . atomically $ ownerGone service >>= traverse (\why → abandonRetirements service ("the graphics owner ended before disposal: " <> why))
        DrainHandOff → atomically (handOffProtected service) >> drain
        DrainFinish → do
          -- the final commit closes step admission only while the drain is still done there: no kick queues a step
          -- after it
          closed ← atomically $ do
            running ← stepUnsettled service
            done ← drained service
            if not running && done then True <$ endOwner service "the views' service has ended" else pure False
          unless closed drain
        DrainAgain → drain
        DrainBarriers → commit (askBarriers service) >> drain
        DrainAdmit → commit (admitDue service ((||) <$> retirementReady service <*> stepRefusedForNow service)) >> drain

-- What the drain's wait found due.
data Drain = DrainAbandon | DrainHandOff | DrainFinish | DrainAgain | DrainBarriers | DrainAdmit

-- Whether nothing of the views' chunks is left to dispose of.
drained ∷ TerrainViews k → STM Bool
drained service = do
  retiring ← readTVar (svRetiring service)
  private ← readTVar (svPrivate service)
  inHand ← readTVar (svInHand service)
  disposing ← readTVar (svDisposing service)
  pending ← readTVar (svPending service)
  orphans ← readTVar (svOrphans service)
  orphanInHand ← readTVar (svOrphanInHand service)
  orphansDisposing ← readTVar (svOrphansDisposing service)
  (held, _) ← ownerReceiptsHeld (portOwner (svPorts service))
  pure (Seq.null retiring && null private && null inHand && null disposing && Map.null pending && null orphans && isNothing orphanInHand && null orphansDisposing && held == 0)

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
      <> [(k, Just chunk, cause) | (k, _, chunk) ← private <> inHand]
      <> [disposalFailure entry cause | (entry, _) ← disposing]
  writeTVar (svRetiring service) Seq.empty
  writeTVar (svPrivate service) []
  writeTVar (svInHand service) []
  writeTVar (svDisposing service) []
  -- orphans, which charge no target, keep their identities with the cause
  orphans ← readTVar (svOrphans service)
  orphanInHand ← readTVar (svOrphanInHand service)
  orphansDisposing ← readTVar (svOrphansDisposing service)
  modifyTVar' (svOrphanFailures service) (<> [(Text.pack (show chunk), cause) | chunk ← orphans <> toList orphanInHand] <> [(identity, cause) | (identity, _) ← orphansDisposing])
  writeTVar (svOrphans service) []
  writeTVar (svOrphanInHand service) Nothing
  writeTVar (svOrphansDisposing service) []

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
-- the style's GPU interests, the receipt and the view. A target that shows nothing and has no frame metrics yet is
-- published the real empty revision in that transaction, which asks it for the first frame its views plan for; a
-- target showing a scene keeps it until the view's first revision is published. A refusal leaves nothing behind.
openView ∷ (Ord k, Show k) ⇒ TerrainViews k → OpenRequest k → IO (Either OpenRefusal (TerrainView k))
openView service request = mask_ $ do
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
          Right camera → do
            -- the caller's authority lists are evaluated in full here, before anything is acquired or committed: a list
            -- that raises leaves everything as it was (the style's, once acquired, releases it first)
            _ ← evaluate (spineOf (surfaceAuthorities (vtSurface target)))
            -- masked: the style is recorded (its release attached) in the handoff that acquires it; only its own
            -- interruptible waits can be interrupted
            openStyle request >>= \case
              Left why → pure (Left (OpenStyle why))
              Right style → do
                let undo = styleRelease style
                _ ← evaluate (spineOf (styleAuthority style)) `onException` undo
                cell ← atomically (Runtime.arenaMarkSTM (portTerrain ports) (openLease request)) `onException` undo
                case cell of
                  Left why → undo >> pure (Left (OpenArena why))
                  Right markCell → do
                    -- the runtime view is attached in the commit that takes the claim, or not at all
                    committed ← commit (commitOpen service request style markCell camera) `onException` undo
                    case committed of
                      Left why → undo >> pure (Left why)
                      Right vs → do
                        commit (kick service)
                        pure (Right (TerrainView service vs))

-- Every element of a list evaluated, and the list's spine: an authority's own fields are strict.
spineOf ∷ [a] → ()
spineOf = foldr seq ()

newViewState ∷ TerrainViews k → OpenRequest k → ViewStyle → Runtime.View → STM (Maybe ArenaMark) → CameraState → STM (ViewState k)
newViewState service request style rview markCell camera = do
  incarnation ← newClaimHolder (portClaims (svPorts service))
  ViewState incarnation (openTarget request) (openLease request) rview style markCell
    <$> newTVar (Nothing, 0, True, GeometryUnknown, True, [], Nothing)
    <*> newTVar ViewOpen
    <*> newTVar camera
    <*> newTVar (openLight request)
    <*> newTVar 0
    <*> newTVar Map.empty
    <*> newTVar Nothing
    <*> newTVar Idle
    <*> newTVar 0
    <*> newTVar Nothing
    <*> newTVar Map.empty
    <*> newTVar Map.empty
    <*> newTVar 1
    <*> newTVar Nothing
    <*> newTVar 0
    <*> newTVar []
    <*> newTVar Nothing
    <*> newTVar 0
    <*> newTVar Nothing
    <*> newTVar False

-- The view's attachment, one commit: every guard first (the service, the original authority, the target, the arena, the
-- style's materials, the target bound, the target's claim free); then the runtime view, attached for the views' client
-- (its admission checks the parent session's token); then its empty demand under the view's authority, which asks the
-- terrain service whether the client owns the arena lease (refused, the runtime view is detached again in this commit);
-- then the view itself, the claim and its interests. A refusal leaves nothing attached.
commitOpen ∷ (Ord k, Show k) ⇒ TerrainViews k → OpenRequest k → ViewStyle → STM (Maybe ArenaMark) → CameraState → OwnerTx (Either OpenRefusal (ViewState k))
commitOpen service request style markCell camera = do
  let ports = svPorts service
      target = openTarget request
      key = vtKey target
      terrain = portTerrain ports
  refused ← own $ do
    open ← readTVar (svOpen service)
    ended ← readTVar (svEnded service)
    authority ← (&&) <$> surfaceAuthority (vtSurface target) <*> leasesLive (styleAuthority style)
    usable ← surfaceUsable (vtSurface target)
    views ← readTVar (svViews service)
    slots ← readTVar (svSlots service)
    arena ← Runtime.inspectArenaSTM terrain (openLease request)
    claimed ← isJust <$> claimOf (portClaims ports) key
    let inUse = Set.fromList (map (vtKey . vsTarget) (Map.elems views)) <> Map.keysSet slots
        unmapped = maybe [] (filter (`Set.notMember` styleMapped style) . paletteMaterials . viewPalette) arena
    pure $
      if
        | not open || isJust ended → Just OpenStopped
        | not authority → Just OpenLeaseEnded
        | not usable → Just OpenTargetUnusable
        | isNothing arena → Just (OpenArena Runtime.RefusedAuthority)
        | not (null unmapped) → Just (OpenStyle (StyleMissingMaterials unmapped))
        | Set.notMember key inUse && Set.size inUse >= profileTargets (tvProfile (svConfig service)) → Just OpenTooManyViews
        | claimed → Just OpenTargetClaimed
        | otherwise → Nothing
  case refused of
    Just why → pure (Left why)
    Nothing →
      -- the runtime view and its empty demand, staged: a refusal of either writes nothing in the runtime
      attachViewTx terrain (portClient ports) (openLease request) (svNoDemand service) >>= \case
        Left why → pure (Left (OpenArena why))
        Right (rview, _) → do
          (vs, geometry) ← own $ do
            vs ← newViewState service request style rview markCell camera
            -- the claim is free: this commit read it so
            _ ← takeClaim (portClaims ports) key (vsId vs)
            forM_ (Set.toList (styleParents style)) (ledgerRetainInterest (portLedger ports))
            modifyTVar' (svViews service) (Map.insert (vsId vs) vs)
            openReceipt (portReceipts ports) (vsId vs)
            surfaceBind (vtSurface target)
            (,) vs <$> surfaceGeometry (vtSurface target)
          -- a target that shows nothing yet is asked for its first frame with the real empty revision; one that
          -- shows a scene keeps it until the view's first revision replaces it (its frame gives the metrics): its
          -- host decides
          when (geometry == GeometryUnknown) (surfacePublishUnlessShown (vtSurface target) (portInitial ports))
          pure (Right vs)

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
-- settles at the camera's transition, once a preparation of the destination has copied what the destination camera
-- reads (and, for a jump with a level, its destination part is ready); with recoverable pressure when that preparation
-- is refused or the part is not ready. A newer move or camera change cancels it; a lighting change does not.
moveView ∷ (Ord k, Show k) ⇒ TerrainView k → Prepared JumpTarget → OwnerTx (Either ControlRefusal PendingMove)
moveView (TerrainView service vs) prepared =
  admitControl service vs >>= \case
    Just _ → pure (Left ControlEnded)
    Nothing → do
      -- the jump always waits for a preparation of its destination: whatever facts the view holds of it, it lands only
      -- at the camera transition of a preparation that copied its destination
      camera ← own (supersede vs >> readTVar (vsCamera vs))
      case requestJump (tvCamera (svConfig service)) (preparedValue prepared) camera of
        Left why → pure (Left (ControlInvalid why))
        Right step → do
          own (writeTVar (vsCamera vs) (stepCamera step))
          bumpIntent service vs
          own $ do
            box ← newTVar Nothing
            case stepJump step of
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

-- | A partial update is fully evaluated before the commit that applies it.
instance NFData Configure where
  rnf (Configure zoom facing depth light) = rnf zoom `seq` rnf facing `seq` rnf depth `seq` rnf light

-- | Apply a validated partial update atomically, or nothing. A camera field needs the view's terrain facts and is
-- busy until it has them; a camera change cancels a pending move, a lighting change does not.
configureView ∷ (Ord k, Show k) ⇒ TerrainView k → Prepared Configure → OwnerTx (Either ControlRefusal ())
configureView (TerrainView service vs) prepared
  | null commands =
      admitControl service vs >>= \case
        Just _ → pure (Left ControlEnded)
        Nothing → case configureLight update of
          Nothing → pure (Right ())
          Just light → Right () <$ (own (writeTVar (vsLight vs) light) >> bumpIntent service vs)
  | otherwise =
      controlled service vs $ \camera →
        case foldl (\acc command → acc >>= \c → stepCamera <$> applyLocal (tvCamera (svConfig service)) command c) (Right camera) commands of
          Left why → pure (Left (ControlInvalid why))
          Right moved → do
            own $ do
              supersede vs
              writeTVar (vsCamera vs) (maybe moved (\p → cancelJump (pendingId p) moved) (camPending moved))
              for_ (configureLight update) (writeTVar (vsLight vs))
            bumpIntent service vs
            pure (Right ())
  where
    update = preparedValue prepared
    commands = catMaybes [SetZoom <$> configureZoom update, SetFacing <$> configureFacing update, SelectSlice <$> configureDepth update]

controlled ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → (CameraState → OwnerTx (Either ControlRefusal a)) → OwnerTx (Either ControlRefusal a)
controlled service vs body =
  admitControl service vs >>= \case
    Just _ → pure (Left ControlEnded)
    Nothing →
      own ((,) <$> readTVar (vsSettled vs) <*> readTVar (vsCamera vs)) >>= \case
        (Nothing, _) → pure (Left ControlBusy)
        (Just _, camera) → body camera

-- | Whether a control may be admitted, read live in the control's own transaction: the view open, the service
-- admitting, the target usable, the view's original authority held and its arena lease live. When it may not, the
-- ending it shows ends the pending moves (never as superseded) and the owner is asked to end the view; nothing else
-- changes.
admitControl ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → OwnerTx (Maybe Ending)
admitControl service vs = do
  ending ← own (controlEnding service vs)
  for_ ending (\_ → kick service)
  pure ending

-- The ending a control finds, read live, with the pending moves it ends settled.
controlEnding ∷ TerrainViews k → ViewState k → STM (Maybe Ending)
controlEnding service vs = do
  status ← readTVar (vsStatus vs)
  open ← readTVar (svOpen service)
  ended ← readTVar (svEnded service)
  -- the graphics owner's own gate, live: a control in the instant its exit began is refused, whatever the watcher has
  -- recorded yet
  gone ← ownerEnded (portOwner (svPorts service))
  usable ← surfaceUsable (vtSurface (vsTarget vs))
  authority ← authorityOf vs
  arena ← Runtime.inspectArenaSTM (portTerrain (svPorts service)) (vsLease vs)
  let ending = case status of
        ViewEnded why → Just why
        ViewOpen
          | not open || isJust ended || isJust gone → Just EndStopped
          | not usable → Just EndTargetGone
          | not authority || isNothing arena → Just EndRevoked
          | otherwise → Nothing
  for_ ending $ \why → do
    moves ← readTVar (vsMoves vs)
    forM_ (Map.elems moves) (settleOnce (MoveEnded why))
    writeTVar (vsMoves vs) Map.empty
  pure ending

-- Settle every pending move as superseded and cancel the camera's pending jump.
supersede ∷ ViewState k → STM ()
supersede vs = do
  moves ← readTVar (vsMoves vs)
  forM_ (Map.elems moves) (settleOnce MoveSuperseded)
  writeTVar (vsMoves vs) Map.empty
  modifyTVar' (vsCamera vs) (\camera → maybe camera (\p → cancelJump (pendingId p) camera) (camPending camera))

settleOnce ∷ MoveOutcome → TVar (Maybe MoveOutcome) → STM ()
settleOnce outcome box = readTVar box >>= maybe (writeTVar box (Just outcome)) (const (pure ()))

bumpIntent ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → OwnerTx ()
bumpIntent service vs = own (modifyTVar' (vsIntent vs) (+ 1)) >> kick service

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
        held ← (<>) <$> readTVar (svPrivate service) <*> readTVar (svInHand service)
        disposing ← map fst <$> readTVar (svDisposing service)
        building ← any ((== vsId vs) . pbView) . Map.elems <$> readTVar (svPending service)
        let ofView = \case
              DisposeChunk (_, v, _) → v == vsId vs
              DisposeAllocation _ v _ _ → v == vsId vs
        pure (if building || any ((== vsId vs) . rtView) retiring || any (\(_, v, _) → v == vsId vs) held || any ofView disposing then CloseRetiring else CloseDone)

-- End a view, once: 'False' when it had already ended. The transaction does every state change; the terrain service's
-- calls and the style's release follow it.
endView ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Ending → IO Bool
endView service vs ending = uninterruptibleMask_ $ do
  ended ← commit (endViewSTM service vs ending)
  case ended of
    Nothing → pure False
    Just flight → do
      for_ flight (abandonFlight service)
      styleRelease (vsStyle vs)
      pure True

endViewSTM ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Ending → OwnerTx (Maybe (Maybe InFlight))
endViewSTM service vs ending =
  own (readTVar (vsStatus vs)) >>= \case
    ViewEnded _ → pure Nothing
    ViewOpen → do
      let ports = svPorts service
          target = vsTarget vs
          key = vtKey target
      -- the runtime view is detached, its demand withdrawn, in the commit that releases the claim: a successor that takes
      -- the claim finds it gone
      closeViewTx (portTerrain ports) (vsRuntime vs)
      released ← own $ do
        writeTVar (vsStatus vs) (ViewEnded ending)
        (,) <$> releaseClaim (portClaims ports) key (vsId vs) <*> surfaceUsable (vtSurface target)
      -- the claim: a published one is handed back with a real empty revision in this commit
      handed ← case released of
        (Just claim, usable) | claimPublished claim, ending /= EndTargetGone → if usable then surfacePublish (vtSurface target) (portInitial ports) else pure False
        _ → pure True
      flight ← own (endState service vs ending handed)
      kick service
      pure (Just flight)

-- The rest of a view's ending, the views' own: its interests, its moves, its builds left to the sweep, its receipt and
-- frame metrics, its stage, and its parts to retirement.
endState ∷ TerrainViews k → ViewState k → Ending → Bool → STM (Maybe InFlight)
endState service vs ending handed = do
      let ports = svPorts service
          target = vsTarget vs
          key = vtKey target
      forM_ (Set.toList (styleParents (vsStyle vs))) (ledgerDropInterest (portLedger ports))
      moves ← readTVar (vsMoves vs)
      forM_ (Map.elems moves) (settleOnce (MoveEnded ending))
      writeTVar (vsMoves vs) Map.empty
      -- its granted builds are collected by the sweep, in place of the view
      modifyTVar' (svPending service) (Map.map (\entry → if pbView entry == vsId vs then entry {pbSweep = Just "its view ended"} else entry))
      forgetReceipt (portReceipts ports) (vsId vs)
      surfaceUnbind (vtSurface target)
      writeTVar (vsPins vs) Map.empty
      flight ← takeStage service vs
      parts ← readTVar (vsParts vs)
      writeTVar (vsParts vs) Map.empty
      unless (Map.null parts) $
        modifyTVar' (svRetiring service) (|> Retiring key (vsId vs) (map partChunk (Map.elems parts)) Unasked (not handed))
      modifyTVar' (svViews service) (Map.delete (vsId vs))
      pure flight

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
    Surfacing _ _ _ flight → pure (Just flight)
    Copying _ _ _ flight → pure (snd <$> flight)
    _ → pure Nothing

privately ∷ TerrainViews k → ViewState k → [ChunkRef] → STM ()
privately service vs chunks = modifyTVar' (svPrivate service) (<> [(vtKey (vsTarget vs), vsId vs, chunk) | chunk ← chunks])

-- Cancel a request in flight; a borrow that settlement won is taken and returned.
abandonFlight ∷ TerrainViews k → InFlight → IO ()
abandonFlight service flight = do
  let terrain = portTerrain (svPorts service)
  _ ← cancelViewRequest terrain (flightRequest flight)
  commit (finishSettled terrain flight)

-- Finish a request whose settlement is in its box, by its handle alone: a borrow not yet taken is taken and returned,
-- any other answer retired. A request taken already, or not settled, is left as it is.
finishSettled ∷ Runtime.Service → InFlight → OwnerTx ()
finishSettled terrain flight =
  own (flightSettled flight) >>= \case
    Just (Succeeded (Runtime.ARegions borrow)) →
      takeViewRequestTx terrain (flightRequest flight) >>= \case
        Taken → releaseRegionBorrowTx terrain borrow
        TakeReleased → pure ()
    Just _ → retireViewRequestTx terrain (flightRequest flight)
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
  when (busy || retired) (commit (kick service))

-- Whether the view did something a further step can continue at once.
stepView ∷ (Ord k, Show k) ⇒ TerrainViews k → Hands → ViewState k → IO Bool
stepView service hands vs = do
  let ports = svPorts service
      target = vsTarget vs
  ending ← atomically $ do
    status ← readTVar (vsStatus vs)
    usable ← surfaceUsable (vtSurface target)
    authority ← authorityOf vs
    arena ← Runtime.inspectArenaSTM (portTerrain ports) (vsLease vs)
    pure $ case status of
      ViewEnded _ → Just Nothing
      ViewOpen
        | not usable → Just (Just EndTargetGone)
        | not authority || isNothing arena → Just (Just EndRevoked)
        | otherwise → Nothing
  case ending of
    Just Nothing → pure False
    Just (Just why) → False <$ endView service vs why
    Nothing → do
      checkPublished service vs
      demanded ← commit (reconcileDemand service vs)
      (serial, stage, basis) ← atomically ((,,) <$> readTVar (vsStageSerial vs) <*> readTVar (vsStage vs) <*> currentBasis service vs)
      case stage of
        Idle → (demanded ||) <$> startIfDue service vs serial basis
        Surfacing at metrics column flight
          | at /= basis → abandon service vs serial >> pure True
          | otherwise → stepSurfacing service vs serial at metrics column flight
        Footprinting prep box
          | stale prep basis → abandon service vs serial >> pure True
          | otherwise → stepFootprinting service vs serial prep box
        Copying prep batches taken flight
          | stale prep basis → abandon service vs serial >> pure True
          | otherwise → stepCopying service vs serial prep batches taken flight
        Inputting prep taken box
          | stale prep basis → abandon service vs serial >> pure True
          | otherwise → stepSettling service vs serial prep taken box
        Planning prep copies camera box
          | stale prep basis → abandon service vs serial >> pure True
          | otherwise → stepPlanning service vs serial prep copies camera box
        Building prep candidate
          | stale prep basis → abandon service vs serial >> pure True
          | otherwise → stepBuilding service hands vs serial prep candidate
  where
    stale prep basis = prepBasis prep /= basis

currentBasis ∷ TerrainViews k → ViewState k → STM Basis
currentBasis service vs = do
  intent ← readTVar (vsIntent vs)
  geometry ← surfaceGeometry (vtSurface (vsTarget vs))
  arena ← Runtime.inspectArenaSTM (portTerrain (svPorts service)) (vsLease vs)
  pure (Basis intent geometry ((\a → (Runtime.viewIncarnation a, viewRevision a, viewKnowledgeRevision a)) <$> arena))

currentResidency ∷ TerrainViews k → ViewState k → STM (Maybe Word64)
currentResidency service vs = fmap (fromIntegral . viewGeneration) <$> Runtime.inspectArenaSTM (portTerrain (svPorts service)) (vsLease vs)

-- A published revision whose chunk failed its upload can never draw: its parts are dropped, so the accepted revision
-- is no longer valid (it lists more parts than are left) and the view prepares again.
checkPublished ∷ TerrainViews k → ViewState k → IO ()
checkPublished service vs = atomically $ do
  parts ← readTVar (vsParts vs)
  standings ← forM (Map.toList parts) $ \(key, part) → (,) key <$> ownerStanding (portOwner (svPorts service)) (partChunk part)
  let failed = [key | (key, Just (ChunkFailed _)) ← standings]
  unless (null failed) $ do
    -- the revision that lists them stays published until a rebuilt one replaces it; they retire behind it
    writeTVar (vsParts vs) (foldr Map.delete parts failed)
    modifyTVar' (svRetiring service) (|> Retiring (vtKey (vsTarget vs)) (vsId vs) (mapMaybe (fmap partChunk . (`Map.lookup` parts)) failed) Unasked False)
    writeTVar (vsRefused vs) Nothing

-- Reconcile the view's runtime demand with the one its state prescribes: on a drawable target, the accepted revision's
-- (empty before the first); otherwise empty. A differing installed list is replaced once, under the live authority,
-- and its receipt recorded; a refused replacement is a current refusal at this basis, suppressed while the basis and the
-- desired list stay as they were. Answers whether it changed anything.
reconcileDemand ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → OwnerTx Bool
reconcileDemand service vs =
  own (demandDue service vs) >>= \case
    Nothing → pure False
    Just (desired, prepared, basis) →
      install desired prepared >>= \case
        Right receipt → own (True <$ (writeTVar (vsAsked vs) desired >> writeTVar (vsReceipt vs) (Just receipt) >> modifyTVar' (vsInstalls vs) (+ 1)))
        Left why → own $ do
          let limit = LimitRuntime ("the terrain service refused the view's demand: " <> why)
          pressure vs limit
          recordRefusal vs limit (RefusedAt basis Nothing (Just desired))
          pure True
  where
    install desired prepared =
      own (hookDemandRefused (portCopyHooks (svPorts service)) desired) >>= \case
        Just why → pure (Left why)
        Nothing → either (Left . Text.pack . show) Right <$> setViewDemandTx (portTerrain (svPorts service)) (vsRuntime vs) (vsLease vs) prepared

-- The demand a view's state prescribes, when it differs from the installed one and no current refusal suppresses it,
-- prepared, with the basis it is asked at.
demandDue ∷ TerrainViews k → ViewState k → STM (Maybe ([RegionCoord], Prepared [RegionDemand], Basis))
demandDue service vs = do
  status ← readTVar (vsStatus vs)
  open ← readTVar (svOpen service)
  ended ← readTVar (svEnded service)
  usable ← surfaceUsable (vtSurface (vsTarget vs))
  authority ← authorityOf vs
  arena ← Runtime.inspectArenaSTM (portTerrain (svPorts service)) (vsLease vs)
  gone ← ownerEnded (portOwner (svPorts service))
  geometry ← surfaceGeometry (vtSurface (vsTarget vs))
  accepted ← readTVar (vsPublished vs)
  installed ← readTVar (vsAsked vs)
  let (desired, prepared) = case geometry of
        GeometryExtent _ | Just held ← accepted → (accDemand held, accPrepared held)
        _ → ([], svNoDemand service)
      -- an ending (a revoked authority or lease, a retired target) is the step's to settle, never a demand refusal
      live = status == ViewOpen && open && isNothing ended && isNothing gone && usable && authority && isJust arena
  if not live || desired == installed
    then pure Nothing
    else do
      basis ← currentBasis service vs
      refused ← readTVar (vsRefused vs)
      let suppressed = case refused of
            Just (_, RefusedAt at _ (Just list)) → at == basis && list == desired
            _ → False
      pure (if suppressed then Nothing else Just (desired, prepared, basis))

-- The runtime demand of a list of regions: each whole.
demandsOf ∷ [RegionCoord] → [RegionDemand]
demandsOf regions = [RegionDemand region coverage | region ← regions, Right coverage ← [coverageBox 0 16 0 16 0 32]]

-- The slots of a target that can still come free: its chunks retiring, private, in the owner's hand or awaiting
-- confirmed disposal (refused builds' buffers included). A failure keeps its slot for good and is not among them.
freeing ∷ Eq k ⇒ TerrainViews k → k → STM Int
freeing service key = do
  retiring ← readTVar (svRetiring service)
  private ← readTVar (svPrivate service)
  inHand ← readTVar (svInHand service)
  disposing ← readTVar (svDisposing service)
  pure $
    sum [length (rtChunks r) | r ← toList retiring, rtTarget r == key]
      + length [() | (k, _, _) ← private <> inHand, k == key]
      + length [() | (entry, _) ← disposing, disposalTarget entry == key]

-- The slots a candidate of the target could have: those free now and those that can still come free, each once.
recoverableSlots ∷ Ord k ⇒ TerrainViews k → ViewState k → STM Int
recoverableSlots service vs = (+) <$> freeSlots service vs <*> freeing service (vtKey (vsTarget vs))

-- The target's free slots.
freeSlots ∷ Ord k ⇒ TerrainViews k → ViewState k → STM Int
freeSlots service vs = do
  occupied ← Map.findWithDefault 0 (vtKey (vsTarget vs)) <$> readTVar (svSlots service)
  pure (profileSlots (tvProfile (svConfig service)) - occupied)

-- Start a preparation when the view's state asks for one and no current refusal applies: on a drawable target, when
-- the accepted revision is not of the current basis or is no longer valid; at a zero geometry, only to settle a
-- pending move; never while the geometry is unknown. A refusal applies while its basis is current and, for a refusal
-- over the target's slots, while the target's free slots are fewer than the attempt needed. The followed column's
-- surface comes first (asked of the terrain service, or reused from its last answer for the column at this content
-- revision), then F.
startIfDue ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Basis → IO Bool
startIfDue service vs serial basis = do
  decision ← commit $ do
   (metrics, stillRefused, running, camera, cached) ← own $ do
    running ← (== Just (vsId vs)) <$> readTVar (svRunning service)
    accepted ← readTVar (vsPublished vs)
    parts ← readTVar (vsParts vs)
    refused ← readTVar (vsRefused vs)
    camera ← readTVar (vsCamera vs)
    free ← freeSlots service vs
    let current = case accepted of
          Just acc → accBasis acc == basis && Map.size parts == accParts acc
          Nothing → False
        moving = isJust (camPending camera)
        stillRefused = case refused of
          Just (_, RefusedAt at need _) → at == basis && maybe True (> free) need
          Nothing → False
        metrics = case basisGeometry basis of
          GeometryExtent m | not current → Just (Just m)
          GeometryZero | moving → Just Nothing
          _ → Nothing
    -- a refusal whose basis no longer applies (or whose missing slots are free again) retires: a new refusal is a new
    -- entry, counted once
    when (isJust refused && not stillRefused) (writeTVar (vsRefused vs) Nothing)
    cached ← readTVar (vsSurface vs)
    pure (metrics, stillRefused, running, camera, cached)
   case metrics of
      Just extent | not stillRefused && not running →
        case followedColumn camera of
          Nothing → Nothing <$ footprint extent camera Nothing
          Just column → case (cached, basisArena basis) of
            (Just (at, revision, known), Just (_, content, _))
              | at == column && revision == content → Nothing <$ footprint extent camera (Just (known, revision))
            _ → pure (Just (extent, column))
      _ → pure Nothing
  case decision of
    Nothing → atomically (isStarted <$> readTVar (vsStage vs))
    Just (metrics, column) → do
      let terrain = portTerrain (svPorts service)
      mask $ \_ →
        requestViewSurface terrain (vsLease vs) column >>= \case
          Left why → False <$ commit (refuse service vs serial basis (LimitRuntime ("the surface could not be asked for: " <> Text.pack (show why))))
          Right request → do
            let flight = InFlight request
            kept ← commit (writeBack service vs serial basis (Surfacing basis metrics column flight))
            unless kept (abandonFlight service flight)
            pure False
  where
    isStarted = \case
      Idle → False
      _ → True
    footprint metrics camera known = do
      (box, prep) ← own ((,) <$> newEmptyTMVar <*> prepFor service basis metrics camera known)
      kept ← writeBack service vs serial basis (Footprinting prep box)
      when kept (own (submitJob service vs (\() → footprintOf service prep) box))

-- The preparation of a basis for a camera and its followed surface: the camera it will settle to.
prepFor ∷ TerrainViews k → Basis → Maybe TargetMetrics → CameraState → Maybe (KnownSurface, Revision) → STM Prep
prepFor service basis metrics camera known =
  pure (Prep basis metrics (prospectiveCamera (tvCamera (svConfig service)) (fst <$> known) camera) known (pendingId <$> camPending camera) zJump [] [] 0)
  where
    zJump = maybe False (isJust . jumpZ . pendingTarget) (camPending camera)

-- The surface answer is taken: the camera it settles is footprinted. A failed read refuses with the runtime's cause; an
-- answer at another content revision than the basis's is superseded and asked again.
stepSurfacing ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Basis → Maybe TargetMetrics → Column → InFlight → IO Bool
stepSurfacing service vs serial basis metrics column flight =
  commit $
    own (flightSettled flight) >>= \case
      Nothing → pure False
      Just settlement → do
        let terrain = portTerrain (svPorts service)
        answer ← case settlement of
          Succeeded (Runtime.ASurface found) → Right found <$ retireViewRequestTx terrain (flightRequest flight)
          Succeeded other → Left ("the surface read answered " <> Text.pack (show other)) <$ retireViewRequestTx terrain (flightRequest flight)
          Failed why → Left ("the surface read failed: " <> Text.pack (show why)) <$ retireViewRequestTx terrain (flightRequest flight)
          Cancelled → pure (Left "the surface read was cancelled")
        case answer of
          Left why → False <$ refuse service vs serial basis (LimitRuntime why)
          Right found
            | Just (Runtime.surfaceRevision found) /= fmap (\(_, content, _) → content) (basisArena basis) → do
                -- superseded: a newer content revision; the basis moves with it and the view prepares again
                True <$ discardStale service vs serial
            | otherwise → do
                let known = maybe KnownSurfaceEmpty (KnownSurfaceAt . occupiedLevel) (Runtime.surfaceTop found)
                    revision = Runtime.surfaceRevision found
                (box, prep) ← own $ do
                  writeTVar (vsSurface vs) (Just (column, revision, known))
                  camera ← readTVar (vsCamera vs)
                  (,) <$> newEmptyTMVar <*> prepFor service basis metrics camera (Just (known, revision))
                kept ← writeBack service vs serial basis (Footprinting prep box)
                when kept (own (submitJob service vs (\() → footprintOf service prep) box))
                pure False

-- F for a preparation's camera, nearest its anchor first, the extra region a pending jump with Z is checked at when F
-- does not hold it, and their request batches: refused when together they exceed the profile's regions (at the first
-- excess key) or the planner's column bound, or when the terrain service holds no region a request. Made on the
-- planner and handed back fully evaluated, so the owner sorts and splits nothing.
footprintOf ∷ TerrainViews k → Prep → Either BindingLimit Footprint
footprintOf service prep =
  -- a zero geometry reads nothing: F is empty without a walk
  case maybe (Right (ReadRegions Set.empty)) (\metrics → cellReadFootprint limit camera (setupFor metrics) (cellConfig service)) (prepMetrics prep) of
    Left why → Left (LimitFailure ("the footprint could not be made: " <> Text.pack (show why)))
    Right (ReadBeyondColumns _) → Left (LimitPlan HaltColumns)
    Right (ReadBeyondRegions n) → Left (LimitRegions (n + 1) n)
    Right (ReadRegions keys) →
      let extra = [anchorRegion camera | prepZJump prep, Set.notMember (anchorRegion camera) keys]
          total = Set.size keys + length extra
          wanted = ordered (anchorRegion camera) (Set.toList keys)
       in if
            | total > limit → Left (LimitRegions total limit)
            | total == 0 → Right (Footprint [] [] [])
            | size <= 0 → Left (LimitRuntime "the terrain service holds no region a request")
            | otherwise → forced (Footprint wanted extra (map sort (batchesOf (wanted <> extra))))
  where
    limit = profileRegions (tvProfile (svConfig service))
    camera = prepCamera prep
    limits = Runtime.configLimits (Runtime.inspectConfig (portTerrain (svPorts service)))
    size = minimum [profileRequestRegions (tvProfile (svConfig service)), fromIntegral (limitHoldRegions limits), fromIntegral (limitQueryRegions limits)]
    batchesOf xs = case splitAt size xs of
      (batch, []) → [batch | not (null batch)]
      (batch, rest) → batch : batchesOf rest
    forced fp = foldr seq () (fpKeys fp) `seq` foldr seq () (fpExtra fp) `seq` foldr (\batch rest → foldr seq () batch `seq` rest) () (fpBatches fp) `seq` Right fp

-- F is made: its batches are copied one at a time; a footprint that reads nothing asks for no copy, and the camera
-- settles without inputs.
stepFootprinting ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Prep → TMVar (Either BindingLimit Footprint) → IO Bool
stepFootprinting service vs serial prep box =
  commit $
    own (tryReadTMVar box) >>= \case
      Nothing → pure False
      Just (Left limit) → False <$ refuse service vs serial (prepBasis prep) limit
      Just (Right fp) →
        let prep' = prep {prepFootprint = fpKeys fp, prepExtra = fpExtra fp}
         in case fpBatches fp of
              [] → settleWith service vs serial prep' Nothing
              batches → True <$ writeBack service vs serial (prepBasis prep) (Copying prep' batches [] Nothing)

-- The regions in admission order: the anchor's first, then the nearest to it, each once.
ordered ∷ RegionCoord → [RegionCoord] → [RegionCoord]
ordered anchor regions = map snd (sortOn fst [(distance region, region) | region ← Set.toList (Set.fromList regions)])
  where
    distance r = (abs (regionX r - regionX anchor) `max` abs (regionY r - regionY anchor), abs (toInteger (regionZ r) - toInteger (regionZ anchor)))

anchorRegion ∷ CameraState → RegionCoord
anchorRegion camera = RegionCoord (fromIntegral (axisValue (camAnchorX camera) `div` 16)) (fromIntegral (axisValue (camAnchorY camera) `div` 16)) (fromIntegral (axisValue (camClip camera) `div` 32))

-- Abandon the stage a newer basis overtook: its private builds go to disposal and its request is cancelled.
abandon ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → IO ()
abandon service vs serial = do
  flight ← atomically $ do
    current ← readTVar (vsStageSerial vs)
    if current /= serial then pure Nothing else takeStage service vs
  for_ flight (abandonFlight service)

-- | Whether a step's work is still current, read in the transaction that acts on it: the stage is the one the step
-- read (its serial); the view and the service are open and the owner takes steps; the target is usable, the view's
-- original authority holds and the arena lease is live; the full basis (intent, metrics, arena content and knowledge revisions) is the one the work was
-- prepared from; and, for work that settles a move, the camera's pending jump is the one captured. Every transaction
-- that writes a stage, changes the camera, settles a move, records a refusal or publishes asks it.
stillCurrent ∷ TerrainViews k → ViewState k → Word64 → Basis → Maybe (Maybe JumpId) → STM Bool
stillCurrent service vs serial basis jump = currentBy serial basis jump <$> liveWitness service vs

-- | The writer-maintained stamps a view's work rests on: the identities and revisions its writers advance, read as they
-- stand and computed from nothing: the stage's serial, the view's and the service's lifecycle, the owner's gate, the
-- target's standing and its facts' version, each original authority's mark, the arena's mark, the view's intent
-- revision and the camera's pending jump. Strict: equal stamps, read in two transactions, mean none of them changed
-- between them, a change made and undone included. A build's collection compares only these.
data Stamps = Stamps
  { stampSerial ∷ !Word64
  , stampStatus ∷ !ViewStatus
  , stampOpen ∷ !Bool
  , stampEnded ∷ !Bool
  , stampGone ∷ !Bool
  , stampUsable ∷ !Bool
  , _stampAuthorities ∷ ![AuthorityMark]
    -- ^ This and the next three are compared only as part of the whole.
  , _stampFacts ∷ !SurfaceVersion
  , _stampArena ∷ !(Maybe ArenaMark)
  , _stampIntent ∷ !Word64
  , stampPending ∷ !(Maybe JumpId)
  }
  deriving (Eq)

-- | The stamps as their writers' cells hold them now: reads of the service's own cells, the target's and the leases'
-- issued readers and the terrain service's mark cell. Nothing waits, and nothing is derived.
stampsOf ∷ TerrainViews k → ViewState k → STM Stamps
stampsOf service vs =
  Stamps
    <$> readTVar (vsStageSerial vs)
    <*> readTVar (vsStatus vs)
    <*> readTVar (svOpen service)
    <*> (isJust <$> readTVar (svEnded service))
    -- the graphics owner's own gate, live: work an owner step carries past its exit's start is stale
    <*> (isJust <$> ownerEnded (portOwner (svPorts service)))
    <*> surfaceUsable (vtSurface (vsTarget vs))
    <*> authorityRevisions vs
    <*> surfaceVersion (vtSurface (vsTarget vs))
    <*> vsMarkCell vs
    <*> readTVar (vsIntent vs)
    <*> (fmap pendingId . camPending <$> readTVar (vsCamera vs))

-- | A view's work, revalidated: its stamps, and what the work's preparation is checked against (the original
-- authority live, the arena held, the full basis). Captured in one read-only transaction outside any commit and forced
-- there; a collection then compares the stamps alone.
data Witness = Witness
  { witnessStamps ∷ !Stamps
  , witnessAuthority ∷ !Bool
  , witnessArena ∷ !Bool
  , witnessBasis ∷ !Basis
  }
  deriving (Eq)

-- | A build's revalidation: the witness of the view's work, and whatever else the target's revalidation reads
-- ('surfaceRevalidation'), in a read-only transaction of its own, outside any commit.
witnessOf ∷ TerrainViews k → ViewState k → STM Witness
witnessOf service vs = liveWitness service vs <* surfaceRevalidation (vtSurface (vsTarget vs))

-- | The witness of a view's work as its writers' cells give it now, through the service's own cells and the target's,
-- the leases' and the terrain service's concrete readers: no caller's transaction, and none that waits.
liveWitness ∷ TerrainViews k → ViewState k → STM Witness
liveWitness service vs =
  Witness
    <$> stampsOf service vs
    <*> authorityOf vs
    <*> (isJust <$> Runtime.inspectArenaSTM (portTerrain (svPorts service)) (vsLease vs))
    <*> currentBasis service vs

-- | Whether a witness finds the work of this stage serial and basis current (and, for work that settles a move, the
-- camera's pending jump the one captured).
currentBy ∷ Word64 → Basis → Maybe (Maybe JumpId) → Witness → Bool
currentBy serial basis jump witness =
  stampSerial stamps == serial
    && stampStatus stamps == ViewOpen
    && stampOpen stamps
    && not (stampEnded stamps)
    && not (stampGone stamps)
    && stampUsable stamps
    && witnessAuthority witness
    && witnessArena witness
    && witnessBasis witness == basis
    && maybe True (== stampPending stamps) jump
  where
    stamps = witnessStamps witness

-- | The view's original authority, as its open checked it: the caller's lease of the target and of the style's parents.
authorityOf ∷ ViewState k → STM Bool
authorityOf vs = (&&) <$> surfaceAuthority (vtSurface (vsTarget vs)) <*> leasesLive (styleAuthority (vsStyle vs))

-- Stale work discards only itself: a stage that is still the step's (its serial) goes, its private builds to disposal
-- and its settled request finished here, and the newer state is prepared.
--
-- Invariant: the stage a step discards holds no unsettled request. A step reaches 'writeBack', 'refuse' or this only
-- after the flight its stage holds has settled (and, for a copy, been taken); a step that starts a request passes it
-- to 'writeBack' in the new stage, and abandons it itself when 'writeBack' answers 'False'. Only 'abandon' (an
-- overtaken stage, outside any step's work) takes an unsettled request, and it cancels it.
discardStale ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → OwnerTx ()
discardStale service vs serial = do
  flight ← own $ do
    mine ← (== serial) <$> readTVar (vsStageSerial vs)
    if mine then takeStage service vs else pure Nothing
  for_ flight (finishSettled (portTerrain (svPorts service)))
  kick service

-- Write a step's new stage back while its work is still current ('False' otherwise: then it is stale, and discarded).
-- No stage written back holds a chunk the step made: a build is handed to the stage, or to disposal, in its own
-- transaction.
writeBack ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Basis → Stage → OwnerTx Bool
writeBack service vs serial basis stage =
  own (stillCurrent service vs serial basis Nothing) >>= \case
    True → True <$ own (writeTVar (vsStage vs) stage)
    False → False <$ discardStale service vs serial

-- Enter refusal, while the work is still current: the current drawing stays; the binding limit is reported once, on
-- entering; the private builds go to disposal, and the pending moves settle with that pressure. Stale work (another
-- basis, a newer control, an ending) discards only itself: no move settles and nothing is recorded.
refuse ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Basis → BindingLimit → OwnerTx ()
refuse service vs serial basis limit =
  own (stillCurrent service vs serial basis Nothing) >>= \case
    False → discardStale service vs serial
    True → own (enterRefusal service vs basis limit)

-- Enter refusal for work already found current: the body of 'refuse'.
enterRefusal ∷ TerrainViews k → ViewState k → Basis → BindingLimit → STM ()
enterRefusal service vs basis limit = do
  stage ← readTVar (vsStage vs)
  case stage of
    Building _ candidate → privately service vs (map partChunk (Map.elems (cdBuilt candidate)))
    _ → pure ()
  writeTVar (vsStage vs) Idle
  pressure vs limit
  let need = case limit of
        LimitSlots wanted _ → Just wanted
        _ → Nothing
  recordRefusal vs limit (RefusedAt basis need Nothing)

-- Record a refusal: a new entry (no record, or one of another basis or desired list) is reported once; the same
-- refusal again adds nothing.
recordRefusal ∷ ViewState k → BindingLimit → RefusedAt → STM ()
recordRefusal vs limit at@(RefusedAt basis _ list) = do
  before ← readTVar (vsRefused vs)
  let same = case before of
        Just (_, RefusedAt basis' _ list') → basis' == basis && list' == list
        Nothing → False
  unless same (modifyTVar' (vsRefusals vs) (+ 1))
  writeTVar (vsRefused vs) (Just (limit, at))

-- Settle every pending move with recoverable pressure, once, and cancel the camera's pending jump: the camera stays
-- where it was.
pressure ∷ ViewState k → BindingLimit → STM ()
pressure vs limit = do
  moves ← readTVar (vsMoves vs)
  forM_ (Map.elems moves) (settleOnce (MovePressure limit))
  writeTVar (vsMoves vs) Map.empty
  modifyTVar' (vsCamera vs) (\camera → maybe camera (\p → cancelJump (pendingId p) camera) (camPending camera))

-- ---------------------------------------------------------------------------
-- Copying and settling

-- One batch of F at a time. A settled copy is taken and its borrow returned in one transaction; it must hold exactly
-- the batch, at the surface answer's content revision; its input runs and intervals, counted as the planner is handed
-- them, are added to the preparation's total, which the profile's runs bound. Only a copy of the whole of F goes on.
stepCopying ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Prep → [[RegionCoord]] → [Runtime.RegionSnapshot] → Maybe ([RegionCoord], InFlight) → IO Bool
stepCopying service vs serial prep batches taken = \case
  Just (batch, flight) → mask $ \restore → do
    -- the settled borrow is taken and kept, charged to the terrain service, through the copy's validation and the run
    -- count; it is returned exactly once, in the transaction that accepts the copy, refuses it or finds it stale. The
    -- take commits masked, and from it every exit returns the borrow: only the count's own work is interruptible
    let terrain = portTerrain (svPorts service)
        hooks = portCopyHooks (svPorts service)
    outcome ← commit $ do
      (unavailable, settled) ← own ((,) <$> hookUnavailable hooks <*> flightSettled flight)
      case settled of
        Nothing → pure Nothing
        Just settlement → Just . fmap ((,) unavailable) <$> takeHeld terrain flight settlement
    case outcome of
      Nothing → pure False
      Just (Left why) → False <$ commit (refuse service vs serial (prepBasis prep) (LimitRuntime why))
      Just (Right (unavailable, borrow)) → do
        let snapshot = Runtime.regionBorrowSnapshot borrow
            release = releaseRegionBorrowTx terrain borrow
            limit = profileRuns (tvProfile (svConfig service))
        (`onException` commit release) $ do
         hookTaken hooks
         counted ← restore (do total ← timed service (\() → prepRuns prep + plannerRuns unavailable snapshot); total <$ hookCounting hooks batch total)
         commit $ do
          own (hookAccounting hooks)
          release
          if
            | Runtime.regionSnapshotRegions snapshot /= batch →
                False <$ refuse service vs serial (prepBasis prep) (LimitRuntime "a copy did not hold exactly the regions asked")
            | basisArena (prepBasis prep) /= Just (Runtime.regionSnapshotIncarnation snapshot, Runtime.regionSnapshotContentRevision snapshot, Runtime.regionSnapshotKnowledgeRevision snapshot) →
                -- the copy is of another version than the one captured: this preparation is superseded
                True <$ discardStale service vs serial
            | counted > limit → False <$ refuse service vs serial (prepBasis prep) (LimitRuns counted limit)
            | otherwise → writeBack service vs serial (prepBasis prep) (Copying prep {prepRuns = counted} batches (snapshot : taken) Nothing)
  Nothing → case batches of
    [] → commit $ do
      (box, unavailable) ← own ((,) <$> newEmptyTMVar <*> hookUnavailable (portCopyHooks (svPorts service)))
      kept ← writeBack service vs serial (prepBasis prep) (Inputting prep taken box)
      when kept (own (submitJob service vs (\() → inputsOf (tvProfile (svConfig service)) unavailable taken) box))
      pure False
    batch : rest →
      mask $ \_ →
        requestViewRegions (portTerrain (svPorts service)) (vsLease vs) batch >>= \case
          Left why → False <$ commit (refuse service vs serial (prepBasis prep) (LimitRuntime (Text.pack (show why))))
          Right request → do
            let flight = InFlight request
            hookRequested (portCopyHooks (svPorts service)) (isJust <$> flightSettled flight)
            kept ← commit (writeBack service vs serial (prepBasis prep) (Copying prep rest taken (Just (batch, flight))))
            unless kept (abandonFlight service flight)
            pure False

-- Take a settled copy's borrow, keeping it charged until the caller returns it.
takeHeld ∷ Runtime.Service → InFlight → Settlement → OwnerTx (Either Text Runtime.RegionBorrow)
takeHeld terrain flight = \case
  Succeeded (Runtime.ARegions borrow) →
    takeViewRequestTx terrain (flightRequest flight) >>= \case
      Taken → pure (Right borrow)
      TakeReleased → pure (Left "the copy was released before it was taken")
  Succeeded other → Left ("the copy answered " <> Text.pack (show other)) <$ retireViewRequestTx terrain (flightRequest flight)
  Failed why → Left ("the copy failed: " <> Text.pack (show why)) <$ retireViewRequestTx terrain (flightRequest flight)
  Cancelled → pure (Left "the copy was cancelled")

-- The copies' inputs: combined into one version (copies of different versions are never combined), as the planner's
-- facts and knowledge.
inputsOf ∷ ViewProfile → Set RegionCoord → [Runtime.RegionSnapshot] → Either BindingLimit (CopySet, TerrainFacts, Knowledge)
inputsOf profile unavailable taken = case combineCopies taken of
  Left _ → Left (LimitRuntime "the copies are of different versions")
  Right copies → case planInputs (ChangeLimits (profileRuns profile)) unavailable copies of
    Left why → Left (LimitFailure ("the copies could not be planned from: " <> Text.pack (show why)))
    Right (facts, knowledge) → facts `seq` knowledge `seq` Right (copies, facts, knowledge)

-- The inputs are made: the camera settles, at its transition, and the plan is made for it. A pending jump lands (with
-- the followed surface as the terrain service answered it; a jump with Z only once its destination part is ready in
-- the copies, else it settles with pressure and the camera stays); a following camera adopts the answered surface. The
-- settled camera is the one F was enumerated for.
stepSettling ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Prep → [Runtime.RegionSnapshot] → TMVar (Either BindingLimit (CopySet, TerrainFacts, Knowledge)) → IO Bool
stepSettling service vs serial prep _ box =
  commit $
    own (tryReadTMVar box) >>= \case
      Nothing → pure False
      Just (Left limit) → False <$ refuse service vs serial (prepBasis prep) limit
      Just (Right inputs) → settleWith service vs serial prep (Just inputs)

-- Settle the camera at its transition from a preparation's inputs ('Nothing': its footprint reads nothing), then plan
-- for it. A pending jump lands (with the answered surface; a jump with Z only once its destination part is ready in
-- the copies); a following camera adopts the answered surface; the settled camera is the one F was enumerated for. A
-- destination that is not ready is a current refusal: the move settles with pressure, the camera and the drawing stay,
-- and the view waits for a change. A footprint that reads nothing is planned empty and published, unless nothing can
-- be drawn (a zero drawable, or a view that has no source yet): then its runtime demand is withdrawn and it waits for
-- its basis to move.
settleWith ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Prep → Maybe (CopySet, TerrainFacts, Knowledge) → OwnerTx Bool
settleWith service vs serial prep inputs =
  own (stillCurrent service vs serial basis (Just (prepJump prep))) >>= \case
    False → True <$ discardStale service vs serial
    True → do
      let config = tvCamera (svConfig service)
          known = fst <$> prepSurface prep
      camera ← own (readTVar (vsCamera vs))
      let settled = case camPending camera of
            Just pending
              | isJust (jumpZ (pendingTarget pending)), Just (_, facts, _) ← inputs → completeJump config facts (pendingId pending) camera
              | otherwise → completeJumpKnown config known (pendingId pending) camera
            Nothing → maybe (Right (Step camera FollowNotApplied NoJump)) (\surface → followKnown config surface camera) known
      case settled of
        Left why → False <$ refuse service vs serial basis (LimitFailure ("the camera could not settle: " <> Text.pack (show why)))
        Right step → case stepJump step of
          JumpPending _ _ → False <$ refuse service vs serial basis (LimitFailure "the jump's destination is not ready")
          event
            | not (sameGeometry (stepCamera step) (prepCamera prep)) →
                False <$ refuse service vs serial basis (LimitFailure "the camera settled elsewhere than it was copied for")
            | otherwise → do
                let landed = stepCamera step
                own $ do
                  case event of
                    JumpApplied (JumpId number) → do
                      moves ← readTVar (vsMoves vs)
                      for_ (Map.lookup number moves) (settleOnce MoveLanded)
                      writeTVar (vsMoves vs) (Map.delete number moves)
                    _ → pure ()
                  writeTVar (vsCamera vs) landed
                  writeTVar (vsSettled vs) (Just landed)
                case (prepMetrics prep, inputs) of
                  -- a zero geometry: the move is settled; nothing is planned or published
                  (Nothing, _) → False <$ own (writeTVar (vsStage vs) Idle)
                  -- a drawable footprint that reads nothing: the planner's own empty plan (readiness-only copies draw nothing)
                  (Just metrics, _)
                    | null (prepFootprint prep) → do
                        residency ← own (currentResidency service vs)
                        case basisArena basis of
                          Nothing → False <$ discardStale service vs serial
                          Just (arena, content, knowledge) → do
                            let ArenaId arenaNumber = arena
                                Revision contentNumber = content
                                Revision knowledgeNumber = knowledge
                                generation = fromMaybe 0 residency
                                request = CellRequest (Versions arenaNumber contentNumber generation) landed (setupFor metrics) (cellConfig service)
                                identity = ((arena, content, knowledge, generation), Set.empty)
                            plan landed metrics identity (\light → forcedPlanned (emptyPlanOf service (vsStyle vs) light request knowledgeNumber))
                  (Just metrics, Just (copies, facts, knowledge)) → do
                    let terrain = portTerrain (svPorts service)
                        slots = fromIntegral (limitCameraRegions (Runtime.configLimits (Runtime.inspectConfig terrain)))
                        -- the runtime's places F leaves: the prefetch prefix's length
                        remaining = max 0 (slots - length (prepFootprint prep))
                        base = cellConfig service
                        -- the cell planner lists no ring: the prefix is walked after the plan, within its bounds
                        cellInputs = CellInputs (CellRequest (factsVersions facts) landed (setupFor metrics) base {ccChunkMargin = 0}) facts knowledge (styleSnapshot (vsStyle vs))
                    plan landed metrics (copyIdentity copies) (\light → forcedPlanned (planOf service (vsStyle vs) light cellInputs base prep remaining))
                  (Just _, Nothing) → False <$ refuse service vs serial basis (LimitFailure "a footprint that reads regions has no copies")
  where
    basis = prepBasis prep
    plan landed metrics identity work = do
      (light, planned) ← own ((,) <$> readTVar (vsLight vs) <*> newEmptyTMVar)
      kept ← writeBack service vs serial basis (Planning prep {prepMetrics = Just metrics} identity landed planned)
      when kept (own (submitJob service vs (\() → work light) planned))
      pure False

-- Whether two cameras draw the same picture: anchor, offset, reference, clip, zoom and facing.
sameGeometry ∷ CameraState → CameraState → Bool
sameGeometry a b =
  (camAnchorX a, camAnchorY a, camFrac a, camRef a, camClip a, camZoom a, camFacing a)
    == (camAnchorX b, camAnchorY b, camFrac b, camRef b, camClip b, camZoom b, camFacing b)

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

-- The planner's whole work for one preparation, pure: the plan run to its end, from F's copies, then the candidate's
-- parts. A plan-wide bound refuses: a halted plan is never published as if it were complete.
planOf ∷ TerrainViews k → ViewStyle → LightSettings → CellInputs → CellConfig → Prep → Int → Either BindingLimit Planned
planOf service style light inputs ring prep remaining = do
  started ← either (failed "the plan could not start") Right (startCells inputs)
  finished ← steps started
  plan ← either (failed "the plan could not finish") Right (cellPlanOf inputs finished)
  -- the prefetch prefix, walked around the plan's visible chunks with the configured ring, outside F, no longer than
  -- the runtime's places F leaves
  let prefetch = cellPrefetchRegions ring (factsAvailability (inputsFacts inputs)) plan (Set.fromList (prepFootprint prep)) remaining
  (adapted, parts) ← candidateOf service style plan light
  Right (Planned plan prefetch adapted parts)
  where
    failed what why = Left (LimitFailure (what <> ": " <> Text.pack (show why)))
    steps prepared = case cellPrepProgress prepared of
      Working → either (failed "a plan step failed") Right (stepCells inputs prepared) >>= steps
      Halted reason → Left (LimitPlan reason)
      Settled → Right prepared

-- The plan of a drawable footprint that reads nothing: the cell planner's own (no quad, no demand), adapted.
emptyPlanOf ∷ TerrainViews k → ViewStyle → LightSettings → CellRequest → Word64 → Either BindingLimit Planned
emptyPlanOf service style light request knowledge = do
  plan ← either (Left . LimitFailure . ("the empty plan could not be made: " <>) . Text.pack . show) Right (planEmptyFootprint request knowledge (styleSnapshot style))
  (adapted, parts) ← candidateOf service style plan light
  Right (Planned plan [] adapted parts)

-- The planner's work done before it is handed back: the plan's quads, pending spans and demand, every part's
-- instances and records.
forcedPlanned ∷ Either BindingLimit Planned → Either BindingLimit Planned
forcedPlanned = \case
  Right planned →
    let plan = plannedPlan planned
        parts = foldr (\(_, instances, records) rest → foldr seq () instances `seq` foldr seq () records `seq` rest) () (plannedParts planned)
     in length (cellPlanQuads plan) `seq` length (cellPlanPending plan) `seq` length (plannedPrefetch planned) `seq` parts `seq` Right planned
  other → other

-- The plan is made: the candidate's admission, on the owner: its parts equal to a published part are reused by
-- reference, and what is left must fit the target's free slots. Its runtime demand is F, nearest the anchor first, then
-- the prefetch, cut at the service's camera regions (completing a cut demand is the terrain service's).
stepPlanning ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Prep → CopyIdentity → CameraState → TMVar (Either BindingLimit Planned) → IO Bool
stepPlanning service vs serial prep copies camera box =
  atomically (tryReadTMVar box) >>= \case
    Nothing → pure False
    Just (Left limit) → False <$ commit (refuse service vs serial (prepBasis prep) limit)
    Just (Right planned) → do
      let plan = plannedPlan planned
          wanted = plannedParts planned
          terrain = portTerrain (svPorts service)
          cap = fromIntegral (limitCameraRegions (Runtime.configLimits (Runtime.inspectConfig terrain)))
          demand = take cap (prepFootprint prep <> plannedPrefetch planned)
      parts ← readTVarIO (vsParts vs)
      -- the reuse comparison is the owner's own planning work, timed into the frame's total
      (reused, toBuild) ← timed service $ \() →
        let byKey = Map.fromList [(key, (instances, records)) | (key, instances, records) ← wanted]
            kept = Map.mapMaybe id (Map.intersectionWith (\part (instances, records) → if partInstances part == instances && partRecords part == records then Just part else Nothing) parts byKey)
            fresh = [w | w@(key, _, _) ← wanted, Map.notMember key kept]
         in Map.size kept `seq` length fresh `seq` (kept, fresh)
      prepared ← prepare (demandsOf demand)
      commit $ do
        recoverable ← own (recoverableSlots service vs)
        if length toBuild > recoverable
          then False <$ refuse service vs serial (prepBasis prep) (LimitSlots (length toBuild) recoverable)
          else case prepMetrics prep of
            Nothing → False <$ refuse service vs serial (prepBasis prep) (LimitFailure "a plan was made without a drawable extent")
            Just metrics → writeBack service vs serial (prepBasis prep) (Building prep (Candidate plan copies (plannedAdapted planned) toBuild Seq.empty (length toBuild) Nothing Map.empty reused camera metrics demand prepared))

-- The element with the greatest key, if any, every comparison made as the list is walked (no deferred chain).
maximumOn ∷ Ord b ⇒ (a → b) → [a] → Maybe a
maximumOn key = foldl' step Nothing
  where
    step Nothing x = Just $! x
    step (Just y) x = if key x > key y then Just $! x else Just $! y

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

-- ---------------------------------------------------------------------------
-- Building and publication

stepBuilding ∷ (Ord k, Show k) ⇒ TerrainViews k → Hands → ViewState k → Word64 → Prep → Candidate → IO Bool
stepBuilding service hands vs serial prep candidate
  | not (null (cdWanted candidate)) = prepareParts
  | otherwise = builds (profileBuilds (tvProfile (svConfig service)))
  where
    basis = prepBasis prep
    tkey = vtKey (vsTarget vs)
    -- At most 'profileBuilds' parts are prepared in one step, on the owner (the renderer routes and encodes them, and
    -- nothing is reserved); every part is prepared before the first is admitted, so the whole remainder is known.
    prepareParts = do
      let (batch, rest) = splitAt (profileBuilds (tvProfile (svConfig service))) (cdWanted candidate)
      -- each part's description and encoding are evaluated here, within this step's bound
      prepared ← forM batch $ \(key, instances, records) →
        handPrepare hands instances records >>= traverse evaluate <&> fmap (\part → (key, part, instances, records))
      case sequence prepared of
        Left why → False <$ commit (refuse service vs serial basis (LimitFailure ("a chunk could not be prepared: " <> why)))
        Right parts → commit $ do
          stage ← own (readTVar (vsStage vs))
          case stage of
            Building p c →
              -- the largest so far, decided here, within this batch's bound
              let !largest = maximumOn preparedBytes (maybe id (:) (cdLargest c) [part | (_, part, _, _) ← parts])
               in writeBack service vs serial basis (Building p c {cdWanted = rest, cdPrepared = cdPrepared c Seq.>< Seq.fromList parts, cdLargest = largest})
            _ → pure False
    -- One decision for the candidate ('nextPart'), taken in one transaction that finds the work still current: a
    -- failed or missing built part refuses it; all built and ready, with publication room, it publishes; otherwise the
    -- next part's admission. A grant takes the target's slot, the renderer's reference and the uploads' room together
    -- (a refused grant takes none of them), and records the build as pending in the same transaction. The granted build
    -- then makes, fills and registers the chunk, sealing its outcome in its receipt whatever its exit; the work is
    -- revalidated in a transaction of its own, and the view collects the receipt in another, which runs no caller code
    -- ('collectBuild'). A build the view cannot collect (its revalidation raised, waited or was cancelled) is left to the
    -- sweep. Blocked, the view is armed in the deciding transaction.
    builds 0 = pure True
    builds n = do
      outcome ← mask $ \_ → do
        decided ← commit $ do
          (current, live, stage) ← own ((,,) <$> ((== serial) <$> readTVar (vsStageSerial vs)) <*> stillCurrent service vs serial basis Nothing <*> readTVar (vsStage vs))
          case stage of
            Building _ c | current && live → do
              next ← nextPart own service vs c (handReserve hands)
              own $ case next of
                NextGranted grant → do
                  occupy service tkey 1
                  for_ (Seq.lookup 0 (cdPrepared c)) $ \(part, _, _, _) →
                    modifyTVar' (svPending service) (Map.insert (receiptKey (grantReceipt grant)) (PendingBuild (grantReceipt grant) tkey (vsId vs) serial part Nothing))
                NextBlocked → writeTVar (vsArmed vs) True
                _ → pure ()
              pure (Just (c, next))
            _ → pure Nothing
        case decided of
          Nothing → pure (Just True)
          Just (_, NextGranted grant) → do
            let key = receiptKey (grantReceipt grant)
                -- a cancellation: the build is left to the sweep, and the cancellation goes on (the owner is ending)
                cancelled failure@(ExceptionWithContext _ raised) = describedText raised >>= atomically . relinquish service key . fst >> rethrowIO failure
                asynchronous (ExceptionWithContext _ raised) = isJust (fromException raised ∷ Maybe SomeAsyncException)
            -- the outcome is sealed whatever the spend's exit: a synchronous exception's cause is in it. The spend's exit
            -- is classified where it ends, against the owner's standing then: a cancellation (or an exit once the owner
            -- ended) leaves the build to the sweep and goes on; a synchronous failure while the owner lives is the
            -- spend's alone, delivered, with its context, once the build is collected
            spent ← tryWithContext @SomeException (grantSpend grant)
            standing ← maybe IssuerLive (const IssuerEnded) <$> atomically (ownerEnded (portOwner (svPorts service)))
            case either (\failure → Exit.classifyExit standing (Left failure)) (\() → Exit.Completed ()) spent ∷ Exit.Exit () () of
              Exit.Cancelled failure → cancelled failure
              Exit.Terminal (Right failure) → cancelled failure
              afterSpend →
               (<* Exit.deliverExit afterSpend) $
                -- revalidation: one read-only snapshot, its evidence strict
                -- every part of the evidence collection compares is forced here, where its exception is this step's
                -- then the seam between the two boundaries, outside both transactions (nothing in production)
                tryWithContext @SomeException (atomically ((Just <$> witnessOf service vs) `orElse` pure Nothing) >>= traverse (\seen → seen <$ evaluate (seen == seen)) >>= \seen → seen <$ when (isJust seen) (hookCollecting (portCopyHooks (svPorts service)))) >>= \case
                  Left failure
                    | asynchronous failure → cancelled failure
                    -- a revalidation that raised: the sweep collects the build, with the cause, and then the original
                    -- exception goes on, with its context, to the owner's action, which the owner outlives; a
                    -- cancellation met while describing the cause is relinquished all the same, and goes on instead
                    | ExceptionWithContext _ raised ← failure → do
                        (why, pending) ← describedText raised
                        atomically (relinquish service key ("its revalidation raised: " <> why))
                        mapM_ rethrowIO pending
                        rethrowIO failure
                  -- the revalidation would wait: the sweep collects the build, and the step yields
                  Right Nothing → Just False <$ atomically (relinquish service key "its revalidation would wait")
                  Right (Just evidence) →
                    -- the collection is owned the same way: one that raises rolls its claim back, so the still-pending
                    -- build is left to the sweep (unless it was collected), and the original exception goes on
                    collecting service key (commit (collectBuild service vs serial basis evidence key)) <&> \case
                      Nothing → Nothing
                      -- not the candidate's part: what the surviving candidate can do next decides whether the step goes on
                      Just CandidateRunnable → Just True
                      Just _ → Just False
          Just (c, NextPublish) → Just <$> publish service vs serial prep c
          Just (_, NextBlocked) → pure (Just False)
          Just (_, NextFailed why) → Just False <$ commit (refuse service vs serial basis (LimitFailure ("a chunk's upload ended without completing: " <> why)))
          Just (_, NextImpossible need have) → Just False <$ commit (refuse service vs serial basis (LimitSlots need have))
          Just (_, NextOversized why) → Just False <$ commit (refuse service vs serial basis (LimitOversized why))
          Just (_, NextEnded why) → Just False <$ commit (refuse service vs serial basis (LimitFailure ("a chunk could not be admitted: " <> why)))
      case outcome of
        Nothing → builds (n - 1 ∷ Int)
        Just more → pure more

-- A collection, owned under the step's mask: an asynchronous exception leaves the pending build to the sweep and goes on;
-- a synchronous one does the same with its rendered cause, and goes on with its context (a cancellation met while
-- rendering goes on instead). A build the collection already took is no longer pending and is left as it is.
collecting ∷ TerrainViews k → Word64 → IO a → IO a
collecting service key collect =
  tryWithContext @SomeException collect >>= \case
    Right answer → pure answer
    Left failure@(ExceptionWithContext _ raised)
      | isJust (fromException raised ∷ Maybe SomeAsyncException) → do
          atomically (relinquish service key "its collection was cancelled")
          rethrowIO failure
      | otherwise → do
          (why, pending) ← describedText raised
          atomically (relinquish service key ("its collection raised: " <> why))
          mapM_ rethrowIO pending
          rethrowIO failure

-- An exception's text, rendered and forced here, before the views record it: a description that itself raises is
-- answered with a fixed text, so a record holds plain data, and a cancellation met while rendering is answered with the
-- same text and handed back, for the caller to raise once it has recorded the build. Nothing escapes here.
describedText ∷ SomeException → IO (Text, Maybe (ExceptionWithContext SomeException))
describedText raised =
  tryWithContext @SomeException (evaluate (Text.pack (displayException raised)) >>= \text → text <$ evaluate (Text.length text)) <&> \case
    Right text → (text, Nothing)
    Left failure@(ExceptionWithContext _ inner)
      | isJust (fromException inner ∷ Maybe SomeAsyncException) → (indescribable, Just failure)
      | otherwise → (indescribable, Nothing)
  where
    indescribable = "an exception whose description raised"

-- Collect a granted build for the view that took it, once its receipt is sealed: in one transaction that runs no caller
-- code, the receipt is claimed and its pending entry goes. The part goes to the candidate when the attempt that granted
-- it is still the view's: the revalidation's evidence found the work current and the live versions are the evidence's
-- (no source changed since), and the candidate's head is this part; otherwise to private retirement. A failure records
-- what it left, and, for the current attempt, its refusal. Answers 'Nothing' when the candidate took the part, and
-- otherwise, once what the build left is accounted, the surviving candidate's next work ('applyCandidateWork'). A build
-- already swept, or not yet sealed, is left as it is.
collectBuild ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → Basis → Witness → Word64 → OwnerTx (Maybe CandidateWork)
collectBuild service vs serial basis evidence key = do
  collected ← collect
  if collected then pure Nothing else Just <$> own (applyCandidateWork service vs)
  where
    collect =
      own (Map.lookup key <$> readTVar (svPending service)) >>= \case
       Nothing → pure False
       Just entry →
         receiptClaim (pbReceipt entry) >>= \case
           Nothing → pure False
           Just outcome → own $ do
             modifyTVar' (svPending service) (Map.delete key)
             -- the revalidation's captured stamps against the writers' stamps now: identities and revisions only, nothing
             -- recomputed (the evidence itself was checked against the basis when it was captured)
             now ← stampsOf service vs
             let current = pbSerial entry == serial && currentBy serial basis Nothing evidence && witnessStamps evidence == now
             stage ← readTVar (vsStage vs)
             case (outcome, stage) of
               (Right chunk, Building p c)
                 | current
                 , (part, _, instances, records) Seq.:< rest ← Seq.viewl (cdPrepared c)
                 , part == pbPart entry →
                     True <$ writeTVar (vsStage vs) (Building p c {cdBuilt = Map.insert part (Part chunk instances records) (cdBuilt c), cdPrepared = rest})
               (Left failure@(BuildFailed why _), Building _ _)
                 | current → False <$ (failureLeft service entry failure >> enterRefusal service vs basis (LimitFailure ("a chunk could not be built: " <> why)))
               _ → False <$ retireOutcome service entry outcome

-- A build collected in place of its view, or no longer its view's: a registered chunk to private retirement, a failure
-- to the ledger that keeps what it left.
retireOutcome ∷ Ord k ⇒ TerrainViews k → PendingBuild k → Either BuildFailure ChunkRef → STM ()
retireOutcome service entry = \case
  Right chunk → modifyTVar' (svPrivate service) (<> [(pbTarget entry, pbView entry, chunk)])
  Left failure → failureLeft service entry failure

-- What a failed build left: none made returns its slot; a released buffer keeps it until the backend confirms its
-- destruction; one whose release failed keeps it as a failure with the build's cause and the release's.
failureLeft ∷ Ord k ⇒ TerrainViews k → PendingBuild k → BuildFailure → STM ()
failureLeft service entry (BuildFailed primary allocated) = case allocated of
  NotAllocated → occupy service (pbTarget entry) (-1)
  AllocatedDisposing identity reading → modifyTVar' (svDisposing service) (<> [(DisposeAllocation (pbTarget entry) (pbView entry) identity primary, reading)])
  AllocatedFailed why → modifyTVar' (svFailed service) (<> [(pbTarget entry, Nothing, "the build failed (" <> primary <> "), and " <> why)])

-- Leave a pending build to the sweep, with why.
relinquish ∷ TerrainViews k → Word64 → Text → STM ()
relinquish service key why = modifyTVar' (svPending service) (Map.adjust (\entry → entry {pbSweep = Just why}) key)

-- The sweep: every pending build left to it whose receipt is sealed is claimed in place of its view and retired, and
-- recorded with what it left and why the sweep took it. It runs no caller code. Having collected any, it asks for the
-- owner's next step (the views' work can go on). Answers whether it collected any.
sweepPending ∷ Ord k ⇒ TerrainViews k → OwnerTx Bool
sweepPending service = do
  pending ← own (Map.toList <$> readTVar (svPending service))
  swept ←
    fmap catMaybes . forM [(key, entry, why) | (key, entry) ← pending, Just why ← [pbSweep entry]] $ \(key, entry, why) →
      receiptClaim (pbReceipt entry) >>= \case
        Nothing → pure Nothing
        Just outcome → Just (pbView entry) <$ own (sweptBuild service key entry outcome why)
  -- once what the swept builds left is accounted, each surviving candidate's next work decides: a runnable one asks for
  -- the owner's step, a waiting one is armed
  own $ do
    views ← readTVar (svViews service)
    decisions ← forM (Set.toList (Set.fromList swept)) $ \view → maybe (pure CandidateEnded) (applyCandidateWork service) (Map.lookup view views)
    when (CandidateRunnable `elem` decisions) (writeTVar (svKickWanted service) True)
  pure (not (null swept))

-- Whether the sweep would collect a build now: a pending build left to it whose receipt its claim would take. Read-only,
-- for the watcher to wait on outside any commit.
sweepDue ∷ TerrainViews k → STM Bool
sweepDue service =
  readTVar (svPending service) >>= fmap or . mapM (\entry → if isJust (pbSweep entry) then receiptClaimable (pbReceipt entry) else pure False) . Map.elems

-- A build the sweep collected: its pending entry goes, what it left is retired, and the record keeps both causes.
sweptBuild ∷ Ord k ⇒ TerrainViews k → Word64 → PendingBuild k → Either BuildFailure ChunkRef → Text → STM ()
sweptBuild service key entry outcome why = do
  modifyTVar' (svPending service) (Map.delete key)
  retireOutcome service entry outcome
  let left = case outcome of
        Right chunk → "a registered chunk (" <> Text.pack (show chunk) <> "), retired privately"
        Left (BuildFailed primary _) → "the build failed: " <> primary
  modifyTVar' (svSwept service) (\records → Seq.drop (Seq.length records - 63) (records |> (pbTarget entry, pbView entry, left <> "; swept because " <> why)))

-- Whether a pending build's receipt can be claimed: the sweep or its collector can take it now.
anySealed ∷ TerrainViews k → STM Bool
anySealed service = readTVar (svPending service) >>= fmap or . mapM (receiptClaimable . pbReceipt) . Map.elems

-- Builds no step will collect: once no owner step is queued or running, every sealed pending build is left to the
-- sweep. Answers whether it left any.
orphanedBuilds ∷ TerrainViews k → STM Bool
orphanedBuilds service = do
  running ← stepUnsettled service
  if running
    then pure False
    else do
      pending ← Map.toList <$> readTVar (svPending service)
      sealed ← filterM (fmap isJust . receiptOutcome . pbReceipt . snd) [(key, entry) | (key, entry) ← pending, isNothing (pbSweep entry)]
      forM_ sealed (\(key, _) → relinquish service key "no owner step collected it")
      pure (not (null sealed))

-- The candidate's one decision, which the owner takes (reserving through @admitNext@, with the slot, in the caller's
-- transaction) and the watcher observes (through the same decision, read-only). A failed or missing built part comes
-- first, whatever the next part's admission. All built: publication once every part is ready and two earlier drawable
-- revisions do not hold it back. Otherwise impossibility: the remainder exceeds the target's free slots and those that
-- can still come free independently of this candidate (each counted once; the displayed revision, reused parts, the
-- candidate's own built prefix and permanent losses are not among them), or its largest part is larger than the whole
-- staging. Then a free slot, and the uploads' room and a reference for the next part. Beyond the built parts'
-- standings, no work here grows with the candidate: the uploads are asked about two parts.
nextPart ∷ (Monad m, Ord k) ⇒ (∀ x. STM x → m x) → TerrainViews k → ViewState k → Candidate → (PreparedChunk → m (Either Admission a)) → m (NextPart a)
nextPart within service vs candidate admitNext = do
  standings ← within (forM (Map.elems (cdBuilt candidate)) (ownerStanding owner . partChunk))
  let failures = [standing | standing ← standings, ended standing]
  if not (null failures)
    then pure (NextFailed (Text.pack (show failures)))
    else case Seq.viewl (cdPrepared candidate) of
      Seq.EmptyL → do
        room ← within ((< 2) . Set.size <$> pinsKept service vs)
        pure (if all (== Just ChunkReady) standings && room then NextPublish else NextBlocked)
      (_, first, _, _) Seq.:< _ → do
        -- two probes, whatever the candidate's size: the largest part (whether any can ever fit) and the next
        (free, recoverable, largest) ← within ((,,) <$> freeSlots service vs <*> recoverableSlots service vs <*> maybe (pure (Right ())) (ownerRoom owner) (cdLargest candidate))
        let remaining = cdFresh candidate - Map.size (cdBuilt candidate)
        if
          | remaining > recoverable → pure (NextImpossible (cdFresh candidate) (recoverable + Map.size (cdBuilt candidate)))
          | Left (AdmitOversized why) ← largest → pure (NextOversized why)
          | free <= 0 → pure NextBlocked
          | otherwise →
              admitNext first <&> \case
                Right granted → NextGranted granted
                Left (AdmitLater _) → NextBlocked
                Left (AdmitOversized why) → NextOversized why
                Left (AdmitNever why) → NextEnded why
  where
    owner = portOwner (svPorts service)
    ended = \case
      Just (ChunkFailed _) → True
      Nothing → True
      _ → False

-- Whether an armed view's candidate can go on: a part still to prepare, or the candidate's one decision ('nextPart',
-- observed) no longer blocked. Any other stage than building: yes (whatever replaced it asked for its own step).
buildActionable ∷ Ord k ⇒ TerrainViews k → ViewState k → STM Bool
buildActionable service vs = (/= CandidateWaiting) <$> nextCandidateWork service vs

-- | What a view's candidate can do next: the one decision the collection, the sweep and the watcher share. Runnable work
-- (a preparation overtaken by its basis, a part still to prepare, or the candidate's one decision, 'nextPart', not
-- blocked); a wait on the target's slots, the uploads' room or the built parts' standings, which the watcher observes
-- once the view is armed; or an ended view. Any stage but building asks for its own step: runnable.
data CandidateWork = CandidateRunnable | CandidateWaiting | CandidateEnded
  deriving (Eq, Show)

nextCandidateWork ∷ Ord k ⇒ TerrainViews k → ViewState k → STM CandidateWork
nextCandidateWork service vs = do
  status ← readTVar (vsStatus vs)
  stage ← readTVar (vsStage vs)
  case (status, stage) of
    (ViewEnded _, _) → pure CandidateEnded
    (ViewOpen, Building prep candidate) → do
      basis ← currentBasis service vs
      if
        | prepBasis prep /= basis → pure CandidateRunnable
        | not (null (cdWanted candidate)) → pure CandidateRunnable
        | otherwise →
            nextPart id service vs candidate (fmap (fmap (const ())) . ownerRoom (portOwner (svPorts service))) <&> \case
              NextBlocked → CandidateWaiting
              _ → CandidateRunnable
    (ViewOpen, _) → pure CandidateRunnable

-- Apply the candidate's next work where a collection or a sweep left it: a waiting candidate is armed, so the watcher
-- asks for the owner's step once the same decision lets it go on. Answers the decision.
applyCandidateWork ∷ Ord k ⇒ TerrainViews k → ViewState k → STM CandidateWork
applyCandidateWork service vs = do
  work ← nextCandidateWork service vs
  when (work == CandidateWaiting) (writeTVar (vsArmed vs) True)
  pure work

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
    Left why → False <$ commit (refuse service vs serial (prepBasis prep) (LimitFailure ("the view could not be made: " <> Text.pack (show why))))
    Right view → do
      let world =
            SceneWorld
              { worldTag = WorldTag (vsId vs) revision
              , worldClear = tvClear (svConfig service)
              , worldView = view
              , worldMetrics = cdMetrics candidate
              , worldChunks = Set.fromList chunks
              , worldTextures = styleParents (vsStyle vs)
              }
      scene ← prepare (worldGraphicsScene world)
      commit $ do
        (keep, live, mine) ← own $ do
          keep ← pinsKept service vs
          live ← stillCurrent service vs serial (prepBasis prep) Nothing
          claim ← claimOf (portClaims ports) (vtKey (vsTarget vs))
          pure (keep, live, fmap claimView claim == Just (vsId vs))
        if
          | not live || not mine →
              -- overtaken: the private builds go, and the newer state is prepared next
              True <$ discardStale service vs serial
          | Set.size keep >= 2 →
              -- two earlier revisions can still be drawn (the drawn one and an adopted successor): publication waits
              -- for one of them to stop being drawable, which a frame or the ledger reports with a kick
              pure False
          | otherwise → do
              -- the successor's runtime demand and its scene are accepted together, or neither, with nothing rolled
              -- back: the target's acceptance is read first (its host's own guards, which the publication meets in this
              -- same commit), then the demand is replaced only when the successor's list differs from the installed one
              -- (a refusal changes nothing), and then the scene is published
              accepts ← surfaceAccepts (vtSurface (vsTarget vs))
              installed ← own (readTVar (vsAsked vs))
              demand ←
                if
                  | not accepts → pure (Left (LimitFailure "the host refused the publication"))
                  | installed == cdDemand candidate → pure (Right Nothing)
                  | otherwise →
                      either (Left . LimitRuntime . ("the terrain service refused the view's demand: " <>) . Text.pack . show) (Right . Just)
                        <$> setViewDemandTx (portTerrain ports) (vsRuntime vs) (vsLease vs) (cdDemandPrepared candidate)
              case demand of
                Left limit → False <$ refuse service vs serial (prepBasis prep) limit
                Right receipt → do
                  for_ receipt $ \given → own $ do
                    writeTVar (vsAsked vs) (cdDemand candidate)
                    writeTVar (vsReceipt vs) (Just given)
                    modifyTVar' (vsInstalls vs) (+ 1)
                  published ← surfacePublish (vtSurface (vsTarget vs)) scene
                  -- accepted, as the commit found the target accepting; a host that refused all the same leaves the
                  -- demand recorded as installed and the view refused, for its next attempt
                  if not published
                    then False <$ refuse service vs serial (prepBasis prep) (LimitFailure "the host refused the publication")
                    else own $ do
                      _ ← markClaimPublished (portClaims ports) (vtKey (vsTarget vs)) (vsId vs)
                      old ← readTVar (vsParts vs)
                      let superseded = [partChunk part | (key, part) ← Map.toList old, Map.notMember key (cdReused candidate)]
                      unless (null superseded) $
                        modifyTVar' (svRetiring service) (|> Retiring (vtKey (vsTarget vs)) (vsId vs) superseded Unasked False)
                      writeTVar (vsParts vs) parts
                      writeTVar (vsPublished vs) (Just (Accepted revision (prepBasis prep) (cdDemand candidate) (cdDemandPrepared candidate) (Map.size parts)))
                      writeTVar (vsRefused vs) Nothing
                      writeTVar (vsStage vs) Idle
                      -- the pins: those of the revisions that can still be drawn, and this successor's
                      let (copied, regions) = cdCopies candidate
                          pin = Pinned plan copied regions (cdCamera candidate) (cdMetrics candidate)
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
askBarriers ∷ (Ord k, Show k) ⇒ TerrainViews k → OwnerTx Bool
askBarriers service = do
  (open, entries) ← own ((,) <$> readTVar (svOpen service) <*> readTVar (svRetiring service))
  (moved, entries') ← go open False Seq.empty (toList entries)
  when moved (own (writeTVar (svRetiring service) entries'))
  pure moved
  where
    go _ moved done [] = pure (moved, done)
    go open moved done (entry : rest) = case rtBarrier entry of
      _ | rtProtected entry && open → go open moved (done |> entry) rest
      Unasked →
        -- the barrier's action asks for the owner's next step, on the owner's thread, once it is met
        ownerRelease (portOwner (svPorts service)) (commit (kick service)) >>= \case
          Left _ → pure (moved, done <> Seq.fromList (entry : rest))
          Right reading → go open True (done |> entry {rtBarrier = Asked reading}) rest
      Asked reading →
        own reading >>= \case
          Just (Right ()) → go open True (done |> entry {rtBarrier = Met}) rest
          -- the entry ends here, its chunks failures with the host's answer (they keep their slots)
          Just (Left why) → own (failChunks entry why) >> go open True done rest
          Nothing → go open moved (done |> entry) rest
      Met → go open moved (done |> entry) rest
    failChunks entry why = modifyTVar' (svFailed service) (<> [(rtTarget entry, Just chunk, why) | chunk ← rtChunks entry])

-- Whether 'askBarriers' would move anything now, read-only, for a reader waiting outside any commit: an asked
-- barrier answered, or the first unasked one (in publication order, skipping a failed handback's while the service is
-- open) while the release lane has room.
barriersDue ∷ TerrainViews k → STM Bool
barriersDue service = do
  open ← readTVar (svOpen service)
  entries ← filter (\entry → not (rtProtected entry && open)) . toList <$> readTVar (svRetiring service)
  answered ← or <$> forM entries (\entry → case rtBarrier entry of
    Asked reading → isJust <$> reading
    _ → pure False)
  let unasked = not (null [() | Retiring {rtBarrier = Unasked} ← entries])
  room ← if unasked then ownerReleaseAdmits (portOwner (svPorts service)) else pure False
  pure (answered || room)

-- Release what can go now, on the owner's thread: private builds whose upload has ended, and retiring chunks whose
-- barrier is met and that no adopted revision holds; then confirm the disposals the backend has finished. Each chunk
-- leaves its holder for the owner's hand in one transaction, is released once, and leaves the hand for the
-- disposals awaiting confirmation (or the failures) in the next. Disposed, its slot is freed; failed, it keeps its
-- identity, its slot and its cause. Answers whether anything moved.
retire ∷ (Ord k, Show k) ⇒ TerrainViews k → Hands → IO Bool
retire service hands = do
  _ ← commit (askBarriers service)
  confirmed ← atomically (confirmDisposals service)
  -- at the service's end, the registry's teardown sweep: every sealed receipt no view collected
  closing ← not <$> readTVarIO (svOpen service)
  registry ← if closing then commit (handSweepReceipts hands >>= own . registrySwept service) else pure False
  -- one orphan at a time, named in hand until its release's outcome is recorded: the selection readiness asks about
  orphaned ← atomically $ do
    selected ← retirementOrphan <$> nextRetirement service
    for_ selected $ \chunk → modifyTVar' (svOrphans service) (filter (/= chunk)) >> writeTVar (svOrphanInHand service) (Just chunk)
    pure selected
  forM_ orphaned releaseOrphan
  picked ← atomically $ do
    chosen ← retirementHeld <$> nextRetirement service
    let taken (key, view, chunk) = (key, view, chunk) `elem` chosen
    modifyTVar' (svPrivate service) (filter (not . taken))
    modifyTVar' (svRetiring service) (Seq.filter (not . null . rtChunks) . fmap (\entry → entry {rtChunks = filter (\chunk → not (taken (rtTarget entry, rtView entry, chunk))) (rtChunks entry)}))
    modifyTVar' (svInHand service) (<> chosen)
    pure chosen
  forM_ picked releaseOne
  pure (confirmed || registry || isJust orphaned || not (null picked))
  where
    releaseOrphan chunk =
      mask $ \_ →
        handDispose hands chunk >>= \outcome → atomically $ do
          writeTVar (svOrphanInHand service) Nothing
          case outcome of
            Right reading → modifyTVar' (svOrphansDisposing service) (<> [(Text.pack (show chunk), reading)])
            Left why → modifyTVar' (svOrphanFailures service) (<> [(Text.pack (show chunk), "the orphaned chunk's release failed: " <> why)])
    releaseOne held@(key, _, chunk) =
      mask $ \_ → do
        outcome ← handDispose hands chunk
        atomically $ do
          inHand ← readTVar (svInHand service)
          -- a chunk abandoned meanwhile (the owner's end, an interrupted drain) is already accounted for
          when (held `elem` inHand) $ do
            writeTVar (svInHand service) (filter (/= held) inHand)
            case outcome of
              Right reading → modifyTVar' (svDisposing service) (<> [(DisposeChunk held, reading)])
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

-- What the registry's teardown sweep claimed: a build with a pending entry is swept in its view's place; a registered
-- chunk with none is an orphan, released by the owner and charged to no target (a refusal with none holds nothing).
-- Answers whether it claimed any.
registrySwept ∷ Ord k ⇒ TerrainViews k → [(Word64, Either BuildFailure ChunkRef)] → STM Bool
registrySwept service claimed = do
  forM_ claimed $ \(key, outcome) →
    Map.lookup key <$> readTVar (svPending service) >>= \case
      Just entry → sweptBuild service key entry outcome (fromMaybe "the registry's teardown sweep found it" (pbSweep entry))
      -- no build of a view: a registered chunk is an orphan, and a refusal's buffer keeps its evidence uncharged; the
      -- record keeps what each left, a refusal's cause with it
      Nothing → do
        let unheld left = modifyTVar' (svUnheld service) (\records → Seq.drop (Seq.length records - 63) (records |> (key, left)))
        case outcome of
          Right chunk → modifyTVar' (svOrphans service) (chunk :) >> unheld ("a registered chunk (" <> Text.pack (show chunk) <> "), released as an orphan")
          Left (BuildFailed primary NotAllocated) → unheld ("the build failed: " <> primary <> "; no buffer was made")
          Left (BuildFailed primary (AllocatedDisposing identity reading)) → do
            modifyTVar' (svOrphansDisposing service) (<> [(identity <> " (the build failed: " <> primary <> ")", reading)])
            unheld ("the build failed: " <> primary <> "; its buffer " <> identity <> " was released")
          Left (BuildFailed primary (AllocatedFailed why)) → do
            modifyTVar' (svOrphanFailures service) (<> [("a failed build's buffer", "the build failed (" <> primary <> "), and " <> why)])
            unheld ("the build failed: " <> primary <> "; " <> why)
  pure (not (null claimed))

-- The disposals the backend has finished: a done one frees its slot, a failed one becomes a failure with its cause and
-- keeps its slot. Answers whether any finished.
confirmDisposals ∷ Ord k ⇒ TerrainViews k → STM Bool
confirmDisposals service = do
  orphans ← readTVar (svOrphansDisposing service)
  orphanReadings ← forM orphans $ \entry@(_, reading) → (,) entry <$> reading
  forM_ orphanReadings $ \((identity, _), standing) → case standing of
    DisposalFailed why → modifyTVar' (svOrphanFailures service) (<> [(identity, "the orphaned buffer's disposal failed: " <> why)])
    _ → pure ()
  writeTVar (svOrphansDisposing service) [entry | (entry, DisposalPending) ← orphanReadings]
  disposing ← readTVar (svDisposing service)
  readings ← forM disposing $ \entry@(_, reading) → (,) entry <$> reading
  forM_ readings $ \((entry, _), standing) → case standing of
    DisposalDone → occupy service (disposalTarget entry) (-1)
    DisposalFailed why → modifyTVar' (svFailed service) (<> [disposalFailure entry ("the disposal failed: " <> why)])
    DisposalPending → pure ()
  let pending = [entry | (entry, DisposalPending) ← readings]
  when (length pending /= length disposing) (writeTVar (svDisposing service) pending)
  pure (length pending /= length disposing || any (\(_, standing) → standing /= DisposalPending) orphanReadings)

disposalTarget ∷ Disposal k → k
disposalTarget = \case
  DisposeChunk (key, _, _) → key
  DisposeAllocation key _ _ _ → key

-- A disposal that cannot complete, as a failure that keeps its slot.
disposalFailure ∷ Disposal k → Text → (k, Maybe ChunkRef, Text)
disposalFailure entry cause = case entry of
  DisposeChunk (key, _, chunk) → (key, Just chunk, cause)
  DisposeAllocation key _ identity primary → (key, Nothing, "a failed build's buffer " <> identity <> " (the build failed: " <> primary <> "): " <> cause)

-- | The retirement work the owner can take now, the one selection readiness and the owner's release share: the next
-- orphan to take in hand (none in hand, and its upload no longer running), the chunks it can release (at most a step's
-- budget), whether a disposal the backend was asked for has finished, and, at the service's end, whether a sealed receipt
-- no view collected awaits the registry's teardown sweep.
data Retirement k = Retirement
  { retirementOrphan ∷ !(Maybe ChunkRef)
  , retirementHeld ∷ ![Held k]
  , retirementConfirmable ∷ !Bool
  , retirementSweepable ∷ !Bool
  }

nextRetirement ∷ Ord k ⇒ TerrainViews k → STM (Retirement k)
nextRetirement service = do
  inHand ← readTVar (svOrphanInHand service)
  orphans ← readTVar (svOrphans service)
  ready ← filterM notUploading orphans
  held ← take 64 <$> disposable service
  disposing ← readTVar (svDisposing service)
  finished ← or <$> forM disposing (\(_, reading) → (/= DisposalPending) <$> reading)
  orphanFinished ← readTVar (svOrphansDisposing service) >>= fmap or . mapM (\(_, reading) → (/= DisposalPending) <$> reading)
  closing ← not <$> readTVar (svOpen service)
  (_, sealed) ← ownerReceiptsHeld (portOwner (svPorts service))
  pure
    Retirement
      { retirementOrphan = case (inHand, ready) of
          (Nothing, chunk : _) → Just chunk
          _ → Nothing
      , retirementHeld = held
      , retirementConfirmable = finished || orphanFinished
      , retirementSweepable = closing && sealed > 0
      }
  where
    notUploading chunk = (/= Just ChunkUploading) <$> ownerStanding (portOwner (svPorts service)) chunk

-- Whether the owner has retirement work it can do now: whether the selection it would take can advance.
retirementReady ∷ Ord k ⇒ TerrainViews k → STM Bool
retirementReady service = advances <$> nextRetirement service
  where
    advances retirement = isJust (retirementOrphan retirement) || not (null (retirementHeld retirement)) || retirementConfirmable retirement || retirementSweepable retirement

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
  , readingDemand ∷ ![RegionCoord]
    -- ^ The runtime demand it last applied: F nearest the anchor first, then its prefetch, within the service's camera
    -- regions.
  , readingReceipt ∷ !(Maybe Runtime.DemandReceipt)
    -- ^ The terrain service's receipt for that demand.
  , readingInstalls ∷ !Natural
    -- ^ How many demand lists the view installed with the terrain service.
  }
  deriving (Eq, Show)

readView ∷ TerrainView k → STM ViewReading
readView (TerrainView service vs) = do
  _ ← sweepOffscreen (portReceipts (svPorts service))
  ViewReading
    <$> readTVar (vsStatus vs)
    <*> (fmap accRevision <$> readTVar (vsPublished vs))
    <*> readReceipt (portReceipts (svPorts service)) (vsId vs)
    <*> (fmap fst <$> readTVar (vsRefused vs))
    <*> readTVar (vsRefusals vs)
    <*> (Map.size <$> readTVar (vsParts vs))
    <*> (stageName <$> readTVar (vsStage vs))
    <*> readTVar (vsAsked vs)
    <*> readTVar (vsReceipt vs)
    <*> readTVar (vsInstalls vs)
  where
    stageName = \case
      Idle → "idle"
      Surfacing {} → "reading the followed surface"
      Footprinting {} → "enumerating the footprint"
      Copying _ batches taken flight → "copying (" <> Text.pack (show (length batches)) <> " batches to ask, " <> Text.pack (show (length taken)) <> " taken, " <> (if isNothing flight then "none" else "one") <> " in flight)"
      Inputting {} → "making inputs"
      Planning {} → "planning"
      Building _ candidate → "building (" <> Text.pack (show (length (cdWanted candidate) + length (cdPrepared candidate))) <> " to build)"

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
  , servicePending ∷ !Int
    -- ^ Granted builds not yet collected, by their views or the sweep.
  , serviceSwept ∷ ![(k, Word64, Text)]
    -- ^ The latest builds the sweep collected in their views' place: target, view, what each left and why it was swept.
  , serviceUnheld ∷ ![(Word64, Text)]
    -- ^ The latest builds the registry's teardown sweep claimed that no view held: the receipt's key and what each left.
  , serviceOrphans ∷ ![(Text, Text)]
    -- ^ Buffers and registered chunks no view collected whose release or disposal failed: their identity and the cause.
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
  , serviceRetirementReady ∷ !Bool
    -- ^ Whether the owner has retirement work it can take now: the selection its release takes ('nextRetirement') can
    -- advance.
  }

readTerrainViews ∷ Ord k ⇒ TerrainViews k → STM (ServiceReading k)
readTerrainViews service =
  ServiceReading
    <$> (Map.size <$> readTVar (svViews service))
    <*> readTVar (svSlots service)
    <*> (sum . fmap (length . rtChunks) <$> readTVar (svRetiring service))
    <*> (length <$> readTVar (svPrivate service))
    <*> ((+) <$> (length <$> readTVar (svInHand service)) <*> (length <$> readTVar (svDisposing service)))
    <*> (Map.size <$> readTVar (svPending service))
    <*> (toList <$> readTVar (svSwept service))
    <*> (toList <$> readTVar (svUnheld service))
    <*> readTVar (svOrphanFailures service)
    <*> readTVar (svFailed service)
    <*> pure (svReserved service)
    <*> ((\a b → max a b) <$> readTVar (svPlanningMax service) <*> readTVar (svPlanningFrame service))
    <*> readTVar (svPlanningStepMax service)
    <*> ((\a b → max a b) <$> readTVar (svOwnerMax service) <*> readTVar (svOwnerFrame service))
    <*> readTVar (svOwnerStepMax service)
    <*> retirementReady service
