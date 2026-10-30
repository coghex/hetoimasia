-- | The graphics operations of the M1 Lua facade (LFE-21), composed over the real providers: the texture pipeline
-- (LFE-16/17), the window provider (LFE-18) and scene publication (LFE-20).
--
-- = What this is
--
-- The CPU facade ("Hetoimasia.LuaEngine.Facade") owns every Lua-visible rule of @api.content.texture@,
-- @api.window.open@, @api.scene.publish@ and @api.texture.release@: who may call, in which role and phase, with what
-- arguments, and what an ordinary error is. It imports no texture, scene, window or GPU module and is handed
-- 'GraphicsServices', abstract operations. This module is the concrete composition of those operations over the
-- session's services and nothing else: 'graphicsInjection' is the value a session is composed with
-- ('Hetoimasia.LuaEngine.Session.sxGraphics'), and the session calls it once for each role's VM.
--
-- = Who owns what
--
-- * The pipeline, the window provider, the scene publisher and everything under them are the /assembly's/: they are
--   borrowed here, made before the session and closed after it, and a session never closes them.
-- * A VM's /lending and lease scope/ are made here, one for each VM, and handed to the VM's scheduled owner. Their
--   capacity is the profile's texture leases plus its window slots for one UI instance (16 + 1): every texture and
--   window a UI instance can hold, pending, live or retiring, is charged by the provider's bank before the host's
--   lease charge is reached, so a lease the host would refuse is a lease an M1 reservation would already have
--   refused as @busy@. The host's lease capacity is therefore never the first bank to answer, and the generic
--   host's faulting refusal cannot be reached by an accepted admission.
-- * A UI instance's /texture owner/ and /window owner/ are made when the facade declares the instance and closed when
--   the facade forgets it (its settlement observed); the table that holds them is written by the declaring thread
--   and read by the instance's owner thread, in STM. A logical instance gets owners of the logical role, which
--   refuse; the facade refuses a logical call before they are ever consulted.
--
-- Nothing here enters Lua, waits, or keeps a registry that outlives the VM it was made for.
module Hetoimasia.LuaEngine.Graphics.Facade
  ( GraphicsFacade (..)
  , graphicsInjection
  , GraphicsCompositionRefused (..)
  , facadeLeaseCapacity
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, readTVarIO)
import Control.Exception (Exception, throwIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Typeable (Typeable)
import Hetoimasia.LuaEngine.Facade
  ( GraphicsInjection (..)
  , GraphicsServices (..)
  , GraphicsStart (..)
  , GraphicsVm (..)
  )
import Hetoimasia.LuaEngine.Graphics.Scene.Publish (PublishHooks, ScenePublisher, graphicsPublishBindingWith, publisherGatedBy)
import Hetoimasia.LuaEngine.Graphics.Window.Provider
  ( WindowOwner
  , WindowProvider
  , WindowStart (..)
  , askWindow
  , closeWindowOwner
  , newWindowOwner
  , startWindow
  , windowArgumentCheck
  , windowEndpoint
  , windowHandleType
  , windowService
  )
import qualified Hetoimasia.LuaEngine.Graphics.Window.Provider as Window
import Hetoimasia.LuaEngine.Graphics.Window.Request (refusalText)
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.LuaEngine.Profile
  ( Count (Count)
  , CountLimit (TextureLeasesPerUiInstance, WindowSlotsPerUiInstance)
  , Profile
  , countLimit
  )
import Hetoimasia.LuaEngine.Scene (sceneLimits)
import Hetoimasia.LuaEngine.Texture
  ( TextureOwner
  , TextureRequest (..)
  , TextureRole (LogicalRole, PresentationRole)
  , TextureStart (..)
  , TexturePipeline
  , closeTextureOwner
  , newTextureOwner
  , releaseTexture
  , releaseWord
  , startTexture
  , textureArgumentCheck
  , textureEndpoint
  , textureHandleType
  , textureService
  , withTextureOr
  )
import Hetoimasia.Scripting.Lua.Admission (Necessity (OptionalRequest, RequiredRequest))
import Hetoimasia.Scripting.Lua.Lease (leaseCapabilityType, newLeases)
import Hetoimasia.Scripting.Lua.Lending (newLending)

-- | The session's graphics services this composition borrows.
data GraphicsFacade target = GraphicsFacade
  { gfProfile ∷ !Profile
  -- ^ The validated profile every VM's request policy is read from: the pipeline's must be this one.
  , gfPipeline ∷ !TexturePipeline
  , gfProvider ∷ !(WindowProvider target)
  , gfPublisher ∷ !(ScenePublisher target)
  , gfPublishHooks ∷ !PublishHooks
  -- ^ The publication's test seams: 'noPublishHooks' in production. An example holds a publication between its check and
  -- its commit with them, to land a stop there.
  }

-- | Why a VM's graphics could not be composed: a failure of the composition, with its reason, and nothing of a
-- script's.
newtype GraphicsCompositionRefused = GraphicsCompositionRefused Text
  deriving (Eq, Show)

instance Exception GraphicsCompositionRefused

-- | The lease capacity of one UI instance: the texture leases and the window slots the profile gives it.
facadeLeaseCapacity ∷ Profile → Int
facadeLeaseCapacity profile = number TextureLeasesPerUiInstance + number WindowSlotsPerUiInstance
  where
    number limit = let Count n = countLimit profile limit in fromIntegral n

-- | One instance's two owners.
data Owners = Owners !TextureOwner !WindowOwner

-- | The injection a session is composed with: for each role's VM, its own lending and lease scope over the shared
-- providers.
graphicsInjection ∷ ∀ target. Typeable target ⇒ GraphicsFacade target → GraphicsInjection
graphicsInjection config = GraphicsInjection $ \vm → do
  let requests = gvRequests vm
      profile = gfProfile config
  texture ← either (\_ → throwIO (GraphicsCompositionRefused "the request policy and the texture pipeline were built from different profiles")) pure (textureService requests (gfPipeline config))
  limits ← either (\refused → throwIO (GraphicsCompositionRefused ("the scene limits were refused: " <> Text.pack (show refused)))) pure (sceneLimits profile)
  lending ← newLending
  leases ← newLeases lending (facadeLeaseCapacity profile)
  owners ← newTVarIO (Map.empty ∷ Map Text Owners)
  let window = windowService requests (gfProvider config)
      textureRole = case gvRole vm of
        Gameplay → LogicalRole
        Presentation → PresentationRole
      windowRole = case gvRole vm of
        Gameplay → Window.LogicalRole
        Presentation → Window.PresentationRole
      ownersOf ∷ Text → IO Owners
      ownersOf identity =
        readTVarIO owners >>= \held → case Map.lookup identity held of
          Just found → pure found
          Nothing → throwIO (GraphicsCompositionRefused "no graphics owner was declared for the instance")
  pure
    GraphicsServices
      { gsLending = lending
      , gsLeases = leases
      , gsTypes = [leaseCapabilityType leases textureHandleType, leaseCapabilityType leases windowHandleType]
      , gsEndpoints = [textureEndpoint texture, windowEndpoint window]
      , gsDeclare = \identity → do
          made ← Owners <$> newTextureOwner (gfPipeline config) textureRole <*> newWindowOwner (gfProvider config) windowRole
          atomically (modifyTVar' owners (Map.insert identity made))
      , gsForget = \identity → do
          held ← atomically $ do
            found ← Map.lookup identity <$> readTVar owners
            modifyTVar' owners (Map.delete identity)
            pure found
          mapM_ (\(Owners textureOwner windowOwner) → closeTextureOwner textureOwner >> closeWindowOwner windowOwner) held
      , gsTextureCheck = \identity key optional owner values → do
          Owners textureOwner _ ← ownersOf identity
          textureArgumentCheck texture (const (TextureRequest textureOwner key (necessity optional))) owner values
      , gsTextureStart = \identity key optional context → do
          Owners textureOwner _ ← ownersOf identity
          startTexture texture (TextureRequest textureOwner key (necessity optional)) context <&> \case
            TextureStarted started → GraphicsStarted started
            TextureRefused why → GraphicsRefused why
      , gsWindowCheck = \identity title width height owner values → do
          Owners _ windowOwner ← ownersOf identity
          case askWindow windowOwner title width height of
            Left refusal → pure (Just (refusalText refusal))
            Right ask → windowArgumentCheck window (const ask) owner values
      , gsWindowStart = \identity title width height context → do
          Owners _ windowOwner ← ownersOf identity
          case askWindow windowOwner title width height of
            -- The check made the same request from the same copied values and accepted it.
            Left refusal → throwIO (GraphicsCompositionRefused ("a window request was valid at its check and is not at its action: " <> refusalText refusal))
            Right ask → startWindow window ask context <&> \case
              WindowStarted started → GraphicsStarted started
              WindowRefused why → GraphicsRefused why
      , gsPublish = \name precondition → graphicsPublishBindingWith (gfPublishHooks config) name precondition (publisherGatedBy (gvTakesWork vm) (gfPublisher config)) limits leases
      , gsReleaseCheck = \key →
          -- (borrowing is how the lease says whose it is; a lease that has ended is the release path's to answer)
          withTextureOr leases key (\why → pure (if Text.isInfixOf "another" why then Just why else Nothing)) (\_ → pure Nothing)
      , gsRelease = \key → releaseWord <$> releaseTexture leases key
      }
  where
    necessity optional = if optional then OptionalRequest else RequiredRequest
    (<&>) = flip fmap
