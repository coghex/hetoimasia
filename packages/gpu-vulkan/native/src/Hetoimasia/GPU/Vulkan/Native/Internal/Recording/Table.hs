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
  , swapTexture
  , releaseTexture
  , refreshTextureTable
  , createTablePipelineLayout
  , TableView (..)
  , readTable
  , RegistrationNotUndone (..)
  ) where

import Control.Concurrent.STM (STM, atomically, newTVar, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeException, displayException, fromException, mask, mask_, onException, rethrowIO, throwIO, try, tryWithContext)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.ByteString as ByteString
import Data.Foldable (for_)
import Control.Monad (unless)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model (Initialization (Initialized), resourceInitialization)
import Hetoimasia.GPU.Model.Budget (BudgetKind (TextureSlotBudget))
import Hetoimasia.GPU.Model.Identity (IdentityKind (..), Misuse (..), ResourceId)
import qualified Hetoimasia.GPU.Model.TextureTable as Book
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Construction
  ( checkedTableRanges
  , construct
  , constructOnce
  , undoing
  , createImage
  , createMapped
  , releaseLive
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
  , SwapState (..)
  , SwapTicket (..)
  , TableState (..)
  , checkpointed
  , isAsynchronous
  , liveNative
  , owned
  , tshow
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Reclamation (failingAgain, recoverAllocation, withAllocationAttempt)
import Hetoimasia.GPU.Vulkan.Native.Internal.Uploads (UploadRequest (..), Uploads, submitUpload)
import Hetoimasia.GPU.Vulkan.Native.Naming (NativeObjectKind (ObjectDescriptorSet), tableSetName)
import Hetoimasia.GPU.Vulkan.Native.Roots (NativeFailure (FailedOutOfMemory), TerminalReport (reportPrimary), nameRootsObject, readRootsDevice, readRootsInstrumentation, readRootsTerminal, rootsCall, rootsNativeFailure, stateRootsModel)
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
-- beyond its update-after-bind resource limit, set 0's pool — the samplers
-- and the initial images — beyond the update-after-bind descriptors all pools
-- may hold, fewer than two bindable sets,
-- one version's entries beyond its storage-buffer range, the last version's
-- dynamic offset beyond what 32 bits hold, and a ring beyond its buffer size,
-- are each 'RefusedOutOfBounds', naming what was asked for and the limit.
-- Versions are placed at a stride that is a multiple of the device's
-- storage-buffer offset alignment and flush granularity. A construction that
-- is refused or raises releases every generation already made, whose
-- destruction follows the ordinary rules. Refused, like all new work, once
-- the session has failed.
--
-- The table is bound only once the placeholder's upload has completed and
-- its descriptor is written, which the owner's next refresh does.
createTextureTable ∷ Recording q inst msgr phys dev cmd → Uploads q inst msgr phys dev cmd → Book.TableConfig → IO (Either Refusal ())
createTextureTable recording uploads config =
  owned recording . checkpointed recording $ do
    existing ← readTVarIO (recordingTable recording)
    limits ← opsRecordingLimits ops
    most ← opsMaxBufferSize ops
    let capacity = Book.tableCapacity config
        initial = Book.tableInitialSlots config
        versions = Book.tableVersionCount config
        -- Set 1 and the version ring are sized for the cap from the start
        -- and never rebuilt (GRS-14): one version is the cap's lookup
        -- entries, eight bytes each, the slot and the generation.
        entryBytes = toInteger capacity * 8
        -- Set 0's generations, from the initial size doubling to the cap;
        -- each pool holds the four samplers and its set's images, and in the
        -- worst case every generation's pool is still held at once.
        generations = setGenerations initial capacity
        poolDescriptors = sum [toInteger count + 4 | count ← generations]
        granule = lcm (max 1 (limitStorageAlignment limits)) (max 1 (limitNonCoherentAtom limits))
        stride = roundUp (fromInteger entryBytes) granule
        ringBytes = stride * fromIntegral versions
        exceeds asked limit = toInteger asked > toInteger limit
        checks =
          [ (toInteger capacity, toInteger (limitTableSampledImages limits))
          , (4, toInteger (limitTableSamplers limits))
          , (toInteger capacity + 5, toInteger (limitTableResources limits))
          , (poolDescriptors, toInteger (limitTablePoolDescriptors limits))
          , (2, toInteger (limitBoundSets limits))
          , (entryBytes, toInteger (limitStorageRange limits))
          , (toInteger stride * (toInteger versions - 1), toInteger (maxBound ∷ Word32))
          , (toInteger ringBytes, toInteger most)
          ]
    case existing of
      Just _ → pure (Left (RefusedMisuse (DuplicateSubject ResourceIdentity)))
      Nothing → case [(asked, limit) | (asked, limit) ← checks, exceeds asked limit] of
        (asked, limit) : _ → pure (Left (RefusedOutOfBounds (fromInteger asked) (fromInteger limit)))
        -- Masked from the first creation to the table's publication, so a
        -- cancellation can arrive only at an interruptible point inside a
        -- step — which the unwinding then sees every generation made before —
        -- or once the table holds them all: never between a generation's
        -- creation and its recording here, nor before publication.
        [] → mask_ $ do
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
      -- Each native object is a generation of its own, made by one creation
      -- that rolls nothing back: a failure part-way leaves only whole
      -- generations, which the unwinding releases and the ordinary disposal
      -- destroys.
      samplers ←
        traverse
          (\sampler → step (construct recording 0 1 "vkCreateSampler" (\layer device _ _ → Right . NativeSampler sampler <$> opsCreateSampler layer device sampler) Nothing))
          [minBound .. maxBound]
      samplerHandles ← traverse handleOf samplers
      let setLayout set request = step (construct recording 0 1 "vkCreateDescriptorSetLayout" (\layer device _ _ → Right . NativeSetLayout set <$> opsCreateSetLayout layer device request) Nothing)
          pool set request = step (construct recording 0 1 "vkCreateDescriptorPool" (\layer device _ _ → Right . NativeDescriptorPool set <$> opsCreateDescriptorPool layer device request) Nothing)
      textureLayout ← setLayout 0 (TextureSetLayout samplerHandles (Book.tableCapacity config))
      lookupLayout ← setLayout 1 LookupSetLayout
      textureLayoutHandle ← handleOf textureLayout
      lookupLayoutHandle ← handleOf lookupLayout
      texturePool ← pool 0 (TexturePool 4 initialSlots)
      lookupPool ← pool 1 LookupPool
      device ←
        atomically (readRootsDevice (recordingRoots recording)) >>= \case
          Nothing → throwIO (Abandon RefusedDeviceAbsent)
          Just (_, handle) → pure handle
      -- Each set is allocated from its pool, which frees it: a failed
      -- allocation leaves the pool, a generation, to the unwinding.
      textureSet ← allocated device 0 texturePool textureLayoutHandle (Just initialSlots)
      lookupSet ← allocated device 1 lookupPool lookupLayoutHandle Nothing
      (ring, mapping, atom) ←
        createMapped recording LookupBuffer ringBytes >>= \case
          Left refusal → throwIO (Abandon refusal)
          Right made'@(resource, _, _) → made' <$ modifyIORef' made (resource :)
      versions ←
        traverse
          (\entry → (,) entry <$> step (construct recording 0 1 "the texture table's lookup version" (\_ _ _ _ → pure (Right (NativeVersion entry))) Nothing))
          [0 .. Book.tableVersionCount config - 1]
      rootsCall (recordingRoots recording) "vkUpdateDescriptorSets" $
        opsWriteDescriptors ops device [WriteLookupBuffer lookupSet (allocationBuffer mapping) (fromIntegral (Book.tableCapacity config) * 8)]
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
          , tableObjects = samplers <> [textureLayout, lookupLayout, lookupPool]
          , tableTexturePool = texturePool
          , tableRing = ring
          , tableVersions = Map.fromList versions
          , tableSetLayoutHandles = [textureLayoutHandle, lookupLayoutHandle]
          , tableSets = [textureSet, lookupSet]
          , tableMapping = mapping
          , tableStride = stride
          , tableEntries = Book.tableCapacity config
          , tableAtom = atom
          , tablePlaceholder = placeholder
          , tablePlaceholderWritten = False
          , tableTextures = Set.empty
          , tableSwapTickets = Map.empty
          }
    -- A set allocated from a pool the table made, named as the pool's set
    -- when the roots offer naming.
    allocated device set poolResource layout count = do
      poolHandle ← handleOf poolResource
      handle ← rootsCall (recordingRoots recording) "vkAllocateDescriptorSets" (opsAllocateSet ops device poolHandle layout count)
      readRootsInstrumentation (recordingRoots recording) >>= \case
        Nothing → pure ()
        Just (_, instrumentation) → nameRootsObject (recordingRoots recording) instrumentation ObjectDescriptorSet handle (tableSetName poolResource set)
      pure handle
    -- A table generation's one native handle.
    handleOf resource =
      nativeOf resource >>= \case
        NativeSampler _ handle → pure handle
        NativeSetLayout _ handle → pure handle
        NativeDescriptorPool _ handle → pure handle
        _ → throwIO (Abandon RefusedWrongKind)
    nativeOf resource =
      liveNative recording resource >>= \case
        Left refusal → throwIO (Abandon refusal)
        Right native → pure native
    -- Release everything made so far, newest first.
    unwind made = do
      resources ← readIORef made
      for_ resources (\resource → releaseManaged recording (Made resource))

