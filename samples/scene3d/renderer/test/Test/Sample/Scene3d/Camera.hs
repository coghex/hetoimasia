-- | The cameras built with @hetoimasia-math@ against the oracle that does not
-- use them: a point the oracle's ray strikes projects, through the pose's
-- view and projection, onto that ray's pixel; clip-space Y points down, depth
-- runs 0 at the near plane to 1 at the far plane, and a nearer hit has the
-- smaller depth; a cube's model matrix yaws about +Y the way the oracle does;
-- and the push-constant block packs a matrix column by column.
module Test.Sample.Scene3d.Camera (spec) where

import qualified Data.ByteString as ByteString
import Data.Bits (shiftL, (.|.))
import Data.Maybe (fromJust)
import Data.Word (Word32, Word8)
import GHC.Float (castWord32ToFloat)
import Test.Hspec

import Hetoimasia.Math.Matrix (M44, apply, identity, toColumnMajor)
import Hetoimasia.Math.Transform (translation)
import Hetoimasia.Math.Vector (V3 (..), V4 (..))
import Hetoimasia.Sample.Scene3d.Camera
import Hetoimasia.Sample.Scene3d.Oracle
import Hetoimasia.Sample.Scene3d.Scene

spec ∷ Spec
spec = describe "Scene3d camera" $ do
  it "builds a view, a projection and a transform for every pose and cube the math package accepts" $ do
    [(viewMatrix pose /= Nothing, projectionMatrix pose /= Nothing) | pose ← poses] `shouldBe` replicate 2 (True, True)
    [transform pose cube /= Nothing | pose ← poses, cube ← cubes] `shouldBe` replicate 4 True
    [modelMatrix cube /= Nothing | cube ← cubes] `shouldBe` replicate 2 True

  it "projects every point the oracle's ray strikes onto the centre of that ray's pixel, with a depth between 0 and 1" $
    forM' sceneProbes $ \probe → do
      let pose = poseNamed (probePose probe)
          (x, y) = probePixel probe
      forM' (hitsAt pose (x, y)) $ \hit → do
        let (px, py, depth) = projected pose (hitPoint hit)
        px `shouldSatisfy` near (fromIntegral x + 0.5)
        py `shouldSatisfy` near (fromIntegral y + 0.5)
        depth `shouldSatisfy` (\d → d > 0 && d < 1)

  it "gives the nearer hit of an overlap the smaller depth, as a less-or-equal depth test keeps it" $
    forM' [probe | probe ← sceneProbes, probePurpose probe == Occlusion] $ \probe → do
      let pose = poseNamed (probePose probe)
      case hitsAt pose (probePixel probe) of
        [nearer, farther] → do
          let (_, _, nearDepth) = projected pose (hitPoint nearer)
              (_, _, farDepth) = projected pose (hitPoint farther)
          nearDepth `shouldSatisfy` (< farDepth)
        other → expectationFailure ("the overlap's hits were " <> show other)

  it "points clip-space Y down and runs depth from 0 at the near plane to 1 at the far plane" $
    forM' poses $ \pose → do
      Just view ← pure (viewMatrix pose)
      Just projection ← pure (projectionMatrix pose)
      let clipOf z yView = apply projection (V4 0 yView z 1)
          depthAt z = let V4 _ _ cz cw = clipOf z 0 in cz / cw
          V4 _ yUp _ wUp = clipOf (negate (realToFrac (poseNear pose) + 1)) 0.25
      (realToFrac (depthAt (negate (realToFrac (poseNear pose)))) ∷ Double) `shouldSatisfy` near 0
      (realToFrac (depthAt (negate (realToFrac (poseFar pose)))) ∷ Double) `shouldSatisfy` near 1
      -- A point above the view's centre line has negative clip-space Y.
      (yUp / wUp < 0) `shouldBe` True
      -- The target is on the view's −Z axis, at its distance from the eye.
      let (tx, ty, tz) = poseTarget pose
          V4 vx vy vz _ = apply view (V4 (realToFrac tx) (realToFrac ty) (realToFrac tz) 1)
      (realToFrac vx ∷ Double) `shouldSatisfy` near 0
      (realToFrac vy ∷ Double) `shouldSatisfy` near 0
      (vz < 0) `shouldBe` True

  it "yaws a cube about +Y as the oracle does: its local +X face centre lands at the centre plus (cos, 0, −sin) of the yaw" $
    forM' cubes $ \cube → do
      let V4 wx wy wz _ = apply (fromJust (modelMatrix cube)) (V4 1 0 0 1)
          (cx, cy, cz) = cubeCentre cube
          yaw = cubeYawDegrees cube * pi / 180
      (realToFrac wx ∷ Double) `shouldSatisfy` near (cx + cos yaw)
      (realToFrac wy ∷ Double) `shouldSatisfy` near cy
      (realToFrac wz ∷ Double) `shouldSatisfy` near (cz - sin yaw)

  it "puts each hit on the face the oracle names: the hit lies inside that face's quad, moved by the model matrix" $
    forM' sceneProbes $ \probe → do
      let pose = poseNamed (probePose probe)
      forM' (hitsAt pose (probePixel probe)) $ \hit → do
        let model = fromJust (modelMatrix (cubeNamed (hitCube hit)))
            faceIndex = fromEnum (hitFace hit)
            corners = [world model position | ((position, _), index) ← zip (cubeVertices (hitCube hit)) [0 ∷ Int ..], index `div` 4 == faceIndex]
        insideQuad corners (hitPoint hit) `shouldBe` True

  it "packs a matrix column by column as sixteen little-endian floats" $ do
    ByteString.length (packMatrix identity) `shouldBe` 64
    floats (packMatrix identity) `shouldBe` [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    -- A translation's offsets are the last column: elements 12 to 14.
    floats (packMatrix (translation (V3 1 2 3))) `shouldBe` [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 2, 3, 1]
    Just matrix ← pure (transform (poseNamed FrontPose) (cubeNamed NearCube))
    floats (packMatrix matrix) `shouldBe` toColumnMajor matrix
  where
    forM' items action = mapM_ action items
    near expected actual = abs (actual - expected) < (0.02 ∷ Double)
    floats bytes = [castWord32ToFloat (word32 (ByteString.unpack (ByteString.take 4 (ByteString.drop (4 * index) bytes)))) | index ← [0 .. ByteString.length bytes `div` 4 - 1]]

-- | A world point's pixel coordinates (of the target's upper-left corner) and
-- depth, through the pose's view and projection.
projected ∷ Pose → Vec → (Double, Double, Double)
projected pose (x, y, z) =
  let V4 cx cy cz cw = apply (fromJust (viewProjection pose)) (V4 (realToFrac x) (realToFrac y) (realToFrac z) 1)
      ndc value = realToFrac (value / cw) ∷ Double
   in ((ndc cx + 1) / 2 * fromIntegral targetWidth, (ndc cy + 1) / 2 * fromIntegral targetHeight, ndc cz)

