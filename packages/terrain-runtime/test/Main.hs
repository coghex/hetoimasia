module Main (main) where

import qualified Test.TerrainRuntime.Spec as Spec
import Test.Hspec (hspec)

main ∷ IO ()
main = hspec Spec.spec
