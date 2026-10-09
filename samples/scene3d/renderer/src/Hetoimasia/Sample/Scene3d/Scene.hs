-- | The scene3d sample's fixed scene (GRS-10): two flat-coloured cubes, one in
-- front of the other, seen from two camera poses, and the probe points whose
-- expected values "Hetoimasia.Sample.Scene3d.Oracle" computes.
--
-- Everything here is plain data in world units, in @Double@, and depends on
-- @base@ and @bytestring@ alone: the camera matrices the renderer draws with
-- are built from it in "Hetoimasia.Sample.Scene3d.Camera" with
-- @hetoimasia-math@, and the oracle reads it directly, so neither can agree
-- with the other by sharing a mistake.
--
-- = Coordinates
--
-- World space is right-handed with +Y up, as the math package's. The target is
-- 256×192 pixels, @(0, 0)@ at its upper-left corner, @x@ rightwards and @y@
-- downwards; a pixel's centre is at @(x + 0.5, y + 0.5)@. The projection's
-- clip-space Y points down and its depth runs 0 to 1 (D-36).
--
-- = The cubes
--
-- Both are cubes of half-extent 1, each yawed about the world's Y axis. The
-- 'NearCube' is nearer both cameras than the 'FarCube', and is drawn first:
-- with depth testing disabled, the farther cube drawn second would overwrite
-- it wherever they overlap, so an overlap that shows the nearer cube's colour
-- proves occlusion by depth rather than by order. Each face of each cube has
-- one flat colour, no lighting, and the near cube's colours are warm and the
-- far cube's cool, so a pixel's colour names the cube and the face.
module Hetoimasia.Sample.Scene3d.Scene
  ( -- * The target
    targetWidth
  , targetHeight
  , targetBytes
  , clearColour
    -- * Colours
  , Rgba (..)
    -- * Cubes
  , CubeName (..)
  , Face (..)
  , Cube (..)
  , cubes
  , cubeNamed
  , drawOrder
  , faceColour
    -- * Cameras
  , Vec
  , Pose (..)
  , PoseName (..)
  , poses
  , poseNamed
    -- * Geometry
  , vertexStride
  , cubeVertices
  , cubeVertexBytes
  , cubeIndices
  , indexCount
    -- * Probes
  , Probe (..)
  , ProbePurpose (..)
  , sceneProbes
  ) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.Text (Text)
import Data.Word (Word16, Word8)
import GHC.Float (castFloatToWord32, double2Float)
import Numeric.Natural (Natural)

-- | The evidence target's width and height, in pixels.
targetWidth, targetHeight ∷ Int
targetWidth = 256
targetHeight = 192

-- | The evidence target's bytes, four a pixel.
targetBytes ∷ Natural
targetBytes = fromIntegral (targetWidth * targetHeight * 4)

-- | An 8-bit colour, as the target's linear RGBA8 texels hold it.
data Rgba = Rgba !Word8 !Word8 !Word8 !Word8
  deriving (Eq, Show)

-- | What the target is cleared to, and what shows outside both cubes. It is a
-- multiple of 1/255 in each channel, so the device's conversion to 8 bits is
-- exact.
clearColour ∷ Rgba
clearColour = Rgba 32 48 64 255

data CubeName = NearCube | FarCube
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A cube's faces, named by the world axis their outward normal lies along
-- before the cube is yawed.
data Face = PosX | NegX | PosY | NegY | PosZ | NegZ
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A point or direction in world units.
type Vec = (Double, Double, Double)

-- | A cube of this half-extent centred here, yawed by this many degrees about
-- the world's Y axis (a positive angle turns +X toward −Z, by the right-hand
-- rule).
data Cube = Cube
  { cubeName ∷ !CubeName
  , cubeCentre ∷ !Vec
  , cubeYawDegrees ∷ !Double
  , cubeHalfExtent ∷ !Double
  }
  deriving (Eq, Show)

cubes ∷ [Cube]
cubes =
  [ Cube NearCube (0.7, 0, 1.2) 25 1
  , Cube FarCube (-0.9, 0.3, -1.4) (-18) 1
  ]

