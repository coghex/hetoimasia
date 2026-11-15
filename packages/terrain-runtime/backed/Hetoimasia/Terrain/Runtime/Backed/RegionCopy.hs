-- | A regional terrain-and-knowledge snapshot (#690): an immutable value copied out of one committed
-- version of an arena's store, for a consumer that builds view data from it alone.
--
-- It holds the identities of that version (the arena incarnation, its content and knowledge
-- revisions, and the residency generation read in the same transaction that pinned it), the
-- incarnation's immutable source (shared, never copied: an incarnation's source never changes, so
-- the incarnation is its identity) and, for each held region, two independent parts:
--
-- * /terrain/: the removed intervals of the region's 256 columns, clipped to its 32 levels. With the
--   source they answer every cell (a removed cell is air, every other cell is the source's), and a
--   consumer turns them into 'Hetoimasia.Terrain.Changes.Changes' with
--   'Hetoimasia.Terrain.Changes.changesFromIntervals'. A pristine region holds none.
-- * /knowledge/: what #661's discovery model knows of every cell ('D.queryCell'), as the compressed
--   column runs of 'D.RegionKnowledge': a region whose answer is uniform is one class of one run.
--
-- Each part is 'PartReady' or 'PartUnavailable' (a page its build needed could not be read); an
-- unavailable part is never air, fog, undiscovered or the pristine source, and other regions are
-- unaffected. A region the snapshot does not hold is 'PartNotHeld'.
--
-- Both parts are kept packed in one short byte string each, so what a snapshot holds is accounted
-- object by object ('snapshotFootprint', an upper bound of its heap) and grows with the region's
-- intervals and knowledge runs, never with its 8,192 cells.
--
-- State, ownership and lifetime: none here; the value is immutable. The service owns a snapshot's
-- charge and its release (see "Hetoimasia.Terrain.Runtime").
module Hetoimasia.Terrain.Runtime.Backed.RegionCopy
  ( -- * The value
    RegionSnapshot (..)
  , RegionCopy (..)
  , RegionWork (..)
  , RegionPart (..)
  , regionSnapshotIncarnation
  , regionSnapshotContentRevision
  , regionSnapshotKnowledgeRevision
  , regionSnapshotGeneration
  , regionSnapshotSource
  , regionSnapshotRegions
  , regionTerrain
  , regionKnowledge
  , regionCell
  , regionCellKnowledge

    -- * Inspection
  , regionSnapshotWork
  , workColumnsRead
  , workRunsRead
  , workClasses
  , workPieces
  , workEvaluations
  , workPerLevelEvaluations

    -- * Packing
  , packTerrain
  , unpackTerrain
  , packKnowledge
  , unpackKnowledge

    -- * What it holds
  , snapshotFootprint
  , snapshotHeaderBytes
  , regionEntryBytes
  , shortBytes
  , worstRegionBytes
  , buildScratchBytes
  , regionReservation
  ) where

import Data.Bits (shiftL, shiftR, (.&.))
import Data.ByteString.Short (ShortByteString)
import qualified Data.ByteString.Short as SBS
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64, Word8)
import Hetoimasia.Terrain.Cell (Cell (..), Column (..), ZRange, mkZRange, zRangeHi, zRangeLo)
import Hetoimasia.Terrain.Changes (changeColumnBytes, changeIntervalBytes, emptyChanges, runsMeetingLevels)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), TileCoord (..), axisFromInteger, axisValue, decomposeTile)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Query (cellAt)
import Hetoimasia.Terrain.Residency (ArenaId, Revision)
import Hetoimasia.Terrain.Source (Source)

-- ---------------------------------------------------------------------------
-- The value

-- | An immutable regional snapshot. The constructor is private to the package: a client reads it
-- through the functions below, which are never field labels, so it cannot be rewritten.
data RegionSnapshot = RegionSnapshot
  { rsArena ∷ !ArenaId
  , rsContent ∷ !Revision
  , rsKnowledge ∷ !Revision
  , rsGeneration ∷ !Word64
  , rsSource ∷ !Source
  , rsRegions ∷ !(Map RegionCoord RegionCopy)
  }

-- | One held region's copied parts ('Nothing': unavailable) and the work its build did.
data RegionCopy = RegionCopy
  { rcTerrain ∷ !(Maybe ShortByteString)
  , rcKnowledge ∷ !(Maybe ShortByteString)
  , rcWork ∷ !RegionWork
  }

-- | The structural work one region's build did: the columns and removed runs it read (its own and
-- the 64 beside it), the column classes and pieces of its knowledge plan, the 'D.queryCell'
-- evaluations it ran, and how many of those were per level (boxes whose components keep the level).
-- Plain counts, for verification.
data RegionWork = RegionWork !Int !Int !Int !Int !Int !Int
  deriving stock (Eq, Show)

