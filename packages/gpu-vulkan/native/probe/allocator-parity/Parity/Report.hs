-- | Requirement 7's arithmetic, and the figures the parity record retains.
--
-- __Refused bytes.__ An implementation's refused-byte rate is the bytes of the
-- allocation requests it refused divided by the bytes of every allocation
-- request in the trace. The Haskell rate may exceed VMA's by at most 0.02.
--
-- __Fragmentation.__ At each checkpoint, @1 − largest free range ÷ free
-- bytes@, and zero when nothing is free. The Haskell value may differ from
-- VMA's by at most 0.02 at every checkpoint.
--
-- __Time.__ Every timed operation is replayed in each measured repetition, and
-- its sample is the mean of its repetitions, which averages the clock's tick
-- away. Medians and 95th percentiles are nearest-rank over those per-operation
-- means. Allocations and frees are separate populations: every allocation
-- request, placed or refused, and every free of an allocation the
-- implementation itself placed. The Haskell median may be at most twice VMA's
-- in each population. Placements — the allocation requests the Haskell side
-- placed — must have a Haskell median under 5 µs.
module Parity.Report
  ( Timing (..)
  , Summary (..)
  , Figures (..)
  , Verdict (..)
  , summarise
  , figures
  , verdicts
  , nearestRank
  , refusedRate
  , fragmentationOf
  , fixed
  ) where

import Data.List (sort)
import qualified Data.Vector.Unboxed as Unboxed
import Data.Word (Word64)
import Parity.Trace (OpKind (..), Trace (..), opKind)

-- | Per-operation mean nanoseconds of one implementation, and which
-- operations ran on it.
data Timing = Timing
  { timingMeans ∷ !(Unboxed.Vector Double)
  , timingPlaced ∷ !(Unboxed.Vector Bool)
    -- ^ Per operation: an allocation this implementation placed.
  , timingFreed ∷ !(Unboxed.Vector Bool)
    -- ^ Per operation: a free of an allocation this implementation placed.
  }

-- | A population's size, median and 95th percentile, in nanoseconds.
data Summary = Summary
  { summaryCount ∷ !Int
  , summaryMedian ∷ !Double
  , summaryP95 ∷ !Double
  }

-- | The nearest-rank percentile: the smallest sample with at least @p@ of the
-- population at or below it.
nearestRank ∷ Double → [Double] → Double
nearestRank _ [] = 0 / 0
nearestRank p samples = sorted !! (max 1 (ceiling (p * fromIntegral (length sorted))) - 1)
  where
    sorted = sort samples

summarise ∷ [Double] → Summary
summarise samples = Summary (length samples) (nearestRank 0.5 samples) (nearestRank 0.95 samples)

-- | One implementation's figures for one trace.
data Figures = Figures
  { figuresRequestedBytes ∷ !Word64
  , figuresRefusedBytes ∷ !Word64
  , figuresRefusedCount ∷ !Int
  , figuresFragmentation ∷ ![Double]
    -- ^ Per checkpoint, in trace order.
  , figuresAllocations ∷ !Summary
  , figuresFrees ∷ !Summary
  , figuresPlacements ∷ !Summary
  }

figures ∷ Trace → Timing → Unboxed.Vector Word64 → Unboxed.Vector Word64 → Figures
figures trace timing freeBytes largestFree =
  Figures
    { figuresRequestedBytes = sum [traceSizes trace Unboxed.! i | i ← allocations]
    , figuresRefusedBytes = sum [traceSizes trace Unboxed.! i | i ← refused]
    , figuresRefusedCount = length refused
    , figuresFragmentation = zipWith fragmentationOf (Unboxed.toList freeBytes) (Unboxed.toList largestFree)
    , figuresAllocations = summarise [timingMeans timing Unboxed.! i | i ← allocations]
    , figuresFrees = summarise [timingMeans timing Unboxed.! i | i ← operations, timingFreed timing Unboxed.! i]
    , figuresPlacements = summarise [timingMeans timing Unboxed.! i | i ← allocations, timingPlaced timing Unboxed.! i]
    }
  where
    operations = [0 .. Unboxed.length (traceKinds trace) - 1]
    allocations = [i | i ← operations, opKind (traceKinds trace Unboxed.! i) == Allocate]
    refused = [i | i ← allocations, not (timingPlaced timing Unboxed.! i)]

