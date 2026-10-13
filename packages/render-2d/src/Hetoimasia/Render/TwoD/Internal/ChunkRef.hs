-- | The representation of a retained chunk's reference.
--
-- __Ownership.__ A hidden module of @hetoimasia-render-2d@. Only the snapshot,
-- the chunk modules and the backend-facing one import it.
--
-- __Dependencies.__ @base@ alone.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Internal.ChunkRef
  ( ChunkRef (..)
  ) where

import Data.Word (Word32)

-- | An index and a generation, which a backend issues and resolves. Holding
-- one acquires nothing and keeps nothing alive.
data ChunkRef = ChunkRef
  { chunkRefIndex ∷ {-# UNPACK #-} !Word32
  , chunkRefGeneration ∷ {-# UNPACK #-} !Word32
  }
  deriving stock (Eq, Ord, Show)
