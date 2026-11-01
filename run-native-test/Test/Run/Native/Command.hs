-- | The built @hetoimasia run@ command, launched as a child process against an unchanged owned copy of the shipped
-- content, and ended by exactly one SIGTERM, twice: with Vulkan validation not requested (the command's default) and
-- with @--vulkan-validation@ (LFE-28). It runs on every platform the runner provides a display for: Linux on the runner's
-- isolated X11 display, macOS under per-command desktop consent.
--
-- This is a launch and lifetime smoke check, /not/ proof that the quad was displayed: the display is invisible, nothing
-- is captured and no window is read back. It shows that the full-product command starts against real graphics, gets
-- past its handlers and its boot, reports how its optional validation resolved, runs a session, stops in order on a
-- first signal, reports an interrupted session with no failure and a clean cleanup, and exits 130 with no watchdog
-- rescue, second signal or forced termination: any of those is a failure, never the expected 130.
--
-- = What the validated case proves, and what it does not
--
-- The record the command logs says what the instance's create info was /asked for/: the Khronos layer and
-- synchronization validation are @enabled@. Together with a clean diagnostic verdict through teardown (an error-severity
-- validation report latches and fails the run, which then leaves with 1 and not 130, and writes an @ERROR@ entry), that
-- is the whole claim: /enabled and clean/. It is not proof that the loader kept the layer in its chain or that it ran
-- (@docs/vulkan_compatibility_record.md@, "Zero validation errors is a claim about coverage"): a stronger attestation
-- through the command's public interfaces does not exist (see @docs/run_command.md@, "Validation"). The deliberate
-- hazard that shows the layer active is @synchronization-hazard@ in @vulkan-native-tests@, in-process.
--
-- = The barrier
--
-- The signal is sent only after the child has logged, in this order, the resolved content root, the validation
-- record, and the session's @start gate opened@. The first two precede preparation and graphics startup, so they alone
-- would allow a stop before any session exists; the third establishes that the session is running. The record is
-- logged before the session is started and so before its first window. An absent record, or a child whose stderr
-- ended first, fails the case with what the child wrote.
--
-- = The child, and what makes each state hold
--
-- * /Owner/: this module's 'withChild', the only place a child is created or reaped.
-- * /Admission to tracking/: the process, both pipe readers and their end flags are created in one masked step; a
--   failure after the process exists and before the caller has the 'Child' kills and reaps it there.
-- * /Intent to issuance/: the one SIGTERM is decided after the barrier and issued by one 'signalProcess' call; a
--   child that is already gone when it is decided is a failure of the case, not a skipped signal.
-- * /Terminal evidence/: the exit code from a bounded 'waitForProcess' and both pipes' end flags, each read from the
--   reader that saw the end; everything the child wrote is read only once both have ended.
-- * /Cleanup/: on every way out the child is killed if it has not exited, reaped within a bound, and its readers are
--   waited for within a bound. A child that cannot be confirmed reaped and drained fails the case.
module Test.Run.Native.Command (spec, executableVariable) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, writeTVar)
import Control.Exception (IOException, SomeException, finally, mask, onException, throwIO, try)
import Control.Monad (forM_, unless, void)
import Data.List (isPrefixOf)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (ExitFailure))
import System.IO (Handle, hClose, hGetLine, hPutStrLn, hSetEncoding, stderr, utf8)
import System.IO.Error (isEOFError)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (sigKILL, sigTERM, signalProcess)
import System.Process
  ( CreateProcess (std_err, std_in, std_out)
  , ProcessHandle
  , StdStream (CreatePipe, NoStream)
  , createProcess
  , getPid
  , getProcessExitCode
  , proc
  , waitForProcess
  )
import qualified System.Process as Process (CreateProcess (env))
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Run.Native.Env (Env, evidence)
import Test.Run.Native.Library (copyTree, shippedContent)

-- | The variable the runner sets to the built full-product executable.
executableVariable ∷ String
executableVariable = "HETOIMASIA_RUN_EXECUTABLE"

