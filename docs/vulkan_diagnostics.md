# Vulkan validation diagnostics

Current behavior of the Vulkan backend's diagnostic capture: the header-free
`Hetoimasia.GPU.Vulkan.Diagnostics` in `packages/gpu-vulkan/diagnostics`, and the
debug-utils messengers the native backend package
`Hetoimasia.GPU.Vulkan.Native.Diagnostics` in `packages/gpu-vulkan/native`
installs. The accepted policy lives in
[the Vulkan backend design](vulkan_backend_design.md) — D-19, D-20, D-21, D-28,
P-11 and the VK-6 slice — and in
[runtime review finding RR-5](runtime_review_findings.md); this document says
what the code does today.

A Vulkan layer or driver reports from inside Vulkan calls, on whatever thread it
is running, and under D-28 some of those calls will be audited `unsafe` imports
that must not re-enter Haskell. So the callback is C, it only copies, and a
Haskell worker delivers what it copied afterwards, outside the callback and
outside the graphics critical path. Latched error and loss state lives in the
C storage, so it is observable with the worker slow, blocked or gone.

## The two packages

| Package | Project files | Depends on | Owns |
| --- | --- | --- | --- |
| `hetoimasia-gpu-vulkan-diagnostics` | `cabal.project`, `cabal.project.cpu`, `cabal.project.vulkan` | `hetoimasia-foundation` only | The C capture storage and producer, the diagnostic lifetime, its drain worker and verdict |
| `hetoimasia-gpu-vulkan-native` | `cabal.project.vulkan` only | the Vulkan binding, the diagnostics package, `hetoimasia-gpu-vulkan-model`, the foundation | The messenger callback, the messengers, and the package's FFI configuration record |

The diagnostics package includes no Vulkan header and depends on no binding or
loader, so `cabal build all` with either ordinary project builds it with no
Vulkan SDK present, and its suite is the CPU validation group
`test.vulkan-diagnostics`. The native package is built only by
`tools/vulkan-proof/run-proof.sh`, which is what points Cabal at the provisioned
loader and headers; see [the proof harness](../tools/vulkan-proof/README.md).
`tools/test/VulkanProof.hs` holds that boundary: neither ordinary project names
the native package, no package they name depends on the binding, and the Vulkan
project names exactly the proof, the native package, and the native package's
local closure.

## The producer

`hetoimasia_capture_callback` in
`packages/gpu-vulkan/diagnostics/capture/cbits/hetoimasia_vulkan_capture.c` is
the producer, and the native package's `hetoimasia_vulkan_capture_messenger` is
the `PFN_vkDebugUtilsMessengerCallbackEXT` every capture messenger registers: a
C function with Vulkan's exact type that passes its arguments straight to it.
Nothing on that path is Haskell. For each report it:

1. ignores it if the user data is not a live storage, since there is nowhere to
   record anything;
2. counts it as offered;
3. **latches the error state if the severity has the error bit**, and counts
   the error — before anything below can drop or refuse the report;
4. refuses it as a capture failure, latching capture failure, if admission has
   closed or the callback data is NULL;
5. claims a queue position with one compare-and-swap, or counts the report as
   dropped and returns if the queue is full;
6. copies the record under its bounds, counts it as truncated if anything did
   not fit, publishes it, and counts it as admitted;
7. returns 0, `VK_FALSE`, the non-aborting answer the API asks for.

It never allocates, waits for space, takes a lock, performs I/O, calls Vulkan or
raises. The queue is a bounded multi-producer, single-consumer ring after
Vyukov's bounded queue, with a sequence encoding that also works for a queue of
one; a producer that loses a race retries only against the position that beat
it.

The diagnostics package knows the callback data only through a layout mirror of
`VkDebugUtilsMessengerCallbackDataEXT` and `VkDebugUtilsObjectNameInfoEXT` in
its header. `packages/gpu-vulkan/native/cbits/hetoimasia_vulkan_native.c` is the
one translation unit that sees both that header and the Vulkan headers, and it
asserts at compile time that every mirrored field has the same offset and size,
that both structures have the same size, and that the severity bits agree. A
header whose layout differed would fail the native build rather than be read
through the wrong offsets. The capture's C is compiled with
`-fno-strict-aliasing` because it reads Vulkan's structures through that mirror.

