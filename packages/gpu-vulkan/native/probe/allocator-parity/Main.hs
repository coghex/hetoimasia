{-# LANGUAGE CPP #-}

-- | The allocator parity probe (GRS-1, D-14): replays committed traces into
-- one fixed-size block through the Haskell placement and through VMA's virtual
-- block, reports requirement 7's four criteria for the gated traces, and
-- reports diagnostics that separate search, copying, collection and timer
-- overhead.
--
--   bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe
--
-- Options, after @--@: @--output FILE@ to also write the report there,
-- @--gate-traces DIR@, @--diagnostic-traces DIR@ (repeatable), @--warmup N@
-- and @--repetitions N@. It exits 1 when a gate is missed on a gated trace and
-- 2 when a self-check fails. README.md beside it states the protocol.
module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, replicateM_, unless, when)
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (intercalate, isSuffixOf, sort)
import qualified Data.Map.Strict as Map
import qualified Data.Vector.Storable as Storable
import qualified Data.Vector.Storable.Mutable as StorableMutable
import qualified Data.Vector.Unboxed as Unboxed
import Data.Version (showVersion)
import Data.Word (Word64, Word8)
import GHC.Conc (getAllocationCounter)
import GHC.RTS.Flags (GCFlags (minAllocAreaSize), getGCFlags)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Hetoimasia.GPU.Model.Placement (bestFit, strategyLabel)
import Numeric (showHex)
import Parity.Differential (differentialCheck)
import Parity.Haskell (HaskellEvidence (..), replayHaskell)
import Parity.Mutable (MutableEvidence (..), replayMutable)
import Parity.Reference (Search (..))
import Parity.Replay (Evidence (..), Mode (..), Pass (..), sampleEvery, samePass)
import Parity.Report
import Parity.Trace (OpKind (..), Trace (..), opKind, readTrace)
import Parity.Vma (VmaStrategy (..), checkLayouts, clockPairNanoseconds, encodeTrace, probeCompiler, replayVma)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hFlush, hPutStrLn, stderr)
import System.Info (arch, fullCompilerVersion, os)
import System.Mem (performMajorGC)
import System.Process (readProcess)

-- | The upstream VMA the pinned Hackage package bundles, from that package's
-- changelog. The package version itself comes from the build.
bundledVma ∷ String
bundledVma = "3.3.0"

-- | The four gated traces' digests as run 1 read them. Run 2 is comparable
-- with run 1 only while these hold.
runOneDigests ∷ Map.Map String String
runOneDigests =
  Map.fromList
    [ ("small-bursty", "4bb9063e41daa08ae02bd239e4bf9d979cfc3b6aeeaf4772eb1322e32b607c0c")
    , ("small-mixed", "c62909c57f8a690941f95b2bf1164b2fc972f0204f5318f724c85444a85c94a8")
    , ("small-steady", "5ecd799fa26e0a73c0a3af2f456f9dbd85e06568691948e35c568e301f29cf3f")
    , ("synarchy-sheets", "74c2e4c93d557e61dfbbd4e357e1f5626c9eba137a8dbd03b9dd099536a5724b")
    ]

-- | The differential self-check's size: seeded scripts, and steps in each.
differentialScripts, differentialSteps ∷ Int
differentialScripts = 500
differentialSteps = 300

-- | Operations per throughput window.
windowOperations ∷ Int
windowOperations = 256

-- | The shortest run of same-kind operations reported as a segment.
segmentOperations ∷ Int
segmentOperations = 256

data Options = Options
  { optionGateTraces ∷ FilePath
  , optionDiagnosticTraces ∷ [FilePath]
  , optionOutput ∷ Maybe FilePath
  , optionWarmup ∷ Int
  , optionRepetitions ∷ Int
  }

parseOptions ∷ [String] → Either String Options
parseOptions = go (Options "probe/allocator-parity/traces" [] Nothing 3 20) False
  where
    go options diagnosticsGiven [] =
      Right
        ( if diagnosticsGiven
            then options
            else options {optionDiagnosticTraces = ["probe/allocator-parity/traces/churn", "probe/allocator-parity/traces/sweep"]}
        )
    go options given ("--gate-traces" : value : rest) = go options {optionGateTraces = value} given rest
    go options _ ("--diagnostic-traces" : value : rest) =
      go options {optionDiagnosticTraces = optionDiagnosticTraces options <> [value]} True rest
    go options given ("--output" : value : rest) = go options {optionOutput = Just value} given rest
    go options given ("--warmup" : value : rest) = count value >>= \n → go options {optionWarmup = n} given rest
    go options given ("--repetitions" : value : rest) = count value >>= \n → go options {optionRepetitions = n} given rest
    go _ _ (other : _) = Left ("unrecognised argument " <> show other)
    count value = case reads value of
      [(n, "")] | n >= 0 → Right n
      _ → Left ("not a count: " <> show value)

