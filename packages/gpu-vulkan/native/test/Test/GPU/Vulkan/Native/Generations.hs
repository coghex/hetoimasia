-- | Swapchain generations over the stand-in native layer: planning,
-- construction, replacement, bounds, failure and destruction.
--
-- Every example asserts the recorded native calls, or what the generations and
-- the model answered, at scripted instants; nothing waits on a clock and
-- nothing creates a Vulkan object.
module Test.GPU.Vulkan.Native.Generations (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), Exception, SomeException, fromException, try)
import Control.Monad (forM_, void)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked), threadStatus)
import Numeric.Natural (Natural)
import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), Instant, durationFromNanoseconds, scriptedInstant)
import Hetoimasia.GPU.Model
  ( Escalation (..)
  , Outcome (..)
  , SessionFailureCause (..)
  , SessionState (..)
  , TargetPhase (..)
  , TargetView (..)
  , closeTarget
  , escalations
  , sessionState
  , targetView
  )
import Hetoimasia.GPU.Model.Budget (BudgetKind (GenerationBudget), BudgetRequest (..), Budgets, defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (GenerationId, TargetClass (..), TargetId)
import Hetoimasia.GPU.Vulkan.Native.Generations
import Hetoimasia.GPU.Vulkan.Native.Presentation
import Hetoimasia.GPU.Vulkan.Native.Roots
import Test.GPU.Vulkan.Native.StandIn
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "Generations" $ do
  describe "construction" $ do
    it "builds the first generation from the surface's concrete extent and the profile's format, with a view of every image" $ do
      rig ← newRig
      stepAt rig 0 (seen 320 240)
      swapchainCalls rig
        `shouldReturn` [ QueriedSurface 10
                       , CreatedSwapchain 100 10 (640, 480) Nothing
                       , EnumeratedImages 100
                       , CreatedView 101 100000
                       , CreatedView 102 100001
                       , CreatedView 103 100002
                       ]
      view ← generationsOf rig
      viewCondition view `shouldBe` Presenting
      [(viewStanding generation, planFormat (viewPlan generation), viewImageViews generation) | generation ← viewGenerations view]
        `shouldBe` [(GenerationPresenting, SurfaceFormat formatB8G8R8A8Srgb colorSpaceSrgbNonlinear, [101, 102, 103])]
      modelled ← modelTarget rig
      viewTargetActive modelled `shouldBe` viewActive view
      viewTargetGenerations modelled `shouldBe` 1

    it "chooses the extent from the last observation when the surface leaves it to the application, clamped to the surface's bounds" $ do
      rig ← newRig
      offerSurface (rigStandIn rig) (withCapabilities (\capabilities → capabilities {capabilityCurrentExtent = Nothing, capabilityMaxExtent = SurfaceExtent 800 600}))
      stepAt rig 0 (seen 1000 700)
      created rig `shouldReturn` [(800, 600)]

    it "builds from the surface's extent rather than a stale observation, and replaces without a fresh one" $ do
      rig ← newRig
      stepAt rig 0 (seen 320 240)
      [old] ← swapchains rig
      -- The window was resized while the main thread published nothing: the
      -- observation is stale, the surface is not, and a present answered out
      -- of date.
      resizeSurface rig 1280 960
      noteActive rig SwapchainOutOfDate
      stepAt rig 1 (seen 320 240)
      stepAt rig 17 (seen 320 240)
      created rig `shouldReturn` [(640, 480), (1280, 960)]
      handedOver rig `shouldReturn` [Nothing, Just old]
      recoveryAttempts rig `shouldReturn` 0

    it "checks zero area before clamping: a zero framebuffer suspends the target, builds nothing and spends no attempt" $ do
      rig ← newRig
      offerSurface (rigStandIn rig) (withCapabilities (\capabilities → capabilities {capabilityCurrentExtent = Nothing, capabilityMinExtent = SurfaceExtent 64 64}))
      stepAt rig 0 (seen 0 480)
      created rig `shouldReturn` []
      viewCondition <$> generationsOf rig `shouldReturn` Suspended (SuspendedZeroArea (SurfaceExtent 0 480))
      viewTargetPhase <$> modelTarget rig `shouldReturn` TargetSuspended
      recoveryAttempts rig `shouldReturn` 0

    it "suspends an ineligible target before asking its surface anything, and resumes it without a rebuild" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      stepAt rig 1 (seen 640 480) {geometryEligibility = Left "minimized"}
      viewCondition <$> generationsOf rig `shouldReturn` Suspended (SuspendedIneligible "minimized")
      stepAt rig 2 (seen 640 480)
      viewCondition <$> generationsOf rig `shouldReturn` Presenting
      viewTargetPhase <$> modelTarget rig `shouldReturn` TargetAdmitted
      length . filter isQuery <$> swapchainCalls rig `shouldReturn` 1
      created rig `shouldReturn` [(640, 480)]

  describe "replacement" $ do
    it "coalesces a resize until its geometry has been quiet for 16 ms, and builds once, from the newest" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      resizeSurface rig 800 600
      stepAt rig 100 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 116)
      resizeSurface rig 1024 768
      stepAt rig 110 (seen 1024 768)
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 126)
      stepAt rig 120 (seen 1024 768)
      created rig `shouldReturn` [(640, 480)]
      stepAt rig 126 (seen 1024 768)
      created rig `shouldReturn` [(640, 480), (1024, 768)]
      viewCondition <$> generationsOf rig `shouldReturn` Presenting

    it "waits out a move whose surface has not caught up yet, and rebuilds once it has" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      stepAt rig 10 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 26)
      resizeSurface rig 800 600
      stepAt rig 20 (seen 800 600)
      stepAt rig 36 (seen 800 600)
      created rig `shouldReturn` [(640, 480), (800, 600)]

    it "cancels a settling move when the geometry returns, so a later move waits its own full period" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      resizeSurface rig 800 600
      stepAt rig 10 (seen 800 600)
      resizeSurface rig 640 480
      stepAt rig 15 (seen 640 480)
      viewCondition <$> generationsOf rig `shouldReturn` Presenting
      resizeSurface rig 800 600
      stepAt rig 30 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 46)
      created rig `shouldReturn` [(640, 480)]
      stepAt rig 46 (seen 800 600)
      created rig `shouldReturn` [(640, 480), (800, 600)]

    it "adopts a settled move that leaves the extent unchanged, without a rebuild" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      stepAt rig 10 (seen 320 240)
      stepAt rig 26 (seen 320 240)
      viewCondition <$> generationsOf rig `shouldReturn` Presenting
      stepAt rig 30 (seen 320 240)
      created rig `shouldReturn` [(640, 480)]
      length . filter isQuery <$> swapchainCalls rig `shouldReturn` 3

    it "hands the active generation over as oldSwapchain, and keeps it owned until its holds end" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      [first] ← activeGenerations rig
      use ← held rig first
      resize rig 20 800 600
      [old, _] ← swapchains rig
      handedOver rig `shouldReturn` [Nothing, Just old]
      standingOf rig first `shouldReturn` Just GenerationRetiredHeld
      atomically (useGeneration (rigGenerations rig) first) >>= either (`shouldBe` UseNotActive GenerationRetiredHeld) (const (expectationFailure "a retired generation was usable"))
      atomically (noteSwapchainResult (rigGenerations rig) first SwapchainOutOfDate) `shouldReturn` False
      -- Steps pass; the hold has not ended, so nothing of it is destroyed.
      stepAt rig 40 (seen 800 600)
      stepAt rig 60 (seen 800 600)
      destroyed rig `shouldReturn` []
      atomically (endGenerationUse (rigGenerations rig) use)
      stepAt rig 80 (seen 800 600)
      destroyed rig `shouldReturn` [DestroyedView 103, DestroyedView 102, DestroyedView 101, DestroyedSwapchain old]
      standingOf rig first `shouldReturn` Nothing
      viewTargetGenerations <$> modelTarget rig `shouldReturn` 1

    it "lets a newer resize supersede a replacement already in flight without dropping the earlier generation's obligations" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      geometry ← newTVarIO (seen 800 600)
      resizeSurface rig 800 600
      stepAt rig 10 (seen 800 600)
      duringCreation (rigStandIn rig) $ do
        resizeSurface rig 1024 768
        atomically (writeTVar geometry (seen 1024 768))
      stepAt rig 26 (seen 800 600)
      [_, second] ← activeGenerations rig
      use ← held rig second
      newer ← atomically (readTVar geometry)
      stepAt rig 30 newer
      stepAt rig 46 newer
      created rig `shouldReturn` [(640, 480), (800, 600), (1024, 768)]
      standingOf rig second `shouldReturn` Just GenerationRetiredHeld
      stepAt rig 60 newer
      viewSwapchainOf rig second `shouldReturn` Just 104
      atomically (endGenerationUse (rigGenerations rig) use)
      stepAt rig 80 newer
      standingOf rig second `shouldReturn` Nothing

    it "treats repeated out-of-date and suboptimal results with unchanged geometry as recovery attempts, bounded and never hot" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      forM_ [(1, SwapchainOutOfDate), (2, SwapchainSuboptimal), (3, SwapchainOutOfDate), (4, SwapchainOutOfDate), (5, SwapchainSuboptimal)] $ \(instant, result) → do
        noteActive rig result
        stepAt rig instant (seen 640 480)
        -- Stepping again at the same instant finds nothing new to do.
        stepAt rig instant (seen 640 480)
      -- The first and three recovery attempts; the fourth unchanged result
      -- found the episode spent.
      length <$> created rig `shouldReturn` 4
      recoveryAttempts rig `shouldReturn` 3
      viewCondition <$> generationsOf rig `shouldReturn` RecoverySpent
      viewTargetPhase <$> modelTarget rig `shouldReturn` TargetUnavailable
      model ← atomically (readRootsModel (rigRoots rig))
      escalations model `shouldBe` [OptionalTargetUnavailable (rigTarget rig)]
      stepAt rig 100 (seen 640 480)
      length <$> created rig `shouldReturn` 4

    it "keeps a suspended target suspended whatever results are reported, and spends nothing" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      noteActive rig SwapchainOutOfDate
      stepAt rig 1 (seen 640 480) {geometryEligibility = Left "hidden"}
      stepAt rig 2 (seen 640 480) {geometryEligibility = Left "hidden"}
      created rig `shouldReturn` [(640, 480)]
      recoveryAttempts rig `shouldReturn` 0

  describe "bounds" $ do
    it "at capacity retires and destroys the oldest disposable generation first, pauses while none is, and builds the newest geometry" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      [first] ← activeGenerations rig
      use ← held rig first
      resize rig 20 800 600
      resizeSurface rig 1024 768
      stepAt rig 40 (seen 1024 768)
      stepAt rig 56 (seen 1024 768)
      viewCondition <$> generationsOf rig `shouldReturn` Backpressured GenerationBudget
      viewTargetPhase <$> modelTarget rig `shouldReturn` TargetSuspended
      resizeSurface rig 1280 960
      stepAt rig 60 (seen 1280 960)
      stepAt rig 76 (seen 1280 960)
      created rig `shouldReturn` [(640, 480), (800, 600)]
      atomically (endGenerationUse (rigGenerations rig) use)
      stepAt rig 80 (seen 1280 960)
      created rig `shouldReturn` [(640, 480), (800, 600), (1280, 960)]
      viewCondition <$> generationsOf rig `shouldReturn` Presenting
      viewTargetPhase <$> modelTarget rig `shouldReturn` TargetAdmitted

    it "with one live generation, retires the active one on its own, awaits it, and builds afresh without it" $ do
      rig ← newRigWith defaultBudgetRequest {requestedGenerations = 1}
      stepAt rig 0 (seen 640 480)
      [first] ← activeGenerations rig
      use ← held rig first
      resize rig 20 800 600
      created rig `shouldReturn` [(640, 480)]
      standingOf rig first `shouldReturn` Just GenerationRetiredHeld
      viewActive <$> generationsOf rig `shouldReturn` Nothing
      atomically (endGenerationUse (rigGenerations rig) use)
      stepAt rig 40 (seen 800 600)
      created rig `shouldReturn` [(640, 480), (800, 600)]
      handedOver rig `shouldReturn` [Nothing, Nothing]
      -- The old swapchain was destroyed before the fresh one was created.
      later ← swapchainCalls rig
      let order = [call | call ← later, isDestroyedSwapchain call || isCreated call]
      order `shouldBe` [CreatedSwapchain 100 10 (640, 480) Nothing, DestroyedSwapchain 100, CreatedSwapchain 104 10 (800, 600) Nothing]

    it "never lets one target's backpressure stop another, or take its reservations" $ do
      rig ← newRig
      other ← admitAnother rig 11
      let both first second = Map.fromList [(rigTarget rig, first), (other, second)]
          stepBoth instant first second = void (stepGenerations (rigGenerations rig) (at instant) (both first second))
      stepBoth 0 (seen 640 480) (seen 640 480)
      [first] ← activeGenerations rig
      _ ← held rig first
      resizeSurface rig 800 600
      stepBoth 20 (seen 800 600) (seen 640 480)
      stepBoth 36 (seen 800 600) (seen 640 480)
      resizeSurface rig 1024 768
      stepBoth 40 (seen 1024 768) (seen 1024 768)
      stepBoth 56 (seen 1024 768) (seen 1024 768)
      viewCondition <$> generationsOf rig `shouldReturn` Backpressured GenerationBudget
      theirs ← atomically (readTargetGenerations (rigGenerations rig) other)
      viewCondition <$> theirs `shouldBe` Just Presenting
      map viewGeneration . viewGenerations <$> theirs `shouldSatisfy` maybe False ((== 2) . length)
      model ← atomically (readRootsModel (rigRoots rig))
      viewTargetGenerations <$> targetView (rigTarget rig) model `shouldBe` Just 2
      viewTargetGenerations <$> targetView other model `shouldBe` Just 2

    it "refuses an oversized returned image count before building any view, and retires the candidate" $ do
      rig ← newRig
      returnImages (rigStandIn rig) 17
      stepAt rig 0 (seen 640 480)
      swapchainCalls rig
        `shouldReturn` [QueriedSurface 10, CreatedSwapchain 100 10 (640, 480) Nothing, EnumeratedImages 100]
      viewCondition <$> generationsOf rig `shouldReturn` ConstructionFailed "the driver returned 17 images against the tracking limit of 16"
      stepAt rig 1 (seen 640 480)
      destroyed rig `shouldReturn` [DestroyedSwapchain 100]

    it "refuses a returned count of zero the same way" $ do
      rig ← newRig
      returnImages (rigStandIn rig) 0
      stepAt rig 0 (seen 640 480)
      length . filter isView <$> swapchainCalls rig `shouldReturn` 0
      viewActive <$> generationsOf rig `shouldReturn` Nothing

  describe "failure" $ do
    it "leaves a failed replacement retired, never reacquires from or hands over the retired handle, and builds afresh" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      [first] ← activeGenerations rig
      script (rigStandIn rig) AtCreateSwapchain (SucceedsThenFails 0)
      resize rig 20 800 600
      viewCondition <$> generationsOf rig `shouldReturn` ConstructionFailed "StandInFailure AtCreateSwapchain"
      viewActive <$> generationsOf rig `shouldReturn` Nothing
      standingOf rig first `shouldReturn` Just GenerationRetiredHeld
      atomically (useGeneration (rigGenerations rig) first) >>= either (const (pure ())) (const (expectationFailure "the retired generation was usable"))
      clearScript rig AtCreateSwapchain
      -- Its views and swapchain go before the fresh construction.
      stepAt rig 40 (seen 800 600)
      handedOver rig `shouldReturn` [Nothing, Just 100, Nothing]
      recoveryAttempts rig `shouldReturn` 1
      later ← swapchainCalls rig
      [call | call ← later, isDestroyedSwapchain call || isCreated call]
        `shouldBe` [ CreatedSwapchain 100 10 (640, 480) Nothing
                   , CreatedSwapchain 104 10 (800, 600) (Just 100)
                   , DestroyedSwapchain 100
                   , CreatedSwapchain 105 10 (800, 600) Nothing
                   ]
      viewCondition <$> generationsOf rig `shouldReturn` Presenting

    it "retries a failing construction only through the recovery episode's attempts and delays, then reports it spent" $ do
      rig ← newRigOf RequiredTarget defaultBudgetRequest
      script (rigStandIn rig) AtCreateSwapchain Fails
      stepAt rig 0 (seen 640 480)
      stepAt rig 1 (seen 640 480)
      stepAt rig 50 (seen 640 480)
      viewCondition <$> generationsOf rig `shouldReturn` RecoveryWaiting (at 101)
      stepAt rig 101 (seen 640 480)
      stepAt rig 400 (seen 640 480)
      stepAt rig 601 (seen 640 480)
      stepAt rig 5000 (seen 640 480)
      length <$> created rig `shouldReturn` 4
      viewCondition <$> generationsOf rig `shouldReturn` RecoverySpent
      model ← atomically (readRootsModel (rigRoots rig))
      sessionState model `shouldBe` SessionFailed RequiredTargetUnrecoverable

    it "destroys exactly what a construction failing after the swapchain left, child before parent, and never replays it" $ do
      forM_ [(AtSwapchainImages, 0, [DestroyedSwapchain 100]), (AtCreateView, 1, [DestroyedView 101, DestroyedSwapchain 100])] $ \(failing, succeeding, expected) → do
        rig ← newRig
        script (rigStandIn rig) failing (SucceedsThenFails succeeding)
        stepAt rig 0 (seen 640 480)
        viewActive <$> generationsOf rig `shouldReturn` Nothing
        clearScript rig failing
        stepAt rig 1 (seen 640 480)
        destroyed rig `shouldReturn` expected
        length <$> created rig `shouldReturn` 2

    it "retains a generation whose cleanup failed, fails the session, never retries, and keeps the surface above it" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      script (rigStandIn rig) AtDestroyView (SucceedsThenFails 1)
      resize rig 20 800 600
      stepAt rig 40 (seen 800 600) `raises` \(GenerationDestructionFailed _ _) → True
      [first, _] ← map viewGeneration . viewGenerations <$> generationsOf rig
      standingOf rig first >>= (`shouldSatisfy` \case
        Just (GenerationUncertain _) → True
        _ → False)
      viewSwapchainOf rig first `shouldReturn` Just 100
      model ← atomically (readRootsModel (rigRoots rig))
      sessionState model `shouldBe` SessionFailed CleanupFailed
      viewAdmitting <$> atomically (readRootsView (rigRoots rig)) `shouldReturn` False
      stepAt rig 60 (seen 800 600)
      destroyed rig `shouldReturn` [DestroyedView 103, DestroyedView 102]
      clearScript rig AtDestroyView
      retireTargetGenerations (rigGenerations rig) (at 80) (rigTarget rig) `raises` \(GenerationsRetained _ remaining) → first `elem` remaining
      retireRootTarget (rigRoots rig) (rigTarget rig) `raises` \(TargetGenerationsRemain _ _) → True
      filter isSurfaceDestroyed <$> calls (rigStandIn rig) `shouldReturn` []

    it "records a swapchain whose creation a cancellation reached, and destroys it before building afresh" $ do
      rig ← newRig
      gate ← newTVarIO False
      script (rigStandIn rig) AtCreateSwapchain (HoldsUntil gate)
      finished ← newEmptyMVar
      stepper ← forkIO (try @SomeException (stepAt rig 0 (seen 640 480)) >>= putMVar finished)
      awaitCall (rigStandIn rig) (CreatedSwapchain 100 10 (640, 480) Nothing)
      killer ← forkIO (killThread stepper)
      -- The cancellation is aimed at the step while the creation holds; it is
      -- delivered at the first point after the swapchain has been recorded.
      awaitThrowing killer
      atomically (writeTVar gate True)
      outcome ← takeMVar finished
      either (\failure → fromException failure `shouldBe` Just ThreadKilled) (const (expectationFailure "the step was not cancelled")) outcome
      length . filter isEnumerated <$> swapchainCalls rig `shouldReturn` 0
      [generation] ← viewGenerations <$> generationsOf rig
      (viewStanding generation, viewSwapchain generation) `shouldBe` (GenerationRetiredHeld, Just 100)
      clearScript rig AtCreateSwapchain
      stepAt rig 1 (seen 640 480)
      later ← swapchainCalls rig
      [call | call ← later, isDestroyedSwapchain call || isCreated call]
        `shouldBe` [CreatedSwapchain 100 10 (640, 480) Nothing, DestroyedSwapchain 100, CreatedSwapchain 101 10 (640, 480) Nothing]

    describe "retains a candidate whose creation a cancellation interrupted inside the call, fails the session, and destroys none of it" $ do
      let interruptedAt at' = do
            rig ← newRig
            gate ← newTVarIO False
            script (rigStandIn rig) at' (WaitsInterruptibly gate)
            finished ← newEmptyMVar
            stepper ← forkIO (try @SomeException (stepAt rig 0 (seen 640 480)) >>= putMVar finished)
            awaitCall (rigStandIn rig) (CreatedSwapchain 100 10 (640, 480) Nothing)
            case at' of
              AtCreateView → awaitCall (rigStandIn rig) (CreatedView 101 100000)
              _ → pure ()
            killThread stepper
            outcome ← takeMVar finished
            either (\failure → fromException failure `shouldBe` Just ThreadKilled) (const (expectationFailure "the step was not cancelled")) outcome
            atomically (writeTVar gate True)
            [generation] ← viewGenerations <$> generationsOf rig
            viewStanding generation `shouldSatisfy` \case
              GenerationUncertain _ → True
              _ → False
            model ← atomically (readRootsModel (rigRoots rig))
            sessionState model `shouldBe` SessionFailed CleanupFailed
            viewAdmitting <$> atomically (readRootsView (rigRoots rig)) `shouldReturn` False
            stepAt rig 1 (seen 640 480)
            stepAt rig 200 (seen 640 480)
            destroyed rig `shouldReturn` []
            length <$> created rig `shouldReturn` 1
            retireTargetGenerations (rigGenerations rig) (at 300) (rigTarget rig) `raises` \(GenerationsRetained _ remaining) → remaining == [viewGeneration generation]
            retireRootTarget (rigRoots rig) (rigTarget rig) `raises` \(TargetGenerationsRemain _ _) → True
      it "in the swapchain's creation" (interruptedAt AtCreateSwapchain)
      it "in an image view's creation" (interruptedAt AtCreateView)

    it "keeps a destruction a cancellation ended part-way uncertain, and never attempts it again" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      gate ← newTVarIO False
      script (rigStandIn rig) AtDestroySwapchain (WaitsInterruptibly gate)
      resizeSurface rig 800 600
      stepAt rig 10 (seen 800 600)
      finished ← newEmptyMVar
      stepper ← forkIO (try @SomeException (stepAt rig 26 (seen 800 600) >> stepAt rig 30 (seen 800 600)) >>= putMVar finished)
      awaitCall (rigStandIn rig) (DestroyedSwapchain 100)
      killThread stepper
      _ ← takeMVar finished
      atomically (writeTVar gate True)
      [first, _] ← map viewGeneration . viewGenerations <$> generationsOf rig
      standingOf rig first >>= (`shouldSatisfy` \case
        Just (GenerationUncertain _) → True
        _ → False)
      stepAt rig 50 (seen 800 600)
      length . filter isDestroyedSwapchain <$> swapchainCalls rig `shouldReturn` 1

    it "latches device loss raised by a swapchain creation, and fails the session" $ do
      rig ← newRig
      script (rigStandIn rig) AtCreateSwapchain Loses
      stepAt rig 0 (seen 640 480) `raises` \(GraphicsDeviceLost _ _) → True
      model ← atomically (readRootsModel (rigRoots rig))
      sessionState model `shouldBe` SessionFailed DeviceLost
      viewActive <$> generationsOf rig `shouldReturn` Nothing

  describe "close" $ do
    it "retires a construction the target closed during, rather than publishing it" $ do
      rig ← newRig
      duringCreation (rigStandIn rig) $
        atomically (void (stateRootsModel (rigRoots rig) (\model → case closeTarget (rigTarget rig) model of
          Admitted next → ((), next)
          _ → ((), model))))
      stepAt rig 0 (seen 640 480)
      view ← generationsOf rig
      viewActive view `shouldBe` Nothing
      viewCondition view `shouldBe` Closing
      retireTargetGenerations (rigGenerations rig) (at 1) (rigTarget rig)
      destroyed rig `shouldReturn` [DestroyedView 103, DestroyedView 102, DestroyedView 101, DestroyedSwapchain 100]
      atomically (readTargetGenerations (rigGenerations rig) (rigTarget rig)) >>= (`shouldSatisfy` not . isJust)

    it "wins over a scheduled retry: a closed target begins nothing more" $ do
      rig ← newRig
      script (rigStandIn rig) AtCreateSwapchain Fails
      stepAt rig 0 (seen 640 480)
      retireTargetGenerations (rigGenerations rig) (at 1) (rigTarget rig)
      stepAt rig 200 (seen 640 480)
      length <$> created rig `shouldReturn` 1

    it "destroys every generation, child before parent, before the target's surface can go" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      [first] ← activeGenerations rig
      use ← held rig first
      retireTargetGenerations (rigGenerations rig) (at 1) (rigTarget rig) `raises` \(GenerationsRetained _ remaining) → remaining == [first]
      retireRootTarget (rigRoots rig) (rigTarget rig) `raises` \(TargetGenerationsRemain _ count) → count == 1
      atomically (endGenerationUse (rigGenerations rig) use)
      retireTargetGenerations (rigGenerations rig) (at 2) (rigTarget rig)
      retireRootTarget (rigRoots rig) (rigTarget rig)
      after ← calls (rigStandIn rig)
      reverse (take 5 (reverse after))
        `shouldBe` [DestroyedView 103, DestroyedView 102, DestroyedView 101, DestroyedSwapchain 100, DestroyedSurface 10]
  where
    isQuery = \case
      QueriedSurface _ → True
      _ → False
    isView = \case
      CreatedView _ _ → True
      _ → False
    isEnumerated = \case
      EnumeratedImages _ → True
      _ → False
    isSurfaceDestroyed = \case
      DestroyedSurface _ → True
      _ → False