-- | Whether the child is started with @--vulkan-validation@.
data Variant = NotRequested | Requested
  deriving (Eq, Show)

spec ∷ Env → Spec
spec env = describe "the built command" $ do
  it "launches the shipped content against real graphics with validation not requested, stops in order on exactly one SIGTERM and exits 130 with a clean cleanup" $
    commandCase env NotRequested
  it "launches the shipped content with --vulkan-validation, records the layer and synchronization validation as requested and enabled, stops in order on exactly one SIGTERM and exits 130 with a clean verdict" $
    commandCase env Requested

commandCase ∷ Env → Variant → IO ()
commandCase env variant = do
  executable ← lookupEnv executableVariable >>= maybe (fail (executableVariable <> " is not set: run this suite with `bash tools/vulkan/run.sh native hetoimasia:test:run-native-tests`, after building the full-product executable")) pure
  environment ← permittingEnvironment
  withSystemTempDirectory "hetoimasia-run-command" $ \folder → do
    copyTree shippedContent folder
    let arguments = ["run"] <> ["--vulkan-validation" | variant == Requested] <> [folder]
    withChild executable arguments environment $ \child → do
      barrier ← waitStderr child (30 * 1000000) reachedBarrier
      case barrier of
        Barrier → pure ()
        BarrierEnded → failWith child "the command's stderr ended before the validation record and the session's start gate were both logged"
        BarrierTimedOut → failWith child "the validation record and the session's start gate were not both logged within 30 seconds"
      -- The barrier holds, so the session is running and the one signal is decided; it is issued once, to a child that
      -- must still be there.
      pid ← getPid (childProcess child)
      case pid of
        Nothing → failWith child "the command had already exited when the one SIGTERM was due"
        Just target → signalProcess sigTERM target
      code ← timeout (25 * 1000000) (waitForProcess (childProcess child))
      case code of
        Nothing → failWith child "the command did not leave within 25 seconds of one SIGTERM; it was killed, which is a failure and not an exit 130"
        Just status → status `shouldBe` ExitFailure 130
      drained ← timeout (10 * 1000000) (atomically (readTVar (childOutEnded child) >>= check >> readTVar (childErrEnded child) >>= check))
      drained `shouldSatisfy` isJust
      -- Everything the child wrote has been read from here on.
      readerFailures ← readTVarIO (childReaderFailures child)
      readerFailures `shouldBe` []
      diagnostics ← readTVarIO (childErr child)
      let joined = Text.unlines diagnostics
          explain = "the child's stderr was:\n" <> Text.unpack joined
          require what condition = unless condition (expectationFailure (what <> "\n" <> explain))
          record = [line | line ← diagnostics, "msg=\"vulkan validation resolved\"" `Text.isInfixOf` line]
          dropped = [line | line ← diagnostics, "msg=\"vulkan validation item dropped\"" `Text.isInfixOf` line]
          field name value line = (name <> "=" <> value) `elem` Text.words line
      -- No error entry whatever the stage, and nothing of a failed run, of a failed cleanup or of an unclean diagnostic
      -- capture: an error-severity validation report latches and would have ended the run with 1.
      require "an ERROR entry was written" (not (" ERROR " `Text.isInfixOf` joined))
      forM_ ["run failed", "cleanup failed", "the diagnostic capture was not clean", "boot failed"] $ \phrase →
        require ("the child reported `" <> phrase <> "`") (not (Text.pack phrase `Text.isInfixOf` joined))
      -- The session ran, was interrupted, failed nothing and said so, whichever way the stop arrived.
      require "no `session ended` entry" ("session ended" `Text.isInfixOf` joined)
      require "the session did not end with failures=0" ("failures=0" `Text.isInfixOf` joined)
      require "the session did not end with verdict=VerdictInterrupted" ("verdict=VerdictInterrupted" `Text.isInfixOf` joined)
      -- Exactly one record, and what it says: requested versus resolved, enabled meaning selected into the create info.
      line ← case record of
        [only] → pure only
        _ → failWith child "the validation record was not written exactly once"
      case variant of
        NotRequested → do
          require "validation was not requested, and the record does not say so" (field "requested" "false" line && field "layer" "not-requested" line && field "feature" "not-requested" line)
          require "validation was not requested, and an item was dropped" (null dropped)
        Requested → do
          require "the layer and synchronization validation were requested, and the record does not say both were enabled (a layer missing from the provisioned prefix fails the case)" (field "requested" "true" line && field "layer" "enabled" line && field "feature" "enabled" line)
          require "validation was requested and enabled, and an item was dropped" (null dropped)
      let at needle = [index | (index, text) ← zip [0 ∷ Int ..] diagnostics, needle `Text.isInfixOf` text]
      require "the validation record was not logged after the content root resolved and before the session's start gate" $
        case (at "content root resolved", at "msg=\"vulkan validation resolved\"", at "start gate opened") of
          (root : _, resolved : _, gate : _) → root < resolved && resolved < gate
          _ → False
      evidence env $
        "command: "
          <> Text.pack executable
          <> " run "
          <> (if variant == Requested then "--vulkan-validation " else "")
          <> "<an unchanged copy of "
          <> Text.pack shippedContent
          <> ">, exactly one SIGTERM sent to the child after the resolved-root diagnostic, the validation record and the session's start gate, exit 130, no error entry; the session ended with failures=0 verdict=VerdictInterrupted; "
          <> ( case variant of
                 NotRequested → "validation was recorded as not requested (requested=false layer=not-requested feature=not-requested) and nothing was dropped"
                 Requested → "validation was recorded as requested and enabled (requested=true layer=enabled feature=enabled: selected into the instance's create info, not proof the loader kept the layer in its chain) and nothing was dropped, with a clean diagnostic verdict through teardown"
             )
          <> "; a launch and lifetime smoke check, not proof of displayed output"

