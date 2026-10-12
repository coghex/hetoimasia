-- | The backend-facing view of a texture handle: build one from an index and a
-- generation, and read both back.
--
-- __Audience.__ A backend registers textures and mints the handles game code
-- holds; a test that stands in for a backend does the same. Game code does not
-- import this module, and imports "Hetoimasia.Render.Api.Texture" for the
-- type. Importing this module is the deliberate act that makes a program a
-- backend, so the package keeps it separate rather than hiding the operations.
--
-- __Total and pure.__ Every pair of 'Word32' values is a handle, including a
-- zero generation: this module checks nothing, because what a lookup index and
-- a generation mean belongs to the backend that issues them. A backend's table
-- may never issue a zero generation, and resolves one that arrives anyway to
-- its placeholder.
--
-- __Dependencies.__ @base@ and the package's hidden representation module.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.Api.Texture.Backend
  ( textureHandle
  , handleIndex
  , handleGeneration
  ) where

import Data.Word (Word32)
import Hetoimasia.Render.Api.Internal.Texture (TextureHandle (..), handleGeneration, handleIndex)

-- | The handle with this lookup index and this generation.
textureHandle ∷ Word32 → Word32 → TextureHandle
textureHandle = TextureHandle
