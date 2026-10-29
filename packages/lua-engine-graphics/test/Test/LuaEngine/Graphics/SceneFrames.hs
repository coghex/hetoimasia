-- | The frame an adopted scene is recorded as (LFE-20): built from the frame's own metrics, never from the
-- scene's publication; the scene part of the host's configuration; and the maximum legal scene against the
-- renderer's configured resources.
--
-- The pure adaptation is judged against the existing render-2d oracle, whose expectations are computed without a
-- GPU: a window that grows shows the same sprites at the same authored pixels over the same explicit clear, a
-- scene is clipped and never stretched or recentred, and nothing about a frame changes the scene's texture
-- references or asks for another publication. Pixels read back from a device are the native suite's and LFE-24's.
module Test.LuaEngine.Graphics.SceneFrames (spec) where

import qualified Data.Map.Strict as Map
import Data.Word (Word64, Word8)
import qualified Data.Set as Set
import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (FromMemory))
import Hetoimasia.Asset.Image (DecodedImage, ImageKind (ColourImage))
import Hetoimasia.Asset.Image.Png (decodePng)
import Hetoimasia.GPU.Vulkan.GLFW (SceneMode (PerWindowScenes), TextureHandle (..), VulkanHostConfig (..), vulkanHostConfig)
import Hetoimasia.GPU.Vulkan.Diagnostics (defaultCaptureConfig)
import Hetoimasia.Runtime.GLFW (defaultHostConfig)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.LuaEngine.Graphics.Scene
import Hetoimasia.LuaEngine.Graphics.Texture.Configuration (configurationFor)
import Hetoimasia.LuaEngine.Graphics.Texture.Port (TextureRef (..), textureIdentity)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Scene
import Hetoimasia.LuaEngine.Texture (TextureView (..))
import Hetoimasia.Render.TwoD.DrawPlan (noCutoutMarks)
import Hetoimasia.Math.Vector (V2 (V2))
import Hetoimasia.Render.TwoD.Metrics (TargetMetrics (..))
import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (R8G8B8A8Srgb), Rgba8 (..))
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Vulkan.Frame (snapshotTablesBound)
import Hetoimasia.Render.TwoD.Vulkan.Textures (fromBackendHandle)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import qualified Test.LuaEngine.Graphics.Png as Png

