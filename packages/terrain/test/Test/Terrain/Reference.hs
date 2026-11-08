-- | The retained reference-defect fixture (TRA-13, #655): a self-contained,
-- deterministic reproduction of the original N/E inconsistency in the reference
-- game's face masks, with its exact geometric implication.
--
-- = Provenance
--
-- The reference is Synarchy at revision @3777d437ea00e1302bf55162ad5693fee4879187@.
-- Its face mask for the N slope, @assets/textures/facemap/isoface_slope_n.png@
-- (Git blob @effc21564c7a653605dcbafca23ce7bc560e262d@), and for the E slope,
-- @isoface_slope_e.png@ (blob @5ed533b4d9467fa3b371a4cb489a87844fa64611@), are
-- 96 × 64 RGBA sheets of one full-block canvas. The samples below were extracted
-- by @test/reference/extract_facemap_samples.py@, which reads those two blobs
-- read-only through git, refuses any whose Git object id is not the pinned one,
-- and prints exactly the literals in 'eTexel' and 'nColumns'. Running it again
-- and diffing against them reproduces the fixture. This suite reads no PNG, no
-- sibling checkout and no network; the library reads none either.
--
-- = What is reproduced
--
-- The reference projects a unit-cell point @(x, y, z)@ onto its canvas at
-- @u = 48 + 48 (x - y)@, @v = 16 + 24 (x + y) - 16 z@. The E mask's texel
-- @(48, 2)@ is opaque, @(0, 255, 0, 255)@. The cell points that project anywhere
-- into that texel's whole area form a convex polytope; this module enumerates
-- its vertices itself, in exact rational arithmetic and with no library code, and
-- bounds the linear functions @x + y@, @x - y@ and @z@ over them. The inverse
-- quarter turn @(x, y, z) -> (y, 1 - x, z)@ takes those points to the N shape's
-- cell, where they project into @[0, 6] × [23.5, 27]@. Every N texel enclosing
-- that window is transparent: the first opaque N rows of columns 0 to 7 are
-- 39, 39, 38, 38, 37, 37, 36, 36. So an opaque part the E mask requires would
-- have to sit inside a transparent part of N after the turn, by a margin of
-- eight rows or more, far beyond a pixel edge or a choice of nearest or linear
-- sampling. This is a mathematical check of two pinned images: no game launch, no
-- GPU, and not a claim about any other mask.
--
-- It is the original defect only. Corrected masks, alpha picking and lighting are
-- other slices' (TRA-14, TRA-16, TRA-17); nothing here is corrected-mask or GPU
-- evidence.
module Test.Terrain.Reference (spec) where

import Control.Monad (forM_)
import Hetoimasia.Terrain.Geometry (V3 (..), rotatePoint)
import Hetoimasia.Terrain.Shape
import Test.Hspec

-- | The reference revision and the pinned blobs.
referenceRevision, northBlob, eastBlob ∷ String
referenceRevision = "3777d437ea00e1302bf55162ad5693fee4879187"
northBlob = "effc21564c7a653605dcbafca23ce7bc560e262d"
eastBlob = "5ed533b4d9467fa3b371a4cb489a87844fa64611"

-- | The E mask's texel (48, 2) as RGBA.
eTexel ∷ (Int, Int, Int, Int)
eTexel = (0, 255, 0, 255)

-- | For columns 0 to 7 of the N mask: the column, the number of leading
-- transparent rows (alpha 0 on rows 0 up to but not including it, so it is also
-- the first opaque row) and the alpha of that first opaque texel.
nColumns ∷ [(Int, Int, Int)]
nColumns = [(0, 39, 255), (1, 39, 255), (2, 38, 255), (3, 38, 255), (4, 37, 255), (5, 37, 255), (6, 36, 255), (7, 36, 255)]

-- | The reference's projection of a unit-cell point onto its canvas.
project ∷ (Rational, Rational, Rational) → (Rational, Rational)
project (x, y, z) = (48 + 48 * (x - y), 16 + 24 * (x + y) - 16 * z)

-- | The inverse quarter turn, written out by this module.
inverseTurn ∷ (Rational, Rational, Rational) → (Rational, Rational, Rational)
inverseTurn (x, y, z) = (y, 1 - x, z)

-- | A half-space @a · p <= b@.
type Constraint = ((Rational, Rational, Rational), Rational)

-- | The cell points that project into the whole of texel @(column, row)@, as
-- half-spaces: the unit cell, @column <= u <= column + 1@ and
-- @row <= v <= row + 1@.
texelPoints ∷ Int → Int → [Constraint]
texelPoints column row =
  [ ((-1, 0, 0), 0)
  , ((1, 0, 0), 1)
  , ((0, -1, 0), 0)
  , ((0, 1, 0), 1)
  , ((0, 0, -1), 0)
  , ((0, 0, 1), 1)
  , -- u >= column: x - y >= (column - 48) / 48.
    ((-1, 1, 0), (48 - c) / 48)
  , -- u <= column + 1: x - y <= (column - 47) / 48.
    ((1, -1, 0), (c - 47) / 48)
  , -- v >= row: -24x - 24y + 16z <= 16 - row.
    ((-24, -24, 16), 16 - r)
  , -- v <= row + 1: 24x + 24y - 16z <= row - 15.
    ((24, 24, -16), r - 15)
  ]
  where
    c = fromIntegral column
    r = fromIntegral row

-- | The vertices of the polytope the half-spaces bound: every point where three
-- of them meet in one point and no half-space excludes.
vertices ∷ [Constraint] → [(Rational, Rational, Rational)]
vertices cs =
  [ p
  | (i, c1) ← indexed
  , (j, c2) ← indexed
  , (k, c3) ← indexed
  , i < j
  , j < k
  , Just p ← [solve c1 c2 c3]
  , all (\((a, b, c), d) → let (x, y, z) = p in a * x + b * y + c * z <= d) cs
  ]
  where
    indexed = zip [0 ∷ Int ..] cs

-- | The single point where three planes meet, by Cramer's rule.
solve ∷ Constraint → Constraint → Constraint → Maybe (Rational, Rational, Rational)
solve ((a1, b1, c1), d1) ((a2, b2, c2), d2) ((a3, b3, c3), d3)
  | det == 0 = Nothing
  | otherwise = Just (det3 d1 b1 c1 d2 b2 c2 d3 b3 c3 / det, det3 a1 d1 c1 a2 d2 c2 a3 d3 c3 / det, det3 a1 b1 d1 a2 b2 d2 a3 b3 d3 / det)
  where
    det = det3 a1 b1 c1 a2 b2 c2 a3 b3 c3
    det3 p q r s t u v w x = p * (t * x - u * w) - q * (s * x - u * v) + r * (s * w - t * v)

extremes ∷ [Rational] → (Rational, Rational)
extremes values = (minimum values, maximum values)

spec ∷ Spec
spec = describe "The retained reference defect" $ do
  describe "the pinned samples" $ do
    it "names the pinned revision and blobs" $ do
      referenceRevision `shouldBe` "3777d437ea00e1302bf55162ad5693fee4879187"
      northBlob `shouldBe` "effc21564c7a653605dcbafca23ce7bc560e262d"
      eastBlob `shouldBe` "5ed533b4d9467fa3b371a4cb489a87844fa64611"
    it "records the E texel (48, 2) as fully opaque green" $
      eTexel `shouldBe` (0, 255, 0, 255)
    it "records the first opaque N row of each of the first eight columns" $
      [(column, firstOpaque) | (column, firstOpaque, _) ← nColumns] `shouldBe` zip [0 ..] [39, 39, 38, 38, 37, 37, 36, 36]
    it "records every N texel above each first opaque row as transparent, and that row as opaque" $
      forM_ nColumns $ \(_, _, alpha) → alpha `shouldBe` 255

  describe "the geometric implication" $ do
    let cell = vertices (texelPoints 48 2)
        qs = [x + y | (x, y, _) ← cell]
        ds = [x - y | (x, y, _) ← cell]
        zs = [z | (_, _, z) ← cell]
        north = map (project . inverseTurn) cell
        (uLo, uHi) = extremes (map fst north)
        (vLo, vHi) = extremes (map snd north)
    it "finds a nonempty polytope of cell points projecting into the whole E texel" $
      cell `shouldSatisfy` (not . null)
    it "bounds x + y to [0, 1/8], x - y to [0, 1/48] and z to [13/16, 1]" $ do
      extremes qs `shouldBe` (0, 1 / 8)
      extremes ds `shouldBe` (0, 1 / 48)
      extremes zs `shouldBe` (13 / 16, 1)
    it "turns the library's quarter turn back to the same inverse turn this module wrote out" $
      forM_ cell $ \(x, y, z) →
        rotatePoint (turns 3) (V3 x y z) `shouldBe` (let (a, b, c) = inverseTurn (x, y, z) in V3 a b c)
    it "takes those points under the inverse turn into the N projection [0, 6] × [47/2, 27]" $ do
      (uLo, uHi) `shouldBe` (0, 6)
      (vLo, vHi) `shouldBe` (47 / 2, 27)
    it "has the N shape one quarter turn from the E shape, so the inverse turn goes from E to N" $ do
      let shape n = either (error . show) id (mkShapeId n)
      rotateShape (turns 1) (shape 1) `shouldBe` shape 2
    it "finds every N texel enclosing that window transparent, eight rows or more clear of the first opaque row" $ do
      let columns = [max 0 (ceiling uLo - 1) .. floor uHi] ∷ [Int]
          rows = [ceiling vLo - 1 .. floor vHi] ∷ [Int]
          firstOpaque column = head' [row | (c, row, _) ← nColumns, c == column]
      columns `shouldBe` [0 .. 6]
      rows `shouldBe` [23 .. 27]
      forM_ columns $ \column →
        forM_ rows $ \row → (column, row < firstOpaque column) `shouldBe` (column, True)
      minimum (map firstOpaque columns) - maximum rows `shouldSatisfy` (>= 8)
  where
    head' (x : _) = x
    head' [] = error "no sample for the column"
