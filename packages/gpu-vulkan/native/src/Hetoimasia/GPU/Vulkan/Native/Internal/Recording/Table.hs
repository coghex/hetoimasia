-- | The session's bindless texture table (GRS-7; resource services design
-- D-1, D-11, D-20, D-22, D-23, D-27, D-31 and D-35): making it, registering
-- and releasing textures, and the pipeline layouts that hold it.
--
-- The table is two engine-owned descriptor sets. Set 0 holds the four shared
-- samplers, immutable, and then the variable-count, update-after-bind
-- sampled-image array as its highest binding, declared at the application's
-- validated cap and allocated at its initial size. Set 1 holds one dynamic
-- storage buffer over the version ring, whose offset selects the version a
-- batch bound. A pipeline layout that holds the table ('createTablePipelineLayout')
-- declares both, so every such layout is compatible with every other for
-- those sets.
--
-- This module makes the table's generations and owns registration and
-- release; "Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Lookup" brings it
-- up to date and takes the version a batch binds; the recorder binds it and
-- selects samplers. All of it runs on the graphics owner's thread.
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Table
  ( createTextureTable
  , registerTexture
  , releaseTexture
  , refreshTextureTable
  , createTablePipelineLayout
  , TableView (..)
  , readTable
  ) where

import Control.Concurrent.STM (STM, atomically, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, onException, throwIO, try)
import qualified Data.ByteString as ByteString
import Data.Foldable (for_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model.Budget (BudgetKind (TextureSlotBudget))
import Hetoimasia.GPU.Model.Identity (IdentityKind (..), Misuse (..), ResourceId)
import qualified Hetoimasia.GPU.Model.TextureTable as Book
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Construction
  ( checkedTableRanges
  , construct
  , createImage
  , createMapped
  , releaseManaged
  , validatePushRanges
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer
  ( BufferKind (LookupBuffer)
  , DescriptorWrite (..)
  , ImageDescription (..)
  , ImageFormat (Rgba8Linear)
  , ImageKind (TextureImage)
  , PoolRequest (..)
  , PushConstantRange (..)
  , PushStage (PushFragment)
  , ReadbackAllocation (..)
  , RecordingLimits (..)
  , RecordingOps (..)
  , SetLayoutRequest (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Lookup (refreshTable, versionHeld)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( Image (..)
  , Managed (..)
  , NativeResource (..)
  , PipelineLayout (..)
  , Recording (..)
  , Refusal (..)
  , TableState (..)
  , liveNative
  , owned
  , tshow
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Uploads (UploadRequest (..), Uploads, submitUpload)
import Hetoimasia.GPU.Vulkan.Native.Roots (readRootsDevice, rootsCall)
import Hetoimasia.GPU.Vulkan.Native.Shader.Interface (CheckedShaders)

-- | Make the session's texture table from a validated configuration (D-11):
-- its samplers, its two set layouts, a pool and a set for each, its version
-- ring with one managed version per entry, and slot 0's transparent-black
-- placeholder, whose upload is admitted through the session's uploads. A
-- session has at most one: a second is 'RefusedMisuse' with
-- 'DuplicateSubject'.
--
-- Before anything is made, the configuration is checked against the device:
-- a cap beyond its update-after-bind sampled-image limits, the four samplers
-- beyond its update-after-bind sampler limits, a stage's every binding
-- beyond its update-after-bind resource limit, fewer than two bindable sets,
-- one version's entries beyond its storage-buffer range, and a ring beyond
-- its buffer size, are each 'RefusedOutOfBounds', naming what was asked for
-- and the limit. Versions are placed at a stride that is a multiple of the
-- device's storage-buffer offset alignment and flush granularity. A
-- construction that is refused or raises releases everything already made.
--
-- The table is bound only once the placeholder's upload has completed and
-- its descriptor is written, which the owner's next refresh does.
createTextureTable ∷ Recording q inst msgr phys dev cmd → Uploads q inst msgr phys dev cmd → Book.TableConfig → IO (Either Refusal ())
createTextureTable recording uploads config =
  owned recording $ do
    existing ← readTVarIO (recordingTable recording)
    limits ← opsRecordingLimits ops
    most ← opsMaxBufferSize ops
    let capacity = Book.tableCapacity config
        initial = Book.tableInitialSlots config
        versions = Book.tableVersionCount config
        entryBytes = toInteger initial * 8
        granule = lcm (max 1 (limitStorageAlignment limits)) (max 1 (limitNonCoherentAtom limits))
        stride = roundUp (fromInteger entryBytes) granule
        ringBytes = stride * fromIntegral versions
        exceeds asked limit = toInteger asked > toInteger limit
        checks =
          [ (toInteger capacity, toInteger (limitTableSampledImages limits))
          , (4, toInteger (limitTableSamplers limits))
          , (toInteger capacity + 5, toInteger (limitTableResources limits))
          , (2, toInteger (limitBoundSets limits))
          , (entryBytes, toInteger (limitStorageRange limits))
          , (toInteger ringBytes, toInteger most)
          ]
    case existing of
      Just _ → pure (Left (RefusedMisuse (DuplicateSubject ResourceIdentity)))
      Nothing → case [(asked, limit) | (asked, limit) ← checks, exceeds asked limit] of
        (asked, limit) : _ → pure (Left (RefusedOutOfBounds (fromInteger asked) (fromInteger limit)))
        [] → do
          made ← newIORef []
          let step action =
                action >>= \case
                  Left refusal → throwIO (Abandon refusal)
                  Right resource → resource <$ modifyIORef' made (resource :)
          outcome ← try @Abandon (build made step stride ringBytes) `onException` unwind made
          case outcome of
            Right state → do
              atomically (writeTVar (recordingTable recording) (Just state))
              -- The placeholder may already be complete.
              refreshTable recording
            Left (Abandon refusal) → unwind made >> pure (Left refusal)
  where
    ops = recordingOps recording
    initialSlots = Book.tableInitialSlots config
    build made step stride ringBytes = do
      samplers ← step $
        construct
          recording
          0
          4
          "vkCreateSampler"
          (\layer device _ _ → Right . NativeSamplers <$> allOrNothing (opsDestroySampler layer device) [opsCreateSampler layer device sampler | sampler ← [minBound .. maxBound]])
          Nothing
      samplerHandles ← nativeOf samplers >>= \case
        NativeSamplers handles → pure handles
        _ → throwIO (Abandon RefusedWrongKind)
      layouts ← step $
        construct
          recording
          0
          2
          "vkCreateDescriptorSetLayout"
          ( \layer device _ _ →
              ( \case
                  [textures, lookups] → Right (NativeSetLayouts textures lookups)
                  _ → Left RefusedWrongKind
              )
                <$> allOrNothing
                  (opsDestroySetLayout layer device)
                  [opsCreateSetLayout layer device (TextureSetLayout samplerHandles (Book.tableCapacity config)), opsCreateSetLayout layer device LookupSetLayout]
          )
          Nothing
      (textureLayout, lookupLayout) ← nativeOf layouts >>= \case
        NativeSetLayouts textures lookups → pure (textures, lookups)
        _ → throwIO (Abandon RefusedWrongKind)
      pools ← step $
        construct recording 0 4 "vkCreateDescriptorPool" (makePools textureLayout lookupLayout) Nothing
      sets ← nativeOf pools >>= \case
        NativeDescriptorPools _ textureSet _ lookupSet → pure [textureSet, lookupSet]
        _ → throwIO (Abandon RefusedWrongKind)
      (ring, mapping, atom) ←
        createMapped recording LookupBuffer ringBytes >>= \case
          Left refusal → throwIO (Abandon refusal)
          Right made'@(resource, _, _) → made' <$ modifyIORef' made (resource :)
      versions ←
        traverse
          (\entry → (,) entry <$> step (construct recording 0 1 "the texture table's lookup version" (\_ _ _ _ → pure (Right (NativeVersion entry))) Nothing))
          [0 .. Book.tableVersionCount config - 1]
      device ←
        atomically (readRootsDevice (recordingRoots recording)) >>= \case
          Nothing → throwIO (Abandon RefusedDeviceAbsent)
          Just (_, handle) → pure handle
      rootsCall (recordingRoots recording) "vkUpdateDescriptorSets" $
        opsWriteDescriptors ops device [WriteLookupBuffer (lookupSetOf sets) (allocationBuffer mapping) (fromIntegral initialSlots * 8)]
      Image placeholder ←
        createImage recording (ImageDescription TextureImage Rgba8Linear 1 1 1) >>= \case
          Left refusal → throwIO (Abandon refusal)
          Right image@(Image resource) → image <$ modifyIORef' made (resource :)
      submitUpload uploads (UploadImage (Image placeholder) [ByteString.replicate 4 0]) >>= \case
        Left refusal → throwIO (Abandon (RefusedIllegal ("the texture table's placeholder upload was refused: " <> tshow refusal)))
        Right _ → pure ()
      pure
        TableState
          { tableBook = Book.newTextureTable config
          , tableSamplers = samplers
          , tableLayouts = layouts
          , tablePools = pools
          , tableRing = ring
          , tableVersions = Map.fromList versions
          , tableSetLayoutHandles = [textureLayout, lookupLayout]
          , tableSets = sets
          , tableMapping = mapping
          , tableStride = stride
          , tableEntries = initialSlots
          , tableAtom = atom
          , tablePlaceholder = placeholder
          , tablePlaceholderWritten = False
          , tableTextures = Set.empty
          }
    -- Set 0's pool and set, then set 1's: a failure destroys every pool made
    -- so far, which frees its set.
    makePools textureLayout lookupLayout layer device _ _ = do
      texturePool ← opsCreateDescriptorPool layer device (TexturePool 4 initialSlots)
      ( do
          textureSet ← opsAllocateSet layer device texturePool textureLayout (Just initialSlots)
          lookupPool ← opsCreateDescriptorPool layer device LookupPool
          ( do
              lookupSet ← opsAllocateSet layer device lookupPool lookupLayout Nothing
              pure (Right (NativeDescriptorPools texturePool textureSet lookupPool lookupSet))
            )
            `onException` opsDestroyDescriptorPool layer device lookupPool
        )
        `onException` opsDestroyDescriptorPool layer device texturePool
    nativeOf resource =
      liveNative recording resource >>= \case
        Left refusal → throwIO (Abandon refusal)
        Right native → pure native
    lookupSetOf = \case
      [_, lookups] → lookups
      _ → 0
    -- Release everything made so far, newest first.
    unwind made = do
      resources ← readIORef made
      for_ resources (\resource → releaseManaged recording (Made resource))

-- | A construction step's refusal, carried out of the steps to undo them.
newtype Abandon = Abandon Refusal
  deriving (Show)

instance Exception Abandon

-- | Any generation the table made, as a handle 'releaseManaged' releases.
newtype Made = Made ResourceId

instance Managed Made where
  managedResource (Made resource) = resource

-- | Run creations in order; if one raises, destroy those already made, newest
-- first, and re-raise.
allOrNothing ∷ (Word64 → IO ()) → [IO Word64] → IO [Word64]
allOrNothing destroy = go []
  where
    go made = \case
      [] → pure (reverse made)
      create : rest → do
        handle ← create `onException` for_ made destroy
        go (handle : made) rest

-- | Register an uploaded texture (#342) with the table: answer its stable
-- handle, which resolves to slot 0's placeholder until the image's upload has
-- completed and to the image's own slot in versions published after that.
-- The table holds the image from now on: releasing it directly is refused,
-- and it is released only through its handle, once no live version maps its
-- slot. Refused, before anything is held: a session with no table; an image
-- that is not this session's live texture; one already registered, as
-- 'DuplicateSubject'; and a full table, as 'RefusedBackpressure'
-- 'TextureSlotBudget', until a released texture's slot is reclaimed.
registerTexture ∷ Recording q inst msgr phys dev cmd → Image → IO (Either Refusal Book.TextureHandle)
registerTexture recording (Image image) =
  owned recording $
    liveNative recording image >>= \case
      Left refusal → pure (Left refusal)
      Right (NativeImage description _ _)
        | imageKind description /= TextureImage → pure (Left RefusedWrongKind)
        | otherwise → do
            registered ← atomically $
              readTVar (recordingTable recording) >>= \case
                Nothing → pure (Left (RefusedIllegal "registering a texture with a session that has made no texture table"))
                Just table
                  | Set.member image (tableTextures table) → pure (Left (RefusedMisuse (DuplicateSubject ResourceIdentity)))
                  | otherwise → case Book.registerTexture image (tableBook table) of
                      Left _ → pure (Left (RefusedBackpressure TextureSlotBudget))
                      Right (book, handle) → do
                        writeTVar (recordingTable recording) (Just table {tableBook = book, tableTextures = Set.insert image (tableTextures table)})
                        pure (Right handle)
            case registered of
              Left refusal → pure (Left refusal)
              -- An image whose upload already completed completes now.
              Right handle → fmap (const handle) <$> refreshTable recording
      Right _ → pure (Left RefusedWrongKind)

-- | Release a handle: it resolves to nothing from the next version on, its
-- index may be issued again under a new generation, and its slot retires.
-- The image is released once no live version maps the slot — at once if the
-- texture never completed, or once every batch that bound a version mapping
-- it has completed. A stale handle is 'RefusedStaleHandle'.
releaseTexture ∷ Recording q inst msgr phys dev cmd → Book.TextureHandle → IO (Either Refusal ())
releaseTexture recording handle =
  owned recording $ do
    released ← atomically $
      readTVar (recordingTable recording) >>= \case
        Nothing → pure (Left (RefusedStaleHandle handle))
        Just table → case Book.releaseTexture handle (tableBook table) of
          Left _ → pure (Left (RefusedStaleHandle handle))
          Right book → Right () <$ writeTVar (recordingTable recording) (Just table {tableBook = book})
    case released of
      Left refusal → pure (Left refusal)
      Right () → refreshTable recording

-- | Bring the table up to date now, on the graphics owner's thread: complete
-- the textures whose uploads have, and reclaim the slots no live version
-- maps, releasing their images. Binding the table does this first; an owner
-- with nothing to bind calls it to let released textures go.
refreshTextureTable ∷ Recording q inst msgr phys dev cmd → IO (Either Refusal ())
refreshTextureTable recording = owned recording (refreshTable recording)

-- | A pipeline layout holding the texture table (D-22, D-35): both of its
-- set layouts, from set 0 on, and exactly the push-constant ranges the
-- checked shaders need, whose descriptor bindings may be only the table's
-- own ('checkedTableRanges'). The consumer declares the push-constant offset
-- of its draws' sampler index, which must be a multiple of four and lie,
-- whole, within a range the fragment stage sees. Refused before any native
-- call: a session with no table, a sampler index outside every fragment
-- range, and whatever 'checkedTableRanges' and the push-range validation
-- refuse.
createTablePipelineLayout ∷ Recording q inst msgr phys dev cmd → CheckedShaders → Word32 → IO (Either Refusal PipelineLayout)
createTablePipelineLayout recording shaders samplerOffset =
  owned recording $
    readTVarIO (recordingTable recording) >>= \case
      Nothing → pure (Left (RefusedIllegal "a pipeline layout holding a texture table this session has not made"))
      Just table → case checkedTableRanges shaders of
        Left refusal → pure (Left refusal)
        Right ranges
          | samplerOffset `mod` 4 /= 0 || not (any (covers samplerOffset) ranges) →
              pure (Left (RefusedIllegal "a sampler index outside every push-constant range the fragment stage sees"))
          | otherwise → do
              limits ← opsRecordingLimits (recordingOps recording)
              case validatePushRanges (limitPushConstantBytes limits) ranges of
                Left refusal → pure (Left refusal)
                Right () →
                  fmap PipelineLayout
                    <$> construct
                      recording
                      0
                      1
                      "vkCreatePipelineLayout"
                      (\layer device _ _ → Right . (\handle → NativeLayout handle ranges (Just samplerOffset)) <$> opsCreatePipelineLayout layer device (tableSetLayoutHandles table) ranges)
                      Nothing
  where
    covers offset range =
      PushFragment `elem` rangeStages range
        && rangeOffset range <= offset
        && toInteger offset + 4 <= toInteger (rangeOffset range) + toInteger (rangeSize range)

-- | The texture table as an observer sees it.
data TableView = TableView
  { tableViewMapping ∷ !(Map.Map Word32 Book.LookupEntry)
    -- ^ The mapping a version published now would hold.
  , tableViewCurrent ∷ !(Maybe Word32)
    -- ^ The current version's ring entry.
  , tableViewLive ∷ ![Word32]
    -- ^ The ring entries whose versions are live: the current one, and every
    -- one a batch holds.
  , tableViewMapped ∷ !(Set Word32)
    -- ^ The slots a live version maps.
  , tableViewFree ∷ !(Set Word32)
  , tableViewRetiring ∷ ![Word32]
  , tableViewPlaceholderWritten ∷ !Bool
  , tableViewStride ∷ !Natural
  , tableViewVersions ∷ !(Map.Map Word32 ResourceId)
  }
  deriving (Eq, Show)

readTable ∷ Recording q inst msgr phys dev cmd → STM (Maybe TableView)
readTable recording =
  readTVar (recordingTable recording) >>= \case
    Nothing → pure Nothing
    Just table → do
      held ← versionHeld (recordingRoots recording) table
      let book = tableBook table
      pure . Just $
        TableView
          { tableViewMapping = Book.currentMapping book
          , tableViewCurrent = Book.currentVersion book
          , tableViewLive = Book.liveVersions held book
          , tableViewMapped = Book.mappedSlots held book
          , tableViewFree = Book.freeSlots book
          , tableViewRetiring = Book.retiringSlots book
          , tableViewPlaceholderWritten = tablePlaceholderWritten table
          , tableViewStride = tableStride table
          , tableViewVersions = tableVersions table
          }

roundUp ∷ Natural → Natural → Natural
roundUp value granule
  | granule <= 1 = value
  | otherwise = ((value + granule - 1) `div` granule) * granule
