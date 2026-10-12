-- | Construction and access through the backend-facing module, and the
-- comparison, ordering and 'show' instances game code relies on.
--
-- __Boundaries.__ The examples fix the 'Word32' edges by hand: zero, one, the
-- middle, the largest value and the one below it, in every pairing of index
-- and generation. The properties then draw from the whole range, with the same
-- edges weighted in.
module Test.Render.Api.Handle (spec) where

import Data.Word (Word32)
import Hetoimasia.Render.Api.Texture.Backend (handleGeneration, handleIndex, textureHandle)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, arbitrary, elements, forAll, frequency)

spec ∷ Spec
spec = describe "TextureHandle" $ do
  describe "construction and access" $ do
    it "reads back the index and the generation it was built from, at every edge pair" $
      mapM_
        ( \(index, generation) → do
            handleIndex (textureHandle index generation) `shouldBe` index
            handleGeneration (textureHandle index generation) `shouldBe` generation
        )
        [(index, generation) | index ← edges, generation ← edges]

    it "keeps the two numbers apart" $ do
      let handle = textureHandle 7 9
      handleIndex handle `shouldBe` 7
      handleGeneration handle `shouldBe` 9

    it "accepts a zero generation, which a backend resolves to its placeholder" $
      handleGeneration (textureHandle 3 0) `shouldBe` 0

    prop "round-trips any index and generation" $
      forAll word $ \index → forAll word $ \generation →
        (handleIndex (textureHandle index generation), handleGeneration (textureHandle index generation))
          == (index, generation)

  describe "equality" $ do
    it "holds only when both numbers agree" $ do
      textureHandle 1 2 `shouldBe` textureHandle 1 2
      (textureHandle 1 2 == textureHandle 1 3) `shouldBe` False
      (textureHandle 1 2 == textureHandle 2 2) `shouldBe` False
      (textureHandle 1 2 == textureHandle 2 1) `shouldBe` False

    prop "agrees with equality of the two numbers" $
      forAll word $ \i → forAll word $ \g → forAll word $ \j → forAll word $ \h →
        (textureHandle i g == textureHandle j h) == ((i, g) == (j, h))

  describe "ordering" $ do
    it "orders by index first, then by generation" $ do
      compare (textureHandle 1 9) (textureHandle 2 0) `shouldBe` LT
      compare (textureHandle 2 0) (textureHandle 1 9) `shouldBe` GT
      compare (textureHandle 4 1) (textureHandle 4 2) `shouldBe` LT
      compare (textureHandle 4 2) (textureHandle 4 2) `shouldBe` EQ

    it "orders at the Word32 edges without wrapping" $ do
      compare (textureHandle maxBound 0) (textureHandle 0 maxBound) `shouldBe` GT
      compare (textureHandle 0 maxBound) (textureHandle 1 0) `shouldBe` LT
      maximum [textureHandle (maxBound - 1) maxBound, textureHandle maxBound 0]
        `shouldBe` textureHandle maxBound 0

    prop "agrees with the order of the two numbers" $
      forAll word $ \i → forAll word $ \g → forAll word $ \j → forAll word $ \h →
        compare (textureHandle i g) (textureHandle j h) == compare (i, g) (j, h)

  describe "show" $ do
    it "prints both numbers, the index first" $ do
      show (textureHandle 3 1) `shouldBe` "TextureHandle {handleIndex = 3, handleGeneration = 1}"
      show (textureHandle maxBound 0)
        `shouldBe` "TextureHandle {handleIndex = 4294967295, handleGeneration = 0}"

    it "parenthesises inside a larger value" $
      show (Just (textureHandle 1 2))
        `shouldBe` "Just (TextureHandle {handleIndex = 1, handleGeneration = 2})"

    it "distinguishes handles that differ in either number" $ do
      (show (textureHandle 1 2) == show (textureHandle 2 1)) `shouldBe` False
      (show (textureHandle 1 2) == show (textureHandle 1 3)) `shouldBe` False

-- | The values at the edges of 'Word32', plus a few ordinary ones.
edges ∷ [Word32]
edges = [0, 1, 2, 0x7fffffff, 0x80000000, maxBound - 1, maxBound]

-- | A 'Word32' with the edges weighted in.
word ∷ Gen Word32
word = frequency [(2, elements edges), (3, arbitrary)]
