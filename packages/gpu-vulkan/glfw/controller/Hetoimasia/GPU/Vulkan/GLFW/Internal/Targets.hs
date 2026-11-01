-- | The offscreen scene targets a host holds (LFE-27): a surface-free target
-- the application registers with the running host, which then takes part in
-- the same ownership a window has — a scene-target key, a latest-value scene
-- with a host-held rising revision, an entry in the release barrier, and the
-- owner's adoption and release of what it publishes
-- ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Scenes").
--
-- A target is /not/ a window and opens none. It has no surface, no swapchain
-- and no frame: what it adopts is read by frame-less batches an owner-thread
-- action records through the host's bound recording boundary
-- ('Hetoimasia.GPU.Vulkan.GLFW.Internal.Rendering.constructTargetBatch'), and a
-- revision it adopted is released only once every such batch's own ticket says
-- the batch was discarded or completed. This module holds the registry and the
-- scene the owner adopted, and decides nothing native.
--
-- = Registration
--
-- 'registerTarget' is one transaction. It issues an 'OffscreenTargetId' from
-- this host's own identity and a rising incarnation number that is never
-- reused, starts the target at the initial scene's revision 0, and registers
-- its adopter with the scene ledger. It is refused, with a typed reason, when
-- the host's gate is closed — the session has failed or the owner's exit has
-- begun —, when no device exists, and when the finite capacity is reached. The
-- capacity counts every target the host still accounts for: those registered,
-- and those unregistered whose adopted revisions the ledger has not yet
-- released, so repeated registration cannot grow the bookkeeping, and it is
-- apart from the windows' bound, which it never reduces.
--
-- = Publication
--
-- 'publishTarget' is one transaction that never waits: it reads the gate and
-- the registry and, for a live target, makes the scene the target's latest
-- value at the next revision, replacing a scene the owner has not yet taken.
-- A target that is not registered — never was, ended, another registration's
-- or another host's — is answered 'TargetSceneUnknown' naming it, and the gate
-- closed 'TargetSceneClosed'; neither changes anything. Revisions rise by one
-- for each accepted publication. As a transaction it composes with the
-- caller's own authority checks, so liveness, acceptance and revision are one
-- fact.
--
-- = Adoption
--
-- The owner's step takes the target's latest scene ('pendingScenes') and
-- adopts it through the ledger when its revision is newer than the one the
-- target holds, or the target has adopted nothing yet — the initial scene, as
-- revision 0, in the first step after registration. The lifecycle wrapper the
-- controller installs records the exact adopted scene here in the same
-- uninterruptible transition as the ledger's record and the hook
-- ('recordAdopted'), so the scene a batch is recorded against is the scene the
-- ledger accounts for. A target at its retention limit adopts nothing newer
-- and the owner neither attempts it again nor asks a round for it, once it has
-- noted the deferral for that revision ('markDeferred'), until a release makes
-- room: the step's adoption and the wake read the one pending set
-- ('pendingScenes'), with the ledger's own answer on room. A newer publication
-- is a new revision and is noted afresh. Its publication never waits.
--
-- = Unregistration
--
-- 'unregisterTarget' removes the target from the registry in one transaction:
-- it can no longer be published to or recorded against, the barrier no longer
-- names it, and the owner is woken to end it in the ledger ('takeRetiring').
-- Its adopted revisions stay in the ledger, and in the observation, until
-- every batch recorded with them is discarded or complete; unregistration
-- manufactures no release.
--
-- = State
--
-- +------------------+-------------+------------------------------------+----------+----------------------+---------------------------+
-- | State            | Owner       | Readers and writers                | Thread   | Lifetime             | Reset or disposal         |
-- +==================+=============+====================================+==========+======================+===========================+
-- | The registry:    | This module | Any thread registers, publishes    | Any,     | The host's           | A target is removed by    |
-- | each target's    |             | and unregisters; the owner's step  | in STM   |                      | its unregistration or the |
-- | latest scene and |             | records what it adopted and takes  |          |                      | owner's retirement; the   |
-- | revision, the    |             | the retired                        |          |                      | incarnation counter never |
-- | scene adopted    |             |                                    |          |                      | resets                    |
-- +------------------+-------------+------------------------------------+----------+----------------------+---------------------------+
module Hetoimasia.GPU.Vulkan.GLFW.Internal.Targets
  ( -- * The registry
    Targets
  , newTargets
  , SceneTargetRefusal (..)
  , TargetScenePublication (..)

    -- * Any thread
  , registerTarget
  , unregisterTarget
  , publishTarget
  , targetsHeld
  , targetsRevisions

    -- * The owner's step
  , pendingScenes
  , markDeferred
  , recordAdopted
  , adoptedScene
  , takeRetiring
  , hasRetiring
  , retireAllTargets
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', newTVarIO, readTVar, writeTVar)
import Control.Monad (forM, forM_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Unique (Unique, newUnique)
import Numeric.Natural (Natural)

import Hetoimasia.Foundation.Messaging.Payload (Prepared, preparedValue)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Actions (ActionRefusal (..))
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Scenes (Scenes, endSceneTarget, forgetSceneTarget, registerSceneTarget, scenesOccupants)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Target (Adopter (..), OffscreenTargetId (..), SceneTargetKey (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (TerminalCause)

-- | Why a registration was refused.
data SceneTargetRefusal
  = TargetSessionFailed !TerminalCause
    -- ^ The session has failed, with this primary.
  | TargetOwnerClosed
    -- ^ The owner's exit has begun, or its run has ended.
  | TargetDeviceNotReady
    -- ^ The session has no device yet.
  | TargetCapacityReached !Natural
    -- ^ The host already accounts for this many targets, its capacity.
  deriving (Eq, Show)

-- | What a publication to an offscreen target did.
data TargetScenePublication
  = TargetScenePublished !OffscreenTargetId !Natural
    -- ^ Accepted: the target's scene is now at this revision. Revisions rise by
    -- one for each accepted publication.
  | TargetSceneUnknown !OffscreenTargetId
    -- ^ The host holds no such target: it was never registered here, it has
    -- been unregistered, or the identity is another registration's or another
    -- host's. Nothing changed.
  | TargetSceneClosed !OffscreenTargetId
    -- ^ The session has failed or the owner's exit has begun. Nothing changed.
  deriving (Eq, Show)

-- | One registered target.
data Cell scene = Cell
  { cellLatest ∷ !(Prepared scene)
    -- ^ The latest accepted scene: the initial scene until one is published.
  , cellRevision ∷ !Natural
    -- ^ Its revision: 0 for the initial scene.
  , cellAdopted ∷ !(Maybe (Natural, scene))
    -- ^ The revision the owner adopted last, with the exact scene it took.
  , cellDeferredAt ∷ !(Maybe Natural)
    -- ^ The revision whose adoption the owner found no room for and has noted,
    -- so it asks no further round for that revision while there is still none.
  }

data Standing scene = Standing
  { standingNext ∷ !Natural
  , standingLive ∷ !(Map OffscreenTargetId (Cell scene))
  , standingRetiring ∷ !(Set.Set OffscreenTargetId)
    -- ^ Unregistered targets the owner has not yet ended in the ledger.
  }

-- | The offscreen targets of one host.
data Targets scene = Targets
  { targetsHost ∷ !Unique
  , targetsInitial ∷ !(Prepared scene)
  , targetsCapacity ∷ !Natural
  , targetsStanding ∷ !(TVar (Standing scene))
  }

-- | An empty registry for a host whose targets start at this initial scene and
-- of which at most this many are accounted for at once.
newTargets ∷ Natural → Prepared scene → IO (Targets scene)
newTargets capacity initial =
  Targets <$> newUnique <*> pure initial <*> pure capacity <*> newTVarIO (Standing 0 Map.empty Set.empty)

-- | Register a target, given the host's gate and whether its device exists, in
-- the ledger's own transaction. Refusals come in that order.
registerTarget ∷ Targets scene → Scenes → STM (Maybe ActionRefusal) → STM Bool → STM (Either SceneTargetRefusal OffscreenTargetId)
registerTarget targets scenes gate deviceExists =
  gate >>= \case
    Just (ActionSessionFailed primary) → pure (Left (TargetSessionFailed primary))
    Just _ → pure (Left TargetOwnerClosed)
    Nothing →
      deviceExists >>= \case
        False → pure (Left TargetDeviceNotReady)
        True → do
          standing ← readTVar (targetsStanding targets)
          occupied ← scenesOccupants scenes
          let accounted = Set.unions [occupied, Map.keysSet (standingLive standing), standingRetiring standing]
          if fromIntegral (Set.size accounted) >= targetsCapacity targets
            then pure (Left (TargetCapacityReached (targetsCapacity targets)))
            else do
              let identity = OffscreenTargetId (targetsHost targets) (standingNext standing)
              writeTVar
                (targetsStanding targets)
                standing
                  { standingNext = standingNext standing + 1
                  , standingLive = Map.insert identity (Cell (targetsInitial targets) 0 Nothing Nothing) (standingLive standing)
                  }
              registerSceneTarget scenes (TargetAdopter identity)
              pure (Right identity)

-- | Unregister a target: answers whether it was registered. It is no longer
-- held, so the barrier stops naming it and nothing can be published to or
-- recorded against it; the owner is woken to end it in the ledger.
unregisterTarget ∷ Targets scene → OffscreenTargetId → STM Bool
unregisterTarget targets identity = do
  standing ← readTVar (targetsStanding targets)
  if Map.member identity (standingLive standing)
    then do
      writeTVar
        (targetsStanding targets)
        standing
          { standingLive = Map.delete identity (standingLive standing)
          , standingRetiring = Set.insert identity (standingRetiring standing)
          }
      pure True
    else pure False

-- | Publish a scene to a target as its latest value, given the host's gate.
publishTarget ∷ Targets scene → STM (Maybe ActionRefusal) → OffscreenTargetId → Prepared scene → STM TargetScenePublication
publishTarget targets gate identity scene =
  gate >>= \case
    Just _ → pure (TargetSceneClosed identity)
    Nothing → do
      standing ← readTVar (targetsStanding targets)
      case Map.lookup identity (standingLive standing) of
        Nothing → pure (TargetSceneUnknown identity)
        Just cell → do
          let revision = cellRevision cell + 1
          writeTVar
            (targetsStanding targets)
            standing {standingLive = Map.insert identity cell {cellLatest = scene, cellRevision = revision} (standingLive standing)}
          pure (TargetScenePublished identity revision)

-- | The scene targets this registry holds, for the barrier.
targetsHeld ∷ Targets scene → STM [SceneTargetKey]
targetsHeld targets = map KeyOffscreen . Map.keys . standingLive <$> readTVar (targetsStanding targets)

-- | The latest published revision of every registered target: 0 before the
-- first publication.
targetsRevisions ∷ Targets scene → STM (Map SceneTargetKey Natural)
targetsRevisions targets =
  Map.fromList . map (\(identity, cell) → (KeyOffscreen identity, cellRevision cell)) . Map.toList . standingLive <$> readTVar (targetsStanding targets)

-- | The scene the owner has to adopt for each registered target whose latest revision is newer than the one it
-- adopted, or that has adopted nothing — except a target whose current revision the owner has already noted it found
-- no room for, while the given question still answers that it has none. That one definition is what the owner's step
-- adopts from and what its wake reads, so a revision whose deferral was counted is not attempted, and not counted
-- again, by any later round until a release makes room.
pendingScenes ∷ Targets scene → (OffscreenTargetId → STM Bool) → STM [(OffscreenTargetId, scene, Natural)]
pendingScenes targets hasRoom = do
  standing ← readTVar (targetsStanding targets)
  fmap concat . forM (Map.toList (standingLive standing)) $ \(identity, cell) →
    if maybe True ((< cellRevision cell) . fst) (cellAdopted cell)
      then do
        room ← if cellDeferredAt cell == Just (cellRevision cell) then hasRoom identity else pure True
        pure [(identity, preparedValue (cellLatest cell), cellRevision cell) | room]
      else pure []

-- | Record the exact scene the owner adopted for a target, in the adoption's
-- own transition. A target that was unregistered meanwhile records nothing.
recordAdopted ∷ Targets scene → OffscreenTargetId → Natural → scene → STM ()
recordAdopted targets identity revision scene =
  modifyTVar' (targetsStanding targets) $ \standing →
    standing {standingLive = Map.adjust (\cell → cell {cellAdopted = Just (revision, scene)}) identity (standingLive standing)}

-- | The scene a registered target has adopted, with its revision: 'Nothing' for
-- a target that is not registered, and @Just Nothing@ for one that has adopted
-- nothing yet.
adoptedScene ∷ Targets scene → OffscreenTargetId → STM (Maybe (Maybe (Natural, scene)))
adoptedScene targets identity = fmap cellAdopted . Map.lookup identity . standingLive <$> readTVar (targetsStanding targets)

-- | The owner found no room to adopt these revisions: it notes each once.
markDeferred ∷ Targets scene → [(OffscreenTargetId, Natural)] → STM ()
markDeferred targets deferred =
  modifyTVar' (targetsStanding targets) $ \standing →
    standing {standingLive = foldr (\(identity, revision) → Map.adjust (\cell → cell {cellDeferredAt = Just revision}) identity) (standingLive standing) deferred}

-- | End, in the ledger and in the same transaction, every target that was
-- unregistered, and forget its entry: its adopted revisions stay until
-- released.
takeRetiring ∷ Targets scene → Scenes → STM Bool
takeRetiring targets scenes = do
  standing ← readTVar (targetsStanding targets)
  let retiring = Set.toList (standingRetiring standing)
  writeTVar (targetsStanding targets) standing {standingRetiring = Set.empty}
  forM_ retiring $ \identity → do
    endSceneTarget scenes (TargetAdopter identity)
    forgetSceneTarget scenes (TargetAdopter identity)
  pure (not (null retiring))

-- | The owner is ending: unregister every target and end it in the ledger,
-- in one transaction.
retireAllTargets ∷ Targets scene → Scenes → STM ()
retireAllTargets targets scenes = do
  modifyTVar' (targetsStanding targets) $ \standing →
    standing
      { standingLive = Map.empty
      , standingRetiring = Set.union (standingRetiring standing) (Map.keysSet (standingLive standing))
      }
  _ ← takeRetiring targets scenes
  pure ()

-- | Whether an unregistered target waits for the owner to end it in the ledger.
hasRetiring ∷ Targets scene → STM Bool
hasRetiring targets = not . Set.null . standingRetiring <$> readTVar (targetsStanding targets)
