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
-- @--headless@ selects only that decision's own examples. They are pure, open
-- no window, initialize no GLFW, and read no consent, so the branch is taken
-- here before consent and before any native procedure would run:
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
  , hspecWithResult
  , isSuccess
  )

import Test.Vulkan.Proof.Consent (consentVariable, readConsent, refusalMessage)
import Test.Vulkan.Proof.Journal (entries, newJournal)
import Test.Vulkan.Proof.Record (renderRecord)
import qualified Test.Vulkan.Proof.RetentionSpec as Retention
import Test.Vulkan.Proof.Run (runProof)
import qualified Test.Vulkan.Proof.Spec as Proof

-- | The flag that selects the headless examples and nothing else. It is this
-- harness's own, so it is taken out of the arguments before Hspec's runner
-- sees them rather than left for it to reject.
headlessFlag ∷ String
headlessFlag = "--headless"

-- | Where the record is written, when the caller asks for one. The Linux job
-- uploads this file; the macOS invocation keeps it beside the PR's evidence.
recordVariable ∷ String
recordVariable = "HETOIMASIA_VULKAN_PROOF_RECORD"

main ∷ IO ()
main = do
  arguments ← getArgs
  if headlessFlag `elem` arguments
    then headless (filter (/= headlessFlag) arguments)
    else native arguments

-- | The release decision's own examples, and nothing else: no consent is read,
-- no native procedure runs, and no record is written, because none of those is
-- what this mode establishes. An empty selection fails rather than passing
-- silently, so this cannot become a run that proved nothing and said so
-- quietly.
headless ∷ [String] → IO ()
headless arguments = do
  putStrLn "vulkan-proof: headless; the release decision only, with no native session"
  passed ← runExamples arguments Retention.spec
  unless passed exitFailure

native ∷ [String] → IO ()
native arguments = do
  consent ←
    readConsent >>= \case
      Left refusal → do
        hPutStrLn stderr ("vulkan-proof: " <> Text.unpack (refusalMessage refusal))
        exitFailure
      Right granted → pure granted

  journal ← newJournal
  outcome ← runProof journal consent
  transcript ← entries journal

  passed ← runExamples arguments (Proof.spec outcome)

  invocation ← describeInvocation
  let record = renderRecord "The VK-2 native Vulkan compatibility record" invocation transcript outcome passed
  destination ← lookupEnv recordVariable
  case destination of
    Nothing → Text.putStrLn record
    Just path → do
      Text.writeFile path record
      putStrLn ("vulkan-proof: wrote the compatibility record to " <> path)

  unless passed exitFailure

runExamples ∷ [String] → Spec → IO Bool
runExamples arguments examples =
  isSuccess <$> withArgs arguments (hspecWithResult defaultConfig {configFailOnEmpty = True} examples)

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
