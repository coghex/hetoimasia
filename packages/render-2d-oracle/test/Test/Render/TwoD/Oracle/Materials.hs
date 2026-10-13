-- | Application materials in the oracle (R2D-11): a material's model applied to
-- its inputs, the same wrapping as the default material's, the record and push
-- block the model is given, the generation-aware sampling of a further texture,
-- and the explicit diagnostic for a material with no model.
--
-- __Method.__ Every expected value is written in the example from the sample
-- material's equations (see "Hetoimasia.Render.TwoD.Oracle.Material.Sample"),
-- with the arithmetic shown, and the sample model is first checked on its own
-- against fixtures stated here before it is run through the oracle.
module Test.Render.TwoD.Oracle.Materials (spec) where

import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.Map.Strict as Map
import Data.Word (Word8)
import Hetoimasia.Asset.Image (DecodedImage)
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Chunk
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)
import Hetoimasia.Render.TwoD.DrawPlan (cutoutMarks)
import Hetoimasia.Render.TwoD.Material
import Hetoimasia.Render.TwoD.Material.Backend (materialRef)
import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..), Tolerance (..))
import Hetoimasia.Render.TwoD.Oracle.Material
import Hetoimasia.Render.TwoD.Oracle.Material.Sample (mixModel, mixWeight)
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (Location (..), validateSnapshotWith)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Render.TwoD.Oracle.Support

-- * The sample material's reference, and what feeds it

-- | The sample material's reference: one handle and one word in a record, and a
-- push block of two floats.
mixRef ∷ MaterialRef
mixRef = materialRef 5 (MaterialFacts True (RecordLayout 1 1) 8)

-- | The same material declared not cutout-capable, for the ordered path.
translucentRef ∷ MaterialRef
translucentRef = materialRef 6 (MaterialFacts False (RecordLayout 1 1) 8)

-- | Two floats, little-endian: the sample material's push block.
pushOf ∷ Float → Float → ByteString.ByteString
pushOf strength bias = Lazy.toStrict (Builder.toLazyByteString (Builder.floatLE strength <> Builder.floatLE bias))

-- | A record of one handle and one word.
recordFor ∷ TextureHandle → Word8 → MaterialRecord
recordFor handle weight = MaterialRecord [handle] [fromIntegral weight]

-- | An instance of the material at a pixel, naming the first record.
mixed ∷ MaterialRef → TextureHandle → (Float, Float) → Instance
mixed material handle position = (sprite handle position (1, 1)) {instanceMaterial = material}

-- | A view of an 8 × 8 target holding this material data and these layers.
viewWith ∷ [(MaterialRef, MaterialData)] → [Layer] → View
viewWith held layers = (fullView 8 8 layers) {viewMaterials = Map.fromList held}

modelsFor ∷ [MaterialRef] → Map.Map MaterialRef MaterialModel
modelsFor refs = Map.fromList [(ref, mixModel) | ref ← refs]

-- | An oracle over one pass into the fixture target, with the sample material's
-- model for its references, the cutout marks given and no chunk.
oracleOf ∷ [MaterialRef] → [TextureHandle] → [(TextureHandle, DecodedImage)] → View → Oracle
oracleOf refs marked textures view =
  newOracleWith
    (modelsFor refs)
    OracleInput
      { inputSnapshot = validated [offscreenPass noClear [view]]
      , inputCutoutMarks = cutoutMarks marked
      , inputWindow = Nothing
      , inputOffscreen = Map.singleton offscreenRef unorm8
      , inputTextures = \handle → lookup handle textures
      }

-- | The pixel a probe at (x, y) of pass 0 expects, as bytes, or why it does not.
bytesAt ∷ Oracle → Int → Int → Either String Rgba8
bytesAt oracle x y = case expectAt oracle x y of
  Expected value _ → Right value
  Indeterminate why → Left ("indeterminate: " <> show why)
  Unevaluable failure → Left ("unevaluable: " <> show failure)

spec ∷ Spec
spec = describe "application materials" $ do
  modelSpec
  wrappingSpec
  recordSpec
  samplingSpec
  diagnosticSpec
  chunkSpec

