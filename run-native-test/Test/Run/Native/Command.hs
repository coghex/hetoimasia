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
-- synchronization validation are @enabled@. That alone is not proof that the loader kept the layer in its chain
-- (@docs/vulkan_compatibility_record.md@, "Zero validation errors is a claim about coverage"), so the validated case
-- also requires the layer's own announcement. The child runs with @HETOIMASIA_DEBUG=gpu.vulkan.diagnostics@, the
-- documented logging selection (@docs/logging.md@), which lets the diagnostic capture's Debug entries reach stderr; the
-- Khronos layer, once it is running in the instance's chain, reports to the capture's messenger at @vkCreateInstance@
-- "Khronos Validation Layer Active" with the features it was enabled with (the enable is spelled
-- @VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION@ by the Linux profile's layer and with an @_EXT@ suffix by the macOS
-- one, so the case keys on the common prefix). That record is the layer speaking, not the
-- command's, so it shows the layer was loaded and ran and that synchronization validation was enabled in it; it needs
-- no hook, only the command's own stderr. The not-requested case must not carry it.
--
-- Beyond that, a clean diagnostic verdict through teardown is the rest of the claim: an error-severity validation
-- report latches and fails the run, which then leaves with 1 and not 130 and writes an @ERROR@ entry. A deliberate
-- hazard that shows the layer catching something is @synchronization-hazard@ in @vulkan-native-tests@, in-process.
--
-- = The barrier
--
-- The signal is sent only after the child has logged, in this order, the resolved content root, the validation
-- record, and the session's @start gate opened@. The first two precede preparation and graphics startup, so they alone
-- would allow a stop before any session exists; the third establishes that the session is running. The record is
-- logged before the session is started and so before its first window. An absent record, or a child whose stderr
-- ended first, fails the case with what the child wrote.
--
-- = The child
--
-- Created, observed and reaped by "Test.Run.Native.Child", whose module header says what makes each state hold and whose
-- failure paths "Test.Run.Native.ChildSpec" exercises.
module Test.Run.Native.Command
  ( spec
  , executableVariable
    -- * What the milestone's actual-command cases share with the smoke cases
  , Awaited (..)
  , waitStderr
  , reachedBarrier
  , permittingEnvironment
  , failWith
  , barrierSeconds
  , exitSeconds
  ) where

import Control.Concurrent.STM (atomically, check, orElse, readTVar, readTVarIO)
import Control.Monad (forM_, unless)
import Data.List (isPrefixOf)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (ExitFailure))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (sigTERM, signalProcess)
import System.Process (getPid, waitForProcess)
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Run.Native.Child (Child (..), withChild)
import Test.Run.Native.Env (Env, evidence)
import Test.Run.Native.Library (copyTree, shippedContent)
import Control.Exception (throwIO)

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
      barrier ← waitStderr child barrierSeconds reachedBarrier
      case barrier of
        Barrier → pure ()
        BarrierEnded → failWith child "the command's stderr ended before the validation record and the session's start gate were both logged"
        BarrierTimedOut → failWith child ("the validation record and the session's start gate were not both logged within " <> show (barrierSeconds `div` 1000000) <> " seconds")
      -- The barrier holds, so the session is running and the one signal is decided; it is issued once, to a child that
      -- must still be there.
      pid ← getPid (childProcess child)
      case pid of
        Nothing → failWith child "the command had already exited when the one SIGTERM was due"
        Just target → signalProcess sigTERM target
      code ← timeout (exitSeconds * 1000000) (waitForProcess (childProcess child))
      case code of
        Nothing → failWith child ("the command did not leave within " <> show exitSeconds <> " seconds of one SIGTERM; it was killed, which is a failure and not an exit 130")
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
          -- The layer's own announcement, made to the diagnostic capture at vkCreateInstance and logged by it.
          announced = [line | line ← diagnostics, "gpu.vulkan.diagnostics" `Text.isInfixOf` line, "Khronos Validation Layer Active" `Text.isInfixOf` line]
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
          require "validation was not requested, and the Khronos layer announced itself" (null announced)
        Requested → do
          require "the layer and synchronization validation were requested, and the record does not say both were enabled (a layer missing from the provisioned prefix fails the case)" (field "requested" "true" line && field "layer" "enabled" line && field "feature" "enabled" line)
          require "validation was requested and enabled, and an item was dropped" (null dropped)
          require "the layer did not announce itself exactly once to the diagnostic capture (the command's stderr carries no `Khronos Validation Layer Active` record): the loader did not keep it in the chain, or the Debug entries did not reach stderr" (length announced == 1)
          require "the layer announced itself without synchronization validation among its enables" (all ("Current Enables: VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION" `Text.isInfixOf`) announced)
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
                 Requested → "validation was recorded as requested and enabled (requested=true layer=enabled feature=enabled: selected into the instance's create info) and nothing was dropped; the Khronos layer announced itself once to the diagnostic capture with synchronization validation among its enables (it was loaded and ran), with a clean diagnostic verdict through teardown"
             )
          <> "; a launch and lifetime smoke check, not proof of displayed output"

-- | How long the child may take to log the barrier (microseconds), and to leave after the one SIGTERM (seconds). Bounded, never
-- slept; the group's watchdog is the outer limit.
barrierSeconds ∷ Int
barrierSeconds = 30 * 1000000

exitSeconds ∷ Int
exitSeconds = 25

-- | The child's environment with the logging variables replaced, so its logging is the defaults (Info for every
-- component, no overrides) whatever the runner's own environment says, plus the Debug entries of the diagnostic capture
-- alone (the selection that carries the layer's own announcement). Nothing else is changed: the loader environment the
-- runner established is the child's too.
permittingEnvironment ∷ IO [(String, String)]
permittingEnvironment = (<> [("HETOIMASIA_DEBUG", "gpu.vulkan.diagnostics")]) . filter (not . logging . fst) <$> getEnvironment
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
