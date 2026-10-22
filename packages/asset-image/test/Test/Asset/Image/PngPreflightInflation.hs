-- | The bounded PNG preflight's inflation: that the budget stops the real
-- inflater, not a count made afterwards; that IDAT chunk boundaries change
-- nothing; what a result retains; and that faults and asynchronous
-- exceptions are not content refusals.
--
-- __How incremental stopping is shown.__ The suite reaches the preflight only
-- through its public entry, so it controls what the inflater would find
-- /after/ the budget point instead of instrumenting it. A stream is built so
-- that, past the budget by more than one inflater output piece (the pieces
-- are at most 32 KiB), the bytes are a deliberately corrupt deflate
-- continuation: a reserved block type written by hand
-- ('Test.Asset.Image.PngBuilder.invalidBlock'). A preflight that inflated
-- the whole stream before it counted would report the corruption; one that
-- stops at the budget reports the budget. The same stream with the budget
-- beyond the corruption reports it. A final length assertion, a count
-- after inflation, or a compressed-size limit would not tell these apart.
module Test.Asset.Image.PngPreflightInflation (spec) where

import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, readMVar, takeMVar, throwTo, tryPutMVar)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), SomeAsyncException, evaluate, fromException, try)
import Control.Monad (forM, forM_, replicateM_, void)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Internal as ByteString (toForeignPtr)
import qualified Data.ByteString.Lazy as Lazy
import Data.List (nub)
import Data.Maybe (isJust)
import Data.Word (Word8)
import Foreign.ForeignPtr (ForeignPtr)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import Foreign.Ptr (plusPtr)
import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (..))
import Hetoimasia.Asset.Image.PngPreflight
import System.IO.Unsafe (unsafePerformIO)
import Test.Asset.Image.PngBuilder
import Test.Asset.Image.PreflightSupport
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "PngPreflight inflation and ownership" $ do
  budgetSpec
  stopsSpec
  boundariesSpec
  corruptionSpec
  ownershipSpec
  faultSpec

-- | A 1 × 1 greyscale image needs two scanline bytes, so every stream below
-- is far past what the header wants: only the budget bounds it.
tiny ∷ Header
tiny = header 1 1 8 0

withInflateLimit ∷ Integer → PngLimits
withInflateLimit n = limitsWith (\s → s {settingInflatedBytes = n})

mebi ∷ Int
mebi = 1024 * 1024

budgetSpec ∷ Spec
budgetSpec = describe "the inflation budget" $ do
  it "stops highly compressible excess image data at the budget, wherever the budget falls in an output piece, however the data is split" $ do
    -- 1 MiB of zeros in about a kilobyte of stream.
    let stream = zlibOf (zeros mebi)
    ByteString.length stream `shouldSatisfy` (< 2048)
    forM_ [0, 1, 7, 100000] $ \size →
      forM_ [2, 100, 32767, 32768, 32769, 40000, 65535, 65536, 65537, 1000000, toInteger mebi - 1] $ \limit →
        preflightUnder (withInflateLimit limit) (assemble ([ihdrChunk tiny] <> idatChunks size stream <> [chunk "IEND" ""]))
          >>= (`shouldBeRefusedAs` ExceededLimit LimitInflatedBytes)

  it "accepts the same stream at exactly its length, and counts it" $
    forM_ [0, 1, 7] $ \size → do
      result ← preflightUnder (withInflateLimit (toInteger mebi)) (assemble ([ihdrChunk tiny] <> idatChunks size (zlibOf (zeros mebi)) <> [chunk "IEND" ""]))
      acceptedWith result $ \accepted → do
        preflightInflatedBytes accepted `shouldBe` mebi
        preflightScanlineBytes accepted `shouldBe` 2

  it "bounds a tiny declared image independently of the header's expected size, at the M1 value" $ do
    -- 41 MiB of zeros against the 40 MiB budget, declared as one pixel.
    result ← preflight (assemble [ihdrChunk tiny, chunk "IDAT" (zlibOf (zeros (41 * mebi))), chunk "IEND" ""])
    result `shouldBeRefusedAs` ExceededLimit LimitInflatedBytes
    preflight (assemble [ihdrChunk tiny, chunk "IDAT" (zlibOf (zeros (40 * mebi))), chunk "IEND" ""]) >>= shouldBeAccepted >>= \_ → pure ()