-- * The sample material's model alone

-- | Inputs to the model with a stub sampler that answers one colour.
inputWith ∷ Colour → Colour → Word8 → ByteString.ByteString → MaterialInput
inputWith texel second weight push =
  MaterialInput
    { materialTexel = texel
    , materialUv = (0.25, 0.75)
    , materialParameter = 0
    , materialRecord = recordFor h2 weight
    , materialPush = push
    , materialSample = \_ _ → Right second
    }

run ∷ MaterialInput → Either ModelFault Colour
run = runMaterialModel mixModel

closeTo ∷ Colour → Either ModelFault Colour → Bool
closeTo (Colour r g b a) (Right (Colour r' g' b' a')) = and [abs (x - y) < 1e-9 | (x, y) ← [(r, r'), (g, g'), (b, b'), (a, a')]]
closeTo _ _ = False

modelSpec ∷ Spec
modelSpec = describe "the sample material's model" $ do
  let opaque = Colour 0.5 0.25 0.125 1
      second = Colour 0.2 0.4 0.8 1
  it "returns the second texture's colour when the weight is one, and the texel when it is zero" $ do
    run (inputWith opaque second 255 (pushOf 1 0)) `shouldSatisfy` closeTo second
    run (inputWith opaque second 0 (pushOf 1 0)) `shouldSatisfy` closeTo opaque
  it "mixes by the weight: 51 255ths is a fifth, from the texel's 0.8 and the second's 0.2" $
    -- r: 0.5 × 0.8 + 0.2 × 0.2 = 0.44; g: 0.25 × 0.8 + 0.4 × 0.2 = 0.28; b: 0.125 × 0.8 + 0.8 × 0.2 = 0.26
    run (inputWith opaque second 51 (pushOf 1 0)) `shouldSatisfy` closeTo (Colour 0.44 0.28 0.26 1)
  it "scales the weight by the push block's strength and adds its bias, then clamps it to [0, 1]" $ do
    mixWeight 0.5 0 255 `shouldBe` 0.5
    mixWeight 1 0.25 51 `shouldSatisfy` (\w → abs (w - 0.45) < 1e-12)
    mixWeight 4 0 255 `shouldBe` 1
    mixWeight 1 (-2) 255 `shouldBe` 0
    -- strength 0.5 over word 255 is half: r = 0.5 × 0.5 + 0.2 × 0.5 = 0.35
    run (inputWith opaque second 255 (pushOf 0.5 0)) `shouldSatisfy` closeTo (Colour 0.35 0.325 0.4625 1)
  it "weighs the second texture's colour by the texel's own coverage and keeps the texel's alpha" $
    -- t = (0.25, 0.125, 0.0625, 0.5) premultiplied; s × 0.5 = (0.1, 0.2, 0.4); w = 1
    run (inputWith (Colour 0.25 0.125 0.0625 0.5) second 255 (pushOf 1 0)) `shouldSatisfy` closeTo (Colour 0.1 0.2 0.4 0.5)
  it "keeps a binary alpha binary: the output alpha is the texel's whatever the second texture's is" $ do
    let translucentSecond = Colour 0.1 0.1 0.1 0.3
    run (inputWith (Colour 0 0 0 0) translucentSecond 255 (pushOf 1 0)) `shouldSatisfy` closeTo (Colour 0 0 0 0)
    run (inputWith opaque translucentSecond 255 (pushOf 1 0)) `shouldSatisfy` (\answer → fmap (\(Colour _ _ _ a) → a) answer == Right 1)
  it "leaves the texel as it is for a record of another layout" $ do
    let input = (inputWith opaque second 255 (pushOf 1 0)) {materialRecord = MaterialRecord [] []}
    run input `shouldSatisfy` closeTo opaque
  it "reads the push block as the shader does: little-endian floats, zero past the end" $ do
    pushFloat (pushOf 0.5 2) 0 `shouldBe` 0.5
    pushFloat (pushOf 0.5 2) 4 `shouldBe` 2
    pushFloat (pushOf 0.5 2) 8 `shouldBe` 0
    pushWord (pushOf 0.5 2) 0 `shouldBe` 0x3F000000
    pushWord ByteString.empty 0 `shouldBe` 0
  it "propagates a fault of its own sampling" $
    run ((inputWith opaque second 255 (pushOf 1 0)) {materialSample = \handle _ → Left (SampleNearTexelBoundary handle)})
      `shouldBe` Left (SampleNearTexelBoundary h2)

