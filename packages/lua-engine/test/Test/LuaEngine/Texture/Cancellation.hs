{-# LANGUAGE OverloadedStrings #-}

-- | Cancellation withdraws interest, and cleanup follows actual use: a request cancelled at each stage
-- (queued for a lane, queued in the pool, being read, being decoded, decoded, being handed over,
-- uploading, registered) leaves nothing reserved once what was started has retired, and never frees
-- active work because its result was taken. Completion and cancellation in both orders, an immediate
-- callback during submission, late and duplicate events, unconsumed success, and instance end.
module Test.LuaEngine.Texture.Cancellation (spec) where

import Control.Concurrent.MVar (readMVar, tryPutMVar)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM_, replicateM_, void)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Content.ReadPool (PoolStatus (..), ReadPriority (..), releaseSlot)
import Hetoimasia.Scripting.Lua.Lease (ScopeSummary (..))
import Test.Hspec
import Test.LuaEngine.Texture.Contract (layout, small, started)
import Test.LuaEngine.Texture.Png (opaque)
import Test.LuaEngine.Texture.Support

spec ∷ Spec
spec = describe "cancellation" $ do
  stages
  orders
  events
  ending

cancelled ∷ Session → Vm → Text → Text → IO ()
cancelled session vm name key = do
  command session vm name "cancel" key
  awaitNote session (name <> " cancel " <> key <> " cancelled")

-- | Take the cancelled request's result: exactly one record, and no texture.
takeCancelled ∷ Session → Vm → Text → Text → IO ()
takeCancelled session vm name key = do
  command session vm name "take" key
  awaitNote session (name <> " take " <> key <> " {status=cancelled}")

