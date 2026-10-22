{-# LANGUAGE OverloadedStrings #-}

-- | The accepted manifests: the issue's examples, both role orders, the common
-- and per-role entry fallbacks, every one-role variant and the absent @vms@, with
-- the selected entries, every declared entry and the exact bytes preserved.
module Test.LuaEngine.Manifest.Examples (spec) where

import Data.List (permutations)
import Data.Text (Text)
import Hetoimasia.LuaEngine.Manifest
import Test.Hspec
import Test.LuaEngine.Support

-- | Both fixed roles from one entry; 10 ms is example data, never a default.
defaultExample ∷ Text
defaultExample = "{\"format\":1,\"id\":\"example_game\",\"entry\":\"lua/main.lua\",\"tick_seconds\":\"0.01\"}"

-- | Separate entries, no common entry.
separateExample ∷ Text
separateExample =
  "{\"format\":1,\"id\":\"example_game\",\"tick_seconds\":\"0.01\",\"vms\":[\n\
  \  {\"role\":\"gameplay\",\"clock\":\"logical\",\"entry\":\"lua/game.lua\"},\n\
  \  {\"role\":\"presentation\",\"clock\":\"elapsed\",\"entry\":\"lua/ui.lua\"}\n\
  \]}"

-- | Presentation only, with a common entry.
presentationExample ∷ Text
presentationExample =
  "{\"format\":1,\"id\":\"example_game\",\"entry\":\"lua/ui.lua\",\"vms\":[\n\
  \  {\"role\":\"presentation\",\"clock\":\"elapsed\"}\n\
  \]}"

gameplayDeclaration, presentationDeclaration ∷ Maybe Text → Text
gameplayDeclaration entry = object (["\"role\":\"gameplay\"", "\"clock\":\"logical\""] <> entryMember entry)
presentationDeclaration entry = object (["\"role\":\"presentation\"", "\"clock\":\"elapsed\""] <> entryMember entry)

entryMember ∷ Maybe Text → [Text]
entryMember = maybe [] (\text → [member "entry" (quoted text)])

withVms ∷ [Text] → [Text] → Text
withVms others declarations = object (others <> [member "vms" ("[" <> foldr1 (\a b → a <> "," <> b) declarations <> "]")])

ok ∷ Text → Manifest
ok text = case parsed (bytes text) of
  Right manifest → manifest
  Left refusal → error ("expected a manifest, got " <> show refusal)

spec ∷ Spec
spec = describe "accepted manifests" $ do
  it "resolves both fixed roles from the common entry when vms is absent" $ do
    let manifest = ok defaultExample
    contentIdText (manifestId manifest) `shouldBe` "example_game"
    manifestCommonEntry manifest `shouldBe` Just "lua/main.lua"
    manifestRoles manifest
      `shouldBe` BothRoles
        (GameplayRole "lua/main.lua" CommonEntry (nanoseconds 10000000))
        (PresentationRole "lua/main.lua" CommonEntry)
    selectedRoles (manifestRoles manifest) `shouldBe` [Gameplay, Presentation]
    declaredEntries manifest `shouldBe` [DeclaredEntry CommonSlot "lua/main.lua"]

  it "resolves separate per-role entries with no common entry" $ do
    let manifest = ok separateExample
    manifestCommonEntry manifest `shouldBe` Nothing
    manifestRoles manifest
      `shouldBe` BothRoles
        (GameplayRole "lua/game.lua" ExplicitEntry (nanoseconds 10000000))
        (PresentationRole "lua/ui.lua" ExplicitEntry)
    declaredEntries manifest
      `shouldBe` [DeclaredEntry (RoleSlot Gameplay) "lua/game.lua", DeclaredEntry (RoleSlot Presentation) "lua/ui.lua"]

  it "resolves a presentation-only manifest with a common entry and no tick" $ do
    let manifest = ok presentationExample
    manifestRoles manifest `shouldBe` PresentationOnly (PresentationRole "lua/ui.lua" CommonEntry)
    selectedRoles (manifestRoles manifest) `shouldBe` [Presentation]

  it "resolves a gameplay-only manifest, which requires the tick, from the common entry" $ do
    let manifest = ok (withVms [member "format" "1", member "id" (quoted "g"), member "entry" (quoted "a.lua"), member "tick_seconds" (quoted "2")] [gameplayDeclaration Nothing])
    manifestRoles manifest `shouldBe` GameplayOnly (GameplayRole "a.lua" CommonEntry (nanoseconds 2000000000))
    selectedRoles (manifestRoles manifest) `shouldBe` [Gameplay]

  it "resolves a gameplay-only manifest from its own entry with no common entry" $ do
    let manifest = ok (withVms [member "format" "1", member "id" (quoted "g"), member "tick_seconds" (quoted "0.5")] [gameplayDeclaration (Just "g.lua")])
    manifestRoles manifest `shouldBe` GameplayOnly (GameplayRole "g.lua" ExplicitEntry (nanoseconds 500000000))
    manifestCommonEntry manifest `shouldBe` Nothing

  it "resolves a presentation-only manifest from its own entry with no common entry" $ do
    let manifest = ok (withVms [member "format" "1", member "id" (quoted "g")] [presentationDeclaration (Just "p.lua")])
    manifestRoles manifest `shouldBe` PresentationOnly (PresentationRole "p.lua" ExplicitEntry)

  it "lets an explicit per-role entry override the common entry for that role only" $ do
    let manifest = ok (withVms [member "format" "1", member "id" (quoted "g"), member "entry" (quoted "common.lua"), member "tick_seconds" (quoted "1")] [gameplayDeclaration (Just "own.lua"), presentationDeclaration Nothing])
    manifestRoles manifest
      `shouldBe` BothRoles
        (GameplayRole "own.lua" ExplicitEntry (nanoseconds 1000000000))
        (PresentationRole "common.lua" CommonEntry)
    declaredEntries manifest
      `shouldBe` [DeclaredEntry CommonSlot "common.lua", DeclaredEntry (RoleSlot Gameplay) "own.lua"]

  it "keeps a common entry that every role overrides among the declared entries" $ do
    let manifest = ok (withVms [member "format" "1", member "id" (quoted "g"), member "entry" (quoted "unused.lua"), member "tick_seconds" (quoted "1")] [gameplayDeclaration (Just "a.lua"), presentationDeclaration (Just "b.lua")])
    manifestCommonEntry manifest `shouldBe` Just "unused.lua"
    declaredEntries manifest
      `shouldBe` [ DeclaredEntry CommonSlot "unused.lua"
                 , DeclaredEntry (RoleSlot Gameplay) "a.lua"
                 , DeclaredEntry (RoleSlot Presentation) "b.lua"
                 ]

  it "keeps a shared entry as one authored text each role will load independently" $ do
    let manifest = ok (withVms [member "format" "1", member "id" (quoted "g"), member "tick_seconds" (quoted "1")] [gameplayDeclaration (Just "same.lua"), presentationDeclaration (Just "same.lua")])
    declaredEntries manifest
      `shouldBe` [DeclaredEntry (RoleSlot Gameplay) "same.lua", DeclaredEntry (RoleSlot Presentation) "same.lua"]
    fmap gameplayEntry (gameplayOf (manifestRoles manifest)) `shouldBe` Just "same.lua"
    fmap presentationEntry (presentationOf (manifestRoles manifest)) `shouldBe` Just "same.lua"

  it "resolves the two role declarations in either array order to the same configuration" $ do
    let others = [member "format" "1", member "id" (quoted "g"), member "tick_seconds" (quoted "0.25")]
        forward = ok (withVms others [gameplayDeclaration (Just "a.lua"), presentationDeclaration (Just "b.lua")])
        backward = ok (withVms others [presentationDeclaration (Just "b.lua"), gameplayDeclaration (Just "a.lua")])
    manifestRoles backward `shouldBe` manifestRoles forward
    declaredEntries backward `shouldBe` declaredEntries forward

  it "resolves any ordering of the root members to the same configuration" $ do
    let reference = sansBytes (ok defaultExample)
    allShouldBe (Right reference) (map (fmap sansBytes . parsed . document) (permutations baseMembers))

  it "resolves any ordering of a role declaration's members to the same configuration" $ do
    let others = [member "format" "1", member "id" (quoted "g"), member "tick_seconds" (quoted "1")]
        declaration order = object order
        members = ["\"role\":\"gameplay\"", "\"clock\":\"logical\"", member "entry" (quoted "a.lua")]
        reference = sansBytes (ok (withVms others [declaration members, presentationDeclaration (Just "b.lua")]))
    allShouldBe reference (map (\order → sansBytes (ok (withVms others [declaration order, presentationDeclaration (Just "b.lua")]))) (permutations members))

  it "keeps the exact supplied bytes, not a reserialization" $ do
    let spaced = bytes "  {\"format\" : 1.0 ,\n\t\"id\":\"example_game\",\"entry\":\"lua/\\u006dain.lua\",\"tick_seconds\":\"0.01\"}\r\n"
    fmap manifestBytes (parsed spaced) `shouldBe` Right spaced
    fmap manifestRoles (parsed spaced) `shouldBe` fmap manifestRoles (parsed (bytes defaultExample))

  it "decodes Unicode entry text and preserves it for later identity validation" $ do
    let entryOf text = fmap manifestCommonEntry (parsed (document [member "format" "1", member "id" (quoted "g"), member "entry" text, member "tick_seconds" (quoted "1")]))
    entryOf (quoted "lua/日本語.lua") `shouldBe` Right (Just "lua/日本語.lua")
    entryOf (quoted "lua/\\u65e5\\u672c.lua") `shouldBe` Right (Just "lua/日本.lua")
    entryOf (quoted "lua/\\ud83d\\ude00.lua") `shouldBe` Right (Just "lua/😀.lua")
    entryOf (quoted "lua/\\uD83D\\uDE00.lua") `shouldBe` Right (Just "lua/😀.lua")
    -- Neither composed nor decomposed spellings are normalised here.
    entryOf (quoted "caf\\u00e9") `shouldBe` Right (Just "caf\233")
    entryOf (quoted "cafe\\u0301") `shouldBe` Right (Just "cafe\769")

  it "decodes the single-character escapes and keeps a decoded NUL for the later path check" $ do
    let entryOf text = fmap manifestCommonEntry (parsed (document [member "format" "1", member "id" (quoted "g"), member "entry" text, member "tick_seconds" (quoted "1")]))
    entryOf (quoted "a\\\"\\\\\\/\\b\\f\\n\\r\\tz") `shouldBe` Right (Just "a\"\\/\b\f\n\r\tz")
    entryOf (quoted "a\\u0000b") `shouldBe` Right (Just "a\0b")

  it "preserves an empty or odd entry text, which only the later path check can judge" $ do
    let entryOf text = fmap manifestCommonEntry (parsed (document [member "format" "1", member "id" (quoted "g"), member "entry" text, member "tick_seconds" (quoted "1")]))
    entryOf (quoted "") `shouldBe` Right (Just "")
    entryOf (quoted "../a b/./c") `shouldBe` Right (Just "../a b/./c")

  it "reads an escaped spelling of a field name as that field" $
    fmap sansBytes (parsed (bytes "{\"\\u0066ormat\":1,\"i\\u0064\":\"example_game\",\"entry\":\"lua/main.lua\",\"tick_seconds\":\"0.01\"}"))
      `shouldBe` Right (sansBytes (ok defaultExample))
