-- | One BC7 block's sixteen texels, as the BC7 format defines them.
--
-- A block is 128 bits, read little-endian. Its first set bit names its mode,
-- 0 to 7; a block whose first byte is zero has no valid mode, and every
-- channel of every texel is zero. After the mode come, in this order and
-- each least significant bit first: the partition, the rotation and the
-- index selection, where the mode has them; every endpoint's red, then
-- green, then blue, then alpha; the p-bits; and the indices, texel 0 first,
-- with each subset's anchor texel one bit shorter. Endpoints are expanded to
-- eight bits by replicating their high bits, texels are interpolated between
-- their subset's two endpoints with the format's 6-bit weights, and modes 4
-- and 5 then swap alpha with the channel their rotation names.
module Hetoimasia.Asset.Image.Internal.Bc7Block
  ( Texel (..)
  , blockTexel
  )
where

import Data.Bits (complement, countTrailingZeros, shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Unsafe as ByteString
import qualified Data.Vector.Unboxed as Vector
import Data.Word (Word16, Word64, Word8)

-- | One decoded texel: R, G, B, A.
data Texel = Texel !Word8 !Word8 !Word8 !Word8
  deriving (Eq, Show)

-- | The texels of the block at this byte offset, by texel number: texel @i@
-- is column @i mod 4@ of row @i div 4@. The block's header and endpoints are
-- read once, when the function is applied to its offset. The caller
-- guarantees sixteen bytes at the offset.
blockTexel ∷ ByteString → Int → Int → Texel
blockTexel bytes offset = case countTrailingZeros (fromIntegral lo ∷ Word8) of
  0 → modeTexel lo hi mode0
  1 → modeTexel lo hi mode1
  2 → modeTexel lo hi mode2
  3 → modeTexel lo hi mode3
  4 → modeTexel lo hi mode4
  5 → modeTexel lo hi mode5
  6 → modeTexel lo hi mode6
  7 → modeTexel lo hi mode7
  _ → const (Texel 0 0 0 0)
  where
    lo = word64 offset
    hi = word64 (offset + 8)
    word64 at = foldr (\i acc → acc `shiftL` 8 .|. fromIntegral (ByteString.unsafeIndex bytes (at + i))) 0 [0 .. 7]

-- | A mode's fields, as the BC7 format's mode table gives them.
data Mode = Mode
  { modeNumber ∷ !Int
  , modeSubsets ∷ !Int
  , partitionBits ∷ !Int
  , rotationBits ∷ !Int
  , selectionBits ∷ !Int
  , colourBits ∷ !Int
  , alphaBits ∷ !Int
  , endpointPBits ∷ !Bool
  , sharedPBits ∷ !Bool
  , indexBits ∷ !Int
  , secondaryIndexBits ∷ !Int
  }

mode0, mode1, mode2, mode3, mode4, mode5, mode6, mode7 ∷ Mode
mode0 = Mode 0 3 4 0 0 4 0 True False 3 0
mode1 = Mode 1 2 6 0 0 6 0 False True 3 0
mode2 = Mode 2 3 6 0 0 5 0 False False 2 0
mode3 = Mode 3 2 6 0 0 7 0 True False 2 0
mode4 = Mode 4 1 0 2 1 5 6 False False 2 3
mode5 = Mode 5 1 0 2 0 7 8 False False 2 2
mode6 = Mode 6 1 0 0 0 7 7 True False 4 0
mode7 = Mode 7 2 6 0 0 5 5 True False 2 0

-- | An endpoint, expanded to eight bits per channel.
data Endpoint = Endpoint !Int !Int !Int !Int

modeTexel ∷ Word64 → Word64 → Mode → Int → Texel
modeTexel lo hi mode = texel
  where
    field ∷ Int → Int → Int
    field = bits lo hi

    subsets = modeSubsets mode
    partitionAt = modeNumber mode + 1
    partition = field partitionAt (partitionBits mode)
    rotation = field (partitionAt + partitionBits mode) (rotationBits mode)
    selection = field (partitionAt + partitionBits mode + rotationBits mode) (selectionBits mode)
    endpointsAt = partitionAt + partitionBits mode + rotationBits mode + selectionBits mode
    endpointCount = 2 * subsets

    -- Channel c of endpoint e, before its p-bit.
    raw c e
      | c < 3 = field (endpointsAt + (c * endpointCount + e) * colourBits mode) (colourBits mode)
      | otherwise = field (endpointsAt + 3 * endpointCount * colourBits mode + e * alphaBits mode) (alphaBits mode)
    pBitsAt = endpointsAt + endpointCount * (3 * colourBits mode + alphaBits mode)
    pBit e
      | endpointPBits mode = Just (field (pBitsAt + e) 1)
      | sharedPBits mode = Just (field (pBitsAt + e `div` 2) 1)
      | otherwise = Nothing
    pBitCount
      | endpointPBits mode = endpointCount
      | sharedPBits mode = subsets
      | otherwise = 0
    channel c e
      | c == 3 && alphaBits mode == 0 = 255
      | otherwise =
          let width = if c < 3 then colourBits mode else alphaBits mode
           in case pBit e of
                Just p → expand (width + 1) (raw c e `shiftL` 1 .|. p)
                Nothing → expand width (raw c e)
    endpoint e = Endpoint (channel 0 e) (channel 1 e) (channel 2 e) (channel 3 e)
    endpoints = map endpoint [0 .. endpointCount - 1]
    (e0s, e1s) = (\es → (everyOther es, everyOther (drop 1 es))) endpoints
    everyOther (x : _ : rest) = x : everyOther rest
    everyOther xs = xs

    subsetOf ∷ Int → Int
    subsetOf = case subsets of
      2 → let mask = partitions2 Vector.! partition in \i → fromIntegral ((mask `shiftR` i) .&. 1)
      3 → let mask = partitions3 Vector.! partition in \i → fromIntegral ((mask `shiftR` (2 * i)) .&. 3)
      _ → const 0
    anchors = case subsets of
      2 → [0, anchors2 Vector.! partition]
      3 → [0, anchors3a Vector.! partition, anchors3b Vector.! partition]
      _ → [0]

    -- Texel i's index in an index array starting at the given bit, whose
    -- anchor texels are one bit shorter.
    indexIn start width anchorSet i =
      field (start + i * width - length (filter (< i) anchorSet)) (if i `elem` anchorSet then width - 1 else width)
    primaryAt = pBitsAt + pBitCount
    secondaryAt = primaryAt + 16 * indexBits mode - length anchors

    texel i =
      let s = subsetOf i
          Endpoint r0 g0 b0 a0 = e0s !! s
          Endpoint r1 g1 b1 a1 = e1s !! s
          primary = indexIn primaryAt (indexBits mode) anchors i
          secondary = indexIn secondaryAt (secondaryIndexBits mode) [0] i
          (colourWeight, alphaWeight)
            | secondaryIndexBits mode == 0 = let w = weight (indexBits mode) primary in (w, w)
            | selection == 0 = (weight (indexBits mode) primary, weight (secondaryIndexBits mode) secondary)
            | otherwise = (weight (secondaryIndexBits mode) secondary, weight (indexBits mode) primary)
          r = interpolate colourWeight r0 r1
          g = interpolate colourWeight g0 g1
          b = interpolate colourWeight b0 b1
          a = interpolate alphaWeight a0 a1
       in case rotation of
            1 → Texel a g b r
            2 → Texel r a b g
            3 → Texel r g a b
            _ → Texel r g b a

-- | The @width@ bits starting at bit @at@ of the 128-bit block.
bits ∷ Word64 → Word64 → Int → Int → Int
bits lo hi at width
  | width == 0 = 0
  | at >= 64 = fromIntegral ((hi `shiftR` (at - 64)) .&. mask)
  | at + width <= 64 = fromIntegral ((lo `shiftR` at) .&. mask)
  | otherwise = fromIntegral (((lo `shiftR` at) .|. (hi `shiftL` (64 - at))) .&. mask)
  where
    mask = complement 0 `shiftR` (64 - width)

-- | An @n@-bit value as eight bits, its high bits replicated into the low.
expand ∷ Int → Int → Int
expand n v = let shifted = v `shiftL` (8 - n) in shifted .|. shifted `shiftR` n

weight ∷ Int → Int → Int
weight = \case
  2 → (weights2 Vector.!)
  3 → (weights3 Vector.!)
  _ → (weights4 Vector.!)

interpolate ∷ Int → Int → Int → Word8
interpolate w e0 e1 = fromIntegral (((64 - w) * e0 + w * e1 + 32) `shiftR` 6)

weights2, weights3, weights4 ∷ Vector.Vector Int
weights2 = Vector.fromList [0, 21, 43, 64]
weights3 = Vector.fromList [0, 9, 18, 27, 37, 46, 55, 64]
weights4 = Vector.fromList [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64]

-- | The two-subset partitions: bit @i@ is texel @i@'s subset.
partitions2 ∷ Vector.Vector Word16
partitions2 =
  Vector.fromList
    [ 0xCCCC, 0x8888, 0xEEEE, 0xECC8, 0xC880, 0xFEEC, 0xFEC8, 0xEC80
    , 0xC800, 0xFFEC, 0xFE80, 0xE800, 0xFFE8, 0xFF00, 0xFFF0, 0xF000
    , 0xF710, 0x008E, 0x7100, 0x08CE, 0x008C, 0x7310, 0x3100, 0x8CCE
    , 0x088C, 0x3110, 0x6666, 0x366C, 0x17E8, 0x0FF0, 0x718E, 0x399C
    , 0xAAAA, 0xF0F0, 0x5A5A, 0x33CC, 0x3C3C, 0x55AA, 0x9696, 0xA55A
    , 0x73CE, 0x13C8, 0x324C, 0x3BDC, 0x6996, 0xC33C, 0x9966, 0x0660
    , 0x0272, 0x04E4, 0x4E40, 0x2720, 0xC936, 0x936C, 0x39C6, 0x639C
    , 0x9336, 0x9CC6, 0x817E, 0xE718, 0xCCF0, 0x0FCC, 0x7744, 0xEE22
    ]

-- | The three-subset partitions: bits @2i@ and @2i + 1@ are texel @i@'s
-- subset.
partitions3 ∷ Vector.Vector Word64
partitions3 =
  Vector.fromList . map pack3 $
    [ [0,0,1,1,0,0,1,1,0,2,2,1,2,2,2,2], [0,0,0,1,0,0,1,1,2,2,1,1,2,2,2,1]
    , [0,0,0,0,2,0,0,1,2,2,1,1,2,2,1,1], [0,2,2,2,0,0,2,2,0,0,1,1,0,1,1,1]
    , [0,0,0,0,0,0,0,0,1,1,2,2,1,1,2,2], [0,0,1,1,0,0,1,1,0,0,2,2,0,0,2,2]
    , [0,0,2,2,0,0,2,2,1,1,1,1,1,1,1,1], [0,0,1,1,0,0,1,1,2,2,1,1,2,2,1,1]
    , [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2], [0,0,0,0,1,1,1,1,1,1,1,1,2,2,2,2]
    , [0,0,0,0,1,1,1,1,2,2,2,2,2,2,2,2], [0,0,1,2,0,0,1,2,0,0,1,2,0,0,1,2]
    , [0,1,1,2,0,1,1,2,0,1,1,2,0,1,1,2], [0,1,2,2,0,1,2,2,0,1,2,2,0,1,2,2]
    , [0,0,1,1,0,1,1,2,1,1,2,2,1,2,2,2], [0,0,1,1,2,0,0,1,2,2,0,0,2,2,2,0]
    , [0,0,0,1,0,0,1,1,0,1,1,2,1,1,2,2], [0,1,1,1,0,0,1,1,2,0,0,1,2,2,0,0]
    , [0,0,0,0,1,1,2,2,1,1,2,2,1,1,2,2], [0,0,2,2,0,0,2,2,0,0,2,2,1,1,1,1]
    , [0,1,1,1,0,1,1,1,0,2,2,2,0,2,2,2], [0,0,0,1,0,0,0,1,2,2,2,1,2,2,2,1]
    , [0,0,0,0,0,0,1,1,0,1,2,2,0,1,2,2], [0,0,0,0,1,1,0,0,2,2,1,0,2,2,1,0]
    , [0,1,2,2,0,1,2,2,0,0,1,1,0,0,0,0], [0,0,1,2,0,0,1,2,1,1,2,2,2,2,2,2]
    , [0,1,1,0,1,2,2,1,1,2,2,1,0,1,1,0], [0,0,0,0,0,1,1,0,1,2,2,1,1,2,2,1]
    , [0,0,2,2,1,1,0,2,1,1,0,2,0,0,2,2], [0,1,1,0,0,1,1,0,2,0,0,2,2,2,2,2]
    , [0,0,1,1,0,1,2,2,0,1,2,2,0,0,1,1], [0,0,0,0,2,0,0,0,2,2,1,1,2,2,2,1]
    , [0,0,0,0,0,0,0,2,1,1,2,2,1,2,2,2], [0,2,2,2,0,0,2,2,0,0,1,2,0,0,1,1]
    , [0,0,1,1,0,0,1,2,0,0,2,2,0,2,2,2], [0,1,2,0,0,1,2,0,0,1,2,0,0,1,2,0]
    , [0,0,0,0,1,1,1,1,2,2,2,2,0,0,0,0], [0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0]
    , [0,1,2,0,2,0,1,2,1,2,0,1,0,1,2,0], [0,0,1,1,2,2,0,0,1,1,2,2,0,0,1,1]
    , [0,0,1,1,1,1,2,2,2,2,0,0,0,0,1,1], [0,1,0,1,0,1,0,1,2,2,2,2,2,2,2,2]
    , [0,0,0,0,0,0,0,0,2,1,2,1,2,1,2,1], [0,0,2,2,1,1,2,2,0,0,2,2,1,1,2,2]
    , [0,0,2,2,0,0,1,1,0,0,2,2,0,0,1,1], [0,2,2,0,1,2,2,1,0,2,2,0,1,2,2,1]
    , [0,1,0,1,2,2,2,2,2,2,2,2,0,1,0,1], [0,0,0,0,2,1,2,1,2,1,2,1,2,1,2,1]
    , [0,1,0,1,0,1,0,1,0,1,0,1,2,2,2,2], [0,2,2,2,0,1,1,1,0,2,2,2,0,1,1,1]
    , [0,0,0,2,1,1,1,2,0,0,0,2,1,1,1,2], [0,0,0,0,2,1,1,2,2,1,1,2,2,1,1,2]
    , [0,2,2,2,0,1,1,1,0,1,1,1,0,2,2,2], [0,0,0,2,1,1,1,2,1,1,1,2,0,0,0,2]
    , [0,1,1,0,0,1,1,0,0,1,1,0,2,2,2,2], [0,0,0,0,0,0,0,0,2,1,1,2,2,1,1,2]
    , [0,1,1,0,0,1,1,0,2,2,2,2,2,2,2,2], [0,0,2,2,0,0,1,1,0,0,1,1,0,0,2,2]
    , [0,0,2,2,1,1,2,2,1,1,2,2,0,0,2,2], [0,0,0,0,0,0,0,0,0,0,0,0,2,1,1,2]
    , [0,0,0,2,0,0,0,1,0,0,0,2,0,0,0,1], [0,2,2,2,1,2,2,2,0,2,2,2,1,2,2,2]
    , [0,1,0,1,2,2,2,2,2,2,2,2,2,2,2,2], [0,1,1,1,2,0,1,1,2,2,0,1,2,2,2,0]
    ]
  where
    pack3 = foldr (\s acc → acc `shiftL` 2 .|. fromIntegral (s ∷ Int)) 0

-- | The anchor texel of subset 1 in each two-subset partition.
anchors2 ∷ Vector.Vector Int
anchors2 =
  Vector.fromList
    [ 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15
    , 15, 2, 8, 2, 2, 8, 8, 15, 2, 8, 2, 2, 8, 8, 2, 2
    , 15, 15, 6, 8, 2, 8, 15, 15, 2, 8, 2, 2, 2, 15, 15, 6
    , 6, 2, 6, 8, 15, 15, 2, 2, 15, 15, 15, 15, 15, 2, 2, 15
    ]

-- | The anchor texels of subsets 1 and 2 in each three-subset partition.
anchors3a, anchors3b ∷ Vector.Vector Int
anchors3a =
  Vector.fromList
    [ 3, 3, 15, 15, 8, 3, 15, 15, 8, 8, 6, 6, 6, 5, 3, 3
    , 3, 3, 8, 15, 3, 3, 6, 10, 5, 8, 8, 6, 8, 5, 15, 15
    , 8, 15, 3, 5, 6, 10, 8, 15, 15, 3, 15, 5, 15, 15, 15, 15
    , 3, 15, 5, 5, 5, 8, 5, 10, 5, 10, 8, 13, 15, 12, 3, 3
    ]
anchors3b =
  Vector.fromList
    [ 15, 8, 8, 3, 15, 15, 3, 8, 15, 15, 15, 15, 15, 15, 15, 8
    , 15, 8, 15, 3, 15, 8, 15, 8, 3, 15, 6, 10, 15, 15, 10, 8
    , 15, 3, 15, 10, 10, 8, 9, 10, 6, 15, 8, 15, 3, 6, 6, 8
    , 15, 3, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3, 15, 15, 8
    ]
