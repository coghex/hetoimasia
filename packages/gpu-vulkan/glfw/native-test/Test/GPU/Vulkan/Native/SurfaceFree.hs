{-# LANGUAGE OverloadedRecordDot #-}

-- | GRS-15's native cases: a graphics session whose device the owner's
-- startup creates without a surface, through the production host, on private
-- roots in a child process of its own.
--
-- The production composition — the loader integration, the validation layer
-- with synchronization validation, the diagnostic lifetime, the protected
-- window host and its graphics owner — is configured with 'DeviceSurfaceFree'.
--
-- * @grs15-surface-free@ opens no window at all. Its owner creates the
--   instance, its messenger and the device; one owner-thread action builds a
--   pipeline layout and a pipeline over the embedded verification shaders, and
--   a second releases both; the owner's own progress destroys them, with no
--   target and no frame; and the host exits through D-33.
-- * @grs15-surface-free-window@ creates the device the same way, then hands
--   over one mapped window, whose surface is admitted against the device's
--   queue family, presents one frame of it and sees that presentation retire
--   on its own present fence, and exits.
-- * @grs5-offscreen@ opens no window either (GRS-5). One owner-thread action
--   builds an RGBA8 color target of each format, sRGB and linear, a pipeline
--   for each over the endpoint shaders and a readback buffer, and records a
--   frame-less batch per target that clears it blue from undefined, draws the
--   yellow triangle, moves it to its transfer-source use, copies it into the
--   readback and returns it to rest. The main thread waits for both tickets;
--   a second action reads both readbacks, which are probed for exact bytes
--   inside and outside the triangle and written as PNGs to temporary paths.
-- * @grs4-drawing@ opens no window either (GRS-4). One owner-thread action
--   makes the session's shared ring, an RGBA8 color target, a layout
--   declaring a fragment push-constant range, a pipeline over the quad
--   shaders reading a per-vertex position and a per-instance offset, and a
--   readback buffer, and records a frame-less batch that claims ring regions
--   for a quad's four vertices, its six 16-bit indices and two instance
--   offsets, writes them, clears the target blue from undefined, pushes
--   magenta, draws indexed and instanced, and copies the target into the
--   readback. The main thread waits for its ticket; a second action reads
--   the readback, which is probed for exact bytes inside each quad and
--   outside both, and written as a PNG to a temporary path.
-- * @r2d17-depth-rect@ opens no window either (R2D-17). One owner-thread
--   action makes the session's shared ring, an RGBA8 color target, a
--   @D32_SFLOAT@ depth target of its extent, a layout and a depth-tested
--   pipeline over the scene3d sample's shaders and a readback buffer, and
--   records a frame-less batch whose pass clears the depth to 0.0, so that a
--   less-or-equal test passes nothing, clears a rectangle touching none of the
--   target's edges to 1.0 with 'clearDepthRect' under a scissor much smaller
--   than it, and draws a quad covering the
--   whole target at depth 0.5. The main thread waits for its ticket; a second
--   action reads the readback, which shows the quad's color exactly inside
--   the rectangle and the pass's clear color exactly outside it, probed on
--   both sides of each edge, and is written as a PNG to a temporary path.
--   Depth cannot be read back, so the picture is the evidence.
-- * @grs12-frameless@ opens no window either (GRS-12). One owner-thread
--   action builds a color target and a vertex buffer and records a
--   frame-less batch that initializes the target and moves the buffer into a
--   copy's use and back; a second action, while the first batch's submission
--   may still be pending, records one that moves the target into a copy's
--   source and back and the buffer again. Each batch is submitted when its
--   action returns, with #335's boundary barriers; the main thread waits for
--   both tickets with a deadline, and the host exits.
--
-- Each asserts where the device came from — enumerated and created with no
-- surface query — the order of the roots' destruction, that every Vulkan call
-- ran on the graphics owner's thread, and a verdict read after the last
-- callback with no issue and no error. It infers nothing from any timing.
module Test.GPU.Vulkan.Native.SurfaceFree
  ( SurfaceFreeOutcome (..)
  , runSurfaceFree
  , runLaterWindow
  , runFrameless
  , runOffscreen
  , runDrawing
  , runUploads
  , runTable
  , runShaderSamplers
  , runStorageTables
  , runSprites
  , runGrowth
  , runSwap
  , runScene3d
  , runDepthRect
  , runOrderedPath
  , runCutoutDepth
  , runRetained
  , surfaceFreeSection
  , laterWindowSection
  , framelessSection
  , offscreenSection
  , drawingSection
  , uploadsSection
  , tableSection
  , shaderSamplersSection
  , storageTablesSection
  , spritesSection
  , growthSection
  , swapSection
  , scene3dSection
  , depthRectSection
  , orderedPathSection
  , cutoutDepthSection
  , retainedSection
  , surfaceFreeSpec
  , laterWindowSpec
  , framelessSpec
  , offscreenSpec
  , drawingSpec
  , uploadsSpec
  , tableSpec
  , shaderSamplersSpec
  , storageTablesSpec
  , spritesSpec
  , growthSpec
  , swapSpec
  , scene3dSpec
  , depthRectSpec
  , orderedPathSpec
  , cutoutDepthSpec
  , retainedSpec
  ) where

import Control.Concurrent (ThreadId, myThreadId, threadDelay)
import Control.Concurrent.STM (STM, TVar, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (void, when)
import Data.Functor ((<&>))
import qualified Data.ByteString as ByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (elemIndex, nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Time.Clock (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Data.Bits (shiftR)
import Data.Word (Word16, Word32, Word64, Word8)
import GHC.Float (castFloatToWord32)
import Numeric.Natural (Natural)
import System.Directory (doesFileExist, getTemporaryDirectory)
import System.IO (hClose, openBinaryTempFile)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogEntry (..)
  , LogFilter (..)
  , LogLevel (Info)
  , Logger
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), durationFromNanoseconds)
import Hetoimasia.GLFW.Session (Backend)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (WindowConfig (..), hiddenTestWindowConfig)
import Hetoimasia.GPU.Model.Budget (BudgetKind (TextureSlotBudget), BudgetRequest (..), defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict (..), defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , BatchTicket
  , Buffer
  , BufferDescription (..)
  , BufferKind (..)
  , ClearColor (..)
  , Construction
  , FrameEvent (..)
  , Image
  , ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , NativeObserver (..)
  , PassStart (..)
  , Pipeline
  , PipelineLayout
  , Readback
  , Readiness (..)
  , Rect (..)
  , Refusal (..)
  , ResourceUse (..)
  , TicketState (..)
  , TransitionSource (..)
  , VulkanAction (..)
  , VulkanDeviceStart (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , Viewport (..)
  , awaitTicket
  , awaitVulkanAction
  , beginRenderingInto
  , bindPipeline
  , constructBuffer
  , constructFramelessBatch
  , constructImage
  , constructPipeline
  , constructPipelineLayout
  , constructReadback
  , copyTargetToReadback
  , draw
  , endRendering
  , formatCode
  , handOverVulkanTarget
  , publishVulkanScene
  , readConstructedReadback
  , readReadiness
  , readVulkanRoots
  , releaseConstructed
  , runVulkanOwnerLoop
  , setScissor
  , setViewport
  , submitVulkanAction
  , transitionResource
  , vulkanHostConfig
  , withVulkanOwnerHost
  , BufferSource (..)
  , IndexType (..)
  , PushStage (..)
  , bindIndexBuffer
  , bindVertexBuffer
  , claimRegion
  , constructPipelineLayoutFor
  , constructCheckedPipeline
  , constructRing
  , constructRingWith
  , drawIndexed
  , pushConstants
  , validateRingSize
  , writeClaim
  , TableLayoutOptions (..)
  , TableUse (..)
  , bindStorageTable
  , claimTable
  , constructStorageTable
  , constructTablePipelineLayoutWith
  , validateStorageWindow
  , UploadConfig
  , UploadRequest (..)
  , UploadState (..)
  , awaitUploadTicket
  , copyLevelToReadback
  , submitVulkanUpload
  , validateUploadConfig
  , LookupEntry (..)
  , TableSampler (..)
  , TableView (..)
  , TextureHandle (..)
  , bindTable
  , constructTablePipelineLayout
  , constructShaderSampledTablePipelineLayout
  , constructTextureTable
  , defaultVersionCount
  , readConstructedTable
  , registerConstructedTexture
  , releaseConstructedTexture
  , swapConstructedTexture
  , SwapState (..)
  , selectSampler
  , tableSamplerIndex
  , validateTableConfig
  , constructBlendedCheckedPipeline
  , constructDepthCheckedPipeline
  , constructDepthFormat
  , depthFormatPreference
  , DepthPass (..)
  , PipelineBlend (BlendNone)
  , beginRenderingWithDepth
  , clearDepthRect
  , depthTested
  , UploadRefusal (..)
  , VulkanUploadRefusal (..)
  , requestVulkanRelease
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (formatB8G8R8A8Srgb)
import Hetoimasia.GPU.Vulkan.Native.Recording.ShaderInterfaces (tableSamplerOffset)
import Hetoimasia.Sample.Sprites (Builders (..))
import qualified Hetoimasia.Sample.Scene3d as Scene3d
import qualified Hetoimasia.Sample.Scene3d.Evidence as Scene3dEvidence
import qualified Hetoimasia.Sample.Scene3d.Oracle as Scene3dOracle
import qualified Hetoimasia.Sample.Scene3d.Scene as Scene3dScene
import Hetoimasia.Sample.Scene3d.Shaders (scene3dShaders)
import Hetoimasia.Sample.Sprites.Evidence (Evidence (..), Host (..), runEvidence)
import Hetoimasia.Sample.Sprites.Oracle (ProbeResult (..))
import Hetoimasia.Sample.Sprites.Swap (SwapEvidence (..), SwapFacts (..), runSwapEvidence)
import qualified Hetoimasia.Sample.Sprites.Scene as Sprites
import Hetoimasia.Sample.Sprites.Scene (Probe (..))
import Hetoimasia.GPU.Vulkan.Native.Recording.Shaders (endpointShaders, quadShaders, storageTableShaders, tableInstanceShaders, tableShaders, verificationShaders)
import Hetoimasia.GPU.Vulkan.Native.Roots (RootStanding (..), RootsView (..))
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , TargetStanding (..)
  , UpdateSchedule (..)
  , defaultHostConfig
  , defaultScheduledHooks
  , graphicsAttachment
  , hostWindowIdentities
  , readTargetStanding
  , runGraphicsOwnerApplication
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import qualified Test.GPU.Vulkan.Native.CutoutDepth as CutoutDepth
import qualified Test.GPU.Vulkan.Native.OrderedPath as OrderedPath
import qualified Test.GPU.Vulkan.Native.RetainedPath as RetainedPath
import Test.GPU.Vulkan.Native.Platform (requestingBackend)
import Test.GPU.Vulkan.Native.Png (encodeRgba)
import Test.Vulkan.Proof.Journal (Journal, heading, note)
import Test.Vulkan.Proof.Roots (NativeCall (..), nativeCallObserver)

-- | What one case saw.
data SurfaceFreeFacts = SurfaceFreeFacts
  { factsCalls ∷ ![NativeCall]
    -- ^ Every observed native call, oldest first.
  , factsRunning ∷ ![Text]
    -- ^ The names of the calls made by the time the body finished, before
    -- the host's exit began.
  , factsMainThread ∷ !ThreadId
  , factsActionThreads ∷ ![ThreadId]
    -- ^ The thread each owner-thread action ran on.
  , factsActions ∷ ![Text]
    -- ^ What each owner-thread action answered.
  , factsWindows ∷ !Int
  , factsRoots ∷ !(Maybe RootsView)
    -- ^ The roots as the body last saw them.
  , factsStanding ∷ !(Maybe TargetStanding)
  , factsEvents ∷ ![FrameEvent]
  , factsTickets ∷ ![Either Refusal TicketState]
  , factsShots ∷ ![Shot]
    -- ^ The offscreen readbacks, one a format.
    -- ^ What waiting for each frame-less batch's ticket answered.
  , factsVerdict ∷ !(Maybe DiagnosticVerdict)
  , factsErrors ∷ ![Text]
  , factsSeconds ∷ !Double
  , factsUploads ∷ !(Maybe UploadFacts)
  , factsTable ∷ !(Maybe TableFacts)
  , factsSprites ∷ !(Maybe Evidence)
  , factsGrowth ∷ !(Maybe GrowthFacts)
  , factsSwap ∷ !(Maybe SwapEvidence)
  , factsScene3d ∷ !(Maybe Scene3dEvidence.Evidence)
  , factsOrdered ∷ !(Maybe OrderedPath.Evidence)
  }

data SurfaceFreeOutcome
  = SurfaceFreeFailed !Text
  | SurfaceFreeRecorded !SurfaceFreeFacts

-- | What a body records beside the calls.
data Seen = Seen
  { seenThreads ∷ ![ThreadId]
  , seenActions ∷ ![Text]
  , seenWindows ∷ !Int
  , seenRoots ∷ !(Maybe RootsView)
  , seenStanding ∷ !(Maybe TargetStanding)
  , seenTickets ∷ ![Either Refusal TicketState]
  , seenShots ∷ ![Shot]
  , seenUploads ∷ !(Maybe UploadFacts)
  , seenTable ∷ !(Maybe TableFacts)
  , seenSprites ∷ !(Maybe Evidence)
  , seenGrowth ∷ !(Maybe GrowthFacts)
  , seenSwap ∷ !(Maybe SwapEvidence)
  , seenScene3d ∷ !(Maybe Scene3dEvidence.Evidence)
  , seenOrdered ∷ !(Maybe OrderedPath.Evidence)
  }

-- | What the uploads case (GRS-6) found: each upload's ticket, waited for
-- with a deadline off the owner's thread, or why it was refused; whether each
-- RGBA8 level read back exactly as uploaded; and whether each BC7 level did,
-- or 'Nothing' where the device takes no BC7, as reported.
data UploadFacts = UploadFacts
  { uploadTickets ∷ ![Either Text UploadState]
  , uploadRgbaLevels ∷ ![Bool]
  , uploadBc7Levels ∷ !(Maybe [Bool])
  }

-- | One offscreen readback (GRS-5): its format, what waiting for its batch's
-- ticket answered, each probe's point and bytes, and where its PNG was
-- written.
data Shot = Shot
  { shotFormat ∷ !ImageFormat
  , shotTicket ∷ !(Either Refusal TicketState)
  , shotProbes ∷ ![((Int, Int), [Word8])]
  , shotPng ∷ !FilePath
  }

-- | The case with no window, on the calling thread, which must be the process
-- main thread.
runSurfaceFree ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runSurfaceFree backend journal = do
  heading journal "GRS-15: a surface-free session with no window acts on its device through the owner's thread"
  runCase backend defaultBudgetRequest [] "vulkan-native-grs15-surface-free" $ \vulkan _ names _ → do
    (threads, answers) ← actOnDevice vulkan
    -- What the second action released is destroyed by the owner's own
    -- progress, with no target, while the host still runs.
    awaitWithin 10 "the released pipeline's destruction" $ do
      made ← readTVar names
      pure (if all (`elem` made) ["vkDestroyPipeline", "vkDestroyPipelineLayout"] then Just () else Nothing)
    windows ← length <$> atomically (hostWindowIdentities (vulkanWindowHost vulkan))
    roots ← atomically (readVulkanRoots (vulkanController vulkan))
    note journal ("the actions answered " <> Text.intercalate "; " answers)
    pure (Seen threads answers windows (Just roots) Nothing [] [] Nothing Nothing Nothing Nothing Nothing Nothing Nothing)

-- | The case that admits a window after the device exists.
runLaterWindow ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runLaterWindow backend journal = do
  heading journal "GRS-15: a surface-free session admits a window after its device exists, and presents to it"
  let window = (hiddenTestWindowConfig "hetoimasia GRS-15 later window" 160 120) {windowVisible = True}
  runCase backend defaultBudgetRequest [window] "vulkan-native-grs15-surface-free-window" $ \vulkan control _ events → do
    [identity] ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
    service ←
      handOverVulkanTarget vulkan identity RequiredTarget >>= \case
        VulkanTargetHandedOver service → pure service
        other → stopWith ("the window was not handed over: " <> tshow other)
    standing ← awaitWithin 10 "the target's admission" $
      readTargetStanding (vulkanGraphicsOwner vulkan) (graphicsAttachment service) >>= \case
        Just TargetConstructing → pure Nothing
        Nothing → pure Nothing
        Just other → pure (Just other)
    when (standing /= TargetUsable) (stopWith ("the target was not admitted: " <> tshow standing))
    -- A newer scene asks the target for a frame; the loop turns until that
    -- frame is presented and its presentation retires.
    void (publishVulkanScene vulkan =<< prepare ())
    deadline ← addUTCTime 15 <$> getCurrentTime
    runVulkanOwnerLoop vulkan control . defaultScheduledHooks quiet $ \_ → do
      now ← getCurrentTime
      when (now > deadline) (stopWith "the window was not presented to within 15 seconds")
      seen ← readTVarIO events
      let presented = [presentation | FramePresented _ _ presentation _ ← seen]
          retired = [presentation | PresentationRetired presentation ← seen]
      pure (if any (`elem` retired) presented then FinishWith () else ContinueWith NoUpdateDemand)
    note journal "presented a frame to the later window and saw its presentation retire"
    roots ← atomically (readVulkanRoots (vulkanController vulkan))
    pure (Seen [] [] 1 (Just roots) (Just standing) [] [] Nothing Nothing Nothing Nothing Nothing Nothing Nothing)
  where
    quiet = recordingLogger (\_ → pure ())

-- | The case that records frame-less batches with no window (GRS-12).
runFrameless ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runFrameless backend journal = do
  heading journal "GRS-12: a surface-free session records frame-less batches through owner-thread actions and waits for their tickets"
  -- Each memory usage opens a VMA block of its own, as VK-11's case explains,
  -- so the byte budget is VK-11's 2 GiB rather than the default 256 MiB.
  runCase backend defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024} [] "vulkan-native-grs12-frameless" $ \vulkan _ _ _ → do
    first ← act vulkan (VulkanAction framelessInitializing) >>= \case
      ActionReturned (ran, Right made) → pure (ran, made)
      ActionReturned (_, Left refusal) → stopWith ("the first frame-less batch was refused: " <> tshow refusal)
      other → stopWith ("the first action did not return: " <> outcomeText other)
    let (firstOn, (target, buffer, firstTicket)) = first
    -- Submitted when the first action returned; the second is recorded
    -- without waiting for it to complete.
    second ← act vulkan (VulkanAction (framelessCopying target buffer)) >>= \case
      ActionReturned (ran, Right ticket) → pure (ran, ticket)
      ActionReturned (_, Left refusal) → stopWith ("the second frame-less batch was refused: " <> tshow refusal)
      other → stopWith ("the second action did not return: " <> outcomeText other)
    tickets ← mapM (\ticket → awaitTicket ticket deadline) [firstTicket, snd second]
    note journal ("the tickets answered " <> tshow tickets)
    roots ← atomically (readVulkanRoots (vulkanController vulkan))
    pure (Seen [firstOn, fst second] ["recorded an initializing frame-less batch", "recorded a second frame-less batch"] 0 (Just roots) Nothing tickets [] Nothing Nothing Nothing Nothing Nothing Nothing Nothing)
  where
    deadline = either (error . show) id (durationFromNanoseconds AllowZero 10000000000)

-- | The case that renders into offscreen color targets and reads them back
-- (GRS-5).
runOffscreen ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runOffscreen backend journal = do
  heading journal "GRS-5: a surface-free session renders into managed color targets and reads them back"
  runCase backend defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024} [] "vulkan-native-grs5-offscreen" $ \vulkan _ _ _ → do
    recorded ← act vulkan (VulkanAction (\construction → (,) <$> myThreadId <*> mapM (offscreenBatch construction) offscreenFormats)) >>= \case
      ActionReturned (ran, made) → pure (ran, made)
      other → stopWith ("the rendering action did not return: " <> outcomeText other)
    let (renderedOn, made) = recorded
    batches ← mapM (either (\refusal → stopWith ("an offscreen batch was refused: " <> tshow refusal)) pure) made
    tickets ← mapM (\(_, _, ticket) → awaitTicket ticket deadline) batches
    read' ← act vulkan (VulkanAction (\construction → (,) <$> myThreadId <*> mapM (\(_, readback, _) → readConstructedReadback construction readback 0 offscreenBytes) batches)) >>= \case
      ActionReturned (ran, bytes) → pure (ran, bytes)
      other → stopWith ("the reading action did not return: " <> outcomeText other)
    let (readOn, readings) = read'
    shots ← sequence
      [ case reading of
          Left refusal → stopWith ("the readback of " <> tshow format <> " was refused: " <> tshow refusal)
          Right bytes → do
            directory ← getTemporaryDirectory
            (path, handle) ← openBinaryTempFile directory ("hetoimasia-grs5-offscreen-" <> show format <> ".png")
            ByteString.hPut handle (encodeRgba offscreenSide offscreenSide bytes)
            hClose handle
            note journal ("the " <> tshow format <> " readback is at " <> Text.pack path)
            pure (Shot format ticket [(point, pixelAt bytes point) | point ← offscreenProbes] path)
      | ((format, _, _), ticket, reading) ← zip3 batches tickets readings
      ]
    roots ← atomically (readVulkanRoots (vulkanController vulkan))
    pure (Seen [renderedOn, readOn] ["rendered and copied both targets", "read both readbacks"] 0 (Just roots) Nothing tickets shots Nothing Nothing Nothing Nothing Nothing Nothing Nothing)
  where
    deadline = either (error . show) id (durationFromNanoseconds AllowZero 10000000000)
    pixelAt bytes (x, y) = ByteString.unpack (ByteString.take 4 (ByteString.drop ((y * offscreenSide + x) * 4) bytes))

-- | The case that draws an indexed, instanced quad from ring regions with a
-- pushed color (GRS-4).
runDrawing ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runDrawing backend journal = do
  heading journal "GRS-4: a surface-free session draws an indexed, instanced quad from its shared ring with a pushed color, and reads it back"
  runCase backend defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024} [] "vulkan-native-grs4-drawing" $ \vulkan _ _ _ → do
    recorded ← act vulkan (VulkanAction (\construction → (,) <$> myThreadId <*> drawingBatch construction)) >>= \case
      ActionReturned (ran, Right made) → pure (ran, made)
      ActionReturned (_, Left refusal) → stopWith ("the drawing batch was refused: " <> tshow refusal)
      other → stopWith ("the drawing action did not return: " <> outcomeText other)
    let (drawnOn, (readback, ticket)) = recorded
    waited ← awaitTicket ticket deadline
    read' ← act vulkan (VulkanAction (\construction → (,) <$> myThreadId <*> readConstructedReadback construction readback 0 offscreenBytes)) >>= \case
      ActionReturned (ran, Right bytes) → pure (ran, bytes)
      ActionReturned (_, Left refusal) → stopWith ("the readback was refused: " <> tshow refusal)
      other → stopWith ("the reading action did not return: " <> outcomeText other)
    let (readOn, bytes) = read'
    directory ← getTemporaryDirectory
    (path, handle) ← openBinaryTempFile directory "hetoimasia-grs4-drawing.png"
    ByteString.hPut handle (encodeRgba offscreenSide offscreenSide bytes)
    hClose handle
    note journal ("the readback is at " <> Text.pack path)
    let shot = Shot Rgba8Srgb waited [(point, pixelAt bytes point) | point ← drawingProbes] path
    roots ← atomically (readVulkanRoots (vulkanController vulkan))
    pure (Seen [drawnOn, readOn] ["drew the quad and copied the target", "read the readback"] 0 (Just roots) Nothing [waited] [shot] Nothing Nothing Nothing Nothing Nothing Nothing Nothing)
  where
    deadline = either (error . show) id (durationFromNanoseconds AllowZero 10000000000)
    pixelAt bytes (x, y) = ByteString.unpack (ByteString.take 4 (ByteString.drop ((y * offscreenSide + x) * 4) bytes))

-- | The uploads case (GRS-6): textures and buffers filled through the
-- session's uploads, admitted from this thread — the main thread, never the
-- owner's — and waited for with a deadline; every texture level copied back
-- and compared exactly; and the uploaded buffers drawn from.
runUploads ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runUploads backend journal = do
  heading journal "GRS-6: a surface-free session uploads textures over several turns and buffers through bounded staging, copies every level back, and draws from the buffers"
  runCaseWith
    (\config → config {vulkanUploads = Just uploadConfig})
    backend
    defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024}
    []
    "vulkan-native-grs6-uploads"
    $ \vulkan _ _ _ → do
      (madeOn, made) ←
        act vulkan (VulkanAction (\construction → (,) <$> myThreadId <*> uploadTargets construction)) >>= \case
          ActionReturned (ran, Right made) → pure (ran, made)
          ActionReturned (_, Left refusal) → stopWith ("the upload targets were refused: " <> tshow refusal)
          other → stopWith ("the upload targets' action did not return: " <> outcomeText other)
      let requests =
            [UploadImage (targetsRgba made) rgbaLevels]
              <> [UploadImage texture bc7Levels | Just texture ← [targetsBc7 made]]
              <> [ UploadBuffer (targetsVertices made) (floatBytes quadCorners)
                 , UploadBuffer (targetsOffsets made) (floatBytes instanceOffsets)
                 , UploadBuffer (targetsIndices made) (indexBytes quadIndices)
                 ]
      admitted ← mapM (submitVulkanUpload vulkan) requests
      states ←
        mapM
          ( \case
              Left refusal → pure (Left (tshow refusal))
              Right ticket → either (Left . tshow) Right <$> awaitUploadTicket ticket deadline
          )
          admitted
      (verifiedOn, ticket) ←
        act vulkan (VulkanAction (\construction → (,) <$> myThreadId <*> verifyBatch construction made)) >>= \case
          ActionReturned (ran, Right batch) → pure (ran, batch)
          ActionReturned (_, Left refusal) → stopWith ("the verifying batch was refused: " <> tshow refusal)
          other → stopWith ("the verifying action did not return: " <> outcomeText other)
      waited ← awaitTicket ticket deadline
      (readOn, (levels, target)) ←
        act vulkan (VulkanAction (\construction → (,) <$> myThreadId <*> readBack construction made)) >>= \case
          ActionReturned (ran, Right bytes) → pure (ran, bytes)
          ActionReturned (_, Left refusal) → stopWith ("the readbacks were refused: " <> tshow refusal)
          other → stopWith ("the reading action did not return: " <> outcomeText other)
      directory ← getTemporaryDirectory
      (path, handle) ← openBinaryTempFile directory "hetoimasia-grs6-uploads.png"
      ByteString.hPut handle (encodeRgba offscreenSide offscreenSide target)
      hClose handle
      note journal ("the drawing readback is at " <> Text.pack path)
      let (rgbaRead, bc7Read) = splitAt (length rgbaLevels) levels
          facts =
            UploadFacts
              states
              (zipWith (==) rgbaLevels rgbaRead)
              (fmap (const (zipWith (==) bc7Levels bc7Read)) (targetsBc7 made))
          shot = Shot Rgba8Srgb waited [(point, pixelAt target point) | point ← drawingProbes] path
      note journal ("BC7 " <> maybe "is not supported by the device, as it reports" (const "is supported, and was uploaded") (targetsBc7 made))
      roots ← atomically (readVulkanRoots (vulkanController vulkan))
      pure
        ( Seen
            [madeOn, verifiedOn, readOn]
            ["made the textures, buffers and readbacks", "copied every level back and drew from the uploaded buffers", "read every readback"]
            0
            (Just roots)
            Nothing
            [waited]
            [shot]
            (Just facts)
            Nothing
            Nothing
            Nothing
            Nothing
            Nothing
            Nothing
        )
  where
    deadline = either (error . show) id (durationFromNanoseconds AllowZero 30000000000)
    pixelAt bytes (x, y) = ByteString.unpack (ByteString.take 4 (ByteString.drop ((y * offscreenSide + x) * 4) bytes))

