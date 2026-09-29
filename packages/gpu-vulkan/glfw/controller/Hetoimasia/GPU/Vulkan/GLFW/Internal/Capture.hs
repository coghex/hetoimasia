-- | Verification capture through the host (VK-19): a verifier's request for
-- the pixels of one frame of a named target, and what that request became.
--
-- Capture is a test-only capability. A host builds its generations for it only
-- when its composition asks ('CaptureOn'), which only this package's private
-- sublibrary can do; every other host answers every request 'CaptureDisabled'
-- and builds its swapchains exactly as it would without this module.
--
-- = A request's way through
--
-- 1. A request is admitted from any thread ('requestCapture') for an
--    attachment that has no request outstanding and whose target has not begun
--    retiring, while fewer than 'capturesRetained' requests are outstanding or
--    settled and untaken, and answered with a ticket. It wakes the owner.
-- 2. The owner's next step asks the attachment's target for a frame, as
--    render demand would ('takeRequested').
-- 3. The next frame the owner acquires for that target is the one the request
--    is for, whatever becomes of it: the request is never moved to a later
--    frame. If the frame's generation is not a transfer source, or no readback
--    buffer can be made for it, the request is settled without bytes and the
--    frame is rendered as usual. Otherwise the host records, after the
--    consumer's commands and in the same batch, the copy of the rendered image
--    into its readback buffer, and the frame is submitted and presented as
--    usual. A frame skipped, abandoned or closed unpresented settles the
--    request without bytes, naming why.
-- 4. Once the batch's completion evidence exposes the bytes, the owner copies
--    them out and settles the request with them and the frame's identities.
--    Retiring the target, or the session's end, settles a request still
--    outstanding without bytes.
--
-- A settled request is read once ('takeCapture'), and kept until it is: every
-- admitted ticket has an outcome to read. Admission is what is bounded — a
-- request beyond 'capturesRetained' outstanding or untaken ones is refused
-- ('CaptureBacklogFull') — so nothing admitted is ever dropped. A target's
-- retirement closes its admission ('closeCaptures') before it settles the
-- target's requests, so none is admitted after that settlement.
--
-- = State
--
-- +---------------------+-----------+--------------------------------------+-----------+------------------------------+------------------------------+
-- | State               | Owner     | Readers and writers                  | Thread    | Lifetime                     | Reset or disposal            |
-- +=====================+===========+======================================+===========+==============================+==============================+
-- | Outstanding         | This      | Admitted by 'requestCapture' on any  | Any, then | Admission until settled      | Moved to the settled map by  |
-- | requests, one per   | module    | thread; advanced and settled by the  | the owner |                              | the owner, or by the host's  |
-- | attachment          |           | owner's rendering                    |           |                              | exit sweep                   |
-- +---------------------+-----------+--------------------------------------+-----------+------------------------------+------------------------------+
-- | Settled outcomes    | This      | Written when a request settles; taken| Any       | Settlement until taken       | Taken once, and only then    |
-- |                     | module    | by 'takeCapture'                     |           |                              | removed                      |
-- +---------------------+-----------+--------------------------------------+-----------+------------------------------+------------------------------+
-- | Closed attachments  | This      | Closed by the owner's retirement of  | Owner,    | A target's retirement until  | Forgotten with the target    |
-- |                     | module    | a target; read by 'requestCapture'   | read from | the owner forgets the target | ('forgetClosed')             |
-- |                     |           |                                      | any       |                              |                              |
-- +---------------------+-----------+--------------------------------------+-----------+------------------------------+------------------------------+
--
-- A readback buffer a request holds is the owner's rendering's
-- ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Rendering"): it is made, released and
-- destroyed there, under the recording's rules, and this module only names it.
module Hetoimasia.GPU.Vulkan.GLFW.Internal.Capture
  ( -- * Whether a host captures
    CaptureMode (..)

    -- * Requests and outcomes
  , CaptureTicket
  , CaptureRefusal (..)
  , CaptureOutcome (..)
  , CapturedFrame (..)
  , Withheld (..)
  , capturesRetained

    -- * The captures
  , Captures
  , newCaptures
  , capturesMode
  , requestCapture
  , takeCapture
  , capturesRequested

    -- * The owner's side
  , Stage (..)
  , Presented (..)
  , takeRequested
  , outstandingFor
  , outstanding
  , associateCapture
  , presentCapture
  , settleCapture
  , withholdAll
  , closeCaptures
  , forgetClosed
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', newTVarIO, readTVar, stateTVar, writeTVar)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word32)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model.Identity (FrameSlotId, GenerationId, ImageId, PresentationId, TargetId)
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent)
import Hetoimasia.GPU.Vulkan.Native.Recording (Readback, Refusal)
import Hetoimasia.GPU.Vulkan.Native.Roots (TerminalCause)
import Hetoimasia.Runtime.GLFW (AttachmentId)

