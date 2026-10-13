-- | The instance encoding: its byte layout field by field, its length, its
-- order, and agreement with an independent reference.
--
-- __Where the expected bytes come from.__ Never from the encoder under test.
-- The fixtures below are written out as literal bytes, each float as the
-- little-endian bytes of its IEEE 754 single-precision pattern worked out by
-- hand (2.0 is @00 00 00 40@, 0.25 is @00 00 80 3E@). The generated examples
-- compare against 'referenceBytes', a second encoder written here in terms of
-- shifts and masks instead of the builder the library uses.
module Test.Render.TwoD.Encoding (spec) where

import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as ByteString
import Data.Word (Word32, Word8)
import GHC.Float (castFloatToWord32)
import Hetoimasia.Math.Affine2 (fromColumns, identity, toColumnMajor)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture.Backend (handleGeneration, handleIndex, textureHandle)
import Hetoimasia.Render.TwoD.DrawPlan
  ( CutoutMarks
  , DrawPlan (..)
  , PlannedLayer
  , PlannedPass (..)
  , PlannedView (..)
  , cutoutMarks
  , drawingOrder
  , noCutoutMarks
  , planSnapshot
  )
import Hetoimasia.Render.TwoD.Encoding (encodeLayer, encodeLayerInDrawingOrder, instanceStride)
import Hetoimasia.Render.TwoD.Material (MaterialFacts (..), RecordLayout (..))
import Hetoimasia.Render.TwoD.Material.Backend (materialRef)
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (ValidLayer, validLayers, validateSnapshot)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (counterexample, forAll, listOf, property, resize)
import Test.Render.TwoD.Support

spec ∷ Spec
spec = describe "Encoding" $ do
  layoutSpec
  lengthAndOrderSpec
  referenceSpec
  drawingOrderSpec

-- | An instance whose every field has a different, recognisable value.
distinct ∷ Instance
distinct =
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
    , instanceParameter = 0xDEADBEEF
    , -- A material that is not the default, which the 64 bytes do not show: the
      -- reference is a value the planner reads and is never encoded.
      instanceMaterial = materialRef 7 (MaterialFacts False (RecordLayout 0 0) 0)
    }

-- | The 64 bytes 'distinct' must encode to, offset by offset.
distinctBytes ∷ [Word8]
distinctBytes =
  concat
    [ [0x00, 0x00, 0x00, 0x40] -- 0: a = 2.0
    , [0x00, 0x00, 0x40, 0x40] -- 4: b = 3.0
    , [0x00, 0x00, 0xA0, 0x40] -- 8: c = 5.0
    , [0x00, 0x00, 0xE0, 0x40] -- 12: d = 7.0
    , [0x00, 0x00, 0x30, 0x41] -- 16: tx = 11.0
    , [0x00, 0x00, 0x50, 0x41] -- 20: ty = 13.0
    , [0x00, 0x00, 0x80, 0x3E] -- 24: u0 = 0.25
    , [0x00, 0x00, 0x00, 0x3F] -- 28: v0 = 0.5
    , [0x00, 0x00, 0x40, 0x3F] -- 32: u1 = 0.75
    , [0x00, 0x00, 0x80, 0x3F] -- 36: v1 = 1.0
    , [0x04, 0x03, 0x02, 0x01] -- 40: handle index 0x01020304
    , [0x0D, 0x0C, 0x0B, 0x0A] -- 44: handle generation 0x0A0B0C0D
    , [0xEF, 0xCD, 0xAB, 0x00] -- 48: depth key 0x00ABCDEF
    , [0x11, 0x22, 0x33, 0x44] -- 52: tint R, G, B, A
    , [0x0E, 0x00, 0x00, 0x00] -- 56: flags: linear (2) | translucent (4) | additive (8)
    , [0xEF, 0xBE, 0xAD, 0xDE] -- 60: material word 0xDEADBEEF
    ]

-- | An instance of the plain defaults.
plain ∷ Instance
plain = plainInstance

