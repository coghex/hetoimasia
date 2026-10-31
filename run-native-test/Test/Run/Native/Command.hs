-- | The built @hetoimasia run@ command, launched as a child process against an unchanged owned copy of the shipped
-- content, and ended by exactly one SIGTERM (Linux, on the runner's isolated X11 display).
--
-- This is a launch and lifetime smoke check, /not/ proof that the quad was displayed: the display is invisible, nothing
-- is captured and no window is read back. It shows that the full-product command starts against real graphics, gets
-- past its handlers and its boot (the existing resolved-root diagnostic is the concrete startup barrier, observed
-- only after the signal handlers are installed, so the one signal is never sent before they exist), stops in order on a
-- first signal, reports an interrupted session with no failure and a clean cleanup, and exits 130 with no watchdog
-- rescue, second signal or forced termination: any of those is a failure, never the expected 130.
--
-- It runs on every platform the runner provides a display for. The supervised close of the actual command's
-- window, and its exit 0, is the local macOS run
-- (@bash tools/vulkan/run.sh native hetoimasia:exe:hetoimasia -- run samples/lua-quad/content@), and the actual command's
-- native close on Linux is LFE-25's: no cross-process close tooling exists or is added here.
--
-- The executable is the one the Vulkan project built: the runner names it in 'executableVariable' for this suite's
-- native execution, so an executable of another profile on @PATH@ is never launched. Every wait is bounded, and
-- the child is killed and reaped on every way out.
module Test.Run.Native.Command (spec, executableVariable) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (unless, void)
import qualified Data.Text as Text
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure))
import System.IO (Handle, hClose, hGetLine, hSetEncoding, utf8)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (sigKILL, sigTERM, signalProcess)
import System.Process
  ( CreateProcess (std_err, std_in, std_out)
  , ProcessHandle
  , StdStream (CreatePipe, NoStream)
  , createProcess
  , getPid
  , proc
  , waitForProcess
  )
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Run.Native.Env (Env, evidence)
import Test.Run.Native.Library (copyTree, shippedContent)

-- | The variable the runner sets to the built full-product executable.
executableVariable ∷ String
executableVariable = "HETOIMASIA_RUN_EXECUTABLE"

spec ∷ Env → Spec
spec env = describe "the built command" $
  it "launches the shipped content against real graphics, stops in order on exactly one SIGTERM and exits 130 with a clean cleanup" $
    do
        executable ← lookupEnv executableVariable >>= maybe (fail (executableVariable <> " is not set: run this suite with `bash tools/vulkan/run.sh native hetoimasia:test:run-native-tests`, after building the full-product executable")) pure
        withSystemTempDirectory "hetoimasia-run-command" $ \folder → do
          copyTree shippedContent folder
          bracket (start executable folder) finish $ \child → do
            -- The barrier: the resolved-root line is logged after the handlers are installed.
            barrier ← timeout (30 * 1000000) (atomically (readTVar (childErr child) >>= check . any (Text.isInfixOf "content root resolved")))
            barrier `shouldSatisfy` (/= Nothing)
            Just pid ← getPid (childProcess child)
            signalProcess sigTERM pid
            code ← timeout (25 * 1000000) (waitForProcess (childProcess child))
            case code of
              Nothing → expectationFailure "the command did not leave within 25 seconds of one SIGTERM; it was killed, which is a failure and not an exit 130"
              Just status → status `shouldBe` ExitFailure 130
            -- Everything the child wrote is read only once both pipes have ended.
            drained ← timeout (10 * 1000000) (mapM_ readMVar (childEnded child))
            drained `shouldSatisfy` (/= Nothing)
            diagnostics ← readTVarIO (childErr child)
            let joined = Text.unlines diagnostics
            -- The signal can land while the folder is still being prepared or after the session has started; either
            -- way the stop is orderly. A session that ran reports itself interrupted and failed nothing, and no
            -- error entry was written whatever the stage.
            joined `shouldSatisfy` (not . Text.isInfixOf " ERROR ")
            let ranSession = Text.isInfixOf "session ended" joined
            unless (not ranSession) $ do
              joined `shouldSatisfy` Text.isInfixOf "failures=0"
              joined `shouldSatisfy` Text.isInfixOf "verdict=VerdictInterrupted"
            evidence env ("command: " <> Text.pack executable <> " run <an unchanged copy of " <> Text.pack shippedContent <> ">, exactly one SIGTERM sent to the child after the resolved-root diagnostic, exit 130, no error entry; " <> (if ranSession then "the session had started and ended with failures=0 verdict=VerdictInterrupted" else "the stop landed while the folder was being prepared and no session had started") <> "; a launch and lifetime smoke check, not proof of displayed output")
  where
    start executable folder = do
      (_, out, err, process) ← createProcess (proc executable ["run", folder]) {std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe}
      case (out, err) of
        (Just output, Just diagnostics) → do
          outLines ← newTVarIO []
          errLines ← newTVarIO []
          outDone ← drain output outLines
          errDone ← drain diagnostics errLines
          pure (Child process outLines errLines [outDone, errDone])
        _ → fail "the child's pipes were not created"
    finish child = do
      _ ← try (getPid (childProcess child) >>= mapM_ (signalProcess sigKILL)) ∷ IO (Either SomeException ())
      void (timeout (10 * 1000000) (waitForProcess (childProcess child)))
    drain ∷ Handle → TVar [Text.Text] → IO (MVar ())
    drain handle ref = do
      hSetEncoding handle utf8
      ended ← newEmptyMVar
      void . forkIO $ do
        let loop = do
              line ← try (hGetLine handle) ∷ IO (Either SomeException String)
              case line of
                Right text → atomically (modifyTVar' ref (<> [Text.pack text])) >> loop
                Left _ → pure ()
        loop
        void (try (hClose handle) ∷ IO (Either SomeException ()))
        putMVar ended ()
      pure ended

data Child = Child
  { childProcess ∷ ProcessHandle
  , _childOut ∷ TVar [Text.Text]
  , childErr ∷ TVar [Text.Text]
  , childEnded ∷ [MVar ()]
  -- ^ Filled when each pipe's reader has seen its end, which is when everything the child wrote has been read.
  }
