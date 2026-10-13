-- | The ordered path's evidence fixtures (R2D-7): the textures, the targets
-- and the snapshots a surface-free session renders, and the probes that
-- distinguish each rendering behaviour the issue lists.
--
-- Everything here is pure. A fixture is a snapshot builder over the textures'
-- handles, the shape of each offscreen target its passes draw to (pass @i@
-- draws to shape @i@), and the named probes whose expectations the oracle must
-- give determinately and must differ from their contrast's — the same
-- question asked where the behaviour is absent. A fixture that only probed its
-- background would pass whatever the recorder did; a named probe whose value
-- equals its contrast's would too, so the pair is checked.
--
-- A fixture names the textures it marks cutout-safe ('fixtureMarked'), and the
-- recorder and the oracle are planned with exactly those marks. The ordered
-- path's own fixtures mark none, so a depth-enabled world layer holding art
-- draws ordered; a target that 'shapeDepth' asks for has a depth image of its
-- extent, and a pass into it begins with a depth attachment when a depth-enabled
-- world layer is drawn.
--
-- = The textures
--
-- * 'Checker': 2×2 linear RGBA8, red and green over blue and yellow, opaque.
-- * 'GreySrgb': 2×2 sRGB RGBA8 of one opaque mid grey (128, 128, 128).
-- * 'White': 1×1 linear RGBA8, opaque white, the canvas tints are drawn on.
-- * 'Art': 2×2 linear RGBA8 of binary alpha: orange on one diagonal, fully
--   transparent on the other, the texture a cutout mark would be computed for.
module Test.GPU.Vulkan.Native.OrderedPath.Fixtures
  ( -- * Textures
    TextureKey (..)
  , Texture (..)
  , textures
  , textureLevels
  , decoded
    -- * Handles
  , Handles (..)
    -- * Targets
  , TargetShape (..)
  , offscreenShape
  , depthShape
  , colourFormatOf
    -- * Fixtures
  , NamedProbe (..)
  , Fixture (..)
  , fixtures
    -- * Building blocks, shared with the other suites
  , quad
  , tinted
  , keyed
  , sampled
  , additive
  , view
  , identityCamera
  , pass
  , probe
  ) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word32, Word8)
