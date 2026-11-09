-- | The terrain material's device-free contracts (TRA-17): its declaration against the pure record
-- layout and push block, an adapted plan's records and instances through snapshot validation, the
-- draw path the colour atlas's mark routes its quads to, and the bytes the renderer writes for its
-- records. None creates a device.
--
-- Expectations are stated by hand from the declaration and the layout: two handles and thirteen
-- words, so a record of 2 x 2 + 13 = 17 words, 68 bytes, and a push block of three vec4s at byte
-- offsets 0, 16 and 32 of the application's block, 48 bytes in all.
module Test.Terrain.Render2D.Vulkan.Material (spec) where

import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.DrawPlan (DrawPath (..), DrawPlan (..), DrawRun (..), PlannedLayer (..), PlannedPass (..), PlannedView (..), cutoutMarks, noCutoutMarks, planSnapshot)
import Hetoimasia.Render.TwoD.Encoding (encodeRecords)
import Hetoimasia.Render.TwoD.Material (MaterialData (..), MaterialFacts (..), MaterialRecord (..), MaterialRef, RecordLayout (..))
import Hetoimasia.Render.TwoD.Material.Backend (materialRef)
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (validateSnapshot)
import Hetoimasia.Render.TwoD.Vulkan.Material (DefinedMaterial (..), PushField (..), PushOffset (..), PushType (..), definedPushBytes)
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle (..), loadAtlasStyle)
import Hetoimasia.Terrain.Render2D.Evidence
import Hetoimasia.Terrain.Render2D.Material
import Hetoimasia.Terrain.Render2D.Presentation (defaultLightSettings, pushBlockBytes)
import Hetoimasia.Terrain.Render2D.Vulkan.Material (lightPush, terrainMaterial, terrainMaterialEquivalent, terrainMaterialInsetControl, terrainMaterialUnbiasedControl, terrainMaterialStaleBiasControl, terrainMaterialWrongOrderControl)
import Test.Hspec (Spec, beforeAll, describe, expectationFailure, it, shouldBe, shouldSatisfy)

-- | The style's two packed parents bound to registered textures 3 (colour) and 4 (normal).
texturesOf ∷ AtlasStyle → AtlasTextures
texturesOf style = packedTextures (either (error . show) id (bindColourParent (styleColour style) (textureHandle 3 1))) (either (error . show) id (bindDataParent (styleNormal style) (textureHandle 4 1)))

-- | The reference a renderer would issue for the material: its facts as defined.
reference ∷ MaterialRef
reference = materialRef 11 (definedFacts terrainMaterial)

-- | A snapshot drawing the adapted quads in a depth-enabled world layer of an offscreen target,
-- the view holding the table of records and the push block.
snapshotOf ∷ Adapted → [MaterialRecord] → [Instance] → Snapshot
snapshotOf adapted records instances =
  Snapshot
    [ Pass
        (OffscreenTarget (targetRef 1 1))
        (ClearColour 0 0 0 1)
        [ ViewWith
            (Camera (V2 200 160) 1 Nothing)
            (Viewport (V2 0 0) (V2 400 320))
            defaultViewSettings
            []
            (Map.fromList [(reference, MaterialData records (adaptedPush adapted))])
            []
            0
            [WorldLayer DepthEnabled instances]
        ]
    ]

instancesOf ∷ Adapted → [Instance]
instancesOf adapted = map (adaptedInstance reference adapted) (adaptedQuads adapted)

-- | Quads of two materials and a ramp over a mixed cell, adapted over the committed atlases.
adaptedOf ∷ AtlasStyle → Adapted
adaptedOf style = case scenePlan (styleAssets style) scene of
  Left refused → error (show refused)
  Right plan → either (error . describeMaterialRefusal) id (adaptCells (texturesOf style) defaultLightSettings (styleAssets style) plan)
  where
    scene = (newScene "vulkan" [Cell 0 0 0 1 0 "loam", Cell 2 0 0 1 3 "granite", Cell 0 2 0 1 5 "loam"] (400, 320)) {sceneMode = ManualAt 1 1, sceneKnow = [((0, 2, 0), KnownSolid)]}

