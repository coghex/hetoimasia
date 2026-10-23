-- | Bounded values without an interpreter: the encoding the boundary uses, the
-- schemas values are checked against, and the limits, pinned at the bound and one
-- past it.
--
-- The reader on Lua's side is exercised through real calls in
-- "Test.Lua.Boundary.Bindings"; what is checked here is the half that is plain
-- data, so the rules and the limits are testable on their own.
module Test.Lua.Boundary.Values (spec) where

import qualified Data.ByteString as ByteString
import Data.Either (isLeft)
import qualified Data.Text as Text
import Data.Word (Word32)
import Hetoimasia.Scripting.Lua.Internal.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

here ∷ VmIdentity
here = VmIdentity 7

-- | A context in which @ticket@ is handle type 0 and @badge@ is 1.
context ∷ Context
context = Context here names numbers
  where
    names (0 ∷ Word32) = Just "ticket"
    names 1 = Just "badge"
    names _ = Nothing
    numbers "ticket" = Just 0
    numbers "badge" = Just 1
    numbers _ = Nothing

limits ∷ ValueLimits
limits = defaultValueLimits

-- | A capability comes back stamped with the VM that issued it.
stamped ∷ Value → Value
stamped = \case
  VCapability capability' → VCapability capability' {capabilityIssuer = Just here}
  other → other

-- | Cross a value out and back in: encode it, decode what was encoded, check it
-- against the schema.
crossed ∷ Schema → Value → Either String Value
crossed schema value = do
  bytes ← either (Left . show) Right (encodeValues context limits [value])
  raws ← either (Left . Text.unpack) Right (decodeValues 1 bytes)
  case raws of
    [raw] → either (Left . show) Right (conformRaw context schema raw)
    _ → Left "not one value"

