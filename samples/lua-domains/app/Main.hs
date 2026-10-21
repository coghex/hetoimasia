-- | @hetoimasia-lua-domains [--ticks N] [--seed N] [--scenario NAME] [--record FILE] [--replay FILE] [--digests]
-- [--expect-digest HEX]@: a headless session of a UI Lua VM owner and a gameplay Lua VM owner against a fixed scripted
-- fake input source, or against an input log.
--
-- It commits N ticks (twenty by default), or fewer when the scenario's failure or stop ends the session, retires
-- both owners, and prints one bounded report on stdout, then the digest trace if @--digests@ asks. @--record FILE@ writes
-- the intentions and controls the session accepted as an input log, to a path that does not exist; @--replay FILE@ takes
-- the session's intentions and controls from such a log and from nothing else. It exits 0 when the session ended without a
-- failure (a stop is not one) and 1 when the gameplay session failed or a UI failure was recorded, when the final digest is
-- not the one @--expect-digest@ names (a match never changes a failure's status), or when a requested recording could not be
-- made; a failure of the host propagates as an uncaught exception and exits 1 as well. @--help@ prints the usage and exits
-- 0. Any unknown or malformed argument, an unreadable or invalid replay file, a log that cannot be replayed in the session
-- asked for, or an output path that exists prints one bounded usage line on stderr and exits 2, before any session starts.
-- Diagnostics go to stderr, and no window is created.
--
-- The session runs through the runtime's public lifecycle: the logging lifetime over @stderr@,
-- entered first and left last, and the supervision boundary both owners are created under. Between
-- ticks it waits five milliseconds of real time so the UI owner, which updates every two, has
-- something to do; that pacing changes when a commit happens and never what it contains.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, when)
import qualified Data.Text.IO as Text
import Hetoimasia.Foundation.Log (defaultLogFilter)
import Hetoimasia.Runtime.Application (runScopedApplication)
import Hetoimasia.Runtime.Logging (withHandleLoggingLifetime)
import Hetoimasia.Sample.LuaDomains
  ( DomainsConfig (configBounds, configGameplaySource, configInput, configPace, configReplay, configScenario, configSeed, configStopAfter, configTicks, configUiScenario)
  , SessionReport (reportRecorded)
  , defaultConfig
  , renderReport
  , runSession
  , scenarioGameplay
  , scenarioInputs
  , scenarioName
  , scenarioStopAfter
  , withDomains
  )
import Hetoimasia.Sample.LuaDomains.Canonical (digestHex)
import Hetoimasia.Sample.LuaDomains.Command (Command (..), Parsed (Help, Run), Problem (..), helpText, parseArguments, problemLine)
import Hetoimasia.Sample.LuaDomains.Files (FileProblem (FileMalformed), checkOutputPath, fileProblemText, loadLog, writeLog)
import Hetoimasia.Sample.LuaDomains.InputLog (InputLog, checkReplayable, logRecords, recordProblemText, refusalText, replayProblemText)
import Hetoimasia.Sample.LuaDomains.Report (RecordOutcome (..), digestMismatch, finalExit, renderRecordLine, renderTrace)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)
import System.IO (hFlush, hSetEncoding, stderr, stdout, utf8)

main ∷ IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  arguments ← getArgs
  case parseArguments arguments of
    Left problem → do
      Text.hPutStrLn stderr (problemLine problem)
      hFlush stderr
      exitWith (ExitFailure 2)
    Right Help → Text.putStr helpText
    Right (Run command) → runCommand command

-- | Refuse the command line, as a usage error: one bounded line on stderr, exit status 2, and no session.
refuse ∷ Problem → IO a
refuse problem = do
  Text.hPutStrLn stderr (problemLine problem)
  hFlush stderr
  exitWith (ExitFailure 2)

runCommand ∷ Command → IO ()
runCommand command = do
  -- The files are checked before anything starts: a log that cannot be read or replayed, or a path that cannot be
  -- recorded to, is a usage error, and no session is run for it.
  replay ← traverse (loadReplay command) (commandReplay command)
  forM_ (commandRecord command) $ \path →
    checkOutputPath path >>= either (refuse . RecordRefused path . fileProblemText) pure
  let scenario = commandScenario command
      config =
        defaultConfig
          { configTicks = Just (commandTicks command)
          , configSeed = commandSeed command
          , configScenario = scenarioName scenario
          , -- A replay takes its intentions and controls from the log alone: the UI has nothing of its own to offer, and
            -- reads the scenario as @normal@, which asks for no control of its own.
            configInput = maybe (scenarioInputs scenario) (const []) replay
          , configReplay = replay
          , configUiScenario = maybe Nothing (const (Just "normal")) replay
          , configGameplaySource = scenarioGameplay scenario
          , configStopAfter = scenarioStopAfter scenario
          , configPace = \_ → threadDelay 5000
          }
  report ←
    runScopedApplication
      (withHandleLoggingLifetime defaultLogFilter stderr)
      "hetoimasia-lua-domains"
      (pure ())
      (\() _ → pure ())
      (\() control → withDomains control config runSession)
  mapM_ Text.putStrLn (renderReport report)
  recorded ← case commandRecord command of
    Nothing → pure NotRecording
    Just path → case reportRecorded report of
      Left problem → pure (RecordFailed path (recordProblemText problem))
      Right log' →
        writeLog path log' >>= \case
          Left problem → pure (RecordFailed path (fileProblemText problem))
          Right () → pure (Recorded (length (logRecords log')) path)
  mapM_ Text.putStrLn (renderRecordLine recorded)
  when (commandDigests command) (mapM_ Text.putStrLn (renderTrace report))
  hFlush stdout
  forM_ (digestMismatch report (commandExpect command)) $ \(wanted, found) →
    Text.hPutStrLn stderr ("hetoimasia-lua-domains: digest mismatch: expected " <> digestHex wanted <> ", final " <> digestHex found)
  hFlush stderr
  case finalExit report (commandExpect command) recorded of
    ExitSuccess → pure ()
    status → exitWith status

-- | Read the log @--replay@ names, and check that this session can replay it, refusing otherwise.
loadReplay ∷ Command → FilePath → IO InputLog
loadReplay command path =
  loadLog path >>= \case
    Left (FileMalformed refusal) → refuse (ReplayMalformed path (refusalText refusal))
    Left problem → refuse (ReplayUnreadable path (fileProblemText problem))
    Right log' → case checkReplayable (configBounds defaultConfig) (Just (commandTicks command)) (scenarioStopAfter (commandScenario command)) log' of
      [] → pure log'
      first : more → refuse (ReplayNotReplayable path (replayProblemText first) (length more))
