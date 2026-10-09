-- | The scene's data and geometry: the target's size, the cubes' vertex and
-- index bytes as the shaders' interface declares them, the colours that make
-- a pixel name its cube and face, and the draw order that makes an overlap
-- prove depth testing.
module Test.Sample.Scene3d.Scene (spec) where

import qualified Data.ByteString as ByteString
import Data.Bits (shiftL, (.|.))
import Data.List (nub)
import Data.Word (Word16, Word32, Word8)
import GHC.Float (castWord32ToFloat)
import Test.Hspec

import Hetoimasia.GPU.Vulkan.Native.Recording (InputRate (..), VertexAttribute (..), VertexBinding (..), VertexFormat (..), VertexInput (..))
import Hetoimasia.GPU.Vulkan.Native.Shader.Interface (ShaderInterface (..), PushMember (..))
import Hetoimasia.Sample.Scene3d.ShaderInterfaces (scene3dVertexInterface, transformBytes)
import Hetoimasia.Sample.Scene3d.Scene

spec ∷ Spec
spec = describe "Scene3d scene" $ do
  it "is a 256 by 192 target of four bytes a pixel" $ do
    (targetWidth, targetHeight) `shouldBe` (256, 192)
    targetBytes `shouldBe` 256 * 192 * 4

  it "has two cubes, drawn nearer first, the nearer one nearer both cameras" $ do
    map cubeName cubes `shouldBe` [NearCube, FarCube]
    drawOrder `shouldBe` [NearCube, FarCube]
    [ distance (poseEye pose) (cubeCentre (cubeNamed NearCube)) < distance (poseEye pose) (cubeCentre (cubeNamed FarCube))
      | pose ← poses
      ]
      `shouldBe` [True, True]

  it "gives all twelve faces distinct opaque colours, none the clear colour, the nearer cube's warm and the farther's cool" $ do
    let colours = [faceColour name face | name ← [NearCube, FarCube], face ← [minBound .. maxBound]]
    length (nub colours) `shouldBe` 12
    colours `shouldSatisfy` notElem clearColour
    [alpha | Rgba _ _ _ alpha ← colours] `shouldBe` replicate 12 255
    [red > blue | face ← [minBound .. maxBound], let Rgba red _ blue _ = faceColour NearCube face] `shouldBe` replicate 6 True
    [blue > red | face ← [minBound .. maxBound], let Rgba red _ blue _ = faceColour FarCube face] `shouldBe` replicate 6 True

  it "has 24 vertices of 16 bytes and 36 16-bit indices a cube, every triangle within one face" $ do
    map (ByteString.length . cubeVertexBytes) [NearCube, FarCube] `shouldBe` [24 * vertexStride, 24 * vertexStride]
    vertexStride `shouldBe` 16
    indexCount `shouldBe` 36
    let indices = words16 cubeIndices
    length indices `shouldBe` 36
    all (< 24) indices `shouldBe` True
    [ length (nub (map (`div` 4) triangle)) | triangle ← chunks 3 indices ] `shouldBe` replicate 12 1

  it "lays each vertex out as the shader interface declares it: a position of three floats on the cube's faces, then its face's colour in four bytes" $ do
    let bytes = cubeVertexBytes NearCube
        vertices = chunks vertexStride (ByteString.unpack bytes)
    length vertices `shouldBe` 24
    forM' (zip [0 ∷ Int ..] vertices) $ \(index, vertex) → do
      let position = [castWord32ToFloat (word32 (take 4 (drop (4 * axis) vertex))) | axis ← [0 .. 2]]
          Rgba r g b a = faceColour NearCube ([minBound .. maxBound] !! (index `div` 4))
      -- Every vertex is a corner of the cube of half-extent 1, and sits on its face's plane.
      map abs position `shouldBe` [1, 1, 1]
      drop 12 vertex `shouldBe` [r, g, b, a]
    -- Declared by the interface the shaders are checked against.
    interfaceVertexInput scene3dVertexInterface
      `shouldBe` VertexInput [VertexBinding 0 16 PerVertex] [VertexAttribute 0 0 VertexFloat3 0, VertexAttribute 1 0 VertexRgba8Unorm 12]
    interfacePushConstants scene3dVertexInterface `shouldBe` [PushMember 0 64]
    transformBytes `shouldBe` 64

  it "places each face's four vertices on its side of the cube" $ do
    let positions = [castWord32ToFloat (word32 (take 4 (drop (4 * axis) vertex))) | vertex ← chunks vertexStride (ByteString.unpack (cubeVertexBytes FarCube)), axis ← [0 .. 2]]
        byFace = chunks 12 positions
        perFace = [chunks 3 face | face ← chunks 12 positions]
    length byFace `shouldBe` 6
    -- Along its face's axis every corner of a face is at the same signed distance.
    [ nub [corner !! axis | corner ← corners]
      | (face, corners) ← zip [minBound .. maxBound ∷ Face] perFace
      , let axis = case face of PosX → 0; NegX → 0; PosY → 1; NegY → 1; PosZ → 2; NegZ → 2
      ]
      `shouldBe` [[1], [-1], [1], [-1], [1], [-1]]
  where
    distance (a, b, c) (d, e, f) = sqrt ((a - d) ^ (2 ∷ Int) + (b - e) ^ (2 ∷ Int) + (c - f) ^ (2 ∷ Int)) ∷ Double
    forM' items action = mapM_ action items

chunks ∷ Int → [a] → [[a]]
chunks _ [] = []
chunks size items = take size items : chunks size (drop size items)

word32 ∷ [Word8] → Word32
word32 bytes = foldr (\byte acc → acc `shiftL` 8 .|. fromIntegral byte) 0 bytes

words16 ∷ ByteString.ByteString → [Word16]
words16 bytes = [fromIntegral low .|. fromIntegral high `shiftL` 8 | [low, high] ← chunks 2 (ByteString.unpack bytes)]
