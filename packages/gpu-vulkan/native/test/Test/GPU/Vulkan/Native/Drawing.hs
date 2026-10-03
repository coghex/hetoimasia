-- | Drawing from buffers with push constants (GRS-4) over the frames' and the
-- recording's stand-in native layers: push-constant ranges and vertex input
-- validated before any native call; pushes, binds and draws checked against
-- the pipeline bound now; the session's shared ring — its size validated
-- once, regions claimed, written, padded and flushed on non-coherent memory,
-- reclaimed only when their batch completes or is discarded, kept through an
-- invalidation that raised, distinct across reuse, and full as backpressure;
-- vertex, instance and index data bound from claimed regions and managed
-- buffers, each bind retaining exactly what it references; and every checked
-- use refused with no native call.
--
-- Nothing here creates a Vulkan object, and nothing waits on a clock.
module Test.GPU.Vulkan.Native.Drawing (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), throwIO, try)
import Control.Monad (when)
import qualified Data.ByteString as ByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.GPU.Model (HoldKind (..), HoldView (..), holdView)
import Hetoimasia.GPU.Model.Budget (BudgetKind (RingBudget))
import Hetoimasia.GPU.Model.Identity (HoldSubject (..), IdentityKind (..), Misuse (..), ResourceId)
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Presentation (formatB8G8R8A8Srgb)
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Roots (stateRootsModel)
import Test.GPU.Vulkan.Native.AllocatorStandIn (AllocatorCall (..), allocatorCalls, allowTypes, deviceLocalType, nonCoherentType)
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn
import Test.GPU.Vulkan.Native.RecordingStandIn
  ( RecordingCall (..)
  , RecordingStep (AtResetStorage)
  , failAt
  , limitBuffers
  , limitRecording
  , recordingCalls
  , standInRecordingLimits
  )
import Test.GPU.Vulkan.Native.StandIn (StandIn (standAllocator))

type Rec = Recorder () Int Int Text Int Word64

