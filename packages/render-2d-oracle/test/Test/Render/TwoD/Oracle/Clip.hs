-- | Clipping (design D-11, R2D-12): the oracle applies each view's resolved clip
-- table.
--
-- Every expectation is worked on paper from the README's clip model:
--
-- * an instance with clip index @k > 0@ draws only where the pixel centre,
--   carried back to the layer's space, lies in the half-open resolved rectangle
--   of entry @k − 1@; elsewhere it gives nothing, colour or depth;
-- * a centre within 1/16 pixel, in target pixels, of the clip's boundary after
--   transformation is indeterminate for an instance that could draw there;
-- * an empty clip holds no point and has no boundary.
--
-- The target is an 8 × 8 UNORM one (a pixel's centre is at its index plus ½)
-- unless an example says otherwise, and every texture is one linear texel, so a
-- drawn pixel is the texel's colour and anything else is the transparent black
-- the pass clears to.
module Test.Render.TwoD.Oracle.Clip (spec) where

import Data.Word (Word16)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Clip (ClipEntry (..), ClipRect (..))
import qualified Data.Map.Strict as Map
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks, cutoutMarks, noCutoutMarks)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (..), Rgba8 (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (Location (..))
import Test.Hspec hiding (Expectation)
import Test.Render.TwoD.Oracle.Support

-- | A clip entry: this origin, this extent, no parent.
rect ∷ (Float, Float) → (Float, Float) → ClipEntry
rect (x, y) (w, h) = ClipEntry (ClipRect (V2 x y) (V2 w h)) Nothing

-- | The same with this parent.
under ∷ Int → ClipEntry → ClipEntry
under parent entry = entry {clipParent = Just parent}

-- | An instance with this clip index.
clipped ∷ Word16 → Instance → Instance
clipped index candidate = candidate {instanceClip = index}

-- | A fourth handle, white.
h4 ∷ TextureHandle
h4 = textureHandle 4 1

-- | A sprite of a handle covering far more than the target, with this clip index.
cover ∷ TextureHandle → Word16 → Instance
cover handle index = clipped index (sprite handle (0, 0) (64, 64))

-- | A sprite of a handle covering the whole target in world space under the
-- default camera, which centres world (0, 0) on pixel (4, 4).
worldCover ∷ TextureHandle → Word16 → Instance
worldCover handle index = clipped index (sprite handle (-100, -100) (200, 200))

-- | An oracle over one pass of these views: handles 1 to 4 are one opaque
-- linear texel each, red, green, blue and white.
oracleOf ∷ TargetSpec → [View] → Oracle
oracleOf target = oracleWith target noCutoutMarks

oracleWith ∷ TargetSpec → CutoutMarks → [View] → Oracle
oracleWith target marks views =
  mkOracleFull
    marks
    Nothing
    (Map.singleton offscreenRef target)
    [ (h1, solid False (255, 0, 0, 255))
    , (h2, solid False (0, 255, 0, 255))
    , (h3, solid False (0, 0, 255, 255))
    , (h4, solid False (255, 255, 255, 255))
    ]
    [offscreenPass noClear views]

-- | The view of the default camera over the whole target, with this clip table
-- and one UI layer.
uiView ∷ [ClipEntry] → [Instance] → View
uiView table instances = mkClipView defaultCamera (fullViewport 8 8) defaultViewSettings table [UiLayer instances]

-- | A view with one world layer without depth.
worldView ∷ ViewSettings → Camera → [ClipEntry] → [Instance] → View
worldView settings camera table instances = mkClipView camera (fullViewport 8 8) settings table [WorldLayer DepthDisabled instances]

pictureOf ∷ Oracle → [String]
pictureOf oracle = picture oracle 0 (8, 8) palette

blank ∷ String
blank = "........"

-- | The glyph of one pixel of the picture.
glyphAt ∷ Oracle → Int → Int → Char
glyphAt oracle x y = pictureOf oracle !! y !! x

-- | A pixel's expectation is indeterminate for this reason.
indeterminateAt ∷ Oracle → Int → Int → Maybe Indeterminate
indeterminateAt oracle x y = case expectAt oracle x y of
  Indeterminate why → Just why
  _ → Nothing

spec ∷ Spec
spec = describe "clip" $ do
  axisAlignedSpec
  nestedSpec
  rotatedSpec
  edgeSpec
  placementSpec
  cutoutSpec
  emptySpec
  viewSpec

axisAlignedSpec ∷ Spec
axisAlignedSpec = describe "an axis-aligned clip" $ do
  it "draws inside the rectangle and nothing outside it, half a pixel clear of every edge" $
    pictureOf (oracleOf unorm8 [uiView [rect (2, 2) (3, 4)] [cover h4 1]])
      `shouldBe` [blank, blank, "..WWW...", "..WWW...", "..WWW...", "..WWW...", blank, blank]

  it "leaves an instance with clip index 0 unclipped beside clipped ones in the same layer" $
    pictureOf (oracleOf unorm8 [uiView [rect (4, 0) (4, 8)] [cover h1 0, cover h2 1]])
      `shouldBe` replicate 8 "RRRRGGGG"

nestedSpec ∷ Spec
nestedSpec = describe "nested clips" $ do
  it "intersects a pair, with unclipped, parent-clipped and child-clipped instances in one layer" $
    pictureOf
      ( oracleOf
          unorm8
          [uiView [rect (1, 1) (6, 6), under 0 (rect (3, 0) (6, 5))] [cover h1 0, cover h3 1, cover h2 2]]
      )
      `shouldBe` [ "RRRRRRRR"
                 , "RBBGGGGR"
                 , "RBBGGGGR"
                 , "RBBGGGGR"
                 , "RBBGGGGR"
                 , "RBBBBBBR"
                 , "RBBBBBBR"
                 , "RRRRRRRR"
                 ]

  it "intersects a chain three deep with every ancestor" $
    pictureOf
      ( oracleOf
          unorm8
          [ uiView
              [rect (0, 0) (6, 6), under 0 (rect (2, 0) (6, 6)), under 1 (rect (0, 3) (5, 5))]
              [cover h4 3]
          ]
      )
      `shouldBe` [blank, blank, blank, "..WWW...", "..WWW...", "..WWW...", blank, blank]

rotatedSpec ∷ Spec
rotatedSpec = describe "a clip under a rotated camera" $ do
  it "turns with the layer: a square about the camera's centre becomes a diamond under a 45 degree rotation" $ do
    -- target = (4, 4) + R(-pi/4) (world): the square [-2, 2)² becomes the
    -- diamond |dx| + |dy| < 2.83 about (4, 4), so with centres at offsets of
    -- half a pixel the pixels inside are those with |dx| + |dy| of 1 or 2, and
    -- the next ones, at 3, are 0.12 pixel outside it.
    let camera = Camera (V2 0 0) 1 (Just (pi / 4))
    pictureOf (oracleOf unorm8 [worldView defaultViewSettings camera [rect (-2, -2) (4, 4)] [worldCover h4 1]])
      `shouldBe` [blank, blank, "...WW...", "..WWWW..", "..WWWW..", "...WW...", blank, blank]

  it "holds under zoom as well: zoom 2 doubles the clip's size on the target" $ do
    -- target = (4, 4) + 2 R(-pi/4) (world): the square [-1, 1)² becomes a
    -- diamond with half-diagonal 2.83, the same one.
    let camera = Camera (V2 0 0) 2 (Just (pi / 4))
    pictureOf (oracleOf unorm8 [worldView defaultViewSettings camera [rect (-1, -1) (2, 2)] [worldCover h4 1]])
      `shouldBe` [blank, blank, "...WW...", "..WWWW..", "..WWWW..", "...WW...", blank, blank]

edgeSpec ∷ Spec
edgeSpec = describe "the edge band" $ do
  let rightEdge edge = oracleOf unorm8 [uiView [rect (2, 0) (edge - 2, 8)] [cover h4 1]]
      near = Just (NearClipEdge (AtInstance 0 0 0 0))
  it "is indeterminate for a pixel centre on a clip edge" $
    indeterminateAt (rightEdge 4.5) 4 4 `shouldBe` near

  it "is indeterminate within 1/16 pixel, either side, and at 1/16 itself" $ do
    indeterminateAt (rightEdge (4.5 + 1 / 32)) 4 4 `shouldBe` near
    indeterminateAt (rightEdge (4.5 + 1 / 16)) 4 4 `shouldBe` near
    indeterminateAt (rightEdge (4.5 - 1 / 32)) 4 4 `shouldBe` near
    indeterminateAt (rightEdge (4.5 - 1 / 16)) 4 4 `shouldBe` near

  it "is determinate farther than 1/16 pixel from the edge: inside draws, outside leaves the clear" $ do
    glyphAt (rightEdge (4.5 + 1 / 16 + 1 / 64)) 4 4 `shouldBe` 'W'
    glyphAt (rightEdge (4.5 - 1 / 16 - 1 / 64)) 4 4 `shouldBe` '.'

  it "never makes a pixel indeterminate that the clipped instance could not draw on" $ do
    -- The sprite covers [0, 2)², far from the edge at 4.5.
    let oracle = oracleOf unorm8 [uiView [rect (2, 0) (2.5, 8)] [clipped 1 (sprite h4 (0, 0) (2, 2))]]
    glyphAt oracle 4 4 `shouldBe` '.'

  it "measures the band in target pixels: a UI scale of 4 makes 0.1 pixel of 0.025 unit determinate" $ do
    -- target = 4 · ui, so the edge at ui 1.1 is at 4.4 and the centre of pixel
    -- 4 is 0.1 pixel outside it, though only 0.025 of a UI unit.
    let settings = defaultViewSettings {settingUiScale = 4}
        oracle = oracleOf unorm8 [mkClipView defaultCamera (fullViewport 8 8) settings [rect (0, 0) (1.1, 2)] [UiLayer [clipped 1 (sprite h4 (0, 0) (2, 2))]]]
    glyphAt oracle 4 4 `shouldBe` '.'
    glyphAt oracle 3 4 `shouldBe` 'W'

  it "measures the band in target pixels: a zoom of 1/4 makes 0.03 pixel of 0.12 unit indeterminate" $ do
    -- target = 4 + world / 4, so the edge at world 2.12 is at 4.53 and the
    -- centre of pixel 4 is 0.03 pixel from it, though 0.12 of a world unit.
    let camera = Camera (V2 0 0) 0.25 Nothing
        oracle = oracleOf unorm8 [worldView defaultViewSettings camera [rect (-100, -100) (102.12, 200)] [worldCover h4 1]]
    indeterminateAt oracle 4 4 `shouldBe` Just (NearClipEdge (AtInstance 0 0 0 0))
    glyphAt oracle 3 4 `shouldBe` 'W'

placementSpec ∷ Spec
placementSpec = describe "where the clip stands in the target" $ do
  let snapping = defaultViewSettings {settingPixelSnap = True}
      camera = Camera (V2 0.25 0) 2 Nothing
      -- With zoom 2 and the camera at x = 0.25 the translation is 3.5, which
      -- snaps to 4, so a world x is at 2x + 4 on the target.
      clipX = rect (0.2, -10) (1.2, 20)
      column = replicate 8 "....WWW."
  it "uses the view's snapped translation: the clip [0.2, 1.4) is at [4.4, 6.8) on the target" $
    pictureOf (oracleOf unorm8 [worldView snapping camera [clipX] [sprite h4 (-100, -100) (200, 200) `clipped'` 1]])
      `shouldBe` column

  it "is not the unsnapped translation: without snapping the clip is at [3.9, 6.3)" $
    pictureOf (oracleOf unorm8 [worldView defaultViewSettings camera [clipX] [sprite h4 (-100, -100) (200, 200) `clipped'` 1]])
      `shouldBe` replicate 8 "....WW.."

  it "does not move with a sprite's origin snap: a sprite snapped 0.4 pixel to the right leaves the clip where it was" $
    -- The sprite's origin is world -9.7, at -15.4 on the target, which snaps to
    -- -15, 0.4 pixel to the right. It still covers the target, and the clip
    -- stays at [4.4, 6.8): pixel 4 is inside.
    pictureOf (oracleOf unorm8 [worldView snapping camera [clipX] [sprite h4 (-9.7, -10) (20, 20) `clipped'` 1]])
      `shouldBe` column

  it "uses the UI scale, the content scale and the viewport's origin, apart from any camera" $ do
    -- Content scale 2 on a 4 × 4 logical, 8 × 8 pixel target, a viewport at
    -- (2, 2): target = 2 + 2 · ui. The clip [1, 2.5) × [0, 100) is at x in
    -- [4, 7) and y from 2, and the viewport keeps the first two rows clear.
    let spec2 = TargetSpec (TargetMetrics (PixelExtent 4 4) (PixelExtent 8 8) 2 2) R8G8B8A8Unorm (PixelExtent 8 8)
        view =
          mkClipView
            (Camera (V2 123 456) 7 (Just 1))
            (Viewport (V2 2 2) (V2 6 6))
            defaultViewSettings
            [rect (1, 0) (1.5, 100)]
            [UiLayer [cover h4 1]]
    pictureOf (oracleOf spec2 [view]) `shouldBe` [blank, blank] <> replicate 6 "....WWW."
  where
    clipped' candidate index = clipped index candidate

cutoutSpec ∷ Spec
cutoutSpec = describe "the cutout path" $ do
  let marks = cutoutMarks [h1, h2]
      layerOf table instances = mkClipView defaultCamera (fullViewport 8 8) defaultViewSettings table [WorldLayer DepthEnabled instances]
      nearer = (sprite h1 (0, 0) (1, 1)) {instanceDepthKey = 9}
      farther = (sprite h2 (0, 0) (1, 1)) {instanceDepthKey = 1}
      valueAt oracle = case expectAt oracle 4 4 of
        Expected value _ → Just value
        _ → Nothing
  it "gives the nearer cutout the pixel when nothing clips it" $
    valueAt (oracleWith unorm8 marks [layerOf [] [nearer, farther]]) `shouldBe` Just (Rgba8 255 0 0 255)

  it "gives a clipped-away cutout no depth: the farther one shows through it" $
    valueAt (oracleWith unorm8 marks [layerOf [rect (10, 10) (1, 1)] [clipped 1 nearer, farther]]) `shouldBe` Just (Rgba8 0 255 0 255)

  it "keeps the nearer cutout where its clip holds the pixel" $
    valueAt (oracleWith unorm8 marks [layerOf [rect (-1, -1) (3, 3)] [clipped 1 nearer, farther]]) `shouldBe` Just (Rgba8 255 0 0 255)

emptySpec ∷ Spec
emptySpec = describe "an empty clip" $ do
  it "clips everything, and has no edge to make a pixel indeterminate, even at its own origin" $
    pictureOf (oracleOf unorm8 [uiView [rect (4.5, 4.5) (0, 0)] [cover h4 1]]) `shouldBe` replicate 8 blank

  it "keeps every descendant empty, however large its own rectangle is" $
    pictureOf (oracleOf unorm8 [uiView [rect (0, 0) (0, 4), under 0 (rect (-100, -100) (200, 200))] [cover h4 2]])
      `shouldBe` replicate 8 blank

  it "clips an intersection of two rectangles that only touch" $
    pictureOf (oracleOf unorm8 [uiView [rect (0, 0) (4, 8), under 0 (rect (4, 0) (4, 8))] [cover h4 2]])
      `shouldBe` replicate 8 blank

viewSpec ∷ Spec
viewSpec = describe "two views" $ do
  it "resolve one clip index against their own tables, in their own viewports" $ do
    let left = mkClipView defaultCamera (Viewport (V2 0 0) (V2 4 8)) defaultViewSettings [rect (1, 0) (1, 8)] [UiLayer [cover h4 1]]
        right = mkClipView defaultCamera (Viewport (V2 4 0) (V2 4 8)) defaultViewSettings [rect (1, 0) (2, 8)] [UiLayer [cover h4 1]]
    pictureOf (oracleOf unorm8 [left, right]) `shouldBe` replicate 8 ".W...WW."
