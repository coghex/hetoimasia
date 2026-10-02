-- | Owner progress: one bounded, round-robin owner turn, and the absolute
-- deadline of the next one.
--
-- This module composes the transitions below it. A turn applies completion
-- facts through "Hetoimasia.GPU.Model.Internal.Completion" and disposals through
-- "Hetoimasia.GPU.Model.Internal.Disposal", visiting targets in rotation under the
-- configured action budget, then anchors the next poll to the turn's instant.
-- The deadlines it answers are read from the work summary in
-- "Hetoimasia.GPU.Model.Internal.Work" and never from the instant they are read at.
module Hetoimasia.GPU.Model.Internal.Progress
  ( TurnReport (..)
  , NextTurn (..)
  , runProgressTurn
  , nextDeadline
  , progressDeadline
  ) where

import qualified Data.Map.Strict as Map
import Data.Either (isLeft)
import Hetoimasia.Foundation.Time (Instant, TimeOverflow (TimeOverflow))
import Hetoimasia.GPU.Model.Internal.Accounting (editTarget)
import Hetoimasia.GPU.Model.Internal.Budget (progressActionLimit)
import Hetoimasia.GPU.Model.Internal.Completion (CompletionFact (..), DisposalResult (..), EvidenceSource (..), recordCompletion)
import Hetoimasia.GPU.Model.Internal.Disposal (dispose, rememberFailure, rotated)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Recovery
  ( BackoffState (backoffDueAt)
  , DueAt (DueAt, DueImmediately, DueUnschedulable)
  , RecoveryEpisode (episodeOutstanding)
  , observeHealthyProgress
  , scheduleNextPoll
  )
import Hetoimasia.GPU.Model.Internal.Resolve (subjectIdentity, targetIdOf)
import Hetoimasia.GPU.Model.Internal.Session (escalateSession)
import Hetoimasia.GPU.Model.Internal.State
import Hetoimasia.GPU.Model.Internal.Work (Work (workRenderDemand), eligible, eligibleSubjects, pollableWork, recoveryDeadlines, work)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Owner turns

data TurnReport = TurnReport
  { turnActions ∷ !Natural
  , turnFacts ∷ !Natural
  , turnDisposed ∷ ![HoldSubject]
  , turnDisposalFailures ∷ ![HoldSubject]
  , turnServed ∷ ![TargetId]
    -- ^ The targets this turn visited, in the order it visited them. The lead
    -- rotates every turn, so no target can starve behind a busy neighbour.
  , turnNextDeadline ∷ !NextTurn
  }
  deriving (Eq, Show)

-- | One owner turn: at most the configured number of completion or disposal
-- actions, taken round-robin across targets, followed by the absolute deadline
-- of the next one.
runProgressTurn ∷ EvidenceSource → Instant → GpuModel → (GpuModel, TurnReport)
runProgressTurn source now model = (finished, report)
  where
    budget = progressActionLimit (gpuBudgets model)
    -- Each pass visits every target once and the session itself once, so
    -- managed resources are reclaimed, and frame-less submissions completed,
    -- under the same action budget as target work rather than through a
    -- second unbounded sweep. The session's place rotates with the targets',
    -- so busy targets can no more starve it than one another.
    visits = rotated (gpuCursor model) (map Just (Map.keys (gpuTargets model)) ++ [Nothing])
    order = [number | Just number ← visits]
    (worked, actions, facts, disposed, failures) = passes model 0 0 [] []
    passes current used factCount disposedSoFar failed
      | used >= budget = (current, used, factCount, disposedSoFar, failed)
      | otherwise =
          let (stepped, stepUsed, stepFacts, stepDisposed, stepFailed) =
                foldl' visit (current, used, factCount, disposedSoFar, failed) visits
           in if stepUsed == used
                then (stepped, stepUsed, stepFacts, stepDisposed, stepFailed)
                else passes stepped stepUsed stepFacts stepDisposed stepFailed
    visit accumulated@(current, used, factCount, disposedSoFar, failed) place
      | used >= budget = accumulated
      | otherwise = case nextAction source current place of
          Nothing → accumulated
          Just action → case applyAction source now current action of
            FactApplied next → (next, used + 1, factCount + 1, disposedSoFar, failed)
            SubjectDisposed next subject → (next, used + 1, factCount, subject : disposedSoFar, failed)
            SubjectDisposalFailed next subject → (next, used + 1, factCount, disposedSoFar, subject : failed)
            ActionDeclined → accumulated
    healthy = foldl' (\current number → editTarget number (\entry → entry {targetRecovery = observeHealthyProgress now (targetRecovery entry)}) current) worked order
    retired = foldl' forgetIfRetired healthy order
    -- The turn is the only place an instant reaches the backoff, so it is the
    -- only place the next poll can be anchored to one.
    backoff = scheduleNextPoll (gpuBudgets retired) now (actions > 0) (gpuBackoff retired)
    finished = retired {gpuBackoff = backoff, gpuCursor = gpuCursor retired + 1}
    report =
      TurnReport
        { turnActions = actions
        , turnFacts = facts
        , turnDisposed = reverse disposed
        , turnDisposalFailures = reverse failures
        , turnServed =
            [ targetIdOf model number target
            | number ← order
            , Just target ← [Map.lookup number (gpuTargets model)]
            ]
        , turnNextDeadline = nextDeadline finished
        }

