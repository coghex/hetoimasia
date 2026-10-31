# LFE-23: integrated failure and two-instance ownership, qualified headlessly

Issue [#538](https://github.com/coghex/hetoimasia/issues/538), epic #514, after LFE-22 ([#537](https://github.com/coghex/hetoimasia/issues/537)).
This is the acceptance map and the evidence record of the integrated groups. It states what each group runs for real, what
it injects, what it observes and which contract it answers. The commands, counts, code revision and CI receipts of a given
head are in the pull request body, which is the record of that head; this document describes the groups and does not
change with the head.

Controlled completion is evidence of the adapters' ownership transitions, ordering and cleanup. It is not evidence of
pixels, a displayed frame, GPU retirement or desktop behavior: those are LFE-24 and LFE-25. No group here acquires a GLFW
session, a display, a device or a window, reads a consent variable, sleeps, or asserts a performance figure.

## Where the groups are

| Suite (validation group) | Command | Integrated groups | Why there |
| --- | --- | --- | --- |
| `hetoimasia-lua-engine:lua-engine-tests` (`test.lua-engine`) | `cabal test --project-file cabal.project.cpu hetoimasia-lua-engine:lua-engine-tests --test-option=--match --test-option=Integrated` | `Integrated` (`Test.LuaEngine.Integrated.*`) | CPU-only: the real services over injected clocks, timers, sinks and read gates; no graphics dependency. The session harness (a private sublibrary) is reachable from this suite alone. |
| `hetoimasia-lua-engine-graphics:lua-engine-graphics-tests` (`test.vulkan-headless`) | `bash tools/vulkan/run.sh test hetoimasia-lua-engine-graphics:lua-engine-graphics-tests -- --match "M1 integrated"` | `M1 integrated texture, window and scene ownership across two instances` (`Test.LuaEngine.Graphics.Integrated`) | Graphics-linked: the real texture pipeline, window provider and scene publisher over the stand-in owner, windows and host. |
| `hetoimasia:hetoimasia-tests`, full-product build (`test.vulkan-headless`) | `bash tools/vulkan/run.sh test hetoimasia:hetoimasia-tests -- --match "Integrated endings"` | `Run`, `Integrated endings (LFE-23)` (`Test.Engine.Run.Integrated`) | The application composition and its exit mapping, the real `runGame` composition without graphics. |

The delivered suite targets are spelled as the issue spells them (`content-tests`, `lua-runtime-tests`, `lua-engine-tests`,
`lua-engine-graphics-tests`, `hetoimasia-tests`); no mapping is needed and no package or suite was created for this slice.
The planner selects these groups from the existing package inputs: `python3 tools/validation/plan.py --base origin/master
--head HEAD` reports `test.lua-engine` and `test.vulkan-headless` affected, with the mandatory floor, and also lists the
native groups (`test.vulkan-lua-engine-native`, `test.vulkan-run-native`) whose input directories this change touches. Those
are CI's (an isolated display on Linux); this slice runs none of them locally and needs no desktop. The catalog is not
edited: `tools/validation/` is a policy input, and a catalog change would mark every group affected without selecting
anything more.

## Real and injected, by name

| Real, in every group | Injected, and only these |
| --- | --- |
| Filtered Lua VMs and their supervised owners; instance construction and attribution through `declareInstance` and `admitBehaviorInstance`; module environments, loader, cache and the one export table per VM; the content root, inventory and verified read pool with its two workers; the data service; request reservations; the facade; the coordinator; the session coordinator (`runSession`) with its roles, gates, status and outcome | The monotonic clock and its timer; the recording output sinks; the facade's admission, status and quit endpoints where a group composes the facade directly (the session's own are used where it runs the session); gates around the pool's reader (a gated read still opens and hashes a real file once the gate opens); the session harness's probe points |
| Graphics groups, in addition: the bounded PNG decoder, the CPU texture pipeline and backend, the window provider, the scene publisher and its hold ledger | The texture owner's native operations (allocation, upload start and completion, registration, release, table reclamation); the native windows; the host's adoption and use of published scenes |
| Root group: `Hetoimasia.Run.runGame`, the production session over a real folder | The coordinator's signal delivery (not an OS signal: that is the process examples') |

