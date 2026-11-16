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

    -- * Picking
  , pickView
  , pickPrecondition
  ) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM
import Control.Exception (SomeAsyncException, SomeException, displayException, finally, fromException, mask, mask_, onException, throwIO, try)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Foldable (for_)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare)
import Hetoimasia.LuaEngine.Graphics.Scene.Claims (Claim (..), SceneClaims, claimOf, markClaimPublished, releaseClaim, takeClaim)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene, SceneLedger, ledgerChunkHeld, ledgerDropInterest, ledgerNewestAdopted, ledgerRetainInterest, worldGraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Scene.World (SceneWorld (..), WorldTag (..))
import Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs (CopySet, combineCopies, copyArena, copyContent, copyKnowledge, planInputs)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Style
import Hetoimasia.LuaEngine.Graphics.TerrainView.Types
import Hetoimasia.LuaEngine.Graphics.TerrainView.Owner (BuildFailure (..), RegionBuild (..), ViewOwner (..))
import Hetoimasia.LuaEngine.Texture (RenderAccount, accountCharged, accountLimit, accountRelease, accountReserve)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Chunk (ChunkRef)
import Hetoimasia.Render.TwoD.Material (MaterialData (..), MaterialRecord, MaterialRef)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot (Instance, Layer (WorldLayerWith), LayerDepth (DepthEnabled), Viewport (..))
import Hetoimasia.Render.TwoD.Vulkan.Chunks (ChunkStanding (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), axisValue)
import Hetoimasia.Terrain.Render2D.Camera
  ( CameraState
  , Command (Jump)
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
  , CellRequest (..)
  , Progress (..)
  , cellPlanDemand
  , cellPlanIdentity
  , cellPlanOf
  , cellPlanPending
  , cellPrepProgress
  , quadKey
  , startCells
  , stepCells
  )
import Hetoimasia.Terrain.Render2D.Facts (ChunkDemand (..), ChunkKey (..), Demand (..), TerrainFacts (..))
import Hetoimasia.Terrain.Render2D.Material (Adapted (..), AdaptedQuad (..), adaptCells, adaptedInstance, terrainView)
import Hetoimasia.Terrain.Render2D.Presentation (LightInput (..), LightSettings, describeSettingRefusal, lightInput, mkLightSettings)
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..))
import Hetoimasia.Terrain.Residency (ArenaId, RegionDemand (..), Revision, coverageBox)
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
  }

data Request k
  = RequestAttach !(AttachRequest k) !AcquiredStyle !(TVar (Maybe (Settled (TerrainView k))))

-- | A chunk on its way out: its reference, its GPU bytes, and whether its barrier has been met.
data Retiring = Retiring
  { rtChunk ∷ !ChunkRef
  , rtBytes ∷ !Word64
  , rtBarrier ∷ !Barrier
  }

-- | Where a retiring chunk stands against the host's release barrier.
data Barrier
  = -- | Not asked yet (or the lane was full when it was).
    BarrierUnasked
  | -- | Asked: the reading answers once it is met or will never be.
    BarrierWaiting !(STM (Maybe Bool))
  | -- | Met: the chunk is released once no adoption lists it.
    BarrierMet

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
  , vsStyle ∷ !AcquiredStyle
  , vsArena ∷ !Runtime.ArenaLease
  , vsRuntimeView ∷ !Runtime.View
  , vsCamera ∷ !(TVar CameraState)
  , vsLight ∷ !(TVar LightSettings)
  , vsIntent ∷ !(TVar Word64)
    -- ^ Bumped by every accepted intent update.
  , vsPrepared ∷ !(TVar (Word64, Maybe (Revision, Revision), Maybe TargetMetrics))
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
  , vsRetry ∷ !(TVar (Maybe (Word64, Maybe Natural, Word64)))
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
  , vsDemandBusy ∷ !(TVar (Maybe (Word64, Maybe Natural, Word64)))
    -- ^ The latest demand was refused busy: the retry mark when it was. It is sent again when the mark moves.
  }

