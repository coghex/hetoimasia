-- | Uploads (GRS-6) over the frames', the recording's and the allocator's
-- stand-in native layers: admission copying the caller's bytes into staging
-- at once, and every refusal it makes before anything is reserved; chunks at
-- mip-level and block-row boundaries under the turn's budget, and byte ranges
-- of a buffer; the target held from every other batch, and from disposal,
-- until its upload settles; staging reclaimed only when an upload settles;
-- cancellation before and after the first copies; tickets completed only on
-- fence evidence, lost on device loss, and waited for with a deadline; the
-- owner's exit; a release while an upload holds its target; uploaded indices
-- bounding indexed draws; and a texture's levels copied back.
--
-- The stand-in device's widest image level is set to 16 texels, so a turn's
-- budget of 64 bytes holds the one block row validation requires and chunks
-- stay small. Nothing here creates a Vulkan object, and nothing waits on a
-- clock but the one example that waits on a ticket's deadline.
module Test.GPU.Vulkan.Native.Uploads (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar, tryTakeMVar)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, throwSTM, writeTVar)
import Control.Concurrent (killThread, myThreadId)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), SomeException, fromException, try)
import Hetoimasia.Foundation.Admission (Admission, admissionToken, closeAdmission, newAdmission, newAdmissionIO, tokenOpen)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.OwnerTx (commit)
import Hetoimasia.GPU.Model (SessionFailureCause (CleanupFailed))
import Hetoimasia.GPU.Vulkan.Native.Roots (failRootsSession)
import Control.Monad (forM, forM_, replicateM_, void, when)
import qualified Data.ByteString as ByteString
import Data.Either (isRight)
import Data.Functor ((<&>))
import Data.Text (Text)
import Data.Word (Word32, Word64, Word8)
import Numeric.Natural (Natural)
import Test.GPU.Vulkan.Native.Threads (onOtherThread, raceOwned)
import Test.Support.Owned (withOwnedThread, withOwnedThreadOpening)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn)