-- * Through the oracle: the wrapping around the model's colour

wrappingSpec ∷ Spec
wrappingSpec = describe "wrapped as the default material is" $ do
  let base = solid False (200, 100, 0, 255)
      other = solid False (0, 100, 200, 255)
      textures = [(h1, base), (h2, other)]
      held weight strength = [(mixRef, MaterialData [recordFor h2 weight] (pushOf strength 0)), (translucentRef, MaterialData [recordFor h2 weight] (pushOf strength 0))]
      within value (Right (Rgba8 r g b a)) = let Rgba8 er eg eb ea = value in all (\(x, y) → abs (fromIntegral x - fromIntegral y ∷ Int) <= 1) [(r, er), (g, eg), (b, eb), (a, ea)]
      within _ _ = False
      orderedAt weight strength modify = oracleOf [mixRef, translucentRef] [] textures (viewWith (held weight strength) [UiLayer [modify (mixed translucentRef h1 (2, 2))]])
  it "draws the model's colour on the ordered path: half of 200 and 0, half of 100 and 100, half of 0 and 200" $
    bytesAt (orderedAt 255 0.5 id) 2 2 `shouldSatisfy` within (Rgba8 100 100 100 255)
  it "draws the second texture alone at weight one and the texel alone at weight zero" $ do
    bytesAt (orderedAt 255 1 id) 2 2 `shouldSatisfy` within (Rgba8 0 100 200 255)
    bytesAt (orderedAt 0 1 id) 2 2 `shouldSatisfy` within (Rgba8 200 100 0 255)
  it "draws nothing outside the instance's quad" $
    bytesAt (orderedAt 255 1 id) 5 5 `shouldSatisfy` within (Rgba8 0 0 0 0)
  it "multiplies the model's colour by the tint, then brightens it, as for the default texel" $ do
    -- model (100, 100, 100, 255), tint (128, 255, 255, 255): r = 100 × 128/255 = 50.2 → 50
    bytesAt (orderedAt 255 0.5 (\candidate → candidate {instanceTint = Tint 128 255 255 255})) 2 2 `shouldSatisfy` within (Rgba8 50 100 100 255)
  it "applies the view's brightness to the model's colour" $ do
    let bright = (viewWith (held 255 0.5) [UiLayer [mixed translucentRef h1 (2, 2)]]) {viewSettings = defaultViewSettings {settingBrightness = 2}}
    bytesAt (oracleOf [mixRef, translucentRef] [] textures bright) 2 2 `shouldSatisfy` within (Rgba8 200 200 200 255)
  it "contributes no coverage when the instance is additive" $
    -- the colour is summed into the destination (transparent black) and the alpha stays 0
    bytesAt (orderedAt 255 0.5 (\candidate → candidate {instanceAdditive = True})) 2 2 `shouldSatisfy` within (Rgba8 100 100 100 0)
  it "applies the cutout variant to the model's colour in a depth-enabled world layer: the colour is written whole, with alpha one" $ do
    -- a unit sprite at the world origin covers pixel (4, 4) of the 8 × 8 target
    let layer = WorldLayer DepthEnabled [mixed mixRef h1 (0, 0)]
        oracle = oracleOf [mixRef, translucentRef] [h1] textures (viewWith (held 255 0.5) [layer])
    bytesAt oracle 4 4 `shouldSatisfy` within (Rgba8 100 100 100 255)
  it "discards a cutout fragment whose model alpha is below one half, as the default material's is" $ do
    let clear = solid False (200, 100, 0, 0)
        layer = WorldLayer DepthEnabled [mixed mixRef h1 (0, 0)]
        oracle = oracleOf [mixRef] [h1] [(h1, clear), (h2, other)] (viewWith (held 255 1) [layer])
    bytesAt oracle 4 4 `shouldSatisfy` within (Rgba8 0 0 0 0)
  it "routes a material that is not cutout-capable to the ordered path even when everything else qualifies" $ do
    let layer = WorldLayer DepthEnabled [mixed translucentRef h1 (0, 0)]
        oracle = oracleOf [mixRef, translucentRef] [h1] textures (viewWith (held 255 0.5) [layer])
    bytesAt oracle 4 4 `shouldSatisfy` within (Rgba8 100 100 100 255)
  it "leaves a default-material instance as the default material draws it, with no model given" $ do
    let oracle = oracleOf [] [] textures (fullView 8 8 [UiLayer [sprite h1 (2, 2) (1, 1)]])
    bytesAt oracle 2 2 `shouldSatisfy` within (Rgba8 200 100 0 255)
  it "ignores a model given for the default material" $ do
    let oracle = oracleOf [defaultMaterial] [] textures (fullView 8 8 [UiLayer [sprite h1 (2, 2) (1, 1)]])
    bytesAt oracle 2 2 `shouldSatisfy` within (Rgba8 200 100 0 255)

