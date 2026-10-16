module Main (main) where

import Test.Hspec (hspec)
import qualified Test.LuaRuntime.Spec

main ∷ IO ()
main = hspec Test.LuaRuntime.Spec.spec