-- | The 64 bytes 'plain' must encode to.
plainBytes ∷ [Word8]
plainBytes =
  concat
    [ [0x00, 0x00, 0x80, 0x3F] -- a = 1.0
    , [0x00, 0x00, 0x00, 0x00] -- b = 0.0
    , [0x00, 0x00, 0x00, 0x00] -- c = 0.0
    , [0x00, 0x00, 0x80, 0x3F] -- d = 1.0
    , [0x00, 0x00, 0x00, 0x00] -- tx = 0.0
    , [0x00, 0x00, 0x00, 0x00] -- ty = 0.0
    , [0x00, 0x00, 0x00, 0x00] -- u0 = 0.0
    , [0x00, 0x00, 0x00, 0x00] -- v0 = 0.0
    , [0x00, 0x00, 0x80, 0x3F] -- u1 = 1.0
    , [0x00, 0x00, 0x80, 0x3F] -- v1 = 1.0
    , [0x01, 0x00, 0x00, 0x00] -- handle index 1
    , [0x01, 0x00, 0x00, 0x00] -- handle generation 1
    , [0x00, 0x00, 0x00, 0x00] -- depth key 0
    , [0xFF, 0xFF, 0xFF, 0xFF] -- tint
    , [0x00, 0x00, 0x00, 0x00] -- flags
    , [0x00, 0x00, 0x00, 0x00] -- material word
    ]

encoded ∷ [Instance] → [Word8]
encoded instances = ByteString.unpack (encodeLayer (singleLayer (UiLayer instances)))

-- | The bytes at an offset and a size.
field ∷ Int → Int → [Word8] → [Word8]
field offset size = take size . drop offset

layoutSpec ∷ Spec
layoutSpec = describe "the byte layout" $ do
  it "is 64 bytes per instance" $ do
    instanceStride `shouldBe` 64
    length distinctBytes `shouldBe` 64
    length plainBytes `shouldBe` 64

  it "writes every field of a distinctive instance at its offset" $ do
    let bytes = encoded [distinct]
    length bytes `shouldBe` 64
    field 0 24 bytes `shouldBe` field 0 24 distinctBytes
    field 0 4 bytes `shouldBe` [0x00, 0x00, 0x00, 0x40]
    field 4 4 bytes `shouldBe` [0x00, 0x00, 0x40, 0x40]
    field 8 4 bytes `shouldBe` [0x00, 0x00, 0xA0, 0x40]
    field 12 4 bytes `shouldBe` [0x00, 0x00, 0xE0, 0x40]
    field 16 4 bytes `shouldBe` [0x00, 0x00, 0x30, 0x41]
    field 20 4 bytes `shouldBe` [0x00, 0x00, 0x50, 0x41]
    field 24 16 bytes `shouldBe` field 24 16 distinctBytes
    field 40 4 bytes `shouldBe` [0x04, 0x03, 0x02, 0x01]
    field 44 4 bytes `shouldBe` [0x0D, 0x0C, 0x0B, 0x0A]
    field 48 4 bytes `shouldBe` [0xEF, 0xCD, 0xAB, 0x00]
    field 52 4 bytes `shouldBe` [0x11, 0x22, 0x33, 0x44]
    field 56 4 bytes `shouldBe` [0x0E, 0x00, 0x00, 0x00]
    field 60 4 bytes `shouldBe` [0xEF, 0xBE, 0xAD, 0xDE]
    bytes `shouldBe` distinctBytes

  it "writes the plain defaults" $
    encoded [plain] `shouldBe` plainBytes

  it "writes the transform column-major as a, b, c, d, tx, ty" $ do
    toColumnMajor (instanceTransform distinct) `shouldBe` [2, 3, 5, 7, 11, 13]
    toColumnMajor identity `shouldBe` [1, 0, 0, 1, 0, 0]

  it "writes the texture index and the generation in that order" $ do
    let bytes = encoded [plain {instanceTexture = textureHandle 7 9}]
    field 40 4 bytes `shouldBe` [7, 0, 0, 0]
    field 44 4 bytes `shouldBe` [9, 0, 0, 0]

  it "writes the depth key little-endian at its limit minus one" $
    field 48 4 (encoded [plain {instanceDepthKey = 16777215}]) `shouldBe` [0xFF, 0xFF, 0xFF, 0x00]

  it "writes the tint in the order red, green, blue, alpha" $
    field 52 4 (encoded [plain {instanceTint = Tint 1 2 3 4}]) `shouldBe` [1, 2, 3, 4]

  it "writes a negative zero and a negative value with their sign bits" $
    field 0 8 (encoded [plain {instanceTransform = fromColumns (V2 (-1.5) (-0.0)) (V2 0 1) (V2 0 0)}])
      `shouldBe` [0x00, 0x00, 0xC0, 0xBF, 0x00, 0x00, 0x00, 0x80]

