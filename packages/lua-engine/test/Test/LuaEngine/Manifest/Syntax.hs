{-# LANGUAGE OverloadedStrings #-}

-- | The manifest's syntax: the byte and nesting bounds, UTF-8 and the byte order
-- mark, RFC 8259's grammar and this profile's stricter refusals, duplicate keys
-- after escape decoding, and the order those refusals are decided in. Each
-- example here distinguishes a syntax refusal from the later schema refusal a
-- well-formed document would get.
module Test.LuaEngine.Manifest.Syntax (spec) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Manifest
import Hetoimasia.LuaEngine.Profile
import Test.Hspec
import Test.LuaEngine.Support

-- | The default example, as bytes.
valid ∷ ByteString
valid = document baseMembers

-- | A document with an extra member after the valid ones, written as JSON
-- text; a well-formed document with an unknown field is a schema refusal.
withExtra ∷ Text.Text → ByteString
withExtra extra = document (baseMembers <> [extra])

-- | The unknown field every well-formed 'withExtra' document is refused for.
unknownZzz ∷ Maybe SchemaError
unknownZzz = Just (UnknownField [] (Excerpt "zzz" False))

refusedAs ∷ ByteString → SyntaxError → Expectation
refusedAs input expected = parsed input `shouldBe` Left (ManifestSyntax expected)

-- | A profile with a manifest limit of the given bytes and nesting depth.
limitedProfile ∷ Word → Word → Profile
limitedProfile size depth = case validateProfile spec' of
  Right profile → profile
  Left refusal → error ("the test profile is not valid: " <> show refusal)
  where
    base = profileSpec fixedM1Profile
    spec' =
      base
        { specBytes = \limit → if limit == ManifestBytes then Bytes (fromIntegral size) else specBytes base limit
        , specCounts = \limit → if limit == ManifestDepth then Count (fromIntegral depth) else specCounts base limit
        }

spec ∷ Spec
spec = describe "manifest syntax" $ do
  describe "the byte limit" $ do
    it "accepts exactly 65,536 bytes, whitespace included" $ do
      let padded = valid <> ByteString.replicate (65536 - ByteString.length valid) 0x20
      ByteString.length padded `shouldBe` 65536
      -- Compared as a length and a flag: a mismatch must not print 64 KiB of bytes.
      fmap (ByteString.length . manifestBytes) (parsed padded) `shouldBe` Right 65536
      fmap ((== padded) . manifestBytes) (parsed padded) `shouldBe` Right True

    it "accepts 65,536 bytes of content, not only of whitespace" $ do
      let overhead = ByteString.length (document [member "format" "1", member "id" (quoted "g"), member "entry" (quoted "")])
          entry = Text.replicate (65536 - overhead) "a"
          input = document [member "format" "1", member "id" (quoted "g"), member "entry" (quoted entry)]
      ByteString.length input `shouldBe` 65536
      schemaRefusal input `shouldBe` Just TickRequired

    it "refuses 65,537 bytes as too large, without looking at them" $ do
      let padded = valid <> ByteString.replicate (65537 - ByteString.length valid) 0x20
      fmap (const ()) (parsed padded) `shouldBe` Left (ManifestTooLarge 65537 65536)
      fmap (const ()) (parsed (ByteString.replicate 65537 0xFF)) `shouldBe` Left (ManifestTooLarge 65537 65536)
      fmap (const ()) (parsed (ByteString.replicate (1024 * 1024) 0x5B)) `shouldBe` Left (ManifestTooLarge (1024 * 1024) 65536)

    it "applies a smaller injected limit at the limit and one past it" $ do
      let profile = limitedProfile 100 8
          exactly = valid <> ByteString.replicate (100 - ByteString.length valid) 0x20
      ByteString.length valid `shouldSatisfy` (< 100)
      fmap manifestBytes (parseManifestWith profile exactly) `shouldBe` Right exactly
      parseManifestWith profile (exactly <> " ") `shouldBe` Left (ManifestTooLarge 101 100)

  describe "the nesting limit" $ do
    let nested ∷ Int → ByteString
        nested containers = withExtra (member "zzz" (Text.replicate containers "[" <> "0" <> Text.replicate containers "]"))

    it "accepts eight containers, the outer object counting, and refuses the same document as a schema error" $
      schemaRefusal (nested 7) `shouldBe` unknownZzz

    it "refuses nine containers as syntax, at the container that is too deep" $ do
      let input = nested 8
          ninth = offsetOf "[[[[[[[[" input + 7
      input `refusedAs` NestingTooDeep ninth

    it "counts objects and arrays alike" $ do
      schemaRefusal (withExtra (member "zzz" "{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":0}}}}}}}")) `shouldBe` unknownZzz
      syntaxRefusal (withExtra (member "zzz" "{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":0}}}}}}}}")) `shouldSatisfy` isNesting
      syntaxRefusal (withExtra (member "zzz" "[{\"a\":[{\"a\":[{\"a\":[{\"a\":[0]}]}]}]}]")) `shouldSatisfy` isNesting

    it "bounds the recursion on input that only opens containers" $ do
      let input = bytes "{\"zzz\":" <> ByteString.replicate 60000 0x5B
      syntaxRefusal input `shouldSatisfy` isNesting

    it "decides nesting before a later duplicate key or trailing data" $ do
      let tooDeep = Text.replicate 8 "[" <> "0" <> Text.replicate 8 "]"
      syntaxRefusal (document [member "a" "1", member "a" "2", member "zzz" tooDeep]) `shouldSatisfy` isNesting
      syntaxRefusal (document [member "zzz" tooDeep] <> " x") `shouldSatisfy` isNesting

    it "applies a smaller injected depth at the limit and one past it" $ do
      let profile = limitedProfile 65536 3
      fmap (const ()) (parseManifestWith profile (withExtra (member "zzz" "[[0]]"))) `shouldBe` Left (ManifestSchema (UnknownField [] (Excerpt "zzz" False)))
      parseManifestWith profile (withExtra (member "zzz" "[[[0]]]")) `shouldSatisfy` isNestingResult

  describe "UTF-8 and the byte order mark" $ do
    it "refuses a byte order mark, even before a valid document" $ do
      (ByteString.pack [0xEF, 0xBB, 0xBF] <> valid) `refusedAs` ByteOrderMark
      ByteString.pack [0xEF, 0xBB, 0xBF] `refusedAs` ByteOrderMark

    it "refuses malformed UTF-8 wherever it is" $ do
      let inId byteString = ByteString.concat ["{\"format\":1,\"id\":\"", byteString, "\",\"entry\":\"e\",\"tick_seconds\":\"1\"}"]
      mapM_
        (\malformed → inId malformed `refusedAs` InvalidUtf8)
        [ ByteString.pack [0xFF]
        , ByteString.pack [0xC0, 0x80] -- overlong NUL
        , ByteString.pack [0xE2, 0x82] -- truncated three-byte sequence
        , ByteString.pack [0xED, 0xA0, 0x80] -- an encoded surrogate
        , ByteString.pack [0xF4, 0x90, 0x80, 0x80] -- above U+10FFFF
        , ByteString.pack [0x80] -- a lone continuation byte
        ]
      (valid <> ByteString.pack [0xFF]) `refusedAs` InvalidUtf8
      ByteString.pack [0x7B, 0xFF, 0x7D] `refusedAs` InvalidUtf8

    it "decides UTF-8 before any grammar error, however early the grammar error is" $ do
      ByteString.pack [0x5B, 0xFF] `refusedAs` InvalidUtf8
      ByteString.pack [0x7B, 0x7D, 0x7D, 0xFF] `refusedAs` InvalidUtf8

    it "accepts well-formed multi-byte text" $
      fmap manifestCommonEntry (parsed (document [member "format" "1", member "id" (quoted "g"), member "entry" (quoted "é日😀"), member "tick_seconds" (quoted "1")]))
        `shouldBe` Right (Just "é日😀")

  describe "RFC 8259 grammar" $ do
    it "refuses a root that is not an object, as syntax" $ do
      mapM_
        (\input → syntaxRefusal (bytes input) `shouldSatisfy` isRootNotObject)
        ["[]", "[{\"format\":1}]", "\"x\"", "1", "-1", "true", "false", "null", "  []", "\n\"x\""]
      "  []" `shouldRefuseAt` 2

    it "refuses empty and whitespace-only input as truncated" $ do
      "" `shouldRefuse` UnexpectedEnd 0
      " \t\r\n" `shouldRefuse` UnexpectedEnd 4

    it "refuses every proper prefix of a valid document as syntax" $ do
      let prefixes = [ByteString.take n valid | n ← [0 .. ByteString.length valid - 1]]
      length prefixes `shouldBe` ByteString.length valid
      mapM_ (\prefix → syntaxRefusal prefix `shouldSatisfy` (/= Nothing)) prefixes
      mapM_ (\prefix → schemaRefusal prefix `shouldBe` Nothing) prefixes

    it "refuses comments of every style" $ do
      "{/*c*/\"format\":1}" `shouldRefuse` UnexpectedByte 1 0x2F
      "{\"format\":1 // c\n}" `shouldRefuse` UnexpectedByte 12 0x2F
      "{\"format\":1} // c" `shouldRefuse` TrailingData 13
      "{# c\n\"format\":1}" `shouldRefuse` UnexpectedByte 1 0x23
      "/* c */{\"format\":1}" `shouldRefuseAt` 0

    it "refuses trailing commas in objects and arrays" $ do
      "{\"format\":1,}" `shouldRefuse` UnexpectedByte 12 0x7D
      "{\"format\":1,\"zzz\":[1,]}" `shouldRefuse` UnexpectedByte 21 0x5D
      "{,\"format\":1}" `shouldRefuse` UnexpectedByte 1 0x2C
      "{\"format\":1,,\"id\":\"g\"}" `shouldRefuse` UnexpectedByte 12 0x2C

    it "refuses missing colons, commas and misplaced punctuation" $ do
      "{\"format\" 1}" `shouldRefuse` UnexpectedByte 10 0x31
      "{\"format\":1 \"id\":\"g\"}" `shouldRefuse` UnexpectedByte 12 0x22
      "{\"format\"::1}" `shouldRefuse` UnexpectedByte 10 0x3A
      "{format:1}" `shouldRefuse` UnexpectedByte 1 0x66
      "{'format':1}" `shouldRefuse` UnexpectedByte 1 0x27
      "{\"format\":'1'}" `shouldRefuse` UnexpectedByte 10 0x27
      "{1:1}" `shouldRefuse` UnexpectedByte 1 0x31

    it "refuses data after the object, but not trailing whitespace" $ do
      (valid <> "x") `refusedAs` TrailingData (ByteString.length valid)
      (valid <> valid) `refusedAs` TrailingData (ByteString.length valid)
      (valid <> "{}") `refusedAs` TrailingData (ByteString.length valid)
      (valid <> "\0") `refusedAs` TrailingData (ByteString.length valid)
      (valid <> " \t\r\n ") `shouldSatisfy` ((== Right ()) . fmap (const ()) . parsed)

    it "refuses whitespace that is not JSON's four characters" $ do
      -- U+00A0, U+FEFF inside the text, vertical tab, form feed, U+2028.
      "{\xC2\xA0\"format\":1}" `shouldRefuse` UnexpectedByte 1 0xC2
      "{\x0B\"format\":1}" `shouldRefuse` UnexpectedByte 1 0x0B
      "{\x0C\"format\":1}" `shouldRefuse` UnexpectedByte 1 0x0C
      "{\"format\":\xEF\xBB\xBF\&1}" `shouldRefuse` UnexpectedByte 10 0xEF
      "{\"format\":1}\xE2\x80\xA8" `shouldRefuse` TrailingData 12

    it "refuses misspelled literals and names the byte that breaks them" $ do
      withExtra' "tru" `shouldSatisfy` isSyntax
      "{\"zzz\":truee}" `shouldRefuse` UnexpectedByte 11 0x65
      "{\"zzz\":True}" `shouldRefuse` UnexpectedByte 7 0x54
      "{\"zzz\":NULL}" `shouldRefuse` UnexpectedByte 7 0x4E
      "{\"zzz\":nul" `shouldRefuse` UnexpectedEnd 10
      "{\"zzz\":NaN}" `shouldRefuse` UnexpectedByte 7 0x4E
      "{\"zzz\":Infinity}" `shouldRefuse` UnexpectedByte 7 0x49
      "{\"zzz\":-Infinity}" `shouldRefuse` InvalidNumber 8

  describe "strings" $ do
    it "refuses an unescaped control character U+0000 to U+001F, and accepts U+007F" $ do
      mapM_
        (\code → ByteString.concat ["{\"format\":1,\"id\":\"a", ByteString.singleton code, "\"}"] `refusedAs` ControlCharacter 19)
        [0x00, 0x01, 0x09, 0x0A, 0x0D, 0x1F]
      ByteString.concat ["{\"format\":1,\"id\":\"a", ByteString.singleton 0x7F, "\"}"] `shouldSatisfy` ((== Nothing) . syntaxRefusal)
      "{\"a\x09\":1}" `shouldRefuse` ControlCharacter 3

    it "refuses an invalid escape" $ do
      "{\"zzz\":\"\\x\"}" `shouldRefuse` InvalidEscape 8
      "{\"zzz\":\"\\U0041\"}" `shouldRefuse` InvalidEscape 8
      "{\"zzz\":\"\\'\"}" `shouldRefuse` InvalidEscape 8
      "{\"zzz\":\"\\a\"}" `shouldRefuse` InvalidEscape 8
      "{\"zzz\":\"\\ \"}" `shouldRefuse` InvalidEscape 8

    it "refuses a truncated or malformed \\u escape" $ do
      "{\"zzz\":\"\\u12\"}" `shouldRefuse` InvalidEscape 8
      "{\"zzz\":\"\\u12G4\"}" `shouldRefuse` InvalidEscape 8
      "{\"zzz\":\"\\u\"}" `shouldRefuse` InvalidEscape 8
      "{\"zzz\":\"\\u00" `shouldRefuse` UnexpectedEnd 12
      "{\"zzz\":\"\\" `shouldRefuse` UnexpectedEnd 9
      "{\"zzz\":\"abc" `shouldRefuse` UnexpectedEnd 11

    it "refuses unpaired surrogate escapes in every position" $ do
      "{\"zzz\":\"\\ud800\"}" `shouldRefuse` UnpairedSurrogate 8
      "{\"zzz\":\"\\udbff\"}" `shouldRefuse` UnpairedSurrogate 8
      "{\"zzz\":\"\\udc00\"}" `shouldRefuse` UnpairedSurrogate 8
      "{\"zzz\":\"\\udfff\"}" `shouldRefuse` UnpairedSurrogate 8
      "{\"zzz\":\"\\ud800\\u0041\"}" `shouldRefuse` UnpairedSurrogate 8
      "{\"zzz\":\"\\ud800x\"}" `shouldRefuse` UnpairedSurrogate 8
      "{\"zzz\":\"\\ud800\\n\"}" `shouldRefuse` UnpairedSurrogate 8
      "{\"zzz\":\"\\ud800\\ud800\"}" `shouldRefuse` UnpairedSurrogate 8
      "{\"zzz\":\"\\ude00\\ud83d\"}" `shouldRefuse` UnpairedSurrogate 8
      "{\"\\ud800\":1}" `shouldRefuse` UnpairedSurrogate 2
      "{\"zzz\":\"\\ud800" `shouldRefuse` UnexpectedEnd 14

    it "accepts a valid surrogate pair and the boundary scalar values" $ do
      let entryOf text = fmap manifestCommonEntry (parsed (document [member "format" "1", member "id" (quoted "g"), member "entry" (quoted text), member "tick_seconds" (quoted "1")]))
      entryOf "\\ud800\\udc00" `shouldBe` Right (Just "\x10000")
      entryOf "\\udbff\\udfff" `shouldBe` Right (Just "\x10FFFF")
      entryOf "\\ud7ff\\ue000" `shouldBe` Right (Just "\xD7FF\xE000")

  describe "numbers" $ do
    it "refuses numbers outside the grammar as syntax, not as a wrong format" $ do
      "{\"format\":01}" `shouldRefuse` InvalidNumber 11
      "{\"format\":-01}" `shouldRefuse` InvalidNumber 12
      "{\"format\":00}" `shouldRefuse` InvalidNumber 11
      "{\"format\":+1}" `shouldRefuse` UnexpectedByte 10 0x2B
      "{\"format\":.5}" `shouldRefuse` UnexpectedByte 10 0x2E
      "{\"format\":1.}" `shouldRefuse` InvalidNumber 12
      "{\"format\":1.e5}" `shouldRefuse` InvalidNumber 12
      "{\"format\":1e}" `shouldRefuse` InvalidNumber 12
      "{\"format\":1e+}" `shouldRefuse` InvalidNumber 13
      "{\"format\":1E-}" `shouldRefuse` InvalidNumber 13
      "{\"format\":-}" `shouldRefuse` InvalidNumber 11
      "{\"format\":- 1}" `shouldRefuse` InvalidNumber 11
      "{\"format\":0x1}" `shouldRefuse` UnexpectedByte 11 0x78
      "{\"format\":1_0}" `shouldRefuse` UnexpectedByte 11 0x5F
      "{\"format\":NaN}" `shouldRefuse` UnexpectedByte 10 0x4E
      "{\"format\":Infinity}" `shouldRefuse` UnexpectedByte 10 0x49
      "{\"format\":1" `shouldRefuse` UnexpectedEnd 11
      "{\"format\":1." `shouldRefuse` UnexpectedEnd 12
      "{\"format\":1e" `shouldRefuse` UnexpectedEnd 12

    it "reads a very long numeric token in time bounded by the token, as syntax or schema" $ do
      let digits = Text.replicate 60000 "9"
      schemaRefusal (document [member "format" digits]) `shouldBe` Just UnsupportedFormat
      syntaxRefusal (document [member "format" (digits <> ".")]) `shouldBe` Just (InvalidNumber (offsetOf "." (bytes (object [member "format" (digits <> ".")]))  + 1))
      schemaRefusal (document [member "format" ("1e" <> digits)]) `shouldBe` Just UnsupportedFormat
      schemaRefusal (document [member "format" ("1e-" <> digits)]) `shouldBe` Just UnsupportedFormat

  describe "duplicate keys" $ do
    it "refuses a repeated key at the root, whatever the values" $ do
      syntaxRefusal (document [member "format" "1", member "id" (quoted "a"), member "id" (quoted "b")]) `shouldBe` Just (DuplicateKey [] (Excerpt "id" False))
      syntaxRefusal (document [member "format" "1", member "format" "2"]) `shouldBe` Just (DuplicateKey [] (Excerpt "format" False))
      syntaxRefusal (document [member "id" "null", member "id" "null"]) `shouldBe` Just (DuplicateKey [] (Excerpt "id" False))

    it "refuses keys that are equal only after escape decoding" $ do
      refusal "{\"id\":\"a\",\"\\u0069d\":\"b\"}" `shouldBe` Just (DuplicateKey [] (Excerpt "id" False))
      refusal "{\"i\\u0064\":\"a\",\"id\":\"b\"}" `shouldBe` Just (DuplicateKey [] (Excerpt "id" False))
      refusal "{\"\\u0069\\u0064\":\"a\",\"\\u0069d\":\"b\"}" `shouldBe` Just (DuplicateKey [] (Excerpt "id" False))
      refusal "{\"a/b\":1,\"a\\/b\":2}" `shouldBe` Just (DuplicateKey [] (Excerpt "a/b" False))
      refusal "{\"\\ud83d\\ude00\":1,\"\\uD83D\\uDE00\":2}" `shouldBe` Just (DuplicateKey [] (Excerpt "😀" False))
      refusal "{\"é\":1,\"\\u00e9\":2}" `shouldBe` Just (DuplicateKey [] (Excerpt "é" False))

    it "does not treat different decoded keys as duplicates" $ do
      refusal "{\"ID\":1,\"id\":2}" `shouldBe` Nothing
      refusal "{\"é\":1,\"e\\u0301\":2}" `shouldBe` Nothing
      refusal "{\"a\":1,\"a \":2}" `shouldBe` Nothing

    it "refuses a repeated key in a role object, citing its location" $ do
      let role extra = "{\"format\":1,\"id\":\"g\",\"vms\":[{\"role\":\"gameplay\",\"clock\":\"logical\"," <> extra <> "}]}"
      refusal (role "\"role\":\"presentation\"") `shouldBe` Just (DuplicateKey [PathKey (Excerpt "vms" False), PathIndex 0] (Excerpt "role" False))
      refusal (role "\"cl\\u006fck\":\"elapsed\"") `shouldBe` Just (DuplicateKey [PathKey (Excerpt "vms" False), PathIndex 0] (Excerpt "clock" False))
      refusal "{\"format\":1,\"id\":\"g\",\"vms\":[{\"role\":\"gameplay\",\"clock\":\"logical\"},{\"role\":\"presentation\",\"role\":\"gameplay\",\"clock\":\"elapsed\"}]}"
        `shouldBe` Just (DuplicateKey [PathKey (Excerpt "vms" False), PathIndex 1] (Excerpt "role" False))

    it "refuses a repeated key at any nesting, including in objects the schema would refuse anyway" $ do
      refusal "{\"zzz\":{\"a\":1,\"a\":2}}" `shouldBe` Just (DuplicateKey [PathKey (Excerpt "zzz" False)] (Excerpt "a" False))
      refusal "{\"zzz\":[{\"a\":{\"b\":1,\"b\":1}}]}"
        `shouldBe` Just (DuplicateKey [PathKey (Excerpt "zzz" False), PathIndex 0, PathKey (Excerpt "a" False)] (Excerpt "b" False))

    it "decides a duplicate before the schema, so a schema error cannot hide it" $ do
      -- Unknown field, wrong format and a duplicate all at once.
      refusal "{\"format\":\"1\",\"zzz\":1,\"id\":1,\"id\":2}" `shouldBe` Just (DuplicateKey [] (Excerpt "id" False))

    it "reports the first object in document order, then the first repeat in it" $ do
      refusal "{\"x\":{\"p\":1,\"p\":2},\"a\":1,\"a\":2}" `shouldBe` Just (DuplicateKey [] (Excerpt "a" False))
      refusal "{\"a\":1,\"b\":1,\"b\":2,\"a\":2}" `shouldBe` Just (DuplicateKey [] (Excerpt "b" False))

    it "cuts an overlong repeated key to the excerpt limit" $ do
      let key = Text.replicate 100 "k"
      syntaxRefusal (bytes ("{\"" <> key <> "\":1,\"" <> key <> "\":2}")) `shouldBe` Just (DuplicateKey [] (Excerpt (Text.replicate excerptLimit "k") True))

  describe "the order refusals are decided in" $ do
    it "decides UTF-8, then grammar, then duplicates, then trailing data, then the schema" $ do
      -- Grammar error after a duplicate: the grammar error comes first.
      "{\"a\":1,\"a\":2,}" `shouldRefuse` UnexpectedByte 13 0x7D
      -- Duplicate and trailing data: the duplicate comes first.
      refusal "{\"a\":1,\"a\":2} x" `shouldBe` Just (DuplicateKey [] (Excerpt "a" False))
      -- Trailing data and a schema error: the syntax error comes first.
      (document [member "format" "2"] <> "x") `refusedAs` TrailingData (ByteString.length (document [member "format" "2"]))

    it "keeps the byte limit ahead of everything" $
      fmap (const ()) (parsed (ByteString.replicate 65537 0x5B)) `shouldBe` Left (ManifestTooLarge 65537 65536)
  where
    -- Raw bytes: each character of the literal is one byte.
    raw ∷ String → ByteString
    raw = Char8.pack
    refusal ∷ Text.Text → Maybe SyntaxError
    refusal = syntaxRefusal . bytes
    shouldRefuse ∷ String → SyntaxError → Expectation
    shouldRefuse text expected = parsed (raw text) `shouldBe` Left (ManifestSyntax expected)
    shouldRefuseAt ∷ String → Int → Expectation
    shouldRefuseAt text offset = syntaxRefusal (raw text) `shouldSatisfy` atOffset offset
    atOffset offset result = case result of
      Just (RootNotObject at) → at == offset
      Just (UnexpectedByte at _) → at == offset
      _ → False
    isNesting result = case result of
      Just (NestingTooDeep _) → True
      _ → False
    isNestingResult result = case result of
      Left (ManifestSyntax (NestingTooDeep _)) → True
      _ → False
    isRootNotObject result = case result of
      Just (RootNotObject _) → True
      _ → False
    isSyntax result = case result of
      Left (ManifestSyntax _) → True
      _ → False
    withExtra' value = parsed (document (baseMembers <> [member "zzz" value]))
