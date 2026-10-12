-- | The application-wide discrete-step-zoom setting: a list of zoom levels.
--
-- The levels are read in a view's zoom mode, so whether a level of 2 means two
-- pixels per world unit or something else follows from the view that uses it.
-- The setting is independent of the per-view settings, of pixel snap, and of
-- the zoom mode, and is not part of a snapshot; smooth zoom stays available
-- whatever the list holds.
--
-- A candidate list validates, or is refused with every reason found, each
-- naming the level it concerns. Nothing is clamped, sorted or deduplicated. The
-- list must be non-empty, every level finite and positive, and the levels
-- strictly increasing. The default list is the whole numbers 1 to 8.
--
-- 'stepZoomIn' and 'stepZoomOut' move a zoom value through a validated list.
--
-- __Dependencies.__ @base@ and the package's hidden checks.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.ZoomSteps
  ( ZoomSteps
  , zoomLevels
  , defaultZoomSteps
  , validateZoomSteps

    -- * Stepping
  , stepZoomIn
  , stepZoomOut

    -- * Refusals
  , ZoomRefusal (..)
  , ZoomLocation (..)
  , ZoomReason (..)
  ) where

import Data.Foldable (find)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (fromMaybe)
import Hetoimasia.Render.TwoD.Internal.Check (positiveFinite)

-- | A validated list of zoom levels: non-empty, finite, positive and strictly
-- increasing. The constructor is private, so every value came from
-- 'validateZoomSteps' or is 'defaultZoomSteps'.
newtype ZoomSteps = ZoomSteps (NonEmpty Float)
  deriving stock (Eq, Show)

-- | The levels, in increasing order.
zoomLevels ∷ ZoomSteps → NonEmpty Float
zoomLevels (ZoomSteps levels) = levels

-- | The whole numbers 1 to 8.
defaultZoomSteps ∷ ZoomSteps
defaultZoomSteps = ZoomSteps (1 :| [2 .. 8])

-- | Step in: the smallest level greater than the current zoom, or the largest
-- level when none is greater. The result is always one of the list's levels.
--
-- The levels and the zoom value are read in the same zoom mode, so the
-- function does not depend on which: it only compares numbers. Smooth zoom is a
-- plain zoom value that these functions never touch. A zoom that is NaN has no
-- greater level, so it steps to the largest; a validated camera zoom is never
-- NaN.
stepZoomIn ∷ ZoomSteps → Float → Float
stepZoomIn (ZoomSteps levels) zoom =
  fromMaybe (NonEmpty.last levels) (find (> zoom) levels)

-- | Step out: the largest level smaller than the current zoom, or the smallest
-- level when none is smaller. The result is always one of the list's levels.
-- A NaN zoom has no smaller level, so it steps to the smallest.
stepZoomOut ∷ ZoomSteps → Float → Float
stepZoomOut (ZoomSteps levels) zoom =
  fromMaybe (NonEmpty.head levels) (find (< zoom) (NonEmpty.reverse levels))

-- | Where a refusal was found.
data ZoomLocation
  = -- | The list as a whole.
    WholeList
  | -- | The level at this index, counting from zero.
    AtLevel !Int
  deriving stock (Eq, Ord, Show)

-- | Why a candidate list was refused.
data ZoomReason
  = -- | The list is empty.
    ZoomListEmpty
  | -- | The level is NaN, infinite, zero or negative.
    ZoomLevelInvalid
  | -- | The level is not greater than the level before it. Checked
    -- independently of 'ZoomLevelInvalid'; only a NaN neighbour has no order to
    -- compare, so an infinity is compared like any other number.
    ZoomLevelNotIncreasing
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | One reason a candidate was refused, and where.
data ZoomRefusal = ZoomRefusal
  { zoomRefusalLocation ∷ !ZoomLocation
  , zoomRefusalReason ∷ !ZoomReason
  }
  deriving stock (Eq, Ord, Show)

-- | Validate a candidate list, refusing it with every reason found, in the
-- order of the levels.
validateZoomSteps ∷ [Float] → Either (NonEmpty ZoomRefusal) ZoomSteps
validateZoomSteps [] = Left (ZoomRefusal WholeList ZoomListEmpty :| [])
validateZoomSteps levels@(first : rest) =
  case NonEmpty.nonEmpty refusals of
    Just found → Left found
    Nothing → Right (ZoomSteps (first :| rest))
  where
    refusals =
      concat
        [ [ZoomRefusal (AtLevel index) ZoomLevelInvalid | not (positiveFinite level)]
            <> [ ZoomRefusal (AtLevel index) ZoomLevelNotIncreasing
               | Just before ← [previous]
               , not (isNaN before || isNaN level)
               , level <= before
               ]
        | (index, level, previous) ← zip3 [0 ..] levels (Nothing : map Just levels)
        ]
