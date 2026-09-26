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
-- open, the image layout and bindings it tracks, and its count of open label
-- regions — for one consumer action on the graphics owner's thread. It
-- inserts batch records into the recording's state
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State") and advances them
-- while recording, and marks a readback buffer as copied into; ending a batch
-- afterwards is the batch lifecycle's
-- ("Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Batches").
module Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Recorder
  ( Recorder
  , recorderBatch
  , recordFrame
  , transitionImage
  , beginRendering
  , endRendering
  , bindPipeline
  , setViewport
  , setScissor
  , draw
  , copyToReadback
  , readbackBytesFor
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, displayException, mask, mask_, rethrowIO, tryWithContext)
import Control.Applicative ((<|>))
import Control.Monad (when)
import Data.Bits ((.&.))
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model
  ( FramePhase (..)
  , FrameView (..)
  , HoldKind (..)
  , HoldView (..)
  , Outcome (..)
  , extendBatch
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
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Batches (retireCompleted)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.Layer
  ( ClearColor
  , ImageLayout (..)
  , NativeCommand (..)
  , ReadbackAllocation (..)
  , RecordingOps (..)
  , Rect (..)
  , Viewport (..)
  , nativeName
  , supportedTransition
  )
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State
  ( BatchRecord (..)
  , BatchStanding (..)
  , ManagedRecord (..)
  , ManagedStanding (..)
  , NativeResource (..)
  , Pipeline (..)
  , Readback (..)
  , ReadbackContents (..)
  , Recording (..)
  , Refusal (..)
  , editBatch
  , editManaged
  , isAsynchronous
  , liveNative
  , modelAnswer
  , owned
  , tshow
  )
import Hetoimasia.GPU.Vulkan.Native.Naming (batchLabel, passLabel)
import Hetoimasia.GPU.Vulkan.Native.Presentation (GenerationPlan (..), SurfaceExtent (..), SurfaceFormat (..), imageUsageTransferSource)
import Hetoimasia.GPU.Vulkan.Native.Roots (readRootsInstrumentation, rootsCall, stateRootsModel)

data RecorderState = RecorderState
  { stateLayout ∷ !ImageLayout
  , stateRendering ∷ !Bool
  , statePipeline ∷ !(Maybe ResourceId)
  , stateViewport ∷ !Bool
  , stateScissor ∷ !Bool
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
  , recorderFrame ∷ !FrameImage
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
  owned recording $
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
                modifyTVar' (recordingBatches recording) (Map.insert batch (BatchRecord frame storage BatchRecording 0 []))
              pure answer
            case admitted of
              Left refusal → pure (Left refusal)
              Right batch → do
                opened ← newIORef True
                state ← newIORef (RecorderState LayoutUndefined False Nothing False False)
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
                        then tryWithContext @SomeException (recordLabel recorder (CommandBeginLabel (batchLabel batch (frameImageGeneration image))))
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
                        rendering ← stateRendering <$> readIORef state
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
                          else
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
                  storage ← maybe (Left RefusedNoStorage) Right (Map.lookup (frameTarget frame, frameSlotNumber frame) storages)
                  commands ← case Map.lookup storage managed of
                    Just (ManagedRecord (NativeStorage _ _ _ commands) ManagedLive) → Right commands
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
commandSequence recorder decide =
  owned recording $
    readIORef (recorderOpen recorder) >>= \case
      False → pure (Left RefusedRecorderClosed)
      True → do
        state ← readIORef (recorderState recorder)
        case decide state of
          Left refusal → pure (Left refusal)
          Right (next, references, natives) → mask_ $ do
            retained ←
              if null references
                then pure (Right ())
                else atomically (modelAnswer roots (fmap (\model → (model, ())) . extendBatch batch (unique references)))
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
transitionImage recorder from to = command recorder $ \state →
  if not (supportedTransition from to)
    then Left (RefusedUnsupported ("the image transition " <> tshow from <> " to " <> tshow to))
    else
      -- The transfer-source layout is valid only for an image created as a
      -- transfer source, which only a generation built for a verification
      -- capture makes.
      if LayoutTransferSource `elem` [from, to] && not (frameImageCapturable (recorderFrame recorder))
        then Left (RefusedUnsupported "a transfer-source transition of an image its generation did not make a transfer source")
        else
      if stateRendering state
        then Left (RefusedIllegal "an image transition inside rendering")
        else
          if stateLayout state /= from
            then Left (RefusedIllegal ("the image is " <> tshow (stateLayout state) <> ", not " <> tshow from))
            else Right (state {stateLayout = to}, [], CommandImageBarrier (frameImageHandle (recorderFrame recorder)) from to)

-- | Begin dynamic rendering into the frame's image view, cleared to the
-- color, across the whole extent. The image must be a color attachment. On a
-- labelled batch the pass's label opens first.
beginRendering ∷ Recorder q inst msgr phys dev cmd → ClearColor → IO (Either Refusal ())
beginRendering recorder clear = commandSequence recorder $ \state →
  if stateRendering state
    then Left (RefusedIllegal "rendering has already begun")
    else
      if stateLayout state /= LayoutColorAttachment
        then Left (RefusedIllegal ("rendering into an image that is " <> tshow (stateLayout state)))
        else
          let frame = recorderFrame recorder
           in Right
                ( state {stateRendering = True}
                , []
                , [CommandBeginLabel (passLabel (recorderBatch recorder) (frameImageGeneration frame)) | recorderLabelled recorder]
                    <> [CommandBeginRendering (frameImageView frame) (frameImageExtent frame) clear]
                )

-- | End dynamic rendering. On a labelled batch the pass's label closes after it.
endRendering ∷ Recorder q inst msgr phys dev cmd → IO (Either Refusal ())
endRendering recorder = commandSequence recorder $ \state →
  if not (stateRendering state)
    then Left (RefusedIllegal "ending rendering that has not begun")
    else Right (state {stateRendering = False}, [], CommandEndRendering : [CommandEndLabel | recorderLabelled recorder])

-- | Bind a live pipeline built for the frame's color format. The batch
-- retains the pipeline's generation and, transitively, its layout's.
bindPipeline ∷ Recorder q inst msgr phys dev cmd → Pipeline → IO (Either Refusal ())
bindPipeline recorder (Pipeline pipeline) =
  liveNative (recorderRecording recorder) pipeline >>= \case
    Left refusal → pure (Left refusal)
    Right (NativePipeline handle layout format)
      | format /= frameImageFormat (recorderFrame recorder) →
          pure (Left (RefusedIncompatible ("a pipeline for format " <> tshow format <> " and an image of format " <> tshow (frameImageFormat (recorderFrame recorder)))))
      | otherwise → command recorder $ \state →
          Right (state {statePipeline = Just pipeline}, [pipeline, layout], CommandBindPipeline handle)
    Right _ → pure (Left RefusedWrongKind)

-- | Set the viewport. It must be finite, have area, and lie within the
-- frame's image — which Vulkan guarantees is within every device's viewport
-- dimension and bounds limits, so no device limit needs reading here.
setViewport ∷ Recorder q inst msgr phys dev cmd → Viewport → IO (Either Refusal ())
setViewport recorder viewport = command recorder $ \state →
  let extent = frameImageExtent (recorderFrame recorder)
      values = [viewportX viewport, viewportY viewport, viewportWidth viewport, viewportHeight viewport]
   in if any (\value → isNaN value || isInfinite value) values
        then Left (RefusedIllegal "a viewport that is not finite")
        else
          if viewportWidth viewport <= 0 || viewportHeight viewport <= 0
            then Left (RefusedIllegal "a viewport with no area")
            else
              if viewportX viewport < 0
                || viewportY viewport < 0
                || viewportX viewport + viewportWidth viewport > fromIntegral (extentWidth extent)
                || viewportY viewport + viewportHeight viewport > fromIntegral (extentHeight extent)
                then Left (RefusedIllegal "a viewport outside the frame's image")
                else Right (state {stateViewport = True}, [], CommandSetViewport viewport)

-- | Set the scissor, which must lie within the frame's image, so its offset
-- and extent never overflow.
setScissor ∷ Recorder q inst msgr phys dev cmd → Rect → IO (Either Refusal ())
setScissor recorder rect = command recorder $ \state →
  let extent = frameImageExtent (recorderFrame recorder)
      reach offset size = toInteger offset + toInteger size
   in if rectX rect < 0 || rectY rect < 0
        then Left (RefusedIllegal "a scissor with a negative offset")
        else
          if reach (rectX rect) (rectWidth rect) > toInteger (extentWidth extent)
            || reach (rectY rect) (rectHeight rect) > toInteger (extentHeight extent)
            then Left (RefusedIllegal "a scissor outside the frame's image")
            else Right (state {stateScissor = True}, [], CommandSetScissor rect)

-- | Draw triangles with the bound pipeline, inside rendering, once the
-- viewport and scissor have been set. The batch retains the bound pipeline
-- and its layout again, which it already holds.
draw ∷ Recorder q inst msgr phys dev cmd → Word32 → Word32 → IO (Either Refusal ())
draw recorder vertices instances = do
  bound ← statePipeline <$> readIORef (recorderState recorder)
  layout ← case bound of
    Nothing → pure []
    Just pipeline → either (const []) dependency <$> liveNative (recorderRecording recorder) pipeline
  command recorder $ \state → case statePipeline state of
    Nothing → Left (RefusedIllegal "a draw with no pipeline bound")
    Just pipeline
      | not (stateRendering state) → Left (RefusedIllegal "a draw outside rendering")
      | not (stateViewport state && stateScissor state) → Left (RefusedIllegal "a draw before the viewport and scissor are set")
      | vertices == 0 || instances == 0 → Left (RefusedIllegal "a draw of nothing")
      | vertices `mod` 3 /= 0 → Left (RefusedUnsupported "a draw that is not whole triangles")
      | otherwise → Right (state, pipeline : layout, CommandDraw vertices instances 0 0)
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
copyToReadback recorder (Readback readback) =
  liveNative recording readback >>= \case
    Left refusal → pure (Left refusal)
    Right (NativeReadback allocation _) → do
      let frame = recorderFrame recorder
          needed = readbackBytesFor (frameImageExtent frame)
          unfit
            | not (frameImageCapturable frame) = Just (RefusedUnsupported "a copy from an image its generation did not make a transfer source")
            | needed > allocationSize allocation = Just (RefusedOutOfBounds needed (allocationSize allocation))
            | otherwise = Nothing
      -- One writer at a time: a buffer another batch — or an earlier copy in
      -- this one — or a submission still holds would be written again with no
      -- ordering between the two writes, and its contents misattributed.
      holds ← atomically $ do
        model ← stateRootsModel (recordingRoots recording) (\current → (current, current))
        pure (maybe [] viewOutstanding (holdView (ResourceSubject readback) model))
      let busy = any (`elem` [RecordedReferenceOwed, SubmittedUseOwed]) holds
      case unfit <|> (if busy then Just RefusedInUse else Nothing) of
        Just refused → pure (Left refused)
        Nothing → do
          copied ←
            command recorder $ \state →
              if stateRendering state
                then Left (RefusedIllegal "a copy inside rendering")
                else
                  if stateLayout state /= LayoutTransferSource
                    then Left (RefusedIllegal ("copying an image that is " <> tshow (stateLayout state)))
                    else Right (state, [readback], CommandCopyImageToBuffer (frameImageHandle frame) (frameImageExtent frame) (allocationBuffer allocation))
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
