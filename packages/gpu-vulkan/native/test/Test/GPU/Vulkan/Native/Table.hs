-- | The bindless texture table (GRS-7) over the frames', the recording's and
-- the allocator's stand-in native layers: making it — its samplers, set
-- layouts declared at the cap, pools, sets at the initial size, version ring
-- and placeholder — and every limit it is checked against first; the table's
-- pipeline layouts; binding it and selecting a sampler; every refusal, each
-- making no native call; descriptor writes only into slots no live version
-- maps; versions held through completion and backpressure when none is free;
-- and the record-then-release case, whose batch keeps its version and whose
-- slot is not reused until it completes.
--
-- The shaders' bytes are stand-ins: their descriptions are what is checked.
-- Nothing here creates a Vulkan object.
module Test.GPU.Vulkan.Native.Table (spec) where

import Control.Concurrent.STM (atomically)
import Control.Concurrent (forkIO, killThread, myThreadId)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (..), SomeException, fromException, throwIO, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import Control.Monad (when)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.GPU.Model.Budget (BudgetKind (LookupVersionBudget, TextureSlotBudget))
import Hetoimasia.GPU.Model (SessionFailureCause (CleanupFailed), SessionState (SessionFailed), sessionState)
import Hetoimasia.GPU.Model.Identity (IdentityKind (..), Misuse (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (failRootsSessionBecause, readRootsModel)
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Shader.Interface
  ( DescriptorCount (..)
  , DescriptorDeclaration (..)
  , DescriptorKind (..)
  , InterfaceStage (..)
  , PushMember (..)
  , ShaderInterface (..)
  , interfaceFor
  )
import Hetoimasia.GPU.Vulkan.Native.TextureTable
import Hetoimasia.GPU.Vulkan.Native.Uploads
import Data.Functor ((<&>))
import Test.GPU.Vulkan.Native.AllocatorStandIn (AllocatorCall (Flushed), allocatorCalls, allowTypes, deviceLocalType, nonCoherentType)
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn (completeAll)
import Test.GPU.Vulkan.Native.StandIn (StandIn (standAllocator))
import Test.GPU.Vulkan.Native.RecordingStandIn (RecordingCall (..), RecordingFailure (..), RecordingStep (..), failAt, limitBuffers, limitRecording, onceAt, outOfMemoryAt, recordingCalls, standInRecordingLimits, succeedAt)

type Ups = Uploads () Int Int Text Int Word64

type Rec = Recorder () Int Int Text Int Word64

spec ∷ Spec
spec = describe "Texture table" $ do
  describe "making it" $ do
    it "makes four samplers, set 0's layout over them declared at the cap and set 1's, a pool and a set for each, the version ring with one version per entry, writes set 1 once, and admits the placeholder's upload" $ do
      (rig, uploads) ← uploadRig
      ok (createTextureTable (rigRecording rig) uploads (tableConfig 16 4 2))
      calls ← recordingCalls (rigRecordingStandIn rig)
      let samplers = [handle | CreatedSampler handle _ ← calls]
      [sampler | CreatedSampler _ sampler ← calls] `shouldBe` [NearestClamp, NearestRepeat, LinearClamp, LinearRepeat]
      [request | CreatedSetLayout _ request ← calls] `shouldBe` [TextureSetLayout samplers 16, LookupSetLayout]
      [request | CreatedPool _ request ← calls] `shouldBe` [TexturePool 4 4, LookupPool]
      [count | AllocatedSet _ _ _ count ← calls] `shouldBe` [Just 4, Nothing]
      -- One version is the cap's sixteen entries of eight bytes, padded to
      -- the device's 256-byte storage alignment; the ring holds two. Set 1
      -- and the ring are sized for the cap from the start (GRS-14).
      [(range, 1) | WroteDescriptors [WriteLookupBuffer _ _ range] ← calls] `shouldBe` [(128, 1 ∷ Int)]
      Just view ← atomically (readTable (rigRecording rig))
      tableViewStride view `shouldBe` 256
      Map.size (tableViewVersions view) `shouldBe` 2
      managedCount rig "lookup buffer" `shouldReturn` 1
      managedCount rig "lookup version" `shouldReturn` 2
      -- The placeholder is not written until its upload completes.
      tableViewPlaceholderWritten view `shouldBe` False
      settle rig uploads
      ok (refreshTextureTable (rigRecording rig))
      writtenSlots rig `shouldReturn` [0]
      clean rig

    it "checks the cap, the samplers, a stage's resources, the bindable sets, one version's range and the ring against the device first, making nothing, and makes one table per session" $ do
      (rig, uploads) ← uploadRig
      let limits = standInRecordingLimits {limitImageDimension = 16}
          refusedUnder changed configured = do
            limitRecording (rigRecordingStandIn rig) changed
            answer ← createTextureTable (rigRecording rig) uploads configured
            limitRecording (rigRecordingStandIn rig) limits
            pure answer
      refusedUnder limits {limitTableSampledImages = 15} (tableConfig 16 4 2) `shouldReturn` Left (RefusedOutOfBounds 16 15)
      refusedUnder limits {limitTableSamplers = 3} (tableConfig 16 4 2) `shouldReturn` Left (RefusedOutOfBounds 4 3)
      refusedUnder limits {limitTableResources = 20} (tableConfig 16 4 2) `shouldReturn` Left (RefusedOutOfBounds 21 20)
      -- Set 0's pool holds the four samplers and the four initial images.
      -- Set 0's pools, generation by generation — 4, 8 and 16 images, each
      -- with the four samplers — may all be held at once.
      refusedUnder limits {limitTablePoolDescriptors = 39} (tableConfig 16 4 2) `shouldReturn` Left (RefusedOutOfBounds 40 39)
      refusedUnder limits {limitBoundSets = 1} (tableConfig 16 4 2) `shouldReturn` Left (RefusedOutOfBounds 2 1)
      refusedUnder limits {limitStorageRange = 127} (tableConfig 16 4 2) `shouldReturn` Left (RefusedOutOfBounds 128 127)
      -- 262144 entries of eight bytes are a 2 MiB stride, so the 2049th
      -- version's dynamic offset is 4 GiB, which no 32-bit offset holds, on a
      -- device whose buffers could hold the whole ring.
      limitBuffers (rigRecordingStandIn rig) (8 * 1024 * 1024 * 1024)
      refusedUnder limits (tableConfig 262144 262144 2049) `shouldReturn` Left (RefusedOutOfBounds 4294967296 4294967295)
      calls ← recordingCalls (rigRecordingStandIn rig)
      [() | CreatedSampler {} ← calls] `shouldBe` []
      ok (createTextureTable (rigRecording rig) uploads (tableConfig 16 4 2))
      createTextureTable (rigRecording rig) uploads (tableConfig 16 4 2) `shouldReturn` Left (RefusedMisuse (DuplicateSubject ResourceIdentity))
      clean rig

  describe "pipeline layouts" $ do
    it "declares both of the table's set layouts and the shaders' ranges, admits the table's bindings and no other, and the sampler index only inside a fragment range" $ do
      (rig, _, kit) ← tableRig 4 2
      calls ← recordingCalls (rigRecordingStandIn rig)
      let layouts = [handle | CreatedSetLayout handle _ ← calls]
      [declared | DeclaredSetLayouts _ declared ← calls] `shouldBe` [layouts]
      -- The fragment stage's range is bytes 0 to 12: an index at 12 lies
      -- outside it, and one at 6 is unaligned.
      createTablePipelineLayout (rigRecording rig) tableShaders 12 `shouldReturn'` refused (RefusedIllegal "a sampler index outside every push-constant range the fragment stage sees")
      createTablePipelineLayout (rigRecording rig) tableShaders 6 `shouldReturn'` refused (RefusedIllegal "a sampler index outside every push-constant range the fragment stage sees")
      createTablePipelineLayout (rigRecording rig) (shadersWith [DescriptorDeclaration 2 0 StorageBuffer (DescriptorCount 1)]) 8
        `shouldReturn'` refused (RefusedIncompatible "a shader declaring a descriptor binding the texture table does not hold")
      -- Set 0 is visible to the fragment stage alone; set 1 to both.
      createTablePipelineLayout (rigRecording rig) (vertexDeclaring [DescriptorDeclaration 0 1 SampledImage RuntimeSized]) 8
        `shouldReturn'` refused (RefusedIncompatible "a vertex shader declaring the texture table's samplers or images, which only the fragment stage sees")
      createTablePipelineLayout (rigRecording rig) (vertexDeclaring [DescriptorDeclaration 0 0 Sampler (DescriptorCount 4)]) 8
        `shouldReturn'` refused (RefusedIncompatible "a vertex shader declaring the texture table's samplers or images, which only the fragment stage sees")
      fmap (const ()) <$> createTablePipelineLayout (rigRecording rig) (vertexDeclaring [DescriptorDeclaration 1 0 StorageBuffer (DescriptorCount 1)]) 8 `shouldReturn` Right ()
      -- A layout without the table admits no binding at all.
      createPipelineLayoutFor (rigRecording rig) tableShaders `shouldReturn'` refused (RefusedUnsupported "a shader declaring descriptor bindings, which only a pipeline layout holding the texture table declares")
      calls' ← recordingCalls (rigRecordingStandIn rig)
      -- Only the admitted vertex stage's layout was made.
      length [() | CreatedLayout {} ← calls'] `shouldBe` length [() | CreatedLayout {} ← calls] + 1
      kitTarget kit `seq` clean rig

  describe "binding and drawing" $ do
    it "binds both sets under the pipeline's layout with the batch's version offset, selects a sampler by a push at the declared offset, and draws" $ do
      (rig, _, kit) ← tableRig 4 2
      framelessOnce rig $ \recorder → inPass kit recorder $ do
        ok (bindTable recorder)
        ok (selectSampler recorder 2)
        ok (draw recorder 3 1)
      calls ← recordingCalls (rigRecordingStandIn rig)
      let sets = [set | AllocatedSet set _ _ _ ← calls]
          commands' = [command | Recorded _ command ← calls]
      [(handles, offsets) | CommandBindDescriptorSets _ handles offsets ← commands'] `shouldBe` [(sets, [0])]
      [(stages, offset, bytes) | CommandPushConstants _ stages offset bytes ← commands'] `shouldBe` [([PushFragment], 8, ByteString.pack [2, 0, 0, 0])]
      [() | CommandDraw {} ← commands'] `shouldBe` [()]
      clean rig

    it "refuses, making no native call: binding with no pipeline or under one whose layout does not hold the table, a sampler past the four, a push over the sampler index, and drawing before the table is bound compatibly or a sampler selected" $ do
      (rig, _, kit) ← tableRig 4 2
      answers ← framelessOnce rig $ \recorder → do
        ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 0 1))
        noPipeline ← bindTable recorder
        ok (bindPipeline recorder (kitPlain kit))
        plain ← bindTable recorder
        plainSampler ← selectSampler recorder 0
        ok (bindPipeline recorder (kitPipeline kit))
        ok (setViewport recorder (Viewport 0 0 32 16))
        ok (setScissor recorder (Rect 0 0 32 16))
        before ← commandCount rig
        unbound ← draw recorder 3 1
        ok (bindTable recorder)
        unselected ← draw recorder 3 1
        beyond ← selectSampler recorder 4
        over ← pushConstants recorder [PushFragment] 8 (ByteString.pack [1, 0, 0, 0])
        after ← commandCount rig
        ok (selectSampler recorder 1)
        -- A pipeline whose layout does not hold the table disturbs the
        -- binding; the table's pipeline again needs it bound again.
        ok (bindPipeline recorder (kitPlain kit))
        ok (bindPipeline recorder (kitPipeline kit))
        disturbed ← draw recorder 3 1
        ok (endRendering recorder)
        pure ([noPipeline, plain, plainSampler, unbound, unselected, beyond, over, disturbed], after - before)
      fst answers
        `shouldBe` [ Left (RefusedIllegal "binding the texture table with no pipeline bound")
                   , Left (RefusedIllegal "binding the texture table under a pipeline whose layout does not hold it")
                   , Left (RefusedIllegal "selecting a sampler under a pipeline whose layout does not hold the texture table")
                   , Left (RefusedIllegal "a draw with a pipeline holding the texture table before the table is bound under a compatible layout")
                   , Left (RefusedIllegal "a draw with a pipeline holding the texture table before a sampler is selected")
                   , Left (RefusedOutOfBounds 4 3)
                   , Left (RefusedIllegal "a push over the sampler index, which selectSampler sets")
                   , Left (RefusedIllegal "a draw with a pipeline holding the texture table before the table is bound under a compatible layout")
                   ]
      -- Between those two counts only the one bind reached the native layer.
      snd answers `shouldBe` 1
      clean rig

    it "keeps a batch's version through a later change and a rebind, and refuses a bind before the placeholder's upload completes" $ do
      (rig, uploads) ← uploadRig
      ok (createTextureTable (rigRecording rig) uploads (tableConfig 16 4 2))
      kit ← newKit rig
      early ← framelessOnce rig $ \recorder → inPass kit recorder (bindTable recorder)
      early `shouldBe` Left (RefusedNotWritten "the texture table's placeholder has not finished uploading")
      settle rig uploads
      texture ← uploadedTexture rig uploads
      framelessOnce rig $ \recorder → inPass kit recorder $ do
        ok (bindTable recorder)
        -- A registration changes a mapping, but this batch keeps its version.
        _ ← registered rig texture
        ok (bindTable recorder)
      calls ← recordingCalls (rigRecordingStandIn rig)
      [offset | Recorded _ (CommandBindDescriptorSets _ _ [offset]) ← calls] `shouldBe` [0, 0]
      clean rig

    it "refuses a draw through the table, making no native call, while the batch holds a texture its version maps in another use, and draws once it is back" $ do
      (rig, uploads, kit) ← tableRig 4 2
      texture ← uploadedTexture rig uploads
      _ ← registered rig texture
      answers ← framelessOnce rig $ \recorder → do
        ok (transitionResource recorder texture (FromUse ShaderSampled) TransferRead)
        moved ← inPass kit recorder $ do
          ok (bindTable recorder)
          ok (selectSampler recorder 0)
          draw recorder 3 1
        ok (transitionResource recorder texture (FromUse TransferRead) ShaderSampled)
        back ← inPass kit recorder $ do
          ok (bindTable recorder)
          ok (selectSampler recorder 0)
          draw recorder 3 1
        pure [moved, back]
      answers `shouldBe` [Left (RefusedIllegal "a draw through the texture table while the batch holds an image its version maps in a use other than sampling"), Right ()]
      calls ← recordingCalls (rigRecordingStandIn rig)
      length [() | Recorded _ CommandDraw {} ← calls] `shouldBe` 1
      clean rig

  describe "growth" $ do
    it "grows set 0 when no slot is free — twice, to a cap that is no power of two — copying every written slot into each larger set, which later batches bind; at the cap it is backpressure, and a retired slot is reused" $ do
      (rig, uploads, kit) ← tableRigWith 5 2 2
      t1 ← uploadedTexture rig uploads
      t2 ← uploadedTexture rig uploads
      t3 ← uploadedTexture rig uploads
      t4 ← uploadedTexture rig uploads
      t5 ← uploadedTexture rig uploads
      h1 ← registered rig t1
      set0 ← currentSet rig
      -- A batch binds the first set and is submitted; it has not completed.
      recordDrawing rig kit
      _ ← registered rig t2
      set1 ← currentSet rig
      allocated rig `shouldReturn` 4
      calls ← recordingCalls (rigRecordingStandIn rig)
      [request | CreatedPool _ request ← calls] `shouldBe` [TexturePool 4 2, LookupPool, TexturePool 4 4]
      [count | AllocatedSet _ _ _ count ← calls] `shouldBe` [Just 2, Nothing, Just 4]
      copies rig `shouldReturn` [(set0, set1, [(0, 2)])]
      _ ← registered rig t3
      _ ← registered rig t4
      set2 ← currentSet rig
      allocated rig `shouldReturn` 5
      copies rig `shouldReturn` [(set0, set1, [(0, 2)]), (set1, set2, [(0, 4)])]
      registerTexture (rigRecording rig) t5 `shouldReturn'` refused (RefusedBackpressure TextureSlotBudget)
      -- A later batch binds the largest set; the earlier one bound the first.
      recordDrawing rig kit
      bound ← recordingCalls (rigRecordingStandIn rig)
      [head' sets | Recorded _ (CommandBindDescriptorSets _ sets _) ← bound] `shouldBe` [set0, set2]
      -- The first set's pool is held by the earlier batch until it
      -- completes; the second's, which no batch bound, goes at the next
      -- disposal; the current one stays.
      final' ← recordingCalls (rigRecordingStandIn rig)
      let pools = [handle | CreatedPool handle (TexturePool _ _) ← final']
          (pool0, pool1, pool2) = (head' pools, head' (drop 1 pools), head' (drop 2 pools))
      _ ← disposeResources (rigRecording rig) (at 1)
      destroyedPools rig >>= (`shouldSatisfy` (\destroyed → pool0 `notElem` destroyed && pool1 `elem` destroyed && pool2 `notElem` destroyed))
      completed rig
      _ ← disposeResources (rigRecording rig) (at 2)
      destroyedPools rig >>= (`shouldSatisfy` (\destroyed → pool0 `elem` destroyed && pool1 `elem` destroyed && pool2 `notElem` destroyed))
      -- At the cap, a released texture's slot is reused once retired, with
      -- no further growth.
      ok (releaseTexture (rigRecording rig) h1)
      completed rig
      ok (refreshTextureTable (rigRecording rig))
      _ ← registered rig t5
      allocated rig `shouldReturn` 5
      final ← recordingCalls (rigRecordingStandIn rig)
      length [() | CreatedPool _ (TexturePool _ _) ← final] `shouldBe` 3
      clean rig

    it "pins a batch's set and version at its first bind: a growth between two binds of one batch leaves both binding the old set, and discarding that unsubmitted batch lets the old set go" $ do
      (rig, uploads, kit) ← tableRigWith 4 2 2
      t1 ← uploadedTexture rig uploads
      t2 ← uploadedTexture rig uploads
      _ ← registered rig t1
      set0 ← currentSet rig
      discarded ← try @ErrorCall @() $ withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope $ \recorder → inPass kit recorder $ do
          ok (bindTable recorder)
          _ ← registered rig t2
          ok (bindTable recorder)
        throwIO (ErrorCall "the consumer gave up")
      discarded `shouldBe` Left (ErrorCall "the consumer gave up")
      set1 ← currentSet rig
      set1 `shouldSatisfy` (/= set0)
      calls ← recordingCalls (rigRecordingStandIn rig)
      [(head' sets, offsets) | Recorded _ (CommandBindDescriptorSets _ sets offsets) ← calls] `shouldBe` [(set0, [0]), (set0, [0])]
      let pool0 = head' [handle | CreatedPool handle (TexturePool _ 2) ← calls]
      completed rig
      _ ← disposeResources (rigRecording rig) (at 1)
      destroyedPools rig >>= (`shouldSatisfy` elem pool0)
      clean rig

    it "leaves the current set and the table as they were when the larger pool's creation runs out of memory with nothing to reclaim: no retry, and a later registration grows" $ do
      (rig, uploads, _) ← tableRigWith 4 2 2
      t1 ← uploadedTexture rig uploads
      t2 ← uploadedTexture rig uploads
      _ ← registered rig t1
      set0 ← currentSet rig
      before ← poolAttempts rig
      outOfMemoryAt (rigRecordingStandIn rig) AtCreatePool 1
      raised ← try @AllocationNotRecovered (registerTexture (rigRecording rig) t2)
      fmap (const ()) raised `shouldSatisfy` either (const True) (const False)
      poolAttempts rig `shouldReturn` before + 1
      currentSet rig `shouldReturn` set0
      allocated rig `shouldReturn` 2
      Just view ← atomically (readTable (rigRecording rig))
      Map.size (tableViewMapping view) `shouldBe` 1
      _ ← registered rig t2
      allocated rig `shouldReturn` 4
      clean rig

    it "rolls a growth back when its set's allocation runs out of memory, reclaims the rolled-back pool, and retries the whole growth once; a second failure is not retried" $ do
      (rig, uploads, _) ← tableRigWith 8 2 2
      t1 ← uploadedTexture rig uploads
      t2 ← uploadedTexture rig uploads
      t3 ← uploadedTexture rig uploads
      t4 ← uploadedTexture rig uploads
      _ ← registered rig t1
      before ← poolAttempts rig
      outOfMemoryAt (rigRecordingStandIn rig) AtAllocateSet 1
      _ ← registered rig t2
      allocated rig `shouldReturn` 4
      calls ← recordingCalls (rigRecordingStandIn rig)
      let attempts = drop before [handle | CreatedPool handle (TexturePool _ _) ← calls]
      length attempts `shouldBe` 2
      destroyedPools rig >>= (`shouldSatisfy` elem (head' attempts))
      -- Both allocations of the next growth fail: the retry is the only one.
      _ ← registered rig t3
      set1 ← currentSet rig
      before' ← poolAttempts rig
      outOfMemoryAt (rigRecordingStandIn rig) AtAllocateSet 2
      raised ← try @AllocationNotRecovered (registerTexture (rigRecording rig) t4)
      fmap (const ()) raised `shouldSatisfy` either (const True) (const False)
      poolAttempts rig `shouldReturn` before' + 2
      currentSet rig `shouldReturn` set1
      allocated rig `shouldReturn` 4
      clean rig

  describe "versions and slots" $ do
    it "writes a texture's descriptor only into a slot no live version maps, and reuses a released texture's slot only once the batches that bound it complete" $ do
      -- A table at its cap, so a third texture waits for a slot.
      (rig, uploads, kit) ← tableRigWith 3 3 2
      first ← uploadedTexture rig uploads
      second ← uploadedTexture rig uploads
      third ← uploadedTexture rig uploads
      handle ← registered rig first
      writtenSlots rig `shouldReturn` [0, 1]
      -- A batch binds a version mapping the first texture's slot, and is
      -- submitted; it has not completed.
      recordDrawing rig kit
      ok (releaseTexture (rigRecording rig) handle)
      -- Its slot stays mapped by the held version: the first texture is not
      -- released, and the second takes the other free slot.
      Just held ← atomically (readTable (rigRecording rig))
      tableViewRetiring held `shouldBe` [1]
      standing rig first `shouldReturn` Just ManagedLive
      _ ← registered rig second
      writtenSlots rig `shouldReturn` [0, 1, 2]
      -- A third has no slot until the first completes.
      registerTexture (rigRecording rig) third `shouldReturn'` refused (RefusedBackpressure TextureSlotBudget)
      completed rig
      ok (refreshTextureTable (rigRecording rig))
      standing rig first `shouldReturn` Just ManagedReleased
      _ ← registered rig third
      writtenSlots rig `shouldReturn` [0, 1, 2, 1]
      clean rig

    it "holds a version through its batch's completion, answers backpressure when a new one is owed and none is free, and binds again once one is" $ do
      (rig, uploads, kit) ← tableRig 4 2
      one ← uploadedTexture rig uploads
      two ← uploadedTexture rig uploads
      -- Two batches, each binding a different version, both submitted and
      -- pending.
      recordDrawing rig kit
      _ ← registered rig one
      recordDrawing rig kit
      _ ← registered rig two
      answer ← framelessOnce rig $ \recorder → inPass kit recorder (bindTable recorder)
      answer `shouldBe` Left (RefusedBackpressure LookupVersionBudget)
      completed rig
      recordDrawing rig kit
      calls ← recordingCalls (rigRecordingStandIn rig)
      [offset | Recorded _ (CommandBindDescriptorSets _ _ [offset]) ← calls] `shouldBe` [0, 256, 0]
      clean rig

    it "keeps the original image for a batch recorded before its texture's release and submitted after it, and reuses its slot only once that batch completes" $ do
      (rig, uploads, kit) ← tableRig 3 2
      first ← uploadedTexture rig uploads
      replacement ← uploadedTexture rig uploads
      handle ← registered rig first
      firstView ← viewOf rig first
      -- Recorded, then the handle released and the texture re-registered,
      -- then submitted: the scope submits once its body returns.
      withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope $ \recorder → inPass kit recorder $ do
          ok (bindTable recorder)
          ok (selectSampler recorder 0)
          ok (draw recorder 3 1)
        ok (releaseTexture (rigRecording rig) handle)
        _ ← registered rig replacement
        pure ()
      -- The batch's version still maps the first image's slot: it was not
      -- released, and no descriptor was written over it.
      standing rig first `shouldReturn` Just ManagedLive
      writes ← imageWrites rig
      [element | (element, view) ← writes, view == firstView] `shouldBe` [1]
      [element | (element, _) ← writes] `shouldBe` [0, 1, 2]
      completed rig
      ok (refreshTextureTable (rigRecording rig))
      standing rig first `shouldReturn` Just ManagedReleased
      clean rig

    it "writes each new version whole into an entry no batch holds before the batch that binds it records, flushed on non-coherent memory to the atom" $ do
      rig ← newRig
      limitRecording (rigRecordingStandIn rig) standInRecordingLimits {limitImageDimension = 16}
      allowTypes (standAllocator (rigRootsStandIn rig)) (2 ^ deviceLocalType + 2 ^ nonCoherentType)
      uploads ← newUploads (rigFrames rig) (either (error . show) id (validateUploadConfig 4096 1024 8)) >>= either (fail . show) pure
      ok (createTextureTable (rigRecording rig) uploads (tableConfig 16 4 2))
      settle rig uploads
      ok (refreshTextureTable (rigRecording rig))
      kit ← newKit rig
      texture ← uploadedTexture rig uploads
      -- The first batch holds entry 0; the registration owes a new version,
      -- which goes into entry 1 at the 256-byte stride.
      recordDrawing rig kit
      _ ← registered rig texture
      recordDrawing rig kit
      calls ← recordingCalls (rigRecordingStandIn rig)
      let versionWrites = [(offset, count) | WroteMapped offset count ← calls, count == 128]
          beforeBind = takeWhile (not . isBind) calls
          isBind = \case
            Recorded _ CommandBindDescriptorSets {} → True
            _ → False
      versionWrites `shouldBe` [(0, 128), (256, 128)]
      [() | WroteMapped _ 128 ← beforeBind] `shouldBe` [()]
      lookupAllocation ← managedHandles rig "lookup buffer" <&> \case
        [_, allocation] → allocation
        other → error ("the lookup buffer's handles: " <> show other)
      flushes ← (\made → [range | Flushed allocation range ← made, allocation == lookupAllocation]) <$> allocatorCalls (standAllocator (rigRootsStandIn rig))
      flushes `shouldBe` [(0, 128), (256, 128)]
      clean rig

    it "binds a batch at the current version while every ring entry is held, when no mapping changed since it was published" $ do
      (rig, uploads, kit) ← tableRig 4 2
      one ← uploadedTexture rig uploads
      recordDrawing rig kit
      _ ← registered rig one
      recordDrawing rig kit
      -- Both entries are held by pending batches, and nothing changed since
      -- the second was published.
      recordDrawing rig kit
      calls ← recordingCalls (rigRecordingStandIn rig)
      [offset | Recorded _ (CommandBindDescriptorSets _ _ [offset]) ← calls] `shouldBe` [0, 256, 256]
      clean rig

  describe "failure" $ do
    it "keeps every image a pending batch's version maps, and the placeholder, through retirement: none is destroyed, and each is named as retained" $ do
      (rig, uploads, kit) ← tableRig 4 2
      texture ← uploadedTexture rig uploads
      _ ← registered rig texture
      recordDrawing rig kit
      retired ← try @ResourcesRetained (retireRecording (rigRecording rig) (at 1))
      case retired of
        Left (ResourcesRetained remaining) → remaining `shouldSatisfy` elem (managedResource texture)
        Right () → expectationFailure "retirement claimed images a pending batch samples"
      -- The texture, the placeholder and the batch's color target are every
      -- image there is, and the batch holds all three.
      calls ← recordingCalls (rigRecordingStandIn rig)
      [view | DestroyedView view ← calls] `shouldBe` []
      standing rig texture `shouldReturn` Just ManagedReleased

    it "keeps them through retirement while the batch is only recorded, too" $ do
      (rig, uploads, kit) ← tableRig 4 2
      texture ← uploadedTexture rig uploads
      _ ← registered rig texture
      retired ← newIORef Nothing
      _ ← try @SomeException $ withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope $ \recorder → inPass kit recorder $ do
          ok (bindTable recorder)
          ok (selectSampler recorder 0)
          ok (draw recorder 3 1)
        answer ← try @ResourcesRetained (retireRecording (rigRecording rig) (at 1))
        writeIORef retired (Just answer)
      readIORef retired >>= \case
        Just (Left (ResourcesRetained remaining)) → remaining `shouldSatisfy` elem (managedResource texture)
        other → expectationFailure ("retirement answered " <> show (fmap (fmap (const ())) other))
      calls ← recordingCalls (rigRecordingStandIn rig)
      [view | DestroyedView view ← calls] `shouldBe` []

    it "refuses new table work once the session has failed, writing nothing, and still lets a released texture go" $ do
      (rig, uploads, kit) ← tableRig 4 2
      texture ← uploadedTexture rig uploads
      other ← uploadedTexture rig uploads
      handle ← registered rig texture
      bound ← newIORef Nothing
      _ ← try @SomeException $ withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope $ \recorder → do
          ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 0 1))
          ok (bindPipeline recorder (kitPipeline kit))
          atomically (failRootsSessionBecause (rigRoots rig) CleanupFailed "a later cleanup failed")
          before ← length <$> recordingCalls (rigRecordingStandIn rig)
          answer ← bindTable recorder
          writeIORef bound (Just (answer, before))
      Just (answer, before) ← readIORef bound
      answer `shouldSatisfy` sessionFailed
      registerTexture (rigRecording rig) other `shouldReturn'` (`shouldSatisfy` sessionFailed)
      createTablePipelineLayout (rigRecording rig) tableShaders 8 `shouldReturn'` (`shouldSatisfy` sessionFailed)
      ok (refreshTextureTable (rigRecording rig))
      after ← drop before <$> recordingCalls (rigRecordingStandIn rig)
      [() | WroteDescriptors _ ← after] `shouldBe` []
      [() | WroteMapped {} ← after] `shouldBe` []
      [() | Recorded _ CommandBindDescriptorSets {} ← after] `shouldBe` []
      -- Releasing is cleanup: the texture no batch bound goes at once.
      ok (releaseTexture (rigRecording rig) handle)
      standing rig texture `shouldReturn` Just ManagedReleased

    it "leaves only whole generations when its construction fails part-way, released at once and destroyed by the ordinary rules, which retain one whose destruction raised and fail the session" $ do
      (rig, uploads) ← uploadRig
      let standIn = rigRecordingStandIn rig
          next = onceAt standIn AtCreateSampler
      -- The fourth sampler's creation raises.
      next (next (next (next (throwIO (RecordingFailure AtCreateSampler)))))
      failAt standIn AtDestroySampler
      raised ← try @RecordingFailure (createTextureTable (rigRecording rig) uploads (tableConfig 16 4 2))
      raised `shouldBe` Left (RecordingFailure AtCreateSampler)
      atomically (readTable (rigRecording rig)) `shouldReturn` Nothing
      samplerStandings rig `shouldReturn` replicate 3 ManagedReleased
      destroyed ← try @ResourceDestructionFailed (disposeResources (rigRecording rig) (at 1))
      fmap (const ()) destroyed `shouldSatisfy` either (const True) (const False)
      samplerStandings rig `shouldReturn'` (`shouldSatisfy` all uncertain)
      sessionState <$> atomically (readRootsModel (rigRoots rig)) `shouldReturn` SessionFailed CleanupFailed
      -- Never retried.
      _ ← try @ResourceDestructionFailed (disposeResources (rigRecording rig) (at 2))
      calls ← recordingCalls standIn
      length [() | DestroyedSampler _ ← calls] `shouldBe` 3

    it "leaves no generation unowned when a cancellation arrives as its construction makes one: each is released, or held by the published table" $ do
      (rig, uploads) ← uploadRig
      owner ← myThreadId
      -- Aimed at the owner from inside the first sampler's creation, which
      -- runs masked: it can be delivered only once that creation returns.
      onceAt (rigRecordingStandIn rig) AtCreateSampler $ do
        killer ← forkIO (killThread owner)
        awaitThrowing killer
      outcome ← try @SomeException (createTextureTable (rigRecording rig) uploads (tableConfig 16 4 2))
      fmap (const ()) outcome `shouldSatisfy` either ((== Just ThreadKilled) . fromException) (const False)
      published ← atomically (readTable (rigRecording rig))
      standings ← samplerStandings rig
      calls ← recordingCalls (rigRecordingStandIn rig)
      length [() | CreatedSampler {} ← calls] `shouldSatisfy` (>= 1)
      length standings `shouldBe` length [() | CreatedSampler {} ← calls]
      case published of
        Nothing → standings `shouldSatisfy` all (== ManagedReleased)
        Just _ → standings `shouldSatisfy` all (== ManagedLive)

    it "never strands a reclaimed image when a cancellation arrives during the refresh that reclaims it: it is released, or still retiring for the next refresh" $ do
      (rig, uploads, kit) ← tableRig 4 2
      first ← uploadedTexture rig uploads
      handle ← registered rig first
      recordDrawing rig kit
      ok (releaseTexture (rigRecording rig) handle)
      -- A second texture whose upload completes before the refresh, so the
      -- refresh writes its descriptor first and then reclaims the first's
      -- slot, whose batch has completed by then.
      second ← createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Linear 2 2 1) >>= either (fail . show) pure
      _ ← submitUpload uploads (UploadImage second [ByteString.replicate 16 255]) >>= either (fail . show) pure
      _ ← registered rig second
      settle rig uploads
      owner ← myThreadId
      onceAt (rigRecordingStandIn rig) AtWriteDescriptors $ do
        killer ← forkIO (killThread owner)
        awaitThrowing killer
      outcome ← try @SomeException (refreshTextureTable (rigRecording rig))
      fmap (const ()) outcome `shouldSatisfy` either ((== Just ThreadKilled) . fromException) (const False)
      Just view ← atomically (readTable (rigRecording rig))
      standing rig first >>= \case
        Just ManagedReleased → tableViewRetiring view `shouldBe` []
        _ → tableViewRetiring view `shouldBe` [1]
      -- Either way the next refresh leaves nothing stranded.
      ok (refreshTextureTable (rigRecording rig))
      standing rig first `shouldReturn` Just ManagedReleased
      clean rig

  describe "handles" $ do
    it "undoes a registration whose refresh raises or is cancelled before its handle is handed out, into a slot an earlier, bound and released texture left: nothing stays registered, and registering again succeeds" $ do
      (rig, uploads, kit) ← tableRig 4 2
      -- An earlier texture takes slot 1, is bound by a batch that completes,
      -- and is released; its slot is reclaimed, while that obsolete version
      -- still names it.
      earlier ← uploadedTexture rig uploads
      earlierHandle ← registered rig earlier
      recordDrawing rig kit
      ok (releaseTexture (rigRecording rig) earlierHandle)
      completed rig
      ok (refreshTextureTable (rigRecording rig))
      standing rig earlier `shouldReturn` Just ManagedReleased
      texture ← uploadedTexture rig uploads
      let standIn = rigRecordingStandIn rig
          unregistered = do
            Just view ← atomically (readTable (rigRecording rig))
            tableViewMapping view `shouldBe` Map.empty
            tableViewFree view `shouldBe` Set.fromList [1, 2, 3]
      -- The texture's upload has completed, so registering it writes its
      -- descriptor, which fails.
      failAt standIn AtWriteDescriptors
      raised ← try @RecordingFailure (registerTexture (rigRecording rig) texture)
      fmap (const ()) raised `shouldBe` Left (RecordingFailure AtWriteDescriptors)
      unregistered
      succeedAt standIn AtWriteDescriptors
      -- A cancellation aimed at the owner from inside that write.
      owner ← myThreadId
      onceAt standIn AtWriteDescriptors $ do
        killer ← forkIO (killThread owner)
        awaitThrowing killer
      interrupted ← try @SomeException (registerTexture (rigRecording rig) texture)
      fmap (const ()) interrupted `shouldSatisfy` either ((== Just ThreadKilled) . fromException) (const False)
      unregistered
      -- The caller still owns the image, and registers it again.
      handle ← registered rig texture
      Just view ← atomically (readTable (rigRecording rig))
      resolveHandle 4 (tableViewMapping view) handle `shouldSatisfy` (/= 0)
      clean rig

    it "refuses a released handle wherever it is used, and issues its index again only under a new generation" $ do
      (rig, uploads, _) ← tableRig 4 2
      first ← uploadedTexture rig uploads
      second ← uploadedTexture rig uploads
      handle ← registered rig first
      ok (releaseTexture (rigRecording rig) handle)
      releaseTexture (rigRecording rig) handle `shouldReturn` Left (RefusedStaleHandle handle)
      reissued ← registered rig second
      handleIndex reissued `shouldBe` handleIndex handle
      handleGeneration reissued `shouldSatisfy` (/= handleGeneration handle)
      releaseTexture (rigRecording rig) handle `shouldReturn` Left (RefusedStaleHandle handle)
      Just view ← atomically (readTable (rigRecording rig))
      -- The stale handle resolves to the placeholder, the new one to its slot.
      resolveHandle 4 (tableViewMapping view) handle `shouldBe` 0
      resolveHandle 4 (tableViewMapping view) reissued `shouldSatisfy` (/= 0)
      clean rig

    it "resolves a handle to the placeholder until its upload completes, and a release before then writes no descriptor and frees the image once its upload settles" $ do
      (rig, uploads, _) ← tableRig 4 2
      texture ← createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Linear 2 2 1) >>= either (fail . show) pure
      _ ← submitUpload uploads (UploadImage texture [ByteString.replicate 16 255]) >>= either (fail . show) pure
      handle ← registered rig texture
      Just pending ← atomically (readTable (rigRecording rig))
      resolveHandle 4 (tableViewMapping pending) handle `shouldBe` 0
      ok (releaseTexture (rigRecording rig) handle)
      settle rig uploads
      ok (refreshTextureTable (rigRecording rig))
      writtenSlots rig `shouldReturn` [0]
      standing rig texture `shouldReturn` Just ManagedReleased
      clean rig

    it "frees a version a discarded batch bound, so a texture it mapped is released once its handle is" $ do
      (rig, uploads, kit) ← tableRig 4 2
      first ← uploadedTexture rig uploads
      handle ← registered rig first
      discarded ← try @ErrorCall @() $ withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope $ \recorder → inPass kit recorder $ do
          ok (bindTable recorder)
          ok (selectSampler recorder 0)
          ok (draw recorder 3 1)
        throwIO (ErrorCall "the consumer gave up")
      discarded `shouldBe` Left (ErrorCall "the consumer gave up")
      ok (releaseTexture (rigRecording rig) handle)
      ok (refreshTextureTable (rigRecording rig))
      standing rig first `shouldReturn` Just ManagedReleased
      clean rig
  where
    sessionFailed = \case
      Left (RefusedSessionFailed _) → True
      _ → False
    uncertain = \case
      ManagedUncertain _ → True
      _ → False
    refused refusal answer = case answer of
      Left actual → actual `shouldBe` refusal
      Right _ → expectationFailure ("expected " <> show refusal)

-- ---------------------------------------------------------------------------
-- The rig

uploadRig ∷ IO (Rig, Ups)
uploadRig = do
  rig ← newRig
  limitRecording (rigRecordingStandIn rig) standInRecordingLimits {limitImageDimension = 16}
  uploads ← newUploads (rigFrames rig) (either (error . show) id (validateUploadConfig 4096 1024 8)) >>= either (fail . show) pure
  pure (rig, uploads)

tableConfig ∷ Integer → Integer → Integer → TableConfig
tableConfig capacity initial versions = either (error . show) id (validateTableConfig capacity initial versions)

-- | A session with a table of this many slots and versions whose placeholder
-- is written, and a kit to draw with.
tableRig ∷ Integer → Integer → IO (Rig, Ups, Kit)
tableRig = tableRigWith 16

-- | 'tableRig' with this cap.
tableRigWith ∷ Integer → Integer → Integer → IO (Rig, Ups, Kit)
tableRigWith cap slots versions = do
  (rig, uploads) ← uploadRig
  ok (createTextureTable (rigRecording rig) uploads (tableConfig cap slots versions))
  settle rig uploads
  ok (refreshTextureTable (rigRecording rig))
  kit ← newKit rig
  pure (rig, uploads, kit)

-- | Turn and complete until every upload has settled.
settle ∷ Rig → Ups → IO ()
settle rig uploads = go (32 ∷ Int)
  where
    go 0 = expectationFailure "the uploads did not settle in 32 turns"
    go remaining = do
      _ ← progressUploads uploads >>= either (fail . show) pure
      completed rig
      _ ← progressUploads uploads >>= either (fail . show) pure
      left ← uploadsUnsettled <$> atomically (readUploads uploads)
      when (not (null left)) (go (remaining - 1))

-- | Complete every pending fence and observe it.
completed ∷ Rig → IO ()
completed rig = completeAll (rigStandIn rig) >> () <$ progress rig

-- | A two-by-two RGBA8 texture whose upload has completed.
uploadedTexture ∷ Rig → Ups → IO Image
uploadedTexture rig uploads = do
  texture ← createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Linear 2 2 1) >>= either (fail . show) pure
  _ ← submitUpload uploads (UploadImage texture [ByteString.replicate 16 255]) >>= either (fail . show) pure
  settle rig uploads
  pure texture

registered ∷ Rig → Image → IO TextureHandle
registered rig texture = registerTexture (rigRecording rig) texture >>= either (fail . show) pure

-- | A color target, a pipeline over a layout holding the table, and one
-- over a layout without it.
data Kit = Kit
  { kitTarget ∷ !Image
  , kitPipeline ∷ !Pipeline
  , kitPlain ∷ !Pipeline
  }

newKit ∷ Rig → IO Kit
newKit rig = do
  target ← createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Srgb 32 16 1) >>= either (fail . show) pure
  layout ← createTablePipelineLayout (rigRecording rig) tableShaders 8 >>= either (fail . show) pure
  pipeline ← createCheckedPipeline (rigRecording rig) layout tableShaders (formatCode Rgba8Srgb) >>= either (fail . show) pure
  plainLayout ← createPipelineLayoutFor (rigRecording rig) plainShaders >>= either (fail . show) pure
  plain ← createCheckedPipeline (rigRecording rig) plainLayout plainShaders (formatCode Rgba8Srgb) >>= either (fail . show) pure
  pure (Kit target pipeline plain)

-- | A fragment stage reading the table, with a handle at offset 0 and its
-- sampler index at 8.
tableShaders ∷ CheckedShaders
tableShaders = shadersWith textureTableDescriptors

shadersWith ∷ [DescriptorDeclaration] → CheckedShaders
shadersWith descriptors =
  CheckedShaders
    (CheckedShader (ByteString.pack [1, 2, 3, 4]) (interfaceFor VertexInterface))
    (CheckedShader (ByteString.pack [5, 6, 7, 8]) (interfaceFor FragmentInterface) {interfacePushConstants = [PushMember 0 8, PushMember 8 4], interfaceDescriptors = descriptors})

plainShaders ∷ CheckedShaders
plainShaders =
  CheckedShaders
    (CheckedShader (ByteString.pack [1, 2, 3, 4]) (interfaceFor VertexInterface))
    (CheckedShader (ByteString.pack [5, 6, 7, 8]) (interfaceFor FragmentInterface))

inPass ∷ Kit → Rec → IO a → IO a
inPass kit recorder action = do
  ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 0 1))
  ok (bindPipeline recorder (kitPipeline kit))
  ok (setViewport recorder (Viewport 0 0 32 16))
  ok (setScissor recorder (Rect 0 0 32 16))
  value ← action
  ok (endRendering recorder)
  pure value

-- | Record one frame-less batch in a scope of its own, which submits it.
framelessOnce ∷ Rig → (Rec → IO a) → IO a
framelessOnce rig consumer =
  withFramelessScope (rigFrames rig) $ \scope → recordFramelessIn scope consumer >>= either (fail . show) (pure . snd)

-- | One submitted, uncompleted batch that binds the table and draws.
recordDrawing ∷ Rig → Kit → IO ()
recordDrawing rig kit = framelessOnce rig $ \recorder → inPass kit recorder $ do
  ok (bindTable recorder)
  ok (selectSampler recorder 0)
  ok (draw recorder 3 1)

-- ---------------------------------------------------------------------------
-- Observation

-- | Every slot a sampled-image descriptor was written into, in order.
writtenSlots ∷ Rig → IO [Word32]
writtenSlots rig = map fst <$> imageWrites rig

imageWrites ∷ Rig → IO [(Word32, Word64)]
imageWrites rig = (\calls → [(element, view) | WroteDescriptors writes ← calls, WriteSampledImage _ element view ← writes]) <$> recordingCalls (rigRecordingStandIn rig)

commandCount ∷ Rig → IO Int
commandCount rig = (\calls → length [() | Recorded {} ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

-- | The native handles of the one managed generation of this kind.
managedHandles ∷ Rig → Text → IO [Word64]
managedHandles rig kind' =
  (\views → concat [handles | ManagedView _ _ named handles ← views, named == kind']) <$> atomically (readManaged (rigRecording rig))

-- | Where each of the table's samplers stands.
samplerStandings ∷ Rig → IO [ManagedStanding]
samplerStandings rig = (\views → [held | ManagedView _ held "table sampler" _ ← views]) <$> atomically (readManaged (rigRecording rig))

-- | The table shaders with this vertex stage's descriptors.
vertexDeclaring ∷ [DescriptorDeclaration] → CheckedShaders
vertexDeclaring descriptors =
  CheckedShaders
    (CheckedShader (ByteString.pack [1, 2, 3, 4]) (interfaceFor VertexInterface) {interfaceDescriptors = descriptors})
    (CheckedShader (ByteString.pack [5, 6, 7, 8]) (interfaceFor FragmentInterface) {interfacePushConstants = [PushMember 0 8, PushMember 8 4], interfaceDescriptors = textureTableDescriptors})

-- | The current set 0.
currentSet ∷ Rig → IO Word64
currentSet rig = atomically (readTable (rigRecording rig)) <&> \case
  Just view → head' (tableViewSets view)
  Nothing → error "no table"

-- | How many slots the current set holds.
allocated ∷ Rig → IO Word32
allocated rig = atomically (readTable (rigRecording rig)) <&> maybe 0 tableViewAllocated

-- | Every growth's copy: the old set, the new one, and the runs copied.
copies ∷ Rig → IO [(Word64, Word64, [(Word32, Word32)])]
copies rig = (\calls → [(from, to, copied) | WroteDescriptors writes ← calls, CopySampledImages from to copied ← writes]) <$> recordingCalls (rigRecordingStandIn rig)

-- | Every descriptor pool destroyed so far.
destroyedPools ∷ Rig → IO [Word64]
destroyedPools rig = (\calls → [pool | DestroyedPool pool ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

-- | How many set 0 pools were asked for so far, made or not.
poolAttempts ∷ Rig → IO Int
poolAttempts rig = (\calls → length [() | CreatedPool _ (TexturePool _ _) ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

head' ∷ [a] → a
head' = \case
  x : _ → x
  [] → error "empty"

-- | How many managed generations of this kind the recording holds.
managedCount ∷ Rig → Text → IO Int
managedCount rig kind' = (\views → length [() | ManagedView _ _ named _ ← views, named == kind']) <$> atomically (readManaged (rigRecording rig))

viewOf ∷ Rig → Image → IO Word64
viewOf rig texture =
  (\views → case [handles | ManagedView viewed _ _ handles ← views, viewed == managedResource texture] of
      (_ : view : _) : _ → view
      _ → error "the image has no view")
    <$> atomically (readManaged (rigRecording rig))

standing ∷ Rig → Image → IO (Maybe ManagedStanding)
standing rig texture =
  (\views → case [held | ManagedView viewed held _ _ ← views, viewed == managedResource texture] of
      held : _ → Just held
      [] → Nothing)
    <$> atomically (readManaged (rigRecording rig))
