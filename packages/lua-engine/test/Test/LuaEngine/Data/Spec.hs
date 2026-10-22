-- | The raw-data provider's examples (LFE-10), composed under one @Data@ group.
module Test.LuaEngine.Data.Spec (spec) where

import qualified Test.LuaEngine.Data.Contract as Contract
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Data" Contract.spec
