{-# LANGUAGE CPP #-}

-- | GRS-18 (#361, D-39): the production VMA integration measured on a real
-- device, and judged against the owner's accepted limits.
--
-- One run measures one build of the Hackage binding — its default unsafe
-- calls or its @safe-foreign-calls@ variant, which @tools/vulkan/run.sh@
-- selects — and every configuration that build can run:
--
-- * the C driver with C callbacks, the baseline;
-- * the binding from Haskell with C callbacks;
-- * with safe calls only, the binding from Haskell with Haskell callbacks.
--
-- It times the per-call script and the four gated traces on a device with no
-- layer, then repeats every evidence pass and the deferred-free workload on a
-- device with the validation layer and synchronization validation, where any
-- message makes the run invalid. README.md states the protocol.
module Production
  ( ProductionOptions (..)
  , runProduction
  ) where

import Control.Concurrent (getNumCapabilities, rtsSupportsBoundThreads)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM, forM_, replicateM_, unless, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (intercalate, nub, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Vector as Vector
import qualified Data.Vector.Storable as Storable
import qualified Data.Vector.Storable.Mutable as StorableMutable
import qualified Data.Vector.Unboxed as Unboxed
import Data.Version (showVersion)
import Data.Word (Word32, Word64)
import Numeric (showHex)
import Parity.Report (fixed, nearestRank)
import Parity.Trace (Trace (..), readTrace)
import Parity.Vma (clockPairNanoseconds, probeCompiler)
import Production.Deferred
import Production.Device
import Production.Driver
import Production.Script
import System.Directory (doesDirectoryExist, listDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hFlush, hPutStrLn, stderr)
import System.Info (arch, fullCompilerVersion, os)
import System.Mem (performMajorGC)
import System.Process (readProcess)

-- | The upstream VMA the pinned Hackage package bundles (its changelog).
bundledVma ∷ String
bundledVma = "3.3.0"

data ProductionOptions = ProductionOptions
  { productionTraces ∷ !FilePath
  , productionOutput ∷ !(Maybe FilePath)
  , productionWarmup ∷ !Int
  , productionRepetitions ∷ !Int
  , productionArguments ∷ ![String]
  , productionDigest ∷ !(String, [String])
  , productionTraceDigests ∷ !(Map.Map String String)
  }

-- | The owner's accepted limits (#361).
bindingAllowanceFraction, bindingAllowanceFloor, throughputLimit ∷ Double
bindingAllowanceFraction = 0.25
bindingAllowanceFloor = 50
throughputLimit = 1.25

progress ∷ String → IO ()
progress message = hPutStrLn stderr ("vma qualification: " <> message) >> hFlush stderr

-- ---------------------------------------------------------------------------
-- Measuring a script

-- | Everything measured for one script.
data Measurement = Measurement
  { measurementScript ∷ !Script
  , measurementEvidence ∷ !(Map.Map Configuration PassResult)
  , measurementPerOperation ∷ !(Map.Map Configuration (Unboxed.Vector Double, Unboxed.Vector Double))
    -- ^ Each operation's mean nanoseconds over the repetitions, and its
    -- allocating call's alone.
  , measurementWhole ∷ !(Map.Map Configuration [Word64])
    -- ^ Each repetition's whole-script nanoseconds.
  }

-- | Rotate the configurations' order by the repetition, so drift and any
-- order effect reach every configuration alike.
rotated ∷ Int → [a] → [a]
rotated k xs = let n = length xs in if n == 0 then xs else take n (drop (k `mod` n) (cycle xs))

-- | The work a pass did, which every timed pass must repeat exactly.
workOf ∷ PassResult → [Word64]
workOf pass =
  map (summaryWord pass) [SummaryChecksum, SummaryCreates, SummaryDestroys, SummaryHits, SummaryMisses, SummaryOther, SummaryBoundBroken, SummaryFailures]

measureScript ∷ Session → IORef [String] → [Configuration] → Int → Int → Script → IO Measurement
measureScript session failures configurations warmup repetitions script = do
  let count = Unboxed.length (scriptKinds script)
      failed problem = modifyIORef' failures ((scriptName script <> ": " <> problem) :)
  evidence ← fmap Map.fromList $ forM configurations $ \c → do
    performMajorGC
    (,) c <$> runPass session c script EvidenceMode
  checkEvidence failed (sessionDevice session) script evidence
  let reference = evidence Map.! Configuration DriverC CallbacksInC
      check c what pass =
        unless (workOf pass == workOf reference) $
          failed (configurationLabel UnsafeCalls c <> "'s " <> what <> " pass did different work from the evidence pass")
  replicateM_ warmup $ forM_ configurations $ \c → performMajorGC >> runPass session c script Whole
  perOperation ← forM configurations $ \c → do
    e ← StorableMutable.replicate (max 1 count) 0
    a ← StorableMutable.replicate (max 1 count) 0
    pure (c, (e, a))
  forM_ [0 .. repetitions - 1] $ \r → forM_ (rotated r perOperation) $ \(c, (e, a)) → do
    performMajorGC
    runPass session c script (PerOperation e a) >>= check c "per-operation"
  whole ← newIORef (Map.empty ∷ Map.Map Configuration [Word64])
  forM_ [0 .. repetitions - 1] $ \r → forM_ (rotated r configurations) $ \c → do
    performMajorGC
    pass ← runPass session c script Whole
    check c "whole-script" pass
    modifyIORef' whole (Map.insertWith (flip (<>)) c [summaryWord pass SummaryTimed])
  means ← forM perOperation $ \(c, (e, a)) → do
    let mean v = Unboxed.fromList . map (\x → fromIntegral x / fromIntegral repetitions) . Storable.toList . Storable.take count <$> Storable.freeze v
    (,) c <$> ((,) <$> mean e <*> mean a)
  wholes ← readIORef whole
  pure (Measurement script evidence (Map.fromList means) wholes)

-- | The evidence passes' own checks: every request placed, the callbacks'
-- accounting equal to VMA's own statistics, everything released with the
-- allocator, and every Haskell configuration's work identical to C's — the
-- same placements, outcomes and block events, operation by operation.
checkEvidence ∷ (String → IO ()) → Device → Script → Map.Map Configuration PassResult → IO ()
checkEvidence failed _ script evidence = do
  let reference = evidence Map.! Configuration DriverC CallbacksInC
      count = Unboxed.length (scriptKinds script)
      haskellWords pass = [w | i ← [0 .. count - 1], k ← [0 .. 4], let w = passEvidence pass Unboxed.! (i * evidenceWords + k)]
  forM_ (Map.toList evidence) $ \(c, pass) → do
    let label = configurationLabel UnsafeCalls c
    when (summaryWord pass SummaryFailures /= 0) $
      failed (label <> ": the device refused " <> show (summaryWord pass SummaryFailures) <> " requests")
    when (summaryWord pass SummaryHeldMismatches /= 0) $
      failed (label <> ": the callbacks' held bytes differed from VMA's statistics " <> show (summaryWord pass SummaryHeldMismatches) <> " times")
    when (countersHeld (passReleased pass) /= 0) $
      failed (label <> ": " <> show (countersHeld (passReleased pass)) <> " bytes were still held after the allocator was destroyed")
    when (countersEventsLost (passReleased pass) /= 0) $
      failed (label <> ": the block-event log overflowed")
    unless (workOf pass == workOf reference) $
      failed (label <> " did different work from the C driver: " <> show (workOf pass) <> " against " <> show (workOf reference))
    unless (haskellWords pass == haskellWords reference) $
      failed (label <> " placed some allocation differently from the C driver")
    unless (countersEvents (passReleased pass) == countersEvents (passReleased reference)) $
      failed (label <> "'s block events differ from the C driver's")
    unless (passCheckpoints pass == passCheckpoints reference) $
      failed (label <> "'s byte quantities at checkpoints differ from the C driver's")

-- ---------------------------------------------------------------------------
-- Populations

-- | A named set of operations of the per-call script, and the part of each
-- operation's time it takes.
data Part = WholeOperation | AttemptOnly | AllocatingOnly
  deriving (Eq, Show)

data Population = Population
  { populationName ∷ !String
  , populationGated ∷ !Bool
  , populationPart ∷ !Part
  , populationOperations ∷ ![Int]
  }

outcomeOf ∷ PassResult → Int → Word64
outcomeOf pass i = passEvidence pass Unboxed.! (i * evidenceWords)

callPopulations ∷ Measurement → [Population]
callPopulations measurement =
  [ Population "create buffer: `vmaCreateBuffer`, one allocating call (staging, 64 KiB)" True WholeOperation (ops CreatePlain (inIds 0 511))
  , Population "create image: `vmaCreateImage`, one allocating call (sheet, 256 × 256)" True WholeOperation (ops CreatePlain (inIds 512 1023))
  , Population "free buffer: `vmaDestroyBuffer` (staging)" True WholeOperation (ops Destroy (inIds 0 511))
  , Population "free image: `vmaDestroyImage` (sheet)" True WholeOperation (ops Destroy (inIds 512 1023))
  , Population "map: `vmaMapMemory` (persistently mapped staging)" True WholeOperation (ops Map (const True))
  , Population "unmap: `vmaUnmapMemory`" True WholeOperation (ops Unmap (const True))
  , Population "flush: `vmaFlushAllocation`, whole allocation" True WholeOperation (ops Flush (const True))
  , Population "invalidate: `vmaInvalidateAllocation`, whole allocation" True WholeOperation (ops Invalidate (const True))
  , Population "D-40 reuse: `NEVER_ALLOCATE` placed in held memory (geometry)" True WholeOperation hits
  , Population "D-40 failed reuse, then an allocating call that opens a block: both calls" True WholeOperation (misses (inIds 1536 1599))
  , Population "  — the failed `NEVER_ALLOCATE` attempt alone" False AttemptOnly (misses (inIds 1536 1599))
  , Population "  — the allocating call alone" False AllocatingOnly (misses (inIds 1536 1599))
  , Population "D-40 failed reuse, then a dedicated allocation (160 MiB): both calls" True WholeOperation (misses (inIds 1600 1615))
  , Population "  — the failed `NEVER_ALLOCATE` attempt alone" False AttemptOnly (misses (inIds 1600 1615))
  , Population "  — the allocating call alone" False AllocatingOnly (misses (inIds 1600 1615))
  , Population "free of a block-backed allocation that empties a block (64 MiB)" False WholeOperation (ops Destroy (inIds 1536 1599))
  , Population "free of a dedicated allocation (160 MiB)" False WholeOperation (ops Destroy (inIds 1600 1615))
  ]
  where
    script = measurementScript measurement
    reference = measurementEvidence measurement Map.! Configuration DriverC CallbacksInC
    count = Unboxed.length (scriptKinds script)
    inIds lo hi i = let identity = scriptIds script Unboxed.! i in identity >= lo && identity <= hi
    ops code keep = [i | i ← [0 .. count - 1], opCode (scriptKinds script Unboxed.! i) == code, keep i]
    hits = [i | i ← ops CreateD40 (const True), outcomeOf reference i `div` 2 `mod` 2 == 1]
    misses keep = [i | i ← ops CreateD40 keep, outcomeOf reference i `div` 4 `mod` 2 == 1]

-- | A population's per-operation samples in one configuration.
samplesOf ∷ Measurement → Configuration → Population → [Double]
samplesOf measurement c population =
  let (totals, allocating) = measurementPerOperation measurement Map.! c
   in [ case populationPart population of
          WholeOperation → totals Unboxed.! i
          AllocatingOnly → allocating Unboxed.! i
          AttemptOnly → totals Unboxed.! i - allocating Unboxed.! i
      | i ← populationOperations population
      ]

-- ---------------------------------------------------------------------------
-- Limits

data Verdict = Verdict
  { verdictLimit ∷ !String
  , verdictConfiguration ∷ !Configuration
  , verdictMet ∷ !Bool
  , verdictDetail ∷ !String
  }

-- | The binding-path limit for one gated call: Haskell median minus C
-- median, each with its own empty timed interval subtracted, no greater than
-- the larger of 25% of the C median or 50 ns.
bindingVerdict ∷ (Double, Double) → Measurement → Configuration → Population → Verdict
bindingVerdict (haskellClock, cClock) measurement c population =
  let cMedian = nearestRank 0.5 (samplesOf measurement baseline population) - cClock
      hMedian = nearestRank 0.5 (samplesOf measurement c population) - haskellClock
      overhead = hMedian - cMedian
      allowance = max (bindingAllowanceFraction * cMedian) bindingAllowanceFloor
   in Verdict
        ("binding path: " <> populationName population)
        c
        (overhead <= allowance)
        ( "C " <> fixed 1 cMedian <> " ns, Haskell " <> fixed 1 hMedian <> " ns, overhead " <> fixed 1 overhead
            <> " ns against an allowance of " <> fixed 1 allowance <> " ns"
        )

baseline ∷ Configuration
baseline = Configuration DriverC CallbacksInC

medianWhole ∷ Measurement → Configuration → Double
medianWhole measurement c = nearestRank 0.5 (map fromIntegral (measurementWhole measurement Map.! c))

throughputVerdict ∷ Measurement → Configuration → Verdict
throughputVerdict measurement c =
  let cElapsed = medianWhole measurement baseline
      hElapsed = medianWhole measurement c
      ratio = hElapsed / cElapsed
   in Verdict
        ("workload throughput: " <> scriptName (measurementScript measurement))
        c
        (hElapsed <= throughputLimit * cElapsed)
        ( "C " <> milliseconds cElapsed <> ", Haskell " <> milliseconds hElapsed <> " (median elapsed over the repetitions); Haskell ÷ C = "
            <> fixed 3 ratio <> "×, limit " <> fixed 2 throughputLimit <> "×"
        )

milliseconds ∷ Double → String
milliseconds ns = fixed 3 (ns / 1e6) <> " ms"

-- ---------------------------------------------------------------------------
-- The run

runProduction ∷ ProductionOptions → IO ()
runProduction options = do
  failures ← newIORef []
  let failed problem = modifyIORef' failures (problem :)
  checkProductionLayouts
  capabilities ← getNumCapabilities
  unless rtsSupportsBoundThreads $ failed "the probe is not linked with the threaded runtime, which the engine uses"
  unless (capabilities == 1) $ failed ("the runtime has " <> show capabilities <> " capabilities; the call-safety check and the engine's owner thread assume one")
  implicitLayers ← fmap (filter (isJust . snd)) $ forM ["VK_INSTANCE_LAYERS", "VK_LOADER_LAYERS_ENABLE"] $ \v → (,) v <$> lookupEnv v
  unless (null implicitLayers) $
    failed ("layers are enabled through the environment (" <> intercalate ", " [v <> "=" <> fromMaybe "" x | (v, x) ← implicitLayers] <> "), so no timing would be layer-free")
  declaredVariant ← lookupEnv "HETOIMASIA_VMA_FOREIGN_CALLS"
  validationFeatures ← maybe [] (filter (not . null) . splitOn ',') <$> lookupEnv "HETOIMASIA_VULKAN_VALIDATION_FEATURES"
  unless ("synchronization" `elem` validationFeatures) $
    failed "HETOIMASIA_VULKAN_VALIDATION_FEATURES does not name synchronization, which requirement 5 needs; run through tools/vulkan/run.sh"
  traceFiles ← do
    exists ← doesDirectoryExist (productionTraces options)
    if exists then map (productionTraces options </>) . sort . filter (".trace" `isSuffixOfString`) <$> listDirectory (productionTraces options) else pure []
  traces ← forM traceFiles readTrace
  let gatedNames = Map.keys (productionTraceDigests options)
  forM_ gatedNames $ \name → case [t | t ← traces, traceName t == name] of
    [t] → unless (traceDigest t == productionTraceDigests options Map.! name) $ failed (name <> "'s digest differs from the retained trace's")
    _ → failed ("the gated trace " <> name <> " is missing from " <> productionTraces options)
  let gatedTraces = [t | t ← traces, traceName t `elem` gatedNames]
  clocks ← clockPairNanoseconds 1000000
  compiler ← probeCompiler
  machine ← describeMachine

  progress "timing on a device with no layer"
  timed ← try $ withDevice Unvalidated $ \device → withSession device $ \session → do
    classes ← resolveClasses device >>= either fail pure
    let geometry = classes Vector.! 1
        preferred = Storable.fromList [preferredBlockSize device (offerIndex o) | o ← deviceMemoryTypes device]
    safety ← detectCallSafety session geometry >>= either fail pure
    let configurations =
          [Configuration DriverC CallbacksInC, Configuration DriverHackage CallbacksInC]
            <> [Configuration DriverHackage CallbacksInHaskell | safety == SafeCalls]
            <> [ Configuration (DriverShim UnsafeCalls) CallbacksInC
               , Configuration (DriverShim SafeCalls) CallbacksInC
               , Configuration (DriverShim SafeCalls) CallbacksInHaskell
               ]
    callsScript ← encodeScript "per-call script" classes preferred callScript []
    progress "measuring the per-call script"
    calls ← measureScript session failures configurations (productionWarmup options) (productionRepetitions options) callsScript
    workloads ← forM gatedTraces $ \trace → do
      ops ← either fail pure (traceScript trace)
      script ← encodeScript (traceName trace) classes preferred ops (traceCheckpoints trace)
      progress ("replaying " <> traceName trace)
      (,) trace <$> measureScript session failures configurations (productionWarmup options) (productionRepetitions options) script
    deferred ← case [(t, m) | (t, m) ← workloads, traceName t == "small-steady"] of
      [(_, m)] → do
        progress "measuring completion-deferred frees on small-steady"
        replicateM_ (productionWarmup options) (performMajorGC >> runDeferred device classes (measurementScript m))
        runs ← forM [1 .. productionRepetitions options] $ \_ → performMajorGC >> runDeferred device classes (measurementScript m)
        pure (Just (m, runs))
      _ → failed "small-steady is missing, so the deferred-free workload did not run" >> pure Nothing
    pure (device, classes, safety, configurations, calls, workloads, deferred)
  -- The correctness passes on a validating device.
  progress "repeating every evidence pass and the deferred frees under validation"
  validated ← try $ withDevice (Validated validationFeatures) $ \device → withSession device $ \session → do
    classes ← resolveClasses device >>= either fail pure
    let preferred = Storable.fromList [preferredBlockSize device (offerIndex o) | o ← deviceMemoryTypes device]
    callsScript ← encodeScript "per-call script" classes preferred callScript []
    configurations ← case timed of
      Right (_, _, _, cs, _, _, _) → pure cs
      Left _ → pure [Configuration DriverC CallbacksInC, Configuration DriverHackage CallbacksInC]
    scripts ← (callsScript :) <$> forM gatedTraces (\trace → either fail pure (traceScript trace) >>= \ops → encodeScript (traceName trace) classes preferred ops (traceCheckpoints trace))
    forM_ scripts $ \script → do
      evidence ← fmap Map.fromList $ forM configurations $ \c → (,) c <$> runPass session c script EvidenceMode
      checkEvidence (\p → failed ("under validation, " <> scriptName script <> ": " <> p)) device script evidence
    deferredRun ← case [t | t ← gatedTraces, traceName t == "small-steady"] of
      [t] → do
        ops ← either fail pure (traceScript t)
        script ← encodeScript (traceName t) classes preferred ops (traceCheckpoints t)
        Just <$> runDeferred device classes script
      _ → pure Nothing
    pure (deviceLayers device, deferredRun)
  messages ← validationMessages
  problemsSoFar ← readIORef failures
  report ← case timed of
    Left (exception ∷ SomeException) → do
      failed ("the timed passes did not complete: " <> displayException exception)
      pure (Left (displayException exception))
    Right result → pure (Right result)
  case validated of
    Left (exception ∷ SomeException) → failed ("the validated passes did not complete: " <> displayException exception)
    Right (_, deferredValidated) → do
      when (messageErrors messages + messageWarnings messages + messageOther messages /= 0) $
        failed (show (messageErrors messages) <> " validation errors and " <> show (messageWarnings messages) <> " warnings were reported")
      forM_ deferredValidated $ \run → do
        unless (deferredEarly run == 0) $ failed (show (deferredEarly run) <> " frees ran before their batch's fence was observed signalled, under validation")
        unless (deferredFailures run == 0) $ failed (show (deferredFailures run) <> " deferred-free allocations were refused, under validation")
  case report of
    Right (_, _, _, _, _, _, Just (_, runs)) →
      forM_ runs $ \run → do
        unless (deferredEarly run == 0) $ failed (show (deferredEarly run) <> " frees ran before their batch's fence was observed signalled")
        unless (deferredFailures run == 0) $ failed (show (deferredFailures run) <> " deferred-free allocations were refused")
    _ → pure ()
  case (report, declaredVariant) of
    (Right (_, _, safety, _, _, _, _), Just declared)
      | declared /= variantName safety →
          failed ("run.sh declared the " <> declared <> " variant, but the binding behaves as " <> variantName safety)
    _ → pure ()
  _ ← pure problemsSoFar
  problems ← reverse <$> readIORef failures
  let verdicts = case report of
        Right (_, _, _, configurations, calls, workloads, _) →
          [ bindingVerdict clocks calls c p
          | c ← configurations
          , configurationDriver c /= DriverC
          , p ← callPopulations calls
          , populationGated p
          ]
            <> [throughputVerdict m c | c ← configurations, configurationDriver c /= DriverC, (_, m) ← workloads]
        Left _ → []
      invalid = not (null problems)
      allMet = all verdictMet verdicts
      text =
        unlines $
          header options machine compiler clocks declaredVariant validationFeatures report
            <> selfChecks problems
            <> limitsSection invalid report verdicts validated messages
            <> either (const []) (detailSections clocks) report
            <> validationSection validated messages
  putStr text
  forM_ (productionOutput options) (`writeFile` text)
  when invalid $ do
    hPutStrLn stderr "vma qualification: the run is invalid or incomplete; the figures are not evidence"
    exitWith (ExitFailure 2)
  unless allMet $ do
    hPutStrLn stderr "vma qualification: at least one accepted limit was missed"
    exitWith (ExitFailure 1)

variantName ∷ CallSafety → String
variantName SafeCalls = "safe"
variantName UnsafeCalls = "unsafe"

splitOn ∷ Char → String → [String]
splitOn c s = case break (== c) s of
  (a, []) → [a]
  (a, _ : rest) → a : splitOn c rest

isSuffixOfString ∷ String → String → Bool
isSuffixOfString suffix s = reverse suffix == take (length suffix) (reverse s)

describeMachine ∷ IO [String]
describeMachine = do
  model ← probe "sysctl" ["-n", "hw.model"]
  cpu ← probe "sysctl" ["-n", "machdep.cpu.brand_string"]
  memory ← probe "sysctl" ["-n", "hw.memsize"]
  system ← probe "uname" ["-srm"]
  osVersion ← probe "sw_vers" ["-productVersion"]
  power ← probe "pmset" ["-g", "batt"]
  load ← probe "sysctl" ["-n", "vm.loadavg"]
  pure
    [ "- Machine: " <> intercalate ", " (filter (not . null) [model, cpu, if null memory then "" else show ((read memory ∷ Integer) `div` (1024 * 1024 * 1024)) <> " GiB", system, if null osVersion then "" else "macOS " <> osVersion])
    , "- Power: " <> (if null power then "unknown" else power)
    , "- Load average at the start (1, 5, 15 minutes): " <> (if null load then "unknown" else load) <> "; timings taken under load are not comparable with quiet ones"
    ]
  where
    probe command arguments = do
      answer ← try (readProcess command arguments "") ∷ IO (Either SomeException String)
      pure (either (const "") (unwords . lines) answer)

-- ---------------------------------------------------------------------------
-- The report

type Timed =
  ( Device
  , Vector.Vector ResourceClass
  , CallSafety
  , [Configuration]
  , Measurement
  , [(Trace, Measurement)]
  , Maybe (Measurement, [DeferredRun])
  )

version ∷ Word32 → String
version v = show (v `div` 4194304 `mod` 128) <> "." <> show (v `div` 4096 `mod` 1024) <> "." <> show (v `mod` 4096)

header ∷ ProductionOptions → [String] → String → (Double, Double) → Maybe String → [String] → Either String Timed → [String]
header options machine compiler (haskellClock, cClock) declared features report =
  [ "# VMA production qualification (GRS-18) results"
  , ""
  , "## Reproduction"
  , ""
  , "- Command: `"
      <> maybe "" (\v → "HETOIMASIA_VMA_FOREIGN_CALLS=" <> v <> " ") declared
      <> "bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe"
      <> (if null (productionArguments options) then "" else " -- " <> unwords (productionArguments options))
      <> "`"
  , "- Binding variant: " <> variant
  , "- Source digest: `" <> fst (productionDigest options) <> "` over " <> intercalate ", " (snd (productionDigest options))
  ]
    <> machine
    <> [ "- Platform: " <> os <> " " <> arch
       , "- GHC: " <> showVersion fullCompilerVersion <> ", threaded runtime, one capability; the probe runs on the main (bound) thread, as the engine's owner thread does"
       , "- C++ compiler (C driver): " <> compiler <> ", `-std=c++17 -O2`"
       , "- VMA: Hackage `VulkanMemoryAllocator-" <> VERSION_VulkanMemoryAllocator <> "`, bundling VMA " <> bundledVma
           <> ", built by its own Cabal package with `-std=c++17` and its `vma-ndebug` flag (`-DNDEBUG`, assertions compiled out) at Cabal's default optimisation; the C driver calls that same compiled VMA, so both drivers run identical VMA code. `VMA_STATIC_VULKAN_FUNCTIONS 0`, dynamic Vulkan functions from the loader's `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr`."
       , "- Allocator: one per pass, created through the binding, used from one thread, with `VMA_ALLOCATOR_CREATE_EXTERNALLY_SYNCHRONIZED_BIT`, `preferredLargeHeapBlockSize` " <> show (preferredLargeHeapBlockSize `div` (1024 * 1024)) <> " MiB (VMA's default, stated explicitly), `vulkanApiVersion` 1.3, no heap size limits, and device-memory callbacks into C or into Haskell"
       , "- Validation: every timing on a device with no layer; correctness on a second device with `VK_LAYER_KHRONOS_validation` and features [" <> intercalate ", " features <> "], whose messenger is a C callback"
       , "- Repetitions: " <> show (productionWarmup options) <> " warm-up, " <> show (productionRepetitions options) <> " measured, per mode; configurations interleaved within each repetition, their order rotated by repetition; a major collection before every pass"
       , "- Empty timed interval (mean of 10^6 back-to-back reads of the one shared clock): Haskell " <> fixed 1 haskellClock <> " ns, C " <> fixed 1 cClock <> " ns; the clock ticks every 41.7 ns on Apple silicon"
       , ""
       ]
    <> deviceLines
  where
    variant = case report of
      Right (_, _, safety, _, _, _, _) →
        callSafetyLabel safety <> " (decided by behaviour: a C callback inside a binding call " <> (if safety == SafeCalls then "was" else "could not be") <> " released by another Haskell thread)"
          <> maybe "" (\v → "; run.sh declared `" <> v <> "`") declared
      Left _ → "unknown: the timed passes did not complete"
    deviceLines = case report of
      Left _ → []
      Right (device, classes, _, _, _, _, _) →
        [ "## Device"
        , ""
        , "- " <> deviceName device <> " (vendor 0x" <> showHex (fst (deviceVendor device)) "" <> ", device 0x" <> showHex (snd (deviceVendor device)) "" <> ")"
        , "- Driver: " <> deviceDriverName device <> " " <> deviceDriverInfo device <> " (driverVersion " <> show (deviceDriverVersion device) <> "), device API " <> version (deviceApiVersion device) <> ", loader " <> version (deviceLoaderVersion device)
        , "- Instance extensions: " <> list (deviceInstanceExtensions device) <> "; device extensions: " <> list (deviceExtensions device) <> "; layers on the timing device: " <> list (deviceLayers device)
        , "- Limits: `bufferImageGranularity` " <> show (deviceBufferImageGranularity device) <> ", `nonCoherentAtomSize` " <> show (deviceNonCoherentAtomSize device) <> ", `maxMemoryAllocationCount` " <> show (deviceMaxAllocations device)
        , ""
        , "| Heap | Size | Flags |"
        , "| ---: | ---: | --- |"
        ]
          <> [ "| " <> show i <> " | " <> bytes size <> " | " <> (if flags == 0 then "none" else if flags == 1 then "DEVICE_LOCAL" else show flags) <> " |"
             | (i, (size, flags)) ← zip [0 ∷ Int ..] (deviceHeaps device)
             ]
          <> ["", "| Memory type | Heap | Properties | VMA preferred block size |", "| ---: | ---: | --- | ---: |"]
          <> [ "| " <> show (offerIndex o) <> " | " <> show (offerHeap o) <> " | " <> intercalate " \\| " (propertyNames (offerFlags o)) <> " | " <> bytes (preferredBlockSize device (offerIndex o)) <> " |"
             | o ← deviceMemoryTypes device
             ]
          <> ["", "| Class | Purpose | Usage flags | Required / preferred / avoided | `memoryTypeBits` offered | Chosen type | VMA flags |", "| --- | --- | ---: | --- | ---: | ---: | --- |"]
          <> [ "| " <> specName s <> " | " <> specPurpose s <> " | 0x" <> showHex (specUsage s) "" <> " | " <> flagsOf (specRequired s) <> " / " <> flagsOf (specPreferred s) <> " / " <> flagsOf (specAvoided s)
                 <> " | 0x" <> showHex (classTypeBits c) "" <> " | " <> show (classMemoryType c) <> " | " <> (if specAllocationFlags s == 4 then "`MAPPED`" else "none") <> " |"
             | c ← Vector.toList classes
             , let s = classSpec c
             ]
          <> [""]
    list xs = if null xs then "none" else intercalate ", " (map (\x → "`" <> x <> "`") xs)
    flagsOf f = if f == 0 then "—" else intercalate "\\|" (propertyNames f)

bytes ∷ Word64 → String
bytes n
  | n >= 1024 * 1024 * 1024 = fixed 2 (fromIntegral n / (1024 * 1024 * 1024)) <> " GiB"
  | n >= 1024 * 1024 = fixed 2 (fromIntegral n / (1024 * 1024)) <> " MiB"
  | n >= 1024 = fixed 1 (fromIntegral n / 1024) <> " KiB"
  | otherwise = show n <> " B"

selfChecks ∷ [String] → [String]
selfChecks problems =
  [ "## Self-checks"
  , ""
  , if null problems
      then
        "All passed: the C driver's restated VMA structs match the binding's layout; the threaded runtime with one capability; no layer enabled through the environment; synchronization validation requested; every gated trace's digest; the binding's call safety decided by behaviour and equal to what run.sh declared; on both devices, every request placed, every Haskell configuration's placements, D-40 outcomes, block events and byte quantities identical to the C driver's operation by operation, the callbacks' held bytes equal to VMA's own statistics at every checkpoint, and nothing held once the allocator was destroyed; every timed pass repeating its evidence pass's work; no free before its batch's fence was observed signalled; and no validation message."
      else "**Invalid** — the run is not evidence of anything below:"
  ]
    <> ["- " <> p | p ← problems]
    <> [""]

limitsSection ∷ Bool → Either String Timed → [Verdict] → Either SomeException ([String], Maybe DeferredRun) → ValidationMessages → [String]
limitsSection invalid report verdicts validated messages =
  [ "## Accepted limits"
  , ""
  , "The owner's limits for GRS-18 (#361): for each gated call, Haskell median minus C median (each less its side's empty timed interval) no greater than the larger of 25% of the C median or 50 ns — the total binding-path overhead, marshalling and wrappers included; on every gated trace, Haskell elapsed time no more than 1.25 × C elapsed time for identical work; and no completion-deferred free before its batch's fence signals, with clean synchronization validation. Timings decide the first two; none was taken under validation."
  , ""
  ]
    <> case report of
      Left problem → ["The timed passes did not complete (" <> problem <> "), so no limit was evaluated.", ""]
      Right (_, _, safety, configurations, _, _, deferred) →
        concat
          [ [ "### " <> configurationLabel safety c
            , ""
            , "| Limit | Result | Figures |"
            , "| --- | --- | --- |"
            ]
              <> [ "| " <> verdictLimit v <> " | " <> (if verdictMet v then "Met" else "**Missed**") <> " | " <> verdictDetail v <> " |"
                 | v ← verdicts
                 , verdictConfiguration v == c
                 ]
              <> [ "| completion-deferred frees | " <> deferredResult <> " | " <> deferredDetail <> " |"
                 , ""
                 , configurationVerdict c
                 , ""
                 ]
          | c ← configurations
          , configurationDriver c /= DriverC
          ]
          <> [ "The deferred-free workload runs from Haskell through this build's binding with C callbacks; its correctness gate is the configuration-independent property that no free precedes its fence, so it is reported against each configuration."
             , ""
             , if invalid
                 then "**This run is invalid** (see the self-checks), so none of the results above qualifies anything."
                 else
                   "A configuration qualifies for #333 only if it meets every limit. The recommendation, and whether it qualifies, is stated in `docs/gpu_vma_qualification_record.md` from this run and the run of the other binding variant."
             , ""
             ]
        where
          deferredClean = case validated of
            Right (_, Just run) → deferredEarly run == 0 && messageErrors messages + messageWarnings messages + messageOther messages == 0
            _ → False
          timedClean = case deferred of
            Just (_, runs) → all ((== 0) . deferredEarly) runs
            Nothing → False
          deferredResult = if deferredClean && timedClean then "Met" else "**Not met: the run is invalid**"
          deferredDetail = case (deferred, validated) of
            (Just (_, runs), Right (_, Just run)) →
              show (sum (map deferredEarly runs) + deferredEarly run) <> " early frees over " <> show (length runs + 1) <> " passes, "
                <> show (messageErrors messages) <> " validation errors and " <> show (messageWarnings messages) <> " warnings"
            _ → "the workload did not complete"
          configurationVerdict c =
            let mine = [v | v ← verdicts, verdictConfiguration v == c]
                missed = length (filter (not . verdictMet) mine)
             in if missed == 0 && deferredClean && timedClean && not invalid
                  then "**" <> configurationLabel safety c <> " met every accepted limit in this run.**"
                  else "**" <> configurationLabel safety c <> " missed " <> show missed <> " of " <> show (length mine) <> " timed limits" <> (if deferredClean && timedClean then "" else ", and the deferred-free gate is not met") <> "; it does not qualify.**"

detailSections ∷ (Double, Double) → Timed → [String]
detailSections clocks (_, classes, safety, configurations, calls, workloads, deferred) =
  callSection clocks safety configurations calls
    <> concatMap (workloadSection safety configurations classes) workloads
    <> maybe [] (deferredSection safety configurations workloads) deferred
    <> mappingSection

callSection ∷ (Double, Double) → CallSafety → [Configuration] → Measurement → [String]
callSection (haskellClock, cClock) safety configurations calls =
  [ "## Per-call figures"
  , ""
  , "The per-call script (README.md) on a fresh allocator per pass; each operation's sample is its mean over the repetitions; medians and 95th percentiles are nearest-rank over the population's operations, raw (each side's empty interval included: Haskell " <> fixed 1 haskellClock <> " ns, C " <> fixed 1 cClock <> " ns). Indented rows split the row above them and gate nothing."
  , ""
  , "| Call | n | " <> intercalate " | " [configurationLabel safety c <> " median / p95 (ns)" | c ← configurations] <> " |"
  , "| --- | ---: |" <> concat (replicate (length configurations) " ---: |")
  ]
    <> [ "| " <> populationName p <> " | " <> show (length (populationOperations p)) <> " | "
           <> intercalate " | " [pair (samplesOf calls c p) | c ← configurations] <> " |"
       | p ← callPopulations calls
       ]
    <> [""]
    <> callbackLines
    <> blockLines "per-call script" calls
  where
    pair samples = if null samples then "n/a" else fixed 1 (nearestRank 0.5 samples) <> " / " <> fixed 1 (nearestRank 0.95 samples)
    callbackLines =
      let pairs =
            [ d
            | d ← [DriverHackage, DriverShim SafeCalls]
            , Configuration d CallbacksInC `elem` configurations
            , Configuration d CallbacksInHaskell `elem` configurations
            ]
          firing =
            [ p
            | p ← callPopulations calls
            , populationName p
                `elem` [ "D-40 failed reuse, then an allocating call that opens a block: both calls"
                       , "D-40 failed reuse, then a dedicated allocation (160 MiB): both calls"
                       , "free of a dedicated allocation (160 MiB)"
                       , "free of a block-backed allocation that empties a block (64 MiB)"
                       ]
            ]
       in [ "**Callbacks.** Callbacks into Haskell against callbacks into C, with safe calls on both sides, on the calls that fire them (median, ns). Calls that fire no callback cost the same either way."
          , ""
          , "| Driver | Call | C callbacks | Haskell callbacks | Difference |"
          , "| --- | --- | ---: | ---: | ---: |"
          ]
            <> [ let a = nearestRank 0.5 (samplesOf calls (Configuration d CallbacksInC) p)
                     b = nearestRank 0.5 (samplesOf calls (Configuration d CallbacksInHaskell) p)
                  in "| " <> driverLabel safety d <> " | " <> populationName p <> " | " <> fixed 1 a <> " | " <> fixed 1 b <> " | " <> fixed 1 (b - a) <> " |"
               | d ← pairs
               , p ← firing
               ]
            <> [ ""
               , if DriverHackage `elem` pairs
                   then "Both safe drivers were compared."
                   else "This build's Hackage binding makes unsafe calls, so it ran with C callbacks only: no unsafe foreign call may reach a Haskell callback. The shim's safe imports supply the comparison here, and the safe-calls run adds the Hackage binding's."
               , ""
               ]

blockLines ∷ String → Measurement → [String]
blockLines what measurement =
  let reference = measurementEvidence measurement Map.! baseline
      retained = passRetained reference
      released = passReleased reference
      events = countersEvents released
      opens = [e | e ← events, not (eventFree e)]
      frees = [e | e ← events, eventFree e]
      count = Unboxed.length (scriptKinds (measurementScript measurement))
      histogram es = intercalate ", " [show (length (filter (== s) sizes)) <> " × " <> bytes s | s ← nub (sort sizes)] where sizes = map eventSize es
   in [ "**Block events (" <> what <> ", C driver; every Haskell configuration's are identical).** VMA opened " <> show (countersOpened released) <> " device-memory objects (" <> bytes (countersOpenedBytes released) <> ": " <> histogram opens <> ")"
          <> " and freed " <> show (length [e | e ← frees, eventOperation e < fromIntegral count]) <> " while the script ran; "
          <> bytes (countersHeld retained) <> " was still held once every resource was freed (VMA's retained empty blocks), released only when the allocator was destroyed; peak held " <> bytes (countersPeakHeld released) <> ". D-40's bound — no more opened by an allocating call than the larger of the type's preferred block size and the request, nothing by a `NEVER_ALLOCATE` attempt — was broken " <> show (summaryWord reference SummaryBoundBroken) <> " times."
      , ""
      ]

workloadSection ∷ CallSafety → [Configuration] → Vector.Vector ResourceClass → (Trace, Measurement) → [String]
workloadSection safety configurations classes (trace, measurement) =
  [ "## Workload: " <> traceName trace
  , ""
  , "- Trace SHA-256 `" <> traceDigest trace <> "`; " <> show creates <> " allocations, " <> show destroys <> " frees, " <> show (length (traceCheckpoints trace)) <> " checkpoints"
  ]
    <> ["- Trace header: " <> n | n ← traceNotes trace]
    <> [ "- Native allocations (`vkAllocateMemory` calls VMA made): " <> show (countersOpened released) <> "; VMA allocations: " <> show creates
           <> "; D-40: " <> show (summaryWord reference SummaryHits) <> " placed by `NEVER_ALLOCATE`, " <> show (summaryWord reference SummaryMisses) <> " needed the allocating call"
       , "- Bytes, as separate quantities: peak live requested " <> bytes (summaryWord reference SummaryPeakRequested)
           <> "; peak live allocated (the device's memory requirements) " <> bytes (summaryWord reference SummaryPeakAllocated)
           <> "; peak device memory held " <> bytes (countersPeakHeld released)
           <> "; held once the trace's live resources were freed " <> bytes (countersHeld (passRetained reference))
       , ""
       , "| Class | Allocations | Requested bytes | Required bytes | Required alignments | `memoryTypeBits` | Memory type |"
       , "| --- | ---: | ---: | ---: | --- | --- | ---: |"
       ]
    <> classRows
    <> [ ""
       , "| Figure | " <> intercalate " | " (map (configurationLabel safety) configurations) <> " |"
       , "| --- |" <> concat (replicate (length configurations) " ---: |")
       , row "Elapsed, median over repetitions (whole trace)" (\c → milliseconds (medianWhole measurement c))
       , row "Throughput (operations per second)" (\c → fixed 0 (fromIntegral (creates + destroys) / (medianWhole measurement c / 1e9)))
       , row "Elapsed ÷ C" (\c → fixed 3 (medianWhole measurement c / medianWhole measurement baseline) <> "×")
       , row "Allocation placed by `NEVER_ALLOCATE`: median / p95 (ns)" (\c → pair (samples c hitOps WholeOperation))
       , row "Allocation needing the allocating call: median / p95 (ns)" (\c → pair (samples c missOps WholeOperation))
       , row "Free: median / p95 (ns)" (\c → pair (samples c destroyOps WholeOperation))
       , ""
       ]
    <> checkpointRows
    <> blockLines (traceName trace) measurement
  where
    script = measurementScript measurement
    reference = measurementEvidence measurement Map.! baseline
    released = passReleased reference
    count = Unboxed.length (scriptKinds script)
    creates = summaryWord reference SummaryCreates
    destroys = summaryWord reference SummaryDestroys
    kindAt i = opCode (scriptKinds script Unboxed.! i)
    createOps = [i | i ← [0 .. count - 1], kindAt i == CreateD40]
    hitOps = [i | i ← createOps, outcomeOf reference i `div` 2 `mod` 2 == 1]
    missOps = [i | i ← createOps, outcomeOf reference i `div` 4 `mod` 2 == 1]
    destroyOps = [i | i ← [0 .. count - 1], kindAt i == Destroy]
    samples c ops part = samplesOf measurement c (Population "" False part ops)
    pair xs = if null xs then "n/a" else fixed 1 (nearestRank 0.5 xs) <> " / " <> fixed 1 (nearestRank 0.95 xs)
    row name f = "| " <> name <> " | " <> intercalate " | " (map f configurations) <> " |"
    word i k = passEvidence reference Unboxed.! (i * evidenceWords + k)
    classRows =
      [ "| " <> specName (classSpec c) <> " | " <> show (length ops) <> " | " <> bytes (sum [scriptSizes script Unboxed.! i | i ← ops])
          <> " | " <> bytes (sum [word i 5 | i ← ops])
          <> " | " <> intercalate ", " (map show (nub (sort [word i 6 | i ← ops])))
          <> " | " <> intercalate ", " ["0x" <> showHex b "" | b ← nub (sort [word i 7 | i ← ops])]
          <> " | " <> intercalate ", " (map show (nub (sort [word i 1 | i ← ops])))
          <> " |"
      | (index, c) ← zip [0 ∷ Word32 ..] (Vector.toList classes)
      , let ops = [i | i ← createOps, scriptClassIndices script Unboxed.! i == index]
      , not (null ops)
      ]
    checkpointRows =
      let rows = passCheckpoints reference
          labels = traceCheckpoints trace
       in if null labels
            then []
            else
              [ "| Checkpoint | Live resources | Live requested | Live allocated | Device memory held (callbacks) | Held (VMA statistics) | Blocks opened so far |"
              , "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"
              ]
                <> [ "| " <> label <> " | " <> show (at 4) <> " | " <> bytes (at 0) <> " | " <> bytes (at 1) <> " | " <> bytes (at 2) <> " | " <> bytes (at 3) <> " | " <> show (at 5) <> " |"
                   | (k, label) ← zip [0 ..] labels
                   , let at j = rows Unboxed.! (k * checkpointWords + j)
                   ]
                <> [""]

deferredSection ∷ CallSafety → [Configuration] → [(Trace, Measurement)] → (Measurement, [DeferredRun]) → [String]
deferredSection _ _ _ (_, []) = []
deferredSection safety configurations workloads (_, first : rest) =
  [ "## Completion-deferred frees"
  , ""
  , "`small-steady` replayed in batches of " <> show batchOperations <> " operations that the GPU executes, " <> show inFlight <> " in flight, from Haskell through this build's binding (" <> callSafetyLabel safety <> ") with C callbacks. Each resource is used by a transfer command in the batch that creates it and in the batch that frees it; its free waits until that batch's fence has signalled. Immediate frees are the same trace's frees in the plain replay, the same configuration, with no GPU use."
  , ""
  , "- Batches " <> show (deferredBatches first) <> "; allocations " <> show (deferredCreates first) <> "; frees " <> show (deferredDestroys first)
      <> "; frees waiting at once: peak " <> show (deferredPendingPeak first) <> ", mean " <> fixed 1 (deferredPendingMean first) <> " per batch"
  , "- Early frees: " <> show (sum (map deferredEarly runs)) <> " over " <> show (length runs) <> " timed passes (the validated pass is reported under Validation)"
  , ""
  , "| Figure (median over repetitions) | Deferred | Immediate |"
  , "| --- | ---: | ---: |"
  , "| Free call (`vmaDestroyBuffer`): median / p95 (ns) | " <> pair deferredFrees <> " | " <> pair immediateFrees <> " |"
  , "| Free calls, total | " <> milliseconds (med (map (fromIntegral . deferredDestroyNanoseconds) runs)) <> " | " <> milliseconds (sum immediateFrees) <> " |"
  , "| Draining released frees (bookkeeping and free calls) | " <> milliseconds (med (map (fromIntegral . deferredDrainNanoseconds) runs)) <> " | — |"
  , "| Allocation (D-40) | " <> milliseconds (med (map (fromIntegral . deferredAllocateNanoseconds) runs)) <> " | — |"
  , "| Recording and submission | " <> milliseconds (med (map (fromIntegral . deferredRecordNanoseconds) runs)) <> " | — |"
  , "| Fence waits | " <> milliseconds (med (map (fromIntegral . deferredWaitNanoseconds) runs)) <> " | — |"
  , "| Whole workload | " <> milliseconds (med (map (fromIntegral . deferredWholeNanoseconds) runs)) <> " | " <> immediateWhole <> " |"
  , ""
  , "Deferred minus immediate free calls, median per free: " <> fixed 1 (nearestRank 0.5 deferredFrees - nearestRank 0.5 immediateFrees) <> " ns. This comparison is reported and carries no numeric limit."
  , ""
  ]
  where
    runs = first : rest
    med = nearestRank 0.5
    perFree = [fromIntegral x / fromIntegral (length runs) | x ← foldr1 (zipWith (+)) (map deferredDestroySamples runs)] ∷ [Double]
    deferredFrees = perFree
    haskellC = Configuration DriverHackage CallbacksInC
    steady = [m | (t, m) ← workloads, traceName t == "small-steady"]
    immediateFrees = case steady of
      [m] →
        let script = measurementScript m
            (totals, _) = measurementPerOperation m Map.! haskellC
         in [totals Unboxed.! i | i ← [0 .. Unboxed.length (scriptKinds script) - 1], opCode (scriptKinds script Unboxed.! i) == Destroy]
      _ → []
    immediateWhole = case steady of
      [m] | haskellC `elem` configurations → milliseconds (medianWhole m haskellC)
      _ → "n/a"
    pair xs = if null xs then "n/a" else fixed 1 (nearestRank 0.5 xs) <> " / " <> fixed 1 (nearestRank 0.95 xs)

validationSection ∷ Either SomeException ([String], Maybe DeferredRun) → ValidationMessages → [String]
validationSection validated messages =
  [ "## Validation"
  , ""
  ]
    <> case validated of
      Left e → ["The validated passes did not complete: " <> displayException e, ""]
      Right (layers, run) →
        [ "Every configuration's evidence pass of the per-call script and of each gated trace, and one deferred-free pass, ran again on a device with " <> intercalate ", " layers <> " and the features above. "
            <> "Messages (errors, warnings, other): " <> show (messageErrors messages) <> ", " <> show (messageWarnings messages) <> ", " <> show (messageOther messages) <> "."
            <> maybe "" (\r → " The validated deferred-free pass freed " <> show (deferredDestroys r) <> " resources with " <> show (deferredEarly r) <> " early frees.") run
        , ""
        ]
          <> ["- " <> t | t ← messageTexts messages]
          <> (if null (messageTexts messages) then [] else [""])

mappingSection ∷ [String]
mappingSection =
  [ "## Trace-to-resource mapping"
  , ""
  ]
    <> mappingLines
    <> [""]
