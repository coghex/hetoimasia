-- | The pixel-snapping function: its rounding at every half boundary, signed
-- ties, values the rounding of @x + 0.5@ would move, large and non-finite
-- values, and its properties against an exact reference.
module Test.Render.TwoD.Snapping (spec) where

import Control.Monad (forM_)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Mapping (snapPixel, snapPoint)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, choose, counterexample, elements, forAll, frequency, property, (===))

spec ∷ Spec
spec = describe "Snapping" $ do
  describe "rounds floor (x + 0.5)" $ do
    it "rounds halves up, at every half boundary" $
      forM_ [(-3.5, -3), (-2.5, -2), (-1.5, -1), (-0.5, 0), (0.5, 1), (1.5, 2), (2.5, 3), (1000.5, 1001), (-1000.5, -1000)] $ \(x, expected) →
        snapPixel x `shouldBe` expected

    it "rounds below the half down and above it up, on both sides of zero" $
      forM_
        [ (0.49999997, 0)
        , (0.50000006, 1)
        , (-0.49999997, 0)
        , (-0.50000006, -1)
        , (1.4999999, 1)
        , (1.5000001, 2)
        , (-1.4999999, -1)
        , (-1.5000001, -2)
        , (0.25, 0)
        , (0.75, 1)
        , (-0.25, 0)
        , (-0.75, -1)
        ]
        $ \(x, expected) → snapPixel x `shouldBe` expected

    it "leaves whole numbers where they are" $
      forM_ [0, 1, -1, 7, -7, 4096, 8388607] $ \x → snapPixel x `shouldBe` x

    it "leaves a whole number the rounding of x + 0.5 would move by one pixel" $ do
      -- In 32-bit arithmetic 8388609 + 0.5 rounds to 8388610; the rounding must
      -- be exact, so the integer stays.
      (8388609 + 0.5 ∷ Float) `shouldBe` 8388610
      snapPixel 8388609 `shouldBe` 8388609
      snapPixel (-8388609) `shouldBe` (-8388609)
      snapPixel 8388608 `shouldBe` 8388608
      snapPixel 16777217 `shouldBe` 16777216

    it "returns every value of magnitude 2^23 or more unchanged, the largest finite ones included" $
      forM_ [8388608, 16777216, 1.0e10, 3.4028235e38, -3.4028235e38] $ \x → snapPixel x `shouldBe` x

    it "returns NaN and the infinities unchanged" $ do
      isNaN (snapPixel (0 / 0)) `shouldBe` True
      snapPixel (1 / 0) `shouldBe` (1 / 0)
      snapPixel (-1 / 0) `shouldBe` (-1 / 0)

  it "snaps a point on each axis alone" $ do
    snapPoint (V2 0.5 (-0.5)) `shouldBe` V2 1 0
    snapPoint (V2 2.4 2.6) `shouldBe` V2 2 3
    snapPoint (V2 (-1.5) 8388609) `shouldBe` V2 (-1) 8388609

  describe "properties" $ do
    prop "equals floor (x + 1/2) computed exactly" $
      forAll anyFinite $ \x →
        counterexample (show x) (toRational (snapPixel x) === fromIntegral (floor (toRational x + 1 / 2) ∷ Integer))

    prop "moves a value by at most half a pixel" $
      forAll anyFinite $ \x →
        counterexample (show x) (property (abs (toRational (snapPixel x) - toRational x) <= 1 / 2))

    prop "is idempotent" $
      forAll anyFinite $ \x → snapPixel (snapPixel x) === snapPixel x

    prop "is monotone" $
      forAll ((,) <$> anyFinite <*> anyFinite) $ \(x, y) →
        property (x > y || snapPixel x <= snapPixel y)

    prop "commutes with whole-number shifts" $
      forAll ((,) <$> ordinary <*> choose (-1000, 1000 ∷ Int)) $ \(x, n) →
        snapPixel (x + fromIntegral n) === snapPixel x + fromIntegral n

-- | Finite floats of every magnitude, whole numbers and exact halves included.
anyFinite ∷ Gen Float
anyFinite =
  frequency
    [ (4, ordinary)
    , (3, (/ 2) . fromIntegral <$> (choose (-20000, 20000) ∷ Gen Int))
    , (2, elements [8388607, 8388608, 8388609, 16777216, 0.49999997, 0.50000006, 1.0e10, 3.4028235e38, 1.0e-45, -0])
    , (2, choose (-1.0e8, 1.0e8))
    ]

-- | Floats in the range where a pixel position lives.
ordinary ∷ Gen Float
ordinary = choose (-100000, 100000)
