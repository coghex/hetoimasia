-- | What a scheduled owner's script instances are made of, and the state their two
-- sides share: the application's threads, which admit instances, deliver events
-- to them, ask to control them and read what became of them, and the owner's
-- thread, which runs their hooks.
--
-- Nothing here runs Lua or a worker. Every operation of the first kind is one STM
-- transaction that never blocks, from any thread, and answers at once. It is the
-- vocabulary "Hetoimasia.Scripting.Lua.Instance" speaks in; that module's header
-- is where the behavior is described.
module Hetoimasia.Scripting.Lua.Instance.Types
  ( -- * Identity
    InstanceId (..)

    -- * What an application admits
  , InstanceKind (..)
  , Interval (..)
  , IntervalRefusal (..)
  , Cadence (..)
  , resolveInterval
  , InstanceRequest (..)
  , EventSource (..)

    -- * Where an instance is
  , InstancePhase (..)
  , isTerminal
  , Execution (..)
  , InstanceSnapshot (..)

    -- * Events
  , Delivery (..)
  , EventRecord (..)

    -- * What an instance settles as
  , InstanceOutcome (..)
  , InstanceSettlement (..)
  , LeaseOutcome (..)
  , noLeases
  , Termination (..)
  , ShutdownDisposition (..)
  , HookStage (..)
  , InstanceError (..)
  , InstanceFailure (..)
  , Escalation (..)
  , InstanceEscalated (..)

    -- * Admission and results
  , InstanceAdmission (..)
  , InstanceTicket (..)

    -- * Control
  , InstanceControlAnswer (..)
  , InstanceControlReceipt (..)
  , InstanceControl (..)
  , ControlAdmission (..)
  , ControlSlot (..)
  , LogicalControl (..)

    -- * Bounds
  , InstanceBounds (..)
  , InstanceConfig (..)
  , InstanceViolation (..)
  , InstancesRefused (..)
  , validateInstanceConfig
  , defaultInstanceBounds
  , defaultInstanceConfig

    -- * Shared state
  , Instances (..)
  , ICell (..)
  , IState (..)
  , UpdateSlot (..)
  , pendingEvents
  , runOwed
  , updateOwed
  , unstartedCount
  , Job (..)
  , QueuedEvent (..)
  , newInstances
  , initialState
  , renderError
  , failureText
  ) where

import Control.Concurrent.STM (TVar, newTVarIO)
import Hetoimasia.Foundation.Time (Duration, ElapsedBaseline, durationNanoseconds, noBaseline, zeroDuration)
import Control.Exception (Exception)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (SubscriptionId, TaskId)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits (ServiceClass)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (TaskFailure)
import Hetoimasia.Scripting.Lua.Owner (ModuleRef, maxEntries)
import Hetoimasia.Scripting.Lua.Registration (validName)
import Hetoimasia.Scripting.Lua.Runtime.Types (CallFault, Discard, OwnerId)
import Hetoimasia.Scripting.Lua.Scheduler (ControlResult)
import Hetoimasia.Scripting.Lua.Value (Schema (..), Value)

-- Identity ---------------------------------------------------------------------

-- | An instance's identity, the TID: the owner that issued it and the owner's own
-- number for it.
--
-- Unique within the 'Hetoimasia.Scripting.Lua.Runtime.LuaRuntime' and never issued
-- again, not after the instance has ended and its result has been observed and not
-- after its owner has retired: the owner's identity is never reissued and the
-- numbers an owner issues never rewind. It names an instance and grants nothing;
-- it is not an OS thread, a @ThreadId@ or a coroutine, and neither it nor the
-- application's name for the instance is authority.
data InstanceId = InstanceId
  { instanceOwner ∷ !OwnerId
  , instanceLocal ∷ !Word64
  }
  deriving (Eq, Ord, Show)

-- What an application admits ----------------------------------------------------

-- | What an instance does after it initializes.
data InstanceKind
  = -- | It only reacts: events delivered to the callbacks it connected run, and it
    -- lives until it is stopped. It has no periodic interval, so no update is ever
    -- due.
    EventOnly
  | -- | It runs its module's @run@ hook to completion, and then ends. It has no
    -- periodic interval.
    RunOnce
  | -- | It reacts to events as an event-only instance does, and its module's
    -- @update(self, dt)@ hook falls due on this interval, chosen at admission and
    -- fixed for the instance's life. See "Hetoimasia.Scripting.Lua.Instance" for the
    -- cadence rules.
    Periodic !Interval
  deriving (Eq, Show)

