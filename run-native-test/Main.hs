-- | The launcher's native suite: the full-product @hetoimasia run@ command on a real device, with real windows.
--
-- The order is the contract. Consent is read once, before anything native, and a run without it refuses and exits
-- non-zero. The process main thread then owns GLFW: it serves, one at a time, the actions the examples ask it to run
-- ('Test.Run.Native.Env.envMain'), each of which is a complete run of the command's production composition, whose
-- owner application and owner loop are the main thread's. Hspec runs on a thread of its own, so an example that
-- blocks cannot starve the main thread, and the suite ends when Hspec has.
--
-- The suite exists to run a nonzero number of examples: an empty selection fails (@configFailOnEmpty@), and a run
-- whose examples all skipped reports it rather than passing. Run it through the catalog group
-- @test.vulkan-run-native@, or the commands that group runs:
--
-- > bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia hetoimasia:test:run-native-tests
-- > bash tools/vulkan/run.sh native hetoimasia:test:run-native-tests
--
-- which on Linux starts an isolated X11 display for it and on macOS needs the desktop opt-in,
-- @HETOIMASIA_NATIVE_SESSION=desktop@, on the run's own command, given under the owner's standing approval
-- (AGENTS.md). Windows appear on the desktop for the length of the run on macOS. The suite sets no variable
-- persistently.
module Main (main) where

import Control.Concurrent (forkIO, forkOS)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar)
import Control.Concurrent.STM
  ( TMVar
  , TVar
  , atomically
  , modifyTVar'
  , newEmptyTMVarIO
  , newTQueueIO
  , writeTQueue
  , newTVarIO
  , orElse
  , putTMVar
  , readTMVar
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception (SomeException, mask_, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import System.IO.Temp (createTempDirectory, getCanonicalTemporaryDirectory)
import System.Environment (getArgs, getProgName, lookupEnv)
import System.Exit (ExitCode (ExitFailure), exitFailure, exitWith)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, stderr, stdout)
import System.Info (arch, compilerName, compilerVersion, os)
import Test.Hspec (Spec)
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, evalSpec, hspecWithResult, isSuccess, runSpecForest, specResultSuccess)
import Hetoimasia.Run.Settle (answering)
import qualified Test.Run.Native.Actual as Actual
import qualified Test.Run.Native.ChildSpec as ChildSpec
import Test.Run.Native.Command (executableVariable)
import qualified Test.Run.Native.Command as Command
import Test.Run.Native.Consent (Consent (..), describeConsent, readConsent, refusalMessage)
import Test.Run.Native.Env (Env (..), Hold (..))
import Test.Run.Native.X11 (defaultX11)
import qualified Test.Run.Native.Library as Library
import qualified Test.Run.Native.Milestone as Milestone
import qualified Test.Run.Native.PeersSpec as PeersSpec

main ∷ IO ()
main = do
  hSetBuffering stdout LineBuffering
  arguments ← getArgs
  when (completeFlag `elem` arguments && arguments /= [completeFlag]) $ do
    hPutStrLn stderr ("run-native-tests: " <> completeFlag <> " runs the whole profile and takes no other argument")
    exitWith (ExitFailure 2)
  consent ← readConsent >>= either refuse pure
  jobs ← newTVarIO []
  evidenceLines ← newTVarIO []
  done ← newEmptyTMVarIO
  started ← getCurrentTime
  evidenceDirectory ← lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE"
  (captureDirectory, scratch) ← case evidenceDirectory of
    Just place → pure (place </> "lua_first_native", False)
    Nothing → do
      temporary ← getCanonicalTemporaryDirectory
      made ← createTempDirectory temporary "hetoimasia-native-captures"
      pure (made, True)
  createDirectoryIfMissing True captureDirectory
  -- The supervised run is told apart from the catalog's unattended receipt by inputs the suite already reads: the
  -- desktop consent with a selection narrower than the complete profile. Only it holds, and only on the operator's
  -- acknowledgment on standard input.
  hold ← case consent of
    Desktop | arguments /= [completeFlag] → do
      input ← newTQueueIO
      _ ← forkIO $ do
        let loop = do
              next ← try @SomeException (Text.getLine)
              case next of
                Right line → atomically (writeTQueue input (Just line)) >> loop
                Left _ → atomically (writeTQueue input Nothing)
        loop
      pure (Just (Hold input (20 * 60)))
    _ → pure Nothing
  let env =
        Env
          { envStart = startMain jobs
          , envEvidence = evidenceLines
          , envX11 = case consent of IsolatedX11 _ → Just defaultX11; _ → Nothing
          , envHold = hold
          , envCaptureDir = captureDirectory
          }
  _ ← forkOS $ do
    result ←
      try @SomeException $
        if arguments == [completeFlag]
          then do
            (cfg, forest) ← evalSpec defaultConfig {configFailOnEmpty = True} (examples env)
            specResultSuccess <$> runSpecForest forest cfg
          else isSuccess <$> hspecWithResult defaultConfig {configFailOnEmpty = True} (examples env)
    atomically (putTMVar done result)
  -- The process main thread serves the examples' runs until Hspec is done.
  outcome ← serve jobs done
  finished ← getCurrentTime
  lines' ← reverse <$> readTVarIO evidenceLines
  let passed = either (const False) id outcome
      problems =
        [ "an example failed" | not passed ]
          <> [ "the suite raised: " <> Text.pack (show failure) | Left failure ← [outcome] ]
  record ← evidenceRecord consent passed problems (realToFrac (diffUTCTime finished started)) lines'
  Text.putStrLn record
  forM_ evidenceDirectory $ \place → do
    createDirectoryIfMissing True place
    Text.writeFile (place </> "run-native.md") record
  when scratch (removeDirectoryRecursive captureDirectory)
  forM_ problems (hPutStrLn stderr . ("run-native-tests: " <>) . Text.unpack)
  unless (null problems) exitFailure
  where
    refuse refusal = hPutStrLn stderr ("run-native-tests: " <> Text.unpack (refusalMessage refusal)) >> exitWith (ExitFailure 3)

