# VMA qualification record

The retained evidence of #361 (GRS-18): the production VMA integration
measured on a real device against the owner's accepted limits, under design
decisions D-16, D-38, D-39 and D-40 of the
[GPU resource services design](designs/gpu_resource_services_design.md).

## Verdict

**Recommended for Q-19: an engine-owned C shim over the pinned VMA, imported
with unsafe calls, with D-40's device-memory callbacks counting in C. That
configuration met every accepted limit in both runs, so it qualifies for #333
(GRS-11).**

- The Hackage `VulkanMemoryAllocator` binding does not qualify in either
  variant. With its default unsafe calls it missed 5 of 15 timed limits; with
  `safe-foreign-calls` it missed 13 of 15, with either callback destination.
- Safe calls do not qualify through either binding: the engine shim with safe
  imports missed 11 of 15 limits, with C or Haskell callbacks.
- D-40's callbacks therefore run in C. No unsafe call may reach a Haskell
  callback, and only safe calls, which miss, could allow one.
- Every configuration met the completion-deferred free gate through its own
  API and callbacks: no free before its batch's fence signalled, and
  synchronization validation reported nothing.

The qualification is for the configuration measured: a shim whose Haskell
side marshals no struct and calls each entry directly. The probe's shim is
apparatus: one C entry per engine call, taking scalars and writing its
results into one reused record (`hetoimasia_shim_*` in
[the probe's C file](../packages/gpu-vulkan/native/probe/allocator-parity/cbits/vma_production.cpp)).
GRS-11's production shim keeps this qualification only if it keeps that
shape. D-38 leaves making VMA a production native input, and its
`docs/toolchain.md` record, to GRS-11. That includes obtaining
`vk_mem_alloc.h`, which the Hackage package bundles but does not install.

## The runs

Both runs come from commit `e0846a2`, source digest
`bcd85bd2dd21b25460d58e27d5eee68df97579b09ba0d7a7cf73b5097818873e`, with
3 warm-up and 20 measured repetitions, on 2026-10-01:

| Run | Binding variant | Load average (1, 5, 15 min) | Report |
| --- | --- | --- | --- |
| 1, unsafe | default unsafe calls, what the unmodified tracked tree builds | 2.79 3.48 3.73 | [run-1-2026-10-01-unsafe.md](gpu_vma_qualification/run-1-2026-10-01-unsafe.md) |
| 1, safe | `safe-foreign-calls` | 2.96 3.39 3.68 | [run-1-2026-10-01-safe.md](gpu_vma_qualification/run-1-2026-10-01-safe.md) |

- **Machine:** Mac15,9, Apple M3 Max, 64 GiB, macOS 26.7.1 (Darwin 25.6.0
  arm64), on AC power.
- **Device:** Apple M3 Max through MoltenVK 1.4.2, device API 1.3.357, loader
  1.3.296, `VK_KHR_portability_subset`. Memory: one 64 GiB device-local heap.
  Type 0 is `DEVICE_LOCAL`, type 1 is `DEVICE_LOCAL | HOST_VISIBLE |
  HOST_COHERENT | HOST_CACHED`, and type 2 is lazily allocated. VMA's
  preferred block size is 256 MiB for every type.
- **VMA:** Hackage `VulkanMemoryAllocator-0.11.1.0`, bundling VMA 3.3.0. The
  Cabal store built it with `+vma-ndebug` (assertions compiled out) at its
  default optimisation. The C driver and the shim call that same compiled VMA.
- **Toolchain:** GHC 9.14.1 with the threaded runtime on one capability.
  Clang 21.0.0 compiled the C driver with `-std=c++17 -O2`.
- **Validation:** timings on a device with no layer; correctness on a second
  device with `VK_LAYER_KHRONOS_validation` 1.3.296 and synchronization
  validation, through a C messenger. Neither run reported a message.

Each report states the full configuration of every result: the per-class
memory requirements and chosen memory types, the trace-to-resource mapping,
and the timing protocol. The probe's
[README](../packages/gpu-vulkan/native/probe/allocator-parity/README.md)
states the protocol in full.

The machine was not quiet: other work held the load average near 3 to 3.7 on
this 16-core machine. Both drivers in a run share that load, interleaved
within every repetition. The recommended configuration's margins below are
wide, and the two runs agree to within a few nanoseconds per call.

## The accepted limits, by configuration

Limits met of the 16 (11 binding-path calls, 4 traces, and the
deferred-free gate), with the Haskell side measured against the C driver of
the same run:

| Configuration | Run 1, unsafe | Run 1, safe | Qualifies |
| --- | ---: | ---: | --- |
| Hackage binding, its build's calls, C callbacks | 11 of 16 | 3 of 16 | no |
| Hackage binding, safe calls, Haskell callbacks | — | 3 of 16 | no |
| **Engine shim, unsafe calls, C callbacks** | **16 of 16** | **16 of 16** | **yes** |
| Engine shim, safe calls, C callbacks | 5 of 16 | 5 of 16 | no |
| Engine shim, safe calls, Haskell callbacks | 5 of 16 | 5 of 16 | no |

### The recommended configuration

Binding-path overhead is the Haskell median minus the C median, each less its
side's empty timed interval. The allowance is the larger of 25% of the C median
or 50 ns:

| Call | Run 1, unsafe: C / overhead | Run 1, safe: C / overhead | Allowance |
| --- | --- | --- | ---: |
| create buffer, one allocating call | 87.6 / 24.2 ns | 85.6 / 22.2 ns | 50 ns |
| create image, one allocating call | 1829.3 / 38.8 ns | 1858.5 / 22.0 ns | 457–465 ns |
| free buffer | 185.4 / 1.4 ns | 187.8 / 9.4 ns | 50 ns |
| free image | 141.7 / 1.5 ns | 152.1 / 1.6 ns | 50 ns |
| map | 0.2 / 7.6 ns | 0.2 / 7.6 ns | 50 ns |
| unmap | 0.1 / 5.5 ns | 0.2 / 5.5 ns | 50 ns |
| flush | 0.1 / 5.6 ns | 0.2 / 5.5 ns | 50 ns |
| invalidate | 0.1 / 5.4 ns | 0.1 / 5.4 ns | 50 ns |
| D-40: `NEVER_ALLOCATE` placed in held memory | 70.8 / 18.1 ns | 73.0 / 13.9 ns | 50 ns |
| D-40: failed attempt, then a block opened | 10729.3 / 586.6 ns | 11525.2 / −419.5 ns | 2.7–2.9 µs |
| D-40: failed attempt, then a dedicated allocation | 7491.7 / 207.8 ns | 7843.9 / −42.4 ns | 1.9–2.0 µs |

| Trace | Run 1, unsafe: Haskell ÷ C | Run 1, safe: Haskell ÷ C | Limit |
| --- | ---: | ---: | ---: |
| synarchy-sheets | 1.020× | 1.016× | 1.25× |
| small-steady | 1.118× | 1.124× | 1.25× |
| small-bursty | 1.045× | 1.058× | 1.25× |
| small-mixed | 1.109× | 1.119× | 1.25× |

Map, unmap, flush and invalidate do almost no work in C: the staging
allocation is persistently mapped, and its memory type is coherent, so VMA's
flush and invalidate return at once. Their medians sit below the clock's
41.7 ns tick and are resolved only by averaging over the repetitions.

### Why the others miss

- **The Hackage binding's wrappers.** Unsafe calls themselves are cheap, but
  each creation marshals its create infos in `ContT`, allocates and frees two
  output cells under `bracket`, and reads back an `AllocationInfo`. That adds
  about 230 ns to a 70–88 ns call: create buffer 236.8 ns over C, a
  `NEVER_ALLOCATE` placement 230.8 ns over. A refused `NEVER_ALLOCATE` arrives
  as a thrown `VulkanException`, so the failed attempt costs about five times
  its C cost. On the small-buffer traces, where nearly every allocation is a
  cheap placement, the binding took 1.31–1.73× C's time. On `synarchy-sheets`, where
  each image creation costs about 1.9 µs in C, it stayed within the limit.
- **Safe calls.** A safe call releases and reacquires the capability, about
  110–160 ns per call whatever the binding. That alone exceeds the 50 ns
  floor on every cheap call. Through the Hackage binding, safe calls add to
  the wrappers' cost: 424 ns on create buffer, and 1.30–2.67× C's time on
  every trace.
- **Callbacks into Haskell.** They need safe calls, so they inherit those
  calls' misses; that, not their own cost, rules them out. Callbacks fire only
  when VMA opens or frees device memory, calls that take about 5 to 14 µs. On those
  calls, Haskell callbacks measured between 448 ns faster and 929 ns slower
  than C callbacks across the two runs and both safe drivers. With 16 or 17
  such calls in the script, that difference is within the calls' own spread.

## D-40's accounting

On every run, configuration and device, D-40's mechanism held:

- A `NEVER_ALLOCATE` attempt never opened device memory.
- No allocating call opened more than the larger of its memory type's
  preferred block size and the allocation's size.
- The callbacks' held bytes equalled VMA's own statistics at every checkpoint
  and at the end.
- Nothing was held once the allocator was destroyed.

The block events the callbacks recorded, identical for every driver:

| Workload | Device-memory objects opened | Freed during the trace | Peak held | Retained once all freed |
| --- | --- | ---: | ---: | ---: |
| synarchy-sheets | 61: 1 × 32 MiB, 1 × 64 MiB, 1 × 128 MiB, 58 × 256 MiB | 58 | 480 MiB | 32 MiB |
| small-steady | 2 × 32 MiB | 0 | 64 MiB | 64 MiB |
| small-bursty | 4: 2 × 32 MiB, 2 × 64 MiB | 2 | 128 MiB | 64 MiB |
| small-mixed | 12: 2 × 32 MiB, 10 × 64 MiB | 8 | 192 MiB | 64 MiB |

VMA starts each memory type at an eighth of its preferred block and doubles
from there. Under the sheets' streaming churn, it opened and freed a 256 MiB
block 58 times over 2,734 allocations, while live requested bytes peaked at
266 MiB. The engine's budget sees each of those blocks as D-40 charges them.
Device bytes held, live allocated bytes (the device's memory requirements) and
live requested bytes are reported separately at every checkpoint. For buffers
on this device the requirements equal the requests, at 256-byte alignment.
For sheets they exceed them by under 1%, at 128-byte alignment.

## Completion-deferred frees

`small-steady` replayed once per Haskell configuration, through that
configuration's own API and callbacks. The GPU executed 313 batches of 64
operations, three in flight. Each free waited for the fence of the batch that
last used its resource; peak 129 frees waited at once, 93.6 per batch on
average. In every configuration of both runs, neither the 20 timed passes nor
the validated pass freed anything early, and synchronization validation
reported nothing.

A destroy the GPU has used costs more on MoltenVK than one it has not. For the
recommended configuration, the median deferred `vmaDestroyBuffer` took 919 ns
against 256 ns for the same trace's immediate frees in its plain replay
(run 1, unsafe). Its frees took 9.5 ms in total against 2.5 ms, and draining
them, bookkeeping included, took 12.1 ms. Across every configuration and both
runs, a deferred free cost 658–742 ns more than an immediate one. The owner set
no numeric limit on this comparison; each report gives the deferred workload's
other costs: allocation, recording and submission, and fence waits.

## Reproducing

```bash
bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe -- --output FILE --warmup 3 --repetitions 20
HETOIMASIA_VMA_FOREIGN_CALLS=safe bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe -- --output FILE --warmup 3 --repetitions 20
```

The first command builds the variant the unmodified tracked tree builds: the
binding's default unsafe calls. The second builds `safe-foreign-calls` into its
own directory, with every other input identical, and the probe confirms the
variant by behaviour. Each run takes about a minute after its build and opens
no window.

The exit status is 0 when every Haskell configuration meets every limit, 1
when one misses, and 2 when the run is invalid or incomplete. Both retained
runs exit 1, because configurations other than the recommended one miss. A run
is evidence only if its self-checks pass, as both of these did. Take timings
on a quiet machine; each report records its load average.

## What this evidence does not show

- One machine and one driver: Apple silicon through MoltenVK on macOS. No
  Linux or discrete-GPU device was measured.
- The shim is the probe's apparatus. GRS-11's production shim, its build and
  its toolchain record are not measured here.
- The traces' churn is assumed, as #331's record states. The sheet and buffer
  descriptors follow the deterministic mapping in each report, not observed
  engine traffic.
