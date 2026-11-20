-- | The targets a terrain view attaches to (TRA-9): a window incarnation, through the narrow capability its instance
-- holds, or a surface-free target registered with the host (LFE-27). Either way the view is lent the target's key,
-- its usability, its latest-value publication as the host's own transaction, whether its frames carry the qualified
-- depth image and the metrics its next frame is recorded with: no native control, no disposal and no raw handle.
--
-- A registered offscreen target's frames are recorded by whoever registered it ('drawOffscreenView'), which is also
-- where its receipt advances: at the successful submission of the batch that drew the revision.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Target
  ( windowViewTarget
  , offscreenViewTarget
  , drawOffscreenView
  ) where

import Control.Concurrent.STM (STM, atomically)
import Data.Functor ((<&>))
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , Image
  , OffscreenTargetId
  , SceneTargetKey (..)
  , TargetScenePublication (..)
  , VulkanAction (..)
  , VulkanHost
  , WindowScenePublication (..)
  , awaitVulkanAction
  , publishVulkanTargetScene
  , recordVulkanTargetBatch
  , submitVulkanAction
  )
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene (..))
import Hetoimasia.LuaEngine.Graphics.Scene.Receipts (DrawReceipts, noteSubmitted)
import Hetoimasia.LuaEngine.Graphics.Scene.Render (RenderSession (..), renderWorldTarget)
import Hetoimasia.LuaEngine.Graphics.Scene.World (SceneWorld (..), WorldTag)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Session (ViewTarget (..))
import Hetoimasia.LuaEngine.Graphics.Texture (TextureGraphics (..))
import Hetoimasia.LuaEngine.Graphics.Texture.Host (hostBuilders)
import Hetoimasia.LuaEngine.Graphics.Window.Host (WindowTarget (..))
import Hetoimasia.Render.TwoD.Metrics (TargetMetrics)

-- | A window incarnation's target. Its depth is the host's: 'True' only on a host built with the window depth a world
-- scene draws with ('Hetoimasia.LuaEngine.Graphics.Scene.Configuration.configureWorldDepth'), which the composition
-- passes here. The metrics are the window's latest observation, as the composition reads it.
windowViewTarget ∷ Bool → STM (Maybe TargetMetrics) → WindowTarget GraphicsScene → ViewTarget SceneTargetKey
windowViewTarget hostDepth metrics target =
  ViewTarget
    { vtKey = KeyWindow (targetWindow target)
    , vtUsable = targetUsable target
    , vtPublish = \scene →
        targetPublishSTM target scene <&> \case
          WindowScenePublished _ _ → True
          _ → False
    , vtDepth = hostDepth
    , vtMetrics = metrics
    }

-- | A surface-free target registered with the host: usable while its registrant says so, drawn with the depth image
-- its registrant records with ('drawOffscreenView'), at the metrics its registrant gives.
offscreenViewTarget ∷ VulkanHost GraphicsScene → OffscreenTargetId → STM Bool → STM (Maybe TargetMetrics) → ViewTarget SceneTargetKey
offscreenViewTarget host target usable metrics =
  ViewTarget
    { vtKey = KeyOffscreen target
    , vtUsable = usable
    , vtPublish = \scene →
        publishVulkanTargetScene host target scene <&> \case
          TargetScenePublished _ _ → True
          _ → False
    , vtDepth = True
    , vtMetrics = metrics
    }

-- | Record the world the host adopted for a registered offscreen target into the caller's colour image (of this
-- format) and @D32_SFLOAT@ depth image, in one owner action, and advance the view's receipt once that batch has been
-- submitted. A target whose adopted scene is not a world records nothing and is refused.
drawOffscreenView
  ∷ VulkanHost GraphicsScene
  → TextureGraphics
  → DrawReceipts
  → OffscreenTargetId
  → TargetMetrics
  → Image
  → Word32
  → Image
  → IO (Either Text WorldTag)
drawOffscreenView host graphics receipts target metrics image format depth = do
  let session = RenderSession (graphicsRenderer graphics) (graphicsTextures graphics) (graphicsRetained graphics)
      action = VulkanAction $ \construction →
        recordVulkanTargetBatch host target construction $ \scene _ recorder → case graphicsWorld scene of
          Nothing → pure (Left "the target's adopted scene is not a terrain view's")
          Just world →
            renderWorldTarget session (hostBuilders host construction) world metrics image format depth recorder <&> \case
              Left refusal → Left (Text.pack (show refusal))
              Right () → Right (worldTag world)
  atomically (submitVulkanAction host action) >>= \case
    Left refusal → pure (Left (Text.pack (show refusal)))
    Right ticket →
      atomically (awaitVulkanAction ticket) >>= \case
        ActionReturned (Right (_, Right tag)) → Right tag <$ atomically (noteSubmitted receipts tag metrics)
        ActionReturned (Right (_, Left why)) → pure (Left why)
        ActionReturned (Left refusal) → pure (Left (Text.pack (show refusal)))
        other → pure (Left (Text.pack (outcomeText other)))
  where
    outcomeText = \case
      ActionRaised why → "the recording raised: " <> show why
      ActionRefused why → "the recording was refused: " <> show why
      ActionReturned _ → "returned"
