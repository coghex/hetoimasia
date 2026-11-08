-- | The terrain material's device-free contracts (TRA-8): its declaration
-- against the pure record layout, an adapted plan's records and instances
-- through snapshot validation, the draw path the art's mark routes its faces to,
-- and the bytes the renderer writes for its records. None creates a device.
--
-- Expectations are stated by hand from the declaration and the record layout
-- (one handle and 23 words, so a record of 25 words, 100 bytes), not read from
-- the code under test.
module Test.Terrain.Render2D.Vulkan.Material (spec) where

import qualified Data.ByteString as ByteString
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
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
import Hetoimasia.Render.TwoD.Vulkan.Material (DefinedMaterial (..), PushOffset, definedPushBytes)
import Hetoimasia.Terrain.Cell (mkMaterialId)
import Hetoimasia.Terrain.Render2D.Evidence
import Hetoimasia.Terrain.Render2D.Material
import Hetoimasia.Terrain.Render2D.Plan (planFaces)
import Hetoimasia.Terrain.Render2D.Vulkan.Material (terrainMaterial)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

art ∷ ArtSheet
art = isoSheet (textureHandle 3 1)

-- | The reference a renderer would issue for the material: its facts as defined.
reference ∷ MaterialRef
reference = materialRef 11 (definedFacts terrainMaterial)

-- | The faces of three flat cells and a ramp, adapted over one sheet.
adapted ∷ Adapted
adapted = case adaptFaces style faces of
  Right found → found
  Left refused → error (show refused)
  where
    style = styleFromList [(either (error . show) id (mkMaterialId "loam"), art)]
    sc = (newScene "vulkan" [Cell 0 0 0 1 0 "loam", Cell 2 0 0 1 0 "loam", Cell 0 2 0 1 3 "loam", Cell 2 2 0 2 0 "loam"] (400, 320)) {sceneMode = ManualAt 1 1}
    faces = either (error . show) planFaces (scenePlan sc)

-- | A snapshot drawing the adapted faces in a depth-enabled world layer of an
-- offscreen target, the view holding the table of records.
snapshotOf ∷ [MaterialRecord] → [Instance] → Snapshot
snapshotOf records instances =
  Snapshot
    [ Pass
        (OffscreenTarget (targetRef 1 1))
        (ClearColour 0 0 0 1)
        [ ViewWith
            (Camera (V2 200 160) 1 Nothing)
            (Viewport (V2 0 0) (V2 400 320))
            defaultViewSettings
            []
            (Map.fromList [(reference, MaterialData records ByteString.empty)])
            []
            0
            [WorldLayer DepthEnabled instances]
        ]
    ]

instancesOf ∷ Adapted → [Instance]
instancesOf found = map (adaptedInstance reference) (adaptedFaces found)

spec ∷ Spec
spec = describe "Terrain material, device-free (TRA-8)" $ do
  describe "its declaration" $ do
    it "is cutout-capable with the pure layout's record and no application push block" $ do
      definedFacts terrainMaterial `shouldBe` MaterialFacts True recordLayout 0
      recordLayout `shouldBe` RecordLayout 1 23
      definedPushBytes terrainMaterial `shouldBe` 0
      (definedPush terrainMaterial ∷ [PushOffset]) `shouldBe` []

    it "has both the translucent and the cutout variants, checked at build time" $
      definedCutout terrainMaterial `shouldSatisfy` isJust

  describe "an adapted plan's records and instances" $ do
    it "form a snapshot the renderer's validation accepts" $
      case validateSnapshot (snapshotOf (adaptedRecords adapted) (instancesOf adapted)) of
        Right _ → pure ()
        Left refused → expectationFailure (show refused)

    it "are refused when a record does not have the layout, never drawn with another's" $ do
      let short = [MaterialRecord handles (drop 1 ws) | MaterialRecord handles ws ← adaptedRecords adapted]
      validateSnapshot (snapshotOf short (instancesOf adapted)) `shouldSatisfy` isLeft

    it "are refused when a parameter word is past the table" $ do
      let beyond = [inst {instanceParameter = fromIntegral (length (adaptedRecords adapted))} | inst ← take 1 (instancesOf adapted)]
      validateSnapshot (snapshotOf (adaptedRecords adapted) beyond) `shouldSatisfy` isLeft

    it "are routed to the cutout path, one run, when the art's decoded mark says its alpha is binary" $
      case validateSnapshot (snapshotOf (adaptedRecords adapted) (instancesOf adapted)) of
        Left refused → expectationFailure (show refused)
        Right valid → do
          let plan = planSnapshot (cutoutMarks [sheetTexture art]) valid
              runs = [run | pass' ← planPasses plan, view' ← plannedViews pass', layer ← plannedLayers view', run ← plannedRuns layer]
          map runPath runs `shouldBe` [Cutout]
          map runMaterial runs `shouldBe` [reference]
          map runCount runs `shouldBe` [length (adaptedFaces adapted)]

    it "take the ordered path when the art is not marked, so the mark decides and nothing forces the art down a path its alpha does not support" $
      case validateSnapshot (snapshotOf (adaptedRecords adapted) (instancesOf adapted)) of
        Left refused → expectationFailure (show refused)
        Right valid → do
          let plan = planSnapshot noCutoutMarks valid
              runs = [run | pass' ← planPasses plan, view' ← plannedViews pass', layer ← plannedLayers view', run ← plannedRuns layer]
          map runPath runs `shouldBe` [Ordered]

  describe "the record conversion" $
    it "writes each record as the sheet's lookup index and generation and then its 23 words, 100 bytes a record, with no padding" $ do
      let bytes = encodeRecords recordLayout (adaptedRecords adapted)
      ByteString.length bytes `shouldBe` 100 * length (adaptedRecords adapted)
      case adaptedRecords adapted of
        MaterialRecord _ ws : _ → do
          -- Little-endian 32-bit words: the handle's index 3 and generation 1, then the words.
          ByteString.unpack (ByteString.take 8 bytes) `shouldBe` [3, 0, 0, 0, 1, 0, 0, 0]
          ByteString.unpack (ByteString.take 4 (ByteString.drop 8 bytes)) `shouldBe` le32 (case ws of w : _ → w; [] → 0)
        [] → expectationFailure "the plan has no record"
  where
    isLeft = \case
      Left _ → True
      Right _ → False
    le32 w = [fromIntegral (w `div` 256 ^ k `mod` 256) | k ← [0 .. 3 ∷ Int]]
