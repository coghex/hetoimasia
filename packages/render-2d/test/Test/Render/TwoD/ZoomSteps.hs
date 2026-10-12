-- | The application-wide discrete-step-zoom list: its default, every refusal
-- with the level it names, and the retention of every reason.
module Test.Render.TwoD.ZoomSteps (spec) where

import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Hetoimasia.Render.TwoD.ZoomSteps
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, choose, counterexample, elements, forAll, listOf, property, suchThat, (===))

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

  it "does not compare a level with a NaN neighbour, which has no order" $ do
    validateZoomSteps' [nan, 1] `shouldBe` Left [at 0 ZoomLevelInvalid]
    validateZoomSteps' [2, nan, 1] `shouldBe` Left [at 1 ZoomLevelInvalid]

  it "compares an infinite level like any other number, besides refusing it" $ do
    validateZoomSteps' [inf, 1] `shouldBe` Left [at 0 ZoomLevelInvalid, at 1 ZoomLevelNotIncreasing]
    validateZoomSteps' [1, inf] `shouldBe` Left [at 1 ZoomLevelInvalid]
    validateZoomSteps' [1, inf, inf] `shouldBe` Left [at 1 ZoomLevelInvalid, at 2 ZoomLevelInvalid, at 2 ZoomLevelNotIncreasing]
    validateZoomSteps' [-inf, 1] `shouldBe` Left [at 0 ZoomLevelInvalid]
    validateZoomSteps' [1, -inf] `shouldBe` Left [at 1 ZoomLevelInvalid, at 1 ZoomLevelNotIncreasing]

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

  describe "stepping" $ do
    let levels = defaultZoomSteps
        custom = either (error "invalid") id (validateZoomSteps [0.5, 1.5, 4])

    it "steps in to the smallest level greater than the zoom" $ do
      stepZoomIn levels 3 `shouldBe` 4
      stepZoomIn levels 3.5 `shouldBe` 4
      stepZoomIn levels 2.999 `shouldBe` 3
      stepZoomIn levels 1 `shouldBe` 2
      stepZoomIn custom 1 `shouldBe` 1.5
      stepZoomIn custom 1.5 `shouldBe` 4

    it "steps out to the largest level smaller than the zoom" $ do
      stepZoomOut levels 3 `shouldBe` 2
      stepZoomOut levels 3.5 `shouldBe` 3
      stepZoomOut levels 3.001 `shouldBe` 3
      stepZoomOut levels 8 `shouldBe` 7
      stepZoomOut custom 1 `shouldBe` 0.5
      stepZoomOut custom 1.5 `shouldBe` 0.5

    it "steps in to the largest level when none is greater" $ do
      stepZoomIn levels 8 `shouldBe` 8
      stepZoomIn levels 9 `shouldBe` 8
      stepZoomIn levels 1.0e30 `shouldBe` 8
      stepZoomIn custom 4 `shouldBe` 4

    it "steps out to the smallest level when none is smaller" $ do
      stepZoomOut levels 1 `shouldBe` 1
      stepZoomOut levels 0.5 `shouldBe` 1
      stepZoomOut levels 1.0e-30 `shouldBe` 1
      stepZoomOut custom 0.5 `shouldBe` 0.5

    it "steps from below the smallest level and above the largest" $ do
      stepZoomIn levels 0.25 `shouldBe` 1
      stepZoomIn levels 0 `shouldBe` 1
      stepZoomOut levels 8.5 `shouldBe` 8
      stepZoomOut levels 1.0e30 `shouldBe` 8

    it "gives the largest or the smallest level for a NaN zoom, which has no order" $ do
      stepZoomIn levels nan `shouldBe` 8
      stepZoomOut levels nan `shouldBe` 1

    it "steps through a one-level list to that level" $ do
      let one = either (error "invalid") id (validateZoomSteps [2])
      map (stepZoomIn one) [0.1, 2, 9] `shouldBe` [2, 2, 2]
      map (stepZoomOut one) [0.1, 2, 9] `shouldBe` [2, 2, 2]

    prop "always gives a level of the list" $
      forAll ((,) <$> validList <*> zoomValue) $ \(steps, zoom) →
        property (all (`elem` NonEmpty.toList (zoomLevels steps)) [stepZoomIn steps zoom, stepZoomOut steps zoom])

    prop "moves in the stated direction until the end of the list" $
      forAll ((,) <$> validList <*> zoomValue) $ \(steps, zoom) →
        let top = NonEmpty.last (zoomLevels steps)
            bottom = NonEmpty.head (zoomLevels steps)
         in property
              ( (stepZoomIn steps zoom > zoom || stepZoomIn steps zoom == top)
                  && (stepZoomOut steps zoom < zoom || stepZoomOut steps zoom == bottom)
              )

    prop "gives the neighbouring level, with nothing between" $
      forAll ((,) <$> validList <*> zoomValue) $ \(steps, zoom) →
        let ls = NonEmpty.toList (zoomLevels steps)
            up = stepZoomIn steps zoom
            down = stepZoomOut steps zoom
         in property
              ( not (any (\l → l > zoom && l < up) ls)
                  && not (any (\l → l < zoom && l > down) ls)
              )

    prop "steps in and then out, or out and then in, between levels" $
      forAll (validList `suchThat` ((> 1) . length . zoomLevels)) $ \steps →
        let ls = NonEmpty.toList (zoomLevels steps)
            inner = take (length ls - 2) (drop 1 ls)
         in property (all (\l → stepZoomOut steps (stepZoomIn steps l) == l && stepZoomIn steps (stepZoomOut steps l) == l) inner)

    prop "leaves smooth zoom alone: it is a plain value, and stepping reads it only" $
      forAll zoomValue $ \zoom → stepZoomIn levels zoom === stepZoomIn levels zoom

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

-- | A valid list: strictly increasing positive levels, one to six of them.
validList ∷ Gen ZoomSteps
validList = do
  count ← choose (1, 6 ∷ Int)
  increments ← mapM (const (choose (0.01, 5))) [1 .. count]
  either (error "invalid") pure (validateZoomSteps (scanl1 (+) increments))

-- | A zoom value anywhere a camera's might be, whole numbers and a level's
-- neighbours included.
zoomValue ∷ Gen Float
zoomValue = elements [0.001, 0.5, 1, 1.5, 2, 3, 3.5, 7.999, 8, 8.5, 100, 1.0e30] `orElse` choose (0.001, 20)
  where
    orElse a b = do
      pick ← choose (0, 1 ∷ Int)
      if pick == 0 then a else b

-- | A candidate list drawn from a pool that holds both valid and invalid
-- levels, in any order.
candidate ∷ Gen [Float]
candidate = listOf (elements [0.5, 1, 1, 2, 3, 4, 0, -1, 0 / 0, 1 / 0, -1 / 0, 1.0e-45])