spec ∷ Spec
spec = describe "Drawing from buffers" $ do
  describe "push constants" $ do
    it "validates a layout's push-constant ranges against the device and Vulkan's rules before any native call" $ do
      rig ← newRig
      before ← layoutCalls rig
      answers ←
        mapM
          (createPipelineLayoutWith (rigRecording rig))
          [ [PushConstantRange [] 0 16]
          , [PushConstantRange [PushVertex, PushVertex] 0 16]
          , [PushConstantRange [PushVertex] 0 0]
          , [PushConstantRange [PushVertex] 2 16]
          , [PushConstantRange [PushVertex] 0 6]
          , [PushConstantRange [PushVertex] 64 68]
          , [PushConstantRange [PushVertex] 0 16, PushConstantRange [PushVertex, PushFragment] 16 16]
          ]
      map (fmap (const ())) answers
        `shouldBe` [ Left (RefusedIllegal "a push-constant range for no stage")
                   , Left (RefusedIllegal "a push-constant range naming a stage twice")
                   , Left (RefusedIllegal "a push-constant range of no bytes")
                   , Left (RefusedIllegal "a push-constant range whose offset or size is not a multiple of four")
                   , Left (RefusedIllegal "a push-constant range whose offset or size is not a multiple of four")
                   , Left (RefusedOutOfBounds 132 128)
                   , Left (RefusedIllegal "two push-constant ranges for one stage")
                   ]
      layoutCalls rig `shouldReturn` before
      _ ← createPipelineLayoutWith (rigRecording rig) pushRanges >>= either (fail . show) pure
      calls ← recordingCalls (rigRecordingStandIn rig)
      [ranges | DeclaredRanges _ ranges ← calls] `shouldBe` [pushRanges]
      clean rig

    it "pushes bytes inside a declared range for its stages, and refuses a push outside the ranges, with no native call" $ do
      rig ← newRig
      kit ← newKit rig
      overlapping ← createPipelineLayoutWith (rigRecording rig) [PushConstantRange [PushVertex, PushFragment] 0 16] >>= either (fail . show) pure
      both ← createPipeline (rigRecording rig) overlapping shaders (formatCode Rgba8Srgb) >>= either (fail . show) pure
      answers ← framelessOnce rig $ \recorder → do
        unbound ← pushConstants recorder [PushVertex] 0 (bytes 16)
        inPass kit recorder $ do
          pushed ← pushConstants recorder [PushVertex] 0 (bytes 16)
          fragment ← pushConstants recorder [PushFragment] 16 (bytes 16)
          beyond ← pushConstants recorder [PushVertex] 8 (bytes 16)
          before ← pushConstants recorder [PushFragment] 12 (bytes 8)
          noStage ← pushConstants recorder [] 0 (bytes 4)
          empty ← pushConstants recorder [PushVertex] 0 ByteString.empty
          unaligned ← pushConstants recorder [PushVertex] 2 (bytes 4)
          ok (bindPipeline recorder both)
          partialStages ← pushConstants recorder [PushVertex] 0 (bytes 16)
          allStages ← pushConstants recorder [PushVertex, PushFragment] 0 (bytes 16)
          pure [unbound, pushed, fragment, beyond, before, noStage, empty, unaligned, partialStages, allStages]
      answers
        `shouldBe` [ Left (RefusedIllegal "a push with no pipeline bound")
                   , Right ()
                   , Right ()
                   , Left (RefusedOutOfBounds 24 16)
                   , Left (RefusedOutOfBounds 20 32)
                   , Left (RefusedIllegal "a push for no stage")
                   , Left (RefusedIllegal "a push of no bytes")
                   , Left (RefusedIllegal "a push whose offset or size is not a multiple of four")
                   , Left (RefusedIllegal "a push that leaves out a stage of a range its bytes overlap")
                   , Right ()
                   ]
      commands ← commandsOf' rig
      [(stages, offset, ByteString.length pushed) | CommandPushConstants _ stages offset pushed ← commands]
        `shouldBe` [([PushVertex], 0, 16), ([PushFragment], 16, 16), ([PushVertex, PushFragment], 0, 16)]
      clean rig

    it "checks pushes, binds and draws against the pipeline bound now, and keeps a binding bound across a switch" $ do
      rig ← newRig
      kit ← newKit rig
      ringed rig 256
      bare ← createPipelineLayoutWith (rigRecording rig) [PushConstantRange [PushFragment] 0 4] >>= either (fail . show) pure
      plain ← createPipeline (rigRecording rig) bare shaders (formatCode Rgba8Srgb) >>= either (fail . show) pure
      answers ← framelessOnce rig $ \recorder → do
        vertices ← claimed recorder 64
        instances ← claimed recorder 16
        inPass kit recorder $ do
          ok (bindVertexBuffer recorder 0 (FromClaim vertices 0))
          ok (bindVertexBuffer recorder 1 (FromClaim instances 0))
          ok (pushConstants recorder [PushVertex] 0 (bytes 16))
          ok (bindPipeline recorder plain)
          vertexPush ← pushConstants recorder [PushVertex] 0 (bytes 16)
          fragmentPush ← pushConstants recorder [PushFragment] 0 (bytes 4)
          undeclared ← bindVertexBuffer recorder 1 (FromClaim instances 0)
          plainDraw ← draw recorder 3 1
          ok (bindPipeline recorder (kitPipeline kit))
          -- Both bindings stayed bound through the switch.
          quadDraw ← draw recorder 6 2
          pure [vertexPush, fragmentPush, undeclared, plainDraw, quadDraw]
      answers
        `shouldBe` [ Left (RefusedIllegal "a push to the PushVertex stage, for which the bound pipeline's layout declares no range")
                   , Right ()
                   , Left (RefusedIllegal "vertex binding 1, which the bound pipeline does not declare")
                   , Right ()
                   , Right ()
                   ]
      clean rig

  describe "vertex input" $ do
    it "validates a pipeline's vertex input against the device and Vulkan's rules before any native call" $ do
      rig ← newRig
      layout ← createPipelineLayout (rigRecording rig) >>= either (fail . show) pure
      let made input = fmap (const ()) <$> createPipelineWith (rigRecording rig) layout shaders (formatCode Rgba8Srgb) input
          binding number stride = VertexBinding number stride PerVertex
          attribute location number format offset = VertexAttribute location number format offset
      before ← pipelineCalls rig
      answers ←
        mapM
          made
          [ VertexInput [binding 0 8, binding 0 8] []
          , VertexInput [binding 0 16] [attribute 0 0 VertexFloat2 0, attribute 0 0 VertexFloat2 8]
          , VertexInput [binding 0 8] [attribute 0 1 VertexFloat2 0]
          , VertexInput [binding 0 0] []
          , VertexInput [binding 0 6] []
          , VertexInput [binding 0 4096] []
          , VertexInput [binding 16 8] []
          , VertexInput [binding 0 8] [attribute 16 0 VertexFloat2 0]
          , VertexInput [binding 0 8] [attribute 0 0 VertexFloat 2]
          , VertexInput [binding 0 8] [attribute 0 0 VertexFloat2 4]
          , VertexInput [binding 0 2048] [attribute 0 0 VertexFloat 2048]
          ]
      answers
        `shouldBe` [ Left (RefusedIllegal "a vertex binding declared twice")
                   , Left (RefusedIllegal "a vertex attribute location declared twice")
                   , Left (RefusedIllegal "a vertex attribute reading a binding the pipeline does not declare")
                   , Left (RefusedIllegal "a vertex binding whose stride is not a positive multiple of four")
                   , Left (RefusedIllegal "a vertex binding whose stride is not a positive multiple of four")
                   , Left (RefusedOutOfBounds 4096 2048)
                   , Left (RefusedOutOfBounds 16 16)
                   , Left (RefusedOutOfBounds 16 16)
                   , Left (RefusedIllegal "a vertex attribute whose offset is not a multiple of four")
                   , Left (RefusedIllegal "a vertex attribute that does not fit its binding's stride")
                   , Left (RefusedOutOfBounds 2048 2047)
                   ]
      limitRecording (rigRecordingStandIn rig) standInRecordingLimits {limitVertexBindings = 1}
      tooMany ← made (VertexInput [binding 0 8, binding 1 8] [])
      tooMany `shouldBe` Left (RefusedOutOfBounds 2 1)
      pipelineCalls rig `shouldReturn` before
      limitRecording (rigRecordingStandIn rig) standInRecordingLimits
      _ ← made quadInput >>= either (fail . show) pure
      calls ← recordingCalls (rigRecordingStandIn rig)
      [input | DeclaredInput _ input ← calls] `shouldBe` [quadInput]
      clean rig

  describe "the shared ring" $ do
    it "validates its size once, never clamping, makes one per session, and refuses claims while there is none" $ do
      rig ← newRig
      map (fmap ringSizeBytes) [validateRingSize 0, validateRingSize (-4), validateRingSize (2 ^ (64 ∷ Int))]
        `shouldBe` [Left (RingSizeNotPositive 0), Left (RingSizeNotPositive (-4)), Left (RingSizeUnrepresentable (2 ^ (64 ∷ Int)))]
      noRing ← framelessOnce rig (\recorder → fmap (const ()) <$> claimRegion recorder 16 4)
      noRing `shouldBe` Left (RefusedIllegal "a claim in a session with no ring")
      limitBuffers (rigRecordingStandIn rig) 128
      createRing (rigRecording rig) (size 256) `shouldReturn` Left (RefusedOutOfBounds 256 128)
      atomically (readRing (rigRecording rig)) `shouldReturn` Nothing
      limitBuffers (rigRecordingStandIn rig) (1024 * 1024)
      ok (createRing (rigRecording rig) (size 256))
      createRing (rigRecording rig) (size 256) `shouldReturn` Left (RefusedMisuse (DuplicateSubject ResourceIdentity))
      fmap ringViewBytes <$> atomically (readRing (rigRecording rig)) `shouldReturn` Just 256
      clean rig

    it "reclaims a region only when its batch completes or is discarded, wrapping round, and answers a full ring as backpressure" $ do
      rig ← newRig
      ringed rig 256
      withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope (\recorder → claimed recorder 96) >>= either (fail . show) pure
        _ ← recordFramelessIn scope (\recorder → claimed recorder 96) >>= either (fail . show) pure
        pure ()
      offsets rig `shouldReturn` [0, 96]
      -- Neither has completed: nothing fits after the second, nor before the
      -- first.
      full ← framelessOnce rig (\recorder → fmap (const ()) <$> claimRegion recorder 96 4)
      full `shouldBe` Left (RefusedBackpressure RingBudget)
      oversized ← framelessOnce rig (\recorder → fmap (const ()) <$> claimRegion recorder 257 4)
      oversized `shouldBe` Left (RefusedOutOfBounds 257 256)
      -- Only the first batch completes. The ring wraps round into its region,
      -- and the second's is still held.
      fences ← map (framelessFence . viewFramelessSync) <$> atomically (readFramelessSlots (rigFrames rig))
      case fences of
        first : _ → completeFence (rigStandIn rig) first
        [] → expectationFailure "no frame-less slot"
      _ ← progress rig
      wrapped ← framelessOnce rig (\recorder → fmap (const ()) <$> claimRegion recorder 96 4)
      wrapped `shouldBe` Right ()
      offsets rig `shouldReturn` [96, 0]
      -- A batch its action abandons is discarded, and its region with it.
      _ ← try @ErrorCall $ withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope (\recorder → claimed recorder 32)
        throwIO (ErrorCall "the action failed")
      offsets rig `shouldReturn` [96, 0]
      settleAll rig
      clean rig

    it "keeps every region of a batch whose invalidation raised" $ do
      rig ← newRig
      ringed rig 256
      frame ← owned rig
      (batch, ()) ← recordFrame (rigRecording rig) (ownedFrame frame) (\recorder → () <$ claimed recorder 32) >>= either (fail . show) pure
      offsets rig `shouldReturn` [0]
      failAt (rigRecordingStandIn rig) AtResetStorage
      _ ← try @BatchInvalidationFailed (discardBatch (rigRecording rig) batch)
      offsets rig `shouldReturn` [0]

    it "pads claims to the atom on non-coherent memory and flushes each write without leaving its claim" $ do
      rig ← newRig
      allowTypes (standAllocator (rigRootsStandIn rig)) (2 ^ deviceLocalType + 2 ^ nonCoherentType)
      ringed rig 512
      fmap ringViewAtom <$> atomically (readRing (rigRecording rig)) `shouldReturn` Just 64
      framelessOnce rig (\recorder → do
        _ ← claimed recorder 10
        second ← claimed recorder 10
        writeClaim recorder second 4 (bytes 4)) >>= either (fail . show) pure
      atomically (readRing (rigRecording rig)) >>= \case
        Just ring → [(claimRecordOffset record, claimRecordSpan record, claimRecordSize record) | (_, record) ← ringViewClaims ring] `shouldBe` [(0, 64, 10), (64, 64, 10)]
        Nothing → expectationFailure "the ring was not made"
      flushes ← (\calls → [range | Flushed _ range ← calls]) <$> allocatorCalls (standAllocator (rigRootsStandIn rig))
      flushes `shouldBe` [(64, 64)]
      calls ← recordingCalls (rigRecordingStandIn rig)
      [(offset, count) | WroteMapped offset count ← calls] `shouldBe` [(68, 4)]
      settleAll rig
      clean rig

    it "keeps claims distinct across reuse and refuses another batch's, a reclaimed one, a write past it and one after recording" $ do
      rig ← newRig
      kit ← newKit rig
      ringed rig 256
      kept ← newIORef Nothing
      recorderKept ← newIORef Nothing
      (earlier, laterAnswers) ← withFramelessScope (rigFrames rig) $ \scope → do
        first ← recordFramelessIn scope (\recorder → do
          claim ← claimed recorder 256
          writeIORef kept (Just claim)
          writeIORef recorderKept (Just recorder)
          writeClaim recorder claim 252 (bytes 8)) >>= either (fail . show) (pure . snd)
        other ← recordFramelessIn scope (\recorder → do
          claim ← readIORef kept >>= maybe (fail "no claim") pure
          sequence [writeClaim recorder claim 0 (bytes 4), bindVertexBuffer recorder 0 (FromClaim claim 0)]) >>= either (fail . show) (pure . snd)
        pure (first, other)
      earlier `shouldBe` Left (RefusedOutOfBounds 260 256)
      laterAnswers `shouldBe` [Left (RefusedMisuse (WrongParent BatchIdentity)), Left (RefusedMisuse (WrongParent BatchIdentity))]
      -- Writing after the batch was recorded.
      stale ← readIORef recorderKept >>= maybe (fail "no recorder") pure
      claim ← readIORef kept >>= maybe (fail "no claim") pure
      writeClaim stale claim 0 (bytes 4) `shouldReturn` Left RefusedRecorderClosed
      -- Its batch completes; the next claim needs the whole ring, so the
      -- region is reclaimed and handed to it, at the same offset.
      settleAll rig
      reused ← framelessOnce rig $ \recorder → do
        _ ← claimed recorder 256
        sequence [writeClaim recorder claim 0 (bytes 4), inPass kit recorder (bindVertexBuffer recorder 0 (FromClaim claim 0))]
      reused `shouldBe` [Left (RefusedMisuse (StaleIdentity ResourceIdentity)), Left (RefusedMisuse (StaleIdentity ResourceIdentity))]
      settleAll rig
      clean rig

    it "enters the ring with a batch's first claim, which is refused inside rendering, and binds a later claim there" $ do
      rig ← newRig
      kit ← newKit rig
      ringed rig 256
      first ← framelessOnce rig $ \recorder → inPass kit recorder (fmap (const ()) <$> claimRegion recorder 16 4)
      first `shouldBe` Left (RefusedIllegal "the batch's first ring claim inside rendering, where its entry barrier cannot be recorded")
      later ← framelessOnce rig $ \recorder → do
        _ ← claimed recorder 16
        inPass kit recorder $ do
          inside ← claimed recorder 64
          bindVertexBuffer recorder 0 (FromClaim inside 0)
      later `shouldBe` Right ()
      settleAll rig
      clean rig

  describe "binding and drawing" $ do
    it "binds vertex, instance and 16-bit index data from claimed regions and draws indexed and instanced, retaining the ring" $ do
      rig ← newRig
      kit ← newKit rig
      ringed rig 256
      before ← length <$> commandsOf' rig
      framelessOnce rig (\recorder → do
        vertices ← claimed recorder 32
        indices ← claimed recorder 12
        instances ← claimed recorder 16
        ok (writeClaim recorder vertices 0 (bytes 32))
        ok (writeClaim recorder indices 0 (indices16 [0, 1, 2, 2, 3, 0]))
        ok (writeClaim recorder instances 0 (bytes 16))
        inPass kit recorder $ do
          ok (bindVertexBuffer recorder 0 (FromClaim vertices 0))
          ok (bindVertexBuffer recorder 1 (FromClaim instances 0))
          ok (bindIndexBuffer recorder (FromClaim indices 0) Index16)
          ok (pushConstants recorder [PushFragment] 16 (bytes 16))
          drawIndexed recorder 6 2) >>= either (fail . show) pure
      commands ← drop before <$> commandsOf' rig
      ring ← atomically (readRing (rigRecording rig)) >>= maybe (fail "no ring") pure
      handle ← ringHandle rig (ringViewResource ring)
      [(binding, offset) | CommandBindVertexBuffer binding buffer offset ← commands, buffer == handle] `shouldBe` [(0, 0), (1, 44)]
      [(offset, indexed) | CommandBindIndexBuffer buffer offset indexed ← commands, buffer == handle] `shouldBe` [(32, Index16)]
      [() | CommandDrawIndexed 6 2 ← commands] `shouldBe` [()]
      -- The ring's entry barrier at the first claim, and its exit barrier at
      -- the seal.
      length [() | CommandResourceBarrier (BarrierBuffer buffer) _ _ ← commands, buffer == handle] `shouldBe` 2
      settleAll rig
      clean rig

    it "binds a managed vertex buffer moved to its use before the pass and 32-bit indices from a region, checks how far each read reaches, and freezes the indices read" $ do
      rig ← newRig
      kit ← newKit rig
      ringed rig 256
      vertexBuffer ← createBuffer (rigRecording rig) (BufferDescription VertexBuffer 32) >>= either (fail . show) pure
      indexBuffer ← createBuffer (rigRecording rig) (BufferDescription IndexBuffer 24) >>= either (fail . show) pure
      answers ← framelessOnce rig $ \recorder → do
        instances ← claimed recorder 16
        indices ← claimed recorder 24
        ok (writeClaim recorder indices 0 (indices32 [0, 1, 2, 2, 3, 0]))
        ok (transitionResource recorder vertexBuffer (FromUse GeometryRead) GeometryRead)
        ok (transitionResource recorder indexBuffer (FromUse GeometryRead) GeometryRead)
        drawn ← inPass kit recorder $ do
          ok (bindVertexBuffer recorder 0 (FromBuffer vertexBuffer 0))
          ok (bindVertexBuffer recorder 1 (FromClaim instances 0))
          ok (bindIndexBuffer recorder (FromClaim indices 0) Index32)
          drawn ←
            sequence
              [ drawIndexed recorder 6 2
              , drawIndexed recorder 9 2
              , drawIndexed recorder 6 3
              , draw recorder 6 1
              , draw recorder 3 2
              ]
          -- Index data the recording cannot read cannot bound per-vertex reads.
          ok (bindIndexBuffer recorder (FromBuffer indexBuffer 0) Index32)
          unreadable ← drawIndexed recorder 6 1
          pure (drawn <> [unreadable])
        -- The indices the first draw read can no longer be changed.
        rewritten ← writeClaim recorder indices 0 (indices32 [5])
        pure (drawn <> [rewritten])
      answers
        `shouldBe` [ Right ()
                   , Left (RefusedOutOfBounds 36 24)
                   , Left (RefusedOutOfBounds 24 16)
                   , Left (RefusedOutOfBounds 48 32)
                   , Right ()
                   , Left (RefusedUnsupported "an indexed draw reading per-vertex data through index data the recording cannot read")
                   , Left (RefusedIllegal "a write into index data a recorded draw has read")
                   ]
      settleAll rig
      clean rig

    it "refuses an indexed draw whose 16-bit or 32-bit indices name a vertex beyond the region bound, recording no draw" $ do
      rig ← newRig
      kit ← newKit rig
      ringed rig 256
      before ← length <$> commandsOf' rig
      answers ← framelessOnce rig $ \recorder → do
        vertices ← claimed recorder 16
        instances ← claimed recorder 16
        short ← claimed recorder 6
        long ← claimed recorder 12
        ok (writeClaim recorder short 0 (indices16 [0, 1, 2]))
        ok (writeClaim recorder long 0 (indices32 [1, 0, 7]))
        inPass kit recorder $ do
          ok (bindVertexBuffer recorder 0 (FromClaim vertices 0))
          ok (bindVertexBuffer recorder 1 (FromClaim instances 0))
          ok (bindIndexBuffer recorder (FromClaim short 0) Index16)
          sixteen ← drawIndexed recorder 3 1
          ok (bindIndexBuffer recorder (FromClaim long 0) Index32)
          thirtyTwo ← drawIndexed recorder 3 1
          pure [sixteen, thirtyTwo]
      answers `shouldBe` [Left (RefusedOutOfBounds 24 16), Left (RefusedOutOfBounds 64 16)]
      commands ← drop before <$> commandsOf' rig
      [() | CommandDrawIndexed {} ← commands] `shouldBe` []
      settleAll rig
      clean rig

    it "refuses a vertex source its attributes cannot be read from, at its bind and at a draw after a pipeline switch, recording no draw" $ do
      rig ← newRig
      kit ← newKit rig
      ringed rig 256
      bytesLayout ← createPipelineLayout (rigRecording rig) >>= either (fail . show) pure
      byteWise ←
        createPipelineWith (rigRecording rig) bytesLayout shaders (formatCode Rgba8Srgb) (VertexInput [VertexBinding 0 4 PerVertex] [VertexAttribute 0 0 VertexRgba8Unorm 0])
          >>= either (fail . show) pure
      before ← length <$> commandsOf' rig
      answers ← framelessOnce rig $ \recorder → do
        vertices ← claimed recorder 64
        instances ← claimed recorder 16
        inPass kit recorder $ do
          misaligned ← bindVertexBuffer recorder 0 (FromClaim vertices 1)
          ok (bindVertexBuffer recorder 1 (FromClaim instances 0))
          -- Bytes are read a byte at a time: offset one suits this pipeline.
          ok (bindPipeline recorder byteWise)
          ok (bindVertexBuffer recorder 0 (FromClaim vertices 1))
          ok (bindPipeline recorder (kitPipeline kit))
          switched ← draw recorder 3 1
          pure [misaligned, switched]
      answers
        `shouldBe` replicate 2 (Left (RefusedIllegal "vertex data for binding 0 at an offset its attributes cannot be read from"))
      commands ← drop before <$> commandsOf' rig
      [() | CommandDraw {} ← commands] `shouldBe` []
      settleAll rig
      clean rig

    it "refuses a draw through a buffer released since its bind, or moved out of the use it was bound in, recording no draw" $ do
      rig ← newRig
      kit ← newKit rig
      ringed rig 256
      released ← createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64) >>= either (fail . show) pure
      moved ← createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64) >>= either (fail . show) pure
      before ← length <$> commandsOf' rig
      answers ← framelessOnce rig $ \recorder → do
        instances ← claimed recorder 16
        ok (transitionResource recorder released (FromUse GeometryRead) GeometryRead)
        ok (transitionResource recorder moved (FromUse GeometryRead) GeometryRead)
        afterRelease ← inPass kit recorder $ do
          ok (bindVertexBuffer recorder 0 (FromBuffer released 0))
          ok (bindVertexBuffer recorder 1 (FromClaim instances 0))
          ok (releaseManaged (rigRecording rig) released)
          draw recorder 3 1
        inPass kit recorder (ok (bindVertexBuffer recorder 0 (FromBuffer moved 0)))
        ok (transitionResource recorder moved (FromUse GeometryRead) TransferWrite)
        afterMove ← inPass kit recorder (draw recorder 3 1)
        ok (transitionResource recorder moved (FromUse TransferWrite) GeometryRead)
        pure [afterRelease, afterMove]
      answers
        `shouldBe` [ Left (RefusedMisuse (WrongPhase ResourceIdentity))
                   , Left (RefusedIllegal "a draw reading a buffer that is TransferWrite, not GeometryRead")
                   ]
      commands ← drop before <$> commandsOf' rig
      [() | CommandDraw {} ← commands] `shouldBe` []
      settleAll rig
      clean rig

    it "reads no index before the owner's thread and an open recorder are checked" $ do
      rig ← newRig
      kit ← newKit rig
      ringed rig 256
      kept ← newIORef Nothing
      offThread ← newEmptyMVar
      before ← readsOf rig
      framelessOnce rig $ \recorder → do
        vertices ← claimed recorder 32
        instances ← claimed recorder 16
        indices ← claimed recorder 12
        ok (writeClaim recorder indices 0 (indices16 [0, 1, 2, 2, 3, 0]))
        writeIORef kept (Just recorder)
        inPass kit recorder $ do
          ok (bindVertexBuffer recorder 0 (FromClaim vertices 0))
          ok (bindVertexBuffer recorder 1 (FromClaim instances 0))
          ok (bindIndexBuffer recorder (FromClaim indices 0) Index16)
          _ ← forkIO (drawIndexed recorder 6 1 >>= putMVar offThread)
          takeMVar offThread `shouldReturn` Left RefusedNotOwner
      stale ← readIORef kept >>= maybe (fail "no recorder") pure
      drawIndexed stale 6 1 `shouldReturn` Left RefusedRecorderClosed
      readsOf rig `shouldReturn` before
      settleAll rig
      clean rig

    it "checks only what the draw reads: no index data for a draw that is not indexed, and no binding the pipeline bound now does not declare" $ do
      rig ← newRig
      kit ← newKit rig
      ringed rig 256
      noInput ← createPipelineLayoutWith (rigRecording rig) pushRanges >>= either (fail . show) pure
      plain ← createPipeline (rigRecording rig) noInput shaders (formatCode Rgba8Srgb) >>= either (fail . show) pure
      indexBuffer ← createBuffer (rigRecording rig) (BufferDescription IndexBuffer 24) >>= either (fail . show) pure
      vertexBuffer ← createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64) >>= either (fail . show) pure
      answers ← framelessOnce rig $ \recorder → do
        instances ← claimed recorder 16
        ok (transitionResource recorder indexBuffer (FromUse GeometryRead) GeometryRead)
        ok (transitionResource recorder vertexBuffer (FromUse GeometryRead) GeometryRead)
        inPass kit recorder $ do
          ok (bindVertexBuffer recorder 0 (FromBuffer vertexBuffer 0))
          ok (bindVertexBuffer recorder 1 (FromClaim instances 0))
          ok (bindIndexBuffer recorder (FromBuffer indexBuffer 0) Index32)
        -- The index buffer moves elsewhere; a draw that is not indexed reads
        -- none of it.
        ok (transitionResource recorder indexBuffer (FromUse GeometryRead) TransferWrite)
        notIndexed ← inPass kit recorder (draw recorder 3 1)
        ok (transitionResource recorder indexBuffer (FromUse TransferWrite) GeometryRead)
        -- The vertex buffer is released; a pipeline with no vertex input
        -- reads none of it.
        ok (releaseManaged (rigRecording rig) vertexBuffer)
        noVertices ← inPass kit recorder (ok (bindPipeline recorder plain) >> draw recorder 3 1)
        pure [notIndexed, noVertices]
      answers `shouldBe` [Right (), Right ()]
      settleAll rig
      clean rig

    it "keeps a partial or cancelled batch's regions, closing its writes, until its discard releases them" $ do
      rig ← newRig
      ringed rig 256
      kept ← newIORef Nothing
      let raising ∷ IO () → Rec → IO ()
          raising failure recorder = do
            claim ← claimed recorder 32
            writeIORef kept (Just (recorder, claim))
            failure
      frame ← owned rig
      raised ← try @ErrorCall (recordFrame (rigRecording rig) (ownedFrame frame) (raising (throwIO (ErrorCall "the consumer failed"))))
      fmap (const ()) raised `shouldBe` Left (ErrorCall "the consumer failed")
      offsets rig `shouldReturn` [0]
      (recorder, claim) ← readIORef kept >>= maybe (fail "no claim") pure
      writeClaim recorder claim 0 (bytes 4) `shouldReturn` Left RefusedRecorderClosed
      partialBatches ← filter (partialStanding . viewBatchStanding) <$> atomically (readBatches (rigRecording rig))
      mapM_ (ok . discardBatch (rigRecording rig) . viewBatch) partialBatches
      offsets rig `shouldReturn` []
      -- A cancellation leaves the batch partial the same way.
      cancelledFrame ← owned rig
      killed ← try @AsyncException (recordFrame (rigRecording rig) (ownedFrame cancelledFrame) (raising (throwIO ThreadKilled)))
      fmap (const ()) killed `shouldBe` Left ThreadKilled
      offsets rig `shouldReturn` [32]
      partialAgain ← filter (partialStanding . viewBatchStanding) <$> atomically (readBatches (rigRecording rig))
      mapM_ (ok . discardBatch (rigRecording rig) . viewBatch) partialAgain
      offsets rig `shouldReturn` []

    it "keeps an accepted batch's regions when a later submission fails with no effect, releasing only the discarded ones, then the rest on completion" $ do
      rig ← newRig
      ringed rig 128
      failSubmission rig 2 AtSubmitNoEffect
      tickets ← withFramelessScope (rigFrames rig) $ \scope →
        mapM (\_ → recordFramelessIn scope (\recorder → () <$ claimed recorder 64) >>= either (fail . show) (pure . fst)) [1 ∷ Int, 2]
      mapM (atomically . readTicket) tickets `shouldReturn` [TicketPending, TicketDiscarded]
      offsets rig `shouldReturn` [0]
      clearFrameStep (rigStandIn rig) AtSubmitNoEffect
      completeAll (rigStandIn rig)
      _ ← progress rig
      -- The whole ring is free once the accepted batch has completed.
      framelessOnce rig (\recorder → () <$ claimed recorder 128)
      settleAll rig
      clean rig

    it "keeps every region of batches whose submission's effect is unknown" $ do
      rig ← newRig
      ringed rig 128
      failSubmission rig 2 AtSubmit
      outcome ← try @FramelessEffectUncertain $ withFramelessScope (rigFrames rig) $ \scope →
        mapM_ (\_ → recordFramelessIn scope (\recorder → () <$ claimed recorder 64) >>= either (fail . show) (pure . fst)) [1 ∷ Int, 2]
      fmap (const ()) outcome `shouldSatisfy` either (const True) (const False)
      offsets rig `shouldReturn` [0, 64]

    it "retains exactly what each bind references, and a rebinding releases nothing an earlier bind captured" $ do
      rig ← newRig
      ringed rig 256
      layout ← createPipelineLayoutWith (rigRecording rig) pushRanges >>= either (fail . show) pure
      framed ← createPipelineWith (rigRecording rig) layout shaders formatB8G8R8A8Srgb quadInput >>= either (fail . show) pure
      first ← createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64) >>= either (fail . show) pure
      second ← createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64) >>= either (fail . show) pure
      unrelated ← createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64) >>= either (fail . show) pure
      frame ← owned rig
      -- Outside rendering, against the frame's image: each bind is its
      -- buffer's first touch, so each retains it.
      (batch, ()) ← recordFrame (rigRecording rig) (ownedFrame frame) (\recorder → do
        ok (bindPipeline recorder framed)
        before ← mapM (recordedBy rig) [managedResource first, managedResource second]
        ok (bindVertexBuffer recorder 0 (FromBuffer first 0))
        ok (bindVertexBuffer recorder 0 (FromBuffer second 0))
        before `shouldBe` [False, False]) >>= either (fail . show) pure
      ring ← atomically (readRing (rigRecording rig)) >>= maybe (fail "no ring") pure
      mapM (recordedBy rig) [managedResource first, managedResource second, managedResource unrelated, ringViewResource ring]
        `shouldReturn` [True, True, False, False]
      ok (discardBatch (rigRecording rig) batch)
      mapM (recordedBy rig) [managedResource first, managedResource second] `shouldReturn` [False, False]
      clean rig

    it "refuses each checked use of a bind, a push or a draw with no native call" $ do
      rig ← newRig
      kit ← newKit rig
      ringed rig 256
      indexBuffer ← createBuffer (rigRecording rig) (BufferDescription IndexBuffer 24) >>= either (fail . show) pure
      lookupBuffer ← createBuffer (rigRecording rig) (BufferDescription LookupBuffer 24) >>= either (fail . show) pure
      vertexBuffer ← createBuffer (rigRecording rig) (BufferDescription VertexBuffer 24) >>= either (fail . show) pure
      released ← createBuffer (rigRecording rig) (BufferDescription VertexBuffer 24) >>= either (fail . show) pure
      ok (releaseManaged (rigRecording rig) released)
      answers ← framelessOnce rig $ \recorder → do
        claim ← claimed recorder 32
        noPipeline ← bindVertexBuffer recorder 0 (FromClaim claim 0)
        refused ← inPass kit recorder $ do
          afterPass ← length <$> commandsOf' rig
          answers ←
            sequence
              [ bindVertexBuffer recorder 0 (FromBuffer indexBuffer 0)
              , bindIndexBuffer recorder (FromBuffer lookupBuffer 0) Index16
              , bindVertexBuffer recorder 0 (FromBuffer released 0)
              , bindVertexBuffer recorder 0 (FromClaim claim 32)
              , bindVertexBuffer recorder 0 (FromBuffer vertexBuffer 24)
              , bindVertexBuffer recorder 2 (FromClaim claim 0)
              , bindIndexBuffer recorder (FromClaim claim 2) Index32
              , bindVertexBuffer recorder 0 (FromBuffer vertexBuffer 0)
              , drawIndexed recorder 3 1
              ]
          ok (bindVertexBuffer recorder 0 (FromClaim claim 0))
          unboundInstance ← draw recorder 3 1
          afterRefusals ← length <$> commandsOf' rig
          pure (answers <> [unboundInstance], afterRefusals - afterPass)
        pure (noPipeline, refused)
      case answers of
        (noPipeline, (refused, recordedInside)) → do
          noPipeline `shouldBe` Left (RefusedIllegal "a buffer bound with no pipeline bound")
          refused
            `shouldBe` [ Left RefusedWrongKind
                       , Left RefusedWrongKind
                       , Left (RefusedMisuse (WrongPhase ResourceIdentity))
                       , Left (RefusedOutOfBounds 32 32)
                       , Left (RefusedOutOfBounds 24 24)
                       , Left (RefusedIllegal "vertex binding 2, which the bound pipeline does not declare")
                       , Left (RefusedIllegal "index data at an offset that is not a multiple of the index's size")
                       , Left (RefusedIllegal "the batch's first use of a buffer inside rendering, where its entry barrier cannot be recorded")
                       , Left (RefusedIllegal "an indexed draw with no index data bound")
                       , Left (RefusedIllegal "a draw that needs vertex binding 1, which is not bound")
                       ]
          -- The one bind that was admitted inside the pass is all it recorded.
          recordedInside `shouldBe` 1
      settleAll rig
      clean rig
  where
    size bytes' = either (error . show) id (validateRingSize bytes')

