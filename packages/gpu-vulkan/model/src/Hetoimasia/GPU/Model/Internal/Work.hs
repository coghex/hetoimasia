-- | The read-only queries the schedule is decided from: the work summary, the
-- one disposal-eligibility rule, whether a target is owed a replacement, and
-- the absolute instants its recovery accounting has committed to.
--
-- They sit below every transition so that "Hetoimasia.GPU.Model.Internal.Scheduling" can
-- compare two models without importing anything that itself schedules.
-- 'eligible' is the only definition of which subjects may be offered for
-- disposal; the work summary, owner progress and reclamation all read it here.
module Hetoimasia.GPU.Model.Internal.Work
  ( -- * The work summary
    Work (..)
  , work
  , workGrew
  , pollableWork
  , pendingObligations

    -- * Disposal eligibility
  , allSubjects
  , eligible
  , eligibleSubjects

    -- * Replacement and recovery
  , replacementOwed
  , recoveryDeadlines
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.Foundation.Time (Instant, TimeOverflow (TimeOverflow), addDuration)
import Hetoimasia.GPU.Model.Internal.Accounting (liveFrames)
import Hetoimasia.GPU.Model.Internal.Budget (healthyProgressPeriod)
import Hetoimasia.GPU.Model.Internal.Hold (holdsSettled)
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Recovery
  ( NextAttempt (AttemptAt, AttemptUnschedulable, AttemptUnscheduled)
  , RecoveryEpisode
      ( episodeHealthySince
      , episodeNextAttemptAt
      , episodeOutstanding
      , episodeRetirementCycle
      )
  )
import Hetoimasia.GPU.Model.Internal.State (GpuModel (..))
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- The work summary

-- | Everything the owner has to act on, counted so that two models can be
-- compared. Schedule resets, deadline selection and 'pendingObligations' read
-- this summary, selecting the fields relevant to each decision.
data Work = Work
  { workRenderDemand ∷ !Natural
  , workFrames ∷ !Natural
  , workSubmissions ∷ !Natural
  , workPresentations ∷ !Natural
  , workRetiringGenerations ∷ !Natural
  , workDisposable ∷ !Natural
  , workRetiringTargets ∷ !Natural
  , workReplacements ∷ !Natural
  , workRecoveries ∷ !Natural
  }
  deriving (Eq, Show)

-- | Summarize render demand and outstanding work without changing the model.
work ∷ GpuModel → Work
work model =
  Work
    { workRenderDemand = count [() | target ← targets, targetRenderDemand target, targetPhase target == TargetAdmitted]
    , workFrames = liveFrames model
    , workSubmissions = fromIntegral (Map.size (gpuSubmissions model))
    , workPresentations = count [() | target ← targets, entry ← Map.elems (targetPool target), poolState entry /= PoolReserved]
    , workRetiringGenerations =
        count
          [ ()
          | target ← targets
          , record ← Map.elems (targetGenerations target)
          , generationPhase record == GenerationRetired
          , not (holdsSettled (generationHolds record))
          ]
    , workDisposable = count (eligibleSubjects model)
    , workRetiringTargets = count [() | target ← targets, targetPhase target `elem` [TargetRetiring, TargetUnavailable]]
    , workReplacements = count [() | target ← targets, replacementOwed target]
    , workRecoveries = count (recoveryDeadlines model)
    }
  where
    targets = Map.elems (gpuTargets model)
    count ∷ [a] → Natural
    count = fromIntegral . length

-- | Whether a transition left the owner with more to do than it found. Every
-- field counts here, because anything the owner must eventually act on is work
-- it has to be woken for.
workGrew ∷ Work → Work → Bool
workGrew before after =
  or
    [ field after > field before
    | field ←
        [ workRenderDemand
        , workFrames
        , workSubmissions
        , workPresentations
        , workRetiringGenerations
        , workDisposable
        , workRetiringTargets
        , workReplacements
        , workRecoveries
        ]
    ]

-- | The work the idle poll is for: the obligations that can end without the
-- owner doing anything, so that asking again later is the only way to find out.
--
-- A recovery deadline is not one of them — it carries its own absolute instant,
-- and polling for it would answer "now" when the model has said "at 100 ms".
-- Neither is a frame the owner has reserved or acquired: it ends when the owner
-- submits or abandons it, not when anyone asks.
pollableWork ∷ Work → Natural
pollableWork summary =
  sum
    [ field summary
    | field ←
        [ workSubmissions
        , workPresentations
        , workRetiringGenerations
        , workDisposable
        , workRetiringTargets
        , workReplacements
        ]
    ]

-- | Sum the owner's outstanding work categories: submissions, presentations
-- (including records awaiting settlement), retiring generations and targets,
-- disposable subjects, replacement requests and recovery deadlines. Categories
-- can overlap, so this is not a count of distinct objects. Render demand and
-- reserved or acquired frames are excluded; 'nextDeadline' handles render demand
-- separately.
pendingObligations ∷ GpuModel → Natural
pendingObligations model =
  sum
    [ field summary
    | field ←
        [ workSubmissions
        , workPresentations
        , workRetiringGenerations
        , workDisposable
        , workRetiringTargets
        , workReplacements
        , workRecoveries
        ]
    ]
  where
    summary = work model

-- ---------------------------------------------------------------------------
-- Disposal eligibility

-- | Every generation and managed-resource record, in a stable order. These are
-- the subjects that carry holds; a bounded reclamation pass reads a window of
-- them. Frames, submissions, presentations and allocation attempts are not
-- separately disposable subjects.
allSubjects ∷ GpuModel → [SubjectKey]
allSubjects model =
  [ GenerationKey number generation
  | (number, target) ← Map.toList (gpuTargets model)
  , generation ← Map.keys (targetGenerations target)
  ]
    ++ [ResourceKey logical generation | (logical, generation) ← Map.keys (gpuResources model)]

-- | Whether this subject may be offered for disposal: every hold has ended, a
-- generation has been retired, and no earlier disposal of it failed. Unlike
-- 'disposalEligible', this includes the phase and failed-disposal checks.
eligible ∷ GpuModel → SubjectKey → Bool
eligible model key
  | key `Set.member` gpuDisposalFailures model = False
  | otherwise = case key of
      GenerationKey number generation →
        case Map.lookup number (gpuTargets model) >>= Map.lookup generation . targetGenerations of
          Nothing → False
          Just record → generationPhase record == GenerationRetired && holdsSettled (generationHolds record)
      ResourceKey logical generation →
        maybe False (holdsSettled . resourceHolds) (Map.lookup (logical, generation) (gpuResources model))

-- | Every subject 'eligible' permits offering for disposal, including its
-- retired-generation and failed-disposal checks.
eligibleSubjects ∷ GpuModel → [SubjectKey]
eligibleSubjects model = filter (eligible model) (allSubjects model)

-- ---------------------------------------------------------------------------
-- Replacement and recovery

-- | Whether this target is owed a replacement that no construction is already
-- serving.
--
-- A request raised while a construction was in flight is not covered by it —
-- that construction was begun for an earlier request — so the demand stays, and
-- with it the reason for the owner to come back. A suspended target is left out
-- for the same reason its render deadline is: suspension silences rendering,
-- and a rebuild is rendering work.
replacementOwed ∷ Target → Bool
replacementOwed target =
  targetPhase target == TargetAdmitted
    && targetReplacementRequested target > targetReplacementServed target
    && not (any covering (Map.elems (targetGenerations target)))
  where
    covering record =
      generationPhase record == GenerationConstructing
        && generationServes record >= targetReplacementRequested target

-- | Every absolute instant a target's recovery accounting has committed to: when
-- its next construction attempt may begin, and when a healthy period that has
-- started would complete and reset its episode.
--
-- Without these the owner is never woken for either. A target whose first
-- attempt has just failed and that is otherwise idle has no obligation to poll
-- for, so a schedule built from obligations alone would advertise no deadline at
-- all; and the episode's reset needs a turn to observe it, so it would never
-- happen, leaving a later recovery starting from a budget that should have been
-- returned.
recoveryDeadlines ∷ GpuModel → [Either TimeOverflow Instant]
recoveryDeadlines model =
  concat
    [ retry episode ++ healthy episode
    | target ← Map.elems (gpuTargets model)
    , targetPhase target `notElem` [TargetRetiring, TargetUnavailable]
    , let episode = targetRecovery target
    ]
  where
    retry episode
      | episodeOutstanding episode = []
      | otherwise = case episodeNextAttemptAt episode of
          AttemptUnscheduled → []
          AttemptAt at → [Right at]
          -- A delay that cannot be expressed is work the owner cannot be given
          -- an instant for, which is exactly what 'TurnUnschedulable' says.
          AttemptUnschedulable → [Left TimeOverflow]
    healthy episode
      | episodeOutstanding episode = []
      | not (episodeRetirementCycle episode) = []
      | otherwise = [addDuration since healthyProgressPeriod | Just since ← [episodeHealthySince episode]]
