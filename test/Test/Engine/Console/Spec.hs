-- | Examples for the console executable's startup, run as a child process.
--
-- They root the suite's @Console@ group, so @--match Console@ selects them and
-- nothing else. They import no runtime spec module: an example asserting a
-- runtime contract belongs to @hetoimasia-runtime:runtime-tests@.
--
-- The console owns the variable names its startup reads, so these examples
-- state them here rather than borrowing the logging configuration examples'
-- own copy.
module Test.Engine.Console.Spec (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (throwIO, try)
import Control.Monad (forM_)
import Data.List (isPrefixOf, tails)
import Data.Maybe (mapMaybe)
import Hetoimasia.Console.Exit (cancellationExitCode, exitOnFailure, failureExitCode, usageExitCode)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)
import System.IO (hClose)
import System.Process
  ( CreateProcess (env, std_err)
  , StdStream (UseHandle)
  , createPipe
  , proc
  , waitForProcess
  , withCreateProcess
  )
import qualified Test.Engine.Console.Lua.Options as LuaOptions
import qualified Test.Engine.Console.Lua.Process as LuaProcess
import qualified Test.Engine.Console.Lua.Signals as LuaSignals
import qualified Test.Engine.Console.Lua.Status as LuaStatus
import Test.Engine.Console.Support (consoleExecutable, consoleVariableNames, controlledEnvironment, runConsole)
import Test.Hspec
  ( Spec
  , describe
  , it
  , shouldBe
  , shouldContain
  , shouldNotBe
  , shouldNotContain
  , shouldStartWith
  )

spec ∷ Spec
spec = describe "Console" $ do
  startup
  describe "Lua" $ do
    LuaOptions.spec
    LuaStatus.spec
    LuaSignals.spec
    LuaProcess.spec

startup ∷ Spec
startup = describe "Console startup" $ do
  it "emits the smoke records under the default configuration" testConsoleDefault
  it "applies a threshold and an exact override to the smoke path" testConsoleThreshold
  it "emits the owned-resource lifecycle records on the resource-smoke path"
    testConsoleResourceSmoke
  it "silences the resource-smoke path at a warn threshold"
    testConsoleResourceSmokeThreshold
  it "rejects an unknown argument with status 2 and a usage line naming both smoke paths and lua"
    testConsoleUnknownArgument
  it "fails before any entry for each invalid variable" testConsoleInvalid
  it "keeps a forged value from splitting the diagnostic" testConsoleForgedValue
  it "keeps help visible and validates configuration on that path" testConsoleHelp
  describe "Exit mapping" $ do
    it "exits non-zero when a runtime failure propagates out of a path" testConsolePropagatedFailure
    it "maps a cancellation to the cancellation status" testExitCancellation
    it "passes an explicit exit status through unchanged" testExitPassthrough

-- | Run the built console executable with its stderr on a pipe whose reading end
-- is already closed, so the first diagnostic write fails in the child.
runConsoleWithBrokenStderr ∷ [String] → IO ExitCode
runConsoleWithBrokenStderr arguments = do
  executable ← consoleExecutable
  controlled ← controlledEnvironment []
  (reading, writing) ← createPipe
  hClose reading
  -- The process library closes the writing end in this process once the
  -- child has it.
  withCreateProcess (proc executable arguments) { env = Just controlled, std_err = UseHandle writing } $
    \_ _ _ child → waitForProcess child

-- | The component of each rendered record, which is its third segment. A line
-- that is not a record is kept whole so a failure shows it.
recordComponents ∷ String → [String]
recordComponents = map component . lines
  where
    component line = case words line of
      (_ : _ : name : _) → name
      _ → line

-- | The message of one rendered record, which the layout quotes after @msg=@.
recordMessage ∷ String → String
recordMessage line = case filter (isPrefixOf marker) (tails line) of
  (found : _) → takeWhile (/= '"') (drop (length marker) found)
  [] → line
  where
    marker = "msg=\""

