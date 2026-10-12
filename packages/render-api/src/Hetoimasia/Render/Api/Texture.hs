-- | The opaque texture handle game code holds.
--
-- A handle names a texture a backend has registered: a 32-bit lookup index and
-- a 32-bit generation. This module is what game code imports. It exports the
-- type and, through its instances, comparison, ordering and 'show'; it exports
-- neither the constructor nor a field reader, so game code can neither build a
-- handle nor take one apart. A backend, and a test that stands in for one,
-- imports "Hetoimasia.Render.Api.Texture.Backend" instead.
--
-- Opacity costs nothing at run time: the handle is a record of two strict,
-- unpacked 'Data.Word.Word32' fields, and what hides it is only what this
-- module exports.
--
-- __Ordering and 'show'.__ Handles order by index, then by generation, and
-- 'show' prints both numbers, the index first. Neither promises that a handle
-- resolves to a live texture: whether one does is the backend's question.
--
-- __Dependencies.__ @base@ and the package's hidden representation module.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.Api.Texture
  ( TextureHandle
  ) where

import Hetoimasia.Render.Api.Internal.Texture (TextureHandle)
