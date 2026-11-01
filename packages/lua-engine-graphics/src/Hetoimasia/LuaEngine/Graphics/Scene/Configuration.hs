-- | The scene part of the host's configuration (LFE-20), as one piece the assembly (LFE-22) takes whole.
--
-- = What 'configureScenes' sets, together
--
-- * @vulkanSceneMode = PerWindowScenes@: each window has its own latest scene on the shared protected host;
--   there is no shared scene and no current-window global.
-- * @vulkanScene@ the window's initial scene ('initialGraphicsScene'): opaque black, empty, naming no texture.
-- * @vulkanInitialSceneHoldsNothing = True@, and only with that scene. The declaration lets a window that has
--   had no publication (revision 0) stay out of the release barrier, which is true exactly because the
--   initial scene references nothing a release frees. A later published empty scene is a real revision with
--   its own barrier entry and its own adoption; it does not take this exemption.
-- * @vulkanSceneLifecycle@ the /real/ lifecycle, over a ledger that exists before the host: the two hooks the
--   owner calls on every adoption and release are the ledger's from the host's first step. There is no slot
--   to be empty and no fallback that ignores them, so no adoption or release can be lost, and no revision
--   above zero can be accepted or adopted before they are installed: the host cannot be built, and so no
--   window published to, without them.
-- * @vulkanRenderer@ the per-window renderer, which records each frame with the window's own metrics
--   ("Hetoimasia.LuaEngine.Graphics.Scene.Render").
--
-- The texture backend's configuration ('Hetoimasia.LuaEngine.Graphics.Texture.configureHost') and the
-- window provider's ('Hetoimasia.LuaEngine.Graphics.Window.Configuration.configureWindows') are separate
-- pieces of the same host; none reads the others' fields.
--
-- = The maximum legal scene
--
-- 'sceneCapacity' proves, from the profile and the configuration alone, that the largest legal scene fits the
-- renderer's ring as the texture configuration sized it: every one of 4,096 sprites is one encoded instance of
-- 'instanceStride' bytes, a frame claims the ring in 16-byte steps, and the ring holds that many bytes twice for
-- every batch that can be in flight. A scene that fits when the ring is otherwise idle is never permanently
-- unrecordable; transient pressure from batches in flight is the native backend's backpressure, which skips the
-- frame and is retried, and is distinguishable from this size, which is fixed.
module Hetoimasia.LuaEngine.Graphics.Scene.Configuration
  ( -- * The session
    SceneSession (..)
  , newSceneSession

    -- * The host
  , configureScenes
  , SceneHostProblem (..)
  , checkSceneHostConfig

    -- * The maximum legal scene
  , SceneCapacity (..)
  , SceneCapacityRefused (..)
  , sceneCapacity
  ) where

import Data.Word (Word64)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare)
import Hetoimasia.GPU.Vulkan.GLFW (SceneMode (PerWindowScenes), SceneTargetKey, VulkanHostConfig (..))
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger
  ( GraphicsScene
  , SceneLedger
  , initialGraphicsScene
  , ledgerLifecycle
  , newSceneLedger
  )
import Hetoimasia.LuaEngine.Graphics.Scene.Render (RenderSlot, newRenderSlot, sceneRenderer)
import Hetoimasia.LuaEngine.Graphics.Texture.Configuration (Accounting (..), TextureGraphicsConfiguration, configurationAccounting)
import Hetoimasia.LuaEngine.Profile (Count (Count), CountLimit (FramelessBatches, FrameSlotsAggregate, SceneSprites), Profile, countLimit)
import Hetoimasia.Render.TwoD.Vulkan.Layout (instanceStride)

-- | What the scene part of a session is made of, made before the host is built.
data SceneSession = SceneSession
  { scenesLedger ∷ !(SceneLedger SceneTargetKey)
    -- ^ What the adopted revisions hold: the texture backend's release is gated on it.
  , scenesSlot ∷ !RenderSlot
    -- ^ Where the renderer hook finds the session's renderer; the composition fills it.
  , scenesInitial ∷ !(Prepared GraphicsScene)
    -- ^ The initial scene every window holds until it publishes.
  }

newSceneSession ∷ IO SceneSession
newSceneSession = SceneSession <$> newSceneLedger <*> newRenderSlot <*> prepare initialGraphicsScene

-- | Set the scene part of a host configuration. Every field is the one set that makes the others true.
configureScenes ∷ SceneSession → VulkanHostConfig GraphicsScene → VulkanHostConfig GraphicsScene
configureScenes session host =
  host
    { vulkanScene = scenesInitial session
    , vulkanSceneMode = PerWindowScenes
    , vulkanSceneLifecycle = ledgerLifecycle (scenesLedger session)
    , vulkanRenderer = sceneRenderer (scenesSlot session)
    , vulkanInitialSceneHoldsNothing = True
    }

-- | What is wrong with a host configuration for scenes.
data SceneHostProblem
  = -- | The host carries one scene for every window.
    SceneModeNotPerWindow
  | -- | The host does not declare that its initial scene holds nothing: the barrier of a release would wait
    -- for every window that has never published.
    InitialSceneNotDeclared
  deriving (Eq, Show)

-- | The checks a borrowed host's configuration can answer for itself. The lifecycle and the renderer are
-- functions and cannot be compared: 'configureScenes' is the one way to set them, and a host built another
-- way is the assembler's to answer for.
checkSceneHostConfig ∷ VulkanHostConfig scene → [SceneHostProblem]
checkSceneHostConfig host =
  [SceneModeNotPerWindow | vulkanSceneMode host /= PerWindowScenes]
    <> [InitialSceneNotDeclared | not (vulkanInitialSceneHoldsNothing host)]

-- | The ring bytes the largest legal scene needs, against the ring the configuration has.
data SceneCapacity = SceneCapacity
  { capacityInstanceBytes ∷ !Word64
    -- ^ One scene's encoded instances: the sprite limit times the instance stride.
  , capacityClaimBytes ∷ !Word64
    -- ^ The same, padded to the ring's claim alignment.
  , capacityRingBytes ∷ !Word64
  , capacityBatches ∷ !Word64
    -- ^ The frame slots and frame-less batches that can be in flight at once.
  , capacityFits ∷ !Word64
    -- ^ How many maximum scenes the otherwise idle ring holds.
  }
  deriving (Eq, Show)

data SceneCapacityRefused
  = -- | One maximum scene does not fit the idle ring: the claim and the ring.
    SceneLargerThanRing !Word64 !Word64
  | -- | The ring cannot hold a maximum scene for every batch that can be in flight, twice over.
    RingBelowBatches !Word64 !Word64
  deriving (Eq, Show)

sceneCapacity ∷ Profile → TextureGraphicsConfiguration → Either SceneCapacityRefused SceneCapacity
sceneCapacity profile configuration
  | claim > ring = Left (SceneLargerThanRing claim ring)
  | fits < 2 * batches = Left (RingBelowBatches (fits) (2 * batches))
  | otherwise = Right (SceneCapacity instances claim ring batches fits)
  where
    count limit = let Count value = countLimit profile limit in value
    sprites = count SceneSprites
    batches = count FrameSlotsAggregate + count FramelessBatches
    instances = sprites * fromIntegral instanceStride
    claim = alignUp instances 16
    ring = accountingRingBytes (configurationAccounting configuration)
    fits = ring `div` claim
    alignUp value granule = ((value + granule - 1) `div` granule) * granule
