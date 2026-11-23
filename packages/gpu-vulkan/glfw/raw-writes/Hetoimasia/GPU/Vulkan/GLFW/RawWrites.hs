-- | The host's own transactions that existing compositions outside terrain run inside a single transaction of their
-- own: the texture port's action and release admission ("Hetoimasia.LuaEngine.Graphics.Texture.Host") and an
-- offscreen target's scene publication in the LFE-27 publisher ("Hetoimasia.LuaEngine.Graphics.Scene.Publish").
-- Every other caller commits the ownership operations of "Hetoimasia.GPU.Vulkan.GLFW" ('submitVulkanActionTx',
-- 'requestVulkanReleaseTx', 'publishVulkanTargetSceneTx'), which embed these same transactions. Terrain views do not
-- depend on this unit.
module Hetoimasia.GPU.Vulkan.GLFW.RawWrites
  ( submitVulkanAction
  , requestVulkanRelease
  , publishVulkanTargetScene
  ) where

import Control.Concurrent.STM (STM)
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
  ( ActionRefusal
  , ActionTicket
  , OffscreenTargetId
  , TargetScenePublication
  , VulkanAction
  , VulkanHost (vulkanController)
  )
import qualified Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller as Controller

-- | Admit an owner-thread action, in the caller's transaction ('Hetoimasia.GPU.Vulkan.GLFW.submitVulkanActionTx').
submitVulkanAction ∷ VulkanHost scene → VulkanAction r → STM (Either ActionRefusal (ActionTicket r))
submitVulkanAction host = Controller.submitVulkanAction (vulkanController host)

-- | Admit a release request, in the caller's transaction ('Hetoimasia.GPU.Vulkan.GLFW.requestVulkanReleaseTx').
requestVulkanRelease ∷ VulkanHost scene → VulkanAction r → STM (Either ActionRefusal (ActionTicket r))
requestVulkanRelease host = Controller.requestVulkanRelease (vulkanController host)

-- | Publish a scene to a registered offscreen target, in the caller's transaction
-- ('Hetoimasia.GPU.Vulkan.GLFW.publishVulkanTargetSceneTx').
publishVulkanTargetScene ∷ VulkanHost scene → OffscreenTargetId → Prepared scene → STM TargetScenePublication
publishVulkanTargetScene = Controller.publishVulkanTargetScene
