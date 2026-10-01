# Allocator probe

Local apparatus with two modes, both run through `tools/vulkan/run.sh`:

- **GRS-18, the default**: the production VMA integration qualified by bounded
  measurement on a real device (#361, design decisions D-16, D-38, D-39 and
  D-40 in
  [the GPU resource services design](../../../../../docs/designs/gpu_resource_services_design.md)).
  Its retained runs and verdict are in
  [the VMA qualification record](../../../../../docs/gpu_vma_qualification_record.md).
- **GRS-1, `--virtual-block-parity`**: #331's comparison of an owned Haskell
  allocator with VMA's virtual block, kept as D-38's evidence in
  [the parity record](../../../../../docs/gpu_allocator_parity_record.md).

```bash
bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe -- --output FILE --warmup 3 --repetitions 20
HETOIMASIA_VMA_FOREIGN_CALLS=safe bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe -- --output FILE --warmup 3 --repetitions 20
bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe -- --virtual-block-parity --output FILE
```

Options after `--`: `--output FILE` also writes the report there;
`--gate-traces DIR` chooses the gated traces; `--warmup N` (default 3) and
`--repetitions N` (default 20); with `--virtual-block-parity` also
`--diagnostic-traces DIR` (repeatable). In either mode the exit status is 0
when every limit or gate is met, 1 when one is missed, and 2 when the run is
invalid or incomplete: a self-check failed, a pass did not complete, a free ran
before its fence, or validation reported anything. A complete run with a miss
is still a complete run, and its report is the evidence of the miss; a miss is
never waived.

The probe is not a validation group: no CI worker runs it and no change
selects it, and `docs/test_classification.md` lists it with the other work
outside routine automation. It is built only through `cabal.project.vulkan`,
and VMA reaches this test suite alone. It is linked with the threaded runtime.
Take timings only on a quiet machine; each report records the load average at
its start.

## GRS-18: the production integration

### What one run measures

One run measures one build of the Hackage `VulkanMemoryAllocator` binding,
because a Cabal project builds one configuration of a dependency.
`HETOIMASIA_VMA_FOREIGN_CALLS` chooses it: `unsafe`, the default and what the
unmodified tracked tree builds, is the binding's default unsafe imports;
`safe` is its `safe-foreign-calls` flag. `tools/vulkan/run.sh` passes the
choice as a command-line constraint, so `VulkanMemoryAllocator ==0.11.1.0
+vma-ndebug`, the `vulkan` binding's flags and every other input stay
identical, and builds the safe variant in `dist-vulkan-vma-safe`. The probe
does not trust the declaration: it decides the call safety by behaviour — a C
device-memory callback inside a binding call waits for another Haskell thread
to release it, which only a safe call allows — and a run whose declaration
and behaviour disagree is invalid.

Each run measures every configuration its build can run:

| Configuration | Calls | Callbacks |
| --- | --- | --- |
| C driver | C, the baseline | C |
| Hackage binding | the build's call safety | C |
| Hackage binding (safe build only) | safe | Haskell |
| Engine shim, unsafe imports | unsafe | C |
| Engine shim, safe imports | safe | C |
| Engine shim, safe imports | safe | Haskell |

The **engine shim** is Q-19's second candidate: one C entry per call the
engine makes (`cbits/vma_production.cpp`, `hetoimasia_shim_*`), taking only
scalars and one reused output record, so the Haskell side marshals no struct.
Because the shim's imports are the probe's own, both of its call safeties are
measured in either build. No unsafe foreign call may reach a Haskell callback:
Haskell callbacks are installed only under safe calls, every allocator is
destroyed through a safe import because destruction frees VMA's retained
blocks, and validation's messenger is C.

Every limit is evaluated separately for each Haskell configuration, against
the C driver of the same run.

### The device, the allocator and the calls

