{-# LANGUAGE OverloadedStrings #-}

-- | The harness's judgement of a failed run's teardown, examined with no device and no session (LFE-25, #540).
--
-- When a scenario throws, the capture attaches its diagnostic verdict to the exception and the scopes retain their
-- cleanup failures beside it. The unwinding control must not pass on the scenario's own failure alone: it asks
-- 'Test.Run.Native.Peers.judgeTeardown' what the teardown said. These examples are the negative controls of that rule:
-- a verdict with any issue (a lost record, a latched error, a dropped or truncated one, an unproven quiescence, retained
-- storage), a missing verdict, a retained cleanup failure and a finalization observation each make the judgement
-- non-empty, and only a clean attached verdict with nothing beside it does not.
module Test.Run.Native.PeersSpec (spec) where

import Data.List (isInfixOf)
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureCounters (..)
  , CaptureStatus (..)
  , ConsumerOutcome (..)
  , DiagnosticVerdict (..)
  )
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Run.Native.Peers (judgeTeardown)

clean ∷ DiagnosticVerdict
clean =
  DiagnosticVerdict
    { verdictStatus = CaptureStatus False False (CaptureCounters 0 0 0 0 0 0)
    , verdictDelivered = 0
    , verdictUndelivered = 0
    , verdictConsumer = ConsumerCompleted
    , verdictQuiescent = True
    , verdictStorageRetained = False
    }

mentions ∷ String → [String] → Bool
mentions word = any (word `isInfixOf`)

spec ∷ Spec
spec = describe "the harness's judgement of a failed teardown" $ do
  it "finds nothing to report when the verdict is attached and clean and nothing was retained beside the failure" $
    judgeTeardown (Just clean) 0 False `shouldBe` []
  it "reports a record the capture lost" $
    judgeTeardown (Just clean {verdictUndelivered = 2, verdictStatus = CaptureStatus False False (CaptureCounters 2 2 0 0 0 0)}) 0 False `shouldSatisfy` mentions "RecordsUndelivered"
  it "reports a dropped record and a latched validation error" $ do
    judgeTeardown (Just clean {verdictStatus = CaptureStatus False False (CaptureCounters 3 2 1 0 0 0)}) 0 False `shouldSatisfy` mentions "RecordsDropped"
    judgeTeardown (Just clean {verdictStatus = CaptureStatus True False (CaptureCounters 1 1 0 0 0 1), verdictDelivered = 1}) 0 False `shouldSatisfy` mentions "ErrorLatched"
  it "reports a teardown whose quiescence was never proved, and storage still retained" $ do
    judgeTeardown (Just clean {verdictQuiescent = False}) 0 False `shouldSatisfy` mentions "QuiescenceUnproven"
    judgeTeardown (Just clean {verdictStorageRetained = True}) 0 False `shouldSatisfy` mentions "StorageRetained"
  it "reports a failure that reached the caller with no verdict attached" $
    judgeTeardown Nothing 0 False `shouldSatisfy` mentions "no diagnostic verdict"
  it "reports a cleanup failure retained beside the failure, and a finalization observation" $ do
    judgeTeardown (Just clean) 1 False `shouldSatisfy` mentions "cleanup failure"
    judgeTeardown (Just clean) 0 True `shouldSatisfy` mentions "finalization observed"
