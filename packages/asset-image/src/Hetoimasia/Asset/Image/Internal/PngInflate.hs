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
module Hetoimasia.Asset.Image.Internal.PngInflate
  ( Inflation (..)
  , Corruption (..)
  , inflateBounded
  , outputPieceBytes
  )
where

import Codec.Compression.Zlib.Internal
  ( DecompressError (..)
  , DecompressParams (decompressBufferSize)
  , decompressST
  , defaultDecompressParams
  , foldDecompressStreamWithInput
  , zlibFormat
  )
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy

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
    (\failure _ → Corrupt (corruption failure))
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

    corruption = \case
      TruncatedInput → TruncatedStream
      DictionaryRequired → DictionaryRequiredByStream
      DictionaryMismatch → DictionaryMismatchInStream
      DataFormatError _ → MalformedStream