### What one record holds

| Field | Bound |
| --- | --- |
| Severity bits and message-type bits | copied |
| Message id number | copied |
| Message id name, message text, object names | copied in that order under **one shared text budget per record**, 4 KiB by default; each string is copied byte by byte up to what the budget has left, never measured or decoded whole first |
| Object type and handle | at most the object limit, 16 by default; the count the callback carried is kept beside them |

A record whose text ran out, whose objects exceeded the limit, or whose callback
data claimed objects and passed no array, is admitted cut and counted as
truncated. Labels are not captured.

### Limits

`CaptureConfig` carries the queue capacity (1,024 records by default), the text
budget (4,096 bytes), the object limit (16), and the worker's poll interval
(2,000 microseconds). `validateCaptureConfig` checks them without performing IO
and `withDiagnosticCapture` runs it first, so a rejected configuration raises
`CaptureConfigError` before anything is allocated:

- every limit must be at least 1 and at most what the storage counts in, an
  unsigned 32-bit value — an `Int` is finite, so this is the whole of "positive
  and finite";
- the bytes the storage would allocate — capacity times the fixed record size,
  the text budget, and the object records — are computed exactly and must fit in
  both a C `size_t` and an `Int` (`AllocationUnrepresentable` otherwise); the C
  constructor repeats that check with overflow-checked multiplication;
- the poll interval must be positive;
- the process must run the threaded runtime.

The default budget does not fit everything a driver routinely says. On macOS,
MoltenVK's info report of its supported extensions during `vkCreateInstance`
runs past 4 KiB, so a session at the default budget with info reports enabled
records one truncation and a verdict that is not clean; Lavapipe's reports all
fit. VK-6's native proof session runs with a 16 KiB budget for that reason. The
default is unchanged: what it should be, or whether routine commentary should
count against a clean verdict, is VK-7's and VK-8's to settle.

## Latches and counters

| State | Set by | Cleared by |
| --- | --- | --- |
| Error latch | any error-severity report, before its admission is attempted | nothing |
| Capture-failure latch | a report refused as a capture failure | nothing |
| Offered, admitted, dropped, truncated, capture failures, errors | the producer, each saturating at `maxBound` | nothing |

Every report the producer records is exactly one of admitted, dropped, or
refused as a capture failure, so offered is their sum until a counter
saturates. `captureStatus` reads all of them from the C storage at any time,
from any thread, with no worker involved; after the lifetime has released the
storage it answers the snapshot taken just before. No delivery, flush or later
report clears any of them, and the logger's filter never sees them: an error
the logger filters out entirely is still latched.

## The diagnostic lifetime

```haskell
withDiagnosticCapture
  ∷ CaptureConfig → Logger → (DiagnosticCapture → IO a) → IO (a, DiagnosticVerdict)
captureUserData ∷ DiagnosticCapture → Ptr ()
captureCallback ∷ FunPtr CaptureCallback
requestDrain    ∷ DiagnosticCapture → IO ()
retainStorage   ∷ DiagnosticCapture → IO ()
capturePhase    ∷ DiagnosticCapture → STM CapturePhase
captureStatus   ∷ DiagnosticCapture → IO CaptureStatus
deliveredCount  ∷ DiagnosticCapture → STM Word64
```

The lifetime is established before any messenger exists: it allocates the
storage, starts the drain worker in a `withWorkerGroup` of its own, and runs the
body. The body enables messengers with `captureUserData`, does every Vulkan
operation that could report, and must have finished the last callback-producing
destruction — `vkDestroyInstance`, where the create-info messenger reports after
the explicit messenger is gone — before it returns or throws. On every exit the
lifetime then:

1. closes admission and waits for any producer still inside the callback — the
   wait is bounded by a producer's own copy, and is the reason closing is a
   `safe` call;
2. asks the worker for its final drain and waits for its completion explicitly,
   never relying on the worker group's default drain;
