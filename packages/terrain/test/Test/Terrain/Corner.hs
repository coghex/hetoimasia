-- | Examples for the corner family: checked masks, shape keys, their exact
-- quarter turns, the folded surface height, the convex pieces and the external
-- facets.
--
-- The expected surface is "Test.Terrain.CornerOracle", a translation of the
-- approved reference that calls nothing from the engine. Every claim here is
-- about a result: heights and keys at all 4,624 reference inputs, the sign of
-- plane values at sample points, the area, orientation and closure of facets,
-- and the union of per-piece ray intervals against the reference's solid.
-- Enumeration order and timing are never asserted.
module Test.Terrain.Corner (spec) where

import Control.Monad (forM_)
import Data.Bits (bit, testBit)
import Data.List (nub, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Hetoimasia.Terrain.Geometry
import Hetoimasia.Terrain.Shape
import Test.Hspec
import Test.Terrain.CornerOracle

-- * Construction

cornerMask ∷ Int → CornerMask
cornerMask value = either (error . show) id (mkCornerMask value)

-- | The occupied key of a nonzero mask.
occupied ∷ Int → ShapeKey
occupied value = fromMaybe (error "mask zero is air") (resolveCorner (cornerMask value))

sideId ∷ Int → ShapeId
sideId value = either (error . show) id (mkShapeId value)

-- | A mask with its corners moved one place, north-west to north-east to
-- south-east to south-west, written bit by bit.
movedOnce ∷ Int → Int
movedOnce value = sum [bit ((corner + 1) `mod` 4) | corner ← [0 .. 3], testBit value corner]

movedBy ∷ Int → Int → Int
movedBy count value = iterate movedOnce value !! count

-- | The 17 × 17 sample points of the reference, endpoints included.
grid ∷ [(Rational, Rational)]
grid = [(x, y) | x ← referenceCoordinates, y ← referenceCoordinates]

heightOf ∷ Maybe ShapeKey → Rational → Rational → Either GeometryError (Maybe Rational)
heightOf = surfaceHeight

-- * Vector helpers on the public 'V3'

dotV ∷ V3 → V3 → Rational
dotV (V3 a b c) (V3 d e f) = a * d + b * e + c * f

planeAt ∷ Plane → V3 → Rational
planeAt plane point = dotV (planeNormal plane) point - planeOffset plane

-- | The vector area of a polygon: half the sum of the cross products of
-- consecutive corners. Its direction is the outward normal for corners that
-- wind counter-clockwise seen from outside, and its length is the area.
vectorArea ∷ [V3] → V3
vectorArea corners = foldr add (V3 0 0 0) (zipWith crossHalf corners (drop 1 corners <> take 1 corners))
  where
    add (V3 a b c) (V3 d e f) = V3 (a + d) (b + e) (c + f)
    crossHalf (V3 a b c) (V3 d e f) = V3 ((b * f - c * e) / 2) ((c * d - a * f) / 2) ((a * e - b * d) / 2)

areaX, areaY, areaZ ∷ V3 → Rational
areaX (V3 a _ _) = a
areaY (V3 _ b _) = b
areaZ (V3 _ _ c) = c

-- * Reference integrals, by exact summation on 1,024 small triangles per cell

-- | The 1/1024-area triangles of the 16 × 16 grid, each cell cut by both of its
-- diagonals. A crease of the reference runs along a cell diagonal, so the
-- reference is linear on every one of them.
smallTriangles ∷ [((Rational, Rational), (Rational, Rational), (Rational, Rational))]
smallTriangles =
  concat
    [ [(centre, p00, p10), (centre, p10, p11), (centre, p11, p01), (centre, p01, p00)]
    | i ← [0 .. 15 ∷ Int]
    , j ← [0 .. 15 ∷ Int]
    , let x0 = fromIntegral i / 16
          y0 = fromIntegral j / 16
          p00 = (x0, y0)
          p10 = (x0 + 1 / 16, y0)
          p11 = (x0 + 1 / 16, y0 + 1 / 16)
          p01 = (x0, y0 + 1 / 16)
          centre = (x0 + 1 / 32, y0 + 1 / 32)
    ]

referenceAt ∷ Int → (Rational, Rational) → Rational
referenceAt value (x, y) = fromMaybe 0 (surfaceHeightReference value x y)

-- | The area of the footprint where the reference height is positive.
referencePositiveArea ∷ Int → Rational
referencePositiveArea value =
  sum [1 / 1024 | (a, b, c) ← smallTriangles, referenceAt value (centroid a b c) > 0]
  where
    centroid (ax, ay) (bx, by) (cx, cy) = ((ax + bx + cx) / 3, (ay + by + cy) / 3)

-- | The volume under the reference height.
referenceVolume ∷ Int → Rational
referenceVolume value =
  sum [(referenceAt value a + referenceAt value b + referenceAt value c) / 3 / 1024 | (a, b, c) ← smallTriangles]

-- | The area under the reference height along one side of the cell. The height
-- is linear along a side, which is asserted at the midpoint.
referenceWall ∷ Int → Side → Rational
referenceWall value side = (h start + h end) / 2
  where
    (start, end) = case side of
      North → ((0, 0), (1, 0))
      East → ((1, 0), (1, 1))
      South → ((0, 1), (1, 1))
      West → ((0, 0), (0, 1))
    h = referenceAt value

-- * Rays and per-piece intervals

type Interval = (Rational, Rational)

-- | The parameters at which the line @origin + t * direction@ is inside every
-- half-space of a piece, or 'Nothing' when it never is.
pieceInterval ∷ ConvexPiece → V3 → V3 → Maybe Interval
pieceInterval piece origin direction = foldr clip (Just (Nothing, Nothing)) (piecePlanes piece) >>= bounded
  where
    clip _ Nothing = Nothing
    clip plane (Just (lo, hi))
      | rate == 0 = if start > 0 then Nothing else Just (lo, hi)
      | rate > 0 = Just (lo, Just (maybe limit (min limit) hi))
      | otherwise = Just (Just (maybe limit (max limit) lo), hi)
      where
        start = planeAt plane origin
        rate = dotV (planeNormal plane) direction
        limit = negate start / rate
    bounded (Just lo, Just hi) | lo <= hi = Just (lo, hi)
    bounded _ = Nothing

-- | The union of closed intervals, merging those that touch.
unionIntervals ∷ [Interval] → [Interval]
unionIntervals = reverse . foldl merge [] . sort
  where
    merge [] interval = [interval]
    merge ((lo, hi) : rest) (lo', hi')
      | lo' <= hi = (lo, max hi hi') : rest
      | otherwise = (lo', hi') : (lo, hi) : rest

