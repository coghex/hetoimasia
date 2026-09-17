# GLFW suite example mapping

Evidence for issue #130 (TEST-6 of epic #49): every example the root
`hetoimasia-tests` suite and the `window-examples` executable it ran as a
subprocess registered at the base revision `0fd66e6`, and the one place each is
registered after the GLFW headless coverage moved into
`hetoimasia-glfw:glfw-tests`.

## Method

The inventories are Hspec's own dry-run tree, not a count of `it` blocks. At
the base revision:

```bash
"$(cabal list-bin hetoimasia:test:hetoimasia-tests)" --dry-run --format=specdoc --no-color
```

and the removed `window-examples` executable's own binary, built at the base
revision and run with the same arguments. On this branch:

```bash
"$(cabal list-bin hetoimasia:test:hetoimasia-tests)" --dry-run --format=specdoc --no-color
"$(cabal list-bin hetoimasia-glfw:test:glfw-tests)" --dry-run --format=specdoc --no-color
```

Each example is identified by its full path of group names. The root suite's one
`GLFW / GLFW window model` example was only a wrapper that ran the executable and
asserted on its report, so it is expanded into the executable's examples rather
than counted as a mapping. A script matched every other base path to exactly one
destination path and checked the result in both directions: no base example is
unmatched, no destination example is matched twice, and neither suite registers
an example with no base counterpart.

| | Examples |
|---|---:|
| Base `hetoimasia-tests` | 66 |
| of which the subprocess wrapper | 1 |
| Base window-examples executable | 180 |
| `glfw-tests` after the move | 234 |
| `hetoimasia-tests` after the move | 11 |

Every path is unchanged. The executable already rooted its examples at a `GLFW`
group, and `glfw-tests` roots the moved root examples at the same `GLFW` group,
so a `--match` selector that chose an example at root or in the executable
chooses the same example in `glfw-tests`. The only removed example is the
wrapper:

- `GLFW / GLFW window model / passes every window model example in the package's private-driver executable`

## Summary by base group

| Base group | Base source | Module now | Base examples | `glfw-tests` | `hetoimasia-tests` |
|---|---|---|---:|---:|---:|
| `Console / Console startup` | root suite | `Test.Engine.Console.Spec` | 11 | 0 | 11 |
| `GLFW / GLFW session entry` | root suite | `Test.GLFW.Session` | 7 | 7 | 0 |
| `GLFW / GLFW session construction rollback` | root suite | `Test.GLFW.Session` | 4 | 4 | 0 |
| `GLFW / GLFW native error evidence` | root suite | `Test.GLFW.Session` | 6 | 6 | 0 |
| `GLFW / GLFW session teardown` | root suite | `Test.GLFW.Session` | 2 | 2 | 0 |
| `GLFW / GLFW owner-only operations` | root suite | `Test.GLFW.Session` | 1 | 1 | 0 |
| `GLFW / GLFW window model` | root suite | removed (wrapper) | 1 | 0 | 0 |
| `GLFW / GLFW link declarations` | root suite | `Test.GLFW.Linking` | 2 | 2 | 0 |
| `GLFW / GLFW session opacity across the package boundary` | root suite | `Test.GLFW.Opacity` | 32 | 32 | 0 |
| `GLFW / GLFW window creation` | window-examples executable | `Test.GLFW.Window` | 4 | 4 | 0 |
| `GLFW / GLFW window observations` | window-examples executable | `Test.GLFW.Window` | 3 | 3 | 0 |
| `GLFW / GLFW window close requests` | window-examples executable | `Test.GLFW.Window` | 1 | 1 | 0 |
| `GLFW / GLFW window callback containment` | window-examples executable | `Test.GLFW.Window` | 2 | 2 | 0 |
| `GLFW / GLFW window lifetime` | window-examples executable | `Test.GLFW.Window` | 2 | 2 | 0 |
| `GLFW / GLFW window closing` | window-examples executable | `Test.GLFW.Window` | 2 | 2 | 0 |
| `GLFW / GLFW window release failures` | window-examples executable | `Test.GLFW.Window` | 7 | 7 | 0 |
| `GLFW / GLFW window command admission` | window-examples executable | `Test.GLFW.Command` | 4 | 4 | 0 |
| `GLFW / GLFW window command execution` | window-examples executable | `Test.GLFW.Command` | 4 | 4 | 0 |
| `GLFW / GLFW window command completion` | window-examples executable | `Test.GLFW.Command` | 2 | 2 | 0 |
| `GLFW / GLFW window command closure` | window-examples executable | `Test.GLFW.Command` | 2 | 2 | 0 |
| `GLFW / GLFW window observation requests` | window-examples executable | `Test.GLFW.Command` | 1 | 1 | 0 |
| `GLFW / GLFW window controls` | window-examples executable | `Test.GLFW.Control` | 8 | 8 | 0 |
| `GLFW / GLFW window host` | window-examples executable | `Test.GLFW.Host` | 22 | 22 | 0 |
| `GLFW / GLFW dynamic windows` | window-examples executable | `Test.GLFW.Dynamic` | 18 | 18 | 0 |
| `GLFW / GLFW monitor inventory` | window-examples executable | `Test.GLFW.Monitor` | 14 | 14 | 0 |
| `GLFW / GLFW input feeds` | window-examples executable | `Test.GLFW.Input` | 31 | 31 | 0 |
| `GLFW / GLFW window modes` | window-examples executable | `Test.GLFW.Mode` | 53 | 53 | 0 |