-- | The child's environment with the logging variables removed, so its logging is the defaults (Info for every
-- component, no overrides) whatever the runner's own environment says. Nothing else is changed: the loader environment
-- the runner established is the child's too.
permittingEnvironment ∷ IO [(String, String)]
permittingEnvironment = filter (not . logging . fst) <$> getEnvironment
  where
    logging name = "HETOIMASIA_LOG_" `isPrefixOf` name || name == "HETOIMASIA_DEBUG"

-- | Fail the case with the reason and everything the child has written so far.
failWith ∷ Child → String → IO a
failWith child reason = do
  diagnostics ← readTVarIO (childErr child)
  expectationFailure (reason <> "\nthe child's stderr so far was:\n" <> Text.unpack (Text.unlines diagnostics))
  throwIO (userError reason)

-- | The first three milestones of a run, in the order they are logged. The record and the gate are what the signal waits
-- for; the root is the existing resolved-root diagnostic, logged after the signal handlers are installed.
reachedBarrier ∷ [Text.Text] → Bool
reachedBarrier diagnostics =
  any ("content root resolved" `Text.isInfixOf`) diagnostics
    && any ("msg=\"vulkan validation resolved\"" `Text.isInfixOf`) diagnostics
    && any ("start gate opened" `Text.isInfixOf`) diagnostics

data Awaited = Barrier | BarrierEnded | BarrierTimedOut

-- | Wait, bounded and without sleeping, until the child's stderr satisfies the condition, or ends first.
waitStderr ∷ Child → Int → ([Text.Text] → Bool) → IO Awaited
waitStderr child bound condition = do
  result ← timeout bound . atomically $ (readTVar (childErr child) >>= check . condition >> pure Barrier) `orElse` (readTVar (childErrEnded child) >>= check >> pure BarrierEnded)
  pure (maybe BarrierTimedOut id result)

data Child = Child
  { childProcess ∷ ProcessHandle
  , childErr ∷ TVar [Text.Text]
  , childOutEnded ∷ TVar Bool
  , childErrEnded ∷ TVar Bool
  -- ^ Set by each pipe's reader when it has seen its end, which is when everything the child wrote has been read.
  , childReaderFailures ∷ TVar [String]
  -- ^ A reader that stopped for any reason other than the end of its stream, recorded where it happened.
  }

