-- | The protocol model's contracts, composed.
--
-- The group is wrapped in 'Test.Lua.Protocol.Fixture.baseline', which runs
-- once before its first example, and ends with the fixture report that reads
-- the counter again. Nothing between the two constructs an interpreter, which
-- is the claim the report makes.
module Test.Lua.Protocol.Spec (spec) where

import Test.Hspec (Spec, beforeAll_, describe)
import qualified Test.Lua.Protocol.Admission
import qualified Test.Lua.Protocol.Boundary
import qualified Test.Lua.Protocol.Determinism
import qualified Test.Lua.Protocol.Epochs
import qualified Test.Lua.Protocol.Failure
import qualified Test.Lua.Protocol.Fixture
import qualified Test.Lua.Protocol.Isolation
import qualified Test.Lua.Protocol.Reason
import qualified Test.Lua.Protocol.Requests
import qualified Test.Lua.Protocol.Stop
import qualified Test.Lua.Protocol.Subscriptions
import qualified Test.Lua.Protocol.Tasks

spec ∷ Spec
spec = describe "Protocol" $ beforeAll_ Test.Lua.Protocol.Fixture.baseline $ do
  Test.Lua.Protocol.Tasks.spec
  Test.Lua.Protocol.Admission.spec
  Test.Lua.Protocol.Requests.spec
  Test.Lua.Protocol.Subscriptions.spec
  Test.Lua.Protocol.Epochs.spec
  Test.Lua.Protocol.Isolation.spec
  Test.Lua.Protocol.Reason.spec
  Test.Lua.Protocol.Failure.spec
  Test.Lua.Protocol.Stop.spec
  Test.Lua.Protocol.Determinism.spec
  Test.Lua.Protocol.Boundary.spec
  Test.Lua.Protocol.Fixture.spec
