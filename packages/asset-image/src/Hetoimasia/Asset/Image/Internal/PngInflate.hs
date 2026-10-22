-- | Inflation of a PNG's image data under a byte budget.
--
-- The zlib binding's decompression stream runs in the /lazy/ 'ST' monad, so
-- 'foldDecompressStreamWithInput' produces its output piece by piece, on
-- demand: it hands the function it is given each piece together with a
-- continuation that, only if it is demanded, asks the inflater for the next
-- one. The earlier unbounded check demanded every continuation and counted
-- afterwards. Here the function counts each piece the moment the inflater
-- produces it, and the piece that crosses the budget answers
-- 'BudgetExceeded' without demanding its continuation: the remaining stream
-- is never inflated, and the count is never held in a thunk.
--
-- __Scratch and state.__ The inflater's native state is created by the
-- pinned @zlib@ binding when the first input is supplied, and is freed by the
-- binding itself: when the stream ends or fails, or, if the fold stops
-- early, by the binding's @inflateEnd@ finalizer on the foreign pointer once
-- the abandoned continuation is unreachable. This module holds neither. Each
-- output piece is a strict 'ByteString' of at most 'outputPieceBytes' (the
-- first) or the binding's default of 32 KiB less a chunk header (every later
-- one); it is counted and dropped, never concatenated or kept. The input is
-- the caller's list of strict chunks, handed over as they are.
--
-- 'inflateInto' is the same bounded inflation run in 'IO' into a buffer the
-- caller has already accounted for (see below).
module Hetoimasia.Asset.Image.Internal.PngInflate
  ( Inflation (..)
  , Corruption (..)
  , corruptionReason
  , inflateBounded
  , inflateInto
  , outputPieceBytes
  )
where

import Codec.Compression.Zlib.Internal
  ( DecompressError (..)
  , DecompressParams (decompressBufferSize)
  , DecompressStream (..)
  , decompressIO
  , decompressST
  , defaultDecompressParams
  , foldDecompressStreamWithInput
  , zlibFormat
  )
import Control.Exception (allowInterrupt, mask_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.ByteString.Unsafe as ByteString
import Data.Text (Text)
import Data.Word (Word8)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)

-- | How a stream that did not inflate failed. The zlib binding's message is
-- not kept: these four are everything a caller can act on, and each has a
-- fixed text.
data Corruption
  = TruncatedStream
  | DictionaryRequiredByStream
  | DictionaryMismatchInStream
  | MalformedStream
  deriving (Eq, Show)

-- | The result of inflating under a budget.
data Inflation
  = -- | The stream ended, having produced exactly this many bytes, within the
    -- budget.
    Inflated !Int
  | -- | The stream produced more than the budget. Nothing past the piece that
    -- crossed it was inflated.
    BudgetExceeded
  | -- | The stream is truncated or corrupt, within the budget.
    Corrupt !Corruption
  deriving (Eq, Show)

-- | The size of the inflater's first output piece, and so the most one call
-- of the inflater produces before this module counts it. Later pieces use the
-- binding's default, which is not larger.
outputPieceBytes ∷ Int
outputPieceBytes = 32 * 1024

-- | Inflate a zlib stream, given as its chunks in order, and count its
-- output against a budget of @limit@ bytes. The count is an 'Integer'
-- comparison, so no budget up to 'maxBound' of 'Int' can make it wrap. Bytes
-- following the stream's end are ignored, as the unbounded check ignored them.
inflateBounded ∷ Int → [ByteString] → Inflation
inflateBounded limit input =
  foldDecompressStreamWithInput
    count
    (\_ counted → Inflated counted)
    (\failure _ → Corrupt (corruptionOf failure))
    (decompressST zlibFormat params)
    (Lazy.fromChunks input)
    0
  where
    params = defaultDecompressParams {decompressBufferSize = outputPieceBytes}

    -- The continuation is demanded only when this piece is within budget.
    count piece continue counted
      | total > toInteger limit = BudgetExceeded
      | otherwise = continue $! fromInteger total
      where
        total = toInteger counted + toInteger (ByteString.length piece)

-- | The fixed text for a corruption, for a refusal's reason.
corruptionReason ∷ Corruption → Text
corruptionReason = \case
  TruncatedStream → "the image data stream ends before its end marker"
  DictionaryRequiredByStream → "the image data stream requires a preset dictionary"
  DictionaryMismatchInStream → "the image data stream names a preset dictionary"
  MalformedStream → "the image data stream is corrupt"

-- | Inflate a zlib stream, given as its chunks in order, into the first
-- @capacity@ bytes at @target@, and count its whole output against a budget
-- of @limit@ bytes exactly as 'inflateBounded' does. Output beyond
-- @capacity@ is counted and dropped, never stored, so what follows the bytes
-- the caller needs is held to the same budget and the same corruption check
-- as the preflight held it. The count returned is of everything inflated;
-- the caller compares it with @capacity@.
--
-- The caller owns @target@, which must be writable for @capacity@ bytes for
-- the whole call. Nothing else is allocated here that is not scratch: this
-- function copies each output piece, at most 'outputPieceBytes', out of the
-- binding's buffer and drops it. No IDAT chunk is copied or concatenated: each
-- non-empty chunk is handed over as it is (an empty IDAT chunk is not a
-- zlib end marker, so it is skipped).
--
-- __Native state and cancellation.__ Every step of the binding runs under
-- 'mask_', so an asynchronous exception cannot arrive between the binding's
-- creation of the inflater and its registration of the finalizer that frees
-- it; each step does at most one output piece of work, and the exception is
-- delivered between steps. A stream that ends or fails frees its state
-- itself; a stream this function abandons (the budget, an exception) is freed
-- by the binding's foreign-pointer finalizer once unreachable, which is the
-- only point at which that state is returned, and which this package does not
-- time.
inflateInto ∷ Int → Ptr Word8 → Int → [ByteString] → IO Inflation
inflateInto limit target capacity input = step (decompressIO zlibFormat params) (filter (not . ByteString.null) input) False 0
  where
    params = defaultDecompressParams {decompressBufferSize = outputPieceBytes}

    -- @finished@: the end-of-input empty chunk has been supplied.
    step ∷ DecompressStream IO → [ByteString] → Bool → Int → IO Inflation
    step stream chunks finished !total = case stream of
      DecompressInputRequired supply → case chunks of
        chunk : rest → mask_ (supply chunk) >>= \next → step next rest False total
        []
          | finished → pure (Corrupt TruncatedStream)
          | otherwise → mask_ (supply ByteString.empty) >>= \next → step next [] True total
      DecompressOutputAvailable piece more
        | produced > toInteger limit → pure BudgetExceeded
        | otherwise → do
            allowInterrupt
            ByteString.unsafeUseAsCStringLen piece $ \(source, size) →
              copyBytes (target `plusPtr` total) (castPtr source) (max 0 (min size (capacity - total)))
            next ← mask_ more
            step next chunks finished (fromInteger produced)
        where
          produced = toInteger total + toInteger (ByteString.length piece)
      DecompressStreamEnd _ → pure (Inflated total)
      DecompressStreamError failure → pure (Corrupt (corruptionOf failure))

corruptionOf ∷ DecompressError → Corruption
corruptionOf = \case
  TruncatedInput → TruncatedStream
  DictionaryRequired → DictionaryRequiredByStream
  DictionaryMismatch → DictionaryMismatchInStream
  DataFormatError _ → MalformedStream
