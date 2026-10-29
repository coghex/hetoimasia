-- | Publishing a copied scene to the caller's ready window (LFE-20): the one boundary at which authority is
-- checked and the scene becomes the owner's to adopt.
--
-- = The operation
--
-- 'publishScene' takes the calling instance's window handle (its lease key) and a 'PreparedScene' (LFE-19's
-- complete check of a copied scene) and either publishes the whole scene as the window's latest value or
-- refuses it whole, leaving the previous publication as it was. It never waits for GPU work, a free adopted
-- revision, a displayed frame or a lock held across either; it adds no revision receipt, request handle,
-- retry or queue of drafts. A window has one latest published scene (the host's snapshot, replaced in
-- execution order, which the owner may skip past) and one draft at a time, the call's own value on the
-- calling thread. The graphics facade (LFE-21) binds it ('graphicsPublishBinding'); which namespace and name
-- it is installed under is the facade's.
--
-- = Authority, and where it is checked
--
-- Preparation (LFE-19) is a check at one moment. Publication asks again, at the boundary, and /holds the
-- answer in place/ until the host has the scene:
--
-- 1. the window lease is borrowed ('withWindowOr'): refused when it has ended, is another instance's (a peer
--    sharing the VM included) or holds another kind of handle;
-- 2. every distinct texture the scene names is borrowed through the instance's own lease
--    ('withTextureOr'), and its identity and dimensions must be the prepared ones. The borrow is the pin:
--    while it lasts the lease cannot be released or ended (the collection answers a retirement of a borrowed
--    member as in use), so no release of a texture the scene names can run between this check and the
--    host holding the scene. A prepared identity of a texture that has since been released and replaced by
--    another at the same index is not that texture;
-- 3. one transaction reads the instance's and the provider's admission (an ending instance or a stopped provider is
--    refused), the window's incarnation (it must still be the admitted, attached one), and the renderer registry's own
--    flag for each texture's exact handle, and, in the same transaction, makes the scene the window's latest value.
--    Nothing that closes can land between the reads and the write.
--
-- The valid outcomes of a race are the two the specification names. If the publication wins, the whole scene
-- is accepted, and a release that follows asks for a barrier that includes it: the release lane waits until
-- the owner has adopted every revision published before the request ('requestVulkanRelease'), the lifecycle
-- hooks then hold what the adopted scene names ("Hetoimasia.LuaEngine.Graphics.Scene.Ledger"), and the
-- table release is deferred while any adoption holds it. If a release or an end wins, the borrow refuses the
-- whole publication and the previous scene stays. A texture released before the call is refused by its
-- lease, and nothing re-grants it: an older scene holding the backing image does not make the handle usable.
--
-- No resource is freed between validation and the owner becoming able to adopt the scene, because nothing
-- can free one: the lease is pinned until the host holds the scene, the host's barrier covers the scene until
-- it is adopted, and the ledger covers it from adoption until its release.
--
-- = Refusal, and what is fatal
--
-- Every refusal, including the ones found at the commit, is an ordinary Lua error from the binding
-- ('graphicsPublishCommit'): @pcall@ catches it, the previous scene stays, and the next valid call works. The host
-- allows an ordinary error only before a binding's action, so the commit is made in the binding's argument check,
-- which runs once per call on the calling thread; the action has nothing left to do. A defect of the host or the
-- registry, an exception or a cancellation is raised, never refused: nothing here downgrades a defect or clears a
-- fatal latch.
--
-- = Owned state, threads and lifetime
--
-- None is owned. The call runs on the calling instance's thread inside the binding, borrows leases for its
-- duration, keeps no draft beyond it, and holds no lock of its own: the only waiting is a bounded CPU
-- publication, one STM read and one STM write of the host's snapshot, none across a GPU wait, a native
-- teardown or a callback into Lua. Lock order, where locks exist: the collection's borrows (window, then
-- each texture in prepared order) outside, the host's snapshot transaction innermost. Nothing inside takes
-- the renderer registry's lock; the registry is read in one transaction.
module Hetoimasia.LuaEngine.Graphics.Scene.Publish
  ( -- * The publisher
    ScenePublisher
  , scenePublisher
  , scenePublisherOver
  , HostAnswer (..)
  , targetAnswer

    -- * Publishing
  , PublishResult (..)
  , PublishRefusal (..)
  , publishRefusalText
  , publishScene
  , PublishHooks (..)
  , noPublishHooks
  , publishSceneWith

    -- * The binding
  , graphicsPublishCommit
  , graphicsPublishBinding
  , graphicsPublishBindingWith
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Monad (when)
import qualified Data.ByteString as ByteString
import Data.Functor ((<&>))
import Data.Text (Text)
import Data.Typeable (Typeable)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Data.Word (Word64)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare)
import Hetoimasia.GPU.Vulkan.GLFW (TextureHandle (..), WindowScenePublication (..))
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene, graphicsScene)
import Hetoimasia.LuaEngine.Graphics.Texture.Port (TextureRef (..), textureRefOf)
import Hetoimasia.LuaEngine.Graphics.Window.Host (WindowTarget (..))
import Hetoimasia.LuaEngine.Graphics.Window.Provider
  ( WindowProvider
  , WindowResource (..)
  , WindowRole (PresentationRole)
  , ownerRole
  , ownerTaking
  , providerTaking
  , windowHandleType
  , withWindowOr
  )