-- | How often an instance's update falls due, as an application states it.
data Interval
  = -- | Gameplay's logical time: this many ticks. It must be positive and fit a
    -- tick count.
    LogicalTicks !Integer
  | -- | Gameplay's logical time, as a duration: it converts to ticks only when it
    -- is an exact multiple of the owner's configured tick duration
    -- ('instanceTickDuration'), and is refused otherwise. Nothing is rounded.
    LogicalDuration !Duration
  | -- | The UI's elapsed time: a positive duration on the owner's monotonic source.
    ElapsedEvery !Duration
  deriving (Eq, Show)

-- | Why an interval was refused at admission. Each names the input.
data IntervalRefusal
  = -- | Zero ticks, a non-positive number of ticks, or a zero duration.
    IntervalNotPositive !Interval
  | -- | A tick count too large to be one.
    IntervalUnrepresentable !Interval
  | -- | A duration that is not an exact multiple of the owner's tick duration: the
    -- interval and the tick duration.
    IntervalNotExact !Interval !Duration
  | -- | A logical duration, and the owner was given no tick duration to convert it by.
    IntervalNoTickDuration !Interval
  deriving (Eq, Show)

-- | An interval as admission resolved it.
data Cadence
  = -- | Every this many ticks, a positive number.
    CadenceTicks !Word64
  | -- | Every this much elapsed time, a positive duration.
    CadenceElapsed !Duration
  deriving (Eq, Show)

-- | Resolve an interval against the owner's tick duration, exactly or not at all.
resolveInterval ∷ Maybe Duration → Interval → Either IntervalRefusal Cadence
resolveInterval tick interval = case interval of
  LogicalTicks count
    | count < 1 → Left (IntervalNotPositive interval)
    | count > fromIntegral (maxBound ∷ Word64) → Left (IntervalUnrepresentable interval)
    | otherwise → Right (CadenceTicks (fromIntegral count))
  LogicalDuration duration
    | duration == zeroDuration → Left (IntervalNotPositive interval)
    | otherwise → case tick of
        Nothing → Left (IntervalNoTickDuration interval)
        Just per
          | durationNanoseconds duration `mod` durationNanoseconds per /= 0 → Left (IntervalNotExact interval per)
          | otherwise → Right (CadenceTicks (fromIntegral (durationNanoseconds duration `div` durationNanoseconds per)))
  ElapsedEvery duration
    | duration == zeroDuration → Left (IntervalNotPositive interval)
    | otherwise → Right (CadenceElapsed duration)

-- | What an application admits as one instance.
data InstanceRequest = InstanceRequest
  { instanceModule ∷ !ModuleRef
    -- ^ A module the owner loaded at initialization, which declares the hooks it
    -- defines as optional entry points ('Hetoimasia.Scripting.Lua.Instance.hookEntries').
  , instanceKind ∷ !InstanceKind
  , instanceName ∷ !(Maybe Text)
    -- ^ The application's readable name. No authority.
  , instanceClass ∷ !ServiceClass
    -- ^ The service class its invocations are scheduled in.
  , instanceGrants ∷ ![Text]
    -- ^ The event sources its @api@ may connect a function to, by name. Anything
    -- else it asks for is a script error: it has no other way to reach one.
  }

-- | An event source the owner offers, by name, and the shape of the payload it
-- delivers. In this slice a source is a seam for tests: nothing but the
-- application's own thread delivers to it.
data EventSource = EventSource
  { sourceName ∷ !Text
    -- ^ A name of the kind bindings have: 1 to 64 ASCII letters, digits and
    -- underscores.
  , sourcePayload ∷ !Schema
    -- ^ The payload every delivery is checked against. No capability: nothing
    -- here is a VM's.
  }
  deriving (Eq, Show)

-- Where an instance is ------------------------------------------------------------

-- | The phase of an instance's life.
data InstancePhase
  = -- | Admitted, its @self@ made, and its @init@ not yet finished. Events can be
    -- accepted; none runs.
    Initializing
  | -- | Initialized and serving.
    Active
  | -- | Initialized, and processing nothing: it holds what it was handed.
    Paused
  | -- | Being ended: admission and connections are closed and what had not begun is
    -- discarded, and the hook that follows is not yet done.
    Stopping
  | -- | Terminal: a one-shot ran to its end.
    Completed
  | -- | Terminal: stopped, by a request or by its owner's retirement.
    Stopped
  | -- | Terminal: failed. Its failure is in its settlement.
    Failed
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Whether a phase is one an instance never leaves.
isTerminal ∷ InstancePhase → Bool
isTerminal = \case
  Completed → True
  Stopped → True
  Failed → True
  _ → False

-- | What a live instance's current invocation is doing: the detail inside a live
-- phase.
data Execution
  = -- | No invocation is in flight.
    ExecIdle
  | -- | An invocation is ready to run, or admitted and waiting for an active slot.
    ExecReady
  | -- | A segment of its invocation is running on the owner's thread.
    ExecRunning
  | -- | Its invocation is suspended and not ready: it waits for a logical tick or an
    -- elapsed deadline, or is frozen by a pause.
    ExecWaiting
  deriving (Eq, Show)

