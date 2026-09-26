-- | Managed-resource construction and release for the managed recording
-- ("Hetoimasia.GPU.Vulkan.Native.Recording"): pipeline layouts, pipelines and
-- their replacements, frame storages and readback buffers, each made in one
-- masked step that reserves the model's accounting, makes the native object,
-- turns the reservation into a managed generation and names that generation
-- before its handle is returned; and 'releaseManaged', which ends a handle's
-- use.
--
-- This module inserts managed records and frame storages into the recording's
-- state ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State") and advances
-- a record to released or replaced; it owns no state of its own. Destroying a
-- released generation is the disposal's ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Disposal"),
-- except for an object the model refused to record, which nothing can
-- reference and which is destroyed here at once.
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Construction
  ( createPipelineLayout
  , createPipeline
  , replacePipeline
  , createFrameStorage
  , createReadback
  , releaseManaged
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVarIO)
import Control.Exception (SomeException, mask_, rethrowIO, tryWithContext)
import Data.ByteString (ByteString)
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model
  ( Outcome (..)
  , TargetPhase (..)
  , TargetView (..)
  , abandonAllocation
  , beginAllocation
  , createResource
  , endResourceCpuUse
  , modelBudgets
  , rebuildResource
  , recordAllocationFailure
  , releaseResource
  )
