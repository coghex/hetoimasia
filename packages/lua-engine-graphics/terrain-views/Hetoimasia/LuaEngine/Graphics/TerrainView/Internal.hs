-- | Terrain views (TRA-9) as the package itself reaches them: every module's names, including the graphics owner's
-- capability records ('OwnerPorts', 'Hands', 'Grant', 'Receipt'), the copy hooks and the held target the headless
-- rigs stand in with. This module is in the package's private library: no client reaches it. Clients use
-- "Hetoimasia.LuaEngine.Graphics.TerrainView", whose composition is opaque.
--
-- The ownership, threads and endings are in "Hetoimasia.LuaEngine.Graphics.TerrainView.Session"; the limits and the
-- allowance in "Hetoimasia.LuaEngine.Graphics.TerrainView.Profile"; the style's authority in
-- "Hetoimasia.LuaEngine.Graphics.TerrainView.Style"; the planning inputs in
-- "Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs"; the graphics owner's capabilities in
-- "Hetoimasia.LuaEngine.Graphics.TerrainView.Owner".
module Hetoimasia.LuaEngine.Graphics.TerrainView.Internal
  ( module Hetoimasia.LuaEngine.Graphics.TerrainView.Owner
  , module Hetoimasia.LuaEngine.Graphics.TerrainView.Profile
  , module Hetoimasia.LuaEngine.Graphics.TerrainView.Session
  , module Hetoimasia.LuaEngine.Graphics.TerrainView.Style
  , module Hetoimasia.LuaEngine.Graphics.TerrainView.Surface
  , module Hetoimasia.LuaEngine.Graphics.TerrainView.Target
  , productionPorts
  ) where

import Hetoimasia.GPU.Vulkan.GLFW (SceneTargetKey, VulkanHost)
import Hetoimasia.LuaEngine.Graphics.Scene.Configuration (SceneSession (..))
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Owner
import Hetoimasia.LuaEngine.Graphics.TerrainView.Profile
import Hetoimasia.LuaEngine.Graphics.TerrainView.Session
import Hetoimasia.LuaEngine.Graphics.TerrainView.Style
import Hetoimasia.LuaEngine.Graphics.TerrainView.Surface
import Hetoimasia.LuaEngine.Graphics.TerrainView.Target
import Hetoimasia.LuaEngine.Graphics.Texture (TextureGraphics (..))
import Hetoimasia.LuaEngine.Texture (RenderAccount)
import qualified Hetoimasia.Terrain.Runtime as Runtime

-- | The ports of a terrain-enabled composition over the running host and its composed graphics session: the owner's
-- capabilities over the host, the session's ledger, claims and receipts, its initial scene (the empty revision a
-- claim is handed back with), the terrain service and the client the views are opened under, and the session's
-- shared render/staging account.
productionPorts ∷ VulkanHost GraphicsScene → TextureGraphics → SceneSession → Runtime.Service → Runtime.Client → RenderAccount → IO (TerrainViewsPorts SceneTargetKey)
productionPorts host graphics scenes terrain client account = do
  owner ← productionOwner host graphics
  pure
    TerrainViewsPorts
      { portOwner = owner
      , portLedger = graphicsLedger graphics
      , portClaims = scenesClaims scenes
      , portReceipts = scenesReceipts scenes
      , portInitial = scenesInitial scenes
      , portTerrain = terrain
      , portClient = client
      , portAccount = account
      , portCopyHooks = noCopyHooks
      }
