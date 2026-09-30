-- | Two-, three- and four-component vectors of 32-bit 'Float'.
--
-- The constructors are public: a vector is its components, and nothing about
-- one needs protecting. Each field is strict. The shared operations are the
-- functions below, overloaded over the closed 'Vector' class; the class's
-- methods are private, so no type outside this module is a 'Vector'.
--
-- __Arithmetic.__ 'add', 'sub', 'scale', 'dot', 'cross' and 'norm' are
-- ordinary IEEE @Float@ arithmetic: they overflow to an infinity, and propagate
-- NaN and infinities, exactly as the component arithmetic does. 'normalize' is
-- the checked operation: it returns 'Nothing' rather than a result containing
-- NaN or an infinity.
--
-- __Dependencies.__ @base@ and this package's hidden finiteness test.
--
-- __State.__ The module owns none.
module Hetoimasia.Math.Vector
  ( -- * Vectors
    V2 (..)
  , V3 (..)
  , V4 (..)
  , Vector

    -- * Arithmetic
  , add
  , sub
  , scale
  , dot
  , cross
  , norm

    -- * Checked operations
  , normalize
  ) where

import Hetoimasia.Math.Internal.Finite (allFinite)

-- | A two-component vector.
data V2 = V2 !Float !Float
  deriving stock (Eq, Show)

-- | A three-component vector.
data V3 = V3 !Float !Float !Float
  deriving stock (Eq, Show)

-- | A four-component vector: in this package's conventions a homogeneous
-- column vector, @w = 1@ for a point and @w = 0@ for a direction.
data V4 = V4 !Float !Float !Float !Float
  deriving stock (Eq, Show)

-- | The vector types, 'V2', 'V3' and 'V4'. The class is closed: its methods
-- are private to this module.
class Vector v where
  -- | Apply a function to every component.
  mapComponents ∷ (Float → Float) → v → v
  -- | Combine corresponding components.
  zipComponents ∷ (Float → Float → Float) → v → v → v
  -- | The components, in order.
  components ∷ v → [Float]

instance Vector V2 where
  mapComponents f (V2 x y) = V2 (f x) (f y)
  zipComponents f (V2 a b) (V2 x y) = V2 (f a x) (f b y)
  components (V2 x y) = [x, y]

instance Vector V3 where
  mapComponents f (V3 x y z) = V3 (f x) (f y) (f z)
  zipComponents f (V3 a b c) (V3 x y z) = V3 (f a x) (f b y) (f c z)
  components (V3 x y z) = [x, y, z]

instance Vector V4 where
  mapComponents f (V4 x y z w) = V4 (f x) (f y) (f z) (f w)
  zipComponents f (V4 a b c d) (V4 x y z w) = V4 (f a x) (f b y) (f c z) (f d w)
  components (V4 x y z w) = [x, y, z, w]

-- | The componentwise sum.
add ∷ Vector v ⇒ v → v → v
add = zipComponents (+)

-- | The componentwise difference: @sub a b@ is @a - b@.
sub ∷ Vector v ⇒ v → v → v
sub = zipComponents (-)

-- | Multiply every component by a scalar.
scale ∷ Vector v ⇒ Float → v → v
scale k = mapComponents (k *)

-- | The dot product.
dot ∷ Vector v ⇒ v → v → Float
dot a b = sum (components (zipComponents (*) a b))

-- | The cross product of three-component vectors, right-handed: @cross x y@
-- is @z@ for the unit axes.
cross ∷ V3 → V3 → V3
cross (V3 ax ay az) (V3 bx by bz) =
  V3 (ay * bz - az * by) (az * bx - ax * bz) (ax * by - ay * bx)

-- | The Euclidean length, @sqrt (dot v v)@. Ordinary arithmetic: a vector whose
-- squared length overflows has an infinite 'norm'.
norm ∷ Vector v ⇒ v → Float
norm v = sqrt (dot v v)

-- | The unit vector in the direction of @v@.
--
-- 'Nothing' for a zero-length vector, or one with a NaN or infinite component.
-- Every other vector normalizes, including one whose squared length would
-- overflow or underflow: the components are divided by the largest magnitude
-- among them before the length is taken, so the length is computed in @[1, 2]@.
-- A 'Just' result is finite.
normalize ∷ Vector v ⇒ v → Maybe v
normalize v
  | not (allFinite (components v)) = Nothing
  | largest == 0 = Nothing
  | allFinite (components unit) = Just unit
  | otherwise = Nothing
  where
    largest = foldr (max . abs) 0 (components v)
    bounded = mapComponents (/ largest) v
    unit = mapComponents (/ norm bounded) bounded
