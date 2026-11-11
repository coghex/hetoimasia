-- | CRC32C (Castagnoli), the page checksum of the temporary store.
--
-- The reflected polynomial @0x82F63B78@ (normal form @0x1EDC6F41@), initial value
-- and final exclusive-or both @0xFFFFFFFF@, as iSCSI (RFC 3720) and the SSE4.2
-- instruction define it. It is a different function from the CRC-32 of PNG and
-- zlib, so no PNG helper can stand in for it; the test suite checks this module
-- against vectors written independently of it.
--
-- State, ownership and lifetime: none. A pure function over a strict 'ByteString'
-- and one immutable 256-entry table built once.
module Hetoimasia.Terrain.Runtime.Store.Internal.Crc32c
  ( crc32c
  ) where

import Data.Array.Unboxed (UArray, listArray, (!))
import Data.Bits (complement, shiftR, xor, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word32, Word8)

-- | The checksum of a byte string.
crc32c ∷ ByteString → Word32
crc32c = complement . BS.foldl' step 0xFFFFFFFF
  where
    step ∷ Word32 → Word8 → Word32
    step crc byte = (crc `shiftR` 8) `xor` (table ! ((crc .&. 0xFF) `xor` fromIntegral byte))

table ∷ UArray Word32 Word32
table = listArray (0, 255) (map entry [0 .. 255])
  where
    entry n = iterate shiftOnce n !! 8
    shiftOnce c
      | c .&. 1 == 1 = (c `shiftR` 1) `xor` 0x82F63B78
      | otherwise = c `shiftR` 1
