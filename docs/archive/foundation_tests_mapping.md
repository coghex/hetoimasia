# Foundation suite example mapping

Evidence for issue #127 (TEST-4 of epic #49): every example the root
`hetoimasia-tests` suite registered at the base revision `fb2e1fa`, and the one
place it is registered after the foundation contracts moved into
`hetoimasia-foundation:foundation-tests`.

## Method

Both inventories are Hspec's own dry-run tree, not a count of `it` blocks:

```bash
cabal test hetoimasia-tests --test-show-details=direct --test-options='--dry-run --format=specdoc'
cabal test hetoimasia-foundation:foundation-tests --test-show-details=direct --test-options='--dry-run --format=specdoc'
```

The first ran at the base revision and again on this branch; the second ran on
this branch. Each example is identified by its full path of group names. A script
matched every base path to exactly one destination path and checked the result
in both directions: no base example is unmatched, no destination example is
matched twice, and neither suite registers an example with no base counterpart.

| | Examples |
|---|---:|
| Base `hetoimasia-tests` | 517 |
| `foundation-tests` after the move | 308 |
| `hetoimasia-tests` after the move | 209 |

Paths are unchanged except for two deliberate moves into the root `Runtime`
group, where they stay until TEST-5 moves them into the runtime package:

- `Resources / Console resource smoke / …` becomes
  `Runtime / Console resource smoke / …` (10 examples).
- The six supervised `Messaging / Channel composition / …` and
  `Messaging / Snapshot composition / …` examples become
  `Runtime / Channel composition / …` and `Runtime / Snapshot composition / …`.
  The unsupervised examples of both groups stay in `foundation-tests` under
  their original paths.

## Summary by base group

| Base group | Base examples | `foundation-tests` | `hetoimasia-tests` |
|---|---:|---:|---:|
| `Logging` | 49 | 49 | 0 |
| `Resources` | 146 | 136 | 10 |
| `Failures` | 26 | 26 | 0 |
| `Recovery` | 23 | 23 | 0 |
| `Workers` | 23 | 23 | 0 |
| `Messaging` | 57 | 51 | 6 |
| `Runtime` | 138 | 0 | 138 |
| `GLFW` | 55 | 0 | 55 |

## Examples

### Logging

| Base path | Suite | Path after the move |
|---|---|---|
| Logging / Component / accepts lowercase dotted names | `foundation-tests` | unchanged |
| Logging / Component / rejects malformed and reserved names | `foundation-tests` | unchanged |
| Logging / Logger filtering / filters before invoking the sink | `foundation-tests` | unchanged |
| Logging / Logger filtering / suppresses everything when the master switch is off | `foundation-tests` | unchanged |
| Logging / Logger filtering / applies the global threshold | `foundation-tests` | unchanged |
| Logging / Logger filtering / applies exact per-component thresholds | `foundation-tests` | unchanged |
| Logging / Logger filtering / enables Debug only through the Debug selection | `foundation-tests` | unchanged |
| Logging / Logger filtering / preserves sink failures | `foundation-tests` | unchanged |
| Logging / Logger metadata / gates payloads and providers for a suppressed entry | `foundation-tests` | unchanged |
| Logging / Logger context / resolves field precedence and breadcrumb order | `foundation-tests` | unchanged |
| Logging / Logger context / keeps concurrent worker context and thread identity separate | `foundation-tests` | unchanged |
| Logging / Logger source attribution / reports the call site outside a wrapper | `foundation-tests` | unchanged |
| Logging / Logger source attribution / reports no location when the source switch is off | `foundation-tests` | unchanged |
| Logging / Record layout / renders the fixed-metadata examples | `foundation-tests` | unchanged |
| Logging / Record layout / omits absent segments and sorts fields by key | `foundation-tests` | unchanged |
| Logging / Record layout / omits the thread segment when the option is off | `foundation-tests` | unchanged |
| Logging / Record layout / quotes and escapes text that would disturb the layout | `foundation-tests` | unchanged |
| Logging / Record layout / passes non-ASCII text through unchanged | `foundation-tests` | unchanged |
| Logging / Record layout / quotes and escapes the source filename | `foundation-tests` | unchanged |
| Logging / Record layout / renders empty text as a pair of quotes | `foundation-tests` | unchanged |
| Logging / Record layout / keeps an unvalidated field key from disturbing the layout | `foundation-tests` | unchanged |
| Logging / Record layout / truncates the timestamp to three fractional digits | `foundation-tests` | unchanged |
| Logging / Handle sink / terminates each record itself | `foundation-tests` | unchanged |
| Logging / Handle sink / keeps concurrent records intact and in per-producer order | `foundation-tests` | unchanged |
| Logging / Handle sink / flushes every entry by default, and on demand when it does not | `foundation-tests` | unchanged |
| Logging / Handle sink / leaves the borrowed handle open, writable, and unchanged | `foundation-tests` | unchanged |
| Logging / Handle sink / serializes two independently constructed roots | `foundation-tests` | unchanged |
| Logging / Handle sink / propagates a write failure and releases its serialization state | `foundation-tests` | unchanged |
| Logging / Handle sink / propagates an interruption and releases its serialization state | `foundation-tests` | unchanged |
| Logging / Handle sink / propagates a flush failure and releases its serialization state | `foundation-tests` | unchanged |
| Logging / Callback sink / defaults to a no-op flush and runs a supplied one | `foundation-tests` | unchanged |
| Logging / Callback sink / propagates callback and flush failures without disabling the sink | `foundation-tests` | unchanged |
| Logging / Worker reporting boundary / emits the success diagnostic for completed work | `foundation-tests` | unchanged |
| Logging / Worker reporting boundary / reports an ordinary failure once and ends the worker | `foundation-tests` | unchanged |
| Logging / Worker reporting boundary / propagates cancellation delivered to blocked work, unreported | `foundation-tests` | unchanged |
| Logging / Worker reporting boundary / keeps the work's exception when its report fails | `foundation-tests` | unchanged |
| Logging / Worker reporting boundary / propagates cancellation delivered while the report blocks | `foundation-tests` | unchanged |
| Logging / Worker reporting boundary / propagates a failing success diagnostic | `foundation-tests` | unchanged |
| Logging / Configuration parsing / accepts every level spelling and rejects the rest | `foundation-tests` | unchanged |
| Logging / Configuration parsing / parses exact per-component overrides | `foundation-tests` | unchanged |
| Logging / Configuration parsing / rejects a malformed override list | `foundation-tests` | unchanged |
| Logging / Configuration parsing / parses the Debug selection and collapses repeats | `foundation-tests` | unchanged |
| Logging / Configuration parsing / rejects a malformed Debug selection | `foundation-tests` | unchanged |
| Logging / Configuration parsing / quotes and escapes a rejected value in its message | `foundation-tests` | unchanged |
| Logging / Startup configuration / keeps every default when no variable is present | `foundation-tests` | unchanged |
| Logging / Startup configuration / assembles the filter from all three variables | `foundation-tests` | unchanged |
| Logging / Startup configuration / names the variable an invalid value came from | `foundation-tests` | unchanged |
| Logging / Startup configuration / leaves the master and source switches programmatic | `foundation-tests` | unchanged |
| Logging / Startup configuration / consults each variable exactly once and nothing afterwards | `foundation-tests` | unchanged |

### Resources

