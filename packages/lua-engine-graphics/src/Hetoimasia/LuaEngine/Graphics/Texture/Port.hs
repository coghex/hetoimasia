-- | The boundary between the texture backend (LFE-17) and the protected graphics owner it borrows.
--
-- The backend ("Hetoimasia.LuaEngine.Graphics.Texture.Backend") never names the owner, a Vulkan
-- handle or a session. It asks a 'Port' for everything native, and a 'Port' answers in the few facts
-- below. The production port ("Hetoimasia.LuaEngine.Graphics.Texture.Host") is built over a running
-- 'Hetoimasia.GPU.Vulkan.GLFW.VulkanHost'; this package's lifecycle tests build ports whose owner,
-- upload progression and completions are gated by the test, so every race of the backend is driven
-- without a device.
--
-- = The two threads a port knows
--
-- * /The owner's thread/. Everything that creates, registers or releases a native object runs there,
--   as a bounded 'Device' action submitted through 'portAct' or, for the release of a registered
--   texture, through 'portRelease'. An action never waits for another action or for a frame, and
--   what it constructs it hands to the backend's tracking /before it returns/ (see the backend's
--   invariants), so a result nobody read cannot strand a native object.
-- * /Any other thread/. Admission of an upload bytes-and-all ('portUpload'), reading a ticket
--   ('portTicket') and cancelling an upload ('portCancel') need no owner action. The backend's one pump
--   thread does them. The table is read by an owner action ('deviceTable'), never from outside, because the
--   owner refreshes it at the end of a step and only an action sees a step's refresh whole.
--
-- = Waiting without polling
--
-- A port never sleeps and never polls. A wait the backend needs is one of: a transaction that reads
-- the variable the fact lives in (a ticket, an action's outcome, the standing), 'portWatch' for
-- facts no variable carries (a completion recorded by the owner, a table descriptor written), or the
-- bounded queue itself: 'portAct' and 'portRelease' are transactions, and a refusal of 'PortFull'
-- read in one that then retries wakes when the queue changes.
module Hetoimasia.LuaEngine.Graphics.Texture.Port
  ( -- * The port
    Port (..)
  , Standing (..)
  , PortRefusal (..)
  , Submitted (..)
  , Outcome (..)

    -- * The owner's thread
  , Device (..)
  , Fault (..)
  , Registration (..)
  , Level (..)
  , TextureRef (..)
  , textureIdentity
  , textureRefOf

    -- * Uploads and the table
  , AdmissionRefusal (..)
  , TicketStanding (..)
  , CancelStanding (..)
  , TableReading (..)
  ) where

import Control.Concurrent.STM (STM)
import Control.Exception (SomeException)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.Set (Set)
import Data.Text (Text)
import Data.Word (Word32, Word64)

-- | Everything the backend asks of the graphics owner, over the native image type and the upload
-- ticket type of the owner it borrows.
data Port image ticket = Port
  { portStanding ∷ STM Standing
    -- ^ Whether the owner can take work: not yet, now, or never again.
  , portAct ∷ ∀ a. (Device image → IO a) → STM (Either PortRefusal (Submitted a))
    -- ^ Hand the owner a bounded action, run once on its thread, in the lane that is not held back by
    -- a scene's adoption. Admission is a transaction that never waits: a full queue is 'PortFull'.
  , portRelease ∷ ∀ a. (Device image → IO a) → STM (Either PortRefusal (Submitted a))
    -- ^ The same through the lane that runs only once the owner has adopted the scene revisions
    -- current when it was asked: the single hook through which a published scene's holds gate the
    -- table release of a registered texture. A full lane is 'PortFull'.
  , portUpload ∷ image → ByteString → IO (Either AdmissionRefusal ticket)
    -- ^ Admit the texels of a fresh image for upload from any thread. The bytes are copied into the
    -- owner's bounded staging before the call returns, so they are free once it has (the borrow
    -- ends there and nowhere else).
  , portTicket ∷ ticket → STM TicketStanding
  , portCancel ∷ ticket → STM CancelStanding
    -- ^ Cancel an upload that no copy was recorded for.
  , portWatch ∷ STM (STM ())
    -- ^ Take a reading of the owner's recorded progress, answering a transaction that does not
    -- return until the progress has changed since: a completion recorded, a resource disposed. The
    -- wake for a fact held by no variable of the backend's own.
  , portMarkReleased ∷ TextureRef → STM ()
    -- ^ The logical release, at once: a scene publication's check sees the texture released while
    -- the table release waits for the holds ('portRelease').
  }

-- | Whether the owner can take work.
data Standing
  = -- | Its startup has not made the device yet.
    Starting
  | Running
  | -- | The owner's exit began or its session failed: nothing more will run, and what it made is
    -- retired by its own teardown, which the backend cannot prove from here. The reason is bounded
    -- text.
    Ended !Text
  deriving (Eq, Show)

