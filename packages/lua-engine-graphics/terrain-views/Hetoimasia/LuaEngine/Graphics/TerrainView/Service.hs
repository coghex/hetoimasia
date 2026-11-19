{-# LANGUAGE MultiWayIf #-}

-- | The terrain-view adapter (TRA-9): views of borrowed terrain arenas published as retained world scenes to the graphics
-- owner's targets, with their claims, interests, preparation, picking and close.
--
-- = The pieces and who owns them
--
-- +----------------------------+--------------------------+--------------------------------+---------------------------+-------------------------------------+
-- | State                      | Owner                    | Writers / thread               | Readers                   | Transfer and disposal               |
-- +============================+==========================+================================+===========================+=====================================+
-- | The service record         | 'withTerrainViews' scope | its worker (one thread); the   | any thread, in STM        | the scope's end closes every view,  |
-- | (views, requests, GPU bank,|                          | callers' transactions          |                           | drains the retirements and joins    |
-- | retirements, failures)     |                          |                                |                           | the worker                          |
-- | A view's intent (camera,   | the view                 | callers (one STM step each)    | the worker                | latest value; superseded intent is  |
-- | presentation, revision)    |                          |                                |                           | overwritten, never queued           |
-- | A target claim             | the scene session's      | attach (take), publish (mark), | the M1 publisher's commit | released by close, in the step that |
-- |                            | 'SceneClaims'            | close (release)                |                           | publishes the empty handback        |
-- | A parent's CPU interest    | the view                 | attach (retain), close (drop)  | the planner (coverage)    | 'releaseStyle' at close             |
-- | A parent's GPU interest    | the view, in the ledger  | attach, close (one STM step)   | the texture backend's     | dropped at close; retirement then   |
-- |                            |                          |                                | release ('portHeld')      | waits for adoptions and GPU use     |
-- | A regional copy            | the worker               | the worker                     | the worker                | released as soon as the facts and   |
-- |                            |                          |                                |                           | knowledge are made from it          |
-- | A pinned plan              | the view                 | the worker (pin on publish,    | pick (STM read)           | unpinned when neither published     |
-- |                            |                          | unpin)                         |                           | newest nor adopted; CPU bytes return|
-- | A retained region (chunk)  | the view while listed;   | the worker (build on the owner,| the renderer (adopted     | retired: marked released, then      |
-- |                            | then the retirement list | retire)                        | frames)                   | released on the owner once no       |
-- |                            |                          |                                |                           | adoption lists it, behind the host's|
-- |                            |                          |                                |                           | release barrier; GPU bytes return   |
-- |                            |                          |                                |                           | then, never earlier                 |
-- +----------------------------+--------------------------+--------------------------------+---------------------------+-------------------------------------+
--
-- = Threads and locks
--
-- One worker per service runs every attachment, preparation, publication, close and retirement step, round-robin over
-- the views, with a bounded request queue and one latest-intent slot per view. No step holds a lock across a wait: the
-- worker waits only in STM, always beside the service's stop and the view's close ('orElse'), and never for GPU
-- completion while holding the terrain owner, the publication transaction or a lease. Chunks are built and released only
-- by owner actions the host runs on the graphics owner's thread. Callers' operations are single transactions that
-- never wait: intent updates record the latest value, and picks read the adopted revision.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Service
  ( -- * The service
    TerrainViews
  , TerrainViewsPorts (..)
  , withTerrainViews
  , terrainViewsFailures
  , terrainViewsGpuCharged
  , terrainViewsRetiring
  , renderStagingAccount

    -- * Views
  , TerrainView
  , viewIncarnation
  , PendingAttach
  , attachView
  , awaitAttach
  , attachSettled
  , cancelAttach
  , closeView
  , viewClosed
  , viewClosing
  , viewHoldsStyle

    -- * Intent
  , updateCamera
  , updatePresentation
  , PendingJump
  , jumpView
  , jumpSettled
  , cancelJumpView

    -- * Observation
  , readView
  , viewDemand
  , viewCameraState

    -- * Picking
  , pickView
  , pickPrecondition
  , withAdoptedPlan
  , admittedCostBound
  , preparationCost

    -- * The account's figures (for the suites' exact checks)
  , planHeld
  , planDemandHeld
  ) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM
import Control.Exception (Exception, SomeAsyncException, SomeException, bracket, displayException, finally, fromException, mask, mask_, throwIO, try, uninterruptibleMask_)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Foldable (for_)
import Data.Functor ((<&>))
import Data.List (nub, sortOn)
import Data.Ord (Down (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare)
import Hetoimasia.Foundation.Resource (withResource)
import Hetoimasia.LuaEngine.Graphics.Scene.Claims (Claim (..), SceneClaims, claimOf, markClaimPublished, releaseClaim, takeClaim)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene, SceneLedger, ledgerChunkHeld, ledgerDropInterest, ledgerNewestAdopted, ledgerRetainInterest, worldGraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Scene.World (SceneWorld (..), WorldTag (..))
import Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs (CopySet, combineCopies, copyArena, copyContent, copyGeneration, copyKnowledge, copyRegions, copySnapshots, knowledgeExpansion, planInputs)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Internal.Pick (PickIdentity (..), PickRef (..))
import Hetoimasia.LuaEngine.Graphics.TerrainView.Style
import Hetoimasia.LuaEngine.Graphics.TerrainView.Types
import Hetoimasia.LuaEngine.Graphics.TerrainView.Owner (Answer (..), BuildFailure (..), OwnerRefusal (..), RegionBuild (..), Ticket, ViewOwner (..))
import Hetoimasia.LuaEngine.Texture (RenderAccount, accountCharged, accountLimit, accountRelease, accountReserve)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Chunk (ChunkRef)
import Hetoimasia.Render.TwoD.Material (MaterialData (..), MaterialRecord, MaterialRef, materialRecordLayout, recordLayoutBytes)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot (Instance, Layer (WorldLayerWith), LayerDepth (DepthEnabled), Viewport (..))
import Hetoimasia.Render.TwoD.Vulkan.Chunks (ChunkStanding (..))
import Hetoimasia.Render.TwoD.Vulkan.Layout (clipEntryBytes)
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), axisValue)
import Hetoimasia.Terrain.Palette (paletteMaterials)
import Hetoimasia.Terrain.Render2D.Camera
  ( CameraState
  , Command (Jump)
  , FollowOutcome (..)
  , JumpEvent (..)
  , JumpId (..)
  , JumpTarget (..)
  , Step (..)
  , applyCommand
  , camPending
  , camRevision
  , cancelJump
  , completeJump
  , newCamera
  , refollow
  )
import qualified Hetoimasia.Terrain.Render2D.Camera as Camera
import Hetoimasia.Terrain.Render2D.CellPick (CellHit (..), CellPickQuery (..), CellPickResult (..), pickCells)
import Hetoimasia.Terrain.Render2D.Cells
  ( CellDemand (..)
  , CellInputs (..)
  , CellKey (..)
  , CellPlan
  , CellPrep
  , CellRequest (..)
  , Progress (..)
  , cellPlanDemand
  , cellPlanIdentity
  , cellPlanOf
  , cellPlanPending
  , cellPlanQuads
  , cellPrepProgress
  , cellPrepSize
  , CellConfig (..)
  , CellLimits (..)
  , quadKey
  , startCells
  , stepCells
  )
import Hetoimasia.Terrain.Render2D.Facts (ChunkDemand (..), ChunkKey (..), Demand (..), TerrainFacts (..))
import Hetoimasia.Terrain.Render2D.Material (Adapted (..), AdaptedQuad (..), adaptCells, adaptedInstance, terrainView)
import Hetoimasia.Terrain.Render2D.Presentation (LightInput (..), LightSettings, describeSettingRefusal, lightInput, mkLightSettings)
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..))
import Hetoimasia.Terrain.Residency (ArenaId, RegionDemand (..), Revision, coverageBox, limitCameraRegions, limitHoldRegions)
import Data.Containers.ListUtils (nubOrd)
import qualified Hetoimasia.Terrain.Runtime as Runtime
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- The service

-- | What the adapter is lent: the graphics owner's narrow capability, the session's texture registry and scene ledger,
-- the scene session (its claims and its initial scene), the terrain service and the client its views are opened under,
-- the session's one CPU render/staging account, and the session's admission.
data TerrainViewsPorts k = TerrainViewsPorts
  { portOwner ∷ !ViewOwner
  , portReleased ∷ TextureHandle → STM Bool
    -- ^ Whether the texture registry reports this exact handle released (its lease let go, or a stale generation).
  , portLedger ∷ !(SceneLedger k)
  , portClaims ∷ !(SceneClaims k)
  , portInitial ∷ !(Prepared GraphicsScene)
    -- ^ The host's initial content (opaque black, naming nothing), which a close publishes as a real revision.
  , portTerrain ∷ !Runtime.Service
  , portClient ∷ !Runtime.Client
  , portAccount ∷ !RenderAccount
  , portTaking ∷ STM Bool
  }

-- | The adapter's service.
data TerrainViews k = TerrainViews
  { svConfig ∷ !TerrainViewsConfig
  , svPorts ∷ !(TerrainViewsPorts k)
  , svMaterial ∷ !MaterialRef
  , svViews ∷ !(TVar (Map Word64 (ViewState k)))
  , svNext ∷ !(TVar Word64)
  , svRequests ∷ !(TVar [Request k])
  , svOpen ∷ !(TVar Bool)
  , svGpu ∷ !(TVar Word64)
  , svRetiring ∷ !(TVar [Retiring])
  , svFailures ∷ !(TVar [Text])
  , svCursor ∷ !(TVar Word64)
  , svReleases ∷ !(TVar Word64)
    -- ^ Counts every release of a copy, a pin or a retained region's bytes: what a view waiting on pressure watches.
  , svShutDown ∷ !(TVar Bool)
    -- ^ Whether the service's end ran to completion (on the worker, or on the scope's exit when the worker was cancelled).
  , svOrphans ∷ !(TVar [Orphan])
    -- ^ Builds a closed or superseded preparation left in flight: collected by the retirements when they answer.
  , svRetiringCpu ∷ !(TVar Word64)
    -- ^ What the service holds of the account for retiring regions' CPU descriptions and builds left in flight, moved
    -- from their views' charges; returned as each release is answered, and at the service's end.
  , svKeptCpu ∷ !(TVar Word64)
    -- ^ Of 'svRetiringCpu', what failed releases keep: their descriptions stay in the renderer's registry, so their CPU
    -- stays charged after the service's end, reported as evidence.
  , svAbandonedCopies ∷ !(TVar [Runtime.Pending Runtime.RegionBorrow])
    -- ^ Copy requests an abandoned stage left in flight, handed here in the transaction that ended the stage: the worker
    -- (or the service's end) takes each settled one and releases it, or cancels it.
  }

data Request k
  = RequestAttach !(AttachRequest k) !AcquiredStyle !(TVar (Maybe (Settled (TerrainView k))))

-- | A chunk on its way out: its reference, its GPU bytes (charged until its release is answered), and where it stands.
data Retiring = Retiring
  { rtChunk ∷ !ChunkRef
  , rtBytes ∷ !Word64
  , rtCpu ∷ !Word64
    -- ^ Its CPU description's bytes (the region's instances and records, and the renderer registry's copy), held in the
    -- service's charge of the account until its release is answered.
  , rtState ∷ !RetireState
  }

-- | Where a retiring chunk stands. A release that failed leaves the list as terminal evidence, its bytes still charged.
data RetireState
  = -- | Published: the host's release barrier has not been asked yet (asked when the release lane has room).
    RetireUnasked
  | -- | Asked: the reading answers once it is met or will never be.
    RetireWaiting !(STM (Maybe Bool))
  | -- | Met (or never published): released on the owner once no adoption lists it, its upload has ended and the owner
    -- has room.
    RetireMet
  | -- | Its release is in flight: the ticket and the chunk's place in its answer.
    RetireReleasing !(Ticket [Either Text ()]) !Int

-- | A view, as callers hold it.
data TerrainView k = TerrainView !(TerrainViews k) !(ViewState k)

instance Eq (TerrainView k) where
  TerrainView _ a == TerrainView _ b = vsId a == vsId b

instance Show (TerrainView k) where
  show (TerrainView _ state) = "TerrainView " <> show (vsId state)

-- | The view's incarnation: never reused within a service.
viewIncarnation ∷ (Ord k, Show k) ⇒ TerrainView k → Word64
viewIncarnation (TerrainView _ state) = vsId state

data ViewState k = ViewState
  { vsId ∷ !Word64
  , vsTarget ∷ !(ViewTarget k)
  , vsStyleIds ∷ !(Set.Set Word64)
    -- ^ The style's two texture identities: the view's GPU interests and what its worlds name.
  , vsArena ∷ !Runtime.ArenaLease
  , vsRuntimeView ∷ !Runtime.View
  , vsStyle ∷ !(TVar (Maybe AcquiredStyle))
    -- ^ The style the view holds, emptied as its close releases it: a closed handle a caller keeps reaches neither
    -- coverage plane.
  , vsCamera ∷ !(TVar CameraState)
  , vsLight ∷ !(TVar LightSettings)
  , vsIntent ∷ !(TVar Word64)
    -- ^ Bumped by every accepted intent update.
  , vsPrepared ∷ !(TVar (Word64, Maybe (Revision, Revision, Word64), Maybe TargetMetrics))
    -- ^ What the last preparation was made for: the intent, the arena's content and knowledge revisions and residency
    -- generation, and the target's metrics. A change in any of them makes the view dirty.
    -- ^ The intent revision, arena revisions and metrics the last completed preparation was made for.
  , vsFacts ∷ !(TVar (Maybe TerrainFacts))
  , vsPins ∷ !(TVar (Map Word64 Pinned))
  , vsRegions ∷ !(TVar (Map (Integer, Integer) Region))
  , vsPublished ∷ !(TVar (Maybe Word64))
  , vsNextRevision ∷ !(TVar Word64)
  , vsPending ∷ !(TVar Int)
  , vsPhase ∷ !(TVar ViewPhase)
  , vsClosing ∷ !(TVar Bool)
  , vsClosed ∷ !(TVar Bool)
  , vsJumps ∷ !(TVar (Map Word64 (TVar (Maybe (Settled JumpOutcome)))))
  , vsRetry ∷ !(TVar (Maybe Mark))
    -- ^ A preparation left work it can complete once something is released or adopted (copies refused busy, a pin
    -- or a bank full): the service's release count and the target's newest adopted revision when it stopped. It runs
    -- again when either has moved.
  , vsExtraDemand ∷ !(TVar [RegionCoord])
    -- ^ Regions a pending jump or an unavailable followed surface needs beyond the viewport.
  , vsDemand ∷ !(TVar (Maybe ([RegionCoord], [RegionCoord])))
    -- ^ The latest camera demand, visible then prefetch: kept, so that a busy refusal loses nothing.
  , vsAccountHeld ∷ !(TVar Word64)
    -- ^ What the view holds in the session's account: whole granules covering its pinned revisions and the candidate
    -- being prepared, never less than they need.
  , vsDemandBusy ∷ !(TVar (Maybe Mark))
    -- ^ The latest demand was refused busy: the retry mark when it was. It is sent again when the mark moves.
  , vsStage ∷ !(TVar Stage)
    -- ^ Where the view's preparation stands, and what that stage owns.
  , vsStageCharge ∷ !(TVar Word64)
    -- ^ What the stage holds of the account: the copies taken so far, then the candidate's CPU bytes.
  , vsRestarts ∷ !(TVar Int)
  , vsAdmitted ∷ !(TVar (Set.Set RegionCoord))
    -- ^ The regions the last published plan admitted that its own visible demand named: when it left visible demand
    -- unadmitted, the next preparation starts from them, so a partial plan goes on from where it stopped.
  , vsVisibleAdmitted ∷ !(TVar (Set.Set RegionCoord))
    -- ^ The candidate's admitted regions its own visible demand named: what 'vsAdmitted' becomes when it publishes.
  , vsUnadmitted ∷ !(TVar Int)
    -- ^ Regions of the visible demand the last published plan did not admit.
  , vsContinue ∷ !(TVar Bool)
    -- ^ The last published plan left visible demand unadmitted and admitted more than the plan before it: the view
    -- prepares again, to go on.
  , vsBlocked ∷ !(TVar (Maybe Blocked))
    -- ^ The last preparation could not start, and only this can change that: the view sleeps until it does, however
    -- its intent or its peers move.
  , vsSteps ∷ !(TVar Int)
    -- ^ Steps the worker has taken for the view.
  , vsAdmittedCount ∷ !(TVar Int)
    -- ^ How many regions the last published plan admitted.
  , vsWindow ∷ !(TVar (Maybe WindowRefusal))
    -- ^ Why the latest candidate's records could not fit the renderer's storage window, until one fits.
  , vsAuthoritySeen ∷ !(TVar Word64)
    -- ^ The terrain service's authority epoch when the view's lease was last found valid: the worker checks the lease
    -- again only when the epoch moves.
  , vsReaders ∷ !(TVar (Map Word64 Int))
    -- ^ The readers of each pinned revision's plan ('withAdoptedPlan'): a pin with a reader is kept and stays charged,
    -- and it counts against the pin limit like any other.
  , vsPublishedFor ∷ !(TVar (Maybe (Word64, Maybe (Revision, Revision, Word64), TargetMetrics)))
    -- ^ What the newest published plan was made for: its intent, arena identity and metrics. Unlike 'vsPrepared', a
    -- preparation that was refused never writes it.
  , vsFactsCharge ∷ !(TVar Word64)
    -- ^ What the facts kept for the camera ('vsFacts') hold of the account: charged with the inputs they were made
    -- from, kept while they are kept, replaced by the next facts' charge and returned at close.
  }

