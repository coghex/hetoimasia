-- | The scene ledger (D-28, D-30): which scene revision each target has
-- adopted, when an adopted revision may be released, and what a release
-- request waits for.
--
-- This module owns the ledger and the decisions made from it, and nothing
-- native. The controller ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller")
-- adopts a scene for each target at the start of its step, reconciles releases
-- at the end of it and when a target retires, and gives the action queue
-- ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Actions") the barrier it holds a
-- release request to.
--
-- = Adoption
--
-- The owner's step hands it each constructed target's scene: the shared scene,
-- in a shared host, or the target's window's, in a per-window one. A target
-- /adopts/ it when its revision is newer than the one the target last
-- adopted, or when the target has adopted nothing yet — a window that has
-- had no publication adopts the initial scene, as revision 0, in the first
-- step after its target is constructed. Adoption does not wait for a frame:
-- a suspended or minimized window adopts, and adopting asks for no frame (a
-- frame is asked for by a publication, never by initialization). A revision
-- published and replaced before a step takes it is never adopted, and is
-- never notified.
--
-- Adopting a revision runs the lifecycle's 'sceneAdopted', handing it the
-- exact scene the step took, and only then raises the window's adopted
-- watermark, which is what a release request's barrier reads. The revision
-- the target held before is superseded.
--
-- = Release
--
-- An adopted revision is /released/ once it is superseded — a newer revision
-- was adopted for the target, or the target has ended — and every frame
-- recorded with it has a use that is over ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Rendering").
-- Nothing else releases one: not a frame's abandonment, a presentation that
-- was refused, a timeout, or the owner's retirement. A revision whose use was
-- never discharged stays awaiting release, and stays visible as such.
--
-- Releases are made in adoption order for each window: a revision is released
-- only after every revision adopted before it for the same window has been.
-- Each is removed from the ledger before its 'sceneReleased' runs, so it is
-- released exactly once, however that hook ends.
--
-- = Release requests
--
-- A release request waits for a 'Barrier' captured when it was made: for each
-- participating window, the latest revision published for it. A window
-- participates when it holds a live target, or, in a per-window host, when
-- it has had a publication — a snapshot nobody has adopted is one a release
-- must not run past. The barrier is met when, for each window it names, the
-- window's adopted watermark has reached that revision, or the host no longer
-- holds the window. A window that appears later is not named, and so delays
-- nothing.
--
-- = State
--
-- +------------------+-------------+------------------------------------+--------+-----------------------+---------------------------+
-- | State            | Owner       | Readers and writers                | Thread | Lifetime              | Reset or disposal         |
-- +==================+=============+====================================+========+=======================+===========================+
-- | The ledger       | This module | The owner's step writes; any       | Any,   | The controller's      | A target is removed when  |
-- |                  |             | thread reads, and a request's      | in STM |                       | its retirement completes; |
-- |                  |             | admission reads                    |        |                       | a record when released    |
-- +------------------+-------------+------------------------------------+--------+-----------------------+---------------------------+
-- | The scene source | This module | The composition installs it once   | Any,   | From the owner's      | Never reset               |
-- |                  |             | the owner exists; the barrier and  | in STM | creation              |                           |
-- |                  |             | the state read it                  |        |                       |                           |
-- +------------------+-------------+------------------------------------+--------+-----------------------+---------------------------+
--
-- The ledger is bounded by the host's windows and the frames in flight: a
-- target has one current record, and a superseded record stays only while
-- some frame recorded with it has a use that is not over, of which a target
-- has at most one for each frame slot.
module Hetoimasia.GPU.Vulkan.GLFW.Internal.Scenes
  ( -- * The lifecycle
    SceneLifecycle (..)
  , noSceneLifecycle

    -- * The ledger
  , Scenes
  , newScenes
  , SceneSource (..)
  , installSceneSource
  , registerSceneTarget
  , adoptScene
  , endSceneTarget
  , forgetSceneTarget
  , releaseScenes

    -- * Release requests
  , sceneBarrier
  , sceneBarrierMet

    -- * Observation
  , VulkanSceneState (..)
  , WindowSceneStanding (..)
  , readSceneState
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, writeTVar)
import Control.Monad (filterM, forM_, when)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Numeric.Natural (Natural)

