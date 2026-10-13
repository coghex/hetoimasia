-- | Probes: targets, passes, indeterminate cases and refusals.
--
-- A probe is answered with a value, with a reason the oracle declines to
-- guess, or with the input defect that stops it. These examples cover each
-- reason and each defect, at its boundary, and show that a defect is never
-- mistaken for a placeholder or a clear.
module Test.Render.TwoD.Oracle.Probes (spec) where

import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.Render.TwoD.DrawPlan (cutoutMarks, noCutoutMarks)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..), offscreenMetrics)
import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (..), Rgba8 (..), Tolerance (..))
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (Location (..))
import Test.Hspec hiding (Expectation)
import Test.Render.TwoD.Oracle.Support

world ∷ [Instance] → Layer
world = WorldLayer DepthDisabled

red ∷ Rgba
red = (255, 0, 0, 255)

clearAt ∷ Expectation
clearAt = Expected (Rgba8 0 0 0 0) (Tolerance 0 0 0 0)

inst ∷ Location
inst = AtInstance 0 0 0 0

-- | A texture that is not a well-formed image, for each way it can fail.
broken ∷ TexelFormat → Int → Int → [Int] → DecodedImage
broken format width height sizes =
  DecodedImage
    { decodedFormat = format
    , decodedWidth = fromIntegral width
    , decodedHeight = fromIntegral height
    , decodedLevels = [ByteString.replicate size 255 | size ← sizes]
    , decodedBinaryAlpha = False
    }

-- | An oracle whose one sprite, over the whole target, uses this texture.
withTexture ∷ DecodedImage → Oracle
withTexture image =
  mkOracle unorm8 [(h1, image)] [offscreenPass noClear [fullView 8 8 [world [sprite h1 (-4, -4) (8, 8)]]]]

