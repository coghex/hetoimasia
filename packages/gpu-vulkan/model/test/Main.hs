-- | Entry point for the GPU model package's suite.
--
-- The examples live in the component specs 'Test.GPU.Model.Spec' composes; this
-- module declares none of its own.
--
-- 'configFailOnEmpty' makes a selection that matches no example a failure
-- rather than a silent pass, so focusing a component with a name the tree does
-- not carry exits non-zero instead of reporting @0 examples, 0 failures@ and
-- succeeding.
module Main (main) where

import qualified Test.GPU.Model.Spec as Model
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} Model.spec
