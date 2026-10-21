# Runtime suite example mapping

Evidence for issue #129 (TEST-5 of epic #49): every example the root
`hetoimasia-tests` suite registered at the base revision `79d4425`, and the one
place it is registered after the runtime contracts moved into
`hetoimasia-runtime:runtime-tests`.

## Method

Both inventories are Hspec's own dry-run tree, not a count of `it` blocks:

```bash
cabal test hetoimasia-tests --test-show-details=direct --test-options='--dry-run --format=specdoc'
cabal test hetoimasia-runtime:runtime-tests --test-show-details=direct --test-options='--dry-run --format=specdoc'
```

The first ran at the base revision and again on this branch; the second ran on
this branch. Each example is identified by its full path of group names. A script
matched every base path to exactly one destination path and checked the result
in both directions: no base example is unmatched, no destination example is
matched twice, and neither suite registers an example with no base counterpart.

| | Examples |
|---|---:|
| Base `hetoimasia-tests` | 209 |
| `runtime-tests` after the move | 143 |
| `hetoimasia-tests` after the move | 66 |

Paths are unchanged except for one deliberate move: the console executable's
`Runtime / Console startup / …` examples, which launch the built executable,
become `Console / Console startup / …` in the root suite (11 examples). The
runtime suite keeps the `Runtime` top-level group, so its subgroup paths and
selectors are the ones the root suite used to carry. The ten resource-smoke
examples and the six supervised messaging examples that #127 left in the root
`Runtime` group move with it; they are listed by name below.

## Summary by base group

| Base group | Base examples | `runtime-tests` | `hetoimasia-tests` |
|---|---:|---:|---:|
| `Runtime / runApplication` | 2 | 2 | 0 |
| `Runtime / Application lifecycle` | 25 | 25 | 0 |
| `Runtime / Console startup` | 11 | 0 | 11 |
| `Runtime / Inbox services` | 18 | 18 | 0 |
| `Runtime / Inbox finish` | 12 | 12 | 0 |
| `Runtime / Logging lifetime` | 15 | 15 | 0 |
| `Runtime / Supervised worker opacity across the package boundary` | 3 | 3 | 0 |
| `Runtime / Inbox service opacity across the package boundary` | 11 | 11 | 0 |
| `Runtime / Outcome reporting` | 16 | 16 | 0 |
| `Runtime / Supervision` | 25 | 25 | 0 |
| `Runtime / Channel composition` | 4 | 4 | 0 |
| `Runtime / Snapshot composition` | 2 | 2 | 0 |
| `Runtime / Console resource smoke` | 10 | 10 | 0 |
| `GLFW` | 55 | 0 | 55 |

## Retained cases moved by name

Resource smoke (`Runtime / Console resource smoke`, now in `runtime-tests`):

- Injected failures / releases everything and reports once when the injected work fails
- Injected failures / propagates a release failure with its evidence and reports it once
- Injected failures / keeps the work's failure and the ordered evidence when the report also fails
- Injected failures / releases everything and reports nothing when a lifecycle record's sink fails
- Injected failures / reports a work failure through a sink that only the lifecycle records broke
- Injected failures / propagates cancellation delivered to the work, unreported
- Injected failures / propagates cancellation delivered while the report blocks
- Injected failures / keeps the annotation of a cancellation the report itself raised
- Injected failures / keeps the cleanup evidence of a cancellation delivered while reporting
- Sink disposal / writes every cleanup record before the test closes the handle it owns

Supervised messaging (`Runtime / Channel composition` and `Runtime / Snapshot composition`, now in `runtime-tests`):

- Channel composition / settles a nonfatal worker outcome before a ready supervised receive, then receives the entry once
- Channel composition / settles a nonfatal worker outcome before a newly possible supervised send, then admits it once
- Channel composition / never commits a ready supervised receive while a fatal worker failure is pending
- Channel composition / never commits a possible supervised send while a fatal worker failure is pending
- Snapshot composition / settles a nonfatal worker outcome before a ready supervised waiting read commits
- Snapshot composition / never commits a ready supervised waiting read while a fatal worker failure is pending

## Examples


### Runtime

