-- | A small JSON reader and writer for the native suite's own records and the X11 helper's one-object answers.
--
-- The suite adds no JSON dependency for a handful of flat records. The reader accepts the whole of JSON as
-- the helper prints it (objects, arrays, strings with the usual escapes, numbers, booleans, null) and refuses
-- anything else, with the offset; the writer escapes strings and sorts nothing (callers give the order).
module Test.Run.Native.Json
  ( Json (..)
  , parseJson
  , render
  , field
  , asInt
  , asText
  , asBool
  , asArray
  , asObject
  ) where

import Data.Char (chr, isDigit, isHexDigit, isSpace, ord)
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as Text
import Numeric (readHex, showHex)

data Json
  = JNull
  | JBool !Bool
  | JNumber !Integer
  | JString !Text
  | JArray ![Json]
  | JObject ![(Text, Json)]
  deriving (Eq, Show)

field ∷ Text → Json → Maybe Json
field name = \case
  JObject pairs → lookup name pairs
  _ → Nothing

asInt ∷ Json → Maybe Int
asInt = \case
  JNumber n → Just (fromInteger n)
  _ → Nothing

asText ∷ Json → Maybe Text
asText = \case
  JString t → Just t
  _ → Nothing

asBool ∷ Json → Maybe Bool
asBool = \case
  JBool b → Just b
  _ → Nothing

asArray ∷ Json → Maybe [Json]
asArray = \case
  JArray items → Just items
  _ → Nothing

asObject ∷ Json → Maybe [(Text, Json)]
asObject = \case
  JObject pairs → Just pairs
  _ → Nothing

-- | Parse one JSON value spanning the whole input.
parseJson ∷ String → Either String Json
parseJson input = case value (skip input) of
  Left failure → Left failure
  Right (result, rest) → case skip rest of
    [] → Right result
    remaining → Left ("trailing input at offset " <> show (length input - length remaining))
  where
    skip = dropWhile isSpace
    offset rest = length input - length rest

    value ∷ String → Either String (Json, String)
    value = \case
      'n' : 'u' : 'l' : 'l' : rest → Right (JNull, rest)
      't' : 'r' : 'u' : 'e' : rest → Right (JBool True, rest)
      'f' : 'a' : 'l' : 's' : 'e' : rest → Right (JBool False, rest)
      '"' : rest → do
        (text, remaining) ← string rest
        Right (JString (Text.pack text), remaining)
      '[' : rest → array (skip rest) []
      '{' : rest → object (skip rest) []
      text@(c : _)
        | c == '-' || isDigit c → number text
      rest → Left ("unexpected input at offset " <> show (offset rest))

    number text =
      let (sign, afterSign) = case text of '-' : more → (-1, more); _ → (1, text)
          (digits, rest) = span isDigit afterSign
       in if null digits || take 1 rest `elem` [".", "e", "E"]
            then Left ("a number this reader does not take at offset " <> show (offset text))
            else Right (JNumber (sign * read digits), rest)

    array rest acc = case rest of
      ']' : more | null acc → Right (JArray [], more)
      _ → do
        (item, afterItem) ← value (skip rest)
        case skip afterItem of
          ',' : more → array (skip more) (item : acc)
          ']' : more → Right (JArray (reverse (item : acc)), more)
          other → Left ("expected , or ] at offset " <> show (offset other))

    object rest acc = case rest of
      '}' : more | null acc → Right (JObject [], more)
      '"' : afterQuote → do
        (name, afterName) ← string afterQuote
        case skip afterName of
          ':' : afterColon → do
            (item, afterItem) ← value (skip afterColon)
            let entry = (Text.pack name, item)
            case skip afterItem of
              ',' : more → object (skip more) (entry : acc)
              '}' : more → Right (JObject (reverse (entry : acc)), more)
              other → Left ("expected , or } at offset " <> show (offset other))
          other → Left ("expected : at offset " <> show (offset other))
      other → Left ("expected a name at offset " <> show (offset other))

    string = go []
      where
        go acc = \case
          '"' : rest → Right (reverse acc, rest)
          '\\' : escaped : rest → case escaped of
            'n' → go ('\n' : acc) rest
            't' → go ('\t' : acc) rest
            'r' → go ('\r' : acc) rest
            'b' → go ('\b' : acc) rest
            'f' → go ('\f' : acc) rest
            '/' → go ('/' : acc) rest
            '\\' → go ('\\' : acc) rest
            '"' → go ('"' : acc) rest
            'u' | (hex, more) ← splitAt 4 rest, length hex == 4, all isHexDigit hex, [(code, "")] ← readHex hex → go (chr code : acc) more
            _ → Left ("a bad escape at offset " <> show (offset rest))
          c : rest → go (c : acc) rest
          [] → Left "an unterminated string"

-- | Render compactly.
render ∷ Json → String
render = \case
  JNull → "null"
  JBool b → if b then "true" else "false"
  JNumber n → show n
  JString t → quote (Text.unpack t)
  JArray items → "[" <> intercalate "," (map render items) <> "]"
  JObject pairs → "{" <> intercalate "," [quote (Text.unpack k) <> ":" <> render v | (k, v) ← pairs] <> "}"
  where
    quote text = "\"" <> concatMap escape text <> "\""
    escape = \case
      '"' → "\\\""
      '\\' → "\\\\"
      '\n' → "\\n"
      '\r' → "\\r"
      '\t' → "\\t"
      c | ord c < 0x20 → "\\u" <> replicate (4 - length (showHex (ord c) "")) '0' <> showHex (ord c) ""
      c → [c]