| Base path | Suite | Path after the move |
|---|---|---|
| Resources / Resource scope outcomes / returns the body's result when the body and the release both succeed | `foundation-tests` | unchanged |
| Resources / Resource scope outcomes / propagates the body's failure unchanged when the release succeeds | `foundation-tests` | unchanged |
| Resources / Resource scope outcomes / propagates a cancellation recognizable by a typed catch | `foundation-tests` | unchanged |
| Resources / Resource scope outcomes / fails with the release's exception and discards the result when only the release fails | `foundation-tests` | unchanged |
| Resources / Resource scope outcomes / propagates the body's failure and retains the release failure when both fail | `foundation-tests` | unchanged |
| Resources / Resource scope outcomes / propagates a failed acquisition and runs no release | `foundation-tests` | unchanged |
| Resources / Resource scope nesting / retains nested cleanup failures in the order they were observed | `foundation-tests` | unchanged |
| Resources / Resource scope nesting / keeps two cleanup failures that render identically distinct | `foundation-tests` | unchanged |
| Resources / Resource scope nesting / retains the first cleanup exception once when only the releases fail | `foundation-tests` | unchanged |
| Resources / Resource scope nesting / attempts each registered release exactly once per scope exit | `foundation-tests` | unchanged |
| Resources / Resource scope nesting / surfaces evidence a release carried out of its own scope | `foundation-tests` | unchanged |
| Resources / Resource scope mask discipline / cancels an acquisition blocked on an MVar and runs no release | `foundation-tests` | unchanged |
| Resources / Resource scope mask discipline / runs the release for a cancellation delivered after acquisition | `foundation-tests` | unchanged |
| Resources / Resource scope mask discipline / restores the caller's masking state after an inner scope completes normally | `foundation-tests` | unchanged |
| Resources / Resource scope mask discipline / defers an asynchronous exception aimed at a release until that unwind's releases finish | `foundation-tests` | unchanged |
| Resources / Resource scope mask discipline / retains an exception a release raises and still attempts the remaining releases | `foundation-tests` | unchanged |
| Resources / Resource scope evidence retention / keeps an annotation from inside the scope reachable when the release succeeds | `foundation-tests` | unchanged |
| Resources / Resource scope evidence retention / keeps an annotation from inside the scope reachable when the release also fails | `foundation-tests` | unchanged |
| Resources / Resource scope evidence retention / keeps an annotation from inside the release reachable above the scope | `foundation-tests` | unchanged |
| Resources / Resource scope evidence retention / recognizes the original exception type through a context-aware typed catch | `foundation-tests` | unchanged |
| Resources / Resource scope evidence retention / finds evidence through a caller's plain catch and rethrow | `foundation-tests` | unchanged |
| Resources / Resource scope evidence retention / reports evidence reached by two routes exactly once | `foundation-tests` | unchanged |
| Resources / Resource scope evidence retention / reports new evidence standing beside evidence already reached | `foundation-tests` | unchanged |
| Resources / Resource scope evidence retention / loses evidence through a bare typed try | `foundation-tests` | unchanged |
| Resources / Resource scope evidence retention / loses evidence through a try followed by a plain throwIO | `foundation-tests` | unchanged |
| Resources / Resource scope owned handles / closes a temporary file handle the scope owns | `foundation-tests` | unchanged |
| Resources / Composite construction / releases nothing when the first acquisition fails | `foundation-tests` | unchanged |
| Resources / Composite construction / releases the part acquired so far when a restored step fails | `foundation-tests` | unchanged |
| Resources / Composite construction / releases the part acquired so far when the second acquisition fails | `foundation-tests` | unchanged |
| Resources / Composite construction / releases both parts in the declared order when the binding step fails | `foundation-tests` | unchanged |
| Resources / Composite construction / lends the finished value and releases it in the declared order | `foundation-tests` | unchanged |
| Resources / Composite construction / declares an order that is acquisition order for a buffer and its memory | `foundation-tests` | unchanged |
| Resources / Composite construction / declares an order that is not acquisition order when the constructor says so | `foundation-tests` | unchanged |
| Resources / Composite construction / attempts the remaining releases after a rollback release throws | `foundation-tests` | unchanged |
| Resources / Composite construction / releases each part once and lets no finished value reach the caller | `foundation-tests` | unchanged |
| Resources / Composite part metadata / releases the parts acquired before a faulting rank and acquires nothing at that stage | `foundation-tests` | unchanged |
| Resources / Composite part metadata / releases the parts acquired before a faulting label and acquires nothing at that stage | `foundation-tests` | unchanged |
| Resources / Composite part metadata / rejects a faulting rank before the later stage that would have failed runs | `foundation-tests` | unchanged |
| Resources / Composite part metadata / rejects a faulting label before the later stage that would have failed runs | `foundation-tests` | unchanged |
| Resources / Composite part metadata / attempts every remaining release after a faulting rank and retains the labelled evidence | `foundation-tests` | unchanged |
| Resources / Composite part metadata / attempts every remaining release after a faulting label and retains the labelled evidence | `foundation-tests` | unchanged |
| Resources / Composite part metadata / keeps an enclosing body's failure primary when a faulting rank fails its release | `foundation-tests` | unchanged |
| Resources / Composite part metadata / keeps an enclosing body's failure primary when a faulting label fails its release | `foundation-tests` | unchanged |
| Resources / Composite part metadata / keeps an earlier stage's failure primary and never evaluates a later part's metadata | `foundation-tests` | unchanged |
| Resources / Composite part metadata / closes the handles it owns when a later part's metadata faults | `foundation-tests` | unchanged |
| Resources / Composite construction cancellation / rolls back the parts acquired so far when cancelled in a restored step | `foundation-tests` | unchanged |
| Resources / Composite construction cancellation / rolls back the parts acquired so far when cancelled inside an acquisition | `foundation-tests` | unchanged |
| Resources / Composite construction cancellation / rolls back a part acquired with a cancellation already pending | `foundation-tests` | unchanged |
| Resources / Composite construction cancellation / defers a cancellation aimed at a rollback until every release has run | `foundation-tests` | unchanged |
| Resources / Composite construction inside a scope / lets the enclosing scope observe the composite's primary and retained failures | `foundation-tests` | unchanged |
| Resources / Composite construction inside a scope / fails with the first cleanup exception when the final releases fail | `foundation-tests` | unchanged |
| Resources / Composite construction inside a scope / keeps the body's failure primary when the final releases also fail | `foundation-tests` | unchanged |
| Resources / Continuation facade / keeps an allocation live in the final callback and releases it when that callback exits | `foundation-tests` | unchanged |
| Resources / Continuation facade / releases a scope's allocations in reverse allocation order on success | `foundation-tests` | unchanged |
| Resources / Continuation facade / releases a scope's allocations in reverse allocation order when the scope fails | `foundation-tests` | unchanged |
| Resources / Continuation facade / releases a scope's allocations in reverse allocation order on cancellation | `foundation-tests` | unchanged |
| Resources / Continuation facade / runs no later acquisition after an earlier action fails | `foundation-tests` | unchanged |
| Resources / Continuation facade / runs ordinary actions inside a scope through MonadIO | `foundation-tests` | unchanged |
| Resources / Continuation facade / composes allocations through fmap and <*> | `foundation-tests` | unchanged |
| Resources / Continuation facade agreement with the direct path / produces the same primary and secondary failures for one resource | `foundation-tests` | unchanged |
| Resources / Continuation facade agreement with the direct path / produces the same primary and secondary failures for nested resources | `foundation-tests` | unchanged |
| Resources / Continuation facade nested scopes / releases everything locally allocated before the outer scope resumes | `foundation-tests` | unchanged |
| Resources / Continuation facade nested scopes / carries a locally cleanup failure into the outer scope's evidence | `foundation-tests` | unchanged |
| Resources / Continuation facade composite allocation / keeps each composite's declared order while the scope unwinds in reverse | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Component convention / observes a configuration fault before any acquisition | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Component convention / reaches private state only through the handle | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Policy and budget / rejects an invalid policy before any effect | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Policy and budget / exhausts one budget across alternatives without resetting it | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Selection / selects the initial alternative with no history | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Selection / releases exactly a failed attempt's parts in declared order before the classifier and the next alternative | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Selection / keeps a fallback handle live for the whole consumer and runs the consumer once | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Selection / binds exhausted optional construction as unavailable data the consumer branches on | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Selection / propagates required exhaustion with every earlier attempt's origin and cleanup evidence in order | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Failures that stop construction / propagates an unrecognized failure unchanged | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Failures that stop construction / propagates an attempt with cleanup evidence without classifying it | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Failures that stop construction / stops on a classifier failure, keeping the handled failure as context | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Cancellation / escapes cancellation during construction with its rollback evidence | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Cancellation / defers cancellation during rollback until every release is attempted, then escapes with its evidence | `foundation-tests` | unchanged |
| Resources / Scoped component construction / Cancellation / releases every part when cancellation preempts the consumer at the protected handoff | `foundation-tests` | unchanged |
| Resources / Scoped component construction / After selection / propagates a consumer failure with cleanup evidence and no further attempt | `foundation-tests` | unchanged |
| Resources / Scoped component construction / After selection / treats a lazy result forced in the consumer as a consumer failure | `foundation-tests` | unchanged |
| Resources / Scoped component construction / After selection / fails with the final release's exception after a successful consumer, with no further attempt | `foundation-tests` | unchanged |
| Resources / Scoped component construction / After selection / never restarts construction when the consumer of an unavailable value fails | `foundation-tests` | unchanged |
| Resources / Resource collection admission / rejects a limit below one before the body runs | `foundation-tests` | unchanged |
| Resources / Resource collection admission / rejects acquisition at the live-member limit before the assembly runs, and reuses a retired slot | `foundation-tests` | unchanged |
| Resources / Resource collection admission / rolls back a failing stage, registers no member, consumes no capacity, and does not poison | `foundation-tests` | unchanged |
| Resources / Resource collection admission / rolls back a member cancelled during its assembly | `foundation-tests` | unchanged |
| Resources / Resource collection admission / registers a member whose acquisition returns with a cancellation pending, and releases it at exit | `foundation-tests` | unchanged |
| Resources / Resource collection admission / rolls back a member cancelled during its assembly before its handoff runs | `foundation-tests` | unchanged |
| Resources / Resource collection admission / runs the handoff masked in the registering step, delivering a pending cancellation only after it | `foundation-tests` | unchanged |
| Resources / Resource collection admission / keeps a member registered when its handoff raises, releasing it at exit | `foundation-tests` | unchanged |
| Resources / Resource collection borrowing and retirement / retires a middle member while its neighbours stay live | `foundation-tests` | unchanged |
| Resources / Resource collection borrowing and retirement / treats a repeated successful retirement as inert and calls the release once | `foundation-tests` | unchanged |
| Resources / Resource collection borrowing and retirement / reports the stored failure on a repeated failed retirement without calling the release again | `foundation-tests` | unchanged |
| Resources / Resource collection borrowing and retirement / answers in use while a member is borrowed, then retires it after the borrow ends | `foundation-tests` | unchanged |
| Resources / Resource collection borrowing and retirement / lets a borrowing callback borrow another live member | `foundation-tests` | unchanged |
| Resources / Resource collection borrowing and retirement / runs a borrowing callback with the caller's masking state | `foundation-tests` | unchanged |
| Resources / Resource collection borrowing and retirement / drops a borrow when its callback fails | `foundation-tests` | unchanged |
| Resources / Resource collection borrowing and retirement / drops a borrow when its callback is cancelled | `foundation-tests` | unchanged |
| Resources / Resource collection misuse / rejects every owner operation from another thread before any effect | `foundation-tests` | unchanged |
| Resources / Resource collection misuse / rejects a token from another collection before any effect | `foundation-tests` | unchanged |
| Resources / Resource collection misuse / rejects acquisition, borrowing, and retirement re-entered from an assembly | `foundation-tests` | unchanged |
| Resources / Resource collection misuse / rejects acquisition and retirement of other members from a borrowing callback | `foundation-tests` | unchanged |
| Resources / Resource collection misuse / rejects retirement of other terminal members from a borrowing callback | `foundation-tests` | unchanged |
| Resources / Resource collection misuse / rejects acquisition, borrowing, and retirement re-entered from an early release | `foundation-tests` | unchanged |
| Resources / Resource collection misuse / rejects acquisition, borrowing, and retirement re-entered from a release at exit | `foundation-tests` | unchanged |
| Resources / Resource collection terminal tokens / reports terminal states after the collection exits and rejects the closed collection | `foundation-tests` | unchanged |
| Resources / Resource collection terminal tokens / releases a failed early retirement's payload while its token keeps only the failure | `foundation-tests` | unchanged |
| Resources / Resource collection terminal tokens / reports a release that failed at exit through the retained token, which keeps only the failure | `foundation-tests` | unchanged |
| Resources / Resource collection terminal tokens / keeps owner bookkeeping and payloads bounded by live members across open and retire cycles | `foundation-tests` | unchanged |
| Resources / Resource collection cleanup failures / fails the exit with a caught early-retirement failure and still releases the remaining members | `foundation-tests` | unchanged |
| Resources / Resource collection cleanup failures / keeps the body's failure primary beside early and final cleanup evidence | `foundation-tests` | unchanged |
| Resources / Resource collection cleanup failures / keeps a cancellation of the body primary beside the collection's evidence | `foundation-tests` | unchanged |
| Resources / Resource collection cleanup failures / poisons acquisition after a failing rollback and makes a successful body's exit fail with it | `foundation-tests` | unchanged |
| Resources / Resource collection cleanup failures / keeps the body's failure primary over a latched rollback failure | `foundation-tests` | unchanged |
| Resources / Resource collection cleanup failures / releases remaining members in reverse registration order with each member's declared ranks | `foundation-tests` | unchanged |
| Resources / Resource collection cleanup failures / fails a successful body's exit with the first final release failure and attempts the rest | `foundation-tests` | unchanged |
| Resources / Resource evidence inspection cost / at twenty nested releases / bounds what cleanupFailures allocates | `foundation-tests` | unchanged |
| Resources / Resource evidence inspection cost / at twenty nested releases / bounds what cleanupFailuresInContext allocates | `foundation-tests` | unchanged |
| Resources / Resource evidence inspection cost / at forty nested releases / bounds what cleanupFailures allocates | `foundation-tests` | unchanged |
| Resources / Resource evidence inspection cost / at forty nested releases / bounds what cleanupFailuresInContext allocates | `foundation-tests` | unchanged |
| Resources / Scoped opacity across the package boundary / rejects a client that replaces the continuation with record update | `foundation-tests` | unchanged |
| Resources / Scoped opacity across the package boundary / rejects a client that names the constructor | `foundation-tests` | unchanged |
| Resources / Scoped opacity across the package boundary / accepts and runs a client using only the runner and the allocators | `foundation-tests` | unchanged |
| Resources / Cleanup evidence opacity across the package boundary / rejects a client that replaces an entry's identity with record update | `foundation-tests` | unchanged |
| Resources / Cleanup evidence opacity across the package boundary / rejects a client that replaces an entry's label with record update | `foundation-tests` | unchanged |
| Resources / Cleanup evidence opacity across the package boundary / rejects a client that replaces an entry's exception with record update | `foundation-tests` | unchanged |
| Resources / Cleanup evidence opacity across the package boundary / rejects a client that names the entry constructor | `foundation-tests` | unchanged |
| Resources / Cleanup evidence opacity across the package boundary / accepts and runs a client using only the readers and reattachment | `foundation-tests` | unchanged |
| Resources / Collection opacity across the package boundary / rejects a client that names the collection constructor | `foundation-tests` | unchanged |
| Resources / Collection opacity across the package boundary / rejects a client that names the member token constructor | `foundation-tests` | unchanged |
| Resources / Collection opacity across the package boundary / rejects a client that rewrites a collection with record update | `foundation-tests` | unchanged |
| Resources / Collection opacity across the package boundary / rejects a client that rewrites a member token with record update | `foundation-tests` | unchanged |
| Resources / Collection opacity across the package boundary / rejects a client that coerces a member token to another type with the same representation | `foundation-tests` | unchanged |
| Resources / Collection opacity across the package boundary / rejects a client that reaches for a member's release through the implementation module | `foundation-tests` | unchanged |
| Resources / Collection opacity across the package boundary / accepts and runs a client using only the public collection operations | `foundation-tests` | unchanged |
| Resources / Console resource smoke / Injected failures / releases everything and reports once when the injected work fails | `hetoimasia-tests` | Runtime / Console resource smoke / Injected failures / releases everything and reports once when the injected work fails |
| Resources / Console resource smoke / Injected failures / propagates a release failure with its evidence and reports it once | `hetoimasia-tests` | Runtime / Console resource smoke / Injected failures / propagates a release failure with its evidence and reports it once |
| Resources / Console resource smoke / Injected failures / keeps the work's failure and the ordered evidence when the report also fails | `hetoimasia-tests` | Runtime / Console resource smoke / Injected failures / keeps the work's failure and the ordered evidence when the report also fails |
| Resources / Console resource smoke / Injected failures / releases everything and reports nothing when a lifecycle record's sink fails | `hetoimasia-tests` | Runtime / Console resource smoke / Injected failures / releases everything and reports nothing when a lifecycle record's sink fails |
| Resources / Console resource smoke / Injected failures / reports a work failure through a sink that only the lifecycle records broke | `hetoimasia-tests` | Runtime / Console resource smoke / Injected failures / reports a work failure through a sink that only the lifecycle records broke |
| Resources / Console resource smoke / Injected failures / propagates cancellation delivered to the work, unreported | `hetoimasia-tests` | Runtime / Console resource smoke / Injected failures / propagates cancellation delivered to the work, unreported |
| Resources / Console resource smoke / Injected failures / propagates cancellation delivered while the report blocks | `hetoimasia-tests` | Runtime / Console resource smoke / Injected failures / propagates cancellation delivered while the report blocks |
| Resources / Console resource smoke / Injected failures / keeps the annotation of a cancellation the report itself raised | `hetoimasia-tests` | Runtime / Console resource smoke / Injected failures / keeps the annotation of a cancellation the report itself raised |
| Resources / Console resource smoke / Injected failures / keeps the cleanup evidence of a cancellation delivered while reporting | `hetoimasia-tests` | Runtime / Console resource smoke / Injected failures / keeps the cleanup evidence of a cancellation delivered while reporting |
| Resources / Console resource smoke / Sink disposal / writes every cleanup record before the test closes the handle it owns | `hetoimasia-tests` | Runtime / Console resource smoke / Sink disposal / writes every cleanup record before the test closes the handle it owns |

