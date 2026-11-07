-- | One known column segment: at most 32 consecutive levels of packed cells in
-- the smallest of three encodings.
--
-- A segment covers @[start, start + length)@ with @1 <= length <= 32@, entirely
-- inside one vertical region (a 32-level, 32-aligned stretch of Z). It stores
-- only those cells; what lies above or below is not in it. For @N@ cells and
-- @R@ runs of equal adjacent values the value encoding is chosen once, when the
-- segment is built, by exactly this rule:
--
-- * @R = 1@: 'Uniform', one 16-bit value for the whole interval (2 bytes);
-- * otherwise @4 * R < 2 * N@: 'Runs', one 32-bit word per run holding the
--   run's exclusive end offset in its high half and its 16-bit value in its low
--   half, ascending and with adjacent equal values coalesced (@4 * R@ bytes);
-- * otherwise 'Dense', exactly @N@ 16-bit values (@2 * N@ bytes), so a tie goes
--   to direct indexing.
--
-- Uniform and dense lookups index directly; a runs lookup is a binary search,
-- and a nonuniform 32-cell segment that selects runs has at most 15 of them.
-- The payload bytes ('segmentPayloadBytes') count the values only. The start,
-- length and encoding tag are metadata, accounted separately by
-- 'segmentMetadataBytes', and the Haskell heap costs of the representation are
-- neither of those: measure them, do not read them from here.
--
-- Updating a segment ('updateSegment') decodes at most 32 values into scratch,
-- applies the changes and builds a fresh segment, choosing its encoding once.
-- The result shares no mutable buffer with its predecessor, and the
-- predecessor stays valid and unchanged.
--
-- State, ownership and lifetime: none. Every segment is immutable and every
-- function pure.
module Hetoimasia.Terrain.Segment
  ( Segment
  , Encoding (..)
  , SegmentError (..)
  , maxSegmentLevels
  , buildSegment
  , updateSegment
  , segmentStart
  , segmentLength
  , segmentEnd
  , segmentEncoding
  , segmentPayloadBytes
  , segmentMetadataBytes
  , segmentRunCount
  , segmentRunWords
  , segmentLookup
  , segmentCells
  , segmentSlice
  ) where

import Data.Array.Unboxed (UArray, bounds, elems, listArray, (!))
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Int (Int64)
import qualified Data.List.NonEmpty as NE
import Data.Word (Word16, Word32)
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Internal.Coordinate (AxisCoord (..))
import Hetoimasia.Terrain.Internal.Packed (PackedCell (..))
import Hetoimasia.Terrain.Palette (packedWord)

-- | The most levels one segment covers.
maxSegmentLevels ∷ Int
maxSegmentLevels = 32

-- | How a segment's values are stored.
data Encoding = Uniform | Runs | Dense
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data Payload
  = PUniform !Word16
  | PRuns !(UArray Int Word32)
  | PDense !(UArray Int Word16)
  deriving stock (Eq, Show)

-- | A known stretch of one column. The constructor is private.
data Segment = Segment !Int64 !Int !Payload
  deriving stock (Eq, Show)

-- | Why a segment could not be built or updated.
data SegmentError
  = -- | No cells.
    EmptySegment
  | -- | More than 'maxSegmentLevels' cells; the field is the number seen, at
    -- least 33.
    SegmentTooLong !Int
  | -- | The cells would leave the vertical region containing the first.
    SegmentCrossesRegion
  | -- | An update names a level the segment does not cover.
    LevelNotInSegment !Int64
  deriving stock (Eq, Show)

-- | Build a segment from cells in ascending level order, starting at a level.
-- The encoding is chosen once from the whole content. Only the first 33 cells
-- are examined, so an oversized list is refused without being traversed.
buildSegment ∷ AxisCoord → [PackedCell] → Either SegmentError Segment
buildSegment (AxisCoord start) cells = case take (maxSegmentLevels + 1) cells of
  [] → Left EmptySegment
  seen
    | n > maxSegmentLevels → Left (SegmentTooLong n)
    | regionOf start /= regionOf (start + fromIntegral n - 1) → Left SegmentCrossesRegion
    | otherwise → Right (Segment start n (encode (map packedWord seen)))
    where
      n = length seen

regionOf ∷ Int64 → Int64
regionOf z = z `div` fromIntegral maxSegmentLevels

-- | Choose the encoding by the stated rule and build its payload.
encode ∷ [Word16] → Payload
encode values = case runs of
  [(_, v)] → PUniform v
  _
    | 4 * r < 2 * n → PRuns (listArray (0, r - 1) [fromIntegral e `shiftL` 16 .|. fromIntegral v | (e, v) ← runs])
    | otherwise → PDense (listArray (0, n - 1) values)
  where
    n = length values
    r = length runs
    runs = runEnds 0 (NE.group values)
    runEnds _ [] = []
    runEnds off (g : gs) = let e = off + NE.length g in (e, NE.head g) : runEnds e gs

