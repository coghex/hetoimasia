-- | Entry point for the Lua engine package's suite.
--
-- The examples live in the component specs 'Test.LuaEngine.Spec' composes; this
-- module declares none of its own.
--
-- 'configFailOnEmpty' makes a selection that matches no example a failure
-- rather than a silent pass, so focusing a component with a name the tree does
-- not carry exits non-zero instead of reporting @0 examples, 0 failures@ and
-- succeeding.
--
-- The terrain set runs once more, last, on the multi-capability pass's count
-- ("Test.LuaEngine.Terrain.Spec"): one setting, read here before anything
-- changes the capability count, from @HETOIMASIA_CONCURRENT_PASS_CAPABILITIES@,
-- else from the count the process started with when it is 2 or more (the lab's
-- @+RTS -N<k>@), else 2 ("Test.Support.Capabilities"); a count below 2 or not a
-- number ends the run with status 2 before any example.
module Main (main) where

import Control.Concurrent (getNumCapabilities)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)
import qualified Test.LuaEngine.Spec as LuaEngine
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)
import Test.Support.Capabilities (resolvePassFromEnvironment)

main ∷ IO ()
main = do
  started ← getNumCapabilities
  pass ← resolvePassFromEnvironment started >>= either refuse pure
  hspecWith defaultConfig {configFailOnEmpty = True} (LuaEngine.spec pass)
  where
    refuse why = hPutStrLn stderr ("lua-engine-tests: " <> why) >> exitWith (ExitFailure 2)
