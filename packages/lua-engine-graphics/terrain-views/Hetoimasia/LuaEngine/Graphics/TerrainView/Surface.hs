-- | The targets a terrain view attaches to (TRA-9), as closed data its session reads inside its own commits.
--
-- A target is a window incarnation, through the capability its host issues ('WindowView'); a surface-free target
-- registered with the host, with facts its registrant sets ('OffscreenFacts'); or a target held in memory, its facts
-- and published scenes in its own state ('HeldTarget'). The session reads each only through the readers here, which run
-- the target's owner's transactions and no caller's: whether it is usable, the original authority over it (its leases),
-- its geometry with the version of the facts it came from, whether it shows a scene already, the frame metrics the view
-- watches from its open to its close, and its publication. A fact that can change and change back carries a version its
-- writer advances in the same commit, so a reader comparing versions misses no change between two of its reads.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Surface
  ( -- * The target
    ViewTarget (..)
  , ViewSurface (..)
  , Authority (..)
  , leasesLive
  , ViewGeometry (..)
  , geometryOfMetrics
  , windowGeometryOf
  , SurfaceVersion

    -- * A registered offscreen target's facts
  , OffscreenFacts
  , newOffscreenFacts
  , setOffscreenUsable
  , setOffscreenMetrics

    -- * A target held in memory
  , HeldTarget
  , newHeldTarget
  , setHeldUsable
  , setHeldAuthority
  , setHeldMetrics
  , setHeldAccepts
  , heldScenes
  , HeldFault (..)
  , setHeldFault

    -- * The readers
  , surfaceUsable
  , surfaceAuthority
  , surfaceGeometry
  , surfaceVersion
  , surfaceRevalidation
  , surfaceShowing
  , surfaceBind
  , surfaceUnbind
  , surfacePublish
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', newTVar, readTVar, retry, throwSTM, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall))
import Control.Monad (when)
import Data.Functor ((<&>))
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Word (Word64)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, preparedValue)
import Hetoimasia.GPU.Vulkan.GLFW
  ( OffscreenTargetId
  , SceneTargetKey (..)
  , TargetScenePublication (..)
  , VulkanHost
  , VulkanSceneState (..)
  , WindowScenePublication (..)
  , WindowSceneStanding (..)
  , publishVulkanTargetScene
  , readVulkanSceneState
  )
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Scene.Receipts (DrawReceipts, unwatchFrameMetrics, watchFrameMetrics)
import Hetoimasia.LuaEngine.Graphics.Window.Host
  ( WindowGeometry (..)
  , WindowVersion
  , WindowView
  , windowViewAttachment
  , windowViewGeometry
  , windowViewId
  , windowViewPublish
  , windowViewUsable
  )
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..), validMetrics)
import Hetoimasia.Scripting.Lua.Lease (Leases, leaseLiveSTM)

-- | A target a view attaches to: its incarnation's key, the target itself, and whether its frames carry the qualified
-- depth image.
data ViewTarget k = ViewTarget
  { vtKey ∷ !k
  , vtSurface ∷ !ViewSurface
  , vtDepth ∷ !Bool
  }

-- | What a target is.
data ViewSurface
  = -- | A window incarnation through its host-issued capability, with the caller's original leases over it.
    WindowSurface !(VulkanHost GraphicsScene) !DrawReceipts !(WindowView GraphicsScene) ![Authority]
  | -- | A surface-free target registered with the host, and its registrant's facts.
    OffscreenSurface !(VulkanHost GraphicsScene) !OffscreenTargetId !OffscreenFacts
  | -- | A target held in memory.
    HeldSurface !HeldTarget

-- | An original authority the caller holds, live until it ends, once: a lease (exact and never reissued), or a cell
-- held in memory that its holder ends.
data Authority = LeaseAuthority !Leases !Word64 | HeldAuthority !(TVar Bool)

-- | Whether every one of these authorities is still live.
leasesLive ∷ [Authority] → STM Bool
leasesLive = fmap and . mapM live
  where
    live = \case
      LeaseAuthority table key → leaseLiveSTM table key
      HeldAuthority cell → readTVar cell

-- | A target's geometry as observed now: unknown (incomplete), zero (an observed zero dimension, logical or
-- framebuffer, whatever else is missing), or a complete positive extent.
data ViewGeometry
  = GeometryUnknown
  | GeometryZero
  | GeometryExtent !TargetMetrics
  deriving (Eq, Show)

