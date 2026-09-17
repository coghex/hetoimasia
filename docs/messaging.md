# Messaging

Current behavior of `Hetoimasia.Foundation.Messaging.Payload`, the prepared
payload boundary every messaging transport accepts, and of
`Hetoimasia.Foundation.Messaging.Channel`, the bounded FIFO channel that carries
prepared payloads, and of `Hetoimasia.Foundation.Messaging.Snapshot`, the
latest-value snapshot read through checked cursors, and of
`Hetoimasia.Runtime.Inbox`, the optional runtime adapter that runs a supervised
service with one inbox. The accepted contract is epic #73; this document
describes what the code does today.

Scope: preparing a payload to normal form on the producer's thread, reading and
forwarding a prepared payload, what a preparation failure does, and what a
client cannot do to a prepared handle; then creating a bounded channel, sending
and receiving, closing and aborting it, its counters, where waiting on it is
safe, and which endpoint may do what; then publishing a latest value, reading and
waiting through cursors, closing a snapshot, and the cursor-mismatch failure;
then starting, stopping, and gracefully finishing a supervised inbox service,
with its drain acknowledgement; and two composed examples, a command service
publishing snapshots and a bounded multi-input loop. The transactional failure companion is described in
[failures.md](failures.md).

## Public interface

```haskell
data Prepared a                      -- abstract; role nominal
prepare       ∷ NFData a ⇒ a → IO (Prepared a)
preparedValue ∷ Prepared a → a
```

`prepare` is the only way to obtain a `Prepared a`. It fully evaluates the value
through its `NFData` instance with `evaluate . force`, in `IO`, on the calling
thread, and returns the handle only after that evaluation finished.

`preparedValue` is a pure projection. It evaluates nothing, and neither it nor
holding a handle requires `NFData a`. A function that reads or forwards
payloads can therefore be written for any `a`:

```haskell
forward ∷ Receiver a → Sender a → STM ()   -- no NFData a, and no evaluation
```

An unchanged payload is forwarded as the same handle and never prepared again.

## Evaluation guarantees

- **Normal form before publication.** A failure nested anywhere the `NFData`
  instance reaches is raised by `prepare`. For a strict record over a lazy list,
  weak head normal form forces the record and the list's first cell but no
  element; preparation forces every element, so a throwing element fails the
  producer and never reaches a reader.
- **Once.** Reading, re-reading, and forwarding a prepared payload run no
  `NFData` instance and force nothing further.
- **Lawful, component-owned instances.** Normal form means exactly what the
  payload type's own `NFData` instance forces. The component that owns the
  type owns that instance. An instance that skips a field leaves that field
  lazy, and neither this module nor a later transport can detect it; no
  transport validates arbitrary instances.
- **Producer-side cost.** Evaluation costs time proportional to the value and
  runs on the producer's thread, before any publication. Charging the producer
  is the purpose, not a side effect. No throughput or allocation target is made,
  and no packed representation is used.
- **No resource scope.** Preparation evaluates a value; it owns nothing the value
  refers to. A closure or a borrowed native handle inside a prepared payload is
  valid only inside the scope that owns it, and preparing the payload does not
  extend that scope. Queued native handles and ownership transfer are not part
  of this contract.
- **No bypass.** There is no weak-head-only or unprepared route. A transformed
  value is a new value and is prepared again.

## Failures and cancellation

A preparation failure propagates from `prepare` with its original type, its
value, and every annotation it already carried, and no handle is returned.
`prepare` catches nothing, retries nothing, and logs nothing, so the failure is
the producer's to handle or report.