lengthAndOrderSpec ∷ Spec
lengthAndOrderSpec = describe "length and order" $ do
  it "encodes no instance to an empty buffer" $ do
    encoded [] `shouldBe` []
    ByteString.length (encodeLayer (singleLayer (WorldLayer DepthEnabled []))) `shouldBe` 0

  it "encodes one instance to exactly 64 bytes" $
    length (encoded [plain]) `shouldBe` 64

  it "encodes many instances to exactly 64 bytes each" $ do
    length (encoded (replicate 2 plain)) `shouldBe` 128
    length (encoded (replicate 3 distinct)) `shouldBe` 192
    length (encoded (replicate 1000 plain)) `shouldBe` 64000

  it "lays instances out in submission order, each at its own multiple of 64" $ do
    let bytes = encoded [distinct, plain, distinct]
    field 0 64 bytes `shouldBe` distinctBytes
    field 64 64 bytes `shouldBe` plainBytes
    field 128 64 bytes `shouldBe` distinctBytes
    encoded [plain, distinct] `shouldBe` plainBytes <> distinctBytes

  it "keeps instances with different depth keys where they were submitted" $ do
    let keys = [5, 1, 4, 2, 3]
        bytes = encoded [plain {instanceDepthKey = key} | key ← keys]
    [fromLE (field (64 * index + 48) 4 bytes) | index ← [0 .. 4]] `shouldBe` keys

  it "encodes a world layer and a UI layer of the same instances to the same bytes" $
    ByteString.unpack (encodeLayer (singleLayer (WorldLayer DepthDisabled [distinct, plain])))
      `shouldBe` ByteString.unpack (encodeLayer (singleLayer (UiLayer [distinct, plain])))

  it "encodes every layer of a validated snapshot on its own" $ do
    let snapshot =
          Snapshot
            [ plainPass (offscreen 0) [plainView [UiLayer [distinct], UiLayer []]]
            , windowPass [plainView [WorldLayer DepthEnabled [plain, plain]]]
            ]
    case validateSnapshot snapshot of
      Left refused → fail (show refused)
      Right valid →
        map (ByteString.length . encodeLayer) (validLayers valid) `shouldBe` [64, 0, 128]

  it "gives the same bytes every time" $ do
    let layer = singleLayer (UiLayer [distinct, plain, distinct])
    encodeLayer layer `shouldBe` encodeLayer layer

  prop "is exactly 64 bytes per instance for any number of generated instances" $
    forAll (resize 40 (listOf validInstance)) $ \instances →
      length (encoded instances) == 64 * length instances

