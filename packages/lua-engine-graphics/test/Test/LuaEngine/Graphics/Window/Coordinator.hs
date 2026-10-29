-- | The window provider on the real session coordinator (LFE-13): its stop and failure endpoints are the session's own
-- ('sessionWindowConfig'), the session is run by 'runSession' over a real content root, manifest, boot checkpoint,
-- read pool and supervised Lua owner, and what the examples read is what the session answers: whether it was asked to
-- stop, and the failure it latched.
--
-- The windows themselves are the gated fake port's, and the session's roles run a script that does nothing: the
-- facade binding that would open a window from Lua is LFE-21's, so no role asks for one. What is real here is the
-- coordinator the provider reports to, which is what the provider's contract with #527 is about. Evidence from the
-- fake port is injected evidence and says so.
module Test.LuaEngine.Graphics.Window.Coordinator (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (SomeException, finally, throwIO, try)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Content (defaultContentLimits, withContentRoot)
import Hetoimasia.Content.Identity (rootKey)
import Hetoimasia.Content.Inventory (InventorySpec (..), inventoryLimits, readVerified, scanInventory)
import Hetoimasia.Content.ReadPool (poolSpec, withReadPoolUsing)
import Hetoimasia.Foundation.Log (Logger, MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith)
import Hetoimasia.Foundation.Time (monotonicSource)
import Hetoimasia.LuaEngine.Boot (bootCheckpoint)
import Hetoimasia.LuaEngine.Facade (OutputSink (..), withOutput)
import Hetoimasia.LuaEngine.Graphics.Window.Port (CreateOutcome (..), Fatal (..))
import Hetoimasia.LuaEngine.Graphics.Window.Provider
import Hetoimasia.LuaEngine.Graphics.Window.Session (sessionWindowConfig)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Session
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (withSupervision)
import Hetoimasia.Scripting.Lua.Runtime (newLuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduler (systemTimerBackend)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import Test.LuaEngine.Graphics.Rig (bounded)
import Test.LuaEngine.Graphics.Window.Fake
import Test.LuaEngine.Graphics.Window.Rig (raisesWindowDefect)
import Test.LuaEngine.Graphics.Windows

spec ∷ Spec
spec = describe "on the real session coordinator" $ do
  it "routes a genuine native close during pending setup to the session's stop, with request capacity full, and the session ends as a quit" $ do
    outcome ← runWithSession $ \session → do
      fake ← newFake (FakeConfig [HoldAdmit])
      withWinComp (sessionWindowConfig session 1) (fakePort fake) $ \comp _ runtime → do
        vm ← startWinVm comp runtime "coordinator-vm"
        admit comp vm PresentationRole "a"
        commandOpen comp vm "a" "a" "t" (640, 480)
        attachWhenReady comp
        awaitFake fake ((== 1) . readingAttached)
        -- The one work record is held by the pending request: the ordinary capacity is full.
        nativeClose fake 1
        -- The session was asked to stop, by the endpoint that takes no slot and cannot be refused.
        atomically (sessionOutcomeNow session >>= \found → unless (outQuit found) retry)
        releaseAll fake
    outVerdict outcome `shouldBe` VerdictSuccess
    outQuit outcome `shouldBe` True
    outFailures outcome `shouldBe` []
    outRetired outcome `shouldBe` True

  it "latches a failed native destruction as the session's cleanup_failure" $ do
    outcome ← runWithSession $ \session → do
      fake ← newFake defaultFakeConfig
      raisesWindowDefect . withWinComp (sessionWindowConfig session 2) (fakePort fake) $ \comp _ runtime → do
        vm ← startWinVm comp runtime "coordinator-vm"
        admit comp vm PresentationRole "a"
        commandOpen comp vm "a" "a" "t" (640, 480)
        attachWhenReady comp
        awaitFake fake ((== 1) . readingAttached)
        failNativeDisposal fake
        endWindows (wcProvider comp)
        atomically (sessionOutcomeNow session >>= \found → unless (outTerminal found /= Nothing) retry)
    outVerdict outcome `shouldBe` VerdictFailure
    fmap rfCode (outTerminal outcome) `shouldBe` Just CleanupFailure
    erPrimary (outEngine outcome) `shouldSatisfy` (/= Nothing)

  it "latches a fatal creation fault as the session's host_failure" $ do
    outcome ← runWithSession $ \session → do
      fake ← newFake defaultFakeConfig
      scriptCreate fake [CreateFatal (Fatal "the creation was interrupted")]
      raisesWindowDefect . withWinComp (sessionWindowConfig session 2) (fakePort fake) $ \comp _ runtime → do
        vm ← startWinVm comp runtime "coordinator-vm"
        admit comp vm PresentationRole "a"
        commandOpen comp vm "a" "a" "t" (640, 480)
        atomically (sessionOutcomeNow session >>= \found → unless (outTerminal found /= Nothing) retry)
    outVerdict outcome `shouldBe` VerdictFailure
    fmap rfCode (outTerminal outcome) `shouldBe` Just HostFailure
  where
    attachWhenReady comp = do
      atomically (windowMainReady (wcProvider comp) >>= \ready → unless ready retry)
      windowMainStep (wcProvider comp)

-- | Run the real session on this thread, over a content root whose roles do nothing, and a scenario on another that
-- is handed the session as soon as it exists. If the scenario raises it stops the session, and the exception is
-- raised here once the session has ended and the scenario's thread has terminated: a failed assertion in it is never
-- swallowed.
runWithSession ∷ (Session → IO ()) → IO SessionOutcome
runWithSession scenario = bounded . withSystemTempDirectory "hetoimasia-window-coordinator" $ \tree → do
  mapM_
    ( \(path, bytes) → do
        createDirectoryIfMissing True (takeDirectory (tree </> path))
        ByteString.writeFile (tree </> path) bytes
    )
    [("hetoimasia.json", manifest), ("lua/main.lua", entryModule)]
  limits ← either (\refused → assertFailure ("scan limits refused: " <> show refused)) pure (inventoryLimits scanSpec)
  root' ← either (\refused → assertFailure ("root key refused: " <> show refused)) pure (rootKey "window-coordinator")
  pool ← either (\refused → assertFailure ("pool refused: " <> show refused)) pure (uncurry poolSpec (2, 16))
  withContentRoot defaultContentLimits tree $ \root → do
    inventory ← scanInventory limits root' root >>= either (\refused → assertFailure ("scan refused: " <> show refused)) pure
    checkpoint ← bootCheckpoint fixedM1Profile inventory (\_ _ → pure (Right manifest)) >>= either (\refused → assertFailure ("boot refused: " <> show refused)) pure
    withReadPoolUsing pool (readVerified inventory root) $ \readPool →
      withOutput quietSink quietSink $ \output →
        withLoggingLifetime quietLogger $ \lifetime →
          withSupervision lifetime $ \control → do
            runtime ← newLuaRuntime control
            handle ← newEmptyMVar
            result ← newEmptyMVar
            terminated ← newEmptyMVar
            _ ← forkIO $
              ( do
                  session ← readMVar handle
                  found ← try @SomeException (scenario session)
                  case found of
                    Left _ → requestStop session StopQuit
                    Right () → pure ()
                  putMVar result found
              )
                `finally` putMVar terminated ()
            let spec' =
                  SessionSpec
                    { sxProfile = fixedM1Profile
                    , sxCheckpoint = checkpoint
                    , sxInventory = inventory
                    , sxPool = readPool
                    , sxLogger = quietLogger
                    , sxOutput = output
                    , sxClock = monotonicSource
                    , sxTimer = systemTimerBackend
                    , sxRuntime = runtime
                    , sxControl = control
                    , sxHarness = noHarness
                    }
            outcome ← runSession spec' (putMVar handle)
            takeMVar terminated
            takeMVar result >>= either throwIO (const (pure outcome))

manifest ∷ ByteString
manifest = Text.encodeUtf8 "{\"format\":1,\"id\":\"window-coordinator\",\"entry\":\"lua/main.lua\",\"vms\":[{\"role\":\"presentation\",\"clock\":\"elapsed\"}]}"

-- | The roles run a behavior that does nothing: no role asks for a window (the binding is LFE-21's).
entryModule ∷ ByteString
entryModule =
  Text.encodeUtf8 . Text.unlines $
    [ "local function behavior(cadence)"
    , "  local b = cadence"
    , "  b.init = function(self, api) end"
    , "  b.update = function(self, dt) end"
    , "  b.shutdown = function(self, reason) end"
    , "  return b"
    , "end"
    , "return { gameplay = behavior({every_ticks = 1}), presentation = behavior({every_seconds = 1}) }"
    ]

scanSpec ∷ InventorySpec
scanSpec =
  InventorySpec
    { specEntries = 100
    , specSegments = 8
    , specPathBytes = 200
    , specSegmentBytes = 40
    , specFileBytes = 40 * 1024 * 1024
    , specRootBytes = 128 * 1024 * 1024
    , specBufferBytes = 64 * 1024
    }

quietSink ∷ OutputSink
quietSink = OutputSink {sinkLine = \_ → pure (), sinkFlush = pure ()}

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter metadata (callbackSink (\_ → pure ()))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }
