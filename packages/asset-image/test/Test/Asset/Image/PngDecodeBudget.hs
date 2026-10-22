-- | The bounded decoder's accounting: what it charges and when, that the
-- charges are the live buffers and not a model beside them, and that every
-- outcome (success, refusal, fault, cancellation) leaves the bank as the
-- contract says.
--
-- The charges are observed at the account, where the production code makes
-- them, in the order it makes them and before the allocation each covers; the
-- peak is the whole bank's, with the caller's own charges (the encoded input
-- and a staging copy) made through the same ledger. The expected sizes are
-- counted here pixel by pixel from the Adam7 pattern
-- ('Test.Asset.Image.PngBuilder.expectedScanlineBytes') and from the header,
-- not taken from the module under test. The bytes the thread allocated while
-- it decoded are measured against what was charged, so a copy the account
-- never saw shows.
module Test.Asset.Image.PngDecodeBudget (spec) where

import Control.Concurrent (ThreadId, forkFinally, killThread, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ErrorCall (ErrorCall)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask_
  , throwIO
  , throwTo
  , toException
  , try
  , uninterruptibleMask_
  )
import Control.Monad (forM_, void, when)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Internal as ByteString (toForeignPtr)
import Data.List (isInfixOf)
import Data.Maybe (isJust)
import Data.Word (Word8)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import Foreign.Ptr (plusPtr)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked, ThreadFinished), threadStatus)
import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.Asset.Image.PngDecode
import Hetoimasia.Asset.Image.PngPreflight
import System.Mem (performMajorGC)
import System.Mem.Weak (deRefWeak, mkWeakPtr)
import Test.Asset.Image.DecodeSupport
import Test.Asset.Image.Fixtures (Expected (..), expectedFixtures)
import Test.Asset.Image.PayloadLedger
import Test.Asset.Image.PngBuilder
import Test.Asset.Image.Support (fixtureBytes)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "PngDecodeBudget" $ do
  modelSpec
  familySpec
  maximaSpec
  capacitySpec
  faultSpec
  cancellationSpec
  handoffSpec
  retentionSpec

mebi ∷ Int
mebi = 1024 * 1024

-- | A preflight of a generated PNG whose scanlines are all zero.
zeroImage ∷ Header → IO (ByteStringAndPreflight)
zeroImage hdr = do
  let colour = hColour hdr
      scanlines = expectedScanlineBytes (hInterlace hdr == 1) colour (fromIntegral (hDepth hdr)) (fromIntegral (hWidth hdr)) (fromIntegral (hHeight hdr))
      extras = [chunk "PLTE" (ByteString.replicate 768 0) | colour == 3]
      bytes = imagePngWith extras hdr scanlines 0
  case preflightPng m1PngLimits decodeAsset bytes of
    Right accepted → pure (bytes, accepted)
    Left refusal → expectationFailure ("the generated image was refused: " <> show refusal) >> fail "refused"

type ByteStringAndPreflight = (ByteString.ByteString, PngPreflight)

colourCode ∷ PngColourType → Word8
colourCode = \case
  ColourGreyscale → 0
  ColourTruecolour → 2
  ColourIndexed → 3
  ColourGreyscaleAlpha → 4
  ColourTruecolourAlpha → 6

-- | The packed bytes of the widest row among the passes, counted from the
-- Adam7 pattern pixel by pixel.
independentWidest ∷ Bool → Int → Int → Int → Int
independentWidest interlaced bits w h = maximum (0 : [(columns * bits + 7) `div` 8 | (columns, rows) ← passes, columns > 0, rows > 0])
  where
    passes
      | interlaced = [(length (filter columnOf [0 .. w - 1]), length (filter rowOf [0 .. h - 1])) | (columnOf, rowOf) ← adam7]
      | otherwise = [(w, h)]
    adam7 =
      [ (\x → x `mod` 8 == 0, \y → y `mod` 8 == 0)
      , (\x → x `mod` 8 == 4, \y → y `mod` 8 == 0)
      , (\x → x `mod` 4 == 0, \y → y `mod` 8 == 4)
      , (\x → x `mod` 4 == 2, \y → y `mod` 4 == 0)
      , (\x → x `mod` 2 == 0, \y → y `mod` 4 == 2)
      , (\x → x `mod` 2 == 1, \y → y `mod` 2 == 0)
      , (const True, \y → y `mod` 2 == 1)
      ]

