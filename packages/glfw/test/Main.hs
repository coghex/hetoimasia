-- | Entry point for the GLFW package's headless suite.
--
-- The examples live in the component specs 'Test.GLFW.Spec' composes; this
-- module declares none of its own.
--
-- 'configFailOnEmpty' makes a selection that matches no example a failure
-- rather than a silent pass, so focusing a component with a name the tree does
-- not carry — a typo, or a group that has been renamed or has moved to another
-- suite — exits non-zero instead of reporting @0 examples, 0 failures@ and
-- succeeding. The command line is still read on top of this default, so
-- @--no-fail-on=empty@ restores the runner's own behaviour for a caller that
-- wants it.
--
-- One example ends a real process: "Test.GLFW.Deadline" runs this executable
-- again as a child whose main thread is blocked in a safe foreign call, with
-- 'childVariable' naming the scenario. A child declares no example; it runs the
-- scenario and ends.
module Main (main) where

import System.Environment (lookupEnv)
import Test.GLFW.Deadline (childVariable, runChild)
import qualified Test.GLFW.Spec as GLFW
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = lookupEnv childVariable >>= \case
  Just scenario → runChild scenario
  Nothing → hspecWith defaultConfig { configFailOnEmpty = True } GLFW.spec
