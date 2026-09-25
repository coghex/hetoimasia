-- | The swapchain generations of every target the roots admitted: their
-- planning, construction, replacement and destruction (VK-10).
--
-- Each generation is keyed by the GPU model's 'GenerationId', and each of its
-- images by that identity and its index. The model decides what a generation
-- owes and when it may go; this module makes the native calls, through the
-- roots' open native layer ('GenerationOps'), and records each one's result in
-- the same masked step that made it. It runs on the graphics owner's thread:
-- 'stepGenerations', 'retireTargetGenerations' and 'trackTarget' are the
-- owner's. A consumer on any thread may hold a generation's CPU use
-- ('useGeneration') and report what a swapchain call answered
-- ('noteSwapchainResult'), both in 'STM'.
--
-- = Planning
--
-- A generation is planned from what the surface reports and the target's last
-- published geometry ("Hetoimasia.GPU.Vulkan.Native.Presentation"): P-15's
-- first profile, D-30's extent, and an image count reserved against the
-- configured tracking limit. The count the driver returns is checked against
-- that limit before any image view — any array that depends on it — is built;
-- a count of zero or above the limit is refused, and the candidate is retired
-- rather than published. A surface that cannot serve the profile leaves the
-- target 'PresentationUnsupported', naming the whole gap.
--
-- = Replacement
--
-- A target is rebuilt when its geometry moves, or when a swapchain call on its
-- active generation answered out of date or suboptimal. Ordinary resize is not
-- a failed construction: the extent the plan would choose is watched, and the
-- generation is rebuilt only once it has been the same for 'settlingPeriod' on
-- the owner's monotonic clock. A zero or otherwise unusable extent suspends the
-- target and creates no attempt. An out-of-date or suboptimal result whose plan
-- is the extent the active generation already has is not a resize: rebuilding
-- it is a recovery attempt, admitted by the model's episode — at most three,
-- 100 ms and then 500 ms apart — and exhausting it is reported through the
-- target's required or optional designation. So is every construction after one
-- that failed.
--
-- Replacement hands the active generation over as @oldSwapchain@. The model
-- retires it, and this module marks it retired, before the native call, and
-- nothing undoes that: a creation that then fails leaves the target without an
-- active generation, in 'ConstructionFailed', and nothing is ever acquired from
-- or handed over as the retired one again. The next construction is a fresh
-- one, begun only once every swapchain of the target that Vulkan still counts
-- as unretired has been destroyed, and it never replays the failed call.
--
-- = Bounds
--
-- A target holds at most the model's generation limit — active, constructing
-- and retired together. At capacity, every retired generation whose holds have
-- ended is destroyed first, and the newest geometry is coalesced into the one
-- replacement that follows. A replacement that still cannot fit leaves the
-- target 'Backpressured': it is suspended in the model, and the owner and every
-- other target carry on. With a limit of one, the active generation is the only
-- thing that can be in the way, so it is retired on its own, awaited, destroyed,
-- and a fresh generation built without it. No target reserves or releases
-- anything of another's.
--
-- = Destruction
--
-- A retired generation keeps its swapchain, its images and its views until the
-- model reports every hold on it ended. Only then are its views destroyed, in
-- reverse order of creation, and then its swapchain — whose images go with it,
-- as they are the swapchain's and never destroyed on their own. The per-target
-- presentation pool is not a generation's and is untouched. A destruction that
-- raised is uncertain: the generation is marked so, never offered again, and
-- everything above it is retained, because the model's session fails with
-- 'CleanupFailed', and the roots close admission, and the step raises
-- 'GenerationDestructionFailed'. An effect whose bookkeeping could not be
-- committed enters the same path ('GenerationEffectUncertain'), and so does a
-- creation a cancellation interrupted inside its call: whether it created
-- anything is unknown, so its candidate is retained, never destroyed, and the
-- cancellation is delivered after the session has failed.
--
-- = Close
--
-- Close wins: a target the model has closed begins no construction, admits no
-- recovery attempt, and a construction that completes after the close is
-- retired rather than published. 'retireTargetGenerations' retires the active
-- generation, destroys every generation whose holds have ended, and raises
-- 'GenerationsRetained' — manufacturing no evidence — if any remains.
--
-- = State
--
-- +--------------------+-------------+--------------------------------+--------+---------------------+-----------------------------+
-- | State              | Owner       | Readers and writers            | Thread | Lifetime            | Reset or disposal           |
-- +====================+=============+================================+========+=====================+=============================+
-- | Target records     | This module | 'trackTarget' inserts;         | Owner  | Admission until the | Removed once every          |
-- |                    |             | retirement removes             |        | target's generations| generation is destroyed     |
-- |                    |             |                                |        | have gone           |                             |
-- +--------------------+-------------+--------------------------------+--------+---------------------+-----------------------------+
-- | Generation records | This module | The owner's step; any thread   | Owner  | 'beginGeneration'   | Removed by a destruction    |
-- |                    |             | holds and ends uses in 'STM'   | (uses: | until destroyed     | that returned; kept         |
-- |                    |             |                                | any)   |                     | uncertain otherwise         |
-- +--------------------+-------------+--------------------------------+--------+---------------------+-----------------------------+
-- | Swapchain results  | This module | Any thread notes; the owner's  | Any    | Until the active    | Cleared by the publication  |
-- |                    |             | step consumes                  |        | generation is       | that replaces it            |
-- |                    |             |                                |        | replaced            |                             |
-- +--------------------+-------------+--------------------------------+--------+---------------------+-----------------------------+
module Hetoimasia.GPU.Vulkan.Native.Generations
  ( -- * The generations
    Generations
  , newGenerations
  , newGenerationsHooked
  , settlingPeriod
  , trackTarget

    -- * The owner's step
  , stepGenerations
  , StepSummary (..)
  , generationsDeadline

    -- * Reports from swapchain calls
  , SwapchainResult (..)
  , noteSwapchainResult

    -- * CPU use
  , GenerationUse
  , UseRefusal (..)
  , useGeneration
  , endGenerationUse

    -- * Retirement
  , retireTargetGenerations

    -- * Observation
  , TargetCondition (..)
  , GenerationStanding (..)
  , GenerationView (..)
  , TargetGenerationsView (..)
  , readTargetGenerations

    -- * Failures
  , GenerationDestructionFailed (..)
  , GenerationEffectUncertain (..)
  , GenerationsRetained (..)
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVar, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception
  ( Exception (displayException)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , allowInterrupt
  , fromException
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (forM, forM_, unless, when)
import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Numeric.Natural (Natural)

import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (RequirePositive)
  , Instant
  , addDuration
  , durationFromNanoseconds
  , minimumPositiveDuration
  )
import Hetoimasia.GPU.Model
  ( DisposalResult (..)
  , EvidenceSource (..)
  , GpuModel
  , NextTurn (..)
  , Outcome (..)
  , PublicationAnswer (..)
  , RecoveryAnswer (..)
  , SessionFailureCause (CleanupFailed, RequiredTargetUnrecoverable)
  , SessionState (..)
  , TargetPhase (..)
  , TargetView (..)
  , TurnReport (..)
  , beginGeneration
  , beginTargetRecovery
  , closeTarget
  , disposalEligible
  , endGenerationCpuUse
  , failGenerationConstruction
  , modelBudgets
  , nextDeadline
  , publishGeneration
  , recordRecoveryFailure
  , recordRecoverySuccess
  , resumeTarget
  , retireGeneration
  , runProgressTurn
  , sessionState
  , silentEvidence
  , suspendTarget
  , targetView
  )
import Hetoimasia.GPU.Model.Budget (BudgetKind, imageTrackingLimit)
import Hetoimasia.GPU.Model.Identity (GenerationId, HoldSubject (..), ImageId, TargetClass, TargetId, generationTarget)
import Hetoimasia.GPU.Vulkan.Native.Presentation
import Hetoimasia.GPU.Vulkan.Native.Profile (DevicePlan (..))
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( GenerationOps (..)
  , GraphicsDeviceLost
  , Roots
  , SwapchainRequest (..)
  , failRootsSession
  , readRootsDevice
  , rootsCall
  , rootsGenerationOps
  , stateRootsModel
  )

-- ---------------------------------------------------------------------------
-- Records

-- | Where one generation stands in this module's own record.
data GenerationStanding
  = GenerationBuilding
    -- ^ Its construction is in progress, or was interrupted before it
    -- settled.
  | GenerationPresenting
    -- ^ The target's active generation.
  | GenerationRetiredHeld
    -- ^ Retired: nothing is acquired from it again, and it is destroyed once
    -- the model reports every hold on it ended.
  | GenerationDestroyedPending
    -- ^ Destroyed natively; the model has not yet recorded the disposal.
  | GenerationUncertain !Text
    -- ^ A destruction, or the bookkeeping of an effect, did not complete. It is
    -- never offered again, and everything above it is retained.
  deriving (Eq, Show)

data NativeGeneration = NativeGeneration
  { genPlan ∷ !GenerationPlan
  , genStanding ∷ !GenerationStanding
  , genSwapchain ∷ !(Maybe Word64)
  , genImages ∷ ![Word64]
  , genViews ∷ ![Word64]
    -- ^ In creation order; destroyed in reverse.
  , genHandedOver ∷ !Bool
    -- ^ Passed as @oldSwapchain@, which Vulkan retires whether or not the
    -- creation it was passed to succeeded.
  , genUses ∷ !Natural
  , genCpuEnded ∷ !Bool
  , genGeometry ∷ !TargetGeometry
    -- ^ The geometry it was planned from.
  }

-- | What a target's generations are doing, as any thread may read it.
data TargetCondition
  = AwaitingGeneration
    -- ^ Tracked, and nothing has been constructed yet.
  | Presenting
  | Suspended !Suspension
    -- ^ No usable extent now. Acquisition is suspended; this is not a failure.
  | Settling !Instant
    -- ^ The geometry moved; the replacement waits until it has been quiet
    -- until this instant.
  | Backpressured !BudgetKind
    -- ^ The replacement cannot fit its budget yet. Rendering is paused; every
    -- other target and the owner carry on.
  | ConstructionFailed !Text
    -- ^ The last construction failed. The target has no active generation,
    -- and the next construction is a fresh one and a recovery attempt.
  | RecoveryWaiting !Instant
    -- ^ The model's episode admits the next attempt at this instant.
  | RecoverySpent
    -- ^ The episode is spent; the model escalated through the target's
    -- designation.
  | PresentationUnsupported ![PresentationGap]
    -- ^ A structured target failure: the surface cannot serve the profile.
  | Closing
  deriving (Eq, Show)

-- | What a swapchain call on a target's active generation answered.
data SwapchainResult
  = SwapchainOutOfDate
  | SwapchainSuboptimal
  deriving (Eq, Show)

data TargetRecord = TargetRecord
  { recordSurface ∷ !Word64
  , recordClass ∷ !TargetClass
  , recordGenerations ∷ !(Map GenerationId NativeGeneration)
  , recordActive ∷ !(Maybe GenerationId)
  , recordCondition ∷ !TargetCondition
  , recordSettling ∷ !(Maybe (SurfaceExtent, TargetGeometry, Instant))
    -- ^ The extent a replacement would be built at, the observed geometry it
    -- was planned from, and since when both have been what they are.
  , recordResult ∷ !(Maybe SwapchainResult)
  , recordResultUnseen ∷ !Bool
    -- ^ A result was reported since the target's last reconciliation, so a
    -- step is owed at once.
  , recordLastPlanned ∷ !(Maybe (SurfaceExtent, TargetGeometry))
    -- ^ The extent and observed geometry of the last construction begun.
  , recordFailed ∷ !Bool
    -- ^ The last construction failed, so the next is a recovery attempt.
  , recordRecovering ∷ !Bool
    -- ^ A recovery attempt the model admitted is outstanding.
  , recordConstructions ∷ !Natural
  }

-- | The generations of one session's targets, over its roots.
data Generations q inst msgr phys dev = Generations
  { generationsRoots ∷ !(Roots q inst msgr phys dev)
  , generationsTargets ∷ !(TVar (Map TargetId TargetRecord))
  , generationsAfterAdmission ∷ GenerationId → IO ()
    -- ^ The examples' seam: runs right after the model admitted a candidate,
    -- inside the construction's masked settlement. Production runs nothing.
  }

newGenerations ∷ Roots q inst msgr phys dev → IO (Generations q inst msgr phys dev)
newGenerations = newGenerationsHooked (\_ → pure ())

-- | 'newGenerations' with the examples' seam, which runs right after the model
-- admits each candidate. Nothing in production sets it.
newGenerationsHooked ∷ (GenerationId → IO ()) → Roots q inst msgr phys dev → IO (Generations q inst msgr phys dev)
newGenerationsHooked hook roots = (\targets → Generations roots targets hook) <$> newTVarIO Map.empty

-- | How long the geometry a replacement would be built from must stay the
-- same before it is built: 16 ms.
settlingPeriod ∷ Duration
settlingPeriod = either (const minimumPositiveDuration) id (durationFromNanoseconds RequirePositive 16000000)

-- | Begin tracking a target the roots admitted, on the surface they hold for
-- it. Nothing is constructed until a step finds it eligible.
trackTarget ∷ Generations q inst msgr phys dev → TargetId → TargetClass → Word64 → STM ()
trackTarget generations target classification surface =
  modifyTVar' (generationsTargets generations) $
    Map.insertWith
      (\_ existing → existing)
      target
      TargetRecord
        { recordSurface = surface
        , recordClass = classification
        , recordGenerations = Map.empty
        , recordActive = Nothing
        , recordCondition = AwaitingGeneration
        , recordSettling = Nothing
        , recordResult = Nothing
        , recordResultUnseen = False
        , recordLastPlanned = Nothing
        , recordFailed = False
        , recordRecovering = False
        , recordConstructions = 0
        }

-- ---------------------------------------------------------------------------
-- Failures

-- | A generation's destruction raised. It is retained, never attempted again,
-- and the session has failed with 'CleanupFailed'.
data GenerationDestructionFailed = GenerationDestructionFailed !GenerationId !Text
  deriving (Eq, Show)

instance Exception GenerationDestructionFailed where
  displayException (GenerationDestructionFailed generation reason) =
    "destroying " <> show generation <> " did not complete: " <> Text.unpack reason

-- | A native effect happened and its bookkeeping could not be committed. The
-- result is retained, admission has stopped and the session has failed.
data GenerationEffectUncertain = GenerationEffectUncertain !GenerationId !Text
  deriving (Eq, Show)

instance Exception GenerationEffectUncertain where
  displayException (GenerationEffectUncertain generation reason) =
    "the outcome of " <> show generation <> " is uncertain: " <> Text.unpack reason

-- | A target's retirement found generations it could not destroy: holds that
-- have not ended, or a destruction that was uncertain. They, the surface and
-- everything above them are retained.
data GenerationsRetained = GenerationsRetained !TargetId ![GenerationId]
  deriving (Eq, Show)

instance Exception GenerationsRetained where
  displayException (GenerationsRetained target retained) =
    "the swapchain generations of " <> show target <> " are retained: " <> show retained

-- ---------------------------------------------------------------------------
-- Reports and uses

-- | Report what a swapchain call on a generation answered. Only the target's
-- active generation is replaced for it; a report about any other answers
-- 'False' and changes nothing.
--
-- It is the owner's: the acquisitions and presentations that produce these
-- results run on the graphics owner's thread. A report asks for a step at
-- once through 'generationsDeadline', so the owner that made it takes the
-- round that reconciles it rather than going idle. A report from another
-- thread wakes nothing.
noteSwapchainResult ∷ Generations q inst msgr phys dev → GenerationId → SwapchainResult → STM Bool
noteSwapchainResult generations generation result = do
  records ← readTVar (generationsTargets generations)
  case Map.lookup (generationTarget generation) records of
    Just record
      | recordActive record == Just generation → do
          writeTVar
            (generationsTargets generations)
            (Map.insert (generationTarget generation) record {recordResult = Just (strongest (recordResult record) result), recordResultUnseen = True} records)
          pure True
    _ → pure False
  where
    strongest (Just SwapchainOutOfDate) _ = SwapchainOutOfDate
    strongest _ latest = latest

-- | A held CPU use of one generation: while any is held the generation's
-- ended-CPU-use hold stays on, and it is not destroyed.
data GenerationUse = GenerationUse !GenerationId !(TVar Bool)

data UseRefusal
  = UseUnknownGeneration
  | UseNotActive !GenerationStanding
    -- ^ Only the active generation can be used; a retired one never again.
  deriving (Eq, Show)

-- | Hold a CPU use of the target's active generation.
useGeneration ∷ Generations q inst msgr phys dev → GenerationId → STM (Either UseRefusal GenerationUse)
useGeneration generations generation =
  lookupGeneration generations generation >>= \case
    Nothing → pure (Left UseUnknownGeneration)
    Just native
      | genStanding native /= GenerationPresenting → pure (Left (UseNotActive (genStanding native)))
      | otherwise → do
          editGeneration generations generation (\entry → entry {genUses = genUses entry + 1})
          Right . GenerationUse generation <$> newTVar False

-- | End a held use. Ending it twice ends it once. The last use of a retired
-- generation ends its CPU use in the model, which lets the owner destroy it.
endGenerationUse ∷ Generations q inst msgr phys dev → GenerationUse → STM ()
endGenerationUse generations (GenerationUse generation ended) = do
  already ← readTVar ended
  unless already $ do
    writeTVar ended True
    editGeneration generations generation (\entry → entry {genUses = max 1 (genUses entry) - 1})
    lookupGeneration generations generation >>= \case
      Just native
        | genStanding native == GenerationRetiredHeld && genUses native == 0 → endCpuUse generations generation
      _ → pure ()

-- ---------------------------------------------------------------------------
-- The owner's step

-- | What one step did.
data StepSummary = StepSummary
  { summaryConstructed ∷ ![GenerationId]
  , summaryDestroyed ∷ ![GenerationId]
  , summaryAdvanced ∷ !Bool
  }
  deriving (Eq, Show)

-- | One step over every tracked target, on the owner's thread: destroy what
-- has become disposable, then reconcile each target with its latest geometry.
--
-- The geometry of a target the caller does not name is left as the step last
-- found it. A destruction that raised is reported, after the whole pass, as
-- 'GenerationDestructionFailed'.
stepGenerations ∷ Generations q inst msgr phys dev → Instant → Map TargetId TargetGeometry → IO StepSummary
stepGenerations generations now geometries = do
  (destroyed, failure) ← disposeEligible generations now Nothing
  for_ failure throwIO
  targets ← Map.keys <$> readTVarIO (generationsTargets generations)
  built ← forM targets $ \target → case Map.lookup target geometries of
    Nothing → pure Nothing
    Just geometry → reconcile generations now target geometry
  -- One progress turn per step, so the model's backoff is anchored to this
  -- step's instant rather than asking for a turn now for ever.
  _ ← atomically (progress generations now (const DisposalRefused))
  let constructed = [generation | Just generation ← built]
  pure (StepSummary constructed destroyed (not (null constructed && null destroyed)))

-- | The earliest instant a step is owed: a swapchain result not yet
-- reconciled, a settling replacement, a deferred recovery attempt, or the
-- model's own schedule. 'Left' means a step is owed now.
generationsDeadline ∷ Generations q inst msgr phys dev → STM (Maybe (Either () Instant))
generationsDeadline generations = do
  records ← Map.elems <$> readTVar (generationsTargets generations)
  model ← stateRootsModel (generationsRoots generations) (\model → (model, model))
  let unseen = any recordResultUnseen records
      own =
        mapMaybe
          ( \record → case recordCondition record of
              Settling at → Just at
              RecoveryWaiting at → Just at
              _ → Nothing
          )
          records
      modelled = case nextDeadline model of
        TurnNow → Just (Left ())
        TurnAt at → Just (Right at)
        _ → Nothing
      candidates = [Left () | unseen] <> map Right own <> maybe [] pure modelled
  pure $ case candidates of
    [] → Nothing
    _ | any isNow candidates → Just (Left ())
    _ → Just (Right (minimum [at | Right at ← candidates]))
  where
    isNow = either (const True) (const False)

-- | Reconcile one target with its latest geometry. Answers the generation it
-- published, if it published one.
reconcile ∷ Generations q inst msgr phys dev → Instant → TargetId → TargetGeometry → IO (Maybe GenerationId)
reconcile generations now target geometry = do
  snapshot ← atomically $ do
    modifyTVar' (generationsTargets generations) (Map.adjust (\entry → entry {recordResultUnseen = False}) target)
    records ← readTVar (generationsTargets generations)
    model ← stateRootsModel roots (\model → (model, model))
    pure ((,) <$> Map.lookup target records <*> targetView target model)
  case snapshot of
    Nothing → pure Nothing
    Just (record, view)
      | viewTargetPhase view `elem` [TargetRetiring, TargetUnavailable] → pure Nothing
      | otherwise → case recordCondition record of
          RecoverySpent → pure Nothing
          PresentationUnsupported _ → pure Nothing
          Closing → pure Nothing
          _ → decide record view
  where
    roots = generationsRoots generations
    decide record view = do
      let active = recordActive record >>= \generation → (,) generation <$> Map.lookup generation (recordGenerations record)
          moved = maybe True (\(_, native) → not (sameGeometry (genGeometry native) geometry)) active
          reported = isJust (recordResult record) || viewTargetReplacementRequested view
          suspendedNow = case recordCondition record of
            Suspended _ → True
            Backpressured _ → True
            _ → False
      case geometryEligibility geometry of
        -- Eligibility is decided before the surface is asked anything.
        Left reason → Nothing <$ suspend (SuspendedIneligible reason)
        Right ()
          | isJust active && not moved && not reported && not (recordFailed record) → do
              -- Nothing to build: a target back to the geometry its generation
              -- has resumes without a rebuild, and a move it had begun to settle
              -- is cancelled, so a later move waits its own full period.
              atomically $ do
                modifyRecord (\entry → entry {recordSettling = Nothing})
                when suspendedNow (modelEdit_ (resumeTarget target))
              Nothing <$ setCondition Presenting
          | otherwise → plan record active reported
    plan record active reported =
      readDevice >>= \case
        Nothing → pure Nothing
        Just (devicePlan, _) → do
          offer ← rootsCall roots "vkGetPhysicalDeviceSurfaceCapabilitiesKHR" (opsSurfaceOffer ops (planDevice devicePlan) (recordSurface record))
          limit ← imageTrackingLimit . modelBudgets <$> atomically (stateRootsModel roots (\model → (model, model)))
          case planGeneration limit geometry offer of
            PlanSuspended suspension → Nothing <$ suspend suspension
            PlanUnsupported gaps → do
              atomically (modelEdit_ (suspendTarget target))
              Nothing <$ setCondition (PresentationUnsupported gaps)
            Planned planned → classify record active reported planned
    classify record active reported planned
      -- A retry after a failed construction is a recovery attempt. If the
      -- geometry has moved since that construction was planned, it waits for
      -- the move to settle first, as any resize does.
      | recordFailed record =
          if maybe False (\(extent, observed) → extent == planExtent planned && sameGeometry observed geometry) (recordLastPlanned record)
            then recover planned
            else settle planned (recover planned)
      | Just (_, native) ← active
      , reported
      , planExtent (genPlan native) == planExtent planned =
          -- Out of date or suboptimal with the extent it already has: not a
          -- resize, so rebuilding it is a recovery attempt — after the
          -- observed geometry, if it has moved, has settled.
          if sameGeometry (genGeometry native) geometry then recover planned else settle planned (recover planned)
      -- The first generation is built at once. A later one with nothing
      -- active — the active one retired on its own to make room — is a
      -- replacement like any other, and waits for its geometry to settle.
      | Nothing ← active = if recordConstructions record == 0 then construct planned else settle planned (construct planned)
      | Just (_, native) ← active = settle planned $
          if planExtent (genPlan native) == planExtent planned
            then do
              -- The geometry moved and has settled without changing the extent
              -- a generation would be built at: adopt it, and rebuild nothing.
              atomically $ do
                editActive (\entry → entry {genGeometry = geometry})
                modifyRecord (\entry → entry {recordSettling = Nothing})
                modelEdit_ (resumeTarget target)
              Nothing <$ setCondition Presenting
            else construct planned
    -- Wait until the extent a replacement would be built at, and the observed
    -- geometry it was planned from, have both been the same for the settling
    -- period, then continue. A surface that reports a new extent a moment
    -- after the observation that moved is therefore still seen, rather than
    -- the move being adopted at the old extent, and a newer observation
    -- restarts the wait even while the surface still reports the old extent.
    settle planned continue = do
        waiting ← atomically $ do
          record ← lookupRecord
          case record >>= recordSettling of
            Just (extent, observed, since) | extent == planExtent planned, sameGeometry observed geometry → pure (Right since)
            _ → do
              modifyRecord (\entry → entry {recordSettling = Just (planExtent planned, geometry, now)})
              pure (Left now)
        let since = either id id waiting
        case addDuration since settlingPeriod of
          Left _ → continue
          Right due
            | due <= now → continue
            | otherwise → Nothing <$ setCondition (Settling due)
    recover planned =
      lookupRecordIO >>= \case
        Just record | recordRecovering record → construct planned
        -- An attempt that could not begin is not admitted, so waiting for an
        -- unretired swapchain to go spends none of the episode.
        _ →
          atomically unretiredRemains >>= \case
            True → pure Nothing
            False →
              atomically (modelEdit (beginTargetRecovery now target)) >>= \case
                Just (RecoveryAttempt _) → do
                  atomically (modifyRecord (\entry → entry {recordRecovering = True}))
                  construct planned
                Just (RecoveryDeferred at) → Nothing <$ setCondition (RecoveryWaiting at)
                Just (RecoveryExhausted _) → Nothing <$ setCondition RecoverySpent
                -- An attempt is outstanding only between its admission and its
                -- settlement in this same step, so there is nothing to begin.
                _ → pure Nothing
    -- Every swapchain Vulkan still counts as unretired, other than the active
    -- one a construction hands over, must be gone before a fresh one is made
    -- for the same surface.
    unretiredRemains = do
      record ← lookupRecord
      pure $ case record of
        Nothing → True
        Just entry →
          or
            [ isJust (genSwapchain native) && not (genHandedOver native)
            | (generation, native) ← Map.toList (recordGenerations entry)
            , Just generation /= recordActive entry
            , genStanding native /= GenerationDestroyedPending
            ]
    construct planned = do
      blocked ← atomically unretiredRemains
      if blocked
        then pure Nothing
        else begin planned
    -- Admission through the construction's settlement is one masked region:
    -- a candidate the model admitted is always settled, published, failed or
    -- retained uncertain, however a cancellation arrives.
    begin planned = mask_ $ do
      attempt ← atomically $ do
        record ← lookupRecord
        let old = record >>= recordActive
        answer ← stateRootsModel roots $ \model → case beginGeneration target old model of
          Admitted (next, candidate) → (Right (candidate, old), next)
          Backpressure kind → (Left (Just kind), model)
          Rejected _ → (Left Nothing, model)
        case answer of
          Right (candidate, handed) → do
            for_ handed $ \previous →
              -- Retired in the model here; handed over to Vulkan only when the
              -- creation that passes it is actually called.
              editGeneration generations previous (\entry → entry {genStanding = GenerationRetiredHeld})
            for_ handed (\previous → retireCpu previous)
            modifyRecord $ \entry →
              entry
                { recordActive = Nothing
                , recordSettling = Nothing
                , recordLastPlanned = Just (planExtent planned, geometry)
                , recordConstructions = recordConstructions entry + 1
                , recordGenerations =
                    Map.insert candidate (NativeGeneration planned GenerationBuilding Nothing [] [] False 0 False geometry) (recordGenerations entry)
                }
            handedHandle ← case handed of
              Nothing → pure Nothing
              Just previous → (>>= genSwapchain) <$> lookupGeneration generations previous
            pure (Right (candidate, (,) <$> handed <*> handedHandle, maybe 0 recordSurface record))
          Left refusal → pure (Left refusal)
      case attempt of
        Left (Just kind) → capacity planned kind
        Left Nothing → pure Nothing
        Right (candidate, handed, surface) → build planned candidate handed surface
    -- The replacement cannot fit. With a limit of one, the only thing in the
    -- way is the active generation that needs replacing: retire it on its own
    -- and build afresh once it is gone. Otherwise wait for a retired
    -- generation's holds to end.
    capacity planned kind = do
      retiredStandalone ← atomically $ do
        record ← lookupRecord
        case record of
          Just entry
            | Just generation ← recordActive entry
            , Map.size (recordGenerations entry) == 1 →
                modelEdit (fmap (\next → (next, ())) . retireGeneration generation) >>= \case
                  Just () → do
                    editGeneration generations generation (\native → native {genStanding = GenerationRetiredHeld})
                    retireCpu generation
                    modifyRecord (\held → held {recordActive = Nothing})
                    pure True
                  Nothing → pure False
          _ → pure False
      atomically (modelEdit_ (suspendTarget target))
      _ ← setCondition (Backpressured kind)
      if retiredStandalone
        then do
          (_, failure) ← disposeEligible generations now (Just target)
          for_ failure throwIO
          stillFull ← atomically (maybe True (not . Map.null . recordGenerations) <$> lookupRecord)
          if stillFull then pure Nothing else construct planned
        else pure Nothing
    build planned candidate handing surface = do
          -- The construction runs masked. Each native effect and the record of
          -- it are consecutive, and a cancellation can land only at the marked
          -- points between effects — whatever exists is then recorded — or
          -- inside a call that blocks interruptibly. The settlement below, which
          -- records how the construction ended, runs before it is re-raised.
          inCreation ← newIORef Nothing
          let creating name call record = do
                writeIORef inCreation (Just name)
                created ← rootsCall roots name call
                atomically (record created)
                writeIORef inCreation Nothing
                pure created
          outcome ← tryWithContext $ do
            generationsAfterAdmission generations candidate
            (devicePlan, device) ← readDevice >>= maybe (throwIO DeviceAbsent) pure
            limit ← imageTrackingLimit . modelBudgets <$> atomically (stateRootsModel roots (\model → (model, model)))
            let request = SwapchainRequest surface planned (planQueueFamily devicePlan) (snd <$> handing)
            -- Passing @oldSwapchain@ retires it whatever the creation answers,
            -- so it is recorded as handed over immediately before the call, with
            -- no point between the two a cancellation could land at. A
            -- construction cancelled before this never handed it over, and the
            -- old swapchain stays one Vulkan counts as unretired.
            for_ handing $ \(previous, _) →
              atomically (editGeneration generations previous (\entry → entry {genHandedOver = True}))
            swapchain ←
              creating "vkCreateSwapchainKHR" (opsCreateSwapchain ops device request) $ \created →
                editGeneration generations candidate (\entry → entry {genSwapchain = Just created})
            allowInterrupt
            images ← rootsCall roots "vkGetSwapchainImagesKHR" (opsSwapchainImages ops device swapchain)
            atomically (editGeneration generations candidate (\entry → entry {genImages = images}))
            allowInterrupt
            let count = fromIntegral (length images) ∷ Natural
            if count == 0 || count > limit
              then pure count
              else do
                forM_ images $ \image → do
                  _ ←
                    creating "vkCreateImageView" (opsCreateImageView ops device image (surfaceFormat (planFormat planned))) $ \created →
                      editGeneration generations candidate (\entry → entry {genViews = genViews entry <> [created]})
                  allowInterrupt
                pure count
          case outcome of
            Right count → publish candidate count
            Left failure@(ExceptionWithContext _ exception) →
              readIORef inCreation >>= \case
                -- A cancellation inside a creation call leaves unknown whether
                -- that call created something whose handle never came back. It
                -- is not a failed construction: the candidate is retained,
                -- uncertain, with everything above it, and the session fails.
                Just call | isAsynchronous exception → do
                  let reason = "a cancellation interrupted " <> call <> ", so whether it created anything is unknown"
                  uncertain candidate reason
                  noteFailure reason
                  rethrowIO failure
                _ → do
                  failed candidate (Text.pack (displayException exception))
                  if isAsynchronous exception then rethrowIO failure else rethrowUnlessOrdinary failure
    -- Device loss was latched by the call that raised it and is the owner's
    -- failure; any other failure is this construction's, and is settled.
    rethrowUnlessOrdinary failure@(ExceptionWithContext _ exception)
      | isJust (fromException exception ∷ Maybe GraphicsDeviceLost) = rethrowIO failure
      | otherwise = pure Nothing
    publish candidate count = do
      answer ← atomically (modelEdit (publishGeneration candidate count))
      case answer of
        Just (GenerationPublished (_ ∷ [ImageId])) → do
          atomically $ do
            editGeneration generations candidate (\entry → entry {genStanding = GenerationPresenting})
            modifyRecord $ \entry →
              entry {recordActive = Just candidate, recordResult = Nothing, recordFailed = False}
            modelEdit_ (resumeTarget target)
          settleRecovery True
          _ ← setCondition Presenting
          pure (Just candidate)
        Just PublicationSuperseded → do
          retiredCandidate candidate
          _ ← setCondition Closing
          settleRecovery False
          pure Nothing
        Just (GenerationRefusedImageCount images limit) → do
          retiredCandidate candidate
          noteFailure ("the driver returned " <> tshow images <> " images against the tracking limit of " <> tshow limit)
          pure Nothing
        Nothing → do
          uncertain candidate "the model refused to record a constructed generation"
          throwIO (GenerationEffectUncertain candidate "the model refused to record a constructed generation")
    failed candidate reason = do
      atomically (modelEdit_ (failGenerationConstruction candidate))
      retiredCandidate candidate
      noteFailure reason
    retiredCandidate candidate = atomically $ do
      editGeneration generations candidate (\entry → entry {genStanding = GenerationRetiredHeld})
      retireCpu candidate
    noteFailure reason = do
      settleRecovery False
      atomically (modifyRecord (\entry → entry {recordFailed = True, recordActive = Nothing}))
      () <$ setCondition (ConstructionFailed reason)
    settleRecovery succeeded = do
      recovering ← maybe False recordRecovering <$> lookupRecordIO
      when recovering $ atomically $ do
        if succeeded
          then modelEdit_ (recordRecoverySuccess target)
          else modelEdit_ (recordRecoveryFailure now target)
        modifyRecord (\entry → entry {recordRecovering = False})
        -- The model marks a target whose last attempt failed unavailable, or
        -- fails the session for a required one, at that failure.
        model ← stateRootsModel roots (\model → (model, model))
        let spent =
              maybe False ((== TargetUnavailable) . viewTargetPhase) (targetView target model)
                || sessionState model == SessionFailed RequiredTargetUnrecoverable
        when spent (modifyRecord (\entry → entry {recordCondition = RecoverySpent}))
    uncertain candidate reason = atomically $ do
      editGeneration generations candidate (\entry → entry {genStanding = GenerationUncertain reason})
      failRootsSession roots CleanupFailed
    suspend suspension = do
      atomically $ do
        modelEdit_ (suspendTarget target)
        modifyRecord (\entry → entry {recordSettling = Nothing})
      setCondition (Suspended suspension)
    setCondition condition = atomically $ do
      record ← lookupRecord
      -- A condition the step set earlier this step for a worse reason stands.
      case record of
        Just entry | recordCondition entry == RecoverySpent → pure ()
        _ → modifyRecord (\entry → entry {recordCondition = condition})
    editActive edit = do
      record ← lookupRecord
      for_ (record >>= recordActive) (\generation → editGeneration generations generation edit)
    lookupRecord = Map.lookup target <$> readTVar (generationsTargets generations)
    lookupRecordIO = atomically lookupRecord
    modifyRecord edit = modifyTVar' (generationsTargets generations) (Map.adjust edit target)
    modelEdit ∷ (GpuModel → Outcome (GpuModel, a)) → STM (Maybe a)
    modelEdit operation = stateRootsModel roots $ \model → case operation model of
      Admitted (next, value) → (Just value, next)
      _ → (Nothing, model)
    modelEdit_ ∷ (GpuModel → Outcome GpuModel) → STM ()
    modelEdit_ operation = stateRootsModel roots $ \model → case operation model of
      Admitted next → ((), next)
      _ → ((), model)
    readDevice = atomically (readRootsDevice roots)
    retireCpu generation = do
      native ← lookupGeneration generations generation
      case native of
        Just entry | genUses entry == 0 → endCpuUse generations generation
        _ → pure ()
    ops = rootsGenerationOps roots

-- | The roots held no live device when a construction began.
data DeviceAbsent = DeviceAbsent
  deriving (Show)

instance Exception DeviceAbsent where
  displayException DeviceAbsent = "the roots hold no live device"

sameGeometry ∷ TargetGeometry → TargetGeometry → Bool
sameGeometry left right =
  geometryEligibility left == geometryEligibility right
    && geometryFramebuffer left == geometryFramebuffer right
    && geometryBounds left == geometryBounds right

-- ---------------------------------------------------------------------------
-- Disposal

-- | Destroy every retired generation whose holds have all ended — of one
-- target, or of all of them — and record the disposals with the model.
--
-- The native destruction comes first and the model is told only what actually
-- happened: a completed destruction is reported completed, and one that raised
-- is reported failed, which retains the generation's accounting and escalates
-- the session.
disposeEligible
  ∷ Generations q inst msgr phys dev
  → Instant
  → Maybe TargetId
  → IO ([GenerationId], Maybe GenerationDestructionFailed)
disposeEligible generations now only = do
  candidates ← atomically $ do
    records ← readTVar (generationsTargets generations)
    model ← stateRootsModel roots (\model → (model, model))
    pure
      [ (generation, native)
      | (target, record) ← Map.toList records
      , maybe True (== target) only
      , (generation, native) ← Map.toList (recordGenerations record)
      , genStanding native == GenerationRetiredHeld
      , disposalEligible (GenerationSubject generation) model
      ]
  device ← atomically (readRootsDevice roots)
  results ← case device of
    Nothing → pure []
    Just (_, handle) → forM candidates $ \(generation, native) → (,) generation <$> destroyGeneration generations handle generation native
  let failures = [(generation, reason) | (generation, Just reason) ← results]
  when (not (null failures)) $ atomically (failRootsSession roots CleanupFailed)
  destroyed ← atomically (progress generations now (evidenceFrom results))
  pure (destroyed, case failures of
    (generation, reason) : _ → Just (GenerationDestructionFailed generation reason)
    [] → Nothing)
  where
    roots = generationsRoots generations
    evidenceFrom results subject = case subject of
      GenerationSubject generation → case lookup generation results of
        Just Nothing → DisposalCompleted
        Just (Just _) → DisposalFailed
        Nothing → DisposalRefused
      _ → DisposalRefused

-- | Destroy one generation's views, newest first, and then its swapchain.
-- Each destruction and the record of it are one masked step; the first that
-- raises marks the generation uncertain and stops, so every parent of what it
-- may have left is retained. Answers the reason, if one did not complete.
destroyGeneration ∷ Generations q inst msgr phys dev → dev → GenerationId → NativeGeneration → IO (Maybe Text)
destroyGeneration generations device generation native = go (reverse (genViews native))
  where
    roots = generationsRoots generations
    ops = rootsGenerationOps roots
    go = \case
      view : rest →
        step "vkDestroyImageView" (opsDestroyImageView ops device view) (\entry → entry {genViews = filter (/= view) (genViews entry)}) >>= \case
          Nothing → go rest
          failure → pure failure
      [] → case genSwapchain native of
        Nothing → finished
        Just swapchain →
          step "vkDestroySwapchainKHR" (opsDestroySwapchain ops device swapchain) (\entry → entry {genSwapchain = Nothing, genImages = []}) >>= \case
            Nothing → finished
            failure → pure failure
    finished = Nothing <$ atomically (editGeneration generations generation (\entry → entry {genStanding = GenerationDestroyedPending}))
    step name destroy record = mask_ $
      tryWithContext (rootsCall roots name destroy) >>= \case
        Right () → Nothing <$ atomically (editGeneration generations generation record)
        Left failure@(ExceptionWithContext _ exception) → do
          let reason = Text.pack (displayException exception)
          atomically $ do
            editGeneration generations generation (\entry → entry {genStanding = GenerationUncertain reason})
            failRootsSession roots CleanupFailed
          if isAsynchronous exception then rethrowIO failure else pure (Just reason)

-- | One model progress turn with the given disposal evidence, forgetting every
-- generation the model recorded as disposed. A generation destroyed natively
-- whose disposal the model did not take this turn keeps answering completed,
-- and one whose destruction was uncertain answers failed, which the model
-- remembers and never offers again.
progress ∷ Generations q inst msgr phys dev → Instant → (HoldSubject → DisposalResult) → STM [GenerationId]
progress generations now evidence = do
  records ← readTVar (generationsTargets generations)
  let standings =
        Map.fromList
          [ (generation, genStanding native)
          | record ← Map.elems records
          , (generation, native) ← Map.toList (recordGenerations record)
          ]
      answer subject = case subject of
        GenerationSubject generation → case Map.lookup generation standings of
          Just GenerationDestroyedPending → DisposalCompleted
          Just (GenerationUncertain _) → DisposalFailed
          _ → evidence subject
        _ → evidence subject
  report ← stateRootsModel (generationsRoots generations) $ \model →
    let (next, turn) = runProgressTurn silentEvidence {disposalEvidence = answer} now model
     in (turn, next)
  let disposed = [generation | GenerationSubject generation ← turnDisposed report]
  modifyTVar' (generationsTargets generations) $
    Map.map (\record → record {recordGenerations = foldr Map.delete (recordGenerations record) disposed})
  pure disposed

-- ---------------------------------------------------------------------------
-- Retirement

-- | Retire every generation of a target that is being retired: close it in the
-- model, retire its active generation, and destroy every generation whose
-- holds have ended. Raises 'GenerationsRetained' if any remains, and
-- 'GenerationDestructionFailed' if a destruction raised; either way nothing is
-- claimed about what remains, and the target's surface is retained above it.
retireTargetGenerations ∷ Generations q inst msgr phys dev → Instant → TargetId → IO ()
retireTargetGenerations generations now target = do
  tracked ← atomically $ do
    record ← Map.lookup target <$> readTVar (generationsTargets generations)
    for_ record $ \entry → do
      stateRootsModel roots $ \model → case closeTarget target model of
        Admitted next → ((), next)
        _ → ((), model)
      for_ (recordActive entry) $ \generation → do
        stateRootsModel roots $ \model → case retireGeneration generation model of
          Admitted next → ((), next)
          _ → ((), model)
        editGeneration generations generation (\native → native {genStanding = GenerationRetiredHeld})
        lookupGeneration generations generation >>= \case
          Just native | genUses native == 0 → endCpuUse generations generation
          _ → pure ()
      modifyTVar' (generationsTargets generations) $
        Map.adjust (\held → held {recordActive = Nothing, recordCondition = Closing}) target
    pure (isJust record)
  when tracked $ do
    (_, failure) ← disposeEligible generations now (Just target)
    for_ failure throwIO
    remaining ← atomically $ do
      record ← Map.lookup target <$> readTVar (generationsTargets generations)
      pure (maybe [] (Map.keys . recordGenerations) record)
    unless (null remaining) (throwIO (GenerationsRetained target remaining))
    atomically (modifyTVar' (generationsTargets generations) (Map.delete target))
  where
    roots = generationsRoots generations

-- ---------------------------------------------------------------------------
-- Observation

data GenerationView = GenerationView
  { viewGeneration ∷ !GenerationId
  , viewStanding ∷ !GenerationStanding
  , viewPlan ∷ !GenerationPlan
  , viewSwapchain ∷ !(Maybe Word64)
  , viewImages ∷ ![Word64]
  , viewImageViews ∷ ![Word64]
  , viewHandedOver ∷ !Bool
  , viewUses ∷ !Natural
  }
  deriving (Eq, Show)

data TargetGenerationsView = TargetGenerationsView
  { viewCondition ∷ !TargetCondition
  , viewActive ∷ !(Maybe GenerationId)
  , viewGenerations ∷ ![GenerationView]
  , viewConstructions ∷ !Natural
    -- ^ How many constructions have been begun for the target.
  , viewPendingResult ∷ !(Maybe SwapchainResult)
  }
  deriving (Eq, Show)

readTargetGenerations ∷ Generations q inst msgr phys dev → TargetId → STM (Maybe TargetGenerationsView)
readTargetGenerations generations target = do
  record ← Map.lookup target <$> readTVar (generationsTargets generations)
  pure $ flip fmap record $ \entry →
    TargetGenerationsView
      { viewCondition = recordCondition entry
      , viewActive = recordActive entry
      , viewGenerations =
          [ GenerationView
              { viewGeneration = generation
              , viewStanding = genStanding native
              , viewPlan = genPlan native
              , viewSwapchain = genSwapchain native
              , viewImages = genImages native
              , viewImageViews = genViews native
              , viewHandedOver = genHandedOver native
              , viewUses = genUses native
              }
          | (generation, native) ← Map.toAscList (recordGenerations entry)
          ]
      , viewConstructions = recordConstructions entry
      , viewPendingResult = recordResult entry
      }

-- ---------------------------------------------------------------------------
-- Helpers

lookupGeneration ∷ Generations q inst msgr phys dev → GenerationId → STM (Maybe NativeGeneration)
lookupGeneration generations generation =
  (\records → Map.lookup (generationTarget generation) records >>= Map.lookup generation . recordGenerations)
    <$> readTVar (generationsTargets generations)

editGeneration ∷ Generations q inst msgr phys dev → GenerationId → (NativeGeneration → NativeGeneration) → STM ()
editGeneration generations generation edit =
  modifyTVar' (generationsTargets generations) $
    Map.adjust (\record → record {recordGenerations = Map.adjust edit generation (recordGenerations record)}) (generationTarget generation)

-- | Certify in the model that nothing can record this generation again.
endCpuUse ∷ Generations q inst msgr phys dev → GenerationId → STM ()
endCpuUse generations generation = do
  native ← lookupGeneration generations generation
  unless (maybe True genCpuEnded native) $ do
    stateRootsModel (generationsRoots generations) $ \model → case endGenerationCpuUse generation model of
      Admitted next → ((), next)
      _ → ((), model)
    editGeneration generations generation (\entry → entry {genCpuEnded = True})

isAsynchronous ∷ SomeException → Bool
isAsynchronous exception = isJust (fromException exception ∷ Maybe SomeAsyncException)

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
