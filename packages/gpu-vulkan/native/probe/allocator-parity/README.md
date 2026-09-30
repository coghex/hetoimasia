# Allocator parity probe

GRS-1's comparison of an owned Haskell allocator with VMA (#331, design
decisions D-4, D-13, D-14 and D-32 in
[the GPU resource services design](../../../../../docs/designs/gpu_resource_services_design.md)).
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
[the parity record](../../../../../docs/gpu_allocator_parity_record.md). It is
not the validation of VMA's production integration, which D-39 assigns to
GRS-18.

```bash
bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe
bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe -- --output FILE
bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe -- +RTS -A1g -RTS
```

Options after `--`: `--output FILE` also writes the report there;
`--gate-traces DIR` and `--diagnostic-traces DIR` (repeatable) choose the
traces; `--warmup N` (default 3) and `--repetitions N` (default 20). The exit
status is 0 when every gate is met for both Haskell implementations, 1 when a
gate is missed on a gated trace, and 2 when a self-check fails. A miss is
reported as a miss, never waived.

The probe is local apparatus, not a validation group: no CI worker runs it and
no change selects it, and `docs/test_classification.md` lists it with the other
work outside routine automation. It is built only through
`cabal.project.vulkan`, and here VMA reaches this test suite alone. Take
timings only on a quiet machine; each report records the load average at its
start.

## Files

| Path | What it is |
| --- | --- |
| `Main.hs` | Options, the passes each trace runs, self-checks and the report |
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

## The mutable prototype

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

## Trace format and replay protocol

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

## VMA's configuration

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

## The gates

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

## Timing

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

## Heap, collection and search

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

## Self-checks

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
