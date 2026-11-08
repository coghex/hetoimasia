-- | The supplied discovery knowledge a cell-quad plan reads (TRA-16).
--
-- == What this is
--
-- Knowledge is /not/ terrain truth and /not/ residency. Terrain truth is the
-- layered source with its retained removals ("Hetoimasia.Terrain.Render2D.Facts"),
-- residency is the availability of its detail, and knowledge is what the
-- player has discovered. This module is the narrow, pure, immutable input the
-- live discovery service (a later slice, revised #645) adapts its retained
-- knowledge into; the planner never writes it, never asks a service for it
-- and never derives discovery from a camera, a cutaway or a query. Nothing
-- here is I/O.
--
-- == The four states of one cell
--
-- > CellUndiscovered   confirmed undiscovered: the cell is covered by generic fog
-- >                    whatever it truly holds; its terrain is never read for display
-- > CellDiscovered     the cell is known whole: air is absent, a solid shows its
-- >                    ordinary shape, and a shaped solid's empty component is
-- >                    discovered with it
-- > CellSolidKnown     the solid is known (seen from outside) but its empty
-- >                    component is not: a shaped solid shows as a known part
-- >                    plus a fog part; a full block has no empty component
-- > CellPending        the retained knowledge has not arrived: neither
-- >                    undiscovered nor discovered
--
-- There is no state for a discovered empty component whose solid boundary is
-- not known: a discovery publication records a revealed void and its exposed
-- solid together (P-14), so that combination is unrepresentable here rather
-- than guessed. A 'CellSolidKnown' cell that the terrain says is air is a
-- contradiction the plan refuses.
--
-- == Compressed summaries
--
-- A 'Knowledge' value never lists cells. It holds a default for every level of
-- every column, uniform summaries of whole 32-level regions of a chunk, and
-- exact runs for the columns that need them; the most specific wins (column
-- runs, then region, then default). A long buried or aerial span is therefore
-- one run however many levels it covers, and a query answers a window as runs.
--
-- State, ownership and lifetime: none. The caller owns the value; the planner
-- only reads it. Revision identity is the caller's: any change to the facts
-- carries a new 'knowledgeRevision', and a plan refuses a continuation made
-- against another one.
module Hetoimasia.Terrain.Render2D.Knowledge
  ( -- * States
    CellKnowledge (..)
  , KnowRun (..)

    -- * The value
  , KnowledgeSpec (..)
  , Knowledge
  , KnowledgeError (..)
  , mkKnowledge
  , knowledgeRevision
  , knowledgeDefault

    -- * Queries
  , knowledgeRuns
  ) where

import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.Terrain.Cell (Column)
import Hetoimasia.Terrain.Render2D.Facts (ChunkKey, chunkOfColumn)

-- | What is known of one cell. See the module description.
data CellKnowledge
  = CellUndiscovered
  | CellDiscovered
  | CellSolidKnown
  | CellPending
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | A maximal stretch of one state, @[lo, hi)@.
data KnowRun = KnowRun
  { knowLo ∷ !Integer
  , knowHi ∷ !Integer
  , knowState ∷ !CellKnowledge
  }
  deriving stock (Eq, Show)

-- | The knowledge a caller supplies, before it is checked.
data KnowledgeSpec = KnowledgeSpec
  { specRevision ∷ !Word64
  , specDefault ∷ !CellKnowledge
  -- ^ Every level of every column the other fields do not mention.
  , specRegions ∷ ![(ChunkKey, Integer, CellKnowledge)]
  -- ^ A chunk's 32-level region (by floor division) that is uniformly one
  -- state.
  , specColumns ∷ ![(Column, [(Integer, Integer, CellKnowledge)])]
  -- ^ Exact half-open runs of a column.
  }
  deriving stock (Eq, Show)

-- | Why a specification was refused.
data KnowledgeError
  = -- | A region was listed twice.
    DuplicateRegion !ChunkKey !Integer
  | -- | A column was listed twice.
    DuplicateColumn !Column
  | -- | A run is empty or reversed.
    InvalidRun !Column !Integer !Integer
  | -- | Two runs of one column overlap.
    OverlappingRuns !Column
  deriving stock (Eq, Show)

-- | Checked, immutable knowledge. The constructor is private.
data Knowledge = Knowledge
  { kRevision ∷ !Word64
  , kDefault ∷ !CellKnowledge
  , kRegions ∷ !(Map.Map (ChunkKey, Integer) CellKnowledge)
  , kColumns ∷ !(Map.Map Column (Map.Map Integer KnowRun))
  -- ^ Each column's disjoint runs by their first level, so a query finds the
  -- runs meeting its interval without visiting the others.
  }
  deriving stock (Eq, Show)

-- | Check a specification: no duplicate region or column, every run non-empty
-- and the runs of a column disjoint. Adjacent equal runs are coalesced.
mkKnowledge ∷ KnowledgeSpec → Either KnowledgeError Knowledge
mkKnowledge spec = do
  regions ← uniqueBy (\(k, r, _) → (k, r)) (\(k, r, _) → DuplicateRegion k r) (specRegions spec)
  columns ← uniqueBy fst (DuplicateColumn . fst) (specColumns spec)
  checked ← traverse (\(column, runs) → (,) column <$> checkRuns column runs) (Map.elems columns)
  pure
    Knowledge
      { kRevision = specRevision spec
      , kDefault = specDefault spec
      , kRegions = Map.fromList [((k, r), s) | (k, r, s) ← Map.elems regions]
      , kColumns = Map.fromList [(column, Map.fromList [(knowLo run, run) | run ← runs]) | (column, runs) ← checked]
      }
  where
    uniqueBy key err = go Map.empty
      where
        go acc [] = Right acc
        go acc (x : xs)
          | Map.member (key x) acc = Left (err x)
          | otherwise = go (Map.insert (key x) x acc) xs
    checkRuns column runs = do
      let sorted = sortOn (\(a, _, _) → a) runs
      mapM_ (\(a, b, _) → if a < b then Right () else Left (InvalidRun column a b)) sorted
      if or (zipWith (\(_, b, _) (c, _, _) → c < b) sorted (drop 1 sorted))
        then Left (OverlappingRuns column)
        else Right (coalesceRuns [KnowRun a b s | (a, b, s) ← sorted])

coalesceRuns ∷ [KnowRun] → [KnowRun]
coalesceRuns (KnowRun a b s : KnowRun c d t : rest)
  | b == c && s == t = coalesceRuns (KnowRun a d s : rest)
coalesceRuns (x : rest) = x : coalesceRuns rest
coalesceRuns [] = []

-- | The revision the caller gave this knowledge.
knowledgeRevision ∷ Knowledge → Word64
knowledgeRevision = kRevision

-- | The state of every level nothing else mentions.
knowledgeDefault ∷ Knowledge → CellKnowledge
knowledgeDefault = kDefault

-- | The runs of one column over @[lo, hi)@, covering it exactly with no gap
-- and no two adjacent equal states. Cost follows the runs, not the levels.
knowledgeRuns ∷ Knowledge → Column → Integer → Integer → [KnowRun]
knowledgeRuns knowledge column lo hi
  | lo >= hi = []
  | otherwise = coalesceRuns (fill lo explicit)
  where
    -- The runs meeting @[lo, hi)@: the one that starts before @lo@ and
    -- reaches it, then those that start inside. Runs outside the interval are
    -- never visited, however many the column holds (the cost is the search
    -- plus the runs returned).
    explicit =
      [ KnowRun (max a lo) (min b hi) s
      | KnowRun a b s ← straddling <> inside
      ]
    runsOf = Map.findWithDefault Map.empty column (kColumns knowledge)
    straddling = [run | Just (_, run) ← [Map.lookupLT lo runsOf], knowHi run > lo]
    inside = Map.elems (Map.takeWhileAntitone (< hi) (Map.dropWhileAntitone (< lo) runsOf))
    key = chunkOfColumn column
    fill from [] = background from hi
    fill from (run@(KnowRun a b _) : rest) = background from a <> [run] <> fill b rest
    -- A gap is the region summaries it crosses, or the default.
    background a b
      | a >= b = []
      | otherwise =
          [ KnowRun x y (Map.findWithDefault (kDefault knowledge) (key, r) (kRegions knowledge))
          | r ← [a `div` 32 .. (b - 1) `div` 32]
          , let x = max a (r * 32)
          , let y = min b ((r + 1) * 32)
          ]
