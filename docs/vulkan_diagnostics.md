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
`tools/vulkan/run.sh`, which is what points Cabal at the provisioned loader and
headers; its groups are `test.vulkan-headless` and `test.vulkan-native`.
`tools/test/VulkanProof.hs` holds that boundary: neither ordinary project names
the native package, no package they name depends on the binding, and the Vulkan
project names exactly the native package, the window integration package, and
their local closure.

## The producer

`hetoimasia_capture_callback` in
`packages/gpu-vulkan/diagnostics/capture/cbits/hetoimasia_vulkan_capture.c` is
the producer, and the native package's `hetoimasia_vulkan_capture_messenger` is
the `PFN_vkDebugUtilsMessengerCallbackEXT` every capture messenger registers: a
C function with Vulkan's exact type that passes its arguments straight to it.
Nothing on that path is Haskell. For each report it:

1. announces itself in the storage's slot — its first memory operation — and
   ignores the report if the user data names no slot or a slot now serving
   another storage, since there is nowhere to record it;
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

It never allocates — on the Haskell heap or the C heap: every record, object and
label it can fill was allocated with the storage — and never waits for space,
takes a lock, performs I/O, calls Vulkan or raises. The queue is a bounded multi-producer, single-consumer ring after
Vyukov's bounded queue, with a sequence encoding that also works for a queue of
one; a producer that loses a race retries only against the position that beat
it.

The diagnostics package knows the callback data only through a layout mirror of
`VkDebugUtilsMessengerCallbackDataEXT`, `VkDebugUtilsObjectNameInfoEXT` and
`VkDebugUtilsLabelEXT` in its header. `packages/gpu-vulkan/native/cbits/hetoimasia_vulkan_native.c` is the
one translation unit that sees both that header and the Vulkan headers, and it
asserts at compile time that every mirrored field has the same offset and size,
that all three structures have the same size — so both array strides agree too —
and that the severity bits agree. A
header whose layout differed would fail the native build rather than be read
through the wrong offsets. The capture's C is compiled with
`-fno-strict-aliasing` because it reads Vulkan's structures through that mirror.

### What one record holds

| Field | Bound |
| --- | --- |
| Severity bits and message-type bits | copied |
| Message id number | copied |
| Message id name, message text, object names, queue label names, command-buffer label names | copied in that order under **one shared text budget per record**, 4 KiB by default; each string is copied byte by byte up to what the budget has left, never measured or decoded whole first |
| Object type and handle | at most the object limit, 16 by default; the count the callback carried is kept beside them |
| Queue labels, command-buffer labels | two separate fields, each at most the label limit, 4 by default, in the callback's order; each keeps the count the callback carried beside the ones copied, and a label whose name was NULL is kept without one |

A record whose text ran out, whose objects or labels exceeded their limits, or
whose callback data claimed objects or labels and passed no array, is admitted
cut and counted as truncated — once per record, however many of those applied.
A label's colour is not copied.

### Limits

`CaptureConfig` carries the queue capacity (1,024 records by default), the text
budget (4,096 bytes), the object limit (16), the label limit (4 of each kind),
and the worker's poll interval (2,000 microseconds). `validateCaptureConfig` checks them without performing IO
and `withDiagnosticCapture` runs it first, so a rejected configuration raises
`CaptureConfigError` before anything is allocated:

- every limit must be at least 1 and at most what the storage counts in, an
  unsigned 32-bit value — an `Int` is finite, so this is the whole of "positive
  and finite";
- the bytes the storage would allocate — capacity times the fixed record size,
  the text budget, the object records, and two arrays of label records — are
  computed exactly and must fit in both a C `size_t` and an `Int`
  (`AllocationUnrepresentable` otherwise); the C constructor repeats that check
  with overflow-checked multiplication, label records included;
- the poll interval must be positive;
- the process must run the threaded runtime.

The default budget does not fit everything a driver routinely says. On macOS,
MoltenVK's info report of its supported extensions during `vkCreateInstance`
runs past 4 KiB, so a session at the default budget with info reports enabled
records one truncation and a verdict that is not clean; Lavapipe's reports all
fit. VK-6's native proof session runs with a 16 KiB budget for that reason, and
so does VK-7's. The default is unchanged. VK-7's production composition
([gpu_backend.md](gpu_backend.md)) takes its capture configuration from its
caller rather than settling it; what the default should be, or whether routine
commentary should count against a clean verdict, rests with VK-8.

## Latches and counters

