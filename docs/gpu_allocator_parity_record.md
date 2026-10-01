# GPU allocator parity record

The retained evidence of #331 (GRS-1): an owned Haskell block allocator
measured against VMA under design decisions D-4, D-13 and D-14 of the
[GPU resource services design](designs/gpu_resource_services_design.md).

**Outcome: the owned allocator did not meet its acceptance gates.** Neither
the pure best-fit reference nor a mutable prototype of it met requirement 7's
four criteria on any gated trace. On 2026-09-30 the owner chose VMA for
production device-memory allocation (D-38), with performance the priority.
#331 is superseded by that decision, not delivered under its criteria. Nothing
below relabels a missed gate as met.

## What was compared

The optional probe `allocator-parity-probe`
([its README](../packages/gpu-vulkan/native/probe/allocator-parity/README.md)
states the protocol) replays committed allocation and free traces into one
fixed-size block through:

- **the reference** — the pure, persistent best-fit placement (D-13), now the
  model package's test-only `placement-reference` sublibrary;
- **the mutable prototype** (run 3 only) — the same best fit over mutable
  arrays in `ST`, with segments in a slot pool and free ranges in size bins
  that each hold a treap ordered by (size, offset). It makes exactly the
  reference's decisions, which the probe's self-checks prove, so only its cost
  differs;
- **VMA default** — a VMA 3.3.0 virtual block (the Hackage
  `VulkanMemoryAllocator-0.11.1.0` build, assertions compiled out) with its
  default algorithm and strategy, the gated baseline;
- **VMA MIN_MEMORY** (runs 2 and 3) — VMA's closest analogue of best fit, a
  comparison that gates nothing.

The four gated traces are `synarchy-sheets`, derived from Synarchy's assets
at `9a27431`, and the synthetic `small-steady`, `small-bursty` and
`small-mixed`. Runs 2 and 3 add six churn variants and nine occupancy sweeps,
all hypothetical workloads that gate nothing. The README separates what each
trace takes from source from what it assumes.

## The gates

Requirement 7 of #331, for every gated trace, against VMA default:

1. refused bytes no more than 2 percentage points above VMA's;
2. fragmentation within 2 points of VMA's at every checkpoint;
3. median time per operation at most twice VMA's, for allocations and for
   frees;
4. median placement under 5 µs.

| Trace | Implementation | Refused bytes | Fragmentation | Median time | Placement under 5 µs |
| --- | --- | --- | --- | --- | --- |
| synarchy-sheets | Reference | Met | Missed | Missed | Met |
| synarchy-sheets | Mutable prototype | Met | Missed | Missed | Met |
| small-steady | Reference | Met | Missed | Missed | Met |
| small-steady | Mutable prototype | Met | Missed | Missed | Met |
| small-bursty | Reference | Met | Missed | Missed | Met |
| small-bursty | Mutable prototype | Met | Missed | Missed | Met |
| small-mixed | Reference | Missed | Missed | Missed | Met |
| small-mixed | Mutable prototype | Missed | Missed | Missed | Met |

The reference's verdicts are identical in all three runs; the prototype's come
from run 3.

## The runs

All runs were taken on 2026-09-30 on the owner's machine: a Mac15,9 (Apple M3
Max) with macOS 26.7.1, GHC 9.14.1 and clang 21.0.0. The reports are retained
unedited.

| Run | Report | What it measured | Conditions |
| --- | --- | --- | --- |
| 1 | [run-1](gpu_allocator_parity/run-1-2026-09-30.md) | The reference against VMA default, per-operation timing only | No source digest or load recorded; the probe's first version |
| 2 | [run-2](gpu_allocator_parity/run-2-2026-09-30.md), [with `-A1g`](gpu_allocator_parity/run-2-2026-09-30-A1g.md) | Adds VMA MIN_MEMORY, batched throughput windows, allocation, collection and heap figures, the search reconstruction, fragmentation samples and the diagnostic traces | Source digest `c1e647b0…`; load not recorded, though a later-started game shows it began after this run, and its figures match run 1's within a few percent |
| 3 | [run-3](gpu_allocator_parity/run-3-2026-09-30.md), [with `-A1g`](gpu_allocator_parity/run-3-2026-09-30-A1g.md) | Adds the mutable prototype, gated beside the reference | Source digest `6c246b9a…`; load average 4.4–5.1 on 16 cores. Its reference and VMA figures reproduce run 2's within 2–5% per operation |

Not retained: short correctness trials run with two repetitions, and one taken
under a load average of about 25. They checked the self-checks only, and their
timings were never results. The first prototype, with sorted lists in its size
bins instead of treaps, never had a measured run. Its trial showed bin walks of
up to 1,214 segments, which is why the bins became treaps.