The probe creates its own windowless device: one instance with
`VK_KHR_portability_enumeration` where the loader offers it, the first
physical device, one graphics queue, and `VK_KHR_portability_subset` where the
device offers it. Timings are taken on a device with no layer. The
correctness passes run on a second device with `VK_LAYER_KHRONOS_validation`
and the features `HETOIMASIA_VULKAN_VALIDATION_FEATURES` names, which must
include `synchronization`; its messenger is the C callback
`hetoimasia_probe_messenger`, and any message makes the run invalid.

Every pass creates a fresh allocator through the binding, used from the
probe's one thread: `VMA_ALLOCATOR_CREATE_EXTERNALLY_SYNCHRONIZED_BIT`,
`preferredLargeHeapBlockSize` 256 MiB stated explicitly (D-40), Vulkan 1.3,
the loader's `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr`, and
device-memory callbacks into C or Haskell. Both kinds update one
`hetoimasia_block_counters` identically: blocks opened and freed, bytes held
and their peak, and an event log. Allocator creation and destruction are never
timed.

The C driver (`hetoimasia_vma_replay_script`) and the Haskell driver
(`Production/Driver.hs`) replay the same encoded script over the same class
table, operation by operation, with the same timed intervals. The C driver
calls the VMA the Hackage package compiles, so both drivers run identical VMA
code; the declarations it calls are restated, and a layout self-check holds
each restated struct to the binding's generated layout.

**Memory types.** The engine chooses each class's memory type (D-38): of the
types the class's `memoryTypeBits` allows that carry every required flag, the
one with the most preferred flags, then the fewest avoided flags, then the
lowest index. Every request pins that one type in `memoryTypeBits`, with
`VMA_MEMORY_USAGE_UNKNOWN`.

**D-40.** Every allocation of a trace, and the D-40 phases of the per-call
script, first ask with `VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT` and, only if
that fails, make the allocating call. After it, the driver reconciles what
the callbacks recorded against D-40's bound: nothing opened by the
`NEVER_ALLOCATE` attempt, and no more by the allocating call than the larger
of the type's preferred block size (VMA's `CalcPreferredBlockSize`) and the
allocation's size. Every break is counted and reported.

### The resource classes and the trace-to-resource mapping

| Class | Resource | Usage | Required / preferred / avoided | VMA flags |
| --- | --- | --- | --- | --- |
| sheet | 2D `R8G8B8A8_UNORM` image, optimal tiling, 1 mip, 1 layer | `TRANSFER_DST \| SAMPLED` | `DEVICE_LOCAL` / — / `HOST_VISIBLE` | — |
| geometry | buffer | `VERTEX_BUFFER \| INDEX_BUFFER \| TRANSFER_DST` | `DEVICE_LOCAL` / — / `HOST_VISIBLE` | — |
| staging | buffer | `TRANSFER_SRC` | `HOST_VISIBLE` / `HOST_COHERENT` / — | `MAPPED` |
| readback | buffer | `TRANSFER_DST` | `HOST_VISIBLE` / `HOST_CACHED \| HOST_COHERENT` / — | `MAPPED` |

The retained traces carry only identities, sizes, alignments, frees and
checkpoints. Each is translated deterministically, before anything runs
(`Production/Script.hs`, `traceScript`):

- `synarchy-sheets`: every allocation `a ID SIZE ALIGNMENT` is a **sheet** of
  extent `2^⌈k/2⌉ × 2^⌊k/2⌋` for `SIZE = 4 × 2^k` bytes (16 MiB is
  2048 × 2048). A size of any other form is refused.
- `small-steady`, `small-bursty`, `small-mixed`: every allocation is a buffer
  of exactly `SIZE` bytes, whose class follows `ALIGNMENT`: 16 is
  **geometry**, 64 **staging**, 256 **readback**. Any other alignment is
  refused.
- `f ID` destroys the resource and its allocation. `c LABEL` records the byte
  quantities in the evidence pass and does nothing else.
