-- | The cutout path's window-free evidence (R2D-9): the fixtures that follow,
-- rendered through @hetoimasia-render-2d-vulkan@ into offscreen colour targets
-- that each have a @D32_SFLOAT@ depth image of their extent, every pixel judged
-- against @hetoimasia-render-2d-oracle@ planned with the same marks, by
-- "Test.GPU.Vulkan.Native.OrderedPath"'s runner. Where the device chooses
-- another depth format the suite renders nothing and says so, after checking
-- that the recorder refuses a depth-enabled world layer over a depth image of
-- it.
--
-- Every texture the fixtures draw is marked cutout-safe, so a sprite that is
-- opaque, not translucent and not additive, in a depth-enabled world layer,
-- takes the cutout path; a translucent sprite takes the ordered path, tested
-- against the cutouts' depth and not written. Colour comes from tinting
-- 'White', whose tint alpha stays 255.
--
-- Each fixture names the behaviour it shows by a probe the oracle must give a
-- determinate expectation, which must differ from its contrast's: the same
-- question asked where the behaviour is absent. A fixture that only probed its
-- background would pass whatever the recorder did.
--
-- = The textures
--
-- * 'White' and 'Art' are the ordered path's: 1×1 opaque white, and 2×2 of binary
--   alpha, orange on one diagonal and transparent on the other.
-- * 'Edge': 2×1, transparent black then opaque white. Filtered linearly, the
--   sample between their centres at weight ⅗ is @(0.6, 0.6, 0.6, 0.6)@.
-- * 'Mipped': 4×4 over three levels. Level 0 has one opaque green texel in
--   every 2×2 block, so its coverage is a quarter and a level-0 sample of the
--   block is discarded; levels 1 and 2 are wholly opaque green, as a
--   coverage-preserving chain would hold.
-- * 'LevelZero': the same level 0 alone, the twin that only level-0 sampling
--   can be.
module Test.GPU.Vulkan.Native.CutoutDepth
  ( cutoutSuite
  , cutoutFixtures
  ) where

import qualified Data.ByteString as ByteString
import Data.Word (Word32, Word8)
import Hetoimasia.GPU.Vulkan.Native.Recording (ImageFormat (..))
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Test.GPU.Vulkan.Native.OrderedPath (Suite (..))
import Test.GPU.Vulkan.Native.OrderedPath.Fixtures

-- | The suite: five textures, seven fixtures, and a depth image for every target.
cutoutSuite ∷ Suite
cutoutSuite = Suite "cutout-depth" "cutout-depth-probes.json" cutoutTextures cutoutFixtures True

cutoutTextures ∷ [Texture]
cutoutTextures =
  [texture | texture ← textures, textureKey texture `elem` [White, Art]]
    <> [ Texture Edge Rgba8Linear 2 1 (ByteString.pack (clear <> white)) []
       , Texture Mipped Rgba8Linear 4 4 levelZero [ByteString.pack (concat (replicate 4 green)), ByteString.pack green]
       , Texture LevelZero Rgba8Linear 4 4 levelZero []
       ]
  where
    green = [0, 255, 0, 255] ∷ [Word8]
    white = [255, 255, 255, 255]
    clear = [0, 0, 0, 0]
    -- One opaque texel in every 2×2 block: those whose column and row are even.
    levelZero = ByteString.pack (concat [if even column && even row then green else clear | row ← [0 ∷ Int .. 3], column ← [0 ∷ Int .. 3]])

-- | Every texture the fixtures draw is marked cutout-safe.
marked ∷ [TextureKey]
marked = [White, Art, Edge, Mipped, LevelZero]

cutoutFixtures ∷ [Fixture]
cutoutFixtures = [interleaved, equalKeys, discarded, filteredEdge, minified, twoLayers, mixedLayers]

-- ---------------------------------------------------------------------------
-- Building blocks

-- | An opaque rectangle of this colour, drawn from the white texture: a cutout
-- by routing.
block ∷ Handles → (Word8, Word8, Word8) → Word32 → (Float, Float) → (Float, Float) → Instance
block handles (r, g, b) key origin extent = keyed key (tinted (r, g, b, 255) (quad origin extent (handleOf handles White)))

-- | A translucent half-red rectangle at this key: the ordered path's.
halfRed ∷ Handles → Word32 → (Float, Float) → (Float, Float) → Instance
halfRed handles key origin extent = (keyed key (tinted (255, 0, 0, 128) (quad origin extent (handleOf handles White)))) {instanceTranslucent = True}