-- | The uploads' configuration: a 1 MiB staging buffer, every upload of the
-- case at once; a 128 KiB turn budget, one block row of a 32768-texel level,
-- as wide as any device the suite runs on allows (D-30) — so the RGBA8
-- texture's 320 KiB take several turns; and a queue of eight.
uploadConfig ∷ UploadConfig
uploadConfig = either (error . show) id (validateUploadConfig (1024 * 1024) uploadBudget 8)

uploadBudget ∷ Integer
uploadBudget = 128 * 1024

-- | The turns the RGBA8 texture needs at least, each a batch of its own.
rgbaTurns ∷ Int
rgbaTurns = fromIntegral ((sum (map (toInteger . ByteString.length) rgbaLevels) + uploadBudget - 1) `div` uploadBudget)

-- | The RGBA8 texture's side, and its two levels' bytes: a pattern no level
-- repeats at any offset a misplaced row or level would land on.
uploadSide ∷ Word32
uploadSide = 256

rgbaLevels ∷ [ByteString.ByteString]
rgbaLevels = [levelPattern 1 (256 * 256 * 4), levelPattern 2 (128 * 128 * 4)]

-- | The BC7 texture's two levels: 64 by 64 and 32 by 32 blocks of sixteen
-- bytes. A copy moves blocks as they are, so any bytes compare.
bc7Levels ∷ [ByteString.ByteString]
bc7Levels = [levelPattern 3 (64 * 64 * 16), levelPattern 4 (32 * 32 * 16)]

levelPattern ∷ Int → Int → ByteString.ByteString
levelPattern seed count = fst (ByteString.unfoldrN count (\index → Just (fromIntegral ((index * 7 + seed * 13 + index `div` 251) `mod` 251), index + 1)) 0)

-- | What the case uploads into and reads back from.
data UploadTargets = UploadTargets
  { targetsRgba ∷ !Image
  , targetsBc7 ∷ !(Maybe Image)
    -- ^ 'Nothing' where the device takes no BC7: its creation was refused.
  , targetsVertices ∷ !Buffer
  , targetsOffsets ∷ !Buffer
  , targetsIndices ∷ !Buffer
  , targetsTarget ∷ !Image
  , targetsPipeline ∷ !Pipeline
  , targetsLevelReadbacks ∷ ![(Readback, Natural)]
    -- ^ One a level, RGBA8 first, then BC7's, with its size.
  , targetsReadback ∷ !Readback
  }

-- | Two textures of two levels each — RGBA8, and BC7 where the device takes
-- it — the quad's vertex, instance-offset and index buffers, an RGBA8 color
-- target, a pipeline over the quad shaders, and a readback for every level
-- and for the target.
uploadTargets ∷ Construction q inst msgr phys dev cmd → IO (Either Refusal UploadTargets)
uploadTargets construction = do
  let side = fromIntegral offscreenSide
  rgba ← constructImage construction (ImageDescription TextureImage Rgba8Linear uploadSide uploadSide 2)
  bc7 ←
    constructImage construction (ImageDescription TextureImage Bc7Linear uploadSide uploadSide 2) <&> \case
      Right texture → Right (Just texture)
      Left (RefusedImageUnsupported _ _) → Right Nothing
      Left refusal → Left refusal
  vertices ← constructBuffer construction (BufferDescription VertexBuffer (fromIntegral (ByteString.length (floatBytes quadCorners))))
  offsets ← constructBuffer construction (BufferDescription VertexBuffer (fromIntegral (ByteString.length (floatBytes instanceOffsets))))
  indices ← constructBuffer construction (BufferDescription IndexBuffer (fromIntegral (ByteString.length (indexBytes quadIndices))))
  target ← constructImage construction (ImageDescription ColorTarget Rgba8Srgb side side 1)
  -- The layout and the vertex input are the checked quad shaders' own.
  pipeline ←
    constructPipelineLayoutFor construction quadShaders >>= \case
      Left refusal → pure (Left refusal)
      Right layout → constructCheckedPipeline construction layout quadShaders (formatCode Rgba8Srgb)
  let sizes = map (fromIntegral . ByteString.length) (rgbaLevels <> either (const []) (maybe [] (const bc7Levels)) bc7)
  levelReadbacks ← mapM (\size → fmap (\readback → (readback, size)) <$> constructReadback construction size) sizes
  readback ← constructReadback construction offscreenBytes
  pure $
    UploadTargets
      <$> rgba
      <*> bc7
      <*> vertices
      <*> offsets
      <*> indices
      <*> target
      <*> pipeline
      <*> sequence levelReadbacks
      <*> readback

-- | One frame-less batch that copies every level of every uploaded texture
-- back, each after its checked transition and returned to rest, then draws
-- the quad indexed and instanced from the uploaded buffers into the color
-- target, cleared blue, with magenta pushed, and copies the target back.
verifyBatch ∷ Construction q inst msgr phys dev cmd → UploadTargets → IO (Either Refusal BatchTicket)
verifyBatch construction made =
  constructFramelessBatch construction steps <&> \case
    Left refusal → Left refusal
    Right (_, Left refusal) → Left refusal
    Right (ticket, Right ()) → Right ticket
  where
    side = fromIntegral offscreenSide
    textures = (targetsRgba made, 2) : [(texture, 2) | Just texture ← [targetsBc7 made]]
    levelCopies recorder =
      concat
        [ [transitionResource recorder texture (FromUse ShaderSampled) TransferRead]
            <> [copyLevelToReadback recorder texture level readback | (level, (readback, _)) ← zip [0 ..] levelReadbacks]
            <> [transitionResource recorder texture (FromUse TransferRead) ShaderSampled]
        | ((texture, _ ∷ Int), levelReadbacks) ← zip textures (chunked (targetsLevelReadbacks made))
        ]
    chunked [] = []
    chunked held = take 2 held : chunked (drop 2 held)
    magenta = floatBytes [(1, 0), (1, 1)]
    steps recorder =
      inOrder $
        levelCopies recorder
          <> [ transitionResource recorder (targetsVertices made) (FromUse GeometryRead) GeometryRead
             , transitionResource recorder (targetsOffsets made) (FromUse GeometryRead) GeometryRead
             , transitionResource recorder (targetsIndices made) (FromUse GeometryRead) GeometryRead
             , beginRenderingInto recorder (targetsTarget made) ClearFromUndefined (ClearColor 0 0 1 1)
             , bindPipeline recorder (targetsPipeline made)
             , setViewport recorder (Viewport 0 0 (fromIntegral side) (fromIntegral side))
             , setScissor recorder (Rect 0 0 side side)
             , bindVertexBuffer recorder 0 (FromBuffer (targetsVertices made) 0)
             , bindVertexBuffer recorder 1 (FromBuffer (targetsOffsets made) 0)
             , bindIndexBuffer recorder (FromBuffer (targetsIndices made) 0) Index16
             , pushConstants recorder [PushFragment] 0 magenta
             , drawIndexed recorder (fromIntegral (length quadIndices)) (fromIntegral (length instanceOffsets))
             , endRendering recorder
             , transitionResource recorder (targetsTarget made) (FromUse ColorAttachment) TransferRead
             , copyTargetToReadback recorder (targetsTarget made) (targetsReadback made)
             , transitionResource recorder (targetsTarget made) (FromUse TransferRead) ColorAttachment
             ]

-- | Every level readback's bytes, in order, and the color target's.
readBack ∷ Construction q inst msgr phys dev cmd → UploadTargets → IO (Either Refusal ([ByteString.ByteString], ByteString.ByteString))
readBack construction made = do
  levels ← mapM (\(readback, size) → readConstructedReadback construction readback 0 size) (targetsLevelReadbacks made)
  target ← readConstructedReadback construction (targetsReadback made) 0 offscreenBytes
  pure ((,) <$> sequence levels <*> target)

-- | Probe points well away from every edge: the first two at the centers of
-- the two instances' quads, the rest outside both.
drawingProbes ∷ [(Int, Int)]
drawingProbes = [(16, 32), (48, 32), (32, 32), (4, 4), (60, 60)]

-- | What each probe must read: the pushed magenta inside each quad, the blue
-- clear outside them, every channel an endpoint.
expectedDrawingProbes ∷ [[Word8]]
expectedDrawingProbes = [[255, 0, 255, 255], [255, 0, 255, 255], [0, 0, 255, 255], [0, 0, 255, 255], [0, 0, 255, 255]]

-- | The quad's corners, a quarter of the target's side across, centered on
-- the origin; its two triangles' indices; and each instance's offset, a
-- quarter of the target to either side.
quadCorners, instanceOffsets ∷ [(Float, Float)]
quadCorners = [(-0.25, -0.25), (0.25, -0.25), (0.25, 0.25), (-0.25, 0.25)]
instanceOffsets = [(-0.5, 0), (0.5, 0)]

quadIndices ∷ [Word16]
quadIndices = [0, 1, 2, 2, 3, 0]

-- | Little-endian bytes of floats and of 16-bit indices, as the device reads
-- them.
floatBytes ∷ [(Float, Float)] → ByteString.ByteString
floatBytes pairs = ByteString.pack (concat [word (castFloatToWord32 value) | (x, y) ← pairs, value ← [x, y]])
  where
    word ∷ Word32 → [Word8]
    word value = [fromIntegral (value `shiftR` shift) | shift ← [0, 8, 16, 24]]

indexBytes ∷ [Word16] → ByteString.ByteString
indexBytes indices = ByteString.pack (concat [[fromIntegral index, fromIntegral (index `shiftR` 8)] | index ← indices])

-- | The session's ring, a color target, a layout declaring the fragment
-- stage's color, a pipeline over the quad shaders, a readback buffer, and a
-- frame-less batch that writes the quad into ring regions, clears the target
-- blue from undefined, pushes magenta, draws indexed and instanced, copies the
-- target into the readback after its transition, and returns it to rest.
drawingBatch ∷ Construction q inst msgr phys dev cmd → IO (Either Refusal (Readback, BatchTicket))
drawingBatch construction = do
  let side = fromIntegral offscreenSide
      ringSize = either (error . show) id (validateRingSize 4096)
      magenta = floatBytes [(1, 0), (1, 1)]
      claimedWith recorder contents = do
        claimed ← claimRegion recorder (fromIntegral (ByteString.length contents)) 4
        case claimed of
          Left refusal → pure (Left refusal)
          Right claim → fmap (const claim) <$> writeClaim recorder claim 0 contents
      steps target pipeline readback recorder = do
        regions ←
          sequence
            [ claimedWith recorder (floatBytes quadCorners)
            , claimedWith recorder (indexBytes quadIndices)
            , claimedWith recorder (floatBytes instanceOffsets)
            ]
        case sequence regions of
          Left refusal → pure (Left refusal)
          Right [vertices, indices, instances] →
            inOrder
              [ beginRenderingInto recorder target ClearFromUndefined (ClearColor 0 0 1 1)
              , bindPipeline recorder pipeline
              , setViewport recorder (Viewport 0 0 (fromIntegral side) (fromIntegral side))
              , setScissor recorder (Rect 0 0 side side)
              , bindVertexBuffer recorder 0 (FromClaim vertices 0)
              , bindVertexBuffer recorder 1 (FromClaim instances 0)
              , bindIndexBuffer recorder (FromClaim indices 0) Index16
              , pushConstants recorder [PushFragment] 0 magenta
              , drawIndexed recorder (fromIntegral (length quadIndices)) (fromIntegral (length instanceOffsets))
              , endRendering recorder
              , transitionResource recorder target (FromUse ColorAttachment) TransferRead
              , copyTargetToReadback recorder target readback
              , transitionResource recorder target (FromUse TransferRead) ColorAttachment
              ]
          Right _ → pure (Left (RefusedIllegal "the case claimed other than three regions"))
  constructRing construction ringSize >>= \case
    Left refusal → pure (Left refusal)
    Right () →
      constructImage construction (ImageDescription ColorTarget Rgba8Srgb side side 1) >>= \case
        Left refusal → pure (Left refusal)
        Right target →
          constructPipelineLayoutFor construction quadShaders >>= \case
            Left refusal → pure (Left refusal)
            Right layout →
              constructCheckedPipeline construction layout quadShaders (formatCode Rgba8Srgb) >>= \case
                Left refusal → pure (Left refusal)
                Right pipeline →
                  constructReadback construction offscreenBytes >>= \case
                    Left refusal → pure (Left refusal)
                    Right readback →
                      constructFramelessBatch construction (steps target pipeline readback) <&> \case
                        Left refusal → Left refusal
                        Right (_, Left refusal) → Left refusal
                        Right (ticket, Right ()) → Right (readback, ticket)

