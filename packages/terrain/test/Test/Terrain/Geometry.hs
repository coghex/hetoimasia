-- | Examples for the canonical cell solids and their pure queries.
--
-- Expected geometry is the hand-authored matrix in "Test.Terrain.Fixtures": the
-- vertices and faces of all sixteen identities, which the library neither reads
-- nor writes. The independent oracle for the property examples is a small
-- height-field predicate defined here, not the library's half-space list.
module Test.Terrain.Geometry (spec) where

import Control.Monad (forM_)
import Data.List (sort)
import Data.Maybe (isJust)
import Hetoimasia.Terrain.Coordinate (TileCoord (..), axisFromInteger)
import Hetoimasia.Terrain.Geometry
import Hetoimasia.Terrain.Shape
import Test.Hspec
import Test.QuickCheck
import Test.Terrain.Fixtures

shape ∷ Int → ShapeId
shape value = either (error . show) id (mkShapeId value)

solid ∷ Int → Solid
solid = shapeSolid . shape

toP ∷ V3 → P
toP (V3 x y z) = (x, y, z)

point ∷ Rational → Rational → Rational → V3
point = V3

faceLabel ∷ FaceKind → String
faceLabel TopFace = "Top"
faceLabel BottomFace = "Bottom"
faceLabel (WallFace North) = "WallN"
faceLabel (WallFace East) = "WallE"
faceLabel (WallFace South) = "WallS"
faceLabel (WallFace West) = "WallW"

-- | The faces as sorted (label, sorted corners) pairs, so two descriptions of
-- the same faces compare equal whatever their order.
faceSet ∷ Solid → [(String, [P])]
faceSet s = sort [(faceLabel (faceKind face), sort (map toP (faceVertices face))) | face ← solidFaces s]

fixtureFaceSet ∷ ShapeFixture → [(String, [P])]
fixtureFaceSet fixture = sort [(fixtureFace face, sort (fixtureCorners face)) | face ← fixtureFaces fixture]

-- | The tests' own positive quarter turn of a local point, applied repeatedly:
-- East of the cell becomes South, so @(x, y)@ goes to @(1 - y, x)@.
quarter ∷ P → P
quarter (x, y, z) = (1 - y, x, z)

rotated ∷ Int → P → P
rotated count = (!! count) . iterate quarter

-- | A wall face moves with its side under a positive turn.
rotatedLabel ∷ Int → String → String
rotatedLabel count name = case lookup name (zip walls (drop count (cycle walls))) of
  Just moved → moved
  Nothing → name
  where
    walls = ["WallN", "WallE", "WallS", "WallW"]

fixtureOf ∷ Int → ShapeFixture
fixtureOf identity = head' [fixture | fixture ← shapeFixtures, fixtureId fixture == identity]
  where
    head' (x : _) = x
    head' [] = error "no such fixture"

spec ∷ Spec
spec = describe "Geometry" $ do
  matrixSpec
  rotationSpec
  coverageSpec
  membershipSpec
  raySpec
  inputSpec

