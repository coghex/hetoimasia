# Messaging

The contract of the foundation's messaging modules and the runtime's inbox
adapter:

- `Hetoimasia.Foundation.Messaging.Payload`: the prepared payload every
  transport accepts;
- `Hetoimasia.Foundation.Messaging.Channel`: the bounded FIFO channel;
- `Hetoimasia.Foundation.Messaging.Snapshot`: the latest-value snapshot read
  through checked cursors;
- `Hetoimasia.Runtime.Inbox`: the optional adapter that runs one supervised
  service with one inbox.

Signatures are in the export lists. The transactional failure helpers are in
[failures.md](failures.md).

## Evaluation guarantees

`prepare ∷ NFData a ⇒ a → IO (Prepared a)` is the only way to obtain a
`Prepared a`. `preparedValue` is a pure projection that evaluates nothing, so
code that reads or forwards payloads needs no `NFData` constraint.

- **Normal form before publication.** `prepare` evaluates through the type's
  `NFData` instance on the calling thread and returns only afterwards. A
  failure nested anywhere the instance reaches fails the producer and never
  reaches a reader.
- **Once.** Reading and forwarding force nothing further. An unchanged payload
  is forwarded as the same handle.
- **The instance is the component's.** Normal form means exactly what the
  payload type's `NFData` instance forces. An instance that skips a field
  leaves it lazy, and no transport can detect that.
- **Producer-side cost** is the purpose, not a side effect.
- **No resource scope.** A closure or borrowed native handle inside a payload
  is valid only inside the scope that owns it. Preparing, sending or
  publishing it does not extend that scope.
- **No bypass.** There is no weak-head or unprepared route. A transformed
  value is prepared again.

A preparation failure propagates with its original type and annotations and
returns no handle; `prepare` catches, retries and logs nothing. Cancellation
during preparation propagates as cancellation.

`Prepared`, every endpoint, cursor and observation is abstract with a nominal
role, read through functions, with no `Functor` instance, so a client can
neither build one nor change or re-type one it holds.

## Bounded FIFO channels

`newChannel capacity` returns the owner's `ChannelControl`, which hands out the
`Sender` and `Receiver` and alone can close, abort or read statistics. A
sender can only send and a receiver only receive. Any number of threads may
hold an endpoint; one logical consumer per channel is the owner's convention,
not enforced.

**Capacity.** The owner chooses it. There is no clamping, no zero-capacity
rendezvous and no default. A capacity below one or above `maximumCapacity`
throws `ChannelCapacityRejected` in `IO` (component `foundation.messaging`,
operation `new-channel`) and no channel exists.

| Operation | Waits | Results |
|---|---|---|
| `send` | never | `Accepted`, `Full`, or `Closed` (which takes precedence over `Full`) |
| `awaitSend` | only while open and full | `Admitted`, `AdmissionClosed` |
| `receive` | never | `Received p`, `Empty`, `Terminated Drained`, `Terminated Aborted` |
| `awaitReceive` | only while open and empty | `Delivered p`, `Ended t` |

`Full` and `Closed` change nothing and the caller keeps its payload. A sender
cannot tell a close from an abort.

**Order.** Entries are received in the order their admissions committed. Each
producer's own entries keep its order. No fairness among producers, batching
or coalescing is promised.

| | `closeChannel` | `abortChannel` |
|---|---|---|
| Admission | Ends | Ends |
| Backlog | Kept and received in order | Dropped; returns the number discarded |
| A receive once nothing is queued | `Drained` | `Aborted` |
| After the other | Never weakens an abort | Strengthens a close |
| Repeated | No effect | Returns zero |

Both wake blocked waiters. A channel never reopens. Neither executes `retry`
or waits, so both are safe inside a release; abort does not traverse or force
the backlog.

**Where waiting is safe.** Compose a wait with the owner's own wake:

- on the application thread, inside
  [`awaitSupervised`](supervision.md#checkpoints-and-supervised-waits):
  `awaitSupervised control (awaitReceive receiver)`;
- on a worker, with its stop request:
  ``atomically ((Right <$> awaitReceive receiver) `orElse` (Left <$> awaitStopRequest token))``.

A bare `atomically (awaitReceive receiver)` is unsupervised on the application
thread and keeps a worker's drain waiting. Never wait on a channel inside a
release.

**Statistics.** `channelStatistics` reads capacity, depth, high-water,
accepted, dequeued and discarded in one transaction. Every committed state
satisfies `accepted = dequeued + discarded + depth`. Counters are cumulative
`Natural`s that never reset.

**Transactions.** No channel transaction evaluates a payload, reads a clock,
logs, runs a callback or raises a typed failure.

## Latest-value snapshots

A snapshot holds one latest value, for state a reader needs only the newest
of. A stream where every entry matters belongs in a channel. A snapshot does
not relate separate streams.

`newSnapshot initial` returns the `SnapshotPublisher`, which hands out the
`SnapshotReader`. A reader can read and wait, not publish or close. Every
`newSnapshot` has a fresh identity: nothing resets or reopens a snapshot. One
logical publisher per snapshot is the owner's convention.

**Publication.** `publish` replaces value and revision in one write and never
waits. The initial value has revision zero; every committed publication
advances it by one, including publication of an equal value. On a closed
snapshot it returns `PublicationClosed` and changes nothing.

**Observations and cursors.** `readSnapshot` returns an `Observation`: the
prepared payload and a `SnapshotCursor` naming this snapshot and that
revision. The cursor is the reader's own last revision; the snapshot keeps no
per-reader state and no history.

`awaitSnapshot reader cursor`:

| Snapshot | Newer than the cursor | Result |
|---|---|---|
| Open or closed | Yes | `Updated`, with the newest publication and its cursor |
| Closed | No | `EndOfStream` |
| Open | No | waits |

A reader that missed intermediate publications receives only the newest.

**Cursor mismatch.** A cursor from a different snapshot is misuse:
`awaitSnapshot` raises `ForeignSnapshotCursor` inside the transaction
(operation `await-snapshot`). The identity check comes first, so it fails at
once whatever the target's state, including for a cursor from a closed earlier
lifetime used with its replacement.

**Close.** `closeSnapshot` is idempotent, never retries, and is safe inside a
release. It keeps the last value and cursor for reads, does not advance the
revision, and wakes waiters. A waiter with an older cursor receives the final
publication first and `EndOfStream` next.

Waiting is safe under the same two compositions as a channel. No snapshot
transaction evaluates a payload, reads a clock, logs or runs a callback.

## Supervised inbox services

`Hetoimasia.Runtime.Inbox` starts one supervised `Service` through
`startSupervised`, with the owner's disposition, warning component and
classifier. It is not a second runner, supervisor, restart policy or
scheduler. Channels work without it.

**Roles.** The application holds the `InboxService` handle and gives producers
only its `Sender`. The worker receives its own `StopToken` and the context its
startup built, never the application's `RuntimeControl`.

**Startup order**, on the worker's thread:

1. the component context and its resources are constructed;
2. the inbox is allocated, with its abort registered as the innermost release,
   so reverse scope order ends admission and drops the backlog before any
   component resource is released;
3. the inbox's control endpoint is written into a private one-shot handoff.

Only then does the worker acknowledge startup.

| Start | Result | Component |
|---|---|---|
| Registration closed | `InboxStartRejected` | Nothing runs |
| Recognized failure of an optional service | `InboxStartUnavailable`, with its one warning | Released |
| Required, unrecognized or cleanup failure | Propagates as from `startSupervised` | Released |
| Owner cancellation of the start | Propagates after the worker drained | Released |

None of these exposes an endpoint.

**Dispatch.** One message at a time. The stop check, the receive and the
recording of a drain acknowledgement are one transaction, in which a requested
stop wins over a ready message. The handler runs outside `STM`. A message a
committed receive selected is in flight: its handler runs to its end and is
never retried. A stuck handler keeps the worker and its dependencies alive
under the group's drain; there is no deadline or detach.

### Finish versus stop

- **Ordinary stop** (`stopInboxService`, or closing's stop when the
  application action returns): the in-flight message finishes; the accepted
  backlog is aborted and counted as discarded, never processed.
- **Graceful finish** (`finishInboxService control service`, on the
  application thread):
  1. admission closes with a normal close while the worker runs;
  2. the worker handles the in-flight message and then the backlog in order;
  3. the worker acknowledges the drain only in a dispatch decision that
     observed the normally closed, empty inbox. Empty depth alone is never an
     acknowledgement;
  4. the worker then waits for its stop token, keeping its `Service` role;
  5. finish observes the acknowledgement through `awaitSupervised`, stops the
     service and awaits its completion the same way.

Request a finish while the services the handler depends on are still
available, before the application action returns.

A `DrainAcknowledgement` is written once and records `drainHandled`, the
number of messages whose handlers had returned. A later stop or cancellation
leaves it in place.

| Finish outcome | When |
|---|---|
| `InboxFinished exit` | A genuine acknowledgement, then a `Succeeded` exit with zero discards and `WorkerStopped` |
| `InboxUnfinished drain completion` | A stop or cancellation won before the drain, or a cancellation ended the service after it |
| `InboxFinishUnavailable failure` | An optional service failed with a recognized failure |

A required or unrecognized failure, and any retained cleanup failure,
propagates from `finishInboxService`. A cancellation after an acknowledged
drain is never a successful finish. Repeated finishes, stops and completion
reads re-run no handler.

### Exits

Every exit from the service aborts the inbox before the component's resources
are released and before the completion is published. That abort is the inbox
allocation's release: it runs uninterruptibly and waits for nothing.

A synchronous exception escaping the handler ends dispatch; the next queued
message is not handled, and supervision decides by policy. There is no
per-message isolation, skip or replay: a handler that can recover does so
before the exception escapes ([recovery.md](recovery.md)).

| Exit | Completion | Supervision status |
|---|---|---|
| Finish after an acknowledged drain | `Succeeded InboxExit` with the acknowledgement and zero discards | `WorkerStopped` |
| Ordinary stop | `Succeeded InboxExit` with its discard count and no acknowledgement | `WorkerStopped` |
| Handler failure | `Failed` with the handler's exception | Unavailable or fatal, by policy |
| Cleanup failure after a stop | `Failed` with the cleanup evidence | Fatal |
| Cancellation | `Cancelled` | `WorkerStopped` when the owner asked, otherwise by policy |

No `InboxExit` is manufactured for a failure or cancellation, and
`WorkerStopped` alone is not an ordinary exit. `inboxDiscarded` is the
channel's cumulative discard count. Completion reads do not consume.

## Module structure

| Module | Visibility | Owns |
|---|---|---|
| `Messaging.Payload` | exposed | `Prepared`, `prepare`, `preparedValue` |
| `Messaging.Component` | hidden | `messagingComponent`, `foundation.messaging` |
| `Messaging.Channel.Types` | hidden | The channel representation, endpoints and result types |
| `Messaging.Channel` | exposed | Every channel operation |
| `Messaging.Snapshot.Types` | hidden | The snapshot representation, endpoints, cursor and observation |
| `Messaging.Snapshot` | exposed | Every snapshot operation |

Dependencies run one way: each `Types` module imports `Payload` only, and
`Snapshot` imports nothing from the channel modules. The `Types` modules define
state but create and change none of it. None of these modules takes a logger:
`Full`, `Closed`, `Empty`, `PublicationClosed` and `EndOfStream` are results,
and the three failures (`ChannelCapacityRejected`, `ForeignSnapshotCursor`,
`InboxInvariantViolated`) propagate with their engine origin.

## State

| State | Owner | Writers and readers | Lifetime |
|---|---|---|---|
| Prepared payload | Whoever holds the handle | Written once by `prepare`; any holder reads | While referenced; immutable |
| Channel entries, terminal flag, counters | The channel, through its `ChannelControl` holder | Sends, receives, close and abort, from any thread holding the endpoint | Entries until received or discarded; the flag never reopens; counters never reset |
| Snapshot value, revision, terminal flag | The snapshot, through its `SnapshotPublisher` holder | `publish` and `closeSnapshot` write; readers read | Value kept after close; never reopens |
| Reader's last revision | The reader holding the cursor | That reader | The snapshot stores no copy |
| Service handoff | The inbox service's start | Worker writes once; the starter reads once | One start |
| Service inbox | The worker, through its startup scope | Producers send; the dispatch loop receives | Aborted on every exit |
| Drain acknowledgement, exit record | The inbox service's start and worker | Written at most once; any thread reads | Kept after completion |

## Verification

```bash
cabal test hetoimasia-foundation:foundation-tests --test-show-details=direct --test-options='--match Messaging'
cabal test hetoimasia-runtime:runtime-tests --test-show-details=direct --test-options='--match Inbox'
```

Two composed examples are worth copying:
`packages/runtime/test/Test/Runtime/InboxFinish.hs` runs a command service
that publishes a snapshot after each command and is then finished, and
`packages/foundation/test/Test/Foundation/Messaging/Turns.hs` writes a
bounded multi-input loop with a finite per-turn budget for each input from the
public channel and snapshot operations alone.