data ActionResult
  = FactApplied !GpuModel
  | SubjectDisposed !GpuModel !HoldSubject
  | SubjectDisposalFailed !GpuModel !HoldSubject
  | ActionDeclined

data PendingAction
  = ApplySubmission !SubmissionId
  | ApplyPresentation !PresentationId
  | ApplySettlement !FrameSlotId
  | DisposeSubject !SubjectKey
  deriving (Eq, Show)

-- | The first action this place offers, in a fixed order: completion facts
-- before disposals, so a turn never spends its whole budget disposing while
-- evidence waits. 'Nothing' names the session itself, whose only work is
-- reclaiming managed resources every hold of which has ended.
nextAction ∷ EvidenceSource → GpuModel → Maybe Natural → Maybe PendingAction
nextAction source model place = case place of
  -- The session's own work: frame-less submissions' completions (GRS-12),
  -- then the managed resources every hold of which has ended.
  Nothing →
    firstOf
      [ ApplySubmission (SubmissionId (gpuSession model) submission)
      | SlotSubmitted submission ← Map.elems (gpuFramelessSlots model)
      , maybe False (not . submissionUncertain) (Map.lookup submission (gpuSubmissions model))
      , submissionEvidence source (SubmissionId (gpuSession model) submission)
      ]
      `orElse` firstOf
        [ DisposeSubject key
        | key@(ResourceKey _ _) ← eligibleSubjects model
        , offered key
        ]
  Just number → case Map.lookup number (gpuTargets model) of
    Nothing → Nothing
    Just target →
      firstOf
        [ ApplySubmission identity
        | identity ← submissionsOf target
        , submissionEvidence source identity
        ]
        `orElse` firstOf
          [ ApplyPresentation identity
          | identity ← enqueuedOf number target
          , presentationEvidence source identity
          ]
        `orElse` firstOf
          [ ApplySettlement identity
          | identity ← awaitingOf number target
          , unpresentedFrameEvidence source identity
          ]
        `orElse` firstOf
          [ DisposeSubject key
          | key ← disposableOf number target
          , offered key
          ]
  where
    offered key = case subjectIdentity model key of
      Nothing → False
      Just subject → disposalEvidence source subject /= DisposalRefused
    submissionsOf target =
      [ SubmissionId (gpuSession model) submission
      | frame ← Map.elems (targetFrames target)
      , Just submission ← [frameSubmission frame]
      , Map.member submission (gpuSubmissions model)
      , maybe False (not . submissionUncertain) (Map.lookup submission (gpuSubmissions model))
      ]
    enqueuedOf target' target =
      [ PresentationId (targetIdOf model target' target) record
      | (record, entry) ← Map.toList (targetPool target)
      , poolState entry == PoolEnqueued
      ]
    awaitingOf target' target =
      [ FrameSlotId (targetIdOf model target' target) slot (frameUseNumber frame)
      | (slot, frame) ← Map.toList (targetFrames target)
      , framePhase frame == FrameRetiring
      , Just record ← [framePoolRecord frame]
      , maybe False ((== PoolAwaitingSettlement) . poolState) (Map.lookup record (targetPool target))
      ]
    -- The one eligibility rule, applied to this target's generations in their
    -- own order.
    disposableOf target' target =
      filter (eligible model) [GenerationKey target' generation | generation ← Map.keys (targetGenerations target)]
    firstOf entries = case entries of
      [] → Nothing
      entry : _ → Just entry
    orElse (Just value) _ = Just value
    orElse Nothing alternative = alternative

applyAction ∷ EvidenceSource → Instant → GpuModel → PendingAction → ActionResult
applyAction source now model = \case
  ApplySubmission identity → case recordCompletion now (SubmissionCompleted identity) model of
    Admitted next → FactApplied next
    _ → ActionDeclined
  ApplyPresentation identity → case recordCompletion now (PresentationRetired identity) model of
    Admitted next → FactApplied next
    _ → ActionDeclined
  ApplySettlement identity → case recordCompletion now (UnpresentedFrameSettled identity) model of
    Admitted next → FactApplied next
    _ → ActionDeclined
  DisposeSubject key → case subjectIdentity model key of
    Nothing → ActionDeclined
    Just subject → case disposalEvidence source subject of
      DisposalRefused → ActionDeclined
      DisposalCompleted → SubjectDisposed (dispose key model) subject
      -- A failed disposal is preserved rather than replayed: the subject keeps
      -- its ownership and its accounting, it is never offered again, and the
      -- session escalates. Not retrying is what makes the failure bounded; it is
      -- also what keeps a turn from spending its whole budget on one broken
      -- disposal.
      DisposalFailed →
        SubjectDisposalFailed (escalateSession CleanupFailed (rememberFailure key model)) subject

-- | A retiring target whose records have all gone leaves the model, freeing its
-- number for reuse under a fresh incarnation.
--
-- An attempt still in flight is one of those records, even though it is not one
-- this model holds: forgetting the target would leave the outcome with nothing
-- to be reported against, and the boundary settling it would be told its
-- identity is stale rather than being allowed to settle it.
forgetIfRetired ∷ GpuModel → Natural → GpuModel
forgetIfRetired model number = case Map.lookup number (gpuTargets model) of
  Just target
    | targetPhase target `elem` [TargetRetiring, TargetUnavailable]
    , not (episodeOutstanding (targetRecovery target))
    , Map.null (targetFrames target)
    , Map.null (targetGenerations target)
    , Map.null (targetPool target) →
        model {gpuTargets = Map.delete number (gpuTargets model)}
  _ → model

-- ---------------------------------------------------------------------------
-- Deadlines

-- | When the next owner turn is due.
data NextTurn
  = NoTurnNeeded
    -- ^ Nothing is pending and nothing is scheduled.
  | TurnNow
    -- ^ An opportunity is owed immediately: something was scheduled since the
    -- last turn, and the transition that scheduled it carried no clock reading
    -- to anchor an instant to.
  | TurnAt !Instant
    -- ^ The absolute instant of the next turn. One in the past means the owner
    -- is overdue, and is reported as it stands.
  | TurnUnschedulable
    -- ^ There is work, and the instant it is due at does not fit the clock's
    -- representation. It is its own answer rather than 'NoTurnNeeded', because
    -- reading an arithmetic failure as an absence would tell the owner that
    -- nothing needs doing while work is outstanding.
  deriving (Eq, Show)

-- | When the next owner turn is due.
--
-- It takes no instant, and that is the point: the answer is a property of the
-- model alone, so reading the same unchanged model twice gives the same answer
-- however much time has passed between the reads. A deadline recomputed from the
-- reading instant would let an unrelated observation push the next poll further
-- away each time it happened.
--
-- A target with render demand that is not suspended asks for an opportunity now.
-- Otherwise it is 'progressDeadline'.
nextDeadline ∷ GpuModel → NextTurn
nextDeadline model
  | workRenderDemand (work model) > 0 = TurnNow
  | otherwise = progressDeadline model

-- | When the next owner turn is due for the obligations alone, leaving render
-- demand out: the earliest of the instants the model is committed to — the
-- poll the last turn anchored, if any obligation is pending, and every absolute
-- recovery deadline — or now, when something scheduled since the last turn
-- carried no clock reading. A suspended target keeps its retirement demand here
-- even though it contributes no render deadline. With nothing pending and
-- nothing scheduled there is nothing to wait for.
--
-- It is the answer an owner that paces its own rendering reads. Render demand
-- in 'nextDeadline' says a frame is wanted now; it does not say one can be made
-- now — every image of the swapchain may be in the presentation engine's hands
-- — so an owner that retries an acquisition later asks this for everything
-- else, and would otherwise be told to take a turn now for as long as the frame
-- it cannot yet acquire is wanted. Like 'nextDeadline', it takes no instant.
progressDeadline ∷ GpuModel → NextTurn
progressDeadline model
  | immediate = TurnNow
  -- The earliest representable instant wins. An overflow is reported only when
  -- there is no representable instant at all, because a deadline that is both
  -- actionable and sooner is not made unreachable by some other candidate's
  -- arithmetic failing.
  | not (null scheduled) = TurnAt (minimum scheduled)
  | any isLeft results = TurnUnschedulable
  | otherwise = NoTurnNeeded
  where
    summary = work model
    pollable = pollableWork summary
    immediate = pollable > 0 && backoffDueAt (gpuBackoff model) == DueImmediately
    scheduled = [instant | Right instant ← results]
    results = poll ++ recoveryDeadlines model
    poll
      | pollable <= 0 = []
      | otherwise = case backoffDueAt (gpuBackoff model) of
          DueImmediately → []
          DueAt at → [Right at]
          DueUnschedulable → [Left TimeOverflow]
