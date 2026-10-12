-- | Entry point for the render-2d package's suite.
--
-- The examples live in the component specs 'Test.Render.TwoD.Spec' composes;
-- this module declares none of its own.
--
-- 'configFailOnEmpty' makes a selection that matches no example a failure
-- rather than a silent pass, so focusing a component with a name the tree does
-- not carry exits non-zero instead of reporting @0 examples, 0 failures@ and
-- succeeding.
module Main (main) where

import qualified Test.Render.TwoD.Spec as TwoD
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} TwoD.spec