samplesOf ∷ PngColourType → Int
samplesOf = \case
  ColourTruecolour → 3
  ColourGreyscaleAlpha → 2
  ColourTruecolourAlpha → 4
  _ → 1

-- | The three charges, counted independently of the module under test.
independentCharges ∷ Bool → PngColourType → Int → Int → Int → [(PayloadStage, Int)]
independentCharges interlaced colour depth w h =
  [ (StageOutput, w * h * 4)
  , (StageScratch, 173056 + independentWidest interlaced (samplesOf colour * depth) w h)
  , (StageWorking, expectedScanlineBytes interlaced (colourCode colour) depth w h)
  ]

-- | What a decode of every fixture charged equals the independent count, in
-- the order it was made, and the peak is the whole bank's.
modelSpec ∷ Spec
modelSpec = describe "what a decode charges" $ do
  forM_ expectedFixtures $ \(Expected name width height _) →
    it (name <> " charges exactly the independently counted buffers, in order, and peaks at their sum with the input") $ do
      outcome ← decodeFixtureBounded name
      _ ← acceptedImage outcome
      Just preflighted ← pure (outcomePreflight outcome)
      let expected = independentCharges (preflightInterlace preflighted == InterlaceAdam7) (preflightColourType preflighted) (preflightBitDepth preflighted) width height
      grants ← grantedEvents (outcomeLedger outcome)
      grants `shouldBe` expected
      map (fmap toInteger) expected `shouldBe` decodeReservations preflighted
      peak ← peakBytes (outcomeLedger outcome)
      peak `shouldBe` outcomeSourceBytes outcome + sum (map snd expected)
      toInteger peak `shouldBe` decodePeakBytes preflighted

  it "charges the output before the scratch and the scratch before the scanlines, each before its allocation" $ do
    -- A bank that refuses the stage after the one named shows that the earlier
    -- grants were made first and the later buffer never allocated.
    outcome ← decodeFixtureBounded "rgba8.png"
    _ ← acceptedImage outcome
    grants ← grantedEvents (outcomeLedger outcome)
    map fst grants `shouldBe` [StageOutput, StageScratch, StageWorking]

-- | Every family at the approved maxima, by arithmetic.
familySpec ∷ Spec
familySpec = describe "the allocation bound at the approved maxima" $ do
  let families =
        [ (ColourGreyscale, [1, 2, 4, 8, 16])
        , (ColourTruecolour, [8, 16])
        , (ColourIndexed, [1, 2, 4, 8])
        , (ColourGreyscaleAlpha, [8, 16])
        , (ColourTruecolourAlpha, [8, 16])
        ]
      cases = [(colour, depth, interlaced) | (colour, depths) ← families, depth ← depths, interlaced ← [False, True]]
      peakOf (colour, depth, interlaced) =
        let charges = decodeReservationsFor colour depth (if interlaced then InterlaceAdam7 else InterlaceNone) 2048 2048
         in 32 * mebi + fromInteger (sum (map snd charges))
  forM_ cases $ \family@(colour, depth, interlaced) →
    it (show colour <> " " <> show depth <> "-bit " <> (if interlaced then "Adam7" else "non-interlaced") <> " at 2048 × 2048 charges what is counted, and fits the bank with a 32 MiB source") $ do
      let charges = decodeReservationsFor colour depth (if interlaced then InterlaceAdam7 else InterlaceNone) 2048 2048
      map (fmap fromInteger) charges `shouldBe` independentCharges interlaced colour depth 2048 2048
      lookup StageOutput charges `shouldBe` Just (16 * toInteger mebi)
      forM_ charges $ \(_, bytes) → bytes `shouldSatisfy` (<= 40 * toInteger mebi)
      peakOf family `shouldSatisfy` (<= m1WorkspaceBytes)

  it "is largest, at 84,079,360 bytes with a 32 MiB source, for 16-bit RGBA under Adam7" $ do
    let peaks = [(peakOf family, family) | family ← cases]
    maximum (map fst peaks) `shouldBe` 84079360
    snd (maximum peaks) `shouldBe` (ColourTruecolourAlpha, 16, True)

  it "leaves room in the bank for a staging copy of the output when the scanlines and scratch are gone" $ do
    32 * mebi + 2 * 16 * mebi `shouldSatisfy` (<= m1WorkspaceBytes)

