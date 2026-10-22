{-# LANGUAGE OverloadedStrings #-}

-- | @tick_seconds@: exact decimal nanoseconds, its endpoints, every forbidden
-- form and overflow, with no floating-point rounding and no default.
module Test.LuaEngine.Manifest.Tick (spec) where

import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (RequirePositive), durationFromNanoseconds)
import Hetoimasia.LuaEngine.Manifest
import Hetoimasia.LuaEngine.Profile
import Test.Hspec
import Test.LuaEngine.Support

-- | The tick of a gameplay-only manifest whose @tick_seconds@ is the given
-- JSON-escaped text, or the refusal.
tickOf ∷ Text → Either ManifestError Duration
tickOf text =
  case parsed (document [member "format" "1", member "id" (quoted "g"), member "entry" (quoted "e.lua"), member "tick_seconds" (quoted text)]) of
    Right manifest → case gameplayOf (manifestRoles manifest) of
      Just role → Right (gameplayTick role)
      Nothing → error "a manifest with a tick has gameplay"
    Left refusal → Left refusal

refusedAs ∷ Text → TickProblem → Expectation
refusedAs text problem = tickOf text `shouldBe` Left (ManifestSchema (InvalidTick problem))

accepts ∷ Text → Integer → Expectation
accepts text count = tickOf text `shouldBe` Right (nanoseconds count)

-- | The largest duration: 2^64 − 1 nanoseconds.
maximumNanoseconds ∷ Integer
maximumNanoseconds = 2 ^ (64 ∷ Int) - 1

spec ∷ Spec
spec = describe "tick_seconds" $ do
  it "converts decimal seconds exactly to whole nanoseconds" $ do
    "0.01" `accepts` 10000000
    "1" `accepts` 1000000000
    "0.5" `accepts` 500000000
    "2.25" `accepts` 2250000000
    "60" `accepts` 60000000000
    "0.016666666" `accepts` 16666666
    "0.123456789" `accepts` 123456789
    "1.000000001" `accepts` 1000000001

  it "accepts the endpoints: one nanosecond and 2^64 − 1 nanoseconds" $ do
    "0.000000001" `accepts` 1
    "18446744073.709551615" `accepts` maximumNanoseconds
    "18446744073.709551614" `accepts` (maximumNanoseconds - 1)

  it "ignores leading and trailing zero digits" $ do
    "007" `accepts` 7000000000
    "0.010" `accepts` 10000000
    "0.010000000" `accepts` 10000000
    "00.5" `accepts` 500000000
    "1.000000000" `accepts` 1000000000
    "000000000000000000000000000000000000000001" `accepts` 1000000000
    "0000000000000000000018446744073.709551615" `accepts` maximumNanoseconds

  it "refuses zero in every spelling" $ do
    "0" `refusedAs` TickZero
    "0.0" `refusedAs` TickZero
    "00" `refusedAs` TickZero
    "0.000000000" `refusedAs` TickZero
    Text.replicate 40000 "0" `refusedAs` TickZero

  it "refuses one nanosecond past the maximum and anything larger, without size-derived work" $ do
    "18446744073.709551616" `refusedAs` TickAboveMaximum
    "18446744074" `refusedAs` TickAboveMaximum
    "18446744074.000000000" `refusedAs` TickAboveMaximum
    "99999999999999999999999999" `refusedAs` TickAboveMaximum
    "100000000000000000000" `refusedAs` TickAboveMaximum
    Text.replicate 60000 "9" `refusedAs` TickAboveMaximum
    ("1" <> Text.replicate 60000 "0") `refusedAs` TickAboveMaximum

  it "refuses a fraction of more than nine digits, even when it would not round" $ do
    "1.0000000000" `refusedAs` TickFractionTooLong 10
    "0.0000000010" `refusedAs` TickFractionTooLong 10
    "0.0000000015" `refusedAs` TickFractionTooLong 10
    "0.5000000000" `refusedAs` TickFractionTooLong 10
    ("1." <> Text.replicate 5000 "0") `refusedAs` TickFractionTooLong 5000

  it "refuses an empty text and a decimal point without a digit on either side" $ do
    "" `refusedAs` TickEmpty
    ".5" `refusedAs` TickNoLeadingDigit
    "." `refusedAs` TickNoLeadingDigit
    "5." `refusedAs` TickFractionEmpty

  it "refuses signs, exponents, spaces, fraction expressions and every other character" $ do
    "+1" `refusedAs` TickBadCharacter 0
    "-1" `refusedAs` TickBadCharacter 0
    "-0" `refusedAs` TickBadCharacter 0
    " 1" `refusedAs` TickBadCharacter 0
    "1 " `refusedAs` TickBadCharacter 1
    "1e3" `refusedAs` TickBadCharacter 1
    "1E3" `refusedAs` TickBadCharacter 1
    "1.5e3" `refusedAs` TickBadCharacter 3
    "1/60" `refusedAs` TickBadCharacter 1
    "1_000" `refusedAs` TickBadCharacter 1
    "1,5" `refusedAs` TickBadCharacter 1
    "0x10" `refusedAs` TickBadCharacter 1
    "1.5.2" `refusedAs` TickBadCharacter 3
    "1..5" `refusedAs` TickBadCharacter 2
    "1.5 " `refusedAs` TickBadCharacter 3
    "NaN" `refusedAs` TickBadCharacter 0
    "Infinity" `refusedAs` TickBadCharacter 0
    "0.01s" `refusedAs` TickBadCharacter 4
    "１" `refusedAs` TickBadCharacter 0 -- a fullwidth digit
    "١" `refusedAs` TickBadCharacter 0 -- an Arabic-Indic digit
    "1.٥" `refusedAs` TickBadCharacter 2

  it "reads only a JSON string: a number, even an exact one, is not a tick" $ do
    let withTick token = parsed (document [member "format" "1", member "id" (quoted "g"), member "entry" (quoted "e.lua"), member "tick_seconds" token])
    withTick "0.01" `shouldBe` Left (ManifestSchema (WrongType [PathKey (Excerpt "tick_seconds" False)] ExpectedString KindNumber))
    withTick "1" `shouldBe` Left (ManifestSchema (WrongType [PathKey (Excerpt "tick_seconds" False)] ExpectedString KindNumber))

  it "decodes escapes before reading the digits" $ do
    "\\u0031" `accepts` 1000000000
    "0\\u002e5" `accepts` 500000000
    "0\\u002f5" `refusedAs` TickBadCharacter 1

  it "has the foundation duration's range: positive, 2^64 − 1 nanoseconds at most" $ do
    durationFromNanoseconds RequirePositive maximumNanoseconds `shouldSatisfy` either (const False) (const True)
    durationFromNanoseconds RequirePositive (maximumNanoseconds + 1) `shouldSatisfy` either (const True) (const False)

  it "applies a smaller injected maximum at the maximum and one past it" $ do
    let profile =
          let base = profileSpec fixedM1Profile
              limited = base {specDurations = \limit → if limit == ManifestTickMaximum then nanoseconds 5 else specDurations base limit}
           in either (error . show) id (validateProfile limited)
        tickWith text = parseManifestWith profile (document [member "format" "1", member "id" (quoted "g"), member "entry" (quoted "e.lua"), member "tick_seconds" (quoted text)])
    tickOf "0.000000005" `shouldBe` Right (nanoseconds 5)
    tickWith "0.000000006" `shouldBe` Left (ManifestSchema (InvalidTick TickAboveMaximum))
    fmap (fmap gameplayTick . gameplayOf . manifestRoles) (tickWith "0.000000005") `shouldBe` Right (Just (nanoseconds 5))
