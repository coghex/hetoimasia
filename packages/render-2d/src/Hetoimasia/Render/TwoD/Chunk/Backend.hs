-- | The backend-facing view of a chunk reference: build one from an index and a
-- generation, and read both back.
--
-- __Audience.__ The backend that retains chunks mints these references, and a
-- test that stands in for one does the same. Game code imports
-- "Hetoimasia.Render.TwoD.Chunk" for the type and does not import this module.
--
-- __Pure and total.__ Every pair of 'Word32' values is a reference. Building one
-- performs no native acquisition and starts no lifetime: what an index and a
-- generation mean, and whether a reference is still live, belong to the backend.
-- A backend that reuses an index gives it a new generation, so a stale reference
-- resolves to nothing and never to rebuilt content.
--
-- __Dependencies.__ @base@ and the package's hidden representation module.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Chunk.Backend
  ( chunkRef
  , chunkRefIndex
  , chunkRefGeneration
  ) where

import Data.Word (Word32)
import Hetoimasia.Render.TwoD.Internal.ChunkRef (ChunkRef (..), chunkRefGeneration, chunkRefIndex)

-- | The reference with this index and this generation.
chunkRef ∷ Word32 → Word32 → ChunkRef
chunkRef = ChunkRef
