{-# LANGUAGE OverloadedStrings #-}

-- | A scene as the renderer's frame, proven against the renderer's own validation, draw plan and
-- oracle, without a GPU, a window or a native effect.
--
-- The oracle computes the pixels the snapshot draws under the renderer's equations, so what these
-- examples show is the CPU semantics of the translation: the approved subset, the order, the blend, the
-- clear, the mapping of the authored rectangles under supplied target metrics. They do not show a
-- displayed pixel; that evidence is a later slice's. Probes sit at pixel centres away from every edge
-- and texel boundary, so none lands in the oracle's indeterminate bands, and an indeterminate answer is
-- a failure here, never a pass.
module Test.LuaEngine.Scene.Render (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64, Word8)
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (TexelRgba8Linear, TexelRgba8Srgb))
import Hetoimasia.LuaEngine.Scene
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (V2))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.DrawPlan (DrawPlan (planPasses), PlannedLayer, PlannedPass (plannedViews), PlannedView (plannedLayers), cutoutMarks, drawingOrder, noCutoutMarks, planSnapshot, plannedRuns)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (PixelExtent), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (R8G8B8A8Srgb, R8G8B8A8Unorm), Rgba8 (Rgba8), Tolerance (Tolerance))
import Hetoimasia.Render.TwoD.Settings (TextureFilter (FilterNearest), ViewSettings (..), ZoomMode (PixelsPerUnit))
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (ValidSnapshot, validateSnapshot)
import Test.Hspec hiding (Expectation)
import Test.LuaEngine.Scene.Support

spec ∷ Spec
spec = describe "the renderer's frame" $ do
  translation
  ordering
  clearing
  pictures
  windows
  chained

-- Fixtures -----------------------------------------------------------------------------------------

-- | The test's own resolution of a backend identity to a handle: the identity is the index, in generation 1.
handleOf ∷ Word64 → Maybe TextureHandle
handleOf identity = Just (textureHandle (fromIntegral identity) 1)

use ∷ Word64 → TextureUse
use identity = TextureUse identity (TextureView identity 2 2)

sprite ∷ Word64 → (Float, Float, Float, Float) → SceneSprite
sprite identity (x, y, w, h) = SceneSprite (use identity) (SceneRect x y w h)

contentOf ∷ ClearColour → [SceneSprite] → SceneContent
contentOf = SceneContent

-- | Target metrics of a square window of this framebuffer extent: logical extent equal to it, scale 1.
square ∷ Int → TargetMetrics
square size = TargetMetrics (PixelExtent size size) (PixelExtent size size) 1 1

candidateOf ∷ TargetMetrics → SceneContent → Snapshot
candidateOf metrics content = either (error . ("candidate refused: " <>) . show) id (sceneCandidate handleOf metrics content)

validOf ∷ TargetMetrics → SceneContent → ValidSnapshot
validOf metrics content = either (error . ("snapshot refused: " <>) . show) id (validateSnapshot (candidateOf metrics content))

-- | An oracle over a window of this format and metrics drawing this content, with these images.
oracleOf ∷ ColourFormat → TargetMetrics → [(Word64, DecodedImage)] → SceneContent → Oracle
oracleOf format metrics images content =
  newOracle
    OracleInput
      { inputSnapshot = validOf metrics content
      , inputCutoutMarks = noCutoutMarks
      , inputWindow = Just (TargetSpec metrics format (metricsFramebuffer metrics))
      , inputOffscreen = Map.empty
      , inputTextures = \handle → lookup handle [(h, image) | (identity, image) ← images, Just h ← [handleOf identity]]
      }

-- | A one-texel image.
solid ∷ Bool → (Word8, Word8, Word8, Word8) → DecodedImage
solid srgb (r, g, b, a) = DecodedImage (if srgb then TexelRgba8Srgb else TexelRgba8Linear) 1 1 [ByteString.pack [r, g, b, a]] False

-- | A 2 by 2 image, row by row.
quad ∷ [(Word8, Word8, Word8, Word8)] → DecodedImage
quad texels = DecodedImage TexelRgba8Linear 2 2 [ByteString.pack (concat [[r, g, b, a] | (r, g, b, a) ← texels])] False

-- | The probe at a pixel, which must be determinate and within the oracle's tolerance, plus a slack, of this value.
shouldDraw ∷ Oracle → (Int, Int) → (Word8, Word8, Word8, Word8) → Int → Expectation'
shouldDraw oracle (x, y) wanted slack = case expect oracle (Probe 0 x y) of
  Expected (Rgba8 r g b a) (Tolerance tr tg tb ta)
    | all id [close r tr (fst4 wanted), close g tg (snd4 wanted), close b tb (thd4 wanted), close a ta (fth4 wanted)] → pure ()
    | otherwise → expectationFailure ("pixel " <> show (x, y) <> " is " <> show (r, g, b, a) <> " ±" <> show (tr, tg, tb, ta) <> ", wanted " <> show wanted)
  other → expectationFailure ("pixel " <> show (x, y) <> " is not determinate: " <> show other)
  where
    close got tolerance want = abs (fromIntegral got - fromIntegral want ∷ Int) <= fromIntegral tolerance + slack
    fst4 (a, _, _, _) = a
    snd4 (_, b, _, _) = b
    thd4 (_, _, c, _) = c
    fth4 (_, _, _, d) = d