-- | A cube's local position in the world, through the model matrix.
world ∷ M44 → (Double, Double, Double) → (Double, Double, Double)
world model (x, y, z) =
  let V4 wx wy wz _ = apply model (V4 (realToFrac x) (realToFrac y) (realToFrac z) 1)
   in (realToFrac wx, realToFrac wy, realToFrac wz)

-- | Whether a point lies in the plane of a quad's four corners and within
-- them, to the tolerance single-precision matrices allow.
insideQuad ∷ [(Double, Double, Double)] → (Double, Double, Double) → Bool
insideQuad corners point = case corners of
  [a, b, _, d] →
    let edgeU = sub b a
        edgeV = sub d a
        offset = sub point a
        normal = cross edgeU edgeV
        along edge = dot offset edge / dot edge edge
     in abs (dot offset normal / sqrt (dot normal normal)) < 1.0e-3 && along edgeU >= -1.0e-3 && along edgeU <= 1.001 && along edgeV >= -1.0e-3 && along edgeV <= 1.001
  _ → False
  where
    sub (a, b, c) (d, e, f) = (a - d, b - e, c - f)
    dot (a, b, c) (d, e, f) = a * d + b * e + c * f
    cross (a, b, c) (d, e, f) = (b * f - c * e, c * d - a * f, a * e - b * d)

word32 ∷ [Word8] → Word32
word32 = foldr (\byte acc → acc `shiftL` 8 .|. fromIntegral byte) 0