-- | The first level covered.
segmentStart ∷ Segment → AxisCoord
segmentStart (Segment start _ _) = AxisCoord start

-- | The number of levels covered, @1 .. 32@.
segmentLength ∷ Segment → Int
segmentLength (Segment _ n _) = n

-- | One past the last level covered, as an exact integer.
segmentEnd ∷ Segment → Integer
segmentEnd (Segment start n _) = toInteger start + toInteger n

-- | The selected value encoding.
segmentEncoding ∷ Segment → Encoding
segmentEncoding (Segment _ _ payload) = case payload of
  PUniform _ → Uniform
  PRuns _ → Runs
  PDense _ → Dense

-- | The number of runs a runs encoding stores, and 'Nothing' for the other two.
segmentRunCount ∷ Segment → Maybe Int
segmentRunCount (Segment _ _ (PRuns runs)) = Just (let (lo, hi) = bounds runs in hi - lo + 1)
segmentRunCount _ = Nothing

-- | The stored run words of a runs encoding, in order: the run's exclusive end
-- offset (@1 .. 32@, from the segment's start) in the high 16 bits and its value
-- in the low 16. Empty for the other two encodings.
segmentRunWords ∷ Segment → [Word32]
segmentRunWords (Segment _ _ (PRuns runs)) = elems runs
segmentRunWords _ = []

-- | The bytes of the encoded values alone: 2 for uniform, 4 per run, 2 per cell
-- for dense. Start, length and the tag are not included.
segmentPayloadBytes ∷ Segment → Int
segmentPayloadBytes (Segment _ n payload) = case payload of
  PUniform _ → 2
  PRuns runs → 4 * (let (lo, hi) = bounds runs in hi - lo + 1)
  PDense _ → 2 * n

-- | The conservative accounted bytes of a segment's own metadata: its start, its
-- length, its encoding tag and the reference to its payload. An accounting
-- figure for admission, not a heap measurement.
segmentMetadataBytes ∷ Segment → Int
segmentMetadataBytes _ = 32

-- | The value at a level, or 'Nothing' if the level is outside the segment.
-- Uniform and dense are direct; runs use binary search.
segmentLookup ∷ Segment → AxisCoord → Maybe PackedCell
segmentLookup (Segment start n payload) (AxisCoord z)
  | offset < 0 || offset >= fromIntegral n = Nothing
  | otherwise = Just (valueAt payload (fromIntegral offset))
  where
    offset = z - start
    valueAt (PUniform v) _ = PackedCell v
    valueAt (PDense values) i = PackedCell (values ! i)
    valueAt (PRuns runs) i = PackedCell (runValue runs (search runs i))
    runValue runs j = fromIntegral (runs ! j .&. 0xffff)
    -- The first run whose exclusive end is above the offset.
    search runs i = go lo0 hi0
      where
        (lo0, hi0) = bounds runs
        go lo hi
          | lo >= hi = lo
          | otherwise =
              let mid = (lo + hi) `div` 2
               in if fromIntegral (runs ! mid `shiftR` 16) > i then go lo mid else go (mid + 1) hi

-- | Every value in level order, decoded into at most 32 elements.
segmentCells ∷ Segment → [PackedCell]
segmentCells segment@(Segment start n _) =
  [c | i ← [0 .. n - 1], Just c ← [segmentLookup segment (AxisCoord (start + fromIntegral i))]]

-- | The values in @[lo, hi)@ clipped to the segment, with the first level
-- covered; 'Nothing' if the interval misses the segment.
segmentSlice ∷ Segment → Int64 → Int64 → Maybe (AxisCoord, [PackedCell])
segmentSlice segment@(Segment start n _) lo hi
  | a >= b = Nothing
  | otherwise = Just (AxisCoord a, take (fromIntegral (b - a)) (drop (fromIntegral (a - start)) (segmentCells segment)))
  where
    a = max lo start
    b = min hi (start + fromIntegral n)

-- | Replace the values at some levels and build a new segment, choosing its
-- encoding once. A level outside the segment is refused and nothing is built.
updateSegment ∷ Segment → [(AxisCoord, PackedCell)] → Either SegmentError Segment
updateSegment segment@(Segment start n _) changes = do
  mapM_ (check . fst) changes
  buildSegment (AxisCoord start) (apply (segmentCells segment))
  where
    check (AxisCoord z)
      | z < start || z >= start + fromIntegral n = Left (LevelNotInSegment z)
      | otherwise = Right ()
    apply cells = [lastWins (start + fromIntegral i) c | (i, c) ← zip [0 ∷ Int ..] cells]
    lastWins z c = case [v | (AxisCoord w, v) ← changes, w == z] of
      [] → c
      vs → last vs
