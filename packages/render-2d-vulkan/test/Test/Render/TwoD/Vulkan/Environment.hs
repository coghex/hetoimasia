-- | The environment the window-host examples share: the headless native layer,
-- the texture and chunk registries, an adapter over a coordinated stand-in for
-- the window host, and the owner's moves (adopting a revision, releasing it,
-- running the release actions the host queued).
--
-- The stand-in host publishes scenes per window with rising revisions and
-- queues the release actions it is asked for. The example plays the owner: it
-- adopts a revision (running the adapter's adoption hook with the scene the host
-- published), releases it, and runs the queued release actions when it says the
-- host's barrier is met.
module Test.Render.TwoD.Vulkan.Environment
  ( Queued (..)
  , Fake (..)
  , Env (..)
  , newFake
  , withEnv
  , withEnvOffering
  , bytesOf
  , decodedWith
  , registered
  , windowSnapshot
  , sprite
  , publishOk
  , adopt
  , releaseRevision
  , runQueued
  , runNext
  , resolves
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), throwIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word32)
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (ImageFormat (..), Refusal, validateRingSize, validateStorageWindow)
import Hetoimasia.GPU.Vulkan.Native.TextureTable (LookupEntry (..), TableView (..), readTable, validateTableConfig)
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import qualified Hetoimasia.Render.Api.Texture.Backend as ApiBackend
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Material (defaultMaterial)
import Hetoimasia.Render.TwoD.Snapshot
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Chunks (Retained, newRetained)
import Hetoimasia.Render.TwoD.Vulkan.Textures
import Hetoimasia.Render.TwoD.Vulkan.Window
import Numeric.Natural (Natural)
import Test.Hspec (expectationFailure)
import Test.Render.TwoD.Vulkan.StandIn

-- | A release action the stand-in host was asked to queue, and whether it asked
-- for the barrier (the request) or nothing (the plain owner action).
data Queued = Queued !Bool ReleaseBody

data Fake = Fake
  { fakePublished ∷ !(TVar [(Int, Natural, Scene2D)])
  , fakeQueued ∷ !(TVar [Queued])
  , fakeRefusing ∷ !(TVar Bool)
    -- ^ Whether the host refuses the release requests it is asked for.
  , fakeCapacity ∷ !(TVar (Maybe Int))
    -- ^ How many actions the host's queue holds, when bounded.
  , fakeCancel ∷ !(TVar Bool)
    -- ^ Whether the next request is interrupted by a cancellation.
  , fakeCancelPlain ∷ !(TVar Bool)
    -- ^ Whether the next barrier-free action is.
  , fakeAsked ∷ !(TVar (Int, Int))
    -- ^ How many actions were admitted with a barrier and without one.
  }

data Env = Env
  { envRig ∷ !Rig
  , envTextures ∷ !Textures
  , envRetained ∷ !Retained
  , envAdapter ∷ !(Adapter Int)
  , envFake ∷ !Fake
  , envRenderer ∷ !Render.Renderer
  }

-- | A stand-in host that holds these windows.
newFake ∷ [Int] → IO (Host Int, Fake)
newFake windows = do
  revisions ← newTVarIO (Map.fromList [(window, 0) | window ← windows])
  published ← newTVarIO []
  queued ← newTVarIO []
  refusing ← newTVarIO False
  capacity ← newTVarIO Nothing
  asked ← newTVarIO (0, 0)
  cancel ← newTVarIO False
  cancelPlain ← newTVarIO False
  let publish window scene = atomically $ do
        known ← Map.lookup window <$> readTVar revisions
        case known of
          Nothing → pure HostWindowUnknown
          Just revision → do
            modifyTVar' revisions (Map.insert window (revision + 1))
            modifyTVar' published (<> [(window, revision + 1, scene)])
            pure (HostPublished (revision + 1))
      admit ∷ Bool → ReleaseBody → IO (Either Text ())
      admit barrier body = atomically $ do
        refused ← readTVar refusing
        room ← readTVar capacity
        held ← length <$> readTVar queued
        if refused || maybe False (held >=) room
          then pure (Left "the host's queue is full")
          else do
            modifyTVar' queued (<> [Queued barrier body])
            modifyTVar' asked (\(b, p) → if barrier then (b + 1, p) else (b, p + 1))
            pure (Right ())
      request ∷ ReleaseBody → IO (Either Text ())
      request body = do
        interrupted ← atomically (readTVar cancel <* writeTVar cancel False)
        if interrupted then throwIO ThreadKilled else admit True body
      plain ∷ ReleaseBody → IO (Either Text ())
      plain body = do
        interrupted ← atomically (readTVar cancelPlain <* writeTVar cancelPlain False)
        if interrupted then throwIO ThreadKilled else admit False body
  pure (Host publish request plain, Fake published queued refusing capacity cancel cancelPlain asked)