-- | The @resource=@ value of a rendered release record, if this line is one.
releasedResource ∷ String → Maybe String
releasedResource line
  | recordMessage line /= "Released resource" = Nothing
  | otherwise = case mapMaybe named (words line) of
      (value : _) → Just value
      [] → Nothing
  where
    named segment
      | marker `isPrefixOf` segment = Just (drop (length marker) segment)
      | otherwise = Nothing
    marker = "resource="

testConsoleDefault ∷ IO ()
testConsoleDefault = do
  (code, output, diagnostics) ← runConsole [] ["--smoke"]
  code `shouldBe` ExitSuccess
  -- Records are diagnostics on stderr; the smoke path writes no application
  -- output of its own.
  output `shouldBe` ""
  recordComponents diagnostics `shouldBe` ["runtime", "console", "runtime"]

testConsoleThreshold ∷ IO ()
testConsoleThreshold = do
  -- Only the variable under test is set, so this quiet run cannot be defeated
  -- by an inherited component override.
  (quiet, output, silent) ← runConsole [("HETOIMASIA_LOG_LEVEL", "warn")] ["--smoke"]
  quiet `shouldBe` ExitSuccess
  output `shouldBe` ""
  silent `shouldBe` ""
  -- An exact override silences one component while the other keeps the global
  -- default, which is the precedence the filter promises.
  (overridden, _, records) ←
    runConsole [("HETOIMASIA_LOG_LEVELS", "runtime=warn")] ["--smoke"]
  overridden `shouldBe` ExitSuccess
  recordComponents records `shouldBe` ["console"]

-- | The owned-resource path, run as a child process exactly as the smoke path
-- is. The message sequence asserted here is the one README.md documents.
testConsoleResourceSmoke ∷ IO ()
testConsoleResourceSmoke = do
  (code, output, diagnostics) ← runConsole [] ["--resource-smoke"]
  code `shouldBe` ExitSuccess
  -- Records are diagnostics on stderr; this path writes no application output.
  output `shouldBe` ""
  recordComponents diagnostics
    `shouldBe` ["runtime"] <> replicate 7 "runtime.resources" <> ["runtime"]
  map recordMessage (lines diagnostics)
    `shouldBe`
      [ "Starting hetoimasia"
      , "Acquired resource"
      , "Acquired composite"
      , "Completed bounded work"
      , "Released resource"
      , "Released resource"
      , "Released resource"
      , "Resource smoke completed"
      , "Completed hetoimasia"
      ]
  -- Identifiers are in fields rather than interpolated into the messages, and
  -- the composite's parts are released in its declared order before the
  -- enclosing scope releases its own allocation.
  diagnostics `shouldContain` "msg=\"Acquired resource\" id=1 resource=workspace"
  diagnostics `shouldContain` "buffer=2 resource=channel store=3"
  mapMaybe releasedResource (lines diagnostics)
    `shouldBe` ["channel.buffer", "channel.store", "workspace"]

testConsoleResourceSmokeThreshold ∷ IO ()
testConsoleResourceSmokeThreshold = do
  -- Lifecycle records are Info, so a warn threshold silences the whole path
  -- while the resources are still acquired, used, and released.
  (code, output, silent) ←
    runConsole [("HETOIMASIA_LOG_LEVEL", "warn")] ["--resource-smoke"]
  code `shouldBe` ExitSuccess
  output `shouldBe` ""
  silent `shouldBe` ""

testConsoleUnknownArgument ∷ IO ()
testConsoleUnknownArgument = do
  (code, output, diagnostics) ← runConsole [] ["--resources"]
  code `shouldBe` usageExitCode
  output `shouldBe` ""
  diagnostics `shouldContain` "Usage: hetoimasia"
  diagnostics `shouldContain` "--smoke"
  diagnostics `shouldContain` "--resource-smoke"
  diagnostics `shouldContain` "lua"