-- | The depth-rect case (R2D-17): a pass into an RGBA8 color target and a
-- @D32_SFLOAT@ depth target that clears the depth to 0.0, clears a rectangle
-- of it to 1.0, and draws a quad covering the whole target at depth 0.5 with a
-- less-or-equal test, so the quad shows exactly where depth was cleared.
runDepthRect ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runDepthRect backend journal = do
  heading journal "R2D-17: a surface-free session clears a rectangle of a depth attachment inside a pass, draws a full-target quad at depth 0.5 with a less-or-equal test, and reads it back"
  runCase backend defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024} [] "vulkan-native-r2d17-depth-rect" $ \vulkan _ _ _ → do
    recorded ← act vulkan (VulkanAction (\construction → (,) <$> myThreadId <*> depthRectBatch construction)) >>= \case
      ActionReturned (ran, Right made) → pure (ran, made)
      ActionReturned (_, Left refusal) → stopWith ("the depth-rect batch was refused: " <> tshow refusal)
      other → stopWith ("the depth-rect action did not return: " <> outcomeText other)
    let (drawnOn, (readback, ticket)) = recorded
    waited ← awaitTicket ticket deadline
    read' ← act vulkan (VulkanAction (\construction → (,) <$> myThreadId <*> readConstructedReadback construction readback 0 offscreenBytes)) >>= \case
      ActionReturned (ran, Right bytes) → pure (ran, bytes)
      ActionReturned (_, Left refusal) → stopWith ("the readback was refused: " <> tshow refusal)
      other → stopWith ("the reading action did not return: " <> outcomeText other)
    let (readOn, bytes) = read'
    directory ← getTemporaryDirectory
    (path, handle) ← openBinaryTempFile directory "hetoimasia-r2d17-depth-rect.png"
    ByteString.hPut handle (encodeRgba offscreenSide offscreenSide bytes)
    hClose handle
    note journal ("the readback is at " <> Text.pack path)
    let shot = Shot Rgba8Srgb waited [(point, pixelAt bytes point) | (point, _) ← depthRectProbes] path
    roots ← atomically (readVulkanRoots (vulkanController vulkan))
    pure (Seen [drawnOn, readOn] ["cleared the depth rectangle, drew the quad and copied the target", "read the readback"] 0 (Just roots) Nothing [waited] [shot] Nothing Nothing Nothing Nothing Nothing Nothing Nothing)
  where
    deadline = either (error . show) id (durationFromNanoseconds AllowZero 10000000000)
    pixelAt bytes (x, y) = ByteString.unpack (ByteString.take 4 (ByteString.drop ((y * offscreenSide + x) * 4) bytes))

-- | The rectangle the case clears the depth to 1.0 within, in pixels of the
-- 64 by 64 targets: 16 to 47 across and 20 to 43 down, touching no edge.
depthRectCleared ∷ Rect
depthRectCleared = Rect 16 20 32 24

-- | Probe points and what each must read: the quad's magenta where the depth
-- was cleared to 1.0, the pass's blue clear where it stayed 0.0. Each edge of
-- the rectangle has a pixel just inside it and one just outside, and so do
-- two corners; the rest are well away from it.
depthRectProbes ∷ [((Int, Int), [Word8])]
depthRectProbes =
  [ ((32, 32), inside)
  , ((16, 32), inside)
  , ((15, 32), outside)
  , ((47, 32), inside)
  , ((48, 32), outside)
  , ((32, 20), inside)
  , ((32, 19), outside)
  , ((32, 43), inside)
  , ((32, 44), outside)
  , ((16, 20), inside)
  , ((15, 19), outside)
  , ((47, 43), inside)
  , ((48, 44), outside)
  , ((4, 4), outside)
  , ((60, 60), outside)
  ]
  where
    inside = [255, 0, 255, 255]
    outside = [0, 0, 255, 255]

-- | The quad as two triangles of the scene3d sample's vertices: a position of
-- three floats and a color of four normalized bytes, covering the whole
-- clip-space square at depth 0.5, in magenta.
depthRectVertices ∷ ByteString.ByteString
depthRectVertices = ByteString.concat [vertex x y | (x, y) ← [(-1, -1), (1, -1), (1, 1), (-1, -1), (1, 1), (-1, 1)]]
  where
    vertex x y = floatList [x, y, 0.5] <> ByteString.pack [255, 0, 255, 255]

-- | The identity transform the scene3d shaders' push-constant block takes.
depthRectTransform ∷ ByteString.ByteString
depthRectTransform = floatList [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

floatList ∷ [Float] → ByteString.ByteString
floatList values = ByteString.pack (concat [word (castFloatToWord32 value) | value ← values])
  where
    word ∷ Word32 → [Word8]
    word value = [fromIntegral (value `shiftR` shift) | shift ← [0, 8, 16, 24]]

-- | The session's ring, an RGBA8 color target, a depth target of the backend's
-- depth format, which the case requires to be @D32_SFLOAT@, a layout and a
-- depth-tested pipeline over the scene3d shaders, a readback buffer, and a
-- frame-less batch that writes the quad into a ring region, begins a pass
-- clearing the color to blue and the depth to 0.0, clears the rectangle to
-- 1.0 under a scissor much smaller than it, draws the quad at depth 0.5, ends the pass, copies the target into the
-- readback after its transition, and returns it to rest.
depthRectBatch ∷ Construction q inst msgr phys dev cmd → IO (Either Refusal (Readback, BatchTicket))
depthRectBatch construction = do
  let side = fromIntegral offscreenSide
      ringSize = either (error . show) id (validateRingSize 4096)
      steps target depth pipeline readback recorder =
        claimRegion recorder (fromIntegral (ByteString.length depthRectVertices)) 4 >>= \case
          Left refusal → pure (Left refusal)
          Right claim →
            writeClaim recorder claim 0 depthRectVertices >>= \case
              Left refusal → pure (Left refusal)
              Right () →
                inOrder
                  [ beginRenderingWithDepth recorder target ClearFromUndefined (ClearColor 0 0 1 1) (DepthPass depth ClearFromUndefined 0)
                  , -- A scissor far smaller than the rectangle must not narrow the clear.
                    setScissor recorder (Rect 0 0 4 4)
                  , clearDepthRect recorder depthRectCleared 1
                  , bindPipeline recorder pipeline
                  , setViewport recorder (Viewport 0 0 (fromIntegral side) (fromIntegral side))
                  , setScissor recorder (Rect 0 0 side side)
                  , bindVertexBuffer recorder 0 (FromClaim claim 0)
                  , pushConstants recorder [PushVertex] 0 depthRectTransform
                  , draw recorder 6 1
                  , endRendering recorder
                  , transitionResource recorder target (FromUse ColorAttachment) TransferRead
                  , copyTargetToReadback recorder target readback
                  , transitionResource recorder target (FromUse TransferRead) ColorAttachment
                  ]
  constructDepthFormat construction >>= \case
    Left refusal → pure (Left refusal)
    Right format
      | format /= Depth32Float → pure (Left (RefusedUnsupported ("a depth attachment of " <> tshow format <> ", when the case needs D32_SFLOAT")))
      | otherwise →
          constructRing construction ringSize >>= \case
            Left refusal → pure (Left refusal)
            Right () →
              constructImage construction (ImageDescription ColorTarget Rgba8Srgb side side 1) >>= \case
                Left refusal → pure (Left refusal)
                Right target →
                  constructImage construction (ImageDescription DepthTarget format side side 1) >>= \case
                    Left refusal → pure (Left refusal)
                    Right depth →
                      constructPipelineLayoutFor construction scene3dShaders >>= \case
                        Left refusal → pure (Left refusal)
                        Right layout →
                          constructDepthCheckedPipeline construction layout scene3dShaders (formatCode Rgba8Srgb) BlendNone (depthTested format) >>= \case
                            Left refusal → pure (Left refusal)
                            Right pipeline →
                              constructReadback construction offscreenBytes >>= \case
                                Left refusal → pure (Left refusal)
                                Right readback →
                                  constructFramelessBatch construction (steps target depth pipeline readback) <&> \case
                                    Left refusal → Left refusal
                                    Right (_, Left refusal) → Left refusal
                                    Right (ticket, Right ()) → Right (readback, ticket)

-- | The formats the case renders into.
offscreenFormats ∷ [ImageFormat]
offscreenFormats = [Rgba8Srgb, Rgba8Linear]

-- | The targets' side, in pixels.
offscreenSide ∷ Int
offscreenSide = 64

offscreenBytes ∷ Natural
offscreenBytes = fromIntegral (offscreenSide * offscreenSide * 4)

-- | Probe points, each well away from the triangle's edges: the first inside
-- it, near its centroid, the rest outside it.
offscreenProbes ∷ [(Int, Int)]
offscreenProbes = [(32, 38), (4, 4), (60, 4), (32, 60)]

-- | What each probe must read: yellow inside the triangle, blue outside,
-- every channel an endpoint, so exact in either format.
expectedProbes ∷ [[Word8]]
expectedProbes = [[255, 255, 0, 255], [0, 0, 255, 255], [0, 0, 255, 255], [0, 0, 255, 255]]

-- | One color target of the format, a pipeline for it over the endpoint
-- shaders, a readback buffer its size, and a frame-less batch that clears the
-- target blue from undefined, draws the triangle, copies the target into the
-- readback after its transition, and returns it to rest.
offscreenBatch ∷ Construction q inst msgr phys dev cmd → ImageFormat → IO (Either Refusal (ImageFormat, Readback, BatchTicket))
offscreenBatch construction format = do
  let side = fromIntegral offscreenSide
      steps target pipeline readback recorder =
        inOrder
          [ beginRenderingInto recorder target ClearFromUndefined (ClearColor 0 0 1 1)
          , bindPipeline recorder pipeline
          , setViewport recorder (Viewport 0 0 (fromIntegral side) (fromIntegral side))
          , setScissor recorder (Rect 0 0 side side)
          , draw recorder 3 1
          , endRendering recorder
          , transitionResource recorder target (FromUse ColorAttachment) TransferRead
          , copyTargetToReadback recorder target readback
          , transitionResource recorder target (FromUse TransferRead) ColorAttachment
          ]
  constructImage construction (ImageDescription ColorTarget format side side 1) >>= \case
    Left refusal → pure (Left refusal)
    Right target →
      constructPipelineLayout construction >>= \case
        Left refusal → pure (Left refusal)
        Right layout →
          constructPipeline construction layout endpointShaders (formatCode format) >>= \case
            Left refusal → pure (Left refusal)
            Right pipeline →
              constructReadback construction offscreenBytes >>= \case
                Left refusal → pure (Left refusal)
                Right readback →
                  constructFramelessBatch construction (steps target pipeline readback) <&> \case
                    Left refusal → Left refusal
                    Right (_, Left refusal) → Left refusal
                    Right (ticket, Right ()) → Right (format, readback, ticket)

-- | A color target and a vertex buffer, and a frame-less batch that
-- initializes the target and moves the buffer into a copy's use and back,
-- answering the thread it ran on.
framelessInitializing ∷ Construction q inst msgr phys dev cmd → IO (ThreadId, Either Refusal (Image, Buffer, BatchTicket))
framelessInitializing construction = do
  ran ← myThreadId
  answer ←
    constructImage construction (ImageDescription ColorTarget Rgba8Srgb 16 16 1) >>= \case
      Left refusal → pure (Left refusal)
      Right target →
        constructBuffer construction (BufferDescription VertexBuffer 256) >>= \case
          Left refusal → pure (Left refusal)
          Right buffer →
            constructFramelessBatch
              construction
              ( \recorder →
                  inOrder
                    [ transitionResource recorder target FromUndefined ColorAttachment
                    , transitionResource recorder buffer (FromUse GeometryRead) TransferWrite
                    , transitionResource recorder buffer (FromUse TransferWrite) GeometryRead
                    ]
              )
              <&> \case
                Left refusal → Left refusal
                Right (_, Left refusal) → Left refusal
                Right (ticket, Right ()) → Right (target, buffer, ticket)
  pure (ran, answer)

-- | A frame-less batch that moves the target into a copy's source and back,
-- and the buffer into a copy's use and back, answering the thread it ran on.
framelessCopying ∷ Image → Buffer → Construction q inst msgr phys dev cmd → IO (ThreadId, Either Refusal BatchTicket)
framelessCopying target buffer construction = do
  ran ← myThreadId
  answer ←
    constructFramelessBatch
      construction
      ( \recorder →
          inOrder
            [ transitionResource recorder target (FromUse ColorAttachment) TransferRead
            , transitionResource recorder target (FromUse TransferRead) ColorAttachment
            , transitionResource recorder buffer (FromUse GeometryRead) TransferWrite
            , transitionResource recorder buffer (FromUse TransferWrite) GeometryRead
            ]
      )
      <&> \case
        Left refusal → Left refusal
        Right (_, Left refusal) → Left refusal
        Right (ticket, Right ()) → Right ticket
  pure (ran, answer)

-- | What the texture table case (GRS-7) found.
data TableFacts = TableFacts
  { tableTickets ∷ ![Either Text UploadState]
    -- ^ Each texture's upload, waited for with a deadline off the owner's
    -- thread.
  , tableReplacedSlot ∷ !(Maybe Word32)
    -- ^ The first texture's slot, which the record-then-replace batch's
    -- version maps.
  , tableReplacementSlot ∷ !(Maybe Word32)
    -- ^ The slot the texture registered after its release took.
  , tableRetiringAtRelease ∷ ![Word32]
    -- ^ The slots retiring right after the release, before that batch was
    -- submitted.
  , tableRetiringAtEnd ∷ ![Word32]
    -- ^ The slots retiring once every batch completed.
  , tableStaleRelease ∷ !(Either Refusal ())
    -- ^ What releasing the released handle again answered.
  }
  deriving (Show)

-- | The texture table case (GRS-7): a table made over the session's uploads;
-- one texture registered before its upload, drawn as slot 0's transparent
-- placeholder; two textures, each uploaded and drawn through its handle with
-- a sampler of its own; a batch recorded with the first texture's handle, the
-- handle then released and a third texture registered before the batch is
-- submitted, which still draws the first; and the third drawn beside the
-- released handle, which a shader resolves to the placeholder. Each batch
-- draws into a color target of its own, copied into a readback and probed.
runTable ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runTable backend journal = do
  heading journal "GRS-7: a surface-free session samples textures through bindless handles: the placeholder before an upload, two textures with selected samplers, and a batch recorded before its texture's release still drawing the original"
  runCaseWith
    (\config → config {vulkanUploads = Just uploadConfig})
    backend
    defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024}
    []
    "vulkan-native-grs7-texture-table"
    $ \vulkan _ _ _ → do
      (madeOn, made) ← acted vulkan "the table and its targets" tableTargets
      -- The table binds once its placeholder's upload has completed.
      awaitTable vulkan "the placeholder written" tableViewPlaceholderWritten
      (firstOn, (red, ticket1)) ←
        acted vulkan "the placeholder batch" $ \construction →
          registerConstructedTexture construction (tableRed made) >>= \case
            Left refusal → pure (Left refusal)
            Right red → fmap ((,) red) <$> tableBatch construction made 0 [(wholeRect, red, LinearClamp)]
      waited1 ← awaitTicket ticket1 deadline
      admitted ←
        mapM
          (submitVulkanUpload vulkan)
          [UploadImage (tableRed made) [solid [255, 0, 0, 255]], UploadImage (tableGreen made) [solid [0, 255, 0, 255]], UploadImage (tableBlue made) [solid [0, 0, 255, 255]]]
      states ←
        mapM
          ( \case
              Left refusal → pure (Left (tshow refusal))
              Right ticket → either (Left . tshow) Right <$> awaitUploadTicket ticket deadline
          )
          admitted
      (secondOn, (replaced, ticket2)) ←
        acted vulkan "the two-texture batch" $ \construction →
          registerConstructedTexture construction (tableGreen made) >>= \case
            Left refusal → pure (Left refusal)
            Right green → do
              batch ← tableBatch construction made 1 [(leftRect, red, NearestClamp), (rightRect, green, LinearRepeat)]
              view ← readConstructedTable construction
              pure (fmap ((,) (view >>= slotOf red)) batch)
      waited2 ← awaitTicket ticket2 deadline
      -- Recorded with the first texture's handle; the handle released and
      -- another texture registered before the action returns, which is when
      -- the batch is submitted.
      (thirdOn, (ticket3, retiring, blue, replacement, stale)) ←
        acted vulkan "the record-then-replace batch" $ \construction →
          tableBatch construction made 2 [(wholeRect, red, LinearClamp)] >>= \case
            Left refusal → pure (Left refusal)
            Right ticket → do
              released ← releaseConstructedTexture construction red
              atRelease ← maybe [] tableViewRetiring <$> readConstructedTable construction
              registered ← registerConstructedTexture construction (tableBlue made)
              stale ← releaseConstructedTexture construction red
              view ← readConstructedTable construction
              pure $ case (released, registered) of
                (Left refusal, _) → Left refusal
                (_, Left refusal) → Left refusal
                (Right (), Right blue) → Right (ticket, atRelease, blue, view >>= slotOf blue, stale)
      waited3 ← awaitTicket ticket3 deadline
      (fourthOn, ticket4) ←
        acted vulkan "the replacement batch" $ \construction →
          tableBatch construction made 3 [(leftRect, blue, NearestRepeat), (rightRect, red, NearestClamp)]
      waited4 ← awaitTicket ticket4 deadline
      -- Once every batch has completed, the owner's step lets the released
      -- texture's slot go.
      awaitTable vulkan "the released texture's slot reclaimed" (null . tableViewRetiring)
      (readOn, (targets, atEnd)) ←
        acted vulkan "the readbacks" $ \construction → do
          bytes ← mapM (\readback → readConstructedReadback construction readback 0 offscreenBytes) (tableReadbacks made)
          view ← readConstructedTable construction
          pure (fmap (\read' → (read', maybe [] tableViewRetiring view)) (sequence bytes))
      directory ← getTemporaryDirectory
      shots ←
        mapM
          ( \(index, (waited, bytes)) → do
              (path, handle) ← openBinaryTempFile directory ("hetoimasia-grs7-table-" <> show (index ∷ Int) <> ".png")
              ByteString.hPut handle (encodeRgba offscreenSide offscreenSide bytes)
              hClose handle
              note journal ("readback " <> tshow index <> " is at " <> Text.pack path)
              pure (Shot Rgba8Srgb waited [(point, pixelAt bytes point) | point ← tableProbes] path)
          )
          (zip [0 ..] (zip [waited1, waited2, waited3, waited4] targets))
      roots ← atomically (readVulkanRoots (vulkanController vulkan))
      let facts = TableFacts states replaced replacement retiring atEnd stale
      note journal ("table: " <> tshow facts)
      pure
        ( Seen
            [madeOn, firstOn, secondOn, thirdOn, fourthOn, readOn]
            [ "made the table, the targets, the pipeline and the readbacks"
            , "drew a texture registered before its upload"
            , "drew two uploaded textures with a sampler each"
            , "recorded a batch, released its texture and registered another"
            , "drew the new texture beside the released handle"
            , "read every readback"
            ]
            0
            (Just roots)
            Nothing
            [waited1, waited2, waited3, waited4]
            shots
            Nothing
            (Just facts)
            Nothing
            Nothing
            Nothing
            Nothing
            Nothing
        )
  where
    deadline = either (error . show) id (durationFromNanoseconds AllowZero 30000000000)
    pixelAt bytes (x, y) = ByteString.unpack (ByteString.take 4 (ByteString.drop ((y * offscreenSide + x) * 4) bytes))
    solid = ByteString.pack . concat . replicate 4
    slotOf handle view = case Map.lookup (handleIndex handle) (tableViewMapping view) of
      Just entry | entryGeneration entry == handleGeneration handle → Just (entrySlot entry)
      _ → Nothing

