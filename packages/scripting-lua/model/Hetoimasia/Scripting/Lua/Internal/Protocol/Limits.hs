-- | The bounds a session is constructed with, and the service classes and
-- quanta a scheduler reads off it.
--
-- P-5 requires active tasks, queued admissions, registered subscriptions,
-- outstanding requests, payload size, and retained terminal results to be
-- bounded. All six are configuration, and all six are validated once, at
-- construction: 'validateLimits' answers every violation it found rather than
-- the first, and a 'ValidLimits' can be obtained no other way, so a session
-- cannot be built over a configuration nobody checked.
--
-- = What the caps mean
--
-- * 'maxActiveTasks' bounds tasks that have left the admission queue, whatever
--   state they are in.
-- * 'maxQueuedAdmissions' bounds admissions accepted but not yet activated.
-- * 'maxRetainedResults' bounds /reservations/, not stored results. A
--   reservation is taken when an admission is accepted and released when its
--   terminal result is observed or discarded, so a completed task whose result
--   nobody reads still occupies the storage admission already paid for. That is
--   what makes storage bounded when results are not promptly observed, and it
--   is why there is no separate ticket history to grow.
-- * 'maxOutstandingRequests' bounds request bookkeeping, which a request holds
--   until /both/ its obligations are discharged: its result observed or
--   discarded, and its provider's work known to have ended. Discharging one
--   never discharges the other; see
--   "Hetoimasia.Scripting.Lua.Internal.Protocol.Request".
-- * 'maxSubscriptions' bounds registered subscriptions, and
--   'maxSubscriptionQueue' bounds one ordered-event subscription's undelivered
--   backlog. A replaceable-state subscription holds one value whatever this
--   says, because coalescing to the newest value is what its policy means.
-- * 'maxPayloadBytes' bounds a single payload. The model compares the size the
--   caller declares; it never measures the value, which it does not inspect.
--
-- = Quanta
--
-- 'Quanta' fixes a finite segment budget per 'ServiceClass'. This slice records
-- it and enforces nothing: which task runs next, and whether its class still
-- has budget, is LUA-6's choice function. Storing the budget here is what lets
-- that choice be made without the scheduler inventing its own policy.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( -- * Service classes
    ServiceClass (..)
  , serviceClasses

    -- * Quanta
  , Quantum (..)
  , Quanta (..)
  , quantumFor

    -- * Caps
  , Limits (..)
  , LimitName (..)
  , limitValue

    -- * Validation
  , ValidLimits
  , limitsOf
  , LimitViolation (..)
  , validateLimits
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty

-- | The fixed service classes of P-5.
--
-- Fixed rather than an open priority number: a script cannot invent a class
-- above the ones the engine serves, so \"high priority\" work cannot bypass a
-- quota by asking for it.
data ServiceClass
  = -- | Control and events. Small, latency-sensitive, still quantised.
    ControlClass
  | -- | Ordinary ready work.
    OrdinaryClass
  | -- | Background work, served when its peers yield.
    BackgroundClass
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Every service class, in class order.
serviceClasses ∷ [ServiceClass]
serviceClasses = [minBound .. maxBound]

-- | A finite segment budget for one class.
newtype Quantum = Quantum {quantumSegments ∷ Int}
  deriving (Eq, Ord, Show)

-- | The budget of each class.
data Quanta = Quanta
  { controlQuantum ∷ !Quantum
  , ordinaryQuantum ∷ !Quantum
  , backgroundQuantum ∷ !Quantum
  }
  deriving (Eq, Show)

-- | The budget a class is configured with.
quantumFor ∷ ServiceClass → Quanta → Quantum
quantumFor ControlClass = controlQuantum
quantumFor OrdinaryClass = ordinaryQuantum
quantumFor BackgroundClass = backgroundQuantum

-- | A session's configured bounds.
data Limits = Limits
  { maxActiveTasks ∷ !Int
  , maxQueuedAdmissions ∷ !Int
  , maxSubscriptions ∷ !Int
  , maxSubscriptionQueue ∷ !Int
  , maxOutstandingRequests ∷ !Int
  , maxPayloadBytes ∷ !Int
  , maxRetainedResults ∷ !Int
  , limitQuanta ∷ !Quanta
  }
  deriving (Eq, Show)

-- | Which cap a violation or a rejection is about.
data LimitName
  = ActiveTasks
  | QueuedAdmissions
  | Subscriptions
  | SubscriptionQueue
  | OutstandingRequests
  | PayloadBytes
  | RetainedResults
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Read one cap by name.
limitValue ∷ LimitName → Limits → Int
limitValue ActiveTasks = maxActiveTasks
limitValue QueuedAdmissions = maxQueuedAdmissions
limitValue Subscriptions = maxSubscriptions
limitValue SubscriptionQueue = maxSubscriptionQueue
limitValue OutstandingRequests = maxOutstandingRequests
limitValue PayloadBytes = maxPayloadBytes
limitValue RetainedResults = maxRetainedResults

-- | Limits that have been validated.
--
-- The constructor is not exported: 'validateLimits' is the only way to obtain
-- one, so \"the caps were checked\" is a property of the type rather than of
-- the call site.
newtype ValidLimits = ValidLimits Limits
  deriving (Eq, Show)

-- | The configuration inside validated limits.
limitsOf ∷ ValidLimits → Limits
limitsOf (ValidLimits limits) = limits

-- | Why a configuration was refused.
data LimitViolation
  = -- | A cap that is not at least one. A zero cap admits nothing, which is a
    -- session that cannot run rather than a session that is very small.
    NonPositiveLimit !LimitName !Int
  | -- | A class whose segment budget is not at least one.
    NonPositiveQuantum !ServiceClass !Int
  deriving (Eq, Show)

-- | Validate a configuration, answering every violation.
--
-- Every violation rather than the first: a configuration with three bad caps
-- should be fixed once, not three times.
validateLimits ∷ Limits → Either (NonEmpty LimitViolation) ValidLimits
validateLimits limits =
  case NonEmpty.nonEmpty (capViolations <> quantumViolations) of
    Nothing → Right (ValidLimits limits)
    Just violations → Left violations
  where
    capViolations =
      [ NonPositiveLimit name value
      | name ← [minBound .. maxBound]
      , let value = limitValue name limits
      , value < 1
      ]
    quantumViolations =
      [ NonPositiveQuantum serviceClass segments
      | serviceClass ← serviceClasses
      , let segments = quantumSegments (quantumFor serviceClass (limitQuanta limits))
      , segments < 1
      ]
