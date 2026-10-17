-- | The protected VM owner's contracts, composed.
module Test.Lua.Owner.Spec (spec) where

import Test.Hspec (Spec, describe)
import qualified Test.Lua.Owner.Cancellation
import qualified Test.Lua.Owner.Construction
import qualified Test.Lua.Owner.Independence
import qualified Test.Lua.Owner.Matrix
import qualified Test.Lua.Owner.Ownership
import qualified Test.Lua.Owner.Scope
import qualified Test.Lua.Owner.Shutdown

spec ∷ Spec
spec = describe "VM owner" $ do
  Test.Lua.Owner.Matrix.spec
  Test.Lua.Owner.Construction.spec
  Test.Lua.Owner.Cancellation.spec
  Test.Lua.Owner.Shutdown.spec
  Test.Lua.Owner.Scope.spec
  Test.Lua.Owner.Ownership.spec
  Test.Lua.Owner.Independence.spec
