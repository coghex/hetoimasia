-- | Recovering a target's lost surface on its same live window, for the
-- swapchain generations ("Hetoimasia.GPU.Vulkan.Native.Generations"), on the
-- graphics owner's thread (VK-14, D-24).
--
-- A surface found lost — a swapchain call reported it, or the surface's query
-- or a swapchain's creation raised it — has already had its active generation
-- retired by the reconciliation, which builds nothing on it again. From there:
--
-- 1. every generation of the target goes as its holds end, through the
--    ordinary disposal: its acquired and submitted frames and its pending
--    presentations settle on their own evidence, and nothing is waited on or
--    replayed;
-- 2. only once none remains is the lost surface destroyed, through the roots
--    ('releaseRootSurface'), which keep the target — its identity, its
--    designation and, above it, its window's attachment, which is never
--    released or reattached;
-- 3. the model's episode is asked for an attempt ('beginTargetRecovery'): a
--    deferred one waits for its deadline, and a spent one leaves the target
--    'RecoverySpent', disposed of through its designation. An admitted one
--    makes the target 'SurfaceReplacing' and is answered by
--    'releaseLostSurfaces', for whoever can create a surface on the window's
--    main thread to create one;
-- 4. the replacement is offered ('offerReplacementSurface'). The roots check
--    that the session's one device and queue family can still present to it,
--    and install it, and the next construction builds a fresh generation on it
--    — handing nothing over — whose publication or failure settles the
--    attempt. A surface the device cannot present to is not migrated anywhere:
--    the attempt fails, and the target is declared unrecoverable
--    ('declareTargetUnrecoverable') — an optional one unavailable while every
--    other target continues, a required one failing the session. A failed
--    creation, or a surface that must not be used, fails the attempt
--    ('replacementSurfaceFailed'), and the episode schedules the next.
--
-- Close wins throughout: a target that has begun retiring asks for nothing, is
-- offered nothing — a replacement offered after the close stays its creator's,
-- to destroy — and its retirement settles an attempt still outstanding, which
-- then decides nothing. Repeated loss spends the same episode, which only a
-- completed presentation-retirement cycle and a healthy second replenish.
--
-- This module advances target records — their condition, surface, loss and
-- outstanding attempt — in "Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State",
-- and owns no state of its own.
module Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Surface
  ( releaseLostSurfaces
  , ReplacementAnswer (..)
  , offerReplacementSurface
  , replacementSurfaceFailed
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar, readTVarIO)
import Control.Monad (forM, when)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word32)

import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GPU.Model
  ( GpuModel
  , Outcome (..)
  , RecoveryAnswer (..)
  , SessionFailureCause (RequiredTargetUnrecoverable)
  , SessionState (..)
  , TargetPhase (..)
  , TargetView (..)
  , beginTargetRecovery
  , declareTargetUnrecoverable
  , recordRecoveryFailure
  , sessionState
  , targetView
  )
