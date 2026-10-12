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
-- __Dependencies.__ @base@ and the package's hidden checks.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.ZoomSteps
  ( ZoomSteps
  , zoomLevels
  , defaultZoomSteps
  , validateZoomSteps
  , ZoomRefusal (..)
  , ZoomLocation (..)
  , ZoomReason (..)
  ) where

import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
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