stages ∷ Spec
stages = describe "at each stage" $ do
  it "withdraws a request still waiting for a lane without any file work, and gives its reservation back with its result" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "queued" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "a.png"
      forM_ ["k0", "k1", "k2"] $ \key → started session vm "i" key "a.png"
      awaitPipeline session ((== 1) . readingPending)
      cancelled session vm "i" "k2"
      awaitPipeline session (\reading → readingPending reading == 0 && readingSettled reading == 1)
      readsStarted (ssProbe session) `shouldReturn` 2
      takeCancelled session vm "i" "k2"
      awaitOwner vm "i" (== OwnerReading 2 8192)

  it "withdraws a read still queued in the shared pool before any file is opened, and frees its lane at once" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "pooled" OnArrival
      admitDriver session vm "i"
      let probe = ssProbe session
      mapM_ (closeGate probe) ["c.png", "d.png"]
      first ← directRead session OrdinaryRead "c.png"
      second ← directRead session OrdinaryRead "d.png"
      awaitStarted probe 2
      started session vm "i" "k0" "a.png"
      awaitPool session ((== 1) . statusQueued)
      cancelled session vm "i" "k0"
      awaitPool session ((== 0) . statusQueued)
      awaitPipeline session (\reading → readingSettled reading == 1 && all ((== Nothing) . laneReadingJob) (readingLanes reading))
      takeCancelled session vm "i" "k0"
      awaitOwner vm "i" (== OwnerReading 0 0)
      mapM_ (openGate probe) ["c.png", "d.png"]
      mapM_ readMVar [first, second]
      readsStarted probe `shouldReturn` 2
      awaitPool session ((== 0) . statusLive)
      replicateM_ 2 (atomically (releaseSlot (ssPool session)))

  it "lets a read a worker has started run to its end: consuming the cancellation frees nothing, and the lane, the reservation and the next job follow its retirement" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "active" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "b.png"
      closeGate (ssProbe session) "a.png"
      started session vm "i" "k0" "b.png"
      started session vm "i" "k1" "a.png"
      started session vm "i" "k2" "a.png"
      awaitStarted (ssProbe session) 2
      cancelled session vm "i" "k0"
      takeCancelled session vm "i" "k0"
      -- The read is in a worker's hands: the result is consumed and nothing is free.
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 3 12288)
      pipelineNow session >>= \reading → (readingReading reading, readingPending reading) `shouldBe` (2, 1)
      openGate (ssProbe session) "b.png"
      -- Its retirement frees the lane without any event of the job's own, and the waiting job starts.
      awaitStarted (ssProbe session) 3
      awaitOwner vm "i" (== OwnerReading 2 8192)

  it "withdraws a request being decoded when the decode ends: no upload, the level released, the lane free" $ do
    gate ← newGate
    withSession ((config small layout) {cfgHooks = noHooks {hookDecoding = hold gate}, cfgRelease = releaseHeldGate gate}) $ \session _ runtime → do
      vm ← startVm session runtime "decoding" OnArrival
      admitDriver session vm "i"
      started session vm "i" "k0" "a.png"
      readMVar (arrived gate)
      awaitPipeline session ((== 1) . readingDecoding)
      cancelled session vm "i" "k0"
      void (tryPutMVar (proceed gate) ())
      awaitPipeline session (\reading → readingSettled reading == 1 && readingDecoding reading == 0)
      uploadsSeen (ssFake session) `shouldReturn` 0
      takeCancelled session vm "i" "k0"
      awaitOwner vm "i" (== OwnerReading 0 0)
      lanesCharged session `shouldReturn` [0, 0]

  it "withdraws a request whose level is decoded and charged but not yet handed over: the level is released and nothing is uploaded" $ do
    gate ← newGate
    withSession ((config small layout) {cfgHooks = noHooks {hookDecoded = hold gate}, cfgRelease = releaseHeldGate gate}) $ \session _ runtime → do
      vm ← startVm session runtime "decoded" OnArrival
      admitDriver session vm "i"
      started session vm "i" "k0" "a.png"
      readMVar (arrived gate)
      -- The encoded input and the level are both charged to the lane that holds them.
      lanesCharged session `shouldReturn` [fromIntegral (BS.length (opaque 8 4)) + 128, 0]
      cancelled session vm "i" "k0"
      void (tryPutMVar (proceed gate) ())
      awaitPipeline session (\reading → readingSettled reading == 1)
      uploadsSeen (ssFake session) `shouldReturn` 0
      lanesCharged session `shouldReturn` [0, 0]
      takeCancelled session vm "i" "k0"
      awaitOwner vm "i" (== OwnerReading 0 0)

  it "tells the backend about a cancellation that arrives inside the call that hands the level over, once the call has returned" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "submitting" OnArrival
      admitDriver session vm "i"
      setHoldSubmission (ssFake session) True
      started session vm "i" "k0" "a.png"
      awaitSubmitting (ssFake session) 1
      cancelled session vm "i" "k0"
      held ← uploadN (ssFake session) 0
      uploadCancelled held `shouldReturn` False
      setHoldSubmission (ssFake session) False
      awaitUploadCancelled held
      -- Interest is withdrawn: the backend still owes the end of the work, and the pipeline waits for it.
      pipelineNow session >>= \reading → readingUploading reading `shouldBe` 1
      _ ← withdrawUpload (ssFake session) held
      awaitPipeline session ((== 1) . readingSettled)
      takeCancelled session vm "i" "k0"
      awaitOwner vm "i" (== OwnerReading 0 0)
      releaseCalls (ssFake session) `shouldReturn` []

  it "tells the backend to withdraw an upload it holds, and gives everything back when it has" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "uploading" OnArrival
      admitDriver session vm "i"
      started session vm "i" "k0" "a.png"
      awaitUploads (ssFake session) 1
      held ← uploadN (ssFake session) 0
      cancelled session vm "i" "k0"
      awaitUploadCancelled held
      takeCancelled session vm "i" "k0"
      -- The request is consumed, and nothing is free until the backend ends the work.
      ownerNow vm "i" >>= \reading → ownerSlotsHeld reading `shouldBe` 1
      lanesCharged session >>= \charged → sum charged `shouldBe` 128
      _ ← withdrawUpload (ssFake session) held
      awaitOwner vm "i" (== OwnerReading 0 0)
      lanesCharged session `shouldReturn` [0, 0]
      releaseCalls (ssFake session) `shouldReturn` []

