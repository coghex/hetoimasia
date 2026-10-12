-- | The recorder's pure layout decisions: the scissor rule against
-- 'viewportContains', the push block's bytes, the instance attributes against
-- render-2d's 64-byte encoding, the sampler-choice mapping, and the shaders'
-- checked interfaces against the same numbers.
--
-- __Where the expected values come from.__ Never from the code under test: the
-- scissors and push bytes are worked out by hand (each float as the
-- little-endian bytes of its IEEE 754 single-precision pattern, 2.0 being
-- @00 00 00 40@), the attribute fields are read from bytes render-2d's own
-- encoder wrote, and the scissor sweep asks render-2d's 'viewportContains'
-- about every pixel centre.
module Test.Render.TwoD.Vulkan.Layout (spec) where

import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as ByteString
import Data.Word (Word32, Word8)
import GHC.Float (castFloatToWord32)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( InputRate (..)
  , Rect (..)
  , TableSampler (..)
  , VertexAttribute (..)
  , VertexBinding (..)
  , VertexFormat (..)
  , VertexInput (..)
  , tableSamplerIndex
  , vertexFormatBytes
  )
import Hetoimasia.GPU.Vulkan.Native.Shader.Interface (CheckedShader (..), CheckedShaders (..), PushMember (..), ShaderInterface (..))
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Encoding (encodeLayer, flagsWord)
import Hetoimasia.Render.TwoD.Mapping (viewportContains)
import Hetoimasia.Render.TwoD.Settings (TextureFilter (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (ValidLayer, validLayers, validateSnapshot)
import Hetoimasia.Render.TwoD.Vulkan.Layout
import Hetoimasia.Render.TwoD.Vulkan.Shaders (orderedShaders)
import Test.Hspec (Spec, describe, it, shouldBe)

spec ∷ Spec
spec = describe "Layout" $ do
  scissorSpec
  pushSpec
  attributeSpec
  samplerSpec
  interfaceSpec

-- ---------------------------------------------------------------------------
-- The scissor

scissorSpec ∷ Spec
scissorSpec = describe "the scissor of a view" $ do
  let attachment = (32, 24)
      scissor x y w h = viewScissor (Viewport (V2 x y) (V2 w h)) attachment

  it "covers the whole attachment for a viewport that is the whole attachment" $
    scissor 0 0 32 24 `shouldBe` Just (Rect 0 0 32 24)

  it "covers exactly the pixels of a whole-pixel viewport" $
    scissor 8 4 16 8 `shouldBe` Just (Rect 8 4 16 8)

  it "takes the pixels whose centres lie inside, working out a fractional viewport by hand" $ do
    -- x in [2.25, 5.25): the centres 2.5, 3.5 and 4.5 are inside, 5.5 is not.
    -- y in [1.5, 3.5): 1.5 is inside (the left and top edges are in), 2.5 is,
    -- and 3.5 is not (the right and bottom edges are out).
    scissor 2.25 1.5 3 2 `shouldBe` Just (Rect 2 1 3 2)

  it "includes a centre on the left or top edge and excludes one on the right or bottom" $ do
    -- x in [0.5, 1.5): the centre 0.5 is in and 1.5 is out.
    scissor 0.5 0.5 1 1 `shouldBe` Just (Rect 0 0 1 1)
    scissor 0.5 0.5 2 2 `shouldBe` Just (Rect 0 0 2 2)

  it "is empty for a viewport containing no pixel centre, however large its overlap with a pixel" $ do
    -- x in [0.6, 1.4): the centres 0.5 and 1.5 are both outside.
    scissor 0.6 0.6 0.8 0.8 `shouldBe` Nothing
    scissor 0 0 0 24 `shouldBe` Nothing
    scissor 0 0 32 0 `shouldBe` Nothing

  it "clamps to the attachment" $ do
    scissor (-4) (-2) 8 6 `shouldBe` Just (Rect 0 0 4 4)
    scissor 30 20 10 10 `shouldBe` Just (Rect 30 20 2 4)
    scissor (-100) (-100) 1000 1000 `shouldBe` Just (Rect 0 0 32 24)

  it "is empty for a viewport wholly outside the attachment" $ do
    scissor 40 0 4 4 `shouldBe` Nothing
    scissor 0 30 4 4 `shouldBe` Nothing
    scissor (-9) 0 4 4 `shouldBe` Nothing

  it "is empty for a viewport with a component that is not finite" $ do
    scissor (0 / 0) 0 8 8 `shouldBe` Nothing
    scissor 0 0 (1 / 0) 8 `shouldBe` Nothing

  it "holds exactly the pixels whose centres viewportContains accepts, over a sweep of viewports" $ do
    let origins = [-1.75, -0.5, 0, 0.25, 0.5, 1.5, 2.75, 7.5, 31.5]
        extents = [0, 0.1, 0.5, 1, 1.5, 3.25, 24, 100]
        (width, height) = attachment
        agrees vp@(Viewport (V2 x y) (V2 w h)) =
          let inside i j = case viewScissor vp attachment of
                Nothing → False
                Just (Rect rx ry rw rh) →
                  fromIntegral i >= toInteger rx && toInteger i < toInteger rx + toInteger rw
                    && fromIntegral j >= toInteger ry && toInteger j < toInteger ry + toInteger rh
              centre i = fromIntegral (i ∷ Word32) + 0.5
           in [ (x, y, w, h, i, j)
              | i ← [0 .. width - 1]
              , j ← [0 .. height - 1]
              , inside i j /= viewportContains vp (V2 (centre i) (centre j))
              ]
    concat [agrees (Viewport (V2 x y) (V2 w h)) | x ← origins, y ← origins, w ← extents, h ← extents] `shouldBe` []

-- ---------------------------------------------------------------------------
-- The push block

pushSpec ∷ Spec
pushSpec = describe "the push block" $ do
  it "is 44 bytes in six members that tile it, each at its natural alignment" $ do
    pushBytes `shouldBe` 44
    [(offset, size) | PushMember offset size ← pushMembers]
      `shouldBe` [(0, 16), (16, 8), (24, 8), (32, 4), (36, 4), (40, 4)]
    -- Each member starts where the one before ends.
    and (zipWith (\(PushMember offset size) (PushMember next _) → offset + size == next) pushMembers (drop 1 pushMembers)) `shouldBe` True
    sum [size | PushMember _ size ← pushMembers] `shouldBe` fromIntegral pushBytes

  it "packs a transform, an extent, a brightness, a filter and a snap flag at their offsets" $ do
    let bytes =
          packViewPush
            ViewPush
              { pushTransform = fromColumns (V2 2 0) (V2 0 2) (V2 10 20)
              , pushExtent = (640, 480)
              , pushBrightness = 1.5
              , pushFilter = FilterLinear
              , pushSnap = True
              }
    ByteString.unpack bytes
      `shouldBe` concat
        [ [0x00, 0x00, 0x00, 0x40] -- 0: a = 2.0
        , [0x00, 0x00, 0x00, 0x00] -- 4: b = 0.0
        , [0x00, 0x00, 0x00, 0x00] -- 8: c = 0.0
        , [0x00, 0x00, 0x00, 0x40] -- 12: d = 2.0
        , [0x00, 0x00, 0x20, 0x41] -- 16: tx = 10.0
        , [0x00, 0x00, 0xA0, 0x41] -- 20: ty = 20.0
        , [0x00, 0x00, 0x20, 0x44] -- 24: extent x = 640.0
        , [0x00, 0x00, 0xF0, 0x43] -- 28: extent y = 480.0
        , [0x00, 0x00, 0xC0, 0x3F] -- 32: brightness = 1.5
        , [0x02, 0x00, 0x00, 0x00] -- 36: filter = linear (2)
        , [0x01, 0x00, 0x00, 0x00] -- 40: snap on
        ]

  it "packs nearest as 1 and snap off as 0, with the transform's off-diagonal and negative values" $ do
    let bytes =
          packViewPush
            ViewPush
              { pushTransform = fromColumns (V2 0 1) (V2 (-1) 0) (V2 0.5 (-0.25))
              , pushExtent = (1, 2)
              , pushBrightness = 0.5
              , pushFilter = FilterNearest
              , pushSnap = False
              }
    ByteString.unpack bytes
      `shouldBe` concat
        [ [0x00, 0x00, 0x00, 0x00] -- a = 0.0
        , [0x00, 0x00, 0x80, 0x3F] -- b = 1.0
        , [0x00, 0x00, 0x80, 0xBF] -- c = -1.0
        , [0x00, 0x00, 0x00, 0x00] -- d = 0.0
        , [0x00, 0x00, 0x00, 0x3F] -- tx = 0.5
        , [0x00, 0x00, 0x80, 0xBE] -- ty = -0.25
        , [0x00, 0x00, 0x80, 0x3F] -- extent x = 1.0
        , [0x00, 0x00, 0x00, 0x40] -- extent y = 2.0
        , [0x00, 0x00, 0x00, 0x3F] -- brightness = 0.5
        , [0x01, 0x00, 0x00, 0x00] -- filter = nearest (1)
        , [0x00, 0x00, 0x00, 0x00] -- snap off
        ]

  it "gives a filter the code an instance's sampler choice uses for it" $ do
    filterCode FilterNearest `shouldBe` 1
    filterCode FilterLinear `shouldBe` 2
    flagsWord distinctInstance {instanceSampler = SamplerNearest} .&. 3 `shouldBe` filterCode FilterNearest
    flagsWord distinctInstance {instanceSampler = SamplerLinear} .&. 3 `shouldBe` filterCode FilterLinear

-- ---------------------------------------------------------------------------
-- The attributes

attributeSpec ∷ Spec
attributeSpec = describe "the instance's vertex input" $ do
  it "is one binding advancing per instance at render-2d's 64-byte stride" $
    case instanceVertexInput of
      VertexInput bindings _ → bindings `shouldBe` [VertexBinding 0 64 PerInstance]

  it "reads every field of an encoded instance at the offset and format the attribute names" $ do
    let bytes = ByteString.unpack (encodeLayer (oneLayer distinctInstance))
        VertexInput _ attributes = instanceVertexInput
        read' attribute = take (fromIntegral (vertexFormatBytes (attributeFormat attribute))) (drop (fromIntegral (attributeOffset attribute)) bytes)
        floats = concatMap (littleEndian . castFloatToWord32)
    length bytes `shouldBe` 64
    [(attributeLocation attribute, attributeBinding attribute, attributeFormat attribute) | attribute ← attributes]
      `shouldBe` [ (0, 0, VertexFloat4)
                 , (1, 0, VertexFloat2)
                 , (2, 0, VertexFloat4)
                 , (3, 0, VertexUint)
                 , (4, 0, VertexUint)
                 , (5, 0, VertexRgba8Unorm)
                 , (6, 0, VertexUint)
                 , (7, 0, VertexUint)
                 ]
    map read' attributes
      `shouldBe` [ floats [2, 3, 5, 7] -- the transform's a, b, c, d
                 , floats [11, 13] -- tx, ty
                 , floats [0.25, 0.5, 0.75, 1.0] -- the UV rectangle
                 , littleEndian 0x01020304 -- the handle's lookup index
                 , littleEndian 0x0A0B0C0D -- its generation
                 , [0x11, 0x22, 0x33, 0x44] -- the tint, red first
                 , littleEndian (flagsWord distinctInstance) -- the flags word
                 , littleEndian 0xDEADBEEF -- the material parameter word
                 ]

  it "keeps every attribute inside the stride and aligned to its component size, with no two overlapping" $ do
    let VertexInput _ attributes = instanceVertexInput
        spans = [(toInteger (attributeOffset attribute), toInteger (attributeOffset attribute) + toInteger (vertexFormatBytes (attributeFormat attribute))) | attribute ← attributes]
    all ((<= 64) . snd) spans `shouldBe` True
    all (\attribute → attributeOffset attribute `mod` 4 == 0) attributes `shouldBe` True
    and [e1 <= s2 || e2 <= s1 | (i, (s1, e1)) ← zip [0 ∷ Int ..] spans, (j, (s2, e2)) ← zip [0 ..] spans, i < j] `shouldBe` True

-- ---------------------------------------------------------------------------
-- The sampler choice

samplerSpec ∷ Spec
samplerSpec = describe "the sampler an instance resolves to" $ do
  it "takes nearest for choice 1 and linear for choice 2 whatever the view's default is" $
    mapM_
      ( \defaultFilter → do
          shaderSamplerIndex (flagsWord distinctInstance {instanceSampler = SamplerNearest}) (filterCode defaultFilter) `shouldBe` tableSamplerIndex NearestClamp
          shaderSamplerIndex (flagsWord distinctInstance {instanceSampler = SamplerLinear}) (filterCode defaultFilter) `shouldBe` tableSamplerIndex LinearClamp
      )
      [FilterNearest, FilterLinear]

  it "takes the view's default for choice 0, under each default" $ do
    shaderSamplerIndex (flagsWord distinctInstance {instanceSampler = SamplerDefault}) (filterCode FilterNearest) `shouldBe` tableSamplerIndex NearestClamp
    shaderSamplerIndex (flagsWord distinctInstance {instanceSampler = SamplerDefault}) (filterCode FilterLinear) `shouldBe` tableSamplerIndex LinearClamp

  it "maps nearest to the table's sampler 0 and linear to its sampler 2, both clamping to the edge" $ do
    tableSamplerIndex NearestClamp `shouldBe` 0
    tableSamplerIndex LinearClamp `shouldBe` 2

  it "reads only the flags word's low two bits, whatever the other flags say" $
    mapM_
      ( \(translucent, additive, clip) → do
          let flags sampler = flagsWord distinctInstance {instanceSampler = sampler, instanceTranslucent = translucent, instanceAdditive = additive, instanceClip = clip}
          instanceSamplerBits (flags SamplerDefault) `shouldBe` 0
          instanceSamplerBits (flags SamplerNearest) `shouldBe` 1
          instanceSamplerBits (flags SamplerLinear) `shouldBe` 2
      )
      [(t, a, c) | t ← [False, True], a ← [False, True], c ← [0, 1, 0xFFFF]]

  it "takes the view's default for the unused choice 3, and never reaches a repeating sampler for any input" $ do
    shaderSamplerIndex 3 (filterCode FilterNearest) `shouldBe` tableSamplerIndex NearestClamp
    shaderSamplerIndex 3 (filterCode FilterLinear) `shouldBe` tableSamplerIndex LinearClamp
    and [shaderSamplerIndex flags code `elem` [0, 2] | flags ← [0 .. 255], code ← [1, 2]] `shouldBe` True

-- ---------------------------------------------------------------------------
-- The shaders' interfaces

interfaceSpec ∷ Spec
interfaceSpec = describe "the shaders' checked interfaces" $ do
  it "declare one push block of 44 bytes in both stages" $
    case (checkedVertex orderedShaders, checkedFragment orderedShaders) of
      (CheckedShader _ vertex, CheckedShader _ fragment) →
        [(offset, offset + size) | PushMember offset size ← interfacePushConstants vertex <> interfacePushConstants fragment]
          `shouldBe` concat (replicate 2 [(0, 16), (16, 24), (24, 32), (32, 36), (36, 40), (40, 44)])

  it "declare the instance attributes in the vertex stage" $
    case checkedVertex orderedShaders of
      CheckedShader _ description → interfaceVertexInput description `shouldBe` instanceVertexInput

  it "declare the same members in both stages" $
    case (checkedVertex orderedShaders, checkedFragment orderedShaders) of
      (CheckedShader _ vertex, CheckedShader _ fragment) → do
        interfacePushConstants vertex `shouldBe` interfacePushConstants fragment
        length (interfacePushConstants vertex) `shouldBe` 6

-- ---------------------------------------------------------------------------
-- Fixtures

-- | An instance whose every field has a different, recognisable value.
distinctInstance ∷ Instance
distinctInstance =
  Instance
    { instanceTransform = fromColumns (V2 2 3) (V2 5 7) (V2 11 13)
    , instanceUv = UvRect 0.25 0.5 0.75 1.0
    , instanceTexture = textureHandle 0x01020304 0x0A0B0C0D
    , instanceDepthKey = 0x00ABCDEF
    , instanceTint = Tint 0x11 0x22 0x33 0x44
    , instanceSampler = SamplerLinear
    , instanceTranslucent = True
    , instanceAdditive = True
    , instanceClip = 0
    , instanceMaterial = 0xDEADBEEF
    }

-- | The validated layer holding this one instance.
oneLayer ∷ Instance → ValidLayer
oneLayer candidate =
  case validateSnapshot (Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 64 64)) defaultViewSettings [UiLayer [candidate]]]]) of
    Right valid | layer : _ ← validLayers valid → layer
    other → error ("the fixture was refused: " <> either show (const "no layer") other)

littleEndian ∷ Word32 → [Word8]
littleEndian word = [fromIntegral ((word `shiftR` shift) .&. 0xFF) | shift ← [0, 8, 16, 24]]
