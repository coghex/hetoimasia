-- | The typed identities the GPU retention model issues, and the typed misuse
-- it answers when one of them is stale, foreign, duplicated or already
-- consumed.
--
-- Every identity here is opaque to clients: this module is not exposed, and
-- the public faces re-export the types without their constructors. Only
-- "Hetoimasia.GPU.Model.Internal.State" issues one, and it issues each from a
-- counter that is never reissued, so a value a client still holds names
-- exactly the object it named when it was made — or names one this model has
-- forgotten, which is what makes staleness decidable without remembering every
-- identity ever issued.
--
-- The session identity is the one premise the model does not establish: the
-- owning boundary supplies a 'Data.Unique.Unique' created for this session
-- alone. Every other identity carries it, so an identity from another model is
-- foreign rather than merely unknown, and the two are different answers.
module Hetoimasia.GPU.Model.Internal.Identity
  ( -- * The session premise
    SessionIdentity (..)
  , sessionIdentity

    -- * Issued identities
  , DeviceId (..)
  , deviceSession
  , TargetId (..)
  , targetSession
  , targetNumber
  , targetIncarnation
  , GenerationId (..)
  , generationTarget
  , generationNumber
  , ImageId (..)
  , imageGeneration
  , imageIndex
  , FrameSlotId (..)
  , frameTarget
  , frameSlotNumber
  , frameUse
  , BatchId (..)
  , batchTarget
  , batchNumber
  , SubmissionId (..)
  , submissionSession
  , submissionNumber
  , PresentationId (..)
  , presentationTarget
  , presentationNumber
  , ResourceId (..)
  , resourceSession
  , resourceNumber
  , resourceGeneration
  , AllocationId (..)
  , allocationSession
  , allocationNumber

    -- * Classification
  , TargetClass (..)

    -- * Subjects that carry holds
  , HoldSubject (..)

    -- * Misuse
  , IdentityKind (..)
  , Misuse (..)
  ) where

import Data.Unique (Unique)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- The session premise

-- | One graphics session, named by a 'Unique' the owning boundary created for
-- it alone. The model never makes one.
newtype SessionIdentity = SessionIdentity Unique
  deriving (Eq, Ord)

-- | 'Show' is diagnostic and deliberately carries nothing: a session identity
-- has no printable content a log or a test may depend on.
instance Show SessionIdentity where
  show _ = "SessionIdentity"

-- | Name a session by a 'Unique' created for it alone.
sessionIdentity ∷ Unique → SessionIdentity
sessionIdentity = SessionIdentity

-- ---------------------------------------------------------------------------
-- Issued identities

-- | The one logical device a session owns.
data DeviceId = DeviceId !SessionIdentity !Natural
  deriving (Eq, Ord)

instance Show DeviceId where
  showsPrec precedence (DeviceId _ number) =
    showParen (precedence > 10) (showString "DeviceId " . showsPrec 11 number)

deviceSession ∷ DeviceId → SessionIdentity
deviceSession (DeviceId session _) = session

-- | A rendering target: its session, its number within that session, and the
-- incarnation that number is currently on. A target number is reused after its
-- target retires; the incarnation is not, so a retained identity for the
-- retired target is stale rather than a handle on its successor.
data TargetId = TargetId !SessionIdentity !Natural !Natural
  deriving (Eq, Ord)

instance Show TargetId where
  showsPrec precedence (TargetId _ number incarnation) =
    showParen (precedence > 10) $
      showString "TargetId " . showsPrec 11 number . showChar ' ' . showsPrec 11 incarnation

targetSession ∷ TargetId → SessionIdentity
targetSession (TargetId session _ _) = session

targetNumber ∷ TargetId → Natural
targetNumber (TargetId _ number _) = number

-- | Starts at one and is never reissued for a target number.
targetIncarnation ∷ TargetId → Natural
targetIncarnation (TargetId _ _ incarnation) = incarnation

-- | One swapchain generation of one target. Generation numbers rise within a
-- target and are never reissued.
data GenerationId = GenerationId !TargetId !Natural
  deriving (Eq, Ord)

instance Show GenerationId where
  showsPrec precedence (GenerationId target number) =
    showParen (precedence > 10) $
      showString "GenerationId " . showsPrec 11 target . showChar ' ' . showsPrec 11 number

generationTarget ∷ GenerationId → TargetId
generationTarget (GenerationId target _) = target

generationNumber ∷ GenerationId → Natural
generationNumber (GenerationId _ number) = number

-- | One tracked image record of one generation, at the index the presentation
-- engine named. Two generations' images never share an identity even at the
-- same index.
data ImageId = ImageId !GenerationId !Natural
  deriving (Eq, Ord)

instance Show ImageId where
  showsPrec precedence (ImageId generation index) =
    showParen (precedence > 10) $
      showString "ImageId " . showsPrec 11 generation . showChar ' ' . showsPrec 11 index

imageGeneration ∷ ImageId → GenerationId
imageGeneration (ImageId generation _) = generation

imageIndex ∷ ImageId → Natural
imageIndex (ImageId _ index) = index

-- | One use of one frame slot: the target, the slot number, and the use that
-- slot is on. A slot number is reused once its own obligations end; the use
-- counter is not, so a frame identity outlives its slot only as a stale value.
data FrameSlotId = FrameSlotId !TargetId !Natural !Natural
  deriving (Eq, Ord)

instance Show FrameSlotId where
  showsPrec precedence (FrameSlotId target slot use) =
    showParen (precedence > 10) $
      showString "FrameSlotId "
        . showsPrec 11 target
        . showChar ' '
        . showsPrec 11 slot
        . showChar ' '
        . showsPrec 11 use