-- | Run one owner-thread action, answering the thread it ran on and what it
-- answered, or stop the case naming it.
acted ∷ VulkanHost () → Text → (∀ q inst msgr phys dev cmd. Construction q inst msgr phys dev cmd → IO (Either Refusal a)) → IO (ThreadId, a)
acted vulkan what body =
  act vulkan (VulkanAction (\construction → (,) <$> myThreadId <*> body construction)) >>= \case
    ActionReturned (ran, Right answer) → pure (ran, answer)
    ActionReturned (_, Left refusal) → stopWith (what <> " was refused: " <> tshow refusal)
    other → stopWith (what <> "'s action did not return: " <> outcomeText other)

-- | Wait, for at most ten seconds, for the texture table to stand as the
-- predicate asks, reading it through owner-thread actions.
awaitTable ∷ VulkanHost () → Text → (TableView → Bool) → IO ()
awaitTable vulkan what wanted = go (500 ∷ Int)
  where
    go 0 = stopWith (what <> " did not happen within ten seconds")
    go remaining =
      act vulkan (VulkanAction readConstructedTable) >>= \case
        ActionReturned (Just view) | wanted view → pure ()
        ActionReturned _ → threadDelay 20000 >> go (remaining - 1)
        other → stopWith ("reading the texture table did not return: " <> outcomeText other)

-- | What the texture table case draws into and reads back from.
data TableTargets = TableTargets
  { tableRed ∷ !Image
  , tableGreen ∷ !Image
  , tableBlue ∷ !Image
  , tableColorTargets ∷ ![Image]
  , tablePipeline ∷ !Pipeline
  , tableReadbacks ∷ ![Readback]
  }

-- | The session's texture table, of sixteen slots with eight at first, and
-- three two-by-two RGBA8 textures; four RGBA8 color targets and a readback
-- for each; and a pipeline over the table shaders.
tableTargets ∷ Construction q inst msgr phys dev cmd → IO (Either Refusal TableTargets)
tableTargets construction =
  constructTextureTable construction (either (error . show) id (validateTableConfig 16 8 (toInteger defaultVersionCount))) >>= \case
    Left refusal → pure (Left refusal)
    Right () → do
      let side = fromIntegral offscreenSide
          texture = constructImage construction (ImageDescription TextureImage Rgba8Linear 2 2 1)
      red ← texture
      green ← texture
      blue ← texture
      targets ← mapM (const (constructImage construction (ImageDescription ColorTarget Rgba8Srgb side side 1))) [1 ∷ Int .. 4]
      pipeline ←
        constructTablePipelineLayout construction tableShaders tableSamplerOffset >>= \case
          Left refusal → pure (Left refusal)
          Right layout → constructCheckedPipeline construction layout tableShaders (formatCode Rgba8Srgb)
      readbacks ← mapM (const (constructReadback construction offscreenBytes)) [1 ∷ Int .. 4]
      pure (TableTargets <$> red <*> green <*> blue <*> sequence targets <*> pipeline <*> sequence readbacks)

-- | One frame-less batch into the color target of this index: cleared to
-- opaque black from undefined, then each draw — over the scissor, through
-- the handle, with the sampler — covering it; copied into its readback.
tableBatch ∷ Construction q inst msgr phys dev cmd → TableTargets → Int → [(Rect, TextureHandle, TableSampler)] → IO (Either Refusal BatchTicket)
tableBatch construction made index draws =
  constructFramelessBatch construction steps <&> \case
    Left refusal → Left refusal
    Right (_, Left refusal) → Left refusal
    Right (ticket, Right ()) → Right ticket
  where
    side = fromIntegral offscreenSide ∷ Float
    target = tableColorTargets made !! index
    steps recorder =
      inOrder $
        [ beginRenderingInto recorder target ClearFromUndefined (ClearColor 0 0 0 1)
        , bindPipeline recorder (tablePipeline made)
        , setViewport recorder (Viewport 0 0 side side)
        , bindTable recorder
        ]
          <> concat
            [ [ setScissor recorder rect
              , selectSampler recorder (tableSamplerIndex sampler)
              , pushConstants recorder [PushFragment] 0 (handleBytes handle)
              , draw recorder 3 1
              ]
            | (rect, handle, sampler) ← draws
            ]
          <> [ endRendering recorder
             , transitionResource recorder target (FromUse ColorAttachment) TransferRead
             , copyTargetToReadback recorder target (tableReadbacks made !! index)
             , transitionResource recorder target (FromUse TransferRead) ColorAttachment
             ]
    handleBytes handle = ByteString.pack (concatMap word [handleIndex handle, handleGeneration handle])
    word ∷ Word32 → [Word8]
    word value = [fromIntegral (value `shiftR` shift) | shift ← [0, 8, 16, 24]]

wholeRect, leftRect, rightRect ∷ Rect
wholeRect = Rect 0 0 (fromIntegral offscreenSide) (fromIntegral offscreenSide)
leftRect = Rect 0 0 (fromIntegral offscreenSide `div` 2) (fromIntegral offscreenSide)
rightRect = Rect (fromIntegral offscreenSide `div` 2) 0 (fromIntegral offscreenSide `div` 2) (fromIntegral offscreenSide)

-- | Probe points well inside each half.
tableProbes ∷ [(Int, Int)]
tableProbes = [(16, 32), (48, 32)]

-- | What each readback's probes must read: the transparent placeholder
-- across both halves; red and green; red across both halves, the released
-- texture its batch was recorded with; and blue beside the placeholder the
-- released handle resolves to.
expectedTableProbes ∷ [[[Word8]]]
expectedTableProbes =
  [ [transparent, transparent]
  , [[255, 0, 0, 255], [0, 255, 0, 255]]
  , [[255, 0, 0, 255], [255, 0, 0, 255]]
  , [[0, 0, 255, 255], transparent]
  ]
  where
    transparent = [0, 0, 0, 0]

-- | The shader-sampled table case (R2D-16): a table over the session's
-- uploads, one two-texel texture — a red texel then a blue one — uploaded and
-- registered, and a pipeline over a shader-sampled layout and the table's
-- instance shaders. One frame-less batch binds the table and draws four
-- instances in one draw call, with no sampler selected: the texture through
-- nearest/clamp-to-edge (index 0), through linear/clamp-to-edge (index 2),
-- through an index of 7, and through index 3. Each instance fills a quadrant
-- of the color target, which is copied into a readback and probed.
runShaderSamplers ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runShaderSamplers backend journal = do
  heading journal "R2D-16: a surface-free session draws instances of one texture through a shader-sampled table layout, each choosing its own sampler in one draw call with no sampler selected"
  runCaseWith
    (\config → config {vulkanUploads = Just uploadConfig})
    backend
    defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024}
    []
    "vulkan-native-r2d16-shader-samplers"
    $ \vulkan _ _ _ → do
      (madeOn, made) ← acted vulkan "the table, the target and the pipeline" shaderSamplerTargets
      awaitTable vulkan "the placeholder written" tableViewPlaceholderWritten
      admitted ← submitVulkanUpload vulkan (UploadImage (samplerTexture made) [ByteString.pack [255, 0, 0, 255, 0, 0, 255, 255]])
      state ← either (pure . Left . tshow) (fmap (either (Left . tshow) Right) . (`awaitUploadTicket` deadline)) admitted
      (drawnOn, ticket) ← acted vulkan "the shader-sampled batch" (shaderSamplerBatch made)
      waited ← awaitTicket ticket deadline
      (readOn, bytes) ← acted vulkan "the readback" $ \construction → readConstructedReadback construction (samplerReadback made) 0 offscreenBytes
      directory ← getTemporaryDirectory
      (path, handle) ← openBinaryTempFile directory "hetoimasia-r2d16-shader-samplers.png"
      ByteString.hPut handle (encodeRgba offscreenSide offscreenSide bytes)
      hClose handle
      note journal ("the readback is at " <> Text.pack path)
      note journal ("the upload: " <> tshow state)
      roots ← atomically (readVulkanRoots (vulkanController vulkan))
      let shot = Shot Rgba8Srgb waited [(point, pixelAt bytes point) | point ← shaderSamplerProbes] path
      pure
        ( Seen
            [madeOn, drawnOn, readOn]
            ["made the table, the target, the pipeline and the readback", "drew four instances in one draw call", "read the readback"]
            0
            (Just roots)
            Nothing
            [waited]
            [shot]
            Nothing
            (Just (TableFacts [state] Nothing Nothing [] [] (Right ())))
            Nothing
            Nothing
            Nothing
            Nothing
            Nothing
        )
  where
    deadline = either (error . show) id (durationFromNanoseconds AllowZero 30000000000)
    pixelAt bytes (x, y) = ByteString.unpack (ByteString.take 4 (ByteString.drop ((y * offscreenSide + x) * 4) bytes))

-- | What the shader-sampled case draws with and reads back from.
data SamplerTargets = SamplerTargets
  { samplerTexture ∷ !Image
  , samplerTarget ∷ !Image
  , samplerPipeline ∷ !Pipeline
  , samplerReadback ∷ !Readback
  }

-- | The session's texture table, a two-by-one RGBA8 texture, an RGBA8 sRGB
-- color target, the shared ring, a pipeline over a shader-sampled table layout
-- and the table's instance shaders, and a readback for the target.
shaderSamplerTargets ∷ Construction q inst msgr phys dev cmd → IO (Either Refusal SamplerTargets)
shaderSamplerTargets construction =
  constructTextureTable construction (either (error . show) id (validateTableConfig 16 8 (toInteger defaultVersionCount))) >>= \case
    Left refusal → pure (Left refusal)
    Right () →
      constructRing construction (either (error . show) id (validateRingSize 4096)) >>= \case
        Left refusal → pure (Left refusal)
        Right () → do
          let side = fromIntegral offscreenSide
          texture ← constructImage construction (ImageDescription TextureImage Rgba8Linear 2 1 1)
          target ← constructImage construction (ImageDescription ColorTarget Rgba8Srgb side side 1)
          pipeline ←
            constructShaderSampledTablePipelineLayout construction tableInstanceShaders >>= \case
              Left refusal → pure (Left refusal)
              Right layout → constructCheckedPipeline construction layout tableInstanceShaders (formatCode Rgba8Srgb)
          readback ← constructReadback construction offscreenBytes
          pure (SamplerTargets <$> texture <*> target <*> pipeline <*> readback)

-- | The four instances, in clip space: a quadrant of the target each, in
-- reading order, drawing the registered texture with sampler indices 0, 2, 7
-- and 3. Each is the rectangle's four floats, the handle's index and
-- generation, and the sampler index.
shaderSamplerInstances ∷ TextureHandle → ByteString.ByteString
shaderSamplerInstances handle =
  ByteString.pack . concat $
    [ concatMap (word . castFloatToWord32) [x0, y0, x0 + 1, y0 + 1] <> word (handleIndex handle) <> word (handleGeneration handle) <> word sampler
    | ((x0, y0), sampler) ← zip [(-1, -1), (0, -1), (-1, 0), (0, 0)] [0, 2, 7, 3]
    ]
  where
    word ∷ Word32 → [Word8]
    word value = [fromIntegral (value `shiftR` shift) | shift ← [0, 8, 16, 24]]

-- | One frame-less batch: the instances written into a ring region, the
-- target cleared to opaque black, the table bound, and one draw of six
-- vertices for the four instances, with no sampler selected; copied into the
-- readback.
shaderSamplerBatch ∷ SamplerTargets → Construction q inst msgr phys dev cmd → IO (Either Refusal BatchTicket)
shaderSamplerBatch made construction =
  registerConstructedTexture construction (samplerTexture made) >>= \case
    Left refusal → pure (Left refusal)
    Right handle →
      constructFramelessBatch construction (steps (shaderSamplerInstances handle)) <&> \case
        Left refusal → Left refusal
        Right (_, Left refusal) → Left refusal
        Right (ticket, Right ()) → Right ticket
  where
    side = fromIntegral offscreenSide ∷ Float
    target = samplerTarget made
    steps contents recorder =
      claimRegion recorder (fromIntegral (ByteString.length contents)) 4 >>= \case
        Left refusal → pure (Left refusal)
        Right claim →
          writeClaim recorder claim 0 contents >>= \case
            Left refusal → pure (Left refusal)
            Right () →
              inOrder
                [ beginRenderingInto recorder target ClearFromUndefined (ClearColor 0 0 0 1)
                , bindPipeline recorder (samplerPipeline made)
                , setViewport recorder (Viewport 0 0 side side)
                , setScissor recorder (Rect 0 0 (fromIntegral offscreenSide) (fromIntegral offscreenSide))
                , bindTable recorder
                , bindVertexBuffer recorder 0 (FromClaim claim 0)
                , draw recorder 6 4
                , endRendering recorder
                , transitionResource recorder target (FromUse ColorAttachment) TransferRead
                , copyTargetToReadback recorder target (samplerReadback made)
                , transitionResource recorder target (FromUse TransferRead) ColorAttachment
                ]

-- | The probe points, in the quadrants' reading order of the case's
-- instances. The quadrants are 32 pixels across and the texture two texels
-- wide, so a pixel at offset @i@ reads at @(i + 0.5) / 32@ across it: offset
-- 12 reads 0.390625, where nearest takes the red texel and linear blends in
-- 0.28125 of the blue one; offset 3 reads 0.109375, where linear/repeat
-- wraps 0.28125 of the blue texel in from the left and linear/clamp-to-edge
-- takes the red texel alone. The probes: nearest at 12, linear/clamp at 12,
-- index 7 at 3, index 3 at 3, and linear/clamp at 3.
shaderSamplerProbes ∷ [(Int, Int)]
shaderSamplerProbes = [(12, 16), (44, 16), (3, 48), (35, 48), (35, 16)]

-- | What each probe must read: the first exactly, the rest within one step of
-- the sRGB encoding of the weighted blend they sample.
expectedShaderSamplerProbes ∷ [[Word8]]
expectedShaderSamplerProbes = [[255, 0, 0, 255], blend, blend, blend, [255, 0, 0, 255]]
  where
    weight = 0.28125 ∷ Double
    blend = [encode (1 - weight), 0, encode weight, 255]
    encode linear =
      round . (* 255) $ if linear <= 0.0031308 then 12.92 * linear else 1.055 * linear ** (1 / 2.4) - 0.055

-- | The storage-table case (R2D-15): a texture table and a ring made with a
-- storage-table window, the storage table, and a pipeline over a layout that
-- holds the table's two sets and set 2, with the storage-table shaders. One
-- frame-less batch claims two regions of the ring for per-batch tables —
-- each a rectangle in clip space and a colour — writes them, binds the
-- texture table, and draws twice in one batch, binding each table at its own
-- dynamic offset, with no selected sampler. The fragment shader reads its
-- colour from the bound table, so the target, copied into a readback, shows
-- each draw's own table's colour exactly.
runStorageTables ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runStorageTables backend journal = do
  heading journal "R2D-15: a surface-free session draws twice in one batch, binding a per-batch table from the ring at its own dynamic offset before each draw, the fragment shader reading its colour from the bound table"
  runCaseWith
    (\config → config {vulkanUploads = Just uploadConfig})
    backend
    defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024}
    []
    "vulkan-native-r2d15-storage-tables"
    $ \vulkan _ _ _ → do
      (madeOn, made) ← acted vulkan "the tables, the target and the pipeline" storageTableTargets
      awaitTable vulkan "the placeholder written" tableViewPlaceholderWritten
      (drawnOn, ticket) ← acted vulkan "the storage-table batch" (storageTableBatch made)
      waited ← awaitTicket ticket deadline
      (readOn, bytes) ← acted vulkan "the readback" $ \construction → readConstructedReadback construction (storageReadback made) 0 offscreenBytes
      directory ← getTemporaryDirectory
      (path, handle) ← openBinaryTempFile directory "hetoimasia-r2d15-storage-tables.png"
      ByteString.hPut handle (encodeRgba offscreenSide offscreenSide bytes)
      hClose handle
      note journal ("the readback is at " <> Text.pack path)
      roots ← atomically (readVulkanRoots (vulkanController vulkan))
      let shot = Shot Rgba8Linear waited [(point, pixelAt bytes point) | point ← storageTableProbes] path
      pure
        ( Seen
            [madeOn, drawnOn, readOn]
            ["made the ring, its window, the tables and the pipeline", "drew twice, binding each table at its dynamic offset", "read the readback"]
            0
            (Just roots)
            Nothing
            [waited]
            [shot]
            Nothing
            (Just (TableFacts [] Nothing Nothing [] [] (Right ())))
            Nothing
            Nothing
            Nothing
            Nothing
            Nothing
        )
  where
    deadline = either (error . show) id (durationFromNanoseconds AllowZero 30000000000)
    pixelAt bytes (x, y) = ByteString.unpack (ByteString.take 4 (ByteString.drop ((y * offscreenSide + x) * 4) bytes))

-- | What the storage-table case draws with and reads back from.
data StorageTargets = StorageTargets
  { storageTarget ∷ !Image
  , storagePipeline ∷ !Pipeline
  , storageReadback ∷ !Readback
  }

-- | The storage-table window, in bytes: a table is thirty-two, and a window of
-- eight times that shows the shader none of the next claim's.
storageWindowSize ∷ Integer
storageWindowSize = 256

-- | The session's texture table, the shared ring made with a storage-table
-- window, the storage table, an RGBA8 linear color target, a pipeline over a
-- shader-sampled layout that also holds set 2 and the storage-table shaders,
-- and a readback for the target.
storageTableTargets ∷ Construction q inst msgr phys dev cmd → IO (Either Refusal StorageTargets)
storageTableTargets construction =
  constructTextureTable construction (either (error . show) id (validateTableConfig 16 8 (toInteger defaultVersionCount))) >>= \case
    Left refusal → pure (Left refusal)
    Right () →
      constructRingWith construction (either (error . show) id (validateRingSize 4096)) (either (error . show) id (validateStorageWindow storageWindowSize)) >>= \case
        Left refusal → pure (Left refusal)
        Right () →
          constructStorageTable construction >>= \case
            Left refusal → pure (Left refusal)
            Right () → do
              let side = fromIntegral offscreenSide
              target ← constructImage construction (ImageDescription ColorTarget Rgba8Linear side side 1)
              pipeline ←
                constructTablePipelineLayoutWith construction storageTableShaders (TableLayoutOptions TableShaderSampler True) >>= \case
                  Left refusal → pure (Left refusal)
                  Right layout → constructCheckedPipeline construction layout storageTableShaders (formatCode Rgba8Linear)
              readback ← constructReadback construction offscreenBytes
              pure (StorageTargets <$> target <*> pipeline <*> readback)

-- | The two tables, each a rectangle in clip space (left, top, right, bottom)
-- and a colour as eight floats: the target's left half in one colour and its
-- right half in another, neither a colour a clear or a blend could make.
storageTables ∷ [ByteString.ByteString]
storageTables = [table (-1, -1, 0, 1) (200 / 255, 100 / 255, 50 / 255, 1), table (0, -1, 1, 1) (30 / 255, 220 / 255, 120 / 255, 1)]
  where
    table (left, top, right, bottom) (red, green, blue, alpha) =
      ByteString.pack (concatMap (word . castFloatToWord32) [left, top, right, bottom, red, green, blue, alpha])
    word ∷ Word32 → [Word8]
    word value = [fromIntegral (value `shiftR` shift) | shift ← [0, 8, 16, 24]]

-- | One frame-less batch: a region of the ring claimed for each table with
-- the device's storage alignment and written, the target cleared to opaque
-- black, the texture table bound, and two draws of six vertices, each after
-- binding its own table; copied into the readback.
storageTableBatch ∷ StorageTargets → Construction q inst msgr phys dev cmd → IO (Either Refusal BatchTicket)
storageTableBatch made construction =
  constructFramelessBatch construction steps <&> \case
    Left refusal → Left refusal
    Right (_, Left refusal) → Left refusal
    Right (ticket, Right ()) → Right ticket
  where
    side = fromIntegral offscreenSide ∷ Float
    target = storageTarget made
    steps recorder = do
      claims ← mapM (\contents → claimTable recorder (fromIntegral (ByteString.length contents)) <&> fmap (\claim → (claim, contents))) storageTables
      case sequence claims of
        Left refusal → pure (Left refusal)
        Right held →
          inOrder $
            [writeClaim recorder claim 0 contents | (claim, contents) ← held]
              <> [ beginRenderingInto recorder target ClearFromUndefined (ClearColor 0 0 0 1)
                 , bindPipeline recorder (storagePipeline made)
                 , setViewport recorder (Viewport 0 0 side side)
                 , setScissor recorder (Rect 0 0 (fromIntegral offscreenSide) (fromIntegral offscreenSide))
                 , bindTable recorder
                 ]
              <> concat [[bindStorageTable recorder claim 0, draw recorder 6 1] | (claim, _) ← held]
              <> [ endRendering recorder
                 , transitionResource recorder target (FromUse ColorAttachment) TransferRead
                 , copyTargetToReadback recorder target (storageReadback made)
                 , transitionResource recorder target (FromUse TransferRead) ColorAttachment
                 ]

