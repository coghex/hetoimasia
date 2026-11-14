-- | The real-platform qualification of the storage backend (TRA-21, requirement 9): the production native backend on
-- a bounded, disposable volume of the platform it runs on.
--
-- This is an explicit local probe, never part of the routine suite: it fills a capped volume, so it runs only against
-- a fixture the operator made for it (the setup scripts under @tools/terrain-storage/@ write the pointer file). Every
-- example begins by acquiring that fixture through 'pointerFixture', which verifies it (a distinct device, owned by
-- the running user, a total capacity within the cap, the capacity asked of an opened descriptor) before anything is
-- allocated; a missing or mismatched fixture fails the example, never skips it and never falls back to another
-- volume. The examples themselves are 'Test.TerrainRuntime.Storage.ProbeSpec.probeCases'.
module Main (main) where

import Control.Monad (forM_)
import System.Info (arch, compilerVersion, os)
import Test.Hspec
import Test.TerrainRuntime.Runner (runSuite)
import Test.TerrainRuntime.Storage.Fixture (pointerFixture)
import Test.TerrainRuntime.Storage.ProbeSpec (probeCases)

main :: IO ()
main = runSuite $ describe "Terrain storage qualification on this platform" $ do
  forM_ probeCases $ \(name, run) -> it name (run pointerFixture)
  where
    _platform = (os, arch, compilerVersion)