matrixSpec ∷ Spec
matrixSpec = describe "the sixteen canonical solids" $ do
  it "has a fixture for every identity" $
    map fixtureId shapeFixtures `shouldBe` [0 .. 15]
  forM_ shapeFixtures $ \fixture →
    describe ("identity " <> show (fixtureId fixture) <> " " <> shapeName (shape (fixtureId fixture))) $ do
      it "has exactly the expected vertices" $
        sort (map toP (solidVertices (solid (fixtureId fixture)))) `shouldBe` sort (fixtureVertices fixture)
      it "has exactly the expected faces" $
        faceSet (solid (fixtureId fixture)) `shouldBe` fixtureFaceSet fixture
      it "lists faces in canonical order, top surfaces first and the bottom last" $ do
        let kinds = map faceKind (solidFaces (solid (fixtureId fixture)))
        kinds `shouldBe` sort kinds
      it "has faces whose corners wind counter-clockwise seen from outside" $
        forM_ (solidFaces (solid (fixtureId fixture))) $ \face →
          dotP (newell (map toP (faceVertices face))) (toP (planeNormal (facePlane face))) `shouldSatisfy` (> 0)
      it "has the identity it was asked for" $
        shapeIdValue (solidShape (solid (fixtureId fixture))) `shouldBe` fixtureId fixture
  it "has five faces for every identity but the flat ones, which have six" $
    map (length . solidFaces . solid) [0 .. 15] `shouldBe` [6, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 6]
  it "keeps identities 0 and 15 distinct but gives them one solid shape" $ do
    solidShape (solid 0) `shouldNotBe` solidShape (solid 15)
    solidVertices (solid 0) `shouldBe` solidVertices (solid 15)
    faceSet (solid 0) `shouldBe` faceSet (solid 15)
  it "gives NS and EW different solids" $
    faceSet (solid 5) `shouldNotBe` faceSet (solid 10)
  it "covers the whole footprint with top faces and the bottom with one face" $
    forM_ [0 .. 15] $ \identity → do
      let faces = solidFaces (solid identity)
      sum [faceFootprintArea face | face ← faces, faceKind face == TopFace] `shouldBe` 1
      sum [faceFootprintArea face | face ← faces, faceKind face == BottomFace] `shouldBe` 1
  where
    dotP (a, b, c) (d, e, f) = a * d + b * e + c * f
    -- The vector area of a polygon, by the shoelace sum of cross products.
    newell ∷ [P] → P
    newell corners =
      foldr add (0, 0, 0) (zipWith crossP corners (drop 1 corners <> take 1 corners))
    add (a, b, c) (d, e, f) = (a + d, b + e, c + f)
    crossP (a, b, c) (d, e, f) = (b * f - c * e, c * d - a * f, a * e - b * d)

rotationSpec ∷ Spec
rotationSpec = describe "quarter turns of the geometry" $ do
  it "has hand-authored fixtures that are themselves consistent under rotation (fixtureConsistentUnderRotation)" $
    forM_ (zip [0 ..] rotationTable) $ \(identity, row) →
      forM_ (zip [0 ..] row) $ \(count, target) → do
        sort (map (rotated count) (fixtureVertices (fixtureOf identity))) `shouldBe` sort (fixtureVertices (fixtureOf target))
        sort [(rotatedLabel count (fixtureFace face), sort (map (rotated count) (fixtureCorners face))) | face ← fixtureFaces (fixtureOf identity)]
          `shouldBe` fixtureFaceSet (fixtureOf target)
  it "gives the rotated identity the rotated solid, vertices and faces, in all four facings" $
    forM_ [0 .. 15] $ \identity →
      forM_ [0 .. 3] $ \count → do
        let target = shapeSolid (rotateShape (turns count) (shape identity))
        sort (map toP (solidVertices target)) `shouldBe` sort (map (rotated count) (fixtureVertices (fixtureOf identity)))
        faceSet target
          `shouldBe` sort [(rotatedLabel count (fixtureFace face), sort (map (rotated count) (fixtureCorners face))) | face ← fixtureFaces (fixtureOf identity)]
  it "rotates points the way the shape rotates, so one authority serves faces and picking" $
    forM_ [0 .. 15] $ \identity →
      forM_ [0 .. 3] $ \count →
        sort (map (rotatePoint (turns count)) (solidVertices (solid identity)))
          `shouldBe` sort (solidVertices (shapeSolid (rotateShape (turns count) (shape identity))))
  it "restores a point after four turns and keeps the centre fixed" $ do
    let p = point (1 / 3) (2 / 7) (5 / 11)
    rotatePoint (turns 4) p `shouldBe` p
    rotatePoint (turns 1) (point (1 / 2) (1 / 2) 0) `shouldBe` point (1 / 2) (1 / 2) 0
  it "turns the East ramp into the South ramp: a world identity moves only its mask" $ do
    -- The world shape 2 (East) seen with one positive turn is shape 4 (South).
    rotateShape (turns 1) (shape 2) `shouldBe` shape 4
    sort (map toP (solidVertices (solid 4))) `shouldBe` sort (map (rotated 1) (fixtureVertices (fixtureOf 2)))

