# Vulkan validation diagnostics

The contract of the Vulkan backend's diagnostic capture: the header-free
`Hetoimasia.GPU.Vulkan.Diagnostics` in `packages/gpu-vulkan/diagnostics`, and
the debug-utils messengers `Hetoimasia.GPU.Vulkan.Native.Diagnostics` installs.

A Vulkan layer or driver reports from inside Vulkan calls, on whatever thread
it is running, and some of those calls are audited `unsafe` imports that must
not re-enter Haskell. So the callback is C and only copies, and a Haskell
worker delivers what it copied afterwards, outside the graphics critical path.
Latched error and loss state lives in the C storage, so it is observable with
the worker slow, blocked or gone.

## The two packages

| Package | Built by | Owns |
| --- | --- | --- |
| `hetoimasia-gpu-vulkan-diagnostics` | every project, with no Vulkan SDK; depends on the foundation only | The C capture storage and producer, the diagnostic lifetime, its drain worker and verdict |
| `hetoimasia-gpu-vulkan-native` | `cabal.project.vulkan` only, through `tools/vulkan/run.sh` | The messenger callback, the messengers, and the FFI configuration record |

`tools/test/VulkanProof.hs` holds that boundary.

## The producer

`hetoimasia_capture_callback` is the producer, and the native package's
`hetoimasia_vulkan_capture_messenger` is the callback every capture messenger
registers. Nothing on that path is Haskell. For each report it:

1. announces itself in the storage's slot, its first memory operation, and
   ignores the report if the user data names no current slot;
2. counts it as offered;
3. **latches the error state if the severity has the error bit**, before
   anything below can drop or refuse the report;
4. refuses it as a capture failure if admission has closed or the callback
   data is NULL;
5. claims a queue position with one compare-and-swap, or counts the report as
   dropped if the queue is full;
6. copies the record under its bounds, counts it as truncated if anything did
   not fit, and publishes it;
7. returns `VK_FALSE`.

It never allocates, waits, locks, performs I/O, calls Vulkan or raises. The
queue is a bounded multi-producer, single-consumer ring.

The diagnostics package knows the callback data only through a layout mirror
of the three debug-utils structures. The native package's one translation unit
that sees both headers asserts at compile time that every mirrored field has
the same offset and size, so a differing header fails the build. The capture's
C is compiled with `-fno-strict-aliasing` for that reason.

**One record** holds the severity and type bits, the message id, and, under
one shared text budget per record, the id name, message text, object names and
label names. It keeps at most the object limit of object types and handles and
at most the label limit of queue and command-buffer labels each, with the
counts the callback carried. A record that had to be cut is admitted and
counted as truncated once.

**Limits.** `CaptureConfig` defaults: queue capacity 1,024 records, text
budget 4,096 bytes, 16 objects, 4 labels of each kind, poll interval 2,000
microseconds. `validateCaptureConfig` runs before anything is allocated: every
limit at least 1 and within 32 bits, the total allocation representable, a
positive poll interval, and the threaded runtime.

On macOS, MoltenVK's info report of its supported extensions exceeds 4 KiB, so
a session at the default budget with info reports enabled records one
truncation and a verdict that is not clean. The native proof sessions use a
16 KiB budget for that reason.

## Latches and counters

| State | Set by | Cleared by |
| --- | --- | --- |
| Error latch | any error-severity report, before its admission is attempted | nothing |
| Capture-failure latch | a report refused as a capture failure | nothing |
| Offered, admitted, dropped, truncated, capture failures, errors | the producer, each saturating | nothing |

Every report is exactly one of admitted, dropped or refused. `captureStatus`
reads all of this from the C storage at any time, from any thread, with no
worker involved, before, during and after release. The logger's filter never
sees the latches: a filtered-out error is still latched.

## The diagnostic lifetime

