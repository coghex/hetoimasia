-- | Bounded decoding of a preflighted static PNG into one premultiplied
-- RGBA8 level, with every payload buffer charged to an account before it is
-- allocated.
--
-- This is the M1 Lua texture profile's decoding stage (design D-65, D-77;
-- LFE-15), over 'Hetoimasia.Asset.Image.PngPreflight.preflightPng'. It is
-- opt-in. 'Hetoimasia.Asset.Image.Png.decodePng' and 'pngDecoder' are
-- unchanged, impose none of these limits and still decode through JuicyPixels;
-- so do the KTX2, BC7 and mip entry points. Nothing here imports the Lua
-- engine, its profile, a graphics package, a console or a registry: the
-- limits are those the preflight carries, and the account is a handle the
-- caller passes.
--
-- == What it decodes
--
-- Every variant the preflight accepts: greyscale at 1, 2, 4, 8 and 16 bits,
-- palette at 1, 2, 4 and 8, RGB, greyscale-alpha and RGBA at 8 and 16, each
-- non-interlaced or Adam7. The result is one 'DecodedImage' of the file's
-- width and height with exactly one level: tightly packed RGBA8, top row
-- first, no padding and no mip chain, in 'TexelRgba8Srgb', each colour
-- channel premultiplied once in linear light by its texel's alpha, alpha
-- unchanged. The texel contract is the general decoder's colour-image
-- contract ("Hetoimasia.Asset.Image.Png"), applied by the rasterizer in
-- "Hetoimasia.Asset.Image.Internal.PngRaster". There is no data-image, HDR or
-- colour-profile option, and colour-space chunks never change a texel.
--
-- The bounded path is not a wrapper around JuicyPixels. That decoder inflates
-- a lazy stream, concatenates its chunks, builds a sample vector and then a
-- second image, none of which can be accounted from here, so this module
-- inflates, unfilters and converts its own way:
--
-- 1. the IDAT slices are fed to the zlib inflater as they are, one output
--    piece at a time, and copied into the one working buffer;
-- 2. each scanline is unfiltered where it lies in that buffer;
-- 3. each pixel is written, premultiplied, to its final place in the output.
--
-- There is no sample vector, no pass image, no concatenation of the encoded
-- data and no second copy of anything.
--
-- == The accounting contract
--
-- The decoder is given a 'PayloadAccount' (see there) and charges it for
-- every buffer of its own, /before/ allocating it: a refused charge is a
-- content refusal of class @ExceededLimit LimitWorkspaceBytes@ and nothing is
-- allocated for it. The charges are 'decodeReservations', in this order:
--
-- 1. 'StageOutput': the RGBA8 level, 'preflightRgba8Bytes'. Reserved first
--    and not released on success: it is the result, and it stays charged
--    until its owner disposes of it. Released on every other outcome.
-- 2. 'StageScratch': 'fixedScratchBytes' plus the widest row. Released
--    before the call returns.
-- 3. 'StageWorking': the inflated, filtered scanlines,
--    'preflightScanlineBytes'. Released before the call returns.
--
-- /On success/ the account has gained exactly 'preflightRgba8Bytes' live
-- bytes; /on a refusal or any exception, asynchronous ones included/, it has
-- gained nothing: every grant the call took was released. The caller's own
-- charges are the caller's: the encoded input ('preflightSource') is charged
-- by whoever read it, from before the call until they drop it, and the
-- decoder neither charges nor releases it. 'decodePeakBytes' is the most the
-- bank holds while this decode runs, input included.
--
-- == The hand-over of the output
--
-- The output reservation passes to the caller at the instant the call
-- returns. A caller that can be cancelled asynchronously calls the decoder
-- under 'mask' (or 'mask_'): the decoder's own steps stay cancellable
-- ('Control.Exception.allowInterrupt' runs once per inflater piece and per
-- row, and the account's calls may block), and no exception is delivered
-- between the decoder's return and the caller's recording of the image, so a
-- caller never holds the charge without the image. The caller then owns both
-- until it releases @StageOutput@ with 'preflightRgba8Bytes' once nothing
-- refers to the level. The result is independent of the decoder's scratch,
-- of the preflight, and of the encoded input: it is the level's one buffer,
-- of exactly that length, and nothing else, so dropping the source and the
-- preflight frees them while the level lives. A staging copy of the level
-- (for the GPU provider, LFE-17) is a separate payload the pipeline charges
-- itself, over and above the output, until the copy is retired.
--
-- == Failures
--
-- A refusal is a 'PngRefusal' of one of the preflight's classes, naming the
-- asset, with a bounded fixed-text reason; no partial image comes with it.
-- Beyond what the preflight already established (and this stage repeats,
-- because it reinflates), the refusals are:
--
-- * 'MalformedPng': an image data stream that is corrupt, truncated or
--   inflates to fewer bytes than the header needs; a scanline whose filter
--   type is not 0 to 4; an indexed image without a palette whose length is a
--   multiple of 3; a palette index outside the palette. Each is found by an
--   explicit check, never by catching an exception.
-- * @ExceededLimit LimitInflatedBytes@: the second inflation produced more
--   than the preflight's inflation limit.
-- * @ExceededLimit LimitWorkspaceBytes@: the account refused a charge.
--
-- Anything else is not a refusal. An allocation failure, a fault in the
-- inflater binding or the account, an asynchronous exception, and the
-- failure of a release all propagate as exceptions: a release that fails
-- after a body that failed is retained beside it in a 'PayloadCleanupFailure'
-- (itself asynchronous if the body's failure was). The result is evaluated
-- completely ('rnf') before it is returned, so a late failure surfaces from
-- the call and never from a value already reported as a success.
--
-- == Completion and abandonment
--
-- When the call returns or throws, the decoder has stopped using every
-- buffer it charged: the working buffer, the scratch and the inflater's
-- input (the caller's own slices) are no longer touched, and the account has
-- seen every release. The one thing it may still hold after an abandoned
-- call is the inflater's native state, which the pinned @zlib@ binding frees
-- (see "Hetoimasia.Asset.Image.Internal.PngInflate"); that state is counted in
-- 'fixedScratchBytes' while the call runs and is not counted afterwards,
-- under the exclusions below. A caller must not release the pipeline's
-- workspace, or the encoded input, while a call is in progress: the call
-- returning is the only evidence that it is done, and a cancellation request
-- is not. There is no deadline and no hard interruption: a cancellation is
-- delivered between steps, each of which does at most one inflater piece or
-- one row of work.
--
-- == The live-buffer bound
--
-- Every buffer the decoder allocates or retains, by operation:
--
-- +-----------------------+---------------------------+-------------------------+------------------------------+
-- | Buffer                | Allocated by              | Size                    | Held from → until            |
-- +=======================+===========================+=========================+==============================+
-- | Encoded input         | the caller                | at most the source      | before the call → the        |
-- |                       |                           | limit (32 MiB)          | caller drops it. Shared by   |
-- |                       |                           |                         | the IDAT, PLTE and tRNS      |
-- |                       |                           |                         | slices; never copied         |
-- +-----------------------+---------------------------+-------------------------+------------------------------+
-- | Output level          | 'StageOutput' reservation | width × height × 4,     | reserved first → the caller  |
-- |                       | then @create@             | at most 16 MiB          | disposes of it               |
-- +-----------------------+---------------------------+-------------------------+------------------------------+
-- | Zero row              | @mallocForeignPtrBytes@   | the widest row's packed | scratch granted → call end   |
-- |                       |                           | bytes, at most 16 KiB   |                              |
-- |                       |                           | at 2,048 columns RGBA16 |                              |
-- +-----------------------+---------------------------+-------------------------+------------------------------+
-- | Palette table         | 'makePalette'             | at most 256 × 4 bytes   | scratch granted → call end   |
-- +-----------------------+---------------------------+-------------------------+------------------------------+
-- | Inflater state        | zlib's @inflateInit@      | about 7 KiB of state    | first input → end or failure |
-- |                       | (the binding)             | and a 32 KiB window     | of the stream (see above)    |
-- +-----------------------+---------------------------+-------------------------+------------------------------+
-- | Inflater output piece | the binding, per piece    | at most 32 KiB, and the | produced → copied; at most   |
-- |                       |                           | next is allocated while | two live                     |
-- |                       |                           | this one is copied      |                              |
-- +-----------------------+---------------------------+-------------------------+------------------------------+
-- | Premultiplication     | a process-wide table,     | 64 KiB (built once, in  | first use → process exit;    |
-- | table                 | built in place            | place, no list)         | charged on every call        |
-- +-----------------------+---------------------------+-------------------------+------------------------------+
-- | Scanlines             | 'StageWorking' then       | 'preflightScanlineBytes'| granted → the last row is    |
-- |                       | @mallocForeignPtrBytes@   | (filtered rows,         | written; unfiltered in place |
-- |                       |                           | all passes), at most    |                              |
-- |                       |                           | the inflation limit     |                              |
-- +-----------------------+---------------------------+-------------------------+------------------------------+
--
-- Nothing else of size is allocated: the sample vector, the deinterlaced
-- image, the chunk concatenation and the palette-expanded image of the
-- general decoder do not exist here. The peak is at conversion, when the
-- encoded input, the output, the scratch and the scanlines are all live:
-- @source + output + scratch + scanlines@ ('decodePeakBytes'). At the M1
-- maxima that is, for the largest family (2,048 × 2,048 RGBA16, Adam7, with a
-- 32 MiB source) 32 MiB + 16 MiB + 173,056 B + 16 KiB + 33,558,272 B, about
-- 80.2 MiB, under the 128 MiB bank by 47.8 MiB; the README tabulates every
-- colour type, depth and interlace method. With a staging copy of the output
-- (16 MiB) still owned at hand-over, after the scanlines and scratch are
-- released, the bank holds source + 2 × output at most.
--
-- == What the figures exclude
--
-- Allocator overhead, memory the collector has not yet returned for buffers
-- already unreferenced (the working buffer after its release is garbage, not
-- a live payload), the object graphs of the preflight (its slice descriptors,
-- at most the chunk limit of them, 224 KiB at 4,096) and of the result, and
-- driver or GPU memory. None of them is used to hide a live referenced
-- payload: every buffer above is charged for exactly as long as the decoder
-- or the caller refers to it. This is not a whole-process heap guarantee.
module Hetoimasia.Asset.Image.PngDecode
  ( -- * Decoding
    decodeBounded

    -- * The account
  , PayloadAccount (..)
  , PayloadStage (..)
  , PayloadCleanupFailure (..)

    -- * What a decode charges
  , decodeReservations
  , decodeReservationsFor
  , decodePeakBytes
  , fixedScratchBytes
  , m1WorkspaceBytes
  )
where

import Control.DeepSeq (force)
import Control.Exception (catch, evaluate, throwIO)
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Internal as ByteString (create)
import Data.Text (Text)
import qualified Data.Text as Text
import Foreign.ForeignPtr (mallocForeignPtrBytes, withForeignPtr)
import Foreign.Marshal.Utils (fillBytes)
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (TexelRgba8Srgb))
import Hetoimasia.Asset.Image.Internal.PngGeometry
  ( Pass (passColumns)
  , bitsPerPixel
  , packedRowBytes
  , passesOf
  , scanlineBytes
  )
import Hetoimasia.Asset.Image.Internal.PngInflate (Inflation (..), corruptionReason, inflateInto, outputPieceBytes)
import Hetoimasia.Asset.Image.Internal.PngRaster (Raster (..), makePalette, paletteBytes, rasterize)
import Hetoimasia.Asset.Image.Internal.PngWorkspace
  ( PayloadAccount (..)
  , PayloadCleanupFailure (..)
  , PayloadStage (..)
  , Refusal (..)
  , withCharge
  )
import Hetoimasia.Asset.Image.Internal.Premultiply (tableBytes)
import Hetoimasia.Asset.Image.Internal.Texels (binaryAlpha)
import Hetoimasia.Asset.Image.PngPreflight
  ( LimitKind (LimitInflatedBytes, LimitWorkspaceBytes)
  , PngColourType (ColourIndexed)
  , PngInterlace
  , PngLimitSettings (settingInflatedBytes)
  , PngPreflight
  , PngRefusal (..)
  , PngRefusalClass (ExceededLimit, MalformedPng)
  , pngLimitSettings
  , preflightAsset
  , preflightBitDepth
  , preflightColourKey
  , preflightColourType
  , preflightHeight
  , preflightImageData
  , preflightInterlace
  , preflightLimits
  , preflightPalette
  , preflightSource
  , preflightTransparency
  , preflightWidth
  )

-- | The accounted CPU payload and workspace of one active texture pipeline
-- in the M1 profile: 128 MiB (design D-77, P-74). A bank this size, charged
-- with the encoded input by the caller, holds every M1 decode.
m1WorkspaceBytes ∷ Int
m1WorkspaceBytes = 128 * 1024 * 1024

-- | The scratch every decode charges whatever the image: the inflater's
-- state and window (8 KiB and 32 KiB, rounded up from zlib's 7,116-byte
-- state), two inflater output pieces (the one being copied and the next, 32
-- KiB each), the shared premultiplication table (64 KiB) and the palette
-- table (1 KiB). 173,056 bytes. The all-zero row is added per image.
fixedScratchBytes ∷ Int
fixedScratchBytes = 8 * 1024 + 32 * 1024 + 2 * outputPieceBytes + tableBytes + paletteBytes

-- | What a decode of this preflight charges the account, in the order it
-- reserves: the output, the scratch (fixed scratch plus the widest row of
-- the image's passes) and the inflated scanlines. The decoder reserves exactly
-- these, each before the allocation it covers.
decodeReservations ∷ PngPreflight → [(PayloadStage, Integer)]
decodeReservations pf =
  decodeReservationsFor (preflightColourType pf) (preflightBitDepth pf) (preflightInterlace pf) (toInteger (preflightWidth pf)) (toInteger (preflightHeight pf))

-- | 'decodeReservations' from a header's fields alone, for the figures of an
-- image that is not at hand (the README's table at the M1 maxima). The
-- decoder takes its own reservations from this function.
decodeReservationsFor ∷ PngColourType → Int → PngInterlace → Integer → Integer → [(PayloadStage, Integer)]
decodeReservationsFor colour depth interlace w h =
  [(StageOutput, planOutput plan), (StageScratch, planScratch plan), (StageWorking, planWorking plan)]
  where
    plan = planFor colour depth interlace w h

-- | The most live payload bytes the bank holds while this decode runs: the
-- encoded input the caller has charged, plus every reservation of
-- 'decodeReservations' (they overlap at conversion). A staging copy the
-- pipeline makes after the call is not included.
decodePeakBytes ∷ PngPreflight → Integer
decodePeakBytes pf = toInteger (ByteString.length (preflightSource pf)) + sum (map snd (decodeReservations pf))

-- | The three charges and the zero row they include, as exact sizes.
data Plan = Plan
  { planOutput ∷ !Integer
  , planScratch ∷ !Integer
  , planWorking ∷ !Integer
  , planZeroRow ∷ !Integer
  }

planOf ∷ PngPreflight → Plan
planOf pf = planFor (preflightColourType pf) (preflightBitDepth pf) (preflightInterlace pf) (toInteger (preflightWidth pf)) (toInteger (preflightHeight pf))

planFor ∷ PngColourType → Int → PngInterlace → Integer → Integer → Plan
planFor colour depth interlace w h =
  Plan
    { planOutput = w * h * 4
    , planScratch = toInteger fixedScratchBytes + zeroRow
    , planWorking = scanlineBytes interlace colour (fromIntegral depth) w h
    , planZeroRow = zeroRow
    }
  where
    -- The packed bytes of the widest row among the image's passes, filter
    -- byte excluded; the row above each pass's first.
    zeroRow = maximum (0 : [packedRowBytes bits (passColumns pass) | pass ← passesOf interlace w h])
    bits = bitsPerPixel colour (fromIntegral depth)

-- | Decode a preflighted PNG within the account, as the module description
-- says: a fully evaluated one-level 'DecodedImage' with 'preflightRgba8Bytes'
-- left charged to the account, or a refusal with nothing left charged. Any
-- other failure is an exception with nothing left charged.
decodeBounded ∷ PayloadAccount → PngPreflight → IO (Either PngRefusal DecodedImage)
decodeBounded account pf =
  -- A success is already evaluated, inside the scope that holds its output's
  -- charge, so nothing is forced after the hand-over; a refusal holds no
  -- charge and is forced here.
  (Right <$> decodeOrRefuse account pf) `catch` \(Refusal cls reason) → evaluate (force (Left (refusal cls reason)))
  where
    refusal cls reason = PngRefusal {pngRefusedAsset = preflightAsset pf, pngRefusalClass = cls, pngRefusalReason = reason}

decodeOrRefuse ∷ PayloadAccount → PngPreflight → IO DecodedImage
decodeOrRefuse account pf = do
  palette ← paletteData
  outputBytes ← narrowReservation (planOutput plan)
  scratchBytes ← narrowReservation (planScratch plan)
  workingBytes ← narrowReservation (planWorking plan)
  let zeroBytes = max 1 (fromInteger (planZeroRow plan)) ∷ Int
  withCharge True account StageOutput outputBytes $
    withCharge False account StageScratch scratchBytes $ do
      zeroRow ← mallocForeignPtrBytes zeroBytes
      withForeignPtr zeroRow $ \pointer → fillBytes pointer 0 zeroBytes
      table ← traverse (uncurry makePalette) palette
      withCharge False account StageWorking workingBytes $ do
        scanlines ← mallocForeignPtrBytes workingBytes
        inflated ← withForeignPtr scanlines $ \pointer →
          inflateInto inflateLimit pointer workingBytes (preflightImageData pf)
        case inflated of
          Inflated count
            | count < workingBytes →
                refuse MalformedPng ("the image data inflates to " <> tshow count <> " bytes, and the header needs " <> tshow workingBytes)
            | otherwise → pure ()
          BudgetExceeded → refuse (ExceededLimit LimitInflatedBytes) ("the image data inflates to more than " <> tshow inflateLimit <> " bytes")
          Corrupt corruption → refuse MalformedPng (corruptionReason corruption)
        let raster =
              Raster
                { rasterColour = preflightColourType pf
                , rasterDepth = fromIntegral (preflightBitDepth pf)
                , rasterInterlace = preflightInterlace pf
                , rasterWidth = preflightWidth pf
                , rasterHeight = preflightHeight pf
                , rasterKey = preflightColourKey pf
                , rasterPalette = table
                }
        level ← ByteString.create outputBytes $ \out → do
          fillBytes out 0 outputBytes
          withForeignPtr scanlines $ \source →
            withForeignPtr zeroRow $ \zeros →
              rasterize raster source workingBytes zeros zeroBytes out outputBytes
        evaluate . force $
          DecodedImage
            { decodedFormat = TexelRgba8Srgb
            , decodedWidth = fromIntegral (preflightWidth pf)
            , decodedHeight = fromIntegral (preflightHeight pf)
            , decodedLevels = [level]
            , decodedBinaryAlpha = binaryAlpha level
            }
  where
    plan = planOf pf
    inflateLimit = fromInteger (settingInflatedBytes (pngLimitSettings (preflightLimits pf))) ∷ Int

    -- An indexed image needs a palette JuicyPixels would accept: the first
    -- PLTE chunk, a whole number of entries long.
    paletteData ∷ IO (Maybe (ByteString, [ByteString]))
    paletteData
      | preflightColourType pf /= ColourIndexed = pure Nothing
      | otherwise = case preflightPalette pf of
          Just plte | ByteString.length plte `mod` 3 == 0 → pure (Just (plte, preflightTransparency pf))
          Just _ → refuse MalformedPng "the PNG's palette is not a whole number of three-byte entries"
          Nothing → refuse MalformedPng "the PNG is indexed and has no palette"

    narrowReservation ∷ Integer → IO Int
    narrowReservation bytes = do
      when (bytes > toInteger (maxBound ∷ Int)) $
        refuse (ExceededLimit LimitWorkspaceBytes) ("a buffer of " <> tshow bytes <> " bytes is larger than this machine can address")
      pure (fromInteger bytes)

refuse ∷ PngRefusalClass → Text → IO a
refuse cls reason = throwIO (Refusal cls reason)

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
