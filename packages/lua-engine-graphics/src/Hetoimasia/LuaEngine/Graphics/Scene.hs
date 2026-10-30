-- | Publishing scenes with completion-safe texture retention (LFE-20): the scene a window holds, the ledger of
-- what its adopted revisions hold, the publication boundary, the per-frame renderer and the scene part of the
-- host's configuration. The composition that borrows a host and runs the texture backend over it is
-- "Hetoimasia.LuaEngine.Graphics.Texture".
--
-- The ownership, authority and lock protocol is in "Hetoimasia.LuaEngine.Graphics.Scene.Publish", the ledger's
-- state in "Hetoimasia.LuaEngine.Graphics.Scene.Ledger", and what the host is configured with in
-- "Hetoimasia.LuaEngine.Graphics.Scene.Configuration".
module Hetoimasia.LuaEngine.Graphics.Scene
  ( module Hetoimasia.LuaEngine.Graphics.Scene.Configuration
  , module Hetoimasia.LuaEngine.Graphics.Scene.Ledger
  , module Hetoimasia.LuaEngine.Graphics.Scene.Publish
  , module Hetoimasia.LuaEngine.Graphics.Scene.Render
  ) where

import Hetoimasia.LuaEngine.Graphics.Scene.Configuration
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger
import Hetoimasia.LuaEngine.Graphics.Scene.Publish
import Hetoimasia.LuaEngine.Graphics.Scene.Render