-- | Grow set 0 (GRS-14), on the graphics owner's thread: a pool of its own
-- for a set of twice the allocated slots, never past the cap; that set,
-- allocated at the new count over the same layout; and every written slot's
-- descriptor copied into it at the same element, slot 0's placeholder
-- included once written. The immutable samplers are the layout's, so nothing
-- is copied into their binding. Then, in one transaction, the larger set
-- becomes current for every batch that binds the table afterwards and the
-- old set's pool is released: a batch that bound the old set retains its
-- pool, so it is destroyed only once no live batch holds it. Set 1, the
-- version ring, slots, handles and versions are unchanged, and so is every
-- pipeline layout, whose set 0 layout declared the cap.
--
-- A table at its cap is 'RefusedBackpressure' 'TextureSlotBudget'. A growth
-- whose pool or set allocation, or descriptor copy, fails gives back what it
-- made and leaves the current set and the bookkeeping as they were. A native
-- out of memory, once that rollback is complete, enters one reclamation pass
-- and at most one retry of the whole growth — the pool's creation obtains no
-- retry of its own — and a growth not recovered raises
-- 'AllocationNotRecovered'.
growSet ∷ Recording q inst msgr phys dev cmd → IO (Either Refusal ())
growSet recording =
  readTVarIO (recordingTable recording) >>= \case
    Nothing → pure (Left (RefusedIllegal "growing a texture table this session has not made"))
    Just table → case Book.growTable (tableBook table) of
      Left Book.TableAtCapacity → pure (Left (RefusedBackpressure TextureSlotBudget))
      Left refusal → pure (Left (RefusedIllegal ("growing the texture table: " <> tshow refusal)))
      Right (_, count) →
        atomically (readRootsDevice roots) >>= \case
          Nothing → pure (Left RefusedDeviceAbsent)
          Just _ →
            tryWithContext @SomeException (attempt table count) >>= \case
              Right (Left refusal) → pure (Left refusal)
              Right (Right made) → commit made
              Left (ExceptionWithContext _ exception)
                | Just (AfterCommit committed) ← fromException exception → throwIO committed
              Left failure@(ExceptionWithContext _ exception)
                | not (isAsynchronous exception)
                , rootsNativeFailure roots exception == Just FailedOutOfMemory →
                    withAllocationAttempt roots (\allocation → recoverAllocation roots "growing the texture table" allocation Nothing (Text.pack (displayException exception)) (failingAgain roots (attempt table count))) >>= \case
                      Right (Right (Right made)) → commit made
                      Right (Right (Left refusal)) → pure (Left refusal)
                      Right (Left notRecovered) → throwIO notRecovered
                      Left _ → rethrowIO failure
                | otherwise → rethrowIO failure
  where
    roots = recordingRoots recording
    -- One whole attempt: the pool, the set and the copy are one creation, so
    -- the model knows the pool as a generation only once all three succeeded.
    -- A step that raises destroys the pool natively before the creation
    -- raises, so the rollback is complete — nothing the attempt made is left
    -- for a reclamation pass to find or miss — before any retry.
    attempt table count = case (tableSetLayoutHandles table, listToMaybe (tableSets table)) of
      (layoutHandle : _, Just current) → do
        made ← newIORef Nothing
        let written = Set.toAscList (Set.union (Book.writtenSlots (tableBook table)) (if tablePlaceholderWritten table then Set.singleton 0 else Set.empty))
            create layer device _ issued = do
              poolHandle ← opsCreateDescriptorPool layer device (TexturePool 4 count)
              ( do
                  set ← rootsCall roots "vkAllocateDescriptorSets" (opsAllocateSet layer device poolHandle layoutHandle (Just count))
                  unless (null written) $
                    rootsCall roots "vkUpdateDescriptorSets" (opsWriteDescriptors layer device [CopySampledImages current set (runs written)])
                  -- The set is named here, under the identity the model is
                  -- about to issue its pool, so a naming that raises is
                  -- rolled back natively like every other step.
                  for_ issued $ \pool →
                    readRootsInstrumentation roots >>= \case
                      Nothing → pure ()
                      Just (_, instrumentation) → nameRootsObject roots instrumentation ObjectDescriptorSet set (tableSetName pool 0)
                  writeIORef made (Just set)
                  pure (Right (NativeDescriptorPool 0 poolHandle))
                )
                `onException` undoing roots "destroying a texture table growth's pool" (rootsCall roots "vkDestroyDescriptorPool" (opsDestroyDescriptorPool layer device poolHandle))
        tryWithContext @SomeException (constructOnce recording 0 1 "vkCreateDescriptorPool" create Nothing) >>= \case
          -- Once the creation returned, the model holds the pool, and what
          -- raises after it — naming the pool — releases it for disposal
          -- rather than destroying it. An out of memory there is no failure
          -- of the growth's allocations, whose rollback was native, so it
          -- is raised as itself, with no recovery: a retry could otherwise
          -- run beside a pool not yet destroyed.
          Left failure@(ExceptionWithContext _ exception) →
            readIORef made >>= \case
              Just _
                | not (isAsynchronous exception)
                , rootsNativeFailure roots exception == Just FailedOutOfMemory →
                    throwIO (AfterCommit exception)
              _ → rethrowIO failure
          Right (Left refusal) → pure (Left refusal)
          Right (Right pool) →
            readIORef made >>= \case
              Just set → pure (Right (pool, set))
              Nothing → Left RefusedWrongKind <$ releaseManaged recording (Made pool)
      _ → pure (Left RefusedWrongKind)
    -- The larger set becomes current, and the old set's pool is released, in
    -- one transaction: no cancellation leaves both live or neither current.
    commit (pool, set) = atomically $ do
      held ← readTVar (recordingTable recording)
      case held of
        Nothing → pure (Left (RefusedIllegal "the texture table vanished while it grew"))
        Just table → case Book.growTable (tableBook table) of
          Left refusal → pure (Left (RefusedIllegal ("growing the texture table: " <> tshow refusal)))
          Right (book, _) → do
            writeTVar
              (recordingTable recording)
              (Just table {tableBook = book, tableTexturePool = pool, tableSets = set : drop 1 (tableSets table)})
            fmap (const ()) <$> releaseLive recording (tableTexturePool table)

