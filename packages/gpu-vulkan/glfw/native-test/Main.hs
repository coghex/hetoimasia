{-# LANGUAGE OverloadedRecordDot #-}

-- | The Vulkan native suite: the package-native fixture for the window
-- integration's native cases, and the migrated VK-2 and VK-5–VK-7 cases.
--
-- The order is the contract. The Vulkan environment is established before any
-- Vulkan call, and consent is read once, before anything native; the process
-- main thread then owns the shared graphics session and serves Hspec, which
-- runs on a thread of its own; the session is released only once Hspec has
-- finished; and only then are the checks that need the roots gone applied —
-- their destruction order on the graphics owner's thread and the capture's
-- final verdict, which fails on any validation error or incomplete capture.
--
-- @--private-roots <scenario>@ runs one case that needs roots of its own as
-- this whole process instead ("Test.GPU.Vulkan.Native.Private").
--
-- Run it through the catalog group @test.vulkan-native@, or the command that
-- group runs:
--
-- > bash tools/vulkan/run.sh build hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests
-- > bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests
--
-- which on Linux starts an isolated X11 display for it, and on macOS needs
-- the human's @HETOIMASIA_NATIVE_SESSION=desktop@ on that one command. See
-- docs/gpu_backend.md.
module Main (main) where

import Control.Monad (forM_, unless)
import Data.IORef (newIORef, readIORef)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, stderr, stdout)
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWithResult, isSuccess)

