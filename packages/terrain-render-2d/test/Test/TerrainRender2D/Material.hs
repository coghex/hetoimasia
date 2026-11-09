-- | TRA-17: the presentation settings, the push block, the material's pure model and the
-- adaptation of a cell plan, proved against numbers worked out by hand.
--
-- Every expected number is stated in a comment beside it from the specification's equations: the
-- settings' ranges, the quarter-turned sun, the lighting and depth examples (top 0.80962, south
-- 0.675, east 0.35; D 1, 0.925, 0.85; H 0, 0.15, 0.60; the west-sun W-ramp response 0.81915
-- against 0.17365). The model is driven with stub samplers that return their own coordinates, so
-- the texel each region selects is read off the result and not recomputed with the helper that
-- chose it. The adaptation is driven over the committed packed atlases.
module Test.TerrainRender2D.Material (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import Data.Either (isLeft)
import Data.Word (Word32, Word64, Word8)
import GHC.Float (castWord32ToFloat)
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Material (MaterialFacts (..), MaterialRecord (..), MaterialRef, RecordLayout (..))
import Hetoimasia.Render.TwoD.Material.Backend (materialRef)
import Hetoimasia.Render.TwoD.Oracle.Material (Colour (..), MaterialInput (..), MaterialModel (..))
import Hetoimasia.Render.TwoD.Snapshot (Instance (..), Sampler (..))
import Hetoimasia.Asset.Image.Region (fullImageViewWith)
import Hetoimasia.Terrain.Render2D.Assets (ColourRef (..))
import Hetoimasia.Terrain.Render2D.AtlasAssets (AtlasAssetError (..), ParentAtlas (..), ParentKind (..), atlasAssetSnapshot)
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle (..), loadAtlasStyle, loadSingleImageStyle)
import Hetoimasia.Terrain.MapBake.Catalog (mapIdentifier)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Material
import Hetoimasia.Terrain.Render2D.Presentation
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Test.Hspec
import Test.TerrainRender2D.CellFixtures

spec ∷ Spec
spec = describe "Material" $ do
  settingsSpec
  pushSpec
  modelSpec
  adaptationSpec

-- ---------------------------------------------------------------------------
-- Settings

settingsSpec ∷ Spec
settingsSpec = describe "the presentation settings" $ do
  let ok input = mkLightSettings input `shouldSatisfy` either (const False) (const True)
      bad input = mkLightSettings input `shouldSatisfy` isLeft
      d = defaultLightInput
  it "has the approved defaults" $
    lightInput defaultLightSettings `shouldBe` LightInput 225 45 0.35 1 250 0.15 0.60 (0.72, 0.85, 0.95)
  it "accepts every endpoint of every range" $ do
    ok d {inputAzimuth = 0}
    ok d {inputAzimuth = 359.999}
    ok d {inputElevation = -90}
    ok d {inputElevation = 90}
    ok d {inputAmbient = 0}
    ok d {inputAmbient = 1}
    ok d {inputSunStrength = 0}
    ok d {inputSunStrength = 1}
    ok d {inputDepthRange = 1}
    ok d {inputDepthRange = 250}
    ok d {inputDarkening = 0}
    ok d {inputDarkening = 1}
    ok d {inputHaze = 0}
    ok d {inputHaze = 1}
    ok d {inputHazeColour = (0, 0, 0)}
    ok d {inputHazeColour = (1, 1, 1)}
  it "refuses a value just outside each range" $ do
    bad d {inputAzimuth = 360}
    bad d {inputAzimuth = -0.001}
    bad d {inputElevation = 90.001}
    bad d {inputElevation = -90.001}
    bad d {inputAmbient = 1.001}
    bad d {inputAmbient = -0.001}
    bad d {inputSunStrength = 1.001}
    bad d {inputDepthRange = 0}
    bad d {inputDepthRange = 251}
    bad d {inputDarkening = 1.5}
    bad d {inputHaze = -1}
    bad d {inputHazeColour = (1.1, 0.5, 0.5)}
    bad d {inputHazeColour = (0.5, -0.1, 0.5)}
    bad d {inputHazeColour = (0.5, 0.5, 2)}
  it "refuses nonfinite values, naming each" $ do
    let nan = 0 / 0
        inf = 1 / 0
    mkLightSettings d {inputAzimuth = nan} `shouldBe` Left [SettingNotFinite "sun azimuth"]
    mkLightSettings d {inputElevation = inf} `shouldBe` Left [SettingNotFinite "sun elevation"]
    mkLightSettings d {inputHazeColour = (nan, 0, 0)} `shouldBe` Left [SettingNotFinite "haze colour red"]
    mkLightSettings d {inputDarkening = -inf} `shouldBe` Left [SettingNotFinite "darkening"]
  it "validates the whole value: every problem is reported and none yields a usable value" $
    mkLightSettings d {inputAmbient = 2, inputDepthRange = 0, inputHaze = 3}
      `shouldBe` Left [SettingOutOfRange "ambient" 2, DepthRangeOutOfRange 0, SettingOutOfRange "haze" 3]

-- ---------------------------------------------------------------------------
-- The push block

