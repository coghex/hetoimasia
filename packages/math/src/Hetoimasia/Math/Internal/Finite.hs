-- | The finiteness test every checked operation applies to its inputs and its
-- result.
--
-- __Ownership.__ A hidden module of @hetoimasia-math@, shared by the vector,
-- transform and projection modules so that the three agree on what a checked
-- result may contain.
--
-- __Dependencies.__ @base@ alone.
--
-- __State.__ The module owns none.
module Hetoimasia.Math.Internal.Finite
  ( finite
  , allFinite
  ) where

-- | Neither NaN nor an infinity.
finite ∷ Float → Bool
finite x = not (isNaN x || isInfinite x)

-- | Every value is 'finite'.
allFinite ∷ [Float] → Bool
allFinite = all finite
