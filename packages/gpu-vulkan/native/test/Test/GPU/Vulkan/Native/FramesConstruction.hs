-- | A frame slot's synchronization and a presentation-pool record whose
-- construction fails after something was made, over stand-in native layers:
-- the rollback destroys each object made exactly once, newest first, whatever
-- a destruction before it did; the construction's failure stays primary with
-- every failed destruction retained beside it; and an object whose
-- destruction raised stays owned, in a record frame retirement keeps, with the
-- session failed and the destruction never tried again.
--
-- The frames' stand-in numbers what it makes from 9000, one handle a creation
-- — a creation that raised included — so a frame's first acquisition makes
-- the slot's acquisition semaphore 9000, its submission fence 9001 and its
-- cleanup fence 9002, then the pool record's render-finished semaphore 9003
-- and present fence 9004. A failure is raised from inside the one call an
-- example picks, after the call is recorded.
module Test.GPU.Vulkan.Native.FramesConstruction (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeException, fromException, throwIO, try)
import Control.Monad (forM)
import Data.IORef (atomicModifyIORef', newIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailures)
import Hetoimasia.GPU.Model (Outcome (..), SessionState (..), noteDeviceLoss, sessionState, usage, usageFrames)
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Naming (NativeObjectKind (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (TerminalCause (..))
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn
import Test.GPU.Vulkan.Native.StandIn (NamingFailure (..), failNaming, offerNaming, restoreNaming)

-- | A failure an example raises from inside one native call.
newtype Scripted = Scripted Text
  deriving (Eq, Show)

instance Exception Scripted

spec ∷ Spec
spec = describe "Frames construction rollback" $ do
  describe "a frame slot's synchronization" $ do
    it "keeps the submission fence owned when its rollback cannot destroy it after the cleanup fence's creation failed, and still destroys the semaphore" $ do
      rig ← newRig
      faults rig
        [ (createdFence, 1, throwIO (Scripted "create cleanup fence"))
        , (isDestruction, 0, throwIO (Scripted "destroy submission fence"))
        ]
      failure ← acquisitionFailure rig
      primaryOf failure `shouldBe` Just (Scripted "create cleanup fence")
      retainedOf failure `shouldBe` [Just (Scripted "destroy submission fence")]
      destructions rig `shouldReturn` [DestroyedFence 9001, DestroyedSemaphore 9000]
      [SlotView _ 0 sync] ← atomically (readSlots (rigFrames rig))
      (syncAcquire sync, syncAcquireState sync) `shouldBe` (9000, SemaphoreDestroyed)
      syncFence sync `shouldBe` 9001
      syncFenceState sync `shouldSatisfy` fenceUncertain
      (syncCleanup sync, syncCleanupState sync) `shouldBe` (0, FenceNeverCreated)
      syncDestruction sync `shouldSatisfy` isJust
      retainedAfter rig [DestroyedFence 9001, DestroyedSemaphore 9000] (\(FramesRetained _ _ slots _ pool) → (slots, pool) == ([0], []))

    it "goes on to destroy the submission fence and the semaphore when the cleanup fence's destruction raised after naming failed" $ do
      rig ← newRig
      offerNaming (rigRootsStandIn rig)
      failNaming (rigRootsStandIn rig) ObjectSemaphore
      faults rig [(isDestruction, 0, throwIO (Scripted "destroy cleanup fence"))]
      failure ← acquisitionFailure rig
      primaryOf failure `shouldBe` Nothing
      fromException failure `shouldBe` Just (NamingFailure ObjectSemaphore)
      retainedOf failure `shouldBe` [Just (Scripted "destroy cleanup fence")]
      destructions rig `shouldReturn` [DestroyedFence 9002, DestroyedFence 9001, DestroyedSemaphore 9000]
      [SlotView _ 0 sync] ← atomically (readSlots (rigFrames rig))
      (syncAcquireState sync, syncFenceState sync) `shouldBe` (SemaphoreDestroyed, FenceDestroyed)
      syncCleanup sync `shouldBe` 9002
      syncCleanupState sync `shouldSatisfy` fenceUncertain
      retainedAfter rig [DestroyedFence 9002, DestroyedFence 9001, DestroyedSemaphore 9000] (\(FramesRetained _ _ slots _ _) → slots == [0])

    it "retains every destruction that raised, in the order attempted, and attempts each object exactly once" $ do
      rig ← newRig
      offerNaming (rigRootsStandIn rig)
      failNaming (rigRootsStandIn rig) ObjectFence
      faults rig
        [ (isDestruction, 0, throwIO (Scripted "destroy cleanup fence"))
        , (isDestruction, 2, throwIO (Scripted "destroy acquisition semaphore"))
        ]
      failure ← acquisitionFailure rig
      fromException failure `shouldBe` Just (NamingFailure ObjectFence)
      retainedOf failure `shouldBe` [Just (Scripted "destroy cleanup fence"), Just (Scripted "destroy acquisition semaphore")]
      destructions rig `shouldReturn` [DestroyedFence 9002, DestroyedFence 9001, DestroyedSemaphore 9000]
      [SlotView _ 0 sync] ← atomically (readSlots (rigFrames rig))
      syncAcquireState sync `shouldSatisfy` semaphoreUncertain
      syncFenceState sync `shouldBe` FenceDestroyed
      syncCleanupState sync `shouldSatisfy` fenceUncertain
      -- Retirement keeps it under the device-loss rule too: nothing it holds
      -- is destroyed again, whatever was owed.
      inModel rig (Admitted . noteDeviceLoss)
      retainedAfter rig [DestroyedFence 9002, DestroyedFence 9001, DestroyedSemaphore 9000] (\(FramesRetained _ _ slots _ _) → slots == [0])

    it "rolls back completely, retaining nothing and failing nothing, when every destruction returns" $ do
      rig ← newRig
      offerNaming (rigRootsStandIn rig)
      failNaming (rigRootsStandIn rig) ObjectSemaphore
      failure ← acquisitionFailure rig
      fromException failure `shouldBe` Just (NamingFailure ObjectSemaphore)
      retainedOf failure `shouldBe` []
      destructions rig `shouldReturn` [DestroyedFence 9002, DestroyedFence 9001, DestroyedSemaphore 9000]
      atomically (readSlots (rigFrames rig)) `shouldReturn` []
      restoreNaming (rigRootsStandIn rig) ObjectSemaphore
      rolledBackCleanly rig

  describe "a presentation-pool record" $ do
    it "keeps the render-finished semaphore owned when the present fence's creation failed and its destruction raised, and keeps the slot it already published" $ do
      rig ← newRig
      faults rig
        [ (createdFence, 2, throwIO (Scripted "create present fence"))
        , (isDestruction, 0, throwIO (Scripted "destroy render-finished semaphore"))
        ]
      failure ← acquisitionFailure rig
      primaryOf failure `shouldBe` Just (Scripted "create present fence")
      retainedOf failure `shouldBe` [Just (Scripted "destroy render-finished semaphore")]
      destructions rig `shouldReturn` [DestroyedSemaphore 9003]
      [PoolView _ 0 pool] ← atomically (readPool (rigFrames rig))
      poolRendered pool `shouldBe` 9003
      poolRenderedState pool `shouldSatisfy` semaphoreUncertain
      (poolFence pool, poolFenceState pool, poolHolder pool) `shouldBe` (0, FenceNeverCreated, PoolFree)
      poolDestruction pool `shouldSatisfy` isJust
      -- The slot was complete before the pool record was begun, and stays.
      [SlotView _ 0 slot] ← atomically (readSlots (rigFrames rig))
      slot `shouldBe` SlotSync 9000 SemaphoreUnsignalled 9001 FenceIdle 9002 FenceIdle Nothing
      -- Retirement destroys the complete, idle slot as it always would, and
      -- keeps the record, destroying nothing of it again.
      retainedAfter rig ([DestroyedSemaphore 9003] <> slotRetired) (\(FramesRetained _ _ slots _ records) → (slots, records) == ([], [0]))

    it "goes on to destroy the render-finished semaphore when the present fence's destruction raised after naming failed" $ do
      rig ← newRig
      -- Naming is offered only once the slot's three objects are made and
      -- named, so it is the pool record's naming that fails.
      faults rig [(createdSemaphore, 1, offerNaming (rigRootsStandIn rig) >> failNaming (rigRootsStandIn rig) ObjectSemaphore), (isDestruction, 0, throwIO (Scripted "destroy present fence"))]
      failure ← acquisitionFailure rig
      fromException failure `shouldBe` Just (NamingFailure ObjectSemaphore)
      retainedOf failure `shouldBe` [Just (Scripted "destroy present fence")]
      destructions rig `shouldReturn` [DestroyedFence 9004, DestroyedSemaphore 9003]
      [PoolView _ 0 pool] ← atomically (readPool (rigFrames rig))
      (poolRendered pool, poolRenderedState pool) `shouldBe` (9003, SemaphoreDestroyed)
      poolFence pool `shouldBe` 9004
      poolFenceState pool `shouldSatisfy` fenceUncertain
      retainedAfter rig ([DestroyedFence 9004, DestroyedSemaphore 9003] <> slotRetired) (\(FramesRetained _ _ slots _ records) → (slots, records) == ([], [0]))

    it "rolls back completely, keeping only the slot, when every destruction returns" $ do
      rig ← newRig
      faults rig [(createdSemaphore, 1, offerNaming (rigRootsStandIn rig) >> failNaming (rigRootsStandIn rig) ObjectFence)]
      failure ← acquisitionFailure rig
      fromException failure `shouldBe` Just (NamingFailure ObjectFence)
      retainedOf failure `shouldBe` []
      destructions rig `shouldReturn` [DestroyedFence 9004, DestroyedSemaphore 9003]
      atomically (readPool (rigFrames rig)) `shouldReturn` []
      map viewSlotNumber <$> atomically (readSlots (rigFrames rig)) `shouldReturn` [0]
      restoreNaming (rigRootsStandIn rig) ObjectFence
      rolledBackCleanly rig

-- | Run each action from inside the call its predicate picks — the one at that
-- position, from zero, among the calls the predicate selects — after the
-- call is recorded.
faults ∷ Rig → [(FrameCall → Bool, Int, IO ())] → IO ()
faults rig scripted = do
  seen ← newIORef (Map.empty ∷ Map.Map Int Int)
  duringFrameCall (rigStandIn rig) $ \call → do
    -- Every count first, so an action that raises leaves none behind.
    due ← forM (zip [0 ∷ Int ..] scripted) $ \(number, (selects, position, action)) →
      if selects call
        then do
          earlier ← atomicModifyIORef' seen (\counts → (Map.insertWith (+) number 1 counts, Map.findWithDefault 0 number counts))
          pure [action | earlier == position]
        else pure []
    sequence_ (concat due)

createdFence, createdSemaphore ∷ FrameCall → Bool
createdFence = \case
  CreatedFence _ → True
  _ → False
createdSemaphore = \case
  CreatedSemaphore _ → True
  _ → False

-- | The failure the rig's first acquisition raised, its reservation given
-- back.
acquisitionFailure ∷ Rig → IO SomeException
acquisitionFailure rig =
  try (tryAcquireFrame (rigFrames rig) (rigTarget rig)) >>= \case
    Left failure → do
      usageFrames . usage <$> modelOf rig `shouldReturn` 0
      pure failure
    Right answer → do
      expectationFailure ("the acquisition did not raise: " <> show answer)
      throwIO (Scripted "unreachable")

primaryOf ∷ SomeException → Maybe Scripted
primaryOf = fromException

-- | Every cleanup failure retained beside the primary, in the order it
-- happened, as the scripted failure it was.
retainedOf ∷ SomeException → [Maybe Scripted]
retainedOf failure = [fromException inner | ExceptionWithContext _ inner ← map cleanupFailureException (cleanupFailures failure)]

destructions ∷ Rig → IO [FrameCall]
destructions rig = filter isDestruction <$> frameCalls (rigStandIn rig)

fenceUncertain ∷ FenceState → Bool
fenceUncertain = \case
  FenceUncertain _ → True
  _ → False

semaphoreUncertain ∷ SemaphoreState → Bool
semaphoreUncertain = \case
  SemaphoreUncertain _ → True
  _ → False

-- | Retirement's destruction of the complete slot the first acquisition
-- published.
slotRetired ∷ [FrameCall]
slotRetired = [DestroyedSemaphore 9000, DestroyedFence 9001, DestroyedFence 9002]

-- | The session failed with 'CleanupFailed', and the target's frames retire
-- without certifying anything. Every destruction attempted by then is the
-- one given: nothing the rollback attempted is attempted again.
retainedAfter ∷ Rig → [FrameCall] → (FramesRetained → Bool) → IO ()
retainedAfter rig attempted names = do
  refusedPrimary rig `shouldReturn'` \case
    Just (TerminalCleanupFailed reason) → reason `shouldSatisfy` Text.isPrefixOf "constructing "
    other → expectationFailure ("the session did not fail with CleanupFailed: " <> show other)
  retireTargetFrames (rigFrames rig) (rigTarget rig) `raises` names
  destructions rig `shouldReturn` attempted
  clean rig

-- | Nothing retained and nothing failed: the session runs on, and the next
-- acquisition builds what it needs again.
rolledBackCleanly ∷ Rig → IO ()
rolledBackCleanly rig = do
  sessionState <$> modelOf rig `shouldReturn` SessionRunning
  duringFrameCall (rigStandIn rig) (\_ → pure ())
  frame ← owned rig
  phaseOf rig (ownedFrame frame) `shouldReturn'` (`shouldSatisfy` isJust)
  clean rig