orders ∷ Spec
orders = describe "completion and cancellation in both orders" $ do
  it "cancels first: a texture the backend completes afterwards is released once, never reaches the request, and holds its charge until it is retired" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "late" OnArrival
      admitDriver session vm "i"
      started session vm "i" "k0" "a.png"
      awaitUploads (ssFake session) 1
      held ← uploadN (ssFake session) 0
      cancelled session vm "i" "k0"
      awaitUploadCancelled held
      -- The backend ignores the cancellation and finishes: the texture is the pipeline's to release.
      identity ← finishUpload (ssFake session) held
      awaitReleaseCalls (ssFake session) 1
      releaseCalls (ssFake session) `shouldReturn` [identity]
      takeCancelled session vm "i" "k0"
      -- The request is consumed and retired; the texture is not, and still charges its slot and bytes.
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 128)
      retireTexture (ssFake session) identity
      awaitOwner vm "i" (== OwnerReading 0 0)
      sessionNow session `shouldReturn` 0
      releaseCalls (ssFake session) `shouldReturn` [identity]
      leaseSummary session vm "i" >>= \summary → summaryLive summary `shouldBe` 0

  it "completes first: the success stands, cancel answers already_settled, and the texture is usable" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "first" OnArrival
      admitDriver session vm "i"
      started session vm "i" "k0" "a.png"
      awaitUploads (ssFake session) 1
      identity ← uploadN (ssFake session) 0 >>= finishUpload (ssFake session)
      command session vm "i" "wait" "k0"
      awaitNote session "i wait k0 0"
      command session vm "i" "cancel" "k0"
      awaitNote session "i cancel k0 already_settled"
      command session vm "i" "take" "k0"
      awaitNote session "i take k0 {status=success,value={height=4,texture=<userdata>,width=8}}"
      command session vm "i" "use" "k0"
      awaitNote session ("i use k0 " <> Text.pack (show identity))
      releaseCalls (ssFake session) `shouldReturn` []

  it "settles on an immediate callback inside the submission, before the call has returned" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "immediate" OnArrival
      admitDriver session vm "i"
      setImmediate (ssFake session) (Just ImmediateReady)
      started session vm "i" "k0" "a.png"
      command session vm "i" "wait_take" "k0"
      line ← lineStarting session "i wait_take k0 "
      line `shouldBe` "i wait_take k0 {status=success,value={height=4,texture=<userdata>,width=8}}"
      lanesCharged session `shouldReturn` [0, 0]

  it "survives the backend finishing, the result being taken and the request's record being returned before the submission call has returned" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "issuing" OnArrival
      admitDriver session vm "i"
      setImmediate (ssFake session) (Just ImmediateReady)
      setHoldSubmission (ssFake session) True
      started session vm "i" "k0" "a.png"
      awaitSubmitting (ssFake session) 1
      -- Both events were delivered inside the call that has not returned: the job settled, the result
      -- was adopted and taken, and the host returned the record, so the job is gone.
      command session vm "i" "wait_take" "k0"
      _ ← lineStarting session "i wait_take k0 "
      awaitPipeline session ((== 0) . readingJobs)
      setHoldSubmission (ssFake session) False
      -- The pipeline is whole: the decode worker lives and a later request goes through.
      setImmediate (ssFake session) Nothing
      started session vm "i" "k1" "b.png"
      awaitUploads (ssFake session) 2
      uploadN (ssFake session) 1 >>= void . finishUpload (ssFake session)
      command session vm "i" "wait_take" "k1"
      _ ← lineStarting session "i wait_take k1 "
      reading ← pipelineNow session
      (readingFailed reading, readingDecodeWorkers reading) `shouldBe` (False, 1)

  it "cancels at the registration boundary: a request cancelled after the backend registered the texture and before the host built the lease releases it once, by the pipeline" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "boundary" OnArrival
      admitDriver session vm "i"
      started session vm "i" "k0" "a.png"
      awaitUploads (ssFake session) 1
      -- The script is inside a callback when the texture is registered, so the host has not yet built the
      -- lease; its cancel then wins, the build is never run, and nothing in the engine knows the texture.
      commandWith session vm "i" "block_cancel" "k0" Nothing
      awaitGate session "k0"
      identity ← uploadN (ssFake session) 0 >>= finishUpload (ssFake session)
      releaseGate session "k0"
      awaitNote session "i block_cancel k0 cancelled"
      takeCancelled session vm "i" "k0"
      -- The host returned the credit it never transferred: the pipeline releases the texture and keeps
      -- the charge until the backend proves it retired.
      awaitReleaseCalls (ssFake session) 1
      releaseCalls (ssFake session) `shouldReturn` [identity]
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 128)
      retireTexture (ssFake session) identity
      awaitOwner vm "i" (== OwnerReading 0 0)
      leaseSummary session vm "i" >>= \summary → summaryLive summary `shouldBe` 0