-- | @1 − largest free range ÷ free bytes@, and zero when nothing is free.
fragmentationOf ∷ Word64 → Word64 → Double
fragmentationOf free largest
  | free == 0 = 0
  | otherwise = 1 - fromIntegral largest / fromIntegral free

-- | Whether one criterion was met, and the figures it was decided on.
data Verdict = Verdict
  { verdictCriterion ∷ !String
  , verdictMet ∷ !Bool
  , verdictDetail ∷ !String
  }

refusedRate ∷ Figures → Double
refusedRate f
  | figuresRequestedBytes f == 0 = 0
  | otherwise = fromIntegral (figuresRefusedBytes f) / fromIntegral (figuresRequestedBytes f)

-- | Requirement 7's four criteria for one trace, Haskell against VMA.
verdicts ∷ [String] → Figures → Figures → [Verdict]
verdicts labels haskell vma =
  [ Verdict
      "refused bytes within 2 points"
      (refusedRate haskell - refusedRate vma <= 0.02)
      (percent (refusedRate haskell) <> " against " <> percent (refusedRate vma))
  , Verdict
      "fragmentation within 2 points at every checkpoint"
      (worst <= 0.02)
      ("largest difference " <> points worst <> worstAt)
  , Verdict
      "median time at most 2× VMA's"
      (allocationRatio <= 2 && freeRatio <= 2)
      ( "allocation "
          <> ratio allocationRatio
          <> " ("
          <> nanoseconds (summaryMedian (figuresAllocations haskell))
          <> " against "
          <> nanoseconds (summaryMedian (figuresAllocations vma))
          <> "), free "
          <> ratio freeRatio
          <> " ("
          <> nanoseconds (summaryMedian (figuresFrees haskell))
          <> " against "
          <> nanoseconds (summaryMedian (figuresFrees vma))
          <> ")"
      )
  , Verdict
      "median placement under 5 µs"
      (summaryMedian (figuresPlacements haskell) < 5000)
      (nanoseconds (summaryMedian (figuresPlacements haskell)))
  ]
  where
    differences = zipWith (\h v → abs (h - v)) (figuresFragmentation haskell) (figuresFragmentation vma)
    worst = maximum (0 : differences)
    worstAt = case [label | (label, d) ← zip labels differences, d == worst, worst > 0] of
      label : _ → " at " <> label
      [] → ""
    allocationRatio = summaryMedian (figuresAllocations haskell) / summaryMedian (figuresAllocations vma)
    freeRatio = summaryMedian (figuresFrees haskell) / summaryMedian (figuresFrees vma)
    percent x = showFixed 2 (100 * x) <> "%"
    points x = showFixed 2 (100 * x) <> " points"
    ratio x = showFixed 2 x <> "×"
    nanoseconds x = showFixed 1 x <> " ns"

showFixed ∷ Int → Double → String
showFixed = fixed

-- | A number with a fixed count of decimals; @n/a@ for NaN and @∞@ for an
-- infinity, such as a ratio whose denominator measured zero.
fixed ∷ Int → Double → String
fixed digits x
  | isNaN x = "n/a"
  | isInfinite x = if x > 0 then "∞" else "-∞"
  | otherwise =
      let scale = 10 ^ digits ∷ Integer
          scaled = round (x * fromIntegral scale) ∷ Integer
          (whole, fraction) = abs scaled `quotRem` scale
          sign = if scaled < 0 then "-" else ""
          padded = let digitsShown = show fraction in replicate (digits - length digitsShown) '0' <> digitsShown
       in sign <> show whole <> (if digits > 0 then "." <> padded else "")
