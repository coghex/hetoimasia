# The generic `run` command

`hetoimasia run GAME_ROOT` is the Lua-first engine's launcher (LFE-22, [#537](https://github.com/coghex/hetoimasia/issues/537)).
It knows how to assemble the engine's services, not what game or scene to run: everything a game is lives in the folder
it is given. The design is [the Lua-first engine design](designs/lua_first_engine_design.md) (P-71, P-73, P-74, D-74 to D-77
and D-80); this document is what the command does today.

## Two builds of one executable

The executable keeps its name, `hetoimasia`. The `run` command exists only in the **full-product build**:

| Build | How | `run` |
| --- | --- | --- |
| default, `--project-file cabal.project.cpu` | `cabal build all` | not a command: `hetoimasia run x` is an unknown argument (usage, exit 2), and the usage line and help name no such command |
| full product | `bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia` | dispatched to the private `run` library |

The root package's manual flag `full-product` (default off) selects the build, and only `cabal.project.vulkan` turns it on.
With it off the `run` library is not buildable and adds no dependency: the CPU build plans resolve nothing of GLFW, Vulkan or the
graphics adapter. This is build selection and nothing else: there is no runtime fallback, no second command, no fake graphics
provider and no option that selects one. The production `run` command neither reads nor requires `HETOIMASIA_NATIVE_SESSION`;
that variable gates native *test suites*, never the user's command.

```sh
# the full-product executable, against the provisioned native prefix
bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia
# launch it (macOS: a window appears; the shipped quad never quits by itself, so close the window or send SIGTERM)
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia:exe:hetoimasia -- run samples/lua-quad/content
```

The `HETOIMASIA_NATIVE_SESSION` on that second command belongs to the runner's `native` mode, which starts a binary that may open
windows; the `run` command itself ignores it. On Linux the runner starts an isolated X11 display when no consent is given.

## Grammar

```text
hetoimasia run GAME_ROOT
hetoimasia run -- GAME_ROOT
hetoimasia run --help
```

Exactly one folder. Without `--`, an argument that starts with a hyphen is an unknown option; after it the next argument is
literal, `--help` included. `run --help` alone prints the help on stdout and exits 0. A missing or extra argument and every other
option is a usage error: the usage line and a one-line, escaped reason on stderr, nothing on stdout, exit 2, decided by a pure
function before the folder, a handler, a worker or native graphics is touched. The fatal logging configuration is still resolved first, so a
bad `HETOIMASIA_LOG_LEVEL` fails even `run --help`. There is no default root, parent search, entry override, mod flag, seed,
cadence or window option, and no forwarding of arguments to a script.

## What `run` does, in order

1. Validate the arguments (above).
2. Install SIGINT and SIGTERM handlers sharing one coordinator, for the scope of the run; put the previous handlers back when it ends.
3. Enter the logging lifetime over stderr (left last; it makes the one final flush).
4. **Prepare the folder** (`Hetoimasia.Run.Boot`): open it once, anchored (the launch pathname is never opened again), and log
   `content root resolved` with the selection as typed, the pathname the system reported and the directory identity; read
   `hetoimasia.json` through the root and parse it with the strict format-1 parser (its `id` is the content identity the
   inventory is keyed by); scan the *whole* folder under the fixed profile's numbers (hidden and unused files too); require the
   manifest bytes parsed to be the bytes the scan pinned; run the boot checkpoint, which validates every declared entry
   (an overridden common entry included) as an inventoried regular file. Any refusal is a **boot failure (1)** and nothing authored
   has run. A first signal here abandons the work, which is cancelled and joined before the root closes.
5. **Start the native owners** on the process main thread (`Hetoimasia.Run.Graphics`): the loader integration, the graphics owner
   (the device starts *without a surface*, so a texture can be GPU-ready before any window exists), the texture adapter and, inside the
   session, the window provider.
6. **Run one session** (`Hetoimasia.Run.Session`) on a thread of its own: two read workers, one decode worker and two texture
   lanes, made once; each selected role's VM evaluates its entry (a common entry runs separately in each); both selected behaviors
   validate before either `init`; the `init`s are dispatched concurrently; the logical clock opens through the joint start gate.
7. Map the outcome to an exit status after every scope has unwound.

Evaluating the selected entries and validating the behaviors can themselves execute Lua and fail; those failures are exit 1 and start
neither `init`. Path-level validation (root, manifest, inventory, declared entry paths) completes before any authored evaluation.

## Roles

The default is both roles on the manifest's common `entry`; `vms` may select either role alone or give each its own entry. A
one-role session does not invent the other. The normal launch creates one root instance per selected role; there is no mod and no
public spawn call.

## Exit status

