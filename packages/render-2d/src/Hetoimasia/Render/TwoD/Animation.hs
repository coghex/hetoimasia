-- | Frame tables and the frame a view's time selects from one (R2D-18, design
-- D-32, P-4).
--
-- A view carries an ordered list of 'FrameTable' values and an animation time.
-- Table @i@ is the one an instance whose frame-table index is @i + 1@ selects
-- (index 0 means the instance is not animated), and the index is the flags
-- word's bits 4–15, so at most 'maxFrameIndex', 4095, tables can be named. An
-- animated instance shows the rectangle of its table's current frame in place of
-- its own.
--
-- __The current frame.__ For a table of @count@ frames of @duration@ seconds and
-- a view at time @t@,
--
-- > f = floor (t / duration) mod count
--
-- where the quotient is the 'Double' division of the view's time by the table's
-- duration, the floor is taken to an unbounded 'Integer' (so a large finite
-- quotient never overflows, whatever its size), and @mod@ is the integer
-- modulus, in @[0, count)@. A time exactly on a boundary @k × duration@ whose
-- quotient is exactly @k@ selects frame @k mod count@. Nothing is snapped, and
-- there is no tolerance: when a product such as @43 × 0.1@ rounds, the quotient
-- is whatever the 'Double' division gives (@42.99999999999999@, frame 42, for
-- the duration 0.1), and that is the frame selected. The recorder computes this
-- once for each table of each view and writes it as a whole number; the shader
-- does no time arithmetic; the oracle computes the same formula with the same
-- function. A frame is therefore exact at any time and any duration validation
-- admits.
--
-- __What validation admits.__ A table has a count of at least 1, a finite
-- positive duration, exactly one rectangle for each frame, every value of which
-- is finite; the count times the duration is finite in 'Double' (a whole cycle
-- can be measured), and so is the view's time over the duration (the quotient
-- exists). The view's time is finite and not negative.
--
-- __Totality.__ 'currentFrame' is total: a table or a time validation refuses,
-- for which there is no quotient, selects frame 0.
--
-- __Dependencies.__ @base@ and this package's snapshot module.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Animation
  ( -- * Indices
    maxFrameIndex
  , frameTableOfIndex

    -- * What a table and a time must be
  , timeValid
  , durationValid
  , cycleFinite
  , phaseFinite
  , framesFinite

    -- * Selection
  , currentFrame
  ) where

import Data.Word (Word16)
import Hetoimasia.Render.TwoD.Snapshot (FrameTable (..), UvRect (..))

-- | The largest frame-table index a flags word holds, 4095: the 12 bits 4–15.
maxFrameIndex ∷ Word16
maxFrameIndex = 4095

-- | The table an index selects: 'Nothing' for index 0, which means the
-- instance is not animated, and table @k − 1@ for an index @k@. The table may
-- lie beyond the view's, which validation refuses.
frameTableOfIndex ∷ Word16 → Maybe Int
frameTableOfIndex 0 = Nothing
frameTableOfIndex index = Just (fromIntegral index - 1)

-- | Whether a 'Double' is neither NaN nor an infinity.
finiteDouble ∷ Double → Bool
finiteDouble value = not (isNaN value || isInfinite value)

-- | An animation time a view may hold: finite and not negative (negative zero
-- included, which is zero).
timeValid ∷ Double → Bool
timeValid time = finiteDouble time && time >= 0

-- | A frame duration a table may hold: finite and positive.
durationValid ∷ Double → Bool
durationValid duration = finiteDouble duration && duration > 0

-- | Whether the table's count times its duration, in 'Double', is finite. A
-- count below 1 has no cycle and is refused on its own, so it is not asked.
cycleFinite ∷ FrameTable → Bool
cycleFinite table = finiteDouble (fromIntegral (frameTableCount table) * frameTableDuration table)

-- | Whether the view's time over the table's duration, the 'Double' division, is
-- finite.
phaseFinite ∷ Double → FrameTable → Bool
phaseFinite time table = finiteDouble (time / frameTableDuration table)

-- | Whether every value of every rectangle of the table is finite.
framesFinite ∷ FrameTable → Bool
framesFinite table = and [all finiteFloat [u0, v0, u1, v1] | UvRect u0 v0 u1 v1 ← frameTableFrames table]
  where
    finiteFloat value = not (isNaN value || isInfinite value)

-- | The frame a table shows at a view's time: @floor (t / duration) mod count@,
-- with the 'Double' quotient and an exact integer floor. Frame 0 for a table
-- with no frame or no finite quotient, which validation refuses.
currentFrame ∷ Double → FrameTable → Integer
currentFrame time table
  | frameTableCount table < 1 = 0
  | not (finiteDouble quotient) = 0
  | otherwise = floor quotient `mod` toInteger (frameTableCount table)
  where
    quotient = time / frameTableDuration table
