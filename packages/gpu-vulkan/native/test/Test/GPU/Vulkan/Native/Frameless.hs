-- | Frame-less batches (GRS-12) over the frames' and the recording's stand-in
-- native layers: an action's scope submitting its sealed batches in seal
-- order, each by itself and before a later frame; a partial batch never
-- submitted; an action that raised submitting nothing; an accepted prefix
-- kept when a later submission fails; slot storage reused only after a
-- completion or a discard; tickets completed only on fence evidence and lost
-- on device loss; waits with a deadline; initialization; and retirement.
--
-- Nothing here creates a Vulkan object, and nothing waits on a clock.
module Test.GPU.Vulkan.Native.Frameless (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (ErrorCall (ErrorCall), SomeException, throwIO, try)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import Data.Word (Word64)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), durationFromNanoseconds)
import Hetoimasia.GPU.Model
  ( Initialization (..)
  , SessionFailureCause (..)
  , SessionState (..)
  , framelessSlots
  , resourceInitialization
  , sessionState
  )
import Hetoimasia.GPU.Model.Budget (BudgetKind (..), BudgetRequest (..), defaultBudgetRequest)
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Recording
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn
import Test.GPU.Vulkan.Native.RecordingStandIn (RecordingCall (..), RecordingStep (AtResetStorage), failAt, recordingCalls)

type Scope = FramelessScope () Int Int Text Int Word64

