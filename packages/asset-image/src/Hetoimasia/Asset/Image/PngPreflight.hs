-- | Bounded preflight of a static PNG: the checks that decide, before any
-- size-derived allocation or any decoder runs, whether a PNG is inside a
-- caller-supplied set of resource limits.
--
-- This is the M1 Lua texture profile's codec boundary (design D-65, D-77).
-- It is opt-in: 'Hetoimasia.Asset.Image.Png.decodePng' and 'pngDecoder' are
-- unchanged and impose none of these limits. A successful 'preflightPng' is
-- not a decoded image and not a usable texture: it is the proof that these
-- bytes, under these limits, have sound framing, a header inside the
-- profile, and an image data stream that inflates to at least the scanline
-- bytes the header needs and at most the inflation budget. Decoding and
-- conversion to RGBA8, and the accounting of their live buffers, are the
-- next stage's (LFE-15); see "Obligations on the decoding stage" below.
--
-- == The limits
--
-- 'PngLimits' holds seven positive limits, each at most 2^31 − 1, built only
-- by 'pngLimits' (which refuses anything else) or 'm1PngLimits'. Every limit
-- fits an 'Int' on any word size, and every product, sum and pass extent
-- derived from a header is computed in 'Integer' and compared with a limit
-- before it is narrowed, so acceptance never depends on the machine word.
-- No value means "unlimited".
--
-- == The order of the checks
--
-- Classification is deterministic for given bytes and limits: the checks run
-- in this order, and the first to fail decides the refusal and its class.
--
-- 1. Source length against the source limit ('LimitSourceBytes').
-- 2. The eight-byte PNG signature. Empty input, a proper prefix of the
--    signature and bytes beginning otherwise are 'UnsupportedFormat'; the
--    recognition is by bytes, never by an asset's name or a format hint.
-- 3. Each chunk in file order, from the first through IEND. For one chunk:
--    framing (twelve bytes of length, type and CRC, and its declared data
--    inside the remaining input), then the chunk limit ('LimitChunks'), then
--    the CRC of its type and data, then what the chunk means: the first
--    chunk must be a 13-byte IHDR (anything else is 'MalformedPng'), and an
--    animation chunk (@acTL@, @fcTL@ or @fdAT@, anywhere up to IEND, before
--    or after the first IDAT) is 'UnsupportedFormat'. A chunk whose declared
--    data runs past the end of the input is a truncation, 'MalformedPng',
--    refused before anything is taken from it. Input that ends before IEND
--    is 'MalformedPng'. Every chunk's CRC is checked, ancillary and unknown
--    chunks included, and none is decompressed.
-- 4. The header: an unknown colour type or interlace method, a zero width or
--    height, a dimension above the PNG specification's 2^31 − 1, an unknown
--    compression or filter method, or a bit depth the colour type does not
--    allow is 'MalformedPng'.
-- 5. Size-derived limits, in this order: width, height, pixels, the
--    eventual RGBA8 output (4 bytes a pixel), and the scanline bytes the
--    header needs against the inflation limit. Each is 'ExceededLimit'.
-- 6. Inflation of the IDAT chunks as one stream, counted as the inflater
--    produces it. More than the inflation limit is
--    @'ExceededLimit' 'LimitInflatedBytes'@; a stream that fails, ends early,
--    or inflates to fewer bytes than the header needs is 'MalformedPng'.
--
-- Bytes after a complete IEND are not parsed and do not count as chunks;
-- they count towards the source limit, and are otherwise ignored as the
-- general decoder ignores them.
--
-- == Failures that are not refusals
--
-- 'PngRefusal' is only ever one of the three content classes. An allocator
-- failure, an exception from the inflater binding other than its own
-- corrupt-or-truncated report, or any other fault is not a content refusal:
-- 'preflightPng' does not catch it. It propagates as an exception when the
-- result is demanded, an asynchronous exception included, and the caller
-- (the texture provider) decides its authority. In particular this does not
-- copy 'Hetoimasia.Asset.Image.Png.decodePng', which turns every synchronous
-- exception into a refusal. The result is deeply evaluated ('rnf') before it
-- is returned, so demanding it to weak head normal form has already done all
-- the work: no value in it holds a suspended computation, inflater state or
-- inflater output. That includes the caller's 'Asset', which the result
-- carries: an exception raised by evaluating it propagates from here.
--
-- == What a successful preflight holds
--
-- A 'PngPreflight' is associated with the bytes and limits it validated:
-- there is no way to build one except 'preflightPng', and 'preflightSource'
-- returns those bytes. It retains the caller's 'ByteString' itself, not a
-- copy, and slices of it (the IDAT chunk data, the palette and the
-- transparency chunks: at most one 'ByteString' constructor each per chunk, so
-- at most the chunk limit of them). Nothing is inflated into a retained
-- buffer. The slices keep the source buffer alive, so the holder releases
-- everything by dropping the 'PngPreflight' (and any slice it took). Preflight
-- owns no thread, file or native handle.
--
-- == Accounting
--
-- +----------------------------+---------------------------------------+-------------------------+
-- | Item                       | Size                                  | Lifetime                |
-- +============================+=======================================+=========================+
-- | Input view                 | the caller's buffer, not copied       | the caller's; kept alive|
-- |                            | (at most the source limit)            | by the result           |
-- +----------------------------+---------------------------------------+-------------------------+
-- | Chunk descriptors          | scan: four words of loop state and    | the scan; the retained  |
-- |                            | one slice per IDAT, tRNS and the      | slices live in the      |
-- |                            | first PLTE; at most one slice per     | result                  |
-- |                            | counted chunk, so at most the chunk   |                         |
-- |                            | limit                                 |                         |
-- +----------------------------+---------------------------------------+-------------------------+
-- | Inflater state             | one zlib stream, created and freed by | from the first input to |
-- |                            | the @zlib@ binding (see below)        | stream end, failure, or |
-- |                            |                                       | the abandoned drive's   |
-- |                            |                                       | finalizer               |
-- +----------------------------+---------------------------------------+-------------------------+
-- | Inflater output scratch    | one piece at a time, at most 32 KiB   | counted and dropped     |
-- +----------------------------+---------------------------------------+-------------------------+
-- | Inflated image             | none: only the count is kept          | not applicable          |
-- +----------------------------+---------------------------------------+-------------------------+
-- | Result                     | a header record, the slices above,    | the caller's            |
-- |                            | the limits, the asset                 |                         |
-- +----------------------------+---------------------------------------+-------------------------+
--
-- The inflater's native state is allocated and released by the pinned @zlib@
-- binding, not by this package: a stream that ends or fails frees its state
-- itself, and a drive stopped by the budget leaves the stream to the
-- binding's foreign-pointer finalizer. No call here holds the state beyond
-- the ST computation that drives it, and the bundled C zlib is used (never a
-- system one). Allocation by the binding is bounded by one inflater state and
-- one output piece; this package does not measure it. These figures are the
-- preflight's alone: the complete decoder's workspace is not accounted here.
--
-- == Obligations on the decoding stage
--
-- Preflight does not bound the decoder. LFE-15 must decode from
-- 'preflightSource' (or the 'preflightImageData' slices) using an inflation
-- bounded by 'inflateLimit' of 'preflightLimits' — it may not hand the bytes
-- to the unbounded general decoder, which inflates without a limit and
-- builds its full chunk list — or establish an equally bounded path for any
-- later inflation, and must account for the RGBA8 output
-- ('preflightRgba8Bytes') and its own intermediates itself.
module Hetoimasia.Asset.Image.PngPreflight
  ( -- * Limits
    PngLimits
  , PngLimitSettings (..)
  , LimitKind (..)
  , LimitsRefusal (..)
  , pngLimits
  , pngLimitSettings
  , m1PngLimits
  , largestLimit

    -- * Preflight
  , preflightPng
  , PngRefusal (..)
  , PngRefusalClass (..)

    -- * A successful preflight
  , PngPreflight
  , preflightAsset
  , preflightLimits
  , preflightSource
  , preflightWidth
  , preflightHeight
  , preflightColourType
  , preflightBitDepth
  , preflightInterlace
  , preflightScanlineBytes
  , preflightInflatedBytes
  , preflightRgba8Bytes
  , preflightImageData
  , preflightPalette
  , preflightTransparency
  , preflightColourKey
  , PngColourType (..)
  , PngInterlace (..)
  , ColourKey (..)
  )
