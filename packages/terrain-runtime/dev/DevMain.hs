module Main (main) where

import qualified Test.TerrainRuntime.Storage.Classes as StorageClasses
import qualified Test.TerrainRuntime.Storage.Growth as StorageGrowth
import qualified Test.TerrainRuntime.Storage.Io as StorageIo
import qualified Test.TerrainRuntime.Storage.Lifetime as StorageLifetime
import qualified Test.TerrainRuntime.Storage.Memory as StorageMemory
import qualified Test.TerrainRuntime.Storage.Open as StorageOpen
import Test.Hspec (hspec)

main ∷ IO ()
main = hspec (StorageOpen.spec >> StorageIo.spec >> StorageLifetime.spec >> StorageGrowth.spec >> StorageMemory.spec >> StorageMemory.spec2 >> StorageClasses.spec)