import GHC.Float (castWord32ToFloat)
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (ImageFormat (..))
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..), offscreenMetrics)
import Hetoimasia.Render.TwoD.Oracle (Probe (..))
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (..))
import Hetoimasia.Render.TwoD.Settings (TextureFilter (..), ViewSettings (..), ZoomMode (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Material (defaultMaterial)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target (TargetRef)
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)

-- ---------------------------------------------------------------------------
-- Textures

data TextureKey = Checker | GreySrgb | White | Art | Edge | Mipped | LevelZero
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A texture: its format, its extent, its level 0 bytes as uploaded and any
-- further levels, each half the size of the one before.
data Texture = Texture
  { textureKey ∷ !TextureKey
  , textureFormat ∷ !ImageFormat
  , textureWidth ∷ !Word32
  , textureHeight ∷ !Word32
  , textureBytes ∷ !ByteString
  , textureMips ∷ ![ByteString]
  }
  deriving (Eq, Show)

-- | Every level's bytes, level 0 first.
textureLevels ∷ Texture → [ByteString]
textureLevels texture = textureBytes texture : textureMips texture

textures ∷ [Texture]
textures =
  [ Texture Checker Rgba8Linear 2 2 (bytes [red, green, blue, yellow]) []
  , Texture GreySrgb Rgba8Srgb 2 2 (bytes (replicate 4 [128, 128, 128, 255])) []
  , Texture White Rgba8Linear 1 1 (bytes [[255, 255, 255, 255]]) []
  , Texture Art Rgba8Linear 2 2 (bytes [orange, clear', clear', orange]) []
  ]
  where
    bytes = ByteString.pack . concat
    red = [255, 0, 0, 255]
    green = [0, 255, 0, 255]
    blue = [0, 0, 255, 255]
    yellow = [255, 255, 0, 255]
    orange = [255, 128, 0, 255]
    clear' = [0, 0, 0, 0] ∷ [Word8]

-- | The image the oracle samples for a texture.
decoded ∷ Texture → DecodedImage
decoded texture =
  DecodedImage
    { decodedFormat = case textureFormat texture of
        Rgba8Srgb → TexelRgba8Srgb
        _ → TexelRgba8Linear
    , decodedWidth = textureWidth texture
    , decodedHeight = textureHeight texture
    , decodedLevels = textureLevels texture
    , decodedBinaryAlpha = all (`elem` [0, 255]) (everyFourth (drop 3 (ByteString.unpack (ByteString.concat (textureLevels texture)))))
    }
  where
    everyFourth = \case
      [] → []
      alpha : rest → alpha : everyFourth (drop 3 rest)

-- | The handles a session registered the textures under, and two handles that
-- resolve to the placeholder: one whose index no texture holds, and one that
-- reuses a registered index with another generation.
data Handles = Handles
  { handleOf ∷ TextureKey → TextureHandle
  , handleUnknown ∷ !TextureHandle
  , handleStale ∷ !TextureHandle
  }

-- ---------------------------------------------------------------------------
-- Targets

-- | An offscreen target a pass draws to.
data TargetShape = TargetShape
  { shapeRef ∷ !TargetRef
  , shapeFormat ∷ !ImageFormat
  , shapeWidth ∷ !Word32
  , shapeHeight ∷ !Word32
  , shapeMetrics ∷ !TargetMetrics
    -- ^ What the views map under, shared by the recorder and the oracle; its
    -- framebuffer extent is the target's.
  , shapeDepth ∷ !Bool
    -- ^ Whether the target has a depth image of its extent for a pass into it.
  }

-- | A target by index of this format and extent, with ordinary offscreen
-- metrics: its logical extent is its pixel extent and its content scale 1.
offscreenShape ∷ Word32 → ImageFormat → Word32 → Word32 → TargetShape
offscreenShape index format width height =
  TargetShape (targetRef index 1) format width height (offscreenMetrics (PixelExtent (fromIntegral width) (fromIntegral height))) False

-- | 'offscreenShape' with a depth image of the target's extent.
depthShape ∷ Word32 → ImageFormat → Word32 → Word32 → TargetShape
depthShape index format width height = (offscreenShape index format width height) {shapeDepth = True}

-- | The oracle's name for a target's colour format.
colourFormatOf ∷ ImageFormat → ColourFormat
colourFormatOf = \case
  Rgba8Srgb → R8G8B8A8Srgb
  Bgra8Srgb → B8G8R8A8Srgb
  Bgra8Linear → B8G8R8A8Unorm
  _ → R8G8B8A8Unorm

-- ---------------------------------------------------------------------------
-- Fixtures

-- | A probe that must be determinate and read what the oracle expects, and
-- whose expectation must differ from its contrast's.
data NamedProbe = NamedProbe
  { namedBehaviour ∷ !Text
  , namedProbe ∷ !Probe
  , namedContrast ∷ !Probe
  }

data Fixture = Fixture
  { fixtureName ∷ !Text
  , fixtureMarked ∷ ![TextureKey]
    -- ^ The textures marked cutout-safe: the recorder and the oracle plan with
    -- exactly these marks.
  , fixtureShapes ∷ ![TargetShape]
  , fixtureSnapshot ∷ Handles → Snapshot
  , fixtureNamed ∷ ![NamedProbe]
  }

fixtures ∷ [Fixture]
fixtures =
  [ placement
  , samplers
  , rotation
  , colour
  , overlap
  , contentScale
  , fractionalViews
  , formats
  , cutoutArt
  , placeholders
  , snapBoundary
  ]

-- ---------------------------------------------------------------------------
-- Building blocks

-- | An instance placing the unit square at this origin with this size.
quad ∷ (Float, Float) → (Float, Float) → TextureHandle → Instance
quad (x, y) (w, h) handle =
  Instance
    { instanceTransform = fromColumns (V2 w 0) (V2 0 h) (V2 x y)
    , instanceUv = UvRect 0 0 1 1
    , instanceTexture = handle
    , instanceDepthKey = 0
    , instanceTint = Tint 255 255 255 255
    , instanceSampler = SamplerDefault
    , instanceTranslucent = False
    , instanceAdditive = False
    , instanceClip = 0
    , instanceParameter = 0
    , instanceMaterial = defaultMaterial
    }

tinted ∷ (Word8, Word8, Word8, Word8) → Instance → Instance
tinted (r, g, b, a) candidate = candidate {instanceTint = Tint r g b a}

keyed ∷ Word32 → Instance → Instance
keyed key candidate = candidate {instanceDepthKey = key}

sampled ∷ Sampler → Instance → Instance
sampled sampler candidate = candidate {instanceSampler = sampler}

additive ∷ Instance → Instance
additive candidate = candidate {instanceAdditive = True}

-- | A view: viewport origin and extent, camera, settings and layers.
view ∷ (Float, Float) → (Float, Float) → Camera → ViewSettings → [Layer] → View
view (x, y) (w, h) camera settings = View camera (Viewport (V2 x y) (V2 w h)) settings

-- | The camera that makes world units target pixels in a viewport of this
-- extent: at its centre at zoom 1.
identityCamera ∷ (Float, Float) → Camera
identityCamera (w, h) = Camera (V2 (w / 2) (h / 2)) 1 Nothing

pass ∷ TargetShape → (Float, Float, Float, Float) → [View] → Pass
pass shape (r, g, b, a) = Pass (OffscreenTarget (shapeRef shape)) (ClearColour r g b a)

probe ∷ Int → Int → Int → Probe
probe = Probe

-- ---------------------------------------------------------------------------
-- The fixtures

-- | Both zoom modes, each with pixel snap off and on, in four 16 × 16 views
-- over one 32 × 32 target; every sprite is 2.1 world units wide, and each view's
-- own pixel coordinates are worked out below. With snap on the camera's
-- translation rounds (in 'worldTransform') and then the sprite's origin rounds
-- rigidly, in the vertex shader, so each of the two roundings moves a column
-- edge across a pixel centre that the unsnapped view keeps on the other side.
--
-- * View 0: 4 pixels per unit, snap off, camera 1.45, sprite origin (0.1, 0.1):
--   the translation is 8 − 5.8 = 2.2 and the sprite begins at 2.6 and ends at
--   11.0, so columns and rows 3 to 10 are covered.
-- * View 1: the same with snap on: the translation rounds to 2, the sprite's
--   origin to 2.4, which the shader rounds to 2.0, so it ends at 10.4 and
--   columns and rows 2 to 9 are covered. Without the shader's rounding it would
--   cover 3 to 10 (origin 2.4 to 10.8: column 2 not, column 10 yes) and without
--   the camera's, 3 to 10 again (origin 2.6 rounds to 3.0).
-- * View 2: fixed half-height 4 at zoom 1, so 2 pixels per unit in a viewport 16
--   tall, snap off, camera 1.1, sprite origin (0.3, 0.3): the translation is
--   8 − 2.2 = 5.8, the sprite begins at 6.4 and ends at 10.6, so columns and
--   rows 6 to 10 are covered.
-- * View 3: the same with snap on: the translation rounds to 6, the origin to
--   6.6, which the shader rounds to 7, so it ends at 11.2 and columns and rows
--   7 to 10 are covered.
placement ∷ Fixture
placement =
  Fixture
    { fixtureName = "placement"
    , fixtureMarked = []
    , fixtureShapes = [shape]
    , fixtureSnapshot = \handles →
        let checker = handleOf handles Checker
            sprite origin = quad origin (2.1, 2.1) checker
            ppu snap = defaultViewSettings {settingPixelSnap = snap}
            fixed snap = defaultViewSettings {settingPixelSnap = snap, settingZoomMode = FixedHalfHeight 4}
            at origin camera settings instance' = view origin (16, 16) camera settings [WorldLayer DepthDisabled [instance']]
         in Snapshot
              [ pass
                  shape
                  (0.1, 0.1, 0.1, 1)
                  [ at (0, 0) (Camera (V2 1.45 1.45) 4 Nothing) (ppu False) (sprite (0.1, 0.1))
                  , at (16, 0) (Camera (V2 1.45 1.45) 4 Nothing) (ppu True) (sprite (0.1, 0.1))
                  , at (0, 16) (Camera (V2 1.1 1.1) 1 Nothing) (fixed False) (sprite (0.3, 0.3))
                  , at (16, 16) (Camera (V2 1.1 1.1) 1 Nothing) (fixed True) (sprite (0.3, 0.3))
                  ]
              ]
    , fixtureNamed =
        [ NamedProbe "pixel snap on rounds the sprite's right edge back across column 10 (pixels per unit)" (probe 0 26 5) (probe 0 10 5)
        , NamedProbe "pixel snap on rounds the sprite's left edge back across column 2 (pixels per unit)" (probe 0 18 5) (probe 0 2 5)
        , NamedProbe "pixel snap on rounds a fixed half-height sprite's origin up past column 6" (probe 0 22 23) (probe 0 6 23)
        , NamedProbe "a fixed half-height scales the world by the viewport's height, not by the zoom" (probe 0 3 23) (probe 0 3 5)
        ]
    }
  where
    shape = offscreenShape 1 Rgba8Linear 32 32