type Expectation' = IO ()

-- The translation ----------------------------------------------------------------------------------

translation ∷ Spec
translation = describe "the translation of a scene's content" $ do
  it "is one window pass cleared to the scene's colour, one full-window view with written-out settings, and one UI layer of the sprites in order" $ do
    let clear = ClearColour 0.25 0.5 0.75 1
        sprites = [sprite 1 (1, 2, 3, 4), sprite 2 (-5.5, 6.25, 7, 8), sprite 1 (1, 2, 3, 4)]
    case candidateOf (square 64) (contentOf clear sprites) of
      Snapshot [Pass WindowTarget found [ViewWith {viewCamera = camera, viewViewport = viewport, viewSettings = settings, viewClips = clips, viewFrameTables = tables, viewAnimationTime = time, viewMaterials = materials, viewLayers = [UiLayerWith chunks instances]}]] → do
        found `shouldBe` clear
        camera `shouldBe` Camera (V2 0 0) 1 Nothing
        viewport `shouldBe` Viewport (V2 0 0) (V2 64 64)
        settings `shouldBe` ViewSettings {settingUiScale = 1, settingPixelSnap = False, settingFilter = FilterNearest, settingBrightness = 1, settingZoomMode = PixelsPerUnit}
        (clips, tables, time, Map.null materials, chunks) `shouldBe` ([], [], 0, True, [])
        length instances `shouldBe` 3
        forM_ (zip sprites instances) $ \(one, planted) → do
          let SceneRect x y w h = spriteRect one
          instanceUv planted `shouldBe` UvRect 0 0 1 1
          instanceDepthKey planted `shouldBe` 0
          instanceTint planted `shouldBe` Tint 255 255 255 255
          instanceSampler planted `shouldBe` SamplerDefault
          (instanceTranslucent planted, instanceAdditive planted, instanceClip planted, instanceFrameTable planted, instanceParameter planted) `shouldBe` (False, False, 0, 0, 0)
          instanceTransform planted `shouldBe` fromColumns (V2 w 0) (V2 0 h) (V2 x y)
        map instanceTexture instances `shouldBe` [textureHandle 1 1, textureHandle 2 1, textureHandle 1 1]
      other → expectationFailure ("unexpected frame: " <> show other)

  it "passes the renderer's validation, including boundary rectangles and an empty scene, and carries the initial scene as opaque black with nothing" $ do
    let boundary = [sprite 1 (-1000000, 1000000, 1000000, 1000000), sprite 1 (1000000, -1000000, 0.0625, 0.0625)]
    forM_ [contentOf (ClearColour 0 0 0 1) boundary, contentOf (ClearColour 1 1 1 1) [], initialContent] $ \content →
      validateSnapshot (candidateOf (square 8) content) `shouldSatisfy` either (const False) (const True)
    initialContent `shouldBe` SceneContent (ClearColour 0 0 0 1) []

  it "refuses metrics the renderer cannot map, and an identity nothing resolves, instead of building a frame" $ do
    sceneCandidate handleOf (TargetMetrics (PixelExtent (-1) 8) (PixelExtent 8 8) 1 1) initialContent `shouldBe` Left MetricsUnusable
    sceneCandidate handleOf (TargetMetrics (PixelExtent 8 8) (PixelExtent 8 8) 0 1) initialContent `shouldBe` Left MetricsUnusable
    sceneCandidate handleOf (TargetMetrics (PixelExtent 8 8) (PixelExtent 8 8) 1 (1 / 0)) initialContent `shouldBe` Left MetricsUnusable
    sceneCandidate (const Nothing) (square 8) (contentOf (ClearColour 0 0 0 1) [sprite 7 (0, 0, 1, 1)]) `shouldBe` Left (UnresolvedTexture 7)

  it "hands the complete identity to the caller's resolution, so a stale identity is never read as a newer texture's" $ do
    -- The same lookup index in two generations: only the current identity resolves, to the current handle.
    let current = 2 ^ (32 ∷ Int) + 5
        resolve identity = if identity == current then Just (textureHandle 5 2) else Nothing
        stale = contentOf (ClearColour 0 0 0 1) [sprite 5 (0, 0, 1, 1)]
        fresh = contentOf (ClearColour 0 0 0 1) [sprite current (0, 0, 1, 1)]
    sceneCandidate resolve (square 8) stale `shouldBe` Left (UnresolvedTexture 5)
    case sceneCandidate resolve (square 8) fresh of
      Right (Snapshot [Pass _ _ [ViewWith {viewLayers = [UiLayerWith _ [planted]]}]]) → instanceTexture planted `shouldBe` textureHandle 5 2
      other → expectationFailure ("unexpected frame: " <> show other)

