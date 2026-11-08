-- | Examples for the cell openings, their components and the connections between
-- neighboring cells (TRA-13, #655).
--
-- Every expectation here is authored independently of the code under test:
--
-- * the area of each face's opening for all sixteen identities is the hand table
--   'openingAreaTable' in "Test.Terrain.Fixtures";
-- * which points of a face are open air comes from 'topHeight', the height rule
--   stated from the mask bits alone, and from this module's own statement of the
--   face coordinates ('airAt'), sampled on a rational lattice that avoids every
--   boundary of every opening;
-- * the area two neighbors share is integrated here, exactly, from the two
--   height functions along the shared edge ('sharedArea');
-- * a quarter turn of a tile offset, of a face and of a point is restated here
--   ('turnOffset', 'turnFace', 'quarter'), not borrowed from the library;
-- * a path through a world is searched here, over the connections the library
--   reports, with a missing tile meaning unavailable and never air.
module Test.Terrain.Opening (spec) where

import Control.Monad (forM_)
import Data.List (sort)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Geometry
import Hetoimasia.Terrain.Opening
import Hetoimasia.Terrain.Shape
import Test.Hspec
import Test.Terrain.Fixtures (openingAreaTable, topHeight)

-- ---------------------------------------------------------------------------
-- Small helpers

shape ∷ Int → ShapeId
shape value = either (error . show) id (mkShapeId value)

openings ∷ Int → CellOpenings
openings = shapeOpenings . shape

tile ∷ Integer → Integer → Integer → TileCoord
tile x y z = either (error . show) id (tileCoord x y z)

point ∷ Rational → Rational → Rational → V3
point = V3

type P2 = (Rational, Rational)

-- | The one element of a list that must have exactly one.
only ∷ [a] → a
only [x] = x
only _ = error "expected exactly one element"

-- | The faces in the order the area table lists them: top, North, East, South,
-- West, bottom.
faceOrder ∷ [FaceKind]
faceOrder = [TopFace, WallFace North, WallFace East, WallFace South, WallFace West, BottomFace]

-- | The total area of the portals of a cell on a face.
faceArea ∷ CellOpenings → FaceKind → Rational
faceArea ops face = sum [openingArea (portalOpening p) | p ← portalsOn face ops]

-- | Whether some portal of the cell on the face contains the face point.
faceHolds ∷ CellOpenings → FaceKind → P2 → Bool
faceHolds ops face p = or [openingContains (portalOpening portal) p | portal ← portalsOn face ops]

-- | The test's own statement of the face coordinates, each in @[0, 1]@: @(y, z)@
-- on East and West, @(x, z)@ on North and South, @(x, y)@ on top and bottom.
liftTo ∷ FaceKind → P2 → V3
liftTo (WallFace North) (u, v) = V3 u 0 v
liftTo (WallFace South) (u, v) = V3 u 1 v
liftTo (WallFace West) (u, v) = V3 0 u v
liftTo (WallFace East) (u, v) = V3 1 u v
liftTo TopFace (u, v) = V3 u v 1
liftTo BottomFace (u, v) = V3 u v 0

dropTo ∷ FaceKind → V3 → P2
dropTo (WallFace North) (V3 x _ z) = (x, z)
dropTo (WallFace South) (V3 x _ z) = (x, z)
dropTo (WallFace West) (V3 _ y z) = (y, z)
dropTo (WallFace East) (V3 _ y z) = (y, z)
dropTo TopFace (V3 x y _) = (x, y)
dropTo BottomFace (V3 x y _) = (x, y)

-- | Whether a face point is open air (strictly above the solid) for an identity,
-- from the height rule alone. The top is open where the solid is below the cell's
-- top, and the bottom is never open.
airAt ∷ Int → FaceKind → P2 → Bool
airAt identity face (u, v) = case face of
  WallFace North → v > topHeight identity u 0
  WallFace South → v > topHeight identity u 1
  WallFace West → v > topHeight identity 0 u
  WallFace East → v > topHeight identity 1 u
  TopFace → topHeight identity u v < 1
  BottomFace → False

-- | Sample points of a face, none of them on any boundary a catalog opening can
-- have: 16 odd multiples of 1/32 against 16 numerators of the form 4j + 3 over 64.
-- The boundaries lie on lines whose coordinates are multiples of 1/2 or on the
-- diagonals @v = u@ and @v = 1 - u@, and no sample is on one.
lattice ∷ [P2]
lattice = [(fromIntegral (2 * i + 1) / 32, fromIntegral (4 * j + 3) / 64) | i ← [0 .. 15 ∷ Int], j ← [0 .. 15 ∷ Int]]

-- | A positive quarter turn of a point: East of the cell becomes South.
quarter ∷ V3 → V3
quarter (V3 x y z) = V3 (1 - y) x z

-- | A face after a number of positive quarter turns: North to East to South to
-- West, the top and bottom staying.
turnFace ∷ Int → FaceKind → FaceKind
turnFace count (WallFace side) = WallFace (sides !! ((indexOf side + count) `mod` 4))
  where
    sides = [North, East, South, West]
    indexOf s = length (takeWhile (/= s) sides)
turnFace _ face = face

-- | A tile offset after a number of positive quarter turns about the origin cell:
-- @(dx, dy)@ goes to @(-dy, dx)@.
turnOffset ∷ Int → (Integer, Integer, Integer) → (Integer, Integer, Integer)
turnOffset count offset = iterate (\(dx, dy, dz) → (negate dy, dx, dz)) offset !! count

-- ---------------------------------------------------------------------------

spec ∷ Spec
spec = describe "Openings" $ do
  catalogSpec
  componentSpec
  rotationSpec
  sharedAreaSpec
  exampleSpec
  contactSpec
  pathSpec
  agreementSpec

-- | The openings of all sixteen identities in all four orientations.
catalogSpec ∷ Spec
catalogSpec = describe "the openings of the sixteen identities in the four orientations" $ do
  it "lists the cell faces in the order the tables use" $
    cellFaces `shouldBe` faceOrder
  forM_ [0 .. 15] $ \identity →
    forM_ [0 .. 3] $ \count →
      it ("opens identity " <> show identity <> " turned " <> show count <> " time(s) exactly as the independent tables and height rule say") $ do
        let turned = rotateShape (turns count) (shape identity)
            target = shapeIdValue turned
            ops = shapeOpenings turned
        -- The area of each face's opening is the table row of the turned identity,
        -- and it is also the original identity's area on the face that turned into it.
        map (faceArea ops) faceOrder `shouldBe` openingAreaTable !! target
        map (faceArea ops) faceOrder
          `shouldBe` [openingAreaTable !! identity !! faceIndex (turnFace (4 - count) face) | face ← faceOrder]
        -- The region itself is open air exactly where the height rule says.
        [(face, p) | face ← faceOrder, p ← lattice, faceHolds ops face p /= airAt target face p] `shouldBe` []
  it "gives a sealed block no portal at all, and every other identity a portal on its top" $
    forM_ [0 .. 15] $ \identity → do
      let ops = openings identity
      null (cellPortals ops) `shouldBe` (identity == 0)
      null (portalsOn TopFace ops) `shouldBe` (identity == 0)
      -- No catalog shape has a bottom opening of positive area.
      portalsOn BottomFace ops `shouldBe` []
  it "keeps a selected side open above its base and an unselected side partly open or sealed by the height function" $ do
    -- N (identity 1): fully open north, sealed south, triangular east and west of
    -- area 1/2, top 1.
    map (faceArea (openings 1)) [WallFace North, WallFace South, WallFace East, WallFace West, TopFace]
      `shouldBe` [1, 0, 1 / 2, 1 / 2, 1]
    -- NS: the unselected east and west are partly open, not sealed.
    map (faceArea (openings 5)) [WallFace East, WallFace West] `shouldBe` [3 / 4, 3 / 4]
    -- ID 15: every side and the top fully open, the bottom not at all.
    map (faceArea (openings 15)) faceOrder `shouldBe` [1, 1, 1, 1, 1, 0]
  it "states the exact corners of simple openings" $ do
    let corners ops face = sort (map sort (openingPieces (portalOpening (single (portalsOn face ops)))))
        square = [(0, 0), (0, 1), (1, 0), (1, 1)]
    -- N: the east and west openings are the triangle above z = y.
    corners (openings 1) (WallFace East) `shouldBe` [[(0, 0), (0, 1), (1, 1)]]
    corners (openings 1) (WallFace West) `shouldBe` [[(0, 0), (0, 1), (1, 1)]]
    corners (openings 1) (WallFace North) `shouldBe` [square]
    corners (openings 1) TopFace `shouldBe` [square]
    -- NE: the south opening is the triangle above z = 1 - x.
    corners (openings 3) (WallFace South) `shouldBe` [[(0, 1), (1, 0), (1, 1)]]
    corners (openings 3) (WallFace West) `shouldBe` [[(0, 0), (0, 1), (1, 1)]]
    -- ID 15: every side and the top is the whole face.
    forM_ [WallFace North, WallFace East, WallFace South, WallFace West, TopFace] $ \face →
      corners (openings 15) face `shouldBe` [square]
  it "splits every opening into convex pieces with area and no common interior" $
    forM_ [0 .. 15] $ \identity →
      forM_ faceOrder $ \face →
        forM_ (portalsOn face (openings identity)) $ \portal → do
          let pieces = openingPieces (portalOpening portal)
          forM_ pieces $ \piece → do
            length piece `shouldSatisfy` (>= 3)
            signedArea piece `shouldSatisfy` (> 0)
          sum (map signedArea pieces) `shouldBe` openingArea (portalOpening portal)
          -- No sample point is in two pieces.
          [p | p ← lattice, length [() | piece ← pieces, inside piece p] > 1] `shouldBe` []
  where
    faceIndex face = length (takeWhile (/= face) faceOrder)
    single (x : _) = x
    single [] = error "no portal on the face"
    signedArea piece = sum (zipWith (\(a, b) (c, d) → a * d - b * c) piece (drop 1 piece <> take 1 piece)) / 2
    inside piece p = all (\(a, b) → turnOf a b p >= 0) (zip piece (drop 1 piece <> take 1 piece))
    turnOf (ax, ay) (bx, by) (cx, cy) = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)