-- | The probe points: the middle of each half of the target.
storageTableProbes ∷ [(Int, Int)]
storageTableProbes = [(16, 32), (48, 32)]

-- | What each probe must read, exactly: each table's colour, as the bytes of
-- the linear target.
expectedStorageTableProbes ∷ [[Word8]]
expectedStorageTableProbes = [[200, 100, 50, 255], [30, 220, 120, 255]]

-- | The sprites case (GRS-8): the sprites sample's window-free evidence over
-- this suite's surface-free session — the sample's own scene, renderer,
-- oracle, PNG and probe record ("Hetoimasia.Sample.Sprites.Evidence") — with
-- the files written under the validation runner's evidence directory when it
-- names one, and otherwise into a directory of their own that is kept and
-- reported.
runSprites ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runSprites backend journal = do
  heading journal "GRS-8: a surface-free session draws the sprites sample's scene of instanced textured quads through texture handles with premultiplied-alpha blending, checks every probe against the independent oracle, and writes a lossless PNG and a probe record"
  directory ← spritesDirectory
  note journal ("the sprites evidence is written into " <> Text.pack directory)
  runCaseWith
    (\config → config {vulkanUploads = Just uploadConfig})
    backend
    defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024}
    []
    "vulkan-native-grs8-sprites"
    $ \vulkan _ _ _ → do
      outcome ← runEvidence (spritesHost vulkan) directory
      note journal ("sprites capture: " <> maybe "not written" Text.pack (evidencePng outcome) <> "; probe record: " <> Text.pack (evidenceRecord outcome))
      mapM_ (\failure → note journal ("sprites evidence failed: " <> failure)) (evidenceFailure outcome)
      roots ← atomically (readVulkanRoots (vulkanController vulkan))
      pure (Seen [] ["ran the sprites evidence"] 0 (Just roots) Nothing [] [] Nothing Nothing (Just outcome) Nothing Nothing Nothing Nothing)
  where
    spritesDirectory =
      lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE" >>= \case
        Just evidence | not (null evidence) → pure (evidence </> "sprites")
        _ → do
          temporary ← getTemporaryDirectory
          stamp ← (round . (* 1000) . utcTimeToPOSIXSeconds ∷ UTCTime → Integer) <$> getCurrentTime
          pure (temporary </> ("hetoimasia-sprites-" <> show stamp))

-- | The swap case (GRS-9): the sprites sample's swap evidence over this
-- suite's surface-free session — the atlas's handle redirected to a
-- replacement between a batch's recording and its submission, with the
-- frames before, across and after the swap read back and checked — with the
-- files written under the validation runner's evidence directory when it
-- names one, and otherwise into a directory of their own that is kept and
-- reported.
runSwap ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runSwap backend journal = do
  heading journal "GRS-9: a surface-free session swaps the sprites sample's atlas under its texture handle: a frame before the swap samples the atlas, a frame recorded before the swap and submitted after it still does, a frame after it samples the replacement from the same instance data, and the atlas's slot is reused only once the delayed frame completes"
  directory ← swapDirectory
  note journal ("the swap evidence is written into " <> Text.pack directory)
  runCaseWith
    (\config → config {vulkanUploads = Just uploadConfig})
    backend
    defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024}
    []
    "vulkan-native-grs9-swap"
    $ \vulkan _ _ _ → do
      outcome ← runSwapEvidence (spritesHost vulkan) directory
      note journal ("swap captures: " <> Text.intercalate ", " (map Text.pack (swapPngs outcome)) <> "; record: " <> Text.pack (swapRecord outcome))
      mapM_ (\facts → note journal ("swap facts: " <> tshow facts)) (swapFacts outcome)
      mapM_ (\failure → note journal ("swap evidence failed: " <> failure)) (swapFailure outcome)
      roots ← atomically (readVulkanRoots (vulkanController vulkan))
      pure (Seen [] ["ran the swap evidence"] 0 (Just roots) Nothing [] [] Nothing Nothing Nothing Nothing (Just outcome) Nothing Nothing)
  where
    swapDirectory =
      lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE" >>= \case
        Just evidence | not (null evidence) → pure (evidence </> "swap")
        _ → do
          temporary ← getTemporaryDirectory
          stamp ← (round . (* 1000) . utcTimeToPOSIXSeconds ∷ UTCTime → Integer) <$> getCurrentTime
          pure (temporary </> ("hetoimasia-swap-" <> show stamp))

-- | The scene3d case (GRS-10): the scene3d sample's window-free evidence over
-- this suite's surface-free session — its two cubes drawn with a depth test
-- from two camera poses into a colour target and a depth target, each pose
-- read back after completion and checked against the sample's own
-- independent oracle ("Hetoimasia.Sample.Scene3d.Evidence") — with the files
-- written under the validation runner's evidence directory when it names
-- one, and otherwise into a directory of their own that is kept and
-- reported.
runScene3d ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runScene3d backend journal = do
  heading journal "GRS-10: a surface-free session draws the scene3d sample's two flat-coloured cubes with a depth test from two camera poses into a colour target and a depth target, reads each pose back after completion, checks every probe against the independent oracle, and writes a lossless PNG a pose and a probe record"
  directory ← scene3dDirectory
  note journal ("the scene3d evidence is written into " <> Text.pack directory)
  runCase backend defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024} [] "vulkan-native-grs10-scene3d" $ \vulkan _ _ _ → do
    outcome ← Scene3dEvidence.runEvidence (scene3dHost vulkan) directory
    note journal ("scene3d depth format: " <> maybe "not chosen" tshow (Scene3dEvidence.evidenceDepthFormat outcome))
    note journal ("scene3d captures: " <> Text.intercalate ", " [Text.pack path | pose ← Scene3dEvidence.evidencePoses outcome, Just path ← [Scene3dEvidence.poseEvidencePng pose]] <> "; probe record: " <> Text.pack (Scene3dEvidence.evidenceRecord outcome))
    mapM_ (\failure → note journal ("scene3d evidence failed: " <> failure)) (Scene3dEvidence.evidenceFailure outcome)
    roots ← atomically (readVulkanRoots (vulkanController vulkan))
    pure (Seen [] ["ran the scene3d evidence"] 0 (Just roots) Nothing [] [] Nothing Nothing Nothing Nothing Nothing (Just outcome) Nothing)
  where
    scene3dDirectory =
      lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE" >>= \case
        Just evidence | not (null evidence) → pure (evidence </> "scene3d")
        _ → do
          temporary ← getTemporaryDirectory
          stamp ← (round . (* 1000) . utcTimeToPOSIXSeconds ∷ UTCTime → Integer) <$> getCurrentTime
          pure (temporary </> ("hetoimasia-scene3d-" <> show stamp))

-- | The scene3d evidence's host over this suite's session: owner-thread
-- actions over its constructions, and batches waited for, each wait bounded
-- by a deadline.
scene3dHost ∷ VulkanHost () → Scene3dEvidence.Host
scene3dHost vulkan =
  Scene3dEvidence.Host
    { Scene3dEvidence.hostAct = \what body → acting what (VulkanAction (body . scene3dBuilders))
    , Scene3dEvidence.hostRecord = \what body →
        acting
          what
          ( VulkanAction
              ( \construction →
                  body (scene3dBuilders construction) >>= \case
                    Left refusal → pure (Left refusal)
                    Right recording →
                      constructFramelessBatch construction recording >>= \case
                        Left refusal → pure (Left refusal)
                        Right (_, Left refusal) → pure (Left refusal)
                        Right (ticket, Right ()) → pure (Right ticket)
              )
          )
    , Scene3dEvidence.hostAwait = \ticket →
        awaitTicket ticket deadline >>= \case
          Right TicketComplete → pure (Right ())
          other → pure (Left (tshow other))
    , Scene3dEvidence.hostRead = \readback → acting "reading the readback" (VulkanAction (\construction → readConstructedReadback construction readback 0 Scene3dScene.targetBytes))
    }
  where
    deadline = either (error . show) id (durationFromNanoseconds AllowZero 30000000000)
    acting ∷ Text → VulkanAction (Either Refusal a) → IO (Either Text a)
    acting what action =
      atomically (submitVulkanAction vulkan action) >>= \case
        Left refusal → pure (Left (what <> " was refused: " <> tshow refusal))
        Right ticket →
          atomically (awaitVulkanAction ticket) >>= \case
            ActionReturned (Right value) → pure (Right value)
            ActionReturned (Left refusal) → pure (Left (what <> " was refused: " <> tshow refusal))
            ActionRaised failure → pure (Left (what <> " raised: " <> tshow failure))
            ActionRefused refusal → pure (Left (what <> " was refused before it ran: " <> tshow refusal))

-- | The scene3d sample's constructions, from the host's.
scene3dBuilders ∷ Construction q inst msgr phys dev cmd → Scene3d.Builders q inst msgr phys dev cmd
scene3dBuilders construction =
  Scene3d.Builders
    { Scene3d.buildRing = constructRing construction
    , Scene3d.buildImage = constructImage construction
    , Scene3d.buildLayout = constructPipelineLayoutFor construction
    , Scene3d.buildPipeline = constructDepthCheckedPipeline construction
    , Scene3d.buildReadback = constructReadback construction
    , Scene3d.chooseDepthFormat = constructDepthFormat construction
    }

-- | The sprites evidence's host over this suite's session: owner-thread
-- actions over its constructions, uploads admitted from the main thread and
-- waited for, and batches waited for, each wait bounded by a deadline.
spritesHost ∷ VulkanHost () → Host
spritesHost vulkan =
  Host
    { hostAct = \what body → acting what (VulkanAction (body . spritesBuilders))
    , hostRecord = \what body →
        acting
          what
          ( VulkanAction
              ( \construction →
                  body (spritesBuilders construction) >>= \case
                    Left refusal → pure (Left refusal)
                    Right recording →
                      constructFramelessBatch construction recording >>= \case
                        Left refusal → pure (Left refusal)
                        Right (_, Left refusal) → pure (Left refusal)
                        Right (ticket, Right ()) → pure (Right ticket)
              )
          )
    , hostUpload = \request →
        submitVulkanUpload vulkan request >>= \case
          Left refusal → pure (Left (tshow refusal))
          Right ticket →
            awaitUploadTicket ticket deadline >>= \case
              Right UploadComplete → pure (Right ())
              other → pure (Left (tshow other))
    , hostAwait = \ticket →
        awaitTicket ticket deadline >>= \case
          Right TicketComplete → pure (Right ())
          other → pure (Left (tshow other))
    , hostReadTable = acting "reading the texture table" (VulkanAction (fmap Right . readConstructedTable))
    , hostRead = \readback → acting "reading the readback" (VulkanAction (\construction → readConstructedReadback construction readback 0 spritesTargetBytes))
    }
  where
    deadline = either (error . show) id (durationFromNanoseconds AllowZero 30000000000)
    acting ∷ Text → VulkanAction (Either Refusal a) → IO (Either Text a)
    acting what action =
      atomically (submitVulkanAction vulkan action) >>= \case
        Left refusal → pure (Left (what <> " was refused: " <> tshow refusal))
        Right ticket →
          atomically (awaitVulkanAction ticket) >>= \case
            ActionReturned (Right value) → pure (Right value)
            ActionReturned (Left refusal) → pure (Left (what <> " was refused: " <> tshow refusal))
            ActionRaised failure → pure (Left (what <> " raised: " <> tshow failure))
            ActionRefused refusal → pure (Left (what <> " was refused before it ran: " <> tshow refusal))

-- | The sample's constructions, from the host's.
spritesBuilders ∷ Construction q inst msgr phys dev cmd → Builders q inst msgr phys dev cmd
spritesBuilders construction =
  Builders
    { buildRing = constructRing construction
    , buildTable = constructTextureTable construction
    , buildImage = constructImage construction
    , buildTableLayout = constructTablePipelineLayout construction
    , buildPipeline = constructBlendedCheckedPipeline construction
    , buildReadback = constructReadback construction
    , registerImage = registerConstructedTexture construction
    , swapImage = swapConstructedTexture construction
    , inspectTable = readConstructedTable construction
    }

-- | The ordered path's case (R2D-7): the 2D renderer's recorder
-- ("Hetoimasia.Render.TwoD.Vulkan") over this suite's surface-free session —
-- eleven fixtures rendered offscreen, every pixel of every target judged against
-- the oracle ("Test.GPU.Vulkan.Native.OrderedPath") — with the files written
-- under the validation runner's evidence directory when it names one, and
-- otherwise into a directory of their own that is kept and reported.
runOrderedPath ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runOrderedPath backend journal =
  runEvidenceSuite
    backend
    journal
    (\vulkan directory → OrderedPath.runEvidence (orderedHost vulkan) OrderedPath.orderedSuite directory)
    "R2D-7: a surface-free session records render-2d snapshots through the ordered path into offscreen targets, reads each back after completion and judges every pixel against the render-2d oracle, and writes a lossless PNG a target and a probe record"
    "vulkan-native-r2d7-ordered-path"
    "ordered-path"

-- | The cutout path's case (R2D-9): the same recorder over the same kind of
-- session, with a @D32_SFLOAT@ depth image for every target, seven fixtures
-- judged against the oracle planned with the marks they name
-- ("Test.GPU.Vulkan.Native.CutoutDepth"), and its files and probe record under
-- the validation runner's evidence directory when it names one, and otherwise
-- in a directory of their own that is kept and reported. Where the device
-- chooses another depth format it renders nothing, reports the format, and
-- checks the recorder's refusal on it.
runCutoutDepth ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runCutoutDepth backend journal =
  runEvidenceSuite
    backend
    journal
    (\vulkan directory → OrderedPath.runEvidence (orderedHost vulkan) CutoutDepth.cutoutSuite directory)
    "R2D-9: a surface-free session records render-2d snapshots with cutout art depth-tested in world layers into offscreen targets that have a D32_SFLOAT depth image, reads each back after completion and judges every pixel against the render-2d oracle, and writes a lossless PNG a target and a probe record that names the depth format and every indeterminate reason"
    "vulkan-native-r2d9-cutout-depth"
    "cutout-depth"

-- | The retained chunks' case (R2D-10): the same recorder over the same kind of
-- session, with a @D32_SFLOAT@ depth image for every target, retained chunks
-- built once and listed by reference over several frames beside the dynamic
-- content that alone is republished, the adapter's holds and a release requested
-- through the integration driven as the owner does, every frame read back after
-- completion and judged against the oracle ("Test.GPU.Vulkan.Native.RetainedPath").
-- Its files, probe record and measurements go under the validation runner's
-- evidence directory when it names one, and otherwise into a directory of their
-- own that is kept and reported.
runRetained ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runRetained backend journal =
  runEvidenceSuite
    backend
    journal
    (\vulkan directory → RetainedPath.runRetained (retainedHost vulkan) directory)
    "R2D-10: a surface-free session builds retained chunks once and lists them in render-2d snapshots over several frames beside dynamic content that alone is republished, records each frame into an offscreen target that has a D32_SFLOAT depth image, reads it back after completion and judges every pixel against the render-2d oracle: retained cutout and translucent content interleaved with dynamic content, a UI chunk and a world chunk without depth drawn in the ordered path, a texture swap showing through a chunk and a mark-changing swap refused, a chunk released while shown still drawn until a snapshot without it is adopted, and a chunk outside a view skipped"
    "vulkan-native-r2d10-retained"
    "retained"

runEvidenceSuite ∷ Maybe Backend → Journal → (VulkanHost () → FilePath → IO OrderedPath.Evidence) → Text → Text → String → IO SurfaceFreeOutcome
runEvidenceSuite backend journal runner headline caseName directoryName = do
  heading journal headline
  directory ← evidenceDirectory
  note journal ("the " <> Text.pack directoryName <> " evidence is written into " <> Text.pack directory)
  runCaseWith
    (\config → config {vulkanUploads = Just uploadConfig})
    backend
    defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024}
    []
    caseName
    $ \vulkan _ _ _ → do
      outcome ← runner vulkan directory
      note journal (Text.pack directoryName <> " probe record: " <> Text.pack (OrderedPath.evidenceRecord outcome))
      mapM_ (\depth → note journal (Text.pack directoryName <> " depth format: " <> tshow depth)) (OrderedPath.evidenceDepthFormat outcome)
      mapM_ (\why → note journal (Text.pack directoryName <> " unavailable: " <> why)) (OrderedPath.evidenceUnavailable outcome)
      mapM_ (\failure → note journal (Text.pack directoryName <> " evidence failed: " <> failure)) (OrderedPath.evidenceFailure outcome)
      mapM_
        ( \result → do
            let probes = OrderedPath.resultProbes result
                determinate = length [() | probed ← probes, OrderedPath.isDeterminate probed]
            note journal
              ( Text.pack directoryName <> " fixture " <> OrderedPath.resultFixture result <> ": "
                  <> tshow (length probes) <> " probes, " <> tshow determinate <> " determinate, "
                  <> tshow (length probes - determinate) <> " not counted; "
                  <> (if OrderedPath.fixturePassed result then "passed" else "FAILED" <> maybe "" (": " <>) (OrderedPath.resultFailure result))
              )
        )
        (OrderedPath.evidenceFixtures outcome)
      roots ← atomically (readVulkanRoots (vulkanController vulkan))
      pure (Seen [] ["ran the " <> Text.pack directoryName <> " evidence"] 0 (Just roots) Nothing [] [] Nothing Nothing Nothing Nothing Nothing Nothing (Just outcome))
  where
    evidenceDirectory =
      lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE" >>= \case
        Just evidence | not (null evidence) → pure (evidence </> directoryName)
        _ → do
          temporary ← getTemporaryDirectory
          stamp ← (round . (* 1000) . utcTimeToPOSIXSeconds ∷ UTCTime → Integer) <$> getCurrentTime
          pure (temporary </> ("hetoimasia-" <> directoryName <> "-" <> show stamp))

-- | The retained case's host over this suite's session: the ordered path's, and
-- uploads admitted for a ticket the registry polls, and the integration's own
-- release request and owner-thread action for the adapter's releases.
retainedHost ∷ VulkanHost () → RetainedPath.RetainedHost
retainedHost vulkan =
  RetainedPath.RetainedHost
    { RetainedPath.retainedBase = orderedHost vulkan
    , RetainedPath.retainedSubmit = submit
    , RetainedPath.retainedRequestRelease = \body →
        atomically (requestVulkanRelease vulkan (VulkanAction (body . RetainedPath.buildersWith submit))) >>= \case
          Left refusal → pure (Left (tshow refusal))
          Right _ → pure (Right ())
    , RetainedPath.retainedRunOnOwner = \body →
        atomically (submitVulkanAction vulkan (VulkanAction (body . RetainedPath.buildersWith submit))) >>= \case
          Left refusal → pure (Left (tshow refusal))
          Right _ → pure (Right ())
    }
  where
    submit request =
      submitVulkanUpload vulkan request >>= \case
        Left (VulkanUploadRefused refusal) → pure (Left refusal)
        Left (VulkanUploadsUnavailable _) → pure (Left UploadClosed)
        Right ticket → pure (Right ticket)