-- | A color target of 32 by 16, a layout declaring 'pushRanges', and a
-- pipeline over it reading 'quadInput'.
data Kit = Kit
  { kitTarget ∷ !Image
  , kitPipeline ∷ !Pipeline
  }

newKit ∷ Rig → IO Kit
newKit rig = do
  target ← createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Srgb 32 16 1) >>= either (fail . show) pure
  layout ← createPipelineLayoutWith (rigRecording rig) pushRanges >>= either (fail . show) pure
  pipeline ← createPipelineWith (rigRecording rig) layout shaders (formatCode Rgba8Srgb) quadInput >>= either (fail . show) pure
  pure (Kit target pipeline)

-- | A vertex range and a fragment range, side by side.
pushRanges ∷ [PushConstantRange]
pushRanges = [PushConstantRange [PushVertex] 0 16, PushConstantRange [PushFragment] 16 16]

-- | A two-float position per vertex from binding 0, and a two-float offset
-- per instance from binding 1.
quadInput ∷ VertexInput
quadInput =
  VertexInput
    [VertexBinding 0 8 PerVertex, VertexBinding 1 8 PerInstance]
    [VertexAttribute 0 0 VertexFloat2 0, VertexAttribute 1 1 VertexFloat2 0]

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

-- | Make the session's ring of this many bytes.
ringed ∷ Rig → Integer → IO ()
ringed rig bytes' = ok (createRing (rigRecording rig) (either (error . show) id (validateRingSize bytes')))