where

import Codec.Picture.Png.Internal.Type (PngImageType (..), pngComputeCrc)
import Control.DeepSeq (NFData (rnf))
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as Lazy
import Data.Char (isAsciiLower, isAsciiUpper)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word8)
import Hetoimasia.Asset (Asset)
import Hetoimasia.Asset.Image.Internal.PngGeometry
  ( PngColourType (..)
  , PngInterlace (..)
  , allowedDepths
  , colourTypeOfCode
  , interlaceOfCode
  , scanlineBytes
  )
import Hetoimasia.Asset.Image.Internal.PngInflate (Corruption (..), Inflation (..), inflateBounded)
import Hetoimasia.Asset.Image.Internal.PngStructure (ColourKey (..), colourKey)

-- | The resource a limit bounds, and so which limit a refusal exceeded.
data LimitKind
  = -- | Encoded PNG bytes.
    LimitSourceBytes
  | -- | Chunks, from IHDR through IEND inclusive.
    LimitChunks
  | -- | Width in pixels.
    LimitWidth
  | -- | Height in pixels.
    LimitHeight
  | -- | Width × height.
    LimitPixels
  | -- | The eventual single RGBA8 output, 4 bytes a pixel.
    LimitRgba8Bytes
  | -- | Decompressed scanline bytes, filter bytes included.
    LimitInflatedBytes
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The seven limits as the caller states them, before validation.
data PngLimitSettings = PngLimitSettings
  { settingSourceBytes ∷ !Integer
  , settingChunks ∷ !Integer
  , settingWidth ∷ !Integer
  , settingHeight ∷ !Integer
  , settingPixels ∷ !Integer
  , settingRgba8Bytes ∷ !Integer
  , settingInflatedBytes ∷ !Integer
  }
  deriving (Eq, Show)