import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Actions (Barrier)
import Hetoimasia.Runtime.GLFW (AttachmentId, SceneMode (..), attachmentWindow)

-- ---------------------------------------------------------------------------
-- The lifecycle

-- | What the owner tells the renderer about the scenes it holds, on the
-- owner's thread.
--
-- Neither hook may raise or wait: both run between native calls, and a hook
-- that raises ends the owner's run. Every adopted revision is announced once
-- by 'sceneAdopted' and released once by 'sceneReleased', and the two are
-- paired by window and revision. A revision can be adopted more than once —
-- once by each target that takes it, a window reattached under a new
-- attachment adopts the revision its predecessor held — and each adoption is
-- released on its own.
data SceneLifecycle scene = SceneLifecycle
  { sceneAdopted ∷ WindowId → Natural → scene → IO ()
    -- ^ A target of this window has adopted this revision, with the exact
    -- scene the owner took, which may already have been replaced by a newer
    -- publication. The owner holds what the scene references from here until
    -- the revision is released.
  , sceneReleased ∷ WindowId → Natural → IO ()
    -- ^ A revision adopted for this window has been superseded, or its target
    -- has ended, and every frame recorded with it is over: nothing the owner
    -- does will read what it references again.
  }

-- | A lifecycle that does nothing, which is what a host has unless it supplies
-- one, so that a renderer that does not care is unchanged.
noSceneLifecycle ∷ SceneLifecycle scene
noSceneLifecycle = SceneLifecycle (\_ _ _ → pure ()) (\_ _ → pure ())

-- ---------------------------------------------------------------------------
-- The ledger

-- | Where the barrier and the observation read the scenes the owner holds
-- from: installed once the owner exists.
data SceneSource = SceneSource
  { sourceMode ∷ !SceneMode
  , sourceWindows ∷ STM [WindowId]
    -- ^ The windows the host holds.
  , sourceRevisions ∷ STM (Map WindowId Natural)
    -- ^ The latest published revision of every window the host holds.
  }

data TargetScene = TargetScene
  { targetAdopted ∷ !(Maybe Natural)
  , targetEnded ∷ !Bool
  }

-- | One adopted revision that has not been released.
data Adoption = Adoption
  { adoptionAttachment ∷ !AttachmentId
  , adoptionRevision ∷ !Natural
  , adoptionSuperseded ∷ !Bool
  }

data Ledger = Ledger
  { ledgerTargets ∷ !(Map AttachmentId TargetScene)
  , ledgerAdopted ∷ !(Map WindowId Natural)
    -- ^ The highest revision any target of each window has adopted.
  , ledgerRecords ∷ ![Adoption]
    -- ^ Every adopted revision not yet released, oldest adoption first.
  }

data Scenes = Scenes
  { scenesLedger ∷ !(TVar Ledger)
  , scenesSource ∷ !(TVar (Maybe SceneSource))
  }

newScenes ∷ IO Scenes
newScenes = Scenes <$> newTVarIO (Ledger Map.empty Map.empty []) <*> newTVarIO Nothing

-- | Install where the scenes are read from, once the owner exists. Until then
-- no barrier names a window.
installSceneSource ∷ Scenes → SceneSource → STM ()
installSceneSource scenes = writeTVar (scenesSource scenes) . Just

-- | A target the roots admitted, which will adopt the scenes of its window.
registerSceneTarget ∷ Scenes → AttachmentId → STM ()
registerSceneTarget scenes attachment =
  modifyTVar' (scenesLedger scenes) $ \ledger →
    ledger {ledgerTargets = Map.insertWith (\_ held → held) attachment (TargetScene Nothing False) (ledgerTargets ledger)}