-- | A bounded, coherent reading of one instance: all of it taken in one
-- transaction. It borrows nothing from a Lua state.
data InstanceSnapshot = InstanceSnapshot
  { snapshotInstance ∷ !InstanceId
  , snapshotOwner ∷ !Text
    -- ^ The application's label of the owner.
  , snapshotName ∷ !(Maybe Text)
  , snapshotModule ∷ !ModuleRef
  , snapshotKind ∷ !InstanceKind
  , snapshotPhase ∷ !InstancePhase
  , snapshotExecution ∷ !Execution
  , snapshotQueued ∷ !Int
    -- ^ Events accepted and not begun, the one in flight among them until its first
    -- segment runs. A one-shot's @run@ is no event and is not counted here, though an
    -- ending counts it among the unstarted invocations it discards.
  , snapshotQueueBound ∷ !Int
  , snapshotQueueFull ∷ !Int
    -- ^ Deliveries refused because the queue was full.
  , snapshotDelivered ∷ !Int
    -- ^ Deliveries accepted.
  , snapshotConnections ∷ !Int
  , snapshotUpdateOwed ∷ !Bool
    -- ^ A periodic update is due or admitted and has not begun: at most one, and it is
    -- not counted in 'snapshotQueued', which it never competes with.
  }
  deriving (Eq, Show)

-- Events --------------------------------------------------------------------------

-- | What delivering an event answered.
data Delivery
  = -- | Accepted, with the sequence it was given. Nothing else changed.
    DeliveryAccepted !Word64
  | -- | The instance's queue is full. Nothing was evicted, and a counter says so.
    DeliveryQueueFull
  | -- | The instance has stopped taking events: it is ending, or its owner is. An
    -- instance that has ended is no live target, and is 'DeliveryUnknownTarget'.
    DeliveryClosed
  | -- | No live instance of this owner has this identity, or it has no connection
    -- to that source.
    DeliveryUnknownTarget
  | -- | The payload is over the owner's limits, or is not what the source
    -- declares. Nothing was kept.
    DeliveryRefused
  deriving (Eq, Show)

-- | An accepted event as the callback is handed it: the sequence admission gave it
-- and the logical tick it was admitted at, kept unchanged until it runs, however
-- long it waited and whatever happened in between.
data EventRecord = EventRecord
  { eventSource ∷ !Text
  , eventSequence ∷ !Word64
  , eventTick ∷ !Word64
  , eventPayload ∷ !Value
  }
  deriving (Eq, Show)

-- | An accepted event, queued.
--
-- A connection's event carries its payload. A subscription's delivery is a /reference/: the
-- payload stays in the subscription's record in the protocol model, where a later delivery of
-- replaceable state replaces it in place, and is taken when the callback's first segment is
-- about to run. The reference keeps the delivery's place in the queue, its sequence and the
-- logical tick it was admitted at.
data QueuedEvent = QueuedEvent
  { queuedSource ∷ !Text
    -- ^ The event source a connection's event came from, or the subscription's endpoint.
  , queuedSequence ∷ !Word64
  , queuedTick ∷ !Word64
  , queuedPayload ∷ !Value
    -- ^ Nil for a subscription's delivery, which holds none.
  , queuedSubscription ∷ !(Maybe SubscriptionId)
    -- ^ The subscription a delivery is for; 'Nothing' for a connection's event.
  }

-- What an instance settles as -------------------------------------------------------

-- | How an admitted instance settled. Exactly one of these, once.
data InstanceOutcome
  = -- | A one-shot ran to its end, and its shutdown did not fail.
    InstanceCompleted
  | -- | Stopped, and its shutdown did not fail.
    InstanceStopped
  | -- | Failed: what failed, and where. It ended its own instance only.
    InstanceFailed !InstanceFailure
  | -- | The owner exited without retiring the instance in order: after a host
    -- failure or a cancellation, no hook ran for it and Lua was not entered for it
    -- again. How the owner exited, and whether a hook of the instance had begun.
    -- An instance that had failed already settles as failed instead, with its first
    -- failure.
    InstanceDiscarded !Discard
  deriving (Show)

-- | What an instance's end revoked and released, and what became of its hook.
data Termination = Termination
  { terminationConnections ∷ !Int
    -- ^ Event connections revoked.
  , terminationUnstarted ∷ !Int
    -- ^ Accepted invocations that had not begun, discarded.
  , terminationClosed ∷ !Int
    -- ^ Invocations that had begun and were suspended, whose coroutines were closed
    -- and not resumed.
  , terminationShutdown ∷ !ShutdownDisposition
  }
  deriving (Eq, Show)