-- | Nearest, linear and default sampler choices mixed in one draw, under a
-- view whose default is nearest and one whose default is linear. Each view's
-- layer is one run, so each is one draw. A checker texel is 4 pixels at 8
-- pixels a side, so the pixel 3 columns in sits 0.125 of a texel short of the
-- boundary: nearest reads red, linear blends 0.375 of green into it.
samplers ∷ Fixture
samplers =
  Fixture
    { fixtureName = "samplers"
    , fixtureMarked = []
    , fixtureShapes = [shape]
    , fixtureSnapshot = \handles →
        let sprite x choice = sampled choice (quad (x, 4) (8, 8) (handleOf handles Checker))
            layer = UiLayer [sprite 0 SamplerDefault, sprite 10 SamplerNearest, sprite 20 SamplerLinear]
            at origin settings = view origin (32, 16) (identityCamera (32, 16)) settings [layer]
         in Snapshot
              [ pass
                  shape
                  (0, 0, 0, 1)
                  [ at (0, 0) defaultViewSettings
                  , at (0, 16) defaultViewSettings {settingFilter = FilterLinear}
                  ]
              ]
    , fixtureNamed =
        [ NamedProbe "default takes the view's nearest filter" (probe 0 3 5) (probe 0 3 21)
        , NamedProbe "default takes the view's linear filter" (probe 0 3 21) (probe 0 3 5)
        , NamedProbe "an explicit nearest choice overrides a linear default, in the same draw as a linear one" (probe 0 13 21) (probe 0 23 21)
        , NamedProbe "an explicit linear choice overrides a nearest default, in the same draw as a nearest one" (probe 0 23 5) (probe 0 13 5)
        ]
    }
  where
    shape = offscreenShape 1 Rgba8Linear 32 32