-- | Real decodes at the maxima.
maximaSpec ∷ Spec
maximaSpec = describe "real decodes at the approved dimensions" $ do
  let big colour depth interlace = header 2048 2048 depth colour `withInterlace` interlace
      withInterlace hdr interlace = hdr {hInterlace = interlace}
  forM_ [(6, 16, 1, "16-bit RGBA under Adam7"), (0, 1, 1, "1-bit greyscale under Adam7"), (3, 8, 0, "8-bit palette"), (2, 8, 0, "8-bit RGB")] $ \(colour, depth, interlace, label) →
    it ("decodes " <> label <> " at 2048 × 2048 within the bank, peaking at the documented sum") $ do
      (bytes, preflighted) ← zeroImage (big colour depth interlace)
      ledger ← m1Bank
      _ ← chargeCaller ledger (ByteString.length bytes)
      result ← decodeBounded (ledgerAccount ledger) preflighted
      image ← either (\refusal → expectationFailure (show refusal) >> fail "refused") pure result
      map ByteString.length (decodedLevels image) `shouldBe` [16 * mebi]
      peak ← peakBytes ledger
      toInteger peak `shouldBe` decodePeakBytes preflighted
      peak `shouldSatisfy` (<= m1WorkspaceBytes)
      live ← liveBytes ledger
      live `shouldBe` ByteString.length bytes + 16 * mebi
      -- Zero samples: opaque types are opaque black, alpha types transparent.
      level ← levelOf image
      ByteString.all (== 0) (ByteString.pack [ByteString.index level i | i ← [0, 4 .. ByteString.length level - 1], ByteString.index level i /= 0]) `shouldBe` True
      ByteString.index level 3 `shouldBe` (if colour == 4 || colour == 6 then 0 else 255)

-- | A bank too small for one stage refuses it, as a limit, having allocated
-- nothing for it.
capacitySpec ∷ Spec
capacitySpec = describe "a bank too small for a stage" $ do
  let image = header 512 512 16 6
  forM_ [(StageOutput, 0 ∷ Int), (StageScratch, 1), (StageWorking, 2)] $ \(stage, position) →
    it ("refuses the " <> show stage <> " charge as a workspace limit, having charged and allocated nothing after it") $ do
      (bytes, preflighted) ← zeroImage image
      let charges = [fromInteger bytes' | (_, bytes') ← decodeReservations preflighted]
          capacity = ByteString.length bytes + sum (take position charges) + (charges !! position) - 1
      ledger ← newLedger capacity
      _ ← chargeCaller ledger (ByteString.length bytes)
      (result, allocated) ← allocatedDuring (decodeBounded (ledgerAccount ledger) preflighted)
      case result of
        Left refusal → do
          pngRefusalClass refusal `shouldBe` ExceededLimit LimitWorkspaceBytes
          pngRefusedAsset refusal `shouldBe` decodeAsset
        Right _ → expectationFailure "decoded in a bank too small for it"
      live ← liveBytes ledger
      live `shouldBe` ByteString.length bytes
      seen ← events ledger
      seen
        `shouldBe` ( [CallerCharged (ByteString.length bytes)]
                      <> [Granted s b | ((s, b), _) ← zip (zip [StageOutput, StageScratch, StageWorking] charges) [1 .. position]]
                      <> [Refused stage (charges !! position)]
                      <> [Released s b | (s, b) ← reverse (zip (take position [StageOutput, StageScratch, StageWorking]) charges)]
                  )
      -- The 2 MiB of scanlines were never allocated, nor inflated.
      allocated `shouldSatisfy` (< 256 * 1024)

  it "does not turn a refusal for the bank into one for the image: the same image decodes in a bank that fits" $ do
    (bytes, preflighted) ← zeroImage image
    ledger ← newLedger (fromInteger (decodePeakBytes preflighted))
    _ ← chargeCaller ledger (ByteString.length bytes)
    result ← decodeBounded (ledgerAccount ledger) preflighted
    either (const (expectationFailure "refused in a bank of exactly its peak")) (const (pure ())) result