-- | What became of the @shutdown@ hook.
data ShutdownDisposition
  = -- | It ran, once, and returned.
    ShutdownRan
  | -- | It ran, once, and raised: the error is kept, not retried.
    ShutdownRaised
  | -- | The module defines none: nothing to run, which is not a failure.
    ShutdownAbsent
  | -- | @init@ never succeeded, so no hook runs on the instance.
    ShutdownSkippedNoInit
  | -- | Lua entry was not safe: the owner ended by a failure or a cancellation.
    ShutdownSkippedUnsafe
  deriving (Eq, Show)

-- | The hook, or the invocation, something happened in.
data HookStage
  = StageInit
  | StageRun
  | -- | A periodic update.
    StageUpdate
  | -- | A callback, by the source it was connected to.
    StageEvent !Text
  | StageShutdown
  | -- | Releasing what the instance held, as it ended.
    StageRelease
  deriving (Eq, Show)

-- | What went wrong, as the host reports it.
data InstanceError
  = -- | A fault of the instance's code or of a value it handed across the boundary:
    -- a script error, a refused value, a call to a binding that is not yet
    -- supported, a wait or a yield where none can happen, or a module the owner did
    -- not load.
    ErrorFault !CallFault
  | -- | A one-shot whose module defines no @run@, refused before any hook ran.
    ErrorMissingEntry !Text
  | -- | The scheduler refused what an invocation asked for (a wait for no ticks or
    -- no time) and failed it.
    ErrorRefusedWait !TaskFailure
  | -- | Releasing a holding failed, or a provider's retirement of one: a bounded
    -- rendering of what failed. The failure itself is cleanup evidence on the
    -- owner.
    ErrorRelease !Text
  | -- | A provider could not preserve an authoritative event of a subscription: the endpoint
    -- and why. The simulation cannot go on as though it had been delivered, so the instance
    -- fails, and the application's escalation decides what that means for its peers.
    ErrorDelivery !Text !Text
  | -- | The cadence's own arithmetic could not be represented: a tick or a deadline
    -- past what a tick or an instant can be, or a logical duration granted that
    -- overflowed. Nothing wrapped; this is what happened.
    ErrorCadence !Text
  deriving (Show)

-- | A bounded diagnostic and inspection result: the instance, its owner, its
-- source, the phase it was in, what failed, and the traceback if one was captured.
--
-- The same value is what the application is told when an instance fails.
data InstanceFailure = InstanceFailure
  { failureInstance ∷ !InstanceId
  , failureOwner ∷ !Text
  , failureName ∷ !(Maybe Text)
  , failureSource ∷ !ModuleRef
  , failurePhase ∷ !InstancePhase
    -- ^ The phase it was in when the primary failure happened.
  , failureStage ∷ !HookStage
  , failureError ∷ !InstanceError
    -- ^ The primary failure. A later one never replaces it.
  , failureMessage ∷ !Text
    -- ^ The error, rendered, at most 'failureTextLimit' characters.
  , failureTraceback ∷ !(Maybe Text)
  , failureSecondary ∷ ![(HookStage, InstanceError)]
    -- ^ What else failed while the instance ended: the error its @shutdown@ raised,
    -- when it was not the primary one.
  }
  deriving (Show)

-- | What the application decides about an instance's failure.
data Escalation
  = -- | The failure ends the instance and nothing else: its peers go on.
    Isolate
  | -- | The failure may have damaged state the instances share: the owner fails, as
    -- it does for a host failure, and what follows is its 'WorkerPolicy'.
    Escalate
  deriving (Eq, Show)

-- | Raised by the owner, on its own thread, when the application's decision is to
-- escalate an instance's failure.
newtype InstanceEscalated = InstanceEscalated InstanceFailure
  deriving (Show)

instance Exception InstanceEscalated

-- Control -----------------------------------------------------------------------------

-- | What admitting an instance answered.
data InstanceAdmission
  = -- | Accepted, with the instance's identity and the ticket its settlement is read
    -- through.
    InstanceAccepted !InstanceId !InstanceTicket
  | -- | A bound is reached: the live instances or the stored results. Nothing
    -- changed.
    InstanceFull
  | -- | The owner has stopped admitting. Nothing changed.
    InstanceAdmissionClosed
  | -- | The periodic interval was refused, naming the input. Nothing changed.
    InstanceIntervalRefused !IntervalRefusal
  deriving (Show)

-- | The place an accepted instance's settlement is read.
data InstanceTicket = InstanceTicket
  { ticketInstances ∷ !Instances
  , ticketCell ∷ !ICell
  , ticketInstance ∷ !InstanceId
  }

