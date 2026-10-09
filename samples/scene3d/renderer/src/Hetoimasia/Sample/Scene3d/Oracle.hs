-- | The scene3d scene's independent oracle (GRS-10): every probe's expected
-- value, found by casting a ray through the probe's pixel centre into the
-- scene of "Hetoimasia.Sample.Scene3d.Scene" — never from an observed image,
-- and without the math package's @lookAt@ or @perspective@, so a mistake in
-- the camera matrices the renderer draws with is not one the oracle shares.
--
-- A pose's ray through pixel @(x, y)@ starts at the eye. With @f@ the unit
-- vector toward the target, @r@ the unit @f × up@ and @u@ the unit @r × f@,
-- and @t@ the tangent of half the vertical field of view, it points along
--
-- > f + sx · r + sy · u,   sx = (2 (x + ½) / width − 1) · aspect · t,
-- >                        sy = (1 − 2 (y + ½) / height) · t
--
-- — the top row of the target is the top of the view, which clip-space Y
-- pointing down puts at the first row. Each cube is struck, if at all, where
-- the ray enters its box, in the cube's own yawed space; the nearer entry
-- along the ray is what a depth test keeps. A pixel's expected colour is that
-- face's flat colour, or the clear colour where the ray misses both cubes.
--
-- A probe is only a probe when it is well inside a face: 'interior' holds a
-- pixel to the same face on every pixel within a margin, so the rasterizer's
-- edge rules and the last bit of a projection can never decide it. Every
-- probe's expected colour is exact.
module Hetoimasia.Sample.Scene3d.Oracle
  ( -- * Rays and hits
    Hit (..)
  , hitsAt
  , nearestHit
  , expectedColour
  , withoutDepthTest
  , interior
  , interiorMargin
    -- * Probes
  , ProbeResult (..)
  , evaluateProbes
  , probesPassed
  , pixelAt
  , Vec3
  ) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.Maybe (listToMaybe)

import Hetoimasia.Sample.Scene3d.Scene

-- | A point or direction.
type Vec3 = Vec

-- | Where a ray first strikes a cube: which cube and face, how far along the
-- ray's unit direction, and the world point.
data Hit = Hit
  { hitCube ∷ !CubeName
  , hitFace ∷ !Face
  , hitDistance ∷ !Double
  , hitPoint ∷ !Vec3
  }
  deriving (Eq, Show)

-- | How many pixels around a probe, in each direction, must strike the same
-- face of the same cube, or miss both cubes alike.
interiorMargin ∷ Int
interiorMargin = 3

-- | The pose's ray through a pixel's centre: its origin and unit direction.
rayFor ∷ Pose → (Int, Int) → (Vec3, Vec3)
rayFor pose (x, y) = (poseEye pose, unit (add forward (add (scale sx right) (scale sy upward))))
  where
    forward = unit (sub (poseTarget pose) (poseEye pose))
    right = unit (cross forward (poseUp pose))
    upward = unit (cross right forward)
    tangent = tan (poseFovDegrees pose * pi / 360)
    aspect = fromIntegral targetWidth / fromIntegral targetHeight
    sx = (2 * (fromIntegral x + 0.5) / fromIntegral targetWidth - 1) * aspect * tangent
    sy = (1 - 2 * (fromIntegral y + 0.5) / fromIntegral targetHeight) * tangent

-- | The cubes a pixel's ray strikes, nearest first.
hitsAt ∷ Pose → (Int, Int) → [Hit]
hitsAt pose pixel = sortOn hitDistance [hit | cube ← cubes, Just hit ← [strike cube origin direction]]
  where
    (origin, direction) = rayFor pose pixel

-- | The hit a depth test keeps.
nearestHit ∷ Pose → (Int, Int) → Maybe Hit
nearestHit pose = listToMaybe . hitsAt pose

-- | What the pixel must read: the nearest hit's face colour, or the clear
-- colour.
expectedColour ∷ Pose → (Int, Int) → Rgba
expectedColour pose pixel = maybe clearColour (\hit → faceColour (hitCube hit) (hitFace hit)) (nearestHit pose pixel)

-- | The cube a pixel would show with depth testing disabled: the last of the
-- draw order that covers it.
withoutDepthTest ∷ Pose → (Int, Int) → Maybe CubeName
withoutDepthTest pose pixel = listToMaybe (reverse [name | name ← drawOrder, name `elem` map hitCube (hitsAt pose pixel)])

-- | Whether every pixel within 'interiorMargin' of this one, all inside the
-- target, strikes the same face of the same cube as it does — or misses both
-- cubes as it does.
interior ∷ Pose → (Int, Int) → Bool
interior pose (x, y) = all inside neighbours && all (== signature (x, y)) (map signature neighbours)
  where
    neighbours = [(x + dx, y + dy) | dx ← [-interiorMargin .. interiorMargin], dy ← [-interiorMargin .. interiorMargin]]
    inside (px, py) = px >= 0 && py >= 0 && px < targetWidth && py < targetHeight
    signature pixel = fmap (\hit → (hitCube hit, hitFace hit)) (nearestHit pose pixel)

