{-# LANGUAGE OverloadedStrings #-}

-- | The manifest schema: every refusal of a syntactically valid document, the
-- exact numeric reading of @format@, the identifier grammar, role and entry
-- resolution, and that no choice among refusals depends on member order.
module Test.LuaEngine.Manifest.Schema (spec) where

import Data.List (permutations)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Manifest
import Test.Hspec
import Test.LuaEngine.Support

formatMember, idMember, entryMember, tickMember ∷ Text
formatMember = member "format" "1"
idMember = member "id" (quoted "g")
entryMember = member "entry" (quoted "e.lua")
tickMember = member "tick_seconds" (quoted "1")

key ∷ Text → PathSegment
key text = PathKey (Excerpt text False)

gameplay, presentation ∷ Text
gameplay = object ["\"role\":\"gameplay\"", "\"clock\":\"logical\""]
presentation = object ["\"role\":\"presentation\"", "\"clock\":\"elapsed\""]

vms ∷ [Text] → Text
vms declarations = member "vms" ("[" <> Text.intercalate "," declarations <> "]")

-- | A well-formed document of the members refused with this schema error.
refusedWith ∷ [Text] → SchemaError → Expectation
refusedWith members expected = parsed (document members) `shouldBe` Left (ManifestSchema expected)

-- | Whether a format token is accepted, with the other members valid.
formatAccepted ∷ Text → Bool
formatAccepted token = case parsed (document [member "format" token, idMember, entryMember, tickMember]) of
  Right _ → True
  Left (ManifestSchema UnsupportedFormat) → False
  Left refusal → error ("unexpected refusal for format " <> Text.unpack token <> ": " <> show refusal)

spec ∷ Spec
spec = describe "manifest schema" $ do
  describe "unknown, missing, null and wrongly typed fields" $ do
    it "refuses a field the schema does not define, naming the least such key" $ do
      [formatMember, idMember, entryMember, tickMember, member "mods" "[]"] `refusedWith` UnknownField [] (Excerpt "mods" False)
      [formatMember, idMember, entryMember, tickMember, member "window" "{}"] `refusedWith` UnknownField [] (Excerpt "window" False)
      [formatMember, idMember, entryMember, tickMember, member "zeta" "1", member "alpha" "1"] `refusedWith` UnknownField [] (Excerpt "alpha" False)
      [formatMember, idMember, entryMember, tickMember, member "Format" "1"] `refusedWith` UnknownField [] (Excerpt "Format" False)
      [formatMember, idMember, entryMember, tickMember, member "tick" "1"] `refusedWith` UnknownField [] (Excerpt "tick" False)

    it "refuses a missing required field" $ do
      [idMember, entryMember, tickMember] `refusedWith` MissingField [key "format"]
      [formatMember, entryMember, tickMember] `refusedWith` MissingField [key "id"]
      [formatMember, idMember, tickMember] `refusedWith` MissingEntry Gameplay
      [formatMember, idMember, entryMember] `refusedWith` TickRequired
      [] `refusedWith` MissingField [key "format"]

    it "refuses null in every field" $ do
      [member "format" "null", idMember, entryMember, tickMember] `refusedWith` NullValue [key "format"]
      [formatMember, member "id" "null", entryMember, tickMember] `refusedWith` NullValue [key "id"]
      [formatMember, idMember, member "entry" "null", tickMember] `refusedWith` NullValue [key "entry"]
      [formatMember, idMember, entryMember, member "tick_seconds" "null"] `refusedWith` NullValue [key "tick_seconds"]
      [formatMember, idMember, entryMember, tickMember, member "vms" "null"] `refusedWith` NullValue [key "vms"]
      [formatMember, idMember, entryMember, tickMember, member "vms" "[null]"] `refusedWith` NullValue [key "vms", PathIndex 0]
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":null", "\"clock\":\"logical\""]]] `refusedWith` NullValue [key "vms", PathIndex 0, key "role"]
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":\"gameplay\"", "\"clock\":null"]]] `refusedWith` NullValue [key "vms", PathIndex 0, key "clock"]
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":\"gameplay\"", "\"clock\":\"logical\"", "\"entry\":null"]]] `refusedWith` NullValue [key "vms", PathIndex 0, key "entry"]

    it "refuses a wrong type and never coerces" $ do
      [member "format" (quoted "1"), idMember, entryMember, tickMember] `refusedWith` WrongType [key "format"] ExpectedNumber KindString
      [member "format" "true", idMember, entryMember, tickMember] `refusedWith` WrongType [key "format"] ExpectedNumber KindBool
      [member "format" "[1]", idMember, entryMember, tickMember] `refusedWith` WrongType [key "format"] ExpectedNumber KindArray
      [member "format" "{}", idMember, entryMember, tickMember] `refusedWith` WrongType [key "format"] ExpectedNumber KindObject
      [formatMember, member "id" "7", entryMember, tickMember] `refusedWith` WrongType [key "id"] ExpectedString KindNumber
      [formatMember, idMember, member "entry" "1", tickMember] `refusedWith` WrongType [key "entry"] ExpectedString KindNumber
      [formatMember, idMember, entryMember, member "tick_seconds" "0.01"] `refusedWith` WrongType [key "tick_seconds"] ExpectedString KindNumber
      [formatMember, idMember, entryMember, member "tick_seconds" "true"] `refusedWith` WrongType [key "tick_seconds"] ExpectedString KindBool
      [formatMember, idMember, entryMember, tickMember, member "vms" "{}"] `refusedWith` WrongType [key "vms"] ExpectedArray KindObject
      [formatMember, idMember, entryMember, tickMember, member "vms" (quoted "gameplay")] `refusedWith` WrongType [key "vms"] ExpectedArray KindString
      [formatMember, idMember, entryMember, tickMember, member "vms" "[1]"] `refusedWith` WrongType [key "vms", PathIndex 0] ExpectedObject KindNumber
      [formatMember, idMember, entryMember, tickMember, member "vms" "[[]]"] `refusedWith` WrongType [key "vms", PathIndex 0] ExpectedObject KindArray
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":1", "\"clock\":\"logical\""]]] `refusedWith` WrongType [key "vms", PathIndex 0, key "role"] ExpectedString KindNumber
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":\"gameplay\"", "\"clock\":false"]]] `refusedWith` WrongType [key "vms", PathIndex 0, key "clock"] ExpectedString KindBool
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":\"gameplay\"", "\"clock\":\"logical\"", "\"entry\":[]"]]] `refusedWith` WrongType [key "vms", PathIndex 0, key "entry"] ExpectedString KindArray

  describe "format" $ do
    it "accepts every number token whose exact decimal value is 1" $
      mapM_
        (\token → (token, formatAccepted token) `shouldBe` (token, True))
        ["1", "1.0", "1.000", "1e0", "1E0", "1e+0", "1e-0", "10E-1", "0.1e1", "0.10e1", "100e-2", "0.00001e5", "1.0e0", "0.0000001e7", "10.0E-1", "1e000", "1e00000000000000000000000000000000"]

    it "refuses every other value, without converting to binary floating point" $
      mapM_
        (\token → (token, formatAccepted token) `shouldBe` (token, False))
        [ "0"
        , "2"
        , "-1"
        , "-1.0"
        , "10"
        , "0.1"
        , "1.5"
        , "1e1"
        , "1e-1"
        , "1.00000000000000000001"
        , "0.99999999999999999999"
        , "1.0000000000000000000000000000000001"
        , "0.9999999999999999999999999999999999"
        , "9007199254740993"
        , "1e999999999"
        , "1e-999999999"
        , "1e99999999999999999999999999999999999999"
        , "0e999999999"
        , "10e999999999"
        , "-0"
        , "0.1e0"
        , "100e-1"
        ]

    it "refuses a very long token and a very long exponent without size-derived work" $ do
      let zeros = Text.replicate 30000 "0"
      formatAccepted ("0." <> zeros <> "1e30001") `shouldBe` True
      formatAccepted ("0." <> zeros <> "1e30000") `shouldBe` False
      formatAccepted ("1." <> zeros) `shouldBe` True
      formatAccepted ("1." <> zeros <> "1") `shouldBe` False
      formatAccepted ("1e" <> Text.replicate 40000 "0") `shouldBe` True
      formatAccepted ("1e" <> Text.replicate 40000 "0" <> "1") `shouldBe` False
      formatAccepted ("1e-" <> Text.replicate 40000 "9") `shouldBe` False

    it "refuses a string, which is not a number" $
      [member "format" (quoted "1"), idMember, entryMember, tickMember] `refusedWith` WrongType [key "format"] ExpectedNumber KindString

  describe "id" $ do
    let idRefusal text = parsed (document [formatMember, member "id" (quoted text), entryMember, tickMember])
        accepted text = fmap (contentIdText . manifestId) (idRefusal text)
    it "accepts one to sixty-four characters of [a-z][a-z0-9_-]*" $ do
      accepted "a" `shouldBe` Right "a"
      accepted "example_game" `shouldBe` Right "example_game"
      accepted "a-b_c9" `shouldBe` Right "a-b_c9"
      accepted "z0" `shouldBe` Right "z0"
      accepted (Text.replicate 64 "a") `shouldBe` Right (Text.replicate 64 "a")

    it "refuses an empty identifier and one of sixty-five characters" $ do
      idRefusal "" `shouldBe` Left (ManifestSchema (InvalidId IdEmpty))
      idRefusal (Text.replicate 65 "a") `shouldBe` Left (ManifestSchema (InvalidId (IdTooLong 65)))
      idRefusal (Text.replicate 65 "A") `shouldBe` Left (ManifestSchema (InvalidId (IdTooLong 65)))

    it "refuses the first character outside the grammar, by position" $ do
      idRefusal "A" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 0)))
      idRefusal "Example" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 0)))
      idRefusal "1abc" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 0)))
      idRefusal "-a" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 0)))
      idRefusal "_a" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 0)))
      idRefusal "aB" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 1)))
      idRefusal "a b" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 1)))
      idRefusal "a.b" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 1)))
      idRefusal "a/b" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 1)))
      idRefusal "abc\\u00e9" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 3)))
      idRefusal "caf\233" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 3)))
      idRefusal "日本" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 0)))
      idRefusal "a\\n" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 1)))
      idRefusal "a\\u0000" `shouldBe` Left (ManifestSchema (InvalidId (IdBadCharacter 1)))

  describe "vms" $ do
    it "refuses an empty array and more than two declarations" $ do
      [formatMember, idMember, entryMember, tickMember, member "vms" "[]"] `refusedWith` EmptyVms
      [formatMember, idMember, entryMember, tickMember, vms [gameplay, presentation, gameplay]] `refusedWith` TooManyVms 3
      [formatMember, idMember, entryMember, tickMember, vms [presentation, presentation, presentation]] `refusedWith` TooManyVms 3

    it "refuses a very long array by its length, before looking at its elements" $
      [formatMember, idMember, entryMember, tickMember, member "vms" ("[" <> Text.intercalate "," (replicate 20000 "0") <> "]")] `refusedWith` TooManyVms 20000

    it "refuses a duplicate role, citing the later declaration" $ do
      [formatMember, idMember, entryMember, tickMember, vms [gameplay, gameplay]] `refusedWith` DuplicateRole Gameplay 1
      [formatMember, idMember, entryMember, tickMember, vms [presentation, presentation]] `refusedWith` DuplicateRole Presentation 1

    it "refuses an unknown role or clock" $ do
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":\"audio\"", "\"clock\":\"logical\""]]]
        `refusedWith` UnknownRole [key "vms", PathIndex 0, key "role"] (Excerpt "audio" False)
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":\"Gameplay\"", "\"clock\":\"logical\""]]]
        `refusedWith` UnknownRole [key "vms", PathIndex 0, key "role"] (Excerpt "Gameplay" False)
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":\"\"", "\"clock\":\"logical\""]]]
        `refusedWith` UnknownRole [key "vms", PathIndex 0, key "role"] (Excerpt "" False)
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":\"gameplay\"", "\"clock\":\"wall\""]]]
        `refusedWith` UnknownClock [key "vms", PathIndex 0, key "clock"] (Excerpt "wall" False)

    it "refuses a clock that belongs to the other role" $ do
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":\"gameplay\"", "\"clock\":\"elapsed\""]]] `refusedWith` ClockMismatch Gameplay 0
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":\"presentation\"", "\"clock\":\"logical\""]]] `refusedWith` ClockMismatch Presentation 0
      [formatMember, idMember, entryMember, tickMember, vms [presentation, object ["\"role\":\"gameplay\"", "\"clock\":\"elapsed\""]]] `refusedWith` ClockMismatch Gameplay 1

    it "refuses a declaration with a missing field or an extra field" $ do
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"clock\":\"logical\""]]] `refusedWith` MissingField [key "vms", PathIndex 0, key "role"]
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":\"gameplay\""]]] `refusedWith` MissingField [key "vms", PathIndex 0, key "clock"]
      [formatMember, idMember, entryMember, tickMember, vms [object []]] `refusedWith` MissingField [key "vms", PathIndex 0, key "role"]
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"role\":\"gameplay\"", "\"clock\":\"logical\"", "\"cadence\":1"]]]
        `refusedWith` UnknownField [key "vms", PathIndex 0] (Excerpt "cadence" False)

    it "refuses the least unknown key of a declaration, never the first written" $ do
      [formatMember, idMember, entryMember, tickMember, vms [object ["\"zz\":1", "\"role\":\"gameplay\"", "\"aa\":1", "\"clock\":\"logical\""]]]
        `refusedWith` UnknownField [key "vms", PathIndex 0] (Excerpt "aa" False)

  describe "entry resolution" $ do
    it "refuses a role with neither its own entry nor a common entry to fall back on" $ do
      [formatMember, idMember, tickMember] `refusedWith` MissingEntry Gameplay
      [formatMember, idMember, tickMember, vms [gameplay]] `refusedWith` MissingEntry Gameplay
      [formatMember, idMember, vms [presentation]] `refusedWith` MissingEntry Presentation
      [formatMember, idMember, tickMember, vms [object ["\"role\":\"gameplay\"", "\"clock\":\"logical\"", "\"entry\":\"g.lua\""], presentation]] `refusedWith` MissingEntry Presentation
      [formatMember, idMember, tickMember, vms [gameplay, object ["\"role\":\"presentation\"", "\"clock\":\"elapsed\"", "\"entry\":\"p.lua\""]]] `refusedWith` MissingEntry Gameplay

    it "does not invent a role to satisfy an entry" $ do
      let manifest = parsed (document [formatMember, idMember, entryMember, tickMember, vms [gameplay]])
      fmap (selectedRoles . manifestRoles) manifest `shouldBe` Right [Gameplay]
      let other = parsed (document [formatMember, idMember, entryMember, vms [presentation]])
      fmap (selectedRoles . manifestRoles) other `shouldBe` Right [Presentation]

  describe "tick_seconds presence" $ do
    it "is required whenever gameplay is present" $ do
      [formatMember, idMember, entryMember] `refusedWith` TickRequired
      [formatMember, idMember, entryMember, vms [gameplay]] `refusedWith` TickRequired
      [formatMember, idMember, entryMember, vms [gameplay, presentation]] `refusedWith` TickRequired

    it "is forbidden for presentation only, whatever its value" $ do
      [formatMember, idMember, entryMember, tickMember, vms [presentation]] `refusedWith` TickForbidden
      [formatMember, idMember, entryMember, member "tick_seconds" "null", vms [presentation]] `refusedWith` TickForbidden
      [formatMember, idMember, entryMember, member "tick_seconds" (quoted "not a tick"), vms [presentation]] `refusedWith` TickForbidden
      [formatMember, idMember, entryMember, member "tick_seconds" "1", vms [presentation]] `refusedWith` TickForbidden

    it "has no default" $
      fmap (const ()) (parsed (document [formatMember, idMember, entryMember])) `shouldBe` Left (ManifestSchema TickRequired)

  describe "which refusal wins" $ do
    it "checks unknown fields, then format, id, entries, vms and the tick, in that fixed order" $ do
      let allWrong = [member "format" "2", member "id" (quoted "X"), member "entry" "1", member "tick_seconds" "1", member "vms" "[]", member "zzz" "1"]
      allWrong `refusedWith` UnknownField [] (Excerpt "zzz" False)
      take 5 allWrong `refusedWith` UnsupportedFormat
      (drop 1 (take 5 allWrong) <> [formatMember]) `refusedWith` InvalidId (IdBadCharacter 0)
      [formatMember, idMember, member "entry" "1", member "tick_seconds" "1", member "vms" "[]"] `refusedWith` WrongType [key "entry"] ExpectedString KindNumber
      [formatMember, idMember, entryMember, member "tick_seconds" "1", member "vms" "[]"] `refusedWith` EmptyVms
      [formatMember, idMember, member "tick_seconds" "1", vms [gameplay]] `refusedWith` MissingEntry Gameplay
      [formatMember, idMember, entryMember, member "tick_seconds" "1"] `refusedWith` WrongType [key "tick_seconds"] ExpectedString KindNumber

    it "returns the same refusal for every ordering of the members of a document with several errors" $
      mapM_
        ( \members →
            allShouldBe (parsed (document members)) (map (parsed . document) (permutations members))
        )
        [ [member "format" "2", member "id" (quoted "X"), member "entry" "1", member "tick_seconds" "1", member "zzz" "1", member "aaa" "null"]
        , [member "format" "1", member "id" "null", member "entry" "1", member "tick_seconds" "1", member "vms" "[]"]
        , [formatMember, idMember, member "vms" "[]", member "tick_seconds" "1", member "bb" "1", member "ba" "2"]
        , [formatMember, idMember, member "entry" "null", member "tick_seconds" "1", vms [gameplay]]
        ]

    it "returns the same refusal for every ordering of the members of a declaration with several errors" $ do
      let members = ["\"zz\":1", "\"role\":\"gameplay\"", "\"aa\":1", "\"clock\":\"elapsed\"", "\"entry\":7"]
          results = map (\order → parsed (document [formatMember, idMember, entryMember, tickMember, vms [object order]])) (permutations members)
          expected = Left (ManifestSchema (UnknownField [key "vms", PathIndex 0] (Excerpt "aa" False)))
      allShouldBe expected results

    it "resolves a valid vms array to the same configuration in either order" $ do
      let one = parsed (document [formatMember, idMember, member "tick_seconds" (quoted "3"), vms [object ["\"role\":\"gameplay\"", "\"clock\":\"logical\"", "\"entry\":\"g\""], object ["\"role\":\"presentation\"", "\"clock\":\"elapsed\"", "\"entry\":\"p\""]]])
          other = parsed (document [formatMember, idMember, member "tick_seconds" (quoted "3"), vms [object ["\"role\":\"presentation\"", "\"clock\":\"elapsed\"", "\"entry\":\"p\""], object ["\"role\":\"gameplay\"", "\"clock\":\"logical\"", "\"entry\":\"g\""]]])
      fmap manifestRoles one `shouldBe` fmap manifestRoles other
