-- | The two owner loops: the unscheduled one, which waits its idle bound
-- whenever a turn found nothing to do, and the scheduled one, which chooses
-- each turn's wait from the application's schedule, its captured demand, and
-- the retirement demand.
--
-- Both run on the process main thread, the session's owner, and refuse any
-- other thread before anything runs. They share one turn,
-- "Hetoimasia.Runtime.GLFW.Internal.Host.Turn", and differ only in how the
-- native step is chosen; the scheduled loop's choice is the pure
-- "Hetoimasia.Runtime.GLFW.Internal.Host.Pacing". The application's schedule
-- is the one piece of state a loop keeps, and it lives on the loop's own
-- stack for the loop's own duration.
module Hetoimasia.Runtime.GLFW.Internal.Host.Loop
  ( -- * The owner loop
    runOwnerLoop
  , LoopHooks (..)
  , noApplicationEvents
  , TurnStep (..)

    -- * The scheduled owner loop
  , runScheduledOwnerLoop
  , ScheduledHooks (..)
  , defaultScheduledHooks
  , noApplicationReadiness
  , ScheduledTurn (..)
  , ScheduledStep (..)
  ) where

import Control.Concurrent.STM (atomically)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Time (Instant, readInstant)
import Hetoimasia.GLFW.Internal.Demand (CapturedDemand (..), captureDemand, demandIsImmediate)
import Hetoimasia.GLFW.Internal.Session (ownerOperation)
import Hetoimasia.GLFW.Internal.Window (EventProcessing (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.Commands (queuedCommands)
import Hetoimasia.Runtime.GLFW.Internal.Host.Config
  ( HostConfig (..)
  , HostConfigRejected (IdleWaitRejected)
  , hostComponent
  , idleWaitDuration
  , waitSeconds
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Pacing
  ( TurnPacing (..)
  , UpdateSchedule (..)
  , choosePacing
  , earlierOf
  , earliestDeadline
  , pacingWaited
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Progress (hostRetirementDemand)
import Hetoimasia.Runtime.GLFW.Internal.Host.State (RetirementDemand (..), WindowHost (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.Turn (Turn, TurnWork (..), processEvents, reportingAsItEnds, turnSummary, turnWork)
import Hetoimasia.Runtime.Supervision (RuntimeControl, checkRuntime)

loopOperation ∷ Operation
loopOperation = operation "run owner loop"

-- ---------------------------------------------------------------------------
-- The owner loop

-- | What the application supplies to the owner loop.
data LoopHooks a = LoopHooks
  { loopLogger ∷ Logger
    -- ^ The injected logger the overflow warning is written through, at a
    -- safe owner boundary outside callbacks.
  , loopEvent ∷ IO Bool
    -- ^ One application event opportunity. 'True' when it dispatched
    -- something, which costs one unit of the event budget; 'False' when nothing
    -- was ready, which ends the turn's event work.
  , loopUpdate ∷ Turn → IO (TurnStep a)
    -- ^ The application-owned update opportunity, once per turn.
  }

-- | An event opportunity that never has anything ready.
noApplicationEvents ∷ IO Bool
noApplicationEvents = pure False

-- | Whether the loop continues.
data TurnStep a
  = Continue
  | Finish a
  deriving (Eq, Show)

-- | Run owner turns until 'loopUpdate' answers 'Finish', on the session's owner
-- thread, and return its result once a final control check has passed.
--
-- Another thread is refused with 'Hetoimasia.GLFW.Session.NotSessionOwner'
-- before anything runs. A supervised failure, a native failure, a callback
-- fault rethrown at reconciliation, a command's rethrown interruption, or a
-- hook's failure ends the loop and propagates.
runOwnerLoop ∷ WindowHost → RuntimeControl → LoopHooks a → IO a
runOwnerLoop host control hooks =
  ownerOperation (hostSession host) loopOperation [] $
    reportingAsItEnds (loopLogger hooks) host (turn 1 False)
  where
    settings = hostSettings host
    turn number idle = do
      checkRuntime control
      (queued, retiring) ← atomically ((,) <$> queuedCommands host <*> hostRetirementDemand host)
      -- A retirement the last round advanced, and one that is owed an
      -- opportunity no round has offered it yet, are both work this turn
      -- already has, so the turn polls rather than waiting: a pending
      -- retirement never waits on the idle bound for its first opportunity and
      -- never holds another window's service up. Retirements that have all been
      -- inspected and are waiting are not that work, however many of them the
      -- budget leaves unserved, so an idle turn beside them is idle.
      let waited = idle && queued == 0 && not (retirementImmediate retiring)
      processEvents host number (if waited then AwaitEventsFor (hostIdleWait settings) else ProcessPending)
      work ← turnWork host control (loopLogger hooks) (loopEvent hooks)
      step ← loopUpdate hooks (turnSummary number waited work)
      checkRuntime control
      case step of
        Finish result → pure result
        Continue → turn (number + 1) (workCommands work == 0 && workEvents work == 0)

-- ---------------------------------------------------------------------------
-- The scheduled owner loop

-- | Whether the scheduled loop continues, and with what schedule.
data ScheduledStep a
  = ContinueWith !UpdateSchedule
  | FinishWith a
  deriving (Eq, Show)

-- | The native step a pacing takes. A wait is only ever entered for a positive
-- duration, so no zero or negative timeout reaches GLFW.
pacingProcessing ∷ TurnPacing → EventProcessing
pacingProcessing = \case
  PolledForWork → ProcessPending
  PolledForDeadline → ProcessPending
  WaitedForDeadline remaining → AwaitEventsFor (waitSeconds remaining)
  WaitedForFallback bound → AwaitEventsFor (waitSeconds bound)

-- | What one scheduled turn did, as its update opportunity sees it.
data ScheduledTurn = ScheduledTurn
  { scheduledTurn ∷ !Turn
    -- ^ The same summary the unscheduled loop supplies: the turn number,
    -- whether it waited, its dispatch counts, and the close requests it
    -- surfaced.
  , scheduledNow ∷ !Instant
    -- ^ The instant sampled after the native call returned, so a deadline
    -- reached during the wait is already visible here. Reconciliation,
    -- dispatch, and this update consume the interval after it; the next turn
    -- samples again.
  , scheduledPacing ∷ !TurnPacing
    -- ^ Whether the turn polled or waited, and why.
  , scheduledDemand ∷ !(Maybe CapturedDemand)
    -- ^ The request the turn's own inspection captured from the application's
    -- demand slot, with its revision, or 'Nothing' when none was pending. It is
    -- already consumed: a publication committed after that capture carries a
    -- newer revision and is captured by a later turn.
  }
  deriving (Eq, Show)

-- | What the application supplies to the scheduled owner loop.
data ScheduledHooks a = ScheduledHooks
  { scheduledLogger ∷ Logger
    -- ^ The injected logger the overflow and wake warnings are written through,
    -- as 'loopLogger' is.
  , scheduledReady ∷ IO Bool
    -- ^ Whether an application event is ready, answered without dispatching
    -- one. It runs once per turn, before the native step, and only decides
    -- whether that turn polls; it must neither dispatch nor consume anything,
    -- and it spends none of 'hostEventBudget'. An event published after it
    -- answered is not seen by that turn: a worker that needs prompt service
    -- publishes demand, which wakes the owner.
  , scheduledEvent ∷ IO Bool
    -- ^ One application event opportunity, exactly as 'loopEvent'.
  , scheduledUpdate ∷ ScheduledTurn → IO (ScheduledStep a)
    -- ^ The application-owned update opportunity, once per turn, which answers
    -- the schedule the turns after it are chosen from.
  , scheduledStart ∷ UpdateSchedule
    -- ^ The schedule in force before the first update opportunity has
    -- answered. 'defaultScheduledHooks' leaves it 'NoUpdateDemand'.
  }

-- | An application event readiness query that never has anything ready.
noApplicationReadiness ∷ IO Bool
noApplicationReadiness = pure False

-- | Hooks with no application events, nothing ever ready, and no initial
-- schedule, for a caller that overrides only the fields it uses.
defaultScheduledHooks ∷ Logger → (ScheduledTurn → IO (ScheduledStep a)) → ScheduledHooks a
defaultScheduledHooks logger update =
  ScheduledHooks
    { scheduledLogger = logger
    , scheduledReady = noApplicationReadiness
    , scheduledEvent = noApplicationEvents
    , scheduledUpdate = update
    , scheduledStart = NoUpdateDemand
    }

-- | Run scheduled owner turns until 'scheduledUpdate' answers 'FinishWith', on
-- the session's owner thread, and return its result once a final control check
-- has passed.
--
-- Each turn samples 'hostClock', captures the application's pending demand,
-- reads the queued command count and the application's readiness in one
-- inspection, and from those and the stored schedule chooses to poll or to wait
-- a finite bound that is at most the earliest deadline and at most the
-- configured fallback. It then resamples the clock and reconciles, dispatches,
-- and offers the update opportunity exactly as 'runOwnerLoop' does, with the
-- same checkpoints, budgets, fair dispatch, retirement, close-request
-- surfacing, and feed recovery.
--
-- 'runOwnerLoop' is untouched by this path and keeps its own behaviour. Another
-- thread is refused with 'Hetoimasia.GLFW.Session.NotSessionOwner' before
-- anything runs, and every failure ends the loop exactly as it ends that one.
runScheduledOwnerLoop ∷ WindowHost → RuntimeControl → ScheduledHooks a → IO a
runScheduledOwnerLoop host control hooks =
  ownerOperation (hostSession host) loopOperation [] $ do
    bound ← either rejectedBound pure (idleWaitDuration settings)
    reportingAsItEnds logger host (turn bound 1 (scheduledStart hooks))
  where
    settings = hostSettings host
    logger = scheduledLogger hooks
    -- Unreachable for a host the construction accepted, which validated these
    -- seconds as a positive duration; a typed rejection rather than a partial
    -- function keeps it that way if the two ever drift apart.
    rejectedBound _ = throwFailure hostComponent loopOperation [] (IdleWaitRejected (hostIdleWait settings))
    turn bound number schedule = do
      checkRuntime control
      inspected ← readInstant (hostClock settings)
      (captured, queued, retiring) ←
        atomically
          ( (,,)
              <$> captureDemand (hostDemandSlot host)
              <*> queuedCommands host
              <*> hostRetirementDemand host
          )
      ready ← scheduledReady hooks
      let immediate =
            schedule == UpdateImmediately
              || maybe False (demandIsImmediate . capturedRequest) captured
              || retirementImmediate retiring
          -- A due retirement step shortens the wait exactly as an application
          -- deadline does, and never lengthens it.
          deadline = earlierOf (earliestDeadline schedule captured) (retirementNextPossible retiring)
          pacing = choosePacing bound inspected deadline (queued > 0 || ready || immediate)
      processEvents host number (pacingProcessing pacing)
      -- The instant the update is given, so a deadline the wait itself reached
      -- is due now rather than on the turn after.
      sampled ← readInstant (hostClock settings)
      work ← turnWork host control logger (scheduledEvent hooks)
      step ←
        scheduledUpdate
          hooks
          ScheduledTurn
            { scheduledTurn = turnSummary number (pacingWaited pacing) work
            , scheduledNow = sampled
            , scheduledPacing = pacing
            , scheduledDemand = captured
            }
      checkRuntime control
      case step of
        FinishWith result → pure result
        ContinueWith next → turn bound (number + 1) next