pieceIntervals ∷ ShapeKey → V3 → V3 → [Interval]
pieceIntervals key origin direction = mapMaybe (\piece → pieceInterval piece origin direction) (convexPieces key)

-- | The reference's solid: below its surface, above the base, over the square.
insideReference ∷ Int → V3 → Bool
insideReference value (V3 x y z) =
  x >= 0 && x <= 1 && y >= 0 && y <= 1 && z >= 0 && maybe False (z <=) (surfaceHeightReference value x y)

along ∷ V3 → V3 → Rational → V3
along (V3 a b c) (V3 d e f) t = V3 (a + t * d) (b + t * e) (c + t * f)

-- * The examples

spec ∷ Spec
spec = describe "Corner masks" $ do
  maskSpec
  keySpec
  rotationSpec
  heightSpec
  squareSpec
  pieceSpec
  planeSpec
  facetSpec
  clippingSpec

maskSpec ∷ Spec
maskSpec = describe "the checked mask" $ do
  it "accepts exactly 0 to 15 and reports the value it was given" $
    map (fmap cornerMaskValue . mkCornerMask) [0 .. 15] `shouldBe` map Right [0 .. 15]
  it "refuses a mask outside 0 to 15 with the value it was given" $
    forM_ [-1, 16, 255, 256, minBound, maxBound] $ \value →
      mkCornerMask value `shouldBe` Left (UnsupportedCornerMask value)
  it "leaves the side identity refusal as it was" $ do
    mkShapeId 16 `shouldBe` Left (UnsupportedShapeId 16)
    show (mkShapeId 16) `shouldBe` "Left (UnsupportedShapeId 16)"

