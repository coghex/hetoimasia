-- | The command as processes: the built executable's usage and boot refusals, which acquire nothing native, and
-- the suite's own binary as a child that runs the command's real composition under real signals.
--
-- A signal is delivered only after the child has said, on stdout, that it is past the point the example needs; every
-- read and every wait is bounded; no example sleeps; and every child is killed and reaped on every way out
-- independently of the signal under test. No example signals this process or its process group.
module Test.Engine.Run.Process (spec) where

import Control.Exception (IOException, try)
import Control.Monad (forM_)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getExecutablePath)
import Hetoimasia.Run.Signals (withRunSignals)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (Handler (Ignore), Signal, installHandler, sigINT, sigTERM)
import Test.Engine.Console.Support
  ( Outcome (..)
  , awaitExit
  , awaitMarker
  , readErrors
  , readRest
  , runToCompletion
  , sendSignal
  , withChildOf
  )
import Test.Engine.Run.Child (childVariable, gameVariable)
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldNotContain)

spec ∷ Spec
spec = describe "Process" $ do
  usage
  boot
  handlers
  signals

-- | The handler scope puts back what was in force, on a return and on a failure, and installs nothing it does
-- not restore. No signal is delivered: only the installation is examined.
handlers ∷ Spec
handlers = describe "the signal handlers' scope" $ do
  it "restores the previous SIGINT and SIGTERM handlers on a return" $ do
    _ ← installHandler sigINT Ignore Nothing
    _ ← installHandler sigTERM Ignore Nothing
    withRunSignals (pure ()) $ \_ → pure ()
    interrupt ← installHandler sigINT Ignore Nothing
    terminate ← installHandler sigTERM Ignore Nothing
    (isIgnore interrupt, isIgnore terminate) `shouldBe` (True, True)

  it "restores them when the body fails" $ do
    _ ← installHandler sigINT Ignore Nothing
    _ ← installHandler sigTERM Ignore Nothing
    failed ← try (withRunSignals (pure ()) $ \_ → ioError (userError "body failed")) ∷ IO (Either IOException ())
    either (const ()) (const ()) failed `shouldBe` ()
    interrupt ← installHandler sigINT Ignore Nothing
    terminate ← installHandler sigTERM Ignore Nothing
    (isIgnore interrupt, isIgnore terminate) `shouldBe` (True, True)
  where
    isIgnore = \case
      Ignore → True
      _ → False

usage ∷ Spec
usage = describe "the command line" $ do
  it "exits 2 with the usage line and a reason on stderr and nothing on stdout, for each usage error" $
    forM_ usageErrors $ \(arguments, reason) → do
      outcome ← runToCompletion [] ("run" : arguments)
      (arguments, outcomeCode outcome, outcomeOut outcome) `shouldBe` (arguments, ExitFailure 2, "")
      outcomeErr outcome `shouldContain` "Usage: hetoimasia run [--vulkan-validation] [--] GAME_ROOT"
      outcomeErr outcome `shouldContain` ("hetoimasia run: " <> reason)
      length (lines (outcomeErr outcome)) `shouldBe` 2

  it "accepts --vulkan-validation before a folder that is not there, which is a boot failure and not a usage error" $
    forM_ [["--vulkan-validation", "/no/such/folder"], ["--vulkan-validation", "--", "/no/such/folder"]] $ \arguments → do
      outcome ← runToCompletion [] ("run" : arguments)
      (arguments, outcomeCode outcome, outcomeOut outcome) `shouldBe` (arguments, ExitFailure 1, "")
      outcomeErr outcome `shouldContain` "boot failed"
      outcomeErr outcome `shouldNotContain` "Usage:"

  it "reads --vulkan-validation and --help after the separator as the folder, with or without the option before it" $
    forM_ [["--", "--vulkan-validation"], ["--vulkan-validation", "--", "--vulkan-validation"], ["--vulkan-validation", "--", "--help"]] $ \arguments → do
      outcome ← runToCompletion [] ("run" : arguments)
      (arguments, outcomeCode outcome, outcomeOut outcome) `shouldBe` (arguments, ExitFailure 1, "")
      outcomeErr outcome `shouldContain` "boot failed"
      outcomeErr outcome `shouldNotContain` "Usage:"

  it "prints the command's help to stdout alone and exits 0" $ do
    outcome ← runToCompletion [] ["run", "--help"]
    outcomeCode outcome `shouldBe` ExitSuccess
    outcomeOut outcome `shouldContain` "Usage: hetoimasia run [--vulkan-validation] [--] GAME_ROOT"
    outcomeOut outcome `shouldContain` "--vulkan-validation"
    outcomeErr outcome `shouldBe` ""

  it "names the command in the top-level usage and help of this build" $ do
    outcome ← runToCompletion [] ["--help"]
    outcomeOut outcome `shouldContain` "run [--vulkan-validation] [--] GAME_ROOT"

  it "reads a folder named --help after the separator, which is a boot failure and not a usage error" $ do
    outcome ← runToCompletion [] ["run", "--", "--help"]
    outcomeCode outcome `shouldBe` ExitFailure 1
    outcomeErr outcome `shouldContain` "boot failed"

  it "keeps the fatal logging configuration ahead of the dispatch, for help and malformed arguments alike" $
    forM_ [["run", "--help"], ["run"], ["run", "x"], ["run", "--vulkan-validation", "x"], ["run", "--vulkan-validation"], ["run", "x", "--vulkan-validation"]] $ \arguments → do
      outcome ← runToCompletion [("HETOIMASIA_LOG_LEVEL", "nope")] arguments
      (arguments, outcomeCode outcome) `shouldBe` (arguments, ExitFailure 1)
      outcomeOut outcome `shouldBe` ""
      outcomeErr outcome `shouldContain` "HETOIMASIA_LOG_LEVEL"