- **Fields with no counterpart.** The `capacity` header is not applied: a
  real allocator has no single block, and VMA opens blocks of its preferred
  size. `ALIGNMENT` only chooses a class: size and alignment come from the
  device's memory requirements, which the report records per class. The
  virtual-block replay refused some requests; here every request is made, and
  one the device refuses makes the run invalid.

Both drivers apply the same translation, descriptors, policies and operation
sequence, and a self-check requires identical completed work.

### The per-call script

A fixed sequence (`callScript`), each phase on resources of one class:

1. 512 staging buffers of 64 KiB, one allocating call each; then each is
   mapped, flushed, invalidated and unmapped; then all are freed.
2. 512 sheets of 256 × 256, one allocating call each; then all are freed.
3. 512 geometry buffers of 64 KiB through D-40, which memory VMA already holds
   places; then freed.
4. 64 geometry buffers of 64 MiB through D-40. They keep filling the blocks
   VMA holds, so whenever none has room the `NEVER_ALLOCATE` attempt fails
   and the allocating call opens a block; then all are freed.
5. 16 geometry buffers of 160 MiB through D-40, each freed at once: larger
   than half a preferred block, so each fails the attempt and gets a
   dedicated allocation.

Map, unmap, flush and invalidate are timed on persistently mapped staging
allocations, the engine's policy; on a coherent type VMA's flush and
invalidate do no work.

### Timing

Both drivers read one clock, `hetoimasia_probe_now`; the report states what an
empty timed interval costs on each side. Everything a call needs is evaluated
before its clock starts on both sides, as the C driver builds its create infos
before its own; inside the interval are the calls and, after a
`NEVER_ALLOCATE` attempt, the read of what it opened. The Haskell replay is
inlined for each API, so each call site is the binding's function or the
shim's import itself, as engine code's would be, never a call through a record
of functions; a creation answers its `VkResult` and writes its results into
one reused record. Each pass replays on a fresh
allocator; a major collection precedes every pass; configurations are
interleaved within each repetition and their order rotates by repetition.

- **Per operation.** One clock pair around each operation: a creation's whole
  D-40 sequence, with the allocating call's own interval recorded beside it,
  or one free, map, unmap, flush or invalidate. An operation's sample is its
  mean over the measured repetitions; medians and 95th percentiles are
  nearest-rank over a population's operations.
- **Whole script.** One clock pair around the whole replay, one sample per
  repetition, for throughput; the median over repetitions decides it.

### The accepted limits

The owner's limits (#361), evaluated for every Haskell configuration:

- **Binding path.** For each gated call, the Haskell median minus the C
  median, each less its side's empty interval, is no greater than the larger
  of 25% of the C median or 50 ns. The difference is the total binding-path
  overhead, marshalling and wrappers included, not the foreign-call
  transition alone. The gated calls are buffer and image creation with one
  allocating call, buffer and image frees, map, unmap, flush, invalidate,
  `NEVER_ALLOCATE` placing in held memory, and the failed attempt followed by
  the allocating call that opens a block or a dedicated allocation. The parts
  of a failed attempt, and frees that release device memory, are reported and
  gate nothing.
- **Throughput.** On each gated trace, the Haskell median elapsed time is no
  more than 1.25 × the C median elapsed time for the same completed work.
- **Completion-deferred frees.** No free before its batch's fence signals,
  with clean synchronization validation. A violation makes the run invalid.
  Its cost against immediate frees is reported with no numeric limit.

### Completion-deferred frees

`small-steady` is replayed in batches of 64 operations that the GPU executes,
three in flight, once per Haskell configuration, through that
configuration's own API and callbacks (`Production/Deferred.hs`), so each
configuration's gate is judged on its own frees. Each resource is used by a transfer
command in the batch that creates it and again in the batch that frees it,
unless that is the same batch: geometry and readback buffers are filled,
staging buffers are copied into their own region of a scratch buffer. Every
command buffer begins with one transfer-to-transfer memory barrier. A free
waits until that batch's fence has been waited on, and each destroy first
checks that the fence is signalled and still that batch's. Each
configuration's timed passes run on the unvalidated device, and one more runs
under validation. Immediate frees are the same trace's frees in that
configuration's plain replay.

