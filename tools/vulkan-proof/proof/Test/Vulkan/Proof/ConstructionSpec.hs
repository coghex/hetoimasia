{-# LANGUAGE OverloadedRecordDot #-}

-- | Composite construction, exercised headlessly.
--
-- Every example here drives the same code the native path drives: the same
-- 'fillSlot' and 'runCapture' sequences from "Test.Vulkan.Proof.Construction",
-- the same 'holding' and 'releasing' handoffs, the same cleanup stack, the
-- same 'runCleanups' executor, and the same pure release decision in
-- "Test.Vulkan.Proof.Retention". Only the native layer is a stand-in, and it
-- is a stand-in precisely so that the step a run fails at can be chosen:
--
-- > bash tools/vulkan-proof/run-proof.sh --headless
--
-- selects these alongside the retention examples, before consent is read and
-- before any native procedure would run. They open no window, initialize no
-- GLFW, and make no native call.
--
-- A native run cannot be asked to fail its fifth @vkCreateSemaphore@, or to
-- fail a memory allocation after a buffer was created, and those are exactly
-- the paths on which an unowned handle becomes a @vkDestroyDevice@ over live
-- device children rather than a failed assertion. So they are asserted here,
-- against what teardown actually released, in what order, and what it
-- retained and why.
module Test.Vulkan.Proof.ConstructionSpec (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, throwTo)
import Control.Exception (Exception, SomeException, displayException, throwIO, try)
import Control.Monad (forM, forM_, when)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Test.Hspec

import Test.Vulkan.Proof.Construction
  ( CaptureOps (..)
  , CapturePlaces
  , SlotOps (..)
  , capturePlaceReleases
  , fillSlot
  , newCapturePlaces
  , newSlotPlaces
  , runCapture
  , slotPlaceReleases
  )
import Test.Vulkan.Proof.Findings (Failure (..), Outcome (..), TeardownFacts (..))
import Test.Vulkan.Proof.Journal (newJournal)
import Test.Vulkan.Proof.Record (renderRecord)
import Test.Vulkan.Proof.Ownership
  ( Cleanups
  , Ledger
  , newCleanups
  , newLedger
  , observe
  , onExit
  , onExitRecallable
  , runCleanups
  )
import Test.Vulkan.Proof.Retention
  ( Handle (..)
  , NativeResult (..)
  , Observation (..)
  , SlotName
  , describeResult
  , teardownEntries
  )

-- --------------------------------------------------------------------------
-- The stand-in native layer

-- | A failure injected at a chosen step of a construction, standing in for the
-- allocation error a native call reports by throwing.
newtype Injected = Injected Text

instance Show Injected where
  show (Injected what) = Text.unpack what

instance Exception Injected

-- | What the stand-in layer did, in the order it did it.
--
-- Both logs are appended to rather than replaced, because the questions these
-- examples ask are about counts and order: an object released twice and an
-- object released once look identical to a set.
data Fake = Fake
  { fakeStep ∷ IORef Int
  , fakeCreated ∷ IORef [Text]
  , fakeReleased ∷ IORef [Text]
  }

newFake ∷ IO Fake
newFake = Fake <$> newIORef 0 <*> newIORef [] <*> newIORef []

created ∷ Fake → IO [Text]
created fake = readIORef fake.fakeCreated

releasedBy ∷ Fake → IO [Text]
releasedBy fake = readIORef fake.fakeReleased

-- | Take the next step's ordinal, and fail if it is the one being injected at.
--
-- Every fallible call the constructions make goes through this, whether or not
-- it produces a handle, so "fail the nth step" reaches a bind, a completion
-- wait, a mapping and a present as readily as it reaches a create.
step ∷ Fake → Maybe Int → Text → IO ()
step fake failAt what = do
  ordinal ← atomicModifyIORef' fake.fakeStep (\next → (next + 1, next))
  when (Just ordinal == failAt) (throwIO (Injected (what <> " failed")))

-- | A stand-in acquisition: the object is its own name, and the name is
-- recorded before it is handed back.
acquire ∷ Fake → Maybe Int → Text → IO Text
acquire fake failAt name = do
  step fake failAt name
  modifyIORef' fake.fakeCreated (<> [name])
  pure name

-- | A stand-in release. The attempt is recorded before it can fail, so a
-- release that throws is still visible as having been attempted exactly once.
release ∷ Fake → [Text] → Text → IO ()
release fake failing name = do
  modifyIORef' fake.fakeReleased (<> [name])
  when (name `elem` failing) (throwIO (Injected ("releasing " <> name <> " failed")))

-- | One slot's stand-in native layer. The two semaphores and the two fences
-- share a create in 'SlotOps', as they do natively, so each takes the next of
-- its own role names.
slotOpsFor ∷ Fake → Maybe Int → [Text] → SlotName → IO (SlotOps Text Text Text Text)
slotOpsFor fake failAt failing name = do
  semaphores ← newIORef [name <> " acquisition semaphore", name <> " presentation semaphore"]
  fences ← newIORef [name <> " rendering fence", name <> " present fence"]
  let nextRole ref =
        atomicModifyIORef' ref $ \case
          (role : rest) → (rest, role)
          [] → ([], name <> " asked for more than it builds")
  pure
    SlotOps
      { createSlotSemaphore = nextRole semaphores >>= acquire fake failAt
      , destroySlotSemaphore = release fake failing
      , createSlotFence = nextRole fences >>= acquire fake failAt
      , destroySlotFence = release fake failing
      , createSlotPool = acquire fake failAt (name <> " command pool")
      , destroySlotPool = release fake failing
      , allocateSlotCommands = \pool → acquire fake failAt (pool <> "'s command buffer")
      }

-- | The capture path's stand-in native layer. Its present records the same
-- obligation on the ledger the native one does, so the retention rule sees
-- what it would see.
captureOpsFor ∷ Fake → Ledger → Maybe Int → [Text] → CaptureOps Text Text Text
captureOpsFor fake ledger failAt failing =
  CaptureOps
    { captureCreateBuffer = acquire fake failAt captureBufferName
    , captureDestroyBuffer = release fake failing
    , captureAllocateMemory = \_ → acquire fake failAt captureMemoryName
    , captureFreeMemory = release fake failing
    , captureBindMemory = \_ _ → step fake failAt "binding the capture memory"
    , captureAcquireImage = do
        step fake failAt "acquiring an image for the capture"
        pure "the captured image"
    , captureRecordAndSubmit = \_ _ → step fake failAt "the capture submission"
    , captureAwaitSubmission = step fake failAt "the capture completion wait"
    , captureReadBack = \_ → do
        step fake failAt "mapping the capture memory"
        pure capturedBytes
    , capturePresent = \_ → do
        -- The native present records the obligation the instant the call
        -- returns and retires it only when the present fence signals, so a
        -- present that fails here leaves the same unretired obligation the
        -- native one would, and the retention rule sees what it would see.
        observe ledger (PresentAttempted captureSlot Succeeded)
        step fake failAt "the capture present"
        observe ledger (PresentFenceWaited captureSlot Succeeded)
    }

captureBufferName, captureMemoryName, captureSlot ∷ Text
captureBufferName = "the capture buffer"
captureMemoryName = "the capture memory"
captureSlot = "slot 0"

capturedBytes ∷ [Word32]
capturedBytes = [255, 0, 255, 255]

-- --------------------------------------------------------------------------
-- The sessions these examples run

-- | The handles the procedure already owns by the time either composite is
-- built, in the order it registers them.
--
-- The device is the one that matters: it is registered above every child, so a
-- child released after it in the log would be the very use-after-free this
-- issue is about, visible rather than inferred.
sessionParents ∷ [Text]
sessionParents =
  [ "GLFW"
  , "the callback trampoline"
  , "the Vulkan instance"
  , "the explicit debug messenger"
  , "the proof window"
  , "the window surface"
  , "the logical device"
  , "the swapchain"
  ]

registerParents ∷ Fake → [Text] → Cleanups → IO ()
registerParents fake failing cleanups =
  forM_
    (zip sessionParents parentHandles)
    (\(name, handle) → onExit cleanups handle (release fake failing name))
  where
    parentHandles =
      [ GlfwTermination
      , TheCallbackTrampoline
      , TheVulkanInstance
      , TheExplicitMessenger
      , TheProofWindow
      , TheWindowSurface
      , TheLogicalDevice
      , TheSwapchain
      ]

-- | The teardown boundary, registered as the procedure registers it and
-- reporting what this run's boundary reported.
registerBoundary ∷ Ledger → NativeResult → Cleanups → IO ()
registerBoundary ledger result cleanups =
  onExit cleanups TheTeardownBoundary $ do
    observe ledger (TeardownBoundaryReached result)
    when (result /= Succeeded) (throwIO (Injected ("the boundary reported " <> describeResult result)))

-- | What one run of a composite left behind.
data Session = Session
  { sessionFake ∷ Fake
  , sessionFacts ∷ TeardownFacts
  , sessionStopped ∷ Maybe Text
    -- ^ The primary failure, if the construction stopped.
  }

-- | Build both slots with the stand-in layer, then tear the session down.
--
-- The registration order is the procedure's: the parents first, then every one
-- of both slots' releases before either slot's first native object exists, then
-- the boundary.
slotSession ∷ Maybe Int → [Text] → IO Session
slotSession failAt failing = do
  fake ← newFake
  cleanups ← newCleanups
  ledger ← newLedger
  journal ← newJournal
  registerParents fake failing cleanups
  outcome ← try @SomeException $ do
    let names = ["slot 0", "slot 1"]
    operations ← forM names (slotOpsFor fake failAt failing)
    places ← forM names (const newSlotPlaces)
    for_ (reverse (concat (zipWith3 slotPlaceReleases operations names places))) $ \(what, action) →
      onExit cleanups what action
    built ← forM (zip operations places) (uncurry fillSlot)
    -- Exactly where the procedure registers it: after both slots exist and
    -- before anything is submitted. A construction that stops never reaches
    -- it, which is the plan "Test.Vulkan.Proof.RetentionSpec" calls a run that
    -- stopped before the boundary was registered.
    registerBoundary ledger Succeeded cleanups
    pure built
  facts ← runCleanups journal ledger cleanups
  pure (Session fake facts (either (Just . stopReason) (const Nothing) outcome))

-- | Run the capture with the stand-in layer, then tear the session down.
captureSession ∷ Maybe Int → [Text] → NativeResult → IO Session
captureSession failAt failing boundary = do
  fake ← newFake
  cleanups ← newCleanups
  ledger ← newLedger
  journal ← newJournal
  registerParents fake failing cleanups
  outcome ← try @SomeException $ do
    places ← newCapturePlaces ∷ IO (CapturePlaces Text Text)
    let operations = captureOpsFor fake ledger failAt failing
    recall ←
      forM (reverse (capturePlaceReleases operations places)) $ \(what, action) →
        onExitRecallable cleanups what action
    registerBoundary ledger boundary cleanups
    observed ← runCapture operations places
    sequence_ recall
    pure observed
  facts ← runCleanups journal ledger cleanups
  pure (Session fake facts (either (Just . stopReason) (const Nothing) outcome))

-- | The primary failure, as the run would carry it into its own record.
stopReason ∷ SomeException → Text
stopReason = Text.pack . displayException

-- | A run that builds both slots, runs the capture to its end, and tears the
-- whole session down — the shape of every run the retained records were
-- produced on.
--
-- The registration order is the procedure's throughout: the parents, both
-- slots' six releases before either slot's first object, the capture's two
-- recallable releases, and the boundary last so it runs first.
wholeSession ∷ IO Session
wholeSession = do
  fake ← newFake
  cleanups ← newCleanups
  ledger ← newLedger
  journal ← newJournal
  registerParents fake [] cleanups
  outcome ← try @SomeException $ do
    let names = ["slot 0", "slot 1"]
    operations ← forM names (slotOpsFor fake Nothing [])
    places ← forM names (const newSlotPlaces)
    for_ (reverse (concat (zipWith3 slotPlaceReleases operations names places))) $ \(what, action) →
      onExit cleanups what action
    _ ← forM (zip operations places) (uncurry fillSlot)
    capturePlaces ← newCapturePlaces ∷ IO (CapturePlaces Text Text)
    let captureOperations = captureOpsFor fake ledger Nothing []
    recall ←
      forM (reverse (capturePlaceReleases captureOperations capturePlaces)) $ \(what, action) →
        onExitRecallable cleanups what action
    registerBoundary ledger Succeeded cleanups
    observed ← runCapture captureOperations capturePlaces
    sequence_ recall
    pure observed
  facts ← runCleanups journal ledger cleanups
  pure (Session fake facts (either (Just . stopReason) (const Nothing) outcome))

-- --------------------------------------------------------------------------
-- Small assertions

occurrences ∷ Text → [Text] → Int
occurrences name = length . filter (== name)

positionIn ∷ Text → [Text] → Int
positionIn name = length . takeWhile (/= name)

-- | Every object the run created that has a cleanup owner of its own.
--
-- A command buffer does not: @vkDestroyCommandPool@ frees the buffers its pool
-- allocated, so the pool is its owner and a separate release of it would be a
-- second release of an object already gone.
ownedCreations ∷ [Text] → [Text]
ownedCreations = filter (not . Text.isSuffixOf "command buffer")

-- | The ownership invariant this issue exists to establish, asserted over one
-- run: every object that was created was released exactly once, and every one
-- of them was released before the device that owns it.
everyChildOwnedAndFreedBeforeTheDevice ∷ Session → Expectation
everyChildOwnedAndFreedBeforeTheDevice session = do
  built ← created session.sessionFake
  gone ← releasedBy session.sessionFake
  forM_ (ownedCreations built) $ \child → do
    (child, occurrences child gone) `shouldBe` (child, 1)
    (child, positionIn child gone < positionIn "the logical device" gone) `shouldBe` (child, True)

-- --------------------------------------------------------------------------

spec ∷ Spec
spec = do
  describe "A frame slot whose construction stops" $ do
    -- Requirement 1. `newSlot` built two semaphores, two fences, a command pool
    -- and a command buffer with no owner until both slots were whole, so a
    -- failure at any of these twelve steps left every earlier child of both
    -- slots outside the cleanup stack while the device release registered above
    -- them still ran.
    let steps = [0 .. 11] ∷ [Int]

    forM_ steps $ \failAt ->
      it ("releases every child it created when step " <> show failAt <> " fails") $ do
        session ← slotSession (Just failAt) []
        session.sessionStopped `shouldSatisfy` maybe False (Text.isInfixOf "failed")
        everyChildOwnedAndFreedBeforeTheDevice session
        -- Nothing is withheld: the run never submitted anything, and the
        -- boundary it registered held.
        session.sessionFacts.teardownRetained `shouldBe` []
        session.sessionFacts.teardownFailures `shouldBe` []

    it "creates exactly the prefix of children the failing step allows" $ do
      -- Six steps per slot, in one order, so the count is the step's ordinal:
      -- a failure at step 7 is a whole first slot plus one child of the second.
      forM_ [0 .. 11 ∷ Int] $ \failAt → do
        session ← slotSession (Just failAt) []
        built ← created session.sessionFake
        (failAt, length built) `shouldBe` (failAt, failAt)

    it "destroys a slot's children in dependency order" $ do
      session ← slotSession (Just 11) []
      gone ← releasedBy session.sessionFake
      -- The pool before the rendering fence and the acquisition semaphore it
      -- is grouped with, and the present fence before the presentation
      -- semaphore it retired, which is the order
      -- VK_EXT_swapchain_maintenance1 names.
      positionIn "slot 1 command pool" gone
        `shouldSatisfy` (< positionIn "slot 1 rendering fence" gone)
      positionIn "slot 0 present fence" gone
        `shouldSatisfy` (< positionIn "slot 0 presentation semaphore" gone)

    it "owns a command buffer through its command pool rather than separately" $ do
      session ← slotSession Nothing []
      built ← created session.sessionFake
      gone ← releasedBy session.sessionFake
      let buffers = filter (Text.isSuffixOf "command buffer") built
      length buffers `shouldBe` 2
      forM_ buffers $ \buffer → occurrences buffer gone `shouldBe` 0
      forM_ ["slot 0 command pool", "slot 1 command pool"] $ \pool →
        occurrences pool gone `shouldBe` 1

    it "never destroys a handle the failing step never created" $ do
      session ← slotSession (Just 3) []
      gone ← releasedBy session.sessionFake
      -- The present fence of slot 0 is what step 3 was creating.
      occurrences "slot 0 present fence" gone `shouldBe` 0
      occurrences "slot 0 command pool" gone `shouldBe` 0
      occurrences "slot 1 acquisition semaphore" gone `shouldBe` 0

  describe "A cancellation at the acquisition-to-registration handoff" $
    -- Requirement 5. A synchronous failure is not the only way a created
    -- handle is lost: an asynchronous exception delivered between the call
    -- that made it and the write that hands it to its owner orphans it just as
    -- completely, and no verdict computed afterwards can see that.
    it "leaves the handle owned rather than orphaned" $ do
      fake ← newFake
      cleanups ← newCleanups
      ledger ← newLedger
      journal ← newJournal
      registerParents fake [] cleanups
      places ← newSlotPlaces
      reached ← newEmptyMVar
      proceed ← newEmptyMVar
      done ← newEmptyMVar
      semaphores ← newIORef ["slot 0 acquisition semaphore", "slot 0 presentation semaphore"]
      let operations =
            SlotOps
              { createSlotSemaphore = do
                  role ←
                    atomicModifyIORef' semaphores $ \case
                      (next : rest) → (rest, next)
                      [] → ([], "unexpected")
                  -- The first acquisition announces, the instant its object
                  -- exists and before 'holding' has handed it over, that the
                  -- cancellation may be thrown; the second blocks before
                  -- creating anything. Blocking on an empty MVar is
                  -- interruptible even under a mask, so that is where the
                  -- throw lands — one step past the handoff under test, with
                  -- the first object owned and no second object to lose.
                  if role == "slot 0 acquisition semaphore"
                    then do
                      name ← acquire fake Nothing role
                      putMVar reached ()
                      pure name
                    else do
                      takeMVar proceed
                      acquire fake Nothing role
              , destroySlotSemaphore = release fake []
              , createSlotFence = acquire fake Nothing "slot 0 unreached fence"
              , destroySlotFence = release fake []
              , createSlotPool = acquire fake Nothing "slot 0 unreached pool"
              , destroySlotPool = release fake []
              , allocateSlotCommands = \pool → acquire fake Nothing (pool <> "'s command buffer")
              }
      for_ (reverse (slotPlaceReleases operations "slot 0" places)) $ \(what, action) →
        onExit cleanups what action
      worker ← forkIO (try @SomeException (fillSlot operations places) >>= putMVar done)
      takeMVar reached
      throwTo worker (Injected "the run was cancelled at the handoff")
      outcome ← takeMVar done
      facts ← runCleanups journal ledger cleanups
      let session = Session fake facts (either (Just . stopReason) (const Nothing) outcome)
      session.sessionStopped `shouldSatisfy` maybe False (Text.isInfixOf "cancelled")
      -- The object that existed when the cancellation arrived is released, and
      -- released before the device, which is the whole claim.
      everyChildOwnedAndFreedBeforeTheDevice session
      gone ← releasedBy fake
      occurrences "slot 0 acquisition semaphore" gone `shouldBe` 1
      facts.teardownFailures `shouldBe` []

  describe "A release that fails while a construction failure is being handled" $ do
    -- Requirement 3, and the review's spec addition: the primary failure is
    -- what stopped the run and must survive teardown, and a release that fails
    -- must be recorded beside it rather than replacing it or hiding the
    -- releases after it.
    let failingRelease = "slot 0 rendering fence"

    it "keeps the primary failure and records the release failure beside it" $ do
      session ← slotSession (Just 7) [failingRelease]
      session.sessionStopped `shouldSatisfy` maybe False (Text.isInfixOf "failed")
      session.sessionFacts.teardownFailures `shouldSatisfy` any (Text.isInfixOf failingRelease)
      length session.sessionFacts.teardownFailures `shouldBe` 1

    it "continues the independent releases and retries none of them" $ do
      session ← slotSession (Just 7) [failingRelease]
      gone ← releasedBy session.sessionFake
      built ← created session.sessionFake
      -- Its two siblings in the same cleanup entry still go, and so does
      -- everything registered beneath it.
      forM_ (ownedCreations built) $ \child → occurrences child gone `shouldBe` 1
      occurrences "the logical device" gone `shouldBe` 1
      occurrences failingRelease gone `shouldBe` 1

    it "renders both failures in the record a stopped run writes" $ do
      session ← slotSession (Just 7) [failingRelease]
      let rendered =
            renderRecord
              "title"
              "invocation"
              []
              (Stopped (Failure "the frame slots" (maybe "" id session.sessionStopped)) session.sessionFacts)
              False
      rendered `shouldSatisfy` Text.isInfixOf "Step: **the frame slots**"
      rendered `shouldSatisfy` Text.isInfixOf failingRelease
      rendered `shouldSatisfy` Text.isInfixOf "releases that failed"

  describe "The capture path" $ do
    -- Requirement 2. The buffer and its memory had no cleanup owner at all:
    -- the only freeMemory and destroyBuffer sat at the successful end of the
    -- path, so every step between the buffer's creation and that end left both
    -- live when the device was destroyed.
    let steps =
          [ (0, "creating the buffer")
          , (1, "allocating the memory")
          , (2, "binding the memory")
          , (3, "acquiring the image")
          , (4, "submitting the copy")
          , (5, "waiting for the copy to complete")
          , (6, "mapping the memory")
          , (7, "presenting")
          ] ∷
            [(Int, String)]

    forM_ steps $ \(failAt, what) →
      it ("owns both handles when it stops while " <> what) $ do
        session ← captureSession (Just failAt) [] Succeeded
        session.sessionStopped `shouldSatisfy` maybe False (Text.isInfixOf "failed")
        everyChildOwnedAndFreedBeforeTheDevice session
        -- Both go: the boundary held, and it is what establishes that the
        -- queue finished with the copy. A present that failed leaves its own
        -- obligation over the swapchain and the parents above it — the next
        -- example is that case — but neither of these is an object a
        -- presentation touches.
        map fst session.sessionFacts.teardownRetained
          `shouldSatisfy` notElem captureBufferName
        map fst session.sessionFacts.teardownRetained
          `shouldSatisfy` notElem captureMemoryName
        session.sessionFacts.teardownFailures `shouldBe` []

    it "frees the memory before the buffer, as the successful path does" $ do
      session ← captureSession (Just 4) [] Succeeded
      gone ← releasedBy session.sessionFake
      positionIn captureMemoryName gone `shouldSatisfy` (< positionIn captureBufferName gone)

    it "destroys neither handle when it never created it" $ do
      session ← captureSession (Just 0) [] Succeeded
      gone ← releasedBy session.sessionFake
      occurrences captureBufferName gone `shouldBe` 0
      occurrences captureMemoryName gone `shouldBe` 0

    it "reports both handles as destroyed rather than only as entries" $ do
      session ← captureSession (Just 5) [] Succeeded
      session.sessionFacts.teardownDestroyed `shouldContain` [captureMemoryName]
      session.sessionFacts.teardownDestroyed `shouldContain` [captureBufferName]
      session.sessionFacts.teardownReleases `shouldContain` [captureBufferName]

    it "retains both when the boundary established no completion for the copy" $ do
      -- Requirement 4. The copy was submitted to the queue, and the boundary
      -- is the only evidence that a queue has finished with it; a boundary
      -- that failed establishes none, so destroying either handle would be the
      -- device-idle fallback the backend design forbids.
      session ← captureSession (Just 6) [] OutOfHostMemory
      gone ← releasedBy session.sessionFake
      occurrences captureBufferName gone `shouldBe` 0
      occurrences captureMemoryName gone `shouldBe` 0
      map fst session.sessionFacts.teardownRetained
        `shouldContain` [captureMemoryName, captureBufferName]
      forM_ (lookup captureBufferName session.sessionFacts.teardownRetained) $ \reason →
        reason `shouldSatisfy` Text.isInfixOf "the teardown boundary failed"
      -- And the device above them, because a retained child holds its parent.
      map fst session.sessionFacts.teardownRetained `shouldContain` ["the logical device"]

    it "is not held by an unretired present, which touches neither handle" $ do
      -- The present the capture makes is work the presentation engine does on
      -- a swapchain image. Retaining the readback buffer behind it would put a
      -- reason in the record that the run never observed; what does hold it is
      -- the boundary, and the boundary held here.
      session ← captureSession (Just 7) [] Succeeded
      session.sessionFacts.teardownObservations
        `shouldSatisfy` any (Text.isInfixOf "vkQueuePresentKHR")
      map fst session.sessionFacts.teardownRetained
        `shouldSatisfy` notElem captureBufferName
      map fst session.sessionFacts.teardownRetained `shouldContain` ["the swapchain"]

  describe "A run that completes" $ do
    -- Requirement 6. None of the above may change the path the retained
    -- records were produced on.
    it "frees the capture's two handles itself, exactly once" $ do
      session ← captureSession Nothing [] Succeeded
      session.sessionStopped `shouldBe` Nothing
      gone ← releasedBy session.sessionFake
      occurrences captureBufferName gone `shouldBe` 1
      occurrences captureMemoryName gone `shouldBe` 1

    it "arrives at teardown holding neither of them" $ do
      session ← captureSession Nothing [] Succeeded
      -- The registrations were recalled, so they are not entries teardown
      -- released and not handles it destroyed. That is what keeps the record's
      -- release line the ten entries it has always been.
      session.sessionFacts.teardownReleases `shouldSatisfy` notElem captureBufferName
      session.sessionFacts.teardownReleases `shouldSatisfy` notElem captureMemoryName
      session.sessionFacts.teardownDestroyed `shouldSatisfy` notElem captureMemoryName
      session.sessionFacts.teardownRetained `shouldBe` []

    it "builds both whole slots and releases each child once" $ do
      session ← slotSession Nothing []
      session.sessionStopped `shouldBe` Nothing
      built ← created session.sessionFake
      length built `shouldBe` 12
      everyChildOwnedAndFreedBeforeTheDevice session
      session.sessionFacts.teardownRetained `shouldBe` []
      session.sessionFacts.teardownFailures `shouldBe` []

    it "releases the same ten entries, in the same order" $ do
      -- The control. A run that builds both slots and captures is the shape
      -- every retained record was produced on, and none of the ownership above
      -- may move an entry, add one, or drop one from it.
      session ← wholeSession
      session.sessionStopped `shouldBe` Nothing
      session.sessionFacts.teardownReleases `shouldBe` teardownEntries
      session.sessionFacts.teardownRetained `shouldBe` []
      session.sessionFacts.teardownFailures `shouldBe` []
      show session.sessionFacts.teardownReleases `shouldSatisfy` not . isInfixOf "capture"

    it "destroys every object it created, exactly once and before its device" $ do
      session ← wholeSession
      built ← created session.sessionFake
      -- Twelve slot children, the capture's buffer and its memory.
      length (ownedCreations built) `shouldBe` 12
      everyChildOwnedAndFreedBeforeTheDevice session
