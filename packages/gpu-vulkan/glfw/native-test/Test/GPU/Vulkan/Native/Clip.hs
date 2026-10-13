-- | Clipping's window-free evidence (R2D-12): the fixtures that follow, rendered
-- through @hetoimasia-render-2d-vulkan@ into offscreen colour targets, every
-- pixel judged against @hetoimasia-render-2d-oracle@ by
-- "Test.GPU.Vulkan.Native.OrderedPath"'s runner. The recorder writes each
-- batch's clip tables into one ring region, binds it as the storage table, and
-- the fragment stage discards a fragment outside its instance's clip; the
-- oracle applies the resolved tables itself.
--
-- Each fixture names the behaviour it shows by probes the oracle must give a
-- determinate expectation, which must differ from their contrast's: the same
-- question asked where the behaviour is absent. A fixture that only probed its
-- background would pass whatever the recorder did.
--
-- Every sprite is the one 'White' texture tinted, so a pixel is the tint's
-- colour or the pass's clear. A fixture's rectangles and the pixels it probes
-- are worked out in its own comment, from the mapping's equations (see
-- "Hetoimasia.Render.TwoD.Mapping"), keeping every probed centre well clear of
-- a clip's boundary.
--
-- = The textures
--
-- * 'White': 1×1 linear RGBA8, opaque white, the canvas tints are drawn on.
module Test.GPU.Vulkan.Native.Clip
  ( clipSuite
  , clipFixtures
  ) where

import Data.Word (Word8)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Clip (ClipEntry (..), ClipRect (..))
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.GPU.Vulkan.Native.Recording (ImageFormat (..))
import Test.GPU.Vulkan.Native.OrderedPath (Suite (..))
import Test.GPU.Vulkan.Native.OrderedPath.Fixtures

-- | The suite: one texture, seven fixtures, over a depth image where a fixture asks
-- for one.
clipSuite ∷ Suite
clipSuite = Suite "clip" "clip-probes.json" [texture | texture ← textures, textureKey texture == White] clipFixtures True

clipFixtures ∷ [Fixture]
clipFixtures = [oneDraw, ownTables, uiScales, snapping, farCamera, cutouts, empties]

-- ---------------------------------------------------------------------------
-- Building blocks

-- | A view of this viewport, camera, settings, clip table and layers.
clipView ∷ (Float, Float) → (Float, Float) → Camera → ViewSettings → [ClipEntry] → [Layer] → View
clipView (x, y) (w, h) camera settings = View camera (Viewport (V2 x y) (V2 w h)) settings

-- | A clip entry: this origin and extent, no parent.
rect ∷ (Float, Float) → (Float, Float) → ClipEntry
rect (x, y) (w, h) = ClipEntry (ClipRect (V2 x y) (V2 w h)) Nothing

-- | The same under this parent entry.
under ∷ Int → ClipEntry → ClipEntry
under parent entry = entry {clipParent = Just parent}

-- | An instance with this clip index.
clipped ∷ Word → Instance → Instance
clipped index candidate = candidate {instanceClip = fromIntegral index}

-- | An opaque rectangle of this colour from the white texture.
paint ∷ Handles → (Word8, Word8, Word8) → (Float, Float) → (Float, Float) → Instance
paint handles (r, g, b) origin extent = tinted (r, g, b, 255) (quad origin extent (handleOf handles White))

shape32 ∷ TargetShape
shape32 = offscreenShape 1 Rgba8Linear 32 32

-- ---------------------------------------------------------------------------
-- The fixtures