stopsSpec ∷ Spec
stopsSpec = describe "the remaining stream is not inflated" $ do
  -- Two stored blocks of 65,535 zero bytes, then a reserved block type.
  -- The invalid block lies 131,070 bytes into the output.
  let stream = storedStream [65535, 65535] invalidBlock

  it "reports the budget, not the corruption beyond it, for a budget more than one piece short of it" $
    forM_ [0, 100, 4096, 70000] $ \size →
      forM_ [2, 1000, 32768, 40000, 70000, 98000] $ \limit →
        preflightUnder (withInflateLimit limit) (assemble ([ihdrChunk tiny] <> idatChunks size stream <> [chunk "IEND" ""]))
          >>= (`shouldBeRefusedAs` ExceededLimit LimitInflatedBytes)

  it "reports the corruption when the budget is beyond it: the control that the stream is corrupt" $
    forM_ [0, 100, 4096, 70000] $ \size →
      forM_ [131070, 131071, 200000, toInteger (40 * mebi)] $ \limit →
        preflightUnder (withInflateLimit limit) (assemble ([ihdrChunk tiny] <> idatChunks size stream <> [chunk "IEND" ""]))
          >>= (`shouldBeRefusedAs` MalformedPng)

  it "does not read an IDAT chunk's data past the budget either: a corrupt later chunk is not reached" $ do
    -- The first IDAT chunk holds the stored header and the first block
    -- whole; the second holds the invalid block.
    let (first, rest) = ByteString.splitAt (2 + 5 + 65535 + 5 + 65535) stream
    preflightUnder (withInflateLimit 40000) (assemble [ihdrChunk tiny, chunk "IDAT" first, chunk "IDAT" rest, chunk "IEND" ""])
      >>= (`shouldBeRefusedAs` ExceededLimit LimitInflatedBytes)
    preflightUnder (withInflateLimit (toInteger (40 * mebi))) (assemble [ihdrChunk tiny, chunk "IDAT" first, chunk "IDAT" rest, chunk "IEND" ""])
      >>= (`shouldBeRefusedAs` MalformedPng)

boundariesSpec ∷ Spec
boundariesSpec = describe "IDAT chunk boundaries" $ do
  let rows = ByteString.concat [ByteString.pack (0 : [fromIntegral (x * 7 + y * 31) | x ← [0 .. 8]]) | y ← [0 .. 2 ∷ Int]] -- 3 × 3 RGB8: 3 × (1 + 9)
      image = header 3 3 8 2
      stream = zlibOf (Lazy.fromStrict rows)

  it "do not change the answer, the counts or the header information" $ do
    results ← forM [0, 1, 2, 3, 5, 7, 11, 1000] $ \size → do
      result ← preflight (assemble ([ihdrChunk image] <> idatChunks size stream <> [chunk "IEND" ""]))
      shouldBeAccepted result
    nub [(preflightWidth r, preflightHeight r, preflightScanlineBytes r, preflightInflatedBytes r) | r ← results] `shouldBe` [(3, 3, 30, 30)]
    forM_ results $ \r → ByteString.concat (preflightImageData r) `shouldBe` stream

  it "do not change the answer when empty IDAT chunks are interleaved" $ do
    let pieces = splitEvery 4 stream
        withEmpties = concatMap (\piece → [chunk "IDAT" "", chunk "IDAT" piece]) pieces
    result ← preflight (assemble ([ihdrChunk image] <> withEmpties <> [chunk "IEND" ""])) >>= shouldBeAccepted
    preflightInflatedBytes result `shouldBe` 30
    ByteString.concat (preflightImageData result) `shouldBe` stream

  it "do not change a refusal's class either" $
    forM_ [0, 1, 3, 1000] $ \size → do
      preflightUnder (withInflateLimit 29) (assemble ([ihdrChunk image] <> idatChunks size stream <> [chunk "IEND" ""]))
        >>= (`shouldBeRefusedAs` ExceededLimit LimitInflatedBytes)
      preflight (assemble ([ihdrChunk image] <> idatChunks size (ByteString.take (ByteString.length stream - 3) stream) <> [chunk "IEND" ""]))
        >>= (`shouldBeRefusedAs` MalformedPng)