-- | Adopt this scene, at this revision, for this target, when it is newer than
-- what the target holds. Answers whether it was adopted.
--
-- The bookkeeping is complete, and the hook has run, before the window's
-- adopted watermark moves.
adoptScene ∷ Scenes → SceneLifecycle scene → AttachmentId → scene → Natural → IO Bool
adoptScene scenes lifecycle attachment scene revision = do
  taken ← atomically $ do
    ledger ← readTVar (scenesLedger scenes)
    case Map.lookup attachment (ledgerTargets ledger) of
      Just target
        | not (targetEnded target)
        , maybe True (< revision) (targetAdopted target) → do
            writeTVar (scenesLedger scenes) $
              ledger
                { ledgerTargets = Map.insert attachment target {targetAdopted = Just revision} (ledgerTargets ledger)
                , ledgerRecords = map (supersede attachment) (ledgerRecords ledger) <> [Adoption attachment revision False]
                }
            pure True
      _ → pure False
  when taken $ do
    sceneAdopted lifecycle window revision scene
    atomically $ do
      -- The watermark of a window the host no longer holds is dropped with it:
      -- a barrier treats such a window as ended without reading it.
      held ← readTVar (scenesSource scenes) >>= maybe (pure Nothing) (fmap Just . sourceWindows)
      modifyTVar' (scenesLedger scenes) $ \ledger →
        ledger
          { ledgerAdopted =
              maybe id (\windows → Map.filterWithKey (\at _ → at `elem` windows)) held $
                Map.insertWith max window revision (ledgerAdopted ledger)
          }
  pure taken
  where
    window = attachmentWindow attachment

supersede ∷ AttachmentId → Adoption → Adoption
supersede attachment record
  | adoptionAttachment record == attachment = record {adoptionSuperseded = True}
  | otherwise = record

-- | The target has ended: it adopts nothing more, and what it adopted is
-- superseded.
endSceneTarget ∷ Scenes → AttachmentId → STM ()
endSceneTarget scenes attachment =
  modifyTVar' (scenesLedger scenes) $ \ledger →
    ledger
      { ledgerTargets = Map.adjust (\target → target {targetEnded = True}) attachment (ledgerTargets ledger)
      , ledgerRecords = map (supersede attachment) (ledgerRecords ledger)
      }

-- | The target's retirement is complete. Its adopted revisions stay in the
-- ledger until they are released.
forgetSceneTarget ∷ Scenes → AttachmentId → STM ()
forgetSceneTarget scenes attachment =
  modifyTVar' (scenesLedger scenes) $ \ledger ->
    ledger {ledgerTargets = Map.delete attachment (ledgerTargets ledger)}

