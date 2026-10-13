-- | Depth: the cutout path, the depth test and the cutout variant (R2D-9).
--
-- Every expectation is worked on paper from the README's depth model:
--
-- * a depth key @k@ is the depth @(2²⁴ − 1 − k) / 2²⁴@, a larger key nearer;
-- * a depth-enabled layer clears depth to 1.0 within its viewport, then its
--   cutouts run (discard below an alpha of ½, else write the un-premultiplied
--   colour with alpha 1, tested less-or-equal and written), then its ordered
--   instances (tested less-or-equal, not written);
-- * the cutout variant's alpha, before brightness, is indeterminate within
--   2/255 of ½, that is for 8-bit alphas 126 to 129.
--
-- The target is an 8 × 8 UNORM one, a pixel at (4, 4) is covered by a unit
-- sprite at the world origin, and every texture is one linear texel.
module Test.Render.TwoD.Oracle.Depth (spec) where

import qualified Data.Map.Strict as Map
import Data.Word (Word32)
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.DrawPlan (cutoutMarks, noCutoutMarks)
import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (Location (..))
import Test.Hspec hiding (Expectation)
import Test.Render.TwoD.Oracle.Support

-- | An oracle over one view of these layers, every texture marked cutout.
over ∷ [(TextureHandleName, Rgba)] → [Layer] → Oracle
over textures layers = overView textures defaultViewSettings layers

overView ∷ [(TextureHandleName, Rgba)] → ViewSettings → [Layer] → Oracle
overView textures settings layers =
  mkOracleFull
    (cutoutMarks (map (handleOfName . fst) textures))
    Nothing
    (Map.singleton offscreenRef unorm8)
    [(handleOfName name, solid False colour) | (name, colour) ← textures]
    [offscreenPass noClear [mkView defaultCamera (fullViewport 8 8) settings layers]]

data TextureHandleName = A | B | C
  deriving (Eq)

handleOfName ∷ TextureHandleName → TextureHandle
handleOfName = \case
  A → h1
  B → h2
  C → h3

-- | The expectation's value, if it is determinate.
valueAt ∷ Oracle → Int → Int → Maybe Rgba8
valueAt oracle x y = case expectAt oracle x y of
  Expected value _ → Just value
  _ → Nothing

keyed ∷ Word32 → Instance → Instance
keyed key candidate = candidate {instanceDepthKey = key}

translucent ∷ Instance → Instance
translucent candidate = candidate {instanceTranslucent = True}

-- | A unit sprite of a texture over pixel (4, 4).
cell ∷ TextureHandleName → Instance
cell name = spriteAt (handleOfName name) (0, 0)

depth ∷ [Instance] → Layer
depth = WorldLayer DepthEnabled