-- | Validated limits. Every one is between 1 and 'largestLimit'; build them
-- with 'pngLimits'.
data PngLimits = PngLimits
  { sourceLimit ∷ !Int
  , chunkLimit ∷ !Int
  , widthLimit ∷ !Int
  , heightLimit ∷ !Int
  , pixelLimit ∷ !Int
  , rgba8Limit ∷ !Int
  , inflateLimit ∷ !Int
  }
  deriving (Eq, Show)

instance NFData PngLimits where
  rnf limits = limits `seq` ()

-- | The largest value any limit may take, 2^31 − 1: the PNG specification's
-- largest dimension, and a value every 'Int' represents. A limit above it,
-- or at or below zero, is refused; there is no sentinel for "unlimited".
largestLimit ∷ Integer
largestLimit = 2 ^ (31 ∷ Int) - 1

-- | Why a set of limits was refused: the first limit, in 'LimitKind' order,
-- that is not between 1 and 'largestLimit'. The reason is fixed text; the
-- offending value is not echoed.
data LimitsRefusal = LimitsRefusal
  { refusedLimit ∷ !LimitKind
  , limitsRefusalReason ∷ !Text
  }
  deriving (Eq, Show)

-- | Validate limits. Each must be an integer from 1 through 'largestLimit'.
pngLimits ∷ PngLimitSettings → Either LimitsRefusal PngLimits
pngLimits settings = case [kind | (kind, value) ← named, value < 1 || value > largestLimit] of
  kind : _ →
    Left
      LimitsRefusal
        { refusedLimit = kind
        , limitsRefusalReason = "the " <> limitName kind <> " limit must be an integer from 1 through " <> Text.pack (show largestLimit)
        }
  [] →
    Right
      PngLimits
        { sourceLimit = narrow (settingSourceBytes settings)
        , chunkLimit = narrow (settingChunks settings)
        , widthLimit = narrow (settingWidth settings)
        , heightLimit = narrow (settingHeight settings)
        , pixelLimit = narrow (settingPixels settings)
        , rgba8Limit = narrow (settingRgba8Bytes settings)
        , inflateLimit = narrow (settingInflatedBytes settings)
        }
  where
    named =
      [ (LimitSourceBytes, settingSourceBytes settings)
      , (LimitChunks, settingChunks settings)
      , (LimitWidth, settingWidth settings)
      , (LimitHeight, settingHeight settings)
      , (LimitPixels, settingPixels settings)
      , (LimitRgba8Bytes, settingRgba8Bytes settings)
      , (LimitInflatedBytes, settingInflatedBytes settings)
      ]
    -- Only reached for values already checked against 'largestLimit'.
    narrow = fromInteger