-- ---------------------------------------------------------------------------
-- The rig

data Rig = Rig
  { rigStandIn ∷ !StandIn
  , rigRoots ∷ !StandInRoots
  , rigGenerations ∷ !(Generations () Int Int Text Int)
  , rigTarget ∷ !TargetId
  }

newRig ∷ IO Rig
newRig = newRigOf OptionalTarget defaultBudgetRequest

newRigWith ∷ BudgetRequest → IO Rig
newRigWith = newRigOf OptionalTarget

-- | Started roots over the stand-in, one target on surface 10, and its
-- generations tracked.
newRigOf ∷ TargetClass → BudgetRequest → IO Rig
newRigOf classification request = do
  standIn ← newStandIn
  roots ← newStandInRoots standIn (budgetsOf request)
  _ ← startRoots roots standardRequest
  target ← admitRootTarget roots classification (surfaceNumbered standIn 10) >>= either (fail . show) pure
  generations ← newGenerations roots
  atomically (trackTarget generations target classification 10)
  pure (Rig standIn roots generations target)

admitAnother ∷ Rig → Word64 → IO TargetId
admitAnother rig surface = do
  target ← admitRootTarget (rigRoots rig) OptionalTarget (surfaceNumbered (rigStandIn rig) surface) >>= either (fail . show) pure
  atomically (trackTarget (rigGenerations rig) target OptionalTarget surface)
  pure target

