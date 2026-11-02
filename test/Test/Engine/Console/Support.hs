-- | What the console examples share: the built executable, the controlled environment it is run in,
-- and the child process handling the signal examples need.
--
-- A child is always run under 'withChild', which is the shared subprocess facility's scoped child
-- ("Test.Support.Subprocess", #588): on every way out it sends the child's process group @SIGTERM@, @SIGKILL@
-- after a grace, independently of any signal an example sends, and reaps it with the wait confirmed. A
-- cooperative signal is not a cleanup: @SIGTERM@ requests an orderly stop in the @lua@ subcommand, and a
-- script whose shutdown never returns can hold that stop, which the grace and the kill then end.
module Test.Engine.Console.Support
  ( -- * The executable
    consoleVariables
  , consoleVariableNames
  , consoleExecutable
  , controlledEnvironment
  , runConsole
    -- * Children
  , Child
  , withChild
  , withChildOf
  , awaitMarker
  , sendSignal
  , awaitExit
  , readRest
  , readErrors
  , Outcome (..)
  , runToCompletion
    -- * Script files
  , withLuaFiles
  ) where

import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (LogVariables (..), variableComponentLevels, variableDebug, variableGlobalLevel)
import System.Directory (findExecutable)
import System.Environment (getEnvironment)
import System.Exit (ExitCode)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (Signal)
import System.Process (CreateProcess (env), proc)
import Test.Support.Bounded (boundMicroseconds)
import qualified Test.Support.Subprocess as Facility

-- | The variable names the console application chooses.
consoleVariables ∷ LogVariables
consoleVariables = LogVariables
  { variableGlobalLevel = "HETOIMASIA_LOG_LEVEL"
  , variableComponentLevels = "HETOIMASIA_LOG_LEVELS"
  , variableDebug = "HETOIMASIA_DEBUG"
  }

-- | The three variable names the console application reads, as the environment spells them.
consoleVariableNames ∷ [String]
consoleVariableNames =
  map Text.unpack
    [ variableGlobalLevel consoleVariables
    , variableComponentLevels consoleVariables
    , variableDebug consoleVariables
    ]

-- | The built executable, reached through this suite's @build-tool-depends@ on it rather than a
-- guessed build path.
consoleExecutable ∷ IO FilePath
consoleExecutable =
  findExecutable "hetoimasia" >>= maybe (fail "the hetoimasia executable is not on this test's search path") pure

-- | The inherited environment stripped of the three logging variables, then these: so an inherited
-- value can neither defeat a quiet run nor fail a default one.
controlledEnvironment ∷ [(String, String)] → IO [(String, String)]
controlledEnvironment variables = do
  inherited ← getEnvironment
  pure ([pair | pair@(name, _) ← inherited, name `notElem` consoleVariableNames] <> variables)

-- | Run the built executable with exactly the logging variables a case asks for.
runConsole ∷ [(String, String)] → [String] → IO (ExitCode, String, String)
runConsole variables arguments = do
  executable ← consoleExecutable
  controlled ← controlledEnvironment variables
  -- The 30-minute budget of the group that runs these examples: a hang-catcher, never a timing assumption.
  Facility.runCaptured (Facility.Within (1800 * 1000000)) (proc executable arguments) {env = Just controlled} ""

-- | A running child of the executable: the shared subprocess facility's child, which the facility owns (#588).
newtype Child = Child Facility.Child

-- | Run the executable as a child with its stdout and stderr on pipes and no standard input, and on every way out end it and reap
-- it: SIGTERM to its process group, SIGKILL after the grace, the reap confirmed, independently of any signal an example sends.
withChild ∷ [(String, String)] → [String] → (Child → IO a) → IO a
withChild = withChildOf consoleExecutable

-- | 'withChild' of the executable this action names: the suite's own binary, for the examples that run the
-- command's composition as a child of their own.
withChildOf ∷ IO FilePath → [(String, String)] → [String] → (Child → IO a) → IO a
withChildOf locate variables arguments body = do
  executable ← locate
  controlled ← controlledEnvironment variables
  -- No standard input stream, as before: the facility's default for the input is absent. The run bound is the 30-minute budget of
  -- the group that runs these examples; every wait in them has its own, shorter bound.
  Facility.withScopedChild (Facility.childSpec (Facility.Within (1800 * 1000000)) (proc executable arguments) {env = Just controlled}) (body . Child)

-- | Read stdout lines until one is exactly this marker, answering the lines read, marker last. Every
-- read is bounded.
awaitMarker ∷ Child → String → IO [String]
awaitMarker (Child child) marker = go []
  where
    go seen = do
      line ← Facility.nextLine child Facility.Stdout boundMicroseconds
      case line of
        Facility.Line text
          | text == marker → pure (reverse (text : seen))
          | otherwise → go (text : seen)
        Facility.EndOfStream → fail ("the child's output ended before the marker " <> show marker <> "; read " <> show (reverse seen))
        Facility.TimedOut → fail ("a bounded test call never returned: waiting for the marker " <> show marker)

-- | Send the child a signal.
sendSignal ∷ Signal → Child → IO ()
sendSignal signal (Child child) = Facility.signalChild child signal

-- | The child's exit status, waited for with a bound.
awaitExit ∷ Child → IO ExitCode
awaitExit (Child child) =
  Facility.waitChild child boundMicroseconds >>= maybe (fail "a bounded test call never returned: waiting for the child to exit") pure

-- | The rest of the child's stdout, to its end, bounded.
readRest ∷ Child → IO String
readRest (Child child) =
  Facility.restOfOutput child Facility.Stdout boundMicroseconds >>= maybe (fail "a bounded test call never returned: reading the rest of the output") pure

-- | Everything the child wrote to stderr, once it has exited, bounded.
readErrors ∷ Child → IO String
readErrors (Child child) =
  Facility.restOfOutput child Facility.Stderr boundMicroseconds >>= maybe (fail "a bounded test call never returned: reading the errors") pure

-- | What a child that ran to its end did.
data Outcome = Outcome
  { outcomeCode ∷ ExitCode
  , outcomeOut ∷ String
  , outcomeErr ∷ String
  }
  deriving (Show)

-- | Run the executable to its end, every wait bounded, and answer its status and both streams.
runToCompletion ∷ [(String, String)] → [String] → IO Outcome
runToCompletion variables arguments = withChild variables arguments $ \child → do
  stdout ← readRest child
  code ← awaitExit child
  diagnostics ← readErrors child
  pure (Outcome code stdout diagnostics)

-- | Write these Lua files, by name, into a directory of their own, and run the body with the way to
-- name each one's path. A name that was not written is the caller's mistake and fails the example.
withLuaFiles ∷ [(FilePath, String)] → ((FilePath → FilePath) → IO a) → IO a
withLuaFiles files body = withSystemTempDirectory "hetoimasia-lua" $ \directory → do
  mapM_ (\(name, text) → writeFile (directory </> name) text) files
  body (\name → if name `elem` map fst files then directory </> name else error ("no such script written: " <> name))
