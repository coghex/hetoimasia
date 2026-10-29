-- | The production 'Port': the texture backend's view of a running
-- 'Hetoimasia.GPU.Vulkan.GLFW.VulkanHost', borrowed and never owned.
--
-- = What it borrows, and how
--
-- The host's graphics owner is the only thread that creates, registers or releases a native object,
-- and this module hands it nothing but bounded actions:
--
-- * 'bootstrapHost' makes, in one owner action, the session's one renderer ('Render.makeRenderer': the
--   shared ring, the texture table, the storage table, the table layout) and the one texture registry
--   ("Hetoimasia.Render.TwoD.Vulkan.Textures"), and returns them. The table is the session's only one;
--   a second would be refused, so the renderer and the registry made here are the ones every later scene
--   adapter (LFE-20) must use. The table is read by an owner action ('deviceTable'), never from outside.
-- * 'hostPort' is the 'Port' over that host: an upload is admitted by the host's own bounded, copying
--   admission ('submitVulkanUpload'); an allocation, a registration and a discarded image run in the host's
--   owner-action lane; the release of a /delivered/ texture runs in the release lane, which the owner runs
--   only once every window has adopted the scene revision that was current when it was asked
--   ('requestVulkanRelease'). That lane is the single hook through which the holds a published scene takes
--   gate the table release: the logical release is marked at once ('markReleasedSTM', for publication's
--   check), the lane's barrier makes every scene published before the request adopted, and the release
--   action then reads the scene ledger ('deviceHeld', on the owner's thread, where the lifecycle hooks
--   that write it run) and releases the table's handle ('releaseTextureNow') only when no adopted
--   revision holds it. A held release is retained by the backend and asked again when the last hold ends
--   ('portHeld'). Releasing the table's handle directly beneath a hold is not possible through this
--   module.
--
-- The host must have been built with the configuration of "Hetoimasia.LuaEngine.Graphics.Texture.Configuration"
-- (uploads configured, the device started without a surface). One that was not fails here, at startup,
-- as a refusal naming what is missing, never later as a content failure.
module Hetoimasia.LuaEngine.Graphics.Texture.Host
  ( HostSession (..)
  , BootstrapRefused (..)
  , bootstrapHost
  , hostPort
  , hostBuilders
  , renderBuilders
  ) where

import Control.Concurrent.STM (STM, atomically, retry)
import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Control.Monad (when)
import Data.Functor ((<&>))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (TexelRgba8Srgb))
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , ActionRefusal (..)
  , ActionTicket
  , BufferDescription (..)
  , BufferKind (..)
  , CancelRefusal (..)
  , Construction
  , ImageDescription (..)
  , ImageFormat (Rgba8Srgb)
  , ImageKind (TextureImage)
  , LookupEntry (..)
  , Readiness (..)
  , Refusal (..)
  , TableLayoutOptions (..)
  , TableUse (TableShaderSampler)
  , TableView (..)
  , TerminalReport (..)
  , TextureHandle (..)
  , UploadRefusal (..)
  , UploadRequest (..)
  , UploadState (..)
  , UploadTicket
  , VulkanAction (..)
  , VulkanHost (..)
  , VulkanUploadRefusal (..)
  , cancelVulkanUpload
  , constructBlendedCheckedPipeline
  , constructBuffer
  , constructDepthCheckedPipeline
  , constructDepthFormat
  , constructImage
  , constructImageFormat
  , constructRingWith
  , constructStorageTable
  , constructTablePipelineLayoutWith
  , constructTextureTable
  , readConstructedTable
  , readReadiness
  , readUploadTicket
  , readVulkanAction
  , readVulkanModel
  , readVulkanTerminal
  , registerConstructedTexture
  , releaseConstructed
  , releaseConstructedTexture
  , requestVulkanRelease
  , submitVulkanAction
  , submitVulkanUpload
  , swapConstructedTexture
  , awaitVulkanAction
  )
import Hetoimasia.GPU.Vulkan.GLFW (Image)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (SceneLedger, ledgerHeld)
import Hetoimasia.LuaEngine.Graphics.Texture.Port
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders (..))
import Hetoimasia.Render.TwoD.Vulkan.Textures
  ( MarkPolicy (DefaultMark)
  , TextureRefusal (..)
  , Textures
  , fromBackendHandle
  , markReleasedSTM
  , newTextures
  , registerTexture
  , releaseTextureNow
  , toBackendHandle
  )

-- | What the bootstrap made: the session's renderer and texture registry, and the ledger of what the
-- adopted scene revisions hold, which the release of a delivered texture is gated on.
data HostSession = HostSession
  { sessionRenderer ∷ !Render.Renderer
  , sessionTextures ∷ !Textures
  , sessionLedger ∷ !SceneLedger
  }

