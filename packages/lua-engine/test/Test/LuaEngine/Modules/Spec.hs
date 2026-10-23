-- | The module coordinator's examples (LFE-11), composed under one @Modules@ group.
module Test.LuaEngine.Modules.Spec (spec) where

import qualified Test.LuaEngine.Modules.Bank as Bank
import qualified Test.LuaEngine.Modules.Basics as Basics
import qualified Test.LuaEngine.Modules.Lifecycle as Lifecycle
import qualified Test.LuaEngine.Modules.Limits as Limits
import qualified Test.LuaEngine.Modules.Order as Order
import qualified Test.LuaEngine.Modules.Positions as Positions
import qualified Test.LuaEngine.Modules.Promotion as Promotion
import qualified Test.LuaEngine.Modules.Stages as Stages
import qualified Test.LuaEngine.Modules.Identities as Identities
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Modules" $ do
  Identities.spec
  Basics.spec
  Order.spec
  Bank.spec
  Limits.spec
  Lifecycle.spec
  Stages.spec
  Promotion.spec
  Positions.spec
