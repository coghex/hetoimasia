-- | The VK-2 proof harness.
--
-- The order is the contract. Consent is read before anything native happens;
-- the whole native run then happens on the process main thread and tears down
-- as much of its session as its own evidence permits, including the instance;
-- only then does Hspec decide whether what was observed is a pass; and the
-- record is written last, carrying that verdict.
--
-- Teardown is not promised complete. A run that stopped with a presentation
-- outstanding, or whose device-idle boundary failed, retains the handles that
-- presentation outlives rather than destroying them, and the record names each
-- one and why. See "Test.Vulkan.Proof.Retention", and the README beside this
-- file.
--
-- @--headless@ selects only that decision's own examples, the composite
-- constructions' ownership examples, and the present handoff's cancellation
-- examples. They open no window, initialize no GLFW, make no native call, and
-- read no consent, so the branch is taken here before consent and before any
-- native procedure would run:
--
-- > bash tools/vulkan-proof/run-proof.sh --headless
--
-- Nothing here is a production component. It is the qualification harness for
-- issue #158, and VK-5 through VK-7 attach their focused native cases to it
-- until VK-8 migrates them into the package-native fixture.
module Main (main) where

import Control.Monad (unless)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Environment (getArgs, getProgName, lookupEnv, withArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Test.Hspec (Spec)
import Test.Hspec.Runner
  ( Config (configFailOnEmpty)
  , defaultConfig
  , evalSpec
  , hspecWithResult
  , isSuccess
  , runSpecForest
  , specResultSuccess
  )

import Test.Vulkan.Proof.Consent (consentVariable, readConsent, refusalMessage)
import qualified Test.Vulkan.Proof.ConstructionSpec as Construction
import Test.Vulkan.Proof.Invocation (Mode (..), selectMode)
import qualified Test.Vulkan.Proof.InvocationSpec as Invocation
import qualified Test.Vulkan.Proof.LoaderSpec as Loader
import Test.Vulkan.Proof.Journal (entries, newJournal)
import qualified Test.Vulkan.Proof.PublicationSpec as Publication
import Test.Vulkan.Proof.Diagnostics (runDiagnostics)
import qualified Test.Vulkan.Proof.DiagnosticsSpec as Diagnostics
import Test.Vulkan.Proof.Record (diagnosticsSection, renderRecordWith)
import qualified Test.Vulkan.Proof.RetentionSpec as Retention
import Test.Vulkan.Proof.Run (runProof)
import qualified Test.Vulkan.Proof.Spec as Proof

-- | Where the record is written, when the caller asks for one. The Linux job
-- uploads this file; the macOS invocation keeps it beside the PR's evidence.
recordVariable ∷ String
recordVariable = "HETOIMASIA_VULKAN_PROOF_RECORD"

main ∷ IO ()
main = do
  arguments ← getArgs
  case selectMode arguments of
    Refused reason → do
      hPutStrLn stderr ("vulkan-proof: " <> Text.unpack reason)
      exitFailure
    Headless selectors → headless selectors
    Native → native

-- | The pure examples, and nothing else: no consent is read, no native
-- procedure runs, and no record is written, because none of those is what this
-- mode establishes. Selecting among them is fine precisely because nothing
-- here writes a verdict anywhere; an empty selection still fails rather than
-- passing silently.
headless ∷ [String] → IO ()
headless selectors = do
  putStrLn "vulkan-proof: headless; the release decision only, with no native session"
  result ←
    withArgs selectors $
      hspecWithResult defaultConfig {configFailOnEmpty = True} headlessExamples
  unless (isSuccess result) exitFailure

-- | Everything @--headless@ selects: the release decision's own examples, the
-- composite constructions' ownership examples, the present handoff's
-- cancellation examples, the invocation policy's, and the loader selection's.
-- The native run asserts what it can of these too, through
-- "Test.Vulkan.Proof.Spec".
headlessExamples ∷ Spec
headlessExamples = do
  Retention.spec
  Construction.spec
  Publication.spec
  Invocation.spec
  Loader.spec

native ∷ IO ()
native = do
  consent ←
    readConsent >>= \case
      Left refusal → do
        hPutStrLn stderr ("vulkan-proof: " <> Text.unpack (refusalMessage refusal))
        exitFailure
      Right granted → pure granted

  journal ← newJournal
  outcome ← runProof journal consent
  -- VK-6's cases run on their own instance once the VK-2 session has torn
  -- down, in the environment it established. Their capture lifetime has ended,
  -- and with it their last callback, before any verdict is computed.
  diagnostics ← runDiagnostics journal
  transcript ← entries journal

  passed ← runCompleteSpec (Proof.spec outcome >> Diagnostics.spec diagnostics)

  invocation ← describeInvocation
  let record =
        renderRecordWith
          "The VK-2 native Vulkan compatibility record"
          invocation
          transcript
          outcome
          (diagnosticsSection diagnostics)
          passed
  destination ← lookupEnv recordVariable
  case destination of
    Nothing → Text.putStrLn record
    Just path → do
      Text.writeFile path record
      putStrLn ("vulkan-proof: wrote the compatibility record to " <> path)

  unless passed exitFailure

-- | Run the whole spec, and only ever the whole spec.
--
-- Deliberately not `hspecWithResult`. That resolves its configuration through
-- Hspec's @readConfig@, which reads the command line, @~/.hspec@, @./.hspec@,
-- and @HSPEC_*@ in the environment — any of which can select a subset. The
-- result returned here is written into the compatibility record as that
-- record's own verdict on the whole contract, so a subset must not be able to
-- produce it: an ambient @HSPEC_MATCH@ that happened to select only the pure
-- examples would otherwise turn a native run that stopped into a record
-- saying @Verdict: pass@.
--
-- These are Hspec's own documented primitives with the configuration-reading
-- step left out, so the configuration is exactly the one written here.
runCompleteSpec ∷ Spec → IO Bool
runCompleteSpec examples = do
  (config, forest) ← evalSpec defaultConfig {configFailOnEmpty = True} examples
  specResultSuccess <$> runSpecForest forest config

-- | The command a reader would have to run to reproduce this, including the
-- environment that decides which loader, driver, and layers it used. A record
-- that does not say how it was produced is not reproducible.
describeInvocation ∷ IO Text
describeInvocation = do
  program ← getProgName
  arguments ← getArgs
  environment ←
    traverse
      (\name → fmap ((,) name) <$> lookupEnv name)
      -- Only what decided which loader, driver, and layers the run used. Where
      -- the record was written is not that, and naming it would put the
      -- author's own directory layout into a committed record.
      [consentVariable, "VK_DRIVER_FILES", "VK_LAYER_PATH", "DISPLAY"]
  pure
    ( Text.intercalate
        " \\\n  "
        ( [Text.pack (name <> "=" <> value) | Just (name, value) ← environment]
            <> [Text.unwords (map Text.pack (program : arguments))]
        )
    )
