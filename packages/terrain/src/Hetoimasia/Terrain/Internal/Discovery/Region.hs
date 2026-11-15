-- | What #661's discovery model knows of every cell of one region, compressed (#690): the answers
-- 'Hetoimasia.Terrain.Internal.Discovery.Core.queryCell' gives over a 16 x 16 x 32 region, found
-- without evaluating cells one at a time where the answer cannot vary.
--
-- = Why the answer is uniform where it is
--
-- A cell's knowledge is a function of what it and its six face neighbours hold now (a removed run
-- or the source cell), the nodes of their voids (a removed run's node, or the source component's
-- key) and whether each node's class is known. The compiled connectivity describes the source by a
-- lattice of boxes: inside a box every cell has the same kind of content and its void belongs to
-- the same class, with the same key unless the box keeps a coordinate as a component parameter. So
-- two cells whose own box and neighbours' boxes agree, with no removal at or beside them and no
-- parameter telling their keys apart, have the same answer.
--
-- 'planRegionKnowledge' partitions the region by that rule, from the compiled connectivity and the
-- removed runs of the region's columns and of the 64 columns beside it ('regionColumns',
-- 'regionHaloColumns'), read by the caller from one committed version over 'regionReadLevels' (the
-- region's levels and one beyond each end):
--
-- * the columns into /classes/ with identical inputs: the same lattice intervals for the column and
--   its four side neighbours, no removed run in any of the five over the levels read, and the
--   column's own coordinate wherever a box there keeps it as a parameter. A column with a removal in
--   it or beside it is a class of its own;
-- * each class's levels into /pieces/, bounded by the lattice's Z cuts and, for a class of its own,
--   the ends of every removed run of the five columns. In a piece every cell but the first and the
--   last has the same inputs, its up and down neighbours included, so a piece is evaluated at its
--   first cell, one interior cell and its last cell. A piece in a box whose components keep the
--   level as a parameter (stacked non-flat cells, a component per level) is evaluated at every level
--   ('planPerLevelTiles' counts those evaluations apart).
--
-- The caller evaluates 'queryCell' at 'planTiles', in order, against the same committed version, and
-- 'assembleRegionKnowledge' coalesces each class's runs and keeps one copy of each distinct column: a
-- region whose answer is uniform is one class of one run.
--
-- Nothing here reads a record. The plan is arithmetic on the connectivity and the runs it is given;
-- its size grows with the lattice cuts, the removals and the parameterised boxes inside the region,
-- never with its 8,192 cells otherwise. State, ownership and lifetime: none; every value is immutable.
module Hetoimasia.Terrain.Internal.Discovery.Region
  ( -- * What a plan reads
    regionColumns
  , regionHaloColumns
  , regionReadLevels

    -- * The plan
  , KnowledgePlan
  , planRegionKnowledge
  , planRegion
  , planTiles
  , planClasses
  , planPieces
  , planPerLevelTiles

    -- * The compressed answer
  , RegionKnowledge
  , assembleRegionKnowledge
  , mkRegionKnowledge
  , regionKnowledgeRegion
  , regionKnowledgeClasses
  , regionKnowledgeColumns
  , regionKnowledgeAt
  , regionKnowledgeColumn
  , regionKnowledgeUniform
  ) where

import Data.Bits (testBit, (.|.))
import Data.Int (Int64)
import qualified Data.IntMap.Strict as IntMap
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word8)
import Hetoimasia.Terrain.Cell (Column (..))
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), TileCoord (..), axisFromInteger, axisMaxValue, axisMinValue, axisValue, columnSize, regionLevels)
import Hetoimasia.Terrain.Internal.Connectivity.Index (Connectivity (..), Node (..), cutIndex, latticeSize)
import Hetoimasia.Terrain.Internal.Discovery.Core (CellKnowledge (..), Env, SolidKnowledge (..), VoidKnowledge (..), envConnectivity)

-- ---------------------------------------------------------------------------
-- What a plan reads

