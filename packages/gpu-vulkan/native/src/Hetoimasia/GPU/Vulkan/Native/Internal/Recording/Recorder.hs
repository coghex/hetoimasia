-- | Scoped recording for the managed recording
-- ("Hetoimasia.GPU.Vulkan.Native.Recording"): 'recordFrame', which reserves
-- one batch against an acquired frame, lends a 'Recorder' to one consumer
-- action and seals the batch or leaves it partial, and the commands that
-- recorder records. Every command validates the recorder, its state and the
-- handles it names, then retains what it references in the model and records
-- it in one masked step; the batch's and each pass's labels are balanced
-- before 'recordFrame' returns or raises.
--
-- This module owns each 'Recorder' and its mutable references — whether it is
-- open, the image layout and bindings it tracks, the use each managed buffer
-- and image it has touched is in (GRS-3), and its count of open label regions
-- — for one consumer action on the graphics owner's thread. It records each
-- batch's entry barriers as their transitions are recorded, and its exit
-- barriers as it seals. It inserts batch records into the recording's state
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State") and advances them
-- while recording, and marks a readback buffer as copied into; ending a batch
-- afterwards is the batch lifecycle's
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Batches").
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Recorder
  ( Recorder
  , recorderBatch
  , recordFrame
  , recordFrameless
  , transitionImage
  , transitionResource
  , beginRendering
  , PassStart (..)
  , beginRenderingInto
  , endRendering
  , bindPipeline
  , setViewport
  , setScissor
  , draw
  , copyToReadback
  , copyTargetToReadback
  , readbackBytesFor
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar, readTVarIO)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, displayException, mask, mask_, rethrowIO, tryWithContext)
import Control.Applicative ((<|>))
import Control.Monad (when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model.Access (BatchAccess, Barrier (..), BarrierRole (EntryBarrier), Contents (..), ResourceUse (..), TransitionSource (..), emptyAccess)
import qualified Hetoimasia.GPU.Model.Access as Access
import Hetoimasia.GPU.Model
  ( FramePhase (..)
  , FrameView (..)
  , HoldKind (..)
  , HoldView (..)
  , Outcome (..)
  , enterResource
  , extendBatch
  , framelessSlots
  , modelBudgets
  , openFramelessBatch
  , frameView
  , holdView
  , recordBatch
  )
import Hetoimasia.GPU.Model.Identity
  ( BatchId
  , FrameSlotId
  , GenerationId
  , HoldSubject (..)
  , IdentityKind (..)
  , Misuse (..)
  , ResourceId
  , frameSlotNumber
  , frameTarget
  , generationTarget
  , imageGeneration
  , imageIndex
  )
import Hetoimasia.GPU.Vulkan.Native.Generations (GenerationView (..), TargetGenerationsView (..), readTargetGenerations)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Batches (retireCompleted, retireCompletedOn)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Construction (createFramelessStorage)
import Hetoimasia.GPU.Vulkan.Native.Allocator (BoundMemory (memoryResource))
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer
  ( ClearColor
  , ImageDescription (..)
  , ImageKind (..)
  , ImageUse (..)
  , formatCode
  , imageKindUse
  , imageResourceKind
  , ImageLayout (..)
  , NativeCommand (..)
  , ReadbackAllocation (..)
  , RecordingOps (..)
  , Rect (..)
  , Viewport (..)
  , nativeName
  , resourceBarrier
  , supportedTransition
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( BatchRecord (..)
  , BatchStanding (..)
  , BatchTicket (..)
  , FrameStorage (..)
  , Image (..)
  , Managed (managedResource)
  , ManagedRecord (..)
  , ManagedStanding (..)
  , NativeResource (..)
  , Ordered
  , Pipeline (..)
  , Readback (..)
  , ReadbackContents (..)
  , Recording (..)
  , Refusal (..)
  , StorageOwner (..)
  , editBatch
  , editManaged
  , isAsynchronous
  , liveNative
  , newTicket
  , checkpointed
  , modelAnswer
  , orderedObject
  , owned
  , tshow
  )
import Hetoimasia.GPU.Model.Budget (BudgetKind (FramelessBatchBudget), framelessBatchLimit)
import Hetoimasia.GPU.Vulkan.Native.Naming (batchLabel, framelessBatchLabel, passLabel, targetPassLabel)
import Hetoimasia.GPU.Vulkan.Native.Presentation (GenerationPlan (..), SurfaceExtent (..), SurfaceFormat (..), imageUsageTransferSource)
import Hetoimasia.GPU.Vulkan.Native.Roots (Roots, readRootsInstrumentation, rootsCall, stateRootsModel)

data RecorderState = RecorderState
  { stateLayout ∷ !ImageLayout
  , stateRendering ∷ !(Maybe Attachment)
    -- ^ The attachment of the pass that is open, if one is.
  , statePipeline ∷ !(Maybe (ResourceId, Word32))
    -- ^ The bound pipeline, and the color format it was built for.
  , stateViewport ∷ !(Maybe Viewport)
  , stateScissor ∷ !(Maybe Rect)
  , stateAccess ∷ !(BatchAccess ResourceId)
    -- ^ The use each managed buffer and image the batch has touched is in
    -- (GRS-3).
  , stateObjects ∷ !(Map.Map ResourceId (Word64, Maybe (Word32, Word32)))
    -- ^ The native handle of each of them, and an image's aspect and mip
    -- levels, for the exit barriers the seal records.
  }

-- | The frame a recorder renders into, as the generation that owns its image
-- describes it.
data FrameImage = FrameImage
  { frameImageHandle ∷ !Word64
  , frameImageView ∷ !Word64
  , frameImageExtent ∷ !SurfaceExtent
  , frameImageFormat ∷ !Word32
  , frameImageCapturable ∷ !Bool
    -- ^ Whether its generation made it a transfer source.
  , frameImageGeneration ∷ !GenerationId
  }

-- | A recorder lent to one consumer action. Every command checks that the
-- action is still running; one kept past it records nothing.
data Recorder q inst msgr phys dev cmd = Recorder
  { recorderRecording ∷ !(Recording q inst msgr phys dev cmd)
  , recorderBatch ∷ !BatchId
    -- ^ The batch this recorder records into.
  , recorderCommands ∷ !cmd
  , recorderFrame ∷ !(Maybe FrameImage)
    -- ^ The frame's image, or 'Nothing' for a frame-less batch, which has no
    -- swapchain image and refuses every command that needs one.
  , recorderOpen ∷ !(IORef Bool)
  , recorderState ∷ !(IORef RecorderState)
  , recorderLabelled ∷ !Bool
    -- ^ Whether the device offers naming, and so this batch is labelled.
  , recorderLabels ∷ !(IORef Natural)
    -- ^ How many label regions are open in the command buffer: each one whose
    -- opening call returned, less each whose closing call returned.
  }

-- | Record one batch for an acquired frame, running the consumer exactly once
-- with a recorder that is closed when it returns or raises.
--
-- Before anything native, the frame must be acquired in the model, with its
-- image's generation still recordable; its slot must have a live storage with
-- no batch of its own outstanding; and the model must admit the batch, which
-- reserves its record and retains the frame's generation and the storage. The
-- batch is sealed only if the consumer returns with rendering ended; otherwise
-- it is left partial and owned, and whatever the consumer raised is re-raised.
recordFrame
  ∷ Recording q inst msgr phys dev cmd
  → FrameSlotId
  → (Recorder q inst msgr phys dev cmd → IO a)
  → IO (Either Refusal (BatchId, a))
recordFrame recording frame consumer =
  owned recording . checkpointed recording $
    -- The frame is checked before anything is done for its slot: a stale or
    -- foreign frame must fail before the slot's storage is touched.
    (atomically (frameAcquired recording frame) >>= \case
      Left refusal → pure (Left refusal)
      Right () → retireCompleted recording frame) >>= \case
      Left refusal → pure (Left refusal)
      Right () →
        checkFrame recording frame >>= \case
          Left refusal → pure (Left refusal)
          Right (storage, commands, image) → mask $ \restore → do
            admitted ← atomically $ do
              answer ← modelAnswer roots (recordBatch frame [storage])
              for_ answer $ \batch →
                modifyTVar' (recordingBatches recording) (Map.insert batch (BatchRecord (Just frame) Nothing storage BatchRecording 0 []))
              pure answer
            case admitted of
              Left refusal → pure (Left refusal)
              Right batch → recordAdmitted recording batch commands (Just image) (batchLabel batch (frameImageGeneration image)) restore consumer
  where
    roots = recordingRoots recording


-- | Record one frame-less batch (GRS-12): a batch that belongs to no frame,
-- with no swapchain image, recorded with the same commands and checks as a
-- frame's — #335's transitions and boundary barriers included — into the
-- command storage of the lowest free frame-less slot.
--
-- Before anything native is recorded the slot needs a live storage — made
-- the first time it is used, and reset of a batch whose submission has
-- completed before it is used again — and the model must admit the batch,
-- which counts the slot against the frame-less batch budget, reserves its
-- objects and retains the storage. A refusal there opens nothing. Once the
-- model has admitted it, the batch is announced to the caller with its
-- ticket, before the consumer runs, so whatever becomes of it — sealed,
-- partial or raised — the caller can submit or discard it. It is sealed, or
-- left partial and owned, exactly as a frame's batch is; it is submitted only
-- by its owner's frame-less submission, and never with a frame.
recordFrameless
  ∷ Recording q inst msgr phys dev cmd
  → (BatchTicket → IO ())
  → (Recorder q inst msgr phys dev cmd → IO a)
  → IO (Either Refusal (BatchTicket, a))
recordFrameless recording announce consumer =
  owned recording . checkpointed recording $ do
    model ← atomically (stateRootsModel roots (\current → (current, current)))
    let limit = framelessBatchLimit (modelBudgets model)
        taken = map fst (framelessSlots model)
    case [slot | slot ← [0 .. limit - 1], slot `notElem` taken] of
      [] → pure (Left (RefusedBackpressure FramelessBatchBudget))
      slot : _ →
        storageFor slot >>= \case
          Left refusal → pure (Left refusal)
          Right (storage, commands) → mask $ \restore → do
            admitted ← atomically $ do
              answer ← modelAnswer roots (openFramelessBatch [storage])
              case answer of
                Left refusal → pure (Left refusal)
                Right (batch, opened)
                  -- One owner decides every opening, so the model takes the
                  -- slot found free above.
                  | opened /= slot → pure (Left (RefusedIllegal "the model opened another frame-less slot than the one prepared"))
                  | otherwise → do
                      ticket ← newTicket
                      modifyTVar' (recordingBatches recording) (Map.insert batch (BatchRecord Nothing (Just ticket) storage BatchRecording 0 []))
                      pure (Right (BatchTicket batch ticket (recordingOwner recording)))
            case admitted of
              Left refusal → pure (Left refusal)
              Right ticket → do
                announce ticket
                fmap (\(_, value) → (ticket, value)) <$> recordAdmitted recording (ticketBatch ticket) commands Nothing (framelessBatchLabel (ticketBatch ticket)) restore consumer
  where
    roots = recordingRoots recording
    -- The slot's live storage, made if it has none, and reset of a batch
    -- whose submission completed.
    storageFor slot = do
      existing ← Map.lookup (StorageOfFrameless slot) <$> readTVarIO (recordingStorages recording)
      made ← case existing of
        Just resource → pure (Right resource)
        Nothing → fmap (\(FrameStorage resource) → resource) <$> createFramelessStorage recording slot
      case made of
        Left refusal → pure (Left refusal)
        Right resource →
          retireCompletedOn recording (StorageOfFrameless slot) >>= \case
            Left refusal → pure (Left refusal)
            Right () → atomically $ do
              managed ← readTVar (recordingManaged recording)
              batches ← readTVar (recordingBatches recording)
              pure $ case Map.lookup resource managed of
                Just (ManagedRecord (NativeStorage _ _ commands) ManagedLive)
                  | any ((== resource) . batchStorage) (Map.elems batches) → Left (RefusedMisuse (DuplicateSubject BatchIdentity))
                  | otherwise → Right (resource, commands)
                _ → Left RefusedNoStorage

-- | Run one admitted batch's recording: begin its command buffer and label
-- it, run the consumer exactly once with a recorder that is closed when it
-- returns or raises, and seal the batch — recording the exit barriers it
-- owes — or leave it partial and owned, re-raising whatever the consumer
-- raised. A frame batch has its frame's image; a frame-less one has none.
recordAdmitted
  ∷ Recording q inst msgr phys dev cmd
  → BatchId
  → cmd
  → Maybe FrameImage
  → ByteString
  → (∀ b. IO b → IO b)
  → (Recorder q inst msgr phys dev cmd → IO a)
  → IO (Either Refusal (BatchId, a))
recordAdmitted recording batch commands image label restore consumer = do
  opened ← newIORef True
  state ← newIORef (RecorderState LayoutUndefined Nothing Nothing Nothing Nothing emptyAccess Map.empty)
  labelled ← isJust <$> readRootsInstrumentation roots
  labels ← newIORef 0
  let recorder = Recorder recording batch commands image opened state labelled labels
      partial reason = atomically (editBatch recording batch (\entry → entry {batchStanding = BatchPartial reason}))
      recording' = atomically (fmap batchStanding . Map.lookup batch <$> readTVar (recordingBatches recording))
      -- Close every open label. One whose closing raised leaves
      -- the batch partial, and its failure is answered, not
      -- raised, so the caller keeps the failure it already has.
      balance =
        balanceLabels recorder >>= \case
          Right () → pure Nothing
          Left failure@(ExceptionWithContext _ exception) → do
            partial ("the batch's labels could not be balanced: " <> Text.pack (displayException exception))
            pure (Just failure)
  began ← tryWithContext @SomeException (rootsCall roots "vkBeginCommandBuffer" (opsBeginCommands (recordingOps recording) commands))
  case began of
    Left failure@(ExceptionWithContext _ exception) → do
      writeIORef opened False
      partial ("beginning the command buffer raised: " <> Text.pack (displayException exception))
      rethrowIO failure
    Right () → do
      opening ←
        if labelled
          then tryWithContext @SomeException (recordLabel recorder (CommandBeginLabel label))
          else pure (Right ())
      ran ← case opening of
        Left failure → pure (Left failure)
        Right () → tryWithContext @SomeException (restore (consumer recorder))
      writeIORef opened False
      case ran of
        Left failure@(ExceptionWithContext _ exception) → do
          -- A command that failed has already said why the batch
          -- is partial; that reason stands.
          standing ← recording'
          when (standing == Just BatchRecording) $
            partial
              ( (if isAsynchronous exception then "a cancellation ended the consumer: " else "the consumer raised: ")
                  <> Text.pack (displayException exception)
              )
          _ ← balance
          rethrowIO failure
        Right value → do
          rendering ← isJust . stateRendering <$> readIORef state
          standing ← recording'
          if standing /= Just BatchRecording
            then do
              _ ← balance
              pure (Left (RefusedIllegal "a command failed during recording, so the batch was not sealed"))
            else if rendering
            then do
              partial "the consumer left rendering open"
              _ ← balance
              pure (Left (RefusedIllegal "the consumer left rendering open, so the batch was not sealed"))
            else do
              ended ← readIORef state
              case Access.sealAccess (stateAccess ended) of
                Left refusal → do
                  let reason = describeAccess refusal
                  partial ("the consumer left " <> reason)
                  _ ← balance
                  pure (Left (RefusedIllegal ("the consumer left " <> reason <> ", so the batch was not sealed")))
                -- The exit barriers, inside the batch's label:
                -- one that raised leaves the batch partial, as
                -- any command's failure does, and is raised once
                -- the labels are balanced.
                Right exits →
                  tryWithContext @SomeException (for_ (exitBarriers (stateObjects ended) exits) (recordLabel recorder)) >>= \case
                    Left failure → balance >> rethrowIO failure
                    Right () →
                      balance >>= \case
                        Just failure → rethrowIO failure
                        Nothing →
                          tryWithContext @SomeException (rootsCall roots "vkEndCommandBuffer" (opsEndCommands (recordingOps recording) commands)) >>= \case
                            Left failure@(ExceptionWithContext _ exception) → do
                              partial ("ending the command buffer raised: " <> Text.pack (displayException exception))
                              rethrowIO failure
                            Right () → do
                              atomically (editBatch recording batch (\entry → entry {batchStanding = BatchSealed}))
                              pure (Right (batch, value))

  where
    roots = recordingRoots recording

-- | Whether the model holds this frame acquired: its identity resolves —
-- this session's, this slot's current use — and it has an image. Any other
-- answer is the model's own classification of the misuse.
frameAcquired ∷ Recording q inst msgr phys dev cmd → FrameSlotId → STM (Either Refusal ())
frameAcquired recording frame = do
  model ← stateRootsModel (recordingRoots recording) (\model → (model, model))
  pure $ case frameView frame model of
    Nothing → Left (RefusedMisuse (case recordBatch frame [] model of
      Rejected misuse → misuse
      _ → UnknownIdentity FrameIdentity))
    Just view
      | viewFramePhase view /= FrameAcquired → Left (RefusedMisuse (WrongPhase FrameIdentity))
      | otherwise → Right ()

-- | Everything 'recordFrame' checks before it asks the model for a batch.
checkFrame
  ∷ Recording q inst msgr phys dev cmd → FrameSlotId → IO (Either Refusal (ResourceId, cmd, FrameImage))
checkFrame recording frame = atomically $ do
  model ← stateRootsModel roots (\model → (model, model))
  case frameView frame model of
    Nothing → pure (Left (RefusedMisuse (misuseOf model)))
    Just view
      | viewFramePhase view /= FrameAcquired → pure (Left (RefusedMisuse (WrongPhase FrameIdentity)))
      | otherwise → case viewFrameImage view of
          Nothing → pure (Left (RefusedMisuse (WrongPhase FrameIdentity)))
          Just image → do
            storages ← readTVar (recordingStorages recording)
            managed ← readTVar (recordingManaged recording)
            batches ← readTVar (recordingBatches recording)
            generations ← readTargetGenerations (recordingGenerations recording) (generationTarget (imageGeneration image))
            let located = do
                  storage ← maybe (Left RefusedNoStorage) Right (Map.lookup (StorageOfFrame (frameTarget frame) (frameSlotNumber frame)) storages)
                  commands ← case Map.lookup storage managed of
                    Just (ManagedRecord (NativeStorage _ _ commands) ManagedLive) → Right commands
                    _ → Left RefusedNoStorage
                  -- One storage, one outstanding batch: the slot's previous
                  -- batch must be discarded or reset first.
                  when (any ((== storage) . batchStorage) (Map.elems batches)) $
                    Left (RefusedMisuse (DuplicateSubject FrameIdentity))
                  native ← maybe (Left (RefusedMisuse (StaleIdentity GenerationIdentity))) Right $ do
                    targetView ← generations
                    generation ← lookup (imageGeneration image) [(viewGeneration each, each) | each ← viewGenerations targetView]
                    let index = fromIntegral (imageIndex image)
                    handle ← nth index (viewImages generation)
                    imageView ← nth index (viewImageViews generation)
                    let plan = viewPlan generation
                    pure (FrameImage handle imageView (planExtent plan) (surfaceFormat (planFormat plan)) (planUsage plan .&. imageUsageTransferSource /= 0) (imageGeneration image))
                  pure (storage, commands, native)
            pure located
  where
    roots = recordingRoots recording
    -- The model's own classification of a frame it cannot resolve: asking it
    -- to record against the frame, and keeping only the refusal, changes
    -- nothing.
    misuseOf model = case recordBatch frame [] model of
      Rejected misuse → misuse
      _ → UnknownIdentity FrameIdentity
    nth index list = case drop index list of
      entry : _ | index >= 0 → Just entry
      _ → Nothing

-- | Run a command that needs the frame's swapchain image, which a frame-less
-- batch has not: refused there before anything else is asked.
withImage ∷ Recorder q inst msgr phys dev cmd → (FrameImage → IO (Either Refusal a)) → IO (Either Refusal a)
withImage recorder continue = case recorderFrame recorder of
  Nothing → pure (Left (RefusedUnsupported "a command that needs a swapchain image, in a frame-less batch"))
  Just image → continue image

-- | Run one command: check the recorder is open and on the owner's thread,
-- decide the command against the recorder's state and the handles it names,
-- retain what it references in the model, and only then record it. The
-- retention and the native call are one masked step, so a cancellation can
-- land only before the first or after the second.
command
  ∷ Recorder q inst msgr phys dev cmd
  → (RecorderState → Either Refusal (RecorderState, [ResourceId], NativeCommand))
  → IO (Either Refusal ())
command recorder decide = commandSequence recorder (fmap (\(next, references, native) → (next, references, [native])) . decide)

-- | 'command' for a decision that records several native commands in order —
-- a rendering boundary and the label around it — in the same masked step. The
-- recorder's state advances only once every one of them has been recorded; a
-- label region counts as open from the moment its opening call returned.
commandSequence
  ∷ Recorder q inst msgr phys dev cmd
  → (RecorderState → Either Refusal (RecorderState, [ResourceId], [NativeCommand]))
  → IO (Either Refusal ())
commandSequence recorder decide = orderedSequence recorder (fmap (\(next, references, natives) → (next, references, [], natives)) . decide)

-- | 'commandSequence' for a decision that is also a batch's first touch of
-- managed resources (GRS-3): each is entered in the model, keeping or
-- discarding its contents, in the same transaction that retains it, so an
-- image that awaits initialization is refused before anything is retained or
-- recorded.
orderedSequence
  ∷ Recorder q inst msgr phys dev cmd
  → (RecorderState → Either Refusal (RecorderState, [ResourceId], [(ResourceId, Contents)], [NativeCommand]))
  → IO (Either Refusal ())
orderedSequence recorder decide =
  owned recording $
    readIORef (recorderOpen recorder) >>= \case
      False → pure (Left RefusedRecorderClosed)
      True → do
        state ← readIORef (recorderState recorder)
        case decide state of
          Left refusal → pure (Left refusal)
          Right (next, references, entries, natives) → mask_ $ do
            retained ←
              if null references
                then pure (Right ())
                else atomically (retain roots batch (unique references) entries)
            case retained of
              Left refusal → pure (Left refusal)
              Right () → do
                for_ natives (recordNative recorder)
                writeIORef (recorderState recorder) next
                pure (Right ())
  where
    recording = recorderRecording recorder
    roots = recordingRoots recording
    batch = recorderBatch recorder
    unique = Map.keys . Map.fromList . map (\resource → (resource, ()))

-- | Retain the references in the batch, then enter each first touch, as one
-- edit of the model: any refusal leaves it as it was.
retain ∷ Roots q inst msgr phys dev → BatchId → [ResourceId] → [(ResourceId, Contents)] → STM (Either Refusal ())
retain roots batch references entries = stateRootsModel roots $ \model →
  case answered (extendBatch batch references model) >>= \extended → foldl' enter (Right extended) entries of
    Left refusal → (Left refusal, model)
    Right next → (Right (), next)
  where
    enter current (resource, contents) =
      current >>= \model → case enterResource batch resource contents model of
        Rejected (WrongPhase ResourceIdentity) → Left RefusedUninitialized
        answer → answered answer
    answered = \case
      Admitted next → Right next
      Backpressure kind → Left (RefusedBackpressure kind)
      Rejected misuse → Left (RefusedMisuse misuse)

-- | Record one native command into the batch and count it, keeping the count
-- of open label regions. A call that raised may or may not have reached the
-- buffer, so the batch can never be sealed: it is partial, the recorder records
-- nothing more, and a consumer that catches the failure cannot change either.
recordNative ∷ Recorder q inst msgr phys dev cmd → NativeCommand → IO ()
recordNative recorder native =
  tryWithContext @SomeException (rootsCall roots (nativeName native) (opsRecord (recordingOps recording) (recorderCommands recorder) native)) >>= \case
    Left failure@(ExceptionWithContext _ exception) → do
      writeIORef (recorderOpen recorder) False
      atomically $
        editBatch recording batch $ \entry →
          entry {batchStanding = BatchPartial (nativeName native <> " raised: " <> Text.pack (displayException exception))}
      rethrowIO failure
    Right () → do
      atomically (editBatch recording batch (\entry → entry {batchCommands = batchCommands entry + 1}))
      case native of
        CommandBeginLabel _ → modifyIORef' (recorderLabels recorder) (+ 1)
        CommandEndLabel → modifyIORef' (recorderLabels recorder) (\open → if open > 0 then open - 1 else 0)
        _ → pure ()
  where
    recording = recorderRecording recorder
    roots = recordingRoots recording
    batch = recorderBatch recorder

-- | Record one label command outside any consumer command: the batch's own.
recordLabel ∷ Recorder q inst msgr phys dev cmd → NativeCommand → IO ()
recordLabel recorder native = mask_ (recordNative recorder native)

-- | Close every label region the batch still has open, innermost first. The
-- first closing call that raised stops it and is answered; the regions still
-- open stay counted, and the batch is then left partial by the caller.
balanceLabels ∷ Recorder q inst msgr phys dev cmd → IO (Either (ExceptionWithContext SomeException) ())
balanceLabels recorder =
  readIORef (recorderLabels recorder) >>= \case
    0 → pure (Right ())
    _ →
      tryWithContext @SomeException (recordLabel recorder CommandEndLabel) >>= \case
        Left failure → pure (Left failure)
        Right () → balanceLabels recorder

-- | Move the frame's image from one layout to another. The recorder tracks
-- the image's layout, so the one it leaves must be the one it is in; only the
-- transitions 'supportedTransition' names are supported, and none inside
-- rendering.
transitionImage ∷ Recorder q inst msgr phys dev cmd → ImageLayout → ImageLayout → IO (Either Refusal ())
transitionImage recorder from to = withImage recorder $ \image → command recorder $ \state →
  if not (supportedTransition from to)
    then Left (RefusedUnsupported ("the image transition " <> tshow from <> " to " <> tshow to))
    else
      -- The transfer-source layout is valid only for an image created as a
      -- transfer source, which only a generation built for a verification
      -- capture makes.
      if LayoutTransferSource `elem` [from, to] && not (frameImageCapturable image)
        then Left (RefusedUnsupported "a transfer-source transition of an image its generation did not make a transfer source")
        else
      if isJust (stateRendering state)
        then Left (RefusedIllegal "an image transition inside rendering")
        else
          if stateLayout state /= from
            then Left (RefusedIllegal ("the image is " <> tshow (stateLayout state) <> ", not " <> tshow from))
            else Right (state {stateLayout = to}, [], CommandImageBarrier (frameImageHandle image) from to)

-- | Move a managed buffer or image from one use to another within the batch
-- (GRS-3): from the use the batch left it in, or from undefined contents,
-- which only an image has. The ordering rules
-- ("Hetoimasia.GPU.Model.Access") decide the move. On the batch's first touch
-- the resource is at rest, and the recorder first records the entry barrier
-- out of its resting use — or, from undefined, that barrier is the move
-- itself, and initializes an image that awaits it.
--
-- Like every command it checks the owner's thread, the handle — this
-- session's, still managed, live, a buffer or an image — the recorder and its
-- state, and that rendering is not open; and it retains the exact generation
-- before its first barrier. An illegal move, one that does not start from the
-- use the batch left the resource in, or a first touch of an image another
-- unsubmitted batch initializes or that this one does not, is refused before
-- anything is retained or recorded.
transitionResource ∷ Ordered handle ⇒ Recorder q inst msgr phys dev cmd → handle → TransitionSource → ResourceUse → IO (Either Refusal ())
transitionResource recorder handle from to =
  owned recording $
    liveNative recording resource >>= \case
      Left refusal → pure (Left refusal)
      Right native → case orderedObject native of
        Nothing → pure (Left RefusedWrongKind)
        Just (kind, object, image) → orderedSequence recorder $ \state →
          if isJust (stateRendering state)
            then Left (RefusedIllegal "a resource transition inside rendering")
            else case Access.transition resource kind from to (stateAccess state) of
              Left refusal → Left (accessRefused refusal)
              Right (access, barriers) →
                Right
                  ( state {stateAccess = access, stateObjects = Map.insert resource (object, image) (stateObjects state)}
                  , [resource]
                  , [ (resource, if barrierDiscards barrier then DiscardsContents else KeepsContents)
                    | barrier ← barriers
                    , barrierRole barrier == EntryBarrier
                    ]
                  , map (resourceBarrier object image) barriers
                  )
  where
    recording = recorderRecording recorder
    resource = managedResource handle

-- | The native commands of the exit barriers the batch owes. Every touched
-- resource's native handle was noted when it was touched, so none is missing.
exitBarriers ∷ Map.Map ResourceId (Word64, Maybe (Word32, Word32)) → [Barrier ResourceId] → [NativeCommand]
exitBarriers objects barriers =
  [ resourceBarrier object image barrier
  | barrier ← barriers
  , Just (object, image) ← [Map.lookup (barrierResource barrier) objects]
  ]

-- | An ordering refusal, as the recording answers it.
accessRefused ∷ Access.AccessRefusal ResourceId → Refusal
accessRefused refusal = case refusal of
  Access.UseNotLegal {} → RefusedUnsupported (describeAccess refusal)
  Access.DiscardNotLegal {} → RefusedUnsupported (describeAccess refusal)
  _ → RefusedIllegal (describeAccess refusal)

describeAccess ∷ Access.AccessRefusal ResourceId → Text.Text
describeAccess = \case
  Access.UseNotLegal kind use → "the use " <> tshow use <> " of a " <> tshow kind
  Access.DiscardNotLegal kind → "discarding the contents of a " <> tshow kind
  Access.UseMismatch current asked → "a resource that is " <> tshow current <> ", not " <> tshow asked
  Access.KindMismatch recorded named → "a " <> tshow recorded <> " named as a " <> tshow named
  Access.AwayFromRest resource kind use → tshow resource <> ", a " <> tshow kind <> ", " <> tshow use <> " rather than at rest"

-- | What a dynamic-rendering pass renders into: the frame's image, or a
-- managed color target (GRS-5).
data Attachment = Attachment
  { attachmentExtent ∷ !SurfaceExtent
  , attachmentFormat ∷ !Word32
  , attachmentTarget ∷ !(Maybe ResourceId)
    -- ^ The color target, or 'Nothing' for the frame's image.
  }

-- | The frame's image as an attachment.
frameAttachment ∷ FrameImage → Attachment
frameAttachment frame = Attachment (frameImageExtent frame) (frameImageFormat frame) Nothing

-- | What a pipeline, a viewport or a scissor is checked against: the open
-- pass's attachment, or, outside rendering, the frame's image. A frame-less
-- batch outside rendering has neither.
checkedAgainst ∷ Recorder q inst msgr phys dev cmd → RecorderState → Either Refusal Attachment
checkedAgainst recorder state = case stateRendering state of
  Just attachment → Right attachment
  Nothing → maybe (Left (RefusedIllegal "dynamic state outside rendering in a frame-less batch, with no attachment to check it against")) (Right . frameAttachment) (recorderFrame recorder)

-- | How an attachment is named in a refusal.
attachmentName ∷ Attachment → Text.Text
attachmentName attachment = maybe "the frame's image" (const "the color target") (attachmentTarget attachment)

-- | Begin dynamic rendering into the frame's image view, cleared to the
-- color, across the whole extent. The image must be a color attachment. On a
-- labelled batch the pass's label opens first.
beginRendering ∷ Recorder q inst msgr phys dev cmd → ClearColor → IO (Either Refusal ())
beginRendering recorder clear = withImage recorder $ \frame → commandSequence recorder $ \state →
  if isJust (stateRendering state)
    then Left (RefusedIllegal "rendering has already begun")
    else
      if stateLayout state /= LayoutColorAttachment
        then Left (RefusedIllegal ("rendering into an image that is " <> tshow (stateLayout state)))
        else
          Right
            ( state {stateRendering = Just (frameAttachment frame)}
            , []
            , [CommandBeginLabel (passLabel (recorderBatch recorder) (frameImageGeneration frame)) | recorderLabelled recorder]
                <> [CommandBeginRendering (frameImageView frame) (frameImageExtent frame) clear]
            )

-- | How a pass into a managed color target begins (GRS-5). Either way the
-- pass clears the whole target to its color.
data PassStart
  = ClearTarget
    -- ^ The target is in its color-attachment use — at rest, on the batch's
    -- first touch — and keeps its layout. Its contents must be initialized.
  | ClearFromUndefined
    -- ^ Whatever the target held is discarded: the pass's barrier leaves the
    -- undefined layout, which initializes a target that awaits it.
  deriving (Eq, Show)

-- | Begin dynamic rendering into a managed color target (GRS-5), in a frame
-- batch or a frame-less one alike: its owned view is the one color
-- attachment, cleared to the color, and its extent is the render area.
--
-- Like every command it checks the owner's thread and the handle — this
-- session's, live, a 'ColorTarget' image — and that no pass is open; under
-- #335's rules the pass is a use of the target in its color-attachment use:
-- 'ClearTarget' requires it to be in that use already, and 'ClearFromUndefined'
-- is a transition from undefined into it. The batch's first touch records the
-- entry barrier, and a target that awaits initialization admits only a
-- 'ClearFromUndefined' pass, or none while another batch initializes it. Every
-- refusal makes no native call. Pipelines, viewports and scissors are checked
-- against the target while the pass is open.
beginRenderingInto ∷ Recorder q inst msgr phys dev cmd → Image → PassStart → ClearColor → IO (Either Refusal ())
beginRenderingInto recorder (Image resource) start clear =
  owned recording $
    liveNative recording resource >>= \case
      Left refusal → pure (Left refusal)
      Right (NativeImage description memory view)
        | imageKind description /= ColorTarget → pure (Left RefusedWrongKind)
        | otherwise → orderedSequence recorder $ \state →
            if isJust (stateRendering state)
              then Left (RefusedIllegal "rendering has already begun")
              else
                let kind = imageResourceKind ColorTarget
                    stepped = case start of
                      ClearTarget → Access.touch resource kind ColorAttachment KeepsContents (stateAccess state)
                      ClearFromUndefined → Access.transition resource kind FromUndefined ColorAttachment (stateAccess state)
                    extent = SurfaceExtent (imageWidth description) (imageHeight description)
                    object = memoryResource memory
                    image = Just (useAspect (imageKindUse ColorTarget), imageMipLevels description)
                 in case stepped of
                      Left refusal → Left (accessRefused refusal)
                      Right (access, barriers) →
                        Right
                          ( state
                              { stateAccess = access
                              , stateObjects = Map.insert resource (object, image) (stateObjects state)
                              , stateRendering = Just (Attachment extent (formatCode (imageFormat description)) (Just resource))
                              }
                          , [resource]
                          , [ (resource, if barrierDiscards barrier then DiscardsContents else KeepsContents)
                            | barrier ← barriers
                            , barrierRole barrier == EntryBarrier
                            ]
                          , map (resourceBarrier object image) barriers
                              <> [CommandBeginLabel (targetPassLabel (recorderBatch recorder) resource) | recorderLabelled recorder]
                              <> [CommandBeginRendering view extent clear]
                          )
      Right _ → pure (Left RefusedWrongKind)
  where
    recording = recorderRecording recorder

-- | End dynamic rendering. On a labelled batch the pass's label closes after it.
endRendering ∷ Recorder q inst msgr phys dev cmd → IO (Either Refusal ())
endRendering recorder = commandSequence recorder $ \state →
  if isNothing (stateRendering state)
    then Left (RefusedIllegal "ending rendering that has not begun")
    else Right (state {stateRendering = Nothing}, [], CommandEndRendering : [CommandEndLabel | recorderLabelled recorder])

-- | Bind a live pipeline built for the color format of the attachment it is
-- checked against: the open pass's, or, outside rendering, the frame's image.
-- The batch retains the pipeline's generation and, transitively, its layout's.
-- A draw checks the format again against the pass it is drawn in.
bindPipeline ∷ Recorder q inst msgr phys dev cmd → Pipeline → IO (Either Refusal ())
bindPipeline recorder (Pipeline pipeline) =
  liveNative (recorderRecording recorder) pipeline >>= \case
    Left refusal → pure (Left refusal)
    Right (NativePipeline handle layout format) → command recorder $ \state → do
      attachment ← checkedAgainst recorder state
      incompatible format attachment
      Right (state {statePipeline = Just (pipeline, format)}, [pipeline, layout], CommandBindPipeline handle)
    Right _ → pure (Left RefusedWrongKind)

-- | A pipeline built for another format than the attachment's.
incompatible ∷ Word32 → Attachment → Either Refusal ()
incompatible format attachment
  | format /= attachmentFormat attachment =
      Left (RefusedIncompatible ("a pipeline for format " <> tshow format <> " and an image of format " <> tshow (attachmentFormat attachment)))
  | otherwise = Right ()

-- | Set the viewport. It must be finite, have area, and lie within the
-- attachment it is checked against — which Vulkan guarantees is within every
-- device's viewport dimension and bounds limits, so no device limit needs
-- reading here. A draw checks it again against the pass it is drawn in.
setViewport ∷ Recorder q inst msgr phys dev cmd → Viewport → IO (Either Refusal ())
setViewport recorder viewport = command recorder $ \state → do
  attachment ← checkedAgainst recorder state
  viewportFits viewport attachment
  Right (state {stateViewport = Just viewport}, [], CommandSetViewport viewport)

viewportFits ∷ Viewport → Attachment → Either Refusal ()
viewportFits viewport attachment
  | any (\value → isNaN value || isInfinite value) values = Left (RefusedIllegal "a viewport that is not finite")
  | viewportWidth viewport <= 0 || viewportHeight viewport <= 0 = Left (RefusedIllegal "a viewport with no area")
  | viewportX viewport < 0
      || viewportY viewport < 0
      || viewportX viewport + viewportWidth viewport > fromIntegral (extentWidth extent)
      || viewportY viewport + viewportHeight viewport > fromIntegral (extentHeight extent) =
      Left (RefusedIllegal ("a viewport outside " <> attachmentName attachment))
  | otherwise = Right ()
  where
    extent = attachmentExtent attachment
    values = [viewportX viewport, viewportY viewport, viewportWidth viewport, viewportHeight viewport]

-- | Set the scissor, which must lie within the attachment it is checked
-- against, so its offset and extent never overflow. A draw checks it again
-- against the pass it is drawn in.
setScissor ∷ Recorder q inst msgr phys dev cmd → Rect → IO (Either Refusal ())
setScissor recorder rect = command recorder $ \state → do
  attachment ← checkedAgainst recorder state
  scissorFits rect attachment
  Right (state {stateScissor = Just rect}, [], CommandSetScissor rect)

scissorFits ∷ Rect → Attachment → Either Refusal ()
scissorFits rect attachment
  | rectX rect < 0 || rectY rect < 0 = Left (RefusedIllegal "a scissor with a negative offset")
  | reach (rectX rect) (rectWidth rect) > toInteger (extentWidth extent)
      || reach (rectY rect) (rectHeight rect) > toInteger (extentHeight extent) =
      Left (RefusedIllegal ("a scissor outside " <> attachmentName attachment))
  | otherwise = Right ()
  where
    extent = attachmentExtent attachment
    reach offset size = toInteger offset + toInteger size

-- | Draw triangles with the bound pipeline, inside rendering, once the
-- viewport and scissor have been set. The pipeline, the viewport and the
-- scissor are checked again against the open pass's attachment: whatever an
-- earlier pass, or the frame outside rendering, left bound must fit this one.
-- The batch retains the bound pipeline and its layout again, which it already
-- holds.
draw ∷ Recorder q inst msgr phys dev cmd → Word32 → Word32 → IO (Either Refusal ())
draw recorder vertices instances = do
  bound ← statePipeline <$> readIORef (recorderState recorder)
  layout ← case bound of
    Nothing → pure []
    Just (pipeline, _) → either (const []) dependency <$> liveNative (recorderRecording recorder) pipeline
  command recorder $ \state → case (statePipeline state, stateRendering state) of
    (Nothing, _) → Left (RefusedIllegal "a draw with no pipeline bound")
    (_, Nothing) → Left (RefusedIllegal "a draw outside rendering")
    (Just (pipeline, format), Just attachment) → case (stateViewport state, stateScissor state) of
      (Just viewport, Just rect)
        | vertices == 0 || instances == 0 → Left (RefusedIllegal "a draw of nothing")
        | vertices `mod` 3 /= 0 → Left (RefusedUnsupported "a draw that is not whole triangles")
        | otherwise → do
            incompatible format attachment
            viewportFits viewport attachment
            scissorFits rect attachment
            Right (state, pipeline : layout, CommandDraw vertices instances 0 0)
      _ → Left (RefusedIllegal "a draw before the viewport and scissor are set")
  where
    dependency = \case
      NativePipeline _ layout _ → [layout]
      _ → []

-- | The bytes one copy of an image of this extent needs: four per pixel,
-- tightly packed.
readbackBytesFor ∷ SurfaceExtent → Natural
readbackBytesFor extent = fromIntegral (extentWidth extent) * fromIntegral (extentHeight extent) * 4

-- | Copy the frame's image, which must be a transfer source, into the
-- readback buffer, and make the write visible to host reads. The buffer must
-- be large enough for the whole image; the batch retains it, and its bytes
-- are undefined until that batch's submission has completed.
copyToReadback ∷ Recorder q inst msgr phys dev cmd → Readback → IO (Either Refusal ())
copyToReadback recorder readback =
  withImage recorder $ \frame →
    copyInto recorder readback (frameImageExtent frame) (if frameImageCapturable frame then Nothing else Just (RefusedUnsupported "a copy from an image its generation did not make a transfer source")) $ \state buffer →
      if stateLayout state /= LayoutTransferSource
        then Left (RefusedIllegal ("copying an image that is " <> tshow (stateLayout state)))
        else Right (state, [], [], [CommandCopyImageToBuffer (frameImageHandle frame) (frameImageExtent frame) buffer])

-- | Copy a managed color target (GRS-5), whole, into the readback buffer, and
-- make the write visible to host reads, as 'copyToReadback' does the frame's
-- image. The target must be this session's, live, a 'ColorTarget', and in its
-- transfer-source use within the batch — an explicit transition out of its
-- color-attachment use (#335); the buffer must hold the whole target, four
-- bytes a pixel, tightly packed in its own format's byte order, with no
-- conversion. The batch retains both, and the buffer's bytes are exposed only
-- once that batch's submission has completed. A refusal makes no native call.
copyTargetToReadback ∷ Recorder q inst msgr phys dev cmd → Image → Readback → IO (Either Refusal ())
copyTargetToReadback recorder (Image resource) readback =
  owned recording $
    liveNative recording resource >>= \case
      Left refusal → pure (Left refusal)
      Right (NativeImage description memory _)
        | imageKind description /= ColorTarget → pure (Left RefusedWrongKind)
        | otherwise →
            let extent = SurfaceExtent (imageWidth description) (imageHeight description)
                kind = imageResourceKind ColorTarget
                object = memoryResource memory
                image = Just (useAspect (imageKindUse ColorTarget), imageMipLevels description)
             in copyInto recorder readback extent Nothing $ \state buffer →
                  case Access.touch resource kind TransferRead KeepsContents (stateAccess state) of
                    Left refusal → Left (accessRefused refusal)
                    Right (access, barriers) →
                      Right
                        ( state {stateAccess = access, stateObjects = Map.insert resource (object, image) (stateObjects state)}
                        , [resource]
                        , [ (resource, if barrierDiscards barrier then DiscardsContents else KeepsContents)
                          | barrier ← barriers
                          , barrierRole barrier == EntryBarrier
                          ]
                        , map (resourceBarrier object image) barriers <> [CommandCopyImageToBuffer object extent buffer]
                        )
      Right _ → pure (Left RefusedWrongKind)
  where
    recording = recorderRecording recorder

-- | Copy an image of this extent into the readback buffer: the buffer's own
-- checks, the decision that records the copy, and after it the barrier that
-- makes the write visible to host reads. One writer at a time: a buffer
-- another batch — or an earlier copy in this one — or a submission still
-- holds would be written again with no ordering between the two writes, and
-- its contents misattributed.
copyInto
  ∷ Recorder q inst msgr phys dev cmd
  → Readback
  → SurfaceExtent
  → Maybe Refusal
  → (RecorderState → Word64 → Either Refusal (RecorderState, [ResourceId], [(ResourceId, Contents)], [NativeCommand]))
  → IO (Either Refusal ())
copyInto recorder (Readback readback) extent refused decide =
  liveNative recording readback >>= \case
    Left refusal → pure (Left refusal)
    Right (NativeReadback allocation _) → do
      let needed = readbackBytesFor extent
          unfit
            | Just refusal ← refused = Just refusal
            | needed > allocationSize allocation = Just (RefusedOutOfBounds needed (allocationSize allocation))
            | otherwise = Nothing
      holds ← atomically $ do
        model ← stateRootsModel (recordingRoots recording) (\current → (current, current))
        pure (maybe [] viewOutstanding (holdView (ResourceSubject readback) model))
      let busy = any (`elem` [RecordedReferenceOwed, SubmittedUseOwed]) holds
      case unfit <|> (if busy then Just RefusedInUse else Nothing) of
        Just refusal → pure (Left refusal)
        Nothing → do
          copied ←
            orderedSequence recorder $ \state →
              if isJust (stateRendering state)
                then Left (RefusedIllegal "a copy inside rendering")
                else (\(next, references, entries, natives) → (next, readback : references, entries, natives)) <$> decide state (allocationBuffer allocation)
          case copied of
            Left refusal → pure (Left refusal)
            Right () → do
              atomically $ do
                editManaged recording readback $ \entry → case managedNative entry of
                  NativeReadback held _ → entry {managedNative = NativeReadback held (ContentsCopyRecorded (recorderBatch recorder))}
                  _ → entry
                editBatch recording (recorderBatch recorder) (\entry → entry {batchReadbacks = readback : batchReadbacks entry})
              command recorder $ \state →
                Right (state, [readback], CommandHostReadBarrier (allocationBuffer allocation) (fromIntegral needed))
    Right _ → pure (Left RefusedWrongKind)
  where
    recording = recorderRecording recorder
