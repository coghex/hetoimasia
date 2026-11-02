-- | The command's policy on native initialization (#586), without a device: when the deadline is armed, the bound it
-- states, and the one diagnostic it makes. The guard that enforces it, the exit and the real process that proves it are
-- @glfw-tests@' and @glfw-native-tests@'; the batch that proves the prevention is the optional repeated-run probe's.
module Test.Engine.Run.Initialization (spec) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Log (LogEntry (..), LogLevel (..), Logger, callbackSinkWith, defaultLogFilter, mkLogger, unsafeComponent)
import Hetoimasia.GLFW.Session (InitializationDeadline (..), InitializationExpiry (..), SessionConfig (..), initializationTimeoutStatus)
import Hetoimasia.GPU.Vulkan.GLFW (ValidationChoice (..), VulkanHostConfig (..))
import Hetoimasia.LuaEngine.Graphics.Scene (GraphicsScene, newSceneSession)
import Hetoimasia.LuaEngine.Graphics.Texture (configurationFor)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Run.Graphics (hostConfiguration, initializationBoundMicroseconds, noObservation, productionInitializationDeadline, withInitializationDeadline)
import Hetoimasia.Runtime.GLFW (HostConfig (..))
import System.Info (os)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Initialization" $ do
  describe "the deadline" $ do
    it "is armed on macOS only, and leaves the host configuration otherwise as it was" $ do
      config ← configured
      recording ← recorded
      let armed = withInitializationDeadline (recordingLogger recording) config
          session = hostSessionConfig . vulkanHost
      initializationDeadline (session config) `shouldBe` Nothing
      if os == "darwin"
        then fmap deadlineBoundMicroseconds (initializationDeadline (session armed)) `shouldBe` Just initializationBoundMicroseconds
        else initializationDeadline (session armed) `shouldBe` Nothing
      requestedBackend (session armed) `shouldBe` requestedBackend (session config)

    it "states ten seconds, more than a hundred times the slowest healthy initialization measured (0.094 s)" $ do
      initializationBoundMicroseconds `shouldBe` 10_000_000
      initializationBoundMicroseconds `shouldSatisfy` (>= 100 * 94_000)

    it "stays inside the complete native profile's 30-second budget with the report's two-second allowance" $
      (initializationBoundMicroseconds + 2_000_000) `shouldSatisfy` (< 30_000_000)

  describe "the report" $
    it "is one error entry under run.graphics naming the observed condition and not a cause, then one flush" $ do
      recording <- recorded
      deadlineReport (productionInitializationDeadline (recordingLogger recording)) expiry
      written <- reverse <$> readTVarIO (recordingEntries recording)
      flushed <- readTVarIO (recordingFlushes recording)
      flushed `shouldBe` 1
      map entryLevel written `shouldBe` [Error]
      map entryComponent written `shouldBe` [unsafeComponent "run.graphics"]
      map entryMessage written `shouldBe` ["native initialization exceeded its bound; ending the process"]
      map (Map.toList . entryFields) written
        `shouldBe` [ Map.toList . Map.fromList $
                       [ ("backend", "cocoa")
                       , ("bound_microseconds", "10000000")
                       , ("exit_status", "75")
                       , ("observed", "glfwInit had not returned")
                       , ("see", "docs/glfw.md#entry")
                       ]
                   ]
  where
    expiry = InitializationExpiry {expiryBackend = "cocoa", expiryBoundMicroseconds = initializationBoundMicroseconds, expiryStatus = initializationTimeoutStatus}

configured ∷ IO (VulkanHostConfig GraphicsScene)
configured = do
  texture ← either (\refused → fail ("the profile cannot be mapped: " <> show refused)) pure (configurationFor fixedM1Profile)
  scenes ← newSceneSession
  pure (hostConfiguration noObservation ValidationOff texture scenes)

-- | A logger whose sink is a list, and a count of its flushes.
data Recording = Recording
  { recordingLogger ∷ Logger
  , recordingEntries ∷ TVar [LogEntry]
  , recordingFlushes ∷ TVar Int
  }

recorded ∷ IO Recording
recorded = do
  entries ← newTVarIO []
  flushes ← newTVarIO 0
  let sink = callbackSinkWith (\entry → atomically (modifyTVar' entries (entry :))) (atomically (modifyTVar' flushes (+ 1)))
  pure Recording {recordingLogger = mkLogger defaultLogFilter sink, recordingEntries = entries, recordingFlushes = flushes}
