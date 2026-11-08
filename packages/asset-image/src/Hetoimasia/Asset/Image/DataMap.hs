-- | Generic validation and CPU coverage for decoded data maps (TRA-15): the binary alpha
-- coverage plane and the numeric normal-map encoding a texture request may declare.
--
-- Nothing here knows terrain, a game, a graphics device, a Lua engine or an account: these are
-- pure functions over one decoded RGBA8 level (what
-- 'Hetoimasia.Asset.Image.PngDecode.decodeBoundedWith' produces) and the values they build.
-- The texture pipeline calls them while the accounted decode buffer exists and before anything
-- is uploaded or published, so a refusal here is an expected content failure with nothing usable
-- made.
--
-- = Binary coverage
--
-- 'buildBinaryCoverage' inspects the same alpha bytes that are uploaded. Only 0 and 255 are
-- valid; any other alpha is a refusal naming the first texel (row-major, top row first) that
-- breaks it, and nothing is thresholded. The result is a 'CoveragePlane': one bit per texel,
-- immutable, tightly packed across rows with no row padding, in top-row-first, left-to-right
-- order. Texel @(x, y)@ is bit @y × width + x@, which is bit @k mod 8@ of byte @k div 8@, least
-- significant bit first; the unused high bits of the final byte are zero. The plane is
-- @ceil(width × height ÷ 8)@ bytes ('coveragePlaneBytes'), and with the fixed bounded
-- metadata a retained plane is accounted at 'coverageRetainedBytes'. It is a value: sharing it
-- among readers copies nothing, which is the owning resource's job to keep true.
--
-- == The sampling reference
--
-- 'sampleIndex' is the asset-level rule for a normalized coordinate and an extent
-- @n@: @i = min (n - 1) (floor (clamp u 0 1 × n))@. An interior boundary @k / n@ selects the
-- higher index, the outer edge @1@ selects the last texel, and the arithmetic is exact: the
-- product is evaluated on the coordinate's own mantissa and exponent, never as a floating
-- product that could round the predecessor of @k / n@ up onto the boundary. A coordinate that
-- is not a number has no texel. This claims nothing outside a rasterized quad and implements no
-- viewport or raster-edge ownership.
--
-- = Normal encodings
--
-- 'UnitNormalRgbV1' (@unit-normal-rgb-v1@) represents a unit normal @n@ as
-- @round (128 + 127 × n)@ per channel. For every nontransparent texel (alpha not 0) all of R, G
-- and B must be in @1..255@ and the triple must not be @(128, 128, 128)@, the zero vector; a
-- transparent texel's RGB is ignored. 'checkNormalEncoding' only reads: accepted bytes are never
-- altered. 'unitNormal' is the decoding: normalize @c - (128, 128, 128)@.
module Hetoimasia.Asset.Image.DataMap
  ( -- * Binary coverage
    CoveragePlane
  , coverageWidth
  , coverageHeight
  , coverageBits
  , coveragePlaneBytes
  , coverageMetadataBytes
  , coverageRetainedBytes
  , maxCoveragePlaneBytes
  , CoverageRefusal (..)
  , coverageRefusalText
  , buildBinaryCoverage
  , coverageAt
  , sampleIndex
  , coverageSample

    -- * Normal encodings
  , NormalEncoding (..)
  , normalEncodingName
  , parseNormalEncoding
  , NormalRefusal (..)
  , normalRefusalText
  , checkNormalEncoding
  , unitNormal
  ) where

import Control.DeepSeq (NFData (rnf))
import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Internal as ByteString (unsafeCreate)
import qualified Data.ByteString.Unsafe as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word8)
import Foreign.Storable (pokeByteOff)

-- | One bit per texel of one immutable level: see the module description for the layout. The
-- fields are not exported, so a plane can be made only by 'buildBinaryCoverage', and its bytes
-- are never written after.
data CoveragePlane = CoveragePlane
  { planeWidth ∷ !Word32
  , planeHeight ∷ !Word32
  , planeBits ∷ !ByteString
  }
  deriving (Eq, Show)

instance NFData CoveragePlane where
  rnf (CoveragePlane width height bits) = rnf width `seq` rnf height `seq` rnf bits

coverageWidth, coverageHeight ∷ CoveragePlane → Word32
coverageWidth = planeWidth
coverageHeight = planeHeight

-- | The plane's storage, exactly 'coveragePlaneBytes' long: bit @y × width + x@ is bit
-- @(y × width + x) mod 8@ of byte @(y × width + x) div 8@, least significant first.
coverageBits ∷ CoveragePlane → ByteString
coverageBits = planeBits

