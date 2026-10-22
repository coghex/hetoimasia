{-# LANGUAGE OverloadedStrings #-}

-- | The M1 selection of a role's behavior: which export field a role is, what its
-- cadence fields mean and how they convert, and the profile's limits for the export
-- modules of one VM, over the Lua runtime's generic behavior mechanism.
--
-- __What is here and what is not.__ The mechanism that evaluates an export module,
-- keeps its table in the VM, validates a behavior's fixed schema and captures its
-- hooks for an instance lives in the Lua host and runtime
-- (@hetoimasia-scripting-lua@); it knows no role. This module is the policy over
-- it: @gameplay@ and @presentation@ are the two fields a role can select, the
-- cadence rules of each are the ones below, and the limits come from the M1 profile.
-- It opens no file, starts no VM, evaluates nothing and performs no IO: everything
-- here is a pure function from what a behavior table read as to an interval or a
-- refusal. The concrete content, time, graphics and status services of a behavior's
-- facade are not here: the facade is a value the caller injects.
--
-- __Cadence.__ Applied to a behavior that has an @update@ hook; a behavior without
-- one has neither cadence field, and a field on it is an error.
--
-- * Gameplay: @every_ticks@ defaults to 1 and, when given, must be a Lua integer from
--   1 through 2^63 − 1. @every_seconds@ is refused. An integer-valued float such as
--   @1.0@, a numeric string, zero, a negative number and a table are refused: nothing
--   is coerced.
-- * Presentation: @every_seconds@ is required and @every_ticks@ refused. The seconds
--   may be a Lua integer or float, must be finite and positive, and the exact value
--   the number represents, times 1,000,000,000 and rounded /upward/, must fit a
--   positive 'Word64' of nanoseconds. There is no default interval, no rounding down,
--   and no reading of the source's decimal literal: @0.1@ is the nearest double to a
--   tenth, whose exact value is what converts.
module Hetoimasia.LuaEngine.Behavior
  ( -- * Selection
    behaviorField
    -- * Limits
  , exportLimits
    -- * Cadence
  , CadenceKey (..)
  , CadenceRefusal (..)
  , cadenceOf
    -- * Instances
  , behaviorRequest
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Time (DurationRejected (..), DurationRequirement (RequirePositive), durationFromNanoseconds)
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (ModuleSourceBytes)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (ModuleIdentitiesPerVm)
  , Profile
  , bytesLimit
  , countLimit
  )
import Hetoimasia.Scripting.Lua.Instance (BehaviorFacade, BehaviorRequest (..), Interval (..))
import Hetoimasia.Scripting.Lua.Owner
  ( BehaviorShape (..)
  , CadenceField (..)
  , ExportIdentity
  , ExportLimits (..)
  )
import Hetoimasia.Scripting.Lua.Scheduled (ServiceClass)

-- | The field of a module's export table that holds a role's behavior. Selected by
-- raw access: nothing else in the table is looked at.
behaviorField ∷ Role → Text
behaviorField = \case
  Gameplay → "gameplay"
  Presentation → "presentation"

-- | The ceilings a VM holds its export modules to under a profile: the source a new
-- evaluation may be given, and the module identities the VM may hold, failed and
-- in-progress ones included. The fixed M1 profile's are one mebibyte and 256.
exportLimits ∷ Profile → ExportLimits
exportLimits profile =
  ExportLimits
    { exportMaxSourceBytes = fromIntegral sourceBytes
    , exportMaxIdentities = fromIntegral identities
    }
  where
    Bytes sourceBytes = bytesLimit profile ModuleSourceBytes
    Count identities = countLimit profile ModuleIdentitiesPerVm

-- | A cadence field of a behavior table.
data CadenceKey = EveryTicks | EverySeconds
  deriving (Eq, Show)

-- | Why a behavior's cadence was refused. Each names the field and what was wrong.
data CadenceRefusal
  = -- | The behavior has no @update@ hook, and the field is there.
    CadenceWithoutUpdate !CadenceKey
  | -- | The role does not take the field: gameplay is logical and takes no seconds,
    -- presentation is elapsed and takes no ticks.
    FieldNotAllowed !Role !CadenceKey
  | -- | @every_ticks@ is not a Lua integer: an integer-valued float, a numeric string
    -- and anything else are refused, not converted. What it read as.
    TicksNotInteger !CadenceField
  | -- | @every_ticks@ is a Lua integer below one.
    TicksNotPositive !Int64
  | -- | A presentation with an @update@ hook has no @every_seconds@.
    SecondsRequired
  | -- | @every_seconds@ is not a number. What it read as.
    SecondsNotNumber !CadenceField
  | -- | @every_seconds@ is not finite.
    SecondsNotFinite
  | -- | @every_seconds@ is zero or negative.
    SecondsNotPositive
  | -- | @every_seconds@, exactly, times 1,000,000,000 nanoseconds and rounded upward,
    -- does not fit a positive 64-bit count.
    SecondsTooLarge
  deriving (Eq, Show)

-- | A behavior's cadence under a role, from what its table read as: the interval its
-- @update@ hook falls due on ('Nothing' for a behavior with no @update@, which has
-- none), or the first reason it is refused.
cadenceOf ∷ Role → BehaviorShape → Either CadenceRefusal (Maybe Interval)
cadenceOf role shape
  | not (shapeUpdate shape) = case (ticks, seconds) of
      (FieldAbsent, FieldAbsent) → Right Nothing
      (FieldAbsent, _) → Left (CadenceWithoutUpdate EverySeconds)
      _ → Left (CadenceWithoutUpdate EveryTicks)
  | otherwise = Just <$> case role of
      Gameplay → case (seconds, ticks) of
        (FieldAbsent, _) → logicalTicks ticks
        _ → Left (FieldNotAllowed Gameplay EverySeconds)
      Presentation → case (ticks, seconds) of
        (FieldAbsent, _) → elapsedSeconds seconds
        _ → Left (FieldNotAllowed Presentation EveryTicks)
  where
    ticks = shapeEveryTicks shape
    seconds = shapeEverySeconds shape
    -- A whole count of ticks: one by default, a Lua integer when given.
    logicalTicks = \case
      FieldAbsent → Right (LogicalTicks 1)
      FieldInteger count
        | count >= 1 → Right (LogicalTicks (toInteger count))
        | otherwise → Left (TicksNotPositive count)
      other → Left (TicksNotInteger other)
    -- An elapsed interval: required, either Lua number, finite and positive, its
    -- exact value converted to whole nanoseconds rounded upward by checked integer
    -- arithmetic, never by floating multiplication.
    elapsedSeconds = \case
      FieldAbsent → Left SecondsRequired
      FieldInteger whole
        | whole <= 0 → Left SecondsNotPositive
        | otherwise → nanoseconds (toInteger whole * nanosecondsPerSecond)
      FieldFloat number
        | isNaN number || isInfinite number → Left SecondsNotFinite
        | number <= 0 → Left SecondsNotPositive
        | otherwise → nanoseconds (ceiling (toRational number * fromInteger nanosecondsPerSecond))
      other → Left (SecondsNotNumber other)
    nanoseconds count = case durationFromNanoseconds RequirePositive count of
      Right duration → Right (ElapsedEvery duration)
      Left DurationNegative → Left SecondsNotPositive
      Left DurationZero → Left SecondsNotPositive
      Left _ → Left SecondsTooLarge
    nanosecondsPerSecond = 1000000000

-- | The request that admits an instance of a role's behavior: the export module the
-- owner holds under the identity, the role's field selected from it, the facade the
-- caller injects, and the role's cadence rule. Captured and validated on the owner's
-- thread when the instance starts, before its @init@; a refusal fails the instance
-- with the rule's reason, rendered, before any hook runs.
--
-- The role and the facade are the caller's: nothing a module's metadata says chooses
-- either.
behaviorRequest ∷ Role → ExportIdentity → Text → BehaviorFacade → Maybe Text → ServiceClass → BehaviorRequest
behaviorRequest role identity label facade name serviceClass =
  BehaviorRequest
    { behaviorExport = identity
    , behaviorLabel = label
    , behaviorSelect = behaviorField role
    , behaviorFacade = facade
    , behaviorCadence = either (Left . Text.pack . show) Right . cadenceOf role
    , behaviorName = name
    , behaviorClass = serviceClass
    }
