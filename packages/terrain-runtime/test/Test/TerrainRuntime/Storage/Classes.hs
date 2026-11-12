-- | The four classes of defect round 1 of review found, each as a class and not as its instances.
--
-- (A) The probe's fixture: every example reaches a filler or a reservation only through a verified 'Fixture'.
-- (B) The growth state machine: every gate point of a growth against every event injected there, and every event
--     in the prepared and releasing states, each outcome one the state table (Service, 'GrowthSlot') allows, with the
--     reported reservation always equal to the file's physical allocation afterwards.
-- (C) Every native resource has an owner at every instant, exceptions included: for each native call at each stage
--     it occurs in, a typed failure, a thrown exception and a cancellation, then the process's open descriptors are
--     back to the baseline, no backing is tracked without a descriptor or the reverse, and the allocation matches.
-- (D) Every charge is released on every path: reviewer reproductions as direct examples and random sequences of
--     submit, cancel, discard, take, close and shutdown with the shared admission back to its starting figures.
module Test.TerrainRuntime.Storage.Classes (spec) where

import Control.Concurrent (throwTo)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (AsyncException (UserInterrupt), try, SomeException)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import qualified Data.ByteString.Char8 as BC
import Data.IORef
import Data.List (isInfixOf)
import Data.Word (Word64)
import qualified Foreign.C.Error as C
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Foundation.Log (callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Worker (GroupReport (..), closeWorkerGroup, withWorkerGroup)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo (..), StoreIdentity (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (admit)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import System.IO (hFlush, stdout)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread)
import Test.TerrainRuntime.Storage.Fixture
import Test.TerrainRuntime.Storage.Harness
import Test.TerrainRuntime.Storage.Lifecycle (checkInvariants)
import Hetoimasia.Terrain.Runtime.Storage.Internal.File (Created (..), closeFile, createPrivate, unlinkFile)
import Test.TerrainRuntime.Storage.ProbeSpec (ExhaustionBad (..), FillError (..), GrowthBad (..), RewriteBad (..), exhaustionVerdict, fillWith, growthVerdict, probeCases, rewriteVerdict, withFillerWith, withMeter)
import Test.TerrainRuntime.Store.Harness (H (..), smallSpec)

mib :: Word64
mib = 1024 * 1024

h0 :: H
h0 = newStoreH smallSpec

eio :: Errno
eio = let C.Errno c = C.eIO in Errno (fromIntegral c)

openFdCount :: IO Int
openFdCount = do
  proc' <- doesDirectoryExist "/proc/self/fd"
  length <$> listDirectory (if proc' then "/proc/self/fd" else "/dev/fd")

view :: Env -> IO ServiceView
view env = atomically (serviceView (envSvc env))

backing' :: Env -> Backing -> IO BackingView
backing' env b = atomically (backingView (envSvc env) b) >>= maybe (fail "no backing") pure

allocatedOf :: Env -> IO Word64
allocatedOf env = do
  fds <- fdHandles (envProbe env)
  case fds of
    fd : _ -> either (fail . show) (pure . nsAllocated) =<< nativeStat posixNative fd
    [] -> fail "no descriptor"

-- | The reservation the service reports (held on the volume) equals the file's physical allocation, to the
-- filesystem's accounting of one block.
-- | The service never reports less than the file physically holds, and when it reports more, the excess is a pending
-- reservation (accounted, recoverable by an explicit release): the state after an effect whose result was lost.
reportedCoversPhysical :: Env -> IO ()
reportedCoversPhysical env = do
  held <- sum . svReserved <$> view env
  phys <- allocatedOf env
  hasPending <- atomically (snapshotOf (envSvc env)) >>= \sn -> pure (any (isJust . bsPending) (snBackings sn))
  (held, phys, hasPending) `shouldSatisfy` \(h, p, pend) -> p <= h + 4096 && (h <= p + 4096 || pend)

reportedMatchesPhysical :: Env -> IO ()
reportedMatchesPhysical env = do
  held <- sum . svReserved <$> view env
  phys <- allocatedOf env
  (held, phys) `shouldSatisfy` \(h, p) -> p <= h + 4096 && h <= p + 4096

-- | The per-volume reserved figures: every one back at zero once every backing is closed.
volumeLedgerClear :: Env -> IO ()
volumeLedgerClear env = (Map.elems . svReserved <$> view env) >>= (`shouldSatisfy` all (== 0))

isReserve, isStat :: NativeOp -> Bool
isReserve op = case op of OpReserveRange _ _ -> True; _ -> False
isStat op = op == OpStatFile

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Storage backend: the classes round 1 of review found" $ do
  fixtureClass
  fillerClass
  growthClass
  sweepClass
  startupClass
  chargeClass

-- ---------------------------------------------------------------------------
-- (A) the probe's fixture

-- | The probe's filler proves its preconditions (round 4): it ends only on the platform's out-of-space result, and the
-- exhausted state is measured before any action that claims it.
fillerClass :: Spec
fillerClass = describe "(A) the probe's filler" $ do
  it "ends only on the platform's out-of-space result: a reservation that fails for another reason, or a length that cannot be established, is a failure and never exhaustion" $
    withSystemTempDirectory "hetoimasia-terrain-filler" $ \dir -> do
      made <- createPrivate productionSeam (BC.pack dir) 1 (const (pure ()))
      c <- either (fail . show) pure made
      let errno x = let C.Errno n = x in Errno (fromIntegral n)
          failsWith e = posixNative {nativeReserve = \_ _ _ -> pure (Left e)}
      -- reasons that are not capacity: EIO, EINVAL, an unsupported allocation
      forM_ [C.eIO, C.eINVAL, C.eNOTSUP, C.eOPNOTSUPP, C.eNOSYS, C.eDQUOT] $ \e ->
        fillWith (failsWith (errno e)) (crFd c) >>= (`shouldBe` Left (FillUnexpected (errno e)))
      -- a length that cannot be established after a reservation that succeeded
      fillWith posixNative {nativeReserve = \_ _ n -> pure (Right n), nativeSetLength = \_ _ -> pure (Left (errno C.eIO))} (crFd c)
        >>= (`shouldBe` Left (FillLength (errno C.eIO)))
      -- the platform's out-of-space result after three whole chunks ends the fill, and the bytes are what was taken
      calls <- newIORef (0 :: Int)
      let capacity = posixNative
            { nativeReserve = \_ _ n -> do
                k <- atomicModifyIORef' calls (\i -> (i + 1, i))
                pure (if k < 3 then Right n else Left (errno C.eNOSPC))
            , nativeSetLength = \_ _ -> pure (Right ())
            }
      fillWith capacity (crFd c) >>= (`shouldBe` Right (3 * 64 * mib))
      _ <- unlinkFile productionSeam (BC.pack dir) (crName c)
      _ <- closeFile productionSeam (crFd c)
      listDirectory dir >>= (`shouldBe` [])
  it "cannot let an example claim exhaustion that was not measured: a filler that is refused at once, on a volume with plenty free, fails before the action runs" $
    withSystemTempDirectory "hetoimasia-terrain-filler2" $ \dir -> do
      fxe <- acquireFixture (Policy maxBound False) dir
      fx <- either (\e -> fail ("fixture refused: " <> show e)) pure fxe
      -- the adapter answers out-of-space for the very first reservation: the fill "ends" having taken nothing
      let immediately = posixNative {nativeReserve = \_ _ _ -> pure (Left (Errno (let C.Errno n = C.eNOSPC in fromIntegral n)))}
      ran <- newIORef False
      r <- try (withMeter fx (\m -> withFillerWith immediately fx m (\_ -> writeIORef ran True)))
      -- it fails for THE reason: the residue the meter reports is far above the bound the refused growth relies on
      either (\e -> show (e :: SomeException)) (const "passed") r `shouldSatisfy` ("ResidueTooLarge" `isInfixOf`)
      readIORef ran >>= (`shouldBe` False)
  it "a platform that would still allocate one more block after the fill is not exhausted: the precondition fails before the action runs" $
    withSystemTempDirectory "hetoimasia-terrain-filler4" $ \dir -> do
      fxe <- acquireFixture (Policy maxBound False) dir
      fx <- either (\e -> fail ("fixture refused: " <> show e)) pure fxe
      calls <- newIORef (0 :: Int)
      -- three whole chunks, the halving down to one block refused (fifteen refusals), then the single block ASKED AFTER
      -- THE FILL is granted
      let granting = posixNative
            { nativeReserve = \_ _ n -> do
                k <- atomicModifyIORef' calls (\i -> (i + 1, i))
                pure (if k < 3 || k >= 18 then Right n else Left (Errno (let C.Errno e = C.eNOSPC in fromIntegral e)))
            , nativeSetLength = \_ _ -> pure (Right ())
            }
      ran <- newIORef False
      r <- try (withMeter fx (\m -> withFillerWith granting fx m (\_ -> writeIORef ran True)))
      either (\e -> show (e :: SomeException)) (const "passed") r `shouldSatisfy` ("OneMoreBlockGranted" `isInfixOf`)
      readIORef ran >>= (`shouldBe` False)
  it "judges the exhausted state by the platform's own statement: one more block must be refused with the out-of-space result, and the residue stays below the bound the refused growth relies on (the 32 MiB APFS reports passes)" $ do
    let enospc = Errno (let C.Errno n = C.eNOSPC in fromIntegral n)
        ioErr = Errno (let C.Errno n = C.eIO in fromIntegral n)
        mib' = 1024 * 1024 :: Word64
    exhaustionVerdict (Left enospc :: Either Errno ()) 0 `shouldBe` Right ()
    exhaustionVerdict (Left enospc :: Either Errno ()) 33681408 `shouldBe` Right ()
    exhaustionVerdict (Left enospc :: Either Errno ()) (64 * mib') `shouldBe` Left (ResidueTooLarge (64 * mib'))
    exhaustionVerdict (Right 4096 :: Either Errno Word64) 0 `shouldBe` Left OneMoreBlockGranted
    exhaustionVerdict (Left ioErr :: Either Errno ()) 0 `shouldBe` Left (OneMoreBlockFailedOther ioErr)
  it "judges the rewrite by what it did: a changed allocation fails, and so does a consumed residue; an unchanged allocation with the space intact passes" $ do
    let mib' = 1024 * 1024 :: Word64
    rewriteVerdict (64 * mib') (64 * mib') (32 * mib') (32 * mib') `shouldBe` Right ()
    -- the space coming back (a lazy reclaim) or a small reading difference is not a consumption
    rewriteVerdict (64 * mib') (64 * mib') (32 * mib') (40 * mib') `shouldBe` Right ()
    rewriteVerdict (64 * mib') (64 * mib') (32 * mib') (30 * mib') `shouldBe` Right ()
    -- a rewrite that had to allocate: the backing grew, or the residue was consumed
    rewriteVerdict (64 * mib') (96 * mib') (32 * mib') (32 * mib') `shouldBe` Left (AllocationChanged (64 * mib') (96 * mib'))
    rewriteVerdict (64 * mib') (64 * mib') (32 * mib') 0 `shouldBe` Left (SpaceConsumed (fromIntegral (32 * mib')))
  it "judges a refused growth by what it left: the length and the allocated bytes of the file are what they were" $ do
    growthVerdict (64, 64) (64, 64) `shouldBe` Right ()
    growthVerdict (64, 64) (128, 64) `shouldBe` Left (GrowthChanged (64, 64) (128, 64))
    growthVerdict (64, 64) (64, 128) `shouldBe` Left (GrowthChanged (64, 64) (64, 128))
  it "a filler whose reservation fails for a reason unrelated to capacity cannot yield a passing example" $
    withSystemTempDirectory "hetoimasia-terrain-filler3" $ \dir -> do
      fxe <- acquireFixture (Policy maxBound False) dir
      fx <- either (\e -> fail ("fixture refused: " <> show e)) pure fxe
      let broken = posixNative {nativeReserve = \_ _ _ -> pure (Left (Errno (let C.Errno n = C.eIO in fromIntegral n)))}
      ran <- newIORef False
      before' <- openFdCount
      r <- try (withMeter fx (\m -> withFillerWith broken fx m (\_ -> writeIORef ran True)))
      (either (\e -> const True (e :: SomeException)) (const False) r) `shouldBe` True
      readIORef ran >>= (`shouldBe` False)
      -- the probe's own descriptors are not left held on its failure path (the filler's and the meter's are closed)
      openFdCount >>= (`shouldBe` before')

fixtureClass :: Spec
fixtureClass = describe "(A) the probe fixture" $
  it "refuses a fixture over the cap, a missing one and (where it is the same volume) the ordinary drive, and every probe case fails at the acquisition with nothing allocated" $
    withSystemTempDirectory "hetoimasia-terrain-fixture" $ \dir -> do
      over <- acquireFixture (Policy mib False) dir
      missing <- acquireFixture defaultPolicy (dir </> "absent")
      fine <- acquireFixture (Policy maxBound False) dir
      over `shouldSatisfy` isOver
      missing `shouldSatisfy` \r -> case r of Left (MissingDirectory _) -> True; _ -> False
      fine `shouldSatisfy` either (const False) (const True)
      -- each of the probe's cases, handed the refusal, fails before it does anything
      forM_ [over, missing] $ \refused ->
        forM_ probeCases $ \(name, run) -> do
          r <- try (run (pure refused))
          (name, either (\e -> const True (e :: SomeException)) (const False) r) `shouldBe` (name, True)
      -- nothing was created or reserved on the way
      listDirectory dir `shouldReturn` []
  where
    isOver r = case r of Left (OverCap _ _) -> True; _ -> False

-- ---------------------------------------------------------------------------
-- (B) the growth state machine

data GrowthEvent = EvNone | EvCancel | EvCommit | EvAbandon | EvSecondGrowth | EvReleasePending
  deriving stock (Eq, Show, Enum, Bounded)

growthClass :: Spec
growthClass = describe "(B) the growth state machine" $ do
  it "allows only the outcomes of the state table at every gate point of a growth, for every event injected there" $
    forM_ gatePoints $ \(gname, gate) ->
      forM_ [minBound .. maxBound] $ \ev ->
        withEnv $ \env -> do
          b <- openBacking env ident (hCfg h0)
          -- a token of an earlier, abandoned preparation of this very growth: stale at every gate point
          old <- preparedOn env b
          submitAbandon (envSvc env) b old >>= either (fail . show) pure >>= awaitOutcome env >>= (`shouldBe` Released)
          g <- gate (envProbe env)
          t <- submitGrowth (envSvc env) b (64 * mib) (128 * mib) >>= either (fail . show) pure
          awaitReached g 1
          refusal <- case ev of
            EvNone -> pure Nothing
            EvCancel -> cancelTicket (envSvc env) t >>= \c -> pure (if c == CancelRequested then Nothing else Just (show c))
            EvCommit -> commitBackingGrowth (envSvc env) b old >>= \r ->
              pure (case r of Left (InvalidRequest NoPreparedGrowth) -> Nothing; other -> Just (show other))
            EvAbandon -> submitAbandon (envSvc env) b old >>= \r ->
              pure (case r of Left (InvalidRequest NoPreparedGrowth) -> Nothing; other -> Just (show (fmap (const ()) other)))
            EvSecondGrowth -> submitGrowth (envSvc env) b (64 * mib) (96 * mib) >>= \r ->
              pure (case r of Left (BusyNow GrowthActive) -> Nothing; other -> Just (show (fmap (const ()) other)))
            EvReleasePending -> submitReleasePending (envSvc env) b >>= \r ->
              pure (case r of Left (InvalidRequest NoPreparedGrowth) -> Nothing; other -> Just (show (fmap (const ()) other)))
          (gname, show ev, refusal) `shouldBe` (gname, show ev, Nothing)
          openGate g
          o <- awaitOutcome env t
          case (ev, o) of
            (EvCancel, Cancelled _) -> do
              reportedMatchesPhysical env
              (bvGrowthPrepared <$> backing' env b) >>= (`shouldBe` False)
              allocatedOf env >>= (`shouldSatisfy` (<= 64 * mib + 4096))
            (EvCancel, other) -> expectationFailure (gname <> ": cancel produced " <> show other)
            (_, GrowthPrepared _ _) -> do
              reportedMatchesPhysical env
              (bvGrowthPrepared <$> backing' env b) >>= (`shouldBe` True)
            (_, other) -> expectationFailure (show (gname, ev, other))

  it "revokes the commit authority in the step that accepts an abandon, and refuses every event while the release runs" $
    withEnv $ \env -> do
      b <- openBacking env ident (hCfg h0)
      p <- prepared env b
      g <- addGate (envProbe env) (== OpSetFileLength (64 * mib))
      t <- submitAbandon (envSvc env) b p >>= either (fail . show) pure
      awaitReached g 1
      -- the release is running: the token commits nothing, a second abandon, a growth and a release are refused
      commitBackingGrowth (envSvc env) b p >>= (`shouldBe` Left (InvalidRequest NoPreparedGrowth))
      submitAbandon (envSvc env) b p >>= (`shouldBe` Left (InvalidRequest NoPreparedGrowth)) . fmap (const ())
      submitGrowth (envSvc env) b (64 * mib) (96 * mib) >>= (`shouldBe` Left (BusyNow GrowthActive)) . fmap (const ())
      submitReleasePending (envSvc env) b >>= (`shouldBe` Left (InvalidRequest NoPreparedGrowth)) . fmap (const ())
      openGate g
      awaitOutcome env t >>= (`shouldBe` Released)
      reportedMatchesPhysical env
      (bvCommittedBytes <$> backing' env b) >>= (`shouldBe` 64 * mib)
      -- the same growth prepared again is a new preparation: the abandoned token is refused and the new one commits
      p2 <- prepared env b
      p2 `shouldSatisfy` (/= p)
      commitBackingGrowth (envSvc env) b p >>= (`shouldBe` Left (InvalidRequest NoPreparedGrowth))
      submitAbandon (envSvc env) b p >>= (`shouldBe` Left (InvalidRequest NoPreparedGrowth)) . fmap (const ())
      commitBackingGrowth (envSvc env) b p2 >>= (`shouldBe` Right ())
      commitBackingGrowth (envSvc env) b p2 >>= (`shouldBe` Left (InvalidRequest NoPreparedGrowth))
      (bvCommittedBytes <$> backing' env b) >>= (`shouldBe` 128 * mib)

  it "refuses a token of another service and sizes off the grid or past the limit before any native work" $ do
    foreignToken <- withEnv $ \env -> do
      b <- openBacking env ident (hCfg h0)
      prepared env b
    withEnv $ \env -> do
      b <- openBacking env ident (hCfg h0)
      _ <- prepared env b
      commitBackingGrowth (envSvc env) b foreignToken >>= (`shouldBe` Left ForeignHandle)
      submitAbandon (envSvc env) b foreignToken >>= (`shouldBe` Left (InvalidRequest NoPreparedGrowth)) . fmap (const ())
    withEnv $ \env -> do
      b <- openBacking env ident (hCfg h0)
      before' <- length <$> events (envProbe env)
      -- 4 KiB past the committed size is off the 1 MiB grid; past the offset limit is refused too
      submitGrowth (envSvc env) b (64 * mib) (64 * mib + 4096) >>= (`shouldSatisfy` isInvalid) . fmap (const ())
      submitGrowth (envSvc env) b (64 * mib) maxBound >>= (`shouldSatisfy` isInvalid) . fmap (const ())
      length <$> events (envProbe env) >>= (`shouldBe` before')
  where
    isInvalid r = case r of Left (InvalidRequest (AllowanceInvalid _)) -> True; _ -> False
    gatePoints :: [(String, Probe -> IO Gate)]
    gatePoints =
      [ ("before the allocation", \p -> addGate p isReserve)
      , ("before the length", \p -> addGate p (== OpSetFileLength (128 * mib)))
      , ("before the final verification", \p -> addGateAfter p 1 isStat)
      ]

prepared :: Env -> Backing -> IO PreparedGrowth
prepared env b = preparedOn env b

preparedOn :: Env -> Backing -> IO PreparedGrowth
preparedOn env b = do
  o <- submitGrowth (envSvc env) b (64 * mib) (128 * mib) >>= outcomeOf env
  case o of
    GrowthPrepared p _ -> pure p
    other -> fail ("not prepared: " <> show other)

-- ---------------------------------------------------------------------------
-- (C) every native resource has an owner at every instant

-- | The ways a native call is made to go wrong. The AFTER dimension (round 4): the native effect has HAPPENED and the
-- seam's after-hook then raises, or raises an exception of the asynchronous type: nothing the effect obtained may be
-- lost, whatever the call.
data Injection = Typed | Thrown | Cancelled' | AfterThrown | AfterAsync
  deriving stock (Eq, Show, Enum, Bounded)

data Stage = SOpen | SGrow | SRelease | SRead | SWrite | SClose
  deriving stock (Eq, Show)

-- | (stage, native call, the occurrence of it the injection lands on, rules installed first)
matrix :: [(Stage, String, NativeOp -> Bool, Int, Probe -> IO ())]
matrix =
  [ (SOpen, "create", (== OpCreateFile), 0, none)
  , (SOpen, "unlink", (== OpUnlinkFile), 0, none)
  , (SOpen, "cloexec", (== OpCloexecFlag), 0, none)
  , (SOpen, "stat (verify private)", isStat, 0, none)
  , (SOpen, "stat (profile)", isStat, 1, none)
  , (SOpen, "statfs", (== OpStatFilesystem), 0, none)
  , (SOpen, "reserve", isReserve, 0, none)
  , (SOpen, "set length", isLen, 0, none)
  , (SOpen, "stat (verify reservation)", isStat, 2, none)
  , (SOpen, "close (cleanup after a failure)", (== OpCloseFile), 0, \p -> addRule p 1 isReserve (FailWith (Errno 28)))
  , (SGrow, "stat (profile)", isStat, 0, none)
  , (SGrow, "statfs", (== OpStatFilesystem), 0, none)
  , (SGrow, "reserve", isReserve, 0, none)
  , (SGrow, "set length", isLen, 0, none)
  , (SGrow, "stat (verify)", isStat, 1, none)
  , (SGrow, "set length (rollback after a failure)", (== OpSetFileLength (64 * mib)), 0, \p -> addRuleAfter p 1 1 isStat (OverAllocated (10 * mib)))
  , (SRelease, "stat", isStat, 0, none)
  , (SRelease, "set length", (== OpSetFileLength (64 * mib)), 0, none)
  , (SRead, "pread", isRd, 0, none)
  , (SWrite, "pwrite", isWr, 0, none)
  , (SClose, "close", (== OpCloseFile), 0, none)
  ]
  where
    none _ = pure ()
    isLen op = case op of OpSetFileLength _ -> True; _ -> False
    isRd op = case op of OpReadAt _ _ -> True; _ -> False
    isWr op = case op of OpWriteAt _ _ -> True; _ -> False

sweepClass :: Spec
sweepClass = describe "(C) every native resource has an owner at every instant" $
  it "keeps descriptors, tracking and allocation consistent for each native call at each stage under a typed failure, an exception and a cancellation" $ do
    cases <- forM matrix $ \(stage, name, match, occurrence, prelude) ->
      forM [minBound .. maxBound] $ \inj -> do
        baseline <- openFdCount
        putStrLn ("  sweep case: " <> show stage <> " / " <> name <> " / " <> show inj) >> hFlush stdout
        -- a FAILING native close is kept by the service whoever asked for it: the scope ends with that labelled failure
        (if stage == SClose && inj `elem` [Typed, Thrown, AfterThrown, AfterAsync] then withEnvEndingWithKeptFailure else withEnv) $ \env -> runCase env stage match occurrence prelude inj
        fdsAfter <- openFdCount
        ((show stage, name, show inj), fdsAfter) `shouldBe` ((show stage, name, show inj), baseline)
        pure ()
    length (concat cases) `shouldBe` length matrix * length [minBound .. maxBound :: Injection]
    putStrLn ("sweep: " <> show (length matrix) <> " native calls at their stages x " <> show (length [minBound .. maxBound :: Injection]) <> " injections (typed, thrown, cancelled, and after the effect: thrown, async) = " <> show (length (concat cases)) <> " cases")
  where
    runCase :: Env -> Stage -> (NativeOp -> Bool) -> Int -> (Probe -> IO ()) -> Injection -> IO ()
    runCase env stage match occurrence prelude inj
      | stage == SClose = closeScenario env inj
      | otherwise = do
          let probe = envProbe env
          openedRef <- newIORef []
          act <- case stage of
            SOpen -> pure (submitOpen (envSvc env) ExplicitWork (OpenSpec (BC.pack (envDir env)) ident (hCfg h0)))
            SGrow -> do
              b <- openBacking env ident (hCfg h0)
              modifyIORef' openedRef (b :)
              pure (submitGrowth (envSvc env) b (64 * mib) (128 * mib))
            SRelease -> do
              b <- openBacking env ident (hCfg h0)
              modifyIORef' openedRef (b :)
              p <- preparedOn env b
              pure (submitAbandon (envSvc env) b p)
            SRead -> do
              b <- openBacking env ident (hCfg h0)
              modifyIORef' openedRef (b :)
              pure (submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo 5) 1 ReadProbe)
            SWrite -> do
              b <- openBacking env ident (hCfg h0)
              modifyIORef' openedRef (b :)
              let plan = either error id (planFor h0 1)
              (tid, s1) <- either (fail . show) pure (admit plan (hStore h0))
              sw <- either (fail . show) pure (stageWrite s1 tid)
              pure (submitWrite (envSvc env) b sw)
            SClose -> fail "unreachable"
          prelude probe
          gate <- if inj == Cancelled' then Just <$> addGateAfter probe occurrence match else pure Nothing
          case inj of
            Typed -> addRuleAfter probe occurrence 1 match (FailWith eio)
            Thrown -> addRuleAfter probe occurrence 1 match Throw
            AfterThrown -> addAfterRuleAfter probe occurrence 1 match Throw
            AfterAsync -> addAfterRuleAfter probe occurrence 1 match ThrowAsync
            Cancelled' -> pure ()
          t <- act >>= either (fail . ("submit refused: " <>) . show) pure
          forM_ gate $ \g -> do
            awaitReached g 1
            void (cancelTicket (envSvc env) t)
            openGate g
          o <- awaitOutcome env t
          opened <- readIORef openedRef
          show o `shouldSatisfy` (not . null)
          v <- view env
          fds <- openFds probe
          length fds `shouldBe` svBackings v
          -- after an after-hook raised, what the last native step did is UNKNOWN to the caller: the extra may be freed
          -- while the service still counts it, as a pending reservation a retry releases: never less than physical
          when (stage `elem` [SGrow, SRelease]) (if inj `elem` [AfterThrown, AfterAsync] then reportedCoversPhysical env else reportedMatchesPhysical env)
          checkInvariants env
          -- close whatever the case left open: the volume's reserved figures are back to their start
          forM_ [b | Opened b _ <- [o]] (closeBacking (envSvc env))
          forM_ opened (closeBacking (envSvc env))
          volumeLedgerClear env

-- | Closing a backing under each injection: a typed close error, an exception raised by the close and an
-- interruption of the closing thread while it waits at the call.
closeScenario :: Env -> Injection -> IO ()
closeScenario env inj = do
  b <- openBacking env ident (hCfg h0)
  let probe = envProbe env
  case inj of
    Typed -> do
      addRule probe 1 (== OpCloseFile) (FailWith eio)
      rep <- closeBacking (envSvc env) b
      (crClosed rep, crCloseError rep) `shouldBe` (True, Just eio)
    Thrown -> do
      addRule probe 1 (== OpCloseFile) Throw
      rep <- closeBacking (envSvc env) b
      (crClosed rep, crCloseException rep == Nothing) `shouldBe` (True, False)
    -- the close HAPPENED and its after-hook raises (synchronously, or of the asynchronous type): the close is recorded
    -- as having raised and is never repeated
    AfterThrown -> afterClose b Throw
    AfterAsync -> afterClose b ThrowAsync
    Cancelled' -> do
      -- the closing thread is interrupted while it waits for a held call: the interruption is remembered, the close
      -- still happens, and the interruption is delivered after it
      g <- addGate probe (\op -> case op of OpReadAt _ _ -> True; _ -> False)
      _ <- submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo 5) 1 ReadProbe >>= either (fail . show) pure
      awaitReached g 1
      done <- newEmptyMVar
      withOwnedThread (try (closeBacking (envSvc env) b) >>= putMVar done) $ \tid wait -> do
        bounded (atomically (backingView (envSvc env) b >>= \v -> check (maybe False bvClosing v)))
        throwTo tid UserInterrupt
        openGate g
        wait
      r <- readMVar done
      (either (\e -> const True (e :: SomeException)) (const False) r) `shouldBe` True
  openFds probe >>= (`shouldBe` [])
  (svBackings <$> view env) >>= (`shouldBe` 0)
  volumeLedgerClear env
  where
    afterClose b act = do
      addAfterRule (envProbe env) 1 (== OpCloseFile) act
      rep <- closeBacking (envSvc env) b
      (crClosed rep, crCloseException rep == Nothing) `shouldBe` (True, False)
      -- exactly one native close was made: an after-hook that raised never leads to a second
      evs <- events (envProbe env)
      length [() | OpCloseFile <- evs] `shouldBe` 1

-- ---------------------------------------------------------------------------
-- (C) startup: every started worker has an owner at every instant

startupClass :: Spec
startupClass = describe "(C) worker startup" $
  it "stops and joins every started worker, and keeps the primary failure, whether a start fails, is cancelled, or the abort's join is" $ do
    results <- forM startupCases $ \(name, setup) -> do
      withWorkerGroup $ \group -> do
        probe <- newProbe
        gates <- setup probe
        bank <- either (fail . show) pure (A.mkEditBankConfig A.defaultEditBankSpec)
        admission <- newTVarIO (A.newAdmission bank)
        cfg <- either (fail . show) pure (mkStorageConfig defaultQualified minHeadroomBytes)
        done <- newEmptyMVar
        let quietLogger = mkLogger defaultLogFilter (callbackSink (\_ -> pure ()))
            start = try (withStorageService (StoragePorts admission group quietLogger (seamFor probe) cfg) (\_ -> pure ())) >>= putMVar done
        withOwnedThread start $ \tid wait -> do
          -- a cancellation lands where the case holds the start (or the abort's join), then the hold is released
          forM_ gates $ \(g, cancelHere) -> do
            awaitReached g 1
            when cancelHere (throwTo tid UserInterrupt)
            openGate g
          wait
        r <- readMVar done
        report <- closeWorkerGroup group
        -- no worker thread is left live: none was still running when the group closed
        (name, length (reportDrained report)) `shouldBe` (name, 0)
        pure (name, either (\e -> show (e :: SomeException)) (const "started") r)
    -- a typed or thrown failure keeps its own error; a cancellation delivered during the start propagates
    forM_ results $ \(name, shown) -> (name, shown) `shouldSatisfy` \(_, t) -> t /= "started"
    forM_ [r | r@(n, _) <- results, n `elem` ["the second start fails", "the first start is refused", "the abort's join is cancelled"]] $ \(n, t) ->
      (n, t) `shouldSatisfy` \(_, x) -> "WorkerNotStarted" `isIn` x
  where
    isIn needle hay = any (\i -> take (length needle) (drop i hay) == needle) [0 .. length hay]
    startupCases :: [(String, Probe -> IO [(Gate, Bool)])]
    startupCases =
      [ ("the first start is refused", \p -> addRule p 1 (== OpWorkerStart 2) Throw >> pure [])
      , ("the second start fails", \p -> addRule p 1 (== OpWorkerStart 1) Throw >> pure [])
      , ("the first start is cancelled", \p -> (\g -> [(g, True)]) <$> addGate p (== OpWorkerStart 2))
      , ("the second start is cancelled", \p -> (\g -> [(g, True)]) <$> addGate p (== OpWorkerStart 1))
      , -- worker one is held as it stops (the abort's join waits for it) and the caller is cancelled there
        ("the abort's join is cancelled", \p -> do
            addRule p 1 (== OpWorkerStart 1) Throw
            g <- addGate p (== OpWorkerStop 2)
            pure [(g, True)])
      ]

-- ---------------------------------------------------------------------------
-- (D) every charge is released on every path

chargeClass :: Spec
chargeClass = describe "(D) every charge is released on every path" $ do
  it "retires a ticket discarded while its job runs, when the job finishes" $
    withEnv $ \env -> do
      b <- openBacking env ident (hCfg h0)
      g <- addGate (envProbe env) (\op -> case op of OpReadAt _ _ -> True; _ -> False)
      t <- submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo 5) 1 ReadProbe >>= either (fail . show) pure
      awaitReached g 1
      discardTicket (envSvc env) t
      openGate g
      bounded (atomically (serviceView (envSvc env) >>= \v -> check (svRecords v == 0)))
      l <- A.ledgers <$> readTVarIO (envAdmission env)
      -- only the backing's own record is still charged
      (A.lgControlReserved l, A.lgCacheBacked l, A.lgStagingForeground l) `shouldBe` (backingRecordBytes, 0, 0)

  it "retires an opened backing's outcome nobody took when the service shuts down, and closes the backing" $ do
    baseline <- openFdCount
    withEnv $ \env -> do
      t <- submitOpen (envSvc env) ExplicitWork (OpenSpec (BC.pack (envDir env)) ident (hCfg h0)) >>= either (fail . show) pure
      bounded (atomically (awaitTicket (envSvc env) t))
    -- the environment's own check found the admission at zero; the descriptor is closed too
    openFdCount >>= (`shouldBe` baseline)

  it "never drops an eviction: a read that would need the owner's cache copies waits until the owner releases them" $
    withEnv $ \env -> do
      b <- openBacking env ident (hCfg h0)
      -- the owner caches a backed, unpinned copy that fills the cache account
      (grant, entry) <- atomically $ do
        a <- readTVar (envAdmission env)
        (gr, a') <- either (const (error "owner cache")) pure (A.reserve A.Foreground [A.CacheCredit (siArena ident) (48 * mib - 2048) A.Backed False] a)
        writeTVar (envAdmission env) a'
        pure (gr, firstEntry gr)
      t <- submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo 5) 1 ReadProbe >>= either (fail . show) pure
      -- a job that needs no credit, queued after it, is dispatched in a scheduling pass that offered the read first
      -- (explicit before maintenance) and refused it: when that job has finished the read was certainly considered
      noop <- submitGrowth (envSvc env) b (64 * mib) (64 * mib) >>= either (fail . show) pure
      awaitOutcome env noop >>= (`shouldBe` GrowthNoChange)
      -- the owner can SEE it must release cache: the view counts the queued jobs refused for want of an eviction
      (svWaitingForCache <$> view env) >>= (`shouldBe` 1)
      -- nothing evicted the owner's copy: it is still charged and the read has not been dispatched
      l <- A.ledgers <$> readTVarIO (envAdmission env)
      A.lgCacheBacked l `shouldSatisfy` (>= 48 * mib - 2048)
      v <- view env
      (svQueued v, svRunning v) `shouldBe` (1, 0)
      -- the owner releases its copy; the read goes
      atomically (modifyTVar' (envAdmission env) (\a -> either (const a) id (A.dropEntry entry a)))
      atomically (modifyTVar' (envAdmission env) (A.release grant))
      awaitOutcome env t >>= (`shouldSatisfy` \o -> case o of Pages _ -> True; _ -> False)
      (svWaitingForCache <$> view env) >>= (`shouldBe` 0)

  it "takes no new borrower of a closing backing, so a caller cannot hold the close open" $
    withEnv $ \env -> do
      b <- openBacking env ident (hCfg h0)
      done <- readJob' env b 5
      bounded (atomically (awaitTicket (envSvc env) done))
      g <- addGate (envProbe env) (\op -> case op of OpReadAt _ _ -> True; _ -> False)
      held <- readJob' env b 6
      awaitReached g 1
      closed <- newEmptyMVar
      withOwnedThread (closeBacking (envSvc env) b >>= putMVar closed) $ \_ wait -> do
        bounded (atomically (backingView (envSvc env) b >>= \v -> check (maybe False bvClosing v)))
        -- a finished outcome of the closing backing is refused, so nobody can keep borrowing while the close waits
        withOutcome (envSvc env) done pure >>= (`shouldSatisfy` isNothing')
        openGate g
        wait
      readMVar closed >>= (`shouldSatisfy` crClosed)
      _ <- pure held
      volumeLedgerClear env

  it "gives back exactly what a backing held of its volume after a failed give-back and a close" $
    withEnv $ \env -> do
      b <- openBacking env ident (hCfg h0)
      -- a growth that never published fails to release its extra: it stays pending, charged on the volume
      addRuleAfter (envProbe env) 1 1 isStat (OverAllocated (10 * mib))
      addRule (envProbe env) 1 (== OpSetFileLength (64 * mib)) (FailWith eio)
      _ <- submitGrowth (envSvc env) b (64 * mib) (128 * mib) >>= either (fail . show) pure >>= awaitOutcome env
      (sum . svReserved <$> view env) >>= (`shouldBe` 128 * mib)
      _ <- closeBacking (envSvc env) b
      volumeLedgerClear env

  it "returns the shared admission to exactly its starting figures after random sequences of submit, cancel, discard, take, close and shutdown" $ do
    counts <- forM [1 .. 40 :: Int] $ \seed -> do
      done <- newIORef (0 :: Int)
      withEnv $ \env -> randomSequence env seed done
      readIORef done
    -- every sequence ran its steps, and each environment's end asserted the admission back at zero
    sum counts `shouldBe` 40 * 36
    putStrLn ("random sequences: 40 seeds, " <> show (sum counts) <> " operations")

-- | A deterministic pseudo-random sequence of operations against one environment.
randomSequence :: Env -> Int -> IORef Int -> IO ()
randomSequence env seed done = do
  gate <- addGate (envProbe env) (\op -> case op of OpReadAt _ _ -> True; _ -> False)
  gen <- newIORef (fromIntegral seed * 2654435761 + 12345 :: Word64)
  tickets <- newIORef ([] :: [Ticket])
  backings <- newIORef ([] :: [Backing])
  let next :: Int -> IO Int
      next n = atomicModifyIORef' gen $ \g -> let g' = g * 6364136223846793005 + 1442695040888963407 in (g', fromIntegral ((g' `div` 65536) `mod` fromIntegral n))
      pick :: [x] -> IO (Maybe x)
      pick xs = if null xs then pure Nothing else (\i -> Just (xs !! i)) <$> next (length xs)
  b0 <- openBacking env ident (hCfg h0)
  writeIORef backings [b0]
  forM_ [1 .. 36 :: Int] $ \step -> do
    op <- next (8 :: Int)
    case op of
      0 -> submitSome next tickets backings ExplicitWork
      1 -> submitSome next tickets backings CameraWork
      2 -> submitSome next tickets backings MaintenanceWork
      3 -> readIORef tickets >>= pick >>= mapM_ (\t -> void (cancelTicket (envSvc env) t))
      4 -> readIORef tickets >>= pick >>= mapM_ (\t -> discardTicket (envSvc env) t)
      5 -> readIORef tickets >>= pick >>= mapM_ (\t -> void (withOutcome (envSvc env) t pure))
      6 -> do
        -- nothing may wait on a held read: the gate opens before a close or an open waits for the workers
        openGate gate
        bs <- readIORef backings
        when (length bs > 1) $ pick bs >>= mapM_ (\b -> closeBacking (envSvc env) b >> modifyIORef' backings (filter (/= b)))
        when (length bs <= 1 && step > 0) $ do
          r <- submitOpen (envSvc env) ExplicitWork (OpenSpec (BC.pack (envDir env)) ident2 (hCfg h0))
          forM_ r $ \t -> do
            bounded (atomically (awaitTicket (envSvc env) t))
            withOutcome (envSvc env) t (\o -> case o of Opened b _ -> modifyIORef' backings (b :); _ -> pure ()) >>= void . pure
      _ -> when (step > 18) (openGate gate)
    modifyIORef' done (+ 1)
    checkInvariants env
  openGate gate
  -- every backing closed: the volume's reserved figures are back to their start, as the admission is at the end
  readIORef backings >>= mapM_ (closeBacking (envSvc env))
  volumeLedgerClear env
  where
    submitSome next tickets backings cls = do
      bs <- readIORef backings
      unless (null bs) $ do
        i <- next (length bs)
        page <- next 200
        r <- submitRead (envSvc env) (bs !! i) cls (hCfg h0) (PageNo (fromIntegral page)) 1 ReadProbe
        forM_ r $ \t -> modifyIORef' tickets (t :)

firstEntry :: A.Grant -> A.EntryId
firstEntry g = case A.grantEntries g of
  e : _ -> e
  [] -> error "a grant with no cache entry"

readJob' :: Env -> Backing -> Word64 -> IO Ticket
readJob' env b n = submitRead (envSvc env) b ExplicitWork (hCfg h0) (PageNo n) 1 ReadProbe >>= either (fail . show) pure

isNothing' :: Maybe a -> Bool
isNothing' Nothing = True
isNothing' _ = False
