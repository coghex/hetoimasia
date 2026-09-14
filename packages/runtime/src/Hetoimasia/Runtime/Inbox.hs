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
-- __Dispatch.__ One prepared message at a time. The stop check and the receive
-- are one STM choice, and a requested stop wins over a simultaneously ready
-- message. The handler runs outside STM. A message a committed receive selected
-- is in flight: a stop cannot retract its effects, and nothing retries it.
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
-- __The exit record.__ On an ordinary stop the service aborts its inbox, then
-- reads the channel's cumulative discard count from committed state into an
-- immutable 'InboxExit', which is the run's result. It records nothing else:
-- accepted backlog is __not__ processed on stop, and there is no drain count or
-- acknowledgement. A failed, cancelled, or cleanup-failed run keeps its actual
-- 'Completion' evidence; no 'InboxExit' is manufactured for it.
--
-- __Completion.__ 'inboxCompletion' and 'awaitInboxCompletion' are raw,
-- non-consuming STM reads of the typed completion. They compose with
-- 'Hetoimasia.Runtime.Supervision.awaitSupervised' inside supervision — which
-- may deliver a latched fatal failure instead of returning that evidence — and
-- stay readable after the group has drained. 'WorkerStopped' alone is not an
-- exit record; the completion's 'Succeeded' result is.
--
-- __Dependencies.__ Borrowed dependencies stay alive through worker cleanup
-- under the group's drain. A stuck handler keeps its resources under the same
-- policy: no deadline and no detach.
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
-- | Stop exit       | The run writes it once as its result; any     | Worker writes; any thread  | Published with the completion; never   |
-- | record          | number of completion readers                  | reads, in STM              | changes or is consumed                 |
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

    -- * The exit record
  , InboxExit
  , inboxDiscarded

    -- * Failures
  , InboxInvariantViolated (..)
  , inboxComponent
  , inboxHandoffOperation
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, orElse, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, ExceptionWithContext, SomeException, uninterruptibleMask_)
import Control.Monad (unless, void)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Channel
  ( ChannelControl
  , ChannelStatistics (statisticsDiscarded)
  , Delivery (..)
  , Sender
  , abortChannel
  , awaitReceive
  , channelReceiver
  , channelSender
  , channelStatistics
  , newChannel
  )
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Hetoimasia.Foundation.Resource (Scoped, allocResource)
import Hetoimasia.Foundation.Worker
  ( Completion
  , StopToken
  , WorkerDefinition
  , awaitCompletion
  , awaitStopRequest
  , pollCompletion
  , workerDefinition
  )
import Hetoimasia.Runtime.Supervision
  ( Disposition
  , Recognition
  , Role (Service)
  , RuntimeControl
  , SupervisedStart (..)
  , SupervisedWorker
  , WorkerPolicy (..)
  , WorkerStatus
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

-- | What an ordinarily stopped inbox service returns.
--
-- It records only the inbox's cumulative discarded-entry count, read after the
-- stop's abort. It has no drain count: accepted backlog is not processed on
-- stop.
data InboxExit = InboxExit !Natural
  deriving (Eq, Show)

-- | Entries the inbox discarded over its life, as its cumulative counter reads
-- after the stop's abort.
inboxDiscarded ∷ InboxExit → Natural
inboxDiscarded (InboxExit discarded) = discarded

-- Failures ---------------------------------------------------------------------

-- | An internal invariant of the adapter did not hold.
data InboxInvariantViolated
  = HandoffEmpty
    -- ^ A started service's handoff held no endpoint.
  | HandoffAlreadyWritten
    -- ^ A startup found its handoff already written.
  | InboxEndedWhileRunning
    -- ^ The inbox ended while its service was still dispatching.
  deriving (Eq, Show)

instance Exception InboxInvariantViolated

-- | The component an invariant failure names as its origin.
inboxComponent ∷ Component
inboxComponent = unsafeComponent "runtime.inbox"

-- | The operation an invariant failure names as its origin.
inboxHandoffOperation ∷ Operation
inboxHandoffOperation = operation "inbox-handoff"

-- The service handle -----------------------------------------------------------

-- | A started inbox service, held by the application.
--
-- Deliberately not a record, and exported without its constructor, so no client
-- can pair one service's endpoint with another's worker.
type role InboxService nominal

data InboxService a = InboxService !(SupervisedWorker InboxExit) !(Sender a)

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
inboxSender (InboxService _ sender) = sender

-- | Ask the service to stop, as 'stopSupervised' does. Accepted backlog is
-- discarded, not processed.
stopInboxService ∷ InboxService a → IO ()
stopInboxService (InboxService worker _) = stopSupervised worker

-- | Request cancellation of the service, as 'cancelSupervised' does.
cancelInboxService ∷ InboxService a → IO ()
cancelInboxService (InboxService worker _) = cancelSupervised worker

-- | What supervision has committed about the service.
inboxStatus ∷ InboxService a → STM WorkerStatus
inboxStatus (InboxService worker _) = workerStatus worker

-- | The typed completion if it has been published. Raw and non-consuming.
inboxCompletion ∷ InboxService a → STM (Maybe (Completion InboxExit))
inboxCompletion (InboxService worker _) = pollCompletion (supervisedWorker worker)

-- | Retry until the typed completion is published. Raw and non-consuming.
awaitInboxCompletion ∷ InboxService a → STM (Completion InboxExit)
awaitInboxCompletion (InboxService worker _) = awaitCompletion (supervisedWorker worker)

-- Starting ---------------------------------------------------------------------

-- | Start an inbox service under supervision and hand its send endpoint to the
-- caller.
--
-- See the module header for the startup order, the handoff, and what a failed
-- start returns or propagates.
startInboxService ∷ RuntimeControl → InboxPolicy → InboxDefinition a → IO (InboxStart a)
startInboxService control policy (InboxDefinition label capacity startup handler) = do
  handoff ← newTVarIO Nothing
  let supervised = WorkerPolicy Service (inboxDisposition policy) (inboxPolicyComponent policy) (inboxClassifier policy)
      definition = serviceDefinition label capacity startup handler handoff
  startSupervised control supervised definition >>= \case
    WorkerStartRejected → pure InboxStartRejected
    WorkerStartUnavailable _ failure → pure (InboxStartUnavailable failure)
    WorkerStarted worker →
      -- Acknowledgement follows the write, so this read never needs to wait.
      readTVarIO handoff >>= \case
        Just inbox → pure (InboxStarted (InboxService worker (channelSender inbox)))
        Nothing → throwFailure inboxComponent inboxHandoffOperation [("service", label)] HandoffEmpty

-- | The worker behind an inbox service.
serviceDefinition
  ∷ Text
  → Integer
  → (StopToken → Scoped context)
  → (context → Prepared a → IO ())
  → TVar (Maybe (ChannelControl a))
  → WorkerDefinition InboxExit
serviceDefinition label capacity startup handler handoff =
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
        loop = do
          next ← atomically ((Nothing <$ awaitStopRequest token) `orElse` (Just <$> awaitReceive (channelReceiver inbox)))
          case next of
            Nothing → finish
            Just (Delivered message) → handler context message >> loop
            Just (Ended _) →
              throwFailure inboxComponent inboxHandoffOperation [("service", label)] InboxEndedWhileRunning
        finish = atomically $ do
          void (abortChannel inbox)
          InboxExit . statisticsDiscarded <$> channelStatistics inbox

-- | The abort safeguard: end admission and drop the backlog by its counter.
-- Never retries, waits, or calls out.
abortInbox ∷ ChannelControl a → IO ()
abortInbox inbox = uninterruptibleMask_ (void (atomically (abortChannel inbox)))
