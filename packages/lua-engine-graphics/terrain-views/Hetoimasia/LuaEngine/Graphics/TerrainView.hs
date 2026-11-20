-- | The terrain-view adapter (TRA-9), the Haskell operations a Lua terrain-view binding wraps: attach a view of a
-- borrowed arena to a target under an exclusive claim, submit camera and presentation intent, jump, observe
-- preparation and adoption, pick from the adopted frame with an opaque consistency reference and its removal
-- precondition, and close with a real empty handback.
--
-- The ownership, threads and invariants are in "Hetoimasia.LuaEngine.Graphics.TerrainView.Service"; the style's
-- authority in "Hetoimasia.LuaEngine.Graphics.TerrainView.Style"; the planning inputs in
-- "Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs"; the graphics owner's capability in
-- "Hetoimasia.LuaEngine.Graphics.TerrainView.Owner".
module Hetoimasia.LuaEngine.Graphics.TerrainView
  ( -- * The service
    TerrainViewsConfig (..)
  , defaultTerrainViewsConfig
  , terrainGpuBankBytes
  , terrainViewsLimits
  , terrainViewsRefusal
  , TerrainViewsRefused (..)
  , TerrainViewsPorts (..)
  , productionPorts
  , TerrainViews
  , withTerrainViews
  , terrainViewsFailures
  , terrainViewsGpuCharged
  , terrainViewsRetiring
  , renderStagingAccount

    -- * The graphics owner
  , ViewOwner (..)
  , OwnerRefusal (..)
  , Answer (..)
  , Ticket
  , RegionBuild (..)
  , BuildFailure (..)
  , productionViewOwner

    -- * Targets
  , ViewTarget (..)
  , TargetIssuer (..)
  , windowViewTarget
  , offscreenViewTarget

    -- * Styles
  , StyleRequest (..)
  , StyleRefusal (..)
  , ParentRole (..)
  , describeStyleRefusal

    -- * Attaching and closing
  , AttachRequest (..)
  , AttachRefusal (..)
  , CloseOutcome (..)
  , TerrainViewCloseFailed (..)
  , describeAttachRefusal
  , Settled (..)
  , TerrainView
  , viewIncarnation
  , PendingAttach
  , attachView
  , attachSettled
  , awaitAttach
  , cancelAttach
  , closeView
  , viewClosed
  , viewCloseOutcome
  , terrainViewsUnhanded
  , viewClosing
  , viewHoldsStyle

    -- * Intent
  , CameraIntent (..)
  , PresentationUpdate (..)
  , noPresentationUpdate
  , IntentRefusal (..)
  , updateCamera
  , updatePresentation
  , JumpRequest (..)
  , JumpOutcome (..)
  , PendingJump
  , jumpView
  , jumpSettled
  , cancelJumpView

    -- * Observation
  , ViewPhase (..)
  , ViewReading (..)
  , WindowRefusal (..)
  , readView
  , viewDemand
  , viewCameraState

    -- * Picking
  , PickResult (..)
  , PickRef
  , pickRefCell
  , pickRefPart
  , pickRefIdentity
  , PickIdentity
  , pickTarget
  , pickViewId
  , pickRevision
  , pickTag
  , pickArena
  , pickContent
  , pickKnowledge
  , pickResidency
  , pickView
  , pickPrecondition
  , admittedCostBound
  , preparationCost
  , admittedInputsCost
  , uniformInputsCost
  ) where

import Control.Concurrent.STM (STM)
import Hetoimasia.GPU.Vulkan.GLFW (SceneTargetKey, VulkanHost, vulkanHostIdentity)
import Hetoimasia.LuaEngine.Graphics.Scene.Configuration (SceneSession (..))
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Owner
import Hetoimasia.LuaEngine.Graphics.TerrainView.Service
import Hetoimasia.LuaEngine.Graphics.TerrainView.Style
import Hetoimasia.LuaEngine.Graphics.TerrainView.Target
import Hetoimasia.LuaEngine.Graphics.TerrainView.Types
import Hetoimasia.LuaEngine.Graphics.Texture (TextureGraphics (..))
import Hetoimasia.LuaEngine.Texture (RenderAccount)
import Hetoimasia.Render.TwoD.Vulkan.Textures (isReleased)
import qualified Hetoimasia.Terrain.Runtime as Runtime

-- | The ports of a terrain-enabled composition over the running host and its composed graphics session: the owner's
-- capability over the host, the session's registry, ledger and claims, its initial scene, the terrain service and the
-- client the views are opened under, the session's one CPU render/staging account (which the terrain service was also
-- given, as 'renderStagingAccount', so all three consumers draw on it) and the session's admission.
productionPorts ∷ VulkanHost GraphicsScene → TextureGraphics → SceneSession → Runtime.Service → Runtime.Client → RenderAccount → STM Bool → IO (TerrainViewsPorts SceneTargetKey)
productionPorts host graphics scenes terrain client account taking = do
  owner ← productionViewOwner host graphics
  pure
    TerrainViewsPorts
      { portOwner = owner
      , portReleased = isReleased (graphicsTextures graphics)
      , portLedger = graphicsLedger graphics
      , portClaims = scenesClaims scenes
      , portInitial = scenesInitial scenes
      , portTerrain = terrain
      , portClient = client
      , portAccount = account
      , portTaking = taking
      , portIssuer = TargetIssuer (vulkanHostIdentity host)
      }
