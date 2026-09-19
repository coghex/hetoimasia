-- | The fixture every macOS confinement example is written against.
--
-- Two things in here are load-bearing rather than convenient.
--
-- The first is the positive controls. A denial is only evidence if the thing
-- denied was reachable in the first place, so the parent -- unconfined, in this
-- process -- reads the home sentinel, connects to both endpoints, runs the exec
-- target, and loads the native module before any helper is launched. A missing
-- file, an unbound socket, or a malformed dylib would otherwise produce exactly
-- the refusals the probe is looking for.
--
-- The second is that every path is canonical. The sandbox matches profile
-- literals against resolved paths, and a temporary directory on macOS is
-- reached through a symlink; a profile written in terms of the unresolved path
-- denies the directory it meant to allow, which is indistinguishable from
-- working.
module Test.MacOS.Driver
  ( Fixture (..)
  , Instance (..)
  , withFixture
  , helperArguments
  , launchHelper
  , accessesFrom
  , outcomeOf
  , mechanismOf
  , guardMicroseconds
  , Ending (..)
  , endWithEscalation
  , endQuietly
  , observeExit
  , Enforcement (..)
  , executionBudgetMicroseconds
  , escalationGraceMicroseconds
  , hardStopMicroseconds
  , enforceExecutionBudget
  ) where

import Control.Exception (ErrorCall (ErrorCall), IOException, bracket_, throwIO, try)
import Control.Monad (forM, unless, void)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , findExecutable
  , getHomeDirectory
  , removeFile
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withTempDirectory)
import System.Posix.Process (getProcessID)
import System.Process (readProcessWithExitCode)

import Test.Support.Bounded (boundMicroseconds)

import Hetoimasia.Scripting.Lua.Internal.MacOS.Confine
  ( Attempt (..)
  , attemptConnectUnix
  , attemptExecute
  , attemptLoadModule
  , attemptReadFile
  , helperProfile
  , openDescriptors
  , probeExecuteProgram
  , probeHomeSentinel
  , probeModuleSource
  , probeNativeModule
  , probeOwnEndpoint
  , probePeerEndpoint
  , probePeerSentinel
  )
import Hetoimasia.Scripting.Lua.Internal.MacOS.Launch
  ( Exit (..)
  , LaunchRequest (..)
  , Launched
  , awaitExit
  , awaitExitWithin
  , awaitStreamEnd
  , collectReports
  , launch
  , sendSignal
  , withEndpoint
  )
import GHC.Clock (getMonotonicTimeNSec)
import System.Posix.Signals (sigKILL, sigTERM)
import Hetoimasia.Scripting.Lua.Internal.MacOS.Report
  ( Origin (..)
  , Outcome (..)
  , Report (..)
  )

-- | One admitted instance's private world.
data Instance = Instance
  { instanceName ∷ Text
  , instancePrivate ∷ FilePath
  , instanceEndpoint ∷ FilePath
  , instanceSentinel ∷ FilePath
  }
  deriving (Eq, Show)

-- | Everything the examples share.
data Fixture = Fixture
  { fixtureRoot ∷ FilePath
  -- ^ The canonical directory holding both instances, both endpoints, the
  -- profile, and the native probe module.
  , fixtureHelper ∷ FilePath
  , fixtureProfile ∷ FilePath
  , fixtureHomeSentinel ∷ FilePath
  , fixtureExecTarget ∷ FilePath
  , fixtureNativeModule ∷ FilePath
  , fixtureFirst ∷ Instance
  , fixtureSecond ∷ Instance
  , fixtureControls ∷ [(Text, Attempt)]
  -- ^ The same accesses the confined helper attempts, made by the unconfined
  -- parent. Every one of them must be 'Allowed'.
  , fixtureParentCensus ∷ (Int, Int, Text)
  -- ^ The parent's own descriptors above stderr, taken while both endpoints
  -- were bound and just before the helper was spawned. It is the control for
  -- the helper's census: the parent really was holding the sockets that the
  -- helper turns out not to have.
  , fixtureSweep ∷ [Report]
  -- ^ One confined helper's whole report, in arrival order.
  , fixtureSweepExit ∷ Exit
  -- ^ How that helper ended.
  }

