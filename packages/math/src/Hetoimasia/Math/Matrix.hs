-- | 4×4 matrices of 32-bit 'Float', acting on column vectors.
--
-- __Conventions.__ A matrix multiplies a column vector on its left, @M × v@
-- ('apply'), so in @multiply a b@ the transformation @b@ applies first. A
-- matrix is built from, and read back as, its rows or its columns; which one
-- a function takes is in its name.
--
-- __No storage promise.__ 'toColumnMajor' is a mathematical view: the sixteen
-- elements, column by column. The representation is private, and this module
-- promises no byte layout, alignment or packing; a graphics backend that needs
-- one builds it from the elements.
--
-- __Arithmetic.__ Every operation here is ordinary IEEE @Float@ arithmetic.
--
-- __Dependencies.__ @base@ and "Hetoimasia.Math.Vector".
--
-- __State.__ The module owns none.
module Hetoimasia.Math.Matrix
  ( -- * Matrices
    M44
  , Index (..)

    -- * Construction
  , identity
  , fromColumns
  , fromRows

    -- * Views
  , columns
  , rows
  , element
  , toColumnMajor

    -- * Arithmetic
  , multiply
  , apply
  , transpose
  ) where

import Hetoimasia.Math.Vector (V4 (..), add, scale)

-- | A 4×4 matrix, held privately as its four columns.
data M44 = M44 !V4 !V4 !V4 !V4
  deriving stock (Eq)

-- | Shown as the 'fromColumns' expression that builds it.
instance Show M44 where
  showsPrec d (M44 c0 c1 c2 c3) =
    showParen (d > 10) $
      showString "fromColumns "
        . showsPrec 11 c0
        . showChar ' '
        . showsPrec 11 c1
        . showChar ' '
        . showsPrec 11 c2
        . showChar ' '
        . showsPrec 11 c3

-- | A row or column index, @I0@ first.
data Index = I0 | I1 | I2 | I3
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The identity matrix.
identity ∷ M44
identity =
  M44 (V4 1 0 0 0) (V4 0 1 0 0) (V4 0 0 1 0) (V4 0 0 0 1)

-- | The matrix with these columns, first to last.
fromColumns ∷ V4 → V4 → V4 → V4 → M44
fromColumns = M44

-- | The matrix with these rows, top to bottom.
fromRows ∷ V4 → V4 → V4 → V4 → M44
fromRows r0 r1 r2 r3 = transpose (M44 r0 r1 r2 r3)

-- | The columns, first to last.
columns ∷ M44 → (V4, V4, V4, V4)
columns (M44 c0 c1 c2 c3) = (c0, c1, c2, c3)

-- | The rows, top to bottom.
rows ∷ M44 → (V4, V4, V4, V4)
rows = columns . transpose

-- | The element at a row and a column: @element row column@.
element ∷ Index → Index → M44 → Float
element row column (M44 c0 c1 c2 c3) = component row $ case column of
  I0 → c0
  I1 → c1
  I2 → c2
  I3 → c3

-- | The sixteen elements, column by column: element @(r, c)@ is at position
-- @4 * c + r@. A mathematical view only; see the module header.
toColumnMajor ∷ M44 → [Float]
toColumnMajor (M44 c0 c1 c2 c3) = concatMap listed [c0, c1, c2, c3]
  where
    listed (V4 x y z w) = [x, y, z, w]

-- | The product @a × b@: applying it applies @b@, then @a@.
multiply ∷ M44 → M44 → M44
multiply a (M44 c0 c1 c2 c3) = M44 (apply a c0) (apply a c1) (apply a c2) (apply a c3)

-- | The product @M × v@ of a matrix and a column vector.
apply ∷ M44 → V4 → V4
apply (M44 c0 c1 c2 c3) (V4 x y z w) =
  scale x c0 `add` scale y c1 `add` scale z c2 `add` scale w c3

-- | The transpose.
transpose ∷ M44 → M44
transpose (M44 (V4 a0 a1 a2 a3) (V4 b0 b1 b2 b3) (V4 c0 c1 c2 c3) (V4 d0 d1 d2 d3)) =
  M44 (V4 a0 b0 c0 d0) (V4 a1 b1 c1 d1) (V4 a2 b2 c2 d2) (V4 a3 b3 c3 d3)

-- | One component of a column.
component ∷ Index → V4 → Float
component index (V4 x y z w) = case index of
  I0 → x
  I1 → y
  I2 → z
  I3 → w