budgetsOf ∷ BudgetRequest → Budgets
budgetsOf request = either (error . show) id (validateBudgets request)

-- | The instant this many milliseconds after the scripted clock's origin.
at ∷ Integer → Instant
at milliseconds = scriptedInstant (either (error . show) id (durationFromNanoseconds AllowZero (milliseconds * 1000000)))

stepAt ∷ Rig → Integer → TargetGeometry → IO ()
stepAt rig instant geometry = void (stepGenerations (rigGenerations rig) (at instant) (Map.singleton (rigTarget rig) geometry))

-- | An eligible target whose framebuffer was observed at this extent.
seen ∷ Word32 → Word32 → TargetGeometry
seen width height = TargetGeometry (Right ()) (Just (SurfaceExtent width height)) Nothing 1

-- | Resize the surface and publish the matching geometry, then let it settle.
resize ∷ Rig → Integer → Word32 → Word32 → IO ()
resize rig instant width height = do
  resizeSurface rig width height
  stepAt rig instant (seen width height)
  stepAt rig (instant + 16) (seen width height)

resizeSurface ∷ Rig → Word32 → Word32 → IO ()
resizeSurface rig width height =
  offerSurface (rigStandIn rig) (withCapabilities (\capabilities → capabilities {capabilityCurrentExtent = Just (SurfaceExtent width height)}))