-- | Components are explicit and every portal belongs to one.
componentSpec ∷ Spec
componentSpec = describe "empty components" $ do
  it "gives a sealed block no component and every other identity exactly one" $
    map (length . cellComponents . openings) [0 .. 15] `shouldBe` 0 : replicate 15 1
  it "lists a component's portals, owned by that component, in face order" $
    forM_ [1 .. 15] $ \identity →
      forM_ (cellComponents (openings identity)) $ \component → do
        map portalComponent (componentPortals component) `shouldSatisfy` all (== componentIndex component)
        map portalFace (componentPortals component) `shouldBe` [face | face ← faceOrder, faceArea (openings identity) face > 0]
        concatMap componentPortals (cellComponents (openings identity)) `shouldBe` cellPortals (openings identity)
  it "has full air as one component open over the whole of all six faces, with no shape" $ do
    length (cellComponents airOpenings) `shouldBe` 1
    openingsShape airOpenings `shouldBe` Nothing
    map (faceArea airOpenings) faceOrder `shouldBe` replicate 6 1
    openingsShape (openings 7) `shouldBe` Just (shape 7)
  it "is connected: the empty space above the solid is one region (a flood fill on an eighth-cell grid)" $
    forM_ [1 .. 15] $ \identity →
      componentsOfGrid identity `shouldBe` 1
  where
    -- Independent check of the one-component claim. The empty region is
    -- discretized into cubes of side 1/8 whose centers are strictly above the
    -- height function, and the face-sharing connected components are counted.
    componentsOfGrid ∷ Int → Int
    componentsOfGrid identity = go (Set.fromList cubes) 0
      where
        n = 8 ∷ Int
        center i = (2 * fromIntegral i + 1) / (2 * fromIntegral n) ∷ Rational
        cubes = [(i, j, k) | i ← [0 .. n - 1], j ← [0 .. n - 1], k ← [0 .. n - 1], center k > topHeight identity (center i) (center j)]
        go remaining count = case Set.minView remaining of
          Nothing → count
          Just (start, rest) → go (flood rest [start]) (count + 1)
        flood remaining [] = remaining
        flood remaining (c : stack) =
          let near = [m | m ← neighbours c, m `Set.member` remaining]
           in flood (foldr Set.delete remaining near) (near <> stack)
        neighbours (i, j, k) = [(i + 1, j, k), (i - 1, j, k), (i, j + 1, k), (i, j - 1, k), (i, j, k + 1), (i, j, k - 1)]

