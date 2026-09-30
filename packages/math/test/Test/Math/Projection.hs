-- | The look-at view matrix and the perspective projection, under every
-- combination of the projection's clip conventions, and their degenerate
-- inputs.
module Test.Math.Projection (spec) where

import Control.Monad (forM_)
import qualified Data.List as List
import Data.Maybe (isNothing)
import Hetoimasia.Math.Matrix (Index (..), M44, apply, element, toColumnMajor)
import Hetoimasia.Math.Projection
  ( ClipY (..)
  , DepthRange (..)
  , Frustum (..)
  , lookAt
  , perspective
  )
import Hetoimasia.Math.Transform (translation)
import Hetoimasia.Math.Vector (V3 (..), V4 (..), add, cross, norm, scale, sub)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.Math.Support
  ( approx
  , approxM44
  , extreme
  , extremeVector3
  , finiteM44
  , shouldApproximate
  , vector3
  )
import Test.QuickCheck
  ( Gen
  , Property
  , Testable
  , choose
  , counterexample
  , frequency
  , forAll
  , property
  , suchThat
  )

spec ∷ Spec
spec = describe "Projection" $ do
  describe "lookAt" $ do
    it "matches a translation for an eye on +Z looking at the origin" $
      case lookAt (V3 0 0 5) (V3 0 0 0) (V3 0 1 0) of
        Nothing → expectationFailure "lookAt returned Nothing"
        Just view → shouldApproximate approxM44 view (translation (V3 0 0 (-5)))

    prop "maps the eye to the origin" $
      forAll scene $ \(eye, target, up) → withView eye target up $ \view →
        let V4 x y z w = apply view (point eye)
            close = within (magnitude eye target)
         in close x 0 && close y 0 && close z 0 && w == 1

    prop "maps the target onto −Z at its distance from the eye" $
      forAll scene $ \(eye, target, up) → withView eye target up $ \view →
        let V4 x y z w = apply view (point target)
            close = within (magnitude eye target)
         in close x 0 && close y 0 && close z (negate (norm (target `sub` eye))) && w == 1

    prop "maps the up vector into the +Y half of the view's YZ plane" $
      forAll scene $ \(eye, target, up) → withView eye target up $ \view →
        let V4 x y _ _ = apply view (point (eye `add` up))
         in within (magnitude eye target + norm up) x 0 && y > 0

    it "returns Nothing when the target is the eye" $
      lookAt (V3 1 2 3) (V3 1 2 3) (V3 0 1 0) `shouldBe` Nothing

    it "returns Nothing for a zero-length up vector" $
      lookAt (V3 0 0 5) (V3 0 0 0) (V3 0 0 0) `shouldBe` Nothing

    it "returns Nothing when up is parallel to the view direction" $ do
      lookAt (V3 0 0 5) (V3 0 0 0) (V3 0 0 1) `shouldBe` Nothing
      lookAt (V3 0 0 5) (V3 0 0 0) (V3 0 0 (-3)) `shouldBe` Nothing
      lookAt (V3 1 2 3) (V3 4 6 9) (V3 6 8 12) `shouldBe` Nothing
      lookAt (V3 0 0 0) (V3 1 0 0) (V3 1 1.0e-7 0) `shouldBe` Nothing

    it "returns Nothing for a non-finite input" $ do
      lookAt (V3 (0 / 0) 0 5) (V3 0 0 0) (V3 0 1 0) `shouldBe` Nothing
      lookAt (V3 0 0 5) (V3 0 (1 / 0) 0) (V3 0 1 0) `shouldBe` Nothing
      lookAt (V3 0 0 5) (V3 0 0 0) (V3 0 (1 / 0) 0) `shouldBe` Nothing

    it "accepts a view whose translations cancel within the largest Float" $
      matchesReference (V3 3.0e38 3.0e38 3.0e38) (V3 2.3333334e38 3.3333333e38 2.3333334e38) (V3 (-1) 2 2)

    it "accepts a view whose eye and target are further apart than the largest Float" $
      case lookAt (V3 0 0 2.0e38) (V3 0 0 (-2.0e38)) (V3 0 1 0) of
        Nothing → expectationFailure "lookAt returned Nothing"
        Just view → shouldApproximate approxM44 view (translation (V3 0 0 (-2.0e38)))

    -- A thousand cases rather than the default hundred: overflow-prone scenes
    -- are a minority of those generated.
    modifyMaxSuccess (max 1000) $
      prop "agrees with a double-precision reference at any scale" $
        forAll scaledScene $ \(eye, target, up) → agreesWithReference eye target up

    prop "never returns a non-finite matrix" $
      forAll extremeVector3 $ \eye → forAll extremeVector3 $ \target → forAll extremeVector3 $ \up →
        maybe True finiteM44 (lookAt eye target up)

  describe "perspective" $ do
    forM_ conventions $ \(range, clipY) →
      describe (show range <> ", " <> show clipY) $ do
        it "maps a right-angle frustum exactly as written" $
          case perspective range clipY (Frustum (pi / 2) 1 1 10) of
            Nothing → expectationFailure "perspective returned Nothing"
            Just m → do
              let V4 _ y _ w = apply m (V4 0 1 (-1) 1)
              y / w `shouldBe` top clipY
              w `shouldBe` 1

        prop "maps the near and far planes to the depth range's ends" $
          forAll frustum $ \f → withProjection range clipY f $ \m →
            approx (depth m (nearPlane f)) (nearEnd range)
              && approx (depth m (farPlane f)) 1

        prop "maps the top of the view to the chosen Y direction" $
          forAll frustum $ \f → withProjection range clipY f $ \m →
            let at distance =
                  let V4 _ y _ w = apply m (V4 0 (distance * tan (fieldOfViewY f / 2)) (negate distance) 1)
                   in y / w
             in approx (at (nearPlane f)) (top clipY) && approx (at (farPlane f)) (top clipY)

        prop "maps the right edge of the view to +X" $
          forAll frustum $ \f → withProjection range clipY f $ \m →
            let distance = nearPlane f
                edge = distance * tan (fieldOfViewY f / 2) * aspectRatio f
                V4 x _ _ w = apply m (V4 edge 0 (negate distance) 1)
             in approx (x / w) 1

        prop "sets w to the distance in front of the eye" $
          forAll frustum $ \f → forAll (choose (nearPlane f, farPlane f)) $ \distance →
            withProjection range clipY f $ \m →
              let V4 _ _ _ w = apply m (V4 1 1 (negate distance) 1)
               in approx w distance

        it "returns Nothing for a field of view outside (0, π)" $
          forM_ [0, -1, pi, 4, 0 / 0, 1 / 0] $ \fov →
            perspective range clipY (Frustum fov 1 1 10) `shouldBe` Nothing

        it "returns Nothing for a non-positive or non-finite aspect ratio" $
          forM_ [0, -1, 0 / 0, 1 / 0] $ \aspect →
            perspective range clipY (Frustum 1 aspect 1 10) `shouldBe` Nothing

        it "returns Nothing for a non-positive or non-finite near plane" $
          forM_ [0, -1, 0 / 0, -1 / 0] $ \near →
            perspective range clipY (Frustum 1 1 near 10) `shouldBe` Nothing

        it "returns Nothing for a far plane not beyond the near plane" $
          forM_ [1, 0.5, -10, 0 / 0, 1 / 0] $ \far →
            perspective range clipY (Frustum 1 1 1 far) `shouldBe` Nothing

        it "accepts planes near the largest Float, whose coefficients are finite" $
          case perspective range clipY (Frustum (pi / 2) 1 1.0e38 3.0e38) of
            Nothing → expectationFailure "perspective returned Nothing"
            Just m → do
              let (scaleExpected, offsetExpected) = case range of
                    ZeroToOne → (-1.5, -1.5e38)
                    NegativeOneToOne → (-2, -3.0e38)
              shouldApproximate approx (element I2 I2 m) scaleExpected
              shouldApproximate approx (element I2 I3 m) offsetExpected
              m `shouldSatisfy` finiteM44

        prop "accepts a valid frustum at any scale and maps its planes" $
          forAll scaledFrustum $ \f → withProjection range clipY f $ \m →
            finiteM44 m
              && approx (depth m (nearPlane f)) (nearEnd range)
              && approx (depth m (farPlane f)) 1

        prop "never returns a non-finite matrix" $
          forAll (Frustum <$> extreme <*> extreme <*> extreme <*> extreme) $ \f →
            maybe True finiteM44 (perspective range clipY f)
  where
    conventions = [(range, clipY) | range ← [minBound .. maxBound], clipY ← [minBound .. maxBound]]