withCapabilities ∷ (SurfaceCapabilities → SurfaceCapabilities) → SurfaceOffer → SurfaceOffer
withCapabilities edit offer = offer {offerCapabilities = edit (offerCapabilities offer)}

noteActive ∷ Rig → SwapchainResult → IO ()
noteActive rig result = do
  active ← viewActive <$> generationsOf rig
  case active of
    Just generation → void (atomically (noteSwapchainResult (rigGenerations rig) generation result))
    Nothing → expectationFailure "the target has no active generation to report on"

held ∷ Rig → GenerationId → IO GenerationUse
held rig generation = atomically (useGeneration (rigGenerations rig) generation) >>= either (fail . show) pure

clearScript ∷ Rig → Step → IO ()
clearScript rig at' = script (rigStandIn rig) at' (SucceedsThenFails maxBound)

generationsOf ∷ Rig → IO TargetGenerationsView
generationsOf rig = atomically (readTargetGenerations (rigGenerations rig) (rigTarget rig)) >>= maybe (fail "the target is not tracked") pure

activeGenerations ∷ Rig → IO [GenerationId]
activeGenerations rig = map viewGeneration . viewGenerations <$> generationsOf rig

standingOf ∷ Rig → GenerationId → IO (Maybe GenerationStanding)
standingOf rig generation = do
  view ← atomically (readTargetGenerations (rigGenerations rig) (rigTarget rig))
  pure (view >>= \entry → lookup generation [(viewGeneration each, viewStanding each) | each ← viewGenerations entry])