-- | Why the session could not be made. A structured startup failure, not a per-request one.
data BootstrapRefused
  = -- | The owner's startup failed, with its reason.
    OwnerStartupFailed !Text
  | -- | The bootstrap action was not admitted or never ran.
    BootstrapNotRun !Text
  | -- | The native layer refused the renderer: no uploads configured, a table the device cannot take, a ring it cannot make.
    RendererRefused !Text
  | -- | The bootstrap action raised.
    BootstrapRaised !Text
  deriving (Eq, Show)

-- | The renderer's constructions over a session's, with buffer uploads admitted through the host's own
-- bounded admission.
hostBuilders ∷ VulkanHost scene → Construction q inst msgr phys dev cmd → Builders q inst msgr phys dev cmd
hostBuilders host construction = (renderBuilders construction) {uploadBuffer = hostUpload}
  where
    hostUpload buffer bytes =
      submitVulkanUpload host (UploadBuffer buffer bytes) <&> \case
        Right ticket → Right ticket
        Left (VulkanUploadRefused refusal) → Left refusal
        Left (VulkanUploadsUnavailable _) → Left UploadClosed

-- | The same constructions for a frame's recording, which admits no buffer upload: the M1 scene retains no
-- chunk, so nothing records into a chunk's buffer. A frame hook is given a 'Construction' and no host.
renderBuilders ∷ Construction q inst msgr phys dev cmd → Builders q inst msgr phys dev cmd
renderBuilders construction =
  Builders
    { buildRing = constructRingWith construction
    , buildStorageTable = constructStorageTable construction
    , buildTable = constructTextureTable construction
    , buildTableLayout = \shaders → constructTablePipelineLayoutWith construction shaders (TableLayoutOptions TableShaderSampler True)
    , buildPipeline = constructBlendedCheckedPipeline construction
    , buildDepthPipeline = constructDepthCheckedPipeline construction
    , buildDepthFormat = constructDepthFormat construction
    , buildImageFormat = constructImageFormat construction
    , registerImage = registerConstructedTexture construction
    , swapImage = swapConstructedTexture construction
    , releaseImage = releaseConstructedTexture construction
    , buildVertexBuffer = \bytes → constructBuffer construction (BufferDescription VertexBuffer bytes)
    , uploadBuffer = \_ _ → pure (Left UploadClosed)
    , releaseBuffer = releaseConstructed construction
    }

-- | Make the session's renderer and registry on the owner's thread, once its startup has made the device.
-- Waits (interruptibly, in STM) for the startup and for the one action to run: this is assembly, before any
-- texture work is admitted.
bootstrapHost ∷ Render.Configuration → SceneLedger → VulkanHost scene → IO (Either BootstrapRefused HostSession)
bootstrapHost configuration ledger host = do
  readiness ← atomically $
    readReadiness (vulkanController host) >>= \case
      RootsPending → retry
      other → pure other
  case readiness of
    RootsFailed why → pure (Left (OwnerStartupFailed why))
    _ → do
      submitted ← atomically (submitVulkanAction host action)
      case submitted of
        Left refusal → pure (Left (BootstrapNotRun (Text.pack (show refusal))))
        Right ticket →
          atomically (awaitVulkanAction ticket) <&> \case
            ActionReturned (Right session) → Right session
            ActionReturned (Left refusal) → Left (RendererRefused (Text.pack (show refusal)))
            ActionRaised (ExceptionWithContext _ raised) → Left (BootstrapRaised (Text.pack (show raised)))
            ActionRefused refusal → Left (BootstrapNotRun (Text.pack (show refusal)))
  where
    action =
      VulkanAction $ \construction →
        Render.makeRenderer (hostBuilders host construction) configuration >>= \case
          Left refusal → pure (Left refusal)
          Right renderer → do
            textures ← newTextures
            pure (Right (HostSession renderer textures ledger))

-- | The port over a host that was bootstrapped.
hostPort ∷ ∀ scene. VulkanHost scene → HostSession → Port Image UploadTicket
hostPort host session =
  Port
    { portStanding = standing
    , portAct = \body → fmap admitted (submitVulkanAction host (VulkanAction (\construction → body (deviceOf host session construction))))
    , portRelease = \body → fmap admitted (requestVulkanRelease host (VulkanAction (\construction → body (deviceOf host session construction))))
    , portUpload = \image bytes →
        submitVulkanUpload host (UploadImage image [bytes]) <&> \case
          Right ticket → Right ticket
          Left (VulkanUploadsUnavailable why) → Left (AdmissionFault ("the session takes no upload: " <> Text.pack (show why)))
          Left (VulkanUploadRefused refusal) → Left (admissionRefusal refusal)
    , portTicket = \ticket →
        readUploadTicket ticket <&> \case
          UploadQueued → TicketQueued
          UploadUploading → TicketUploading
          UploadComplete → TicketComplete
          UploadCancelled → TicketCancelled
          UploadLost → TicketLost
    , portCancel = \ticket →
        cancelVulkanUpload host ticket <&> \case
          Right () → CancelledNow
          Left CancelStarted → CancelTooLate
          Left (CancelSettled _) → CancelAlreadySettled
          Left CancelUnknown → CancelAlreadySettled
    , portWatch = do
        model ← readVulkanModel (vulkanController host)
        pure (readVulkanModel (vulkanController host) >>= \now → when (now == model) retry)
    , portMarkReleased = \ref → () <$ markReleasedSTM (sessionTextures session) (fromBackendHandle (TextureHandle (refIndex ref) (refGeneration ref)))
    , portHeld = ledgerHeld (sessionLedger session) . textureIdentity
    }
  where
    controller = vulkanController host
    standing ∷ STM Standing
    standing =
      readReadiness controller >>= \case
        RootsPending → pure Starting
        RootsFailed why → pure (Ended why)
        RootsReady →
          readVulkanTerminal controller <&> \report → case reportPrimary report of
            Nothing → Running
            Just cause → Ended (Text.pack (show cause))

