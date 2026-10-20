-- | The sample's examples, composed. Every example that starts an owner runs real interpreters
-- under a real supervision boundary; the structural and pure ones need no VM.
module Test.Domains.Spec (spec) where

import qualified Test.Domains.Admission
import qualified Test.Domains.Barrier
import qualified Test.Domains.Command
import qualified Test.Domains.Conservation
import qualified Test.Domains.Dependencies
import qualified Test.Domains.Controls
import qualified Test.Domains.Exposure
import qualified Test.Domains.Failure
import qualified Test.Domains.Intentions
import qualified Test.Domains.Ledger
import qualified Test.Domains.Leases
import qualified Test.Domains.Lifetime
import qualified Test.Domains.Process
import qualified Test.Domains.Progress
import qualified Test.Domains.Queue
import qualified Test.Domains.Random
import qualified Test.Domains.Staging
import qualified Test.Domains.Stop
import qualified Test.Domains.UiFailure
import qualified Test.Domains.View
import qualified Test.Domains.World
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "the two-domain Lua sample" $ do
  Test.Domains.Dependencies.spec
  Test.Domains.World.spec
  Test.Domains.Queue.spec
  Test.Domains.Lifetime.spec
  Test.Domains.Exposure.spec
  Test.Domains.Staging.spec
  Test.Domains.Intentions.spec
  Test.Domains.Controls.spec
  Test.Domains.Failure.spec
  Test.Domains.Ledger.spec
  Test.Domains.Leases.spec
  Test.Domains.Stop.spec
  Test.Domains.UiFailure.spec
  Test.Domains.View.spec
  Test.Domains.Barrier.spec
  Test.Domains.Progress.spec
  Test.Domains.Admission.spec
  Test.Domains.Conservation.spec
  Test.Domains.Random.spec
  Test.Domains.Command.spec
  Test.Domains.Process.spec
