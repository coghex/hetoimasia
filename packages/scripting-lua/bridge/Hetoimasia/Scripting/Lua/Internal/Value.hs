-- | The values that cross between Lua and Haskell, the schemas they are checked
-- against, and the bounds on both.
--
-- Nothing here touches Lua. A value that crosses is a /bounded copy/: Lua's
-- side reads it into the byte encoding the C layer defines
-- ("Hetoimasia.Scripting.Lua.Internal.Marshal"), stopping at the limits, and
-- this module decodes that encoding and checks it against a 'Schema'. In the
-- other direction a Haskell 'Value' is checked against its schema and encoded
-- under the same limits, then built in Lua by the C layer. So the limits, the
-- schema rules and the typed reasons for refusing a value live in one place and
-- are testable without an interpreter.
--
-- = What a value is
--
-- Nil, booleans, 64-bit integers, floats, byte strings, UTF-8 text, lists,
-- records, and capabilities. Integers keep their exact value over the whole
-- 64-bit range and floats stay floats: no conversion changes the number's
-- subtype, so an integral float is refused where an integer is declared, and an
-- integer where a float is. 'SNumber' is the schema that accepts either and keeps
-- which it was. Byte strings and text are distinct: Lua has one string type, and
-- the schema says whether a string is read as bytes or as text, in which case
-- invalid UTF-8 is refused.
--
-- A list is a table whose keys are exactly @1..n@, and a record is a table whose
-- keys are exactly the declared field names (an optional field may be absent).
-- Anything else in a table is refused. A table that carries a metatable is
-- refused as well, so a copy never depends on a metamethod and none is ever
-- consulted. Cycles, functions, coroutines, light userdata and foreign
-- userdata are refused with a typed reason.
--
-- A capability is an opaque application identity -- a type the application
-- declared and a key within it -- that a VM issued to its own scripts. It is
-- checked at every use for the VM that issued it, its type, and, by the
-- application, that it is still live.
--
-- = The limits
--
-- A crossing is bounded by bytes, depth and elements. Bytes are the size of the
-- copy's encoding: 1 for nil and booleans, 9 for a number, 5 and the length for
-- a string, 21 for a capability, and for a table 5 and the size of each key and
-- value. Depth is how deeply tables nest (a flat table is 1). Elements are the
-- values of the copy, nested ones included and table keys not. The limits
-- apply to everything a crossing carries together, and the reader stops at the
-- first one it reaches, so the work it does is bounded by them and not by the
-- input.
module Hetoimasia.Scripting.Lua.Internal.Value
  ( -- * Values
    Value (..)
  , Capability (..)
  , VmIdentity (..)
    -- * Schemas
  , Schema (..)
  , schemaDepth
  , schemaFieldCount
  , schemaCapabilities
  , schemaDuplicateField
    -- * Limits
  , ValueLimits (..)
  , defaultValueLimits
  , valueLimitMaxima
  , valueLimits
  , LimitsRefusal (..)
    -- * Why a value is refused
  , Side (..)
  , PathStep (..)
  , ValueRule (..)
  , ValueRefusal (..)
    -- * The wire form
  , RawValue (..)
  , RawKey (..)
  , decodeValues
  , Context (..)
  , conformRaw
  , conformValue
  , encodeValues
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.Int (Int64)
import Data.List (nub, sortOn)
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Data.Word (Word32, Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)

-- | A VM, as its identity: a number no other VM in the process shares.
newtype VmIdentity = VmIdentity Word64
  deriving (Eq, Ord, Show)

-- | An application capability: the type the application declared for it, its
-- key within that type, and the VM that issued it.
--
-- The issuer is 'Nothing' for a capability an application has just made, which
-- the VM stamps with its own identity when it hands the capability to Lua, and
-- the issuing VM for one read back from Lua. A capability issued by one VM is
-- refused when it is given to another.
data Capability = Capability
  { capabilityTypeName ∷ !Text
  , capabilityKey ∷ !Word64
  , capabilityIssuer ∷ !(Maybe VmIdentity)
  }
  deriving (Eq, Show)

-- | A bounded copy of a Lua value, as Haskell holds it.
data Value
  = VNil
  | VBoolean !Bool
  | VInteger !Int64
  | VFloat !Double
  | -- | A byte string.
    VBytes !ByteString
  | -- | UTF-8 text.
    VText !Text
  | -- | A sequence.
    VList ![Value]
  | -- | A record: field names and their values.
    VRecord ![(Text, Value)]
  | VCapability !Capability
  deriving (Eq, Show)

-- | What a value is declared to be.
data Schema
  = SNil
  | SBoolean
  | -- | A 64-bit integer. A float is refused, an integral one included.
    SInteger
  | -- | A float. An integer is refused.
    SFloat
  | -- | An integer or a float, whichever it was.
    SNumber
  | SBytes
  | SText
  | -- | A sequence of values of one schema.
    SList Schema
  | -- | A record: exactly these fields, an 'SOptional' one possibly absent.
    SRecord [(Text, Schema)]
  | -- | Nil, or a value of the schema.
    SOptional Schema
  | -- | A capability of the application type of this name.
    SCapability Text
  deriving (Eq, Show)

-- | How deeply a schema nests: a scalar is 0.
schemaDepth ∷ Schema → Int
schemaDepth = \case
  SList inner → 1 + schemaDepth inner
  SRecord fields → 1 + maximum (0 : map (schemaDepth . snd) fields)
  SOptional inner → schemaDepth inner
  _ → 0

-- | The most fields any record in the schema declares.
schemaFieldCount ∷ Schema → Int
schemaFieldCount = \case
  SList inner → schemaFieldCount inner
  SRecord fields → maximum (length fields : map (schemaFieldCount . snd) fields)
  SOptional inner → schemaFieldCount inner
  _ → 0

-- | The capability types the schema names.
schemaCapabilities ∷ Schema → [Text]
schemaCapabilities = \case
  SCapability name → [name]
  SList inner → schemaCapabilities inner
  SRecord fields → concatMap (schemaCapabilities . snd) fields
  SOptional inner → schemaCapabilities inner
  _ → []

-- | A field name some record in the schema declares twice.
schemaDuplicateField ∷ Schema → Maybe Text
schemaDuplicateField = \case
  SList inner → schemaDuplicateField inner
  SOptional inner → schemaDuplicateField inner
  SRecord fields →
    let names = map fst fields
     in case [name | name ← nub names, length (filter (== name) names) > 1] of
          name : _ → Just name
          [] → case [found | Just found ← map (schemaDuplicateField . snd) fields] of
            found : _ → Just found
            [] → Nothing
  _ → Nothing

-- | The bounds on one crossing: its bytes, its depth and its elements.
data ValueLimits = ValueLimits
  { limitBytes ∷ !Int
  , limitDepth ∷ !Int
  , limitElements ∷ !Int
  }
  deriving (Eq, Show)

-- | 64 KiB, depth 8, 4096 elements.
defaultValueLimits ∷ ValueLimits
defaultValueLimits = ValueLimits 65536 8 4096

-- | The most any limit may be configured to: 16 MiB, depth 64, 2²⁰ elements.
valueLimitMaxima ∷ ValueLimits
valueLimitMaxima = ValueLimits 16777216 64 1048576

-- | Why a limit configuration was refused.
data LimitsRefusal
  = -- | The named limit is below its minimum, 1.
    LimitTooSmall !Text !Int
  | -- | The named limit is above its maximum, which is given.
    LimitTooLarge !Text !Int !Int
  deriving (Eq, Show)

-- | A limit configuration, each limit from 1 to its maximum.
valueLimits ∷ Int → Int → Int → Either LimitsRefusal ValueLimits
valueLimits bytes depth elements = do
  checked "bytes" (limitBytes valueLimitMaxima) bytes
  checked "depth" (limitDepth valueLimitMaxima) depth
  checked "elements" (limitElements valueLimitMaxima) elements
  pure (ValueLimits bytes depth elements)
  where
    checked name maximal value
      | value < 1 = Left (LimitTooSmall name value)
      | value > maximal = Left (LimitTooLarge name value maximal)
      | otherwise = Right ()

-- | Which side of a crossing a refusal concerns.
data Side = Arguments | Results
  deriving (Eq, Show)

-- | One step into a value.
data PathStep
  = -- | The 1-based position in a list.
    AtIndex !Int
  | AtField !Text
  deriving (Eq, Show)

-- | The rule a value broke.
data ValueRule
  = -- | The copy would pass the byte limit.
    RuleBytesLimit !Int
  | RuleDepthLimit !Int
  | RuleElementLimit !Int
  | -- | A table contains itself.
    RuleCycle
  | -- | A function, a coroutine, a light userdata or a userdata that is not a
    -- capability: its Lua type name.
    RuleUnsupportedType !Text
  | -- | A table carries a metatable.
    RuleMetatable
  | -- | A table key is neither an integer nor a string.
    RuleKeyType
  | -- | Working stack for the copy could not be reserved.
    RuleStack
  | -- | Memory for the copy could not be had.
    RuleMemory
  | -- | A value of the wrong kind: what was declared, what was found.
    RuleWrongType !Text !Text
  | -- | A float where an integer is declared, integral or not.
    RuleFloatForInteger
  | RuleInvalidUtf8
  | -- | A list was declared and the table's keys are not exactly @1..n@.
    RuleNotASequence
  | -- | A record was declared and the table has a key that is not a string.
    RuleNotARecord
  | RuleUnknownField !Text
  | RuleMissingField !Text
  | -- | A record names a field twice.
    RuleDuplicateField !Text
  | -- | The wrong number of values: declared, found.
    RuleArity !Int !Int
  | -- | A capability another VM issued.
    RuleForeignHandle
  | -- | A capability of another type: declared, found.
    RuleHandleType !Text !Text
  | -- | The application's own check refused a capability: it is retired.
    RuleRetiredHandle !Text
  | -- | A capability of a type the registration does not declare.
    RuleUnknownCapability !Text
  deriving (Eq, Show)

-- | A value refused at the boundary: which side, which value of it, where in
-- that value, the rule, and how many values had been visited when it was
-- refused (which the element limit bounds by itself plus one).
data ValueRefusal = ValueRefusal
  { refusalSide ∷ !Side
  , refusalIndex ∷ !Int
  , refusalPath ∷ ![PathStep]
  , refusalRule ∷ !ValueRule
  , refusalVisited ∷ !Int
  }
  deriving (Eq, Show)

-- | A table key as it was read.
data RawKey = KeyInteger !Int64 | KeyString !ByteString
  deriving (Eq, Show)

-- | A value as the reader copied it, before any schema was applied.
data RawValue
  = RNil
  | RBoolean !Bool
  | RInteger !Int64
  | RFloat !Double
  | RString !ByteString
  | RTable ![(RawKey, RawValue)]
  | -- | The issuing VM, the type's number, the key.
    RHandle !Word64 !Word32 !Word64
  deriving (Eq, Show)

-- | Decode @count@ values from the reader's encoding. A malformed encoding is a
-- bug in this package and is answered as one, never trusted.
decodeValues ∷ Int → ByteString → Either Text [RawValue]
decodeValues count input = go count input []
  where
    go 0 rest acc
      | ByteString.null rest = Right (reverse acc)
      | otherwise = Left "trailing bytes after the last value"
    go remaining rest acc = do
      (value, after) ← decodeOne rest
      go (remaining - 1 ∷ Int) after (value : acc)

decodeOne ∷ ByteString → Either Text (RawValue, ByteString)
decodeOne input = case ByteString.uncons input of
  Nothing → Left "the encoding ended where a value was expected"
  Just (tag, rest) → case tag of
    0x00 → Right (RNil, rest)
    0x01 → Right (RBoolean False, rest)
    0x02 → Right (RBoolean True, rest)
    0x03 → do
      (bytes, after) ← takeBytes 8 rest
      Right (RInteger (fromIntegral (le64 bytes)), after)
    0x04 → do
      (bytes, after) ← takeBytes 8 rest
      Right (RFloat (castWord64ToDouble (le64 bytes)), after)
    0x05 → do
      (text, after) ← sized rest
      Right (RString text, after)
    0x06 → do
      (header, afterHeader) ← takeBytes 4 rest
      entries ← pairs (fromIntegral (le32 header)) afterHeader []
      Right (RTable (fst entries), snd entries)
    0x07 → do
      (bytes, after) ← takeBytes 20 rest
      Right (RHandle (le64 (ByteString.take 8 bytes)) (le32 (ByteString.take 4 (ByteString.drop 8 bytes))) (le64 (ByteString.drop 12 bytes)), after)
    _ → Left "an unknown tag"
  where
    takeBytes n bytes
      | ByteString.length bytes >= n = Right (ByteString.splitAt n bytes)
      | otherwise = Left "the encoding ended inside a value"
    sized bytes = do
      (header, after) ← takeBytes 4 bytes
      takeBytes (fromIntegral (le32 header)) after
    pairs ∷ Int → ByteString → [(RawKey, RawValue)] → Either Text ([(RawKey, RawValue)], ByteString)
    pairs 0 rest acc = Right (reverse acc, rest)
    pairs remaining rest acc = do
      (key, afterKey) ← decodeKey rest
      (value, afterValue) ← decodeOne afterKey
      pairs (remaining - 1) afterValue ((key, value) : acc)
    decodeKey bytes = do
      (raw, after) ← decodeOne bytes
      case raw of
        RInteger v → Right (KeyInteger v, after)
        RString v → Right (KeyString v, after)
        _ → Left "a table key that is neither an integer nor a string"

le32 ∷ ByteString → Word32
le32 bytes = foldr (\byte acc → (acc `shiftL` 8) .|. fromIntegral byte) 0 (ByteString.unpack bytes)

le64 ∷ ByteString → Word64
le64 bytes = foldr (\byte acc → (acc `shiftL` 8) .|. fromIntegral byte) 0 (ByteString.unpack bytes)

-- | What checking a value needs to know of its VM.
data Context = Context
  { contextVm ∷ !VmIdentity
  , contextTypeName ∷ Word32 → Maybe Text
    -- ^ The application type a handle's number stands for.
  , contextTypeNumber ∷ Text → Maybe Word32
    -- ^ The number a type is given in a handle.
  }

describeRaw ∷ RawValue → Text
describeRaw = \case
  RNil → "nil"
  RBoolean _ → "boolean"
  RInteger _ → "integer"
  RFloat _ → "float"
  RString _ → "string"
  RTable _ → "table"
  RHandle {} → "capability"

describeSchema ∷ Schema → Text
describeSchema = \case
  SNil → "nil"
  SBoolean → "boolean"
  SInteger → "integer"
  SFloat → "float"
  SNumber → "number"
  SBytes → "byte string"
  SText → "text"
  SList _ → "list"
  SRecord _ → "record"
  SOptional inner → "optional " <> describeSchema inner
  SCapability name → "capability " <> name

describeValue ∷ Value → Text
describeValue = \case
  VNil → "nil"
  VBoolean _ → "boolean"
  VInteger _ → "integer"
  VFloat _ → "float"
  VBytes _ → "byte string"
  VText _ → "text"
  VList _ → "list"
  VRecord _ → "record"
  VCapability capability → "capability " <> capabilityTypeName capability

-- | Check a copy the reader made against a schema, and read it as a 'Value'.
--
-- The first rule broken is the answer, with where in the value it was.
conformRaw ∷ Context → Schema → RawValue → Either ([PathStep], ValueRule) Value
conformRaw context = go []
  where
    wrong path schema raw = Left (reverse path, RuleWrongType (describeSchema schema) (describeRaw raw))
    go path schema raw = case (schema, raw) of
      (SOptional _, RNil) → Right VNil
      (SOptional inner, _) → go path inner raw
      (SNil, RNil) → Right VNil
      (SBoolean, RBoolean value) → Right (VBoolean value)
      (SInteger, RInteger value) → Right (VInteger value)
      (SInteger, RFloat _) → Left (reverse path, RuleFloatForInteger)
      (SFloat, RFloat value) → Right (VFloat value)
      (SNumber, RInteger value) → Right (VInteger value)
      (SNumber, RFloat value) → Right (VFloat value)
      (SBytes, RString value) → Right (VBytes value)
      (SText, RString value) → case Text.decodeUtf8' value of
        Right text → Right (VText text)
        Left _ → Left (reverse path, RuleInvalidUtf8)
      (SList element, RTable entries) → do
        let keyed = [(index, value) | (KeyInteger index, value) ← entries]
        if length keyed /= length entries
          then Left (reverse path, RuleNotASequence)
          else do
            let ordered = sortOn fst keyed
            if map fst ordered /= [1 .. fromIntegral (length ordered)]
              then Left (reverse path, RuleNotASequence)
              else VList <$> traverse (\(index, value) → go (AtIndex (fromIntegral index) : path) element value) ordered
      (SRecord fields, RTable entries) → do
        named ← traverse (\(key, value) → case key of
                            KeyString bytes → case Text.decodeUtf8' bytes of
                              Right name → Right (name, value)
                              Left _ → Left (reverse path, RuleInvalidUtf8)
                            KeyInteger _ → Left (reverse path, RuleNotARecord)) entries
        case [name | (name, _) ← named, name `notElem` map fst fields] of
          name : _ → Left (reverse path, RuleUnknownField name)
          [] → VRecord <$> traverse (field path named) fields
      (SCapability expected, RHandle issuer number key)
        | VmIdentity issuer /= contextVm context → Left (reverse path, RuleForeignHandle)
        | otherwise → case contextTypeName context number of
            Just found
              | found == expected → Right (VCapability (Capability found key (Just (VmIdentity issuer))))
              | otherwise → Left (reverse path, RuleHandleType expected found)
            Nothing → Left (reverse path, RuleHandleType expected "unknown")
      _ → wrong path schema raw
    field path named (name, schema) = case lookup name named of
      Just value → (,) name <$> go (AtField name : path) schema value
      Nothing → case schema of
        SOptional _ → Right (name, VNil)
        _ → Left (reverse path, RuleMissingField name)

-- | Check a Haskell value against a schema, as a copy about to cross is checked.
conformValue ∷ Context → Schema → Value → Either ([PathStep], ValueRule) ()
conformValue context = go []
  where
    wrong path schema value = Left (reverse path, RuleWrongType (describeSchema schema) (describeValue value))
    go path schema value = case (schema, value) of
      (SOptional _, VNil) → Right ()
      (SOptional inner, _) → go path inner value
      (SNil, VNil) → Right ()
      (SBoolean, VBoolean _) → Right ()
      (SInteger, VInteger _) → Right ()
      (SInteger, VFloat _) → Left (reverse path, RuleFloatForInteger)
      (SFloat, VFloat _) → Right ()
      (SNumber, VInteger _) → Right ()
      (SNumber, VFloat _) → Right ()
      (SBytes, VBytes _) → Right ()
      (SText, VText _) → Right ()
      (SList element, VList values) →
        sequence_ [go (AtIndex index : path) element item | (index, item) ← zip [1 ..] values]
      (SRecord fields, VRecord entries) → do
        case [name | name ← nub (map fst entries), length (filter ((== name) . fst) entries) > 1] of
          name : _ → Left (reverse path, RuleDuplicateField name)
          [] → Right ()
        case [name | (name, _) ← entries, name `notElem` map fst fields] of
          name : _ → Left (reverse path, RuleUnknownField name)
          [] → Right ()
        sequence_
          [ case lookup name entries of
              Just item → go (AtField name : path) fieldSchema item
              Nothing → case fieldSchema of
                SOptional _ → Right ()
                _ → Left (reverse path, RuleMissingField name)
          | (name, fieldSchema) ← fields
          ]
      (SCapability expected, VCapability capability)
        | capabilityTypeName capability /= expected → Left (reverse path, RuleHandleType expected (capabilityTypeName capability))
        | Just issuer ← capabilityIssuer capability, issuer /= contextVm context → Left (reverse path, RuleForeignHandle)
        | otherwise → case contextTypeNumber context expected of
            Just _ → Right ()
            Nothing → Left (reverse path, RuleUnknownCapability expected)
      _ → wrong path schema value

-- | Encode values for the C layer to build in Lua, refusing a copy that would
-- pass a limit. The sum of the encodings is what the byte limit bounds, and the
-- values counted by the element limit are the ones the reader would count.
encodeValues ∷ Context → ValueLimits → [Value] → Either ValueRule ByteString
encodeValues context limits values = do
  (builder, bytes, elements) ← foldlM' step (mempty, 0, 0) values
  if bytes > limitBytes limits then Left (RuleBytesLimit (limitBytes limits)) else Right ()
  if elements > limitElements limits then Left (RuleElementLimit (limitElements limits)) else Right ()
  Right (Lazy.toStrict (Builder.toLazyByteString builder))
  where
    step (acc, bytes, elements) value = do
      (builder, size, count) ← encodeOne context limits 0 value
      Right (acc <> builder, bytes + size, elements + count)
    foldlM' f z xs = foldl (\acc x → acc >>= \a → f a x) (Right z) xs

-- | The encoding of one value, its size and its element count; a table past the
-- depth limit is refused where it is met.
encodeOne ∷ Context → ValueLimits → Int → Value → Either ValueRule (Builder.Builder, Int, Int)
encodeOne context limits depth = \case
  VNil → Right (Builder.word8 0x00, 1, 1)
  VBoolean False → Right (Builder.word8 0x01, 1, 1)
  VBoolean True → Right (Builder.word8 0x02, 1, 1)
  VInteger value → Right (Builder.word8 0x03 <> Builder.int64LE value, 9, 1)
  VFloat value → Right (Builder.word8 0x04 <> Builder.word64LE (castDoubleToWord64 value), 9, 1)
  VBytes bytes → Right (stringBuilder bytes, 5 + ByteString.length bytes, 1)
  VText text → let bytes = Text.encodeUtf8 text in Right (stringBuilder bytes, 5 + ByteString.length bytes, 1)
  VList items → table depth [(KeyIndex index, item) | (index, item) ← zip [1 ..] items]
  VRecord entries → table depth [(KeyName name, item) | (name, item) ← entries]
  VCapability capability → do
    issuer ← case capabilityIssuer capability of
      Nothing → Right (contextVm context)
      Just found
        | found == contextVm context → Right found
        | otherwise → Left RuleForeignHandle
    number ← maybe (Left (RuleUnknownCapability (capabilityTypeName capability))) Right (contextTypeNumber context (capabilityTypeName capability))
    let VmIdentity identity = issuer
    Right (Builder.word8 0x07 <> Builder.word64LE identity <> Builder.word32LE number <> Builder.word64LE (capabilityKey capability), 21, 1)
  where
    stringBuilder bytes = Builder.word8 0x05 <> Builder.word32LE (fromIntegral (ByteString.length bytes)) <> Builder.byteString bytes
    table level entries
      | level + 1 > limitDepth limits = Left (RuleDepthLimit (limitDepth limits))
      | otherwise = do
          encoded ← traverse (encodeEntry level) entries
          let size = 5 + sum [keySize + valueSize | (_, keySize, _, valueSize, _) ← encoded]
              count = 1 + sum [valueCount | (_, _, _, _, valueCount) ← encoded]
              body = mconcat [keyBuilder <> valueBuilder | (keyBuilder, _, valueBuilder, _, _) ← encoded]
          Right (Builder.word8 0x06 <> Builder.word32LE (fromIntegral (length entries)) <> body, size, count)
    encodeEntry level (key, item) = do
      let (keyBuilder, keySize) = case key of
            KeyIndex index → (Builder.word8 0x03 <> Builder.int64LE (fromIntegral (index ∷ Int)), 9)
            KeyName name → let bytes = Text.encodeUtf8 name in (stringBuilder bytes, 5 + ByteString.length bytes)
      (valueBuilder, valueSize, valueCount) ← encodeOne context limits (level + 1) item
      Right (keyBuilder, keySize, valueBuilder, valueSize, valueCount)

-- | A table key being encoded: a list position or a field name.
data EncodedKey = KeyIndex !Int | KeyName !Text