instance Show InstanceTicket where
  show ticket = "instance ticket of " <> show (ticketInstance ticket)

-- | A request about one instance.
data InstanceControl
  = InstancePause
  | InstanceResume
  | InstanceStop
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | What requesting control of an instance answered.
data InstanceControlAnswer
  = -- | Taken. Its settlement is read through the receipt.
    InstanceControlAccepted !InstanceControlReceipt
  | -- | Every result reservation is held. Nothing changed.
    InstanceControlFull
  | InstanceControlClosed
  | -- | No live instance of this owner has this identity: it is another owner's,
    -- ended, or never issued.
    InstanceControlUnknown
  | -- | The request was assigned a tick the owner has already begun: it is refused,
    -- never applied at a later boundary. Nothing changed.
    InstanceControlLate
  | -- | Another request already holds this tick and sequence on this owner. Nothing
    -- changed, and nothing was ordered by arrival.
    InstanceControlDuplicate
  | -- | The request was assigned a tick and a sequence, and this owner does not admit
    -- controls logically. Nothing changed.
    InstanceControlNotLogical
  deriving (Show)

-- | How an owner admits the control requests made of its instances through a grant
-- (LUA-23).
data ControlAdmission
  = -- | At the owner's next safe boundary, in the order the requests were accepted: the
    -- way requests were always admitted.
    AdmitOnArrival
  | -- | By the tick and sequence the application assigned each request (D-23): a request
    -- is applied at the logical boundary of its tick, before that tick's other work, in
    -- the order of (tick, sequence), whatever order the requests arrived in and whichever
    -- VM sent them. One assigned a tick the owner has begun is refused as late.
    AdmitLogically
  deriving (Eq, Show)

-- | Where a control request belongs in a logically admitting owner's input sequence,
-- as the application assigned it: the tick whose boundary applies it, and its place
-- among the requests assigned to that tick. The pair is unique on an owner.
data ControlSlot = ControlSlot
  { controlTick ∷ !Word64
  , controlSequence ∷ !Word64
  }
  deriving (Eq, Ord, Show)

-- | An accepted request waiting for its tick's boundary.
data LogicalControl = LogicalControl
  { logicalInstance ∷ !Word64
  , logicalRequest ∷ !InstanceControl
  , logicalReceipt ∷ !InstanceControlReceipt
  }

-- | The place an accepted request's settlement is read. Reading it is observing
-- it: the first read that finds it gives the reservation back, and every later
-- read answers the same settlement and gives nothing back.
data InstanceControlReceipt = InstanceControlReceipt
  { receiptSettlement ∷ !(TVar (Maybe ControlResult))
  , receiptForgotten ∷ !(TVar Bool)
  , receiptReleased ∷ !(TVar Bool)
  , receiptReserved ∷ !(TVar Int)
  }

instance Show InstanceControlReceipt where
  show _ = "<instance control receipt>"

-- Bounds ------------------------------------------------------------------------------

-- | The bounds an owner's instances are configured with. Each is at least one.
data InstanceBounds = InstanceBounds
  { boundLiveInstances ∷ !Int
    -- ^ Instances not yet ended.
  , boundRetainedInstances ∷ !Int
    -- ^ Result reservations: taken when an instance is admitted, given back when
    -- its settlement is observed or abandoned. At least the live bound.
  , boundInvocationQueue ∷ !Int
    -- ^ Accepted invocations an instance holds that have not begun.
  , boundInstanceControls ∷ !Int
    -- ^ Control reservations: taken when a request is accepted, given back when its
    -- settlement is observed or abandoned.
  }
  deriving (Eq, Show)

-- | Sixteen live instances, thirty-two reservations, a queue of sixty-four
-- invocations and thirty-two control requests.
defaultInstanceBounds ∷ InstanceBounds
defaultInstanceBounds = InstanceBounds 16 32 64 32

-- | What an owner is given to host instances.
data InstanceConfig = InstanceConfig
  { instanceBounds ∷ !InstanceBounds
  , instanceSources ∷ ![EventSource]
    -- ^ The event sources the owner offers, by name.
  , instanceTickDuration ∷ !(Maybe Duration)
    -- ^ The logical duration one tick stands for, which an interval given as a
    -- duration is converted by. No production rate is hard-coded: without it, an
    -- interval given as a duration is refused, and one given as ticks needs none.
  , instanceControlAdmission ∷ !ControlAdmission
    -- ^ How the requests made of this owner's instances through a grant are admitted
    -- (LUA-23). The application's own 'Hetoimasia.Scripting.Lua.Instance.requestInstanceControl'
    -- is admitted on arrival whatever this is.
  , instanceEscalate ∷ InstanceFailure → IO Escalation
    -- ^ Told, on the owner's thread, of each instance's failure after the instance
    -- has ended. It decides, and its default keeps the failure isolated. What it
    -- raises is a failure of the host. It cannot hide or replace the cleanup
    -- evidence of the owner, which is fatal whatever it answers.
  }

