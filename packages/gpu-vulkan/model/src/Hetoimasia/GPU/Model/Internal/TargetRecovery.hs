-- | Model-wide recovery transitions: beginning a target's recovery attempt,
-- recording its outcome, and exhausting or declaring a target unrecoverable.
--
-- The per-episode accounting these transitions consult — the attempt budget,
-- retry delays and healthy-progress reset — is the policy in
-- "Hetoimasia.GPU.Model.Internal.Recovery". This module owns applying it to a target of the
-- model: the recovery epoch, the escalation a spent episode raises, and the
-- rule that close and a failed session each take precedence over recovery.
module Hetoimasia.GPU.Model.Internal.TargetRecovery
  ( RecoveryAnswer (..)
  , beginTargetRecovery
  , recordRecoveryFailure
  , recordRecoverySuccess
  , declareTargetUnrecoverable
  ) where

import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GPU.Model.Internal.Accounting (editTarget)
import Hetoimasia.GPU.Model.Internal.Budget (recoveryAttemptLimit)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Recovery
  ( RecoveryEpisode (episodeAttempts, episodeOutstanding)
  , RecoveryProgress
      ( AttemptAdmitted
      , AttemptBudgetExhausted
      , AttemptDeferredUntil
      , AttemptDelayUnrepresentable
      , AttemptStillOutstanding
      )
  , attemptRecovery
  , recordAttemptFailure
  , recordAttemptSuccess
  )
import Hetoimasia.GPU.Model.Internal.Resolve (resolveTarget, targetIdOf)
import Hetoimasia.GPU.Model.Internal.Scheduling (scheduling, scheduling_)
import Hetoimasia.GPU.Model.Internal.Session (escalateSession, note)
import Hetoimasia.GPU.Model.Internal.State
import Numeric.Natural (Natural)

data RecoveryAnswer
  = RecoveryAttempt !Natural
  | RecoveryDeferred !Instant
  | RecoveryClosed
    -- ^ Close takes precedence over retry admission.
  | RecoveryUnschedulable
    -- ^ The delay this episode owes does not fit the clock's representation, so
    -- the attempt cannot be admitted without shortening a delay the episode
    -- exists to enforce.
  | RecoveryOutstanding
    -- ^ An attempt is already in flight. It must be settled with
    -- 'recordRecoveryFailure' or 'recordRecoverySuccess' first, so one
    -- construction can never spend two of the episode's three attempts.
  | RecoveryExhausted !Escalation
  deriving (Eq, Show)

-- | Ask to begin this target's next recovery construction attempt.
beginTargetRecovery ∷ Instant → TargetId → GpuModel → Outcome (GpuModel, RecoveryAnswer)
beginTargetRecovery now identity model =
  scheduling model $
  -- A terminal session begins no new recovery work. Device loss and the other
  -- session causes are not conditions a target can construct its way out of.
  resolved (running model) $ \() →
    resolved (resolveTarget model identity) $ \(number, target) →
      case targetPhase target of
        TargetRetiring → Admitted (model, RecoveryClosed)
        TargetUnavailable → Admitted (model, RecoveryClosed)
        _ → case attemptRecovery now (targetRecovery target) of
          (_, AttemptStillOutstanding) → Admitted (model, RecoveryOutstanding)
          (_, AttemptDelayUnrepresentable) → Admitted (model, RecoveryUnschedulable)
          -- Reachable only for a target readmitted since its episode was spent:
          -- the final failure exhausts it where it happens, rather than waiting
          -- for someone to ask for an attempt that does not exist.
          (_, AttemptBudgetExhausted) →
            let (next, escalation) = exhaustTarget number target model
             in Admitted (next, RecoveryExhausted escalation)
          (_, AttemptDeferredUntil at) → Admitted (model, RecoveryDeferred at)
          (episode, AttemptAdmitted attempt) →
            Admitted
              ( editTarget
                  number
                  -- The epoch rises here and nowhere else. Every piece of health
                  -- evidence carries the epoch it was gathered in, so this one
                  -- line is what makes evidence from before this attempt
                  -- incomparable with evidence from after it.
                  (\entry → entry {targetRecovery = episode, targetRecoveryEpoch = targetRecoveryEpoch entry + 1})
                  model
              , RecoveryAttempt attempt
              )