| Base path | Suite | Path after the move |
|---|---|---|
| Runtime / runApplication / orders events and returns the application result | `runtime-tests` | unchanged |
| Runtime / runApplication / propagates failure without reporting completion | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Order / runs startup and the action on the calling thread, drains workers, then disposes dependents before dependencies | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Order / publishes an optional component's unavailability truthfully in the services value | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Partial startup and cancellation / disposes what construction acquired without running startup, then reports once before the flush | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Partial startup and cancellation / drains a worker a failing startup started before disposing its dependencies | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Partial startup and cancellation / drains workers before dependency disposal on owner cancellation, unreported and unflushed | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Truthful outcomes / never turns a caught supervised failure into a successful run | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Truthful outcomes / observes a worker failure that arrives while closing before accepting the result | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Truthful outcomes / keeps a component cleanup failure in the one terminal report, after disposal and before the flush | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Truthful outcomes / fails a successful run whose final flush fails, flushing once and reporting nothing | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Truthful outcomes / attempts no terminal report once a managed report has failed | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / releases a worker awaiting a reply from a dependency-owned service so the boundary drain completes | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / runs exactly once, with dependencies live, on every exit from the supervised region / startup callback failure | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / runs exactly once, with dependencies live, on every exit from the supervised region / post-startup checkpoint failure | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / runs exactly once, with dependencies live, on every exit from the supervised region / action failure | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / runs exactly once, with dependencies live, on every exit from the supervised region / final checkpoint failure | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / runs exactly once, with dependencies live, on every exit from the supervised region / successful action return | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / runs exactly once, with dependencies live, on every exit from the supervised region / action cancellation | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / does not run when dependency construction fails | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / precedes the boundary's stop requests on ordinary shutdown | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / may follow a stop the fatal latch already requested | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / may follow the drain of a worker whose managed startup was cancelled | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / retains its failure as cleanup evidence while an action failure stays primary | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / retains its failure as cleanup evidence while cancellation propagates unreported and unflushed | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / discards a successful result when it fails, then drains, disposes, reports, and flushes | `runtime-tests` | unchanged |
| Runtime / Application lifecycle / Quiescence / leaves runScopedApplication identical to a no-op quiescence action | `runtime-tests` | unchanged |
| Runtime / Console startup / emits the smoke records under the default configuration | `hetoimasia-tests` | Console / Console startup / emits the smoke records under the default configuration |
| Runtime / Console startup / applies a threshold and an exact override to the smoke path | `hetoimasia-tests` | Console / Console startup / applies a threshold and an exact override to the smoke path |
| Runtime / Console startup / emits the owned-resource lifecycle records on the resource-smoke path | `hetoimasia-tests` | Console / Console startup / emits the owned-resource lifecycle records on the resource-smoke path |
| Runtime / Console startup / silences the resource-smoke path at a warn threshold | `hetoimasia-tests` | Console / Console startup / silences the resource-smoke path at a warn threshold |
| Runtime / Console startup / rejects an unknown argument with a usage line naming both smoke paths | `hetoimasia-tests` | Console / Console startup / rejects an unknown argument with a usage line naming both smoke paths |
| Runtime / Console startup / fails before any entry for each invalid variable | `hetoimasia-tests` | Console / Console startup / fails before any entry for each invalid variable |
| Runtime / Console startup / keeps a forged value from splitting the diagnostic | `hetoimasia-tests` | Console / Console startup / keeps a forged value from splitting the diagnostic |
| Runtime / Console startup / keeps help visible and validates configuration on that path | `hetoimasia-tests` | Console / Console startup / keeps help visible and validates configuration on that path |
| Runtime / Console startup / Exit mapping / exits non-zero when a runtime failure propagates out of a path | `hetoimasia-tests` | Console / Console startup / Exit mapping / exits non-zero when a runtime failure propagates out of a path |
| Runtime / Console startup / Exit mapping / maps a cancellation to the cancellation status | `hetoimasia-tests` | Console / Console startup / Exit mapping / maps a cancellation to the cancellation status |
| Runtime / Console startup / Exit mapping / passes an explicit exit status through unchanged | `hetoimasia-tests` | Console / Console startup / Exit mapping / passes an explicit exit status through unchanged |
| Runtime / Inbox services / Failed starts / propagates a required context failure with no endpoint and the context released | `runtime-tests` | unchanged |
| Runtime / Inbox services / Failed starts / rejects a start after closing without constructing anything | `runtime-tests` | unchanged |
| Runtime / Inbox services / Failed starts / returns an optional recognized context failure as unavailable, with no endpoint and one warning | `runtime-tests` | unchanged |
| Runtime / Inbox services / Failed starts / propagates owner cancellation during context construction with the context released | `runtime-tests` | unchanged |
| Runtime / Inbox services / Handoff and immediate exit / returns a usable endpoint from a start whose handoff is already full | `runtime-tests` | unchanged |
| Runtime / Inbox services / Handoff and immediate exit / closes the inbox before teardown when a service stops straight after acknowledgement | `runtime-tests` | unchanged |
| Runtime / Inbox services / Stop with a full inbox / aborts the backlog on an ordinary stop and retains its discard count | `runtime-tests` | unchanged |
| Runtime / Inbox services / Stop with a full inbox / aborts the backlog on closing's stop when the application returns | `runtime-tests` | unchanged |
| Runtime / Inbox services / Stop races / lets a requested stop win over a simultaneously ready message | `runtime-tests` | unchanged |
| Runtime / Inbox services / Stop races / completes an in-flight message once without retrying it | `runtime-tests` | unchanged |
| Runtime / Inbox services / Handler exceptions / fails a required service with the handler's type and context, aborting the queued messages | `runtime-tests` | unchanged |
| Runtime / Inbox services / Handler exceptions / fails an optional service whose classifier does not recognize the failure | `runtime-tests` | unchanged |
| Runtime / Inbox services / Handler exceptions / leaves a recognized optional failure unavailable with one warning, aborting the queued messages | `runtime-tests` | unchanged |
| Runtime / Inbox services / Handler exceptions / handles the following message after a handler recovers explicitly | `runtime-tests` | unchanged |
| Runtime / Inbox services / Failure evidence / closes the endpoint before teardown for a cancellation after the handoff and before any dispatch | `runtime-tests` | unchanged |
| Runtime / Inbox services / Failure evidence / keeps an in-flight cancellation's completion without an exit record | `runtime-tests` | unchanged |
| Runtime / Inbox services / Failure evidence / keeps a cleanup failure's completion without an exit record | `runtime-tests` | unchanged |
| Runtime / Inbox services / Dependencies / keeps a borrowed dependency usable until the service's cleanup finishes | `runtime-tests` | unchanged |
| Runtime / Inbox finish / In-flight and backlog work / handles the in-flight message and every accepted message once, in order, before acknowledging the drain | `runtime-tests` | unchanged |
| Runtime / Inbox finish / Stop or cancellation before the drain / reports a stop requested before the drain as unfinished, discarding the backlog | `runtime-tests` | unchanged |
| Runtime / Inbox finish / Stop or cancellation before the drain / reports a cancellation committed before the dispatch decision as unfinished, with no acknowledgement | `runtime-tests` | unchanged |
| Runtime / Inbox finish / Stop or cancellation before the drain / never acknowledges a drain when a stop races the final empty-inbox observation | `runtime-tests` | unchanged |
| Runtime / Inbox finish / Failures during finish / reports a recognized optional handler failure as unavailable with one warning, without waiting for a drain | `runtime-tests` | unchanged |
| Runtime / Inbox finish / Failures during finish / propagates a required handler failure with its original evidence | `runtime-tests` | unchanged |
| Runtime / Inbox finish / Failures during finish / propagates an unrecognized optional handler failure with its original evidence | `runtime-tests` | unchanged |
| Runtime / Inbox finish / Failures during finish / propagates a cleanup failure after the drain with its evidence, keeping the acknowledgement | `runtime-tests` | unchanged |
| Runtime / Inbox finish / Unrelated outcomes / settles a completed job and an unavailable optional worker during the finish wait, then finishes | `runtime-tests` | unchanged |
| Runtime / Inbox finish / Cancellation after the drain / keeps the acknowledgement and the cancelled completion, is not a successful finish, and repeats nothing | `runtime-tests` | unchanged |
| Runtime / Inbox finish / Owner cancellation / keeps a borrowed dependency usable until the service's cleanup finishes | `runtime-tests` | unchanged |
| Runtime / Inbox finish / Combined example / publishes each handled command's state after handling it, and keeps the final snapshot readable after finish | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / returns the callback's result after one final flush | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / fails a successful run whose final flush fails | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / rethrows a callback failure after one final flush | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / keeps a callback failure primary, with its evidence, when the flush also fails | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / returns a result without flushing once a managed report has failed | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / rethrows without flushing once a managed report has failed, exposing the attempt | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Finalization / makes no flush after a marked diagnostic failed | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Cancellation / propagates a cancellation the callback raised, with its context and no flush | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Cancellation / propagates a cancellation delivered to the callback, with no flush | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Cancellation / propagates a cancellation delivered while the owner's report blocks, with no flush | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Cancellation / propagates a cancellation delivered while the final flush blocks, unretried | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Ordering / flushes after producers, scopes, and the report, outside every release | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Ordering / leaves a borrowed handle open with its buffering unchanged | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Managed resource smoke / runs the smoke records and then one final flush | `runtime-tests` | unchanged |
| Runtime / Logging lifetime / Managed resource smoke / hands a failed report to the lifetime owner while the work's failure propagates | `runtime-tests` | unchanged |
| Runtime / Supervised worker opacity across the package boundary / rejects a client that replaces the raw worker with record update | `runtime-tests` | unchanged |
| Runtime / Supervised worker opacity across the package boundary / rejects a client that names the constructor | `runtime-tests` | unchanged |
| Runtime / Supervised worker opacity across the package boundary / accepts and runs a client using the reader, completion, status, stop, and cancel | `runtime-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that replaces a service's endpoint with record update | `runtime-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that names the service handle's constructor | `runtime-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that names the definition's constructor to build its own startup and handoff | `runtime-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that takes a send endpoint from an unavailable start | `runtime-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that constructs an exit record | `runtime-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that updates an exit record's discard count | `runtime-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that updates an exit record's drain acknowledgement | `runtime-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that forges a drain acknowledgement with its constructor | `runtime-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / rejects a client that rewrites a drain acknowledgement's handled count | `runtime-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / accepts and runs a client that starts a service, sends, stops it, and reads its discard count | `runtime-tests` | unchanged |
| Runtime / Inbox service opacity across the package boundary / accepts and runs a client that finishes a service and reads both exit record accessors | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Levels and dispositions / warns once for a recovered result, with its attempt history | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Levels and dispositions / reports nothing for a first-attempt success | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Levels and dispositions / warns once for an exhausted optional operation | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Levels and dispositions / reports a terminal required failure once as an error and rethrows it | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Levels and dispositions / reports a first-attempt terminal failure's recovery as unrecorded | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Origin / reports the failure's origin in fields distinct from the reporting site | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Origin / reports a failure with no recorded origin without inventing one | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Disposition before diagnostics / keeps an optional outcome unavailable before and after its warning fails | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Disposition before diagnostics / keeps the outcome and its attempt evidence when the filter drops the report | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Bounded reports / emits one terminal error for a multi-attempt chain crossing two boundaries | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Diagnostic failures / keeps the primary failure, completed cleanup, and attempt count when the sink fails | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Diagnostic failures / keeps the primary failure and its evidence when formatting the report throws | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Diagnostic failures / keeps a recovered outcome when formatting its report throws | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Diagnostic failures / never reports a marked diagnostic's own failure through the same sink | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Cancellation / escapes cancellation delivered while a terminal report blocks | `runtime-tests` | unchanged |
| Runtime / Outcome reporting / Cancellation / escapes a cancellation an outcome report raised, with its context | `runtime-tests` | unchanged |
| Runtime / Supervision / Waking / wakes an active supervised wait when a required worker fails | `runtime-tests` | unchanged |
| Runtime / Supervision / Waking / wakes a startup wait and drains the new worker before the start unwinds | `runtime-tests` | unchanged |
| Runtime / Supervision / Waking / handles a ready failure before simultaneously ready caller work, leaving the work unconsumed | `runtime-tests` | unchanged |
| Runtime / Supervision / Startup / handles an optional startup failure once, with one warning and no report at later checkpoints | `runtime-tests` | unchanged |
| Runtime / Supervision / Startup / propagates a required startup failure once and never commits it again | `runtime-tests` | unchanged |
| Runtime / Supervision / Classification / distinguishes finite-job completion from an expected exit after a requested stop | `runtime-tests` | unchanged |
| Runtime / Supervision / Classification / fails an unexpected service exit under the service's requirement policy | `runtime-tests` | unchanged |
| Runtime / Supervision / Classification / preserves an unexpected child cancellation as a typed termination without cancelling the observer | `runtime-tests` | unchanged |
| Runtime / Supervision / Classification / fails the run for a cleanup failure on an optional worker | `runtime-tests` | unchanged |
| Runtime / Supervision / Classification / keeps an unexpected cancellation unexpected when a stop or cancel is requested after publication | `runtime-tests` | unchanged |
| Runtime / Supervision / Warnings and the fatal latch / commits an optional disposition before its warning, and a failed warning neither repeats nor restores it | `runtime-tests` | unchanged |
| Runtime / Supervision / Warnings and the fatal latch / keeps a caught fatal delivery latched through the final settlement | `runtime-tests` | unchanged |
| Runtime / Supervision / Warnings and the fatal latch / initiates owned shutdown on a caught fatal: siblings are asked to stop and a later start forks nothing | `runtime-tests` | unchanged |
| Runtime / Supervision / Simultaneous failures / selects the primary by registration order and retains every other typed failure | `runtime-tests` | unchanged |
| Runtime / Supervision / Simultaneous failures / never selects an earlier optional failure as primary over a fatal one | `runtime-tests` | unchanged |
| Runtime / Supervision / Simultaneous failures / keeps the application's own failure primary with worker failures beside it | `runtime-tests` | unchanged |
| Runtime / Supervision / Evidence across invocations / retains an outer failure beside an inner primary whose worker has the same local ID | `runtime-tests` | unchanged |
| Runtime / Supervision / Evidence across invocations / keeps inner secondary evidence when an outer boundary retains its own failure | `runtime-tests` | unchanged |
| Runtime / Supervision / Evidence across invocations / composes a caught delivery rethrown inside a later independent invocation | `runtime-tests` | unchanged |
| Runtime / Supervision / Evidence across invocations / retains each secondary once across repeated deliveries and adds a later failure | `runtime-tests` | unchanged |
| Runtime / Supervision / Classifier failures / stops supervision on a classifier failure, retaining the handled worker failure | `runtime-tests` | unchanged |
| Runtime / Supervision / Classifier failures / propagates cancellation during classification as the owner's and still drains workers | `runtime-tests` | unchanged |
| Runtime / Supervision / Closing / keeps an exit before closing's stop request an unexpected service exit | `runtime-tests` | unchanged |
| Runtime / Supervision / Closing / observes a failure published before closing before the boundary returns | `runtime-tests` | unchanged |
| Runtime / Supervision / Closing / returns after an expected owner-requested cancellation and rejects a later start | `runtime-tests` | unchanged |
| Runtime / Channel composition / settles a nonfatal worker outcome before a ready supervised receive, then receives the entry once | `runtime-tests` | unchanged |
| Runtime / Channel composition / settles a nonfatal worker outcome before a newly possible supervised send, then admits it once | `runtime-tests` | unchanged |
| Runtime / Channel composition / never commits a ready supervised receive while a fatal worker failure is pending | `runtime-tests` | unchanged |
| Runtime / Channel composition / never commits a possible supervised send while a fatal worker failure is pending | `runtime-tests` | unchanged |
| Runtime / Snapshot composition / settles a nonfatal worker outcome before a ready supervised waiting read commits | `runtime-tests` | unchanged |
| Runtime / Snapshot composition / never commits a ready supervised waiting read while a fatal worker failure is pending | `runtime-tests` | unchanged |
| Runtime / Console resource smoke / Injected failures / releases everything and reports once when the injected work fails | `runtime-tests` | unchanged |
| Runtime / Console resource smoke / Injected failures / propagates a release failure with its evidence and reports it once | `runtime-tests` | unchanged |
| Runtime / Console resource smoke / Injected failures / keeps the work's failure and the ordered evidence when the report also fails | `runtime-tests` | unchanged |
| Runtime / Console resource smoke / Injected failures / releases everything and reports nothing when a lifecycle record's sink fails | `runtime-tests` | unchanged |
| Runtime / Console resource smoke / Injected failures / reports a work failure through a sink that only the lifecycle records broke | `runtime-tests` | unchanged |
| Runtime / Console resource smoke / Injected failures / propagates cancellation delivered to the work, unreported | `runtime-tests` | unchanged |
| Runtime / Console resource smoke / Injected failures / propagates cancellation delivered while the report blocks | `runtime-tests` | unchanged |
| Runtime / Console resource smoke / Injected failures / keeps the annotation of a cancellation the report itself raised | `runtime-tests` | unchanged |
| Runtime / Console resource smoke / Injected failures / keeps the cleanup evidence of a cancellation delivered while reporting | `runtime-tests` | unchanged |
| Runtime / Console resource smoke / Sink disposal / writes every cleanup record before the test closes the handle it owns | `runtime-tests` | unchanged |

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