-- | Faults are not refusals, and they leave the bank counting what it did not
-- release.
faultSpec ∷ Spec
faultSpec = describe "faults" $ do
  let prepared name = do
        bytes ← fixtureBytes name
        case preflightPng m1PngLimits decodeAsset bytes of
          Right accepted → pure (bytes, accepted)
          Left refusal → expectationFailure (show refusal) >> fail "refused"
      fault = throwIO (ErrorCall "the bank failed")
      chargesOf preflighted = [(stage, fromInteger bytes) | (stage, bytes) ← decodeReservations preflighted]

  forM_ [(StageOutput, 0 ∷ Int), (StageScratch, 1), (StageWorking, 2)] $ \(stage, position) →
    it ("is an exception, not a refusal, when the bank fails reserving " <> show stage <> ", and every earlier grant is released") $ do
      (bytes, preflighted) ← prepared "filters-rgba16.png"
      ledger ← m1Bank
      _ ← chargeCaller ledger (ByteString.length bytes)
      let account = beforeReserve (\s _ → when (s == stage) fault) (ledgerAccount ledger)
      outcome ← try (decodeBounded account preflighted)
      case outcome of
        Left (ErrorCall message) → message `shouldBe` "the bank failed"
        Right _ → expectationFailure "a bank fault became a result"
      liveBytes ledger >>= (`shouldBe` ByteString.length bytes)
      grants ← grantedEvents ledger
      length grants `shouldBe` position

  forM_ [StageWorking, StageScratch] $ \stage →
    it ("fails with the release's exception when " <> show stage <> " does not release after a decode that succeeded, and releases the rest") $ do
      (bytes, preflighted) ← prepared "filters-rgba16.png"
      ledger ← m1Bank
      _ ← chargeCaller ledger (ByteString.length bytes)
      let account = beforeRelease (\s _ → when (s == stage) fault) (ledgerAccount ledger)
      outcome ← try (decodeBounded account preflighted)
      case outcome of
        Left (ErrorCall message) → message `shouldBe` "the bank failed"
        Right _ → expectationFailure "a failed release was absorbed"
      -- The release that failed is not counted as released; the others are.
      liveBytes ledger >>= (`shouldBe` ByteString.length bytes + sum [b | (s, b) ← chargesOf preflighted, s == stage])

  it "retains failed releases beside a refusal, as a cleanup failure and not as a refusal, innermost first" $ do
    (bytes, preflighted) ← prepared "invalid-filter.png"
    ledger ← m1Bank
    _ ← chargeCaller ledger (ByteString.length bytes)
    let failing stage _ = when (stage == StageWorking || stage == StageScratch) (throwIO (ErrorCall ("release " <> show stage)))
    outcome ← try (decodeBounded (beforeRelease failing (ledgerAccount ledger)) preflighted)
    case outcome of
      Left failure → do
        show (cleanupPrimary failure) `shouldSatisfy` isInfixOf "filter type 5"
        map describeCleanup (cleanupFailures failure) `shouldBe` ["release StageWorking", "release StageScratch"]
        isJust (fromException (toException failure) ∷ Maybe SomeAsyncException) `shouldBe` False
      Right _ → expectationFailure "a refusal with failed releases was reported as a result"
    liveBytes ledger >>= (`shouldBe` ByteString.length bytes + sum [b | (s, b) ← chargesOf preflighted, s `elem` [StageWorking, StageScratch]])