-- | The bytes a plane of this extent occupies: @ceil (width × height ÷ 8)@.
coveragePlaneBytes ∷ Word32 → Word32 → Integer
coveragePlaneBytes width height = maxCoveragePlaneBytes (toInteger width * toInteger height)

-- | The bytes of the plane of this many texels.
maxCoveragePlaneBytes ∷ Integer → Integer
maxCoveragePlaneBytes texels = (texels + 7) `div` 8

-- | The bounded, fixed metadata a retained plane is accounted for beside its bits: the extent,
-- the image kind, the encoding fact, the version's identity and the interest bookkeeping.
-- A constant, so a retained plane's charge is a function of its extent alone.
coverageMetadataBytes ∷ Integer
coverageMetadataBytes = 128

-- | What a retained plane of this extent is accounted at: its bits and 'coverageMetadataBytes'.
coverageRetainedBytes ∷ Word32 → Word32 → Integer
coverageRetainedBytes width height = coveragePlaneBytes width height + coverageMetadataBytes

-- | Why a level has no binary coverage.
data CoverageRefusal
  = -- | The level is not @width × height × 4@ bytes: a fault of the caller, not of any file.
    CoverageLevelMismatch !Int !Integer
  | -- | The first texel (column, row) whose alpha is neither 0 nor 255, and that alpha.
    CoverageNotBinary !Word32 !Word32 !Word8
  deriving (Eq, Show)

-- | The refusal as bounded text naming the policy that failed.
coverageRefusalText ∷ CoverageRefusal → Text
coverageRefusalText = \case
  CoverageLevelMismatch found expected ->
    "binary coverage was asked of a level of " <> tshow found <> " bytes, not " <> tshow expected
  CoverageNotBinary x y alpha ->
    "coverage=binary needs every alpha to be 0 or 255, and the texel at column "
      <> tshow x
      <> ", row "
      <> tshow y
      <> " has alpha "
      <> tshow alpha

-- | The coverage plane of an RGBA8 level of this extent, or why it has none. The level is only
-- read: nothing is thresholded, and no plane exists unless every texel's alpha is 0 or 255.
buildBinaryCoverage ∷ Word32 → Word32 → ByteString → Either CoverageRefusal CoveragePlane
buildBinaryCoverage width height level
  | toInteger (ByteString.length level) /= texels * 4 = Left (CoverageLevelMismatch (ByteString.length level) (texels * 4))
  | Just offender ← firstNonBinary = Left (let (y, x) = offender `quotRem` w in CoverageNotBinary (fromIntegral x) (fromIntegral y) (ByteString.unsafeIndex level (4 * offender + 3)))
  | otherwise = Right $! CoveragePlane width height bits
  where
    texels = toInteger width * toInteger height
    w = fromIntegral width ∷ Int
    count = fromInteger texels ∷ Int
    firstNonBinary = scan 0
      where
        scan !i
          | i >= count = Nothing
          | alpha <- ByteString.unsafeIndex level (4 * i + 3), alpha /= 0 && alpha /= 255 = Just i
          | otherwise = scan (i + 1)
    bits = ByteString.unsafeCreate (fromInteger (maxCoveragePlaneBytes texels)) $ \out ->
      let byteAt !b
            | b >= fromInteger (maxCoveragePlaneBytes texels) = pure ()
            | otherwise = do
                let packed = pack (b * 8) 0 0
                pokeByteOff out b (packed ∷ Word8)
                byteAt (b + 1)
          pack !i !k !acc
            | k >= 8 || i >= count = acc
            | ByteString.unsafeIndex level (4 * i + 3) == 255 = pack (i + 1) (k + 1) (acc .|. (1 `shiftL` k))
            | otherwise = pack (i + 1) (k + 1) acc
       in byteAt 0

-- | Whether the texel at (column, row) is covered, or 'Nothing' outside the extent.
coverageAt ∷ CoveragePlane → Word32 → Word32 → Maybe Bool
coverageAt plane x y
  | x >= planeWidth plane || y >= planeHeight plane = Nothing
  | otherwise =
      let k = toInteger y * toInteger (planeWidth plane) + toInteger x
          byte = ByteString.unsafeIndex (planeBits plane) (fromInteger (k `shiftR` 3))
       in Just (testBit byte (fromInteger (k .&. 7)))

