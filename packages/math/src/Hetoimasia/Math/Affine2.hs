-- | 2×3 affine transforms of the plane over 32-bit 'Float', under the package's
-- column-vector convention.
--
-- __Conventions.__ A transform maps a point @(x, y)@ to
--
-- > x' = a * x + c * y + tx
-- > y' = b * x + d * y + ty
--
-- so its columns are @(a, b)@, @(c, d)@ and the translation @(tx, ty)@, and
-- 'toColumnMajor' lists them as @[a, b, c, d, tx, ty]@. In @'compose' f g@ the
-- transform @g@ applies first, as in 'Hetoimasia.Math.Matrix.multiply'. Angles
-- are in radians, and a positive 'rotation' takes +X toward +Y. The module
-- chooses no handedness for the plane, so whether +Y is up or down on a screen
-- is the caller's convention.
--
-- __No storage promise.__ 'toColumnMajor' is a mathematical view: the
-- representation is private, and this module promises no byte layout,
-- alignment or packing. A renderer that uploads a transform builds its own
-- buffer from the six coefficients.
--
-- __Arithmetic.__ 'translation', 'scaling', 'compose' and 'applyPoint' are
-- ordinary IEEE @Float@ arithmetic: a NaN or infinite argument, or an overflow,
-- appears in the result. 'rotation' and 'inverse' are checked: each returns
-- 'Nothing' rather than a transform containing NaN or an infinity.
--
-- __Dependencies.__ @base@, "Hetoimasia.Math.Vector" and this package's hidden
-- finiteness test.
--
-- __State.__ The module owns none.
module Hetoimasia.Math.Affine2
  ( -- * Transforms
    Affine2

    -- * Construction
  , identity
  , fromColumns
  , translation
  , scaling
  , rotation

    -- * Views
  , columns
  , toColumnMajor

    -- * Arithmetic
  , compose
  , applyPoint

    -- * Checked operations
  , inverse
  ) where

import GHC.Float (double2Float, float2Double)
import Hetoimasia.Math.Internal.Finite (allFinite, finite)
import Hetoimasia.Math.Vector (V2 (..))

-- | A 2×3 affine transform, held privately as its two linear columns and its
-- translation.
data Affine2 = Affine2 !V2 !V2 !V2
  deriving stock (Eq)

-- | Shown as the 'fromColumns' expression that builds it.
instance Show Affine2 where
  showsPrec d (Affine2 x y t) =
    showParen (d > 10) $
      showString "fromColumns "
        . showsPrec 11 x
        . showChar ' '
        . showsPrec 11 y
        . showChar ' '
        . showsPrec 11 t

-- | The transform that leaves every point where it is.
identity ∷ Affine2
identity = Affine2 (V2 1 0) (V2 0 1) (V2 0 0)

-- | The transform with these columns: the images of the unit X and Y
-- directions, then the translation. A direction's image is @(a, b)@ and
-- @(c, d)@ in the convention above.
fromColumns ∷ V2 → V2 → V2 → Affine2
fromColumns = Affine2

-- | Translation by an offset.
translation ∷ V2 → Affine2
translation = Affine2 (V2 1 0) (V2 0 1)

-- | Scaling by a factor along each axis; the factors may differ.
scaling ∷ V2 → Affine2
scaling (V2 x y) = Affine2 (V2 x 0) (V2 0 y) (V2 0 0)

-- | Rotation about the origin by an angle in radians. A positive angle takes
-- +X toward +Y: a quarter turn takes @(1, 0)@ to @(0, 1)@.
--
-- 'Nothing' when the angle is NaN or infinite. A 'Just' result is finite.
rotation ∷ Float → Maybe Affine2
rotation angle
  | not (finite angle) = Nothing
  | otherwise = Just (Affine2 (V2 c s) (V2 (negate s) c) (V2 0 0))
  where
    c = cos angle
    s = sin angle

-- | The three columns: the images of the unit X and Y directions, then the
-- translation.
columns ∷ Affine2 → (V2, V2, V2)
columns (Affine2 x y t) = (x, y, t)

-- | The six coefficients @[a, b, c, d, tx, ty]@, column by column. A
-- mathematical view only; see the module header.
toColumnMajor ∷ Affine2 → [Float]
toColumnMajor (Affine2 (V2 a b) (V2 c d) (V2 tx ty)) = [a, b, c, d, tx, ty]

-- | The composition @compose f g@: applying it applies @g@, then @f@.
compose ∷ Affine2 → Affine2 → Affine2
compose f (Affine2 x y t) = Affine2 (direction f x) (direction f y) (applyPoint f t)

-- | The image of a point.
applyPoint ∷ Affine2 → V2 → V2
applyPoint transform@(Affine2 _ _ (V2 tx ty)) point = V2 (x + tx) (y + ty)
  where
    V2 x y = direction transform point

-- | The linear part applied to a vector: the translation does not move it.
direction ∷ Affine2 → V2 → V2
direction (Affine2 (V2 xa xb) (V2 ya yb) _) (V2 px py) =
  V2 (px * xa + py * ya) (px * xb + py * yb)

-- | The transform that undoes this one.
--
-- 'Nothing' for a singular transform, for one with a NaN or infinite
-- coefficient, and whenever a coefficient of the inverse cannot be
-- represented as a finite @Float@. Every other transform inverts: the
-- determinant and the inverse are calculated in double precision, whose range
-- holds every product of two @Float@ values and whose subtraction of two such
-- exact products is zero only for a transform that is exactly singular. A
-- 'Just' result is finite.
inverse ∷ Affine2 → Maybe Affine2
inverse transform@(Affine2 (V2 a b) (V2 c d) (V2 tx ty))
  | not (allFinite (toColumnMajor transform)) = Nothing
  | determinant == 0 = Nothing
  | allFinite (toColumnMajor result) = Just result
  | otherwise = Nothing
  where
    a' = float2Double a
    b' = float2Double b
    c' = float2Double c
    d' = float2Double d
    tx' = float2Double tx
    ty' = float2Double ty
    determinant = a' * d' - b' * c'
    -- The linear part's inverse, then the translation that undoes the linear
    -- part's image of the old translation.
    ia = d' / determinant
    ib = negate b' / determinant
    ic = negate c' / determinant
    id' = a' / determinant
    itx = negate (ia * tx' + ic * ty')
    ity = negate (ib * tx' + id' * ty')
    result =
      Affine2
        (V2 (double2Float ia) (double2Float ib))
        (V2 (double2Float ic) (double2Float id'))
        (V2 (double2Float itx) (double2Float ity))
