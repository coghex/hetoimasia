-- | Configuration: the design's initial limits, and every bound a lifetime
-- refuses before it allocates anything.
module Test.GPU.Vulkan.Diagnostics.Config (spec) where

import Control.Exception (try)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word32)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureConfig (..)
  , CaptureConfigError (..)
  , DiagnosticVerdict
  , LimitError (..)
  , defaultCaptureConfig
  , validateCaptureConfig
  , withDiagnosticCapture
  )
import Test.GPU.Vulkan.Diagnostics.Support (everythingFilter, recordingLogger)

spec ∷ Spec
spec = describe "Configuration" $ do
  it "defaults to 1,024 records, 4 KiB of text per record and 16 objects" $ do
    captureQueueCapacity defaultCaptureConfig `shouldBe` 1024
    captureTextBudget defaultCaptureConfig `shouldBe` 4096
    captureObjectLimit defaultCaptureConfig `shouldBe` 16
    validateCaptureConfig defaultCaptureConfig `shouldSatisfy` either (const False) (const True)

  it "rejects a limit that is not positive" $ do
    let rejected config = either Just (const Nothing) (validateCaptureConfig config)
    rejected defaultCaptureConfig {captureQueueCapacity = 0}
      `shouldBe` Just (CaptureLimitRejected (QueueCapacityRejected 0))
    rejected defaultCaptureConfig {captureTextBudget = -1}
      `shouldBe` Just (CaptureLimitRejected (TextBudgetRejected (-1)))
    rejected defaultCaptureConfig {captureObjectLimit = 0}
      `shouldBe` Just (CaptureLimitRejected (ObjectLimitRejected 0))
    rejected defaultCaptureConfig {capturePollInterval = 0}
      `shouldBe` Just (PollIntervalRejected 0)

  it "rejects a limit the storage cannot count" $ do
    let beyond = fromIntegral (maxBound ∷ Word32) + 1
    validateCaptureConfig defaultCaptureConfig {captureObjectLimit = beyond}
      `shouldBe` Left (CaptureLimitRejected (ObjectLimitRejected beyond))

  it "rejects limits whose allocation cannot be represented, though each fits" $ do
    let huge = fromIntegral (maxBound ∷ Word32)
    case validateCaptureConfig defaultCaptureConfig {captureQueueCapacity = huge, captureTextBudget = huge} of
      Left (CaptureLimitRejected (AllocationUnrepresentable bytes)) →
        bytes `shouldSatisfy` (> toInteger (maxBound ∷ Int))
      other → expectationFailure ("expected an unrepresentable allocation, got " <> show other)

  it "refuses a rejected configuration before it runs the body" $ do
    (logger, _) ← recordingLogger everythingFilter
    ran ← newIORef False
    result ←
      try (withDiagnosticCapture defaultCaptureConfig {captureTextBudget = 0} logger (\_ → writeIORef ran True))
    fmap snd' result `shouldBe` Left (CaptureLimitRejected (TextBudgetRejected 0))
    readIORef ran `shouldReturn` False
  where
    snd' ∷ ((), DiagnosticVerdict) → ()
    snd' _ = ()
