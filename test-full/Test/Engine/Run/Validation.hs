-- | The production composition's optional Vulkan validation (LFE-28), without a device: what the host is configured to
-- ask of the loader, and the one record of requested versus resolved with a warning for each dropped item. The native
-- half (the layer and synchronization validation enabled in the actual command, clean through teardown) is
-- @run-native-tests@'s.
module Test.Engine.Run.Validation (spec) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Log (LogEntry (..), LogLevel (..), callbackSinkWith, defaultLogFilter, mkLogger, unsafeComponent)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ValidationChoice (..)
  , ValidationDisposition (..)
  , ValidationResolution (..)
  , VulkanHostConfig (..)
  )
import Hetoimasia.LuaEngine.Graphics.Scene (GraphicsScene, newSceneSession)
import Hetoimasia.LuaEngine.Graphics.Texture (configurationFor)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Run.Graphics (droppedItems, hostConfiguration, noObservation, reportResolution, validationFields)
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Test.Hspec (Spec, describe, it, shouldBe)

spec ∷ Spec
spec = describe "Validation" $ do
  describe "the production host's request" $ do
    it "asks the loader for no layer and no validation feature, and for no optional validation, when it is not requested" $ do
      config ← configured ValidationOff
      (vulkanLayers config, vulkanValidationFeatures config, vulkanOptionalValidation config) `shouldBe` ([], [], ValidationOff)

    it "carries the requested choice as the optional validation alone, leaving the strict layers and features empty" $ do
      config ← configured ValidationOn
      (vulkanLayers config, vulkanValidationFeatures config, vulkanOptionalValidation config) `shouldBe` ([], [], ValidationOn)

  describe "the record" $ do
    it "says for each item whether it was requested, enabled or dropped" $ do
      validationFields notRequested `shouldBe` [("requested", "false"), ("layer", "not-requested"), ("feature", "not-requested")]
      validationFields bothEnabled `shouldBe` [("requested", "true"), ("layer", "enabled"), ("feature", "enabled")]
      validationFields layerOnly `shouldBe` [("requested", "true"), ("layer", "enabled"), ("feature", "dropped")]
      validationFields neither `shouldBe` [("requested", "true"), ("layer", "dropped"), ("feature", "dropped")]

    it "names a dropped item and why, and nothing else" $ do
      droppedItems notRequested `shouldBe` []
      droppedItems bothEnabled `shouldBe` []
      map fst (droppedItems layerOnly) `shouldBe` ["synchronization-validation"]
      map fst (droppedItems neither) `shouldBe` ["VK_LAYER_KHRONOS_validation", "synchronization-validation"]

    it "writes one info entry, and one warning for each dropped item, under the run.graphics component" $ do
      forM_ [notRequested, bothEnabled, layerOnly, neither] $ \resolution → do
        entries ← written resolution
        let infos = [entry | entry <- entries, entryLevel entry == Info]
            warnings = [entry | entry <- entries, entryLevel entry == Warning]
        length entries `shouldBe` length infos + length warnings
        map entryComponent entries `shouldBe` map (const (unsafeComponent "run.graphics")) entries
        map entryMessage infos `shouldBe` ["vulkan validation resolved"]
        map (Map.toList . entryFields) infos `shouldBe` [Map.toList (Map.fromList (validationFields resolution))]
        map entryMessage warnings `shouldBe` ["vulkan validation item dropped" | _ ← droppedItems resolution]
        map (Map.lookup "item" . entryFields) warnings `shouldBe` [Just item | (item, _) ← droppedItems resolution]
  where
    notRequested = ValidationResolution DispositionNotRequested DispositionNotRequested
    bothEnabled = ValidationResolution DispositionEnabled DispositionEnabled
    layerOnly = ValidationResolution DispositionEnabled DispositionDropped
    neither = ValidationResolution DispositionDropped DispositionDropped

configured ∷ ValidationChoice → IO (VulkanHostConfig GraphicsScene)
configured choice = do
  texture ← either (\refused → fail ("the profile cannot be mapped: " <> show refused)) pure (configurationFor fixedM1Profile)
  scenes ← newSceneSession
  pure (hostConfiguration noObservation choice texture scenes)

-- | What the record's writer emits, in order, through a logger whose sink is a list.
written ∷ ValidationResolution → IO [LogEntry]
written resolution = do
  entries ← newTVarIO []
  let sink = callbackSinkWith (\entry → atomically (modifyTVar' entries (entry :))) (pure ())
  withLoggingLifetime (mkLogger defaultLogFilter sink) (\lifetime → reportResolution lifetime resolution)
  reverse <$> readTVarIO entries