spec ∷ Spec
spec = describe "values and schemas" $ do
  describe "limits" $ do
    it "accepts each limit from 1 to its maximum" $ do
      valueLimits 1 1 1 `shouldBe` Right (ValueLimits 1 1 1)
      valueLimits (limitBytes valueLimitMaxima) (limitDepth valueLimitMaxima) (limitElements valueLimitMaxima)
        `shouldBe` Right valueLimitMaxima
      valueLimitMaxima `shouldBe` ValueLimits 16777216 64 1048576
      defaultValueLimits `shouldBe` ValueLimits 65536 8 4096

    it "refuses a limit below 1 or above its maximum" $ do
      valueLimits 0 1 1 `shouldBe` Left (LimitTooSmall "bytes" 0)
      valueLimits 1 0 1 `shouldBe` Left (LimitTooSmall "depth" 0)
      valueLimits 1 1 0 `shouldBe` Left (LimitTooSmall "elements" 0)
      valueLimits 16777217 1 1 `shouldBe` Left (LimitTooLarge "bytes" 16777217 16777216)
      valueLimits 1 65 1 `shouldBe` Left (LimitTooLarge "depth" 65 64)
      valueLimits 1 1 1048577 `shouldBe` Left (LimitTooLarge "elements" 1048577 1048576)

  describe "the encoding" $ do
    it "round trips every kind of value, 64-bit integers exactly and floats as floats" $ do
      let cases ∷ [(Schema, Value)]
          cases =
            [ (SNil, VNil)
            , (SBoolean, VBoolean True)
            , (SBoolean, VBoolean False)
            , (SInteger, VInteger minBound)
            , (SInteger, VInteger maxBound)
            , (SInteger, VInteger 0)
            , (SFloat, VFloat 0.1)
            , (SFloat, VFloat (-0.0))
            , (SFloat, VFloat (1 / 0))
            , (SNumber, VInteger 3)
            , (SNumber, VFloat 3)
            , (SBytes, VBytes (ByteString.pack [0, 255, 10]))
            , (SText, VText "h\233llo \128512")
            , (SText, VText "")
            , (SList SInteger, VList [])
            , (SList SNumber, VList [VInteger 1, VFloat 2.5])
            , (SRecord [("a", SInteger), ("b", SOptional SText)], VRecord [("a", VInteger 1), ("b", VNil)])
            , (SOptional SText, VNil)
            , (SOptional SText, VText "x")
            , (SCapability "ticket", VCapability (Capability "ticket" 99 Nothing))
            ]
      mapM_ (\(schema, value) → crossed schema value `shouldBe` Right (stamped value)) cases

    it "keeps an integer and a float apart even when they are equal as numbers" $ do
      crossed SNumber (VInteger 3) `shouldBe` Right (VInteger 3)
      crossed SNumber (VFloat 3) `shouldBe` Right (VFloat 3)
      crossed SInteger (VFloat 3) `shouldSatisfy` isLeft
      crossed SFloat (VInteger 3) `shouldSatisfy` isLeft

    it "keeps byte strings and text apart, refusing invalid UTF-8 where text is declared" $ do
      let encoded value = either (error . show) id (encodeValues context limits [value])
          invalid = ByteString.pack [0xff, 0xfe]
      crossed SBytes (VBytes invalid) `shouldBe` Right (VBytes invalid)
      case decodeValues 1 (encoded (VBytes invalid)) of
        Right [raw] → conformRaw context SText raw `shouldBe` Left ([], RuleInvalidUtf8)
        other → expectationFailure ("not one value: " <> show other)

    it "rejects an encoding that is malformed rather than trusting it" $ do
      let good = either (error . show) id (encodeValues context limits [VList [VInteger 1]])
      decodeValues 1 (ByteString.init good) `shouldSatisfy` isLeft
      decodeValues 1 (good <> ByteString.pack [0]) `shouldSatisfy` isLeft
      decodeValues 1 (ByteString.pack [0x99]) `shouldSatisfy` isLeft
      decodeValues 1 ByteString.empty `shouldSatisfy` isLeft
      decodeValues 2 good `shouldSatisfy` isLeft

  describe "limits on a copy about to cross" $ do
    let encodedWith bytes depth elements values = encodeValues context (ValueLimits bytes depth elements) values
        integers n = VList (replicate n (VInteger 1))
    it "is bounded in bytes, at the bound and one past" $ do
      -- A list of n integers is 5 + 18n bytes.
      encodedWith 59 8 4096 [integers 3] `shouldSatisfy` (not . isLeft)
      encodedWith 59 8 4096 [integers 4] `shouldBe` Left (RuleBytesLimit 59)
      -- The limit covers every value of a crossing together.
      encodedWith 18 8 4096 [VInteger 1, VInteger 2] `shouldSatisfy` (not . isLeft)
      encodedWith 17 8 4096 [VInteger 1, VInteger 2] `shouldBe` Left (RuleBytesLimit 17)
      encodedWith 15 8 4096 [VText (Text.replicate 10 "x")] `shouldSatisfy` (not . isLeft)
      encodedWith 15 8 4096 [VText (Text.replicate 11 "x")] `shouldBe` Left (RuleBytesLimit 15)

    it "is bounded in elements, at the bound and one past" $ do
      encodedWith 65536 8 11 [integers 10] `shouldSatisfy` (not . isLeft)
      encodedWith 65536 8 11 [integers 11] `shouldBe` Left (RuleElementLimit 11)

    it "bounds the inspection of nil record fields, which the encoding omits" $ do
      let sentinel = error "inspected past the limits"
          tailed = [("a", VNil), ("b", VNil), ("c", VNil)] ++ sentinel
      encodedWith 65536 8 2 [VRecord tailed] `shouldBe` Left (RuleElementLimit 2)
      encodedWith 65536 8 2 [VRecord (repeat ("a", VNil))] `shouldBe` Left (RuleElementLimit 2)
      checkLimits (ValueLimits 65536 8 2) [VRecord (repeat ("a", VNil))] `shouldBe` Left (RuleElementLimit 2)
      checkLimits (ValueLimits 65536 8 2) [VList (repeat VNil)] `shouldBe` Left (RuleElementLimit 2)

    it "counts the context record the Lua-first facade hands its builder: 142 bytes at the smallest identity bound, four elements, one level, at the bound and one past" $ do
      let record = VRecord [("role", VText "presentation"), ("content_id", VText (Text.replicate 64 "c")), ("instance_id", VText "inst-1")]
      -- five for the record; for each field five and its name, and five and its length for the text
      valuesFootprint (ValueLimits 65536 8 4096) [record] `shouldBe` Right (5 + (5 + 4) + (5 + 12) + (5 + 10) + (5 + 64) + (5 + 11) + (5 + 6))
      valuesFootprint (ValueLimits 65536 8 4096) [record] `shouldBe` Right 142
      checkLimits (ValueLimits 142 1 4) [record] `shouldBe` Right ()
      checkLimits (ValueLimits 141 1 4) [record] `shouldBe` Left (RuleBytesLimit 141)
      checkLimits (ValueLimits 142 1 3) [record] `shouldBe` Left (RuleElementLimit 3)
      checkLimits (ValueLimits 142 1 4) [VList [record]] `shouldBe` Left (RuleDepthLimit 1)

    it "is bounded in depth, at the bound and one past" $ do
      encodedWith 65536 2 4096 [VList [VList [VInteger 1]]] `shouldSatisfy` (not . isLeft)
      encodedWith 65536 2 4096 [VList [VList [VList []]]] `shouldBe` Left (RuleDepthLimit 2)
      encodedWith 65536 1 4096 [VInteger 1] `shouldSatisfy` (not . isLeft)

  describe "schemas" $ do
    let against schema value = conformValue context schema value
    it "accepts what conforms and says where what does not" $ do
      let record = SRecord [("name", SText), ("tags", SList SText), ("note", SOptional SInteger)]
      against record (VRecord [("name", VText "n"), ("tags", VList [VText "a"])]) `shouldBe` Right ()
      against record (VRecord [("name", VText "n"), ("tags", VList [VText "a", VInteger 1])])
        `shouldBe` Left ([AtField "tags", AtIndex 2], RuleWrongType "text" "integer")
      against record (VRecord [("tags", VList [])]) `shouldBe` Left ([], RuleMissingField "name")
      against record (VRecord [("name", VText "n"), ("tags", VList []), ("extra", VNil)]) `shouldBe` Left ([], RuleUnknownField "extra")
      against record (VRecord [("name", VText "n"), ("name", VText "m"), ("tags", VList [])]) `shouldBe` Left ([], RuleDuplicateField "name")

    it "refuses a nil where a table cannot keep one, and omits an optional field that is nil" $ do
      against (SList (SOptional SInteger)) (VList [VInteger 1, VNil]) `shouldBe` Left ([AtIndex 2], RuleNilInTable)
      against (SRecord [("a", SInteger)]) (VRecord [("a", VNil)]) `shouldBe` Left ([AtField "a"], RuleNilInTable)
      against (SRecord [("a", SOptional SInteger)]) (VRecord [("a", VNil)]) `shouldBe` Right ()
      encodeValues context limits [VList [VInteger 1, VNil]] `shouldBe` Left RuleNilInTable
      -- A nil field is absent in the encoding, so it comes back absent and nil.
      crossed (SRecord [("a", SOptional SInteger)]) (VRecord [("a", VNil)]) `shouldBe` Right (VRecord [("a", VNil)])
      encodeValues context limits [VRecord [("a", VNil)]] `shouldBe` encodeValues context limits [VRecord []]

    it "checks a capability against the issuing VM and the type" $ do
      against (SCapability "ticket") (VCapability (Capability "ticket" 1 Nothing)) `shouldBe` Right ()
      against (SCapability "ticket") (VCapability (Capability "ticket" 1 (Just here))) `shouldBe` Right ()
      against (SCapability "ticket") (VCapability (Capability "ticket" 1 (Just (VmIdentity 8)))) `shouldBe` Left ([], RuleForeignHandle)
      against (SCapability "ticket") (VCapability (Capability "badge" 1 Nothing)) `shouldBe` Left ([], RuleHandleType "ticket" "badge")
      against (SCapability "unknown") (VCapability (Capability "unknown" 1 Nothing)) `shouldBe` Left ([], RuleUnknownCapability "unknown")

    it "reads a raw copy by the same rules" $ do
      let raw = conformRaw context
      raw SInteger (RFloat 1) `shouldBe` Left ([], RuleFloatForInteger)
      raw SInteger (RInteger 1) `shouldBe` Right (VInteger 1)
      raw (SList SInteger) (RTable [(KeyInteger 2, RInteger 1), (KeyInteger 1, RInteger 2)]) `shouldBe` Right (VList [VInteger 2, VInteger 1])
      raw (SList SInteger) (RTable [(KeyInteger 1, RInteger 1), (KeyInteger 3, RInteger 3)]) `shouldBe` Left ([], RuleNotASequence)
      raw (SList SInteger) (RTable [(KeyString "a", RInteger 1)]) `shouldBe` Left ([], RuleNotASequence)
      raw (SCapability "ticket") (RHandle 7 0 5) `shouldBe` Right (VCapability (Capability "ticket" 5 (Just here)))
      raw (SCapability "ticket") (RHandle 8 0 5) `shouldBe` Left ([], RuleForeignHandle)
      raw (SCapability "ticket") (RHandle 7 1 5) `shouldBe` Left ([], RuleHandleType "ticket" "badge")
      raw (SCapability "ticket") (RInteger 5) `shouldBe` Left ([], RuleWrongType "capability ticket" "integer")
      raw SText (RString (ByteString.pack [0xc0, 0x80])) `shouldBe` Left ([], RuleInvalidUtf8)
