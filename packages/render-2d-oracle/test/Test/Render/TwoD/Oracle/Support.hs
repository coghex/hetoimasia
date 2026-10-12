-- | Builders the oracle's examples share.
--
-- Every fixture is a small snapshot whose expected pixels are written by hand
-- in the example, as a picture or as bytes, from the equations in the README.
-- Nothing here computes an expectation: it builds inputs, and 'picture' only
-- prints what the oracle answered, so a hand-written picture can be compared
-- with it.
module Test.Render.TwoD.Oracle.Support
  ( -- * Colours
    Rgba
  , palette
  , px

    -- * Handles and targets
  , h1
  , h2
  , h3
  , offscreenRef
  , targetSpec
  , unorm8
  , srgb8

    -- * Snapshots
  , sprite
  , defaultCamera
  , fullViewport
  , mkView
  , fullView
  , offscreenPass
  , noClear
  , validated

    -- * Textures
  , rgba8
  , solid
  , flat

    -- * Oracles and pictures
  , mkOracle
  , mkOracleFull
  , picture
  , expectAt
  , spriteAt
  ) where

import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Word (Word8)
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks, noCutoutMarks)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), offscreenMetrics)
import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (..), Rgba8 (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings, defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target (TargetRef)
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (ValidSnapshot, validateSnapshot)

-- | A colour as four bytes.
type Rgba = (Word8, Word8, Word8, Word8)

-- | A pixel from four bytes.
px ∷ Rgba → Rgba8
px (r, g, b, a) = Rgba8 r g b a

-- | The glyphs of a picture: transparent black, and the opaque primaries and
-- secondaries.
palette ∷ [(Char, Rgba8)]
palette =
  [ ('.', Rgba8 0 0 0 0)
  , ('R', Rgba8 255 0 0 255)
  , ('G', Rgba8 0 255 0 255)
  , ('B', Rgba8 0 0 255 255)
  , ('Y', Rgba8 255 255 0 255)
  , ('C', Rgba8 0 255 255 255)
  , ('W', Rgba8 255 255 255 255)
  ]

-- | Three distinct handles.
h1, h2, h3 ∷ TextureHandle
h1 = textureHandle 1 1
h2 = textureHandle 2 1
h3 = textureHandle 3 1

-- | The offscreen target every fixture's passes draw into.
offscreenRef ∷ TargetRef
offscreenRef = targetRef 1 1

-- | A target of a format and extent, whose logical extent is its pixel extent
-- and whose content scale is 1.
targetSpec ∷ ColourFormat → Int → Int → TargetSpec
targetSpec format width height =
  TargetSpec (offscreenMetrics (PixelExtent width height)) format (PixelExtent width height)

-- | An 8 × 8 UNORM target.
unorm8 ∷ TargetSpec
unorm8 = targetSpec R8G8B8A8Unorm 8 8

-- | An 8 × 8 sRGB target.
srgb8 ∷ TargetSpec
srgb8 = targetSpec R8G8B8A8Srgb 8 8

-- | An instance placing its texture's whole image on the rectangle with this
-- origin and size, with every default: depth key 0, an opaque white tint, the
-- nearest sampler and no flags.
sprite ∷ TextureHandle → (Float, Float) → (Float, Float) → Instance
sprite handle (x, y) (w, h) =
  Instance
    { instanceTransform = fromColumns (V2 w 0) (V2 0 h) (V2 x y)
    , instanceUv = UvRect 0 0 1 1
    , instanceTexture = handle
    , instanceDepthKey = 0
    , instanceTint = Tint 255 255 255 255
    , instanceSampler = SamplerNearest
    , instanceTranslucent = False
    , instanceAdditive = False
    , instanceClip = 0
    , instanceMaterial = 0
    }

-- | A camera at the origin, zoom 1, no rotation.
defaultCamera ∷ Camera
defaultCamera = Camera (V2 0 0) 1 Nothing

-- | A viewport at the origin of this extent.
fullViewport ∷ Float → Float → Viewport
fullViewport w h = Viewport (V2 0 0) (V2 w h)

-- | A view of a camera, a viewport, settings and layers.
mkView ∷ Camera → Viewport → ViewSettings → [Layer] → View
mkView = View

-- | The default camera and settings over a viewport covering a target of this
-- extent.
fullView ∷ Float → Float → [Layer] → View
fullView w h = View defaultCamera (fullViewport w h) defaultViewSettings

-- | A pass into the fixtures' offscreen target.
offscreenPass ∷ ClearColour → [View] → Pass
offscreenPass = Pass (OffscreenTarget offscreenRef)

-- | A transparent black clear.
noClear ∷ ClearColour
noClear = ClearColour 0 0 0 0

-- | The validated snapshot of these passes; the fixtures are all valid.
validated ∷ [Pass] → ValidSnapshot
validated candidates = either (error . ("fixture refused: " <>) . show) id (validateSnapshot (Snapshot candidates))

-- | A decoded RGBA8 image, each level given as its bytes.
rgba8 ∷ Bool → Int → Int → [[Word8]] → DecodedImage
rgba8 srgb width height levels =
  DecodedImage
    { decodedFormat = if srgb then TexelRgba8Srgb else TexelRgba8Linear
    , decodedWidth = fromIntegral width
    , decodedHeight = fromIntegral height
    , decodedLevels = map ByteString.pack levels
    , decodedBinaryAlpha = False
    }

-- | A one-texel image.
solid ∷ Bool → Rgba → DecodedImage
solid srgb (r, g, b, a) = rgba8 srgb 1 1 [[r, g, b, a]]

-- | This many texels of one colour, as level bytes.
flat ∷ Int → Rgba → [Word8]
flat count (r, g, b, a) = concat (replicate count [r, g, b, a])

-- | An oracle over the passes, drawing into the fixtures' one offscreen
-- target, with no window and no cutout marks.
mkOracle ∷ TargetSpec → [(TextureHandle, DecodedImage)] → [Pass] → Oracle
mkOracle spec textures = mkOracleFull noCutoutMarks Nothing (Map.singleton offscreenRef spec) textures

-- | An oracle with every input given.
mkOracleFull ∷ CutoutMarks → Maybe TargetSpec → Map TargetRef TargetSpec → [(TextureHandle, DecodedImage)] → [Pass] → Oracle
mkOracleFull marks window offscreen textures candidates =
  newOracle
    OracleInput
      { inputSnapshot = validated candidates
      , inputCutoutMarks = marks
      , inputWindow = window
      , inputOffscreen = offscreen
      , inputTextures = \handle → lookup handle textures
      }

-- | The oracle's answer for every pixel of a pass as rows of glyphs: a glyph
-- from the legend for an expected value that is in it, @?@ for one that is
-- not, @~@ for an indeterminate probe and @!@ for an unevaluable one.
picture ∷ Oracle → Int → (Int, Int) → [(Char, Rgba8)] → [String]
picture oracle passIndex (width, height) legend =
  [[glyph (expect oracle (Probe passIndex x y)) | x ← [0 .. width - 1]] | y ← [0 .. height - 1]]
  where
    glyph (Expected value _) = fromMaybe '?' (lookup value [(pixel, c) | (c, pixel) ← legend])
    glyph (Indeterminate _) = '~'
    glyph (Unevaluable _) = '!'

-- | The expectation at a pixel of pass 0.
expectAt ∷ Oracle → Int → Int → Expectation
expectAt oracle x y = expect oracle (Probe 0 x y)

-- | A sprite of a handle at a position, one unit square.
spriteAt ∷ TextureHandle → (Float, Float) → Instance
spriteAt handle position = sprite handle position (1, 1)
