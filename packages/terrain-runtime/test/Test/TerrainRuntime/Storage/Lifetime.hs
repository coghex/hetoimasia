-- | The queue, the two workers, scheduling, cancellation and the lifetime of a
-- backing: what is held until a native call has actually returned, how a close
-- drains, and that one arena's late work never reaches another's file.
--
-- A job is held inside its native call by a gate on its exact offset, so the order
-- in which a lone worker takes the queue is the order of the calls the seam records,
-- and "held until it returned" is read from the accounting while the gate is closed.
-- No example sleeps: every wait is for an event a worker announced.
module Test.TerrainRuntime.Storage.Lifetime (spec) where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (ErrorCall (..), ExceptionWithContext (..), SomeException, throwIO, tryWithContext)
import Control.Monad (forM, forM_)
import qualified Data.ByteString.Char8 as BC
import System.IO.Temp (withSystemTempDirectory)
import Data.Maybe (isJust, isNothing)
import qualified Foreign.C.Error as C
import Hetoimasia.Foundation.Log (callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext)
import Hetoimasia.Foundation.Worker (closeWorkerGroup, withWorkerGroup)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (admit)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..), pageSize)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (pageFileOffset)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread)
import Test.TerrainRuntime.Storage.Harness
import Test.TerrainRuntime.Store.Harness (H (..), smallSpec)

er ∷ C.Errno → Errno
er (C.Errno c) = Errno (fromIntegral c)

h0 ∷ H
h0 = newStoreH smallSpec

offOf ∷ Word → NativeOp
offOf n = OpReadAt (either (error . show) id (pageFileOffset (hCfg h0) (PageNo (fromIntegral n)))) pageSize

-- | A raw read of one page: no page was ever written, so a probe read is the
-- cheapest job there is.
readJob ∷ Env → Backing → WorkClass → Word → Int → IO (Either StorageFailure Ticket)
readJob env b cls n count = submitRead (envSvc env) b cls (hCfg h0) (PageNo (fromIntegral n)) count ReadProbe

view ∷ Env → IO ServiceView
view env = atomically (serviceView (envSvc env))

ledger ∷ Env → IO A.Ledger
ledger env = A.ledgers <$> readTVarIO (envAdmission env)

ok ∷ Show f ⇒ Either f a → IO a
ok = either (fail . show) pure