main ∷ IO ()
main = do
  arguments ← getArgs
  options ← either (\problem → hPutStrLn stderr problem >> exitWith (ExitFailure 2)) pure (parseOptions arguments)
  unless (optionRepetitions options >= 1) $ hPutStrLn stderr "at least one repetition is needed" >> exitWith (ExitFailure 2)
  checkLayouts
  failures ← newIORef []
  selfCheckStatistics failures
  progress "running the differential check of the prototype against the reference"
  differentialCheck differentialScripts differentialSteps >>= mapM_ (failed failures)
  clocks ← clockPairNanoseconds 1000000
  environment ← describeEnvironment options arguments clocks
  gateFiles ← traceFiles (optionGateTraces options)
  when (null gateFiles) $ hPutStrLn stderr ("no traces in " <> optionGateTraces options) >> exitWith (ExitFailure 2)
  gated ← forM gateFiles $ \file → do
    progress ("replaying gated trace " <> file)
    trace ← readTrace file
    case Map.lookup (traceName trace) runOneDigests of
      Just digest
        | digest /= traceDigest trace →
            failed failures (traceName trace <> "'s digest differs from run 1's, so run 2 is not comparable with it")
      _ → pure ()
    measure options clocks failures trace
  diagnosticSections ← forM (optionDiagnosticTraces options) $ \directory → do
    files ← traceFiles directory
    results ← forM files $ \file → do
      progress ("replaying diagnostic trace " <> file)
      readTrace file >>= measure options clocks failures
    pure (directory, results)
  problems ← reverse <$> readIORef failures
  let gatesMet = all resultGatesMet gated && all resultMutableGatesMet gated
      report =
        unlines $
          environment
            <> selfCheckSection problems
            <> gateSummary gated
            <> ["## Gated traces: measured on the committed traces", ""]
            <> concatMap (traceSection True) gated
            <> summaryTable "Gated traces" gated
            <> concat
              [ ["## Diagnostic traces (hypothetical workloads): " <> directory, ""]
                  <> [ "These traces vary assumptions no source establishes. The criteria are shown for comparison and gate nothing."
                     , ""
                     ]
                  <> summaryTable directory results
                  <> concatMap (traceSection False) results
              | (directory, results) ← diagnosticSections
              ]
  putStr report
  forM_ (optionOutput options) (`writeFile` report)
  unless (null problems) $ do
    hPutStrLn stderr "allocator parity: a self-check failed; the figures are not trustworthy"
    exitWith (ExitFailure 2)
  unless gatesMet $ do
    hPutStrLn stderr "allocator parity: at least one gate was missed on a gated trace"
    exitWith (ExitFailure 1)

traceFiles ∷ FilePath → IO [FilePath]
traceFiles directory = do
  exists ← doesDirectoryExist directory
  if not exists
    then pure []
    else do
      names ← sort . filter (".trace" `isSuffixOf`) <$> listDirectory directory
      pure (map (directory </>) names)

progress ∷ String → IO ()
progress message = hPutStrLn stderr ("allocator parity: " <> message) >> hFlush stderr

failed ∷ IORef [String] → String → IO ()
failed failures problem = modifyIORef' failures (problem :)

-- | The report's own arithmetic, checked on inputs whose answers are known.
selfCheckStatistics ∷ IORef [String] → IO ()
selfCheckStatistics failures = do
  let cases =
        [ (nearestRank 0.5 [5, 1, 3, 2, 4], 3)
        , (nearestRank 0.5 [1, 2, 3, 4], 2)
        , (nearestRank 0.95 [1 .. 20], 19)
        , (nearestRank 0.95 [1 .. 100], 95)
        , (nearestRank 1.0 [7, 9, 8], 9)
        ]
  forM_ cases $ \(answer, expected) →
    unless (answer == expected) $ failed failures ("nearest rank answered " <> show answer <> " where " <> show expected <> " is right")
  enabled ← getRTSStatsEnabled
  unless enabled $ failed failures "the runtime keeps no statistics, so allocation and collection figures are missing; run with +RTS -T"

-- ---------------------------------------------------------------------------
-- Measuring one trace

-- | One side of the comparison.
data SideName = Haskell | HaskellMutable | VmaBaseline | VmaMinMemorySide
  deriving (Eq, Ord, Show)

sideLabel ∷ SideName → String
sideLabel Haskell = "Haskell reference"
sideLabel HaskellMutable = "Haskell mutable prototype"
sideLabel VmaBaseline = "VMA default"
sideLabel VmaMinMemorySide = "VMA MIN_MEMORY"

sides ∷ [SideName]
sides = [Haskell, HaskellMutable, VmaBaseline, VmaMinMemorySide]

-- | The two Haskell sides: the pure reference and the mutable prototype.
haskellSides ∷ [SideName]
haskellSides = [Haskell, HaskellMutable]

-- | Everything measured for one side on one trace.
data Measured = Measured
  { measuredEvidence ∷ !Evidence
  , measuredPerOperation ∷ !(Unboxed.Vector Double)
    -- ^ Per-operation mean nanoseconds over the measured repetitions.
  , measuredWindows ∷ !(Unboxed.Vector Double)
    -- ^ Per-window accumulated nanoseconds.
  , measuredWindowTotals ∷ ![Double]
    -- ^ Each repetition's windowed nanoseconds, the whole trace.
  , measuredSegments ∷ !(Unboxed.Vector Double)
  , measuredExecuted ∷ !Word64
  , measuredHeap ∷ !(Maybe Pass)
    -- ^ VMA's counting pass.
  , measuredRuntime ∷ !(Maybe RuntimeFigures)
    -- ^ The Haskell side's runtime statistics over the windowed passes.
  }

data RuntimeFigures = RuntimeFigures
  { runtimeAllocatedBytes ∷ !Word64
  , runtimeCollections ∷ !Word64
  , runtimeCollectionNanoseconds ∷ !Word64
  , runtimeTimedNanoseconds ∷ !Word64
  , runtimeExecuted ∷ !Word64
  }

