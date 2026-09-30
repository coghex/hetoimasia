-- | Affine transformations as 4×4 matrices, under the package's right-handed
-- convention and column vectors (@M × v@).
--
-- A point is a 'V4' with @w = 1@ and a direction one with @w = 0@: a
-- 'translation' moves the first and leaves the second unchanged. Compose with
-- 'Hetoimasia.Math.Matrix.multiply', whose right operand applies first.
--
-- __Arithmetic.__ 'translation' and 'scaling' place their arguments in a
-- matrix unchanged, so a NaN or infinite argument appears in the result as
-- ordinary IEEE arithmetic would leave it. 'rotation' is checked: it returns
-- 'Nothing' rather than a matrix containing NaN or an infinity.
--
-- __Dependencies.__ @base@, "Hetoimasia.Math.Vector",
-- "Hetoimasia.Math.Matrix" and this package's hidden finiteness test.
--
-- __State.__ The module owns none.
module Hetoimasia.Math.Transform
  ( translation
  , scaling
  , rotation
  ) where

import Hetoimasia.Math.Internal.Finite (allFinite, finite)
import Hetoimasia.Math.Matrix (M44, fromRows, toColumnMajor)
import Hetoimasia.Math.Vector (V3 (..), V4 (..), normalize)

-- | Translation by an offset.
translation ∷ V3 → M44
translation (V3 x y z) =
  fromRows
    (V4 1 0 0 x)
    (V4 0 1 0 y)
    (V4 0 0 1 z)
    (V4 0 0 0 1)

-- | Scaling by a factor along each axis; the factors may differ.
scaling ∷ V3 → M44
scaling (V3 x y z) =
  fromRows
    (V4 x 0 0 0)
    (V4 0 y 0 0)
    (V4 0 0 z 0)
    (V4 0 0 0 1)

-- | Rotation about an axis through the origin by an angle in radians.
--
-- A positive angle turns by the right-hand rule: with the thumb along the
-- axis, the fingers curl in the positive direction, so a quarter turn about
-- +Z takes +X to +Y. The axis need not be unit length; it is normalized first.
--
-- 'Nothing' when the axis is zero-length or has a NaN or infinite component,
-- when the angle is NaN or infinite, or when the calculated matrix would
-- contain either. A 'Just' result is finite.
rotation ∷ V3 → Float → Maybe M44
rotation axis angle
  | not (finite angle) = Nothing
  | otherwise = do
      V3 x y z ← normalize axis
      let c = cos angle
          s = sin angle
          t = 1 - c
          matrix =
            fromRows
              (V4 (t * x * x + c) (t * x * y - s * z) (t * x * z + s * y) 0)
              (V4 (t * x * y + s * z) (t * y * y + c) (t * y * z - s * x) 0)
              (V4 (t * x * z - s * y) (t * y * z + s * x) (t * z * z + c) 0)
              (V4 0 0 0 1)
      if allFinite (toColumnMajor matrix) then Just matrix else Nothing