-- | A camera turned by an eighth of a turn about the viewport's centre (16, 16),
-- and in one world layer, one draw of three instances, each covering the whole
-- target: a blue one with no clip, a green one clipped to the world square
-- [-8, 8)² (entry 0), and a red one clipped to the nested entry 1, the world
-- strip x in [0, 40) and y in [-30, 30) under entry 0, which leaves x in [0, 8) and
-- y in [-8, 8) of that square.
--
-- Under the camera a target pixel centre at offset @d@ from (16, 16) is the
-- world point @R(θ) d@, with θ = π/4, so the square is a diamond of half-diagonal
-- 11.3 pixels with world +X toward the upper right and world +Y toward the lower
-- right:
--
-- * pixel (2, 2), offset (-13.5, -13.5), is the world point (0, -19.1): outside the
--   square, so blue;
-- * pixel (11, 17), offset (-4.5, 1.5), is (-4.24, -2.12): inside the square and
--   left of the strip, so green;
-- * pixel (20, 14), offset (4.5, -1.5), is (4.24, 2.12): inside both, so red;
-- * pixel (27, 24), offset (11.5, 8.5), is (2.12, 14.1): inside the strip, which
--   reaches to y = 30, but outside the square its parent allows, so blue.
oneDraw ∷ Fixture
oneDraw =
  Fixture
    { fixtureName = "one-draw"
    , fixtureMarked = []
    , fixtureShapes = [shape32]
    , fixtureSnapshot = \handles →
        let camera = Camera (V2 0 0) 1 (Just (realToFrac (pi / 4 ∷ Double)))
            everything colour' index = clipped index (paint handles colour' (-40, -40) (80, 80))
         in Snapshot
              [ pass
                  shape32
                  (0, 0, 0, 1)
                  [ clipView
                      (0, 0)
                      (32, 32)
                      camera
                      defaultViewSettings
                      [rect (-8, -8) (16, 16), under 0 (rect (0, -30) (40, 60))]
                      [ WorldLayer
                          DepthDisabled
                          [everything (0, 0, 255) 0, everything (0, 255, 0) 1, everything (255, 0, 0) 2]
                      ]
                  ]
              ]
    , fixtureNamed =
        [ NamedProbe "an instance with no clip draws outside every clip, in the same draw as clipped ones" (probe 0 2 2) (probe 0 11 17)
        , NamedProbe "a clip under a turned camera trims its instance to the turned rectangle" (probe 0 11 17) (probe 0 2 2)
        , NamedProbe "a nested clip leaves only the child's share of its parent" (probe 0 20 14) (probe 0 11 17)
        , NamedProbe "a nested clip is still cut by its parent where the child's own rectangle reaches past it" (probe 0 27 24) (probe 0 20 14)
        ]
    }

-- | Two views of one 32 × 16 target, each with its own table, whose entry 0 is
-- the same clip index 1 in both: the left view's is the UI rectangle (2, 2) 6 × 6
-- and the right view's (4, 4) 8 × 8 from its own viewport origin (16, 0), which
-- is x in [20, 28) and y in [4, 12). Each draws a red sprite far larger than its
-- viewport.
ownTables ∷ Fixture
ownTables =
  Fixture
    { fixtureName = "own-tables"
    , fixtureMarked = []
    , fixtureShapes = [shape]
    , fixtureSnapshot = \handles →
        let red = clipped 1 (paint handles (255, 0, 0) (0, 0) (100, 100))
            at origin entry = clipView origin (16, 16) (identityCamera (16, 16)) defaultViewSettings [entry] [UiLayer [red]]
         in Snapshot
              [ pass
                  shape
                  (0, 0, 0, 1)
                  [at (0, 0) (rect (2, 2) (6, 6)), at (16, 0) (rect (4, 4) (8, 8))]
              ]
    , fixtureNamed =
        [ NamedProbe "the left view's index 1 selects the left view's rectangle" (probe 0 5 5) (probe 0 12 5)
        , NamedProbe "the right view's index 1 selects the right view's rectangle, from its own viewport origin" (probe 0 24 8) (probe 0 18 8)
        ]
    }
  where
    shape = offscreenShape 1 Rgba8Linear 32 16

