-- | Placement and coverage, against pictures written by hand.
--
-- Every expectation here comes from the equations in the README worked on
-- paper: the camera's position lands at the viewport's centre, a unit of world
-- spans @zoom@ pixels (or @viewportHeight × zoom ÷ (2h)@ in fixed half-height
-- mode), a camera turned by @θ@ puts the world's +X axis along the target's
-- @(cos θ, −sin θ)@, UI maps through @origin + ui × scale × content scale@, and
-- pixel snap rounds the world transform's translation and each instance's
-- origin. None of them is computed by the oracle or by "Hetoimasia.Render.TwoD.Mapping".
module Test.Render.TwoD.Oracle.Placement (spec) where

import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (..), Rgba8 (..), Tolerance (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), ZoomMode (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (Location (..))
import Test.Hspec hiding (Expectation)
import Test.Render.TwoD.Oracle.Support

red ∷ Rgba
red = (255, 0, 0, 255)

green ∷ Rgba
green = (0, 255, 0, 255)

blue ∷ Rgba
blue = (0, 0, 255, 255)

world ∷ [Instance] → Layer
world = WorldLayer DepthDisabled

blank ∷ Int → String
blank width = replicate width '.'

spec ∷ Spec
spec = describe "placement and coverage" $ do
  describe "the camera and the viewport" $ do
    it "puts the camera's position at the viewport's centre" $ do
      let oracle =
            mkOracle srgb8 [(h1, solid True red)] $
              [ offscreenPass noClear [mkView (Camera (V2 10 20) 1 Nothing) (fullViewport 8 8) defaultViewSettings [world [spriteAt h1 (10, 20)]]]
              ]
      picture oracle 0 (8, 8) palette
        `shouldBe` [ "........"
                   , "........"
                   , "........"
                   , "........"
                   , "....R..."
                   , "........"
                   , "........"
                   , "........"
                   ]

    it "spaces whole-number zoom evenly in pixels per unit" $ do
      let target = targetSpec R8G8B8A8Srgb 16 8
          oracle =
            mkOracle target [(h1, solid True red), (h2, solid True blue)] $
              [ offscreenPass noClear [mkView (Camera (V2 0 0) 3 Nothing) (fullViewport 16 8) defaultViewSettings [world [spriteAt h1 (0, 0), spriteAt h2 (1, 0)]]]
              ]
      picture oracle 0 (16, 8) palette
        `shouldBe` replicate 4 (blank 16) <> replicate 3 "........RRRBBB.." <> [blank 16]

    it "spaces whole-number zoom evenly in fixed half-height mode" $ do
      let target = targetSpec R8G8B8A8Srgb 16 8
          settings = defaultViewSettings {settingZoomMode = FixedHalfHeight 2}
          oracle =
            mkOracle target [(h1, solid True red), (h2, solid True blue)] $
              [ offscreenPass noClear [mkView (Camera (V2 0 0) 2 Nothing) (fullViewport 16 8) settings [world [spriteAt h1 (0, 0), spriteAt h2 (1, 0)]]]
              ]
      -- 8 × 2 ÷ (2 × 2) = 4 pixels a unit.
      picture oracle 0 (16, 8) palette
        `shouldBe` replicate 4 (blank 16) <> replicate 4 "........RRRRBBBB"

    it "shows the same extent of world at any resolution in fixed half-height mode" $ do
      let target = targetSpec R8G8B8A8Srgb 16 16
          settings = defaultViewSettings {settingZoomMode = FixedHalfHeight 2}
          oracle =
            mkOracle target [(h1, solid True red), (h2, solid True blue)] $
              [ offscreenPass noClear [mkView (Camera (V2 0 0) 1 Nothing) (fullViewport 16 16) settings [world [spriteAt h1 (0, 0), spriteAt h2 (1, 0)]]]
              ]
      -- 16 × 1 ÷ (2 × 2) = 4 pixels a unit again, from a taller viewport.
      picture oracle 0 (16, 16) palette
        `shouldBe` replicate 8 (blank 16) <> replicate 4 "........RRRRBBBB" <> replicate 4 (blank 16)

    it "turns the world by a quarter turn when the camera does" $ do
      -- World +X lies above the centre and +Y to its right.
      let oracle =
            mkOracle srgb8 [(h1, solid True red), (h2, solid True green)] $
              [ offscreenPass noClear [mkView (Camera (V2 0 0) 1 (Just (pi / 2))) (fullViewport 8 8) defaultViewSettings [world [spriteAt h1 (2, 0), spriteAt h2 (0, 2)]]]
              ]
      picture oracle 0 (8, 8) palette
        `shouldBe` [ "........"
                   , "....R..."
                   , "........"
                   , "......G."
                   , "........"
                   , "........"
                   , "........"
                   , "........"
                   ]

    it "draws only inside the viewport" $ do
      let oracle =
            mkOracle srgb8 [(h1, solid True red)] $
              [ offscreenPass noClear [mkView defaultCamera (Viewport (V2 2 2) (V2 4 4)) defaultViewSettings [world [sprite h1 (-4, -4) (8, 8)]]]
              ]
      picture oracle 0 (8, 8) palette
        `shouldBe` replicate 2 (blank 8) <> replicate 4 "..RRRR.." <> replicate 2 (blank 8)

    it "draws nothing in an empty viewport, and says so without refusing" $ do
      let oracle =
            mkOracle srgb8 [(h1, solid True red)] $
              [ offscreenPass noClear [mkView defaultCamera (Viewport (V2 0 0) (V2 0 8)) defaultViewSettings [world [sprite h1 (-4, -4) (8, 8)]]]
              ]
      picture oracle 0 (8, 8) palette `shouldBe` replicate 8 (blank 8)

  describe "UI space" $ do
    it "maps UI pixels one to one at content scale 1" $ do
      let oracle =
            mkOracle srgb8 [(h1, solid True red)] $
              [offscreenPass noClear [fullView 8 8 [UiLayer [spriteAt h1 (1, 1)]]]]
      picture oracle 0 (8, 8) palette
        `shouldBe` [blank 8, ".R......"] <> replicate 6 (blank 8)

    it "doubles a UI unit at content scale 2" $ do
      let metrics = TargetMetrics (PixelExtent 4 4) (PixelExtent 8 8) 2 2
          oracle =
            mkOracle (TargetSpec metrics R8G8B8A8Srgb (PixelExtent 8 8)) [(h1, solid True red)] $
              [offscreenPass noClear [fullView 8 8 [UiLayer [spriteAt h1 (1, 1)]]]]
      picture oracle 0 (8, 8) palette
        `shouldBe` replicate 2 (blank 8) <> replicate 2 "..RR...." <> replicate 4 (blank 8)

    it "multiplies the UI scale setting into the content scale" $ do
      let settings = defaultViewSettings {settingUiScale = 2}
          oracle =
            mkOracle srgb8 [(h1, solid True red)] $
              [offscreenPass noClear [mkView defaultCamera (fullViewport 8 8) settings [UiLayer [spriteAt h1 (1, 1)]]]]
      picture oracle 0 (8, 8) palette
        `shouldBe` replicate 2 (blank 8) <> replicate 2 "..RR...." <> replicate 4 (blank 8)

    it "measures UI from the viewport's origin and clips to the viewport" $ do
      let oracle =
            mkOracle srgb8 [(h1, solid True red), (h2, solid True green)] $
              [ offscreenPass noClear [mkView defaultCamera (Viewport (V2 2 2) (V2 6 6)) defaultViewSettings [UiLayer [spriteAt h1 (0, 0), spriteAt h2 (-1, 0)]]]
              ]
      picture oracle 0 (8, 8) palette
        `shouldBe` replicate 2 (blank 8) <> ["..R....."] <> replicate 5 (blank 8)

  describe "pixel snap" $ do
    let snapping = defaultViewSettings {settingPixelSnap = True}

    it "moves a world sprite rigidly by the rounding of its origin" $ do
      let at settings =
            mkOracle srgb8 [(h1, solid True red)] $
              [offscreenPass noClear [mkView defaultCamera (fullViewport 8 8) settings [world [sprite h1 (1.4, 1.4) (1.2, 1.2)]]]]
      -- The origin 5.4 rounds to 5, so the 1.2-pixel quad covers [5, 6.2].
      picture (at snapping) 0 (8, 8) palette
        `shouldBe` replicate 5 (blank 8) <> [".....R..", blank 8, blank 8]
      -- Unsnapped it covers [5.4, 6.6], which holds two pixel centres a side.
      picture (at defaultViewSettings) 0 (8, 8) palette
        `shouldBe` replicate 5 (blank 8) <> replicate 2 ".....RR." <> [blank 8]

    it "rounds the camera's translation and then the origin" $ do
      let at settings =
            mkOracle srgb8 [(h1, solid True red)] $
              [offscreenPass noClear [mkView (Camera (V2 0.4 0) 1 Nothing) (fullViewport 8 8) settings [world [spriteAt h1 (0.6, 0)]]]]
      -- Translation 3.6 rounds to 4, the origin 4.6 to 5.
      picture (at snapping) 0 (8, 8) palette
        `shouldBe` replicate 4 (blank 8) <> [".....R..", blank 8, blank 8, blank 8]
      -- Unsnapped the quad covers [4.2, 5.2].
      picture (at defaultViewSettings) 0 (8, 8) palette
        `shouldBe` replicate 4 (blank 8) <> ["....R...", blank 8, blank 8, blank 8]

    it "rounds a UI instance's origin and keeps its size" $ do
      let at settings =
            mkOracle srgb8 [(h1, solid True red)] $
              [offscreenPass noClear [mkView defaultCamera (fullViewport 8 8) settings [UiLayer [sprite h1 (1.4, 1.4) (1.2, 1.2)]]]]
      picture (at snapping) 0 (8, 8) palette
        `shouldBe` [blank 8, ".R......"] <> replicate 6 (blank 8)
      picture (at defaultViewSettings) 0 (8, 8) palette
        `shouldBe` [blank 8] <> replicate 2 ".RR....." <> replicate 5 (blank 8)

  describe "degenerate and reflected quads" $ do
    it "places a reflected quad with its texture reflected" $ do
      let texture = rgba8 True 2 1 [[255, 0, 0, 255, 0, 0, 255, 255]]
          oracle =
            mkOracle srgb8 [(h1, texture)] $
              [offscreenPass noClear [fullView 8 8 [world [sprite h1 (1, -2) (-2, 1)]]]]
      picture oracle 0 (8, 8) palette
        `shouldBe` replicate 2 (blank 8) <> ["...BR..."] <> replicate 5 (blank 8)

    it "lets a zero-area quad contribute nothing, however it is singular" $ do
      let flatScale = (spriteAt h1 (0, 0)) {instanceTransform = fromColumns (V2 0 0) (V2 0 1) (V2 0 0)}
          collinear = (spriteAt h1 (0, 0)) {instanceTransform = fromColumns (V2 1 1) (V2 2 2) (V2 0 0)}
          oracle =
            mkOracle srgb8 [(h1, solid True red)] $
              [offscreenPass noClear [fullView 8 8 [world [flatScale, collinear, spriteAt h1 (1, 1)]]]]
      picture oracle 0 (8, 8) palette
        `shouldBe` replicate 5 (blank 8) <> [".....R..", blank 8, blank 8]

    it "refuses a quad whose corners cannot be held, unlike a singular one" $ do
      let huge = (spriteAt h1 (0, 0)) {instanceTransform = fromColumns (V2 3.0e38 0) (V2 0 3.0e38) (V2 0 0)}
          oracle =
            mkOracle srgb8 [(h1, solid True red)] $
              [offscreenPass noClear [mkView (Camera (V2 0 0) 10 Nothing) (Viewport (V2 0 0) (V2 4 8)) defaultViewSettings [world [huge]]]]
      expectAt oracle 2 2 `shouldBe` Unevaluable (PlacementNotRepresentable (AtInstance 0 0 0 0))
      -- Outside the viewport the instance is not drawn, so nothing is refused.
      expectAt oracle 6 2 `shouldBe` Expected (Rgba8 0 0 0 0) (Tolerance 0 0 0 0)

    it "refuses a view whose mapping cannot be held, when an instance needs it" $ do
      let camera = Camera (V2 2.0e38 0) 2 Nothing
          drawing =
            mkOracle srgb8 [(h1, solid True red)] $
              [offscreenPass noClear [mkView camera (fullViewport 8 8) defaultViewSettings [world [spriteAt h1 (0, 0)]]]]
          empty =
            mkOracle srgb8 [(h1, solid True red)] $
              [offscreenPass noClear [mkView camera (fullViewport 8 8) defaultViewSettings [world []]]]
      expectAt drawing 4 4 `shouldBe` Unevaluable (MappingNotRepresentable (AtView 0 0))
      expectAt empty 4 4 `shouldBe` Expected (Rgba8 0 0 0 0) (Tolerance 0 0 0 0)
