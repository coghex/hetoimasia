-- | The probe record is well-formed JSON whatever a failure's message holds:
-- control characters, quotes and backslashes are escaped. A recursive-descent
-- checker of the suite's own parses each record, with no JSON dependency.
module Test.Sample.Sprites.Record (spec) where

import Data.Char (isDigit, isHexDigit, isSpace)
import qualified Data.Text as Text
import Test.Hspec

import Hetoimasia.Sample.Sprites.Evidence (renderRecord)
import Hetoimasia.Sample.Sprites.Oracle (evaluateProbes)

spec ∷ Spec
spec = describe "Sprites probe record" $ do
  it "is well-formed JSON for a failure carrying newlines, tabs, carriage returns, other control characters, quotes and backslashes" $ do
    let failure = Text.pack "an upload did not complete:\n\tline two\r\n\"quoted\" \\ back\x01\x1f end"
        record = Text.unpack (renderRecord (Just failure) (Just False) 0 [])
    wellFormed record `shouldBe` True
    filter (< ' ') (init record) `shouldBe` ""
    record `shouldContain` "\\n\\tline two\\r\\n\\\"quoted\\\" \\\\ back\\u0001\\u001f end"

  it "is well-formed JSON for a run's every probe" $ do
    let probes = evaluateProbes True mempty
    wellFormed (Text.unpack (renderRecord Nothing (Just True) 262144 probes)) `shouldBe` True

  it "refuses malformed documents, so its acceptance means something" $ do
    map wellFormed ["{\"a\": \"line\nbreak\"}", "{\"a\": [1, 2,]}", "{\"a\" 1}", "[\"\\x\"]", "{} {}"] `shouldBe` replicate 5 False
    map wellFormed ["{\"a\": [1, -2.5e3, true, false, null, \"\\u00e9\\n\"], \"b\": {}}", "[]"] `shouldBe` [True, True]

-- | Whether the text is exactly one JSON value, surrounded by whitespace.
wellFormed ∷ String → Bool
wellFormed text = case value (skip text) of
  Just rest → null (skip rest)
  Nothing → False
  where
    skip = dropWhile isSpace
    value = \case
      '{' : rest → members (skip rest)
      '[' : rest → elements (skip rest)
      '"' : rest → string rest
      't' : 'r' : 'u' : 'e' : rest → Just rest
      'f' : 'a' : 'l' : 's' : 'e' : rest → Just rest
      'n' : 'u' : 'l' : 'l' : rest → Just rest
      other → number other
    members = \case
      '}' : rest → Just rest
      chars → member chars
    member chars = do
      afterKey ← case chars of
        '"' : rest → string rest
        _ → Nothing
      afterColon ← case skip afterKey of
        ':' : rest → Just (skip rest)
        _ → Nothing
      afterValue ← skip <$> value afterColon
      case afterValue of
        ',' : rest → member (skip rest)
        '}' : rest → Just rest
        _ → Nothing
    elements = \case
      ']' : rest → Just rest
      chars → element chars
    element chars = do
      afterValue ← skip <$> value chars
      case afterValue of
        ',' : rest → element (skip rest)
        ']' : rest → Just rest
        _ → Nothing
    string = \case
      '"' : rest → Just rest
      '\\' : c : rest
        | c `elem` ("\"\\/bfnrt" ∷ String) → string rest
        | c == 'u', (digits, rest') ← splitAt 4 rest, length digits == 4, all isHexDigit digits → string rest'
        | otherwise → Nothing
      c : rest
        | c < ' ' → Nothing
        | otherwise → string rest
      [] → Nothing
    number chars =
      let rest = case chars of
            '-' : more → more
            more → more
          (integer, afterInteger) = span isDigit rest
          (fraction, afterFraction) = case afterInteger of
            '.' : more → let (digits, after) = span isDigit more in (Just digits, after)
            more → (Nothing, more)
          (exponent', afterExponent) = case afterFraction of
            e : more | e `elem` ("eE" ∷ String) → let (digits, after) = span isDigit (dropWhile (`elem` ("+-" ∷ String)) more) in (Just digits, after)
            more → (Nothing, more)
       in if null integer || fraction == Just "" || exponent' == Just "" then Nothing else Just afterExponent
