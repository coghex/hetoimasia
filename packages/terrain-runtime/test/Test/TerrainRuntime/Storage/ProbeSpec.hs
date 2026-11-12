-- | The real-platform qualification examples, as a list taking the fixture acquirer as a parameter.
--
-- The probe's main passes the verified pointer fixture ('pointerFixture'); the routine suite passes an acquirer
-- that refuses (a fixture over the cap, a missing one, one on the ordinary drive) and shows that EVERY case fails
-- at the acquisition, before any file, filler or reservation exists: each case's first step is the acquisition, and
-- everything that fills a volume or reserves in it takes the resulting 'Fixture'.
--
-- Every record line is printed as @PROBE key=value@ for the evidence write-up.
module Test.TerrainRuntime.Storage.ProbeSpec (probeCases, ProbeCase) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Exception (bracket)
import Control.Monad (forM_, unless, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Unsafe as BSU
import Data.IORef
import Data.Word (Word64)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (castPtr)
import GHC.Clock (getMonotonicTime)
import qualified Foreign.C.Error as C
import Hetoimasia.Terrain.Runtime.Storage.Internal.File
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import Hetoimasia.Terrain.Runtime.Storage.Internal.Volume
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (pageSize)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (cfgAllowanceBytes)
import System.Directory (doesDirectoryExist, listDirectory)
import System.Info (arch, compilerVersion, os)
import System.IO (hFlush, stdout)
import Test.Hspec
import Test.TerrainRuntime.Storage.Fixture
import Test.TerrainRuntime.Storage.Harness
import Test.TerrainRuntime.Store.Harness (H (..), smallSpec, specOf)

mib :: Word64
mib = 1024 * 1024

record :: String -> String -> IO ()
record k v = putStrLn ("PROBE " <> k <> "=" <> v) >> hFlush stdout

timed :: String -> IO a -> IO a
timed label act = do
  t0 <- getMonotonicTime
  r <- act
  t1 <- getMonotonicTime
  record ("latency." <> label <> ".seconds") (show (t1 - t0))
  pure r

type ProbeCase = (String, IO (Either FixtureError Fixture) -> IO ())

-- | The verified fixture, or the example fails here, before it does anything else.
acquired :: IO (Either FixtureError Fixture) -> IO Fixture
acquired acquire = acquire >>= either (\e -> fail ("fixture refused: " <> show e)) pure

h64 :: H
h64 = newStoreH smallSpec

defaultProbe :: EnvOptions
defaultProbe = defaultOptions {eoQualified = Just defaultQualified, eoUnbounded = True}

probeCases :: [ProbeCase]
probeCases =
  [ ("records the platform, the fixture and the qualified profile", \acquire -> do
        fx <- acquired acquire
        let dir = fixtureDir fx
        record "os" os
        record "arch" arch
        record "compiler" (show compilerVersion)
        record "fixture" dir
        withEnvIn dir defaultProbe $ \env -> do
          _ <- openBacking env ident (hCfg h64)
          [fd] <- fdHandles (envProbe env)
          prof <- either (fail . show) pure =<< profileOf productionSeam fd
          record "filesystem" (BC.unpack (vpFilesystem prof))
          record "device" (show (vpDevice prof))
          record "blocksize" (show (vpBlockSize prof))
          record "volume.total.bytes" (show (vpTotalBytes prof))
      
    )
  , ("reserves the minimum, a middle and the default allowance for real, and reports the overhead", \acquire -> do
        fx <- acquired acquire
        let dir = fixtureDir fx
        forM_ [64 * mib, 256 * mib, 1024 * mib] $ \bytes -> withEnvIn dir defaultProbe $ \env -> do
          let cfg = hCfg (newStoreH (specOf (toInteger bytes) Nothing))
          o <- timed ("reserve." <> show (bytes `div` mib) <> "MiB") (openBackingAt env dir ident cfg)
          case o of
            Opened _ rs -> do
              record ("reserve." <> show (bytes `div` mib) <> "MiB.allocated") (show (rsAllocated rs))
              record ("reserve." <> show (bytes `div` mib) <> "MiB.overhead") (show (rsOverhead rs))
              rsAllocated rs `shouldSatisfy` (>= bytes)
              -- the allocation GRANULARITY is asserted, not only reported: the allocated bytes are a whole multiple of the
              -- reported block size
              record ("reserve." <> show (bytes `div` mib) <> "MiB.blocksize") (show (rsBlockSize rs))
              rsBlockSize rs `shouldSatisfy` (> 0)
              (rsAllocated rs `mod` rsBlockSize rs) `shouldBe` 0
            other -> expectationFailure ("not reserved: " <> show other)
    
    )
  , ("writes and reads back the whole reserved capacity, and rewrites it with the rest of the volume exhausted", \acquire -> do
        fx <- acquired acquire
        let dir = fixtureDir fx
        withEnvIn dir defaultProbe $ \env -> do
          let cfg = hCfg h64
              size = cfgAllowanceBytes cfg
          _ <- openBacking env ident cfg
          [fd] <- fdHandles (envProbe env)
          -- every page of the allowance, a pattern per page, then the whole range read back
          timed "write.allowance" (pattern' fd size 1)
          timed "readback.allowance" (verify fd size 1)
          -- the rest of the volume is consumed in a filler file the probe owns, until the platform refuses
          withMeter fx $ \meter -> withFiller fx meter $ \filler -> noCreateWhile env $ do
            record "exhausted.filler.bytes" (show filler)
            -- previously written pages are rewritten across the whole reserved range: it must need no new allocation
            timed "rewrite.exhausted" (pattern' fd size 2)
            verify fd size 2
            record "rewrite.within.reservation" "no new allocation needed"
    
    )
  , ("refuses to grow when the volume is exhausted, keeping the old data and size, and grows when there is room", \acquire -> do
        fx <- acquired acquire
        let dir = fixtureDir fx
        withEnvIn dir defaultProbe $ \env -> do
          let cfg = hCfg h64
          b <- openBacking env ident cfg
          [fd] <- fdHandles (envProbe env)
          pattern' fd (cfgAllowanceBytes cfg) 3
          withMeter fx $ \meter -> withFiller fx meter $ \_ -> noCreateWhile env $ do
            o <- submitGrowth (envSvc env) b (64 * mib) (128 * mib) >>= outcomeOf env
            o `shouldBeFailure` \f -> case f of ReservationFailed (InsufficientHeadroom {}) -> True; _ -> False
            record "growth.exhausted" "reservation_failed"
            verify fd (cfgAllowanceBytes cfg) 3
          g <- submitGrowth (envSvc env) b (64 * mib) (128 * mib) >>= outcomeOf env
          case g of
            GrowthPrepared _ rs -> do
              record "growth.64to128.allocated" (show (rsAllocated rs))
              record "growth.64to128.overhead" (show (rsOverhead rs))
              -- the granularity of the grown file too: whole blocks of the reported block size
              rsBlockSize rs `shouldSatisfy` (> 0)
              (rsAllocated rs `mod` rsBlockSize rs) `shouldBe` 0
            other -> expectationFailure ("not grown: " <> show other)
          verify fd (cfgAllowanceBytes cfg) 3
    
    )
  , ("retains a failed release as a pending reservation and frees it on an explicit retry, old data intact", \acquire -> do
        fx <- acquired acquire
        let dir = fixtureDir fx
        withEnvIn dir defaultProbe $ \env -> do
          let cfg = hCfg h64
          b <- openBacking env ident cfg
          [fd] <- fdHandles (envProbe env)
          pattern' fd (cfgAllowanceBytes cfg) 4
          addRuleAfter (envProbe env) 1 1 (== OpStatFile) (OverAllocated (10 * mib))
          addRule (envProbe env) 1 (== OpSetFileLength (64 * mib)) (FailWith (Errno (fromIntegral (let C.Errno c = C.eIO in c))))
          o <- submitGrowth (envSvc env) b (64 * mib) (128 * mib) >>= outcomeOf env
          o `shouldBeFailure` \f -> case f of ReservationFailed (OverheadExceedsModel _ _) -> True; _ -> False
          v <- atomically (backingView (envSvc env) b)
          fmap bvPendingReservation v `shouldBe` Just (Just (64 * mib))
          t <- submitReleasePending (envSvc env) b >>= either (fail . show) pure
          awaitOutcome env t >>= (`shouldBe` Released)
          st <- either (fail . show) pure =<< nativeStat posixNative fd
          record "release.retry.allocated" (show (nsAllocated st))
          nsAllocated st `shouldSatisfy` (< 65 * mib)
          verify fd (cfgAllowanceBytes cfg) 4
    
    )
  , ("keeps the file after its name is gone for as long as a borrower holds it, and reclaims the space after the last close", \acquire -> do
        fx <- acquired acquire
        let dir = fixtureDir fx
        withMeter fx $ \meter -> withEnvIn dir defaultProbe $ \env -> do
          before' <- availableOf meter
          names0 <- listDirectory dir
          b <- openBacking env ident (hCfg h64)
          -- the name is gone as soon as the file exists: the directory lists what it listed before (a fresh
          -- ext4 volume has its own lost+found)
          listDirectory dir `shouldReturn` names0
          held <- availableOf meter
          record "unlink.reserved.bytes" (show (before' - held))
          -- a borrower is using the file: the close waits for it, and the data is still readable
          r <- withUse (envSvc env) b (readPages env b (hCfg h64) 7 1 ReadProbe)
          fmap (either (const False) (not . null)) r `shouldBe` Right True
          _ <- closeBacking (envSvc env) b
          after' <- pollRecovered meter before'
          record "close.reclaimed.bytes" (show (after' - held))
          record "close.reclaimed.complete" (show (after' + 4 * mib >= before'))
          after' + 4 * mib `shouldSatisfy` (>= before')
    
    )
  , ("refuses a filesystem that is not qualified, and an always-refusing build would not pass the examples above", \acquire -> do
        fx <- acquired acquire
        let dir = fixtureDir fx
        -- the list names a filesystem this volume is not: the native call would succeed and is not asked
        withEnvIn dir (defaultProbe {eoQualified = Just ["not-this-one"]}) $ \env -> do
          o <- openBackingAt env dir ident (hCfg h64)
          o `shouldBeFailure` \f -> case f of StorageUnsupported (FilesystemNotQualified _) -> True; _ -> False
          record "unsupported.list" "storage_unsupported"
        -- tmpfs, where the platform has it
        shm <- doesDirectoryExist "/dev/shm"
        when shm $ withEnvIn "/dev/shm" (defaultProbe {eoQualified = Just defaultQualified}) $ \env -> do
          o <- openBackingAt env "/dev/shm" ident (hCfg h64)
          case o of
            Failed (StorageUnsupported (FilesystemNotQualified n)) _ -> record "unsupported.tmpfs" (BC.unpack n)
            other -> expectationFailure ("tmpfs was not refused: " <> show other)
          -- the refusal came before any allocation was asked of the platform
          evs <- events (envProbe env)
          length [() | OpReserveRange _ _ <- evs] `shouldBe` 0
    
    )
  , ("fails the reservation qualification of a sparse file of the right length (negative control)", \acquire -> do
        fx <- acquired acquire
        let dir = fixtureDir fx
        withEnvIn dir defaultProbe $ \env -> do
          addRule (envProbe env) 1 (\op -> case op of OpReserveRange _ _ -> True; _ -> False) Lie
          o <- openBackingAt env dir ident (hCfg h64)
          o `shouldBeFailure` \f -> case f of ReservationFailed (CoverageShort _ _) -> True; _ -> False
          record "negative.sparse" "reservation_failed"
    )
  ]

-- | Write a distinct byte pattern to every page of the first @size@ bytes (by the native adapter and the
-- backend's own transfer loop).
pattern' :: Fd -> Word64 -> Int -> IO ()
pattern' fd size gen = forPages size $ \off -> do
  let bytes = BS.replicate pageSize (fromIntegral ((off `div` fromIntegral pageSize + fromIntegral gen) `mod` 251))
  r <- BSU.unsafeUseAsCStringLen bytes $ \(p, n) -> writeFully productionSeam (castPtr p) n off fd
  either (fail . show) pure r

verify :: Fd -> Word64 -> Int -> IO ()
verify fd size gen = allocaBytes pageSize $ \buf -> forPages size $ \off -> do
  r <- readFully productionSeam buf pageSize off fd
  case r of
    Left _ -> fail ("readback failed at offset " <> show off)
    Right () -> do
      got <- BS.packCStringLen (castPtr buf, pageSize)
      let want = BS.replicate pageSize (fromIntegral ((off `div` fromIntegral pageSize + fromIntegral gen) `mod` 251))
      unless (got == want) (fail ("readback differs at offset " <> show off))

forPages :: Word64 -> (Word64 -> IO ()) -> IO ()
forPages size act = go 0
  where
    go off | off >= size = pure ()
           | otherwise = act off >> go (off + fromIntegral pageSize)

-- | THE PROBE'S WAY OF READING FREE SPACE: a descriptor the probe opens BEFORE anything is allocated and holds for
-- the whole example (a private, unlinked, empty file on the fixture volume), read with @fstat@ and @fstatfs@ on the
-- descriptor. Reading free space never creates anything: while a volume is exhausted, or has not yet been given its
-- space back (a filesystem may free the blocks of a closed, unlinked file lazily), a create needs space and a name,
-- so a meter that creates fails exactly when it is needed. There is no function here that measures free space by
-- creating a file.
newtype Meter = Meter Fd

withMeter :: Fixture -> (Meter -> IO a) -> IO a
withMeter fx = bracket make (\(Meter fd) -> () <$ closeFile productionSeam fd)
  where
    make = do
      made <- createPrivate productionSeam (BC.pack (fixtureDir fx)) 9999
      c <- either (fail . show) pure made
      _ <- unlinkFile productionSeam (BC.pack (fixtureDir fx)) (crName c)
      pure (Meter (crFd c))

availableOf :: Meter -> IO Word64
availableOf (Meter fd) = do
  p <- profileOf productionSeam fd
  either (fail . show) (pure . vpAvailableBytes) p

-- | The exhausted phase: nothing in it may create a file or a name. The backend's own calls go through the harness
-- seam, which logs every native create: the count is the same at the end as at the start.
noCreateWhile :: Env -> IO a -> IO a
noCreateWhile env act = do
  before' <- creates
  r <- act
  after' <- creates
  after' `shouldBe` before'
  pure r
  where
    creates = (\evs -> length [() | OpCreateFile <- evs]) <$> events (envProbe env)

-- | Run an action with the rest of the volume's free space consumed by a file of the probe's own (reserved
-- natively until the platform refuses), and give the space back when it ends. Hands over the bytes taken.
withFiller :: Fixture -> Meter -> (Word64 -> IO a) -> IO a
withFiller fx meter = \act -> do
  free0 <- availableOf meter
  r <- bracket acquire (\(_, fd) -> () <$ closeFile productionSeam fd) (act . fst)
  -- a filesystem may give the blocks of a closed, unlinked file back lazily (APFS did, within about a
  -- second): observe, bounded, until the volume reports the space again, and record how long it took
  polls <- pollRecoveredCount meter free0
  record "filler.reclaim.observations" (show polls)
  pure r
  where
    acquire = do
      made <- createPrivate productionSeam (BC.pack (fixtureDir fx)) 4242
      c <- either (fail . show) pure made
      _ <- unlinkFile productionSeam (BC.pack (fixtureDir fx)) (crName c)
      total <- newIORef (0 :: Word64)
      let step chunk = do
            t <- readIORef total
            r <- nativeReserve posixNative (crFd c) t chunk
            case r of
              Right _ -> nativeSetLength posixNative (crFd c) (t + chunk) >> writeIORef total (t + chunk) >> step chunk
              Left _
                | chunk > 4096 -> step (chunk `div` 2)
                | otherwise -> pure ()
      step (64 * mib)
      taken <- readIORef total
      pure (taken, crFd c)

-- | The free space once the volume has reclaimed a closed file: observed by bounded polling of the platform's
-- own report (a filesystem may free the blocks of a closed, unlinked file lazily), at most 200 observations, 50 ms apart.
pollRecoveredCount :: Meter -> Word64 -> IO Int
pollRecoveredCount meter target = go (0 :: Int)
  where
    go n = do
      a <- availableOf meter
      if a + 4 * mib >= target || n >= 200 then pure n else threadDelay 50000 >> go (n + 1)

pollRecovered :: Meter -> Word64 -> IO Word64
pollRecovered meter target = go (0 :: Int)
  where
    go n = do
      a <- availableOf meter
      if a + 4 * mib >= target || n >= 200 then pure a else threadDelay 50000 >> go (n + 1)

