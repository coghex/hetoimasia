-- | Sampling: filters, colour spaces, mip levels, the placeholder and BC7.
--
-- The texels are chosen so each expectation is a value worked on paper:
-- sRGB 128 decodes to 0.2158605 and rounds to byte 55 on a UNORM target, a
-- 2:1 minified probe reads level 1, and a BC7 block whose indices are all 0 or
-- all 15 decodes to its first or second endpoint exactly.
module Test.Render.TwoD.Oracle.Sampling (spec) where

import Data.Bits (shiftL, testBit, (.|.))
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.Word (Word8)
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..), Tolerance (..))
import Hetoimasia.Render.TwoD.Settings (TextureFilter (..), ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (Location (..))
import Test.Hspec hiding (Expectation)
import Test.Render.TwoD.Oracle.Support

world ∷ [Instance] → Layer
world = WorldLayer DepthDisabled

blank ∷ Int → String
blank width = replicate width '.'

red ∷ Rgba
red = (255, 0, 0, 255)

blue ∷ Rgba
blue = (0, 0, 255, 255)

bytesOf ∷ [Rgba] → [Word8]
bytesOf = concatMap (\(r, g, b, a) → [r, g, b, a])

linear ∷ Instance → Instance
linear candidate = candidate {instanceSampler = SamplerLinear}

-- | Red then blue, one row of two texels, sRGB.
redBlue ∷ DecodedImage
redBlue = rgba8 True 2 1 [bytesOf [red, blue]]

-- | A 4 × 4 texture of three levels, each of its own colours, so which level
-- was read is plain: level 0 is red, level 1 is green, yellow, cyan and white,
-- level 2 is blue.
mipped ∷ DecodedImage
mipped =
  rgba8
    False
    4
    4
    [ flat 16 red
    , bytesOf [(0, 255, 0, 255), (255, 255, 0, 255), (0, 255, 255, 255), (255, 255, 255, 255)]
    , flat 1 blue
    ]

-- | A 16 × 16 texture of three levels, 16, 8 and 4 texels across, the last
-- blue and the others red.
deep ∷ DecodedImage
deep = rgba8 False 16 16 [flat 256 red, flat 64 red, flat 16 blue]

-- | One BC7 mode 6 block: two endpoints, each with its four channels in seven
-- bits and a shared low bit, and sixteen 4-bit indices, the first of them 3 bits
-- as the format's anchor texel is. Mode 6 is six zero bits and a one.
mode6Block ∷ (Int, Int, Int, Int, Int) → (Int, Int, Int, Int, Int) → [Int] → ByteString
mode6Block (r0, g0, b0, a0, p0) (r1, g1, b1, a1, p1) indices =
  ByteString.pack (bytes bits)
  where
    field ∷ Int → Int → [Bool]
    field width value = [testBit value i | i ← [0 .. width - 1]]
    bits =
      field 7 64
        <> concatMap (field 7) [r0, r1, g0, g1, b0, b1, a0, a1]
        <> field 1 p0
        <> field 1 p1
        <> case indices of
          anchor : rest → field 3 anchor <> concatMap (field 4) rest
          [] → []
    bytes [] = []
    bytes group = let (byte, rest) = splitAt 8 group in foldr (\bit acc → acc `shiftL` 1 .|. (if bit then 1 else 0)) 0 byte : bytes rest

-- | The endpoints used below, as the bytes they decode to.
endpointZero, endpointOne ∷ Rgba
endpointZero = (201, 41, 121, 255)
endpointOne = (21, 221, 181, 255)

blockWith ∷ [Int] → ByteString
blockWith = mode6Block (100, 20, 60, 127, 1) (10, 110, 90, 127, 1)

bc7 ∷ Int → Int → [ByteString] → DecodedImage
bc7 width height levels =
  DecodedImage
    { decodedFormat = TexelBc7Linear
    , decodedWidth = fromIntegral width
    , decodedHeight = fromIntegral height
    , decodedLevels = levels
    , decodedBinaryAlpha = True
    }

spec ∷ Spec
spec = describe "sampling" $ do
  describe "nearest and linear filtering across a texel boundary" $ do
    -- A 4-pixel sprite on a 2-texel texture: its pixel centres land at 0.25,
    -- 0.75, 1.25 and 1.75 texels, so the boundary lies between pixels.
    let drawn instanceValue =
          mkOracle srgb8 [(h1, redBlue)] [offscreenPass noClear [fullView 8 8 [world [instanceValue]]]]
        stretched = sprite h1 (-2, -1) (4, 1)

    it "takes the texel containing the coordinate under nearest" $ do
      picture (drawn stretched) 0 (8, 8) palette
        `shouldBe` replicate 3 (blank 8) <> ["..RRBB.."] <> replicate 4 (blank 8)

    it "weighs the four texels around coordinate − ½ under linear, in linear light" $ do
      let at x = expect (drawn (linear stretched)) (Probe 0 x 3)
      at 2 `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)
      -- 0.75 red and 0.25 blue in linear light encode to 225 and 137.
      at 3 `shouldBe` Expected (Rgba8 225 0 137 255) (Tolerance 1 0 1 0)
      at 4 `shouldBe` Expected (Rgba8 137 0 225 255) (Tolerance 1 0 1 0)
      at 5 `shouldBe` Expected (Rgba8 0 0 255 255) (Tolerance 0 0 0 0)

    it "resolves the default sampler through the view's filter" $ do
      let viaView filtering =
            mkOracle
              srgb8
              [(h1, redBlue)]
              [ offscreenPass
                  noClear
                  [mkView defaultCamera (fullViewport 8 8) defaultViewSettings {settingFilter = filtering} [world [stretched {instanceSampler = SamplerDefault}]]]
              ]
      expect (viaView FilterNearest) (Probe 0 3 3) `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)
      expect (viaView FilterLinear) (Probe 0 3 3) `shouldBe` Expected (Rgba8 225 0 137 255) (Tolerance 1 0 1 0)

    it "clamps to the edge texel past the texture's edge" $ do
      -- UVs reaching beyond the image repeat nothing: every coordinate past
      -- the last texel reads the last texel.
      let wide = stretched {instanceUv = UvRect 0 0 3 1}
          oracle = mkOracle srgb8 [(h1, redBlue)] [offscreenPass noClear [fullView 8 8 [world [wide]]]]
      -- Pixel 5 is at u = 2.625, which is texel 5 and clamps to the blue one.
      expectAt oracle 5 3 `shouldBe` Expected (Rgba8 0 0 255 255) (Tolerance 0 0 0 0)

  describe "colour spaces" $ do
    let texel = (128, 64, 255, 255)
        shown spec' image = expectAt (mkOracle spec' [(h1, image)] [offscreenPass noClear [fullView 8 8 [world [spriteAt h1 (0, 0)]]]]) 4 4

    it "decodes an sRGB texture on sampling, and stores it encoded on an sRGB target" $
      shown srgb8 (solid True texel) `shouldBe` Expected (Rgba8 128 64 255 255) (Tolerance 0 0 0 0)

    it "decodes an sRGB texture and stores it linear on a UNORM target" $
      -- 128 decodes to 0.2158605 and 64 to 0.0512695: bytes 55 and 13.
      shown unorm8 (solid True texel) `shouldBe` Expected (Rgba8 55 13 255 255) (Tolerance 1 1 0 0)

    it "stores a linear texture unchanged on a UNORM target" $
      shown unorm8 (solid False texel) `shouldBe` Expected (Rgba8 128 64 255 255) (Tolerance 0 0 0 0)

    it "encodes a linear texture on an sRGB target" $
      -- 128/255 encodes to byte 188 and 64/255 to 137.
      shown srgb8 (solid False texel) `shouldBe` Expected (Rgba8 188 137 255 255) (Tolerance 1 1 0 0)

  describe "mip levels" $ do
    let target = unorm8
        drawn instanceValue = mkOracle target [(h1, mipped)] [offscreenPass noClear [fullView 8 8 [world [instanceValue]]]]
        minified = sprite h1 (1, 1) (2, 2)

    it "samples level 1 of a 2:1 minified probe with nearest filtering" $
      picture (drawn minified) 0 (8, 8) palette
        `shouldBe` replicate 5 (blank 8) <> [".....GY.", ".....CW.", blank 8]

    it "samples level 1 of a 2:1 minified probe with linear filtering" $
      picture (drawn (linear minified)) 0 (8, 8) palette
        `shouldBe` replicate 5 (blank 8) <> [".....GY.", ".....CW.", blank 8]

    it "samples level 0 of a magnified or unscaled probe" $ do
      picture (drawn (sprite h1 (-2, -2) (4, 4))) 0 (8, 8) palette
        `shouldBe` replicate 2 (blank 8) <> replicate 4 "..RRRR.." <> replicate 2 (blank 8)
      picture (drawn (sprite h1 (-4, -4) (8, 8))) 0 (8, 8) palette `shouldBe` replicate 8 "RRRRRRRR"

    it "samples the last level once the level of detail reaches it" $ do
      let oracle instanceValue = mkOracle target [(h1, deep)] [offscreenPass noClear [fullView 8 8 [world [instanceValue]]]]
          minifiedHard = sprite h1 (1, 1) (2, 2)
      -- 16 texels over 2 pixels is level 3 of a 3-level texture: level 2.
      expectAt (oracle minifiedHard) 5 5 `shouldBe` Expected (Rgba8 0 0 255 255) (Tolerance 0 0 0 0)
      expectAt (oracle (linear minifiedHard)) 6 6 `shouldBe` Expected (Rgba8 0 0 255 255) (Tolerance 0 0 0 0)

    it "reports a minified probe rotated by 45 degrees as indeterminate" $ do
      let turned = (sprite h1 (0, 0) (1, 1)) {instanceTransform = fromColumns (V2 1.4142135 1.4142135) (V2 (-1.4142135) 1.4142135) (V2 0 0)}
      expectAt (drawn turned) 4 5 `shouldBe` Indeterminate (MinifiedNotAxisAligned (AtInstance 0 0 0 0))

    it "reports a minified probe between two levels as indeterminate" $
      -- 4 texels over 3 pixels is a level of detail of about 0.41.
      expectAt (drawn (sprite h1 (1, 1) (3, 3))) 6 6 `shouldBe` Indeterminate (MinifiedFractionalLevel (AtInstance 0 0 0 0))

    it "reports a level of detail just off a whole number rather than collapsing it" $ do
      -- Levels 0 and 1 are black and level 2 white. A 1.9997-pixel quad over 4
      -- texels has a level of detail of 1.0002, and a linear blend with level 2
      -- at weight 0.0002, brightened 3 times and sRGB encoded, stores byte 2:
      -- reading level 1 alone would say black.
      let blackBlack = rgba8 False 4 4 [flat 16 (0, 0, 0, 255), flat 4 (0, 0, 0, 255), flat 1 (255, 255, 255, 255)]
          bright = defaultViewSettings {settingBrightness = 3}
          at size =
            mkOracle
              srgb8
              [(h1, blackBlack)]
              [offscreenPass noClear [mkView defaultCamera (fullViewport 8 8) bright [world [linear (sprite h1 (1, 1) (size, size))]]]]
      expectAt (at 1.9997) 5 5 `shouldBe` Indeterminate (MinifiedFractionalLevel (AtInstance 0 0 0 0))
      -- Within 2⁻¹⁶ of level 1 the blend is under a fifth of a channel step even
      -- so, and the oracle reads level 1: black, exactly.
      expectAt (at 2.00001) 5 5 `shouldBe` Expected (Rgba8 0 0 0 255) (Tolerance 0 0 0 0)

    it "reads level 0 when the texture has only one level, however minified" $ do
      let turned = (sprite h1 (0, 0) (1, 1)) {instanceTransform = fromColumns (V2 1.4142135 1.4142135) (V2 (-1.4142135) 1.4142135) (V2 0 0)}
          single = mkOracle target [(h1, solid False red)] [offscreenPass noClear [fullView 8 8 [world [turned]]]]
      expectAt single 4 5 `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)

  describe "the placeholder" $ do
    it "samples transparent black for a handle the lookup does not know" $ do
      let oracle =
            mkOracle unorm8 [] [offscreenPass (ClearColour 0.2 0.4 0.6 1) [fullView 8 8 [world [spriteAt h3 (0, 0)]]]]
      -- It draws nothing: the clear shows, 0.2, 0.4 and 0.6 stored as 51, 102
      -- and 153, with the alpha of 1 exact.
      expectAt oracle 4 4 `shouldBe` Expected (Rgba8 51 102 153 255) (Tolerance 1 1 1 0)

    it "tells two handles with one index and two generations apart" $ do
      let stale = textureHandle 1 2
          oracle =
            mkOracle srgb8 [(h1, solid True red)] [offscreenPass noClear [fullView 8 8 [world [spriteAt stale (0, 0), spriteAt h1 (1, 1)]]]]
      picture oracle 0 (8, 8) palette
        `shouldBe` replicate 5 (blank 8) <> [".....R..", blank 8, blank 8]

  describe "BC7" $ do
    let halves = blockWith [if x < 2 then 0 else 15 | _ ← [0 .. 3 ∷ Int], x ← [0 .. 3 ∷ Int]]
        whole = sprite h1 (-2, -2) (4, 4)

    it "samples a BC7 texture through its software-decoded texels" $ do
      let oracle = mkOracle unorm8 [(h1, bc7 4 4 [halves])] [offscreenPass noClear [fullView 8 8 [world [whole]]]]
          exact = Tolerance 0 0 0 0
      expectAt oracle 2 2 `shouldBe` Expected (px endpointZero) exact
      expectAt oracle 3 5 `shouldBe` Expected (px endpointZero) exact
      expectAt oracle 4 2 `shouldBe` Expected (px endpointOne) exact
      expectAt oracle 5 5 `shouldBe` Expected (px endpointOne) exact

    it "samples a decoded BC7 mip level of a minified probe" $ do
      let zeros = blockWith (replicate 16 0)
          ones = blockWith (replicate 16 15)
          oracle = mkOracle unorm8 [(h1, bc7 8 8 [mconcat (replicate 4 zeros), ones])] [offscreenPass noClear [fullView 8 8 [world [whole]]]]
      -- 8 texels over 4 pixels is level 1, whose one block is all second endpoint.
      expectAt oracle 3 3 `shouldBe` Expected (px endpointOne) (Tolerance 0 0 0 0)