cubeNamed ∷ CubeName → Cube
cubeNamed name = case [cube | cube ← cubes, cubeName cube == name] of
  cube : _ → cube
  [] → error "every cube is in the scene"

-- | The order the cubes are drawn in: the nearer first, so that without
-- depth testing the farther one, drawn last, would show wherever they overlap.
drawOrder ∷ [CubeName]
drawOrder = [NearCube, FarCube]

-- | A face's flat colour.
faceColour ∷ CubeName → Face → Rgba
faceColour NearCube = \case
  PosX → opaque 230 57 70
  NegX → opaque 244 127 40
  PosY → opaque 255 214 10
  NegY → opaque 200 100 0
  PosZ → opaque 255 100 120
  NegZ → opaque 150 30 30
faceColour FarCube = \case
  PosX → opaque 38 70 200
  NegX → opaque 20 140 160
  PosY → opaque 60 200 120
  NegY → opaque 40 100 60
  PosZ → opaque 100 150 255
  NegZ → opaque 80 40 160

-- | A fully opaque colour.
opaque ∷ Word8 → Word8 → Word8 → Rgba
opaque r g b = Rgba r g b 255

data PoseName = FrontPose | SidePose
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A camera: where it is, what it looks at, which way is up, its vertical
-- field of view in degrees, and its near and far planes.
data Pose = Pose
  { poseName ∷ !PoseName
  , poseEye ∷ !Vec
  , poseTarget ∷ !Vec
  , poseUp ∷ !Vec
  , poseFovDegrees ∷ !Double
  , poseNear ∷ !Double
  , poseFar ∷ !Double
  }
  deriving (Eq, Show)

poses ∷ [Pose]
poses =
  [ Pose FrontPose (0.2, 2.4, 6.2) (0, 0.2, 0) (0, 1, 0) 45 0.5 50
  , Pose SidePose (4.6, 2.8, 4.2) (0, 0, 0) (0, 1, 0) 45 0.5 50
  ]

poseNamed ∷ PoseName → Pose
poseNamed name = case [pose | pose ← poses, poseName pose == name] of
  pose : _ → pose
  [] → error "every pose is in the scene"

-- ---------------------------------------------------------------------------
-- Geometry

-- | A vertex is three little-endian 32-bit floats, a position in the cube's
-- own space, then four bytes of colour, read normalized: 16 bytes.
vertexStride ∷ Int
vertexStride = 16

-- | Every cube is 24 vertices, four to a face, and 36 indices, two triangles
-- to a face.
indexCount ∷ Int
indexCount = 36

-- | A cube's vertices, face by face in 'Face' order.
cubeVertices ∷ CubeName → [((Double, Double, Double), Rgba)]
cubeVertices name =
  [ (corner, faceColour name face)
  | face ← [minBound .. maxBound]
  , corner ← faceCorners (cubeHalfExtent (cubeNamed name)) face
  ]

-- | A face's four corners, in a winding that is the same for every face
-- seen from outside; the pipeline culls nothing, so it only has to be
-- consistent.
faceCorners ∷ Double → Face → [(Double, Double, Double)]
faceCorners half face = [place u v | (u, v) ← [(-half, -half), (half, -half), (half, half), (-half, half)]]
  where
    (axis, sign) = case face of
      PosX → (0 ∷ Int, 1)
      NegX → (0, -1)
      PosY → (1, 1)
      NegY → (1, -1)
      PosZ → (2, 1)
      NegZ → (2, -1)
    place u v = case axis of
      0 → (sign * half, u, v)
      1 → (v, sign * half, u)
      _ → (u, v, sign * half)

-- | A cube's vertex bytes.
cubeVertexBytes ∷ CubeName → ByteString
cubeVertexBytes name =
  Lazy.toStrict . Builder.toLazyByteString . mconcat $
    [ float x <> float y <> float z <> Builder.word8 r <> Builder.word8 g <> Builder.word8 b <> Builder.word8 a
    | ((x, y, z), Rgba r g b a) ← cubeVertices name
    ]
  where
    float = Builder.word32LE . castFloatToWord32 . double2Float