spec ∷ Spec
spec = describe "probes" $ do
  describe "indeterminate probes" $ do
    it "reports a centre within 1/16 pixel of a quad's edge, and no other" $ do
      -- The quad covers [4.45, 6.45]: 0.05 pixel from the centre of pixel 4 and
      -- of pixel 6, and a clear 1.05 from the centre of pixel 5.
      let oracle = mkOracle srgb8 [(h1, solid True red)] [offscreenPass noClear [fullView 8 8 [world [sprite h1 (0.45, 0) (2, 1)]]]]
      expectAt oracle 4 4 `shouldBe` Indeterminate (NearQuadEdge inst)
      expectAt oracle 6 4 `shouldBe` Indeterminate (NearQuadEdge inst)
      expectAt oracle 5 4 `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)
      expectAt oracle 3 4 `shouldBe` clearAt

    it "reports the same centre when it is 1/16 away and not when it is farther" $ do
      -- The edge at 4.4375 is exactly 1/16 from the centre; 4.4 is 0.1 away.
      let at x = mkOracle srgb8 [(h1, solid True red)] [offscreenPass noClear [fullView 8 8 [world [spriteAt h1 (x, 0)]]]]
      expectAt (at 0.4375) 4 4 `shouldBe` Indeterminate (NearQuadEdge inst)
      expectAt (at 0.4) 4 4 `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)

    it "reports a centre within 1/16 pixel of a viewport edge that is not on a whole pixel" $ do
      let oracle =
            mkOracle srgb8 [(h1, solid True red)] $
              [offscreenPass noClear [mkView defaultCamera (Viewport (V2 0 0) (V2 4.45 8)) defaultViewSettings [world [sprite h1 (-4, -4) (8, 8)]]]]
      expectAt oracle 4 4 `shouldBe` Indeterminate (NearViewportEdge (AtView 0 0))
      expectAt oracle 3 4 `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)
      expectAt oracle 5 4 `shouldBe` clearAt

    it "reports a viewport edge near the centre whether or not the view draws anything" $ do
      let oracle =
            mkOracle srgb8 [] [offscreenPass noClear [mkView defaultCamera (Viewport (V2 0 0) (V2 4.45 8)) defaultViewSettings [world []]]]
      expectAt oracle 4 4 `shouldBe` Indeterminate (NearViewportEdge (AtView 0 0))
      expectAt oracle 3 4 `shouldBe` clearAt

    it "finds a viewport edge near the centre of a huge finite viewport" $ do
      -- Double arithmetic would lose the centre's offset from an edge 0.05 pixel
      -- away when the viewport spans 2e20 pixels; the distance is exact.
      let oracle =
            mkOracle srgb8 [] [offscreenPass noClear [mkView defaultCamera (Viewport (V2 0.45 (-1.0e20)) (V2 4 2.0e20)) defaultViewSettings [world []]]]
      expectAt oracle 0 0 `shouldBe` Indeterminate (NearViewportEdge (AtView 0 0))

    it "does not report an empty viewport's edges, which draw nothing" $ do
      let oracle =
            mkOracle srgb8 [(h1, solid True red)] [offscreenPass noClear [mkView defaultCamera (Viewport (V2 0 0) (V2 0 8)) defaultViewSettings [world [sprite h1 (-4, -4) (8, 8)]]]]
      expectAt oracle 0 4 `shouldBe` clearAt

    it "draws a cutout-path instance, and reports its edge like any quad's" $ do
      let marks = cutoutMarks [h1]
          cutout = spriteAt h1 (0, 0)
          at layer = mkOracleFull marks Nothing (Map.singleton offscreenRef srgb8) [(h1, solid True red)] [offscreenPass noClear [fullView 8 8 [layer]]]
      expectAt (at (WorldLayer DepthEnabled [cutout])) 4 4 `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)
      -- A pixel the instance does not reach is unaffected.
      expectAt (at (WorldLayer DepthEnabled [cutout])) 6 6 `shouldBe` clearAt
      -- Near its edge it could cover the probe or not.
      expectAt (at (WorldLayer DepthEnabled [spriteAt h1 (0.45, 0)])) 4 4 `shouldBe` Indeterminate (NearQuadEdge inst)
      -- Without depth, or translucent, or in UI, it takes the ordered path.
      expectAt (at (WorldLayer DepthDisabled [cutout])) 4 4 `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)
      expectAt (at (WorldLayer DepthEnabled [cutout {instanceTranslucent = True}])) 4 4 `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)
      expectAt (at (WorldLayer DepthEnabled [cutout {instanceTint = Tint 255 255 255 254}])) 4 4 `shouldSatisfy` isExpected
      expectAt (at (UiLayer [spriteAt h1 (4, 4)])) 4 4 `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)

    it "draws an unmarked texture in a depth-enabled layer on the ordered path" $ do
      let oracle =
            mkOracleFull noCutoutMarks Nothing (Map.singleton offscreenRef srgb8) [(h1, solid True red)] $
              [offscreenPass noClear [fullView 8 8 [WorldLayer DepthEnabled [spriteAt h1 (0, 0)]]]]
      expectAt oracle 4 4 `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)

    it "reports a nearest coordinate on a boundary between unlike texels, not alike ones" $ do
      let unlike = rgba8 True 2 1 [[255, 0, 0, 255, 0, 0, 255, 255]]
          alike = rgba8 True 2 1 [[255, 0, 0, 255, 255, 0, 0, 255]]
          at image = mkOracle srgb8 [(h1, image)] [offscreenPass noClear [fullView 8 8 [world [sprite h1 (-3.5, -1) (2, 1)]]]]
      -- Pixel 1's centre is exactly on the boundary between the two texels.
      expectAt (at unlike) 1 3 `shouldBe` Indeterminate (NearTexelBoundary inst)
      expectAt (at alike) 1 3 `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)

    it "prefers a refusal to an indeterminacy" $ do
      let huge = (spriteAt h1 (0, 0)) {instanceTransform = fromColumns (V2 3.0e38 0) (V2 0 3.0e38) (V2 0 0)}
          oracle =
            mkOracle srgb8 [(h1, solid True red)] $
              [offscreenPass noClear [mkView (Camera (V2 0 0) 10 Nothing) (fullViewport 8 8) defaultViewSettings [world [spriteAt h1 (0.045, 0), huge]]]]
      expectAt oracle 4 4 `shouldBe` Unevaluable (PlacementNotRepresentable (AtInstance 0 0 0 1))

  describe "targets" $ do
    it "selects each pass's own target, in its own format" $ do
      let image = solid True (128, 64, 255, 255)
          window = targetSpec B8G8R8A8Srgb 8 8
          oracle =
            mkOracleFull noCutoutMarks (Just window) (Map.singleton offscreenRef unorm8) [(h1, image)] $
              [ offscreenPass noClear [fullView 8 8 [world [spriteAt h1 (0, 0)]]]
              , Pass WindowTarget noClear [fullView 8 8 [world [spriteAt h1 (0, 0)]]]
              ]
      -- The same sRGB texel is stored linear in the UNORM target and carried in
      -- the sRGB window, and both report in RGBA order.
      expect oracle (Probe 0 4 4) `shouldBe` Expected (Rgba8 55 13 255 255) (Tolerance 1 1 0 0)
      expect oracle (Probe 1 4 4) `shouldBe` Expected (Rgba8 128 64 255 255) (Tolerance 0 0 0 0)

    it "keeps each pass's expectation when passes clear the same target" $ do
      let oracle =
            mkOracle srgb8 [(h1, solid True red)] $
              [ offscreenPass (ClearColour 0 0 0 0) [fullView 8 8 [world [spriteAt h1 (0, 0)]]]
              , offscreenPass (ClearColour 0 0 1 1) [fullView 8 8 []]
              ]
      expect oracle (Probe 0 4 4) `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)
      expect oracle (Probe 1 4 4) `shouldBe` Expected (Rgba8 0 0 255 255) (Tolerance 0 0 0 0)
      expect oracle (Probe 0 0 0) `shouldBe` clearAt

    it "refuses a pass that is not in the snapshot, at both ends" $ do
      let oracle = mkOracle srgb8 [] [offscreenPass noClear [fullView 8 8 []]]
      expect oracle (Probe 1 0 0) `shouldBe` Unevaluable (PassOutOfRange 1)
      expect oracle (Probe (-1) 0 0) `shouldBe` Unevaluable (PassOutOfRange (-1))
      expect oracle (Probe 0 0 0) `shouldBe` clearAt

    it "refuses a pixel outside its target, at each edge" $ do
      let oracle = mkOracle srgb8 [] [offscreenPass noClear [fullView 8 8 []]]
      expect oracle (Probe 0 8 0) `shouldBe` Unevaluable (PixelOutsideTarget 8 0)
      expect oracle (Probe 0 0 8) `shouldBe` Unevaluable (PixelOutsideTarget 0 8)
      expect oracle (Probe 0 (-1) 0) `shouldBe` Unevaluable (PixelOutsideTarget (-1) 0)
      expect oracle (Probe 0 0 (-1)) `shouldBe` Unevaluable (PixelOutsideTarget 0 (-1))
      expect oracle (Probe 0 7 7) `shouldBe` clearAt

    it "refuses every pixel of a zero-extent target" $ do
      let oracle = mkOracle (targetSpec R8G8B8A8Srgb 0 0) [] [offscreenPass noClear [fullView 0 0 []]]
      expect oracle (Probe 0 0 0) `shouldBe` Unevaluable (PixelOutsideTarget 0 0)

    it "refuses a pass whose target has no metadata" $ do
      let window = mkOracleFull noCutoutMarks Nothing Map.empty [] [Pass WindowTarget noClear [fullView 8 8 []]]
          missing = mkOracleFull noCutoutMarks Nothing Map.empty [] [offscreenPass noClear [fullView 8 8 []]]
      expect window (Probe 0 0 0) `shouldBe` Unevaluable (MissingTarget WindowTarget)
      expect missing (Probe 0 0 0) `shouldBe` Unevaluable (MissingTarget (OffscreenTarget offscreenRef))

    it "refuses invalid metrics, whatever they are" $ do
      let with metrics reported = mkOracle (TargetSpec metrics R8G8B8A8Srgb reported) [] [offscreenPass noClear [fullView 8 8 []]]
          extent = PixelExtent 8 8
          valid = offscreenMetrics extent
          refused metrics = expect (with metrics extent) (Probe 0 0 0) `shouldBe` Unevaluable (InvalidMetrics (OffscreenTarget offscreenRef))
      refused valid {metricsScaleX = 0}
      refused valid {metricsScaleY = -1}
      refused valid {metricsScaleX = 0 / 0}
      refused valid {metricsScaleX = 1 / 0}
      refused valid {metricsLogical = PixelExtent (-1) 8}
      let negative = PixelExtent (-1) 8
      expect (with (offscreenMetrics negative) negative) (Probe 0 0 0) `shouldBe` Unevaluable (InvalidMetrics (OffscreenTarget offscreenRef))

    it "refuses a pixel extent that disagrees with the metrics' framebuffer extent" $ do
      let oracle = mkOracle (TargetSpec (offscreenMetrics (PixelExtent 8 8)) R8G8B8A8Srgb (PixelExtent 8 4)) [] [offscreenPass noClear [fullView 8 8 []]]
      expect oracle (Probe 0 0 0) `shouldBe` Unevaluable (ExtentDisagrees (OffscreenTarget offscreenRef))

    it "refuses a target beyond 2^23 pixels, where a pixel centre is not a Float" $ do
      let oracle = mkOracle (targetSpec R8G8B8A8Srgb 8388609 1) [] [offscreenPass noClear [fullView 8 8 []]]
          edge = mkOracle (targetSpec R8G8B8A8Srgb 8388608 1) [] [offscreenPass noClear [fullView 8 8 []]]
      expect oracle (Probe 0 0 0) `shouldBe` Unevaluable (TargetTooLarge (OffscreenTarget offscreenRef))
      expect edge (Probe 0 8388607 0) `shouldBe` clearAt

  describe "malformed textures" $ do
    let faulty image = expectAt (withTexture image) 4 4

    it "refuses an extent of zero" $ do
      faulty (broken TexelRgba8Linear 0 4 [0]) `shouldBe` Unevaluable (MalformedImage inst h1 ZeroExtent)
      faulty (broken TexelRgba8Linear 4 0 [0]) `shouldBe` Unevaluable (MalformedImage inst h1 ZeroExtent)

    it "refuses no levels, and more levels than the chain has" $ do
      faulty (broken TexelRgba8Linear 2 2 []) `shouldBe` Unevaluable (MalformedImage inst h1 (LevelCountInvalid 0))
      -- 2 × 2 has two levels, 2 × 2 then 1 × 1.
      faulty (broken TexelRgba8Linear 2 2 [16, 4, 4]) `shouldBe` Unevaluable (MalformedImage inst h1 (LevelCountInvalid 3))

    it "refuses a level of the wrong size, naming it" $ do
      faulty (broken TexelRgba8Linear 2 2 [15]) `shouldBe` Unevaluable (MalformedImage inst h1 (LevelSizeWrong 0))
      faulty (broken TexelRgba8Linear 2 2 [16, 5]) `shouldBe` Unevaluable (MalformedImage inst h1 (LevelSizeWrong 1))
      faulty (broken TexelBc7Linear 4 4 [15]) `shouldBe` Unevaluable (MalformedImage inst h1 (LevelSizeWrong 0))

    it "checks sizes without wrapping, for an extent near 2^32" $ do
      faulty (broken TexelRgba8Srgb 4294967295 4294967295 [4]) `shouldBe` Unevaluable (MalformedImage inst h1 (LevelSizeWrong 0))
      faulty (broken TexelBc7Srgb 4294967295 4294967295 [16]) `shouldBe` Unevaluable (MalformedImage inst h1 (LevelSizeWrong 0))

    it "never takes a present image for the absent-handle placeholder" $ do
      let absent = expectAt (mkOracle unorm8 [] [offscreenPass noClear [fullView 8 8 [world [sprite h1 (-4, -4) (8, 8)]]]]) 4 4
      absent `shouldBe` clearAt
      faulty (broken TexelRgba8Linear 2 2 [15]) `shouldNotBe` absent

    it "ignores a malformed texture no covering instance samples" $ do
      let oracle = mkOracle unorm8 [(h1, broken TexelRgba8Linear 2 2 [15])] [offscreenPass noClear [fullView 8 8 [world [spriteAt h1 (0, 0)]]]]
      expectAt oracle 4 4 `shouldBe` Unevaluable (MalformedImage inst h1 (LevelSizeWrong 0))
      expectAt oracle 0 0 `shouldBe` clearAt

  describe "purity" $
    it "gives the same expectations for the same inputs" $ do
      let build = mkOracle srgb8 [(h1, solid True red)] [offscreenPass noClear [fullView 8 8 [world [sprite h1 (0.45, 0.3) (2.7, 1.9)]]]]
          pictureOf oracle = picture oracle 0 (8, 8) palette
      pictureOf build `shouldBe` pictureOf build
      [expectAt build x y | x ← [0 .. 7], y ← [0 .. 7]] `shouldBe` [expectAt build x y | x ← [0 .. 7], y ← [0 .. 7]]
  where
    isExpected (Expected _ _) = True
    isExpected _ = False