-- | A camera turned by a quarter turn about the viewport's centre. World +Y
-- lies to the right of the centre and world +X above it, so a sprite whose
-- world rectangle is [0, 3]² at 4 pixels per unit, which unturned would fill
-- (16..28, 16..28), fills (16..28, 4..16).
rotation ∷ Fixture
rotation =
  Fixture
    { fixtureName = "rotation"
    , fixtureMarked = []
    , fixtureShapes = [shape]
    , fixtureSnapshot = \handles →
        let quarter = realToFrac (pi / 2 ∷ Double) ∷ Float
         in Snapshot
              [ pass
                  shape
                  (0.2, 0, 0.2, 1)
                  [ view
                      (0, 0)
                      (32, 32)
                      (Camera (V2 0 0) 4 (Just quarter))
                      defaultViewSettings
                      [WorldLayer DepthDisabled [quad (0, 0) (3, 3) (handleOf handles Checker)]]
                  ]
              ]
    , fixtureNamed =
        [ NamedProbe "a quarter-turn camera puts a sprite at the world origin above it" (probe 0 20 8) (probe 0 20 20)
        , NamedProbe "a quarter-turn camera turns the sprite's texels with the world" (probe 0 18 6) (probe 0 26 6)
        ]
    }
  where
    shape = offscreenShape 1 Rgba8Linear 32 32

