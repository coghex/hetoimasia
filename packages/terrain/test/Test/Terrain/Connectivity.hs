-- | Examples for the symbolic source connectivity compiler.
--
-- Three kinds of evidence:
--
-- * hand-authored fixtures with analytically stated expectations (the default
--   flat source, covered and shafted air slabs, uniform ramp layers and their
--   rotations, patch splits and joins, both coordinate extremes), checked at
--   spans of @2^20@ and @2^60@ so a per-member cost cannot hide;
-- * deterministic generated comparisons against the independent flood model of
--   "Test.Terrain.ConnectivityOracle" over sealed rooms, covered open worlds and
--   open-top worlds, covering all sixteen identities (and so all four rotations
--   of every orientable shape) as the default layer and as patch content;
-- * negative controls: deliberately wrong views of the same results (a family
--   merged into one component, a side limit counted as exterior) that the
--   oracle comparison must reject.
module Test.Terrain.Connectivity (spec) where

import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Hetoimasia.Terrain.Connectivity
import Hetoimasia.Terrain.Coordinate (axisFromInteger)
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..))
import Test.Hspec
import Test.Terrain.ConnectivityFixtures
import Test.Terrain.ConnectivityOracle
import Test.Terrain.Model

-- | Layers: stone below @lo@, a slab of one shape on @[lo, hi)@ and stone above.
cover ∷ Integer → Integer → Int → [LayerSpec]
cover lo hi shape = [stoneLayer Nothing (Just lo), slabLayer lo hi shape, stoneLayer (Just hi) Nothing]

world ∷ [LayerSpec] → [PatchSpec] → SourceSpec
world layers patches = SourceSpec {specMaterials = ["stone", "slab"], specLayers = layers, specPatches = patches}

airPatch ∷ Integer → Integer → Integer → Integer → PatchSpec
airPatch x y lo hi = PatchSpec x y lo hi SpecAir

blockPatch ∷ Integer → Integer → Integer → Integer → PatchSpec
blockPatch x y lo hi = PatchSpec x y lo hi (SpecSolid "stone" 0)

-- | The magnitudes the fixtures are checked at.
spans ∷ [Integer]
spans = [2 ^ (20 ∷ Int), 2 ^ (60 ∷ Int)]

sameKey ∷ Connectivity → (Integer, Integer, Integer) → (Integer, Integer, Integer) → Bool
sameKey c a b = isJust (keyAt c a) && keyAt c a == keyAt c b

differ ∷ Connectivity → (Integer, Integer, Integer) → (Integer, Integer, Integer) → Bool
differ c a b = isJust (keyAt c a) && isJust (keyAt c b) && keyAt c a /= keyAt c b

exteriorAt ∷ Connectivity → (Integer, Integer, Integer) → Maybe Bool
exteriorAt c cell = keyAt c cell >>= isExterior c

-- | Compare a case with the oracle through the real result.
agrees ∷ Case → Expectation
agrees c = verify (compiledView (compiled (caseSpec c))) (worldContent (caseSpec c)) (caseWindow c) (caseInner c) `shouldBe` []