-- | The default bounds, no event source, controls admitted on arrival, and an
-- escalation that keeps every failure isolated.
defaultInstanceConfig ∷ InstanceConfig
defaultInstanceConfig = InstanceConfig defaultInstanceBounds [] Nothing AdmitOnArrival (const (pure Isolate))

-- | A configuration problem.
data InstanceViolation
  = BoundBelowOne !Text !Int
  | -- | The retained-result bound is below the live bound.
    RetainedBelowLive !Int !Int
  | -- | The scheduler's retained-result bound must be at least twice the live
    -- instances: an instance's next invocation is admitted before the scheduler has
    -- given back the result of its last.
    SchedulerRetainedTooSmall !Int !Int
  | -- | The scheduler's queue of admissions must hold every live instance's
    -- invocation.
    SchedulerQueueTooSmall !Int !Int
  | InvalidSourceName !Text
  | DuplicateSource !Text
  | -- | A source's payload names a capability, which is a VM's.
    SourceCapability !Text
  | -- | More sources than the driver module can declare an entry point for: how many
    -- were given, and how many fit.
    TooManySources !Int !Int
  | -- | The configured tick duration is zero.
    TickDurationNotPositive
  | -- | The application's registration could not take the instance layer's
    -- namespace beside its own: what the registration refused.
    RegistrationRefused !Text
  deriving (Eq, Show)

-- | A configuration was refused, and nothing was made. Every violation.
newtype InstancesRefused = InstancesRefused (NonEmpty InstanceViolation)
  deriving (Eq, Show)

instance Exception InstancesRefused

-- | Every violation of a configuration against the scheduler's own bounds: its
-- retained results and its queue of admissions.
validateInstanceConfig ∷ Int → Int → InstanceConfig → [InstanceViolation]
validateInstanceConfig schedulerRetained schedulerQueued config =
  [BoundBelowOne name value | (name, value) ← bounds, value < 1]
    <> [RetainedBelowLive (boundRetainedInstances b) (boundLiveInstances b) | boundRetainedInstances b < boundLiveInstances b]
    <> [SchedulerRetainedTooSmall schedulerRetained (boundLiveInstances b) | schedulerRetained < 2 * boundLiveInstances b]
    <> [SchedulerQueueTooSmall schedulerQueued (boundLiveInstances b) | schedulerQueued < boundLiveInstances b]
    -- A source is named as a binding is, and the driver's entry point for it is
    -- named for it after a prefix, under the same bound.
    <> [InvalidSourceName (sourceName source) | source ← sources, validName (sourceName source) /= Nothing || validName ("event_" <> sourceName source) /= Nothing]
    <> [TooManySources (length sources) sourceLimit | length sources > sourceLimit]
    <> [DuplicateSource name | name ← duplicated names]
    <> [SourceCapability (sourceName source) | source ← sources, hasCapability (sourcePayload source)]
    <> [TickDurationNotPositive | instanceTickDuration config == Just zeroDuration]
  where
    b = instanceBounds config
    sources = instanceSources config
    -- The driver declares five entry points of its own, and one for each source.
    sourceLimit = maxEntries - 5
    names = map sourceName sources
    bounds =
      [ ("live instances", boundLiveInstances b)
      , ("retained instance results", boundRetainedInstances b)
      , ("invocation queue", boundInvocationQueue b)
      , ("instance controls", boundInstanceControls b)
      ]
    -- Each name that appears again after its first place, once.
    duplicated xs = nub [x | (index, x) ← zip [0 ∷ Int ..] xs, x `elem` take index xs]
    hasCapability = \case
      SCapability _ → True
      SList inner → hasCapability inner
      SOptional inner → hasCapability inner
      SRecord fields → any (hasCapability . snd) fields
      _ → False

-- Shared state ----------------------------------------------------------------------------

-- | One accepted instance, as the two sides share it.
data ICell = ICell
  { icId ∷ !Word64
  , icModule ∷ !ModuleRef
  , icKind ∷ !InstanceKind
  , icCadence ∷ !(Maybe Cadence)
    -- ^ The interval a periodic instance was admitted with, resolved, and fixed for its
    -- life.
  , icName ∷ !(Maybe Text)
  , icClass ∷ !ServiceClass
  , icGrants ∷ !(Set Text)
  , icState ∷ !(TVar IState)
  , icResult ∷ !(TVar (Maybe InstanceSettlement))
    -- ^ Written once: when the instance ends, or when its owner exits.
  , icForgotten ∷ !(TVar Bool)
  , icReleased ∷ !(TVar Bool)
  }