events ∷ Spec
events = describe "late and duplicate events" $
  it "counts a second registration, a second retirement and a stale one after the request is gone, and keeps none of what they carry" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "events" OnArrival
      admitDriver session vm "i"
      started session vm "i" "k0" "a.png"
      awaitUploads (ssFake session) 1
      held ← uploadN (ssFake session) 0
      identity ← finishUpload (ssFake session) held
      command session vm "i" "wait_take" "k0"
      _ ← lineStarting session "i wait_take k0 "
      readingBefore ← pipelineNow session
      (second, answer) ← registerTexture (ssFake session) held
      answer `shouldBe` SinkLate
      retireBuffers (ssFake session) held >>= (`shouldBe` SinkLate)
      failUpload (ssFake session) held "a device loss after the fact" >>= (`shouldBe` SinkLate)
      sinkWithdrawn (heldSink held) >>= (`shouldBe` SinkLate)
      readingAfter ← pipelineNow session
      -- One for the registration, one for the buffers, two for a failure (the fake retires the buffers
      -- first, as a backend must) and one for a withdrawal.
      readingLate readingAfter `shouldBe` readingLate readingBefore + 5
      -- The texture the second registration carried was never taken: the pipeline asks for no release,
      -- and the first texture is the only one the engine owns.
      releaseCalls (ssFake session) `shouldReturn` []
      texturesLive (ssFake session) >>= (`shouldBe` [identity, second])
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 128)

ending ∷ Spec
ending = describe "instance end" $ do
  it "releases an unconsumed success automatically when the instance ends, once, and keeps its charge until the backend retires it" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "unconsumed" OnArrival
      admitDriver session vm "i"
      started session vm "i" "k0" "a.png"
      awaitUploads (ssFake session) 1
      identity ← uploadN (ssFake session) 0 >>= finishUpload (ssFake session)
      awaitPipeline session ((== 1) . readingSettled)
      awaitLeaseSummary session vm "i" ((== 1) . summaryLive)
      stopInstance session vm "i"
      awaitReleaseCalls (ssFake session) 1
      releaseCalls (ssFake session) `shouldReturn` [identity]
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 128)
      retireTexture (ssFake session) identity
      awaitOwner vm "i" (== OwnerReading 0 0)
      sessionNow session `shouldReturn` 0
      releaseCalls (ssFake session) `shouldReturn` [identity]

  it "withdraws an upload in flight when the instance ends, and leaves another instance's request and texture alone" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "ending" OnArrival
      mapM_ (admitDriver session vm) ["i", "j"]
      started session vm "i" "k0" "a.png"
      started session vm "j" "k0" "b.png"
      awaitUploads (ssFake session) 2
      -- Uploads arrive in the order the workers finish: each is found by its own path.
      first ← uploadFor (ssFake session) "a.png"
      second ← uploadFor (ssFake session) "b.png"
      stopInstance session vm "i"
      awaitUploadCancelled first
      uploadCancelled second `shouldReturn` False
      _ ← withdrawUpload (ssFake session) first
      awaitOwner vm "i" (== OwnerReading 0 0)
      -- The peer's request goes on and succeeds.
      identity ← finishUpload (ssFake session) second
      command session vm "j" "wait_take" "k0"
      line ← lineStarting session "j wait_take k0 "
      line `shouldBe` "j wait_take k0 {status=success,value={height=4,texture=<userdata>,width=8}}"
      command session vm "j" "use" "k0"
      awaitNote session ("j use k0 " <> Text.pack (show identity))
      ownerNow vm "j" >>= (`shouldBe` OwnerReading 1 128)

  it "releases a texture whose instance's shutdown hook raises: the engine's cleanup does not depend on the script" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "shutdown" OnArrival
      admitModule session vm "failing" "f"
      awaitNote session "failing started"
      awaitUploads (ssFake session) 1
      identity ← uploadN (ssFake session) 0 >>= finishUpload (ssFake session)
      awaitLeaseSummary session vm "f" ((== 1) . summaryLive)
      stopInstance session vm "f"
      awaitReleaseCalls (ssFake session) 1
      releaseCalls (ssFake session) `shouldReturn` [identity]
      ownerNow vm "f" >>= (`shouldBe` OwnerReading 1 128)
      retireTexture (ssFake session) identity
      awaitOwner vm "f" (== OwnerReading 0 0)
      sessionNow session `shouldReturn` 0