keySpec ∷ Spec
keySpec = describe "shape keys" $ do
  it "resolves mask zero to air and every other mask to a key of its own" $ do
    resolveCorner (cornerMask 0) `shouldBe` Nothing
    let keys = [resolveCorner (cornerMask value) | value ← [1 .. 15]]
    all isJust keys `shouldBe` True
    length (nub keys) `shouldBe` 15
  it "enumerates the 31 occupied keys once each: 16 sides and 15 nonzero corner masks" $ do
    length allShapeKeys `shouldBe` 31
    length (nub allShapeKeys) `shouldBe` 31
    sort allShapeKeys
      `shouldBe` sort (map (sideKey . sideId) [0 .. 15] <> map occupied [1 .. 15])
  it "keeps side 0 and corner mask 15 as different full blocks" $ do
    sideKey (sideId 0) `shouldNotBe` occupied 15
    forM_ grid $ \(x, y) → do
      heightOf (Just (sideKey (sideId 0))) x y `shouldBe` Right (Just 1)
      heightOf (Just (occupied 15)) x y `shouldBe` Right (Just 1)
  it "never equates a side key with a corner key, whatever the numbers" $
    forM_ [1 .. 15] $ \value → sideKey (sideId value) `shouldNotBe` occupied value
  it "associates every occupied key with its pieces and facets, found again through the key a mask resolves to" $ do
    let table = Map.fromList [(key, (convexPieces key, boundaryFaces key)) | key ← allShapeKeys]
    Map.size table `shouldBe` 31
    forM_ [1 .. 15] $ \value → do
      let (pieces, facets) = table Map.! occupied value
      pieces `shouldSatisfy` (not . null)
      facets `shouldSatisfy` (not . null)

rotationSpec ∷ Spec
rotationSpec = describe "quarter turns" $ do
  it "move each corner north-west to north-east to south-east to south-west" $
    forM_ [0 .. 15] $ \value →
      forM_ [0 .. 3] $ \count →
        fmap (rotateKey (turns count)) (resolveCorner (cornerMask value))
          `shouldBe` resolveCorner (cornerMask (movedBy count value))
  it "restore a key after four turns and compose by adding" $
    forM_ allShapeKeys $ \key → do
      rotateKey (turns 4) key `shouldBe` key
      rotateKey (turns 1) (rotateKey (turns 2) key) `shouldBe` rotateKey (turns 3) key
  it "rotate a side key as the side shape rotates" $
    forM_ [0 .. 15] $ \value →
      forM_ [0 .. 3] $ \count →
        rotateKey (turns count) (sideKey (sideId value)) `shouldBe` sideKey (rotateShape (turns count) (sideId value))
  it "keep the reference itself consistent with the clockwise turn at every input" $
    [ (value, x, y)
    | value ← referenceMasks
    , (x, y) ← grid
    , surfaceHeightReference (movedOnce value) (1 - y) x /= surfaceHeightReference value x y
    ]
      `shouldBe` []

