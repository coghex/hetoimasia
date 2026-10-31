-- | LFE-23: the M1 integrated ownership and failure qualification, composed under one @Integrated@ group.
--
-- The groups are CPU-only: they use the production composition's real services over injected clocks, timers and
-- sinks, and acquire no graphics dependency. The graphics-linked cases (textures, windows, scene retention) are in
-- @lua-engine-graphics-tests@, and the application-composition cases are in the root @hetoimasia-tests@.
module Test.LuaEngine.Integrated.Spec (spec) where

import qualified Test.LuaEngine.Integrated.Capacity as Capacity
import qualified Test.LuaEngine.Integrated.Instances as Instances
import qualified Test.LuaEngine.Integrated.Jobs as Jobs
import qualified Test.LuaEngine.Integrated.Roles as Roles
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Integrated" $ do
  Instances.spec
  Jobs.spec
  Roles.spec
  Capacity.spec