data Result = Result
  { resultTrace ∷ !Trace
  , resultMeasured ∷ !(Map.Map SideName Measured)
  , resultSearches ∷ ![(Search, Maybe Word64)]
  , resultFootprints ∷ !(Map.Map SideName [Word64])
  , resultLongestWalk ∷ !Int
    -- ^ The prototype's deepest treap path on insertion.
  , resultGateFigures ∷ !(Map.Map SideName Figures)
    -- ^ Every side's per-operation figures, as run 1 computed them.
  , resultVerdicts ∷ ![Verdict]
    -- ^ The reference's gates, against VMA default.
  , resultMutableVerdicts ∷ ![Verdict]
    -- ^ The prototype's gates, against VMA default.
  , resultMinMemoryVerdicts ∷ ![Verdict]
    -- ^ The reference against VMA MIN_MEMORY; never gated.
  , resultWindowBounds ∷ ![(Int, Int)]
  , resultSegmentBounds ∷ ![(OpKind, Int, Int)]
  , resultClocks ∷ !(Double, Double)
  }

resultGatesMet ∷ Result → Bool
resultGatesMet = all verdictMet . resultVerdicts

resultMutableGatesMet ∷ Result → Bool
resultMutableGatesMet = all verdictMet . resultMutableVerdicts

measure ∷ Options → (Double, Double) → IORef [String] → Trace → IO Result
measure options clocks failures trace = do
  encoded ← encodeTrace trace
  let count = Unboxed.length (traceKinds trace)
      repetitions = optionRepetitions options
      windows = [(start, min count (start + windowOperations)) | start ← [0, windowOperations .. count - 1]]
      segments = sameKindRuns trace
      windowBounds = boundsVector [(a, b) | (a, b) ← windows]
      segmentBounds = boundsVector [(a, b) | (_, a, b) ← segments]
      replay side mode = case side of
        Haskell → do
          (pass, _) ← replayHaskell bestFit trace mode
          pure pass
        HaskellMutable → fst <$> replayMutable trace mode
        VmaBaseline → fst <$> replayVma VmaDefault trace encoded mode
        VmaMinMemorySide → fst <$> replayVma VmaMinMemory trace encoded mode
  -- The evidence passes.
  performMajorGC
  (haskellPass, haskellExtra) ← replayHaskell bestFit trace EvidenceMode
  haskell ← maybe (fail "no Haskell evidence") pure haskellExtra
  performMajorGC
  (mutablePass, mutableExtra) ← replayMutable trace EvidenceMode
  mutable ← maybe (fail "no prototype evidence") pure mutableExtra
  -- The prototype must make the reference's decisions: every request placed
  -- at the same offset, or refused by both.
  let referenceShared = haskellShared haskell
      prototypeShared = mutableShared mutable
  unless
    ( evidencePlaced referenceShared == evidencePlaced prototypeShared
        && evidenceOffsets referenceShared == evidenceOffsets prototypeShared
        && evidenceSampleLargest referenceShared == evidenceSampleLargest prototypeShared
        && evidenceSampleFree referenceShared == evidenceSampleFree prototypeShared
    )
    $ failed failures (traceName trace <> ": the prototype's placements or usage differ from the reference's")
  (vmaPass, vmaEvidence) ← replayVma VmaDefault trace encoded EvidenceMode
  (minimumPass, minimumEvidence) ← replayVma VmaMinMemory trace encoded EvidenceMode
  evidence ← maybe (fail "no VMA evidence") pure vmaEvidence
  minimumEvidence' ← maybe (fail "no VMA MIN_MEMORY evidence") pure minimumEvidence
  let evidencePasses = Map.fromList [(Haskell, haskellPass), (HaskellMutable, mutablePass), (VmaBaseline, vmaPass), (VmaMinMemorySide, minimumPass)]
      checkPass side what pass =
        unless (samePass pass (evidencePasses Map.! side)) $
          failed failures (traceName trace <> ": " <> sideLabel side <> "'s " <> what <> " pass did different work from its evidence pass")
  -- The reconstruction must agree with the implementation wherever it was sampled.
  let disagreements = [() | (search, actual) ← haskellSearches haskell, searchOffset search /= actual]
  unless (null disagreements) $
    failed failures (traceName trace <> ": the search reconstruction disagreed with the placement on " <> show (length disagreements) <> " sampled requests")
  -- VMA's heap counting passes.
  (vmaHeap, _) ← replayVma VmaDefault trace encoded HeapCount
  (minimumHeap, _) ← replayVma VmaMinMemory trace encoded HeapCount
  checkPass VmaBaseline "heap-counting" vmaHeap
  checkPass VmaMinMemorySide "heap-counting" minimumHeap
  -- Warm-up, untimed.
  scratch ← StorableMutable.replicate (max 1 count) 0
  replicateM_ (optionWarmup options) $ forM_ sides $ \side → do
    performMajorGC
    replay side (PerOperation scratch)
  -- Per operation: the gated method, unchanged from run 1.
  perOperation ← forM sides $ \side → (,) side <$> StorableMutable.replicate (max 1 count) 0
  replicateM_ repetitions $ forM_ perOperation $ \(side, elapsed) → do
    performMajorGC
    replay side (PerOperation elapsed) >>= checkPass side "per-operation"
  -- Windows: throughput diagnostics, with the runtime's statistics around each
  -- Haskell pass and the collection forced before it left out.
  windowed ← forM sides $ \side → (,) side <$> StorableMutable.replicate (max 1 (length windows)) 0
  runtime ← newIORef (Map.fromList [(side, RuntimeFigures 0 0 0 0 0) | side ← haskellSides])
  totals ← newIORef (Map.empty ∷ Map.Map SideName [Double])
  replicateM_ repetitions $ forM_ windowed $ \(side, elapsed) → do
    performMajorGC
    before ← getRTSStats
    counterBefore ← getAllocationCounter
    pass ← replay side (Intervals windowBounds elapsed)
    counterAfter ← getAllocationCounter
    after ← getRTSStats
    checkPass side "windowed" pass
    modifyIORef' totals (Map.insertWith (flip (<>)) side [fromIntegral (passTimedNanoseconds pass)])
    when (side `elem` haskellSides) $
      modifyIORef' runtime $ flip Map.adjust side $ \r →
        r
          { -- The thread's allocation counter counts down as it allocates, and
            -- unlike the statistics' total it does not wait for a collection.
            runtimeAllocatedBytes = runtimeAllocatedBytes r + fromIntegral (counterBefore - counterAfter)
          , runtimeCollections = runtimeCollections r + fromIntegral (gcs after - gcs before)
          , runtimeCollectionNanoseconds = runtimeCollectionNanoseconds r + fromIntegral (gc_elapsed_ns after - gc_elapsed_ns before)
          , runtimeTimedNanoseconds = runtimeTimedNanoseconds r + passTimedNanoseconds pass
          , runtimeExecuted = runtimeExecuted r + passExecuted pass
          }
  -- Same-kind segments: throughput diagnostics for pure allocation and pure free runs.
  segmented ← forM sides $ \side → (,) side <$> StorableMutable.replicate (max 1 (length segments)) 0
  unless (null segments) $
    replicateM_ repetitions $ forM_ segmented $ \(side, elapsed) → do
      performMajorGC
      replay side (Intervals segmentBounds elapsed) >>= checkPass side "segmented"
  runtimeFigures ← readIORef runtime
  totalsBySide ← readIORef totals
  let evidenceOf Haskell = haskellShared haskell
      evidenceOf HaskellMutable = mutableShared mutable
      evidenceOf VmaBaseline = evidence
      evidenceOf VmaMinMemorySide = minimumEvidence'
      averaged vector = Unboxed.map (/ fromIntegral repetitions) . Unboxed.map fromIntegral <$> freezeWords vector
  measured ← forM sides $ \side → do
    perOp ← averaged (lookupSide side perOperation)
    perWindow ← Unboxed.map fromIntegral <$> freezeWords (lookupSide side windowed)
    perSegment ← Unboxed.map fromIntegral <$> freezeWords (lookupSide side segmented)
    pure
      ( side
      , Measured
          { measuredEvidence = evidenceOf side
          , measuredPerOperation = Unboxed.take count perOp
          , measuredWindows = Unboxed.take (length windows) perWindow
          , measuredWindowTotals = Map.findWithDefault [] side totalsBySide
          , measuredSegments = Unboxed.take (length segments) perSegment
          , measuredExecuted = passExecuted (evidencePasses Map.! side)
          , measuredHeap = case side of
              VmaBaseline → Just vmaHeap
              VmaMinMemorySide → Just minimumHeap
              _ → Nothing
          , measuredRuntime = Map.lookup side runtimeFigures
          }
      )
  let bySide = Map.fromList measured
      gateFiguresOf side =
        let m = bySide Map.! side
            e = measuredEvidence m
         in figures trace (Timing (measuredPerOperation m) (evidencePlaced e) (freedBy trace (evidencePlaced e))) (evidenceCheckpointFree e) (evidenceCheckpointLargest e)
      gateFigures = Map.fromList [(side, gateFiguresOf side) | side ← sides]
      verdictsOf side against = verdicts (traceCheckpoints trace) (gateFigures Map.! side) (gateFigures Map.! against)
  pure
    Result
      { resultTrace = trace
      , resultMeasured = bySide
      , resultSearches = haskellSearches haskell
      , resultFootprints = Map.fromList [(Haskell, haskellFootprint haskell), (HaskellMutable, mutableFootprint mutable)]
      , resultLongestWalk = mutableWalk mutable
      , resultGateFigures = gateFigures
      , resultVerdicts = verdictsOf Haskell VmaBaseline
      , resultMutableVerdicts = verdictsOf HaskellMutable VmaBaseline
      , resultMinMemoryVerdicts = verdictsOf Haskell VmaMinMemorySide
      , resultWindowBounds = windows
      , resultSegmentBounds = segments
      , resultClocks = clocks
      }
  where
    lookupSide side pairs = maybe (error "no such side") id (lookup side pairs)

