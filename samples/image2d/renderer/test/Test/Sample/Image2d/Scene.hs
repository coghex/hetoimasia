-- | The scene's snapshot and the evidence frame's named probes (R2D-8).
--
-- The probes' colours are recomputed here from the images' region tables and
-- the frame's geometry, in 'Rational's from the sprites' placements in the
-- scene's documentation: where the world copies and the UI copy land, and
-- which texel a pixel centre falls in. A probe whose hand-stated colour
-- disagrees fails here, before the device is involved.
module Test.Sample.Image2d.Scene (spec) where

import Data.List (nub, sort)
import Data.Ratio ((%))
import Hetoimasia.Math.Affine2 (columns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..))
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (validateSnapshot)
import Hetoimasia.Sample.Image2d.Assets (ImageName (..))
import Hetoimasia.Sample.Image2d.Fixtures
import Hetoimasia.Sample.Image2d.Scene
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)

handles ∷ Handles
handles = Handles (textureHandle 1 1) (textureHandle 2 1)

spec ∷ Spec
spec = describe "the scene" $ do
  it "validates, for a window and for an offscreen target, with one pass of one view" $ do
    mapM_
      ( \target → do
          let candidate = snapshotFor target handles evidenceLayout
          either (const False) (const True) (validateSnapshot candidate) `shouldBe` True
          [(passTarget pass, length (passViews pass)) | pass ← snapshotPasses candidate] `shouldBe` [(target, 1)]
      )
      [WindowTarget, OffscreenTarget (targetRef 1 1)]

  it "draws the PNG and the KTX2 image in one world layer and the PNG again in one UI layer" $ do
    let layers = concatMap viewLayers (concatMap passViews (snapshotPasses (snapshotFor WindowTarget handles evidenceLayout)))
    [(isWorld layer, map instanceTexture (layerInstances layer)) | layer ← layers]
      `shouldBe` [(True, [textureHandle 1 1, textureHandle 2 1]), (False, [textureHandle 1 1])]

  it "draws the UI copy at its fixed logical size and the world copies at 64 units, whatever the layout" $
    mapM_
      ( \layout → do
          case concatMap passViews (snapshotPasses (snapshotFor WindowTarget handles layout)) of
            [view] → map (map sizeOf . layerInstances) (viewLayers view) `shouldBe` [[(64, 64), (64, 64)], [(uiLogicalSize, uiLogicalSize)]]
            other → expectationFailure ("expected one view, found " <> show (length other))
      )
      [evidenceLayout, Layout (2560, 1440) 2, Layout (100, 100) 0.5]

  it "puts the layout's UI scale in the view's settings and spans the viewport over its framebuffer" $ do
    case concatMap passViews (snapshotPasses (snapshotFor WindowTarget handles (Layout (640, 480) 3))) of
      [view] → do
        settingUiScale (viewSettings view) `shouldBe` 3
        viewViewport view `shouldBe` Viewport (v 0 0) (v 640 480)
      other → expectationFailure ("expected one view, found " <> show (length other))

  describe "the evidence frame's named probes" $ do
    it "covers the PNG's world copy, its UI copy, the KTX2 copy and the clear background" $
      sort (nub (map probeCovers namedProbes)) `shouldBe` [minBound .. maxBound]

    it "states each probe's colour and its contrast's as the region tables give them through the frame's geometry" $
      [probeBehaviour probe | probe ← namedProbes, geometry (probePixel probe) /= probeColour probe || geometry (probeContrastPixel probe) /= probeContrastColour probe]
        `shouldBe` []

    it "puts no probe within a sixteenth of a texel of a texel boundary, so none is indeterminate for nearest sampling" $
      [probeBehaviour probe | probe ← namedProbes, pixel ← [probePixel probe, probeContrastPixel probe], nearBoundary pixel] `shouldBe` []

    it "contrasts each probe with a different colour" $
      [probeBehaviour probe | probe ← namedProbes, probeColour probe == probeContrastColour probe] `shouldBe` []
  where
    isWorld = \case
      WorldLayer {} → True
      UiLayer {} → False
    v = V2

-- | The colour a pixel of the evidence frame shows, by the frame's geometry,
-- worked out from the region tables.
geometry ∷ (Int, Int) → Colour
geometry (x, y)
  | inside (16, 16) 96 = texel Quadrants ((px - 16) / 1.5, (py - 16) / 1.5)
  | inside (48, 128) 64 = texel Quadrants (px - 48, py - 128)
  | inside (144, 128) 64 = texel Stripes ((px - 144) / 2, (py - 128) / 2)
  | otherwise = backgroundColour
  where
    px = fromIntegral x + 0.5 ∷ Rational
    py = fromIntegral y + 0.5
    inside (x0, y0) size = px >= x0 && px < x0 + size && py >= y0 && py < y0 + size
    texel name (tx, ty) = texelAt (fixture name) (floor tx, floor ty)

-- | Whether the pixel's centre is within a sixteenth of a texel of a texel
-- boundary of the image it lies in. A pixel in no image is not.
nearBoundary ∷ (Int, Int) → Bool
nearBoundary (x, y) = case placement of
  Nothing → False
  Just ((ox, oy), texelsPerPixel) → any near [(px - ox) * texelsPerPixel, (py - oy) * texelsPerPixel]
  where
    px = fromIntegral x + 0.5 ∷ Rational
    py = fromIntegral y + 0.5
    near coordinate = let distance = abs (coordinate - fromIntegral (round coordinate ∷ Integer)) in distance < 1 % 16
    inside (x0, y0) size = px >= x0 && px < x0 + size && py >= y0 && py < y0 + size
    placement
      | inside (16, 16) 96 = Just ((16, 16), 2 % 3)
      | inside (48, 128) 64 = Just ((48, 128), 1)
      | inside (144, 128) 64 = Just ((144, 128), 1 % 2)
      | otherwise = Nothing

-- | A sprite's width and height: the lengths of the transform's two columns,
-- which the scene makes axis-aligned.
sizeOf ∷ Instance → (Float, Float)
sizeOf instanceOf = case columns (instanceTransform instanceOf) of
  (V2 a b, V2 c d, _) → (sqrt (a * a + b * b), sqrt (c * c + d * d))