-- | What changes about an instance, all of it in one variable so a reading is
-- coherent.
data IState = IState
  { isPhase ∷ !InstancePhase
  , isInitialized ∷ !Bool
    -- ^ @init@ returned.
  , isConnections ∷ !(Set Text)
  , isQueue ∷ !(Seq QueuedEvent)
  , isNextSequence ∷ !Word64
  , isQueueFull ∷ !Int
  , isDelivered ∷ !Int
  , isActive ∷ !(Maybe TaskId)
    -- ^ The scheduler task of the invocation in flight.
  , isDispatchQueued ∷ !Bool
    -- ^ A job is already waiting for the owner to look at this instance's queue.
  , isStopped ∷ !Bool
    -- ^ A stop was applied, or the instance failed: nothing new is accepted or
    -- started.
  , isRunBegun ∷ !Bool
    -- ^ A one-shot's @run@ has run its first segment. A one-shot's run is owed, as an
    -- unstarted invocation, from the success of its @init@ until this is set or the
    -- instance is discarded: whether the scheduler has been given it, refused it,
    -- queued it, had it taken back by a pause or holds it paused makes no difference,
    -- because nothing of that is how it is represented.
  , isPending ∷ !(Maybe QueuedEvent)
    -- ^ The event whose callback is in flight, until that callback's first segment
    -- runs: it is still an unstarted invocation, and holds its place against the
    -- queue's bound.
  , isUpdate ∷ !UpdateSlot
    -- ^ Where the instance's one periodic update is. It is never in 'isQueue' and never
    -- competes with events for the queue's bound: it keeps its place among them by the
    -- sequence the next event would have been given when it fell due.
  , isUpdateRunning ∷ !Bool
    -- ^ An update began and has not finished: it is the invocation in flight.
  , isBaseline ∷ !ElapsedBaseline
    -- ^ An elapsed instance's baseline: the instant its last update began, or its
    -- @init@ succeeded, or it resumed, which is what its @dt@ is measured from.
  , isDeliveryFailure ∷ !(Maybe (Text, Text))
    -- ^ The endpoint and why: a provider surfaced that it could not preserve an authoritative event of one of this
    -- instance's subscriptions: the owner fails the instance with it, once.
  }

-- | Where an instance's periodic update is.
data UpdateSlot
  = -- | None is owed.
    UpdateNone
  | -- | It fell due and waits its turn: events accepted before it (with a sequence below
    -- this one) run first, events accepted after it run after it.
    UpdateDue !Word64
  | -- | It was admitted as the invocation in flight and has not run a segment: still an
    -- unstarted invocation, which a pause takes back and a stop discards.
    UpdateAdmitted !Word64
  deriving (Eq, Show)

-- | Whether an update is owed, as an unstarted invocation: due, or admitted and not
-- begun.
updateOwed ∷ IState → Bool
updateOwed state = case isUpdate state of
  UpdateDue _ → True
  UpdateAdmitted _ → True
  _ → False

-- | How many places of the queue an unstarted invocation in flight holds: an event's,
-- as it would in the queue. A one-shot's run is no event and holds none.
pendingEvents ∷ IState → Int
pendingEvents state = maybe 0 (const 1) (isPending state)

-- | Whether a one-shot's run is owed: its instance is a one-shot, its @init@ has
-- succeeded, and the run has not begun. The one representation of an unstarted run,
-- by which an ending counts it among the invocations it discards, exactly once.
runOwed ∷ InstanceKind → IState → Bool
runOwed kind state = kind == RunOnce && isInitialized state && not (isRunBegun state)

-- | The invocations an ending discards for not having begun: the events queued, the
-- event whose callback has not run a segment, and the run that is owed. The only
-- count of them, whichever way the instance ends.
unstartedCount ∷ InstanceKind → IState → Int
unstartedCount kind state =
  Seq.length (isQueue state) + pendingEvents state + (if runOwed kind state then 1 else 0) + (if updateOwed state then 1 else 0)

-- | A fresh instance's state.
initialState ∷ IState
initialState = IState Initializing False Set.empty Seq.empty 0 0 0 Nothing False False False Nothing UpdateNone False noBaseline Nothing

-- | What the owner's thread is asked to do, in the order the application asked.
data Job
  = -- | Make the instance and run its @init@.
    JobStart !Word64
  | -- | Look at the instance's queue: an event was accepted, or its invocation can
    -- go on.
    JobDispatch !Word64
  | -- | Apply a request.
    JobControl !Word64 !InstanceControl !InstanceControlReceipt
  | -- | Let the instance's VM go of the callbacks of subscriptions that ended without it
    -- (an epoch change): they are named in the provider service, and are no use to anyone.
    JobForget !Word64