freezeWords ∷ StorableMutable.IOVector Word64 → IO (Unboxed.Vector Word64)
freezeWords vector = Unboxed.fromList . Storable.toList <$> Storable.freeze vector

boundsVector ∷ [(Int, Int)] → Storable.Vector Word64
boundsVector pairs = Storable.fromList (concat [[fromIntegral a, fromIntegral b] | (a, b) ← pairs])

-- | Maximal runs of consecutive allocations, or of consecutive frees, at least
-- 'segmentOperations' long. A checkpoint ends a run.
sameKindRuns ∷ Trace → [(OpKind, Int, Int)]
sameKindRuns trace = go 0
  where
    kindAt i = opKind (traceKinds trace Unboxed.! i)
    count = Unboxed.length (traceKinds trace)
    go i
      | i >= count = []
      | otherwise =
          let kind = kindAt i
              end = runEnd kind i
           in if kind /= Checkpoint && end - i >= segmentOperations
                then (kind, i, end) : go end
                else go end
    runEnd kind j
      | j < count && kindAt j == kind = runEnd kind (j + 1)
      | otherwise = j

-- | Per operation: a free of an allocation this side placed.
freedBy ∷ Trace → Unboxed.Vector Bool → Unboxed.Vector Bool
freedBy trace placed =
  let operations = Unboxed.length (traceKinds trace)
      allocatedAt =
        Unboxed.accum
          (\_ i → i)
          (Unboxed.replicate (max 1 (traceIdentities trace)) (-1 ∷ Int))
          [ (fromIntegral (traceIds trace Unboxed.! i), i)
          | i ← [0 .. operations - 1]
          , opKind (traceKinds trace Unboxed.! i) == Allocate
          ]
   in Unboxed.generate operations $ \i →
        opKind (traceKinds trace Unboxed.! i) == Free
          && placed Unboxed.! (allocatedAt Unboxed.! fromIntegral (traceIds trace Unboxed.! i))

