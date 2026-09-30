-- | Matrix identities, element access, and the column-vector multiplication
-- order.
module Test.Math.Matrix (spec) where

import Hetoimasia.Math.Matrix
  ( Index (..)
  , apply
  , columns
  , element
  , fromColumns
  , fromRows
  , identity
  , multiply
  , rows
  , toColumnMajor
  , transpose
  )
import Hetoimasia.Math.Vector (V4 (..))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.Math.Support (matrix, vector4)
import Test.QuickCheck (forAll, (.&&.), (===))

spec ∷ Spec
spec = describe "Matrix" $ do
  describe "identity" $ do
    prop "is a left and right identity for multiplication" $
      forAll matrix $ \m →
        multiply identity m === m .&&. multiply m identity === m

    prop "leaves every vector unchanged" $
      forAll vector4 $ \v → apply identity v === v

  describe "transpose" $ do
    prop "of a transpose is the original" $
      forAll matrix $ \m → transpose (transpose m) === m

    prop "swaps rows and columns" $
      forAll matrix $ \m → rows (transpose m) === columns m

    prop "of a product reverses it" $
      forAll matrix $ \a → forAll matrix $ \b →
        let lhs = toColumnMajor (transpose (multiply a b))
            rhs = toColumnMajor (multiply (transpose b) (transpose a))
         in lhs === rhs

  describe "element access" $ do
    it "reads rows and columns of a matrix built from rows" $ do
      let m = fromRows (V4 0 1 2 3) (V4 10 11 12 13) (V4 20 21 22 23) (V4 30 31 32 33)
      element I0 I3 m `shouldBe` 3
      element I3 I0 m `shouldBe` 30
      element I2 I1 m `shouldBe` 21
      columns m `shouldBe` (V4 0 10 20 30, V4 1 11 21 31, V4 2 12 22 32, V4 3 13 23 33)

    it "lists elements column by column" $
      toColumnMajor (fromColumns (V4 0 1 2 3) (V4 4 5 6 7) (V4 8 9 10 11) (V4 12 13 14 15))
        `shouldBe` [0 .. 15]

    prop "puts element (r, c) at position 4c + r of the column-major list" $
      forAll matrix $ \m →
        [element r c m | c ← [minBound .. maxBound], r ← [minBound .. maxBound]]
          === toColumnMajor m

    prop "agrees with fromColumns and fromRows" $
      forAll vector4 $ \a → forAll vector4 $ \b → forAll vector4 $ \c → forAll vector4 $ \d →
        fromRows a b c d === transpose (fromColumns a b c d)

  describe "multiplication" $ do
    it "multiplies a column vector on the matrix's right" $ do
      let m = fromRows (V4 1 2 0 0) (V4 0 1 0 0) (V4 0 0 1 0) (V4 0 0 0 1)
      apply m (V4 0 1 0 0) `shouldBe` V4 2 1 0 0
      apply m (V4 1 0 0 0) `shouldBe` V4 1 0 0 0

    it "applies the right operand first" $ do
      let shear = fromRows (V4 1 1 0 0) (V4 0 1 0 0) (V4 0 0 1 0) (V4 0 0 0 1)
          swap = fromRows (V4 0 1 0 0) (V4 1 0 0 0) (V4 0 0 1 0) (V4 0 0 0 1)
      apply (multiply shear swap) (V4 1 0 0 0) `shouldBe` V4 1 1 0 0
      apply (multiply swap shear) (V4 1 0 0 0) `shouldBe` V4 0 1 0 0

    prop "a product applies as its factors in turn" $
      forAll matrix $ \a → forAll matrix $ \b → forAll vector4 $ \v →
        approxProduct (apply (multiply a b) v) (apply a (apply b v))

-- | Equal to within @1e-5@ of the largest magnitude either grouping can reach:
-- elements and components of at most 100 give terms of up to @1.6e7@, which
-- single precision rounds at about 1.
approxProduct ∷ V4 → V4 → Bool
approxProduct (V4 a b c d) (V4 x y z w) =
  and (zipWith (\p q → abs (p - q) <= 1.6e7 * 1e-5) [a, b, c, d] [x, y, z, w])