-- | Record that the attempt just made failed. Nothing about a nested helper, a
-- changed geometry observation or an allocation sub-retry reaches this counter
-- except through 'beginTargetRecovery', so none of them can replenish it.
recordRecoveryFailure ∷ Instant → TargetId → GpuModel → Outcome GpuModel
recordRecoveryFailure now identity model =
  scheduling_ model $
  resolved (resolveTarget model identity) $ \(number, target) →
    -- A failure is a report about an attempt this episode admitted. Accepting
    -- one with nothing outstanding would spend an attempt on a construction that
    -- never began, and would install a retry delay out of nowhere.
    if not (episodeOutstanding (targetRecovery target))
      then Rejected (WrongPhase TargetIdentity)
      else
        let recorded =
              editTarget number (\entry → entry {targetRecovery = recordAttemptFailure now (targetRecovery entry)}) model
         in -- The last failure of an episode is where recovery is exhausted.
            -- Leaving that to whoever next asks for an attempt would leave the
            -- target admitted, unescalated and unscheduled — and on an otherwise
            -- idle target nobody ever asks.
            --
            -- Unless close already won. An attempt that was outstanding when the
            -- target closed still has to be settled, but its outcome decides
            -- nothing: a target that is retiring is not one recovery can be
            -- exhausted on, and a session that has already failed has no room
            -- for a target to fail it again.
            if episodeAttempts (targetRecovery target) < recoveryAttemptLimit
              || not (stillRecovering model target)
              then Admitted recorded
              else case Map.lookup number (gpuTargets recorded) of
                Nothing → Admitted recorded
                Just spent → Admitted (fst (exhaustTarget number spent recorded))

-- | Whether a failure reported for this target can still exhaust its recovery.
-- A target that has closed, one already marked unavailable, and any target of a
-- session that has already failed have nothing left for recovery to decide.
stillRecovering ∷ GpuModel → Target → Bool
stillRecovering model target =
  gpuState model == SessionRunning
    && targetPhase target `notElem` [TargetRetiring, TargetUnavailable]

-- | Mark a target whose recovery budget is spent: an optional one becomes
-- unavailable and the session continues; a required one fails the session.
exhaustTarget ∷ Natural → Target → GpuModel → (GpuModel, Escalation)
exhaustTarget number target model = case targetClassOf target of
  OptionalTarget →
    let escalation = OptionalTargetUnavailable (targetIdOf model number target)
     in ( note
            escalation
            (editTarget number (\entry → entry {targetPhase = TargetUnavailable, targetRenderDemand = False}) model)
        , escalation
        )
  RequiredTarget →
    let escalation = RequiredTargetFailedSession (targetIdOf model number target)
     in ( note
            escalation
            ( escalateSession
                RequiredTargetUnrecoverable
                (editTarget number (\entry → entry {targetPhase = TargetRetiring, targetRenderDemand = False}) model)
            )
        , escalation
        )


-- | Declare that this target cannot be recovered at all, whatever its episode
-- has left: the session's one device can no longer present to what the target
-- would be rebuilt on, and no second device is ever made. It is disposed of
-- exactly as a spent episode is — an optional target unavailable while the
-- session continues, a required one failing the session — and answers the
-- escalation, or 'Nothing' when close already won, the target is already
-- unavailable, or the session has already failed, since then there is nothing
-- left for it to decide.
--
-- It settles no attempt: an attempt still outstanding is reported first, with
-- 'recordRecoveryFailure', whose last failure may already have exhausted the
-- target.
declareTargetUnrecoverable ∷ TargetId → GpuModel → Outcome (GpuModel, Maybe Escalation)
declareTargetUnrecoverable identity model =
  scheduling model $
  resolved (resolveTarget model identity) $ \(number, target) →
    if stillRecovering model target
      then let (next, escalation) = exhaustTarget number target model in Admitted (next, Just escalation)
      else Admitted (model, Nothing)

-- | Record that the attempt just made succeeded. It settles the attempt so the
-- episode can admit another later; it does not give the spent attempt back,
-- which only a completed retirement cycle and a healthy second do.
recordRecoverySuccess ∷ TargetId → GpuModel → Outcome GpuModel
recordRecoverySuccess identity model =
  scheduling_ model $
  resolved (resolveTarget model identity) $ \(number, target) →
    if not (episodeOutstanding (targetRecovery target))
      then Rejected (WrongPhase TargetIdentity)
      else Admitted (editTarget number (\entry → entry {targetRecovery = recordAttemptSuccess (targetRecovery entry)}) model)