spec ∷ Spec
spec = describe "Terrain material, device-free (TRA-17)" $ do
  describe "its declaration" $ do
    it "is cutout-capable with the pure layout's record and a 48-byte push block of three vec4s" $ do
      definedFacts terrainMaterial `shouldBe` MaterialFacts True recordLayout 48
      recordLayout `shouldBe` RecordLayout 2 13
      definedPushBytes terrainMaterial `shouldBe` 48
      pushBlockBytes `shouldBe` 48
    it "names the members the host packs, at their std430 offsets" $ do
      lightPush `shouldBe` [PushField "lightSun" PushVec4, PushField "lightDepth" PushVec4, PushField "lightHaze" PushVec4]
      definedPush terrainMaterial `shouldBe` [PushOffset "lightSun" PushVec4 0, PushOffset "lightDepth" PushVec4 16, PushOffset "lightHaze" PushVec4 32]
    it "has both the translucent and the cutout variants, checked at build time" $
      definedCutout terrainMaterial `shouldSatisfy` isJust
    it "declares an equivalent second material identically but for its source" $ do
      definedFacts terrainMaterialEquivalent `shouldBe` definedFacts terrainMaterial
      definedPush terrainMaterialEquivalent `shouldBe` definedPush terrainMaterial
      definedCutout terrainMaterialEquivalent `shouldSatisfy` isJust

    it "declares the half-texel-inset negative control with the same layout, so only its sampling rule differs" $ do
      definedFacts terrainMaterialInsetControl `shouldBe` definedFacts terrainMaterial
      definedPush terrainMaterialInsetControl `shouldBe` definedPush terrainMaterial
    it "declares the unbiased-index negative control with the same layout, so only the texel bias differs" $ do
      definedFacts terrainMaterialUnbiasedControl `shouldBe` definedFacts terrainMaterial
      definedPush terrainMaterialUnbiasedControl `shouldBe` definedPush terrainMaterial
    it "declares the stale-bias negative control with the same layout, compiled to its own shaders" $ do
      definedFacts terrainMaterialStaleBiasControl `shouldBe` definedFacts terrainMaterial
      definedPush terrainMaterialStaleBiasControl `shouldBe` definedPush terrainMaterial
      definedTranslucent terrainMaterialStaleBiasControl `shouldSatisfy` (/= definedTranslucent terrainMaterial)
      definedTranslucent terrainMaterialStaleBiasControl `shouldSatisfy` (/= definedTranslucent terrainMaterialUnbiasedControl)
    it "declares the wrong-composition-order negative control with the same layout, compiled to its own shaders" $ do
      definedFacts terrainMaterialWrongOrderControl `shouldBe` definedFacts terrainMaterial
      definedPush terrainMaterialWrongOrderControl `shouldBe` definedPush terrainMaterial
      definedTranslucent terrainMaterialWrongOrderControl `shouldSatisfy` (/= definedTranslucent terrainMaterial)
    it "compiles the unbiased control to different shaders than the terrain material, whose shader carries the bias" $ do
      definedTranslucent terrainMaterialUnbiasedControl `shouldSatisfy` (/= definedTranslucent terrainMaterial)
      definedCutout terrainMaterialUnbiasedControl `shouldSatisfy` isJust

  beforeAll (loadAtlasStyle 5 [("loam", "colour.loam"), ("granite", "colour.granite")]) $ do
    describe "an adapted plan's records and instances" $ do
      it "form a snapshot the renderer's validation accepts" $ \style → do
        let adapted = adaptedOf style
        case validateSnapshot (snapshotOf adapted (adaptedRecords adapted) (instancesOf adapted)) of
          Right _ → pure ()
          Left refused → expectationFailure (show refused)

      it "are refused when a record does not have the layout, never drawn with another's" $ \style → do
        let adapted = adaptedOf style
            short = [MaterialRecord handles (drop 1 ws) | MaterialRecord handles ws ← adaptedRecords adapted]
        validateSnapshot (snapshotOf adapted short (instancesOf adapted)) `shouldSatisfy` isLeft

      it "are refused when a parameter word is past the table" $ \style → do
        let adapted = adaptedOf style
            beyond = [inst {instanceParameter = fromIntegral (length (adaptedRecords adapted))} | inst ← take 1 (instancesOf adapted)]
        validateSnapshot (snapshotOf adapted (adaptedRecords adapted) beyond) `shouldSatisfy` isLeft

      it "are refused when the push block is not the declared size" $ \style → do
        let adapted = adaptedOf style
            wrong = adapted {adaptedPush = ByteString.take 47 (adaptedPush adapted)}
        validateSnapshot (snapshotOf wrong (adaptedRecords wrong) (instancesOf wrong)) `shouldSatisfy` isLeft

      it "are routed to the cutout path, one run, when the colour atlas's decoded mark says its alpha is binary" $ \style → do
        let adapted = adaptedOf style
        case validateSnapshot (snapshotOf adapted (adaptedRecords adapted) (instancesOf adapted)) of
          Left refused → expectationFailure (show refused)
          Right valid → do
            let plan = planSnapshot (cutoutMarks (atlasColourHandles (texturesOf style))) valid
                runs = [run | pass' ← planPasses plan, view' ← plannedViews pass', layer ← plannedLayers view', run ← plannedRuns layer]
            map runPath runs `shouldBe` [Cutout]
            map runMaterial runs `shouldBe` [reference]
            map runCount runs `shouldBe` [length (adaptedQuads adapted)]

      it "take the ordered path when the atlas is not marked, so the mark decides and nothing forces it down a path its alpha does not support" $ \style → do
        let adapted = adaptedOf style
        case validateSnapshot (snapshotOf adapted (adaptedRecords adapted) (instancesOf adapted)) of
          Left refused → expectationFailure (show refused)
          Right valid → do
            let plan = planSnapshot noCutoutMarks valid
                runs = [run | pass' ← planPasses plan, view' ← plannedViews pass', layer ← plannedLayers view', run ← plannedRuns layer]
            map runPath runs `shouldBe` [Ordered]

    describe "the record conversion" $
      it "writes each record as its two handles' lookup indices and generations and then its 13 words, 68 bytes a record, with no padding" $ \style → do
        let adapted = adaptedOf style
            bytes = encodeRecords recordLayout (adaptedRecords adapted)
        ByteString.length bytes `shouldBe` 68 * length (adaptedRecords adapted)
        -- Little-endian 32-bit words: the colour handle's index 3 and generation 1, the normal
        -- handle's index 4 and generation 1, then the words.
        ByteString.unpack (ByteString.take 16 bytes) `shouldBe` [3, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0]
  where
    isLeft = \case
      Left _ → True
      Right _ → False