heightSpec ∷ Spec
heightSpec = describe "the surface height" $ do
  it "covers 16 masks × 17 × 17 = 4,624 reference inputs" $
    length [(value, x, y) | value ← referenceMasks, (x, y) ← grid] `shouldBe` 4624
  it "equals the reference exactly at every input, empty included" $
    [ (value, x, y, got, want)
    | value ← referenceMasks
    , (x, y) ← grid
    , let got = heightOf (resolveCorner (cornerMask value)) x y
          want = Right (surfaceHeightReference value x y)
    , got /= want
    ]
      `shouldBe` []
  it "equals the reference at the point a clockwise turn moves it to, for the turned key" $
    [ (value, x, y, got, want)
    | value ← referenceMasks
    , (x, y) ← grid
    , let turned = fmap (rotateKey (turns 1)) (resolveCorner (cornerMask value))
          got = heightOf turned (1 - y) x
          want = Right (surfaceHeightReference value x y)
    , got /= want
    ]
      `shouldBe` []
  it "has no height for air at any point of the square" $
    forM_ grid $ \(x, y) → heightOf Nothing x y `shouldBe` Right Nothing
  it "reports zero on the flat half of a bank and on the crease of a valley" $ do
    heightOf (Just (occupied 1)) (3 / 4) (3 / 4) `shouldBe` Right (Just 0)
    heightOf (Just (occupied 5)) (1 / 2) (1 / 2) `shouldBe` Right (Just 0)
    heightOf (Just (occupied 10)) (1 / 4) (1 / 4) `shouldBe` Right (Just 0)
  it "reports the top of a side solid: 1 for side 0, a ramp for a single side, one half at the apex of side 15" $ do
    heightOf (Just (sideKey (sideId 0))) (1 / 3) (2 / 3) `shouldBe` Right (Just 1)
    heightOf (Just (sideKey (sideId 1))) (1 / 3) (2 / 3) `shouldBe` Right (Just (2 / 3))
    heightOf (Just (sideKey (sideId 4))) (1 / 3) (2 / 3) `shouldBe` Right (Just (1 / 3))
    heightOf (Just (sideKey (sideId 15))) (1 / 2) (1 / 2) `shouldBe` Right (Just (1 / 2))
    heightOf (Just (sideKey (sideId 15))) 0 (1 / 2) `shouldBe` Right (Just 0)
  it "equals the height at which a vertical ray enters the solid of every side shape" $
    [ (value, x, y, got, want)
    | value ← [0 .. 15]
    , (x, y) ← grid
    , let got = heightOf (Just (sideKey (sideId value))) x y
          want = case mkRay (V3 x y 2) (V3 0 0 (-1)) of
            Right ray → Right (fmap (\hit → let V3 _ _ z = hitPoint hit in z) (castRay (shapeSolid (sideId value)) ray))
            Left e → Left e
    , got /= want
    ]
      `shouldBe` []

squareSpec ∷ Spec
squareSpec = describe "a sample outside the closed unit square" $ do
  let outside =
        [(-1 / 100, 1 / 2), (101 / 100, 1 / 2), (1 / 2, -1 / 100), (1 / 2, 101 / 100), (-1, -1), (2, 2)]
      inside = [(0, 0), (1, 0), (0, 1), (1, 1), (0, 1 / 2), (1, 1 / 2), (1 / 2, 0), (1 / 2, 1)]
  it "is refused for air and for every occupied key, before the air case" $
    forM_ (Nothing : map Just allShapeKeys) $ \key →
      forM_ outside $ \(x, y) → heightOf key x y `shouldBe` Left OutsideCellSquare
  it "is accepted at the endpoints of both axes" $ do
    forM_ inside $ \(x, y) → do
      heightOf Nothing x y `shouldBe` Right Nothing
      heightOf (Just (occupied 7)) x y `shouldSatisfy` either (const False) isJust

pieceSpec ∷ Spec
pieceSpec = describe "convex pieces" $ do
  it "give a side key its one convex solid, planes and facets unchanged" $
    forM_ [0 .. 15] $ \value → do
      let key = sideKey (sideId value)
      map piecePlanes (convexPieces key) `shouldBe` [solidPlanes (shapeSolid (sideId value))]
      boundaryFaces key `shouldBe` solidFaces (shapeSolid (sideId value))
  it "give a bank one piece and a valley two, leaving the flat half of a bank empty" $ do
    forM_ [1, 2, 4, 8] $ \value → length (convexPieces (occupied value)) `shouldBe` 1
    forM_ [5, 10] $ \value → length (convexPieces (occupied value)) `shouldBe` 2
  it "have positive volume: some point lies strictly inside every plane of every piece" $
    forM_ [occupied value | value ← [1 .. 15]] $ \key →
      forM_ (convexPieces key) $ \piece →
        [() | p ← interior, all (\plane → planeAt plane p < 0) (piecePlanes piece)] `shouldSatisfy` (not . null)
  where
    interior = [V3 (a / 16) (b / 16) (c / 16) | a ← [1 .. 15], b ← [1 .. 15], c ← [1 .. 15]]

-- | Sample heights in eighths, from below the base to above the level.
levels ∷ [Rational]
levels = [fromIntegral k / 8 | k ← [-1 .. 16 ∷ Int]]

