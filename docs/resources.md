# Resources

Current behavior of `Hetoimasia.Foundation.Resource`, the public CPU resource
scope. The approved policy and its alternatives live in
[the resource ownership design](resource_ownership_design.md) (D-1, D-2, and
D-6 through D-8); this document describes what the code does today.

Scope: the scope primitive, ownership and borrowing of the scoped value, the
argument order, the failure table, the mask discipline, what the release
guarantee does and does not cover, how to inspect and how not to discard the
secondary failures a scope retains, the staged constructor an owner built from
several parts is assembled with, the continuation facade those scopes are
composed in, the scoped collection whose members are retired independently,
the scoped constructor that selects a live component among alternatives, the
component convention, and how an application composes them with logging.

Anything involving Vulkan, GPU completion, retirement queues, or ownership
transfer is not part of it yet, and early release of an individual resource
exists only through [the scoped collection](#scoped-resource-collections). This module imports no
logger, runtime environment, graphics, or scripting module, and owns no
application state; [Application lifecycle](#application-lifecycle) describes
what the application does with it, and belongs to the application rather than to
the module.

## Public interface

```haskell
withResource         ∷        IO a → (a → IO ()) → (a → IO r) → IO r
withResourceLabelled ∷ Text → IO a → (a → IO ()) → (a → IO r) → IO r
```

The acquisition comes first and the release second, matching
`Control.Exception.bracket`. Synarchy's release-first order is not carried
over and no compatibility with it is promised.

`withResource` records cleanup failures under a default label.
`withResourceLabelled` takes the operation's label as its first argument, so
evidence retained from several nested scopes says which scope each entry came
from. The two are otherwise identical, and everything below applies to both.

This is not an alias for `bracket`. When the body and the release both fail,
`bracket` reports one of them and discards the other; this scope preserves the
body's failure and retains every cleanup failure beside it.

## Ownership and borrowing

The scope owns the acquired value for exactly the duration of the body. The
body borrows it: the release runs when the body returns or throws, so the value
is already released by the time the scope's caller sees a result.

Do not return the scoped value out of the body, and do not return anything
whose validity depends on it — a handle, a pointer, a lazily read `String`, a
record holding any of those. The type does not prevent it; this contract does.
Return ordinary, fully evaluated results instead.

There is no escape hatch and no transfer operation, and a scope has no way to
release one of its own allocations early. A resource whose lifetime must end
before its scope does, independently of its neighbours, belongs to a
[scoped resource collection](#scoped-resource-collections). A value whose
lifetime must outlast its scope belongs to an owner that has not been designed
yet, not to a scope that returns it.

## The failure table

| Body | Release | Outcome |
|---|---|---|
| Succeeds | Succeeds | The body's result is returned |
| Fails | Succeeds | The original exception propagates unchanged |
| Succeeds | Fails | The scope fails with the release's exception; the body's result is discarded |
| Fails | Fails | The body's failure propagates and every cleanup failure is retained beside it |

Details the table does not spell out:

- A failed acquisition propagates and runs **no** release, because no value
  exists to release. The body does not run either.
- Cancellation is a failure. A body that is cancelled is a body that failed,
  and its release runs.
- The propagating exception keeps its own type, value, and attached context. A
  typed catch above the scope still recognizes it.
- Successful cleanup is never reported for a body that threw or was cancelled.
  A scope with nothing to retain attaches nothing.
- When only the release fails, its exception is primary **and** is retained as
  one labelled entry, so inspection reports it beside any failure an enclosing
  scope adds later.
- Nested scopes append to the evidence they receive and never rebuild the
  primary exception. Entries are ordered by when they were observed during
  unwinding: innermost first.

## Mask discipline

Acquisition runs under `mask`, as `bracket` does, so a blocking acquisition
stays cancellable unless the caller already imposed an uninterruptible mask.
The scope's own handler is installed while still masked, so nothing runs
unprotected between a successful acquisition and its cleanup protection.

The body runs with the caller's masking state restored. An inner scope that
completes normally therefore hands control back to an enclosing body that is
cancellable again: a cancellation requested at that point is delivered there,
and the enclosing scope's release then runs under the protection below.

Each release runs under `uninterruptibleMask_`, and the orchestration around it
stays masked, with no interruptible gap between the releases of one unwind. So
an asynchronous exception aimed at the thread from elsewhere is not delivered
until that release and the remaining releases of the same unwind have finished.
The request is not swallowed: it stays pending until masking permits delivery.

An exception a release raises **itself** is a cleanup failure under the table
above, not an interruption — including one whose type belongs to the
asynchronous-exception hierarchy, such as `throwIO ThreadKilled`. It does not
stop the remaining releases from being attempted.

### What a release may do

A release must have a controlled blocking duration. This is the condition
GHC's own documentation sets for
[`uninterruptibleMask`](https://hackage.haskell.org/package/base-4.21.0.0/docs/Control-Exception.html#v:uninterruptibleMask),
and it is the caller's obligation to establish for the actual operation and its
synchronization. The names `close`, `free`, and `destroy` are not proof.

Closing an exclusively owned file handle and freeing host memory are
candidates. **No fence, queue, or device wait belongs inside a release**, even
with a timeout: a timeout establishes neither completion nor permission to
destroy anything. A release that blocks indefinitely hangs its thread
uninterruptibly, and no timeout inside the scope can rescue it.

### What the release guarantee covers

Each release registered in a scope is attempted exactly once per scope exit,
provided the releases before it return or throw within the contract above. A
release that throws has been attempted, not completed, and is never retried
automatically.

It does not cover:

- **Process termination.** Nothing runs after the process is gone: a signal
  that is not handled, `exitWith` from another thread unwinding past the scope
  in a way the runtime does not survive, or a hard abort.
- **A release that never returns.** The guarantee is that the release is
  invoked, not that it finishes.
- **GPU completion.** This arc establishes CPU scope exit only. A wait placed
  in the body protects nothing when the body throws or is cancelled before
  reaching it. Establishing completion on exceptional exits belongs to the
  future backend contract, and must not be solved by making a release
  interruptible.

## Composite construction

```haskell
data Assembly a          -- Functor, Applicative, Monad
data ReleaseRank

releaseRank   ∷ Int → ReleaseRank
acquirePart   ∷ Text → ReleaseRank → IO p → (p → IO ()) → Assembly p
restoredStep  ∷ IO a → Assembly a
withComposite ∷ Assembly a → (a → IO r) → IO r
```

A composite owner acquires several parts in sequence, may fail between any two
of them, and must release them in an order its own API dictates. One
`withResource` per part cannot express that: it releases in reverse allocation
order, and a part acquired inside another part's body cannot outlive it.

`withComposite` is `withResource` for that owner. An `Assembly` is the
construction, written in `do` notation so a later stage may use what an earlier
one produced:

```haskell
allocation ∷ Device → Assembly Allocation
allocation device = do
  handle ← acquirePart "handle" (releaseRank 0)
             (createHandle device) (destroyHandle device)
  needs  ← restoredStep (queryRequirements device handle)
  memory ← acquirePart "handle memory" (releaseRank 1)
             (allocateMemory device needs) (freeMemory device)
  restoredStep (bindMemory device handle memory)
  pure (Allocation handle memory)

withComposite (allocation device) $ \owned → use owned
```

### Ownership of partial state

At every moment after an acquisition returns, exactly one authoritative release
covers every part acquired so far. `acquirePart` extends that release; nothing
is unregistered to make room for the extension, and the accumulated release is
taken out of the construction when it runs, so no part is released twice.

A failure before the first acquisition releases nothing. A failure at any later
stage — while evaluating a part's declared label or rank, inside an
acquisition, inside a restored step, or at the final binding or publication
step — releases exactly the parts acquired so far, each exactly once, and
propagates the triggering failure as primary. The body never runs on that path,
so no half-built value is ever observable.

### The staged-protection guarantee

The whole assembly runs under `mask`. An acquisition and the installation of
its rollback are one protected step: installing a rollback cannot block, so
there is no interruptible gap between the two. This is the gap Synarchy's
`allocResource'` left open, and closing it is the point of the constructor.

Masking still permits cancellation at an interruptible operation *inside* an
acquisition, which is deliberate: a blocking acquisition stays cancellable, and
nothing was acquired when it is cancelled there. An acquisition that throws
before returning its handle is responsible for releasing whatever it acquired
internally, exactly as an acquisition passed to `withResource` is.

`restoredStep` runs work that acquires nothing with the caller's masking state
restored, as `withResource` restores it around its body. It is legal only
because every part acquired so far is already covered: a cancellation delivered
inside such a step rolls exactly those parts back. It inherits the caller's
state rather than forcing an unmasked one, so a caller that was already masked
stays masked. A step that acquires something belongs in `acquirePart`.

### When part metadata is evaluated

`acquirePart` takes the part's label and its rank as ordinary arguments, so
either can be a thunk — a rank read out of a table, a label built from a name
the caller assembled. Both are evaluated at the start of that stage, **before**
its acquisition runs, because the authoritative release needs both to order and
to label what it releases and must not be able to fail on either.

A label or rank that throws is therefore an ordinary construction failure at
its own stage, and it behaves exactly like one:

- That stage acquires nothing, so it owns nothing to release and contributes no
  cleanup entry. A rejected stage never needs a fabricated label.
- The stages after it and the body do not run.
- The parts acquired before it are released in the declared order, each exactly
  once, and a throwing release among them does not stop the remaining ones.
  Those failures are retained under their own parts' valid labels.
- The fault is primary because it was raised first, not because it displaced
  anything. A failure already being unwound stays primary: when an enclosing
  scope's body has failed and its release constructs a composite whose metadata
  faults, the body's failure remains primary and the fault arrives as that
  scope's own cleanup failure, with the composite's labelled evidence still
  reachable below it. A stage that fails *before* a later part's metadata would
  have thrown stays primary too, because the stage declaring that metadata
  never runs.

Both are forced exactly as far as the `Part` record forces them, so a total
label and rank behave as they always did and nothing is deep-forced. Evaluating
them at release time instead is the defect this rule exists to prevent: a thunk
that throws once the authoritative release has been taken out of the
construction abandons every acquired part without a release attempt and
replaces the failure being unwound with its own.

### The declared release order

The constructor declares the final release order with `releaseRank`. Lower
ranks are released first, and parts sharing a rank are released in acquisition
order. Both the rollback of a failed construction and the release at the end of
a successful body use that declared order. Computing that order demands every
acquired part's rank, and every one of them was evaluated before that part was
acquired, so ordering the release of an acquired part cannot fail.

The order is a property of the API the parts come from, not of when they were
acquired. A buffer is created before the memory behind it, and the correct
release is destroy the buffer, then free the memory — acquisition order, not
the reverse of it. A scope that always released in reverse would free memory
the buffer still referred to. Nothing about the ranks is tied to acquisition:
the same two stages can declare either order.

### Handoff to the enclosing scope

On success the finished value is lent to the body under the borrowing rules
above, and the declared release runs when that body returns or throws. The
release never becomes a value the caller holds. Each release runs under
`uninterruptibleMask_` and the orchestration between them stays masked, so an
asynchronous exception aimed at the thread from elsewhere is not delivered
until the whole declared order has been attempted.

Cleanup failures obey the failure table. Each is retained under its own part's
label, the remaining releases are still attempted, and a failure that triggered
a rollback stays primary. When the body succeeds and releases fail, the first
cleanup failure becomes the scope's exception and the body's result is
discarded, as for a single resource; every labelled failure is retained beside
it, once, including through an enclosing `withResource`.

### Patterns this constructor replaces

- **Delayed registration.** There is no helper that returns an action which
  installs cleanup when it is later run. Cleanup is installed by the stage that
  acquired the part, before that stage returns.
- **Returned cleanup closures.** A constructor does not hand a caller a manual
  release to invoke. Synarchy's `Image.hs` returned one only after several
  acquisitions, and sequenced two releases so that a throwing first release
  skipped the second.
- **Unregistering rollback before publication.** Nothing is removed and
  reinstalled around the final binding or publication step, so there is no
  window in which a part is acquired but unprotected.
- **A dependency scheduler.** `Assembly` is a sequence, not a graph. A part
  has no early-release token of its own, and there is no way to move a part to
  another live owner. A whole assembly can become one member of a
  [scoped resource collection](#scoped-resource-collections), which releases
  all of its parts together.

## The continuation facade

```haskell
data Scoped a            -- Functor, Applicative, Monad, MonadIO

withScoped     ∷ Scoped a → forall r. (a → IO r) → IO r
allocResource  ∷ IO a → (a → IO ()) → Scoped a
allocComposite ∷ Assembly a → Scoped a
locally        ∷ Scoped a → Scoped a
```

`allocResource` takes the acquisition first and the release second, as
`withResource` and `bracket` do. Synarchy's release-first order is not carried
over, and the primed compatibility helpers have no successor here.

A `Scoped` value is a scope that has not been entered yet. Binding two of them
nests the second inside the first, so each allocation is one line of a `do`
block instead of one more level of callback indentation:

```haskell
stagedUpload ∷ Device → Scoped Upload
stagedUpload device = do
  staging ← allocResource (createStaging device) (destroyStaging device)
  target  ← allocComposite (allocation device)
  size    ← liftIO (measure staging)
  pure (Upload staging target size)

withScoped (stagedUpload device) $ \upload → run upload
```

The facade changes no lifetime. `withScoped (allocResource acquire release)` is
`withResource acquire release`, and `allocComposite` runs its assembly under
the same staged protection `withComposite` gives it. Every row of the failure
table, the mask discipline, and the retained evidence are the primitive's
unchanged: the direct path and the continuation path produce the same primary
exception and the same ordered secondary failures for the same outcomes.

`Scoped` is opaque and `withScoped` is the only runner. There is no way to
resume a scope's continuation, take a scope apart, or install cleanup for a
resource acquired elsewhere. A scope is built with `allocResource`,
`allocComposite`, `locally`, `pure`, `liftIO`, the instances above, and
[`allocComponent`](#component-construction), and is consumed by running it.

That opacity rests on the representation being closed, not on a check made
while a scope runs. `Scoped` wraps its continuation in an unexported
constructor with no record field, so a client outside the package has no name
for the continuation: it cannot write one of its own into a `Scoped`, and it
cannot rewrite the one a scope it was handed already carries. Record
construction and record-update syntax both need a field label in scope, and a
field label is in scope wherever it is exported — which is why the continuation
is not a field and `withScoped` is an ordinary function over the closed type
rather than its selector. `withScoped`'s name and type are unaffected by that:
it is still applied to a scope and a continuation.

Nothing counts entries or refuses a second one at run time; the guarantee is
that the rewrite cannot be expressed, and it is checked when the client is
compiled. `test/Test/Engine/Resources/Opacity.hs` holds it there, compiling
clients against the built package: a client that replaces the continuation and
a client that names the constructor must both be rejected for exactly that
reason, while a client using only the runner and the allocators compiles,
links, and runs. The same file holds the companion boundary for retained
cleanup evidence, described under
[The evidence boundary](#the-evidence-boundary).

`allocComposite` allocates; it is not a second runner. Composite construction
is still written with `acquirePart` and `restoredStep`, and `withComposite`
remains the way to enter such a scope directly.

### The cleanup point

A resource allocated with `allocResource` is released when the enclosing
`withScoped` continuation returns or throws — **not** at the end of the `do`
block that allocated it. The rest of the block, and the final callback given to
`withScoped`, both run inside that resource's lifetime. This is the property
Synarchy's `allocResource'` existed to work around, and `locally` is the
supported way to end a group of lifetimes early.

A failed action in a scope never runs a later acquisition: everything after it
is inside its continuation.

### Release order

One scope releases its own allocations in reverse allocation order, on success,
on failure, and on asynchronous cancellation. That order is the scope's own
lifetime boundary, not a global rule across nested ones: a `locally` releases
its inner allocations before the outer scope resumes, and a composite released
by the scope keeps the order its constructor declared with `releaseRank`. A
different order within one scope needs the composite constructor above, not a
positioning trick.

### `locally`

`locally inner` runs `inner` to completion, releases everything `inner`
allocated, and only then continues the enclosing scope with `inner`'s result.
Staging work whose buffers must be gone before the rest of a block runs is the
case it exists for.

Its result must be an ordinary, fully evaluated value. The inner scope's
allocations are already released when the outer scope resumes, so a borrowed
handle returned from `inner` is a handle whose cleanup has run.

Cleanup failures inside `locally` propagate into the enclosing scope under the
failure table and are retained there as evidence `cleanupFailures` reads back,
beside anything the outer scope's own releases add.

### Borrowing and documented misuse

A scoped callback borrows its values, under the same rules as `withResource`.
Do not return a borrowed value, or anything whose validity depends on one, out
of `withScoped` or `locally`; return ordinary results.

`withScoped scope pure` is the documented misuse: it hands back a handle whose
cleanup has already run. The type does not prevent it — `pure` is a legitimate
continuation when the scope's result is an ordinary value — so this contract
and the examples forbid it for borrowed ones. `Scoped` has no escape
operation, no transfer operation, and no early-release token, and that boundary
is unchanged by the collection below: nothing allocated through `Scoped` can be
released before its enclosing continuation ends, except as a group by
`locally`. The collection's members are released early, but the collection is
itself a `Scoped` allocation that cannot outlive its scope.

## Scoped resource collections

```haskell
-- Hetoimasia.Foundation.Resource.Collection
data Collection
data Member a            -- nominal in a

allocCollection ∷ Int → Scoped Collection
liveMemberCount ∷ Collection → IO Int
acquireMember   ∷ Collection → Assembly a → IO (Member a)
withMember      ∷ Collection → Member a → (a → IO r) → IO r
retireMember    ∷ Collection → Member a → IO Retirement
memberStatus    ∷ Member a → IO MemberStatus

data Retirement      = Retired | AlreadyRetired | RetirementInUse
data MemberStatus    = MemberLive | MemberRetired
                     | MemberRetirementFailed (ExceptionWithContext SomeException)
data CollectionError = InvalidMemberLimit Int | NotOwnerThread | ForeignMember
                     | CollectionReentered Activity | CollectionClosed
                     | MemberLimitReached Int | CollectionPoisoned | MemberNotLive
data Activity        = Acquiring | Borrowing | Retiring | Closing
```

A collection owns independent resources whose lifetimes end when the
application decides — windows created while running and closed in any order —
while its enclosing scope stays their final owner. Every other lifetime in this
document is lexical. The module imports no logger, runtime, messaging, or
windowing module, and is built through
[the implementation seam](#the-implementation-seam), so neither `Scoped`'s
continuation nor a member's release is exposed.

```haskell
withScoped (allocCollection 8) $ \windows → do
  editor  ← acquireMember windows (windowAssembly editorConfig)
  preview ← acquireMember windows (windowAssembly previewConfig)
  withMember windows editor render
  _ ← retireMember windows preview    -- preview ends; editor stays live
  runUntilQuit windows editor
-- editor, and anything else still live, is released here
```

### Owner, thread, and lifetime

`allocCollection limit` allocates a collection for the rest of the enclosing
scope. A limit below one is rejected with `InvalidMemberLimit` before the
collection exists. The collection has a fresh identity, and the thread that
entered the scope is its only owner: `acquireMember`, `withMember`,
`retireMember`, and `liveMemberCount` called from any other thread fail with
`NotOwnerThread` before any effect. Concurrent member operations from several
threads are not supported. A native owner with a stricter thread requirement
enforces that itself.

The collection cannot outlive its scope. When the enclosing continuation
returns or throws, admission closes; afterwards every operation on the
collection is rejected with `CollectionClosed`, so a collection value that
leaked out of its scope reaches nothing, not even `liveMemberCount`.

### Acquisition

`acquireMember` checks, in order and before its `Assembly` runs, the owner
thread, that the collection is not already busy (`CollectionReentered`) or
closed, that no borrowing callback is running, that the collection is not
poisoned (`CollectionPoisoned`), and that it holds fewer live members than its
limit (`MemberLimitReached`). It then chooses the member's identity and runs the
assembly under the staged protection of
[Composite construction](#composite-construction). Each part's label and rank
are evaluated at that part's own stage, as
[When part metadata is evaluated](#when-part-metadata-is-evaluated) describes;
later metadata may depend on earlier acquisitions, so nothing is preflighted.

A failing stage rolls back exactly the parts acquired so far and propagates its
own failure with their ordered cleanup evidence retained. No member is
registered and no capacity is consumed. On success the finished release is
registered in the collection while still masked, with no interruptible
operation in between, and the token is returned only after registration. A
cancellation that arrives at that handoff therefore leaves a registered member,
which the collection releases at exit; no member is ever neither registered
nor released.

### Borrowing

`withMember` checks the owner thread, that the token was issued by this
collection (`ForeignMember`), the collection's phase, and that the member is
live (`MemberNotLive`). It records a borrow, runs the callback with the caller's
masking state, and drops the borrow on every exit, including failure and
cancellation. The borrowed value follows
[Ownership and borrowing](#ownership-and-borrowing): it must not escape the
callback. No linear typing is claimed.

A borrowing callback may borrow other live members. It may not acquire a member
or retire a different one: both are rejected with
`CollectionReentered Borrowing`. Retiring the member it is borrowing returns
`RetirementInUse` and never waits for the callback, so the caller retires it
after the borrow has returned.

### Retirement

`retireMember` checks the owner thread, the token's collection, and the phase,
then answers from the member's state, in the order of this table:

| Member state | Outcome |
|---|---|
| Borrowed by a running callback | `RetirementInUse`; nothing runs |
| Any other member, live or terminal, while a callback is borrowing | Rejected with `CollectionReentered Borrowing`; nothing runs |
| Retired successfully | `AlreadyRetired`; nothing runs |
| Retirement failed | The stored failure is rethrown — the same exception, context, and cleanup identities — and the release is not called again |
| Live | Its parts are released now, in their declared order, each once and uninterruptibly: `Retired`, or the failure below |

Retirement claims the release exactly once and makes access terminal. A
successful retirement removes the member's ledger entry and its value and
release references, so what the owner keeps is proportional to its live members
rather than to every member it ever opened. A failed retirement discards the
same references and keeps only the exception it propagated: the first cleanup
failure's exception, with every cleanup failure of that member retained beside
it, as a composite's release reports it.

A `Member` is an identity, not a borrowed value. It holds neither the collection
nor the member's value, and it may be retained after retirement and after the
scope, where `memberStatus` reports `MemberRetired` or `MemberRetirementFailed`.
A terminal state never changes, and `memberStatus` may be called from any
thread. What a client keeps by retaining tokens is the client's memory, not the
collection's. The token's type parameter is nominal, so a `Member` cannot be
coerced to a token at another type sharing a representation.

### Reentry

An `Assembly`, a release, and a borrowing callback all run user code on the
owner thread, which could call back into the same collection and defeat a
capacity check or disturb the ledger being released. While a collection is
acquiring, retiring, or closing, an acquisition, borrow, or retirement against
it is rejected with `CollectionReentered Acquiring`, `Retiring`, or `Closing`
before any effect. Borrowing is the lighter state described above.

### Poisoning and the exit outcome

Any release failure poisons the collection: a retirement whose release threw,
and a failed acquisition whose rollback release threw. Further acquisition is
rejected with `CollectionPoisoned`, while live members stay borrowable and
retirable. A construction failure whose rollback succeeded does not poison.

The failure is also latched. Catching the exception an early retirement or an
acquisition propagated cannot make the collection's exit succeed, and no
release is attempted a second time to find out. At exit:

| Body | Cleanup failures, latched or at exit | Outcome |
|---|---|---|
| Succeeds | None | The body's result is returned |
| Succeeds | Some | The first cleanup failure's exception is primary, with every cleanup failure retained beside it |
| Fails or is cancelled | Any | The body's exception propagates unchanged, with every cleanup failure retained beside it |

This is [the failure table](#the-failure-table) applied to everything the
collection released. Exception types, contexts, and `CleanupFailureId`s are
preserved; no textual collection exception replaces them.

### Release order at exit

Exit closes admission, then releases the members still live in reverse
registration order, each member's parts in the order its assembly declared with
`releaseRank`. Every remaining member is attempted even when an earlier one
fails, and every token is left in its terminal state. Members must be
independent: a dependency they share belongs outside the collection's scope, and
a dependency between two members belongs in one composite or another explicit
owner. The collection is not a dependency scheduler.

### State the collection holds

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
|---|---|---|---|---|---|
| Phase | The collection | Read by every operation; written by acquisition, retirement, and exit | Owner | The scope | Closed at exit and never reopened |
| Active borrows | The collection | Written by `withMember`; read by acquisition and retirement | Owner | The scope | Each borrow drops its count on every exit |
| Member identity counter | The collection | `acquireMember` | Owner | The scope | Monotone; never reused |
| Live-member ledger | The collection | Inserted by acquisition; removed by retirement and exit | Owner | Registration until retirement or exit | Entry removed at retirement; emptied at exit |
| Latched cleanup failures | The collection | Written by failed retirements and rollbacks; read by acquisition and exit | Owner | First failure until exit | Handed to the exit outcome and cleared |
| Live member state: value, release, borrow count | The collection | Borrows read the value; retirement and exit take the release | Owner | Registration until retirement or exit | Replaced by a terminal state holding no value or release |
| Terminal member state | Whoever retains the token | `memberStatus` | Any | As long as the token is retained | Immutable; a failed state keeps only its exception |

None of this is application state.

## Component construction

```haskell
-- Hetoimasia.Foundation.Recovery
allocComponent ∷ Operation → RecoveryPolicy (Assembly a) → Assembly a → Scoped (Outcome a)
```

`allocComponent` constructs a live component for the rest of the enclosing
scope, choosing among `Assembly` alternatives when an attempt fails. It lives
beside `recover` because it reuses that boundary's definitions unchanged — the
`RecoveryPolicy`, the budget rule, the exclusions, the `Disposition`, the
`Outcome`, and the `AttemptFailure` and `RecoveryHistory` evidence described in
[recovery.md](recovery.md) — but it is a different boundary with a different
lifetime. `recover` runs one complete operation and returns an ordinary value
after every scope inside it has closed. `allocComponent` keeps the selected
attempt's parts alive until the enclosing `withScoped` continuation returns or
throws, and it never calls `recover`.

```haskell
renderer ∷ Device → RendererConfig → Disposition → Scoped (Outcome Renderer)
renderer device config disposition =
  allocComponent (operation "renderer") policy (rendererAssembly device config Vulkan)
  where
    policy = RecoveryPolicy
      { policyDisposition = disposition   -- the caller's choice
      , policyBudget      = 2             -- the initial attempt and one more
      , policyClassifier  = classify      -- the component's knowledge
      , policyWait        = \_ → pure () }
    classify failure = pure $ case failureOf failure of
      Just NoDiscreteDevice → Just (Fallback (operation "software") (pure (rendererAssembly device config Software)))
      _                     → Nothing

withScoped (renderer device config Optional) $ \availability → case availability of
  Available recovered → run (recoveredValue recovered)
  Unavailable reason  → runHeadless reason
```

### Alternatives and the policy

The assembly passed to `allocComponent` is the initial alternative. After a
recognized failure the classifier names the next one:

- `Retry` runs the initial assembly again, even after a fallback.
- `Fallback name select` runs a named alternative. `select` is the first step
  of that attempt, run with the caller's masking state restored while nothing
  is acquired, and the assembly it returns is the rest of the attempt. A
  failure of `select` is therefore that attempt's failure, classified like any
  other.

One budget counts the initial attempt and every later one, and switching
between alternatives never resets it. The policy is evaluated and validated
when the scope is entered, before any alternative runs: a budget below one
throws `InvalidRecoveryPolicy` and nothing else happens.

**Required or optional is the caller's decision** at the composition boundary,
through `policyDisposition`. The component decides only which of its failures
another alternative can survive, through the classifier, and owns its private
sub-part invariants. Nothing about an exception's type makes a component
optional.

### Attempt order

Each attempt starts with a fresh part ledger and runs its assembly under the
rules of [Composite construction](#composite-construction): acquisition and
rollback installation are one protected step, part metadata is evaluated
before its acquisition, and `restoredStep` is the only restored work. When the
attempt fails:

1. **Rollback comes first.** Exactly the parts that attempt acquired are
   released, in their declared order, each exactly once, before anything looks
   at the failure. The construction failure stays primary and every cleanup
   failure is retained beside it.
2. **Cancellation propagates.** A cancellation that failed the attempt
   propagates with that rollback evidence. A cancellation requested while the
   rollback ran is deferred until every release has been attempted — the
   releases stay uninterruptible — and is then delivered with the caller's
   masking state restored. It propagates as itself with the rollback's cleanup
   failures retained and the construction failure attached as `WhileHandling`.
   A caller that was already masked keeps its masking state, and the request
   stays pending as it would anywhere else.
3. **Failed cleanup propagates.** A failure carrying cleanup evidence is not
   classified and no other alternative runs: an attempted release is not proof
   of disposal. No override treats a failed rollback as complete.
4. **The classifier is consulted,** with the caller's masking state, since the
   attempt holds nothing any more. A failure it does not recognize propagates.
5. **Budget remaining:** the wait runs, then the selected alternative starts.
6. **No budget left:** `Required` construction propagates the failure;
   `Optional` construction binds `Unavailable`.

A failure raised by the classifier, by evaluating its selection, or by the wait
stops construction and propagates with the handled failure attached as
`WhileHandling`; a cancellation there propagates as itself. A propagated
failure after earlier failed attempts carries one `RecoveryHistory` listing
them, oldest first, each with its own origin and cleanup evidence — exactly as
`recover` attaches it.

### The availability value

The continuation receives an immutable `Outcome`:

- **`Available`** carries the live handle as `recoveredValue`, the attempt kind
  that built it as `recoveredBy` (`InitialAttempt`, `RetryAttempt`, or
  `FallbackAttempt` with the alternative's name), and every failed attempt
  before it, oldest first, as `recoveredFailures`.
- **`Unavailable`** carries no handle. It names the component, the reason (the
  last attempt, which the classifier recognized with no budget left), and every
  attempt before it. It exists only for an `Optional` policy and only after the
  rollback has finished, so it owns nothing and no release follows it.

A consumer of an optional component branches on that data; it does not catch.

### The protected handoff and the once-only consumer

A successful attempt's ledger becomes the scope's release without ever leaving
the masked region. The continuation's failure handler is installed while still
masked, and only then is the caller's masking state restored and the
continuation invoked. There is no interval in which the handle lacks its
release or the consumer lacks its failure protection, and no token lets a
caller detach, duplicate, or trigger that release.

A cancellation delivered at that handoff may preempt the continuation's first
effect. It still releases every acquired part and propagates with the evidence
of that release; it cannot leak the handle, and it cannot start another
attempt.

Once construction resolves to `Available` or a permitted `Unavailable`, the
continuation is invoked exactly once, subject to cancellation before entry.
Construction that propagates a failure never invokes it. After the continuation
has been entered, nothing can start another attempt:

| Continuation | Final release | Outcome |
|---|---|---|
| Succeeds | Succeeds | The continuation's result is returned |
| Fails | Succeeds | The continuation's failure propagates unchanged; no attempt follows |
| Succeeds | Fails | The scope fails with the release's exception and the result is discarded; no attempt follows |
| Fails | Fails | The continuation's failure propagates with every cleanup failure retained; no attempt follows |

This is the failure table above, applied to the selected attempt's release. A
lazy value the continuation forces and a failure of the continuation after
`Unavailable` are continuation failures like any other.

### The handle never leaves the scope

The handle is borrowed under [Ownership and borrowing](#ownership-and-borrowing).
It is valid only inside the enclosing `withScoped` continuation, and the result
leaving that continuation must be an ordinary, fully evaluated value. There is
no transfer, no early release, and no catch instance on `Scoped`.

### State the constructor holds

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
|---|---|---|---|---|---|
| Per-attempt part ledger | One attempt of one entry into the scope | Written by that attempt's `acquirePart` stages; read and emptied by its rollback, or by the scope's release for the selected attempt | The thread entering the scope | From the attempt's start until its rollback, or for the selected attempt until the scope's release | Created empty per attempt and never reused; emptied when its releases run, so no part is released twice |
| Selected release | The scope, once construction succeeds | Run only by the scope when the continuation returns or throws; never exposed | The thread entering the scope | From the successful attempt's last stage until the scope exits | Attempted exactly once; never reset |
| Attempt history | The entry into the scope while it builds; then the `Outcome` or the propagated failure | Appended by the constructor after each failed, classified attempt; read by the continuation or by `recoveryHistory` | The thread entering the scope | Bounded by the budget; lives as long as the value carrying it | Immutable once handed on; a new entry into the scope starts a new history |

None of this is application state, and none of it is visible outside the entry
into the scope that created it.

### The component convention

A component that owns resources follows these conventions. They are
[the working agreements](../AGENTS.md)' architecture rules made concrete, and
`test/Test/Engine/Resources/Journal.hs` is the worked example.

- **One constructor.** A component exposes one construction function in
  `Scoped` — over `allocResource`, `allocComposite`, or `allocComponent` —
  taking its dependencies and its configuration as ordinary arguments.
- **An opaque handle.** The constructor yields a handle whose constructor and
  fields are not exported. Every consumer takes the handles it needs as
  parameters, exactly as it takes a `Logger`. There is no environment record,
  `Reader` facade, capability class, service locator, or global registry.
- **Pure, validated configuration.** The component defines its own
  configuration value and a pure validation for it, run by the application
  before any acquisition, the way `resolveLogFilter` validates logging
  configuration. A component never reads a shared application configuration
  record.
- **Private state behind the handle.** State is created inside the constructor
  and reachable only through the handle's operations.
- **One state table per component module,** naming every state's owner,
  readers and writers, thread, lifetime, and reset or disposal behavior, as the
  table above does for the constructor itself.
- **The caller decides availability.** A component offers alternatives and a
  classifier; the application chooses the budget and whether the component is
  required.

### The implementation seam

`Scoped`, the composite ledger, and the cleanup-failure primitives are defined
in `Hetoimasia.Foundation.Resource.Internal`, which the foundation library lists
under `other-modules`. `Hetoimasia.Foundation.Resource` re-exports only the
closed types and the operations over them, and `allocComponent` builds its
scope through the hidden module from inside the same library. No client can
import that module, so the opacity described under
[The continuation facade](#the-continuation-facade) and
[The evidence boundary](#the-evidence-boundary) is unchanged, and the opacity
examples are unchanged.

## Inspecting secondary failures

```haskell
data CleanupFailure
cleanupFailureId        ∷ CleanupFailure → CleanupFailureId
cleanupFailureLabel     ∷ CleanupFailure → Text
cleanupFailureException ∷ CleanupFailure → ExceptionWithContext SomeException
displayCleanupFailure   ∷ CleanupFailure → String

cleanupFailures          ∷ SomeException    → [CleanupFailure]
cleanupFailuresInContext ∷ ExceptionContext → [CleanupFailure]
```

A retained failure is structured data, not a rendered message: it carries the
operation's label and the exception together with the context that exception
had when the scope caught it, so its own annotations and backtrace are still
there to examine. Inspection needs no logger. The three readers are ordinary
functions over a closed type rather than field selectors, so an entry can be
read but not written; [The evidence boundary](#the-evidence-boundary) says why
that matters.

`cleanupFailures` takes the exception a caller caught and returns the retained
failures in the order they were observed while the scopes unwound.
`cleanupFailuresInContext` is the same for a caller that already holds the
context, from `tryWithContext` or `catchNoPropagate`.

No entry is lost or duplicated as nested scopes unwind. Evidence reached by
more than one route is reported once, while two distinct failures that render
identically stay distinct. Evidence nested inside a `WhileHandling` annotation
is found as well, and so is evidence a release carried out of a scope of its
own.

### The evidence boundary

A `CleanupFailure` is read-only outside the foundation package. Entries are
created only where a release is attempted and throws, and each one is issued
its `CleanupFailureId` at that moment. A caller reads an entry with the three
readers above and reattaches it unchanged; there is no supported way to build
one, and no supported way to alter one it was handed.

That boundary rests on the representation being closed, the same way `Scoped`'s
does. The constructor is not exported and none of the three carried values is a
record field, so no field label reaches a client — and record construction and
record-update syntax both need one in scope. This is why the readers are
ordinary functions rather than selectors: an exported selector is an exported
field label, and a field label is a licence to write as well as read. Their
names and types are unaffected by that, so a caller that inspects an entry's
identity, label, exception, and attached context needs no change.

The invariant the boundary protects is that one `CleanupFailureId` stands for
one unchanging payload. [What inspection costs](#what-inspection-costs) rests
on it directly: inspection expands a given identity's carried context the first
time that identity is reached and skips the identity afterwards, which is sound
only because reaching it again means reaching the same label, the same
exception, and therefore the same context. An entry whose payload could be
replaced while its identity stayed the same would put two payloads behind one
key, and evidence reachable only through the replacement would never be
expanded — the reported failures would be missing entries rather than merely
costing more. Reattaching an *unchanged* entry any number of times, which is
what nested scopes do as they unwind, is exactly the case the invariant is
there to permit.

Nothing counts entries or refuses a rewrite at run time; the guarantee is that
the rewrite cannot be expressed, and it is checked when the client is compiled.

### What inspection costs

Inspection runs on a failure path, where a caller is already recovering and has
the least room to absorb a surprise, so what it costs is part of this contract
rather than an implementation detail.

Each distinct `CleanupFailure`'s own carried context is expanded once per
inspection, however many routes reach it. Nested releases that each carry the
cleanup context below them offer exponentially many such routes to the same
evidence; expanding each retained failure once is what keeps the cost
proportional to the evidence retained instead of to the number of routes.

What a caller pays beyond that is a scan of the annotations on each expanded
context — every annotation on it is examined, not only the cleanup failures —
together with the work of ordering the result by identity. A `WhileHandling`
annotation carries no identity of its own, so the contexts below one are
followed whenever they are reached rather than being expanded once; a caller
that nests handlers deeply pays for that scanning. Inspection is therefore
bounded by the retained evidence and the annotations sitting beside it, not by
the number of returned failures alone.

Recognizing a repeated failure skips that one entry, never the context holding
it: evidence standing beside an entry already reached, directly or below a
handler, is still reported.

```haskell
outcome ← try (withResourceLabelled "index buffer" acquire release body)
case outcome of
  Right result → use result
  Left (failure ∷ SomeException) →
    report failure (map displayCleanupFailure (cleanupFailures failure))
```

An engine failure raised with `throwFailure` also carries its origin and any
operation context on the same exception context, beside the cleanup failures
retained here; [failures.md](failures.md) describes that evidence and its
inspection. Neither kind of evidence displaces the other.

`Hetoimasia.Foundation.Recovery` reads this evidence to refuse automatic retry
or fallback after a failed cleanup: an attempted release is not proof of
disposal. [recovery.md](recovery.md) describes that boundary; nothing in this
contract changes for it.

A boundary that reports resource failures through a logger follows the pattern
in [logging.md](logging.md#module-authoring-guide): the scope raises, and the
boundary decides what to log. A broken logger must not erase the outcome.

## Application lifecycle

Scopes and logging are peers. This module imports no logger, and a scope runs
its cleanup and exposes its outcome with no logger at all or with a broken one.
Composing the two is therefore the application's job, and these are the rules
that composition follows. [The application runner](#the-application-runner)
composes them, with workers and supervision, for any application. `Hetoimasia.Runtime.Resources.resourceSmoke` is the
worked example: the console executable runs it as `--resource-smoke`, and the
suite runs the same body with failures injected.

### Where a logger call may go

**Never between an acquisition and its protection.** Nothing that can fail on
its own belongs there, and a sink write can fail. With the facade there is no
temptation to put one there: the continuation the facade enters is already
covered by that allocation's release, so an acquisition record emitted from it
is emitted after the resource is protected.

```haskell
smokeScope ∷ Logger → Ledger → ReleaseOutcomes → Scoped SmokeResources
smokeScope scoped ledger outcomes = do
  workspace ←
    allocResource
      (openSlot ledger "workspace")
      (closeSlot ledger (onReleaseWorkspace outcomes))
  liftIO $
    logInfo scoped resourceComponent "Acquired resource"
      [("resource", slotName workspace), ("id", slotId workspace)]
  channel ← allocComposite (channelAssembly ledger outcomes)
  liftIO $
    logInfo scoped resourceComponent "Acquired composite"
      [ ("resource", "channel")
      , ("buffer", slotId (channelBuffer channel))
      , ("store", slotId (channelStore channel))
      ]
  pure (SmokeResources workspace channel)
```

**Never inside a release.** A release runs under `uninterruptibleMask_` and must
have a controlled blocking duration; a sink write has none, and a sink that
fails would then be a cleanup failure of a resource that was destroyed
perfectly well. Collect a bounded lifecycle entry in the release and emit it
after the scope has unwound:

```haskell
closeSlot ∷ Ledger → IO () → Slot → IO ()
closeSlot ledger injected slot = do
  entries ← readIORef (slotEntries slot)
  atomicModifyIORef' (ledgerReleased ledger) $ \released →
    (Released (slotName slot) (slotId slot) (length entries) : released, ())
  writeIORef (slotOpen slot) False
  injected
```

The record is appended before anything can fail, so evidence shows every
release that was attempted rather than only those that succeeded, and the
destruction happens whether or not the diagnostic later reaches a sink. A
failed lifecycle log never skips a destruction, because no log runs inside one.

### The reporting boundary

A boundary that turns a resource failure into a diagnostic follows the worker
example of [the logging contract](logging.md#usage), with one difference: that
worker is terminal and swallows what it reported, while a boundary with a caller
must hand the structured outcome on. `Hetoimasia.Runtime.Reporting` implements
these rules once as `reportTerminalFailure`, described in
[Recovery and terminal reports](logging.md#recovery-and-terminal-reports), and
the demonstration uses it rather than repeating them. The rules:

- Classify anything thrown as asynchronous as cancellation and let it escape
  unreported. A record emitted while cancelling is one more place the
  cancellation could be lost.
- Report an ordinary failure — of a resource, of a release, or of the work —
  exactly once, with its context, which means the evidence
  `cleanupFailuresInContext` reads out of it rather than a rendered message.
- **A resource failure and a diagnostic failure are different things.** When
  what failed is the sink a lifecycle record was written to, there is no second
  sink to say so through and the one that just failed is not it: release
  everything, then propagate with no reporting attempt at all. An exception's
  type cannot tell you which it was — an `IOException` from a sink and an
  `IOException` from a release look alike — so mark the emission and check the
  mark. The example annotates every lifecycle record it emits with
  `DiagnosticFailure`, which rides on the exception's context through the
  scope's preserving rethrows.
- Make the one attempt guarded, and never a second one. A synchronous failure
  from that attempt is discarded in favour of the original, and a cancellation
  arriving during it escapes as itself.
- Rethrow preservingly — the cancellation included. `rethrowIO` on the value
  `tryWithContext` returned keeps the exception's type, its value, and its
  retained evidence, so the caller can inspect the same outcome the boundary
  just reported. Guard the attempt with the same preserving `tryWithContext`
  rather than a plain `try`, and rethrow the cancellation it hands back rather
  than the bare exception inside it: `try` retains the context on the value it
  returns, but a plain `throwIO` of that value gives it a fresh one, so the
  annotation and the cleanup evidence the cancellation was already carrying are
  lost.
- Never report successful completion for an action that threw or was
  interrupted.

```haskell
resourceSmoke ∷ Logger → ReleaseOutcomes → SmokeWork → IO Int
resourceSmoke = smokeReportedBy reportTerminalFailure

smokeReportedBy ∷ Reporter → Logger → ReleaseOutcomes → SmokeWork → IO Int
smokeReportedBy report logger outcomes work = do
  ledger ← newLedger
  report scoped resourceComponent "Resource smoke abandoned"
    (releasedFields <$> recordedReleases ledger)
    (runSmoke scoped ledger outcomes work)
  where
    scoped = withBreadcrumb "resource-smoke" logger

-- Every lifecycle record is emitted through the adapter's mark.
lifecycle ∷ IO () → IO ()
lifecycle = markDiagnostic

releasedFields ∷ [Released] → [(Text, Text)]
releasedFields released =
  [("released", Text.intercalate "," (map releasedResource released))]
```

`reportTerminalFailure` classifies what the run threw. A cancellation and a
failure marked by `markDiagnostic` propagate with no attempt. Anything else gets
one guarded `Error` attempt carrying the cleanup evidence
`cleanupFailuresInContext` reads, the failure's origin, and the released names
read from the ledger inside that attempt. The original exception then
propagates through `rethrowIO`, and a cancellation raised during the attempt
propagates as itself. `DiagnosticFailure` is defined by the adapter and
re-exported by `Hetoimasia.Runtime.Resources`.

The reporter is injected so the same run has exactly one terminal report on
both of its paths. `resourceSmoke` uses `reportTerminalFailure`.
`managedResourceSmoke`, which the console executable runs inside a
[logging lifetime](logging.md#logging-lifetime), uses
`reportTerminalFailureWith` with the lifetime's `recordReport`, so a report that
failed reaches the lifetime owner while the original failure still propagates.
Neither wraps the run in a second reporter.

The emission of the lifecycle records sits inside that boundary too, but on the
diagnostic side of it. If the sink fails while the lifecycle is being reported,
everything has already been released, the marked exception takes the second
branch above, and it propagates with nothing further written — the caller
learns that the sink failed by receiving the sink's own exception, which is the
only place that news can still go.

### The application runner

```haskell
-- Hetoimasia.Runtime.Application
runScopedApplication
  ∷ HasCallStack
  ⇒ (∀ r. (LoggingLifetime → IO r) → IO r)            -- enters the logging lifetime
  → Text                                             -- the application's name
  → Scoped dependencies                              -- construction, in dependency order
  → (dependencies → RuntimeControl → IO services)    -- startup
  → (services → RuntimeControl → IO a)               -- the action
  → IO a
```

`runScopedApplication` is the generic lifecycle an application runs through. It
sits in its own module beside `Hetoimasia.Runtime.runApplication`, which keeps
its module, signature, behavior, and examples as the thin runner over a
supplied logger. The new runner composes the
runtime's existing boundaries and adds no mechanics of its own: supervision is
[supervision.md](supervision.md)'s, worker ownership and the drain are
[workers.md](workers.md)'s, the finalization matrix is the
[logging lifetime](logging.md#logging-lifetime)'s, the report is the
[reporting adapter](logging.md#recovery-and-terminal-reports)'s, and every
release follows this document's failure table and mask discipline.

**The lifecycle order**, on every run:

1. Configuration is parsed and the logger constructed, by the caller, before
   the runner is called. A failure there propagates as its own typed failure
   with no record promised: no managed logger exists yet.
2. The runner enters the logging lifetime through its first argument — for the
   console, `withHandleLoggingLifetime configuration stderr`.
3. The dependencies are constructed inside it, by `withScoped` over the
   application's `Scoped` value, in the order that value allocates them. A
   required component propagates its failure after cleanup of what it
   acquired; an optional one built with
   [`allocComponent`](#component-construction) binds `Unavailable` only after
   its rollback. A construction failure disposes what was acquired without
   entering the worker group.
4. A supervised worker group is entered inside those scopes, with
   `withSupervision`.
5. The startup callback runs on the calling thread with the dependencies and
   the `RuntimeControl`. It may start and acknowledge workers with
   `startSupervised`, and it returns the application's services value.
6. `checkRuntime` runs before that value is handed over.
7. The action runs on the calling thread with the services value and the
   control; `checkRuntime` runs again before its result is accepted.
8. Supervision closes: registration closes, every live worker is asked to stop
   — a failed or cancelled request does not skip the rest — and every worker is
   drained with its dependencies live. Every outcome not yet handled is
   settled, including a failure that arrived while closing, and a latched
   failure is rethrown.
9. The dependency scope unwinds. Dependents are disposed before their
   dependencies, and a composite keeps its declared internal order.
10. A failed run gets one managed terminal report, while the logger is live.
11. The logging lifetime makes its one permitted final flush.
12. The runner returns the action's result, or rethrows.

Steps 8 onwards happen on every exit path — construction failure (from step
9), startup failure, action failure, a supervisor-detected failure, and owner
cancellation, which skips steps 10 and 11.

**The application owns its types.** The runner is polymorphic over the
dependencies and the services value; it names no field of either, imports no
concrete application, and passes each callback only what it was given. The
services value is a snapshot assembled once by startup and passed as an ordinary
immutable argument. There is no global or central mutable availability
registry, nothing mutates the value, and nothing re-publishes it: a component
that degrades after startup says so through its own handle, under its own
documented state ownership.

**The calling thread.** Construction, startup, and the action all run on the
thread that called the runner. The action is never forked to race a monitor,
and no arbitrary `IO` is interrupted: a worker failure reaches the application
at a checkpoint or inside `awaitSupervised`, as
[supervision.md](supervision.md#checkpoints-and-supervised-waits) describes.
This keeps the process main thread for a future windowing owner.

**A composition.** The application declares its own types and builds them from
the handles its components expose, under
[the component convention](#the-component-convention):

```haskell
data Tools    = Tools    { toolsStore ∷ Store, toolsPreview ∷ Outcome Preview }
data Services = Services { servicesStore ∷ Store, servicesPreview ∷ Maybe Preview
                         , servicesIndexer ∷ SupervisedWorker () }

main ∷ IO ()
main = exitOnFailure $ do
  configuration ← resolveLogFilter variables readVariable defaultLogFilter
    >>= either (die . Text.unpack) pure
  runScopedApplication (withHandleLoggingLifetime configuration stderr) "example"
    tools startup action
  where
    tools = do
      store ← storeScope storeConfig                 -- required
      preview ← previewScope store Optional          -- allocComponent: data, not a catch
      pure (Tools store preview)

    startup (Tools store preview) control = do
      indexer ← startSupervised control indexerPolicy (indexerWorker store) >>= started
      pure (Services store (availableValue preview) indexer)

    action services control = loop
      where
        loop = do
          checkRuntime control
          request ← awaitSupervised control (nextRequest (servicesStore services))
          ...
```

`test/Test/Engine/Runtime/Composition.hs` is the worked example: two unrelated
applications — a workshop whose services carry a supervised service, and a
station whose services publish an optional radio's availability — run through
the same runner.

**Outcomes.**

| What happened | What the runner does |
|---|---|
| The action returned, nothing fatal was settled, every disposal succeeded, the flush succeeded | Returns the action's result |
| Construction, startup, or the action failed synchronously | Drains, disposes, reports once, flushes, and rethrows the failure with its type, value, and context |
| A supervised failure was latched — even one the action caught and ignored, or one that arrived while closing | The same: a latched failure cannot become a successful run |
| The action succeeded and a component's disposal failed | The same, with the cleanup failure primary and retained; the report carries `cleanup.failures` and `cleanup.labels` |
| The run succeeded and the final flush failed | The flush's failure propagates, with no report attempted and no retry |
| A managed report already failed on this lifetime, such as an optional worker's warning | No terminal report and no flush; the failure propagates with the failed attempts attached |
| The report's own write failed synchronously | The failure being reported propagates, with its evidence; the attempt is recorded on the lifetime, so no flush follows |
| Owner cancellation | Drains, disposes, and propagates the cancellation as itself, with no report and no flush |

The one report is `Error` `Application failed` under the `runtime` component,
with an `application` field naming the run and the fields the adapter derives:
the primary failure's reason and origin, and every retained cleanup failure,
including component disposal failures. A failure already reported by a terminal
boundary inside the action, or raised by a marked diagnostic, is not reported
again. A filter may still drop the record, and a sink may still refuse it.

**Exit mapping belongs to the executable.** The runtime never exits the host
process. The console maps what propagates out of a path in
`Hetoimasia.Console.Exit.exitOnFailure`: a failure exits 1 after one best-effort
line on stderr, a cancellation exits 130 with nothing written, and an explicit
`ExitCode` such as a usage error passes through unchanged. That module lives in
the root package's private `console` library, beside `app/`, so the suite
drives the mapping directly as well as through the executable.

**What the runner does not own.** It defines no classifier, observation
cursor, fatal latch, closing protocol, or logging finalization rule; no worker
restart, deadline, detach, or process termination; no environment record,
service locator, application-wide monad, or runtime-declared services record.
The existing `--smoke` and `--resource-smoke` paths keep their output; neither
needs the new runner, and no console path was added for it.

**The runner's state.** It holds no mutable state of its own:

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
|---|---|---|---|---|---|
| The dependencies value | The application; its releases belong to the runner's `withScoped` | Built by construction; read by startup | The calling thread | From construction until the dependency scope unwinds, after workers drain | Released once, in reverse allocation order with each composite's declared order; never reset |
| The services value | The application | Written once, by startup's return; read by the action | The calling thread | From startup's return until the action returns or throws | Immutable; nothing re-publishes it and nothing disposes it |
| Worker, supervision, and latch state | The one `withSupervision` invocation | As [supervision.md](supervision.md#state) records | As recorded there | One invocation | As recorded there |
| Recorded reporting outcomes | The logging lifetime the runner entered | As [logging.md](logging.md#logging-lifetime) records; the runner reads them once before its report | As recorded there | One lifetime | As recorded there |

Nothing is global, shared between invocations, or reset.

### Shutdown order

The order is the one [the logging contract](logging.md#ownership-and-failures)
establishes, and nothing here changes it:

1. Stop and join the producers, so nothing is still emitting.
2. Finish subsystem cleanup, which may itself emit diagnostics.
3. Make the terminal report, once, through the boundary chosen to own it.
4. Make the final flush.
5. Close any handle the application owns.

Step 2 is where a scope unwinds, and the lifecycle records collected during that
unwind are emitted after it, in step 2's own tail, then step 3 reports a failure
if there was one. Steps 1 to 3 all happen inside the callback of a
[logging lifetime](logging.md#logging-lifetime), and step 4 is that lifetime's
own phase: it starts only once the callback has returned or thrown, and so only
once every `withScoped` inside it has finished unwinding and every release has
run. The flush therefore never runs inside a release, where its unbounded
blocking would break the release contract, and never runs before the cleanup
whose records it is meant to carry. A lifetime is never entered from a release
callback.

`runScopedApplication` performs steps 1 to 4 in exactly this order: supervision
closing is step 1, the dependency scope's unwind is step 2, its one report is
step 3, and the lifetime it entered makes step 4.

The console executable owns no handle: its sink borrows the process's `stderr`,
which it never closes and never rebuffers, so its step 5 is empty. An
application that opened its own log file closes it there — after the lifetime
has returned, never before.

### What the demonstration owns

Two resources through the facade, and nothing that outlives the process. The
workspace is a plain `allocResource`; the channel is an `allocComposite` of a
buffer and the backing store it is bound to, released in that declared order —
acquisition order, because what holds the reference goes before what it refers
to — while the enclosing scope releases the workspace it allocated first last.
There is no file, no thread, and no service: ownership is what the example
shows, and none of those is needed to show it.

Cleanup failures from the composite carry that constructor's own part labels;
the workspace's carry `withResource`'s default label, because the facade's
`allocResource` takes no label. Nesting a labelled `withResourceLabelled` by
hand is the way to name one today.

## Caller patterns that discard evidence

Recognizing an exception by type and keeping its attached context are separate
properties. Two ordinary-looking patterns keep the former and throw away the
latter, and no scope can recover what its caller has discarded.

**A bare typed `try`.** `try @IOException` or `try @ErrorCall` hands back the
concrete exception value. It has the right type and the right value, and no
context — so `cleanupFailures` on it reports nothing.

```haskell
-- Loses the evidence:
outcome ← try @ErrorCall scope

-- Keeps it: a context-aware typed catch.
outcome ← tryWithContext @ErrorCall scope
case outcome of
  Left (ExceptionWithContext context (ErrorCall message)) →
    report message (cleanupFailuresInContext context)
  Right result → use result
```

`try @SomeException` keeps the context, reachable through
`someExceptionContext`, so `cleanupFailures` works on its result directly.

**A `try` followed by a plain `throwIO`.** Re-raising a caught value with
`throwIO` starts a fresh context, and the evidence is gone. An ordinary `catch`
handler that does the same leaves the original only nested inside a
`WhileHandling` annotation; `cleanupFailures` does search there, but do not
rely on incidental handler nesting to carry evidence.

```haskell
-- Loses the evidence:
Left failure ← try @SomeException scope
throwIO failure

-- Keeps it: rethrow with the exception's own context.
Left failure ← try @SomeException scope
rethrowIO (ExceptionWithContext (someExceptionContext failure) failure)

-- Or do not take it apart at all:
scope `catchNoPropagate` \caught → case caught of
  ExceptionWithContext context (_ ∷ SomeException) → do
    note (cleanupFailuresInContext context)
    rethrowIO caught
```

Inside the scope module every rethrow already uses a preserving path, so an
annotation attached below a scope is directly reachable above it and the
primary exception is never rebuilt. See GHC's
[`rethrowIO`](https://hackage.haskell.org/package/base-4.21.0.0/docs/Control-Exception.html#v:rethrowIO)
and
[`catchNoPropagate`](https://hackage.haskell.org/package/base-4.21.0.0/docs/Control-Exception.html#v:catchNoPropagate).

## Verification

`cabal test hetoimasia-tests --test-show-details=direct` runs the `Resources`
examples from `test/Test/Engine/Resources/Spec.hs`, which drive every row of
the failure table, the failed acquisition, ordered nested evidence, the
cancellation and throwing-release cases of the mask discipline, inspection
through `WhileHandling`, each internal rethrow site, and both evidence losses
above. The composite examples in the same file add a failure injected before
and after each acquisition and at the binding step, the declared release order
in both its acquisition-order and its reordered form, a throwing rollback
release, the cancellation cases above, and the whole construction nested inside
`withResource`. The `Composite part metadata` group adds a throwing rank and a
throwing label at a later stage, each asserting which parts were acquired and
which were released: alone, ahead of a later stage that would itself have
failed, with an earlier part's release throwing while the remaining one is
still attempted, and beneath an enclosing scope whose body has already failed.
One further example owns two real file handles and asserts both are closed and
the rejected stage's file was never opened, and one asserts that an earlier
stage's failure stays primary when a later part's metadata would have thrown.
They drive it through the fake buffer of
`test/Test/Engine/Resources/Buffer.hs`, which models exactly the four steps
this contract needs and ships in no library.

The facade examples in the same file add the cleanup point observed from the
final callback, reverse-allocation release on success, failure, and
cancellation, a failed action leaving a later acquisition unrun, the `MonadIO`
path, composition through `fmap` and `<*>`, the direct and continuation paths
agreeing on one resource and on nested ones, `locally` releasing before the
outer scope resumes while its ordinary result survives, a `locally` cleanup
failure reaching the outer scope's evidence, and two composites allocated
through the facade keeping their declared order while the scope unwinds in
reverse.

The `Scoped component construction` examples in
`test/Test/Engine/Resources/Construction.hs` cover
[Component construction](#component-construction) with typed synthetic
failures, real CPU scopes, and ordered traces. Through the synthetic journal
component of `test/Test/Engine/Resources/Journal.hs` they show a configuration
fault observed before any acquisition, private state reachable only through the
handle, a fallback handle live for the whole consumer with the consumer run
once, an exhausted optional component bound as `Unavailable` data with its
reason and history, and required exhaustion across both alternatives
propagating the latest failure with each earlier attempt's origin and cleanup
evidence in order. With assemblies placed exactly they show an invalid policy
rejected before any effect, one budget exhausted across alternatives without
reset, rollback of exactly the failed attempt's parts in declared order before
the classifier, the wait, and the next alternative, an unrecognized failure, an
attempt with cleanup evidence, and a classifier failure each propagating as
specified, and a consumer failure, a lazy result forced in the consumer, a
final release failure, and a failing consumer of `Unavailable` each following
the failure table with no further attempt. The cancellation examples, coordinated
with `MVar`s and `threadStatus` and no sleeps, cancel a blocking acquisition,
request cancellation while a throwing rollback release runs — asserting the
request stays pending until every release has been attempted and then escapes
with the rollback evidence, invoking neither another alternative nor the
consumer — and leave a cancellation pending as construction completes, which
preempts the consumer and still releases every part.

The first two opacity groups in `test/Test/Engine/Resources/Opacity.hs` cover
[The continuation facade](#the-continuation-facade) and
[The evidence boundary](#the-evidence-boundary). They compile eight
single-module clients with the compiler on `PATH` against the package database
this build produced, exposing only `base`, `text`, and
`hetoimasia-foundation`, so what a client can say is exactly what the package
boundary allows. Six must be rejected: for `Scoped`, one that replaces the
continuation through record update and one that names the constructor; for
retained evidence, one for each of `cleanupFailureId`, `cleanupFailureLabel`,
and `cleanupFailureException` that imports the reader by name and then tries to
replace it through record update, and one that names the `CleanupFailure`
constructor. The four record-update cases are rejected because no field label
exists to write through, and the two that name a constructor because their
types are exported without their children; each example asserts the diagnostic
that names its own cause and refuses to count a missing package, an absent
compiler, or an unrelated error as the guarantee holding. Two must be accepted, linked, and run: one using only
the runner and the allocators, and one using only the three readers, both
inspection entry points, `displayCleanupFailure`, and reattachment through
`addExceptionAnnotation`, which asserts observation order across a scope that
fails in three places at once, the evidence reachable only through an entry's
own carried context, and that reattaching entries already present reports each
of them once.

The `Resource collection` groups in `test/Test/Engine/Resources/Collection.hs`
cover [Scoped resource collections](#scoped-resource-collections) with real CPU
scopes and ordered traces, coordinated with `MVar`s and `threadStatus` and no
sleeps. Admission: a limit below one, rejection at the live-member limit before
the assembly runs and reuse of a retired slot, rollback of a failing stage with
no member registered, no capacity consumed, and no poisoning, a member cancelled
inside its assembly rolled back, and a member whose acquisition returns with a
cancellation pending registered and released exactly once at exit. Borrowing
and retirement: a middle member retired while its neighbours stay live and the
rest released in reverse, repeated retirement inert after success and reporting
the stored failure with the same cleanup identities after a failed release,
with each release called once, `RetirementInUse` during a borrow and `Retired`
after it, a nested borrow of another member, the caller's masking state in the
callback, and a borrow dropped after its callback fails or is cancelled. Misuse:
every owner operation from another thread and a foreign token rejected with no
effect, and acquisition, borrowing, and retirement re-entered from an assembly,
an early release, and a release at exit each rejected, with a borrowing
callback allowed to borrow but not to acquire or retire another member, live
or already terminal. Terminal tokens: statuses read after exit while the closed
collection rejects every operation, including `liveMemberCount`, a failed early
retirement and a release failed at exit each reported through a retained token
whose payload the garbage collector can no longer reach, and two hundred open,
borrow, and retire cycles under a limit of one leaving no live member, with no
retired payload reachable through the retained tokens. Cleanup failures: a caught early-retirement
failure still failing a successful body's exit while the remaining members are
released, a failing and a cancelled body each staying primary beside early and
final evidence, a failing rollback poisoning acquisition while a live member
stays borrowable and retirable and then failing a successful body's exit with
the same cleanup identity, the body staying primary over such a rollback,
reverse registration order with each member's declared ranks, and a successful
body failing with the first of several final release failures.

The `Collection opacity across the package boundary` group in
`test/Test/Engine/Resources/Opacity.hs` compiles seven more clients the same
way. Six must be rejected: one naming each of the `Collection` and `Member`
constructors, one each rewriting a collection through `liveMemberCount` and a
token through `memberStatus` with record update, one coercing a `Member
Celsius` to a `Member Double`, which the nominal role refuses, and one
importing the ledger release primitive from the implementation module, which
the package hides. One must be accepted, linked, and run: it uses only the
public operations to acquire three members, borrow two together, observe
`RetirementInUse`, `Retired`, and `AlreadyRetired`, release the rest at exit in
reverse order, and read both retained tokens' terminal states afterwards.

The `Resource evidence inspection cost` examples in
`test/Test/Engine/Resources/Cost.hs` cover
[What inspection costs](#what-inspection-costs). They build twenty and then
forty nested scopes whose releases each run the next scope, with the innermost
release throwing, and hold each of `cleanupFailures` and
`cleanupFailuresInContext` to a fixed allocation budget — 128 MiB at the
shallower depth and 512 MiB at the deeper one — measured with `GHC.Stats`
across garbage collections, with the fixture built before the interval opens
and the returned failures and their order asserted after it closes. Two depths
are what separate a changed growth rate from a constant factor. The suite is
built with `-with-rtsopts=-T` so those statistics exist; an example that finds
them missing fails rather than reporting a budget as met. A measured inspection
that overruns a much larger reporting bound is abandoned and named as such, so
an unbounded traversal fails these examples in seconds instead of running for
hours.

The `Console resource smoke` examples in
`test/Test/Engine/Resources/Smoke.hs` cover
[Application lifecycle](#application-lifecycle) by running
`Hetoimasia.Runtime.Resources.resourceSmoke` — the body the console executable
runs — with a failure injected into the work, into one release, into two
releases at once with the report failing too, and into the sink of a lifecycle
record after acquisition — which releases everything and then propagates with
no reporting attempt, beside a companion example raising the same sink
exception from the work instead, which does get its one report — plus a
cancellation delivered to the work and another delivered while the report
blocks. Each asserts what a caller sees: the
exception that propagated, the evidence `cleanupFailures` reads out of it, the
records that reached the sink, and which releases ran. One further example
drives the body through a handle sink over a temporary file the example owns,
and closes that handle only after the scope has unwound, so every cleanup
record is in the file and the borrowed handle was neither closed nor rebuffered
by the sink. The `Console startup` group in `test/Main.hs` runs
`--resource-smoke` as a child process for the record sequence and for the quiet
path at a `warn` threshold. The validation catalog covers all of them through
the floor group `test.engine`; see [validation.md](validation.md).

The `Application lifecycle` examples in
`test/Test/Engine/Runtime/Composition.hs`, selected by `--match Runtime`,
cover [The application runner](#the-application-runner) with two
application-owned dependency and services types through the same runner, an
injected sink traced beside the releases, real CPU scopes, real foundation
workers under supervision, and the supervision fixtures of
`Test.Engine.Runtime.Supervision.Support`, coordinated with gates, STM, and
`threadStatus` and no sleeps. They show startup and the action on the calling
thread; boot in dependency order and disposal of dependents before
dependencies with a composite's declared order kept; an optional component's
unavailability published in the services value after its rollback; a
construction failure disposing what was acquired without running startup; a
failing startup and an owner cancellation each draining a worker before any
dependency is disposed, the cancellation unreported and unflushed; a caught
supervised failure and a failure arriving while closing each failing a run
whose action returned; a component cleanup failure in the one terminal report,
after disposal and before the flush; a final flush failure attempted once,
failing the run with no report; and no terminal report once an optional
worker's warning has failed. The `Exit mapping` examples in
`test/Test/Engine/Runtime/Console.hs` run both smoke paths with a broken stderr
for a non-zero exit, and drive `exitOnFailure` directly for cancellation and
for an explicit status passing through.