`withDiagnosticCapture config logger body` is established before any messenger
exists: it allocates the storage, starts the drain worker in a worker group of
its own, and runs the body. The body enables messengers with
`captureUserData`, does every Vulkan operation that could report, and finishes
the last callback-producing destruction through `afterLastCallback`, which
returns the `Quiesced` evidence the body hands back with its result. On every
exit the lifetime:

1. closes admission and waits for every producer that has announced itself;
2. asks the worker for its final drain and waits for its completion;
3. counts as undelivered every admitted record the worker did not deliver;
4. reads the latches and counters for the verdict and frees the storage,
   unless the body called `retainStorage` because a native object that
   registered the callback may outlive it;
5. returns the body's result with the verdict, or rethrows the body's failure
   with the verdict attached.

| Phase | Meaning |
| --- | --- |
| `PhaseCapturing` | The body runs; producers report; the worker drains |
| `PhaseClosed` | Admission is closed, every producer has left, the final drain was requested |
| `PhaseJoined` | The worker is terminal and its outcome has been read |
| `PhaseReleased` | The storage is freed, or deliberately retained |

### Quiescence is the owner's evidence

Vulkan invokes a messenger's callback only from inside a Vulkan call, so once
the last call that could invoke it (`vkDestroyInstance`) has returned, none
can be running. The capture cannot establish that on its own, so the lifetime
demands it by type. `afterLastCallback capture destruction` runs the
destruction and, once it returns normally, records quiescence and returns an
opaque `Quiesced`. The native package's `destroyInstanceQuiesced` is
`vkDestroyInstance` through it. A verdict without that evidence reports
`QuiescenceUnproven` and is not clean. A destruction that throws establishes
nothing.

A capture is two kinds of memory. The **storage** (queue, records, text) is on
the C heap and is freed in step 4. Its **slot** (announcement count, closed
flag, generation, latches, counters) is one entry of a fixed static table of
64 and is never freed; a messenger's user data encodes the slot index and
generation, not a pointer. A report that arrives after release therefore
touches only static memory and counts itself as a capture failure in the slot.
A sixty-fifth concurrent lifetime is refused with `StorageSlotsExhausted`.

**Finalization and cancellation.** A cancellation delivered while the lifetime
waits for the worker does not end the wait; the storage is released only after
the worker is terminal.

| Body | Finalization observed | Rethrown |
| --- | --- | --- |
| failed or cancelled | anything | the body's failure with the verdict; a finalization cancellation and group-closing failure are kept beside it as `FinalizationEvidence` |
| returned | a cancellation while waiting for the worker | that cancellation, with the verdict |
| returned | a failure while the worker group closed | that failure, with the verdict |
| returned | neither | nothing: the result and the verdict are returned |

A sink that blocks forever keeps the lifetime in `PhaseClosed`: there is no
deadline and no detach.

### The drain worker

The worker is the storage's only consumer. It hands each record to the
caller's logger under the breadcrumb `vulkan-diagnostics`, component
`gpu.vulkan.diagnostics`, constant message `Vulkan diagnostic`:

| Record severity | Level |
| --- | --- |
| error | `Error` |
| warning, or no known bit | `Warning` |
| info, verbose | `Debug` |

Fields are `severity`, `types`, `message.id`, `message.number`, `text`,
`objects`, `object.<n>`, `object.<n>.name` and `truncated`. A record's labels
are its scoped context (`queue.labels`, `cmdbuf.labels`, `queue.label.<n>`,
`cmdbuf.label.<n>`), on a logger derived for that record alone. The pinned
validation layers were seen to list a batch's still-open label region twice.

