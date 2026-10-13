-- | Animation in the oracle (R2D-18): an instance whose frame-table index selects
-- a table of its view shows the rectangle of the table's current frame at the
-- view's time, for a dynamic instance and a retained chunk's alike, with the
-- frame the 'Double' formula @floor (t / duration) mod count@ gives and no
-- indeterminacy band.
--
-- __Fixtures.__ Every expectation is worked on paper. The texture is four texels
-- in a row, red, green, blue and yellow, sampled nearest; frame @k@ of a table
-- shows texel @k@, so a pixel's colour names the frame the oracle selected. The
-- target is 8 × 8; a unit sprite at the world origin covers pixel (4, 4) of a view
-- over the whole target, whose pixel centre is a quarter of a texel from a texel
-- boundary and far from every edge, so a determinate answer is the only one
-- possible. Times that must fall exactly on a boundary are multiples of an exactly
-- representable duration (0.5, a power of two), so their quotient is exact.
module Test.Render.TwoD.Oracle.Animation (spec) where

import qualified Data.Map.Strict as Map
import Data.Word (Word16)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import Hetoimasia.Asset.Image (DecodedImage)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Chunk
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)
import Hetoimasia.Render.TwoD.DrawPlan (noCutoutMarks)
import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8)
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (validateSnapshotWith)
import Test.Hspec hiding (Expectation)
import Test.Render.TwoD.Oracle.Support

-- * Fixtures

red, green, blue, yellow ∷ Rgba
red = (255, 0, 0, 255)
green = (0, 255, 0, 255)
blue = (0, 0, 255, 255)
yellow = (255, 255, 0, 255)

-- | Four texels in a row: red, green, blue, yellow.
strip ∷ [(TextureHandle, DecodedImage)]
strip = [(h1, rgba8 False 4 1 [concat [[r, g, b, a] | (r, g, b, a) ← [red, green, blue, yellow]]])]

-- | A table of this many frames of this duration, frame @k@ showing texel @k@ of
-- the strip (the strip's four texels, wrapped: a table of more frames than the
-- strip has texels shows texel @k mod 4@).
tableOf ∷ Int → Double → FrameTable
tableOf count duration = FrameTable count duration [texel (k `mod` 4) | k ← [0 .. count - 1]]

-- | The table whose frames run backwards through the strip.
reversedTable ∷ Int → Double → FrameTable
reversedTable count duration = FrameTable count duration [texel (3 - (k `mod` 4)) | k ← [0 .. count - 1]]

texel ∷ Int → UvRect
texel k = UvRect (fromIntegral k / 4) 0 (fromIntegral k / 4 + 0.25) 1

-- | A unit sprite over pixel (4, 4) of the strip, carrying this frame-table
-- index and its own rectangle, the whole strip, which an animated instance
-- does not show.
animated ∷ Word16 → Instance
animated index = (spriteAt h1 (0, 0)) {instanceFrameTable = index}

-- | The oracle of one 8 × 8 view of these tables at this time over these layers.
at ∷ [FrameTable] → Double → [Layer] → Oracle
at tables time layers = mkOracle unorm8 strip [offscreenPass noClear [animatedView tables time layers]]

animatedView ∷ [FrameTable] → Double → [Layer] → View
animatedView tables time = ViewWith defaultCamera (fullViewport 8 8) defaultViewSettings [] Map.empty tables time

-- | The value expected at pixel (4, 4), if determinate.
shown ∷ Oracle → Maybe Rgba8
shown oracle = case expectAt oracle 4 4 of
  Expected value _ → Just value
  _ → Nothing

colour ∷ Rgba → Maybe Rgba8
colour = Just . px

-- | The colour of the frame a table shows at a time, by the oracle.
frameAt ∷ FrameTable → Double → Maybe Rgba8
frameAt table time = shown (at [table] time [WorldLayer DepthDisabled [animated 1]])

below, above ∷ Double → Double
below value = castWord64ToDouble (castDoubleToWord64 value - 1)
above value = castWord64ToDouble (castDoubleToWord64 value + 1)

-- * Examples

spec ∷ Spec
spec = do
  dynamicSpec
  boundarySpec
  precisionSpec
  chunkSpec

dynamicSpec ∷ Spec
dynamicSpec = describe "a dynamic instance" $ do
  it "shows its own rectangle when it is not animated, even in a view that holds tables" $
    shown (at [tableOf 4 1] 1 [WorldLayer DepthDisabled [(spriteAt h1 (0, 0)) {instanceUv = texel 2}]]) `shouldBe` colour blue

  it "shows the current frame of its table in place of its own rectangle" $
    mapM_
      (\(time, expected) → frameAt (tableOf 4 1) time `shouldBe` colour expected)
      [(0, red), (0.5, red), (1, green), (1.75, green), (2, blue), (3.5, yellow), (4, red), (9.25, green)]

  it "selects the table its index names, among several" $ do
    let tables = [tableOf 4 1, reversedTable 4 1, tableOf 2 10]
        showing index = shown (at tables 2 [WorldLayer DepthDisabled [animated index]])
    showing 1 `shouldBe` colour blue
    showing 2 `shouldBe` colour green
    showing 3 `shouldBe` colour red

  it "draws an animated and a non-animated instance in one layer, each as its own" $ do
    let sprites = [animated 1, (spriteAt h1 (1, 0)) {instanceUv = texel 2}]
        oracle = at [tableOf 4 1] 1 [WorldLayer DepthDisabled sprites]
    expectAt oracle 4 4 `shouldSatisfy` isValue green
    expectAt oracle 5 4 `shouldSatisfy` isValue blue

  it "is never indeterminate because of animation, at any time" $
    mapM_
      (\time → expectAt (at [tableOf 4 0.5] time [WorldLayer DepthDisabled [animated 1]]) 4 4 `shouldSatisfy` determinate)
      [0, 0.25, 0.5, below 0.5, above 0.5, 1.5, 991231.9998, 1.0e6, 1.0e300]
  where
    determinate = \case
      Expected _ _ → True
      _ → False
    isValue (r, g, b, a) = \case
      Expected value _ → value == px (r, g, b, a)
      _ → False