spec ∷ Spec
spec = describe "the frame of an adopted scene" $ do
  describe "metrics" $ do
    it "skips a frame that has no logical extent or no content scale, and invents neither" $ do
      frameCandidate sampleScene (FrameFacts (8, 6) Nothing (Just (1, 1))) `shouldSatisfy` skipped NoLogicalExtent
      frameCandidate sampleScene (FrameFacts (8, 6) (Just (8, 6)) Nothing) `shouldSatisfy` skipped NoContentScale

    it "skips a frame whose observations are not usable metrics" $ do
      case frameCandidate sampleScene (FrameFacts (8, 6) (Just (8, 6)) (Just (0, 1))) of
        Left (MetricsNotUsable _) → pure ()
        other → expectationFailure ("expected unusable metrics, found " <> take 80 (show (fmap fst other)))

    it "builds the full-window view of the frame's own framebuffer, with the authored rectangles unchanged by any size or scale" $ do
      let drawn facts = either (const Nothing) (spritesOf . fst) (frameCandidate sampleScene facts)
          small = drawn (FrameFacts (8, 6) (Just (8, 6)) (Just (1, 1)))
          large = drawn (FrameFacts (64, 48) (Just (64, 48)) (Just (1, 1)))
          scaled = drawn (FrameFacts (128, 96) (Just (64, 48)) (Just (2, 2)))
      fmap (\(_, viewport, _) → viewport) small `shouldBe` Just (Viewport (V2 0 0) (V2 8 6))
      fmap (\(_, viewport, _) → viewport) large `shouldBe` Just (Viewport (V2 0 0) (V2 64 48))
      fmap (\(_, viewport, _) → viewport) scaled `shouldBe` Just (Viewport (V2 0 0) (V2 128 96))
      -- The sprites, their order and the references are the scene's, whatever the frame.
      fmap (\(_, _, sprites) → sprites) small `shouldSatisfy` (/= Nothing)
      fmap (\(_, _, sprites) → sprites) large `shouldBe` fmap (\(_, _, sprites) → sprites) small
      fmap (\(_, _, sprites) → sprites) scaled `shouldBe` fmap (\(_, _, sprites) → sprites) small
      graphicsReferences sampleScene `shouldBe` Set.fromList [sampleIdentity]

    it "suspends drawing at a zero framebuffer without invalidating the scene" $ do
      case frameCandidate sampleScene (FrameFacts (0, 0) (Just (8, 6)) (Just (1, 1))) of
        Right (candidate, _) → fmap (\(_, viewport, _) → viewport) (spritesOf candidate) `shouldBe` Just (Viewport (V2 0 0) (V2 0 0))
        Left skip → expectationFailure ("a zero framebuffer is a valid empty viewport, found " <> show skip)

  describe "against the render-2d oracle" $ do
    it "clears the initial scene to opaque black everywhere" $ do
      oracle ← oracleFor initialGraphicsScene (FrameFacts (8, 6) (Just (8, 6)) (Just (1, 1)))
      forM_' [(0, 0), (7, 5), (3, 2)] $ \(x, y) →
        expect oracle (Probe 0 x y) `shouldSatisfy` readsAs (Rgba8 0 0 0 255)

    it "clears an empty scene to the clear it was published with" $ do
      oracle ← oracleFor (GraphicsScene (SceneContent (clearOfBytes 255 0 128) []) Set.empty) (FrameFacts (8, 6) (Just (8, 6)) (Just (1, 1)))
      forM_' [(0, 0), (7, 5)] $ \(x, y) →
        expect oracle (Probe 0 x y) `shouldSatisfy` readsAs (Rgba8 255 0 128 255)

    it "shows the same sprite at the same pixels in a larger window and clips it in a smaller one, never stretching or recentring" $ do
      small ← oracleFor sampleScene (FrameFacts (8, 6) (Just (8, 6)) (Just (1, 1)))
      large ← oracleFor sampleScene (FrameFacts (16, 12) (Just (16, 12)) (Just (1, 1)))
      -- The sprite is at (2, 1), three by two: its interior is the texture's red in both windows.
      forM_' [small, large] $ \oracle →
        forM_' [(2, 1), (4, 2)] $ \(x, y) → expect oracle (Probe 0 x y) `shouldSatisfy` readsAs (Rgba8 255 0 0 255)
      -- Outside it is the clear: nothing grew with the window, and nothing moved to its middle.
      forM_' [(0, 0), (5, 1), (2, 3)] $ \(x, y) → expect small (Probe 0 x y) `shouldSatisfy` readsAs (Rgba8 0 0 0 255)
      forM_' [(0, 0), (5, 1), (2, 3), (10, 8), (15, 11)] $ \(x, y) → expect large (Probe 0 x y) `shouldSatisfy` readsAs (Rgba8 0 0 0 255)
      -- A window too small for the sprite's far corner clips it.
      tiny ← oracleFor sampleScene (FrameFacts (3, 2) (Just (3, 2)) (Just (1, 1)))
      expect tiny (Probe 0 2 1) `shouldSatisfy` readsAs (Rgba8 255 0 0 255)
      expect tiny (Probe 0 0 0) `shouldSatisfy` readsAs (Rgba8 0 0 0 255)

  describe "the scene part of the host" $ do
    it "sets per-window scenes, the real lifecycle's slot, the renderer and the declaration together" $ do
      scenes ← newSceneSession
      budgets ← either (\refused → assertFailure ("budgets: " <> show refused)) pure (validateBudgets defaultBudgetRequest)
      let plain = vulkanHostConfig (defaultHostConfig []) defaultCaptureConfig budgets (scenesInitial scenes)
          configured = configureScenes scenes plain
      checkSceneHostConfig plain `shouldBe` [SceneModeNotPerWindow, InitialSceneNotDeclared]
      checkSceneHostConfig configured `shouldBe` []
      vulkanSceneMode configured `shouldBe` PerWindowScenes
      vulkanInitialSceneHoldsNothing configured `shouldBe` True

  describe "the maximum legal scene" $ do
    it "fits the renderer's configured ring for every batch that can be in flight, and its tables fit the region window" $ do
      configuration ← either (\refused → assertFailure ("configuration: " <> show refused)) pure (configurationFor fixedM1Profile)
      case sceneCapacity fixedM1Profile configuration of
        Left refused → expectationFailure ("the largest legal scene does not fit: " <> show refused)
        Right capacity → do
          capacityInstanceBytes capacity `shouldBe` 4096 * 64
          capacityFits capacity `shouldSatisfy` (>= 2 * capacityBatches capacity)
      -- The renderer's own bound of the tables a 4,096-sprite frame carries, against the configured storage window.
      let sprites = [SceneSprite (TextureUse 1 (TextureView sampleIdentity 1 1)) (SceneRect 0 0 1 1) | _ ← [1 .. 4096 ∷ Int]]
          facts = FrameFacts (4096, 4096) (Just (4096, 4096)) (Just (1, 1))
      case frameCandidate (GraphicsScene (SceneContent (clearOfBytes 0 0 0) sprites) (Set.fromList [sampleIdentity])) facts of
        Left skip → expectationFailure ("the largest scene was skipped: " <> show skip)
        Right (_, valid) → case snapshotTablesBound valid of
          Left refused → expectationFailure ("the frame block is not representable: " <> show refused)
          Right size → size `shouldSatisfy` (<= 3 * 4096 * 16)
  where
    skipped skip = \case Left found → found == skip; Right _ → False
    -- Within one step of the 8-bit value the oracle stores, which is what its own tolerance allows.
    readsAs (Rgba8 r g b a) = \case
      Expected (Rgba8 r' g' b' a') _ → all close [(r, r'), (g, g'), (b, b'), (a, a')]
      _ → False
    close (want, got) = abs (fromIntegral want - fromIntegral got ∷ Int) <= 1
    forM_' xs f = mapM_ f xs