-- | The limits a 'PngLimits' holds, as settings.
pngLimitSettings ∷ PngLimits → PngLimitSettings
pngLimitSettings limits =
  PngLimitSettings
    { settingSourceBytes = toInteger (sourceLimit limits)
    , settingChunks = toInteger (chunkLimit limits)
    , settingWidth = toInteger (widthLimit limits)
    , settingHeight = toInteger (heightLimit limits)
    , settingPixels = toInteger (pixelLimit limits)
    , settingRgba8Bytes = toInteger (rgba8Limit limits)
    , settingInflatedBytes = toInteger (inflateLimit limits)
    }

-- | The fixed M1 profile (design D-77, P-74): 32 MiB source, 4,096 chunks,
-- each axis 1 through 2,048, 4,194,304 pixels, a 16 MiB RGBA8 output and 40
-- MiB of decompressed scanlines. KiB and MiB are powers of 1024.
m1PngLimits ∷ PngLimits
m1PngLimits =
  PngLimits
    { sourceLimit = 32 * mebi
    , chunkLimit = 4096
    , widthLimit = 2048
    , heightLimit = 2048
    , pixelLimit = 4194304
    , rgba8Limit = 16 * mebi
    , inflateLimit = 40 * mebi
    }
  where
    mebi = 1024 * 1024

limitName ∷ LimitKind → Text
limitName = \case
  LimitSourceBytes → "source byte"
  LimitChunks → "chunk count"
  LimitWidth → "width"
  LimitHeight → "height"
  LimitPixels → "pixel count"
  LimitRgba8Bytes → "RGBA8 byte"
  LimitInflatedBytes → "inflated byte"

-- | Why a PNG was refused: the three content classes a texture provider
-- maps (unsupported format, invalid image, too large).
data PngRefusalClass
  = -- | Not a PNG (empty input and a proper prefix of the signature
    -- included), or an animated PNG.
    UnsupportedFormat
  | -- | Begins with the PNG signature and is not a sound PNG of the profile.
    MalformedPng
  | -- | Sound so far, and over this limit.
    ExceededLimit !LimitKind
  deriving (Eq, Show)

-- | A refusal: the asset, the class, and a bounded reason. The reason is
-- built from fixed text and numbers; it never carries the offending bytes.
data PngRefusal = PngRefusal
  { pngRefusedAsset ∷ !Asset
  , pngRefusalClass ∷ !PngRefusalClass
  , pngRefusalReason ∷ !Text
  }
  deriving (Eq, Show)

