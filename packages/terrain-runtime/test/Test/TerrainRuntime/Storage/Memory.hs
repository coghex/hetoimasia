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
module Test.TerrainRuntime.Storage.Memory (spec) where

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
import Test.TerrainRuntime.Store.Harness (H (..), smallSpec)

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