| State | Set by | Cleared by |
| --- | --- | --- |
| Error latch | any error-severity report, before its admission is attempted | nothing |
| Capture-failure latch | a report refused as a capture failure | nothing |
| Offered, admitted, dropped, truncated, capture failures, errors | the producer, each saturating at `maxBound` | nothing |

Every report the producer records is exactly one of admitted, dropped, or
refused as a capture failure, so offered is their sum until a counter
saturates. `captureStatus` reads all of them from the C storage at any time,
from any thread, with no worker involved, before, during and after the
release: they live in the storage's static slot, which is never freed, and
once the slot serves another lifetime the query answers the snapshot taken just
before the storage was freed. No delivery, flush or later
report clears any of them, and the logger's filter never sees them: an error
the logger filters out entirely is still latched.

## The diagnostic lifetime

```haskell
withDiagnosticCapture
  ∷ CaptureConfig → Logger → (DiagnosticCapture → IO (a, Quiesced)) → IO (a, DiagnosticVerdict)
afterLastCallback ∷ DiagnosticCapture → IO () → IO Quiesced
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
operation that could report, and finishes the last callback-producing
destruction — `vkDestroyInstance`, where the create-info messenger reports after
the explicit messenger is gone — through `afterLastCallback`, which returns the
`Quiesced` evidence the body must hand back with its result. On every exit the
lifetime then:

1. closes admission and waits for every producer that has announced itself
   inside the callback — the wait is bounded by a producer's own copy, and is
   the reason closing is a `safe` call;
2. asks the worker for its final drain and waits for its completion explicitly,
   never relying on the worker group's default drain;
3. counts as undelivered every admitted record the worker did not deliver: the
   ones it discarded after a sink failure, one it had taken and was delivering
   when it was cancelled — the worker counts a record as taken in the same
   masked step that takes it — and every one still queued;
4. reads the latches and counters for the verdict, keeps them as the status
   snapshot, and frees the storage — unless the body called `retainStorage`
   because a native object that registered the callback may outlive it, in
   which case it is left for process exit and the verdict says so;
5. returns the body's result with the verdict, or rethrows the body's failure
   with its own type, value and context and the verdict attached to it. A body
   failure — a body cancellation included — stays primary whatever
   finalization observes: a cancellation delivered while the lifetime waits
   for the worker, or a failure raised while its worker group closes, is kept
   beside it as `FinalizationEvidence` rather than rethrown in its place.

| Phase | Meaning |
| --- | --- |
| `PhaseCapturing` | The body runs; producers report, and the worker drains when woken or polled. |
| `PhaseClosed` | Admission is closed, every producer has left, and the final drain was requested. The storage and the logger are still borrowed. |
| `PhaseJoined` | The worker is terminal and its outcome has been read. |
| `PhaseReleased` | The storage is freed, or deliberately retained. |

### Quiescence is the owner's evidence

Vulkan invokes a messenger's callback only from inside a Vulkan call. So once
the last call that could invoke it — `vkDestroyInstance` — has returned, no
invocation can be running or begin, and that return is what quiescence is. The
capture cannot establish it on its own: an invocation that has entered the
callback but not yet executed its first memory operation has touched nothing
any barrier could see, and a barrier only moves that window to its own first
instruction. Quiescence is therefore evidence the owner of the last
callback-producing destruction supplies, and the lifetime demands it by type.

`afterLastCallback capture destruction` runs the destruction and, once it has
returned normally, records that the capture is quiescent and returns an opaque
`Quiesced` naming this capture; it is the only way to make one. The native
package's `destroyInstanceQuiesced` is `vkDestroyInstance` through it. The body
returns the token with its result, and the record covers a destruction made
while a failure unwinds, when there is no result to return it with. A verdict
without that evidence — no record, and no returned token that names this
capture — reports `QuiescenceUnproven` and is not clean, because a callback may
still have been on its way when admission closed. A destruction that throws
establishes nothing.

A capture is two kinds of memory. The **storage** — the queue, its object
records and its text — is on the C heap, is the lifetime's, and is freed whole
in step 4. Its **slot** — the announcement count, the closed flag, a
generation, the latches and the counters — is one entry of a fixed static table
of 64, so it is never freed. The user data a messenger carries encodes the
slot's index and the storage's generation rather than pointing at anything.

Announcing is the first thing the producer does, so every report that has
begun is one closing waits for, and the verdict includes it: a report that
announced itself before admission closed and was still copying when the body
returned is admitted or refused before the verdict is read. The only report
closing cannot see is one that has not begun at all — a Vulkan call still
running after the body returned, which the lifetime's contract rules out.
Because what such a report touches first is static, it is still memory-safe:
it finds admission closed and counts itself as a capture failure in the slot,
outside the verdict, where `captureStatus` shows it. A slot is claimed again
only after its generation has moved on and every producer announced against it
has left, so a straggler never counts against a later lifetime; its stale user
data names nothing. Sixty-four storages may be live at once in one process, and
a lifetime asking for a sixty-fifth is refused with `StorageSlotsExhausted`.

Draining may run while producers are still active: a record produced while an
earlier one is being delivered is delivered after it. Final closure and release
wait for producer quiescence, which the body establishes by finishing its last
callback-producing destruction; a report that arrives after admission closed —
a body that broke that contract — is refused as a capture failure while the
storage is still there to count it, and makes the verdict not clean.

A cancellation delivered while the lifetime waits for the worker does not end
the wait. The first one is kept — later ones are not — the worker is asked to
cancel, and the wait continues; the storage is released only after the worker
is terminal. What is rethrown then follows one precedence:

| Body | Finalization observed | Rethrown | Kept beside it |
| --- | --- | --- | --- |
| failed, or cancelled | anything | the body's failure, with its own type, value and context, and the verdict | the finalization cancellation and the group-closing failure, as `FinalizationEvidence` |
| returned | a cancellation while waiting for the worker | that cancellation, with the verdict | nothing |
| returned | a failure while its worker group closed | that failure, with the verdict | nothing |
| returned | neither | nothing: the result and the verdict are returned | — |

A cancellation after a body that returned is never turned into a successful
return. A sink that blocks forever and cannot be interrupted keeps the lifetime
in `PhaseClosed` with the storage and the logger borrowed: there is no deadline
and no detach, and the process's external termination is the escape.

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

A record's labels are its **scoped context**: the worker delivers each record
through a logger derived for that record alone (`withFields`), carrying

| Context field | Value |
| --- | --- |
| `queue.labels`, `cmdbuf.labels` | how many queue and command-buffer labels the callback carried, when any |
| `queue.label.<n>`, `cmdbuf.label.<n>` | each copied label's name, numbered from 1 in the callback's order; a label with no name has no field |

so a record's labels never reach another record's entry. The order, and which
regions are listed, are the reporting layer's own: the pinned layers were seen
to list a batch's still-open region twice, and Linux's to list a pass region
that had already closed as well
([macOS](vulkan/macos-vkr2.md), [Linux](vulkan/linux-vkr2.md)). The native
package's recorder
opens a label around every batch and every rendering pass
([gpu_backend.md](gpu_backend.md#names-and-labels)); nothing opens queue labels
yet.

Delivering a record and counting it delivered are one masked step: the sink's
own blocking stays interruptible, so a cancellation still reaches a stuck sink,
but none can land between a write that completed and its count, and the
verdict's delivered count is exactly what the sink received.

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
| `QuiescenceUnproven` | the owner never supplied `Quiesced` evidence for this capture |
| `StorageRetained` | a registering native object may still report into the storage |

`verdictClean` holds only when the list is empty. Warnings are not issues: they
are diagnostics. So a verdict is clean only when no error arrived, nothing was
lost, cut or refused, every admitted record was delivered, and the worker
completed — draining everything admitted is not enough on its own. A failed
body's verdict is read with `diagnosticVerdict` from the exception it rethrows;
a sink failure never replaces that failure and never authorizes an early
release, and neither does a cancellation or a worker-group closing failure
during finalization.

```haskell
diagnosticVerdict             ∷ SomeException → Maybe DiagnosticVerdict
diagnosticVerdictInContext    ∷ ExceptionContext → Maybe DiagnosticVerdict
finalizationEvidence          ∷ SomeException → Maybe FinalizationEvidence
finalizationEvidenceInContext ∷ ExceptionContext → Maybe FinalizationEvidence