-- | Consecutive slots as runs: a first slot and a count.
runs ∷ [Word32] → [(Word32, Word32)]
runs = \case
  [] → []
  first : rest →
    let (following, after) = span' (first + 1) rest
     in (first, 1 + fromIntegral (length following)) : runs after
  where
    span' next = \case
      slot : more | slot == next → let (taken, left) = span' (next + 1) more in (slot : taken, left)
      remaining → ([], remaining)

-- | Set 0's slot counts, generation by generation: the initial size, doubled
-- until the cap.
setGenerations ∷ Word32 → Word32 → [Word32]
setGenerations initial cap = initial : if initial >= cap then [] else setGenerations (Book.grownSlots initial cap) cap

-- | A failure raised after a growth's creation committed its pool, which no
-- allocation recovery covers.
newtype AfterCommit = AfterCommit SomeException
  deriving (Show)

instance Exception AfterCommit

-- | A construction step's refusal, carried out of the steps to undo them.
newtype Abandon = Abandon Refusal
  deriving (Show)

instance Exception Abandon

-- | Any generation the table made, as a handle 'releaseManaged' releases.
newtype Made = Made ResourceId

instance Managed Made where
  managedResource (Made resource) = resource

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
  owned recording . checkpointed recording $
    liveNative recording image >>= \case
      Left refusal → pure (Left refusal)
      Right (NativeImage description _ _)
        | imageKind description /= TextureImage → pure (Left RefusedWrongKind)
        | otherwise → mask $ \restore → do
            let reserve = atomically $
                  readTVar (recordingTable recording) >>= \case
                    Nothing → pure (Left (Just (RefusedIllegal "registering a texture with a session that has made no texture table")))
                    Just table
                      | Set.member image (tableTextures table) → pure (Left (Just (RefusedMisuse (DuplicateSubject ResourceIdentity))))
                      | otherwise → case Book.registerTexture image (tableBook table) of
                          Left _ → pure (Left Nothing)
                          Right (book, handle) → do
                            writeTVar (recordingTable recording) (Just table {tableBook = book, tableTextures = Set.insert image (tableTextures table)})
                            pure (Right handle)
            -- No free slot: the table grows at once (GRS-14), even while
            -- released slots are still retiring, and the registration is
            -- made in the larger set. At the cap it is backpressure.
            registered ←
              reserve >>= \case
                Right handle → pure (Right handle)
                Left (Just refusal) → pure (Left refusal)
                Left Nothing →
                  growSet recording >>= \case
                    Left refusal → pure (Left refusal)
                    Right () → either (Left . fromMaybe (RefusedBackpressure TextureSlotBudget)) Right <$> reserve
            case registered of
              Left refusal → pure (Left refusal)
              -- An image whose upload already completed completes now. If
              -- that refresh raises, is cancelled or refuses, the handle is
              -- never handed out, so the registration is undone first: the
              -- caller keeps its image, and may register it again. An undo
              -- that is itself refused raises 'RegistrationNotUndone', which
              -- carries the live handle, so it is never lost.
              Right handle →
                tryWithContext @SomeException (restore (refreshTable recording)) >>= \case
                  Right (Right ()) → pure (Right handle)
                  Right (Left refusal) → do
                    undone handle (tshow refusal) =<< unregister recording image handle
                    pure (Left refusal)
                  Left failure@(ExceptionWithContext _ exception) → do
                    undone handle (Text.pack (displayException exception)) =<< unregister recording image handle
                    rethrowIO failure
      Right _ → pure (Left RefusedWrongKind)

