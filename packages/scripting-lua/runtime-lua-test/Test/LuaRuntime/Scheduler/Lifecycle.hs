-- | Lua cannot reach any of this yet: a lifecycle-operation binding still
-- answers not-yet-supported through the finite-call adapter, which this slice
-- leaves exactly as delivered.
module Test.LuaRuntime.Scheduler.Lifecycle (spec) where

import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Runtime
import Test.Hspec (Spec, describe, it, shouldSatisfy)
import Test.LuaRuntime.Support

spec ∷ Spec
spec = describe "lifecycle-operation bindings" $
  it "still answer not-yet-supported, since no control is reachable from Lua" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      owner ← startOwner runtime (quickSpec fixture "lifecycle" ["app"])
      lifecycle ← submit (ownerEndpoint owner) "lifecycle" [] >>= accepted
      settleOutcome lifecycle >>= \case
        CallFaulted (BoundaryFailed fault) → boundaryReason fault `shouldSatisfy` \case NotYetSupported _ → True; _ → False
        other → fail ("expected a not-yet-supported fault, found " <> show other)
      retireOwner owner