-- | An eye, a target at least @0.01@ from it, and an up vector at least a
-- tenth of a radian's sine away from parallel to the view direction.
scene ∷ Gen (V3, V3, V3)
scene = do
  eye ← vector3
  target ← vector3 `suchThat` \t → norm (t `sub` eye) >= 0.01
  let direction = target `sub` eye
  up ← vector3 `suchThat` \u →
    norm u >= 0.01 && norm (direction `cross` u) >= 0.1 * norm direction * norm u
  pure (eye, target, up)

-- | A 'scene' scaled by a mantissa in @[1, 3.3]@ times a power of ten in
-- @[1e-30, 1e36]@, half the time in @[1e35, 1e36]@, where coordinates approach
-- the largest @Float@: there the difference between the eye and the target, a
-- translation's partial sums, or the translation itself can overflow.
scaledScene ∷ Gen (V3, V3, V3)
scaledScene = do
  (eye, target, up) ← scene
  mantissa ← choose (1, 3.3)
  exponent' ← frequency [(1, choose (-30, 36 ∷ Int)), (1, choose (35, 36))]
  let factor = mantissa * 10 ^^ exponent'
  pure (scale factor eye, scale factor target, scale factor up)

-- | The view matrix computed in @Double@, as its sixteen elements column by
-- column. @Double@ holds every intermediate a @Float@ scene produces without
-- overflow, so it tells a representable view from one that is not.
referenceView ∷ V3 → V3 → V3 → [Double]
referenceView eye target up =
  concat (List.transpose [translated side, translated upward, facing, [0, 0, 0, 1]])
  where
    e = wide eye
    forward = unit (wide target `minus` e)
    side = unit (forward `crossD` unit (wide up))
    upward = side `crossD` forward
    translated (x, y, z) = [x, y, z, negate (dotD (x, y, z) e)]
    facing = let (x, y, z) = forward in [negate x, negate y, negate z, dotD forward e]
    wide (V3 x y z) = (realToFrac x, realToFrac y, realToFrac z)
    minus (a, b, c) (x, y, z) = (a - x, b - y, c - z)
    dotD (a, b, c) (x, y, z) = a * x + b * y + c * z
    crossD (a, b, c) (x, y, z) = (b * z - c * y, c * x - a * z, a * y - b * x)
    unit v@(x, y, z) = let n = sqrt (dotD v v) in (x / n, y / n, z / n)

