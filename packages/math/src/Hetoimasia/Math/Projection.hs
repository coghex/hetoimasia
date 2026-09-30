-- | A look-at view matrix and a perspective projection, with every convention
-- an explicit parameter or a documented rule.
--
-- __View space.__ World and view space are right-handed. The view matrix puts
-- the eye at the origin looking down −Z, with +Y up and +X to the right.
--
-- __Clip space.__ 'perspective' maps view space to homogeneous clip space; a
-- consumer divides by @w@ to reach normalized device coordinates. Which depth
-- range the near and far planes reach, and whether the top of the view is at
-- +Y or −Y, are the caller's 'DepthRange' and 'ClipY': this module chooses no
-- graphics API's convention.
--
-- __Checked operations.__ 'lookAt' and 'perspective' return 'Nothing' for the
-- degenerate inputs each lists, for a NaN or infinite input, and when the
-- calculated matrix would contain NaN or an infinity. A 'Just' result is
-- finite.
--
-- __Dependencies.__ @base@, "Hetoimasia.Math.Vector",
-- "Hetoimasia.Math.Matrix" and this package's hidden finiteness test.
--
-- __State.__ The module owns none.
module Hetoimasia.Math.Projection
  ( -- * View
    lookAt
  , parallelTolerance

    -- * Perspective projection
  , DepthRange (..)
  , ClipY (..)
  , Frustum (..)
  , perspective
  ) where

import Hetoimasia.Math.Internal.Finite (allFinite)
import Hetoimasia.Math.Matrix (M44, fromRows, toColumnMajor)
import Hetoimasia.Math.Vector (V3 (..), V4 (..), cross, dot, norm, normalize, sub)

-- | The view matrix of an eye at @eye@ looking toward @target@, with @up@
-- choosing which way is up: @lookAt eye target up@.
--
-- The eye maps to the origin and the target onto −Z, at its distance from the
-- eye. @up@ need not be perpendicular to the view direction, nor unit length;
-- the view's +Y is the component of @up@ perpendicular to that direction.
--
-- 'Nothing' when the target is the eye, when @up@ is zero-length, when @up@ is
-- parallel to the view direction (either way along it), or when an input or the
-- result is not finite. Parallel means the sine of the angle between them is
-- below 'parallelTolerance'.
lookAt ∷ V3 → V3 → V3 → Maybe M44
lookAt eye target up = do
  forward ← normalize (target `sub` eye)
  upward ← normalize up
  let side = forward `cross` upward
  if norm side < parallelTolerance
    then Nothing
    else do
      V3 sx sy sz ← normalize side
      let V3 ux uy uz = V3 sx sy sz `cross` forward
          V3 fx fy fz = forward
          matrix =
            fromRows
              (V4 sx sy sz (negate (V3 sx sy sz `dot` eye)))
              (V4 ux uy uz (negate (V3 ux uy uz `dot` eye)))
              (V4 (negate fx) (negate fy) (negate fz) (forward `dot` eye))
              (V4 0 0 0 1)
      checked matrix

-- | The sine of the smallest angle between a look-at's view direction and its
-- up vector: @1e-5@, about two thousandths of a degree. Closer than this and
-- the two count as parallel, since rounding in the unit vectors alone reaches
-- a few times @1e-7@ and the side axis they span is no longer meaningful.
parallelTolerance ∷ Float
parallelTolerance = 1e-5

-- | The normalized-device depth the near and far planes reach.
data DepthRange
  = -- | The near plane at depth 0 and the far plane at depth 1.
    ZeroToOne
  | -- | The near plane at depth −1 and the far plane at depth 1.
    NegativeOneToOne
  deriving stock (Eq, Show, Enum, Bounded)

-- | The clip-space direction of the top of the view.
data ClipY
  = -- | The top of the view at +Y.
    YUp
  | -- | The top of the view at −Y.
    YDown
  deriving stock (Eq, Show, Enum, Bounded)

-- | A symmetric view frustum.
data Frustum = Frustum
  { fieldOfViewY ∷ !Float
  -- ^ The vertical field of view, top to bottom, in radians.
  , aspectRatio ∷ !Float
  -- ^ Width over height.
  , nearPlane ∷ !Float
  -- ^ The distance from the eye to the near plane.
  , farPlane ∷ !Float
  -- ^ The distance from the eye to the far plane.
  }
  deriving stock (Eq, Show)

-- | The perspective projection of a frustum, under the given depth range and
-- clip-space Y direction.
--
-- After division by @w@, a point on the near plane reaches the depth range's
-- near end and one on the far plane its far end; the top edge of the view
-- reaches Y = 1 under 'YUp' and Y = −1 under 'YDown', and the right edge
-- reaches X = 1. Clip-space @w@ is the point's distance in front of the eye,
-- @−z@ in view space.
--
-- 'Nothing' unless @0 < fieldOfViewY < π@, @aspectRatio > 0@ and
-- @0 < nearPlane < farPlane@, every field is finite, and the calculated matrix
-- is finite.
perspective ∷ DepthRange → ClipY → Frustum → Maybe M44
perspective range clipY (Frustum fov aspect near far)
  | not (allFinite [fov, aspect, near, far]) = Nothing
  | not (0 < fov && fov < pi) = Nothing
  | not (aspect > 0) = Nothing
  | not (0 < near && near < far) = Nothing
  | otherwise =
      checked $
        fromRows
          (V4 (focal / aspect) 0 0 0)
          (V4 0 (direction * focal) 0 0)
          (V4 0 0 depthScale depthOffset)
          (V4 0 0 (-1) 0)
  where
    focal = 1 / tan (fov / 2)
    direction = case clipY of
      YUp → 1
      YDown → -1
    -- No intermediate here overflows unless the coefficient it feeds does. The
    -- offsets multiply by the ratio rather than forming @near * far@, which
    -- would underflow or overflow for extreme but representable planes, and
    -- the symmetric range's scale divides each plane separately rather than
    -- forming @far + near@. Since @|ratio| > 1@, @2 * near@ overflows only
    -- when the offset itself cannot be represented.
    ratio = far / (near - far)
    (depthScale, depthOffset) = case range of
      ZeroToOne → (ratio, near * ratio)
      NegativeOneToOne → (ratio + near / (near - far), 2 * near * ratio)

-- | The matrix, when every element is finite.
checked ∷ M44 → Maybe M44
checked matrix
  | allFinite (toColumnMajor matrix) = Just matrix
  | otherwise = Nothing