sampleIdentity ∷ Word64
sampleIdentity = textureIdentity (TextureRef 1 1)

-- | An opaque clear from sRGB bytes, in linear light, as a script's clear becomes.
clearOfBytes ∷ Word8 → Word8 → Word8 → ClearColour
clearOfBytes r g b = ClearColour (linearOfByte r) (linearOfByte g) (linearOfByte b) 1

sampleScene ∷ GraphicsScene
sampleScene =
  GraphicsScene
    (SceneContent (clearOfBytes 0 0 0) [SceneSprite (TextureUse 1 (TextureView sampleIdentity 1 1)) (SceneRect 2 1 3 2)])
    (Set.fromList [sampleIdentity])

-- | The sprites, view and clear of a candidate.
spritesOf ∷ Snapshot → Maybe (ClearColour, Viewport, [Instance])
spritesOf = \case
  Snapshot [Pass WindowTarget clear [View _ viewport _ _ [UiLayer instances]]] → Just (clear, viewport, instances)
  _ → Nothing

oracleFor ∷ GraphicsScene → FrameFacts → IO Oracle
oracleFor scene facts = case (frameCandidate scene facts, frameMetrics facts) of
  (Right (_, valid), Right metrics) → do
    image ← red
    let TargetMetrics {metricsFramebuffer = extent} = metrics
        handle = fromBackendHandle (TextureHandle 1 1)
    pure . newOracle $
      OracleInput
        { inputSnapshot = valid
        , inputCutoutMarks = noCutoutMarks
        , inputWindow = Just (TargetSpec metrics R8G8B8A8Srgb extent)
        , inputOffscreen = Map.empty
        , inputTextures = \found → if found == handle then Just image else Nothing
        }
  _ → assertFailure "the frame could not be built for the oracle"

-- | The one-texel red texture the sample scene names.
red ∷ IO DecodedImage
red = case decodePng ColourImage (Asset (AssetId "frames") (FromMemory "a red texel")) (Png.solid 1 1 (255, 0, 0, 255)) of
  Left refusal → assertFailure ("the fixture was refused: " <> show refusal)
  Right image → pure image