-- | Runs the whole profile with nothing an environment could narrow, which the catalog group passes.
completeFlag ∷ String
completeFlag = "--complete"

examples ∷ Env → Spec
examples env = ChildSpec.spec >> PeersSpec.spec >> Library.spec env >> Command.spec env >> Milestone.spec env >> Actual.spec env

-- | Hand an action to the main thread, in one step that nothing can interrupt, and answer the wait for its outcome.
startMain ∷ TVar [IO ()] → IO a → IO (IO a)
startMain jobs action = mask_ $ do
  answer ← newEmptyMVar
  atomically (modifyTVar' jobs (<> [answering answer action]))
  pure (takeMVar answer >>= either throwIO pure)

-- | Serve the examples' actions, one at a time, until Hspec has finished, and answer how it did.
serve ∷ TVar [IO ()] → TMVar (Either SomeException Bool) → IO (Either SomeException Bool)
serve jobs done = loop
  where
    loop = do
      next ← atomically ((Left <$> takeJob) `orElse` (Right <$> readTMVar done))
      case next of
        Left job → job >> loop
        Right result → pure result
    takeJob =
      readTVar jobs >>= \case
        [] → retry
        job : rest → writeTVar jobs rest >> pure job

-- | The run's evidence: exact revision and source identity, the command, the platform and driver, the consent and
-- what the examples measured.
evidenceRecord ∷ Consent → Bool → [Text] → Double → [Text] → IO Text
evidenceRecord consent passed problems seconds measured = do
  revision ← lookupEnv "HETOIMASIA_VULKAN_REVISION"
  digest ← lookupEnv "HETOIMASIA_VULKAN_SOURCE_DIGEST"
  driver ← lookupEnv "VK_DRIVER_FILES"
  executable ← lookupEnv executableVariable
  program ← getProgName
  arguments ← getArgs
  let field name value = "- " <> name <> ": " <> value
  pure . Text.unlines $
    [ "# The generic run command on a real device"
    , ""
    , field "revision" (maybe "unknown" Text.pack revision)
    , field "source digest" (maybe "unknown" Text.pack digest)
    , field "command" (Text.pack (unwords (program : arguments)) <> " (through tools/vulkan/run.sh native)")
    , field "launched executable" (maybe "unset" Text.pack executable)
    , field "platform" (Text.pack (os <> "/" <> arch <> ", " <> compilerName <> " " <> show compilerVersion))
    , field "driver manifest" (maybe "unset" Text.pack driver)
    , field "consent" (describeConsent consent)
    , field "seconds" (Text.pack (show seconds))
    , field "result" (if passed && null problems then "every check passed" else "failed: " <> Text.intercalate "; " problems)
    , ""
    , "## What the examples measured"
    , ""
    ]
      <> map ("- " <>) measured
      <> [ ""
         , "No screen capture, window readback or pixel was taken; this establishes launch and lifetime, not visible output."
         ]