### Failures

| Base path | Suite | Path after the move |
|---|---|---|
| Failures / Failure origin / keeps the original exception type and payload for a typed catch | `foundation-tests` | unchanged |
| Failures / Failure origin / records the component, operation, identifiers, and call site | `foundation-tests` | unchanged |
| Failures / Failure origin / attributes a wrapper that declares HasCallStack to its own caller | `foundation-tests` | unchanged |
| Failures / Failure origin / matches the original type through nested withResource, withComposite, and Scoped scopes | `foundation-tests` | unchanged |
| Failures / Failure origin / raises from inside a Scoped block through MonadIO | `foundation-tests` | unchanged |
| Failures / Operation context / adds outer context in attachment order without replacing the origin | `foundation-tests` | unchanged |
| Failures / Operation context / keeps the origin when a later handler rethrows preservingly | `foundation-tests` | unchanged |
| Failures / Operation context / loses the evidence through a typed try followed by a plain throwIO | `foundation-tests` | unchanged |
| Failures / Native causes / keeps a library IOException's type and payload and records no throw site | `foundation-tests` | unchanged |
| Failures / Native causes / distinguishes an engine origin from a native cause | `foundation-tests` | unchanged |
| Failures / Resource contracts beside origin evidence / retains cleanup failures beside an origin-annotated primary failure | `foundation-tests` | unchanged |
| Failures / Resource contracts beside origin evidence / leaves a delivered cancellation unannotated with its context intact | `foundation-tests` | unchanged |
| Failures / Resource contracts beside origin evidence / leaves an asynchronous exception raised synchronously unannotated | `foundation-tests` | unchanged |
| Failures / Resource contracts beside origin evidence / records no origin for an asynchronous exception passed to throwFailure | `foundation-tests` | unchanged |
| Failures / Failure inspection / reads immutable evidence after its scope closed, with no logger | `foundation-tests` | unchanged |
| Failures / Failure inspection / renders hostile operation and identifier text on one escaped line | `foundation-tests` | unchanged |
| Failures / Failures inside STM / is caught by its own type with catchSTM and outside atomically | `foundation-tests` | unchanged |
| Failures / Failures inside STM / records the component, operation, identifiers, and call site | `foundation-tests` | unchanged |
| Failures / Failures inside STM / attributes a wrapper that declares HasCallStack to its own caller | `foundation-tests` | unchanged |
| Failures / Failures inside STM / exposes evidence to a SomeException handler but not to a typed handler's value | `foundation-tests` | unchanged |
| Failures / Failures inside STM / gains context from an enclosing withOperationContext once it escapes atomically | `foundation-tests` | unchanged |
| Failures / Failures inside STM / keeps an annotation the cause already carried | `foundation-tests` | unchanged |
| Failures / Failures inside STM / keeps an earlier origin and its ordered contexts | `foundation-tests` | unchanged |
| Failures / Failures inside STM / records no origin for an asynchronous cause and keeps its context | `foundation-tests` | unchanged |
| Failures / Failures inside STM / raises a faulting identifier's own exception instead of the failure | `foundation-tests` | unchanged |
| Failures / Failures inside STM / rolls back an escaping transaction and only the caught action's writes | `foundation-tests` | unchanged |