withEnv ∷ [Int] → (Env → IO a) → IO a
withEnv = withEnvOffering [Depth32Float, Depth24, Depth16]

-- | The same over a device that offers only these depth formats.
withEnvOffering ∷ [ImageFormat] → [Int] → (Env → IO a) → IO a
withEnvOffering offered windows action = do
  rig ← newRigOffering offered
  renderer ←
    newRenderer
      rig
      Render.Configuration
        { Render.configurationRing = either (error . show) id (validateRingSize (64 * 1024))
        , Render.configurationRegionWindow = either (error . show) id (validateStorageWindow 4096)
        , Render.configurationTable = either (error . show) id (validateTableConfig 16 8 4)
        }
  resetJournal rig
  textures ← newTextures
  retained ← newRetained
  (host, fake) ← newFake windows
  adapter ← newAdapter host textures retained renderer
  action (Env rig textures retained adapter fake renderer)

-- | Four texels of this colour.
bytesOf ∷ Word32 → ByteString
bytesOf shade = ByteString.concat (replicate 4 (ByteString.pack [fromIntegral shade, 0, 0, 255]))

-- | A decoded image whose mark the example states.
decodedWith ∷ Bool → DecodedImage
decodedWith binary = DecodedImage TexelRgba8Linear 2 2 [bytesOf 1] binary

-- | Make, upload and register a texture.
registered ∷ Env → Word32 → Bool → MarkPolicy → IO Api.TextureHandle
registered env shade binary policy = do
  image ← uploadedTexture (envRig env) (bytesOf shade)
  registerTexture (builders (envRig env)) (envTextures env) image (decodedWith binary) policy >>= either (fail . show) pure

-- | A window snapshot of one UI layer naming these textures.
windowSnapshot ∷ [Api.TextureHandle] → Snapshot
windowSnapshot handles =
  Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 16 16)) defaultViewSettings [] [UiLayer (map sprite handles)]]]

sprite ∷ Api.TextureHandle → Instance
sprite handle =
  Instance
    { instanceTransform = fromColumns (V2 4 0) (V2 0 4) (V2 0 0)
    , instanceUv = UvRect 0 0 1 1
    , instanceTexture = handle
    , instanceDepthKey = 0
    , instanceTint = Tint 255 255 255 255
    , instanceSampler = SamplerDefault
    , instanceTranslucent = False
    , instanceAdditive = False
    , instanceClip = 0
    , instanceParameter = 0
    , instanceMaterial = defaultMaterial
    }

-- | Publish, expecting acceptance.
publishOk ∷ Env → Int → [Api.TextureHandle] → IO Natural
publishOk env window handles = publish2DSnapshot (envAdapter env) window (windowSnapshot handles) >>= either (fail . ("refused: " <>) . show) pure

-- | The owner adopts this revision of the window: the adapter's hook with the
-- scene the host published.
adopt ∷ Env → Int → Natural → IO ()
adopt env window revision = do
  published ← readTVarIO (fakePublished (envFake env))
  case [scene | (w, r, scene) ← published, w == window, r == revision] of
    scene : _ → adapterAdopted (envAdapter env) window revision scene
    [] → expectationFailure ("revision " <> show revision <> " of window " <> show window <> " was never published")

-- | The owner has released this revision: its last recording is over.
releaseRevision ∷ Env → Int → Natural → IO ()
releaseRevision env = adapterReleased (envAdapter env)

-- | The host's barrier is met: run every release action it queued, in order,
-- on the owner's thread (here, the example's), with the real builders.
runQueued ∷ Env → IO [Either Refusal ()]
runQueued env = do
  queued ← readTVarIO (fakeQueued (envFake env))
  atomically (writeTVar (fakeQueued (envFake env)) [])
  mapM (\(Queued _ body) → body (builders (envRig env))) queued

-- | The host runs only the first queued action, on the owner's thread.
runNext ∷ Env → IO [Either Refusal ()]
runNext env = do
  queued ← readTVarIO (fakeQueued (envFake env))
  case queued of
    [] → pure []
    Queued _ body : rest → do
      atomically (writeTVar (fakeQueued (envFake env)) rest)
      (: []) <$> body (builders (envRig env))

-- | Whether the table resolves this handle to its own slot now.
resolves ∷ Env → Api.TextureHandle → IO Bool
resolves env handle =
  atomically (readTable (rigRecording (envRig env))) >>= \case
    Nothing → pure False
    Just view →
      pure $ case Map.lookup (ApiBackend.handleIndex handle) (tableViewMapping view) of
        Just entry → entryGeneration entry == ApiBackend.handleGeneration handle && entryGeneration entry /= 0
        Nothing → False
