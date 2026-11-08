-- | The immutable terrain facts a plan reads, the three-way answer they give
-- (known air, known solid, unavailable) and the demand that names what is
-- missing.
--
-- == Authority and availability
--
-- Cell values come from the layered 'Source' and the retained 'Changes'
-- (TRA-2), the same authority every other consumer reads. Whether a cell may
-- be /shown/ is a separate fact the residency owner supplies as an
-- 'Availability': which horizontal chunks (16 x 16 columns) are published and,
-- for each, which half-open intervals of levels are ready. A level in no ready
-- interval is /unavailable/, which is neither air nor solid: nothing is
-- invented for it, a decision that needs it is reported as incomplete, and
-- the demand names it. 'AllKnown' declares every level of every chunk ready.
--
-- A chunk absent from a 'KnownIntervals' map is wholly unavailable, including
-- its column summaries. A chunk present in the map has its column summaries
-- published, so an empty column of such a chunk is /known/ empty
-- ('SurfaceAbsent'); a column whose highest solid cell lies in an unready
-- interval is 'SurfaceUnavailable'.
--
-- Levels outside the supported range hold nothing and are known air: the world
-- ends there, and nothing wraps or clamps.
--
-- == Cost
--
-- 'columnFacts' answers a window of one column as runs over the source's
-- intervals and the availability's, so a long gap of air, solid or removed
-- cells is one run however many levels it spans.
--
-- State, ownership and lifetime: none. The caller owns the source, changes and
-- availability values; a 'TerrainFacts' only names them and never mutates
-- them. It owns no thread or resource.
module Hetoimasia.Terrain.Render2D.Facts
  ( -- * Versions
    Versions (..)

    -- * Chunks and availability
  , ChunkKey (..)
  , chunkOfColumn
  , chunkColumns
  , regionOfLevel
  , Availability (..)
  , mkAvailability
  , unknownPieces

    -- * Facts
  , TerrainFacts (..)
  , FKind (..)
  , FRun (..)
  , columnFacts
  , kindAt
  , SurfaceResult (..)
  , surfaceAt

    -- * Demand
  , ChunkDemand (..)
  , Demand (..)
  , emptyDemand
  , demandFrom
  , demandIntervalCount
  ) where

import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Changes (Changes)
import Hetoimasia.Terrain.Coordinate (AxisCoord, axisValue)
import Hetoimasia.Terrain.Query
import Hetoimasia.Terrain.Shape (ShapeId)
import Hetoimasia.Terrain.Source (Source)

-- | The three version identities one coherent plan carries: the arena
-- incarnation, the content revision and the residency generation. The caller
-- supplies them; a plan and a pick refuse inputs whose versions differ.
data Versions = Versions
  { versionArena ∷ !Word64
  , versionContent ∷ !Word64
  , versionResidency ∷ !Word64
  }
  deriving stock (Eq, Ord, Show)

-- | A horizontal storage chunk: 16 columns on each axis, by floor division.
data ChunkKey = ChunkKey !Int64 !Int64
  deriving stock (Eq, Ord, Show)

-- | The chunk holding a column.
chunkOfColumn ∷ Column → ChunkKey
chunkOfColumn column = ChunkKey (axisValue (columnX column) `div` 16) (axisValue (columnY column) `div` 16)

-- | The columns of a chunk are the 16 x 16 tile coordinates that floor-divide
-- to its key: the lowest X and Y, so a caller can reason about seams.
chunkColumns ∷ ChunkKey → ((Integer, Integer), (Integer, Integer))
chunkColumns (ChunkKey cx cy) = ((lo cx, lo cx + 15), (lo cy, lo cy + 15))
  where
    lo c = toInteger c * 16

-- | The vertical region key (32 levels, floor division) holding a level.
regionOfLevel ∷ Integer → Integer
regionOfLevel level = level `div` 32

-- | Which levels are ready, per chunk. Intervals are half-open @[lo, hi)@.
data Availability
  = -- | Every level of every chunk is ready.
    AllKnown
  | -- | Only the listed intervals of the listed chunks are ready. Built by
    -- 'mkAvailability', which keeps each list sorted, disjoint and coalesced
    -- so that a seam between two adjacent ready intervals is invisible.
    -- Each chunk's intervals are keyed by their first level, so a query visits
    -- only the intervals that meet its window, never the others.
    KnownIntervals !(Map.Map ChunkKey (Map.Map Integer Integer))
  deriving stock (Eq, Show)