-- | A single 32 × 32 view over a depth target, its camera making a world unit a
-- pixel, of these layers.
over32 ∷ TargetShape → [Layer] → Snapshot
over32 shape layers = Snapshot [pass shape (0, 0, 0, 1) [view (0, 0) (32, 32) (identityCamera (32, 32)) defaultViewSettings layers]]

shape32 ∷ TargetShape
shape32 = depthShape 1 Rgba8Linear 32 32

-- ---------------------------------------------------------------------------
-- The fixtures

-- | Cutouts and translucent instances interleaved in one depth-enabled world
-- layer, submitted translucent, cutout, translucent, cutout. In the left
-- square the translucent instance is nearer than the cutout (key 20 over 10),
-- so it blends over it; in the right square it is farther (10 under 20), so the
-- cutout hides it. The plan draws both cutouts first.
interleaved ∷ Fixture
interleaved =
  Fixture
    { fixtureName = "interleaved"
    , fixtureMarked = marked
    , fixtureShapes = [shape32]
    , fixtureSnapshot = \handles →
        over32
          shape32
          [ WorldLayer
              DepthEnabled
              [ halfRed handles 20 (2, 2) (8, 8)
              , block handles (0, 255, 0) 10 (2, 2) (8, 8)
              , halfRed handles 10 (14, 2) (8, 8)
              , block handles (0, 255, 0) 20 (14, 2) (8, 8)
              ]
          ]
    , fixtureNamed =
        [ NamedProbe "a translucent instance nearer than a cutout draws over it, in a layer where they are interleaved" (probe 0 5 5) (probe 0 17 5)
        , NamedProbe "a translucent instance farther than a cutout is hidden by it" (probe 0 17 5) (probe 0 5 5)
        ]
    }

-- | Both equal-key rules. Among cutouts of key 7 the later draw wins: red then
-- green is green at the top left, green then red is red beside it. At an equal
-- key a translucent instance draws over a cutout whatever the submission order:
-- the half-red square, submitted first, is over the blue one at the bottom left,
-- and the blue square alone beside it is the contrast.
equalKeys ∷ Fixture
equalKeys =
  Fixture
    { fixtureName = "equal-keys"
    , fixtureMarked = marked
    , fixtureShapes = [shape32]
    , fixtureSnapshot = \handles →
        over32
          shape32
          [ WorldLayer
              DepthEnabled
              [ block handles (255, 0, 0) 7 (2, 2) (8, 8)
              , block handles (0, 255, 0) 7 (2, 2) (8, 8)
              , block handles (0, 255, 0) 7 (14, 2) (8, 8)
              , block handles (255, 0, 0) 7 (14, 2) (8, 8)
              , halfRed handles 7 (2, 14) (8, 8)
              , block handles (0, 0, 255) 7 (2, 14) (8, 8)
              , block handles (0, 0, 255) 7 (14, 14) (8, 8)
              ]
          ]
    , fixtureNamed =
        [ NamedProbe "among cutouts of an equal key the later draw wins (red then green)" (probe 0 5 5) (probe 0 17 5)
        , NamedProbe "among cutouts of an equal key the later draw wins (green then red)" (probe 0 17 5) (probe 0 5 5)
        , NamedProbe "at an equal key a translucent instance draws over a cutout, though submitted before it" (probe 0 5 17) (probe 0 17 17)
        ]
    }

-- | A discarded fragment writes no depth. The nearer cutout, key 20, is the art
-- whose top-right and bottom-left texels are transparent, and is submitted
-- first; the farther one, blue at key 5, is submitted after it. Where the nearer
-- is transparent the farther shows: had the discarded fragment written its
-- depth, the later, farther draw would fail the test there.
discarded ∷ Fixture
discarded =
  Fixture
    { fixtureName = "discarded"
    , fixtureMarked = marked
    , fixtureShapes = [shape32]
    , fixtureSnapshot = \handles →
        over32
          shape32
          [ WorldLayer
              DepthEnabled
              [ keyed 20 (quad (4, 4) (8, 8) (handleOf handles Art))
              , block handles (0, 0, 255) 5 (4, 4) (8, 8)
              ]
          ]
    , fixtureNamed =
        [ NamedProbe "a nearer cutout's discarded fragment leaves the farther cutout visible, and writes no depth" (probe 0 10 6) (probe 0 6 6)
        , NamedProbe "a nearer cutout's surviving fragment hides the farther one" (probe 0 6 6) (probe 0 10 6)
        ]
    }

