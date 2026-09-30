-- | Best fit's search, reconstructed from a block's layout without touching the
-- placement code.
--
-- The strategy looks through free ranges in increasing (size, offset) order,
-- starting with the first range at least as large as the request, and takes the
-- first one the request fits once aligned. Replaying that order over
-- 'blockRanges' gives how many ranges one placement examines and where it
-- lands. The probe checks the reconstructed offset against the real one on
-- every sampled placement, so a count is only reported when the reconstruction
-- agreed with the implementation. Granularity is one in the probe's blocks, so
-- no page rule applies.
module Parity.Reference
  ( Search (..)
  , reconstructSearch
  ) where

import Data.List (sortOn)
import Data.Word (Word64)
import Hetoimasia.GPU.Model.Placement (BlockRange (..))

-- | One reconstructed search.
data Search = Search
  { searchExamined ∷ !Int
    -- ^ Free ranges examined, the chosen one included; all eligible ones when
    -- the request is refused.
  , searchFreeRanges ∷ !Int
    -- ^ Free ranges in the block.
  , searchOffset ∷ !(Maybe Word64)
    -- ^ Where best fit places the request, or 'Nothing' for a refusal.
  }

reconstructSearch ∷ [BlockRange] → Word64 → Word64 → Search
reconstructSearch layout size alignment = go 0 eligible
  where
    frees = [(rangeSize, start) | FreeRange start rangeSize ← layout]
    eligible = sortOn id [(rangeSize, start) | (rangeSize, start) ← frees, rangeSize >= size]
    go examined [] = Search examined (length frees) Nothing
    go examined ((rangeSize, start) : rest)
      | aligned + size <= start + rangeSize = Search (examined + 1) (length frees) (Just aligned)
      | otherwise = go (examined + 1) rest
      where
        aligned = (start + alignment - 1) `div` alignment * alignment
