-- | Reconciliation for the swapchain generations
-- ("Hetoimasia.GPU.Vulkan.Native.Generations"): bringing one target, on the
-- graphics owner's thread, to its latest geometry. It decides eligibility and
-- suspension, plans from what the surface reports, waits out settling, admits
-- recovery attempts through the model's episode, frees room at capacity —
-- retiring the active generation on its own when the limit is one — and
-- constructs, names and publishes a candidate, handing the active generation
-- over as @oldSwapchain@ only when the creation that passes it is called.
--
-- Admission through a construction's settlement is one masked region, and each
-- native effect is recorded in the same masked step that made it. A creation a
-- cancellation interrupted inside its call leaves its candidate uncertain and
-- fails the session; any other failure is the construction's and is settled.
--
-- This module inserts and advances generation records and advances target
-- records — their condition, settling, last plan, recovery and active
-- generation — in "Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State".
-- The only state it creates is each construction's own note of the creation
-- call in progress, which lives for that one construction.
module Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Reconciliation
  ( reconcile
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar)
import Control.Exception
  ( Exception (displayException)
  , ExceptionWithContext (ExceptionWithContext)
  , allowInterrupt
  , fromException
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (forM_, when)
import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Numeric.Natural (Natural)

import Hetoimasia.Foundation.Time (Instant, addDuration)
import Hetoimasia.GPU.Model
  ( GpuModel
  , Outcome (..)
  , PublicationAnswer (..)
  , RecoveryAnswer (..)
  , SessionFailureCause (CleanupFailed, RequiredTargetUnrecoverable)
  , SessionState (..)
  , TargetPhase (..)
  , TargetView (..)
  , beginGeneration
  , beginTargetRecovery
  , failGenerationConstruction
  , modelBudgets
  , publishGeneration
  , recordRecoveryFailure
  , recordRecoverySuccess
  , resumeTarget
  , retireGeneration
  , sessionState
  , suspendTarget
  , targetView
  )
import Hetoimasia.GPU.Model.Budget (imageTrackingLimit)
import Hetoimasia.GPU.Model.Identity (GenerationId, ImageId, TargetId)
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.Disposal (disposeEligible)
import Hetoimasia.GPU.Vulkan.Native.Internal.Generations.State
  ( GenerationEffectUncertain (..)
  , GenerationStanding (..)
  , Generations (..)
  , NativeGeneration (..)
  , TargetCondition (..)
  , TargetRecord (..)
  , editGeneration
  , endCpuUse
  , isAsynchronous
  , lookupGeneration
  , settlingPeriod
  )
import Hetoimasia.GPU.Vulkan.Native.Naming (NativeObjectKind (..), imageViewName, swapchainImageName, swapchainName)
import Hetoimasia.GPU.Vulkan.Native.Presentation
import Hetoimasia.GPU.Vulkan.Native.Profile (DevicePlan (..))
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( GenerationOps (..)
  , GraphicsDeviceLost
  , SwapchainRequest (..)
  , failRootsSession
  , nameRootsObject
  , readRootsDevice
  , readRootsInstrumentation
  , rootsCall
  , rootsGenerationOps
  , stateRootsModel
  )

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
          case planGenerationWith (generationsCapture generations) limit geometry offer of
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
            then unmoved planned
            else settle planned (recover planned)
      | Just (_, native) ← active
      , reported
      , planExtent (genPlan native) == planExtent planned =
          -- Out of date or suboptimal with the extent it already has: not a
          -- resize, so rebuilding it is a recovery attempt — after the
          -- observed geometry, if it has moved, has settled.
          if sameGeometry (genGeometry native) geometry then unmoved planned else settle planned (recover planned)
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
    -- A recovery rebuild at the geometry it was already planned from: a move
    -- that had begun to settle is cancelled, so a later move waits its own
    -- full period rather than inheriting that one's start.
    unmoved planned = do
      atomically (modifyRecord (\entry → entry {recordSettling = Nothing}))
      recover planned
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
            instrumentation ← fmap snd <$> readRootsInstrumentation roots
            let name kind handle label = for_ instrumentation (\instrumented → nameRootsObject roots instrumented kind handle label)
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
            name ObjectSwapchain swapchain (swapchainName candidate)
            allowInterrupt
            images ← rootsCall roots "vkGetSwapchainImagesKHR" (opsSwapchainImages ops device swapchain)
            atomically (editGeneration generations candidate (\entry → entry {genImages = images}))
            allowInterrupt
            let count = fromIntegral (length images) ∷ Natural
            if count == 0 || count > limit
              then pure count
              else do
                forM_ (zip [0 ..] images) $ \(index, image) → do
                  name ObjectImage image (swapchainImageName candidate index)
                  view ←
                    creating "vkCreateImageView" (opsCreateImageView ops device image (surfaceFormat (planFormat planned))) $ \created →
                      editGeneration generations candidate (\entry → entry {genViews = genViews entry <> [created]})
                  name ObjectImageView view (imageViewName candidate index)
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

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