-- | Why the owner took no action. A refused action never ran.
data PortRefusal
  = -- | The bounded queue is full: pressure, retried when the queue changes.
    PortFull
  | -- | Not yet running.
    PortNotStarted
  | -- | Ended, with the reason.
    PortEnded !Text
  deriving (Eq, Show)

-- | An action the owner accepted: its outcome, once it has one.
newtype Submitted a = Submitted
  { submittedOutcome ∷ STM (Maybe (Outcome a))
    -- ^ 'Nothing' while the action is queued or running. Never waits.
  }

-- | What an accepted action came to.
data Outcome a
  = Returned a
  | -- | It raised: an engine failure.
    Raised SomeException
  | -- | It never ran: the owner ended first.
    NotRun !PortRefusal

-- | The operations an owner-thread action may perform, over the owner's native image type.
data Device image = Device
  { deviceAllocate ∷ Word32 → Word32 → IO (Either Fault image)
    -- ^ A texture image for one RGBA8 sRGB level of this extent. Nothing is written.
  , deviceDiscard ∷ image → IO (Either Fault ())
    -- ^ Release an image that was never registered.
  , deviceRegister ∷ image → Level → IO (Either Fault Registration)
    -- ^ Register an image whose upload completed with the table, with the level's alpha
    -- classification as its cutout mark, after checking the table is bound ('FaultNotReady'
    -- otherwise) and that the registration resolves to the image's own slot.
  , deviceRelease ∷ Registration → IO (Either Fault ())
    -- ^ The table's release of a registered texture, on the owner's thread.
  , deviceTable ∷ IO TableReading
    -- ^ The table as it stands. An action reads it at the start of one of the owner's steps, after the previous
    -- step's refresh, which is what makes a reading taken after a wake a reading of what the wake announced.
  }

-- | The facts about the uploaded level a registration needs.
data Level = Level
  { levelWidth ∷ !Word32
  , levelHeight ∷ !Word32
  , levelBinaryAlpha ∷ !Bool
    -- ^ Every texel's alpha is 0 or 255, read from the decoded level while it was borrowed.
  }
  deriving (Eq, Show)

-- | A native refusal, in the three kinds the backend treats differently.
data Fault
  = -- | A bounded budget has no room now (a native pressure answer): retained work, retried when
    -- the owner's recorded progress changes.
    FaultPressure
  | -- | The table has not bound yet: retried when it has.
    FaultNotReady
  | -- | Everything else: a device, allocator, misuse or session failure. Fatal.
    FaultFatal !Text
  deriving (Eq, Show)

-- | A registered texture: the handle a scene names it by, and the table slot it resolves to.
data Registration = Registration
  { registrationRef ∷ !TextureRef
  , registrationSlot ∷ !Word32
  }
  deriving (Eq, Show)

-- | The table handle's lookup index and its generation, which is never zero.
data TextureRef = TextureRef
  { refIndex ∷ !Word32
  , refGeneration ∷ !Word32
  }
  deriving (Eq, Ord, Show)

-- | The registration identity the pipeline carries: the generation above the index, so a stale
-- index never names a later texture.
textureIdentity ∷ TextureRef → Word64
textureIdentity (TextureRef index generation) = (fromIntegral generation `shiftL` 32) .|. fromIntegral index

-- | The handle an identity names.
textureRefOf ∷ Word64 → TextureRef
textureRefOf identity = TextureRef (fromIntegral (identity .&. 0xFFFFFFFF)) (fromIntegral (identity `shiftR` 32))

-- | Why an upload was not admitted. Nothing was reserved or copied.
data AdmissionRefusal
  = -- | The queue or the staging is full for now: retained work, retried when progress changes.
    AdmissionPressure
  | -- | The owner admits nothing more.
    AdmissionEnded
  | -- | Everything else: oversized for the whole staging, misuse, a failed session. Fatal.
    AdmissionFault !Text
  deriving (Eq, Show)

-- | Where an upload stands, from any thread.
data TicketStanding
  = TicketQueued
  | TicketUploading
  | TicketComplete
  | -- | Settled without initializing its target.
    TicketCancelled
  | TicketLost
  deriving (Eq, Show)

-- | What a cancellation of an upload came to.
data CancelStanding
  = -- | Settled as cancelled: no copy was recorded, the target is untouched.
    CancelledNow
  | -- | Its first copies are recorded: it completes.
    CancelTooLate
  | -- | It had already settled.
    CancelAlreadySettled
  deriving (Eq, Show)

-- | The texture table, as far as the backend needs it.
data TableReading = TableReading
  { tablePlaceholderWritten ∷ !Bool
    -- ^ The bootstrap is complete: slot 0's placeholder is uploaded and its descriptor written.
  , tableRetiring ∷ !(Set Word32)
    -- ^ The slots released and still mapped by a version a batch holds.
  }
  deriving (Eq, Show)
