module Main (main) where

import Test.Hspec (hspec)
import qualified Test.Lua.Spec

main ∷ IO ()
main = hspec Test.Lua.Spec.spec
