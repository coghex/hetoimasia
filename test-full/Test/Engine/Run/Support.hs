-- | What the @run@ examples share: games written into temporary folders, the command's real composition run
-- in this process without a native session, and the way an example observes it.
--
-- The composition is 'Hetoimasia.Run.runGame' with the one launch the suite substitutes: the production
-- session coordinator over real content, real filtered Lua VMs, the real module and data services and the real
-- read pool, with no graphics (a game that asks for a window gets the ordinary "no such call" error of a
-- session composed without one). Nothing here sleeps: an example knows what happened by blocking in STM on a line
-- a script printed, and every wait is bounded.
module Test.Engine.Run.Support
  ( -- * Games
    Files
  , manifestWith
  , commonManifest
  , lua
    -- * Running
  , Observed (..)
  , Probe (..)
  , Changes (..)
  , unchanged
  , observe
  , observeWith
  , launchWithout
  , quietFilter
  , silentLogger
  , withFolder
  , blockedFor
  ) where

import Control.Concurrent (ThreadId, forkIO, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (STM, TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Console.Lua.Signals (Delivery, deliver)
import GHC.Conc (BlockReason, ThreadStatus (ThreadBlocked), threadStatus)
import Hetoimasia.Foundation.Log (LogFilter (..), LogSink, Logger, callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Run.Settle (withRecordingLifetime)
import Hetoimasia.LuaEngine.Facade (OutputSink (..))
import Hetoimasia.LuaEngine.Session (SessionOutcome)
import Hetoimasia.Run (Setup (..), runGame)
import Hetoimasia.Run.Boot (BootHooks, Prepared, noBootHooks)
import Hetoimasia.Run.Session (Environment (..), SessionLink, newSessionLink, productionEnvironment, runPrepared)
import Hetoimasia.Runtime.Logging (LoggingLifetime, withHandleLoggingLifetime)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode)
import Data.Maybe (fromMaybe)
import System.FilePath (takeDirectory, (</>))
import System.IO (stderr)
import System.IO.Temp (withSystemTempDirectory)
import Test.Support.Bounded (bounded)

-- | The files of a game, by path under its folder.
type Files = [(FilePath, ByteString)]

-- | Text as the bytes of a file.
lua ∷ Text → ByteString
lua = Text.encodeUtf8

-- | A manifest whose declarations after @format@ and @id@ are these.
manifestWith ∷ [Text] → ByteString
manifestWith fields = lua ("{\"format\":1,\"id\":\"t\"," <> Text.intercalate "," fields <> "}")

-- | The default pair of roles on one common entry, @main.lua@, at a 10 ms tick.
commonManifest ∷ ByteString
commonManifest = manifestWith ["\"entry\":\"main.lua\"", "\"tick_seconds\":\"0.01\""]

-- | What an example may observe and do while the command runs.
data Probe = Probe
  { probeSignal ∷ IO Delivery
  -- ^ Deliver one SIGINT or SIGTERM to the coordinator: the very call the installed handlers make.
  , probeAwaitOut ∷ Text → IO ()
  -- ^ Block until a script printed exactly this line to stdout. Bounded.
  , probeAwaitErr ∷ (Text → Bool) → IO ()
  -- ^ Block until a line written to stderr satisfies this. Bounded.
  , probeForced ∷ STM Int
  -- ^ How many times the force action ran.
  }

-- | What the command did.
data Observed = Observed
  { observedStatus ∷ ExitCode
  , observedOut ∷ [Text]
  , observedErr ∷ [Text]
  , observedForced ∷ Int
  , observedReports ∷ [Text]
  -- ^ The terminal lines the command wrote for a failure.
  }
  deriving (Show)

-- | What an example changes about the composition: the sinks (a function of the recording ones) and the boot seam.
data Changes = Changes
  { changeSinks ∷ (OutputSink, OutputSink) → (OutputSink, OutputSink)
  , changePrepare ∷ FilePath → IO ()
  -- ^ Done to the folder after its files are written and before the command starts (a link, say).
  , changeBoot ∷ FilePath → BootHooks
  -- ^ The boot seam, given the folder: a step between the manifest's first read and the scan.
  , changeSink ∷ Maybe LogSink
  -- ^ The sink the logging lifetime is made over, instead of stderr's: one the example counts and breaks. The lifetime
  -- records its refusals where they occur, as the command's own does.
  , changeLink ∷ Maybe (IO SessionLink)
  -- ^ How the command makes its link to the session: one whose diagnostics writer the example holds.
  , changeEnvironment ∷ Environment → Environment
  -- ^ The session's environment: a clock that fails, say, from inside 'runSession'.
  , changeAfterLaunch ∷ LoggingLifetime → IO ()
  -- ^ Done once the session has returned its outcome and before the launch itself returns: where a cleanup of the
  -- scopes around the session fails, made on demand.
  }

unchanged ∷ Changes
unchanged = Changes id (\_ → pure ()) (\_ → noBootHooks) Nothing Nothing id (\_ → pure ())

-- | A filter that writes nothing, so a failing run does not fill the suite's own stderr.
quietFilter ∷ LogFilter
quietFilter = defaultLogFilter {filterEnabled = False}

-- | These files written into a temporary folder, which the body is given.
withFolder ∷ Files → (FilePath → IO a) → IO a
withFolder files body = withSystemTempDirectory "hetoimasia-run" $ \folder → do
  forM_ files $ \(path, bytes) → do
    createDirectoryIfMissing True (takeDirectory (folder </> path))
    ByteString.writeFile (folder </> path) bytes
  body folder

-- | A logger that writes nothing.
silentLogger ∷ Logger
silentLogger = mkLogger quietFilter (callbackSink (\_ → pure ()))

-- | Wait until a thread is blocked for this reason, by asking the runtime: coordination on what the thread is doing,
-- not a wait for time to pass.
blockedFor ∷ BlockReason → ThreadId → IO ()
blockedFor reason thread = bounded loop
  where
    loop = threadStatus thread >>= \status → unless (status == ThreadBlocked reason) (yield >> loop)

-- | The launch the suite substitutes for the native one: the real session over a prepared folder, no graphics.
launchWithout ∷ Environment → LoggingLifetime → STM Bool → SessionLink → Prepared → IO SessionOutcome
launchWithout environment lifetime stop link prepared = runPrepared environment lifetime stop link prepared Nothing (\_ → pure ())

-- | Run a game in this process and observe it.
observe ∷ Files → (Probe → IO ()) → IO Observed
observe = observeWith unchanged

-- | 'observe' with these changes. The folder is written first, the command is run with every wait of the
-- scenario bounded, and a failure of the scenario is raised after the command has returned and unwound.
observeWith ∷ Changes → Files → (Probe → IO ()) → IO Observed
observeWith changes files scenario = withFolder files $ \folder → do
  changePrepare changes folder
  out ← newTVarIO []
  err ← newTVarIO []
  forced ← newTVarIO 0
  reports ← newTVarIO []
  coordinator ← newEmptyMVar
  let record ref = OutputSink {sinkLine = \line → atomically (modifyTVar' ref (<> [line])), sinkFlush = pure ()}
      (stdoutSink, stderrSink) = changeSinks changes (record out, record err)
      environment = productionEnvironment {envStdout = stdoutSink, envStderr = stderrSink}
      setup =
        Setup
          { setupForce = atomically (modifyTVar' forced (+ 1))
          , setupReady = putMVar coordinator
          , setupBoot = changeBoot changes folder
          , setupLifetime = \configuration -> case changeSink changes of
              Just sink -> withRecordingLifetime defaultLogFilter sink
              Nothing -> withHandleLoggingLifetime configuration stderr
          , setupLink = fromMaybe newSessionLink (changeLink changes)
          , setupReport = \line -> atomically (modifyTVar' reports (<> [line]))
          , setupLaunch = \lifetime stop link prepared → runPrepared (changeEnvironment changes environment) lifetime stop link prepared Nothing (\_ → pure ()) <* changeAfterLaunch changes lifetime
          }
      probe =
        Probe
          { probeSignal = readMVar coordinator >>= deliver
          , probeAwaitOut = \line → bounded (awaitIn out (== line))
          , probeAwaitErr = \matches → bounded (awaitIn err matches)
          , probeForced = readTVar forced
          }
  finished ← newEmptyMVar ∷ IO (MVar (Either SomeException ()))
  _ ← forkIO (try (scenario probe) >>= putMVar finished)
  status ← bounded (runGame setup quietFilter folder)
  -- A scenario still waiting for a line the command never wrote fails its own bounded wait.
  bounded (readMVar finished) >>= either throwIO pure
  Observed status <$> readTVarIO out <*> readTVarIO err <*> readTVarIO forced <*> readTVarIO reports
  where
    awaitIn ∷ TVar [Text] → (Text → Bool) → IO ()
    awaitIn ref matches = atomically (readTVar ref >>= check . any matches)