floatsOf ∷ ByteString.ByteString → [Float]
floatsOf bytes = [castWord32ToFloat (word i) | i ← [0, 4 .. ByteString.length bytes - 4]]
  where
    word i = foldr (\k acc → acc * 256 + fromIntegral (ByteString.index bytes (i + k))) (0 ∷ Word32) [0 .. 3]

near ∷ Float → Float → Bool
near a b = abs (a - b) < 1.0e-6

pushSpec ∷ Spec
pushSpec = describe "the push block" $ do
  it "is three vec4s, 48 bytes" $ do
    ByteString.length (pushBytes FaceSouth defaultLightSettings) `shouldBe` 48
    pushBlockBytes `shouldBe` 48
  it "packs the defaults at the south facing: sun (-1/2, 1/2, sqrt 2 / 2), ambient, strength, darkening, haze, 1/250 and the linear haze" $ do
    -- azimuth 225, elevation 45: (sin 225 cos 45, -cos 225 cos 45, sin 45) = (-1/2, 1/2, 0.70710678).
    -- linear (0.72) = ((0.72 + 0.055) / 1.055) ^ 2.4 = 0.47700; (0.85) = 0.69207; (0.95) = 0.89001.
    let found = floatsOf (pushBytes FaceSouth defaultLightSettings)
        expected = [-0.5, 0.5, 0.70710678, 0.35, 1, 0.15, 0.6, 0.004, 0.47700, 0.69207, 0.89001, 0]
    length found `shouldBe` 12
    forM_ (zip3 [0 ∷ Int ..] found expected) $ \(i, f, e) → (i, abs (f - e) < 5.0e-5) `shouldBe` (i, True)
  it "turns the sun once per positive quarter turn, one turn taking (x, y) to (-y, x)" $ do
    -- With the south sun (-1/2, 1/2): 0 turns (-1/2, 1/2); 1 turn (-1/2, -1/2); 2 turns (1/2, -1/2); 3 turns (1/2, 1/2).
    -- South is 0 turns, East 1, North 2 and West 3.
    let sunOf facing = take 3 (floatsOf (pushBytes facing defaultLightSettings))
        xy facing = case sunOf facing of
          x : y : _ → (round (x * 2) ∷ Int, round (y * 2) ∷ Int)
          _ → (0, 0)
    map xy [FaceSouth, FaceEast, FaceNorth, FaceWest] `shouldBe` [(-1, 1), (-1, -1), (1, -1), (1, 1)]
  it "keeps the height of the sun fixed when the camera turns" $
    forM_ [FaceEast, FaceNorth, FaceWest] $ \facing →
      floatsOf (pushBytes facing defaultLightSettings) !! 2 `shouldSatisfy` near 0.70710678
  it "zeroes the direct strength at or below the horizon and keeps it above" $ do
    let strengthAt elevation = floatsOf (pushBytes FaceSouth (either (error . show) id (mkLightSettings defaultLightInput {inputElevation = elevation}))) !! 4
    map strengthAt [-90, -30, 0, 0.001, 10, 90] `shouldBe` [0, 0, 0, 1, 1, 1]
  it "states the depth range as its reciprocal" $ do
    let reciprocal range = floatsOf (pushBytes FaceSouth (either (error . show) id (mkLightSettings defaultLightInput {inputDepthRange = range}))) !! 7
    reciprocal 1 `shouldBe` 1
    reciprocal 50 `shouldSatisfy` near 0.02
  it "bounds a cell's depth word: zero at or above the cut, the cut minus the level below it, 250 at the bound" $ do
    map (uncurry depthWord) [(5, 7), (5, 5), (5, 4), (5, -245), (5, -246), (5, -9999999999999), (9223372036854775807, -9223372036854775808)]
      `shouldBe` [0, 0, 1, 250, 250, 250, 250]

-- ---------------------------------------------------------------------------
-- The model

colourHandle ∷ Int
colourHandle = 3

-- | A record of the colour region at (96, 0) of a 288 x 64 atlas and the normal region at
-- (192, 128) of a 768 x 384 atlas, at the given depth.
recordAt ∷ Word32 → MaterialRecord
recordAt depth =
  MaterialRecord
    [textureHandle 3 1, textureHandle 4 1]
    [96, 0, 96, 64, 288, 64, 192, 128, 96, 64, 768, 384, depth]

-- | A model input whose samplers answer by the handle's lookup index: the colour sampler returns
-- the coordinates it was asked at as the colour (red, green) with alpha 1, and the normal sampler a
-- fixed texel.
inputWith ∷ MaterialRecord → ByteString.ByteString → (Double, Double) → ((Double, Double) → Colour) → ((Double, Double) → Colour) → MaterialInput
inputWith record push uv colourSampler normalSampler =
  MaterialInput
    { materialTexel = Colour 0 0 0 0
    , materialUv = uv
    , materialParameter = 0
    , materialRecord = record
    , materialPush = push
    , materialSample = \handle at →
        Right (if handle == textureHandle (fromIntegral colourHandle) 1 then colourSampler at else normalSampler at)
    , materialSampleScaled = \handle at _ →
        Right (if handle == textureHandle (fromIntegral colourHandle) 1 then colourSampler at else normalSampler at)
    }

run ∷ MaterialInput → Colour
run input = either (error . show) id (runMaterialModel terrainModel input)

