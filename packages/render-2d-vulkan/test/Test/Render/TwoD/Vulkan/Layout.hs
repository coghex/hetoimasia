-- | The recorder's pure layout decisions: the scissor rule against
-- 'viewportContains', the push block's bytes, the instance attributes against
-- render-2d's 64-byte encoding, the key-to-depth mapping, the sampler-choice
-- mapping, and the shaders' checked interfaces against the same numbers.
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
import Hetoimasia.GPU.Vulkan.Native.Shader.Interface (CheckedShader (..), CheckedShaders (..), PushMember (..), ShaderInterface (..), storageTableDescriptors, textureTableDescriptors)
import Hetoimasia.Math.Affine2 (fromColumns, identity)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Clip (ResolvedClip (..), emptyClip)
import Hetoimasia.Render.TwoD.Encoding (encodeLayer, flagsWord)
import Hetoimasia.Render.TwoD.Mapping (viewportContains)
import Hetoimasia.Render.TwoD.Settings (TextureFilter (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (ValidLayer, validLayers, validateSnapshot)
import Hetoimasia.Render.TwoD.Vulkan.Layout
import Hetoimasia.Render.TwoD.Vulkan.Shaders (cutoutShaders, orderedShaders)
import Test.Hspec (Spec, describe, it, shouldBe)

spec ∷ Spec
spec = describe "Layout" $ do
  scissorSpec
  pushSpec
  clipTableSpec
  attributeSpec
  depthSpec
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
  it "is 72 bytes in nine members that tile it, each at its natural alignment" $ do
    pushBytes `shouldBe` 72
    [(offset, size) | PushMember offset size ← pushMembers]
      `shouldBe` [(0, 16), (16, 8), (24, 8), (32, 4), (36, 4), (40, 4), (44, 4), (48, 16), (64, 8)]
    -- Each member starts where the one before ends.
    and (zipWith (\(PushMember offset size) (PushMember next _) → offset + size == next) pushMembers (drop 1 pushMembers)) `shouldBe` True
    sum [size | PushMember _ size ← pushMembers] `shouldBe` fromIntegral pushBytes

  it "packs a transform, the inverse's linear part, a clip base and centre, an extent, a brightness, a filter and a snap flag at their offsets" $ do
    let bytes =
          packViewPush
            ViewPush
              { pushTransform = fromColumns (V2 2 0) (V2 0 2) (V2 10 20)
              , pushInverse = fromColumns (V2 0.5 0) (V2 0 0.5) (V2 (-5) (-10))
              , pushClipBase = 3
              , pushClipCentre = (320, 240)
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
        , [0x03, 0x00, 0x00, 0x00] -- 44: clip base = 3
        , [0x00, 0x00, 0x00, 0x3F] -- 48: inverse a = 0.5
        , [0x00, 0x00, 0x00, 0x00] -- 52: inverse b = 0.0
        , [0x00, 0x00, 0x00, 0x00] -- 56: inverse c = 0.0
        , [0x00, 0x00, 0x00, 0x3F] -- 60: inverse d = 0.5
        , [0x00, 0x00, 0xA0, 0x43] -- 64: clip centre x = 320.0 (the inverse's translation is not pushed)
        , [0x00, 0x00, 0x70, 0x43] -- 68: clip centre y = 240.0
        ]

  it "packs nearest as 1 and snap off as 0, with the transform's off-diagonal and negative values" $ do
    let bytes =
          packViewPush
            ViewPush
              { pushTransform = fromColumns (V2 0 1) (V2 (-1) 0) (V2 0.5 (-0.25))
              , pushInverse = fromColumns (V2 0 (-1)) (V2 1 0) (V2 0.25 0.5)
              , pushClipBase = 0
              , pushClipCentre = (0.5, -0.25)
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
        , [0x00, 0x00, 0x00, 0x00] -- clip base = 0
        , [0x00, 0x00, 0x00, 0x00] -- inverse a = 0.0
        , [0x00, 0x00, 0x80, 0xBF] -- inverse b = -1.0
        , [0x00, 0x00, 0x80, 0x3F] -- inverse c = 1.0
        , [0x00, 0x00, 0x00, 0x00] -- inverse d = 0.0
        , [0x00, 0x00, 0x00, 0x3F] -- clip centre x = 0.5
        , [0x00, 0x00, 0x80, 0xBE] -- clip centre y = -0.25
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
                 , (8, 0, VertexUint)
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
                 , littleEndian 0x00ABCDEF -- the depth key
                 ]

  it "keeps every attribute inside the stride and aligned to its component size, with no two overlapping" $ do
    let VertexInput _ attributes = instanceVertexInput
        spans = [(toInteger (attributeOffset attribute), toInteger (attributeOffset attribute) + toInteger (vertexFormatBytes (attributeFormat attribute))) | attribute ← attributes]
    all ((<= 64) . snd) spans `shouldBe` True
    all (\attribute → attributeOffset attribute `mod` 4 == 0) attributes `shouldBe` True
    and [e1 <= s2 || e2 <= s1 | (i, (s1, e1)) ← zip [0 ∷ Int ..] spans, (j, (s2, e2)) ← zip [0 ..] spans, i < j] `shouldBe` True

-- ---------------------------------------------------------------------------
-- The key's depth

depthSpec ∷ Spec
depthSpec = describe "the depth a key gives" $ do
  it "is (2^24 - 1 - k) / 2^24, worked by hand at the ends and the middle of the range" $ do
    -- 16777215 / 16777216 is the largest float below one: 0x3F7FFFFF.
    fmap castFloatToWord32 (depthFromKey 0) `shouldBe` Just 0x3F7FFFFF
    -- 16777214 / 16777216 is the float below that one: 0x3F7FFFFE.
    fmap castFloatToWord32 (depthFromKey 1) `shouldBe` Just 0x3F7FFFFE
    -- 8388607 / 16777216 = 0.5 - 2^-24, which is two steps (2^-25 each) below one half: 0x3EFFFFFE.
    fmap castFloatToWord32 (depthFromKey 0x800000) `shouldBe` Just 0x3EFFFFFE
    -- 2^23 - 1 gives 8388608 / 16777216 = 0.5: 0x3F000000.
    fmap castFloatToWord32 (depthFromKey 0x7FFFFF) `shouldBe` Just 0x3F000000
    -- The nearest key gives 1 / 2^24 = 2^-24: 0x33800000.
    fmap castFloatToWord32 (depthFromKey 0xFFFFFE) `shouldBe` Just 0x33800000
    -- Key 2^24 - 1 is depth 0.
    depthFromKey 0xFFFFFF `shouldBe` Just 0

  it "is exact: scaled back by 2^24 it is the integer the key leaves" $
    and [fmap (* 16777216) (depthFromKey key) == Just (fromIntegral (16777215 - key)) | key ← [0, 1, 2, 255, 65535, 0x7FFFFF, 0x800000, 0xFFFFFD, 0xFFFFFE, 0xFFFFFF]]
      `shouldBe` True

  it "falls as the key grows, so a larger key is nearer, and stays below the cleared 1.0" $ do
    and [a > b | (a, b) ← zip depths (drop 1 depths)] `shouldBe` True
    all (< Just 1) (map depthFromKey [0, 1, 0xFFFFFF]) `shouldBe` True

  it "has no depth for a key at or past 2^24, which a validated snapshot never holds" $ do
    depthFromKey 0x1000000 `shouldBe` Nothing
    depthFromKey maxBound `shouldBe` Nothing
    depthKeyLimit `shouldBe` 0x1000000
  where
    depths = map depthFromKey [0, 1, 2, 100, 0x7FFFFF, 0x800000, 0xFFFFFE, 0xFFFFFF]

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
-- The clip table

clipTableSpec ∷ Spec
clipTableSpec = describe "the clip table" $ do
  it "is a vec4 an entry: 16 bytes" $
    clipEntryBytes `shouldBe` 16

  it "packs an entry's left, top, right and bottom as little-endian floats, in table order" $
    ByteString.unpack (packClipTable [ResolvedClip 1 2 3 4, ResolvedClip (-0.5) 0.25 8 (-2)])
      `shouldBe` concat
        [ [0x00, 0x00, 0x80, 0x3F] -- 0: left = 1.0
        , [0x00, 0x00, 0x00, 0x40] -- 4: top = 2.0
        , [0x00, 0x00, 0x40, 0x40] -- 8: right = 3.0
        , [0x00, 0x00, 0x80, 0x40] -- 12: bottom = 4.0
        , [0x00, 0x00, 0x00, 0xBF] -- 16: left = -0.5
        , [0x00, 0x00, 0x80, 0x3E] -- 20: top = 0.25
        , [0x00, 0x00, 0x00, 0x41] -- 24: right = 8.0
        , [0x00, 0x00, 0x00, 0xC0] -- 28: bottom = -2.0
        ]

  it "packs the empty clip as sixteen zero bytes, and a table of none as no bytes" $ do
    packClipTable [emptyClip] `shouldBe` ByteString.replicate 16 0
    packClipTable [] `shouldBe` ByteString.empty

  it "is as many entries as it was given, each 16 bytes" $
    ByteString.length (packClipTable (replicate 7 (ResolvedClip 0 0 1 1))) `shouldBe` 7 * clipEntryBytes

  it "rebases a clip about the layer-space point under a target-pixel point" $ do
    -- The transform (100, 0, 0, 100) with translation (-6553584, 16) puts the
    -- world point (65536, 0) at (16, 16): the point under (16, 16), and so the
    -- reference, is (65536, 0), and under (26, 36) it is (65536.1, 0.2).
    let far = fromColumns (V2 100 0) (V2 0 100) (V2 (-6553584) 16)
    clipReference far (16, 16) `shouldBe` (65536, 0)
    -- Exactly (26 + 6553584) / 100 and (36 - 16) / 100, each rounded once.
    clipReference far (26, 36) `shouldBe` (65536.1, 0.2)

  it "gives the point under the centre for a transform with a turn in it, by hand" $ do
    -- A quarter turn: (x, y) goes to (-y + 10, x + 20), so (7, 25) comes from
    -- x = 5 (from the second coordinate: 25 - 20) and y = 3 (from the first:
    -- 10 - 7).
    clipReference (fromColumns (V2 0 1) (V2 (-1) 0) (V2 10 20)) (7, 25) `shouldBe` (5, 3)

  it "has no inverse to take for a singular transform: the origin" $
    clipReference (fromColumns (V2 1 2) (V2 2 4) (V2 0 0)) (3, 4) `shouldBe` (0, 0)

  it "takes a clip's edges about the reference in double precision, rounding once" $ do
    -- Edges near 65536 about a reference of exactly 65536 are small, exact floats.
    rebaseClip (65536, 0) (ResolvedClip 65536.1484375 (-1) 65536.6484375 1) `shouldBe` ResolvedClip 0.1484375 (-1) 0.6484375 1
    -- The difference of two floats is taken exactly before it is rounded.
    rebaseClip (0.1, 0.2) (ResolvedClip 1 2 3 4) `shouldBe` ResolvedClip 0.9 1.8 2.9 3.8

  it "keeps an empty clip empty, and a clip the rebasing leaves no area empty" $ do
    rebaseClip (3, 4) emptyClip `shouldBe` emptyClip
    -- Edges at a billion, 64 apart (the spacing of floats there), are 0 and 64
    -- about a reference of a billion.
    rebaseClip (1.0e9, 0) (ResolvedClip 1.0e9 0 (1.0e9 + 64) 1) `shouldBe` ResolvedClip 0 0 64 1
    rebaseClip (0, 0) (ResolvedClip 3 0 3 1) `shouldBe` emptyClip

  it "clamps an edge past the finite range to the largest float, never to an infinity" $ do
    -- About a reference of 4.4e38, an edge at -1e38 is at -5.4e38, past the
    -- floats; one at 1e38 is at about -3.4e38, within them.
    let ResolvedClip left top right bottom = rebaseClip (4.4e38, 4.4e38) (ResolvedClip (-1.0e38) (-1.0e38) 1.0e38 1.0e38)
    (left, top) `shouldBe` (-3.4028235e38, -3.4028235e38)
    all (\edge → not (isInfinite edge || isNaN edge)) [left, top, right, bottom] `shouldBe` True
    (right < 0 && right > -3.4028235e38, bottom < 0 && bottom > -3.4028235e38) `shouldBe` (True, True)

  it "leaves a clip wholly past the finite range on one side with no area: empty" $
    rebaseClip (4.4e38, 0) (ResolvedClip (-3.0e38) 0 (-2.0e38) 1) `shouldBe` emptyClip

  it "takes the difference before rounding: a reference no double holds still gives the exact edge" $ do
    -- At a zoom of 2^60 about a camera at world x = 1, the point under the scissor's
    -- centre is 1 + 2^-56, which a double rounds to 1: the edge at 1 is 2^-56 of a
    -- layer unit short of it, not 0.
    rebaseClip (1 + 2 ^^ (-56 ∷ Int), 0) (ResolvedClip 1 (-1) 2 1) `shouldBe` ResolvedClip (negate (2 ^^ (-56 ∷ Int))) (-1) 1 1

  it "finds the clip arithmetic representable at ordinary scales, and not where a scissor spans more than the floats hold" $ do
    let scaled s = fromColumns (V2 s 0) (V2 0 s) (V2 0 0)
        representable inverse = clipRepresentable identity inverse
    -- Half of 32 pixels is 16, so the offset reaches 16 times the inverse's scale: the
    -- limit is half the largest float, 1.7e38.
    representable (scaled 1) (32, 32) `shouldBe` True
    representable (scaled 1.0e37) (32, 32) `shouldBe` True
    representable (scaled 1.1e37) (32, 32) `shouldBe` False
    representable (scaled 8.0e37) (32, 32) `shouldBe` False

  it "counts both of an axis's products, so a turn that splits the reach is checked too" $ do
    -- 1e37 · 16 + 1e37 · 16 = 3.2e38 on one axis, past the limit, though each product alone is not
    -- (the first transform's columns are (a, b) = (1e37, 0) and (c, d) = (1e37, 0): all its reach is on x).
    clipRepresentable identity (fromColumns (V2 1.0e37 0) (V2 1.0e37 0) (V2 0 0)) (32, 32) `shouldBe` False
    clipRepresentable identity (fromColumns (V2 0 1.0e37) (V2 0 1.0e37) (V2 0 0)) (32, 32) `shouldBe` False
    clipRepresentable identity (fromColumns (V2 5.0e36 0) (V2 5.0e36 0) (V2 0 0)) (32, 32) `shouldBe` True
    clipRepresentable identity (fromColumns (V2 0 5.0e36) (V2 0 5.0e36) (V2 0 0)) (32, 32) `shouldBe` True
    -- A tall scissor weighs the second column more: 1e37 · 16 on the first, 1e37 · 160 on the second.
    clipRepresentable identity (fromColumns (V2 1.0e37 0) (V2 1.0e37 0) (V2 0 0)) (32, 320) `shouldBe` False
    clipRepresentable identity (fromColumns (V2 1.0e37 0) (V2 0 1.0e37) (V2 0 0)) (32, 320) `shouldBe` False
    clipRepresentable identity (fromColumns (V2 1.0e37 0) (V2 0 1.0e37) (V2 0 0)) (32, 32) `shouldBe` True

  it "bounds the layer's scale at 2^100 pixels a unit, where a device that flushes denormals would move an edge by a visible amount" $ do
    let forward s = fromColumns (V2 s 0) (V2 0 s) (V2 0 0)
        inverse s = fromColumns (V2 (1 / s) 0) (V2 0 (1 / s)) (V2 0 0)
    clipRepresentable (forward (2 ^^ (100 ∷ Int))) (inverse (2 ^^ (100 ∷ Int))) (32, 32) `shouldBe` True
    clipRepresentable (forward (2 ^^ (101 ∷ Int))) (inverse (2 ^^ (101 ∷ Int))) (32, 32) `shouldBe` False
    clipRepresentable (forward (2 ^^ (60 ∷ Int))) (inverse (2 ^^ (60 ∷ Int))) (32, 32) `shouldBe` True

-- ---------------------------------------------------------------------------
-- The shaders' interfaces

interfaceSpec ∷ Spec
interfaceSpec = describe "the shaders' checked interfaces" $ do
  it "declare one push block of 72 bytes in both stages" $
    case (checkedVertex orderedShaders, checkedFragment orderedShaders) of
      (CheckedShader _ vertex, CheckedShader _ fragment) →
        [(offset, offset + size) | PushMember offset size ← interfacePushConstants vertex <> interfacePushConstants fragment]
          `shouldBe` concat (replicate 2 [(0, 16), (16, 24), (24, 32), (32, 36), (36, 40), (40, 44), (44, 48), (48, 64), (64, 72)])

  it "declare the instance attributes in the vertex stage, which both variants share" $
    mapM_
      ( \shaders → case checkedVertex shaders of
          CheckedShader _ description → interfaceVertexInput description `shouldBe` instanceVertexInput
      )
      [orderedShaders, cutoutShaders]

  it "are the same two stages' interfaces for the cutout variant" $
    case (checkedVertex orderedShaders, checkedFragment orderedShaders, checkedVertex cutoutShaders, checkedFragment cutoutShaders) of
      (CheckedShader orderedVertexCode orderedVertex, CheckedShader orderedFragmentCode orderedFragment, CheckedShader cutoutVertexCode cutoutVertex, CheckedShader cutoutFragmentCode cutoutFragment) → do
        interfacePushConstants cutoutVertex `shouldBe` interfacePushConstants orderedVertex
        interfacePushConstants cutoutFragment `shouldBe` interfacePushConstants orderedFragment
        interfaceDescriptors cutoutFragment `shouldBe` interfaceDescriptors orderedFragment
        -- The vertex stage is the same compiled code; the fragment stage is not.
        cutoutVertexCode `shouldBe` orderedVertexCode
        (cutoutFragmentCode == orderedFragmentCode) `shouldBe` False

  it "declare the clip table's binding in the fragment stage, beside the texture table's, and none in the vertex stage" $
    case (checkedVertex orderedShaders, checkedFragment orderedShaders, checkedFragment cutoutShaders) of
      (CheckedShader _ vertex, CheckedShader _ fragment, CheckedShader _ cutout) → do
        interfaceDescriptors vertex `shouldBe` []
        interfaceDescriptors fragment `shouldBe` textureTableDescriptors <> storageTableDescriptors
        interfaceDescriptors cutout `shouldBe` interfaceDescriptors fragment

  it "declare the same members in both stages" $
    case (checkedVertex orderedShaders, checkedFragment orderedShaders) of
      (CheckedShader _ vertex, CheckedShader _ fragment) → do
        interfacePushConstants vertex `shouldBe` interfacePushConstants fragment
        length (interfacePushConstants vertex) `shouldBe` 9

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
  case validateSnapshot (Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 64 64)) defaultViewSettings [] [UiLayer [candidate]]]]) of
    Right valid | layer : _ ← validLayers valid → layer
    other → error ("the fixture was refused: " <> either show (const "no layer") other)

littleEndian ∷ Word32 → [Word8]
littleEndian word = [fromIntegral ((word `shiftR` shift) .&. 0xFF) | shift ← [0, 8, 16, 24]]
