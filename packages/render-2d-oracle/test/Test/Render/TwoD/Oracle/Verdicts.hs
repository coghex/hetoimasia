-- | Verdicts: the readback reader, the comparison, and the rejection suite.
--
-- The readbacks here are synthetic and written by hand, as pictures over a
-- legend of bytes, never taken from the oracle: the exact image is accepted,
-- and reversed overlap, a channel off by two and a wrong snap are rejected.
module Test.Render.TwoD.Oracle.Verdicts (spec) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..))
import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (Channel (..), ColourFormat (..), Rgba8 (..), Tolerance (..))
import Hetoimasia.Render.TwoD.Oracle.Readback (readPixel)
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (Location (..))
import Test.Hspec hiding (Expectation)
import Test.Render.TwoD.Oracle.Support

world ∷ [Instance] → Layer
world = WorldLayer DepthDisabled

-- | A readback of a picture, four bytes a pixel in a format's own channel order.
render ∷ ColourFormat → [String] → [(Char, Rgba)] → ByteString
render format rows legend =
  ByteString.pack
    [ byte
    | row ← rows
    , glyph ← row
    , let (r, g, b, a) = maybe (error "glyph not in the legend") id (lookup glyph legend)
    , byte ← case format of
        B8G8R8A8Srgb → [b, g, r, a]
        B8G8R8A8Unorm → [b, g, r, a]
        _ → [r, g, b, a]
    ]

-- | Whether every pixel of an 8 × 8 pass-0 target passes against a readback.
accepts ∷ Oracle → ByteString → Bool
accepts oracle bytes = and [passes (judgeReadback oracle (Probe 0 x y) bytes) | x ← [0 .. 7], y ← [0 .. 7]]

rejectedAt ∷ Oracle → ByteString → [(Int, Int)]
rejectedAt oracle bytes = [(x, y) | y ← [0 .. 7], x ← [0 .. 7], not (passes (judgeReadback oracle (Probe 0 x y) bytes))]

-- | Two half-alpha sprites overlapping, the red below the blue: red alone,
-- both, blue alone, and nothing.
overlap ∷ Oracle
overlap =
  mkOracle
    unorm8
    [(h1, solid False (128, 0, 0, 128)), (h2, solid False (0, 0, 128, 128))]
    [ offscreenPass
        noClear
        [ fullView
            8
            8
            [world [(sprite h2 (-1, -1) (3, 3)) {instanceDepthKey = 2}, (sprite h1 (-2, -2) (3, 3)) {instanceDepthKey = 1}]]
        ]
    ]

overlapPicture ∷ [String]
overlapPicture =
  [ "........"
  , "........"
  , "..aaa..."
  , "..aoob.."
  , "..aoob.."
  , "...bbb.."
  , "........"
  , "........"
  ]

overlapLegend ∷ [(Char, Rgba)]
overlapLegend = [('.', (0, 0, 0, 0)), ('a', (128, 0, 0, 128)), ('o', (64, 0, 128, 192)), ('b', (0, 0, 128, 128))]

-- | A red 1.2-pixel sprite with its origin at 1.4, with pixel snap on or off.
snapped ∷ Bool → Oracle
snapped snaps =
  mkOracle
    unorm8
    [(h1, solid False (255, 0, 0, 255))]
    [offscreenPass noClear [mkView defaultCamera (fullViewport 8 8) defaultViewSettings {settingPixelSnap = snaps} [world [sprite h1 (1.4, 1.4) (1.2, 1.2)]]]]