-- | What a snapshot says of one part of a region.
data RegionPart a
  = -- | The snapshot does not hold the region.
    PartNotHeld
  | -- | The part could not be read: never air, fog, undiscovered or the pristine source.
    PartUnavailable
  | PartReady !a
  deriving stock (Eq, Show, Functor)

regionSnapshotIncarnation ∷ RegionSnapshot → ArenaId
regionSnapshotIncarnation = rsArena

-- | The content revision of the one committed version the snapshot was read from.
regionSnapshotContentRevision ∷ RegionSnapshot → Revision
regionSnapshotContentRevision = rsContent

-- | The knowledge revision of that version.
regionSnapshotKnowledgeRevision ∷ RegionSnapshot → Revision
regionSnapshotKnowledgeRevision = rsKnowledge

-- | The arena's residency generation, read in the transaction that pinned that version.
regionSnapshotGeneration ∷ RegionSnapshot → Word64
regionSnapshotGeneration = rsGeneration

-- | The incarnation's immutable source (shared, not copied; the incarnation is its identity).
regionSnapshotSource ∷ RegionSnapshot → Source
regionSnapshotSource = rsSource

-- | The regions the snapshot holds, ascending.
regionSnapshotRegions ∷ RegionSnapshot → [RegionCoord]
regionSnapshotRegions = Map.keys . rsRegions

-- | A held region's removed intervals, @[lo, hi)@ in absolute levels, clipped to its 32 levels.
regionTerrain ∷ RegionSnapshot → RegionCoord → RegionPart [(Column, ZRange)]
regionTerrain snapshot region = case Map.lookup region (rsRegions snapshot) of
  Nothing → PartNotHeld
  Just copy → maybe PartUnavailable (PartReady . unpackTerrain region) (rcTerrain copy)

-- | A held region's knowledge.
regionKnowledge ∷ RegionSnapshot → RegionCoord → RegionPart D.RegionKnowledge
regionKnowledge snapshot region = case Map.lookup region (rsRegions snapshot) of
  Nothing → PartNotHeld
  Just copy → case rcKnowledge copy of
    Nothing → PartUnavailable
    Just packed → maybe PartUnavailable PartReady (unpackKnowledge region packed)

-- | What a cell holds as of the snapshot: air where it was removed, the source's cell otherwise.
regionCell ∷ RegionSnapshot → TileCoord → RegionPart Cell
regionCell snapshot tile@(TileCoord x y z) = case regionTerrain snapshot (fst (decomposeTile tile)) of
  PartNotHeld → PartNotHeld
  PartUnavailable → PartUnavailable
  PartReady intervals
    | or [lo <= level && level < hi | (Column cx cy, range) ← intervals, cx == x, cy == y, let (lo, hi) = zBounds range] → PartReady Air
    | otherwise → PartReady (cellAt (rsSource snapshot) emptyChanges tile)
  where
    level = toInteger (axisValue z)
    zBounds range = (zRangeLo range, zRangeHi range)

-- | What is known of a cell as of the snapshot.
regionCellKnowledge ∷ RegionSnapshot → TileCoord → RegionPart D.CellKnowledge
regionCellKnowledge snapshot tile = case regionKnowledge snapshot (fst (decomposeTile tile)) of
  PartNotHeld → PartNotHeld
  PartUnavailable → PartUnavailable
  PartReady rk → maybe PartUnavailable PartReady (D.regionKnowledgeAt rk tile)

-- ---------------------------------------------------------------------------
-- Inspection

-- | The structural work a held region's build did.
regionSnapshotWork ∷ RegionSnapshot → RegionCoord → Maybe RegionWork
regionSnapshotWork snapshot region = rcWork <$> Map.lookup region (rsRegions snapshot)

workColumnsRead, workRunsRead, workClasses, workPieces, workEvaluations, workPerLevelEvaluations ∷ RegionWork → Int
workColumnsRead (RegionWork n _ _ _ _ _) = n
workRunsRead (RegionWork _ n _ _ _ _) = n
workClasses (RegionWork _ _ n _ _ _) = n
workPieces (RegionWork _ _ _ n _ _) = n
workEvaluations (RegionWork _ _ _ _ n _) = n
workPerLevelEvaluations (RegionWork _ _ _ _ _ n) = n

-- ---------------------------------------------------------------------------
-- Packing