import Hetoimasia.LuaEngine.Scene
  ( PreparedScene (preparedOwner)
  , SceneLimits
  , TextureUse (..)
  , prepareScene
  , refusalReasonText
  , sceneSchema
  , scenePublishLimits
  , textureUses
  )
import Hetoimasia.LuaEngine.Texture (TextureView (viewIdentity), withTextureOr)
import Hetoimasia.Render.TwoD.Vulkan.Textures (Textures, fromBackendHandle, isReleased)
import Hetoimasia.Scripting.Lua.Lease (Leases)
import Hetoimasia.Scripting.Lua.Registration
  ( ArgumentCheck
  , Binding
  , stateOperation
  , withArgumentCheck
  , withArgumentLimits
  )
import Hetoimasia.Scripting.Lua.Value (Schema (SCapability), Value (VCapability), capabilityKey, capabilityTypeName)

-- | What a publication reads of the session: the renderer registry that knows each texture's exact handle,
-- the window provider whose admission a stop closes, and the two things a window's capability does.
data ScenePublisher target = ScenePublisher
  { publisherTextures ∷ !Textures
  , publisherTaking ∷ STM Bool
  , publisherPublish ∷ target → Prepared GraphicsScene → STM HostAnswer
    -- ^ Make the scene the window's latest value, as a transaction: the authority checks and this are one atomic
    -- step. Never waits.
  , publisherUsable ∷ target → STM Bool
    -- ^ Whether the capability's window incarnation is still the admitted, attached one.
  }

-- | What the host answered a publication, without the window identities its own answer carries.
data HostAnswer
  = HostAccepted
  | HostAnsweredUnknown
  | HostAnsweredClosed
  | HostAnsweredShared
  deriving (Eq, Show)

-- | A publisher over the session's registry and the window provider, publishing through the capability
-- the production window port yields.
scenePublisher ∷ Textures → WindowProvider (WindowTarget GraphicsScene) → ScenePublisher (WindowTarget GraphicsScene)
scenePublisher textures provider = scenePublisherOver textures provider targetAnswer targetUsable

-- | The host's answer to a publication through the production window capability, without the window identities
-- its own answer carries.
targetAnswer ∷ WindowTarget GraphicsScene → Prepared GraphicsScene → STM HostAnswer
targetAnswer target scene =
  targetPublishSTM target scene <&> \case
    WindowScenePublished _ _ → HostAccepted
    WindowSceneUnknown _ → HostAnsweredUnknown
    WindowSceneClosed _ → HostAnsweredClosed
    WindowScenesNotEnabled _ → HostAnsweredShared

-- | The same over any window capability: the lifecycle suite's, which has no window identity to mint.
scenePublisherOver ∷ Textures → WindowProvider target → (target → Prepared GraphicsScene → STM HostAnswer) → (target → STM Bool) → ScenePublisher target
scenePublisherOver textures provider = ScenePublisher textures (providerTaking provider)

-- | What a publication came to. Success carries no revision and no receipt: the scene is the window's
-- latest value, and nothing is promised about when, or whether, a frame shows it.
data PublishResult
  = Published
  | Refused !PublishRefusal
  deriving (Eq, Show)