-- | Ask a live handle to show a replacement texture (GRS-9): the image an
-- admitted upload (#342) is filling, or one whose upload completed. The
-- table holds the replacement from now on, as it holds a registered image.
-- Until the replacement's upload completes, the handle keeps resolving to
-- what it shows now; in the first version published after completion it
-- resolves to the replacement, whose descriptor is written first into a slot
-- no live version maps, and the texture it replaced is released then — it is
-- destroyed only once no batch retains it, and its slot reused only once no
-- live version maps it. The replacement may differ from the old texture in
-- format, extent and mip count.
--
-- A swap still pending on the handle is superseded: its replacement is
-- released at once — an upload not yet started is cancelled, one copying
-- finishes first — and never shown. The answered 'SwapTicket' reports where
-- the swap stands; a replacement whose upload is cancelled or lost, or a
-- session that fails first, leaves the handle on what it showed and reports
-- 'SwapFailed'.
--
-- Refused, changing nothing — the mapping, a pending swap, and the
-- replacement, which stays the caller's: a stale handle, as
-- 'RefusedStaleHandle'; a session with no table; an image that is not this
-- session's live texture; one the table already holds — registered, or
-- another swap's replacement — as 'DuplicateSubject'; one no upload fills, as
-- 'RefusedNotWritten'; and a full table at its cap, as
-- 'RefusedBackpressure' 'TextureSlotBudget', until a released texture's slot
-- is reclaimed. Below the cap, the table grows first (GRS-14). Like all new
-- work, refused once the session has failed.
swapTexture ∷ Recording q inst msgr phys dev cmd → Book.TextureHandle → Image → IO (Either Refusal SwapTicket)
swapTexture recording handle (Image image) =
  owned recording . checkpointed recording $
    liveNative recording image >>= \case
      Left refusal → pure (Left refusal)
      Right (NativeImage description _ _)
        | imageKind description /= TextureImage → pure (Left RefusedWrongKind)
        | otherwise → do
            let accept = atomically $ do
                  model ← stateRootsModel roots (\held → (held, held))
                  uploading ← Set.member image <$> readTVar (recordingUploading recording)
                  readTVar (recordingTable recording) >>= \case
                    Nothing → pure (Left (Just (RefusedIllegal "swapping a texture in a session that has made no texture table")))
                    Just table
                      | Set.member image (tableTextures table) → pure (Left (Just (RefusedMisuse (DuplicateSubject ResourceIdentity))))
                      | not uploading && resourceInitialization image model /= Just Initialized →
                          pure (Left (Just (RefusedNotWritten "no upload fills the replacement: admit one first, or name a texture whose upload completed")))
                      | otherwise → case Book.swapTexture handle image (tableBook table) of
                          Left Book.TableFull → pure (Left Nothing)
                          Left _ → pure (Left (Just (RefusedStaleHandle handle)))
                          Right (book, superseded) →
                            -- The superseded replacement is released first:
                            -- a refusal changes nothing.
                            maybe (pure (Right ())) (releaseLive recording) superseded >>= \case
                              Left refusal → pure (Left (Just refusal))
                              Right () → do
                                cell ← newTVar SwapPending
                                for_ superseded $ \old → for_ (Map.lookup old (tableSwapTickets table)) (`writeTVar` SwapSuperseded)
                                writeTVar
                                  (recordingTable recording)
                                  ( Just
                                      table
                                        { tableBook = book
                                        , tableTextures = Set.insert image (maybe id Set.delete superseded (tableTextures table))
                                        , tableSwapTickets = Map.insert image cell (maybe id Map.delete superseded (tableSwapTickets table))
                                        }
                                  )
                                pure (Right (SwapTicket cell sessionFailed))
            -- No free slot: the table grows at once, as for a registration.
            accept >>= \case
              Right ticket → pure (Right ticket)
              Left (Just refusal) → pure (Left refusal)
              Left Nothing →
                growSet recording >>= \case
                  Left refusal → pure (Left refusal)
                  Right () → either (Left . fromMaybe (RefusedBackpressure TextureSlotBudget)) Right <$> accept
      Right _ → pure (Left RefusedWrongKind)
  where
    roots = recordingRoots recording
    -- Whether the session has failed: its terminal report names a primary.
    sessionFailed = isJust . reportPrimary <$> readRootsTerminal roots

-- | Undo a registration whose handle was never handed out, answering
-- whether it was undone.
unregister ∷ Recording q inst msgr phys dev cmd → ResourceId → Book.TextureHandle → IO Bool
unregister recording image handle =
  atomically $
    readTVar (recordingTable recording) >>= \case
      Nothing → pure False
      Just table → case Book.unregisterTexture handle (tableBook table) of
        Right book → True <$ writeTVar (recordingTable recording) (Just table {tableBook = book, tableTextures = Set.delete image (tableTextures table)})
        Left _ → pure False

-- | Raise 'RegistrationNotUndone' unless the undo happened.
undone ∷ Book.TextureHandle → Text → Bool → IO ()
undone handle cause = \case
  True → pure ()
  False → throwIO (RegistrationNotUndone handle cause)

-- | A registration whose refresh failed — for the reason given — could not
-- be undone: the handle is live, and is the caller's to release.
data RegistrationNotUndone = RegistrationNotUndone !Book.TextureHandle !Text
  deriving (Show)

instance Exception RegistrationNotUndone

-- | Release a handle: it resolves to nothing from the next version on, its
-- index may be issued again under a new generation, and its slot retires.
-- The image is released once no live version maps the slot — at once if the
-- texture never completed, or once every batch that bound a version mapping
-- it has completed. A swap still pending on the handle (GRS-9) ends with it:
-- its replacement is released at once — an upload not yet started is
-- cancelled, one copying finishes first — and never shown, and its ticket
-- reports 'SwapAbandoned'. A stale handle is 'RefusedStaleHandle'.
releaseTexture ∷ Recording q inst msgr phys dev cmd → Book.TextureHandle → IO (Either Refusal ())
releaseTexture recording handle =
  owned recording $ do
    released ← atomically $
      readTVar (recordingTable recording) >>= \case
        Nothing → pure (Left (RefusedStaleHandle handle))
        Just table → case Book.releaseTexture handle (tableBook table) of
          Left _ → pure (Left (RefusedStaleHandle handle))
          Right book → do
            let pending = snd <$> Book.pendingSwap handle (tableBook table)
            maybe (pure (Right ())) (releaseLive recording) pending >>= \case
              Left refusal → pure (Left refusal)
              Right () → do
                for_ pending $ \replacement → for_ (Map.lookup replacement (tableSwapTickets table)) (`writeTVar` SwapAbandoned)
                Right ()
                  <$ writeTVar
                    (recordingTable recording)
                    ( Just
                        table
                          { tableBook = book
                          , tableTextures = maybe id Set.delete pending (tableTextures table)
                          , tableSwapTickets = maybe id Map.delete pending (tableSwapTickets table)
                          }
                    )
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
  owned recording . checkpointed recording $
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
  , tableViewAllocated ∷ !Word32
    -- ^ How many slots the current set 0 holds, slot 0 included (GRS-14).
  , tableViewSets ∷ ![Word64]
  , tableViewSwaps ∷ ![(Book.TextureHandle, Word32, ResourceId)]
    -- ^ Each pending swap (GRS-9): the handle, its replacement's reserved
    -- slot, and the replacement.
    -- ^ The current set 0, then set 1.
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
          , tableViewAllocated = Book.allocatedSlots book
          , tableViewSets = tableSets table
          , tableViewSwaps = [(handle, slot, image) | (handle, _) ← Book.pendingSwaps book, Just (slot, image) ← [Book.pendingSwap handle book]]
          }

roundUp ∷ Natural → Natural → Natural
roundUp value granule
  | granule <= 1 = value
  | otherwise = ((value + granule - 1) `div` granule) * granule