### Recovery

| Base path | Suite | Path after the move |
|---|---|---|
| Recovery / Complete owned operations / finishes a failed attempt's release before the wait and the fallback start | `foundation-tests` | unchanged |
| Recovery / Complete owned operations / leaves an enclosing scope's resource valid after recovery | `foundation-tests` | unchanged |
| Recovery / Complete owned operations / returns a first-attempt success without consulting the classifier | `foundation-tests` | unchanged |
| Recovery / Complete owned operations / evaluates the result inside the attempt | `foundation-tests` | unchanged |
| Recovery / Complete owned operations / neither catches nor retries a caller failure after the boundary, and runs it once | `foundation-tests` | unchanged |
| Recovery / Policy and budget / rejects a non-positive budget before any effect | `foundation-tests` | unchanged |
| Recovery / Policy and budget / exhausts one budget across a retry-then-fallback strategy change | `foundation-tests` | unchanged |
| Recovery / Outcomes / recovers by retry with its status and history | `foundation-tests` | unchanged |
| Recovery / Outcomes / propagates required exhaustion with earlier attempts, origins, and cleanup evidence in order | `foundation-tests` | unchanged |
| Recovery / Outcomes / returns an explicit unavailable outcome for exhausted optional work | `foundation-tests` | unchanged |
| Recovery / Failures that stop recovery / propagates an unrecognized first failure unchanged | `foundation-tests` | unchanged |
| Recovery / Failures that stop recovery / propagates an attempt with cleanup evidence without classifying it | `foundation-tests` | unchanged |
| Recovery / Failures that stop recovery / stops on a classifier failure, keeping the handled failure as context | `foundation-tests` | unchanged |
| Recovery / Failures that stop recovery / stops on a wait failure, keeping the handled failure as context | `foundation-tests` | unchanged |
| Recovery / Failures that stop recovery / keeps earlier history when a later failure is unrecognized | `foundation-tests` | unchanged |
| Recovery / Failures that stop recovery / keeps earlier history when the terminal attempt's cleanup fails | `foundation-tests` | unchanged |
| Recovery / Optional work with a budget of one / does not downgrade an unrecognized failure | `foundation-tests` | unchanged |
| Recovery / Optional work with a budget of one / does not downgrade a cleanup failure or classify it | `foundation-tests` | unchanged |
| Recovery / Optional work with a budget of one / does not downgrade a cancellation or classify it | `foundation-tests` | unchanged |
| Recovery / Cancellation / escapes cancellation during work with its own context and cleanup evidence | `foundation-tests` | unchanged |
| Recovery / Cancellation / escapes cancellation during classification | `foundation-tests` | unchanged |
| Recovery / Cancellation / escapes cancellation during the wait | `foundation-tests` | unchanged |
| Recovery / Cancellation / escapes cancellation during a fallback | `foundation-tests` | unchanged |