-- | Pack a region's removed runs (of its own columns, @[lo, hi)@, as read over its levels and one
-- beyond) clipped to its 32 levels: for each column with an interval, ascending by its local index
-- @y * 16 + x@, the index, the count and each interval's ends relative to the region's floor.
packTerrain ∷ RegionCoord → [(Column, Int64, Int64)] → ShortByteString
packTerrain region runs =
  SBS.pack . concat $
    [ fromIntegral index : fromIntegral (length intervals) : concat [[fromIntegral (lo - z0), fromIntegral (hi - z0)] | (lo, hi) ← intervals]
    | (index, intervals) ← Map.toAscList byColumn
    , not (null intervals)
    ]
  where
    (x0, y0, z0) = origin region
    byColumn =
      Map.map (sortOn fst) . Map.fromListWith (<>) $
        [ (localIndex, [(max z0 lo, min (z0 + 32) hi)])
        | (Column x y, lo, hi) ← runs
        , let cx = axisValue x - x0
              cy = axisValue y - y0
              localIndex = cy * 16 + cx
        , cx >= 0 && cx < 16 && cy >= 0 && cy < 16
        , hi > z0 && lo < z0 + 32
        ]

-- | The removed intervals a packed terrain part holds, in absolute levels.
unpackTerrain ∷ RegionCoord → ShortByteString → [(Column, ZRange)]
unpackTerrain region packed = go (SBS.unpack packed)
  where
    (x0, y0, z0) = origin region
    go (index : count : rest) =
      let (ends, more) = splitAt (2 * fromIntegral count) rest
          (cy, cx) = fromIntegral index `divMod` 16
       in [ (column, range)
          | Just column ← [columnOf (x0 + cx) (y0 + cy)]
          , (lo, hi) ← pairs ends
          , Right range ← [mkZRange (toInteger (z0 + fromIntegral lo)) (toInteger (z0 + fromIntegral hi))]
          ]
            <> go more
    go _ = []
    pairs (a : b : rest) = (a, b) : pairs rest
    pairs _ = []

-- | Pack a region's knowledge: the number of classes (two bytes), then each class's run count and each
-- run's first level relative to the region's floor and its knowledge's code, then (only when there is
-- more than one class) the class of each of the 256 columns.
packKnowledge ∷ D.RegionKnowledge → ShortByteString
packKnowledge rk =
  SBS.pack $
    [fromIntegral (count `shiftR` 8), fromIntegral (count .&. 0xff)]
      <> concat [fromIntegral (length runs) : concat [[fromIntegral (lo - z0), code k] | (lo, _, k) ← runs] | runs ← classes]
      <> map fromIntegral (D.regionKnowledgeColumns rk)
  where
    classes = D.regionKnowledgeClasses rk
    count = length classes
    (_, _, z0) = origin (D.regionKnowledgeRegion rk)

-- | The knowledge a packed part holds; 'Nothing' for bytes that do not describe a region's knowledge.
unpackKnowledge ∷ RegionCoord → ShortByteString → Maybe D.RegionKnowledge
unpackKnowledge region packed = case SBS.unpack packed of
  hi : lo : rest → do
    let count = (fromIntegral hi `shiftL` 8) + fromIntegral lo ∷ Int
    (classes, columns) ← classesOf count rest
    D.mkRegionKnowledge region classes (map fromIntegral columns)
  _ → Nothing
  where
    (_, _, z0) = origin region
    classesOf 0 rest = Just ([], rest)
    classesOf n (runCount : rest) = do
      let (body, more) = splitAt (2 * fromIntegral runCount) rest
      starts ← traverse (\(a, c) → (,) (z0 + fromIntegral a) <$> decode c) (pairs body)
      let ends = drop 1 (map fst starts) <> [z0 + 32]
          runs = [(a, b, k) | ((a, k), b) ← zip starts ends]
      (others, final) ← classesOf (n - 1 ∷ Int) more
      pure (runs : others, final)
    classesOf _ [] = Nothing
    pairs (a : b : rest) = (a, b) : pairs rest
    pairs _ = []

-- | A cell's knowledge as one byte: its solid's code times three plus its void's.
code ∷ D.CellKnowledge → Word8
code (D.CellKnowledge solid void) =
  3 * (case solid of D.NoSolid → 0; D.SolidKnown → 1; D.SolidUnknown → 2)
    + (case void of D.NoVoidHere → 0; D.VoidKnown → 1; D.VoidUnknown → 2)

decode ∷ Word8 → Maybe D.CellKnowledge
decode c
  | c > 8 = Nothing
  | otherwise =
      D.CellKnowledge
        <$> lookup (c `div` 3) [(0, D.NoSolid), (1, D.SolidKnown), (2, D.SolidUnknown)]
        <*> lookup (c `mod` 3) [(0, D.NoVoidHere), (1, D.VoidKnown), (2, D.VoidUnknown)]