instance NFData PngRefusalClass where
  rnf cls = cls `seq` ()

instance NFData PngRefusal where
  rnf refusal = rnf (pngRefusedAsset refusal) `seq` rnf (pngRefusalClass refusal) `seq` rnf (pngRefusalReason refusal)

-- | A PNG that passed 'preflightPng' under the limits it names, with the
-- header information bounded decoding needs. See the module description for
-- what it retains. It cannot be built any other way, so it cannot authorize
-- decoding bytes other than 'preflightSource'.
data PngPreflight = PngPreflight
  { pfAsset ∷ !Asset
  , pfLimits ∷ !PngLimits
  , pfSource ∷ !ByteString
  , pfWidth ∷ !Int
  , pfHeight ∷ !Int
  , pfColour ∷ !PngColourType
  , pfDepth ∷ !Int
  , pfInterlace ∷ !PngInterlace
  , pfScanlineBytes ∷ !Int
  , pfInflatedBytes ∷ !Int
  , pfRgba8Bytes ∷ !Int
  , pfImageData ∷ ![ByteString]
  , pfPalette ∷ !(Maybe ByteString)
  , pfTransparency ∷ ![ByteString]
  , pfColourKey ∷ !(Maybe ColourKey)
  }
  deriving (Eq, Show)

instance NFData PngPreflight where
  rnf pf =
    rnf (pfAsset pf)
      `seq` rnf (pfLimits pf)
      `seq` rnf (pfSource pf)
      `seq` rnf (pfWidth pf)
      `seq` rnf (pfHeight pf)
      `seq` rnf (pfColour pf)
      `seq` rnf (pfDepth pf)
      `seq` rnf (pfInterlace pf)
      `seq` rnf (pfScanlineBytes pf)
      `seq` rnf (pfInflatedBytes pf)
      `seq` rnf (pfRgba8Bytes pf)
      `seq` rnf (pfImageData pf)
      `seq` rnf (pfPalette pf)
      `seq` rnf (pfTransparency pf)
      `seq` rnf (pfColourKey pf)

-- | The asset the preflight is for.
preflightAsset ∷ PngPreflight → Asset
preflightAsset = pfAsset

-- | The limits the bytes were checked against.
preflightLimits ∷ PngPreflight → PngLimits
preflightLimits = pfLimits

-- | The bytes that were checked: the caller's buffer, not a copy.
preflightSource ∷ PngPreflight → ByteString
preflightSource = pfSource

preflightWidth, preflightHeight ∷ PngPreflight → Int
preflightWidth = pfWidth
preflightHeight = pfHeight

preflightColourType ∷ PngPreflight → PngColourType
preflightColourType = pfColour

-- | The header's bit depth: 1, 2, 4, 8 or 16, as its colour type allows.
preflightBitDepth ∷ PngPreflight → Int
preflightBitDepth = pfDepth

preflightInterlace ∷ PngPreflight → PngInterlace
preflightInterlace = pfInterlace

-- | The scanline bytes the header needs, filter bytes included, packed rows
-- rounded up to whole bytes, and for Adam7 each non-empty pass. At most the
-- inflation limit.
preflightScanlineBytes ∷ PngPreflight → Int
preflightScanlineBytes = pfScanlineBytes

-- | The bytes the image data stream inflated to: at least
-- 'preflightScanlineBytes', at most the inflation limit. Counted, not kept.
preflightInflatedBytes ∷ PngPreflight → Int
preflightInflatedBytes = pfInflatedBytes

-- | Width × height × 4: the single RGBA8 output the decoding stage will
-- allocate and account. At most the RGBA8 limit; not allocated here.
preflightRgba8Bytes ∷ PngPreflight → Int
preflightRgba8Bytes = pfRgba8Bytes

-- | The data of every IDAT chunk in file order: the pieces of one zlib
-- stream, slices of 'preflightSource'.
preflightImageData ∷ PngPreflight → [ByteString]
preflightImageData = pfImageData