-- | Operations a side executed within @[start, end)@.
executedIn ∷ Trace → Unboxed.Vector Bool → Int → Int → Int
executedIn trace freed start end =
  length
    [ ()
    | i ← [start .. end - 1]
    , opKind (traceKinds trace Unboxed.! i) == Allocate || freed Unboxed.! i
    ]

-- ---------------------------------------------------------------------------
-- The report

describeEnvironment ∷ Options → [String] → (Double, Double) → IO [String]
describeEnvironment options arguments (haskellClock, shimClock) = do
  model ← probe "sysctl" ["-n", "hw.model"]
  cpu ← probe "sysctl" ["-n", "machdep.cpu.brand_string"]
  system ← probe "uname" ["-srm"]
  osVersion ← probe "sw_vers" ["-productVersion"]
  power ← probe "pmset" ["-g", "batt"]
  load ← probe "sysctl" ["-n", "vm.loadavg"]
  compiler ← probeCompiler
  gcFlags ← getGCFlags
  sources ← sourceDigest
  let nursery = fromIntegral (minAllocAreaSize gcFlags) * 4096 ∷ Integer
  pure
    [ "# Allocator parity probe results"
    , ""
    , "## Reproduction"
    , ""
    , "- Command: `bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe"
        <> (if null arguments then "" else " -- " <> unwords arguments)
        <> "`"
    , "- Source digest: `" <> fst sources <> "` over " <> intercalate ", " (snd sources)
    , "- Machine: " <> intercalate ", " (filter (not . null) [model, cpu, system, if null osVersion then "" else "macOS " <> osVersion])
    , "- Power: " <> (if null power then "unknown" else power)
    , "- Load average at the start (1, 5, 15 minutes): " <> (if null load then "unknown" else load)
        <> "; timings taken under load are not comparable with quiet ones"
    , "- Platform: " <> os <> " " <> arch
    , "- GHC: " <> showVersion fullCompilerVersion <> ", nursery (-A) " <> show (nursery `div` 1024) <> " KiB"
    , "- C++ compiler (shim and VMA): " <> compiler
    , "- VMA: Hackage VulkanMemoryAllocator-" <> VERSION_VulkanMemoryAllocator <> ", bundling VMA " <> bundledVma
        <> ", assertions compiled out; a virtual block with VMA's default (TLSF) algorithm, no linear algorithm and no upper-address allocation"
    , "- Haskell: " <> strategyLabel bestFit <> ", one fixed block, granularity 1"
    , "- Repetitions: " <> show (optionWarmup options) <> " warm-up, " <> show (optionRepetitions options) <> " measured per mode"
    , "- Empty timed interval (mean of 10^6 back-to-back reads of the one shared clock): Haskell "
        <> fixed 1 haskellClock <> " ns, shim " <> fixed 1 shimClock <> " ns; the clock ticks every 41.7 ns on Apple silicon"
    , ""
    , "## How to read this report"
    , ""
    , "- **Gates** are requirement 7's four criteria, computed exactly as in run 1: per-operation samples, Haskell against VMA's default strategy, on the four gated traces."
    , "- **VMA MIN_MEMORY** is VMA's closest analogue of best fit. It is a separate comparison and gates nothing."
    , "- **The mutable prototype** (`Prototype/MutableBestFit.hs`) is best fit over mutable arrays in `ST`, owned by the probe's thread: segments in a slot pool linked to their physical neighbours, and free segments in TLSF-style size bins, each a treap ordered by (size, offset). It makes exactly the reference's decisions, which the self-checks prove, so its placements, refusals and fragmentation are the reference's and only its cost differs. The reference is the pure best fit #331 built (D-13), kept only as a test reference since the owner chose VMA for production allocation (D-38); the gates are evaluated for both."
    , "- **Per-operation figures** time each operation with one clock pair and average each operation over the repetitions. Every sample includes one empty timed interval; the *corrected* figures subtract it."
    , "- **Throughput diagnostics** time windows of " <> show windowOperations <> " consecutive operations, or runs of at least "
        <> show segmentOperations <> " same-kind operations, with one clock pair each. They are mean nanoseconds per executed operation, loop and collection included; a window's p95 describes windows, not individual-operation latency."
    , "- **Heap and collection figures**: the Haskell side's bytes allocated come from the replay thread's allocation counter, and its collections from the runtime's statistics, over the windowed passes, the forced collection before each pass left out; the footprint is live heap above the empty block after a major collection, every 1,000 operations. VMA's heap figures come from the C library's heap statistics read after every operation of a separate untimed pass; VMA builds a virtual block's metadata without allocation callbacks, so callbacks could not see them."
    , "- **Search figures** reconstruct, from the block's layout, how many free ranges best fit examines for a request, on up to 2,000 evenly spaced allocations per trace; each reconstruction is checked against the offset the implementation chose."
    , "- **Fragmentation samples** are taken after every " <> show sampleEvery <> " operations on all three sides; signed differences are Haskell minus VMA, so a negative value means Haskell is less fragmented."
    , "- **Workload assumptions** are quoted from each trace's header. The gated traces' sheet sizes come from Synarchy's assets; their churn, and every synthetic parameter, is assumed."
    , ""
    ]
  where
    probe command commandArguments = do
      answer ← try (readProcess command commandArguments "") ∷ IO (Either SomeException String)
      pure (either (const "") (unwords . lines) answer)