### Workers

| Base path | Suite | Path after the move |
|---|---|---|
| Workers / Startup / acknowledges startup after initialization and keeps the worker's resources live for its run | `foundation-tests` | unchanged |
| Workers / Startup / reports a typed startup failure retaining its origin and cleanup evidence | `foundation-tests` | unchanged |
| Workers / Startup / publishes cancellation during startup as run-not-entered without inventing a run exit | `foundation-tests` | unchanged |
| Workers / Startup / drains a child whose starter is cancelled before the starter's dependencies are released | `foundation-tests` | unchanged |
| Workers / Startup / prepares before any child code and drains the child when a composed wait fails | `foundation-tests` | unchanged |
| Workers / Startup / cancels and drains the fork it owns when preparation fails | `foundation-tests` | unchanged |
| Workers / Startup / reports acknowledgement and completion ready together | `foundation-tests` | unchanged |
| Workers / Requests and observation / keeps a repeated stop request idempotent and records it at exit | `foundation-tests` | unchanged |
| Workers / Requests and observation / delivers repeated cancellation requests through one owned helper | `foundation-tests` | unchanged |
| Workers / Requests and observation / lets an observer be cancelled without cancelling or joining the worker | `foundation-tests` | unchanged |
| Workers / Requests and observation / reports a worker's cancellation to an observer without cancelling the observer | `foundation-tests` | unchanged |
| Workers / Requests and observation / publishes completion after cleanup, identically to several readers | `foundation-tests` | unchanged |
| Workers / Closing and drain / requests every stop before waiting for any worker | `foundation-tests` | unchanged |
| Workers / Closing and drain / rejects a start after closing without forking | `foundation-tests` | unchanged |
| Workers / Closing and drain / synchronizes registration with closing | `foundation-tests` | unchanged |
| Workers / Closing and drain / keeps a run exit before the stop request recorded when the request lands during cleanup | `foundation-tests` | unchanged |
| Workers / Closing and drain / snapshots an outcome published before closing as exited rather than stopped | `foundation-tests` | unchanged |
| Workers / Closing and drain / cancels live workers on owner failure and propagates that failure after their cleanup | `foundation-tests` | unchanged |
| Workers / Closing and drain / keeps draining through a further cancellation of the owner | `foundation-tests` | unchanged |
| Workers / Closing and drain / keeps the parent alive for a worker that ignores its stop request until it is released | `foundation-tests` | unchanged |
| Workers / Closing and drain / keeps the parent alive while a cancellation delivery blocks, until the worker is released | `foundation-tests` | unchanged |
| Workers / Retirement / retires observed workers while retained handles keep their results | `foundation-tests` | unchanged |
| Workers / Retirement / keeps an observed failure through retirement and an exceptional group exit | `foundation-tests` | unchanged |

### Messaging

