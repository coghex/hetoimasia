-- | An independent small-space portal and flood model for the connectivity
-- compiler.
--
-- The oracle shares no code with the library. It reads a 'SourceSpec' as plain
-- data through the naive scan of "Test.Terrain.Model", derives each shape's top
-- height from the issue's stated rule (shape 0 the full block; any other
-- identity the minimum of its selected expressions @N = y@, @E = 1 - x@,
-- @S = 1 - y@, @W = x@; bits North 1, East 2, South 4, West 8), decides whether
-- two face-adjacent cells connect by testing exact rational sample points of
-- the shared face for membership in both open regions, and floods an explicit
-- finite window cell by cell. Its expected topology therefore comes from
-- authored geometry and the source expectations, never from the compiled result
-- or from the production portal routine.
--
-- The sampling is a deliberate approximation of the exact overlap area: every
-- open region here is a union of polygons whose corners lie on multiples of
-- @1/4@, so any overlap of positive area is at least @1/32@ of the face and
-- contains a sample centre of a 32 × 32 grid. Edge and point contacts contain no
-- sample centre, because centres are strictly interior to their grid cells and
-- open regions are strict inequalities.
module Test.Terrain.ConnectivityOracle
  ( -- * Content
    Content (..)
  , contentOf
  , worldContent

    -- * Geometry
  , connectsAlong
  , topOpens
  , hasVoid

    -- * Flood
  , Cell3
  , Window (..)
  , inWindow
  , windowCells
  , flood
  , neighbour

    -- * Checking a compiled result
  , View (..)
  , compiledView
  , Verdict
  , verify
  ) where

import qualified Data.Map.Lazy as Lazy
import Data.Bits (testBit)
import Control.Monad (join)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Set as Set
import Hetoimasia.Terrain.Connectivity
import Hetoimasia.Terrain.Coordinate (TileCoord, tileCoord)
import Hetoimasia.Terrain.Geometry (FaceKind (..))
import Hetoimasia.Terrain.Shape (Side (..))
import Hetoimasia.Terrain.Source (SourceSpec)
import Test.Terrain.Model (highest, lowest, modelCell, topEnd)

-- | What a cell holds, as far as connectivity cares.
data Content = CAir | CBlock | CShape Int
  deriving stock (Eq, Ord, Show)

-- | The model's reading of a cell value.
contentOf ∷ Maybe (String, Int) → Content
contentOf Nothing = CAir
contentOf (Just (_, 0)) = CBlock
contentOf (Just (_, shape)) = CShape shape

-- | A cell by coordinates.
type Cell3 = (Integer, Integer, Integer)

-- | The content of a cell of a source, or 'Nothing' for a coordinate outside
-- the supported world (which holds no cell and connects to nothing).
worldContent ∷ SourceSpec → Cell3 → Maybe Content
worldContent spec cell@(x, y, z)
  | any outside [x, y, z] = Nothing
  | otherwise = Just (contentOf (modelCell spec [] cell))
  where
    outside v = v < lowest || v > highest

-- | Whether the cell holds any empty space.
hasVoid ∷ Content → Bool
hasVoid CBlock = False
hasVoid _ = True

-- | The height of the solid's top above the cell-local point @(x, y)@, or
-- 'Nothing' where there is no solid (air).
topHeight ∷ Content → Rational → Rational → Maybe Rational
topHeight CAir _ _ = Nothing
topHeight CBlock _ _ = Just 1
topHeight (CShape 0) _ _ = Just 1
topHeight (CShape mask) x y =
  Just (minimum [expr | (bit, expr) ← [(0, y), (1, 1 - x), (2, 1 - y), (3, x)], testBit mask bit])

-- | Whether a point of a cell face is open air. A face is named by its plane;
-- coordinates are @(u, v)@ as in the issue: @(y, z)@ on East and West, @(x, z)@
-- on North and South and @(x, y)@ on Top and Bottom.
openOn ∷ Content → FaceKind → (Rational, Rational) → Bool
openOn content face (u, v) = case face of
  WallFace East → above (topHeight content 1 u) v
  WallFace West → above (topHeight content 0 u) v
  WallFace North → above (topHeight content u 0) v
  WallFace South → above (topHeight content u 1) v
  TopFace → maybe True (< 1) (topHeight content u v)
  BottomFace → content == CAir
  where
    above Nothing _ = True
    above (Just h) z = z > h

