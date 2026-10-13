-- | What the sample's images contain and what the evidence frame must show,
-- stated here by hand and independently of any decoder, of the oracle and of
-- the device (R2D-8).
--
-- The region tables restate those in @tools/make_fixtures.py@, which makes the
-- files: every texel of every image lies in at least one region, so a texel's
-- colour is the last region covering it. The suite decodes the committed files
-- and compares them with these tables. The named probes of the evidence frame
-- are positions with a colour read off the tables through the frame's
-- geometry, worked out in the comments beside each, and a contrast: the same
-- question asked where the behaviour is absent.
module Hetoimasia.Sample.Image2d.Fixtures
  ( -- * The images
    Region (..)
  , Fixture (..)
  , fixture
  , texelAt
    -- * The evidence frame
  , Colour (..)
  , Coverage (..)
  , NamedProbe (..)
  , namedProbes
  , backgroundColour
  ) where

import Data.Word (Word32, Word8)
import Hetoimasia.Asset.Image (TexelFormat (..))
import Hetoimasia.Sample.Image2d.Assets (ImageName (..))

-- | A rectangle of texels, @x0 ≤ x < x1@ and @y0 ≤ y < y1@, of one straight
-- RGBA colour.
data Region = Region !Int !Int !Int !Int !Colour
  deriving (Eq, Show)

-- | A straight (not premultiplied) RGBA8 colour.
data Colour = Colour !Word8 !Word8 !Word8 !Word8
  deriving (Eq, Show)

-- | What one image is.
data Fixture = Fixture
  { fixtureName ∷ !ImageName
  , fixtureWidth ∷ !Word32
  , fixtureHeight ∷ !Word32
  , fixtureLevels ∷ !Int
    -- ^ How many levels decoding gives: a PNG decodes to its one level, since
    -- the sample does not generate a mip chain, and the KTX2 file stores one.
  , fixtureFormat ∷ !TexelFormat
  , fixtureBinaryAlpha ∷ !Bool
    -- ^ Whether every alpha is 0 or 255, the default cutout mark.
  , fixtureRegions ∷ ![Region]
  }

fixture ∷ ImageName → Fixture
fixture = \case
  Quadrants →
    Fixture Quadrants 64 64 1 TexelRgba8Srgb True
      [ Region 0 0 32 32 red
      , Region 32 0 64 32 green
      , Region 0 32 32 64 blue
      , Region 32 32 64 64 yellow
      , Region 4 4 12 12 magenta
      , Region 52 52 60 60 white
      ]
  Fade →
    Fixture Fade 64 64 1 TexelRgba8Srgb False
      [ Region 0 0 32 64 (Colour 200 60 60 128)
      , Region 32 0 64 64 (Colour 60 60 200 255)
      ]
  Stripes →
    Fixture Stripes 32 32 1 TexelRgba8Srgb True
      [ Region 0 0 32 8 cyan
      , Region 0 8 32 16 orange
      , Region 0 16 32 24 purple
      , Region 0 24 32 32 grey
      , Region 0 0 4 4 white
      ]

red, green, blue, yellow, magenta, white, cyan, orange, purple, grey ∷ Colour
red = Colour 220 40 40 255
green = Colour 40 200 60 255
blue = Colour 50 70 220 255
yellow = Colour 240 220 50 255
magenta = Colour 255 0 255 255
white = Colour 255 255 255 255
cyan = Colour 0 200 200 255
orange = Colour 255 140 0 255
purple = Colour 150 60 200 255
grey = Colour 128 128 128 255

-- | The straight colour of a texel of level 0: the last region covering it, or
-- transparent black when none does.
texelAt ∷ Fixture → (Int, Int) → Colour
texelAt image (x, y) = foldl pick (Colour 0 0 0 0) (fixtureRegions image)
  where
    pick current (Region x0 y0 x1 y1 colour)
      | x0 <= x && x < x1 && y0 <= y && y < y1 = colour
      | otherwise = current

-- | The colour the evidence frame clears to: linear (0, 0, 0, 1), which an
-- sRGB target stores as (0, 0, 0, 255).
backgroundColour ∷ Colour
backgroundColour = Colour 0 0 0 255

-- | What a named probe covers: the evidence must hold a determinate probe of
-- each.
data Coverage = PngWorldCopy | PngUiCopy | Ktx2Copy | ClearBackground
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One behaviour the frame shows, a pixel that shows it, and a contrast.
data NamedProbe = NamedProbe
  { probeBehaviour ∷ !String
  , probeCovers ∷ !Coverage
  , probePixel ∷ !(Int, Int)
  , probeColour ∷ !Colour
  , probeContrastPixel ∷ !(Int, Int)
  , probeContrastColour ∷ !Colour
  }

