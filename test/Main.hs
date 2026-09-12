-- | Entry point for the headless engine suite.
--
-- The examples live in the component specs 'Test.Engine.Spec' composes; this
-- module declares none of its own.
module Main (main) where

import qualified Test.Engine.Spec as Engine
import Test.Hspec (hspec)

main ∷ IO ()
main = hspec Engine.spec
