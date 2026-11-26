-- | One known column segment: at most 32 consecutive levels of packed cells in
-- the smallest of three encodings.
--
-- A segment covers @[start, start + length)@ with @1 <= length <= 32@, entirely
-- inside one vertical region (a 32-level, 32-aligned stretch of Z). It stores
-- only those cells; what lies above or below is not in it. A packed cell is 17
-- bits (see "Hetoimasia.Terrain.Palette"): a 16-bit word and a family tag. For
-- @N@ cells, @R@ runs of equal adjacent values (the tag is part of the value, so
-- side 15 and corner 15 of one material are two runs) and @D@ the dense payload
-- ('segmentPayloadBytes' of the dense form: @2 * N@ bytes, and @ceil (N / 8)@
-- more for the tag bits when some cell is a corner), the value encoding is
-- chosen once, when the segment is built, by exactly this rule:
--
-- * @R = 1@: 'Uniform', one value for the whole interval (2 bytes, or 3 when it
--   is a corner);
-- * otherwise @4 * R < D@: 'Runs', one 32-bit word per run holding the run's
--   exclusive end offset (@1 .. 32@) from bit 17 up and its 17-bit value in the
--   low 17 bits, ascending and with adjacent equal values coalesced (@4 * R@
--   bytes);
-- * otherwise 'Dense', the 16-bit words of the @N@ cells and, only when some cell
--   is a corner, one tag bit per cell (@D@ bytes), so a tie goes to direct
--   indexing.
--
-- A segment holding no corner is charged and encoded exactly as it was when a
-- packed cell was 16 bits. The largest payload any segment can have is
-- 'maxSegmentPayloadBytes', that of a dense 32-cell segment with a corner.
--
-- Uniform and dense lookups index directly; a runs lookup is a binary search,
-- and a nonuniform 32-cell segment that selects runs has at most 16 of them.
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
  , maxSegmentPayloadBytes
  , decodedCellBytes
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
import Data.Bits (setBit, shiftL, shiftR, testBit, (.&.), (.|.))
import Data.Int (Int64)
import qualified Data.List.NonEmpty as NE
import Data.Word (Word32, Word8)
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Internal.Coordinate (AxisCoord (..))
import Hetoimasia.Terrain.Internal.Packed (PackedCell (..))
import Hetoimasia.Terrain.Palette (packedBits)

-- | The most levels one segment covers.
maxSegmentLevels ∷ Int
maxSegmentLevels = 32

-- | The most payload bytes any segment has: a dense segment of 'maxSegmentLevels'
-- cells, two bytes each, with a tag bit for each.
maxSegmentPayloadBytes ∷ Int
maxSegmentPayloadBytes = 2 * maxSegmentLevels + (maxSegmentLevels + 7) `div` 8

-- | The bytes one decoded cell occupies in scratch: a 'PackedCell' is a 32-bit
-- value, whatever its 17 significant bits.
decodedCellBytes ∷ Int
decodedCellBytes = 4

-- | How a segment's values are stored.
data Encoding = Uniform | Runs | Dense
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The values are stored in exactly the bytes 'segmentPayloadBytes' charges. A
-- uniform payload is the value's two little-endian bytes of its 16-bit word and
-- a third, set to 1, for a corner. A run word holds the end offset from bit 17
-- and the 17-bit value below it. A dense payload is the @N@ 16-bit words, two
-- little-endian bytes each, and, only when some cell is a corner, @ceil (N / 8)@
-- more bytes holding one tag bit per cell, bit @i mod 8@ of byte @i div 8@.
data Payload
  = PUniform !(UArray Int Word8)
  | PRuns !(UArray Int Word32)
  | PDense !(UArray Int Word8)
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
    | otherwise → Right (Segment start n (encode (map packedBits seen)))
    where
      n = length seen

regionOf ∷ Int64 → Int64
regionOf z = z `div` fromIntegral maxSegmentLevels

