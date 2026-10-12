-- | The 2×3 affine transform: its coefficient convention, the order in which
-- composed transforms apply, and the checked inverse and rotation.
--
-- __Domain.__ The round-trip properties build a transform as a translation of
-- up to 10, a rotation of up to two turns and a scale of 0.5 to 2 on each axis,
-- in either sign, and apply it to points within 10 of the origin, so
-- single-precision rounding stays well inside 'approx'. The extreme generator
-- reaches zeros, subnormals, the largest finite values, infinities and NaN, and
-- is used only where the contract is that a checked result is 'Nothing' or
-- finite.
module Test.Math.Affine2 (spec) where

import Hetoimasia.Math.Affine2
  ( Affine2
  , applyPoint
  , columns
  , compose
  , fromColumns
  , identity
  , inverse
  , rotation
  , scaling
  , toColumnMajor
  , translation
  )
import Hetoimasia.Math.Vector (V2 (..))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Hspec.QuickCheck (prop)
import Test.Math.Support (angle, approx, extreme, shouldApproximate)
import Test.QuickCheck (Gen, Property, Testable, choose, counterexample, elements, forAll, property)

spec ∷ Spec
spec = describe "Affine2" $ do
  coefficientsSpec
  constructionSpec
  compositionSpec
  inverseSpec
  rotationSpec

-- | A transform whose six coefficients are all different, so a swapped pair
-- of them changes every example that reads them.
distinct ∷ Affine2
distinct = fromColumns (V2 2 3) (V2 5 7) (V2 11 13)

coefficientsSpec ∷ Spec
coefficientsSpec = describe "coefficients" $ do
  it "maps (x, y) to (a x + c y + tx, b x + d y + ty)" $
    -- a = 2, b = 3, c = 5, d = 7, tx = 11, ty = 13
    applyPoint distinct (V2 1 10) `shouldBe` V2 (2 * 1 + 5 * 10 + 11) (3 * 1 + 7 * 10 + 13)

  it "lists them as [a, b, c, d, tx, ty], column by column" $ do
    toColumnMajor distinct `shouldBe` [2, 3, 5, 7, 11, 13]
    columns distinct `shouldBe` (V2 2 3, V2 5 7, V2 11 13)

  it "shows the expression that builds it" $
    show distinct `shouldBe` "fromColumns (V2 2.0 3.0) (V2 5.0 7.0) (V2 11.0 13.0)"

  it "has the identity leave every point where it is" $ do
    applyPoint identity (V2 (-3) 4) `shouldBe` V2 (-3) 4
    toColumnMajor identity `shouldBe` [1, 0, 0, 1, 0, 0]

constructionSpec ∷ Spec
constructionSpec = describe "construction" $ do
  it "translates a point by the offset" $
    applyPoint (translation (V2 3 (-4))) (V2 1 1) `shouldBe` V2 4 (-3)

  it "scales each axis by its own factor" $ do
    applyPoint (scaling (V2 2 3)) (V2 5 7) `shouldBe` V2 10 21
    toColumnMajor (scaling (V2 2 3)) `shouldBe` [2, 0, 0, 3, 0, 0]

  it "stores a translation in the last column" $
    toColumnMajor (translation (V2 3 (-4))) `shouldBe` [1, 0, 0, 1, 3, -4]

compositionSpec ∷ Spec
compositionSpec = describe "composition" $ do
  it "applies the right operand first" $ do
    let unitX = V2 1 0
        move = translation (V2 1 0)
        double = scaling (V2 2 2)
    applyPoint (compose move double) unitX `shouldBe` V2 3 0
    applyPoint (compose double move) unitX `shouldBe` V2 4 0

  it "does not commute for a rotation and a translation" $ do
    let move = translation (V2 1 0)
    turn ← required (rotation (pi / 2))
    -- Rotate first: (1, 0) → (0, 1), then move: (1, 1).
    shouldApproximate approxPoint (applyPoint (compose move turn) (V2 1 0)) (V2 1 1)
    -- Move first: (1, 0) → (2, 0), then rotate: (0, 2).
    shouldApproximate approxPoint (applyPoint (compose turn move) (V2 1 0)) (V2 0 2)

  it "carries the translation through the left operand's linear part" $
    toColumnMajor (compose (scaling (V2 2 3)) (translation (V2 5 7)))
      `shouldBe` [2, 0, 0, 3, 10, 21]

  it "has the identity as both a left and a right unit" $ do
    compose identity distinct `shouldBe` distinct
    compose distinct identity `shouldBe` distinct

  prop "is associative" $
    forAll transform $ \f → forAll transform $ \g → forAll transform $ \h → forAll point $ \p →
      approxPoint
        (applyPoint (compose f (compose g h)) p)
        (applyPoint (compose (compose f g) h) p)

  prop "applies as the two applications in turn" $
    forAll transform $ \f → forAll transform $ \g → forAll point $ \p →
      approxPoint (applyPoint (compose f g) p) (applyPoint f (applyPoint g p))