-- | The geometry metrics give: none is unknown, a zero dimension is zero.
geometryOfMetrics ∷ Maybe TargetMetrics → ViewGeometry
geometryOfMetrics = \case
  Nothing → GeometryUnknown
  Just metrics
    | any (== 0) dimensions → GeometryZero
    | all (> 0) dimensions && validMetrics metrics → GeometryExtent metrics
    | otherwise → GeometryUnknown
    where
      dimensions = [pixelWidth (metricsLogical metrics), pixelHeight (metricsLogical metrics), pixelWidth (metricsFramebuffer metrics), pixelHeight (metricsFramebuffer metrics)]

-- | A window's geometry as the views read it: its live observation, a zero dimension included.
windowGeometryOf ∷ WindowGeometry → ViewGeometry
windowGeometryOf = \case
  WindowGeometryUnknown → GeometryUnknown
  WindowGeometryZero → GeometryZero
  WindowGeometryExtent metrics → GeometryExtent metrics

-- | The version of the facts a geometry came from: equal versions mean no change between two reads.
data SurfaceVersion = WindowFacts !WindowVersion | HeldFacts !Word64
  deriving (Eq)

-- The facts of a target that is not a window, with the version their every change advances.
data Facts = Facts
  { factsVersion ∷ !Word64
  , factsUsable ∷ !Bool
  , factsAuthority ∷ !Bool
  , factsMetrics ∷ !(Maybe TargetMetrics)
  }

-- | A registered offscreen target's facts, set by its registrant: whether it is usable (which is also its authority)
-- and the metrics its next frame is recorded with. Scoped to one registration.
newtype OffscreenFacts = OffscreenFacts (TVar Facts)

-- | Facts for a registration: usable or not, and its metrics, if known.
newOffscreenFacts ∷ Bool → Maybe TargetMetrics → STM OffscreenFacts
newOffscreenFacts usable metrics = OffscreenFacts <$> newTVar (Facts 0 usable usable metrics)

setOffscreenUsable ∷ OffscreenFacts → Bool → STM ()
setOffscreenUsable (OffscreenFacts cell) usable = changeFacts cell (\facts → facts {factsUsable = usable, factsAuthority = usable})

setOffscreenMetrics ∷ OffscreenFacts → Maybe TargetMetrics → STM ()
setOffscreenMetrics (OffscreenFacts cell) metrics = changeFacts cell (\facts → facts {factsMetrics = metrics})

-- | A target held in memory: its facts, the scenes published to it, newest first with the revision it gave each, and
-- whether it accepts a publication.
data HeldTarget = HeldTarget
  { heldFacts ∷ !(TVar Facts)
  , heldPublished ∷ !(TVar [(Word64, GraphicsScene)])
  , heldAccepting ∷ !(TVar Bool)
  , heldFault ∷ !(TVar (Maybe HeldFault))
  }

-- | How a held target's revalidation read fails, while its holder says so: it raises, waits, or is cancelled; or
-- its facts change right after the read.
data HeldFault = HeldRaises | HeldWaits | HeldCancelled | HeldChanges
  deriving (Eq, Show)

-- | Make the held target's revalidation read fail, or read again.
setHeldFault ∷ HeldTarget → Maybe HeldFault → STM ()
setHeldFault held = writeTVar (heldFault held)

-- | A usable, accepting target held in memory, under its caller's authority, at these metrics.
newHeldTarget ∷ Maybe TargetMetrics → STM HeldTarget
newHeldTarget metrics = HeldTarget <$> newTVar (Facts 0 True True metrics) <*> newTVar [] <*> newTVar True <*> newTVar Nothing

setHeldUsable, setHeldAuthority ∷ HeldTarget → Bool → STM ()
setHeldUsable held usable = changeFacts (heldFacts held) (\facts → facts {factsUsable = usable})
setHeldAuthority held authority = changeFacts (heldFacts held) (\facts → facts {factsAuthority = authority})

setHeldMetrics ∷ HeldTarget → Maybe TargetMetrics → STM ()
setHeldMetrics held metrics = changeFacts (heldFacts held) (\facts → facts {factsMetrics = metrics})

setHeldAccepts ∷ HeldTarget → Bool → STM ()
setHeldAccepts held = writeTVar (heldAccepting held)

-- | The scenes published to a held target, newest first, with the revision it gave each.
heldScenes ∷ HeldTarget → STM [(Word64, GraphicsScene)]
heldScenes = readTVar . heldPublished

changeFacts ∷ TVar Facts → (Facts → Facts) → STM ()
changeFacts cell change = modifyTVar' cell (\facts → (change facts) {factsVersion = factsVersion facts + 1})