spec ∷ Spec
spec = describe "readbacks and verdicts" $ do
  describe "the readback reader" $ do
    let bytes = ByteString.pack [1, 2, 3, 4, 5, 6, 7, 8]
        extent = PixelExtent 2 1

    it "reads RGBA in order" $ do
      readPixel R8G8B8A8Srgb extent bytes 0 0 `shouldBe` Right (Rgba8 1 2 3 4)
      readPixel R8G8B8A8Unorm extent bytes 1 0 `shouldBe` Right (Rgba8 5 6 7 8)

    it "swizzles B8G8R8A8 to RGBA, leaving every byte as stored" $ do
      readPixel B8G8R8A8Srgb extent bytes 0 0 `shouldBe` Right (Rgba8 3 2 1 4)
      readPixel B8G8R8A8Unorm extent bytes 1 0 `shouldBe` Right (Rgba8 7 6 5 8)

    it "reads the pixel a probe names" $ do
      readProbe B8G8R8A8Srgb extent bytes (Probe 0 1 0) `shouldBe` Right (Rgba8 7 6 5 8)
      readProbe R8G8B8A8Srgb extent bytes (Probe 3 0 0) `shouldBe` Right (Rgba8 1 2 3 4)
      readProbe R8G8B8A8Srgb extent bytes (Probe 0 2 0) `shouldBe` Left (ReadbackPixelOutside 2 0)

    it "reads rows top first" $
      readPixel R8G8B8A8Unorm (PixelExtent 1 2) bytes 0 1 `shouldBe` Right (Rgba8 5 6 7 8)

    it "refuses a readback of the wrong size, short or long" $ do
      readPixel R8G8B8A8Srgb extent (ByteString.take 7 bytes) 0 0 `shouldBe` Left (ReadbackSizeWrong 8 7)
      readPixel R8G8B8A8Srgb extent (bytes <> ByteString.singleton 9) 0 0 `shouldBe` Left (ReadbackSizeWrong 8 9)
      readPixel R8G8B8A8Srgb extent ByteString.empty 0 0 `shouldBe` Left (ReadbackSizeWrong 8 0)

    it "compares sizes without wrapping, for an extent whose product overflows" $
      readPixel R8G8B8A8Srgb (PixelExtent 2147483647 2147483647) bytes 0 0
        `shouldBe` Left (ReadbackSizeWrong (2147483647 * 2147483647 * 4) 8)

    it "refuses a pixel outside the extent and an invalid extent" $ do
      readPixel R8G8B8A8Srgb extent bytes 2 0 `shouldBe` Left (ReadbackPixelOutside 2 0)
      readPixel R8G8B8A8Srgb extent bytes 0 1 `shouldBe` Left (ReadbackPixelOutside 0 1)
      readPixel R8G8B8A8Srgb extent bytes (-1) 0 `shouldBe` Left (ReadbackPixelOutside (-1) 0)
      readPixel R8G8B8A8Srgb (PixelExtent (-1) 1) bytes 0 0 `shouldBe` Left ReadbackExtentInvalid

  describe "verdicts" $ do
    it "passes only when every channel is within its tolerance" $ do
      let expected = Expected (Rgba8 100 100 100 100) (Tolerance 0 1 0 1)
      judge expected (Rgba8 100 101 100 99) `shouldBe` Passed
      judge expected (Rgba8 101 100 100 100) `shouldBe` OutOfTolerance [ChannelDifference Red 100 101 0]
      judge expected (Rgba8 100 102 98 100)
        `shouldBe` OutOfTolerance [ChannelDifference Green 100 102 1, ChannelDifference Blue 100 98 0]

    it "never passes an indeterminate or an unevaluable probe, whatever was read" $ do
      let why = NearQuadEdge (AtInstance 0 0 0 0)
      judge (Indeterminate why) (Rgba8 0 0 0 0) `shouldBe` ProbeIndeterminate why
      judge (Unevaluable (PassOutOfRange 3)) (Rgba8 0 0 0 0) `shouldBe` ProbeUnevaluable (PassOutOfRange 3)
      passes (judge (Indeterminate why) (Rgba8 255 255 255 255)) `shouldBe` False

    it "judges a probe against a readback, swizzling a B8G8R8A8 target" $ do
      let oracle =
            mkOracle (targetSpec B8G8R8A8Srgb 8 8) [(h1, solid True (200, 100, 50, 255))] $
              [offscreenPass noClear [fullView 8 8 [world [spriteAt h1 (0, 0)]]]]
          legend = [('.', (0, 0, 0, 0)), ('x', (200, 100, 50, 255))]
          rows = replicate 4 "........" <> ["....x..."] <> replicate 3 "........"
          bgra = render B8G8R8A8Srgb rows legend
          wrongOrder = render R8G8B8A8Srgb rows legend
      accepts oracle bgra `shouldBe` True
      -- The same picture in RGBA byte order is not what a B8G8R8A8 target holds.
      rejectedAt oracle wrongOrder `shouldBe` [(4, 4)]

    it "refuses a readback of the wrong size or a probe it cannot place" $ do
      let oracle = mkOracle unorm8 [] [offscreenPass noClear [fullView 8 8 []]]
          good = ByteString.replicate 256 0
      judgeReadback oracle (Probe 0 0 0) good `shouldBe` Passed
      judgeReadback oracle (Probe 0 0 0) (ByteString.take 255 good) `shouldBe` ReadbackFaulty (ReadbackSizeWrong 256 255)
      judgeReadback oracle (Probe 0 0 0) (good <> ByteString.singleton 0) `shouldBe` ReadbackFaulty (ReadbackSizeWrong 256 257)
      judgeReadback oracle (Probe 1 0 0) good `shouldBe` ProbeUnevaluable (PassOutOfRange 1)
      judgeReadback oracle (Probe 0 8 0) good `shouldBe` ProbeUnevaluable (PixelOutsideTarget 8 0)

  describe "against synthetic readbacks" $ do
    it "computes the hand-written overlap picture" $
      picture overlap 0 (8, 8) [(c, px v) | (c, v) ← overlapLegend] `shouldBe` overlapPicture

    it "accepts the exact image" $
      accepts overlap (render R8G8B8A8Unorm overlapPicture overlapLegend) `shouldBe` True

    it "rejects reversed overlap" $ do
      let reversed = [(c, if c == 'o' then (128, 0, 64, 192) else v) | (c, v) ← overlapLegend]
      -- Only the overlapped pixels differ, and every one of them is rejected.
      rejectedAt overlap (render R8G8B8A8Unorm overlapPicture reversed) `shouldBe` [(3, 3), (4, 3), (3, 4), (4, 4)]

    it "rejects a channel off by two, and accepts one off by one where one step is allowed" $ do
      let with value = [(c, if c == 'o' then value else v) | (c, v) ← overlapLegend]
          at value = rejectedAt overlap (render R8G8B8A8Unorm overlapPicture (with value))
      at (66, 0, 128, 192) `shouldBe` [(3, 3), (4, 3), (3, 4), (4, 4)]
      at (62, 0, 128, 192) `shouldBe` [(3, 3), (4, 3), (3, 4), (4, 4)]
      at (65, 0, 128, 193) `shouldBe` []
      at (63, 0, 128, 191) `shouldBe` []

    it "rejects a channel off by one where the channel is exact" $ do
      let with value = [(c, if c == 'a' then value else v) | (c, v) ← overlapLegend]
          at value = rejectedAt overlap (render R8G8B8A8Unorm overlapPicture (with value))
      -- The red-only pixels carry the texel's bytes through unchanged.
      at (129, 0, 0, 128) `shouldBe` [(2, 2), (3, 2), (4, 2), (2, 3), (2, 4)]
      at (128, 1, 0, 128) `shouldBe` [(2, 2), (3, 2), (4, 2), (2, 3), (2, 4)]

    it "rejects a wrong snap and accepts the exact image" $ do
      let legend = [('.', (0, 0, 0, 0)), ('R', (255, 0, 0, 255))]
          picture' grid = render R8G8B8A8Unorm grid legend
          rows cells = [[if (cx, cy) `elem` cells then 'R' else '.' | cx ← [0 .. 7 ∷ Int]] | cy ← [0 .. 7 ∷ Int]]
      -- The origin 5.4 rounds to 5 and the quad covers [5, 6.2]: pixel (5, 5).
      accepts (snapped True) (picture' (rows [(5, 5)])) `shouldBe` True
      -- The unsnapped quad, rounding up and rounding down are all wrong.
      rejectedAt (snapped True) (picture' (rows [(5, 5), (6, 5), (5, 6), (6, 6)])) `shouldBe` [(6, 5), (5, 6), (6, 6)]
      rejectedAt (snapped True) (picture' (rows [(6, 6)])) `shouldBe` [(5, 5), (6, 6)]
      rejectedAt (snapped True) (picture' (rows [(4, 4)])) `shouldBe` [(4, 4), (5, 5)]
      -- And the unsnapped scene is the four pixels, not the snapped one.
      accepts (snapped False) (picture' (rows [(5, 5), (6, 5), (5, 6), (6, 6)])) `shouldBe` True
      rejectedAt (snapped False) (picture' (rows [(5, 5)])) `shouldBe` [(6, 5), (5, 6), (6, 6)]