-- | Choose the encoding by the stated rule and build its payload.
encode ∷ [Word32] → Payload
encode values = case runs of
  [(_, v)] → PUniform (bytesOf (uniformBytes v))
  _
    | 4 * r < denseSize n anyCorner → PRuns (listArray (0, r - 1) [fromIntegral e `shiftL` runValueBits .|. v | (e, v) ← runs])
    | otherwise → PDense (bytesOf (denseContent n anyCorner values))
  where
    n = length values
    r = length runs
    anyCorner = any (`testBit` cornerBit) values
    runs = runEnds 0 (NE.group values)
    runEnds _ [] = []
    runEnds off (g : gs) = let e = off + NE.length g in (e, NE.head g) : runEnds e gs

bytesOf ∷ [Word8] → UArray Int Word8
bytesOf bytes = listArray (0, length bytes - 1) bytes

-- | The two little-endian bytes of a 16-bit word, and a third for a corner.
uniformBytes ∷ Word32 → [Word8]
uniformBytes v = wordBytes v <> [1 | testBit v cornerBit]

wordBytes ∷ Word32 → [Word8]
wordBytes v = [fromIntegral v, fromIntegral (v `shiftR` 8)]

-- | The dense bytes of the values: every 16-bit word, then the tag bytes if some
-- cell is a corner.
denseContent ∷ Int → Bool → [Word32] → [Word8]
denseContent n anyCorner values = concatMap wordBytes values <> (if anyCorner then tagBytes else [])
  where
    tagBytes = [foldr (\(i, v) acc → if testBit v cornerBit then setBit acc i else acc) 0 (zip [0 ..] chunk) | chunk ← chunksOf8 (take n values)]
    chunksOf8 [] = []
    chunksOf8 xs = let (h, t) = splitAt 8 xs in h : chunksOf8 t

-- | The bit that tags a corner value.
cornerBit ∷ Int
cornerBit = 16

-- | The width of a value inside a run word; the end offset sits above it.
runValueBits ∷ Int
runValueBits = 17

-- | The dense payload bytes of @n@ cells, with the tag bits when some cell is a
-- corner.
denseSize ∷ Int → Bool → Int
denseSize n anyCorner = 2 * n + (if anyCorner then (n + 7) `div` 8 else 0)

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
-- offset (@1 .. 32@, from the segment's start) from bit 17 up and its 17-bit
-- value, tag included, in the low 17 bits. Empty for the other two encodings.
segmentRunWords ∷ Segment → [Word32]
segmentRunWords (Segment _ _ (PRuns runs)) = elems runs
segmentRunWords _ = []

-- | The bytes of the encoded values alone: 2 for uniform (3 for a corner), 4 per
-- run, and for dense 2 per cell plus one tag bit per cell when some cell is a
-- corner. Start, length and the encoding tag are not included.
segmentPayloadBytes ∷ Segment → Int
segmentPayloadBytes (Segment _ _ payload) = case payload of
  PUniform bytes → byteCount bytes
  PRuns runs → 4 * (let (lo, hi) = bounds runs in hi - lo + 1)
  PDense bytes → byteCount bytes
  where
    byteCount bytes = let (lo, hi) = bounds bytes in hi - lo + 1

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
    valueAt (PUniform bytes) _ = PackedCell (wordAt bytes 0 .|. (if snd (bounds bytes) >= 2 then 1 `shiftL` cornerBit else 0))
    valueAt (PDense bytes) i = PackedCell (wordAt bytes i .|. (if snd (bounds bytes) >= 2 * n && testBit (bytes ! (2 * n + i `div` 8)) (i `mod` 8) then 1 `shiftL` cornerBit else 0))
    valueAt (PRuns runs) i = PackedCell (runs ! search runs i .&. runValueMask)
    wordAt bytes i = fromIntegral (bytes ! (2 * i)) .|. (fromIntegral (bytes ! (2 * i + 1)) `shiftL` 8)
    runValueMask = (1 `shiftL` runValueBits) - 1
    -- The first run whose exclusive end is above the offset.
    search runs i = go lo0 hi0
      where
        (lo0, hi0) = bounds runs
        go lo hi
          | lo >= hi = lo
          | otherwise =
              let mid = (lo + hi) `div` 2
               in if fromIntegral (runs ! mid `shiftR` runValueBits) > i then go lo mid else go (mid + 1) hi

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