inverseSpec ∷ Spec
inverseSpec = describe "inverse" $ do
  it "undoes a translation and a scaling exactly" $ do
    inverse (translation (V2 3 (-4))) `shouldBe` Just (translation (V2 (-3) 4))
    inverse (scaling (V2 2 4)) `shouldBe` Just (scaling (V2 0.5 0.25))
    inverse identity `shouldBe` Just identity

  it "carries the translation through the inverse linear part" $
    -- Scaled by (2, 4) and then moved by (6, 8); undoing the move leaves the
    -- scaled frame to undo, so the inverse's translation is (-3, -2).
    inverse (compose (translation (V2 6 8)) (scaling (V2 2 4)))
      `shouldBe` Just (compose (scaling (V2 0.5 0.25)) (translation (V2 (-6) (-8))))

  it "inverts a transform whose six coefficients are all different" $ do
    inverted ← required (inverse distinct)
    -- The determinant is 2 * 7 - 3 * 5 = -1.
    toColumnMajor inverted `shouldBe` [-7, 3, 5, -2, 11 * 7 - 13 * 5, -(11 * 3 - 13 * 2)]

  prop "round-trips a point through a transform and its inverse, in either order" $
    forAll transform $ \f → forAll point $ \p →
      withInverse f $ \g →
        approxPoint (applyPoint g (applyPoint f p)) p
          && approxPoint (applyPoint f (applyPoint g p)) p

  prop "composes with its inverse to the identity" $
    forAll transform $ \f →
      withInverse f $ \g →
        approxCoefficients (compose f g) identity && approxCoefficients (compose g f) identity

  prop "inverts back to the original" $
    forAll transform $ \f →
      withInverse f $ \g → case inverse g of
        Nothing → counterexample "the inverse of an inverse was Nothing" False
        Just back → property (approxCoefficients back f)

  describe "returns Nothing" $ do
    it "for a singular transform" $ do
      inverse (fromColumns (V2 1 2) (V2 2 4) (V2 0 0)) `shouldBe` Nothing
      inverse (scaling (V2 0 1)) `shouldBe` Nothing
      inverse (scaling (V2 1 (-0))) `shouldBe` Nothing
      inverse (fromColumns (V2 0 0) (V2 0 0) (V2 5 5)) `shouldBe` Nothing
      -- A zero column with a translation still collapses the plane.
      inverse (fromColumns (V2 3 0) (V2 0 0) (V2 1 1)) `shouldBe` Nothing

    it "for a transform whose two linear columns are equal" $
      inverse (fromColumns (V2 3 5) (V2 3 5) (V2 0 0)) `shouldBe` Nothing

    it "for a NaN or infinite coefficient, wherever it sits" $
      mapM_
        (\(position, value) → inverse (withCoefficient position value) `shouldBe` Nothing)
        [ (position, value)
        | position ← [0 .. 5]
        , value ← [0 / 0, 1 / 0, -1 / 0]
        ]

    it "when a coefficient of the inverse is too large for a Float" $ do
      -- 1e-39 is a subnormal Float whose reciprocal, 1e39, exceeds the largest.
      inverse (scaling (V2 1.0e-39 1)) `shouldBe` Nothing
      -- A translation of 1e30 through a linear part of 1e-30 would have to be
      -- undone by 1e60.
      inverse (fromColumns (V2 1.0e-30 0) (V2 0 1.0e-30) (V2 1.0e30 0)) `shouldBe` Nothing

  describe "returns Just" $
    it "wherever the inverse can be represented, however the product would have gone" $ do
      -- The determinant, 1e60, overflows a Float; the inverse, 1e-30, does not.
      large ← required (inverse (scaling (V2 1.0e30 1.0e30)))
      toColumnMajor large `shouldSatisfy` all id . zipWith near [1.0e-30, 0, 0, 1.0e-30, 0, 0]
      -- The determinant, 1e-60, underflows a Float to zero; the inverse, 1e30,
      -- does not, and the transform is not singular.
      small ← required (inverse (scaling (V2 1.0e-30 1.0e-30)))
      toColumnMajor small `shouldSatisfy` all id . zipWith near [1.0e30, 0, 0, 1.0e30, 0, 0]

  prop "never returns a non-finite transform" $
    forAll (fromColumns <$> extremeVector <*> extremeVector <*> extremeVector) $ \f →
      maybe True (all finite . toColumnMajor) (inverse f)
  where
    -- All coefficients 1 except the one at this position in the column-major list.
    withCoefficient ∷ Int → Float → Affine2
    withCoefficient position value =
      fromColumns (V2 (at 0) (at 1)) (V2 (at 2) (at 3)) (V2 (at 4) (at 5))
      where
        at i = if i == position then value else 1
    extremeVector = V2 <$> extreme <*> extreme