describeCleanup ∷ SomeException → String
describeCleanup failure = case fromException failure of
  Just (ErrorCall message) → message
  Nothing → "other"

-- | Cancellation neither becomes a result nor leaves the bank charged.
cancellationSpec ∷ Spec
cancellationSpec = describe "asynchronous cancellation" $ do
  let prepared = do
        bytes ← fixtureBytes "filters-rgba16.png"
        case preflightPng m1PngLimits decodeAsset bytes of
          Right accepted → pure (bytes, accepted)
          Left refusal → expectationFailure (show refusal) >> fail "refused"

  forM_ [StageOutput, StageScratch, StageWorking] $ \stage →
    it ("while waiting for the bank to grant " <> show stage <> ": the thread ends cancelled and the bank holds only the input") $ do
      (bytes, preflighted) ← prepared
      ledger ← m1Bank
      _ ← chargeCaller ledger (ByteString.length bytes)
      waiting ← newEmptyMVar
      never ← newEmptyMVar
      let gate s _ = when (s == stage) (putMVar waiting () >> takeMVar never)
      (child, childDone) ← forkChild (decodeBounded (beforeReserve gate (ledgerAccount ledger)) preflighted)
      bounded (takeMVar waiting)
      killThread child
      outcome ← bounded (takeMVar childDone)
      cancelled outcome
      liveBytes ledger >>= (`shouldBe` ByteString.length bytes)
      balanced ledger

  forM_ [StageOutput, StageScratch, StageWorking] $ \stage →
    it ("after every grant, with the request pending until the decoder's first cancellable step, under mask: the decode is cancelled and every grant released (gate at " <> show stage <> ")") $ do
      (bytes, preflighted) ← prepared
      ledger ← m1Bank
      _ ← chargeCaller ledger (ByteString.length bytes)
      reached ← newEmptyMVar
      proceed ← newEmptyMVar
      -- The gate holds the decoder, uninterruptibly, until the cancellation
      -- request is queued behind its mask, so the request is delivered at
      -- the decoder's own first cancellable step and not before.
      let gate s _ = when (s == stage) (uninterruptibleMask_ (putMVar reached () >> takeMVar proceed))
      (child, childDone) ← forkChild (mask_ (decodeBounded (beforeReserve gate (ledgerAccount ledger)) preflighted))
      bounded (takeMVar reached)
      (thrower, throwerDone) ← forkChild (throwTo child ThreadKilled)
      bounded (awaitBlockedThrowing thrower)
      putMVar proceed ()
      outcome ← bounded (takeMVar childDone)
      void (bounded (takeMVar throwerDone))
      cancelled outcome
      liveBytes ledger >>= (`shouldBe` ByteString.length bytes)
      balanced ledger
      grants ← grantedEvents ledger
      map fst grants `shouldBe` [StageOutput, StageScratch, StageWorking]

  it "is still asynchronous, with the failed release retained, when a release fails during the cancellation" $ do
    (bytes, preflighted) ← prepared
    ledger ← m1Bank
    _ ← chargeCaller ledger (ByteString.length bytes)
    reached ← newEmptyMVar
    proceed ← newEmptyMVar
    let gate s _ = when (s == StageWorking) (uninterruptibleMask_ (putMVar reached () >> takeMVar proceed))
        failing s _ = when (s == StageScratch) (throwIO (ErrorCall "the release failed"))
        account = beforeRelease failing (beforeReserve gate (ledgerAccount ledger))
    (child, childDone) ← forkChild (mask_ (decodeBounded account preflighted))
    bounded (takeMVar reached)
    (thrower, throwerDone) ← forkChild (throwTo child ThreadKilled)
    bounded (awaitBlockedThrowing thrower)
    putMVar proceed ()
    outcome ← bounded (takeMVar childDone)
    void (bounded (takeMVar throwerDone))
    case outcome of
      Left failure → do
        (fromException failure ∷ Maybe SomeAsyncException) `shouldSatisfy` isJust
        case fromException failure of
          Just retained → do
            fromException (cleanupPrimary retained) `shouldBe` Just ThreadKilled
            map describeCleanup (cleanupFailures retained) `shouldBe` ["the release failed"]
          Nothing → expectationFailure "the cancellation lost its retained cleanup failure"
      Right _ → expectationFailure "the decode finished though cancelled"
    -- The scratch release failed and is still counted; the rest are released.
    live ← liveBytes ledger
    live `shouldBe` ByteString.length bytes + chargeFor StageScratch preflighted
  where
    cancelled outcome = case outcome of
      Left failure → fromException failure `shouldBe` Just ThreadKilled
      Right _ → expectationFailure "a cancelled decode returned"

