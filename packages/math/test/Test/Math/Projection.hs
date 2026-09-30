-- | The look-at view matrix and the perspective projection, under every
-- combination of the projection's clip conventions, and their degenerate
-- inputs.
module Test.Math.Projection (spec) where

import Control.Monad (forM_)
import Hetoimasia.Math.Matrix (M44, apply)
import Hetoimasia.Math.Projection
  ( ClipY (..)
  , DepthRange (..)
  , Frustum (..)
  , lookAt
  , perspective
  )
import Hetoimasia.Math.Transform (translation)
import Hetoimasia.Math.Vector (V3 (..), V4 (..), add, cross, norm, sub)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
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
