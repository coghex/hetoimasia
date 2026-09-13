-- | Examples for the console executable's startup, run as a child process.
--
-- The variable names come from the logging component that declares them, so the
-- injected-lookup cases there and the child-process cases here describe one
-- contract rather than two copies of it.
module Test.Engine.Runtime.Console (spec) where

import Control.Monad (forM_)
import Data.List (isPrefixOf, tails)
import Data.Maybe (mapMaybe)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log
  ( variableComponentLevels
  , variableDebug
  , variableGlobalLevel
  )
import System.Directory (findExecutable)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.Process
  ( CreateProcess (env)
  , proc
  , readCreateProcessWithExitCode
  )
import Test.Engine.Logging.Configuration (consoleVariables)
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
spec = describe "Console startup" $ do
  it "emits the smoke records under the default configuration" testConsoleDefault
  it "applies a threshold and an exact override to the smoke path" testConsoleThreshold
  it "emits the owned-resource lifecycle records on the resource-smoke path"
    testConsoleResourceSmoke
  it "silences the resource-smoke path at a warn threshold"
    testConsoleResourceSmokeThreshold
  it "rejects an unknown argument with a usage line naming both smoke paths"
    testConsoleUnknownArgument
  it "fails before any entry for each invalid variable" testConsoleInvalid
  it "keeps a forged value from splitting the diagnostic" testConsoleForgedValue
  it "keeps help visible and validates configuration on that path" testConsoleHelp

-- | The three variable names the console application reads, as the environment
-- spells them.
consoleVariableNames ∷ [String]
consoleVariableNames =
  map Text.unpack
    [ variableGlobalLevel consoleVariables
    , variableComponentLevels consoleVariables
    , variableDebug consoleVariables
    ]

-- | Run the built console executable with exactly the logging variables a case
-- asks for: the inherited environment is stripped of all three first, so an
-- inherited value can neither defeat a quiet run nor fail a default one. The
-- executable is reached through this suite's @build-tool-depends@ on it rather
-- than a guessed build path.
runConsole ∷ [(String, String)] → [String] → IO (ExitCode, String, String)
runConsole variables arguments = do
  found ← findExecutable "hetoimasia"
  case found of
    Nothing → fail "the hetoimasia executable is not on this test's search path"
    Just executable → do
      inherited ← getEnvironment
      let controlled =
            [ pair | pair@(name, _) ← inherited, name `notElem` consoleVariableNames ]
              <> variables
      readCreateProcessWithExitCode
        (proc executable arguments) { env = Just controlled }
        ""

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
  code `shouldNotBe` ExitSuccess
  output `shouldBe` ""
  diagnostics `shouldContain` "Usage: hetoimasia"
  diagnostics `shouldContain` "--smoke"
  diagnostics `shouldContain` "--resource-smoke"

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
  forM_ consoleVariableNames (shouldContain output)
  -- The help path resolves configuration first, so an invalid value fails it
  -- too, printing no help at all.
  (rejected, helpOutput, reason) ← runConsole [("HETOIMASIA_DEBUG", "NONE")] ["--help"]
  rejected `shouldNotBe` ExitSuccess
  helpOutput `shouldBe` ""
  reason `shouldStartWith` "HETOIMASIA_DEBUG: "