-- What a preparation that could not start waits for: an adoption other than the one it saw (a pin is then freed), or
-- the target's metrics and the arena both available.
data Blocked = BlockedOnAdoption !(Maybe Natural) !Int | BlockedOnMetrics

-- | A published plan kept for picking, with its identity and its CPU charge.
data Pinned = Pinned
  { pinPlan ∷ !CellPlan
  , pinMetrics ∷ !TargetMetrics
  , pinArena ∷ !ArenaId
  , pinContent ∷ !Revision
  , pinKnowledge ∷ !Revision
  , pinResidency ∷ !Word64
    -- ^ The plan's residency identity: the copies' one generation, or a digest of theirs ('generationIdentity').
  , pinBytes ∷ !Word64
  }

-- | One retained render region: its chunk, what it was built from (for reuse), and its GPU bytes.
data Region = Region
  { rgChunk ∷ !ChunkRef
  , rgInstances ∷ ![Instance]
  , rgRecords ∷ ![MaterialRecord]
  , rgBytes ∷ !Word64
  }

-- | The session's CPU render/staging account as the terrain service's outside staging account
-- ('Runtime.configStagingAccount'): a terrain-enabled composition gives the service this, so the terrain service's
-- staging, the coverage planes and the views' payloads all draw on the one allowance.
renderStagingAccount ∷ RenderAccount → Runtime.StagingAccount
renderStagingAccount account =
  Runtime.StagingAccount
    { Runtime.stagingAccountLimit = accountLimit account
    , Runtime.stagingAccountReserve = accountReserve account
    , Runtime.stagingAccountRelease = accountRelease account
    , Runtime.stagingAccountCharged = accountCharged account
    }

-- | Failures the service retained as terminal evidence: provider, host or ownership defects, and retirements it could
-- not prove.
terrainViewsFailures ∷ (Ord k, Show k) ⇒ TerrainViews k → STM [Text]
terrainViewsFailures = readTVar . svFailures

-- | Where each retiring chunk stands: "unasked", "waiting" (on the host's barrier), "met" (released once no adoption
-- lists it, its upload has ended and the owner has room) or "releasing". Read-only.
terrainViewsRetiring ∷ TerrainViews k → STM [(ChunkRef, Text)]
terrainViewsRetiring service = map (\r → (rtChunk r, name (rtState r))) <$> readTVar (svRetiring service)
  where
    name = \case
      RetireUnasked → "unasked"
      RetireWaiting _ → "waiting"
      RetireMet → "met"
      RetireReleasing _ _ → "releasing"

-- | The GPU bytes the service holds charged: every retained region listed, being built, uploading or retiring, until
-- its release is proved. Read-only.
terrainViewsGpuCharged ∷ TerrainViews k → STM Word64
terrainViewsGpuCharged = readTVar . svGpu

-- | Run the adapter for the body. On every exit every view is closed (its claim handed back, its interests dropped and
-- its regions retired), the retirements are drained to the owner's evidence, and the worker is joined.
withTerrainViews ∷ (Ord k, Show k) ⇒ TerrainViewsConfig → TerrainViewsPorts k → (TerrainViews k → IO a) → IO a
withTerrainViews config ports body = do
  service ←
    TerrainViews config ports (ownerMaterial (portOwner ports))
      <$> newTVarIO Map.empty
      <*> newTVarIO 1
      <*> newTVarIO []
      <*> newTVarIO True
      <*> newTVarIO 0
      <*> newTVarIO []
      <*> newTVarIO []
      <*> newTVarIO 0
      <*> newTVarIO 0
      <*> newTVarIO False
      <*> newTVarIO []
      <*> newTVarIO 0
      <*> newTVarIO 0
      <*> newTVarIO []
  done ← newEmptyMVar
  -- The worker is the scope's resource: started under the scope's mask, it announces its end on every exit (its own end
  -- running first, however that goes). The release stops it, joins it and runs the service's end if it did not, all
  -- uninterruptibly ('withResource'), so the scope never exits before the worker is joined and the views are drained, and
  -- a body's failure and the release's are both kept.
  withResource
    ( void
        ( forkIOWithUnmask
            ( \unmask →
                (unmask (worker service) >>= \case
                  Left failure → recordFailure service ("the worker failed: " <> Text.pack (displayException failure))
                  Right () → pure ())
                  `finally` (workerEnded service `finally` putMVar done ())
            )
        )
    )
    ( \() → do
        atomically (writeTVar (svOpen service) False)
        tvStopping config
        readMVar done
        -- A worker that was cancelled did not run the service's end: run it here, so every view is still closed.
        ended ← readTVarIO (svShutDown service)
        unless ended (shutdown service)
    )
    (\() → body service)

-- The worker is gone, by its end or a cancellation: no attachment is taken any more, every one still queued settles
-- stopped, releasing the parents it holds, and, if the worker did not run the service's end, it runs here: every live
-- view closes now, so a close asked of one (by the body, or its own finalizer) never waits on the worker that is gone.
workerEnded ∷ (Ord k, Show k) ⇒ TerrainViews k → IO ()
workerEnded service = do
  queued ← atomically $ do
    writeTVar (svOpen service) False
    readTVar (svRequests service) <* writeTVar (svRequests service) []
  settleQueued queued
  ended ← readTVarIO (svShutDown service)
  unless ended (shutdown service)

settleQueued ∷ [Request k] → IO ()
settleQueued queued =
  forM_ queued $ \(RequestAttach _ style box) → do
    releaseStyle style
    atomically (readTVar box >>= \case Nothing → writeTVar box (Just (SettledRefused AttachStopped)); Just _ → pure ())

-- | Run an action, answering a synchronous failure as a value and rethrowing an asynchronous exception (a cancellation
-- is never recorded as a failure, and never lets the worker loop on).
trySync ∷ IO a → IO (Either SomeException a)
trySync action =
  try action >>= \case
    Left failure | Just (_ ∷ SomeAsyncException) ← fromException failure → throwIO failure
    result → pure result

recordFailure ∷ TerrainViews k → Text → IO ()
recordFailure service why = atomically (recordFailureSTM service why)

recordFailureSTM ∷ TerrainViews k → Text → STM ()
recordFailureSTM service why = modifyTVar' (svFailures service) (take 64 . (why :))

-- ---------------------------------------------------------------------------
-- Attachment

-- | An attachment in progress.
newtype PendingAttach k = PendingAttach (TVar (Maybe (Settled (TerrainView k))))