-- | The first PLTE chunk's data, as the general decoder reads the palette,
-- a slice of 'preflightSource'. Its length and the indices into it are the
-- decoder's to check.
preflightPalette ∷ PngPreflight → Maybe ByteString
preflightPalette = pfPalette

-- | The data of every tRNS chunk in file order, slices of
-- 'preflightSource', for a palette image's alpha table. How many there are,
-- and what a malformed one means, is the decoder's to apply as the general
-- decoder does.
preflightTransparency ∷ PngPreflight → [ByteString]
preflightTransparency = pfTransparency

-- | A greyscale or truecolour image's tRNS colour key, read as the general
-- decoder reads it: exactly one tRNS chunk of the length the colour type
-- takes; otherwise 'Nothing', the chunk being ignored.
preflightColourKey ∷ PngPreflight → Maybe ColourKey
preflightColourKey = pfColourKey

-- | What the scan of a PNG's chunks found.
data Scanned = Scanned
  { scannedHeader ∷ !ByteString
  , scannedImageData ∷ ![ByteString]
  , scannedPalette ∷ !(Maybe ByteString)
  , scannedTransparency ∷ ![ByteString]
  }

-- | Preflight a PNG's bytes under limits, in the order the module
-- description gives. The asset is carried into every refusal and the result.
preflightPng ∷ PngLimits → Asset → ByteString → Either PngRefusal PngPreflight
preflightPng limits asset bytes = strictly $ do
  checkSource
  scanned ← scanChunks limits refuse bytes
  header ← checkHeader refuse (scannedHeader scanned)
  let (w, h, colour, depth, interlace) = header
      scanline = scanlineBytes interlace colour depth w h
  checkGeometry refuse limits w h scanline
  let imageData = scannedImageData scanned
  inflated ← case inflateBounded (inflateLimit limits) imageData of
    Inflated count
      | toInteger count < scanline →
          Left (refuse MalformedPng ("the image data inflates to " <> number count <> " bytes, and the header needs " <> number scanline))
      | otherwise → Right count
    BudgetExceeded → Left (refuse (ExceededLimit LimitInflatedBytes) ("the image data inflates to more than " <> number (inflateLimit limits) <> " bytes"))
    Corrupt corruption → Left (refuse MalformedPng (corruptionReason corruption))
  Right
    PngPreflight
      { pfAsset = asset
      , pfLimits = limits
      , pfSource = bytes
      , pfWidth = fromInteger w
      , pfHeight = fromInteger h
      , pfColour = colour
      , pfDepth = fromIntegral depth
      , pfInterlace = interlace
      , pfScanlineBytes = fromInteger scanline
      , pfInflatedBytes = inflated
      , pfRgba8Bytes = fromInteger (w * h * 4)
      , pfImageData = imageData
      , pfPalette = scannedPalette scanned
      , pfTransparency = scannedTransparency scanned
      , pfColourKey = colourKey (juicyColour colour) (map Lazy.fromStrict (scannedTransparency scanned))
      }
  where
    -- The result is demanded whole: the refusal or the preflight is deeply
    -- evaluated before the 'Either' is returned.
    strictly = either (\refusal → rnf refusal `seq` Left refusal) (\done → rnf done `seq` Right done)
    refuse cls reason = PngRefusal {pngRefusedAsset = asset, pngRefusalClass = cls, pngRefusalReason = reason}
    checkSource
      | ByteString.length bytes > sourceLimit limits =
          Left (refuse (ExceededLimit LimitSourceBytes) ("the source is " <> number (ByteString.length bytes) <> " bytes, over the limit of " <> number (sourceLimit limits)))
      | otherwise = Right ()

