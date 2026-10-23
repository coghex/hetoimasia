-- | The graphics adapter's real-device suite: a texture request finished through verified reading, bounded
-- decoding and the production backend on the production graphics owner of a window-free session, and the
-- device's own evidence for it.
--
-- The order is the contract. The Vulkan environment is established before any Vulkan call, and consent is read
-- once, before anything native; a run without consent refuses and exits non-zero. The process main thread
-- then owns the session (the loader integration, the production host, the owner), Hspec runs on a thread of
-- its own, the session is released only once Hspec has finished, and only then are the checks that need the
-- roots gone applied: the destruction order, and the diagnostic capture's final verdict, which fails on any
-- validation error or incomplete capture.
--
-- Run it through the catalog group @test.vulkan-lua-engine-native@, or the commands that group runs:
--
-- > bash tools/vulkan/run.sh build hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests
-- > bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests
--
-- which on Linux starts an isolated X11 display for it and on macOS needs the desktop opt-in,
-- @HETOIMASIA_NATIVE_SESSION=desktop@, on the run's own command, given under the owner's standing approval
-- (AGENTS.md). The suite opens no window. See @packages/lua-engine-graphics/README.md@.
module Main (main) where

import Control.Monad (forM_, unless, when)
import Data.List (isPrefixOf)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, getProgName, lookupEnv)
import System.Exit (ExitCode (ExitFailure), exitFailure, exitWith)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, stderr, stdout)
import System.Info (arch, compilerName, compilerVersion, os)

import Hetoimasia.GPU.Vulkan.Diagnostics (DiagnosticVerdict (..), verdictIssues)
import Hetoimasia.LuaEngine.Graphics.Texture
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.LuaEngine.Graphics.Native.Consent (Consent, consentBackend, describeConsent, readConsent, refusalMessage)
import Test.LuaEngine.Graphics.Native.Environment (checkValidationFeatures, establishEnvironment, validationFeatures)
import Test.LuaEngine.Graphics.Native.Loader (checkLoader)
import Test.LuaEngine.Graphics.Native.Session (Facts (..), runSession)
import qualified Test.LuaEngine.Graphics.Native.Spec as Native

main ∷ IO ()
main = do
  hSetBuffering stdout LineBuffering
  started ← getCurrentTime
  environment ← establishEnvironment
  arguments ← getArgs
  when (completeFlag `elem` arguments && arguments /= [completeFlag]) $ do
    hPutStrLn stderr ("lua-engine-graphics-native-tests: " <> completeFlag <> " runs the whole profile and takes no other argument")
    exitWith (ExitFailure 2)
  forM_ environment (Text.putStrLn . ("lua-engine-graphics-native-tests: " <>))
  consent ← readConsent >>= either refuse pure
  checkValidationFeatures >>= either (\why → stop ("validation features: " <> why)) pure
  loader ← checkLoader >>= either (\why → stop ("the qualified loader: " <> why)) pure
  Text.putStrLn ("lua-engine-graphics-native-tests: the binding's loader is the recorded loader " <> Text.pack loader)
  configuration ← either (\refused → stop ("the profile could not be mapped: " <> Text.pack (show refused))) pure (configurationFor fixedM1Profile)
  facts ← runSession (arguments == [completeFlag]) (consentBackend consent) validationFeatures configuration Native.spec
  finished ← getCurrentTime
  let problems = checks facts
      seconds = realToFrac (diffUTCTime finished started) ∷ Double
  record ← evidenceRecord consent loader configuration facts problems seconds
  Text.putStrLn record
  directory ← lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE"
  forM_ directory $ \place → do
    createDirectoryIfMissing True place
    Text.writeFile (place </> "lua-engine-graphics-native.md") record
  forM_ problems (hPutStrLn stderr . ("lua-engine-graphics-native-tests: " <>) . Text.unpack)
  unless (null problems) exitFailure
  where
    refuse refusal = hPutStrLn stderr ("lua-engine-graphics-native-tests: " <> Text.unpack (refusalMessage refusal)) >> exitWith (ExitFailure 3)
    stop why = hPutStrLn stderr ("lua-engine-graphics-native-tests: " <> Text.unpack why) >> exitFailure

-- | Runs the whole profile with nothing an environment could narrow, which the catalog group passes; without it
-- the suite is an ordinary Hspec run that selects as asked.
completeFlag ∷ String
completeFlag = "--complete"

