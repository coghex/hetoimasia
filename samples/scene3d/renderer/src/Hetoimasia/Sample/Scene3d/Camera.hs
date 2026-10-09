-- | The scene3d sample's cameras and model transforms (GRS-10), built with
-- @hetoimasia-math@ from the plain data of "Hetoimasia.Sample.Scene3d.Scene":
-- a look-at view, a perspective projection whose depth runs 0 to 1 and whose
-- clip-space Y points down (D-36), and each cube's model matrix, a yaw about
-- the world's Y axis then a translation to its centre.
--
-- The math package promises no byte layout (its README), so the renderer
-- packs the matrix it pushes itself, in 'packMatrix': sixteen little-endian
-- 32-bit floats, column by column, which is how a GLSL @mat4@ in a
-- push-constant block is laid out.
--
-- Every function is 'Nothing' where the math package's checked operations are:
-- for a degenerate or non-finite pose.
module Hetoimasia.Sample.Scene3d.Camera
  ( viewMatrix
  , projectionMatrix
  , modelMatrix
  , transform
  , viewProjection
  , packMatrix
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import GHC.Float (castFloatToWord32, double2Float)

import Hetoimasia.Math.Matrix (M44, multiply, toColumnMajor)
import Hetoimasia.Math.Projection (ClipY (YDown), DepthRange (ZeroToOne), Frustum (..), lookAt, perspective)
import Hetoimasia.Math.Transform (rotation, translation)
import Hetoimasia.Math.Vector (V3 (..))

import Hetoimasia.Sample.Scene3d.Scene (Cube (..), Pose (..), Vec, targetHeight, targetWidth)

-- | The pose's look-at view: the eye at the origin, looking down −Z.
viewMatrix ∷ Pose → Maybe M44
viewMatrix pose = lookAt (vector (poseEye pose)) (vector (poseTarget pose)) (vector (poseUp pose))

-- | The pose's perspective projection: the target's aspect ratio, depth 0 at
-- the near plane to 1 at the far plane, and the top of the view at clip-space
-- Y = −1.
projectionMatrix ∷ Pose → Maybe M44
projectionMatrix pose =
  perspective
    ZeroToOne
    YDown
    Frustum
      { fieldOfViewY = double2Float (poseFovDegrees pose * pi / 180)
      , aspectRatio = fromIntegral targetWidth / fromIntegral targetHeight
      , nearPlane = double2Float (poseNear pose)
      , farPlane = double2Float (poseFar pose)
      }

-- | A cube's model matrix: yawed about the world's Y axis, then moved to its
-- centre.
modelMatrix ∷ Cube → Maybe M44
modelMatrix cube = multiply (translation (vector (cubeCentre cube))) <$> rotation (V3 0 1 0) (double2Float (cubeYawDegrees cube * pi / 180))

-- | The projection after the view: world space to homogeneous clip space.
viewProjection ∷ Pose → Maybe M44
viewProjection pose = multiply <$> projectionMatrix pose <*> viewMatrix pose

-- | The matrix the vertex shader multiplies a cube's vertices by: model, then
-- view, then projection.
transform ∷ Pose → Cube → Maybe M44
transform pose cube = multiply <$> viewProjection pose <*> modelMatrix cube

-- | A matrix as a push-constant block holds a @mat4@: its sixteen elements,
-- column by column, as little-endian 32-bit floats.
packMatrix ∷ M44 → ByteString
packMatrix = Lazy.toStrict . Builder.toLazyByteString . foldMap (Builder.word32LE . castFloatToWord32) . toColumnMajor

vector ∷ Vec → V3
vector (x, y, z) = V3 (double2Float x) (double2Float y) (double2Float z)