The second instance of a role is admitted, in the facade-level groups (`Instances`, `Jobs`, `Capacity`) and in the graphics groups,
through the construction path the launcher uses: `declareInstance` plus `admitBehaviorInstance`, ended by
`requestInstanceControl ... InstanceStop`. These are public composition points already delivered, so no capability is missing there.

The session-level groups (`Roles`) use only the public `runSession` composition (`noHarness`): one UI instance beside the logical
owner, no probe point, no tick base, no removed protection; every gate they hold is a Lua-side wait on a gated read at the pool's
reader, a parked line of authored output, or a clock they move. A *second instance of a role inside a running session* is reachable
only through the session harness's second slot (a private sublibrary), which the approved contract keeps out of this slice, so
that window is recorded below with the owning slices' evidence and reported to the manager rather than reached.

## Acceptance map

Each row names the example, what it runs, what it injects, what it observes and the contract it answers. "Prerequisite
contract" cites the accepted design (`docs/designs/lua_first_engine_design.md`).

| Scenario | Example | Injected boundary | Observable assertions | Prerequisite contract |
| --- | --- | --- | --- | --- |
| Two UI instances plus an independent logical owner | `Integrated`, `M1 integrated ownership`: *gives two UI instances and a logical owner separate self and capabilities…* | clock/timer, sinks | ids `inst-1..3` distinct, one content id, the right role for each; the two UI instances see one export table and its mutable state, the logical VM its own (one evaluation per VM, two in all); a peer's facade and request handle refused as ordinary errors, no read of the file the refused call named; an edit of another instance's saved API table changes nothing the engine attributes (warning identity, the owner's own request) | P-40 part 4, P-72, D-58 |
| Stable controlled FIFO | *serves two ready UI instances of one VM first-in first-out…* | clock/timer | with both ready at one instant and A admitted first: A runs to its yield, B's whole non-yielding segment follows uninterrupted, A resumes (`A pre`, `B 1..3`, `A post`); no cross-VM order is asserted | P-40 part 4 |
| End A during pending work (CPU) | *ends one UI instance with a read in flight…* | read gate | A stays `Stopping` while its borrowed read is held; B keeps serving and sees the module A loaded as the same table; A's handle and facade act on nothing; A settles `Stopped` only after the read returns, delivering nothing | D-57, D-72 |
| Same-path PNGs, opposite completion orders | `M1 integrated texture, window and scene ownership across two instances`: *loads the same PNG for two instances as two independent…* | native upload completion, held per upload ticket | two allocations, uploads and registrations (no coalescing); B's upload completes and registers before A's has completed, B alone is told; A is delivered its own, after; distinct handles; a peer's handle authorizes neither release nor publication, and nothing is released | D-49 |
| End A during pending work (graphics) | *ends A while its upload is open…* | upload completion held | A is not delivered; A's end is not complete while its upload is open (it cannot be withdrawn once started) and retires `Stopped` with no failed lease only after the completion is supplied; B publishes and republishes on its own window and lease meanwhile and is never closed | D-52, D-54, D-72 |
| End A after publish and release | *ends A after both instances published and released…* | table-version holder, host adoption | A's retained use outlives the end while the device holds the table version; B's accepted scene and window survive; a new publication on B's released lease is refused (`false`) and an empty scene (`clear` and `sprites = {}`) is accepted; A retires `Stopped` once the version is let go; ending B retires its holdings | D-54, D-88 |
| Shared module waiter leaves, then all leave | `Integrated shared jobs and assigned results`: *keeps a shared module job and the peer's result…* | read gate | one read and one VM-owned job for two waiters; the waiter that ends does not stop the job; the peer's result is delivered; the last waiter's cancel leaves a job that still finishes and caches at its retained position; a later request is served from the cache with no new read; a broken module with no waiter is logged, cached and fails no instance | D-57 |
| VM stop with a borrowed read | *stops a VM closed to evaluation while a module read is borrowed…* | read gate | the owner ends, the borrowed read returns to the pool, the module is never evaluated | D-57 |
| Delayed logical result with UI traffic | *settles a logical result at its assigned tick…* | read gate, clock | an early result is read long before its position and stays unavailable; a late required read holds its tick exactly (`ownerTick` stays) however far the clock moves; the UI's own reads finish through the second worker meanwhile; ticks 1..5 each once, none dropped or stretched | D-67, D-77 part 4 |
| Active import against prefetch; A due at 10, B requested for 12 | *evaluates a module once in its importer's chain…* | read gates | A is evaluated at tick 10 with B evaluated once in its chain and C, which nobody asked for, read on demand ahead of the prefetch queued earlier once a worker is free; B's own request is not visible at 10 and 11 and is at 12, the same table A's chain evaluated | D-58, D-77 part 4 |
| Texture work, an uncached import and logical results sharing the pool | `M1 integrated texture…`: *serves a UI peer's uncached import and data read through the free worker while a texture's upload is open and a logical module read holds its tick…* | upload completion held; read gate with an entry acknowledgement; ticks granted by the example | a logical owner (its own coordinator, facade and scheduled owner over the same pool) asked for a module due at tick 3 and data due at tick 5; the module's read is borrowed and held while A's upload is open at the owner; B's two-file import chain (nobody had read it) and data finish through the other worker; the held tick does not complete however far the UI goes on; ticks 1 to 5 each once with the module visible from 3 and the data from 5 | D-67, D-77 part 4 |
| Both init orders and failure around the joint gate | `Integrated role failure, status and outcome`, `both initialization orders` (three examples) | a parked line of authored output | the UI instance starts on its own success while the logical init is held and the logical clock opens only at the joint gate; the logical role waits `ready`, with no tick, while the UI instance's init is held; the UI instance's init failing before the joint gate ends the whole session, retires both sides, runs no logical update and attributes the failure to the presentation instance, whether or not the logical init had begun | D-42 |
| Postboot logical failure, then UI stop; later cleanup fault | `after a successful start`: *stops the logical role alone…*; root `Integrated endings`: *a failing close during an interrupted stop is 1* | none beyond the clock; the coordinator's signal delivery at the root | the logical failure is published and attributed with `stopping=false` while the UI instance runs, stays the same record as the phase reaches retired, grants nothing after the failing tick, and a later UI stop is a failure; at the root, the logical role's suspended work failing to close while an interruption stops the session is 1, not 130, and the report names it (the session-level cleanup-fault case with a second instance is a recorded window below) | D-42, D-26 |
| UI or one-role failure; the caught state guard | *ends the whole session when a UI instance fails…*, *keeps the unavailable-state guard terminal…* (update and shared-module top level), *ends a session of the … role alone…* (two) | none beyond the clock | the UI instance's failure ends the session with the right identity and runs every shutdown once; a role that is the whole session fails it; the guard caught by a script is terminal, claimed once (one diagnostic) in both VMs, no role blamed | D-26, D-76 |
| Quit with full queues | *quits from the logical role while the UI instance holds every request place it can…* | read gates (the logical role waits on one) | `quit` returns at once with every place held; a later content request is an ordinary error and never busy; cancel and output work; the role retires only after the held reads return | D-72, D-77 |
| Status through the facade | *reads a status that is one coherent copy within a UI segment…* | read gates (the instance waits on one, the logical failure on another, so the failure cannot precede the instance's first sample) | two reads in one segment are equal, an edit of one reaches no later read, and the instance sees the failure after it resumes | D-76 |
| The same public assembly | *runs … from the manifest alone…* (six) | none | common entry, separate entries and each one-role variant start each present role once and stop with success | D-42 |
| Full capacity then cancel and late completion | `Integrated capacity…`: *answers busy atomically…*; graphics: *answers the ninth texture request…* | read gates, upload completion | busy is atomic (nothing reserved, no read of the refused file); cancelling a read a worker holds does not free its place, only the read's return does (and, for a texture, the proof of retirement); queued work withdrawn without any read frees exactly one place while the reads stay held; the peer's bank is untouched; accepted work never turns busy | D-52, D-54, D-77 |
| One return of room at the end | *returns an ended instance's room exactly once…* | none | results never taken and handles dropped leave a room the next instance fills exactly again and not by one more | D-54 |
| Failure over interruption over a normal stop; cleanup fault; guard (application) | `Run`, `Integrated endings (LFE-23)` (seven) | the coordinator's signal delivery | a normal quit is 0; an interruption alone 130 with the shutdown run; a quit during an interrupted stop still 130; a logical failure then an interruption or a later quit is 1; a failing close during an interrupted stop is 1 and the report names it; a caught guard is 1 with one diagnostic | D-26, D-42 |

## Counts of what the saturating groups reach

* CPU: the pool this harness injects has two workers and twelve slots, and each of the VM's coordinators holds four, so
  eight data reads can be held in all (derived from those constants, not read back). The profile's 16 places per instance
  and 64 per VM are not reachable before the pool is full and are not faked; the facade's own examples (`Facade.Limits`) cover
  those bounds.
* Graphics: the fixed profile's 128 MiB texture bytes per UI instance hold eight 16 MiB nominal reservations. The group holds
  the picture's reads at the pool's reader, so no decode has shrunk a reservation, and the ninth request is busy.

## Windows not reachable at the integrated boundary

The amended rule for Requirement 6 (comment 6337122532) is followed: a window is gated on both sides wherever the injected
boundaries and the prerequisites' public Haskell control points reach it; where it cannot be reached without a private
import or a new hook, it is recorded here, with the owning slice's test as its evidence, and nothing is imported, hooked
or dropped silently.

| Window | Why it is not reachable here | Owning evidence |
| --- | --- | --- |
| Between reservation and tracking of a request inside one Lua call | no injected boundary or public control point lies inside a single call | `Test.LuaEngine.Request.*`, `Test.LuaEngine.Facade.Requests` |
| Issuance and stop, and the points of the session's life | the probe points are the harness's (private); the integrated groups place none and gate with Lua-side waits, parked output and reader gates instead | `Test.LuaEngine.Session.Stop`, `Session.Startup`, `Session.Commit` |
| Result and lease publication, the final scene authority check, dependent-owner teardown | the publication hooks are the graphics package's own test seam (`noPublishHooks`); the integrated groups use the production publisher without them | `Test.LuaEngine.Graphics.ScenePublication`, `Lifecycle`, `Stages`, `Teardown` |
| A late logical init success after the UI's init failed ("late success cannot reopen a stopped gate") | placing the failure after the logical init has begun, and the success after the failure, needs an ordering point inside the dispatch that only the harness's probe points give; with the public composition the UI can fail before the logical init has started, so an example cannot rely on it | `Test.LuaEngine.Session.Startup` (*stops while either init is held: the init that succeeds late is shut down as stopped, and the gate stays shut*, *fails the boot when an init fails after the other role's init succeeded…*) |
| A second instance of a role inside a running session (`runSession`): a second UI instance failing or failing to initialize beside the first, a second logical instance whose suspended work fails to close after the first failed | the second slot is the session harness's, a private sublibrary; no public composition reaches it | `Test.LuaEngine.Session.Startup` (every instance validated before any init), `Session.Api` (two instances' captures), `Session.Stop` (one instance's failure, its peer stopped), `Session.Failures` (*ends even a previously healthy presentation role when the logical role's cleanup then fails*); the root group *a failing close during an interrupted stop is 1* covers the cleanup fault through the real composition |
| Publication by an instance after a peer fully ended, B retaining a live lease | covered by the existing two-instance example `Test.LuaEngine.Graphics.Peers` (*leaves a surviving instance's window and texture usable and publishable when its peer ends…*); the integrated example *ends A while its upload is open…* places B's republication while A's end is still draining | `Graphics.Peers` |

## Not production findings

The integration exposed no production bug and no missing contract. Observations worth knowing, none of them a defect:

* a published scene that clears and sprites nothing must still carry `sprites = {}`; the empty scene is a valid table, not
  an absent field;
* a refused ask after a cancel is still busy until the work retires, and a withdrawn queued texture request returns its
  place through the pipeline's own housekeeping, shortly after the cancel call and not inside it, so a group that checks it
  retries until it is accepted and then checks that exactly one place came back.