-- | Tint, brightness above and below 1, and an additive instance, in two views
-- of one 48 × 32 target: brightness 2 above and 0.5 below. Each view's layer
-- holds, left to right, a tinted white sprite, an untinted one, a half
-- transparent one over the clear, an opaque grey one and an additive
-- instance over that grey one's right part. Sprites are 8 × 8 at y = 4. The
-- clear is not black, so a half-transparent white that lets it through reads
-- differently from an opaque one (the colour is not premultiplied by alpha).
colour ∷ Fixture
colour =
  Fixture
    { fixtureName = "colour"
    , fixtureMarked = []
    , fixtureShapes = [shape]
    , fixtureSnapshot = \handles →
        let white = handleOf handles White
            layer =
              UiLayer
                [ tinted (200, 100, 50, 255) (quad (0, 4) (8, 8) white)
                , quad (9, 4) (8, 8) white
                , tinted (255, 255, 255, 128) (quad (18, 4) (8, 8) white)
                , tinted (100, 100, 100, 255) (quad (27, 4) (12, 8) white)
                , additive (keyed 1 (tinted (100, 50, 0, 255) (quad (33, 4) (8, 8) white)))
                ]
            at origin brightness = view origin (48, 16) (identityCamera (48, 16)) defaultViewSettings {settingBrightness = brightness} [layer]
         in Snapshot [pass shape (0.2, 0.4, 0.6, 1) [at (0, 0) 2, at (0, 16) 0.5]]
    , fixtureNamed =
        [ NamedProbe "brightness above 1 brightens, and clamps" (probe 0 12 8) (probe 0 12 24)
        , NamedProbe "brightness below 1 darkens" (probe 0 12 24) (probe 0 12 8)
        , NamedProbe "a tint multiplies the texel" (probe 0 4 24) (probe 0 12 24)
        , NamedProbe "a half-transparent tint lets the clear through" (probe 0 22 24) (probe 0 12 24)
        , NamedProbe "an additive instance adds to what is under it" (probe 0 36 8) (probe 0 30 8)
        ]
    }
  where
    shape = offscreenShape 1 Rgba8Linear 48 32

-- | Overlapping translucent instances, in key order and in submission order,
-- over three 24 × 24 views of one 72 × 24 target, camera at the centre so a
-- world unit is a pixel. Each view holds a green and a blue 12-pixel square
-- overlapping in (10..16)²: view 0 submits green then blue at one key, so blue
-- is drawn over green; view 1 submits blue then green at that key, so green is
-- over blue; view 2 submits green then blue with keys 2 and 1, so blue is
-- drawn first and green over it, whatever the submission order.
overlap ∷ Fixture
overlap =
  Fixture
    { fixtureName = "overlap"
    , fixtureMarked = []
    , fixtureShapes = [shape]
    , fixtureSnapshot = \handles →
        let white = handleOf handles White
            green key = keyed key (tinted (0, 255, 0, 128) (quad (4, 4) (12, 12) white))
            blue key = keyed key (tinted (0, 0, 255, 128) (quad (10, 10) (12, 12) white))
            at origin instances = view origin (24, 24) (identityCamera (24, 24)) defaultViewSettings [WorldLayer DepthDisabled instances]
         in Snapshot
              [ pass
                  shape
                  (0, 0, 0, 1)
                  [ at (0, 0) [green 1, blue 1]
                  , at (24, 0) [blue 1, green 1]
                  , at (48, 0) [green 2, blue 1]
                  ]
              ]
    , fixtureNamed =
        [ NamedProbe "equal keys draw in submission order" (probe 0 13 13) (probe 0 37 13)
        , NamedProbe "a larger key draws over a smaller one whatever the submission order" (probe 0 61 13) (probe 0 13 13)
        ]
    }
  where
    shape = offscreenShape 1 Rgba8Linear 72 24