-- | Rotation of the openings and their face coordinates.
rotationSpec ∷ Spec
rotationSpec = describe "quarter turns of the openings" $ do
  it "restores the original after four turns, for every identity and for air" $ do
    forM_ [0 .. 15] $ \identity →
      rotateOpenings (turns 4) (openings identity) `shouldBe` openings identity
    forM_ [0 .. 15] $ \identity →
      foldr (.) id (replicate 4 (rotateOpenings (turns 1))) (openings identity) `shouldBe` openings identity
    rotateOpenings (turns 1) airOpenings `shouldBe` airOpenings
  it "is the openings of the turned shape, and so adds up like the turns do" $
    forM_ [0 .. 15] $ \identity →
      forM_ [0 .. 3] $ \count → do
        rotateOpenings (turns count) (openings identity) `shouldBe` shapeOpenings (rotateShape (turns count) (shape identity))
        rotateOpenings (turns 1) (rotateOpenings (turns count) (openings identity))
          `shouldBe` rotateOpenings (turns (count + 1)) (openings identity)
  it "moves a point of an opening to the same place on the turned face, using the tests' own turn" $
    forM_ [0 .. 15] $ \identity →
      forM_ [1 .. 3] $ \count →
        forM_ faceOrder $ \face → do
          let turnedOps = rotateOpenings (turns count) (openings identity)
              turnedFace = turnFace count face
              move = dropTo turnedFace . (!! count) . iterate quarter . liftTo face
          [ p
            | p ← lattice
            , faceHolds (openings identity) face p /= faceHolds turnedOps turnedFace (move p)
            ]
            `shouldBe` []
  it "turns the vertical order of the faces with the sides and leaves the top and bottom" $ do
    oppositeFace TopFace `shouldBe` BottomFace
    oppositeFace (WallFace North) `shouldBe` WallFace South
    oppositeFace (WallFace East) `shouldBe` WallFace West
    forM_ faceOrder $ \face → oppositeFace (oppositeFace face) `shouldBe` face
    forM_ [0 .. 3] $ \count → forM_ faceOrder $ \face → rotateFace (turns count) face `shouldBe` turnFace count face
  it "leaves the authored shape identity alone: a view facing selects the turned openings and the world's are recovered" $
    forM_ allViewFacings $ \facing →
      forM_ [0 .. 15] $ \identity → do
        -- What a view at the facing sees is the openings of its selected mask ...
        rotateOpenings (facingTurns facing) (openings identity) `shouldBe` shapeOpenings (viewShape facing (shape identity))
        -- ... and the world shape, and with it every connection, is unchanged and recoverable.
        rotateOpenings (inverseTurns (facingTurns facing)) (shapeOpenings (viewShape facing (shape identity)))
          `shouldBe` openings identity
        openingsShape (openings identity) `shouldBe` Just (shape identity)

