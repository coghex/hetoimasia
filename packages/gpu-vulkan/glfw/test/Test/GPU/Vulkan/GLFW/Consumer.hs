{-# LANGUAGE AllowAmbiguousTypes #-}

-- | VK-19's examples: a consumer's own pipelines built and drawn through the
-- public host's renderer, their teardown, and verification capture, over whole
-- graphics hosts on the GLFW package's scripted seam with the stand-in native
-- layers of "Test.GPU.Vulkan.GLFW.StandIn".
--
-- The stand-in recording layer journals every command it is asked to record
-- and every managed object it makes and destroys, so an example reads what the
-- host and the consumer recorded, in order, beside the roots' own calls. Its
-- readback buffers read back as 'readbackByte', and its submissions complete
-- only when the example lets them ('submissionsComplete'). None sleeps for
-- correctness; each wait for something /not/ to happen is bounded by owner
-- rounds that asked a fence and were answered no.
module Test.GPU.Vulkan.GLFW.Consumer (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception (..), SomeException, throwIO, toException)
import Control.Monad (void)
import qualified Data.ByteString as ByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf, isSubsequenceOf)
import Data.Maybe (isJust, isNothing)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import System.Timeout (timeout)

import Hetoimasia.GLFW.Command (clientDemandPublisher)
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.GPU.Model.Identity (TargetClass (..), imageGeneration)
import Hetoimasia.GPU.Vulkan.Diagnostics (DiagnosticVerdict, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Loop (runVulkanOwnerLoop)
import Hetoimasia.GPU.Vulkan.Native.Naming (NativeObjectKind (ObjectPipeline))
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..), formatB8G8R8A8Srgb, formatR8G8B8A8Srgb, imageUsageColorAttachment, imageUsageTransferSource)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( BufferDescription (..)
  , BufferKind (..)
  , ClearColor (..)
  , ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , ImageLayout (..)
  , NativeCommand (..)
  , Pipeline
  , PipelineLayout
  , PipelineShaders (..)
  , Recorder
  , Rect (..)
  , Refusal (..)
  , Viewport (..)
  , beginRendering
  , bindPipeline
  , draw
  , endRendering
  , readbackBytesFor
  , setScissor
  , setViewport
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsDeviceLost (..), GraphicsSessionFailed (..), TerminalCause (..), TerminalReport (..))
import Hetoimasia.Runtime.GLFW
  ( CloseStart (..)
  , GraphicsService
  , ScheduledStep (..)
  , ScheduledTurn (..)
  , TargetStanding (..)
  , Turn (..)
  , UpdateSchedule (..)
  , closeHostWindow
  , defaultScheduledHooks
  , graphicsAttachment
  , hostWindowClient
  , readOwnerFailure
  , readOwnerStatusNow
  , OwnerPhase (..)
  , OwnerStatus (..)
  , superviseGraphicsOwner
  )
import Hetoimasia.Runtime.Supervision (RuntimeControl, checkRuntime)
import Test.GPU.Vulkan.GLFW.StandIn
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Vulkan consumer rendering and capture" $ do
  describe "consumer construction" $ do
    it "describes each frame's format and extent, and binds and draws a pipeline the consumer built in the host's frame" (bounded testConsumerTriangle)
    it "refuses construction and release off the owner's thread before any native call, buffers and images included" (bounded testOffOwnerThread)
    it "refuses a pipeline built for another format at its binding, recording nothing of it" (bounded testIncompatibleFormat)
    it "skips only the frame whose construction was refused or raised with no effect, never calling the renderer again for it, and the session continues" (bounded testRefusedConstruction)
    it "fails the session through the terminal latch, keeping the loss primary, when a construction loses the device" (bounded testTerminalConstruction)
    it "keeps a replaced pipeline and its layout while a submitted batch still holds them, and destroys it only on that batch's completion" (bounded testReplacedInFlight)
    it "ends the owner's run, never answering a refusal, when a replacement's new pipeline cannot be named after it was committed" (bounded testReplacementUnnamed)

  describe "consumer teardown" $ do
    it "destroys what the consumer built, pipeline before layout, before the device on the host's normal exit, with a clean verdict" (bounded testNormalTeardown)
    it "destroys what the consumer built before the device on a terminal exit, with the validation error primary" (bounded testTerminalTeardown)

  describe "verification capture" $ do
    it "leaves a host without capture exactly as before: clipped, no transfer-source usage, and every request refused" (bounded testCaptureOff)
    it "builds a capturing host's generations unclipped, and transfer sources where the surface offers it" (bounded testCaptureOn)
    it "copies after the consumer's commands in the same batch, and delivers the bytes once, only after the batch's completion" (bounded testCaptureDelivered)
    it "delivers nothing for a captured frame the renderer refused, naming why, and destroys its readback buffer" (bounded testCaptureSkipped)
    it "admits a surface offering no transfer-source usage, presents its frame, and refuses its capture with a typed reason" (bounded testCaptureUnsupported)
    it "settles a capture outstanding when its target retires, without bytes" (bounded testCaptureRetired)
    it "refuses a capture once its target's retirement has begun, while that retirement is still owed, and settles the one it already had" (bounded testCaptureWhileRetiring)
    it "keeps every admitted outcome until it is taken, refusing further requests at the limit as backpressure" (bounded testCaptureBacklog)
    it "gives a request made from a frame's acquisition report a later frame, never the one already reported" (bounded testCaptureFromAcquisition)
    it "gives a request admitted while an acquisition is under way a later frame, never the one being acquired" (bounded testCaptureDuringAcquisition)
    it "settles a presented capture without bytes when the session fails before its completion, naming the primary, and never delivers it" (bounded testCaptureTerminal)

