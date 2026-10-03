-- | The texture table's steps the recorder and the table's own operations
-- share (GRS-7; resource services design D-20, D-27): observing which
-- registered textures' uploads have completed and writing their descriptors,
-- reclaiming slots no live version maps, and taking the version a batch binds
-- — publishing a new one into the version ring when a mapping changed.
--
-- Whether a ring entry is held is the GPU model's answer: each entry is a
-- managed version generation, and a batch that binds the table at it retains
-- it, so its recorded reference, then its submitted use until completion,
-- hold it exactly as they hold any managed resource. The pure rules are
-- "Hetoimasia.GPU.Model.TextureTable"'s.
--
-- Every step runs on the graphics owner's thread. Descriptor writes target
-- only a slot no live version maps — one just reserved, or slot 0 before the
-- table is first bound — so no recorded or pending batch can read them; a
-- version is written only into a ring entry no batch holds, and is made
-- visible to the device by the submission that follows (D-26).
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Lookup
  ( refreshTable
  , takeVersion
  , TakenVersion (..)
  , versionHeld
  , encodeVersion
  ) where

import Control.Concurrent.STM (STM, atomically, catchSTM, modifyTVar', readTVar, readTVarIO, throwSTM, writeTVar)
import Control.Exception (Exception)
import Control.Monad (unless, when)
import Data.Functor ((<&>))
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word32)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model (HoldView (..), Initialization (..), holdView, resourceInitialization)
import Hetoimasia.GPU.Model.Budget (BudgetKind (LookupVersionBudget))
import Hetoimasia.GPU.Model.Identity (HoldSubject (..), ResourceId)
import qualified Hetoimasia.GPU.Model.TextureTable as Book
import Hetoimasia.GPU.Vulkan.Native.Internal.Allocation (AllocatedBuffer (..), flushBuffer)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Construction (releaseLive)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer
  ( DescriptorWrite (..)
  , ReadbackAllocation (..)
  , RecordingOps (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( ManagedRecord (..)
  , ManagedStanding (..)
  , NativeResource (..)
  , Recording (..)
  , Refusal (..)
  , TableState (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (Checkpoint (..), Roots, checkpointRoots, readRootsDevice, rootsCall, stateRootsModel)

-- | Whether each ring entry's version is held by a batch: its managed
-- generation still has a recorded reference or a submitted use in the model.
versionHeld ∷ Roots q inst msgr phys dev → TableState → STM (Word32 → Bool)
versionHeld roots table = do
  model ← stateRootsModel roots (\model → (model, model))
  pure $ \entry → case Map.lookup entry (tableVersions table) >>= \resource → holdView (ResourceSubject resource) model of
    Just view → not (null (viewRecorded view) && null (viewSubmitted view))
    Nothing → False

-- | One version as the device reads it: every lookup entry in index order, as
-- two little-endian 32-bit words, the slot and then the generation. An index
-- the mapping leaves out reads as 'Book.invalidEntry'.
encodeVersion ∷ Word32 → Map.Map Word32 Book.LookupEntry → ByteString
encodeVersion entries mapping =
  Lazy.toStrict . Builder.toLazyByteString $
    foldMap
      (\index → let entry = Map.findWithDefault Book.invalidEntry index mapping in Builder.word32LE (Book.entrySlot entry) <> Builder.word32LE (Book.entryGeneration entry))
      [0 .. entries - 1]

-- | Bring the table up to date, on the graphics owner's thread: write slot
-- 0's placeholder once its upload has completed; complete every registered
-- texture whose upload has, writing its descriptor into its reserved slot;
-- and reclaim every retiring slot no live version maps, releasing its image.
-- A texture is complete once the model holds it initialized and no upload
-- holds it any longer, which is its upload's completion. A session with no
-- table has nothing to do. Once the session has failed, or while a
-- diagnostic failure is pending, no descriptor is written — that is new work
-- — but released textures are still reclaimed, which is cleanup.
refreshTable ∷ Recording q inst msgr phys dev cmd → IO (Either Refusal ())
refreshTable recording =
  readTVarIO (recordingTable recording) >>= \case
    Nothing → pure (Right ())
    Just table →
      atomically (readRootsDevice roots) >>= \case
        Nothing → pure (Left RefusedDeviceAbsent)
        Just (_, device) → do
          clear ←
            checkpointRoots roots <&> \case
              CheckpointClear → True
              _ → False
          when clear (writeCompleted table device)
          -- Slots no live version maps any longer, and their images released,
          -- in one transaction: no cancellation can leave an image the table
          -- has let go of unreleased, and a refusal leaves everything as it
          -- was, still retiring for the next refresh.
          atomically $
            ( do
                held ← readTVar (recordingTable recording)
                case held of
                  Nothing → pure (Right ())
                  Just state → do
                    isHeld ← versionHeld roots state
                    let (reclaimed, slots) = Book.reclaimSlots isHeld (tableBook state)
                        images = map snd slots
                    writeTVar
                      (recordingTable recording)
                      (Just state {tableBook = reclaimed, tableTextures = foldr Set.delete (tableTextures state) images})
                    for_ images $ \image →
                      releaseLive recording image >>= \case
                        Left refusal → throwSTM (ReclaimRefused refusal)
                        Right () → pure ()
                    pure (Right ())
            )
              `catchSTM` \(ReclaimRefused refusal) → pure (Left refusal)
  where
    roots = recordingRoots recording
    ops = recordingOps recording
    writeCompleted table device = do
          -- Slot 0 first: until it is written, no batch binds the table.
          unless (tablePlaceholderWritten table) $
            ready (tablePlaceholder table) >>= \case
              Just view → do
                rootsCall roots "vkUpdateDescriptorSets" (opsWriteDescriptors ops device [WriteSampledImage (textureSet table) 0 view])
                atomically (modifyTVar' (recordingTable recording) (fmap (\held → held {tablePlaceholderWritten = True})))
              Nothing → pure ()
          -- Each registered texture whose upload completed.
          pending ← Book.pendingTextures . tableBook <$> current
          for_ pending $ \(handle, image) →
            ready image >>= \case
              Nothing → pure ()
              Just view → do
                book ← tableBook <$> current
                case Book.completeTexture handle book of
                  Left _ → pure ()
                  Right (completed, (slot, _)) → do
                    rootsCall roots "vkUpdateDescriptorSets" (opsWriteDescriptors ops device [WriteSampledImage (textureSet table) slot view])
                    atomically (modifyTVar' (recordingTable recording) (fmap (\held → held {tableBook = completed})))
    current = maybe (fail "the texture table vanished") pure =<< readTVarIO (recordingTable recording)
    textureSet table = case tableSets table of
      set : _ → set
      [] → 0
    -- The image's owned view, once its upload has completed.
    ready image = atomically $ do
      model ← stateRootsModel roots (\model → (model, model))
      uploading ← Set.member image <$> readTVar (recordingUploading recording)
      managed ← Map.lookup image <$> readTVar (recordingManaged recording)
      pure $ case (resourceInitialization image model, managed) of
        (Just Initialized, Just (ManagedRecord (NativeImage _ _ view) ManagedLive))
          | not uploading → Just view
        _ → Nothing

-- | A reclaimed image's release was refused: the reclamation is rolled back.
newtype ReclaimRefused = ReclaimRefused Refusal
  deriving (Show)

instance Exception ReclaimRefused

-- | The version a batch binds the table at: its ring entry, that entry's
-- managed version generation, which the batch retains, and the dynamic
-- offset selecting it.
data TakenVersion = TakenVersion
  { takenEntry ∷ !Word32
  , takenResource ∷ !ResourceId
  , takenOffset ∷ !Word32
  }
  deriving (Eq, Show)

-- | Take the version a batch binding the table now binds, after bringing the
-- table up to date ('refreshTable'): the current one when no mapping changed,
-- or a new one, written whole into a ring entry no batch holds before anyone
-- can read it. Refused: a session with no table; a table whose placeholder
-- has not finished uploading, as 'RefusedNotWritten'; and a new version owed
-- while every entry is held, as 'RefusedBackpressure' 'LookupVersionBudget'.
takeVersion ∷ Recording q inst msgr phys dev cmd → IO (Either Refusal TakenVersion)
takeVersion recording =
  refreshTable recording >>= \case
    Left refusal → pure (Left refusal)
    Right () →
      readTVarIO (recordingTable recording) >>= \case
        Nothing → pure (Left (RefusedIllegal "binding a texture table this session has not made"))
        Just table
          | not (tablePlaceholderWritten table) → pure (Left (RefusedNotWritten "the texture table's placeholder has not finished uploading"))
          | otherwise → do
              isHeld ← atomically (versionHeld roots table)
              case Book.bindVersion isHeld (tableBook table) of
                Left _ → pure (Left (RefusedBackpressure LookupVersionBudget))
                Right (bound, binding) → do
                  let entry = Book.bindingVersion binding
                      offset = fromIntegral entry * tableStride table
                  for_ (Book.bindingWrite binding) $ \mapping → do
                    let bytes = encodeVersion (tableEntries table) mapping
                        mapped = tableMapping table
                        atom = tableAtom table
                        high = roundUp (offset + fromIntegral (ByteString.length bytes)) atom
                    opsWriteMapped ops mapped offset bytes
                    unless (allocationCoherent mapped) $
                      flushBuffer roots (AllocatedBuffer (allocationMemory mapped) False (Just (allocationMapped mapped))) (offset, high - offset)
                  atomically (modifyTVar' (recordingTable recording) (fmap (\held → held {tableBook = bound})))
                  case Map.lookup entry (tableVersions table) of
                    Nothing → pure (Left (RefusedIllegal "a lookup version the table never made"))
                    Just resource
                      | offset > fromIntegral (maxBound ∷ Word32) → pure (Left (RefusedOutOfBounds offset (fromIntegral (maxBound ∷ Word32))))
                      | otherwise → pure (Right (TakenVersion entry resource (fromIntegral offset)))
  where
    roots = recordingRoots recording
    ops = recordingOps recording

roundUp ∷ Natural → Natural → Natural
roundUp value granule
  | granule <= 1 = value
  | otherwise = ((value + granule - 1) `div` granule) * granule
