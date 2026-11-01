{-# LANGUAGE OverloadedStrings #-}

-- | The actual built command in the milestone group (LFE-25, #540 requirement 5): the full-product @hetoimasia run
-- --vulkan-validation GAME_ROOT@ as an owned child against an unchanged owned copy of the shipped content (or a finite
-- fixture variant of it), ended by the means each case names, never by a signal standing in for a native close.
--
-- The child is created, observed and reaped by "Test.Run.Native.Child"; its stderr is the only channel, and every case
-- judges the same things in it before its own: the validation record (requested, layer and feature enabled, nothing
-- dropped) exactly once and before the session's start gate, the layer's own announcement exactly once with
-- synchronization validation among its enables (the loaded-chain evidence), no warning that diagnostic records were
-- lost or truncated (the production verdict only warns about them, so the receipt does not let them pass), and the
-- session's own ending line. A watchdog rescue, a second signal or a forced termination is never an expected ending.
--
-- On the isolated X11 display the child's window is bound by process id, captured through the external helper and closed
-- with a genuine @WM_DELETE_WINDOW@: native-close success is never inferred from a signal. Elsewhere (the macOS desktop,
-- Wayland) there is no OS capture and no external close, and these cases that need one record themselves as not
-- applicable: the actual command's window is the supervised run's, confirmed by the owner (docs/evidence/lua_first_native).
module Test.Run.Native.Actual (spec) where

import Control.Concurrent.STM (atomically, check, readTVar, readTVarIO)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as ByteString
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (getPid, waitForProcess)
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Run.Native.Capture (Bound (..), bindChild, closeBound, snapWith)
import Test.Run.Native.Child (Child (..), withChild)
import Test.Run.Native.Command (Awaited (..), executableVariable, failWith, permittingEnvironment, reachedBarrier, waitStderr, barrierSeconds)
import Test.Run.Native.Env (Env (..), evidence)
import Test.Run.Native.Landmarks (quadLandmarks, redClearLandmarks)
import Test.Run.Native.Library (copyTree, shippedContent)
import System.IO.Temp (withSystemTempDirectory)

-- | What a case expects of how the child ended and of its session.
data Expect = Expect
  { expectExit ∷ !ExitCode
  , expectVerdict ∷ !Text
  -- ^ The session's verdict word in its @session ended@ line.
  , expectFailures ∷ !(Maybe Text)
  -- ^ The @failures=@ count when the session reported one, as text.
  , expectErrorEntries ∷ !Bool
  -- ^ Whether an @ERROR@ entry is expected (a failed session writes its failure).
  }

spec ∷ Env → Spec
spec env = describe "Lua native milestone: the actual command" $ do
  it "shows the shipped quad in the real command's window, then ends on a genuine WM_DELETE_WINDOW delivered to that exact window: exit 0 with a clean validated teardown (isolated X11)" $
    onX11 env "native close" $
      runChild env "actual-command" (\_ → pure ()) (Expect ExitSuccess "VerdictSuccess" (Just "0") False) $ \pid found → forM_ found $ \bound → do
        snapWith env "actual-command--quad" bound quadLandmarks Nothing
        closeBound (Just bound)
        evidence env ("actual command: pid " <> Text.pack (show pid) <> ", native window " <> Text.pack (show (boundX bound)) <> " closed by a genuine WM_DELETE_WINDOW (the helper reported delivery; the exit below is the command's own); no signal was sent")
  it "leaves the healthy UI active with the exact red clear after an ordinary logical failure, and ends on a native close with exit 1 (isolated X11), or on a later Lua quit with exit 1 (elsewhere)" $
    let x11 = isJust (envX11 env)
     in runChild env "logical-failure" (failing x11) (Expect (ExitFailure 1) "VerdictFailure" Nothing True) $ \pid found → forM_ found $ \bound → do
          snapWith env "actual-command--logical-failure-red-clear" bound redClearLandmarks Nothing
          closeBound (Just bound)
          evidence env ("logical failure: pid " <> Text.pack (show pid) <> ", the UI stayed active and showed the exact empty red clear, a native close then ended the session with exit 1 (the failure outranks the normal stop)")
  it "ends on a Lua quit with exit 0 and a clean validated teardown" $
    runChild env "lua-quit" quitting (Expect ExitSuccess "VerdictSuccess" (Just "0") False) $ \_ _ → pure ()

-- | Run a case that needs the external helper only where the run carries one; elsewhere it records itself as not
-- applicable (the macOS actual command is the supervised run's, and no Wayland claim is made).
onX11 ∷ Env → Text → IO () → IO ()
onX11 env what run = case envX11 env of
  Just _ → run
  Nothing → evidence env ("actual command, " <> what <> ": not applicable in this session (no isolated-X11 helper): on macOS the real command's window is closed by the owner in the supervised run, whose confirmation is pending in docs/evidence/lua_first_native/macos-owner-confirmations.md (M-6)")

-- | The shipped main.lua with a logical failure after startup. On the isolated display the UI waits for the native close;
-- elsewhere it quits itself some updates after it has shown the failure.
failing ∷ Bool → FilePath → IO ()
failing waitForClose folder = edit folder $ \script →
  let raised = Text.replace "update=function(self, dt_seconds) end" "update=function(self, dt_seconds) error(\"logical failure on purpose\") end" script
      quits = Text.replace "          self.error_shown = true" "          self.error_shown = true\n          self.shown_updates = 0" raised
      counted = Text.replace "        return\n      end\n      if self.window and self.image and not self.drawn then" "        self.shown_updates = (self.shown_updates or 0) + 1\n        if self.shown_updates > 25 then api.session.quit() end\n        return\n      end\n      if self.window and self.image and not self.drawn then" quits
   in if waitForClose then raised else counted

quitting ∷ FilePath → IO ()
quitting folder = edit folder (Text.replace "api.texture.release(self.image.texture)" "api.texture.release(self.image.texture)\n        api.session.quit()")

edit ∷ FilePath → (Text → Text) → IO ()
edit folder change = do
  let path = folder </> "lua" </> "main.lua"
  original ← Text.decodeUtf8 <$> ByteString.readFile path
  let changed = change original
  if changed == original then expectationFailure "the fixture edit changed nothing" else ByteString.writeFile path (Text.encodeUtf8 changed)

-- | Start the built command with @--vulkan-validation@ on an owned copy of the content (changed by the fixture), wait for
-- the barrier (the resolved root, the validation record, the session's start gate), let the case act, wait for the
-- child's own exit within a bound and judge its stderr.
runChild ∷ Env → Text → (FilePath → IO ()) → Expect → (Int → Maybe Bound → IO ()) → IO ()
runChild env name fixture expectation act = do
  executable ← lookupEnv executableVariable >>= maybe (fail (executableVariable <> " is not set: run this suite through tools/vulkan/run.sh native")) pure
  environment ← permittingEnvironment
  withSystemTempDirectory "hetoimasia-native-actual" $ \folder → do
    copyTree shippedContent folder
    fixture folder
    withChild executable ["run", "--vulkan-validation", folder] environment $ \child → do
      barrier ← waitStderr child barrierSeconds reachedBarrier
      case barrier of
        Barrier → pure ()
        BarrierEnded → failWith child "the command's stderr ended before the validation record and the session's start gate were both logged"
        BarrierTimedOut → failWith child "the validation record and the session's start gate were not both logged in time"
      pid ← getPid (childProcess child) >>= maybe (failWith child "the command had already exited") (pure . fromIntegral)
      bound ← bindChild env pid
      act pid bound
      code ← timeout (30 * 1000000) (waitForProcess (childProcess child))
      case code of
        Nothing → failWith child "the command did not leave within 30 seconds of its ending; it was killed, which is a failure"
        Just status → status `shouldBe` expectExit expectation
      drained ← timeout (10 * 1000000) (atomically (readTVar (childOutEnded child) >>= check >> readTVar (childErrEnded child) >>= check))
      drained `shouldSatisfy` isJust
      readTVarIO (childReaderFailures child) >>= (`shouldBe` [])
      diagnostics ← readTVarIO (childErr child)
      judgeStderr expectation diagnostics
      evidence env ("actual command, case " <> name <> ": pid " <> Text.pack (show pid) <> ", " <> Text.pack executable <> " run --vulkan-validation <owned copy of " <> Text.pack shippedContent <> (if name == "actual-command" then "" else ", fixture variant") <> ">; exit " <> Text.pack (show (expectExit expectation)) <> " by the command itself; the validation record (requested=true layer=enabled feature=enabled, nothing dropped) was written once before the session's start gate and the layer announced itself once with synchronization validation among its enables; no warning that diagnostic records were lost; the session ended with verdict=" <> expectVerdict expectation)

-- | The common judgement of a validated child's stderr.
judgeStderr ∷ Expect → [Text] → IO ()
judgeStderr expectation diagnostics = do
  let joined = Text.unlines diagnostics
      explain = "the child's stderr was:\n" <> Text.unpack joined
      require what condition = unless condition (expectationFailure (what <> "\n" <> explain))
      records = [l | l ← diagnostics, "msg=\"vulkan validation resolved\"" `Text.isInfixOf` l]
      announced = [l | l ← diagnostics, "gpu.vulkan.diagnostics" `Text.isInfixOf` l, "Khronos Validation Layer Active" `Text.isInfixOf` l]
      dropped = [l | l ← diagnostics, "msg=\"vulkan validation item dropped\"" `Text.isInfixOf` l]
      field n v l = (n <> "=" <> v) `elem` Text.words l
      at needle = [i | (i, t) ← zip [0 ∷ Int ..] diagnostics, needle `Text.isInfixOf` t]
  forM_ ["cleanup failed", "the diagnostic capture was not clean", "boot failed"] $ \phrase →
    require ("the child reported `" <> phrase <> "`") (not (Text.pack phrase `Text.isInfixOf` joined))
  -- The production verdict only warns about lost, truncated, undelivered or unaccounted records; this receipt fails on it.
  require "the diagnostic capture reported lost records (`diagnostic records were lost`)" (not ("diagnostic records were lost" `Text.isInfixOf` joined))
  require "an ERROR entry was written, or was expected and absent" ((" ERROR " `Text.isInfixOf` joined) == expectErrorEntries expectation)
  require "no `session ended` entry" ("session ended" `Text.isInfixOf` joined)
  require ("the session did not end with verdict=" <> Text.unpack (expectVerdict expectation)) (("verdict=" <> expectVerdict expectation) `Text.isInfixOf` joined)
  forM_ (expectFailures expectation) $ \count → require ("the session did not end with failures=" <> Text.unpack count) (("failures=" <> count) `Text.isInfixOf` joined)
  line ← case records of
    [only] → pure only
    _ → failWith' "the validation record was not written exactly once"
  require "the record does not say requested=true layer=enabled feature=enabled" (field "requested" "true" line && field "layer" "enabled" line && field "feature" "enabled" line)
  require "an item was dropped" (null dropped)
  require "the layer did not announce itself exactly once to the diagnostic capture (the loader did not keep it in the chain)" (length announced == 1)
  require "the layer announced itself without synchronization validation among its enables" (all ("Current Enables: VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION" `Text.isInfixOf`) announced)
  require "the validation record was not logged after the content root resolved and before the session's start gate" $
    case (at "content root resolved", at "msg=\"vulkan validation resolved\"", at "start gate opened") of
      (root : _, resolved : _, gate : _) → root < resolved && resolved < gate
      _ → False
  where
    failWith' reason = expectationFailure reason >> error "unreachable"
