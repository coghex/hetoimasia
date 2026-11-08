-- | A deterministic JSON writer for the generated manifest (TRA-14).
--
-- Only what the manifest needs: objects, arrays, ASCII strings and integers.
-- The layout is fixed so that regeneration is byte-stable and a changed entry
-- is one changed line: the top-level object and its arrays are spread over
-- lines, and every object inside an array is written inline on one line. There
-- is no timestamp, path of the generating machine or random value to render.
--
-- State, ownership and lifetime: none. Pure.
module Hetoimasia.Terrain.MapGen.Json
  ( Json (..)
  , renderJson
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.Char (isAscii, isControl, ord)
import Data.List (intercalate)
import Numeric (showHex)

data Json
  = JObject [(String, Json)]
  | JArray [Json]
  | JString String
  | JNumber Integer
  deriving stock (Eq, Show)

-- | The document, ending in one newline.
renderJson ∷ Json → ByteString
renderJson value = Char8.pack (block 0 value <> "\n")

pad ∷ Int → String
pad depth = replicate (2 * depth) ' '

block ∷ Int → Json → String
block depth (JObject fields)
  | null fields = "{}"
  | otherwise =
      "{\n"
        <> intercalate ",\n" [pad (depth + 1) <> quote key <> ": " <> block (depth + 1) v | (key, v) ← fields]
        <> "\n"
        <> pad depth
        <> "}"
block _ (JArray items)
  | all scalar items = inline (JArray items)
block depth (JArray items)
  | null items = "[]"
  | otherwise =
      "[\n"
        <> intercalate ",\n" [pad (depth + 1) <> inline item | item ← items]
        <> "\n"
        <> pad depth
        <> "]"
block _ other = inline other

scalar ∷ Json → Bool
scalar (JString _) = True
scalar (JNumber _) = True
scalar _ = False

inline ∷ Json → String
inline (JObject fields) = "{" <> intercalate ", " [quote key <> ": " <> inline v | (key, v) ← fields] <> "}"
inline (JArray items) = "[" <> intercalate ", " (map inline items) <> "]"
inline (JString s) = quote s
inline (JNumber n) = show n

quote ∷ String → String
quote s = "\"" <> concatMap escape s <> "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape c
      | isControl c || not (isAscii c) = "\\u" <> replicate (4 - length hex) '0' <> hex
      | otherwise = [c]
      where
        hex = showHex (ord c) ""