viewSwapchainOf ∷ Rig → GenerationId → IO (Maybe Word64)
viewSwapchainOf rig generation = do
  view ← generationsOf rig
  pure (lookup generation [(viewGeneration each, viewSwapchain each) | each ← viewGenerations view] >>= id)

modelTarget ∷ Rig → IO TargetView
modelTarget rig = atomically (readRootsModel (rigRoots rig)) >>= maybe (fail "the model has no such target") pure . targetView (rigTarget rig)

recoveryAttempts ∷ Rig → IO Natural
recoveryAttempts rig = viewTargetRecoveryAttempts <$> modelTarget rig

-- | Every generation call, oldest first.
swapchainCalls ∷ Rig → IO [Call]
swapchainCalls rig = filter generational <$> calls (rigStandIn rig)
  where
    generational = \case
      QueriedSurface _ → True
      CreatedSwapchain {} → True
      EnumeratedImages _ → True
      CreatedView _ _ → True
      DestroyedView _ → True
      DestroyedSwapchain _ → True
      _ → False

swapchains ∷ Rig → IO [Word64]
swapchains rig = (\recorded → [handle | CreatedSwapchain handle _ _ _ ← recorded]) <$> swapchainCalls rig

created ∷ Rig → IO [(Word32, Word32)]
created rig = (\recorded → [extent | CreatedSwapchain _ _ extent _ ← recorded]) <$> swapchainCalls rig

handedOver ∷ Rig → IO [Maybe Word64]
handedOver rig = (\recorded → [old | CreatedSwapchain _ _ _ old ← recorded]) <$> swapchainCalls rig

destroyed ∷ Rig → IO [Call]
destroyed rig = filter (\call → isDestroyedSwapchain call || isDestroyedView call) <$> swapchainCalls rig
  where
    isDestroyedView = \case
      DestroyedView _ → True
      _ → False

isDestroyedSwapchain ∷ Call → Bool
isDestroyedSwapchain = \case
  DestroyedSwapchain _ → True
  _ → False

isCreated ∷ Call → Bool
isCreated = \case
  CreatedSwapchain {} → True
  _ → False

raises ∷ ∀ e a. Exception e ⇒ IO a → (e → Bool) → IO ()
raises action expected =
  try action >>= \case
    Left failure → expected failure `shouldBe` True
    Right _ → expectationFailure "expected a failure, but the action returned"

-- | Wait until a thread is blocked delivering an exception to another, which
-- is the one observable sign that a cancellation is pending on its target.
awaitThrowing ∷ ThreadId → IO ()
awaitThrowing thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnException → pure ()
    _ → yield >> awaitThrowing thread
