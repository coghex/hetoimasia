-- | Runs the GLFW window model, window command, and window host examples from
-- the package's own @glfw-window-examples@ executable.
--
-- Those examples drive windows through the test seam's private window
-- drivers — scripted callbacks, a cancellation at the reconciliation's
-- preparation point, and close-request rejection — which live in
-- @hetoimasia-glfw@'s private @seam-core@ sublibrary so that no package outside
-- it can name them. This suite therefore cannot import them; it reaches the
-- executable through its @build-tool-depends@, runs it, and fails with the
-- executable's own report if any example fails. The executable initializes no
-- GLFW and opens no display.
module Test.Engine.GLFW.WindowModel (spec) where

import Data.List (isInfixOf)
import System.Directory (findExecutable)
import System.Exit (ExitCode (ExitSuccess))
import System.Process (readProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it)

spec ∷ Spec
spec = describe "GLFW window model" $
  it "passes every window model example in the package's private-driver executable" $ do
    found ← findExecutable "glfw-window-examples"
    case found of
      Nothing →
        expectationFailure
          "glfw-window-examples is not on PATH; it is reached through this suite's build-tool-depends"
      Just executable → do
        (status, out, err) ← readProcessWithExitCode executable ["--no-color"] ""
        let report = out <> err
        if status == ExitSuccess && " 0 failures" `isInfixOf` report && not (" 0 examples" `isInfixOf` report)
          then pure ()
          else
            expectationFailure
              ("glfw-window-examples exited with " <> show status <> ":\n" <> report)
