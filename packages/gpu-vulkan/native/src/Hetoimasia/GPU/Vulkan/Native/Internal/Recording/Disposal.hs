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
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Disposal
  ( disposeResources
  , retireRecording
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar, readTVarIO)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, displayException, mask_, rethrowIO, throwIO, tryWithContext)
import Control.Monad (forM, unless)
import Data.Foldable (for_)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
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
  , destroyNative
  , editManaged
  , isAsynchronous
  , modelEdit
  , owner
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (failRootsSession, readRootsDevice, stateRootsModel)

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
      unless (null failures) (atomically (failRootsSession roots CleanupFailed))
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
        model ← stateRootsModel roots (\model → (model, model))
        device ← readRootsDevice roots
        let dependants layout =
              [ () | ManagedRecord (NativePipeline _ over _) standing ← Map.elems managed, over == layout, standing /= ManagedDestroyedPending
              ]
            eligible resource record =
              releasedStanding (managedStanding record)
                && disposalEligible (ResourceSubject resource) model
                && case managedNative record of
                  NativeLayout _ → null (dependants resource)
                  _ → True
        pure (sortOn (kindOrder . managedNative . snd) (Map.toList (Map.filterWithKey eligible managed)), snd <$> device)
      results ← case device of
        Nothing → pure []
        Just handle → forM candidates $ \(resource, record) → (,) resource <$> destroyOne handle resource record
      pure ([resource | (resource, Nothing) ← results], [(resource, reason) | (resource, Just reason) ← results])
    destroyOne device resource record = mask_ $
      tryWithContext @SomeException (destroyNative recording device (managedNative record)) >>= \case
        Right () → Nothing <$ atomically (editManaged recording resource (\entry → entry {managedStanding = ManagedDestroyedPending}))
        Left failure@(ExceptionWithContext _ exception) → do
          let reason = Text.pack (displayException exception)
          atomically (editManaged recording resource (\entry → entry {managedStanding = ManagedUncertain reason}))
          if isAsynchronous exception then rethrowIO failure else pure (Just reason)
    kindOrder = \case
      NativePipeline {} → 0 ∷ Int
      NativeStorage {} → 1
      NativeReadback {} → 2
      NativeLayout _ → 3
    releasedStanding = \case
      ManagedReleased → True
      ManagedReplaced _ → True
      _ → False

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
  modifyTVar' (recordingManaged recording) (\held → foldr Map.delete held disposed)
  modifyTVar' (recordingStorages recording) (Map.filter (`notElem` disposed))
  -- A storage is disposable only once no batch or submission holds it, so a
  -- batch record still naming a destroyed storage is a submitted one whose
  -- submission completed: it goes with its storage. A readback it copied into
  -- keeps its own evidence.
  modifyTVar' (recordingBatches recording) (Map.filter ((`notElem` disposed) . batchStorage))
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
