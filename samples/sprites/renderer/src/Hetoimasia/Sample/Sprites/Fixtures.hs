-- | The sprites sample's technical fixtures (GRS-8): three textures made of
-- generated or embedded bytes, each with exactly one caller-supplied mip
-- level, and the decoded texels every expected pixel is computed from.
--
-- They are scaffolding, not art. Texture coordinates follow Vulkan's
-- convention: @(0, 0)@ is the upper-left corner of texel @(0, 0)@, @u@ grows
-- rightwards and @v@ downwards, and texel @(x, y)@ covers
-- @[x / width, (x + 1) / width) × [y / height, (y + 1) / height)@.
--
-- * 'atlasFixture': an 8×8 linear RGBA8 atlas of four opaque 4×4 regions —
--   red upper-left, green upper-right, blue lower-left, yellow lower-right —
--   whose normalized rectangles divide each axis at 0.5 ('atlasRegion').
-- * 'translucentFixture': a 2×2 linear RGBA8 texture, premultiplied red
--   @(128, 0, 0, 128)@ in its left column and premultiplied blue
--   @(0, 0, 128, 128)@ in its right, in both rows.
-- * 'bc7Fixture': one 4×4 linear BC7 block, embedded as fixed bytes. It is a
--   mode-6 block whose two endpoints are @(255, 1, 1, 255)@ and
--   @(1, 1, 255, 255)@, with index 0 for the left two columns and index 15
--   for the right two: weights 0 and 64, which reproduce the endpoints
--   exactly. 'bc7Decoded' is that oracle, established independently of any
--   device; the sample's suite decodes the bytes again to check it.
-- * 'swappedAtlasFixture': the swap case's replacement for the atlas
--   (GRS-9), of the same 8×8 linear RGBA8 layout — so every UV rectangle
--   and the linear probe's sub-texel margin hold unchanged — with its
--   regions' colours rotated: green upper-left, blue upper-right, yellow
--   lower-left, red lower-right. Every region differs from the atlas's.
module Hetoimasia.Sample.Sprites.Fixtures
  ( -- * Texels
    Rgba (..)
  , transparent
    -- * Fixtures
  , Fixture (..)
  , FixtureName (..)
  , fixture
  , atlasFixture
  , swappedAtlasFixture
  , translucentFixture
  , bc7Fixture
  , bc7Block
  , bc7Decoded
  , texelAt
    -- * The atlas's regions
  , AtlasRegion (..)
  , atlasRegion
  , UvRect (..)
  ) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.Word (Word32, Word8)

import Hetoimasia.GPU.Vulkan.Native.Recording (ImageFormat (..))

-- | One texel, or one pixel, as four 8-bit channels.
data Rgba = Rgba !Word8 !Word8 !Word8 !Word8
  deriving (Eq, Ord, Show)

-- | The evidence target's clear.
transparent ∷ Rgba
transparent = Rgba 0 0 0 0

data FixtureName
  = Atlas
  | Translucent
  | Bc7Block
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A texture: its format and extent, the one mip level's bytes as uploaded,
-- and its decoded texels, row by row from the top.
data Fixture = Fixture
  { fixtureName ∷ !FixtureName
  , fixtureFormat ∷ !ImageFormat
  , fixtureWidth ∷ !Word32
  , fixtureHeight ∷ !Word32
  , fixtureBytes ∷ !ByteString
  , fixtureTexels ∷ ![[Rgba]]
  }
  deriving (Eq, Show)

fixture ∷ FixtureName → Fixture
fixture = \case
  Atlas → atlasFixture
  Translucent → translucentFixture
  Bc7Block → bc7Fixture

atlasFixture ∷ Fixture
atlasFixture = rgba8 Atlas 8 8 [[atlasTexel x y | x ← [0 .. 7]] | y ← [0 .. 7]]
  where
    atlasTexel ∷ Int → Int → Rgba
    atlasTexel x y = case (x < 4, y < 4) of
      (True, True) → Rgba 255 0 0 255
      (False, True) → Rgba 0 255 0 255
      (True, False) → Rgba 0 0 255 255
      (False, False) → Rgba 255 255 0 255

-- | The swap case's replacement atlas: the atlas's layout, each region's
-- colour rotated to the next.
swappedAtlasFixture ∷ Fixture
swappedAtlasFixture = rgba8 Atlas 8 8 [[swappedTexel x y | x ← [0 .. 7]] | y ← [0 .. 7]]
  where
    swappedTexel ∷ Int → Int → Rgba
    swappedTexel x y = case (x < 4, y < 4) of
      (True, True) → Rgba 0 255 0 255
      (False, True) → Rgba 0 0 255 255
      (True, False) → Rgba 255 255 0 255
      (False, False) → Rgba 255 0 0 255

translucentFixture ∷ Fixture
translucentFixture = rgba8 Translucent 2 2 (replicate 2 [Rgba 128 0 0 128, Rgba 0 0 128 128])

bc7Fixture ∷ Fixture
bc7Fixture = Fixture Bc7Block Bc7Linear 4 4 bc7Block bc7Decoded

-- | The BC7 block's sixteen bytes, as committed.
bc7Block ∷ ByteString
bc7Block = ByteString.pack [0xc0, 0x3f, 0x00, 0x00, 0x00, 0xfc, 0xff, 0xff, 0x01, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff]

-- | What the block decodes to: the first endpoint in the left two columns,
-- the second in the right two, in every row.
bc7Decoded ∷ [[Rgba]]
bc7Decoded = replicate 4 [left, left, right, right]
  where
    left = Rgba 255 1 1 255
    right = Rgba 1 1 255 255

-- | A linear RGBA8 fixture whose bytes are its texels, row by row.
rgba8 ∷ FixtureName → Word32 → Word32 → [[Rgba]] → Fixture
rgba8 name width height texels =
  Fixture name Rgba8Linear width height (ByteString.pack (concat [[r, g, b, a] | Rgba r g b a ← concat texels])) texels

-- | The texel at a column and row, clamped to the edge.
texelAt ∷ Fixture → Int → Int → Rgba
texelAt texture x y = (fixtureTexels texture !! clampTo (fixtureHeight texture) y) !! clampTo (fixtureWidth texture) x
  where
    clampTo extent = max 0 . min (fromIntegral extent - 1)

-- | A normalized texture-coordinate rectangle: its upper-left and
-- lower-right corners. A rectangle whose corners agree in an axis samples
-- one coordinate across the whole quad in that axis.
data UvRect = UvRect !Double !Double !Double !Double
  deriving (Eq, Show)

data AtlasRegion = RedRegion | GreenRegion | BlueRegion | YellowRegion
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Each atlas region's rectangle, dividing each axis at 0.5.
atlasRegion ∷ AtlasRegion → UvRect
atlasRegion = \case
  RedRegion → UvRect 0 0 0.5 0.5
  GreenRegion → UvRect 0.5 0 1 0.5
  BlueRegion → UvRect 0 0.5 0.5 1
  YellowRegion → UvRect 0.5 0.5 1 1