The source digests identify the probe as it was when each run was taken. The
committed probe differs by its documentation and by the reference's move into
the `placement-reference` sublibrary, so it reproduces the method and the
decisions but not those digests. The traces are unchanged. Their SHA-256
digests are listed in the probe README and checked by the probe itself.

## Key figures

Per-operation medians, the gated method, from run 3 (run 1 for the reference
agrees within a few percent):

| Trace | Reference allocation | Prototype allocation | VMA default allocation | Prototype free | VMA default free |
| --- | ---: | ---: | ---: | ---: | ---: |
| synarchy-sheets | 106.2 ns (4.6×) | 50.0 ns (2.18×) | 23.0 ns | 33.3 ns (2.01×) | 16.6 ns |
| small-steady | 485.4 ns (13.7×) | 139.7 ns (3.94×) | 35.5 ns | 58.4 ns (2.00×) | 29.2 ns |
| small-bursty | 456.4 ns (14.6×) | 133.3 ns (4.27×) | 31.2 ns | 89.6 ns (3.06×) | 29.3 ns |
| small-mixed | 527.1 ns (15.8×) | 145.8 ns (4.37×) | 33.4 ns | 60.4 ns (2.23×) | 27.0 ns |

Bytes allocated per executed operation (Haskell runtime): the reference
790–2,876; the prototype 218–437. Garbage collection took up to 29% of the
reference's windowed time and at most 0.4% of the prototype's.

## What we learned

- **Search was never the cost.** Best fit examined a median of one free range
  per placement, with a 95th percentile of one to six, on every trace. That
  includes 10,000 live buffers in a near-full block.
- **Persistent copying was.** The reference allocated 0.8–2.9 KB per
  operation to copy tree paths through its ordered maps. Its cost grew with
  the number of live placements, which sets tree depth, not with the length
  of the free list.
- **Collection was secondary.** A 1 GiB nursery removed collection from the
  measured windows but left the reference at 14–21× VMA's throughput on the
  small-buffer traces.
- **Timer and call overhead favoured Haskell.** An empty timed interval costs
  about 9 ns on the Haskell side and 10 ns in the shim. Subtracting it widened
  every ratio, and batched throughput, with one clock pair per 256 operations,
  agreed.
- **The mutable prototype removed most of the gap but not enough.** It was
  2.1–4.6× faster than the reference, and still 2.0–4.4× VMA per operation.
  The remaining cost is the treap rotations that exact (size, offset) order
  requires, plus about 220–440 bytes of residual allocation per operation.
  VMA's size classes do not keep that order.
- **Two gates cannot move with speed.** The prototype makes the reference's
  decisions, so it shares the reference's fragmentation and refusals.
  - Once two allocators place anything differently, their layouts diverge,
    and per-checkpoint fragmentation swings 15–27 points either way. VMA's own
    two strategies are 7.5 points apart at one `small-steady` checkpoint, so
    VMA would fail the two-sided per-checkpoint gate against itself.
  - `small-mixed`'s refused-bytes miss is a policy difference against VMA's
    default search. Against MIN_MEMORY, best fit is within about half a point.
- **Placement quality was not the problem.** Best fit refused fewer bytes than
  VMA default on three of the four traces (0.91% against 4.99% on the
  Synarchy sheets), and it matched VMA MIN_MEMORY within about half a point
  on all four.

## Why VMA

Performance is the priority. The owned allocator was conditional on parity
(D-4), and it did not reach parity. The owner declined further optimisation
of the owned allocator, which could at best have closed the speed gate on the
sheets alone, and chose VMA for production allocation (D-38).

## What this evidence does not show

The probe compares placement inside VMA's *virtual* blocks, which allocate no
device memory and are called from C with no Haskell crossing per operation.
It says nothing about:

- VMA's real allocator on a device;
- the cost of calling VMA through the Haskell binding;
- memory-type selection, mapping or dedicated allocations;
- the completion-deferred free path the engine needs.

Those are what the bounded validation of the VMA integration (GRS-18 in the
design) establishes; its runs are in
[the VMA qualification record](gpu_vma_qualification_record.md).

## Reproducing

The probe's default is now GRS-18's measurement, so this comparison takes
`--virtual-block-parity`:

```bash
bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe -- --virtual-block-parity --output FILE
bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe -- --virtual-block-parity --output FILE +RTS -A1g -RTS
```

Runs 1 to 3 used the non-threaded runtime; the suite is now linked threaded
for GRS-18, which this comparison's pure Haskell and unsafe calls do not
depend on, so a new run is comparable but not identical.

Take timings only on a quiet machine. Each report records the load average at
its start. The probe is local apparatus outside routine automation, not a
validation group ([test classification](test_classification.md)).
