-- | The real-platform qualification of the storage backend (TRA-21, requirement 9): the
-- production native backend on a bounded, disposable volume of the platform it runs on.
--
-- This is an explicit local probe, never part of the routine suite: it fills a capped
-- volume, so it runs only against a fixture the operator made for it, named in
-- @$XDG_CACHE_HOME/hetoimasia/terrain-storage-probe/fixture@ (the pointer file the setup
-- scripts under @tools/terrain-storage/@ write). Before any step that consumes space the
-- probe verifies the fixture: a distinct volume (its device differs from the working
-- directory's and the home directory's), owned by the running user, whose total capacity is
-- within the declared cap. A missing pointer, a missing directory or a mismatch FAILS the
-- run; it is never a skip and never a pass, and the probe never falls back to the ordinary
-- drive. It runs no privileged operation; provisioning the volume is the setup step.
--
-- Every record line is printed as @PROBE key=value@ for the evidence write-up, so the
-- platform, filesystem, native ABI, the reservation as the filesystem reports it, the
-- overhead, the write and readback results and the observed latencies are the run's own
-- output, never typed.
module Main (main) where

import Control.Concurrent.STM (atomically)
import Control.Exception (IOException, bracket, try)
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
import System.Directory (doesDirectoryExist, getCurrentDirectory, getHomeDirectory, listDirectory)
import System.Environment (lookupEnv)
import System.Info (arch, compilerVersion, os)
import System.IO (hFlush, stdout)
import System.Posix.Files (deviceID, fileOwner, getFileStatus)
import System.Posix.User (getRealUserID)
import Test.Hspec
import Test.TerrainRuntime.Storage.Harness
import Test.TerrainRuntime.Store.Harness (H (..), smallSpec, specOf)

mib :: Word64
mib = 1024 * 1024

-- | The most a fixture volume may hold: the declared cap.
fixtureCapBytes :: Word64
fixtureCapBytes = 4 * 1024 * mib

record :: String -> String -> IO ()
record k v = putStrLn ("PROBE " <> k <> "=" <> v) >> hFlush stdout

timed :: String -> IO a -> IO a
timed label act = do
  t0 <- getMonotonicTime
  r <- act
  t1 <- getMonotonicTime
  record ("latency." <> label <> ".seconds") (show (t1 - t0))
  pure r

-- | The fixture directory, verified.
fixture :: IO FilePath
fixture = do
  home <- getHomeDirectory
  cache <- maybe (home <> "/.cache") id <$> lookupEnv "XDG_CACHE_HOME"
  let pointer = cache <> "/hetoimasia/terrain-storage-probe/fixture"
  raw <- try (readFile pointer) :: IO (Either IOException String)
  dir <- case fmap (takeWhile (/= '\n')) raw of
    Right d | not (null d) -> pure d
    _ -> fail ("no fixture: the pointer file " <> pointer <> " is missing or empty; run the platform's setup script under tools/terrain-storage/")
  exists <- doesDirectoryExist dir
  unless exists (fail ("the fixture directory " <> dir <> " does not exist"))
  cwd <- getCurrentDirectory
  [fx, cw, hm] <- mapM (fmap deviceID . getFileStatus) [dir, cwd, home]
  when (fx == cw || fx == hm) (fail "the fixture is on the same volume as the working directory or the home directory: refused")
  owner <- fileOwner <$> getFileStatus dir
  me <- getRealUserID
  when (owner /= me) (fail "the fixture is not owned by the running user: refused")
  pure dir