-- * The record and the push block

recordSpec ∷ Spec
recordSpec = describe "the record and the push block a model is given" $ do
  let base = solid False (200, 100, 0, 255)
      textures = [(h1, base), (h2, solid False (0, 100, 200, 255)), (h3, solid False (0, 0, 0, 255))]
      pixelOf record push =
        bytesAt
          (oracleOf [translucentRef] [] textures (viewWith [(translucentRef, MaterialData record push)] [UiLayer [(mixed translucentRef h1 (2, 2))]]))
          2
          2
      near expected (Right (Rgba8 r g b a)) = let Rgba8 er eg eb ea = expected in all (\(x, y) → abs (fromIntegral x - fromIntegral y ∷ Int) <= 1) [(r, er), (g, eg), (b, eb), (a, ea)]
      near _ _ = False
  it "reads the record the parameter word indexes" $ do
    let records = [recordFor h2 255, recordFor h3 255]
        at index = bytesAt (oracleOf [translucentRef] [] textures (viewWith [(translucentRef, MaterialData records (pushOf 1 0))] [UiLayer [(mixed translucentRef h1 (2, 2)) {instanceParameter = index}]])) 2 2
    at 0 `shouldSatisfy` near (Rgba8 0 100 200 255)
    at 1 `shouldSatisfy` near (Rgba8 0 0 0 255)
  it "changes the colour when the push block's bytes change" $ do
    pixelOf [recordFor h2 255] (pushOf 1 0) `shouldSatisfy` near (Rgba8 0 100 200 255)
    pixelOf [recordFor h2 255] (pushOf 0.25 0) `shouldSatisfy` near (Rgba8 150 100 50 255)
    pixelOf [recordFor h2 255] (pushOf 0 0) `shouldSatisfy` near (Rgba8 200 100 0 255)
  it "changes the colour when the record's word changes" $ do
    pixelOf [recordFor h2 0] (pushOf 1 0) `shouldSatisfy` near (Rgba8 200 100 0 255)
    pixelOf [recordFor h2 255] (pushOf 1 0) `shouldSatisfy` near (Rgba8 0 100 200 255)

-- * A further texture, sampled through the lookup