Delivering a record and counting it delivered are one masked step. A
synchronous sink failure stops delivery: the worker keeps taking records and
counts them undelivered, and the failure is kept only in the worker's report,
never logged through the sink that failed. The worker never flushes or closes
the borrowed logger, and the lifetime must run inside the application's
[logging lifetime](logging.md#logging-lifetime).

## The verdict

`DiagnosticVerdict` carries the status after admission closed, the delivered
and undelivered counts, the worker's outcome and whether the storage was
retained. `verdictIssues` lists every reason it is not clean:

| Issue | When |
| --- | --- |
| `ErrorLatched` | an error-severity report arrived |
| `CaptureFailureLatched` | a report could not be captured |
| `RecordsDropped n` | the queue was full `n` times |
| `RecordsTruncated n` | `n` admitted records were cut |
| `CaptureFailures n` | `n` reports were refused |
| `RecordsUndelivered n` | `n` admitted records never reached the logger |
| `RecordsUnaccounted` | admitted differs from delivered plus undelivered |
| `CounterSaturated` | a counter reached its ceiling |
| `ConsumerUnsuccessful` | the sink failed, or the worker failed or was cancelled |
| `QuiescenceUnproven` | the owner never supplied `Quiesced` evidence |
| `StorageRetained` | a registering native object may still report |

Warnings are not issues. A failed body's verdict is read with
`diagnosticVerdict` from the exception, and `finalizationEvidence` reads what
finalization observed beside it. A sink failure never replaces the body's
failure and never authorizes an early release.

**Acting on the latch is the owner's.** This package exposes the latch and
does nothing about it; the backend's controller installs it as the roots'
diagnostic watch, so an error-severity report becomes the session's primary
failure at the owner's next checkpoint
([gpu_backend.md](gpu_backend.md#terminal-failure)).

**Which failure came first.** The storage keeps one first-failure cell per
lifetime, claimed by compare-and-swap: by the C callback for an error before
it sets the latch, by the worker for a sink failure, or by the owner for a
failure of its own (`claimCaptureOrder`, answering `OwnerFailedFirst`,
`ErrorLatchedFirst` or `SinkFailedFirst`). `captureAlarms` answers the alarms
in the order they happened, or `CaptureAlarmPending` while the first claimant
has not yet set its own alarm, so it never answers a later failure first.
`captureSinkFailure` reads the sink failure from the moment the worker met it.

## Messengers on real objects

- `captureMessengerCreateInfo` goes in the `VkInstanceCreateInfo` chain. It is
  the only messenger that hears `vkCreateInstance` and `vkDestroyInstance`.
- `createCaptureMessenger` (or `withCaptureMessenger`) is the explicit
  messenger. It must be created before the instance's first child and
  destroyed after its last, immediately before the instance.
- `destroyInstanceQuiesced` destroys the instance through
  `afterLastCallback`.

The package installs no Haskell callback, allocation callback or trampoline.
The backend never names its debug messenger: doing so crashes the pinned macOS
loader and MoltenVK. `nativeFfiConfiguration` records how the package calls
Vulkan (the pinned binding with `safe-foreign-calls` on, the C-only capture
callback, and the audited `unsafe` recording subset listed in
[the FFI audit](gpu_backend.md#the-ffi-audit)).

## State

| State | Owner | Writers and readers | Lifetime |
| --- | --- | --- | --- |
| C storage: queue, objects, labels, text | the lifetime | producers on any thread; the worker consumes | allocated at entry, freed at release unless retained |
| C slot: announcements, close flag, generation, latches, first-failure cell, counters | the lifetime, then the slot's next claimant | producers, the worker (once, for its sink), the lifetime; `captureStatus` reads | static; reset only when claimed again |
| Phase, wake and final requests | the lifetime | the lifetime writes; any thread reads | per lifetime; the phase only advances |
| Taken and delivered counts, sink failure | the worker | the worker writes; any thread reads | per lifetime; never cleared |

## Testing

```bash
cabal test --project-file cabal.project.cpu hetoimasia-gpu-vulkan-diagnostics:diagnostics-tests --test-show-details=direct
```

This is the CPU group `test.vulkan-diagnostics`. The messengers on real
objects are exercised by the Vulkan native suites
([gpu_backend.md](gpu_backend.md#the-native-suite)).