planeSpec ∷ Spec
planeSpec = describe "plane signs" $ do
  it "put a point strictly inside a piece's footprint and below the reference height below every plane of that piece" $
    [ (value, x, y, z)
    | value ← [1 .. 15]
    , (x, y) ← grid
    , x > 0 && x < 1 && y > 0 && y < 1 && x /= y && x + y /= 1
    , z ← levels
    , z > 0
    , Just h ← [surfaceHeightReference value x y]
    , z < h
    , let p = V3 x y z
          holding = [piece | piece ← convexPieces (occupied value), all (\plane → planeAt plane p < 0) (piecePlanes piece)]
    , length holding /= 1
    ]
      `shouldBe` []
  it "put a point on or below the reference height, above the base, inside the closed union" $
    [ (value, x, y, z)
    | value ← [1 .. 15]
    , (x, y) ← grid
    , z ← levels
    , z > 0
    , Just h ← [surfaceHeightReference value x y]
    , z <= h
    , let p = V3 x y z
    , not (any (\piece → all (\plane → planeAt plane p <= 0) (piecePlanes piece)) (convexPieces (occupied value)))
    ]
      `shouldBe` []
  it "put a point above the reference height, or below the base, positive on at least one plane of every piece" $
    [ (value, x, y, z)
    | value ← [1 .. 15]
    , (x, y) ← grid
    , z ← levels
    , Just h ← [surfaceHeightReference value x y]
    , z > h || z < 0
    , let p = V3 x y z
    , any (\piece → not (any (\plane → planeAt plane p > 0) (piecePlanes piece))) (convexPieces (occupied value))
    ]
      `shouldBe` []

facetSpec ∷ Spec
facetSpec = describe "external facets" $ do
  forM_ [1 .. 15] $ \value → describe ("corner mask " <> show value) $ do
    let key = occupied value
        facets = boundaryFaces key
        areaOf kind component = sum [component (vectorArea (faceVertices f)) | f ← facets, faceKind f == kind]
    it "lie on their planes and wind counter-clockwise seen from outside" $
      forM_ facets $ \facet → do
        forM_ (faceVertices facet) $ \v → planeAt (facePlane facet) v `shouldBe` 0
        dotV (vectorArea (faceVertices facet)) (planeNormal (facePlane facet)) `shouldSatisfy` (> 0)
    it "face up for tops, down for the bottom and outward on a cell side for walls" $
      forM_ facets $ \facet → do
        let area = vectorArea (faceVertices facet)
            onSide f = all f (faceVertices facet)
        case faceKind facet of
          TopFace → areaZ area `shouldSatisfy` (> 0)
          BottomFace → do
            (areaX area, areaY area) `shouldBe` (0, 0)
            areaZ area `shouldSatisfy` (< 0)
          WallFace North → do
            onSide (\(V3 _ y _) → y == 0) `shouldBe` True
            (areaX area, areaZ area) `shouldBe` (0, 0)
            areaY area `shouldSatisfy` (< 0)
          WallFace South → do
            onSide (\(V3 _ y _) → y == 1) `shouldBe` True
            (areaX area, areaZ area) `shouldBe` (0, 0)
            areaY area `shouldSatisfy` (> 0)
          WallFace East → do
            onSide (\(V3 x _ _) → x == 1) `shouldBe` True
            (areaY area, areaZ area) `shouldBe` (0, 0)
            areaX area `shouldSatisfy` (> 0)
          WallFace West → do
            onSide (\(V3 x _ _) → x == 0) `shouldBe` True
            (areaY area, areaZ area) `shouldBe` (0, 0)
            areaX area `shouldSatisfy` (< 0)
    it "cover the footprint where the reference is positive, with the top and the bottom each" $ do
      areaOf TopFace areaZ `shouldBe` referencePositiveArea value
      negate (areaOf BottomFace areaZ) `shouldBe` referencePositiveArea value
    it "give each wall the area under the reference along its side" $
      forM_ [North, East, South, West] $ \side → do
        let component = case side of
              North → negate . areaY
              South → areaY
              East → areaX
              West → negate . areaX
        areaOf (WallFace side) component `shouldBe` referenceWall value side
    it "close the surface and enclose exactly the volume under the reference" $ do
      foldr
        (\f (V3 a b c) → let V3 d e g = vectorArea (faceVertices f) in V3 (a + d) (b + e) (c + g))
        (V3 0 0 0)
        facets
        `shouldBe` V3 0 0 0
      sum [dotV (firstCorner f) (vectorArea (faceVertices f)) | f ← facets] / 3
        `shouldBe` referenceVolume value
  describe "the sides of the reference" $ do
    it "are linear: the height at a side's midpoint is the mean of its ends" $
      forM_ [(v, s) | v ← [1 .. 15], s ← [North, East, South, West]] $ \(v, s) → do
        let (a, b, m) = case s of
              North → ((0, 0), (1, 0), (1 / 2, 0))
              East → ((1, 0), (1, 1), (1, 1 / 2))
              South → ((0, 1), (1, 1), (1 / 2, 1))
              West → ((0, 0), (0, 1), (0, 1 / 2))
        referenceAt v m `shouldBe` (referenceAt v a + referenceAt v b) / 2
    it "give the bank of mask 1 a half on the north and west, and none on the east and south" $
      [referenceWall 1 s | s ← [North, East, South, West]] `shouldBe` [1 / 2, 0, 0, 1 / 2]
  where
    firstCorner facet = case faceVertices facet of
      v : _ → v
      [] → V3 0 0 0