-- | A digest over the probe's own sources, the placement sources it measures,
-- and the build configuration, by path and content.
sourceDigest ∷ IO (String, [String])
sourceDigest = do
  files ← concat <$> mapM expand roots
  rows ← forM (sort files) $ \file → do
    bytes ← ByteString.readFile file
    pure (Char8.pack (file <> " " <> hex (SHA256.hash bytes) <> "\n"))
  pure (hex (SHA256.hash (ByteString.concat rows)), roots)
  where
    roots =
      [ "probe/allocator-parity"
      , "hetoimasia-gpu-vulkan-native.cabal"
      , "../model/placement-reference"
      , "../model/hetoimasia-gpu-vulkan-model.cabal"
      , "../../../cabal.project.vulkan"
      , "../../../cabal.project.common"
      ]
    expand path = do
      isFile ← doesFileExist path
      isDirectory ← doesDirectoryExist path
      if isFile
        then pure [path]
        else
          if isDirectory
            then do
              names ← sort <$> listDirectory path
              concat <$> mapM (expand . (path </>)) [n | n ← names, n /= "__pycache__", n /= ".DS_Store"]
            else fail ("the source digest's root " <> path <> " does not exist, so the digest would not cover what the probe measures")
    hex = concatMap byte . ByteString.unpack
    byte (b ∷ Word8) = let s = showHex b "" in if length s == 1 then '0' : s else s

selfCheckSection ∷ [String] → [String]
selfCheckSection problems =
  [ "## Self-checks"
  , ""
  , if null problems
      then
        "All passed: the layout check against the binding; the report's percentile arithmetic; the differential check of the prototype against the reference ("
          <> show differentialScripts <> " seeded scripts of " <> show differentialSteps
          <> " steps, granularity up to 1,024, both tilings, stale and repeated releases); every gated trace's digest equal to run 1's; the prototype placing every trace's requests exactly where the reference does, with the same usage at every sample; every timed and counting pass, on every side and repetition, placing exactly what its evidence pass placed; and every sampled search reconstruction choosing the reference's offset."
      else "**Failed** — the figures below are not trustworthy:"
  ]
    <> ["- " <> problem | problem ← problems]
    <> [""]

gateSummary ∷ [Result] → [String]
gateSummary results =
  [ "## Gates"
  , ""
  , "Requirement 7's four criteria against VMA default, computed as in run 1, for the pure best-fit reference and for the mutable prototype."
  , ""
  , "| Trace | Implementation | Refused bytes | Fragmentation | Median time | Placement under 5 µs |"
  , "| --- | --- | --- | --- | --- | --- |"
  ]
    <> concat
      [ [ "| " <> traceName (resultTrace r) <> " | Reference (pure best fit) | " <> intercalate " | " (map mark (resultVerdicts r)) <> " |"
        , "| " <> traceName (resultTrace r) <> " | Mutable prototype | " <> intercalate " | " (map mark (resultMutableVerdicts r)) <> " |"
        ]
      | r ← results
      ]
    <> [ ""
       , verdictLine "The reference" (all resultGatesMet results)
       , verdictLine "The mutable prototype" (all resultMutableGatesMet results)
       , ""
       ]
  where
    mark v = if verdictMet v then "Met" else "**Missed**"
    verdictLine who met =
      who <> (if met then " met every gate on every gated trace." else " missed at least one gate; a miss is reported, never waived.")