-- | The ordered path's evidence host over this suite's session: owner-thread
-- actions over its constructions, uploads admitted from the main thread and
-- waited for, and batches waited for, each wait bounded by a deadline.
orderedHost ∷ VulkanHost () → OrderedPath.Host
orderedHost vulkan =
  OrderedPath.Host
    { OrderedPath.hostAct = \what body → acting what (VulkanAction body)
    , OrderedPath.hostRecord = \what body →
        acting
          what
          ( VulkanAction
              ( \construction →
                  body construction >>= \case
                    Left refusal → pure (Left refusal)
                    Right recording →
                      constructFramelessBatch construction recording >>= \case
                        Left refusal → pure (Left refusal)
                        Right (_, Left refusal) → pure (Left refusal)
                        Right (ticket, Right ()) → pure (Right ticket)
              )
          )
    , OrderedPath.hostUpload = \request →
        submitVulkanUpload vulkan request >>= \case
          Left refusal → pure (Left (tshow refusal))
          Right ticket →
            awaitUploadTicket ticket deadline >>= \case
              Right UploadComplete → pure (Right ())
              other → pure (Left (tshow other))
    , OrderedPath.hostAwait = \ticket →
        awaitTicket ticket deadline >>= \case
          Right TicketComplete → pure (Right ())
          other → pure (Left (tshow other))
    , OrderedPath.hostReadTable = acting "reading the texture table" (VulkanAction (fmap Right . readConstructedTable))
    , OrderedPath.hostRead = \readback size → acting "reading a readback" (VulkanAction (\construction → readConstructedReadback construction readback 0 size))
    }
  where
    deadline = either (error . show) id (durationFromNanoseconds AllowZero 30000000000)
    acting ∷ Text → VulkanAction (Either Refusal a) → IO (Either Text a)
    acting what action =
      atomically (submitVulkanAction vulkan action) >>= \case
        Left refusal → pure (Left (what <> " was refused: " <> tshow refusal))
        Right ticket →
          atomically (awaitVulkanAction ticket) >>= \case
            ActionReturned (Right value) → pure (Right value)
            ActionReturned (Left refusal) → pure (Left (what <> " was refused: " <> tshow refusal))
            ActionRaised failure → pure (Left (what <> " raised: " <> tshow failure))
            ActionRefused refusal → pure (Left (what <> " was refused before it ran: " <> tshow refusal))

-- | What the growth case (GRS-14) found.
data GrowthFacts = GrowthFacts
  { growthAllocated ∷ ![Word32]
    -- ^ The slots set 0 held: at first, after the first growth, after the
    -- second.
  , growthSets ∷ ![Word64]
    -- ^ The current set 0 at each of those points: a new set at each growth.
  , growthBackpressure ∷ !(Either Refusal ())
    -- ^ What registering one texture past the cap answered.
  , growthTickets ∷ ![Either Text UploadState]
  }
  deriving (Show)

-- | The growth case (GRS-14): a table of five slots at most, two at first,
-- over the session's uploads, and a pipeline built over it before any
-- growth. A batch is recorded with the first texture's handle, the second
-- texture's registration then grows the table — the batch is submitted after,
-- when its action returns — and the batch still samples the first texture
-- from the set it bound. The third and fourth textures grow the table to its
-- cap, not to a power of two, a fifth is backpressure, and a batch draws a
-- texture registered before both growths beside one registered after them,
-- with the pipeline built before them. Both batches are read back and probed.
runGrowth ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runGrowth backend journal = do
  heading journal "GRS-14: a surface-free session grows its texture table twice to a cap that is no power of two, a batch recorded before a growth and submitted after it samples correctly, handles from before and after growth draw with a pipeline built before it, and the cap is backpressure"
  runCaseWith
    (\config → config {vulkanUploads = Just uploadConfig})
    backend
    defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024}
    []
    "vulkan-native-grs14-table-growth"
    $ \vulkan _ _ _ → do
      (madeOn, (made, textures)) ← acted vulkan "the table, its textures and its pipeline" growthTargets
      awaitTable vulkan "the placeholder written" tableViewPlaceholderWritten
      initial ← tableNow vulkan
      admitted ← mapM (submitVulkanUpload vulkan) [UploadImage texture [solid colour] | (texture, colour) ← zip textures growthColours]
      states ←
        mapM
          ( \case
              Left refusal → pure (Left (tshow refusal))
              Right ticket → either (Left . tshow) Right <$> awaitUploadTicket ticket deadline
          )
          admitted
      (firstOn, (first, ticket1)) ←
        acted vulkan "the batch recorded before the first growth" $ \construction →
          registerConstructedTexture construction (textures !! 0) >>= \case
            Left refusal → pure (Left refusal)
            Right first → do
              batch ← tableBatch construction made 0 [(wholeRect, first, NearestClamp)]
              -- The second texture finds no free slot: the table grows
              -- before this action returns, which is when the batch is
              -- submitted.
              grown ← registerConstructedTexture construction (textures !! 1)
              pure ((,) first <$> (grown >> batch))
      waited1 ← awaitTicket ticket1 deadline
      afterFirst ← tableNow vulkan
      (secondOn, (backpressure, ticket2)) ←
        acted vulkan "the second growth, the cap and the batch over both" $ \construction → do
          _ ← registerConstructedTexture construction (textures !! 2)
          fourth ← registerConstructedTexture construction (textures !! 3)
          capped ← registerConstructedTexture construction (textures !! 4)
          case fourth of
            Left refusal → pure (Left refusal)
            Right latest →
              fmap ((,) (fmap (const ()) capped)) <$> tableBatch construction made 1 [(leftRect, first, NearestClamp), (rightRect, latest, NearestClamp)]
      waited2 ← awaitTicket ticket2 deadline
      afterSecond ← tableNow vulkan
      (readOn, targets) ←
        acted vulkan "the readbacks" $ \construction →
          sequence <$> mapM (\readback → readConstructedReadback construction readback 0 offscreenBytes) (tableReadbacks made)
      directory ← getTemporaryDirectory
      shots ←
        mapM
          ( \(index, (waited, bytes)) → do
              (path, handle) ← openBinaryTempFile directory ("hetoimasia-grs14-growth-" <> show (index ∷ Int) <> ".png")
              ByteString.hPut handle (encodeRgba offscreenSide offscreenSide bytes)
              hClose handle
              note journal ("readback " <> tshow index <> " is at " <> Text.pack path)
              pure (Shot Rgba8Srgb waited [(point, pixelAt bytes point) | point ← tableProbes] path)
          )
          (zip [0 ..] (zip [waited1, waited2] targets))
      roots ← atomically (readVulkanRoots (vulkanController vulkan))
      let facts =
            GrowthFacts
              (map (maybe 0 tableViewAllocated) [initial, afterFirst, afterSecond])
              (map (maybe 0 (headOr 0 . tableViewSets)) [initial, afterFirst, afterSecond])
              backpressure
              states
      note journal ("growth: " <> tshow facts)
      pure
        ( Seen
            [madeOn, firstOn, secondOn, readOn]
            ["made the table, the textures, the targets and the pipeline", "recorded a batch, then grew the table", "grew the table to its cap and drew over both growths", "read both readbacks"]
            0
            (Just roots)
            Nothing
            [waited1, waited2]
            shots
            Nothing
            Nothing
            Nothing
            (Just facts)
            Nothing
            Nothing
            Nothing
        )
  where
    deadline = either (error . show) id (durationFromNanoseconds AllowZero 30000000000)
    pixelAt bytes (x, y) = ByteString.unpack (ByteString.take 4 (ByteString.drop ((y * offscreenSide + x) * 4) bytes))
    solid = ByteString.pack . concat . replicate 4
    tableNow vulkan =
      act vulkan (VulkanAction readConstructedTable) >>= \case
        ActionReturned view → pure view
        other → stopWith ("reading the texture table did not return: " <> outcomeText other)
    headOr fallback = \case
      x : _ → x
      [] → fallback

-- | The growth case's textures' colours: red, green, blue, yellow and white.
growthColours ∷ [[Word8]]
growthColours = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255], [255, 255, 255, 255]]