-- ---------------------------------------------------------------------------
-- The consumer

-- | The consumer's triangle renderer: it builds a layout and a pipeline for
-- the first frame's format, keeps them, and draws one triangle in each frame
-- inside the rendering it begins and ends. Every frame it was asked for is
-- recorded, and so is what it built.
data Triangle = Triangle
  { triangleBuilt ∷ !(TVar (Maybe (PipelineLayout, Pipeline)))
  , triangleRequests ∷ !(TVar [FrameRequest])
  }

newTriangle ∷ IO Triangle
newTriangle = Triangle <$> newTVarIO Nothing <*> newTVarIO []

shaders ∷ PipelineShaders
shaders = PipelineShaders "stand-in vertex SPIR-V" "stand-in fragment SPIR-V"

triangleRenderer ∷ Triangle → VulkanRenderer Scene
triangleRenderer triangle = VulkanRenderer $ \_ request construction recorder → do
  atomically (modifyTVar' (triangleRequests triangle) (<> [request]))
  held ← readTVarIO (triangleBuilt triangle)
  built ← case held of
    Just pair → pure (Right pair)
    Nothing →
      constructPipelineLayout construction >>= \case
        Left refusal → pure (Left refusal)
        Right layout → fmap ((,) layout) <$> constructPipeline construction layout shaders (requestFormat request)
  case built of
    Left refusal → pure (Left refusal)
    Right pair@(_, pipeline) → do
      atomically (writeTVar (triangleBuilt triangle) (Just pair))
      drawTriangle request recorder pipeline

drawTriangle ∷ FrameRequest → Recorder q inst msgr phys dev cmd → Pipeline → IO (Either Refusal ())
drawTriangle request recorder pipeline =
  chain
    [ beginRendering recorder (ClearColor 0 0 0 1)
    , bindPipeline recorder pipeline
    , setViewport recorder (Viewport 0 0 (fromIntegral width) (fromIntegral height))
    , setScissor recorder (Rect 0 0 width height)
    , draw recorder 3 1
    , endRendering recorder
    ]
  where
    SurfaceExtent width height = requestExtent request

chain ∷ [IO (Either Refusal ())] → IO (Either Refusal ())
chain = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (chain rest))

-- | A construction lent to the renderer, kept past its frame.
data Lent = ∀ q inst msgr phys dev cmd. Lent (Construction q inst msgr phys dev cmd)

-- ---------------------------------------------------------------------------
-- Consumer construction

testConsumerTriangle ∷ IO ()
testConsumerTriangle = do
  rig ← visibleRig
  triangle ← newTriangle
  renderWith rig (triangleRenderer triangle)
  runRig rig $ \host control → do
    [window] ← windowsOf host
    _ ← firstFrame rig host control window
    pure ()
  requests ← readTVarIO (triangleRequests triangle)
  requests `shouldSatisfy` (not . null)
  [(requestFormat request, requestExtent request) | request ← requests] `shouldSatisfy` all (== (formatB8G8R8A8Srgb, SurfaceExtent 640 480))
  events ← journal rig
  let layouts = [layout | LayoutMade layout ← events]
      pipelines = [(pipeline, over, format) | PipelineMade pipeline over format ← events]
  length layouts `shouldBe` 1
  pipelines `shouldBe` [(pipeline, layout, formatB8G8R8A8Srgb) | (pipeline, _, _) ← take 1 pipelines, layout ← layouts]
  pipeline ← pipelineHandle rig 0
  commands ← map snd <$> commandsRecorded rig
  -- Inside the host's transitions, in the rendering the consumer began.
  take 8 (map shape commands)
    `shouldBe` [ "barrier LayoutUndefined LayoutColorAttachment"
               , "begin rendering"
               , "bind " <> show pipeline
               , "viewport"
               , "scissor"
               , "draw 3 1"
               , "end rendering"
               , "barrier LayoutColorAttachment LayoutPresentSource"
               ]
  -- It was built on the owner's thread, which is the roots'.
  owners ← threadsOf rig (== InstanceCreated)
  builders ← threadsOf rig (\case LayoutMade _ → True; PipelineMade {} → True; _ → False)
  builders `shouldSatisfy` all (`elem` owners)