traceSection ∷ Bool → Result → [String]
traceSection gated result =
  [ "### " <> traceName trace
  , ""
  , "- SHA-256: `" <> traceDigest trace <> "`"
      <> maybe "" (\d → if d == traceDigest trace then " (as run 1)" else " (**differs from run 1**)") (Map.lookup (traceName trace) runOneDigests)
  , "- Capacity " <> show (traceCapacity trace) <> " bytes, seed " <> show (traceSeed trace)
      <> ", " <> show allocations <> " allocations, " <> show frees <> " frees, "
      <> show (length (traceCheckpoints trace)) <> " checkpoints"
  ]
    <> ["- Trace header: " <> note | note ← traceNotes trace]
    <> [ ""
       , "Per-operation figures (the gated method):"
       , ""
       , header
       , divider
       , row "Refused requests" (show . figuresRefusedCount . figuresOf)
       , row "Refused bytes" (\side → let f = figuresOf side in show (figuresRefusedBytes f) <> " (" <> fixed 2 (100 * refusedRate f) <> "%)")
       , row "Allocation median / p95 (ns)" (pair . figuresAllocations . figuresOf)
       , row "Free median / p95 (ns)" (pair . figuresFrees . figuresOf)
       , row "Placement median / p95 (ns)" (pair . figuresPlacements . figuresOf)
       , row "Allocation median, clock-corrected (ns)" (corrected allocationSamples)
       , row "Free median, clock-corrected (ns)" (corrected freeSamples)
       , ""
       , "Throughput diagnostics (windows and segments; not individual-operation latency):"
       , ""
       , header
       , divider
       , row "Whole trace, ns per executed operation" wholeTrace
       , row "Spread over repetitions: min / median / max" spread
       , row "Window means: median / p95 of windows" windowSummary
       , row "Allocation-only segments, ns per operation" (segmentMean Allocate)
       , row "Free-only segments, ns per operation" (segmentMean Free)
       , ""
       , "Heap, collection and search:"
       , ""
       ]
    <> heapLines
    <> [ ""
       , "| Checkpoint | Haskell fragmentation (reference and prototype) | VMA default | VMA MIN_MEMORY |"
       , "| --- | ---: | ---: | ---: |"
       ]
    <> zipWith4'
      (\label h v m → "| " <> label <> " | " <> fixed 4 h <> " | " <> fixed 4 v <> " | " <> fixed 4 m <> " |")
      (traceCheckpoints trace)
      (figuresFragmentation (figuresOf Haskell))
      (figuresFragmentation (figuresOf VmaBaseline))
      (figuresFragmentation (figuresOf VmaMinMemorySide))
    <> [ ""
       , "Fragmentation samples every " <> show sampleEvery <> " operations (" <> show (length (samplesOf Haskell)) <> " samples), Haskell minus VMA; the prototype's samples equal the reference's:"
       , ""
       , "| Against | Mean | Most positive (Haskell worse) | Most negative (Haskell better) | Samples over +2 points |"
       , "| --- | ---: | ---: | ---: | ---: |"
       , sampleRow "VMA default" VmaBaseline
       , sampleRow "VMA MIN_MEMORY" VmaMinMemorySide
       , ""
       , (if gated then "Gates for the reference (against VMA default):" else "Criteria for the reference against VMA default (diagnostic, not gated):")
       ]
    <> verdictLines True (resultVerdicts result)
    <> ["", if gated then "Gates for the mutable prototype (against VMA default):" else "Criteria for the mutable prototype against VMA default (diagnostic, not gated):"]
    <> verdictLines True (resultMutableVerdicts result)
    <> ["", "The reference against VMA MIN_MEMORY (diagnostic, never gated):"]
    <> verdictLines False (resultMinMemoryVerdicts result)
    <> [""]
  where
    trace = resultTrace result
    figuresOf side = resultGateFigures result Map.! side
    measuredOf side = resultMeasured result Map.! side
    kinds = map opKind (Unboxed.toList (traceKinds trace))
    allocations = length (filter (== Allocate) kinds)
    frees = length (filter (== Free) kinds)
    header = "| Figure | " <> intercalate " | " (map sideLabel sides) <> " |"
    divider = "| --- |" <> concat (replicate (length sides) " ---: |")
    row name f = "| " <> name <> " | " <> intercalate " | " (map f sides) <> " |"
    pair summary = fixed 1 (summaryMedian summary) <> " / " <> fixed 1 (summaryP95 summary) <> " (n = " <> show (summaryCount summary) <> ")"
    verdictLines strong vs =
      ["- " <> (if verdictMet v then "Met" else if strong then "**Missed**" else "Missed") <> ": " <> verdictCriterion v <> " — " <> verdictDetail v | v ← vs]
    placedOf side = evidencePlaced (measuredEvidence (measuredOf side))
    allocationSamples side =
      [measuredPerOperation (measuredOf side) Unboxed.! i | (i, k) ← zip [0 ..] kinds, k == Allocate]
    freeSamples side =
      let freed = freedBy trace (placedOf side)
       in [measuredPerOperation (measuredOf side) Unboxed.! i | i ← [0 .. length kinds - 1], freed Unboxed.! i]
    corrected samplesOf' side = fixed 1 (nearestRank 0.5 [x - clockOf result side | x ← samplesOf' side])
    repetitions = fromIntegral (length (measuredWindowTotals (measuredOf Haskell))) ∷ Double
    wholeTrace side = fixed 1 (throughputOf result side)
    spread side =
      let m = measuredOf side
          perRep = [t / fromIntegral (measuredExecuted m) | t ← measuredWindowTotals m]
       in fixed 1 (nearestRank 0 perRep) <> " / " <> fixed 1 (nearestRank 0.5 perRep) <> " / " <> fixed 1 (nearestRank 1 perRep)
    windowSummary side =
      let m = measuredOf side
          freed = freedBy trace (placedOf side)
          means =
            [ measuredWindows m Unboxed.! w / repetitions / fromIntegral executed
            | (w, (a, b)) ← zip [0 ..] (resultWindowBounds result)
            , let executed = executedIn trace freed a b
            , executed > 0
            ]
       in fixed 1 (nearestRank 0.5 means) <> " / " <> fixed 1 (nearestRank 0.95 means)
    segmentMean kind side =
      let m = measuredOf side
          freed = freedBy trace (placedOf side)
          chosen = [(i, a, b) | (i, (k, a, b)) ← zip [0 ..] (resultSegmentBounds result), k == kind]
          time = sum [measuredSegments m Unboxed.! i | (i, _, _) ← chosen]
          executed = sum [executedIn trace freed a b | (_, a, b) ← chosen]
       in if null chosen || executed == 0
            then "none"
            else fixed 1 (time / repetitions / fromIntegral executed) <> " (" <> show (length chosen) <> " runs)"
    heapLines =
      let searches = [found | (found, _) ← resultSearches result]
          examined = map (fromIntegral . searchExamined) searches
          ranges = map (fromIntegral . searchFreeRanges) searches
          runtimeLine side =
            "- " <> sideLabel side <> ": "
              <> maybe
                "n/a"
                ( \r →
                    fixed 1 (fromIntegral (runtimeAllocatedBytes r) / fromIntegral (max 1 (runtimeExecuted r)))
                      <> " bytes allocated per executed operation; "
                      <> fixed 2 (1000 * fromIntegral (runtimeCollections r) / fromIntegral (max 1 (runtimeExecuted r)))
                      <> " collections per 1,000 operations, "
                      <> fixed 1 (100 * fromIntegral (runtimeCollectionNanoseconds r) / fromIntegral (max 1 (runtimeTimedNanoseconds r)))
                      <> "% of windowed time; block footprint "
                      <> footprint side
                )
                (measuredRuntime (measuredOf side))
          footprint side = case Map.findWithDefault [] side (resultFootprints result) of
            [] → "n/a"
            samples → "peak " <> show (maximum samples) <> " bytes, mean " <> fixed 0 (fromIntegral (sum samples) / fromIntegral (length samples)) <> " bytes over " <> show (length samples) <> " samples"
          heapOf side = case measuredHeap (measuredOf side) of
            Just pass →
              let executed = fromIntegral (passExecuted pass) ∷ Double
               in "- " <> sideLabel side <> " heap: " <> show (passHeapChanges pass) <> " of " <> fixed 0 executed
                    <> " operations changed the C heap; peak " <> show (passHeapPeak pass) <> " bytes above the empty block, "
                    <> show (passHeapFinal pass) <> " at the end"
            Nothing → ""
       in map runtimeLine haskellSides
            <> [heapOf VmaBaseline, heapOf VmaMinMemorySide]
            <> [ "- Search (both Haskell sides decide alike): "
                   <> ( if null searches
                          then "n/a"
                          else
                            "free ranges examined per placement median "
                              <> fixed 0 (nearestRank 0.5 examined) <> ", p95 " <> fixed 0 (nearestRank 0.95 examined)
                              <> ", max " <> fixed 0 (maximum examined)
                              <> "; free ranges in the block median " <> fixed 0 (nearestRank 0.5 ranges)
                              <> ", p95 " <> fixed 0 (nearestRank 0.95 ranges)
                              <> " (" <> show (length searches) <> " sampled requests)"
                      )
               , "- Prototype's deepest bin-treap insertion path: " <> show (resultLongestWalk result) <> " levels"
               ]
    samplesOf side =
      let e = measuredEvidence (measuredOf side)
       in zipWith fragmentationOf (Unboxed.toList (evidenceSampleFree e)) (Unboxed.toList (evidenceSampleLargest e))
    sampleRow label side =
      let differences = zipWith (-) (samplesOf Haskell) (samplesOf side)
          points x = fixed 2 (100 * x)
       in if null differences
            then "| " <> label <> " | n/a | n/a | n/a | n/a |"
            else
              "| " <> label <> " | " <> points (sum differences / fromIntegral (length differences))
                <> " | " <> points (maximum differences) <> " | " <> points (minimum differences)
                <> " | " <> show (length (filter (> 0.02) differences)) <> " of " <> show (length differences) <> " |"

