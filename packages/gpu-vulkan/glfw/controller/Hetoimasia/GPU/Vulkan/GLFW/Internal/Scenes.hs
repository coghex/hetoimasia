-- | The scene ledger (D-28, D-30): which scene revision each target has
-- adopted, when an adopted revision may be released, and what a release
-- request waits for.
--
-- Everything here is keyed by 'SceneTargetKey' (LFE-27): a window, or an
-- offscreen target registered with the host
-- ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Targets"). The ledger's records are
-- kept by what adopted them, an 'Adopter' — one window attachment, or the one
-- offscreen target — so a window reattached under a new attachment still adopts
-- again and each adoption is accounted on its own, while the barrier, the
-- lifecycle and the observation speak of the key. Wherever the text below says
-- /window/ of a barrier, a revision or a release, it holds for an offscreen
-- target in the same words: an offscreen target is a scene target with no
-- window.
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
-- the target held before is superseded. The whole transition — the ledger's
-- record, the hook and the watermark — runs uninterruptibly, so a
-- cancellation of the owner lands before it or after it and never inside:
-- every adoption that is recorded has been notified, and every notified one
-- is on the ledger to be released.
--
-- A target holds a finite number of unreleased revisions (D-28's pressure):
-- its current one and the superseded ones still awaiting release, bounded by
-- 'retentionLimit'. A target at its limit adopts nothing newer. The step
-- skips its frame, keeps the window's demand, and tries again once a release
-- has made room; the publication itself never waits, and the window's snapshot
-- keeps the latest scene meanwhile.
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
-- released exactly once, and the removal and the hooks of one pass run
-- uninterruptibly together, so a cancellation never loses a notification
-- between them.
--
-- = Release requests
--
-- A release request waits for a 'Barrier' captured when it was made: for every
-- window the host holds, the latest revision published for it — the initial
-- scene's revision 0 for a window with no publication, whether or not it has
-- a target yet, since a window attached later adopts the scene it holds and
-- must find what it references still there. The barrier is met when, for each
-- window it names, the revision a live target of the window holds has reached
-- that revision,
-- or the host no longer holds the window. A window that appears later is not
-- named, and so delays nothing.
--
-- A host may declare that its initial scene references nothing a release
-- request releases ('newScenes'). Then the barrier a request captures leaves
-- out every window whose latest revision is 0 — in a per-window host a window
-- with no publication, in a shared host every window while the shared scene is
-- unpublished — because a target adopting the initial scene later finds
-- nothing there that a release could have freed. This applies to the barrier
-- captured with a request and to nothing else: the observation still reports
-- revision 0 as the window's published revision, and every other window is
-- named as before, with or without a live target. In particular a window that
-- has had a publication, with no live target, is still named: a target of it
-- adopts that publication later, and what it references must not have been
-- freed. It holds every later request until a target of it adopts the
-- barrier's revision (the watermark of a target that ended counts for nothing)
-- or the host drops the window, and the observation shows it through the
-- request's barrier and the window's adopted revision. It is for the
-- application to resolve: attach a target, or close the window. A publication
-- of another blank scene creates a positive revision, so it is named too.
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
-- The ledger is bounded: a target holds at most 'retentionLimit' records, and
-- the host's windows and the registered offscreen targets bound the targets:
-- 'scenesOccupants' counts a registered target and a retired one that still has
-- an unreleased record alike, so the host can refuse a registration once their
-- number reaches its finite capacity without touching the windows'.
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
  , scenesOccupants
  , adopterAtLimit
  , Adopting (..)
  , retentionLimit
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
import Control.Exception (uninterruptibleMask_)
import Control.Monad (filterM, forM_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Functor ((<&>))
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Vulkan.GLFW.Internal.Actions (Barrier)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Target (Adopter (..), OffscreenTargetId, SceneTargetKey (..), adopterKey)
import Hetoimasia.Runtime.GLFW (SceneMode (..))

-- ---------------------------------------------------------------------------
-- The lifecycle

-- | What the owner tells the renderer about the scenes it holds, on the
-- owner's thread.
--
-- Neither hook may raise or wait: both run between native calls, and a hook
-- that raises ends the owner's run. Every adopted revision is announced once
-- by 'sceneAdopted' and released once by 'sceneReleased', and the two are
-- paired by scene target and revision. A revision can be adopted more than once —
-- once by each target that takes it, a window reattached under a new
-- attachment adopts the revision its predecessor held — and each adoption is
-- released on its own.
data SceneLifecycle scene = SceneLifecycle
  { sceneAdopted ∷ SceneTargetKey → Natural → scene → IO ()
    -- ^ A target of this window, or this offscreen target, has adopted this
    -- revision, with the exact scene the owner took, which may already have
    -- been replaced by a newer publication. The owner holds what the scene
    -- references from here until the revision is released.
  , sceneReleased ∷ SceneTargetKey → Natural → IO ()
    -- ^ A revision adopted for this window or offscreen target has been
    -- superseded, or its target has ended, and every frame or batch recorded
    -- with it is over: nothing the owner does will read what it references
    -- again.
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
  , sourceHeld ∷ STM [SceneTargetKey]
    -- ^ The scene targets the host holds: its windows, and the offscreen
    -- targets registered with it.
  , sourceRevisions ∷ STM (Map SceneTargetKey Natural)
    -- ^ The latest published revision of every scene target the host holds.
  }

data TargetScene = TargetScene
  { targetAdopted ∷ !(Maybe Natural)
    -- ^ The highest revision the target has adopted, recorded before the hook
    -- runs, which is what gates a further adoption.
  , targetHeld ∷ !(Maybe Natural)
    -- ^ The highest revision the target has adopted and notified, once its
    -- hook has returned: what it holds, as a release barrier reads it. It
    -- stops counting the moment the target ends.
  , targetEnded ∷ !Bool
  }

-- | One adopted revision that has not been released.
data Adoption = Adoption
  { adoptionAdopter ∷ !Adopter
  , adoptionRevision ∷ !Natural
  , adoptionSuperseded ∷ !Bool
  }

data Ledger = Ledger
  { ledgerTargets ∷ !(Map Adopter TargetScene)
  , ledgerRecords ∷ ![Adoption]
    -- ^ Every adopted revision not yet released, oldest adoption first.
  , ledgerDeferred ∷ !(Map SceneTargetKey Natural)
    -- ^ For each scene target, how many adoptions a target of it deferred at
    -- its retention limit.
  }

data Scenes = Scenes
  { scenesLedger ∷ !(TVar Ledger)
  , scenesSource ∷ !(TVar (Maybe SceneSource))
  , scenesInitialEmpty ∷ !Bool
    -- ^ Whether the host declared that its initial scene references nothing a
    -- release request releases.
  }

-- | An empty ledger, for a host that declares, with 'True', that its initial
-- scene references nothing a release request releases, so that a window still
-- at the initial scene's revision 0 is left out of every barrier. With 'False'
-- every window the host holds is named.
newScenes ∷ Bool → IO Scenes
newScenes initialEmpty = (\ledger source → Scenes ledger source initialEmpty) <$> newTVarIO (Ledger Map.empty [] Map.empty) <*> newTVarIO Nothing

-- | Install where the scenes are read from, once the owner exists. Until then
-- no barrier names a window.
installSceneSource ∷ Scenes → SceneSource → STM ()
installSceneSource scenes = writeTVar (scenesSource scenes) . Just

-- | A target the roots admitted, which will adopt the scenes of its window, or
-- an offscreen target the host registered, which will adopt its own.
registerSceneTarget ∷ Scenes → Adopter → STM ()
registerSceneTarget scenes adopter =
  modifyTVar' (scenesLedger scenes) $ \ledger →
    ledger {ledgerTargets = Map.insertWith (\_ held → held) adopter (TargetScene Nothing Nothing False) (ledgerTargets ledger)}

-- | The offscreen targets the ledger still accounts for: those it holds a
-- target entry for, and those with an adopted revision not yet released, so a
-- retired target whose last use is uncertain counts until it is released.
scenesOccupants ∷ Scenes → STM (Set.Set OffscreenTargetId)
scenesOccupants scenes = do
  ledger ← readTVar (scenesLedger scenes)
  pure . Set.fromList $
    [target | TargetAdopter target ← Map.keys (ledgerTargets ledger)]
      <> [target | record ← ledgerRecords ledger, TargetAdopter target ← [adoptionAdopter record]]

-- | What adopting a scene for a target came to.
data Adopting
  = Adopted
    -- ^ The target adopted it now.
  | AlreadyHeld
    -- ^ The target holds this revision or a newer one, or has ended: there is
    -- nothing to adopt.
  | AtLimit
    -- ^ The target holds as many unreleased revisions as it may. Nothing was
    -- adopted, and a later attempt may be.
  deriving (Eq, Show)

-- | How many unreleased revisions one target may hold for a host whose targets
-- have this many frame slots: the revisions frames in flight can reference,
-- and the current one, and as many again waiting behind them in adoption
-- order. It is derived from the budgets, not chosen, so the frames the host
-- may keep in flight never reach it before the owner has been told.
retentionLimit ∷ Natural → Natural
retentionLimit slots = 2 * (slots + 1)

-- | Whether this adopter holds as many unreleased revisions as the limit allows,
-- so that it adopts nothing newer until a release makes room.
adopterAtLimit ∷ Scenes → Natural → Adopter → STM Bool
adopterAtLimit scenes limit adopter = do
  ledger ← readTVar (scenesLedger scenes)
  pure (fromIntegral (length (filter ((== adopter) . adoptionAdopter) (ledgerRecords ledger))) >= limit)

-- | Adopt this scene, at this revision, for this target, when it is newer than
-- what the target holds and the target is below its retention limit.
--
-- The ledger's record, the hook and the watermark are one uninterruptible
-- transition; the hook has run, and the bookkeeping is complete, before the
-- revision counts as held for a barrier.
adoptScene ∷ Scenes → SceneLifecycle scene → Natural → Adopter → scene → Natural → IO Adopting
adoptScene scenes lifecycle limit adopter scene revision = uninterruptibleMask_ $ do
  answer ← atomically $ do
    ledger ← readTVar (scenesLedger scenes)
    case Map.lookup adopter (ledgerTargets ledger) of
      Just target
        | not (targetEnded target)
        , maybe True (< revision) (targetAdopted target) →
            if fromIntegral (length (filter ((== adopter) . adoptionAdopter) (ledgerRecords ledger))) >= limit
              then do
                writeTVar (scenesLedger scenes) ledger {ledgerDeferred = Map.insertWith (+) key 1 (ledgerDeferred ledger)}
                pure AtLimit
              else do
                writeTVar (scenesLedger scenes) $
                  ledger
                    { ledgerTargets = Map.insert adopter target {targetAdopted = Just revision} (ledgerTargets ledger)
                    , ledgerRecords = map (supersede adopter) (ledgerRecords ledger) <> [Adoption adopter revision False]
                    }
                pure Adopted
      _ → pure AlreadyHeld
  case answer of
    Adopted → do
      sceneAdopted lifecycle key revision scene
      atomically $ do
        held ← readTVar (scenesSource scenes) >>= maybe (pure Nothing) (fmap Just . sourceHeld)
        modifyTVar' (scenesLedger scenes) $ \ledger →
          ledger
            { -- Only now does the target hold the revision for a barrier.
              ledgerTargets = Map.adjust (\target → target {targetHeld = Just revision}) adopter (ledgerTargets ledger)
            , ledgerDeferred = maybe id (\windows → Map.filterWithKey (\at _ → at `elem` windows)) held (ledgerDeferred ledger)
            }
    _ → pure ()
  pure answer
  where
    key = adopterKey adopter

supersede ∷ Adopter → Adoption → Adoption
supersede adopter record
  | adoptionAdopter record == adopter = record {adoptionSuperseded = True}
  | otherwise = record

-- | The target has ended: it adopts nothing more, and what it adopted is
-- superseded.
endSceneTarget ∷ Scenes → Adopter → STM ()
endSceneTarget scenes adopter =
  modifyTVar' (scenesLedger scenes) $ \ledger →
    ledger
      { ledgerTargets = Map.adjust (\target → target {targetEnded = True}) adopter (ledgerTargets ledger)
      , ledgerRecords = map (supersede adopter) (ledgerRecords ledger)
      }

-- | The target's retirement is complete. Its adopted revisions stay in the
-- ledger until they are released.
forgetSceneTarget ∷ Scenes → Adopter → STM ()
forgetSceneTarget scenes adopter =
  modifyTVar' (scenesLedger scenes) $ \ledger →
    ledger {ledgerTargets = Map.delete adopter (ledgerTargets ledger)}

-- | Release every adopted revision that may be, in adoption order for each
-- window, and answer whether any was.
--
-- A revision may be when it is superseded and has no use left, given by the
-- predicate, and every revision adopted before it for its window has been
-- released. Each is removed from the ledger in one transaction with the
-- others, before the hook is run for any of them.
releaseScenes ∷ Scenes → (SceneTargetKey → Natural → IO ()) → (Adopter → Natural → STM Bool) → IO Bool
releaseScenes scenes released used = uninterruptibleMask_ $ do
  due ← atomically $ do
    ledger ← readTVar (scenesLedger scenes)
    ready ← filterM (\record → if adoptionSuperseded record then not <$> used (adoptionAdopter record) (adoptionRevision record) else pure False) (ledgerRecords ledger)
    let readyKeys = Set.fromList [(adoptionAdopter record, adoptionRevision record) | record ← ready]
        step (blocked, out, kept) record
          | key `Set.member` blocked = (blocked, out, kept <> [record])
          | (adoptionAdopter record, adoptionRevision record) `Set.member` readyKeys = (blocked, out <> [record], kept)
          | otherwise = (Set.insert key blocked, out, kept <> [record])
          where
            key = adopterKey (adoptionAdopter record)
        (_, due', kept') = foldl' step (Set.empty, [], []) (ledgerRecords ledger)
    writeTVar (scenesLedger scenes) ledger {ledgerRecords = kept'}
    pure due'
  forM_ due $ \record → released (adopterKey (adoptionAdopter record)) (adoptionRevision record)
  pure (not (null due))

-- ---------------------------------------------------------------------------
-- Release requests

-- | The barrier a release request made now waits for, in one transaction with
-- the host's windows and their published revisions: every window the host
-- holds, at the latest revision published for it — except, for a host that
-- declared its initial scene holds nothing, a window whose latest revision is
-- 0. Only this barrier leaves those windows out; 'readSceneState' does not.
sceneBarrier ∷ Scenes → STM Barrier
sceneBarrier scenes =
  readTVar (scenesSource scenes) >>= \case
    Nothing → pure Map.empty
    Just source →
      sourceRevisions source <&> \revisions →
        if scenesInitialEmpty scenes then Map.filter (> 0) revisions else revisions

-- | The highest revision a live target of each window holds. A target that has
-- ended holds nothing: a window whose adopting target was detached or released
-- has no hold until another adoption replaces it, however long ago its
-- revision was adopted, since the revision it published is one a later target
-- will adopt.
liveWatermark ∷ Ledger → Map SceneTargetKey Natural
liveWatermark ledger =
  Map.fromListWith
    max
    [ (adopterKey adopter, revision)
    | (adopter, target) ← Map.toList (ledgerTargets ledger)
    , not (targetEnded target)
    , Just revision ← [targetHeld target]
    ]

-- | Whether a barrier is met: for each window it names, the window's adopted
-- watermark has reached the revision, or the host no longer holds the window.
sceneBarrierMet ∷ Scenes → Barrier → STM Bool
sceneBarrierMet scenes barrier =
  readTVar (scenesSource scenes) >>= \case
    Nothing → pure True
    Just source → do
      held ← sourceHeld source
      adopted ← liveWatermark <$> readTVar (scenesLedger scenes)
      pure $
        all
          (\(key, revision) → key `notElem` held || maybe False (>= revision) (Map.lookup key adopted))
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
    -- ^ The highest revision a live target of the window holds, once it has
    -- adopted one: the barrier's watermark. A window whose adopting target has
    -- ended holds none until another adopts.
  , windowDeferrals ∷ !Natural
    -- ^ How many times a target of it, at its retention limit, deferred
    -- adopting a newer revision: the positive sign that pressure held an
    -- adoption back.
  , windowAwaitingRelease ∷ ![Natural]
    -- ^ The revisions adopted for it and superseded, or whose target ended,
    -- that are not yet released, in adoption order: each waits for a frame
    -- recorded with it to be discarded or to complete, or for an earlier
    -- revision of the window to be released.
  }
  deriving (Eq, Show)

-- | The owner's scene state, as any thread may read it.
data VulkanSceneState = VulkanSceneState
  { sceneWindows ∷ !(Map SceneTargetKey WindowSceneStanding)
    -- ^ For each scene target — each window, and each offscreen target
    -- registered with the host — what the owner holds of its scenes. The
    -- names say /window/ for the contract they have always had; an offscreen
    -- target reads the same fields.
  , sceneRequests ∷ ![Map SceneTargetKey Natural]
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
  let awaiting = Map.fromListWith (flip (<>)) [(adopterKey (adoptionAdopter record), [adoptionRevision record]) | record ← ledgerRecords ledger, adoptionSuperseded record]
      holding = liveWatermark ledger
      windows = Set.unions [Map.keysSet published, Map.keysSet holding, Map.keysSet awaiting, Map.keysSet (ledgerDeferred ledger)]
      standing window =
        WindowSceneStanding
          { windowPublished = Map.lookup window published
          , windowAdopted = Map.lookup window holding
          , windowDeferrals = Map.findWithDefault 0 window (ledgerDeferred ledger)
          , windowAwaitingRelease = fromMaybe [] (Map.lookup window awaiting)
          }
  pure (VulkanSceneState (Map.fromSet standing windows) requests)