3. counts every record still queued as undelivered;
4. snapshots the latches and counters and frees the storage — unless the body
   called `retainStorage` because a native object that registered the callback
   may outlive it, in which case the storage is left for process exit and the
   verdict says so;
5. returns the body's result with the verdict, or rethrows the body's failure
   with its own type, value and context and the verdict attached to it.

| Phase | Meaning |
| --- | --- |
| `PhaseCapturing` | The body runs; producers report, and the worker drains when woken or polled. |
| `PhaseClosed` | Admission is closed, every producer has left, and the final drain was requested. The storage and the logger are still borrowed. |
| `PhaseJoined` | The worker is terminal and its outcome has been read. |
| `PhaseReleased` | The storage is freed, or deliberately retained. |

Draining may run while producers are still active: a record produced while an
earlier one is being delivered is delivered after it. Final closure and release
wait for producer quiescence, which the body establishes by finishing its last
callback-producing destruction; a report that arrives after admission closed —
a body that broke that contract — is refused as a capture failure while the
storage is still there to count it, and makes the verdict not clean.

A cancellation delivered while the lifetime waits for the worker does not end
the wait. The first one is kept, the worker is asked to cancel, and the wait
continues; the storage is released only after the worker is terminal, and then
the cancellation is rethrown with the verdict attached. A sink that blocks
forever and cannot be interrupted keeps the lifetime in `PhaseClosed` with the
storage and the logger borrowed: there is no deadline and no detach, and the
process's external termination is the escape.

### The drain worker

The worker belongs to the lifetime's own worker group, not the application's,
and performs no GPU retirement. It takes records from the storage — it is the
storage's only consumer until it is terminal — and hands each to the caller's
logger through `logEvent`, from a logger derived with the breadcrumb
`vulkan-diagnostics`:

| Record severity | Level |
| --- | --- |
| error | `Error` |
| warning | `Warning` |
| info, verbose | `Debug` — the loader's and the layers' running commentary is detail for someone investigating this component, not lifecycle `Info` |
| no known bit | `Warning` |

Every record has the component `gpu.vulkan.diagnostics`, the constant message
`Vulkan diagnostic`, and its variable parts in fields:

| Field | Value |
| --- | --- |
| `severity` | `error`, `warning`, `info`, `verbose`, or the bits in hex |
| `types` | `general`, `validation`, `performance`, `device-address-binding`, comma-separated |
| `message.id`, `message.number` | the message id name when present, and its number |
| `text` | the message |
| `objects` | how many objects the callback carried, when any |
| `object.<n>`, `object.<n>.name` | each copied object's `type:0xhandle`, and its name when present |
| `truncated` | `true` when the record was cut |

A synchronous failure writing a record is the sink's. Delivery stops; the
worker keeps taking records and counts them as undelivered, so the accounting
stays complete; and the failure is kept only in the worker's report. It is never
logged, because the sink that would carry it is the one that failed. Anything
asynchronous ends the worker as a cancellation. The worker never flushes or
closes the borrowed logger, and it finishes inside the lifetime, which must
itself run inside the application's [logging lifetime](logging.md#logging-lifetime).

## The verdict

`DiagnosticVerdict` carries the status after admission closed, the records
delivered and undelivered, the worker's `ConsumerOutcome` — completed, sink
failed, failed or cancelled — and whether the storage was retained.
`verdictIssues` lists every reason it is not clean, in a fixed order:

| Issue | When |
| --- | --- |
| `ErrorLatched` | an error-severity report arrived |
| `CaptureFailureLatched` | a report could not be captured at all |
| `RecordsDropped n` | the queue was full `n` times |
| `RecordsTruncated n` | `n` admitted records were cut |
| `CaptureFailures n` | `n` reports were refused |
| `RecordsUndelivered n` | `n` admitted records never reached the logger |
| `RecordsUnaccounted admitted accounted` | admitted differs from delivered plus undelivered |
| `CounterSaturated` | a counter reached its ceiling, so no count can be trusted |
| `ConsumerUnsuccessful` | the sink failed, or the worker failed or was cancelled |
| `StorageRetained` | a registering native object may still report into the storage |