| Base path | Suite | Path after the move |
|---|---|---|
| Messaging / Payload preparation / raises a throwing thunk nested in a lazy field during preparation with its own type | `foundation-tests` | unchanged |
| Messaging / Payload preparation / reads a prepared payload back unchanged and never evaluates it again | `foundation-tests` | unchanged |
| Messaging / Payload preparation failures / keeps a typed engine failure's type, origin, and operation context | `foundation-tests` | unchanged |
| Messaging / Payload preparation failures / keeps a native IOException's type and operation context | `foundation-tests` | unchanged |
| Messaging / Payload preparation failures / ends a preparation cancelled from another thread by cancellation | `foundation-tests` | unchanged |
| Messaging / Channel construction / rejects zero, negative, and above-maximum capacities with a typed failure and engine origin | `foundation-tests` | unchanged |
| Messaging / Channel admission and order / receives entries in the order their admissions committed | `foundation-tests` | unchanged |
| Messaging / Channel admission and order / keeps each of several concurrent producers' entries in order | `foundation-tests` | unchanged |
| Messaging / Channel admission and order / accepts up to capacity and then reports Full with the queue and counters unchanged | `foundation-tests` | unchanged |
| Messaging / Channel admission and order / reports Closed rather than Full once admission has ended by close or abort | `foundation-tests` | unchanged |
| Messaging / Channel close and abort / drains a closed channel in order and then reports the end of the stream | `foundation-tests` | unchanged |
| Messaging / Channel close and abort / discards only queued entries, strengthens close, and returns zero when repeated | `foundation-tests` | unchanged |
| Messaging / Channel close and abort / wakes blocked waiting sends and receives on close and on abort with the terminal result | `foundation-tests` | unchanged |
| Messaging / Channel close and abort / releases a blocked waiting send by one dequeue and a blocked waiting receive by one admission | `foundation-tests` | unchanged |
| Messaging / Channel counters and transactions / conserves accepted entries and keeps high-water monotone through contention, rollback, failed admission, drain, and abort | `foundation-tests` | unchanged |
| Messaging / Channel counters and transactions / never delivers an entry whose admission rolled back | `foundation-tests` | unchanged |
| Messaging / Channel counters and transactions / forwards a received prepared payload to another channel without evaluating it again | `foundation-tests` | unchanged |
| Messaging / Channel composition / leaves a blocked waiting send through a worker's stop request with the channel unchanged | `foundation-tests` | unchanged |
| Messaging / Channel composition / leaves a blocked waiting receive through a worker's stop request with the channel unchanged | `foundation-tests` | unchanged |
| Messaging / Channel composition / settles a nonfatal worker outcome before a ready supervised receive, then receives the entry once | `hetoimasia-tests` | Runtime / Channel composition / settles a nonfatal worker outcome before a ready supervised receive, then receives the entry once |
| Messaging / Channel composition / settles a nonfatal worker outcome before a newly possible supervised send, then admits it once | `hetoimasia-tests` | Runtime / Channel composition / settles a nonfatal worker outcome before a newly possible supervised send, then admits it once |
| Messaging / Channel composition / never commits a ready supervised receive while a fatal worker failure is pending | `hetoimasia-tests` | Runtime / Channel composition / never commits a ready supervised receive while a fatal worker failure is pending |
| Messaging / Channel composition / never commits a possible supervised send while a fatal worker failure is pending | `hetoimasia-tests` | Runtime / Channel composition / never commits a possible supervised send while a fatal worker failure is pending |
| Messaging / Snapshot publication / observes the initial value at revision zero before any publication | `foundation-tests` | unchanged |
| Messaging / Snapshot publication / advances the revision for a publication of an equal value | `foundation-tests` | unchanged |
| Messaging / Snapshot publication / delivers the newest publication to each waiting reader without acknowledging for the others | `foundation-tests` | unchanged |
| Messaging / Snapshot publication / never pairs a value with another publication's revision under concurrent publication and reads | `foundation-tests` | unchanged |
| Messaging / Snapshot publication / leaves value and revision unchanged when a publication rolls back | `foundation-tests` | unchanged |
| Messaging / Snapshot publication / publishes an observed prepared payload to another snapshot without evaluating it again | `foundation-tests` | unchanged |
| Messaging / Snapshot close / delivers an unseen final publication before end-of-stream and keeps the final value | `foundation-tests` | unchanged |
| Messaging / Snapshot close / ends a waiter holding the initial cursor when closed before any publication, and again when repeated | `foundation-tests` | unchanged |
| Messaging / Snapshot close / wakes a blocked waiting read with end-of-stream | `foundation-tests` | unchanged |
| Messaging / Snapshot cursor mismatch / raises a typed failure with engine origin, without waiting, for a cursor from another snapshot at the same revision | `foundation-tests` | unchanged |
| Messaging / Snapshot composition / leaves a blocked waiting read through a worker's stop request | `foundation-tests` | unchanged |
| Messaging / Snapshot composition / settles a nonfatal worker outcome before a ready supervised waiting read commits | `hetoimasia-tests` | Runtime / Snapshot composition / settles a nonfatal worker outcome before a ready supervised waiting read commits |
| Messaging / Snapshot composition / never commits a ready supervised waiting read while a fatal worker failure is pending | `hetoimasia-tests` | Runtime / Snapshot composition / never commits a ready supervised waiting read while a fatal worker failure is pending |
| Messaging / Bounded turns / serves every input under continuously ready traffic, charging rejected and discarded entries their opportunity | `foundation-tests` | unchanged |
| Messaging / Prepared payload opacity across the package boundary / rejects a client that names the constructor | `foundation-tests` | unchanged |
| Messaging / Prepared payload opacity across the package boundary / rejects a client that replaces the payload with record update | `foundation-tests` | unchanged |
| Messaging / Prepared payload opacity across the package boundary / rejects a client that wraps an unprepared value with coerce | `foundation-tests` | unchanged |
| Messaging / Prepared payload opacity across the package boundary / rejects a client that changes the payload type with coerce between equivalent newtypes | `foundation-tests` | unchanged |
| Messaging / Prepared payload opacity across the package boundary / rejects a client that maps over a handle with fmap | `foundation-tests` | unchanged |
| Messaging / Prepared payload opacity across the package boundary / rejects a client that traverses a handle | `foundation-tests` | unchanged |
| Messaging / Prepared payload opacity across the package boundary / accepts and runs a client that prepares, reads, and forwards without NFData | `foundation-tests` | unchanged |
| Messaging / Channel endpoint authority across the package boundary / rejects a client that receives from a send endpoint | `foundation-tests` | unchanged |
| Messaging / Channel endpoint authority across the package boundary / rejects a client that closes from a send endpoint | `foundation-tests` | unchanged |
| Messaging / Channel endpoint authority across the package boundary / rejects a client that closes from a receive endpoint | `foundation-tests` | unchanged |
| Messaging / Channel endpoint authority across the package boundary / rejects a client that constructs an endpoint from its internals | `foundation-tests` | unchanged |
| Messaging / Channel endpoint authority across the package boundary / rejects a client that replaces an endpoint with record update | `foundation-tests` | unchanged |
| Messaging / Channel endpoint authority across the package boundary / accepts and runs a client using every send, receive, control, and statistics operation | `foundation-tests` | unchanged |
| Messaging / Snapshot endpoint authority across the package boundary / rejects a client that forges a cursor from its constructor | `foundation-tests` | unchanged |
| Messaging / Snapshot endpoint authority across the package boundary / rejects a client that forges an observation from its constructor | `foundation-tests` | unchanged |
| Messaging / Snapshot endpoint authority across the package boundary / rejects a client that replaces an observation's payload with record update | `foundation-tests` | unchanged |
| Messaging / Snapshot endpoint authority across the package boundary / rejects a client that replaces a publisher's read endpoint with record update | `foundation-tests` | unchanged |
| Messaging / Snapshot endpoint authority across the package boundary / rejects a client that publishes through a read endpoint | `foundation-tests` | unchanged |
| Messaging / Snapshot endpoint authority across the package boundary / rejects a client that closes through a read endpoint | `foundation-tests` | unchanged |
| Messaging / Snapshot endpoint authority across the package boundary / accepts and runs a client using every publish, read, wait, and close operation | `foundation-tests` | unchanged |

### Runtime