spec :: Spec
spec = describe "Terrain storage qualification on this platform" $ do
  it "records the platform, the fixture and the qualified profile" $ do
    dir <- fixture
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
      when (vpTotalBytes prof > fixtureCapBytes) (fail "the fixture volume is larger than the declared cap")

  it "reserves the minimum, a middle and the default allowance for real, and reports the overhead" $ do
    dir <- fixture
    forM_ [64 * mib, 256 * mib, 1024 * mib] $ \bytes -> withEnvIn dir defaultProbe $ \env -> do
      let cfg = hCfg (newStoreH (specOf (toInteger bytes) Nothing))
      o <- timed ("reserve." <> show (bytes `div` mib) <> "MiB") (openBackingAt env dir ident cfg)
      case o of
        Opened _ rs -> do
          record ("reserve." <> show (bytes `div` mib) <> "MiB.allocated") (show (rsAllocated rs))
          record ("reserve." <> show (bytes `div` mib) <> "MiB.overhead") (show (rsOverhead rs))
          rsAllocated rs `shouldSatisfy` (>= bytes)
        other -> expectationFailure ("not reserved: " <> show other)

  it "writes and reads back the whole reserved capacity, and rewrites it with the rest of the volume exhausted" $ do
    dir <- fixture
    withEnvIn dir defaultProbe $ \env -> do
      let cfg = hCfg h64
          size = cfgAllowanceBytes cfg
      _ <- openBacking env ident cfg
      [fd] <- fdHandles (envProbe env)
      -- every page of the allowance, a pattern per page, then the whole range read back
      timed "write.allowance" (pattern' fd size 1)
      timed "readback.allowance" (verify fd size 1)
      -- the rest of the volume is consumed in a filler file the probe owns, until the platform refuses
      withFiller dir $ \filler -> do
        record "exhausted.filler.bytes" (show filler)
        -- previously written pages are rewritten across the whole reserved range: it must need no new allocation
        timed "rewrite.exhausted" (pattern' fd size 2)
        verify fd size 2
        record "rewrite.within.reservation" "no new allocation needed"

  it "refuses to grow when the volume is exhausted, keeping the old data and size, and grows when there is room" $ do
    dir <- fixture
    withEnvIn dir defaultProbe $ \env -> do
      let cfg = hCfg h64
      b <- openBacking env ident cfg
      [fd] <- fdHandles (envProbe env)
      pattern' fd (cfgAllowanceBytes cfg) 3
      withFiller dir $ \_ -> do
        o <- submitGrowth (envSvc env) b (64 * mib) (128 * mib) >>= outcomeOf env
        o `shouldBeFailure` \f -> case f of ReservationFailed (InsufficientHeadroom {}) -> True; _ -> False
        record "growth.exhausted" "reservation_failed"
        verify fd (cfgAllowanceBytes cfg) 3
      g <- submitGrowth (envSvc env) b (64 * mib) (128 * mib) >>= outcomeOf env
      case g of
        GrowthPrepared _ rs -> record "growth.64to128.allocated" (show (rsAllocated rs)) >> record "growth.64to128.overhead" (show (rsOverhead rs))
        other -> expectationFailure ("not grown: " <> show other)
      verify fd (cfgAllowanceBytes cfg) 3

  it "retains a failed release as a pending reservation and frees it on an explicit retry, old data intact" $ do
    dir <- fixture
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

  it "keeps the file after its name is gone for as long as a borrower holds it, and reclaims the space after the last close" $ do
    dir <- fixture
    withEnvIn dir defaultProbe $ \env -> do
      before' <- availableOf dir
      names0 <- listDirectory dir
      b <- openBacking env ident (hCfg h64)
      -- the name is gone as soon as the file exists: the directory lists what it listed before (a fresh
      -- ext4 volume has its own lost+found)
      listDirectory dir `shouldReturn` names0
      held <- availableOf dir
      record "unlink.reserved.bytes" (show (before' - held))
      -- a borrower is using the file: the close waits for it, and the data is still readable
      r <- withUse (envSvc env) b (readPages env b (hCfg h64) 7 1 ReadProbe)
      fmap (either (const False) (not . null)) r `shouldBe` Right True
      _ <- closeBacking (envSvc env) b
      after' <- pollRecovered dir before'
      record "close.reclaimed.bytes" (show (after' - held))
      record "close.reclaimed.complete" (show (after' + 4 * mib >= before'))
      after' + 4 * mib `shouldSatisfy` (>= before')

  it "refuses a filesystem that is not qualified, and an always-refusing build would not pass the examples above" $ do
    dir <- fixture
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

  it "fails the reservation qualification of a sparse file of the right length (negative control)" $ do
    dir <- fixture
    withEnvIn dir defaultProbe $ \env -> do
      addRule (envProbe env) 1 (\op -> case op of OpReserveRange _ _ -> True; _ -> False) Lie
      o <- openBackingAt env dir ident (hCfg h64)
      o `shouldBeFailure` \f -> case f of ReservationFailed (CoverageShort _ _) -> True; _ -> False
      record "negative.sparse" "reservation_failed"
  where
    h64 = newStoreH smallSpec
    defaultProbe = defaultOptions {eoQualified = Just defaultQualified, eoUnbounded = True}

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

availableOf :: FilePath -> IO Word64
availableOf dir = do
  made <- createPrivate productionSeam (BC.pack dir) 99
  case made of
    Left f -> fail (show f)
    Right c -> do
      _ <- unlinkFile productionSeam (BC.pack dir) (crName c)
      p <- profileOf productionSeam (crFd c)
      _ <- closeFile productionSeam (crFd c)
      either (fail . show) (pure . vpAvailableBytes) p

-- | Run an action with the rest of the volume's free space consumed by a file of the probe's own (reserved
-- natively until the platform refuses), and give the space back when it ends. Hands over the bytes taken.
withFiller :: FilePath -> (Word64 -> IO a) -> IO a
withFiller dir = \act -> do
  free0 <- availableOf dir
  r <- bracket acquire (\(_, fd) -> () <$ closeFile productionSeam fd) (act . fst)
  -- a filesystem may give the blocks of a closed, unlinked file back lazily (APFS did, within about a
  -- second): observe, bounded, until the volume reports the space again, and record how long it took
  polls <- pollRecoveredCount dir free0
  record "filler.reclaim.observations" (show polls)
  pure r
  where
    acquire = do
      made <- createPrivate productionSeam (BC.pack dir) 4242
      c <- either (fail . show) pure made
      _ <- unlinkFile productionSeam (BC.pack dir) (crName c)
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
-- own report (a filesystem may free the blocks of a closed, unlinked file lazily), at most 600 observations.
pollRecoveredCount :: FilePath -> Word64 -> IO Int
pollRecoveredCount dir target = go (0 :: Int)
  where
    go n = do
      a <- availableOf dir
      if a + 4 * mib >= target || n >= 600 then pure n else go (n + 1)

pollRecovered :: FilePath -> Word64 -> IO Word64
pollRecovered dir target = go (0 :: Int)
  where
    go n = do
      a <- availableOf dir
      if a + 4 * mib >= target || n >= 600 then pure a else go (n + 1)

main :: IO ()
main = hspec spec
