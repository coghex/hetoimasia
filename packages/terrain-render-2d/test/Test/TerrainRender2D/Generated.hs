-- | Generated scenes: small random clusters of cells of every shape, seen from
-- every facing and cut, must plan without an ordering refusal and agree with
-- the ray oracle wherever it is sampled.
module Test.TerrainRender2D.Generated (spec) where

import Data.List (nubBy)
import Hetoimasia.Terrain.Render2D.Pick
import Hetoimasia.Terrain.Render2D.Plan
import Test.Hspec (Spec, describe, it)
import Test.QuickCheck (Gen, Property, choose, counterexample, forAll, listOf1, property, withNumTests, elements)
import Test.TerrainRender2D.Fixtures
import Test.TerrainRender2D.Ordering (targetOf, withFacing)
import Test.TerrainRender2D.Oracle

-- | Up to a few dozen distinct cells in a 4 x 4 x 4 box, any shape.
genScene ∷ Gen [Cell3]
genScene = do
  cells ← listOf1 ((,,,) <$> choose (-2, 1) <*> choose (-2, 1) <*> choose (0, 3) <*> choose (0, 15))
  pure (nubBy (\(a, b, c, _) (d, e, f, _) → (a, b, c) == (d, e, f)) cells)

prop ∷ Property
prop = forAll genScene $ \cells → forAll (elements allFacings) $ \facing → forAll (choose (0, 4)) $ \cut →
  let camera = withFacing facing (manualCamera 0 0 cut)
      result = planWith id (setup 480 320) camera (factsOf (sceneSource cells))
      ref = cut + 1
   in case result of
        Left refusal → counterexample ("refused: " <> show refusal) False
        Right p →
          let bad =
                [ (point, expected, actual)
                | point ← lattice (-230) 230 (-150) 150 17
                , let expected = sceneHit facing ref cut cells point
                , let actual = case pickPlan p (PickQuery (planIdentity p) (targetOf point)) of
                        Right (PickHit f) → Just (faceCell f, faceViewKind f)
                        _ → Nothing
                , expected /= actual
                ]
           in counterexample ("first mismatch: " <> show (take 1 bad)) (null bad)

spec ∷ Spec
spec = describe "Generated scenes" $
  it "plan without refusal and agree with the ray oracle, for random cells, facings and cuts" $
    withNumTests 150 (property prop)