-- | The deadlock guard. It is never the thing an assertion depends on.
guardMicroseconds ∷ Int
guardMicroseconds = boundMicroseconds

-- | Build the fixture, run the examples against it, and take it all back down.
withFixture ∷ (Fixture → IO a) → IO a
withFixture action = do
  helper ←
    findExecutable "macos-confinement-helper"
      >>= maybe (throwIO (ErrorCall "no macos-confinement-helper on PATH")) pure
  socketRoot ← canonicalizePath "/tmp"
  -- Not the system temporary directory: a Unix-domain address is 104 bytes of
  -- sun_path on macOS, and TMPDIR's per-user folder is long enough on its own
  -- that an endpoint under it is rejected with ENAMETOOLONG before the sandbox
  -- has any say. The short root is a real constraint on this platform's IPC,
  -- not a convenience.
  withTempDirectory socketRoot "hmp" $ \rawRoot → do
    root ← canonicalizePath rawRoot
    first ← makeInstance root "instance-1"
    second ← makeInstance root "instance-2"
    let profile = root </> "helper.sb"
    Text.writeFile profile helperProfile
    nativeModule ← buildNativeModule root
    withHomeSentinel $ \homeSentinel →
      withEndpoint (instanceEndpoint first) $ \_ →
        withEndpoint (instanceEndpoint second) $ \_ → do
          controls ← runControls homeSentinel execTarget nativeModule first second
          parentCensus ← openDescriptors
          let partial =
                Fixture
                  { fixtureRoot = root
                  , fixtureHelper = helper
                  , fixtureProfile = profile
                  , fixtureHomeSentinel = homeSentinel
                  , fixtureExecTarget = execTarget
                  , fixtureNativeModule = nativeModule
                  , fixtureFirst = first
                  , fixtureSecond = second
                  , fixtureControls = controls
                  , fixtureParentCensus = parentCensus
                  , fixtureSweep = []
                  , fixtureSweepExit = ExitedWith (-1)
                  }
          (reports, status) ← sweep partial
          action partial{fixtureSweep = reports, fixtureSweepExit = status}
 where
  -- A real program the parent has just run itself, so a refused exec is the
  -- sandbox refusing rather than a path that was never executable.
  execTarget = "/bin/echo"

  makeInstance root name = do
    let private = root </> Text.unpack name
    createDirectoryIfMissing True private
    let sentinel = private </> "sentinel.txt"
    writeFile sentinel (Text.unpack name <> " sentinel\n")
    Text.writeFile (private </> "module.lua") probeModuleSource
    pure
      Instance
        { instanceName = name
        , instancePrivate = private
        , instanceEndpoint = root </> (Text.unpack name <> ".sock")
        , instanceSentinel = sentinel
        }

  sweep fixture = do
    launched ← launchHelper fixture (fixtureFirst fixture) (fixtureSecond fixture) "report" 0
    observeExit launched

-- | Run one helper, with the arguments its mode needs.
launchHelper ∷ Fixture → Instance → Instance → Text → Int → IO Launched
launchHelper fixture self peer mode memoryLimitMiB = do
  result ←
    launch
      LaunchRequest
        { requestExecutable = fixtureHelper fixture
        , requestArguments = helperArguments fixture self peer mode
        , requestMemoryLimitMiB = memoryLimitMiB
        }
  either (throwIO . ErrorCall . ("the helper could not be launched: " <>) . show) pure result

-- | The command line one instance is given.
helperArguments ∷ Fixture → Instance → Instance → Text → [String]
helperArguments fixture self peer mode =
  [ "--mode"
  , Text.unpack mode
  , "--profile"
  , fixtureProfile fixture
  , "--private"
  , instancePrivate self
  , "--endpoint"
  , instanceEndpoint self
  , "--peer-endpoint"
  , instanceEndpoint peer
  , "--home-sentinel"
  , fixtureHomeSentinel fixture
  , "--peer-sentinel"
  , instanceSentinel peer
  , "--exec-target"
  , fixtureExecTarget fixture
  , "--native-module"
  , fixtureNativeModule fixture
  , "--ceiling-mib"
  , "256"
  ]

