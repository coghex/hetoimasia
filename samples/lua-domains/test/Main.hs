-- | Entry point for the sample's suite.
--
-- The examples live in the specs 'Test.Domains.Spec' composes; this module declares none of its
-- own. 'configFailOnEmpty' makes a selection that matches no example a failure rather than a
-- silent pass, so a selector the tree does not carry exits non-zero.
module Main (main) where

import qualified Test.Domains.Spec
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} Test.Domains.Spec.spec
