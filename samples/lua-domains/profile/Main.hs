-- | Entry point for the sample's profiling probe.
--
-- The probe is the one example of 'Profile.Workloads.spec'. It runs bounded workloads and prints one record for each; it
-- asserts nothing about a number and gates nothing (P-11). A selection that matches no example is a failure rather than a
-- silent pass.
module Main (main) where

import qualified Profile.Workloads
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} Profile.Workloads.spec
