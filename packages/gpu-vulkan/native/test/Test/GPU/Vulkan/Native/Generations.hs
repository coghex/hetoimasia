-- | Swapchain generations over the stand-in native layer: planning,
-- construction, replacement, bounds, failure and destruction.
--
-- Every example asserts the recorded native calls, or what the generations and
-- the model answered, at scripted instants; nothing waits on a clock and
-- nothing creates a Vulkan object.
module Test.GPU.Vulkan.Native.Generations (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, check, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), Exception, SomeException, fromException, try)
import Control.Monad (forM_, void)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked), threadStatus)
import Numeric.Natural (Natural)
import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), Instant, durationFromNanoseconds, scriptedInstant)
import Data.Foldable (for_)
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
import Hetoimasia.GPU.Vulkan.Native.Naming (NativeObjectKind (..), imageViewName, swapchainImageName, swapchainName)
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

    it "restarts the quiet period for a newer observation while the surface still reports the extent it planned" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      resizeSurface rig 800 600
      stepAt rig 10 (seen 800 600)
      stepAt rig 15 (seen 900 600)
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 31)
      stepAt rig 26 (seen 900 600)
      created rig `shouldReturn` [(640, 480)]
      stepAt rig 31 (seen 900 600)
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

    it "asks for a step at once when a result is reported, until a step has reconciled it, so the owner that reported it is not left idle" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      atomically (generationsDeadline (rigGenerations rig)) >>= (`shouldSatisfy` not . immediate)
      noteActive rig SwapchainSuboptimal
      atomically (generationsDeadline (rigGenerations rig)) >>= (`shouldSatisfy` immediate)
      stepAt rig 1 (seen 640 480)
      atomically (generationsDeadline (rigGenerations rig)) >>= (`shouldSatisfy` not . immediate)
      length <$> created rig `shouldReturn` 2

    it "settles a moved observation before an out-of-date result's recovery rebuild, and builds the newest extent as a resize" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      noteActive rig SwapchainOutOfDate
      stepAt rig 10 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 26)
      created rig `shouldReturn` [(640, 480)]
      resizeSurface rig 800 600
      stepAt rig 20 (seen 800 600)
      stepAt rig 36 (seen 800 600)
      created rig `shouldReturn` [(640, 480), (800, 600)]
      recoveryAttempts rig `shouldReturn` 0

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

    it "with one live generation, waits the quiet period for a newer resize that arrived while its only generation was held" $ do
      rig ← newRigWith defaultBudgetRequest {requestedGenerations = 1}
      stepAt rig 0 (seen 640 480)
      [first] ← activeGenerations rig
      use ← held rig first
      resize rig 20 800 600
      viewCondition <$> generationsOf rig `shouldReturn` Backpressured GenerationBudget
      resizeSurface rig 1024 768
      stepAt rig 50 (seen 1024 768)
      atomically (endGenerationUse (rigGenerations rig) use)
      stepAt rig 55 (seen 1024 768)
      created rig `shouldReturn` [(640, 480)]
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 66)
      stepAt rig 66 (seen 1024 768)
      created rig `shouldReturn` [(640, 480), (1024, 768)]

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

  describe "names" $ do
    it "names the swapchain, each image and each view from the candidate's generation as each is made, before publishing it" $ do
      rig ← newRig
      offerNaming (rigStandIn rig)
      stepAt rig 0 (seen 640 480)
      [generation] ← activeGenerations rig
      recorded ← calls (rigStandIn rig)
      [call | call ← recorded, namedCall call || isCreated call || enumeratedCall call || viewCall call]
        `shouldBe` [ CreatedSwapchain 100 10 (640, 480) Nothing
                   , Named ObjectSwapchain 100 (swapchainName generation)
                   , EnumeratedImages 100
                   , Named ObjectImage 100000 (swapchainImageName generation 0)
                   , CreatedView 101 100000
                   , Named ObjectImageView 101 (imageViewName generation 0)
                   , Named ObjectImage 100001 (swapchainImageName generation 1)
                   , CreatedView 102 100001
                   , Named ObjectImageView 102 (imageViewName generation 1)
                   , Named ObjectImage 100002 (swapchainImageName generation 2)
                   , CreatedView 103 100002
                   , Named ObjectImageView 103 (imageViewName generation 2)
                   ]
      viewCondition <$> generationsOf rig `shouldReturn` Presenting

    it "names nothing when the device offers no naming, and builds exactly the same generation" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      namesGiven (rigStandIn rig) `shouldReturn` []
      viewCondition <$> generationsOf rig `shouldReturn` Presenting

    it "fails a construction whose naming raised: the candidate is retired unpublished and destroyed child before parent" $ do
      rig ← newRig
      offerNaming (rigStandIn rig)
      failNaming (rigStandIn rig) ObjectImageView
      stepAt rig 0 (seen 640 480)
      viewCondition <$> generationsOf rig `shouldReturn` ConstructionFailed "NamingFailure ObjectImageView"
      viewActive <$> generationsOf rig `shouldReturn` Nothing
      [candidate] ← activeGenerations rig
      standingOf rig candidate `shouldReturn` Just GenerationRetiredHeld
      atomically (useGeneration (rigGenerations rig) candidate) >>= either (const (pure ())) (const (expectationFailure "the unnamed candidate was usable"))
      viewTargetActive <$> modelTarget rig `shouldReturn` Nothing
      -- The view that exists, then the swapchain, go before the next attempt.
      restoreNaming (rigStandIn rig) ObjectImageView
      stepAt rig 200 (seen 640 480)
      destroyed rig `shouldReturn` [DestroyedView 101, DestroyedSwapchain 100]
      viewCondition <$> generationsOf rig `shouldReturn` Presenting

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

    it "settles a resize that arrives after a failed construction before retrying at its geometry" $ do
      rig ← newRig
      script (rigStandIn rig) AtCreateSwapchain (SucceedsThenFails 0)
      stepAt rig 0 (seen 640 480)
      clearScript rig AtCreateSwapchain
      resizeSurface rig 800 600
      stepAt rig 5 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 21)
      recoveryAttempts rig `shouldReturn` 0
      stepAt rig 21 (seen 800 600)
      created rig `shouldReturn` [(640, 480), (800, 600)]
      recoveryAttempts rig `shouldReturn` 1

    it "cancels a settling move when a failed construction's geometry returns, so a later move waits its own full period" $ do
      rig ← newRig
      script (rigStandIn rig) AtCreateSwapchain Fails
      stepAt rig 0 (seen 640 480)
      stepAt rig 1 (seen 640 480)
      stepAt rig 2 (seen 640 480)
      viewCondition <$> generationsOf rig `shouldReturn` RecoveryWaiting (at 101)
      resizeSurface rig 800 600
      stepAt rig 80 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 96)
      resizeSurface rig 640 480
      stepAt rig 90 (seen 640 480)
      resizeSurface rig 800 600
      stepAt rig 95 (seen 800 600)
      stepAt rig 101 (seen 800 600)
      length <$> created rig `shouldReturn` 2
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 111)
      stepAt rig 111 (seen 800 600)
      created rig `shouldReturn` [(640, 480), (640, 480), (800, 600)]

    it "cancels a settling move when an out-of-date result's geometry returns to the active generation's, so a later move waits its own full period" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      noteActive rig SwapchainOutOfDate
      stepAt rig 10 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 26)
      stepAt rig 15 (seen 640 480)
      length <$> created rig `shouldReturn` 2
      noteActive rig SwapchainOutOfDate
      resizeSurface rig 800 600
      stepAt rig 20 (seen 800 600)
      stepAt rig 26 (seen 800 600)
      length <$> created rig `shouldReturn` 2
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 36)
      stepAt rig 36 (seen 800 600)
      created rig `shouldReturn` [(640, 480), (640, 480), (800, 600)]

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

    it "settles a candidate a cancellation reached right after its admission, and leaves the surface destroyable" $ do
      rig ← newRig
      gate ← newTVarIO False
      reached ← newEmptyMVar
      atomically $ writeTVar (rigAfterAdmission rig) $ \_ → do
        putMVar reached ()
        atomically (readTVar gate >>= check)
      finished ← newEmptyMVar
      stepper ← forkIO (try @SomeException (stepAt rig 0 (seen 640 480)) >>= putMVar finished)
      takeMVar reached
      killThread stepper
      outcome ← takeMVar finished
      either (\failure → fromException failure `shouldBe` Just ThreadKilled) (const (expectationFailure "the step was not cancelled")) outcome
      [generation] ← viewGenerations <$> generationsOf rig
      (viewStanding generation, viewSwapchain generation) `shouldBe` (GenerationRetiredHeld, Nothing)
      created rig `shouldReturn` []
      atomically $ do
        writeTVar gate True
        writeTVar (rigAfterAdmission rig) (\_ → pure ())
      retireTargetGenerations (rigGenerations rig) (at 1) (rigTarget rig)
      retireRootTarget (rigRoots rig) (rigTarget rig)
      filter isSurfaceDestroyed <$> calls (rigStandIn rig) `shouldReturn` [DestroyedSurface 10]

    it "counts a replacement cancelled before its creation as never handing the old swapchain over, and destroys that first" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      [first] ← activeGenerations rig
      use ← held rig first
      gate ← newTVarIO False
      reached ← newEmptyMVar
      atomically $ writeTVar (rigAfterAdmission rig) $ \_ → do
        putMVar reached ()
        atomically (readTVar gate >>= check)
      resizeSurface rig 800 600
      stepAt rig 10 (seen 800 600)
      finished ← newEmptyMVar
      stepper ← forkIO (try @SomeException (stepAt rig 26 (seen 800 600)) >>= putMVar finished)
      takeMVar reached
      killThread stepper
      _ ← takeMVar finished
      atomically $ do
        writeTVar gate True
        writeTVar (rigAfterAdmission rig) (\_ → pure ())
      standings ← viewGenerations <$> generationsOf rig
      lookup first [(viewGeneration each, (viewStanding each, viewHandedOver each)) | each ← standings]
        `shouldBe` Just (GenerationRetiredHeld, False)
      -- The old swapchain is still one Vulkan counts as unretired, and it is
      -- held: nothing is created for the surface, and no attempt is spent.
      stepAt rig 30 (seen 800 600)
      stepAt rig 60 (seen 800 600)
      created rig `shouldReturn` [(640, 480)]
      recoveryAttempts rig `shouldReturn` 0
      atomically (endGenerationUse (rigGenerations rig) use)
      stepAt rig 80 (seen 800 600)
      later ← swapchainCalls rig
      [call | call ← later, isDestroyedSwapchain call || isCreated call]
        `shouldBe` [CreatedSwapchain 100 10 (640, 480) Nothing, DestroyedSwapchain 100, CreatedSwapchain 104 10 (800, 600) Nothing]

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

  describe "surface recovery (VK-14)" $ do
    it "retires a lost surface's generation, destroys the surface only once every generation of it has gone, and replaces it on the same target as an attempt" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      [first] ← activeGenerations rig
      use ← held rig first
      noteActive rig SwapchainSurfaceLost
      wantedAt rig 1 `shouldReturn` []
      viewCondition <$> generationsOf rig `shouldReturn` SurfaceLost
      viewActive <$> generationsOf rig `shouldReturn` Nothing
      standingOf rig first `shouldReturn` Just GenerationRetiredHeld
      -- Held: nothing of it goes, the surface stays, and no attempt begins.
      wantedAt rig 2 `shouldReturn` []
      surfacesDestroyed rig `shouldReturn` []
      recoveryAttempts rig `shouldReturn` 0
      atomically (endGenerationUse (rigGenerations rig) use)
      wantedAt rig 3 `shouldReturn` [rigTarget rig]
      viewCondition <$> generationsOf rig `shouldReturn` SurfaceReplacing
      recoveryAttempts rig `shouldReturn` 1
      offerReplacementSurface (rigGenerations rig) (at 4) (rigTarget rig) (surfaceNumbered (rigStandIn rig) 20) `shouldReturn` ReplacementInstalled
      stepAt rig 4 (seen 640 480)
      viewCondition <$> generationsOf rig `shouldReturn` Presenting
      recovered ← calls (rigStandIn rig)
      -- Child before parent: the views, the swapchain, the lost surface, and
      -- only then the new surface's support and a fresh swapchain on it,
      -- handed nothing.
      [call | call ← recovered, isRecoveryCall call]
        `shouldBe` [ QueriedSurface 10
                   , CreatedSwapchain 100 10 (640, 480) Nothing
                   , DestroyedView 103
                   , DestroyedView 102
                   , DestroyedView 101
                   , DestroyedSwapchain 100
                   , DestroyedSurface 10
                   , QueriedSupport 20
                   , QueriedSurface 20
                   , CreatedSwapchain 104 20 (640, 480) Nothing
                   ]
      -- The same target, its attempt settled and not given back.
      modelled ← modelTarget rig
      viewTargetPhase modelled `shouldBe` TargetAdmitted
      viewTargetRecoveryAttempts modelled `shouldBe` 1
      map targetViewSurface <$> atomically (readRootTargets (rigRoots rig)) `shouldReturn` [20]

    it "reads a surface lost by its query or by a swapchain's creation as a lost surface too" $ do
      forM_ [AtSurfaceOffer, AtCreateSwapchain] $ \failing → do
        rig ← newRig
        stepAt rig 0 (seen 640 480)
        script (rigStandIn rig) failing (AnswersOnce FailedSurfaceLost)
        resizeSurface rig 800 600
        -- The query answers at once; a creation only once the move settled.
        stepAt rig 10 (seen 800 600)
        stepAt rig 26 (seen 800 600)
        viewCondition <$> generationsOf rig >>= (`shouldSatisfy` (`elem` [SurfaceLost, SurfaceReplacing]))
        viewActive <$> generationsOf rig `shouldReturn` Nothing
        length . filter isCreated <$> swapchainCalls rig `shouldReturn` (if failing == AtCreateSwapchain then 2 else 1)
        _ ← wantedAt rig 40
        viewCondition <$> generationsOf rig `shouldReturn` SurfaceReplacing
        surfacesDestroyed rig `shouldReturn` [DestroyedSurface 10]

    it "keeps asking nothing more while an attempt waits for its surface, and never hot" $ do
      rig ← lostAndReleased
      forM_ [4, 5, 6] $ \instant → wantedAt rig instant `shouldReturn` []
      atomically (generationsDeadline (rigGenerations rig)) >>= (`shouldSatisfy` not . immediate)
      recoveryAttempts rig `shouldReturn` 1

    it "spends one episode across repeated loss: three replacements and then the target is spent, with nothing replenished" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      forM_ (zip [1 ..] [20, 21, 22]) $ \(round', surface) → do
        noteActive rig SwapchainSurfaceLost
        _ ← wantedAt rig (round' * 10)
        wantedAt rig (round' * 10 + 1) `shouldReturn` [rigTarget rig]
        offerReplacementSurface (rigGenerations rig) (at (round' * 10 + 2)) (rigTarget rig) (surfaceNumbered (rigStandIn rig) surface) `shouldReturn` ReplacementInstalled
        stepAt rig (round' * 10 + 2) (seen 640 480)
        viewCondition <$> generationsOf rig `shouldReturn` Presenting
        recoveryAttempts rig `shouldReturn` fromIntegral round'
      noteActive rig SwapchainSurfaceLost
      _ ← wantedAt rig 40
      wantedAt rig 41 `shouldReturn` []
      viewCondition <$> generationsOf rig `shouldReturn` RecoverySpent
      -- Unavailable, and — holding nothing more — forgotten by the model at the
      -- step's own progress turn; the escalation is what remains.
      model ← atomically (readRootsModel (rigRoots rig))
      fmap viewTargetPhase (targetView (rigTarget rig) model) `shouldSatisfy` (`elem` [Nothing, Just TargetUnavailable])
      escalations model `shouldBe` [OptionalTargetUnavailable (rigTarget rig)]

    it "carries one episode across a failed replacement, a changed geometry and the construction's own retries, never resetting it" $ do
      rig ← lostAndReleased
      -- The replacement's first construction fails: the attempt it belonged
      -- to fails with it.
      script (rigStandIn rig) AtCreateSwapchain (AnswersOnce FailedNativeWindowInUse)
      offerReplacementSurface (rigGenerations rig) (at 4) (rigTarget rig) (surfaceNumbered (rigStandIn rig) 20) `shouldReturn` ReplacementInstalled
      stepAt rig 4 (seen 640 480)
      viewCondition <$> generationsOf rig `shouldReturn` ConstructionFailed "StandInResult \"AtCreateSwapchain\" FailedNativeWindowInUse"
      recoveryAttempts rig `shouldReturn` 1
      -- The window moves meanwhile; the next attempt still waits its delay
      -- and then its geometry's quiet period, and counts on from the first.
      resizeSurface rig 800 600
      stepAt rig 50 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` Settling (at 66)
      stepAt rig 66 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` RecoveryWaiting (at 104)
      stepAt rig 104 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` Presenting
      recoveryAttempts rig `shouldReturn` 2
      created rig `shouldReturn` [(640, 480), (640, 480), (800, 600)]

    it "retries a replacement whose partial construction was rolled back, freshly and only after its rollback was proven" $ do
      rig ← lostAndReleased
      script (rigStandIn rig) AtCreateView (SucceedsThenFails 1)
      offerReplacementSurface (rigGenerations rig) (at 4) (rigTarget rig) (surfaceNumbered (rigStandIn rig) 20) `shouldReturn` ReplacementInstalled
      stepAt rig 4 (seen 640 480)
      clearScript rig AtCreateView
      stepAt rig 104 (seen 640 480)
      viewCondition <$> generationsOf rig `shouldReturn` Presenting
      recovered ← calls (rigStandIn rig)
      [call | call ← recovered, isRecoveryCall call, touches20 call]
        `shouldBe` [ QueriedSupport 20
                   , QueriedSurface 20
                   , CreatedSwapchain 104 20 (640, 480) Nothing
                   , DestroyedView 105
                   , DestroyedSwapchain 104
                   , QueriedSurface 20
                   , CreatedSwapchain 107 20 (640, 480) Nothing
                   ]
      recoveryAttempts rig `shouldReturn` 2

    it "forbids any further attempt when a partial replacement's rollback is unproven, failing the session and keeping the surface" $ do
      rig ← lostAndReleased
      script (rigStandIn rig) AtCreateView (SucceedsThenFails 0)
      script (rigStandIn rig) AtDestroySwapchain Fails
      offerReplacementSurface (rigGenerations rig) (at 4) (rigTarget rig) (surfaceNumbered (rigStandIn rig) 20) `shouldReturn` ReplacementInstalled
      stepAt rig 4 (seen 640 480)
      stepAt rig 104 (seen 640 480) `raises` \(GenerationDestructionFailed _ _) → True
      clearScript rig AtCreateView
      forM_ [200, 800, 2000] $ \instant → void (stepGenerations (rigGenerations rig) (at instant) (Map.singleton (rigTarget rig) (seen 640 480)))
      created rig `shouldReturn` [(640, 480), (640, 480)]
      sessionState <$> atomically (readRootsModel (rigRoots rig)) `shouldReturn` SessionFailed CleanupFailed
      retireTargetGenerations (rigGenerations rig) (at 3000) (rigTarget rig) `raises` \(GenerationsRetained _ _) → True
      retireRootTarget (rigRoots rig) (rigTarget rig) `raises` \(TargetGenerationsRemain _ _) → True
      filter (== DestroyedSurface 20) <$> calls (rigStandIn rig) `shouldReturn` []

    it "forbids any attempt when the lost surface's own destruction is unproven, failing the session" $ do
      standIn ← newStandIn
      roots ← newStandInRoots standIn (budgetsOf defaultBudgetRequest)
      _ ← startRoots roots standardRequest
      target ← admitRootTarget roots OptionalTarget (surfaceFailing standIn 10) >>= either (fail . show) pure
      generations ← newGenerations roots
      atomically (trackTarget generations target OptionalTarget 10)
      let stepOnce instant = stepGenerations generations (at instant) (Map.singleton target (seen 640 480))
      _ ← stepOnce 0
      active ← viewActive <$> (atomically (readTargetGenerations generations target) >>= maybe (fail "untracked") pure)
      for_ active $ \generation → atomically (noteSwapchainResult generations generation SwapchainSurfaceLost)
      _ ← stepOnce 1
      stepOnce 2 `raises` \(SurfaceDestructionFailed _ _) → True
      -- Reported once; never attempted again, and nothing asked for.
      summarySurfacesWanted <$> stepOnce 200 `shouldReturn` []
      model ← atomically (readRootsModel roots)
      sessionState model `shouldBe` SessionFailed CleanupFailed
      fmap viewTargetRecoveryAttempts (targetView target model) `shouldBe` Just 0
      length . filter (== DestroyedSurface 10) <$> calls standIn `shouldReturn` 1

    it "orders a failed replacement's retired chain: destroyed before any fresh creation, and a window still in use charged to the same episode" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      -- The replacement hands the active generation over, and its creation
      -- answers the window still in use: the old chain is retired all the
      -- same, and never named again.
      script (rigStandIn rig) AtCreateSwapchain (AnswersOnce FailedNativeWindowInUse)
      resize rig 10 800 600
      viewActive <$> generationsOf rig `shouldReturn` Nothing
      -- The fresh construction waits for the retired chain's destruction,
      -- and is refused again with the window still in use: the episode's
      -- first attempt, failed, and the second 100 ms on.
      script (rigStandIn rig) AtCreateSwapchain (AnswersOnce FailedNativeWindowInUse)
      stepAt rig 40 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` ConstructionFailed "StandInResult \"AtCreateSwapchain\" FailedNativeWindowInUse"
      stepAt rig 139 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` RecoveryWaiting (at 140)
      stepAt rig 140 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` Presenting
      later ← swapchainCalls rig
      [call | call ← later, isDestroyedSwapchain call || isCreated call]
        `shouldBe` [ CreatedSwapchain 100 10 (640, 480) Nothing
                   , CreatedSwapchain 104 10 (800, 600) (Just 100)
                   , DestroyedSwapchain 100
                   , CreatedSwapchain 105 10 (800, 600) Nothing
                   , CreatedSwapchain 106 10 (800, 600) Nothing
                   ]
      recoveryAttempts rig `shouldReturn` 2

    it "lets close defeat a replacement that arrives after it: the surface stays its creator's, and the attempt settles" $ do
      rig ← lostAndReleased
      retireTargetGenerations (rigGenerations rig) (at 4) (rigTarget rig)
      offerReplacementSurface (rigGenerations rig) (at 5) (rigTarget rig) (surfaceNumbered (rigStandIn rig) 20) `shouldReturn` ReplacementNotWanted
      filter (== QueriedSupport 20) <$> calls (rigStandIn rig) `shouldReturn` []
      -- Nothing of it remains to destroy, and the model forgets the target.
      retireRootTarget (rigRoots rig) (rigTarget rig)
      model ← atomically (readRootsModel (rigRoots rig))
      targetView (rigTarget rig) model `shouldBe` Nothing
      length . filter isCreated <$> swapchainCalls rig `shouldReturn` 1

    it "fails an attempt whose replacement was not made, and schedules the next through the episode" $ do
      rig ← lostAndReleased
      replacementSurfaceFailed (rigGenerations rig) (at 4) (rigTarget rig) "scripted"
      viewCondition <$> generationsOf rig `shouldReturn` SurfaceLost
      wantedAt rig 50 `shouldReturn` []
      viewCondition <$> generationsOf rig `shouldReturn` RecoveryWaiting (at 104)
      wantedAt rig 104 `shouldReturn` [rigTarget rig]
      recoveryAttempts rig `shouldReturn` 2

    describe "exhaustion follows the designation" $ do
      it "an optional target becomes unavailable while another keeps building" $ do
        rig ← lostAndReleased
        other ← admitAnother rig 11
        spendReplacements rig
        viewCondition <$> generationsOf rig `shouldReturn` RecoverySpent
        viewTargetPhase <$> modelTarget rig `shouldReturn` TargetUnavailable
        model ← atomically (readRootsModel (rigRoots rig))
        sessionState model `shouldBe` SessionRunning
        void (stepGenerations (rigGenerations rig) (at 5000) (Map.fromList [(rigTarget rig, seen 640 480), (other, seen 640 480)]))
        viewCondition <$> otherGenerations rig other `shouldReturn` Presenting

      it "a required target fails the session" $ do
        rig ← lostAndReleasedOf RequiredTarget
        spendReplacements rig
        viewCondition <$> generationsOf rig `shouldReturn` RecoverySpent
        model ← atomically (readRootsModel (rigRoots rig))
        sessionState model `shouldBe` SessionFailed RequiredTargetUnrecoverable
        escalations model `shouldSatisfy` elem (RequiredTargetFailedSession (rigTarget rig))

    describe "a replacement the device cannot present to is disposed of through the designation, with no second device" $ do
      it "an optional target becomes unavailable while another keeps building" $ do
        rig ← lostAndReleased
        other ← admitAnother rig 11
        offerReplacementSurface (rigGenerations rig) (at 4) (rigTarget rig) (surfaceNumbered (rigStandIn rig) unsupportedSurface) `shouldReturn` ReplacementUnsupported 0
        viewCondition <$> generationsOf rig `shouldReturn` RecoverySpent
        viewTargetPhase <$> modelTarget rig `shouldReturn` TargetUnavailable
        sessionState <$> atomically (readRootsModel (rigRoots rig)) `shouldReturn` SessionRunning
        void (stepGenerations (rigGenerations rig) (at 5) (Map.fromList [(rigTarget rig, seen 640 480), (other, seen 640 480)]))
        viewCondition <$> otherGenerations rig other `shouldReturn` Presenting
        -- The surface stays its creator's; the device is the one there was.
        filter (== DestroyedSurface unsupportedSurface) <$> calls (rigStandIn rig) `shouldReturn` []
        length . filter isDeviceCreated <$> calls (rigStandIn rig) `shouldReturn` 1

      it "a required target fails the session" $ do
        rig ← lostAndReleasedOf RequiredTarget
        offerReplacementSurface (rigGenerations rig) (at 4) (rigTarget rig) (surfaceNumbered (rigStandIn rig) unsupportedSurface) `shouldReturn` ReplacementUnsupported 0
        sessionState <$> atomically (readRootsModel (rigRoots rig)) `shouldReturn` SessionFailed RequiredTargetUnrecoverable
        length . filter isDeviceCreated <$> calls (rigStandIn rig) `shouldReturn` 1

    it "takes a lost surface reported from a generation already retired, and no late report about it reaches the replacement" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      [first] ← activeGenerations rig
      use ← held rig first
      resize rig 10 800 600
      viewActive <$> generationsOf rig >>= (`shouldSatisfy` (/= Just first))
      -- A presentation made on the retired generation answers the surface
      -- lost: the target's surface is lost, whichever generation said so.
      atomically (noteSwapchainResult (rigGenerations rig) first SwapchainOutOfDate) `shouldReturn` False
      atomically (noteSwapchainResult (rigGenerations rig) first SwapchainSurfaceLost) `shouldReturn` True
      stepAt rig 30 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` SurfaceLost
      viewActive <$> generationsOf rig `shouldReturn` Nothing
      -- Another report about the lost surface, while it is being recovered,
      -- changes nothing.
      atomically (noteSwapchainResult (rigGenerations rig) first SwapchainSurfaceLost) `shouldReturn` True
      atomically (endGenerationUse (rigGenerations rig) use)
      _ ← wantedAt rig 40
      _ ← wantedAt rig 41
      viewCondition <$> generationsOf rig `shouldReturn` SurfaceReplacing
      offerReplacementSurface (rigGenerations rig) (at 42) (rigTarget rig) (surfaceNumbered (rigStandIn rig) 20) `shouldReturn` ReplacementInstalled
      stepAt rig 42 (seen 800 600)
      stepAt rig 43 (seen 800 600)
      viewCondition <$> generationsOf rig `shouldReturn` Presenting
      recoveryAttempts rig `shouldReturn` 1

    describe "reads what a creation's retry raised as itself, not as a failed retry" $ do
      it "latching device loss" $ do
        rig ← retryingRig (AnswersOnceThen FailedOutOfMemory Loses)
        stepAt rig 30 (seen 800 600) `raises` \(GraphicsDeviceLost {}) → True
        viewLoss <$> atomically (readRootsView (rigRoots rig)) >>= (`shouldSatisfy` isJust)
        -- The retry was made: the reclamation pass destroyed the generation a
        -- hold had kept until the construction began.
        destroyed rig >>= (`shouldSatisfy` elem (DestroyedSwapchain 100))

      it "replacing a lost surface" $ do
        rig ← retryingRig (AnswersOnceThen FailedOutOfMemory (AnswersOnce FailedSurfaceLost))
        stepAt rig 30 (seen 800 600)
        viewCondition <$> generationsOf rig `shouldReturn` SurfaceLost
        destroyed rig >>= (`shouldSatisfy` elem (DestroyedSwapchain 100))

    it "fails the attempt in flight when the replacement surface's own query reports it lost, and admits the next through the episode" $ do
      rig ← lostAndReleased
      offerReplacementSurface (rigGenerations rig) (at 4) (rigTarget rig) (surfaceNumbered (rigStandIn rig) 20) `shouldReturn` ReplacementInstalled
      script (rigStandIn rig) AtSurfaceOffer (AnswersOnce FailedSurfaceLost)
      -- Nothing was built on it, so the same step lets the lost replacement
      -- go, and the next attempt waits its delay rather than being refused as
      -- outstanding, asking for no step now.
      wantedAt rig 4 `shouldReturn` []
      wantedAt rig 5 `shouldReturn` []
      viewCondition <$> generationsOf rig `shouldReturn` RecoveryWaiting (at 104)
      atomically (generationsDeadline (rigGenerations rig)) >>= (`shouldSatisfy` not . immediate)
      surfacesDestroyed rig `shouldReturn` [DestroyedSurface 10, DestroyedSurface 20]
      wantedAt rig 104 `shouldReturn` [rigTarget rig]
      recoveryAttempts rig `shouldReturn` 2

    it "keeps a fresh construction waiting while the chain a failed replacement handed over is still held, and destroys it first" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      [first] ← activeGenerations rig
      use ← held rig first
      script (rigStandIn rig) AtCreateSwapchain (AnswersOnce FailedNativeWindowInUse)
      resize rig 10 800 600
      viewActive <$> generationsOf rig `shouldReturn` Nothing
      -- Held, the retired chain stays, and nothing fresh is created or
      -- charged, however long the episode's delays run.
      forM_ [40, 200, 700, 2000] $ \instant → stepAt rig instant (seen 800 600)
      length . filter isCreated <$> swapchainCalls rig `shouldReturn` 2
      recoveryAttempts rig `shouldReturn` 0
      atomically (endGenerationUse (rigGenerations rig) use)
      stepAt rig 2100 (seen 800 600)
      later ← swapchainCalls rig
      [call | call ← later, isDestroyedSwapchain call || isCreated call]
        `shouldBe` [ CreatedSwapchain 100 10 (640, 480) Nothing
                   , CreatedSwapchain 104 10 (800, 600) (Just 100)
                   , DestroyedSwapchain 100
                   , CreatedSwapchain 105 10 (800, 600) Nothing
                   ]
      viewCondition <$> generationsOf rig `shouldReturn` Presenting

    it "tells an ordinary resize, which spends nothing, from a repeated failure at unchanged geometry, which spends the episode" $ do
      rig ← newRig
      stepAt rig 0 (seen 640 480)
      forM_ (zip [10, 40, 70] [(800, 600), (1024, 768), (640, 480)]) $ \(instant, (width, height)) → resize rig instant width height
      recoveryAttempts rig `shouldReturn` 0
      noteActive rig SwapchainOutOfDate
      stepAt rig 100 (seen 640 480)
      noteActive rig SwapchainOutOfDate
      stepAt rig 101 (seen 640 480)
      recoveryAttempts rig `shouldReturn` 2
      length <$> created rig `shouldReturn` 6

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
  , rigAfterAdmission ∷ !(TVar (GenerationId → IO ()))
    -- ^ What runs right after the model admits each candidate.
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
  hook ← newTVarIO (\_ → pure ())
  generations ← newGenerationsHooked (\candidate → readTVarIO hook >>= ($ candidate)) roots
  atomically (trackTarget generations target classification 10)
  pure (Rig standIn roots generations target hook)

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

namedCall, enumeratedCall, viewCall ∷ Call → Bool
namedCall = \case
  Named {} → True
  _ → False
enumeratedCall = \case
  EnumeratedImages _ → True
  _ → False
viewCall = \case
  CreatedView _ _ → True
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

-- | A rig whose first generation is retired but held, and whose active one
-- has an out-of-date result, so the step at 30 rebuilds it. The hold ends
-- right after that construction's admission, making the retired generation
-- something a reclamation pass can dispose of; the construction's first view
-- creation then runs out of memory, and its retry does as scripted.
retryingRig ∷ Scripted → IO Rig
retryingRig retry = do
  -- Room for three generations, so the rebuild is not held back by the
  -- retired one's hold.
  rig ← newRigWith defaultBudgetRequest {requestedGenerations = 3}
  stepAt rig 0 (seen 640 480)
  [first] ← activeGenerations rig
  use ← held rig first
  resize rig 10 800 600
  noteActive rig SwapchainOutOfDate
  atomically (writeTVar (rigAfterAdmission rig) (\_ → atomically (endGenerationUse (rigGenerations rig) use)))
  script (rigStandIn rig) AtCreateView retry
  pure rig

-- | Step once, and answer the targets the step asked a replacement surface
-- for.
wantedAt ∷ Rig → Integer → IO [TargetId]
wantedAt rig instant = summarySurfacesWanted <$> stepGenerations (rigGenerations rig) (at instant) (Map.singleton (rigTarget rig) (seen 640 480))

-- | A rig whose target's surface was lost, its generation destroyed, the
-- surface released, and one attempt admitted and waiting for a replacement.
lostAndReleased ∷ IO Rig
lostAndReleased = lostAndReleasedOf OptionalTarget

lostAndReleasedOf ∷ TargetClass → IO Rig
lostAndReleasedOf classification = do
  rig ← newRigOf classification defaultBudgetRequest
  stepAt rig 0 (seen 640 480)
  noteActive rig SwapchainSurfaceLost
  _ ← wantedAt rig 1
  _ ← wantedAt rig 2
  viewCondition <$> generationsOf rig >>= (`shouldBe` SurfaceReplacing)
  pure rig

-- | Fail the outstanding attempt's replacement and every later one the
-- episode admits, until it is spent.
spendReplacements ∷ Rig → IO ()
spendReplacements rig = do
  replacementSurfaceFailed (rigGenerations rig) (at 4) (rigTarget rig) "scripted"
  wantedAt rig 104 >>= (`shouldBe` [rigTarget rig])
  replacementSurfaceFailed (rigGenerations rig) (at 104) (rigTarget rig) "scripted"
  wantedAt rig 604 >>= (`shouldBe` [rigTarget rig])
  replacementSurfaceFailed (rigGenerations rig) (at 604) (rigTarget rig) "scripted"
  recoveryAttempts rig >>= (`shouldBe` 3)

otherGenerations ∷ Rig → TargetId → IO TargetGenerationsView
otherGenerations rig target = atomically (readTargetGenerations (rigGenerations rig) target) >>= maybe (fail "the other target is not tracked") pure

-- | Every surface destruction, oldest first.
surfacesDestroyed ∷ Rig → IO [Call]
surfacesDestroyed rig = filter (\case DestroyedSurface _ → True; _ → False) <$> calls (rigStandIn rig)

-- | The calls a surface's recovery orders: generation creation and
-- destruction, the surface's destruction, and the support and capability
-- queries.
isRecoveryCall ∷ Call → Bool
isRecoveryCall = \case
  CreatedSwapchain {} → True
  DestroyedView _ → True
  DestroyedSwapchain _ → True
  DestroyedSurface _ → True
  QueriedSupport _ → True
  QueriedSurface _ → True
  _ → False

-- | Whether a call concerns surface 20 or a swapchain or view built on it.
touches20 ∷ Call → Bool
touches20 = \case
  CreatedSwapchain _ 20 _ _ → True
  QueriedSupport 20 → True
  QueriedSurface 20 → True
  DestroyedView view → view >= 104
  DestroyedSwapchain swapchain → swapchain >= 104
  _ → False

isDeviceCreated ∷ Call → Bool
isDeviceCreated = \case
  CreatedDevice _ _ → True
  _ → False

-- | Whether a deadline asks for a step now.
immediate ∷ Maybe (Either () Instant) → Bool
immediate = \case
  Just (Left ()) → True
  _ → False

-- | Wait until a thread is blocked delivering an exception to another, which
-- is the one observable sign that a cancellation is pending on its target.
awaitThrowing ∷ ThreadId → IO ()
awaitThrowing thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnException → pure ()
    _ → yield >> awaitThrowing thread
