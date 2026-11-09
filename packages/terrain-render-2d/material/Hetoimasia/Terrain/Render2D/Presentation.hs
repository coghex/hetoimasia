-- | The terrain material's presentation settings and the push block they pack to (TRA-17).
--
-- A presentation snapshot carries one immutable 'LightSettings'. Nothing here is a world clock
-- or a global mutable light: the later view owner (and, through it, Lua) supplies a value, which
-- is validated as a whole before anything usable is produced, and a snapshot keeps it.
--
-- == Settings
--
-- > setting         valid range                                   default
-- > sun azimuth     [0, 360) degrees, N=0 E=90 S=180 W=270         225
-- > sun elevation   [-90, 90] degrees above the horizon            45
-- > ambient         [0, 1], independent linear illumination        0.35
-- > sun strength    [0, 1], direct strength                        1
-- > depth range     integer cell levels 1 .. 250                   250
-- > darkening       [0, 1], fraction at full range                 0.15
-- > haze            [0, 1], blend fraction at full range           0.60
-- > haze colour     complete sRGB triple, each [0, 1]              (0.72, 0.85, 0.95)
--
-- A value that is not finite or is out of range is refused with the setting it names, and every
-- refusal is reported, so a caller sees the whole of what is wrong at once.
--
-- == The push block
--
-- The application push block is three @vec4@s in std430, 48 bytes, the most the engine leaves:
--
-- > offset 0    sun       view sun direction x, y, z; ambient
-- > offset 16   depth     effective sun strength; darkening; haze; reciprocal depth range
-- > offset 32   hazeLight haze colour in linear light r, g, b; padding (zero)
--
-- The sun direction is the world direction toward the sun (X east, Y south, Z up),
--
-- > (sin a cos e, -cos a cos e, sin e)
--
-- with its horizontal part turned by the camera's positive quarter turns, applied once, so a
-- normal that is already in the selected map's rotated view frame is compared with it directly
-- and a fixed world sun lights the same world-facing surface whatever the facing. The effective
-- sun strength is the setting when the elevation is above the horizon and zero otherwise. The
-- haze colour is converted from sRGB to linear light once, here. Every value is rounded once to a
-- 32-bit float, which is what the device reads.
--
-- == Depth
--
-- 'depthWord' is a cell's depth below the cut, @cut - z@, computed on wide integers and bounded
-- to @[0, maxDepthWord]@. The bound does not depend on the settings: the depth range is at most
-- 250, and a depth at or beyond the range is the full range, so the record stays the same when
-- only the lighting changes.
--
-- State, ownership and lifetime: none. Every value is immutable and every function pure.
module Hetoimasia.Terrain.Render2D.Presentation
  ( -- * Settings
    LightInput (..)
  , defaultLightInput
  , LightSettings
  , defaultLightSettings
  , SettingRefusal (..)
  , describeSettingRefusal
  , mkLightSettings
  , lightInput
  , maxDepthRange
  , maxDepthWord

    -- * The light
  , sunWorld
  , sunView
  , effectiveSunStrength
  , srgbToLinear

    -- * The push block
  , pushBytes
  , pushWords
  , pushBlockBytes
  , depthWord
  ) where

import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.Word (Word32)
import GHC.Float (castFloatToWord32, double2Float)
import Hetoimasia.Terrain.Render2D.Projection (facingTurnCount)
import Hetoimasia.Terrain.Shape (ViewFacing)

-- | A supplied, not yet checked, set of presentation settings.
data LightInput = LightInput
  { inputAzimuth ∷ !Double
  , inputElevation ∷ !Double
  , inputAmbient ∷ !Double
  , inputSunStrength ∷ !Double
  , inputDepthRange ∷ !Integer
  , inputDarkening ∷ !Double
  , inputHaze ∷ !Double
  , inputHazeColour ∷ !(Double, Double, Double)
  }
  deriving stock (Eq, Show)

-- | The approved defaults.
defaultLightInput ∷ LightInput
defaultLightInput = LightInput 225 45 0.35 1 250 0.15 0.60 (0.72, 0.85, 0.95)

-- | Checked settings. The constructor is private: a value of this type is valid.
newtype LightSettings = LightSettings LightInput
  deriving stock (Eq, Show)

-- | The checked defaults.
defaultLightSettings ∷ LightSettings
defaultLightSettings = LightSettings defaultLightInput

-- | The largest depth range, in cell levels.
maxDepthRange ∷ Integer
maxDepthRange = 250

-- | The bound of a record's depth word.
maxDepthWord ∷ Word32
maxDepthWord = 250

