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
--
-- In the full-product build this binary is also the child process of the @run@ command's signal examples
-- ('Test.Engine.Variant.childEntry'): launched by the suite itself with the one variable it sets, it runs
-- the command's real composition over real signal handlers without a native session, and does not run Hspec.
module Main (main) where

import Control.Monad (unless)
import qualified Test.Engine.Spec as Engine
import qualified Test.Engine.Variant as Variant
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = do
  child ← Variant.childEntry
  unless child $ hspecWith defaultConfig { configFailOnEmpty = True } Engine.spec
