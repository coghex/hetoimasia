-- | The graphics owner's worker progress: its run action, its rounds, the one
-- step it offers the backend each round, and its wait between rounds.
--
-- Everything here runs on the owner thread. It reads the handoff, the host's
-- read-only pending and retiring sets, and the backend's injected operations,
-- and reaches the main thread only through the authorized wake. It imports
-- neither the client-side handover nor the protected lifetime: the target
-- work each round performs is in "Hetoimasia.Runtime.GLFW.Internal.Owner.Targets"
-- and "Hetoimasia.Runtime.GLFW.Internal.Owner.Terminal", and the drain every
-- run ends through is in "Hetoimasia.Runtime.GLFW.Internal.Owner.Drain".
--
-- 'offerStep' and 'ownerWait' are kept together on purpose: the step records
-- the revisions it read in the same transaction it read its inputs in, and the
-- wait's predicates compare against exactly those revisions.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Worker
  ( runOwnerAction
  ) where

import Control.Concurrent.STM (STM, atomically, check, readTVar, readTVarIO, writeTVar)
import Control.Exception (evaluate, finally, mask, tryWithContext)
import Control.Monad (unless)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Hetoimasia.Foundation.Time (Instant, deadlineReached, readInstant, remainingUntil)
import Hetoimasia.Foundation.Worker (StopToken, stopRequested)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Config (GraphicsOwnerConfig (..), OwnerTimer (..))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Drain (ownerDrain, settleOwnerOutcome)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Evidence (HasEvidence (..))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff
  ( OwnerPhase (OwnerRunning)
  , OwnerStatus (statusNextDeadline)
  , TargetObservation (targetRevision)
  , closeOwnerPublications
  , noTargetGeometry
  , pendingTargetEvents
  , readOwnerDemandAt
  , readOwnerSceneAt
  , readOwnerStatus
  , readTargetObservations
  , recordOwnerEnded
  , recordOwnerStarted
  , writeOwnerPhase
  , writeOwnerProgress
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Latch (latchFailure)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Operations
  ( GraphicsOperations (..)
  , NextDeadline (..)
  , OwnerStart (OwnerStart)
  , OwnerStep (OwnerStep)
  , StepReport (..)
  , TargetStepView (..)
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.State
  ( GraphicsOwner (..)
  , TargetState (..)
  , constructed
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Targets
  ( constructPending
  , foldHostRetirements
  , foldObservations
  , retirementsBegun
  , takeLifetimeEvents
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Terminal
  ( forgetValidatedTargets
  , publishOwed
  , retireReleased
  , validatedTargets
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Wake (wakeGraphicsHost)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Withhold (applyWithholding, endStepPresenting, recordStepPresenting)
import Hetoimasia.Runtime.GLFW.Internal.RenderDemand (RenderEligibility (RenderSuspended))

-- | The owner's whole run: the protected retirement, the body, and the settled
-- outcome.
runOwnerAction ∷ GraphicsOwner scene → StopToken → IO ()
runOwnerAction owner token = mask $ \restore → do
  -- The protected retirement is installed here, first, before a single
  -- dependent is constructed: from this line on, every way this action can end
  -- — an expected stop, a startup failure, a run failure, and a cancellation —
  -- leaves through the same drain.
  outcome ← tryWithContext (restore (ownerRun owner token))
  -- No step runs again: a hide need wait for none, whatever ended the run.
  atomically (endStepPresenting owner)
  latchFailure owner outcome
  -- Unconditionally, and before the drain takes its final backlog: a normal
  -- stop ends the run without a failure to latch, and 'graphicsOwnerWorker'
  -- is public, so any caller can cause one. Closing here is what makes that
  -- single take sound — nothing can be admitted after it, so nothing can be
  -- admitted that the take will miss.
  atomically (closeOwnerPublications (ownerHandoff' owner))
  started ← readTVarIO (ownerStarted owner)
  drained ← ownerDrain owner restore started
  atomically (recordOwnerEnded (ownerHandoff' owner))
  wakeGraphicsHost owner
  settleOwnerOutcome outcome drained

-- | The owner's own body: start the backend, then take rounds until a stop.
ownerRun ∷ GraphicsOwner scene → StopToken → IO ()
ownerRun owner token = do
  -- The call is interruptible and the record of what it returned is not. A
  -- cancellation delivered between the two would discard evidence the backend
  -- really established, and the drain would then be told that a started owner
  -- was never started.
  mask $ \restore → do
    ready ← restore (graphicsStartOwner operations (OwnerStart (ownerLabel (ownerSettings owner))) >>= evaluate)
    ownerSettled owner
    -- Recorded exactly as it came back, and as /status/ rather than anywhere
    -- that could be mistaken for permission: what a successful startup
    -- establishes is that whole-owner retirement and destruction have
    -- something to act on, which the drain is told separately. It stays
    -- readable through retirement and after the owner has ended.
    atomically $ do
      recordOwnerStarted (ownerHandoff' owner) (evidenceDetail ready)
      writeTVar (ownerStarted owner) True
      writeOwnerPhase (ownerHandoff' owner) OwnerRunning
  wakeGraphicsHost owner
  loop
  where
    operations = ownerOperations (ownerSettings owner)
    loop = do
      ending ← atomically (ownerEnding owner token)
      unless ending $ do
        immediate ← ownerRound owner token
        unless immediate (ownerWait owner token)
        loop

-- | One bounded round: take the lifetime events, construct what is owed, fold
-- the observations, retire what was released, publish what is owed, and offer
-- the backend one step.
--
-- It answers whether another round is owed at once.
ownerRound ∷ GraphicsOwner scene → StopToken → IO Bool
ownerRound owner token = do
  takeLifetimeEvents owner
  foldHostRetirements owner
  constructPending owner
  foldObservations owner
  retireReleased owner
  publishOwed owner
  forgetValidatedTargets owner
  ending ← atomically (ownerEnding owner token)
  if ending
    then pure True
    else do
      (report, deadline) ← offerStep owner
      atomically
        ( writeOwnerProgress
            (ownerHandoff' owner)
            (stepAdvanced report)
            (stepImmediateWork report)
            (deadlineInstant deadline)
        )
      wakeGraphicsHost owner
      pure (stepImmediateWork report)

-- | Whether this round is the owner's last: its owner asked it to stop, or a
-- failure its disposition calls terminal has been latched.
--
-- A latched required failure ends the run action exactly as a stop does, which
-- is what takes the owner into the protected drain rather than leaving it
-- running with a failure recorded behind it.
ownerEnding ∷ GraphicsOwner scene → StopToken → STM Bool
ownerEnding owner token = do
  stopping ← stopRequested token
  latched ← isJust <$> readTVar (ownerLatch owner)
  pure (stopping || latched)

deadlineInstant ∷ NextDeadline → Maybe Instant
deadlineInstant = \case
  NoOwnerDemand → Nothing
  OwnerDeadline due → Just due

-- | Offer the backend one bounded step, and ask it for its next deadline.
--
-- Everything the step is given is read in one transaction, so a backend never
-- sees one target's observation from this round beside another's from the
-- last. The presentation holds are applied in that same transaction
-- ("Hetoimasia.Runtime.GLFW.Internal.Owner.Withhold"): a held target is viewed
-- as suspended, and the set of targets the step may present to stands until
-- it returns. That set is recorded and its clearing installed under one mask,
-- and only the step itself is interruptible, so no cancellation can leave a
-- target in it for a hide to wait on.
offerStep ∷ GraphicsOwner scene → IO (StepReport, NextDeadline)
offerStep owner = do
  now ← readInstant (ownerClock owner)
  report ← mask $ \restore → do
    (scene, sceneRevision, demand, demandRevision, views) ← atomically $ do
      (scene, sceneRevision) ← readOwnerSceneAt handoff
      (demand, demandRevision) ← readOwnerDemandAt handoff
      withheld ← applyWithholding owner
      states ← readTVar (ownerTargets owner)
      geometry ← readTVar (ownerGeometryCells owner)
      -- Recorded in the same transaction the step's inputs were read in, so
      -- the wait below can never conclude that a publication this step did
      -- not see has already been folded.
      writeTVar (ownerSeenInputs owner) (demandRevision, sceneRevision)
      let views = map (stepView geometry withheld) (Map.toAscList states)
      recordStepPresenting owner views
      pure (scene, sceneRevision, demand, demandRevision, views)
    restore (graphicsStep operations (OwnerStep now scene sceneRevision demand demandRevision views) >>= evaluate)
      `finally` atomically (endStepPresenting owner)
  deadline ← graphicsNextDeadline operations >>= evaluate
  pure (report, deadline)
  where
    handoff = ownerHandoff' owner
    operations = ownerOperations (ownerSettings owner)
    stepView geometry withheld (target, state) =
      TargetStepView
        { viewTarget = target
        , viewEligibility = if Set.member target withheld then RenderSuspended else targetEligible state
        , viewGeometry = Map.findWithDefault noTargetGeometry target geometry
        , viewRevision = targetSeen state
        , viewConstructed = constructed (targetConstruction state)
        , viewWithdrawals = targetWithdrawals state
        }

-- | Wait for the next thing worth a round: a stop, a lifetime event, a fresher
-- observation, newly published demand or a newer scene, or the owner's own
-- deadline.
--
-- The owner's deadlines are its own: nothing here waits for the main thread to
-- wake it, so a main loop that never posts an event, and a main thread stalled
-- in a platform modal loop, neither starve the owner nor delay a deadline it
-- set for itself.
ownerWait ∷ GraphicsOwner scene → StopToken → IO ()
ownerWait owner token = do
  status ← atomically (readOwnerStatus handoff)
  expired ← case statusNextDeadline status of
    Nothing → pure (pure False)
    Just due → do
      now ← readInstant (ownerClock owner)
      if deadlineReached now due then pure (pure True) else arm (remainingUntil now due)
  atomically $ do
    stopping ← stopRequested token
    failing ← isJust <$> readTVar (ownerLatch owner)
    queued ← (> 0) <$> pendingTargetEvents handoff
    fresher ← observationsAdvanced owner
    published ← inputsAdvanced owner
    -- An attachment that has just validated the facts one of the owner's
    -- records established is work of the owner's own: the round that follows
    -- releases the cells that record was holding. Without it those cells
    -- would wait for some unrelated reason to wake the owner, and a host
    -- whose windows are all idle would give it none.
    prunable ← not . null <$> validatedTargets owner
    -- A window closed from the main thread begins its attachment's retirement
    -- without an event, so an idle owner has to wake for that too.
    closing ← retirementsBegun owner
    -- Something the backend watches on another thread, which no event of the
    -- owner's would otherwise report.
    woken ← graphicsWake (ownerOperations (ownerSettings owner))
    elapsed ← expired
    check (stopping || failing || queued || fresher || published || prunable || closing || woken || elapsed)
  where
    handoff = ownerHandoff' owner
    OwnerTimer arm = ownerClockTimer (ownerSettings owner)

-- | Whether the demand or the scene has been published since the owner's last
-- step read them.
--
-- Immediate demand is the case that makes this necessary rather than merely
-- tidy: an owner with no deadline and no event of its own would otherwise
-- sleep through a publisher asking for a frame now.
inputsAdvanced ∷ GraphicsOwner scene → STM Bool
inputsAdvanced owner = do
  (_, demandRevision) ← readOwnerDemandAt (ownerHandoff' owner)
  (_, sceneRevision) ← readOwnerSceneAt (ownerHandoff' owner)
  (seenDemand, seenScene) ← readTVar (ownerSeenInputs owner)
  pure (demandRevision > seenDemand || sceneRevision > seenScene)

-- | Whether any target's observation is newer than the one the owner folded.
observationsAdvanced ∷ GraphicsOwner scene → STM Bool
observationsAdvanced owner = do
  observations ← readTargetObservations (ownerHandoff' owner)
  states ← readTVar (ownerTargets owner)
  pure $
    or
      [ targetRevision observation > targetSeen state
      | (target, Just observation) ← observations
      , Just state ← [Map.lookup target states]
      ]