-- | Whether a host's generations are built for verification capture.
data CaptureMode
  = CaptureOff
    -- ^ Every host's default: swapchains are clipped and no transfer-source
    -- usage is added, and every request is refused 'CaptureDisabled'.
  | CaptureOn
    -- ^ Generations are unclipped and made transfer sources wherever their
    -- surface offers that usage.
  deriving (Eq, Show)

-- | One admitted request, until it is taken.
newtype CaptureTicket = CaptureTicket Natural
  deriving (Eq, Ord, Show)

-- | Why a request was not admitted.
data CaptureRefusal
  = CaptureDisabled
    -- ^ The host was not built for capture.
  | CaptureNoTarget
    -- ^ The owner holds no target for the attachment.
  | CaptureOutstanding !CaptureTicket
    -- ^ The attachment already has this request outstanding.
  | CaptureTargetRetiring
    -- ^ The attachment's target has begun retiring: no request is admitted
    -- for it after its retirement settled those it had.
  | CaptureBacklogFull !Int
    -- ^ This many requests are outstanding or settled and not yet taken, the
    -- most the host keeps: take an outcome first. It is backpressure, and
    -- drops nothing already admitted.
  | CaptureSessionFailed !TerminalCause
    -- ^ The graphics session has failed, with this primary failure.
  deriving (Eq, Show)

-- | One frame's pixels, and the identities of the frame they were copied from.
data CapturedFrame = CapturedFrame
  { capturedAttachment ∷ !AttachmentId
  , capturedTarget ∷ !TargetId
  , capturedGeneration ∷ !GenerationId
  , capturedFrame ∷ !FrameSlotId
  , capturedImage ∷ !ImageId
  , capturedPresentation ∷ !PresentationId
  , capturedExtent ∷ !SurfaceExtent
  , capturedFormat ∷ !Word32
    -- ^ The image's Vulkan format; the bytes are its texels, four a pixel,
    -- row by row with no padding.
  , capturedSceneRevision ∷ !Natural
  , capturedBytes ∷ !ByteString
    -- ^ A copy of its own: nothing the host later does to its readback memory
    -- changes it.
  }
  deriving (Eq, Show)

-- | Why a request was settled without bytes.
data Withheld
  = WithheldUnsupported !GenerationId
    -- ^ The frame's generation is not a transfer source: its surface offers
    -- no transfer-source usage.
  | WithheldNoReadback !Refusal
    -- ^ No readback buffer could be made for the frame.
  | WithheldFrameAbandoned !FrameSlotId !Text
    -- ^ The frame was skipped, abandoned or closed unpresented.
  | WithheldReadRefused !Refusal
    -- ^ The bytes could not be read.
  | WithheldTargetRetired
    -- ^ The target retired before the request was fulfilled.
  | WithheldSessionEnded !(Maybe TerminalCause)
    -- ^ The session ended first; with its primary failure, if it failed.
  deriving (Eq, Show)

-- | What a request became.
data CaptureOutcome
  = CaptureDelivered !CapturedFrame
  | CaptureWithheld !AttachmentId !Withheld
  deriving (Eq, Show)

-- | How many requests may be outstanding or settled and untaken at once.
capturesRetained ∷ Int
capturesRetained = 64

-- | A captured frame waiting for its batch's completion evidence.
data Presented = Presented
  { presentedReadback ∷ !Readback
  , presentedBytes ∷ !Natural
  , presentedFrame ∷ !(ByteString → CapturedFrame)
    -- ^ The frame's identities, waiting for its bytes.
  }

-- | Where an outstanding request is.
data Stage
  = StageRequested
    -- ^ Admitted; the owner has not yet asked a frame for it.
  | StageAsked
    -- ^ The owner has asked the target for a frame; the next one it acquires
    -- is this request's.
  | StageInFrame !FrameSlotId
    -- ^ The owner is recording, submitting and presenting the request's frame.
  | StagePresented !Presented
    -- ^ The frame was presented; its bytes wait for its batch's completion
    -- evidence.

data Outstanding = Outstanding !CaptureTicket !Stage

data Captures = Captures
  { capturesMode ∷ !CaptureMode
  , capturesNext ∷ !(TVar Natural)
  , capturesOutstanding ∷ !(TVar (Map AttachmentId Outstanding))
  , capturesSettled ∷ !(TVar (Map CaptureTicket CaptureOutcome))
  , capturesClosed ∷ !(TVar (Set AttachmentId))
  }

newCaptures ∷ CaptureMode → IO Captures
newCaptures mode = Captures mode <$> newTVarIO 0 <*> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newTVarIO Set.empty

