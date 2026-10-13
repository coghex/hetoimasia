-- | Frame tables and animation (R2D-18): the frame a view's time selects, the
-- refusals of a table, a time and an index, the retained chunk's reference, and
-- the index in the flags word and the 64-byte instance.
--
-- __Where the expectations come from.__ The selection examples state the frame
-- they expect in the test, worked out by hand from the formula
-- @floor (t / duration) mod count@ with the 'Double' division: times and durations
-- are chosen to be exactly representable where a boundary is meant, so that the
-- quotient is exact, and the decimal regression names its quotient. The
-- generated examples compare with 'referenceFrame', a second evaluation of the
-- formula that takes the floor from the quotient's mantissa and exponent instead
-- of the library's @floor@, so no integer conversion is shared.
module Test.Render.TwoD.Animation (spec) where

import Data.Bits (shiftL)
import qualified Data.ByteString as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map.Strict as Map
import Data.Word (Word16, Word8)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Animation
import Hetoimasia.Render.TwoD.Chunk
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)
import Hetoimasia.Render.TwoD.Clip (ClipEntry (..), ClipRect (..))
import Hetoimasia.Render.TwoD.Encoding (encodeLayer, flagsWord)
import Hetoimasia.Render.TwoD.Material (MaterialFacts (..), RecordLayout (..))
import Hetoimasia.Render.TwoD.Material.Backend (materialRef)
import Hetoimasia.Render.TwoD.DrawPlan (noCutoutMarks)
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation
  ( Location (..)
  , Reason (..)
  , Refusal (..)
  , validLayers
  , validateSnapshot
  , validateSnapshotWith
  )
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, choose, conjoin, counterexample, elements, forAll, oneof, property, (===))
import Test.Render.TwoD.Support

spec ∷ Spec
spec = describe "Animation" $ do
  selectionSpec
  refusalSpec
  chunkSpec
  flagsSpec
  encodingSpec

-- * Builders

-- | A table of this many frames of this duration, frame @k@ showing the
-- rectangle @(k, 0, k + 1, 1)@, so a frame is read off its rectangle.
tableOf ∷ Int → Double → FrameTable
tableOf count duration = FrameTable count duration [UvRect (fromIntegral k) 0 (fromIntegral k + 1) 1 | k ← [0 .. count - 1]]

-- | A view of these tables at this time, drawing these layers in the plain
-- viewport.
animatedView ∷ [FrameTable] → Double → [Layer] → View
animatedView tables time = ViewWith plainCamera plainViewport defaultViewSettings [] Map.empty tables time

-- | An instance carrying this frame-table index.
framed ∷ Word16 → Instance
framed index = plainInstance {instanceFrameTable = index}

-- | The snapshot of one window pass holding the view.
snapshotOfView ∷ View → Snapshot
snapshotOfView = snapshotWithView

-- | The refusals of a view alone, with their reasons and locations.
refusedView ∷ View → [Refusal]
refusedView = refusalsOf . snapshotOfView

atTable ∷ Int → Reason → Refusal
atTable index = Refusal (AtFrameTable 0 0 index)

atView ∷ Reason → Refusal
atView = Refusal (AtView 0 0)

atInstance ∷ Int → Reason → Refusal
atInstance index = Refusal (AtInstance 0 0 0 index)

-- | The largest finite 'Double', written out so no test depends on a library
-- constant.
hugeDouble ∷ Double
hugeDouble = 1.7976931348623157e308

-- | The next 'Double' below this positive one.
below ∷ Double → Double
below value = castWord64ToDouble (castDoubleToWord64 value - 1)

-- | The next 'Double' above this positive one.
above ∷ Double → Double
above value = castWord64ToDouble (castDoubleToWord64 value + 1)

-- * Selection