clippingSpec ∷ Spec
clippingSpec = describe "clipping against the union of the pieces" $ do
  it "meets the solid of every corner key along a line exactly where the reference solid is" $
    [ (value, through, direction, z, t)
    | value ← [1 .. 15]
    , direction ← [V3 1 0 0, V3 0 1 0, V3 1 1 0, V3 1 (-1) 0]
    , through ← [(1 / 2, 1 / 2), (1 / 4, 3 / 4), (3 / 4, 1 / 4), (1 / 2, 1 / 4)]
    , z ← [1 / 8, 1 / 4, 1 / 2, 3 / 4, 1]
    , let V3 dx dy _ = direction
          origin = V3 (fst through - dx) (snd through - dy) z
          intervals = unionIntervals (pieceIntervals (occupied value) origin direction)
    , t ← [fromIntegral k / 64 | k ← [0 .. 128 ∷ Int]]
    , any (\(lo, hi) → lo <= t && t <= hi) intervals /= insideReference value (along origin direction t)
    ]
      `shouldBe` []
  it "recovers one entry and one exit across the internal partition of a three-high mask" $
    forM_ [7, 11, 13, 14] $ \value → do
      let key = occupied value
          -- The crease of 11 and 14 is x + y = 1 and of 7 and 13 is x = y.
          (direction, onCrease) =
            if value `elem` [11, 14]
              then (V3 1 1 0, \(V3 x y _) → x + y == 1)
              else (V3 1 (-1) 0, \(V3 x y _) → x == y)
          origin = if value `elem` [11, 14] then V3 (-1 / 2) (-1 / 2) (1 / 4) else V3 (-1 / 2) (3 / 2) (1 / 4)
          pieces = mapMaybe (\piece → pieceInterval piece origin direction) (convexPieces key)
      length (convexPieces key) `shouldBe` 2
      -- Each piece gives its own interval; they meet at the crossing, t = 1.
      case sort pieces of
        [(_, firstEnd), (secondStart, _)] → (firstEnd, secondStart) `shouldBe` (1, 1)
        other → expectationFailure ("expected two intervals, got " <> show other)
      case unionIntervals pieces of
        [(lo, hi)] → do
          lo `shouldSatisfy` (< 1)
          hi `shouldSatisfy` (> 1)
        other → expectationFailure ("expected one interval, got " <> show other)
      -- No external facet lies on the partition.
      forM_ (boundaryFaces key) $ \facet → all onCrease (faceVertices facet) `shouldBe` False
  it "meets no piece under the flat half of a bank, though the height there is zero" $ do
    let key = occupied 1
    pieceIntervals key (V3 (3 / 4) (3 / 4) 2) (V3 0 0 (-1)) `shouldBe` []
    heightOf (Just key) (3 / 4) (3 / 4) `shouldBe` Right (Just 0)
  it "meets a vertical line in the segment from the base to the height, or in no more than a point" $
    [ (value, x, y, got)
    | value ← [1 .. 15]
    , (x, y) ← grid
    , let got = unionIntervals (pieceIntervals (occupied value) (V3 x y (-1)) (V3 0 0 1))
          want = case surfaceHeightReference value x y of
            Just h | h > 0 → [(1, 1 + h)]
            _ → []
    , if want == [] then any (\(lo, hi) → lo /= hi) got else got /= want
    ]
      `shouldBe` []
