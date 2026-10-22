-- | Reversing a PNG row filter in place.
--
-- A filtered row is one filter-type byte followed by the row's packed bytes;
-- each byte is stored as its difference from a predictor built from its
-- left neighbour @a@, the byte above it @b@ and the byte above-left @c@. The
-- neighbours are @bpp@ bytes back along the row, where @bpp@ is the pixel
-- size in whole bytes (1 for pixels under 8 bits), and the row above is all
-- zeros for the first row of a pass. Arithmetic is modulo 256.
--
-- The row is reversed where it lies, in the inflated buffer: this module
-- allocates nothing. Every index is a pointer offset inside the two rows the
-- caller gives it, @len@ bytes each; the caller establishes that both rows
-- lie inside buffers it owns.
module Hetoimasia.Asset.Image.Internal.PngUnfilter
  ( unfilterRow
  )
where

import Data.Word (Word16, Word8)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (peekByteOff, pokeByteOff)

-- | Reverse the filter of the row whose filter-type byte is at @row@ and
-- whose @len@ packed bytes follow it, given the unfiltered row above (@len@
-- bytes at @above@; zeros for a pass's first row). 'False', with the row
-- untouched, when the filter-type byte is not 0 to 4: that is not a filter,
-- and no byte of the row is read as if it were one.
unfilterRow ∷ Int → Int → Ptr Word8 → Ptr Word8 → IO Bool
unfilterRow bpp len above row = do
  kind ← peekByteOff row 0 ∷ IO Word8
  let cur = row `plusPtr` 1 ∷ Ptr Word8
  case kind of
    0 → pure True
    1 → sub cur >> pure True
    2 → up cur >> pure True
    3 → average cur >> pure True
    4 → paeth cur >> pure True
    _ → pure False
  where
    at ∷ Ptr Word8 → Int → IO Word8
    at = peekByteOff
    put ∷ Ptr Word8 → Int → Word8 → IO ()
    put = pokeByteOff

    sub cur = loop bpp
      where
        loop !i
          | i >= len = pure ()
          | otherwise = do
              x ← at cur i
              a ← at cur (i - bpp)
              put cur i (x + a)
              loop (i + 1)

    up cur = loop 0
      where
        loop !i
          | i >= len = pure ()
          | otherwise = do
              x ← at cur i
              b ← at above i
              put cur i (x + b)
              loop (i + 1)

    average cur = loop 0
      where
        loop !i
          | i >= len = pure ()
          | otherwise = do
              x ← at cur i
              a ← if i >= bpp then at cur (i - bpp) else pure 0
              b ← at above i
              put cur i (x + fromIntegral ((fromIntegral a + fromIntegral b ∷ Word16) `div` 2))
              loop (i + 1)

    paeth cur = loop 0
      where
        loop !i
          | i >= len = pure ()
          | otherwise = do
              x ← at cur i
              a ← if i >= bpp then at cur (i - bpp) else pure 0
              b ← at above i
              c ← if i >= bpp then at above (i - bpp) else pure 0
              put cur i (x + predictor a b c)
              loop (i + 1)

-- | The Paeth predictor: whichever of left, above and above-left is nearest
-- to left + above − above-left, ties going to left, then above.
predictor ∷ Word8 → Word8 → Word8 → Word8
predictor a b c
  | pa <= pb && pa <= pc = a
  | pb <= pc = b
  | otherwise = c
  where
    a' = fromIntegral a ∷ Int
    b' = fromIntegral b
    c' = fromIntegral c
    p = a' + b' - c'
    pa = abs (p - a')
    pb = abs (p - b')
    pc = abs (p - c')
