{-# LANGUAGE OverloadedStrings #-}

-- | Builders and readers the manifest specs share: documents assembled from
-- member text, results narrowed to their syntax or schema refusal, and the
-- exact durations the examples expect.
module Test.LuaEngine.Support
  ( -- * Documents
    bytes
  , object
  , member
  , quoted
  , baseMembers
  , document

    -- * Results
  , parsed
  , syntaxRefusal
  , schemaRefusal
  , gameplayOf
  , presentationOf
  , sansBytes
  , allShouldBe

    -- * Expectations
  , nanoseconds
  , offsetOf
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (RequirePositive), durationFromNanoseconds)
import Hetoimasia.LuaEngine.Manifest
import Test.Hspec (Expectation, shouldBe)

-- | UTF-8 bytes of text.
bytes ∷ Text → ByteString
bytes = Encoding.encodeUtf8

-- | A JSON object from members already written as @"key":value@.
object ∷ [Text] → Text
object members = "{" <> Text.intercalate "," members <> "}"

-- | A member from a key written as it appears between the quotes and a value
-- written as JSON text.
member ∷ Text → Text → Text
member key value = "\"" <> key <> "\":" <> value

-- | A JSON string of plain text with no escapes.
quoted ∷ Text → Text
quoted text = "\"" <> text <> "\""

-- | The members of the default example, in order.
baseMembers ∷ [Text]
baseMembers =
  [ member "format" "1"
  , member "id" (quoted "example_game")
  , member "entry" (quoted "lua/main.lua")
  , member "tick_seconds" (quoted "0.01")
  ]

-- | The bytes of an object of these members.
document ∷ [Text] → ByteString
document = bytes . object

-- | The fixed-profile parse.
parsed ∷ ByteString → Either ManifestError Manifest
parsed = parseManifest

-- | The syntax refusal, if the result is one.
syntaxRefusal ∷ ByteString → Maybe SyntaxError
syntaxRefusal input = case parsed input of
  Left (ManifestSyntax refusal) → Just refusal
  _ → Nothing

-- | The schema refusal, if the result is one.
schemaRefusal ∷ ByteString → Maybe SchemaError
schemaRefusal input = case parsed input of
  Left (ManifestSchema refusal) → Just refusal
  _ → Nothing

-- | The gameplay role of a selection.
gameplayOf ∷ RoleSelection → Maybe GameplayRole
gameplayOf selection = case selection of
  GameplayOnly role → Just role
  BothRoles role _ → Just role
  PresentationOnly _ → Nothing

-- | The presentation role of a selection.
presentationOf ∷ RoleSelection → Maybe PresentationRole
presentationOf selection = case selection of
  PresentationOnly role → Just role
  BothRoles _ role → Just role
  GameplayOnly _ → Nothing

-- | A manifest without its bytes, for comparing what two spellings resolve to.
sansBytes ∷ Manifest → Manifest
sansBytes manifest = manifest {manifestBytes = ByteString.empty}

-- | Every result equals the expected one. A failure shows the first result that
-- differs and the expected one, never the whole list: a long list of results
-- would otherwise make a failing example slow to report.
allShouldBe ∷ (Eq a, Show a) ⇒ a → [a] → Expectation
allShouldBe expected actuals = case filter (/= expected) actuals of
  [] → pure ()
  differing : _ → differing `shouldBe` expected

-- | A duration of exactly this many nanoseconds; the example fails if it is
-- not a duration.
nanoseconds ∷ Integer → Duration
nanoseconds count = either (error . show) id (durationFromNanoseconds RequirePositive count)

-- | The byte offset of the first occurrence of the needle.
offsetOf ∷ ByteString → ByteString → Int
offsetOf needle haystack = ByteString.length (fst (ByteString.breakSubstring needle haystack))
