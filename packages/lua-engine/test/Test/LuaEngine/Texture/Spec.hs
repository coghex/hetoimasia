-- | The texture pipeline's examples (LFE-16), composed under one @Texture@ group.
module Test.LuaEngine.Texture.Spec (spec) where

import qualified Test.LuaEngine.Texture.Cancellation as Cancellation
import qualified Test.LuaEngine.Texture.Client as Client
import qualified Test.LuaEngine.Texture.Contract as Contract
import qualified Test.LuaEngine.Texture.Failures as Failures
import qualified Test.LuaEngine.Texture.Lifecycle as Lifecycle
import qualified Test.LuaEngine.Texture.Limits as Limits
import qualified Test.LuaEngine.Texture.Ownership as Ownership
import qualified Test.LuaEngine.Texture.Stages as Stages
import qualified Test.LuaEngine.Texture.Workers as Workers
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Texture" $ do
  Contract.spec
  Limits.spec
  Stages.spec
  Workers.spec
  Cancellation.spec
  Failures.spec
  Ownership.spec
  Lifecycle.spec
  Client.spec
