{-# LANGUAGE OverloadedStrings #-}

-- | The manifest schema: a duplicate-free object to a 'Manifest', or the one
-- refusal that comes first.
--
-- __Order.__ A document that reaches this module is syntactically valid, so
-- the refusal is decided by a fixed order of checks that never consults member
-- order: unknown fields (the least key by code point), then @format@, @id@,
-- @entry@, @vms@ with its elements in index order, and @tick_seconds@. The
-- same members in any order give the same result, refusal included. Elements of
-- @vms@ are checked by index and a refusal may cite it, but a valid array
-- resolves to the same configuration in either order.
--
-- __Contract.__ Exactly the fields @format@, @id@, @entry@, @tick_seconds@ and
-- @vms@ (and in a role @role@, @clock@, @entry@) are accepted; unknown fields,
-- @null@ and wrong types are refused, never ignored or coerced. Entry texts are
-- kept as decoded; their path validity is not judged here.
module Hetoimasia.LuaEngine.Manifest.Schema
  ( resolveManifest
  ) where

import Data.ByteString (ByteString)
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Time (Duration)
import Hetoimasia.LuaEngine.Manifest.Error
import Hetoimasia.LuaEngine.Manifest.Json (JsonValue (..), numberIsOne, valueKind)
import Hetoimasia.LuaEngine.Manifest.Tick (parseTickSeconds)
import Hetoimasia.LuaEngine.Manifest.Types

-- | A role declaration as written, before entries are resolved.
data Declaration = Declaration
  { declaredRole ∷ !Role
  , declaredEntryText ∷ !(Maybe Text)
  }

-- | Resolve a duplicate-free root object into a manifest. The bytes are kept
-- only to be returned in it.
resolveManifest ∷ Duration → ByteString → Map Text JsonValue → Either SchemaError Manifest
resolveManifest maximumTick bytes root = do
  checkKnownFields [] rootFields root
  checkFormat root
  identifier ← identifierOf root
  commonEntry ← optionalString [] "entry" root
  declarations ← declarationsOf root
  selection ← resolveRoles maximumTick root commonEntry declarations
  Right
    Manifest
      { manifestBytes = bytes
      , manifestId = identifier
      , manifestCommonEntry = commonEntry
      , manifestRoles = selection
      }

rootFields, roleFields ∷ [Text]
rootFields = ["format", "id", "entry", "tick_seconds", "vms"]
roleFields = ["role", "clock", "entry"]

keyPath ∷ FieldPath → Text → FieldPath
keyPath path key = path ++ [PathKey (excerptOf key)]

-- | Refuse the least key that is not in the list.
checkKnownFields ∷ FieldPath → [Text] → Map Text JsonValue → Either SchemaError ()
checkKnownFields path known object = case find (`notElem` known) (Map.keys object) of
  Nothing → Right ()
  Just key → Left (UnknownField path (excerptOf key))

-- | A present field, with @null@ refused.
present ∷ FieldPath → Text → Map Text JsonValue → Either SchemaError (Maybe JsonValue)
present path key object = case Map.lookup key object of
  Nothing → Right Nothing
  Just JsonNull → Left (NullValue (keyPath path key))
  Just value → Right (Just value)

required ∷ FieldPath → Text → Map Text JsonValue → Either SchemaError JsonValue
required path key object = do
  found ← present path key object
  maybe (Left (MissingField (keyPath path key))) Right found

stringOf ∷ FieldPath → JsonValue → Either SchemaError Text
stringOf path value = case value of
  JsonString text → Right text
  other → Left (WrongType path ExpectedString (valueKind other))

optionalString ∷ FieldPath → Text → Map Text JsonValue → Either SchemaError (Maybe Text)
optionalString path key object = do
  found ← present path key object
  traverse (stringOf (keyPath path key)) found

checkFormat ∷ Map Text JsonValue → Either SchemaError ()
checkFormat root = do
  value ← required [] "format" root
  case value of
    JsonNumber number
      | numberIsOne number → Right ()
      | otherwise → Left UnsupportedFormat
    other → Left (WrongType (keyPath [] "format") ExpectedNumber (valueKind other))

identifierOf ∷ Map Text JsonValue → Either SchemaError ContentId
identifierOf root = do
  text ← required [] "id" root >>= stringOf (keyPath [] "id")
  case idProblem text of
    Nothing → Right (unsafeContentId text)
    Just problem → Left (InvalidId problem)

-- | The first thing wrong with an identifier: empty, longer than 64, or the
-- first character outside @[a-z]@ at the start and @[a-z0-9_-]@ after.
idProblem ∷ Text → Maybe IdProblem
idProblem text
  | Text.null text = Just IdEmpty
  | Text.compareLength text 64 == GT = Just (IdTooLong (Text.length text))
  | otherwise = case [index | (index, character) ← zip [0 ..] (Text.unpack text), not (allowed index character)] of
      [] → Nothing
      index : _ → Just (IdBadCharacter index)
  where
    allowed ∷ Int → Char → Bool
    allowed index character
      | index == 0 = lower character
      | otherwise = lower character || (character >= '0' && character <= '9') || character == '_' || character == '-'
    lower character = character >= 'a' && character <= 'z'

-- | The role declarations in the document, if @vms@ is present, in array order.
declarationsOf ∷ Map Text JsonValue → Either SchemaError (Maybe [Declaration])
declarationsOf root = do
  found ← present [] "vms" root
  case found of
    Nothing → Right Nothing
    Just (JsonArray elements) → do
      case elements of
        [] → Left EmptyVms
        _ | length elements > 2 → Left (TooManyVms (length elements))
        _ → Right ()
      declarations ← traverse declaration (zip [0 ..] elements)
      checkRolesUnique declarations
      Right (Just (map snd declarations))
    Just other → Left (WrongType (keyPath [] "vms") ExpectedArray (valueKind other))
  where
    declaration (index, element) = do
      let path = keyPath [] "vms" ++ [PathIndex index]
      object ← case element of
        JsonObject members → Right members
        JsonNull → Left (NullValue path)
        other → Left (WrongType path ExpectedObject (valueKind other))
      checkKnownFields path roleFields object
      roleText ← required path "role" object >>= stringOf (keyPath path "role")
      clockText ← required path "clock" object >>= stringOf (keyPath path "clock")
      entry ← optionalString path "entry" object
      role ← case roleText of
        "gameplay" → Right Gameplay
        "presentation" → Right Presentation
        _ → Left (UnknownRole (keyPath path "role") (excerptOf roleText))
      let expectedClock = case role of
            Gameplay → "logical"
            Presentation → "elapsed"
      if clockText == expectedClock
        then Right ()
        else
          Left $
            if clockText `elem` ["logical", "elapsed"]
              then ClockMismatch role index
              else UnknownClock (keyPath path "clock") (excerptOf clockText)
      Right (index, Declaration {declaredRole = role, declaredEntryText = entry})
    checkRolesUnique declarations = go [] declarations
      where
        go _ [] = Right ()
        go seen ((index, declared) : rest)
          | declaredRole declared `elem` seen = Left (DuplicateRole (declaredRole declared) index)
          | otherwise = go (declaredRole declared : seen) rest

-- | Pair each declared role with its entry and, for gameplay, its tick.
resolveRoles ∷ Duration → Map Text JsonValue → Maybe Text → Maybe [Declaration] → Either SchemaError RoleSelection
resolveRoles maximumTick root commonEntry declarations = do
  gameplay ← entryFor Gameplay
  presentation ← entryFor Presentation
  case (gameplay, presentation) of
    (Just chosen, Nothing) → GameplayOnly <$> gameplayRole chosen
    (Just chosen, Just other) → do
      role ← gameplayRole chosen
      Right (BothRoles role (presentationRole other))
    (Nothing, Just chosen) → do
      case Map.lookup "tick_seconds" root of
        Just _ → Left TickForbidden
        Nothing → Right ()
      Right (PresentationOnly (presentationRole chosen))
    -- A declaration list is never empty, so some role is always present.
    (Nothing, Nothing) → Left EmptyVms
  where
    declared = fromMaybe [Declaration Gameplay Nothing, Declaration Presentation Nothing] declarations
    -- The role's selected entry and where it came from, if the role is declared:
    -- its own entry, else the common one, else a refusal.
    entryFor role = case find ((== role) . declaredRole) declared of
      Nothing → Right Nothing
      Just declaration → case (declaredEntryText declaration, commonEntry) of
        (Just entry, _) → Right (Just (entry, ExplicitEntry))
        (Nothing, Just entry) → Right (Just (entry, CommonEntry))
        (Nothing, Nothing) → Left (MissingEntry role)
    presentationRole (entry, origin) = PresentationRole {presentationEntry = entry, presentationEntryOrigin = origin}
    gameplayRole (entry, origin) = do
      found ← present [] "tick_seconds" root
      text ← case found of
        Nothing → Left TickRequired
        Just value → stringOf (keyPath [] "tick_seconds") value
      tick ← either (Left . InvalidTick) Right (parseTickSeconds maximumTick text)
      Right GameplayRole {gameplayEntry = entry, gameplayEntryOrigin = origin, gameplayTick = tick}
