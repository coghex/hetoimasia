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
module Test.TerrainRuntime.Storage.Memory (spec, spec2, spec3) where

import Control.Concurrent.STM (atomically)
import Control.Exception (evaluate)
import Control.Monad (forM, forM_, void)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (pageSize)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (admit)
import qualified Data.ByteString.Char8 as BC
import Data.Word (Word64)
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..))
import System.Mem (performMajorGC)
import Test.Hspec
import Test.TerrainRuntime.Storage.Harness
import Test.TerrainRuntime.Storage.Lifecycle (withControlledService, Ctl (..))
import Data.Unique (newUnique)
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThreadOpening)
import Test.TerrainRuntime.Store.Harness (H (..), identOf, smallSpec)

h0 ∷ H
h0 = newStoreH smallSpec

live ∷ IO Word64
live = performMajorGC >> performMajorGC >> (gcdetails_live_bytes . gc <$> getRTSStats)

-- | The live heap that queuing @n@ jobs adds, per job, with both workers held so the
-- jobs stay queued and no transfer buffer is allocated; and the tickets, to retire.
perJob ∷ Int → (Int → IO (Either StorageFailure Ticket)) → IO (Double, [Ticket])
perJob n submit = do
  heapBefore ← live
  ts ← forM [1 .. n] (\i → submit i >>= either (fail . show) pure)
  heapAfter ← live
  pure ((fromIntegral heapAfter - fromIntegral heapBefore) / fromIntegral n, ts)