spec ∷ Spec
spec = describe "Frame-less batches" $ do
  describe "submission" $ do
    it "submits an action's sealed batches each by itself, with no wait and no signal, in seal order, before a later frame's" $ do
      rig ← newRig
      -- The inner batch is opened second and sealed first.
      scoped rig $ \scope → ok (fmap (const ()) <$> recordFramelessIn scope (\_ → sealedIn scope))
      [slotZero, slotOne] ← framelessCommands rig
      frame ← owned rig
      batch ← sealed rig frame
      _ ← submitted rig (batch :| [])
      submissions ← filter isSubmission <$> frameCalls (rigStandIn rig)
      case submissions of
        [Submitted [first] _, Submitted [second] _, Submitted [(waits, _, _, _)] _] → do
          first `shouldBe` ([], WaitAtAllCommands, [slotOne], [])
          second `shouldBe` ([], WaitAtAllCommands, [slotZero], [])
          length waits `shouldBe` 1
        other → expectationFailure ("the submissions were " <> show other)
      clean rig

    it "refuses a command that needs a swapchain image in a frame-less batch, before any native call" $ do
      rig ← newRig
      answers ← scoped rig $ \scope →
        recordFramelessIn scope (\recorder → sequence [transitionImage recorder LayoutUndefined LayoutColorAttachment, beginRendering recorder (ClearColor 0 0 0 1)])
          >>= either (fail . show) (pure . snd)
      answers `shouldBe` replicate 2 (Left (RefusedUnsupported "a command that needs a swapchain image, in a frame-less batch"))
      recordingCalls (rigRecordingStandIn rig) >>= \calls → [() | Recorded _ (CommandImageBarrier {}) ← calls] `shouldBe` []
      clean rig

    it "never submits a batch left partial, and discards it, resetting its storage" $ do
      rig ← newRig
      scoped rig $ \scope → do
        outcome ← try @ErrorCall (recordFramelessIn scope (\_ → throwIO (ErrorCall "the consumer failed")))
        fmap (const ()) outcome `shouldBe` Left (ErrorCall "the consumer failed")
        (framelessSlots <$> modelOf rig) `shouldReturn'` (`shouldSatisfy` ((== 1) . length))
      filter isSubmission <$> frameCalls (rigStandIn rig) `shouldReturn` []
      framelessSlots <$> modelOf rig `shouldReturn` []
      atomically (readBatches (rigRecording rig)) `shouldReturn` []
      resets rig `shouldReturn` 1
      clean rig

    it "submits nothing when the action raises after sealing, discards everything it opened, and raises the action's failure" $ do
      rig ← newRig
      tickets ← newIORef []
      outcome ← try @ErrorCall $ scoped rig $ \scope → do
        ticket ← sealedIn scope
        modifyIORef' tickets (ticket :)
        throwIO (ErrorCall "the action failed")
      fmap (const ()) outcome `shouldBe` Left (ErrorCall "the action failed")
      filter isSubmission <$> frameCalls (rigStandIn rig) `shouldReturn` []
      readIORef tickets >>= mapM (atomically . readTicket) >>= (`shouldBe` [TicketDiscarded])
      framelessSlots <$> modelOf rig `shouldReturn` []
      clean rig

    it "keeps an accepted prefix when a later submission fails with no effect, and discards it and every later one" $ do
      rig ← newRig
      failSubmission rig 2 AtSubmitNoEffect
      tickets ← scoped rig (\scope → mapM (const (sealedIn scope)) [1 ∷ Int .. 3])
      mapM (atomically . readTicket) tickets `shouldReturn` [TicketPending, TicketDiscarded, TicketDiscarded]
      atomically (readFramelessSubmissions (rigFrames rig)) >>= (`shouldSatisfy` ((== 1) . length))
      clearFrameStep (rigStandIn rig) AtSubmitNoEffect
      completeAll (rigStandIn rig)
      _ ← progress rig
      mapM (atomically . readTicket) (take 1 tickets) `shouldReturn` [TicketComplete]
      clean rig

    it "raises a submission whose effect is unknown, keeping the accepted prefix, failing the session and discarding the rest" $ do
      rig ← newRig
      failSubmission rig 2 AtSubmit
      tickets ← newIORef []
      outcome ← try @FramelessEffectUncertain $ scoped rig $ \scope →
        mapM_ (const (sealedIn scope >>= \ticket → modifyIORef' tickets (ticket :))) [1 ∷ Int .. 3]
      fmap (const ()) outcome `shouldSatisfy` either (const True) (const False)
      states ← readIORef tickets >>= mapM (atomically . readTicket) . reverse
      -- The first was accepted, the second's effect is unknown: neither is
      -- complete, and neither is discarded.
      states `shouldBe` [TicketPending, TicketPending, TicketDiscarded]
      sessionState <$> modelOf rig `shouldReturn` SessionFailed UnknownSubmissionEffect

  describe "slots" $ do
    it "reuses a slot's storage only after its submission completed, or its batch was discarded" $ do
      rig ← newRigOver 1 defaultBudgetRequest {requestedFramelessBatches = 1}
      first ← scoped rig sealedIn
      refused ← scoped rig (\scope → recordFramelessIn scope (\_ → pure ()))
      fmap (const ()) refused `shouldBe` Left (RefusedBackpressure FramelessBatchBudget)
      resets rig `shouldReturn` 0
      completeAll (rigStandIn rig)
      _ ← progress rig
      atomically (readTicket first) `shouldReturn` TicketComplete
      second ← scoped rig sealedIn
      -- The completed batch's commands were invalidated before the reuse.
      resets rig `shouldReturn` 1
      completeAll (rigStandIn rig)
      _ ← progress rig
      -- A discard frees the slot as well.
      _ ← try @ErrorCall (scoped rig (\scope → sealedIn scope >> throwIO (ErrorCall "raised")))
      third ← scoped rig sealedIn
      length <$> framelessCommands rig `shouldReturn` 1
      -- Earlier tickets keep their outcomes across the slot's reuse.
      mapM (atomically . readTicket) [first, second, third] `shouldReturn` [TicketComplete, TicketComplete, TicketPending]
      clean rig

    it "keeps a batch whose discard's reset raised, with every hold, never reusing its slot, and raises the action's own failure" $ do
      rig ← newRigOver 1 defaultBudgetRequest {requestedFramelessBatches = 1}
      failAt (rigRecordingStandIn rig) AtResetStorage
      outcome ← try @ErrorCall (scoped rig (\scope → sealedIn scope >> throwIO (ErrorCall "the action failed")))
      fmap (const ()) outcome `shouldBe` Left (ErrorCall "the action failed")
      (framelessSlots <$> modelOf rig) `shouldReturn'` (`shouldSatisfy` ((== 1) . length))
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed

  describe "tickets" $ do
    it "keeps a ticket pending until its fence is observed signalled, completing it only then" $ do
      rig ← newRig
      ticket ← scoped rig sealedIn
      atomically (readTicket ticket) `shouldReturn` TicketPending
      report ← progress rig
      progressCompleted report `shouldBe` []
      atomically (readTicket ticket) `shouldReturn` TicketPending
      completeAll (rigStandIn rig)
      completed ← progressCompleted <$> progress rig
      length completed `shouldBe` 1
      atomically (readTicket ticket) `shouldReturn` TicketComplete
      framelessSlots <$> modelOf rig `shouldReturn` []
      clean rig

    it "waits with a deadline off the owner's thread, a timeout changing nothing, and refuses a wait on the owner's thread" $ do
      rig ← newRig
      ticket ← scoped rig sealedIn
      awaitTicket ticket (milliseconds 1) `shouldReturn` Left RefusedOwnerWait
      waited ← newEmptyMVar
      _ ← forkIO (awaitTicket ticket (milliseconds 1) >>= putMVar waited)
      takeMVar waited `shouldReturn` Right TicketPending
      atomically (readTicket ticket) `shouldReturn` TicketPending
      completeAll (rigStandIn rig)
      _ ← progress rig
      later ← newEmptyMVar
      _ ← forkIO (awaitTicket ticket (milliseconds 60000) >>= putMVar later)
      takeMVar later `shouldReturn` Right TicketComplete
      clean rig

    it "reports a pending ticket lost on device loss, and leaves a complete one complete" $ do
      rig ← newRig
      tickets ← scoped rig (\scope → mapM (const (sealedIn scope)) [1 ∷ Int, 2])
      fences ← map (framelessFence . viewFramelessSync) <$> atomically (readFramelessSlots (rigFrames rig))
      case fences of
        first : _ → completeFence (rigStandIn rig) first
        [] → expectationFailure "no frame-less fence was made"
      settled ← progress rig
      length (progressCompleted settled) `shouldBe` 1
      loseFrameStep (rigStandIn rig) AtQueryFence
      _ ← try @SomeException (progress rig)
      retireFrameless (rigFrames rig)
      mapM (atomically . readTicket) tickets `shouldReturn` [TicketComplete, TicketLost]
      atomically (readFramelessSlots (rigFrames rig)) `shouldReturn` []

    it "observes a ready frame-less submission in a one-action step even behind one that has not signalled" $ do
      rig ← newRigWithActions 2 1
      tickets ← scoped rig (\scope → mapM (const (sealedIn scope)) [1 ∷ Int, 2])
      fences ← map (framelessFence . viewFramelessSync) <$> atomically (readFramelessSlots (rigFrames rig))
      case fences of
        [_, second] → completeFence (rigStandIn rig) second
        other → expectationFailure ("the fences were " <> show other)
      _ ← progress rig
      _ ← progress rig
      mapM (atomically . readTicket) tickets `shouldReturn` [TicketPending, TicketComplete]
      clean rig

  describe "initialization" $ do
    it "publishes an image's initialization by a frame-less batch on its submission, not its sealing, and lets a later batch use it before completion" $ do
      rig ← newRig
      image ← createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Srgb 16 16 1) >>= either (fail . show) pure
      let resource = managedResource image
      during ← scoped rig $ \scope → do
        ok (fmap (const ()) <$> recordFramelessIn scope (\recorder → ok (transitionResource recorder image FromUndefined ColorAttachment)))
        resourceInitialization resource <$> modelOf rig
      during `shouldSatisfy` \case
        Just (InitializingIn _) → True
        _ → False
      resourceInitialization resource <$> modelOf rig `shouldReturn` Just Initialized
      later ← scoped rig $ \scope → recordFramelessIn scope (\recorder → transitionResource recorder image (FromUse ColorAttachment) ColorAttachment)
      fmap snd later `shouldBe` Right (Right ())
      clean rig

  describe "retirement" $ do
    it "retains the frame-less fences while a submission is outstanding, and destroys them once it completed" $ do
      rig ← newRig
      _ ← scoped rig sealedIn
      try @FramelessRetained (retireFrameless (rigFrames rig)) >>= (`shouldSatisfy` either (const True) (const False))
      completeAll (rigStandIn rig)
      _ ← progress rig
      retireFrameless (rigFrames rig)
      atomically (readFramelessSlots (rigFrames rig)) `shouldReturn` []
      clean rig

-- | Run a scope over the rig's frames.
scoped ∷ Rig → (Scope → IO a) → IO a
scoped rig = withFramelessScope (rigFrames rig)

-- | Record an empty frame-less batch, sealed, answering its ticket.
sealedIn ∷ Scope → IO BatchTicket
sealedIn scope = recordFramelessIn scope (\_ → pure ()) >>= either (fail . ("the frame-less batch was refused: " <>) . show) (pure . fst)

-- | The command buffer of each frame-less slot's storage, in slot order: the
-- stand-in allocates it right after the pool.
framelessCommands ∷ Rig → IO [Word64]
framelessCommands rig = (\views → [handle + 1 | ManagedView _ _ "frame-less storage" [handle] ← views]) <$> atomically (readManaged (rigRecording rig))

-- | Fail the nth submission, and every later one, at this step.
failSubmission ∷ Rig → Int → FrameStep → IO ()
failSubmission rig nth step' = do
  seen ← newIORef (0 ∷ Int)
  duringFrameCall (rigStandIn rig) $ \case
    Submitted {} → do
      modifyIORef' seen (+ 1)
      count ← readIORef seen
      if count == nth then failFrameStep (rigStandIn rig) step' else pure ()
    _ → pure ()

-- | How many storage resets the recording made.
resets ∷ Rig → IO Int
resets rig = length . filter (\case ResetStorage _ → True; _ → False) <$> recordingCalls (rigRecordingStandIn rig)

milliseconds ∷ Integer → Duration
milliseconds n = either (error . show) id (durationFromNanoseconds AllowZero (n * 1000000))