-- | The sample centres of a 32 × 32 grid over the unit square.
samples ∷ [(Rational, Rational)]
samples = [((fromIntegral a + 0.5) / 32, (fromIntegral b + 0.5) / 32) | a ← [0 .. 31 ∷ Int], b ← [0 .. 31 ∷ Int]]

-- | Whether a lower cell connects to the cell one step up an axis (0 east, 1
-- south, 2 up): some sample of the shared face is open air on both sides.
connectsAlong ∷ Int → Content → Content → Bool
connectsAlong axis lower upper = connectTable Lazy.! (axis, index lower, index upper)

index ∷ Content → Int
index CAir = 0
index CBlock = 1
index (CShape s) = 1 + s

fromIndex ∷ Int → Content
fromIndex 0 = CAir
fromIndex 1 = CBlock
fromIndex n = CShape (n - 1)

connectTable ∷ Lazy.Map (Int, Int, Int) Bool
connectTable = Lazy.fromList [((axis, a, b), compute axis (fromIndex a) (fromIndex b)) | axis ← [0, 1, 2], a ← [0 .. 16], b ← [0 .. 16]]

compute ∷ Int → Content → Content → Bool
compute axis lower upper
  | not (hasVoid lower && hasVoid upper) = False
  | otherwise = any (\p → openOn lower lowerFace p && openOn upper upperFace p) samples
  where
    (lowerFace, upperFace) = case axis of
      0 → (WallFace East, WallFace West)
      1 → (WallFace South, WallFace North)
      _ → (TopFace, BottomFace)

-- | Whether the cell's top face has positive open area.
topOpens ∷ Content → Bool
topOpens content = topTable Lazy.! index content

topTable ∷ Lazy.Map Int Bool
topTable = Lazy.fromList [(n, let c = fromIndex n in hasVoid c && any (openOn c TopFace) samples) | n ← [0 .. 16]]

-- ---------------------------------------------------------------------------
-- Flood

-- | A finite window of cells, each axis half-open.
data Window = Window
  { windowX ∷ !(Integer, Integer)
  , windowY ∷ !(Integer, Integer)
  , windowZ ∷ !(Integer, Integer)
  }
  deriving stock (Eq, Show)

inWindow ∷ Window → Cell3 → Bool
inWindow (Window (x0, x1) (y0, y1) (z0, z1)) (x, y, z) = x0 <= x && x < x1 && y0 <= y && y < y1 && z0 <= z && z < z1

-- | Every cell of a window.
windowCells ∷ Window → [Cell3]
windowCells (Window (x0, x1) (y0, y1) (z0, z1)) = [(x, y, z) | z ← [z0 .. z1 - 1], y ← [y0 .. y1 - 1], x ← [x0 .. x1 - 1]]

-- | The cell one step along an axis, in either direction.
neighbour ∷ Int → Integer → Cell3 → Cell3
neighbour 0 d (x, y, z) = (x + d, y, z)
neighbour 1 d (x, y, z) = (x, y + d, z)
neighbour _ d (x, y, z) = (x, y, z + d)