import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), durationFromNanoseconds)
import Hetoimasia.GPU.Model (Initialization (..), Outcome (Admitted), noteDeviceLoss, resourceInitialization)
import Hetoimasia.GPU.Model.Identity (IdentityKind (..), Misuse (..), ResourceId)
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Profile (DeviceOffer (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Uploads
import Test.GPU.Vulkan.Native.AllocatorStandIn (AllocatorCall (..), allocatorCalls, allowTypes, deviceLocalType, nonCoherentType)
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn (FrameCall (Submitted), FrameStep (AtSubmitNoEffect), clearFrameStep, completeAll, duringFrameCall, failFrameStep)
import Test.GPU.Vulkan.Native.RecordingStandIn
  ( RecordingCall (..)
  , RecordingFailure (..)
  , RecordingStep (AtUploadQueued, AtWriteMapped)
  , duringRecord
  , failAt
  , limitRecording
  , onceAt
  , recordingCalls
  , standInRecordingLimits
  , succeedAt
  )
import Test.GPU.Vulkan.Native.StandIn (StandIn (standAllocator, standOffers), standInDevice)

type Ups = Uploads () Int Int Text Int Word64

type Rec = Recorder () Int Int Text Int Word64

spec ∷ Spec
spec = describe "Uploads" $ do
  describe "configuration" $ do
    it "refuses zero, negative and unrepresentable sizes, budgets and capacities, never clamping them" $ do
      validateUploadConfig 0 64 4 `shouldBe` Left (StagingNotPositive 0)
      validateUploadConfig (2 ^ (64 ∷ Int)) 64 4 `shouldBe` Left (StagingUnrepresentable (2 ^ (64 ∷ Int)))
      validateUploadConfig 1024 (-1) 4 `shouldBe` Left (BudgetNotPositive (-1))
      validateUploadConfig 1024 (2 ^ (64 ∷ Int)) 4 `shouldBe` Left (BudgetUnrepresentable (2 ^ (64 ∷ Int)))
      validateUploadConfig 1024 64 0 `shouldBe` Left (QueueNotPositive 0)
      validateUploadConfig 1024 64 (toInteger (maxBound ∷ Int) + 1) `shouldBe` Left (QueueUnrepresentable (toInteger (maxBound ∷ Int) + 1))
      (uploadStagingBytes <$> validateUploadConfig 1024 64 4) `shouldBe` Right 1024

    it "refuses a budget that cannot hold one block row of the widest level, and a staging buffer the device cannot make, making nothing" $ do
      rig ← newUploadRig
      newUploads (rigFrames rig) (config 1024 63 4) >>= \case
        Left refusal → refusal `shouldBe` RefusedOutOfBounds 64 63
        Right _ → expectationFailure "a budget below one block row was accepted"
      newUploads (rigFrames rig) (config (2 * 1024 * 1024 * 1024) 64 4) >>= \case
        Left refusal → refusal `shouldBe` RefusedOutOfBounds (2 * 1024 * 1024 * 1024) (1024 * 1024 * 1024)
        Right _ → expectationFailure "a staging buffer past the device's largest was made"
      stagingCount rig `shouldReturn` 0

    it "makes the staging buffer as a staging-kind buffer of the configured size, reports BC7 support, and is the owner's alone" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      stagingCount rig `shouldReturn` 1
      uploadsStagingSize <$> atomically (readUploads uploads) `shouldReturn` 1024
      uploadsSupportBC7 uploads `shouldBe` True
      onOtherThread (fmap (const ()) <$> progressUploads uploads) `shouldReturn` Left RefusedNotOwner

  describe "admission" $ do
    it "copies the caller's bytes into staging before it returns, and queues the upload" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      texture ← textureOf rig Rgba8Linear 8 8 2
      ticket ← admitted uploads (UploadImage texture [level 256 1, level 64 2])
      atomically (readUploadTicket ticket) `shouldReturn` UploadQueued
      calls ← recordingCalls (rigRecordingStandIn rig)
      [(offset, count) | WroteMapped offset count ← calls] `shouldBe` [(0, 256), (256, 64)]
      fmap uploadPhase . uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` [PhaseQueued]
      clean rig

    it "evaluates a request in full before it takes anything: a level list whose tail raises leaves the queued upload, the reservations and staging as they were" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      texture ← textureOf rig Rgba8Linear 8 8 2
      first ← admitted uploads (UploadImage texture [level 256 1, level 64 2])
      before ← atomically (readUploads uploads)
      calls ← length <$> recordingCalls (rigRecordingStandIn rig)
      try @ErrorCall (submitUpload uploads (UploadImage texture (level 256 1 : error "the level list's tail raised"))) >>= \case
        Left (ErrorCall why) → why `shouldBe` "the level list's tail raised"
        Right _ → expectationFailure "the request was not evaluated before admission"
      fmap uploadPhase . uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` fmap uploadPhase (uploadsUnsettled before)
      uploadsReserved <$> atomically (readUploads uploads) `shouldReturn` uploadsReserved before
      length <$> recordingCalls (rigRecordingStandIn rig) `shouldReturn` calls
      atomically (readUploadTicket first) `shouldReturn` UploadQueued
      clean rig

    it "refuses, reserving and copying nothing: malformed levels and sizes, wrong kinds, a foreign or released target, and a closed queue" $ do
      rig ← newUploadRig
      other ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      texture ← textureOf rig Rgba8Linear 8 8 2
      vertices ← bufferOf rig VertexBuffer 100
      instances ← bufferOf rig InstanceBuffer 100
      target ← created (createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Linear 8 8 1))
      foreign' ← textureOf other Rgba8Linear 8 8 1
      released ← textureOf rig Rgba8Linear 8 8 1
      ok (releaseManaged (rigRecording rig) released)
      answers ←
        mapM
          (fmap (fmap (const ())) . submitUpload uploads)
          [ UploadImage texture [level 256 1]
          , UploadImage texture [level 256 1, level 60 2]
          , UploadBuffer vertices (level 99 1)
          , UploadImage target [level 256 1]
          , UploadBuffer instances (level 100 1)
          , UploadImage foreign' [level 256 1]
          , UploadImage released [level 256 1]
          ]
      answers
        `shouldBe` [ Left (UploadMalformed "the texture has 2 mip levels, and 1 were given")
                   , Left (UploadMalformed "mip level 1 needs 64 bytes, and 60 were given")
                   , Left (UploadMalformed "the buffer holds 100 bytes, and 99 were given")
                   , Left UploadWrongKind
                   , Left UploadWrongKind
                   , Left (UploadMisuse (ForeignIdentity ResourceIdentity))
                   , Left (UploadMisuse (WrongPhase ResourceIdentity))
                   ]
      atomically (closeUploads uploads)
      fmap (const ()) <$> submitUpload uploads (UploadBuffer vertices (level 100 1)) `shouldReturn` Left UploadClosed
      uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []
      writes rig `shouldReturn` []
      clean rig

    it "refuses an upload larger than the whole staging buffer permanently, and a full queue and a full staging buffer as distinct backpressure" $ do
      rig ← newUploadRig
      small ← made rig (config 128 64 4)
      texture ← textureOf rig Rgba8Linear 8 8 2
      fmap (const ()) <$> submitUpload small (UploadImage texture [level 256 1, level 64 2]) `shouldReturn` Left (UploadOversized 320 128)
      -- A queue of one, with room in staging: the second waits for the queue.
      queued ← made rig (config 1024 64 1)
      first ← bufferOf rig VertexBuffer 16
      second ← bufferOf rig VertexBuffer 16
      _ ← admitted queued (UploadBuffer first (level 16 1))
      fmap (const ()) <$> submitUpload queued (UploadBuffer second (level 16 1)) `shouldReturn` Left (UploadBackpressure QueueFull)
      -- Room in the queue, none in staging: the second waits for staging.
      tight ← made rig (config 320 64 4)
      third ← textureOf rig Rgba8Linear 8 8 2
      fourth ← bufferOf rig VertexBuffer 16
      _ ← admitted tight (UploadImage third [level 256 1, level 64 2])
      fmap (const ()) <$> submitUpload tight (UploadBuffer fourth (level 16 1)) `shouldReturn` Left (UploadBackpressure StagingFull)
      clean rig

    it "refuses a target another upload holds, and one already initialized or still held by a batch, as not fresh" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      texture ← textureOf rig Rgba8Linear 4 4 1
      vertices ← bufferOf rig VertexBuffer 16
      _ ← admitted uploads (UploadImage texture [level 64 1])
      fmap (const ()) <$> submitUpload uploads (UploadImage texture [level 64 1]) `shouldReturn` Left UploadAlreadyTargeted
      -- A vertex buffer a recorded batch still holds.
      held ← bufferOf rig VertexBuffer 64
      _ ← framelessOnce rig $ \recorder → ok (transitionResource recorder held (FromUse GeometryRead) GeometryRead)
      fmap (const ()) <$> submitUpload uploads (UploadBuffer held (level 64 1)) `shouldReturn` Left UploadNotFresh
      _ ← admitted uploads (UploadBuffer vertices (level 16 1))
      settleUploads rig uploads
      -- Each is initialized now, and fresh no more.
      fmap (const ()) <$> submitUpload uploads (UploadImage texture [level 64 1]) `shouldReturn` Left UploadNotFresh
      fmap (const ()) <$> submitUpload uploads (UploadBuffer vertices (level 16 1)) `shouldReturn` Left UploadNotFresh
      clean rig

    it "gives back every reservation when copying the caller's bytes raised, and raises it" $ do
      rig ← newUploadRig
      uploads ← made rig (config 320 64 4)
      texture ← textureOf rig Rgba8Linear 8 8 2
      failAt (rigRecordingStandIn rig) AtWriteMapped
      outcome ← try @RecordingFailure (submitUpload uploads (UploadImage texture [level 256 1, level 64 2]))
      fmap (const ()) outcome `shouldBe` Left (RecordingFailure AtWriteMapped)
      uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []
      succeedAt (rigRecordingStandIn rig) AtWriteMapped
      -- The target, the place in the queue and the whole staging buffer are
      -- all free again.
      _ ← admitted uploads (UploadImage texture [level 256 1, level 64 2])
      clean rig

    it "admits exactly one of two uploads racing for one target" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      texture ← textureOf rig Rgba8Linear 4 4 1
      outcomes ← raceOwned (replicate 2 (fmap (const ()) <$> submitUpload uploads (UploadImage texture [level 64 1])))
      length (filter isRight outcomes) `shouldBe` 1
      [refusal | Left refusal ← outcomes] `shouldBe` [UploadAlreadyTargeted]
      length . uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` 1

    it "refuses an upload under a gate closed before it, or closing while its bytes are copied, giving back every reservation" $ do
      rig ← newUploadRig
      uploads ← made rig (config 64 64 4)
      texture ← textureOf rig Rgba8Linear 4 4 1
      current ← admissionNow False
      let gate = gateOver current
      fmap (const ()) <$> submitUploadGated gate uploads (UploadImage texture [level 64 1]) `shouldReturn` Left UploadClosed
      writes rig `shouldReturn` []
      atomically (newAdmission >>= writeTVar current)
      onceAt (rigRecordingStandIn rig) AtWriteMapped (atomically (readTVar current >>= closeAdmission))
      fmap (const ()) <$> submitUploadGated gate uploads (UploadImage texture [level 64 1]) `shouldReturn` Left UploadClosed
      uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []
      -- The target, the place in the queue and the whole staging buffer are
      -- all free again.
      atomically (newAdmission >>= writeTVar current)
      _ ← admitted uploads (UploadImage texture [level 64 1])
      clean rig

    it "refuses a buffer an upload filled as not fresh, through any uploads over the same recording" $ do
      rig ← newUploadRig
      first ← made rig (config 1024 64 4)
      second ← made rig (config 1024 64 4)
      vertices ← bufferOf rig VertexBuffer 16
      ticket ← admitted first (UploadBuffer vertices (level 16 1))
      settleUploads rig first
      settleAll rig
      atomically (readUploadTicket ticket) `shouldReturn` UploadComplete
      fmap (const ()) <$> submitUpload second (UploadBuffer vertices (level 16 2)) `shouldReturn` Left UploadNotFresh
      fmap (const ()) <$> submitUpload first (UploadBuffer vertices (level 16 2)) `shouldReturn` Left UploadNotFresh
      clean rig

    it "reports BC7 unsupported on a device without BC compression, where a BC7 texture is refused at its creation" $ do
      rig ← newRigOn (\standIn → standIn {standOffers = [standInDevice {offerTextureCompressionBC = False}]})
      limitRecording (rigRecordingStandIn rig) standInRecordingLimits {limitImageDimension = 16}
      uploads ← made rig (config 1024 64 4)
      uploadsSupportBC7 uploads `shouldBe` False
      createImage (rigRecording rig) (ImageDescription TextureImage Bc7Srgb 16 16 1) `shouldReturn` Left (RefusedImageUnsupported TextureImage Bc7Srgb)

  describe "reservations" $ do
    it "reserves on the decision admission makes, holding its queue place for every other caller until abandoned" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 1)
      other ← bufferOf rig VertexBuffer 16
      atomically (uploadRoom uploads 16) `shouldReturn` Right ()
      grant ← (prepare 16 >>= commit . reserveUploadTx uploads) >>= either (fail . show) pure
      -- the one queue place is the reservation's: observed and refused alike, nothing copied
      atomically (uploadRoom uploads 16) `shouldReturn` Left (UploadBackpressure QueueFull)
      fmap (const ()) <$> submitUpload uploads (UploadBuffer other (level 16 1)) `shouldReturn` Left (UploadBackpressure QueueFull)
      writes rig `shouldReturn` []
      commit (abandonUploadGrantTx uploads grant)
      uploadsReserved <$> atomically (readUploads uploads) `shouldReturn` []
      _ ← admitted uploads (UploadBuffer other (level 16 1))
      clean rig

    it "refuses room no aligned gap holds though the free bytes suffice, and a reservation larger than the whole staging for good" $ do
      rig ← newUploadRig
      uploads ← made rig (config 64 64 8)
      grants ← forM [1 ∷ Int .. 3] (\_ → (prepare 16 >>= commit . reserveUploadTx uploads) >>= either (fail . show) pure)
      -- 32 bytes are free, in two gaps of 16: a 32-byte request fits neither
      commit (abandonUploadGrantTx uploads (grants !! 1))
      atomically (uploadRoom uploads 32) `shouldReturn` Left (UploadBackpressure StagingFull)
      fmap (const ()) <$> (prepare 32 >>= commit . reserveUploadTx uploads) `shouldReturn` Left (UploadBackpressure StagingFull)
      atomically (uploadRoom uploads 16) `shouldReturn` Right ()
      fmap (const ()) <$> (prepare 65 >>= commit . reserveUploadTx uploads) `shouldReturn` Left (UploadOversized 80 64)
      length . uploadsReserved <$> atomically (readUploads uploads) `shouldReturn` 2

    it "spends a reservation once, into a fresh vertex buffer of exactly its bytes, which then competes for nothing" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 1)
      grant ← (prepare 16 >>= commit . reserveUploadTx uploads) >>= either (fail . show) pure
      wrongSize ← bufferOf rig VertexBuffer 32
      indices ← bufferOf rig IndexBuffer 16
      vertices ← bufferOf rig VertexBuffer 16
      -- refusals leave the reservation as it was
      submitUploadGranted ungated uploads grant wrongSize (level 32 1) >>= \case
        Left (UploadMalformed _) → pure ()
        other → expectationFailure ("a spend of other bytes than reserved was answered " <> show (fmap (const ()) other))
      fmap (const ()) <$> submitUploadGranted ungated uploads grant indices (level 16 1) `shouldReturn` Left UploadWrongKind
      length . uploadsReserved <$> atomically (readUploads uploads) `shouldReturn` 1
      -- the queue holds one: the reservation's place is what the spend takes
      ticket ← submitUploadGranted ungated uploads grant vertices (level 16 1) >>= either (fail . show) pure
      atomically (readUploadTicket ticket) `shouldReturn` UploadQueued
      uploadsReserved <$> atomically (readUploads uploads) `shouldReturn` []
      -- spent: it binds nothing again, and abandoning it frees nothing of the live upload's
      again ← bufferOf rig VertexBuffer 16
      fmap (const ()) <$> submitUploadGranted ungated uploads grant again (level 16 1) `shouldReturn` Left (UploadMisuse (StaleIdentity ResourceIdentity))
      commit (abandonUploadGrantTx uploads grant)
      map uploadRegion . uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` [(0, 16)]
      atomically (uploadRoom uploads 16) `shouldReturn` Left (UploadBackpressure QueueFull)
      clean rig

    it "binds or abandons a reservation only through the uploads that issued it, though another's over the same recording has the same number" $ do
      rig ← newUploadRig
      first ← made rig (config 1024 64 4)
      second ← made rig (config 1024 64 4)
      ours ← (prepare 16 >>= commit . reserveUploadTx first) >>= either (fail . show) pure
      theirs ← (prepare 16 >>= commit . reserveUploadTx second) >>= either (fail . show) pure
      map fst . uploadsReserved <$> atomically (readUploads first) `shouldReturn` [0]
      map fst . uploadsReserved <$> atomically (readUploads second) `shouldReturn` [0]
      vertices ← bufferOf rig VertexBuffer 16
      fmap (const ()) <$> submitUploadGranted ungated second ours vertices (level 16 1) `shouldReturn` Left (UploadMisuse (StaleIdentity ResourceIdentity))
      commit (abandonUploadGrantTx second ours >> abandonUploadGrantTx first theirs)
      length . uploadsReserved <$> atomically (readUploads first) `shouldReturn` 1
      length . uploadsReserved <$> atomically (readUploads second) `shouldReturn` 1
      uploadsUnsettled <$> atomically (readUploads second) `shouldReturn` []
      -- each spends in its own
      _ ← submitUploadGranted ungated first ours vertices (level 16 1) >>= either (fail . show) pure
      length . uploadsReserved <$> atomically (readUploads second) `shouldReturn` 1
      clean rig

    it "abandons every unspent reservation when admission closes" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      grant ← (prepare 16 >>= commit . reserveUploadTx uploads) >>= either (fail . show) pure
      atomically (closeUploads uploads)
      uploadsReserved <$> atomically (readUploads uploads) `shouldReturn` []
      vertices ← bufferOf rig VertexBuffer 16
      fmap (const ()) <$> submitUploadGranted ungated uploads grant vertices (level 16 1) `shouldReturn` Left UploadClosed
      fmap (const ()) <$> (prepare 16 >>= commit . reserveUploadTx uploads) `shouldReturn` Left UploadClosed

    it "returns a bound grant's place, region and target through one cleanup whatever ends it before it is queued: the copy raising, or the gate raising, waiting, cancelled or answering a refusal whose payload raises after the copy; the spent grant is stale, a fresh upload takes the same room and target, and retirement finishes" $
      forM_ [AfterCopyRaises, GateRaises, GateWaits, GateCancelled, GateRefusalRaises] $ \ending → do
        rig ← newUploadRig
        -- one queue place and the whole staging buffer: the grant takes both
        uploads ← made rig (config 64 64 1)
        grant ← (prepare 64 >>= commit . reserveUploadTx uploads) >>= either (fail . show) pure
        vertices ← bufferOf rig VertexBuffer 64
        afterCopy ← newTVarIO Nothing
        let gate =
              readTVar afterCopy >>= \case
                Nothing → ungated
                Just GateRaises → throwSTM (ErrorCall "the gate raised")
                Just GateWaits → retry
                -- the refusal is evaluated where the submission owns its exception, after the admission's cleanup
                Just GateRefusalRaises → pure (Left (UploadMalformed (error "the refusal's payload raised")))
                Just _ → throwSTM ThreadKilled
        case ending of
          AfterCopyRaises → failAt (rigRecordingStandIn rig) AtWriteMapped
          _ → onceAt (rigRecordingStandIn rig) AtWriteMapped (atomically (writeTVar afterCopy (Just ending)))
        outcome ← try @SomeException (submitUploadGranted gate uploads grant vertices (level 64 1))
        case (ending, outcome) of
          (AfterCopyRaises, Left raised) | Just (RecordingFailure AtWriteMapped) ← fromException raised → pure ()
          (GateRaises, Left raised) | Just (ErrorCall "the gate raised") ← fromException raised → pure ()
          (GateWaits, Right (Left UploadGateBusy)) → pure ()
          (GateCancelled, Left raised) | Just ThreadKilled ← fromException raised → pure ()
          (GateRefusalRaises, Left raised) | Just (ErrorCall "the refusal's payload raised") ← fromException raised → pure ()
          _ → expectationFailure ("unexpected outcome for " <> show ending <> ": " <> either show (show . fmap (const ())) outcome)
        succeedAt (rigRecordingStandIn rig) AtWriteMapped
        atomically (writeTVar afterCopy Nothing)
        uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []
        fmap (const ()) <$> submitUploadGranted ungated uploads grant vertices (level 64 1) `shouldReturn` Left (UploadMisuse (StaleIdentity ResourceIdentity))
        _ ← admitted uploads (UploadBuffer vertices (level 64 1))
        ok (retireUploads uploads)

    it "gives copied bytes to whichever commits first, the gate's closing or the queue: closed first, a refusal and the room free again; queued first, an upload the queue settles, holding its target until it does" $ do
      rig ← newUploadRig
      uploads ← made rig (config 64 64 1)
      vertices ← bufferOf rig VertexBuffer 64
      current ← admissionNow True
      let gate = gateOver current
          close = readTVar current >>= closeAdmission
      -- closed first: the gate closes while the bytes are copied
      onceAt (rigRecordingStandIn rig) AtWriteMapped (atomically close)
      fmap (const ()) <$> submitUploadGated gate uploads (UploadBuffer vertices (level 64 1)) `shouldReturn` Left UploadClosed
      uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []
      -- queued first: the gate closes once the upload is queued
      atomically (newAdmission >>= writeTVar current)
      ticket ← submitUploadGated gate uploads (UploadBuffer vertices (level 64 1)) >>= either (fail . show) pure
      atomically close
      fmap (const ()) <$> submitUploadGated ungated uploads (UploadBuffer vertices (level 64 1)) `shouldReturn` Left UploadAlreadyTargeted
      settleUploads rig uploads
      atomically (readUploadTicket ticket) `shouldReturn` UploadComplete
      clean rig

    it "leaves an upload the queue took to the queue when its submitter is cancelled after the queueing commit and before its ticket's delivery: its place, range and target stay held through settlement, its place and range are reusable once, and retirement completes" $ do
      rig ← newUploadRig
      uploads ← made rig (config 64 64 1)
      vertices ← bufferOf rig VertexBuffer 64
      submitter ← myThreadId
      fire ← newEmptyMVar
      withOwnedThread (takeMVar fire >> killThread submitter) $ \killer _ → do
        -- the rendezvous: inside the submitter's protected hand-off, the queue's commit made, the ticket not yet handed
        -- back; the cancellation is aimed at the submitter from there
        onceAt (rigRecordingStandIn rig) AtUploadQueued (putMVar fire () >> awaitThrowing killer)
        try (submitUpload uploads (UploadBuffer vertices (level 64 1))) >>= \case
          Left raised | Just ThreadKilled ← fromException raised → pure ()
          Left raised → expectationFailure ("the submitter ended otherwise: " <> show (raised ∷ SomeException))
          Right answer → expectationFailure ("the cancellation was not delivered: " <> show (fmap (const ()) answer))
      -- the queue holds the upload: its place and staging range, and its target, which takes no other upload
      length . uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` 1
      fmap (const ()) <$> submitUpload uploads (UploadBuffer vertices (level 64 1)) `shouldReturn` Left UploadAlreadyTargeted
      -- settled by the queue, which fills the target once; then the place and the whole staging range are free again,
      -- for another target's upload of the same size, and retirement completes
      settleUploads rig uploads
      uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []
      fmap (const ()) <$> submitUpload uploads (UploadBuffer vertices (level 64 1)) `shouldReturn` Left UploadNotFresh
      another ← bufferOf rig VertexBuffer 64
      _ ← admitted uploads (UploadBuffer another (level 64 1))
      settleUploads rig uploads
      ok (retireUploads uploads)
      clean rig

    it "refuses an upload whose permit's admission closed after the gate admitted it and before the commit that binds or queues it, and one whose admission was closed and reopened while its bytes were copied" $ do
      let fresh = do
            rig ← newUploadRig
            uploads ← made rig (config 64 64 1)
            vertices ← bufferOf rig VertexBuffer 64
            current ← admissionNow True
            pure (rig, uploads, vertices, current)
          closeNow current = readTVar current >>= closeAdmission
      -- closed after the first ask admits, before the binding commit: nothing taken, the grant still spendable
      (rig, uploads, vertices, current) ← fresh
      grant ← (prepare 64 >>= commit . reserveUploadTx uploads) >>= either (fail . show) pure
      let closingOnAsk = gateOver current <* closeNow current
      fmap (const ()) <$> submitUploadGranted closingOnAsk uploads grant vertices (level 64 1) `shouldReturn` Left UploadClosed
      length . uploadsReserved <$> atomically (readUploads uploads) `shouldReturn` 1
      atomically (newAdmission >>= writeTVar current)
      _ ← submitUploadGranted (gateOver current) uploads grant vertices (level 64 1) >>= either (fail . show) pure
      clean rig
      -- closed after the second ask admits, before the queueing commit: the room returns, the grant is spent
      (rig', uploads', vertices', current') ← fresh
      grant' ← (prepare 64 >>= commit . reserveUploadTx uploads') >>= either (fail . show) pure
      asks ← newTVarIO (0 ∷ Int)
      let closingOnSecond = do
            answer ← gateOver current'
            n ← readTVar asks
            writeTVar asks (n + 1)
            when (n == 1) (closeNow current')
            pure answer
      fmap (const ()) <$> submitUploadGranted closingOnSecond uploads' grant' vertices' (level 64 1) `shouldReturn` Left UploadClosed
      uploadsUnsettled <$> atomically (readUploads uploads') `shouldReturn` []
      atomically (newAdmission >>= writeTVar current')
      fmap (const ()) <$> submitUploadGranted (gateOver current') uploads' grant' vertices' (level 64 1) `shouldReturn` Left (UploadMisuse (StaleIdentity ResourceIdentity))
      _ ← submitUploadGated (gateOver current') uploads' (UploadBuffer vertices' (level 64 1)) >>= either (fail . show) pure
      clean rig'
      -- closed and reopened while the bytes are copied: the reopened admission does not revive the upload
      (rig'', uploads'', vertices'', current'') ← fresh
      onceAt (rigRecordingStandIn rig'') AtWriteMapped (atomically (closeNow current'' >> newAdmission >>= writeTVar current''))
      fmap (const ()) <$> submitUploadGated (gateOver current'') uploads'' (UploadBuffer vertices'' (level 64 1)) `shouldReturn` Left UploadClosed
      uploadsUnsettled <$> atomically (readUploads uploads'') `shouldReturn` []
      _ ← submitUploadGated (gateOver current'') uploads'' (UploadBuffer vertices'' (level 64 1)) >>= either (fail . show) pure
      clean rig''

    it "owns an admitted upload's every exit until it is queued: a gate's second answer that raises when evaluated, and a session failure latched after it, each give back the place, range and target" $ do
      -- the gate's second answer raises only when it is evaluated
      rig ← newUploadRig
      uploads ← made rig (config 64 64 1)
      vertices ← bufferOf rig VertexBuffer 64
      asks ← newTVarIO (0 ∷ Int)
      let deferred = do
            n ← readTVar asks
            writeTVar asks (n + 1)
            answer ← ungated
            pure (if n == 0 then answer else error "the gate's answer raised")
      try @ErrorCall (submitUploadGated deferred uploads (UploadBuffer vertices (level 64 1))) >>= \case
        Left (ErrorCall cause) → cause `shouldBe` "the gate's answer raised"
        Right answer → expectationFailure ("expected the gate's answer to raise, found " <> show (fmap (const ()) answer))
      uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []
      _ ← admitted uploads (UploadBuffer vertices (level 64 1))
      clean rig
      -- the session fails in the transaction of the gate's second answer, which admits: the queueing commit refuses
      rig' ← newUploadRig
      uploads' ← made rig' (config 64 64 1)
      vertices' ← bufferOf rig' VertexBuffer 64
      asks' ← newTVarIO (0 ∷ Int)
      let failing = do
            n ← readTVar asks'
            writeTVar asks' (n + 1)
            when (n == 1) (failRootsSession (rigRoots rig') CleanupFailed)
            ungated
      submitUploadGated failing uploads' (UploadBuffer vertices' (level 64 1)) >>= \case
        Left (UploadSessionFailed _) → pure ()
        other → expectationFailure ("expected the session's failure, found " <> show (fmap (const ()) other))
      uploadsUnsettled <$> atomically (readUploads uploads') `shouldReturn` []
      ok (retireUploads uploads')

  describe "progress" $ do
    it "records each turn's copies at block-row boundaries under the budget, the target resting in its transfer write between batches, and completes on the final batch's fence" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      texture ← textureOf rig Rgba8Linear 8 8 2
      ticket ← admitted uploads (UploadImage texture [level 256 1, level 64 2])
      (image, staging) ← handlesOf rig texture uploads
      perTurn ← forM [1 ∷ Int .. 5] $ \_ → do
        before ← length <$> commands rig
        _ ← turned uploads
        state ← atomically (readUploadTicket ticket)
        recorded ← drop before <$> commands rig
        completeAll' rig
        pure (state, [copy | copy@CommandCopyBufferToImage {} ← recorded], barriersOn image recorded)
      map (\(_, copies, _) → copies) perTurn
        `shouldBe` [ [CommandCopyBufferToImage staging 0 image 0 0 8 2]
                   , [CommandCopyBufferToImage staging 64 image 0 2 8 2]
                   , [CommandCopyBufferToImage staging 128 image 0 4 8 2]
                   , [CommandCopyBufferToImage staging 192 image 0 6 8 2]
                   , [CommandCopyBufferToImage staging 256 image 1 0 4 4]
                   ]
      -- Out of the undefined layout into the transfer write first; back into
      -- it at every other boundary; shader-read only at the last.
      map (\(_, _, barriers) → barriers) perTurn
        `shouldBe` [[(0, 7), (7, 7)], [(7, 7), (7, 7)], [(7, 7), (7, 7)], [(7, 7), (7, 7)], [(7, 7), (7, 5)]]
      map (\(state, _, _) → state) perTurn `shouldBe` replicate 5 UploadUploading
      _ ← turned uploads
      atomically (readUploadTicket ticket) `shouldReturn` UploadComplete
      resourceInitialization (managedResource texture) <$> modelOf rig `shouldReturn` Just Initialized
      clean rig

    it "splits a BC7 level at block rows, its last partial row reaching the level's edge, and a buffer at byte ranges" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      texture ← textureOf rig Bc7Linear 12 6 1
      vertices ← bufferOf rig VertexBuffer 100
      _ ← admitted uploads (UploadImage texture [level 96 1])
      _ ← admitted uploads (UploadBuffer vertices (level 100 2))
      (image, staging) ← handlesOf rig texture uploads
      buffer ← bufferHandle rig vertices
      copies ← forM [1 ∷ Int .. 4] $ \_ → do
        before ← length <$> commands rig
        _ ← turned uploads
        recorded ← drop before <$> commands rig
        completeAll' rig
        pure [copy | copy ← recorded, isCopy copy]
      -- The texture's 48-byte rows take the budget one at a time; the buffer
      -- follows in the bytes each turn leaves.
      copies
        `shouldBe` [ [CommandCopyBufferToImage staging 0 image 0 0 12 4, CommandCopyBuffer staging 96 buffer 0 16]
                   , [CommandCopyBufferToImage staging 48 image 0 4 12 2, CommandCopyBuffer staging 112 buffer 16 16]
                   , [CommandCopyBuffer staging 128 buffer 32 64]
                   , [CommandCopyBuffer staging 192 buffer 96 4]
                   ]
      clean rig

    it "refuses the target to every other batch until the upload completes" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      kit ← newKit rig
      texture ← textureOf rig Rgba8Linear 8 8 2
      vertices ← bufferOf rig VertexBuffer 64
      _ ← admitted uploads (UploadImage texture [level 256 1, level 64 2])
      _ ← admitted uploads (UploadBuffer vertices (level 64 1))
      _ ← turned uploads
      refused ← framelessOnce rig $ \recorder →
        sequence
          [ transitionResource recorder texture (FromUse ShaderSampled) TransferRead
          , transitionResource recorder vertices (FromUse GeometryRead) GeometryRead
          ]
      refused `shouldBe` replicate 2 (Left RefusedUninitialized)
      settleUploads rig uploads
      used ← framelessOnce rig $ \recorder → do
        moved ← transitionResource recorder texture (FromUse ShaderSampled) TransferRead
        back ← transitionResource recorder texture (FromUse TransferRead) ShaderSampled
        touched ← transitionResource recorder vertices (FromUse GeometryRead) GeometryRead
        bound ← inPass kit recorder (bindVertexBuffer recorder 0 (FromBuffer vertices 0))
        pure [moved, back, touched, bound]
      used `shouldBe` replicate 4 (Right ())
      settleAll rig
      clean rig

    it "frees staging only when an upload settles: not while its copies are recorded or in flight" $ do
      rig ← newUploadRig
      uploads ← made rig (config 320 64 4)
      texture ← textureOf rig Rgba8Linear 8 8 2
      vertices ← bufferOf rig VertexBuffer 16
      _ ← admitted uploads (UploadImage texture [level 256 1, level 64 2])
      replicateM_ 5 (turned uploads >> completeAll' rig)
      -- Every copy recorded, the last in flight: the region is still held.
      fmap uploadCopied . uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` [True]
      fmap (const ()) <$> submitUpload uploads (UploadBuffer vertices (level 16 1)) `shouldReturn` Left (UploadBackpressure StagingFull)
      _ ← turned uploads
      uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []
      _ ← admitted uploads (UploadBuffer vertices (level 16 1))
      clean rig

    it "records a discarded batch's copies again from the same bytes, and frees nothing for it" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      vertices ← bufferOf rig VertexBuffer 16
      ticket ← admitted uploads (UploadBuffer vertices (level 16 1))
      failNextSubmission rig
      _ ← turned uploads
      atomically (readUploadTicket ticket) `shouldReturn` UploadQueued
      fmap (\view → (uploadStarted view, uploadInFlight view)) . uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` [(False, False)]
      clearSubmissionFailure rig
      _ ← turned uploads
      completeAll' rig
      _ ← turned uploads
      atomically (readUploadTicket ticket) `shouldReturn` UploadComplete
      buffer ← bufferHandle rig vertices
      staging ← stagingOf rig uploads
      ((\calls → [copy | Recorded _ copy@CommandCopyBuffer {} ← calls]) <$> recordingCalls (rigRecordingStandIn rig))
        `shouldReturn` replicate 2 (CommandCopyBuffer staging 0 buffer 0 16)
      clean rig

    it "flushes each turn's staging bytes on non-coherent memory, aligned to the atom and never past the upload's region" $ do
      rig ← newUploadRig
      allowTypes (standAllocator (rigRootsStandIn rig)) (2 ^ deviceLocalType + 2 ^ nonCoherentType)
      uploads ← made rig (config 1024 64 4)
      first ← bufferOf rig VertexBuffer 100
      second ← bufferOf rig VertexBuffer 8
      _ ← admitted uploads (UploadBuffer first (level 100 1))
      _ ← admitted uploads (UploadBuffer second (level 8 2))
      _ ← turned uploads
      completeAll' rig
      _ ← turned uploads
      flushes ← (\calls → [range | Flushed _ range ← calls]) <$> allocatorCalls (standAllocator (rigRootsStandIn rig))
      -- 100 bytes padded to 128 by the 64-byte atom, then 8 padded to 64; the
      -- first turn reads the first 64 bytes, the second the rest of the first
      -- and all of the second.
      drop (length flushes - 3) flushes `shouldBe` [(0, 64), (64, 64), (128, 64)]
      clean rig

  describe "tickets and cancellation" $ do
    it "cancels an upload not yet started, freeing its staging and leaving its target uninitialized, and refuses one started, which completes" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      texture ← textureOf rig Rgba8Linear 4 4 1
      ticket ← admitted uploads (UploadImage texture [level 64 1])
      atomically (cancelUpload uploads ticket) `shouldReturn` Right ()
      atomically (readUploadTicket ticket) `shouldReturn` UploadCancelled
      uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []
      resourceInitialization (managedResource texture) <$> modelOf rig `shouldReturn` Just Uninitialized
      atomically (cancelUpload uploads ticket) `shouldReturn` Left (CancelSettled UploadCancelled)
      again ← admitted uploads (UploadImage texture [level 64 1])
      _ ← turned uploads
      atomically (cancelUpload uploads again) `shouldReturn` Left CancelStarted
      settleUploads rig uploads
      atomically (readUploadTicket again) `shouldReturn` UploadComplete
      clean rig

    it "refuses a cancellation, and holds the staging region, while the owner records an upload's first copies, which then complete" $ do
      rig ← newUploadRig
      uploads ← made rig (config 64 64 4)
      texture ← textureOf rig Rgba8Linear 4 4 1
      rival ← textureOf rig Rgba8Linear 4 4 1
      ticket ← admitted uploads (UploadImage texture [level 64 1])
      seen ← newEmptyMVar
      -- Inside the copy's recording, on the owner's thread, as another
      -- thread's cancellation and admission could land.
      duringRecord (rigRecordingStandIn rig) $ \case
        CommandCopyBufferToImage {} → do
          cancelling ← atomically (cancelUpload uploads ticket)
          admittedNow ← fmap (const ()) <$> submitUpload uploads (UploadImage rival [level 64 2])
          () <$ tryPutMVar seen (cancelling, admittedNow)
        _ → pure ()
      _ ← turned uploads
      duringRecord (rigRecordingStandIn rig) (const (pure ()))
      takeMVar seen `shouldReturn` (Left CancelStarted, Left (UploadBackpressure StagingFull))
      atomically (readUploadTicket ticket) `shouldReturn` UploadUploading
      settleUploads rig uploads
      atomically (readUploadTicket ticket) `shouldReturn` UploadComplete
      resourceInitialization (managedResource texture) <$> modelOf rig `shouldReturn` Just Initialized
      clean rig

    it "refuses a cancellation and a rival admission at the batch's submission, and publishes its flight as it releases the claim" $ do
      rig ← newUploadRig
      uploads ← made rig (config 64 64 4)
      texture ← textureOf rig Rgba8Linear 4 4 1
      rival ← textureOf rig Rgba8Linear 4 4 1
      ticket ← admitted uploads (UploadImage texture [level 64 1])
      seen ← newEmptyMVar
      -- Inside the submission of the batch carrying its first copies, the
      -- last instant before the turn publishes what it submitted.
      duringFrameCall (rigStandIn rig) $ \case
        Submitted {} → do
          cancelling ← atomically (cancelUpload uploads ticket)
          admittedNow ← fmap (const ()) <$> submitUpload uploads (UploadImage rival [level 64 2])
          () <$ tryPutMVar seen (cancelling, admittedNow)
        _ → pure ()
      _ ← turned uploads
      duringFrameCall (rigStandIn rig) (const (pure ()))
      tryTakeMVar seen `shouldReturn` Just (Left CancelStarted, Left (UploadBackpressure StagingFull))
      -- The claim was released with the flight published in the same
      -- transaction: in flight, claimed no longer, and still held.
      fmap (\view → (uploadStarted view, uploadInFlight view, uploadClaimed view)) . uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` [(True, True, False)]
      atomically (cancelUpload uploads ticket) `shouldReturn` Left CancelStarted
      fmap (const ()) <$> submitUpload uploads (UploadImage rival [level 64 2]) `shouldReturn` Left (UploadBackpressure StagingFull)
      settleUploads rig uploads
      atomically (readUploadTicket ticket) `shouldReturn` UploadComplete
      clean rig

    it "releases the claim without a flight when the batch was discarded, so no submitted work holds the upload and it may be cancelled" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      vertices ← bufferOf rig VertexBuffer 16
      ticket ← admitted uploads (UploadBuffer vertices (level 16 1))
      failNextSubmission rig
      _ ← turned uploads
      clearSubmissionFailure rig
      fmap (\view → (uploadStarted view, uploadInFlight view, uploadClaimed view)) . uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` [(False, False, False)]
      atomically (cancelUpload uploads ticket) `shouldReturn` Right ()
      atomically (readUploadTicket ticket) `shouldReturn` UploadCancelled
      uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []
      clean rig

    it "completes a ticket only on its final batch's fence, refuses a wait on the owner, and lets a deadline pass without cancelling anything" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      vertices ← bufferOf rig VertexBuffer 16
      ticket ← admitted uploads (UploadBuffer vertices (level 16 1))
      _ ← turned uploads
      replicateM_ 3 (turned uploads >> progress rig)
      atomically (readUploadTicket ticket) `shouldReturn` UploadUploading
      awaitUploadTicket ticket (milliseconds 1) `shouldReturn` Left RefusedOwnerWait
      onOtherThread (awaitUploadTicket ticket (milliseconds 5)) `shouldReturn` Right UploadUploading
      completeAll' rig
      _ ← turned uploads
      atomically (readUploadTicket ticket) `shouldReturn` UploadComplete
      clean rig

    it "loses every unsettled upload once the device is lost, never completing one" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      started ← bufferOf rig VertexBuffer 16
      queued ← bufferOf rig VertexBuffer 16
      first ← admitted uploads (UploadBuffer started (level 16 1))
      _ ← turned uploads
      second ← admitted uploads (UploadBuffer queued (level 16 1))
      inModel rig (Admitted . noteDeviceLoss)
      _ ← turned uploads
      mapM (atomically . readUploadTicket) [first, second] `shouldReturn` [UploadLost, UploadLost]

  describe "exit and release" $ do
    it "keeps an admitting caller's staging region through device loss until it finishes, then refuses its upload with the session's failure and gives its room back" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      texture ← textureOf rig Rgba8Linear 4 4 1
      entered ← newEmptyMVar
      release ← newEmptyMVar
      onceAt (rigRecordingStandIn rig) AtWriteMapped (putMVar entered () >> takeMVar release)
      answer ← newEmptyMVar
      withOwnedThreadOpening (void (tryPutMVar release ())) (submitUpload uploads (UploadImage texture [level 64 1]) >>= putMVar answer) $ \_ _ → do
        takeMVar entered
        inModel rig (Admitted . noteDeviceLoss)
        _ ← turned uploads
        -- Still its caller's: the loss settles nothing it is writing into.
        map uploadPhase . uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` [PhaseAdmitting]
        putMVar release ()
        -- the queueing commit finds the session failed: refused, and the one cleanup gives back every reservation
        takeMVar answer >>= \case
          Left (UploadSessionFailed _) → pure ()
          other → expectationFailure ("expected the session's failure, found " <> show (fmap (const ()) other))
        uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []

    it "retires only once a caller still copying its bytes into staging has finished, which then finds admission closed" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      texture ← textureOf rig Rgba8Linear 4 4 1
      entered ← newEmptyMVar
      release ← newEmptyMVar
      order ← newTVarIO []
      let note' event = atomically (modifyTVar' order (event :))
      onceAt (rigRecordingStandIn rig) AtWriteMapped (putMVar entered () >> takeMVar release >> note' "written")
      answer ← newEmptyMVar
      withOwnedThreadOpening (void (tryPutMVar release ())) (submitUpload uploads (UploadImage texture [level 64 1]) >>= putMVar answer . fmap (const ())) $ \_ _ → do
        takeMVar entered
        -- The caller is let go only once retirement has closed admission.
        withOwnedThread
          ( do
              atomically (readUploads uploads >>= check . not . uploadsAdmitting)
              note' "released"
              putMVar release ()
          )
          $ \_ _ → do
          ok (retireUploads uploads)
          note' "retired"
          takeMVar answer `shouldReturn` Left UploadClosed
          reverse <$> readTVarIO order `shouldReturn` ["released", "written", "retired" ∷ Text]
          uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []

    it "cancels every upload not started when the owner's exit begins, refuses new ones, and settles started ones with their batches" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      finished ← bufferOf rig VertexBuffer 16
      unfinished ← textureOf rig Rgba8Linear 8 8 1
      queued ← bufferOf rig VertexBuffer 16
      done ← admitted uploads (UploadBuffer finished (level 16 1))
      partial ← admitted uploads (UploadImage unfinished [level 256 1])
      _ ← turned uploads
      waiting ← admitted uploads (UploadBuffer queued (level 16 1))
      atomically (closeUploads uploads)
      atomically (readUploadTicket waiting) `shouldReturn` UploadCancelled
      fmap (const ()) <$> submitUpload uploads (UploadBuffer queued (level 16 1)) `shouldReturn` Left UploadClosed
      completeAll' rig
      ok (retireUploads uploads)
      mapM (atomically . readUploadTicket) [done, partial] `shouldReturn` [UploadComplete, UploadCancelled]
      uploadsUnsettled <$> atomically (readUploads uploads) `shouldReturn` []

    it "cancels an upload whose target was released before it started, and destroys the target only once its upload has settled" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      early ← textureOf rig Rgba8Linear 4 4 1
      late ← textureOf rig Rgba8Linear 8 8 2
      waiting ← admitted uploads (UploadImage early [level 64 1])
      ok (releaseManaged (rigRecording rig) early)
      started ← admitted uploads (UploadImage late [level 256 1, level 64 2])
      _ ← turned uploads
      atomically (readUploadTicket waiting) `shouldReturn` UploadCancelled
      ok (releaseManaged (rigRecording rig) late)
      -- Released, and still copied into: nothing destroys it until it is done.
      _ ← disposeResources (rigRecording rig) (at 1)
      standing rig late `shouldReturn` Just ManagedReleased
      settleUploads rig uploads
      atomically (readUploadTicket started) `shouldReturn` UploadComplete
      settleAll rig
      _ ← disposeResources (rigRecording rig) (at 2)
      standing rig early `shouldReturn` Nothing
      standing rig late `shouldReturn` Nothing
      clean rig

  describe "reading what was uploaded" $ do
    it "bounds an indexed draw through an uploaded index buffer by the indices it wrote" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      kit ← newKit rig
      vertices ← bufferOf rig VertexBuffer 32
      indices ← bufferOf rig IndexBuffer 12
      offsets' ← bufferOf rig InstanceBuffer 16
      _ ← admitted uploads (UploadBuffer vertices (level 32 1))
      _ ← admitted uploads (UploadBuffer indices (indices16 [0, 1, 2, 2, 1, 3]))
      settleUploads rig uploads
      answers ← framelessOnce rig $ \recorder → do
        ok (transitionResource recorder vertices (FromUse GeometryRead) GeometryRead)
        ok (transitionResource recorder indices (FromUse GeometryRead) GeometryRead)
        ok (transitionResource recorder offsets' (FromUse InstanceRead) InstanceRead)
        inPass kit recorder $ do
          ok (bindVertexBuffer recorder 0 (FromBuffer vertices 0))
          ok (bindVertexBuffer recorder 1 (FromBuffer offsets' 0))
          ok (bindIndexBuffer recorder (FromBuffer indices 0) Index16)
          sequence [drawIndexed recorder 6 1, drawIndexed recorder 6 3]
      answers `shouldBe` [Right (), Left (RefusedOutOfBounds 24 16)]
      settleAll rig
      clean rig

    it "copies any level of a texture back after a checked transition, and refuses another kind, a level it lacks and a buffer too small" $ do
      rig ← newUploadRig
      uploads ← made rig (config 1024 64 4)
      texture ← textureOf rig Rgba8Linear 8 8 2
      target ← created (createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Linear 8 8 1))
      readback ← created (createReadback (rigRecording rig) 64)
      small ← created (createReadback (rigRecording rig) 63)
      _ ← admitted uploads (UploadImage texture [level 256 1, level 64 2])
      settleUploads rig uploads
      answers ← framelessOnce rig $ \recorder → do
        moved ← transitionResource recorder texture (FromUse ShaderSampled) TransferRead
        refused ←
          sequence
            [ copyLevelToReadback recorder target 0 readback
            , copyLevelToReadback recorder texture 2 readback
            , copyLevelToReadback recorder texture 1 small
            ]
        copied ← copyLevelToReadback recorder texture 1 readback
        back ← transitionResource recorder texture (FromUse TransferRead) ShaderSampled
        pure (moved : refused <> [copied, back])
      answers
        `shouldBe` [ Right ()
                   , Left RefusedWrongKind
                   , Left (RefusedOutOfBounds 3 2)
                   , Left (RefusedOutOfBounds 64 63)
                   , Right ()
                   , Right ()
                   ]
      (image, _) ← handlesOf rig texture uploads
      readbackBuffer ← readbackHandle rig readback
      ((\calls → [copy | Recorded _ copy@CommandCopyImageLevelToBuffer {} ← calls]) <$> recordingCalls (rigRecordingStandIn rig))
        `shouldReturn` [CommandCopyImageLevelToBuffer image 1 4 4 readbackBuffer]
      settleAll rig
      clean rig

-- ---------------------------------------------------------------------------
-- The rig

-- | The frames' rig, its device's widest image level 16 texels wide.
newUploadRig ∷ IO Rig
newUploadRig = do
  rig ← newRig
  limitRecording (rigRecordingStandIn rig) standInRecordingLimits {limitImageDimension = 16}
  pure rig

config ∷ Integer → Integer → Integer → UploadConfig
config staging budget queue = either (error . show) id (validateUploadConfig staging budget queue)

made ∷ Rig → UploadConfig → IO Ups
made rig configured = newUploads (rigFrames rig) configured >>= either (fail . ("the uploads were refused: " <>) . show) pure

admitted ∷ Ups → UploadRequest → IO UploadTicket
admitted uploads request = submitUpload uploads request >>= either (fail . ("the upload was refused: " <>) . show) pure

-- | One owner turn's uploads.
turned ∷ Ups → IO UploadProgress
turned uploads = progressUploads uploads >>= either (fail . show) pure

-- | Complete every pending fence and observe it, as the owner's next progress
-- step would.
completeAll' ∷ Rig → IO ()
completeAll' rig = completeAll (rigStandIn rig) >> () <$ progress rig

-- | Turn and complete until no upload is left unsettled.
settleUploads ∷ Rig → Ups → IO ()
settleUploads rig uploads = go (32 ∷ Int)
  where
    go 0 = expectationFailure "the uploads did not settle in 32 turns"
    go remaining = do
      _ ← turned uploads
      completeAll' rig
      _ ← turned uploads
      left ← uploadsUnsettled <$> atomically (readUploads uploads)
      when (not (null left)) (go (remaining - 1))

textureOf ∷ Rig → ImageFormat → Word32 → Word32 → Word32 → IO Image
textureOf rig format width height levels = created (createImage (rigRecording rig) (ImageDescription TextureImage format width height levels))

bufferOf ∷ Rig → BufferKind → Natural → IO Buffer
bufferOf rig kind' bytes' = created (createBuffer (rigRecording rig) (BufferDescription kind' bytes'))

created ∷ Show refusal ⇒ IO (Either refusal a) → IO a
created action = action >>= either (fail . ("the creation was refused: " <>) . show) pure

level ∷ Int → Word8 → ByteString.ByteString
level count byte = ByteString.replicate count byte

-- | Every command the recording recorded, in order.
commands ∷ Rig → IO [NativeCommand]
commands rig = (\calls → [command | Recorded _ command ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

isCopy ∷ NativeCommand → Bool
isCopy = \case
  CommandCopyBuffer {} → True
  CommandCopyBufferToImage {} → True
  _ → False

-- | The layouts each barrier on this image leaves and enters.
barriersOn ∷ Word64 → [NativeCommand] → [(Word32, Word32)]
barriersOn image recorded = [(from, to) | CommandResourceBarrier (BarrierImage handle _ _ from to) _ _ ← recorded, handle == image]

-- | Every bytes write into mapped memory the recording made.
writes ∷ Rig → IO [(Natural, Natural)]
writes rig = (\calls → [(offset, count) | WroteMapped offset count ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

-- | How many staging buffers the recording holds.
stagingCount ∷ Rig → IO Int
stagingCount rig = (\views → length [() | ManagedView _ _ "staging buffer" _ ← views]) <$> atomically (readManaged (rigRecording rig))

-- | A managed generation's native handles: an image's first is the image, a
-- buffer's the buffer.
handlesOf' ∷ Rig → ResourceId → IO [Word64]
handlesOf' rig resource =
  (\views → concat [handles | ManagedView viewed _ _ handles ← views, viewed == resource]) <$> atomically (readManaged (rigRecording rig))

-- | A texture's native image, and the uploads' staging buffer.
handlesOf ∷ Rig → Image → Ups → IO (Word64, Word64)
handlesOf rig texture uploads = do
  image ← firstOf <$> handlesOf' rig (managedResource texture)
  staging ← stagingOf rig uploads
  pure (image, staging)

stagingOf ∷ Rig → Ups → IO Word64
stagingOf rig uploads = do
  view ← atomically (readUploads uploads)
  firstOf <$> handlesOf' rig (uploadsStagingBuffer view)

bufferHandle ∷ Rig → Buffer → IO Word64
bufferHandle rig buffer = firstOf <$> handlesOf' rig (managedResource buffer)

readbackHandle ∷ Rig → Readback → IO Word64
readbackHandle rig readback = firstOf <$> handlesOf' rig (managedResource readback)

firstOf ∷ [Word64] → Word64
firstOf = \case
  handle : _ → handle
  [] → error "the generation has no native handle"

-- | Where a generation stands, or 'Nothing' once it is gone.
standing ∷ Managed handle ⇒ Rig → handle → IO (Maybe ManagedStanding)
standing rig handle =
  (\views → case [held | ManagedView viewed held _ _ ← views, viewed == managedResource handle] of
      held : _ → Just held
      [] → Nothing)
    <$> atomically (readManaged (rigRecording rig))

-- | Make the next frame-less submission fail with no effect, as out of
-- memory does, until 'clearSubmissionFailure'.
failNextSubmission ∷ Rig → IO ()
failNextSubmission rig = failFrameStep (rigStandIn rig) AtSubmitNoEffect

clearSubmissionFailure ∷ Rig → IO ()
clearSubmissionFailure rig = clearFrameStep (rigStandIn rig) AtSubmitNoEffect

-- | A color target of 32 by 16, and a pipeline over a layout with no ranges
-- reading a two-float position per vertex from binding 0 and a two-float
-- offset per instance from binding 1.
data Kit = Kit
  { kitTarget ∷ !Image
  , kitPipeline ∷ !Pipeline
  }

newKit ∷ Rig → IO Kit
newKit rig = do
  target ← created (createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Srgb 32 16 1))
  layout ← created (createPipelineLayout (rigRecording rig))
  pipeline ←
    created
      ( createPipelineWith
          (rigRecording rig)
          layout
          (PipelineShaders (ByteString.pack [1, 2, 3, 4]) (ByteString.pack [5, 6, 7, 8]))
          (formatCode Rgba8Srgb)
          ( VertexInput
              [VertexBinding 0 8 PerVertex, VertexBinding 1 8 PerInstance]
              [VertexAttribute 0 0 VertexFloat2 0, VertexAttribute 1 1 VertexFloat2 0]
          )
      )
  pure (Kit target pipeline)

-- | Run the action inside a pass into the kit's target, cleared from
-- undefined, with its pipeline bound and the viewport and scissor set.
inPass ∷ Kit → Rec → IO a → IO a
inPass kit recorder action = do
  ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 0 1))
  ok (bindPipeline recorder (kitPipeline kit))
  ok (setViewport recorder (Viewport 0 0 32 16))
  ok (setScissor recorder (Rect 0 0 32 16))
  value ← action
  ok (endRendering recorder)
  pure value

-- | Record one frame-less batch in a scope of its own, answering what the
-- consumer returned.
framelessOnce ∷ Rig → (Rec → IO a) → IO a
framelessOnce rig consumer =
  withFramelessScope (rigFrames rig) $ \scope → recordFramelessIn scope consumer >>= either (fail . show) (pure . snd)

-- | Little-endian 16-bit indices.
indices16 ∷ [Integer] → ByteString.ByteString
indices16 = ByteString.pack . concatMap (\index → [fromIntegral index, fromIntegral (index `div` 256)])

milliseconds ∷ Integer → Duration
milliseconds n = either (error . show) id (durationFromNanoseconds AllowZero (n * 1000000))

-- | What ends a granted upload between its binding and its queueing.
data PostBind = AfterCopyRaises | GateRaises | GateWaits | GateCancelled | GateRefusalRaises
  deriving (Eq, Show)

-- | A gate over the admission an example holds now: open while that admission is.
gateOver ∷ TVar Admission → UploadGate
gateOver current = do
  token ← admissionToken <$> readTVar current
  tokenOpen token <&> \open → if open then Right (admittedWhile token) else Left UploadClosed

-- | A fresh admission, open or already closed.
admissionNow ∷ Bool → IO (TVar Admission)
admissionNow open = do
  admission ← newAdmissionIO
  if open then pure () else atomically (closeAdmission admission)
  newTVarIO admission
