-- | What the console examples share: the built executable, the controlled environment it is run in,
-- and the child process handling the signal examples need.
--
-- A child is always run under 'withChild', which on every way out kills what is still running with
-- @SIGKILL@, independently of any signal an example sends, and reaps it, bounded. A cooperative signal
-- is not a cleanup: @SIGTERM@ requests an orderly stop in the @lua@ subcommand, and a script whose
-- shutdown never returns can hold that stop indefinitely.
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

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (void)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (LogVariables (..), variableComponentLevels, variableDebug, variableGlobalLevel)
import System.Directory (findExecutable)
import System.Environment (getEnvironment)
import System.Exit (ExitCode)
import System.FilePath ((</>))
import System.IO (Handle, hClose, hGetContents', hGetLine, hSetEncoding, utf8)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (Signal, sigKILL, signalProcess)
import System.Process
  ( CreateProcess (env, std_err, std_in, std_out)
  , ProcessHandle
  , StdStream (CreatePipe, NoStream)
  , createProcess
  , getPid
  , proc
  , readCreateProcessWithExitCode
  , waitForProcess
  )
import System.Timeout (timeout)
import Test.Support.Bounded (bounded)

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
  readCreateProcessWithExitCode (proc executable arguments) {env = Just controlled} ""

-- | A running child of the executable.
data Child = Child
  { childProcess ∷ ProcessHandle
  , childOut ∷ Handle
  , childErrors ∷ MVar String
    -- ^ Everything the child wrote to stderr, once it has closed it.
  , childExit ∷ MVar ExitCode
  }

-- | Run the executable as a child with its stdout and stderr on pipes, and always, on every way out,
-- kill it with @SIGKILL@ if it is still running and reap it.
withChild ∷ [(String, String)] → [String] → (Child → IO a) → IO a
withChild = withChildOf consoleExecutable

-- | 'withChild' of the executable this action names: the suite's own binary, for the examples that run the
-- command's composition as a child of their own.
withChildOf ∷ IO FilePath → [(String, String)] → [String] → (Child → IO a) → IO a
withChildOf locate variables arguments = bracket start finish
  where
    start = do
      executable ← locate
      controlled ← controlledEnvironment variables
      (_, out, errors, process) ←
        createProcess (proc executable arguments) {env = Just controlled, std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe}
      case (out, errors) of
        (Just output, Just diagnostics) → do
          hSetEncoding output utf8
          hSetEncoding diagnostics utf8
          errorsBox ← newEmptyMVar
          void (forkIO (hGetContents' diagnostics >>= putMVar errorsBox))
          exitBox ← newEmptyMVar
          void (forkIO (waitForProcess process >>= putMVar exitBox))
          pure (Child process output errorsBox exitBox)
        _ → fail "the child's pipes were not created"
    finish child = do
      -- Independently of any signal under test. A process that has already been reaped has no pid.
      _ ← try (getPid (childProcess child) >>= mapM_ (signalProcess sigKILL)) ∷ IO (Either SomeException ())
      void (timeout 10000000 (readMVar (childExit child)))
      _ ← try (hClose (childOut child)) ∷ IO (Either SomeException ())
      pure ()

-- | Read stdout lines until one is exactly this marker, answering the lines read, marker last. Every
-- read is bounded.
awaitMarker ∷ Child → String → IO [String]
awaitMarker child marker = go []
  where
    go seen = do
      line ← bounded (hGetLine (childOut child))
      if line == marker then pure (reverse (line : seen)) else go (line : seen)

-- | Send the child a signal.
sendSignal ∷ Signal → Child → IO ()
sendSignal signal child =
  getPid (childProcess child) >>= maybe (fail "the child is no longer running") (signalProcess signal)

-- | The child's exit status, waited for with a bound.
awaitExit ∷ Child → IO ExitCode
awaitExit child = bounded (readMVar (childExit child))

-- | The rest of the child's stdout, to its end, bounded.
readRest ∷ Child → IO String
readRest child = bounded (hGetContents' (childOut child))

-- | Everything the child wrote to stderr, once it has exited, bounded.
readErrors ∷ Child → IO String
readErrors child = bounded (readMVar (childErrors child))

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
