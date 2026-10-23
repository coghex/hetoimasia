-- | The logical clock's pacing arithmetic, as pure checked functions.
--
-- Tick /n/ of a session is due /n/ tick durations after the instant the start gate opened, on the
-- injected clock. Each tick is granted by itself, at its own due time or as soon after as the owner is
-- free; none is skipped, merged or shortened, and the duration of each is the manifest's exactly. The
-- origin is the clock reading at the instant the joint start gate opens (or at a one-role session's own
-- @init@ success, which is the same instant for it), so the wall time the @init@s took earns no logical
-- time and leaves no debt.
--
-- Every number here is checked and none wraps: a due time the clock's range cannot hold, and a tick
-- number no Lua integer holds (2^63 - 1 at most; the first tick is 1), is a fault the coordinator ends
-- the session with, never a wrapped value that is published. The tick number a script reads is the
-- owner's tick plus the base the composition starts from (zero in production; a test of the ceiling
-- starts near it, which no manifest, Lua API or public composition can reach).
module Hetoimasia.LuaEngine.Session.Pacing
  ( -- * Limits
    luaTickCeiling

    -- * Faults
  , PacingFault (..)
  , pacingFaultText

    -- * Checks before Lua
  , initialDeadline

    -- * The schedule
  , Schedule (..)
  , startSchedule
  , nextTickNumber
  , afterGrant
  ) where

import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Foundation.Time (Duration, Instant, addDuration)

-- | The largest tick, offset and counter a Lua integer holds: 2^63 - 1.
luaTickCeiling ∷ Word64
luaTickCeiling = 9223372036854775807

-- | Why pacing cannot go on.
data PacingFault
  = -- | A due time past what the clock can count.
    DeadlineOverflow
  | -- | The next tick is past what a Lua integer holds.
    TickCeiling
  deriving (Eq, Show)

-- | The text a fault is reported as.
pacingFaultText ∷ PacingFault → Text
pacingFaultText = \case
  DeadlineOverflow → "the next logical tick is due past the end of the clock's range"
  TickCeiling → "the next logical tick is past the largest tick a Lua integer holds"

-- | The first tick's due time from a reading of the clock, for a check that runs before any Lua: a
-- first deadline the clock cannot count is already impossible.
initialDeadline ∷ Instant → Duration → Either PacingFault Instant
initialDeadline now tick = either (const (Left DeadlineOverflow)) Right (addDuration now tick)

-- | Where the ticks stand.
data Schedule = Schedule
  { scTick ∷ !Duration
  -- ^ The tick duration, exactly the manifest's.
  , scDue ∷ !Instant
  -- ^ When the next tick is due.
  , scGranted ∷ !Word64
  -- ^ How many ticks have been granted.
  , scBase ∷ !Word64
  -- ^ The tick number the composition counts from: zero in production.
  }
  deriving (Eq, Show)

-- | The schedule that starts at this origin: tick 1 is due one tick after it.
startSchedule ∷ Word64 → Instant → Duration → Either PacingFault Schedule
startSchedule base origin tick = (\due → Schedule tick due 0 base) <$> initialDeadline origin tick

-- | The number of the next tick, if a Lua integer holds it.
nextTickNumber ∷ Schedule → Either PacingFault Word64
nextTickNumber schedule
  | number > toInteger luaTickCeiling = Left TickCeiling
  | otherwise = Right (fromInteger number)
  where
    number = toInteger (scBase schedule) + toInteger (scGranted schedule) + 1

-- | The schedule after a tick has been granted: the next is due one tick later, if the clock can
-- count it.
afterGrant ∷ Schedule → Either PacingFault Schedule
afterGrant schedule = do
  due ← either (const (Left DeadlineOverflow)) Right (addDuration (scDue schedule) (scTick schedule))
  pure schedule {scDue = due, scGranted = scGranted schedule + 1}