-- | The formula again, written out another way: the floor of the 'Double'
-- quotient from its mantissa and exponent (@m × 2^e@, shifted right for a
-- negative exponent), then the modulus. No @floor@ and no @truncate@.
referenceFrame ∷ Double → FrameTable → Integer
referenceFrame time table = whole `mod` toInteger (frameTableCount table)
  where
    (mantissa, exponent') = decodeFloat (time / frameTableDuration table)
    whole
      | mantissa == 0 = 0
      | exponent' >= 0 = mantissa * 2 ^ exponent'
      | otherwise = mantissa `div` (2 ^ negate exponent')

selectionSpec ∷ Spec
selectionSpec = describe "the current frame" $ do
  it "is floor (t / duration) mod count, from time 0" $
    [currentFrame t (tableOf 4 0.5) | t ← [0, 0.25, 0.5, 0.75, 1, 1.25, 2, 2.5, 3.75]]
      `shouldBe` [0, 0, 1, 1, 2, 2, 0, 1, 3]

  it "selects frame k mod count exactly on the boundary k × duration" $
    [currentFrame (fromIntegral k * 0.5) (tableOf 4 0.5) | k ← [0 .. 11 ∷ Int]]
      `shouldBe` [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3]

  it "selects the previous frame just before a boundary and the frame itself just after" $
    mapM_
      ( \k →
          let boundary = fromIntegral k * 2 ∷ Double
              table = tableOf 5 2
           in do
                currentFrame (below boundary) table `shouldBe` (toInteger k - 1) `mod` 5
                currentFrame boundary table `shouldBe` toInteger k `mod` 5
                currentFrame (above boundary) table `shouldBe` toInteger k `mod` 5
      )
      [1 .. 12 ∷ Int]

  it "wraps from frame count − 1 to frame 0" $ do
    currentFrame (below 3) (tableOf 3 1) `shouldBe` 2
    currentFrame 3 (tableOf 3 1) `shouldBe` 0
    currentFrame 1.5 (tableOf 1 1) `shouldBe` 0

  it "selects frame 0 for count 2, duration 8192, time 991231.9998, which a 32-bit phase would round up to frame 1" $ do
    -- 991231.9998 / 8192 is 120.99999997558594: the floor is 120, an even frame.
    currentFrame 991231.9998 (tableOf 2 8192) `shouldBe` 0
    referenceFrame 991231.9998 (tableOf 2 8192) `shouldBe` 0

  it "selects frame 2 for count 3, duration 2^127, time 2.5 × 2^127" $
    currentFrame (2.5 * 2 ^ (127 ∷ Int)) (tableOf 3 (2 ^ (127 ∷ Int))) `shouldBe` 2

  it "takes the quotient in Double without snapping to a boundary: duration 0.1, time 43 × 0.1" $ do
    -- 43 × 0.1 rounds, and divided by 0.1 gives 42.99999999999999: frame 42, even.
    let time = 43 * 0.1 ∷ Double
    time / 0.1 `shouldBe` 42.99999999999999
    currentFrame time (tableOf 2 0.1) `shouldBe` 0
    currentFrame time (tableOf 3 0.1) `shouldBe` 0
    currentFrame time (tableOf 5 0.1) `shouldBe` 2

  it "takes the floor of a quotient beyond 2^63 exactly, without overflow" $ do
    let table = tableOf 7 1
        big = 1.0e300 ∷ Double
    currentFrame big table `shouldBe` referenceFrame big table
    currentFrame big table `shouldBe` 1000000000000000052504760255204420248704468581108159154915854115511802457988908195786371375080447864043704443832883878176942523235360430575644792184786706982848387200926575803737830233794788090059368953234970799945081119038967640880074652742780142494579258788820056842838115669472196386865459400540160 `mod` 7
    currentFrame (2 ^ (70 ∷ Int)) (tableOf 3 1) `shouldBe` 2 ^ (70 ∷ Int) `mod` 3

  it "selects frame 0 for a table or a time with no quotient, which validation refuses" $ do
    currentFrame 1 (tableOf 0 1) `shouldBe` 0
    currentFrame 1 (FrameTable 3 0 []) `shouldBe` 0
    currentFrame (1 / 0) (tableOf 3 1) `shouldBe` 0
    currentFrame (0 / 0) (tableOf 3 1) `shouldBe` 0

  prop "agrees with the formula over generated tables and times, within the table" $
    forAll tableAndTime $ \(table, time) →
      let frame = currentFrame time table
       in counterexample (show (table {frameTableFrames = []}, time)) $
            conjoin [frame === referenceFrame time table, property (0 <= frame && frame < toInteger (frameTableCount table))]

-- | A table and a time: durations from tiny to enormous, times near 10^6
-- seconds and far beyond, and quotients past 2^63, every one finite.
tableAndTime ∷ Gen (FrameTable, Double)
tableAndTime = do
  count ← oneof [choose (1, 8), choose (1, 100000)]
  duration ← oneof [elements [0.1, 0.25, 0.5, 1, 8192, 1.0e-6, 2 ^ (100 ∷ Int), 1.0e-300], choose (1.0e-3, 1.0e3)]
  time ← oneof [choose (0, 1.0e6), choose (990000, 1.0e6), elements [0, 1, 991231.9998, 1.0e300, 2 ^ (200 ∷ Int)], (* duration) . fromIntegral <$> (choose (0, 100000) ∷ Gen Int)]
  let quotient = time / duration
  pure (tableOf count duration, if isInfinite quotient then 0 else time)

-- * Refusals

spec3 ∷ Instance
spec3 = framed 3

refusalSpec ∷ Spec
refusalSpec = describe "validation" $ do
  it "accepts a view with tables and a time, and instances selecting them" $
    refusedView (animatedView [tableOf 2 0.5, tableOf 3 1] 12.25 [WorldLayer DepthEnabled [framed 1, framed 2, plainInstance]]) `shouldBe` []

  it "accepts a time of zero, negative zero and a very large finite time" $ do
    refusedView (animatedView [tableOf 2 1] 0 []) `shouldBe` []
    refusedView (animatedView [tableOf 2 1] (-0.0) []) `shouldBe` []
    refusedView (animatedView [tableOf 2 1] 1.0e300 []) `shouldBe` []

  it "leaves a view with no table and an instance with no index as it was" $
    refusedView (plainView [UiLayer [plainInstance]]) `shouldBe` []

  it "refuses an index above 4095, naming the instance" $ do
    let tables = replicate 4096 (tableOf 1 1)
    -- Index 4096 names table 4095, which the view holds; 65535 is beyond them too.
    refusedView (animatedView tables 0 [UiLayer [framed 4095, framed 4096, framed 65535]])
      `shouldBe` [atInstance 1 FrameIndexTooLarge, atInstance 2 FrameIndexTooLarge, atInstance 2 FrameIndexUnknown]

  it "refuses an index above 4095 as well as unknown when the view holds too few tables" $
    refusedView (animatedView [tableOf 1 1] 0 [UiLayer [framed 4096]])
      `shouldBe` [atInstance 0 FrameIndexTooLarge, atInstance 0 FrameIndexUnknown]

  it "refuses an index beyond the view's tables, naming the instance" $ do
    refusedView (animatedView [tableOf 2 1, tableOf 2 1] 0 [WorldLayer DepthDisabled [framed 2, spec3, framed 1]])
      `shouldBe` [atInstance 1 FrameIndexUnknown]
    refusedView (animatedView [] 0 [UiLayer [framed 1]]) `shouldBe` [atInstance 0 FrameIndexUnknown]

  it "refuses an instance whose view is not the one that holds the table" $
    refusalsOf (Snapshot [windowPass [animatedView [tableOf 2 1] 0 [UiLayer [framed 1]], plainView [UiLayer [framed 1]]]])
      `shouldBe` [Refusal (AtInstance 0 1 0 0) FrameIndexUnknown]

  it "refuses a frame count of 0 or below" $ do
    refusedView (animatedView [FrameTable 0 1 []] 0 []) `shouldBe` [atTable 0 FrameCountInvalid]
    -- A negative count is no length the list can have.
    refusedView (animatedView [tableOf 1 1, FrameTable (-3) 1 []] 0 []) `shouldBe` [atTable 1 FrameCountInvalid, atTable 1 FrameUvCountMismatch]

  it "refuses a duration that is not finite and positive" $
    mapM_
      (\duration → refusedView (animatedView [FrameTable 1 duration [UvRect 0 0 1 1]] 0 []) `shouldBe` [atTable 0 FrameDurationInvalid])
      [0, -0.0, -1, 0 / 0, 1 / 0, -1 / 0]

  it "refuses a table whose count × duration is not finite" $ do
    refusedView (animatedView [tableOf 2 hugeDouble] 0 []) `shouldBe` [atTable 0 FrameCycleNotFinite]
    refusedView (animatedView [tableOf 3 (hugeDouble / 2)] 0 []) `shouldBe` [atTable 0 FrameCycleNotFinite]
    -- The largest cycle that is finite is admitted.
    refusedView (animatedView [tableOf 2 (hugeDouble / 2)] 0 []) `shouldBe` []

  it "refuses a table whose time ÷ duration is not finite" $ do
    refusedView (animatedView [tableOf 1 1.0e-10] 1.0e300 []) `shouldBe` [atTable 0 FramePhaseNotFinite]
    refusedView (animatedView [tableOf 1 5.0e-324] 1 []) `shouldBe` [atTable 0 FramePhaseNotFinite]
    -- The same table at a time with a finite quotient is admitted.
    refusedView (animatedView [tableOf 1 1.0e-10] 1.0e298 []) `shouldBe` []

  it "refuses a list of rectangles that is not as long as the count" $ do
    refusedView (animatedView [FrameTable 3 1 [UvRect 0 0 1 1, UvRect 0 0 1 1]] 0 []) `shouldBe` [atTable 0 FrameUvCountMismatch]
    refusedView (animatedView [FrameTable 1 1 [UvRect 0 0 1 1, UvRect 0 0 1 1]] 0 []) `shouldBe` [atTable 0 FrameUvCountMismatch]

  it "refuses a rectangle with a value that is not finite" $
    mapM_
      ( \bad →
          refusedView (animatedView [tableOf 1 1, FrameTable 2 1 [UvRect 0 0 1 1, bad]] 0 [])
            `shouldBe` [atTable 1 FrameUvNotFinite]
      )
      [UvRect (0 / 0) 0 1 1, UvRect 0 (1 / 0) 1 1, UvRect 0 0 (-1 / 0) 1, UvRect 0 0 1 (0 / 0)]

  it "refuses a time that is NaN, infinite or negative, naming the view" $
    mapM_
      (\time → refusedView (animatedView [tableOf 2 1] time []) `shouldBe` [atView AnimationTimeInvalid])
      [0 / 0, 1 / 0, -1 / 0, -1, -1.0e-300]

  it "does not repeat a cause: a bad duration is not also a bad cycle or quotient, a bad time not also a bad quotient" $ do
    refusedView (animatedView [FrameTable 2 0 [UvRect 0 0 1 1, UvRect 0 0 1 1]] 1 []) `shouldBe` [atTable 0 FrameDurationInvalid]
    refusedView (animatedView [tableOf 2 1] (0 / 0) []) `shouldBe` [atView AnimationTimeInvalid]
    refusedView (animatedView [FrameTable 0 1 []] 1 []) `shouldBe` [atTable 0 FrameCountInvalid]

  it "reports every refusal of a table, in the order the reasons list them" $
    refusedView (animatedView [FrameTable 2 (0 / 0) [UvRect (0 / 0) 0 0 0]] 0 [])
      `shouldBe` [atTable 0 FrameDurationInvalid, atTable 0 FrameUvCountMismatch, atTable 0 FrameUvNotFinite]

  it "checks every table, whether or not an instance uses it" $
    refusedView (animatedView [FrameTable 0 1 [], tableOf 1 1, FrameTable 1 (-1) [UvRect 0 0 1 1]] 0 [UiLayer [framed 2]])
      `shouldBe` [atTable 0 FrameCountInvalid, atTable 2 FrameDurationInvalid]

  it "checks the tables and the time of a view in a zero-size viewport, and of a view with no layers" $ do
    let zero = Viewport (V2 0 0) (V2 0 0)
        zeroView tables time layers = ViewWith plainCamera zero defaultViewSettings [] Map.empty tables time layers
    refusalsOf (snapshotOfView (zeroView [FrameTable 0 1 [], tableOf 1 (0 / 0)] (-1) []))
      `shouldBe` [atView AnimationTimeInvalid, atTable 0 FrameCountInvalid, atTable 1 FrameDurationInvalid]
    refusalsOf (snapshotOfView (zeroView [] 0 [UiLayer [framed 1]])) `shouldBe` [atInstance 0 FrameIndexUnknown]

  it "puts a view's time and tables after its clip table and before its layers" $
    refusalsOf
      ( snapshotOfView
          ( ViewWith
              plainCamera
              plainViewport
              defaultViewSettings
              [ClipEntry (ClipRect (V2 0 0) (V2 (-1) 1)) Nothing]
              Map.empty
              [FrameTable 0 1 []]
              (-1)
              [UiLayer [plainInstance {instanceDepthKey = depthKeyLimit}]]
          )
      )
      `shouldBe` [ Refusal (AtClipEntry 0 0 0) ClipRectInvalid
                 , atView AnimationTimeInvalid
                 , atTable 0 FrameCountInvalid
                 , atInstance 0 DepthKeyTooLarge
                 ]

-- * Retained chunks

chunkOf ∷ [Instance] → Chunk
chunkOf = either (error . ("the chunk was refused: " <>) . show) id . buildChunk noCutoutMarks ChunkUi DeriveBounds

chunkSpec ∷ Spec
chunkSpec = describe "retained references" $ do
  it "refuses at build an instance whose index is above 4095, naming the instance" $ do
    buildChunk noCutoutMarks ChunkUi DeriveBounds [framed 4095, framed 4096]
      `shouldBe'` Left (ChunkInstanceInvalid 1 FrameIndexTooLarge :| [])
    buildChunk noCutoutMarks ChunkWorldDepth DeriveBounds [framed 65535]
      `shouldBe'` Left (ChunkInstanceInvalid 0 FrameIndexTooLarge :| [])

  it "builds a chunk whose indices are 4095 or below, with no view to check them against" $
    mapM_ (\kind → either (const False) (const True) (buildChunk noCutoutMarks kind DeriveBounds [framed 4095, framed 1]) `shouldBe` True) [minBound .. maxBound]

  it "records the largest index and the first instance carrying it" $ do
    chunkLargestFrameIndex (chunkOf [plainInstance, framed 3, framed 5, framed 2, framed 5, plainInstance]) `shouldBe` Just (5, 2)
    chunkLargestFrameIndex (chunkOf [framed 1]) `shouldBe` Just (1, 0)
    chunkLargestFrameIndex (chunkOf [framed 4095, framed 4095]) `shouldBe` Just (4095, 0)

  it "records nothing for a chunk with no animated instance, or no instance" $ do
    chunkLargestFrameIndex (chunkOf [plainInstance, plainInstance]) `shouldBe` Nothing
    chunkLargestFrameIndex (either (error . show) id (buildChunk noCutoutMarks ChunkUi (SuppliedBounds (Bounds (V2 0 0) (V2 1 1))) [])) `shouldBe` Nothing

  it "is checked against the tables of each view that lists the chunk, naming the view, layer, chunk and instance" $ do
    let chunk = chunkOf [plainInstance, framed 2, framed 3, framed 3]
        reference = chunkRef 4 1
        listing = UiLayerWith [reference] []
        enough = animatedView [tableOf 1 1, tableOf 1 1, tableOf 1 1] 0 [listing]
        short = animatedView [tableOf 1 1, tableOf 1 1] 0 [UiLayer [], UiLayerWith [chunkRef 4 1] []]
        snapshot = Snapshot [windowPass [enough, short]]
    validateSnapshotWith (chunksFrom [(reference, chunk)]) snapshot
      `shouldBe'` Left (Refusal (AtChunkInstance 0 1 1 0 2) FrameIndexUnknown :| [])

  it "is refused for a view with no tables at all, and accepted once the view holds enough" $ do
    let chunk = chunkOf [framed 1]
        reference = chunkRef 1 1
    validateSnapshotWith (chunksFrom [(reference, chunk)]) (snapshotOfView (plainView [UiLayerWith [reference] []]))
      `shouldBe'` Left (Refusal (AtChunkInstance 0 0 0 0 0) FrameIndexUnknown :| [])
    either (const False) (const True) (validateSnapshotWith (chunksFrom [(reference, chunk)]) (snapshotOfView (animatedView [tableOf 1 1] 0 [UiLayerWith [reference] []])))
      `shouldBe` True

  it "is checked for a chunk the view would cull, and in a zero-size viewport" $ do
    let chunk = chunkOf [(framed 2) {instanceTransform = fromColumns (V2 1 0) (V2 0 1) (V2 1.0e9 1.0e9)}]
        reference = chunkRef 1 1
        far = animatedView [tableOf 1 1] 0 [UiLayerWith [reference] []]
        zero = ViewWith plainCamera (Viewport (V2 0 0) (V2 0 0)) defaultViewSettings [] Map.empty [tableOf 1 1] 0 [UiLayerWith [reference] []]
        expected = Refusal (AtChunkInstance 0 0 0 0 0) FrameIndexUnknown :| []
    validateSnapshotWith (chunksFrom [(reference, chunk)]) (snapshotOfView far) `shouldBe'` Left expected
    validateSnapshotWith (chunksFrom [(reference, chunk)]) (snapshotOfView zero) `shouldBe'` Left expected

  it "leaves the other chunk refusals as they were" $ do
    let chunk = chunkOf [framed 1]
        listing = UiLayerWith [chunkRef 9 9] []
    validateSnapshotWith (chunksFrom [(chunkRef 1 1, chunk)]) (snapshotOfView (animatedView [tableOf 1 1] 0 [listing]))
      `shouldBe'` Left (Refusal (AtChunk 0 0 0 0 (chunkRef 9 9)) ChunkUnresolved :| [])

  it "refuses a chunk listed twice at each listing" $ do
    let chunk = chunkOf [framed 2]
        reference = chunkRef 1 1
    validateSnapshotWith (chunksFrom [(reference, chunk)]) (snapshotOfView (animatedView [tableOf 1 1] 0 [UiLayerWith [reference, reference] []]))
      `shouldBe'` Left (Refusal (AtChunkInstance 0 0 0 0 0) FrameIndexUnknown :| [Refusal (AtChunkInstance 0 0 0 1 0) FrameIndexUnknown])
  where
    shouldBe' actual expected = actual `shouldBe` expected

-- * Flags and the 64-byte instance

flagsSpec ∷ Spec
flagsSpec = describe "the frame-table index in the flags word" $ do
  it "occupies bits 4 to 15, so a shader reads it as (flags >> 4) & 0xFFF" $
    mapM_
      (\(index, expected) → flagsWord (framed index) `shouldBe` expected)
      [ (0, 0x00000000)
      , (1, 0x00000010)
      , (2, 0x00000020)
      , (0x00F, 0x000000F0)
      , (0x0FF, 0x00000FF0)
      , (0x100, 0x00001000)
      , (0x123, 0x00001230)
      , (0x800, 0x00008000)
      , (4095, 0x0000FFF0)
      ]

  it "leaves the sampler, translucent, additive and clip fields alone" $ do
    flagsWord (framed 0xABC) {instanceSampler = SamplerLinear, instanceTranslucent = True, instanceAdditive = True, instanceClip = 0x1234}
      `shouldBe` 0x1234ABCE
    flagsWord (framed 4095) {instanceSampler = SamplerNearest, instanceClip = 0xFFFF} `shouldBe` 0xFFFFFFF1
    flagsWord (framed 1) {instanceClip = 1, instanceAdditive = True} `shouldBe` 0x00010018

  it "writes only the low 12 bits of an index validation would refuse, on an unvalidated instance" $
    mapM_
      ( \(index, clip, expected) →
          flagsWord (framed index) {instanceClip = clip, instanceSampler = SamplerLinear} `shouldBe` expected
      )
      [ (4096, 0, 0x00000002)
      , (4096, 0x1234, 0x12340002)
      , (4097, 0, 0x00000012)
      , (65535, 0, 0x0000FFF2)
      , (65535, 0xFFFF, 0xFFFFFFF2)
      , (65535, 0x0001, 0x0001FFF2)
      , (0x8000, 0x4321, 0x43210002)
      , (0xF000, 0, 0x00000002)
      ]

  it "never reaches the clip index or bits 0 to 3, whatever the index" $
    mapM_
      ( \index →
          let flagsBase = flagsWord plainInstance {instanceSampler = SamplerNearest, instanceTranslucent = True, instanceClip = 0xBEEF}
              flagsFramed = flagsWord (framed index) {instanceSampler = SamplerNearest, instanceTranslucent = True, instanceClip = 0xBEEF}
           in (flagsFramed `shouldBe`) (flagsBase + (fromIntegral (index `mod` 4096) `shiftL` 4))
      )
      [0, 1, 4095, 4096, 4097, 8191, 8192, 40000, 65535]

-- | The 64 bytes an instance with a frame-table index encodes to, in a view that
-- holds the table.
encodingSpec ∷ Spec
encodingSpec = describe "the 64-byte instance" $ do
  it "keeps the stride and every other field's offset, with the index in the flags at byte 56" $ do
    let tables = [tableOf 1 1, tableOf 2 1, tableOf 3 1]
        candidate =
          plainInstance
            { instanceTransform = fromColumns (V2 2 3) (V2 5 7) (V2 11 13)
            , instanceUv = UvRect 0.25 0.5 0.75 1.0
            , instanceTexture = textureHandle 0x01020304 0x0A0B0C0D
            , instanceDepthKey = 0x00ABCDEF
            , instanceTint = Tint 0x11 0x22 0x33 0x44
            , instanceSampler = SamplerLinear
            , instanceTranslucent = True
            , instanceAdditive = True
            , instanceFrameTable = 3
            , instanceParameter = 0xDEADBEEF
            , instanceMaterial = materialRef 7 (MaterialFacts False (RecordLayout 0 0) 0)
            }
        expected =
          concat
            [ [0x00, 0x00, 0x00, 0x40] -- 0: a = 2.0
            , [0x00, 0x00, 0x40, 0x40] -- 4: b = 3.0
            , [0x00, 0x00, 0xA0, 0x40] -- 8: c = 5.0
            , [0x00, 0x00, 0xE0, 0x40] -- 12: d = 7.0
            , [0x00, 0x00, 0x30, 0x41] -- 16: tx = 11.0
            , [0x00, 0x00, 0x50, 0x41] -- 20: ty = 13.0
            , [0x00, 0x00, 0x80, 0x3E] -- 24: u0 = 0.25
            , [0x00, 0x00, 0x00, 0x3F] -- 28: v0 = 0.5
            , [0x00, 0x00, 0x40, 0x3F] -- 32: u1 = 0.75
            , [0x00, 0x00, 0x80, 0x3F] -- 36: v1 = 1.0
            , [0x04, 0x03, 0x02, 0x01] -- 40: handle index
            , [0x0D, 0x0C, 0x0B, 0x0A] -- 44: handle generation
            , [0xEF, 0xCD, 0xAB, 0x00] -- 48: depth key
            , [0x11, 0x22, 0x33, 0x44] -- 52: tint
            , [0x3E, 0x00, 0x00, 0x00] -- 56: flags: linear 2 | translucent 4 | additive 8 | frame table 3 << 4
            , [0xEF, 0xBE, 0xAD, 0xDE] -- 60: material word
            ] ∷ [Word8]
        view = animatedView tables 1.5 [UiLayer [candidate]]
    case validateSnapshot (snapshotOfView view) of
      Left refused → fail' (show refused)
      Right valid → case validLayers valid of
        [layer] → ByteString.unpack (encodeLayer layer) `shouldBe` expected
        other → fail' ("expected one layer, found " <> show (length other))

  it "encodes the index of every instance of a layer, animated or not, at its own 64 bytes" $ do
    let view = animatedView [tableOf 1 1, tableOf 1 1] 0 [UiLayer [framed 2, plainInstance, framed 1]]
    case validateSnapshot (snapshotOfView view) of
      Left refused → fail' (show refused)
      Right valid → case validLayers valid of
        [layer] → do
          let bytes = ByteString.unpack (encodeLayer layer)
          length bytes `shouldBe` 192
          [bytes !! (64 * n + 56) | n ← [0, 1, 2]] `shouldBe` [0x20, 0x00, 0x10]
          [bytes !! (64 * n + 57) | n ← [0, 1, 2]] `shouldBe` [0, 0, 0]
        other → fail' ("expected one layer, found " <> show (length other))
  where
    fail' = error
