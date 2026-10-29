-- | What the window provider (LFE-18) asks of the host it borrows, and a check of a host against it.
--
-- The fixed M1 profile has up to two UI instances, each with at most one window, so the host must carry
-- two windows at once, take their creation and close commands without refusing one for the other's
-- sake, and keep a scene for each window. A sample's single-window policy is not this: a host built for
-- one window would meet 'Hetoimasia.GLFW.Command.WindowCapacityReached' on the second instance's
-- request, which after the adapter's own validation is a fatal fault, never a @window_error@.
--
-- The graphics side of the same profile (two target records, the frame slots, the generations and
-- the native byte, object and progress budgets) is mapped once, by
-- "Hetoimasia.LuaEngine.Graphics.Texture.Configuration"; this module neither copies nor changes it, and
-- 'checkWindowHost' leaves them to that module's 'Hetoimasia.LuaEngine.Graphics.Texture.Configuration.checkHostConfig'.
--
-- = What is required
--
-- * the host holds at least 'windowSlots' windows ('hostWindowLimit'): one for each instance that can
--   have one;
-- * its command queue holds a creation and a close for each of them at once
--   ('windowCommandCapacity'), so a close is never refused for want of the room a creation took;
-- * its scenes are kept for each window ('PerWindowScenes'), because a scene published to one
--   instance's window must never be the other's.
module Hetoimasia.LuaEngine.Graphics.Window.Configuration
  ( windowSlots
  , windowCommandCapacity
  , configureWindows
  , checkWindowHost
  , WindowHostProblem (..)
  ) where

import Hetoimasia.GPU.Vulkan.GLFW (SceneMode (..), VulkanHostConfig (..))
import Hetoimasia.Runtime.GLFW (HostConfig (..))

-- | The windows the fixed profile can hold at once: two UI instances, one each.
windowSlots ∷ Int
windowSlots = 2

-- | The commands the host must be able to queue at once: a creation and a close for each window.
windowCommandCapacity ∷ Integer
windowCommandCapacity = 2 * fromIntegral windowSlots

-- | A host configuration that carries the profile's windows: never smaller than it already was, and with
-- a scene for each window.
configureWindows ∷ VulkanHostConfig scene → VulkanHostConfig scene
configureWindows host =
  host
    { vulkanHost =
        (vulkanHost host)
          { hostWindowLimit = max windowSlots (hostWindowLimit (vulkanHost host))
          , hostCommandCapacity = max windowCommandCapacity (hostCommandCapacity (vulkanHost host))
          }
    , vulkanSceneMode = PerWindowScenes
    }

-- | What is wrong with a host for the window provider, structured. An empty answer means it can carry
-- the profile's windows.
data WindowHostProblem
  = -- | The host holds fewer windows than the instances that can have one: the second instance's
    -- creation would meet the host's capacity.
    HostWindowLimitTooSmall !Int
  | -- | The host's command queue cannot hold a creation and a close for every window at once.
    HostCommandCapacityTooSmall !Integer
  | -- | The host keeps one scene for every window, so a publication to one instance would be seen by
    -- the other.
    HostScenesShared
  deriving (Eq, Show)

checkWindowHost ∷ VulkanHostConfig scene → [WindowHostProblem]
checkWindowHost host =
  [HostWindowLimitTooSmall limit | let limit = hostWindowLimit (vulkanHost host), limit < windowSlots]
    <> [HostCommandCapacityTooSmall capacity | let capacity = hostCommandCapacity (vulkanHost host), capacity < windowCommandCapacity]
    <> [HostScenesShared | vulkanSceneMode host /= PerWindowScenes]