-- | The region's own 256 columns, row by row (local index @y * 16 + x@). A region whose cells are
-- not all supported tiles yields only the columns that are.
regionColumns ∷ RegionCoord → [Column]
regionColumns region =
  [ column
  | cy ← [0 .. side - 1]
  , cx ← [0 .. side - 1]
  , Just column ← [columnAt (x0 + cx) (y0 + cy)]
  ]
  where
    (x0, y0, _) = regionOrigin region

-- | The columns beside the region that its cells' side faces touch: the column west and east of each
-- row and north and south of each column (at most 64; those past the supported range do not exist).
regionHaloColumns ∷ RegionCoord → [Column]
regionHaloColumns region =
  [ column
  | (x, y) ←
      [(x0 - 1, y0 + i) | i ← [0 .. side - 1]]
        <> [(x0 + side, y0 + i) | i ← [0 .. side - 1]]
        <> [(x0 + i, y0 - 1) | i ← [0 .. side - 1]]
        <> [(x0 + i, y0 + side) | i ← [0 .. side - 1]]
  , Just column ← [columnAt x y]
  ]
  where
    (x0, y0, _) = regionOrigin region

-- | The levels a plan needs the runs of, @[lo, hi)@: the region's 32 and one beyond each end, within
-- the supported range.
regionReadLevels ∷ RegionCoord → (Int64, Int64)
regionReadLevels region =
  let (_, _, z0) = regionOrigin region
   in (fromInteger (max axisMinValue (z0 - 1)), fromInteger (min (axisMaxValue + 1) (z0 + levels + 1)))

-- ---------------------------------------------------------------------------
-- The plan

-- | How a region's knowledge is found: its column classes, each class's pieces, and the tiles to
-- evaluate. The constructor is private.
data KnowledgePlan = KnowledgePlan
  { kpRegion ∷ !RegionCoord
  , kpClassOf ∷ ![Int]
  -- ^ The class of each local column, by local index @y * 16 + x@.
  , kpClasses ∷ ![ClassPlan]
  }
  deriving stock (Eq, Show)

-- | One class: the column evaluated for all of it, and its pieces in ascending order, covering the
-- region's 32 levels exactly.
data ClassPlan = ClassPlan
  { cpColumn ∷ !(Integer, Integer)
  , cpPieces ∷ ![Piece]
  }
  deriving stock (Eq, Show)

-- | A piece of levels @[lo, hi)@.
data Piece
  = -- | Every level has its own components: each is evaluated.
    PerLevel !Int64 !Int64
  | -- | The first, one interior and the last level are evaluated; the interior answer is every
    -- interior level's.
    Span !Int64 !Int64
  deriving stock (Eq, Show)

-- | What a class's evaluation looks like before the answers come back.
data Signature
  = -- | A column with a removal in it or beside it: a class of its own.
    Own !Integer !Integer
  | -- | The lattice intervals of the column and its west, east, north and south neighbours, and
    -- the column's coordinates where a box keeps one as a parameter.
    Shared ![(Maybe Int, Maybe Int)] !(Maybe Integer) !(Maybe Integer)
  deriving stock (Eq, Ord, Show)