-- | A fork whose result and termination the example waits for.
forkChild ∷ IO a → IO (ThreadId, MVar (Either SomeException a))
forkChild action = do
  done ← newEmptyMVar
  child ← forkFinally action (putMVar done)
  pure (child, done)

-- | Wait, without sleeping, until the thread is blocked delivering an
-- exception: it has been queued behind the target's mask.
awaitBlockedThrowing ∷ ThreadId → IO ()
awaitBlockedThrowing thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnException → pure ()
    ThreadFinished → expectationFailure "the cancelling thread finished before it was queued"
    _ → yield >> awaitBlockedThrowing thread

-- | Every grant has its release, except what was not released because it
-- could not be.
balanced ∷ Ledger → Expectation
balanced ledger = do
  seen ← events ledger
  let granted = sum [bytes | Granted _ bytes ← seen]
      released = sum [bytes | Released _ bytes ← seen]
  granted `shouldBe` released

-- | The output stays charged through the hand-over, and a consumer's staging
-- copy is charged beside it, not instead.
handoffSpec ∷ Spec
handoffSpec = describe "the output's hand-over" $ do
  it "keeps the output charged after the decoder returns, while a staging copy is charged beside it, and releases both in turn" $ do
    bytes ← fixtureBytes "rgba16.png"
    Right preflighted ← pure (preflightPng m1PngLimits decodeAsset bytes)
    ledger ← m1Bank
    _ ← chargeCaller ledger (ByteString.length bytes)
    result ← decodeBounded (ledgerAccount ledger) preflighted
    image ← either (\refusal → expectationFailure (show refusal) >> fail "refused") pure result
    level ← levelOf image
    let outputBytes = preflightRgba8Bytes preflighted
    -- The decoder has finished; its scratch and scanlines are released.
    liveBytes ledger >>= (`shouldBe` ByteString.length bytes + outputBytes)
    -- The consumer stages a copy while it still holds the level.
    staged ← chargeCaller ledger outputBytes
    staged `shouldBe` True
    let copy = ByteString.copy level
    liveBytes ledger >>= (`shouldBe` ByteString.length bytes + 2 * outputBytes)
    copy `shouldBe` level
    -- The source is dropped once the consumer has read it; the level remains
    -- charged until the staging copy is retired and the level disposed of.
    releaseCaller ledger (ByteString.length bytes)
    liveBytes ledger >>= (`shouldBe` 2 * outputBytes)
    releaseCaller ledger outputBytes
    releasePayload (ledgerAccount ledger) StageOutput outputBytes
    liveBytes ledger >>= (`shouldBe` 0)
    -- The bank's peak is the decode's, or the hand-over's if that is larger.
    peak ← peakBytes ledger
    toInteger peak `shouldBe` max (decodePeakBytes preflighted) (toInteger (ByteString.length bytes + 2 * outputBytes))

  it "leaves the level charged when the consumer's staging copy does not fit, until the consumer disposes of it" $ do
    bytes ← fixtureBytes "rgba16.png"
    Right preflighted ← pure (preflightPng m1PngLimits decodeAsset bytes)
    let capacity = fromInteger (decodePeakBytes preflighted)
    ledger ← newLedger capacity
    _ ← chargeCaller ledger (ByteString.length bytes)
    Right _ ← decodeBounded (ledgerAccount ledger) preflighted
    live ← liveBytes ledger
    -- A copy larger than the room the decoder's released work left is refused:
    -- the handoff failed, and nothing the decoder charged was given back.
    staged ← chargeCaller ledger (capacity - live + 1)
    staged `shouldBe` False
    liveBytes ledger >>= (`shouldBe` live)
    -- The consumer abandons the level; only then is its charge released.
    releasePayload (ledgerAccount ledger) StageOutput (preflightRgba8Bytes preflighted)
    liveBytes ledger >>= (`shouldBe` ByteString.length bytes)

  it "returns the bank to its start after repeated successes and refusals" $ do
    ledger ← m1Bank
    forM_ (concat (replicate 6 ["rgba16.png", "invalid-filter.png", "adam7-rgba16.png", "palette-index-out-of-range.png", "corrupt-stream.png"])) $ \name → do
      bytes ← fixtureBytes name
      _ ← chargeCaller ledger (ByteString.length bytes)
      outcome ← case preflightPng m1PngLimits decodeAsset bytes of
        Left refusal → pure (Left refusal)
        Right preflighted → decodeBounded (ledgerAccount ledger) preflighted
      case outcome of
        Right _ → do
          Right preflighted ← pure (preflightPng m1PngLimits decodeAsset bytes)
          releasePayload (ledgerAccount ledger) StageOutput (preflightRgba8Bytes preflighted)
        Left _ → pure ()
      releaseCaller ledger (ByteString.length bytes)
    liveBytes ledger >>= (`shouldBe` 0)
    balanced ledger

