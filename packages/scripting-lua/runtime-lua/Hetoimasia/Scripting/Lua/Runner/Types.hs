-- | What the script runner takes and answers: the scripts, the injected clock, timer, sinks, logger
-- and stop request, and the bounded report of a run.
--
-- Nothing here runs anything. "Hetoimasia.Scripting.Lua.Runner" is where the behavior is
-- described; this module is the vocabulary it speaks in, and the constants that bound it.
{-# LANGUAGE PatternSynonyms #-}

module Hetoimasia.Scripting.Lua.Runner.Types
  ( -- * What a run is given
    Script (Script, ScriptWith, scriptPath, scriptName, scriptInterval, scriptTicks)
  , script
  , everyTicks
  , RunnerConfig (..)
  , runnerConfig

    -- * What a run answers
  , RunOutcome (..)
  , RunReport (..)
  , RunEnding (..)
  , RunStatus (..)
  , runStatusOf
  , EventTally (..)
  , noTally
  , InstanceReport (..)
  , InstanceEnd (..)
  , FailureReport (..)
  , SecondaryFailure (..)
  , LoadFailure (..)
  , LoadProblem (..)

    -- * Usage refusals
  , UsageRefusal (..)
  , UsageViolation (..)
  , UsageReason (..)
  , usageText

    -- * Bounds
  , runnerMaxScripts
  , runnerInstanceBounds
  , runnerSchedulerBounds
  , runnerLifecycleName
  , runnerEventsName
  , runnerSubscriptionBound
  , runnerStagingBound
  , outputCallLimit
  , truncationMarker
  , columnLimit
  , secondaryLimit
  , errorLimit
  , tracebackLimit
  , nameLimit
  , pathLimit
  ) where

import Control.Concurrent.STM (STM)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Time (Duration, MonotonicSource, monotonicSource)
import Hetoimasia.Scripting.Lua.Instance.Types
  ( InstanceBounds (..)
  , InstanceId
  , InstancePhase
  , ShutdownDisposition
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits (Quanta (..), Quantum (..))
import Hetoimasia.Scripting.Lua.Runtime.Types (Discard)
import Hetoimasia.Scripting.Lua.Scheduler (SchedulerBounds (..), TimerBackend, systemTimerBackend)

-- | One script: a file, and how it runs.
--
-- On an elapsed VM (no tick duration) a looped script's interval is 'scriptInterval', an elapsed
-- duration; on a tick VM it is 'scriptTicks', a number of ticks. The other is refused as usage, and so is
-- a script with neither when its module defines @update@, and one with an interval when it does not. The
-- three-argument constructor 'Script' is a script with no tick interval, which is what a script was
-- before the tick clock existed.
data Script = ScriptWith
  { scriptPath ∷ FilePath
    -- ^ The file the runner reads. Two scripts that name the same path share one read and one
    -- module, and are admitted as two instances.
  , scriptName ∷ Maybe Text
    -- ^ The instance's readable name. Without one it is the last component of the path. It
    -- names the instance in the tables and the reports and grants nothing.
  , scriptInterval ∷ Maybe Duration
    -- ^ A positive elapsed duration: how often the module's @update@ falls due on an elapsed VM. It is
    -- required there for a module that defines @update@ and refused for one that does not.
  , scriptTicks ∷ Maybe Integer
    -- ^ The same on a tick VM, as a positive whole number of ticks that fits a 64-bit tick. A count that
    -- is not positive, or does not fit, is refused as usage.
  }
  deriving (Eq, Show)

-- | A script with this path, name and elapsed interval, and no tick interval.
pattern Script ∷ FilePath → Maybe Text → Maybe Duration → Script
pattern Script path name interval ← ScriptWith path name interval Nothing
  where
    Script path name interval = ScriptWith path name interval Nothing

-- | A script with no name and no interval.
script ∷ FilePath → Script
script path = Script path Nothing Nothing

-- | The same script, looped every this many ticks, on a tick VM.
everyTicks ∷ Integer → Script → Script
everyTicks count item = item {scriptTicks = Just count}

-- | What a run is given. Every input that is not data is injected, so a test, a command line and a
-- windowed application each supply their own.
data RunnerConfig = RunnerConfig
  { runnerName ∷ Text
    -- ^ The VM's name: the owner label the tables and the reports show.
  , runnerScripts ∷ [Script]
    -- ^ The scripts, in the order they are loaded and admitted, so in the order their instance
    -- numbers ascend. At least one, and at most 'runnerMaxScripts'.
  , runnerLimit ∷ Maybe Duration
    -- ^ A positive run limit, measured on 'runnerClock' from the instant the runner begins
    -- admitting instances, and waited for on 'runnerTimer'. 'Nothing' sets none. Available on both clocks.
  , runnerTick ∷ Maybe Duration
    -- ^ The tick duration, a positive whole number of nanoseconds. With it the VM is a /tick VM/: it is
    -- hosted with that tick duration, admits Lua controls logically, takes its events at assigned ticks,
    -- and the runner grants logical steps of exactly this duration at this real-time rate. Without it the
    -- VM is an /elapsed VM/: controls and events are admitted on arrival and nothing is granted.
  , runnerTickLimit ∷ Maybe Integer
    -- ^ A run limit of this many ticks, at least one and fitting a 64-bit tick; it needs a tick duration.
    -- When this many ticks have completed the run ends as a duration limit ends it.
  , runnerStop ∷ STM Bool
    -- ^ The stop request. The run waits on it in STM, beside everything else it waits for, and
    -- never polls it; one that is already set when the run begins admits nothing.
  , runnerClock ∷ MonotonicSource
  , runnerTimer ∷ TimerBackend
  , runnerOutput ∷ Text → IO ()
    -- ^ Receives one line at a time: a script's @print@, and the tables. Never a line break and
    -- never a control character but a tab.
  , runnerErrors ∷ Text → IO ()
    -- ^ The same, for a script's @warn@ and for the failure reports.
  , runnerLogger ∷ Logger
    -- ^ The diagnostics the runner itself raises: a record when a run starts and when it ends.
    -- Script output, tables and reports are application output and never go here.
  }

-- | A configuration with no limit, a stop request that is never set, the production clock and timer,
-- and these sinks and logger.
runnerConfig ∷ Text → [Script] → Logger → (Text → IO ()) → (Text → IO ()) → RunnerConfig
runnerConfig name scripts logger output errors =
  RunnerConfig
    { runnerName = name
    , runnerScripts = scripts
    , runnerLimit = Nothing
    , runnerTick = Nothing
    , runnerTickLimit = Nothing
    , runnerStop = pure False
    , runnerClock = monotonicSource
    , runnerTimer = systemTimerBackend
    , runnerOutput = output
    , runnerErrors = errors
    , runnerLogger = logger
    }

-- | How a run ended.
data RunEnding
  = -- | Every instance ended: one-shots completed, instances failed, or a Lua control stopped
    -- them, of themselves or of another.
    EndedAllInstances
  | -- | The duration limit was reached.
    EndedLimit
  | -- | The tick limit was reached: that many ticks have completed.
    EndedTickLimit
  | -- | The stop request fired.
    EndedStopRequest
  | -- | A source did not load, so the VM did not start: no instance was admitted.
    EndedStartupFailure
  deriving (Eq, Show)

-- | The status value of a run. The exit numbers are the command line's.
data RunStatus
  = -- | Every instance completed or was stopped, by a control or by the limit.
    StatusSuccess
  | -- | The stop request ended the run, and no instance failed and no source failed to load.
    StatusInterrupted
  | -- | An instance failed or a source did not load.
    StatusFailure
  deriving (Eq, Show)

-- | The status of a run that ended this way, with or without a failure: a failure outranks a stop
-- request, which outranks success.
runStatusOf ∷ Bool → RunEnding → RunStatus
runStatusOf failed ending
  | failed || ending == EndedStartupFailure = StatusFailure
  | ending == EndedStopRequest = StatusInterrupted
  | otherwise = StatusSuccess

-- | The answer of a run that was not refused.
data RunReport = RunReport
  { reportEnding ∷ !RunEnding
  , reportInstances ∷ ![InstanceReport]
    -- ^ Every instance the run admitted, in ascending instance number, ended ones included.
    -- Empty when a source did not load, when the stop request was already set, and when the
    -- supervision boundary was closing.
  , reportLoadFailure ∷ !(Maybe LoadFailure)
  , reportStatus ∷ !RunStatus
  , reportTicks ∷ !Word64
    -- ^ How many ticks completed: always zero on an elapsed VM.
  , reportEvents ∷ !EventTally
    -- ^ What became of the instance events.
  }
  deriving (Eq, Show)

-- | What became of the events of the @instances@ endpoint, by count. An /event/ is produced once; a
-- production makes a /delivery attempt/ to each subscription that exists then, so several attempts can
-- come of one event and none of an event nobody subscribed for. An attempt is counted by the engine's
-- answer: only these answers are not defects of the runner, which raises the others as a failure of
-- the host.
data EventTally = EventTally
  { tallyStarted ∷ !Int
    -- ^ /Started/ events produced.
  , tallyEnded ∷ !Int
    -- ^ /Ended/ events produced.
  , tallyAttempts ∷ !Int
    -- ^ Delivery attempts, all of them.
  , tallyAdmitted ∷ !Int
    -- ^ Attempts admitted on arrival (an elapsed VM).
  , tallyStaged ∷ !Int
    -- ^ Attempts held for their tick (a tick VM). A held attempt can still fail at its tick, below.
  , tallyQueueFull ∷ !Int
    -- ^ Attempts refused when offered, because the subscriber's queue was full: counted, nothing
    -- evicted or retried, nothing failed.
  , tallyStagingFull ∷ !Int
    -- ^ The same, because the store of events held for ticks was full.
  , tallySubscriptionEnded ∷ !Int
    -- ^ Attempts for a subscription that had ended: counted, benign.
  , tallyWatchersFailed ∷ !Int
    -- ^ Watcher instances an event already held for a tick failed, because their queue was full at that
    -- tick: LUA-26's delivery error, which the run reports once like any instance failure.
  }
  deriving (Eq, Show)

-- | Nothing produced, nothing attempted.
noTally ∷ EventTally
noTally = EventTally 0 0 0 0 0 0 0 0 0

-- | What a run answers: the arguments were refused, or it ran.
data RunOutcome
  = -- | The scripts or the limit were refused as usage, before any instance was admitted and before
    -- any hook ran. A distinct result, not a report of a run, so the command line can map it.
    Refused !UsageRefusal
  | Ran !RunReport
  deriving (Eq, Show)

-- | One instance's settlement as the report keeps it.
data InstanceReport = InstanceReport
  { instanceTid ∷ !InstanceId
  , instanceNameText ∷ !Text
    -- ^ The name, with control characters replaced.
  , instanceFile ∷ !Text
    -- ^ The path as it was given, bounded and with control characters replaced.
  , instanceStatus ∷ !InstancePhase
    -- ^ The terminal phase.
  , instanceEnd ∷ !InstanceEnd
  , instanceShutdown ∷ !ShutdownDisposition
    -- ^ What became of @shutdown@.
  }
  deriving (Eq, Show)

-- | How an instance ended.
data InstanceEnd
  = EndCompleted
  | EndStopped
  | EndFailed !FailureReport
  | -- | The owner exited without retiring it in order: only after a host failure or a
    -- cancellation, which a run propagates, so a returned report never carries it.
    EndDiscarded !Discard
  deriving (Eq, Show)

-- | A failed instance, bounded: what the report and the failure text show.
data FailureReport = FailureReport
  { frTid ∷ !InstanceId
  , frVm ∷ !Text
  , frName ∷ !Text
  , frFile ∷ !Text
  , frPhase ∷ !InstancePhase
    -- ^ The phase it was in when its primary failure happened.
  , frStage ∷ !Text
    -- ^ The hook or invocation: @init@, @run@, @update@, @event <source>@, @shutdown@ or @release@.
  , frError ∷ !Text
  , frTraceback ∷ !(Maybe Text)
  , frSecondary ∷ ![SecondaryFailure]
    -- ^ What else failed while the instance ended, at most 'secondaryLimit' of them.
  , frOmitted ∷ !Int
    -- ^ How many further secondary failures were not kept.
  }
  deriving (Eq, Show)

-- | A failure that was not the primary one: its stage and its error.
data SecondaryFailure = SecondaryFailure
  { secondaryStage ∷ !Text
  , secondaryError ∷ !Text
  }
  deriving (Eq, Show)

-- | Why a source did not load.
data LoadProblem
  = -- | The file does not exist.
    LoadMissing
  | -- | The file could not be read: not a file, not permitted, or a failed read.
    LoadUnreadable
  | -- | The file is larger than the host's source limit.
    LoadTooLarge
  | -- | The host refused or could not load it: a syntax error, a top-level error, an identity or a
    -- module count it refuses.
    LoadRejected
  deriving (Eq, Show)

-- | A source that did not load, which fails the VM's start. It names no instance.
data LoadFailure = LoadFailure
  { loadFile ∷ !Text
    -- ^ The path as it was given.
  , loadVm ∷ !Text
  , loadProblem ∷ !LoadProblem
  , loadError ∷ !Text
  , loadTraceback ∷ !(Maybe Text)
  }
  deriving (Eq, Show)

-- | The arguments were refused. Every reason, in script order.
newtype UsageRefusal = UsageRefusal (NonEmpty UsageViolation)
  deriving (Eq, Show)

-- | One reason, and the script it names, when it names one.
data UsageViolation = UsageViolation
  { violationScript ∷ !(Maybe Text)
    -- ^ The path as it was given.
  , violationReason ∷ !UsageReason
  }
  deriving (Eq, Show)

-- | Why the arguments were refused.
data UsageReason
  = -- | No scripts at all.
    NoScripts
  | -- | More scripts than a run admits: how many were given and the most a run admits.
    TooManyScripts !Int !Int
  | -- | The script's interval is zero.
    IntervalNotPositive
  | -- | The run limit is zero.
    LimitNotPositive
  | -- | The tick duration is zero.
    TickDurationNotPositive
  | -- | An elapsed interval on a tick VM.
    ElapsedIntervalOnTickClock
  | -- | A tick interval on an elapsed VM.
    TickIntervalOnElapsedClock
  | -- | A tick limit with no tick duration.
    TickLimitNeedsTickClock
  | -- | A tick count, as an interval or as the limit, that is zero or negative.
    TickCountNotPositive
  | -- | A tick count, as an interval or as the limit, that does not fit a 64-bit tick.
    TickCountTooLarge
  | -- | The module defines both @run@ and @update@.
    ModuleDefinesRunAndUpdate
  | -- | The module defines @update@ and the script has no interval.
    UpdateNeedsInterval
  | -- | The script has an interval and its module does not define @update@.
    IntervalWithoutUpdate
  deriving (Eq, Show)

-- | A refusal's reason as one bounded line.
usageText ∷ UsageViolation → Text
usageText (UsageViolation file reason) =
  maybe "" (\path → path <> ": ") file <> case reason of
    NoScripts → "no scripts were given"
    TooManyScripts given most → Text.pack (show given) <> " scripts were given and a run admits at most " <> Text.pack (show most)
    IntervalNotPositive → "the interval is zero"
    LimitNotPositive → "the run limit is zero"
    TickDurationNotPositive → "the tick duration is zero"
    ElapsedIntervalOnTickClock → "an elapsed interval was given and the VM runs on ticks"
    TickIntervalOnElapsedClock → "a tick interval was given and the VM runs on elapsed time"
    TickLimitNeedsTickClock → "a tick limit was given and the VM runs on elapsed time"
    TickCountNotPositive → "a tick count is not positive"
    TickCountTooLarge → "a tick count does not fit a tick"
    ModuleDefinesRunAndUpdate → "the module defines both run and update"
    UpdateNeedsInterval → "the module defines update and no interval was given"
    IntervalWithoutUpdate → "an interval was given and the module does not define update"

-- Bounds ---------------------------------------------------------------------------------------

-- | The most scripts a run admits: the live-instance bound.
runnerMaxScripts ∷ Int
runnerMaxScripts = 64

-- | The instance bounds of every run: 'runnerMaxScripts' live instances, twice as many result
-- reservations, a queue of twice as many invocations for each instance (a watcher with one
-- subscription is handed at most two events by each instance of a full run, and a queue that holds them
-- all is what keeps an event held for a tick from being lost to a full queue in the ordinary case) and
-- 64 control requests.
runnerInstanceBounds ∷ InstanceBounds
runnerInstanceBounds =
  InstanceBounds
    { boundLiveInstances = runnerMaxScripts
    , boundRetainedInstances = 2 * runnerMaxScripts
    , boundInvocationQueue = 2 * runnerMaxScripts
    , boundInstanceControls = 64
    }

-- | The scheduler bounds of every run: room for every instance's invocation to be active, queued
-- and retained (twice over for results, as the instance bounds require), service quanta of four
-- segments in each class, one outstanding grant (a run grants none), 64 control requests and no
-- service budget.
runnerSchedulerBounds ∷ SchedulerBounds
runnerSchedulerBounds =
  SchedulerBounds
    { boundActiveTasks = runnerMaxScripts
    , boundQueuedAdmissions = runnerMaxScripts
    , boundRetainedResults = 2 * runnerMaxScripts
    , boundQuanta = Quanta (Quantum 4) (Quantum 4) (Quantum 4)
    , boundOutstandingGrants = 1
    , boundControlRequests = 64
    , boundServiceBudget = Nothing
    }

-- | The name the lifecycle bindings are registered under: a script calls @lifecycle.pause@,
-- @lifecycle.resume@, @lifecycle.stop@, @lifecycle.inspect@, @lifecycle.inspect_owner@,
-- @lifecycle.owners@, @lifecycle.self@, @lifecycle.result@ and @lifecycle.forget@.
runnerLifecycleName ∷ Text
runnerLifecycleName = "lifecycle"

-- | The name of the one event endpoint every instance is granted: a script subscribes with
-- @api.subscribe("instances", callback)@.
runnerEventsName ∷ Text
runnerEventsName = "instances"

-- | The most subscriptions a run holds: four for each script. A subscription holds its place until it
-- has ended and the runner has proved its retirement, which it does at once.
runnerSubscriptionBound ∷ Int
runnerSubscriptionBound = 4 * runnerMaxScripts

-- | The most deliveries a tick VM holds for ticks it has not reached: sized so that a watcher with one
-- subscription in a run of 'runnerMaxScripts' scripts, each of which produces at most two events, never
-- fills it (that is 128 deliveries). A run with more subscriptions can, and the delivery is then refused
-- and counted.
runnerStagingBound ∷ Int
runnerStagingBound = 1024

-- | The most bytes one call of @print@ or @warn@ writes, as it is written: the UTF-8 bytes of its
-- lines, each line counting one more for its end, and the marker, when there is one, included.
outputCallLimit ∷ Int
outputCallLimit = 4096

-- | What a cut of a line, a name or a call leaves in its place.
truncationMarker ∷ Text
truncationMarker = "..."

-- | The widest the owner and name columns of a table are, in characters.
columnLimit ∷ Int
columnLimit = 32

-- | The most secondary failures a failure report keeps.
secondaryLimit ∷ Int
secondaryLimit = 8

-- | The most characters of an error a report keeps, as written: after its control characters are replaced.
errorLimit ∷ Int
errorLimit = 1024

-- | The most characters of a traceback a report keeps, as written.
tracebackLimit ∷ Int
tracebackLimit = 4096

-- | The most characters of an instance's name the runner gives the instance, as written.
nameLimit ∷ Int
nameLimit = 64

-- | The most characters of a path a report keeps, as written.
pathLimit ∷ Int
pathLimit = 256
