-- | A bounded reader for the atlas manifest's JSON subset (TRA-17).
--
-- The manifest is ASCII text of objects, arrays, strings and integers, which is all this reads.
-- Three bounds are checked before anything is built, so no input makes the reader do more than
-- a fixed amount of work: the byte length, the nesting depth and the number of values. Floats,
-- booleans, null and non-ASCII bytes are refusals, never approximations.
--
-- State, ownership and lifetime: none. Pure.
module Hetoimasia.Terrain.Atlas.Internal.Json
  ( JsonValue (..)
  , JsonLimits (..)
  , parseJsonBounded
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.Char (chr, isDigit, isHexDigit, isSpace)
import Numeric (readHex)

-- | A parsed value.
data JsonValue
  = JsonObject [(String, JsonValue)]
  | JsonArray [JsonValue]
  | JsonString String
  | JsonInteger Integer
  deriving stock (Eq, Show)

-- | What an input may cost.
data JsonLimits = JsonLimits
  { limitBytes ∷ !Int
  , limitDepth ∷ !Int
  , limitValues ∷ !Int
  }
  deriving stock (Eq, Show)

-- The remaining text and the number of values still allowed.
data St = St String !Int

type P a = St → Int → Either String (a, St)

-- | The value a document holds, or why it is refused.
parseJsonBounded ∷ JsonLimits → ByteString → Either String JsonValue
parseJsonBounded limits bytes
  | ByteString.length bytes > limitBytes limits = Left ("the document is longer than " <> show (limitBytes limits) <> " bytes")
  | ByteString.any (>= 128) bytes = Left "the document is not ASCII"
  | otherwise = do
      (parsed, St rest _) ← value (St (Char8.unpack bytes) (limitValues limits)) (limitDepth limits)
      case dropWhile isSpace rest of
        [] → Right parsed
        _ → Left "text follows the document"

spaces ∷ St → St
spaces (St s n) = St (dropWhile isSpace s) n

spend ∷ St → Either String St
spend (St s n)
  | n <= 0 = Left "the document holds too many values"
  | otherwise = Right (St s (n - 1))

value ∷ P JsonValue
value st0 depth = do
  st1 ← spend (spaces st0)
  let St s n = st1
  case s of
    '{' : rest
      | depth <= 0 → Left "the document nests too deeply"
      | otherwise → object (St rest n) (depth - 1)
    '[' : rest
      | depth <= 0 → Left "the document nests too deeply"
      | otherwise → array (St rest n) (depth - 1)
    '"' : rest → do
      (text, st) ← string (St rest n)
      Right (JsonString text, st)
    c : _ | c == '-' || isDigit c → integer st1
    c : _ → Left ("unexpected " <> show c)
    [] → Left "the document ends early"

integer ∷ St → Either String (JsonValue, St)
integer (St s n) =
  let (sign, rest) = case s of
        '-' : r → (-1, r)
        _ → (1, s)
      (digits, after) = span isDigit rest
   in case (digits, after) of
        ([], _) → Left "a number needs digits"
        (_, c : _) | c == '.' || c == 'e' || c == 'E' → Left "only integers are allowed"
        ('0' : _ : _, _) → Left "a number has a leading zero"
        _ | length digits > 18 → Left "an integer is too long"
        _ → Right (JsonInteger (sign * read digits), St after n)

string ∷ St → Either String (String, St)
string (St s0 n) = go s0 []
  where
    go [] _ = Left "a string is not closed"
    go ('"' : rest) acc = Right (reverse acc, St rest n)
    go ('\\' : rest) acc = case rest of
      '"' : r → go r ('"' : acc)
      '\\' : r → go r ('\\' : acc)
      '/' : r → go r ('/' : acc)
      'n' : r → go r ('\n' : acc)
      't' : r → go r ('\t' : acc)
      'u' : a : b : c : d : r
        | all isHexDigit [a, b, c, d], [(code, "")] ← readHex [a, b, c, d] → go r (chr code : acc)
      _ → Left "a string has an unknown escape"
    go (c : rest) acc
      | c < ' ' = Left "a string holds a control character"
      | otherwise = go rest (c : acc)

array ∷ St → Int → Either String (JsonValue, St)
array st0 depth = case spaces st0 of
  St (']' : rest) n → Right (JsonArray [], St rest n)
  st → items st []
  where
    items st acc = do
      (item, st1) ← value st depth
      case spaces st1 of
        St (',' : rest) n → items (St rest n) (item : acc)
        St (']' : rest) n → Right (JsonArray (reverse (item : acc)), St rest n)
        _ → Left "an array needs a comma or a closing bracket"

object ∷ St → Int → Either String (JsonValue, St)
object st0 depth = case spaces st0 of
  St ('}' : rest) n → Right (JsonObject [], St rest n)
  st → members st []
  where
    members st acc = do
      let St s n = spaces st
      case s of
        '"' : rest → do
          (key, St afterKey m) ← string (St rest n)
          case dropWhile isSpace afterKey of
            ':' : afterColon → do
              (item, st1) ← value (St afterColon m) depth
              case spaces st1 of
                St (',' : rest') k → members (St rest' k) ((key, item) : acc)
                St ('}' : rest') k → Right (JsonObject (reverse ((key, item) : acc)), St rest' k)
                _ → Left "an object needs a comma or a closing brace"
            _ → Left "an object key needs a colon"
        _ → Left "an object needs a quoted key"
