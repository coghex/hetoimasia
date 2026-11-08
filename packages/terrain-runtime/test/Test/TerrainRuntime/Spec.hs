module Test.TerrainRuntime.Spec (spec) where

import qualified Test.TerrainRuntime.Basic as Basic
import qualified Test.TerrainRuntime.Budgets as Budgets
import qualified Test.TerrainRuntime.Closure as Closure
import qualified Test.TerrainRuntime.Races as Races
import Test.Hspec (Spec)

spec ∷ Spec
spec = do
  Basic.spec
  Races.spec
  Budgets.spec
  Closure.spec
