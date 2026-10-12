-- | Colour: the output equations, the premultiplied blend in drawing order,
-- the 8-bit store after every draw, and which channels are exact.
--
-- The expected bytes are worked by hand from @s = m × c@, @s.rgb × b@,
-- additive @s.a = 0@ and @result = s + destination × (1 − s.a)@, with every
-- source clamped to [0, 1] and every store rounded half up to 8 bits.
module Test.Render.TwoD.Oracle.Colour (spec) where

import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (..), Rgba8 (..), Tolerance (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Test.Hspec hiding (Expectation)
import Test.Render.TwoD.Oracle.Support

world ∷ [Instance] → Layer
world = WorldLayer DepthDisabled

-- | An instance drawn additively.
additive ∷ Instance → Instance
additive candidate = candidate {instanceAdditive = True}

-- | The pixel (4, 4), where a unit sprite at the world origin lands.
centre ∷ Oracle → Expectation
centre oracle = expectAt oracle 4 4

-- | An 8 × 8 UNORM target drawing these linear textures, each by its handle, in
-- one view of the given settings and layers.
onUnorm ∷ ClearColour → ViewSettings → [Layer] → Oracle
onUnorm clear settings layers =
  mkOracle
    unorm8
    [(h1, solid False (200, 100, 50, 255)), (h2, solid False (100, 50, 25, 255))]
    [offscreenPass clear [mkView defaultCamera (fullViewport 8 8) settings layers]]

-- | A translucent red and a translucent blue, both half alpha, as linear
-- premultiplied texels.
halfRed, halfBlue ∷ Rgba
halfRed = (128, 0, 0, 128)
halfBlue = (0, 0, 128, 128)

overlapped ∷ ClearColour → [Layer] → Oracle
overlapped clear layers =
  mkOracle
    unorm8
    [(h1, solid False halfRed), (h2, solid False halfBlue), (h3, solid False (255, 0, 0, 255))]
    [offscreenPass clear [fullView 8 8 layers]]

spec ∷ Spec
spec = describe "colour" $ do
  describe "tint, brightness and additive output" $ do
    let drawn settings clear instanceValue = onUnorm clear settings [world [instanceValue]]
        plain = spriteAt h1 (0, 0)

    it "multiplies by the tint componentwise" $
      centre (drawn defaultViewSettings noClear plain {instanceTint = Tint 128 255 255 255})
        -- 200/255 × 128/255 is 0.3936, byte 100; the others carry unchanged.
        `shouldBe` Expected (Rgba8 100 100 50 255) (Tolerance 1 0 0 0)

    it "scales the tint's alpha too" $
      centre (drawn defaultViewSettings noClear plain {instanceTint = Tint 255 255 255 128})
        `shouldBe` Expected (Rgba8 200 100 50 128) (Tolerance 0 0 0 1)

    it "scales colour by the view's brightness and clamps the result to 1" $ do
      -- 200/255 × 2 clamps to 1 and is exactly 255; 100 and 50 double.
      centre (drawn defaultViewSettings {settingBrightness = 2} noClear plain)
        `shouldBe` Expected (Rgba8 255 200 100 255) (Tolerance 0 1 1 0)
      centre (drawn defaultViewSettings {settingBrightness = 1.5} noClear plain)
        `shouldBe` Expected (Rgba8 255 150 75 255) (Tolerance 0 1 1 0)

    it "does not scale alpha by brightness" $ do
      let oracle =
            mkOracle
              unorm8
              [(h3, solid False (100, 100, 100, 128))]
              [offscreenPass noClear [mkView defaultCamera (fullViewport 8 8) defaultViewSettings {settingBrightness = 2} [world [spriteAt h3 (0, 0)]]]]
      -- 100/255 × 2 is 0.784, byte 200, and the alpha stays the texel's 128.
      centre oracle `shouldBe` Expected (Rgba8 200 200 200 128) (Tolerance 1 1 1 0)

    it "adds an additive instance's colour to the destination and leaves its alpha" $
      -- A clear of 0.2 stores 51; 100, 50 and 25 over it sum to 151, 101 and 76.
      -- The alpha of 1 is the clear's, carried exactly.
      centre (drawn defaultViewSettings (ClearColour 0.2 0.2 0.2 1) (additive (spriteAt h2 (0, 0))))
        `shouldBe` Expected (Rgba8 151 101 76 255) (Tolerance 1 1 1 0)

    it "does not make additive colour exact because its alpha is zero" $
      -- Over transparent black the alpha stays 0, but the colour still rounds.
      centre (drawn defaultViewSettings noClear (additive (spriteAt h2 (0, 0))))
        `shouldBe` Expected (Rgba8 100 50 25 0) (Tolerance 1 1 1 0)

    it "keeps additive black exact" $
      centre
        ( mkOracle
            unorm8
            [(h1, solid False (0, 0, 0, 255))]
            [offscreenPass noClear [fullView 8 8 [world [additive (spriteAt h1 (0, 0))]]]]
        )
        `shouldBe` Expected (Rgba8 0 0 0 0) (Tolerance 0 0 0 0)

  describe "the premultiplied blend in drawing order" $ do
    let front = (spriteAt h2 (0, 0)) {instanceDepthKey = 2}
        back = (spriteAt h1 (0, 0)) {instanceDepthKey = 1}

    it "draws a larger depth key over a smaller one, whatever the submission order" $ do
      -- Blue over red: 0.502 + 0.502 × 0.498 alpha rounds to 192; red keeps
      -- 0.502 × 0.498 = 0.25, byte 64; blue is carried at 128.
      let expected = Expected (Rgba8 64 0 128 192) (Tolerance 1 0 0 1)
      centre (overlapped noClear [world [front, back]]) `shouldBe` expected
      centre (overlapped noClear [world [back, front]]) `shouldBe` expected

    it "is not symmetric: red over blue differs" $
      centre (overlapped noClear [world [back {instanceDepthKey = 2}, front {instanceDepthKey = 1}]])
        `shouldBe` Expected (Rgba8 128 0 64 192) (Tolerance 0 0 1 1)

    it "draws equal keys in submission order" $ do
      let equal instanceValue = instanceValue {instanceDepthKey = 5}
      centre (overlapped noClear [world [equal back, equal front]])
        `shouldBe` Expected (Rgba8 64 0 128 192) (Tolerance 1 0 0 1)
      centre (overlapped noClear [world [equal front, equal back]])
        `shouldBe` Expected (Rgba8 128 0 64 192) (Tolerance 0 0 1 1)

    it "draws a UI instance with a larger key over one submitted later" $ do
      let opaqueRed = (spriteAt h3 (4, 4)) {instanceDepthKey = 5}
          opaqueBlue = (spriteAt h2 (4, 4)) {instanceDepthKey = 1}
          oracle =
            mkOracle
              unorm8
              [(h3, solid False (255, 0, 0, 255)), (h2, solid False (0, 0, 255, 255))]
              [offscreenPass noClear [fullView 8 8 [UiLayer [opaqueRed, opaqueBlue]]]]
      -- The smaller key draws first, so the red, drawn last, is what remains.
      centre oracle `shouldBe` Expected (Rgba8 255 0 0 255) (Tolerance 0 0 0 0)

    it "draws a view's layers in order and a pass's views in order" $ do
      let layered =
            mkOracle
              unorm8
              [(h1, solid False (255, 0, 0, 255)), (h2, solid False (0, 0, 255, 255)), (h3, solid False (0, 255, 0, 255))]
              [ offscreenPass
                  noClear
                  [ fullView 8 8 [world [spriteAt h1 (0, 0)], UiLayer [spriteAt h2 (4, 4)]]
                  , fullView 8 8 [world [spriteAt h3 (0, 0)]]
                  ]
              ]
      -- Blue is in the first view's later layer, green in the second view.
      centre layered `shouldBe` Expected (Rgba8 0 255 0 255) (Tolerance 0 0 0 0)
      let oneView =
            mkOracle
              unorm8
              [(h1, solid False (255, 0, 0, 255)), (h2, solid False (0, 0, 255, 255))]
              [offscreenPass noClear [fullView 8 8 [world [spriteAt h1 (0, 0)], UiLayer [spriteAt h2 (4, 4)]]]]
      centre oneView `shouldBe` Expected (Rgba8 0 0 255 255) (Tolerance 0 0 0 0)

    it "blends over a nonzero clear colour" $
      -- Clear 0.2, 0.4, 0.6, 1 stores 51, 102, 153, 255; half red over it.
      centre (overlapped (ClearColour 0.2 0.4 0.6 1) [world [back]])
        `shouldBe` Expected (Rgba8 153 51 76 255) (Tolerance 1 1 1 0)

  describe "the 8-bit store after every draw" $ do
    it "rounds each fragment's result before the next reads it" $ do
      -- Eight sources of byte 4 over transparent black give 32 with a store
      -- after each draw; rounding only at the end would give 30.
      let dim = [(h1, solid False (4, 4, 4, 4))]
          oracle = mkOracle unorm8 dim [offscreenPass noClear [fullView 8 8 [world (replicate 8 (spriteAt h1 (0, 0)))]]]
      centre oracle `shouldBe` Expected (Rgba8 32 32 32 32) (Tolerance 1 1 1 1)

    it "stores the intermediate encoded on an sRGB target and decodes it for the next blend" $ do
      -- Half red stores as encode 0.502 = 188; a second half red blends in
      -- linear light, 0.502 + 0.502 × 0.498 = 0.752, which encodes to 225.
      let oracle =
            mkOracle srgb8 [(h1, solid False halfRed)] [offscreenPass noClear [fullView 8 8 [world [spriteAt h1 (0, 0)]]]]
          twice =
            mkOracle srgb8 [(h1, solid False halfRed)] [offscreenPass noClear [fullView 8 8 [world [spriteAt h1 (0, 0), spriteAt h1 (0, 0)]]]]
      centre oracle `shouldBe` Expected (Rgba8 188 0 0 128) (Tolerance 1 0 0 0)
      centre twice `shouldBe` Expected (Rgba8 225 0 0 192) (Tolerance 1 0 0 1)

  describe "the clear colour" $ do
    it "is exact for a component of 0 or 1 and rounds any other" $ do
      let at format = mkOracle (targetSpec format 8 8) [] [offscreenPass (ClearColour 0 0.5 1 0.5) [fullView 8 8 []]]
      -- On UNORM 0.5 stores 128; on an sRGB target the colour encodes to 188
      -- and the alpha stays linear.
      centre (at R8G8B8A8Unorm) `shouldBe` Expected (Rgba8 0 128 255 128) (Tolerance 0 1 0 1)
      centre (at R8G8B8A8Srgb) `shouldBe` Expected (Rgba8 0 188 255 128) (Tolerance 0 1 0 1)

    it "leaves an untouched pixel transparent black and exact" $
      expectAt (mkOracle unorm8 [] [offscreenPass noClear [fullView 8 8 []]]) 0 0
        `shouldBe` Expected (Rgba8 0 0 0 0) (Tolerance 0 0 0 0)