referenceSpec ∷ Spec
referenceSpec = describe "against an independent reference" $ do
  prop "writes any generated layer as the reference encoder does" $
    forAll (resize 12 (listOf validInstance)) $ \instances →
      let expected = concatMap referenceBytes instances
       in counterexample (show (take 8 expected)) (property (encoded instances == expected))

  prop "reads back, field by field, what a generated instance holds" $
    forAll validInstance $ \candidate →
      let bytes = encoded [candidate]
          UvRect u0 v0 u1 v1 = instanceUv candidate
          Tint r g b a = instanceTint candidate
       in property
            ( map fromLE [field offset 4 bytes | offset ← [0, 4 .. 20]]
                == map castFloatToWord32 (toColumnMajor (instanceTransform candidate))
                && map fromLE [field offset 4 bytes | offset ← [24, 28, 32, 36]]
                  == map castFloatToWord32 [u0, v0, u1, v1]
                && fromLE (field 40 4 bytes) == handleIndex (instanceTexture candidate)
                && fromLE (field 44 4 bytes) == handleGeneration (instanceTexture candidate)
                && fromLE (field 48 4 bytes) == instanceDepthKey candidate
                && field 52 4 bytes == [r, g, b, a]
                && fromLE (field 60 4 bytes) == instanceParameter candidate
            )

-- | The reference encoder: the same 64 bytes, written with shifts and masks.
referenceBytes ∷ Instance → [Word8]
referenceBytes candidate =
  concatMap (littleEndian . castFloatToWord32) (toColumnMajor (instanceTransform candidate))
    <> concatMap (littleEndian . castFloatToWord32) [u0, v0, u1, v1]
    <> littleEndian (handleIndex (instanceTexture candidate))
    <> littleEndian (handleGeneration (instanceTexture candidate))
    <> littleEndian (instanceDepthKey candidate)
    <> [r, g, b, a]
    <> littleEndian flags
    <> littleEndian (instanceParameter candidate)
  where
    UvRect u0 v0 u1 v1 = instanceUv candidate
    Tint r g b a = instanceTint candidate
    flags =
      sampler (instanceSampler candidate)
        + (if instanceTranslucent candidate then 4 else 0)
        + (if instanceAdditive candidate then 8 else 0)
        + 65536 * fromIntegral (instanceClip candidate)
    sampler SamplerDefault = 0
    sampler SamplerNearest = 1
    sampler SamplerLinear = 2

-- | The four bytes of a word, least significant first.
littleEndian ∷ Word32 → [Word8]
littleEndian word = [fromIntegral ((word `shiftR` shift) .&. 0xFF) | shift ← [0, 8, 16, 24]]

-- | A word from four bytes, least significant first.
fromLE ∷ [Word8] → Word32
fromLE bytes = sum [fromIntegral byte * 256 ^ position | (position, byte) ← zip [0 ∷ Int ..] bytes]

-- | Every planned layer of a snapshot, planned with these marks, beside its
-- validated layer, in snapshot order.
plannedWith ∷ CutoutMarks → Snapshot → [(PlannedLayer, ValidLayer)]
plannedWith marks snapshot = case validateSnapshot snapshot of
  Left refused → error ("the snapshot was refused: " <> show refused)
  Right valid →
    zip
      [ layer
      | DrawPlan passes ← [planSnapshot marks valid]
      , PlannedPass {plannedViews = views} ← passes
      , PlannedView {plannedLayers = layers} ← views
      , layer ← layers
      ]
      (validLayers valid)

-- | The chunk of a submission-order buffer at this submission index.
chunk ∷ Int → [Word8] → [Word8]
chunk index = field (64 * index) 64

