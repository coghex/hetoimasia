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
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (STM, TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Console.Lua.Signals (Delivery, deliver)
import Hetoimasia.Foundation.Log (LogFilter (..), defaultLogFilter)
import Hetoimasia.LuaEngine.Facade (OutputSink (..))
import Hetoimasia.LuaEngine.Session (SessionOutcome)
import Hetoimasia.Run (Setup (..), runGame)
import Hetoimasia.Run.Boot (BootHooks, Prepared, noBootHooks)
import Hetoimasia.Run.Session (Environment (..), newSessionLink, productionEnvironment, runPrepared)
import Hetoimasia.Runtime.Logging (LoggingLifetime)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode)
import System.FilePath (takeDirectory, (</>))
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
  }
  deriving (Show)

-- | What an example changes about the composition: the sinks (a function of the recording ones) and the boot seam.
data Changes = Changes
  { changeSinks ∷ (OutputSink, OutputSink) → (OutputSink, OutputSink)
  , changePrepare ∷ FilePath → IO ()
  -- ^ Done to the folder after its files are written and before the command starts (a link, say).
  , changeBoot ∷ FilePath → BootHooks
  -- ^ The boot seam, given the folder: a step between the manifest's first read and the scan.
  }

unchanged ∷ Changes
unchanged = Changes id (\_ → pure ()) (\_ → noBootHooks)

-- | A filter that writes nothing, so a failing run does not fill the suite's own stderr.
quietFilter ∷ LogFilter
quietFilter = defaultLogFilter {filterEnabled = False}

-- | The launch the suite substitutes for the native one: the real session over a prepared folder, no graphics.
launchWithout ∷ Environment → LoggingLifetime → STM Bool → Prepared → IO SessionOutcome
launchWithout environment lifetime stop prepared = do
  link ← newSessionLink
  runPrepared environment lifetime stop link prepared Nothing (\_ → pure ())

-- | Run a game in this process and observe it.
observe ∷ Files → (Probe → IO ()) → IO Observed
observe = observeWith unchanged

-- | 'observe' with these changes. The folder is written first, the command is run with every wait of the
-- scenario bounded, and a failure of the scenario is raised after the command has returned and unwound.
observeWith ∷ Changes → Files → (Probe → IO ()) → IO Observed
observeWith changes files scenario = withSystemTempDirectory "hetoimasia-run" $ \folder → do
  forM_ files $ \(path, bytes) → do
    createDirectoryIfMissing True (takeDirectory (folder </> path))
    ByteString.writeFile (folder </> path) bytes
  changePrepare changes folder
  out ← newTVarIO []
  err ← newTVarIO []
  forced ← newTVarIO 0
  coordinator ← newEmptyMVar
  let record ref = OutputSink {sinkLine = \line → atomically (modifyTVar' ref (<> [line])), sinkFlush = pure ()}
      (stdoutSink, stderrSink) = changeSinks changes (record out, record err)
      environment = productionEnvironment {envStdout = stdoutSink, envStderr = stderrSink}
      setup =
        Setup
          { setupForce = atomically (modifyTVar' forced (+ 1))
          , setupReady = putMVar coordinator
          , setupBoot = changeBoot changes folder
          , setupLaunch = launchWithout environment
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
  Observed status <$> readTVarIO out <*> readTVarIO err <*> readTVarIO forced
  where
    awaitIn ∷ TVar [Text] → (Text → Bool) → IO ()
    awaitIn ref matches = atomically (readTVar ref >>= check . any matches)
