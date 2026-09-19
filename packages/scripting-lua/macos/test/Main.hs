-- | The macOS confinement probe's entry point.
--
-- Built only on Darwin, registered as an optional validation group, and never
-- part of the mandatory floor: it is LUA-15's local feasibility evidence, not a
-- check every contribution has to pass. See docs/macos_confinement_verdict.md
-- for what it concluded.
module Main (main) where

import Test.Hspec (hspec)

import qualified Test.MacOS.Spec as MacOS

main ∷ IO ()
main = hspec MacOS.spec