### Self-checks

The run is invalid, exit status 2 and a report headed *Invalid*, if any of
these fails:

- the C driver's restated VMA structs match the binding's layout, and the
  counter and shim records their Haskell offsets;
- the threaded runtime with one capability, and no layer enabled through
  `VK_INSTANCE_LAYERS` or `VK_LOADER_LAYERS_ENABLE`;
- synchronization validation requested, and the binding's call safety, by
  behaviour, equal to what `run.sh` declared;
- every gated trace's digest equals the retained one;
- on both devices, for every configuration: every request placed; the
  placements, D-40 outcomes, block events and checkpoint byte quantities
  identical to the C driver's, operation by operation; the callbacks' held
  bytes equal to VMA's own statistics at every checkpoint and at the end; and
  nothing held once the allocator is destroyed;
- every timed pass does exactly its evidence pass's work;
- no free before its batch's fence was observed signalled, and no validation
  message.

## GRS-1: the virtual-block parity probe

GRS-1's comparison of an owned Haskell allocator with VMA (#331, design
decisions D-4, D-13, D-14 and D-32), run with `--virtual-block-parity`.
It replays committed allocation and free traces into one fixed-size block,
evaluates requirement 7's four gates, and reports diagnostics that separate
search, copying, collection and timer overhead. It replays each trace through:

- the pure best-fit placement, now the test-only `placement-reference`
  sublibrary of `hetoimasia-gpu-vulkan-model`;
- a mutable prototype of it that makes the same decisions;
- VMA's virtual block, with its default strategy and with `MIN_MEMORY`.

**Status: retained evidence.** Neither Haskell allocator met the gates, and
the owner chose VMA for production allocation (D-38). The probe and its three
runs are kept as that decision's evidence, in
[the parity record](../../../../../docs/gpu_allocator_parity_record.md).

```bash
bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe -- --virtual-block-parity --output FILE
bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe -- --virtual-block-parity --output FILE +RTS -A1g -RTS
```

Its exit status is 0 when every gate is met for both Haskell
implementations, 1 when a gate is missed on a gated trace, and 2 when a
self-check fails. Runs 1 to 3 used the non-threaded runtime; the suite is now
linked threaded for GRS-18, which this mode's pure Haskell and unsafe calls do
not depend on.

## Files

| Path | What it is |
| --- | --- |
| `Main.hs` | Options, the mode, and GRS-1's passes, self-checks and report |
| `Production.hs` | GRS-18: the run, the limits and the report |
| `Production/Device.hs` | GRS-18's windowless device, its memory-type rule and the validation messages |
| `Production/Script.hs` | GRS-18's resource classes, the trace-to-resource mapping and the per-call script |
| `Production/Driver.hs` | GRS-18's allocators, callbacks, call-safety check, and the Haskell driver over the binding and the shim |
| `Production/Deferred.hs` | GRS-18's completion-deferred frees |
| `cbits/vma_production.cpp` | GRS-18's C driver, engine shim, callbacks, messenger and layout checks |
| `Parity/Trace.hs` | The trace format: parsing and checking before anything is timed |
| `Parity/Replay.hs` | The replay modes and pass summaries both sides share |
| `Parity/Haskell.hs` | The reference's replay, into one fixed `Block` running `bestFit` |
| `Parity/Mutable.hs` | The mutable prototype's replay, through `stToIO` |
| `Parity/Differential.hs` | The prototype and the reference in lockstep on seeded random scripts |
| `Prototype/MutableBestFit.hs` | The mutable prototype: best fit over mutable arrays in `ST` |
| `Parity/Vma.hs` | The shim's bindings, the shared clock and the layout check |
| `Parity/Reference.hs` | Best fit's search reconstructed from a block's layout |
| `Parity/Report.hs` | The gates' arithmetic |
| `cbits/vma_replay.cpp` | The C++ shim that replays whole traces into VMA |
| `generate_traces.py` | Regenerates every trace |
| `traces/*.trace` | The four gated traces |
| `traces/churn/*.trace` | The churn sensitivity sweep: hypothetical, never gated |
| `traces/sweep/*.trace` | The occupancy sweep: hypothetical, never gated |