corruptionSpec ∷ Spec
corruptionSpec = describe "streams that are corrupt or short within the budget" $ do
  let image = header 3 3 8 2
      good = zlibOf (Lazy.fromStrict (ByteString.replicate 30 0))
      withStream stream = assemble [ihdrChunk image, chunk "IDAT" stream, chunk "IEND" ""]

  it "refuse a corrupt stream as malformed" $ do
    preflight (withStream good) >>= shouldBeAccepted >>= \_ → pure ()
    -- Flipped checksum, truncated stream, damaged header, not a stream at all.
    preflight (withStream (ByteString.init good <> ByteString.singleton (ByteString.last good + 1))) >>= (`shouldBeRefusedAs` MalformedPng)
    preflight (withStream (ByteString.take (ByteString.length good - 4) good)) >>= (`shouldBeRefusedAs` MalformedPng)
    preflight (withStream (ByteString.pack [0x00, 0x01] <> ByteString.drop 2 good)) >>= (`shouldBeRefusedAs` MalformedPng)
    preflight (withStream (ByteString.pack [1 .. 40])) >>= (`shouldBeRefusedAs` MalformedPng)

  it "refuse a missing or empty image data stream as malformed" $ do
    preflight (assemble [ihdrChunk image, chunk "IEND" ""]) >>= (`shouldBeRefusedAs` MalformedPng)
    preflight (assemble [ihdrChunk image, chunk "IDAT" "", chunk "IEND" ""]) >>= (`shouldBeRefusedAs` MalformedPng)

  it "refuse a stream that inflates to fewer bytes than the header needs as malformed" $
    forM_ [0, 1, 29] $ \count →
      preflight (withStream (zlibOf (Lazy.fromStrict (ByteString.replicate count 0)))) >>= (`shouldBeRefusedAs` MalformedPng)

  it "accept a stream that inflates to more bytes than the header needs, within the budget, as the general decoder does" $ do
    result ← preflight (withStream (zlibOf (Lazy.fromStrict (ByteString.replicate 31 0)))) >>= shouldBeAccepted
    preflightInflatedBytes result `shouldBe` 31

  it "checks the source, chunk and header limits before it inflates anything" $ do
    -- The image data is not a stream at all: reaching it would be malformed.
    let garbage = assemble [ihdrChunk image, chunk "IDAT" (ByteString.pack [1 .. 40]), chunk "IEND" ""]
    preflightUnder (limitsWith (\s → s {settingSourceBytes = 50})) garbage >>= (`shouldBeRefusedAs` ExceededLimit LimitSourceBytes)
    preflightUnder (limitsWith (\s → s {settingChunks = 2})) garbage >>= (`shouldBeRefusedAs` ExceededLimit LimitChunks)
    preflightUnder (limitsWith (\s → s {settingWidth = 2})) garbage >>= (`shouldBeRefusedAs` ExceededLimit LimitWidth)
    preflightUnder (limitsWith (\s → s {settingHeight = 2})) garbage >>= (`shouldBeRefusedAs` ExceededLimit LimitHeight)
    preflightUnder (limitsWith (\s → s {settingPixels = 8})) garbage >>= (`shouldBeRefusedAs` ExceededLimit LimitPixels)
    preflightUnder (limitsWith (\s → s {settingRgba8Bytes = 35})) garbage >>= (`shouldBeRefusedAs` ExceededLimit LimitRgba8Bytes)
    preflightUnder (limitsWith (\s → s {settingInflatedBytes = 29})) garbage >>= (`shouldBeRefusedAs` ExceededLimit LimitInflatedBytes)
    preflight garbage >>= (`shouldBeRefusedAs` MalformedPng)