`verdictClean` holds only when the list is empty. Warnings are not issues: they
are diagnostics. So a verdict is clean only when no error arrived, nothing was
lost, cut or refused, every admitted record was delivered, and the worker
completed — draining everything admitted is not enough on its own. A failed
body's verdict is read with `diagnosticVerdict` from the exception it rethrows;
a sink failure never replaces that failure and never authorizes an early
release.

Stopping graphics admission when the error latch is set is the owner's, at its
checkpoints (VK-7, VK-15): this package exposes the latch and does nothing
about it.

## Messengers on real objects

`Hetoimasia.GPU.Vulkan.Native.Diagnostics` builds both messengers an instance
can have from one capture:

- `captureMessengerCreateInfo` goes in the `VkInstanceCreateInfo` chain. It is
  the only messenger that hears `vkCreateInstance` and `vkDestroyInstance`, and
  the extension uses it for nothing else.
- `createCaptureMessenger`, or `withCaptureMessenger` in scope form, is the
  explicit messenger. It must be created before the instance's first child and
  destroyed after its last, immediately before the instance, so a device's own
  destruction reports somewhere.

Both register `captureMessengerCallback`, whose code is linked into the
executable and so lives as long as the process, with the capture's storage as
user data, which the lifetime keeps until the body has returned. The package
installs no Haskell callback, no allocation callback and no trampoline.

`nativeFfiConfiguration` records how the package calls Vulkan and what can call
back: the binding at `vulkan-3.27` with `safe-foreign-calls` on and
`darwin-lib-dirs` off, as `cabal.project.vulkan` constrains it and
`tools/toolchain/binding.pin` records; the C-only capture callback; no Haskell
callbacks; and no `unsafe` imports of its own yet — the audited recording subset
is VK-11's. The proof record prints it beside the build's source digest, and the
proof checks the binding flags against the pin.

## State

| State | Owner | Writers | Readers | Thread | Lifetime and reset |
| --- | --- | --- | --- | --- | --- |
| C storage: queue, latches, counters | the lifetime | producers on any thread; the worker, consuming | the worker; the lifetime after it; `captureStatus` | any | allocated at entry, freed in step 4 unless retained; never reset |
| Phase | the lifetime | the lifetime's thread | any thread | any | per lifetime; only advances |
| Delivered count | the worker | the worker | any thread | the worker's | per lifetime; only grows |
| Wake and final requests | the lifetime | `requestDrain`; the lifetime, once, for final | the worker | any | per lifetime |
| Status snapshot | the lifetime | step 4, once | `captureStatus` after release | the lifetime's | taken before any release |

## Testing

`diagnostics-tests`, the `Vulkan diagnostics` group, is registered as the
non-optional CPU group `test.vulkan-diagnostics`, which runs through
`cabal.project.cpu`, is selected when affected or requested, and is not in the
floor:

```
cabal test --project-file cabal.project.cpu hetoimasia-gpu-vulkan-diagnostics:diagnostics-tests --test-show-details=direct
```

Its examples offer records through `hetoimasia_capture_offer`, a package-local
producer entry that builds the callback data on a C frame and calls the
production producer with it — the storage they exercise is the production C, not
a Haskell stand-in. `Capture` drives the storage directly: bounded copying at
each limit and one byte past it, the shared budget, saturation and the drop
counter with the error latch surviving it, error latching ahead of admission,
truncation counting, contained producer failures, counters saturating at their
ceilings, and eight threads racing for positions while a consumer drains.
`Lifetime` drives the whole lifetime with injected sinks: delivery and its
fields, the worker's own group, the verdict's issues, sink failure beside a
preserved primary failure, a record produced while draining, the final drain,
a blocked sink holding the storage, cancellation during finalization and of the
body, and retention. Waits are explicit: a gated sink says when it is entered,
the delivered count says what the worker has done, and the poll is replaced by
one no example reaches.

The native cases run through the VK-2 proof route until VK-8 moves them into
the package-native fixture; see
[the proof harness](../tools/vulkan-proof/README.md#vk-6-validation-capture) for
what they show and where their records are retained.
