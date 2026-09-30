-- | Translation, scaling and checked rotation, and the order in which composed
-- transforms apply.
module Test.Math.Transform (spec) where

import Hetoimasia.Math.Matrix (M44, apply, identity, multiply)
import Hetoimasia.Math.Transform (rotation, scaling, translation)
import Hetoimasia.Math.Vector (V3 (..), V4 (..), norm, scale)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.Math.Support
  ( angle
  , approx
  , approxM44
  , approxV4
  , component
  , extreme
  , extremeVector3
  , finiteM44
  , nonZeroVector3
  , shouldApproximate
  , vector3
  )
import Test.QuickCheck (Property, Testable, counterexample, forAll, property, suchThat)

spec ∷ Spec
spec = describe "Transform" $ do
  describe "translation" $ do
    it "moves a point and leaves a direction unchanged" $ do
      apply (translation (V3 1 2 3)) (V4 10 20 30 1) `shouldBe` V4 11 22 33 1
      apply (translation (V3 1 2 3)) (V4 10 20 30 0) `shouldBe` V4 10 20 30 0

    prop "by an offset and its negation compose to the identity" $
      forAll vector3 $ \v →
        approxM44 (multiply (translation v) (translation (scale (-1) v))) identity

  describe "scaling" $ do
    it "scales each axis by its own factor" $
      apply (scaling (V3 2 3 4)) (V4 1 1 1 1) `shouldBe` V4 2 3 4 1

    prop "by reciprocal factors composes to the identity" $
      forAll nonZeroFactors $ \(V3 x y z) →
        approxM44 (multiply (scaling (V3 x y z)) (scaling (V3 (1 / x) (1 / y) (1 / z)))) identity

  describe "composition" $
    it "applies the right operand first" $ do
      let point = V4 1 0 0 1
          move = translation (V3 1 0 0)
          double = scaling (V3 2 2 2)
      apply (multiply move double) point `shouldBe` V4 3 0 0 1
      apply (multiply double move) point `shouldBe` V4 4 0 0 1

  describe "rotation" $ do
    it "turns a quarter turn about each axis by the right-hand rule" $ do
      rotated (V3 0 0 1) (pi / 2) (V4 1 0 0 0) `approximates` V4 0 1 0 0
      rotated (V3 1 0 0) (pi / 2) (V4 0 1 0 0) `approximates` V4 0 0 1 0
      rotated (V3 0 1 0) (pi / 2) (V4 0 0 1 0) `approximates` V4 1 0 0 0
      rotated (V3 0 0 1) (-pi / 2) (V4 1 0 0 0) `approximates` V4 0 (-1) 0 0

    it "leaves a point on its axis fixed" $
      rotated (V3 1 1 1) 1.234 (V4 2 2 2 1) `approximates` V4 2 2 2 1

    prop "preserves length" $
      forAll nonZeroVector3 $ \axis → forAll angle $ \theta → forAll vector3 $ \(V3 x y z) →
        withRotation axis theta $ \m →
          let V4 a b c _ = apply m (V4 x y z 0)
           in approx (norm (V3 a b c)) (norm (V3 x y z))

    prop "by an angle and its negation compose to the identity" $
      forAll nonZeroVector3 $ \axis → forAll angle $ \theta →
        withRotation axis theta $ \forward →
          withRotation axis (negate theta) $ \backward →
            approxM44 (multiply forward backward) identity

    prop "about a non-unit axis equals rotation about the unit axis" $
      forAll nonZeroVector3 $ \axis → forAll angle $ \theta →
        withRotation axis theta $ \m →
          withRotation (scale (1 / norm axis) axis) theta $ \unit →
            approxM44 m unit

    it "returns Nothing for a zero-length or non-finite axis" $ do
      rotation (V3 0 0 0) 1 `shouldBe` Nothing
      rotation (V3 (0 / 0) 0 1) 1 `shouldBe` Nothing
      rotation (V3 0 (1 / 0) 0) 1 `shouldBe` Nothing

    it "returns Nothing for a non-finite angle" $ do
      rotation (V3 0 0 1) (0 / 0) `shouldBe` Nothing
      rotation (V3 0 0 1) (1 / 0) `shouldBe` Nothing
      rotation (V3 0 0 1) (-1 / 0) `shouldBe` Nothing

    prop "never returns a non-finite matrix" $
      forAll extremeVector3 $ \axis → forAll extreme $ \theta →
        maybe True finiteM44 (rotation axis theta)
  where
    nonZeroFactors = V3 <$> factor <*> factor <*> factor
    factor = component `suchThat` \x → abs x >= 0.01

-- | The rotation of a vector, which must exist.
rotated ∷ V3 → Float → V4 → Maybe V4
rotated axis theta v = (`apply` v) <$> rotation axis theta

-- | The rotation exists and its result approximates the expected vector.
approximates ∷ Maybe V4 → V4 → Expectation
approximates actual expected = case actual of
  Nothing → expectationFailure "the rotation returned Nothing"
  Just v → shouldApproximate approxV4 v expected

-- | A property of a rotation that must exist.
withRotation ∷ Testable p ⇒ V3 → Float → (M44 → p) → Property
withRotation axis theta check = case rotation axis theta of
  Nothing → counterexample ("no rotation for " <> show (axis, theta)) False
  Just m → counterexample (show m) (property (check m))
