-- | The sprites sample's fixed scene (GRS-8): the evidence target, the draws
-- in painter order with the one shared sampler each selects, every instance
-- they draw, and the probe points whose expected values
-- "Hetoimasia.Sample.Sprites.Oracle" computes.
--
-- The view is a fixed orthographic one over the 256×256 target: an
-- instance's rectangle is in target pixels, @(0, 0)@ at the upper-left
-- corner, @x@ rightwards and @y@ downwards, and a pixel's centre is at
-- @(x + 0.5, y + 0.5)@. Each instance carries its texture by name — the
-- renderer resolves the name to the stable handle the texture table issued —
-- its texture-coordinate rectangle, mapped linearly across the quad, and its
-- position and size.
--
-- = Draws
--
-- 1. 'GridDraw', nearest-clamp: a 32×32 grid of 4×4-pixel quads over the
--    upper-left quarter, 1,024 instances using both RGBA8 textures — atlas
--    regions in turn, and the translucent red column in every eighth
--    column — then the four atlas regions at 32×32 pixels, the atlas's
--    red/green boundary sampled with nearest filtering, a translucent red
--    quad overlapped by a translucent blue one, and finally a translucent red
--    quad the next draw overlaps.
-- 2. 'LinearDraw', linear-clamp: a translucent blue quad over the previous
--    draw's last red quad, so painter order across the draw boundary is
--    observable, then the atlas's red/green boundary at the same coordinate
--    sampled with linear filtering.
-- 3. 'Bc7Draw', nearest-clamp, drawn only when the device takes BC7: the
--    BC7 fixture at 32×32 pixels.
--
-- Nothing sorts instances: each draw's instances are drawn in the order
-- listed, and the draws in the order above.
module Hetoimasia.Sample.Sprites.Scene
  ( -- * The target
    targetSide
  , targetBytes
    -- * Draws and instances
  , DrawName (..)
  , Draw (..)
  , Instance (..)
  , sceneDraws
  , drawSampler
  , boundaryU
  , boundaryV
    -- * Probes
  , Probe (..)
  , ProbePurpose (..)
  , sceneProbes
    -- * Instance data
  , instanceStride
  , encodeInstances
  , quadCorners
  , quadIndices
  ) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.Text (Text)
import Data.Word (Word16, Word32)
import GHC.Float (castFloatToWord32)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Vulkan.Native.Recording (TableSampler (..))
import Hetoimasia.Sample.Sprites.Fixtures (AtlasRegion (..), FixtureName (..), UvRect (..), atlasRegion)

-- | The evidence target's side, in pixels.
targetSide ∷ Int
targetSide = 256

-- | The evidence target's bytes, four a pixel.
targetBytes ∷ Natural
targetBytes = fromIntegral (targetSide * targetSide * 4)

data DrawName = GridDraw | LinearDraw | Bc7Draw
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One textured quad: its texture, its texture-coordinate rectangle, and
-- its rectangle in target pixels (left, top, width, height).
data Instance = Instance
  { instanceTexture ∷ !FixtureName
  , instanceUv ∷ !UvRect
  , instanceRect ∷ !(Double, Double, Double, Double)
  }
  deriving (Eq, Show)

-- | One draw: its name, the shared sampler it selects, and its instances in
-- painter order.
data Draw = Draw
  { drawName ∷ !DrawName
  , drawFilter ∷ !TableSampler
  , drawInstances ∷ ![Instance]
  }
  deriving (Eq, Show)

-- | Each draw's sampler: nearest-clamp, or linear-clamp. Instances carry no
-- sampler; the draw selects one through its push constants.
drawSampler ∷ DrawName → TableSampler
drawSampler = \case
  GridDraw → NearestClamp
  LinearDraw → LinearClamp
  Bc7Draw → NearestClamp

-- | The texture coordinate both filters sample across the atlas's red/green
-- boundary: @u = 0.46875 + 1/8192@, so the texel coordinate @8u − 0.5@ is
-- @3.25 + 1/1024@. Nearest filtering takes texel 3, red; linear filtering
-- weighs texel 4, green, by @0.25 + 1/1024@. A conformant device's sub-texel
-- precision is at least four bits, and every precision of four bits or more
-- quantizes that weight, truncated or rounded, to within @1/1024@ of 0.25,
-- which moves no channel by more than 0.25 of a step: the ±1 tolerance holds
-- at every conformant precision.
boundaryU, boundaryV ∷ Double
boundaryU = 0.46875 + 1 / 8192
boundaryV = 0.25

