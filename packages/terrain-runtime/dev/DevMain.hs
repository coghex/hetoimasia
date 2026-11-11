module Main (main) where

import qualified Test.TerrainRuntime.Storage.Io as StorageIo
import qualified Test.TerrainRuntime.Storage.Open as StorageOpen
import Test.Hspec (hspec)

main ∷ IO ()
main = hspec (StorageOpen.spec >> StorageIo.spec)