-- | Whether the target is still the admitted, attached one.
surfaceUsable ∷ ViewSurface → STM Bool
surfaceUsable = \case
  WindowSurface _ _ view _ → windowViewUsable view
  OffscreenSurface _ _ (OffscreenFacts cell) → factsUsable <$> readTVar cell
  HeldSurface held → factsUsable <$> readTVar (heldFacts held)

-- | Whether the caller's original authority over the target holds: every lease it opened under still live.
surfaceAuthority ∷ ViewSurface → STM Bool
surfaceAuthority = \case
  WindowSurface _ _ _ leases → leasesLive leases
  OffscreenSurface _ _ (OffscreenFacts cell) → factsAuthority <$> readTVar cell
  HeldSurface held → factsAuthority <$> readTVar (heldFacts held)

-- | The target's geometry as observed now.
surfaceGeometry ∷ ViewSurface → STM ViewGeometry
surfaceGeometry = \case
  WindowSurface _ _ view _ → windowGeometryOf . fst <$> windowViewGeometry view
  OffscreenSurface _ _ (OffscreenFacts cell) → geometryOfMetrics . factsMetrics <$> readTVar cell
  HeldSurface held → geometryOfMetrics . factsMetrics <$> readTVar (heldFacts held)

-- | The version of the target's facts now: equal versions, read in two transactions, mean no change between them.
-- It never waits.
surfaceVersion ∷ ViewSurface → STM SurfaceVersion
surfaceVersion = \case
  WindowSurface _ _ view _ → WindowFacts . snd <$> windowViewGeometry view
  OffscreenSurface _ _ (OffscreenFacts cell) → HeldFacts . factsVersion <$> readTVar cell
  HeldSurface held → HeldFacts . factsVersion <$> readTVar (heldFacts held)

-- | What a view's revalidation of its work reads of the target beyond its facts: nothing, but for a held target its
-- holder has made fail ('setHeldFault'): raise, wait, be cancelled, or see the facts change right after the read.
surfaceRevalidation ∷ ViewSurface → STM ()
surfaceRevalidation = \case
  HeldSurface held →
    readTVar (heldFault held) >>= \case
      Nothing → pure ()
      Just HeldRaises → throwSTM (ErrorCall "the held target's facts could not be read")
      Just HeldWaits → retry
      Just HeldCancelled → throwSTM ThreadKilled
      Just HeldChanges → changeFacts (heldFacts held) id
  _ → pure ()

-- | Whether the target holds a published scene (an M1 scene, say), whose frame is or was drawn.
surfaceShowing ∷ ViewSurface → STM Bool
surfaceShowing = \case
  WindowSurface host _ view _ → showing host (KeyWindow (windowViewId view))
  OffscreenSurface host target _ → showing host (KeyOffscreen target)
  HeldSurface held → not . null <$> readTVar (heldPublished held)

-- | Watch the target's frame metrics, from the view's open.
surfaceBind ∷ ViewSurface → STM ()
surfaceBind = \case
  WindowSurface _ receipts view _ → watchFrameMetrics receipts (windowViewAttachment view)
  _ → pure ()

-- | Stop watching them, at the view's close.
surfaceUnbind ∷ ViewSurface → STM ()
surfaceUnbind = \case
  WindowSurface _ receipts view _ → unwatchFrameMetrics receipts (windowViewAttachment view)
  _ → pure ()

-- | Publish a scene to the target, as its host's own transaction: whether it was accepted.
surfacePublish ∷ ViewSurface → Prepared GraphicsScene → STM Bool
surfacePublish surface scene = case surface of
  WindowSurface _ _ view _ →
    windowViewPublish view scene <&> \case
      WindowScenePublished _ _ → True
      _ → False
  OffscreenSurface host target _ →
    publishVulkanTargetScene host target scene <&> \case
      TargetScenePublished _ _ → True
      _ → False
  HeldSurface held → do
    accepts ← readTVar (heldAccepting held)
    when accepts $ do
      published ← readTVar (heldPublished held)
      writeTVar (heldPublished held) ((fromIntegral (length published) + 1, preparedValue scene) : published)
    pure accepts

-- Whether the host holds a scene published for this target.
showing ∷ VulkanHost GraphicsScene → SceneTargetKey → STM Bool
showing host key = maybe False ((> 0) . fromMaybe 0 . windowPublished) . Map.lookup key . sceneWindows <$> readVulkanSceneState host