-- | An instance's settlement.
data InstanceSettlement = InstanceSettlement
  { resultInstance ∷ !InstanceId
  , resultOwner ∷ !Text
  , resultName ∷ !(Maybe Text)
  , resultModule ∷ !ModuleRef
  , resultPhase ∷ !InstancePhase
    -- ^ The terminal phase.
  , resultOutcome ∷ !InstanceOutcome
  , resultTermination ∷ !Termination
  , resultLeases ∷ !LeaseOutcome
    -- ^ What the end did with the leases the instance held.
  }
  deriving (Show)

-- | What an instance's end did with its leases ("Hetoimasia.Scripting.Lua.Lease").
data LeaseOutcome = LeaseOutcome
  { leasesDrained ∷ !Int
    -- ^ Holdings the end released.
  , leasesAwaited ∷ !Int
    -- ^ Provider retirements the end waited for, and saw complete: the ones still
    -- pending when the instance's holdings were released.
  , leasesFailed ∷ !Int
    -- ^ Releases and retirements that failed. Each is kept beside the instance's
    -- primary failure, and as cleanup evidence on the owner.
  }
  deriving (Eq, Show)

-- | An instance that held no leases.
noLeases ∷ LeaseOutcome
noLeases = LeaseOutcome 0 0 0

-- | Everything one owner's instances share across its two sides.
data Instances = Instances
  { insBounds ∷ !InstanceBounds
  , insSources ∷ !(Map Text Schema)
  , insTickDuration ∷ !(Maybe Duration)
  , insNext ∷ !(TVar Word64)
    -- ^ The next number to issue. Never rewinds.
  , insCells ∷ !(TVar (Map Word64 ICell))
    -- ^ Every instance that is live, or ended and not yet observed: bounded by the
    -- reservations.
  , insInbox ∷ !(TVar (Seq Job))
  , insLive ∷ !(TVar Int)
  , insRetained ∷ !(TVar Int)
  , insControls ∷ !(TVar Int)
  , insRunning ∷ !(TVar (Maybe Word64))
    -- ^ The instance whose Lua the owner's thread is running, if any: what a binding
    -- the instance's code calls is told it is called by.
  , insTasks ∷ !(TVar (Set TaskId))
    -- ^ The scheduler tasks that are instances' invocations: the application's own
    -- requests about tasks do not reach them.
  , insBlocked ∷ !(TVar Bool)
    -- ^ An invocation was refused by the scheduler for want of room, and waits for
    -- room.
  , insDelta ∷ !(TVar (Maybe (Word64, Double)))
    -- ^ The @dt@, in seconds, of the update about to begin, and the instance it is
    -- for: the driver's entry point takes it through the one binding built for the
    -- purpose, so an update's boundary footprint is a one-shot's.
  , insAdmission ∷ !ControlAdmission
    -- ^ How the owner admits controls made through a grant.
  , insLogical ∷ !(TVar (Map ControlSlot LogicalControl))
    -- ^ The accepted requests assigned a tick the owner has not begun, by their place
    -- in the input sequence, which is their order: each holds a reservation like any
    -- accepted request, so they are bounded by 'boundInstanceControls'.
  }

-- | Make an owner's instance state.
newInstances ∷ InstanceConfig → IO Instances
newInstances config =
  Instances (instanceBounds config) (Map.fromList [(sourceName source, sourcePayload source) | source ← instanceSources config]) (instanceTickDuration config)
    <$> newTVarIO 1
    <*> newTVarIO Map.empty
    <*> newTVarIO Seq.empty
    <*> newTVarIO 0
    <*> newTVarIO 0
    <*> newTVarIO 0
    <*> newTVarIO Nothing
    <*> newTVarIO Set.empty
    <*> newTVarIO False
    <*> newTVarIO Nothing
    <*> pure (instanceControlAdmission config)
    <*> newTVarIO Map.empty

-- | An error as one line of text, at most 'failureTextLimit' characters.
renderError ∷ InstanceError → Text
renderError = failureText . \case
  ErrorFault fault → Text.pack (show fault)
  ErrorMissingEntry entry → "the module defines no " <> entry <> " entry point"
  ErrorRefusedWait failure → Text.pack (show failure)
  ErrorRelease released → "a release failed: " <> released
  ErrorCadence what → "cadence: " <> what
  ErrorDelivery endpoint why → "delivery to a subscription of " <> endpoint <> " failed: " <> why

-- | A bounded rendering.
failureText ∷ Text → Text
failureText = Text.take failureTextLimit . Text.map (\c → if c == '\n' then ' ' else c)

failureTextLimit ∷ Int
failureTextLimit = 1024