-- | Start the child, run the body, and on every way out kill it if it has not exited, reap it and wait for its readers,
-- each within a bound. The body's own failure, an assertion included, is raised as it is; a child that cannot be confirmed
-- reaped and drained fails an otherwise passing case.
withChild ∷ FilePath → [String] → [(String, String)] → (Child → IO a) → IO a
withChild executable arguments environment body = mask $ \restore → do
  child ← start executable arguments environment
  outcome ← try @SomeException (restore (body child))
  problems ← release child
  case outcome of
    Left failure → do
      forM_ problems $ \problem → hPutStrLn stderr ("run-native-tests: the command's cleanup was not confirmed: " <> problem)
      throwIO failure
    Right result → do
      unless (null problems) $ expectationFailure ("the command's cleanup was not confirmed: " <> unwords problems)
      pure result

-- | Create the process and its readers in one masked step. A failure after the process exists kills and reaps it here, because
-- the caller has no 'Child' to release yet.
start ∷ FilePath → [String] → [(String, String)] → IO Child
start executable arguments environment = do
  (_, out, err, process) ← createProcess (proc executable arguments) {Process.env = Just environment, std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe}
  (do
      (output, diagnostics) ← case (out, err) of
        (Just output, Just diagnostics) → pure (output, diagnostics)
        _ → fail "the child's pipes were not created"
      outLines ← newTVarIO []
      errLines ← newTVarIO []
      outEnded ← newTVarIO False
      errEnded ← newTVarIO False
      failures ← newTVarIO []
      reader "stdout" output outLines outEnded failures
      reader "stderr" diagnostics errLines errEnded failures
      pure (Child process errLines outEnded errEnded failures))
    `onException` abandon process out err
  where
    abandon process out err = do
      getPid process >>= mapM_ (\pid → try @IOException (signalProcess sigKILL pid))
      void (waitForProcess process)
      forM_ out closeQuietly
      forM_ err closeQuietly

-- | Read lines until the stream ends, then mark it ended. The loop runs unmasked; the end is marked however it stopped.
-- Only the end of the stream is silent: any other failure of the read is recorded for the case to assert on.
reader ∷ String → Handle → TVar [Text.Text] → TVar Bool → TVar [String] → IO ()
reader name handle ref ended failures =
  void (forkIOWithUnmask (\unmask → (hSetEncoding handle utf8 >> unmask loop) `finally` (closeQuietly handle >> atomically (writeTVar ended True))))
  where
    loop = do
      line ← try @IOException (hGetLine handle)
      case line of
        Right text → atomically (modifyTVar' ref (<> [Text.pack text])) >> loop
        Left failure
          | isEOFError failure → pure ()
          | otherwise → atomically (modifyTVar' failures (<> [name <> ": " <> show failure]))

closeQuietly ∷ Handle → IO ()
closeQuietly handle = void (try @IOException (hClose handle))

-- | Kill the child if it has not exited, reap it and wait for both readers, each bounded; answer what could not be confirmed.
release ∷ Child → IO [String]
release child = do
  exited ← getProcessExitCode (childProcess child)
  case exited of
    Just _ → pure ()
    Nothing → do
      target ← getPid (childProcess child)
      -- The child may leave between the check and the kill; the reap below is the authority, so a failed kill is no verdict.
      forM_ target $ \pid → try @IOException (signalProcess sigKILL pid)
  reaped ← timeout (10 * 1000000) (waitForProcess (childProcess child))
  drained ← timeout (10 * 1000000) (atomically (readTVar (childOutEnded child) >>= check >> readTVar (childErrEnded child) >>= check))
  pure (["the child was not reaped within 10 seconds of the kill" | reaped == Nothing] <> ["the child's pipes did not end within 10 seconds" | drained == Nothing])