-- | What a run must have shown whatever Hspec reported.
checks ∷ Facts → [Text]
checks facts =
  [ "an example failed" | not (factsPassed facts) ]
    <> [ "the session ended with a failure: " <> failure | Just failure ← [factsFailure facts] ]
    <> [ "a native call raised: " <> name <> ": " <> reason | (name, Just reason) ← factsCalls facts ]
    <> orderProblems
    <> verdictProblems
  where
    names = map fst (factsCalls facts)
    positions name = [index | (index, called) ← zip [0 ∷ Int ..] names, called == name]
    firstOf name = if null (positions name) then Nothing else Just (minimum (positions name))
    lastOf name = if null (positions name) then Nothing else Just (maximum (positions name))
    before earlier later = case (earlier, later) of
      (Just a, Just b) → a < b
      _ → True
    orderProblems =
      [ "the roots were not destroyed image views, device, messenger, instance, with the instance last: " <> Text.intercalate ", " [name | name ← names, Text.isPrefixOf "vkDestroy" name]
      | not
          ( lastOf "vkDestroyImageView" `before` firstOf "vkDestroyDevice"
              && lastOf "vkDestroyDevice" `before` firstOf "vkDestroyDebugUtilsMessengerEXT"
              && isJust (lastOf "vkDestroyInstance")
              && lastOf "vkDestroyInstance" == Just (length names - 1)
          )
      ]
        <> [ "the session created a swapchain although it has no window" | isJust (firstOf "vkCreateSwapchainKHR") ]
    verdictProblems = case factsVerdict facts of
      Nothing → ["the session gave no diagnostic verdict"]
      Just verdict
        | null (verdictIssues verdict) → []
        | otherwise → ["the diagnostic verdict, computed after the last teardown callback, is not clean: " <> Text.pack (show (verdictIssues verdict))]

-- | The run's evidence: exact revision and source identity, the command, the platform and driver, the
-- validation outcome and what the examples measured.
evidenceRecord ∷ Consent → FilePath → TextureGraphicsConfiguration → Facts → [Text] → Double → IO Text
evidenceRecord consent loader configuration facts problems seconds = do
  revision ← lookupEnv "HETOIMASIA_VULKAN_REVISION"
  digest ← lookupEnv "HETOIMASIA_VULKAN_SOURCE_DIGEST"
  driver ← lookupEnv "VK_DRIVER_FILES"
  features ← lookupEnv "HETOIMASIA_VULKAN_VALIDATION_FEATURES"
  program ← getProgName
  arguments ← getArgs
  let accounting = configurationAccounting configuration
      field name value = "- " <> name <> ": " <> value
      native = length [() | (name, _) ← factsCalls facts, "vk" `Text.isPrefixOf` name]
  pure . Text.unlines $
    [ "# The graphics adapter on a real device"
    , ""
    , field "revision" (maybe "unknown" Text.pack revision)
    , field "source digest" (maybe "unknown" Text.pack digest)
    , field "command" (Text.pack (unwords (program : arguments)) <> " (through tools/vulkan/run.sh native)")
    , field "platform" (Text.pack (os <> "/" <> arch <> ", " <> compilerName <> " " <> show compilerVersion))
    , field "driver manifest" (maybe "unset" Text.pack driver)
    , field "loader" (Text.pack loader)
    , field "consent" (describeConsent consent)
    , field "windows" "0 (the session is started without a surface and no window is requested)"
    , field "validation" ("synchronization validation, pinned features " <> maybe "unset" Text.pack features)
    , field "diagnostic verdict" (maybe "none" (\verdict → if null (verdictIssues verdict) then "clean, " <> Text.pack (show (verdictDelivered verdict)) <> " records delivered" else Text.pack (show (verdictIssues verdict))) (factsVerdict facts))
    , field "native calls" (Text.pack (show native))
    , field "destruction" (Text.intercalate ", " [name | (name, _) ← factsCalls facts, "vkDestroy" `Text.isPrefixOf` name])
    , field "configuration" ("staging " <> bytes (accountingStagingBytes accounting) <> ", table capacity " <> Text.pack (show (accountingTableCapacity accounting)) <> ", versions " <> Text.pack (show (accountingTableVersions accounting)) <> ", native bytes budgeted " <> bytes (accountingNativeBytes accounting) <> " of " <> bytes (accountingNativeLimit accounting))
    , field "seconds" (Text.pack (show seconds))
    , field "result" (if null problems then "every check passed" else "failed: " <> Text.intercalate "; " problems)
    , ""
    , "## What the examples measured"
    , ""
    ]
      <> map ("- " <>) (factsEvidence facts)
  where
    bytes value = Text.pack (show value) <> " bytes"
    _ = isPrefixOf "" ""
