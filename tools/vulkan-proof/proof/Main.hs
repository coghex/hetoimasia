-- | The VK-2 proof harness.
--
-- The order is the contract. Consent is read before anything native happens;
-- the whole native run then happens on the process main thread and tears its
-- session down completely, including the instance; only then does Hspec decide
-- whether what was observed is a pass; and the record is written last, carrying
-- that verdict.
--
-- Nothing here is a production component. It is the qualification harness for
-- issue #158, and VK-5 through VK-7 attach their focused native cases to it
-- until VK-8 migrates them into the package-native fixture.
module Main (main) where

import Control.Monad (unless)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Environment (getArgs, getProgName, lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Test.Hspec.Runner
  ( Config (configFailOnEmpty)
  , defaultConfig
  , hspecWithResult
  , isSuccess
  )

import Test.Vulkan.Proof.Consent (consentVariable, readConsent, refusalMessage)
import Test.Vulkan.Proof.Journal (entries, newJournal)
import Test.Vulkan.Proof.Record (renderRecord)
import Test.Vulkan.Proof.Run (runProof)
import qualified Test.Vulkan.Proof.Spec as Proof

-- | Where the record is written, when the caller asks for one. The Linux job
-- uploads this file; the macOS invocation keeps it beside the PR's evidence.
recordVariable ∷ String
recordVariable = "HETOIMASIA_VULKAN_PROOF_RECORD"

main ∷ IO ()
main = do
  consent ←
    readConsent >>= \case
      Left refusal → do
        hPutStrLn stderr ("vulkan-proof: " <> Text.unpack (refusalMessage refusal))
        exitFailure
      Right granted → pure granted

  journal ← newJournal
  outcome ← runProof journal consent
  transcript ← entries journal

  result ← hspecWithResult defaultConfig {configFailOnEmpty = True} (Proof.spec outcome)
  let passed = isSuccess result

  invocation ← describeInvocation
  let record = renderRecord "The VK-2 native Vulkan compatibility record" invocation transcript outcome passed
  destination ← lookupEnv recordVariable
  case destination of
    Nothing → Text.putStrLn record
    Just path → do
      Text.writeFile path record
      putStrLn ("vulkan-proof: wrote the compatibility record to " <> path)

  unless passed exitFailure

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