spec ∷ Spec
spec = describe "Source connectivity" $ do
  describe "the default flat source" $ do
    let c = compiled soilOverStone
    it "has one exterior component of unobstructed sky and no buried cell" $ do
      keyAt c (0, 0, 1) `shouldSatisfy` isJust
      sameKey c (0, 0, 1) (10 ^ (15 ∷ Int), -(10 ^ (15 ∷ Int)), 12345678901234) `shouldBe` True
      sameKey c (0, 0, 1) (highest, highest, highest) `shouldBe` True
      exteriorAt c (0, 0, 1) `shouldBe` Just True
      exteriorAt c (lowest, lowest, highest) `shouldBe` Just True
      forM_ [(0, 0, 0), (7, -3, -3), (5, 5, -4), (0, 0, lowest), (0, 0, -100)] $ \cell → voidAt c cell `shouldBe` NoVoid
    it "describes itself with a handful of boxes, however large the world" $ do
      statNodes (connectivityStats c) `shouldBe` 2
      statClasses (connectivityStats c) `shouldBe` 1
      statRelations (connectivityStats c) `shouldBe` 1
    it "answers a void index the cell does not have" $
      lookupVoid c (mustTile 0 0 1) 1 `shouldBe` NoSuchVoid

  describe "wholly air terrain" $ do
    let c = compiled (world [] [])
    it "is one exterior component" $ do
      sameKey c (0, 0, 0) (lowest, highest, highest) `shouldBe` True
      exteriorAt c (3, 3, lowest) `shouldBe` Just True

  describe "covered air" $ do
    forM_ spans $ \g → do
      let slab patches = compiled (world [stoneLayer Nothing (Just (negate g)), stoneLayer (Just g) Nothing] patches)
      it ("keeps a world-spanning slab of 2 * " <> show g <> " levels sealed") $ do
        let c = slab []
        sameKey c (0, 0, 0) (lowest, lowest, negate g) `shouldBe` True
        sameKey c (0, 0, 0) (highest, highest, g - 1) `shouldBe` True
        exteriorAt c (0, 0, 0) `shouldBe` Just False
        exteriorAt c (lowest, highest, negate g) `shouldBe` Just False
        voidAt c (0, 0, g) `shouldBe` NoVoid
      it ("lets a shaft to the upper limit open the slab of 2 * " <> show g <> " levels") $ do
        let c = slab [airPatch 3 (-4) 0 topEnd]
        sameKey c (0, 0, 0) (3, -4, highest) `shouldBe` True
        exteriorAt c (0, 0, 0) `shouldBe` Just True
        exteriorAt c (lowest, lowest, negate g) `shouldBe` Just True
      it ("keeps the slab of 2 * " <> show g <> " levels sealed under a shaft that stops inside the cover") $ do
        let c = slab [airPatch 3 (-4) 0 (g + 5)]
        sameKey c (0, 0, 0) (3, -4, g + 4) `shouldBe` True
        exteriorAt c (0, 0, 0) `shouldBe` Just False
    it "keeps air touching only the horizontal and lower limits sealed" $ do
      let c = compiled (world [stoneLayer (Just 0) Nothing] [])
      exteriorAt c (lowest, lowest, lowest) `shouldBe` Just False
      exteriorAt c (highest, 0, -1) `shouldBe` Just False
    it "gives a topmost full block no opening and a topmost shape its top portal" $ do
      let capped = compiled (world [stoneLayer (Just (topEnd - 1)) Nothing] [])
          ramped = compiled (world [slabLayer (topEnd - 1) topEnd 1] [])
      exteriorAt capped (0, 0, topEnd - 2) `shouldBe` Just False
      voidAt capped (0, 0, highest) `shouldBe` NoVoid
      exteriorAt ramped (0, 0, highest) `shouldBe` Just True
      -- The air below the topmost ramp level meets only the ramp's closed bottom.
      exteriorAt ramped (4, 9, topEnd - 2) `shouldBe` Just False
    it "reads an omitted upper end as one past the highest level" $ do
      let omitted = compiled (world [slabLayer 0 topEnd 1] [])
      exteriorAt omitted (0, 0, highest) `shouldBe` Just True
      exteriorAt omitted (0, 0, highest - 1) `shouldBe` Just False

  describe "uniform ramp layers" $ do
    forM_ spans $ \levels → do
      let l = levels
          rows = compiled (world (cover 0 l 1) [])
          columns = compiled (world (cover 0 l 2) [])
          mid = l `div` 2
      it ("keeps separate row channels and levels in a layer of " <> show levels <> " N ramps") $ do
        sameKey rows (0, 3, mid) (-(10 ^ (12 ∷ Int)), 3, mid) `shouldBe` True
        differ rows (0, 3, mid) (0, 4, mid) `shouldBe` True
        differ rows (0, 3, mid) (0, 3, mid + 1) `shouldBe` True
        differ rows (0, 3, mid) (0, 2, mid) `shouldBe` True
        exteriorAt rows (0, 3, mid) `shouldBe` Just False
        voidAt rows (0, 3, l) `shouldBe` NoVoid
        voidAt rows (0, 3, -1) `shouldBe` NoVoid
        fmap (map fst . keyParameters) (keyAt rows (0, 3, mid)) `shouldBe` Just [AxisY, AxisZ]
      it ("keeps separate column channels and levels in a layer of " <> show levels <> " E ramps") $ do
        sameKey columns (3, 0, mid) (3, -(10 ^ (12 ∷ Int)), mid) `shouldBe` True
        differ columns (3, 0, mid) (4, 0, mid) `shouldBe` True
        differ columns (3, 0, mid) (3, 0, mid + 1) `shouldBe` True
        fmap (map fst . keyParameters) (keyAt columns (3, 0, mid)) `shouldBe` Just [AxisX, AxisZ]
    it "describes layers of 2^20 and 2^60 levels with the same structure" $ do
      let figures n = let s = statsOf (world (cover 0 n 1) []) in (workNodes s, workRelations s, workSteps s, workResultBytes s, workPeakBytes s)
      figures (2 ^ (20 ∷ Int)) `shouldBe` figures (2 ^ (60 ∷ Int))
    it "turns the channels with the ramp: S ramps run along X, W ramps along Y" $ do
      let south = compiled (world (cover 0 100 4) [])
          west = compiled (world (cover 0 100 8) [])
      sameKey south (0, 3, 50) (99, 3, 50) `shouldBe` True
      differ south (0, 3, 50) (0, 4, 50) `shouldBe` True
      sameKey west (3, 0, 50) (3, 99, 50) `shouldBe` True
      differ west (3, 0, 50) (4, 0, 50) `shouldBe` True
    it "joins a ramp layer to the air above it level by level without joining the levels" $ do
      -- Stone below, ramps on [0, 4), air on [4, top): the air connects every
      -- row of the top ramp level (and only that level) to the sky.
      let c = compiled (world [stoneLayer Nothing (Just 0), slabLayer 0 4 1] [])
      sameKey c (0, 3, 3) (50, -9, 100) `shouldBe` True
      sameKey c (50, -9, 3) (50, 9, 3) `shouldBe` True
      differ c (0, 3, 2) (0, 3, 3) `shouldBe` True
      differ c (0, 3, 2) (0, 4, 2) `shouldBe` True
      exteriorAt c (0, 3, 3) `shouldBe` Just True
      exteriorAt c (0, 3, 2) `shouldBe` Just False

  describe "patches" $ do
    forM_ spans $ \l → do
      let base = cover 0 l 1
          y0 = 6
          x0 = 11
      it ("splits one ramp channel in two with a full block, leaving its neighbours, over " <> show l <> " levels") $ do
        let za = l `div` 4
            zb = za + 3
            c = compiled (world base [blockPatch x0 y0 za zb])
        differ c (x0 - 1, y0, za + 1) (x0 + 1, y0, za + 1) `shouldBe` True
        sameKey c (x0 - 1, y0, za + 1) (-5, y0, za + 1) `shouldBe` True
        sameKey c (x0 + 1, y0, za + 1) (999, y0, za + 1) `shouldBe` True
        sameKey c (x0 - 1, y0, za - 1) (x0 + 1, y0, za - 1) `shouldBe` True
        sameKey c (x0 - 1, y0, zb) (x0 + 1, y0, zb) `shouldBe` True
        sameKey c (x0 - 1, y0 + 1, za + 1) (x0 + 1, y0 + 1, za + 1) `shouldBe` True
        sameKey c (x0 - 1, y0 - 1, za + 1) (x0 + 1, y0 - 1, za + 1) `shouldBe` True
        voidAt c (x0, y0, za + 1) `shouldBe` NoVoid
      it ("joins a vast range of repeated layer components with one air shaft, over " <> show l <> " levels") $ do
        let c = compiled (world base [airPatch x0 y0 0 l])
            rowJoined = [(x0 - 40, y0, 3), (x0 + 40, y0, l - 3), (x0, y0, l `div` 2), (7, y0 + 1, l `div` 3), (-9, y0 + 1, l - 1)]
        forM_ (zip rowJoined (drop 1 rowJoined)) $ \(a, b) → sameKey c a b `shouldBe` True
        differ c (0, y0 - 1, 5) (0, y0, 5) `shouldBe` True
        differ c (0, y0 + 2, 5) (0, y0 + 1, 5) `shouldBe` True
        differ c (0, y0 + 2, 5) (0, y0 + 2, 6) `shouldBe` True
        fmap keyParameters (keyAt c (x0, y0, 9)) `shouldBe` Just []
        fmap keyParameters (keyAt c (0, y0 + 2, 9)) `shouldBe` Just [(AxisY, either (error . show) id (axisOf (y0 + 2))), (AxisZ, either (error . show) id (axisOf 9))]
        exteriorAt c (x0, y0, 5) `shouldBe` Just False
      it ("joins only the levels a partial shaft covers, over " <> show l <> " levels") $ do
        -- The shaft's bottom rests on the ramp below it, whose void it joins
        -- through that ramp's top portal; its top meets a closed ramp bottom.
        let za = l `div` 2
            zb = za + 5
            c = compiled (world base [airPatch x0 y0 za zb])
        sameKey c (x0 - 3, y0, za - 1) (x0 + 3, y0 + 1, zb - 1) `shouldBe` True
        sameKey c (x0 - 3, y0, zb - 1) (x0 + 3, y0, za) `shouldBe` True
        differ c (x0 - 3, y0, za - 2) (x0 - 3, y0, za - 1) `shouldBe` True
        differ c (x0 + 3, y0 + 1, za - 1) (x0 - 3, y0, za - 1) `shouldBe` True
        sameKey c (x0 - 3, y0, za - 2) (x0 + 3, y0, za - 2) `shouldBe` True
        sameKey c (x0 - 3, y0, zb) (x0 + 3, y0, zb) `shouldBe` True
        differ c (x0 - 3, y0, zb) (x0 - 3, y0, za) `shouldBe` True
        differ c (x0 - 3, y0 + 2, za) (x0 - 3, y0 + 1, za) `shouldBe` True
    it "places patches and portals across negative chunk and vertical-region boundaries" $ do
      let base = cover (-70) 70 1
          c = compiled (world base [blockPatch (-1) (-1) (-33) (-31), airPatch (-16) 0 (-40) (-20)])
      differ c (-2, -1, -32) (0, -1, -32) `shouldBe` True
      sameKey c (-2, -1, -34) (0, -1, -34) `shouldBe` True
      sameKey c (-2, -1, -31) (0, -1, -31) `shouldBe` True
      sameKey c (-30, 0, -33) (3, 1, -21) `shouldBe` True
      differ c (-30, 0, -42) (-30, 0, -33) `shouldBe` True
      sameKey c (-30, 0, -41) (-30, 0, -33) `shouldBe` True
    it "treats a patch that restates the layer as no change" $ do
      let plain = compiled (world (cover 0 100 1) [])
          restated = compiled (world (cover 0 100 1) [PatchSpec 5 5 10 20 (SpecSolid "slab" 1)])
      sameKey restated (0, 5, 15) (9, 5, 15) `shouldBe` True
      sameKey plain (0, 5, 15) (9, 5, 15) `shouldBe` True

  describe "the independent oracle" $ do
    let kinds = Nothing : map Just [0 .. 15]
    forM_ (zip [0 ∷ Int ..] kinds) $ \(i, def) →
      it ("agrees on sealed rooms of default kind " <> maybe "air" show def) $
        forM_ [1 .. 6] $ \s →
          agrees (sealedRoom ("room " <> show i) (ox s, oy s, oz s) (4 + s `mod` 2, 4, 3) def (100 * i + s))
    forM_ (zip [0 ∷ Int ..] kinds) $ \(i, def) →
      it ("agrees on covered open worlds of default kind " <> maybe "air" show def) $
        forM_ [1 .. 3] $ \s →
          agrees (coveredOpen ("open " <> show i) (ox s, oy s, oz s) (4, 3, 3) def (7000 + 100 * i + s))
    forM_ [1 .. 12] $ \s →
      it ("agrees on an open-top world, seed " <> show s) $
        agrees (openTop ("top " <> show s) (ox s, oy s) (4, 3, 2) (1 + s `mod` 3) (900 + s))
    it "agrees on sealed rooms at the coordinate extremes" $
      forM_ extremes $ \(label, origin, size) →
        forM_ [1 .. 4] $ \s → agrees (sealedRoom label origin size (Just (s * 3 `mod` 16)) (50000 + s))
    it "agrees on a hand-built all-sixteen-shape cavity" $ do
      let patches =
            [ PatchSpec (toInteger (i `mod` 4)) (toInteger (i `div` 4)) 0 1 (SpecSolid "slab" i)
            | i ← [0 .. 15]
            ]
          ring =
            [ blockPatch x y (-3) 4
            | x ← [-1 .. 4]
            , y ← [-1 .. 4]
            , x == -1 || x == 4 || y == -1 || y == 4
            ]
          c = Case "cavity" (world [stoneLayer Nothing (Just 0), stoneLayer (Just 1) Nothing] (patches ++ ring)) (Window (-1, 5) (-1, 5) (-3, 4)) (const True)
      agrees c
  describe "negative controls" $ do
    -- A covered layer of N ramps is one class of row-and-level channels. The
    -- oracle accepts the real view, and must reject a view that gives the whole
    -- family one component, and one that calls a sealed slab exterior because it
    -- touches a side limit.
    let family = Case "ramp family" (world (cover 0 4 1) []) (Window (-3, 3) (-3, 3) (-1, 5)) (const True)
        slab = Case "limit slab" (world [stoneLayer Nothing (Just 0), stoneLayer (Just 4) Nothing] []) (Window (lowest, lowest + 4) (lowest, lowest + 4) (0, 4)) (const True)
        check view c = verify view (worldContent (caseSpec c)) (caseWindow c) (caseInner c)
    it "accepts the real views of both control cases" $ do
      check (compiledView (compiled (caseSpec family))) family `shouldBe` []
      check (compiledView (compiled (caseSpec slab))) slab `shouldBe` []
    it "rejects a view that merges a family into one component" $
      check (rekeyed (compiledView (compiled (caseSpec family))) (caseWindow family) keyOrigin) family `shouldNotBe` []
    it "rejects a view that treats a side limit as exterior" $ do
      let real = compiledView (compiled (caseSpec slab))
          wrong = real {viewExterior = \k → fmap (const True) (viewExterior real k)}
      check wrong slab `shouldNotBe` []
    it "rejects a view that drops a level from a family's parameters" $ do
      let real = compiledView (compiled (caseSpec family))
          forgetLevel k = (keyOrigin k, [p | p@(axis, _) ← keyParameters k, axis /= AxisZ])
      check (rekeyed real (caseWindow family) forgetLevel) family `shouldNotBe` []
  where
    ox s = toInteger (s * 13 - 20)
    oy s = toInteger (s * 7 - 31)
    oz s = toInteger (s * 11 - 40)
    extremes =
      [ ("lowest corner", (lowest, lowest, lowest + 3), (4, 4, 3))
      , ("highest corner", (highest - 3, highest - 3, topEnd - 9), (4, 4, 3))
      , ("mixed corner", (lowest, highest - 3, topEnd - 9), (4, 4, 3))
      ]
    axisOf = axisFromInteger

-- | A view of the same result under different keys: every answer other than the
-- lookup is the real one, found through a representative real key of each new
-- key seen in the window. A key function that forgets a distinction (the
-- parameters of a family) makes a deliberately wrong view.
rekeyed ∷ Ord k ⇒ View ComponentKey → Window → (ComponentKey → k) → View k
rekeyed real window f =
  View
    { viewLookup = \cell → fmap (fmap f) (viewLookup real cell)
    , viewExterior = \k → representative k >>= viewExterior real
    , viewRanges = \k → representative k >>= viewRanges real
    , viewRelations = \k → representative k >>= viewRelations real
    , viewBoundary = \k → representative k >>= viewBoundary real
    , viewBox = viewBox real
    }
  where
    representatives = Map.fromList [(f k, k) | cell ← windowCells window, Just (Just k) ← [viewLookup real cell]]
    representative k = Map.lookup k representatives