Inside [`withOperationContext`](failures.md#adding-operation-context) the
failure gains that boundary's operation context like any other synchronous
failure: a typed engine failure raised with `throwFailure` keeps its engine
origin, and a native `IOException` stays native with the boundary's context.
`failureEvidence` reads both back.

Cancellation delivered while preparation is running propagates as that
cancellation and is left unannotated, as [failures.md](failures.md#cancellation)
describes for every boundary.

## Opacity

A client outside the foundation package cannot obtain a `Prepared` value except
through `prepare`, and cannot change the payload of one it holds:

| Attempt | Why it is rejected |
|---|---|
| Naming the constructor | `Prepared` is exported without its children |
| Record update of `preparedValue` | `preparedValue` is a function, not a record field |
| `coerce ∷ a → Prepared a` | The constructor is not in scope |
| `coerce ∷ Prepared A → Prepared B` for representationally equal `A` and `B` | The role is nominal; `B`'s `NFData` instance never ran |
| `fmap` or `traverse` over a handle | There is no `Functor`, `Foldable`, or `Traversable` instance |

## Bounded FIFO channels

```haskell
data ChannelControl a                -- abstract; role nominal
data Sender a                        -- abstract; role nominal
data Receiver a                      -- abstract; role nominal

newChannel      ∷ HasCallStack ⇒ Integer → IO (ChannelControl a)
maximumCapacity ∷ Integer
channelSender   ∷ ChannelControl a → Sender a
channelReceiver ∷ ChannelControl a → Receiver a

send         ∷ Sender a → Prepared a → STM SendResult   -- Accepted | Full | Closed
awaitSend    ∷ Sender a → Prepared a → STM Admission    -- Admitted | AdmissionClosed
receive      ∷ Receiver a → STM (Receipt a)             -- Received p | Empty | Terminated t
awaitReceive ∷ Receiver a → STM (Delivery a)            -- Delivered p | Ended t
                                                        -- t ∷ Termination = Drained | Aborted

closeChannel      ∷ ChannelControl a → STM ()
abortChannel      ∷ ChannelControl a → STM Natural
channelStatistics ∷ ChannelControl a → STM ChannelStatistics
```

### Endpoints

`newChannel` returns the owner-control endpoint, `ChannelControl`. Its holder
hands out the other two with `channelSender` and `channelReceiver`, and is the
only one that can close or abort the channel or read its statistics. A `Sender`
can only send: it cannot receive, close, or abort. A `Receiver` can only
receive: it cannot send, close, or abort. Every operation is an ordinary
function, no endpoint has a record selector, and no queue, `TVar`, or other
private state escapes the module.

Any number of threads may hold the same `Sender` or `Receiver`. One logical
consumer per channel is an ownership convention the owner keeps, not something
the types enforce: two threads receiving from one channel each get distinct
entries, and neither sees the whole stream in order.

### Capacity and admission

The owner chooses the capacity when it creates the channel. There is no
clamping, no zero-capacity rendezvous, and no engine-wide default.

- A capacity below one throws `CapacityNotPositive`, and one above
  `maximumCapacity` — the largest depth the channel's `Int` depth counter
  represents — throws `CapacityAboveMaximum`. Both are
  `ChannelCapacityRejected` raised in `IO` with
  [`throwFailure`](failures.md#raising-a-failure): component
  `foundation.messaging`, operation `new-channel`, the capacity as the
  `capacity` identifier, and the caller's site as the origin. No channel exists
  afterwards. Construction compares before it allocates, and allocates nothing
  proportional to the capacity.
- `send` never waits. It reports `Accepted`, `Full` when the open channel holds
  capacity entries, or `Closed` once admission has ended. `Closed` takes
  precedence over `Full`. `Full` and `Closed` change neither the queue nor a
  counter, and the caller still holds its payload.
- `awaitSend` is the separate operation that waits. It retries only while the
  channel is open and full, returns `Admitted` once there is room, and returns
  `AdmissionClosed` as soon as admission ends, never retrying on a terminal
  channel.
- A sender cannot tell why a channel stopped: close and abort both appear as
  `Closed` or `AdmissionClosed`.

### Receiving and order

`receive` never waits. It reports `Received` with the oldest entry, `Empty` for
an open channel with no entries, `Terminated Drained` for a closed channel whose
backlog has been received, and `Terminated Aborted` for an aborted channel.
`awaitReceive` retries only while the channel is open and empty and otherwise
returns `Delivered` or `Ended` with the same termination.

Entries are received in the order their admissions committed. Each producer's
own entries keep that producer's order; entries from concurrent producers
interleave in whatever order their transactions committed. No wall-clock order,
fairness among producers, batching, or coalescing is promised.

A receive returns the very `Prepared` handle that was sent, so it can be sent to
another channel unchanged, without `NFData` and without evaluation.

### Close and abort

| | `closeChannel` | `abortChannel` |
|---|---|---|
| Admission | Ends | Ends |
| Backlog | Kept, and received in order | Dropped; returns the number this call discarded |
| A receive once nothing is queued | `Drained` | `Aborted` |
| After the other | Never weakens an abort | Strengthens a close |
| Repeated | No effect | Returns zero and changes no counter |

Both wake a blocked `awaitSend`, which returns `AdmissionClosed`, and a blocked
`awaitReceive` on an empty channel, which returns `Ended`. A channel never
reopens. Abort cannot recall an entry already received.

Neither operation ever executes STM `retry` or waits for another participant,
so both are safe inside a controlled release such as an `allocResource`
release. Abort takes its discard count from the depth counter; it neither
traverses nor forces the backlog it drops.

### Where waiting is safe

`awaitSend` and `awaitReceive` block until the channel changes. Wait on them
composed with the owner's own wake:

- **On the application thread**, inside
  [`awaitSupervised`](supervision.md#checkpoints-and-supervised-waits):
  `awaitSupervised control (awaitReceive receiver)`. A pending worker outcome is
  settled before the channel operation commits, and the wait then starts again,
  so the entry is received exactly once. A pending fatal failure is rethrown and
  the channel operation never commits. Classification and reporting stay outside
  the channel's transaction.
- **On a worker**, composed with its stop request:
  `atomically ((Right <$> awaitReceive receiver) `orElse` (Left <$> awaitStopRequest token))`.
  A stop leaves through the second branch with the channel unchanged.

A bare `atomically (awaitReceive receiver)` on the application thread is not
supervised, and on a worker that does not observe its stop request it keeps the
worker, and its group's drain, waiting until the channel changes. Never wait on a
channel inside a release; close and abort are the operations a release may use.

### Statistics

`channelStatistics` reads every field in one transaction, so a reading is always
a committed state and never mixes fields sampled at different times.

| Field | Meaning |
|---|---|
| `statisticsCapacity` | The capacity chosen at construction |
| `statisticsDepth` | Entries accepted and neither received nor discarded |
| `statisticsHighWater` | The largest depth the channel has held |
| `statisticsAccepted` | Payloads admitted by a committed send |
| `statisticsDequeued` | Entries returned by a committed receive |
| `statisticsDiscarded` | Entries dropped by abort |

Every field is a non-wrapping, nonnegative `Natural`. Every committed state
satisfies `accepted = dequeued + discarded + depth`. High-water never decreases
and never exceeds the capacity. A `Full` or `Closed` result, and a transaction
that rolled back, count nothing. Statistics hold no payload and expose no
mutable internals.

### Transaction hygiene

No channel transaction evaluates a payload — an entry is stored unevaluated, and
moving entries between the queue's two internal lists moves list cells only —
reads a clock, logs, invokes a callback or destructor, or uses `unsafeIOToSTM`.
No channel operation raises a typed failure inside STM; the only failure is
construction's, in `IO`.

### Endpoint opacity

| Attempt | Why it is rejected |
|---|---|
| `receive` with a `Sender` | `receive` takes a `Receiver` |
| `closeChannel` or `abortChannel` with a `Sender` or a `Receiver` | Both take a `ChannelControl` |
| Naming an endpoint's constructor | Each endpoint type is exported without its children |
| Record update of `channelSender` or `channelReceiver` | They are functions, not record fields |
| `coerce ∷ Sender A → Sender B` | Every endpoint's role is nominal |

## Latest-value snapshots

```haskell
data SnapshotPublisher a             -- abstract; role nominal
data SnapshotReader a                -- abstract; role nominal
data Observation a                   -- abstract; role nominal
data SnapshotCursor a                -- abstract; role nominal; Eq

newSnapshot    ∷ Prepared a → IO (SnapshotPublisher a)
snapshotReader ∷ SnapshotPublisher a → SnapshotReader a

publish       ∷ SnapshotPublisher a → Prepared a → STM Publication   -- Published | PublicationClosed
closeSnapshot ∷ SnapshotPublisher a → STM ()

readSnapshot   ∷ SnapshotReader a → STM (Observation a)
awaitSnapshot  ∷ HasCallStack ⇒ SnapshotReader a → SnapshotCursor a → STM (Update a)
                                                  -- Updated observation | EndOfStream
observedValue  ∷ Observation a → Prepared a
observedCursor ∷ Observation a → SnapshotCursor a
cursorRevision ∷ SnapshotCursor a → Natural
```

A snapshot holds one latest value. It is for state a reader needs only the
newest of, such as a processed input state; a stream in which every entry
matters belongs in a channel. A coherent snapshot does not relate separate
streams: publishing a state before the events that follow it is an ordering the
components involved agree on, not something a snapshot provides.

### Endpoints and identity

`newSnapshot` creates an open snapshot from a prepared initial value and returns
the publisher endpoint, which hands out the read endpoint with
`snapshotReader`. A `SnapshotReader` can read and wait; it cannot publish or
close. Every operation is an ordinary function, no endpoint or observation has a
record selector, and no `TVar` or other private state escapes the module.

Every `newSnapshot` call has a fresh identity. A new lifetime is always a new
snapshot, never a revision reset on an old one: nothing resets or reopens a
snapshot.

Any number of threads may hold the publisher or a reader. One logical publisher
per snapshot is an ownership convention the owner keeps, not something the types
enforce; two threads publishing to one snapshot each advance the revision, and
readers see whichever publication committed last.

### Publication and revision

`publish` replaces the value and its revision in one write, so a reader never
observes a value paired with another publication's revision, or a mix of
fields.

- The initial value has revision zero. Every committed publication advances the
  revision by one, including publication of an equal value, or of the very
  handle already held: no `Eq` instance is required and no content is compared.
- The revision is a `Natural` and never wraps.
- A transaction that rolls back, by `retry` under `orElse` or by an exception,
  changes neither value nor revision.
- `publish` never waits. On a closed snapshot it returns `PublicationClosed`
  and changes nothing.

### Observations and cursors

`readSnapshot` returns an `Observation`: the current `Prepared` payload, read
with `observedValue`, paired with a `SnapshotCursor`, read with
`observedCursor`. The cursor names this snapshot and the observed revision,
which `cursorRevision` reads. Neither an observation nor a cursor can be built,
rewritten, or re-typed outside the module.

A read changes nothing another reader can see. The observed payload is the very
handle that was published, so it can be published to another snapshot or sent
on a channel unchanged, without `NFData` and without evaluation.

A cursor is the reader's own last revision. The snapshot keeps no per-reader
state and no history of earlier publications.

### Waiting

`awaitSnapshot` takes a cursor:

| Snapshot | Newer than the cursor | Result |
|---|---|---|
| Open or closed | Yes | `Updated`, with the newest publication and its new cursor |
| Closed | No | `EndOfStream` |
| Open | No | `retry` |

A reader that missed intermediate publications receives only the newest. Two
readers waiting from the same cursor each receive the same publication, and
neither acknowledges anything for the other. A reader advances only the cursor it
holds; waiting again from an older cursor returns the current value again.

### Cursor mismatch

A cursor from a different snapshot is API misuse. `awaitSnapshot` raises
`ForeignSnapshotCursor` with
[`throwFailureSTM`](failures.md#raising-inside-a-transaction): component
`foundation.messaging`, operation `await-snapshot`, the cursor's revision as the
`cursor-revision` identifier, and the caller's site as the origin. The
exception's value carries the same revision.

The identity check comes first, before the value, revision, or terminal flag is
read and before any wait, so a mismatch fails at once whether the target is
open, closed, or has something newer. Identities are compared exactly; revisions
and hashes play no part, so a cursor from another snapshot at the same revision
is rejected, and so is a retained cursor from a closed earlier lifetime used
with its replacement. A failure that escapes `atomically` rolls the whole
transaction back.

### Close

`closeSnapshot` ends publication:

- It is idempotent and never executes `retry`, so it is safe inside a
  controlled release.
- It keeps the last value, and the same cursor, for current reads.
- It does not advance the revision and is not a publication. A waiter holding a
  cursor older than the final publication receives that publication first and
  `EndOfStream` next; a waiter holding the current cursor receives
  `EndOfStream`, including when the snapshot is closed before any publication.
- It wakes waiting readers.
- A closed snapshot never reopens; a later `publish` returns
  `PublicationClosed` with value and revision unchanged.

### Where waiting on a snapshot is safe

As with a channel, wait composed with the owner's own wake:
`awaitSupervised control (awaitSnapshot reader cursor)` on the application
thread, where a pending worker outcome is settled before the read commits and a
pending fatal failure is rethrown with the read never committed; and, on a
worker,
`atomically ((Right <$> awaitSnapshot reader cursor) `orElse` (Left <$> awaitStopRequest token))`.
Never wait on a snapshot inside a release.

### Native resources

A snapshot grants no lifetime ownership over anything a value refers to. A
native handle inside a published value is still owned, and released, by the
scope that owns it; keeping the value in a snapshot, including after close, does
not extend that scope.

### Transaction hygiene

No snapshot transaction evaluates a payload — the value is stored in a lazy
field and returned as the same handle — reads a clock, logs, invokes a callback,
or uses `unsafeIOToSTM`. The only failure a snapshot operation raises is the
cursor mismatch, inside STM.

### Snapshot opacity

| Attempt | Why it is rejected |
|---|---|
| `publish` or `closeSnapshot` with a `SnapshotReader` | Both take a `SnapshotPublisher` |
| Naming the `SnapshotCursor` or `Observation` constructor | Each is exported without its children |
| Record update of `observedValue` | It is a function, not a record field |
| Record update of `snapshotReader` | It is a function, not a record field |
| `coerce` between endpoint, observation, or cursor types | Every role is nominal |

## Supervised inbox services

```haskell
data InboxDefinition a                   -- abstract; role nominal
inboxDefinition ∷ Text → Integer → (StopToken → Scoped context)
                → (context → Prepared a → IO ()) → InboxDefinition a
data InboxPolicy = InboxPolicy
  { inboxDisposition ∷ Disposition, inboxPolicyComponent ∷ Component
  , inboxClassifier ∷ ExceptionWithContext SomeException → IO Recognition }

startInboxService ∷ RuntimeControl → InboxPolicy → InboxDefinition a → IO (InboxStart a)
data InboxStart a = InboxStarted (InboxService a)
                  | InboxStartUnavailable (ExceptionWithContext SomeException)
                  | InboxStartRejected

data InboxService a                      -- abstract; role nominal
inboxSender          ∷ InboxService a → Sender a
stopInboxService     ∷ InboxService a → IO ()
cancelInboxService   ∷ InboxService a → IO ()
inboxStatus          ∷ InboxService a → STM WorkerStatus
inboxCompletion      ∷ InboxService a → STM (Maybe (Completion InboxExit))
awaitInboxCompletion ∷ InboxService a → STM (Completion InboxExit)
inboxAcknowledgedDrain ∷ InboxService a → STM (Maybe DrainAcknowledgement)

finishInboxService ∷ RuntimeControl → InboxService a → IO InboxFinish
data InboxFinish = InboxFinished InboxExit
                 | InboxUnfinished (Maybe DrainAcknowledgement) (Completion InboxExit)
                 | InboxFinishUnavailable (ExceptionWithContext SomeException)

data InboxExit                           -- abstract
inboxDiscarded ∷ InboxExit → Natural
inboxDrain     ∷ InboxExit → Maybe DrainAcknowledgement
data DrainAcknowledgement                -- abstract
drainHandled   ∷ DrainAcknowledgement → Natural

data InboxInvariantViolated = HandoffEmpty | HandoffAlreadyWritten | InboxEndedWhileRunning
                            | FinishUnsettled
```

`Hetoimasia.Runtime.Inbox` lives in the runtime package and is optional:
channels work without it, and component protocols and handlers stay with their
components. It starts one supervised `Service` through `startSupervised` and
the worker's own `Scoped` startup, with the owner's disposition, warning
component, and classifier. It is not a second runner, supervisor, thread
registry, restart policy, or scheduler, and it changes no supervision or worker
contract.

### Roles and endpoints

The application holds the `InboxService` handle and gives producers only its
`Sender`. The worker receives its own `StopToken`, passed to the context
startup, and the context that startup built, passed to the handler; it never
receives the application's `RuntimeControl`. The handle exposes the endpoint,
stop, finish, cancel, status, completion, and drain-acknowledgement reads and
nothing else. Its constructor, the supervised worker and inbox control inside
it, the definition's constructor, the handoff, and the acknowledgement's
constructor are private.

### Startup order

Inside the worker's startup, on the worker's thread:

1. The component context and every resource it owns are constructed.
2. The inbox is allocated with `newChannel` and the definition's capacity, and
   its abort is registered as the release of that allocation — the innermost
   one, so reverse scope order ends admission and drops the backlog before any
   component resource is released. No allocation follows it.
3. The inbox's control endpoint is written into a private one-shot handoff.

Only then does the worker acknowledge startup. A capacity `newChannel` rejects
is a startup failure raised after the context was built, which is released.

### Handoff

`startSupervised` returns `WorkerStarted` only after acknowledgement, so the
handoff is already full when the adapter reads it. It reads it once, with a
read that never retries, and starts no second readiness wait. An empty handoff,
or a startup that finds its handoff already written, raises
`InboxInvariantViolated` through `throwFailure` with the `runtime.inbox`
component, the `inbox-handoff` operation, and the service label. An invariant
failure or an owner cancellation during that read leaves the started worker
registered with its group, which stops and drains it on exit.

### Failed starts

| Start | Returned or raised | Component construction and release |
|---|---|---|
| Registration closed | `InboxStartRejected` | Nothing runs |
| Recognized failure of an optional service, during startup or as it acknowledged | `InboxStartUnavailable` with the failure, and its one warning | What was constructed is released |
| Required, unrecognized, or cleanup failure during startup | Propagates as from `startSupervised`, with its type, context, and evidence | What was constructed is released |
| Owner cancellation of the start | Propagates as cancellation after the worker drained | What was constructed is released |

None of these exposes an endpoint. A failure or cancellation while the context
is being constructed happens before the inbox exists; the inbox is closed during
component release wherever its allocation had succeeded. Once the start has
returned an endpoint, a cancellation delivered before dispatch begins still
closes that endpoint before the component is torn down, and keeps its
`Cancelled` completion.

### Dispatch

The service handles one `Prepared` message at a time. The stop check, the
receive, and the recording of a drain acknowledgement are one STM decision,
`awaitStopRequest` `orElse` `awaitReceive`, so a requested stop wins when a
message, or a drained inbox, is simultaneously ready. The handler runs outside
STM. A message a committed receive selected is in flight: a stop cannot
retract its effects, the handler runs to its end, and nothing retries it. A
stuck handler keeps the worker, and its resources and borrowed dependencies,
alive under the group's drain; there is no deadline or detach.

### Finish versus stop

The owner ends a service in one of two ways.

- **Ordinary stop.** `stopInboxService`, or closing's stop when the application
  action returns, is taken at the next dispatch decision. The in-flight message
  finishes; accepted backlog is aborted and counted as discarded, never
  processed.
- **Graceful finish.** `finishInboxService control service` runs on the
  application thread:
  1. It closes admission with `closeChannel` — a normal close, not an abort —
     while the worker runs. Later sends report `Closed`, and admission never
     reopens.
  2. The worker completes the in-flight handler, then handles the accepted
     backlog in FIFO order, one message at a time as before.
  3. The worker acknowledges the drain only after those handlers returned and a
     dispatch decision observed the normally closed, empty inbox (`Ended
     Drained`), in that same transaction. Empty depth alone is never an
     acknowledgement, and neither is a cached end-of-stream observation after a
     stop has won.
  4. Having acknowledged, the worker waits for its stop token rather than
     returning, so it keeps its `Service` role and no `UnexpectedServiceExit`
     arises.
  5. Finish observes the acknowledgement through `awaitSupervised`, calls
     `stopSupervised`, and awaits the terminal completion through
     `awaitSupervised`. A raw completion read never bypasses pending worker
     outcomes or the fatal latch.

The finish wait ends on the acknowledgement or on the completion being
published without one, so finish never waits for a marker a terminal worker can
no longer produce. A job completing, or an optional worker becoming
unavailable, while finish waits is settled by `awaitSupervised` before the wait
resumes; it neither consumes the acknowledgement nor causes a false finish.
In-flight effects are never retried by either path.

### The drain acknowledgement

A `DrainAcknowledgement` is written once, by the dispatch decision described
above, into state owned by the service's start. It records `drainHandled`, the
number of messages the service had received — and whose handlers had returned —
when it acknowledged. Its constructor is private, so no client forges one.

It is readable in three places: `inboxAcknowledgedDrain` on the handle, a raw
non-consuming STM read that stays valid whatever the completion turns out to
be; the finish result; and `inboxDrain` on a `Succeeded` exit record. A later
stop, abort, or cancellation leaves it in place, and cannot undo a handler that
completed.

### Finish outcomes

| Outcome | When | Evidence |
|---|---|---|
| `InboxFinished exit` | A genuine acknowledgement, then `Succeeded exit` recording that acknowledgement and zero discards, successful cleanup, and `WorkerStopped` — the expected-stop classification | The exit record |
| `InboxUnfinished drain completion` | Supervision settled `WorkerStopped`, but a stop or cancellation won before the drain, or a cancellation ended the service after it | The acknowledgement if one was recorded, and the actual completion |
| `InboxFinishUnavailable failure` | An optional service failed with a recognized failure — including a handler failure before the drain and a cancellation no owner asked for after it | The failure with its context; supervision attempted the single warning |

A required or unrecognized failure, and any retained cleanup failure,
propagates from `finishInboxService` through supervision with its original
type, context, and evidence, as does a fatal failure already latched for
another worker. A cancellation after an acknowledged drain keeps the
acknowledgement and its `Cancelled` completion; it is never a successful
finish, even when the settled status is `WorkerStopped`, and no `Succeeded`
exit record is fabricated for it. `FinishUnsettled`, raised through
`throwFailure` with the `inbox-finish` operation, marks the invariant that
supervision has committed a stop or unavailable status by the time the
completion is returned.

Repeated finishes, stops, and completion reads re-run no handler and repeat no
effect: each finish closes an already closed inbox, finds the same
acknowledgement or completion, and reports the same outcome.

Owner cancellation during finish propagates out of `finishInboxService` like
any cancellation of a supervised wait. The supervision boundary then stops and
cancels the worker and drains it with its borrowed dependencies alive before
the cancellation leaves; a stuck handler keeps its resources under the same
policy, with no deadline and no detach.

### Requesting graceful completion

Request a finish while the services the handler depends on are still
available. The backlog is handled by the service's own handler, on its own
thread, with whatever the component borrowed; finish before the application
action returns and before any dependency the handler uses begins shutting
down. Closing's stop, which runs after the action returns, is an ordinary stop
and discards the backlog.

### Abort on stop and on failure

Every exit from the service aborts the inbox — admission ends and pending
references are dropped — before the component's resources are released and
before the terminal completion is published:

- a stop, whether requested with `stopInboxService`, by a finish after the
  drain, or by closing when the application action returns;
- a synchronous handler failure;
- cancellation, including cancellation before the run loop begins;
- an exit straight after acknowledgement.

The safeguard is the inbox allocation's release. It runs under
`uninterruptibleMask_`, executes no `retry`, waits for nothing, invokes no
handler, logs nothing, joins no worker, and uses the channel's counter-based
`abortChannel` rather than traversing the backlog it drops. An ordinary stop
aborts once more inside the run, before reading the exit record; the release's
second abort is idempotent.

### Handler failures and recovery

A synchronous exception escaping the handler ends dispatch; the next queued
message is not handled. The exception fails the run with its original type and
context after the abort and the scope's cleanup, and supervision decides:

- a recognized failure of an optional service makes it unavailable, with its
  single warning;
- a required or unrecognized failure is fatal;
- a retained cleanup failure is fatal.

There is no per-message isolation, catch-and-continue, warning-and-skip, or
replay. A handler that can recover — explicitly, for instance with
`recover` from [recovery.md](recovery.md) — does so before the exception
escapes; returning normally lets dispatch continue with the next message.

### The exit record

When its stop is taken, the service aborts its inbox and then, in the same
transaction, reads the channel's cumulative discarded count and the drain
acknowledgement it recorded, if any, into an `InboxExit`, which is the run's
result. The count is the channel's cumulative counter, not the latest abort's
return value. `InboxExit` is immutable, its constructor is private, and
`inboxDiscarded` and `inboxDrain` are ordinary functions, so no client builds,
updates, or forges one.

A graceful finish records the acknowledgement and zero discards. An ordinary
stop records no acknowledgement and its real discard count: that backlog is
not processed. A client that reads only `inboxDiscarded` is unaffected by the
acknowledgement field.

### Completion observation

`inboxCompletion` and `awaitInboxCompletion` read the typed completion without
consuming it; repeated reads return the same value. They compose with
`awaitSupervised` inside supervision, where a latched fatal failure may be
delivered instead, and remain readable after the boundary drained.

| Exit | Completion result | Supervision status |
|---|---|---|
| Finish after an acknowledged drain, with successful cleanup | `Succeeded InboxExit` with the acknowledgement and zero discards | `WorkerStopped` |
| Ordinary stop with successful cleanup, including closing's stop | `Succeeded InboxExit` with its discard count and no acknowledgement | `WorkerStopped` |
| Handler failure | `Failed` with the handler's exception | Unavailable or fatal, by policy |
| Cleanup failure after a stop | `Failed` with the cleanup evidence | Fatal |
| Cancellation | `Cancelled` | `WorkerStopped` when the owner asked, otherwise by policy |

No `InboxExit` is manufactured for a failure, cancellation, or cleanup failure,
and `WorkerStopped` alone is not read as an ordinary exit.

## Composed examples

### Commands and snapshots

`packages/runtime/test/Test/Runtime/InboxFinish.hs` composes the pieces the way an
application would. A small application-owned command protocol — `Add` and
`Reset` for a counter, with its own `NFData` instance — runs as a scoped inbox
service. The application creates the snapshot and keeps only its
`SnapshotReader`; the service's context owns the `SnapshotPublisher` for its run
and closes it in its release. The handler updates its counter, prepares the new
total, and publishes it, so every publication follows the command it came from.
The application waits for the first publication with `awaitSupervised` over
`awaitSnapshot`, sends more commands, and finishes the service. After finish and
the supervision boundary's teardown, `readSnapshot` still returns the last
value, and `awaitSnapshot` from that value's cursor reports `EndOfStream`.

### Bounded turns

`packages/foundation/test/Test/Foundation/Messaging/Turns.hs` writes a custom multi-input loop from the
public channel and snapshot operations, with no engine scheduling or batching
interface. Each input has an explicit, finite per-turn budget — two
opportunities for commands, one for events, one for a settings snapshot — and
one opportunity is one non-waiting `receive`, or one `awaitSnapshot` tried under
`orElse`. A dequeued entry costs its opportunity whether the loop handles,
rejects, or discards it, and an input with nothing ready ends its turn early.
Under traffic that keeps every input ready — commands alone could fill every
turn — each turn still serves every input, and the channel counters show
exactly one dequeue per spent opportunity.

## State

| State | Owner | Readers and writers | Thread | Lifetime and reset |
|---|---|---|---|---|
| Prepared payload | Whoever holds the handle | Written once by `prepare`; read by any holder through `preparedValue` | Prepared on the producer's thread; read on any thread | As long as it is referenced; immutable, never reset, no disposal |
| Channel entries | The channel, controlled by the `ChannelControl` holder | Sends append; receives remove the oldest; abort drops every entry | Any thread holding the endpoint | From admission until received or discarded; an unreferenced channel is collected with any entries it holds |
| Channel terminal flag | The channel, controlled by the `ChannelControl` holder | Close and abort write; every send and receive reads | Any thread holding the endpoint | Open until the first close or abort; abort may replace close; never reopens |
| Channel counters | The channel, controlled by the `ChannelControl` holder | Accepting sends, receives, and abort write; `channelStatistics` reads | Any thread holding the endpoint | Cumulative for the channel's life; never reset and never wrap |
| Snapshot value | The snapshot, controlled by the `SnapshotPublisher` holder | `publish` writes; `readSnapshot` and `awaitSnapshot` read | Any thread holding an endpoint | From construction until replaced; kept after close; lives while referenced |
| Snapshot revision | The snapshot, controlled by the `SnapshotPublisher` holder | Written with the value by `publish`; read with it | Any thread holding an endpoint | Zero at construction; advanced only by publication; never reset, never wraps |
| Snapshot terminal flag | The snapshot, controlled by the `SnapshotPublisher` holder | `closeSnapshot` writes; `publish` and `awaitSnapshot` read | Any thread holding an endpoint | Open until the first close; never reopens |
| Reader's last revision | The reader holding the cursor | That reader alone, by keeping or replacing its cursor | The reader's thread | As long as the reader keeps the cursor; the snapshot stores no copy and no registry |
| Service handoff | The inbox service's start | The worker's startup writes it once, as its last step; the starter reads it once, without waiting, after `WorkerStarted` | Worker writes; application thread reads | One start; never cleared; dropped with the start |
| Service inbox | The inbox service's worker, through its startup scope | Producers send through the `Sender`; the dispatch loop receives; the run and the abort release abort | Producers' threads; the worker | The worker's startup scope; aborted on every exit, never reopened |
| Drain acknowledgement | The inbox service's start | The dispatch decision that observes the normally closed, empty inbox writes it once; finish, the exit record, and `inboxAcknowledgedDrain` read it | Worker writes; any thread reads, in STM | One start; written at most once, never cleared, kept after completion and after a later stop or cancellation |
| Inbox exit record | The inbox service's worker | The run returns it once after the stop's abort; any number of completion readers | Worker writes; any thread reads, in STM | Published with the completion; immutable, never consumed or reset |

The payload module owns no other state and no STM operation. Each channel owns
only its own three rows; nothing is shared between channels, and there is no
disposal step. Each snapshot owns its value, revision, and terminal flag, and
each reader owns its own last revision; nothing is shared between snapshots.

## Module authoring

The module follows the [module authoring guide](logging.md#module-authoring-guide):
it takes no logger and emits no diagnostics, because preparation reports a
failure only by propagating it to the producer, whose handling boundary reports
it once. It imposes no error type, keeps its representation behind an opaque
handle, and documents its one state row above.

The channel module follows the same guide. It takes no logger: `Full`,
`Closed`, `Empty`, and a termination are results the caller handles, not
diagnostics, and its one failure, a rejected capacity, propagates to the owner
with its engine origin. Its representation stays behind three abstract
endpoints, and its state rows are documented above.

The snapshot module follows the same guide. It takes no logger:
`PublicationClosed` and `EndOfStream` are results the caller handles, and its
one failure, a cursor mismatch, propagates to the misusing caller with its
engine origin. Its representation stays behind abstract endpoints,
observations, and cursors, and its state rows are documented above.

The inbox adapter follows the same guide. It takes no logger: optional
unavailability is warned about once by supervision, and its one failure of its
own, `InboxInvariantViolated`, propagates with its engine origin. Finish
outcomes are results the owner handles, not diagnostics. Its handle,
definition, exit record, and drain acknowledgement are abstract, and its state
rows are documented above.

## Verification

`cabal test hetoimasia-foundation:foundation-tests --test-show-details=direct --test-options='--match Messaging'`
runs the `Messaging` examples from
`packages/foundation/test/Test/Foundation/Messaging/Spec.hs` and
`packages/foundation/test/Test/Foundation/Messaging/Opacity.hs`. Evaluation is observed through side
effects in each payload's own `NFData` instance, and cancellation is coordinated
with `MVar`s, never with a sleep. They cover:

- a throwing thunk nested in a lazy list inside a strict record, which survives
  weak head normal form and is raised by `prepare` with its own type;
- a prepared payload read back unchanged, re-read, and relayed through an
  `MVar` without its `NFData` instance running again, against the control of a
  second preparation that does run it;
- a typed engine failure raised during preparation inside
  `withOperationContext`, keeping its type, engine origin, and the boundary's
  context;
- a native `IOException` raised the same way, keeping its type and message, a
  native cause, and the boundary's context;
- a preparation cancelled with `killThread` while its instance is known to be
  running, ending by `ThreadKilled` with no evidence added;
- external clients compiled against the built package: the constructor, record
  update, wrapping `coerce`, re-typing `coerce` between two client newtypes
  (beside an accepted control coercion between the newtypes themselves),
  `fmap`, and `traverse` each rejected for its named cause, and a linked client
  that prepares, reads, forwards through unconstrained polymorphic functions,
  and sees a nested failure raised by `prepare`.

The channel examples live in
`packages/foundation/test/Test/Foundation/Messaging/Channel.hs`, with their
external clients in `packages/foundation/test/Test/Foundation/Messaging/Opacity.hs`.
Blocked waits are detected with `awaitBlockedOnSTM` and producers start from a
gate; no example sleeps or asserts an order only timing could decide. They
cover:

- zero, negative, and above-maximum capacities rejected with
  `ChannelCapacityRejected`, the `foundation.messaging` engine origin, the
  capacity identifier, and the caller's site, beside the accepted capacities one
  and `maximumCapacity`;
- FIFO order across alternating producers' endpoints, and each of three
  concurrent producers' entries received in its own order;
- `Accepted` up to capacity, then `Full` with statistics unchanged and the
  refused payload still sendable; `Closed` over `Full` after close and after
  abort, for both sends;
- drain after a repeated close in order, then `Drained` from both receives;
- abort of an empty channel, abort strengthening a close without recalling a
  received entry, a repeated abort returning zero with counters unchanged, and a
  later close leaving the abort in place;
- blocked `awaitSend` and `awaitReceive` woken by close and by abort with the
  terminal result, a blocked send released by one receive, and a blocked receive
  released by one send;
- conservation and monotone high-water checked after rollback, contention,
  failed admission, drain before and after close, and abort; an admission rolled
  back by `orElse`, a thrown transaction, and `catchSTM` never delivered;
- a payload whose `NFData` instance counts evaluations received from one channel
  and sent to another with the count unchanged;
- blocked waits composed with a real worker's `awaitStopRequest` through
  `orElse`, leaving through the stop branch with the channel unchanged;
- external clients: receiving from a `Sender`, closing from a `Sender` or a
  `Receiver`, naming the `Sender` constructor, and record update of
  `channelSender` each rejected for its named cause, and a linked client using
  every send, receive, control, and statistics operation.

The snapshot examples live in
`packages/foundation/test/Test/Foundation/Messaging/Snapshot.hs`, with their
external clients in `packages/foundation/test/Test/Foundation/Messaging/Opacity.hs`. Blocked waits
are detected with `awaitBlockedOnSTM`, concurrent readers start from a gate, and
a read that must not wait is run under `orElse`, which only a `retry` can
select. They cover:

- the initial value observed at revision zero before any publication, with a
  waiting read from its cursor retrying;
- an equal value, and the same handle, each advancing the revision;
- two readers blocked on the same cursor each receiving the newest publication,
  the original cursor still seeing it, and a reader that missed intermediate
  publications receiving only the newest;
- waiting and current readers checking every observation against 500
  concurrent publications, where publication n carries value n, for a value
  paired with another publication's revision;
- a publication rolled back by an exception and by `retry` under `orElse`
  leaving value and revision unchanged;
- an observed payload whose `NFData` instance counts evaluations published to
  another snapshot with the count unchanged;
- after close, an unseen final publication delivered before `EndOfStream`, the
  final value still read, and publishing reporting `PublicationClosed` without
  change, again after a repeated close;
- close before any publication, and repeated, ending a waiter holding the
  initial cursor while reads keep the initial value and cursor;
- a blocked waiting read woken by close with `EndOfStream`;
- a cursor from another snapshot at the same revision raising
  `ForeignSnapshotCursor` with its engine origin, identifier, and the caller's
  site, without waiting, against an open target, a closed target, and the
  replacement of a closed earlier lifetime;
- a blocked waiting read composed with a real worker's `awaitStopRequest`,
  leaving through the stop branch;
- external clients: forging a cursor or an observation, record update of
  `observedValue` or `snapshotReader`, and publishing or closing through a
  `SnapshotReader` each rejected for its named cause, and a linked client using
  every publish, read, wait, and close operation, the observation readers, and
  the cursor-mismatch failure.

The supervised waits on channels and snapshots exercise the runtime's
supervision, so the runtime package's suite registers them under `Runtime`, in
`packages/runtime/test/Test/Runtime/Messaging.hs`, as `Channel composition` and
`Snapshot composition`. Worker outcomes are read raw before a supervised wait
begins. They cover real `withSupervision` and `awaitSupervised`:

- an optional worker's published failure settled, and its warning written while
  the entry was still queued or the send not yet admitted, before a channel
  receive or send commits exactly once; and a required worker's published
  failure rethrown with the receive or send never committed;
- an optional worker's published failure settled, and its warning written,
  before a ready snapshot waiting read commits; and a required worker's
  published failure rethrown with the read never committed.

The inbox adapter's examples live in `hetoimasia-runtime:runtime-tests` under
`Runtime`, in `packages/runtime/test/Test/Runtime/Inbox.hs`, with their external
clients in `packages/runtime/test/Test/Runtime/Opacity.hs`; `--match Runtime`
selects them with the rest of that suite, and
`--match 'Inbox'` selects only them. Each uses real `withSupervision`,
`startInboxService`, and `awaitSupervised` over a collecting logging lifetime.
A component context's traced release records whether the inbox still admits a
message through the returned endpoint. Handlers signal entry through `MVar`s
and wait on gates, and closing's drain is detected with `awaitBlockedOnSTM`; no
example sleeps. They cover:

- a required context failure, a rejected start, an optional recognized context
  failure, and owner cancellation during construction, each exposing no
  endpoint, with the context released and nothing constructed for the
  rejection;
- a start returning a usable endpoint, and a service stopped straight after
  acknowledgement closing its inbox before teardown;
- an ordinary stop and closing's stop each aborting a full backlog before
  component release, retaining `Succeeded InboxExit` with the discard count
  across repeated reads;
- a stop winning over a simultaneously ready message, and an in-flight message
  finishing once without being retried;
- a handler exception with messages queued, which are never handled: fatal with
  its type and context for a required service and for an unrecognized optional
  one, unavailable with one warning for a recognized optional one, and an
  explicitly recovering handler letting the next message be handled;
- a cancellation delivered after the handoff returned and before any message
  was dispatched — once the worker parks in its first receive — closing the
  returned endpoint before teardown and keeping its `Cancelled` completion,
  judged an unexpected termination, with no handler run;
- an in-flight cancellation and a cleanup failure keeping their `Cancelled` and
  `Failed` completions with no exit record;
- a borrowed dependency usable by the handler and by component release, and
  released only after the drain;
- external clients: record update of `inboxSender`, naming the `InboxService`,
  `InboxDefinition`, `InboxExit`, or `DrainAcknowledgement` constructor, taking
  a service from `InboxStartUnavailable`, and record update of
  `inboxDiscarded`, `inboxDrain`, or `drainHandled` each rejected for its named
  cause; a linked client that starts a service, sends, stops it, and prints its
  discard count, unchanged from the stop-only slice; and a linked client that
  finishes a service and prints both exit-record accessors and the handle's
  acknowledgement.

The graceful finish examples live in `packages/runtime/test/Test/Runtime/InboxFinish.hs`,
also under `Runtime`; `--match 'Inbox finish'` selects only them. They use the
same real supervision, fixtures, and coordination, plus a classifier that waits
on a gate where an example must hold the finish's supervised wait between two
outcomes. They cover:

- a finish requested with a handler in flight and three messages queued: every
  message handled once in FIFO order, no acknowledgement inside the last
  handler, then `InboxFinished` with zero discards and an acknowledgement after
  four messages, a run exit recording the stop request, `WorkerStopped` after
  cleanup, a later send `Closed`, and a repeated finish returning the same;
- a stop requested before the drain, a cancellation committed while the last
  message is in flight, and a stop racing the final closed, empty observation,
  each `InboxUnfinished` with no acknowledgement, the ordinary stop keeping its
  real discard count;
- a recognized optional handler failure during finish returned as unavailable
  with one warning and no acknowledgement; a required failure and an
  unrecognized optional failure propagating with their type and handler
  annotation; and a cleanup failure after the drain propagating with its
  cleanup evidence while the acknowledgement stays readable;
- a job completing and an optional worker becoming unavailable while finish
  waits, each settled, followed by `InboxFinished`;
- a cancellation delivered after the acknowledgement and before the finish's
  stop, while the finish is held settling another worker: judged by the
  service's policy, never a successful finish, with the acknowledgement and
  the `Cancelled` completion retained across a repeated finish and repeated
  reads;
- owner cancellation during finish, with a borrowed dependency usable by the
  cancelled handler and the component release and released only afterwards;
- the commands-and-snapshots example above.

The bounded-turn example lives in
`packages/foundation/test/Test/Foundation/Messaging/Turns.hs`, under
`Messaging`; `--match 'Bounded turns'` selects it.

The validation catalog covers the foundation examples through the floor group
`test.foundation`, and the supervised waits and inbox examples through the floor
group `test.runtime`; see
[validation.md](validation.md).
