-- | The packed cell representation behind "Hetoimasia.Terrain.Palette".
--
-- Private to the package: the constructor of 'PackedCell' is reachable only
-- from inside it, so a client holds a packed value only through a checked path.
--
-- State, ownership and lifetime: none. Pure, immutable values.
module Hetoimasia.Terrain.Internal.Packed
  ( PackedCell (..)
  ) where

import Data.Word (Word16)

-- | A 12-bit palette index over a 4-bit shape identity. The constructor is
-- private.
newtype PackedCell = PackedCell Word16
  deriving stock (Eq, Ord, Show)
