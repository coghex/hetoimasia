-- | Disposal for the managed recording
-- ("Hetoimasia.GPU.Vulkan.Native.Recording"): destroying, on the graphics
-- owner's thread, every released generation the model reports every hold of
-- ended — each pipeline before the layout it was built over — recording each
-- disposal with the model, and retiring the whole recording. A destruction
-- that raised is uncertain: the generation is retained, never attempted again,
-- and the session fails.
--
-- This module advances managed records to destroyed or uncertain and removes
-- them, their frame storages, and the batch records of destroyed storages from
-- the recording's state ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State")
-- once the model records the disposal; it owns no state of its own.
--
-- It also makes the recording: 'newRecording' registers the recording's
-- 'SubjectDisposer' with the roots, so a reclamation pass (VK-14) destroys a
-- released generation exactly as 'disposeResources' would.
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Disposal
  ( newRecording
  , disposeResources
  , retireRecording
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar, readTVarIO)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, displayException, mask_, rethrowIO, throwIO, tryWithContext)
import Control.Monad (forM, unless)
import Data.Foldable (for_)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text

import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GPU.Model
  ( DisposalResult (..)
  , EvidenceSource (..)
  , SessionFailureCause (CleanupFailed)
  , TurnReport (..)
  , disposalEligible
  , endResourceCpuUse
  , releaseResource
  , runProgressTurn
  , silentEvidence
  )
import Hetoimasia.GPU.Model.Identity (HoldSubject (..), ResourceId)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( BatchRecord (..)
  , ManagedRecord (..)
  , ManagedStanding (..)
  , NativeResource (..)
  , Recording (..)
  , ResourceDestructionFailed (..)
  , ResourcesRetained (..)
  , RingState (..)
  , destroyNative
  , editManaged
  , isAsynchronous
  , makeRecording
  , modelEdit
  , owner
  , releaseClaims
  )
import Hetoimasia.GPU.Vulkan.Native.Generations (Generations)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer (RecordingOps)
import Hetoimasia.GPU.Vulkan.Native.Roots (Roots, SubjectDisposer (..), failRootsSessionBecause, readRootsDevice, registerRootsDisposer, stateRootsModel)

-- | Destroy every released generation whose holds the model reports ended,
-- and record the disposals with the model. A pipeline layout waits for every
-- pipeline built over it to be destroyed first. A destruction that raised is
-- reported, after the whole pass, as 'ResourceDestructionFailed'.
disposeResources ∷ Recording q inst msgr phys dev cmd → Instant → IO [ResourceId]
disposeResources recording now = owner recording (go [])
  where
    roots = recordingRoots recording
    -- Pass after pass, since a pass can make a layout eligible by destroying
    -- its last pipeline, until one destroys nothing. Each pass's destructions
    -- are recorded before the next begins, and a failure is raised only once
    -- everything that did return has been recorded.
    go recorded = do
      (destroyed, failures) ← pass
      -- Each failed destruction is its own cleanup failure, named.
      for_ failures $ \(resource, reason) →
        atomically (failRootsSessionBecause roots CleanupFailed ("destroying " <> Text.pack (show resource) <> " raised: " <> reason))
      settled ← settle []
      for_ failures $ \(resource, reason) → throwIO (ResourceDestructionFailed resource reason)
      if null destroyed then pure (recorded <> settled) else go (recorded <> settled)
    -- A progress turn does bounded work, so turns continue until the model
    -- has recorded every destruction that returned, or a turn does nothing.
    settle recorded = do
      (disposed, acted) ← atomically (progress recording now)
      pending ← any ((== ManagedDestroyedPending) . managedStanding) . Map.elems <$> readTVarIO (recordingManaged recording)
      if not acted || not pending then pure (recorded <> disposed) else settle (recorded <> disposed)
    pass = do
      (candidates, device) ← atomically $ do
        managed ← readTVar (recordingManaged recording)
        uploading ← readTVar (recordingUploading recording)
        model ← stateRootsModel roots (\model → (model, model))
        device ← readRootsDevice roots
        let eligible resource record =
              disposalEligible (ResourceSubject resource) model && destroyableNow uploading managed resource record
        pure (sortOn (kindOrder . managedNative . snd) (Map.toList (Map.filterWithKey eligible managed)), snd <$> device)
      results ← case device of
        Nothing → pure []
        Just handle → forM candidates $ \(resource, record) → (,) resource <$> destroyOne recording handle resource record
      pure ([resource | (resource, Nothing) ← results], [(resource, reason) | (resource, Just reason) ← results])
    kindOrder = \case
      NativePipeline {} → 0 ∷ Int
      NativeStorage {} → 1
      NativeReadback {} → 2
      NativeBuffer {} → 2
      NativeImage {} → 2
      NativeLayout {} → 3

-- | Whether a generation may be destroyed natively now, as far as the
-- recording knows: it was released or replaced, it is the target of no
-- upload still settling (GRS-6) — which holds it between the batches that
-- copy into it, when no batch does — and a pipeline layout has no pipeline
-- left that was built over it. The model decides its holds.
destroyableNow ∷ Set.Set ResourceId → Map.Map ResourceId (ManagedRecord cmd) → ResourceId → ManagedRecord cmd → Bool
destroyableNow uploading managed resource record =
  releasedStanding (managedStanding record) && resource `Set.notMember` uploading && case managedNative record of
    NativeLayout {} → null [() | ManagedRecord (NativePipeline _ over _ _) standing ← Map.elems managed, over == resource, standing /= ManagedDestroyedPending]
    _ → True
  where
    releasedStanding = \case
      ManagedReleased → True
      ManagedReplaced _ → True
      _ → False