-- | A claim of this many bytes, four-aligned, that must succeed.
claimed ∷ Rec → Natural → IO RingClaim
claimed recorder bytes' = claimRegion recorder bytes' 4 >>= either (fail . ("the claim was refused: " <>) . show) pure

-- | Where every region of the ring a batch holds starts, in claim order.
offsets ∷ Rig → IO [Natural]
offsets rig =
  atomically (readRing (rigRecording rig)) >>= \case
    Just ring → pure [claimRecordOffset record | (_, record) ← ringViewClaims ring]
    Nothing → fail "the ring was not made"

-- | The ring buffer's native handle.
ringHandle ∷ Rig → ResourceId → IO Word64
ringHandle rig resource = do
  views ← atomically (readManaged (rigRecording rig))
  case [handles | ManagedView viewed _ _ handles ← views, viewed == resource] of
    [buffer : _] → pure buffer
    other → fail ("the ring's handles were " <> show other)

-- | Whether a batch recorded a reference to the resource the model still owes.
recordedBy ∷ Rig → ResourceId → IO Bool
recordedBy rig resource = atomically $ do
  model ← stateRootsModel (rigRoots rig) (\current → (current, current))
  pure (maybe False ((RecordedReferenceOwed `elem`) . viewOutstanding) (holdView (ResourceSubject resource) model))

