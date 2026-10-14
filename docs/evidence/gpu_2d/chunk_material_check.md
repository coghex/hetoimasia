# GUIDE-3 evidence: the material check of retained chunks (#449)

Measured evidence for the performance claim of #449, which the issue labels an
estimate: a successful `unissuedMaterial` check (run for every frame recorded and
every publication) costs work proportional to the chunks a layer lists times their
distinct materials, not to the instances the chunks retain.

## What was measured

One call of `unissuedMaterial` on a prebuilt, fully evaluated valid snapshot: one
UI layer listing four chunks, each of `instances / 4` instances over the same eight
materials, every one issued, and no dynamic instance. Chunk count (4), distinct
materials (8) and the issued registry (a prebuilt `Map` of eight entries, looked up
by identity as `issuedMaterials` does) are held fixed; only the retained instance
count varies. Chunk and snapshot construction and validation, and one warming call,
are outside the measured region. The issued lookup closes over the loop index so the
call cannot be shared between iterations. Each figure is the mean over the
iterations of the bytes the RTS reports allocated (`allocated_bytes`, after a major
collection) and of process CPU time.

| Retained instances | Before: allocated per call | Before: CPU per call | After: allocated per call | After: CPU per call |
| ---: | ---: | ---: | ---: | ---: |
| 1,024 | 125,374 bytes | 24 µs | 1,464 bytes | 1 µs |
| 16,384 | 2,214,357 bytes | 305 µs | 1,459 bytes | 1 µs |
| 262,144 | 35,637,985 bytes | 4,714 µs | 1,459 bytes | 1 µs |

*Before* is `master` at `11677900` (200 iterations per row); *after* is the pull
request's head with the check by material set (20,000 iterations per row). The
before cost grows with the instance count (about 18 ns and 136 bytes per instance
at 262,144); the after cost does not. For the issue's 512 × 512 tile map
(262,144 retained instances) the check is about 4.7 ms before and under 2 µs after,
for the recording and again for the publication of each frame.

The figures are one run on one machine, a shape and not a threshold: no timing
threshold is a routine test. The routine proof is that the check's answer is the
full scan's for every generated snapshot (`Test.Render.TwoD.Vulkan.MaterialSet`).

## Machine and command

macOS 26.7.1, Apple M3 Max, GHC 9.14.1, `-O2`. A temporary example, below, was added
to `Test.Render.TwoD.Vulkan.MaterialSet` (not kept, since it asserts nothing) and run
with

```text
PROBE_ITERS=<iterations> bash tools/vulkan/run.sh test \
  hetoimasia-render-2d-vulkan:test:render-2d-vulkan-tests -- --match PROBE +RTS -T -RTS
```

once on `master` (200 iterations) and once on the change (20,000). The example uses
that module's `sessionOf`, `chunkOf`, `sprite`, `snapshotOf` and `reference`, and
imports `evaluate`, `forM_`, `when`, `RTSStats (..)`, `getRTSStats`,
`getRTSStatsEnabled`, `getCPUTime`, `lookupEnv` and `performMajorGC`.

```haskell
probeSpec ∷ Spec
probeSpec = it "PROBE" $ do
  enabled ← lookupEnv "PROBE_ITERS"
  when (enabled /= Nothing) $ do
    let iters = maybe 10 read enabled ∷ Int
    stats ← getRTSStatsEnabled
    when (not stats) (putStrLn "PROBE: run with +RTS -T")
    let materials = [reference identity True | identity ← [1 .. 8]]
        issuedAll = sessionOf [(identity, Just True) | identity ← [1 .. 8]]
    forM_ [1024, 16384, 262144 ∷ Int] $ \n → do
      let per = n `div` 4
          chunks = [chunkOf [sprite (materials !! (k `mod` 8)) (fromIntegral (k `mod` 16)) | k ← [1 .. per]] | _ ← [1 .. 4 ∷ Int]]
          snapshot = snapshotOf chunks [[([0, 1, 2, 3], [])]]
      _ ← evaluate (sum [length (chunkInstances c) + Set.size (chunkMaterials c) | c ← chunks])
      _ ← evaluate (length (concatMap validLayerChunks (validLayers snapshot)))
      _ ← evaluate (unissuedMaterial issuedAll snapshot)
      performMajorGC
      s0 ← getRTSStats
      t0 ← getCPUTime
      forM_ [1 .. iters] $ \k → evaluate (unissuedMaterial (\identity → if k < 0 then Nothing else issuedAll identity) snapshot)
      t1 ← getCPUTime
      s1 ← getRTSStats
      let bytes = fromIntegral (allocated_bytes s1 - allocated_bytes s0) / fromIntegral iters ∷ Double
          micros = fromIntegral (t1 - t0) / 1.0e6 / fromIntegral iters ∷ Double
      putStrLn ("PROBE instances=" <> show n <> " chunks=4 distinct=8 iters=" <> show iters <> " alloc_bytes_per_call=" <> show (round bytes ∷ Integer) <> " cpu_us_per_call=" <> show (round micros ∷ Integer))
```