-- | The availability of the listed intervals. A chunk listed with no interval
-- is published with no ready level (its summaries are known).
mkAvailability ∷ [(ChunkKey, [ZRange])] → Availability
mkAvailability entries =
  KnownIntervals
    ( Map.map Map.fromDistinctAscList $
        Map.fromListWith
          (\new old → merge (old <> new))
          [(key, merge [(zRangeLo r, zRangeHi r) | r ← ranges]) | (key, ranges) ← entries]
    )
  where
    merge = coalesce . sortOn fst
    coalesce ((a, b) : (c, d) : rest)
      | c <= b = coalesce ((a, max b d) : rest)
    coalesce (x : rest) = x : coalesce rest
    coalesce [] = []

-- | The pieces of @[lo, hi)@ that are not ready in a chunk, ascending.
unknownPieces ∷ Availability → ChunkKey → Integer → Integer → [(Integer, Integer)]
unknownPieces availability key lo hi = [(a, b) | (a, b, False) ← pieces availability key lo hi]

-- The whole of @[lo, hi)@ partitioned into ready and unready pieces.
pieces ∷ Availability → ChunkKey → Integer → Integer → [(Integer, Integer, Bool)]
pieces _ _ lo hi | lo >= hi = []
pieces AllKnown _ lo hi = [(lo, hi, True)]
pieces (KnownIntervals chunks) key lo hi = go lo relevant
  where
    -- The intervals meeting @[lo, hi)@: the one that starts before @lo@ and
    -- reaches it, then those that start inside. The rest of the chunk's
    -- intervals are never visited, however many there are.
    intervals = Map.findWithDefault Map.empty key chunks
    relevant =
      [(a, b) | Just (a, b) ← [Map.lookupLT lo intervals], b > lo]
        <> Map.toAscList (Map.takeWhileAntitone (< hi) (Map.dropWhileAntitone (< lo) intervals))
    go from _ | from >= hi = []
    go from [] = [(from, hi, False)]
    go from ((a, b) : rest)
      | b <= from = go from rest
      | a >= hi = [(from, hi, False)]
      | a > from = (from, a, False) : go a ((a, b) : rest)
      | otherwise = let end = min b hi in (from, end, True) : go end rest

-- | The immutable inputs a plan reads: the version identities, the source
-- and retained removals and what is ready.
data TerrainFacts = TerrainFacts
  { factsVersions ∷ !Versions
  , factsSource ∷ !Source
  , factsChanges ∷ !Changes
  , factsAvailability ∷ !Availability
  }

-- | What one level of one column holds, as far as the facts say.
data FKind
  = -- | Not ready: neither air nor solid.
    FUnknown
  | -- | Known air.
    FAir
  | -- | Known solid of a material and a /world/ shape identity.
    FSolid !MaterialId !ShapeId
  deriving stock (Eq, Show)

-- | A maximal stretch of one kind, @[lo, hi)@.
data FRun = FRun
  { runLo ∷ !Integer
  , runHi ∷ !Integer
  , runKind ∷ !FKind
  }
  deriving stock (Eq, Show)

-- | The runs of one column over @[lo, hi)@, covering it exactly with no gap
-- and no two adjacent equal kinds, or the query refusal. Levels outside the
-- supported range are air.
columnFacts ∷ QueryLimits → TerrainFacts → Column → Integer → Integer → Either QueryError [FRun]
columnFacts limits facts column lo hi
  | lo >= hi = Right []
  | otherwise = coalesceRuns . concat <$> traverse piece spans
  where
    worldLo = negate (2 ^ (62 ∷ Int))
    worldHi = 2 ^ (62 ∷ Int)
    key = chunkOfColumn column
    spans =
      [(lo, min hi worldLo, False) | lo < worldLo]
        <> [(max lo worldLo, min hi worldHi, True) | max lo worldLo < min hi worldHi]
        <> [(max lo worldHi, hi, False) | hi > worldHi]
    -- A void piece is air; an in-world piece is split by what is ready.
    piece (a, b, False) = Right [FRun a b FAir | a < b]
    piece (a, b, True) = concat <$> traverse known (pieces (factsAvailability facts) key a b)
    known (a, b, False) = Right [FRun a b FUnknown]
    known (a, b, True) = case mkZRange a b of
      Left _ → Right [FRun a b FAir]
      Right range → do
        runs ← columnRuns limits (factsSource facts) (factsChanges facts) column range
        pure [FRun (zRangeLo r) (zRangeHi r) (kindOf cell) | Run r cell ← runs]
    kindOf Air = FAir
    kindOf (Solid material shape) = FSolid material shape