## Every example

Destination is `glfw-tests` for every `GLFW / …` path and `hetoimasia-tests`
for every `Console / …` path; the path itself is unchanged.

| Base source | Path | Destination |
|---|---|---|
| root | Console / Console startup / emits the smoke records under the default configuration | `hetoimasia-tests` |
| root | Console / Console startup / applies a threshold and an exact override to the smoke path | `hetoimasia-tests` |
| root | Console / Console startup / emits the owned-resource lifecycle records on the resource-smoke path | `hetoimasia-tests` |
| root | Console / Console startup / silences the resource-smoke path at a warn threshold | `hetoimasia-tests` |
| root | Console / Console startup / rejects an unknown argument with a usage line naming both smoke paths | `hetoimasia-tests` |
| root | Console / Console startup / fails before any entry for each invalid variable | `hetoimasia-tests` |
| root | Console / Console startup / keeps a forged value from splitting the diagnostic | `hetoimasia-tests` |
| root | Console / Console startup / keeps help visible and validates configuration on that path | `hetoimasia-tests` |
| root | Console / Console startup / Exit mapping / exits non-zero when a runtime failure propagates out of a path | `hetoimasia-tests` |
| root | Console / Console startup / Exit mapping / maps a cancellation to the cancellation status | `hetoimasia-tests` |
| root | Console / Console startup / Exit mapping / passes an explicit exit status through unchanged | `hetoimasia-tests` |
| root | GLFW / GLFW session entry / enters and ends a session in its declared order, then enters again after the complete teardown | `glfw-tests` |
| root | GLFW / GLFW session entry / rejects a bound worker thread that is not the process main thread before any native call | `glfw-tests` |
| root | GLFW / GLFW session entry / rejects an unbound thread even when it runs as the process main thread | `glfw-tests` |
| root | GLFW / GLFW session entry / rejects a nested entry from the owner thread before any further native call | `glfw-tests` |
| root | GLFW / GLFW session entry / rejects a concurrent entry from another main-thread candidate while a session is active | `glfw-tests` |
| root | GLFW / GLFW session entry / answers a Wayland request, or a Wayland-only platform, as unsupported before any native call | `glfw-tests` |
| root | GLFW / GLFW session entry / answers another platform's backend, or one the library reports unavailable, as unsupported | `glfw-tests` |
| root | GLFW / GLFW session construction rollback / rolls back a failed initialization without terminating, keeping its reports as evidence | `glfw-tests` |
| root | GLFW / GLFW session construction rollback / terminates an initialization that returned but reported an error, before raising it | `glfw-tests` |
| root | GLFW / GLFW session construction rollback / terminates when the initialized platform is not the selected backend | `glfw-tests` |
| root | GLFW / GLFW session construction rollback / keeps a rolled-back failure primary beside a failing rollback, and poisons the guard | `glfw-tests` |
| root | GLFW / GLFW native error evidence / keeps the first reports up to capacity, counts the rest, and still fails a call that returned | `glfw-tests` |
| root | GLFW / GLFW native error evidence / copies a bounded description, records truncation, and decodes invalid UTF-8 leniently | `glfw-tests` |
| root | GLFW / GLFW native error evidence / does not attribute a report made on another thread during an owner call to that call | `glfw-tests` |
| root | GLFW / GLFW native error evidence / bounds asynchronous reports the same way | `glfw-tests` |
| root | GLFW / GLFW native error evidence / retains asynchronous reports nobody read as cleanup evidence, without poisoning | `glfw-tests` |
| root | GLFW / GLFW native error evidence / contains a failure inside the callback instead of unwinding into the native caller | `glfw-tests` |
| root | GLFW / GLFW session teardown / keeps a failing body primary beside release-time native errors, then refuses entry once poisoned | `glfw-tests` |
| root | GLFW / GLFW session teardown / retains a release-time native error without poisoning when every teardown step returned | `glfw-tests` |
| root | GLFW / GLFW owner-only operations / rejects use from another thread and after the session ended, before any native call | `glfw-tests` |
| root | GLFW / GLFW window model / passes every window model example in the package's private-driver executable | removed wrapper; expanded into the window-examples rows |
| root | GLFW / GLFW link declarations / declare exactly the platform link requirements the native manifest records | `glfw-tests` |
| root | GLFW / GLFW link declarations / declares the pinned GLFW series as a pkg-config dependency | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that names the session constructor | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for a native window handle or the production native table | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that names the window or observation constructor | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for a window's native handle or owner-boundary driver | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that closes a window's observations through its read endpoint | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that constructs a monitor identity, description, or inventory | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for a native monitor pointer or pointer-lending resolution | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that names a monitor driver through the public seam | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that names a command host, port, or completion ticket constructor | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for command execution or admission hooks in the private command module | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that constructs or alters a control command or its size constraints outside the smart constructors | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for the control representation in the private control module | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that constructs a mode, a saved placement, or a mode record, or sets a saved placement through a field | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for the mode representation or the owner's record updates in the private mode module | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that constructs an input reader, control, event, epoch, or reset token | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that coerces a number into an input epoch to retarget a reset | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that rewrites a reset token's epoch through record syntax | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for an input feed, its producer, or its resumption through the public input module | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for an input feed's producer or channel in the private input module | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that registers an input callback or injects an event through the private native table | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that names the command executor through the public seam | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for the command executor in the private seam implementation | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that names a window driver through the public seam | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for the window drivers in the private seam implementation | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that names the window host's constructor | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that asks the window host for its session or command host | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that asks the window host for the collection owning its windows or their registry | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that reaches for the collection or the host hooks in the window host's private implementation | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client that forges a window's client capabilities or takes another window's port out of them | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / rejects a client holding a window host that reaches for the owner loop's executor or event processing | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / accepts and runs a client using the window host's supported capabilities, without initializing GLFW | `glfw-tests` |
| root | GLFW / GLFW session opacity across the package boundary / accepts and runs a client using only the public session, window, and command interfaces, without initializing GLFW | `glfw-tests` |
| window-examples | GLFW / GLFW window creation / rejects invalid dimensions and titles before any conversion or native call | `glfw-tests` |
| window-examples | GLFW / GLFW window creation / resets every creation hint and sets each explicitly before every window | `glfw-tests` |
| window-examples | GLFW / GLFW window creation / publishes sampled geometry, never the request, and releases in the declared order | `glfw-tests` |
| window-examples | GLFW / GLFW window creation / destroys a live window before raising an error its creation reported, and never a null one | `glfw-tests` |
| window-examples | GLFW / GLFW window observations / coalesces callback captures into one new revision at the owner boundary | `glfw-tests` |
| window-examples | GLFW / GLFW window observations / represents an attribute the platform cannot provide as unavailable, and accepts a zero framebuffer | `glfw-tests` |
| window-examples | GLFW / GLFW window observations / publishes a new revision for a refresh even when every attribute is unchanged | `glfw-tests` |
| window-examples | GLFW / GLFW window close requests / latches close intent with its own identity, never destroys, and keeps a newer request past an older rejection | `glfw-tests` |
| window-examples | GLFW / GLFW window callback containment / rethrows a fault raised during a setter or a poll at the owner boundary with its context | `glfw-tests` |
| window-examples | GLFW / GLFW window callback containment / keeps every capture latched and the snapshot coherent when cancelled before the commit | `glfw-tests` |
| window-examples | GLFW / GLFW window lifetime / keeps two live windows independent and never lets a later window answer to an ended handle | `glfw-tests` |
| window-examples | GLFW / GLFW window lifetime / rejects window operations from another thread before any native call | `glfw-tests` |
| window-examples | GLFW / GLFW window closing / changes nothing when cancelled before the closing commit, then commits the owner's record and the closing phase in one transaction, once | `glfw-tests` |
| window-examples | GLFW / GLFW window closing / publishes nothing when the owner's commit declines | `glfw-tests` |
| window-examples | GLFW / GLFW window release failures / rolls back a failed initial sampling, then creates another window in the same session | `glfw-tests` |
| window-examples | GLFW / GLFW window release failures / detaches and releases a window whose callback attachment reported an error, without poisoning | `glfw-tests` |
| window-examples | GLFW / GLFW window release failures / detaches, keeps callback storage, and poisons the session when attaching callbacks raises | `glfw-tests` |
| window-examples | GLFW / GLFW window release failures / retains a latched callback fault beside a detach that raises or reports an error | `glfw-tests` |
| window-examples | GLFW / GLFW window release failures / keeps callback storage and poisons the session when detaching callbacks raises | `glfw-tests` |
| window-examples | GLFW / GLFW window release failures / keeps callback storage and poisons the session when destroying the window raises | `glfw-tests` |
| window-examples | GLFW / GLFW window release failures / treats a destroy that reported an error as uncertain: storage kept, session poisoned | `glfw-tests` |
| window-examples | GLFW / GLFW window command admission / answers Full at capacity and Closed after closure, changing nothing | `glfw-tests` |
| window-examples | GLFW / GLFW window command admission / waits for capacity cancellably, admitting nothing when cancelled, and ends the wait at closure | `glfw-tests` |
| window-examples | GLFW / GLFW window command admission / leaves nothing reserved after a rolled-back or cancelled admission, and keeps a command whose admission committed | `glfw-tests` |
| window-examples | GLFW / GLFW window command admission / keeps the submission site, caller context, and window and request identity intact across the queue | `glfw-tests` |
| window-examples | GLFW / GLFW window command execution / claims commands in committed admission order | `glfw-tests` |
| window-examples | GLFW / GLFW window command execution / settles an interruption after the claim, after effects, or in preparation as interrupted, without replay | `glfw-tests` |
| window-examples | GLFW / GLFW window command execution / carries a native failure as prepared data and keeps a Haskell exception's context on the failure path | `glfw-tests` |
| window-examples | GLFW / GLFW window command execution / keeps pending bookkeeping within capacity plus active work across repeated cycles | `glfw-tests` |
| window-examples | GLFW / GLFW window command completion / returns one settled disposition to repeated and cancelled waits, and after leaving the bookkeeping | `glfw-tests` |
| window-examples | GLFW / GLFW window command completion / never waits on the owner thread for work only the owner thread can do | `glfw-tests` |
| window-examples | GLFW / GLFW window command closure / settles every queued command as not executed, wakes its waiters, and executes nothing afterwards | `glfw-tests` |
| window-examples | GLFW / GLFW window command closure / leaves a command claimed before closure to settle through its execution | `glfw-tests` |
| window-examples | GLFW / GLFW window observation requests / settle with a committed revision of the addressed window, published first, and reject unserved and ended windows | `glfw-tests` |
| window-examples | GLFW / GLFW window controls / validation / rejects every invalid argument class before any native call, and an out-of-constraint size once constraints are known | `glfw-tests` |
| window-examples | GLFW / GLFW window controls / validation / rejects controls addressed to unknown, closing, and closed windows without native effect | `glfw-tests` |
| window-examples | GLFW / GLFW window controls / validation / rejects controls while a mode transition is in progress, leaving observation and other windows alone | `glfw-tests` |
| window-examples | GLFW / GLFW window controls / dispatch / dispatches every control through the owner loop to its addressed window while a second window stays untouched | `glfw-tests` |
| window-examples | GLFW / GLFW window controls / honest outcomes / settles controls the modeled Wayland backend cannot perform as unsupported with a reason, and fabricates no unreportable observation | `glfw-tests` |
| window-examples | GLFW / GLFW window controls / honest outcomes / attributes a native error to its own command and submission context, never to an unrelated one | `glfw-tests` |
| window-examples | GLFW / GLFW window controls / honest outcomes / reports a failed constraint update's returned, failed, and unattempted calls, refuses sizes until a complete update restores known state | `glfw-tests` |
| window-examples | GLFW / GLFW window controls / honest outcomes / names a revision a post-call sample published, and stays correct when the latest snapshot has moved beyond it | `glfw-tests` |
| window-examples | GLFW / GLFW window host / owner turns / polls while active and waits its finite idle bound while idle, serving a command queued during an idle turn on the next | `glfw-tests` |
| window-examples | GLFW / GLFW window host / owner turns / waits on every idle turn with no windows rather than spinning | `glfw-tests` |
| window-examples | GLFW / GLFW window host / owner turns / refuses budgets and idle waits it cannot bound before acquiring anything | `glfw-tests` |
| window-examples | GLFW / GLFW window host / owner turns / rolls a failed construction back before startup, releasing what it created | `glfw-tests` |
| window-examples | GLFW / GLFW window host / checkpoints under saturated queues / rethrows a failure latched during event processing before any dispatch | `glfw-tests` |
| window-examples | GLFW / GLFW window host / checkpoints under saturated queues / reaches the check after one command batch, charging rejected commands their attempt | `glfw-tests` |
| window-examples | GLFW / GLFW window host / checkpoints under saturated queues / reaches the check after one application event batch, before the update | `glfw-tests` |
| window-examples | GLFW / GLFW window host / workers and the owner / lets a background worker progress while the owner is inside its finite wait | `glfw-tests` |
| window-examples | GLFW / GLFW window host / workers and the owner / settles a worker's observation request through the loop with the published revision | `glfw-tests` |
| window-examples | GLFW / GLFW window host / workers and the owner / rejects owner-thread waits on its own loop, and refuses the loop to another thread | `glfw-tests` |
| window-examples | GLFW / GLFW window host / monitors / refreshes the monitor inventory after native events only when the monitor callback reported a change | `glfw-tests` |
| window-examples | GLFW / GLFW window host / close requests / surfaces a close request once to application policy, destroying nothing and keeping the loop and workers running | `glfw-tests` |
| window-examples | GLFW / GLFW window host / quiescence and shutdown / closes admission and settles queued commands in one finite, idempotent transaction that executes nothing | `glfw-tests` |
| window-examples | GLFW / GLFW window host / quiescence and shutdown / closes a window's input feed with its close protocol, and every feed at quiescence, without awaiting a pending reset's acknowledgement | `glfw-tests` |
| window-examples | GLFW / GLFW window host / quiescence and shutdown / claims the overflow warning through the injected loop logger and resumes after acknowledgement at the owner-loop recovery boundary | `glfw-tests` |
| window-examples | GLFW / GLFW window host / quiescence and shutdown / recovers a feed overflowed by command-triggered callbacks at the post-command boundary | `glfw-tests` |
| window-examples | GLFW / GLFW window host / quiescence and shutdown / settles queued callers before the boundary drain when startup fails after a worker started | `glfw-tests` |
| window-examples | GLFW / GLFW window host / quiescence and shutdown / settles queued callers before the boundary drain when the action returns | `glfw-tests` |
| window-examples | GLFW / GLFW window host / quiescence and shutdown / settles queued callers before the boundary drain when the action fails | `glfw-tests` |
| window-examples | GLFW / GLFW window host / quiescence and shutdown / settles queued callers before the boundary drain when the action is cancelled | `glfw-tests` |
| window-examples | GLFW / GLFW window host / quiescence and shutdown / settles queued callers after a supervisor-detected failure, releasing the window only after the drain | `glfw-tests` |
| window-examples | GLFW / GLFW window host / quiescence and shutdown / drains an abandoned managed startup before quiescence, then settles queued callers and releases the window after the drain | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / creation / hands over a created window's port and observations beside its prepared completion, only after its initial observation, without creation or cross-window authority | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / creation / rejects creation beyond the live-window limit and an invalid configuration before any native effect | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / creation / rolls a failed construction back with its native evidence, registering nothing and consuming no capacity | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / creation / propagates a construction failure whose rollback failed as the host's primary failure, interrupting its ticket, settling the queued command behind it, and stopping the loop | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / creation / keeps a window whose creation ticket nobody awaits enumerable, live through the drain, and disposed at shutdown | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / creation / rolls back a construction cancelled from another thread, registering nothing, reclaiming its capacity, and handing nothing over | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / creation / keeps a window registered and enumerable when a cancellation pending across its registration lands before its result is published | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / the close protocol / closes the middle of three windows, leaving the others observing and executing | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / the close protocol / closes windows in the order A, B, C through their own ports, disposing each with its callbacks detached first | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / the close protocol / closes windows in the order C, A, B through their own ports, disposing each with its callbacks detached first | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / the close protocol / answers a retained port, borrow, and close of a disposed window with typed terminal results and no native call | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / the close protocol / settles a closing window's queued callers as not executed, after the commands its port admitted first | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / the close protocol / defers retirement while a window is borrowed, publishing its closing phase first and its disposal before its snapshot closes | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / the close protocol / latches a failed release as disposal failed, never retries it, poisons creation, and keeps it as evidence at final exit | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / the close protocol / keeps the body's failure primary with a latched release failure retained beside it | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / churn and shutdown / keeps bookkeeping bounded across repeated creation and honoured close requests, never reissuing an identity | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / churn and shutdown / closes every port before the drain and disposes closing and live windows once each after it, settling racing closes as not executed | `glfw-tests` |
| window-examples | GLFW / GLFW dynamic windows / fair dispatch / serves a waiting window port and the host port within the documented turn bound beside a replenished port, under one budget, through rejections, closure, and creation | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / observations / publishes an empty inventory as revision zero of an observation, and republishes nothing unchanged | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / observations / describes monitors at negative and nonzero desktop origins, reporting the primary only as an attribute | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / observations / turns inconsistent native numbers into unavailable fields rather than fabricated values | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / observations / makes an inconsistent enumeration unavailable and ends every identity until a consistent one | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / observations / reports a query GLFW calls unavailable as unavailable, and fails the boundary on any other report | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / identities / ends an identity on disconnect while its copied description stays readable | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / identities / issues a fresh identity to a monitor reconnected at the same native address, and keeps identities through reordering | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / identities / answers a stale identity as disconnected before any native operation targets its monitor | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / identities / never resolves an identity from a completed session in a later one, though its number and address repeat | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / the monitor callback / rethrows a callback fault at the next boundary with its context and ends every identity | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / the monitor callback / ends every identity after more changes than one boundary keeps, or an event code GLFW does not define | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / the monitor callback / raises a fault latched after the last boundary from the session's release, which still completes | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / ownership and teardown / refuses monitor operations off the owner thread before any native call, while any thread reads the inventory | `glfw-tests` |
| window-examples | GLFW / GLFW monitor inventory / ownership and teardown / closes the inventory before termination: the last descriptions stay readable, waiters wake, and the callback is detached first and freed last | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / events and gates / delivers key, text, button, scroll, and focus as distinct, uncoalesced events tagged with their window and epoch | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / events and gates / gates input before readiness and while unfocused, needs no reset to stay disabled before readiness, and delivers the focus loss that closes the focus gate | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / events and gates / keeps a button event's captured cursor position and modifiers after later cursor motion | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / events and gates / clears held state on focus loss, so a later repeat or release is unpaired until a fresh press | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / overflow reset / keeps one stable token per episode across repeated overflow, suppressing into bounded, exact counters | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / overflow reset / accounts the discarded backlog exactly, apart from the overflowing event and from events already delivered | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / overflow reset / delivers no old backlog after the reset, and no new-epoch input before acknowledgement and resumption | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / overflow reset / answers foreign, duplicate, stale, and closed acknowledgements as specified | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / overflow reset / leaves a feed paused and closable when its consumer is cancelled before acknowledging | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / overflow reset / ends reads at closure during a pending or acknowledged reset, without delivering the reset first | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / overflow reset / loses resumption to a closure committed after the candidate channel was allocated, publishing no channel | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / overflow reset / gives a key or button held at a reset no synthetic press in the new epoch, while a fresh press is delivered | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / overflow reset / overflows two windows' feeds independently | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / overflow warning / writes one warning per episode through the injected logger, and blocks resumption until the attempt completes | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / overflow warning / retains an episode whose warning sink failed in final observations, without trying the sink again | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / overflow warning / retains an episode whose warning attempt shutdown cancelled, or prevented, in final observations | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / callback staging / delivers key, character, button, and scroll from callbacks as tagged, uncoalesced events, and coalesces cursor into the observation | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / callback staging / keeps a button event's captured coordinates after later cursor motion through callbacks | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / callback staging / keeps a button event's captured coordinates when motion and the button occur in separate owner turns | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / callback staging / sets the staging loss latch while the buffer is full and begins the same reset, replaying no captured prefix | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / callback staging / keeps the focus gate current when focus loss is discarded with a staging overflow | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / callback staging / publishes a captured batch to completion before a cancellation at the publication boundary | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / callback staging / does not synthesize a press from a release delivered through a callback | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / callback staging / gates callback input until admission is opened explicitly | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / callback staging / leaves a second window's feed running when the first window's staging overflows | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / callback staging / delivers focus loss and gain in native order, and a focus transition that cannot be admitted starts the reset | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / application suspension / leaves no backlog or held state after press, suspend, suppressed release, and enable, and needs acknowledgement, resumption, and a fresh press | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / application suspension / resumes only once acknowledged and re-enabled, in either order | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / application suspension / keeps one token and epoch through repeated toggles during one reset | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / application suspension / preserves an overflow reset's token and warning obligation when input is suspended during it | `glfw-tests` |
| window-examples | GLFW / GLFW input feeds / application suspension / lets closure win every suspension and resumption race, and a changed gate leave the candidate unpublished | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / restoration / leaves a repeated request inert and never restores stale placement over a window moved since | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / restoration / keeps the saved placement across windowed, fullscreen, borderless, and windowed, placing borderless over a work area at negative coordinates | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / restoration / seeds the saved placement from the actual window before a startup transition straight into fullscreen | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / restoration / ends a long chain of transitions at the original placement | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / restoration / keeps a user's windowed move and resize through a later transition and return | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / restoration / treats a request as inert only on complete equality with a cleanly applied target | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / restoration / never treats a borderless request as inert after its monitor detached, even before anything refreshed the inventory | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / restoration / applies a repeated fullscreen request again when the observed size or the monitor's current video mode diverged | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / validation / refuses unrepresentable preferences, budgets, and placements, and unreported video modes, before any native setter | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / rejects a disconnected selected monitor without a fallback, and returns to the windowed placement with one | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / falls back through the owner loop when the applied monitor disconnects, deriving a reachable placement and keeping the saved one | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / follows a borderless window a later move callback carries onto another monitor's work area through the owner loop, with no synchronization | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / reports finite exhaustion when no monitor remains to place the window in | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / recovers through the configured fallback when an observation intervenes before reconciliation, and never repeats it | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / recovers when the observation precedes the inventory refresh that ends the identity | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / recovers when an observation command intervenes, and a refused request leaves the recovery pending | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / recovers a borderless window from the indeterminate observation its disconnect leaves | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / reports exhaustion once across an intervening observation and never revives it through refreshes, observations, or a reconnect | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / only resamples an observed disconnect with no fallback configured, reporting the platform's truth | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / lets a request settled after the disconnect supersede the pending recovery | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / recovers a borderless window moved onto another live monitor by a callback when that monitor disconnects, and never repeats it | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / recovers a borderless window moved onto another live monitor by a full sample when that monitor disconnects, and never repeats it | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / keeps a borderless window moved by a callback on its live monitor, with no fallback, when the monitor it left disconnects | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / keeps a borderless window moved by a full sample on its live monitor, with no fallback, when the monitor it left disconnects | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / keeps the obligation on the ended monitor when the move is observed by a callback after its native disconnect and before the refresh | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / keeps the obligation on the ended monitor when the move is observed by a full sample after its native disconnect and before the refresh | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / recovers from a confirmed monitor's disconnect across a move callback folded before the refresh that ends it | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / recovers from a confirmed monitor's disconnect across a full sample taken before the refresh that ends it | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / only resamples a confirmed monitor's disconnect with no fallback configured, answering the followed obligation once | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / recovers through the owner loop when the monitor a borderless window was moved onto disconnects a turn after the move was confirmed | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / settles borderless placement the platform cannot perform as unsupported, never as fullscreen | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / reports a partial native failure with its completed steps and retains the pre-departure geometry for a later return | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / restores the pre-departure geometry through the configured fallback when a departure fails partway | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / restores the pre-departure geometry under constraints that admit it and exclude the stale size | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / retains the pre-departure geometry when a departure is interrupted after a native step | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / stops recovery when restoring the windowed constraints fails during an attempt's cleanup, and a later refusal makes no setter | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / propagates a cleanup that raises instead of reporting, settling its command as interrupted rather than as data | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / restores suspended windowed constraints when a windowed return decorates the window but fails to place it | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fallback and disconnection / fails a required startup mode under the required policy, rolling the window back, and records an optional one, refused or not | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fullscreen claims / gives a second window MonitorBusy without native effect or record, including while the first is iconified and with a fallback configured | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fullscreen claims / claims different monitors independently and releases each claim in both close orders | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fullscreen claims / releases a claim as soon as a refresh observes its monitor disconnected | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fullscreen claims / keeps claims unavailable after an unobserved transition or a failed disposal until a later sample proves release | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fullscreen claims / switches monitors by reserving the destination first and releasing the source only after confirmed departure | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fullscreen claims / settles the claims of a fullscreen attempt interrupted by a raising native step as uncertain until reconciliation, and releases an unused reservation | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fullscreen claims / prunes an ended monitor's claim after a refresh that commits and then rethrows a monitor callback fault | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / fullscreen claims / releases a fullscreen reservation cancelled after it was committed and before the first native step | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / eligibility / applies the operation matrix after entering each mode, rejecting ineligible controls before any native setter | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / eligibility / refuses controls that depend on an indeterminate presentation until a later synchronization establishes one | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / eligibility / refuses commands inside a transition's interval, serves another window there, and admits them after settlement | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / eligibility / suspends windowed constraints for borderless, restores them on return, and refuses a placement they exclude | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / eligibility / refuses every transition, and any windowed return, before a setter while a partial constraint update left the constraints indeterminate | `glfw-tests` |
| window-examples | GLFW / GLFW window modes / observations / names the revision its final sample published, which reports the applied mode and geometry observed | `glfw-tests` |