-- Order --------------------------------------------------------------------------------------------

ordering ∷ Spec
ordering = describe "the order" $
  it "is the script's list order for the renderer's plan whatever the cutout marks say, because every sprite has one depth key" $ do
    let sprites = [sprite (fromIntegral n `mod` 3 + 1) (fromIntegral n, 0, 1, 1) | n ← [0 .. 23 ∷ Int]]
        valid = validOf (square 32) (contentOf (ClearColour 0 0 0 1) sprites)
        layersOf marks = [layer | pass ← planPasses (planSnapshot marks valid), planned ← plannedViews pass, layer ← plannedLayers planned]
        handles = [textureHandle i 1 | i ← [1, 2, 3]]
    forM_ [noCutoutMarks, cutoutMarks handles, cutoutMarks (take 1 handles), cutoutMarks (drop 1 handles)] $ \marks → do
      case layersOf marks of
        [layer] → do
          drawingOrder layer `shouldBe` [0 .. 23]
          length (plannedRuns layer) `shouldBe` 1
        other → expectationFailure ("expected one layer, found " <> show (length (other ∷ [PlannedLayer])))

-- The clear ----------------------------------------------------------------------------------------

clearing ∷ Spec
clearing = describe "the clear" $
  it "is an opaque background for an empty scene, and a sprite of the same sRGB grey over black draws the same pixels as the clear" $ do
    let grey = 128
        metrics = square 8
        background = oracleOf R8G8B8A8Srgb metrics [] (contentOf (ClearColour (linearOfByte grey) (linearOfByte grey) (linearOfByte grey) 1) [])
        covered = oracleOf R8G8B8A8Srgb metrics [(1, solid True (grey, grey, grey, 255))] (contentOf (ClearColour 0 0 0 1) [sprite 1 (0, 0, 8, 8)])
    forM_ [(1, 1), (4, 4), (6, 2)] $ \pixel → do
      shouldDraw background pixel (grey, grey, grey, 255) 1
      shouldDraw covered pixel (grey, grey, grey, 255) 1
    -- Byte 128 is not linear one half: that would store as 188 in an sRGB target.
    shouldDraw (oracleOf R8G8B8A8Srgb metrics [] (contentOf (ClearColour 0.5 0.5 0.5 1) [])) (1, 1) (188, 188, 188, 255) 1

-- Pictures -----------------------------------------------------------------------------------------

pictures ∷ Spec
pictures = describe "the pixels" $ do
  it "show the whole image upright with nearest sampling, with the origin at the upper left" $ do
    let red = (255, 0, 0, 255)
        green = (0, 255, 0, 255)
        blue = (0, 0, 255, 255)
        yellow = (255, 255, 0, 255)
        oracle = oracleOf R8G8B8A8Unorm (square 8) [(1, quad [red, green, blue, yellow])] (contentOf (ClearColour 0 0 0 1) [sprite 1 (0, 0, 8, 8)])
    shouldDraw oracle (1, 1) red 1
    shouldDraw oracle (6, 1) green 1
    shouldDraw oracle (1, 6) blue 1
    shouldDraw oracle (6, 6) yellow 1

  it "blend a later sprite over an earlier one with premultiplied alpha, so the list order decides the overlap, and an opaque clear stays opaque" $ do
    let halfRed = (128, 0, 0, 128)
        halfBlue = (0, 0, 128, 128)
        images = [(1, solid False halfRed), (2, solid False halfBlue)]
        clear = ClearColour 0 0 0 1
        redThenBlue = oracleOf R8G8B8A8Unorm (square 8) images (contentOf clear [sprite 1 (0, 0, 5, 5), sprite 2 (3, 3, 5, 5)])
        blueThenRed = oracleOf R8G8B8A8Unorm (square 8) images (contentOf clear [sprite 2 (3, 3, 5, 5), sprite 1 (0, 0, 5, 5)])
    -- Red alone, blue alone, and the overlap with the later one over the earlier one.
    shouldDraw redThenBlue (1, 1) (128, 0, 0, 255) 1
    shouldDraw redThenBlue (6, 6) (0, 0, 128, 255) 1
    shouldDraw redThenBlue (4, 4) (64, 0, 128, 255) 1
    shouldDraw blueThenRed (4, 4) (128, 0, 64, 255) 1
    shouldDraw redThenBlue (7, 0) (0, 0, 0, 255) 1

-- Windows ------------------------------------------------------------------------------------------

