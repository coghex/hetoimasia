-- | What the bounded-preflight examples share: the asset they preflight as,
-- limits built from the M1 values with some changed, and assertions that
-- report a refusal's class and reason instead of printing a whole result.
module Test.Asset.Image.PreflightSupport
  ( asset
  , m1Settings
  , limitsWith
  , preflight
  , preflightUnder
  , shouldBeRefusedAs
  , shouldBeAccepted
  , acceptedWith
  , classOfRefusal
  )
where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Data.ByteString (ByteString)
import qualified Data.Text as Text
import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (..))
import Hetoimasia.Asset.Image.PngPreflight
import Test.Hspec (Expectation, expectationFailure, shouldBe, shouldSatisfy)

asset ∷ Asset
asset = Asset (AssetId "preflight") (FromMemory "Test.Asset.Image.PngPreflight")

-- | The M1 values as settings, to change one or two of them.
m1Settings ∷ PngLimitSettings
m1Settings = pngLimitSettings m1PngLimits

-- | Limits from the M1 settings with a change; an invalid change is a bug in
-- the example, not a refusal under test.
limitsWith ∷ (PngLimitSettings → PngLimitSettings) → PngLimits
limitsWith change = case pngLimits (change m1Settings) of
  Right limits → limits
  Left refusal → error ("the example's limits are invalid: " <> show refusal)

-- | Preflight under the M1 limits, the result evaluated completely.
preflight ∷ ByteString → IO (Either PngRefusal PngPreflight)
preflight = preflightUnder m1PngLimits

preflightUnder ∷ PngLimits → ByteString → IO (Either PngRefusal PngPreflight)
preflightUnder limits bytes = evaluate (force (preflightPng limits asset bytes))

classOfRefusal ∷ Either PngRefusal a → Maybe PngRefusalClass
classOfRefusal = either (Just . pngRefusalClass) (const Nothing)

-- | The result is a refusal of this class, naming the asset, with a bounded
-- non-empty reason.
shouldBeRefusedAs ∷ Either PngRefusal PngPreflight → PngRefusalClass → Expectation
shouldBeRefusedAs result expected = case result of
  Left refusal → do
    pngRefusedAsset refusal `shouldBe` asset
    pngRefusalClass refusal `shouldBe` expected
    Text.length (pngRefusalReason refusal) `shouldSatisfy` (\n → n > 0 && n < 300)
  Right accepted →
    expectationFailure ("expected a refusal of class " <> show expected <> ", got an accepted " <> show (preflightWidth accepted, preflightHeight accepted))

shouldBeAccepted ∷ Either PngRefusal PngPreflight → IO PngPreflight
shouldBeAccepted = \case
  Right accepted → pure accepted
  Left refusal → expectationFailure ("expected acceptance, refused as " <> show (pngRefusalClass refusal) <> ": " <> Text.unpack (pngRefusalReason refusal)) >> fail "refused"

-- | Accepted, then inspected.
acceptedWith ∷ Either PngRefusal PngPreflight → (PngPreflight → Expectation) → Expectation
acceptedWith result check = shouldBeAccepted result >>= check