| Base path | Suite | Path after the move |
|---|---|---|
| Runtime / runApplication / orders events and returns the application result | `hetoimasia-tests` | unchanged |
| Runtime / runApplication / propagates failure without reporting completion | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Order / runs startup and the action on the calling thread, drains workers, then disposes dependents before dependencies | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Order / publishes an optional component's unavailability truthfully in the services value | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Partial startup and cancellation / disposes what construction acquired without running startup, then reports once before the flush | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Partial startup and cancellation / drains a worker a failing startup started before disposing its dependencies | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Partial startup and cancellation / drains workers before dependency disposal on owner cancellation, unreported and unflushed | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Truthful outcomes / never turns a caught supervised failure into a successful run | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Truthful outcomes / observes a worker failure that arrives while closing before accepting the result | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Truthful outcomes / keeps a component cleanup failure in the one terminal report, after disposal and before the flush | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Truthful outcomes / fails a successful run whose final flush fails, flushing once and reporting nothing | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Truthful outcomes / attempts no terminal report once a managed report has failed | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / releases a worker awaiting a reply from a dependency-owned service so the boundary drain completes | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / runs exactly once, with dependencies live, on every exit from the supervised region / startup callback failure | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / runs exactly once, with dependencies live, on every exit from the supervised region / post-startup checkpoint failure | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / runs exactly once, with dependencies live, on every exit from the supervised region / action failure | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / runs exactly once, with dependencies live, on every exit from the supervised region / final checkpoint failure | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / runs exactly once, with dependencies live, on every exit from the supervised region / successful action return | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / runs exactly once, with dependencies live, on every exit from the supervised region / action cancellation | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / does not run when dependency construction fails | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / precedes the boundary's stop requests on ordinary shutdown | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / may follow a stop the fatal latch already requested | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / may follow the drain of a worker whose managed startup was cancelled | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / retains its failure as cleanup evidence while an action failure stays primary | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / retains its failure as cleanup evidence while cancellation propagates unreported and unflushed | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / discards a successful result when it fails, then drains, disposes, reports, and flushes | `hetoimasia-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / leaves runScopedApplication identical to a no-op quiescence action | `hetoimasia-tests` | unchanged |
| Runtime / Console startup / emits the smoke records under the default configuration | `hetoimasia-tests` | unchanged |
| Runtime / Console startup / applies a threshold and an exact override to the smoke path | `hetoimasia-tests` | unchanged |
| Runtime / Console startup / emits the owned-resource lifecycle records on the resource-smoke path | `hetoimasia-tests` | unchanged |
| Runtime / Console startup / silences the resource-smoke path at a warn threshold | `hetoimasia-tests` | unchanged |
| Runtime / Console startup / rejects an unknown argument with a usage line naming both smoke paths | `hetoimasia-tests` | unchanged |
| Runtime / Console startup / fails before any entry for each invalid variable | `hetoimasia-tests` | unchanged |
| Runtime / Console startup / keeps a forged value from splitting the diagnostic | `hetoimasia-tests` | unchanged |
| Runtime / Console startup / keeps help visible and validates configuration on that path | `hetoimasia-tests` | unchanged |
| Runtime / Console startup / Exit mapping / exits non-zero when a runtime failure propagates out of a path | `hetoimasia-tests` | unchanged |
| Runtime / Console startup / Exit mapping / maps a cancellation to the cancellation status | `hetoimasia-tests` | unchanged |
| Runtime / Console startup / Exit mapping / passes an explicit exit status through unchanged | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Failed starts / propagates a required context failure with no endpoint and the context released | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Failed starts / rejects a start after closing without constructing anything | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Failed starts / returns an optional recognized context failure as unavailable, with no endpoint and one warning | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Failed starts / propagates owner cancellation during context construction with the context released | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Handoff and immediate exit / returns a usable endpoint from a start whose handoff is already full | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Handoff and immediate exit / closes the inbox before teardown when a service stops straight after acknowledgement | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Stop with a full inbox / aborts the backlog on an ordinary stop and retains its discard count | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Stop with a full inbox / aborts the backlog on closing's stop when the application returns | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Stop races / lets a requested stop win over a simultaneously ready message | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Stop races / completes an in-flight message once without retrying it | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Handler exceptions / fails a required service with the handler's type and context, aborting the queued messages | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Handler exceptions / fails an optional service whose classifier does not recognize the failure | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Handler exceptions / leaves a recognized optional failure unavailable with one warning, aborting the queued messages | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Handler exceptions / handles the following message after a handler recovers explicitly | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Failure evidence / closes the endpoint before teardown for a cancellation after the handoff and before any dispatch | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Failure evidence / keeps an in-flight cancellation's completion without an exit record | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Failure evidence / keeps a cleanup failure's completion without an exit record | `hetoimasia-tests` | unchanged |
| Runtime / Inbox services / Dependencies / keeps a borrowed dependency usable until the service's cleanup finishes | `hetoimasia-tests` | unchanged |
| Runtime / Inbox finish / In-flight and backlog work / handles the in-flight message and every accepted message once, in order, before acknowledging the drain | `hetoimasia-tests` | unchanged |
| Runtime / Inbox finish / Stop or cancellation before the drain / reports a stop requested before the drain as unfinished, discarding the backlog | `hetoimasia-tests` | unchanged |
| Runtime / Inbox finish / Stop or cancellation before the drain / reports a cancellation committed before the dispatch decision as unfinished, with no acknowledgement | `hetoimasia-tests` | unchanged |
| Runtime / Inbox finish / Stop or cancellation before the drain / never acknowledges a drain when a stop races the final empty-inbox observation | `hetoimasia-tests` | unchanged |
| Runtime / Inbox finish / Failures during finish / reports a recognized optional handler failure as unavailable with one warning, without waiting for a drain | `hetoimasia-tests` | unchanged |
| Runtime / Inbox finish / Failures during finish / propagates a required handler failure with its original evidence | `hetoimasia-tests` | unchanged |
| Runtime / Inbox finish / Failures during finish / propagates an unrecognized optional handler failure with its original evidence | `hetoimasia-tests` | unchanged |
| Runtime / Inbox finish / Failures during finish / propagates a cleanup failure after the drain with its evidence, keeping the acknowledgement | `hetoimasia-tests` | unchanged |
| Runtime / Inbox finish / Unrelated outcomes / settles a completed job and an unavailable optional worker during the finish wait, then finishes | `hetoimasia-tests` | unchanged |
| Runtime / Inbox finish / Cancellation after the drain / keeps the acknowledgement and the cancelled completion, is not a successful finish, and repeats nothing | `hetoimasia-tests` | unchanged |
| Runtime / Inbox finish / Owner cancellation / keeps a borrowed dependency usable until the service's cleanup finishes | `hetoimasia-tests` | unchanged |
| Runtime / Inbox finish / Combined example / publishes each handled command's state after handling it, and keeps the final snapshot readable after finish | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / returns the callback's result after one final flush | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / fails a successful run whose final flush fails | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / rethrows a callback failure after one final flush | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / keeps a callback failure primary, with its evidence, when the flush also fails | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / returns a result without flushing once a managed report has failed | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / rethrows without flushing once a managed report has failed, exposing the attempt | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / makes no flush after a marked diagnostic failed | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Cancellation / propagates a cancellation the callback raised, with its context and no flush | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Cancellation / propagates a cancellation delivered to the callback, with no flush | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Cancellation / propagates a cancellation delivered while the owner's report blocks, with no flush | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Cancellation / propagates a cancellation delivered while the final flush blocks, unretried | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Ordering / flushes after producers, scopes, and the report, outside every release | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Ordering / leaves a borrowed handle open with its buffering unchanged | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Managed resource smoke / runs the smoke records and then one final flush | `hetoimasia-tests` | unchanged |
| Runtime / Logging lifetime / Managed resource smoke / hands a failed report to the lifetime owner while the work's failure propagates | `hetoimasia-tests` | unchanged |
| Runtime / Supervised worker opacity across the package boundary / rejects a client that replaces the raw worker with record update | `hetoimasia-tests` | unchanged |
| Runtime / Supervised worker opacity across the package boundary / rejects a client that names the constructor | `hetoimasia-tests` | unchanged |
| Runtime / Supervised worker opacity across the package boundary / accepts and runs a client using the reader, completion, status, stop, and cancel | `hetoimasia-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that replaces a service's endpoint with record update | `hetoimasia-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that names the service handle's constructor | `hetoimasia-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that names the definition's constructor to build its own startup and handoff | `hetoimasia-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that takes a send endpoint from an unavailable start | `hetoimasia-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that constructs an exit record | `hetoimasia-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that updates an exit record's discard count | `hetoimasia-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that updates an exit record's drain acknowledgement | `hetoimasia-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that forges a drain acknowledgement with its constructor | `hetoimasia-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that rewrites a drain acknowledgement's handled count | `hetoimasia-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / accepts and runs a client that starts a service, sends, stops it, and reads its discard count | `hetoimasia-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / accepts and runs a client that finishes a service and reads both exit record accessors | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Levels and dispositions / warns once for a recovered result, with its attempt history | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Levels and dispositions / reports nothing for a first-attempt success | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Levels and dispositions / warns once for an exhausted optional operation | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Levels and dispositions / reports a terminal required failure once as an error and rethrows it | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Levels and dispositions / reports a first-attempt terminal failure's recovery as unrecorded | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Origin / reports the failure's origin in fields distinct from the reporting site | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Origin / reports a failure with no recorded origin without inventing one | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Disposition before diagnostics / keeps an optional outcome unavailable before and after its warning fails | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Disposition before diagnostics / keeps the outcome and its attempt evidence when the filter drops the report | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Bounded reports / emits one terminal error for a multi-attempt chain crossing two boundaries | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Diagnostic failures / keeps the primary failure, completed cleanup, and attempt count when the sink fails | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Diagnostic failures / keeps the primary failure and its evidence when formatting the report throws | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Diagnostic failures / keeps a recovered outcome when formatting its report throws | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Diagnostic failures / never reports a marked diagnostic's own failure through the same sink | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Cancellation / escapes cancellation delivered while a terminal report blocks | `hetoimasia-tests` | unchanged |
| Runtime / Outcome reporting / Cancellation / escapes a cancellation an outcome report raised, with its context | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Waking / wakes an active supervised wait when a required worker fails | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Waking / wakes a startup wait and drains the new worker before the start unwinds | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Waking / handles a ready failure before simultaneously ready caller work, leaving the work unconsumed | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Startup / handles an optional startup failure once, with one warning and no report at later checkpoints | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Startup / propagates a required startup failure once and never commits it again | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Classification / distinguishes finite-job completion from an expected exit after a requested stop | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Classification / fails an unexpected service exit under the service's requirement policy | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Classification / preserves an unexpected child cancellation as a typed termination without cancelling the observer | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Classification / fails the run for a cleanup failure on an optional worker | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Classification / keeps an unexpected cancellation unexpected when a stop or cancel is requested after publication | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Warnings and the fatal latch / commits an optional disposition before its warning, and a failed warning neither repeats nor restores it | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Warnings and the fatal latch / keeps a caught fatal delivery latched through the final settlement | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Warnings and the fatal latch / initiates owned shutdown on a caught fatal: siblings are asked to stop and a later start forks nothing | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Simultaneous failures / selects the primary by registration order and retains every other typed failure | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Simultaneous failures / never selects an earlier optional failure as primary over a fatal one | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Simultaneous failures / keeps the application's own failure primary with worker failures beside it | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Evidence across invocations / retains an outer failure beside an inner primary whose worker has the same local ID | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Evidence across invocations / keeps inner secondary evidence when an outer boundary retains its own failure | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Evidence across invocations / composes a caught delivery rethrown inside a later independent invocation | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Evidence across invocations / retains each secondary once across repeated deliveries and adds a later failure | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Classifier failures / stops supervision on a classifier failure, retaining the handled worker failure | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Classifier failures / propagates cancellation during classification as the owner's and still drains workers | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Closing / keeps an exit before closing's stop request an unexpected service exit | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Closing / observes a failure published before closing before the boundary returns | `hetoimasia-tests` | unchanged |
| Runtime / Supervision / Closing / returns after an expected owner-requested cancellation and rejects a later start | `hetoimasia-tests` | unchanged |