coalesceRuns ∷ [FRun] → [FRun]
coalesceRuns (FRun a b k : FRun c d l : rest)
  | b == c && k == l = coalesceRuns (FRun a d k : rest)
coalesceRuns (x : rest) = x : coalesceRuns rest
coalesceRuns [] = []

-- | The kind a run list gives one level. A level the list does not cover is
-- reported unavailable, never air.
kindAt ∷ [FRun] → Integer → FKind
kindAt runs level = case [k | FRun a b k ← runs, a <= level, level < b] of
  (k : _) → k
  [] → FUnknown

-- | The highest remaining solid cell of a column, as the facts allow.
data SurfaceResult
  = -- | The highest remaining solid level.
    SurfacePresent !AxisCoord
  | -- | A known empty column.
    SurfaceAbsent
  | -- | Its facts are not ready: not a known empty column. The chunk and the
    -- level (when the column has a solid cell at all) that are missing.
    SurfaceUnavailable !ChunkKey !(Maybe AxisCoord)
  deriving stock (Eq, Show)

-- | The followed surface of a column. The highest cell is taken from the
-- source and retained removals together, and is reported only if its level is
-- ready.
surfaceAt ∷ TerrainFacts → Column → SurfaceResult
surfaceAt facts column = case highestOccupied (factsSource facts) (factsChanges facts) column of
  Just occupied
    | ready (toInteger (axisValue (occupiedLevel occupied))) → SurfacePresent (occupiedLevel occupied)
    | otherwise → SurfaceUnavailable key (Just (occupiedLevel occupied))
  Nothing
    | published → SurfaceAbsent
    | otherwise → SurfaceUnavailable key Nothing
  where
    key = chunkOfColumn column
    availability = factsAvailability facts
    ready level = null (unknownPieces availability key level (level + 1))
    published = case availability of
      AllKnown → True
      KnownIntervals chunks → Map.member key chunks

-- | What one chunk is missing: explicit half-open level intervals, ascending
-- and coalesced, and the vertical region keys (32 levels) they touch.
data ChunkDemand = ChunkDemand
  { demandChunk ∷ !ChunkKey
  , demandIntervals ∷ ![(Integer, Integer)]
  , demandRegions ∷ ![Integer]
  }
  deriving stock (Eq, Show)

-- | The missing facts of a plan or a camera, ascending by chunk. It names
-- spatial keys only: coalescing, admission and execution belong to the
-- residency owner.
newtype Demand = Demand {demandChunks ∷ [ChunkDemand]}
  deriving stock (Eq, Show)

emptyDemand ∷ Demand
emptyDemand = Demand []

-- | The demand for the listed @(chunk, lo, hi)@ intervals: intervals merged
-- per chunk, regions derived.
demandFrom ∷ [(ChunkKey, Integer, Integer)] → Demand
demandFrom wants = Demand [chunkDemand key (merge ranges) | (key, ranges) ← Map.toAscList grouped]
  where
    grouped = Map.fromListWith (<>) [(key, [(lo, hi)]) | (key, lo, hi) ← wants, lo < hi]
    merge = coalesce . sortOn fst
    coalesce ((a, b) : (c, d) : rest)
      | c <= b = coalesce ((a, max b d) : rest)
    coalesce (x : rest) = x : coalesce rest
    coalesce [] = []
    chunkDemand key intervals =
      ChunkDemand
        { demandChunk = key
        , demandIntervals = intervals
        , demandRegions = mergeRegions (concat [[regionOfLevel a .. regionOfLevel (b - 1)] | (a, b) ← intervals])
        }
    mergeRegions = foldr insertAscending []
    insertAscending r rs = if r `elem` rs then rs else r : rs

-- | The number of intervals a demand names, for a caller's bound.
demandIntervalCount ∷ Demand → Int
demandIntervalCount (Demand chunks) = sum [length (demandIntervals chunk) | chunk ← chunks]
