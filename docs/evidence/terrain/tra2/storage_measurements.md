# TRA-2 storage evidence: payload, metadata, allocation and operation costs

Evidence for issue #638 (TRA-2 of epic #636): the layered source, packed sparse
resident detail and retained removals in `hetoimasia-terrain`. This document
records what was measured and how to reproduce it. It is evidence, not a
contract; the contract is `packages/terrain/README.md`.

These are CPU data-structure measurements. They are not evidence of renderer
correctness, live concurrent offload or process memory, and they carry no
speedup claim, no universal compression ratio and no wall-clock threshold. One
run on one machine.

## Reproduce

From the implementation checkout, with the qualified toolchain (GHC 9.14.1,
Cabal 3.18.1.0) on `PATH`:

```sh
cabal bench --project-file cabal.project.cpu hetoimasia-terrain:terrain-measure
```

`terrain-measure` is a benchmark component of the terrain package, outside every
required validation group, built with `-fno-full-laziness` (so the timed updates
are not hoisted out of their loops) and `-with-rtsopts=-T` (so `GHC.Stats` is
available). The deterministic structural and allocation-growth checks that *are*
required run in the routine suite (`Test.Terrain.Resident`, `Test.Terrain.Growth`).
quruntul's `$profile` / `$performance` were not used; this command is the
reproduction.

Run recorded here: commit `14268656774d90792291d2447d0ad0f6ca2c885e` of branch
`issue-638-terrain-sources-changes`, Apple M3 Max (arm64), macOS, GHC 9.14.1,
`-O2`.

## What each column means

- *payload B*: `sum segmentPayloadBytes`, the encoded values only (2 bytes
  uniform, `4R` runs, `2N` dense).
- *metadata B (accounted)*: 32 bytes per segment plus 48 per column index entry,
  a conservative accounting figure and not a heap measurement.
- *source B (accounted)*: the definition's conservative accounted bytes (64 header,
  16 + id per material, 24 per layer, 40 per patch).
- *retained heap B*: the change in `gcdetails_live_bytes` across major
  collections with the resident detail held. It includes object headers, the
  unboxed-array wrappers and the `Data.Map` indexes, so it is reported beside the
  payload and not derived from it.
- *allocated building B*: `allocated_bytes` across building the detail (read after
  the collection).
- Operation costs are nanoseconds per operation over a fixed number of
  repetitions; the checksum keeps the work live.

Fixtures (a 16 x 16 block of columns, 256 columns): *flat* is stone under soil;
*layered* is stone under four alternating 10-level strata; *hollow* is rock with
a cavity patch in every column; *fragmented* alternates two materials every level
over 128 levels. *top-only* demands one surface cell per column; *full-128*
demands levels `[-64, 64)` of every column (four 32-level regions each).

## Raw results

```text
terrain-measure: payload, metadata, heap and operation costs (one run, one machine)
columns: fixture | demand | segments | known cells | uniform/runs/dense | payload B | metadata B (accounted) | source B (accounted) | retained heap B | allocated building B
flat | top-only | 256 | 256 | 256/0/0 | 512 | 20480 | 153 | 111136 | 870056
flat | full-128 | 1024 | 32768 | 512/512/0 | 5120 | 45056 | 153 | 197208 | 12491664
flat | lookup coherent | 81 ns/op | checksum 31500000
flat | lookup scattered | 108 ns/op | checksum 31499984
flat | bulk scan 128 levels | 365 ns/column | checksum 300000
flat | remove + refresh one cell | 23042 ns/op | checksum 1638400000
layered | top-only | 256 | 256 | 256/0/0 | 512 | 20480 | 239 | 50280 | 765352
layered | full-128 | 1024 | 32768 | 512/512/0 | 7168 | 45056 | 239 | 170280 | 13098712
layered | lookup coherent | 77 ns/op | checksum 33000000
layered | lookup scattered | 107 ns/op | checksum 32999936
layered | bulk scan 128 levels | 669 ns/column | checksum 600000
layered | remove + refresh one cell | 23173 ns/op | checksum 1638400000
hollow | top-only | 256 | 256 | 256/0/0 | 512 | 20480 | 10348 | 94552 | 1057952
hollow | full-128 | 1024 | 32768 | 768/256/0 | 4608 | 45056 | 10348 | 153744 | 12468984
hollow | lookup coherent | 76 ns/op | checksum 13000000
hollow | lookup scattered | 104 ns/op | checksum 12999968
hollow | bulk scan 128 levels | 501 ns/column | checksum 400000
hollow | remove + refresh one cell | 22473 ns/op | checksum 1638400000
fragmented | top-only | 256 | 256 | 256/0/0 | 512 | 20480 | 3170 | 69824 | 930696
fragmented | full-128 | 1024 | 32768 | 0/0/1024 | 65536 | 45056 | 3170 | 257144 | 51539536
fragmented | lookup coherent | 74 ns/op | checksum 48000000
fragmented | lookup scattered | 104 ns/op | checksum 48000032
fragmented | bulk scan 128 levels | 14506 ns/column | checksum 12800000
fragmented | remove + refresh one cell | 26946 ns/op | checksum 1638400000
segment | uniform -> runs (1 cell) | 1831 ns/op | checksum 2350000
segment | runs -> dense (16 cells) | 4343 ns/op | checksum 12800000
segment | dense -> uniform (16 cells) | 3802 ns/op | checksum 400000
segment encodings reached: Runs Dense Uniform
```

