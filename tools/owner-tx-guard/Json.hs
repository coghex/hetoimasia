{-# LANGUAGE NoOverloadedStrings #-}

-- | A small JSON reader for the guard's allowlist: objects, arrays, strings, integers, booleans and null. It reads the
-- whole document or refuses it, naming where it stopped; nothing is guessed. An integer with a leading zero, a number
-- with a fraction or an exponent, and an object that repeats a key are refused.
module Json
  ( Json (..)
  , parseJson
  , member
  , asArray
  , asString
  , asInteger
  ) where

import Data.Char (chr, isDigit, isHexDigit, isSpace)
import Numeric (readHex)

data Json
  = JObject [(String, Json)]
  | JArray [Json]
  | JString String
  | JNumber Integer
  | JBool Bool
  | JNull
  deriving (Eq, Show)

parseJson ∷ String → Either String Json
parseJson text = case value (skip text) of
  Left why → Left why
  Right (parsed, rest)
    | all isSpace rest → Right parsed
    | otherwise → Left ("trailing text: " <> take 40 rest)

member ∷ String → Json → Maybe Json
member key (JObject fields) = lookup key fields
member _ _ = Nothing

asArray ∷ Json → Maybe [Json]
asArray (JArray items) = Just items
asArray _ = Nothing

asString ∷ Json → Maybe String
asString (JString text) = Just text
asString _ = Nothing

asInteger ∷ Json → Maybe Integer
asInteger (JNumber number) = Just number
asInteger _ = Nothing

skip ∷ String → String
skip = dropWhile isSpace

value ∷ String → Either String (Json, String)
value input = case input of
  '{' : rest → object (skip rest) []
  '[' : rest → array (skip rest) []
  '"' : rest → fmap (\(text, after) → (JString text, after)) (string rest "")
  't' : 'r' : 'u' : 'e' : rest → Right (JBool True, rest)
  'f' : 'a' : 'l' : 's' : 'e' : rest → Right (JBool False, rest)
  'n' : 'u' : 'l' : 'l' : rest → Right (JNull, rest)
  '-' : rest | (digits@(_ : _), after) ← span isDigit rest → fmap (\n → (JNumber (negate n), after)) (integer digits after)
  _ | (digits@(_ : _), after) ← span isDigit input → fmap (\n → (JNumber n, after)) (integer digits after)
  _ → Left ("unexpected text: " <> take 40 input)

-- JSON's integer grammar: no leading zero, and nothing this reader would have to round.
integer ∷ String → String → Either String Integer
integer digits after
  | length digits > 1 && take 1 digits == "0" = Left ("a number with a leading zero: " <> digits)
  | take 1 after `elem` [".", "e", "E"] = Left ("a number that is not an integer: " <> digits <> take 10 after)
  | otherwise = Right (read digits)

object ∷ String → [(String, Json)] → Either String (Json, String)
object input fields = case input of
  '}' : rest | null fields → Right (JObject [], rest)
  '"' : rest → do
    (key, afterKey) ← string rest ""
    if key `elem` map fst fields then Left ("an object that repeats the key " <> show key) else Right ()
    case skip afterKey of
      ':' : afterColon → do
        (item, afterValue) ← value (skip afterColon)
        let collected = fields <> [(key, item)]
        case skip afterValue of
          ',' : more → object (skip more) collected
          '}' : more → Right (JObject collected, more)
          other → Left ("expected , or } in an object: " <> take 40 other)
      other → Left ("expected : after a key: " <> take 40 other)
  other → Left ("expected a key: " <> take 40 other)

array ∷ String → [Json] → Either String (Json, String)
array input items = case input of
  ']' : rest | null items → Right (JArray [], rest)
  _ → do
    (item, afterValue) ← value input
    let collected = items <> [item]
    case skip afterValue of
      ',' : more → array (skip more) collected
      ']' : more → Right (JArray collected, more)
      other → Left ("expected , or ] in an array: " <> take 40 other)

string ∷ String → String → Either String (String, String)
string input acc = case input of
  '"' : rest → Right (reverse acc, rest)
  '\\' : escape : rest → case escape of
    '"' → string rest ('"' : acc)
    '\\' → string rest ('\\' : acc)
    '/' → string rest ('/' : acc)
    'n' → string rest ('\n' : acc)
    't' → string rest ('\t' : acc)
    'r' → string rest ('\r' : acc)
    'b' → string rest ('\b' : acc)
    'f' → string rest ('\f' : acc)
    'u' | (hex, after) ← splitAt 4 rest, length hex == 4, all isHexDigit hex, [(code, "")] ← readHex hex → string after (chr code : acc)
    _ → Left "an escape it cannot read"
  c : rest → string rest (c : acc)
  [] → Left "a string that does not close"
