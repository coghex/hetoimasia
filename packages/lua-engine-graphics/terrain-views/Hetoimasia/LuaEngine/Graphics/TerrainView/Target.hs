-- | The targets a terrain view attaches to (TRA-9): a window incarnation, through the narrow capability its instance
-- holds, or a surface-free target registered with the host (LFE-27). Either way the view is lent the target's key,
-- its usability, its latest-value publication as the host's own transaction, whether its frames carry the qualified
-- depth image and the metrics its next frame is recorded with: no native control, no disposal and no raw handle.
--
-- A registered offscreen target's frames are recorded by whoever registered it ('drawOffscreenView'). Its receipt
-- advances once the batch that drew the revision is complete: the owner action that records the batch notes its
-- ticket, and the receipts promote it when the ticket says so, whatever becomes of the caller.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Target
  ( windowViewTarget
  , offscreenViewTarget
  , drawOffscreenView
  ) where

import Control.Concurrent.STM (atomically)
import Data.Functor ((<&>))
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , BatchTicket
  , Image
  , Recorder
  , Refusal
  , OffscreenTargetId
  , SceneTargetKey (..)
  , VulkanAction (..)
  , VulkanHost
  , awaitVulkanAction
  , recordVulkanTargetBatch
  , submitVulkanAction
  )
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene (..))
import Hetoimasia.LuaEngine.Graphics.Scene.Receipts (DrawReceipts, noteOffscreenBatch)
import Hetoimasia.LuaEngine.Graphics.Scene.Render (RenderSession (..), renderWorldTarget)
import Hetoimasia.LuaEngine.Graphics.Scene.World (SceneWorld (..), WorldTag)
import Hetoimasia.LuaEngine.Graphics.TerrainView.Surface (Authority, OffscreenFacts, ViewSurface (..), ViewTarget (..))
import Hetoimasia.LuaEngine.Graphics.Texture (TextureGraphics (..))
import Hetoimasia.LuaEngine.Graphics.Texture.Host (hostBuilders)
import Hetoimasia.LuaEngine.Graphics.Window.Host (WindowTarget (..))
import Hetoimasia.Render.TwoD.Metrics (TargetMetrics)

-- | A window incarnation's target, through the capability its host issued ('targetView'). Its depth is the host's:
-- 'True' only on a host built with the window depth a world scene draws with
-- ('Hetoimasia.LuaEngine.Graphics.Scene.Configuration.configureWorldDepth'), which the composition passes here. Its
-- geometry is the window's live observation, whatever frame was recorded last: a recorded frame's metrics describe that
-- frame (for drawing and picking), never the window now. Its authority is the caller's original leases (checked in the
-- open's commit and wherever the view's work is revalidated). It shows a scene once the host holds one published for it.
windowViewTarget ∷ VulkanHost GraphicsScene → Bool → DrawReceipts → [Authority] → WindowTarget GraphicsScene → ViewTarget SceneTargetKey
windowViewTarget host hostDepth receipts leases target =
  ViewTarget
    { vtKey = KeyWindow (targetWindow target)
    , vtSurface = WindowSurface host receipts (targetView target) leases
    , vtDepth = hostDepth
    }

-- | A surface-free target registered with the host: usable while its registrant's facts say so, drawn with the depth
-- image its registrant records with ('drawOffscreenView'), at the metrics its registrant sets (none is an unknown
-- geometry, a zero dimension a zero one).
offscreenViewTarget ∷ VulkanHost GraphicsScene → OffscreenTargetId → OffscreenFacts → ViewTarget SceneTargetKey
offscreenViewTarget host target facts =
  ViewTarget
    { vtKey = KeyOffscreen target
    , vtSurface = OffscreenSurface host target facts
    , vtDepth = True
    }

-- | Record the world the host adopted for a registered offscreen target into the caller's colour image (of this
-- format) and @D32_SFLOAT@ depth image, then the caller's own commands in the same batch (a copy to a readback, say),
-- in one owner action, which notes the batch's ticket with the receipts: the view's receipt advances once that batch is
-- complete (a discarded or lost batch drew nothing). Answers the batch's ticket and the revision drawn. A target whose
-- adopted scene is not a world records nothing and is refused.
drawOffscreenView
  ∷ VulkanHost GraphicsScene
  → TextureGraphics
  → DrawReceipts
  → OffscreenTargetId
  → TargetMetrics
  → Image
  → Word32
  → Image
  → (∀ q inst msgr phys dev cmd. Recorder q inst msgr phys dev cmd → IO (Either Refusal ()))
  → IO (Either Text (BatchTicket, WorldTag))
drawOffscreenView host graphics receipts target metrics image format depth after = do
  let session = RenderSession (graphicsRenderer graphics) (graphicsTextures graphics) (graphicsRetained graphics)
      action = VulkanAction $ \construction → do
        recorded ←
          recordVulkanTargetBatch host target construction $ \scene _ recorder → case graphicsWorld scene of
            Nothing → pure (Left "the target's adopted scene is not a terrain view's")
            Just world →
              renderWorldTarget session (hostBuilders host construction) world metrics image format depth recorder >>= \case
                Left refusal → pure (Left (Text.pack (show refusal)))
                Right () →
                  after recorder <&> \case
                    Left refusal → Left (Text.pack (show refusal))
                    Right () → Right (worldTag world)
        -- on the owner's thread, before the action returns and its batch is submitted
        case recorded of
          Right (batch, Right tag) → atomically (noteOffscreenBatch receipts batch tag metrics)
          _ → pure ()
        pure recorded
  atomically (submitVulkanAction host action) >>= \case
    Left refusal → pure (Left (Text.pack (show refusal)))
    Right ticket →
      atomically (awaitVulkanAction ticket) >>= \case
        ActionReturned (Right (batch, Right tag)) → pure (Right (batch, tag))
        ActionReturned (Right (_, Left why)) → pure (Left why)
        ActionReturned (Left refusal) → pure (Left (Text.pack (show refusal)))
        other → pure (Left (Text.pack (outcomeText other)))
  where
    outcomeText = \case
      ActionRaised why → "the recording raised: " <> show why
      ActionRefused why → "the recording was refused: " <> show why
      ActionReturned _ → "returned"