-- | Ask for a view. It must be called from inside the owning instance's own call (a binding), because the style's
-- parents are retained there, through the instance's leases, before this returns: a parent the instance does not hold
-- (released, ended, another instance's, of the wrong kind or profile) and an incomplete or unrepresentable mapping are
-- refused at once ('AttachStyle'), with nothing retained. The rest never waits: a full request queue or a stopped
-- service answers at once, and otherwise the attachment settles exactly once ('attachSettled'), on the adapter's worker,
-- which validates the target and the arena, takes the claim and the GPU interests in one transaction, and on any
-- refusal or cancellation releases the parents it was handed.
attachView ∷ (Ord k, Show k) ⇒ TerrainViews k → AttachRequest k → IO (Either AttachRefusal (PendingAttach k))
attachView service request = mask_ $
  acquireStyle (attachStyle request) >>= \case
    Left why → pure (Left (AttachStyle why))
    Right style → do
      box ← newTVarIO Nothing
      queued ← atomically $ do
        open ← readTVar (svOpen service)
        taking ← portTaking (svPorts service)
        waiting ← readTVar (svRequests service)
        if not (open && taking)
          then pure (Left AttachStopped)
          else
            if length waiting >= tvRequestQueue (svConfig service)
              then pure (Left (AttachBusy "the request queue is full"))
              else Right (PendingAttach box) <$ writeTVar (svRequests service) (waiting <> [RequestAttach request style box])
      case queued of
        Left refusal → releaseStyle style >> pure (Left refusal)
        Right pending → pure (Right pending)

-- | The settlement, once there is one.
attachSettled ∷ (Ord k, Show k) ⇒ PendingAttach k → STM (Maybe (Settled (TerrainView k)))
attachSettled (PendingAttach box) = readTVar box

-- | Wait for the settlement.
awaitAttach ∷ (Ord k, Show k) ⇒ PendingAttach k → IO (Settled (TerrainView k))
awaitAttach (PendingAttach box) = atomically (readTVar box >>= maybe retry pure)

-- | Cancel an attachment that has not settled: it settles cancelled, and what it retained is released. One that settled
-- already is unchanged ('False').
cancelAttach ∷ (Ord k, Show k) ⇒ TerrainViews k → PendingAttach k → IO Bool
cancelAttach service (PendingAttach box) = mask_ $ do
  -- the request leaves the queue and its parents are released with no cancellation between: masked through the release
  outcome ← atomically $ do
    settled ← readTVar box
    case settled of
      Just _ → pure Nothing
      Nothing → do
        waiting ← readTVar (svRequests service)
        let (mine, rest) = partitionBy (\(RequestAttach _ _ other) → other == box) waiting
        writeTVar (svRequests service) rest
        writeTVar box (Just SettledCancelled)
        -- a request the worker has taken is released by the worker, which finds it cancelled at its commit
        pure (Just [style | RequestAttach _ style _ ← mine])
  case outcome of
    Nothing → pure False
    Just styles → mapM_ releaseStyle styles >> pure True
  where
    partitionBy predicate xs = (filter predicate xs, filter (not . predicate) xs)

-- The worker's attachment, run masked from the moment the worker took the request off the queue: every check before the
-- claim (interruptible), the runtime view opened, its lease's client and the arena's palette checked, then one
-- transaction that claims and takes the interests. Until that commit the attachment owns the parents and the runtime
-- view, and every exit before it, a refusal, a failure or a cancellation, closes the runtime view and releases the
-- parents; after it the view owns both.
runAttach ∷ (Ord k, Show k) ⇒ (∀ a. IO a → IO a) → TerrainViews k → AttachRequest k → AcquiredStyle → TVar (Maybe (Settled (TerrainView k))) → IO ()
runAttach restore service request style box = do
  checked ← try (restore (attachChecks service request))
  case checked of
    Left failure → abandon failure
    Right (Left refusal) → refuse refusal
    Right (Right (camera, light)) →
      Runtime.openView (portTerrain (svPorts service)) (portClient (svPorts service)) >>= \case
        Left why → refuse (AttachBusy (Text.pack (show why)))
        Right runtimeView → do
          outcome ← try (restore (commitAttach service request box style runtimeView camera light))
          committed ← atomically (readTVar box) <&> \case
            Just (SettledOk _) → True
            _ → False
          -- the runtime view is the attachment's until the commit transfers it with the view
          unless committed (Runtime.closeView (portTerrain (svPorts service)) runtimeView)
          case outcome of
            Left failure
              | committed → passOn failure
              | otherwise → abandon failure
            Right (Left refusal) → refuse refusal
            Right (Right ()) → pure ()
  where
    settle value = atomically (readTVar box >>= \case Nothing → writeTVar box (Just value); Just _ → pure ())
    refuse refusal = releaseStyle style >> settle (SettledRefused refusal)
    -- a synchronous failure is evidence; a cancellation is passed on, after the parents are released
    abandon (failure ∷ SomeException) = do
      releaseStyle style
      settle (SettledRefused AttachStopped)
      passOn failure
    passOn (failure ∷ SomeException) = case fromException failure of
      Just (_ ∷ SomeAsyncException) → throwIO failure
      Nothing → recordFailure service ("an attachment failed: " <> Text.pack (displayException failure))

-- The checks that need nothing held: the view count, depth, the light settings, the camera and the arena's authority.
attachChecks ∷ (Ord k, Show k) ⇒ TerrainViews k → AttachRequest k → IO (Either AttachRefusal (CameraState, LightSettings))
attachChecks service request = do
  let ports = svPorts service
      config = svConfig service
      target = attachTarget request
  count ← Map.size <$> readTVarIO (svViews service)
  if
    | count >= tvMaxViews config → pure (Left AttachTooManyViews)
    | not (vtDepth target) || not (ownerDepthQualified (portOwner ports)) → pure (Left AttachNoDepth)
    | otherwise → case mkLightSettings (attachLight request) of
        Left problems → pure (Left (AttachSettings (Text.intercalate "; " (map (Text.pack . describeSettingRefusal) problems))))
        Right light → do
          let (x, y, clip) = attachAnchor request
          case newCamera (tvCameraConfig config) x y clip of
            Left why → pure (Left (AttachCamera (Text.pack (show why))))
            Right camera → do
              status ← atomically (Runtime.arenaStatusSTM (portTerrain ports) (attachArena request))
              pure $ case status of
                Left why → Left (AttachArena (Text.pack (show why)))
                Right _ → Right (camera, light)

-- The attachment's commit. The lease must be one the runtime view can use: a live lease of another client of the same
-- service passes the arena's checks, but every demand of the view would be refused, so it is refused here, before any
-- claim (a lease's client never changes, so this holds at the commit too). Then the authority, the target, the parents'
-- registrations, the arena's palette against the style's mapping and the claim are read, and the claim and both GPU
-- interests are taken, in one transaction. A cancellation that won before it, or any failed check, takes nothing.
commitAttach ∷ (Ord k, Show k) ⇒ TerrainViews k → AttachRequest k → TVar (Maybe (Settled (TerrainView k))) → AcquiredStyle → Runtime.View → CameraState → LightSettings → IO (Either AttachRefusal ())
commitAttach service request box style runtimeView camera light = do
  let ports = svPorts service
      target = attachTarget request
  compatible ← Runtime.setViewDemand (portTerrain ports) runtimeView (attachArena request) []
  case compatible of
    Left Runtime.RefusedAuthority → pure (Left (AttachArena "the arena lease is not the views' client's: the view's demand would be refused"))
    Left (Runtime.RefusedBusy why) → pure (Left (AttachBusy (Text.pack (show why))))
    Left why → pure (Left (AttachArena (Text.pack (show why))))
    Right _ → do
      state ← newViewState service request style runtimeView camera light
      tvBeforeAttachCommit (svConfig service)
      outcome ← atomically $ do
        cancelled ← isJust <$> readTVar box
        -- the arena's authority again, with the claim: a lease released or an arena closed since the early check refuses
        arena ← Runtime.arenaStatusSTM (portTerrain ports) (attachArena request)
        palette ← fmap (paletteMaterials . Runtime.viewPalette) <$> Runtime.inspectArenaSTM (portTerrain ports) (attachArena request)
        open ← readTVar (svOpen service)
        taking ← portTaking ports
        usable ← vtUsable target
        claim ← claimOf (portClaims ports) (vtKey target)
        released ← or <$> traverse (portReleased ports) [styleColourHandle style, styleNormalHandle style]
        count ← Map.size <$> readTVar (svViews service)
        let missing = [material | material ← fromMaybe [] palette, material `Set.notMember` styleMappedMaterials style]
        if
          | cancelled → pure (Left Nothing)
          | not (open && taking) → pure (Left (Just AttachStopped))
          | count >= tvMaxViews (svConfig service) → pure (Left (Just AttachTooManyViews))
          | Left why ← arena → pure (Left (Just (AttachArena (Text.pack (show why)))))
          | not (null missing) → pure (Left (Just (AttachStyle (StyleMissingMaterials missing))))
          | not usable → pure (Left (Just AttachTargetUnusable))
          | isJust claim → pure (Left (Just AttachTargetClaimed))
          | released → pure (Left (Just AttachParentReleased))
          | otherwise → do
              _ ← takeClaim (portClaims ports) (vtKey target) (vsId state)
              forM_ (Set.toList (styleIdentities style)) (ledgerRetainInterest (portLedger ports))
              modifyTVar' (svViews service) (Map.insert (vsId state) state)
              writeTVar box (Just (SettledOk (TerrainView service state)))
              pure (Right ())
      -- a cancellation that won is answered as a refusal here, so the caller releases the parents; the box stays as
      -- the cancellation settled it
      pure (either (Left . fromMaybe AttachStopped) Right outcome)

newViewState ∷ (Ord k, Show k) ⇒ TerrainViews k → AttachRequest k → AcquiredStyle → Runtime.View → CameraState → LightSettings → IO (ViewState k)
newViewState service request style runtimeView camera light = do
  identity ← atomically $ do
    next ← readTVar (svNext service)
    writeTVar (svNext service) (next + 1)
    pure next
  ViewState identity (attachTarget request) (styleIdentities style) (attachArena request) runtimeView
    <$> newTVarIO (Just style)
    <*> newTVarIO camera
    <*> newTVarIO light
    <*> newTVarIO 1
    <*> newTVarIO (0, Nothing, Nothing)
    <*> newTVarIO Nothing
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Nothing
    <*> newTVarIO 1
    <*> newTVarIO 0
    <*> newTVarIO PhaseStarting
    <*> newTVarIO False
    <*> newTVarIO False
    <*> newTVarIO Map.empty
    <*> newTVarIO Nothing
    <*> newTVarIO []
    <*> newTVarIO Nothing
    <*> newTVarIO 0
    <*> newTVarIO Nothing
    <*> newTVarIO StageIdle
    <*> newTVarIO 0
    <*> newTVarIO 0
    <*> newTVarIO Set.empty
    <*> newTVarIO Set.empty
    <*> newTVarIO 0
    <*> newTVarIO False
    <*> newTVarIO Nothing
    <*> newTVarIO 0
    <*> newTVarIO 0
    <*> newTVarIO Nothing
    <*> newTVarIO 0
    <*> newTVarIO Map.empty
    <*> newTVarIO Nothing
    <*> newTVarIO 0

-- ---------------------------------------------------------------------------
-- Intent

-- | Apply camera commands to the view's intent, all or none, without waiting: the result is recorded intent, not an
-- adopted frame. A jump is not a camera command here ('jumpView').
updateCamera ∷ (Ord k, Show k) ⇒ TerrainView k → CameraIntent → STM (Either IntentRefusal ())
updateCamera (TerrainView service state) (CameraIntent commands) = do
  closing ← readTVar (vsClosing state)
  if closing
    then pure (Left IntentClosed)
    else do
      camera ← readTVar (vsCamera state)
      facts ← readTVar (vsFacts state)
      -- before the first facts, every command that reads none (a zoom, a facing, a turn, a slice) is recorded as
      -- intent; a pan, which follows the surface, waits for them
      case foldl' (step facts) (Right (Just camera)) commands of
        Right Nothing → pure (Left IntentBusy)
        Left why → pure (Left (IntentInvalid why))
        Right (Just moved) → do
          writeTVar (vsCamera state) moved
          modifyTVar' (vsIntent state) (+ 1)
          pure (Right ())
  where
    config = tvCameraConfig (svConfig service)
    step _ (Left why) _ = Left why
    step _ (Right Nothing) _ = Right Nothing
    step facts (Right (Just camera)) command = case command of
      Jump _ → Left "a jump is asked for with jumpView"
      _ → case maybe (Camera.applyCommandWithoutFacts config command camera) (\f → Just (applyCommand config f command camera)) facts of
        Nothing → Right Nothing
        Just (Left why) → Left (Text.pack (show why))
        Just (Right result) → Right (Just (stepCamera result))

-- | Replace the view's presentation settings: omitted values keep theirs, and an invalid update changes nothing.
updatePresentation ∷ (Ord k, Show k) ⇒ TerrainView k → PresentationUpdate → STM (Either IntentRefusal ())
updatePresentation (TerrainView _ state) update = do
  closing ← readTVar (vsClosing state)
  if closing
    then pure (Left IntentClosed)
    else do
      current ← lightInput <$> readTVar (vsLight state)
      let next =
            current
              { inputAzimuth = fromMaybe (inputAzimuth current) (updateSunAzimuth update)
              , inputElevation = fromMaybe (inputElevation current) (updateSunElevation update)
              , inputAmbient = fromMaybe (inputAmbient current) (updateAmbient update)
              , inputSunStrength = fromMaybe (inputSunStrength current) (updateSunStrength update)
              , inputDepthRange = maybe (inputDepthRange current) toInteger (updateDepthRange update)
              , inputDarkening = fromMaybe (inputDarkening current) (updateDarkening update)
              , inputHaze = fromMaybe (inputHaze current) (updateHaze update)
              , inputHazeColour = fromMaybe (inputHazeColour current) (updateHazeColour update)
              }
      case mkLightSettings next of
        Left problems → pure (Left (IntentInvalid (Text.intercalate "; " (map (Text.pack . describeSettingRefusal) problems))))
        Right settings → do
          writeTVar (vsLight state) settings
          modifyTVar' (vsIntent state) (+ 1)
          pure (Right ())

-- | A jump in progress.
data PendingJump = PendingJump !Word64 !(TVar (Maybe (Settled JumpOutcome)))

-- | Ask the camera to jump. The camera moves only when the destination's facts allow; until then the last coherent
-- view stays. A newer jump supersedes this one, which then settles 'JumpSuperseded' without moving the camera.
jumpView ∷ (Ord k, Show k) ⇒ TerrainView k → JumpRequest → STM (Either IntentRefusal PendingJump)
jumpView (TerrainView service state) request = do
  closing ← readTVar (vsClosing state)
  if closing
    then pure (Left IntentClosed)
    else do
      camera ← readTVar (vsCamera state)
      facts ← readTVar (vsFacts state)
      let (jx, jy) = jumpColumn request
      case facts of
        Nothing → pure (Left IntentBusy)
        Just f → case applyCommand (tvCameraConfig (svConfig service)) f (Jump (JumpTarget jx jy (jumpDepth request))) camera of
          Left why → pure (Left (IntentInvalid (Text.pack (show why))))
          Right result → do
            box ← newTVar Nothing
            let JumpId number = case stepJump result of
                  JumpApplied jid → jid
                  JumpPending jid _ → jid
                  JumpStale jid → jid
                  NoJump → JumpId 0
            -- every earlier jump not yet settled is superseded
            earlier ← readTVar (vsJumps state)
            forM_ (Map.elems earlier) $ \other → readTVar other >>= \case Nothing → writeTVar other (Just (SettledOk JumpSuperseded)); Just _ → pure ()
            writeTVar (vsJumps state) Map.empty
            case stepJump result of
              JumpApplied _ → writeTVar box (Just (SettledOk JumpLanded))
              _ → modifyTVar' (vsJumps state) (Map.insert number box)
            writeTVar (vsCamera state) (stepCamera result)
            modifyTVar' (vsIntent state) (+ 1)
            pure (Right (PendingJump number box))

jumpSettled ∷ PendingJump → STM (Maybe (Settled JumpOutcome))
jumpSettled (PendingJump _ box) = readTVar box

-- | Cancel a pending jump: it settles cancelled and the camera stays. A jump of another view, or one this view no longer
-- holds, is unchanged ('False'): jump numbers are per camera, so the handle is checked against the view's own record.
cancelJumpView ∷ (Ord k, Show k) ⇒ TerrainView k → PendingJump → STM Bool
cancelJumpView (TerrainView _ state) (PendingJump number box) = do
  mine ← (== Just box) . Map.lookup number <$> readTVar (vsJumps state)
  settled ← readTVar box
  case settled of
    _ | not mine → pure False
    Just _ → pure False
    Nothing → do
      writeTVar box (Just SettledCancelled)
      modifyTVar' (vsJumps state) (Map.delete number)
      modifyTVar' (vsCamera state) (cancelJump (JumpId number))
      modifyTVar' (vsIntent state) (+ 1)
      pure True

-- ---------------------------------------------------------------------------
-- Observation


-- | A reading of one view, for observation.
readView ∷ (Ord k, Show k) ⇒ TerrainView k → STM ViewReading
readView (TerrainView service state) = do
  phase ← readTVar (vsPhase state)
  published ← readTVar (vsPublished state)
  pins ← readTVar (vsPins state)
  regions ← readTVar (vsRegions state)
  pending ← readTVar (vsPending state)
  adopted ← adoptedRevision service state
  -- waiting for capacity: a preparation that stopped for it, or a stage waiting for room (the account, the terrain
  -- service, the owner's queue)
  stopped ← isJust <$> readTVar (vsRetry state)
  staged ← readTVar (vsStage state) <&> \case
    StageCopying _ copying → isJust (cpWait copying)
    StagePlanning _ planning → isJust (plWait planning)
    StageBuilding _ building → isNothing (bdTicket building)
    _ → False
  let waiting = stopped || staged
  restarts ← readTVar (vsRestarts state)
  staged' ← readTVar (vsStageCharge state)
  factsBytes ← readTVar (vsFactsCharge state)
  demandBytes' ← demandNeed state
  pinnedBytes ← pinnedNeed state
  unadmitted ← readTVar (vsUnadmitted state)
  steps ← readTVar (vsSteps state)
  admittedCount ← readTVar (vsAdmittedCount state)
  held ← readTVar (vsAccountHeld state)
  window ← readTVar (vsWindow state)
  adoptedResidency ← fmap (pinResidency . snd) <$> adoptedPin service state
  pure
    ViewReading
      { readingPhase = phase
      , readingPublished = published
      , readingAdopted = tagRevision . snd <$> adopted
      , readingPendingRegions = pending
      , readingRetainedRegions = Map.size regions
      , readingCpuBytes = held
      , readingGpuBytes = sum (map rgBytes (Map.elems regions))
      , readingPins = Map.size pins
      , readingWaiting = waiting
      , readingRestarts = restarts
      , readingStagedBytes = staged'
      , readingFactsBytes = factsBytes
      , readingDemandBytes = demandBytes'
      , readingUnadmitted = unadmitted
      , readingAdmitted = admittedCount
      , readingSteps = steps
      , readingNeedBytes = pinnedBytes + sum (map regionCpu (Map.elems regions)) + staged' + factsBytes + demandBytes'
      , readingPinnedBytes = pinnedBytes
      , readingWindow = window
      , readingAdoptedResidency = adoptedResidency
      }

-- | The view's camera as the last preparation settled it: its anchor, its followed surface, its clip, its zoom.
viewCameraState ∷ TerrainView k → STM CameraState
viewCameraState (TerrainView _ state) = readTVar (vsCamera state)

-- | The view's latest camera demand: its visible regions, then its prefetch. 'Nothing' before its first preparation.
viewDemand ∷ TerrainView k → STM (Maybe ([RegionCoord], [RegionCoord]))
viewDemand (TerrainView _ state) = readTVar (vsDemand state)

-- The newest revision the host adopted for the view's target, when it is this view's world.
adoptedRevision ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → STM (Maybe (Natural, WorldTag))
adoptedRevision service state = do
  newest ← ledgerNewestAdopted (portLedger (svPorts service)) (vtKey (vsTarget state))
  pure $ case newest of
    Just (revision, Just tag) | tagView tag == vsId state → Just (revision, tag)
    _ → Nothing

-- ---------------------------------------------------------------------------
-- Close

-- | Close the view and wait until it is closed: its demand withdrawn, its claim handed back (with a real empty
-- revision when it published), its interests dropped and its regions on their way to retirement. Idempotent.
closeView ∷ (Ord k, Show k) ⇒ TerrainView k → IO ()
closeView (TerrainView _ state) = do
  atomically (writeTVar (vsClosing state) True)
  atomically (readTVar (vsClosed state) >>= check)

-- | Whether the view still holds its style (its parents' interests, its asset snapshot and both coverage planes): until
-- its close releases it. Read-only.
viewHoldsStyle ∷ TerrainView k → STM Bool
viewHoldsStyle (TerrainView _ state) = isJust <$> readTVar (vsStyle state)

-- | Whether the view has closed.
viewClosed ∷ (Ord k, Show k) ⇒ TerrainView k → STM Bool
viewClosed (TerrainView _ state) = readTVar (vsClosed state)

-- | Whether the view's close was asked for (it may not have completed yet).
viewClosing ∷ TerrainView k → STM Bool
viewClosing (TerrainView _ state) = readTVar (vsClosing state)

-- The worker's close of one view.
runClose ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → IO ()
runClose service state = do
  let ports = svPorts service
      target = vsTarget state
  -- A close is re-entrant: one interrupted after its main transaction (the phase is then closed) goes on from the
  -- parents' release. The view stays in the service's views until then, so the service's end finds it.
  handedBack ← (== PhaseClosed) <$> readTVarIO (vsPhase state)
  unless handedBack $ do
    -- whatever the view's preparation holds is handed to cleanup first
    abandonStage service state
    void (Runtime.clearViewDemand (portTerrain ports) (vsRuntimeView state))
    Runtime.closeView (portTerrain ports) (vsRuntimeView state)
    closeMain service state target
    transferSeam service state "closed"
  -- the parents are released, then the view leaves the service and its close is announced, with no cancellation
  -- between: a 'closeView' waiting on it never waits on a view nobody can find
  uninterruptibleMask_ $ do
    style ← atomically (readTVar (vsStyle state) <* writeTVar (vsStyle state) Nothing)
    forM_ style releaseStyle
    atomically $ do
      modifyTVar' (svViews service) (Map.delete (vsId state))
      writeTVar (vsClosed state) True

-- The close's main step: the jumps settle, the claim is handed back, the interests drop, the regions retire and every
-- charge and payload the view keeps goes, in one transaction.
closeMain ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → ViewTarget k → IO ()
closeMain service state target = do
  let ports = svPorts service
  atomically $ do
    jumps ← readTVar (vsJumps state)
    forM_ (Map.elems jumps) $ \box → readTVar box >>= \case Nothing → writeTVar box (Just SettledCancelled); Just _ → pure ()
    writeTVar (vsJumps state) Map.empty
    -- The claim is handed back in the same step as its empty revision: if it still names this view and the view
    -- published, the host's initial content (opaque black, naming nothing) is published as a real new revision with
    -- its own barrier entry and adoption, so the closed terrain retires without a later M1 publication. A view that
    -- never published leaves the latest value alone; an ended target is published nothing.
    released ← releaseClaim (portClaims ports) (vtKey target) (vsId state)
    case released of
      Just claim | claimPublished claim → do
        usable ← vtUsable target
        when usable (void (vtPublish target (portInitial ports)))
      _ → pure ()
    forM_ (Set.toList (vsStyleIds state)) (ledgerDropInterest (portLedger ports))
    regions ← readTVar (vsRegions state)
    writeTVar (vsRegions state) Map.empty
    modifyTVar' (svRetiring service) (<> [Retiring (rgChunk region) (rgBytes region) (regionCpu region) RetireUnasked | region ← Map.elems regions])
    moveToService service state (sum (map regionCpu (Map.elems regions)))
    writeTVar (vsPins state) Map.empty
    writeTVar (vsFacts state) Nothing
    writeTVar (vsFactsCharge state) 0
    -- what the closed handle would otherwise keep reachable: its demand, its admission sets
    writeTVar (vsDemand state) Nothing
    writeTVar (vsExtraDemand state) []
    writeTVar (vsAdmitted state) Set.empty
    writeTVar (vsVisibleAdmitted state) Set.empty
    writeTVar (vsDemandBusy state) Nothing
    writeTVar (vsRetry state) Nothing
    held ← readTVar (vsAccountHeld state)
    when (held > 0) (accountRelease (portAccount ports) held)
    writeTVar (vsAccountHeld state) 0
    modifyTVar' (svReleases service) (+ 1)
    writeTVar (vsPhase state) PhaseClosed

-- ---------------------------------------------------------------------------
-- The worker

data Work k
  = WorkStop
  | WorkAttach !(AttachRequest k) !AcquiredStyle !(TVar (Maybe (Settled (TerrainView k))))
  | WorkClose !(ViewState k)
  | WorkRetire
  | WorkStep !(ViewState k)
  | WorkDemand !(ViewState k)
  | WorkAuthority !(ViewState k)

worker ∷ (Ord k, Show k) ⇒ TerrainViews k → IO (Either SomeException ())
worker service = trySync loop
  where
    loop = do
      -- an attachment is taken off the queue and handed to its owner (the attachment) with no cancellation between
      work ← mask $ \restore →
        atomically (nextWork service) >>= \case
          WorkAttach request style box → Nothing <$ runAttach restore service request style box
          other → pure (Just other)
      case work of
        Nothing → loop
        Just next → run next
    run = \case
        WorkStop → shutdown service
        WorkAttach request style box → mask (\restore → runAttach restore service request style box) >> loop
        WorkClose state → guarded (runClose service state) >> loop
        WorkRetire → guarded (atomically (retireStep service)) >> loop
        WorkStep state → guarded (stepView service state) >> loop
        WorkDemand state → guarded (resendDemand service state) >> loop
        WorkAuthority state → guarded (checkAuthority service state) >> loop
    guarded action =
      trySync action >>= \case
        Left (failure ∷ SomeException) → recordFailure service (Text.pack (displayException failure))
        Right () → pure ()

nextWork ∷ (Ord k, Show k) ⇒ TerrainViews k → STM (Work k)
nextWork service = do
  open ← readTVar (svOpen service)
  if not open
    then pure WorkStop
    else
      requests
        `orElse` closes
        `orElse` retirements
        `orElse` demands
        `orElse` preparations
  where
    requests =
      readTVar (svRequests service) >>= \case
        RequestAttach request style box : rest → writeTVar (svRequests service) rest >> pure (WorkAttach request style box)
        [] → retry
    -- a view asked to close, or one whose target has retired, in whatever stage it is (the latter's close is asked
    -- here and the loss kept as evidence), or one whose lease must be checked again because some lease stopped being
    -- valid. Only cells that change on those events are read: the terrain service's authority epoch, never its state,
    -- which every load writes, and the target's retirement cell, never the host's scene state.
    closes = do
      views ← Map.elems <$> readTVar (svViews service)
      epoch ← Runtime.authorityEpochSTM (portTerrain (svPorts service))
      firstClosing epoch views >>= maybe retry pure
    firstClosing epoch = \case
      [] → pure Nothing
      state : rest → do
        closing ← readTVar (vsClosing state)
        retired ← vtRetired (vsTarget state)
        seen ← readTVar (vsAuthoritySeen state)
        if
          | closing → pure (Just (WorkClose state))
          | retired → do
              recordFailureSTM service ("view " <> Text.pack (show (vsId state)) <> " closes: its target is gone")
              writeTVar (vsClosing state) True
              pure (Just (WorkClose state))
          | seen /= epoch → pure (Just (WorkAuthority state))
          | otherwise → firstClosing epoch rest
    retirements = retirable service >>= check >> pure WorkRetire
    demands = do
      views ← Map.elems <$> readTVar (svViews service)
      waiting ← filterM' (\state → readTVar (vsDemandBusy state) >>= maybe (pure False) (\mark → (/= mark) <$> retryMark service state)) views
      case waiting of
        state : _ → pure (WorkDemand state)
        [] → retry
    preparations = do
      views ← Map.toList <$> readTVar (svViews service)
      cursor ← readTVar (svCursor service)
      let ordered = [v | (k, v) ← views, k > cursor] <> [v | (k, v) ← views, k <= cursor]
      -- one bounded step of one view at a time, round-robin: a view with a long plan, a slow copy or a build in flight
      -- never keeps another view's step, attachment, close or retirement waiting
      ready ← filterM' (stepReady service) ordered
      case ready of
        state : _ → writeTVar (svCursor service) (vsId state) >> pure (WorkStep state)
        [] → retry

filterM' ∷ (a → STM Bool) → [a] → STM [a]
filterM' predicate = foldr (\x rest → predicate x >>= \keep → (if keep then (x :) else id) <$> rest) (pure [])

-- The arena's identity a preparation is made for: its content and knowledge revisions and its residency generation.
arenaIdentity ∷ Either e Runtime.ArenaStatus → Maybe Word64 → Maybe (Revision, Revision, Word64)
arenaIdentity status residency = case (status, residency) of
  (Right s, Just generation) → Just (Runtime.statusContentRevision s, Runtime.statusKnowledgeRevision s, generation)
  _ → Nothing

-- Whether a view has work: a new intent, a new arena revision or residency generation, new metrics, or pressure released
-- since it stopped.
viewDirty ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → STM Bool
viewDirty service state =
  readTVar (vsBlocked state) >>= \case
    -- an adoption other than the one seen, or a reader that let a pin go
    Just (BlockedOnAdoption seen readers) → do
      newest ← fmap fst <$> ledgerNewestAdopted (portLedger (svPorts service)) (vtKey (vsTarget state))
      now ← sum <$> readTVar (vsReaders state)
      pure (newest /= seen || now /= readers)
    Just BlockedOnMetrics → do
      metrics ← vtMetrics (vsTarget state)
      status ← Runtime.arenaStatusSTM (portTerrain (svPorts service)) (vsArena state)
      pure (isJust metrics && either (const False) (const True) status)
    Nothing → unblockedDirty service state

unblockedDirty ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → STM Bool
unblockedDirty service state = do
  intent ← readTVar (vsIntent state)
  (prepared, revisions, metrics) ← readTVar (vsPrepared state)
  status ← Runtime.arenaStatusSTM (portTerrain (svPorts service)) (vsArena state)
  residency ← residencyNow service state
  now ← vtMetrics (vsTarget state)
  retryAt ← readTVar (vsRetry state)
  mark ← retryMark service state
  let current = arenaIdentity status residency
  continue ← readTVar (vsContinue state)
  pure (intent /= prepared || current /= revisions || now /= metrics || maybe False (/= mark) retryAt || continue)

-- What a waiting preparation watches: the service's releases, the target's newest adoption, the shared account's charge
-- (moved by any of its consumers: coverage, view payloads or the terrain service's own staging), the owner's unsettled
-- uploads and the terrain service's retained bank.
retryMark ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → STM Mark
retryMark service state = do
  releases ← readTVar (svReleases service)
  newest ← ledgerNewestAdopted (portLedger (svPorts service)) (vtKey (vsTarget state))
  charged ← accountCharged (portAccount (svPorts service))
  -- an upload that settles frees the staging buffer or its queue, which a build refused as pressure waits for
  uploads ← ownerUploadsSettled (portOwner (svPorts service))
  -- the terrain service's retained bank: a regional request that settles (its reservation becomes its footprint) or is
  -- released makes room a copy refused 'BusyRetained' waits for
  retained ← Runtime.retainedBankUseSTM (portTerrain (svPorts service))
  pure (releases, fst <$> newest, charged, uploads, retained)

-- The graphics owner takes no more actions, so the retirements left cannot be proved: they are kept as terminal
-- evidence, and their GPU bytes stay charged.
abandonRetirements ∷ TerrainViews k → STM ()
abandonRetirements service = do
  left ← readTVar (svRetiring service)
  orphans ← readTVar (svOrphans service)
  writeTVar (svRetiring service) []
  writeTVar (svOrphans service) []
  let count = length left + length orphans
  when (count > 0) $
    recordFailureSTM service ("retirement could not be proved for " <> Text.pack (show count) <> " retained regions or builds: the graphics owner takes no more actions")

-- The service's end: close every view, then drain the retirements.
shutdown ∷ (Ord k, Show k) ⇒ TerrainViews k → IO ()
shutdown service = do
  views ← Map.elems <$> readTVarIO (svViews service)
  forM_ views $ \state → do
    atomically (writeTVar (vsClosing state) True)
    trySync (runClose service state) >>= \case
      Left (failure ∷ SomeException) → recordFailure service ("a view's close failed: " <> Text.pack (displayException failure))
      Right () → pure ()
  -- Settle every attachment still queued.
  queued ← atomically (readTVar (svRequests service) <* writeTVar (svRequests service) [])
  settleQueued queued
  disposeAbandonedCopies service
  drain
  -- what the service still holds for retiring regions left by an owner that ended returns now that nothing can use it;
  -- a failed release's description is still in the renderer's registry, so its CPU stays charged, reported here
  atomically $ do
    kept ← readTVar (svKeptCpu service)
    held ← readTVar (svRetiringCpu service)
    returnFromService service (held - min held kept)
    when (kept > 0) $
      recordFailureSTM service ("failed releases keep " <> Text.pack (show kept) <> " bytes of their descriptions charged: they are still in the renderer's registry")
    writeTVar (svShutDown service) True
  where
    drain = do
      remaining ← atomically ((\r o → not (null r && null o)) <$> readTVar (svRetiring service) <*> readTVar (svOrphans service))
      when remaining $ do
        -- Wait for a retirement to be able to move (an answer, a barrier, room on the owner, the ledger letting a chunk
        -- go, an upload ending), or for the graphics owner to end: then nothing it still holds will ever be handed back,
        -- and what is left is kept as terminal evidence. So the scope's exit ends in either order of the host's end and
        -- the views'.
        moved ← atomically ((True <$ (retirable service >>= check)) `orElse` (False <$ ownerEnd (portOwner (svPorts service))))
        if moved
          then atomically (retireStep service) >> drain
          else atomically (abandonRetirements service)

-- Whether a retirement can move now. Every wait is on something that changes: an action's or a barrier's answer, room
-- on the owner's queue or release lane, the ledger letting a chunk go, an upload ending. A full lane or queue is waited
-- on, never asked again at once, so a blocked retirement never makes the worker loop; a failed release has left the list.
retirable ∷ TerrainViews k → STM Bool
retirable service = do
  let owner = portOwner (svPorts service)
      ledger = portLedger (svPorts service)
  orphans ← readTVar (svOrphans service)
  orphanAnswered ← or <$> forM orphans (\o → isJust <$> orTicket o)
  retiring ← readTVar (svRetiring service)
  laneRoom ← ownerReleaseRoom owner
  room ← ownerRoom owner
  candidates ← forM retiring $ \r → case rtState r of
    RetireUnasked → pure laneRoom
    RetireWaiting reading → isJust <$> reading
    RetireMet → if room then releasable ledger owner r else pure False
    RetireReleasing ticket _ → isJust <$> ticket
  pure (orphanAnswered || or candidates)

-- A chunk behind a met barrier that no adoption lists and whose upload has ended: its release on the owner is never
-- deferred, so the release's answer proves its buffer gone.
releasable ∷ SceneLedger k → ViewOwner → Retiring → STM Bool
releasable ledger owner r = do
  held ← ledgerChunkHeld ledger (rtChunk r)
  standing ← ownerStanding owner (rtChunk r)
  pure (not held && standing /= Just ChunkUploading)

-- One retirement step, in one transaction that never waits:
--
-- * builds a closed or superseded preparation left in flight that answered: what they built retires (a barrier is not
--   needed for chunks no revision listed); a build that built nothing returns its GPU bytes;
-- * the host's release barrier is asked for every published chunk not yet behind one, when the lane has room;
-- * barriers that answered move on;
-- * releases that answered end their chunks: a released chunk returns its GPU bytes; a release that failed is kept as
--   evidence, its bytes still charged, and never asked again;
-- * the chunks now releasable are released on the owner in one action, when the owner has room.
--
-- An owner that will never answer (gone, or a barrier it will never meet) ends the retirements as terminal evidence.
retireStep ∷ TerrainViews k → STM ()
retireStep service = do
  let ports = svPorts service
      owner = portOwner ports
  -- builds left in flight
  orphans ← readTVar (svOrphans service)
  stillOut ← fmap concat . forM orphans $ \o →
    orTicket o >>= \case
      Nothing → pure [o]
      Just (Answered (Right chunks)) | length chunks == length (orBytes o) → do
        modifyTVar' (svRetiring service) (<> [Retiring chunk bytes cpu RetireMet | (chunk, bytes, cpu) ← zip3 chunks (orBytes o) (orCpu o)])
        modifyTVar' (svGpu service) (subtract (orGpu o - sum (orBytes o)))
        pure []
      Just (Answered (Right chunks)) → do
        recordFailureSTM service "a build left in flight answered another number of regions than asked"
        modifyTVar' (svRetiring service) (<> [Retiring chunk 0 0 RetireMet | chunk ← chunks])
        pure []
      Just answer → do
        -- it stopped: what it built retires with its charges, and the GPU bytes and the CPU of what it did not build
        -- return
        let built = case answer of
              Answered (Left (BuildPressure chunks _)) → chunks
              Answered (Left (BuildFailed chunks _)) → chunks
              _ → []
            paired = zip3 built (orBytes o) (orCpu o)
        modifyTVar' (svRetiring service) (<> [Retiring chunk bytes cpu RetireMet | (chunk, bytes, cpu) ← paired])
        modifyTVar' (svGpu service) (subtract (orGpu o - min (orGpu o) (sum [b | (_, b, _) ← paired])))
        returnFromService service (sum (orCpu o) - min (sum (orCpu o)) (sum [c | (_, _, c) ← paired]))
        modifyTVar' (svReleases service) (+ 1)
        pure []
  writeTVar (svOrphans service) stillOut
  retiring ← readTVar (svRetiring service)
  laneRoom ← ownerReleaseRoom owner
  let unasked = [rtChunk r | r ← retiring, RetireUnasked ← [rtState r]]
  asked ← if null unasked || not laneRoom then pure (Left OwnerBusy) else ownerBarrier owner unasked
  stepped ← forM retiring $ \r → case rtState r of
    RetireUnasked → pure $ case asked of
      Right reading → Next r {rtState = RetireWaiting reading}
      Left OwnerGone → Gone
      Left OwnerBusy → Next r
    RetireWaiting reading →
      reading >>= \case
        Just True → pure (Next r {rtState = RetireMet})
        Just False → pure Gone
        Nothing → pure (Next r)
    RetireMet → pure (Next r)
    RetireReleasing ticket index →
      ticket >>= \case
        Nothing → pure (Next r)
        -- a release action that did not answer: only an owner that takes no more actions ends every retirement; one that
        -- goes on serving keeps this region's failure and charges as evidence, and every other retirement goes on
        Just (NotRun why) → do
          ended ← (True <$ ownerEnd owner) `orElse` pure False
          if ended
            then pure Gone
            else do
              recordFailureSTM service ("a retained region's release did not run: " <> Text.pack (show (rtChunk r)) <> ": " <> why)
              modifyTVar' (svKeptCpu service) (+ rtCpu r)
              pure Kept
        Just (Answered results) → case drop index results of
          Right () : _ → pure Released
          Left why : _ → do
            recordFailureSTM service ("a retained region's release failed: " <> Text.pack (show (rtChunk r)) <> ": " <> why)
            modifyTVar' (svKeptCpu service) (+ rtCpu r)
            pure Kept
          [] → pure Kept
  if any isGone stepped
    then abandonRetirements service
    else do
      let released = [r | (r, Released) ← zip retiring stepped]
          left = [r' | Next r' ← stepped]
      unless (null released) $ do
        modifyTVar' (svGpu service) (subtract (sum (map rtBytes released)))
        returnFromService service (sum (map rtCpu released))
        modifyTVar' (svReleases service) (+ 1)
      -- the chunks now releasable, released in one action when the owner has room
      room ← ownerRoom owner
      eligible ← if room then filterM' (\r → case rtState r of RetireMet → releasable (portLedger ports) owner r; _ → pure False) left else pure []
      if null eligible
        then writeTVar (svRetiring service) left
        else
          ownerRelease owner (map rtChunk eligible) >>= \case
            Left OwnerBusy → writeTVar (svRetiring service) left
            Left OwnerGone → writeTVar (svRetiring service) left >> abandonRetirements service
            Right ticket → do
              let indexOf = Map.fromList (zip (map rtChunk eligible) [0 ..])
              writeTVar (svRetiring service) [maybe r (\i → r {rtState = RetireReleasing ticket i}) (Map.lookup (rtChunk r) indexOf) | r ← left]
  where
    isGone = \case
      Gone → True
      _ → False

-- What one retirement entry's step decided.
data RetireStep = Next !Retiring | Released | Kept | Gone

-- ---------------------------------------------------------------------------
-- Preparation

-- How one preparation ended.
data Prepared'
  = Published' !Word64
  | Unchanged'
  | Retry'
  | Abandoned'

-- What a waiting step watches: the service's releases, the target's newest adoption, the shared account's charge, how
-- many of the owner's uploads have settled, and the terrain service's retained bank.
type Mark = (Word64, Maybe Natural, Word64, Natural, Word64)

-- | Where a view's preparation stands. Each stage is resumable and owns what it holds until it hands it on: the worker
-- takes one bounded step of one view at a time, so no view's copies, plan, build or uploads keep the worker from another
-- view's attachment, close or retirement.
data Stage
  = StageIdle
  | -- | Copies are asked for one batch at a time: at most one request in flight, owned here; each settled batch is
    -- taken, checked against the others, charged to the view and released in one transaction.
    StageCopying !Prep !Copying
  | -- | The planner, one quantum per step.
    StagePlanning !Prep !Planning
  | -- | A build on the owner, in flight (its ticket owned here) or waiting for room on the owner's queue.
    StageBuilding !Prep !Building
  | -- | Built chunks whose uploads have not all ended, owned here until published or retired.
    StageUploading !Prep !Uploading

data Prep = Prep
  { prpIntent ∷ !Word64
  , prpMetrics ∷ !TargetMetrics
  , prpIdentity ∷ !(Maybe (Revision, Revision, Word64))
  , prpRegions ∷ !(Set.Set RegionCoord)
    -- ^ What this preparation copies: the camera's anchor and a jump's destination first, then each plan's missing
    -- demand, round by round.
  , prpRounds ∷ !Int
  , prpRestarts ∷ !Int
    -- ^ Copies of different committed versions start the copies again, at most this many more times.
  }

data Copying = Copying
  { cpKept ∷ ![Runtime.RegionSnapshot]
    -- ^ The batches taken so far: immutable values, charged to the view's account, their borrows already released.
  , cpTodo ∷ ![[RegionCoord]]
  , cpPending ∷ !(Maybe ([RegionCoord], Runtime.Pending Runtime.RegionBorrow))
  , cpWait ∷ !(Maybe CopyWait)
  }

-- What a copying stage that cannot go on waits for.
data CopyWait
  = -- | A request refused busy (the terrain service's banks, its retained bank): any change of the mark.
    WaitMark !Mark
  | -- | A copy the account could not hold: this much free room in the account, the whole granules the charge needs. A
    -- release that leaves the account as full (another view's copy taken and dropped) does not wake it.
    WaitRoom !Word64

data Planning = Planning
  { plCopies ∷ !CopySet
  , plInputs ∷ !CellInputs
  , plPrep ∷ !CellPrep
  , plBase ∷ !Word64
    -- ^ The stage's charge before planning: the copies (the inputs made from them are the kept facts' charge).
  , plWait ∷ !(Maybe Mark)
    -- ^ The account could not hold the next quantum's growth: it is asked again once something is released.
  }

data Building = Building
  { bdPlan ∷ !CellPlan
  , bdAdapted ∷ !Adapted
  , bdCopies ∷ !CopySet
  , bdReused ∷ !(Map (Integer, Integer) Region)
  , bdWanted ∷ !(Map (Integer, Integer) ([Instance], [MaterialRecord]))
  , bdGpu ∷ !Word64
  , bdCpu ∷ !Word64
  , bdTicket ∷ !(Maybe (Ticket (Either BuildFailure [ChunkRef])))
  , bdUploads ∷ !Natural
    -- ^ How many of the owner's uploads had settled when the build was submitted, read in the submission's transaction:
    -- a build refused as upload pressure waits for more to have settled, so an upload that settles after the submission
    -- (even one that also started after it) is never missed.
  }

data Uploading = Uploading
  { upPlan ∷ !CellPlan
  , upAdapted ∷ !Adapted
  , upCopies ∷ !CopySet
  , upReused ∷ !(Map (Integer, Integer) Region)
  , upFresh ∷ !(Map (Integer, Integer) Region)
  , upCpu ∷ !Word64
  }

-- A build left in flight by a closed or superseded preparation: what it builds retires when it answers.
data Orphan = Orphan
  { orTicket ∷ !(Ticket (Either BuildFailure [ChunkRef]))
  , orGpu ∷ !Word64
  , orBytes ∷ ![Word64]
  , orCpu ∷ ![Word64]
  }

-- Whether the view's stage can take a step now (an idle view: whether it has work).
stepReady ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → STM Bool
stepReady service state =
  readTVar (vsStage state) >>= \case
    StageIdle → viewDirty service state
    StageCopying prep copying → do
      stale ← superseded state prep
      if stale
        then pure True
        else case (cpPending copying, cpWait copying) of
          (Just (_, pending), _) → settled pending
          (Nothing, Just (WaitMark mark)) → (/= mark) <$> retryMark service state
          (Nothing, Just (WaitRoom room)) → (>= room) <$> accountRoom (portAccount (svPorts service))
          (Nothing, Nothing) → pure True
    StagePlanning prep planning → do
      stale ← superseded state prep
      case plWait planning of
        Just mark | not stale → (/= mark) <$> retryMark service state
        _ → pure True
    StageBuilding prep building → do
      stale ← superseded state prep
      if stale
        then pure True
        else case bdTicket building of
          Nothing → ownerRoom (portOwner (svPorts service))
          Just ticket → isJust <$> ticket
    StageUploading prep uploading → do
      stale ← superseded state prep
      if stale
        then pure True
        else not <$> anyUploading service (upFresh uploading)
  where
    -- whether a request has settled, read without taking it: the take is rolled back with the exception that carries
    -- the answer out
    settled pending = ((Runtime.awaitSTM (portTerrain (svPorts service)) pending >> throwSTM RequestSettled) `catchSTM` \RequestSettled → pure True) `orElse` pure False

data RequestSettled = RequestSettled
  deriving (Show)

instance Exception RequestSettled

anyUploading ∷ TerrainViews k → Map (Integer, Integer) Region → STM Bool
anyUploading service fresh = or <$> forM (Map.elems fresh) (\region → (== Just ChunkUploading) <$> ownerStanding (portOwner (svPorts service)) (rgChunk region))

-- A newer intent or other metrics make a stage's work obsolete: it is handed to cleanup and the newer state prepared.
superseded ∷ ViewState k → Prep → STM Bool
superseded state prep = do
  intent ← readTVar (vsIntent state)
  metrics ← vtMetrics (vsTarget state)
  pure (intent /= prpIntent prep || metrics /= Just (prpMetrics prep))

-- One step of the view's preparation.
stepView ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → IO ()
stepView service state = do
  atomically (modifyTVar' (vsSteps state) (+ 1))
  readTVarIO (vsStage state) >>= \case
    StageIdle → startPreparation service state
    stage → do
      stale ← case stagePrep stage of
        Just prep → atomically (superseded state prep)
        Nothing → pure False
      if stale
        then abandonStage service state >> finish service state Abandoned' Nothing
        else case stage of
          StageCopying prep copying → stepCopying service state prep copying
          StagePlanning prep planning → stepPlanning service state prep planning
          StageBuilding prep building → stepBuilding service state prep building
          StageUploading prep uploading → stepUploading service state prep uploading

stagePrep ∷ Stage → Maybe Prep
stagePrep = \case
  StageIdle → Nothing
  StageCopying prep _ → Just prep
  StagePlanning prep _ → Just prep
  StageBuilding prep _ → Just prep
  StageUploading prep _ → Just prep

stageName ∷ Stage → Text
stageName = \case
  StageIdle → "idle"
  StageCopying {} → "copying"
  StagePlanning {} → "planning"
  StageBuilding {} → "building"
  StageUploading {} → "uploading"

-- Enter a stage: recorded first, then the seam that lets an example hold the worker exactly there.
enter ∷ TerrainViews k → ViewState k → Stage → IO ()
enter service state stage = do
  atomically (writeTVar (vsStage state) stage)
  stageSeam service state stage

-- The test seam after a stage was recorded.
stageSeam ∷ TerrainViews k → ViewState k → Stage → IO ()
stageSeam service state stage = tvOnStage (svConfig service) (vsId state) (stageName stage)

-- End a preparation: the outcome is recorded, the stage is idle again and its charge is gone.
finish ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Prepared' → Maybe Prep → IO ()
finish service state outcome prep = atomically (finishSTM service state outcome prep)

-- A preparation refused as upload pressure ends waiting on these uploads (read when its build was submitted) in place of
-- the owner's now: any that settled since then is a change, and it runs again.
finishPressured ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Natural → Prep → IO ()
finishPressured service state uploads prep = atomically $ do
  finishSTM service state Retry' (Just prep)
  modifyTVar' (vsRetry state) (fmap (\(releases, adopted, charged, _, retained) → (releases, adopted, charged, uploads, retained)))

finishSTM ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Prepared' → Maybe Prep → STM ()
finishSTM service state outcome prep = do
  writeTVar (vsStage state) StageIdle
  writeTVar (vsStageCharge state) 0
  _ ← recharge service state
  mark ← retryMark service state
  case outcome of
    Retry' → writeTVar (vsRetry state) (Just mark)
    _ → writeTVar (vsRetry state) Nothing
  case (outcome, prep) of
    (Abandoned', _) → pure ()
    (_, Just p) → writeTVar (vsPrepared state) (prpIntent p, prpIdentity p, Just (prpMetrics p))
    (_, Nothing) → pure ()
  published ← readTVar (vsPublished state)
  writeTVar (vsPhase state) (if isJust published then PhasePublished else PhaseStarting)

-- Hand everything a stage holds to cleanup, exactly once: a request in flight is cancelled (or, settled, released), a
-- build in flight is left to the retirements to collect, built chunks retire (no barrier: no revision listed them), and
-- the stage's charge returns.
abandonStage ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → IO ()
abandonStage service state = do
  atomically (abandonStageSTM service state)
  transferSeam service state "abandoned"
  disposeAbandonedCopies service

-- The stage ends and everything it holds changes owner in one transaction, so no cancellation can fall between the two: a
-- copy request in flight to the service's abandoned copies, a build in flight to the orphans (a reservation with no
-- build yet returns), built chunks to the retirements; the stage's charge returns.
abandonStageSTM ∷ TerrainViews k → ViewState k → STM ()
abandonStageSTM service state = do
  stage ← readTVar (vsStage state)
  writeTVar (vsStage state) StageIdle
  case stage of
    StageCopying _ copying → forM_ (cpPending copying) $ \(_, pending) → modifyTVar' (svAbandonedCopies service) (pending :)
    StageBuilding _ building → case bdTicket building of
      Just ticket → do
        let wanted = Map.elems (bdWanted building)
            cpus = [wantedCpu instances records | (instances, records) ← wanted]
        modifyTVar' (svOrphans service) (<> [Orphan ticket (bdGpu building) [fromIntegral (length instances) * instanceBytes | (instances, _) ← wanted] cpus])
        -- the CPU it will describe moves out of the stage's charge into the service's
        modifyTVar' (vsStageCharge state) (\c → c - min c (sum cpus))
        moveToService service state (sum cpus)
      Nothing → modifyTVar' (svGpu service) (subtract (bdGpu building))
    StageUploading _ uploading → do
      retireFresh service (upFresh uploading)
      let cpus = sum (map regionCpu (Map.elems (upFresh uploading)))
      modifyTVar' (vsStageCharge state) (\c → c - min c cpus)
      moveToService service state cpus
    _ → pure ()
  writeTVar (vsStageCharge state) 0
  void (recharge service state)
  modifyTVar' (svReleases service) (+ 1)

-- Dispose of the copy requests abandoned stages left in flight: a settled one is taken and its borrow released, a
-- pending one cancelled, and one that settles between the probe and the cancellation taken and released after all.
-- Each is taken from the list and disposed of with no cancellation between the two.
disposeAbandonedCopies ∷ TerrainViews k → IO ()
disposeAbandonedCopies service = do
  let terrain = portTerrain (svPorts service)
  more ← uninterruptibleMask_ $ do
    next ← atomically $ readTVar (svAbandonedCopies service) >>= \case
      pending : rest → Just pending <$ writeTVar (svAbandonedCopies service) rest
      [] → pure Nothing
    forM_ next $ \pending → do
      taken ← atomically ((Just <$> Runtime.awaitSTM terrain pending) `orElse` pure Nothing)
      case taken of
        Just (Right borrow) → Runtime.releaseRegionBorrow terrain borrow
        Just (Left _) → pure ()
        Nothing → do
          tvOnTransfer (svConfig service) 0 "cancelling"
          Runtime.cancelPending terrain pending >>= \case
            -- it settled after the probe: the settled result is taken and its borrow released, as a cancellation that
            -- lost to the settlement must ('Runtime.withRegionSnapshot')
            Runtime.AlreadySettled → atomically (Runtime.awaitSTM terrain pending) >>= either (const (pure ())) (Runtime.releaseRegionBorrow terrain)
            _ → pure ()
    pure (isJust next)
  when more (disposeAbandonedCopies service)

-- The test seam after a transaction that handed resources on.
transferSeam ∷ TerrainViews k → ViewState k → Text → IO ()
transferSeam service state = tvOnTransfer (svConfig service) (vsId state)

-- Built chunks no revision listed retire with no barrier; their GPU bytes stay charged until each is released.
retireFresh ∷ TerrainViews k → Map (Integer, Integer) Region → STM ()
retireFresh service fresh = modifyTVar' (svRetiring service) (<> [Retiring (rgChunk r) (rgBytes r) (regionCpu r) RetireMet | r ← Map.elems fresh])

startPreparation ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → IO ()
startPreparation service state = do
  -- Which pins survive and the adoption the view waits on are decided from one observation, in one transaction: an
  -- adoption that lands after it is a change the view wakes for, never its baseline.
  started ← atomically $ do
    dropUnneededPinsSTM service state
    pins ← Map.size <$> readTVar (vsPins state)
    if pins >= tvCpuPins (svConfig service)
      then do
        finishSTM service state Retry' Nothing
        newest ← fmap fst <$> ledgerNewestAdopted (portLedger (svPorts service)) (vtKey (vsTarget state))
        readers ← sum <$> readTVar (vsReaders state)
        writeTVar (vsBlocked state) (Just (BlockedOnAdoption newest readers))
        pure False
      else pure True
  when started (prepareFrom service state)

-- Some lease stopped being valid since the view's was last found valid: check the view's own, in a transaction of its
-- own. The epoch is recorded; a lease that is gone (revoked, released, its arena closed) closes the view through its own
-- close, which hands the target back, and the loss is kept as evidence.
checkAuthority ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → IO ()
checkAuthority service state = atomically $ do
  epoch ← Runtime.authorityEpochSTM (portTerrain (svPorts service))
  status ← Runtime.arenaStatusSTM (portTerrain (svPorts service)) (vsArena state)
  writeTVar (vsAuthoritySeen state) epoch
  case status of
    Left why → do
      recordFailureSTM service ("view " <> Text.pack (show (vsId state)) <> " closes: its arena authority is gone: " <> Text.pack (show why))
      writeTVar (vsClosing state) True
    Right _ → pure ()

prepareFrom ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → IO ()
prepareFrom service state = do
  (intent, metrics, status, residency) ← atomically $ do
    (,,,) <$> readTVar (vsIntent state) <*> vtMetrics (vsTarget state) <*> Runtime.arenaStatusSTM (portTerrain (svPorts service)) (vsArena state) <*> residencyNow service state
  let identity = arenaIdentity status residency
  case (metrics, status) of
    (Just m, Right _) → do
      (camera, extra, seeds) ← atomically $ do
        writeTVar (vsContinue state) False
        writeTVar (vsBlocked state) Nothing
        camera ← readTVar (vsCamera state)
        extra ← readTVar (vsExtraDemand state)
        -- a partial plan goes on from the regions it admitted that its own visible demand named
        unadmitted ← readTVar (vsUnadmitted state)
        admitted ← readTVar (vsAdmitted state)
        pure (camera, extra, if unadmitted > 0 then Set.toList admitted else [])
      let anchor = anchorRegion camera
          ordered = take (max 1 (tvAdmitRegions (svConfig service))) (admissionOrder anchor (extra <> seeds))
          prep = Prep intent m identity (Set.fromList ordered) maxRounds maxRestarts
      atomically (writeTVar (vsPhase state) PhasePreparing)
      enter service state (StageCopying prep (Copying [] (batchesOf service ordered) Nothing Nothing))
    _ → do
      finish service state Unchanged' Nothing
      atomically (writeTVar (vsBlocked state) (Just BlockedOnMetrics))

-- The planner finds its demand as it goes: regions behind known air become candidates only once the regions in front of
-- them are known. So the copies start from the camera's anchor, and each plan's own visible demand that the copies did
-- not hold is copied too, and the plan made again, a bounded number of rounds. What is still missing then stays pending
-- in the published plan, and the next preparation goes on from there.
maxRounds, maxRestarts ∷ Int
maxRounds = 16

-- | The most one preparation's admitted copies and the inputs made from them can hold of the account: the terrain
-- service's reservation for the regions it copies, and each region's inputs.
admittedCostBound ∷ TerrainViewsConfig → Word64
admittedCostBound config =
  let regions = max 1 (tvAdmitRegions config)
   in Runtime.regionSnapshotReservation regions + inputsPerRegion * fromIntegral regions

-- | What a preparation over this many regions needs of the account beyond what the view already holds, at most: the
-- terrain service's reservation for their copies, their inputs and the room for the plan's first quantum over them.
preparationCost ∷ TerrainViewsConfig → Int → Word64
preparationCost config regions =
  Runtime.regionSnapshotReservation (max 1 regions) + inputsPerRegion * fromIntegral (max 1 regions) + quantumBound config (max 1 regions)

-- The order regions are admitted in: the camera's anchor, then the others nearest it first (by the larger of the
-- horizontal distances, then the vertical), then by coordinate. Pure, so a preparation admits the same regions for the
-- same camera and demand.
admissionOrder ∷ RegionCoord → [RegionCoord] → [RegionCoord]
admissionOrder anchor others = anchor : sortOn key (Set.toList (Set.delete anchor (Set.fromList others)))
  where
    RegionCoord ax ay az = anchor
    key r@(RegionCoord x y z) = (max (abs (x - ax)) (abs (y - ay)), abs (z - az), r)
maxRestarts = 3

-- Batches of at most the configured regions, and never more than the service's per-hold bound.
batchesOf ∷ TerrainViews k → [RegionCoord] → [[RegionCoord]]
batchesOf service = chunksOf (max 1 (min holdCap (tvCopyRegions (svConfig service))))
  where
    holdCap = fromIntegral (limitHoldRegions (Runtime.configLimits (Runtime.inspectConfig (portTerrain (svPorts service)))))

stepCopying ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Prep → Copying → IO ()
stepCopying service state prep copying = case cpPending copying of
  Just (batch, pending) → do
    -- Take, check, charge and release in one transaction: no cancellation can fall between the take and the release.
    outcome ← atomically $ do
      Runtime.awaitSTM terrain pending >>= \case
        Left settlement → pure (Left (Text.pack (show settlement)))
        Right borrow → do
          let snapshot = Runtime.regionBorrowSnapshot borrow
              kept = snapshot : cpKept copying
          Runtime.releaseRegionBorrowSTM terrain borrow
          modifyTVar' (svReleases service) (+ 1)
          case combineCopies kept of
            Left _ → pure (Right Nothing)
            Right _ → do
              before ← readTVar (vsStageCharge state)
              writeTVar (vsStageCharge state) (before + Runtime.regionSnapshotFootprint snapshot)
              charged ← recharge service state
              if charged
                then pure (Right (Just (Right kept)))
                else do
                  -- the wait is for the room this charge needs, so a release that leaves the account as full (another
                  -- view's copy taken and dropped, this one's own) does not wake it
                  room ← roomNeeded service state
                  writeTVar (vsStageCharge state) before
                  pure (Right (Just (Left room)))
    case outcome of
      Left why → do
        recordFailure service ("a regional copy failed: " <> why)
        abandonStage service state >> finish service state Retry' (Just prep)
      -- copies of different committed versions are never combined: the copies start again from fresh ones
      Right Nothing → restart
      -- the account cannot hold the copy now: with copies already taken, they are the admitted subset and the rest stays
      -- pending (a deliberately partial plan); with none, it is asked again once something is released
      Right (Just (Left room))
        | not (null (cpKept copying)) → partial (cpKept copying)
        | otherwise → enter service state (StageCopying prep copying {cpPending = Nothing, cpTodo = batch : cpTodo copying, cpWait = Just (WaitRoom room)})
      Right (Just (Right kept)) → next copying {cpKept = kept, cpPending = Nothing, cpWait = Nothing}
  Nothing → next copying {cpWait = Nothing}
  where
    terrain = portTerrain (svPorts service)
    partial kept = case combineCopies kept of
      Left _ → restart
      Right copies → toPlanning service state prep {prpRegions = copyRegions copies, prpRounds = 1} copies
    restart
      | prpRestarts prep > 0 = do
          atomically (writeTVar (vsStageCharge state) 0 >> void (recharge service state) >> modifyTVar' (vsRestarts state) (+ 1))
          let prep' = prep {prpRestarts = prpRestarts prep - 1}
          enter service state (StageCopying prep' (Copying [] (batchesOf service (Set.toList (prpRegions prep))) Nothing Nothing))
      | otherwise = abandonStage service state >> finish service state Retry' (Just prep)
    next current = case cpTodo current of
      batch : rest → do
        -- the mark is read before the request: whatever makes room after it (the retained bank included) moves it, so a
        -- refusal never waits for a change that already happened
        before ← atomically (retryMark service state)
        -- the request and its record in the stage, with no cancellation between them
        mask_ (Runtime.requestRegionSnapshot terrain (vsArena state) batch >>= traverse (\pending → pending <$ atomically (writeTVar (vsStage state) (StageCopying prep current {cpTodo = rest, cpPending = Just (batch, pending)})))) >>= \case
          Right pending → do
            transferSeam service state "requested"
            stageSeam service state (StageCopying prep current {cpTodo = rest, cpPending = Just (batch, pending)})
          Left (Runtime.RefusedBusy _) → enter service state (StageCopying prep current {cpWait = Just (WaitMark before)})
          Left refusal → do
            recordFailure service ("a regional copy was refused: " <> Text.pack (show refusal))
            abandonStage service state >> finish service state Retry' (Just prep)
      [] → case combineCopies (cpKept current) of
        Left _ → restart
        Right copies → toPlanning service state prep copies

toPlanning ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Prep → CopySet → IO ()
toPlanning service state prep0 copies0 = do
  -- the inputs are charged before they are made: a copied region's facts and knowledge at most its own record. When
  -- the account cannot hold them for every copy, the longest prefix of the copies (in admission order) it can hold is
  -- the admitted subset; the rest is dropped and stays pending.
  admitted ← atomically (admitInputs service state (reverse (copySnapshots copies0)))
  case admitted of
    Nothing → abandonStage service state >> finish service state Retry' (Just prep0)
    Just (copies, inputs) → planFrom (prep0 {prpRegions = copyRegions copies}) copies inputs
  where
    planFrom prep copies inputs = case planInputs (tvChangeLimits (svConfig service)) copies of
      Left why → failed ("the view's inputs could not be made: " <> Text.pack (show why))
      Right (facts, knowledge) → readTVarIO (vsStyle state) >>= \case
       -- the view's close released its style: nothing more is prepared for it
       Nothing → abandonStage service state >> finish service state Abandoned' Nothing
       Just style → do
        camera ← settleCamera service state facts inputs
        void (atomically (recharge service state))
        let cellInputs = CellInputs (CellRequest (factsVersions facts) camera (setupFor (prpMetrics prep)) (tvCellConfig (svConfig service))) facts knowledge (styleAssets style)
        base ← readTVarIO (vsStageCharge state)
        case startCells cellInputs of
          Left why → failed ("the plan could not start: " <> Text.pack (show why))
          Right cellPrep → enter service state (StagePlanning prep (Planning copies cellInputs cellPrep base Nothing))
      where
        failed why = recordFailure service why >> abandonStage service state >> finish service state Retry' (Just prep)

-- The longest prefix of these copies (taken in admission order) whose inputs the account can hold beside them, with
-- room left for the plan's first quantum over them (so an admitted subset can always be planned): the stage's charge
-- becomes that prefix's footprint and its inputs. 'Nothing' (and nothing changed) when not even the first copy fits.
admitInputs ∷ TerrainViews k → ViewState k → [Runtime.RegionSnapshot] → STM (Maybe (CopySet, Word64))
admitInputs service state ordered = do
  before ← readTVar (vsStageCharge state)
  let prefixes = [take n ordered | n ← [length ordered, length ordered - 1 .. 1]]
      attempt [] = writeTVar (vsStageCharge state) before >> pure Nothing
      attempt (prefix : rest) = case combineCopies prefix of
        Left _ → attempt rest
        Right copies → do
          -- each region's fixed inputs, and what the planner's knowledge expands to for regions of more than one class
          let inputs = inputsPerRegion * fromIntegral (Set.size (copyRegions copies)) + sum (map knowledgeExpansion prefix)
              held = sum (map Runtime.regionSnapshotFootprint prefix) + inputs
          writeTVar (vsStageCharge state) (held + quantumBound (svConfig service) (Set.size (copyRegions copies)))
          room ← recharge service state
          writeTVar (vsStageCharge state) held
          ok ← recharge service state
          if room && ok then pure (Just (copies, inputs)) else attempt rest
  attempt prefixes

-- Grow the stage's charge by these bytes, covered by the account: 'False' (and nothing changed) when it cannot.
growStage ∷ TerrainViews k → ViewState k → Word64 → STM Bool
growStage service state bytes = do
  before ← readTVar (vsStageCharge state)
  writeTVar (vsStageCharge state) (before + bytes)
  ok ← recharge service state
  unless ok (writeTVar (vsStageCharge state) before)
  pure ok

-- The most one quantum can add to a plan: each step evaluates at most the step's levels and finishes the column it is
-- in (whose levels are bounded by the band), each level at most two quads, and a step adds at most so many pending spans;
-- and never more than the copied regions' cells can give, two quads a cell.
quantumBound ∷ TerrainViewsConfig → Int → Word64
quantumBound config regions =
  let steps = fromIntegral (max 1 (tvStepsPerQuantum config))
      levels = fromIntegral (clStepLevels (ccLimits (tvCellConfig config))) + 512
      perSteps = steps * (levels * 2 * quadBytes + 64 * pendingBytes)
      perCells = fromIntegral regions * 16 * 16 * 32 * 2 * quadBytes
   in min perSteps perCells

stepPlanning ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Prep → Planning → IO ()
stepPlanning service state prep planning = case cellPrepProgress (plPrep planning) of
  Working → do
    -- the quantum's growth is charged before it is made, then the charge is set to what the plan now holds
    mark ← atomically (retryMark service state)
    charged ← atomically $ do
      writeTVar (vsStageCharge state) (plBase planning + prepHeld (plPrep planning))
      growStage service state (quantumBound (svConfig service) (Set.size (prpRegions prep)))
    if not charged
      then enter service state (StagePlanning prep planning {plWait = Just mark})
      else case steps (max 1 (tvStepsPerQuantum (svConfig service))) (plPrep planning) of
        Left why → failed ("a plan step failed: " <> Text.pack (show why))
        Right next → do
          atomically $ do
            writeTVar (vsStageCharge state) (plBase planning + prepHeld next)
            void (recharge service state)
          enter service state (StagePlanning prep planning {plPrep = next, plWait = Nothing})
  _ → case cellPlanOf (plInputs planning) (plPrep planning) of
    Left why → failed ("the plan could not finish: " <> Text.pack (show why))
    Right plan → do
      -- a jump whose destination the copies did not hold left its demand in this round's settlement: it is copied in
      -- the next round, as the plan's own missing demand is
      jumpDemand ← Set.fromList <$> readTVarIO (vsExtraDemand state)
      let demand = cellPlanDemand plan
          visible = regionsOf (cdVisible demand)
          prefetch = regionsOf (cdPrefetch demand)
          room = max 0 (tvAdmitRegions (svConfig service) - Set.size (prpRegions prep))
          anchor = case Set.toList (prpRegions prep) of
            first : _ → first
            [] → RegionCoord 0 0 0
          missing = Set.fromList (take room (drop 1 (admissionOrder anchor (Set.toList ((Set.fromList visible <> jumpDemand) `Set.difference` prpRegions prep)))))
      if not (Set.null missing) && prpRounds prep > 1
        then do
          -- the next round keeps the copies taken and makes the inputs again; the plan made here is dropped
          atomically $ do
            writeTVar (vsStageCharge state) (plBase planning)
            void (recharge service state)
          enter service state . StageCopying prep {prpRegions = prpRegions prep <> missing, prpRounds = prpRounds prep - 1} $
            Copying (copySnapshots (plCopies planning)) (batchesOf service (Set.toList missing)) Nothing Nothing
        else do
          let demanded = Set.toList (prpRegions prep <> Set.fromList visible)
          atomically $ do
            writeTVar (vsPending state) (length (cellPlanPending plan))
            writeTVar (vsUnadmitted state) (Set.size (Set.fromList visible `Set.difference` prpRegions prep))
            writeTVar (vsVisibleAdmitted state) (prpRegions prep `Set.intersection` Set.fromList visible)
          -- the plan's own size, then the adaptation, the regions' instances and records and the renderer's copies of
          -- them, all charged before they are made; and the demand about to be kept, beyond what the kept demand holds
          let quads = length (cellPlanQuads plan)
              held = planHeld quads (length (cellPlanPending plan)) + planDemandHeld (cellPlanDemand plan)
              adaptation = fromIntegral quads * (adaptedPerQuad + 2 * instanceBytes)
              demandGrowth kept = demandBytes * fromIntegral (length demanded + length prefetch) - min (demandBytes * fromIntegral (length demanded + length prefetch)) kept
          charged ← atomically $ do
            writeTVar (vsStageCharge state) (plBase planning + held)
            void (recharge service state)
            kept ← maybe 0 (\(v', p') → demandBytes * fromIntegral (length v' + length p')) <$> readTVar (vsDemand state)
            growStage service state (adaptation + demandGrowth kept)
          -- a preparation woken only to admit more (the same intent, metrics and arena state as the published plan) that
          -- admitted no more publishes nothing: it sleeps again until something it waits on changes. It is compared with
          -- what was published, never with a preparation that was refused (a retry after pressure is not unchanged)
          unchanged ← atomically $ do
            publishedFor ← readTVar (vsPublishedFor state)
            count ← readTVar (vsAdmittedCount state)
            pure (publishedFor == Just (prpIntent prep, prpIdentity prep, prpMetrics prep) && Set.size (prpRegions prep) <= count)
          if not charged || unchanged
            then abandonStage service state >> finish service state Retry' (Just prep)
            else do
              -- The camera's interests cover every region the plan was drawn from, not only what is still pending: the
              -- regions it shows, background far from the camera included, stay protected from eviction.
              setDemand service state demanded prefetch
              light ← readTVarIO (vsLight state)
              readTVarIO (vsStyle state) >>= \case
                Nothing → abandonStage service state >> finish service state Abandoned' Nothing
                Just style → case adaptCells (styleTextures style) light (styleAssets style) plan of
                  Left why → failed ("the plan could not be adapted: " <> Text.pack (show why))
                  Right adapted → toBuilding service state prep (plCopies planning) plan adapted held
  where
    failed why = recordFailure service why >> abandonStage service state >> finish service state Retry' (Just prep)
    steps 0 cellPrep = Right cellPrep
    steps n cellPrep = case cellPrepProgress cellPrep of
      Working → stepCells (plInputs planning) cellPrep >>= steps (n - 1 ∷ Int)
      _ → Right cellPrep
    prepHeld cellPrep = let (quads, pending) = cellPrepSize cellPrep in planHeld quads pending

-- Group the plan into regions and reserve the GPU bytes of those it must build (their CPU bytes were charged before the
-- adaptation), then submit the build (or, with nothing to build, go straight to publication).
toBuilding ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Prep → CopySet → CellPlan → Adapted → Word64 → IO ()
toBuilding service state prep copies plan adapted held = do
  let groups = regionGroups (svMaterial service) adapted
  window ← atomically (ownerRegionWindow (portOwner (svPorts service)))
  case windowRefusal (svMaterial service) window groups of
    Just refusal → do
      -- never built nor accepted: the previous publication stays, and the view sleeps until its intent, metrics or
      -- arena state change (more capacity changes nothing: the window is the renderer's)
      atomically (writeTVar (vsWindow state) (Just refusal))
      abandonStage service state >> finish service state Unchanged' (Just prep)
    Nothing → do
      atomically (writeTVar (vsWindow state) Nothing)
      buildGroups service state prep copies plan adapted held groups

-- Whether a candidate's render regions' material records fit the renderer's storage window, as a frame records them:
-- one clip entry (a drawing view's table holds at least one), then each region's record table. The terrain view's own
-- records are empty and it holds no frame table. A region that cannot fit alone is a typed refusal (the largest such);
-- otherwise a total beyond the window waits.
windowRefusal ∷ MaterialRef → Word64 → Map (Integer, Integer) ([Instance], [MaterialRecord]) → Maybe WindowRefusal
windowRefusal material window groups
  | ((key, bytes) : _) ← sortOn (Down . snd) [(key, alone records) | (key, (_, records)) ← Map.toList groups], bytes > window = Just (UnitExceedsWindow key bytes window)
  | need > window = Just (EnvelopeExceedsWindow need window)
  | otherwise = Nothing
  where
    perRecord = recordLayoutBytes (materialRecordLayout material)
    clip = fromIntegral clipEntryBytes
    alone records = clip + perRecord * fromIntegral (length records)
    need = clip + sum [perRecord * fromIntegral (length records) | (_, records) ← Map.elems groups]

buildGroups ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Prep → CopySet → CellPlan → Adapted → Word64 → Map (Integer, Integer) ([Instance], [MaterialRecord]) → IO ()
buildGroups service state prep copies plan adapted held groups = do
  existing ← readTVarIO (vsRegions state)
  let reused = Map.mapMaybe id (Map.intersectionWith (\region (instances, records) → if rgInstances region == instances && rgRecords region == records then Just region else Nothing) existing groups)
      wanted = Map.difference groups reused
      gpuNeed = sum [fromIntegral (length instances) * instanceBytes | (instances, _) ← Map.elems wanted]
  -- the GPU bytes are reserved and recorded with the stage that holds them, in one transaction
  reserved ← atomically $ do
    charged ← readTVar (svGpu service)
    if gpuNeed > tvGpuBytes (svConfig service) - min (tvGpuBytes (svConfig service)) charged
      then pure Nothing
      else do
        writeTVar (svGpu service) (charged + gpuNeed)
        let next
              | Map.null wanted = StageUploading prep (Uploading plan adapted copies reused Map.empty held)
              | otherwise = StageBuilding prep (Building plan adapted copies reused wanted gpuNeed held Nothing 0)
        Just next <$ writeTVar (vsStage state) next
  case reserved of
    Nothing → abandonStage service state >> finish service state Retry' (Just prep)
    Just next → do
      transferSeam service state "reserved"
      case next of
        StageBuilding _ building → submitBuild service state prep building
        _ → stageSeam service state next

submitBuild ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Prep → Building → IO ()
submitBuild service state prep building = do
  -- the submission and its ticket's record in the stage, in one transaction
  submitted ← atomically $ do
    uploads ← ownerUploadsSettled (portOwner (svPorts service))
    ownerBuild (portOwner (svPorts service)) [RegionBuild instances records | (instances, records) ← Map.elems (bdWanted building)] >>= \case
      Right ticket → do
        let next = building {bdTicket = Just ticket, bdUploads = uploads}
        Right next <$ writeTVar (vsStage state) (StageBuilding prep next)
      Left refusal → pure (Left refusal)
  case submitted of
    Right next → do
      transferSeam service state "submitted"
      stageSeam service state (StageBuilding prep next)
    -- a full queue: the build waits for room on the owner's queue, holding nothing but its reservation (recorded)
    Left OwnerBusy → stageSeam service state (StageBuilding prep building {bdTicket = Nothing})
    Left OwnerGone → do
      recordFailure service "a retained region could not be built: the graphics owner takes no more actions"
      abandonStage service state >> finish service state Retry' (Just prep)

stepBuilding ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Prep → Building → IO ()
stepBuilding service state prep building = case bdTicket building of
  Nothing → submitBuild service state prep building
  Just ticket → do
    -- the answer is read and what it built changes owner in the same transaction: to the uploading stage, or, for a
    -- build that stopped, to the retirements
    settled ← atomically $ ticket >>= \case
      Nothing → pure Nothing
      Just answer → Just <$> settleBuild service state prep building answer
    forM_ settled $ \after → transferSeam service state "answered" >> after

-- What a build's answer hands on, in the transaction that read it; answers what is left to do after it.
settleBuild ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Prep → Building → Answer (Either BuildFailure [ChunkRef]) → STM (IO ())
settleBuild service state prep building = \case
  Answered (Right chunks)
    | length chunks == Map.size (bdWanted building) → do
        let fresh =
              Map.fromList
                [ (key, Region chunk instances records (fromIntegral (length instances) * 64))
                | ((key, (instances, records)), chunk) ← zip (Map.toList (bdWanted building)) chunks
                ]
            next = StageUploading prep (Uploading (bdPlan building) (bdAdapted building) (bdCopies building) (bdReused building) fresh (bdCpu building))
        writeTVar (vsStage state) next
        pure (stageSeam service state next)
    | otherwise → do
        retireBuilt service state building chunks
        pure (recordFailure service "the owner built another number of regions than asked" >> finish service state Retry' (Just prep))
  Answered (Left (BuildPressure built _)) → do
    retireBuilt service state building built
    -- it waits for an upload to settle since the submission, not since now: one that settled in between wakes it
    pure (finishPressured service state (bdUploads building) prep)
  Answered (Left (BuildFailed built why)) → do
    retireBuilt service state building built
    pure (recordFailure service ("a retained region could not be built: " <> why) >> finish service state Retry' (Just prep))
  NotRun why → do
    retireBuilt service state building []
    pure (recordFailure service ("a retained region's build did not run: " <> why) >> finish service state Retry' (Just prep))

-- The chunks a build made, when it stopped before the whole set or answered another number: each retires (no barrier:
-- no revision listed it), its GPU bytes and its description's CPU still charged until its release is answered, since its
-- upload may still be running. The GPU bytes of what it did not build return; the stage ends.
retireBuilt ∷ TerrainViews k → ViewState k → Building → [ChunkRef] → STM ()
retireBuilt service state building chunks = do
  let sizes = [(fromIntegral (length instances) * instanceBytes, wantedCpu instances records) | (instances, records) ← Map.elems (bdWanted building)]
      paired = zip chunks sizes
      extra = drop (length sizes) chunks
      gpuKept = sum [g | (_, (g, _)) ← paired]
      cpuKept = sum [c | (_, (_, c)) ← paired]
  modifyTVar' (svRetiring service) (<> ([Retiring chunk g c RetireMet | (chunk, (g, c)) ← paired] <> [Retiring chunk 0 0 RetireMet | chunk ← extra]))
  modifyTVar' (svGpu service) (subtract (bdGpu building - min (bdGpu building) gpuKept))
  modifyTVar' (vsStageCharge state) (\c → c - min c cpuKept)
  moveToService service state cpuKept
  writeTVar (vsStage state) StageIdle
  modifyTVar' (svReleases service) (+ 1)

stepUploading ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Prep → Uploading → IO ()
stepUploading service state prep uploading = do
  standings ← atomically (forM (Map.elems (upFresh uploading)) (\region → (,) (rgChunk region) <$> ownerStanding (portOwner (svPorts service)) (rgChunk region)))
  let failures =
        [ why
        | (chunk, standing) ← standings
        , Just why ← [failedUpload chunk standing]
        ]
      failedUpload chunk = \case
        Just (ChunkFailed state') → Just ("a retained region's upload failed: " <> Text.pack (show chunk) <> ": " <> Text.pack (show state'))
        Nothing → Just ("a built retained region is not registered with the owner: " <> Text.pack (show chunk))
        _ → Nothing
  if
    | any ((== Just ChunkUploading) . snd) standings → pure ()
    -- each failure is kept as evidence before the candidate retires; the previous revision stays published
    | not (null failures) → mapM_ (recordFailure service) failures >> abandonStage service state >> finish service state Retry' (Just prep)
    | otherwise → publishPlan service state prep uploading

-- The region of the camera's anchor column at its clip level.
anchorRegion ∷ CameraState → RegionCoord
anchorRegion camera =
  RegionCoord (axisValue (Camera.camAnchorX camera) `div` 16) (axisValue (Camera.camAnchorY camera) `div` 16) (axisValue (Camera.camClip camera) `div` 32)

chunksOf ∷ Int → [a] → [[a]]
chunksOf _ [] = []
chunksOf n xs = let (a, b) = splitAt n xs in a : chunksOf n b

regionsOf ∷ Demand → [RegionCoord]
regionsOf (Demand chunks) = [RegionCoord cx cy (fromInteger level) | ChunkDemand (ChunkKey cx cy) _ levels ← chunks, level ← levels]

-- The view's camera interests: its visible regions before its prefetch, latest value only. More regions than the
-- service's camera share takes are asked again with the visible ones alone. The latest demand is kept: a busy refusal
-- (the terrain service's own banks, or the shared account another consumer fills) is sent again once something is
-- released ('resendDemand'), so it loses nothing. The copies the view plans from do not depend on residency, so a
-- refused demand delays nothing it draws.
setDemand ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → [RegionCoord] → [RegionCoord] → IO ()
setDemand service state visible prefetch = do
  atomically (writeTVar (vsDemand state) (Just (visible, prefetch)))
  sendDemand service state

sendDemand ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → IO ()
sendDemand service state =
  readTVarIO (vsDemand state) >>= \case
    Nothing → pure ()
    Just (visible, prefetch) → do
      mark ← atomically (retryMark service state)
      -- One camera description holds at most the service's camera regions: visible regions first, in the plan's order,
      -- then prefetch, never one dropped for the description's size and never the whole demand dropped.
      let cap = fromIntegral (limitCameraRegions (Runtime.configLimits (Runtime.inspectConfig (portTerrain (svPorts service)))))
          regions = take cap (nubOrd (visible <> prefetch))
      busy ← case traverse demandOf regions of
        Left why → recordFailure service ("the camera demand could not be described: " <> Text.pack (show why)) >> pure False
        Right demands →
          Runtime.setViewDemand (portTerrain (svPorts service)) (vsRuntimeView state) (vsArena state) demands >>= \case
            Left (Runtime.RefusedBusy _) → pure True
            Left refusal → recordFailure service ("the camera demand was refused: " <> Text.pack (show refusal)) >> pure False
            Right _ → pure False
      atomically (writeTVar (vsDemandBusy state) (if busy then Just mark else Nothing))
  where
    demandOf region = RegionDemand region <$> coverageBox 0 16 0 16 0 32

-- Send the kept demand again after a busy refusal.
resendDemand ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → IO ()
resendDemand = sendDemand

-- The view's setup for these metrics: the whole framebuffer.
setupFor ∷ TargetMetrics → ViewSetup
setupFor metrics =
  let PixelExtent width height = metricsFramebuffer metrics
   in ViewSetup metrics (Viewport (V2 0 0) (V2 (fromIntegral width) (fromIntegral height))) defaultViewSettings

-- Give the camera the new facts: a followed surface they supply is adopted, and a pending jump they allow lands. Only
-- if the intent did not change meanwhile; otherwise the newer intent is prepared next.
settleCamera ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → TerrainFacts → Word64 → IO CameraState
settleCamera service state facts charge = atomically $ do
  -- the facts are kept beyond the stage, so their charge moves from the stage's to theirs, replacing the facts before
  writeTVar (vsFacts state) (Just facts)
  modifyTVar' (vsStageCharge state) (\c → c - min c charge)
  writeTVar (vsFactsCharge state) charge
  camera ← readTVar (vsCamera state)
  let config = tvCameraConfig (svConfig service)
      stepped = either (const Nothing) Just (refollow config facts camera)
      followed = maybe camera stepCamera stepped
      -- a followed surface the facts do not hold yet: its regions are copied in the next round, as a jump's are
      followNeed = case stepFollow <$> stepped of
        Just (FollowUnavailable demand) → regionsOf demand
        _ → []
  landed ← case camPending followed of
    Nothing → followed <$ writeTVar (vsExtraDemand state) followNeed
    Just pending → case completeJump config facts (Camera.pendingId pending) followed of
      Right result → do
        case stepJump result of
          JumpApplied (JumpId number) → do
            jumps ← readTVar (vsJumps state)
            for_ (Map.lookup number jumps) $ \box → writeTVar box (Just (SettledOk JumpLanded))
            modifyTVar' (vsJumps state) (Map.delete number)
            writeTVar (vsExtraDemand state) followNeed
          JumpPending _ demand → writeTVar (vsExtraDemand state) (regionsOf demand <> followNeed)
          _ → pure ()
        pure (stepCamera result)
      Left _ → followed <$ modifyTVar' (vsExtraDemand state) (nub . (<> followNeed))
  when (camRevision landed /= camRevision camera) (writeTVar (vsCamera state) landed)
  pure landed

-- ---------------------------------------------------------------------------
-- Retained regions and publication

-- The plan's quads in render regions: 16 x 16 cells of the rotated view frame, each with the distinct records its
-- quads use (parameters renumbered into them) and its instances in plan order.
regionGroups ∷ MaterialRef → Adapted → Map (Integer, Integer) ([Instance], [MaterialRecord])
regionGroups material adapted =
  Map.map build (Map.fromListWith (flip (<>)) [(regionKey (adaptedQuad quad), [quad]) | quad ← adaptedQuads adapted])
  where
    table = Map.fromList (zip [0 ..] (adaptedRecords adapted))
    regionKey quad = let CellKey _ _ vx vy _ = quadKey quad in (vx `div` 16, vy `div` 16)
    build quads =
      let used = nub [adaptedParameter quad | quad ← quads]
          renumber = Map.fromList (zip used [0 ..])
          records = mapMaybe (`Map.lookup` table) used
          instances = [adaptedInstance material adapted quad {adaptedParameter = Map.findWithDefault 0 (adaptedParameter quad) renumber} | quad ← quads]
       in (instances, records)

-- Publish the whole revision, then retire what it no longer lists.
publishPlan ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Prep → Uploading → IO ()
publishPlan service state prep uploading = do
  let ports = svPorts service
      material = svMaterial service
      plan = upPlan uploading
      adapted = upAdapted uploading
      copies = upCopies uploading
      metrics = prpMetrics prep
      regions = Map.union (upReused uploading) (upFresh uploading)
      chunks = map rgChunk (Map.elems regions)
  revision ← atomically (readTVar (vsNextRevision state) <* modifyTVar' (vsNextRevision state) (+ 1))
  case terrainView plan adapted [(material, MaterialData [] (adaptedPush adapted))] [WorldLayerWith DepthEnabled chunks []] of
    Left why → do
      recordFailure service ("the view could not be made: " <> Text.pack (show why))
      abandonStage service state >> finish service state Retry' (Just prep)
    Right view → do
      let world =
            SceneWorld
              { worldTag = WorldTag (vsId state) revision
              , worldClear = tvClear (svConfig service)
              , worldView = view
              , worldMetrics = metrics
              , worldChunks = Set.fromList chunks
              , worldTextures = vsStyleIds state
              }
      scene ← prepare (worldGraphicsScene world)
      committed ← atomically $ do
        closing ← readTVar (vsClosing state)
        open ← readTVar (svOpen service)
        taking ← portTaking ports
        claim ← claimOf (portClaims ports) (vtKey (vsTarget state))
        usable ← vtUsable (vsTarget state)
        -- Every identity the plan was made from is revalidated here, with the publication: a newer intent (camera,
        -- presentation, jump), other metrics, or a content or knowledge revision the arena has since committed make this
        -- plan obsolete. It is discarded, never relabelled current; the newer state is prepared next.
        current ← readTVar (vsIntent state)
        nowMetrics ← vtMetrics (vsTarget state)
        status ← Runtime.arenaStatusSTM (portTerrain ports) (vsArena state)
        residency ← residencyNow service state
        existing ← readTVar (vsRegions state)
        let mine = fmap claimView claim == Just (vsId state)
            coherent =
              current == prpIntent prep
                && nowMetrics == Just metrics
                && either (const False) (\s → Runtime.statusContentRevision s == copyContent copies && Runtime.statusKnowledgeRevision s == copyKnowledge copies) status
                -- residency is part of the plan's identity: a load, eviction or removal since the copies were labelled
                -- makes the plan stale, and it is made again from fresh copies (content-checked reuse then rebuilds no
                -- region whose bytes did not change)
                && residency == Just (copyGeneration copies)
        if closing || not open || not taking || not mine || not usable || not coherent
          then pure False
          else do
            accepted ← vtPublish (vsTarget state) scene
            when accepted $ do
              _ ← markClaimPublished (portClaims ports) (vtKey (vsTarget state)) (vsId state)
              writeTVar (vsPublished state) (Just revision)
              writeTVar (vsPublishedFor state) (Just (prpIntent prep, prpIdentity prep, metrics))
              -- the candidate's CPU charge becomes the pin's, and the stage holds nothing more
              modifyTVar' (vsPins state) (Map.insert revision (Pinned plan metrics (copyArena copies) (copyContent copies) (copyKnowledge copies) (copyGeneration copies) (upCpu uploading)))
              -- the stage's charge ends: the pin holds the plan, the listed regions their descriptions
              writeTVar (vsStageCharge state) 0
              writeTVar (vsStage state) StageIdle
              writeTVar (vsRegions state) regions
              -- What the new revision no longer lists starts its retirement; the host's barrier and the adoptions still
              -- protect it wherever an earlier revision may be drawn.
              let superseded' = Map.difference existing (upReused uploading)
              modifyTVar' (svRetiring service) (<> [Retiring (rgChunk r) (rgBytes r) (regionCpu r) RetireUnasked | r ← Map.elems superseded'])
              -- the superseded regions' CPU descriptions move from the view's charge to the service's, and the view's
              -- charge is now its pins and its listed regions
              moveToService service state (sum (map regionCpu (Map.elems superseded')))
              void (recharge service state)
            pure accepted
      if committed
        then do
          finish service state (Published' revision) (Just prep)
          -- a partial plan goes on while each preparation admits more; one that could admit no more sleeps until
          -- something it waits on changes (a release, an adoption, the account)
          atomically $ do
            unadmitted ← readTVar (vsUnadmitted state)
            previous ← readTVar (vsAdmittedCount state)
            readTVar (vsVisibleAdmitted state) >>= writeTVar (vsAdmitted state)
            let admitted = Set.size (prpRegions prep)
                capped = admitted >= tvAdmitRegions (svConfig service)
            writeTVar (vsAdmittedCount state) admitted
            -- at the cap only a new intent, metrics or arena state changes what is admitted: nothing more to do
            when (unadmitted > 0 && not capped) $
              if admitted > previous
                then writeTVar (vsContinue state) True
                else retryMark service state >>= writeTVar (vsRetry state) . Just
        else abandonStage service state >> finish service state Abandoned' (Just prep)

-- The view's need of the account, covered: its pinned revisions and what its stage holds (taken copies, the candidate).
-- 'False' when the account cannot cover an increase (nothing then changes).
recharge ∷ TerrainViews k → ViewState k → STM Bool
recharge service state = viewNeed state >>= coverNeed service state

-- Everything the view keeps: its pinned plans, its listed regions' descriptions, its stage, its facts and its demand.
viewNeed ∷ ViewState k → STM Word64
viewNeed state = do
  pinned ← pinnedNeed state
  listed ← sum . map regionCpu . Map.elems <$> readTVar (vsRegions state)
  staged ← readTVar (vsStageCharge state)
  facts ← readTVar (vsFactsCharge state)
  demand ← demandNeed state
  pure (pinned + listed + staged + facts + demand)

-- The free room the account must have for the view to cover its need as it stands now: the whole granules beyond what it
-- holds.
roomNeeded ∷ TerrainViews k → ViewState k → STM Word64
roomNeeded service state = do
  need ← viewNeed state
  held ← readTVar (vsAccountHeld state)
  let granule = max 1 (tvAccountGranule (svConfig service))
  pure (if need > held then ((need - held + granule - 1) `div` granule) * granule else 0)

-- What the account has free now.
accountRoom ∷ RenderAccount → STM Word64
accountRoom account = (\charged → accountLimit account - min (accountLimit account) charged) <$> accountCharged account

-- What the view's kept demand holds: its latest camera demand and a pending jump's or followed surface's regions, each
-- coordinate at most 'demandBytes'.
demandNeed ∷ ViewState k → STM Word64
demandNeed state = do
  kept ← maybe 0 (\(visible, prefetch) → length visible + length prefetch) <$> readTVar (vsDemand state)
  extra ← length <$> readTVar (vsExtraDemand state)
  pure (demandBytes * fromIntegral (kept + extra))

-- Move bytes the view holds in the account to the service's charge for retiring regions: a transfer of what is already
-- reserved, never a new reservation, so it cannot be refused.
moveToService ∷ TerrainViews k → ViewState k → Word64 → STM ()
moveToService service state bytes = do
  held ← readTVar (vsAccountHeld state)
  let moved = min held bytes
  writeTVar (vsAccountHeld state) (held - moved)
  modifyTVar' (svRetiringCpu service) (+ moved)

-- Return bytes the service held for retiring regions to the account.
returnFromService ∷ TerrainViews k → Word64 → STM ()
returnFromService service bytes = do
  held ← readTVar (svRetiringCpu service)
  let returned = min held bytes
  when (returned > 0) $ do
    accountRelease (portAccount (svPorts service)) returned
    writeTVar (svRetiringCpu service) (held - returned)

-- The CPU bytes a retained region's description holds: its instances and records here, and the renderer registry's copy
-- of its instances, for as long as the chunk is listed or retiring.
regionCpu ∷ Region → Word64
regionCpu r = wantedCpu (rgInstances r) (rgRecords r)

wantedCpu ∷ [Instance] → [MaterialRecord] → Word64
wantedCpu instances records = 2 * instanceBytes * fromIntegral (length instances) + recordBytes * fromIntegral (length records)

-- What the account is charged for each piece, conservatively: a planned quad and its key, a pending span, a copied
-- region's facts and knowledge as the inputs hold them (the copy's own per-region record), an adapted quad, an encoded
-- instance and a material record.
quadBytes, pendingBytes, inputsPerRegion, adaptedPerQuad, instanceBytes, recordBytes, demandBytes ∷ Word64
quadBytes = 384
pendingBytes = 64
inputsPerRegion = 25872
adaptedPerQuad = 128
instanceBytes = 64
recordBytes = 128
demandBytes = 32

-- What a plan holds: its quads and its pending spans (and a fixed amount for its identity and preparation metadata).
planHeld ∷ Int → Int → Word64
planHeld quads pending = 4096 + quadBytes * fromIntegral quads + pendingBytes * fromIntegral pending

-- What a plan's own demand holds for as long as the plan is kept (its pin's lifetime): each chunk's entry and each of
-- its intervals and regions, visible and prefetch, at the kept demand's figure. The view's latest kept demand is charged
-- apart ('demandNeed'), so an older pinned plan's demand is never covered by a newer one's.
planDemandHeld ∷ CellDemand → Word64
planDemandHeld demand =
  sum
    [ demandBytes * fromIntegral (2 + length (demandIntervals chunk) + length (demandRegions chunk))
    | chunk ← demandChunks (cdVisible demand) <> demandChunks (cdPrefetch demand)
    ]


-- | Cover the view's CPU need with whole granules of the session's account: on the way up, reserve the granules the need
-- passes into, all or none ('False' changes nothing); on the way down, return only granules wholly free of the need. A
-- need that moves within a granule leaves the account untouched, so a panning camera does not write the account (which
-- the terrain service reads in its own transactions) at every publication.
coverNeed ∷ TerrainViews k → ViewState k → Word64 → STM Bool
coverNeed service state need = do
  held ← readTVar (vsAccountHeld state)
  let granule = max 1 (tvAccountGranule (svConfig service))
      account = portAccount (svPorts service)
  if need > held
    then do
      let more = ((need - held + granule - 1) `div` granule) * granule
      ok ← accountReserve account more
      when ok (writeTVar (vsAccountHeld state) (held + more))
      pure ok
    else do
      let free = ((held - need) `div` granule) * granule
      when (free > 0) $ do
        accountRelease account free
        writeTVar (vsAccountHeld state) (held - free)
        modifyTVar' (svReleases service) (+ 1)
      pure True

-- What the view's pinned revisions need of the account.
pinnedNeed ∷ ViewState k → STM Word64
pinnedNeed state = sum . map pinBytes . Map.elems <$> readTVar (vsPins state)

-- Unpin every plan that is neither the newest published nor the newest adopted, returning its CPU bytes.
dropUnneededPinsSTM ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → STM ()
dropUnneededPinsSTM service state = do
  published ← readTVar (vsPublished state)
  adopted ← fmap (tagRevision . snd) <$> adoptedRevision service state
  pins ← readTVar (vsPins state)
  readers ← readTVar (vsReaders state)
  let keep revision = Just revision == published || Just revision == adopted || maybe False (revision >) adopted || Map.findWithDefault 0 revision readers > 0
      (kept, dropped) = Map.partitionWithKey (\revision _ → keep revision) pins
      bytes = sum (map pinBytes (Map.elems dropped))
  unless (Map.null dropped) $ do
    writeTVar (vsPins state) kept
    void (recharge service state)
    when (bytes > 0) (modifyTVar' (svReleases service) (+ 1))

-- ---------------------------------------------------------------------------
-- Picking

-- | Pick at a logical point of the view's target. Never waits and never loads terrain: it reads the revision the host
-- adopted and the plan pinned for it. No adopted revision, a plan made for other metrics than the target's now, or
-- information that could lie ahead is 'PickLoading'; zero or absent metrics, a point outside, air, gaps and fog are
-- 'PickNoHit'; a visible known part is 'PickHit' with its consistency reference.
-- The pin of the revision the host adopted for the view's target, the one picks read: 'Nothing' before an adoption of the
-- view's own revision.
adoptedPin ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → STM (Maybe (Word64, Pinned))
adoptedPin service state =
  adoptedRevision service state >>= \case
    Nothing → pure Nothing
    Just (_, tag) → fmap (tagRevision tag,) . Map.lookup (tagRevision tag) <$> readTVar (vsPins state)

-- | Read the plan of the revision the host adopted for the view's target, the one picks read ('Nothing' before an
-- adoption of the view's own revision), for as long as the body runs: the revision is read under a reader, so its pin
-- is kept, stays charged and counts against the view's pin limit until the body returns. The plan is for the body; one
-- kept after it is not accounted.
withAdoptedPlan ∷ (Ord k, Show k) ⇒ TerrainView k → (Maybe CellPlan → IO a) → IO a
withAdoptedPlan (TerrainView service state) body = bracket acquire release (body . fmap (pinPlan . snd))
  where
    acquire = atomically $ do
      found ← adoptedPin service state
      forM_ found $ \(revision, _) → modifyTVar' (vsReaders state) (Map.insertWith (+) revision 1)
      pure found
    release = \case
      Nothing → pure ()
      Just (revision, _) → atomically $ do
        modifyTVar' (vsReaders state) (Map.update (\n → if n > 1 then Just (n - 1) else Nothing) revision)
        modifyTVar' (svReleases service) (+ 1)

pickView ∷ (Ord k, Show k) ⇒ TerrainView k → (Double, Double) → STM (PickResult k)
pickView (TerrainView service state) (px, py) = do
  closing ← readTVar (vsClosing state)
  metrics ← vtMetrics (vsTarget state)
  case metrics of
    _ | closing → pure PickNoHit
    Nothing → pure PickNoHit
    Just m
      | let PixelExtent w h = metricsFramebuffer m in w == 0 || h == 0 → pure PickNoHit
      -- a point outside the target's logical extent is no hit, whatever is adopted (or not yet) and for which metrics
      | let PixelExtent w h = metricsLogical m in px < 0 || py < 0 || px >= fromIntegral w || py >= fromIntegral h → pure PickNoHit
      | otherwise →
          adoptedRevision service state >>= \case
            Nothing → pure PickLoading
            Just (revision, tag) → do
              pins ← readTVar (vsPins state)
              case Map.lookup (tagRevision tag) pins of
                Nothing → pure PickLoading
                Just pinned
                  | pinMetrics pinned /= m → pure PickLoading
                  | otherwise → pure $ case pickCells (pinPlan pinned) (CellPickQuery (cellPlanIdentity (pinPlan pinned)) (V2 (realToFrac px) (realToFrac py))) of
                      Left _ → PickNoHit
                      Right CellPickNoHit → PickNoHit
                      Right CellPickLoading → PickLoading
                      Right (CellPickHit hit) →
                        PickHit
                          ( PickRef
                              (hitCell hit)
                              (hitPart hit)
                              PickIdentity
                                { identityTarget = vtKey (vsTarget state)
                                , identityViewId = vsId state
                                , identityRevision = fromIntegral revision
                                , identityTag = tag
                                , identityArena = pinArena pinned
                                , identityContent = pinContent pinned
                                , identityKnowledge = pinKnowledge pinned
                                , identityResidency = pinResidency pinned
                                }
                          )

-- | The removal precondition of a pick: the arena incarnation and the content and knowledge revisions it was picked
-- from, with a guard that the view still holds its target and that the revision it was picked from is still the one
-- the host adopted. The terrain service reads the guard in its removal arbitration, atomically with the commit.
-- The arena's current residency generation, through the view's lease ('Nothing' once the lease is gone).
residencyNow ∷ TerrainViews k → ViewState k → STM (Maybe Word64)
residencyNow service state = fmap (fromIntegral . Runtime.viewGeneration) <$> Runtime.inspectArenaSTM (portTerrain (svPorts service)) (vsArena state)

pickPrecondition ∷ (Ord k, Show k) ⇒ TerrainView k → PickRef k → Runtime.Precondition
pickPrecondition (TerrainView service state) ref =
  Runtime.PreconditionWith
    { Runtime.preconditionArena = pickArena identity
    , Runtime.preconditionContent = pickContent identity
    , Runtime.preconditionKnowledge = Just (pickKnowledge identity)
    , Runtime.preconditionGuard = Just (Runtime.PreconditionGuard guardId guard)
    }
  where
    identity = pickRefIdentity ref
    guardId = vsId state * 4294967296 + pickRevision identity
    guard = do
      closing ← readTVar (vsClosing state)
      claim ← claimOf (portClaims (svPorts service)) (pickTarget identity)
      adopted ← adoptedRevision service state
      residency ← residencyNow service state
      -- the target is still usable and draws at the metrics the picked plan was made for: a resize, a content-scale
      -- change or a revoked target makes the reference stale while the same revision stays adopted
      usable ← vtUsable (vsTarget state)
      metrics ← vtMetrics (vsTarget state)
      picked ← fmap pinMetrics . Map.lookup (tagRevision (pickTag identity)) <$> readTVar (vsPins state)
      pure
        ( not closing
            && fmap claimView claim == Just (vsId state)
            && fmap (\(revision, tag) → (fromIntegral revision, tag)) adopted == Just (pickRevision identity, pickTag identity)
            && residency == Just (pickResidency identity)
            && usable
            && isJust metrics
            && picked == metrics
        )