coverageSpec ∷ Spec
coverageSpec = describe "face coverage of the cell sides" $ do
  it "matches the hand-computed wall areas of every identity and side" $
    forM_ (zip [0 ..] wallAreaTable) $ \(identity, areas) →
      map (sideCoverageArea (shape identity)) allSides `shouldBe` areas
  it "classifies the coverage as none, partial or full" $
    forM_ (zip [0 ..] wallAreaTable) $ \(identity, areas) →
      map (sideCoverage (shape identity)) allSides `shouldBe` map coverageOf areas
  it "has a fully covered side only opposite a lowered one, or on a flat identity" $ do
    sideCoverage (shape 1) South `shouldBe` FullCoverage
    sideCoverage (shape 1) North `shouldBe` NoCoverage
    sideCoverage (shape 5) East `shouldBe` PartialCoverage
    sideCoverage (shape 15) West `shouldBe` FullCoverage
  where
    coverageOf ∷ Rational → Coverage
    coverageOf 0 = NoCoverage
    coverageOf 1 = FullCoverage
    coverageOf _ = PartialCoverage

-- | The oracle: a point is in the closed solid of a shape when it is in the
-- unit footprint, at or above the base and at or below every ramp the mask
-- sets; it is interior when each of those holds strictly.
height ∷ [Side] → Rational → Rational → Rational
height sides x y = minimum (1 : [ramp side | side ← sides])
  where
    ramp North = y
    ramp East = 1 - x
    ramp South = 1 - y
    ramp West = x

-- | Flat identities have the full height 1, which 'height' gives for no sides.
oracle ∷ Int → V3 → PointClass
oracle identity (V3 x y z)
  | x < 0 || x > 1 || y < 0 || y > 1 || z < 0 || z > top = Exterior
  | x > 0 && x < 1 && y > 0 && y < 1 && z > 0 && z < top = Interior
  | otherwise = Boundary
  where
    sides = if identity == 15 then [] else shapeSides (shape identity)
    top = height sides x y

membershipSpec ∷ Spec
membershipSpec = describe "point membership" $ do
  forM_ examples $ \(identity, p, expected) →
    it ("classifies " <> show (toP p) <> " in identity " <> show identity <> " as " <> show expected) $
      classifyPoint (solid identity) p `shouldBe` expected
  it "tells a shared face, edge and vertex between two cells apart from the interior of either" $ do
    -- The east face of one cell and the west face of its east neighbour are the same plane.
    classifyPoint (solid 0) (point 1 (1 / 2) (1 / 2)) `shouldBe` Boundary
    classifyPoint (solid 0) (point 0 (1 / 2) (1 / 2)) `shouldBe` Boundary
    classifyPoint (solid 0) (point 1 1 (1 / 2)) `shouldBe` Boundary
    classifyPoint (solid 0) (point 1 1 1) `shouldBe` Boundary
  it "keeps a lowered side's zero-thickness edge on the boundary, and the air above it outside" $ do
    classifyPoint (solid 1) (point (1 / 2) 0 0) `shouldBe` Boundary
    classifyPoint (solid 1) (point (1 / 2) 0 (1 / 1000)) `shouldBe` Exterior
  it "agrees with the independent height-field oracle on random points of every identity" $
    property $ forAll ((,) <$> choose (0, 15) <*> genPoint) $ \(identity, p) →
      classifyPoint (solid identity) p === oracle identity p
  where
    examples ∷ [(Int, V3, PointClass)]
    examples =
      [ (0, point (1 / 2) (1 / 2) (1 / 2), Interior)
      , (0, point (1 / 2) (1 / 2) 1, Boundary)
      , (0, point (1 / 2) (1 / 2) (1001 / 1000), Exterior)
      , (0, point (1 / 2) (1 / 2) (-1 / 1000), Exterior)
      , (0, point (-1 / 1000) (1 / 2) (1 / 2), Exterior)
      , (0, point 5 5 5, Exterior)
      , (15, point (1 / 2) (1 / 2) (1 / 2), Interior)
      , (15, point (1 / 2) (1 / 2) 1, Boundary)
      , (1, point (1 / 2) (1 / 2) (1 / 4), Interior)
      , (1, point (1 / 2) (1 / 2) (1 / 2), Boundary)
      , (1, point (1 / 2) (1 / 2) (3 / 4), Exterior)
      , (1, point (1 / 2) (1 / 10) (1 / 5), Exterior)
      , (1, point (1 / 2) 1 1, Boundary)
      , (3, point 0 1 1, Boundary)
      , (3, point (1 / 4) (3 / 4) (1 / 4), Interior)
      , (3, point (1 / 4) (3 / 4) (3 / 4), Boundary)
      , (3, point (1 / 4) (3 / 4) (4 / 5), Exterior)
      , (5, point (1 / 2) (1 / 2) (1 / 2), Boundary)
      , (5, point (1 / 2) (1 / 2) (51 / 100), Exterior)
      , (5, point (1 / 2) (1 / 4) (1 / 5), Interior)
      , (5, point (1 / 2) (1 / 4) (1 / 4), Boundary)
      , (10, point (1 / 4) (1 / 2) (1 / 4), Boundary)
      , (10, point (1 / 4) (1 / 2) (3 / 10), Exterior)
      , (7, point (1 / 2) (1 / 2) (1 / 2), Boundary)
      , (7, point (1 / 4) (1 / 2) (1 / 4), Interior)
      , (7, point (1 / 4) (1 / 2) (1 / 2), Boundary)
      , (7, point (1 / 4) (1 / 2) (3 / 5), Exterior)
      ]

