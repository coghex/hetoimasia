-- | The invocation policy, exercised headlessly.
--
-- What these protect is the compatibility record's verdict. The record says
-- @Verdict: pass@ or @Verdict: fail@ about the whole contract, and that claim
-- is only worth anything if the run that produced it evaluated the whole
-- contract. A selector reaching the native run would break exactly that, and
-- the examples below are where "it cannot" is written down.
module Test.Vulkan.Proof.InvocationSpec (spec) where

import qualified Data.Text as Text
import Test.Hspec

import Test.Vulkan.Proof.Invocation

spec ∷ Spec
spec = describe "The harness's own invocation" $ do
  it "runs the native procedure when it is given nothing to select" $
    selectMode [] `shouldBe` Native

  it "selects the headless examples on the flag, and passes the rest to Hspec" $ do
    selectMode ["--headless"] `shouldBe` Headless []
    selectMode ["--headless", "--match", "A whole run"]
      `shouldBe` Headless ["--match", "A whole run"]
    selectMode ["--match", "A whole run", "--headless"]
      `shouldBe` Headless ["--match", "A whole run"]

  it "refuses a native run that carries a selector, rather than ignoring it" $ do
    -- A filtered native run is the one that could write `Verdict: pass` onto a
    -- record whose own body says the run stopped: `--match 'A whole run'`
    -- selects only the pure examples, and every example that asserts over the
    -- native outcome is left out. Refusing makes that combination
    -- unrepresentable rather than merely unlikely.
    selectMode ["--match", "A whole run"] `shouldSatisfy` isRefusal
    selectMode ["--skip", "Teardown"] `shouldSatisfy` isRefusal
    selectMode ["--rerun"] `shouldSatisfy` isRefusal

  it "says what it was given and what to pass instead" $
    case selectMode ["--match", "Teardown"] of
      Refused reason → do
        reason `shouldSatisfy` Text.isInfixOf "--match Teardown"
        reason `shouldSatisfy` Text.isInfixOf "--headless"
        reason `shouldSatisfy` Text.isInfixOf "whole contract"
      other → expectationFailure ("a native selector was not refused: " <> show other)

isRefusal ∷ Mode → Bool
isRefusal = \case
  Refused _ → True
  _ → False