-- | The connected components of the void cells of a window, by flooding face by
-- face. Cells outside the window or the supported world are walls. The
-- component numbers are arbitrary.
flood ∷ (Cell3 → Maybe Content) → Window → Map.Map Cell3 Int
flood content window = snd (foldl' visit (0, Map.empty) cells)
  where
    cells = [c | c ← windowCells window, maybe False hasVoid (content c)]
    visit (next, assigned) start
      | Map.member start assigned = (next, assigned)
      | otherwise = (next + 1, go [start] (Map.insert start next assigned))
      where
        go [] acc = acc
        go (c : rest) acc =
          let new = [n | n ← adjacent c, not (Map.member n acc)]
              acc' = foldl' (\m n → Map.insert n next m) acc new
           in go (new ++ rest) acc'
    adjacent c = mapMaybe (\(axis, d) → step c axis d) [(axis, d) | axis ← [0, 1, 2], d ← [1, -1]]
    step c axis d = do
      let n = neighbour axis d c
          (lower, upper) = if d == 1 then (c, n) else (n, c)
      cl ← content lower
      cu ← content upper
      if inWindow window n && connectsAlong axis cl cu then Just n else Nothing

-- ---------------------------------------------------------------------------
-- Checking

-- | Discrepancies between a compiled result and the oracle; empty when they
-- agree.
type Verdict = [String]

-- | What a verdict needs of a compiled result, over any key type. The real
-- result's view is 'compiledView'; a negative control builds a deliberately
-- wrong one, which the checks must reject.
data View k = View
  { viewLookup ∷ Cell3 → Maybe (Maybe k)
  -- ^ 'Nothing' when the cell has no void, 'Just' its component otherwise.
  , viewExterior ∷ k → Maybe Bool
  , viewRanges ∷ k → Maybe [CellRange]
  , viewRelations ∷ k → Maybe [PortalRelation]
  , viewBoundary ∷ k → Maybe [BoundaryFace]
  , viewBox ∷ Cell3 → Maybe CellRange
  }

tile ∷ Cell3 → Maybe TileCoord
tile (x, y, z) = either (const Nothing) Just (tileCoord x y z)

-- | The view of a real compiled result.
compiledView ∷ Connectivity → View ComponentKey
compiledView compiled =
  View
    { viewLookup = \c → case tile c of
        Nothing → Nothing
        Just t → case lookupVoid compiled t 0 of
          NoVoid → Just Nothing
          InComponent k → Just (Just k)
          NoSuchVoid → Nothing
    , viewExterior = isExterior compiled
    , viewRanges = componentRanges compiled
    , viewRelations = componentRelations compiled
    , viewBoundary = componentBoundary compiled
    , viewBox = \c → tile c >>= cellBox compiled
    }

cellsOf ∷ CellRange → [Cell3]
cellsOf r = [(x, y, z) | z ← [rangeZLo r .. rangeZHi r - 1], y ← [rangeYLo r .. rangeYHi r - 1], x ← [rangeXLo r .. rangeXHi r - 1]]

-- | Compare a compiled result with the oracle over a window. The window must
-- contain every special column of the source with a margin of one cell and hold
-- every cut of the vertical axis, and either enclose the cells compared (a
-- sealed room) or extend one cell past them on every side, so that the flood
-- reproduces the connectivity of the unbounded plane around it. @inner@ selects
-- the cells compared. Checked: void versus no-void, the partition into
-- components (a bijection with the keys), exterior classification, membership of
-- every component range, every portal relation (sound and, together with the
-- interior connections of each box, complete) and every boundary face.
verify ∷ (Ord k, Show k) ⇒ View k → (Cell3 → Maybe Content) → Window → (Cell3 → Bool) → Verdict
verify view content window selected = concat [voidChecks, partitionChecks, exteriorChecks, rangeChecks, relationChecks, boundaryChecks]
  where
    inner c = inWindow window c && selected c
    components = flood content window
    comparedCells = [c | c ← windowCells window, inner c]
    voidCells = [c | c ← comparedCells, Map.member c components]
    keyAt c = join (viewLookup view c)
    voidChecks =
      [ "no-void answer disagrees at " <> show c
      | c ← comparedCells
      , let expected = maybe False hasVoid (content c)
      , let got = case viewLookup view c of
              Just (Just _) → True
              _ → False
      , expected /= got
      ]
    pairs = [(Map.findWithDefault (-1) c components, keyAt c) | c ← voidCells]
    partitionChecks =
      [ "a cell has no component key" | (_, Nothing) ← pairs ]
        <> [ "oracle component " <> show o <> " has several keys"
           | (o, ks) ← Map.toList (Map.fromListWith Set.union [(o, Set.singleton k) | (o, Just k) ← pairs])
           , Set.size ks > 1
           ]
        <> [ "key " <> show k <> " joins several oracle components"
           | (k, os) ← Map.toList (Map.fromListWith Set.union [(k, Set.singleton o) | (o, Just k) ← pairs])
           , Set.size os > 1
           ]
    keys = Set.toList (Set.fromList [k | (_, Just k) ← pairs])
    oracleExterior o = or [isTop c && maybe False topOpens (content c) | (c, o') ← Map.toList components, o' == o]
    isTop (_, _, z) = z == topEnd - 1
    exteriorChecks =
      [ "exterior flag disagrees for " <> show k
      | (o, Just k) ← Set.toList (Set.fromList pairs)
      , viewExterior view k /= Just (oracleExterior o)
      ]
    Window (wx0, wx1) (wy0, wy1) (wz0, wz1) = window
    clip r = r {rangeXLo = max (rangeXLo r) wx0, rangeXHi = min (rangeXHi r) wx1, rangeYLo = max (rangeYLo r) wy0, rangeYHi = min (rangeYHi r) wy1, rangeZLo = max (rangeZLo r) wz0, rangeZHi = min (rangeZHi r) wz1}
    expandedRanges k = Set.fromList [c | r ← fromMaybe [] (viewRanges view k), c ← cellsOf (clip r), inner c]
    rangeChecks =
      [ "range membership disagrees for " <> show k
      | k ← keys
      , let expected = Set.fromList [c | c ← voidCells, keyAt c == Just k]
      , expandedRanges k /= expected
      ]
    -- The relation expansion: the pairs (lower, upper) of cells across each
    -- relation's shared face.
    inBox r (x, y, z) = rangeXLo r <= x && x < rangeXHi r && rangeYLo r <= y && y < rangeYHi r && rangeZLo r <= z && z < rangeZHi r
    expandRelation (PortalRelation lower upper axis) =
      [ (c, n)
      | c ← cellsOf (clip lower)
      , inner c
      , let n = neighbour (fromEnum axis) 1 c
      , inner n
      , inBox upper n
      ]
    expandedRelations = Set.fromList (concat [concatMap expandRelation (fromMaybe [] (viewRelations view k)) | k ← keys])
    oracleEdges =
      Set.fromList
        [ (c, n)
        | c ← voidCells
        , axis ← [0, 1, 2]
        , let n = neighbour axis 1 c
        , inner n
        , Just cl ← [content c]
        , Just cu ← [content n]
        , connectsAlong axis cl cu
        ]
    sameBox a b = case (viewBox view a, viewBox view b) of
      (Just ra, Just rb) → ra == rb
      _ → False
    relationChecks =
      [ "a relation joins cells the oracle does not connect: " <> show e
      | e ← Set.toList expandedRelations
      , not (Set.member e oracleEdges)
      ]
        <> [ "an oracle connection is neither inside a box nor a relation: " <> show e
           | e@(a, b) ← Set.toList oracleEdges
           , not (sameBox a b)
           , not (Set.member e expandedRelations)
           ]
    faceFor ∷ Int → Integer → FaceKind
    faceFor 0 1 = WallFace East
    faceFor 0 _ = WallFace West
    faceFor 1 1 = WallFace South
    faceFor 1 _ = WallFace North
    faceFor _ 1 = TopFace
    faceFor _ _ = BottomFace
    faceDirection ∷ FaceKind → (Int, Integer)
    faceDirection f = case f of
      WallFace East → (0, 1)
      WallFace West → (0, -1)
      WallFace South → (1, 1)
      WallFace North → (1, -1)
      TopFace → (2, 1)
      BottomFace → (2, -1)
    -- The boundary: pairs of a member cell and a face whose across cell is a
    -- supported cell outside the component, or no cell at all (a limit).
    oracleBoundary k =
      Set.fromList
        [ (c, faceFor axis d)
        | c ← voidCells
        , keyAt c == Just k
        , axis ← [0, 1, 2]
        , d ← [1, -1]
        , let n = neighbour axis d c
        , case content n of
            Nothing → True
            Just _ → inner n && Map.lookup n components /= Map.lookup c components
        ]
    expandedBoundary k =
      Set.fromList
        [ (c, boundaryFace face)
        | face ← fromMaybe [] (viewBoundary view k)
        , c ← cellsOf (clip (boundaryCells face))
        , inner c
        , acrossCounts face c
        ]
    acrossCounts face c = case boundaryAcross face of
      AcrossLimit → True
      AcrossTiles _ _ →
        let (axis, dir) = faceDirection (boundaryFace face)
         in inner (neighbour axis dir c)
    boundaryChecks =
      [ "boundary disagrees for " <> show k
      | k ← keys
      , expandedBoundary k /= oracleBoundary k
      ]
        <> [ "a boundary face lies across a limit but the world has a cell there: " <> show f
           | k ← keys
           , f ← fromMaybe [] (viewBoundary view k)
           , AcrossLimit ← [boundaryAcross f]
           , c ← cellsOf (clip (boundaryCells f))
           , inner c
           , let (axis, dir) = faceDirection (boundaryFace f)
           , Just _ ← [content (neighbour axis dir c)]
           ]
        <> [ "a boundary face's across kind is wrong: " <> show f
           | k ← keys
           , f ← fromMaybe [] (viewBoundary view k)
           , AcrossTiles range kind ← [boundaryAcross f]
           , n ← cellsOf (clip range)
           , inner n
           , let isVoid = maybe False hasVoid (content n)
           , (kind == AcrossOtherVoid) /= isVoid
           ]