spec ∷ Spec
spec = describe "depth" $ do
  describe "the cutout variant" $ do
    it "writes an opaque texel as it is, with alpha 1" $
      valueAt (over [(A, (200, 100, 50, 255))] [depth [cell A]]) 4 4 `shouldBe` Just (Rgba8 200 100 50 255)

    it "discards below an alpha of one half and leaves the clear" $
      valueAt (over [(A, (200, 100, 50, 100))] [depth [cell A]]) 4 4 `shouldBe` Just (Rgba8 0 0 0 0)

    it "is indeterminate for alphas 126 to 129 and determinate either side" $ do
      let at alpha = expectAt (over [(A, (200, 100, 50, alpha))] [depth [cell A]]) 4 4
      map (\alpha → isIndeterminate (at alpha)) [125, 126, 127, 128, 129, 130] `shouldBe` [False, True, True, True, True, False]
      at 126 `shouldBe` Indeterminate (NearCutoutThreshold (AtInstance 0 0 0 0))
      valueAt (over [(A, (200, 100, 50, 125))] [depth [cell A]]) 4 4 `shouldBe` Just (Rgba8 0 0 0 0)
      -- Past the band it survives, un-premultiplied: 200 over 130 clamps, 100/130 and 50/130 do not.
      valueAt (over [(A, (200, 100, 50, 130))] [depth [cell A]]) 4 4 `shouldBe` Just (Rgba8 255 196 98 255)

    it "writes a (0.6, 0.6, 0.6, 0.6) sample as white, not grey" $
      valueAt (over [(A, (153, 153, 153, 153))] [depth [cell A]]) 4 4 `shouldBe` Just (Rgba8 255 255 255 255)

    it "un-premultiplies a colour by its own alpha" $
      -- 150 over alpha 200 is 0.75 of full, 191.25; 70 over 200 is 0.35, 89.25.
      valueAt (over [(A, (150, 70, 0, 200))] [depth [cell A]]) 4 4 `shouldBe` Just (Rgba8 191 89 0 255)

    it "multiplies the tint's colour before un-premultiplying, then brightens" $ do
      -- (100, 200, 0, 255) tinted (255, 128, 255) is (100, 100.4, 0); brightness 0.5 halves it.
      let tinted = (cell A) {instanceTint = Tint 255 128 255 255}
          settings = defaultViewSettings {settingBrightness = 0.5}
      valueAt (overView [(A, (100, 200, 0, 255))] settings [depth [tinted]]) 4 4 `shouldBe` Just (Rgba8 50 50 0 255)

    it "applies brightness after un-premultiplying" $ do
      let settings = defaultViewSettings {settingBrightness = 0.5}
      -- 100/153 = 0.6536 and 200/153 = 1.3072, which clamps before it is halved?
      -- No: brightness scales the un-premultiplied colour, then the store clamps.
      valueAt (overView [(A, (100, 200, 0, 153))] settings [depth [cell A]]) 4 4 `shouldBe` Just (Rgba8 83 167 0 255)

  describe "the depth test" $ do
    it "lets a larger key win whatever the submission order" $ do
      let layer first second = depth [keyed first (cell A), keyed second (cell B)]
          textures = [(A, (255, 0, 0, 255)), (B, (0, 255, 0, 255))]
      valueAt (over textures [layer 5 9]) 4 4 `shouldBe` Just (Rgba8 0 255 0 255)
      valueAt (over textures [layer 9 5]) 4 4 `shouldBe` Just (Rgba8 255 0 0 255)

    it "lets the later draw win among cutouts of an equal key" $ do
      let textures = [(A, (255, 0, 0, 255)), (B, (0, 255, 0, 255))]
      valueAt (over textures [depth [keyed 7 (cell A), keyed 7 (cell B)]]) 4 4 `shouldBe` Just (Rgba8 0 255 0 255)
      valueAt (over textures [depth [keyed 7 (cell B), keyed 7 (cell A)]]) 4 4 `shouldBe` Just (Rgba8 255 0 0 255)

    it "draws a translucent instance over a cutout of an equal key" $ do
      -- Half red over opaque green: red 255, green 127, alpha 255.
      let textures = [(A, (0, 255, 0, 255)), (B, (255, 255, 255, 255))]
          half = (translucent (keyed 7 (cell B))) {instanceTint = Tint 255 0 0 128}
      valueAt (over textures [depth [half, keyed 7 (cell A)]]) 4 4 `shouldBe` Just (Rgba8 255 127 0 255)

    it "interleaves cutouts and translucent instances in one layer: the nearer translucent blends, the farther is hidden" $ do
      -- Submitted translucent, cutout, translucent, cutout; the plan draws both
      -- cutouts first, then the translucent ones back to front.
      let textures = [(A, (0, 255, 0, 255)), (B, (255, 255, 255, 255))]
          half key x = (translucent (keyed key (spriteAt h2 (x, 0)))) {instanceTint = Tint 255 0 0 128}
          oracle = over textures [depth [half 20 0, keyed 10 (spriteAt h1 (0, 0)), half 10 1, keyed 20 (spriteAt h1 (1, 0))]]
      valueAt oracle 4 4 `shouldBe` Just (Rgba8 255 127 0 255)
      valueAt oracle 5 4 `shouldBe` Just (Rgba8 0 255 0 255)

    it "hides a translucent instance behind a cutout and shows one in front of it" $ do
      let textures = [(A, (0, 255, 0, 255)), (B, (255, 255, 255, 255))]
          half key = (translucent (keyed key (cell B))) {instanceTint = Tint 255 0 0 128}
      valueAt (over textures [depth [keyed 7 (cell A), half 6]]) 4 4 `shouldBe` Just (Rgba8 0 255 0 255)
      valueAt (over textures [depth [keyed 7 (cell A), half 8]]) 4 4 `shouldBe` Just (Rgba8 255 127 0 255)

    it "leaves a discarded fragment's depth unwritten, so farther art shows through it" $ do
      -- The nearer cutout is submitted first and is transparent over the pixel.
      let textures = [(A, (255, 0, 0, 0)), (B, (0, 255, 0, 255))]
      valueAt (over textures [depth [keyed 9 (cell A), keyed 2 (cell B)]]) 4 4 `shouldBe` Just (Rgba8 0 255 0 255)

    it "compares an exact depth at the ends of the key range" $ do
      let textures = [(A, (255, 0, 0, 255)), (B, (0, 255, 0, 255))]
          top = 16777215
      valueAt (over textures [depth [keyed top (cell A), keyed (top - 1) (cell B)]]) 4 4 `shouldBe` Just (Rgba8 255 0 0 255)
      valueAt (over textures [depth [keyed 1 (cell A), keyed 0 (cell B)]]) 4 4 `shouldBe` Just (Rgba8 255 0 0 255)
      valueAt (over textures [depth [keyed 0 (cell A), keyed 1 (cell B)]]) 4 4 `shouldBe` Just (Rgba8 0 255 0 255)

  describe "layers" $ do
    it "starts each depth-enabled layer from its own clear, so keys are independent between layers" $ do
      let textures = [(A, (255, 0, 0, 255)), (B, (0, 255, 0, 255))]
      -- The second layer's far key still draws over the first layer's near one.
      valueAt (over textures [depth [keyed 100 (cell A)], depth [keyed 1 (cell B)]]) 4 4 `shouldBe` Just (Rgba8 0 255 0 255)

    it "neither tests nor writes in a world layer without depth or in a UI layer" $ do
      let textures = [(A, (255, 0, 0, 255)), (B, (0, 255, 0, 255))]
      valueAt (over textures [depth [keyed 100 (cell A)], WorldLayer DepthDisabled [keyed 1 (cell B)]]) 4 4 `shouldBe` Just (Rgba8 0 255 0 255)
      valueAt (over textures [depth [keyed 100 (cell A)], UiLayer [keyed 1 (spriteAt h2 (4, 4))]]) 4 4 `shouldBe` Just (Rgba8 0 255 0 255)
      -- Marked art in a layer without depth takes the ordered path, in key order.
      valueAt (over textures [WorldLayer DepthDisabled [keyed 100 (cell A), keyed 1 (cell B)]]) 4 4 `shouldBe` Just (Rgba8 255 0 0 255)

    it "routes only marked, opaque, non-translucent art to the cutout path" $ do
      -- Unmarked art in a depth layer is ordered: it draws in key order and is
      -- tested against the cutouts.
      let unmarked = mkOracleFull (cutoutMarks [h1]) Nothing (Map.singleton offscreenRef unorm8) [(h1, solid False (255, 0, 0, 255)), (h2, solid False (0, 255, 0, 255))]
          oracle = unmarked [offscreenPass noClear [fullView 8 8 [depth [keyed 5 (cell A), keyed 9 (cell B)]]]]
      -- B is ordered, drawn after the cutout A, tested against its depth: the nearer B shows.
      valueAt oracle 4 4 `shouldBe` Just (Rgba8 0 255 0 255)
      let farther = unmarked [offscreenPass noClear [fullView 8 8 [depth [keyed 9 (cell A), keyed 5 (cell B)]]]]
      -- B is farther than the cutout A and fails the test.
      valueAt farther 4 4 `shouldBe` Just (Rgba8 255 0 0 255)

    it "draws every instance ordered when nothing is marked" $ do
      let oracle =
            mkOracleFull noCutoutMarks Nothing (Map.singleton offscreenRef unorm8) [(h1, solid False (255, 0, 0, 255)), (h2, solid False (0, 255, 0, 255))] $
              [offscreenPass noClear [fullView 8 8 [depth [keyed 9 (cell A), keyed 5 (cell B)]]]]
      -- Ordered, back to front: key 5 first, then key 9 over it.
      valueAt oracle 4 4 `shouldBe` Just (Rgba8 255 0 0 255)

  describe "textures" $ do
    it "writes a linearly filtered edge sample white, not grey" $ do
      -- Two texels, transparent black then opaque white, under a ten-pixel
      -- sprite from pixel 0: pixel 5's centre is at u = 0.55, weight 0.6 of white,
      -- so the sample is (0.6, 0.6, 0.6, 0.6).
      let edge = rgba8 False 2 1 [[0, 0, 0, 0, 255, 255, 255, 255]]
          sprite' = (sprite h1 (-4, 0) (10, 1)) {instanceSampler = SamplerLinear}
          oracle = mkOracleFull (cutoutMarks [h1]) Nothing (Map.singleton offscreenRef unorm8) [(h1, edge)] [offscreenPass noClear [fullView 8 8 [depth [sprite']]]]
      valueAt oracle 5 4 `shouldBe` Just (Rgba8 255 255 255 255)
      -- Where the weight is below a half, the fragment is discarded.
      valueAt oracle 3 4 `shouldBe` Just (Rgba8 0 0 0 0)

    it "reads the mip level a minified cutout selects, not level zero" $ do
      -- Level 0 holds one opaque texel in four, so a level-0 sample has a
      -- coverage of a quarter and is discarded; level 1, which a 2:1 minified
      -- probe reads, is opaque.
      let green = [0, 255, 0, 255]
          level0 = green <> replicate 12 0
          mipped = rgba8 False 2 2 [level0, green]
          single = (sprite h1 (0, 0) (1, 1)) {instanceSampler = SamplerLinear}
          oracle = mkOracleFull (cutoutMarks [h1]) Nothing (Map.singleton offscreenRef unorm8) [(h1, mipped)] [offscreenPass noClear [fullView 8 8 [depth [single]]]]
          levelZero = mkOracleFull (cutoutMarks [h1]) Nothing (Map.singleton offscreenRef unorm8) [(h1, rgba8 False 2 2 [level0])] [offscreenPass noClear [fullView 8 8 [depth [single]]]]
      valueAt oracle 4 4 `shouldBe` Just (Rgba8 0 255 0 255)
      valueAt levelZero 4 4 `shouldBe` Just (Rgba8 0 0 0 0)

    it "samples the placeholder for a marked handle the lookup does not know, which is discarded" $ do
      let oracle = mkOracleFull (cutoutMarks [h1]) Nothing (Map.singleton offscreenRef unorm8) [] [offscreenPass noClear [fullView 8 8 [depth [cell A]]]]
      valueAt oracle 4 4 `shouldBe` Just (Rgba8 0 0 0 0)

  describe "what stays indeterminate" $ do
    it "reports a cutout quad's edge like any other quad's" $ do
      let oracle = over [(A, (255, 0, 0, 255))] [depth [spriteAt h1 (0.45, 0)]]
      expectAt oracle 4 4 `shouldBe` Indeterminate (NearQuadEdge (AtInstance 0 0 0 0))

    it "reports a filtered alpha near the threshold even when a nearer cutout hides it" $ do
      let textures = [(A, (200, 100, 50, 128)), (B, (0, 255, 0, 255))]
      isIndeterminate (expectAt (over textures [depth [keyed 1 (cell A), keyed 9 (cell B)]]) 4 4) `shouldBe` True

isIndeterminate ∷ Expectation → Bool
isIndeterminate = \case
  Indeterminate _ → True
  _ → False

