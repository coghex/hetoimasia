-- | Vector arithmetic and checked normalization.
module Test.Math.Vector (spec) where

import Data.Maybe (isNothing)
import Hetoimasia.Math.Vector
  ( V2 (..)
  , V3 (..)
  , V4 (..)
  , add
  , cross
  , dot
  , norm
  , normalize
  , scale
  , sub
  )
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Hspec.QuickCheck (prop)
import Test.Math.Support
  ( approx
  , approxV3
  , extremeVector3
  , nonZeroVector3
  , shouldApproximate
  , vector3
  )
import Test.QuickCheck (Property, counterexample, forAll, (.&&.))

spec ∷ Spec
spec = describe "Vector" $ do
  describe "arithmetic" $ do
    it "adds, subtracts and scales componentwise" $ do
      V3 1 2 3 `add` V3 10 20 30 `shouldBe` V3 11 22 33
      V3 1 2 3 `sub` V3 10 20 30 `shouldBe` V3 (-9) (-18) (-27)
      scale 2 (V4 1 2 3 4) `shouldBe` V4 2 4 6 8
      V2 1 2 `add` V2 3 4 `shouldBe` V2 4 6

    it "takes dot products and lengths" $ do
      V3 1 2 3 `dot` V3 4 5 6 `shouldBe` 32
      norm (V2 3 4) `shouldBe` 5
      norm (V4 1 1 1 1) `shouldBe` 2

    it "crosses the unit axes right-handedly" $ do
      V3 1 0 0 `cross` V3 0 1 0 `shouldBe` V3 0 0 1
      V3 0 1 0 `cross` V3 0 0 1 `shouldBe` V3 1 0 0
      V3 0 0 1 `cross` V3 1 0 0 `shouldBe` V3 0 1 0

    prop "a cross product is perpendicular to both operands" $
      forAll vector3 $ \a → forAll vector3 $ \b →
        let c = a `cross` b
            tolerance = 1e-4 * max 1 (norm a * norm b * norm c)
         in abs (c `dot` a) <= tolerance && abs (c `dot` b) <= tolerance

    prop "subtraction undoes addition" $
      forAll vector3 $ \a → forAll vector3 $ \b →
        approxV3 ((a `add` b) `sub` b) a

  describe "normalize" $ do
    it "returns Nothing for a zero-length vector of each size" $ do
      normalize (V2 0 0) `shouldBe` Nothing
      normalize (V3 0 0 0) `shouldBe` Nothing
      normalize (V3 (-0) 0 (-0)) `shouldBe` Nothing
      normalize (V4 0 0 0 0) `shouldBe` Nothing

    it "returns Nothing for a NaN or infinite component" $ do
      normalize (V3 (0 / 0) 1 1) `shouldBe` Nothing
      normalize (V3 1 (1 / 0) 1) `shouldBe` Nothing
      normalize (V2 (-1 / 0) 0) `shouldBe` Nothing
      normalize (V4 1 1 1 (0 / 0)) `shouldSatisfy` isNothing

    it "normalizes vectors whose squared length would overflow or underflow" $ do
      normalize (V3 3.0e38 3.0e38 0) `shouldApproximateJust` V3 (sqrt 0.5) (sqrt 0.5) 0
      normalize (V3 1.0e-45 0 0) `shouldApproximateJust` V3 1 0 0
      normalize (V3 3.0e-40 4.0e-40 0) `shouldApproximateJust` V3 0.6 0.8 0

    prop "a nonzero vector normalizes to unit length in its own direction" $
      forAll nonZeroVector3 unitInDirection

    prop "never returns a non-finite result" $
      forAll extremeVector3 $ \v → case normalize v of
        Nothing → True
        Just (V3 x y z) → all (\c → not (isNaN c || isInfinite c)) [x, y, z]

shouldApproximateJust ∷ Maybe V3 → V3 → Expectation
shouldApproximateJust actual expected = case actual of
  Nothing → expectationFailure ("expected approximately " <> show expected <> ", got Nothing")
  Just v → shouldApproximate approxV3 v expected

unitInDirection ∷ V3 → Property
unitInDirection v = case normalize v of
  Nothing → counterexample "normalize returned Nothing" False
  Just u →
    counterexample (show u) $
      approx (norm u) 1 .&&. approxV3 (scale (norm v) u) v