-- | A table of five slots at most, two at first; five two-by-two RGBA8
-- textures; two RGBA8 color targets with a readback each; and a pipeline
-- over the table shaders, built before any growth.
growthTargets ∷ Construction q inst msgr phys dev cmd → IO (Either Refusal (TableTargets, [Image]))
growthTargets construction =
  constructTextureTable construction (either (error . show) id (validateTableConfig 5 2 (toInteger defaultVersionCount))) >>= \case
    Left refusal → pure (Left refusal)
    Right () → do
      let side = fromIntegral offscreenSide
      textures ← mapM (const (constructImage construction (ImageDescription TextureImage Rgba8Linear 2 2 1))) growthColours
      targets ← mapM (const (constructImage construction (ImageDescription ColorTarget Rgba8Srgb side side 1))) [1 ∷ Int .. 2]
      pipeline ←
        constructTablePipelineLayout construction tableShaders tableSamplerOffset >>= \case
          Left refusal → pure (Left refusal)
          Right layout → constructCheckedPipeline construction layout tableShaders (formatCode Rgba8Srgb)
      readbacks ← mapM (const (constructReadback construction offscreenBytes)) [1 ∷ Int .. 2]
      pure $ do
        made ← sequence textures
        colour ← sequence targets
        built ← pipeline
        read' ← sequence readbacks
        first ← maybe (Left (RefusedIllegal "no textures")) Right (listToMaybe made)
        pure (TableTargets first first first colour built read', made)

-- | What each growth readback's probes must read: the first texture across
-- the batch recorded before the first growth; the first texture beside the
-- fourth, registered after both growths.
expectedGrowthProbes ∷ [[[Word8]]]
expectedGrowthProbes = [[[255, 0, 0, 255], [255, 0, 0, 255]], [[255, 0, 0, 255], [255, 255, 0, 255]]]

-- | Run the commands in order, stopping at the first refusal.
inOrder ∷ [IO (Either Refusal ())] → IO (Either Refusal ())
inOrder = \case
  [] → pure (Right ())
  command : rest → command >>= either (pure . Left) (const (inOrder rest))

-- | Build a layout and a pipeline through one owner-thread action, and
-- release both through another, answering the thread each ran on and what
-- each answered.
actOnDevice ∷ VulkanHost () → IO ([ThreadId], [Text])
actOnDevice vulkan = do
  built ← act vulkan (VulkanAction building)
  (builtOn, pair) ← case built of
    ActionReturned (ran, Right pair) → pure (ran, pair)
    ActionReturned (_, Left refusal) → stopWith ("the construction was refused: " <> tshow refusal)
    other → stopWith ("the building action did not return: " <> outcomeText other)
  released ← act vulkan (VulkanAction (releasing pair))
  case released of
    ActionReturned (releasedOn, (Right (), Right ())) → pure ([builtOn, releasedOn], ["built a pipeline layout and a pipeline", "released both"])
    ActionReturned (_, answers) → stopWith ("a release was refused: " <> tshow answers)
    other → stopWith ("the releasing action did not return: " <> outcomeText other)

-- | Submit an owner-thread action and wait for its outcome.
act ∷ VulkanHost () → VulkanAction r → IO (ActionOutcome r)
act host action =
  atomically (submitVulkanAction host action) >>= \case
    Left refusal → stopWith ("an action was refused: " <> tshow refusal)
    Right ticket → atomically (awaitVulkanAction ticket)

outcomeText ∷ ActionOutcome r → Text
outcomeText = \case
  ActionReturned _ → "returned"
  ActionRaised failure → "raised " <> Text.pack (displayException failure)
  ActionRefused refusal → "refused " <> tshow refusal

-- | Build a layout and a pipeline over the verification shaders, answering the
-- thread it ran on.
building ∷ Construction q inst msgr phys dev cmd → IO (ThreadId, Either Refusal (PipelineLayout, Pipeline))
building construction = do
  ran ← myThreadId
  answer ←
    constructPipelineLayout construction >>= \case
      Left refusal → pure (Left refusal)
      Right layout → fmap ((,) layout) <$> constructPipeline construction layout verificationShaders formatB8G8R8A8Srgb
  pure (ran, answer)

-- | Release the pipeline and then its layout, answering the thread it ran on.
releasing ∷ (PipelineLayout, Pipeline) → Construction q inst msgr phys dev cmd → IO (ThreadId, (Either Refusal (), Either Refusal ()))
releasing (layout, pipeline) construction = do
  ran ← myThreadId
  released ← releaseConstructed construction pipeline
  gone ← releaseConstructed construction layout
  pure (ran, (released, gone))

-- | Run one case's production host with the device started without a
-- surface, over these windows.
runCase
  ∷ Maybe Backend
  → BudgetRequest
  → [WindowConfig]
  → Text
  → (VulkanHost () → RuntimeControl → TVar [Text] → TVar [FrameEvent] → IO Seen)
  → IO SurfaceFreeOutcome
runCase = runCaseWith id

-- | 'runCase' with the host's configuration adjusted, as the uploads case
-- configures the session's uploads.
runCaseWith
  ∷ (VulkanHostConfig () → VulkanHostConfig ())
  → Maybe Backend
  → BudgetRequest
  → [WindowConfig]
  → Text
  → (VulkanHost () → RuntimeControl → TVar [Text] → TVar [FrameEvent] → IO Seen)
  → IO SurfaceFreeOutcome
runCaseWith adjust backend request windows label body = do
  started ← getCurrentTime
  recorded ← newIORef []
  names ← newTVarIO []
  events ← newTVarIO []
  logged ← newTVarIO []
  verdictHeld ← newIORef Nothing
  partial ← newIORef Nothing
  scene ← prepare ()
  budgets ← either (stopWith . tshow) pure (validateBudgets request)
  let host = requestingBackend backend (defaultHostConfig windows)
      logger = recordingLogger (\entry → atomically (modifyTVar' logged (entry :)))
      config =
        adjust
          (vulkanHostConfig host defaultCaptureConfig {captureTextBudget = 16384} budgets scene)
            { vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
            , vulkanValidationFeatures = validationFeatures
            , vulkanObserver = \capture → naming names (nativeCallObserver recorded capture)
            , vulkanFrameObserver = \event → atomically (modifyTVar' events (event :))
            , vulkanDeviceStart = DeviceSurfaceFree
            }
  outcome ←
    try @SomeException $
      withLoaderIntegration $ \integration →
        runGraphicsOwnerApplication
          (withLoggingLifetime logger)
          label
          ( \_ use → do
              (result, verdict) ← withVulkanOwnerHost logger integration config use
              writeIORef verdictHeld (Just verdict)
              pure result
          )
          vulkanWindowHost
          (\vulkan _ → pure vulkan)
          (\vulkan control → do
              main ← myThreadId
              readiness ← awaitWithin 10 "the owner's startup" $
                readReadiness (vulkanController vulkan) >>= \case
                  RootsPending → pure Nothing
                  other → pure (Just other)
              case readiness of
                RootsFailed reason → stopWith ("the owner's startup failed: " <> reason)
                _ → pure ()
              seen ← body vulkan control names events
              running ← reverse <$> readTVarIO names
              writeIORef partial (Just (main, seen, running)))
  finished ← getCurrentTime
  verdict ← readIORef verdictHeld
  calls ← reverse <$> readIORef recorded
  entries ← readTVarIO logged
  seenEvents ← reverse <$> readTVarIO events
  let errors = [maybe "" id (Map.lookup "message" entry.entryFields) | entry ← entries, Map.lookup "severity" entry.entryFields == Just "error"]
  case outcome of
    Left failure → pure (SurfaceFreeFailed (Text.pack (displayException failure)))
    Right () →
      readIORef partial >>= \case
        Nothing → pure (SurfaceFreeFailed "the body returned without its facts")
        Just (main, seen, running) →
          pure . SurfaceFreeRecorded $
            SurfaceFreeFacts
              { factsCalls = calls
              , factsRunning = running
              , factsMainThread = main
              , factsActionThreads = seenThreads seen
              , factsActions = seenActions seen
              , factsWindows = seenWindows seen
              , factsRoots = seenRoots seen
              , factsStanding = seenStanding seen
              , factsTickets = seenTickets seen
              , factsShots = seenShots seen
              , factsEvents = seenEvents
              , factsVerdict = verdict
              , factsErrors = errors
              , factsSeconds = realToFrac (diffUTCTime finished started)
              , factsUploads = seenUploads seen
              , factsTable = seenTable seen
              , factsSprites = seenSprites seen
              , factsGrowth = seenGrowth seen
              , factsSwap = seenSwap seen
              , factsScene3d = seenScene3d seen
              , factsOrdered = seenOrdered seen
              }
  where
    -- Every call's name, as it returns, where a transaction can wait for it.
    naming names (NativeObserver observe) = NativeObserver $ \name call → do
      answer ← observe name call
      atomically (modifyTVar' names (name :))
      pure answer

-- ---------------------------------------------------------------------------
-- The records

surfaceFreeSection ∷ SurfaceFreeOutcome → [Text]
surfaceFreeSection = section "A surface-free session with no window, acting on its device"

laterWindowSection ∷ SurfaceFreeOutcome → [Text]
laterWindowSection = section "A surface-free session that admits a window later"

framelessSection ∷ SurfaceFreeOutcome → [Text]
framelessSection outcome =
  section "A surface-free session recording frame-less batches" outcome
    <> case outcome of
      SurfaceFreeRecorded facts →
        [ "- frame-less tickets waited for: " <> tshow (factsTickets facts)
        , "- submissions: " <> tshow (length (filter (== "vkQueueSubmit2") (callNames facts)))
            <> ", command buffers begun: " <> tshow (length (filter (== "vkBeginCommandBuffer") (callNames facts)))
            <> ", completions observed: " <> tshow (length [() | SubmissionCompleted _ ← factsEvents facts])
        ]
      SurfaceFreeFailed _ → []

section ∷ Text → SurfaceFreeOutcome → [Text]
section title = \case
  SurfaceFreeFailed reason → ["", "## The case did not complete", "", reason]
  SurfaceFreeRecorded facts →
    [ ""
    , "## " <> title
    , ""
    , "- windows: " <> tshow (factsWindows facts)
    , "- roots at the end of the body: " <> maybe "unread" tshow (factsRoots facts)
    , "- target standing: " <> maybe "no target" tshow (factsStanding facts)
    , "- actions: " <> Text.intercalate "; " (factsActions facts)
    , "- device calls, in order: " <> Text.intercalate ", " (filter (`elem` rootCalls) (map (.callName) (factsCalls facts)))
    , "- Vulkan calls: " <> tshow (length (vulkanCalls facts)) <> ", on " <> tshow (length (nub (map (.callHaskellThread) (vulkanCalls facts)))) <> " thread(s)"
    , "- frames presented: " <> tshow (length [() | FramePresented {} ← factsEvents facts]) <> ", presentations retired: " <> tshow (length [() | PresentationRetired _ ← factsEvents facts])
    , "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) (factsVerdict facts)
    , "- error reports: " <> tshow (length (factsErrors facts))
    , "- seconds, from the loader integration to the verdict: " <> Text.pack (show (factsSeconds facts))
    ]
  where
    rootCalls =
      [ "vkCreateInstance"
      , "vkCreateDebugUtilsMessengerEXT"
      , "vkEnumeratePhysicalDevices"
      , "vkCreateDevice"
      , "glfwCreateWindowSurface"
      , "vkGetPhysicalDeviceSurfaceSupportKHR"
      , "vkDestroySurfaceKHR"
      , "vkDestroyDevice"
      , "vkDestroyDebugUtilsMessengerEXT"
      , "vkDestroyInstance"
      ]

vulkanCalls ∷ SurfaceFreeFacts → [NativeCall]
vulkanCalls facts = [call | call ← factsCalls facts, "vk" `Text.isPrefixOf` call.callName]

-- ---------------------------------------------------------------------------
-- The examples

surfaceFreeSpec ∷ SurfaceFreeOutcome → Spec
surfaceFreeSpec outcome = describe "GRS-15 surface-free session" $ do
  it "opened no window and created no surface" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"

  it "created the device in the owner's startup, asking no surface about presentation" $
    on outcome $ \facts → do
      deviceFirst facts
      callNames facts `shouldSatisfy` notElem "vkGetPhysicalDeviceSurfaceSupportKHR"
      fmap (\roots → (viewDevice roots, viewTargets roots)) (factsRoots facts) `shouldBe` Just (RootLive, [])

  it "built and released a pipeline layout and a pipeline through owner-thread actions, on the owner's thread" $
    on outcome $ \facts → do
      factsActions facts `shouldBe` ["built a pipeline layout and a pipeline", "released both"]
      ownerThread facts $ \owner → factsActionThreads facts `shouldBe` [owner, owner]
      factsActionThreads facts `shouldSatisfy` notElem (factsMainThread facts)

  it "destroyed what it released through the owner's own progress, with no target and no frame, before the host's exit" $
    on outcome $ \facts → do
      factsRunning facts `shouldSatisfy` ordered ["vkCreatePipelineLayout", "vkCreateGraphicsPipelines", "vkDestroyPipeline", "vkDestroyPipelineLayout"]
      factsRunning facts `shouldSatisfy` notElem "vkDestroyDevice"
      factsEvents facts `shouldBe` []

  it "retired cleanly: the device, then the messenger, then the instance, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyPipelineLayout", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error" $
    on outcome clean

offscreenSection ∷ SurfaceFreeOutcome → [Text]
offscreenSection outcome =
  section "A surface-free session rendering into color targets and reading them back" outcome
    <> case outcome of
      SurfaceFreeRecorded facts →
        concat
          [ [ "- " <> tshow (shotFormat shot) <> ": ticket " <> tshow (shotTicket shot) <> ", PNG at " <> Text.pack (shotPng shot)
            , "  probes: " <> Text.intercalate "; " [tshow point <> " " <> tshow bytes | (point, bytes) ← shotProbes shot]
            ]
          | shot ← factsShots facts
          ]
      SurfaceFreeFailed _ → []

offscreenSpec ∷ SurfaceFreeOutcome → Spec
offscreenSpec outcome = describe "GRS-5 offscreen color targets in a surface-free session" $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "rendered into an RGBA8 target of each format and copied it, its batch's ticket complete, on the owner's thread" $
    on outcome $ \facts → do
      map shotFormat (factsShots facts) `shouldBe` offscreenFormats
      map shotTicket (factsShots facts) `shouldBe` replicate 2 (Right TicketComplete)
      ownerThread facts $ \owner → factsActionThreads facts `shouldBe` [owner, owner]

  it "read back exact bytes: yellow well inside the triangle, the blue clear well outside it, in both formats" $
    on outcome $ \facts →
      [map snd (shotProbes shot) | shot ← factsShots facts] `shouldBe` replicate 2 expectedProbes

  it "retired cleanly, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean

depthRectSection ∷ SurfaceFreeOutcome → [Text]
depthRectSection outcome =
  section "A surface-free session clearing a rectangle of a depth attachment inside a pass" outcome
    <> case outcome of
      SurfaceFreeRecorded facts →
        concat
          [ [ "- ticket " <> tshow (shotTicket shot) <> ", PNG at " <> Text.pack (shotPng shot)
            , "  cleared rectangle (x, y, width, height): " <> tshow depthRectCleared
            , "  probes: " <> Text.intercalate "; " [tshow point <> " " <> tshow bytes | (point, bytes) ← shotProbes shot]
            ]
          | shot ← factsShots facts
          ]
      SurfaceFreeFailed _ → []

depthRectSpec ∷ SurfaceFreeOutcome → Spec
depthRectSpec outcome = describe "R2D-17 clearing depth within a rectangle in a surface-free session" $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "cleared the rectangle with vkCmdClearAttachments and drew in one frame-less batch whose ticket completed, on the owner's thread" $
    on outcome $ \facts → do
      factsRunning facts `shouldSatisfy` ordered ["vkCreatePipelineLayout", "vkCreateGraphicsPipelines", "vkBeginCommandBuffer", "vkQueueSubmit2"]
      map shotTicket (factsShots facts) `shouldBe` [Right TicketComplete]
      ownerThread facts $ \owner → factsActionThreads facts `shouldBe` [owner, owner]

  it "read back exact bytes: the quad's magenta exactly inside the rectangle and the pass's blue clear exactly outside it, on both sides of each edge" $
    on outcome $ \facts →
      [probes shot | shot ← factsShots facts] `shouldBe` [map snd depthRectProbes]

  it "retired cleanly, the ring with every other managed resource before the device, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean
  where
    probes = map snd . shotProbes

drawingSection ∷ SurfaceFreeOutcome → [Text]
drawingSection outcome =
  section "A surface-free session drawing an indexed, instanced quad from its shared ring with a pushed color" outcome
    <> case outcome of
      SurfaceFreeRecorded facts →
        concat
          [ [ "- ticket " <> tshow (shotTicket shot) <> ", PNG at " <> Text.pack (shotPng shot)
            , "  probes: " <> Text.intercalate "; " [tshow point <> " " <> tshow bytes | (point, bytes) ← shotProbes shot]
            ]
          | shot ← factsShots facts
          ]
      SurfaceFreeFailed _ → []

drawingSpec ∷ SurfaceFreeOutcome → Spec
drawingSpec outcome = describe "GRS-4 drawing from the shared ring with push constants in a surface-free session" $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "made a layout with a push-constant range and a pipeline with vertex input, and drew in one frame-less batch whose ticket completed, on the owner's thread" $
    on outcome $ \facts → do
      factsRunning facts `shouldSatisfy` ordered ["vkCreatePipelineLayout", "vkCreateGraphicsPipelines", "vkBeginCommandBuffer", "vkQueueSubmit2"]
      map shotTicket (factsShots facts) `shouldBe` [Right TicketComplete]
      ownerThread facts $ \owner → factsActionThreads facts `shouldBe` [owner, owner]

  it "read back exact bytes: the pushed magenta inside each instance's quad, the blue clear outside both" $
    on outcome $ \facts →
      [map snd (shotProbes shot) | shot ← factsShots facts] `shouldBe` [expectedDrawingProbes]

  it "retired cleanly, the ring with every other managed resource before the device, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean

uploadsSection ∷ SurfaceFreeOutcome → [Text]
uploadsSection outcome =
  section "A surface-free session uploading textures and buffers through bounded staging" outcome
    <> case outcome of
      SurfaceFreeRecorded facts →
        concat
          [ [ "- upload tickets: " <> tshow (maybe [] uploadTickets (factsUploads facts))
            , "- RGBA8 levels read back exactly: " <> tshow (maybe [] uploadRgbaLevels (factsUploads facts))
            , "- BC7 levels read back exactly: " <> maybe "BC7 is not supported by the device, as it reports" tshow (factsUploads facts >>= uploadBc7Levels)
            , "- submissions: " <> tshow (length (filter (== "vkQueueSubmit2") (callNames facts)))
            ]
          , concat
              [ [ "- drawing ticket " <> tshow (shotTicket shot) <> ", PNG at " <> Text.pack (shotPng shot)
                , "  probes: " <> Text.intercalate "; " [tshow point <> " " <> tshow bytes | (point, bytes) ← shotProbes shot]
                ]
              | shot ← factsShots facts
              ]
          ]
      SurfaceFreeFailed _ → []

uploadsSpec ∷ SurfaceFreeOutcome → Spec
uploadsSpec outcome = describe "GRS-6 uploads through bounded staging in a surface-free session" $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "completed every upload, admitted and waited for with a deadline off the owner's thread, the RGBA8 texture over more than one turn's budget" $
    on outcome $ \facts → do
      fmap uploadTickets (factsUploads facts) `shouldSatisfy` maybe False (\tickets → not (null tickets) && all (== Right UploadComplete) tickets)
      -- The RGBA8 texture's 320 KiB need three turns of 128 KiB, each its own
      -- submission; the verifying batch is one more.
      length (filter (== "vkQueueSubmit2") (callNames facts)) `shouldSatisfy` (>= rgbaTurns + 1)

  it "copied every RGBA8 level back exactly as uploaded" $
    on outcome $ \facts → fmap uploadRgbaLevels (factsUploads facts) `shouldBe` Just [True, True]

  it "copied every BC7 level back block for block where the device takes BC7, and reported it unsupported where it does not" $
    on outcome $ \facts → (factsUploads facts >>= uploadBc7Levels) `shouldSatisfy` maybe True and

  it "drew from the uploaded vertex, offset and index buffers: magenta inside each instance's quad, the blue clear outside both" $
    on outcome $ \facts → do
      map shotTicket (factsShots facts) `shouldBe` [Right TicketComplete]
      [map snd (shotProbes shot) | shot ← factsShots facts] `shouldBe` [expectedDrawingProbes]

  it "retired cleanly, the staging buffer with every other managed resource before the device, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean

tableSection ∷ SurfaceFreeOutcome → [Text]
tableSection outcome =
  section "A surface-free session sampling textures through the bindless texture table" outcome
    <> case outcome of
      SurfaceFreeRecorded facts →
        concat
          [ ["- table: " <> maybe "no facts" tshow (factsTable facts)]
          , [ "- " <> tshow (map snd (shotProbes shot)) <> ", ticket " <> tshow (shotTicket shot) <> ", PNG at " <> Text.pack (shotPng shot)
            | shot ← factsShots facts
            ]
          ]
      SurfaceFreeFailed _ → []

tableSpec ∷ SurfaceFreeOutcome → Spec
tableSpec outcome = describe "GRS-7 the bindless texture table in a surface-free session" $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "made the table's four samplers, two set layouts, two pools and two sets, wrote its descriptors, and drew in four frame-less batches whose tickets completed, on the owner's thread" $
    on outcome $ \facts → do
      length (filter (== "vkCreateSampler") (callNames facts)) `shouldBe` 4
      length (filter (== "vkCreateDescriptorSetLayout") (callNames facts)) `shouldBe` 2
      length (filter (== "vkCreateDescriptorPool") (callNames facts)) `shouldBe` 2
      length (filter (== "vkAllocateDescriptorSets") (callNames facts)) `shouldBe` 2
      factsRunning facts `shouldSatisfy` ordered ["vkCreateSampler", "vkCreateDescriptorSetLayout", "vkCreateDescriptorPool", "vkAllocateDescriptorSets", "vkUpdateDescriptorSets", "vkCreatePipelineLayout", "vkCreateGraphicsPipelines"]
      map shotTicket (factsShots facts) `shouldBe` replicate 4 (Right TicketComplete)
      fmap tableTickets (factsTable facts) `shouldBe` Just (replicate 3 (Right UploadComplete))
      ownerThread facts $ \owner → factsActionThreads facts `shouldBe` replicate 6 owner

  it "drew the transparent placeholder through a handle whose texture had not uploaded, and each uploaded texture through its own handle and sampler" $
    on outcome $ \facts →
      take 2 [map snd (shotProbes shot) | shot ← factsShots facts] `shouldBe` take 2 expectedTableProbes

  it "drew the released texture in a batch recorded before its release and submitted after it, gave the next texture another slot, and let the slot go once that batch completed" $
    on outcome $ \facts → do
      drop 2 [map snd (shotProbes shot) | shot ← factsShots facts] `shouldBe` drop 2 expectedTableProbes
      case factsTable facts of
        Nothing → expectationFailure "no table facts"
        Just table → do
          tableReplacedSlot table `shouldSatisfy` maybe False (/= 0)
          tableReplacementSlot table `shouldSatisfy` maybe False (/= 0)
          tableReplacementSlot table `shouldSatisfy` (/= tableReplacedSlot table)
          Just (tableRetiringAtRelease table) `shouldBe` fmap pure (tableReplacedSlot table)
          tableRetiringAtEnd table `shouldBe` []
          tableStaleRelease table `shouldSatisfy` either isStale (const False)

  it "retired cleanly, the table's pools, set layouts and samplers before the device, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyDescriptorPool", "vkDestroyDescriptorSetLayout", "vkDestroySampler", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean
  where
    isStale = \case
      RefusedStaleHandle _ → True
      _ → False

shaderSamplersSection ∷ SurfaceFreeOutcome → [Text]
shaderSamplersSection outcome =
  section "A surface-free session drawing instances through a shader-sampled table layout" outcome
    <> case outcome of
      SurfaceFreeRecorded facts →
        concat
          [ ["- upload: " <> maybe "no facts" (tshow . tableTickets) (factsTable facts)]
          , [ "- " <> tshow (zip (map fst (shotProbes shot)) (map snd (shotProbes shot))) <> ", ticket " <> tshow (shotTicket shot) <> ", PNG at " <> Text.pack (shotPng shot)
            | shot ← factsShots facts
            ]
          ]
      SurfaceFreeFailed _ → []

shaderSamplersSpec ∷ SurfaceFreeOutcome → Spec
shaderSamplersSpec outcome = describe "R2D-16 shader-chosen samplers in a surface-free session" $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "made the table, a pipeline layout holding its two set layouts and no push-constant range, and drew in one batch whose ticket completed, on the owner's thread" $
    on outcome $ \facts → do
      length (filter (== "vkCreateSampler") (callNames facts)) `shouldBe` 4
      length (filter (== "vkCreatePipelineLayout") (callNames facts)) `shouldBe` 1
      factsRunning facts `shouldSatisfy` ordered ["vkCreateSampler", "vkCreateDescriptorSetLayout", "vkCreateDescriptorPool", "vkAllocateDescriptorSets", "vkUpdateDescriptorSets", "vkCreatePipelineLayout", "vkCreateGraphicsPipelines"]
      map shotTicket (factsShots facts) `shouldBe` [Right TicketComplete]
      fmap tableTickets (factsTable facts) `shouldBe` Just [Right UploadComplete]
      ownerThread facts $ \owner → factsActionThreads facts `shouldBe` replicate 3 owner

  it "drew, in one call with no selected sampler, the nearest instance's texel exactly and the linear one's blend within one step, so the two differ, and an index of 7 as sampler 3" $
    on outcome $ \facts → case [map snd (shotProbes shot) | shot ← factsShots facts] of
      [[nearest, linear, seven, three, clamped]] → do
        nearest `shouldBe` (expectedShaderSamplerProbes !! 0)
        withinOne linear (expectedShaderSamplerProbes !! 1)
        withinOne seven (expectedShaderSamplerProbes !! 2)
        withinOne three (expectedShaderSamplerProbes !! 3)
        withinOne clamped (expectedShaderSamplerProbes !! 4)
        -- The two filters read different bytes at the same offset.
        linear `shouldSatisfy` (/= nearest)
        -- Index 7 reads as sampler 3, the repeating one, not as 2: at the
        -- left edge the red channels differ by far more than a step.
        abs (fromIntegral (seven !! 0) - fromIntegral (clamped !! 0) ∷ Int) `shouldSatisfy` (> 8)
      other → expectationFailure ("expected one readback of five probes, got " <> show other)

  it "retired cleanly, the table's pools, set layouts and samplers before the device, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyDescriptorPool", "vkDestroyDescriptorSetLayout", "vkDestroySampler", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean
  where
    withinOne actual expected =
      (zipWith (\a b → abs (fromIntegral a - fromIntegral b ∷ Int)) actual expected) `shouldSatisfy` all (<= 1)

storageTablesSection ∷ SurfaceFreeOutcome → [Text]
storageTablesSection outcome =
  section "A surface-free session binding per-batch storage tables from the ring" outcome
    <> case outcome of
      SurfaceFreeRecorded facts →
        [ "- " <> tshow (zip (map fst (shotProbes shot)) (map snd (shotProbes shot))) <> ", ticket " <> tshow (shotTicket shot) <> ", PNG at " <> Text.pack (shotPng shot)
        | shot ← factsShots facts
        ]
      SurfaceFreeFailed _ → []

storageTablesSpec ∷ SurfaceFreeOutcome → Spec
storageTablesSpec outcome = describe "R2D-15 per-batch storage tables in a surface-free session" $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "made the ring a window longer, set 2's layout, pool and set, and a pipeline layout holding the table's two sets and set 2, and drew in one batch whose ticket completed, on the owner's thread" $
    on outcome $ \facts → do
      -- The table's two set layouts and pools, and set 2's.
      length (filter (== "vkCreateDescriptorSetLayout") (callNames facts)) `shouldBe` 3
      length (filter (== "vkCreateDescriptorPool") (callNames facts)) `shouldBe` 3
      length (filter (== "vkCreatePipelineLayout") (callNames facts)) `shouldBe` 1
      factsRunning facts `shouldSatisfy` ordered ["vkCreateSampler", "vkCreateDescriptorSetLayout", "vkCreateDescriptorPool", "vkAllocateDescriptorSets", "vkUpdateDescriptorSets", "vkCreateDescriptorSetLayout", "vkCreateDescriptorPool", "vkAllocateDescriptorSets", "vkUpdateDescriptorSets", "vkCreatePipelineLayout", "vkCreateGraphicsPipelines"]
      map shotTicket (factsShots facts) `shouldBe` [Right TicketComplete]
      ownerThread facts $ \owner → factsActionThreads facts `shouldBe` replicate 3 owner

  it "bound each table at its own dynamic offset and drew twice, each draw showing its own table's colour exactly" $
    on outcome $ \facts → case [map snd (shotProbes shot) | shot ← factsShots facts] of
      [[left, right]] → do
        left `shouldBe` (expectedStorageTableProbes !! 0)
        right `shouldBe` (expectedStorageTableProbes !! 1)
        left `shouldSatisfy` (/= right)
      other → expectationFailure ("expected one readback of two probes, got " <> show other)

  it "retired cleanly, the table's pools, set layouts and samplers before the device, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyDescriptorPool", "vkDestroyDescriptorSetLayout", "vkDestroySampler", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean

spritesSection ∷ SurfaceFreeOutcome → [Text]
spritesSection outcome =
  section "A surface-free session drawing the sprites sample's evidence scene" outcome
    <> case outcome of
      SurfaceFreeRecorded facts → case factsSprites facts of
        Nothing → ["- no sprites evidence"]
        Just evidence →
          [ "- capture: " <> maybe "not written" Text.pack (evidencePng evidence) <> "; probe record: " <> Text.pack (evidenceRecord evidence)
          , "- BC7: " <> maybe "not reached" (\drawn → if drawn then "supported and drawn" else "not supported by the device, as it reports; skipped") (evidenceBc7 evidence)
          , "- readback bytes: " <> tshow (evidenceReadback evidence)
          , "- failure: " <> fromMaybe "none" (evidenceFailure evidence)
          ]
            <> [ "- " <> (if resultPassed result then "pass " else "FAIL ") <> probeName (resultProbe result) <> ": observed " <> tshow (resultObserved result) <> ", expected " <> tshow (resultExpected result)
               | result ← evidenceProbes evidence
               ]
      SurfaceFreeFailed _ → []

spritesSpec ∷ SurfaceFreeOutcome → Spec
spritesSpec outcome = describe "GRS-8 the sprites sample's window-free evidence" $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "rendered the scene and read back the whole target once its batch had completed, every probe passing the independent oracle — the BC7 fixture's only where the device takes BC7" $
    on outcome $ \facts → case factsSprites facts of
      Nothing → expectationFailure "no sprites evidence"
      Just evidence → do
        evidenceFailure evidence `shouldBe` Nothing
        evidenceReadback evidence `shouldBe` fromIntegral spritesTargetBytes
        [probeName (resultProbe result) | result ← evidenceProbes evidence, not (resultPassed result)] `shouldBe` []
        evidenceProbes evidence `shouldSatisfy` (not . null)
        evidencePassed evidence `shouldBe` True

  it "wrote the lossless PNG and the probe record where they are kept" $
    on outcome $ \facts → case factsSprites facts of
      Nothing → expectationFailure "no sprites evidence"
      Just evidence → do
        png ← maybe (pure False) doesFileExist (evidencePng evidence)
        record ← doesFileExist (evidenceRecord evidence)
        (png, record) `shouldBe` (True, True)

  it "retired cleanly, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean

orderedPathSection ∷ SurfaceFreeOutcome → [Text]
orderedPathSection = evidenceSection "A surface-free session recording the ordered path's evidence fixtures" "ordered path"

cutoutDepthSection ∷ SurfaceFreeOutcome → [Text]
cutoutDepthSection = evidenceSection "A surface-free session recording the cutout path's evidence fixtures over a D32_SFLOAT depth image" "cutout depth"

-- | The report of an evidence case: its probe record, the depth format, why it
-- rendered nothing if it did not, and each fixture with its named behaviours.
evidenceSection ∷ Text → Text → SurfaceFreeOutcome → [Text]
evidenceSection title label outcome =
  section title outcome
    <> case outcome of
      SurfaceFreeRecorded facts → case factsOrdered facts of
        Nothing → ["- no " <> label <> " evidence"]
        Just evidence →
          [ "- probe record: " <> Text.pack (OrderedPath.evidenceRecord evidence)
          , "- failure: " <> fromMaybe "none" (OrderedPath.evidenceFailure evidence)
          ]
            <> [ "- depth format: " <> tshow depth | depth ← maybe [] pure (OrderedPath.evidenceDepthFormat evidence)]
            <> [ "- unavailable: " <> why | why ← maybe [] pure (OrderedPath.evidenceUnavailable evidence)]
            <> concat
              [ [ "- " <> OrderedPath.resultFixture result <> ": "
                    <> (if OrderedPath.fixturePassed result then "pass" else "FAIL")
                    <> ", " <> tshow (length (OrderedPath.resultProbes result)) <> " probes, "
                    <> tshow (length [() | probed ← OrderedPath.resultProbes result, OrderedPath.isDeterminate probed]) <> " determinate"
                ]
                  <> [ "    - " <> (if OrderedPath.namedDistinguishes named && OrderedPath.verdictPasses (OrderedPath.namedVerdict named) then "pass " else "FAIL ") <> OrderedPath.namedName named
                     | named ← OrderedPath.resultNamed result
                     ]
              | result ← OrderedPath.evidenceFixtures evidence
              ]
      SurfaceFreeFailed _ → []

retainedSection ∷ SurfaceFreeOutcome → [Text]
retainedSection = evidenceSection "A surface-free session recording retained chunks over several frames over a D32_SFLOAT depth image" "retained"

orderedPathSpec ∷ SurfaceFreeOutcome → Spec
orderedPathSpec = evidenceSpec "R2D-7 the ordered path's window-free evidence" "ordered path" 10 True

cutoutDepthSpec ∷ SurfaceFreeOutcome → Spec
cutoutDepthSpec = evidenceSpec "R2D-9 the cutout path's window-free evidence" "cutout depth" 7 True

retainedSpec ∷ SurfaceFreeOutcome → Spec
retainedSpec = evidenceSpec "R2D-10 the retained chunks' window-free evidence" "retained" 11 True

-- | The examples of an evidence case: no window, every fixture rendered and
-- read back after its batch completed, every determinate probe within its
-- tolerance and every named behaviour distinguished from its contrast, the
-- files kept, and a clean retirement. A case that needs depth is satisfied by
-- reporting where @D32_SFLOAT@ is unavailable, with the recorder's refusal
-- checked, and is otherwise satisfied only by a @D32_SFLOAT@ image.
evidenceSpec ∷ Text → Text → Int → Bool → SurfaceFreeOutcome → Spec
evidenceSpec title label minimumFixtures needsDepth outcome = describe (Text.unpack title) $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "rendered every fixture and read back every target once its batch had completed, every determinate probe within its tolerance and every named behaviour distinguished from its contrast, or reports where D32_SFLOAT is unavailable" $
    on outcome $ \facts → case factsOrdered facts of
      Nothing → expectationFailure ("no " <> Text.unpack label <> " evidence")
      Just evidence → do
        OrderedPath.evidenceFailure evidence `shouldBe` Nothing
        OrderedPath.evidencePassed evidence `shouldBe` True
        case OrderedPath.evidenceUnavailable evidence of
          Just _ | needsDepth → do
            map OrderedPath.resultFixture (OrderedPath.evidenceFixtures evidence) `shouldBe` []
            OrderedPath.evidenceDepthFormat evidence `shouldSatisfy` (/= Just Depth32Float)
          _ → do
            [OrderedPath.resultFixture result | result ← OrderedPath.evidenceFixtures evidence, not (OrderedPath.fixturePassed result)] `shouldBe` []
            length (OrderedPath.evidenceFixtures evidence) `shouldSatisfy` (>= minimumFixtures)
            when needsDepth $ OrderedPath.evidenceDepthFormat evidence `shouldBe` Just Depth32Float

  it "wrote a lossless PNG for every target and the probe record where they are kept" $
    on outcome $ \facts → case factsOrdered facts of
      Nothing → expectationFailure ("no " <> Text.unpack label <> " evidence")
      Just evidence → do
        record ← doesFileExist (OrderedPath.evidenceRecord evidence)
        pngs ← traverse (maybe (pure False) doesFileExist . OrderedPath.targetPng) [target | result ← OrderedPath.evidenceFixtures evidence, target ← OrderedPath.resultTargets result]
        (record, and pngs, not (null pngs) || isJust (OrderedPath.evidenceUnavailable evidence)) `shouldBe` (True, True, True)

  it "retired cleanly, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean

swapSection ∷ SurfaceFreeOutcome → [Text]
swapSection outcome =
  section "A surface-free session swapping the sprites sample's atlas under its handle" outcome
    <> case outcome of
      SurfaceFreeRecorded facts → case factsSwap facts of
        Nothing → ["- no swap evidence"]
        Just evidence →
          [ "- captures: " <> Text.intercalate ", " (map Text.pack (swapPngs evidence)) <> "; record: " <> Text.pack (swapRecord evidence)
          , "- BC7: " <> maybe "not reached" (\drawn → if drawn then "supported and drawn" else "not supported by the device, as it reports; skipped") (swapBc7 evidence)
          , "- facts: " <> maybe "none" tshow (swapFacts evidence)
          , "- failure: " <> fromMaybe "none" (swapFailure evidence)
          ]
            <> [ "- " <> name <> " " <> (if resultPassed result then "pass " else "FAIL ") <> probeName (resultProbe result) <> ": observed " <> tshow (resultObserved result) <> ", expected " <> tshow (resultExpected result)
               | (name, results) ← [("before", swapBefore evidence), ("delayed", swapDelayed evidence), ("after", swapAfter evidence)]
               , result ← results
               ]
      SurfaceFreeFailed _ → []

swapSpec ∷ SurfaceFreeOutcome → Spec
swapSpec outcome = describe "GRS-9 a texture swap under a stable handle, in the sprites sample's window-free evidence" $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "sampled the atlas in the frame before the swap and in the frame recorded before it and submitted after it, and the replacement in the frame after it, every probe passing the independent oracle" $
    on outcome $ \facts → withSwap facts $ \evidence → do
      swapFailure evidence `shouldBe` Nothing
      [(name, probeName (resultProbe result)) | (name, results) ← [("before", swapBefore evidence), ("delayed", swapDelayed evidence), ("after", swapAfter evidence)], result ← results, not (resultPassed result)] `shouldBe` ([] ∷ [(Text, Text)])
      map length [swapBefore evidence, swapDelayed evidence, swapAfter evidence] `shouldSatisfy` all (> 0)

  it "drew the same instance data before and after the swap, which took effect, in a slot of the replacement's own" $
    on outcome $ \facts → withSwap facts $ \evidence → case swapFacts evidence of
      Nothing → expectationFailure "no swap facts"
      Just held → do
        factsInstancesUnchanged held `shouldBe` True
        factsSwapState held `shouldBe` SwapPublished
        factsNewSlot held `shouldSatisfy` (`notElem` [0, factsOldSlot held])

  it "kept the atlas's slot retiring, and gave it to no texture, while the delayed frame held it, and reused it only once that frame completed" $
    on outcome $ \facts → withSwap facts $ \evidence → case swapFacts evidence of
      Nothing → expectationFailure "no swap facts"
      Just held → do
        factsRetiringDuringDelay held `shouldSatisfy` elem (factsOldSlot held)
        factsSlotDuringDelay held `shouldSatisfy` (`notElem` [0, factsOldSlot held])
        factsSlotAfterCompletion held `shouldBe` factsOldSlot held
        swapPassed evidence `shouldBe` True

  it "wrote the before, delayed and after PNGs and the record where they are kept" $
    on outcome $ \facts → withSwap facts $ \evidence → do
      pngs ← mapM doesFileExist (swapPngs evidence)
      record ← doesFileExist (swapRecord evidence)
      (pngs, record) `shouldBe` ([True, True, True], True)

  it "retired cleanly, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean
  where
    withSwap facts body = maybe (expectationFailure "no swap evidence") body (factsSwap facts)

growthSection ∷ SurfaceFreeOutcome → [Text]
growthSection outcome =
  section "A surface-free session growing its texture table" outcome
    <> case outcome of
      SurfaceFreeRecorded facts →
        ["- growth: " <> maybe "no facts" tshow (factsGrowth facts)]
          <> [ "- " <> tshow (map snd (shotProbes shot)) <> ", ticket " <> tshow (shotTicket shot) <> ", PNG at " <> Text.pack (shotPng shot)
             | shot ← factsShots facts
             ]
      SurfaceFreeFailed _ → []

growthSpec ∷ SurfaceFreeOutcome → Spec
growthSpec outcome = describe "GRS-14 texture table growth in a surface-free session" $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "grew set 0 twice, from two slots to four to the cap of five, each time into a new set from a pool of its own, and answered backpressure at the cap" $
    on outcome $ \facts → case factsGrowth facts of
      Nothing → expectationFailure "no growth facts"
      Just growth → do
        growthAllocated growth `shouldBe` [2, 4, 5]
        length (nub (growthSets growth)) `shouldBe` 3
        growthBackpressure growth `shouldBe` Left (RefusedBackpressure TextureSlotBudget)
        growthTickets growth `shouldBe` replicate 5 (Right UploadComplete)
        length (filter (== "vkCreateDescriptorPool") (callNames facts)) `shouldBe` 4
        length (filter (== "vkAllocateDescriptorSets") (callNames facts)) `shouldBe` 4

  it "sampled the first texture in a batch recorded before a growth and submitted after it, and textures registered before and after growth with a pipeline built before it" $
    on outcome $ \facts → do
      map shotTicket (factsShots facts) `shouldBe` replicate 2 (Right TicketComplete)
      [map snd (shotProbes shot) | shot ← factsShots facts] `shouldBe` expectedGrowthProbes
      length (filter (== "vkCreateGraphicsPipelines") (callNames facts)) `shouldBe` 1

  it "retired cleanly, every set's pool before the device, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyDescriptorPool", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean

scene3dSection ∷ SurfaceFreeOutcome → [Text]
scene3dSection outcome =
  section "A surface-free session drawing the scene3d sample's two cubes with a depth test" outcome
    <> case outcome of
      SurfaceFreeRecorded facts → case factsScene3d facts of
        Nothing → ["- no scene3d evidence"]
        Just evidence →
          ["- depth format: " <> maybe "not chosen" tshow (Scene3dEvidence.evidenceDepthFormat evidence), "- probe record: " <> Text.pack (Scene3dEvidence.evidenceRecord evidence), "- failure: " <> fromMaybe "none" (Scene3dEvidence.evidenceFailure evidence)]
            <> concat
              [ [ "- " <> tshow (Scene3dEvidence.poseEvidenceName pose) <> " capture: " <> maybe "not written" Text.pack (Scene3dEvidence.poseEvidencePng pose)
                , "- " <> tshow (Scene3dEvidence.poseEvidenceName pose) <> " readback bytes: " <> tshow (Scene3dEvidence.poseEvidenceBytes pose)
                ]
                  <> [ "- " <> tshow (Scene3dEvidence.poseEvidenceName pose) <> " " <> (if Scene3dOracle.resultPassed result then "pass " else "FAIL ") <> Scene3dScene.probeName (Scene3dOracle.resultProbe result) <> ": observed " <> tshow (Scene3dOracle.resultObserved result) <> ", expected " <> tshow (Scene3dOracle.resultExpected result) <> ", covered by " <> tshow (Scene3dOracle.resultCovered result)
                     | result ← Scene3dEvidence.poseEvidenceProbes pose
                     ]
              | pose ← Scene3dEvidence.evidencePoses evidence
              ]
      SurfaceFreeFailed _ → []

scene3dSpec ∷ SurfaceFreeOutcome → Spec
scene3dSpec outcome = describe "GRS-10 the scene3d sample's window-free evidence" $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "chose a depth-only format, rendered both poses and read back each whole once its batch had completed, every probe passing the independent oracle" $
    on outcome $ \facts → withScene3d facts $ \evidence → do
      Scene3dEvidence.evidenceFailure evidence `shouldBe` Nothing
      Scene3dEvidence.evidenceDepthFormat evidence `shouldSatisfy` maybe False (`elem` depthFormatPreference)
      map Scene3dEvidence.poseEvidenceName (Scene3dEvidence.evidencePoses evidence) `shouldBe` [Scene3dScene.FrontPose, Scene3dScene.SidePose]
      map Scene3dEvidence.poseEvidenceBytes (Scene3dEvidence.evidencePoses evidence) `shouldBe` replicate 2 (fromIntegral Scene3dScene.targetBytes)
      [(Scene3dEvidence.poseEvidenceName pose, Scene3dScene.probeName (Scene3dOracle.resultProbe result)) | pose ← Scene3dEvidence.evidencePoses evidence, result ← Scene3dEvidence.poseEvidenceProbes pose, not (Scene3dOracle.resultPassed result)] `shouldBe` []
      map (length . Scene3dEvidence.poseEvidenceProbes) (Scene3dEvidence.evidencePoses evidence) `shouldSatisfy` all (> 0)
      Scene3dEvidence.evidencePassed evidence `shouldBe` True

  it "showed the nearer cube, drawn first, where the cubes overlap in each pose, so depth testing and not draw order decided the pixel, and showed that the camera moved" $
    on outcome $ \facts → withScene3d facts $ \evidence →
      forM_' [Scene3dScene.Occlusion, Scene3dScene.CameraMovedFace, Scene3dScene.CameraMovedPlace, Scene3dScene.FaceColour, Scene3dScene.Clear] $ \purpose → do
        let results = [result | pose ← Scene3dEvidence.evidencePoses evidence, result ← Scene3dEvidence.poseEvidenceProbes pose, Scene3dScene.probePurpose (Scene3dOracle.resultProbe result) == purpose]
        results `shouldSatisfy` (not . null)
        all Scene3dOracle.resultPassed results `shouldBe` True
        when (purpose == Scene3dScene.Occlusion) $
          [Scene3dOracle.resultCovered result | result ← results] `shouldBe` replicate (length results) [Scene3dScene.NearCube, Scene3dScene.FarCube]

  it "wrote a lossless PNG a pose and the probe record where they are kept" $
    on outcome $ \facts → withScene3d facts $ \evidence → do
      pngs ← mapM (maybe (pure False) doesFileExist . Scene3dEvidence.poseEvidencePng) (Scene3dEvidence.evidencePoses evidence)
      record ← doesFileExist (Scene3dEvidence.evidenceRecord evidence)
      (pngs, record) `shouldBe` ([True, True], True)

  it "retired cleanly, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean
  where
    withScene3d facts body = maybe (expectationFailure "no scene3d evidence") body (factsScene3d facts)
    forM_' items action = mapM_ action items

framelessSpec ∷ SurfaceFreeOutcome → Spec
framelessSpec outcome = describe "GRS-12 frame-less batches in a surface-free session" $ do
  it "opened no window, created no surface and acquired no image" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"
      callNames facts `shouldSatisfy` notElem "vkAcquireNextImageKHR"
      deviceFirst facts

  it "recorded both frame-less batches through owner-thread actions on the owner's thread, each begun and ended in a frame-less slot's own command buffer" $
    on outcome $ \facts → do
      ownerThread facts $ \owner → factsActionThreads facts `shouldBe` [owner, owner]
      -- Recorded commands are not observed one by one; their barriers are the
      -- headless examples', and their synchronization the verdict's.
      length (filter (== "vkBeginCommandBuffer") (callNames facts)) `shouldBe` 2
      length (filter (== "vkEndCommandBuffer") (callNames facts)) `shouldBe` 2

  it "submitted each batch by itself when its action returned, and completed both tickets on their fences, waited for with a deadline off the owner's thread" $
    on outcome $ \facts → do
      factsRunning facts `shouldSatisfy` ordered ["vkQueueSubmit2", "vkQueueSubmit2"]
      factsTickets facts `shouldBe` [Right TicketComplete, Right TicketComplete]
      length [() | SubmissionCompleted _ ← factsEvents facts] `shouldBe` 2

  it "retired cleanly: the frame-less fences before the device, then the messenger, then the instance, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyFence", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome clean

laterWindowSpec ∷ SurfaceFreeOutcome → Spec
laterWindowSpec outcome = describe "GRS-15 surface-free session with a later window" $ do
  it "created the device with no surface before the window's surface existed" $
    on outcome $ \facts → do
      deviceFirst facts
      callNames facts `shouldSatisfy` ordered ["vkCreateDevice", "glfwCreateWindowSurface", "vkGetPhysicalDeviceSurfaceSupportKHR"]

  it "admitted the window against the device's queue family, with one device" $
    on outcome $ \facts → do
      factsStanding facts `shouldBe` Just TargetUsable
      length (filter (== "vkCreateDevice") (callNames facts)) `shouldBe` 1

  it "presented a frame to it and saw that presentation retire on its own present fence" $
    on outcome $ \facts → do
      let presented = [presentation | FramePresented _ _ presentation _ ← factsEvents facts]
          retired = [presentation | PresentationRetired presentation ← factsEvents facts]
      presented `shouldSatisfy` (not . null)
      presented `shouldSatisfy` any (`elem` retired)

  it "retired the surface, then the device, then the messenger, then the instance, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroySurfaceKHR", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error" $
    on outcome clean

-- ---------------------------------------------------------------------------
-- Helpers

on ∷ SurfaceFreeOutcome → (SurfaceFreeFacts → Expectation) → Expectation
on = \case
  SurfaceFreeFailed reason → const (expectationFailure (Text.unpack reason))
  SurfaceFreeRecorded facts → ($ facts)

callNames ∷ SurfaceFreeFacts → [Text]
callNames facts = map (.callName) (factsCalls facts)

-- | The device was enumerated and created right after the instance and its
-- messenger, before anything else native.
deviceFirst ∷ SurfaceFreeFacts → Expectation
deviceFirst facts =
  take 4 [name | name ← callNames facts, name `notElem` ["vkEnumerateInstanceExtensionProperties"]]
    `shouldBe` ["vkCreateInstance", "vkCreateDebugUtilsMessengerEXT", "vkEnumeratePhysicalDevices", "vkCreateDevice"]

-- | The thread the device was created on.
ownerThread ∷ SurfaceFreeFacts → (ThreadId → Expectation) → Expectation
ownerThread facts check' = case [call.callHaskellThread | call ← factsCalls facts, call.callName == "vkCreateDevice"] of
  [owner] → check' owner
  other → expectationFailure ("expected one device creation, but " <> show (length other))

oneOwnerThread ∷ SurfaceFreeFacts → Expectation
oneOwnerThread facts = do
  let threads = nub (map (.callHaskellThread) (vulkanCalls facts))
  length threads `shouldBe` 1
  threads `shouldSatisfy` notElem (factsMainThread facts)

clean ∷ SurfaceFreeFacts → Expectation
clean facts = do
  fmap verdictIssues (factsVerdict facts) `shouldBe` Just []
  factsErrors facts `shouldBe` []

-- | Whether these names occur in this order among the calls.
ordered ∷ [Text] → [Text] → Bool
ordered wanted calls = go wanted calls
  where
    go [] _ = True
    go (first : rest) remaining = case elemIndex first remaining of
      Nothing → False
      Just at → go rest (drop (at + 1) remaining)

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

-- | Wait for the transaction to answer something, for at most this many
-- seconds.
awaitWithin ∷ Double → Text → STM (Maybe a) → IO a
awaitWithin seconds what transaction = do
  expired ← registerDelay (round (seconds * 1000000))
  atomically ((transaction >>= maybe retry (pure . Just)) `orElse` (Nothing <$ (readTVar expired >>= check)))
    >>= maybe (stopWith (what <> " did not happen within " <> tshow seconds <> " seconds")) pure

recordingLogger ∷ (LogEntry → IO ()) → Logger
recordingLogger keep =
  mkLogger
    LogFilter
      { filterEnabled = True
      , filterGlobalLevel = Info
      , filterComponentLevels = Map.empty
      , filterDebug = DebugAll
      , filterSource = False
      }
    (callbackSink keep)

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show

spritesTargetBytes ∷ Natural
spritesTargetBytes = Sprites.targetBytes