-- | The indices of any cube, as 16-bit little-endian integers: each face's
-- four vertices as two triangles.
cubeIndices ∷ ByteString
cubeIndices =
  Lazy.toStrict . Builder.toLazyByteString . mconcat . map Builder.word16LE $
    concat [[base, base + 1, base + 2, base, base + 2, base + 3] | face ← [0 .. 5 ∷ Word16], let base = face * 4]

-- ---------------------------------------------------------------------------
-- Probes

-- | What a probe proves.
data ProbePurpose
  = FaceColour
    -- ^ A face visible from the pose, away from its edges, reads its flat
    -- colour.
  | Occlusion
    -- ^ A pixel both cubes cover, where the nearer cube — drawn first —
    -- reads its own colour: depth testing, not draw order, decided it.
  | CameraMovedFace
    -- ^ A face the other pose cannot see at all.
  | CameraMovedPlace
    -- ^ A face both poses see, at different pixels, or one pixel the two
    -- poses read differently.
  | Clear
    -- ^ A pixel neither cube covers reads the clear colour.
  deriving (Eq, Ord, Show, Enum, Bounded)

data Probe = Probe
  { probeName ∷ !Text
  , probePose ∷ !PoseName
  , probePixel ∷ !(Int, Int)
  , probePurpose ∷ !ProbePurpose
  }
  deriving (Eq, Show)

-- | The scene's probes, in the order the record lists them. Each is well
-- inside one face, or outside both cubes, as "Hetoimasia.Sample.Scene3d.Oracle"
-- checks, and its expected colour is that oracle's.
--
-- The two poses read the pixel @(146, 132)@ differently — the front pose
-- sees the near cube's +Z face there, the side pose its +X face — and each
-- pose has a face the other cannot see at all.
sceneProbes ∷ [Probe]
sceneProbes =
  [ Probe "front: near cube +Z face" FrontPose (175, 137) FaceColour
  , Probe "front: near cube +Y face" FrontPose (165, 83) FaceColour
  , Probe "front: far cube +Z face, moved from the side pose's pixels" FrontPose (83, 82) CameraMovedPlace
  , Probe "front: far cube +X face, moved from the side pose's pixels" FrontPose (129, 61) CameraMovedPlace
  , Probe "front: near cube -X face, hidden from the side pose" FrontPose (121, 140) CameraMovedFace
  , Probe "front: pixel (146, 132) shows the near cube's +Z face" FrontPose (146, 132) CameraMovedPlace
  , Probe "front: near cube -X face over the far cube" FrontPose (115, 104) Occlusion
  , Probe "front: near cube +Y face over the far cube" FrontPose (129, 82) Occlusion
  , Probe "front: clear, upper left" FrontPose (8, 8) Clear
  , Probe "front: clear, right" FrontPose (240, 60) Clear
  , Probe "front: clear, lower left" FrontPose (40, 176) Clear
  , Probe "side: near cube +Z face" SidePose (92, 136) FaceColour
  , Probe "side: near cube +Y face" SidePose (87, 82) FaceColour
  , Probe "side: far cube +X face, moved from the front pose's pixels" SidePose (159, 64) CameraMovedPlace
  , Probe "side: far cube +Y face" SidePose (139, 41) FaceColour
  , Probe "side: far cube +Z face, moved from the front pose's pixels" SidePose (113, 54) CameraMovedPlace
  , Probe "side: near cube +X face, hidden from the front pose" SidePose (144, 150) CameraMovedFace
  , Probe "side: pixel (146, 132) shows the near cube's +X face" SidePose (146, 132) CameraMovedPlace
  , Probe "side: near cube +X face over the far cube" SidePose (151, 98) Occlusion
  , Probe "side: near cube +Y face over the far cube" SidePose (125, 83) Occlusion
  , Probe "side: clear, upper left" SidePose (8, 8) Clear
  , Probe "side: clear, right" SidePose (240, 60) Clear
  , Probe "side: clear, lower left" SidePose (40, 176) Clear
  ]