-- | What the result keeps alive.
retentionSpec ∷ Spec
retentionSpec = describe "what the result retains" $ do
  it "is the level's own buffer: not a slice of the source, of exactly the charged size" $ do
    bytes ← ByteString.copy <$> fixtureBytes "interlaced-rgba8.png"
    Right preflighted ← pure (preflightPng m1PngLimits decodeAsset bytes)
    ledger ← m1Bank
    Right image ← decodeBounded (ledgerAccount ledger) preflighted
    level ← levelOf image
    let (levelFp, levelOffset, levelLength) = ByteString.toForeignPtr level
        (sourceFp, sourceOffset, sourceLength) = ByteString.toForeignPtr bytes
        levelStart = unsafeForeignPtrToPtr levelFp `plusPtr` levelOffset
        sourceStart = unsafeForeignPtrToPtr sourceFp `plusPtr` sourceOffset
    levelOffset `shouldBe` 0
    levelLength `shouldBe` preflightRgba8Bytes preflighted
    (levelStart >= sourceStart `plusPtr` sourceLength || levelStart `plusPtr` levelLength <= sourceStart) `shouldBe` True

  it "does not keep the encoded source or the preflight alive" $ do
    -- The source is made, preflighted and decoded in a scope that returns
    -- only the image and a weak reference to the source's buffer.
    (image, weak) ← do
      bytes ← ByteString.copy <$> fixtureBytes "interlaced-rgba8.png"
      let (sourceFp, _, _) = ByteString.toForeignPtr bytes
      weakSource ← mkWeakPtr sourceFp Nothing
      Right preflighted ← pure (preflightPng m1PngLimits decodeAsset bytes)
      ledger ← m1Bank
      Right decoded ← decodeBounded (ledgerAccount ledger) preflighted
      pure (decoded, weakSource)
    performMajorGC
    alive ← deRefWeak weak
    decodedWidth image `shouldBe` 5
    isJust alive `shouldBe` False
