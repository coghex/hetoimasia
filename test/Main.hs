-- | Entry point for the headless engine suite.
--
-- The examples live in the component specs 'Test.Engine.Spec' composes; this
-- module declares none of its own.
--
-- 'configFailOnEmpty' makes a selection that matches no example a failure
-- rather than a silent pass, so focusing a component with a name the tree does
-- not carry — a typo, or a group that has been renamed — exits non-zero instead
-- of reporting @0 examples, 0 failures@ and succeeding. The command line is
-- still read on top of this default, so @--no-fail-on=empty@ restores the
-- runner's own behaviour for a caller that wants it.
module Main (main) where

import qualified Test.Engine.Spec as Engine
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig { configFailOnEmpty = True } Engine.spec