data FinalizationEvidence = FinalizationEvidence
  { evidenceCancellation ∷ Maybe (ExceptionWithContext SomeException)
  , evidenceGroupFailure ∷ Maybe (ExceptionWithContext SomeException)
  }
```

`finalizationEvidence` reads what finalization observed beside a body failure
it kept primary: at most the first cancellation delivered while the lifetime
waited for its worker, and at most one failure raised while its worker group
closed, each exactly as it was caught, so the group's own annotations stay
reachable. It answers `Nothing` when finalization observed neither, and for an
exception that is itself the finalization cancellation or group-closing
failure, which the verdict already accompanies.

Stopping graphics admission when the error latch is set is the owner's, at its
checkpoints: this package exposes the latch and does nothing about it. VK-7's
controller does not read it yet — it records and submits nothing, so there is
no graphics work to stop — and stopping on a strict validation error is in
VK-15's (#231) scope.

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
- `destroyInstanceQuiesced` destroys the instance through `afterLastCallback`,
  on the path that returns and on the one that unwinds, and yields the
  `Quiesced` evidence the lifetime needs.

Both register `captureMessengerCallback`, whose code is linked into the
executable and so lives as long as the process, with the capture's storage as
user data, which the lifetime keeps until the body has returned. The package
installs no Haskell callback, no allocation callback and no trampoline.

`nativeFfiConfiguration` records how the package calls Vulkan and what can call
back: the binding at `vulkan-3.27` with `safe-foreign-calls` on and
`darwin-lib-dirs` off, as `cabal.project.vulkan` constrains it and
`tools/toolchain/binding.pin` records; the C-only capture callback; no Haskell
callbacks; and, since VK-11, the audited recording subset — the package's only
genuine `unsafe` imports, which [the FFI audit](gpu_backend.md#the-ffi-audit)
lists entry point by entry point, and from which only this C-only callback is
reachable. The proof record prints it beside the build's source digest, and the
proof checks the binding flags against the pin.

## State

| State | Owner | Writers | Readers | Thread | Lifetime and reset |
| --- | --- | --- | --- | --- | --- |
| C storage: queue, objects, labels, text | the lifetime | producers on any thread; the worker, consuming | the worker; the lifetime after it | any | allocated at entry, freed in step 4 unless retained |
| C slot: announcements, close flag, generation, latches, counters | the lifetime, then its slot's next claimant | producers on any thread; the lifetime, closing | the lifetime; `captureStatus` | any | static; claimed at entry, reset only when claimed again |
| Status snapshot | the lifetime | step 4, once, before the free | `captureStatus` once the slot serves another lifetime | the lifetime's | per lifetime |
| Phase | the lifetime | the lifetime's thread | any thread | any | per lifetime; only advances |
| Taken and delivered counts | the worker | the worker | any thread; the lifetime once the worker is terminal | the worker's | per lifetime; only grow |
| Wake and final requests | the lifetime | `requestDrain`; the lifetime, once, for final | the worker | any | per lifetime |

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
each limit and one byte past it, the shared budget, both label arrays apart and
in order with what each reported, each at its limit and one past it, a label
count with no array, the budget's copy order through the labels, one truncation
for a record cut twice, and label space reused cleanly, saturation and the drop
counter with the error latch surviving it, error latching ahead of admission,
truncation counting, contained producer failures, counters saturating at their
ceilings, eight threads racing for positions while a consumer drains, closing
waiting for a producer that has announced itself, a report that begins only
after closing and freeing, slot reclamation beyond the table's size, and a
stale user data naming nothing.
`Lifetime` drives the whole lifetime with injected sinks: delivery and its
fields, a record's labels in its own scoped context and no other's, the worker's own group, the verdict's issues, sink failure beside a
preserved primary failure, a record produced while draining, the final drain,
a blocked sink holding the storage, cancellation during finalization — with the
record in the worker's hands counted — and of the body, a failed body kept
primary over a cancellation during finalization with that cancellation beside
it, a body's own cancellation kept primary over a different one during
finalization, status reads racing the
release, a producer that announced itself before the body returned counted in
the verdict, a report not yet begun counted outside it, quiescence evidence
missing, established while a failure unwinds, issued by another capture, and
not established by a destruction that threw, the verdict's delivered
count matching what the sink received across 300 cancellations, and
retention. Waits are explicit: a gated sink says when it is entered,
the delivered count says what the worker has done, and the poll is replaced by
one no example reaches.
`Outcome` drives the lifetime's private precedence selection directly, because
a failure while the worker group closes arrives after the worker is terminal,
where no public coordination point exists: a failed body kept primary over a
group-closing failure whose own context stays reachable, and every combination
of body outcome, finalization cancellation and group-closing failure.

The native cases are the Vulkan native suite's `vk6-capture` case, on an
instance of its own in a child process; see
[the Vulkan native suite](gpu_backend.md#the-native-suite). Their earlier records
are retained as `docs/vulkan/linux-vk6.md` and `docs/vulkan/macos-vk6.md`. Every
validation-enabled instance there, and the shared roots', also enables
synchronization validation through its create info, and the suite's
`synchronization-hazard` case proves the capture receives its reports. The
`debug-names` case provokes one validation error on a named managed resource
inside a labelled batch and requires the delivered record to carry that
resource's name and, where the pinned layer reports them, the batch's label.
