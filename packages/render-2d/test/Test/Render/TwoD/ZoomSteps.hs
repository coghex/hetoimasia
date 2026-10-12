-- | The application-wide discrete-step-zoom list: its default, every refusal
-- with the level it names, and the retention of every reason.
module Test.Render.TwoD.ZoomSteps (spec) where

import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Hetoimasia.Render.TwoD.ZoomSteps
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, counterexample, elements, forAll, listOf, property)

spec ∷ Spec
spec = describe "ZoomSteps" $ do
  it "defaults to the whole numbers 1 to 8" $
    NonEmpty.toList (zoomLevels defaultZoomSteps) `shouldBe` [1, 2, 3, 4, 5, 6, 7, 8]

  it "accepts the default list as a candidate" $
    fmap zoomLevels (validateZoomSteps [1 .. 8]) `shouldBe` Right (zoomLevels defaultZoomSteps)

  describe "accepts" $ do
    it "one level" $
      fmap zoomLevels (validateZoomSteps [0.25]) `shouldBe` Right (0.25 :| [])
    it "fractions and large values, strictly increasing, unchanged and in order" $
      fmap zoomLevels (validateZoomSteps [0.5, 1, 1.5, 3, 1.0e30])
        `shouldBe` Right (0.5 :| [1, 1.5, 3, 1.0e30])
    it "the smallest positive level" $
      fmap zoomLevels (validateZoomSteps [1.0e-45, 1]) `shouldBe` Right (1.0e-45 :| [1])

  describe "refuses, naming the level" $
    mapM_
      (\(name, levels, expected) → it ("a candidate with " <> name) $ validateZoomSteps' levels `shouldBe` Left expected)
      refusalCases

  it "does not compare a level with a non-finite neighbour, which is refused already" $ do
    validateZoomSteps' [nan, 1] `shouldBe` Left [at 0 ZoomLevelInvalid]
    validateZoomSteps' [2, nan, 1] `shouldBe` Left [at 1 ZoomLevelInvalid]
    validateZoomSteps' [inf, 1] `shouldBe` Left [at 0 ZoomLevelInvalid]

  it "reports every reason together, in the order of the levels" $
    validateZoomSteps' [0, nan, 2, 1, -1, 1, 1]
      `shouldBe` Left
        [ at 0 ZoomLevelInvalid
        , at 1 ZoomLevelInvalid
        , at 3 ZoomLevelNotIncreasing
        , at 4 ZoomLevelInvalid
        , at 4 ZoomLevelNotIncreasing
        , at 6 ZoomLevelNotIncreasing
        ]

  it "is exercised for every reason it can give" $
    sort (nub [zoomRefusalReason refusal | (_, _, expected) ← refusalCases, refusal ← expected])
      `shouldBe` [minBound .. maxBound]

  prop "accepts exactly the non-empty, finite, positive, strictly increasing lists" $
    forAll candidate $ \levels →
      let oracle =
            not (null levels)
              && all (\x → not (isNaN x || isInfinite x) && x > 0) levels
              && and (zipWith (<) levels (drop 1 levels))
       in case validateZoomSteps levels of
            Right accepted →
              counterexample (show levels) (property (oracle && NonEmpty.toList (zoomLevels accepted) == levels))
            Left refused → counterexample (show (levels, refused)) (property (not oracle))

  prop "answers the same way twice" $
    forAll candidate $ \levels → property (validateZoomSteps levels == validateZoomSteps levels)

at ∷ Int → ZoomReason → ZoomRefusal
at index = ZoomRefusal (AtLevel index)

nan, inf ∷ Float
nan = 0 / 0
inf = 1 / 0

-- | Each candidate list and the exact refusals it must produce.
refusalCases ∷ [(String, [Float], [ZoomRefusal])]
refusalCases =
  [ ("an empty list", [], [ZoomRefusal WholeList ZoomListEmpty])
  , ("a zero level", [0], [at 0 ZoomLevelInvalid])
  , ("a negative level", [1, 2, -3], [at 2 ZoomLevelInvalid, at 2 ZoomLevelNotIncreasing])
  , ("a NaN level", [1, nan, 3], [at 1 ZoomLevelInvalid])
  , ("an infinite level", [1, inf], [at 1 ZoomLevelInvalid])
  , ("a negative infinite level", [-inf], [at 0 ZoomLevelInvalid])
  , ("an equal level", [1, 2, 2], [at 2 ZoomLevelNotIncreasing])
  , ("a decreasing level", [3, 2, 4], [at 1 ZoomLevelNotIncreasing])
  , ("a second level below the first", [2, 1], [at 1 ZoomLevelNotIncreasing])
  , ("a decrease after a long increase", [1, 2, 3, 4, 5, 6, 7, 6.5], [at 7 ZoomLevelNotIncreasing])
  ]

validateZoomSteps' ∷ [Float] → Either [ZoomRefusal] [Float]
validateZoomSteps' levels = case validateZoomSteps levels of
  Left refused → Left (NonEmpty.toList refused)
  Right accepted → Right (NonEmpty.toList (zoomLevels accepted))

-- | A candidate list drawn from a pool that holds both valid and invalid
-- levels, in any order.
candidate ∷ Gen [Float]
candidate = listOf (elements [0.5, 1, 1, 2, 3, 4, 0, -1, 0 / 0, 1 / 0, -1 / 0, 1.0e-45])
