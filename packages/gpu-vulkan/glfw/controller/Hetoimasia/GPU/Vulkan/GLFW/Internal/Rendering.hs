{-# LANGUAGE RankNTypes #-}

-- | Rendering in the graphics owner's step (VK-16): the recording and the
-- frames composed into the controller, render demand turned into frames, and
-- the owner's own pacing of completion polls and acquisition retries.
--
-- The controller ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller") calls
-- every function here on the graphics owner's thread, from its progress step
-- and its target retirement, and nothing here makes a GLFW call.
--
-- = What makes a frame wanted
--
-- The graphics owner hands each step the latest render demand the main thread
-- published and the latest scene any application thread published, each with
-- the revision of its publication. A target is asked for a frame — the GPU
-- model's 'requestRender', which is also what restarts the idle backoff — when
--
-- * a demand publication it has not acted on is due: immediate, or with a
--   deadline that has come (one still ahead is kept, and asked for when it
--   comes);
-- * a scene publication it has not rendered arrives; or
-- * a target that has shown a frame before can no longer be showing the
--   latest one: its active swapchain generation is not the one its last
--   presentation went to, or it has become eligible again after a suspension.
--
-- Nothing else asks for a frame. In particular a target nobody asked a frame
-- of is never rendered to, however its generations change, so a host whose
-- application publishes neither demand nor a scene presents nothing.
--
-- = Rendering one frame
--
-- A target the model says wants a frame — render demand, admitted and not
-- suspended — is offered one attempt per step, round-robin with the lead
-- rotating each step: an acquisition with a zero timeout, then the renderer
-- recording the frame between the transition into rendering and the one to
-- presentation, then one submission and one presentation. An acquisition the
-- swapchain cannot answer yet is retried at the first interval of the model's
-- backoff schedule, anchored at the step's own instant, so work the step did
-- counts against it; a frame the renderer or the recording refused, or whose
-- submission had no effect, is skipped, and one whose presentation enqueued
-- nothing is closed unpresented. Every native effect's bookkeeping is the
-- frames module's own.
--
-- = Polling completion
--
-- A fence is asked only when the model's own schedule says a poll is due —
-- 'progressDeadline', which leaves render demand out — or when a frame is to
-- be attempted this step and the slots it needs may be waiting on one. An
-- owner round that something unrelated woke asks no fence, and takes no model
-- turn that would move the schedule on.
--
-- = Retirement
--
-- A target that begins retiring is closed in the model at once — which drops
-- its render demand and restarts the schedule — and its frames are closed:
-- acquired ones skipped, submitted ones closed unpresented. Its retirement is
-- owed ('RetirementOwed') until every frame and presentation of it has gone on
-- its own evidence; only then are its synchronization, its frame storages,
-- its generations and its surface destroyed. After the device's loss nothing
-- is waited for: the frames let go of what only the lost device could have
-- discharged.
--
-- = State
--
-- +---------------------+-----------+------------------------------------+--------+------------------------------+------------------------------+
-- | State               | Owner     | Readers and writers                | Thread | Lifetime                     | Reset or disposal            |
-- +=====================+===========+====================================+========+==============================+==============================+
-- | The recording and   | This      | Made by the first frame attempted  | Owner  | The first attempt after the  | 'retireRendering', before    |
-- | the frames          | module    | once the device exists; read by    |        | device exists until          | the device is destroyed      |
-- |                     |           | every function here                |        | whole-owner retirement       |                              |
-- +---------------------+-----------+------------------------------------+--------+------------------------------+------------------------------+
-- | Per-target records  | This      | Written by the step, retirement    | Owner  | A target's first render      | Removed by                   |
-- |                     | module    | preparation and retirement; read   |        | request until its retirement | 'retireTargetRendering'      |
-- |                     |           | by the deadline                    |        |                              |                              |
-- +---------------------+-----------+------------------------------------+--------+------------------------------+------------------------------+
-- | The revisions acted | This      | The step alone                     | Owner  | The owner's run              | Never reset: revisions only  |
-- | on, and a demand    | module    |                                    |        |                              | rise                         |
-- | deadline ahead      |           |                                    |        |                              |                              |
-- +---------------------+-----------+------------------------------------+--------+------------------------------+------------------------------+
module Hetoimasia.GPU.Vulkan.GLFW.Internal.Rendering
  ( -- * The native layers
    RenderingOps (..)

    -- * The renderer
  , VulkanRenderer (..)
  , FrameRequest (..)
  , clearRenderer

    -- * Observing frames
  , FrameEvent (..)
  , FrameObserver
  , noFrameObserver

    -- * The rendering
  , Rendering
  , newRendering
  , StepInputs (..)
  , StepPlan (..)
  , planStep
  , renderDue
  , renderingDeadline
  , pollDue

    -- * Retirement
  , prepareTargetRetirement
  , retireTargetRendering
  , retireRendering

    -- * Failures
  , FrameStorageRefused (..)
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, stateTVar, writeTVar)
import Control.Exception (Exception, throwIO)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Foldable (for_)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Numeric.Natural (Natural)

import Hetoimasia.Foundation.Time (Instant, addDuration, deadlineReached)
import Hetoimasia.GPU.Model
  ( GpuModel
  , NextTurn (..)
  , Outcome (..)
  , PresentOutcome
  , TargetView (..)
  , closeTarget
  , deviceLossObserved
  , modelBudgets
  , progressDeadline
  , requestRender
  , targetView
  )
import Hetoimasia.GPU.Model.Budget (backoffSchedule, frameSlotLimit)
import Hetoimasia.GPU.Model.Identity (FrameSlotId, GenerationId, ImageId, PresentationId, SubmissionId, TargetId, imageGeneration, presentationTarget, frameTarget)
import Hetoimasia.GPU.Vulkan.Native.Frames
  ( Acquisition (..)
  , FrameOps
  , FrameStanding (..)
  , Frames
  , OwnedFrame (..)
  , PendingReason
  , PresentationStanding (..)
  , Presented (..)
  , Progress (..)
  , Submitted (..)
  , closeTargetFrames
  , closeUnpresentedFrame
  , newFrames
  , presentFrame
  , progressFrames
  , readFrameStandings
  , readPresentations
  , retireTargetFrames
  , skipFrame
  , submitFrames
  , tryAcquireFrame
  )
import Hetoimasia.GPU.Vulkan.Native.Generations
  ( GenerationView (..)
  , Generations
  , TargetGenerationsView (..)
  , readTargetGenerations
  , stepGenerations
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (GenerationPlan (..), SurfaceExtent)
import Hetoimasia.GPU.Vulkan.Native.Profile (DevicePlan (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( ClearColor
  , FrameStorage
  , ImageLayout (..)
  , Recorder
  , Recording
  , RecordingOps
  , Refusal
  , beginRendering
  , createFrameStorage
  , disposeResources
  , endRendering
  , newRecording
  , recordFrame
  , releaseManaged
  , retireRecording
  , transitionImage
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (Roots, readRootsDevice, readRootsModel, stateRootsModel)
import Hetoimasia.Runtime.GLFW (AttachmentId, OwnerDemand (..))

-- ---------------------------------------------------------------------------
-- The native layers

-- | The native layers rendering adds to the roots': the recording's, made
-- from the session's physical device once it has been selected, and the
-- frames'. Production supplies "Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan"
-- and "Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan"; the headless examples
-- supply stand-ins.
data RenderingOps phys dev cmd = RenderingOps
  { renderingRecordingOps ∷ phys → IO (RecordingOps dev cmd)
  , renderingFrameOps ∷ FrameOps dev cmd
  }

-- ---------------------------------------------------------------------------
-- The renderer

-- | What one frame is being recorded for.
data FrameRequest = FrameRequest
  { requestAttachment ∷ !AttachmentId
  , requestTarget ∷ !TargetId
  , requestFrame ∷ !FrameSlotId
  , requestImage ∷ !ImageId
  , requestExtent ∷ !SurfaceExtent
    -- ^ The extent of the generation the image belongs to.
  , requestSceneRevision ∷ !Natural
    -- ^ The revision of the scene being rendered, zero for the owner's
    -- initial one.
  }
  deriving (Eq, Show)

-- | How a frame of the scene is recorded, on the graphics owner's thread.
--
-- The image is already in the color-attachment layout when it is called, and
-- is transitioned for presentation after it returns: the renderer begins
-- dynamic rendering, records into it and ends it. An answer of 'Left', or a
-- command it left refused, skips the frame; nothing it recorded is submitted.
-- It runs exactly once per frame and must return finitely.
newtype VulkanRenderer scene = VulkanRenderer
  { renderScene ∷ ∀ q inst msgr phys dev cmd. scene → FrameRequest → Recorder q inst msgr phys dev cmd → IO (Either Refusal ())
  }

-- | A renderer that clears each frame to the color it computes and draws
-- nothing else.
clearRenderer ∷ (scene → FrameRequest → ClearColor) → VulkanRenderer scene
clearRenderer color = VulkanRenderer $ \scene request recorder →
  beginRendering recorder (color scene request) `andThen` endRendering recorder

andThen ∷ IO (Either Refusal ()) → IO (Either Refusal ()) → IO (Either Refusal ())
andThen first second = first >>= either (pure . Left) (const second)

-- ---------------------------------------------------------------------------
-- Observing frames

-- | Something the owner did with a frame, or observed about one, in the order
-- it happened. Each is reported on the graphics owner's thread as it happens:
-- a presentation's request before its call and its return after it, and a
-- present fence's completion when a poll observed it — independently of any
-- call's return.
data FrameEvent
  = FrameAcquired !AttachmentId !FrameSlotId !ImageId
  | FramePending !AttachmentId !PendingReason
  | FrameSubmitted !AttachmentId !FrameSlotId !SubmissionId
  | FramePresentRequested !AttachmentId !FrameSlotId !ImageId !Natural
    -- ^ About to present, with the scene revision the frame rendered.
  | FramePresented !AttachmentId !FrameSlotId !PresentationId !PresentOutcome
    -- ^ The present call returned with a presentation enqueued. It proves the
    -- request was admitted, nothing more.
  | FrameAbandoned !AttachmentId !FrameSlotId !Text
  | SubmissionCompleted !SubmissionId
  | PresentationRetired !PresentationId
    -- ^ The presentation's present fence was observed signalled.
  deriving (Eq, Show)

-- | Where frame events go. It must not raise and should not block: it runs on
-- the graphics owner's thread, between native calls.
type FrameObserver = FrameEvent → IO ()

noFrameObserver ∷ FrameObserver
noFrameObserver _ = pure ()

-- ---------------------------------------------------------------------------
-- The rendering

data Live q inst msgr phys dev cmd = Live
  { liveRecording ∷ !(Recording q inst msgr phys dev cmd)
  , liveFrames ∷ !(Frames q inst msgr phys dev cmd)
  }

-- | One target as rendering holds it.
data TargetRendering = TargetRendering
  { targetStorages ∷ ![FrameStorage]
  , targetRetryAt ∷ !(Maybe Instant)
    -- ^ When an acquisition the swapchain could not answer is tried again.
  , targetShown ∷ !(Maybe GenerationId)
    -- ^ The generation the target's last presentation went to, once it has
    -- presented one.
  , targetEligible ∷ !Bool
    -- ^ Whether it was eligible at the last step.
  , targetClosing ∷ !Bool
  }

freshTarget ∷ TargetRendering
freshTarget = TargetRendering [] Nothing Nothing False False

-- | The rendering of one graphics session.
data Rendering q inst msgr phys dev cmd = Rendering
  { renderingRoots ∷ !(Roots q inst msgr phys dev)
  , renderingGenerations ∷ !(Generations q inst msgr phys dev)
  , renderingOps ∷ !(RenderingOps phys dev cmd)
  , renderingLive ∷ !(TVar (Maybe (Live q inst msgr phys dev cmd)))
  , renderingTargets ∷ !(TVar (Map TargetId TargetRendering))
  , renderingDemandSeen ∷ !(TVar Natural)
  , renderingSceneSeen ∷ !(TVar Natural)
  , renderingDemandAt ∷ !(TVar (Maybe Instant))
  , renderingCursor ∷ !(TVar Natural)
  , renderingObserver ∷ !FrameObserver
  }

newRendering
  ∷ Roots q inst msgr phys dev
  → Generations q inst msgr phys dev
  → RenderingOps phys dev cmd
  → FrameObserver
  → IO (Rendering q inst msgr phys dev cmd)
newRendering roots generations ops observer =
  Rendering roots generations ops
    <$> newTVarIO Nothing
    <*> newTVarIO Map.empty
    <*> newTVarIO 0
    <*> newTVarIO 0
    <*> newTVarIO Nothing
    <*> newTVarIO 0
    <*> pure observer

-- | The recording and the frames, made the first time they are needed once
-- the device exists, on the owner's thread, which is what makes it their
-- owner.
live ∷ Rendering q inst msgr phys dev cmd → IO (Maybe (Live q inst msgr phys dev cmd))
live rendering =
  readTVarIO (renderingLive rendering) >>= \case
    Just made → pure (Just made)
    Nothing →
      atomically (readRootsDevice (renderingRoots rendering)) >>= \case
        Nothing → pure Nothing
        Just (plan, _) → do
          ops ← renderingRecordingOps (renderingOps rendering) (planDevice plan)
          recording ← newRecording ops (renderingRoots rendering) (renderingGenerations rendering)
          frames ← newFrames (renderingFrameOps (renderingOps rendering)) recording
          let made = Live recording frames
          atomically (writeTVar (renderingLive rendering) (Just made))
          pure (Just made)

-- | A frame storage could not be made for a target's slot. It is raised, and
-- ends the owner's run like any other owner failure: a target whose slots
-- cannot be recorded into renders nothing.
data FrameStorageRefused = FrameStorageRefused !TargetId !Natural !Refusal
  deriving (Show)

instance Exception FrameStorageRefused

-- ---------------------------------------------------------------------------
-- The step

-- | What one owner step hands the rendering.
data StepInputs = StepInputs
  { inputsNow ∷ !Instant
  , inputsSceneRevision ∷ !Natural
  , inputsDemand ∷ !OwnerDemand
  , inputsDemandRevision ∷ !Natural
  , inputsTargets ∷ ![(TargetId, AttachmentId, Bool)]
    -- ^ Every target the owner constructed, with whether it is eligible to
    -- render now.
  }

-- | What the step owes before it renders.
data StepPlan = StepPlan
  { planPolled ∷ !Bool
    -- ^ Whether this step asked the fences, which a model turn must then
    -- anchor.
  , planDue ∷ ![(TargetId, AttachmentId)]
    -- ^ The targets to offer one frame each this step, in this step's order.
  }

-- | Fold the step's demand and scene into render requests, poll completion
-- if a poll is due or a frame is to be attempted, and say which targets are
-- offered a frame.
planStep ∷ Rendering q inst msgr phys dev cmd → StepInputs → IO StepPlan
planStep rendering inputs = do
  views ← atomically (mapM (\(target, _, _) → (,) target <$> readTargetGenerations (renderingGenerations rendering) target) (inputsTargets inputs))
  atomically $ do
    wantAll ← foldPublications
    held ← readTVar (renderingTargets rendering)
    let wanted =
          [ target
          | (target, _, eligible) ← inputsTargets inputs
          , let record = Map.findWithDefault freshTarget target held
          , not (targetClosing record)
          , wantAll
              || ( isJust (targetShown record)
                     && eligible
                     && ( not (targetEligible record)
                            || maybe False (\view → viewActive view /= targetShown record && isJust (viewActive view)) (lookup target views >>= id)
                        )
                 )
          ]
    for_ wanted $ \target →
      stateRootsModel (renderingRoots rendering) $ \model → case requestRender target model of
        Admitted next → ((), next)
        _ → ((), model)
    writeTVar (renderingTargets rendering) $
      foldl
        (\records (target, _, eligible) → Map.alter (Just . (\record → record {targetEligible = eligible}) . maybe freshTarget id) target records)
        held
        [entry | entry@(target, _, _) ← inputsTargets inputs, target `elem` wanted || Map.member target held]
  model ← atomically (readRootsModel (renderingRoots rendering))
  held ← readTVarIO (renderingTargets rendering)
  cursor ← atomically (stateTVar (renderingCursor rendering) (\at → (at, at + 1)))
  let due =
        rotated
          cursor
          [ (target, attachment)
          | (target, attachment, _) ← inputsTargets inputs
          , Just view ← [targetView target model]
          , viewTargetRenderDemand view
          , let record = Map.findWithDefault freshTarget target held
          , not (targetClosing record)
          , maybe True (deadlineReached now) (targetRetryAt record)
          ]
      polling = pollDue now model || not (null due)
  when polling (poll rendering now)
  pure (StepPlan polling due)
  where
    now = inputsNow inputs
    demand = inputsDemand inputs
    foldPublications = do
      seenDemand ← readTVar (renderingDemandSeen rendering)
      fresh ←
        if inputsDemandRevision inputs > seenDemand
          then do
            writeTVar (renderingDemandSeen rendering) (inputsDemandRevision inputs)
            case ownerDemandDeadline demand of
              Just at
                | not (ownerDemandImmediate demand) && not (deadlineReached now at) → do
                    modifyTVar' (renderingDemandAt rendering) (Just . maybe at (min at))
                    pure False
              _ → pure (ownerDemandImmediate demand || isJust (ownerDemandDeadline demand))
          else pure False
      ahead ← readTVar (renderingDemandAt rendering)
      came ← case ahead of
        Just at | deadlineReached now at → True <$ writeTVar (renderingDemandAt rendering) Nothing
        _ → pure False
      seenScene ← readTVar (renderingSceneSeen rendering)
      scened ←
        if inputsSceneRevision inputs > seenScene
          then True <$ writeTVar (renderingSceneSeen rendering) (inputsSceneRevision inputs)
          else pure False
      pure (fresh || came || scened)

-- | Whether the model's own schedule says a completion poll is due now.
pollDue ∷ Instant → GpuModel → Bool
pollDue now model = case progressDeadline model of
  TurnNow → True
  TurnAt at → deadlineReached now at
  TurnUnschedulable → True
  NoTurnNeeded → False

-- | Ask the fences, once, and report what was observed.
poll ∷ Rendering q inst msgr phys dev cmd → Instant → IO ()
poll rendering now =
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → pure ()
    Just made → do
      progress ← progressFrames (liveFrames made) now
      for_ (progressCompleted progress) (renderingObserver rendering . SubmissionCompleted)
      for_ (progressRetired progress) (renderingObserver rendering . PresentationRetired)

-- | Offer each due target one frame of the scene. Answers whether any frame
-- was presented.
renderDue
  ∷ Rendering q inst msgr phys dev cmd
  → VulkanRenderer scene
  → Instant
  → scene
  → Natural
  → [(TargetId, AttachmentId)]
  → IO Bool
renderDue rendering renderer now scene revision due =
  if null due
    then pure False
    else
      live rendering >>= \case
        Nothing → False <$ for_ due (\(target, _) → retryAfterPending target)
        Just made → or <$> forM due (renderOne made)
  where
    observe = renderingObserver rendering
    renderOne made (target, attachment) = do
      ready ← storagesFor made target
      if not ready
        then False <$ retryAfterPending target
        else
          tryAcquireFrame (liveFrames made) target >>= \case
            Right (AcquisitionOwned owned) → do
              atomically (editTarget rendering target (\record → record {targetRetryAt = Nothing}))
              observe (FrameAcquired attachment (ownedFrame owned) (ownedImage owned))
              extent ← extentOf target (ownedImage owned)
              case extent of
                Nothing → False <$ abandon made attachment owned "its generation is no longer tracked"
                Just size → recordOne made target attachment owned size
            Right (AcquisitionPending reason) → do
              observe (FramePending attachment reason)
              False <$ retryAfterPending target
            Right _ → False <$ retryAfterPending target
            Left _ → False <$ retryAfterPending target
    retryAfterPending target = do
      model ← atomically (readRootsModel (renderingRoots rendering))
      let first = case backoffSchedule (modelBudgets model) of
            interval : _ → Just interval
            [] → Nothing
          at = first >>= either (const Nothing) Just . addDuration now
      atomically (editTarget rendering target (\record → record {targetRetryAt = at}))
    storagesFor made target = do
      held ← Map.findWithDefault freshTarget target <$> readTVarIO (renderingTargets rendering)
      if not (null (targetStorages held))
        then pure True
        else do
          model ← atomically (readRootsModel (renderingRoots rendering))
          let slots = frameSlotLimit (modelBudgets model)
          made' ← forM [0 .. slots - 1] $ \slot →
            createFrameStorage (liveRecording made) target slot >>= \case
              Right storage → pure storage
              Left refusal → throwIO (FrameStorageRefused target slot refusal)
          atomically (editTarget rendering target (\record → record {targetStorages = made'}))
          pure True
    extentOf target image = do
      view ← atomically (readTargetGenerations (renderingGenerations rendering) target)
      pure $ do
        generations ← viewGenerations <$> view
        generation ← find ((== imageGeneration image) . viewGeneration) generations
        pure (planExtent (viewPlan generation))
    recordOne made target attachment owned size = do
      let request = FrameRequest attachment target (ownedFrame owned) (ownedImage owned) size revision
      recorded ←
        recordFrame (liveRecording made) (ownedFrame owned) $ \recorder →
          transitionImage recorder LayoutUndefined LayoutColorAttachment
            `andThen` renderScene renderer scene request recorder
            `andThen` transitionImage recorder LayoutColorAttachment LayoutPresentSource
      case recorded of
        Right (batch, Right ()) →
          submitFrames (liveFrames made) (batch :| []) >>= \case
            Right (SubmittedAs submission) → do
              observe (FrameSubmitted attachment (ownedFrame owned) submission)
              present made target attachment owned
            Right (SubmittedNothing reason) → False <$ abandon made attachment owned ("its submission had no effect: " <> reason)
            Left refusal → False <$ abandon made attachment owned ("its submission was refused: " <> tshow refusal)
        Right (_, Left refusal) → False <$ abandon made attachment owned ("the renderer refused: " <> tshow refusal)
        Left refusal → False <$ abandon made attachment owned ("its recording was refused: " <> tshow refusal)
    present made target attachment owned = do
      observe (FramePresentRequested attachment (ownedFrame owned) (ownedImage owned) revision)
      presentFrame (liveFrames made) (ownedFrame owned) >>= \case
        Right (PresentedAs presentation outcome) → do
          observe (FramePresented attachment (ownedFrame owned) presentation outcome)
          atomically (editTarget rendering target (\record → record {targetShown = Just (imageGeneration (ownedImage owned))}))
          pure True
        Right (PresentedNothing reason) → do
          _ ← closeUnpresentedFrame (liveFrames made) (ownedFrame owned)
          False <$ observe (FrameAbandoned attachment (ownedFrame owned) ("its presentation enqueued nothing: " <> reason))
        Left refusal → do
          _ ← closeUnpresentedFrame (liveFrames made) (ownedFrame owned)
          False <$ observe (FrameAbandoned attachment (ownedFrame owned) ("its presentation was refused: " <> tshow refusal))
    abandon made attachment owned reason = do
      _ ← skipFrame (liveFrames made) (ownedFrame owned)
      observe (FrameAbandoned attachment (ownedFrame owned) reason)

editTarget ∷ Rendering q inst msgr phys dev cmd → TargetId → (TargetRendering → TargetRendering) → STM ()
editTarget rendering target edit = modifyTVar' (renderingTargets rendering) (Map.alter (Just . edit . maybe freshTarget id) target)

-- | The earliest instant rendering owes the owner a round: a demand deadline
-- still ahead, and, for every target the model says wants a frame, the retry
-- of an acquisition that could not be answered, or now.
renderingDeadline ∷ Rendering q inst msgr phys dev cmd → Instant → IO (Maybe Instant)
renderingDeadline rendering now = atomically $ do
  ahead ← readTVar (renderingDemandAt rendering)
  held ← readTVar (renderingTargets rendering)
  model ← readRootsModel (renderingRoots rendering)
  let wanting =
        [ maybe now id (targetRetryAt record)
        | (target, record) ← Map.toList held
        , not (targetClosing record)
        , Just view ← [targetView target model]
        , viewTargetRenderDemand view
        ]
  pure $ case maybe [] pure ahead <> wanting of
    [] → Nothing
    candidates → Just (minimum candidates)

-- ---------------------------------------------------------------------------
-- Retirement

-- | Begin retiring one target, and say whether its retirement can be
-- performed now.
--
-- The first call closes the target in the model and closes its frames. Every
-- call asks the fences when a poll is due — the close itself makes one due —
-- and anchors the model's schedule with one generation step, and answers
-- 'Nothing' — ready — once no frame and no presentation of the target
-- remains, or once the device has been lost; otherwise the reason it is still
-- owed.
prepareTargetRetirement ∷ Rendering q inst msgr phys dev cmd → Instant → TargetId → IO (Maybe Text)
prepareTargetRetirement rendering now target =
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → pure Nothing
    Just made → do
      first ← atomically $ do
        record ← Map.findWithDefault freshTarget target <$> readTVar (renderingTargets rendering)
        unless (targetClosing record) $ do
          editTarget rendering target (\held → held {targetClosing = True})
          stateRootsModel (renderingRoots rendering) $ \model → case closeTarget target model of
            Admitted next → ((), next)
            _ → ((), model)
        pure (not (targetClosing record))
      when first (void (closeTargetFrames (liveFrames made) target))
      model ← atomically (readRootsModel (renderingRoots rendering))
      if deviceLossObserved model
        then pure Nothing
        else do
          when (pollDue now model) $ do
            poll rendering now
            void (stepGenerations (renderingGenerations rendering) now Map.empty)
          frames ← atomically (filter ((== target) . frameTarget . standingFrame) <$> readFrameStandings (liveFrames made))
          presentations ← atomically (filter ((== target) . presentationTarget . standingPresentation) <$> readPresentations (liveFrames made))
          pure $
            if null frames && null presentations
              then Nothing
              else
                Just
                  ( tshow (length frames)
                      <> " frames and "
                      <> tshow (length presentations)
                      <> " presentations of "
                      <> tshow target
                      <> " await their own evidence"
                  )

-- | Destroy what rendering holds for one target: its slots' synchronization
-- and its presentation pool, which raises, retaining them, if anything of the
-- target is still owed; and its frame storages, released and destroyed once
-- the model reports them unheld.
retireTargetRendering ∷ Rendering q inst msgr phys dev cmd → Instant → TargetId → IO ()
retireTargetRendering rendering now target =
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → atomically (modifyTVar' (renderingTargets rendering) (Map.delete target))
    Just made → do
      retireTargetFrames (liveFrames made) target
      storages ← maybe [] targetStorages . Map.lookup target <$> readTVarIO (renderingTargets rendering)
      forM_ storages (void . releaseManaged (liveRecording made))
      _ ← disposeResources (liveRecording made) now
      atomically (modifyTVar' (renderingTargets rendering) (Map.delete target))

-- | Retire the recording, releasing and destroying every managed resource
-- left, before the device is destroyed. Raises, retaining them, if any
-- remains.
retireRendering ∷ Rendering q inst msgr phys dev cmd → Instant → IO ()
retireRendering rendering now =
  readTVarIO (renderingLive rendering) >>= \case
    Nothing → pure ()
    Just made → retireRecording (liveRecording made) now

-- ---------------------------------------------------------------------------
-- Helpers

rotated ∷ Natural → [a] → [a]
rotated _ [] = []
rotated cursor items = drop offset items <> take offset items
  where
    offset = fromIntegral (cursor `mod` fromIntegral (length items))

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