-- | The texel index a normalized coordinate selects in an extent of this many texels:
-- @min (n - 1) (floor (clamp u 0 1 × n))@, exactly. 'Nothing' for a coordinate that is not a
-- number, and for an extent of zero.
sampleIndex ∷ Word32 → Double → Maybe Word32
sampleIndex n u
  | n == 0 || isNaN u = Nothing
  | otherwise = Just (min (n - 1) (fromInteger scaled))
  where
    clamped = min 1 (max 0 u)
    (mantissa, exponent') = decodeFloat clamped
    product' = mantissa * toInteger n
    -- floor of mantissa × 2^exponent × n, on integers: a nonnegative number, so a right shift floors.
    scaled
      | exponent' >= 0 = product' `shiftL` exponent'
      | otherwise = product' `shiftR` negate exponent'

-- | Whether the texel normalized coordinates @(u, v)@ select is covered, by 'sampleIndex' on each
-- axis, or 'Nothing' for a coordinate that is not a number.
coverageSample ∷ CoveragePlane → Double → Double → Maybe Bool
coverageSample plane u v = do
  x ← sampleIndex (planeWidth plane) u
  y ← sampleIndex (planeHeight plane) v
  coverageAt plane x y

-- Normal encodings ----------------------------------------------------------------------------------------

-- | A declared meaning for the RGB bytes of a data map.
data NormalEncoding
  = -- | @unit-normal-rgb-v1@: @round (128 + 127 × n)@ per channel.
    UnitNormalRgbV1
  deriving (Eq, Show)

-- | The name a request states the encoding by.
normalEncodingName ∷ NormalEncoding → Text
normalEncodingName UnitNormalRgbV1 = "unit-normal-rgb-v1"

-- | The encoding a name states, if it is one.
parseNormalEncoding ∷ Text → Maybe NormalEncoding
parseNormalEncoding = \case
  "unit-normal-rgb-v1" → Just UnitNormalRgbV1
  _ → Nothing

-- | The first texel (column, row) that breaks the encoding, its bytes, and how.
data NormalRefusal
  = NormalLevelMismatch !Int !Integer
  | -- | A nontransparent texel has a zero channel.
    NormalZeroChannel !Word32 !Word32 !Word8 !Word8 !Word8
  | -- | A nontransparent texel is the zero vector, @(128, 128, 128)@.
    NormalZeroVector !Word32 !Word32
  deriving (Eq, Show)

-- | The refusal as bounded text naming the policy that failed.
normalRefusalText ∷ NormalEncoding → NormalRefusal → Text
normalRefusalText encoding = \case
  NormalLevelMismatch found expected ->
    name <> " was asked of a level of " <> tshow found <> " bytes, not " <> tshow expected
  NormalZeroChannel x y r g b ->
    name <> " needs every channel of a nontransparent texel in 1..255, and the texel at column " <> tshow x <> ", row " <> tshow y <> " is (" <> tshow r <> ", " <> tshow g <> ", " <> tshow b <> ")"
  NormalZeroVector x y ->
    name <> " does not allow the zero vector (128, 128, 128), and the texel at column " <> tshow x <> ", row " <> tshow y <> " is it"
  where
    name = "normal_encoding=" <> normalEncodingName encoding

-- | Check an RGBA8 level against the encoding, reading it and nothing more.
checkNormalEncoding ∷ NormalEncoding → Word32 → Word32 → ByteString → Either NormalRefusal ()
checkNormalEncoding UnitNormalRgbV1 width height level
  | toInteger (ByteString.length level) /= texels * 4 = Left (NormalLevelMismatch (ByteString.length level) (texels * 4))
  | otherwise = go 0
  where
    texels = toInteger width * toInteger height
    w = fromIntegral width ∷ Int
    count = fromInteger texels ∷ Int
    go !i
      | i >= count = Right ()
      | alpha == 0 = go (i + 1)
      | r == 0 || g == 0 || b == 0 = Left (NormalZeroChannel x y r g b)
      | r == 128 && g == 128 && b == 128 = Left (NormalZeroVector x y)
      | otherwise = go (i + 1)
      where
        r = ByteString.unsafeIndex level (4 * i)
        g = ByteString.unsafeIndex level (4 * i + 1)
        b = ByteString.unsafeIndex level (4 * i + 2)
        alpha = ByteString.unsafeIndex level (4 * i + 3)
        (row, column) = i `quotRem` w
        x = fromIntegral column
        y = fromIntegral row

-- | The unit vector an encoded triple stands for: @c - (128, 128, 128)@ normalized, or 'Nothing'
-- for the zero vector.
unitNormal ∷ (Word8, Word8, Word8) → Maybe (Double, Double, Double)
unitNormal (r, g, b)
  | length' == 0 = Nothing
  | otherwise = Just (dx / length', dy / length', dz / length')
  where
    dx = fromIntegral r - 128
    dy = fromIntegral g - 128
    dz = fromIntegral b - 128
    length' = sqrt (dx * dx + dy * dy + dz * dz) ∷ Double

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
