{-# LANGUAGE RoleAnnotations #-}

-- | An optional adapter that runs a supervised 'Service' with one FIFO inbox,
-- a component-supplied context, and a component-supplied handler.
--
-- It is built on 'startSupervised' and the worker's own 'Scoped' startup. It is
-- not a second runner, supervisor, thread registry, restart policy, or
-- scheduler: the worker is an ordinary supervised service, judged by the policy
-- its starter supplies and drained by the group that owns it. Component
-- protocols and handlers stay with the component, and
-- "Hetoimasia.Foundation.Messaging.Channel" stays usable without this module.
--
-- __Startup order.__ On the worker's thread, inside its 'Scoped' startup:
--
-- 1. the component's context and every resource it owns are constructed;
-- 2. the inbox is allocated, with its abort registered as the innermost
--    release, so reverse scope order ends admission and drops the backlog
--    before any component resource is released;
-- 3. the endpoint is written into a private one-shot handoff, after every
--    construction and cleanup registration succeeded and before the startup is
--    acknowledged. No allocation follows the abort guard.
--
-- __Handoff.__ After 'startSupervised' returns 'WorkerStarted', the adapter
-- reads the already-full handoff with a read that never retries, and never
-- starts a second readiness wait. An empty handoff or a duplicate write is an
-- 'InboxInvariantViolated' failure raised through 'throwFailure'. Whatever
-- happens during that read — an invariant failure or the owner's cancellation —
-- the started worker stays owned by the group, which stops and drains it.
--
-- __Failed starts.__ A rejected start forks nothing, and a recognized optional
-- failure returns 'InboxStartUnavailable'; neither carries an endpoint. A fatal
-- startup failure and an owner cancellation propagate from
-- 'startInboxService' as 'startSupervised' propagates them, with their own
-- type, context, and evidence. A failure or cancellation while the context is
-- being constructed happens before the inbox exists.
--
-- __Dispatch.__ One prepared message at a time. The stop check, the receive,
-- and the recording of a drain acknowledgement are one STM decision, and a
-- requested stop wins over a simultaneously ready message and over a drained
-- inbox. The handler runs outside STM. A message a committed receive selected
-- is in flight: a stop cannot retract its effects, and nothing retries it.
--
-- __Finish versus stop.__ 'stopInboxService' is the ordinary stop: the next
-- decision takes the stop, and accepted backlog is aborted and counted, not
-- processed. 'finishInboxService' is the graceful finish:
--
-- 1. it closes admission normally — a close, not an abort — so the backlog is
--    kept and later sends report 'Hetoimasia.Foundation.Messaging.Channel.Closed';
-- 2. the worker completes the in-flight handler, then handles the accepted
--    backlog in FIFO order;
-- 3. once those handlers returned, the decision that observes the normally
--    closed, empty inbox records the drain acknowledgement in the same
--    transaction. Empty depth alone is never an acknowledgement, and a stop
--    that has already won is never followed by one;
-- 4. having acknowledged, the worker waits for its stop token rather than
--    returning, so it stays a 'Service';
-- 5. finish observes the acknowledgement through 'awaitSupervised', asks for
--    the stop with 'stopSupervised', and awaits the terminal completion
--    through 'awaitSupervised' again, so pending outcomes and the fatal latch
--    are handled before either read.
--
-- The finish wait also ends when the completion is published without an
-- acknowledgement, so finish never waits for a marker a terminal worker can no
-- longer produce. An unrelated worker's outcome that arrives while it waits is
-- settled by 'awaitSupervised' and the wait resumes; it consumes nothing.
-- Request a finish while the services the handler depends on are still
-- available: the backlog is handled with them, before closing drains the group.
--
-- __Finish outcomes.__ 'InboxFinished' requires a genuine acknowledgement, a
-- 'Succeeded' completion whose 'InboxExit' records that acknowledgement and zero
-- discards, and the 'WorkerStopped' status, which supervision gives only after
-- successful cleanup. When supervision settles 'WorkerStopped' otherwise — a
-- stop or cancellation that won before the drain, or a cancellation after it —
-- the finish is 'InboxUnfinished', carrying the acknowledgement if one was made
-- and the actual completion. A recognized failure of an optional service,
-- including a cancellation after the drain that no owner asked for, is
-- 'InboxFinishUnavailable', with its single warning. A required, unrecognized,
-- or cleanup failure propagates from 'finishInboxService' through supervision
-- with its original evidence; in every case a recorded acknowledgement and the
-- actual completion stay readable on the handle. Repeated finishes, stops, and
-- completion reads re-run no handler and return the same evidence; admission
-- never reopens, and a later stop or cancellation leaves a recorded
-- acknowledgement in place.
--
-- __Abort before teardown.__ Every exit from the service — an ordinary stop,
-- including one closing requested, a synchronous handler failure, cancellation
-- (also before dispatch begins), and an exit straight after acknowledgement —
-- aborts the inbox before the component's resources are released and before
-- the terminal completion is published. The abort release runs under
-- 'uninterruptibleMask_', never executes 'retry', never waits, invokes no
-- handler, logs nothing, joins no worker, and uses the channel's counter-based
-- discard rather than traversing the backlog it drops.
--
-- __Handler failures.__ A synchronous exception escaping the handler ends
-- dispatch; the next queued message is not handled. After the abort and the
-- scope's cleanup it fails the run with its original type and context, and
-- supervision's policy decides: a recognized failure of an optional service is
-- unavailable with its single warning; a required or unrecognized failure is
-- fatal; retained cleanup failure is fatal. There is no per-message isolation,
-- catch-and-continue, skip, or replay. A handler that can recover — for
-- instance with "Hetoimasia.Foundation.Recovery" — does so before the exception
-- escapes, and returning normally lets dispatch continue.
--
-- __The exit record.__ When its stop is requested the service aborts its inbox,
-- then reads, in the same transaction, the channel's cumulative discard count
-- and the drain acknowledgement it recorded, if any, into an immutable
-- 'InboxExit', which is the run's result. After a finish it records the
-- acknowledgement and zero discards; after an ordinary stop it records no
-- acknowledgement and the real discard count, because that backlog is not
-- processed. A failed, cancelled, or cleanup-failed run keeps its actual
-- 'Completion' evidence; no 'InboxExit' is manufactured for it, and the
-- acknowledgement stays readable through 'inboxAcknowledgedDrain'.
--
-- __Completion.__ 'inboxCompletion', 'awaitInboxCompletion', and
-- 'inboxAcknowledgedDrain' are raw, non-consuming STM reads. They compose with
-- 'Hetoimasia.Runtime.Supervision.awaitSupervised' inside supervision — which
-- may deliver a latched fatal failure instead of returning that evidence — and
-- stay readable after the group has drained. 'WorkerStopped' alone is not an
-- exit record; the completion's 'Succeeded' result is.
--
-- __Dependencies.__ Borrowed dependencies stay alive through worker cleanup
-- under the group's drain, including when the owner is cancelled during a
-- finish. A stuck handler keeps its resources under the same policy: no
-- deadline and no detach.
--
-- __State.__
--
-- +-----------------+-----------------------------------------------+----------------------------+----------------------------------------+
-- | State           | Readers and writers                           | Thread                     | Lifetime and reset                     |
-- +=================+===============================================+============================+========================================+
-- | Service handoff | The worker's startup writes once, last; the   | Worker writes; application | One start; written at most once, never |
-- |                 | starter reads once after 'WorkerStarted'      | thread reads               | cleared, dropped with the start        |
-- +-----------------+-----------------------------------------------+----------------------------+----------------------------------------+
-- | Inbox channel   | Producers send; the dispatch loop receives;   | Any sender; the worker     | The worker's startup scope; aborted on |
-- |                 | the run and the abort release abort           |                            | every exit, never reopened             |
-- +-----------------+-----------------------------------------------+----------------------------+----------------------------------------+
-- | Drain           | The dispatch decision that observes the       | Worker writes; any thread  | One start; written at most once, never |
-- | acknowledgement | closed, empty inbox writes it once; finish,   | reads, in STM              | cleared, kept after completion         |
-- |                 | the exit record, and handle readers read      |                            |                                        |
-- +-----------------+-----------------------------------------------+----------------------------+----------------------------------------+
-- | Exit record     | The run writes it once as its result; any     | Worker writes; any thread  | Published with the completion; never   |
-- |                 | number of completion readers                  | reads, in STM              | changes or is consumed                 |
-- +-----------------+-----------------------------------------------+----------------------------+----------------------------------------+
--
-- The module takes no logger: its one failure propagates, and supervision owns
-- every warning. See @docs/messaging.md@, \"Supervised inbox services\", for the
-- same contract in prose.
module Hetoimasia.Runtime.Inbox
  ( -- * Definitions and policy
    InboxDefinition
  , inboxDefinition
  , InboxPolicy (..)

    -- * Starting
  , InboxStart (..)
  , startInboxService

    -- * The service handle
  , InboxService
  , inboxSender
  , stopInboxService
  , cancelInboxService
  , inboxStatus
  , inboxCompletion
  , awaitInboxCompletion
  , inboxAcknowledgedDrain

    -- * Finishing
  , InboxFinish (..)
  , finishInboxService

    -- * The exit record
  , InboxExit
  , inboxDiscarded
  , inboxDrain
  , DrainAcknowledgement
  , drainHandled

    -- * Failures
  , InboxInvariantViolated (..)
  , inboxComponent
  , inboxHandoffOperation
  , inboxFinishOperation
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, orElse, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (Exception, ExceptionWithContext, SomeException, uninterruptibleMask_)
import Control.Monad (unless, void)
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (for_)
import Data.Text (Text)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Channel
  ( ChannelControl
  , ChannelStatistics (statisticsDequeued, statisticsDiscarded)
  , Delivery (..)
  , Sender
  , Termination (..)
  , abortChannel
  , awaitReceive
  , channelReceiver
  , channelSender
  , channelStatistics
  , closeChannel
  , newChannel
  )
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Hetoimasia.Foundation.Resource (Scoped, allocResource)
import Hetoimasia.Foundation.Worker
  ( Completion (completionResult)
  , Result (Succeeded)
  , StopToken
  , WorkerDefinition
  , awaitCompletion
  , awaitStopRequest
  , pollCompletion
  , workerDefinition
  , workerLabel
  )
import Hetoimasia.Runtime.Supervision
  ( Disposition
  , Recognition
  , Role (Service)
  , RuntimeControl
  , SupervisedStart (..)
  , SupervisedWorker
  , WorkerPolicy (..)
  , WorkerStatus (WorkerStopped, WorkerUnavailable)
  , awaitSupervised
  , cancelSupervised
  , startSupervised
  , stopSupervised
  , supervisedWorker
  , workerStatus
  )
import Numeric.Natural (Natural)

-- Definitions ------------------------------------------------------------------

-- | A component's inbox service: its label, inbox capacity, context startup, and
-- message handler.
type role InboxDefinition nominal

data InboxDefinition a
  = ∀ context. InboxDefinition !Text !Integer (StopToken → Scoped context) (context → Prepared a → IO ())

-- | Define an inbox service.
--
-- The startup runs first on the worker's thread and owns what it allocates for
-- the whole run; it receives the worker's 'StopToken', never the application's
-- 'RuntimeControl'. The capacity is the inbox's, validated by
-- 'Hetoimasia.Foundation.Messaging.Channel.newChannel' after the context is
-- built. The handler runs on the worker's thread, once per received message.
inboxDefinition
  ∷ Text → Integer → (StopToken → Scoped context) → (context → Prepared a → IO ()) → InboxDefinition a
inboxDefinition = InboxDefinition

-- | The supervision policy of an inbox service. Its role is always 'Service'.
data InboxPolicy = InboxPolicy
  { inboxDisposition ∷ !Disposition
  , inboxPolicyComponent ∷ !Component
    -- ^ The component an optional service's warning is reported under.
  , inboxClassifier ∷ ExceptionWithContext SomeException → IO Recognition
  }

-- The exit record --------------------------------------------------------------

-- | What an inbox service returns when its stop is requested.
--
-- It records the inbox's cumulative discarded-entry count, read after the
-- stop's abort, and the drain acknowledgement the service recorded before that
-- stop, if any. Its representation is private: no client builds, updates, or
-- forges one.
data InboxExit = InboxExit !Natural !(Maybe DrainAcknowledgement)
  deriving (Eq, Show)

-- | Entries the inbox discarded over its life, as its cumulative counter reads
-- after the stop's abort. Zero after a finish; the real count after an
-- ordinary stop.
inboxDiscarded ∷ InboxExit → Natural
inboxDiscarded (InboxExit discarded _) = discarded

-- | The drain acknowledgement recorded before the stop, or 'Nothing' when the
-- stop won before a drain.
inboxDrain ∷ InboxExit → Maybe DrainAcknowledgement
inboxDrain (InboxExit _ drain) = drain

-- | Evidence that the service handled every message it accepted and then
-- observed its normally closed, empty inbox, in the decision that recorded it.
--
-- Only that decision constructs one.
data DrainAcknowledgement = DrainAcknowledgement !Natural
  deriving (Eq, Show)

-- | How many messages the service had received, and handled, when it
-- acknowledged the drain.
drainHandled ∷ DrainAcknowledgement → Natural
drainHandled (DrainAcknowledgement handled) = handled

-- | What 'finishInboxService' reports.
data InboxFinish
  = InboxFinished !InboxExit
    -- ^ A genuine drain acknowledgement, then an expected stop with successful
    -- cleanup. The exit record holds that acknowledgement and zero discards.
  | InboxUnfinished !(Maybe DrainAcknowledgement) !(Completion InboxExit)
    -- ^ Supervision settled 'WorkerStopped', but not as a finish: a stop or
    -- cancellation won before the drain, or a cancellation ended the service
    -- after one. It carries the acknowledgement, if one was recorded, and the
    -- actual completion.
  | InboxFinishUnavailable !(ExceptionWithContext SomeException)
    -- ^ An optional service failed with a recognized failure — possibly an
    -- unexpected cancellation — and its single warning was attempted by
    -- supervision. The acknowledgement, if any, stays on the handle.

-- Failures ---------------------------------------------------------------------

-- | An internal invariant of the adapter did not hold.
data InboxInvariantViolated
  = HandoffEmpty
    -- ^ A started service's handoff held no endpoint.
  | HandoffAlreadyWritten
    -- ^ A startup found its handoff already written.
  | InboxEndedWhileRunning
    -- ^ The inbox ended while its service was still dispatching.
  | FinishUnsettled
    -- ^ A finish found its service's completion with no committed stop or
    -- unavailable status.
  deriving (Eq, Show)

instance Exception InboxInvariantViolated

-- | The component an invariant failure names as its origin.
inboxComponent ∷ Component
inboxComponent = unsafeComponent "runtime.inbox"

-- | The operation an invariant failure names as its origin.
inboxHandoffOperation ∷ Operation
inboxHandoffOperation = operation "inbox-handoff"

-- | The operation a finish's invariant failure names as its origin.
inboxFinishOperation ∷ Operation
inboxFinishOperation = operation "inbox-finish"

-- The service handle -----------------------------------------------------------

-- | A started inbox service, held by the application.
--
-- Deliberately not a record, and exported without its constructor, so no client
-- can pair one service's endpoint with another's worker.
type role InboxService nominal

data InboxService a
  = InboxService !(SupervisedWorker InboxExit) !(ChannelControl a) !(TVar (Maybe DrainAcknowledgement))

-- | What 'startInboxService' returns.
data InboxStart a
  = InboxStarted !(InboxService a)
    -- ^ Startup was acknowledged and the endpoint handed off. The service may
    -- already have been stopped; 'inboxStatus' says.
  | InboxStartUnavailable !(ExceptionWithContext SomeException)
    -- ^ An optional service failed with a recognized failure during startup or
    -- as soon as it acknowledged. No endpoint is exposed.
  | InboxStartRejected
    -- ^ The supervision boundary had closed registration. Nothing ran.

-- | The send endpoint, for the application to give to producers.
inboxSender ∷ InboxService a → Sender a
inboxSender (InboxService _ inbox _) = channelSender inbox

-- | Ask the service to stop, as 'stopSupervised' does. Accepted backlog is
-- discarded, not processed; use 'finishInboxService' to process it first.
stopInboxService ∷ InboxService a → IO ()
stopInboxService (InboxService worker _ _) = stopSupervised worker

-- | Request cancellation of the service, as 'cancelSupervised' does.
cancelInboxService ∷ InboxService a → IO ()
cancelInboxService (InboxService worker _ _) = cancelSupervised worker

-- | What supervision has committed about the service.
inboxStatus ∷ InboxService a → STM WorkerStatus
inboxStatus (InboxService worker _ _) = workerStatus worker

-- | The typed completion if it has been published. Raw and non-consuming.
inboxCompletion ∷ InboxService a → STM (Maybe (Completion InboxExit))
inboxCompletion (InboxService worker _ _) = pollCompletion (supervisedWorker worker)

-- | Retry until the typed completion is published. Raw and non-consuming.
awaitInboxCompletion ∷ InboxService a → STM (Completion InboxExit)
awaitInboxCompletion (InboxService worker _ _) = awaitCompletion (supervisedWorker worker)

-- | The drain acknowledgement if the service has recorded one. Raw and
-- non-consuming; it stays readable whatever the completion turns out to be.
inboxAcknowledgedDrain ∷ InboxService a → STM (Maybe DrainAcknowledgement)
inboxAcknowledgedDrain (InboxService _ _ drain) = readTVar drain

-- Finishing --------------------------------------------------------------------

-- | Finish the service gracefully: close admission, let it handle the accepted
-- backlog and acknowledge the drain, then stop it and await its completion,
-- all through supervised waits.
--
-- Call it on the application thread, while the services the handler depends on
-- are still available. See the module header for the protocol and what each
-- outcome means. A required, unrecognized, or cleanup failure — this service's
-- or a latched one — propagates from here with its original evidence, and an
-- owner cancellation propagates after the group drained the worker.
finishInboxService ∷ RuntimeControl → InboxService a → IO InboxFinish
finishInboxService control (InboxService worker inbox drain) = do
  atomically (closeChannel inbox)
  acknowledged ←
    awaitSupervised control ((Just <$> (readTVar drain >>= maybe retry pure)) `orElse` (Nothing <$ awaitCompletion raw))
  for_ acknowledged (\_ → stopSupervised worker)
  completion ← awaitSupervised control (awaitCompletion raw)
  atomically (workerStatus worker) >>= \case
    WorkerStopped
      | Just acknowledgement ← acknowledged
      , Succeeded exit ← completionResult completion
      , inboxDrain exit == Just acknowledgement
      , inboxDiscarded exit == 0 →
          pure (InboxFinished exit)
      | otherwise → pure (InboxUnfinished acknowledged completion)
    WorkerUnavailable failure → pure (InboxFinishUnavailable failure)
    _ → throwFailure inboxComponent inboxFinishOperation [("service", workerLabel raw)] FinishUnsettled
  where
    raw = supervisedWorker worker

-- Starting ---------------------------------------------------------------------

-- | Start an inbox service under supervision and hand its send endpoint to the
-- caller.
--
-- See the module header for the startup order, the handoff, and what a failed
-- start returns or propagates.
startInboxService ∷ RuntimeControl → InboxPolicy → InboxDefinition a → IO (InboxStart a)
startInboxService control policy (InboxDefinition label capacity startup handler) = do
  handoff ← newTVarIO Nothing
  drain ← newTVarIO Nothing
  let supervised = WorkerPolicy Service (inboxDisposition policy) (inboxPolicyComponent policy) (inboxClassifier policy)
      definition = serviceDefinition label capacity startup handler handoff drain
  startSupervised control supervised definition >>= \case
    WorkerStartRejected → pure InboxStartRejected
    WorkerStartUnavailable _ failure → pure (InboxStartUnavailable failure)
    WorkerStarted worker →
      -- Acknowledgement follows the write, so this read never needs to wait.
      readTVarIO handoff >>= \case
        Just inbox → pure (InboxStarted (InboxService worker inbox drain))
        Nothing → throwFailure inboxComponent inboxHandoffOperation [("service", label)] HandoffEmpty

-- | The worker behind an inbox service.
serviceDefinition
  ∷ Text
  → Integer
  → (StopToken → Scoped context)
  → (context → Prepared a → IO ())
  → TVar (Maybe (ChannelControl a))
  → TVar (Maybe DrainAcknowledgement)
  → WorkerDefinition InboxExit
serviceDefinition label capacity startup handler handoff drain =
  workerDefinition label construct $ \token (context, inbox) → dispatch token context inbox
  where
    construct token = do
      context ← startup token
      -- The innermost allocation: released first on every exit.
      inbox ← allocResource (newChannel capacity) abortInbox
      liftIO (handOver inbox)
      pure (context, inbox)

    handOver inbox = do
      written ← atomically $
        readTVar handoff >>= \case
          Nothing → True <$ writeTVar handoff (Just inbox)
          Just _ → pure False
      unless written $
        throwFailure inboxComponent inboxHandoffOperation [("service", label)] HandoffAlreadyWritten

    dispatch token context inbox = loop
      where
        loop =
          atomically decide >>= \case
            StopTaken → exit
            Handle message → handler context message >> loop
            DrainAcknowledged → atomically (awaitStopRequest token) >> exit
            EndedWhileRunning →
              throwFailure inboxComponent inboxHandoffOperation [("service", label)] InboxEndedWhileRunning
        -- One decision: a requested stop wins over a ready message and over a
        -- drained inbox, and a drain is acknowledged in the transaction that
        -- observed the closed, empty inbox, never after a stop won.
        decide =
          (StopTaken <$ awaitStopRequest token)
            `orElse` ( awaitReceive (channelReceiver inbox) >>= \case
                         Delivered message → pure (Handle message)
                         Ended Drained → do
                           handled ← statisticsDequeued <$> channelStatistics inbox
                           writeTVar drain (Just (DrainAcknowledgement handled))
                           pure DrainAcknowledged
                         Ended Aborted → pure EndedWhileRunning
                     )
        exit = atomically $ do
          void (abortChannel inbox)
          InboxExit . statisticsDiscarded <$> channelStatistics inbox <*> readTVar drain

-- | One dispatch decision.
data Decision a
  = StopTaken
  | Handle (Prepared a)
  | DrainAcknowledged
  | EndedWhileRunning

-- | The abort safeguard: end admission and drop the backlog by its counter.
-- Never retries, waits, or calls out.
abortInbox ∷ ChannelControl a → IO ()
abortInbox inbox = uninterruptibleMask_ (void (atomically (abortChannel inbox)))
