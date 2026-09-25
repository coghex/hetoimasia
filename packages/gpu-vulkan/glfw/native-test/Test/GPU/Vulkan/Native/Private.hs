-- | Native cases that need roots of their own, each in a child process of this
-- executable.
--
-- The shared fixture holds one GLFW session, one instance and one device for
-- the whole run, so nothing that has to create, fail, or destroy those can run
-- beside it: GLFW allows one session per process, and a case whose point is
-- the destruction order of the roots, or a deliberate validation error, would
-- destroy or poison what every other example shares. Each such case therefore
-- runs in a child started with @--private-roots <scenario>@, on the child's own
-- process main thread, with private roots from start to teardown:
--
-- * @vk2-compatibility@ — VK-2's compatibility, completion, abandonment and
--   capture proof (#158), with its pure release decisions;
-- * @vk6-capture@ — VK-6's C-only validation capture (#217);
-- * @vk5-bridge@ — VK-5's loader-aware surface bridge (#216);
-- * @vk7-roots@ — VK-7's roots under the graphics owner, over two windows,
--   including the destruction order at the host's exit (#219);
-- * @vk11-recording@ — VK-11's managed resources and a recorded, discarded
--   triangle batch against a swapchain generation's image (#223);
-- * @synchronization-hazard@ — the negative control that proves
--   synchronization validation active ("Test.GPU.Vulkan.Native.Hazard");
-- * @debug-names@ — #250's provoked validation report on a named managed
--   resource inside a labelled batch ("Test.GPU.Vulkan.Native.Naming").
--
-- The child asserts its migrated examples exactly as the proof did: the whole
-- spec and only the whole spec, through Hspec's own primitives with the
-- configuration-reading step left out, so an ambient @HSPEC_*@ or a @.hspec@
-- file cannot narrow what its verdict speaks for. The parent example passes
-- only when the child ran every one of them and every one passed. Its output,
-- and the record the child writes, go to the evidence directory the validation
-- runner names, so a failed or expired run keeps them.
--
-- The parent starts no child without the run's consent, and the child, which
-- inherits it, refuses on stderr with exit status 3 when started directly
-- without it, before it looks its scenario up; an unknown scenario under
-- consent exits 2.
module Test.GPU.Vulkan.Native.Private
  ( privateRootsFlag
  , scenarioNames
  , runScenario
  , spec
  , ChildRun (..)
  ) where

import Control.Monad (unless)
import Data.IORef (IORef, modifyIORef')
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Environment (getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it)
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, evalSpec, runSpecForest, specResultSuccess)

import Test.GPU.Vulkan.Native.Consent (Consent, Refusal, refusalMessage)
import Test.GPU.Vulkan.Native.Environment (checkValidationFeatures)
import Test.GPU.Vulkan.Native.Gate (Gate, admit)
import qualified Test.GPU.Vulkan.Native.Hazard as Hazard
import qualified Test.GPU.Vulkan.Native.Naming as Naming
import qualified Test.GPU.Vulkan.Native.Recording as Recording
import qualified Test.Vulkan.Proof.Bridge as Bridge
import qualified Test.Vulkan.Proof.BridgeSpec as BridgeSpec
import qualified Test.Vulkan.Proof.Diagnostics as Diagnostics
import qualified Test.Vulkan.Proof.DiagnosticsSpec as DiagnosticsSpec
import Test.Vulkan.Proof.Journal (Journal, entries, newJournal)
import Test.Vulkan.Proof.Record (bridgeSection, diagnosticsSection, renderRecord, rootsSection)
import qualified Test.Vulkan.Proof.Roots as Roots
import qualified Test.Vulkan.Proof.RootsSpec as RootsSpec
import Test.Vulkan.Proof.Run (runProof)
import qualified Test.Vulkan.Proof.Spec as Proof

-- | The flag that turns this executable into one scenario's child.
privateRootsFlag ∷ String
privateRootsFlag = "--private-roots"

-- | What one child's run cost, for the report the parent prints at the end.
data ChildRun = ChildRun
  { childScenario ∷ !String
  , childSeconds ∷ !Double
  , childStatus ∷ !ExitCode
  }
  deriving (Show)

-- | One scenario: what its example is called, and how the child runs it.
data Scenario = Scenario
  { scenarioName ∷ String
  , scenarioTitle ∷ String
  , scenarioRun ∷ Consent → Journal → IO (Spec, Bool → [Text] → Text)
    -- ^ The native procedure, run to completion and torn down before it
    -- returns; then the examples that assert over what it saw, and the record
    -- that states their verdict.
  }

scenarios ∷ [Scenario]
scenarios =
  [ Scenario
      "vk2-compatibility"
      "proves the VK-2 compatibility profile, presentation completion, safe abandonment and capture"
      $ \consent journal → do
        outcome ← runProof journal consent
        pure (Proof.spec outcome, \passed transcript → renderRecord "The VK-2 native Vulkan compatibility record" invocation transcript outcome passed)
  , Scenario "vk6-capture" "proves VK-6's C-only validation capture on an instance of its own" $ \_ journal → do
      outcome ← Diagnostics.runDiagnostics journal
      pure (DiagnosticsSpec.spec outcome, section "The VK-6 validation capture record" (diagnosticsSection outcome))
  , Scenario "vk5-bridge" "proves VK-5's loader-aware surface bridge in a session of its own" $ \_ journal → do
      outcome ← Bridge.runBridge journal
      pure (BridgeSpec.spec outcome, section "The VK-5 surface bridge record" (bridgeSection outcome))
  , Scenario "vk7-roots" "proves VK-7's roots under the graphics owner, through their destruction at the host's exit" $ \_ journal → do
      outcome ← Roots.runRoots journal
      pure (RootsSpec.spec outcome, section "The VK-7 Vulkan roots record" (rootsSection outcome))
  , Scenario
      "vk11-recording"
      "records and discards a triangle batch through VK-11's managed resources, with validation reporting nothing"
      $ \_ journal → do
        outcome ← Recording.runRecording journal
        pure (Recording.spec outcome, section "The VK-11 managed recording record" (Recording.recordingSection outcome))
  , Scenario
      "synchronization-hazard"
      "observes a deliberate synchronization hazard, proving synchronization validation active"
      $ \_ journal → do
        outcome ← Hazard.runHazard journal
        pure (Hazard.spec outcome, section "The synchronization validation control record" (Hazard.hazardSection outcome))
  , Scenario
      "debug-names"
      "carries a provoked validation report's named managed resource, and its batch's label, into the capture"
      $ \_ journal → do
        outcome ← Naming.runNaming journal
        pure (Naming.spec outcome, section "The #250 debug names and labels record" (Naming.namingSection outcome))
  ]
  where
    invocation = "tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete"
    section title body passed transcript =
      Text.unlines $
        ["# " <> title, "", "Verdict: **" <> (if passed then "pass" else "fail") <> "**."]
          <> body
          <> ["", "## Transcript", "", "```"]
          <> transcript
          <> ["```"]

scenarioNames ∷ [String]
scenarioNames = map scenarioName scenarios

-- | The exit status of a child started without consent.
refusedExit ∷ ExitCode
refusedExit = ExitFailure 3

-- | The exit status of a consented child asked for no known scenario.
unknownScenarioExit ∷ ExitCode
unknownScenarioExit = ExitFailure 2

-- | Run one scenario as this process's whole work, on its main thread.
runScenario ∷ Either Refusal Consent → String → IO ()
runScenario refusedOrGranted name = case refusedOrGranted of
  Left refusal → do
    hPutStrLn stderr ("vulkan-native-tests " <> name <> ": " <> Text.unpack (refusalMessage refusal))
    exitWith refusedExit
  Right consent → case [scenario | scenario ← scenarios, scenarioName scenario == name] of
    [] → do
      hPutStrLn stderr ("vulkan-native-tests: unknown private roots scenario " <> show name)
      exitWith unknownScenarioExit
    scenario : _ → do
      -- The validation features every instance enables are compiled in; the
      -- run is refused if they are not the set the provisioned layer is pinned
      -- to, which is the set the receipt names.
      checkValidationFeatures >>= \case
        Right () → pure ()
        Left reason → do
          hPutStrLn stderr ("vulkan-native-tests " <> name <> ": " <> Text.unpack reason)
          exitWith (ExitFailure 1)
      journal ← newJournal
      (examples, record) ← scenarioRun scenario consent journal
      passed ← runCompleteSpec examples
      transcript ← entries journal
      retain (name <> ".md") (record passed transcript)
      if passed
        then putStrLn ("vulkan-native-tests " <> name <> ": every check passed")
        else do
          putStrLn ("vulkan-native-tests " <> name <> ": a check failed")
          exitWith (ExitFailure 1)

-- | Run the whole spec, and only ever the whole spec, as the proof did.
--
-- Deliberately not `hspecWithResult`, which resolves its configuration from
-- the command line, @~/.hspec@, @./.hspec@ and @HSPEC_*@ — any of which could
-- select a subset whose success would then be reported as the scenario's.
runCompleteSpec ∷ Spec → IO Bool
runCompleteSpec examples = do
  (config, forest) ← evalSpec defaultConfig {configFailOnEmpty = True} examples
  specResultSuccess <$> runSpecForest forest config

-- | Write a file into the evidence directory the validation runner names, when
-- there is one. Evidence is kept, never required: a run outside the runner
-- still prints everything it asserts.
retain ∷ String → Text → IO ()
retain file contents =
  lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE" >>= \case
    Nothing → pure ()
    Just "" → pure ()
    Just directory → Text.writeFile (directory </> file) contents

-- | One example per scenario, each starting its child only under consent.
spec ∷ Gate → IORef [ChildRun] → Spec
spec gate timings = describe "with private roots in a child process" $
  mapM_ example scenarios
  where
    example scenario = it (scenarioTitle scenario) $ do
      _ ← admit gate
      executable ← getExecutablePath
      started ← getCurrentTime
      (status, out, err) ← readProcessWithExitCode executable [privateRootsFlag, scenarioName scenario] ""
      finished ← getCurrentTime
      let seconds = realToFrac (diffUTCTime finished started)
      modifyIORef' timings (ChildRun (scenarioName scenario) seconds status :)
      retain (scenarioName scenario <> ".log") (Text.pack (out <> err))
      let passedLine = "vulkan-native-tests " <> scenarioName scenario <> ": every check passed"
      unless (status == ExitSuccess && passedLine `isInfixOf` out) $
        expectationFailure
          ("the private " <> scenarioName scenario <> " process exited " <> show status <> ":\n" <> out <> err)