-- | The parent's own unconfined attempt at everything the helper attempts.
runControls
  ∷ FilePath → FilePath → FilePath → Instance → Instance → IO [(Text, Attempt)]
runControls homeSentinel execTarget nativeModule first second =
  forM
    [ (probeHomeSentinel, attemptReadFile homeSentinel)
    , (probePeerSentinel, attemptReadFile (instanceSentinel second))
    , (probeOwnEndpoint, attemptConnectUnix (instanceEndpoint first))
    , (probePeerEndpoint, attemptConnectUnix (instanceEndpoint second))
    , (probeExecuteProgram, attemptExecute execTarget)
    , (probeNativeModule, attemptLoadModule nativeModule)
    ]
    (\(name, attempt) → fmap (\outcome → (name, outcome)) attempt)

-- | A disposable sentinel in the user's own home directory.
--
-- The home directory is the fixture requirement 4 names, and nothing else in
-- the user's home is read, written, or looked at. The name is unique to this
-- process so a run cannot collide with another, and it is removed even when an
-- example fails.
withHomeSentinel ∷ (FilePath → IO a) → IO a
withHomeSentinel action = do
  home ← getHomeDirectory
  pid ← getProcessID
  let path = home </> (".hetoimasia-macos-probe-" <> show pid <> ".sentinel")
  bracket_
    (writeFile path "hetoimasia macos confinement probe sentinel\n")
    (removeFile path)
    (action path)

-- | A real native module for the load probe, built where the helper cannot
-- reach it.
--
-- It is compiled rather than borrowed from the system so that the parent's own
-- successful load is a control over this exact file: a module that failed to
-- load for being malformed would look just like one the sandbox refused.
buildNativeModule ∷ FilePath → IO FilePath
buildNativeModule root = do
  let source = root </> "probe-module.c"
      target = root </> "libhetoimasia-probe-module.dylib"
  writeFile
    source
    "int hetoimasia_probe_module_symbol(void) { return 42; }\n"
  (code, out, err) ← readProcessWithExitCode "cc" ["-dynamiclib", "-o", target, source] ""
  unless (code == ExitSuccess) $
    throwIO (ErrorCall ("cannot build the native probe module: " <> out <> err))
  pure target

-- | The accesses one origin reported, in order.
accessesFrom ∷ Origin → [Report] → [(Text, Outcome, Text)]
accessesFrom wanted reports =
  [ (name, outcome, mechanism)
  | Access origin name outcome mechanism ← reports
  , origin == wanted
  ]

-- | One named access's outcome.
outcomeOf ∷ Text → [(Text, Outcome, Text)] → Maybe Outcome
outcomeOf name entries = (\(_, outcome, _) → outcome) <$> find (\(found, _, _) → found == name) entries

-- | One named access's recorded mechanism.
mechanismOf ∷ Text → [(Text, Outcome, Text)] → Maybe Text
mechanismOf name entries = (\(_, _, mechanism) → mechanism) <$> find (\(found, _, _) → found == name) entries


-- | Reap a helper and read everything it wrote, in that order.
--
-- Both halves, because they are different events: 'awaitExit' says the process
-- is gone, and only the stream's end says the parent has the whole of what it
-- said. Collecting between the two silently loses the last line — the refusal,
-- the ceiling, the final measurement — whenever the reader thread has not been
-- scheduled yet, so the wait is an error if it does not complete.
observeExit ∷ Launched → IO ([Report], Exit)
observeExit launched = do
  status ← awaitExit launched
  complete ← awaitStreamEnd launched guardMicroseconds
  unless complete $
    throwIO (ErrorCall "the helper was reaped but its output never reached end of file")
  reports ← collectReports launched
  pure (reports, status)

