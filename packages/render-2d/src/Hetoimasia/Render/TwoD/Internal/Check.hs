-- | The finiteness and range tests validation applies.
--
-- __Ownership.__ A hidden module of @hetoimasia-render-2d@, shared by the
-- snapshot validation and the zoom-step validation so that the two agree on
-- what a finite value and an in-range value are. Every test refuses NaN and
-- both infinities explicitly, because an ordinary floating-point comparison
-- can accept NaN by accident.
--
-- __Dependencies.__ @base@ alone.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Internal.Check
  ( finite
  , allFinite
  , withinClosed
  , positiveFinite
  ) where

-- | Neither NaN nor an infinity.
finite ∷ Float → Bool
finite x = not (isNaN x || isInfinite x)

-- | Every value is 'finite'.
allFinite ∷ [Float] → Bool
allFinite = all finite

-- | Finite and inside the closed interval.
withinClosed ∷ Float → Float → Float → Bool
withinClosed low high x = finite x && x >= low && x <= high

-- | Finite and greater than zero.
positiveFinite ∷ Float → Bool
positiveFinite x = finite x && x > 0