-- | What is wrong with a setting.
data SettingRefusal
  = -- | A value that is not a finite number.
    SettingNotFinite !String
  | -- | A value outside its range: the setting, then the value.
    SettingOutOfRange !String !Double
  | -- | The integral depth range outside 1..250.
    DepthRangeOutOfRange !Integer
  deriving stock (Eq, Show)

describeSettingRefusal ∷ SettingRefusal → String
describeSettingRefusal = \case
  SettingNotFinite name → name <> " is not a finite number"
  SettingOutOfRange name value → name <> " is " <> show value <> ", outside its range"
  DepthRangeOutOfRange n → "depth range is " <> show n <> ", outside 1 to " <> show maxDepthRange

-- | Check a set of settings as a whole: every problem is reported, and a value is made only when
-- there is none.
mkLightSettings ∷ LightInput → Either [SettingRefusal] LightSettings
mkLightSettings input = case problems of
  [] → Right (LightSettings input)
  _ → Left problems
  where
    LightInput azimuth elevation ambient strength range darkening haze (hr, hg, hb) = input
    problems =
      check "sun azimuth" azimuth (\v → v >= 0 && v < 360)
        <> check "sun elevation" elevation (\v → v >= -90 && v <= 90)
        <> check "ambient" ambient unit
        <> check "sun strength" strength unit
        <> [DepthRangeOutOfRange range | range < 1 || range > maxDepthRange]
        <> check "darkening" darkening unit
        <> check "haze" haze unit
        <> check "haze colour red" hr unit
        <> check "haze colour green" hg unit
        <> check "haze colour blue" hb unit
    unit v = v >= 0 && v <= 1
    check name value ok
      | isNaN value || isInfinite value = [SettingNotFinite name]
      | ok value = []
      | otherwise = [SettingOutOfRange name value]

-- | The settings as supplied.
lightInput ∷ LightSettings → LightInput
lightInput (LightSettings input) = input

-- | The world direction toward the sun: X east, Y south, Z up.
sunWorld ∷ LightSettings → (Double, Double, Double)
sunWorld (LightSettings input) = (sin a * cos e, negate (cos a) * cos e, sin e)
  where
    a = inputAzimuth input * pi / 180
    e = inputElevation input * pi / 180

-- | The sun as the selected map's view frame sees it: the horizontal part turned once by the
-- camera's positive quarter turns, one turn taking @(x, y)@ to @(-y, x)@.
sunView ∷ ViewFacing → LightSettings → (Double, Double, Double)
sunView facing settings = (tx, ty, z)
  where
    (x, y, z) = sunWorld settings
    (tx, ty) = case facingTurnCount facing `mod` 4 of
      0 → (x, y)
      1 → (negate y, x)
      2 → (negate x, negate y)
      _ → (y, negate x)

-- | The direct strength the shader applies: the setting above the horizon, zero at or below it.
effectiveSunStrength ∷ LightSettings → Double
effectiveSunStrength (LightSettings input)
  | inputElevation input > 0 = inputSunStrength input
  | otherwise = 0

-- | The sRGB transfer function's decoding of one component.
srgbToLinear ∷ Double → Double
srgbToLinear v
  | v <= 0.04045 = v / 12.92
  | otherwise = ((v + 0.055) / 1.055) ** 2.4

-- | The twelve floats of the push block, in order, each rounded once to 32 bits.
pushWords ∷ ViewFacing → LightSettings → [Float]
pushWords facing settings@(LightSettings input) =
  map
    double2Float
    [ sx
    , sy
    , sz
    , inputAmbient input
    , effectiveSunStrength settings
    , inputDarkening input
    , inputHaze input
    , 1 / fromInteger (inputDepthRange input)
    , srgbToLinear hr
    , srgbToLinear hg
    , srgbToLinear hb
    , 0
    ]
  where
    (sx, sy, sz) = sunView facing settings
    (hr, hg, hb) = inputHazeColour input

-- | The push block's size in bytes: three @vec4@s.
pushBlockBytes ∷ Int
pushBlockBytes = 48

-- | The push block, little-endian.
pushBytes ∷ ViewFacing → LightSettings → ByteString.ByteString
pushBytes facing settings = Lazy.toStrict (Builder.toLazyByteString (foldMap (Builder.word32LE . castFloatToWord32) (pushWords facing settings)))

-- | A cell's depth below the cut: @cut - z@ on wide integers, bounded to @[0, maxDepthWord]@ so a
-- cell at or above the cut is zero and one at or beyond the largest range is the bound.
depthWord ∷ Integer → Integer → Word32
depthWord cut z
  | d <= 0 = 0
  | d >= toInteger maxDepthWord = maxDepthWord
  | otherwise = fromInteger d
  where
    d = cut - z
