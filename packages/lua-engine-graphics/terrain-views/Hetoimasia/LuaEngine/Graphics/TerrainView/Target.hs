-- | The targets a terrain view attaches to (TRA-9): a window incarnation, through the narrow capability its instance
-- holds, or a surface-free target registered with the host (LFE-27). Either way the view is lent only the target's key,
-- its usability, its latest-value publication as the host's own transaction, whether its frames carry the qualified
-- depth image and the metrics its next frame is recorded with: no native control, no disposal and no raw handle.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Target
  ( windowViewTarget
  , offscreenViewTarget
  ) where

import Control.Concurrent.STM (STM)
import Data.Functor ((<&>))
import Hetoimasia.GPU.Vulkan.GLFW
  ( OffscreenTargetId
  , SceneTargetKey (..)
  , TargetScenePublication (..)
  , VulkanHost
  , WindowScenePublication (..)
  , publishVulkanTargetScene
  , vulkanHostIdentity
  , vulkanSceneTargetRegistered
  )
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Types (TargetIssuer (..), ViewTarget (..))
import Hetoimasia.LuaEngine.Graphics.Window.Host (WindowTarget (..))
import Hetoimasia.Render.TwoD.Metrics (TargetMetrics)

-- | A window incarnation's target, bound to the host the window belongs to. Its depth is the host's: 'True' only on a host built with the host-wide window
-- depth ('Hetoimasia.LuaEngine.Graphics.Scene.Configuration.configureWorldDepth'), which the composition that built the
-- host passes here. The metrics are the window's latest observation, as the composition reads it.
windowViewTarget ∷ VulkanHost GraphicsScene → Bool → STM (Maybe TargetMetrics) → WindowTarget GraphicsScene → ViewTarget SceneTargetKey
windowViewTarget host hostDepth metrics target =
  ViewTarget
    { vtKey = KeyWindow (targetWindow target)
    , vtIssuer = TargetIssuer (vulkanHostIdentity host)
    , vtUsable = targetUsable target
    , -- the incarnation's own lifecycle cell, which the owner's rounds never write
      vtRetired = targetRetired target
    , vtPublish = \scene →
        targetPublishSTM target scene <&> \case
          WindowScenePublished _ _ → True
          _ → False
    , vtDepth = hostDepth
    , vtMetrics = metrics
    }

-- | A surface-free target registered with the host. Its recording boundary ('recordVulkanTargetBatch') is the one
-- place its frames are recorded; whoever records them says whether they carry the qualified depth image. Whoever
-- registered it says whether it has retired, from a cell that changes only when it does (its unregistration). It is
-- usable while this host holds this exact registration (not another host's, not an ended one) and it has not retired:
-- an attachment checks that in its own transaction.
offscreenViewTarget ∷ VulkanHost GraphicsScene → OffscreenTargetId → STM Bool → Bool → STM (Maybe TargetMetrics) → ViewTarget SceneTargetKey
offscreenViewTarget host target retired depth metrics =
  ViewTarget
    { vtKey = KeyOffscreen target
    , vtIssuer = TargetIssuer (vulkanHostIdentity host)
    , vtUsable = (&&) <$> vulkanSceneTargetRegistered host target <*> (not <$> retired)
    , vtRetired = retired
    , vtPublish = \scene →
        publishVulkanTargetScene host target scene <&> \case
          TargetScenePublished _ _ → True
          _ → False
    , vtDepth = depth
    , vtMetrics = metrics
    }