-- | A linearly filtered cutout edge: the 2×1 texture, transparent then white,
-- stretched over ten pixels. Pixel 5's centre is at u = 0.55, weight ⅗ of white:
-- the sample is @(0.6, 0.6, 0.6, 0.6)@, alpha above a half, so the fragment
-- survives and writes its colour un-premultiplied, white and not grey. Pixel 3,
-- at weight ⅕, is below a half and is discarded.
filteredEdge ∷ Fixture
filteredEdge =
  Fixture
    { fixtureName = "filtered-edge"
    , fixtureMarked = marked
    , fixtureShapes = [shape32]
    , fixtureSnapshot = \handles → over32 shape32 [WorldLayer DepthEnabled [sampled SamplerLinear (quad (0, 4) (10, 4) (handleOf handles Edge))]]
    , fixtureNamed =
        [ NamedProbe "a filtered edge sample of (0.6, 0.6, 0.6, 0.6) writes white, not grey" (probe 0 5 5) (probe 0 3 5)
        , NamedProbe "a filtered edge sample below an alpha of a half is discarded" (probe 0 3 5) (probe 0 5 5)
        ]
    }

-- | A minified cutout texture samples its mips. Two 2 × 2-pixel sprites of
-- the 4 × 4 texture, so the level of detail is exactly 1: the first uses the
-- chain, whose level 1 is opaque, and the second is the twin of level 0 alone,
-- whose quarter coverage is discarded. The chain's pixel is green; the twin's is
-- the clear, so the expected result is distinguishable from level-zero-only
-- sampling.
minified ∷ Fixture
minified =
  Fixture
    { fixtureName = "minified"
    , fixtureMarked = marked
    , fixtureShapes = [shape16]
    , fixtureSnapshot = \handles →
        Snapshot
          [ pass
              shape16
              (0, 0, 0, 1)
              [ view
                  (0, 0)
                  (16, 16)
                  (identityCamera (16, 16))
                  defaultViewSettings
                  [ WorldLayer
                      DepthEnabled
                      [ sampled SamplerLinear (quad (2, 2) (2, 2) (handleOf handles Mipped))
                      , sampled SamplerLinear (quad (8, 2) (2, 2) (handleOf handles LevelZero))
                      ]
                  ]
              ]
          ]
    , fixtureNamed =
        [ NamedProbe "a 2:1 minified cutout samples level 1 of its chain, which level-0-only sampling would discard" (probe 0 2 2) (probe 0 8 2)
        , NamedProbe "the same minified texture without its chain is discarded, as level 0 alone gives" (probe 0 8 2) (probe 0 2 2)
        , NamedProbe "the chain's other pixel samples its level 1 too" (probe 0 3 3) (probe 0 9 3)
        ]
    }
  where
    shape16 = depthShape 1 Rgba8Linear 16 16

-- | Two depth-enabled world layers in one view. The first draws red at key
-- 100; the second, green at key 1, overlaps it. The second layer clears depth
-- itself, so its far key is not hidden by the first's near one: the overlap is
-- green.
twoLayers ∷ Fixture
twoLayers =
  Fixture
    { fixtureName = "two-layers"
    , fixtureMarked = marked
    , fixtureShapes = [shape32]
    , fixtureSnapshot = \handles →
        over32
          shape32
          [ WorldLayer DepthEnabled [block handles (255, 0, 0) 100 (4, 4) (16, 16)]
          , WorldLayer DepthEnabled [block handles (0, 255, 0) 1 (12, 12) (16, 16)]
          ]
    , fixtureNamed =
        [ NamedProbe "the second depth-enabled layer's keys are independent of the first's: green at key 1 over red at key 100" (probe 0 16 16) (probe 0 8 8)
        , NamedProbe "the first layer's own area is its own" (probe 0 8 8) (probe 0 16 16)
        ]
    }

-- | A depth pass that also holds a UI layer and a world layer without depth.
-- A depth-enabled layer draws red at key 50. The UI layer's blue square is over
-- it, and a world layer without depth draws green at key 1 over both, though
-- that key is farther than the red's: neither layer tests or writes depth.
mixedLayers ∷ Fixture
mixedLayers =
  Fixture
    { fixtureName = "mixed-layers"
    , fixtureMarked = marked
    , fixtureShapes = [shape32]
    , fixtureSnapshot = \handles →
        over32
          shape32
          [ WorldLayer DepthEnabled [block handles (255, 0, 0) 50 (2, 2) (16, 16)]
          , UiLayer [tinted (0, 0, 255, 255) (quad (6, 6) (8, 8) (handleOf handles White))]
          , WorldLayer DepthDisabled [block handles (0, 255, 0) 1 (10, 10) (10, 10)]
          ]
    , fixtureNamed =
        [ NamedProbe "a UI layer in a depth pass draws over a cutout without a depth test" (probe 0 8 8) (probe 0 4 4)
        , NamedProbe "a world layer without depth in a depth pass draws over a nearer cutout" (probe 0 16 16) (probe 0 4 4)
        ]
    }