-- | 'lookAt' agrees with 'referenceView': a view whose reference elements all
-- lie well inside @Float@'s range must be returned and match it, one with an
-- element well outside must be 'Nothing', and near the boundary either is
-- acceptable.
agreesWithReference ∷ V3 → V3 → V3 → Property
agreesWithReference eye target up
  | all (\x → abs x <= 0.99 * largest) reference = case lookAt eye target up of
      Nothing → counterexample ("no view; reference " <> show reference) False
      Just view →
        let wrong = mismatches eye view reference
         in counterexample (show view <> "\nmismatched " <> show wrong) (null wrong)
  | any (\x → abs x > 1.01 * largest) reference =
      counterexample "an unrepresentable view was returned" (isNothing (lookAt eye target up))
  | otherwise = property True
  where
    reference = referenceView eye target up
    largest = realToFrac (3.4028235e38 ∷ Float)

-- | The view exists and agrees with 'referenceView'.
matchesReference ∷ V3 → V3 → V3 → Expectation
matchesReference eye target up = case lookAt eye target up of
  Nothing → expectationFailure "lookAt returned Nothing"
  Just view → do
    view `shouldSatisfy` finiteM44
    mismatches eye view (referenceView eye target up) `shouldBe` []

-- | The elements of a view, by column-major position, that differ from the
-- reference by more than @1e-4@, or, for the three translations, by more than
-- @1e-4@ of the eye's distance from the origin: the scale their rounding grows
-- with.
mismatches ∷ V3 → M44 → [Double] → [(Int, Float, Double)]
mismatches eye view reference =
  [ (index, actual, expected)
  | (index, actual, expected) ← zip3 [0 ..] (toColumnMajor view) reference
  , abs (realToFrac actual - expected) > tolerance index
  ]
  where
    tolerance index
      | index >= 12 && index < 15 = 1e-4 * max 1 distance
      | otherwise = 1e-4
    distance = let V3 x y z = eye in sqrt (sum [realToFrac c * realToFrac c | c ← [x, y, z]])

