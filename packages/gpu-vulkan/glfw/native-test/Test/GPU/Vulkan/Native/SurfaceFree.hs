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
  , surfaceFreeSection
  , laterWindowSection
  , framelessSection
  , offscreenSection
  , drawingSection
  , uploadsSection
  , surfaceFreeSpec
  , laterWindowSpec
  , framelessSpec
  , offscreenSpec
  , drawingSpec
  , uploadsSpec
  ) where

import Control.Concurrent (ThreadId, myThreadId)
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
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime)
import Data.Bits (shiftR)
import Data.Word (Word16, Word32, Word8)
import GHC.Float (castFloatToWord32)
import Numeric.Natural (Natural)
import System.Directory (getTemporaryDirectory)
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
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, validateBudgets)
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
  , drawIndexed
  , pushConstants
  , validateRingSize
  , writeClaim
  , UploadConfig
  , UploadRequest (..)
  , UploadState (..)
  , awaitUploadTicket
  , copyLevelToReadback
  , submitVulkanUpload
  , validateUploadConfig
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (formatB8G8R8A8Srgb)
import Hetoimasia.GPU.Vulkan.Native.Recording.Shaders (endpointShaders, quadShaders, verificationShaders)
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
    pure (Seen threads answers windows (Just roots) Nothing [] [] Nothing)

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
    pure (Seen [] [] 1 (Just roots) (Just standing) [] [] Nothing)
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
    pure (Seen [firstOn, fst second] ["recorded an initializing frame-less batch", "recorded a second frame-less batch"] 0 (Just roots) Nothing tickets [] Nothing)
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
    pure (Seen [renderedOn, readOn] ["rendered and copied both targets", "read both readbacks"] 0 (Just roots) Nothing tickets shots Nothing)
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
    pure (Seen [drawnOn, readOn] ["drew the quad and copied the target", "read the readback"] 0 (Just roots) Nothing [waited] [shot] Nothing)
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