-- | Admit a request for the next frame of this attachment's target, given
-- whether the owner holds a target for it and the session's primary failure,
-- if it has failed.
requestCapture ∷ Captures → AttachmentId → Bool → Maybe TerminalCause → STM (Either CaptureRefusal CaptureTicket)
requestCapture captures attachment targeted failed = do
  outstanding' ← readTVar (capturesOutstanding captures)
  settled ← readTVar (capturesSettled captures)
  closed ← Set.member attachment <$> readTVar (capturesClosed captures)
  let held = Map.lookup attachment outstanding'
      backlog = Map.size outstanding' + Map.size settled
  case (capturesMode captures, failed, held) of
    (CaptureOff, _, _) → pure (Left CaptureDisabled)
    (_, Just cause, _) → pure (Left (CaptureSessionFailed cause))
    _ | not targeted → pure (Left CaptureNoTarget)
    _ | closed → pure (Left CaptureTargetRetiring)
    (_, _, Just (Outstanding ticket _)) → pure (Left (CaptureOutstanding ticket))
    _
      | backlog >= capturesRetained → pure (Left (CaptureBacklogFull backlog))
      | otherwise → do
          ticket ← CaptureTicket <$> stateTVar (capturesNext captures) (\next → (next, next + 1))
          modifyTVar' (capturesOutstanding captures) (Map.insert attachment (Outstanding ticket StageRequested))
          pure (Right ticket)

-- | What a request became, once, when it has settled.
takeCapture ∷ Captures → CaptureTicket → STM (Maybe CaptureOutcome)
takeCapture captures ticket = stateTVar (capturesSettled captures) (\held → (Map.lookup ticket held, Map.delete ticket held))

-- | Whether a request is waiting for the owner to ask its frame: what wakes an
-- idle owner, and stays false once its round has asked.
capturesRequested ∷ Captures → STM Bool
capturesRequested captures = any requested . Map.elems <$> readTVar (capturesOutstanding captures)
  where
    requested (Outstanding _ stage) = case stage of
      StageRequested → True
      _ → False

-- | The attachments whose requests wait for a frame to be asked, now marked
-- asked.
takeRequested ∷ Captures → STM [AttachmentId]
takeRequested captures = do
  held ← readTVar (capturesOutstanding captures)
  let requested = [attachment | (attachment, Outstanding _ StageRequested) ← Map.toList held]
  writeTVar (capturesOutstanding captures) (foldr (Map.adjust (\(Outstanding ticket _) → Outstanding ticket StageAsked)) held requested)
  pure requested

-- | The request outstanding for this attachment, if one is.
outstandingFor ∷ Captures → AttachmentId → STM (Maybe Stage)
outstandingFor captures attachment = fmap (\(Outstanding _ stage) → stage) . Map.lookup attachment <$> readTVar (capturesOutstanding captures)

-- | Every outstanding request, by attachment.
outstanding ∷ Captures → STM [(AttachmentId, Stage)]
outstanding captures = map (\(attachment, Outstanding _ stage) → (attachment, stage)) . Map.toList <$> readTVar (capturesOutstanding captures)

-- | Record that the attachment's request is this frame's.
associateCapture ∷ Captures → AttachmentId → FrameSlotId → STM ()
associateCapture captures attachment frame =
  modifyTVar' (capturesOutstanding captures) (Map.adjust (\(Outstanding ticket _) → Outstanding ticket (StageInFrame frame)) attachment)

-- | Record that the attachment's request was copied from a presented frame.
presentCapture ∷ Captures → AttachmentId → Presented → STM ()
presentCapture captures attachment presented =
  modifyTVar' (capturesOutstanding captures) (Map.adjust (\(Outstanding ticket _) → Outstanding ticket (StagePresented presented)) attachment)

-- | Settle the attachment's outstanding request, if it has one.
settleCapture ∷ Captures → AttachmentId → CaptureOutcome → STM ()
settleCapture captures attachment outcome =
  Map.lookup attachment <$> readTVar (capturesOutstanding captures) >>= \case
    Nothing → pure ()
    Just (Outstanding ticket _) → do
      modifyTVar' (capturesOutstanding captures) (Map.delete attachment)
      -- Admission bounded outstanding and settled requests together, so
      -- this never grows past 'capturesRetained' and drops nothing.
      modifyTVar' (capturesSettled captures) (Map.insert ticket outcome)

-- | Settle every outstanding request without bytes, for this reason.
withholdAll ∷ Captures → Withheld → STM ()
withholdAll captures reason = do
  attachments ← Map.keys <$> readTVar (capturesOutstanding captures)
  mapM_ (\attachment → settleCapture captures attachment (CaptureWithheld attachment reason)) attachments

-- | Admit no more requests for this attachment: its target has begun
-- retiring. Those already admitted are the retirement's to settle.
closeCaptures ∷ Captures → AttachmentId → STM ()
closeCaptures captures attachment = modifyTVar' (capturesClosed captures) (Set.insert attachment)

-- | Forget a closed attachment, once the owner holds no target for it and
-- every request is refused 'CaptureNoTarget' instead.
forgetClosed ∷ Captures → AttachmentId → STM ()
forgetClosed captures attachment = modifyTVar' (capturesClosed captures) (Set.delete attachment)
