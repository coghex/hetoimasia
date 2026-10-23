{-# LANGUAGE OverloadedStrings #-}

-- | The role clocks and the cooperative waits of a facade (D-17, D-68, P-72 section 3, P-74 section 5).
--
-- = The two clocks
--
-- A gameplay VM's clock is the logical tick: an integer read live from the owner's scheduler through
-- the injected endpoint, which only a begun tick advances, so no load, native delay or slow hook moves
-- it. A presentation VM's clock is elapsed time on the injected monotonic source, measured from one
-- origin set when the VM begins its first instance's initialization, so that instance's first segment
-- reads zero and a later instance shares the origin. Presentation time is /sampled/: the owner tells
-- the facade whenever an instance's hook begins or resumes ('segmentStarted'), and a read inside the
-- segment is that sample, however many times and however late the script reads. A resumed segment
-- takes a new sample, so the time a wait or a load took is seen only after it. A sample is a
-- finite approximation of the exact nanoseconds: never the authority for a deadline.
--
-- = The waits
--
-- @wait_ticks(n)@ and @wait_seconds(s)@ suspend the instance's current update, and @yield()@ gives
-- control back; all three are the host's scheduler operations, refused as ordinary Lua errors before
-- anything is suspended unless an instance of the right role is serving (an update or a callback). Their
-- arguments are checked first by a /preparing/ binding that decides every fact a script can get wrong:
-- @n@ is a Lua integer from 1 and its target tick is a Lua integer too; @s@ is a finite positive
-- number whose exact value times 1,000,000,000 rounded upward is a positive 'Word64' count of
-- nanoseconds ('elapsedDuration', the conversion of a presentation cadence), and the clock now plus that
-- count is representable. The count crosses to the suspending binding as the two 32-bit halves of the
-- number, which the scheduler reads as one count ('Hetoimasia.Scripting.Lua.Scheduled'), so a wait
-- passes the 2^63 - 1 a Lua integer holds. The deadline is placed by the scheduler when the wait is
-- requested, not from the segment's sample, and a wake before it resumes nothing.
--
-- Arithmetic that fails after a call was validly admitted is an engine failure, reported through the
-- injected boundary and raised: a tick no Lua integer holds is never wrapped or clamped.
module Hetoimasia.LuaEngine.Facade.Time
  ( timeBindings
  , segmentStarted
  , forgetSamples
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVar, writeTVar)
import Control.Monad (when)
import Data.Bits (shiftR, (.&.))
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Time (Duration, addDuration, durationNanoseconds, elapsedBetween, readInstant)
import Hetoimasia.LuaEngine.Behavior (CadenceRefusal (..), elapsedDuration)
import Hetoimasia.LuaEngine.Facade.Bindings
import Hetoimasia.LuaEngine.Facade.Caller
  ( Calling (InInstance)
  , Caller (..)
  , Stage (..)
  , recordByNumber
  )
import Hetoimasia.LuaEngine.Facade.Types
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.Scripting.Lua.Instance (InstanceId (instanceLocal))
import Hetoimasia.Scripting.Lua.Owner (CadenceField (..))
import Hetoimasia.Scripting.Lua.Registration
  ( Binding
  , WaitKind (WaitElapsed, WaitLogical)
  , asynchronousNativeRequestIn
  , waitOperation
  , withArgumentCheck
  , withPrecondition
  , yieldOperation
  )
import Hetoimasia.Scripting.Lua.Value (Schema (SFloat, SInteger, SNumber), Value (VFloat, VInteger))

-- | The six calls of @api.time@, and the preparing bindings of the two waits. Their names are the hidden
-- namespace's; the initial chunk wraps each in the facade's own closure.
timeBindings ∷ Facade → [Binding]
timeBindings facade =
  [ clock "tick" [SInteger] Gameplay "tick is available to gameplay only" (readTick facade)
  , clock "tick_seconds" [SFloat] Gameplay "tick_seconds is available to gameplay only" tickSeconds
  , clock "seconds" [SFloat] Presentation "seconds is available to presentation only" (readSeconds facade)
  , withArgumentCheck prepareTicks (action "prepare_wait_ticks" [SInteger] [SInteger] (\_ values → pure values))
  , withArgumentCheck prepareSeconds (action "prepare_wait_seconds" [SNumber] [SInteger, SInteger] prepared)
  , withPrecondition (instanceCheck facade (waitRefusal Gameplay "wait_ticks is available to gameplay only")) (waitOperation "wait_ticks" WaitLogical [SInteger])
  , withPrecondition (instanceCheck facade (waitRefusal Presentation "wait_seconds is available to presentation only")) (waitOperation "wait_seconds" WaitElapsed [SInteger, SInteger])
  , withPrecondition (instanceCheck facade waitStage) (yieldOperation "yield")
  ]
  where
    -- A read of a clock: the role's own, in any hook of an instance (init and shutdown included).
    clock name results role refusal read' =
      withPrecondition (instanceCheck facade (requireRole role refusal)) $
        asynchronousNativeRequestIn name [] results $ \context _ → do
          calling ← callingIn facade context
          case calling of
            InInstance caller → read' caller
            _ → failEngine facade "a clock was read with no instance running"
    action name arguments results run = asynchronousNativeRequestIn name arguments results run
    tickSeconds _ = case fcTickDuration facade of
      Just duration → pure [VFloat (secondsOf duration)]
      Nothing → failEngine facade "a gameplay facade has no tick duration"

    -- The preparing checks. Each is made before anything is suspended or read twice, on the copied
    -- values, and refuses as an ordinary Lua error.
    prepareTicks = instanceArgumentCheck facade $ \caller values →
      case waitRefusal Gameplay "wait_ticks is available to gameplay only" caller of
        Just why → pure (Just why)
        Nothing → case values of
          [VInteger count]
            | count < 1 → pure (refuseText "wait_ticks needs a whole number of ticks from 1")
            | otherwise → do
                tick ← fcReadTick facade
                let ceiling' = luaMaximum facade
                -- A tick no Lua integer holds is the engine's fact and not the call's.
                when (tick > ceiling') $
                  failEngine facade ("the logical tick " <> Text.pack (show tick) <> " is past the largest Lua integer")
                pure $
                  if fromIntegral count > ceiling' - tick
                    then refuseText "wait_ticks would end past the largest tick"
                    else Nothing
          _ → pure (refuseText "wait_ticks needs a whole number of ticks")
    prepareSeconds = instanceArgumentCheck facade $ \caller values →
      case waitRefusal Presentation "wait_seconds is available to presentation only" caller of
        Just why → pure (Just why)
        Nothing → case secondsField values of
          Nothing → pure (refuseText "wait_seconds needs a number of seconds")
          Just field → case elapsedDuration field of
            Left refusal → pure (refuseText (describe refusal))
            Right duration → do
              now ← readInstant (endpointClock (fcEndpoints facade))
              pure $ case addDuration now duration of
                Left _ → refuseText "wait_seconds would end past the clock's range"
                Right _ → Nothing
    -- Converting is done again, on the owner's thread, with the same rule: the check did not keep it.
    prepared _ values = case secondsField values >>= either (const Nothing) Just . elapsedDuration of
      Just duration →
        let nanoseconds = durationNanoseconds duration
         in pure [VInteger (fromIntegral (nanoseconds `shiftR` 32)), VInteger (fromIntegral (nanoseconds .&. 0xFFFFFFFF))]
      Nothing → failEngine facade "a wait's seconds were valid at its check and are not at its action"

    secondsField = \case
      [VInteger whole] → Just (FieldInteger (whole ∷ Int64))
      [VFloat number] → Just (FieldFloat number)
      _ → Nothing

    describe = \case
      SecondsNotFinite → "wait_seconds needs a finite number"
      SecondsNotPositive → "wait_seconds needs a positive number"
      SecondsTooLarge → "wait_seconds is longer than the clock can count"
      _ → "wait_seconds needs a number of seconds"

-- | Why this caller may not wait: the wrong role, or not serving an update.
waitRefusal ∷ Role → Text → Caller → Maybe Text
waitRefusal role refusal caller = case requireRole role refusal caller of
  Just why → Just why
  Nothing → waitStage caller

-- | A wait or a yield is made by an instance that is serving: not in @init@, not in @shutdown@.
waitStage ∷ Caller → Maybe Text
waitStage caller = case callerStage caller of
  StageServing → Nothing
  StageInitializing → Just "a wait is not available in init"
  StageEnding → Just "a wait is not available in shutdown"

-- | The tick the owner is at, as the Lua integer a script is handed: one past 2^63 - 1 is never wrapped or
-- clamped but an engine failure.
readTick ∷ Facade → Caller → IO [Value]
readTick facade _ = do
  tick ← fcReadTick facade
  when (tick > luaMaximum facade) $
    failEngine facade ("the logical tick " <> Text.pack (show tick) <> " is past the largest Lua integer")
  pure [VInteger (fromIntegral tick)]

-- | The seconds since the origin, as of the segment the caller is running.
readSeconds ∷ Facade → Caller → IO [Value]
readSeconds facade caller = do
  sample ← atomically (Map.lookup (callerNumber caller) <$> readTVar (timeSamples (fcTime facade)))
  case sample of
    Just duration → pure [VFloat (secondsOf duration)]
    Nothing → failEngine facade "a presentation hook began without the facade being told: no sample of its segment"

-- | The exact nanoseconds as the nearest double of the exact seconds.
secondsOf ∷ Duration → Double
secondsOf duration = fromRational (toInteger (durationNanoseconds duration) % 1000000000)

-- | An instance's hook is about to begin or resume. A presentation facade takes the sample its reads
-- answer, setting the origin if this is the VM's first. Gameplay samples nothing: its clock is read live.
-- An instance this facade was not declared to is not remembered.
segmentStarted ∷ Facade → InstanceId → IO ()
segmentStarted facade instanceId = case fcRole facade of
  Gameplay → pure ()
  Presentation → do
    now ← readInstant (endpointClock (fcEndpoints facade))
    atomically $ do
      known ← recordByNumber (fcRegistry facade) (instanceLocal instanceId)
      case known of
        Nothing → pure ()
        Just _ → do
          origin ← readTVar (timeOrigin (fcTime facade))
          start ← case origin of
            Just found → pure found
            Nothing → now <$ writeTVar (timeOrigin (fcTime facade)) (Just now)
          modifyTVar' (timeSamples (fcTime facade)) (Map.insert (instanceLocal instanceId) (elapsedBetween start now))

-- | Forget an instance's sample.
forgetSamples ∷ Facade → Word64 → IO ()
forgetSamples facade number = atomically (modifyTVar' (timeSamples (fcTime facade)) (Map.delete number))

fcReadTick ∷ Facade → IO Word64
fcReadTick = endpointTick . fcEndpoints