testOffOwnerThread ∷ IO ()
testOffOwnerThread = do
  rig ← visibleRig
  triangle ← newTriangle
  lent ← newIORef Nothing
  renderWith rig $ VulkanRenderer $ \scene request construction recorder → do
    writeIORef lent (Just (Lent construction))
    renderScene (triangleRenderer triangle) scene request construction recorder
  (layout, pipeline, release, resources, before, after) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    _ ← firstFrame rig host control window
    Just (Lent construction) ← readIORef lent
    Just (built, pipeline') ← readTVarIO (triangleBuilt triangle)
    before ← journal rig
    -- The example's thread is the main thread, never the owner's.
    layout ← constructPipelineLayout construction
    pipeline ← constructPipeline construction built shaders formatB8G8R8A8Srgb
    release ← releaseConstructed construction pipeline'
    buffer ← constructBuffer construction (BufferDescription StagingBuffer 64)
    image ← constructImage construction (ImageDescription TextureImage Rgba8Srgb 16 16 1)
    after ← journal rig
    pure (layout, pipeline, release, (buffer, image), before, after)
  either Just (const Nothing) layout `shouldBe` Just RefusedNotOwner
  either Just (const Nothing) pipeline `shouldBe` Just RefusedNotOwner
  release `shouldBe` Left RefusedNotOwner
  either Just (const Nothing) (fst resources) `shouldBe` Just RefusedNotOwner
  either Just (const Nothing) (snd resources) `shouldBe` Just RefusedNotOwner
  -- Nothing native happened for any of them.
  let made = \case
        LayoutMade _ → True
        PipelineMade {} → True
        PipelineGone _ → True
        BufferMade {} → True
        ImageMade {} → True
        OwnedViewMade {} → True
        _ → False
  filter made after `shouldBe` filter made before

testIncompatibleFormat ∷ IO ()
testIncompatibleFormat = do
  rig ← visibleRig
  answered ← newTVarIO []
  renderWith rig $ VulkanRenderer $ \_ _ construction recorder → do
    built ←
      constructPipelineLayout construction >>= \case
        Left refusal → pure (Left refusal)
        Right layout → constructPipeline construction layout shaders formatR8G8B8A8Srgb
    case built of
      Left refusal → pure (Left refusal)
      Right pipeline → do
        _ ← beginRendering recorder (ClearColor 0 0 0 1)
        bound ← bindPipeline recorder pipeline
        atomically (modifyTVar' answered (<> [bound]))
        _ ← endRendering recorder
        pure (bound >> Right ())
  runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    demandFrame host window
    composedUntil rig host control "an abandoned frame" (\_ → pure ()) ((>= 1) <$> framesAbandoned rig)
  bound ← readTVarIO answered
  take 1 bound `shouldSatisfy` \case
    [Left (RefusedIncompatible _)] → True
    _ → False
  commands ← map snd <$> commandsRecorded rig
  [() | CommandBindPipeline _ ← commands] `shouldBe` []
  events ← frameEvents rig
  [() | FramePresented {} ← events] `shouldBe` []

testRefusedConstruction ∷ IO ()
testRefusedConstruction = do
  rig ← visibleRig
  triangle ← newTriangle
  calls ← newTVarIO (0 ∷ Int)
  released ← newTVarIO False
  renderWith rig $ VulkanRenderer $ \scene request construction recorder → do
    atomically (modifyTVar' calls (+ 1))
    readTVarIO calls >>= \case
      -- The first frame's construction is refused: a pipeline over a layout
      -- it has already released.
      1 →
        constructPipelineLayout construction >>= \case
          Left refusal → pure (Left refusal)
          Right layout → do
            _ ← releaseConstructed construction layout
            atomically (writeTVar released True)
            void <$> constructPipeline construction layout shaders (requestFormat request)
      -- The second's raises having created nothing.
      2 → do
        raiseOnCreate rig CreatePipeline (toException (StandInFailure "vkCreateGraphicsPipelines ran out of something"))
        renderScene (triangleRenderer triangle) scene request construction recorder
      _ → renderScene (triangleRenderer triangle) scene request construction recorder
  (terminal, attachment) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    (,) <$> atomically (readVulkanTerminal (vulkanController host)) <*> pure (graphicsAttachment service)
  reportPrimary terminal `shouldBe` Nothing
  events ← frameEvents rig
  let abandoned = [reason | FrameAbandoned _ _ reason ← events]
      acquired = length [() | FrameAcquired at _ _ ← events, at == attachment]
  take 2 abandoned `shouldSatisfy` \case
    [first, second] →
      "RefusedMisuse" `isInfixOf` Text.unpack first && "RefusedConstructionFailed" `isInfixOf` Text.unpack second
    _ → False
  -- The renderer was called once for each frame acquired, and never again for
  -- a frame it had refused: the third frame presented.
  readTVarIO calls >>= (`shouldBe` acquired)
  acquired `shouldBe` 3
  [() | FramePresented {} ← events] `shouldSatisfy` (not . null)
  readTVarIO released >>= (`shouldBe` True)

testTerminalConstruction ∷ IO ()
testTerminalConstruction = do
  rig ← visibleRig
  triangle ← newTriangle
  observed ← newTVarIO Nothing
  raiseOnCreate rig CreatePipeline (toException (StandInLoss "vkCreateGraphicsPipelines"))
  renderWith rig (triangleRenderer triangle)
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    demandFrame host window
    atomically (writeTVar observed (Just (vulkanController host)))
    untilOwnerFailed rig host control
    checkRuntime control
  loss ← raisedAs @GraphicsDeviceLost outcome
  lostDuring loss `shouldBe` "vkCreateGraphicsPipelines"
  Just controller ← readTVarIO observed
  report ← atomically (readVulkanTerminal controller)
  reportPrimary report `shouldSatisfy` \case
    Just (TerminalDeviceLost _) → True
    _ → False
  -- It was never answered to the renderer as a refusal.
  events ← frameEvents rig
  [reason | FrameAbandoned _ _ reason ← events, "RefusedConstructionFailed" `isInfixOf` Text.unpack reason] `shouldBe` []

testReplacedInFlight ∷ IO ()
testReplacedInFlight = do
  rig ← visibleRig
  triangle ← newTriangle
  replaced ← newTVarIO Nothing
  renderWith rig $ VulkanRenderer $ \scene request construction recorder → do
    done ← isJust <$> readTVarIO replaced
    readTVarIO (triangleBuilt triangle) >>= \case
      -- The second frame replaces the first's pipeline, once, and binds the
      -- new one.
      Just (layout, old) | not done →
        replaceConstructedPipeline construction old layout shaders (requestFormat request) >>= \case
          Left refusal → pure (Left refusal)
          Right new → do
            atomically $ do
              writeTVar (triangleBuilt triangle) (Just (layout, new))
              writeTVar replaced (Just (old, new))
            drawTriangle request recorder new
      _ → renderScene (triangleRenderer triangle) scene request construction recorder
  submissionsComplete rig False
  (retainedWhileInFlight, gone) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    demandFrame host window
    composedUntil rig host control "a second frame" (\_ → pure ()) ((>= 2) <$> presentsOf rig (graphicsAttachment service))
    Just (old, _) ← readTVarIO replaced
    oldHandle ← pipelineHandle rig 0
    -- The owner keeps polling the first batch's fence, which answers not yet;
    -- nothing destroys the replaced pipeline meanwhile.
    queried ← fenceQueries rig
    composedUntil rig host control "further fence polls" (\_ → pure ()) ((>= queried + 3) <$> fenceQueries rig)
    retained ← notElem (PipelineGone oldHandle) <$> journal rig
    submissionsComplete rig True
    composedUntil rig host control "the replaced pipeline's destruction" (\_ → pure ()) (elem (PipelineGone oldHandle) <$> journal rig)
    events ← journal rig
    old `seq` pure (retained, [event | event ← events, isGone event])
  retainedWhileInFlight `shouldBe` True
  -- The new pipeline and the layout both still stood until the host's exit.
  events ← journal rig
  newHandle ← pipelineHandle rig 1
  [layout] ← pure [layout | LayoutMade layout ← events]
  gone `shouldSatisfy` all (`notElem` [PipelineGone newHandle, LayoutGone layout])
  where
    isGone = \case
      PipelineGone _ → True
      LayoutGone _ → True
      _ → False

testReplacementUnnamed ∷ IO ()
testReplacementUnnamed = do
  rig ← visibleRig
  offerNaming rig
  triangle ← newTriangle
  answered ← newTVarIO False
  renderWith rig $ VulkanRenderer $ \scene request construction recorder →
    readTVarIO (triangleBuilt triangle) >>= \case
      -- The second frame replaces the first's pipeline, whose new generation
      -- is committed, and the old one replaced, before naming it raises.
      Just (layout, old) → do
        failNaming rig ObjectPipeline
        answer ← replaceConstructedPipeline construction old layout shaders (requestFormat request)
        atomically (writeTVar answered True)
        either (pure . Left) (drawTriangle request recorder) answer
      Nothing → renderScene (triangleRenderer triangle) scene request construction recorder
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    [window] ← windowsOf host
    _ ← firstFrame rig host control window
    demandFrame host window
    untilOwnerFailed rig host control
    checkRuntime control
  failure ← raisedAs @StandInFailure outcome
  failure `shouldBe` StandInFailure "naming a ObjectPipeline raised"
  -- The renderer was never answered, so it could not go on holding a stale
  -- handle as though only its frame had been refused.
  readTVarIO answered >>= (`shouldBe` False)
  events ← frameEvents rig
  [reason | FrameAbandoned _ _ reason ← events, "RefusedConstructionFailed" `isInfixOf` Text.unpack reason] `shouldBe` []
  -- Both pipelines the consumer's frames committed were destroyed before the
  -- device all the same.
  journaled ← journal rig
  made ← pure [pipeline | PipelineMade pipeline _ _ ← journaled]
  length made `shouldBe` 2
  journaled `shouldSatisfy` isSubsequenceOf ([PipelineGone pipeline | pipeline ← made] <> [DeviceDestroyed])

-- ---------------------------------------------------------------------------
-- Consumer teardown

testNormalTeardown ∷ IO ()
testNormalTeardown = do
  rig ← visibleRig
  triangle ← newTriangle
  renderWith rig (triangleRenderer triangle)
  runRig rig $ \host control → do
    [window] ← windowsOf host
    void (firstFrame rig host control window)
  events ← journal rig
  pipeline ← pipelineHandle rig 0
  [layout] ← pure [layout | LayoutMade layout ← events]
  events `shouldSatisfy` isSubsequenceOf [PipelineGone pipeline, LayoutGone layout, DeviceDestroyed, InstanceDestroyed]
  Just verdict ← atomically (readTVar (rigVerdict rig))
  verdictClean verdict `shouldBe` True

testTerminalTeardown ∷ IO ()
testTerminalTeardown = do
  rig ← visibleRig
  triangle ← newTriangle
  observed ← newTVarIO Nothing
  renderWith rig (triangleRenderer triangle)
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    [window] ← windowsOf host
    _ ← firstFrame rig host control window
    reportErrorNow rig "an error after the consumer built its pipeline"
    demandFrame host window
    atomically (writeTVar observed (Just (vulkanController host)))
    untilOwnerFailed rig host control
    checkRuntime control
  failure ← raisedAs @GraphicsSessionFailed outcome
  failure `shouldSatisfy` \case
    GraphicsSessionFailed TerminalValidationError → True
    _ → False
  Just controller ← readTVarIO observed
  report ← atomically (readVulkanTerminal controller)
  reportPrimary report `shouldBe` Just TerminalValidationError
  events ← journal rig
  pipeline ← pipelineHandle rig 0
  [layout] ← pure [layout | LayoutMade layout ← events]
  events `shouldSatisfy` isSubsequenceOf [PipelineGone pipeline, LayoutGone layout, DeviceDestroyed, InstanceDestroyed]

-- ---------------------------------------------------------------------------
-- Verification capture

testCaptureOff ∷ IO ()
testCaptureOff = do
  rig ← visibleRig
  offerUsage rig (imageUsageColorAttachment + imageUsageTransferSource)
  refused ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    atomically (requestVulkanCapture (vulkanController host) (graphicsAttachment service))
  refused `shouldBe` Left CaptureDisabled
  plans ← planned rig
  plans `shouldSatisfy` (not . null)
  plans `shouldSatisfy` all (== (imageUsageColorAttachment, True))

testCaptureOn ∷ IO ()
testCaptureOn = do
  rig ← capturingRigOf 1
  offerUsage rig (imageUsageColorAttachment + imageUsageTransferSource)
  runRig rig $ \host control → do
    [window] ← windowsOf host
    void (firstFrame rig host control window)
  plans ← planned rig
  plans `shouldSatisfy` (not . null)
  plans `shouldSatisfy` all (== (imageUsageColorAttachment + imageUsageTransferSource, False))

testCaptureDelivered ∷ IO ()
testCaptureDelivered = do
  rig ← capturingRigOf 1
  offerUsage rig (imageUsageColorAttachment + imageUsageTransferSource)
  submissionsComplete rig False
  (beforeCompletion, delivered, again, attachment) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    let controller = vulkanController host
        attachment = graphicsAttachment service
    -- Nothing else asks for a frame: the request itself does.
    Right ticket ← atomically (requestVulkanCapture controller attachment)
    composedUntil rig host control "the captured frame's presentation" (\_ → pure ()) ((>= 1) <$> presentsOf rig attachment)
    -- The batch's fence is asked, and answers not yet, on further rounds:
    -- the bytes are not exposed meanwhile.
    queried ← fenceQueries rig
    composedUntil rig host control "further fence polls" (\_ → pure ()) ((>= queried + 3) <$> fenceQueries rig)
    before ← atomically (takeVulkanCapture controller ticket)
    submissionsComplete rig True
    outcome ← newTVarIO Nothing
    composedUntil rig host control "the capture's delivery" (\_ → pure ()) $
      atomically (takeVulkanCapture controller ticket) >>= \case
        Nothing → pure False
        Just settled → True <$ atomically (writeTVar outcome (Just settled))
    Just settled ← readTVarIO outcome
    later ← atomically (takeVulkanCapture controller ticket)
    pure (before, settled, later, attachment)
  isNothing beforeCompletion `shouldBe` True
  isNothing again `shouldBe` True
  events ← frameEvents rig
  let presentations = [(frame, presentation) | FramePresented at frame presentation _ ← events, at == attachment]
      images = [image | FrameAcquired at _ image ← events, at == attachment]
  case delivered of
    CaptureDelivered frame → do
      capturedAttachment frame `shouldBe` attachment
      capturedExtent frame `shouldBe` SurfaceExtent 640 480
      capturedFormat frame `shouldBe` formatB8G8R8A8Srgb
      take 1 presentations `shouldBe` [(capturedFrame frame, capturedPresentation frame)]
      take 1 images `shouldBe` [capturedImage frame]
      capturedGeneration frame `shouldBe` imageGeneration (capturedImage frame)
      ByteString.length (capturedBytes frame) `shouldBe` fromIntegral (readbackBytesFor (SurfaceExtent 640 480))
      ByteString.all (== readbackByte) (capturedBytes frame) `shouldBe` True
    other → expectationFailure ("the capture was not delivered: " <> show other)
  -- After the consumer's rendering, in the same batch: the transition to the
  -- copy, the copy, the transfer write made visible to the host, and the
  -- transition to presentation.
  commands ← map snd <$> commandsRecorded rig
  captured : _ ← pure [batch | batch ← batches commands, any copying batch]
  map shape captured
    `shouldBe` [ "barrier LayoutUndefined LayoutColorAttachment"
               , "begin rendering"
               , "end rendering"
               , "barrier LayoutColorAttachment LayoutTransferSource"
               , "copy"
               , "host read barrier"
               , "barrier LayoutTransferSource LayoutPresentSource"
               ]
  -- The readback buffer was released and destroyed on the owner's thread.
  journaled ← journal rig
  [buffer] ← pure [buffer | ReadbackMade buffer _ ← journaled]
  journaled `shouldSatisfy` isSubsequenceOf [ReadbackGone buffer, DeviceDestroyed]
  where
    copying = \case
      CommandCopyImageToBuffer {} → True
      _ → False

testCaptureSkipped ∷ IO ()
testCaptureSkipped = do
  rig ← capturingRigOf 1
  offerUsage rig (imageUsageColorAttachment + imageUsageTransferSource)
  refuseFrames rig True
  settled ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    Right ticket ← atomically (requestVulkanCapture (vulkanController host) (graphicsAttachment service))
    outcome ← awaitCapture rig host control ticket
    composedUntil rig host control "the readback buffer's destruction" (\_ → pure ()) (any gone <$> journal rig)
    pure outcome
  case settled of
    CaptureWithheld _ (WithheldFrameAbandoned _ reason) → Text.unpack reason `shouldSatisfy` ("the renderer refused" `isPrefixOf`)
    other → expectationFailure ("the capture was not withheld as abandoned: " <> show other)
  commands ← map snd <$> commandsRecorded rig
  [() | CommandCopyImageToBuffer {} ← commands] `shouldBe` []
  where
    gone = \case
      ReadbackGone _ → True
      _ → False

testCaptureUnsupported ∷ IO ()
testCaptureUnsupported = do
  rig ← capturingRigOf 1
  (standing, settled, attachment) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    standing ← awaitStanding host service
    Right ticket ← atomically (requestVulkanCapture (vulkanController host) (graphicsAttachment service))
    outcome ← awaitCapture rig host control ticket
    composedUntil rig host control "the frame's presentation" (\_ → pure ()) ((>= 1) <$> presentsOf rig (graphicsAttachment service))
    pure (standing, outcome, graphicsAttachment service)
  standing `shouldBe` TargetUsable
  events ← frameEvents rig
  generation : _ ← pure [imageGeneration image | FrameAcquired at _ image ← events, at == attachment]
  settled `shouldBe` CaptureWithheld attachment (WithheldUnsupported generation)
  plans ← planned rig
  plans `shouldSatisfy` all (== (imageUsageColorAttachment, False))
  journaled ← journal rig
  [() | ReadbackMade {} ← journaled] `shouldBe` []

testCaptureRetired ∷ IO ()
testCaptureRetired = do
  rig ← capturingRigOf 1
  offerUsage rig (imageUsageColorAttachment + imageUsageTransferSource)
  controller ← newIORef Nothing
  ticketHeld ← newIORef Nothing
  runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    writeIORef controller (Just (vulkanController host))
    publishObservation host service window
    composedUntil rig host control "the first generation" (\_ → pure ()) (not . null . swapchains <$> journal rig)
    -- Its acquisitions cannot be answered, so no frame of it is acquired.
    first : _ ← swapchains <$> journal rig
    stallSwapchain rig first
    Right ticket ← atomically (requestVulkanCapture (vulkanController host) (graphicsAttachment service))
    writeIORef ticketHeld (Just ticket)
    composedUntil rig host control "a pending acquisition" (\_ → pure ()) (any pending <$> frameEvents rig)
    CloseStarted ← closeHostWindow (vulkanWindowHost host) window
    composedUntil rig host control "the window's release" (\_ → pure ()) (elem (WindowGone False) <$> journal rig)
  Just held ← readIORef controller
  Just ticket ← readIORef ticketHeld
  settled ← atomically (takeVulkanCapture held ticket)
  settled `shouldSatisfy` \case
    Just (CaptureWithheld _ WithheldTargetRetired) → True
    _ → False
  where
    swapchains events = [handle | SwapchainCreated handle _ _ ← events]
    pending = \case
      FramePending {} → True
      _ → False

testCaptureWhileRetiring ∷ IO ()
testCaptureWhileRetiring = do
  rig ← capturingRigOf 1
  offerUsage rig (imageUsageColorAttachment + imageUsageTransferSource)
  -- The first frame's presentation stays owed, so the target's retirement,
  -- once begun, cannot finish until the example lets it.
  presentationsRetire rig False
  (first, whileOwed, surfaceThen, afterwards, settled) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    let controller = vulkanController host
        attachment = graphicsAttachment service
    -- A request its target can never serve a frame for stays outstanding.
    swapchain : _ ← (\events → [handle | SwapchainCreated handle _ _ ← events]) <$> journal rig
    stallSwapchain rig swapchain
    first ← atomically (requestVulkanCapture controller attachment)
    CloseStarted ← closeHostWindow (vulkanWindowHost host) window
    refused ← newTVarIO Nothing
    composedUntil rig host control "a refusal while the retirement is owed" (\_ → pure ()) $ do
      answer ← atomically (requestVulkanCapture controller attachment)
      case answer of
        Left CaptureTargetRetiring → do
          surface ← elem (SurfaceDestroyed 100) <$> journal rig
          True <$ atomically (writeTVar refused (Just (answer, surface)))
        _ → pure False
    Just (whileOwed, surfaceThen) ← readTVarIO refused
    presentationsRetire rig True
    composedUntil rig host control "the window's release" (\_ → pure ()) (elem (WindowGone False) <$> journal rig)
    afterwards ← atomically (requestVulkanCapture controller attachment)
    settled ← either (const (pure Nothing)) (atomically . takeVulkanCapture controller) first
    pure (first, whileOwed, surfaceThen, afterwards, settled)
  first `shouldSatisfy` either (const False) (const True)
  whileOwed `shouldBe` Left CaptureTargetRetiring
  -- Refused while the target and its surface still stood.
  surfaceThen `shouldBe` False
  afterwards `shouldBe` Left CaptureNoTarget
  settled `shouldSatisfy` \case
    Just (CaptureWithheld _ WithheldTargetRetired) → True
    _ → False

testCaptureBacklog ∷ IO ()
testCaptureBacklog = do
  -- Its surface offers no transfer-source usage, so every request settles, as
  -- withheld, with its frame.
  rig ← capturingRigOf 1
  (tickets, full, outcomes, again) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    let controller = vulkanController host
        attachment = graphicsAttachment service
    admitted ← newTVarIO []
    refusal ← newTVarIO Nothing
    composedUntil rig host control "the backlog's limit" (\_ → pure ()) $
      atomically (requestVulkanCapture controller attachment) >>= \case
        Right ticket → False <$ atomically (modifyTVar' admitted (<> [ticket]))
        Left (CaptureOutstanding _) → pure False
        Left other → True <$ atomically (writeTVar refusal (Just other))
    tickets ← readTVarIO admitted
    Just full ← readTVarIO refusal
    outcomes ← mapM (atomically . takeVulkanCapture controller) tickets
    again ← atomically (requestVulkanCapture controller attachment)
    pure (tickets, full, outcomes, again)
  length tickets `shouldBe` capturesRetained
  full `shouldBe` CaptureBacklogFull capturesRetained
  -- Every admitted ticket still had its outcome to take.
  outcomes `shouldSatisfy` all (\case Just (CaptureWithheld _ (WithheldUnsupported _)) → True; _ → False)
  again `shouldSatisfy` either (const False) (const True)

testCaptureFromAcquisition ∷ IO ()
testCaptureFromAcquisition = do
  rig ← capturingRigOf 1
  offerUsage rig (imageUsageColorAttachment + imageUsageTransferSource)
  trigger ← newTVarIO Nothing
  ticketHeld ← newTVarIO Nothing
  (settled, acquired) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    let controller = vulkanController host
        attachment = graphicsAttachment service
    -- The first acquisition's report asks for a capture, once, from the
    -- owner's thread, as a verifier's frame observer may.
    onFrameEvent rig $ \case
      FrameAcquired at frame image | at == attachment → do
        armed ← isNothing <$> readTVarIO trigger
        when' armed $ do
          atomically (writeTVar trigger (Just (frame, image)))
          atomically (requestVulkanCapture controller attachment) >>= \case
            Right ticket → atomically (writeTVar ticketHeld (Just ticket))
            Left refusal → throwIO (StandInFailure (Text.pack ("the capture was refused: " <> show refusal)))
      _ → pure ()
    demandFrame host window
    composedUntil rig host control "the request made from the report" (\_ → pure ()) (isJust <$> readTVarIO ticketHeld)
    Just ticket ← readTVarIO ticketHeld
    settled ← awaitCapture rig host control ticket
    events ← frameEvents rig
    pure (settled, [(frame, image) | FrameAcquired at frame image ← events, at == attachment])
  Just (triggerFrame, triggerImage) ← readTVarIO trigger
  case settled of
    CaptureDelivered frame → do
      (capturedFrame frame, capturedImage frame) `shouldSatisfy` (/= (triggerFrame, triggerImage))
      -- The captured frame was acquired after the one whose report asked.
      dropWhile (/= (triggerFrame, triggerImage)) acquired `shouldSatisfy` elem (capturedFrame frame, capturedImage frame) . drop 1
    other → expectationFailure ("the capture was not delivered: " <> show other)
  where
    when' condition action = if condition then action else pure ()

testCaptureDuringAcquisition ∷ IO ()
testCaptureDuringAcquisition = do
  rig ← capturingRigOf 1
  offerUsage rig (imageUsageColorAttachment + imageUsageTransferSource)
  (settled, before, acquired) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    let controller = vulkanController host
        attachment = graphicsAttachment service
        acquisitions = (\events → [(frame, image) | FrameAcquired at frame image ← events, at == attachment]) <$> frameEvents rig
    before ← length <$> acquisitions
    -- The next acquisition holds inside the native call, after the owner
    -- decided which request it would be for and before it has a frame.
    gate ← newTVarIO False
    holding ← holdAcquisitions rig gate
    demandFrame host window
    composedUntil rig host control "an acquisition under way" (\_ → pure ()) (atomically holding)
    Right ticket ← atomically (requestVulkanCapture controller attachment)
    atomically (writeTVar gate True)
    settled ← awaitCapture rig host control ticket
    (,,) settled before <$> acquisitions
  -- The acquisition that was under way when the request was admitted.
  held : later ← pure (drop before acquired)
  case settled of
    CaptureDelivered frame → do
      (capturedFrame frame, capturedImage frame) `shouldSatisfy` (/= held)
      later `shouldSatisfy` elem (capturedFrame frame, capturedImage frame)
    other → expectationFailure ("the capture was not delivered: " <> show other)

testCaptureTerminal ∷ IO ()
testCaptureTerminal = do
  rig ← capturingRigOf 1
  offerUsage rig (imageUsageColorAttachment + imageUsageTransferSource)
  -- Nothing the frame's batch or its presentation owes completes until the
  -- owner's drain has begun, as a real present fence cannot signal before the
  -- rendering it waited for.
  submissionsComplete rig False
  presentationsRetire rig False
  controller ← newIORef Nothing
  ticketHeld ← newIORef Nothing
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    writeIORef controller (Just (vulkanController host))
    Right ticket ← atomically (requestVulkanCapture (vulkanController host) (graphicsAttachment service))
    writeIORef ticketHeld (Just ticket)
    composedUntil rig host control "the captured frame's presentation" (\_ → pure ()) ((>= 1) <$> presentsOf rig (graphicsAttachment service))
    -- The batch completes only once the owner's run has failed and its drain
    -- has begun: its bytes are then exposed by the evidence, and must still
    -- not be delivered.
    _ ← forkIO $ do
      atomically (readOwnerStatusNow (vulkanGraphicsOwner host) >>= check . (== OwnerRetiring) . statusPhase)
      submissionsComplete rig True
      presentationsRetire rig True
    reportErrorNow rig "an error while the captured frame's batch is in flight"
    demandFrame host window
    untilOwnerFailed rig host control
    checkRuntime control
  _ ← raisedAs @GraphicsSessionFailed outcome
  Just held ← readIORef controller
  Just ticket ← readIORef ticketHeld
  settled ← atomically (takeVulkanCapture held ticket)
  settled `shouldSatisfy` \case
    Just (CaptureWithheld _ (WithheldSessionEnded (Just TerminalValidationError))) → True
    _ → False
  again ← atomically (takeVulkanCapture held ticket)
  isNothing again `shouldBe` True

-- ---------------------------------------------------------------------------
-- Helpers

-- | A window's own demand publisher.
demandFrame ∷ VulkanHost Scene → WindowId → IO ()
demandFrame host window = do
  client ← atomically (hostWindowClient (vulkanWindowHost host) window) >>= maybe (failWith "the window has no client") pure
  void (publishDemand (clientDemandPublisher client) immediateDemand)

-- | Run the composed loop until the condition holds.
composedUntil ∷ Rig → VulkanHost Scene → RuntimeControl → String → (ScheduledTurn → IO ()) → IO Bool → IO ()
composedUntil rig host control what each done =
  runVulkanOwnerLoop host control $
    defaultScheduledHooks quietLogger $ \turn → do
      each turn
      finished ← done
      if finished
        then pure (FinishWith ())
        else
          if turnNumber (scheduledTurn turn) > 20000
            then do
              events ← frameEvents rig
              throwIO (StandInFailure (Text.pack ("the composed loop never reached " <> what <> "; the last frame events: " <> show (drop (length events - 12) events))))
            else pure (ContinueWith NoUpdateDemand)

-- | Hand the host's window over, wait until its owner has built it a
-- generation, and present one frame through the composed loop.
firstFrame ∷ Rig → VulkanHost Scene → RuntimeControl → WindowId → IO GraphicsService
firstFrame rig host control window = do
  service ← handedOver host window RequiredTarget
  TargetUsable ← awaitStanding host service
  demandFrame host window
  composedUntil rig host control "a first presented frame" (\_ → pure ()) ((>= 1) <$> presentsOf rig (graphicsAttachment service))
  pure service

-- | Run the composed loop until the owner's run has failed. The loop's own
-- checkpoint may raise the failure first, which ends the example's body as
-- the application's checkpoint would.
untilOwnerFailed ∷ Rig → VulkanHost Scene → RuntimeControl → IO ()
untilOwnerFailed rig host control =
  composedUntil rig host control "the owner's failure" (\_ → pure ()) (isJust <$> atomically (readOwnerFailure (vulkanGraphicsOwner host)))

-- | Run the composed loop until the capture has settled, and take it.
awaitCapture ∷ Rig → VulkanHost Scene → RuntimeControl → CaptureTicket → IO CaptureOutcome
awaitCapture rig host control ticket = do
  held ← newTVarIO Nothing
  composedUntil rig host control "the capture's settlement" (\_ → pure ()) $
    atomically (takeVulkanCapture (vulkanController host) ticket) >>= \case
      Nothing → pure False
      Just settled → True <$ atomically (writeTVar held (Just settled))
  readTVarIO held >>= maybe (failWith "the capture did not settle") pure

-- | Every swapchain's image usage and whether it was created clipped.
planned ∷ Rig → IO [(Word32, Bool)]
planned rig = (\events → [(usage, clipped) | SwapchainPlanned _ usage clipped ← events]) <$> journal rig

-- | The nth pipeline the consumer built.
pipelineHandle ∷ Rig → Int → IO Word64
pipelineHandle rig index = do
  events ← journal rig
  case drop index [pipeline | PipelineMade pipeline _ _ ← events] of
    pipeline : _ → pure pipeline
    [] → failWith ("the consumer built no pipeline " <> show index)

-- | The recorded commands split into batches, each beginning with the host's
-- transition into rendering.
batches ∷ [NativeCommand] → [[NativeCommand]]
batches = \case
  [] → []
  first : rest →
    let (inside, after) = break opening rest
     in (first : inside) : batches after
  where
    opening = \case
      CommandImageBarrier _ LayoutUndefined LayoutColorAttachment → True
      _ → False

-- | A command, as an example compares it.
shape ∷ NativeCommand → String
shape = \case
  CommandImageBarrier _ from to → "barrier " <> show from <> " " <> show to
  CommandBeginRendering {} → "begin rendering"
  CommandEndRendering → "end rendering"
  CommandBindPipeline pipeline → "bind " <> show pipeline
  CommandSetViewport _ → "viewport"
  CommandSetScissor _ → "scissor"
  CommandDraw vertices instances _ _ → "draw " <> show vertices <> " " <> show instances
  CommandCopyImageToBuffer {} → "copy"
  CommandHostReadBarrier {} → "host read barrier"
  CommandBeginLabel _ → "label"
  CommandEndLabel → "end label"

verdictClean ∷ DiagnosticVerdict → Bool
verdictClean = null . verdictIssues

bounded ∷ IO () → Expectation
bounded action =
  timeout (60 * 1000 * 1000) action >>= \case
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"

raisedAs ∷ ∀ e a. Exception e ⇒ Either SomeException a → IO e
raisedAs = \case
  Left failure → case fromException failure of
    Just typed → pure typed
    Nothing → failWith ("the run failed with something else: " <> show failure)
  Right _ → failWith "the run returned instead of failing"

failWith ∷ String → IO a
failWith message = expectationFailure message >> throwIO (userError message)