-- | Why a publication was refused whole, with the previous scene unchanged. Every field is a fixed word or a
-- number; nothing authored is in any of them.
data PublishRefusal
  = -- | The window handle's lease: ended, another instance's, or another kind of handle (the lease's text).
    WindowRefused !Text
  | -- | The instance is not a presentation instance.
    NotPresentation
  | -- | The instance has ended.
    InstanceEnded
  | -- | The window provider takes no new work: the session is stopping or has stopped.
    PublicationStopped
  | -- | The window is not the admitted, attached incarnation: not ready yet, closing or retired.
    WindowNotReady
  | -- | The distinct texture at this position, in prepared order, was refused by its lease (the text).
    TextureRefused !Int !Text
  | -- | The texture at this position is not the one the scene was prepared against.
    TextureChanged !Int
  | -- | The registry reports the texture at this position, by its exact handle, released.
    TextureReleased !Int
  | -- | The host holds no such window incarnation: it was never created, or it has ended.
    HostWindowUnknown
  | -- | The host's publications have ended with its exit.
    HostClosed
  | -- | The host carries one scene for every window: it was not configured for per-window scenes.
    HostNotPerWindow
  deriving (Eq, Show)

-- | A refusal as the bounded text a script or a log sees: fixed words and numbers, at most 160 bytes.
publishRefusalText ∷ PublishRefusal → Text
publishRefusalText refusal = clip $ case refusal of
  WindowRefused why → "window refused: " <> why
  NotPresentation → "scene publication is presentation-instance hook work"
  InstanceEnded → "the instance has ended"
  PublicationStopped → "scene publication is stopped"
  WindowNotReady → "the window is not ready"
  TextureRefused index why → "texture " <> number index <> " refused: " <> why
  TextureChanged index → "texture " <> number index <> " is not the one the scene was prepared against"
  TextureReleased index → "texture " <> number index <> " has been released"
  HostWindowUnknown → "the host holds no such window"
  HostClosed → "the host's publications have ended"
  HostNotPerWindow → "the host carries one scene for every window"
  where
    number = Text.pack . show
    clip text
      | ByteString.length (Encoding.encodeUtf8 text) <= 160 = text
      | otherwise = Text.take 157 text <> "..."

-- | Where a test may hold the publication at a precise place. Production uses none of them.
data PublishHooks = PublishHooks
  { hookBeforeBoundary ∷ IO ()
    -- ^ After the caller's preparation, before any authority is checked at the boundary.
  , hookBeforeCommit ∷ IO ()
    -- ^ After the final check, with every lease borrowed, before the host is handed the scene.
  , hookAfterCommit ∷ IO ()
    -- ^ After the host holds the scene, before the call returns its acknowledgement.
  }

noPublishHooks ∷ PublishHooks
noPublishHooks = PublishHooks (pure ()) (pure ()) (pure ())

-- | Publish a prepared scene to the window the lease key names.
publishScene ∷ Typeable target ⇒ ScenePublisher target → Word64 → PreparedScene → IO PublishResult
publishScene = publishSceneWith noPublishHooks

-- | 'publishScene' with the test seams.
publishSceneWith ∷ ∀ target. Typeable target ⇒ PublishHooks → ScenePublisher target → Word64 → PreparedScene → IO PublishResult
publishSceneWith hooks publisher windowKey prepared = do
  hookBeforeBoundary hooks
  withWindowOr @target leases windowKey (pure . Refused . WindowRefused) $ \resource →
    pinned (zip [1 ..] (textureUses prepared)) $ do
      hookBeforeCommit hooks
      scene ← prepare (graphicsScene prepared)
      -- One transaction: the authority is read and the scene is made the window's latest value in the same step, so
      -- no closure of the instance, the provider or the window's incarnation can land between them. A refusal
      -- writes nothing.
      committed ← atomically $
        boundary publisher resource (zip [1 ..] (textureUses prepared)) >>= \case
          Just refusal → pure (Refused refusal)
          Nothing →
            publisherPublish publisher (resourceTarget resource) scene <&> \case
              HostAccepted → Published
              HostAnsweredUnknown → Refused HostWindowUnknown
              HostAnsweredClosed → Refused HostClosed
              HostAnsweredShared → Refused HostNotPerWindow
      when (committed == Published) (hookAfterCommit hooks)
      pure committed
  where
    leases = preparedOwner prepared
    -- Each distinct texture borrowed, in prepared order, and its prepared identity compared; the action runs
    -- with all of them pinned.
    pinned ∷ [(Int, TextureUse)] → IO PublishResult → IO PublishResult
    pinned [] inner = inner
    pinned ((index, use) : rest) inner =
      withTextureOr leases (useLease use) (pure . Refused . TextureRefused index) $ \view →
        if view /= useView use
          then pure (Refused (TextureChanged index))
          else pinned rest inner

-- | The facts a publication decides on, read in one transaction.
boundary ∷ ScenePublisher target → WindowResource target → [(Int, TextureUse)] → STM (Maybe PublishRefusal)
boundary publisher resource uses = do
  taking ← ownerTaking (resourceOwner resource)
  provider ← publisherTaking publisher
  usable ← publisherUsable publisher (resourceTarget resource)
  released ← firstReleased uses
  pure $ case () of
    _
      | ownerRole (resourceOwner resource) /= PresentationRole → Just NotPresentation
      | not taking → Just InstanceEnded
      | not provider → Just PublicationStopped
      | not usable → Just WindowNotReady
      | Just index ← released → Just (TextureReleased index)
      | otherwise → Nothing
  where
    firstReleased [] = pure Nothing
    firstReleased ((index, use) : rest) = do
      flagged ← isReleased (publisherTextures publisher) (handleOf (viewIdentity (useView use)))
      if flagged then pure (Just index) else firstReleased rest
    handleOf identity =
      let TextureRef index generation = textureRefOf identity
       in fromBackendHandle (TextureHandle index generation)

-- The binding -----------------------------------------------------------------------------------------

-- | The publication as the binding's argument check: the place the host lets a refusal be an ordinary Lua error.
--
-- A refusal the host makes after a binding's action is a typed fault of the call, which a @pcall@ cannot hide, and
-- no public path raises an ordinary error from inside an action. Stop, closure and an ending instance are
-- /expected/ refusals ("Scene publication after the stop latch is an ordinary Lua error"), and they can land between
-- any earlier check and the commit. So the commit is made here, once per call, on the calling thread, after the
-- facade's own precondition and the scene's own check ('prepareScene'), and its result is the check's: 'Nothing'
-- when the scene was published, otherwise the bounded reason, which the host raises as an ordinary Lua error with the
-- previous publication untouched. The binding's action then has nothing left to do. An exception (a defect of the
-- host or the registry, a cancellation) is the application's failure, never a refusal.
graphicsPublishCommit ∷ ∀ target. Typeable target ⇒ PublishHooks → ArgumentCheck → ScenePublisher target → SceneLimits → Leases → ArgumentCheck
graphicsPublishCommit hooks precondition publisher limits leases owner values =
  precondition owner values >>= \case
    Just why → pure (Just why)
    Nothing → case values of
      [VCapability window, scene]
        | capabilityTypeName window /= windowHandleType → pure (Just "the first argument is not a window")
        | otherwise →
            prepareScene limits leases scene >>= \case
              Left refusal → pure (Just (refusalReasonText refusal))
              Right prepared →
                publishSceneWith hooks publisher (capabilityKey window) prepared <&> \case
                  Published → Nothing
                  Refused refusal → Just (publishRefusalText refusal)
      other → pure (Just (Text.pack ("publishing takes a window and a scene, not " <> show (length other) <> " arguments")))

-- | A binding that takes a window and a scene, refuses with an ordinary Lua error whatever can be known up to the
-- commit, and otherwise publishes ('graphicsPublishCommit'). Answers nothing to the script.
--
-- Its arguments cross together, so it reads them under the scene limits' call-level limits ('scenePublishLimits'):
-- the scene's own widened by the window handle beside it, which the profile's validation guarantees room for.
graphicsPublishBinding ∷ ∀ target. Typeable target ⇒ Text → ArgumentCheck → ScenePublisher target → SceneLimits → Leases → Binding
graphicsPublishBinding = graphicsPublishBindingWith noPublishHooks

-- | The same with the test seams of 'publishSceneWith'.
graphicsPublishBindingWith ∷ ∀ target. Typeable target ⇒ PublishHooks → Text → ArgumentCheck → ScenePublisher target → SceneLimits → Leases → Binding
graphicsPublishBindingWith hooks name precondition publisher limits leases =
  withArgumentLimits (scenePublishLimits limits) $
    withArgumentCheck (graphicsPublishCommit hooks precondition publisher limits leases) $
      stateOperation name [SCapability windowHandleType, sceneSchema] [] (\_ → pure [])
