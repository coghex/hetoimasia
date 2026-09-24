# Runtime tracing: proposed first contract

Design state: `exploring`.

This is the proposed contract for RTC-1 in the
[runtime capability report](runtime_capabilities_findings.md#rtc-1-runtime-performance-evidence-lacks-a-correlated-engine-timeline).
The owner requested a documentation-only design discussion on 2026-09-23:
no issue drafts, tracker changes, implementation, or delivery decomposition.
The recommendations below are proposals, not approved behavior or delivered
capabilities. No new epic is proposed.

## Purpose and recommendation

Make a short execution capture answer: what work was outstanding, which owner
was executing or waiting, how long an operation took, and what the RTS was
doing at the same time. Start with opt-in CPU tracing through GHC's eventlog,
using a narrow injected engine interface and offline inspection. Keep the raw
eventlog as evidence; use a qualified offline converter for an engine timeline
in Perfetto. A custom viewer and an always-running telemetry service would add
work before we have established the useful events.

This complements existing logs and counters. It does not change log filtering,
sink failure semantics, supervision, update policy, or resource release rules.
A long span establishes elapsed time, not CPU consumption or the cause of a
stall. Overlap with GC is evidence of overlap, not automatic attribution.

## Verified current state

Checked against `68ddbbce1f25794b576331bb3b2b711cf3ec255e`:

- `Foundation.Time` owns opaque instants and explicit clock domains. Production
  sources share a monotonic epoch; scripted sources need not share it.
- `Runtime.UpdatePolicy` is pure. Its fixed-step accounting describes demand,
  remainder, and discarded simulation time; it does not measure execution.
- `Foundation.Messaging.Channel` exposes transactional aggregate statistics;
  these do not timestamp each message's residence in the queue.
- `Foundation.Worker` protects dependencies through group drain. Tracing must
  not reinterpret a wait, stop request, or cancellation as completion.
- `Runtime.Inbox` owns handler dispatch and its drain acknowledgement. Those
  are useful observation boundaries, with different meanings.
- The console executable uses `-threaded -rtsopts`. No engine tracing facade
  or shared event schema is present in the production foundation/runtime code.

GHC 9.14.1 supports user events and RTS events in an eventlog, with timestamps
in elapsed nanoseconds from program start. `traceEventIO` sequences an event
with surrounding IO. Its presence alone does not prove that runtime event
recording is enabled. See the references below.

## Proposed contract

### P-1. Explicit activation and ownership

Tracing is off by default. The application supplies either a disabled handle
or a capture-scoped opaque `Tracer` to interested consumers. Libraries neither
read environment settings nor install a global tracer. Reuse validated
component names; do not add a universal environment or make engine packages
depend on a game or a viewer.

The small common event vocabulary and disabled path belong at the foundation
boundary; runtime-owned observations stay in runtime. The application selects
the backend and capture configuration. Exact module/API names remain open.

| State | Owner and access | Lifetime and end behavior |
| --- | --- | --- |
| Capture configuration and identity | Application constructs; producers read immutable values | One capture; a new capture has a new identity |
| Event budget, active spans, bounded name/track table, loss status | Capture owns; producers update through its narrow interface | Shared across producer threads; close stops new admissions; late emissions are ignored and cannot reopen it |
| Correlation token | Creating producer passes it explicitly with the work | Contains identity only, retains no payload/resource; IDs never alias another operation in that capture |
| Eventlog writer and file | Executable/RTS owns the process-level capture | Borrowed by the engine capture; library scope exit does not close the RTS writer |
| Offline conversion state | Separate tool owns it | Reads a completed or explicitly partial artifact; owns no live engine state |

IDs and counters have checked overflow behavior: disable further admission and
record exhaustion rather than wrapping. Capture closure does not wait for an
unfinished span or worker. It does not flush on every event or install another
worker whose drain could extend application shutdown. There is no persistent
ring buffer or automatic restart in this first proposal.

### P-2. A small versioned vocabulary

Use explicit IO events: span begin/end, instant/phase, numeric counter sample,
and correlated handoff observations. Do not use pure `trace` expressions.
Each engine record identifies schema version, capture, component, logical
track, event kind and event name; span/handoff IDs and small numeric fields
are included where relevant. Span ends classify success, failure, or
cancellation without embedding exception text. Begin/end IDs pair events
across interleaving; a converter must not infer a global nesting stack.

Static names are validated before capture. Records contain bounded encoded
fields, not arbitrary `Show` output, user scripts, message bodies, or object
graphs. Parent IDs are explicit and optional. The disabled path does not read
a clock, allocate IDs, encode fields, or evaluate a supplied payload builder.
This is a behavior to verify, not a claim of zero execution cost.

Logical worker identity, Haskell thread identity, RTS capability, and OS thread
identity are different. A worker may migrate between capabilities. The first
viewer uses logical tracks for elapsed engine spans; it must not label those
spans as continuous CPU occupancy. Mapping to scheduler events requires a
verified thread-identity mapping, not parsing `Show ThreadId` by assumption.

### P-3. First observation points

| Observation | Meaning and initial placement |
| --- | --- |
| Update turn and simulation step | Span around the consumer's IO work; sample step count and discarded simulation time separately; keep `Runtime.UpdatePolicy` pure |
| Worker phase and lifetime | Declared operation/phase and observed startup, stop request, cancellation request, completion; requests never stand for completion |
| Message handoff and handler | Correlate send attempt, send result, handler start/end; name rejection or abandonment explicitly |
| Queue/backlog sample | Read existing statistics at selected boundaries; a sample is not a continuous depth history |
| Drain wait | Begin/end around an owner wait; an unfinished span remains unfinished when capture stops |

Use one headless consumer combining an update loop, a bounded inbox, and
supervised workers to establish usefulness before instrumenting every module.
Do not emit IO from STM or use `unsafeIOToSTM`: retries could duplicate or lie
about events. A send-return marker can occur after a receiver has started.
Therefore the first handoff view reports send-attempt-to-handler latency,
which includes admission and scheduling; it does **not** claim exact queue
residence. Exact enqueue/dequeue timing needs a separately justified observation
boundary. Cross-thread record order alone is not causality.

Haskell spans around native calls may later show host wait duration. They do
not measure GPU work. Do not call Haskell tracing from Vulkan's C-only callback
or any foreign boundary that forbids Haskell re-entry.

### P-4. Backend and clock semantics

The first backend calls `traceEventIO` at the observation point. Engine and
RTS events then use the eventlog's timestamps. No asynchronous engine export
queue is inserted: timestamping the later dequeue would distort the work.
Do not subtract an opaque `Foundation.Time.Instant` from an eventlog timestamp
or serialize its diagnostic `Show` representation. Any future separate clock
requires explicit calibration, uncertainty, and domain metadata.

The executable selects the required user, scheduling and GC event classes and
an explicit output path. A capture receipt records commit/build identity, GHC
version, RTS flags, platform, event schema, limits, and workload. Routine runs
remain disabled; ordinary builds must still support the no-op interface.

GHC's writer is process-wide. The library does not replace it, start competing
writers, or promise delivery acknowledgements for individual records. Eventlog
emission can encounter RTS buffering, synchronization and writer I/O. It is
neither a wait-free interface nor a hard latency guarantee. A background flush
option does not remove that limitation. Direct eventlog tracing is appropriate
for explicitly requested diagnostic runs; requiring strict producer latency
would reopen this backend choice.

### P-5. Bounded engine work and honest incomplete captures

Proposed starting defaults, subject to measurement and owner agreement:

- 100,000 engine records per capture, including metadata and reserved endings;
- 256 encoded bytes per engine record;
- 1,024 registered logical tracks/names and 1,024 simultaneously active spans;
- stop admitting new spans after 30 seconds, checked at emission boundaries.

Limits are validated at construction and enforced before encoding an event.
Reserve capacity for each admitted span's end and a capture summary; refuse a
new span when that reservation cannot be made. Existing spans may end after
the admission window while capacity remains reserved. Explicit capture close
does not wait for them. Unknown IDs and table exhaustion drop trace records,
never engine work. Keep bounded, saturating refusal/loss counters outside the
ordinary event budget; do not create an unbounded bookkeeping map or error log.

These limits bound the facade's state and engine records. They **do not cap
RTS event volume, total file size, capture wall time, or file-system latency**.
The runner owns the finite diagnostic workload and available disk space; a
hard total-file cap would need a different writer design. Reaching the engine
limit is visible as a partial capture, never a complete-looking trace.

Recovered backend/encoding failures disable tracing and record degraded
status. They do not replace a workload failure, turn failure into success, or
swallow asynchronous cancellation. Span wrappers preserve the body's masking
and exception semantics and do not add uninterruptible output. Process-fatal
RTS/writer failure and permanently blocked native I/O cannot be contained by
this facade; it is not crash isolation. Missing terminal records mean unknown
completion, not success. No crash-survival or durable final-flush promise.

### P-6. Inspection and evidence

Retain the raw `.eventlog` and its receipt in local capture storage. Conversion
produces a separate view and preserves schema, IDs, units, timestamps, loss
status and unfinished spans. Perfetto can import Chrome Trace Event JSON;
that does not establish that it can directly decode this GHC eventlog/schema.
Qualify the converter with the pinned GHC format before depending on it.
Until then, an eventlog decoder is the reference inspection route.

An incomplete stream must remain visibly incomplete. Converter tests cover
interleaving, missing begin/end records, unknown schema versions, truncated
input, and cross-thread handoffs without invented ordering. Keep nanoseconds
internally and explicitly convert any output-format units. Ignore local raw
captures by default; retain evidence deliberately when an implementation or
performance claim needs it. No automatic uploads or capture of game payloads.

### P-7. Verification and cost

Test the interface and pairing model with an injected recorder and coordinated
workers: disabled payloads remain unevaluated; bounds hold under contention;
cancellation preserves the original outcome; exhausted captures stay readable;
late events cannot reopen a closed capture. No sleeps for concurrency proofs.
Use a finite headless native eventlog capture to prove that engine events and
selected RTS events are actually present and readable on macOS and Linux.

Compare an uninstrumented baseline with three modes on the same workload and
matched optimized build settings: tracing disabled, RTS capture alone, and RTS
plus engine capture. Record throughput, operation latency distribution,
allocation, and output volume so the RTS and facade costs are distinguishable.
Suggested investigation thresholds are 1% overhead for the disabled facade
versus the uninstrumented baseline and 5% additional workload-time overhead
for the selected engine events versus RTS-only capture. These are provisional targets, not measured
results or universal per-call bounds. Report uncertainty and refine noisy
measurements; do not make ordinary CI timing assertions or silently weaken a
target. Use the existing profiling workflow for eventual measurements.

## Boundaries and open choices

RTC-2 stalled-drain observation remains a separate capability: a trace may show
an unfinished drain, but it does not guarantee a live observer or progress
during an RTS/native stall. GPU timing and CPU/GPU clock correlation, native
crash collection, statistical profiling, live UI, remote telemetry, and
always-on flight recording are outside this first contract.

- **Q-1 — Capture backend:** accept opt-in GHC eventlog with its I/O and
  process-wide writer limits, or require strictly bounded producer latency?
  Recommendation: eventlog for short developer captures first.
- **Q-2 — Inspection:** qualify an offline Perfetto conversion as the intended
  engine view, retaining raw-eventlog inspection as the reference?
  Recommendation: yes; no custom viewer or embedded Perfetto SDK initially.
- **Q-3 — Initial bounds and cost:** accept P-5's defaults and P-7's thresholds
  as provisional qualification targets? They need measurement before release.

No technical choice above is recorded as an owner decision yet. Package/API
details and any implementation breakdown wait for agreement on this contract.
RTC-1 remains unprocessed in the report; this proposal is not its completion.

## References

- [GHC 9.14.1 runtime eventlog options](https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/runtime_control.html#rts-eventlog): event classes, timestamps, writer lifecycle and output configuration.
- `Debug.Trace` in the locally installed GHC 9.14.1 / base 4.22.0.0 documentation: `traceEventIO` sequencing and `flushEventLog`. Exact installed HTML was inspected; no backend implementation has been qualified by this document.
- [Perfetto supported external formats](https://perfetto.dev/docs/getting-started/other-formats): Chrome Trace Event JSON import.
- [Current logging contract](logging.md), [time contract](time.md), and [runtime capability findings](runtime_capabilities_findings.md).