-- | An admitted action, as the backend reads it.
admitted ∷ Either ActionRefusal (ActionTicket a) → Either PortRefusal (Submitted a)
admitted = \case
  Left refusal → Left (refused refusal)
  Right ticket →
    Right . Submitted $
      readVulkanAction ticket <&> fmap (\case
        ActionReturned value → Returned value
        ActionRaised (ExceptionWithContext _ raised) → Raised raised
        ActionRefused refusal → NotRun (refused refusal))

refused ∷ ActionRefusal → PortRefusal
refused = \case
  ActionQueueFull → PortFull
  ReleaseQueueFull → PortFull
  ActionDeviceNotReady → PortNotStarted
  ActionSessionFailed cause → PortEnded ("the session failed: " <> Text.pack (show cause))
  ActionOwnerClosed → PortEnded "the owner's exit began"

admissionRefusal ∷ UploadRefusal → AdmissionRefusal
admissionRefusal = \case
  UploadBackpressure _ → AdmissionPressure
  UploadClosed → AdmissionEnded
  UploadSessionFailed _ → AdmissionEnded
  other → AdmissionFault (Text.pack (show other))

-- | What an owner action may do, over a construction the owner lent it.
deviceOf ∷ VulkanHost scene → HostSession → Construction q inst msgr phys dev cmd → Device Image
deviceOf host session construction =
  Device
    { deviceAllocate = \width height →
        constructImage construction (ImageDescription TextureImage Rgba8Srgb width height 1) <&> either (Left . faultOf) Right
    , deviceDiscard = \image → releaseConstructed construction image <&> either (Left . faultOf) Right
    , deviceRegister = \image level → do
        view ← readConstructedTable construction
        case view of
          Just table | tableViewPlaceholderWritten table → registerBound image level
          _ → pure (Left FaultNotReady)
    , deviceRelease = \registration →
        releaseTextureNow builders textures (fromBackendHandle (nativeHandle (registrationRef registration))) <&> either (Left . faultOf) Right
    , deviceHeld = atomically . ledgerHeld (sessionLedger session) . textureIdentity . registrationRef
    , deviceTable =
        readConstructedTable construction <&> \case
          Nothing → TableReading False Set.empty
          Just view → TableReading (tableViewPlaceholderWritten view) (Set.fromList (tableViewRetiring view))
    }
  where
    builders = hostBuilders host construction
    textures = sessionTextures session
    nativeHandle (TextureRef index generation) = TextureHandle index generation
    -- The decoded image the registry reads its cutout mark from. It reads the mark and nothing else, so it
    -- carries no level: the level is the native image's, and a reference to it here would keep the borrowed
    -- bytes alive for no reader.
    decodedFor level =
      DecodedImage
        { decodedFormat = TexelRgba8Srgb
        , decodedWidth = levelWidth level
        , decodedHeight = levelHeight level
        , decodedLevels = []
        , decodedBinaryAlpha = levelBinaryAlpha level
        }
    registerBound image level =
      registerTexture builders textures image (decodedFor level) DefaultMark >>= \case
        Left (TextureRefusedByBackend refusal) → pure (Left (faultOf refusal))
        Left other → pure (Left (FaultFatal ("the registry refused the texture: " <> Text.pack (show other))))
        Right handle → do
          let TextureHandle index generation = toBackendHandle handle
          after ← readConstructedTable construction
          case after >>= Map.lookup index . tableViewMapping of
            -- Usable: the table resolves this handle to the image's own slot, which is not the placeholder's.
            Just entry | entryGeneration entry == generation, entrySlot entry /= 0 → pure (Right (Registration (TextureRef index generation) (entrySlot entry)))
            _ → do
              -- A registration that does not resolve is not success. It is undone here, on the owner's
              -- thread, before anything has seen the handle.
              undone ← releaseTextureNow builders textures handle
              pure . Left . FaultFatal $
                "the registration did not resolve to the image's own slot"
                  <> either (\refusal → ", and releasing it failed: " <> Text.pack (show refusal)) (const "") undone

faultOf ∷ Refusal → Fault
faultOf = \case
  RefusedBackpressure _ → FaultPressure
  other → FaultFatal (Text.pack (show other))