-- | A UI layer at content scale 1 and 2, as two passes into two 32 × 32
-- targets. The second target's metrics are those of a window of logical
-- extent 16 × 16 at content scale 2, supplied explicitly and shared with the
-- oracle, so the same 6-pixel UI sprite at (2, 2) covers (2..8)² in the
-- first and (4..16)² in the second.
contentScale ∷ Fixture
contentScale =
  Fixture
    { fixtureName = "content-scale"
    , fixtureMarked = []
    , fixtureShapes = [one, two]
    , fixtureSnapshot = \handles →
        let layer = UiLayer [tinted (255, 128, 0, 255) (quad (2, 2) (6, 6) (handleOf handles White))]
            at = view (0, 0) (32, 32) (identityCamera (32, 32)) defaultViewSettings [layer]
         in Snapshot [pass one (0, 0, 0.3, 1) [at], pass two (0, 0.3, 0, 1) [at]]
    , fixtureNamed =
        [ NamedProbe "content scale 2 doubles a UI sprite's physical size" (probe 1 12 12) (probe 0 12 12)
        , NamedProbe "content scale 1 leaves a UI sprite at its logical size" (probe 0 4 4) (probe 1 2 2)
        ]
    }
  where
    one = offscreenShape 1 Rgba8Linear 32 32
    two = (offscreenShape 2 Rgba8Linear 32 32) {shapeMetrics = TargetMetrics (PixelExtent 16 16) (PixelExtent 32 32) 2 2}

-- | Two views with separate viewports in one pass: the first 16.5 pixels wide
-- and the second starting at 16.5. Each draws a UI sprite far larger than its
-- viewport, so what shows is the viewport's own scissor: columns 0 to 15 for
-- the first and 16 to 31 for the second. The centre of column 16 lies on the
-- shared fractional edge, which the oracle reports indeterminate.
fractionalViews ∷ Fixture
fractionalViews =
  Fixture
    { fixtureName = "fractional-views"
    , fixtureMarked = []
    , fixtureShapes = [shape]
    , fixtureSnapshot = \handles →
        let white = handleOf handles White
            cover colour' = UiLayer [tinted colour' (quad (-4, -4) (40, 40) white)]
            at origin extent colour' = view origin extent (identityCamera extent) defaultViewSettings [cover colour']
         in Snapshot
              [ pass
                  shape
                  (0.1, 0.1, 0.1, 1)
                  [ at (0, 0) (16.5, 32) (255, 0, 0, 255)
                  , at (16.5, 0) (15.5, 32) (0, 0, 255, 255)
                  ]
              ]
    , fixtureNamed =
        [ NamedProbe "the first viewport's scissor ends before the fractional edge" (probe 0 15 10) (probe 0 17 10)
        , NamedProbe "the second viewport's scissor begins after the fractional edge" (probe 0 17 10) (probe 0 15 10)
        ]
    }
  where
    shape = offscreenShape 1 Rgba8Linear 32 32

-- | An R8G8B8A8_SRGB target and an R8G8B8A8_UNORM one, in two passes of one
-- frame drawing the same sRGB texture at the same place. Colour is decoded on
-- sampling, so the mid-grey texel is 0.2158 in linear light: the sRGB target
-- stores it encoded, 128; the UNORM target stores it as it is, 55. The clears
-- (0.5 linear) differ the same way, 188 and 128.
formats ∷ Fixture
formats =
  Fixture
    { fixtureName = "formats"
    , fixtureMarked = []
    , fixtureShapes = [srgb, unorm]
    , fixtureSnapshot = \handles →
        let layer = UiLayer [quad (2, 2) (8, 8) (handleOf handles GreySrgb)]
            at = view (0, 0) (16, 16) (identityCamera (16, 16)) defaultViewSettings [layer]
         in Snapshot [pass srgb (0.5, 0.5, 0.5, 1) [at], pass unorm (0.5, 0.5, 0.5, 1) [at]]
    , fixtureNamed =
        [ NamedProbe "an sRGB target stores sampled colour encoded and a UNORM target does not" (probe 0 5 5) (probe 1 5 5)
        , NamedProbe "each pass clears its own target's format" (probe 0 14 14) (probe 1 14 14)
        ]
    }
  where
    srgb = offscreenShape 1 Rgba8Srgb 16 16
    unorm = offscreenShape 2 Rgba8Linear 16 16