-- | Plan a region from its environment and the removed runs, @[lo, hi)@, that its columns and the
-- columns beside it hold over 'regionReadLevels' (a column absent from the map holds none). The runs
-- must be those of the committed version the answers will be evaluated against.
planRegionKnowledge ∷ Env → RegionCoord → Map Column [(Int64, Int64)] → KnowledgePlan
planRegionKnowledge env region runs = KnowledgePlan region classOf (map plan representatives)
  where
    conn = envConnectivity env
    (nx, ny, _) = latticeSize conn
    (x0, y0, z0) = regionOrigin region
    z1 = z0 + levels
    (readLo, readHi) = regionReadLevels region
    -- the lattice interval of a coordinate on an axis, when the coordinate is supported
    indexOn cuts v
      | v < axisMinValue || v > axisMaxValue = Nothing
      | otherwise = cutIndex cuts (fromInteger v)
    xi = indexOn (cXCuts conn)
    yj = indexOn (cYCuts conn)
    zk = indexOn (cZCuts conn)
    axesAt i j k = maybe (0 ∷ Word8) nodeAxes (IntMap.lookup (i + nx * (j + ny * k)) (cNodeAt conn) >>= (`IntMap.lookup` cNodes conn))
    zIntervals = case (zk (toInteger readLo), zk (toInteger readHi - 1)) of
      (Just a, Just b) → [a .. b]
      _ → []
    -- the column and its four side neighbours, as coordinates
    fiveOf x y = [(x, y), (x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
    boxesOf x y = [(xi a, yj b) | (a, b) ← fiveOf x y]
    runsOf (x, y) = maybe [] (\column → Map.findWithDefault [] column runs) (columnAt x y)
    meeting (lo, hi) = hi > readLo && lo < readHi
    special x y = any (any meeting . runsOf) (fiveOf x y)
    signature (cx, cy) =
      let x = x0 + cx
          y = y0 + cy
          boxes = boxesOf x y
          axes = foldr (.|.) 0 [axesAt i j k | (Just i, Just j) ← boxes, k ← zIntervals]
       in if special x y
            then Own x y
            else Shared boxes (if testBit axes 0 then Just x else Nothing) (if testBit axes 1 then Just y else Nothing)
    locals = [(cx, cy) | cy ← [0 .. side - 1], cx ← [0 .. side - 1]]
    signatures = map signature locals
    -- classes numbered in the order their first column appears
    numbering = foldl (\acc sig → if Map.member sig acc then acc else Map.insert sig (Map.size acc) acc) Map.empty signatures
    classOf = [numbering Map.! sig | sig ← signatures]
    representatives =
      map snd . Map.toAscList $
        Map.fromListWith (\_ earlier → earlier) [(numbering Map.! sig, (x0 + cx, y0 + cy, sig)) | ((cx, cy), sig) ← zip locals signatures]
    plan (x, y, sig) = ClassPlan (x, y) (map piece (zip breaks (drop 1 breaks)))
      where
        cuts = [toInteger c | c ← Set.toAscList (Set.takeWhileAntitone (< fromInteger z1) (Set.dropWhileAntitone (<= fromInteger z0) (cZCuts conn)))]
        runEnds = case sig of
          Own {} → [toInteger e | col ← fiveOf x y, (lo, hi) ← runsOf col, e ← [lo, hi], toInteger e > z0, toInteger e < z1]
          Shared {} → []
        breaks = dedup (sort ([z0, z1] <> cuts <> runEnds))
        boxes = boxesOf x y
        piece (a, b) =
          let levelParam = case zk a of
                Just k → any (\(mi, mj) → maybe False (\(i, j) → testBit (axesAt i j k) 2) ((,) <$> mi <*> mj)) boxes
                Nothing → False
           in (if levelParam then PerLevel else Span) (fromInteger a) (fromInteger b)

-- | The region the plan is for.
planRegion ∷ KnowledgePlan → RegionCoord
planRegion = kpRegion

-- | The tiles to evaluate, in the order 'assembleRegionKnowledge' takes their answers.
planTiles ∷ KnowledgePlan → [TileCoord]
planTiles kp =
  [ tile
  | ClassPlan (x, y) pieces ← kpClasses kp
  , z ← concatMap pieceLevels pieces
  , Right tile ← [TileCoord <$> axisFromInteger x <*> axisFromInteger y <*> axisFromInteger (toInteger z)]
  ]

-- | How many column classes the plan has.
planClasses ∷ KnowledgePlan → Int
planClasses = length . kpClasses

-- | How many pieces its classes have, in all.
planPieces ∷ KnowledgePlan → Int
planPieces kp = sum [length (cpPieces c) | c ← kpClasses kp]

-- | How many of 'planTiles' are evaluated because a box keeps the level as a component parameter.
planPerLevelTiles ∷ KnowledgePlan → Int
planPerLevelTiles kp = sum [fromIntegral (b - a) | c ← kpClasses kp, PerLevel a b ← cpPieces c]

-- | The levels of a piece that are evaluated.
pieceLevels ∷ Piece → [Int64]
pieceLevels = \case
  PerLevel a b → [a .. b - 1]
  Span a b
    | b - a >= 3 → [a, a + 1, b - 1]
    | b - a == 2 → [a, a + 1]
    | otherwise → [a]

-- ---------------------------------------------------------------------------
-- The compressed answer

-- | The knowledge of every cell of one region: each distinct column's runs, @[lo, hi)@ in absolute
-- levels covering the region's 32 exactly, coalesced, and which of them each column has. A region
-- whose answer is uniform is one class of one run. The constructor is private.
data RegionKnowledge = RegionKnowledge
  { rkRegion ∷ !RegionCoord
  , rkClasses ∷ ![[(Int64, Int64, CellKnowledge)]]
  , rkColumns ∷ ![Int]
  -- ^ The class of each local column (@y * 16 + x@); empty when there is one class.
  }
  deriving stock (Eq, Show)

-- | Build the answer from a plan and the answers of 'planTiles', in order. 'Nothing' when the answers
-- do not match the plan's tiles in number.
assembleRegionKnowledge ∷ KnowledgePlan → [CellKnowledge] → Maybe RegionKnowledge
assembleRegionKnowledge kp answers0 = do
  (classRuns, rest) ← takeClasses (kpClasses kp) answers0
  if not (null rest) then Nothing else Just ()
  -- classes are told apart by their runs (keyed by an encoding: 'CellKnowledge' has no order)
  let keyOf runs = [(a, b, knowledgeKey k) | (a, b, k) ← runs]
      distinct = foldl (\acc runs → if Map.member (keyOf runs) acc then acc else Map.insert (keyOf runs) (Map.size acc, runs) acc) Map.empty classRuns
      renumber = [fst (distinct Map.! keyOf runs) | runs ← classRuns]
      classes = map snd (sortOn fst (Map.elems distinct))
      columns = [renumber !! c | c ← kpClassOf kp]
  pure (RegionKnowledge (kpRegion kp) classes (if length classes == 1 then [] else columns))
  where
    takeClasses [] answers = Just ([], answers)
    takeClasses (ClassPlan _ pieces : more) answers = do
      (runs, rest) ← takePieces pieces answers
      (others, rest') ← takeClasses more rest
      pure (coalesce runs : others, rest')
    takePieces [] answers = Just ([], answers)
    takePieces (p : ps) answers = do
      let n = length (pieceLevels p)
      if length (take n answers) < n then Nothing else Just ()
      let (mine, rest) = splitAt n answers
          runs = case (p, mine) of
            (PerLevel a _, _) → [(z, z + 1, k) | (z, k) ← zip [a ..] mine]
            (Span a b, [k]) → [(a, b, k)]
            (Span a b, [k0, k1]) → [(a, a + 1, k0), (a + 1, b, k1)]
            (Span a b, [k0, k1, k2]) → [(a, a + 1, k0), (a + 1, b - 1, k1), (b - 1, b, k2)]
            _ → []
      (others, rest') ← takePieces ps rest
      pure (runs <> others, rest')
    coalesce ((a, _, k) : (_, d, k') : more) | k == k' = coalesce ((a, d, k) : more)
    coalesce (r : more) = r : coalesce more
    coalesce [] = []

-- | Rebuild an answer from its parts (the inverse of the accessors, for a value decoded from a copy):
-- 'Nothing' unless every class covers the region's 32 levels with ordered, adjacent, coalesced runs,
-- there is at least one class, and the column map is empty for one class or names a class for each of
-- the 256 columns.
mkRegionKnowledge ∷ RegionCoord → [[(Int64, Int64, CellKnowledge)]] → [Int] → Maybe RegionKnowledge
mkRegionKnowledge region classes columns
  | null classes = Nothing
  | not (all covers classes) = Nothing
  | length classes == 1 && not (null columns) = Nothing
  | length classes > 1 && (toInteger (length columns) /= side * side || any (\c → c < 0 || c >= length classes) columns) = Nothing
  | otherwise = Just (RegionKnowledge region classes columns)
  where
    (_, _, z0) = regionOrigin region
    covers runs =
      not (null runs)
        && and [a < b | (a, b, _) ← runs]
        && and (zipWith (\(_, b, k) (c, _, k') → b == c && k /= k') runs (drop 1 runs))
        && (case runs of (a, _, _) : _ → toInteger a == z0; [] → False)
        && (case reverse runs of (_, b, _) : _ → toInteger b == z0 + levels; [] → False)

regionKnowledgeRegion ∷ RegionKnowledge → RegionCoord
regionKnowledgeRegion = rkRegion

-- | The distinct column runs.
regionKnowledgeClasses ∷ RegionKnowledge → [[(Int64, Int64, CellKnowledge)]]
regionKnowledgeClasses = rkClasses

-- | The class of each local column (@y * 16 + x@); empty when there is one class.
regionKnowledgeColumns ∷ RegionKnowledge → [Int]
regionKnowledgeColumns = rkColumns

-- | The one answer of every cell, when the region is uniform.
regionKnowledgeUniform ∷ RegionKnowledge → Maybe CellKnowledge
regionKnowledgeUniform rk = case rkClasses rk of
  [[(_, _, k)]] → Just k
  _ → Nothing

-- | The runs of one of the region's columns; 'Nothing' for a column outside it.
regionKnowledgeColumn ∷ RegionKnowledge → Column → Maybe [(Int64, Int64, CellKnowledge)]
regionKnowledgeColumn rk (Column x y) = do
  let (x0, y0, _) = regionOrigin (rkRegion rk)
      cx = toInteger (axisValue x) - x0
      cy = toInteger (axisValue y) - y0
  if cx < 0 || cx >= side || cy < 0 || cy >= side then Nothing else Just ()
  let index = fromInteger (cy * side + cx)
  case rkClasses rk of
    [only] → Just only
    classes → (classes !!) <$> lookupIndex index (rkColumns rk)
  where
    lookupIndex i xs = case drop i xs of
      c : _ → Just c
      [] → Nothing

-- | The knowledge of one cell of the region; 'Nothing' for a cell outside it.
regionKnowledgeAt ∷ RegionKnowledge → TileCoord → Maybe CellKnowledge
regionKnowledgeAt rk (TileCoord x y z) = do
  runs ← regionKnowledgeColumn rk (Column x y)
  case [k | (a, b, k) ← runs, axisValue z >= a, axisValue z < b] of
    k : _ → Just k
    [] → Nothing

-- ---------------------------------------------------------------------------
-- Helpers

-- | A cell's knowledge as a number, to tell classes apart.
knowledgeKey ∷ CellKnowledge → (Int, Int)
knowledgeKey (CellKnowledge solid void) =
  ( case solid of NoSolid → 0; SolidKnown → 1; SolidUnknown → 2
  , case void of NoVoidHere → 0; VoidKnown → 1; VoidUnknown → 2
  )

side ∷ Integer
side = toInteger columnSize

levels ∷ Integer
levels = toInteger regionLevels

regionOrigin ∷ RegionCoord → (Integer, Integer, Integer)
regionOrigin (RegionCoord rx ry rz) = (toInteger rx * side, toInteger ry * side, toInteger rz * levels)

columnAt ∷ Integer → Integer → Maybe Column
columnAt x y = case (axisFromInteger x, axisFromInteger y) of
  (Right ax, Right ay) → Just (Column ax ay)
  _ → Nothing

dedup ∷ Eq a ⇒ [a] → [a]
dedup (a : b : rest) | a == b = dedup (b : rest)
dedup (a : rest) = a : dedup rest
dedup [] = []