-- | A UI layer at UI scale 1 and content scale 2, in a viewport that does not
-- start at the target's origin: the target is 32 × 32 pixels, its logical extent
-- 16 × 16, the viewport (4, 4) 24 × 24, so a UI point maps to @4 + 2 · ui@. The
-- clip (2, 2) 6 × 6 is therefore x and y in [8, 20).
uiScales ∷ Fixture
uiScales =
  Fixture
    { fixtureName = "ui-scales"
    , fixtureMarked = []
    , fixtureShapes = [shape]
    , fixtureSnapshot = \handles →
        Snapshot
          [ pass
              shape
              (0, 0, 0, 1)
              [ clipView
                  (4, 4)
                  (24, 24)
                  (identityCamera (24, 24))
                  defaultViewSettings
                  [rect (2, 2) (6, 6)]
                  [UiLayer [clipped 1 (paint handles (0, 255, 0) (0, 0) (100, 100))]]
              ]
          ]
    , fixtureNamed =
        [ NamedProbe "a UI clip is in UI points: scaled by the content scale and offset by the viewport's origin" (probe 0 12 12) (probe 0 6 12)
        , NamedProbe "a UI clip ends where the scaled rectangle does" (probe 0 18 12) (probe 0 22 12)
        ]
    }
  where
    shape = (offscreenShape 1 Rgba8Linear 32 32) {shapeMetrics = TargetMetrics (PixelExtent 16 16) (PixelExtent 32 32) 2 2}

-- | A world layer under pixel snap and zoom 2 with the camera at (0.25, 0) over a
-- 32 × 32 viewport, so the translation 16 − 0.5 = 15.5 snaps to 16 and a world x
-- is at @2 x + 16@. The clip is x in [0.2, 1.4), which is [16.4, 18.8) on the
-- target. The red sprite's origin is world (-19.7, -20), at -23.4 on the target,
-- which the vertex shader snaps to -23, 0.4 pixel to the right; it covers the
-- target either way.
--
-- * pixel 16 (centre 16.5) is inside: it is outside if the clip followed the
--   sprite's snap, by 0.4 pixel, to [16.8, 19.2);
-- * pixel 18 (centre 18.5) is inside: it is outside if the translation were not
--   snapped, which would end the clip at 18.3;
-- * pixel 19 is outside.
snapping ∷ Fixture
snapping =
  Fixture
    { fixtureName = "snapping"
    , fixtureMarked = []
    , fixtureShapes = [shape32]
    , fixtureSnapshot = \handles →
        Snapshot
          [ pass
              shape32
              (0, 0, 0, 1)
              [ clipView
                  (0, 0)
                  (32, 32)
                  (Camera (V2 0.25 0) 2 Nothing)
                  defaultViewSettings {settingPixelSnap = True}
                  [rect (0.2, -20) (1.2, 40)]
                  [WorldLayer DepthDisabled [clipped 1 (paint handles (255, 0, 0) (-19.7, -20) (40, 40))]]
              ]
          ]
    , fixtureNamed =
        [ NamedProbe "a clip does not follow a sprite's origin snap" (probe 0 16 16) (probe 0 19 16)
        , NamedProbe "a clip is placed by the view's snapped translation" (probe 0 18 16) (probe 0 19 16)
        ]
    }