spec ∷ Spec
spec = describe "Storage backend: the accounted job record is measured" $ do
  it "is at least the live heap the largest queued read adds to the system" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      g ← addGate (envProbe env) (\op → case op of OpReadAt _ _ → True; _ → False)
      held ← forM [1, 2] (\i → submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo i) 1 ReadProbe >>= either (fail . show) pure)
      awaitReached g 2
      (readCost, ts) ← perJob 8 (\i → submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo (fromIntegral (1000 + i * 300))) 256 ReadValidated)
      putStrLn ("measured bytes per queued read record: " <> show readCost <> " (accounted " <> show jobRecordBytes <> ")")
      readCost `shouldSatisfy` (<= fromIntegral jobRecordBytes)
      openGate g
      forM_ (held <> ts) (awaitOutcome env)

  it "is at least the live heap the largest queued open adds to the system" $
    withEnv $ \env → do
      g ← addGate (envProbe env) (== OpCreateFile)
      -- a directory that does not exist, as long as a path may be and a path of each job's own:
      -- the opens fail once released
      let spec' i = OpenSpec (BC.pack ('/' : replicate (maxDirectoryBytes - 1) (toEnum (100 + i)))) ident (hCfg h0)
      held ← forM [1, 2 ∷ Int] (\i → submitOpen (envSvc env) ExplicitWork (spec' i) >>= either (fail . show) pure)
      awaitReached g 2
      (opens, ts) ← perJob 8 (\i → submitOpen (envSvc env) ExplicitWork (spec' (i + 2)))
      putStrLn ("measured bytes per queued open record: " <> show opens <> " (accounted " <> show jobRecordBytes <> ")")
      opens `shouldSatisfy` (<= fromIntegral jobRecordBytes)
      openGate g
      forM_ (held <> ts) (awaitOutcome env)

-- | The rest of what the service holds, each charged at what it holds and measured the same way: the
-- transfer buffer of a held read, the result of a finished read nobody has taken, and a backing's record.
spec2 ∷ Spec
spec2 = describe "Storage backend: every other accounted figure is measured" $ do
  it "charges a held transfer buffer at least the live heap it adds" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      g ← addGate (envProbe env) (\op → case op of OpReadAt _ _ → True; _ → False)
      heapBefore ← live
      ts ← forM [1, 2 ∷ Int] (\i → submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo (fromIntegral (i * 1000))) 256 ReadProbe >>= either (fail . show) pure)
      awaitReached g 2
      heapAfter ← live
      let perRead = (fromIntegral heapAfter - fromIntegral heapBefore) / 2 ∷ Double
          accounted = fromIntegral (transferBufferBytes 256 + jobRecordBytes)
      putStrLn ("measured bytes per held 256-page read (buffer and record): " <> show perRead <> " (accounted " <> show accounted <> ")")
      perRead `shouldSatisfy` (<= accounted)
      openGate g
      forM_ ts (awaitOutcome env)

  it "charges a finished, untaken result at least the live heap it holds" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      heapBefore ← live
      t ← submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo 1000) 256 ReadProbe >>= either (fail . show) pure
      bounded' (atomically (awaitTicket (envSvc env) t))
      heapAfter ← live
      let held = fromIntegral heapAfter - fromIntegral heapBefore ∷ Double
          accounted = fromIntegral (256 * resultPageBytes + jobRecordBytes)
      putStrLn ("measured bytes of a held 256-page result (and its record): " <> show held <> " (accounted " <> show accounted <> ")")
      held `shouldSatisfy` (<= accounted)
      _ ← awaitOutcome env t
      pure ()

  it "charges a backing's record at least the live heap it adds, with a growth prepared and a reservation pending" $
    withEnv $ \env → do
      -- one open first, so the figures are the records' and not one-time initialisation, then three measured
      warm ← openBacking env (identOf 9 99) (hCfg h0)
      heapBefore ← live
      bs ← forM [ident, ident2, identOf 3 11] (\i → openBacking env i (hCfg h0))
      heapOpen ← live
      -- and the largest variant of the entry: a reservation left pending
      addRuleAfter (envProbe env) 1 1 (== OpStatFile) (OverAllocated (10 * 1024 * 1024))
      addRule (envProbe env) 1 (== OpSetFileLength (64 * 1024 * 1024)) (FailWith (Errno 5))
      case bs of
        b : _ → () <$ (submitGrowth (envSvc env) b (64 * 1024 * 1024) (128 * 1024 * 1024) >>= either (fail . show) pure >>= awaitOutcome env)
        [] → pure ()
      _ ← closeBacking (envSvc env) warm
      heapPending ← live
      let opened = (fromIntegral heapOpen - fromIntegral heapBefore) / 3 ∷ Double
          pendingCost = fromIntegral heapPending - fromIntegral heapOpen ∷ Double
      putStrLn ("measured bytes per open backing: " <> show opened <> ", and for a pending reservation: " <> show pendingCost <> " (accounted " <> show backingRecordBytes <> " for both)")
      (opened + pendingCost) `shouldSatisfy` (<= fromIntegral backingRecordBytes)
  where
    bounded' = bounded

-- ---------------------------------------------------------------------------
-- Every retained structure, charged and measured at its LARGEST instance

mib' :: Word64
mib' = 1024 * 1024

-- | A staged write of the most pages a transaction may stage, each its own page.
bigWrite :: IO StagedWrite
bigWrite = do
  let plan = either error id (planFor h0 1)
  (tid, s1) <- either (fail . show) pure (admit plan (hStore h0))
  sw <- either (fail . show) pure (stageWrite s1 tid)
  let pages = [(PageNo (100 + i), BS.replicate pageSize (fromIntegral i)) | i <- [0 .. fromIntegral maxIoPages - 1]]
  -- the pages are the transaction's own: built and forced here, so what the service adds is not counted with them
  _ <- evaluate (sum (map (BS.length . snd) pages))
  pure sw {swPages = pages}

-- | The live heap a thing adds, held live while it is counted.
heapAdded :: IO a -> IO (a, Double)
heapAdded act = do
  heapBefore <- live
  r <- act
  heapAfter <- live
  pure (r, fromIntegral heapAfter - fromIntegral heapBefore)

-- | One row of the table: what is retained, the charge that pays for it, the measured bytes, asserted within it.
row :: String -> Word64 -> Double -> Expectation
row name charge measured = do
  putStrLn ("memory row | " <> name <> " | measured " <> show (round measured :: Integer) <> " | charged " <> show charge)
  measured `shouldSatisfy` (<= fromIntegral charge)

-- | The retained failure at its largest: the longest text a defect keeps (of four-byte characters, the worst case of
-- the UTF-8 encoding) and the most notes a failure carries (each cleanup step yields at most two).
failedLargest :: Int -> Outcome
failedLargest i = Failed (HostFailure (T.replicate maxHostFailureChars (T.singleton (toEnum (0x10000 + i))))) [CleanupNote IoClose (Errno (fromIntegral (i + k))) | k <- [1 .. 4]]

cancelledLargest :: Int -> Outcome
cancelledLargest i = Cancelled [CleanupNote IoUnlink (Errno (fromIntegral (i + k))) | k <- [1 .. 4]]

-- | The live heap one retained outcome adds, per instance, over 200 distinct instances held live.
standalone :: (Int -> Outcome) -> IO (Double, ())
standalone mk = do
  let n = 200 :: Int
  heapBefore <- live
  let xs = map mk [1 .. n]
  _ <- evaluate (sum [case o of Failed (HostFailure t) ns -> T.length t + length ns; Cancelled ns -> length ns; Written w -> length (wrPages w); _ -> 0 | o <- xs])
  heapAfter <- live
  _ <- evaluate (length xs)
  pure ((fromIntegral heapAfter - fromIntegral heapBefore) / fromIntegral n, ())

spec3 :: Spec
spec3 = describe "Storage backend: every retained structure is charged and measured at its largest" $ do
  it "a queued write of the most pages, charged the record and its report's bounded metadata at admission" $
    withEnv $ \env -> do
      b <- openBacking env ident (hCfg h0)
      sw <- bigWrite
      g <- addGate (envProbe env) (\op -> case op of OpReadAt _ _ -> True; _ -> False)
      held <- forM [1, 2] (\i -> submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo i) 1 ReadProbe >>= either (fail . show) pure)
      awaitReached g 2
      (t, cost) <- heapAdded (submitWrite (envSvc env) b sw >>= either (fail . show) pure)
      row "queued write, 256 pages" (jobCharge' (length (swPages sw))) cost
      openGate g
      forM_ (t : held) (awaitOutcome env)

  it "a running write holding the most results, and its finished report, at the largest" $
    withEnv $ \env -> do
      b <- openBacking env ident (hCfg h0)
      sw <- bigWrite
      -- held at the last page: the 255 results heapBefore it are what the worker holds
      g <- addGateAfter (envProbe env) (fromIntegral maxIoPages - 1) (\op -> case op of OpWriteAt _ _ -> True; _ -> False)
      (t, cost) <- heapAdded $ do
        t <- submitWrite (envSvc env) b sw >>= either (fail . show) pure
        awaitReached g 1
        pure t
      row "running write, 255 results held" (jobCharge' (length (swPages sw))) cost
      openGate g
      (_, done) <- heapAdded (bounded (atomically (awaitTicket (envSvc env) t)))
      putStrLn ("memory row | finished write report change (informational) | " <> show (round done :: Integer))
      _ <- awaitOutcome env t
      pure ()

  it "a finished write report with the most pages, and with its one failure, at the largest" $ do
    sw <- bigWrite
    let report i failing = Written (WriteReport (swTxn sw) ((if failing then [(PageNo (fromIntegral i), WriteFailedAt (StorageIo (IoFailure IoWrite (IoErrno (Errno 5)) (Just (PageNo (fromIntegral i))) (Just (fromIntegral i * 4096)) 17 4096)))] else [(PageNo (fromIntegral i), Wrote)]) <> [(PageNo (fromIntegral (i + k)), if failing then NotAttempted else Wrote) | k <- [1 .. maxIoPages - 1]]))
    (full, _) <- standalone (\i -> report i False)
    (failing, _) <- standalone (\i -> report i True)
    row "finished write report, 256 pages written" (fromIntegral maxIoPages * writeEntryBytes + writeFailureBytes) full
    row "finished write report, first page failed, 255 not attempted" (fromIntegral maxIoPages * writeEntryBytes + writeFailureBytes) failing

  it "every other retained outcome, each added to the largest queued record and within the record's charge" $
    withEnv $ \env -> do
      -- the largest record a job holds: an open with a path as long as a path may be, measured queued
      g <- addGate (envProbe env) (== OpCreateFile)
      let spec' i = OpenSpec (BC.pack ('/' : replicate (maxDirectoryBytes - 1) (toEnum (100 + i)))) ident (hCfg h0)
      held <- forM [1, 2 :: Int] (\i -> submitOpen (envSvc env) ExplicitWork (spec' i) >>= either (fail . show) pure)
      awaitReached g 2
      (record, ts) <- perJob 8 (\i -> submitOpen (envSvc env) ExplicitWork (spec' (i + 2)))
      u <- newUnique
      let backing i = Backing u (fromIntegral i) ident
          reservation i = Reservation (fromIntegral i) 4096 0 (BC.pack "ext4") 4096 (fromIntegral i)
          prepared' i = PreparedGrowth u (fromIntegral i) 1 (64 * mib') (128 * mib') (fromIntegral i)
      -- an Opened outcome, its backing's own record being charged separately (the row of the backing's record)
      (opened, _) <- standalone (\i -> Opened (backing i) (reservation i))
      (grown, _) <- standalone (\i -> GrowthPrepared (prepared' i) (reservation i))
      (plain, _) <- standalone (\i -> if even i then Released else GrowthNoChange)
      row "largest open record plus a retained Opened" jobRecordBytes (record + opened)
      row "largest open record plus a retained GrowthPrepared" jobRecordBytes (record + grown)
      row "largest open record plus a retained Released or GrowthNoChange" jobRecordBytes (record + plain)
      openGate g
      forM_ (held <> ts) (awaitOutcome env)

  it "a retained failure and a retained cancellation at their largest, added to the largest queued record" $
    withEnv $ \env -> do
      -- the largest record a job holds: an open with a path as long as a path may be (measured as in the first
      -- example), to which the largest retained outcome is added
      g <- addGate (envProbe env) (== OpCreateFile)
      let spec' i = OpenSpec (BC.pack ('/' : replicate (maxDirectoryBytes - 1) (toEnum (100 + i)))) ident (hCfg h0)
      held <- forM [1, 2 :: Int] (\i -> submitOpen (envSvc env) ExplicitWork (spec' i) >>= either (fail . show) pure)
      awaitReached g 2
      (opens, ts) <- perJob 8 (\i -> submitOpen (envSvc env) ExplicitWork (spec' (i + 2)))
      (failed, _) <- standalone failedLargest
      (cancelled, _) <- standalone cancelledLargest
      row "largest open record plus a retained Failed (a defect text of 256 four-byte characters, 4 notes)" jobRecordBytes (opens + failed)
      row "largest open record plus a retained Cancelled (4 notes)" jobRecordBytes (opens + cancelled)
      openGate g
      forM_ (held <> ts) (awaitOutcome env)

  it "a kept failure, and a closing record that is moved and not copied" $
    withControlledService' $ \env -> do
      -- the evidence list is full: 64 kept failures, each charged
      (_, kept) <- heapAdded (atomically (keepEvidence (envSvc env) "measure" [CleanupNote IoClose (Errno (fromIntegral i)) | i <- [1 .. maxKept]]))
      row "kept failure (per entry, the list full)" keptEntryBytes (kept / fromIntegral maxKept)
      -- the claim moves a backing's entry into its closing record whole: held at the native close the heap holds one
      -- entry, not two
      b <- openBacking env ident (hCfg h0)
      g <- addGate (envProbe env) (== OpCloseFile)
      heapBefore <- live
      withOwnedThreadOpening (openGate g) (void (closeBacking (envSvc env) b)) $ \_ waitClose -> do
        awaitReached g 1
        heapAfter <- live
        row "closing record (the entry moved, per backing)" backingRecordBytes (max 0 (fromIntegral heapAfter - fromIntegral heapBefore))
        openGate g
        waitClose
  where
    jobCharge' n = jobRecordBytes + fromIntegral n * writeEntryBytes + writeFailureBytes
    -- the service's end reports the kept failures: this example measures them and ignores that report
    withControlledService' body = withControlledService (\env ctl -> body env >> ctlBegin ctl >> void (ctlResult ctl))