-- ---------------------------------------------------------------------------
-- Shared areas

-- | The height of an identity's solid at the point of a face with parameter @t@
-- along the shared edge, for the four sides.
edgeHeight ∷ Int → FaceKind → Rational → Rational
edgeHeight identity face t = case face of
  WallFace North → topHeight identity t 0
  WallFace South → topHeight identity t 1
  WallFace West → topHeight identity 0 t
  WallFace East → topHeight identity 1 t
  _ → error "not a side"

-- | The exact area two neighbors' openings share across a side: the integral of
-- one less the higher of the two heights along the edge. Both heights are linear
-- on each half of the edge, as is their maximum, so the trapezoid rule on each
-- half is exact.
sharedArea ∷ Int → FaceKind → Int → Rational
sharedArea identity face other =
  sum [(g a + g b) / 2 * (b - a) | (a, b) ← [(0, 1 / 2), (1 / 2, 1)]]
  where
    g t = 1 - max (edgeHeight identity face t) (edgeHeight other (oppositeSide face) t)
    oppositeSide f = case f of
      WallFace North → WallFace South
      WallFace South → WallFace North
      WallFace East → WallFace West
      _ → WallFace East

stepOf ∷ FaceKind → (Integer, Integer, Integer)
stepOf (WallFace North) = (0, -1, 0)
stepOf (WallFace East) = (1, 0, 0)
stepOf (WallFace South) = (0, 1, 0)
stepOf (WallFace West) = (-1, 0, 0)
stepOf TopFace = (0, 0, 1)
stepOf BottomFace = (0, 0, -1)

at ∷ (Integer, Integer, Integer) → (Integer, Integer, Integer) → TileCoord
at (x, y, z) (dx, dy, dz) = tile (x + dx) (y + dy) (z + dz)

sharedAreaSpec ∷ Spec
sharedAreaSpec = describe "connections between neighbors of every pair of identities" $ do
  forM_ [WallFace North, WallFace East, WallFace South, WallFace West] $ \face →
    it ("across the " <> show face <> " side the library finds exactly the area integrated independently, for all 256 pairs") $ do
      let origin = tile 0 0 0
          neighbour = at (0, 0, 0) (stepOf face)
          found a b = connectCells origin (openings a) neighbour (openings b)
      forM_ [0 .. 15] $ \a →
        forM_ [0 .. 15] $ \b → do
          let expected = sharedArea a face b
              connections = found a b
          (a, b, map connectionArea connections) `shouldBe` (a, b, [expected | expected > 0])
          forM_ connections $ \c → do
            connectionFace c `shouldBe` face
            componentRefTile (connectionFrom c) `shouldBe` origin
            componentRefTile (connectionTo c) `shouldBe` neighbour
            connectionRegion c `shouldSatisfy` (not . null)
  it "connects across the top and the bottom only through the top opening of the lower cell and the bottom opening of the upper one" $
    forM_ [0 .. 15] $ \lower →
      forM_ [0 .. 15] $ \upper → do
        let below = tile 0 0 0
            above = tile 0 0 1
        -- An occupied cell has no bottom opening, so two occupied cells never connect.
        map connectionArea (connectCells below (openings lower) above (openings upper)) `shouldBe` []
        map connectionArea (connectCells above (openings upper) below (openings lower)) `shouldBe` []
        -- Air above an occupied cell meets its whole top opening; air below one never does.
        map connectionArea (connectCells below (openings lower) above airOpenings) `shouldBe` [1 | lower /= 0]
        map connectionArea (connectCells above airOpenings below (openings lower)) `shouldBe` [1 | lower /= 0]
        map connectionArea (connectCells below airOpenings above (openings upper)) `shouldBe` []
  it "joins air to air across all six directions with the whole shared face, naming the direction" $
    forM_ faceOrder $ \face → do
      let origin = tile 3 (-4) 5
          neighbour = at (3, -4, 5) (stepOf face)
          forward = connectCells origin airOpenings neighbour airOpenings
          backward = connectCells neighbour airOpenings origin airOpenings
      map connectionArea forward `shouldBe` [1]
      map connectionFace forward `shouldBe` [face]
      map connectionFace backward `shouldBe` [oppositeFace face]
      map connectionArea backward `shouldBe` [1]
  it "finds no connection between the same tile, diagonal tiles or tiles farther apart" $
    forM_ [(0, 0, 0), (1, 1, 0), (1, 0, 1), (0, 1, 1), (1, 1, 1), (-1, 1, 0), (2, 0, 0), (0, 0, -2), (1, -1, -1)] $ \offset →
      connectCells (tile 0 0 0) airOpenings (at (0, 0, 0) offset) airOpenings `shouldBe` []
  it "steps to the tile across a face, refusing a step off the supported range" $ do
    forM_ faceOrder $ \face →
      neighbourTile face (tile 0 0 0) `shouldBe` Right (at (0, 0, 0) (stepOf face))
    neighbourTile TopFace (tile 0 0 axisMaxValue) `shouldSatisfy` either (const True) (const False)
    neighbourTile (WallFace West) (tile axisMinValue 0 0) `shouldSatisfy` either (const True) (const False)