clockOf ∷ Result → SideName → Double
clockOf result side = if side `elem` haskellSides then fst (resultClocks result) else snd (resultClocks result)

-- | Mean nanoseconds per executed operation over the windowed repetitions.
throughputOf ∷ Result → SideName → Double
throughputOf result side =
  let m = resultMeasured result Map.! side
   in sum (measuredWindowTotals m) / fromIntegral (max 1 (length (measuredWindowTotals m))) / fromIntegral (measuredExecuted m)

zipWith4' ∷ (a → b → c → d → e) → [a] → [b] → [c] → [d] → [e]
zipWith4' f (a : as) (b : bs) (c : cs) (d : ds) = f a b c d : zipWith4' f as bs cs ds
zipWith4' _ _ _ _ _ = []

-- | One row per trace: the prototype against VMA and against the reference.
summaryTable ∷ String → [Result] → [String]
summaryTable title results =
  [ "#### Summary: " <> title
  , ""
  , "Medians are per-operation (the gated method); throughput is the windowed diagnostic. M is the mutable prototype, R the reference, V VMA default, V-MM VMA MIN_MEMORY."
  , ""
  , "| Trace | Allocation median M / V (M÷V) | Free median M / V (M÷V) | Throughput M / V (M÷V) | Throughput M ÷ V-MM | Throughput R ÷ M | Bytes per op R / M | GC share R / M | Deepest treap path | Refused bytes R=M / V / V-MM |"
  , "| --- | --- | --- | --- | ---: | ---: | --- | --- | ---: | --- |"
  ]
    <> map row results
    <> [""]
  where
    row result =
      let figuresOf side = resultGateFigures result Map.! side
          measured side = resultMeasured result Map.! side
          ratio a b = fixed 1 a <> " / " <> fixed 1 b <> " (" <> fixed 2 (a / b) <> "×)"
          median f side = summaryMedian (f (figuresOf side))
          runtimeOf side = measuredRuntime (measured side)
          bytes side = maybe "n/a" (\r → fixed 0 (fromIntegral (runtimeAllocatedBytes r) / fromIntegral (max 1 (runtimeExecuted r)))) (runtimeOf side)
          share side = maybe "n/a" (\r → fixed 1 (100 * fromIntegral (runtimeCollectionNanoseconds r) / fromIntegral (max 1 (runtimeTimedNanoseconds r))) <> "%") (runtimeOf side)
          throughput = throughputOf result
       in "| " <> traceName (resultTrace result)
            <> " | " <> ratio (median figuresAllocations HaskellMutable) (median figuresAllocations VmaBaseline)
            <> " | " <> ratio (median figuresFrees HaskellMutable) (median figuresFrees VmaBaseline)
            <> " | " <> ratio (throughput HaskellMutable) (throughput VmaBaseline)
            <> " | " <> fixed 2 (throughput HaskellMutable / throughput VmaMinMemorySide) <> "×"
            <> " | " <> fixed 1 (throughput Haskell / throughput HaskellMutable) <> "×"
            <> " | " <> bytes Haskell <> " / " <> bytes HaskellMutable
            <> " | " <> share Haskell <> " / " <> share HaskellMutable
            <> " | " <> show (resultLongestWalk result)
            <> " | " <> intercalate " / " [fixed 2 (100 * refusedRate (figuresOf side)) <> "%" | side ← [Haskell, VmaBaseline, VmaMinMemorySide]]
            <> " |"