import Hetoimasia.Foundation.Log (LogEntry (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (DiagnosticVerdict (..), verdictIssues)
import Test.GPU.Vulkan.Native.Consent (Consent, Refusal, readConsent, refusalMessage)
import Test.GPU.Vulkan.Native.Environment (establishEnvironment)
import Test.GPU.Vulkan.Native.Fixture (SharedReport (..), ThreadCheck (..), runShared)
import Test.GPU.Vulkan.Native.Gate (newGate, refusals)
import Test.GPU.Vulkan.Native.Private (ChildRun (..), privateRootsFlag, runScenario)
import qualified Test.GPU.Vulkan.Native.Spec as Native
import Test.Vulkan.Proof.Roots (NativeCall (..))

main ∷ IO ()
main = do
  hSetBuffering stdout LineBuffering
  started ← getCurrentTime
  environment ← establishEnvironment
  consent ← readConsent
  getArgs >>= \case
    [flag, scenario] | flag == privateRootsFlag → runScenario consent scenario
    _ → do
      forM_ environment (Text.putStrLn . ("vulkan-native-tests: " <>))
      runSuite consent started

runSuite ∷ Either Refusal Consent → UTCTime → IO ()
runSuite consent started = do
  gate ← newGate consent
  timings ← newIORef []
  (result, report) ←
    runShared gate $ \fixture →
      hspecWithResult defaultConfig {configFailOnEmpty = True} (Native.spec gate fixture timings)
  children ← readIORef timings
  refused ← refusals gate
  finished ← getCurrentTime
  mapM_ (Text.putStrLn . ("vulkan-native-tests: " <>)) (summary report children)
  putStrLn
    ( "vulkan-native-tests: the process ran for "
        <> show (realToFrac (diffUTCTime finished started) ∷ Double)
        <> "s, fixtures, examples and teardown included"
    )
  let problems = sharedProblems report <> refusalProblems consent refused
  forM_ problems (hPutStrLn stderr . ("vulkan-native-tests: " <>) . Text.unpack)
  unless (isSuccess result && null problems) exitFailure

-- | What the run's shared session did, and what each child cost.
summary ∷ SharedReport → [ChildRun] → [Text]
summary report children =
  [ "shared session acquisitions: " <> tshow report.reportAcquisitions
  , "shared session native calls: " <> tshow (length report.reportCalls)
  , "shared session destruction: " <> Text.intercalate ", " (destructions report)
  , "shared session verdict: " <> maybe "none (nothing was acquired)" describeVerdict report.reportVerdict
  ]
    <> [ "private " <> Text.pack child.childScenario <> ": " <> tshow child.childStatus <> " in " <> tshow child.childSeconds <> "s"
       | child ← sortOn (.childScenario) children
       ]
  where
    describeVerdict verdict =
      (if null (verdictIssues verdict) then "clean" else "issues " <> tshow (verdictIssues verdict))
        <> ", "
        <> tshow verdict.verdictDelivered
        <> " records delivered"

destructions ∷ SharedReport → [Text]
destructions report = [call.callName | call ← report.reportCalls, Text.isPrefixOf "vkDestroy" call.callName]

-- | The checks the shared session is held to once it has been released.
sharedProblems ∷ SharedReport → [Text]
sharedProblems report
  | report.reportAcquisitions == 0 = []
  | otherwise =
      concat
        [ ["the shared session was acquired " <> tshow report.reportAcquisitions <> " times, not once" | report.reportAcquisitions > 1]
        , ["the shared session ended with a failure: " <> failure | Just failure ← [report.reportFailure]]
        , [ "a dispatched operation's thread check failed: " <> check.checkedOn
          | check ← report.reportChecks
          , not check.checkedPassed
          ]
        , ["a native call raised: " <> call.callName <> ": " <> reason | call ← report.reportCalls, Just reason ← [call.callRaised]]
        , ownerProblems
        , orderProblems
        , verdictProblems
        ]
  where
    calls = report.reportCalls
    owner = [call.callHaskellThread | call ← calls, call.callName == "vkCreateInstance"]
    ownerProblems =
      [ call.callName <> " ran off the graphics owner's thread"
      | call ← calls
      , Text.isPrefixOf "vk" call.callName
      , call.callHaskellThread `notElem` owner || call.callHaskellThread == report.reportMainThread || call.callOsThread == report.reportMainOs
      ]
        <> [ "glfwCreateWindowSurface ran off the process main thread"
           | call ← calls
           , call.callName == "glfwCreateWindowSurface"
           , call.callOsThread /= report.reportMainOs
           ]
    -- Child before parent: every surface before the device, the device before
    -- the explicit messenger, and the messenger before the instance, which is
    -- the last native call of all.
    orderProblems =
      let named = map (.callName) calls
          positions name = [index | (index, called) ← zip [0 ∷ Int ..] named, called == name]
          lastOf name = if null (positions name) then Nothing else Just (maximum (positions name))
          firstOf name = if null (positions name) then Nothing else Just (minimum (positions name))
          before earlier later = case (earlier, later) of
            (Just a, Just b) → a < b
            _ → True
       in [ "the shared roots were not destroyed surface, device, messenger, instance: " <> Text.intercalate ", " (destructions report)
          | not
              ( lastOf "vkDestroySurfaceKHR" `before` firstOf "vkDestroyDevice"
                  && lastOf "vkDestroyDevice" `before` firstOf "vkDestroyDebugUtilsMessengerEXT"
                  && isJust (lastOf "vkDestroyInstance")
                  && lastOf "vkDestroyInstance" == Just (length named - 1)
                  && lastOf "vkDestroyDebugUtilsMessengerEXT" `before` lastOf "vkDestroyInstance"
              )
          ]
    verdictProblems = case report.reportVerdict of
      Nothing → ["the shared session gave no diagnostic verdict"]
      Just verdict
        | null (verdictIssues verdict) → []
        | otherwise →
            ("the shared session's diagnostic verdict, computed after its last teardown callback, is not clean: " <> tshow (verdictIssues verdict))
              : [ "  " <> Map.findWithDefault "" "message.id" entry.entryFields <> ": " <> entry.entryMessage
                | entry ← report.reportEntries
                , Map.lookup "severity" entry.entryFields == Just "error"
                ]

-- | A run without consent that refused a native example is not a pass, even
-- when Hspec counted the refusal as that example's failure: it says why.
refusalProblems ∷ Either Refusal Consent → Int → [Text]
refusalProblems consent refused = case consent of
  Left refusal | refused > 0 → [refusalMessage refusal]
  _ → []

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
