-- | The Lua bridge's and protocol model's contracts, composed.
module Test.Lua.Spec (spec) where

import Test.Hspec (Spec, describe)
import qualified Test.Lua.Close
import qualified Test.Lua.Discipline
import qualified Test.Lua.Faults
import qualified Test.Lua.Hazard
import qualified Test.Lua.Independence
import qualified Test.Lua.Libraries
import qualified Test.Lua.Opacity
import qualified Test.Lua.Protocol.Spec

spec ∷ Spec
spec = describe "Lua" $ do
  Test.Lua.Faults.spec
  Test.Lua.Discipline.spec
  Test.Lua.Close.spec
  Test.Lua.Independence.spec
  Test.Lua.Libraries.spec
  Test.Lua.Hazard.spec
  Test.Lua.Opacity.spec
  Test.Lua.Protocol.Spec.spec
