-- | The placement contract: validation, best-fit placement in one block,
-- coalescing, granularity, growth, dedicated routing and releases.
--
-- The generated examples drive a fixed block or an allocator through random
-- scripts and check the whole layout after every step: the ranges tile each
-- block, no two live placements overlap, every offset keeps its alignment, no
-- two placements of different tilings share a granularity page, and no two free
-- ranges are adjacent. A brute-force reference decides independently which free
-- range best fit should have chosen, and whether a refusal was right.
module Test.GPU.Model.Placement (spec) where

import Control.Monad (forM_)
import Data.Bits (popCount, shiftL)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64)
import Hetoimasia.GPU.Model.Placement
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck
  ( Gen
  , Property
  , choose
  , counterexample
  , elements
  , forAll
  , frequency
  , sized
  , vectorOf
  , (.&&.)
  , (===)
  )

mib ∷ Num a ⇒ a
mib = 1024 * 1024

spec ∷ Spec
spec = describe "placement" $ do
  configurationSpec
  requestSpec
  blockSpec
  granularitySpec
  growthSpec
  dedicatedSpec
  releaseSpec
  boundarySpec
  generatedSpec

-- ---------------------------------------------------------------------------
-- Configuration

configurationSpec ∷ Spec
configurationSpec = describe "configuration" $ do
  it "accepts D-13's defaults of 8 MiB growing to 64 MiB" $ do
    config ← validConfig (defaultPlacementConfigRequest 1024)
    initialBlockBytes config `shouldBe` 8 * 1024 * 1024
    maximumBlockBytes config `shouldBe` 64 * 1024 * 1024
    bufferImageGranularity config `shouldBe` 1024
    dedicatedThreshold config `shouldBe` 32 * 1024 * 1024

  it "rejects zero, negative, non-power-of-two and unrepresentable values rather than clamping them" $ do
    let base = defaultPlacementConfigRequest 1
        ceiling' = toInteger placementCeiling
        check asked expected = validatePlacementConfig asked `shouldBe` Left expected
    check base {requestedInitialBlockBytes = 0} (ConfigNotPositive InitialBlockField 0)
    check base {requestedInitialBlockBytes = -8} (ConfigNotPositive InitialBlockField (-8))
    check base {requestedInitialBlockBytes = 3 * mib} (ConfigNotPowerOfTwo InitialBlockField (3 * mib))
    check base {requestedMaximumBlockBytes = 0} (ConfigNotPositive MaximumBlockField 0)
    check base {requestedMaximumBlockBytes = 48 * mib} (ConfigNotPowerOfTwo MaximumBlockField (48 * mib))
    check base {requestedMaximumBlockBytes = 2 * ceiling'} (ConfigAboveCeiling MaximumBlockField (2 * ceiling'))
    check base {requestedBufferImageGranularity = 0} (ConfigNotPositive GranularityField 0)
    check base {requestedBufferImageGranularity = -1} (ConfigNotPositive GranularityField (-1))
    check base {requestedBufferImageGranularity = 1000} (ConfigNotPowerOfTwo GranularityField 1000)
    check base {requestedBufferImageGranularity = 2 ^ (70 ∷ Int)} (ConfigAboveCeiling GranularityField (2 ^ (70 ∷ Int)))

  it "rejects an initial block larger than the maximum" $
    validatePlacementConfig (defaultPlacementConfigRequest 1) {requestedInitialBlockBytes = 128 * mib}
      `shouldBe` Left (InitialAboveMaximum (128 * mib) (64 * mib))

  it "accepts an initial block equal to the maximum, the ceiling itself, and a granularity of one" $ do
    let ceiling' = toInteger placementCeiling
    _ ← validConfig (PlacementConfigRequest (64 * mib) (64 * mib) 1)
    _ ← validConfig (PlacementConfigRequest ceiling' ceiling' ceiling')
    pure ()

  it "reports the first fault in a fixed order when several are present" $
    validatePlacementConfig (PlacementConfigRequest 0 3 (-1))
      `shouldBe` Left (ConfigNotPositive InitialBlockField 0)

  it "validates a fixed block's capacity without requiring a power of two" $ do
    _ ← fixedBlock 1000 1
    either (const (pure ())) (const (expectationFailure "a zero capacity was accepted")) (openFixedBlock bestFit 0 1)
    case openFixedBlock bestFit (toInteger placementCeiling + 1) 1 of
      Left rejection → rejection `shouldBe` ConfigAboveCeiling BlockCapacityField (toInteger placementCeiling + 1)
      Right _ → expectationFailure "a capacity above the ceiling was accepted"
    case openFixedBlock bestFit 1000 3 of
      Left rejection → rejection `shouldBe` ConfigNotPowerOfTwo GranularityField 3
      Right _ → expectationFailure "a granularity of three was accepted"

-- ---------------------------------------------------------------------------
-- Requests

requestSpec ∷ Spec
requestSpec = describe "requests" $ do
  it "rejects a zero size, a non-power-of-two alignment and values above the ceiling" $ do
    validateFit 0 1 LinearResource `shouldBe` Left RequestSizeZero
    validateFit 16 0 LinearResource `shouldBe` Left (RequestAlignmentNotPowerOfTwo 0)
    validateFit 16 48 LinearResource `shouldBe` Left (RequestAlignmentNotPowerOfTwo 48)
    validateFit (placementCeiling + 1) 1 LinearResource `shouldBe` Left (RequestAboveCeiling RequestedSize (placementCeiling + 1))
    validateFit 16 (placementCeiling * 2) LinearResource `shouldBe` Left (RequestAboveCeiling RequestedAlignment (placementCeiling * 2))

  it "leaves the allocator unchanged when it rejects a request" $ do
    allocator0 ← defaultAllocator
    (_, allocator1) ← placed allocator0 (request 0 (4 * mib) 256 OptimalResource)
    forM_
      [ request 0 0 256 OptimalResource
      , request 0 (4 * mib) 3 OptimalResource
      , request 1 (fromIntegral placementCeiling + 1) 1 LinearResource
      ]
      $ \bad → case place bad allocator1 of
        Left _ → pure ()
        Right _ → expectationFailure ("placed an invalid request: " <> show bad)
    -- A rejection answers no allocator, so the one held is the one before it:
    -- the next identity is still the one after the only placement made, and
    -- the only block is still the one it opened.
    (next, allocator2) ← placed allocator1 (request 0 mib 1 OptimalResource)
    placementNumber (placementId next) `shouldBe` 1
    length (allocatorBlocks allocator2) `shouldBe` 1

-- ---------------------------------------------------------------------------
-- One block

blockSpec ∷ Spec
blockSpec = describe "a fixed block" $ do
  it "places into the smallest free range that fits, the lowest offset among equals" $ do
    -- Carve free ranges of 300, 100 and 200 bytes separated by placements.
    block0 ← fixedBlock 1000 1
    (a, block1) ← fitted block0 300 1
    (_, block2) ← fitted block1 50 1
    (b, block3) ← fitted block2 100 1
    (_, block4) ← fitted block3 50 1
    (c, block5) ← fitted block4 200 1
    (_, block6) ← fitted block5 300 1
    block7 ← released block6 [a, b, c]
    map rangeKind (blockRanges block7)
      `shouldBe` [Free 0 300, Live 300 50, Free 350 100, Live 450 50, Free 500 200, Live 700 300]
    (offset, _) ← fitted block7 90 1
    offset `shouldBe` 350
    (offset', _) ← fitted block7 150 1
    offset' `shouldBe` 500

  it "refuses a request that no free range can take, and changes nothing" $ do
    block0 ← fixedBlock 1000 1
    (_, block1) ← fitted block0 600 1
    fit ← validFit 500 1 OptimalResource
    case placeInBlock fit block1 of
      Refused → pure ()
      Fitted offset _ → expectationFailure ("placed at " <> show offset)

  it "leaves alignment padding free and places at an aligned offset" $ do
    block0 ← fixedBlock 1024 1
    (_, block1) ← fitted block0 10 1
    (offset, block2) ← fitted block1 64 64
    offset `shouldBe` 64
    map rangeKind (blockRanges block2)
      `shouldBe` [Live 0 10, Free 10 54, Live 64 64, Free 128 896]

  it "coalesces freed neighbours on both sides into one range" $ do
    block0 ← fixedBlock 900 1
    (a, block1) ← fitted block0 300 1
    (b, block2) ← fitted block1 300 1
    (c, block3) ← fitted block2 300 1
    block4 ← released block3 [a, c]
    usageFreeRangeCount (blockUsage block4) `shouldBe` 2
    block5 ← released block4 [b]
    map rangeKind (blockRanges block5) `shouldBe` [Free 0 900]
    blockIsEmpty block5 `shouldBe` True
    fragmentation (blockUsage block5) `shouldBe` 0

  it "refuses to release an offset where no placement starts" $ do
    block0 ← fixedBlock 1000 1
    (a, block1) ← fitted block0 100 1
    maybe (pure ()) (const (expectationFailure "released a free offset")) (releaseInBlock 500 block1)
    maybe (pure ()) (const (expectationFailure "released the middle of a placement")) (releaseInBlock (a + 1) block1)
    block2 ← released block1 [a]
    maybe (pure ()) (const (expectationFailure "released a placement twice")) (releaseInBlock a block2)

-- ---------------------------------------------------------------------------
-- Granularity

granularitySpec ∷ Spec
granularitySpec = describe "buffer-image granularity" $ do
  it "moves an optimally tiled placement off a linear neighbour's page" $ do
    block0 ← fixedBlockOf 8192 1024
    (_, block1) ← fittedAs block0 100 1 LinearResource
    (offset, _) ← fittedAs block1 100 1 OptimalResource
    offset `shouldBe` 1024

  it "lets placements of one tiling share a page" $ do
    block0 ← fixedBlockOf 8192 1024
    (_, block1) ← fittedAs block0 100 1 LinearResource
    (offset, _) ← fittedAs block1 100 1 LinearResource
    offset `shouldBe` 100

  it "rejects a free range whose next neighbour would share the new placement's last page" $ do
    -- Optimal [0, 1500), a free gap [1500, 2500), optimal [2500, 2600), then
    -- free. Pages are 1024 bytes, so the gap spans pages one and two, each of
    -- which an optimal neighbour shares.
    block0 ← fixedBlockOf 8192 1024
    (_, block1) ← fittedAs block0 1500 1 OptimalResource
    (gap, block2) ← fittedAs block1 1000 1 OptimalResource
    (_, block3) ← fittedAs block2 100 1 OptimalResource
    block4 ← released block3 [gap]
    -- A linear request is the gap's best fit by size. The previous neighbour
    -- pushes it to 2048, where its last byte shares page two with the next
    -- neighbour, so the gap is rejected and it goes past that neighbour's page.
    (offset, block5) ← fittedAs block4 100 1 LinearResource
    offset `shouldBe` 3072
    layoutProblems 1024 block5 `shouldBe` []
    -- An optimal request shares both pages freely and takes the gap.
    (offset', _) ← fittedAs block5 900 1 OptimalResource
    offset' `shouldBe` 1500

  it "places a mixed tiling between existing neighbours without sharing either page" $ do
    -- Optimal [0, 100), free, optimal [4096, 4196): a linear placement between
    -- them may share neither neighbour's page.
    block0 ← fixedBlockOf 8192 1024
    (_, block1) ← fittedAs block0 100 1 OptimalResource
    (gap, block2) ← fittedAs block1 3996 1 OptimalResource
    (_, block3) ← fittedAs block2 100 1 OptimalResource
    block4 ← released block3 [gap]
    (offset, block5) ← fittedAs block4 2048 1 LinearResource
    offset `shouldBe` 1024
    layoutProblems 1024 block5 `shouldBe` []
    -- The rest of the gap, [3072, 4096), is page three alone, which no optimal
    -- placement touches, so a linear request may fill it exactly.
    (offset', block6) ← fittedAs block5 1024 1 LinearResource
    offset' `shouldBe` 3072
    -- One byte more fits nowhere in the gap, and the free range after the
    -- second optimal placement starts on its page, so it moves to page five.
    (offset'', _) ← fittedAs block6 1025 1 LinearResource
    offset'' `shouldBe` 5120

-- ---------------------------------------------------------------------------
-- Growth

growthSpec ∷ Spec
growthSpec = describe "block growth" $ do
  it "opens blocks of 8, 16, 32 and then 64 MiB, and stays at 64" $ do
    allocator0 ← defaultAllocator
    -- 5 MiB requests: one fits the 8 MiB block, three the 16, six the 32 and
    -- twelve each 64, so 23 of them open five blocks.
    capacities ← openedCapacities allocator0 (replicate 23 (request 0 (5 * mib) 256 OptimalResource))
    map (`div` mib) capacities `shouldBe` [8, 16, 32, 64, 64]

  it "advances straight to a size that fits without opening the ones in between" $ do
    allocator0 ← defaultAllocator
    (first, allocator1) ← placed allocator0 (request 0 (20 * mib) 256 OptimalResource)
    placementLocation first `shouldSatisfy` openedWith (32 * mib)
    length (allocatorBlocks allocator1) `shouldBe` 1
    nextBlockBytes (MemoryTypeIndex 0) allocator1 `shouldBe` 64 * mib

  it "grows each memory type independently" $ do
    allocator0 ← defaultAllocator
    (_, allocator1) ← placed allocator0 (request 0 (20 * mib) 256 OptimalResource)
    nextBlockBytes (MemoryTypeIndex 0) allocator1 `shouldBe` 64 * mib
    nextBlockBytes (MemoryTypeIndex 1) allocator1 `shouldBe` 8 * mib
    (other, allocator2) ← placed allocator1 (request 1 mib 256 OptimalResource)
    placementLocation other `shouldSatisfy` openedWith (8 * mib)
    -- The first type's block has room, but a request for another type never
    -- goes there.
    (again, _) ← placed allocator2 (request 1 (8 * mib) 256 OptimalResource)
    placementLocation again `shouldSatisfy` openedWith (16 * mib)

  it "places into an open block with room before opening another" $ do
    allocator0 ← defaultAllocator
    (_, allocator1) ← placed allocator0 (request 0 mib 256 OptimalResource)
    (second, _) ← placed allocator1 (request 0 mib 256 OptimalResource)
    case placementLocation second of
      InExistingBlock _ offset → offset `shouldBe` mib
      other → expectationFailure ("expected the open block, got " <> show other)

-- ---------------------------------------------------------------------------
-- Dedicated allocations

dedicatedSpec ∷ Spec
dedicatedSpec = describe "dedicated allocations" $ do
  it "dedicates a request of at least half the configured maximum, whatever block is open" $ do
    allocator0 ← defaultAllocator
    (_, allocator1) ← placed allocator0 (request 0 mib 256 OptimalResource)
    (half, allocator2) ← placed allocator1 (request 0 (32 * mib) 256 OptimalResource)
    placementLocation half `shouldBe` DedicatedAllocation
    (below, _) ← placed allocator2 (request 0 (32 * mib - 1) 256 OptimalResource)
    placementLocation below `shouldSatisfy` openedWith (32 * mib)

  it "dedicates any request the driver prefers or requires dedicated" $ do
    allocator0 ← defaultAllocator
    forM_ [DriverPrefersDedicated, DriverRequiresDedicated] $ \dedication → do
      (small, allocator1) ← placed allocator0 (request 0 4096 256 OptimalResource) {requestDedication = dedication}
      placementLocation small `shouldBe` DedicatedAllocation
      length (allocatorBlocks allocator1) `shouldBe` 0

  it "releases a dedicated allocation back to the owning boundary" $ do
    allocator0 ← defaultAllocator
    (big, allocator1) ← placed allocator0 (request 0 (40 * mib) 256 OptimalResource)
    livePlacementCount allocator1 `shouldBe` 1
    (answer, allocator2) ← releasedPlacement allocator1 (placementId big)
    answer `shouldBe` ReleasedDedicated
    livePlacementCount allocator2 `shouldBe` 0

-- ---------------------------------------------------------------------------
-- Releases

releaseSpec ∷ Spec
releaseSpec = describe "releases" $ do
  it "reports a block empty once all of its placements are released, as one free range" $ do
    allocator0 ← defaultAllocator
    (a, allocator1) ← placed allocator0 (request 0 mib 256 OptimalResource)
    (b, allocator2) ← placed allocator1 (request 0 mib 256 OptimalResource)
    (first, allocator3) ← releasedPlacement allocator2 (placementId a)
    first `shouldSatisfy` releasedWithEmpty False
    emptyBlocks allocator3 `shouldBe` []
    (second, allocator4) ← releasedPlacement allocator3 (placementId b)
    second `shouldSatisfy` releasedWithEmpty True
    map emptyCapacity (emptyBlocks allocator4) `shouldBe` [8 * 1024 * 1024]
    [(_, _, block)] ← pure (allocatorBlocks allocator4)
    map rangeKind (blockRanges block) `shouldBe` [Free 0 (8 * 1024 * 1024)]

  it "rejects releasing a placement twice, and changes nothing" $ do
    allocator0 ← defaultAllocator
    (a, allocator1) ← placed allocator0 (request 0 mib 256 OptimalResource)
    (_, allocator2) ← releasedPlacement allocator1 (placementId a)
    case release (placementId a) allocator2 of
      Left rejection → rejection `shouldBe` UnknownPlacement (placementId a)
      Right _ → expectationFailure "released a placement twice"

  it "never lets a released identity release the placement that took its offset" $ do
    allocator0 ← defaultAllocator
    (old, allocator1) ← placed allocator0 (request 0 mib 256 OptimalResource)
    (_, allocator2) ← releasedPlacement allocator1 (placementId old)
    (replacement, allocator3) ← placed allocator2 (request 0 mib 256 OptimalResource)
    placementLocation replacement `shouldBe` InExistingBlock (blockOf old) 0
    placementId replacement `shouldSatisfy` (/= placementId old)
    case release (placementId old) allocator3 of
      Left rejection → rejection `shouldBe` UnknownPlacement (placementId old)
      Right _ → expectationFailure "the old identity released its replacement"
    livePlacementCount allocator3 `shouldBe` 1

  it "rejects an identity another allocator issued beyond this one's" $ do
    allocator0 ← defaultAllocator
    (_, other1) ← placed allocator0 (request 0 mib 1 OptimalResource)
    (foreign', _) ← placed other1 (request 0 mib 1 OptimalResource)
    case release (placementId foreign') allocator0 of
      Left rejection → rejection `shouldBe` UnknownPlacement (placementId foreign')
      Right _ → expectationFailure "released an identity this allocator never issued"
  where
    blockOf placement = case placementLocation placement of
      InOpenedBlock blockId _ _ → blockId
      InExistingBlock blockId _ → blockId
      DedicatedAllocation → error "a dedicated placement has no block"

-- ---------------------------------------------------------------------------
-- Boundary arithmetic

boundarySpec ∷ Spec
boundarySpec = describe "boundary arithmetic" $ do
  it "places a ceiling-sized request with a ceiling alignment in a ceiling-sized block" $ do
    block0 ← fixedBlock (toInteger placementCeiling) 1
    (offset, block1) ← fittedAs block0 placementCeiling placementCeiling OptimalResource
    offset `shouldBe` 0
    fit ← validFit 1 1 OptimalResource
    case placeInBlock fit block1 of
      Refused → pure ()
      Fitted at _ → expectationFailure ("placed past a full block at " <> show at)

  it "refuses a large alignment that would align past the block instead of wrapping" $ do
    block0 ← fixedBlock (toInteger placementCeiling) (toInteger placementCeiling)
    (_, block1) ← fittedAs block0 1 1 LinearResource
    -- The next ceiling-aligned offset is the block's end, and the granularity
    -- page is the whole block, so neither tiling fits anywhere.
    forM_ [LinearResource, OptimalResource] $ \tiling → do
      fit ← validFit 1 placementCeiling tiling
      case placeInBlock fit block1 of
        Refused → pure ()
        Fitted at _ → expectationFailure ("placed at " <> show at)
    -- A request of the same tiling may still share the one page.
    (offset, _) ← fittedAs block1 (placementCeiling - 1) 1 LinearResource
    offset `shouldBe` 1

-- ---------------------------------------------------------------------------
-- Generated sequences

generatedSpec ∷ Spec
generatedSpec = describe "generated sequences" $ modifyMaxSuccess (const 300) $ do
  prop "keep a fixed block's layout sound and choose what best fit would choose" $
    forAll blockScript runBlockScript
  prop "keep an allocator's blocks sound, growing and dedicating by the rules" $
    forAll allocatorScript runAllocatorScript

-- | One step of a generated script.
data Op
  = Place !Word64 !Word64 !ResourceTiling !Dedication !Int
    -- ^ Size, alignment, tiling, dedication and memory type.
  | Drop !Int
    -- ^ Release the live placement at this position of the live list, modulo
    -- its length.
  deriving (Show)

data BlockScript = BlockScript !Integer !Integer ![Op]
  deriving (Show)

blockScript ∷ Gen BlockScript
blockScript = sized $ \n → do
  capacity ← choose (64, 4096)
  granularity ← elements [1, 1, 2, 16, 64, 256]
  count ← choose (1, 30 + 3 * n)
  BlockScript capacity granularity <$> vectorOf count (operation (fromInteger capacity `div` 3) 1)

operation ∷ Word64 → Int → Gen Op
operation largest memoryTypes =
  frequency
    [ ( 3
      , Place
          <$> frequency [(3, choose (1, 48)), (2, choose (1, largest)), (1, elements [1, 2, largest])]
          <*> (shiftL 1 <$> choose (0, 7))
          <*> elements [LinearResource, OptimalResource]
          <*> frequency [(12, pure NoDedicationPreference), (1, pure DriverPrefersDedicated), (1, pure DriverRequiresDedicated)]
          <*> choose (0, memoryTypes - 1)
      )
    , (2, Drop <$> choose (0, 1000))
    ]

-- | A live placement in a fixed block, as the script remembers it.
data Held = Held {heldOffset ∷ !Word64, heldSize ∷ !Word64, heldAlignment ∷ !Word64}
  deriving (Show)

runBlockScript ∷ BlockScript → Property
runBlockScript (BlockScript capacity granularity ops) =
  case openFixedBlock bestFit capacity granularity of
    Left rejection → counterexample (show rejection) False
    Right block0 → go block0 [] (zip [0 ∷ Int ..] ops)
  where
    g = fromInteger granularity
    go block held [] =
      -- Releasing everything left leaves one free range.
      let emptied = foldl' (\b h → maybe b id (releaseInBlock (heldOffset h) b)) block held
       in counterexample "after releasing everything" $
            map rangeKind (blockRanges emptied) === [Free 0 (fromInteger capacity)]
    go block held ((step, op) : rest) =
      case op of
        Place size alignment tiling _ _ →
          case validateFit size alignment tiling of
            Left rejection → counterexample (show rejection) False
            Right fit →
              let expected = referenceBestFit g (blockRanges block) size alignment tiling
               in case (placeInBlock fit block, expected) of
                    (Refused, Nothing) → go block held rest
                    (Refused, Just offset) →
                      counterexample ("step " <> show step <> ": refused, but " <> show offset <> " fits") False
                    (Fitted offset _, Nothing) →
                      counterexample ("step " <> show step <> ": placed at " <> show offset <> ", but nothing fits") False
                    (Fitted offset block', Just want)
                      | offset /= want →
                          counterexample ("step " <> show step <> ": placed at " <> show offset <> ", best fit is " <> show want) False
                      | otherwise → checked step block' (Held offset size alignment : held) rest
        Drop index → case pick index held of
          Nothing → go block held rest
          Just (target, others) →
            case releaseInBlock (heldOffset target) block of
              Nothing → counterexample ("step " <> show step <> ": could not release " <> show target) False
              Just block' → checked step block' others rest
    checked step block held rest =
      let problems = layoutProblems g block <> alignmentProblems held
       in if null problems
            then go block held rest
            else counterexample ("step " <> show step <> ": " <> unlines problems) False

-- | Where best fit should place a request, found by trying every free range:
-- the smallest range that fits, the lowest offset among equals.
referenceBestFit ∷ Word64 → [BlockRange] → Word64 → Word64 → ResourceTiling → Maybe Word64
referenceBestFit g layout size alignment tiling =
  case sortOn (\(rangeSize, start, _) → (rangeSize, start)) candidates of
    ((_, _, offset) : _) → Just offset
    [] → Nothing
  where
    indexed = zip [0 ∷ Int ..] layout
    candidates =
      [ (rangeSize, start, offset)
      | (i, FreeRange start rangeSize) ← indexed
      , let previous = if i > 0 then liveTiling (layout !! (i - 1)) else Nothing
            next = if i + 1 < length layout then liveStart (layout !! (i + 1)) else Nothing
            end = toInteger start + toInteger rangeSize
            offset0 = alignUp (toInteger start) (toInteger alignment)
            offset1 = case previous of
              Just (previousEnd, previousTiling)
                | g > 1
                , previousTiling /= tiling
                , (previousEnd - 1) `div` toInteger g == offset0 `div` toInteger g →
                    alignUp offset0 (toInteger g)
              _ → offset0
      , offset1 + toInteger size <= end
      , case next of
          Just (nextStart, nextTiling) →
            not (g > 1 && nextTiling /= tiling && (offset1 + toInteger size - 1) `div` toInteger g == nextStart `div` toInteger g)
          Nothing → True
      , let offset = fromInteger offset1
      ]
    liveTiling (LiveRange at liveSize liveTiling') = Just (toInteger at + toInteger liveSize, liveTiling')
    liveTiling _ = Nothing
    liveStart (LiveRange at _ liveTiling') = Just (toInteger at, liveTiling')
    liveStart _ = Nothing
    alignUp value a = ((value + a - 1) `div` a) * a

-- | Everything wrong with a block's layout: gaps or overlaps between ranges,
-- adjacent free ranges, tilings sharing a page, and usage disagreeing with the
-- ranges.
layoutProblems ∷ Word64 → Block → [String]
layoutProblems g block =
  tiling <> adjacentFree <> pages <> accounting
  where
    layout = blockRanges block
    usage = blockUsage block
    extent (LiveRange at size _) = (at, size)
    extent (FreeRange at size) = (at, size)
    tiling =
      [ "ranges do not tile the block: " <> show layout
      | let ends = scanl (\at r → at + snd (extent r)) 0 layout
      , or (zipWith (\at r → fst (extent r) /= at) ends layout) || last ends /= blockCapacity block
      ]
    adjacentFree =
      [ "adjacent free ranges at " <> show a
      | (FreeRange a _, FreeRange _ _) ← zip layout (drop 1 layout)
      ]
    lives = [(at, size, t) | LiveRange at size t ← layout]
    pages =
      [ "tilings share page " <> show ((aEnd - 1) `div` g) <> ": " <> show (a, b)
      | g > 1
      , (a@(aAt, aSize, aTiling), b@(bAt, _, bTiling)) ← pairs lives
      , let aEnd = aAt + aSize
      , aTiling /= bTiling
      , (aEnd - 1) `div` g == bAt `div` g
      ]
    pairs xs = [(x, y) | (i, x) ← zip [0 ∷ Int ..] xs, (j, y) ← zip [0 ..] xs, i < j]
    frees = [size | FreeRange _ size ← layout]
    accounting =
      [ "usage disagrees with the ranges: " <> show usage
      | usageFreeBytes usage /= sum frees
          || usageLiveCount usage /= length lives
          || usageLiveBytes usage /= sum [size | (_, size, _) ← lives]
          || usageFreeRangeCount usage /= length frees
          || usageLargestFreeRange usage /= maximum (0 : frees)
      ]

alignmentProblems ∷ [Held] → [String]
alignmentProblems held =
  [ "placement at " <> show (heldOffset h) <> " breaks its alignment " <> show (heldAlignment h)
  | h ← held
  , heldOffset h `mod` heldAlignment h /= 0
  ]

-- | A script for an allocator with a small configuration, so growth, the
-- dedicated threshold and several memory types are all reached quickly.
newtype AllocatorScript = AllocatorScript [Op]
  deriving (Show)

allocatorScript ∷ Gen AllocatorScript
allocatorScript = sized $ \n → do
  count ← choose (1, 40 + 4 * n)
  AllocatorScript <$> vectorOf count (operation 400 3)

smallConfigRequest ∷ PlacementConfigRequest
smallConfigRequest = PlacementConfigRequest 64 512 16

runAllocatorScript ∷ AllocatorScript → Property
runAllocatorScript (AllocatorScript ops) =
  case validatePlacementConfig smallConfigRequest of
    Left rejection → counterexample (show rejection) False
    Right config → go config (newAllocator bestFit config) [] Map.empty (zip [0 ∷ Int ..] ops)
  where
    go _ allocator live _ [] =
      let emptied = foldl' (\a p → either (const a) snd (release (placementId (fst p)) a)) allocator live
          layouts = [map rangeKind (blockRanges block) | (_, _, block) ← allocatorBlocks emptied]
       in counterexample "after releasing everything" $
            livePlacementCount emptied === 0
              .&&. all (\l → length l == 1) layouts
              .&&. length (emptyBlocks emptied) === length (allocatorBlocks emptied)
    go config allocator live opened ((step, op) : rest) =
      case op of
        Place size alignment tiling dedication memoryType →
          let asked = PlacementRequest (MemoryTypeIndex (fromIntegral memoryType)) size alignment tiling dedication
           in case place asked allocator of
                Left rejection → counterexample ("step " <> show step <> ": " <> show rejection) False
                Right (placement, allocator') →
                  let shouldDedicate = dedication /= NoDedicationPreference || size >= dedicatedThreshold config
                      isDedicated = placementLocation placement == DedicatedAllocation
                      opened' = case placementLocation placement of
                        InOpenedBlock _ capacity _ → Map.insertWith (flip (<>)) memoryType [capacity] opened
                        _ → opened
                   in if shouldDedicate /= isDedicated
                        then counterexample ("step " <> show step <> ": dedicated " <> show isDedicated <> " for " <> show asked) False
                        else checked config step allocator' ((placement, alignment) : live) opened' rest
        Drop index → case pick index live of
          Nothing → go config allocator live opened rest
          Just (target, others) →
            case release (placementId (fst target)) allocator of
              Left rejection → counterexample ("step " <> show step <> ": " <> show rejection) False
              Right (_, allocator') → checked config step allocator' others opened rest
    checked config step allocator live opened rest =
      let g = bufferImageGranularity config
          blockProblems = concat [layoutProblems g block | (_, _, block) ← allocatorBlocks allocator]
          liveProblems =
            [ "live placement misplaced: " <> show placement
            | (placement, alignment) ← live
            , case placementLocation placement of
                InExistingBlock _ offset → offset `mod` alignment /= 0
                InOpenedBlock _ _ offset → offset `mod` alignment /= 0
                DedicatedAllocation → False
            ]
          growthProblems =
            [ "memory type " <> show memoryType <> " opened " <> show capacities
            | (memoryType, capacities) ← Map.toList opened
            , not (growsByTheRules config capacities)
            ]
          countProblems =
            [ "live count " <> show (livePlacementCount allocator) <> " but the script holds " <> show (length live)
            | livePlacementCount allocator /= length live
            ]
          problems = blockProblems <> liveProblems <> growthProblems <> countProblems
       in if null problems
            then go config allocator live opened rest
            else counterexample ("step " <> show step <> ": " <> unlines problems) False

-- | Capacities in opening order never shrink, are powers of two between the
-- initial and maximum sizes, and never exceed the maximum.
growsByTheRules ∷ PlacementConfig → [Word64] → Bool
growsByTheRules config capacities =
  and (zipWith (<=) capacities (drop 1 capacities))
    && all (\c → c >= initialBlockBytes config && c <= maximumBlockBytes config && popCount c == 1) capacities

-- ---------------------------------------------------------------------------
-- Helpers

-- | The element at a position, modulo the length, and the others in order.
pick ∷ Int → [a] → Maybe (a, [a])
pick _ [] = Nothing
pick index xs = case splitAt (index `mod` length xs) xs of
  (before, target : after) → Just (target, before <> after)
  (_, []) → Nothing

data Kind = Live !Word64 !Word64 | Free !Word64 !Word64
  deriving (Eq, Show)

rangeKind ∷ BlockRange → Kind
rangeKind (LiveRange at size _) = Live at size
rangeKind (FreeRange at size) = Free at size

validConfig ∷ PlacementConfigRequest → IO PlacementConfig
validConfig asked = either (fail . show) pure (validatePlacementConfig asked)

defaultAllocator ∷ IO Allocator
defaultAllocator = newAllocator bestFit <$> validConfig (defaultPlacementConfigRequest 1024)

fixedBlock ∷ Integer → Integer → IO Block
fixedBlock = fixedBlockOf

fixedBlockOf ∷ Integer → Integer → IO Block
fixedBlockOf capacity granularity = either (fail . show) pure (openFixedBlock bestFit capacity granularity)

validFit ∷ Word64 → Word64 → ResourceTiling → IO Fit
validFit size alignment tiling = either (fail . show) pure (validateFit size alignment tiling)

fitted ∷ Block → Word64 → Word64 → IO (Word64, Block)
fitted block size alignment = fittedAs block size alignment OptimalResource

fittedAs ∷ Block → Word64 → Word64 → ResourceTiling → IO (Word64, Block)
fittedAs block size alignment tiling = do
  fit ← validFit size alignment tiling
  case placeInBlock fit block of
    Fitted offset block' → pure (offset, block')
    Refused → fail ("refused " <> show (size, alignment, tiling))

released ∷ Block → [Word64] → IO Block
released block offsets =
  case foldl' (\b o → b >>= releaseInBlock o) (Just block) offsets of
    Just block' → pure block'
    Nothing → fail ("could not release " <> show offsets)

request ∷ Word32 → Integer → Word64 → ResourceTiling → PlacementRequest
request memoryType size alignment tiling =
  PlacementRequest (MemoryTypeIndex memoryType) (fromInteger size) alignment tiling NoDedicationPreference

placed ∷ Allocator → PlacementRequest → IO (Placement, Allocator)
placed allocator asked = either (fail . show) pure (place asked allocator)

releasedPlacement ∷ Allocator → PlacementId → IO (Released, Allocator)
releasedPlacement allocator identity = either (fail . show) pure (release identity allocator)

openedCapacities ∷ Allocator → [PlacementRequest] → IO [Word64]
openedCapacities allocator0 requests = go allocator0 requests []
  where
    go _ [] acc = pure (reverse acc)
    go allocator (r : rs) acc = do
      (placement, allocator') ← placed allocator r
      case placementLocation placement of
        InOpenedBlock _ capacity _ → go allocator' rs (capacity : acc)
        _ → go allocator' rs acc

openedWith ∷ Integer → PlacementLocation → Bool
openedWith capacity (InOpenedBlock _ c _) = toInteger c == capacity
openedWith _ _ = False

releasedWithEmpty ∷ Bool → Released → Bool
releasedWithEmpty expected (ReleasedFromBlock _ _ empty) = empty == expected
releasedWithEmpty _ ReleasedDedicated = False