testConsoleInvalid ∷ IO ()
testConsoleInvalid = forM_ invalid $ \(name, value) → do
  (code, output, diagnostics) ← runConsole [(name, value)] ["--smoke"]
  code `shouldNotBe` ExitSuccess
  -- Exactly one line, naming the variable and the reason. Nothing else reached
  -- stderr, so startup failed before any entry was emitted, and the smoke
  -- action never ran.
  length (lines diagnostics) `shouldBe` 1
  diagnostics `shouldStartWith` (name <> ": ")
  diagnostics `shouldContain` value
  diagnostics `shouldNotContain` "Hello from Hetoimasia."
  output `shouldBe` ""
  where
    invalid =
      [ ("HETOIMASIA_LOG_LEVEL", "verbose")
      , ("HETOIMASIA_LOG_LEVELS", "gpu.vulkan=warn,gpu.vulkan=info")
      , ("HETOIMASIA_DEBUG", "All")
      ]

testConsoleForgedValue ∷ IO ()
testConsoleForgedValue = do
  -- An embedded newline in a value must not reach stderr as a second line: the
  -- startup contract is one line naming the variable and the reason.
  (code, output, diagnostics) ←
    runConsole [("HETOIMASIA_LOG_LEVEL", "bad\nforged")] ["--smoke"]
  code `shouldNotBe` ExitSuccess
  output `shouldBe` ""
  length (lines diagnostics) `shouldBe` 1
  diagnostics `shouldStartWith` "HETOIMASIA_LOG_LEVEL: "
  diagnostics `shouldContain` "\"bad\\nforged\""

testConsoleHelp ∷ IO ()
testConsoleHelp = do
  -- Help is ordinary application output, so a threshold that silences every
  -- record leaves it visible, and it names all three variables.
  (code, output, diagnostics) ← runConsole [("HETOIMASIA_LOG_LEVEL", "error")] ["--help"]
  code `shouldBe` ExitSuccess
  diagnostics `shouldBe` ""
  output `shouldContain` "Usage: hetoimasia"
  -- Both supported paths are listed, so --help documents the one this suite
  -- also runs as a child process below.
  output `shouldContain` "--smoke"
  output `shouldContain` "--resource-smoke"
  -- The lua subcommand and the exit statuses are listed too.
  output `shouldContain` "lua OPTIONS"
  output `shouldContain` "130"
  forM_ consoleVariableNames (shouldContain output)
  -- The help path resolves configuration first, so an invalid value fails it
  -- too, printing no help at all.
  (rejected, helpOutput, reason) ← runConsole [("HETOIMASIA_DEBUG", "NONE")] ["--help"]
  rejected `shouldNotBe` ExitSuccess
  helpOutput `shouldBe` ""
  reason `shouldStartWith` "HETOIMASIA_DEBUG: "

-- | A sink write that fails inside the runtime propagates out of the path, and
-- the executable's mapping, not the runtime, turns it into a failed exit.
testConsolePropagatedFailure ∷ IO ()
testConsolePropagatedFailure =
  forM_ [["--smoke"], ["--resource-smoke"]] $ \arguments →
    runConsoleWithBrokenStderr arguments >>= (`shouldBe` failureExitCode)

-- | A cancellation delivered to a running path leaves as the cancellation
-- status, with no failure line written.
testExitCancellation ∷ IO ()
testExitCancellation = do
  entered ← newEmptyMVar
  held ← newEmptyMVar
  outcome ← newEmptyMVar
  runner ← forkIO $ try (exitOnFailure (putMVar entered () >> takeMVar held)) >>= putMVar outcome
  takeMVar entered
  killThread runner
  takeMVar outcome >>= (`shouldBe` Left cancellationExitCode)
  -- Keeps the path's MVar reachable, so its block is a cancellation point
  -- rather than a deadlock the runtime could resolve on its own.
  putMVar held ()

-- | A usage or configuration @die@ keeps its own status.
testExitPassthrough ∷ IO ()
testExitPassthrough = do
  try (exitOnFailure (exitWith (ExitFailure 3))) >>= (`shouldBe` Left (ExitFailure 3))
  try (exitOnFailure (throwIO (ExitFailure 4))) >>= (`shouldBe` Left (ExitFailure 4))
  cancellationExitCode `shouldNotBe` failureExitCode
