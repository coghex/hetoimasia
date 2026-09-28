-- | The loop adapter (VK-16): the main thread's scheduled owner loop composed
-- with the supervised graphics owner, without a second engine loop.
--
-- 'runVulkanOwnerLoop' is the GLFW package's 'runScheduledOwnerLoop' over the
-- host's window host, with the application's own hooks, and one addition to
-- every turn: once the application's update opportunity has returned, the main
-- thread hands the graphics owner what it needs and takes back what the owner
-- published, and performs no GPU work of its own.
--
-- = What each turn does
--
-- 1. __Observations.__ For every window with an attachment, the window's
--    latest observation is published to the owner's latest-value slot for
--    that attachment, with the render eligibility the main thread classified
--    it as, whenever it is newer than the one last published. The owner folds
--    it on its own next round.
-- 2. __Render demand.__ Every such window's demand slot is captured — which is
--    the acknowledgement its publisher is owed — and the requests are combined
--    and published to the owner's demand snapshot. A snapshot keeps only its
--    latest value, so what was published and not yet taken into an owner step
--    ('readOwnerDemandTaken') is kept and published again with anything newer:
--    a newer publication never replaces demand the owner has not seen. Once
--    the owner has taken it, it is forgotten. A closed snapshot — the owner's
--    admission has ended — settles it: nothing will render it.
-- 3. __Replacement surfaces.__ Every replacement surface the owner asked for
--    to recover a lost one is created, under its target's attachment
--    ('replaceVulkanSurfaces').
-- 4. __The owner's deadline.__ The earliest absolute instant the owner last
--    published is folded into the schedule the application's update answered,
--    so the turn's wait is bounded by it: a pending GPU obligation bounds the
--    main loop's idle wait. It can shorten that wait and never lengthen it,
--    and one that has already passed is left out, since the owner schedules
--    its own rounds and wakes the host after each; the main thread performs
--    none of that work.
--
-- = During a main-thread stall
--
-- A platform modal loop inside the native event call stalls every step above:
-- no observation, demand or replacement is published until the call returns,
-- and window commands wait for the pump as they always did. The graphics owner
-- is not stalled by it: it keeps rendering what it holds — the last coherent
-- observation, the extent the surface's capabilities supply, the latest scene
-- any other thread published — on its own deadlines. See docs/glfw.md.
--
-- = Who else may publish
--
-- An application that runs this loop leaves observation publication and
-- window demand capture to it: an observation published by hand at a higher
-- revision would make every later one of the adapter's stale, and a demand
-- slot the application captured itself would never reach the owner.
module Hetoimasia.GPU.Vulkan.GLFW.Internal.Loop
  ( runVulkanOwnerLoop
  , vulkanLoopHooks
  , LoopAdapter
  , newLoopAdapter
  , adapterTurn
  , foldOwnerDeadline
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO, writeTVar)
import Control.Monad (forM, void, when)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Numeric.Natural (Natural)

import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (Publication (..), observedValue, readSnapshot)
import Hetoimasia.Foundation.Time (Instant, deadlineReached)
import Hetoimasia.GLFW.Command (clientObservations)
import Hetoimasia.GLFW.Demand (CapturedDemand (..), DemandRequest, demandDeadline, demandIsImmediate, demandRequested, noDemand)
import Hetoimasia.GLFW.Window (observedRevision)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller (VulkanHost (..), replaceVulkanSurfaces)
import Hetoimasia.Runtime.GLFW
  ( AttachmentId
  , OwnerDemand (..)
  , OwnerStatus (..)
  , ScheduledHooks (..)
  , ScheduledStep (..)
  , ScheduledTurn (..)
  , UpdateSchedule (..)
  , captureWindowDemand
  , graphicsAttachment
  , hostWindowClient
  , hostWindowIdentities
  , ownerHandoff
  , publishGraphicsObservation
  , publishOwnerDemand
  , readOwnerDemandTaken
  , readOwnerStatusNow
  , runScheduledOwnerLoop
  , windowGraphicsService
  , windowRenderEligibility
  )
import Hetoimasia.Runtime.Supervision (RuntimeControl)

-- | What the adapter keeps between turns, on the main thread alone.
data LoopAdapter scene = LoopAdapter
  { adapterHost ∷ !(VulkanHost scene)
  , adapterPublished ∷ !(TVar (Map AttachmentId Natural))
    -- ^ The observation revision last published for each attachment.
  , adapterOutstanding ∷ !(TVar DemandRequest)
    -- ^ Demand published and not yet taken into an owner step.
  }