-- | A frustum in the ordinary domain: a field of view in @[0.1, 3]@, an
-- aspect ratio in @[0.1, 10]@, a near plane in @[0.01, 10]@, and a far plane
-- between 1.5 and 1000 times as far.
frustum ∷ Gen Frustum
frustum = do
  fov ← choose (0.1, 3)
  aspect ← choose (0.1, 10)
  near ← choose (0.01, 10)
  ratio ← choose (1.5, 1000)
  pure (Frustum fov aspect near (near * ratio))

-- | A valid frustum whose planes lie anywhere from about @1e-30@ to @3e37@:
-- the near plane a mantissa in @[1, 9.9]@ times a power of ten in
-- @[1e-30, 1e36]@, and the far plane 1.5 to 3 times as far. The ceiling keeps
-- the test's own evaluation of a far-plane point finite; the example above
-- covers planes near the largest @Float@.
scaledFrustum ∷ Gen Frustum
scaledFrustum = do
  fov ← choose (0.1, 3)
  aspect ← choose (0.1, 10)
  mantissa ← choose (1, 9.9)
  exponent' ← choose (-30, 36 ∷ Int)
  ratio ← choose (1.5, 3)
  let near = mantissa * 10 ^^ exponent'
  pure (Frustum fov aspect near (near * ratio))

-- | The normalized-device depth of the point on the view axis at a distance.
depth ∷ M44 → Float → Float
depth m distance =
  let V4 _ _ z w = apply m (V4 0 0 (negate distance) 1)
   in z / w

-- | The near plane's normalized-device depth.
nearEnd ∷ DepthRange → Float
nearEnd ZeroToOne = 0
nearEnd NegativeOneToOne = -1

-- | The normalized-device Y of the top of the view.
top ∷ ClipY → Float
top YUp = 1
top YDown = -1

point ∷ V3 → V4
point (V3 x y z) = V4 x y z 1

-- | The scale of a scene's coordinates, against which a view-space position is
-- compared: its error grows with the magnitudes the view matrix combines.
magnitude ∷ V3 → V3 → Float
magnitude eye target = norm eye + norm target

-- | Equal to within @1e-5@ of the scene's magnitude, or of 1 if that is
-- smaller.
within ∷ Float → Float → Float → Bool
within size a b = abs (a - b) <= 1e-5 * max 1 size

withView ∷ Testable p ⇒ V3 → V3 → V3 → (M44 → p) → Property
withView eye target up check = case lookAt eye target up of
  Nothing → counterexample ("no view for " <> show (eye, target, up)) False
  Just m → counterexample (show m) (property (check m))

withProjection ∷ Testable p ⇒ DepthRange → ClipY → Frustum → (M44 → p) → Property
withProjection range clipY f check = case perspective range clipY f of
  Nothing → counterexample ("no projection for " <> show f) False
  Just m → counterexample (show m) (property (check m))