drawingOrderSpec ∷ Spec
drawingOrderSpec = describe "in drawing order" $ do
  let keyed key = plain {instanceDepthKey = key, instanceTexture = textureHandle 1 key}
      inOrder marks layer = case plannedWith marks (snapshotWithView (plainView [layer])) of
        [(planned, valid)] → (drawingOrder planned, fmap ByteString.unpack (encodeLayerInDrawingOrder planned valid), ByteString.unpack (encodeLayer valid))
        other → error ("expected one layer, found " <> show (length other))

  it "writes the chunks of ascending depth key, then submission, as the plan orders them" $ do
    let instances = [keyed 3, keyed 1, keyed 2, keyed 1]
        (order, bytes, _) = inOrder noCutoutMarks (UiLayer instances)
    order `shouldBe` [1, 3, 2, 0]
    -- Each chunk is the independent reference encoding of the instance the
    -- order names at that position, not a copy of the encoder under test.
    bytes `shouldBe` Just (concatMap (referenceBytes . (instances !!)) [1, 3, 2, 0])

  it "writes the chunks `encodeLayer` writes, permuted by the drawing order" $ do
    let instances = [distinct, keyed 5, plain, keyed 2, distinct {instanceDepthKey = 1}]
        (order, bytes, submission) = inOrder noCutoutMarks (UiLayer instances)
    order `shouldBe` [2, 4, 3, 1, 0]
    bytes `shouldBe` Just (concatMap (`chunk` submission) order)

  it "writes the cutout instances first when a mark routes them there" $ do
    let marked = textureHandle 7 1
        instances = [keyed 0, plain {instanceTexture = marked, instanceDepthKey = 9}, keyed 4]
        (order, bytes, submission) = inOrder (cutoutMarks [marked]) (WorldLayer DepthEnabled instances)
    -- The cutout run comes before every ordered-path instance whatever its key.
    order `shouldBe` [1, 0, 2]
    bytes `shouldBe` Just (concatMap (`chunk` submission) order)

  it "gives a run's instances as the contiguous range its start and count name" $ do
    let marked = textureHandle 7 1
        instances = [keyed 0, plain {instanceTexture = marked, instanceDepthKey = 9}, keyed 4, plain {instanceTexture = marked}]
        snapshot = snapshotWithView (plainView [WorldLayer DepthEnabled instances])
    case plannedWith (cutoutMarks [marked]) snapshot of
      [(planned, valid)] → do
        let submission = ByteString.unpack (encodeLayer valid)
            bytes = maybe [] ByteString.unpack (encodeLayerInDrawingOrder planned valid)
        -- The cutouts 1 and 3 form the first run, the ordered 0 and 2 the second.
        drawingOrder planned `shouldBe` [1, 3, 0, 2]
        field 0 128 bytes `shouldBe` chunk 1 submission <> chunk 3 submission
        field 128 128 bytes `shouldBe` chunk 0 submission <> chunk 2 submission
      other → error ("expected one layer, found " <> show (length other))

  it "encodes a layer with no instances, and one in a zero-size viewport, to the empty buffer" $ do
    let emptyViewport = View plainCamera (Viewport (V2 0 0) (V2 0 480)) defaultViewSettings [UiLayer [plain, distinct]]
        zeroSize = [(planned, valid) | (planned, valid) ← plannedWith noCutoutMarks (snapshotWithView emptyViewport)]
    inOrder noCutoutMarks (UiLayer []) `shouldBe` ([], Just [], [])
    map (\(planned, valid) → (drawingOrder planned, encodeLayerInDrawingOrder planned valid)) zeroSize `shouldBe` [([], Just ByteString.empty)]

  it "refuses a plan that names an instance the layer does not hold" $
    case
      ( plannedWith noCutoutMarks (snapshotWithView (plainView [UiLayer [plain, plain, plain]]))
      , plannedWith noCutoutMarks (snapshotWithView (plainView [UiLayer [plain, plain]]))
      ) of
      ([(planned, _)], [(_, short)]) → encodeLayerInDrawingOrder planned short `shouldBe` Nothing
      _ → expectationFailure "each snapshot has one layer"

  it "gives the same bytes every time" $
    case plannedWith noCutoutMarks (snapshotWithView (plainView [UiLayer [keyed 3, keyed 1, keyed 2]])) of
      [(planned, valid)] → encodeLayerInDrawingOrder planned valid `shouldBe` encodeLayerInDrawingOrder planned valid
      _ → expectationFailure "the snapshot has one layer"

  prop "is, for every layer of a generated snapshot, the submission chunks permuted by its drawing order" $
    forAll validSnapshotGen $ \snapshot →
      and
        [ fmap ByteString.unpack (encodeLayerInDrawingOrder planned valid)
            == Just (concatMap (`chunk` ByteString.unpack (encodeLayer valid)) (drawingOrder planned))
        | (planned, valid) ← plannedWith noCutoutMarks snapshot
        ]