## Reading the results

- **Payload.** A top-only demand holds 256 one-cell segments at 2 bytes each (512
  bytes) for every fixture, however the source is layered: unrequested depth has
  no resident value payload. A full 128-level demand of the flat fixture is 512
  uniform segments (2 bytes) and 512 two-run segments (8 bytes): 5,120 bytes for
  32,768 known cells. Hollow is 4,608 bytes (768 uniform segments at 2 bytes and 256
  three-run segments at 12 bytes). The fragmented fixture alternates
  every level, so all 1,024 segments are dense at 64 bytes: 65,536 bytes, the
  intended case where runs stop saving space.
- **Metadata and heap are separate from payload.** Accounted metadata (20,480 B
  for 256 segments; 45,056 B for 1,024 segments plus 256 column entries) is larger
  than the payload in the compressible fixtures, and the retained heap
  (about 111 KB to 257 KB) is larger again because of object headers and indexing
  maps. The design's 2N/4R/2-byte arithmetic describes value payload only, not
  Haskell heap or RSS, and these figures confirm the distinction is material at
  these sizes.
- **Source cost.** The hollow fixture's 256 patches make its accounted definition
  10,348 bytes against 153 for the flat one; the source is independent of how
  much is resident.
- **Lookup.** Direct and binary-search lookups are tens to ~100 ns per operation,
  coherent consistently faster than scattered in this run; the fixtures'
  encodings differ little here, since a lookup is dominated by the column and
  segment index descent.
- **Bulk scan.** The 128-level range of one column costs about 0.4 to 0.7 microseconds
  for the layered sources and about 14.5 microseconds for the fragmented one: cost
  follows the number of runs returned, not the levels.
- **Edit.** Removing a cell and refreshing its segment costs about 22 to 27
  microseconds; it is the cost of the removal plus re-deriving one segment (at
  most 32 values) from source and changes, and the work is bounded by the segment,
  not by depth.
- **Transitions.** Updating a 32-cell segment from uniform to runs, runs to dense
  and dense back to uniform costs about 1.8, 4.3 and 3.8 microseconds; the new
  encoding is chosen once from at most 32 values.

## Growth with depth and gap width

Proved in the routine suite, not here: `Test.Terrain.Growth` measures `GHC.Stats`
allocation at two widely separated scales and requires them to agree within a
constant factor and a budget no per-level traversal could meet: a deep cell
(`-2^62 + 10` against `-10`), a deep 4,096-level range, an air gap of `2^20`
against `2^60` levels, a removed interval of `2^20` against `2^60` levels, a
one-cell materialization at `-2^62 + 7` and `2^60` against `-2`, and four widely
separated segments against four near ones. `Test.Terrain.Resident` asserts the
structural counts (one segment and one known cell for a top-only or deep request,
no cell between separated segments).

Negative controls for these checks (a bounded highest-search step, a
whole-region materialization) fail the examples named in the pull request.
