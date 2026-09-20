{-# LANGUAGE OverloadedRecordDot #-}

-- | The release decision, exercised headlessly.
--
-- Every example here is a pure assertion over "Test.Vulkan.Proof.Retention",
-- which is the same decision the native cleanup executor in
-- "Test.Vulkan.Proof.Run" obeys. They open no window, initialize no GLFW, make
-- no native call, and need no @HETOIMASIA_NATIVE_SESSION@:
--
-- > bash tools/vulkan-proof/run-proof.sh --headless
--
-- selects exactly this module, before consent is read and before any native
-- procedure would run.
--
-- The cases are the ones a native run cannot be asked to produce on demand. A
-- present fence that times out, a device-idle boundary that fails, and a lost
-- device are the paths the retained macOS and Linux records never took, and
-- the paths on which destroying regardless would be a use-after-free rather
-- than a failed assertion. Each asserts the exact handles destroyed and
-- retained and their order, not only the verdict.
module Test.Vulkan.Proof.RetentionSpec (spec) where

import Control.Exception (toException)
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec

import Vulkan.Core10.Enums.Result (Result (..))
import Vulkan.Exception (VulkanException (..))

import Test.Vulkan.Proof.Findings (Failure (..), Outcome (..), TeardownFacts (..))
import Test.Vulkan.Proof.Record (renderRecord)
import Test.Vulkan.Proof.Retention

-- | The two slots a run builds, by the names it gives them.
first, second ∷ Text
first = "slot 0"
second = "slot 1"

-- | The whole plan, in the order teardown reaches it.
plan ∷ [Handle]
plan = teardownPlan [first, second]

-- | A run that presented on both slots and retired both, then reached a
-- boundary that held. This is the shape of every successful run.
wholeRun ∷ [Observation]
wholeRun =
  [ PresentAttempted first Succeeded
  , PresentFenceWaited first Succeeded
  , PresentAttempted second Succeeded
  , PresentFenceWaited second Succeeded
  , TeardownBoundaryReached Succeeded
  ]

destroyedIn, retainedIn ∷ [(Handle, Disposition)] → [Handle]
destroyedIn decisions = [handle | (handle, Destroy) ← decisions]
retainedIn decisions = [handle | (handle, Retain _) ← decisions]

reasonFor ∷ Handle → [(Handle, Disposition)] → Text
reasonFor handle decisions =
  case [reason | (candidate, Retain reason) ← decisions, candidate == handle] of
    (reason : _) → reason
    [] → ""

-- | Everything a retained present obligation must hold up: the slot's own two
-- handles, the swapchain, and every parent above them, through the window and
-- @glfwTerminate@ and the callback trampoline.
heldByAnUnretiredPresent ∷ Text → [Handle]
heldByAnUnretiredPresent slot =
  [ SlotPresentFence slot
  , SlotPresentSemaphore slot
  , TheSwapchain
  , TheLogicalDevice
  , TheWindowSurface
  , TheProofWindow
  , TheExplicitMessenger
  , TheVulkanInstance
  , TheCallbackTrampoline
  , GlfwTermination
  ]

spec ∷ Spec
spec = do
  describe "A whole run" $ do
    it "releases the same ten entries, in the same order" $ do
      let decisions = decide plan wholeRun
      releasedEntries [(handle, wasDestroyed d) | (handle, d) ← decisions] `shouldBe` teardownEntries
      length teardownEntries `shouldBe` 10

    it "retains nothing and destroys every handle in plan order" $ do
      let decisions = decide plan wholeRun
      retainedIn decisions `shouldBe` []
      destroyedIn decisions `shouldBe` plan

    it "reports the ordinary destruction rules, not device loss" $ do
      let standing = standingFrom wholeRun
      standing.standingRoute `shouldBe` OrdinaryRoute
      standing.standingBoundary `shouldBe` BoundaryHeld
      standing.standingPending `shouldBe` []

  describe "A present fence that times out" $ do
    -- Requirement 1. The device-idle boundary succeeds, which is exactly the
    -- trap: it is not evidence that the presentation retired, and teardown
    -- must not treat it as any.
    let observed =
          [ PresentAttempted first Succeeded
          , PresentFenceWaited first TimedOut
          , TeardownBoundaryReached Succeeded
          , PresentFenceWaited first TimedOut
          ]
        decisions = decide plan observed

    it "retains that slot's present fence and presentation semaphore, the swapchain, and every parent above them" $
      retainedIn decisions `shouldBe` heldByAnUnretiredPresent first

    it "destroys only what does not depend on the unretired present" $
      destroyedIn decisions
        `shouldBe` [ TheTeardownBoundary
                   , SlotWorkObjects first
                   , SlotWorkObjects second
                   , SlotPresentFence second
                   , SlotPresentSemaphore second
                   ]

    it "names the reason on each retained handle" $ do
      reasonFor (SlotPresentFence first) decisions
        `shouldSatisfy` Text.isInfixOf "present fence has not signalled"
      reasonFor (SlotPresentFence first) decisions
        `shouldSatisfy` Text.isInfixOf "VK_TIMEOUT"
      reasonFor TheSwapchain decisions `shouldSatisfy` Text.isInfixOf "unretired present"
      -- The parents say which child holds them, rather than repeating the
      -- present's own reason as though each had observed it.
      reasonFor TheProofWindow decisions `shouldSatisfy` Text.isInfixOf "the window surface is retained"
      reasonFor GlfwTermination decisions `shouldSatisfy` Text.isInfixOf "the proof window is retained"
      reasonFor TheCallbackTrampoline decisions `shouldSatisfy` Text.isInfixOf "the Vulkan instance is retained"

    it "is not device loss, however long the wait went unsatisfied" $ do
      (standingFrom observed).standingRoute `shouldBe` OrdinaryRoute
      releasedEntries [(handle, wasDestroyed d) | (handle, d) ← decisions] `shouldBe` ["the teardown boundary"]

  describe "A teardown boundary that fails without device loss" $ do
    -- Requirement 2.
    let observed =
          [ PresentAttempted first Succeeded
          , PresentFenceWaited first Succeeded
          , TeardownBoundaryReached OutOfHostMemory
          ]
        decisions = decide plan observed

    it "prohibits every release whose safety the boundary was to establish" $ do
      destroyedIn decisions `shouldBe` [TheTeardownBoundary]
      retainedIn decisions `shouldBe` drop 1 plan

    it "reports the boundary failure as the reason rather than a presentation" $ do
      (standingFrom observed).standingBoundary `shouldBe` BoundaryBroken "VK_ERROR_OUT_OF_HOST_MEMORY"
      reasonFor (SlotWorkObjects first) decisions
        `shouldSatisfy` Text.isInfixOf "the teardown boundary failed with VK_ERROR_OUT_OF_HOST_MEMORY"
      (standingFrom observed).standingRoute `shouldBe` OrdinaryRoute

    it "is not discharged by a later valid present fence" $ do
      -- The correction on this issue: requirement 5 discharges the
      -- presentation obligation and nothing else. Release needs every
      -- applicable condition, so a fence that signals afterwards leaves the
      -- unresolved boundary exactly where it was.
      let afterwards = decide plan (observed <> [PresentFenceWaited first Succeeded])
      retainedIn afterwards `shouldBe` drop 1 plan
      reasonFor TheSwapchain afterwards `shouldSatisfy` Text.isInfixOf "the teardown boundary failed"

  describe "Later valid present-fence evidence" $
    -- Requirement 5: the only route from retained to destroyed that is not
    -- device loss, and it releases in order.
    it "permits ordered release once the fence signals during teardown" $ do
      let retained =
            [ PresentAttempted first Succeeded
            , PresentFenceWaited first TimedOut
            , TeardownBoundaryReached Succeeded
            ]
          decisions = decide plan (retained <> [PresentFenceWaited first Succeeded])
      retainedIn (decide plan retained) `shouldBe` heldByAnUnretiredPresent first
      retainedIn decisions `shouldBe` []
      destroyedIn decisions `shouldBe` plan
      -- In order: the fence before the semaphore it retired, and the swapchain
      -- after both slots' fences.
      positionOf (SlotPresentFence first) plan
        `shouldSatisfy` (< positionOf (SlotPresentSemaphore first) plan)
      positionOf (SlotPresentFence second) plan `shouldSatisfy` (< positionOf TheSwapchain plan)

  describe "Device loss" $ do
    -- Requirement 3.
    it "permits destruction under the specification's own rule" $ do
      let observed =
            [ PresentAttempted first Succeeded
            , PresentFenceWaited first DeviceLost
            , TeardownBoundaryReached DeviceLost
            ]
          decisions = decide plan observed
      (standingFrom observed).standingRoute `shouldBe` DeviceLossRoute
      retainedIn decisions `shouldBe` []
      destroyedIn decisions `shouldBe` plan
      releasedEntries [(handle, wasDestroyed d) | (handle, d) ← decisions] `shouldBe` teardownEntries

    it "is never reached by promoting a timeout to it" $ do
      let timedOut =
            [ PresentAttempted first Succeeded
            , PresentFenceWaited first TimedOut
            , TeardownBoundaryReached Succeeded
            , PresentFenceWaited first TimedOut
            ]
      (standingFrom timedOut).standingRoute `shouldBe` OrdinaryRoute

    it "is established by the boundary alone as readily as by a fence" $ do
      let atTheBoundary = [PresentAttempted first Succeeded, TeardownBoundaryReached DeviceLost]
      (standingFrom atTheBoundary).standingRoute `shouldBe` DeviceLossRoute
      retainedIn (decide plan atTheBoundary) `shouldBe` []

  describe "A present rejected out-of-date or surface-lost" $ do
    -- Requirement 4: the error result alone releases nothing, because the
    -- presentation contract preserves the operations the call enqueued.
    it "counts its enqueued operations and holds the slot" $
      mapM_
        ( \result → do
            let decisions = decide plan [PresentAttempted first result, TeardownBoundaryReached Succeeded]
            presentEnqueuesOperations result `shouldBe` True
            retainedIn decisions `shouldBe` heldByAnUnretiredPresent first
            reasonFor (SlotPresentSemaphore first) decisions
              `shouldSatisfy` Text.isInfixOf (describeResult result)
        )
        [OutOfDate, SurfaceLost]

    it "releases the slot only on the fence, never on the error result" $ do
      let signalled =
            [ PresentAttempted first OutOfDate
            , TeardownBoundaryReached Succeeded
            , PresentFenceWaited first Succeeded
            ]
      retainedIn (decide plan signalled) `shouldBe` []

    it "creates no obligation for the specified no-effect results" $
      mapM_
        ( \result → do
            presentEnqueuesOperations result `shouldBe` False
            retainedIn (decide plan [PresentAttempted first result, TeardownBoundaryReached Succeeded])
              `shouldBe` []
        )
        [OutOfHostMemory, OutOfDeviceMemory]

  describe "An exception in place of a result" $ do
    -- The binding throws an error code rather than returning it, so the two
    -- have to classify the same way; an exception that carries no code at all
    -- establishes neither completion nor device loss.
    it "classifies a thrown Vulkan result as that result" $ do
      classifyResult SUCCESS `shouldBe` Succeeded
      classifyThrown (toException (VulkanException ERROR_DEVICE_LOST)) `shouldBe` DeviceLost
      classifyThrown (toException (VulkanException ERROR_OUT_OF_DATE_KHR)) `shouldBe` OutOfDate

    it "treats an exception carrying no result as evidence of nothing" $ do
      let thrown = classifyThrown (toException (userError "the proof raised something else"))
          decisions = decide plan [PresentAttempted first thrown, TeardownBoundaryReached Succeeded]
      thrown `shouldSatisfy` isNotAResult
      thrown `shouldSatisfy` (/= DeviceLost)
      -- Evidence of nothing is not evidence of completion: the obligation is
      -- assumed to exist, because one wrongly assumed costs a retained handle
      -- and one wrongly discharged costs a use-after-free.
      retainedIn decisions `shouldBe` heldByAnUnretiredPresent first
      (standingFrom [PresentAttempted first thrown]).standingRoute `shouldBe` OrdinaryRoute

    it "treats a boundary that threw as a boundary that failed" $ do
      let thrown = classifyThrown (toException (userError "vkDeviceWaitIdle raised"))
          decisions = decide plan [TeardownBoundaryReached thrown]
      retainedIn decisions `shouldBe` drop 1 plan

  describe "A run that stopped before the boundary was registered" $ do
    -- The procedure registers the boundary immediately after the frame slots
    -- and submits nothing until afterwards, so a plan without one holds no
    -- object with queue work outstanding. Withholding there would leak a
    -- session that owed nothing — and take the instance's own destruction
    -- diagnostics with it, which is where a validation layer reports a leak.
    let early = [TheLogicalDevice, TheWindowSurface, TheProofWindow, TheExplicitMessenger, TheVulkanInstance, TheCallbackTrampoline, GlfwTermination]

    it "releases what it registered" $ do
      let decisions = decide early []
      retainedIn decisions `shouldBe` []
      destroyedIn decisions `shouldBe` early

    it "still withholds when a registered boundary reached no result at all" $ do
      -- The boundary is first in teardown order, so a plan carrying one has
      -- run it. One that carries one and recorded nothing is a teardown that
      -- lost its own evidence, and that is not a reason to destroy.
      let decisions = decide plan []
      (standingFrom []).standingBoundary `shouldBe` BoundaryNotReached
      retainedIn decisions `shouldBe` drop 1 plan
      reasonFor TheLogicalDevice decisions
        `shouldSatisfy` Text.isInfixOf "the teardown boundary was never reached"

  describe "A recycled slot" $
    -- The obligation belongs to the present, not to the slot: a slot's earlier
    -- completion must not discharge the present it was reused for.
    it "is not discharged by the completion of the present before it" $ do
      let reused =
            [ PresentAttempted first Succeeded
            , PresentFenceWaited first Succeeded
            , PresentAttempted first Succeeded
            , PresentFenceWaited first TimedOut
            , TeardownBoundaryReached Succeeded
            ]
      map fst (standingFrom reused).standingPending `shouldBe` [first]
      retainedIn (decide plan reused) `shouldBe` heldByAnUnretiredPresent first

  describe "The record a stopped run renders" $ do
    -- The observations teardown made are not dropped for a stop: the release
    -- outcomes, the retained handles with their reasons, and the disposition
    -- are what a reader of a failed run most needs.
    let facts =
          TeardownFacts
            { teardownReleases = ["the teardown boundary"]
            , teardownFailures = []
            , teardownDestroyed = ["the command pool, rendering fence and acquisition semaphore of slot 0"]
            , teardownRetained = [("the present fence of slot 0", "its present fence has not signalled")]
            , teardownRoute = "ordinary: each release needed its own completion evidence"
            , teardownObservations = ["a wait on the present fence of slot 0 returned VK_TIMEOUT"]
            }
        rendered = renderRecord "title" "invocation" [] (Stopped (Failure "completion" "a reason") facts) False

    it "keeps the failing step and the failed verdict" $ do
      rendered `shouldSatisfy` Text.isInfixOf "Step: **completion**"
      rendered `shouldSatisfy` Text.isInfixOf "Verdict: **fail**"

    it "renders the retained handles, their reasons, and the disposition" $ do
      rendered `shouldSatisfy` Text.isInfixOf "the present fence of slot 0 — its present fence has not signalled"
      rendered `shouldSatisfy` Text.isInfixOf "a wait on the present fence of slot 0 returned VK_TIMEOUT"
      rendered `shouldSatisfy` Text.isInfixOf "destruction rules in force"
      rendered `shouldSatisfy` Text.isInfixOf "released, in order: the teardown boundary"

    it "still claims nothing the run did not establish" $
      rendered `shouldSatisfy` (not . Text.isInfixOf "observed in this run")

positionOf ∷ Handle → [Handle] → Int
positionOf handle = length . takeWhile (/= handle)

isNotAResult ∷ NativeResult → Bool
isNotAResult = \case
  NotAResult _ → True
  _ → False
