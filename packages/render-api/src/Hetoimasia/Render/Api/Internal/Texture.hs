-- | The representation of a texture handle.
--
-- __Ownership.__ A hidden module of @hetoimasia-render-api@. Only the public
-- handle module and the backend-facing module import it, so the constructor and
-- the field readers reach a client only through the exports those two choose.
--
-- __Dependencies.__ @base@ alone.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.Api.Internal.Texture
  ( TextureHandle (..)
  ) where

import Data.Word (Word32)

-- | A lookup index and a generation, as two strict, unpacked 32-bit fields, so
-- that constructing, comparing and encoding a handle cost what the raw values
-- cost. Derived ordering is by index, then by generation.
data TextureHandle = TextureHandle
  { handleIndex ∷ {-# UNPACK #-} !Word32
  , handleGeneration ∷ {-# UNPACK #-} !Word32
  }
  deriving stock (Eq, Ord, Show)