## GRS-1: The mutable prototype

`Prototype/MutableBestFit.hs` asks what the reference's persistent maps cost.
It keeps the reference's exact decisions: the smallest free range a request
fits once aligned, the lowest offset among equal sizes, the same granularity
rule and the same validation. Its representation is mutable and explicit:

- **Segments.** A `MutableBlock s` is mutated in place by operations in
  `ST s`, and has one owner. Every range is a segment in a slot pool of
  unboxed `Int` arrays, ten fields per slot. Segments link to their physical
  neighbours by slot index, so a release coalesces in constant time and
  nothing is ever shifted.
- **The size index.** Free segments sit in TLSF-style size bins found through
  two bitmap levels. Each bin is a treap ordered by (size, offset), which
  preserves the reference's order with O(log n) insertion and removal.
- **Handles.** A placement answers a slot, a generation and an offset. The
  generation rejects a stale or repeated release.

The first version kept each bin as a sorted list. Its trial walked up to
1,214 segments per insertion on dense workloads, and it was replaced by the
treap before any measured run.

## GRS-1: Trace format and replay protocol

Line-oriented ASCII. `#` lines are comments; the first names the format and
the rest state the trace's derivation and assumptions, which the report
quotes. Then a header — `trace NAME`, `capacity BYTES`, `seed N` — and one
operation per line:

- `a ID SIZE ALIGNMENT` allocates. Identities are issued densely from zero.
- `f ID` frees an identity allocated earlier and not yet freed.
- `c LABEL` is a checkpoint.

Both implementations receive identical requests and each tracks its own
outcomes. A request one side refuses is not live on that side, so its later
free is a no-op there and is not timed. Every request is an optimally tiled
resource. VMA's virtual blocks have no `bufferImageGranularity`, so the traces
use one tiling and the Haskell block uses granularity 1, which makes the
placement constraints equivalent. Mixed-tiling granularity is proven by
`gpu-model-tests`. No comparison with VMA's real allocator follows: D-39
superseded D-32's native comparison, and GRS-18 (#361) validates VMA's
production integration on a device instead.

The trace parser rejects a malformed trace before any replay: a
non-dense identity, a free of an identity that is not live, or a request the
placement validation refuses.

## GRS-1: VMA's configuration

VMA is the copy the Hackage `VulkanMemoryAllocator` package compiles, pinned at
`==0.11.1.0` in the test suite and in `cabal.project.vulkan`, which also turns
on its `vma-ndebug` flag so its assertions are compiled out as in a release
build. That package bundles VMA 3.3.0 (its changelog). It does not install
`vk_mem_alloc.h`, so the shim restates the few virtual-block declarations it
calls; before any replay, the probe marshals each of those structs through the
binding's own generated layout and has the shim read it back, and stops if any
field disagrees.

Every virtual block uses VMA's default algorithm, TLSF. It never uses the
linear algorithm or an upper-address allocation: those flags appear only as
sentinel values in the layout check. Two allocation strategies are compared:

- **VMA default** — no strategy flag. VMA's default search tries the next
  larger size class, then the untouched end of the block, then the best-fit
  class. It is the gated baseline, as in run 1.
- **VMA MIN_MEMORY** — `VMA_VIRTUAL_ALLOCATION_CREATE_STRATEGY_MIN_MEMORY_BIT`,
  VMA's closest analogue of best fit. It is a separate comparison and gates
  nothing.

## GRS-1: The gates

Requirement 7's four criteria, for each gated trace and each Haskell implementation, against VMA
default, computed exactly as in run 1:

1. **Refused bytes.** Bytes of refused requests over bytes of all requests; the
   Haskell rate may exceed VMA's by at most 2 percentage points.
2. **Fragmentation.** `1 − largest free range ÷ free bytes`, zero when nothing
   is free; within 2 percentage points of VMA's at every checkpoint.
3. **Median time.** The Haskell per-operation median at most twice VMA's, for
   allocations and for frees each.
4. **Placement.** The Haskell per-operation median of placed requests under
   5 µs.

## GRS-1: Timing

Both sides read one clock, the shim's `hetoimasia_probe_now` (the raw
monotonic clock, which ticks every 41.7 ns on Apple silicon). The Haskell side
calls it through an unsafe foreign call. The report states what an empty timed
interval costs on each side.

Every pass executes every operation the same way; passes differ only in what
they record. Each Haskell operation's answer is forced with `evaluate` before
the next begins, and the block's state is strict throughout, so forcing the
answer does all the work. Every pass keeps a checksum of the placed offsets and
counts of what it placed and executed. A self-check requires every timed pass
to match its evidence pass, so no timed pass can have skipped or deferred a
placement. A major collection precedes every pass. The three sides are
interleaved within each repetition so drift reaches them alike.

- **Per operation — the gated method.** One clock pair around each operation
  (validation and placement, or release). Each operation's sample is its mean
  over the measured repetitions, which averages the clock's tick away. Medians
  and 95th percentiles are nearest-rank. Allocations, frees and placements are
  separate populations. The report also gives medians with the empty interval
  subtracted.
- **Throughput diagnostics.** One clock pair around each window of 256
  consecutive operations, and around each run of at least 256 consecutive
  allocations or frees. The loop's own bookkeeping and any collection are
  inside. Figures are mean nanoseconds per executed operation: the whole
  trace, the spread over repetitions, and the median and 95th percentile of
  window means. A window's percentile describes windows, not
  individual-operation latency.

## GRS-1: Heap, collection and search

- **Haskell allocation and collection.** Around each windowed pass, the
  forced collection before it excluded: bytes allocated per executed operation,
  from the replay thread's allocation counter (`getAllocationCounter`), and
  collections per thousand operations and collection time as a share of the
  windowed time, from the runtime's statistics (the suite is linked
  `-with-rtsopts=-T`). The statistics' own byte total is brought up to date
  only at a collection, so it cannot measure a pass. A run with a large nursery (`+RTS -A1g -RTS`) takes collection
  out of the windows and shows its share directly.
- **Haskell block footprint.** Live heap above the empty block after a major
  collection, every 1,000 operations of the evidence pass. Everything the pass
  records into is allocated before the baseline is read.
- **VMA heap.** VMA 3.3.0 builds a virtual block's metadata with null
  allocation callbacks, so callbacks cannot see its allocations. The shim
  reads the C library's heap statistics after every operation of a separate
  untimed pass instead: how many operations changed the heap, and the peak
  bytes in use above the empty block.
- **Search.** For up to 2,000 evenly spaced allocations per trace, the free
  ranges best fit examines are reconstructed from the block's layout
  (`Parity/Reference.hs`). A self-check requires each reconstruction to choose
  the offset the implementation chose. VMA has no counterpart.
- **Fragmentation samples.** After every 100 operations, on every side, beside
  the gated checkpoints. Differences are Haskell minus VMA, so negative means
  Haskell is less fragmented.

## The traces

Both modes read the four gated traces; only GRS-1 reads the churn and occupancy sweeps.

Regenerate them all, byte for byte, with:

```bash
python3 generate_traces.py --synarchy ~/work/synarchy \
    --revision 9a274311de7596fc971008eb90a3e67eb83fe004 --output traces
```

The generator reads Synarchy's assets at that revision through `git archive`,
so the checkout's own state does not matter, and draws every random choice
from its own splitmix64 generator rather than Python's `random`. Nothing reads
Synarchy at build or test time.

### Gated traces