newLoopAdapter ∷ VulkanHost scene → IO (LoopAdapter scene)
newLoopAdapter host = LoopAdapter host <$> newTVarIO Map.empty <*> newTVarIO noDemand

-- | Run the scheduled owner loop over this host with the graphics owner
-- composed in. It must run on the process main thread, as the loop does.
runVulkanOwnerLoop ∷ VulkanHost scene → RuntimeControl → ScheduledHooks a → IO a
runVulkanOwnerLoop host control hooks = do
  adapter ← newLoopAdapter host
  runScheduledOwnerLoop (vulkanWindowHost host) control (vulkanLoopHooks adapter hooks)

-- | The application's hooks with the adapter's work added to every turn,
-- after the application's update opportunity.
vulkanLoopHooks ∷ LoopAdapter scene → ScheduledHooks a → ScheduledHooks a
vulkanLoopHooks adapter hooks =
  hooks
    { scheduledUpdate = \turn → do
        step ← scheduledUpdate hooks turn
        adapterTurn adapter
        case step of
          FinishWith result → pure (FinishWith result)
          ContinueWith schedule → ContinueWith <$> foldOwnerDeadline adapter (scheduledNow turn) schedule
    }

-- | One turn's handoffs: observations, render demand and replacement
-- surfaces. It runs on the main thread and waits for nothing.
adapterTurn ∷ LoopAdapter scene → IO ()
adapterTurn adapter = do
  attached ← atomically $ do
    windows ← hostWindowIdentities windowHost
    fmap catMaybes . forM windows $ \window → fmap ((,) window) <$> windowGraphicsService windowHost window
  -- Observations.
  published ← readTVarIO (adapterPublished adapter)
  latest ← fmap catMaybes . forM attached $ \(window, service) → do
    client ← atomically (hostWindowClient windowHost window)
    case client of
      Nothing → pure Nothing
      Just held → do
        observation ← preparedValue . observedValue <$> atomically (readSnapshot (clientObservations held))
        -- The attachment's revisions start after the slot's initial zero, and
        -- rise with the window's own.
        let revision = observedRevision observation + 1
            attachment = graphicsAttachment service
        when (maybe True (< revision) (Map.lookup attachment published)) $
          void (publishGraphicsObservation owner service revision observation (windowRenderEligibility observation) Nothing)
        pure (Just (attachment, revision))
  -- Only attachments still held are remembered, so the record is bounded by
  -- the windows the host holds.
  atomically (writeTVar (adapterPublished adapter) (Map.fromList latest))
  -- Render demand.
  captured ← mconcat . map capturedRequest . catMaybes <$> forM attached (captureWindowDemand windowHost . fst)
  atomically $ do
    taken ← readOwnerDemandTaken owner
    when taken (writeTVar (adapterOutstanding adapter) noDemand)
    modifyTVar' (adapterOutstanding adapter) (<> captured)
  when (demandRequested captured) $ do
    outstanding ← readTVarIO (adapterOutstanding adapter)
    demand ← prepare (OwnerDemand (demandIsImmediate outstanding) (demandDeadline outstanding))
    atomically $
      publishOwnerDemand (ownerHandoff owner) demand >>= \case
        Published → pure ()
        -- The owner's admission has ended: nothing will render it.
        PublicationClosed → writeTVar (adapterOutstanding adapter) noDemand
  -- Replacement surfaces.
  void (replaceVulkanSurfaces (vulkanController host) windowHost owner)
  where
    host = adapterHost adapter
    windowHost = vulkanWindowHost host
    owner = vulkanGraphicsOwner host

-- | Fold the owner's published deadline into the schedule, when it is still
-- ahead of now: it can only make the schedule earlier.
foldOwnerDeadline ∷ LoopAdapter scene → Instant → UpdateSchedule → IO UpdateSchedule
foldOwnerDeadline adapter now schedule = do
  status ← atomically (readOwnerStatusNow (vulkanGraphicsOwner (adapterHost adapter)))
  pure $ case statusNextDeadline status of
    Just due | not (deadlineReached now due) → case schedule of
      UpdateImmediately → UpdateImmediately
      UpdateBy at → UpdateBy (min at due)
      NoUpdateDemand → UpdateBy due
    _ → schedule
