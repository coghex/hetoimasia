-- | What a window host is built from, and the checks that run before anything
-- is acquired.
--
-- Values only: nothing here reads a clock, enters a session, or touches a
-- window. A 'HostConfig' is validated on the thread that constructs the host,
-- before the session is entered, and is then fixed for the host's lifetime and
-- read by the process main thread that owns it.
module Hetoimasia.Runtime.GLFW.Internal.Host.Config
  ( HostConfig (..)
  , defaultHostConfig
  , HostConfigRejected (..)
  , maximumIdleWait
  , maximumWindowLimit
  , validateHostConfig
  , idleWaitDuration
  , waitSeconds
  , hostComponent
  ) where

import Control.Exception (Exception)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Channel (maximumCapacity)
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRejected
  , DurationRequirement (RequirePositive)
  , MonotonicSource
  , convertedDuration
  , convertedRounding
  , durationFromNanoseconds
  , durationFromSeconds
  , durationNanoseconds
  , monotonicSource
  )
import Hetoimasia.GLFW.Session (SessionConfig, defaultSessionConfig)
import Hetoimasia.GLFW.Window (WindowConfig)

-- | What a host is built from. A pure value, validated before anything is
-- acquired.
data HostConfig = HostConfig
  { hostSessionConfig ∷ !SessionConfig
    -- ^ The session 'allocWindowHost' enters. 'allocWindowHostIn' ignores it.
  , hostWindowConfigs ∷ ![WindowConfig]
    -- ^ The windows created when the host is built, in order. It may be empty.
  , hostWindowLimit ∷ !Int
    -- ^ The most windows the host holds live at once, closing windows included.
    -- At least one, at least as many as 'hostWindowConfigs', and at most
    -- 'maximumWindowLimit'.
  , hostCommandCapacity ∷ !Integer
    -- ^ How many commands the host's port, and each window's own port, holds
    -- queued.
  , hostInputCapacity ∷ !Integer
    -- ^ How many input events each window's feed holds queued. At least one,
    -- and at most 'Hetoimasia.Foundation.Messaging.Channel.maximumCapacity'.
  , hostCommandBudget ∷ !Int
    -- ^ The most commands one turn attempts, across every port. At least one.
  , hostEventBudget ∷ !Int
    -- ^ The most application events one turn dispatches. At least one.
  , hostRetirementBudget ∷ !Int
    -- ^ The most attachment retirement opportunities one turn offers, across
    -- every window with a pending retirement. At least one. Pending retirements
    -- are served in rotating order, so one window's stalled or slow retirement
    -- can never starve another's, and an attachment no round has yet offered an
    -- opportunity to keeps the next turn immediate however short the budget
    -- fell. Once every one of them has been offered and is waiting, the turn
    -- waits toward the earliest instant they named, bounded by 'hostIdleWait':
    -- more waiting attachments than this budget is an ordinary idle host, not a
    -- reason to poll. An ordinary host holds no attachment, so nothing spends
    -- it.
  , hostIdleWait ∷ !Double
    -- ^ The most seconds an idle turn waits for a native event, and the
    -- scheduled path's fallback bound. Finite, above zero, at most
    -- 'maximumIdleWait', and at least one whole nanosecond, so it is always a
    -- positive 'Duration' that never exceeds the seconds configured.
  , hostClock ∷ !MonotonicSource
    -- ^ The monotonic source 'runScheduledOwnerLoop' samples, and the clock
    -- domain every deadline it is given belongs to. 'runOwnerLoop' never reads
    -- it. A seam example configures a 'Hetoimasia.Foundation.Time.scriptedSource'
    -- here and scripts every reading exactly.
  }

-- | Every field but the injected clock, which is an action rather than a value.
instance Show HostConfig where
  show config =
    "HostConfig {hostSessionConfig = "
      <> show (hostSessionConfig config)
      <> ", hostWindowConfigs = "
      <> show (hostWindowConfigs config)
      <> ", hostWindowLimit = "
      <> show (hostWindowLimit config)
      <> ", hostCommandCapacity = "
      <> show (hostCommandCapacity config)
      <> ", hostInputCapacity = "
      <> show (hostInputCapacity config)
      <> ", hostCommandBudget = "
      <> show (hostCommandBudget config)
      <> ", hostEventBudget = "
      <> show (hostEventBudget config)
      <> ", hostRetirementBudget = "
      <> show (hostRetirementBudget config)
      <> ", hostIdleWait = "
      <> show (hostIdleWait config)
      <> ", hostClock = <injected>}"