-- | A published plan kept for picking, with its identity and its CPU charge.
data Pinned = Pinned
  { pinPlan ∷ !CellPlan
  , pinMetrics ∷ !TargetMetrics
  , pinArena ∷ !ArenaId
  , pinContent ∷ !Revision
  , pinKnowledge ∷ !Revision
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
  done ← newEmptyMVar
  mask $ \restore → do
    _ ← forkIOWithUnmask $ \unmask →
      (unmask (worker service) >>= \case
        Left failure → recordFailure service ("the worker failed: " <> Text.pack (displayException failure))
        Right () → pure ())
        `finally` (workerEnded service >> putMVar done ())
    restore (body service) `finally` do
      atomically (writeTVar (svOpen service) False)
      tvStopping config
      readMVar done
      -- A worker that was cancelled did not run the service's end: run it here, so every view is still closed.
      ended ← readTVarIO (svShutDown service)
      unless ended (shutdown service)

-- The worker is gone, by its end or a cancellation: no attachment is taken any more, and every one still queued settles
-- stopped, releasing the parents it holds.
workerEnded ∷ (Ord k, Show k) ⇒ TerrainViews k → IO ()
workerEnded service = do
  queued ← atomically $ do
    writeTVar (svOpen service) False
    readTVar (svRequests service) <* writeTVar (svRequests service) []
  settleQueued queued

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

recordFailure ∷ (Ord k, Show k) ⇒ TerrainViews k → Text → IO ()
recordFailure service why = atomically (modifyTVar' (svFailures service) (take 64 . (why :)))

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
cancelAttach service (PendingAttach box) = do
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

-- The worker's attachment: every check before the claim, then one transaction that claims and takes the interests.
runAttach ∷ (Ord k, Show k) ⇒ TerrainViews k → AttachRequest k → AcquiredStyle → TVar (Maybe (Settled (TerrainView k))) → IO ()
runAttach service request style box = do
  outcome ← trySync (attachSteps service request style box) `onException` (releaseStyle style >> settle (SettledRefused AttachStopped))
  case outcome of
    Left (failure ∷ SomeException) → do
      recordFailure service ("an attachment failed: " <> Text.pack (displayException failure))
      releaseStyle style
      settle (SettledRefused AttachStopped)
    Right (Left refusal) → releaseStyle style >> settle (SettledRefused refusal)
    Right (Right ()) → pure ()
  where
    settle value = atomically (readTVar box >>= \case Nothing → writeTVar box (Just value); Just _ → pure ())

attachSteps ∷ (Ord k, Show k) ⇒ TerrainViews k → AttachRequest k → AcquiredStyle → TVar (Maybe (Settled (TerrainView k))) → IO (Either AttachRefusal ())
attachSteps service request style box = do
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
              case status of
                Left why → pure (Left (AttachArena (Text.pack (show why))))
                Right _ →
                  Runtime.openView (portTerrain ports) (portClient ports) >>= \case
                    Left why → pure (Left (AttachBusy (Text.pack (show why))))
                    Right runtimeView → commitAttach service request box style runtimeView camera light

-- The attachment's commit: the authority, the target, the parents' registrations and the claim are read, and the claim
-- and both GPU interests are taken, in one transaction. A cancellation that won before it, or any failed check, takes
-- nothing and rolls back the CPU interests and the runtime view.
commitAttach ∷ (Ord k, Show k) ⇒ TerrainViews k → AttachRequest k → TVar (Maybe (Settled (TerrainView k))) → AcquiredStyle → Runtime.View → CameraState → LightSettings → IO (Either AttachRefusal ())
commitAttach service request box style runtimeView camera light = do
  let ports = svPorts service
      target = attachTarget request
  state ← newViewState service request style runtimeView camera light
  outcome ← atomically $ do
    cancelled ← isJust <$> readTVar box
    open ← readTVar (svOpen service)
    taking ← portTaking ports
    usable ← vtUsable target
    claim ← claimOf (portClaims ports) (vtKey target)
    released ← or <$> traverse (portReleased ports) [styleColourHandle style, styleNormalHandle style]
    count ← Map.size <$> readTVar (svViews service)
    if
      | cancelled → pure (Left Nothing)
      | not (open && taking) → pure (Left (Just AttachStopped))
      | count >= tvMaxViews (svConfig service) → pure (Left (Just AttachTooManyViews))
      | not usable → pure (Left (Just AttachTargetUnusable))
      | isJust claim → pure (Left (Just AttachTargetClaimed))
      | released → pure (Left (Just AttachParentReleased))
      | otherwise → do
          _ ← takeClaim (portClaims ports) (vtKey target) (vsId state)
          forM_ (Set.toList (styleIdentities style)) (ledgerRetainInterest (portLedger ports))
          modifyTVar' (svViews service) (Map.insert (vsId state) state)
          writeTVar box (Just (SettledOk (TerrainView service state)))
          pure (Right ())
  case outcome of
    Right () → pure (Right ())
    Left refusal → do
      Runtime.closeView (portTerrain ports) runtimeView
      -- a cancellation that won is answered as a refusal here, so the caller releases the parents; the box stays as
      -- the cancellation settled it
      pure (Left (fromMaybe AttachStopped refusal))

newViewState ∷ (Ord k, Show k) ⇒ TerrainViews k → AttachRequest k → AcquiredStyle → Runtime.View → CameraState → LightSettings → IO (ViewState k)
newViewState service request style runtimeView camera light = do
  identity ← atomically $ do
    next ← readTVar (svNext service)
    writeTVar (svNext service) (next + 1)
    pure next
  ViewState identity (attachTarget request) style (attachArena request) runtimeView
    <$> newTVarIO camera
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
      case facts of
       Nothing → pure (Left IntentBusy)
       Just _ → case foldl' (step facts) (Right camera) commands of
        Left why → pure (Left (IntentInvalid why))
        Right moved → do
          writeTVar (vsCamera state) moved
          modifyTVar' (vsIntent state) (+ 1)
          pure (Right ())
  where
    config = tvCameraConfig (svConfig service)
    step _ (Left why) _ = Left why
    step facts (Right camera) command = case command of
      Jump _ → Left "a jump is asked for with jumpView"
      _ → case maybe (Left Camera.InvalidConfig) (\f → applyCommand config f command camera) facts of
        Left why → Left (Text.pack (show why))
        Right result → Right (stepCamera result)

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

-- | Cancel a pending jump: it settles cancelled and the camera stays.
cancelJumpView ∷ (Ord k, Show k) ⇒ TerrainView k → PendingJump → STM Bool
cancelJumpView (TerrainView _ state) (PendingJump number box) =
  readTVar box >>= \case
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
  waiting ← isJust <$> readTVar (vsRetry state)
  held ← readTVar (vsAccountHeld state)
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
      }

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

-- | Whether the view has closed.
viewClosed ∷ (Ord k, Show k) ⇒ TerrainView k → STM Bool
viewClosed (TerrainView _ state) = readTVar (vsClosed state)

-- The worker's close of one view.
runClose ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → IO ()
runClose service state = do
  let ports = svPorts service
      target = vsTarget state
  void (Runtime.clearViewDemand (portTerrain ports) (vsRuntimeView state))
  Runtime.closeView (portTerrain ports) (vsRuntimeView state)
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
    forM_ (Set.toList (styleIdentities (vsStyle state))) (ledgerDropInterest (portLedger ports))
    regions ← readTVar (vsRegions state)
    writeTVar (vsRegions state) Map.empty
    modifyTVar' (svRetiring service) (<> [Retiring (rgChunk region) (rgBytes region) BarrierUnasked | region ← Map.elems regions])
    writeTVar (vsPins state) Map.empty
    held ← readTVar (vsAccountHeld state)
    when (held > 0) (accountRelease (portAccount ports) held)
    writeTVar (vsAccountHeld state) 0
    modifyTVar' (svReleases service) (+ 1)
    modifyTVar' (svViews service) (Map.delete (vsId state))
    writeTVar (vsPhase state) PhaseClosed
  releaseStyle (vsStyle state)
  atomically (writeTVar (vsClosed state) True)

-- ---------------------------------------------------------------------------
-- The worker

data Work k
  = WorkStop
  | WorkAttach !(AttachRequest k) !AcquiredStyle !(TVar (Maybe (Settled (TerrainView k))))
  | WorkClose !(ViewState k)
  | WorkRetire
  | WorkPrepare !(ViewState k)
  | WorkDemand !(ViewState k)

worker ∷ (Ord k, Show k) ⇒ TerrainViews k → IO (Either SomeException ())
worker service = trySync loop
  where
    loop =
      atomically (nextWork service) >>= \case
        WorkStop → shutdown service
        WorkAttach request style box → runAttach service request style box >> loop
        WorkClose state → guarded (runClose service state) >> loop
        WorkRetire → guarded (retireStep service >>= \progressed → unless progressed (abandonRetirements service)) >> loop
        WorkPrepare state → guarded (prepareView service state) >> loop
        WorkDemand state → guarded (resendDemand service state) >> loop
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
    closes = do
      views ← Map.elems <$> readTVar (svViews service)
      closing ← filterM' (\state → readTVar (vsClosing state)) views
      case closing of
        state : _ → pure (WorkClose state)
        [] → retry
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
      dirty ← filterM' (viewDirty service) ordered
      case dirty of
        state : _ → writeTVar (svCursor service) (vsId state) >> pure (WorkPrepare state)
        [] → retry

filterM' ∷ (a → STM Bool) → [a] → STM [a]
filterM' predicate = foldr (\x rest → predicate x >>= \keep → (if keep then (x :) else id) <$> rest) (pure [])

-- Whether a view has work: a new intent, a new arena revision, new metrics, or pressure released since it stopped.
viewDirty ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → STM Bool
viewDirty service state = do
  intent ← readTVar (vsIntent state)
  (prepared, revisions, metrics) ← readTVar (vsPrepared state)
  status ← Runtime.arenaStatusSTM (portTerrain (svPorts service)) (vsArena state)
  now ← vtMetrics (vsTarget state)
  retryAt ← readTVar (vsRetry state)
  mark ← retryMark service state
  let current = either (const Nothing) (\s → Just (Runtime.statusContentRevision s, Runtime.statusKnowledgeRevision s)) status
  pure (intent /= prepared || current /= revisions || now /= metrics || maybe False (/= mark) retryAt)

-- What a waiting preparation watches: the service's releases, the target's newest adoption and the shared account's
-- charge (moved by any of its consumers: coverage, view payloads or the terrain service's own staging).
retryMark ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → STM (Word64, Maybe Natural, Word64)
retryMark service state = do
  releases ← readTVar (svReleases service)
  newest ← ledgerNewestAdopted (portLedger (svPorts service)) (vtKey (vsTarget state))
  charged ← accountCharged (portAccount (svPorts service))
  pure (releases, fst <$> newest, charged)

-- The graphics owner takes no more actions, so the retirements left cannot be proved: they are kept as terminal
-- evidence, and their GPU bytes stay charged.
abandonRetirements ∷ (Ord k, Show k) ⇒ TerrainViews k → IO ()
abandonRetirements service = do
  left ← atomically (readTVar (svRetiring service) <* writeTVar (svRetiring service) [])
  unless (null left) $ recordFailure service ("retirement could not be proved for " <> Text.pack (show (length left)) <> " retained regions: the graphics owner takes no more actions")

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
  drain
  atomically (writeTVar (svShutDown service) True)
  where
    drain = do
      remaining ← null <$> readTVarIO (svRetiring service)
      unless remaining $ do
        progressed ← atomically ((True <$ (retirable service >>= check)) `orElse` pure False)
        if progressed
          then retireStep service >>= \case
            True → drain
            False → abandonRetirements service
          else do
            -- Wait for the ledger to let a retiring chunk go (an adopted revision's last use), or for the graphics owner
            -- to end: then no adoption it still records will ever be released to us, and what is left is kept as
            -- terminal evidence. So the scope's exit ends in either order of the host's end and the views'.
            moved ← atomically ((True <$ (retirable service >>= check)) `orElse` (False <$ ownerEnd (portOwner (svPorts service))))
            if moved then drain else abandonRetirements service

-- Whether some retiring chunk can move: its barrier not yet asked for, its barrier's answer arrived, or the barrier met
-- and no adoption lists it. Nothing here waits for the barrier itself, so a target that adopts nothing delays only its
-- own retirements, never a close, an attachment or another view.
retirable ∷ (Ord k, Show k) ⇒ TerrainViews k → STM Bool
retirable service = do
  retiring ← readTVar (svRetiring service)
  let ledger = portLedger (svPorts service)
  candidates ← forM retiring $ \r → case rtBarrier r of
    BarrierUnasked → pure True
    BarrierWaiting reading → isJust <$> reading
    BarrierMet → not <$> ledgerChunkHeld ledger (rtChunk r)
  pure (or candidates)

-- One retirement step: ask the host's release barrier for every chunk not yet behind one (the barrier covers every
-- revision published before the request, so one that lists the chunk is adopted, and so recorded in the ledger, before
-- it is met), take every barrier's answer that arrived, then release on the owner every chunk whose barrier is met and
-- that no adoption lists, returning its GPU bytes only once the owner reports it released. 'False' when the owner will
-- never meet a barrier or takes no more actions.
retireStep ∷ (Ord k, Show k) ⇒ TerrainViews k → IO Bool
retireStep service = do
  let ports = svPorts service
      owner = portOwner ports
  -- ask, and take the answers that arrived, in one transaction
  gone ← atomically $ do
    retiring ← readTVar (svRetiring service)
    let unasked = [rtChunk r | r ← retiring, BarrierUnasked ← [rtBarrier r]]
    asked ← if null unasked then pure (Right Nothing) else fmap Just <$> ownerBarrier owner unasked
    stepped ← forM retiring $ \r → case rtBarrier r of
      BarrierUnasked → pure $ case asked of
        Right (Just reading) → (r {rtBarrier = BarrierWaiting reading}, False)
        _ → (r, False)
      BarrierWaiting reading →
        reading >>= \case
          Just True → pure (r {rtBarrier = BarrierMet}, False)
          Just False → pure (r, True)
          Nothing → pure (r, False)
      BarrierMet → pure (r, False)
    writeTVar (svRetiring service) (map fst stepped)
    pure (any snd stepped)
  if gone
    then pure False
    else do
      eligible ← atomically $ do
        now ← readTVar (svRetiring service)
        filterM' (\r → case rtBarrier r of BarrierMet → not <$> ledgerChunkHeld (portLedger ports) (rtChunk r); _ → pure False) now
      if null eligible
        then pure True
        else
          ownerRelease owner (map rtChunk eligible) >>= \case
            Nothing → pure False
            Just results → do
              let paired = zip eligible results
              forM_ [(r, why) | (r, Left why) ← paired] $ \(r, why) → recordFailure service ("a retained region's release failed: " <> Text.pack (show (rtChunk r)) <> ": " <> why)
              let done = [rtChunk r | (r, Right ()) ← paired]
                  returned = sum [rtBytes r | (r, Right ()) ← paired]
              atomically $ do
                modifyTVar' (svRetiring service) (filter (\r → rtChunk r `notElem` done))
                modifyTVar' (svGpu service) (subtract returned)
                modifyTVar' (svReleases service) (+ 1)
              pure True

-- ---------------------------------------------------------------------------
-- Preparation

-- How one preparation ended.
data Prepared'
  = Published' !Word64
  | Unchanged'
  | Retry'
  | Abandoned'

prepareView ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → IO ()
prepareView service state = do
  (intent, metrics, status) ← atomically $ do
    writeTVar (vsPhase state) PhasePreparing
    (,,) <$> readTVar (vsIntent state) <*> vtMetrics (vsTarget state) <*> Runtime.arenaStatusSTM (portTerrain (svPorts service)) (vsArena state)
  let revisions = either (const Nothing) (\s → Just (Runtime.statusContentRevision s, Runtime.statusKnowledgeRevision s)) status
  outcome ← case (metrics, status) of
    (Nothing, _) → pure Unchanged'
    (_, Left _) → pure Unchanged'
    (Just m, Right _) → prepareFor service state intent m
  atomically $ do
    mark ← retryMark service state
    case outcome of
      Retry' → writeTVar (vsRetry state) (Just mark)
      _ → writeTVar (vsRetry state) Nothing
    case outcome of
      Abandoned' → pure ()
      _ → writeTVar (vsPrepared state) (intent, revisions, metrics)
    published ← readTVar (vsPublished state)
    writeTVar (vsPhase state) (if isJust published then PhasePublished else PhaseStarting)

prepareFor ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → TargetMetrics → IO Prepared'
prepareFor service state intent metrics = do
  dropUnneededPins service state
  pins ← Map.size <$> readTVarIO (vsPins state)
  if pins >= tvCpuPins (svConfig service)
    then pure Retry'
    else do
      camera ← readTVarIO (vsCamera state)
      extra ← readTVarIO (vsExtraDemand state)
      grow (Set.fromList (anchorRegion camera : extra)) (maxRounds :: Int)
  where
    -- The planner finds its demand as it goes: regions behind known air become candidates only once the regions in
    -- front of them are known. So the copies start from the camera's anchor, and each plan's own visible demand that
    -- the copies did not hold is added and the plan made again from fresh coherent copies, a bounded number of rounds.
    -- What is still missing then stays pending in the published plan, and the next preparation goes on from there.
    maxRounds = 16
    grow regions rounds = do
      step ← withCopies service state (Set.toList regions) $ \case
        CopiesBusy → pure (Done Retry')
        CopiesGone → pure (Done Abandoned')
        CopiesReady copies → planFrom service state intent metrics copies >>= \case
          Nothing → pure (Done Abandoned')
          Just (Left why) → recordFailure service why >> pure (Done Retry')
          Just (Right (plan, adapted)) → do
            let demand = cellPlanDemand plan
                visible = regionsOf (cdVisible demand)
                prefetch = regionsOf (cdPrefetch demand)
                missing = Set.fromList visible `Set.difference` regions
            if not (Set.null missing) && rounds > 1
              then pure (More missing)
              else do
                -- The camera's interests cover every region the plan was drawn from, not only what is still pending:
                -- the regions it shows, background far from the camera included, stay protected from eviction.
                setDemand service state (Set.toList (regions <> Set.fromList visible)) prefetch
                atomically (writeTVar (vsPending state) (length (cellPlanPending plan)))
                Done <$> publishPlan service state intent metrics copies plan adapted
      case step of
        More missing → grow (regions <> missing) (rounds - 1)
        Done outcome → pure outcome

-- How one round of a preparation ended.
data Round = More !(Set.Set RegionCoord) | Done !Prepared'

-- The region of the camera's anchor column at its clip level.
anchorRegion ∷ CameraState → RegionCoord
anchorRegion camera =
  RegionCoord (axisValue (Camera.camAnchorX camera) `div` 16) (axisValue (Camera.camAnchorY camera) `div` 16) (axisValue (Camera.camClip camera) `div` 32)

data Copies = CopiesReady !CopySet | CopiesBusy | CopiesGone

-- Borrow coherent copies of these regions for the body and release them after it, however it ends. Asked in batches
-- of the service's per-copy bound, all admitted before any is awaited; a batch refused busy, or copies of different
-- versions three times running, is pressure ('CopiesBusy'). A view closing or a service stopping while a copy builds
-- cancels the rest ('CopiesGone').
withCopies ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → [RegionCoord] → (Copies → IO a) → IO a
withCopies service state regions body = attempt (3 ∷ Int)
  where
    terrain = portTerrain (svPorts service)
    batches = chunksOf (max 1 (tvCopyRegions (svConfig service))) regions
    attempt n = do
      requested ← forM batches (Runtime.requestRegionSnapshot terrain (vsArena state))
      let pendings = [p | Right p ← requested]
          busy = any isBusy [why | Left why ← requested]
      outcomes ← forM pendings $ \pending →
        atomically ((Just <$> Runtime.awaitSTM terrain pending) `orElse` (stopping >>= check >> pure Nothing)) >>= \case
          Nothing → void (Runtime.cancelPending terrain pending) >> pure Nothing
          Just settled → pure (Just settled)
      let borrows = [b | Just (Right b) ← outcomes]
          gone = any isNothing outcomes
          release = forM_ borrows (Runtime.releaseRegionBorrow terrain) >> atomically (modifyTVar' (svReleases service) (+ 1))
      ( if gone
          then body CopiesGone
          else
            if busy || null borrows || any (\o → case o of Just (Left _) → True; _ → False) outcomes
              then body CopiesBusy
              else case combineCopies (map Runtime.regionBorrowSnapshot borrows) of
                Right copies → body (CopiesReady copies)
                Left _
                  | n > 1 → release >> attempt (n - 1)
                  | otherwise → body CopiesBusy
        )
        `finally` release
    stopping = (||) <$> readTVar (vsClosing state) <*> (not <$> readTVar (svOpen service))
    isBusy = \case
      Runtime.RefusedBusy _ → True
      _ → False

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
      busy ← ask (visible <> prefetch) (Just visible)
      atomically (writeTVar (vsDemandBusy state) (if busy then Just mark else Nothing))
  where
    ask regions fallback = case traverse demandOf regions of
      Left _ → pure False
      Right demands →
        Runtime.setViewDemand (portTerrain (svPorts service)) (vsRuntimeView state) (vsArena state) demands >>= \case
          Left (Runtime.RefusedInvalid _) | Just smaller ← fallback, length smaller < length regions → ask smaller Nothing
          Left (Runtime.RefusedBusy _) → pure True
          _ → pure False
    demandOf region = RegionDemand region <$> coverageBox 0 16 0 16 0 32

-- Send the kept demand again after a busy refusal.
resendDemand ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → IO ()
resendDemand = sendDemand

-- The view's setup for these metrics: the whole framebuffer.
setupFor ∷ TargetMetrics → ViewSetup
setupFor metrics =
  let PixelExtent width height = metricsFramebuffer metrics
   in ViewSetup metrics (Viewport (V2 0 0) (V2 (fromIntegral width) (fromIntegral height))) defaultViewSettings

-- Plan from coherent copies: the facts and knowledge they make, the camera given those facts, the bounded plan and its
-- adaptation. 'Nothing' when a newer intent superseded the plan.
planFrom ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → TargetMetrics → CopySet → IO (Maybe (Either Text (CellPlan, Adapted)))
planFrom service state intent metrics copies =
  case planInputs (tvChangeLimits (svConfig service)) copies of
    Left why → pure (Just (Left ("the view's inputs could not be made: " <> Text.pack (show why))))
    Right (facts, knowledge) → do
      camera ← settleCamera service state facts
      light ← readTVarIO (vsLight state)
      let style = vsStyle state
          inputs = CellInputs (CellRequest (factsVersions facts) camera (setupFor metrics) (tvCellConfig (svConfig service))) facts knowledge (styleAssets style)
      runPlan service state intent inputs >>= \case
        Nothing → pure Nothing
        Just plan → pure . Just $ case adaptCells (styleTextures style) light (styleAssets style) plan of
          Left why → Left ("the plan could not be adapted: " <> Text.pack (show why))
          Right adapted → Right (plan, adapted)

-- Give the camera the new facts: a followed surface they supply is adopted, and a pending jump they allow lands. Only
-- if the intent did not change meanwhile; otherwise the newer intent is prepared next.
settleCamera ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → TerrainFacts → IO CameraState
settleCamera service state facts = atomically $ do
  writeTVar (vsFacts state) (Just facts)
  camera ← readTVar (vsCamera state)
  let config = tvCameraConfig (svConfig service)
      followed = either (const camera) stepCamera (refollow config facts camera)
  landed ← case camPending followed of
    Nothing → pure followed
    Just pending → case completeJump config facts (Camera.pendingId pending) followed of
      Right result → do
        case stepJump result of
          JumpApplied (JumpId number) → do
            jumps ← readTVar (vsJumps state)
            for_ (Map.lookup number jumps) $ \box → writeTVar box (Just (SettledOk JumpLanded))
            modifyTVar' (vsJumps state) (Map.delete number)
            writeTVar (vsExtraDemand state) []
          JumpPending _ demand → writeTVar (vsExtraDemand state) (regionsOf demand)
          _ → pure ()
        pure (stepCamera result)
      Left _ → pure followed
  when (camRevision landed /= camRevision camera) (writeTVar (vsCamera state) landed)
  pure landed

-- The planner's bounded steps, abandoning the plan as soon as a newer intent supersedes it.
runPlan ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → CellInputs → IO (Maybe CellPlan)
runPlan service state intent inputs =
  case startCells inputs of
    Left why → recordFailure service ("the plan could not start: " <> Text.pack (show why)) >> pure Nothing
    Right prep0 → go prep0
  where
    quantum = max 1 (tvStepsPerQuantum (svConfig service))
    go prep = case cellPrepProgress prep of
      Working → do
        current ← readTVarIO (vsIntent state)
        closing ← readTVarIO (vsClosing state)
        if current /= intent || closing
          then pure Nothing
          else case steps quantum prep of
            Left why → recordFailure service ("a plan step failed: " <> Text.pack (show why)) >> pure Nothing
            Right next → go next
      _ → either (\why → recordFailure service ("the plan could not finish: " <> Text.pack (show why)) >> pure Nothing) (pure . Just) (cellPlanOf inputs prep)
    steps 0 prep = Right prep
    steps n prep = case cellPrepProgress prep of
      Working → stepCells inputs prep >>= steps (n - 1 ∷ Int)
      _ → Right prep

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

-- Build what changed, publish the whole revision, then retire what it no longer lists.
publishPlan ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → Word64 → TargetMetrics → CopySet → CellPlan → Adapted → IO Prepared'
publishPlan service state intent metrics copies plan adapted = do
  let ports = svPorts service
      material = svMaterial service
      groups = regionGroups material adapted
  existing ← readTVarIO (vsRegions state)
  let reused = Map.mapMaybe id (Map.intersectionWith (\region (instances, records) → if rgInstances region == instances && rgRecords region == records then Just region else Nothing) existing groups)
      wanted = Map.difference groups reused
      bytesOf (instances, _) = fromIntegral (length instances) * 64
      gpuNeed = sum (map bytesOf (Map.elems wanted))
      cpuNeed = planBytes adapted
  reserved ← atomically $ do
    charged ← readTVar (svGpu service)
    if gpuNeed > tvGpuBytes (svConfig service) - min (tvGpuBytes (svConfig service)) charged
      then pure False
      else do
        pinned ← pinnedNeed state
        cpu ← coverNeed service state (pinned + cpuNeed)
        when cpu (writeTVar (svGpu service) (charged + gpuNeed))
        pure cpu
  if not reserved
    then pure Retry'
    else do
      built ← buildRegions service wanted
      let refund = do
            pinned ← pinnedNeed state
            void (coverNeed service state pinned)
            modifyTVar' (svGpu service) (subtract gpuNeed)
            modifyTVar' (svReleases service) (+ 1)
      case built of
        Nothing → atomically refund >> pure Retry'
        Just fresh → do
          ready ← awaitReady service state (map rgChunk (Map.elems fresh))
          if not ready
            then discardFresh service fresh >> atomically refund >> pure Retry'
            else do
              let regions = Map.union reused fresh
                  chunks = map rgChunk (Map.elems regions)
              revision ← atomically (readTVar (vsNextRevision state) <* modifyTVar' (vsNextRevision state) (+ 1))
              case terrainView plan adapted [(material, MaterialData [] (adaptedPush adapted))] [WorldLayerWith DepthEnabled chunks []] of
                Left why → do
                  recordFailure service ("the view could not be made: " <> Text.pack (show why))
                  discardFresh service fresh >> atomically refund >> pure Retry'
                Right view → do
                  let world =
                        SceneWorld
                          { worldTag = WorldTag (vsId state) revision
                          , worldClear = tvClear (svConfig service)
                          , worldView = view
                          , worldMetrics = metrics
                          , worldChunks = Set.fromList chunks
                          , worldTextures = styleIdentities (vsStyle state)
                          }
                  scene ← prepare (worldGraphicsScene world)
                  committed ← atomically $ do
                    closing ← readTVar (vsClosing state)
                    open ← readTVar (svOpen service)
                    taking ← portTaking ports
                    claim ← claimOf (portClaims ports) (vtKey (vsTarget state))
                    usable ← vtUsable (vsTarget state)
                    -- Every identity the plan was made from is revalidated here, with the publication: a newer intent
                    -- (camera, presentation, jump), other metrics, or a content or knowledge revision the arena has since
                    -- committed make this plan obsolete. It is discarded, never relabelled current; the newer state is
                    -- prepared next.
                    current ← readTVar (vsIntent state)
                    nowMetrics ← vtMetrics (vsTarget state)
                    status ← Runtime.arenaStatusSTM (portTerrain ports) (vsArena state)
                    let mine = fmap claimView claim == Just (vsId state)
                        coherent =
                          current == intent
                            && nowMetrics == Just metrics
                            && either (const False) (\s → Runtime.statusContentRevision s == copyContent copies && Runtime.statusKnowledgeRevision s == copyKnowledge copies) status
                    if closing || not open || not taking || not mine || not usable || not coherent
                      then pure False
                      else do
                        accepted ← vtPublish (vsTarget state) scene
                        when accepted $ do
                          _ ← markClaimPublished (portClaims ports) (vtKey (vsTarget state)) (vsId state)
                          writeTVar (vsPublished state) (Just revision)
                          modifyTVar' (vsPins state) (Map.insert revision (Pinned plan metrics (copyArena copies) (copyContent copies) (copyKnowledge copies) cpuNeed))
                          writeTVar (vsRegions state) regions
                          -- What the new revision no longer lists starts its retirement; the host's barrier and the
                          -- adoptions still protect it wherever an earlier revision may be drawn.
                          let superseded = Map.difference existing reused
                          modifyTVar' (svRetiring service) (<> [Retiring (rgChunk r) (rgBytes r) BarrierUnasked | r ← Map.elems superseded])
                        pure accepted
                  if committed
                    then pure (Published' revision)
                    else discardFresh service fresh >> atomically refund >> pure Abandoned'

-- A conservative CPU charge of one pinned revision: the plan's quads and pending spans, the adapted instances and their
-- records, and the region copies of the instances kept for reuse.
planBytes ∷ Adapted → Word64
planBytes adapted =
  let quads = fromIntegral (length (adaptedQuads adapted))
      records = fromIntegral (length (adaptedRecords adapted))
   in 4096 + quads * (256 + 64 + 64) + records * 128

-- Build the regions on the graphics owner, in one action; a refusal releases whatever the action built before it.
buildRegions ∷ (Ord k, Show k) ⇒ TerrainViews k → Map (Integer, Integer) ([Instance], [MaterialRecord]) → IO (Maybe (Map (Integer, Integer) Region))
buildRegions service wanted
  | Map.null wanted = pure (Just Map.empty)
  | otherwise =
      ownerBuild (portOwner (svPorts service)) [RegionBuild instances records | (instances, records) ← Map.elems wanted] >>= \case
        Nothing → pure Nothing
        Just (Left (BuildPressure _)) → pure Nothing
        Just (Left (BuildFailed why)) → recordFailure service ("a retained region could not be built: " <> why) >> pure Nothing
        Just (Right chunks)
          | length chunks /= Map.size wanted → recordFailure service "the owner built another number of regions than asked" >> pure Nothing
          | otherwise →
              pure . Just . Map.fromList $
                [ (key, Region chunk instances records (fromIntegral (length instances) * 64))
                | ((key, (instances, records)), chunk) ← zip (Map.toList wanted) chunks
                ]

-- Wait for every fresh chunk's upload: 'False' when one failed or the view is closing.
awaitReady ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → [ChunkRef] → IO Bool
awaitReady service state chunks = atomically $ do
  standings ← traverse (ownerStanding (portOwner (svPorts service))) chunks
  closing ← readTVar (vsClosing state)
  open ← readTVar (svOpen service)
  case () of
    _
      | closing || not open → pure False
      | any failed standings → pure False
      | all (== Just ChunkReady) standings → pure True
      | otherwise → retry
  where
    failed = \case
      Just (ChunkFailed _) → True
      Nothing → True
      _ → False

-- Release chunks that were never published: nothing can hold them, so the owner releases them at once.
discardFresh ∷ (Ord k, Show k) ⇒ TerrainViews k → Map (Integer, Integer) Region → IO ()
discardFresh service fresh
  | Map.null fresh = pure ()
  | otherwise =
      ownerRelease (portOwner (svPorts service)) (map rgChunk (Map.elems fresh)) >>= \case
        Just results | all (either (const False) (const True)) results → pure ()
        _ → recordFailure service "unpublished regions could not be released"

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
dropUnneededPins ∷ (Ord k, Show k) ⇒ TerrainViews k → ViewState k → IO ()
dropUnneededPins service state = atomically $ do
  published ← readTVar (vsPublished state)
  adopted ← fmap (tagRevision . snd) <$> adoptedRevision service state
  pins ← readTVar (vsPins state)
  let keep revision = Just revision == published || Just revision == adopted || maybe False (revision >) adopted
      (kept, dropped) = Map.partitionWithKey (\revision _ → keep revision) pins
      bytes = sum (map pinBytes (Map.elems dropped))
  unless (Map.null dropped) $ do
    writeTVar (vsPins state) kept
    void (coverNeed service state (sum (map pinBytes (Map.elems kept))))
    when (bytes > 0) (modifyTVar' (svReleases service) (+ 1))

-- ---------------------------------------------------------------------------
-- Picking

-- | Pick at a logical point of the view's target. Never waits and never loads terrain: it reads the revision the host
-- adopted and the plan pinned for it. No adopted revision, a plan made for other metrics than the target's now, or
-- information that could lie ahead is 'PickLoading'; zero or absent metrics, a point outside, air, gaps and fog are
-- 'PickNoHit'; a visible known part is 'PickHit' with its consistency reference.
pickView ∷ (Ord k, Show k) ⇒ TerrainView k → (Double, Double) → STM (PickResult k)
pickView (TerrainView service state) (px, py) = do
  closing ← readTVar (vsClosing state)
  metrics ← vtMetrics (vsTarget state)
  case metrics of
    _ | closing → pure PickNoHit
    Nothing → pure PickNoHit
    Just m
      | let PixelExtent w h = metricsFramebuffer m in w == 0 || h == 0 → pure PickNoHit
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
                          ( mkPickRef
                              (hitCell hit)
                              (hitPart hit)
                              PickIdentity
                                { pickTarget = vtKey (vsTarget state)
                                , pickViewId = vsId state
                                , pickRevision = fromIntegral revision
                                , pickTag = tag
                                , pickArena = pinArena pinned
                                , pickContent = pinContent pinned
                                , pickKnowledge = pinKnowledge pinned
                                }
                          )

-- | The removal precondition of a pick: the arena incarnation and the content and knowledge revisions it was picked
-- from, with a guard that the view still holds its target and that the revision it was picked from is still the one
-- the host adopted. The terrain service reads the guard in its removal arbitration, atomically with the commit.
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
      pure (not closing && fmap claimView claim == Just (vsId state) && fmap (\(revision, tag) → (fromIntegral revision, tag)) adopted == Just (pickRevision identity, pickTag identity))