frameTarget ∷ FrameSlotId → TargetId
frameTarget (FrameSlotId target _ _) = target

frameSlotNumber ∷ FrameSlotId → Natural
frameSlotNumber (FrameSlotId _ slot _) = slot

-- | Starts at one for each slot and is never reissued.
frameUse ∷ FrameSlotId → Natural
frameUse (FrameSlotId _ _ use) = use

-- | One recorded batch of commands, belonging to one target.
data BatchId = BatchId !TargetId !Natural
  deriving (Eq, Ord)

instance Show BatchId where
  showsPrec precedence (BatchId target number) =
    showParen (precedence > 10) $
      showString "BatchId " . showsPrec 11 target . showChar ' ' . showsPrec 11 number

batchTarget ∷ BatchId → TargetId
batchTarget (BatchId target _) = target

batchNumber ∷ BatchId → Natural
batchNumber (BatchId _ number) = number

-- | One submission record. It is a session-wide identity because one call may
-- submit frames of several targets, and they then share exactly one record.
data SubmissionId = SubmissionId !SessionIdentity !Natural
  deriving (Eq, Ord)

instance Show SubmissionId where
  showsPrec precedence (SubmissionId _ number) =
    showParen (precedence > 10) (showString "SubmissionId " . showsPrec 11 number)

submissionSession ∷ SubmissionId → SessionIdentity
submissionSession (SubmissionId session _) = session

submissionNumber ∷ SubmissionId → Natural
submissionNumber (SubmissionId _ number) = number

-- | One presentation record, taken from its target's finite pool.
data PresentationId = PresentationId !TargetId !Natural
  deriving (Eq, Ord)

instance Show PresentationId where
  showsPrec precedence (PresentationId target number) =
    showParen (precedence > 10) $
      showString "PresentationId " . showsPrec 11 target . showChar ' ' . showsPrec 11 number

presentationTarget ∷ PresentationId → TargetId
presentationTarget (PresentationId target _) = target

presentationNumber ∷ PresentationId → Natural
presentationNumber (PresentationId _ number) = number

-- | One managed resource generation: the unit recording retains and disposal
-- releases. Its own generation counter rises when the same logical resource is
-- rebuilt, so a recorded reference names the exact contents it referenced.
data ResourceId = ResourceId !SessionIdentity !Natural !Natural
  deriving (Eq, Ord)

instance Show ResourceId where
  showsPrec precedence (ResourceId _ number generation) =
    showParen (precedence > 10) $
      showString "ResourceId " . showsPrec 11 number . showChar ' ' . showsPrec 11 generation

resourceSession ∷ ResourceId → SessionIdentity
resourceSession (ResourceId session _ _) = session

resourceNumber ∷ ResourceId → Natural
resourceNumber (ResourceId _ number _) = number

resourceGeneration ∷ ResourceId → Natural
resourceGeneration (ResourceId _ _ generation) = generation

-- | One allocation attempt. Its identity is stable across the reclamation pass
-- and the single retry that pass may permit, which is what keeps the retry bit
-- attached to the attempt rather than to whichever helper ran last.
data AllocationId = AllocationId !SessionIdentity !Natural
  deriving (Eq, Ord)

instance Show AllocationId where
  showsPrec precedence (AllocationId _ number) =
    showParen (precedence > 10) (showString "AllocationId " . showsPrec 11 number)

allocationSession ∷ AllocationId → SessionIdentity
allocationSession (AllocationId session _) = session

allocationNumber ∷ AllocationId → Natural
allocationNumber (AllocationId _ number) = number

-- ---------------------------------------------------------------------------
-- Classification

-- | The application classifies each target when it admits it. The
-- classification decides only what exhausted recovery escalates to; it never
-- weakens an ownership or completion requirement.
data TargetClass
  = RequiredTarget
    -- ^ Exhausted recovery fails the graphics session.
  | OptionalTarget
    -- ^ Exhausted recovery marks this target unavailable and leaves the
    -- session running.
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Subjects that carry holds

-- | The two kinds of object whose disposal the hold ledger governs.
data HoldSubject
  = GenerationSubject !GenerationId
  | ResourceSubject !ResourceId
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Misuse

-- | Which identity an answer is about. It never carries the identity itself,
-- so a refusal about a foreign value cannot smuggle that value back out.
data IdentityKind
  = DeviceIdentity
  | TargetIdentity
  | GenerationIdentity
  | ImageIdentity
  | FrameIdentity
  | BatchIdentity
  | SubmissionIdentity
  | PresentationIdentity
  | ResourceIdentity
  | AllocationIdentity
  deriving (Eq, Ord, Show)

-- | Typed misuse. Every operation checks for it before it changes anything, so
-- a rejected call leaves the model exactly as it found it.
data Misuse
  = ForeignIdentity !IdentityKind
    -- ^ The value belongs to another session's model.
  | UnknownIdentity !IdentityKind
    -- ^ This model never issued the value.
  | StaleIdentity !IdentityKind
    -- ^ The value named an object this model has since retired; a live object
    -- of the same number is a different incarnation.
  | AlreadyConsumed !IdentityKind
    -- ^ The value names a record that has already been settled once. A second
    -- settlement is misuse, not idempotence: it would discharge an obligation
    -- the first one already discharged.
  | WrongPhase !IdentityKind
    -- ^ The object exists and is this model's, but is not in a phase from
    -- which the requested transition is legal.
  | DuplicateSubject !IdentityKind
    -- ^ One call named the same object twice, such as a multi-frame submission
    -- listing a slot more than once.
  | EmptySubmission
    -- ^ A submission named no frame at all.
  | SessionAlreadyFailed
    -- ^ The session has escalated; it admits no further work.
  deriving (Eq, Ord, Show)
