# Messaging

Current behavior of `Hetoimasia.Foundation.Messaging.Payload`, the prepared
payload boundary every messaging transport accepts, and of
`Hetoimasia.Foundation.Messaging.Channel`, the bounded FIFO channel that carries
prepared payloads. The accepted contract is epic #73; this document describes
what the code does today.

Scope: preparing a payload to normal form on the producer's thread, reading and
forwarding a prepared payload, what a preparation failure does, and what a
client cannot do to a prepared handle; then creating a bounded channel, sending
and receiving, closing and aborting it, its counters, where waiting on it is
safe, and which endpoint may do what. Snapshot publication and the runtime inbox
adapter arrive in later slices of the same arc and are not described here. The
transactional failure companion is described in
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

## State

| State | Owner | Readers and writers | Thread | Lifetime and reset |
|---|---|---|---|---|
| Prepared payload | Whoever holds the handle | Written once by `prepare`; read by any holder through `preparedValue` | Prepared on the producer's thread; read on any thread | As long as it is referenced; immutable, never reset, no disposal |
| Channel entries | The channel, controlled by the `ChannelControl` holder | Sends append; receives remove the oldest; abort drops every entry | Any thread holding the endpoint | From admission until received or discarded; an unreferenced channel is collected with any entries it holds |
| Channel terminal flag | The channel, controlled by the `ChannelControl` holder | Close and abort write; every send and receive reads | Any thread holding the endpoint | Open until the first close or abort; abort may replace close; never reopens |
| Channel counters | The channel, controlled by the `ChannelControl` holder | Accepting sends, receives, and abort write; `channelStatistics` reads | Any thread holding the endpoint | Cumulative for the channel's life; never reset and never wrap |

The payload module owns no other state and no STM operation. Each channel owns
only its own three rows; nothing is shared between channels, and there is no
disposal step.

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

## Verification

`cabal test hetoimasia-tests --test-show-details=direct --test-options='--match Messaging'`
runs the `Messaging` examples from `test/Test/Engine/Messaging/Spec.hs` and
`test/Test/Engine/Messaging/Opacity.hs`. Evaluation is observed through side
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

The channel examples live in `test/Test/Engine/Messaging/Channel.hs`, with
their external clients in `test/Test/Engine/Messaging/Opacity.hs`. Blocked waits
are detected with `awaitBlockedOnSTM`, producers start from a gate, and worker
outcomes are read raw before a supervised wait begins; no example sleeps or
asserts an order only timing could decide. They cover:

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
- real `withSupervision` and `awaitSupervised`: an optional worker's published
  failure settled, and its warning written while the entry was still queued or
  the send not yet admitted, before the receive or send commits exactly once;
  and a required worker's published failure rethrown with the receive or send
  never committed;
- external clients: receiving from a `Sender`, closing from a `Sender` or a
  `Receiver`, naming the `Sender` constructor, and record update of
  `channelSender` each rejected for its named cause, and a linked client using
  every send, receive, control, and statistics operation.

The validation catalog covers them through the floor group `test.engine`; see
[validation.md](validation.md).