-- | Destroy one generation's native objects and record what the destruction
-- did, in one masked step. Answers the reason, if it did not complete.
destroyOne ∷ Recording q inst msgr phys dev cmd → dev → ResourceId → ManagedRecord cmd → IO (Maybe Text.Text)
destroyOne recording device resource record = mask_ $
  tryWithContext @SomeException (destroyNative recording device (managedNative record)) >>= \case
    Right () → Nothing <$ atomically (editManaged recording resource (\entry → entry {managedStanding = ManagedDestroyedPending}))
    Left failure@(ExceptionWithContext _ exception) → do
      let reason = Text.pack (displayException exception)
      atomically (editManaged recording resource (\entry → entry {managedStanding = ManagedUncertain reason}))
      if isAsynchronous exception then rethrowIO failure else pure (Just reason)

-- | A recording over these roots and generations, owned by the calling
-- thread, which must be the graphics owner's.
newRecording
  ∷ RecordingOps dev cmd
  → Roots q inst msgr phys dev
  → Generations q inst msgr phys dev
  → IO (Recording q inst msgr phys dev cmd)
newRecording ops roots generations = do
  recording ← makeRecording ops roots generations
  recording <$ atomically (registerRootsDisposer roots (disposer recording))

-- | What a reclamation pass disposes of the recording's subjects with: a
-- released generation the model offers — every hold on it ended — is
-- destroyed as 'disposeResources' destroys one, unless a pipeline built over
-- it, when it is a layout, still exists. Another layer's subject is not the
-- recording's.
disposer ∷ Recording q inst msgr phys dev cmd → SubjectDisposer
disposer recording =
  SubjectDisposer
    { disposerDispose = \case
        ResourceSubject resource → do
          (managed, uploading, device) ←
            atomically ((,,) <$> readTVar (recordingManaged recording) <*> readTVar (recordingUploading recording) <*> readRootsDevice (recordingRoots recording))
          case (Map.lookup resource managed, device) of
            (Just record, Just (_, handle))
              | destroyableNow uploading managed resource record →
                  Just . maybe DisposalCompleted (const DisposalFailed) <$> destroyOne recording handle resource record
            _ → pure Nothing
        _ → pure Nothing
    , disposerForget = \subjects → forget recording [resource | ResourceSubject resource ← subjects]
    }

-- | Forget the records of generations the model recorded as disposed: each
-- managed record, its frame storage, the batch records of a destroyed
-- storage — submitted batches whose submission completed — and the shared
-- ring, once its buffer is disposed of.
forget ∷ Recording q inst msgr phys dev cmd → [ResourceId] → STM ()
forget recording disposed = do
  modifyTVar' (recordingRing recording) (\ring → ring >>= \held → if ringResource held `elem` disposed then Nothing else Just held)
  modifyTVar' (recordingManaged recording) (\held → foldr Map.delete held disposed)
  modifyTVar' (recordingIndexData recording) (\held → foldr Map.delete held disposed)
  modifyTVar' (recordingStorages recording) (Map.filter (`notElem` disposed))
  -- A batch record that goes with its storage is a submitted batch whose
  -- submission completed: its ring regions go too.
  completed ← Map.keys . Map.filter ((`elem` disposed) . batchStorage) <$> readTVar (recordingBatches recording)
  releaseClaims recording completed
  modifyTVar' (recordingBatches recording) (Map.filter ((`notElem` disposed) . batchStorage))

-- | One model progress turn answering for this recording's resources only,
-- forgetting every one the model recorded as disposed. Answers those, and
-- whether the turn took any action at all.
progress ∷ Recording q inst msgr phys dev cmd → Instant → STM ([ResourceId], Bool)
progress recording now = do
  managed ← readTVar (recordingManaged recording)
  let answer = \case
        ResourceSubject resource → case managedStanding <$> Map.lookup resource managed of
          Just ManagedDestroyedPending → DisposalCompleted
          Just (ManagedUncertain _) → DisposalFailed
          _ → DisposalRefused
        GenerationSubject _ → DisposalRefused
  report ← stateRootsModel (recordingRoots recording) $ \model →
    let (next, turn) = runProgressTurn silentEvidence {disposalEvidence = answer} now model
     in (turn, next)
  let disposed = [resource | ResourceSubject resource ← turnDisposed report]
  -- A storage is disposable only once no batch or submission holds it, so a
  -- batch record still naming a destroyed storage is a submitted one whose
  -- submission completed: it goes with its storage. A readback it copied into
  -- keeps its own evidence.
  forget recording disposed
  pure (disposed, turnActions report > 0)

-- | Release every live handle, destroy every generation whose holds have
-- ended, and raise 'ResourcesRetained' — manufacturing no evidence — if any
-- remains. A batch still outstanding retains what it references.
retireRecording ∷ Recording q inst msgr phys dev cmd → Instant → IO ()
retireRecording recording now = owner recording $ do
  live ← Map.keys . Map.filter ((== ManagedLive) . managedStanding) <$> readTVarIO (recordingManaged recording)
  for_ live $ \resource → atomically $ do
    modelEdit roots (releaseResource resource)
    modelEdit roots (endResourceCpuUse resource)
    editManaged recording resource (\entry → entry {managedStanding = ManagedReleased})
  _ ← disposeResources recording now
  remaining ← Map.keys <$> readTVarIO (recordingManaged recording)
  unless (null remaining) (throwIO (ResourcesRetained remaining))
  where
    roots = recordingRoots recording
