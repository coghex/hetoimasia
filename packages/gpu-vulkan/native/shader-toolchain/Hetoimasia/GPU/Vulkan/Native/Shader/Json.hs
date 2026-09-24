-- | Just enough JSON to read the native manifest's glslang record.
--
-- The manifest is written by @tools/native/vulkan.py@ with @json.dump@, so it
-- is ordinary JSON. This reads the whole grammar, because a reader that
-- skipped what it did not understand could read a different record from the
-- one the file holds, but it keeps numbers as their source text: nothing here
-- does arithmetic, and the only numeric field in the glslang record is a file
-- mode this package does not consult.
module Hetoimasia.GPU.Vulkan.Native.Shader.Json
  ( Value (..)
  , parseJson
  , member
  , stringMember
  ) where

import Data.Char (chr, isDigit, isHexDigit, isSpace)
import Numeric (readHex)

-- | A JSON value.
data Value
  = Object [(String, Value)]
  | Array [Value]
  | String String
  | Number String
  | Bool Bool
  | Null
  deriving (Eq, Show)

-- | Parse one complete JSON document, or say where it stopped making sense.
parseJson ∷ String → Either String Value
parseJson input = case value (skip input) of
  Left problem → Left problem
  Right (parsed, rest)
    | all isSpace rest → Right parsed
    | otherwise → Left ("unexpected text after the document: " <> take 20 rest)

-- | A member of an object, by name.
member ∷ String → Value → Maybe Value
member name (Object members) = lookup name members
member _ _ = Nothing

-- | A string member of an object, by name.
stringMember ∷ String → Value → Maybe String
stringMember name document = case member name document of
  Just (String text) → Just text
  _ → Nothing

type Parser a = String → Either String (a, String)

skip ∷ String → String
skip = dropWhile isSpace

value ∷ Parser Value
value input = case input of
  '{' : rest → object (skip rest)
  '[' : rest → array (skip rest)
  '"' : rest → fmap (\(text, remaining) → (String text, remaining)) (string rest)
  't' : 'r' : 'u' : 'e' : rest → Right (Bool True, rest)
  'f' : 'a' : 'l' : 's' : 'e' : rest → Right (Bool False, rest)
  'n' : 'u' : 'l' : 'l' : rest → Right (Null, rest)
  c : _ | c == '-' || isDigit c → number input
  _ → Left ("expected a value at: " <> take 20 input)

object ∷ Parser Value
object ('}' : rest) = Right (Object [], rest)
object input = go [] input
  where
    go members ('"' : rest) = do
      (name, afterName) ← string rest
      case skip afterName of
        ':' : afterColon → do
          (item, afterItem) ← value (skip afterColon)
          case skip afterItem of
            ',' : more → go ((name, item) : members) (skip more)
            '}' : more → Right (Object (reverse ((name, item) : members)), more)
            other → Left ("expected ',' or '}' in an object at: " <> take 20 other)
        other → Left ("expected ':' after a member name at: " <> take 20 other)
    go _ other = Left ("expected a member name at: " <> take 20 other)

array ∷ Parser Value
array (']' : rest) = Right (Array [], rest)
array input = go [] input
  where
    go items remaining = do
      (item, afterItem) ← value (skip remaining)
      case skip afterItem of
        ',' : more → go (item : items) more
        ']' : more → Right (Array (reverse (item : items)), more)
        other → Left ("expected ',' or ']' in an array at: " <> take 20 other)

string ∷ Parser String
string = go []
  where
    go acc input = case input of
      '"' : rest → Right (reverse acc, rest)
      '\\' : escaped : rest → case escaped of
        '"' → go ('"' : acc) rest
        '\\' → go ('\\' : acc) rest
        '/' → go ('/' : acc) rest
        'b' → go ('\b' : acc) rest
        'f' → go ('\f' : acc) rest
        'n' → go ('\n' : acc) rest
        'r' → go ('\r' : acc) rest
        't' → go ('\t' : acc) rest
        'u' → case splitAt 4 rest of
          (digits, more) | length digits == 4, all isHexDigit digits, [(code, "")] ← readHex digits →
            go (chr code : acc) more
          _ → Left "a \\u escape needs four hexadecimal digits"
        other → Left ("unknown escape \\" <> [other])
      c : rest → go (c : acc) rest
      [] → Left "unterminated string"

number ∷ Parser Value
number input =
  let (text, rest) = span (\c → isDigit c || c `elem` ("+-.eE" ∷ String)) input
   in if any isDigit text then Right (Number text, rest) else Left ("malformed number at: " <> take 20 input)