spec ∷ Spec
spec = describe "Storage backend: queue, workers and lifetime" $ do
  it "runs two jobs and queues eight, refuses the next, and holds no buffer for a queued job" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      g ← addGate (envProbe env) isRead
      first2 ← forM [100, 101] (\n → readJob env b ExplicitWork n 1 >>= ok)
      awaitReached g 2
      queued ← forM [102 .. 109] (\n → readJob env b ExplicitWork n 1 >>= ok)
      readJob env b ExplicitWork 110 1 >>= (`shouldBe` Left (BusyNow QueueFull)) . fmap (const ())
      v ← view env
      (svQueued v, svRunning v, svRecords v) `shouldBe` (8, 2, 10)
      l ← ledger env
      -- only the two running transfers hold a buffer: one staging page and one result copy each
      (A.lgStagingForeground l, A.lgCacheBacked l) `shouldBe` (2 * fromIntegral pageSize, 2 * fromIntegral pageSize)
      A.lgControlReserved l `shouldBe` 10 * jobRecordBytes
      openGate g
      forM_ (first2 <> queued) (awaitOutcome env)

  it "lets reads, and unrelated work, proceed while one mutating job holds a native call, and refuses a second" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      let plan = either error id (planFor h0 1)
      g ← addGate (envProbe env) (\op → case op of OpWriteAt _ _ → True; _ → False)
      (tid, s1) ← either (fail . show) pure (admit plan (hStore h0))
      sw ← either (fail . show) pure (stageWrite s1 tid)
      t1 ← submitWrite (envSvc env) b sw >>= ok
      awaitReached g 1
      -- a second mutating job is refused; a read on the other worker completes
      submitWrite (envSvc env) b sw >>= (`shouldBe` Left (BusyNow MutationActive)) . fmap (const ())
      rt ← readJob env b ExplicitWork 300 1 >>= ok
      awaitOutcome env rt >>= (`shouldSatisfy` isPages)
      counter ← newTVarIO (0 ∷ Int)
      atomically (modifyTVar' counter (+ 1))
      readTVarIO counter `shouldReturn` 1
      (svMutating <$> view env) `shouldReturn` True
      openGate g
      awaitOutcome env t1 >>= (`shouldSatisfy` isWritten)
      (svMutating <$> view env) `shouldReturn` False

  it "serves explicit work first, maintenance after a bounded run of it and camera last, with none starved" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      g1 ← addGate (envProbe env) (== offOf 100)
      g2 ← addGate (envProbe env) (== offOf 101)
      j1 ← readJob env b ExplicitWork 100 1 >>= ok
      j2 ← readJob env b ExplicitWork 101 1 >>= ok
      awaitReached g1 1
      awaitReached g2 1
      cam ← readJob env b CameraWork 200 1 >>= ok
      mnt ← readJob env b MaintenanceWork 201 1 >>= ok
      exs ← forM [210 .. 214] (\n → readJob env b ExplicitWork n 1 >>= ok)
      -- one worker is let go; the other stays held, so the queue is taken in dispatch order
      openGate g1
      forM_ (cam : mnt : exs) (awaitOutcome env)
      evs ← events (envProbe env)
      let order = [o | OpReadAt o _ ← evs]
          expected = [o | n ← [100, 101] <> [210, 211, 212, 201, 213, 214, 200], OpReadAt o _ ← [offOf n]]
      drop 2 order `shouldBe` drop 2 expected
      openGate g2
      mapM_ (awaitOutcome env) [j1, j2]

  it "keeps the protected staging from camera reads, and lets them go once it is free" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      -- a foreground transaction holds all but a page of the share camera work may use
      grant ← atomically $ do
        a ← readTVar (envAdmission env)
        r ← either (const (error "reserve")) pure (A.reserve A.Foreground [A.StagingCredit (4 * 1024 * 1024 - 2048)] a)
        writeTVar (envAdmission env) (snd r)
        pure (fst r)
      cam ← readJob env b CameraWork 200 1 >>= ok
      ex ← readJob env b ExplicitWork 201 1 >>= ok
      awaitOutcome env ex >>= (`shouldSatisfy` isPages)
      v ← view env
      svQueued v `shouldBe` 1
      atomically (modifyTVar' (envAdmission env) (A.release grant))
      awaitOutcome env cam >>= (`shouldSatisfy` isPages)

  it "cancels a queued job at once, a running job only at a safe point, and a finished job not at all" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      g ← addGate (envProbe env) isRead
      [r1, r2] ← forM [100, 101] (\n → readJob env b ExplicitWork n 2 >>= ok)
      awaitReached g 2
      q ← readJob env b ExplicitWork 120 1 >>= ok
      cancelTicket (envSvc env) q >>= (`shouldBe` CancelledBeforeDispatch)
      awaitOutcome env q >>= (`shouldBe` Cancelled [])
      (svRecords <$> view env) `shouldReturn` 2
      -- a running job: the request releases nothing until the call has returned
      l0 ← ledger env
      cancelTicket (envSvc env) r1 >>= (`shouldBe` CancelRequested)
      l1 ← ledger env
      l1 `shouldBe` l0
      openGate g
      awaitOutcome env r1 >>= (`shouldBe` Cancelled [])
      awaitOutcome env r2 >>= (`shouldSatisfy` isPages)
      done ← readJob env b ExplicitWork 130 1 >>= ok
      bounded (atomically (awaitTicket (envSvc env) done))
      cancelTicket (envSvc env) done >>= (`shouldBe` CancelTooLate)
      awaitOutcome env done >>= (`shouldSatisfy` isPages)

  it "closes only after a gated native call has returned and its borrowers have retired" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      g ← addGate (envProbe env) isRead
      rd ← readJob env b ExplicitWork 100 1 >>= ok
      awaitReached g 1
      closed ← newEmptyMVar
      withOwnedThread (closeBacking (envSvc env) b >>= putMVar closed) $ \_ wait → do
        -- the close has asked the call to stop and is waiting for it: nothing is closed
        bounded (atomically (backingView (envSvc env) b >>= \v → check (maybe False bvClosing v)))
        evs ← events (envProbe env)
        length [() | OpCloseFile ← evs] `shouldBe` 0
        tryReadMVar closed >>= (`shouldSatisfy` isNothing)
        openGate g
        wait
      report ← readMVar closed
      crClosed report `shouldBe` True
      evs ← events (envProbe env)
      let at op = length (takeWhile (/= op) evs)
      at (offOf 100) `shouldSatisfy` (< at OpCloseFile)
      discardTicket (envSvc env) rd
      openFds (envProbe env) >>= (`shouldBe` [])

  it "closes a backing whose queue is full: the queued jobs are withdrawn, the running calls finish and nothing leaks" $
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      g ← addGate (envProbe env) isRead
      running ← forM [100, 101] (\n → readJob env b ExplicitWork n 1 >>= ok)
      awaitReached g 2
      queued ← forM [102 .. 109] (\n → readJob env b ExplicitWork n 1 >>= ok)
      closed ← newEmptyMVar
      withOwnedThread (closeBacking (envSvc env) b >>= putMVar closed) $ \_ wait → do
        -- the queued jobs settle at once; the close waits for the two calls held in flight
        bounded (atomically (serviceView (envSvc env) >>= \v → check (svQueued v == 0)))
        tryReadMVar closed >>= (`shouldSatisfy` isNothing)
        openGate g
        wait
      readMVar closed >>= (`shouldSatisfy` crClosed)
      -- every record was retired by the close: nothing is left to take
      forM_ (running <> queued) (\t → withOutcome (envSvc env) t pure >>= (`shouldSatisfy` isNothing))
      (svRecords <$> view env) `shouldReturn` 0
      evs ← events (envProbe env)
      -- the queued reads never reached a native call
      length [() | OpReadAt _ _ ← evs] `shouldBe` 2

  it "waits for a borrower, such as a reader pin, before closing" $
    withEnv (\env → do
      b ← openBacking env ident (hCfg h0)
      entered ← newEmptyMVar
      release ← newEmptyMVar
      closed ← newEmptyMVar
      -- a borrower (a reader pin) holds the backing; the close waits for it
      withOwnedThread (() <$ withUse (envSvc env) b (putMVar entered () >> readMVar release)) $ \_ waitBorrow → do
        readMVar entered
        withOwnedThread (closeBacking (envSvc env) b >>= putMVar closed) $ \_ waitClose → do
          bounded (atomically (backingView (envSvc env) b >>= \v → check (maybe False bvClosing v)))
          evs ← events (envProbe env)
          length [() | OpCloseFile ← evs] `shouldBe` 0
          putMVar release ()
          waitBorrow
          waitClose
      readMVar closed >>= (`shouldSatisfy` crClosed))

  it "never closes twice: a failed close is reported once and a descriptor number reused later cannot be reached by an old handle" $
    withEnv $ \env → do
      a ← openBacking env ident (hCfg h0)
      addRule (envProbe env) 1 (== OpCloseFile) (FailWith (er C.eIO))
      rep ← closeBacking (envSvc env) a
      (crClosed rep, crCloseError rep) `shouldBe` (True, Just (er C.eIO))
      -- a second close finds nothing to close and makes no native call
      closeBacking (envSvc env) a >>= (`shouldSatisfy` (not . crClosed))
      evs ← events (envProbe env)
      length [() | OpCloseFile ← evs] `shouldBe` 1
      -- another file takes the freed descriptor number; the old handle is refused
      b ← openBacking env ident2 (hCfg h0)
      readJob env a ExplicitWork 5 1 >>= (`shouldBe` Left BackingClosed) . fmap (const ())
      stale ← readJob env b ExplicitWork 5 1 >>= ok
      awaitOutcome env stale >>= (`shouldSatisfy` isPages)
      withOutcome (envSvc env) stale pure >>= (`shouldSatisfy` isNothing)

  it "closes one of two arenas while the other's call is held, and the late work of neither reaches the other" $
    withEnv $ \env → do
      a ← openBacking env ident (hCfg h0)
      b ← openBacking env ident2 (hCfg h0)
      g ← addGate (envProbe env) isRead
      rb ← readJob env b ExplicitWork 100 1 >>= ok
      awaitReached g 1
      rep ← closeBacking (envSvc env) a
      crClosed rep `shouldBe` True
      (svBackings <$> view env) `shouldReturn` 1
      openGate g
      awaitOutcome env rb >>= (`shouldSatisfy` isPages)
      readJob env b ExplicitWork 101 1 >>= ok >>= awaitOutcome env >>= (`shouldSatisfy` isPages)

  it "keeps the primary failure and the cleanup failure of a close, and a defect stops the service" $ do
    -- the scopes outside the failing one are the harness's own, so the evidence is read
    -- at the service's boundary: its temporary directory is made outside the scope
    r ← withSystemTempDirectory "hetoimasia-terrain-storage" $ \dir → do
      cfg ← testConfigFor dir defaultOptions
      probe ← newProbe
      bank ← either (fail . show) pure (A.mkEditBankConfig A.defaultEditBankSpec)
      admission ← newTVarIO (A.newAdmission bank)
      withWorkerGroup $ \group → tryWithContext $
        withStorageService (StoragePorts admission group quiet (seamFor probe) cfg) $ \svc → do
          t ← submitOpen svc ExplicitWork (OpenSpec (BC.pack dir) ident (hCfg h0))
          ticket ← either (fail . show) pure t
          bounded (atomically (awaitTicket svc ticket))
          _ ← withOutcome svc ticket pure
          addRule probe 1 (== OpCloseFile) (FailWith (er C.eIO))
          throwIO (ErrorCall "the body failed")
    case r of
      Left (ExceptionWithContext ctx e) → do
        show (e ∷ SomeException) `shouldContain` "the body failed"
        length (cleanupFailuresInContext ctx) `shouldBe` 1
      Right () → expectationFailure "the body's failure was lost"
    withEnv $ \env → do
      b ← openBacking env ident (hCfg h0)
      addRule (envProbe env) 1 isRead Throw
      t ← readJob env b ExplicitWork 100 1 >>= ok
      awaitOutcome env t >>= (`shouldSatisfy` \o → case o of Failed (HostFailure _) _ → True; _ → False)
      (svDefect <$> view env) >>= (`shouldSatisfy` isJust)
      readJob env b ExplicitWork 101 1 >>= (`shouldBe` Left ServiceStopped) . fmap (const ())

  it "refuses to start when a worker cannot be started, leaving nothing running" $
    withWorkerGroup $ \group → do
      _ ← closeWorkerGroup group
      bank ← either (fail . show) pure (A.mkEditBankConfig A.defaultEditBankSpec)
      admission ← newTVarIO (A.newAdmission bank)
      cfg ← either (fail . show) pure (mkStorageConfig defaultQualified minHeadroomBytes)
      r ← tryWithContext (withStorageService (StoragePorts admission group quietLogger productionSeam cfg) (\_ → pure ()))
      case r of
        Left (ExceptionWithContext _ e) → show (e ∷ SomeException) `shouldContain` "WorkerNotStarted"
        Right () → expectationFailure "started on a closed worker group"
  where
    quietLogger = mkLogger defaultLogFilter (callbackSink (\_ → pure ()))
    isRead op = case op of OpReadAt _ _ → True; _ → False
    isPages o = case o of Pages _ → True; _ → False
    isWritten o = case o of Written _ → True; _ → False