-- | The scene's draws, in painter order: every one when the device takes
-- BC7, and the BC7 draw left out when it does not.
sceneDraws ∷ Bool → [Draw]
sceneDraws withBc7 =
  [ Draw GridDraw (drawSampler GridDraw) (grid <> gridExtras)
  , Draw LinearDraw (drawSampler LinearDraw) linearInstances
  ]
    <> [Draw Bc7Draw (drawSampler Bc7Draw) [Instance Bc7Block (UvRect 0 0 1 1) (16, 208, 32, 32)] | withBc7]
  where
    grid =
      [ if column `mod` 8 == 7
          then Instance Translucent translucentRed (cell column row)
          else Instance Atlas (atlasRegion (toEnum ((column + row) `mod` 4))) (cell column row)
      | row ← [0 .. 31 ∷ Int]
      , column ← [0 .. 31 ∷ Int]
      ]
    cell column row = (fromIntegral (4 * column), fromIntegral (4 * row), 4, 4)
    gridExtras =
      [ Instance Atlas (atlasRegion RedRegion) (136, 8, 32, 32)
      , Instance Atlas (atlasRegion GreenRegion) (176, 8, 32, 32)
      , Instance Atlas (atlasRegion BlueRegion) (136, 48, 32, 32)
      , Instance Atlas (atlasRegion YellowRegion) (176, 48, 32, 32)
      , Instance Atlas boundary (216, 8, 32, 32)
      , Instance Translucent translucentRed (136, 96, 48, 32)
      , Instance Translucent translucentBlue (160, 96, 48, 32)
      , Instance Translucent translucentRed (136, 160, 48, 32)
      ]
    linearInstances =
      [ Instance Translucent translucentBlueCentre (160, 160, 48, 32)
      , Instance Atlas boundary (216, 48, 32, 32)
      ]
    boundary = UvRect boundaryU boundaryV boundaryU boundaryV
    -- The translucent texture's columns: under nearest filtering any
    -- coordinate in a column takes that column's texel; under linear
    -- filtering the blue column's centre, u = 0.75, does.
    translucentRed = UvRect 0 0 0.5 1
    translucentBlue = UvRect 0.5 0 1 1
    translucentBlueCentre = UvRect 0.75 0.5 0.75 0.5

-- | Why a probe is where it is.
data ProbePurpose
  = AtlasSelection
    -- ^ An atlas region, which a wrong rectangle would show in another
    -- colour.
  | FilterDistinction
    -- ^ The atlas's red/green boundary, sampled by one filter or the other.
  | Translucency
    -- ^ A translucent region, alone or overlapped.
  | PainterOrder
    -- ^ An overlap whose colour depends on which instance was drawn last.
  | LargeDraw
    -- ^ One of the 1,024-instance draw's quads.
  | Bc7Texels
    -- ^ The BC7 fixture, probed only when it was drawn.
  | Clear
    -- ^ A pixel no instance covers.
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One probe: its name, its pixel, and why it is there. Every probe is a
-- pixel's centre well inside its quad, away from every rasterization edge.
data Probe = Probe
  { probeName ∷ !Text
  , probePixel ∷ !(Int, Int)
  , probePurpose ∷ !ProbePurpose
  }
  deriving (Eq, Show)

-- | The scene's probes: the BC7 fixture's only when it was drawn.
sceneProbes ∷ Bool → [Probe]
sceneProbes withBc7 =
  [ Probe "grid red region (0,0)" (1, 1) LargeDraw
  , Probe "grid green region (1,0)" (5, 1) LargeDraw
  , Probe "grid blue region (2,0)" (9, 1) LargeDraw
  , Probe "grid yellow region (3,0)" (13, 1) LargeDraw
  , Probe "grid translucent red (7,3)" (29, 13) LargeDraw
  , Probe "grid blue region (14,16)" (57, 65) LargeDraw
  , Probe "grid green region (30,31)" (121, 125) LargeDraw
  , Probe "atlas red region" (147, 19) AtlasSelection
  , Probe "atlas green region" (187, 19) AtlasSelection
  , Probe "atlas blue region" (147, 59) AtlasSelection
  , Probe "atlas yellow region" (187, 59) AtlasSelection
  , Probe "red/green boundary, nearest" (232, 24) FilterDistinction
  , Probe "red/green boundary, linear" (232, 64) FilterDistinction
  , Probe "translucent red alone" (144, 112) Translucency
  , Probe "red then blue, one draw" (172, 112) PainterOrder
  , Probe "translucent blue alone" (196, 112) Translucency
  , Probe "translucent red alone, before the boundary" (144, 176) Translucency
  , Probe "red then blue, across the draw boundary" (172, 176) PainterOrder
  , Probe "translucent blue alone, after the boundary" (196, 176) Translucency
  , Probe "clear, between the grid and the atlas" (130, 130) Clear
  , Probe "clear, lower right" (250, 250) Clear
  , Probe "clear, lower left" (100, 200) Clear
  , Probe "clear, right edge" (250, 140) Clear
  ]
    <> [ p
       | withBc7
       , p ←
           [ Probe "BC7 left endpoint" (21, 224) Bc7Texels
           , Probe "BC7 right endpoint" (43, 224) Bc7Texels
           ]
       ]

-- | The bytes one instance takes in the instance buffer: its rectangle and
-- its texture-coordinate rectangle as four floats each, then its texture
-- handle's lookup index and generation as unsigned 32-bit integers.
instanceStride ∷ Natural
instanceStride = 40

-- | Instances as the vertex stage reads them, given each texture's handle.
encodeInstances ∷ (FixtureName → (Word32, Word32)) → [Instance] → ByteString
encodeInstances handleOf instances =
  Lazy.toStrict . Builder.toLazyByteString $
    foldMap
      ( \(Instance texture (UvRect u0 v0 u1 v1) (left, top, width, height)) →
          let (index, generation) = handleOf texture
           in foldMap float [left, top, width, height, u0, v0, u1, v1] <> Builder.word32LE index <> Builder.word32LE generation
      )
      instances
  where
    float = Builder.word32LE . castFloatToWord32 . realToFrac

-- | The unit quad's four corners, as two floats each, and its two
-- triangles' 16-bit indices.
quadCorners ∷ ByteString
quadCorners = Lazy.toStrict (Builder.toLazyByteString (foldMap (Builder.word32LE . castFloatToWord32) [0, 0, 1, 0, 1, 1, 0, 1]))

quadIndices ∷ ByteString
quadIndices = ByteString.pack (concat [[fromIntegral (i `mod` 256), fromIntegral (i `div` 256)] | i ← [0, 1, 2, 2, 3, 0 ∷ Word16]])