ownershipSpec ∷ Spec
ownershipSpec = describe "ownership and evaluation" $ do
  let image = header 3 3 8 2
      stream = zlibOf (Lazy.fromStrict (ByteString.replicate 30 0))
      png = assemble [ihdrChunk image, chunk "PLTE" (ByteString.replicate 6 1), chunk "tRNS" "\1", chunk "IDAT" stream, chunk "IEND" ""]

  it "returns values that are completely evaluated and equal each time, success and refusal alike" $ do
    -- 'preflight' forces its result with its NFData instance: a suspended
    -- computation, inflater state or output left in it would run, or fail,
    -- here and not later in the caller.
    first ← preflight png
    refused ← preflight (assemble [ihdrChunk image, chunk "IDAT" (ByteString.pack [1 .. 40]), chunk "IEND" ""])
    replicateM_ 200 $ do
      again ← preflight png
      again `shouldBe` first
      other ← preflight (assemble [ihdrChunk image, chunk "IDAT" (ByteString.pack [1 .. 40]), chunk "IEND" ""])
      other `shouldBe` refused
    refused `shouldBeRefusedAs` MalformedPng

  it "retains the caller's bytes and slices of them, not copies, and nothing inflated" $ do
    accepted ← preflight png >>= shouldBeAccepted
    preflightSource accepted `shouldBe` png
    sameBuffer (preflightSource accepted) png `shouldBe` True
    forM_ (preflightImageData accepted <> preflightTransparency accepted <> maybe [] pure (preflightPalette accepted)) $ \slice →
      insideBuffer slice png `shouldBe` True
    preflightLimits accepted `shouldBe` m1PngLimits
    preflightAsset accepted `shouldBe` asset
    -- Only the count of the inflated bytes is kept.
    preflightInflatedBytes accepted `shouldBe` 30

  it "keeps at most one retained slice per counted chunk" $ do
    let many = assemble ([ihdrChunk image] <> replicate 4100 (chunk "tRNS" "\1") <> idatChunks 1 stream <> [chunk "IEND" ""])
    preflight many >>= (`shouldBeRefusedAs` ExceededLimit LimitChunks)
    let fits = assemble ([ihdrChunk image] <> replicate 3000 (chunk "tRNS" "\1") <> idatChunks 100 stream <> [chunk "IEND" ""])
    accepted ← preflight fits >>= shouldBeAccepted
    length (preflightTransparency accepted) + length (preflightImageData accepted) `shouldSatisfy` (<= 4096 - 2)

  it "gives the same answer for an equal copy of the bytes, and for different bytes, its own" $ do
    copy ← preflight (ByteString.copy png)
    original ← preflight png
    fmap (\r → (preflightWidth r, preflightInflatedBytes r)) copy `shouldBe` fmap (\r → (preflightWidth r, preflightInflatedBytes r)) original
    fmap preflightSource copy `shouldBe` Right (ByteString.copy png)
  where
    sameBuffer a b = base a == base b
    base bytes = let (fp, offset, _) = ByteString.toForeignPtr bytes in (fp ∷ ForeignPtr Word8, offset)
    insideBuffer slice whole =
      let (sliceFp, sliceOffset, sliceLength) = ByteString.toForeignPtr slice
          (wholeFp, wholeOffset, wholeLength) = ByteString.toForeignPtr whole
          start = unsafeForeignPtrToPtr sliceFp `plusPtr` sliceOffset
          origin = unsafeForeignPtrToPtr wholeFp `plusPtr` wholeOffset
       in sliceLength == 0 || (start >= origin && start `plusPtr` sliceLength <= origin `plusPtr` wholeLength)

-- Faults are not content refusals.
faultSpec ∷ Spec
faultSpec = describe "faults and asynchronous exceptions" $ do
  let image = header 1 1 8 0
      valid = imagePng image 2

  it "propagates a fault raised while the result is built, on every outcome, instead of turning it into a refusal" $ do
    let faulty = Asset (AssetId (error "the example's fault")) (FromMemory "fault")
    forM_ [valid, "not a PNG", assemble [ihdrChunk image, chunk "IDAT" (ByteString.pack [1 .. 9]), chunk "IEND" ""]] $ \bytes → do
      outcome ← try (evaluate (preflightPng m1PngLimits faulty bytes))
      case outcome of
        Left (ErrorCall message) → message `shouldBe` "the example's fault"
        Right _ → expectationFailure "the fault was absorbed into a result"

  it "lets an asynchronous exception through, neither answered nor cached, and resumes to the normal answer" $ do
    entered ← newEmptyMVar
    gate ← newEmptyMVar
    finished ← newEmptyMVar
    let blocked = unsafePerformIO (tryPutMVar entered () >> readMVar gate >> pure "gated")
        gated = Asset (AssetId blocked) (FromMemory "gated")
        answer = preflightPng m1PngLimits gated "not a PNG"
    -- The child announces itself too once it has an answer, so a library that
    -- never blocks here fails the example instead of hanging it.
    child ← forkFinally (evaluate answer >> void (tryPutMVar entered ())) (putMVar finished)
    takeMVar entered
    throwTo child ThreadKilled
    outcome ← takeMVar finished
    case outcome of
      Left failure → (fromException failure ∷ Maybe SomeAsyncException) `shouldSatisfy` isJust
      Right _ → expectationFailure "an asynchronous exception became a result"
    -- The same value, demanded again once the gate opens, is the normal
    -- refusal: the interrupted evaluation was resumed, not cached as an answer.
    putMVar gate ()
    answer `shouldBeRefusedAs'` UnsupportedFormat
  where
    shouldBeRefusedAs' result expected = case result of
      Left refusal → pngRefusalClass refusal `shouldBe` expected
      Right _ → expectationFailure "expected a refusal"