-- | The evidence frame's named probes, for the layout of
-- "Hetoimasia.Sample.Image2d.Scene".'evidenceLayout': a 256×256 target of
-- logical extent 128×128 at content scale 2, UI scale 1, camera at the world
-- origin.
--
-- * The camera centres the world on pixel (128, 128) at one pixel per unit.
--   The PNG's world copy is 64 units square at world (−80, 0), so it covers
--   pixels x 48–111, y 128–191, one texel to the pixel. The KTX2 copy is 64
--   units square at world (16, 0), so it covers x 144–207, y 128–191, two
--   pixels to the texel of its 32×32 image.
-- * The UI copy is 48 logical pixels square at UI (8, 8), so with UI scale 1
--   and content scale 2 it covers pixels 16–111 on both axes, 1.5 pixels to
--   the texel.
--
-- Every contrast pixel is outside the sprites it is contrasted with, or in a
-- different region of the same one, and no probe is within a sixteenth of a
-- texel of a texel boundary.
namedProbes ∷ [NamedProbe]
namedProbes =
  [ -- Texel (22, 22) of the PNG is in the red quadrant.
    NamedProbe "the PNG's world copy shows its red quadrant at the upper left" PngWorldCopy (70, 150) red (70, 200) backgroundColour
  , -- Texel (52, 22) is in the green quadrant.
    NamedProbe "the PNG's world copy shows its green quadrant at the upper right" PngWorldCopy (100, 150) green (120, 150) backgroundColour
  , -- Texel (22, 52) is in the blue quadrant.
    NamedProbe "the PNG's world copy shows its blue quadrant at the lower left" PngWorldCopy (70, 180) blue (40, 180) backgroundColour
  , -- Texel (42, 42) is in the yellow quadrant.
    NamedProbe "the PNG's world copy shows its yellow quadrant at the lower right" PngWorldCopy (90, 170) yellow (90, 195) backgroundColour
  , -- The magenta marker, texels 4–11 on both axes, is at the upper left: a
    -- vertical flip would put it at the lower left, which is blue.
    NamedProbe "the PNG's world copy is not flipped: its marker is at the upper left" PngWorldCopy (56, 136) magenta (56, 184) blue
  , -- The white marker, texels 52–59 on both axes, is at the lower right: a
    -- horizontal flip would put it at the lower left, which is blue.
    NamedProbe "the PNG's world copy is not mirrored: its second marker is at the lower right" PngWorldCopy (104, 184) white (56, 184) blue
  , -- A world copy is 64 pixels whatever the content scale; scaled by it, it
    -- would reach pixel 175, and pixel (120, 150) would be green.
    NamedProbe "the world copy is drawn in world units, not scaled by the content scale" PngWorldCopy (100, 150) green (120, 150) backgroundColour
  , -- The KTX2 file's bands, 8 texels each, are 16 pixels each.
    NamedProbe "the KTX2 copy shows its cyan band at the top" Ktx2Copy (190, 136) cyan (190, 120) backgroundColour
  , NamedProbe "the KTX2 copy shows its orange band second" Ktx2Copy (190, 152) orange (190, 136) cyan
  , NamedProbe "the KTX2 copy shows its purple band third" Ktx2Copy (190, 168) purple (190, 152) orange
  , NamedProbe "the KTX2 copy shows its grey band last" Ktx2Copy (190, 184) grey (190, 168) purple
  , -- The corner marker, texels 0–3, is at pixels 144–151, 128–135.
    NamedProbe "the KTX2 copy's marker is at its upper left" Ktx2Copy (147, 131) white (190, 131) cyan
  , -- Texel (9, 9) of the UI copy, by 1.5 pixels to the texel: pixel 30
    -- covers texel 9.67, which is in the magenta marker's span 4–11; pixel 45
    -- covers 19.67, in the red quadrant.
    NamedProbe "the PNG's UI copy shows its red quadrant at the upper left" PngUiCopy (45, 45) red (45, 130) backgroundColour
  , NamedProbe "the PNG's UI copy shows its green quadrant at the upper right" PngUiCopy (90, 30) green (130, 30) backgroundColour
  , NamedProbe "the PNG's UI copy shows its blue quadrant at the lower left" PngUiCopy (30, 90) blue (10, 90) backgroundColour
  , NamedProbe "the PNG's UI copy shows its yellow quadrant at the lower right" PngUiCopy (82, 82) yellow (82, 118) backgroundColour
  , NamedProbe "the PNG's UI copy shows its marker at the upper left" PngUiCopy (24, 24) magenta (24, 100) blue
  , -- The UI copy is 48 logical pixels times the content scale of 2 wide:
    -- pixel 100 is inside it and a copy at content scale 1 would have ended
    -- at pixel 56, where it would show background.
    NamedProbe "the UI copy spans its logical size times the content scale" PngUiCopy (100, 30) green (118, 30) backgroundColour
  , NamedProbe "the clear colour fills what no sprite covers" ClearBackground (5, 250) backgroundColour (70, 150) red
  ]