-- ---------------------------------------------------------------------------
-- Rational examples

exampleSpec ∷ Spec
exampleSpec = describe "worked examples with exact rational areas and regions" $ do
  let ramp = 1
      southRamp = 4
      block = 0
      across a b = connectCells (tile 0 0 0) (openings a) (tile 1 0 0) (openings b)
  it "gives adjacent N and N cells across X a shared opening of area 1/2, the triangle above z = y" $ do
    let c = only (across ramp ramp)
    connectionArea c `shouldBe` 1 / 2
    map sort (connectionRegion c) `shouldBe` [sort [point 1 0 0, point 1 1 1, point 1 0 1]]
  it "gives adjacent N and S cells across X an overlap of 1/4 although each opening has area 1/2" $ do
    faceArea (openings ramp) (WallFace East) `shouldBe` 1 / 2
    faceArea (openings southRamp) (WallFace West) `shouldBe` 1 / 2
    let c = only (across ramp southRamp)
    connectionArea c `shouldBe` 1 / 4
    -- Above z = max(y, 1 - y): the triangle with its low corner at (y, z) = (1/2, 1/2).
    map sort (connectionRegion c) `shouldBe` [sort [point 1 0 1, point 1 (1 / 2) (1 / 2), point 1 1 1]]
  it "tells overlap from equal area: the same two areas can overlap in 1/4 or in all of 1/2" $ do
    map connectionArea (across ramp southRamp) `shouldBe` [1 / 4]
    map connectionArea (across ramp ramp) `shouldBe` [1 / 2]
  it "is sealed by an adjoining full block, whichever side it is on" $ do
    across ramp block `shouldBe` []
    across block ramp `shouldBe` []
    across block block `shouldBe` []
  it "meets air over the whole of a ramp's east opening" $
    map connectionArea (connectCells (tile 0 0 0) (openings ramp) (tile 1 0 0) airOpenings) `shouldBe` [1 / 2]
  it "meets air over the whole of the west opening of a ramp that is open there" $
    map connectionArea (connectCells (tile 0 0 0) airOpenings (tile 1 0 0) (openings 8)) `shouldBe` [1]
  it "does not connect a face the ramp has sealed" $ do
    -- E (identity 2) is as high as the cell on its west side: sealed to its west neighbor.
    faceArea (openings 2) (WallFace West) `shouldBe` 0
    connectCells (tile 0 0 0) airOpenings (tile 1 0 0) (openings 2) `shouldBe` []
  it "keeps the connections of an ID 15 peak through all four sides and the top" $
    forM_ faceOrder $ \face →
      map connectionArea (connectCells (tile 0 0 0) (openings 15) (at (0, 0, 0) (stepOf face)) airOpenings)
        `shouldBe` [1 | face /= BottomFace]
  it "reports the connection with exact world coordinates at the supported extremes" $ do
    let top = axisMaxValue
        a = tile (top - 1) (-5) 7
        b = tile top (-5) 7
        c = only (connectCells a (openings ramp) b (openings ramp))
    connectionArea c `shouldBe` 1 / 2
    componentRefTile (connectionFrom c) `shouldBe` a
    componentRefTile (connectionTo c) `shouldBe` b
    -- The shared plane is x = 2^62 - 1 + 1 = 2^62, exactly, one past the last tile.
    map sort (connectionRegion c)
      `shouldBe` [sort [point (fromInteger top) (-5) 7, point (fromInteger top) (-4) 8, point (fromInteger top) (-5) 8]]
    let low = axisMinValue
        d = only (connectCells (tile low 0 0) (openings ramp) (tile (low + 1) 0 0) (openings ramp))
    map sort (connectionRegion d)
      `shouldBe` [sort [point (fromInteger low + 1) 0 0, point (fromInteger low + 1) 1 1, point (fromInteger low + 1) 0 1]]
  it "places an opening in the world as the tile plus the local point" $ do
    let p = only [p' | p' ← placePortals (tile (-1) 15 31) airOpenings, portalFace (placedPortal p') == WallFace East]
    placedTile p `shouldBe` tile (-1) 15 31
    placedWorldPieces p `shouldBe` [[point 0 15 31, point 0 16 31, point 0 16 32, point 0 15 32]]

-- ---------------------------------------------------------------------------
-- Edge and point contact

airPortal ∷ TileCoord → FaceKind → PlacedPortal
airPortal t face = case [p | p ← placePortals t airOpenings, portalFace (placedPortal p) == face] of
  p : _ → p
  [] → error "no portal"

contactSpec ∷ Spec
contactSpec = describe "zero-width contact" $ do
  let east t = airPortal t (WallFace East)
      west t = airPortal t (WallFace West)
  it "connects portals that share a face with positive overlap" $ do
    fmap connectionArea (connectPortals (east (tile 0 0 0)) (west (tile 1 0 0))) `shouldBe` Just 1
    fmap connectionArea (connectPortals (west (tile 1 0 0)) (east (tile 0 0 0))) `shouldBe` Just 1
  it "does not connect portals of the same plane that touch only along an edge" $ do
    -- The East face of (0,0,0) spans y in [0,1]; the West face of (1,1,0) spans y in [1,2].
    connectPortals (east (tile 0 0 0)) (west (tile 1 1 0)) `shouldBe` Nothing
    connectPortals (west (tile 1 1 0)) (east (tile 0 0 0)) `shouldBe` Nothing
    -- Likewise along the other axis: z in [0,1] against [1,2].
    connectPortals (east (tile 0 0 0)) (west (tile 1 0 1)) `shouldBe` Nothing
  it "does not connect portals that touch only at a point" $ do
    connectPortals (east (tile 0 0 0)) (west (tile 1 1 1)) `shouldBe` Nothing
    connectPortals (east (tile 0 0 0)) (west (tile 1 (-1) (-1))) `shouldBe` Nothing
  it "does not connect disjoint portals, a different plane, the same direction or the same cell" $ do
    connectPortals (east (tile 0 0 0)) (west (tile 1 5 0)) `shouldBe` Nothing
    connectPortals (east (tile 0 0 0)) (west (tile 2 0 0)) `shouldBe` Nothing
    connectPortals (east (tile 0 0 0)) (east (tile 0 5 0)) `shouldBe` Nothing
    connectPortals (east (tile 0 0 0)) (west (tile 0 0 0)) `shouldBe` Nothing
    connectPortals (east (tile 0 0 0)) (east (tile 0 0 0)) `shouldBe` Nothing
  it "does not connect a face of one axis with a face of another" $
    connectPortals (east (tile 0 0 0)) (airPortal (tile 1 0 0) (WallFace North)) `shouldBe` Nothing
  it "connects a partly open portal over exactly the overlap, and not when only its top edge touches the next level" $ do
    -- The South portal of a W ramp is the triangle above z = x, of area 1/2.
    let ramp t = only [p | p ← placePortals t (openings 8), portalFace (placedPortal p) == WallFace South]
        flat t = airPortal t (WallFace North)
    fmap connectionArea (connectPortals (ramp (tile 0 0 0)) (flat (tile 0 1 0))) `shouldBe` Just (1 / 2)
    -- One level up the whole North face of the air cell starts at z = 1, where the triangle's top edge ends.
    connectPortals (ramp (tile 0 0 0)) (flat (tile 0 1 1)) `shouldBe` Nothing

-- ---------------------------------------------------------------------------
-- Paths through a world

data Content = Air | Shape Int
  deriving stock (Eq, Show)

contentOpenings ∷ Content → CellOpenings
contentOpenings Air = airOpenings
contentOpenings (Shape identity) = openings identity

turnContent ∷ Int → Content → Content
turnContent _ Air = Air
turnContent count (Shape identity) = Shape (shapeIdValue (rotateShape (turns count) (shape identity)))

type Layout = [((Integer, Integer, Integer), Content)]

-- | The layout turned about its origin cell by whole quarter turns.
turnLayout ∷ Int → Layout → Layout
turnLayout count layout = [(turnOffset count offset, turnContent count content) | (offset, content) ← layout]

-- | Whether the component of the cell at one offset can be reached from the
-- component of the cell at another, searching only the connections the library
-- reports between tiles present in the layout. A tile absent from the layout is
-- unavailable: it has no openings and joins nothing.
reaches ∷ (Integer, Integer, Integer) → Layout → (Integer, Integer, Integer) → (Integer, Integer, Integer) → Bool
reaches base layout from to = to' `Set.member` flood (Set.singleton start) [start]
  where
    placed = Map.fromList [(at base offset, contentOpenings content) | (offset, content) ← layout]
    start = (at base from, 0)
    to' = (at base to, 0)
    flood seen [] = seen
    flood seen ((cell, _) : stack) =
      let next =
            [ (componentRefTile (connectionTo c), componentRefIndex (connectionTo c))
            | face ← faceOrder
            , Right other ← [neighbourTile face cell]
            , Just there ← [Map.lookup other placed]
            , Just here ← [Map.lookup cell placed]
            , c ← connectCells cell here other there
            ]
          fresh = [n | n ← next, n `Set.notMember` seen]
       in flood (foldr Set.insert seen fresh) (fresh <> stack)

-- | 'reaches' for a layout and its two endpoints all turned together by whole
-- quarter turns about the origin cell.
reachesTurned ∷ (Integer, Integer, Integer) → Int → Layout → (Integer, Integer, Integer) → (Integer, Integer, Integer) → Bool
reachesTurned base count layout from to = reaches base (turnLayout count layout) (turnOffset count from) (turnOffset count to)

-- | Placements that put the layout across the chunk seam, the vertical-region seam,
-- the negative seams and both ends of the supported range.
bases ∷ [(Integer, Integer, Integer)]
bases =
  [ (0, 0, 0)
  , (15, 15, 31)
  , (-1, -1, -1)
  , (15, -1, 31)
  , (-17, 31, -33)
  , (top - 1, top - 1, top - 1)
  , (low + 1, low + 1, low + 1)
  ]
  where
    top = toInteger axisMaxValue
    low = toInteger axisMinValue

pathSpec ∷ Spec
pathSpec = describe "paths through the empty space of neighboring cells" $ do
  -- A is open air at the origin, B a ramp east of it, C open air south of B. A and C
  -- are diagonal neighbors; the path is through the empty region above the ramp.
  let aOffset = (0, 0, 0)
      cOffset = (1, 1, 0)
      layoutWith b = [((0, 0, 0), Air), ((1, 0, 0), b), ((1, 1, 0), Air)]
      -- W (identity 8): open to the west above the base, partly open to the south.
      through = layoutWith (Shape 8)
      everywhere check = forM_ bases $ \base → forM_ [0 .. 3] $ \count → check base count
  it "turns through the empty region above a ramp into the diagonal cavity, in every orientation and placement" $
    everywhere $ \base count →
      reachesTurned base count through aOffset cOffset `shouldBe` True
  it "has the diagonal neighbors A and C not linked directly" $
    connectCells (tile 0 0 0) airOpenings (tile 1 1 0) airOpenings `shouldBe` []
  it "is sealed by a full block in place of the ramp" $
    everywhere $ \base count →
      reachesTurned base count (layoutWith (Shape 0)) aOffset cOffset `shouldBe` False
  it "is blocked by a ramp whose open side faces away from A" $
    everywhere $ \base count →
      -- E (identity 2) is as high as the cell on its west side.
      reachesTurned base count (layoutWith (Shape 2)) aOffset cOffset `shouldBe` False
  it "is blocked by the ramp turned so that its lowered side does not face A, whatever the facing" $
    everywhere $ \base count →
      forM_ [0 .. 15] $ \identity → do
        let openToA = faceArea (openings identity) (WallFace West) > 0
            openToC = faceArea (openings identity) (WallFace South) > 0
        reachesTurned base count (layoutWith (Shape identity)) aOffset cOffset `shouldBe` (openToA && openToC)
  it "does not take a missing tile for air: an unavailable ramp tile joins nothing, a known empty one does" $
    everywhere $ \base count → do
      reachesTurned base count [((0, 0, 0), Air), ((1, 1, 0), Air)] aOffset cOffset `shouldBe` False
      reachesTurned base count (layoutWith Air) aOffset cOffset `shouldBe` True
  it "does not pass between cavities that touch only along an edge, with the face neighbors sealed" $
    everywhere $ \base count →
      reachesTurned base count [((0, 0, 0), Air), ((1, 0, 0), Shape 0), ((0, 1, 0), Shape 0), ((1, 1, 0), Air)] aOffset cOffset
        `shouldBe` False
  it "does not pass between cavities that touch only at a corner, with the face neighbors sealed" $
    everywhere $ \base count →
      reachesTurned
        base
        count
        [((0, 0, 0), Air), ((1, 0, 0), Shape 0), ((0, 1, 0), Shape 0), ((0, 0, 1), Shape 0), ((1, 1, 0), Shape 0), ((0, 1, 1), Shape 0), ((1, 0, 1), Shape 0), ((1, 1, 1), Air)]
        aOffset
        (1, 1, 1)
        `shouldBe` False
  -- Down through the open top of an ID 15 peak and out through its east side.
  let down b = [((0, 0, 1), Air), ((0, 0, 0), b), ((1, 0, 0), Air)]
  it "enters the empty space above a peak from above and leaves it through a side, across a vertical-region seam" $ do
    forM_ bases $ \base → forM_ [0 .. 3] $ \count →
      reachesTurned base count (down (Shape 15)) (0, 0, 1) (1, 0, 0) `shouldBe` True
    -- The placement used really does cross a vertical region boundary and a chunk boundary.
    let (_, local0) = decomposeTile (tile 15 15 31)
        (_, local1) = decomposeTile (tile 16 15 32)
    (localZ local0, localZ local1) `shouldBe` (31, 0)
    (localX local0, localX local1) `shouldBe` (15, 0)
    regionOf (tile 15 15 31) `shouldNotBe` regionOf (tile 16 15 32)
  it "is sealed from below: a peak has no bottom opening" $
    forM_ bases $ \base → forM_ [0 .. 3] $ \count →
      reachesTurned base count [((0, 0, -1), Air), ((0, 0, 0), Shape 15), ((1, 0, 0), Air)] (0, 0, -1) (1, 0, 0) `shouldBe` False
  it "is sealed by a full block in place of the peak" $
    forM_ bases $ \base → forM_ [0 .. 3] $ \count →
      reachesTurned base count (down (Shape 0)) (0, 0, 1) (1, 0, 0) `shouldBe` False
  where
    regionOf = fst . decomposeTile

-- ---------------------------------------------------------------------------
-- Agreement with the logical queries

agreementSpec ∷ Spec
agreementSpec = describe "agreement with point and ray queries" $ do
  it "classifies a face point strictly inside a portal as exterior and a sealed one as boundary, for every identity" $
    forM_ [0 .. 15] $ \identity →
      forM_ faceOrder $ \face →
        [ (face, p, held)
          | p ← lattice
          , let held = faceHolds (openings identity) face p
          , classifyPoint (shapeSolid (shape identity)) (liftTo face p) /= (if held then Exterior else Boundary)
          ]
          `shouldBe` []
  it "agrees with the closed-solid classification on every point of every face, boundaries and seams included" $
    -- A face point is open air exactly when the solid calls the cell point exterior. The grid has step 1/8, so it
    -- holds the face's edges and corners, the ramp and ridge lines, the base edge, the top edge, the diagonals and the
    -- seams between the opening's convex pieces.
    forM_ [0 .. 15] $ \identity →
      forM_ faceOrder $ \face →
        [ (identity, face, p, held)
          | i ← [0 .. 8 ∷ Integer]
          , j ← [0 .. 8 ∷ Integer]
          , let p = (fromInteger i / 8, fromInteger j / 8)
          , let held = faceHolds (openings identity) face p
          , held /= (classifyPoint (shapeSolid (shape identity)) (liftTo face p) == Exterior)
          ]
          `shouldBe` []
  it "keeps the solid's boundary out of the opening: ramp, ridge, top edge and base edge" $ do
    let holds identity face p = faceHolds (openings identity) face p
    -- N, east face: the ramp line z = y is solid boundary, above it is air, below it is sealed.
    holds 1 (WallFace East) (1 / 2, 1 / 2) `shouldBe` False
    holds 1 (WallFace East) (1 / 2, 51 / 100) `shouldBe` True
    holds 1 (WallFace East) (1 / 2, 49 / 100) `shouldBe` False
    -- NS, east face: the ridge point (1/2, 1/2) is boundary; the seam between the pieces is air.
    holds 5 (WallFace East) (1 / 2, 1 / 2) `shouldBe` False
    holds 5 (WallFace East) (1 / 4, 3 / 4) `shouldBe` True
    holds 5 (WallFace East) (3 / 4, 3 / 4) `shouldBe` True
    -- N, top face: the line y = 1 reaches the cell's top, so it is solid; the rest of the top is air.
    holds 1 TopFace (1 / 2, 1) `shouldBe` False
    holds 1 TopFace (1 / 2, 99 / 100) `shouldBe` True
    -- ID 15, east face: the base edge z = 0 is solid; the apex's facets leave everything above it air.
    holds 15 (WallFace East) (1 / 2, 0) `shouldBe` False
    holds 15 (WallFace East) (1 / 2, 1 / 100) `shouldBe` True
    -- A sealed block is never air, and air always is, edges included.
    holds 0 (WallFace East) (1 / 2, 1 / 2) `shouldBe` False
    or [holds 0 face (0, 0) | face ← faceOrder] `shouldBe` False
    and [faceHolds airOpenings face p | face ← faceOrder, p ← [(0, 0), (1, 1), (1 / 2, 1 / 2), (0, 1)]] `shouldBe` True
  it "lets a ray through an opening point miss a ramp that is lower there, and stops one at a sealed point" $ do
    -- N, east face: open where z > y. At y = 3/4: z = 7/8 is open, z = 1/4 is sealed.
    let solid = shapeSolid (shape 1)
        ray o d = either (error . show) id (mkRay o d)
    classifyPoint solid (point 1 (3 / 4) (7 / 8)) `shouldBe` Exterior
    castRay solid (ray (point 2 (3 / 4) (7 / 8)) (point (-1) 0 0)) `shouldBe` Nothing
    classifyPoint solid (point 1 (3 / 4) (1 / 4)) `shouldBe` Boundary
    fmap (\h → (hitParameter h, hitPoint h, hitContact h)) (castRay solid (ray (point 2 (3 / 4) (1 / 4)) (point (-1) 0 0)))
      `shouldBe` Just (1, point 1 (3 / 4) (1 / 4), Enters)
  it "lets a ray through the peak's open side and meets a facet inside the cell" $ do
    -- ID 15: the east face is open for z > 0, so (y, z) = (1/2, 1/4) is air; the ray meets the west-sloping facet at x = 3/4.
    let solid = shapeSolid (shape 15)
        ray o d = either (error . show) id (mkRay o d)
    classifyPoint solid (point 1 (1 / 2) (1 / 4)) `shouldBe` Exterior
    openingContains (portalOpening (only (portalsOn (WallFace East) (openings 15)))) (1 / 2, 1 / 4) `shouldBe` True
    fmap (\h → (hitParameter h, hitPoint h)) (castRay solid (ray (point 2 (1 / 2) (1 / 4)) (point (-1) 0 0)))
      `shouldBe` Just (5 / 4, point (3 / 4) (1 / 2) (1 / 4))
    -- Above the apex the ray passes the whole cell.
    castRay solid (ray (point 2 (1 / 2) (3 / 4)) (point (-1) 0 0)) `shouldBe` Nothing