-- | Rational points around the unit cell on a grid fine enough to hit its
-- faces, edges and vertices, with a share of off-grid values.
genPoint ∷ Gen V3
genPoint = V3 <$> coordinate <*> coordinate <*> coordinate
  where
    coordinate = frequency [(4, (/ 4) . fromInteger <$> choose (-2, 6)), (1, (/ 7) . fromInteger <$> choose (-3, 10))]

hit ∷ Solid → V3 → V3 → Maybe RayHit
hit s origin direction = either (const Nothing) (castRay s) (mkRay origin direction)

hitOrFail ∷ Solid → V3 → V3 → IO RayHit
hitOrFail s origin direction = case hit s origin direction of
  Just found → pure found
  Nothing → expectationFailure "the ray should hit" >> error "unreachable"

faceKindOf ∷ RayHit → Maybe FaceKind
faceKindOf = fmap faceKind . hitFace

raySpec ∷ Spec
raySpec = describe "ray and segment queries" $ do
  it "hits the top of a flat cell from above, entering the top face" $ do
    found ← hitOrFail (solid 0) (point (1 / 2) (1 / 2) 2) (point 0 0 (-1))
    hitParameter found `shouldBe` 1
    toP (hitPoint found) `shouldBe` (1 / 2, 1 / 2, 1)
    hitContact found `shouldBe` Enters
    faceKindOf found `shouldBe` Just TopFace
  it "hits a ramp at its own height" $ do
    found ← hitOrFail (solid 1) (point (1 / 2) (1 / 4) 2) (point 0 0 (-1))
    hitParameter found `shouldBe` 7 / 4
    toP (hitPoint found) `shouldBe` (1 / 2, 1 / 4, 1 / 4)
    faceKindOf found `shouldBe` Just TopFace
  it "enters a wedge through its ramp, not through the lowered side's empty wall" $ do
    found ← hitOrFail (solid 1) (point (1 / 2) (-1) (1 / 4)) (point 0 1 0)
    hitParameter found `shouldBe` 5 / 4
    toP (hitPoint found) `shouldBe` (1 / 2, 1 / 4, 1 / 4)
    hitContact found `shouldBe` Enters
    faceKindOf found `shouldBe` Just TopFace
  it "enters through a side wall" $ do
    found ← hitOrFail (solid 0) (point (-1) (1 / 2) (1 / 2)) (point 1 0 0)
    hitParameter found `shouldBe` 1
    hitContact found `shouldBe` Enters
    faceKindOf found `shouldBe` Just (WallFace West)
  it "enters a flat cell from below through the bottom" $ do
    found ← hitOrFail (solid 0) (point (1 / 2) (1 / 2) (-3)) (point 0 0 1)
    hitParameter found `shouldBe` 3
    faceKindOf found `shouldBe` Just BottomFace
  it "misses a ray that never comes near, and one parallel and outside" $ do
    hit (solid 0) (point (1 / 2) (1 / 2) 2) (point 1 0 0) `shouldBe` Nothing
    hit (solid 0) (point 3 3 3) (point 1 1 1) `shouldBe` Nothing
    hit (solid 0) (point (1 / 2) (1 / 2) 2) (point 0 0 1) `shouldBe` Nothing
  it "starts inside with no face when the origin is interior" $ do
    found ← hitOrFail (solid 0) (point (1 / 2) (1 / 2) (1 / 2)) (point 0 0 1)
    hitParameter found `shouldBe` 0
    hitContact found `shouldBe` StartsInside
    hitFace found `shouldBe` Nothing
  it "enters at t = 0 from an origin on the boundary that moves inward" $ do
    found ← hitOrFail (solid 0) (point (1 / 2) (1 / 2) 1) (point 0 0 (-1))
    hitParameter found `shouldBe` 0
    hitContact found `shouldBe` Enters
    faceKindOf found `shouldBe` Just TopFace
  it "grazes at t = 0 from an origin on the boundary that moves outward" $ do
    found ← hitOrFail (solid 0) (point (1 / 2) (1 / 2) 1) (point 0 0 1)
    hitParameter found `shouldBe` 0
    hitContact found `shouldBe` Grazes
    faceKindOf found `shouldBe` Just TopFace
  it "grazes a ray that runs along an edge, at its first contact point" $ do
    found ← hitOrFail (solid 0) (point (-1) 0 1) (point 1 0 0)
    hitParameter found `shouldBe` 1
    toP (hitPoint found) `shouldBe` (0, 0, 1)
    hitContact found `shouldBe` Grazes
    -- The edge belongs to the top and the north wall; the top comes first.
    faceKindOf found `shouldBe` Just TopFace
  it "grazes a ray that lies in a face plane, never entering through that face" $ do
    found ← hitOrFail (solid 0) (point (-1) (1 / 2) 1) (point 1 0 0)
    hitContact found `shouldBe` Grazes
    faceKindOf found `shouldBe` Just TopFace
  it "enters through a vertex by the first face, in canonical order, that it moves into" $ do
    found ← hitOrFail (solid 0) (point (-1) (-1) 2) (point 1 1 (-1))
    hitParameter found `shouldBe` 1
    toP (hitPoint found) `shouldBe` (0, 0, 1)
    hitContact found `shouldBe` Enters
    faceKindOf found `shouldBe` Just TopFace
  it "enters through an edge by the first face, in canonical order, that it moves into" $ do
    -- The top-north edge belongs to the top and the north wall, and the ray moves into both.
    found ← hitOrFail (solid 0) (point (1 / 2) (-1) 2) (point 0 1 (-1))
    hitParameter found `shouldBe` 1
    toP (hitPoint found) `shouldBe` (1 / 2, 0, 1)
    hitContact found `shouldBe` Enters
    faceKindOf found `shouldBe` Just TopFace
  it "touches the apex of a corner slope by the first face containing it" $ do
    -- Identity 3 has its apex at (0, 1, 1); this ray runs along the top edge of the south wall.
    found ← hitOrFail (solid 3) (point (-1) 1 2) (point 1 0 (-1))
    hitParameter found `shouldBe` 1
    toP (hitPoint found) `shouldBe` (0, 1, 1)
    hitContact found `shouldBe` Grazes
    fmap (planeNormal . facePlane) (hitFace found) `shouldBe` Just (point 0 (-1) 1)
  it "touches a ridge from outside without entering" $ do
    found ← hitOrFail (solid 5) (point (-1) (1 / 2) (1 / 2)) (point 1 0 0)
    hitContact found `shouldBe` Grazes
    hitParameter found `shouldBe` 1
  it "returns the same first contact for a segment that reaches it, and none for a short one" $ do
    first ← hitOrFail (solid 0) (point (1 / 2) (1 / 2) 2) (point 0 0 (-1))
    castSegment (solid 0) (point (1 / 2) (1 / 2) 2) (point (1 / 2) (1 / 2) 0)
      `shouldBe` Right (Just first {hitParameter = 1 / 2})
    castSegment (solid 0) (point (1 / 2) (1 / 2) 2) (point (1 / 2) (1 / 2) (3 / 2)) `shouldBe` Right Nothing
  it "grazes when a segment ends exactly on the boundary, and enters when it passes it" $ do
    fmap (fmap hitContact) (castSegment (solid 0) (point (1 / 2) (1 / 2) 2) (point (1 / 2) (1 / 2) 1))
      `shouldBe` Right (Just Grazes)
    fmap (fmap hitContact) (castSegment (solid 0) (point (1 / 2) (1 / 2) 2) (point (1 / 2) (1 / 2) (1 / 2)))
      `shouldBe` Right (Just Enters)
  it "refuses a segment of no length" $
    castSegment (solid 0) (point 0 0 0) (point 0 0 0) `shouldBe` Left ZeroLengthDirection
  it "agrees with the oracle: the first non-exterior sample is never before the hit, and a miss has none" $
    property $ forAll ((,,) <$> choose (0, 15) <*> genPoint <*> genDirection) $ \(identity, origin, direction) →
      let s = solid identity
          samples = [(t, classifyPoint s (origin `along` (t, direction))) | t ← map (/ 8) [0 .. 48]]
          touching = [t | (t, c) ← samples, c /= Exterior]
       in case hit s origin direction of
            Nothing → counterexample "a miss with a sample inside" (null touching)
            Just found →
              let earlier = [t | t ← touching, t < hitParameter found]
               in conjoin
                    [ counterexample "a sample precedes the hit" (null earlier)
                    , counterexample "the hit point is exterior" (classifyPoint s (hitPoint found) /= Exterior)
                    , counterexample "the hit point is not on the ray" (hitPoint found === origin `along` (hitParameter found, direction))
                    , counterexample "no face for a boundary hit" (isJust (hitFace found) === (hitContact found /= StartsInside))
                    ]
  where
    along (V3 ox oy oz) (t, V3 dx dy dz) = V3 (ox + t * dx) (oy + t * dy) (oz + t * dz)