| Status | When |
| --- | --- |
| 0 | a Lua `quit`, a native user close, or an orderly end |
| 1 | a root, manifest, content, entry or boot failure; a script, required-request, host, provider, output or cleanup failure; a session whose roles did not all retire; a caught call of `state(...)`; an unclean diagnostic capture |
| 2 | invalid command syntax |
| 130 | an orderly SIGINT or SIGTERM stop that failed nothing |

A failure outranks an interruption, which outranks a normal quit, in every order they arrive; an error after a quit, a sink failure or
a cleanup failure overrides a normal or signal stop. An ordinary logical failure after the start with a healthy UI leaves that UI
running, and its later quit still exits 1. A UI failure, or the failure of a one-role session, ends the session.

## Signals

The first signal, of either kind, requests an orderly whole-session stop and returns without waiting: during scanning, module
loading, `init`, a running session or a surviving error UI. A second signal while stopping leaves the process **at once with
status 130**, running no hook, cleanup or flush, even when a failure was already recorded; the two signals share one count, and the
force happens at most once. The force is a real immediate exit in the root application, never a catchable exception, and no reusable
provider exits the process. A script that never returns can still block the first, orderly stop: there is no new hard-preemption
promise for trusted Lua.

## Native close

A genuine native close request (the window's own, never a close the provider itself began) is the same whole-session normal stop
as a Lua `quit`, including during startup. Closing a window for cleanup generates no user quit.

## Ownership

| State | Owner | Thread | Ends |
| --- | --- | --- | --- |
| anchored root, inventory, checkpoint | the preparation scope | main | after the session and its pool |
| read pool (2 workers), texture pipeline (1 decode worker, 2 lanes) | the session composition, once per session | their own workers | after the window provider, before the root |
| GLFW, the device and the owner loop | the native owner application | the process main thread and the owner's thread | after the session has settled; if the loop is lost, the application's own exit destroys the windows first and the session is joined after |
| texture adapter, pool, pipeline | the session thread | the session thread and its workers | before the session thread ends |
| window provider | the session composition | its pump; the main step on the main thread | before the pipeline and the adapter drain |
| session diagnostics writer | `runSession` | its own thread | joined by the command before the logger is released |
| session, role VMs | `runSession` | the session thread | actual retirement of every role |
| signal handlers, coordinator | the run scope | a handler thread per delivery | the end of the run |

Neither CPU scope exit, a cancellation, a timeout nor a thread finishing proves GPU retirement; retirement is read from the owners.

## When something fails during shutdown

Every wait of the launcher's shutdown follows the same rules (`Hetoimasia.Run.Settle`): it is never made uninterruptible; a
cancellation delivered meanwhile is remembered across the *whole* sequence it belongs to and raised after it, with the failures
that sequence found retained beside it, never instead of them; catching a failure to examine it never swallows a cancellation; and a
diagnostic that cannot be written never replaces what it reports.

* **Preparation** (`Boot.abortable`) runs on a thread of its own. A stop cancels and joins it before the root closes. The child's
  terminal outcome is read: a clean cancellation is an orderly stop (130), but a cleanup that failed under the cancellation is a failure
  (1). A cancellation of the caller, whether it arrives in the wait or while the cancellation is being sent, still cancels and joins the
  child first, and the child's cleanup evidence is retained beside it.
* **Who owns what** (`Serve`): the *session thread* owns every scope the session uses (the texture adapter, the pool, the pipeline, the
  window provider, the roles) and ends them itself. The *process main thread* owns only the native owner application (GLFW, the device and
  the loop) and the root, and serves the loop.
* **The owner loop failing** (or the main thread being cancelled in it): the session is asked to stop and the owner is served *again* by a
  drain loop until the session has settled, because the session's cleanup closes windows and waits for their native destruction, which only
  the main thread performs. The drain makes its own supervision, since the application's may have latched the very failure that ended the
  loop. A failing drain is run again, three times in all.
* **The session thread, the handle and the loop's guard are one masked step** (`serveSpawned`): the thread is created, its handle recorded
  where the join will find it, and the loop entered inside the guard before asynchronous exceptions are enabled at all, so a cancellation
  already pending when the loop is entered lands inside the guard and stops the session like any other failure of the loop. The
  application that owns the loop is itself run in one masked step (`runOwned`): only the application runs with asynchronous exceptions
  enabled, and capturing whatever ended it, stopping the session, joining it (so its failure is kept beside the application's) and
  combining the evidence are one sequence in which a cancellation is only remembered and is raised last as the primary failure. A caught
  failure's continuation never resumes unmasked, so no cancellation can land between the application's teardown and the join, and the
  join never depends on the loop's guard having run.
* **The owner lost for good** (the drain fails every time): the loop's failure is raised at once, *without* joining the session. That
  hands the owner back to its application's own protected exit, which performs the verified destruction of the windows the loop could not.
  The session, whose providers then see a finished owner, settles, and the command joins it *after* the application has torn down,
  retaining the session's failure beside the loop's (once, however often it is asked).
* **The session's diagnostics writer** may outlive `runSession` and borrows the logger, so it is joined before the logging lifetime
  releases the logger, after every scope the session used has unwound, on a failure as well as a success. A cancellation during that
  join does not hide the failure of what was being run: both are raised together.
* **Reporting.** A failure raised inside the logging lifetime goes through it unchanged, so the lifetime applies its own rules. Every
  startup diagnostic is marked as the diagnostics' own, so a write that fails is not followed by a final flush through that path, and when
  the diagnostic path is what failed the command writes no terminal line through it either (the status is the same). Otherwise boot and
  host failures are reported by one best-effort line on stderr after every scope has unwound, carrying the cleanup failures retained beside
  the primary one, never through the logger.
* **A diagnostic write that fails while something else unwinds is recorded, not dropped.** The drain's report, the verdict's warning and
  the session's own sink failures (the session's writer counts the writes its sink refused and returns them as data in the outcome, raising
  nothing) are written through, or carried into, the logging lifetime as a failed report (`reportDiagnostic`, `notePathFailure`,
  `noteSessionDiagnostics`). The session's refusals are recorded at their source: in `runPrepared`,
  from the session handle bound to the link (`noteLinkedDiagnostics`), when `runSession` ends, on a return and on an exception alike and
  while every scope the session used is still open; and once more after the writer has been joined, for a refusal in its tail. Nothing
  depends on `runSession` having answered, so neither a failure it raises nor a cleanup that fails afterwards can report or flush before
  the record exists.
* **Typed failures are never reduced to the first of several.** The content layer keeps a failure beside another (a descriptor that would
  not close after a read failed) in the exception's context. Wherever the launcher turns such a failure into text (the root refusal and
  the manifest read in `Boot`, the final failure line in `Run`), it does so from the failure *with its context* (`withEvidence`), so the
  bounded line names the retained cleanup failures too. The first failure is kept as evidence beside the primary failure, nothing more is written through that path
  by the launcher, and the lifetime makes no final flush through it. The status is not changed by it.

