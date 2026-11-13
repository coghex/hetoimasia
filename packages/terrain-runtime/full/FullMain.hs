module Main (main) where

import qualified Test.TerrainRuntime.Store.Rebalance as StoreRebalance
import qualified Test.TerrainRuntime.Store.Scattered as StoreScattered
import qualified Test.TerrainRuntime.Store.Large as StoreLarge
import qualified Test.TerrainRuntime.Store.Protocol as StoreProtocol
import qualified Test.TerrainRuntime.Store.History as StoreHistory
import qualified Test.TerrainRuntime.Store.Trees as StoreTrees
import qualified Test.TerrainRuntime.Store.Evidence as StoreEvidence
import qualified Test.TerrainRuntime.Store.Fuzz as StoreFuzz
import qualified Test.TerrainRuntime.Store.FuzzTrees as StoreFuzzTrees
import qualified Test.TerrainRuntime.Store.Cycles as StoreCycles
import Test.Hspec (Spec, before_, hspec)
import Test.TerrainRuntime.Isolation (sequentialGuard)

-- | Every reduced or moved family of the routine suite at its complete original parameters: the optional
-- full-depth probe. The routine run plus this run executes everything the unreduced suite did. Everything here runs one
-- example at a time on one capability, and the isolation guard of the routine suite runs before each example.
main ∷ IO ()
main = hspec (before_ sequentialGuard fullDepth)

fullDepth ∷ Spec
fullDepth = do
  StoreRebalance.fullSpec
  StoreScattered.fullSpec
  StoreLarge.fullSpec
  StoreProtocol.fullSpec
  StoreHistory.fullSpec
  StoreTrees.fullSpec
  StoreEvidence.fullSpec
  StoreFuzz.fullSpec
  StoreFuzzTrees.fullSpec
  StoreCycles.fullSpec
