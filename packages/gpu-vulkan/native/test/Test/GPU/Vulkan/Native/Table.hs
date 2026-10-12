{-# LANGUAGE DuplicateRecordFields #-}

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
import Numeric.Natural (Natural)
import Vulkan.Core10 (PhysicalDeviceLimits (..))
import Vulkan.Core12 (PhysicalDeviceVulkan12Properties (..))
import Vulkan.Zero (zero)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.GPU.Model.Access (ResourceKind (InstanceResource))
import Hetoimasia.GPU.Model.Budget (BudgetKind (LookupVersionBudget, RingBudget, TextureSlotBudget))
import Hetoimasia.GPU.Model (GpuModel, HoldView (..), SessionFailureCause (CleanupFailed), SessionState (SessionFailed), holdView, sessionState)
import Hetoimasia.GPU.Model.Identity (BatchId, HoldSubject (..), IdentityKind (..), Misuse (..), ResourceId)
import Hetoimasia.GPU.Vulkan.Native.Roots (failRootsSessionBecause, readRootsModel)
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan (recordingLimitsOf)
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
import Data.Bits ((.&.))
import Data.List (nub)
import Test.GPU.Vulkan.Native.AllocatorStandIn (AllocatorCall (Flushed, Placing), allocatorCalls, allowTypes, deviceLocalType, nonCoherentType)
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn (FrameStep (AtQueryFence), completeAll, completeFence, loseFrameStep, pendingFences)
import Test.GPU.Vulkan.Native.StandIn (StandIn (standAllocator), StandInResult (..), offerNaming, outOfMemoryNaming)
import Hetoimasia.GPU.Vulkan.Native.Naming (NativeObjectKind (ObjectDescriptorPool, ObjectDescriptorSet))
import Test.GPU.Vulkan.Native.RecordingStandIn (RecordingCall (..), RecordingFailure (..), RecordingStep (..), duringWrite, failAt, limitBuffers, limitRecording, onceAt, outOfMemoryAt, recordingCalls, standInRecordingLimits, succeedAt)

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
      -- Set 0's pools, generation by generation — 4, 8 and 16 images, each
      -- with the four samplers — may all be held at once.
      refusedUnder limits {limitTablePoolDescriptors = 39} (tableConfig 16 4 2) `shouldReturn` Left (RefusedOutOfBounds 40 39)
      -- Doubling past 2^31 reaches the cap rather than wrapping: two
      -- generations, of 2^31 and 2^31 + 1 images.
      refusedUnder limits {limitTableSampledImages = maxBound, limitTableResources = maxBound, limitTablePoolDescriptors = maxBound} (tableConfig 2147483649 2147483648 2) `shouldReturn` Left (RefusedOutOfBounds 4294967305 4294967295)
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

  describe "shader-sampled pipeline layouts" $ do
    it "makes a layout holding both set layouts, with no sampler offset and no push-constant range, and a checked pipeline over it" $ do
      (rig, _, kit) ← tableRig 4 2
      before ← recordingCalls (rigRecordingStandIn rig)
      layout ← createShaderSampledTablePipelineLayout (rigRecording rig) sampledShaders >>= either (fail . show) pure
      after ← recordingCalls (rigRecordingStandIn rig)
      let layouts = [handle | CreatedSetLayout handle _ ← before]
          made = drop (length before) after
      [declared | DeclaredSetLayouts _ declared ← made] `shouldBe` [layouts]
      -- The stand-in records a layout's ranges only when it has any.
      [ranges | DeclaredRanges _ ranges ← made] `shouldBe` []
      length [() | CreatedLayout {} ← made] `shouldBe` 1
      pipeline ← createCheckedPipeline (rigRecording rig) layout sampledShaders (formatCode Rgba8Srgb) >>= either (fail . show) pure
      -- A range the shaders declare is the layout's, with no offset reserved
      -- in it.
      wide ← createShaderSampledTablePipelineLayout (rigRecording rig) (sampledShadersWith [PushMember 0 16]) >>= either (fail . show) pure
      createCheckedPipeline (rigRecording rig) wide (sampledShadersWith [PushMember 0 16]) (formatCode Rgba8Srgb) `shouldReturn'` (either (fail . show) (const (pure ())))
      -- A layout of the other kind is not the shaders' layout.
      createCheckedPipeline (rigRecording rig) layout tableShaders (formatCode Rgba8Srgb)
        `shouldReturn'` refused (RefusedIncompatible "a pipeline layout whose push-constant ranges are not the ones its checked shaders declare")
      pipeline `seq` kitTarget kit `seq` clean rig

    it "is refused, making no native call, in a session with no table, for a binding the table does not hold, for a vertex stage declaring set 0, and for ranges past the device's limit" $ do
      bare ← newRig
      bareBefore ← recordingCalls (rigRecordingStandIn bare)
      createShaderSampledTablePipelineLayout (rigRecording bare) sampledShaders
        `shouldReturn'` refused (RefusedIllegal "a pipeline layout holding a texture table this session has not made")
      bareAfter ← recordingCalls (rigRecordingStandIn bare)
      length bareAfter `shouldBe` length bareBefore
      (rig, _, kit) ← tableRig 4 2
      before ← recordingCalls (rigRecordingStandIn rig)
      createShaderSampledTablePipelineLayout (rigRecording rig) (sampledWith [DescriptorDeclaration 2 0 StorageBuffer (DescriptorCount 1)] [])
        `shouldReturn'` refused (RefusedIncompatible "a shader declaring a descriptor binding the texture table does not hold")
      createShaderSampledTablePipelineLayout (rigRecording rig) (sampledVertexDeclaring [DescriptorDeclaration 0 1 SampledImage RuntimeSized])
        `shouldReturn'` refused (RefusedIncompatible "a vertex shader declaring the texture table's samplers or images, which only the fragment stage sees")
      createShaderSampledTablePipelineLayout (rigRecording rig) (sampledVertexDeclaring [DescriptorDeclaration 0 0 Sampler (DescriptorCount 4)])
        `shouldReturn'` refused (RefusedIncompatible "a vertex shader declaring the texture table's samplers or images, which only the fragment stage sees")
      limitRecording (rigRecordingStandIn rig) standInRecordingLimits {limitImageDimension = 16, limitPushConstantBytes = 8}
      createShaderSampledTablePipelineLayout (rigRecording rig) (sampledShadersWith [PushMember 0 12])
        `shouldReturn'` refused (RefusedOutOfBounds 12 8)
      limitRecording (rigRecordingStandIn rig) standInRecordingLimits {limitImageDimension = 16}
      after ← recordingCalls (rigRecordingStandIn rig)
      length [() | CreatedLayout {} ← after] `shouldBe` length [() | CreatedLayout {} ← before]
      -- The shaders' own bindings are still refused by a layout without the table.
      createPipelineLayoutFor (rigRecording rig) sampledShaders `shouldReturn'` refused (RefusedUnsupported "a shader declaring descriptor bindings, which only a pipeline layout holding the texture table declares")
      kitTarget kit `seq` clean rig

  describe "drawing under a shader-sampled layout" $ do
    it "binds the table and draws with no selected sampler, refuses selectSampler with no native call, and admits a push over offset 8 while keeping the ordinary push checks" $ do
      (rig, _, kit) ← tableRig 4 2
      pipeline ← sampledPipeline rig (sampledShadersWith [PushMember 0 16])
      answers ← framelessOnce rig $ \recorder → inPassWith kit pipeline recorder $ do
        ok (bindTable recorder)
        ok (draw recorder 3 1)
        before ← commandCount rig
        selected ← selectSampler recorder 1
        beyond ← selectSampler recorder 9
        after ← commandCount rig
        ok (pushConstants recorder [PushFragment] 8 (ByteString.pack [7, 0, 0, 0]))
        ok (pushConstants recorder [PushFragment] 4 (ByteString.pack [1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0]))
        unaligned ← pushConstants recorder [PushFragment] 10 (ByteString.pack [1, 0, 0, 0])
        past ← pushConstants recorder [PushFragment] 16 (ByteString.pack [1, 0, 0, 0])
        vertex ← pushConstants recorder [PushVertex] 8 (ByteString.pack [1, 0, 0, 0])
        ok (draw recorder 3 1)
        pure ([selected, beyond, unaligned, past, vertex], after - before)
      fst answers
        `shouldBe` [ Left (RefusedIllegal "selecting a sampler under a pipeline whose layout's shaders choose their samplers")
                   , Left (RefusedIllegal "selecting a sampler under a pipeline whose layout's shaders choose their samplers")
                   , Left (RefusedIllegal "a push whose offset or size is not a multiple of four")
                   , Left (RefusedOutOfBounds 20 16)
                   , Left (RefusedIllegal "a push to the PushVertex stage, for which the bound pipeline's layout declares no range")
                   ]
      snd answers `shouldBe` 0
      calls ← recordingCalls (rigRecordingStandIn rig)
      let commands' = [command | Recorded _ command ← calls]
      [(offset, bytes) | CommandPushConstants _ _ offset bytes ← commands'] `shouldBe` [(8, ByteString.pack [7, 0, 0, 0]), (4, ByteString.pack [1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0])]
      length [() | CommandDraw {} ← commands'] `shouldBe` 2
      clean rig

    it "refuses a draw, making no native call, before the table is bound under a compatible layout and while the batch holds an image its version maps in another use, and draws once it is back" $ do
      (rig, uploads, kit) ← tableRig 4 2
      pipeline ← sampledPipeline rig sampledShaders
      texture ← uploadedTexture rig uploads
      _ ← registered rig texture
      answers ← framelessOnce rig $ \recorder → do
        unbound ← inPassWith kit pipeline recorder (draw recorder 3 1)
        ok (transitionResource recorder texture (FromUse ShaderSampled) TransferRead)
        moved ← inPassWith kit pipeline recorder $ do
          ok (bindTable recorder)
          draw recorder 3 1
        ok (transitionResource recorder texture (FromUse TransferRead) ShaderSampled)
        back ← inPassWith kit pipeline recorder $ do
          ok (bindTable recorder)
          draw recorder 3 1
        pure [unbound, moved, back]
      answers
        `shouldBe` [ Left (RefusedIllegal "a draw with a pipeline holding the texture table before the table is bound under a compatible layout")
                   , Left (RefusedIllegal "a draw through the texture table while the batch holds an image its version maps in a use other than sampling")
                   , Right ()
                   ]
      calls ← recordingCalls (rigRecordingStandIn rig)
      length [() | Recorded _ CommandDraw {} ← calls] `shouldBe` 1
      clean rig

    it "disturbs the table binding and the sampler selection on a switch between a pushed and a shader-sampled pipeline of identical ranges, in both directions, and a rebind keeps the batch's sets and version" $ do
      (rig, uploads, kit) ← tableRigWith 16 2 4
      sampled ← sampledPipeline rig (sampledShadersWith [PushMember 0 8, PushMember 8 4])
      t1 ← uploadedTexture rig uploads
      t2 ← uploadedTexture rig uploads
      answers ← framelessOnce rig $ \recorder → inPass kit recorder $ do
        ok (bindTable recorder)
        ok (selectSampler recorder 1)
        ok (draw recorder 3 1)
        ok (bindPipeline recorder sampled)
        -- Two registrations change the mapping and grow the table, but the
        -- batch keeps the set and version it took.
        _ ← registered rig t1
        _ ← registered rig t2
        toSampled ← draw recorder 3 1
        ok (bindTable recorder)
        ok (draw recorder 3 1)
        ok (bindPipeline recorder (kitPipeline kit))
        toPushed ← draw recorder 3 1
        ok (bindTable recorder)
        unselected ← draw recorder 3 1
        ok (selectSampler recorder 2)
        ok (draw recorder 3 1)
        pure [toSampled, toPushed, unselected]
      answers
        `shouldBe` [ Left (RefusedIllegal "a draw with a pipeline holding the texture table before the table is bound under a compatible layout")
                   , Left (RefusedIllegal "a draw with a pipeline holding the texture table before the table is bound under a compatible layout")
                   , Left (RefusedIllegal "a draw with a pipeline holding the texture table before a sampler is selected")
                   ]
      calls ← recordingCalls (rigRecordingStandIn rig)
      let commands' = [command | Recorded _ command ← calls]
          binds = [(sets, offsets) | CommandBindDescriptorSets _ sets offsets ← commands']
      length binds `shouldBe` 3
      length (Set.fromList binds) `shouldBe` 1
      [bytes | CommandPushConstants _ _ 8 bytes ← commands'] `shouldBe` [ByteString.pack [1, 0, 0, 0], ByteString.pack [2, 0, 0, 0]]
      length [() | CommandDraw {} ← commands'] `shouldBe` 3
      clean rig

    it "keeps the pushed path as it was: a draw before a sampler is selected is refused, and switching between pushed pipelines of equal ranges keeps the table bound" $ do
      (rig, _, kit) ← tableRig 4 2
      other ← do
        layout ← createTablePipelineLayout (rigRecording rig) tableShaders 8 >>= either (fail . show) pure
        createCheckedPipeline (rigRecording rig) layout tableShaders (formatCode Rgba8Srgb) >>= either (fail . show) pure
      answers ← framelessOnce rig $ \recorder → inPass kit recorder $ do
        ok (bindTable recorder)
        before ← draw recorder 3 1
        ok (selectSampler recorder 3)
        ok (bindPipeline recorder other)
        kept ← draw recorder 3 1
        pure [before, kept]
      answers
        `shouldBe` [Left (RefusedIllegal "a draw with a pipeline holding the texture table before a sampler is selected"), Right ()]
      clean rig

  describe "the ring's storage window (R2D-15)" $ do
    it "validates a window once, never clamping it" $
      map (fmap storageWindowBytes) [validateStorageWindow 0, validateStorageWindow (-4), validateStorageWindow (2 ^ (64 ∷ Int)), validateStorageWindow 64]
        `shouldBe` [Left (StorageWindowNotPositive 0), Left (StorageWindowNotPositive (-4)), Left (StorageWindowUnrepresentable (2 ^ (64 ∷ Int))), Right 64]

    it "covers shader storage reads in the vertex and fragment stages by the ring's instance-read use" $ do
      -- The use is the ring's resting use, entered by the batch's first
      -- claim: its stages include both shaders', and its access is
      -- @SHADER_READ@, which covers storage reads beside sampled and uniform
      -- ones, so binding the ring as a storage buffer records no other use.
      let scope = useScope InstanceResource InstanceRead
      (scopeStages scope .&. 0x8, scopeStages scope .&. 0x80, scopeAccess scope .&. 0x20) `shouldBe` (0x8, 0x80, 0x20)

    it "makes the ring R + W bytes under storage usage with a tail no claim uses, and a plain ring R bytes, both with storage usage" $ do
      plain ← newRig
      plainBefore ← placed plain
      ok (createRing (rigRecording plain) (ringOf 256))
      (drop (length plainBefore) <$> placed plain) `shouldReturn` [256]
      (atomically (readRing (rigRecording plain)) <&> fmap (\view → (ringViewBytes view, ringViewWindow view))) `shouldReturn` Just (256, Nothing)
      -- The ring is the instance buffer's kind, which gains storage usage
      -- beside its vertex and index usage.
      fst (bufferKindUse InstanceBuffer) `shouldBe` 0xE0
      rig ← newRig
      before ← placed rig
      ok (createRingWith (rigRecording rig) (ringOf 256) (Just (windowOf 64)))
      (drop (length before) <$> placed rig) `shouldReturn` [320]
      (atomically (readRing (rigRecording rig)) <&> fmap (\view → (ringViewBytes view, ringViewWindow view))) `shouldReturn` Just (256, Just 64)
      createRingWith (rigRecording rig) (ringOf 256) (Just (windowOf 64)) `shouldReturn'` refused (RefusedMisuse (DuplicateSubject ResourceIdentity))
      -- Claims fill the 256 claimable bytes and never the 64 after them.
      answers ← framelessOnce rig $ \recorder → do
        larger ← claimRegion recorder 257 4
        whole ← claimRegion recorder 256 4
        tail' ← claimRegion recorder 1 4
        pure (fmap (const ()) larger, fmap (const ()) whole, fmap (const ()) tail')
      answers `shouldBe` (Left (RefusedOutOfBounds 257 256), Right (), Left (RefusedBackpressure RingBudget))
      claimStarts rig `shouldReturn` [0]
      clean rig

    it "refuses a window the device or the ring cannot hold, and a total no buffer can be, before allocating, never clamping" $ do
      rig ← newRig
      before ← placed rig
      let standIn = rigRecordingStandIn rig
      limitRecording standIn standInRecordingLimits {limitStorageRange = 63}
      createRingWith (rigRecording rig) (ringOf 256) (Just (windowOf 64)) `shouldReturn'` refused (RefusedLimit "maxStorageBufferRange" 64 63)
      limitRecording standIn standInRecordingLimits
      createRingWith (rigRecording rig) (ringOf 256) (Just (windowOf 300)) `shouldReturn'` refused (RefusedOutOfBounds 300 256)
      -- The ring alone is valid; with its tail it exceeds the device's buffer.
      limitBuffers standIn 300
      createRingWith (rigRecording rig) (ringOf 256) (Just (windowOf 64)) `shouldReturn'` refused (RefusedOutOfBounds 320 300)
      -- A total no size can hold.
      limitBuffers standIn (2 ^ (65 ∷ Int))
      createRingWith (rigRecording rig) (ringOf (2 ^ (64 ∷ Int) - 1)) (Just (windowOf 1)) `shouldReturn'` refused (RefusedOutOfBounds (2 ^ (64 ∷ Int)) (2 ^ (64 ∷ Int) - 1))
      (drop (length before) <$> placed rig) `shouldReturn` []
      (atomically (readRing (rigRecording rig)) <&> fmap ringViewBytes) `shouldReturn` Nothing
      -- Nothing was made, so the same ring, refused above only for its tail,
      -- is made once the device allows it.
      limitBuffers standIn 300
      ok (createRing (rigRecording rig) (ringOf 256))
      (drop (length before) <$> placed rig) `shouldReturn` [256]
      clean rig

  describe "the storage table (R2D-15)" $ do
    it "makes set 2 once: its layout, its pool and its one set, whose descriptor covers the ring from offset zero over the window" $ do
      (rig, _, _) ← tableRig 4 2
      ok (createRingWith (rigRecording rig) (ringOf 4096) (Just (windowOf 1024)))
      before ← recordingCalls (rigRecordingStandIn rig)
      ok (createStorageTable (rigRecording rig))
      made ← drop (length before) <$> recordingCalls (rigRecordingStandIn rig)
      [request | CreatedSetLayout _ request ← made] `shouldBe` [StorageSetLayout]
      [request | CreatedPool _ request ← made] `shouldBe` [StoragePool]
      [count | AllocatedSet _ _ _ count ← made] `shouldBe` [Nothing]
      ringBuffer ← ringBufferHandle rig
      set ← case [set' | AllocatedSet set' _ _ _ ← made] of
        [only] → pure only
        other → fail ("expected one set, found " <> show other)
      [writes | WroteDescriptors writes ← made] `shouldBe` [[WriteStorageTable set ringBuffer 1024]]
      (atomically (readStorageTable (rigRecording rig)) <&> fmap (\view → (storageViewSet view, storageViewWindow view, length (storageViewObjects view)))) `shouldReturn` Just (set, 1024, 2)
      -- The table's two set layouts and pools, and set 2's.
      managedCount rig "table set layout" `shouldReturn` 3
      managedCount rig "table pool" `shouldReturn` 3
      createStorageTable (rigRecording rig) `shouldReturn'` refused (RefusedMisuse (DuplicateSubject ResourceIdentity))
      clean rig

    it "reads the ordinary storage-buffer limits from a device, whatever its update-after-bind counterparts are, which may legally be zero" $ do
      let limits = (zero ∷ PhysicalDeviceLimits) {maxDescriptorSetStorageBuffersDynamic = 4, maxPerStageDescriptorStorageBuffers = 12}
          noUpdateAfterBind = (zero ∷ PhysicalDeviceVulkan12Properties) {maxDescriptorSetUpdateAfterBindStorageBuffersDynamic = 0, maxPerStageDescriptorUpdateAfterBindStorageBuffers = 0}
          converted = recordingLimitsOf limits noUpdateAfterBind
      (limitDynamicStorageBuffers converted, limitStageStorageBuffers converted) `shouldBe` (4, 12)

    it "is made without the texture table, and refused with no ring or a ring made with no window" $ do
      bare ← newRig
      createStorageTable (rigRecording bare) `shouldReturn'` refused (RefusedIllegal "a storage table in a session that has made no ring")
      ok (createRing (rigRecording bare) (ringOf 256))
      createStorageTable (rigRecording bare) `shouldReturn'` refused (RefusedIllegal "a storage table over a ring made with no storage-table window")
      alone ← newRig
      ok (createRingWith (rigRecording alone) (ringOf 256) (Just (windowOf 64)))
      ok (createStorageTable (rigRecording alone))
      atomically (readTable (rigRecording alone)) `shouldReturn` Nothing
      clean alone

    it "checks the device's limits for the layouts that hold it first, naming each, and makes nothing" $ do
      (rig, _, _) ← tableRig 4 2
      ok (createRingWith (rigRecording rig) (ringOf 4096) (Just (windowOf 1024)))
      let standIn = rigRecordingStandIn rig
          limits = standInRecordingLimits {limitImageDimension = 16}
          refusedUnder changed = do
            limitRecording standIn changed
            answer ← createStorageTable (rigRecording rig)
            limitRecording standIn limits
            pure answer
      refusedUnder limits {limitBoundSets = 2} `shouldReturn'` refused (RefusedLimit "maxBoundDescriptorSets" 3 2)
      refusedUnder limits {limitDynamicStorageBuffers = 1} `shouldReturn'` refused (RefusedLimit "maxDescriptorSetStorageBuffersDynamic" 2 1)
      refusedUnder limits {limitStageStorageBuffers = 1} `shouldReturn'` refused (RefusedLimit "maxPerStageDescriptorStorageBuffers" 2 1)
      calls ← recordingCalls (rigRecordingStandIn rig)
      length [() | CreatedSetLayout _ StorageSetLayout ← calls] `shouldBe` 0
      length [() | CreatedPool _ StoragePool ← calls] `shouldBe` 0
      atomically (readStorageTable (rigRecording rig)) `shouldReturn` Nothing
      ok (createStorageTable (rigRecording rig))
      clean rig

    it "releases every generation it made when a step fails, publishes nothing, and can be made again" $ do
      (rig, _, _) ← tableRig 4 2
      ok (createRingWith (rigRecording rig) (ringOf 4096) (Just (windowOf 1024)))
      let standIn = rigRecordingStandIn rig
      failAt standIn AtCreatePool
      failed ← try @SomeException (createStorageTable (rigRecording rig))
      either (const True) (const False) failed `shouldBe` True
      atomically (readStorageTable (rigRecording rig)) `shouldReturn` Nothing
      -- The layout made before the pool was released at once.
      views ← atomically (readManaged (rigRecording rig))
      length [() | ManagedView _ ManagedReleased "table set layout" _ ← views] `shouldBe` 1
      succeedAt standIn AtCreatePool
      ok (createStorageTable (rigRecording rig))
      (atomically (readStorageTable (rigRecording rig)) <&> fmap storageViewWindow) `shouldReturn` Just 1024

  describe "layouts that hold set 2 (R2D-15)" $ do
    it "keeps the original constructors as the options form without set 2: the same set layouts and the same ranges" $ do
      (rig, _, _) ← storageRig 4096 1024
      let shapeOf calls = ([declared | DeclaredSetLayouts _ declared ← calls], [ranges | DeclaredRanges _ ranges ← calls])
          since from calls = shapeOf (drop (length from) calls)
          calls' = recordingCalls (rigRecordingStandIn rig)
      pushedBefore ← calls'
      ok (fmap (const ()) <$> createTablePipelineLayout (rigRecording rig) tableShaders 8)
      pushedMid ← calls'
      ok (fmap (const ()) <$> createTablePipelineLayoutWith (rigRecording rig) tableShaders (TableLayoutOptions (TablePushedSampler 8) False))
      pushedAfter ← calls'
      since pushedBefore pushedMid `shouldBe` since pushedMid pushedAfter
      ok (fmap (const ()) <$> createShaderSampledTablePipelineLayout (rigRecording rig) (sampledShadersWith [PushMember 0 16]))
      sampledMid ← calls'
      ok (fmap (const ()) <$> createTablePipelineLayoutWith (rigRecording rig) (sampledShadersWith [PushMember 0 16]) (TableLayoutOptions TableShaderSampler False))
      sampledAfter ← calls'
      since pushedAfter sampledMid `shouldBe` since sampledMid sampledAfter
      -- Without set 2 the layouts hold the table's two set layouts alone.
      fmap length (fst (since pushedBefore pushedMid)) `shouldBe` [2]
      clean rig

    it "declares set 2 after the table's two set layouts, admits its binding beside the table's and a pipeline over it" $ do
      (rig, _, _) ← storageRig 4096 1024
      calls ← recordingCalls (rigRecordingStandIn rig)
      -- The table's set 0 and set 1 layouts, then set 2's.
      let setLayouts = [handle | CreatedSetLayout handle _ ← calls]
      [request | CreatedSetLayout _ request ← calls] `shouldBe` [TextureSetLayout [h | CreatedSampler h _ ← calls] 16, LookupSetLayout, StorageSetLayout]
      layout ← createTablePipelineLayoutWith (rigRecording rig) storageShaders (TableLayoutOptions TableShaderSampler True) >>= either (fail . show) pure
      made ← recordingCalls (rigRecordingStandIn rig)
      [declared | DeclaredSetLayouts _ declared ← drop (length calls) made] `shouldBe` [setLayouts]
      -- A stage may declare the table's own bindings and set 2's together.
      both ← createTablePipelineLayoutWith (rigRecording rig) (storageShadersWith (textureTableDescriptors <> storageTableDescriptors)) (TableLayoutOptions TableShaderSampler True)
      either (fail . show) (const (pure ())) both
      ok (fmap (const ()) <$> createCheckedPipeline (rigRecording rig) layout storageShaders (formatCode Rgba8Srgb))
      -- Shaders that do not declare it are fine under it, too.
      ok (fmap (const ()) <$> createCheckedPipeline (rigRecording rig) layout sampledShaders (formatCode Rgba8Srgb))
      clean rig

    it "refuses a shader declaring set 2's binding under every other layout, with no native call" $ do
      (rig, _, _) ← storageRig 4096 1024
      before ← length . filter isLayout <$> recordingCalls (rigRecordingStandIn rig)
      createTablePipelineLayout (rigRecording rig) storageShaders 8
        `shouldReturn'` refused (RefusedIncompatible "a shader declaring a descriptor binding the texture table does not hold")
      createShaderSampledTablePipelineLayout (rigRecording rig) storageShaders
        `shouldReturn'` refused (RefusedIncompatible "a shader declaring a descriptor binding the texture table does not hold")
      createTablePipelineLayoutWith (rigRecording rig) storageShaders (TableLayoutOptions TableShaderSampler False)
        `shouldReturn'` refused (RefusedIncompatible "a shader declaring a descriptor binding the texture table does not hold")
      createPipelineLayoutFor (rigRecording rig) storageShaders
        `shouldReturn'` refused (RefusedUnsupported "a shader declaring descriptor bindings, which only a pipeline layout holding the texture table declares")
      -- A pipeline over a layout that does not hold it is refused the same way.
      tableOnly ← createShaderSampledTablePipelineLayout (rigRecording rig) sampledShaders >>= either (fail . show) pure
      createCheckedPipeline (rigRecording rig) tableOnly storageShaders (formatCode Rgba8Srgb)
        `shouldReturn'` refused (RefusedIncompatible "a shader declaring a descriptor binding the texture table does not hold")
      -- Set 2 is visible to both stages; only the table's set 0 is the
      -- fragment stage's alone, as it was.
      createTablePipelineLayoutWith (rigRecording rig) (storageShadersWith (storageTableDescriptors <> [DescriptorDeclaration 3 0 StorageBuffer (DescriptorCount 1)])) (TableLayoutOptions TableShaderSampler True)
        `shouldReturn'` refused (RefusedIncompatible "a shader declaring a descriptor binding the texture table and the storage table do not hold")
      after ← length . filter isLayout <$> recordingCalls (rigRecordingStandIn rig)
      -- Only the one table-only layout above was made.
      after - before `shouldBe` 1
      clean rig

    it "is refused with no storage table, and with no texture table first" $ do
      bare ← newRig
      createTablePipelineLayoutWith (rigRecording bare) storageShaders (TableLayoutOptions TableShaderSampler True)
        `shouldReturn'` refused (RefusedIllegal "a pipeline layout holding a texture table this session has not made")
      (rig, _, _) ← tableRig 4 2
      before ← length . filter isLayout <$> recordingCalls (rigRecordingStandIn rig)
      createTablePipelineLayoutWith (rigRecording rig) storageShaders (TableLayoutOptions TableShaderSampler True)
        `shouldReturn'` refused (RefusedIllegal "a pipeline layout holding a storage table this session has not made")
      after ← length . filter isLayout <$> recordingCalls (rigRecordingStandIn rig)
      after `shouldBe` before
      clean rig

    it "checks the device's limits across the whole layout, set 1 included, naming each before it creates one, and leaves the original layouts alone" $ do
      (rig, _, _) ← storageRig 4096 1024
      let standIn = rigRecordingStandIn rig
          limits = standInRecordingLimits {limitImageDimension = 16}
          under changed layouts = do
            limitRecording standIn changed
            answer ← layouts
            limitRecording standIn limits
            pure answer
          storageLayout = fmap (const ()) <$> createTablePipelineLayoutWith (rigRecording rig) storageShaders (TableLayoutOptions TableShaderSampler True)
          original = fmap (const ()) <$> createShaderSampledTablePipelineLayout (rigRecording rig) sampledShaders
      before ← length . filter isLayout <$> recordingCalls (rigRecordingStandIn rig)
      under limits {limitBoundSets = 2} storageLayout `shouldReturn'` refused (RefusedLimit "maxBoundDescriptorSets" 3 2)
      under limits {limitDynamicStorageBuffers = 1} storageLayout `shouldReturn'` refused (RefusedLimit "maxDescriptorSetStorageBuffersDynamic" 2 1)
      under limits {limitStageStorageBuffers = 1} storageLayout `shouldReturn'` refused (RefusedLimit "maxPerStageDescriptorStorageBuffers" 2 1)
      -- The table's cap of sixteen images, its four samplers and its two
      -- buffers are 22 resources in one stage; the table alone is 21.
      under limits {limitTableResources = 21} storageLayout `shouldReturn'` refused (RefusedLimit "maxPerStageUpdateAfterBindResources" 22 21)
      after ← length . filter isLayout <$> recordingCalls (rigRecordingStandIn rig)
      after `shouldBe` before
      -- The layouts that do not hold set 2 are checked as they always were.
      under limits {limitBoundSets = 2} original >>= either (fail . show) pure
      under limits {limitDynamicStorageBuffers = 1, limitStageStorageBuffers = 1, limitTableResources = 21} original >>= either (fail . show) pure
      under limits storageLayout >>= either (fail . show) pure
      clean rig

  describe "binding the storage table (R2D-15)" $ do
    it "binds set 2 alone at the claim's start plus the offset, leaving the table's sets and version offset as they stand, and draws with each table of a batch" $ do
      (rig, _, kit) ← storageRig 4096 1024
      pipeline ← storagePipeline rig TableShaderSampler storageShaders
      let setOf = atomically (readStorageTable (rigRecording rig)) >>= maybe (fail "no storage table") (pure . storageViewSet)
      answers ← framelessOnce rig $ \recorder → do
        first ← tableClaim recorder 64
        second ← tableClaim recorder 512
        ok (writeClaim recorder first 0 (fill 64))
        ok (writeClaim recorder second 0 (fill 512))
        inPassWith kit pipeline recorder $ do
          ok (bindTable recorder)
          bound ← bindStorageTable recorder first 0
          ok (draw recorder 3 1)
          offset ← bindStorageTable recorder second 256
          ok (draw recorder 3 1)
          pure [bound, offset]
      answers `shouldBe` [Right (), Right ()]
      set ← setOf
      starts ← claimStarts rig
      calls ← recordingCalls (rigRecordingStandIn rig)
      let commands' = [command | Recorded _ command ← calls]
          layoutHandle = last [handle | CreatedLayout handle ← calls]
      -- The first claim starts at zero, the second at the next multiple of
      -- the 256-byte storage alignment.
      starts `shouldBe` [0, 256]
      [(layout, bound, offset) | CommandBindStorageSet layout bound offset ← commands'] `shouldBe` [(layoutHandle, set, 0), (layoutHandle, set, 512)]
      -- The table's own bind is the only other, and only the one.
      [offsets | CommandBindDescriptorSets _ _ offsets ← commands'] `shouldBe` [[0]]
      length [() | CommandDraw {} ← commands'] `shouldBe` 2
      clean rig

    it "refuses with no native call: no pipeline, a layout that does not hold set 2, an offset past the claim, a table too big for the window, a misaligned offset, and a recorder that is closed" $ do
      (rig, _, kit) ← storageRig 4096 256
      pipeline ← storagePipeline rig TableShaderSampler storageShaders
      sampled ← sampledPipeline rig sampledShaders
      kept ← newIORef Nothing
      (refusals, native) ← framelessOnce rig $ \recorder → do
        big ← tableClaim recorder 512
        small ← tableClaim recorder 256
        writeIORef kept (Just (recorder, small))
        -- Each refusal is the only thing between two counts of commands.
        let counted bind = do
              before ← commandCount rig
              answer ← bind
              after ← commandCount rig
              pure (answer, after - before)
        noPipeline ← counted (bindStorageTable recorder small 0)
        ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 0 1))
        ok (bindPipeline recorder sampled)
        notHeld ← counted (bindStorageTable recorder small 0)
        ok (bindPipeline recorder pipeline)
        past ← counted (bindStorageTable recorder small 257)
        oversized ← counted (bindStorageTable recorder big 0)
        misaligned ← counted (bindStorageTable recorder small 4)
        -- The edges are not refused: the claim's end, and a table that is
        -- exactly the window.
        atEnd ← counted (bindStorageTable recorder small 256)
        exact ← counted (bindStorageTable recorder big 256)
        ok (endRendering recorder)
        pure ([noPipeline, notHeld, past, oversized, misaligned], [atEnd, exact])
      map fst refusals
        `shouldBe` [ Left (RefusedIllegal "binding the storage table with no pipeline bound")
                   , Left (RefusedIllegal "binding the storage table under a pipeline whose layout does not hold it")
                   , Left (RefusedOutOfBounds 257 256)
                   , Left (RefusedOutOfBounds 512 256)
                   , Left (RefusedIllegal "a storage table bound at an offset that is not a multiple of the device's storage-buffer offset alignment")
                   ]
      map snd refusals `shouldBe` replicate 5 0
      native `shouldBe` [(Right (), 1), (Right (), 1)]
      -- The recorder is closed once its action ends.
      Just (recorder, small) ← readIORef kept
      closedBefore ← commandCount rig
      bindStorageTable recorder small 0 `shouldReturn` Left RefusedRecorderClosed
      commandCount rig `shouldReturn` closedBefore
      clean rig

    it "refuses another session's claim, another batch's and a reclaimed one, each with no native call" $ do
      (rig, _, kit) ← storageRig 4096 256
      pipeline ← storagePipeline rig TableShaderSampler storageShaders
      -- A claim of a ring of another session.
      (foreignRig, _, _) ← storageRig 4096 256
      foreignClaim ← framelessOnce foreignRig (\recorder → tableClaim recorder 64)
      kept ← newIORef Nothing
      earlier ← framelessOnce rig $ \recorder → do
        claim ← tableClaim recorder 2048
        writeIORef kept (Just claim)
        pure ()
      earlier `shouldBe` ()
      Just claim ← readIORef kept
      -- Each bind is the only thing between the two counts of commands.
      let refusedBinding recorder held = do
            before ← commandCount rig
            answer ← bindStorageTable recorder held 0
            after ← commandCount rig
            pure (answer, after - before)
      elsewhere ← framelessOnce rig $ \recorder → do
        _ ← tableClaim recorder 64
        inPassWith kit pipeline recorder (refusedBinding recorder foreignClaim)
      elsewhere `shouldBe` (Left (RefusedMisuse (ForeignIdentity ResourceIdentity)), 0)
      other ← framelessOnce rig $ \recorder → do
        _ ← tableClaim recorder 64
        inPassWith kit pipeline recorder (refusedBinding recorder claim)
      other `shouldBe` (Left (RefusedMisuse (WrongParent BatchIdentity)), 0)
      -- Its batch completes; the next claim needs the whole ring, so the
      -- region is reclaimed and handed on.
      settleAll rig
      reused ← framelessOnce rig $ \recorder → do
        _ ← tableClaim recorder 4096
        inPassWith kit pipeline recorder (refusedBinding recorder claim)
      reused `shouldBe` (Left (RefusedMisuse (StaleIdentity ResourceIdentity)), 0)
      settleAll rig
      clean rig
      clean foreignRig

    it "refuses a dynamic offset past 32 bits before narrowing it, computing the claim's start plus the offset without overflow" $ do
      -- The byte budget (D-40) keeps every ring's bytes below 2^32, so no
      -- claim a bind can name reaches the boundary: the check is defensive,
      -- and its arithmetic is tested where it is made.
      let boundary = 2 ^ (32 ∷ Int) - 1
      map (uncurry storageDynamicOffset)
        [ (0, 0)
        , (boundary - 255, 255)
        , (boundary, 0)
        , (boundary, 1)
        , (2 ^ (32 ∷ Int), 0)
        , (2 ^ (64 ∷ Int) - 1, 2 ^ (64 ∷ Int) - 1)
        ]
        `shouldBe` [ Right 0
                   , Right 4294967295
                   , Right 4294967295
                   , Left (RefusedOutOfBounds (2 ^ (32 ∷ Int)) (2 ^ (32 ∷ Int) - 1))
                   , Left (RefusedOutOfBounds (2 ^ (32 ∷ Int)) (2 ^ (32 ∷ Int) - 1))
                   , Left (RefusedOutOfBounds (2 ^ (65 ∷ Int) - 2) (2 ^ (32 ∷ Int) - 1))
                   ]

    it "is refused once the session has failed, with no native call" $ do
      (rig, _, kit) ← storageRig 4096 256
      pipeline ← storagePipeline rig TableShaderSampler storageShaders
      bound ← newIORef Nothing
      _ ← try @SomeException $ withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope $ \recorder → do
          claim ← tableClaim recorder 64
          ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 0 1))
          ok (bindPipeline recorder pipeline)
          atomically (failRootsSessionBecause (rigRoots rig) CleanupFailed "a later cleanup failed")
          before ← commandCount rig
          answer ← bindStorageTable recorder claim 0
          after ← commandCount rig
          writeIORef bound (Just (answer, after - before))
      Just (answer, native) ← readIORef bound
      answer `shouldSatisfy` sessionFailed
      native `shouldBe` 0

  describe "drawing under a layout that holds set 2 (R2D-15)" $ do
    it "refuses a draw and an indexed draw before set 2 is bound, with no native call, and draws once it is" $ do
      (rig, _, kit) ← storageRig 4096 1024
      pipeline ← storagePipeline rig TableShaderSampler storageShaders
      answers ← framelessOnce rig $ \recorder → do
        table ← tableClaim recorder 64
        indices ← claimRegion recorder 6 2 >>= either (fail . show) pure
        ok (writeClaim recorder indices 0 (ByteString.pack [0, 0, 1, 0, 2, 0]))
        inPassWith kit pipeline recorder $ do
          unboundTable ← draw recorder 3 1
          ok (bindTable recorder)
          ok (bindIndexBuffer recorder (FromClaim indices 0) Index16)
          before ← commandCount rig
          unbound ← draw recorder 3 1
          unboundIndexed ← drawIndexed recorder 3 1
          after ← commandCount rig
          ok (bindStorageTable recorder table 0)
          ok (draw recorder 3 1)
          ok (drawIndexed recorder 3 1)
          pure ([unboundTable, unbound, unboundIndexed], after - before)
      fst answers
        `shouldBe` [ Left (RefusedIllegal "a draw with a pipeline holding the texture table before the table is bound under a compatible layout")
                   , Left (RefusedIllegal "a draw with a pipeline holding the storage table before it is bound under a compatible layout")
                   , Left (RefusedIllegal "a draw with a pipeline holding the storage table before it is bound under a compatible layout")
                   ]
      snd answers `shouldBe` 0
      calls ← recordingCalls (rigRecordingStandIn rig)
      length [() | Recorded _ CommandDraw {} ← calls] `shouldBe` 1
      length [() | Recorded _ CommandDrawIndexed {} ← calls] `shouldBe` 1
      clean rig

    it "keeps set 2 bound through the table's bind in either order and through a compatible pipeline switch, and needs it bound again after any other" $ do
      (rig, _, kit) ← storageRig 4096 1024
      first ← storagePipeline rig TableShaderSampler storageShaders
      second ← storagePipeline rig TableShaderSampler storageShaders
      withoutSet2 ← sampledPipeline rig sampledShaders
      sampledRanges ← storagePipeline rig TableShaderSampler (storageShadersRanged [PushMember 0 8, PushMember 8 4])
      pushedRanges ← storagePipeline rig (TablePushedSampler 8) (storageShadersRanged [PushMember 0 8, PushMember 8 4])
      let storageUnbound = Left (RefusedIllegal "a draw with a pipeline holding the storage table before it is bound under a compatible layout")
      answers ← framelessOnce rig $ \recorder → do
        table ← tableClaim recorder 64
        -- Set 2 first, then the table: the table's bind keeps set 2.
        orderOne ← inPassWith kit first recorder $ do
          ok (bindStorageTable recorder table 0)
          ok (bindTable recorder)
          draw recorder 3 1
        -- A compatible switch keeps both; a pipeline whose layout does not
        -- hold set 2 disturbs it alone, as the table is kept under equal ranges.
        switched ← inPassWith kit first recorder $ do
          ok (bindPipeline recorder second)
          kept <- draw recorder 3 1
          ok (bindPipeline recorder withoutSet2)
          ok (draw recorder 3 1)
          ok (bindPipeline recorder first)
          disturbed <- draw recorder 3 1
          ok (bindStorageTable recorder table 0)
          rebound <- draw recorder 3 1
          pure [kept, disturbed, rebound]
        -- A pushed pipeline of the same ranges is of another kind: it
        -- disturbs both, and a rebind of each is owed.
        kinds ← inPassWith kit sampledRanges recorder $ do
          ok (bindTable recorder)
          ok (bindStorageTable recorder table 0)
          ok (draw recorder 3 1)
          ok (bindPipeline recorder pushedRanges)
          ok (bindTable recorder)
          ok (selectSampler recorder 1)
          disturbed <- draw recorder 3 1
          ok (bindStorageTable recorder table 0)
          rebound <- draw recorder 3 1
          pure [disturbed, rebound]
        -- The table first, then set 2.
        orderTwo ← inPassWith kit first recorder $ do
          ok (bindTable recorder)
          ok (bindStorageTable recorder table 0)
          draw recorder 3 1
        pure (orderOne, switched, kinds, orderTwo)
      answers `shouldBe` (Right (), [Right (), storageUnbound, Right ()], [storageUnbound, Right ()], Right ())
      calls ← recordingCalls (rigRecordingStandIn rig)
      let commands' = [command | Recorded _ command ← calls]
      -- Five binds of set 2 were made, one for each that was owed.
      length [() | CommandBindStorageSet {} ← commands'] `shouldBe` 5
      clean rig

    it "retains set 2's layout and pool at the batch's first bind, the ring through its claims, and keeps them through a later claim and a rebind" $ do
      (rig, _, kit) ← storageRig 4096 1024
      pipeline ← storagePipeline rig TableShaderSampler storageShaders
      Just view ← atomically (readStorageTable (rigRecording rig))
      Just ring ← atomically (readRing (rigRecording rig))
      let holders = mapM (heldBy rig) (ringViewResource ring : storageViewObjects view)
      (beforeBind, afterBind, current) ← framelessOnce rig $ \recorder → do
        first ← tableClaim recorder 64
        beforeBind ← holders
        afterBind ← inPassWith kit pipeline recorder $ do
          ok (bindTable recorder)
          ok (bindStorageTable recorder first 0)
          holders
        pure (beforeBind, afterBind, recorderBatch recorder)
      -- The ring is held by the first claim; set 2's generations by the bind.
      beforeBind `shouldBe` [[current], [], []]
      afterBind `shouldBe` [[current], [current], [current]]
      -- A later claim and a rebind change nothing held.
      (final, again) ← framelessOnce rig $ \recorder → do
        first ← tableClaim recorder 64
        later ← tableClaim recorder 64
        final ← inPassWith kit pipeline recorder $ do
          ok (bindTable recorder)
          ok (bindStorageTable recorder first 0)
          ok (bindStorageTable recorder later 0)
          ok (bindStorageTable recorder first 0)
          holders
        pure (final, recorderBatch recorder)
      final `shouldBe` [[again], [again], [again]]
      settleAll rig
      clean rig

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

    it "keeps each superseded set's pool for exactly the batch that bound it, across successive growths: each retires independently, on its own batch's discard or completion, in any order" $ do
      -- Each pending batch holds a lookup version, so the ring has room.
      (rig, uploads, kit) ← tableRigWith 16 2 8
      textures ← mapM (const (uploadedTexture rig uploads)) [1 ∷ Int .. 8]
      let texture n = textures !! (n - 1)
          pools = (\calls → [pool | CreatedPool pool (TexturePool _ _) ← calls]) <$> recordingCalls (rigRecordingStandIn rig)
          disposed n = () <$ disposeResources (rigRecording rig) (at n)
      -- Batch A binds the first set, and is submitted and pending.
      _ ← registered rig (texture 1)
      set0 ← currentSet rig
      recordDrawing rig kit
      [fenceA] ← pendingFences (rigStandIn rig)
      -- The table grows; batch B binds the second set, submitted and pending.
      _ ← registered rig (texture 2)
      set1 ← currentSet rig
      recordDrawing rig kit
      [fenceB] ← filter (/= fenceA) <$> pendingFences (rigStandIn rig)
      -- The table grows again; batch C binds the third set, and the table
      -- grows a third time while C is still being recorded, which then
      -- discards it, unsubmitted.
      _ ← registered rig (texture 3)
      _ ← registered rig (texture 4)
      set2 ← currentSet rig
      discarded ← try @ErrorCall @() $ withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope $ \recorder → inPass kit recorder $ do
          ok (bindTable recorder)
          mapM_ (registered rig . texture) [5 .. 8]
        throwIO (ErrorCall "the consumer gave up")
      discarded `shouldBe` Left (ErrorCall "the consumer gave up")
      allocated rig `shouldReturn` 16
      set3 ← currentSet rig
      [pool0, pool1, pool2, pool3] ← pools
      bound ← recordingCalls (rigRecordingStandIn rig)
      [head' sets | Recorded _ (CommandBindDescriptorSets _ sets _) ← bound] `shouldBe` [set0, set1, set2]
      Set.size (Set.fromList [set0, set1, set2, set3]) `shouldBe` 4
      -- C's discard lets the third set's pool go; A and B still hold theirs.
      disposed 1
      destroyedPools rig >>= (`shouldSatisfy` \destroyed → pool2 `elem` destroyed && all (`notElem` destroyed) [pool0, pool1, pool3])
      -- B completes before A: the second set's pool goes, the first stays.
      completeFence (rigStandIn rig) fenceB
      _ ← progress rig
      disposed 2
      destroyedPools rig >>= (`shouldSatisfy` \destroyed → pool1 `elem` destroyed && all (`notElem` destroyed) [pool0, pool3])
      -- A completes: the first set's pool goes; the current one stays.
      completeFence (rigStandIn rig) fenceA
      _ ← progress rig
      disposed 3
      destroyedPools rig >>= (`shouldSatisfy` \destroyed → pool0 `elem` destroyed && pool3 `notElem` destroyed)
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

    it "destroys a failed growth's pool natively before raising — no reclamation pass ever sees it — and retries the whole growth once only after the pass reclaims something else; a second failure is not retried" $ do
      (rig, uploads, _) ← tableRigWith 8 2 2
      t1 ← uploadedTexture rig uploads
      t2 ← uploadedTexture rig uploads
      t3 ← uploadedTexture rig uploads
      t4 ← uploadedTexture rig uploads
      _ ← registered rig t1
      -- An unrelated released layout is the only thing a reclamation pass
      -- can dispose of.
      let unrelated = do
            layout ← createPipelineLayoutFor (rigRecording rig) plainShaders >>= either (fail . show) pure
            ok (releaseManaged (rigRecording rig) layout)
      unrelated
      mark ← length <$> recordingCalls (rigRecordingStandIn rig)
      outOfMemoryAt (rigRecordingStandIn rig) AtAllocateSet 1
      _ ← registered rig t2
      allocated rig `shouldReturn` 4
      grown ← drop mark <$> recordingCalls (rigRecordingStandIn rig)
      -- The failed attempt's pool is destroyed before the pass reclaims the
      -- layout, and both before the retry makes its pool.
      let indexed = zip [0 ∷ Int ..] grown
      case [(index, pool) | (index, CreatedPool pool (TexturePool _ _)) ← indexed] of
        [(made, failedPool), (retried, _)] → do
          let destroyedAt = [index | (index, DestroyedPool pool) ← indexed, pool == failedPool]
              reclaimedAt = [index | (index, DestroyedLayout _) ← indexed]
          destroyedAt `shouldSatisfy` \case
            [destroyed] → made < destroyed && all (destroyed <) reclaimedAt
            _ → False
          reclaimedAt `shouldSatisfy` \case
            [reclaimed] → reclaimed < retried
            _ → False
        other → expectationFailure ("expected two pools, a failed one and a retried one: " <> show other)
      -- Both allocations of the next growth fail: the retry is the only one.
      _ ← registered rig t3
      set1 ← currentSet rig
      unrelated
      mark' ← length <$> recordingCalls (rigRecordingStandIn rig)
      outOfMemoryAt (rigRecordingStandIn rig) AtAllocateSet 2
      raised ← try @AllocationNotRecovered (registerTexture (rigRecording rig) t4)
      fmap (const ()) raised `shouldSatisfy` either (const True) (const False)
      failed ← drop mark' <$> recordingCalls (rigRecordingStandIn rig)
      -- Two attempts, each pool destroyed natively before the next step.
      map (either (const 'c') (const 'd')) (poolSteps failed) `shouldBe` "cdcd"
      currentSet rig `shouldReturn` set1
      allocated rig `shouldReturn` 4
      clean rig

    it "names the grown set inside the growth's creation, so a naming that runs out of memory is rolled back natively before the pass and the single retry" $ do
      (rig, uploads, _) ← tableRigWith 8 2 2
      t1 ← uploadedTexture rig uploads
      t2 ← uploadedTexture rig uploads
      _ ← registered rig t1
      layout ← createPipelineLayoutFor (rigRecording rig) plainShaders >>= either (fail . show) pure
      ok (releaseManaged (rigRecording rig) layout)
      offerNaming (rigRootsStandIn rig)
      mark ← length <$> recordingCalls (rigRecordingStandIn rig)
      outOfMemoryNaming (rigRootsStandIn rig) ObjectDescriptorSet
      _ ← registered rig t2
      allocated rig `shouldReturn` 4
      grown ← drop mark <$> recordingCalls (rigRecordingStandIn rig)
      let indexed = zip [0 ∷ Int ..] grown
      case [(index, pool) | (index, CreatedPool pool (TexturePool _ _)) ← indexed] of
        [(made, failedPool), (retried, _)] → do
          let destroyedAt = [index | (index, DestroyedPool pool) ← indexed, pool == failedPool]
              reclaimedAt = [index | (index, DestroyedLayout _) ← indexed]
          destroyedAt `shouldSatisfy` \case
            [destroyed] → made < destroyed && all (destroyed <) reclaimedAt && destroyed < retried
            _ → False
          reclaimedAt `shouldSatisfy` \case
            [reclaimed] → reclaimed < retried
            _ → False
        other → expectationFailure ("expected two pools, a failed one and a retried one: " <> show other)
      clean rig

    it "raises an out of memory naming the grown pool, after its creation committed, as itself, with no recovery and no retry, leaving the current set" $ do
      (rig, uploads, _) ← tableRigWith 8 2 2
      t1 ← uploadedTexture rig uploads
      t2 ← uploadedTexture rig uploads
      _ ← registered rig t1
      layout ← createPipelineLayoutFor (rigRecording rig) plainShaders >>= either (fail . show) pure
      ok (releaseManaged (rigRecording rig) layout)
      set0 ← currentSet rig
      offerNaming (rigRootsStandIn rig)
      mark ← length <$> recordingCalls (rigRecordingStandIn rig)
      outOfMemoryNaming (rigRootsStandIn rig) ObjectDescriptorPool
      raised ← try @StandInResult (registerTexture (rigRecording rig) t2)
      fmap (const ()) raised `shouldSatisfy` either (const True) (const False)
      after ← drop mark <$> recordingCalls (rigRecordingStandIn rig)
      -- One attempt, and no reclamation pass reclaimed the layout.
      length [() | CreatedPool _ (TexturePool _ _) ← after] `shouldBe` 1
      [() | DestroyedLayout _ ← after] `shouldBe` []
      currentSet rig `shouldReturn` set0
      allocated rig `shouldReturn` 2
      _ ← registered rig t2
      allocated rig `shouldReturn` 4
      clean rig

    it "leaves the current set as it was, with no retry, when a growth's set allocation runs out of memory and nothing else is reclaimable" $ do
      (rig, uploads, _) ← tableRigWith 8 2 2
      t1 ← uploadedTexture rig uploads
      t2 ← uploadedTexture rig uploads
      _ ← registered rig t1
      set0 ← currentSet rig
      mark ← length <$> recordingCalls (rigRecordingStandIn rig)
      outOfMemoryAt (rigRecordingStandIn rig) AtAllocateSet 1
      raised ← try @AllocationNotRecovered (registerTexture (rigRecording rig) t2)
      fmap (const ()) raised `shouldSatisfy` either (const True) (const False)
      failed ← drop mark <$> recordingCalls (rigRecordingStandIn rig)
      map (either (const 'c') (const 'd')) (poolSteps failed) `shouldBe` "cd"
      currentSet rig `shouldReturn` set0
      allocated rig `shouldReturn` 2
      _ ← registered rig t2
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

  describe "swaps" $ do
    it "publishes a swap to an already uploaded replacement in the next version and releases the old texture then, which a batch recorded before the swap and submitted after it keeps sampling: the old texture is destroyed, and its slot reused, only once that batch completes" $ do
      (rig, uploads, kit) ← tableRig 4 2
      old ← uploadedTexture rig uploads
      replacement ← uploadedTexture rig uploads
      later ← uploadedTexture rig uploads
      handle ← registered rig old
      oldView ← viewOf rig old
      replacementView ← viewOf rig replacement
      oldSlot ← resolvedNow rig handle
      -- Recorded, then the swap requested, then submitted: the scope
      -- submits once its body returns.
      ticket ← withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope $ \recorder → inPass kit recorder $ do
          ok (bindTable recorder)
          ok (selectSampler recorder 0)
          ok (draw recorder 3 1)
        swapped rig handle replacement
      swapStanding ticket `shouldReturn` SwapPending
      resolvedNow rig handle `shouldReturn` oldSlot
      ok (refreshTextureTable (rigRecording rig))
      swapStanding ticket `shouldReturn` SwapPublished
      newSlot ← resolvedNow rig handle
      newSlot `shouldSatisfy` (`notElem` [0, oldSlot])
      imageWrites rig >>= (`shouldSatisfy` elem (newSlot, replacementView))
      -- Released at publication, not destroyed: the earlier batch retains
      -- the old texture, and its slot still retires.
      standing rig old `shouldReturn` Just ManagedReleased
      _ ← disposeResources (rigRecording rig) (at 1)
      standing rig old `shouldReturn` Just ManagedReleased
      Just afterSwap ← atomically (readTable (rigRecording rig))
      tableViewRetiring afterSwap `shouldBe` [oldSlot]
      -- A later batch binds a new version, which maps the replacement.
      recordDrawing rig kit
      calls ← recordingCalls (rigRecordingStandIn rig)
      [offset | Recorded _ (CommandBindDescriptorSets _ _ [offset]) ← calls] `shouldBe` [0, 256]
      writes ← imageWrites rig
      [element | (element, view) ← writes, view == oldView] `shouldBe` [oldSlot]
      [() | (element, _) ← writes, element == oldSlot] `shouldBe` [()]
      -- Once the earlier batch completes, the old texture is destroyed and
      -- its slot reused.
      completed rig
      ok (refreshTextureTable (rigRecording rig))
      _ ← disposeResources (rigRecording rig) (at 2)
      standing rig old `shouldReturn` Nothing
      _ ← registered rig later
      (lastOf <$> writtenSlots rig) `shouldReturn` oldSlot
      clean rig

    it "keeps a swapped handle on its current image — never the placeholder — until the replacement's upload completes, growing the table for the replacement's slot, and then publishes a replacement of another format, extent and mip count" $ do
      (rig, uploads, kit) ← tableRigWith 16 2 2
      old ← uploadedTexture rig uploads
      handle ← registered rig old
      oldSlot ← resolvedNow rig handle
      (replacement, upload) ← queuedTexture rig uploads (ImageDescription TextureImage Rgba8Srgb 4 4 3) [ByteString.replicate 64 7, ByteString.replicate 16 7, ByteString.replicate 4 7]
      ticket ← swapped rig handle replacement
      -- No slot was free: the table grew for the replacement.
      allocated rig `shouldReturn` 4
      ok (refreshTextureTable (rigRecording rig))
      swapStanding ticket `shouldReturn` SwapPending
      resolvedNow rig handle `shouldReturn` oldSlot
      Just pending ← atomically (readTable (rigRecording rig))
      [(swappedHandle, image) | (swappedHandle, _, image) ← tableViewSwaps pending] `shouldBe` [(handle, managedResource replacement)]
      recordDrawing rig kit
      settle rig uploads
      atomically (readUploadTicket upload) `shouldReturn` UploadComplete
      ok (refreshTextureTable (rigRecording rig))
      swapStanding ticket `shouldReturn` SwapPublished
      resolvedNow rig handle >>= (`shouldSatisfy` (`notElem` [0, oldSlot]))
      clean rig

    it "supersedes a pending swap with a later one: a replacement whose upload had not started is cancelled and released, one whose upload had started is released and destroyed once it finishes, and neither is ever written or shown" $ do
      (rig, uploads, _) ← tableRig 4 2
      old ← uploadedTexture rig uploads
      last' ← uploadedTexture rig uploads
      handle ← registered rig old
      oldSlot ← resolvedNow rig handle
      (unstarted, unstartedUpload) ← queuedTexture rig uploads (ImageDescription TextureImage Rgba8Linear 2 2 1) [ByteString.replicate 16 1]
      unstartedView ← viewOf rig unstarted
      first ← swapped rig handle unstarted
      (started, startedUpload) ← queuedTexture rig uploads (ImageDescription TextureImage Rgba8Linear 2 2 1) [ByteString.replicate 16 2]
      startedView ← viewOf rig started
      second ← swapped rig handle started
      swapStanding first `shouldReturn` SwapSuperseded
      standing rig unstarted `shouldReturn` Just ManagedReleased
      -- The next turn cancels the released, unstarted upload and starts the
      -- other, which then may not be cancelled.
      _ ← progressUploads uploads >>= either (fail . show) pure
      atomically (readUploadTicket unstartedUpload) `shouldReturn` UploadCancelled
      atomically (readUploadTicket startedUpload) `shouldReturn` UploadUploading
      third ← swapped rig handle last'
      swapStanding second `shouldReturn` SwapSuperseded
      standing rig started `shouldReturn` Just ManagedReleased
      ok (refreshTextureTable (rigRecording rig))
      swapStanding third `shouldReturn` SwapPublished
      resolvedNow rig handle >>= (`shouldSatisfy` (`notElem` [0, oldSlot]))
      -- The started upload finishes; then its target is destroyed with the
      -- cancelled one, and neither was ever written.
      settle rig uploads
      atomically (readUploadTicket startedUpload) `shouldReturn` UploadComplete
      ok (refreshTextureTable (rigRecording rig))
      _ ← disposeResources (rigRecording rig) (at 1)
      standing rig unstarted `shouldReturn` Nothing
      standing rig started `shouldReturn` Nothing
      writes ← imageWrites rig
      [() | (_, view) ← writes, view `elem` [unstartedView, startedView]] `shouldBe` []
      clean rig

    it "ends a pending swap with its handle: the replacement is released, never written, and its upload's later completion publishes nothing, even once the handle's index is issued again" $ do
      (rig, uploads, _) ← tableRig 4 2
      old ← uploadedTexture rig uploads
      next ← uploadedTexture rig uploads
      handle ← registered rig old
      (replacement, upload) ← queuedTexture rig uploads (ImageDescription TextureImage Rgba8Linear 2 2 1) [ByteString.replicate 16 3]
      replacementView ← viewOf rig replacement
      -- Started, so it cannot be cancelled.
      _ ← progressUploads uploads >>= either (fail . show) pure
      atomically (readUploadTicket upload) `shouldReturn` UploadUploading
      ticket ← swapped rig handle replacement
      ok (releaseTexture (rigRecording rig) handle)
      swapStanding ticket `shouldReturn` SwapAbandoned
      standing rig replacement `shouldReturn` Just ManagedReleased
      reissued ← registered rig next
      handleIndex reissued `shouldBe` handleIndex handle
      settle rig uploads
      atomically (readUploadTicket upload) `shouldReturn` UploadComplete
      ok (refreshTextureTable (rigRecording rig))
      swapStanding ticket `shouldReturn` SwapAbandoned
      Just view ← atomically (readTable (rigRecording rig))
      tableViewSwaps view `shouldBe` []
      writes ← imageWrites rig
      [() | (_, written) ← writes, written == replacementView] `shouldBe` []
      _ ← disposeResources (rigRecording rig) (at 1)
      standing rig replacement `shouldReturn` Nothing
      clean rig

    it "leaves the handle on its current image and reports the failure when the replacement's upload is cancelled, releasing the replacement; the handle then accepts another swap" $ do
      (rig, uploads, _) ← tableRig 4 2
      old ← uploadedTexture rig uploads
      handle ← registered rig old
      oldSlot ← resolvedNow rig handle
      (replacement, upload) ← queuedTexture rig uploads (ImageDescription TextureImage Rgba8Linear 2 2 1) [ByteString.replicate 16 4]
      ticket ← swapped rig handle replacement
      atomically (cancelUpload uploads upload) >>= either (fail . show) pure
      ok (refreshTextureTable (rigRecording rig))
      swapStanding ticket `shouldReturn` SwapFailed
      resolvedNow rig handle `shouldReturn` oldSlot
      standing rig replacement `shouldReturn` Just ManagedReleased
      Just view ← atomically (readTable (rigRecording rig))
      tableViewSwaps view `shouldBe` []
      again ← uploadedTexture rig uploads
      retried ← swapped rig handle again
      ok (refreshTextureTable (rigRecording rig))
      swapStanding retried `shouldReturn` SwapPublished
      clean rig

    it "refuses another upload into a pending swap's replacement once its accepted upload is cancelled, so the cancellation fails the swap and the handle keeps its image" $ do
      (rig, uploads, _) ← tableRig 4 2
      old ← uploadedTexture rig uploads
      handle ← registered rig old
      oldSlot ← resolvedNow rig handle
      (replacement, first) ← queuedTexture rig uploads (ImageDescription TextureImage Rgba8Linear 2 2 1) [ByteString.replicate 16 6]
      ticket ← swapped rig handle replacement
      atomically (cancelUpload uploads first) >>= either (fail . show) pure
      -- Between owner turns, before any refresh: the same image again.
      submitUpload uploads (UploadImage replacement [ByteString.replicate 16 7]) `shouldReturn'` \case
        Left (UploadMisuse (WrongPhase ResourceIdentity)) → pure ()
        other → expectationFailure ("expected the re-upload refused, not " <> either show (const "admitted") other)
      settle rig uploads
      ok (refreshTextureTable (rigRecording rig))
      swapStanding ticket `shouldReturn` SwapFailed
      resolvedNow rig handle `shouldReturn` oldSlot
      clean rig

    it "fails a pending swap the moment the session fails, before any refresh, drain or retirement, and keeps it failed through retirement" $ do
      (rig, uploads, _) ← tableRig 4 2
      old ← uploadedTexture rig uploads
      handle ← registered rig old
      (replacement, _) ← queuedTexture rig uploads (ImageDescription TextureImage Rgba8Linear 2 2 1) [ByteString.replicate 16 8]
      ticket ← swapped rig handle replacement
      swapStanding ticket `shouldReturn` SwapPending
      atomically (failRootsSessionBecause (rigRoots rig) CleanupFailed "a later cleanup failed")
      swapStanding ticket `shouldReturn` SwapFailed
      _ ← try @ResourcesRetained (retireRecording (rigRecording rig) (at 1))
      swapStanding ticket `shouldReturn` SwapFailed

    it "never publishes a swap whose replacement's upload the device's loss ended, and fails it" $ do
      (rig, uploads, _) ← tableRig 4 2
      old ← uploadedTexture rig uploads
      handle ← registered rig old
      oldSlot ← resolvedNow rig handle
      (replacement, upload) ← queuedTexture rig uploads (ImageDescription TextureImage Rgba8Linear 2 2 1) [ByteString.replicate 16 9]
      replacementView ← viewOf rig replacement
      -- Started: its copies are submitted when the device is lost.
      _ ← progressUploads uploads >>= either (fail . show) pure
      ticket ← swapped rig handle replacement
      -- Observing the upload's fence loses the device.
      loseFrameStep (rigStandIn rig) AtQueryFence
      _ ← try @SomeException (progress rig)
      _ ← try @SomeException (progressUploads uploads)
      _ ← try @SomeException (refreshTextureTable (rigRecording rig))
      -- The loss ended the upload, and the refresh after it, which may write
      -- nothing, failed the swap.
      atomically (readUploadTicket upload) `shouldReturn` UploadLost
      swapStanding ticket `shouldReturn` SwapFailed
      _ ← try @SomeException (retireRecording (rigRecording rig) (at 1))
      swapStanding ticket `shouldReturn` SwapFailed
      resolvedNow rig handle `shouldReturn` oldSlot
      writes ← imageWrites rig
      [() | (_, written) ← writes, written == replacementView] `shouldBe` []

    it "keeps a failure it reported: a swap read failed once the session fails stays failed when its handle is then released before retirement" $ do
      (rig, uploads, _) ← tableRig 4 2
      old ← uploadedTexture rig uploads
      handle ← registered rig old
      (replacement, _) ← queuedTexture rig uploads (ImageDescription TextureImage Rgba8Linear 2 2 1) [ByteString.replicate 16 10]
      ticket ← swapped rig handle replacement
      atomically (failRootsSessionBecause (rigRoots rig) CleanupFailed "a later cleanup failed")
      swapStanding ticket `shouldReturn` SwapFailed
      ok (releaseTexture (rigRecording rig) handle)
      swapStanding ticket `shouldReturn` SwapFailed
      _ ← try @ResourcesRetained (retireRecording (rigRecording rig) (at 1))
      swapStanding ticket `shouldReturn` SwapFailed

    it "keeps a success it reported: a published swap stays published when the session then fails, its handle is released and the recording retires" $ do
      (rig, uploads, _) ← tableRig 4 2
      old ← uploadedTexture rig uploads
      replacement ← uploadedTexture rig uploads
      handle ← registered rig old
      ticket ← swapped rig handle replacement
      ok (refreshTextureTable (rigRecording rig))
      swapStanding ticket `shouldReturn` SwapPublished
      atomically (failRootsSessionBecause (rigRoots rig) CleanupFailed "a later cleanup failed")
      swapStanding ticket `shouldReturn` SwapPublished
      ok (releaseTexture (rigRecording rig) handle)
      _ ← try @ResourcesRetained (retireRecording (rigRecording rig) (at 1))
      swapStanding ticket `shouldReturn` SwapPublished

    it "publishes nothing when the session fails during the replacement's descriptor write: the handle keeps its image, the old texture stays held, and the swap fails" $ do
      (rig, uploads, _) ← tableRig 4 2
      old ← uploadedTexture rig uploads
      replacement ← uploadedTexture rig uploads
      handle ← registered rig old
      oldSlot ← resolvedNow rig handle
      replacementView ← viewOf rig replacement
      ticket ← swapped rig handle replacement
      -- The failure is latched from inside the write of the replacement's
      -- descriptor, as a diagnostic failure from another thread can be.
      duringWrite (rigRecordingStandIn rig) $ \writes →
        when (any (\case WriteSampledImage _ _ view → view == replacementView; _ → False) writes) $
          atomically (failRootsSessionBecause (rigRoots rig) CleanupFailed "failed during the descriptor's write")
      _ ← refreshTextureTable (rigRecording rig)
      imageWrites rig >>= (`shouldSatisfy` any ((== replacementView) . snd))
      swapStanding ticket `shouldReturn` SwapFailed
      resolvedNow rig handle `shouldReturn` oldSlot
      standing rig old `shouldReturn` Just ManagedLive

    it "refuses a swap that cannot be made — a stale handle, an image the table already holds, one no upload fills, one that is no texture, and a table full at its cap — changing neither the mapping nor a pending swap, and leaving the image the caller's" $ do
      -- Four slots, all the cap allows: slot 0, two textures and a pending
      -- replacement.
      (rig, uploads, _) ← tableRigWith 4 4 2
      old ← uploadedTexture rig uploads
      other ← uploadedTexture rig uploads
      spare ← uploadedTexture rig uploads
      handle ← registered rig old
      otherHandle ← registered rig other
      (pending, _) ← queuedTexture rig uploads (ImageDescription TextureImage Rgba8Linear 2 2 1) [ByteString.replicate 16 5]
      _ ← swapped rig handle pending
      Just before ← atomically (readTable (rigRecording rig))
      fresh ← createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Linear 2 2 1) >>= either (fail . show) pure
      target ← createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Srgb 2 2 1) >>= either (fail . show) pure
      swapTexture (rigRecording rig) (TextureHandle 9 1) spare `shouldReturn'` refused (RefusedStaleHandle (TextureHandle 9 1))
      swapTexture (rigRecording rig) otherHandle old `shouldReturn'` refused (RefusedMisuse (DuplicateSubject ResourceIdentity))
      swapTexture (rigRecording rig) otherHandle pending `shouldReturn'` refused (RefusedMisuse (DuplicateSubject ResourceIdentity))
      swapTexture (rigRecording rig) otherHandle fresh `shouldReturn'` \case
        Left (RefusedNotWritten _) → pure ()
        _ → expectationFailure "expected RefusedNotWritten"
      swapTexture (rigRecording rig) otherHandle target `shouldReturn'` refused RefusedWrongKind
      swapTexture (rigRecording rig) otherHandle spare `shouldReturn'` refused (RefusedBackpressure TextureSlotBudget)
      Just after ← atomically (readTable (rigRecording rig))
      tableViewMapping after `shouldBe` tableViewMapping before
      tableViewSwaps after `shouldBe` tableViewSwaps before
      standing rig spare `shouldReturn` Just ManagedLive
      -- The caller still owns it: releasing it directly is not refused.
      ok (releaseManaged (rigRecording rig) spare)
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

-- | A fragment stage reading the table whose sampler the shaders choose: it
-- declares no push constants.
sampledShaders ∷ CheckedShaders
sampledShaders = sampledShadersWith []

-- | 'sampledShaders' with a fragment push-constant block of these members.
sampledShadersWith ∷ [PushMember] → CheckedShaders
sampledShadersWith = sampledWith textureTableDescriptors

sampledWith ∷ [DescriptorDeclaration] → [PushMember] → CheckedShaders
sampledWith descriptors members =
  CheckedShaders
    (CheckedShader (ByteString.pack [1, 2, 3, 4]) (interfaceFor VertexInterface))
    (CheckedShader (ByteString.pack [5, 6, 7, 8]) (interfaceFor FragmentInterface) {interfacePushConstants = members, interfaceDescriptors = descriptors})

-- | 'sampledShaders' with this vertex stage's descriptors.
sampledVertexDeclaring ∷ [DescriptorDeclaration] → CheckedShaders
sampledVertexDeclaring descriptors =
  CheckedShaders
    (CheckedShader (ByteString.pack [1, 2, 3, 4]) (interfaceFor VertexInterface) {interfaceDescriptors = descriptors})
    (CheckedShader (ByteString.pack [5, 6, 7, 8]) (interfaceFor FragmentInterface) {interfaceDescriptors = textureTableDescriptors})

-- | A pipeline over a shader-sampled layout for these shaders.
sampledPipeline ∷ Rig → CheckedShaders → IO Pipeline
sampledPipeline rig shaders = do
  layout ← createShaderSampledTablePipelineLayout (rigRecording rig) shaders >>= either (fail . show) pure
  createCheckedPipeline (rigRecording rig) layout shaders (formatCode Rgba8Srgb) >>= either (fail . show) pure

plainShaders ∷ CheckedShaders
plainShaders =
  CheckedShaders
    (CheckedShader (ByteString.pack [1, 2, 3, 4]) (interfaceFor VertexInterface))
    (CheckedShader (ByteString.pack [5, 6, 7, 8]) (interfaceFor FragmentInterface))

inPass ∷ Kit → Rec → IO a → IO a
inPass kit = inPassWith kit (kitPipeline kit)

-- | 'inPass' over this pipeline instead of the kit's.
inPassWith ∷ Kit → Pipeline → Rec → IO a → IO a
inPassWith kit pipeline recorder action = do
  ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 0 1))
  ok (bindPipeline recorder pipeline)
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
-- The storage table (R2D-15)

ringOf ∷ Integer → RingSize
ringOf = either (error . show) id . validateRingSize

windowOf ∷ Integer → StorageWindow
windowOf = either (error . show) id . validateStorageWindow

-- | A session with a table, a ring of this many bytes made with a storage
-- window of this many, the storage table, and a kit to draw with.
storageRig ∷ Integer → Integer → IO (Rig, Ups, Kit)
storageRig ring window = do
  (rig, uploads, kit) ← tableRig 4 2
  ok (createRingWith (rigRecording rig) (ringOf ring) (Just (windowOf window)))
  ok (createStorageTable (rigRecording rig))
  pure (rig, uploads, kit)

-- | Shaders whose stages declare set 2's binding and nothing else, and no
-- push constants.
storageShaders ∷ CheckedShaders
storageShaders = storageShadersWith storageTableDescriptors

-- | A fragment stage declaring these bindings and a vertex stage declaring
-- those of them in set 2.
storageShadersWith ∷ [DescriptorDeclaration] → CheckedShaders
storageShadersWith descriptors = storageShadersDeclaring descriptors []

-- | 'storageShaders' with a fragment push-constant block of these members.
storageShadersRanged ∷ [PushMember] → CheckedShaders
storageShadersRanged = storageShadersDeclaring storageTableDescriptors

storageShadersDeclaring ∷ [DescriptorDeclaration] → [PushMember] → CheckedShaders
storageShadersDeclaring descriptors members =
  CheckedShaders
    (CheckedShader (ByteString.pack [1, 2, 3, 4]) (interfaceFor VertexInterface) {interfaceDescriptors = filter ((== 2) . descriptorSet) descriptors})
    (CheckedShader (ByteString.pack [5, 6, 7, 8]) (interfaceFor FragmentInterface) {interfacePushConstants = members, interfaceDescriptors = descriptors})

-- | A pipeline over a layout that holds set 2, for these shaders.
storagePipeline ∷ Rig → TableUse → CheckedShaders → IO Pipeline
storagePipeline rig use shaders = do
  layout ← createTablePipelineLayoutWith (rigRecording rig) shaders (TableLayoutOptions use True) >>= either (fail . show) pure
  createCheckedPipeline (rigRecording rig) layout shaders (formatCode Rgba8Srgb) >>= either (fail . show) pure

tableClaim ∷ Rec → Natural → IO RingClaim
tableClaim recorder size = claimTable recorder size >>= either (fail . ("the claim was refused: " <>) . show) pure

fill ∷ Int → ByteString.ByteString
fill count = ByteString.replicate count 0x5A

-- | Where every region of the ring a batch holds starts, in claim order.
claimStarts ∷ Rig → IO [Natural]
claimStarts rig =
  atomically (readRing (rigRecording rig)) >>= \case
    Just ring → pure [claimRecordOffset record | (_, record) ← ringViewClaims ring]
    Nothing → fail "the ring was not made"

-- | The ring buffer's native handle.
ringBufferHandle ∷ Rig → IO Word64
ringBufferHandle rig = do
  Just ring ← atomically (readRing (rigRecording rig))
  views ← atomically (readManaged (rigRecording rig))
  case [handle | ManagedView resource _ _ (handle : _) ← views, resource == ringViewResource ring] of
    handle : _ → pure handle
    [] → fail "the ring has no native handle"

-- | The size of every allocation the allocator was asked to place, in order
-- (each once, however many placements its attempts made).
placed ∷ Rig → IO [Natural]
placed rig = (\calls → nub [size | Placing size _ _ ← calls]) <$> allocatorCalls (standAllocator (rigRootsStandIn rig))

isLayout ∷ RecordingCall → Bool
isLayout = \case
  CreatedLayout _ → True
  _ → False

-- | The batches that hold this resource while they record.
heldBy ∷ Rig → ResourceId → IO [BatchId]
heldBy rig resource = (\model → maybe [] viewRecorded (holdView (ResourceSubject resource) (model ∷ GpuModel))) <$> atomically (readRootsModel (rigRoots rig))

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

-- | In order: each set 0 pool these calls made ('Left') and each of those
-- they destroyed ('Right').
poolSteps ∷ [RecordingCall] → [Either Word64 Word64]
poolSteps calls =
  [ step
  | call ← calls
  , step ← case call of
      CreatedPool pool (TexturePool _ _) → [Left pool]
      DestroyedPool pool | pool `Set.member` made → [Right pool]
      _ → []
  ]
  where
    made = Set.fromList [pool | CreatedPool pool (TexturePool _ _) ← calls]

-- | Every descriptor pool destroyed so far.
destroyedPools ∷ Rig → IO [Word64]
destroyedPools rig = (\calls → [pool | DestroyedPool pool ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

-- | How many set 0 pools were asked for so far, made or not.
poolAttempts ∷ Rig → IO Int
poolAttempts rig = (\calls → length [() | CreatedPool _ (TexturePool _ _) ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

-- | Swap the handle's texture, requiring the swap's acceptance.
swapped ∷ Rig → TextureHandle → Image → IO SwapTicket
swapped rig handle texture = swapTexture (rigRecording rig) handle texture >>= either (fail . show) pure

-- | Where a swap stands now.
swapStanding ∷ SwapTicket → IO SwapState
swapStanding = atomically . readSwapTicket

-- | The slot a version published now would resolve the handle to.
resolvedNow ∷ Rig → TextureHandle → IO Word32
resolvedNow rig handle =
  atomically (readTable (rigRecording rig)) <&> \case
    Just view → resolveHandle maxBound (tableViewMapping view) handle
    Nothing → 0

-- | A texture of this description whose upload is admitted and not yet
-- progressed, and the upload's ticket.
queuedTexture ∷ Rig → Ups → ImageDescription → [ByteString.ByteString] → IO (Image, UploadTicket)
queuedTexture rig uploads description levels = do
  texture ← createImage (rigRecording rig) description >>= either (fail . show) pure
  ticket ← submitUpload uploads (UploadImage texture levels) >>= either (fail . show) pure
  pure (texture, ticket)

lastOf ∷ [a] → a
lastOf = head' . reverse

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
