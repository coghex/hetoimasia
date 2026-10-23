-- | The scene schema's examples (LFE-19), composed under one @Scene@ group.
module Test.LuaEngine.Scene.Spec (spec) where

import qualified Test.LuaEngine.Scene.Authority as Authority
import qualified Test.LuaEngine.Scene.Client as Client
import qualified Test.LuaEngine.Scene.Failure as Failure
import qualified Test.LuaEngine.Scene.Limits as Limits
import qualified Test.LuaEngine.Scene.Numbers as Numbers
import qualified Test.LuaEngine.Scene.Render as Render
import qualified Test.LuaEngine.Scene.Schema as Schema
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Scene" $ do
  Schema.spec
  Numbers.spec
  Limits.spec
  Authority.spec
  Failure.spec
  Render.spec
  Client.spec