windows ∷ Spec
windows = describe "under the target's metrics" $ do
  let red = (255, 0, 0, 255)
      black = (0, 0, 0, 255)
      one rect = contentOf (ClearColour 0 0 0 1) [SceneSprite (use 1) rect]
      drawn metrics rect = oracleOf R8G8B8A8Unorm metrics [(1, solid False red)] (one rect)

  it "place logical pixels from the upper left, keep a fraction, and clip what is negative" $ do
    let fractional = drawn (square 8) (SceneRect 1.25 1.25 2 2)
    -- Pixel centres 1.5 and 2.5 are inside 1.25 to 3.25, 0.5 and 3.5 outside, each a quarter pixel from an edge.
    shouldDraw fractional (1, 1) red 1
    shouldDraw fractional (2, 2) red 1
    shouldDraw fractional (0, 0) black 1
    shouldDraw fractional (3, 3) black 1
    let clipped = drawn (square 8) (SceneRect (-3) (-3) 5 5)
    shouldDraw clipped (0, 0) red 1
    shouldDraw clipped (1, 1) red 1
    shouldDraw clipped (2, 2) black 1
    shouldDraw clipped (5, 5) black 1

  it "convert the content scale: a logical rectangle covers its scaled pixels of the framebuffer" $ do
    let scaled = drawn (TargetMetrics (PixelExtent 8 8) (PixelExtent 16 16) 2 2) (SceneRect 1 1 2 2)
    shouldDraw scaled (2, 2) red 1
    shouldDraw scaled (5, 5) red 1
    shouldDraw scaled (1, 1) black 1
    shouldDraw scaled (6, 6) black 1
    shouldDraw scaled (12, 12) black 1

  it "resize without stretching or recentring: the same content, a larger target, the same rectangle at the same corner, and the new area the clear" $ do
    let content = one (SceneRect 2 2 3 3)
        small' = oracleOf R8G8B8A8Unorm (square 8) [(1, solid False red)] content
        large = oracleOf R8G8B8A8Unorm (square 24) [(1, solid False red)] content
    forM_ [(2, 2), (4, 4), (1, 1), (5, 5), (7, 7)] $ \pixel →
      expect small' (Probe 0 (fst pixel) (snd pixel)) `shouldBe` expect large (Probe 0 (fst pixel) (snd pixel))
    shouldDraw large (12, 12) black 1
    shouldDraw large (20, 4) black 1
    candidateOf (square 24) content `shouldNotBe` candidateOf (square 8) content

  it "suspend drawing at a zero framebuffer extent without invalidating the scene, and draw again when the extent returns" $ do
    let metrics = TargetMetrics (PixelExtent 0 0) (PixelExtent 0 0) 1 1
        content = one (SceneRect 0 0 4 4)
        valid = validOf metrics content
        runsOf v = [length (plannedRuns layer) | pass ← planPasses (planSnapshot noCutoutMarks v), planned ← plannedViews pass, layer ← plannedLayers planned]
    runsOf valid `shouldBe` [0]
    runsOf (validOf (square 8) content) `shouldBe` [1]
    -- The scene is the same content throughout; nothing in it knew the extent.
    content `shouldBe` one (SceneRect 0 0 4 4)

-- From Lua to pixels -------------------------------------------------------------------------------

chained ∷ Spec
chained = describe "a scene a script published" $
  it "is drawn, by the oracle, from the real decoded texels of a real PNG: the same grey as the clear, from its prepared content alone" $ do
    sink ← newSink
    withSession (sceneConfig (sceneProfile [] []) layout sink) $ \session _ runtime → do
      vm ← startVm session runtime "chain" OnArrival
      admitDriver session vm "i"
      identity ← acquire session vm "i" "g" "grey.png"
      held ← uploadN (ssFake session) 0
      let upload = heldUpload held
          image = DecodedImage TexelRgba8Srgb (fromIntegral (uploadWidth upload) ∷ Word32) (fromIntegral (uploadHeight upload)) [uploadTexels upload] False
      evalOk
        session
        vm
        "i"
        "k1"
        "scene.publish({clear = {r = 0, g = 0, b = 0}, sprites = {{texture = self.ts.g, x = 0, y = 0, width = 8, height = 8}}}) return 'ok'"
        "ok"
      evalOk session vm "i" "k2" "scene.publish({clear = {r = 128, g = 128.0, b = 128}, sprites = {}}) return 'ok'" "ok"
      [textured, plain] ← map preparedContent <$> published sink
      let metrics = square 8
          drawing content = oracleOf R8G8B8A8Srgb metrics [(identity, image)] content
      forM_ [(2, 2), (5, 5)] $ \pixel → do
        shouldDraw (drawing textured) pixel (128, 128, 128, 255) 1
        shouldDraw (drawing plain) pixel (128, 128, 128, 255) 1
