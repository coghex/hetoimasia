-- | What a job record really retains, against what it is charged.
--
-- A queued job is charged 'jobRecordBytes' of the control account from submission
-- until its outcome is retired. The figure is MEASURED, the way the store's own
-- constants are (see @Test.TerrainRuntime.Store.Memory@): the live heap a major
-- collection leaves heapAfter the largest valid jobs are queued, divided by the number
-- of jobs, must be within the figure. The measure is the whole of what a job adds
-- to the system (the job table entry, the queue entry, its grant in the shared
-- admission and the request it carries), not an estimate from field sizes.
--
-- The largest job of each kind is the one measured: a read of the most pages the
-- bound allows in validated mode, a write of the most pages a transaction stages
-- (its pages are the transaction's own, already accounted, and shared, so they add
-- nothing here), and an open (which carries a path and a configuration).
-- | What the service retains, against what it is charged.
--
-- THE MEASUREMENT (rewritten in round 5, after the CI runner showed the live-heap difference is noisy in BOTH directions
-- by several KiB, so that "noise only adds" is false and small rows could pass vacuously): the live heap a major
-- collection leaves is read twice, and the difference of two readings carries a FLOOR, the amplitude it shows when
-- nothing that matters happened between them ('noiseFloor', measured in the process). Every ASSERTED row therefore
-- has a SIGNAL far above that floor: either K instances held at once and divided (K raised until the total added is at
-- least 'signalMultiple' times the floor), or a standalone value built that many at a time, or a structure whose size
-- already is that large (a transfer buffer). A measured value of zero or below FAILS the row (it measured nothing); there
-- is no least-of-N and no clamp. A row that cannot reach that signal in the service itself is printed as an observation
-- and its bound is carried by a standalone row.
--
-- The standalone rows rebuild what the service holds per element, with the same constructors it uses: the job table
-- node, the queue's element and the admission's own entry for the grant (a job), the backing map's node and the volume
-- ledger's node (an entry and a closing record), the list cell and the grant (a kept failure).
module Test.TerrainRuntime.Storage.Memory (spec, spec2, spec3, spec4, floorSpec, rulesSpec, noiseFloor, signalMultiple) where

import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM, forM_, replicateM, void, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import Foreign.Marshal.Utils (fillBytes)
import qualified Data.Text as T
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (pageSize)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (admit)
import qualified Data.ByteString.Char8 as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.List
import Data.Word (Word32, Word64)
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats)
import Hetoimasia.Terrain.Runtime.Storage.Internal.File (Created (..), closeFile, createPrivate, unlinkFile)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Volume (profileOf, vpFilesystem)
import System.IO.Temp (withSystemTempDirectory)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..))
import System.IO.Unsafe (unsafePerformIO)
import System.Mem (performMajorGC)
import Test.Hspec
import Test.TerrainRuntime.Storage.Harness
import Test.TerrainRuntime.Storage.Lifecycle (withControlledService, Ctl (..))
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Data.Unique (newUnique)
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Store.Harness (H (..), identOf, smallSpec)

h0 ∷ H
h0 = newStoreH smallSpec