-- | Each usage error of the grammar, with the reason its one line carries.
usageErrors ∷ [([String], String)]
usageErrors =
  [ ([], "missing GAME_ROOT")
  , (["--"], "missing GAME_ROOT")
  , (["-x"], "unknown option '-x'")
  , (["a", "b"], "exactly one GAME_ROOT is accepted")
  , (["--", "a", "b"], "exactly one GAME_ROOT is accepted")
  , (["--help", "a"], "--help takes no other argument")
  , (["--mod", "x"], "unknown option '--mod'")
  , (["--vulkan-validation"], "missing GAME_ROOT")
  , (["--vulkan-validation", "--"], "missing GAME_ROOT")
  , (["a", "--vulkan-validation"], "--vulkan-validation must come before GAME_ROOT")
  , (["--vulkan-validation", "a", "--vulkan-validation"], "--vulkan-validation must come before GAME_ROOT")
  , (["--", "a", "--vulkan-validation"], "exactly one GAME_ROOT is accepted")
  , (["--vulkan-validation", "--vulkan-validation", "a"], "--vulkan-validation is given more than once")
  , (["--vulkan-validation", "--help"], "--help takes no other argument")
  , (["--help", "--vulkan-validation"], "--help takes no other argument")
  , (["--vulkan-validation", "--mod", "a"], "unknown option '--mod'")
  , (["--validation", "a"], "unknown option '--validation'")
  ]

boot ∷ Spec
boot = describe "boot refusals of the built executable" $ do
  it "exits 1 for a folder that is not there, one without a manifest and one whose manifest is malformed, reaching no graphics" $
    withSystemTempDirectory "hetoimasia-run-process" $ \folder → do
      createDirectoryIfMissing True (folder </> "empty")
      createDirectoryIfMissing True (folder </> "bad")
      writeFile (folder </> "bad" </> "hetoimasia.json") "{"
      forM_ [folder </> "absent", folder </> "empty", folder </> "bad"] $ \root → do
        outcome ← runToCompletion [] ["run", root]
        (root, outcomeCode outcome, outcomeOut outcome) `shouldBe` (root, ExitFailure 1, "")
        outcomeErr outcome `shouldContain` "boot failed"

  it "reports the resolved root of a folder it opened, then refuses what is in it" $
    withSystemTempDirectory "hetoimasia-run-process" $ \folder → do
      outcome ← runToCompletion [] ["run", folder]
      outcomeErr outcome `shouldContain` "content root resolved"
      outcomeErr outcome `shouldContain` ("selected=" <> folder)

signals ∷ Spec
signals = describe "signals, to a child running the command's composition" $ do
  let game =
        unlines
          [ "return {"
          , "  gameplay = { every_ticks = 1, update = function(self, dt) end },"
          , "  presentation = {"
          , "    every_seconds = 0.02,"
          , "    init = function(self, api) print('ui ready') end,"
          , "    update = function(self, dt) end,"
          , "    shutdown = function(self, reason) print('ui shutdown') end"
          , "  }"
          , "}"
          ]
      manifest = "{\"format\":1,\"id\":\"child\",\"entry\":\"main.lua\",\"tick_seconds\":\"0.01\"}"
      withGame body = withSystemTempDirectory "hetoimasia-run-child" $ \folder → do
        writeFile (folder </> "hetoimasia.json") manifest
        writeFile (folder </> "main.lua") game
        body folder
      child mode folder = withChildOf getExecutablePath [(childVariable, mode), (gameVariable, folder)] []

  forM_ [("SIGTERM", sigTERM), ("SIGINT", sigINT)] $ \(name, signal) →
    it ("stops in order on one " <> name <> ", runs the scripts' shutdown and exits 130") $
      withGame $ \folder → child "orderly" folder $ \process → do
        _ ← awaitMarker process "ui ready"
        sendSignal signal process
        awaitExit process >>= (`shouldBe` ExitFailure 130)
        readRest process >>= (`shouldContain` "ui shutdown")
        diagnostics ← readErrors process
        diagnostics `shouldContain` "content root resolved"
        diagnostics `shouldContain` "session ended"

  forM_ [(sigINT, sigTERM), (sigTERM, sigINT), (sigTERM, sigTERM)] $ \(first, second) →
    it ("leaves at once with 130 on a second signal, running no cleanup (" <> showSignal first <> " then " <> showSignal second <> ")") $
      withGame $ \folder → child "stuck" folder $ \process → do
        _ ← awaitMarker process "ready"
        sendSignal first process
        _ ← awaitMarker process "stopping"
        sendSignal second process
        awaitExit process >>= (`shouldBe` ExitFailure 130)
        rest ← readRest process
        rest `shouldNotContain` "cleaned up"
  where
    showSignal ∷ Signal → String
    showSignal signal
      | signal == sigINT = "SIGINT"
      | otherwise = "SIGTERM"