-- | Little-endian 16-bit and 32-bit indices.
indices16, indices32 ∷ [Integer] → ByteString.ByteString
indices16 = ByteString.pack . concatMap (\index → [fromIntegral index, fromIntegral (index `div` 256)])
indices32 = ByteString.pack . concatMap (\index → [fromIntegral (index `div` 256 ^ place) | place ← [0 ∷ Int .. 3]])

-- | Fail the nth frame-less submission with this step.
failSubmission ∷ Rig → Int → FrameStep → IO ()
failSubmission rig nth step' = do
  seen ← newIORef (0 ∷ Int)
  duringFrameCall (rigStandIn rig) $ \case
    Submitted {} → do
      count ← atomicModifyIORef' seen (\held → (held + 1, held + 1))
      when (count == nth) (failFrameStep (rigStandIn rig) step')
    _ → pure ()

bytes ∷ Int → ByteString.ByteString
bytes count = ByteString.replicate count 0x5A

shaders ∷ PipelineShaders
shaders = PipelineShaders (ByteString.pack [1, 2, 3, 4]) (ByteString.pack [5, 6, 7, 8])

commandsOf' ∷ Rig → IO [NativeCommand]
commandsOf' rig = (\calls → [command | Recorded _ command ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

-- | How many reads of mapped memory the recording made.
readsOf ∷ Rig → IO Int
readsOf rig = (\calls → length [() | ReadMapped {} ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

layoutCalls, pipelineCalls ∷ Rig → IO Int
layoutCalls rig = (\calls → length [() | CreatedLayout _ ← calls]) <$> recordingCalls (rigRecordingStandIn rig)
pipelineCalls rig = (\calls → length [() | CreatedPipeline {} ← calls]) <$> recordingCalls (rigRecordingStandIn rig)
