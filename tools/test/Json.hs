-- | A minimal JSON reader for asserting on tool output.
--
-- The validation planner's @--json@ plan is a stable contract consumed by later
-- CI work, so the workflow tests assert against that structure rather than the
-- prose rendering. Only the value forms the planner emits are supported; this
-- is a test helper, not a general JSON library.
module Json
  ( Json (..)
  , parseJson
  , field
  , asArray
  , asBool
  , asString
  , entryFor
  ) where

import Data.Char (chr, isDigit, isHexDigit, isSpace)
import Data.List (find)
import Numeric (readHex)

data Json
  = JNull
  | JBool Bool
  | JNumber Double
  | JString String
  | JArray [Json]
  | JObject [(String, Json)]
  deriving (Eq, Show)

parseJson ∷ String → Maybe Json
parseJson text = case value (skip text) of
  Just (result, rest) | all isSpace rest → Just result
  _ → Nothing

skip ∷ String → String
skip = dropWhile isSpace

value ∷ String → Maybe (Json, String)
value input = case input of
  ('n' : 'u' : 'l' : 'l' : rest) → Just (JNull, rest)
  ('t' : 'r' : 'u' : 'e' : rest) → Just (JBool True, rest)
  ('f' : 'a' : 'l' : 's' : 'e' : rest) → Just (JBool False, rest)
  ('"' : rest) → do
    (text, remaining) ← string rest ""
    pure (JString text, remaining)
  ('[' : rest) → array (skip rest) []
  ('{' : rest) → object (skip rest) []
  _ → number input

string ∷ String → String → Maybe (String, String)
string input acc = case input of
  [] → Nothing
  ('"' : rest) → Just (reverse acc, rest)
  ('\\' : 'u' : a : b : c : d : rest)
    | all isHexDigit [a, b, c, d]
    , [(code, "")] ← readHex [a, b, c, d] → string rest (chr code : acc)
  ('\\' : escape : rest) → do
    decoded ← lookup escape [('"', '"'), ('\\', '\\'), ('/', '/'), ('n', '\n'), ('t', '\t'), ('r', '\r'), ('b', '\b'), ('f', '\f')]
    string rest (decoded : acc)
  (character : rest) → string rest (character : acc)

array ∷ String → [Json] → Maybe (Json, String)
array input acc = case input of
  (']' : rest) → Just (JArray (reverse acc), rest)
  _ → do
    (element, rest) ← value input
    case skip rest of
      (',' : more) → array (skip more) (element : acc)
      (']' : more) → Just (JArray (reverse (element : acc)), more)
      _ → Nothing

object ∷ String → [(String, Json)] → Maybe (Json, String)
object input acc = case input of
  ('}' : rest) → Just (JObject (reverse acc), rest)
  ('"' : rest) → do
    (key, afterKey) ← string rest ""
    case skip afterKey of
      (':' : afterColon) → do
        (element, rest') ← value (skip afterColon)
        case skip rest' of
          (',' : more) → object (skip more) ((key, element) : acc)
          ('}' : more) → Just (JObject (reverse ((key, element) : acc)), more)
          _ → Nothing
      _ → Nothing
  _ → Nothing

number ∷ String → Maybe (Json, String)
number input =
  let (digits, rest) = span (\character → isDigit character || character `elem` ("-+.eE" ∷ String)) input
   in case reads digits ∷ [(Double, String)] of
        [(parsed, "")] → Just (JNumber parsed, rest)
        _ → Nothing

field ∷ String → Json → Maybe Json
field name (JObject pairs) = lookup name pairs
field _ _ = Nothing

asArray ∷ Json → Maybe [Json]
asArray (JArray elements) = Just elements
asArray _ = Nothing

asBool ∷ Json → Maybe Bool
asBool (JBool flag) = Just flag
asBool _ = Nothing

asString ∷ Json → Maybe String
asString (JString text) = Just text
asString _ = Nothing

-- | The element of an array of objects whose @key@ field equals @wanted@.
entryFor ∷ String → String → Json → Maybe Json
entryFor key wanted document = do
  elements ← asArray document
  find (\element → (field key element >>= asString) == Just wanted) elements