import Hetoimasia.GPU.Model.Identity (TargetId)
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State
  ( Generations (..)
  , TargetCondition (..)
  , TargetRecord (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Profile (TargetRejection (..))
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( TargetSurface (..)
  , installRootSurface
  , releaseRootSurface
  , rootSurfaceHeld
  , stateRootsModel
  )

-- | Advance every target whose surface was lost: once every generation of it
-- has been destroyed, destroy the lost surface and ask the episode for an
-- attempt. Answers the targets whose attempt it just admitted, each of which
-- now wants a replacement surface.
--
-- A destruction of the lost surface that did not complete raises
-- 'Hetoimasia.GPU.Vulkan.Native.Roots.SurfaceDestructionFailed', having failed
-- the session: unproven rollback forbids any further attempt, and the surface,
-- the device and the instance are retained.
releaseLostSurfaces ∷ Generations q inst msgr phys dev → Instant → IO [TargetId]
releaseLostSurfaces generations now = do
  records ← Map.toList <$> readTVarIO (generationsTargets generations)
  concat <$> forM [(target, record) | (target, record) ← records, recordSurfaceLost record] advance
  where
    roots = generationsRoots generations
    advance (target, record) = do
      model ← atomically (readModel generations)
      let open = maybe False ((`notElem` [TargetRetiring, TargetUnavailable]) . viewTargetPhase) (targetView target model)
      if not open || sessionState model /= SessionRunning || waiting (recordCondition record) || not (Map.null (recordGenerations record))
        then pure []
        else do
          held ← atomically (rootSurfaceHeld roots target)
          when held (releaseRootSurface roots target)
          answer ← atomically $ stateRootsModel roots $ \current → case beginTargetRecovery now target current of
            Admitted (next, value) → (Just value, next)
            _ → (Nothing, current)
          atomically $ case answer of
            Just (RecoveryAttempt _) → [target] <$ edit generations target (\entry → entry {recordRecovering = True, recordCondition = SurfaceReplacing})
            Just (RecoveryDeferred at) → [] <$ edit generations target (\entry → entry {recordCondition = RecoveryWaiting at})
            Just (RecoveryExhausted _) → [] <$ edit generations target (\entry → entry {recordCondition = RecoverySpent})
            _ → pure []
    -- An attempt already outstanding, or an episode already spent, asks for
    -- nothing more.
    waiting = \case
      SurfaceReplacing → True
      RecoverySpent → True
      _ → False

-- | What an offered replacement surface became.
data ReplacementAnswer
  = ReplacementInstalled
    -- ^ The roots own it as the target's surface, and the next step builds a
    -- fresh generation on it, whose outcome settles the attempt.
  | ReplacementUnsupported !Word32
    -- ^ The session's queue family cannot present to it, and no other device
    -- is used. It is still its creator's, to destroy. The attempt failed and
    -- the target was disposed of through its designation.
  | ReplacementNotWanted
    -- ^ The target is not waiting for one: close won, or the roots admit
    -- nothing more. It is still its creator's, to destroy, and an attempt
    -- still outstanding is settled by the target's retirement.
  deriving (Eq, Show)

-- | Offer a replacement surface, created on the target's same window, to the
-- target an admitted attempt is waiting for one for.
offerReplacementSurface ∷ Generations q inst msgr phys dev → Instant → TargetId → TargetSurface → IO ReplacementAnswer
offerReplacementSurface generations now target surface = do
  record ← Map.lookup target <$> readTVarIO (generationsTargets generations)
  case record of
    Just entry
      | recordSurfaceLost entry, recordCondition entry == SurfaceReplacing →
          installRootSurface (generationsRoots generations) target surface >>= \case
            Right () → do
              atomically $
                edit generations target $ \held →
                  held
                    { recordSurface = targetSurfaceHandle surface
                    , recordSurfaceLost = False
                    , recordCondition = AwaitingGeneration
                    , recordFailed = False
                    , recordSettling = Nothing
                    , recordLastPlanned = Nothing
                    , -- Nothing has been built on this surface: its first
                      -- generation is built at once, as a target's first is,
                      -- and the owner is asked for the step that builds it.
                      recordConstructions = 0
                    , recordResultUnseen = True
                    , recordResult = Nothing
                    }
              pure ReplacementInstalled
            Left (TargetSurfaceUnsupported family) → do
              atomically $ do
                settle generations now target
                _ ← stateRootsModel (generationsRoots generations) $ \model → case declareTargetUnrecoverable target model of
                  Admitted (next, _) → ((), next)
                  _ → ((), model)
                edit generations target (\held → held {recordCondition = RecoverySpent})
              pure (ReplacementUnsupported family)
            Left _ → pure ReplacementNotWanted
    _ → pure ReplacementNotWanted

-- | The replacement an admitted attempt waited for was not created, or was
-- created unusable and has been destroyed by its creator: the attempt failed,
-- and the episode schedules the next — or, at its last, is spent.
replacementSurfaceFailed ∷ Generations q inst msgr phys dev → Instant → TargetId → Text → IO ()
replacementSurfaceFailed generations now target _ = atomically $ do
  record ← Map.lookup target <$> readTVar (generationsTargets generations)
  case record of
    Just entry | recordSurfaceLost entry, recordCondition entry == SurfaceReplacing → do
      settle generations now target
      model ← readModel generations
      let spent =
            maybe False ((== TargetUnavailable) . viewTargetPhase) (targetView target model)
              || sessionState model == SessionFailed RequiredTargetUnrecoverable
      edit generations target (\held → held {recordCondition = if spent then RecoverySpent else SurfaceLost})
    _ → pure ()

-- | Report the outstanding attempt failed, and clear it.
settle ∷ Generations q inst msgr phys dev → Instant → TargetId → STM ()
settle generations now target = do
  stateRootsModel (generationsRoots generations) $ \model → case recordRecoveryFailure now target model of
    Admitted next → ((), next)
    _ → ((), model)
  edit generations target (\held → held {recordRecovering = False})

edit ∷ Generations q inst msgr phys dev → TargetId → (TargetRecord → TargetRecord) → STM ()
edit generations target change = modifyTVar' (generationsTargets generations) (Map.adjust change target)

readModel ∷ Generations q inst msgr phys dev → STM GpuModel
readModel generations = stateRootsModel (generationsRoots generations) (\model → (model, model))
