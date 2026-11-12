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
module Test.TerrainRuntime.Storage.Memory (spec, spec2) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM, forM_)
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
import Test.Support.Bounded (bounded)
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