### GLFW

| Base path | Suite | Path after the move |
|---|---|---|
| GLFW / GLFW session entry / enters and ends a session in its declared order, then enters again after the complete teardown | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session entry / rejects a bound worker thread that is not the process main thread before any native call | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session entry / rejects an unbound thread even when it runs as the process main thread | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session entry / rejects a nested entry from the owner thread before any further native call | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session entry / rejects a concurrent entry from another main-thread candidate while a session is active | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session entry / answers a Wayland request, or a Wayland-only platform, as unsupported before any native call | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session entry / answers another platform's backend, or one the library reports unavailable, as unsupported | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session construction rollback / rolls back a failed initialization without terminating, keeping its reports as evidence | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session construction rollback / terminates an initialization that returned but reported an error, before raising it | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session construction rollback / terminates when the initialized platform is not the selected backend | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session construction rollback / keeps a rolled-back failure primary beside a failing rollback, and poisons the guard | `hetoimasia-tests` | unchanged |
| GLFW / GLFW native error evidence / keeps the first reports up to capacity, counts the rest, and still fails a call that returned | `hetoimasia-tests` | unchanged |
| GLFW / GLFW native error evidence / copies a bounded description, records truncation, and decodes invalid UTF-8 leniently | `hetoimasia-tests` | unchanged |
| GLFW / GLFW native error evidence / does not attribute a report made on another thread during an owner call to that call | `hetoimasia-tests` | unchanged |
| GLFW / GLFW native error evidence / bounds asynchronous reports the same way | `hetoimasia-tests` | unchanged |
| GLFW / GLFW native error evidence / retains asynchronous reports nobody read as cleanup evidence, without poisoning | `hetoimasia-tests` | unchanged |
| GLFW / GLFW native error evidence / contains a failure inside the callback instead of unwinding into the native caller | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session teardown / keeps a failing body primary beside release-time native errors, then refuses entry once poisoned | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session teardown / retains a release-time native error without poisoning when every teardown step returned | `hetoimasia-tests` | unchanged |
| GLFW / GLFW owner-only operations / rejects use from another thread and after the session ended, before any native call | `hetoimasia-tests` | unchanged |
| GLFW / GLFW window model / passes every window model example in the package's private-driver executable | `hetoimasia-tests` | unchanged |
| GLFW / GLFW link declarations / declare exactly the platform link requirements the native manifest records | `hetoimasia-tests` | unchanged |
| GLFW / GLFW link declarations / declares the pinned GLFW series as a pkg-config dependency | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that names the session constructor | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for a native window handle or the production native table | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that names the window or observation constructor | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for a window's native handle or owner-boundary driver | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that closes a window's observations through its read endpoint | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that constructs a monitor identity, description, or inventory | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for a native monitor pointer or pointer-lending resolution | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that names a monitor driver through the public seam | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that names a command host, port, or completion ticket constructor | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for command execution or admission hooks in the private command module | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that constructs or alters a control command or its size constraints outside the smart constructors | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for the control representation in the private control module | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that constructs a mode, a saved placement, or a mode record, or sets a saved placement through a field | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for the mode representation or the owner's record updates in the private mode module | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that constructs an input reader, control, event, epoch, or reset token | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that coerces a number into an input epoch to retarget a reset | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that rewrites a reset token's epoch through record syntax | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for an input feed, its producer, or its resumption through the public input module | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for an input feed's producer or channel in the private input module | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that registers an input callback or injects an event through the private native table | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that names the command executor through the public seam | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for the command executor in the private seam implementation | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that names a window driver through the public seam | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for the window drivers in the private seam implementation | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that names the window host's constructor | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that asks the window host for its session or command host | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that asks the window host for the collection owning its windows or their registry | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for the collection or the host hooks in the window host's private implementation | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client that forges a window's client capabilities or takes another window's port out of them | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / rejects a client holding a window host that reaches for the owner loop's executor or event processing | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / accepts and runs a client using the window host's supported capabilities, without initializing GLFW | `hetoimasia-tests` | unchanged |
| GLFW / GLFW session opacity across the package boundary / accepts and runs a client using only the public session, window, and command interfaces, without initializing GLFW | `hetoimasia-tests` | unchanged |
