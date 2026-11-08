module Test.TerrainRuntime.Spec (spec) where

import qualified Test.TerrainRuntime.Basic as Basic
import qualified Test.TerrainRuntime.Budgets as Budgets
import qualified Test.TerrainRuntime.Closure as Closure
import qualified Test.TerrainRuntime.Credits as Credits
import qualified Test.TerrainRuntime.Hardening as Hardening
import qualified Test.TerrainRuntime.Interleaving as Interleaving
import qualified Test.TerrainRuntime.Lifecycle as Lifecycle
import qualified Test.TerrainRuntime.Limits as Limits
import qualified Test.TerrainRuntime.Offload as Offload
import qualified Test.TerrainRuntime.Opacity as Opacity
import qualified Test.TerrainRuntime.Races as Races
import qualified Test.TerrainRuntime.Revalidation as Revalidation
import Test.Hspec (Spec)

spec ∷ Spec
spec = do
  Basic.spec
  Races.spec
  Budgets.spec
  Offload.spec
  Revalidation.spec
  Opacity.spec
  Lifecycle.spec
  Hardening.spec
  Credits.spec
  Limits.spec
  Interleaving.spec
  Closure.spec
