-- | Tolerances and generators the math component specs share.
--
-- __Tolerance.__ Approximate comparisons accept @|a − b| ≤ 1e-4 · max 1 |a| |b|@
-- per component: absolute near zero, relative elsewhere. Every exact identity
-- (a transpose of a transpose, the identity matrix, known axis rotations by
-- exact values) is compared exactly instead.
--
-- __Generated domain.__ Ordinary generated components lie in @[−100, 100]@,
-- angles in @[−2π, 2π]@, and nonzero vectors have a length of at least @0.01@,
-- so single-precision rounding stays well inside the tolerance. The extreme
-- generator is the opposite: it exists to reach zeros, subnormals, the largest
-- finite values, infinities and NaN, and is used only where the contract is
-- that a checked result is 'Nothing' or finite.
module Test.Math.Support
  ( -- * Tolerance
    approx
  , approxV3
  , approxV4
  , approxM44
  , shouldApproximate

    -- * Finiteness
  , finiteV4
  , finiteM44

    -- * Generators
  , component
  , vector3
  , vector4
  , nonZeroVector3
  , angle
  , matrix
  , extreme
  , extremeVector3
  ) where

import Control.Monad (unless)
import GHC.Stack (HasCallStack)
import Hetoimasia.Math.Matrix (M44, fromColumns, toColumnMajor)
import Hetoimasia.Math.Vector (V3 (..), V4 (..), norm)
import Test.Hspec (Expectation, expectationFailure)
import Test.QuickCheck (Gen, arbitrary, choose, elements, frequency, suchThat)

-- | Equal within the suite's tolerance.
approx ∷ Float → Float → Bool
approx a b = abs (a - b) <= 1e-4 * maximum [1, abs a, abs b]

-- | Every component 'approx'.
approxV3 ∷ V3 → V3 → Bool
approxV3 (V3 a b c) (V3 x y z) = and (zipWith approx [a, b, c] [x, y, z])

-- | Every component 'approx'.
approxV4 ∷ V4 → V4 → Bool
approxV4 (V4 a b c d) (V4 x y z w) = and (zipWith approx [a, b, c, d] [x, y, z, w])

-- | Every element 'approx'.
approxM44 ∷ M44 → M44 → Bool
approxM44 a b = and (zipWith approx (toColumnMajor a) (toColumnMajor b))

-- | An expectation that two values agree under a comparison such as 'approxV4'.
shouldApproximate ∷ (HasCallStack, Show a) ⇒ (a → a → Bool) → a → a → Expectation
shouldApproximate same actual expected =
  unless (same actual expected) $
    expectationFailure ("expected approximately " <> show expected <> ", got " <> show actual)

-- | No component is NaN or infinite.
finiteV4 ∷ V4 → Bool
finiteV4 (V4 x y z w) = all finite [x, y, z, w]

-- | No element is NaN or infinite.
finiteM44 ∷ M44 → Bool
finiteM44 = all finite . toColumnMajor

finite ∷ Float → Bool
finite x = not (isNaN x || isInfinite x)

-- | A component in the ordinary domain.
component ∷ Gen Float
component = choose (-100, 100)

-- | A vector in the ordinary domain.
vector3 ∷ Gen V3
vector3 = V3 <$> component <*> component <*> component

-- | A vector in the ordinary domain.
vector4 ∷ Gen V4
vector4 = V4 <$> component <*> component <*> component <*> component

-- | A vector in the ordinary domain at least @0.01@ long.
nonZeroVector3 ∷ Gen V3
nonZeroVector3 = vector3 `suchThat` \v → norm v >= 0.01

-- | An angle in radians within two turns of zero.
angle ∷ Gen Float
angle = choose (-2 * pi, 2 * pi)

-- | A matrix with elements in the ordinary domain.
matrix ∷ Gen M44
matrix = fromColumns <$> vector4 <*> vector4 <*> vector4 <*> vector4

-- | A value biased toward the edges of @Float@: signed zeros, the smallest
-- subnormal and normal magnitudes, the largest finite magnitudes, infinities,
-- NaN, and arbitrary values between.
extreme ∷ Gen Float
extreme =
  frequency
    [ (3, arbitrary)
    , (1, choose (-100, 100))
    , ( 4
      , elements
          [ 0
          , -0
          , 1
          , -1
          , 1.0e-45
          , -1.0e-45
          , 1.1754944e-38
          , 1.0e38
          , -1.0e38
          , 3.4028235e38
          , -3.4028235e38
          , 1 / 0
          , -1 / 0
          , 0 / 0
          , pi
          ]
      )
    ]

-- | A vector of 'extreme' components.
extremeVector3 ∷ Gen V3
extremeVector3 = V3 <$> extreme <*> extreme <*> extreme
