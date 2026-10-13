-- | The flags word: its bit layout for every sampler choice and flag
-- combination, the reserved bits, and the clip index in the top 16 bits.
--
-- __Layout under test.__ Bits 0–1 the sampler choice (0 default, 1 nearest,
-- 2 linear, 3 never produced), bit 2 translucent, bit 3 additive, bits 4–15 the
-- frame-table index (R2D-18, whose own examples are in "Test.Render.TwoD.Animation"),
-- bits 16–31 the clip index. The expected words are written
-- out by hand. A validated layer's clip index is always zero, so the clip
-- packing is checked on the flags word directly, where a clip index can be set,
-- and the encoded bytes are checked for every combination with clip zero.
module Test.Render.TwoD.Flags (spec) where

import Data.Bits (shiftR, testBit, (.&.))
import qualified Data.ByteString as ByteString
import Data.Word (Word16, Word32, Word8)
import Hetoimasia.Render.TwoD.Encoding (encodeLayer, flagsWord)
import Hetoimasia.Render.TwoD.Snapshot
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (forAll, property)
import Test.Render.TwoD.Support

spec ∷ Spec
spec = describe "Flags word" $ do
  samplerAndFlagsSpec
  clipSpec
  propertySpec

-- | Every sampler choice and flag combination with its flags word.
combinations ∷ [(Sampler, Bool, Bool, Word32)]
combinations =
  [ (SamplerDefault, False, False, 0x0)
  , (SamplerDefault, True, False, 0x4)
  , (SamplerDefault, False, True, 0x8)
  , (SamplerDefault, True, True, 0xC)
  , (SamplerNearest, False, False, 0x1)
  , (SamplerNearest, True, False, 0x5)
  , (SamplerNearest, False, True, 0x9)
  , (SamplerNearest, True, True, 0xD)
  , (SamplerLinear, False, False, 0x2)
  , (SamplerLinear, True, False, 0x6)
  , (SamplerLinear, False, True, 0xA)
  , (SamplerLinear, True, True, 0xE)
  ]

shaped ∷ Sampler → Bool → Bool → Instance
shaped sampler translucent additive =
  plainInstance
    { instanceSampler = sampler
    , instanceTranslucent = translucent
    , instanceAdditive = additive
    }

samplerAndFlagsSpec ∷ Spec
samplerAndFlagsSpec = describe "sampler choice, translucent and additive" $ do
  it "covers every combination" $
    length combinations `shouldBe` length ([minBound .. maxBound] ∷ [Sampler]) * 2 * 2

  mapM_
    ( \(sampler, translucent, additive, expected) →
        it ("packs " <> show sampler <> ", translucent " <> show translucent <> ", additive " <> show additive <> " as " <> show expected) $ do
          flagsWord (shaped sampler translucent additive) `shouldBe` expected
          -- The same word reaches bytes 56 to 59 of the encoded instance.
          let bytes = ByteString.unpack (encodeLayer (singleLayer (UiLayer [shaped sampler translucent additive])))
          take 4 (drop 56 bytes) `shouldBe` [fromIntegral expected, 0, 0, 0]
          -- An instance with no frame table has bits 4 to 15 and the whole clip field zero.
          expected .&. 0xFFFFFFF0 `shouldBe` 0
          -- The sampler code 3 is never produced.
          (expected .&. 3 /= 3) `shouldBe` True
    )
    combinations

clipSpec ∷ Spec
clipSpec = describe "the clip index" $ do
  it "occupies bits 16 to 31, so a shader reads it as flags >> 16" $
    mapM_
      (\(clip, expected) → flagsWord plainInstance {instanceClip = clip} `shouldBe` expected)
      [ (0, 0x00000000)
      , (1, 0x00010000)
      , (2, 0x00020000)
      , (0x00FF, 0x00FF0000)
      , (0x0100, 0x01000000)
      , (0x1234, 0x12340000)
      , (0x8000, 0x80000000)
      , (0xFFFF, 0xFFFF0000)
      ]

  it "leaves the sampler and flag bits alone" $ do
    flagsWord (shaped SamplerLinear False True) {instanceClip = 0x1234} `shouldBe` 0x1234000A
    flagsWord (shaped SamplerNearest True False) {instanceClip = 0xFFFF} `shouldBe` 0xFFFF0005
    flagsWord (shaped SamplerDefault True True) {instanceClip = 1} `shouldBe` 0x0001000C

  it "keeps bits 4 to 15 zero at the largest clip index with every flag set and no frame table" $
    (flagsWord (shaped SamplerLinear True True) {instanceClip = maxBound} `shiftR` 4) .&. 0xFFF
      `shouldBe` 0

propertySpec ∷ Spec
propertySpec = describe "over any instance" $ do
  prop "packs each field into its own bits, the frame-table index's low 12 bits in bits 4 to 15" $
    forAll anyInstance $ \candidate →
      let word = flagsWord candidate
          clip = fromIntegral (word `shiftR` 16) ∷ Word16
          code = fromIntegral (word .&. 3) ∷ Word8
       in property
            ( clip == instanceClip candidate
                && (word `shiftR` 4) .&. 0xFFF == fromIntegral (instanceFrameTable candidate .&. 0xFFF)
                && testBit word 2 == instanceTranslucent candidate
                && testBit word 3 == instanceAdditive candidate
                && code /= 3
                && code == samplerCode (instanceSampler candidate)
            )
  where
    samplerCode SamplerDefault = 0
    samplerCode SamplerNearest = 1
    samplerCode SamplerLinear = 2
