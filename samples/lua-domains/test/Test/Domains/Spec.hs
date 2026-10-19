-- | The sample's examples, composed. Every example that starts an owner runs real interpreters
-- under a real supervision boundary; the structural and pure ones need no VM.
module Test.Domains.Spec (spec) where

import qualified Test.Domains.Exposure
import qualified Test.Domains.Intentions
import qualified Test.Domains.Lifetime
import qualified Test.Domains.Queue
import qualified Test.Domains.Staging
import qualified Test.Domains.World
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "the two-domain Lua sample" $ do
  Test.Domains.World.spec
  Test.Domains.Queue.spec
  Test.Domains.Lifetime.spec
  Test.Domains.Exposure.spec
  Test.Domains.Staging.spec
  Test.Domains.Intentions.spec
