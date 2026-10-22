-- | A strict, bounded JSON reader for one object, written for the manifest.
--
-- __Why hand-written.__ The manifest's profile is stricter than a general
-- JSON library offers: duplicate keys are refused after escape decoding and
-- before any map is built, nesting is bounded while parsing rather than after
-- a tree exists, a number is judged by its exact decimal value without ever
-- being converted to a binary float or an @Integer@ that grows with its
-- exponent, and each refusal is a bounded value naming where it happened. Those
-- are properties of the parser, not of something to be checked afterwards on a
-- tree already built, so the parser is this module's rather than a dependency's.
--
-- __Grammar.__ RFC 8259 with these refusals on top, checked in this order on
-- every document: well-formed UTF-8, no byte order mark, the grammar and the
-- nesting bound (at the first offending byte), duplicate decoded keys at every
-- object (the first object in document order that has one, then the first
-- repeated key in it), and trailing data. The root must be an object.
--
-- __Bounds.__ The caller bounds the byte count before calling; the nesting
-- bound is an argument and is enforced as containers open, so the recursion is
-- at most that deep. A number is kept as slices of the input and examined by
-- digit counts, so no work or allocation grows with an exponent's value; a
-- string's or array's size is bounded by the input's.
--
-- __State.__ The module owns none: it is pure over the supplied bytes.
module Hetoimasia.LuaEngine.Manifest.Json
  ( -- * Values
    JsonValue (..)
  , JsonNumber
  , numberIsOne
  , valueKind

    -- * Reading
  , parseJsonObject
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Unsafe as Unsafe
import Data.Char (chr)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Data.Word (Word8)
import Hetoimasia.LuaEngine.Manifest.Error
  ( FieldPath
  , PathSegment (..)
  , SyntaxError (..)
  , ValueKind (..)
  , excerptOf
  )

-- | A value of a document whose objects have no duplicate keys.
data JsonValue
  = JsonNull
  | JsonBool !Bool
  | JsonNumber !JsonNumber
  | JsonString !Text
  | JsonArray [JsonValue]
  | JsonObject !(Map Text JsonValue)
  deriving (Eq, Show)

-- | A number token of the grammar, kept as the slices of the input it was
-- written with. Its value is examined only through 'numberIsOne'.
data JsonNumber = JsonNumber'
  { numberNegative ∷ !Bool
  , numberInteger ∷ !ByteString
  , numberFraction ∷ !ByteString
  , numberExponentNegative ∷ !Bool
  , numberExponent ∷ !ByteString
  }
  deriving (Eq, Show)

-- | Whether the token's exact decimal value is 1: @1@, @1.0@, @1e0@, @10E-1@
-- and @0.1e1@ are, @1.00000000000000000001@ and @-1@ are not. The value is
-- never converted to a binary float or built as a power of ten; the token's
-- digits and the exponent's digit count decide it, so an exponent of any
-- length costs no more than reading it.
numberIsOne ∷ JsonNumber → Bool
numberIsOne number
  | numberNegative number = False
  | ByteString.filter (/= zero) digits /= ByteString.singleton one = False
  | otherwise = case exponentValue of
      Nothing → False
      Just power → power == leadingZeros + 1 - ByteString.length whole
  where
    zero = 0x30
    one = 0x31
    whole = numberInteger number
    digits = ByteString.append whole (numberFraction number)
    leadingZeros = ByteString.length (ByteString.takeWhile (== zero) digits)
    -- The exponent's value when it is small enough to matter: the value of 1
    -- needs an exponent no larger in magnitude than the token's length.
    exponentValue =
      let significant = ByteString.dropWhile (== zero) (numberExponent number)
       in if ByteString.length significant > 9
            then Nothing
            else
              let magnitude = ByteString.foldl' (\total digit → total * 10 + fromIntegral (digit - zero)) 0 significant
               in Just (if numberExponentNegative number then negate magnitude else magnitude)

-- | The kind of a value.
valueKind ∷ JsonValue → ValueKind
valueKind value = case value of
  JsonNull → KindNull
  JsonBool _ → KindBool
  JsonNumber _ → KindNumber
  JsonString _ → KindString
  JsonArray _ → KindArray
  JsonObject _ → KindObject

-- | A value before duplicate keys are looked for: objects keep their members in
-- document order.
data Raw
  = RawNull
  | RawBool !Bool
  | RawNumber !JsonNumber
  | RawString !Text
  | RawArray [Raw]
  | RawObject [(Text, Raw)]

-- | Read one document: an object, nested at most the given number of
-- containers deep (counting the outer object), with nothing after it but
-- whitespace.
parseJsonObject ∷ Int → ByteString → Either SyntaxError (Map Text JsonValue)
parseJsonObject maxDepth input
  | not (ByteString.isValidUtf8 input) = Left InvalidUtf8
  | ByteString.isPrefixOf byteOrderMark input = Left ByteOrderMark
  | otherwise = do
      let start = skipWhitespace input 0
      case peek input start of
        Nothing → Left (UnexpectedEnd start)
        Just 0x7B → Right ()
        Just _ → Left (RootNotObject start)
      (raw, end) ← parseValue input maxDepth 0 start
      checked ← checkDuplicates [] raw
      let rest = skipWhitespace input end
      if rest < ByteString.length input then Left (TrailingData rest) else Right ()
      case checked of
        JsonObject members → Right members
        _ → Left (RootNotObject start)
  where
    byteOrderMark = ByteString.pack [0xEF, 0xBB, 0xBF]

peek ∷ ByteString → Int → Maybe Word8
peek input index
  | index < ByteString.length input = Just (Unsafe.unsafeIndex input index)
  | otherwise = Nothing

-- | JSON's four whitespace bytes.
skipWhitespace ∷ ByteString → Int → Int
skipWhitespace input index = case peek input index of
  Just byte | byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D → skipWhitespace input (index + 1)
  _ → index

-- | The refusal for the byte at the index, which cannot continue the document.
unexpected ∷ ByteString → Int → SyntaxError
unexpected input index = case peek input index of
  Nothing → UnexpectedEnd index
  Just byte → UnexpectedByte index (fromIntegral byte)

-- | One value starting at or after the index, given how many containers are
-- already open. Returns the value and the index after it.
parseValue ∷ ByteString → Int → Int → Int → Either SyntaxError (Raw, Int)
parseValue input maxDepth depth from = case peek input index of
  Nothing → Left (UnexpectedEnd index)
  Just 0x7B → parseObject input maxDepth depth index
  Just 0x5B → parseArray input maxDepth depth index
  Just 0x22 → do
    (text, next) ← parseString input index
    Right (RawString text, next)
  Just 0x74 → literal "true" (RawBool True)
  Just 0x66 → literal "false" (RawBool False)
  Just 0x6E → literal "null" RawNull
  Just byte
    | byte == 0x2D || isDigit byte → do
        (number, next) ← parseNumber input index
        Right (RawNumber number, next)
  Just _ → Left (unexpected input index)
  where
    index = skipWhitespace input from
    literal word value =
      let expected = ByteString.pack (map (fromIntegral . fromEnum) word)
          common = length (takeWhile id (ByteString.zipWith (==) expected (ByteString.drop index input)))
       in if common == length word
            then Right (value, index + common)
            else Left (unexpected input (index + common))

isDigit ∷ Word8 → Bool
isDigit byte = byte >= 0x30 && byte <= 0x39

-- | An object whose opening brace is at the index.
parseObject ∷ ByteString → Int → Int → Int → Either SyntaxError (Raw, Int)
parseObject input maxDepth depth open
  | depth + 1 > maxDepth = Left (NestingTooDeep open)
  | otherwise = case peek input first of
      Nothing → Left (UnexpectedEnd first)
      Just 0x7D → Right (RawObject [], first + 1)
      Just _ → members first []
  where
    first = skipWhitespace input (open + 1)
    members from acc = do
      case peek input from of
        Just 0x22 → Right ()
        _ → Left (unexpected input from)
      (key, afterKey) ← parseString input from
      let colon = skipWhitespace input afterKey
      case peek input colon of
        Just 0x3A → Right ()
        _ → Left (unexpected input colon)
      (value, afterValue) ← parseValue input maxDepth (depth + 1) (colon + 1)
      let next = skipWhitespace input afterValue
          acc' = (key, value) : acc
      case peek input next of
        Just 0x2C → members (skipWhitespace input (next + 1)) acc'
        Just 0x7D → Right (RawObject (reverse acc'), next + 1)
        _ → Left (unexpected input next)

-- | An array whose opening bracket is at the index.
parseArray ∷ ByteString → Int → Int → Int → Either SyntaxError (Raw, Int)
parseArray input maxDepth depth open
  | depth + 1 > maxDepth = Left (NestingTooDeep open)
  | otherwise = case peek input first of
      Nothing → Left (UnexpectedEnd first)
      Just 0x5D → Right (RawArray [], first + 1)
      Just _ → elements first []
  where
    first = skipWhitespace input (open + 1)
    elements from acc = do
      (value, afterValue) ← parseValue input maxDepth (depth + 1) from
      let next = skipWhitespace input afterValue
          acc' = value : acc
      case peek input next of
        Just 0x2C → elements (skipWhitespace input (next + 1)) acc'
        Just 0x5D → Right (RawArray (reverse acc'), next + 1)
        _ → Left (unexpected input next)

-- | A number token starting at the index (a minus sign or a digit).
parseNumber ∷ ByteString → Int → Either SyntaxError (JsonNumber, Int)
parseNumber input start = do
  let negative = peek input start == Just 0x2D
      integerStart = if negative then start + 1 else start
  integerEnd ← case peek input integerStart of
    Just 0x30
      | maybe False isDigit (peek input (integerStart + 1)) → Left (InvalidNumber (integerStart + 1))
      | otherwise → Right (integerStart + 1)
    Just byte | isDigit byte → Right (digitsEnd integerStart)
    _ → Left (numberFault integerStart)
  (fraction, fractionEnd) ←
    if peek input integerEnd == Just 0x2E
      then do
        let from = integerEnd + 1
            to = digitsEnd from
        if to == from then Left (numberFault from) else Right (slice from to, to)
      else Right (ByteString.empty, integerEnd)
  (exponentNegative, exponentDigits, end) ←
    if peek input fractionEnd == Just 0x65 || peek input fractionEnd == Just 0x45
      then do
        let signed = peek input (fractionEnd + 1)
            exponentNegative = signed == Just 0x2D
            from = if signed == Just 0x2D || signed == Just 0x2B then fractionEnd + 2 else fractionEnd + 1
            to = digitsEnd from
        if to == from then Left (numberFault from) else Right (exponentNegative, slice from to, to)
      else Right (False, ByteString.empty, fractionEnd)
  Right
    ( JsonNumber'
        { numberNegative = negative
        , numberInteger = slice integerStart integerEnd
        , numberFraction = fraction
        , numberExponentNegative = exponentNegative
        , numberExponent = exponentDigits
        }
    , end
    )
  where
    slice from to = ByteString.take (to - from) (ByteString.drop from input)
    digitsEnd from = case peek input from of
      Just byte | isDigit byte → digitsEnd (from + 1)
      _ → from
    numberFault index = case peek input index of
      Nothing → UnexpectedEnd index
      Just _ → InvalidNumber index

-- | A string whose opening quote is at the index; the decoded text and the
-- index after the closing quote.
parseString ∷ ByteString → Int → Either SyntaxError (Text, Int)
parseString input open = scan (open + 1) (open + 1) []
  where
    -- @from@ starts the run of bytes not yet decoded, @at@ is the byte under
    -- examination and @done@ holds the finished pieces, latest first.
    scan from at done = case peek input at of
      Nothing → Left (UnexpectedEnd at)
      Just 0x22 → do
        run ← decodeRun from at
        Right (Text.concat (reverse (run : done)), at + 1)
      Just 0x5C → do
        run ← decodeRun from at
        (character, next) ← parseEscape input at
        scan next next (Text.singleton character : run : done)
      Just byte
        | byte < 0x20 → Left (ControlCharacter at)
        | otherwise → scan from (at + 1) done
    -- The whole document was validated as UTF-8 and runs end at ASCII bytes,
    -- so a run is well-formed; the refusal is the one honest total answer.
    decodeRun from to =
      either (const (Left InvalidUtf8)) Right $
        Encoding.decodeUtf8' (ByteString.take (to - from) (ByteString.drop from input))

-- | The escape whose backslash is at the index: the character it stands for and
-- the index after it. A high surrogate must be followed by a low one.
parseEscape ∷ ByteString → Int → Either SyntaxError (Char, Int)
parseEscape input slash = case peek input (slash + 1) of
  Nothing → Left (UnexpectedEnd (slash + 1))
  Just 0x22 → simple '"'
  Just 0x5C → simple '\\'
  Just 0x2F → simple '/'
  Just 0x62 → simple '\b'
  Just 0x66 → simple '\f'
  Just 0x6E → simple '\n'
  Just 0x72 → simple '\r'
  Just 0x74 → simple '\t'
  Just 0x75 → do
    unit ← hexUnit (slash + 2)
    if unit >= 0xD800 && unit <= 0xDBFF
      then case peek input (slash + 6) of
        Nothing → Left (UnexpectedEnd (slash + 6))
        Just 0x5C | peek input (slash + 7) == Just 0x75 → do
          low ← hexUnit (slash + 8)
          if low >= 0xDC00 && low <= 0xDFFF
            then Right (chr (0x10000 + ((unit - 0xD800) `shiftL` 10) + (low - 0xDC00)), slash + 12)
            else Left (UnpairedSurrogate slash)
        Just _ → Left (UnpairedSurrogate slash)
      else
        if unit >= 0xDC00 && unit <= 0xDFFF
          then Left (UnpairedSurrogate slash)
          else Right (chr unit, slash + 6)
  Just _ → Left (InvalidEscape slash)
  where
    simple character = Right (character, slash + 2)
    -- Four hexadecimal digits, the first at the index.
    hexUnit from = go from (0 ∷ Int) (0 ∷ Int)
      where
        go at count total
          | count == 4 = Right total
          | otherwise = case peek input at of
              Nothing → Left (UnexpectedEnd at)
              Just byte → case hexValue byte of
                Just value → go (at + 1) (count + 1) ((total `shiftL` 4) .|. value)
                Nothing → Left (InvalidEscape slash)
    hexValue byte
      | byte >= 0x30 && byte <= 0x39 = Just (fromIntegral byte - 0x30)
      | byte >= 0x41 && byte <= 0x46 = Just (fromIntegral byte - 0x41 + 10)
      | byte >= 0x61 && byte <= 0x66 = Just (fromIntegral byte - 0x61 + 10)
      | otherwise = Nothing

-- | Look for a repeated decoded key at every object, in document order, before
-- any object is collapsed into a map: an object is checked as a whole first,
-- then its members in order.
checkDuplicates ∷ FieldPath → Raw → Either SyntaxError JsonValue
checkDuplicates path raw = case raw of
  RawNull → Right JsonNull
  RawBool flag → Right (JsonBool flag)
  RawNumber number → Right (JsonNumber number)
  RawString text → Right (JsonString text)
  RawArray elements →
    JsonArray <$> traverse (\(index, element) → checkDuplicates (path ++ [PathIndex index]) element) (zip [0 ..] elements)
  RawObject members → do
    firstRepeat Map.empty members
    converted ← traverse (\(key, value) → (,) key <$> checkDuplicates (path ++ [PathKey (excerptOf key)]) value) members
    Right (JsonObject (Map.fromList converted))
  where
    firstRepeat _ [] = Right ()
    firstRepeat seen ((key, _) : rest)
      | Map.member key seen = Left (DuplicateKey path (excerptOf key))
      | otherwise = firstRepeat (Map.insert key () seen) rest
