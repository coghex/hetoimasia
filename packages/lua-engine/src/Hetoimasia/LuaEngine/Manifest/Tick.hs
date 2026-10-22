-- | The manifest's @tick_seconds@: decimal text converted exactly to whole
-- nanoseconds.
--
-- __Grammar.__ ASCII digits, then optionally a decimal point and one to nine
-- digits; at least one digit before the point. No sign, exponent, whitespace,
-- fraction expression, JSON number or default. Leading zeros and trailing
-- fraction zeros change nothing.
--
-- __Arithmetic.__ The value is 'Integer' arithmetic on the digits, never a
-- 'Double'. A whole part with more significant digits than any representable
-- duration could have is refused before it is converted, so the work is bounded
-- by the text, not by the number it names. The result must be at least one
-- nanosecond and at most the profile's maximum, which is the foundation's
-- @2^64 - 1@ for the fixed profile.
--
-- __Relation to the console.__ The @lua@ command's @parseSeconds@ accepts the
-- same text for its own options. That function is console code, and the engine
-- never imports the console, so this is the engine's own implementation of the
-- same contract; the console is unchanged.
module Hetoimasia.LuaEngine.Manifest.Tick
  ( parseTickSeconds
  ) where

import Data.Char (ord)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRejected (..)
  , DurationRequirement (RequirePositive)
  , durationFromNanoseconds
  )
import Hetoimasia.LuaEngine.Manifest.Error (TickProblem (..))

-- | The duration the text names, if it is within the given maximum.
parseTickSeconds ∷ Duration → Text → Either TickProblem Duration
parseTickSeconds maximumTick text = do
  let (wholeDigits, afterWhole) = Text.span isDigit text
  if Text.null wholeDigits
    then
      Left $ case Text.uncons text of
        Nothing → TickEmpty
        Just ('.', _) → TickNoLeadingDigit
        Just _ → TickBadCharacter 0
    else Right ()
  fractionDigits ← case Text.uncons afterWhole of
    Nothing → Right Text.empty
    Just ('.', afterPoint) → do
      let (digits, rest) = Text.span isDigit afterPoint
          pointIndex = Text.length wholeDigits
      if Text.null digits
        then Left (if Text.null rest then TickFractionEmpty else TickBadCharacter (pointIndex + 1))
        else Right ()
      if Text.null rest then Right () else Left (TickBadCharacter (pointIndex + 1 + Text.length digits))
      if Text.length digits > 9 then Left (TickFractionTooLong (Text.length digits)) else Right ()
      Right digits
    Just _ → Left (TickBadCharacter (Text.length wholeDigits))
  let significantWhole = Text.dropWhile (== '0') wholeDigits
  -- 2^64 - 1 nanoseconds is under 1.9e10 seconds: eleven digits. Twenty is a
  -- generous bound, so what is converted below is at most twenty digits.
  if Text.length significantWhole > 20 then Left TickAboveMaximum else Right ()
  let nanoseconds =
        digitsValue significantWhole * 1000000000
          + digitsValue (Text.justifyLeft 9 '0' fractionDigits)
  case durationFromNanoseconds RequirePositive nanoseconds of
    Left DurationZero → Left TickZero
    Left _ → Left TickAboveMaximum
    Right duration
      | duration > maximumTick → Left TickAboveMaximum
      | otherwise → Right duration

-- | An ASCII digit; no other character, whatever Unicode calls it.
isDigit ∷ Char → Bool
isDigit character = character >= '0' && character <= '9'

-- | The value of a text of ASCII digits (at most twenty of them).
digitsValue ∷ Text → Integer
digitsValue = Text.foldl' (\total digit → total * 10 + toInteger (ord digit - ord '0')) 0
