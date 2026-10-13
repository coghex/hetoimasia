-- | The image2d sample's session (R2D-8): the constructions it needs from a
-- host, what a host must offer, and the steps both of its modes share —
-- decoding the committed images, making and uploading their textures, and
-- registering them with @render-2d-vulkan@.
--
-- The sample depends on the native backend and @render-2d-vulkan@ alone, and
-- names nothing of the window integration, so the integration's native suite
-- can run it unchanged: the sample's executable and that suite each fill
-- 'Builders' and 'Host' from the constructions their host lends.
--
-- = State
--
-- 'Prepared' holds the renderer, the texture registry and the images' handles.
-- It is made once on the graphics owner's thread and the uploads' waits, then
-- read from any thread; nothing in it changes afterwards except the
-- registry's own marks and releases, which "Hetoimasia.Render.TwoD.Vulkan.Textures"
-- documents. It lives for the session.
module Hetoimasia.Sample.Image2d
  ( -- * What a host lends
    Builders (..)
  , Host (..)
    -- * The session's textures
  , Prepared (..)
  , prepare
  , configuration
  , handlesOf
  , uploadOf
  , awaitPlaceholder
  ) where

import Control.Concurrent (threadDelay)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( BatchTicket
  , Image
  , ImageDescription
  , Readback
  , Recorder
  , Refusal (..)
  , validateRingSize
  , validateStorageWindow
  )
import Hetoimasia.GPU.Vulkan.Native.TextureTable (TableView (..), validateTableConfig)
import Hetoimasia.GPU.Vulkan.Native.Uploads (UploadRequest (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Textures (MarkPolicy (DefaultMark), Textures, newTextures, registerTexture)
import Hetoimasia.Sample.Image2d.Assets (ImageName (..), allImages, decodeImage, describeImage)
import Hetoimasia.Sample.Image2d.Scene (Handles (..))
import Numeric.Natural (Natural)

-- | The constructions the sample needs from its host: the recorder's and the
-- registry's, and the images, readbacks and table views the evidence uses.
data Builders q inst msgr phys dev cmd = Builders
  { renderBuilders ∷ Render.Builders q inst msgr phys dev cmd
  , buildImage ∷ ImageDescription → IO (Either Refusal Image)
  , buildReadback ∷ Natural → IO (Either Refusal Readback)
  , inspectTable ∷ IO (Maybe TableView)
    -- ^ The texture table as it stands now.
  }

-- | What the sample needs of a session.
data Host = Host
  { hostAct ∷ ∀ a. Text → (∀ q inst msgr phys dev cmd. Builders q inst msgr phys dev cmd → IO (Either Refusal a)) → IO (Either Text a)
    -- ^ Run an owner-thread action over the session's constructions, naming
    -- it for a failure's report.
  , hostRecord ∷ Text → (∀ q inst msgr phys dev cmd. Builders q inst msgr phys dev cmd → IO (Either Refusal (Recorder q inst msgr phys dev cmd → IO (Either Refusal ())))) → IO (Either Text BatchTicket)
    -- ^ Run an owner-thread action that prepares a frame-less batch's
    -- recording through the constructions, then records that batch, which is
    -- submitted when the action returns; answer its ticket.
  , hostUpload ∷ UploadRequest → IO (Either Text ())
    -- ^ Admit an upload off the owner's thread and wait, with a deadline, for
    -- it to complete.
  , hostAwait ∷ BatchTicket → IO (Either Text ())
    -- ^ Wait, with a deadline, for a batch to complete.
  , hostRead ∷ Readback → Natural → IO (Either Text ByteString)
    -- ^ The first bytes of a readback, once its batch has completed.
  }

-- | The renderer's ring and table: a mebibyte of ring, and a table of 16
-- slots, 8 at first, with four versions.
configuration ∷ Render.Configuration
configuration =
  Render.Configuration
    { Render.configurationRing = either (error . show) id (validateRingSize (1024 * 1024))
    , Render.configurationRegionWindow = either (error . show) id (validateStorageWindow (16 * 1024))
    , Render.configurationTable = either (error . show) id (validateTableConfig 16 8 4)
    }

-- | What 'prepare' made.
data Prepared = Prepared
  { preparedRenderer ∷ !Render.Renderer
  , preparedTextures ∷ !Textures
  , preparedDecoded ∷ !(Map ImageName DecodedImage)
  , preparedImages ∷ !(Map ImageName Image)
    -- ^ Each image's uploaded texture, the unregistered replacement's too.
  , preparedHandles ∷ !(Map ImageName Api.TextureHandle)
    -- ^ The registered images' handles: the quadrants and the stripes.
  }

-- | The scene's handles.
handlesOf ∷ Prepared → Handles
handlesOf prepared = Handles (preparedHandles prepared Map.! Quadrants) (preparedHandles prepared Map.! Stripes)

-- | The upload of a decoded image into its texture: every level it carries.
uploadOf ∷ Image → DecodedImage → UploadRequest
uploadOf image decoded = UploadImage image (decodedLevels decoded)

-- | Decode the committed images, make the renderer and a texture for each,
-- upload them and wait for the table's placeholder, then register the
-- quadrants and the stripes with their default marks. The fade image, the
-- replacement a swap is shown with, is uploaded and not registered.
prepare ∷ Host → IO (Either Text Prepared)
prepare host@Host {hostAct = actOn, hostUpload = upload} = case traverse (\name → (,) name <$> decodeImage name) allImages of
  Left reason → pure (Left ("an image was not decoded: " <> reason))
  Right decodedList → do
    let decoded = Map.fromList decodedList
    made ← actOn "making the renderer and the textures" $ \builders → do
      renderer ← Render.makeRenderer (renderBuilders builders) configuration
      images ← traverse (\(name, image) → fmap ((,) name) <$> buildImage builders (describeImage image)) decodedList
      pure ((,) <$> renderer <*> sequence images)
    case made of
      Left failure → pure (Left failure)
      Right (renderer, images) → do
        uploads ← traverse (\(name, image) → upload (uploadOf image (decoded Map.! name))) images
        case sequence uploads of
          Left failure → pure (Left ("an upload did not complete: " <> failure))
          Right _ →
            awaitPlaceholder host (200 ∷ Int) >>= \case
              Left failure → pure (Left failure)
              Right () → do
                textures ← newTextures
                let imageMap = Map.fromList images
                registered ← actOn "registering the textures" $ \builders →
                  fmap sequence . traverse (\name → registering builders textures name (imageMap Map.! name) (decoded Map.! name)) $ [Quadrants, Stripes]
                pure $ case registered of
                  Left failure → Left failure
                  Right handles → Right (Prepared renderer textures decoded imageMap (Map.fromList handles))
  where
    registering builders textures name image decoded =
      registerTexture (renderBuilders builders) textures image decoded DefaultMark >>= \case
        Left refusal → pure (Left (RefusedIllegal (Text.pack (show refusal))))
        Right handle → pure (Right (name, handle))

-- | The table binds once its placeholder's upload has completed and its
-- descriptor is written, which the owner's steps do.
awaitPlaceholder ∷ Host → Int → IO (Either Text ())
awaitPlaceholder host'@Host {hostAct = actOn} remaining =
  actOn "reading the texture table" (\builders → Right <$> inspectTable builders) >>= \case
    Left failure → pure (Left failure)
    Right (Just table) | tableViewPlaceholderWritten table → pure (Right ())
    Right _
      | remaining <= 0 → pure (Left "the texture table's placeholder was not written within ten seconds")
      | otherwise → threadDelay 50000 >> awaitPlaceholder host' (remaining - 1)