-- | A view looking at a distant place: the camera at (65536, 0) at zoom 100 over a
-- 32 × 32 viewport puts world x = 65536 at pixel 16, so the transform's
-- translation is (-6553584, 16) and a world x is at @100 x − 6553584@. The red
-- sprite covers world x in [65536, 65537), pixels 16 to 115, and the clip from
-- (65536.1484375, -1) of extent (0.5, 2) is x in [30.84375, 80.84375) on the
-- target: pixel 30 (centre 30.5) is 0.34 pixel outside it, and pixel 31 inside.
-- A single-precision absolute world coordinate near 65536 is spaced 1/128 apart,
-- which at this zoom is most of a pixel: mapping the fragment back to the world
-- would give 65536.1484375 for pixel 30's centre, whose exact value is 65536.145,
-- and admit it. The clip test is taken about the world point under the
-- scissor's centre, so it does not.
farCamera ∷ Fixture
farCamera =
  Fixture
    { fixtureName = "far-camera"
    , fixtureMarked = []
    , fixtureShapes = [shape32]
    , fixtureSnapshot = \handles →
        Snapshot
          [ pass
              shape32
              (0, 0, 0, 1)
              [ clipView
                  (0, 0)
                  (32, 32)
                  (Camera (V2 65536 0) 100 Nothing)
                  defaultViewSettings
                  [rect (65536.1484375, -1) (0.5, 2)]
                  [WorldLayer DepthDisabled [clipped 1 (paint handles (255, 0, 0) (65536, -1) (1, 2))]]
              ]
          ]
    , fixtureNamed =
        [ NamedProbe "a clip far from the origin keeps its edge where the exact transform puts it: pixel 31 is inside it" (probe 0 31 16) (probe 0 30 16)
        , NamedProbe "a clip far from the origin does not admit the pixel 0.34 pixel outside its edge, which a coarse absolute coordinate would" (probe 0 30 16) (probe 0 31 16)
        , NamedProbe "the sprite's own pixels short of the clip draw nothing" (probe 0 20 16) (probe 0 31 16)
        ]
    }

-- | The cutout path: two opaque rectangles over x in [4, 28), the nearer one
-- (key 9, green) clipped to x in [16, 32) and the farther one (key 1, red) not.
-- Where the nearer one is clipped away it writes neither colour nor depth, so
-- the farther one shows through; where its clip holds it hides the farther one.
cutouts ∷ Fixture
cutouts =
  Fixture
    { fixtureName = "cutouts"
    , fixtureMarked = [White]
    , fixtureShapes = [deep]
    , fixtureSnapshot = \handles →
        Snapshot
          [ pass
              deep
              (0, 0, 0, 1)
              [ clipView
                  (0, 0)
                  (32, 32)
                  (identityCamera (32, 32))
                  defaultViewSettings
                  [rect (16, 0) (16, 32)]
                  [ WorldLayer
                      DepthEnabled
                      [ keyed 9 (clipped 1 (paint handles (0, 255, 0) (4, 4) (24, 24)))
                      , keyed 1 (paint handles (255, 0, 0) (4, 4) (24, 24))
                      ]
                  ]
              ]
          ]
    , fixtureNamed =
        [ NamedProbe "a cutout clipped away exposes the farther cutout, having written no depth" (probe 0 8 16) (probe 0 24 16)
        , NamedProbe "a cutout inside its clip hides the farther one" (probe 0 24 16) (probe 0 8 16)
        ]
    }
  where
    deep = depthShape 1 Rgba8Linear 32 32

-- | An empty clip, a zero-extent rectangle, and a descendant of it whose own
-- rectangle is the whole target, both clip everything: a red instance under the
-- descendant shows nowhere, beside a blue unclipped one at the corner.
empties ∷ Fixture
empties =
  Fixture
    { fixtureName = "empties"
    , fixtureMarked = []
    , fixtureShapes = [shape32]
    , fixtureSnapshot = \handles →
        Snapshot
          [ pass
              shape32
              (0, 0, 0, 1)
              [ clipView
                  (0, 0)
                  (32, 32)
                  (identityCamera (32, 32))
                  defaultViewSettings
                  [rect (4.5, 4.5) (0, 0), under 0 (rect (0, 0) (100, 100))]
                  [ UiLayer
                      [ paint handles (0, 0, 255) (0, 0) (4, 4)
                      , clipped 2 (paint handles (255, 0, 0) (0, 0) (100, 100))
                      , clipped 1 (paint handles (255, 0, 0) (0, 0) (100, 100))
                      ]
                  ]
              ]
          ]
    , fixtureNamed =
        [ NamedProbe "an empty clip, and a clip under one, clip everything" (probe 0 16 16) (probe 0 2 2)
        , NamedProbe "an unclipped instance beside them still draws" (probe 0 2 2) (probe 0 16 16)
        ]
    }