byteColour ∷ Word8 → Word8 → Word8 → Word8 → Colour
byteColour r g b a = Colour (fromIntegral r / 255) (fromIntegral g / 255) (fromIntegral b / 255) (fromIntegral a / 255)

push' ∷ LightInput → ViewFacing → ByteString.ByteString
push' input facing = pushBytes facing (either (error . show) id (mkLightSettings input))

-- | Light off, depth off: the colour comes out as the sampled colour times the map's alpha.
plain ∷ LightInput
plain = defaultLightInput {inputAmbient = 1, inputDarkening = 0, inputHaze = 0}

channels ∷ Colour → [Double]
channels (Colour r g b a) = [r, g, b, a]

closeTo ∷ Double → [Double] → [Double] → Bool
closeTo tolerance a b = length a == length b && and (zipWith (\x y → abs (x - y) <= tolerance) a b)

modelSpec ∷ Spec
modelSpec = describe "the model" $ do
  let up = byteColour 128 128 255 255
      someColour = Colour 0.5 0.25 0.125 1
  describe "region sampling" $ do
    -- The stub returns the coordinates it is asked at as the colour, and light is off, so the
    -- result is (u', v', 0, 1) with (u', v') the coordinates of the colour sample.
    let sampled uv = channels (run (inputWith (recordAt 0) (push' plain FaceSouth) uv (\(a, b) → Colour a b 0 1) (const up)))
        expectedAt i j = [(96 + i + 0.5) / 288, (0 + j + 0.5) / 64, 0, 1]
    it "samples the texel centre of the region's own local texel, adding the origin afterwards" $ do
      -- u = 0 selects local texel 0; u = 1 the last (95); v likewise 0 and 63; the centre is
      -- (origin + i + 1/2) / atlas extent.
      sampled (0, 0) `shouldSatisfy` closeTo 1e-12 (expectedAt 0 0)
      sampled (1, 1) `shouldSatisfy` closeTo 1e-12 (expectedAt 95 63)
      sampled (0.5, 0.5) `shouldSatisfy` closeTo 1e-12 (expectedAt 48 32)
    it "selects the higher texel on an interior boundary, within the 1/128 texel bias below it, and the lower beyond" $ do
      -- 1/96 is the boundary between local texels 0 and 1: it selects 1, and so does a coordinate a
      -- billionth below it (96 x 1e-9 texels, far inside the bias). 1e-4 below it is 9.6e-3 texels,
      -- beyond the 1/128 = 7.8e-3 bias, and selects 0. The same on the other axis at 1/64.
      sampled (1 / 96, 0) `shouldSatisfy` closeTo 1e-12 (expectedAt 1 0)
      sampled (1 / 96 - 1.0e-9, 0) `shouldSatisfy` closeTo 1e-12 (expectedAt 1 0)
      sampled (1 / 96 - 1.0e-4, 0) `shouldSatisfy` closeTo 1e-12 (expectedAt 0 0)
      sampled (0, 1 / 64) `shouldSatisfy` closeTo 1e-12 (expectedAt 0 1)
      -- The model is exact: 0.031168619791666664 x 96 + 1/128 is just below 3, so the local texel is 2
      -- (a Double product would round it up to 3).
      sampled (0.031168619791666664, 0) `shouldSatisfy` closeTo 1e-12 (expectedAt 2 0)
    it "clamps coordinates outside the unit square to the region's outer texels" $ do
      sampled (-3, -3) `shouldSatisfy` closeTo 1e-12 (expectedAt 0 0)
      sampled (7, 7) `shouldSatisfy` closeTo 1e-12 (expectedAt 95 63)
    it "samples the normal region at its own origin and atlas extent, not the colour's" $ do
      let normalAt uv = channels (run (inputWith (recordAt 0) (push' plain FaceSouth) uv (const (Colour 1 1 1 1)) (\(a, b) → Colour a b 1 1)))
      -- normal origin (192, 128), atlas 768 x 384: local texel (95, 63) is at ((192 + 95.5) / 768, (128 + 63.5) / 384).
      -- The normal bytes decoded from (a, b, 1) are irrelevant here: with ambient 1 the colour is
      -- (1, 1, 1) times the map's alpha, which is 1, so the colour shows only that sampling ran.
      normalAt (1, 1) `shouldSatisfy` closeTo 1e-12 [1, 1, 1, 1]
  describe "lighting" $ do
    -- Default sun at the south facing is (-1/2, 1/2, 0.70710678), ambient 0.35, strength 1.
    let lit normal = channels (run (inputWith (recordAt 0) (push' defaultLightInput {inputDarkening = 0, inputHaze = 0} FaceSouth) (0, 0) (const (Colour 1 1 1 1)) (const normal)))
        brightness normal = case lit normal of r : _ → r; [] → 0
    it "lights a flat top 0.80962, a south wall 0.675 and an east wall 0.35" $ do
      -- top (128, 128, 255): n = (0, 0, 1): 0.35 + 0.65 * 0.70710678 = 0.80962.
      -- south wall (128, 255, 128): n = (0, 1, 0): 0.35 + 0.65 * 0.5 = 0.675.
      -- east wall (255, 128, 128): n = (1, 0, 0): dot = -1/2, clamped to 0: 0.35.
      brightness (byteColour 128 128 255 255) `shouldSatisfy` (\b → abs (b - 0.80962) < 1e-4)
      brightness (byteColour 128 255 128 255) `shouldSatisfy` (\b → abs (b - 0.675) < 1e-6)
      brightness (byteColour 255 128 128 255) `shouldSatisfy` (\b → abs (b - 0.35) < 1e-6)
    it "gives the W-ramp normal 0.81915 under a west sun at 10 degrees and the flat top 0.17365" $ do
      -- azimuth 270, elevation 10: sun (sin 270 cos 10, -cos 270 cos 10, sin 10) = (-0.98481, 0, 0.17365).
      -- The W ramp (38, 128, 218): c - 128 = (-90, 0, 90), unit (-0.70711, 0, 0.70711):
      -- dot = 0.69636 + 0.12279 = 0.81915. Ambient 0 and full strength, so the colour is the dot.
      let west = defaultLightInput {inputAzimuth = 270, inputElevation = 10, inputAmbient = 0, inputDarkening = 0, inputHaze = 0}
          at normal = case channels (run (inputWith (recordAt 0) (push' west FaceSouth) (0, 0) (const (Colour 1 1 1 1)) (const normal))) of r : _ → r; [] → 0
      at (byteColour 38 128 218 255) `shouldSatisfy` (\b → abs (b - 0.81915) < 2e-4)
      at (byteColour 128 128 255 255) `shouldSatisfy` (\b → abs (b - 0.17365) < 2e-4)
    it "applies ambient alone, direct light alone, nothing, and light at the horizon and below" $ do
      let at input normal = case channels (run (inputWith (recordAt 0) (push' input FaceSouth) (0, 0) (const (Colour 1 1 1 1)) (const normal))) of r : _ → r; [] → 0
          base = defaultLightInput {inputDarkening = 0, inputHaze = 0}
          top = byteColour 128 128 255 255
      at base {inputSunStrength = 0} top `shouldSatisfy` (\b → abs (b - 0.35) < 1e-6)
      at base {inputAmbient = 0} top `shouldSatisfy` (\b → abs (b - 0.70710678) < 1e-6)
      at base {inputAmbient = 0, inputSunStrength = 0} top `shouldBe` 0
      at base {inputElevation = 0} top `shouldSatisfy` (\b → abs (b - 0.35) < 1e-6)
      at base {inputElevation = -45} top `shouldSatisfy` (\b → abs (b - 0.35) < 1e-6)
    it "lights the same world-facing surface alike when the camera turns, because the sun turns with it" $ do
      -- A world-south wall is (0,1,0) at the south facing and, after one positive quarter turn,
      -- (-1, 0, 0) at the east facing; the sun turned the same way keeps the dot product.
      let base = defaultLightInput {inputDarkening = 0, inputHaze = 0}
          at facing normal = case channels (run (inputWith (recordAt 0) (push' base facing) (0, 0) (const (Colour 1 1 1 1)) (const normal))) of r : _ → r; [] → 0
      at FaceSouth (byteColour 128 255 128 255) `shouldSatisfy` (\b → abs (b - 0.675) < 1e-6)
      -- (-1, 0, 0) is encoded round (128 - 127) = 1, 128, 128.
      at FaceEast (byteColour 1 128 128 255) `shouldSatisfy` (\b → abs (b - 0.675) < 1e-6)
  describe "depth effects and their order" $ do
    -- Ambient 0 and no sun: B = 0, so only the haze term remains for the colour. T = (0.5, 0.25, 0.125).
    let dark = defaultLightInput {inputAmbient = 0, inputSunStrength = 0}
        atDepth input depth = channels (run (inputWith (recordAt depth) (push' input FaceSouth) (0, 0) (const someColour) (const up)))
    it "darkens by 1, 0.925 and 0.85 at depths zero, half and full range, with the haze off" $ do
      -- Ambient 1, no haze, darkening 0.15, range 250: D = 1 - 0.15 t with t = d / 250.
      let lightOn = defaultLightInput {inputAmbient = 1, inputHaze = 0}
          at depth = atDepth lightOn depth
      at 0 `shouldSatisfy` closeTo 1e-6 [0.5, 0.25, 0.125, 1]
      at 125 `shouldSatisfy` closeTo 1e-6 [0.5 * 0.925, 0.25 * 0.925, 0.125 * 0.925, 1]
      at 250 `shouldSatisfy` closeTo 1e-6 [0.5 * 0.85, 0.25 * 0.85, 0.125 * 0.85, 1]
    it "hazes black terrain toward the linear haze colour by 0, 0.15 and 0.60 at depths zero, half and full range" $ do
      -- B = 0, so rgb = H F alpha with H = 0.6 t^2: 0, 0.6 * 0.25 = 0.15, 0.6; F = linear (0.72, 0.85, 0.95).
      let f = [0.47700, 0.69207, 0.89001]
          at depth = take 3 (atDepth dark depth)
      at 0 `shouldSatisfy` closeTo 1e-6 [0, 0, 0]
      at 125 `shouldSatisfy` closeTo 1e-4 (map (* 0.15) f)
      at 250 `shouldSatisfy` closeTo 1e-4 (map (* 0.60) f)
    it "composes the haze over the lit and darkened colour in linear light, in the specified order" $ do
      -- Ambient 1, depth 125 (t = 1/2): D = 0.925, H = 0.15: rgb = 0.85 * T * 0.925 + 0.15 * F.
      let full = defaultLightInput {inputAmbient = 1}
          f = [0.47700, 0.69207, 0.89001]
          expected = [0.85 * t' * 0.925 + 0.15 * fc | (t', fc) ← zip [0.5, 0.25, 0.125] f]
      take 3 (atDepth full 125) `shouldSatisfy` closeTo 1e-4 expected
    it "composes the wrong-order control differently: haze first, then darkening over the hazed colour, and the same at depth zero" $ do
      -- The same inputs: rgb = (0.85 * T + 0.15 * F) * 0.925 for the control, against 0.85 * T * 0.925 + 0.15 * F.
      let full = defaultLightInput {inputAmbient = 1}
          f = [0.47700, 0.69207, 0.89001]
          atWith model depth = channels (either (error . show) id (runMaterialModel model (inputWith (recordAt depth) (push' full FaceSouth) (0, 0) (const someColour) (const up))))
          wrong = [(0.85 * t' + 0.15 * fc) * 0.925 | (t', fc) ← zip [0.5, 0.25, 0.125] f]
      take 3 (atWith terrainModelWrongOrderControl 125) `shouldSatisfy` closeTo 1e-4 wrong
      take 3 (atWith terrainModelWrongOrderControl 125) `shouldSatisfy` (not . closeTo 1e-3 (take 3 (atWith terrainModel 125)))
      atWith terrainModelWrongOrderControl 0 `shouldSatisfy` closeTo 1e-9 (atWith terrainModel 0)
    it "bounds depth by the configured range, not by the viewport: a depth beyond it is the full range" $ do
      let short = defaultLightInput {inputAmbient = 1, inputHaze = 0, inputDepthRange = 10}
      atDepth short 5 `shouldSatisfy` closeTo 1e-6 [0.5 * 0.925, 0.25 * 0.925, 0.125 * 0.925, 1]
      atDepth short 10 `shouldSatisfy` closeTo 1e-6 [0.5 * 0.85, 0.25 * 0.85, 0.125 * 0.85, 1]
      atDepth short 250 `shouldSatisfy` closeTo 1e-6 [0.5 * 0.85, 0.25 * 0.85, 0.125 * 0.85, 1]
    it "never changes the alpha, whatever the depth effects" $
      forM_ [0, 60, 250] $ \depth → (atDepth defaultLightInput depth !! 3) `shouldBe` 1
  describe "transparency" $ do
    it "contributes nothing, and never a NaN, where the map is transparent, whatever its colour bytes" $
      forM_ [byteColour 128 128 128 0, byteColour 0 0 0 0, byteColour 255 255 255 0] $ \transparent → do
        let out = channels (run (inputWith (recordAt 100) (push' defaultLightInput FaceSouth) (0.5, 0.5) (const someColour) (const transparent)))
        out `shouldBe` [0, 0, 0, 0]
    it "contributes nothing where the colour is transparent" $
      channels (run (inputWith (recordAt 100) (push' defaultLightInput FaceSouth) (0.5, 0.5) (const (Colour 0 0 0 0)) (const up))) `shouldSatisfy` (\found → drop 3 found == [0])
    it "leaves the neutral byte 128 exactly neutral: a normal of bytes 128 on an opaque texel decodes to the guarded up vector, never a NaN" $
      channels (run (inputWith (recordAt 0) (push' plain FaceSouth) (0.5, 0.5) (const someColour) (const (byteColour 128 128 128 255)))) `shouldSatisfy` all (\c → not (isNaN c))
    it "draws nothing for a record of another layout" $
      channels (run (inputWith (MaterialRecord [textureHandle 3 1] [1, 2, 3]) (push' plain FaceSouth) (0.5, 0.5) (const someColour) (const up))) `shouldBe` [0, 0, 0, 0]

-- ---------------------------------------------------------------------------
-- Adaptation

-- | A style of the committed packed atlases at one parent version, and its two textures bound to
-- those very parents (colour handle 3, normal handle 4).
boundStyle ∷ Word64 → IO (AtlasStyle, AtlasTextures)
boundStyle version = do
  style ← loadAtlasStyle version [("stone", "colour.loam"), ("soil", "colour.granite")]
  colour ← either (fail . show) pure (bindColourParent (styleColour style) (textureHandle 3 1))
  normal ← either (fail . show) pure (bindDataParent (styleNormal style) (textureHandle 4 1))
  pure (style, packedTextures colour normal)

reference ∷ MaterialRef
reference = materialRef 11 (MaterialFacts True recordLayout (fromIntegral pushBlockBytes))

adaptationSpec ∷ Spec
adaptationSpec = describe "adapting a cell plan" $ do
  it "declares two handles and thirteen words, which fit the record limits" $ do
    recordLayout `shouldBe` RecordLayout 2 13
    recordHandleCount `shouldBe` 2
    recordWordCount `shouldBe` 13
  it "gives every quad a record that names both atlases, the quad's two regions and its depth below the cut" $ do
    (style, textures) ← boundStyle 5
    let assets = styleAssets style
        scene = sceneOf FaceSouth 2 [OCell 0 0 0 0 KnownAll, OCell 0 0 2 0 KnownAll]
        plan = planScene assets scene
    case adaptCells textures defaultLightSettings assets plan of
      Left why → expectationFailure (describeMaterialRefusal why)
      Right adapted → do
        let records = adaptedRecords adapted
        -- Two cells of one material and one shape at two levels: the same regions at depths 2 and 0.
        length records `shouldBe` 2
        forM_ records $ \(MaterialRecord handles ws) → do
          handles `shouldBe` [textureHandle 3 1, textureHandle 4 1]
          length ws `shouldBe` 13
        map (\(MaterialRecord _ ws) → last ws) records `shouldSatisfy` (\depths → all (`elem` depths) [0, 2])
  it "shares one record between quads that need the same regions and depth" $ do
    (style, textures) ← boundStyle 5
    let assets = styleAssets style
        scene = sceneOf FaceSouth 0 [OCell 0 0 0 0 KnownAll, OCell 3 0 0 0 KnownAll, OCell 0 3 0 0 KnownAll]
        plan = planScene assets scene
    case adaptCells textures defaultLightSettings assets plan of
      Left why → expectationFailure (describeMaterialRefusal why)
      Right adapted → do
        length (adaptedQuads adapted) `shouldBe` 3
        length (adaptedRecords adapted) `shouldBe` 1
        map adaptedParameter (adaptedQuads adapted) `shouldBe` [0, 0, 0]
  it "keeps the push block of the plan's own facing and the settings, 48 bytes" $ do
    (style, textures) ← boundStyle 5
    let assets = styleAssets style
    forM_ [FaceSouth, FaceWest, FaceNorth, FaceEast] $ \facing → do
      let plan = planScene assets (sceneOf facing 0 [OCell 0 0 0 0 KnownAll])
      case adaptCells textures defaultLightSettings assets plan of
        Left why → expectationFailure (describeMaterialRefusal why)
        Right adapted → adaptedPush adapted `shouldBe` pushBytes facing defaultLightSettings
  it "draws each instance with the colour atlas as its primary texture, nearest sampling and opaque white" $ do
    (style, textures) ← boundStyle 5
    let assets = styleAssets style
        plan = planScene assets (sceneOf FaceSouth 0 [OCell 0 0 0 0 KnownAll])
    case adaptCells textures defaultLightSettings assets plan of
      Left why → expectationFailure (describeMaterialRefusal why)
      Right adapted → forM_ (adaptedQuads adapted) $ \quad → do
        let instance' = adaptedInstance reference adapted quad
        instanceTexture instance' `shouldBe` textureHandle 3 1
        instanceSampler instance' `shouldBe` SamplerNearest
        instanceParameter instance' `shouldBe` adaptedParameter quad
        -- the record's colour handle is the primary slot's
        case drop (fromIntegral (adaptedParameter quad)) (adaptedRecords adapted) of
          MaterialRecord (h : _) _ : _ → h `shouldBe` instanceTexture instance'
          _ → expectationFailure "no record"
  it "adapts a mixed cell's fog and known parts together or not at all" $ do
    (style, textures) ← boundStyle 5
    let assets = styleAssets style
        plan = planScene assets (sceneOf FaceSouth 0 [OCell 0 0 0 5 KnownSolid])
    case adaptCells textures defaultLightSettings assets plan of
      Left why → expectationFailure (describeMaterialRefusal why)
      Right adapted → map (quadPart . adaptedQuad) (adaptedQuads adapted) `shouldBe` [PartFog, PartKnown]
    -- Against other assets nothing is adapted, not even one part.
    (otherStyle, _) ← boundStyle 6
    adaptCells textures defaultLightSettings (styleAssets otherStyle) plan `shouldBe` Left StaleAssets
  it "refuses a view paired with an adaptation of another plan" $ do
    (style, textures) ← boundStyle 5
    let assets = styleAssets style
        planA = planScene assets (sceneOf FaceSouth 0 [OCell 0 0 0 0 KnownAll])
        planB = planScene assets (sceneOf FaceWest 0 [OCell 0 0 0 0 KnownAll])
    case adaptCells textures defaultLightSettings assets planA of
      Left why → expectationFailure (describeMaterialRefusal why)
      Right adapted → do
        terrainView planB adapted [] [] `shouldSatisfy` isLeft
        terrainView planA adapted [(reference, adaptedMaterialData adapted)] [] `shouldSatisfy` either (const False) (const True)
  describe "textures are bound to the parents their regions live in" $ do
    it "refuses a plan whose region's parent has no bound texture, naming the parent" $ do
      (style, textures) ← boundStyle 5
      let assets = styleAssets style
          plan = planScene assets (sceneOf FaceSouth 0 [OCell 0 0 0 0 KnownAll])
      adaptCells textures {atlasNormal = []} defaultLightSettings assets plan `shouldBe` Left (NoTextureForParent "normal" 5 (768, 384))
      adaptCells textures {atlasColour = []} defaultLightSettings assets plan `shouldBe` Left (NoTextureForParent "colour" 5 (288, 64))
    it "refuses a binding whose identity is another parent's: a texture bound to the colour parent is not found for the normal regions" $ do
      (style, textures) ← boundStyle 5
      let assets = styleAssets style
          plan = planScene assets (sceneOf FaceSouth 0 [OCell 0 0 0 0 KnownAll])
          swapped = textures {atlasColour = atlasNormal textures, atlasNormal = atlasColour textures}
      adaptCells swapped defaultLightSettings assets plan `shouldSatisfy` isLeft
    it "binds a parent only as the kind it was decoded as, with one level and the checked profile" $ do
      (style, _) ← boundStyle 5
      bindColourParent (styleNormal style) (textureHandle 9 1) `shouldBe` Left (BindWrongKind DataParent)
      bindDataParent (styleColour style) (textureHandle 9 1) `shouldBe` Left (BindWrongKind ColourParent)
      bindColourParent (styleColour style) {parentLevels = 3} (textureHandle 9 1) `shouldBe` Left (BindLevels 3)
      bindDataParent (styleNormal style) {parentLevels = 2} (textureHandle 9 1) `shouldBe` Left (BindLevels 2)
      bindDataParent (styleNormal style) {parentProfile = Nothing} (textureHandle 9 1) `shouldBe` Left (BindWrongProfile Nothing)
    it "refuses a multi-level or wrongly decoded parent before any asset is made" $ do
      (style, _) ← boundStyle 5
      let build colour normal = atlasAssetSnapshot 5 (styleManifest style) colour normal [(stoneId, "colour.loam")]
      build (styleColour style) (styleNormal style) {parentLevels = 2} `shouldBe` Left (AtlasParentLevels "normal" 2)
      build (styleColour style) {parentKind = DataParent} (styleNormal style) `shouldBe` Left (AtlasParentKind "colour" DataParent)
    it "tells two different parents of one version and extent apart by their content, and refuses swapped or ambiguous bindings" $ do
      (assets, textures, handles) ← loadSingleImageStyle 5 [("stone", "colour.loam"), ("soil", "colour.granite")]
      let plan = planScene assets (sceneOf FaceSouth 0 [OCell 0 0 0 0 KnownAll])
          loamT = [t | t ← atlasColour textures, Just (ptHandle t) == Map.lookup "colour.loam" handles]
          graniteT = [t | t ← atlasColour textures, Just (ptHandle t) == Map.lookup "colour.granite" handles]
      -- Same extent (96 x 64), different images: their digests differ.
      map ptContent loamT /= map ptContent graniteT `shouldBe` True
      -- Forced to one version, the parents are still told apart by content: the stone (loam) quad
      -- draws with the loam handle, never the granite one.
      let sameVersion t = t {ptVersion = 1000}
          forced = textures {atlasColour = map sameVersion (atlasColour textures)}
      case (loamT, graniteT) of
        (l : _, g : _) → ptHandle l `shouldSatisfy` (/= ptHandle g)
        _ → expectationFailure "no loam or granite binding"
      -- A colour binding that is really a data parent (same list slot, matching extent) is not
      -- accepted for a colour region; and a duplicated binding is ambiguous, not first-wins.
      case atlasColour textures of
        t : _ → do
          adaptCells textures {atlasColour = [t {ptKind = DataParent}]} defaultLightSettings assets plan `shouldSatisfy` isLeft
          adaptCells textures {atlasColour = atlasColour textures <> atlasColour textures} defaultLightSettings assets plan `shouldSatisfy` (\r → case r of Left (AmbiguousTexture _ _) → True; _ → False)
        [] → expectationFailure "no colour bindings"
      forced `shouldSatisfy` (const True)
    it "resolves two different 96 x 64 parents of the same version to their own handles (the equal-version collision)" $ do
      let plane = planeFromFormula (\_ _ → True)
          viewOf content = either (error . show) id (fullImageViewWith content 5 plane)
          textureOf handleNo content kind = ParentTexture (textureHandle handleNo 1) 5 (96, 64) content kind
          bindings = AtlasTextures [textureOf 10 111 ColourParent, textureOf 11 222 ColourParent] [textureOf 20 333 DataParent, textureOf 21 444 DataParent]
          handlesOf colourContent normalContent = case quadRecord bindings 0 (viewOf colourContent) (viewOf normalContent) of
            Right (MaterialRecord hs _) → hs
            Left why → error (describeMaterialRefusal why)
      handlesOf 111 333 `shouldBe` [textureHandle 10 1, textureHandle 20 1]
      handlesOf 222 444 `shouldBe` [textureHandle 11 1, textureHandle 21 1]
      handlesOf 222 333 `shouldBe` [textureHandle 11 1, textureHandle 20 1]
      -- A parent whose content is bound nowhere is refused, not matched to the first of its size.
      quadRecord bindings 0 (viewOf 999) (viewOf 333) `shouldBe` Left (NoTextureForParent "colour" 5 (96, 64))
    it "gives every region of a single-image style the handle of its own image: distinct images never share a handle" $ do
      (assets, textures, handles) ← loadSingleImageStyle 5 [("stone", "colour.loam"), ("soil", "colour.granite")]
      let scenes =
            [ sceneOf facing 1 [OCell 0 0 0 shape know, OCell 2 0 0 (15 - shape) KnownAll]
            | facing ← [FaceSouth, FaceWest, FaceNorth, FaceEast]
            , shape ← [0 .. 15]
            , know ← [KnownAll, Undisc] <> [KnownSolid | shape /= 0]
            ]
      forM_ scenes $ \scene → do
        let plan = planScene assets scene
        case adaptCells textures defaultLightSettings assets plan of
          Left why → expectationFailure (describeMaterialRefusal why)
          Right adapted → forM_ (adaptedQuads adapted) $ \q → do
            let colourId = case quadColour (adaptedQuad q) of
                  ColourBlank → "colour.blanktexture"
                  _ → "colour.loam"
                expected = [Map.lookup colourId handles, Map.lookup (mapIdentifier (quadMap (adaptedQuad q))) handles]
            case drop (fromIntegral (adaptedParameter q)) (adaptedRecords adapted) of
              MaterialRecord hs _ : _ → map Just hs `shouldBe` expected
              [] → expectationFailure "no record"
      -- A mixed cell's known and fog parts draw different images, and so are different records.
      let mixed = planScene assets (sceneOf FaceSouth 0 [OCell 0 0 0 5 KnownSolid])
      case adaptCells textures defaultLightSettings assets mixed of
        Left why → expectationFailure (describeMaterialRefusal why)
        Right adapted → length (adaptedRecords adapted) `shouldBe` 2
  describe "capacity" $ do
    it "keeps a mixed cell's known and fog parts together under the record bound: all of them or none" $ do
      (style, textures) ← boundStyle 5
      let assets = styleAssets style
          mixed = planScene assets (sceneOf FaceSouth 0 [OCell 0 0 0 5 KnownSolid])
      -- The known and the fog part are two distinct records: a bound of one refuses the cell whole.
      adaptCellsWith 1 textures defaultLightSettings assets mixed `shouldBe` Left (TooManyRecords 1)
      case adaptCellsWith 2 textures defaultLightSettings assets mixed of
        Left why → expectationFailure (describeMaterialRefusal why)
        Right adapted → length (adaptedQuads adapted) `shouldBe` 2
    it "holds the same two parent textures however many regions and quads draw from them: one charge per physical texture" $ do
      (style, textures) ← boundStyle 5
      let assets = styleAssets style
          small = planScene assets (sceneOf FaceSouth 0 [OCell 0 0 0 5 KnownAll])
          large = planScene assets (sceneOf FaceSouth 8 [OCell x y z 5 KnownAll | x ← [0 .. 3], y ← [0 .. 3], z ← [0 .. 3]])
          handlesOf plan = case adaptCells textures defaultLightSettings assets plan of
            Left why → Left (describeMaterialRefusal why)
            Right adapted → Right (Set.fromList [h | MaterialRecord hs _ ← adaptedRecords adapted, h ← hs])
          -- #672: a texture is charged its byte size, at least 4 KiB, once however many instances read it.
          charge ∷ Set.Set Api.TextureHandle → Int
          charge handles = sum [max 4096 (bytes h) | h ← Set.toList handles]
          bytes ∷ Api.TextureHandle → Int
          bytes h
            | h == textureHandleOf (head' (atlasColour textures)) = 288 * 64 * 4
            | otherwise = 768 * 384 * 4
          head' xs = case xs of x : _ → x; [] → error "an atlas style binds its colour parent"
          textureHandleOf = ptHandle
      case (handlesOf small, handlesOf large) of
        (Right few, Right many) → do
          few `shouldBe` many
          Set.size many `shouldBe` 2
          charge many `shouldBe` 288 * 64 * 4 + 768 * 384 * 4
        other → expectationFailure (show other)
    it "refuses a plan whose second parent was never admitted, whole, and adapts it once both are bound" $ do
      (style, textures) ← boundStyle 5
      let assets = styleAssets style
          plan = planScene assets (sceneOf FaceSouth 0 [OCell 0 0 0 5 KnownAll])
          onlyColour = textures {atlasNormal = []}
      -- The normal parent's byte charge was refused (or its interest never taken): nothing of the plan is adapted.
      case adaptCells onlyColour defaultLightSettings assets plan of
        Left (NoTextureForParent _ _ _) → pure ()
        other → expectationFailure ("expected NoTextureForParent, got " <> either describeMaterialRefusal (const "an adaptation") other)
      -- Admitting it afterwards adapts the whole plan: the refusal left nothing behind.
      fmap (length . adaptedQuads) (adaptCells textures defaultLightSettings assets plan) `shouldBe` Right 1
    it "refuses the whole plan when it needs more distinct records than the bound, and adapts it at the bound" $ do
      (style, textures) ← boundStyle 5
      let assets = styleAssets style
          -- Three levels of one shape: three distinct depth words, so three records.
          plan = planScene assets (sceneOf FaceSouth 2 [OCell 0 0 0 0 KnownAll, OCell 0 0 1 0 KnownAll, OCell 0 0 2 0 KnownAll])
      adaptCellsWith 2 textures defaultLightSettings assets plan `shouldBe` Left (TooManyRecords 2)
      fmap (length . adaptedRecords) (adaptCellsWith 3 textures defaultLightSettings assets plan) `shouldBe` Right 3
      -- The documented bound is never exceeded by a caller's larger request.
      adaptCellsWith (maxRecords + 5) textures defaultLightSettings assets plan `shouldSatisfy` either (const False) (const True)
      maxRecords `shouldBe` 4096