rotationSpec ∷ Spec
rotationSpec = describe "rotation" $ do
  it "takes +X toward +Y by a positive quarter turn" $ do
    quarter ← required (rotation (pi / 2))
    shouldApproximate approxPoint (applyPoint quarter (V2 1 0)) (V2 0 1)
    shouldApproximate approxPoint (applyPoint quarter (V2 0 1)) (V2 (-1) 0)

  it "turns the other way by a negative angle" $ do
    quarter ← required (rotation (-pi / 2))
    shouldApproximate approxPoint (applyPoint quarter (V2 1 0)) (V2 0 (-1))

  it "leaves the origin fixed and the identity at angle zero" $ do
    none ← required (rotation 0)
    none `shouldBe` identity

  it "stores its coefficients as [cos, sin, -sin, cos, 0, 0]" $ do
    turned ← required (rotation 0.5)
    shouldApproximate approxCoefficients turned (fromColumns (V2 (cos 0.5) (sin 0.5)) (V2 (negate (sin 0.5)) (cos 0.5)) (V2 0 0))

  prop "composes with the rotation by the negated angle to the identity" $
    forAll angle $ \theta → forAll point $ \p →
      withRotation theta $ \forward → withRotation (negate theta) $ \backward →
        approxPoint (applyPoint (compose forward backward) p) p

  prop "preserves length" $
    forAll angle $ \theta → forAll point $ \p@(V2 x y) →
      withRotation theta $ \turned →
        let V2 x' y' = applyPoint turned p
         in approx (sqrt (x' * x' + y' * y')) (sqrt (x * x + y * y))

  it "returns Nothing for a non-finite angle" $ do
    rotation (0 / 0) `shouldBe` Nothing
    rotation (1 / 0) `shouldBe` Nothing
    rotation (-1 / 0) `shouldBe` Nothing

  prop "never returns a non-finite transform" $
    forAll extreme $ \theta →
      maybe True (all finite . toColumnMajor) (rotation theta)

-- | Neither NaN nor an infinity.
finite ∷ Float → Bool
finite x = not (isNaN x || isInfinite x)

-- | A well-conditioned transform: translation, rotation and scale composed.
transform ∷ Gen Affine2
transform = do
  offset ← V2 <$> choose (-10, 10) <*> choose (-10, 10)
  theta ← angle
  sx ← factor
  sy ← factor
  case rotation theta of
    Nothing → pure identity
    Just turn →
      pure (compose (translation offset) (compose turn (scaling (V2 sx sy))))
  where
    factor = do
      magnitude ← choose (0.5, 2)
      sign ← elements [1, -1]
      pure (sign * magnitude)

-- | A point within 10 of the origin on each axis.
point ∷ Gen V2
point = V2 <$> choose (-10, 10) <*> choose (-10, 10)

approxPoint ∷ V2 → V2 → Bool
approxPoint (V2 a b) (V2 x y) = approx a x && approx b y

-- | Equal within one part in 100,000 of the expected value, or both zero.
near ∷ Float → Float → Bool
near actual expected
  | expected == 0 = actual == 0
  | otherwise = abs (actual - expected) <= 1e-5 * abs expected

approxCoefficients ∷ Affine2 → Affine2 → Bool
approxCoefficients a b = and (zipWith approx (toColumnMajor a) (toColumnMajor b))

-- | The value of a checked operation that must have produced one.
required ∷ Maybe a → IO a
required = maybe (fail "the checked operation returned Nothing") pure

-- | A property of an inverse that must exist.
withInverse ∷ Testable p ⇒ Affine2 → (Affine2 → p) → Property
withInverse f check = case inverse f of
  Nothing → counterexample ("no inverse for " <> show f) False
  Just g → counterexample (show g) (property (check g))

-- | A property of a rotation that must exist.
withRotation ∷ Testable p ⇒ Float → (Affine2 → p) → Property
withRotation theta check = case rotation theta of
  Nothing → counterexample ("no rotation for " <> show theta) False
  Just turned → counterexample (show turned) (property (check turned))