-- | The scan: signature, then every chunk in file order to IEND.
scanChunks ∷ PngLimits → (PngRefusalClass → Text → PngRefusal) → ByteString → Either PngRefusal Scanned
scanChunks limits refuse bytes
  | ByteString.null bytes = Left (refuse UnsupportedFormat "the bytes are empty")
  | ByteString.length bytes < ByteString.length signature && bytes `ByteString.isPrefixOf` signature = Left (refuse UnsupportedFormat "the bytes are truncated within the PNG signature")
  | not (signature `ByteString.isPrefixOf` bytes) = Left (refuse UnsupportedFormat "the bytes are not a PNG: they do not begin with the PNG signature")
  | otherwise = go (ByteString.length signature) 0 Nothing [] Nothing []
  where
    signature = ByteString.pack [137, 80, 78, 71, 13, 10, 26, 10]
    total = ByteString.length bytes

    -- offset: the next chunk's first byte; count: chunks accepted so far.
    -- The lists are built in reverse and reversed once, at IEND.
    go ∷ Int → Int → Maybe ByteString → [ByteString] → Maybe ByteString → [ByteString] → Either PngRefusal Scanned
    go !offset !count !header !idat !palette !transparency
      | remaining == 0 = Left (refuse MalformedPng "the PNG has no complete IEND chunk")
      | remaining < 12 = Left (refuse MalformedPng "the PNG is truncated within a chunk's framing")
      | toInteger declared + 12 > toInteger remaining =
          Left (refuse MalformedPng ("a chunk declares " <> number declared <> " data bytes, and the PNG ends before them"))
      | count >= chunkLimit limits =
          Left (refuse (ExceededLimit LimitChunks) ("the PNG has more than " <> number (chunkLimit limits) <> " chunks"))
      | count == 0 && chunkType /= "IHDR" = Left (refuse MalformedPng "the PNG's first chunk is not IHDR")
      | count == 0 && declared /= 13 = Left (refuse MalformedPng "the PNG's IHDR chunk is not 13 bytes long")
      | crcMismatch = Left (refuse MalformedPng ("the " <> chunkName <> " chunk fails its CRC"))
      | chunkType `elem` ["acTL", "fcTL", "fdAT"] =
          Left (refuse UnsupportedFormat ("the PNG is animated: it holds an " <> chunkName <> " chunk"))
      | chunkType == "IEND" =
          case header' of
            Just ihdr → Right Scanned {scannedHeader = ihdr, scannedImageData = reverse idat', scannedPalette = palette', scannedTransparency = reverse transparency'}
            Nothing → Left (refuse MalformedPng "the PNG has no IHDR chunk")
      | otherwise = body `seq` go next (count + 1) header' idat' palette' transparency'
      where
        remaining = total - offset
        declared = word32 offset
        chunkType = slice (offset + 4) 4
        body = slice (offset + 8) (fromIntegral declared)
        next = offset + 12 + fromIntegral declared
        stored = word32 (offset + 8 + fromIntegral declared)
        crcMismatch = pngComputeCrc [Lazy.fromStrict (slice (offset + 4) (4 + fromIntegral declared))] /= stored
        chunkName = nameOf chunkType
        header' = if count == 0 then Just body else header
        idat' = if chunkType == "IDAT" then body : idat else idat
        palette' = if chunkType == "PLTE" && isNothing palette then Just body else palette
        transparency' = if chunkType == "tRNS" then body : transparency else transparency

    slice from count = ByteString.take count (ByteString.drop from bytes)
    word32 at = ByteString.foldl' (\acc byte → (acc `shiftL` 8) .|. fromIntegral byte) (0 ∷ Word32) (slice at 4)

-- | A chunk type for a reason: four ASCII letters as themselves, anything
-- else as a fixed word, so a reason never carries arbitrary bytes.
nameOf ∷ ByteString → Text
nameOf chunkType
  | ByteString.length chunkType == 4 && Char8.all (\c → isAsciiUpper c || isAsciiLower c) chunkType = Text.pack (Char8.unpack chunkType)
  | otherwise = "unnamed"

-- | The header's fields, or the reason it is malformed. Dimensions are
-- 'Integer' until compared with a limit.
checkHeader
  ∷ (PngRefusalClass → Text → PngRefusal)
  → ByteString
  → Either PngRefusal (Integer, Integer, PngColourType, Word8, PngInterlace)
checkHeader refuse ihdr = do
  colour ← maybe (malformed "the PNG's colour type is not one the specification defines") Right (colourTypeOfCode (ByteString.index ihdr 9))
  interlace ← maybe (malformed "the PNG's interlace method is not one the specification defines") Right (interlaceOfCode (ByteString.index ihdr 12))
  validate colour interlace
  where
    malformed ∷ Text → Either PngRefusal a
    malformed = Left . refuse MalformedPng
    w = toInteger (word32At 0)
    h = toInteger (word32At 4)
    depth = ByteString.index ihdr 8
    validate colour interlace
      | w == 0 || h == 0 = malformed "the PNG's width or height is zero"
      | w > largestLimit || h > largestLimit = malformed "the PNG's width or height is above the specification's 2^31 - 1"
      | ByteString.index ihdr 10 /= 0 = malformed "the PNG names an unknown compression method"
      | ByteString.index ihdr 11 /= 0 = malformed "the PNG names an unknown filter method"
      | depth `notElem` allowedDepths colour = malformed ("the PNG's bit depth " <> number depth <> " is not allowed for its colour type")
      | otherwise = Right (w, h, colour, depth, interlace)
    word32At at = ByteString.foldl' (\acc byte → (acc `shiftL` 8) .|. fromIntegral byte) (0 ∷ Word32) (ByteString.take 4 (ByteString.drop at ihdr))

-- | The size-derived limits, in order, on 'Integer' values.
checkGeometry ∷ (PngRefusalClass → Text → PngRefusal) → PngLimits → Integer → Integer → Integer → Either PngRefusal ()
checkGeometry refuse limits w h scanline
  | w > toInteger (widthLimit limits) = exceeded LimitWidth ("the PNG is " <> number w <> " pixels wide, over the limit of " <> number (widthLimit limits))
  | h > toInteger (heightLimit limits) = exceeded LimitHeight ("the PNG is " <> number h <> " pixels high, over the limit of " <> number (heightLimit limits))
  | w * h > toInteger (pixelLimit limits) = exceeded LimitPixels ("the PNG has " <> number (w * h) <> " pixels, over the limit of " <> number (pixelLimit limits))
  | w * h * 4 > toInteger (rgba8Limit limits) = exceeded LimitRgba8Bytes ("the PNG's RGBA8 output would be " <> number (w * h * 4) <> " bytes, over the limit of " <> number (rgba8Limit limits))
  | scanline > toInteger (inflateLimit limits) = exceeded LimitInflatedBytes ("the PNG's header needs " <> number scanline <> " scanline bytes, over the limit of " <> number (inflateLimit limits))
  | otherwise = Right ()
  where
    exceeded kind = Left . refuse (ExceededLimit kind)

corruptionReason ∷ Corruption → Text
corruptionReason = \case
  TruncatedStream → "the image data stream ends before its end marker"
  DictionaryRequiredByStream → "the image data stream requires a preset dictionary"
  DictionaryMismatchInStream → "the image data stream names a preset dictionary"
  MalformedStream → "the image data stream is corrupt"

number ∷ (Show a, Integral a) ⇒ a → Text
number = Text.pack . show . toInteger

juicyColour ∷ PngColourType → PngImageType
juicyColour = \case
  ColourGreyscale → PngGreyscale
  ColourTruecolour → PngTrueColour
  ColourIndexed → PngIndexedColor
  ColourGreyscaleAlpha → PngGreyscaleWithAlpha
  ColourTruecolourAlpha → PngTrueColourWithAlpha