-- | Release every adopted revision that may be, in adoption order for each
-- window, and answer whether any was.
--
-- A revision may be when it is superseded and has no use left, given by the
-- predicate, and every revision adopted before it for its window has been
-- released. Each is removed from the ledger in one transaction with the
-- others, before the hook is run for any of them.
releaseScenes ∷ Scenes → (WindowId → Natural → IO ()) → (AttachmentId → Natural → STM Bool) → IO Bool
releaseScenes scenes released used = do
  due ← atomically $ do
    ledger ← readTVar (scenesLedger scenes)
    ready ← filterM (\record → if adoptionSuperseded record then not <$> used (adoptionAttachment record) (adoptionRevision record) else pure False) (ledgerRecords ledger)
    let readyKeys = Set.fromList [(adoptionAttachment record, adoptionRevision record) | record ← ready]
        step (blocked, out, kept) record
          | window `Set.member` blocked = (blocked, out, kept <> [record])
          | (adoptionAttachment record, adoptionRevision record) `Set.member` readyKeys = (blocked, out <> [record], kept)
          | otherwise = (Set.insert window blocked, out, kept <> [record])
          where
            window = attachmentWindow (adoptionAttachment record)
        (_, due', kept') = foldl' step (Set.empty, [], []) (ledgerRecords ledger)
    writeTVar (scenesLedger scenes) ledger {ledgerRecords = kept'}
    pure due'
  forM_ due $ \record → released (attachmentWindow (adoptionAttachment record)) (adoptionRevision record)
  pure (not (null due))

-- ---------------------------------------------------------------------------
-- Release requests

-- | The barrier a release request made now waits for, in one transaction with
-- the host's windows and their published revisions.
sceneBarrier ∷ Scenes → STM Barrier
sceneBarrier scenes =
  readTVar (scenesSource scenes) >>= \case
    Nothing → pure Map.empty
    Just source → do
      revisions ← sourceRevisions source
      ledger ← readTVar (scenesLedger scenes)
      let live =
            Set.fromList
              [ attachmentWindow attachment
              | (attachment, target) ← Map.toList (ledgerTargets ledger)
              , not (targetEnded target)
              ]
          participates window revision =
            window `Set.member` live || (sourceMode source == PerWindowScenes && revision >= 1)
      pure (Map.filterWithKey participates revisions)

-- | Whether a barrier is met: for each window it names, the window's adopted
-- watermark has reached the revision, or the host no longer holds the window.
sceneBarrierMet ∷ Scenes → Barrier → STM Bool
sceneBarrierMet scenes barrier =
  readTVar (scenesSource scenes) >>= \case
    Nothing → pure True
    Just source → do
      held ← sourceWindows source
      adopted ← ledgerAdopted <$> readTVar (scenesLedger scenes)
      pure $
        all
          (\(window, revision) → window `notElem` held || maybe False (>= revision) (Map.lookup window adopted))
          (Map.toList barrier)

-- ---------------------------------------------------------------------------
-- Observation

-- | What the owner holds of one window's scenes.
data WindowSceneStanding = WindowSceneStanding
  { windowPublished ∷ !(Maybe Natural)
    -- ^ The latest revision published for it: zero before any publication.
    -- 'Nothing' for a window the host no longer holds, whose adopted
    -- revisions may still be awaiting release.
  , windowAdopted ∷ !(Maybe Natural)
    -- ^ The highest revision any target of the window has adopted, once one
    -- has.
  , windowAwaitingRelease ∷ ![Natural]
    -- ^ The revisions adopted for it and superseded, or whose target ended,
    -- that are not yet released, in adoption order: each waits for a frame
    -- recorded with it to be discarded or to complete, or for an earlier
    -- revision of the window to be released.
  }
  deriving (Eq, Show)

-- | The owner's scene state, as any thread may read it.
data VulkanSceneState = VulkanSceneState
  { sceneWindows ∷ !(Map WindowId WindowSceneStanding)
  , sceneRequests ∷ ![Map WindowId Natural]
    -- ^ The release requests still queued, in the order they were made, each
    -- with the revision it awaits from each window.
  }
  deriving (Eq, Show)

-- | The window-by-window state, given the barriers of the release requests
-- still queued.
readSceneState ∷ Scenes → STM [Barrier] → STM VulkanSceneState
readSceneState scenes pending = do
  ledger ← readTVar (scenesLedger scenes)
  published ← readTVar (scenesSource scenes) >>= maybe (pure Map.empty) sourceRevisions
  requests ← pending
  let awaiting = Map.fromListWith (flip (<>)) [(attachmentWindow (adoptionAttachment record), [adoptionRevision record]) | record ← ledgerRecords ledger, adoptionSuperseded record]
      windows = Set.unions [Map.keysSet published, Map.keysSet (ledgerAdopted ledger), Map.keysSet awaiting]
      standing window =
        WindowSceneStanding
          { windowPublished = Map.lookup window published
          , windowAdopted = Map.lookup window (ledgerAdopted ledger)
          , windowAwaitingRelease = fromMaybe [] (Map.lookup window awaiting)
          }
  pure (VulkanSceneState (Map.fromSet standing windows) requests)
