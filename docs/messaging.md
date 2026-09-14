# Messaging

Current behavior of `Hetoimasia.Foundation.Messaging.Payload`, the prepared
payload boundary every later messaging transport accepts. The accepted contract
is epic #73; this document describes what the code does today.

Scope: preparing a payload to normal form on the producer's thread, reading and
forwarding a prepared payload, what a preparation failure does, and what a
client cannot do to a prepared handle. Bounded FIFO channels, snapshot
publication, the transactional failure companion, and the runtime inbox adapter
arrive in later slices of the same arc and are not described here.

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
forward ∷ Prepared a → Channel a → IO ()   -- a later transport, for example
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

## State

| State | Owner | Readers and writers | Thread | Lifetime and reset |
|---|---|---|---|---|
| Prepared payload | Whoever holds the handle | Written once by `prepare`; read by any holder through `preparedValue` | Prepared on the producer's thread; read on any thread | As long as it is referenced; immutable, never reset, no disposal |

The module owns no other state. It adds no queue, snapshot, or transport state
and no STM operation.

## Module authoring

The module follows the [module authoring guide](logging.md#module-authoring-guide):
it takes no logger and emits no diagnostics, because preparation reports a
failure only by propagating it to the producer, whose handling boundary reports
it once. It imposes no error type, keeps its representation behind an opaque
handle, and documents its one state row above.

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

The validation catalog covers them through the floor group `test.engine`; see
[validation.md](validation.md).
