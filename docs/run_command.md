# The generic `run` command

`hetoimasia run [--vulkan-validation] GAME_ROOT` is the Lua-first engine's launcher (LFE-22, [#537](https://github.com/coghex/hetoimasia/issues/537);
the option is LFE-28, [#579](https://github.com/coghex/hetoimasia/issues/579)).
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
hetoimasia run [--vulkan-validation] [--] GAME_ROOT
hetoimasia run --help
```

Exactly one folder. Without `--`, an argument that starts with a hyphen is an unknown option, except the one option below; after
`--` the next argument is literal, `--help` and `--vulkan-validation` included. `run --help` alone prints the help on stdout and
exits 0.

`--vulkan-validation` asks for Vulkan validation, as far as the loader offers it ([Validation](#validation)). It is accepted only
before GAME_ROOT, with or without `--` after it, and at most once. After GAME_ROOT (`run GAME_ROOT --vulkan-validation`), given
twice, with no folder, or beside `--help` it is a usage error.

A missing or extra argument and every other option is a usage error: the usage line and a one-line, escaped reason on stderr,
nothing on stdout, exit 2, decided by a pure function before the folder, a handler, a worker or native graphics is touched. The
fatal logging configuration is still resolved first, so a bad `HETOIMASIA_LOG_LEVEL` fails even `run --help`. There is no default
root, parent search, entry override, mod flag, seed, cadence or window option, and no forwarding of arguments to a script. The one
option is a value of the parse; no environment variable, manifest field, build flag or game content selects it.

## What `run` does, in order

1. Validate the arguments (above), which also settles whether validation was asked for.
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
   session, the window provider. The owner's startup resolves the validation request against the loader's offer and creates the
   instance; the record of what it resolved is logged once, as soon as that startup has finished or failed and before the session,
   so before any window ([Validation](#validation)).
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

## Validation

`--vulkan-validation` (LFE-28) asks for the Khronos validation layer (`VK_LAYER_KHRONOS_validation`) and for synchronization
validation, each **only as far as the loader offers it**. It is a run-time option, not a build flag, so the command that
`run-native-tests` starts can be validated by the same suite, and the loader's offer decides at the moment it is known: in the
owner's instance startup, after the host configuration is fixed. Off, the default, requests no layer and no validation feature and
the instance is created exactly as it was before the option existed.

| The loader offers | Enabled | Recorded |
| --- | --- | --- |
| the layer, and the layer lists `VK_EXT_validation_features` | the layer and synchronization validation | `layer=enabled feature=enabled` |
| the layer, not the extension | the layer only | `layer=enabled feature=dropped` |
| not the layer | neither | `layer=dropped feature=dropped` |
| (not requested) | neither, whatever is offered | `requested=false layer=not-requested feature=not-requested` |

Synchronization validation is enabled only through an *enabled* layer that lists the extension: an extension listed globally, or by a
layer that is not enabled, enables nothing. The decision is `Hetoimasia.GPU.Vulkan.Native.Profile.resolveValidation`, a pure,
device-free function. The strict path is unchanged and is not this option: a layer or feature that a caller names in the host
configuration itself (the four samples' `--validation` and the native suites' fixtures) that the loader lacks is still an
`InstanceRefusal` before anything is created, because those callers must never silently validate less than they claim.

**What is recorded.** Once per run, at `Info`, under the `run.graphics` component, on stderr (never stdout):
`vulkan validation resolved` with the fields `requested`, `layer` and `feature`, then one `Warning`, `vulkan validation item
dropped`, for each item dropped. It is written when the owner's startup has reached the loader's offer, which is before the session
and so before any window; a usage error or a boot refusal reaches no offer and has no record, and none is made up. Normal logging
filters apply (a threshold above `Info` hides the record, not the warnings), and a failure to write it is a diagnostic failure like any
other. In process the same record is data: `readValidationResolution` on the host's controller.

**What "enabled" means, and what is stronger.** The record says the layer and the feature were *selected into the instance's create
info*. That alone is not proof that the loader kept the layer in its chain or that it ran (`VK_LOADER_LAYERS_DISABLE` can drop a
requested layer; see
[the compatibility record](vulkan_compatibility_record.md#zero-validation-errors-is-a-claim-about-coverage-not-just-about-count)).
The stronger evidence is the layer's own: once it is running in the chain, the Khronos layer reports to the diagnostic capture's
messenger at `vkCreateInstance` `Khronos Validation Layer Active`, with the features it was enabled with (for example
`Current Enables: VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT` on the macOS profile's layer 1.3.296; the Linux
profile's 1.3.275 spells it without `_EXT`, so the case keys on the common prefix). The capture hands that record to the logger as a
`Debug` entry of `gpu.vulkan.diagnostics`, which the command's stderr carries under the documented selection
`HETOIMASIA_DEBUG=gpu.vulkan.diagnostics` ([logging](logging.md)); no hook is involved. The validated native case requires it exactly
once with synchronization validation among the enables, and the case without the option requires its absence. A validation error
still latches and fails the run (exit 1), so the cases assert *enabled, loaded and clean*. A layer or feature is dropped only when
the loader does not advertise it; advertised is not proven runnable, so a failure to create the instance or device, and every
validation error, keep their ordinary failure authority and nothing retries without validation.

**What the pinned macOS profile offers.** The provisioned prefix pins loader and layer 1.3.296 and MoltenVK 1.4.2
(`tools/native/vulkan.pin`); the compatibility and crash evidence below was gathered on MoltenVK 1.4.0, which the pin moved on from
only in the library. `VK_LAYER_KHRONOS_validation` 1.3.296 is present in the loaded chain with zero error records
([the proved profile](vulkan_compatibility_record.md#the-proved-profile)); every native instance the suites create enables
synchronization validation through its own create info, and [gpu_backend.md](gpu_backend.md#the-native-suite) records those runs
clean; the first run of the Lua-first adapter's native suite with the layer and synchronization validation ended with a clean
verdict ([the LFE-24 evidence](evidence/lfe24-offscreen-pixels/README.md)); and `synchronization-hazard` in `vulkan-native-tests` shows
the layer active by capturing a deliberate hazard. Nothing in the repository records a validation feature this profile cannot run;
the model has exactly one feature.

**The messenger crash stays unreachable.** Naming a `VkDebugUtilsMessengerEXT` segfaults on the pinned loader and MoltenVK
([the crash evidence](vulkan/macos-debug-utils-naming.md); [Names and labels](gpu_backend.md#names-and-labels)). The option adds no
naming call and does not change the messenger's creation, ownership or its never-named rule on either profile; the messenger is
always created, validation or not.

**In process.** `runNativeWith`, `runNative` and `Setup` take the choice (`ValidationChoice`, `ValidationOff` by default) as an
ordinary value, the one the option parses to: `production ValidationOn`. There is no global, no environment read and no test-only hook.

## Ownership

| State | Owner | Thread | Ends |
| --- | --- | --- | --- |
| anchored root, inventory, checkpoint | the preparation scope | main | after the session and its pool |
| read pool (2 workers), texture pipeline (1 decode worker, 2 lanes) | the session composition, once per session | their own workers | after the window provider, before the root |
| GLFW, the device and the owner loop | the native owner application | the process main thread and the owner's thread | after the session has settled; if the loop is lost, the application's own exit destroys the windows first and the session is joined after |
| the instance's validation request and its resolution record | the graphics owner's startup (written once); read by the process main thread | the owner's thread; read on the main thread | the host's end |
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
* **A refused diagnostic is recorded where it occurs.** The logging lifetime the command runs in is made over a sink that records its own
  refusals (`withRecordingLifetime`): the first write or flush the sink refuses is recorded on the lifetime as a failed report at that
  moment, from inside the sink, whichever component, thread or scope made it (the session's diagnostics writer, a boot diagnostic, the
  drain's report, the verdict's warning, a reporting boundary of the native application), and every later write or flush is refused without
  touching the sink. So any enclosing boundary that runs at any later point already sees the path as failed, the lifetime makes no final
  flush through it, and the command writes no terminal line through it; the first failure is kept as evidence beside the primary failure and
  the status is not changed by it. No snapshot of the session, finalizer or join is the source of that fact, and nothing waits for one. The
  refusal is still raised to the writer that met it (the session counts it in its own evidence), and a cancellation is never recorded as one.
  Every write and flush goes through one serialization point shared by all writers (the session's diagnostics writer, a drain, a
  terminal reporter, the finalizer): the check of the path, the sink operation and the recording of a refusal are a single step per writer,
  so a writer that queued behind a failing write finds the path failed when its turn comes and never touches the sink; the wait and the
  write stay interruptible. The capture of a refusal and its recording are one masked step (only the sink operation itself runs with the caller's interruptibility), so
  a cancellation queued while the sink was throwing cannot land before the record exists.
* **The launcher's rule for a caught failure.** Wherever a failure is caught and something is owed after it (recording, joining, releasing,
  answering a waiter, reporting), the capture and the handling are one masked step and the continuation does not resume unmasked; only the
  guarded operation runs with the caller's interruptibility restored, and a cancellation is remembered or handed on, never swallowed. Every
  such site in `run/` and in the native harness was audited against this (the list is in the pull request), and a best-effort write ignores
  a failure to write but not a cancellation.
* **Typed failures are never reduced to the first of several.** The content layer keeps a failure beside another (a descriptor that would
  not close after a read failed) in the exception's context. Wherever the launcher turns such a failure into text (the root refusal and
  the manifest read in `Boot`, the final failure line in `Run`), it does so from the failure *with its context* (`withEvidence`), so the
  bounded line names the retained cleanup failures too.

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
  native close, the assembled facade's capacity behavior, and the built command stopped by one SIGTERM, twice: with validation not
  requested (recorded as such) and with `--vulkan-validation` (recorded as requested and enabled, clean through teardown). Each waits
  for the resolved root, the validation record and the session's `start gate opened` before the one signal, and requires the session
  to have ended with `failures=0 verdict=VerdictInterrupted`.
  `bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia hetoimasia:test:run-native-tests`, then
  `bash tools/vulkan/run.sh native hetoimasia:test:run-native-tests -- --complete` (macOS: with `HETOIMASIA_NATIVE_SESSION=desktop`
  on that command).

These smoke cases establish launch and lifetime, **not visible output**: no pixel is captured or read back in them (LFE-24's matrix
is offscreen; LFE-25's `Lua native milestone` subgroup captures the windows' presented output on the isolated X11 display, see
[its evidence](evidence/lua_first_native/README.md).

The actual command's native close is covered per platform, and the split is part of the acceptance:

* **macOS, supervised** (required once, at the head the review approves, before the merge; owner amendment
  https://github.com/coghex/hetoimasia/issues/537#issuecomment-6547003833): the launch and lifetime smoke of the real command. A person
  closes its window and the exit status must be 0.

  ```sh
  HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia:exe:hetoimasia -- run samples/lua-quad/content
  ```

  It is not a catalog example and not an unattended routine test: nothing in this repository closes another process's window.
  The record, in the pull request body once the review has approved the head and before the merge, carries: the command, the platform,
  the exit status, the runner's `repository revision` and `source digest` lines (clean, with no dirty suffix) for that approved head, and the
  existing `session stopping` and `session ended` stderr diagnostics quoted from the run (`quit=true`, `failures=0`,
  `verdict=VerdictSuccess`). All of the suite's other requirements (the `run-native-tests` examples, the Linux SIGTERM/130 run, the macOS
  native suite and green CI) stand beside it.
* **Linux**: the library-composed `run-native-tests` case delivers a real in-process `WM_DELETE_WINDOW` through the existing native close
  driver (exit 0), and the built command is started on the isolated X11 display and sent exactly one SIGTERM (exit 130). The actual
  command's native close on Linux is LFE-25's: its `Lua native milestone` cases start the built command with `--vulkan-validation`, capture its
  window through the test-only helper `tools/x11-window/x11_window.py`, and deliver a genuine `WM_DELETE_WINDOW` to that exact window (exit 0).