-- | THE LIVE-HEAP READING (round 10; the CI runner showed a pair of readings with NOTHING between them differing by half a megabyte).
-- A reading is the live bytes of the LAST collection the runtime reports. Another thread of the process that allocates between our
-- 'performMajorGC' and our read of the statistics makes a MINOR collection the last one, and a minor collection's live bytes are the young
-- generation's, not the heap's: the "reading" is then an artifact of a collection that was not ours. So (1) a reading is VALID only when the
-- last collection reported was a major one (its generation is the oldest), else it is discarded and retaken; (2) a measurement's reading is
-- SETTLED: valid readings are taken until two consecutive ones agree within 'settleTolerance' (residue of earlier examples, finalizers that
-- run after a collection and threads still ending are gone by then), bounded; a heap that does not settle FAILS the example with its readings
-- in the message. 'discardedReadings' counts the artifacts seen (printed, so a runner's behaviour is visible).
live ∷ IO Word64
live = liveWith (pure ())

-- | 'live', running a hook after every valid reading (the controls use it to remove a transient after the first reading).
liveWith ∷ IO () → IO Word64
liveWith afterReading = settle (0 ∷ Int) []
  where
    settle attempts seen
      | attempts >= maxSettleAttempts = error ("the live heap did not settle: " <> show (reverse seen) <> " after " <> show attempts <> " readings")
      | otherwise = do
          r ← validReading
          afterReading
          case seen of
            prev : _ | absDiff prev r <= settleTolerance → pure r
            _ → settle (attempts + 1) (r : seen)
    absDiff a b = if a > b then a - b else b - a

-- | One VALID reading: after a major collection whose details are the major collection's.
validReading ∷ IO Word64
validReading = go (0 ∷ Int)
  where
    go k = do
      performMajorGC
      st ← getRTSStats
      major ← majorGeneration
      if gcdetails_gen (gc st) >= major
        then pure (gcdetails_live_bytes (gc st))
        else do
          atomicModifyIORef' discardedReadings (\n → (n + 1, ()))
          if k >= 200 then error "no valid live-heap reading in 200 attempts: another thread keeps the last collection minor" else go (k + 1)

-- | The generation a major collection reports (the oldest), found once: the largest generation seen over several forced major collections.
majorGeneration ∷ IO Word32
majorGeneration = readIORef majorGenCell >>= maybe find pure
  where
    find = do
      gens ← replicateM 5 (performMajorGC >> (gcdetails_gen . gc <$> getRTSStats))
      let g = maximum gens
      writeIORef majorGenCell (Just g)
      pure g

majorGenCell ∷ IORef (Maybe Word32)
majorGenCell = unsafePerformIO (newIORef Nothing)
{-# NOINLINE majorGenCell #-}

-- | How many readings were discarded as artifacts of a minor collection (see 'live').
discardedReadings ∷ IORef Int
discardedReadings = unsafePerformIO (newIORef 0)
{-# NOINLINE discardedReadings #-}

-- | Two consecutive valid readings within this many bytes are a SETTLED heap.
settleTolerance ∷ Word64
settleTolerance = 1024

maxSettleAttempts ∷ Int
maxSettleAttempts = 60

mib' ∷ Word64
mib' = 1024 * 1024

-- ---------------------------------------------------------------------------
-- THE NOISE FLOOR: what a reading of the live heap does when nothing that matters has happened

-- | How many times the floor a row's signal must be.
signalMultiple ∷ Double
signalMultiple = 50

-- | THE FLOOR (round 10): the amplitude two SETTLED readings show when nothing that matters happened between them. The statistic is the
-- MEDIAN OF BATCH MAXIMA: seven batches, each the largest absolute difference over twenty pairs; the floor is the median of the seven.
-- Why: the old floor was one maximum over 300 pairs, so a single outlier reading set it for the whole process (8,768 where it is 1,208
-- on a quiet run); the maximum is the right statistic for an amplitude, and the median over batches is what keeps one spike (one
-- batch) from being the floor. The largest single difference over all batches is returned beside it and printed. Likewise for readings around a
-- change that leaves nothing behind (a list built, forced and dropped); the floor is the larger of the two.
noiseFloor ∷ IO (Double, Double, Double)
noiseFloor = do
  let aaOnce = do a ← live; b ← live; pure (abs (fromIntegral b - fromIntegral a ∷ Double))
      listOnce = do
        a ← live
        xs ← evaluate (map (* 2) [1 .. 5000 ∷ Int])
        _ ← evaluate (length xs)
        c ← live
        pure (abs (fromIntegral c - fromIntegral a ∷ Double))
      batches once = replicateM 7 (maximum <$> replicateM 20 once)
      median xs = Data.List.sort xs !! (length xs `div` 2)
  -- the first samples of each series are a warm-up (the collector's own state settling) and are discarded
  _ ← replicateM 5 aaOnce
  aa ← batches aaOnce
  _ ← replicateM 5 listOnce
  lst ← batches listOnce
  pure (max (median aa) (median lst), maximum (aa <> lst), median aa)

-- | The floor every row is held against, measured once in the process, at the start of the Memory group ('settleFloor').
theFloor ∷ Double
theFloor = unsafePerformIO ((\(f, _, _) → f) <$> noiseFloor)
{-# NOINLINE theFloor #-}

-- | Forces the floor before the first example of a describe runs: the first describe of the Memory group to run pays for the measurement.
settleFloor ∷ SpecWith a → SpecWith a
settleFloor = beforeAll_ (void (evaluate theFloor))

floorSpec ∷ Spec
floorSpec = describe "Storage backend: the live-heap reading's noise floor" $ settleFloor $
  it "is measured, with nothing between two readings and around a change that leaves nothing" $
    withEnv $ \env → do
      (fl, worst, aaMedian) ← noiseFloor
      discarded ← readIORef discardedReadings
      oc ← replicateM 100 $ do
        a ← live
        b ← openBacking env ident (hCfg h0)
        _ ← closeBacking (envSvc env) b
        c ← live
        pure (fromIntegral c - fromIntegral a ∷ Double)
      putStrLn ("memory floor | two settled readings, nothing between | median of batch maxima " <> show (round aaMedian ∷ Integer))
      putStrLn ("memory floor | the floor of this measurement (the larger of the two series' medians of batch maxima) " <> show (round fl ∷ Integer) <> " | the LARGEST single difference of any sample " <> show (round worst ∷ Integer) <> " | readings discarded as artifacts of a minor collection " <> show discarded)
      putStrLn ("memory floor | around an open and close (observation: it leaves garbage a later collection frees) | min " <> show (round (minimum oc) ∷ Integer) <> " max " <> show (round (maximum oc) ∷ Integer))
      putStrLn ("memory floor | the floor every asserted row must beat " <> show (round signalMultiple ∷ Integer) <> " times | " <> show (round theFloor ∷ Integer))

-- | The rule that no row passes vacuously, shown on values: a measurement of zero or below, and a signal below
-- 'signalMultiple' times the floor, each FAIL the row.
rulesSpec ∷ Spec
rulesSpec = describe "Storage backend: a memory row cannot pass without measuring something" $ settleFloor $ do
  let fails act = (try act ∷ IO (Either SomeException ())) >>= \r → either (const (pure ())) (const (expectationFailure "the row passed")) r
      big = ceiling (signalMultiple * theFloor) ∷ Int
  it "fails a row that measured zero, or less than zero (a clamp or a least-of-N would have passed it)" $ do
    fails (checkSignal "measured nothing" big 0)
    fails (checkSignal "measured less than nothing" big (-2184))
  -- THE CONTROLS OF ROUND 10: a transient of the size the CI runner showed (a pair of readings with nothing between them that differed by 497,536 bytes)
  -- must not change a row's verdict, and a real retention of the same size must (it is not hidden).
  it "does not let a transient that is live for one collection, of the size the CI runner showed, into a settled reading" $ do
    let spike = 497536 ∷ Int
    transient ← newIORef (Nothing ∷ Maybe BS.ByteString)
    base ← live
    -- the transient is live at the first valid reading and gone by the second: the readings disagree and the third settles WITHOUT it
    -- built by an IO action at run time (a pure `BS.replicate` of a constant would be floated into a top-level constant that stays live for the whole process)
    chunk ← BSI.create spike (\ptr → fillBytes ptr 7 spike)
    atomicModifyIORef' transient (\_ → (Just chunk, ()))
    _ ← evaluate =<< (maybe 0 BS.length <$> readIORef transient)
    r ← liveWith (atomicModifyIORef' transient (\_ → (Nothing, ())))
    -- a reading that had taken the transient in would be at least `spike` above the base
    (fromIntegral r - fromIntegral base ∷ Double) `shouldSatisfy` (< 50000)
  it "takes the median of independent samples: one sample carrying a transient of that size leaves the median alone and is reported UNSTABLE, and a retention in every sample is not hidden" $ do
    let spikeTotal = 497536 ∷ Double
        n = 24 ∷ Int
        calm = 400 ∷ Double
        spiked = calm + spikeTotal / fromIntegral n
        (med, spread, allowed) = sampleStats n [calm, spiked, calm]
    -- the row's VALUE is the median: the transient does not move it ...
    med `shouldBe` calm
    -- ... and the disagreement is a loud UNSTABLE failure of the row, never a changed figure
    spread `shouldSatisfy` (> allowed)
    -- a real retention (every sample carries it) IS the median and is stable: it is not hidden
    let (med2, spread2, allowed2) = sampleStats n [spiked, spiked, spiked]
    med2 `shouldBe` spiked
    spread2 `shouldSatisfy` (<= allowed2)
  it "fails a row whose signal is below the floor times the multiple, and passes one above it" $ do
    fails (checkSignal "signal too small" 10 1)
    checkSignal "signal far above" big 1.5

-- | The live heap that a build adds, per instance: read before, build (forced; it hands back an action that touches
-- what it built), read after, then the action run so the build stayed live across the second reading.
heldAdded ∷ Int → IO (IO Int) → IO Double
heldAdded n build = do
  heapBefore ← live
  touch ← build
  heapAfter ← live
  _ ← touch
  pure ((fromIntegral heapAfter - fromIntegral heapBefore) / fromIntegral n)

-- | Hold a built value LIVE (in a cell the caller's action reads) and force it. A thunk that has been evaluated drops
-- what it was built from, so a closure over the structures would not keep them alive across the second reading; a cell
-- does.
holdLive ∷ a → (a → Int) → IO (IO Int)
holdLive x size = do
  ref ← newIORef x
  _ ← evaluate (size x)
  pure (readIORef ref >>= \y → evaluate (size y))

-- | A row's signal must be far above the floor and its value above zero (zero or below measured nothing).
checkSignal ∷ String → Int → Double → Expectation
checkSignal name n m = do
  let signal = m * fromIntegral n
      need = signalMultiple * theFloor
  putStrLn ("memory signal | " <> name <> " | instances " <> show n <> " | signal " <> show (round signal ∷ Integer) <> " | floor " <> show (round theFloor ∷ Integer))
  m `shouldSatisfy` (> 0)
  signal `shouldSatisfy` (>= need)

-- | How many independent samples a row takes (odd: the median is one of them).
sampleCount ∷ Int
sampleCount = 3

-- | The fraction of a row's signal by which its samples may disagree (largest minus smallest total) before the row is UNSTABLE.
unstableFraction ∷ Double
unstableFraction = 0.25

-- | The runtime's stack chunk is 32 KiB: whether a thread's chunk is live at a reading or not moves the live heap by exactly that (seen as a
-- 31,000 to 32,000 byte step of one sample in a few rows on both hosts, and the reason the old repeats showed "one stack chunk" between
-- readings of one state). A row's samples may therefore differ by one chunk and a little (the median discards the odd sample); more than
-- that, or more than 'unstableFraction' of the signal, is UNSTABLE.
stackChunkQuantum ∷ Double
stackChunkQuantum = 40000

-- | ONE BAD READING CANNOT DECIDE A ROW (round 10): a discarded warm-up run, then an odd number of independent samples of the per-instance figure (each its own settled
-- readings and, for an in-service row, its own service); the MEDIAN is the row's value (not a minimum, not a maximum); the samples and their spread
-- are printed; and a row whose samples disagree by more than 'unstableFraction' of its signal (or of the smallest signal a row may have) fails
-- loudly as UNSTABLE, never as an over- or under-charge.
medianOf ∷ String → Int → IO Double → IO Double
medianOf name n sample = do
  -- the first run of a row in the process pays costs that are not the row's (a first-use initialization, a first evaluation of a shared
  -- constant): it is a WARM-UP and is discarded, like the noise floor's first samples; the samples after it are independent
  _ ← sample
  xs ← replicateM sampleCount sample
  let (med, spread, allowed) = sampleStats n xs
  putStrLn ("memory samples | " <> name <> " | " <> show (map (round ∷ Double → Integer) xs) <> " | spread of the totals " <> show (round spread ∷ Integer) <> " of " <> show (round allowed ∷ Integer) <> " allowed | median " <> show (round med ∷ Integer))
  when (spread > allowed) $
    expectationFailure ("UNSTABLE: the samples of " <> name <> " disagree by " <> show (round spread ∷ Integer) <> " bytes in total (more than " <> show (round allowed ∷ Integer) <> "): " <> show xs)
  pure med

-- | The median of the samples, the spread of their totals and the spread allowed (the pure part of 'medianOf').
sampleStats ∷ Int → [Double] → (Double, Double, Double)
sampleStats n xs = (med, spread, allowed)
  where
    med = Data.List.sort xs !! (length xs `div` 2)
    spread = (maximum xs - minimum xs) * fromIntegral n
    allowed = max stackChunkQuantum (unstableFraction * max (abs med * fromIntegral n) (signalMultiple * theFloor))

-- | A standalone row: instances raised until the total added is at least 'signalMultiple' times the floor.
sound ∷ String → Int → (Int → IO Double) → IO Double
sound name n0 at = go n0 (0 ∷ Int)
  where
    need = signalMultiple * theFloor
    go n tries = do
      m ← medianOf name n (at n)
      if m * fromIntegral n >= need || tries >= 4
        then checkSignal name n m >> pure m
        else go (min 60000 (max (n * 2) (ceiling (need / max m 1) * 2))) (tries + 1)

-- | One row of the table: what is retained, the charge that pays for it, the measured bytes, asserted within it.
row ∷ String → Word64 → Double → Expectation
row name charge measured = do
  putStrLn ("memory row | " <> name <> " | measured " <> show (round measured ∷ Integer) <> " | charged " <> show charge)
  measured `shouldSatisfy` (<= fromIntegral charge)

-- ---------------------------------------------------------------------------
-- Standalone builders: what the service holds per element, with the constructors it uses

-- | An admission with room for the standalone rows' many grants (the default control account holds 2,048 records).
bigBank ∷ A.EditBankConfig
bigBank = either (error . show) id (A.mkEditBankConfig A.defaultEditBankSpec {A.ebsControl = fromIntegral (256 * mib'), A.ebsEditBank = fromIntegral (1024 * mib')})

-- | @n@ control grants of @bytes@ each, in one admission (the admission's own entries per grant are part of the cost).
reserveN ∷ Int → Word64 → ([A.Grant], A.Admission)
reserveN n bytes = go (A.newAdmission bigBank) n []
  where
    go a 0 acc = (reverse acc, a)
    go a k acc = case A.reserve A.Foreground [A.ControlCredit bytes] a of
      Right (g, a') → go a' (k - 1 ∷ Int) (g : acc)
      Left _ → error "the control account of the standalone rows is too small"

-- | @n@ queued jobs of a work, as the service holds them: the job table node, the queue's element and the grant's
-- entry in the admission.
jobRow ∷ (Int → Work) → Int → IO Double
jobRow mk n = heldAdded n $ do
  let (grants, adm) = reserveN n (jobCharge (mk 1))
      jobs = Map.fromList [(fromIntegral i ∷ Word64, Job Nothing ident ExplicitWork (mk i) JQueued False g Nothing 0 False False (jobCharge (mk 1))) | (i, g) ← zip [1 .. n] grants]
      queue = Map.singleton ExplicitWork (Seq.fromList (map fromIntegral [1 .. n]) ∷ Seq.Seq Word64)
  holdLive (jobs, queue, adm) (\(j, q, a) → Map.size j + sum (map Seq.length (Map.elems q)) + fromIntegral (A.lgControlReserved (A.ledgers a)))

readWork ∷ Int → Work
readWork i = WRead (ReadSpec (hCfg h0) (PageNo (fromIntegral (1000 + i * 300))) 256 ReadValidated)

-- | An open with a path as long as a path may be, of its own.
openWork ∷ Int → Work
openWork i = WOpen (OpenSpec (BC.pack ('/' : replicate (maxDirectoryBytes - 1) (toEnum (100 + (i `mod` 100))))) ident (hCfg h0))

-- | The most results a running write holds (the 255 before the page it is held at), each instance its own.
resultsOf ∷ Int → [(PageNo, PageResult)]
resultsOf k = [(PageNo (fromIntegral (k * 1000 + i)), Wrote) | i ← [0 .. fromIntegral maxIoPages - 2 ∷ Int]]

-- | A staged write of the most pages a transaction may stage, each its own page and each of its own BYTES. The seed
-- makes every call a distinct value: without it GHC floats the page list out as one shared constant, every write would
-- share the same pages, and a service that kept them alive would not be seen to (the page numbers depend on the seed
-- through a division that is zero for any seed below a million, which the compiler cannot fold).
bigWriteAt ∷ Int → IO StagedWrite
bigWriteAt k = do
  let plan = either error id (planFor h0 1)
  (tid, s1) ← either (fail . show) pure (admit plan (hStore h0))
  sw ← either (fail . show) pure (stageWrite s1 tid)
  let zero = fromIntegral (k `div` 1000000) ∷ Word64
      pages = [(PageNo (100 + i + zero), BS.replicate pageSize (fromIntegral (fromIntegral i + k))) | i ← [0 .. fromIntegral maxIoPages - 1]]
  -- the pages are the transaction's own: built and forced here, so what the service adds is not counted with them
  _ ← evaluate (sum (map (BS.length . snd) pages) + sum [fromIntegral p | (PageNo p, _) ← pages])
  pure sw {swPages = pages}

bigWrite ∷ IO StagedWrite
bigWrite = bigWriteAt 0

-- | What a table of @n@ backing-sized records holds: a backing entry at its largest variant (the growth slot is the only
-- varying field: 'GReleasing' holds a 'Maybe' of the six-field 'PreparedGrowth', a pending reservation is present, the
-- entry is open and its grant is a real control grant), in the backing map; or the same entry MOVED into a closing
-- record whose native close has not returned; or a REPORTING closing record, which keeps nothing but the grant. Each
-- instance with its volume's node in the reserved-figure ledger (one per instance: conservative, the service shares
-- a volume's node) and the admission's entry for its grant.
data HeldKind = HeldBacking | HeldNative | HeldReporting | HeldHeldClose | HeldOpening

closingRow ∷ Env → HeldKind → Int → IO Double
closingRow env kind n = do
  fd ← (\fds → case fds of f : _ → f; [] → error "no descriptor") <$> fdHandles (envProbe env)
  u ← newUnique
  let (grants, adm) = reserveN n backingRecordBytes
      entryFor g i = Entry fd ident (fromIntegral i) (1024 * mib') (1024 * mib') (1024 * mib') mib' (GReleasing (Just (PreparedGrowth u (fromIntegral i) (fromIntegral i) (64 * mib') (128 * mib') (fromIntegral i)))) (Just (fromIntegral i)) EOpen 0 (1024 * mib') g
      ledger = Map.fromList [(fromIntegral i, fromIntegral i * 3) | i ← [1 .. n]] ∷ Map.Map Word64 Word64
      keyed ∷ (A.Grant → Int → v) → Map.Map Word64 v
      keyed f = Map.fromList [(fromIntegral i ∷ Word64, f g i) | (i, g) ← zip [1 .. n] grants]
  heldAdded n $ case kind of
    HeldBacking → holdLive (keyed entryFor, ledger, adm) (\(m, l, a) → Map.size m + Map.size l + fromIntegral (A.lgControlReserved (A.ledgers a)) + sum [fromIntegral (eReserved e) | e ← Map.elems m])
    HeldNative → holdLive (keyed (\g i → CrNative (entryFor g i)), ledger, adm) (\(m, l, a) → Map.size m + Map.size l + fromIntegral (A.lgControlReserved (A.ledgers a)) + sum [case c of CrNative e → fromIntegral (eReserved e); CrReporting _ → 0 | c ← Map.elems m])
    HeldReporting → holdLive (keyed (\g _ → CrReporting (Just g)), ledger, adm) (\(m, l, a) → Map.size m + Map.size l + fromIntegral (A.lgControlReserved (A.ledgers a)) + sum [case c of CrNative _ → 0; CrReporting _ → 1 | c ← Map.elems m])
    -- a HELD close (round 7), measured TOGETHER: its two records (the held record that carries the grant to the service's end, and
    -- the reporting record that carries none until the diagnostics return) and the volume-ledger node, against the ONE charge
    -- a RUNNING OPEN's presecured charge (round 8): its map node, the record and the one grant (bounded by the workers: at most two at once)
    HeldOpening → holdLive (keyed (\g _ → OpenRec g (Just fd)) ∷ Map.Map Word64 OpenRec, ledger, adm) (\(m, l, a) → Map.size m + Map.size l + fromIntegral (A.lgControlReserved (A.ledgers a)))
    HeldHeldClose → holdLive (keyed (\g i → Held (fromIntegral i) (fromIntegral i * 3) g fd), keyed (\_ _ → CrReporting Nothing) ∷ Map.Map Word64 ClosingRec, ledger, adm) (\(m, r, l, a) → Map.size m + Map.size r + Map.size l + fromIntegral (A.lgControlReserved (A.ledgers a)) + sum [fromIntegral (hBytes h) | h ← Map.elems m])

-- ---------------------------------------------------------------------------
-- The rows

-- | The live heap one retained outcome adds, per instance, over @n@ distinct instances held live.
outcomeRow ∷ (Int → Outcome) → Int → IO Double
outcomeRow mk n = heldAdded n $
  -- every instance walked completely ('forceOutcome', the walk the service applies before it retains an outcome): a
  -- standalone model must hold the evaluated value the service holds, not a lazier one
  holdLive (map (forceOutcome . mk) [1 .. n]) (\xs → sum [case o of Failed (HostFailure t) ns → T.length t + length ns; Cancelled ns → length ns; Written w → length (wrPages w); _ → 0 | o ← xs] + length xs)

-- | The retained failure at its largest: the longest text a defect keeps (of four-byte characters, the worst case of
-- the UTF-8 encoding) and the most notes a failure carries (each cleanup step yields at most two).
failedLargest ∷ Int → Outcome
failedLargest i = Failed (HostFailure (T.replicate maxHostFailureChars (T.singleton (toEnum (0x10000 + (i `mod` 1000)))))) [CleanupNote IoClose (Errno (fromIntegral (i + k))) | k ← [1 .. 4]]

cancelledLargest ∷ Int → Outcome
cancelledLargest i = Cancelled [CleanupNote IoUnlink (Errno (fromIntegral (i + k))) | k ← [1 .. 4]]

-- | The queued, running and finished write at its largest, @n@ at a time.
writeReportOf ∷ StagedWrite → Bool → Int → Outcome
writeReportOf sw failing i = Written (WriteReport (swTxn sw) ((if failing then [(PageNo (fromIntegral i), WriteFailedAt (StorageIo (IoFailure IoWrite (IoErrno (Errno 5)) (Just (PageNo (fromIntegral i))) (Just (fromIntegral i * 4096)) 17 4096)))] else [(PageNo (fromIntegral i), Wrote)]) <> [(PageNo (fromIntegral (i + k)), if failing then NotAttempted else Wrote) | k ← [1 .. maxIoPages - 1]]))

-- | The kept failure at its largest (a close that RAISED with the longest text), with its list cell and the admission's
-- entry for its grant, @n@ at a time.
keptRow ∷ Int → IO Double
keptRow n = heldAdded n $ do
  let (grants, adm) = reserveN n keptEntryBytes
      ks = [Kept (T.pack ("close of backing " <> show i)) (KeptClose (fromIntegral i) (CloseRaised (T.copy (T.replicate maxHostFailureChars (T.singleton (toEnum (0x10000 + (i `mod` 1000)))))))) g | (i, g) ← zip [1 .. n] grants]
  holdLive (ks, adm) (\(l, a) → length l + sum [T.length t | Kept _ (KeptClose _ (CloseRaised t)) _ ← l] + fromIntegral (A.lgControlReserved (A.ledgers a)))

spec ∷ Spec
spec = describe "Storage backend: the accounted job record is measured" $ settleFloor $ do
  it "is at least the live heap the largest queued read adds to the system" $ do
    perRead ← sound "queued read record" 200 (jobRow readWork)
    row "queued read record (standalone: job node, queue element, grant entry)" jobRecordBytes perRead
    -- the service itself, eight held: an OBSERVATION (its signal is below the floor), not an assertion
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      g ← addGate (envProbe env) (\op → case op of OpReadAt _ _ → True; _ → False)
      held ← forM [1, 2] (\i → submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo i) 1 ReadProbe >>= either (fail . show) pure)
      awaitReached g 2
      (readCost, ts) ← perJob 8 (\i → submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo (fromIntegral (1000 + i * 300))) 256 ReadValidated)
      putStrLn ("memory observation | eight queued reads in the service, per record | " <> show (round readCost ∷ Integer) <> " | not asserted: signal below the floor")
      openGate g
      forM_ (held <> ts) (awaitOutcome env)

  it "is at least the live heap the largest queued open adds to the system" $ do
    perOpen ← sound "queued open record" 200 (jobRow openWork)
    row "queued open record (standalone, a 512-byte path of its own)" jobRecordBytes perOpen
    withEnv $ \env → do
      g ← addGate (envProbe env) (== OpCreateFile)
      let spec' i = OpenSpec (BC.pack ('/' : replicate (maxDirectoryBytes - 1) (toEnum (100 + i)))) ident (hCfg h0)
      held ← forM [1, 2 ∷ Int] (\i → submitOpen (envSvc env) ExplicitWork (spec' i) >>= either (fail . show) pure)
      awaitReached g 2
      (opens, ts) ← perJob 8 (\i → submitOpen (envSvc env) ExplicitWork (spec' (i + 2)))
      putStrLn ("memory observation | eight queued opens in the service, per record | " <> show (round opens ∷ Integer) <> " | not asserted: signal below the floor")
      openGate g
      forM_ (held <> ts) (awaitOutcome env)

-- | The live heap that queuing @n@ jobs adds, per job, with both workers held so the jobs stay queued and no transfer
-- buffer is allocated; and the tickets, to retire. Used for OBSERVATIONS: eight records are a signal below the floor.
perJob ∷ Int → (Int → IO (Either StorageFailure Ticket)) → IO (Double, [Ticket])
perJob n submit = do
  heapBefore ← live
  ts ← forM [1 .. n] (\i → submit i >>= either (fail . show) pure)
  heapAfter ← live
  pure ((fromIntegral heapAfter - fromIntegral heapBefore) / fromIntegral n, ts)

-- | The rest of what the service holds. The transfer buffer and the result are structures of about a megabyte: their
-- signal is already far above the floor, and the rows assert it.
spec2 ∷ Spec
spec2 = describe "Storage backend: every other accounted figure is measured" $ settleFloor $ do
  it "charges a held transfer buffer at least the live heap it adds" $ do
    perRead ← medianOf "held transfer buffer" 2 $ withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      g ← addGate (envProbe env) (\op → case op of OpReadAt _ _ → True; _ → False)
      heapBefore ← live
      ts ← forM [1, 2 ∷ Int] (\i → submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo (fromIntegral (i * 1000))) 256 ReadProbe >>= either (fail . show) pure)
      awaitReached g 2
      heapAfter ← live
      openGate g
      forM_ ts (awaitOutcome env)
      pure ((fromIntegral heapAfter - fromIntegral heapBefore) / 2 ∷ Double)
    checkSignal "held transfer buffer" 2 perRead
    row "held 256-page read (buffer and record)" (transferBufferBytes 256 + jobRecordBytes) perRead

  it "charges a finished, untaken result at least the live heap it holds" $ do
    held ← medianOf "finished 256-page result" 1 $ withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      heapBefore ← live
      t ← submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo 1000) 256 ReadProbe >>= either (fail . show) pure
      bounded (atomically (awaitTicket (envSvc env) t))
      heapAfter ← live
      _ ← awaitOutcome env t
      pure (fromIntegral heapAfter - fromIntegral heapBefore ∷ Double)
    checkSignal "finished 256-page result" 1 held
    row "finished, untaken 256-page result (and its record)" (256 * resultPageBytes + jobRecordBytes) held

  it "charges a backing's record at least its largest entry, measured as a value, with the service's own places for it" $
    withEnv $ \env → do
      _ ← openBacking env ident (hCfg h0)
      standalone ← sound "backing entry" 200 (closingRow env HeldBacking)
      row "backing entry, largest variant (GReleasing (Just prepared), a pending reservation), standalone, with its backing-map node, its volume-ledger node and its grant's entry" backingRecordBytes standalone
      -- the service itself: an OBSERVATION (the signal of one backing is below the floor), not an assertion
      warm ← openBacking env (identOf 9 99) (hCfg h0)
      samples ← forM [1 .. 15 ∷ Int] $ \k → do
        heapBefore ← live
        b ← openBacking env (identOf (fromIntegral k) (fromIntegral (100 + k))) (hCfg h0)
        heapOpen ← live
        _ ← closeBacking (envSvc env) b
        pure (fromIntegral heapOpen - fromIntegral heapBefore ∷ Double)
      _ ← closeBacking (envSvc env) warm
      putStrLn ("memory observation | an open backing in the service, fifteen samples | min " <> show (round (minimum samples) ∷ Integer) <> " max " <> show (round (maximum samples) ∷ Integer) <> " | not asserted: the signal of one backing is below the floor")

spec3 ∷ Spec
spec3 = describe "Storage backend: every retained structure is charged and measured at its largest" $ settleFloor $ do
  it "a queued write of the most pages, charged the record and its report's bounded metadata at admission" $ do
    sw ← bigWrite
    perWrite ← sound "queued write" 200 (jobRow (const (WWrite sw)))
    row "queued write, 256 pages (standalone: the pages are the transaction's own and shared)" (jobCharge' (length (swPages sw))) perWrite

  it "a running write holding the most results, at the largest" $ do
    sw ← bigWrite
    -- the job's record plus the 255 results the worker holds at the last page, each instance its own
    let measure n = heldAdded n $ do
          let (grants, adm) = reserveN n (jobCharge (WWrite sw))
              jobs = Map.fromList [(fromIntegral i ∷ Word64, Job Nothing ident ExplicitWork (WWrite sw) JQueued False g Nothing 0 False False (jobCharge (WWrite sw))) | (i, g) ← zip [1 .. n] grants]
              results = [resultsOf k | k ← [1 .. n]]
          holdLive (jobs, results, adm) (\(j, rs, a) → Map.size j + sum (map length rs) + fromIntegral (A.lgControlReserved (A.ledgers a)))
    perRunning ← sound "running write" 20 measure
    row "running write, 255 results held (standalone: its record and the results)" (jobCharge' (length (swPages sw))) perRunning

  it "a finished write report with the most pages, and with its one failure, at the largest" $ do
    sw ← bigWrite
    full ← sound "finished write report, written" 20 (outcomeRow (writeReportOf sw False))
    failing ← sound "finished write report, first page failed" 20 (outcomeRow (writeReportOf sw True))
    row "finished write report, 256 pages written" (fromIntegral maxIoPages * writeEntryBytes + writeFailureBytes) full
    row "finished write report, first page failed, 255 not attempted" (fromIntegral maxIoPages * writeEntryBytes + writeFailureBytes) failing

  it "every other retained outcome, each added to the largest queued record and within the record's charge" $ do
    u ← newUnique
    record ← sound "largest queued open record" 200 (jobRow openWork)
    let backing i = Backing u (fromIntegral i) ident
        reservation i = Reservation (fromIntegral i) 4096 0 (BC.pack "ext4") 4096 (fromIntegral i)
        prepared' i = PreparedGrowth u (fromIntegral i) 1 (64 * mib') (128 * mib') (fromIntegral i)
    opened ← sound "retained Opened" 200 (outcomeRow (\i → Opened (backing i) (reservation i)))
    grown ← sound "retained GrowthPrepared" 200 (outcomeRow (\i → GrowthPrepared (prepared' i) (reservation i)))
    plain ← sound "retained Released or GrowthNoChange" 200 (outcomeRow (\i → if even i then Released else GrowthNoChange))
    row "largest open record plus a retained Opened" jobRecordBytes (record + opened)
    row "largest open record plus a retained GrowthPrepared" jobRecordBytes (record + grown)
    row "largest open record plus a retained Released or GrowthNoChange" jobRecordBytes (record + plain)

  it "a retained failure and a retained cancellation at their largest, added to the largest queued record" $ do
    record ← sound "largest queued open record" 200 (jobRow openWork)
    failed ← sound "retained Failed" 200 (outcomeRow failedLargest)
    cancelled ← sound "retained Cancelled" 200 (outcomeRow cancelledLargest)
    row "largest open record plus a retained Failed (a defect text of 256 four-byte characters, 4 notes)" jobRecordBytes (record + failed)
    row "largest open record plus a retained Cancelled (4 notes)" jobRecordBytes (record + cancelled)

  it "a kept failure at its largest, with its list cell and its grant's entry" $ do
    kept ← sound "kept failure" 200 keptRow
    row "kept failure, a close that raised with the longest text (standalone, per entry)" keptEntryBytes kept
    -- the service's list really does hold the most it may: 64 are kept and none was refused for its charge
    withControlledService' $ \env → do
      atomically (keepEvidence (envSvc env) "measure" [KeptClose (fromIntegral i) (CloseRaised (T.copy (T.replicate maxHostFailureChars (T.singleton (toEnum (0x10000 + i)))))) | i ← [1 .. maxKept]])
      snKept ← snEvidence <$> atomically (snapshotOf (envSvc env))
      snKept `shouldBe` maxKept

  it "validates the model against the service: finished write reports held UNTAKEN at once, produced by real jobs, within a tolerance of the standalone rows" $ do
    swModel ← bigWrite
    recordModel ← sound "write job record (model)" 200 (jobRow (const (WWrite swModel)))
    reportOk ← sound "write report, all written (model)" 20 (outcomeRow (writeReportOf swModel False))
    reportFirstFailed ← sound "write report, first page failed (model)" 20 (outcomeRow (writeReportOf swModel True))
    forM_ [("all written", False, reportOk), ("first page failed, 255 not attempted", True, reportFirstFailed)] $ \(label, failing, report) → do
      let k = 24 ∷ Int
      perJobBytes ← medianOf ("service: " <> label) k $ withEnv $ \env → do
        b ← openBacking env ident (hCfg h0)
        -- one write first, taken, so the service's one-time state is not counted
        counter ← newIORef (1 ∷ Int)
        let produce = do
              when failing (addRule (envProbe env) 1 (\op → case op of OpWriteAt _ _ → True; _ → False) (FailWith (Errno 5)))
              sw ← bigWriteAt =<< atomicModifyIORef' counter (\n → (n + 1, n))
              t ← submitWrite (envSvc env) b sw >>= either (fail . show) pure
              bounded (atomically (awaitTicket (envSvc env) t))
              -- the harness's own log of native calls (256 entries a write) is the TEST's memory, not the service's: cleared
              clearEvents (envProbe env)
              pure t
        warm ← produce
        _ ← awaitOutcome env warm
        -- BOTH readings are taken with the workers idle: the warm-up job's worker may still be inside its frame, holding the
        -- pages it wrote, and a first reading taken then would count what the second no longer does (a negative figure)
        workersIdle env
        heapBefore ← live
        ts ← forM [1 .. k] (const produce)
        -- the second reading is taken with the workers IDLE (blocked in their wait): a worker that has committed its
        -- job's outcome is still inside its frame for a moment, holding the work it ran, and one reading taken then
        -- counts that job's pages (a race of the test, seen once in 26 repeats: +1 MiB over 24 jobs)
        workersIdle env
        heapAfter ← live
        forM_ ts (awaitOutcome env)
        pure ((fromIntegral heapAfter - fromIntegral heapBefore) / fromIntegral k ∷ Double)
      let modelled = recordModel + report
      checkSignal ("service: " <> label) k perJobBytes
      row ("service, finished untaken write report (" <> label <> "), per job, " <> show k <> " held at once, the test's own pages dropped") (jobCharge' maxIoPages) perJobBytes
      putStrLn ("memory model | write report (" <> label <> ") | service " <> show (round perJobBytes ∷ Integer) <> " | standalone record + report " <> show (round modelled ∷ Integer))
      -- the model must not drift from the service: within 15 percent either way
      perJobBytes `shouldSatisfy` (<= modelled * 1.15)
      perJobBytes `shouldSatisfy` (>= modelled * 0.85)

  it "observes what a running write holds beyond the model: its results (the model) and the worker (a constant of the service)" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      sw ← bigWrite
      let heldAtPage n = do
            g ← addGateAfter (envProbe env) n (\op → case op of OpWriteAt _ _ → True; _ → False)
            heapBefore ← live
            t ← submitWrite (envSvc env) b sw >>= either (fail . show) pure
            awaitReached g 1
            heapAfter ← live
            openGate g
            _ ← awaitOutcome env t
            pure (fromIntegral heapAfter - fromIntegral heapBefore ∷ Double)
      -- warm the path once, so the first reading is not the first use
      _ ← heldAtPage 0
      -- the SAME state, read twenty times: the spread of its readings is the noise a worker's presence adds to the
      -- difference of two readings, and it is larger than the model's whole figure for the results
      atLast ← replicateM 20 (heldAtPage (fromIntegral maxIoPages - 1))
      atFirst ← replicateM 20 (heldAtPage 0)
      let sorted xs = Data.List.sort xs
          med xs = sorted xs !! (length xs `div` 2)
      putStrLn ("memory observation | running write held at its first page (the record and the worker, no results), 20 readings | min " <> show (round (minimum atFirst) ∷ Integer) <> " median " <> show (round (med atFirst) ∷ Integer) <> " max " <> show (round (maximum atFirst) ∷ Integer))
      putStrLn ("memory observation | running write held at its last page (the record, the worker and 255 results), 20 readings | min " <> show (round (minimum atLast) ∷ Integer) <> " median " <> show (round (med atLast) ∷ Integer) <> " max " <> show (round (maximum atLast) ∷ Integer))
      -- WHAT THE WORKER HOLDS THAT THE MODEL DOES NOT: the harness's own log of native calls (the probe records every one:
      -- 255 writes by the last page). Its per-entry cost is measured as a standalone value and taken off the difference.
      perLogEntry ← sound "the probe's log entry (a native write)" 200 (\n → heldAdded n (holdLive [OpWriteAt (fromIntegral i * 4096) 4096 | i ← [1 .. n]] length))
      let resultsByDifference = maximum atLast - maximum atFirst
          logShare = perLogEntry * fromIntegral (maxIoPages - 1)
      putStrLn ("memory observation | the 255 results by difference " <> show (round resultsByDifference ∷ Integer) <> " | less the probe's own log of the 255 native writes " <> show (round logShare ∷ Integer) <> " | leaves " <> show (round (resultsByDifference - logShare) ∷ Integer) <> " | the standalone model of the results " <> show (round (fromIntegral (length (resultsOf 1)) * (64 ∷ Double)) ∷ Integer))
      putStrLn ("memory observation | the model of the 255 results (standalone, signal above the floor) | " <> show (round (fromIntegral (length (resultsOf 1)) * (64 ∷ Double)) ∷ Integer) <> " | the spread of the in-service readings of one state is " <> show (round (maximum atLast - minimum atLast) ∷ Integer) <> ": not a measurement of the results")
      -- an OBSERVATION: nothing here is asserted (the readings of one state step by about one 32 KiB stack chunk from one
      -- repeat to the next: see the distribution in the repeat runs)

  it "a closing record, the entry moved and not copied (native close pending), and a reporting record (the grant only)" $
    withEnv $ \env → do
      _ ← openBacking env ident (hCfg h0)
      native ← sound "closing record, native close pending" 200 (closingRow env HeldNative)
      reporting ← sound "closing record, reporting" 200 (closingRow env HeldReporting)
      row "closing record, native close pending (the entry moved, per backing)" backingRecordBytes native
      -- what a reporting record retains: its map node and the one grant it carries until the transaction that deletes it
      row "closing record, reporting (the carried grant, per record)" backingRecordBytes reporting
      heldClose ← sound "held close, both records" 200 (closingRow env HeldHeldClose)
      row "held close: the held record and the reporting record together (one grant, per backing)" backingRecordBytes heldClose
      opening ← sound "running open's presecured charge" 200 (closingRow env HeldOpening)
      row "running open: the presecured charge (record, map node and grant, per open)" backingRecordBytes opening
  where
    jobCharge' n = jobRecordBytes + fromIntegral n * writeEntryBytes + writeFailureBytes
    -- the service's end reports the kept failures: this example measures them and ignores that report
    withControlledService' body = withControlledService (\env ctl → body env >> ctlBegin ctl >> void (ctlResult ctl))

-- ---------------------------------------------------------------------------
-- What the service retains is ITS OWN (round 6): a ByteString is a view

-- | A short path that is a VIEW into a fresh two-megabyte buffer of its own: a service that keeps the view keeps the
-- buffer. The path names a directory that does not exist, so an open of it fails at once.
sliceOf ∷ Int → BS.ByteString
sliceOf k = BS.take 48 (BC.pack ('/' : "no-such-dir-" <> show k <> "/" <> replicate (2 * 1024 * 1024) (toEnum (97 + k `mod` 20))))

-- | The whole of the retention rows of round 6. Each asserts a per-job retention within the record's charge: with the
-- copy undone the service retains megabytes a job (the control fails it by two orders of magnitude, far above the floor).
spec4 ∷ Spec
spec4 = describe "Storage backend: what the service retains of what it is handed is its own" $ settleFloor $ do
  it "a directory that is a short slice of a large buffer costs the copy and not the buffer: K finished, untaken opens held at once" $ do
    let k = 24 ∷ Int
    perJobBytes ← medianOf "retention: finished untaken open" k $ withEnv $ \env → do
      let produce n = do
            t ← submitOpen (envSvc env) ExplicitWork (OpenSpec (sliceOf n) ident (hCfg h0)) >>= either (fail . show) pure
            bounded (atomically (awaitTicket (envSvc env) t))
            pure t
      warm ← produce 0
      _ ← awaitOutcome env warm
      workersIdle env
      heapBefore ← live
      ts ← forM [1 .. k] produce
      workersIdle env
      heapAfter ← live
      forM_ ts (awaitOutcome env)
      pure ((fromIntegral heapAfter - fromIntegral heapBefore) / fromIntegral k ∷ Double)
    putStrLn ("memory retention | finished untaken open, a 48-byte slice of a 2 MiB buffer, per job, " <> show k <> " held at once | " <> show (round perJobBytes ∷ Integer) <> " | charged " <> show jobRecordBytes)
    perJobBytes `shouldSatisfy` (<= fromIntegral jobRecordBytes)

  it "a directory that is a short slice of a large buffer costs the copy and not the buffer: K queued opens" $ do
    let k = 8 ∷ Int
    perJobBytes ← medianOf "retention: queued open" k $ withEnv $ \env → do
      g ← addGate (envProbe env) (== OpCreateFile)
      held ← forM [1, 2 ∷ Int] (\i → submitOpen (envSvc env) ExplicitWork (OpenSpec (sliceOf (100 + i)) ident (hCfg h0)) >>= either (fail . show) pure)
      awaitReached g 2
      heapBefore ← live
      ts ← forM [1 .. k] (\i → submitOpen (envSvc env) ExplicitWork (OpenSpec (sliceOf (200 + i)) ident (hCfg h0)) >>= either (fail . show) pure)
      heapAfter ← live
      openGate g
      forM_ (held <> ts) (awaitOutcome env)
      pure ((fromIntegral heapAfter - fromIntegral heapBefore) / fromIntegral k ∷ Double)
    putStrLn ("memory retention | queued open, a 48-byte slice of a 2 MiB buffer, per job, " <> show k <> " queued | " <> show (round perJobBytes ∷ Integer) <> " | charged " <> show jobRecordBytes)
    perJobBytes `shouldSatisfy` (<= fromIntegral jobRecordBytes)

  it "a qualified-filesystem name that is a short slice of a large buffer costs the copy: K configurations held at once" $ do
    let viewOf k = BS.take 4 (BC.pack (replicate (2 * 1024 * 1024) (toEnum (97 + k `mod` 20))))
        config k = either (error . show) id (mkStorageConfig [viewOf k, viewOf (k + 1)] minHeadroomBytes)
    _ ← evaluate (length (scQualified (config 0)))
    let k = 24 ∷ Int
    perConfig ← medianOf "retention: configuration" k $ do
      heapBefore ← live
      cs ← forM [1 .. k] (\i → evaluate (config (100 + i)))
      heapAfter ← live
      _ ← evaluate (sum (map (length . scQualified) cs))
      pure ((fromIntegral heapAfter - fromIntegral heapBefore) / fromIntegral k ∷ Double)
    putStrLn ("memory retention | storage configuration, two 4-byte names viewed from 2 MiB buffers, per configuration, " <> show k <> " held | " <> show (round perConfig ∷ Integer))
    perConfig `shouldSatisfy` (<= 1024)

  it "a filesystem name that is a short slice of a large buffer (a mount table's text) costs the copy: K profiles held at once" $
    withSystemTempDirectory "hetoimasia-terrain-profile" $ \dir → do
      made ← createPrivate productionSeam (BC.pack dir) 1 (const (pure ()))
      c ← either (fail . show) pure made
      -- the native adapter reports the type name as a view into a fresh two-megabyte buffer, as the mount table's lines are
      let viewOf k = BS.take 4 (BC.pack (replicate (2 * 1024 * 1024) (toEnum (97 + k `mod` 20))))
          native k = posixNative {nativeStatFs = \fd → fmap (\f → f {nfTypeName = viewOf k}) <$> nativeStatFs posixNative fd}
          profile k = profileOf productionSeam {seamNative = native k} (crFd c) >>= either (\e → fail (show e)) pure
      _ ← profile 0
      let k = 24 ∷ Int
      perProfile ← medianOf "retention: volume profile" k $ do
        heapBefore ← live
        ps ← forM [1 .. k] profile
        heapAfter ← live
        _ ← evaluate (sum (map (BS.length . vpFilesystem) ps))
        pure ((fromIntegral heapAfter - fromIntegral heapBefore) / fromIntegral k ∷ Double)
      putStrLn ("memory retention | volume profile, a 4-byte filesystem name viewed from a 2 MiB buffer, per profile, " <> show k <> " held | " <> show (round perProfile ∷ Integer))
      -- the copy of four bytes and the profile's own words: a few hundred bytes, never the buffer
      perProfile `shouldSatisfy` (<= 1024)
      _ ← unlinkFile productionSeam (BC.pack dir) (crName c)
      void (closeFile productionSeam (crFd c))

-- | Wait until both workers are blocked in their wait for work (observed, no timer): nothing of a finished job is held by a
-- worker's frame any more.
workersIdle ∷ Env → IO ()
workersIdle env = workerThreads (envProbe env) >>= mapM_ awaitBlockedInStm