-- | A depth-enabled world layer holding cutout-marked art (binary alpha),
-- drawn ordered because nothing is marked, in a pass with a depth attachment
-- that its tested-and-unwritten ordered instances pass against. The art's orange
-- texels lie on one diagonal and its transparent ones on the other; the second
-- sprite, a larger key, is tinted, so where its transparent texel lies over the
-- first's orange one the first shows through, and where its orange one does it
-- covers it.
cutoutArt ∷ Fixture
cutoutArt =
  Fixture
    { fixtureName = "cutout-art"
    , fixtureMarked = []
    , fixtureShapes = [shape]
    , fixtureSnapshot = \handles →
        let art = handleOf handles Art
         in Snapshot
              [ pass
                  shape
                  (0, 0, 0, 1)
                  [ view
                      (0, 0)
                      (24, 24)
                      (identityCamera (24, 24))
                      defaultViewSettings
                      [WorldLayer DepthEnabled [keyed 1 (quad (2, 2) (12, 12) art), keyed 2 (tinted (0, 200, 255, 255) (quad (5, 5) (12, 12) art))]]
                  ]
              ]
    , fixtureNamed =
        [ NamedProbe "transparent art leaves what is under it" (probe 0 9 12) (probe 0 6 6)
        , NamedProbe "opaque art of a larger key covers what is under it" (probe 0 6 6) (probe 0 9 12)
        ]
    }
  where
    shape = depthShape 1 Rgba8Linear 24 24

-- | A handle whose index no texture holds and one that reuses a registered
-- index with another generation both sample slot 0's transparent placeholder,
-- so they leave the clear; a registered texture at the same size, beside
-- them, does not.
placeholders ∷ Fixture
placeholders =
  Fixture
    { fixtureName = "placeholders"
    , fixtureMarked = []
    , fixtureShapes = [shape]
    , fixtureSnapshot = \handles →
        let sprite x handle = quad (x, 2) (6, 6) handle
         in Snapshot
              [ pass
                  shape
                  (0.3, 0.1, 0.1, 1)
                  [ view
                      (0, 0)
                      (24, 24)
                      (identityCamera (24, 24))
                      defaultViewSettings
                      [UiLayer [sprite 2 (handleOf handles White), sprite 10 (handleUnknown handles), sprite 18 (handleStale handles)]]
                  ]
              ]
    , fixtureNamed =
        [ NamedProbe "an unknown handle index samples the placeholder" (probe 0 13 5) (probe 0 5 5)
        , NamedProbe "a stale generation samples the placeholder" (probe 0 21 5) (probe 0 5 5)
        ]
    }
  where
    shape = offscreenShape 1 Rgba8Linear 24 24

-- | A snapping view whose sprite's origin is the largest 'Float' below one
-- half (0x3effffff, 0.49999997) on both axes: it rounds down to 0, as
-- 'Hetoimasia.Render.TwoD.Mapping.snapPixel' evaluates it exactly. A shader
-- that added 0.5 in single precision would get 1.0, floor it to 1 and shift
-- the 4-pixel quad by a whole pixel, covering 1 to 4 where 0 to 3 is right.
snapBoundary ∷ Fixture
snapBoundary =
  Fixture
    { fixtureName = "snap-boundary"
    , fixtureMarked = []
    , fixtureShapes = [shape]
    , fixtureSnapshot = \handles →
        let belowHalf = castWord32ToFloat 0x3effffff
         in Snapshot
              [ pass
                  shape
                  (0.1, 0.1, 0.1, 1)
                  [ view
                      (0, 0)
                      (16, 16)
                      (identityCamera (16, 16))
                      defaultViewSettings {settingPixelSnap = True}
                      [UiLayer [tinted (255, 128, 0, 255) (quad (belowHalf, belowHalf) (4, 4) (handleOf handles White))]]
                  ]
              ]
    , fixtureNamed =
        [ NamedProbe "an origin just below one half snaps to 0, so the quad covers pixel 0" (probe 0 0 0) (probe 0 8 8)
        , NamedProbe "an origin just below one half snaps to 0, so the quad leaves pixel 4" (probe 0 4 4) (probe 0 3 3)
        ]
    }
  where
    shape = offscreenShape 1 Rgba8Linear 16 16