-- | The entry of a ray into a cube, if it has one in front of the origin.
strike ∷ Cube → Vec3 → Vec3 → Maybe Hit
strike cube origin direction
  | tNear <= tFar && tFar > 0 && tNear > 0 = Just (Hit (cubeName cube) face tNear world)
  | otherwise = Nothing
  where
    half = cubeHalfExtent cube
    local o = yawBy (negate (cubeYawDegrees cube)) (sub o (cubeCentre cube))
    (ox, oy, oz) = local origin
    (dx, dy, dz) = yawBy (negate (cubeYawDegrees cube)) direction
    slabs = [slab half ox dx, slab half oy dy, slab half oz dz]
    (tNear, axis) = maximum [(near, index) | ((near, _), index) ← zip slabs [0 ∷ Int ..]]
    tFar = minimum [far | (_, far) ← slabs]
    entering = [dx, dy, dz] !! axis
    face = case (axis, entering > 0) of
      (0, True) → NegX
      (0, False) → PosX
      (1, True) → NegY
      (1, False) → PosY
      (_, True) → NegZ
      (_, False) → PosZ
    world = add (cubeCentre cube) (yawBy (cubeYawDegrees cube) (add (ox, oy, oz) (scale tNear (dx, dy, dz))))

-- | The interval along a ray where its coordinate on one axis is within the
-- slab @[-half, half]@: unbounded if the ray runs along the slab inside it,
-- empty if outside.
slab ∷ Double → Double → Double → (Double, Double)
slab half origin direction
  | abs direction < 1.0e-12 = if abs origin <= half then (-1 / 0, 1 / 0) else (1 / 0, -1 / 0)
  | otherwise = let a = (-half - origin) / direction; b = (half - origin) / direction in (min a b, max a b)

-- | A vector turned about +Y by this many degrees, by the right-hand rule: a
-- positive angle turns +X toward −Z.
yawBy ∷ Double → Vec3 → Vec3
yawBy degrees (x, y, z) = (x * c + z * s, y, negate x * s + z * c)
  where
    radians = degrees * pi / 180
    c = cos radians
    s = sin radians

add, sub, cross ∷ Vec3 → Vec3 → Vec3
add (a, b, c) (d, e, f) = (a + d, b + e, c + f)
sub (a, b, c) (d, e, f) = (a - d, b - e, c - f)
cross (a, b, c) (d, e, f) = (b * f - c * e, c * d - a * f, a * e - b * d)

scale ∷ Double → Vec3 → Vec3
scale k (a, b, c) = (k * a, k * b, k * c)

unit ∷ Vec3 → Vec3
unit v@(a, b, c) = scale (1 / sqrt (a * a + b * b + c * c)) v

-- ---------------------------------------------------------------------------
-- Probes

-- | One probe's outcome.
data ProbeResult = ProbeResult
  { resultProbe ∷ !Probe
  , resultExpected ∷ !Rgba
  , resultObserved ∷ !Rgba
  , resultHit ∷ !(Maybe Hit)
    -- ^ The face the oracle's ray strikes first, if any.
  , resultCovered ∷ ![CubeName]
    -- ^ The cubes the ray strikes, in the order they are drawn.
  , resultPainter ∷ !(Maybe CubeName)
    -- ^ The cube the pixel would show with depth testing disabled: the last
    -- drawn of those the ray strikes.
  , resultPassed ∷ !Bool
  }
  deriving (Eq, Show)

-- | Every probe of the scene that belongs to this pose, against the pose's
-- readback of the target: exact, in every channel.
evaluateProbes ∷ PoseName → ByteString → [ProbeResult]
evaluateProbes name bytes =
  [ ProbeResult probe expected observed hit covered (withoutDepthTest pose pixel) (expected == observed)
  | probe ← sceneProbes
  , probePose probe == name
  , let pose = poseNamed name
        pixel = probePixel probe
        expected = expectedColour pose pixel
        observed = pixelAt bytes pixel
        hit = nearestHit pose pixel
        covered = [cube | cube ← drawOrder, cube `elem` map hitCube (hitsAt pose pixel)]
  ]

probesPassed ∷ [ProbeResult] → Bool
probesPassed results = not (null results) && all resultPassed results

-- | A pixel of a tightly packed RGBA8 readback of the target; transparent
-- black past its end, which no probe passes.
pixelAt ∷ ByteString → (Int, Int) → Rgba
pixelAt bytes (x, y) = case ByteString.unpack (ByteString.take 4 (ByteString.drop ((y * targetWidth + x) * 4) bytes)) of
  [r, g, b, a] → Rgba r g b a
  _ → Rgba 0 0 0 0
