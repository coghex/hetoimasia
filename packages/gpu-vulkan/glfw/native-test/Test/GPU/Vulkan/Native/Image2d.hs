{-# LANGUAGE OverloadedRecordDot #-}

-- | R2D-8's native case (@r2d8-image@): the image2d sample's evidence and its
-- texture lifecycle, through the production host, on private roots in a child
-- process of its own.
--
-- The production composition — 'withVulkanOwnerHost' over the loader
-- integration, with the validation layer and synchronization validation — is
-- configured with 'PerWindowScenes', the per-window adapter's lifecycle hooks
-- and one test-owned window. Nothing is captured from a screen.
--
-- 1. __Evidence.__ Before the window is handed over, the sample's window-free
--    evidence ("Hetoimasia.Sample.Image2d.Evidence") renders the frame offscreen
--    through the same recorder, reads it back after the batch's completion and
--    judges every pixel against the oracle and every named probe against its
--    hand-stated colour. It also shows the swap rule: a swap of the PNG's handle
--    to an image whose computed mark differs is refused, naming both marks, and
--    accepted when the registered mark is explicitly kept. The PNG and the probe
--    record are kept with the case's evidence.
-- 2. __The lifecycle__, through the actual per-window adapter and the host's
--    adoption callbacks, in one window:
--
--    a. a snapshot showing the PNG and the KTX2 image is published and adopted;
--    b. the KTX2 image's release is requested while that snapshot is adopted.
--       The request is the adapter's: it marks the texture released at once and
--       asks the host for the release. The release runs on the owner's thread
--       once the host's barrier is met, and finds the adopted snapshot holding
--       the texture, so the table still maps it; the window renders that
--       snapshot again, showing the texture, afterwards;
--    c. publishing a snapshot that names the released texture is refused,
--       naming it;
--    d. a snapshot without the texture is published and adopted, the first
--       snapshot is released by the host, and only then does the release take
--       effect: the table no longer maps the handle.
-- 3. The loop finishes and the host exits through D-33.
--
-- The case asserts the order of the log it kept of the lifecycle, the
-- renderer's calls and the release actions, read from the real table on the
-- owner's thread; that every Vulkan call ran on the graphics owner's thread;
-- and a verdict, read after the last callback, with no issue at all.
module Test.GPU.Vulkan.Native.Image2d
  ( Image2dOutcome (..)
  , runImage2d
  , image2dSection
  , spec
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry, writeTVar)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (elemIndex, findIndex, nub)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Numeric.Natural (Natural)
import System.Directory (getTemporaryDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

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
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), durationFromNanoseconds)
import Hetoimasia.GLFW.Command (clientDemandPublisher)
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GLFW.Session (Backend)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (WindowConfig (..), WindowId, hiddenTestWindowConfig)
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict (..), defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , Construction
  , FrameEvent (..)
  , FrameRequest (..)
  , Readiness (..)
  , Refusal
  , SceneLifecycle (..)
  , SceneMode (..)
  , TicketState (..)
  , UploadConfig
  , UploadState (..)
  , VulkanAction (..)
  , VulkanDeviceStart (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , VulkanRenderer (..)
  , WindowScenePublication (..)
  , awaitTicket
  , awaitUploadTicket
  , awaitVulkanAction
  , constructBlendedCheckedPipeline
  , constructFramelessBatch
  , constructImage
  , constructReadback
  , constructRing
  , constructShaderSampledTablePipelineLayout
  , constructTextureTable
  , handOverVulkanTarget
  , publishVulkanWindowScene
  , readConstructedReadback
  , readConstructedTable
  , readReadiness
  , readVulkanGenerations
  , registerConstructedTexture
  , releaseConstructedTexture
  , requestVulkanRelease
  , runVulkanOwnerLoop
  , submitVulkanAction
  , submitVulkanUpload
  , swapConstructedTexture
  , validateUploadConfig
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.GPU.Vulkan.Native.Generations (TargetCondition (..), TargetGenerationsView (..))
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.GPU.Vulkan.Native.TextureTable (LookupEntry (..), TableView (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.Api.Texture.Backend (handleGeneration, handleIndex)
import Hetoimasia.Render.TwoD.Snapshot (Target (WindowTarget))
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Window
  ( FrameInfo (..)
  , Host (..)
  , HostPublication (..)
  , PublishRefusal (..)
  , ReleaseBody
  , Scene2D (..)
  , adapterAdopted
  , adapterReleased
  , blankScene
  , newAdapter
  , pendingReleases
  , publish2DSnapshot
  , release2DTexture
  , renderWindowFrame
  )
import Hetoimasia.Runtime.GLFW
  ( OwnerStatus (..)
  , ScheduledStep (..)
  , TargetStanding (..)
  , UpdateSchedule (..)
  , defaultHostConfig
  , defaultScheduledHooks
  , graphicsAttachment
  , hostWindowClient
  , hostWindowIdentities
  , readOwnerStatusNow
  , readTargetStanding
  , runGraphicsOwnerApplication
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import qualified Hetoimasia.Sample.Image2d as Sample
import Hetoimasia.Sample.Image2d (Builders (..), Prepared (..), handlesOf)
import Hetoimasia.Sample.Image2d.Assets (ImageName (..))
import Hetoimasia.Sample.Image2d.Evidence (Evidence (..), NamedResult (..), SwapDemonstration (..), runEvidenceWith)
import Hetoimasia.Sample.Image2d.Fixtures (NamedProbe (..))
import Hetoimasia.Sample.Image2d.Scene (Handles (..), Layout (..), snapshotFor)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.GPU.Vulkan.Native.Platform (requestingBackend)
import Test.Vulkan.Proof.Journal (Journal, heading, note)
import Test.Vulkan.Proof.Roots (NativeCall (..), nativeCallObserver)

-- | What the case kept, in the order it happened, on the threads it happened
-- on.
data Entry
  = Frame !FrameEvent
  | Adopted !WindowId !Natural !(Set Api.TextureHandle)
    -- ^ The owner adopted this revision, which references these textures.
  | Released !WindowId !Natural
  | Rendered !Natural !(Set Api.TextureHandle)
    -- ^ The renderer was handed the window's scene of this revision.
  | ReleaseRan !Bool
    -- ^ A release the adapter queued ran on the owner's thread; whether the
    -- KTX2 image's handle still resolved to its own slot in the real table
    -- afterwards.
  | Marker !Text
  deriving (Eq, Show)

-- | What the case saw.
data Facts = Facts
  { factsLog ∷ ![Entry]
  , factsEvidence ∷ !Evidence
  , factsStripes ∷ !Api.TextureHandle
  , factsQuadrants ∷ !Api.TextureHandle
  , factsRefusal ∷ !(Either PublishRefusal Natural)
    -- ^ What publishing a snapshot naming the released texture answered.
  , factsPublications ∷ ![Either PublishRefusal Natural]
  , factsPending ∷ !(Set Api.TextureHandle)
    -- ^ The textures whose release is still pending at the end.
  , factsCalls ∷ ![NativeCall]
  , factsMainThread ∷ !ThreadId
  , factsVerdict ∷ !(Maybe DiagnosticVerdict)
  , factsErrors ∷ ![Text]
  , factsSeconds ∷ !Double
  }

data Image2dOutcome
  = Image2dFailed !Text
  | Image2dRecorded !Facts

-- | The phase the loop's update opportunity is in.
data Phase
  = Preparing
  | PublishedShowing
    -- ^ The snapshot showing both images is published; its adoption and a
    -- frame of it are awaited.
  | ReleaseRequested
    -- ^ The release is requested; its run, and a frame of the snapshot still
    -- showing the texture, are awaited.
  | PublishedWithout
    -- ^ The snapshot without the texture is published; its adoption, the
    -- showing snapshot's release and the release's second run are awaited.
  | Done

-- | The case's own deadline for the lifecycle, inside the child's.
lifecycleSeconds ∷ Double
lifecycleSeconds = 12

-- | Run the case on the calling thread, which must be the process main thread.
runImage2d ∷ Maybe Backend → Journal → IO Image2dOutcome
runImage2d backend journal = do
  heading journal "R2D-8: the image2d sample's evidence offscreen, and a texture's release deferred behind the window host's adoption of the snapshots that show it"
  started ← getCurrentTime
  directory ← evidenceDirectory
  note journal ("the image2d evidence is written into " <> Text.pack directory)
  recorded ← newIORef []
  entries ← newTVarIO []
  logged ← newTVarIO []
  verdictHeld ← newIORef Nothing
  factsHeld ← newIORef Nothing
  owner ← newTVarIO Nothing
  preparedHeld ← newTVarIO Nothing
  adapterSlot ← newTVarIO Nothing
  initial ← prepare blankScene
  budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024})
  let window name = (hiddenTestWindowConfig name 160 120) {windowVisible = True}
      host = requestingBackend backend (defaultHostConfig [window "hetoimasia R2D-8 image"])
      logger = recordingLogger (\entry → atomically (modifyTVar' logged (entry :)))
      keep entry = atomically (modifyTVar' entries (<> [entry]))
      config =
        (vulkanHostConfig host defaultCaptureConfig {captureTextBudget = 16384} budgets initial)
          { vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
          , vulkanValidationFeatures = validationFeatures
          , vulkanObserver = nativeCallObserver recorded
          , vulkanFrameObserver = \event → keep (Frame event)
          , vulkanSceneMode = PerWindowScenes
          , vulkanUploads = Just uploadConfig
          , vulkanDeviceStart = DeviceSurfaceFree
          , vulkanSceneLifecycle =
              SceneLifecycle
                { sceneAdopted = \at revision scene → do
                    keep (Adopted at revision (sceneReferences scene))
                    readTVarIO adapterSlot >>= maybe (pure ()) (\adapter → adapterAdopted adapter at revision scene)
                , sceneReleased = \at revision → do
                    keep (Released at revision)
                    readTVarIO adapterSlot >>= maybe (pure ()) (\adapter → adapterReleased adapter at revision)
                }
          , vulkanRenderer = VulkanRenderer $ \scene request construction recorder → do
              keep (Rendered (requestSceneRevision request) (sceneReferences scene))
              readTVarIO preparedHeld >>= \case
                Nothing → pure (Right ())
                Just ready → do
                  let SurfaceExtent width height = requestExtent request
                      info = FrameInfo (width, height) (requestFormat request) (requestLogicalExtent request) (requestContentScale request)
                  renderWindowFrame (renderBuildersOf construction) (preparedRenderer ready) info scene recorder
          }
  outcome ←
    try @SomeException $
      withLoaderIntegration $ \integration →
        runGraphicsOwnerApplication
          (withLoggingLifetime logger)
          "vulkan-native-r2d8-image"
          ( \_ use → do
              (result, verdict) ← withVulkanOwnerHost logger integration config use
              writeIORef verdictHeld (Just verdict)
              pure result
          )
          vulkanWindowHost
          (\vulkan _ → pure vulkan)
          (\vulkan control → body vulkan control directory entries owner keep preparedHeld adapterSlot factsHeld)
  finished ← getCurrentTime
  verdict ← readIORef verdictHeld
  calls ← reverse <$> readIORef recorded
  logs ← readTVarIO logged
  let errors = [maybe "" id (Map.lookup "message" entry.entryFields) | entry ← logs, Map.lookup "severity" entry.entryFields == Just "error"]
  case outcome of
    Left failure → pure (Image2dFailed (Text.pack (displayException failure)))
    Right () →
      readIORef factsHeld >>= \case
        Nothing → pure (Image2dFailed "the loop returned without its facts")
        Just partial → do
          -- Read once the host has exited, so its retirement is in the log.
          final ← readTVarIO entries
          note journal ("rendered " <> tshow (length [() | Rendered {} ← final]) <> " frames of scenes; presented " <> tshow (length [() | Frame (FramePresented {}) ← final]) <> "; " <> tshow (length [() | Released {} ← final]) <> " scene revisions released")
          pure . Image2dRecorded $
            partial
              { factsLog = final
              , factsCalls = calls
              , factsVerdict = verdict
              , factsErrors = errors
              , factsSeconds = realToFrac (diffUTCTime finished started)
              }
  where
    body vulkan control directory entries owner keep preparedHeld adapterSlot factsHeld = do
      main ← myThreadId
      let controller = vulkanController vulkan
          windowHost = vulkanWindowHost vulkan
          graphics = vulkanGraphicsOwner vulkan
      atomically (writeTVar owner (Just graphics))
      readiness ← awaitWithin 10 "the owner's startup" $
        readReadiness controller >>= \case
          RootsPending → pure Nothing
          other → pure (Just other)
      case readiness of
        RootsFailed reason → stopWith ("the owner's startup failed: " <> reason)
        _ → pure ()
      -- The sample's textures, made, uploaded and registered, and the
      -- evidence over them, before the window is handed over.
      prepared ← Sample.prepare (hostOf vulkan) >>= either (\failure → stopWith ("the textures were not prepared: " <> failure)) pure
      atomically (writeTVar preparedHeld (Just prepared))
      evidence ← runEvidenceWith (hostOf vulkan) prepared directory
      note journal ("image2d probe record: " <> Text.pack (evidenceRecord evidence))
      mapM_ (\failure → note journal ("image2d evidence failed: " <> failure)) (evidenceFailure evidence)
      note journal ("image2d evidence: " <> (if evidencePassed evidence then "every check passed" else "FAILED") <> "; " <> tshow (length (evidenceProbes evidence)) <> " pixels judged, " <> tshow (length (evidenceNamed evidence)) <> " named probes")
      let stripes = preparedHandles prepared Map.! Stripes
          quadrants = preparedHandles prepared Map.! Quadrants
          handles = handlesOf prepared
      -- The adapter, over the host's public publication and release-request
      -- operations, and the hooks that reach it.
      adapter ← newAdapter (windowHostOf vulkan keep stripes) (preparedTextures prepared)
      atomically (writeTVar adapterSlot (Just adapter))
      windows ← atomically (hostWindowIdentities windowHost)
      window ← case windows of
        [one] → pure one
        other → stopWith ("the host holds " <> tshow (length other) <> " windows, not one")
      service ←
        handOverVulkanTarget vulkan window RequiredTarget >>= \case
          VulkanTargetHandedOver handed → pure handed
          other → stopWith ("the window was not handed over: " <> tshow other)
      standing ← awaitWithin 10 "the target's admission" $
        readTargetStanding graphics (graphicsAttachment service) >>= \case
          Just TargetConstructing → pure Nothing
          Nothing → pure Nothing
          Just other → pure (Just other)
      when (standing /= TargetUsable) (stopWith ("the target was not admitted: " <> tshow standing))
      let layout = Layout (320, 240) 1
          snapshotOf referencing = snapshotFor WindowTarget referencing layout
          showing = snapshotOf handles
          without = snapshotOf handles {handleKtx2 = quadrants}
          presenting = atomically (maybe False ((== Presenting) . viewCondition) <$> readVulkanGenerations controller (graphicsAttachment service))
          publishChecked label snapshot =
            publish2DSnapshot adapter window snapshot >>= \answer → do
              keep (Marker label)
              pure answer
          completedRounds = atomically (statusRounds <$> readOwnerStatusNow graphics)
          demand =
            atomically (hostWindowClient windowHost window) >>= \case
              Nothing → pure ()
              Just client → () <$ publishDemand (clientDemandPublisher client) immediateDemand
      publications ← newTVarIO []
      refusal ← newTVarIO Nothing
      phase ← newTVarIO Preparing
      limit ← addUTCTime (realToFrac lifecycleSeconds) <$> getCurrentTime
      _ ← pure completedRounds
      runVulkanOwnerLoop vulkan control . defaultScheduledHooks quiet $ \_ → do
        now ← getCurrentTime
        when (now > limit) $ do
          current ← readTVarIO phase
          note journal ("the lifecycle reached its deadline in phase " <> phaseName current)
          stopWith ("the lifecycle did not finish within " <> tshow lifecycleSeconds <> " seconds")
        current ← readTVarIO phase
        log' ← readTVarIO entries
        case current of
          Preparing → do
            ready ← presenting
            let adoptedInitial = [() | Adopted at 0 _ ← log', at == window]
            when (ready && not (null adoptedInitial)) $ do
              published ← publishChecked "published the snapshot showing both images" showing
              atomically (modifyTVar' publications (<> [published]))
              note journal ("published the showing snapshot: " <> tshow published)
              atomically (writeTVar phase PublishedShowing)
          PublishedShowing → do
            -- Adopted as revision 1, and a frame of it recorded.
            let adopted = [() | Adopted at 1 refs ← log', at == window, Set.member stripes refs]
                framed = [() | Rendered 1 refs ← log', Set.member stripes refs]
            when (not (null adopted) && not (null framed)) $ do
              keep (Marker "requested the release of the KTX2 image's texture")
              requested ← release2DTexture adapter stripes
              either (\failure → stopWith ("the release was refused: " <> tshow failure)) pure requested
              -- A snapshot naming the released texture is refused, naming it.
              answer ← publishChecked "offered a snapshot naming the released texture" showing
              atomically (writeTVar refusal (Just answer))
              atomically (modifyTVar' publications (<> [answer]))
              note journal ("offered a snapshot naming the released texture: " <> tshow answer)
              atomically (writeTVar phase ReleaseRequested)
              demand
          ReleaseRequested → do
            -- The release ran with the showing snapshot adopted, and the
            -- window rendered that snapshot, showing the texture, afterwards.
            let after = dropWhile (/= Marker "requested the release of the KTX2 image's texture") log'
                ran = findIndex (\case ReleaseRan _ → True; _ → False) after
                rendered = case ran of
                  Nothing → False
                  Just at → not (null [() | Rendered 1 refs ← drop at after, Set.member stripes refs])
            when (ran /= Nothing && rendered) $ do
              published ← publishChecked "published the snapshot without the texture" without
              atomically (modifyTVar' publications (<> [published]))
              note journal ("published the snapshot without the released texture: " <> tshow published)
              atomically (writeTVar phase PublishedWithout)
            when (ran /= Nothing && not rendered) demand
            when (ran == Nothing) demand
          PublishedWithout → do
            let ranAfterRelease = case elemIndex (Released window 1) log' of
                  Nothing → False
                  Just at → not (null [() | ReleaseRan _ ← drop at log'])
            when ranAfterRelease (atomically (writeTVar phase Done))
            demand
          Done → pure ()
        ended ← readTVarIO phase
        case ended of
          Done → do
            published ← readTVarIO publications
            answer ← readTVarIO refusal
            pending ← pendingReleases adapter
            writeIORef factsHeld . Just $
              Facts
                { factsLog = []
                , factsEvidence = evidence
                , factsStripes = stripes
                , factsQuadrants = quadrants
                , factsRefusal = maybe (Left NoWindowPass) id answer
                , factsPublications = published
                , factsPending = pending
                , factsCalls = []
                , factsMainThread = main
                , factsVerdict = Nothing
                , factsErrors = []
                , factsSeconds = 0
                }
            pure (FinishWith ())
          _ → pure (ContinueWith NoUpdateDemand)
    quiet = recordingLogger (\_ → pure ())
    phaseName = \case
      Preparing → "preparing"
      PublishedShowing → "published the showing snapshot"
      ReleaseRequested → "release requested"
      PublishedWithout → "published the snapshot without the texture"
      Done → "done"
    evidenceDirectory =
      lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE" >>= \case
        Just evidence | not (null evidence) → pure (evidence </> "image2d")
        _ → do
          temporary ← getTemporaryDirectory
          stamp ← (round . (* 1000) . utcTimeToPOSIXSeconds ∷ UTCTime → Integer) <$> getCurrentTime
          pure (temporary </> ("hetoimasia-image2d-" <> show stamp))

-- | The adapter's host record over the production host: its public
-- publication and release-request operations. The release is wrapped to log,
-- on the owner's thread and from the real table, whether the KTX2 image's
-- handle still resolves after it ran.
windowHostOf ∷ VulkanHost Scene2D → (Entry → IO ()) → Api.TextureHandle → Host WindowId
windowHostOf vulkan keep watched =
  Host
    { hostPublish = \window scene →
        prepare scene >>= publishVulkanWindowScene vulkan window >>= \case
          WindowScenePublished _ revision → pure (HostPublished revision)
          WindowSceneUnknown _ → pure HostWindowUnknown
          WindowSceneClosed _ → pure HostClosed
          WindowScenesNotEnabled _ → pure HostSharedScenes
    , hostRequestRelease = \body →
        atomically (requestVulkanRelease vulkan (VulkanAction (logged body))) >>= \case
          Left refusal → pure (Left (tshow refusal))
          Right _ → pure (Right ())
    , hostRunOnOwner = \body →
        atomically (submitVulkanAction vulkan (VulkanAction (logged body))) >>= \case
          Left refusal → pure (Left (tshow refusal))
          Right _ → pure (Right ())
    }
  where
    -- The release, then whether the handle still resolves, read from the real
    -- table on the owner's thread.
    logged ∷ ReleaseBody → Construction q inst msgr phys dev cmd → IO (Either Refusal ())
    logged body construction = do
      answer ← body (renderBuildersOf construction)
      table ← readConstructedTable construction
      keep (ReleaseRan (resolves table))
      pure answer
    resolves = \case
      Nothing → False
      Just view → case Map.lookup (handleIndex watched) (tableViewMapping view) of
        Just entry → entryGeneration entry == handleGeneration watched && entryGeneration entry /= 0
        Nothing → False

-- | The renderer's constructions, from the host's.
renderBuildersOf ∷ Construction q inst msgr phys dev cmd → Render.Builders q inst msgr phys dev cmd
renderBuildersOf construction =
  Render.Builders
    { Render.buildRing = constructRing construction
    , Render.buildTable = constructTextureTable construction
    , Render.buildTableLayout = constructShaderSampledTablePipelineLayout construction
    , Render.buildPipeline = constructBlendedCheckedPipeline construction
    , Render.registerImage = registerConstructedTexture construction
    , Render.swapImage = swapConstructedTexture construction
    , Render.releaseImage = releaseConstructedTexture construction
    }

-- | The sample's constructions, from the host's.
buildersOf ∷ Construction q inst msgr phys dev cmd → Builders q inst msgr phys dev cmd
buildersOf construction =
  Builders
    { renderBuilders = renderBuildersOf construction
    , buildImage = constructImage construction
    , buildReadback = constructReadback construction
    , inspectTable = readConstructedTable construction
    }

-- | The sample's host over this suite's session: owner-thread actions over its
-- constructions, uploads admitted from the main thread and waited for, and
-- batches waited for, each wait bounded by a deadline.
hostOf ∷ VulkanHost scene → Sample.Host
hostOf vulkan =
  Sample.Host
    { Sample.hostAct = \what body → act what (VulkanAction (body . buildersOf))
    , Sample.hostRecord = \what body →
        act
          what
          ( VulkanAction
              ( \construction →
                  body (buildersOf construction) >>= \case
                    Left refusal → pure (Left refusal)
                    Right recording →
                      constructFramelessBatch construction recording >>= \case
                        Left refusal → pure (Left refusal)
                        Right (_, Left refusal) → pure (Left refusal)
                        Right (ticket, Right ()) → pure (Right ticket)
              )
          )
    , Sample.hostUpload = \request →
        submitVulkanUpload vulkan request >>= \case
          Left refusal → pure (Left (tshow refusal))
          Right ticket →
            awaitUploadTicket ticket deadline >>= \case
              Right UploadComplete → pure (Right ())
              other → pure (Left (tshow other))
    , Sample.hostAwait = \ticket →
        awaitTicket ticket deadline >>= \case
          Right TicketComplete → pure (Right ())
          other → pure (Left (tshow other))
    , Sample.hostRead = \readback count → act "reading the readback" (VulkanAction (\construction → readConstructedReadback construction readback 0 count))
    }
  where
    act ∷ Text → VulkanAction (Either Refusal a) → IO (Either Text a)
    act what action =
      atomically (submitVulkanAction vulkan action) >>= \case
        Left refusal → pure (Left (what <> " was refused: " <> tshow refusal))
        Right ticket →
          atomically (awaitVulkanAction ticket) >>= \case
            ActionReturned (Right value) → pure (Right value)
            ActionReturned (Left refusal) → pure (Left (what <> " was refused: " <> tshow refusal))
            ActionRaised failure → pure (Left (what <> " raised: " <> tshow failure))
            ActionRefused refusal → pure (Left (what <> " was refused before it ran: " <> tshow refusal))

deadline ∷ Duration
deadline = either (error . show) id (durationFromNanoseconds AllowZero 10000000000)

uploadConfig ∷ UploadConfig
uploadConfig = either (error . show) id (validateUploadConfig (1024 * 1024) (128 * 1024) 8)

-- | The record's section.
image2dSection ∷ Image2dOutcome → [Text]
image2dSection = \case
  Image2dFailed reason → ["", "## The image2d case did not complete", "", reason]
  Image2dRecorded facts →
    let evidence = factsEvidence facts
        probes = evidenceProbes evidence
     in [ ""
        , "## The image2d evidence and texture lifecycle"
        , ""
        , "- evidence: " <> (if evidencePassed evidence then "every check passed" else "FAILED")
        , "- probe record: " <> Text.pack (evidenceRecord evidence) <> ", capture: " <> maybe "none" Text.pack (evidencePng evidence)
        , "- pixels judged: " <> tshow (length probes) <> ", named probes: " <> tshow (length (evidenceNamed evidence))
        , "- swap demonstration: " <> tshow (evidenceSwap evidence)
        , "- publication naming the released texture: " <> tshow (factsRefusal facts)
        , "- publications: " <> tshow (factsPublications facts)
        , "- lifecycle: " <> tshow [entry | entry ← factsLog facts, isLifecycle entry]
        , "- pending releases at the end: " <> tshow (Set.size (factsPending facts))
        , "- Vulkan calls: " <> tshow (length (vulkanCalls facts)) <> ", on " <> tshow (length (nub (map (.callHaskellThread) (vulkanCalls facts)))) <> " thread(s)"
        , "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) (factsVerdict facts)
        , "- error reports: " <> tshow (length (factsErrors facts))
        , "- seconds, from the loader integration to the verdict: " <> Text.pack (show (factsSeconds facts))
        ]
  where
    isLifecycle = \case
      Adopted {} → True
      Released {} → True
      ReleaseRan {} → True
      Marker {} → True
      _ → False

vulkanCalls ∷ Facts → [NativeCall]
vulkanCalls facts = [call | call ← factsCalls facts, "vk" `Text.isPrefixOf` call.callName]

spec ∷ Image2dOutcome → Spec
spec outcome = describe "R2D-8 the image2d sample" $ do
  it "rendered the frame offscreen and passed every determinate oracle probe, with at least one" $
    on outcome $ \facts → do
      let evidence = factsEvidence facts
      evidenceFailure evidence `shouldBe` Nothing
      length (evidenceProbes evidence) `shouldSatisfy` (> 0)
      evidencePassed evidence `shouldBe` True

  it "read every named probe of the PNG's world copy, the PNG's UI copy, the KTX2 copy and the clear background as the colour stated by hand" $
    on outcome $ \facts → do
      let named = evidenceNamed (factsEvidence facts)
      [probeBehaviour (namedProbe result) | result ← named, not (namedHeld result && namedAgreed result && namedDistinguishes result)] `shouldBe` []
      length named `shouldSatisfy` (>= 15)

  it "refused a swap to an image whose computed mark differs, naming both marks, kept the mark, and accepted the swap with the registered mark explicitly kept" $
    on outcome $ \facts →
      evidenceSwap (factsEvidence facts) `shouldBe` Just (SwapDemonstration (Just (True, False)) (Just True) True (Just True))

  it "kept the released texture mapped in the table while the adopted snapshot showed it, and rendered that snapshot with it afterwards" $
    on outcome $ \facts → do
      let log' = factsLog facts
          requested = elemIndex (Marker "requested the release of the KTX2 image's texture") log'
          firstRun = requested >>= \at → (+ (at + 1)) <$> findIndex isRun (drop (at + 1) log')
          secondRelease = elemIndex (Released (windowOf facts) 1) log'
      requested `shouldSatisfy` (/= Nothing)
      firstRun `shouldSatisfy` (/= Nothing)
      -- Every run before the showing snapshot's release found the texture mapped.
      [mapped | (at, ReleaseRan mapped) ← zip [0 ∷ Int ..] log', maybe False (at <) secondRelease] `shouldSatisfy` (\runs → not (null runs) && and runs)
      -- And the window rendered the showing snapshot, with the texture, after the first run.
      case firstRun of
        Nothing → expectationFailure "the release never ran"
        Just at → [() | Rendered 1 refs ← drop at log', Set.member (factsStripes facts) refs] `shouldSatisfy` (not . null)

  it "released the texture in the table only after a snapshot without it was adopted and the snapshot that showed it was released" $
    on outcome $ \facts → do
      let log' = factsLog facts
          without = findIndex (\case Adopted at revision refs → at == windowOf facts && revision >= 2 && not (Set.member (factsStripes facts) refs); _ → False) log'
          showingReleased = elemIndex (Released (windowOf facts) 1) log'
          unmapped = [at | (at, ReleaseRan False) ← zip [0 ∷ Int ..] log']
      without `shouldSatisfy` (/= Nothing)
      showingReleased `shouldSatisfy` (/= Nothing)
      take 1 unmapped `shouldSatisfy` (\found → not (null found))
      case (without, showingReleased, unmapped) of
        (Just adopted, Just released, first : _) → do
          adopted < released `shouldBe` True
          released < first `shouldBe` True
        _ → expectationFailure "the release did not take effect"
      factsPending facts `shouldBe` Set.empty

  it "refused publishing a snapshot that names the released texture, naming it, and published one without it" $
    on outcome $ \facts → do
      factsRefusal facts `shouldBe` Left (TextureReleasedInSnapshot (factsStripes facts))
      [revision | Right revision ← factsPublications facts] `shouldBe` [1, 2]

  it "made every Vulkan call on the graphics owner's thread, and every surface creation on the main thread" $
    on outcome $ \facts → do
      let threads = nub (map (.callHaskellThread) (vulkanCalls facts))
      length threads `shouldBe` 1
      threads `shouldSatisfy` notElem (factsMainThread facts)
      [call.callHaskellThread | call ← factsCalls facts, call.callName == "glfwCreateWindowSurface"] `shouldSatisfy` all (== factsMainThread facts)

  it "reached a verdict after the last callback with no issue and no error" $
    on outcome $ \facts → do
      fmap verdictIssues (factsVerdict facts) `shouldBe` Just []
      factsErrors facts `shouldBe` []
  where
    on = \case
      Image2dFailed reason → const (expectationFailure (Text.unpack reason))
      Image2dRecorded facts → ($ facts)
    isRun = \case
      ReleaseRan _ → True
      _ → False
    windowOf facts = head' [at | Adopted at _ _ ← factsLog facts]
    head' = \case
      one : _ → one
      [] → error "the case adopted no scene"

-- ---------------------------------------------------------------------------
-- Helpers

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