## Sizing

The generic host's lease and request bounds sit above every M1 reservation that can coexist, and the M1 admission checks its own atomic reservations
first, so ordinary full capacity is the common `busy` answer and never a host fault: a VM's lease scope holds
16 + 1 leases per instance (`facadeLeaseCapacity`); the window provider has `windowSlots` (2) work records; the read pool has 16 slots and
the texture pipeline 16 accepted-work records. No M1 ceiling is changed by this composition.

## Diagnostics

Engine, boot and failure diagnostics go to stderr through the logger, independently of the UI. Authored `print` is plain stdout and
`warn` the attributed stderr line, both through the session's ordered output sinks with the accepted caps and visible truncation.
Output and flush failure is fatal. The launcher adds at most one bounded, escaped reason line for a boot or host failure.

## Tests

* `hetoimasia-tests` (`Run` group, full build; `test.vulkan-headless`): the grammar, the status function, the composition over real
  content with no graphics (roles, failures, boot refusals with a script that must not run, stops), the built executable's usage
  and boot refusals, and the suite's own binary as a child under real signals. See [test_suites.md](test_suites.md).
* `run-native-tests` (`test.vulkan-run-native`): the command's production composition on a real device with real windows, a genuine
  native close, the assembled facade's capacity behavior, and the built command stopped by one SIGTERM.
  `bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia hetoimasia:test:run-native-tests`, then
  `bash tools/vulkan/run.sh native hetoimasia:test:run-native-tests -- --complete` (macOS: with `HETOIMASIA_NATIVE_SESSION=desktop`
  on that command).

These establish launch and lifetime, **not visible output**: no pixel is captured or read back (LFE-24's matrix and LFE-25's platform
qualification are separate).

The actual command's native close is covered per platform, and the split is part of the acceptance:

* **macOS, supervised** (required, run by the owner at the head under review): the launch and lifetime smoke of the real command. A
  person closes its window and the exit status must be 0.

  ```sh
  HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia:exe:hetoimasia -- run samples/lua-quad/content
  ```

  It is not a catalog example and not an unattended routine test: nothing in this repository closes another process's window.
  The command, the clean revision, the platform and the exit status are recorded with the pull request.
* **Linux**: the library-composed `run-native-tests` case delivers a real in-process `WM_DELETE_WINDOW` through the existing native close
  driver (exit 0), and the built command is started on the isolated X11 display and sent exactly one SIGTERM (exit 130). The actual
  command's native close on Linux needs cross-process tooling that does not exist and is **LFE-25's**; none is added here.