boundarySpec ∷ Spec
boundarySpec = describe "frame boundaries" $ do
  it "selects frame k mod count exactly on the boundary k × duration" $
    mapM_
      (\(k, expected) → frameAt (tableOf 4 0.5) (fromIntegral (k ∷ Int) * 0.5) `shouldBe` colour expected)
      (zip [0 .. 9] (cycle [red, green, blue, yellow]))

  it "selects the previous frame just before a boundary and the frame itself just after" $
    mapM_
      ( \k → do
          let boundary = fromIntegral (k ∷ Int) * 0.5
          frameAt (tableOf 4 0.5) (below boundary) `shouldBe` colour (cycle [red, green, blue, yellow] !! (k - 1))
          frameAt (tableOf 4 0.5) boundary `shouldBe` colour (cycle [red, green, blue, yellow] !! k)
          frameAt (tableOf 4 0.5) (above boundary) `shouldBe` colour (cycle [red, green, blue, yellow] !! k)
      )
      [1 .. 9]

  it "wraps from the last frame to the first" $ do
    frameAt (tableOf 4 0.5) 1.75 `shouldBe` colour yellow
    frameAt (tableOf 4 0.5) 2 `shouldBe` colour red

precisionSpec ∷ Spec
precisionSpec = describe "the Double formula, with no snapping and no band" $ do
  it "selects frame 0 for count 2, duration 8192, time 991231.9998, near the cycle's end but not on a boundary" $
    frameAt (tableOf 2 8192) 991231.9998 `shouldBe` colour red

  it "selects frame 2 for count 3, duration 2^127, time 2.5 × 2^127" $
    frameAt (tableOf 3 (2 ^ (127 ∷ Int))) (2.5 * 2 ^ (127 ∷ Int)) `shouldBe` colour blue

  it "takes the quotient 42.99999999999999 of duration 0.1 and time 43 × 0.1 as frame 0, not 1" $ do
    -- 43 × 0.1 rounds, so the time is not exactly the boundary 43 × 0.1: the
    -- Double division gives 42.99999999999999, the floor 42, an even frame.
    let time = 43 * 0.1 ∷ Double
    time / 0.1 `shouldBe` 42.99999999999999
    frameAt (tableOf 2 0.1) time `shouldBe` colour red
    frameAt (tableOf 3 0.1) time `shouldBe` colour red
    -- The exactly representable boundary 43 × 0.5 is what a boundary fixture uses.
    frameAt (tableOf 2 0.5) (43 * 0.5) `shouldBe` colour green

  it "selects a frame at a time near 10^6 seconds by the formula" $ do
    -- 1000000 / 0.25 = 4000000 exactly, an even multiple of the count 4.
    frameAt (tableOf 4 0.25) 1.0e6 `shouldBe` colour red
    frameAt (tableOf 4 0.25) (above 1.0e6) `shouldBe` colour red
    frameAt (tableOf 4 0.25) (below 1.0e6) `shouldBe` colour yellow

  it "takes the floor of a quotient beyond 2^63 exactly" $ do
    -- 2^70 / 1 = 2^70, and 2^70 mod 3 is 1.
    frameAt (tableOf 3 1) (2 ^ (70 ∷ Int)) `shouldBe` colour green

chunkSpec ∷ Spec
chunkSpec = describe "a retained chunk" $ do
  it "shows each view's own frame when drawn in two views with different tables and times" $ do
    let chunk = either (error . show) id (buildChunk noCutoutMarks ChunkWorldFlat DeriveBounds [animated 1])
        reference = chunkRef 1 1
        listing = WorldLayerWith DepthDisabled [reference] []
        left = ViewWith defaultCamera (Viewport (V2 0 0) (V2 4 8)) defaultViewSettings [] Map.empty [tableOf 4 1] 1 [listing]
        right = ViewWith defaultCamera (Viewport (V2 4 0) (V2 4 8)) defaultViewSettings [] Map.empty [reversedTable 4 1] 1 [listing]
        snapshot = Snapshot [offscreenPass noClear [left, right]]
        oracle =
          newOracle
            OracleInput
              { inputSnapshot = either (error . show) id (validateSnapshotWith (chunksFrom [(reference, chunk)]) snapshot)
              , inputCutoutMarks = noCutoutMarks
              , inputWindow = Nothing
              , inputOffscreen = Map.singleton offscreenRef unorm8
              , inputTextures = \handle → lookup handle strip
              }
    -- The camera is at the origin in both: the left view's sprite covers pixel
    -- (2, 4), the right view's pixel (6, 4); both at time 1 select frame 1,
    -- which the first table shows as green and the reversed one as blue.
    expectAt oracle 2 4 `shouldSatisfy` isColour green
    expectAt oracle 6 4 `shouldSatisfy` isColour blue
  where
    isColour (r, g, b, a) = \case
      Expected value _ → value == px (r, g, b, a)
      _ → False