genDirection ∷ Gen V3
genDirection =
  (V3 <$> component <*> component <*> component) `suchThat` (/= V3 0 0 0)
  where
    component = (/ 2) . fromInteger <$> choose (-4, 4)

inputSpec ∷ Spec
inputSpec = describe "inputs" $ do
  it "refuses a ray with no direction" $
    mkRay (point 0 0 0) (point 0 0 0) `shouldBe` Left ZeroLengthDirection
  it "refuses a non-finite floating-point component, in the origin or the direction" $ do
    mkRayFromDoubles (nan, 0, 0) (0, 0, 1) `shouldBe` Left NonFiniteComponent
    mkRayFromDoubles (0, 0, 0) (0, infinity, 1) `shouldBe` Left NonFiniteComponent
    mkRayFromDoubles (0, 0, 0) (0, 0, negate infinity) `shouldBe` Left NonFiniteComponent
    v3FromDoubles 0 nan 0 `shouldBe` Left NonFiniteComponent
    v3FromDoubles infinity 0 0 `shouldBe` Left NonFiniteComponent
  it "reports a non-finite component before a zero direction" $
    mkRayFromDoubles (nan, 0, 0) (0, 0, 0) `shouldBe` Left NonFiniteComponent
  it "converts finite floating-point input exactly" $ do
    v3FromDoubles 0.5 0.25 (-2) `shouldBe` Right (point (1 / 2) (1 / 4) (-2))
    fmap rayOrigin (mkRayFromDoubles (0.5, 0.5, 2) (0, 0, -1)) `shouldBe` Right (point (1 / 2) (1 / 2) 2)
    fmap rayDirection (mkRayFromDoubles (0.5, 0.5, 2) (0, 0, -1)) `shouldBe` Right (point 0 0 (-1))
    fmap (fmap hitParameter . castRay (solid 0)) (mkRayFromDoubles (0.5, 0.5, 2) (0, 0, -1)) `shouldBe` Right (Just 1)
  it "places a cell-local point in tile space exactly, at the extreme coordinates" $ do
    let axisOf = either (error . show) id . axisFromInteger
        far = TileCoord (axisOf 4611686018427387903) (axisOf (-4611686018427387904)) (axisOf 0)
    cellWorldPoint far (point 1 (1 / 2) (1 / 4))
      `shouldBe` point 4611686018427387904 (-9223372036854775807 / 2) (1 / 4)
  where
    nan = 0 / 0 ∷ Double
    infinity = 1 / 0 ∷ Double
