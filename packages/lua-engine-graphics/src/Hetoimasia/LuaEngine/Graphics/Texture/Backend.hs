-- | The texture backend: the state machine that makes a texture, with its one pump thread, over a 'Port'. This is the package's public
-- face; the implementation, with its contract (what one pump step costs, the invariants) and what the package's own suite needs
-- beyond it, is "Hetoimasia.LuaEngine.Graphics.Texture.Backend.Internal".
module Hetoimasia.LuaEngine.Graphics.Texture.Backend
  ( -- * The backend
    Backend
  , withBackend
  , textureBackend

    -- * Observation
  , BackendReading (..)
  , readBackend
  , awaitBackendFailure
  , awaitBound
  , backendEvidence

    -- * Failures
  , BackendDefect (..)
  ) where

import Hetoimasia.LuaEngine.Graphics.Texture.Backend.Internal