import qualified Hetoimasia.GPU.Model as Model
import Hetoimasia.GPU.Model.Budget (frameSlotLimit)
import Hetoimasia.GPU.Model.Identity (IdentityKind (..), Misuse (..), ResourceId, TargetId, targetSession)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer
  ( PipelineRequest (..)
  , PipelineShaders
  , ReadbackAllocation (..)
  , RecordingOps (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( Managed (..)
  , ManagedRecord (..)
  , ManagedStanding (..)
  , NativeResource (..)
  , Pipeline (..)
  , PipelineLayout (..)
  , FrameStorage (..)
  , Readback (..)
  , ReadbackContents (..)
  , Recording (..)
  , Refusal (..)
  , destroyNative
  , editManaged
  , liveNative
  , modelAnswer
  , modelEdit
  , owned
  )
import Hetoimasia.GPU.Vulkan.Native.Naming
  ( NativeObjectKind (..)
  , ShaderStage
  , commandBufferName
  , commandPoolName
  , pipelineLayoutName
  , pipelineName
  , readbackBufferName
  , readbackMemoryName
  , shaderModuleName
  )
import Hetoimasia.GPU.Vulkan.Native.Profile (DevicePlan (..))
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( nameRootsObject
  , readRootsDevice
  , readRootsInstrumentation
  , rootsCall
  , rootsSessionIdentity
  , stateRootsModel
  )

-- | A pipeline layout with no descriptor sets and no push constants.
createPipelineLayout ∷ Recording q inst msgr phys dev cmd → IO (Either Refusal PipelineLayout)
createPipelineLayout recording =
  fmap PipelineLayout
    <$> construct recording 0 1 "vkCreatePipelineLayout" (\ops device _ → NativeLayout <$> opsCreatePipelineLayout ops device) Nothing

-- | A graphics pipeline over the layout, rendering to the color format. The
-- layout must be live; the pipeline depends on that exact generation, which
-- every batch binding the pipeline retains with it.
createPipeline
  ∷ Recording q inst msgr phys dev cmd → PipelineLayout → PipelineShaders → Word32 → IO (Either Refusal Pipeline)
createPipeline recording layout shaders format = buildPipeline recording layout shaders format Nothing

-- | Publish a new generation of a pipeline, over the given layout. The old
-- generation is released: nothing records it again, and every batch that
-- recorded it keeps it, and its layout, until the batch's references end.
replacePipeline
  ∷ Recording q inst msgr phys dev cmd → Pipeline → PipelineLayout → PipelineShaders → Word32 → IO (Either Refusal Pipeline)
replacePipeline recording (Pipeline old) layout shaders format = buildPipeline recording layout shaders format (Just old)

buildPipeline
  ∷ Recording q inst msgr phys dev cmd
  → PipelineLayout
  → PipelineShaders
  → Word32
  → Maybe ResourceId
  → IO (Either Refusal Pipeline)
buildPipeline recording (PipelineLayout layout) shaders format replacing =
  liveNative recording layout >>= \case
    Left refusal → pure (Left refusal)
    Right (NativeLayout handle) →
      fmap Pipeline
        <$> construct
          recording
          0
          1
          "vkCreateGraphicsPipelines"
          ( \ops device issued → do
              naming ← shaderNaming recording issued
              (\created → NativePipeline created layout format) <$> opsCreatePipeline ops device (PipelineRequest handle shaders format) naming
          )
          replacing
    Right _ → pure (Left RefusedWrongKind)

-- | A frame slot's command storage: a pool on the session's queue family and
-- its one primary command buffer. A slot has at most one; 'recordFrame'
-- records every frame of that slot into it.
--
-- The target must be one of this session's, still admitted or suspended, and
-- the slot one its frame budget can issue; anything else is refused before
-- any native call.
createFrameStorage ∷ Recording q inst msgr phys dev cmd → TargetId → Natural → IO (Either Refusal FrameStorage)
createFrameStorage recording target slot = do
  existing ← Map.lookup (target, slot) <$> readTVarIO (recordingStorages recording)
  model ← atomically (stateRootsModel (recordingRoots recording) (\current → (current, current)))
  let limit = frameSlotLimit (modelBudgets model)
      unusable = case Model.targetView target model of
        _ | targetSession target /= rootsSessionIdentity (recordingRoots recording) → Just (RefusedMisuse (ForeignIdentity TargetIdentity))
        Nothing → Just (RefusedMisuse (StaleIdentity TargetIdentity))
        Just view
          | viewTargetPhase view `notElem` [TargetAdmitted, TargetSuspended] → Just (RefusedMisuse (WrongPhase TargetIdentity))
          | slot >= limit → Just (RefusedOutOfBounds slot limit)
          | otherwise → Nothing
  case (existing, unusable) of
    (_, Just refused) → pure (Left refused)
    (Just _, _) → pure (Left (RefusedMisuse (DuplicateSubject FrameIdentity)))
    (Nothing, Nothing) → do
      family ← fmap (planQueueFamily . fst) <$> atomically (readRootsDevice (recordingRoots recording))
      case family of
        Nothing → pure (Left RefusedDeviceAbsent)
        Just queueFamily → do
          made ←
            construct
              recording
              0
              2
              "vkCreateCommandPool"
              (\ops device _ → (\(pool, commands) → NativeStorage target slot pool commands) <$> opsCreateStorage ops device queueFamily)
              Nothing
          for_ made (\resource → atomically (modifyTVar' (recordingStorages recording) (Map.insert (target, slot) resource)))
          pure (FrameStorage <$> made)

-- | A host-visible readback buffer of this many bytes, mapped for its
-- lifetime. 'readbackBytesFor' is what one frame's copy needs.
createReadback ∷ Recording q inst msgr phys dev cmd → Natural → IO (Either Refusal Readback)
createReadback recording bytes
  | bytes == 0 = pure (Left (RefusedOutOfBounds 0 0))
  | otherwise =
      fmap Readback
        <$> construct
          recording
          bytes
          2
          "vkCreateBuffer"
          (\ops device _ → (\allocation → NativeReadback allocation ContentsUndefined) <$> opsCreateReadback ops device bytes)
          Nothing

-- | The naming call a pipeline's shader modules are given: under the
-- identity the model is about to issue the pipeline, when the roots offer
-- naming, and nothing otherwise.
shaderNaming ∷ Recording q inst msgr phys dev cmd → Maybe ResourceId → IO (ShaderStage → Word64 → IO ())
shaderNaming recording issued =
  readRootsInstrumentation roots >>= \case
    Just (_, instrumentation)
      | Just resource ← issued →
          pure (\stage handle → nameRootsObject roots instrumentation ObjectShaderModule handle (shaderModuleName resource stage))
    _ → pure (\_ _ → pure ())
  where
    roots = recordingRoots recording

-- | Reserve the accounting, make the native object, and turn the reservation
-- into a managed generation — or into a new generation of the one being
-- replaced — in one masked step. A creation that raised created nothing: its
-- reservation is given back, and the failure is re-raised. The creation is
-- told the identity the model is about to issue the generation, for what it
-- names before that identity exists.
construct
  ∷ Recording q inst msgr phys dev cmd
  → Natural
  → Natural
  → Text
  → (RecordingOps dev cmd → dev → Maybe ResourceId → IO (NativeResource cmd))
  → Maybe ResourceId
  → IO (Either Refusal ResourceId)
construct recording bytes objects name create replacing =
  owned recording $
    atomically (readRootsDevice roots) >>= \case
      Nothing → pure (Left RefusedDeviceAbsent)
      Just (_, device) → do
        -- A replacement's predecessor must still be this recording's current,
        -- live generation; the model checks the same before rebuilding.
        predecessor ← case replacing of
          Nothing → pure (Right ())
          Just old → fmap (const ()) <$> liveNative recording old
        case predecessor of
          Left refusal → pure (Left refusal)
          Right () → mask_ $ do
            reserved ← atomically (modelAnswer roots (beginAllocation bytes objects))
            case reserved of
              Left refusal → pure (Left refusal)
              Right allocation → do
                issued ← atomically $ stateRootsModel roots $ \model →
                  let answer = case replacing of
                        Nothing → createResource allocation model
                        Just old → rebuildResource old allocation model
                   in ( case answer of
                          Admitted (_, resource) → Just resource
                          _ → Nothing
                      , model
                      )
                tryWithContext @SomeException (rootsCall roots name (create (recordingOps recording) device issued)) >>= \case
                  Left failure → do
                    atomically $ do
                      modelEdit roots (recordAllocationFailure allocation)
                      modelEdit roots (abandonAllocation allocation)
                    rethrowIO failure
                  Right native → do
                    committed ← atomically $ do
                      answer ← case replacing of
                        Nothing → modelAnswer roots (createResource allocation)
                        Just old → modelAnswer roots (rebuildResource old allocation)
                      case answer of
                        Right resource → do
                          modifyTVar' (recordingManaged recording) (Map.insert resource (ManagedRecord native ManagedLive))
                          for_ replacing $ \old → do
                            -- The rebuild released the old generation; its CPU
                            -- use ends with it, since no handle may record it.
                            modelEdit roots (endResourceCpuUse old)
                            editManaged recording old (\entry → entry {managedStanding = ManagedReplaced resource})
                          pure (Right resource)
                        Left refusal → do
                          modelEdit roots (abandonAllocation allocation)
                          pure (Left refusal)
                    case committed of
                      Right resource → nameManaged recording resource native
                      Left refusal → do
                        -- The model refused to record what now exists, so
                        -- nothing can reference it: destroy it at once.
                        destroyNative recording device native
                        pure (Left refusal)
  where
    roots = recordingRoots recording

-- | Name a generation's native objects, when the roots offer naming, before
-- its handle is returned. A naming call that raised releases the generation —
-- nothing can record it, its CPU use ends, and the owner's disposal destroys it
-- like any other released generation — and the failure is re-raised.
nameManaged ∷ Recording q inst msgr phys dev cmd → ResourceId → NativeResource cmd → IO (Either Refusal ResourceId)
nameManaged recording resource native =
  readRootsInstrumentation roots >>= \case
    Nothing → pure (Right resource)
    Just (_, instrumentation) →
      tryWithContext @SomeException (for_ (managedNames recording resource native) (\(kind, handle, name) → nameRootsObject roots instrumentation kind handle name)) >>= \case
        Right () → pure (Right resource)
        Left failure → do
          atomically $ do
            modelEdit roots (releaseResource resource)
            modelEdit roots (endResourceCpuUse resource)
            editManaged recording resource (\entry → entry {managedStanding = ManagedReleased})
          rethrowIO failure
  where
    roots = recordingRoots recording

-- | What each of a generation's native objects is named.
managedNames ∷ Recording q inst msgr phys dev cmd → ResourceId → NativeResource cmd → [(NativeObjectKind, Word64, ByteString)]
managedNames recording resource = \case
  NativeLayout handle → [(ObjectPipelineLayout, handle, pipelineLayoutName resource)]
  NativePipeline handle _ _ → [(ObjectPipeline, handle, pipelineName resource)]
  NativeStorage target slot pool commands →
    [ (ObjectCommandPool, pool, commandPoolName resource target slot)
    , (ObjectCommandBuffer, opsCommandBufferHandle (recordingOps recording) commands, commandBufferName resource target slot)
    ]
  NativeReadback allocation _ →
    [ (ObjectBuffer, allocationBuffer allocation, readbackBufferName resource)
    , (ObjectDeviceMemory, allocationMemory allocation, readbackMemoryName resource)
    ]

-- | Release a handle: nothing records through it again, and its CPU use —
-- reading a readback included — ends with it. Batches that already recorded
-- it keep it until their own references end.
releaseManaged ∷ Managed handle ⇒ Recording q inst msgr phys dev cmd → handle → IO (Either Refusal ())
releaseManaged recording handle =
  owned recording $
    liveNative recording resource >>= \case
      Left refusal → pure (Left refusal)
      Right _ → atomically $ do
        released ← modelAnswer roots (fmap (\next → (next, ())) . releaseResource resource)
        case released of
          Left refusal → pure (Left refusal)
          Right () → do
            modelEdit roots (endResourceCpuUse resource)
            editManaged recording resource (\entry → entry {managedStanding = ManagedReleased})
            pure (Right ())
  where
    resource = managedResource handle
    roots = recordingRoots recording