-- | The platform's own session, the given windows, a limit of 16 live windows,
-- a command capacity of 64, an input capacity of 256, command and event budgets
-- of 16, a retirement budget of 4, a 0.1-second idle wait, and the process's
-- monotonic clock.
defaultHostConfig ∷ [WindowConfig] → HostConfig
defaultHostConfig windows =
  HostConfig
    { hostSessionConfig = defaultSessionConfig
    , hostWindowConfigs = windows
    , hostWindowLimit = 16
    , hostCommandCapacity = 64
    , hostInputCapacity = 256
    , hostCommandBudget = 16
    , hostEventBudget = 16
    , hostRetirementBudget = 4
    , hostIdleWait = 0.1
    , hostClock = monotonicSource
    }

-- | A host configuration refused before anything was acquired.
data HostConfigRejected
  = CommandBudgetRejected !Int
  | EventBudgetRejected !Int
  | RetirementBudgetRejected !Int
  | IdleWaitRejected !Double
  | WindowLimitRejected !Int
    -- ^ The limit is below one, below the number of configured windows, or
    -- above 'maximumWindowLimit'.
  | InputCapacityRejected !Integer
  deriving (Eq, Show)

instance Exception HostConfigRejected

-- | The longest idle wait a configuration may ask for, in seconds.
maximumIdleWait ∷ Double
maximumIdleWait = 60

-- | The most live windows a configuration may ask for.
--
-- Far above what any platform hosts at once, and low enough that every count a
-- host derives from it — the protected host's completion inbox holds one notice
-- per retirement fact per window — is an exact 'Int', never a wrapped one. A
-- configuration above it is refused before anything is acquired, as one below
-- one is.
maximumWindowLimit ∷ Int
maximumWindowLimit = 1024

-- | Check the budgets, the idle wait, the window limit, and the input capacity.
-- The session, window, and command capacity settings are checked by the
-- operations they configure.
validateHostConfig ∷ HostConfig → Either HostConfigRejected ()
validateHostConfig config
  | hostCommandBudget config < 1 = Left (CommandBudgetRejected (hostCommandBudget config))
  | hostEventBudget config < 1 = Left (EventBudgetRejected (hostEventBudget config))
  | hostRetirementBudget config < 1 = Left (RetirementBudgetRejected (hostRetirementBudget config))
  -- Written so a NaN, which fails every comparison, is refused too.
  | not (wait > 0 && wait <= maximumIdleWait) = Left (IdleWaitRejected wait)
  -- A wait of less than a whole nanosecond is no bound the scheduled path could
  -- wait for, so it is refused here rather than rounded up to one.
  | Left _ ← idleWaitDuration config = Left (IdleWaitRejected wait)
  | limit < 1 || limit < length (hostWindowConfigs config) || limit > maximumWindowLimit =
      Left (WindowLimitRejected limit)
  | input < 1 || input > maximumCapacity = Left (InputCapacityRejected input)
  | otherwise = Right ()
  where
    wait = hostIdleWait config
    limit = hostWindowLimit config
    input = hostInputCapacity config

-- | The configured fallback bound as a positive 'Duration', or why those
-- seconds are none. 'validateHostConfig' refuses a configuration this rejects,
-- so an accepted host always has one.
--
-- The bound is an upper bound, so the conversion may never round up past the
-- seconds configured: 'durationFromSeconds' rounds to the nearest nanosecond
-- and reports the rounding it applied, and a positive rounding means the whole
-- nanosecond below is the real bound. A wait that floors to no nanoseconds at
-- all — anything under one, which nearest-rounding would otherwise accept as
-- one — is refused rather than lengthened.
idleWaitDuration ∷ HostConfig → Either DurationRejected Duration
idleWaitDuration config = do
  converted ← durationFromSeconds RequirePositive (hostIdleWait config)
  let nanoseconds = toInteger (durationNanoseconds (convertedDuration converted))
  durationFromNanoseconds
    RequirePositive
    (if convertedRounding converted > 0 then nanoseconds - 1 else nanoseconds)

-- | A duration as the seconds a native timed wait takes.
--
-- This is the GLFW layer's one conversion out of 'Duration', and the scheduled
-- loop waits only for a positive duration, so the value it passes to
-- 'AwaitEventsFor' is always finite and above zero.
waitSeconds ∷ Duration → Double
waitSeconds duration = fromIntegral (durationNanoseconds duration) / 1e9

-- | The component a host's own failures are attributed to.
hostComponent ∷ Component
hostComponent = unsafeComponent "glfw.runtime"
