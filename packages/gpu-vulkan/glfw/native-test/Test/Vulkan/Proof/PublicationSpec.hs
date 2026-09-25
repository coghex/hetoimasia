{-# LANGUAGE OverloadedRecordDot #-}

-- | The present handoff under cancellation, exercised headlessly.
--
-- Every example here drives "Test.Vulkan.Proof.Publication" — the same
-- 'publishPresent' the native path in "Test.Vulkan.Proof.Run" calls, the same
-- ledger it writes to, the same 'catchAll' that names the step a run stopped
-- at, and the same 'Test.Vulkan.Proof.Retention.decide' the cleanup executor
-- obeys. Only @vkQueuePresentKHR@ is replaced, because a native call cannot be
-- asked to be cancelled at a chosen instant. They open no window, initialize
-- no GLFW, make no native call, and need no @HETOIMASIA_NATIVE_SESSION@:
--
-- > bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --match cancellation
--
-- The cancellation is real rather than simulated: a second thread's 'throwTo',
-- delivered at the first point the code under test permits one. Determinism
-- comes from 'throwTo' itself and not from a delay — see 'armCancellation' —
-- so there is no sleep here, no retry budget, and nothing that could pass by
-- luck. An unprotected handoff is cancelled inside the stand-in enqueue
-- instead of after it, which is a different recorded result and a different
-- outcome, so removing the mask fails these examples rather than weakening
-- them.
module Test.Vulkan.Proof.PublicationSpec (spec) where

import Control.Concurrent (ThreadId, forkOn, myThreadId, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , MaskingState (Unmasked)
  , SomeException
  , displayException
  , getMaskingState
  , throwIO
  , throwTo
  , toException
  , try
  )
import Data.Foldable (for_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (..), threadStatus)
import Test.Hspec

import Vulkan.Core10.Enums.Result (Result (..))
import Vulkan.Exception (VulkanException (..))

import Test.Vulkan.Proof.Findings (Failure (..))
import Test.Vulkan.Proof.Ownership (Ledger, newLedger, observations, observe)
import Test.Vulkan.Proof.Publication (catchAll, publishPresent)
import Test.Vulkan.Proof.Retention
  ( Disposition (..)
  , Handle (..)
  , NativeResult (..)
  , Observation (..)
  , SlotName
  , Standing (..)
  , decide
  , isDestruction
  , standingFrom
  , teardownPlan
  )

-- | The two slots a run builds, by the names it gives them.
first, second ∷ SlotName
first = "slot 0"
second = "slot 1"

-- | The whole plan, in the order teardown reaches it.
plan ∷ [Handle]
plan = teardownPlan [first, second]

-- --------------------------------------------------------------------------
-- One attempt

-- | How one present handoff ended, as the run itself would see it.
data Ending
  = StoppedAt Failure
    -- ^ The production translation named the step and the failure.
  | Completed NativeResult
    -- ^ The handoff returned and the run carried on.
  | Escaped Text
    -- ^ The cancellation left the run entirely, which is neither.
  deriving (Eq, Show)

-- | Everything one attempt leaves behind: how it ended, whether the stand-in
-- enqueue ran to completion, whether the slot was marked presented, and what
-- the ledger carries.
data Attempt = Attempt
  { attemptEnding ∷ Ending
  , attemptEnqueued ∷ Bool
  , attemptPresented ∷ Bool
  , attemptObservations ∷ [Observation]
  }

-- | Run one present handoff through the production path, with a stand-in for
-- the native call, and report what it left behind.
attempt ∷ Ledger → SlotName → (IORef Bool → IO Result) → IO Attempt
attempt ledger slot enqueue = do
  enqueued ← newIORef False
  presented ← newIORef False
  ended ←
    onItsOwnThread $
      catchAll
        (Completed . snd <$> publishPresent ledger slot presented (enqueue enqueued))
        (pure . StoppedAt)
  Attempt (either escaped id ended)
    <$> readIORef enqueued
    <*> readIORef presented
    <*> observations ledger
  where
    escaped = Escaped . Text.pack . displayException

-- | Run the attempt on a thread of its own, on 'theCapability'.
--
-- A handoff that fails to protect its publication is cancelled for real, and
-- the thread it was cancelled on dies; that must be this thread rather than
-- the one Hspec is reporting on, so the failure is an assertion about what was
-- recorded rather than a dead runner.
onItsOwnThread ∷ IO a → IO (Either SomeException a)
onItsOwnThread action = do
  done ← newEmptyMVar
  _ ← forkOn theCapability (try @SomeException action >>= putMVar done)
  takeMVar done

-- | The one capability the attempt and its killer both run on.
--
-- 'throwTo' between two threads on the same capability is settled where it is
-- made: the target is masked, so the exception is on its queue before the
-- caller is recorded as waiting for it. Across capabilities it is a message
-- instead, and the caller is recorded as waiting from the moment it sends one
-- — which is a state this example must not mistake for "the cancellation is
-- pending against the target", because it is not yet. Pinning both threads
-- removes that distinction rather than racing with it, so the examples read
-- the same under @-N1@ and under any other @-N@.
theCapability ∷ Int
theCapability = 0

-- --------------------------------------------------------------------------
-- The stand-in enqueue

-- | The stand-in for @vkQueuePresentKHR@: it performs the effect a present
-- performs — from here on the device owes this slot's present fence — arms a
-- cancellation of the calling thread, and then reports the result the call
-- reported.
--
-- The order is what makes it faithful. The effect exists before the
-- cancellation can be taken, exactly as it does the instant the real call
-- returns, and the result is reported after it, exactly as the real one's is.
cancelledEnqueue ∷ Result → IORef Bool → IO Result
cancelledEnqueue reported enqueued = do
  writeIORef enqueued True
  armCancellation
  pure reported

-- | The same stand-in without a cancellation: the ordinary path, which this
-- change must leave exactly as it was.
plainEnqueue ∷ Result → IORef Bool → IO Result
plainEnqueue reported enqueued = reported <$ writeIORef enqueued True

-- | A stand-in that throws instead of returning, which is how the binding
-- reports an error code and how anything else that goes wrong arrives.
throwingEnqueue ∷ SomeException → IORef Bool → IO Result
throwingEnqueue failure enqueued = writeIORef enqueued True *> throwIO failure

-- | Arrange for this thread to be cancelled at the first point the code under
-- test permits one, and do not return until that cancellation is certain.
--
-- 'throwTo' does not return until its exception has been raised in the target,
-- and it blocks while the target is masked. So a killer sitting in
-- 'BlockedOnException' is exactly the state "a cancellation is pending against
-- us, and will be taken the moment we are unmasked" — and waiting for that
-- state is what makes these examples deterministic instead of timed. There is
-- no sleep, no retry budget, and no window in which the two threads could race
-- to a different answer. Both threads run on 'theCapability', which is what
-- makes that state mean what it says.
--
-- Where the cancellation then lands is decided by the code under test, which
-- is the point. A masked handoff takes it after the publication, where
-- 'Test.Vulkan.Proof.Publication.publishing' restores the caller's masking
-- state. An unmasked one never lets the killer block at all: 'throwTo' raises
-- immediately, here, before this stand-in has reported its result. Either way
-- this wait ends — the loop sees the killer blocked, or is itself cancelled.
armCancellation ∷ IO ()
armCancellation = do
  target ← myThreadId
  killer ← forkOn theCapability (throwTo target ThreadKilled)
  awaitPending killer

awaitPending ∷ ThreadId → IO ()
awaitPending killer =
  threadStatus killer >>= \case
    ThreadBlocked BlockedOnException → pure ()
    -- A killer that is already done raised its exception before returning, so
    -- there is nothing left to wait for either way.
    ThreadFinished → pure ()
    ThreadDied → pure ()
    -- 'yield' rather than a delay: the killer is runnable and only needs the
    -- capability, so this terminates with one capability as readily as with
    -- several, and it is not a retry — the state it waits for is reached once
    -- and never left.
    _ → yield *> awaitPending killer

-- --------------------------------------------------------------------------
-- What teardown then sees

-- | What teardown observes after such a stop: the device-idle boundary, and
-- the bounded wait 'Test.Vulkan.Proof.Run.probePresentFences' takes on every
-- slot the ledger still says is owed.
--
-- The boundary succeeds, which is the whole trap. Device idle is not evidence
-- that a presentation retired, so a slot whose obligation was never recorded
-- is one this probe never reaches and this boundary appears to clear.
afterTeardown ∷ Ledger → IO [Observation]
afterTeardown ledger = do
  observe ledger (TeardownBoundaryReached Succeeded)
  recorded ← observations ledger
  for_ (map fst (standingFrom recorded).standingPending) $ \slot →
    observe ledger (PresentFenceWaited slot TimedOut)
  observations ledger

-- | Everything a retained present obligation must hold up: the slot's own two
-- handles, the swapchain, and every parent above them.
heldByAnUnretiredPresent ∷ SlotName → [Handle]
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

destroyedIn ∷ [(Handle, Disposition)] → [Handle]
destroyedIn decisions = [handle | (handle, Destroy) ← decisions, isDestruction handle]

retainedIn ∷ [(Handle, Disposition)] → [Handle]
retainedIn decisions = [handle | (handle, Retain _) ← decisions]

reasonFor ∷ Handle → [(Handle, Disposition)] → Text
reasonFor handle decisions =
  case [reason | (candidate, Retain reason) ← decisions, candidate == handle] of
    (reason : _) → reason
    [] → ""

-- --------------------------------------------------------------------------
-- The examples

spec ∷ Spec
spec = do
  describe "A cancellation taken at the present handoff" $ do
    (taken, torndown, decisions) ← runIO $ do
      ledger ← newLedger
      taken ← attempt ledger first (cancelledEnqueue SUCCESS)
      torndown ← afterTeardown ledger
      pure (taken, torndown, decide plan torndown)

    it "records the presentation the enqueue created before it is taken" $ do
      -- Requirement 1. The enqueue ran to completion, so the obligation exists
      -- on the device; the journal has to carry it whatever happened next.
      taken.attemptEnqueued `shouldBe` True
      taken.attemptPresented `shouldBe` True
      take 1 taken.attemptObservations `shouldBe` [PresentAttempted first Succeeded]

    it "preserves the result the present reported rather than the exception that stopped the run" $
      -- A cancellation deferred until after the result was recorded happened to
      -- the run, not to the present. Recording it as an exception would lose
      -- what the device actually reported.
      [result | PresentAttempted _ result ← taken.attemptObservations]
        `shouldBe` [Succeeded]

    it "stops the run at the presentation step, carrying the cancellation's own failure" $
      -- Requirement 2, through the production translation: 'publishPresent'
      -- takes the deferred cancellation and 'catchAll' names the step.
      -- Without that the same cancellation reaches 'catchAll' raw and is
      -- reported as an unexpected exception at no step at all.
      taken.attemptEnding `shouldBe` StoppedAt (Failure "presentation" "thread killed")

    it "keeps teardown's own boundary and fence-wait observations beside it" $ do
      -- The stop does not replace what teardown then observed, and what
      -- teardown observed does not replace the stop.
      torndown
        `shouldBe` [ PresentAttempted first Succeeded
                   , TeardownBoundaryReached Succeeded
                   , PresentFenceWaited first TimedOut
                   ]
      taken.attemptEnding `shouldBe` StoppedAt (Failure "presentation" "thread killed")

    it "retains the slot's present fence and presentation semaphore, the swapchain, and every parent" $ do
      -- Requirement 3, on a fresh slot: device idle succeeded, the present
      -- fence did not, and nothing below the unretired present may go.
      retainedIn decisions `shouldBe` heldByAnUnretiredPresent first
      destroyedIn decisions
        `shouldBe` [ SlotWorkObjects first
                   , SlotWorkObjects second
                   , SlotPresentFence second
                   , SlotPresentSemaphore second
                   ]

    it "names each retained handle and why it was retained" $ do
      reasonFor (SlotPresentFence first) decisions
        `shouldSatisfy` Text.isInfixOf "its presentation was enqueued and reported VK_SUCCESS"
      reasonFor (SlotPresentSemaphore first) decisions
        `shouldSatisfy` Text.isInfixOf "present fence has not signalled"
      reasonFor TheSwapchain decisions `shouldSatisfy` Text.isInfixOf "unretired present"
      reasonFor TheLogicalDevice decisions
        `shouldSatisfy` Text.isInfixOf "the present fence of slot 0 is retained"
      reasonFor GlfwTermination decisions `shouldSatisfy` Text.isInfixOf "the proof window is retained"

  describe "A cancellation at the handoff of a recycled slot" $ do
    (taken, torndown, decisions) ← runIO $ do
      ledger ← newLedger
      -- The slot's earlier present, retired in full before it was reused.
      observe ledger (PresentAttempted first Succeeded)
      observe ledger (PresentFenceWaited first Succeeded)
      taken ← attempt ledger first (cancelledEnqueue SUBOPTIMAL_KHR)
      torndown ← afterTeardown ledger
      pure (taken, torndown, decide plan torndown)

    it "records the new present rather than carrying the retired one forward" $ do
      taken.attemptEnqueued `shouldBe` True
      [result | PresentAttempted _ result ← taken.attemptObservations]
        `shouldBe` [Succeeded, Suboptimal]
      taken.attemptEnding `shouldBe` StoppedAt (Failure "presentation" "thread killed")

    it "reopens the obligation the earlier present's completion had closed" $ do
      map fst (standingFrom torndown).standingPending `shouldBe` [first]
      reasonFor (SlotPresentFence first) decisions
        `shouldSatisfy` Text.isInfixOf "VK_SUBOPTIMAL_KHR"

    it "retains exactly what the fresh slot's cancellation retains" $ do
      retainedIn decisions `shouldBe` heldByAnUnretiredPresent first
      destroyedIn decisions
        `shouldBe` [ SlotWorkObjects first
                   , SlotWorkObjects second
                   , SlotPresentFence second
                   , SlotPresentSemaphore second
                   ]

  describe "A present handoff no cancellation reaches" $ do
    it "records the result and returns, exactly as it did before" $ do
      ledger ← newLedger
      taken ← attempt ledger first (plainEnqueue SUCCESS)
      taken.attemptEnqueued `shouldBe` True
      taken.attemptPresented `shouldBe` True
      taken.attemptEnding `shouldBe` Completed Succeeded
      taken.attemptObservations `shouldBe` [PresentAttempted first Succeeded]

    it "leaves the caller unmasked, so the waits after it are as interruptible as ever" $ do
      -- Requirement 5: the mask covers the handoff and stops there. A wait that
      -- inherited it would be a native call made unstoppable, which the
      -- harness contract forbids.
      ledger ← newLedger
      presented ← newIORef False
      state ←
        publishPresent ledger first presented (SUCCESS <$ getMaskingState)
          *> getMaskingState
      state `shouldBe` Unmasked

    it "keeps the classification of a call that threw" $ do
      -- Requirement 4: an error code the binding threw is still that code, and
      -- an exception carrying no code is still evidence of nothing.
      for_
        [ (VulkanException ERROR_OUT_OF_DATE_KHR, OutOfDate)
        , (VulkanException ERROR_OUT_OF_HOST_MEMORY, OutOfHostMemory)
        ]
        $ \(thrown, expected) → do
          ledger ← newLedger
          taken ← attempt ledger first (throwingEnqueue (toSome thrown))
          taken.attemptObservations `shouldBe` [PresentAttempted first expected]

      ledger ← newLedger
      taken ← attempt ledger first (throwingEnqueue (toSome (userError "the present raised something else")))
      [result | PresentAttempted _ result ← taken.attemptObservations]
        `shouldSatisfy` all isNotAResult

toSome ∷ Exception e ⇒ e → SomeException
toSome = toException

isNotAResult ∷ NativeResult → Bool
isNotAResult = \case
  NotAResult _ → True
  _ → False