samplingSpec ∷ Spec
samplingSpec = describe "sampling a further texture" $ do
  let base = solid False (200, 100, 0, 255)
      other = solid False (0, 100, 200, 255)
      view' = viewWith [(translucentRef, MaterialData [recordFor h2 255] (pushOf 1 0))] [UiLayer [(mixed translucentRef h1 (2, 2))]]
      near expected (Right (Rgba8 r g b a)) = let Rgba8 er eg eb ea = expected in all (\(x, y) → abs (fromIntegral x - fromIntegral y ∷ Int) <= 1) [(r, er), (g, eg), (b, eb), (a, ea)]
      near _ _ = False
      pixel textures = bytesAt (oracleOf [translucentRef] [] textures view') 2 2
  it "samples the placeholder, transparent black, for a handle the lookup does not hold: a released texture, or an index of another generation" $ do
    -- s = (0, 0, 0, 0): the colour is the texel's (1 − 1) = 0 plus nothing
    pixel [(h1, base)] `shouldSatisfy` near (Rgba8 0 0 0 255)
    -- the lookup holds index 2 only in generation 2, and the record names generation 1
    pixel [(h1, base), (textureHandle 2 2, other)] `shouldSatisfy` near (Rgba8 0 0 0 255)
    pixel [(h1, base), (h2, other)] `shouldSatisfy` near (Rgba8 0 100 200 255)
  it "samples a reused index at its own generation: the reusing handle's texture and not the released one's" $ do
    let reused = textureHandle 2 2
        record = MaterialRecord [reused] [255]
        reusedView = viewWith [(translucentRef, MaterialData [record] (pushOf 1 0))] [UiLayer [(mixed translucentRef h1 (2, 2))]]
        oracle textures = oracleOf [translucentRef] [] textures reusedView
    bytesAt (oracle [(h1, base), (h2, other), (reused, solid False (50, 50, 50, 255))]) 2 2 `shouldSatisfy` near (Rgba8 50 50 50 255)
  it "applies the instance's sampler choice to the further texture" $ do
    -- a 2 × 1 texture sampled at the middle of the quad: nearest is on the boundary between its texels
    let two = rgba8 False 2 1 [[0, 0, 0, 255, 255, 255, 255, 255]]
        run' sampler = bytesAt (oracleOf [translucentRef] [] [(h1, base), (h2, two)] (viewWith [(translucentRef, MaterialData [recordFor h2 255] (pushOf 1 0))] [UiLayer [(mixed translucentRef h1 (2, 2)) {instanceSampler = sampler}]])) 2 2
    run' SamplerNearest `shouldSatisfy` (either (== "indeterminate: NearTexelBoundary (AtInstance 0 0 0 0)") (const False))
    run' SamplerLinear `shouldSatisfy` near (Rgba8 128 128 128 255)

-- * What the oracle will not guess

diagnosticSpec ∷ Spec
diagnosticSpec = describe "a material without a model, and a model that cannot answer" $ do
  let textures = [(h1, solid False (200, 100, 0, 255)), (h2, solid False (0, 100, 200, 255))]
      view' = viewWith [(translucentRef, MaterialData [recordFor h2 255] (pushOf 1 0))] [UiLayer [(mixed translucentRef h1 (2, 2))]]
  it "is unevaluable, naming the instance and the material, when no model was given" $
    expectAt (oracleOf [] [] textures view') 2 2 `shouldBe` Unevaluable (MissingMaterialModel (AtInstance 0 0 0 0) translucentRef)
  it "does not draw a missing model's instance as the default material" $
    expectAt (oracleOf [] [] textures view') 2 2 `shouldSatisfy` (\expectation → case expectation of Expected _ _ → False; _ → True)
  it "is not asked about a pixel the instance does not cover" $
    expectAt (oracleOf [] [] textures view') 6 6 `shouldSatisfy` (\expectation → case expectation of Expected (Rgba8 0 0 0 0) _ → True; _ → False)
  it "names a model that gives a colour that is not finite" $ do
    let nan = 0 / 0
        broken = MaterialModel (\_ → Right (Colour nan 0 0 1))
        oracle =
          newOracleWith
            (Map.singleton translucentRef broken)
            OracleInput
              { inputSnapshot = validated [offscreenPass noClear [view']]
              , inputCutoutMarks = cutoutMarks []
              , inputWindow = Nothing
              , inputOffscreen = Map.singleton offscreenRef unorm8
              , inputTextures = \handle → lookup handle textures
              }
    expectAt oracle 2 2 `shouldBe` Unevaluable (ModelOutputNotFinite (AtInstance 0 0 0 0))
  it "gives a model's own sampling fault as the case it is, naming the instance" $ do
    let faulting = MaterialModel (\input → materialSample input h2 (0.5, 0.5) >> Right (materialTexel input))
        two = rgba8 False 2 1 [[0, 0, 0, 255, 255, 255, 255, 255]]
        oracle =
          newOracleWith
            (Map.singleton translucentRef faulting)
            OracleInput
              { inputSnapshot = validated [offscreenPass noClear [view']]
              , inputCutoutMarks = cutoutMarks []
              , inputWindow = Nothing
              , inputOffscreen = Map.singleton offscreenRef unorm8
              , inputTextures = \handle → lookup handle [(h1, solid False (200, 100, 0, 255)), (h2, two)]
              }
    -- Nearest sampling at (0.5, 0.5) of a 2 × 1 texture is on the boundary
    -- between its two different texels.
    expectAt oracle 2 2 `shouldBe` Indeterminate (NearTexelBoundary (AtInstance 0 0 0 0))

-- * A chunk's own records

chunkSpec ∷ Spec
chunkSpec = describe "a chunk's instances" $ do
  let textures = [(h1, solid False (200, 100, 0, 255)), (h2, solid False (0, 100, 200, 255)), (h3, solid False (0, 0, 0, 255))]
      marks = cutoutMarks []
      first = chunkRef 1 1
      second = chunkRef 2 1
      -- The same material and parameter index in both chunks and in the view,
      -- with different records in each.
      built records position = either (error . show) id (buildChunkWith marks ChunkUi DeriveBounds (Map.singleton translucentRef [records]) [(mixed translucentRef h1 position)])
      chunkA = built (recordFor h2 255) (1, 1)
      chunkB = built (recordFor h3 255) (4, 4)
      layer = UiLayerWith [first, second] [mixed translucentRef h1 (6, 6)]
      held = [(translucentRef, MaterialData [recordFor h1 255] (pushOf 1 0))]
      snapshot = Snapshot [offscreenPass noClear [viewWith held [layer]]]
      valid = either (error . show) id (validateSnapshotWith (chunksFrom [(first, chunkA), (second, chunkB)]) snapshot)
      oracle =
        newOracleWith
          (modelsFor [translucentRef])
          OracleInput
            { inputSnapshot = valid
            , inputCutoutMarks = marks
            , inputWindow = Nothing
            , inputOffscreen = Map.singleton offscreenRef unorm8
            , inputTextures = \handle → lookup handle textures
            }
      near expected (Expected (Rgba8 r g b a) _) = let Rgba8 er eg eb ea = expected in all (\(x, y) → abs (fromIntegral x - fromIntegral y ∷ Int) <= 1) [(r, er), (g, eg), (b, eb), (a, ea)]
      near _ _ = False
  it "reads the chunk's own record for each chunk and the view's for a dynamic instance, at the same parameter index" $ do
    expectAt oracle 1 1 `shouldSatisfy` near (Rgba8 0 100 200 255)
    expectAt oracle 4 4 `shouldSatisfy` near (Rgba8 0 0 0 255)
    expectAt oracle 6 6 `shouldSatisfy` near (Rgba8 200 100 0 255)
  it "names a chunk's instance by its location when its material has no model" $ do
    let bare = newOracle OracleInput {inputSnapshot = valid, inputCutoutMarks = marks, inputWindow = Nothing, inputOffscreen = Map.singleton offscreenRef unorm8, inputTextures = \handle → lookup handle textures}
    expectAt bare 1 1 `shouldBe` Unevaluable (MissingMaterialModel (AtChunkInstance 0 0 0 0 0) translucentRef)
  it "is unaffected by a tolerance for the record's exactness: the result carries the tolerance of an inexact value" $
    case expectAt oracle 1 1 of
      Expected _ (Tolerance r g b a) → (r, g, b) `shouldSatisfy` (\(x, y, z) → x <= 1 && y <= 1 && z <= 1 && a <= 1)
      other → expectationFailure ("expected a value, got " <> show other)