| Trace | SHA-256 |
| --- | --- |
| `synarchy-sheets` | `74c2e4c93d557e61dfbbd4e357e1f5626c9eba137a8dbd03b9dd099536a5724b` |
| `small-steady` | `5ecd799fa26e0a73c0a3af2f456f9dbd85e06568691948e35c568e301f29cf3f` |
| `small-bursty` | `4bb9063e41daa08ae02bd239e4bf9d979cfc3b6aeeaf4772eb1322e32b607c0c` |
| `small-mixed` | `c62909c57f8a690941f95b2bf1164b2fc972f0204f5318f724c85444a85c94a8` |

These are the traces run 1 measured, and the probe checks each digest before
comparing a run with it.

**`synarchy-sheets`.** What comes from source, and what is assumed:

- *From Synarchy at `9a27431`:* 6,251 PNGs under `assets/` and their
  dimensions, read from each file's IHDR chunk, as RGBA8 bytes.
- *From the design record:* sheets of 1 to 16 MiB, numbering in the tens to
  low hundreds (D-13); a hot-reloaded image is replaced before the old one
  retires (D-5); per-frame data and staging use rings, not the block allocator
  (D-16, D-33), so they appear in no trace.
- *Assumed:* units are atlased per unit type and streamed, and everything else
  is atlased per texture category and stays resident. Sheets are packed
  first-fit, largest image first, to at most four-fifths full, as the smallest
  power of two from 1 to 16 MiB. Every sheet is aligned to 64 KiB. The block
  is 256 MiB with a 200 MiB streaming budget. Each of 1,500 churn steps either
  streams, with probability 7/10, by unloading one random family and loading
  random unloaded families while the budget allows, or hot-reloads one random
  live sheet, whose predecessor is freed 1 to 3 steps later. Seed 331.
  Synarchy itself has no suballocator, no texture eviction and no hot-reload
  path in `src/Engine/Graphics` at that revision, so none of this churn is
  observed behaviour.

**`small-steady`, `small-bursty`, `small-mixed`.** Every parameter is assumed:
buffers of 256 B to 256 KiB (up to 4 MiB in `small-mixed`), log-uniform, rounded
to 16 bytes, aligned to 16, 64 or 256 bytes, churned around live targets near
the block's capacity. Seeds 1, 2 and 3. Each trace's header states its shape.

### Churn sensitivity sweep (hypothetical)

Six variants of `synarchy-sheets`, each changing one assumed churn parameter
and nothing else: the retire delay (exactly 1 step; 8–16 steps), the hot-reload
share (0%; 70%), and the streaming budget (150 MiB; 240 MiB). If the ratios and
criteria hold across them, the gated result is not an artefact of the assumed
churn. If they change, the answer depends on streaming and hot-reload paths
that do not exist yet.

### Occupancy sweep (hypothetical)

Nine traces of steady small-buffer churn: 100, 1,000 or 10,000 live buffers of
256 B to 64 KiB, in a block they fill to 50%, 75% or 95%, then 5,000 steps of
one random free and one allocation. They show how each side's cost grows with
the number of live placements and free ranges. Seeds 1000 to 1008.

## GRS-1: Self-checks

Exit status 2, and a report headed *Failed*, if any of these fails:

- the shim's restated VMA structs match the binding's layout;
- the percentile arithmetic answers known inputs correctly;
- every gated trace's digest equals run 1's;
- every timed and heap-counting pass, on every side and repetition, places
  exactly what its evidence pass placed;
- every sampled search reconstruction chooses the implementation's offset;
- the prototype and the reference, in lockstep on 500 seeded scripts of 300
  steps each, agree after every step on each placement and on the block's
  usage. The scripts cover granularities up to 1,024, both tilings, and stale
  and repeated releases;
- on every trace, the prototype places each request exactly where the
  reference does, with the same usage at every sample;
- the runtime keeps statistics.

Retained results belong in
[`docs/gpu_allocator_parity_record.md`](../../../../../docs/gpu_allocator_parity_record.md).
