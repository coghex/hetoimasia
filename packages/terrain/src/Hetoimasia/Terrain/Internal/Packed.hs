-- | The packed cell representation behind "Hetoimasia.Terrain.Palette".
--
-- Private to the package: the constructor of 'PackedCell' is reachable only
-- from inside it, so a client holds a packed value only through a checked path.
--
-- State, ownership and lifetime: none. Pure, immutable values.
module Hetoimasia.Terrain.Internal.Packed
  ( PackedCell (..)
  ) where

import Data.Word (Word32)

-- | A 17-bit value: bit 16 is the family tag (set for a corner key, clear for a
-- side key), bits 4 to 15 a palette index and bits 0 to 3 the value within the
-- family. A clear tag leaves the historic 16-bit word, zero-extended. The
-- constructor is private; the bits above 16 are always clear.
newtype PackedCell = PackedCell Word32
  deriving stock (Eq, Ord, Show)