-- ---------------------------------------------------------------------------
-- What it holds

-- | The accounted bytes a snapshot holds: its record and, for each held region, its entry and its
-- packed parts. The source is the incarnation's, shared, and not counted.
--
-- The figure names every heap object of the copied value as GHC 9.14.1 lays it out on a 64-bit
-- machine, optimised as every local package is built (strict fields of one word unpacked): an object
-- is a one-word header and its payload, a word for each pointer or unpacked word, and a byte array's
-- payload is rounded up to a word. It is an upper bound of what a walk of the evaluated value's heap
-- measures, the source left out: a part that is unavailable is charged as a ready one's box, and the
-- identity fields are charged as boxes of their own as well as the record's words.
snapshotFootprint ∷ RegionSnapshot → Word64
snapshotFootprint snapshot =
  snapshotHeaderBytes
    + sum [regionEntryBytes + maybe 0 (shortBytes . SBS.length) (rcTerrain c) + maybe 0 (shortBytes . SBS.length) (rcKnowledge c) | c ← Map.elems (rsRegions snapshot)]

-- | One word.
wordBytes ∷ Word64
wordBytes = 8

-- | A heap object: its header word and its payload of @n@ words.
objectBytes ∷ Word64 → Word64
objectBytes n = wordBytes * (1 + n)

-- | The snapshot's own objects: its record (the arena, the two revisions and the generation as a word
-- each, the source and the region map as pointers: 56), each of the four identities as a box of its
-- own (16 each: 64) and the map's empty leaf, a static object of a header alone (8).
snapshotHeaderBytes ∷ Word64
snapshotHeaderBytes = objectBytes 6 + 4 * objectBytes 1 + objectBytes 0

-- | One held region's entry, its parts' contents apart: its node in the map (the size as a word, the
-- key, the value and the two subtrees: 48), its key (three coordinates as a word each: 32), its copy
-- record (two parts and the work record as pointers: 32), the 'Just' box of each part (16 each: 32)
-- and its work record (six counts as a word each: 56).
regionEntryBytes ∷ Word64
regionEntryBytes = objectBytes 5 + objectBytes 3 + objectBytes 3 + 2 * objectBytes 1 + objectBytes 6

-- | A packed part of @n@ bytes: the short byte string's boxed array (a pointer: 16) and the array
-- itself, a header and its size (16) and the payload rounded up to a word.
shortBytes ∷ Int → Word64
shortBytes n = objectBytes 1 + objectBytes 1 + wordBytes * ((fromIntegral n + 7) `div` 8)

-- | The most one held region can hold: its entry, a terrain part of 256 columns each with the most
-- intervals 32 levels can hold (16: removed runs are coalesced, so two are a level apart), and a
-- knowledge part of 256 distinct classes each of 32 runs with the column map.
worstRegionBytes ∷ Word64
worstRegionBytes = regionEntryBytes + shortBytes (256 * (2 + 2 * 16)) + shortBytes (2 + 256 * (1 + 2 * 32) + 256)

-- | What one region's build keeps while it runs, at the package's accounted figures: the removed runs
-- its two reads keep and the same runs indexed for its plan (320 columns over 34 levels each), its
-- plan's pieces (256 classes of at most 34) and its tiles and their answers (8,192 of each at most).
buildScratchBytes ∷ Word64
buildScratchBytes = 2 * runsBytes + pieceBytes + tileBytes
  where
    columns = 320
    runsBytes = columns * fromIntegral (runsMeetingLevels (34 ∷ Int)) * fromIntegral changeIntervalBytes + columns * fromIntegral changeColumnBytes
    pieceBytes = 256 * 34 * 16
    tileBytes = 8192 * (32 + 16)

-- | What admission reserves for a snapshot of @n@ regions: its record, the most each region can hold
-- and one region's build scratch. At settlement the charge becomes the snapshot's exact footprint.
regionReservation ∷ Int → Word64
regionReservation n = snapshotHeaderBytes + fromIntegral n * worstRegionBytes + buildScratchBytes

-- ---------------------------------------------------------------------------
-- Helpers

origin ∷ RegionCoord → (Int64, Int64, Int64)
origin (RegionCoord rx ry rz) = (rx * 16, ry * 16, rz * 32)

columnOf ∷ Int64 → Int64 → Maybe Column
columnOf x y = case (axisFromInteger (toInteger x), axisFromInteger (toInteger y)) of
  (Right ax, Right ay) → Just (Column ax ay)
  _ → Nothing
