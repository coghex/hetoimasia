-- | Hspec coverage for the isolated-X11 window helper (LFE-25, #540).
--
-- @tools/display/x11_window.py@ identifies, observes, captures and closes one suite-owned native window on the
-- isolated X11 display. Its logic (identity, ambiguity between windows that share one pid, vanished targets, a
-- refused close, a malformed capture and the cleanup of a failed one) is tested over an in-memory display by
-- @tools/display/x11_window_test.py@, which opens no display, loads no X library and controls no desktop. This
-- example runs that file in the mandatory workflow floor and requires that it ran a nonzero number of examples
-- and that all passed, so an emptied or skipped file cannot go green.
module X11Window (spec) where

import Data.Char (isDigit)
import Data.List (isInfixOf, isPrefixOf, stripPrefix)
import Sandbox (run, sanitizedEnvironment)
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)

spec ∷ Spec
spec = describe "X11 window helper" $
  it "passes its device-free examples (identity, ambiguity, vanished targets, refused close, malformed capture, cleanup)" $ do
    checkout ← getCurrentDirectory
    settings ← sanitizedEnvironment
    (result, _, errors) ←
      run
        (("PYTHONDONTWRITEBYTECODE", "1") : settings)
        checkout
        "python3"
        ["-I", "-W", "error", checkout </> "tools/display/x11_window_test.py"]
    result `shouldBe` ExitSuccess
    case [count | line ← lines errors, Just rest ← [stripPrefix "Ran " line], let count = takeWhile isDigit rest, not (null count)] of
      [count] | read count >= (20 ∷ Int) → pure ()
      other → expectationFailure ("the helper's tests ran " <> show other <> " examples; expected at least 20\n" <> errors)
    if "OK" `isPrefixOf` last (lines errors) || "OK" `isInfixOf` last (lines errors)
      then pure ()
      else expectationFailure ("the helper's tests did not end OK\n" <> errors)