-- | What ending a helper took.
data Ending = Ending
  { endingEscalated ∷ Bool
  -- ^ Whether the polite signal was not enough.
  , endingExit ∷ Exit
  -- ^ The status the parent reaped. This, and not the successful signal send,
  -- is what releases a quota.
  , endingReports ∷ [Report]
  -- ^ Everything the helper wrote, read to end of file.
  }
  deriving (Eq, Show)

-- | End a helper through the platform's escalation path and observe it end.
--
-- Every wait is bounded, including the one after the hard signal: a reap that
-- could block forever is a suite that hangs rather than an example that fails.
endWithEscalation ∷ Launched → IO Ending
endWithEscalation launched = do
  _ ← sendSignal launched sigTERM
  polite ← awaitExitWithin launched escalationGraceMicroseconds
  case polite of
    Just status → finish False status
    Nothing → do
      _ ← sendSignal launched sigKILL
      hard ← awaitExitWithin launched hardStopMicroseconds
      case hard of
        Just status → finish True status
        Nothing → throwIO (ErrorCall "the helper outlived SIGKILL and its bound")
 where
  finish escalated status = do
    complete ← awaitStreamEnd launched guardMicroseconds
    unless complete $
      throwIO (ErrorCall "the helper ended but its output never reached end of file")
    reports ← collectReports launched
    pure (Ending escalated status reports)

-- | The execution budget an admitted helper is granted, in microseconds.
--
-- This is the policy under test, not a synchronisation delay: the examples that
-- use it have already established by handshake that the helper is running, and
-- what the budget's expiry proves is that the parent ends a helper that will
-- never stop on its own. Nothing waits on it to observe a state change.
executionBudgetMicroseconds ∷ Int
executionBudgetMicroseconds = 750000

-- | How long the polite signal is given before the hard one.
escalationGraceMicroseconds ∷ Int
escalationGraceMicroseconds = 2000000

-- | The last bound. Nothing survives a hard signal this long.
hardStopMicroseconds ∷ Int
hardStopMicroseconds = 5000000

-- | What enforcing the execution budget did.
data Enforcement = Enforcement
  { enforcementReason ∷ Text
  -- ^ The parent's own enforcement reason, recorded with the exit.
  , enforcementEscalated ∷ Bool
  , enforcementExit ∷ Exit
  , enforcementElapsedMicros ∷ Int
  -- ^ From the start of the granted budget to the reaped status.
  , enforcementReports ∷ [Report]
  }
  deriving (Eq, Show)

-- | Grant a running helper an execution budget, and enforce it when it expires.
--
-- The budget really expires here: the parent waits out the granted time, finds
-- the helper still running, and only then escalates. A helper that finishes
-- inside its budget is not a violation and is reported as one that completed,
-- so the example asserting enforcement cannot be satisfied by a helper that
-- simply exited.
enforceExecutionBudget ∷ Launched → IO Enforcement
enforceExecutionBudget launched = do
  started ← getMonotonicTimeNSec
  granted ← awaitExitWithin launched executionBudgetMicroseconds
  case granted of
    Just status → do
      complete ← awaitStreamEnd launched guardMicroseconds
      unless complete $
        throwIO (ErrorCall "the helper completed but its output never reached end of file")
      reports ← collectReports launched
      elapsed ← sinceMicros started
      pure (Enforcement "completed-within-budget" False status elapsed reports)
    Nothing → do
      ending ← endWithEscalation launched
      elapsed ← sinceMicros started
      pure
        Enforcement
          { enforcementReason = "execution-budget-exceeded"
          , enforcementEscalated = endingEscalated ending
          , enforcementExit = endingExit ending
          , enforcementElapsedMicros = elapsed
          , enforcementReports = endingReports ending
          }
 where
  sinceMicros started = do
    now ← getMonotonicTimeNSec
    pure (fromIntegral ((now - started) `div` 1000))

-- | End a helper that an example may already have ended.
--
-- Used only by fixture teardown, where reaping a status that is already reaped
-- is expected rather than a result.
endQuietly ∷ Launched → IO ()
endQuietly launched = void (try @IOException (endWithEscalation launched))
