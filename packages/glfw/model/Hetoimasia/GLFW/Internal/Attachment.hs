{-# LANGUAGE MultiWayIf #-}

-- | The backend-neutral model of exclusive window attachments and the evidence
-- that retires them.
--
-- A graphics integration that depends on a window — a future surface and the
-- work submitted through it — holds an /attachment/ to that window. This module
-- records which windows have an attachment, where each attachment is in its
-- lifetime, which retirement facts its owner has certified, and whether the
-- attachment still vetoes the window's destruction. It is a pure state machine
-- plus bounded bookkeeping and one bounded notice inbox: it performs no native
-- call, owns no thread, names no graphics type, and exposes no usable
-- attachment. Nothing in the public library exports it, and no production
-- component uses it yet; the protected host (LIFE-3) and the public attachment
-- contract (LIFE-4) of "docs/window_graphics_lifetime_design.md" follow.
--
-- = Identities
--
-- An 'AttachmentId' binds four identities: the host's 'HostIdentity', the
-- session's identity, the 'WindowId', and an incarnation. Incarnations start at
-- one and are never reissued by a model; a model's host identity is fresh, so
-- the pair names one attachment within the process. Every operation that
-- carries authority compares all four against the attachment it targets, and a
-- mismatch on any of them is typed misuse that changes nothing.
--
-- = Trusted inputs
--
-- The model does not establish its own premises. The owning boundary supplies
-- them and is responsible for them:
--
-- * the host identity passed to 'newAttachmentModel' is fresh — made from a
--   'Data.Unique.Unique' the boundary created for this host alone;
-- * the session identity is that of the session issuing the host's windows,
--   and windows are registered in the order that session issued them;
-- * every operation taking an 'OwnerAuthority' runs on the owner thread. A pure
--   transition cannot observe the executing OS thread, so the boundary checks
--   it before calling one, exactly as the window operations check theirs.
--
-- = Phases
--
-- @
-- (none)               → AttachmentRegistering  'attachWindow' reserves an open,
--                                               unoccupied window
-- AttachmentRegistering → AttachmentActive      'constructionSucceeded'
-- AttachmentRegistering → AttachmentRetiring    'beginRetirement', 'markWindowClosing',
--                                               or 'constructionFailed'
-- AttachmentActive      → AttachmentRetiring    'beginRetirement' or 'markWindowClosing'
-- AttachmentRetiring    → AttachmentRetired     every retirement fact is recorded
-- @
--
-- No other transition exists. A retiring attachment never becomes active: a
-- construction that succeeds after retirement began answers
-- 'PublicationSuperseded', and the constructed dependents stay registered for
-- retirement. 'AttachmentRetired' is never stored — a retired attachment's
-- entry is removed and the window's slot is free.
--
-- Construction is tracked beside the phase ('ConstructionState'). While it is
-- pending no retirement fact is accepted, because a construction still in
-- flight may yet create a dependent; its outcome must be recorded first.
--
-- = Failure evidence is not a phase
--
-- A failed construction or a failed disposal is recorded in
-- 'AttachmentEvidence' with its original failure, and later failures are
-- counted without replacing it. Recording a failure never retires anything.
-- A construction failure moves a registering attachment to retiring and records
-- its 'RollbackOutcome': 'RollbackSafe' establishes every retirement fact —
-- obligations the construction never created are explicitly discharged
-- ('DischargedByRollback') — and retires it; 'RollbackUnsafe' records nothing,
-- and the attachment keeps its window until each fact is certified separately.
-- A cancellation is counted as evidence and begins retirement; it establishes
-- no fact.
--
-- = Retirement facts
--
-- Four independent 'RetirementFact's retire an attachment: 'CpuUseRetired' (no
-- retained capability or pending producer can submit another use),
-- 'SubmittedWorkEnded', 'PresentationEnded', and 'DependentsDisposed'. Each
-- certifies an obligation that has irrevocably ended, so none is accepted before
-- retirement begins, while further use is still possible. The attachment is
-- retired — and stops vetoing its window — only when all four are recorded. No
-- single fact, elapsed time, cancellation, or failure substitutes for another,
-- and 'viewMissing' reports what is still owed.
--
-- 'windowVeto' answering 'NoAttachmentVeto' means only that this model no
-- longer vetoes destruction. Destroying the window still requires the host's
-- close protocol and its ordinary CPU borrows to allow it.
--
-- = Acknowledgements
--
-- Attaching returns an 'Acknowledgement' bound to the new incarnation. It is
-- the integration's completion authority: every attachment transition takes the
-- target 'AttachmentId' and an acknowledgement, and they must name the same
-- host, session, window, and incarnation. The acknowledgement prevents
-- accidental cross-window or cross-incarnation misuse; it is not proof that a
-- backend really finished, which the backend's own tested contract supplies.
--
-- Resolution, in order:
--
-- 1. The acknowledgement must name the target ('AcknowledgementForOther…').
-- 2. The target must belong to this model's host and session.
-- 3. An incarnation this model never issued is 'UnknownAttachment'.
-- 4. If the window holds an attachment of another incarnation, the target was
--    replaced: 'ReplacedAttachment'. This identity mismatch against a current
--    attachment takes precedence over terminal idempotence, so a late report
--    can never alter a replacement.
-- 5. If the target is absent it was retired, since an issued attachment leaves
--    the bookkeeping only by retiring. The report is accepted and changes
--    nothing; no entry is recreated.
--
-- Recording the same fact twice for a live incarnation is accepted and
-- idempotent.
--
-- = Owner authority and notices
--
-- 'newAttachmentModel' returns the model's 'OwnerAuthority'. Every operation
-- that changes the model takes it, and one from another model is
-- 'ForeignOwnerAuthority'. Observation — 'attachmentStatus', 'windowVeto', and
-- the counts — takes none.
--
-- Another thread cannot change the model. It publishes a 'CompletionNotice' to
-- a bounded 'CompletionInbox' with 'offerCompletion', which never waits: it
-- answers 'NoticeAdmitted', 'NoticeCoalesced' when an equal notice is already
-- pending, or 'NoticeRejectedFull' when the inbox holds its capacity of distinct
-- notices. An admitted notice stays pending until the owner takes it with
-- 'takeCompletions' and folds it with 'foldCompletions', which revalidates each
-- notice exactly as 'recordRetirementFact' does, so a notice queued for a
-- replaced attachment is misuse when folded and never touches the replacement.
--
-- = Bookkeeping
--
-- The model holds one record per registered, not yet forgotten window, at most
-- the host's window limit, and at most one attachment per record. Retired
-- attachments are removed. Stale identities are rejected by comparing
-- incarnations and local window numbers against the counters, never by
-- remembering them: a window numbered at or below the highest registered that
-- has no record has ended. No set grows with the number of attachments or
-- windows ever made.
--
-- = State
--
-- +----------------------+-----------------+---------------------------------+--------+-----------------+--------------------------------+
-- | State                | Owner           | Readers and writers             | Thread | Lifetime        | Reset or disposal              |
-- +======================+=================+=================================+========+=================+================================+
-- | Window records and   | The owning host | Owner transitions write; anyone | Owner  | The host        | A record is removed when its   |
-- | attachments          | boundary        | holding the value observes      |        |                 | window is forgotten; an        |
-- |                      |                 |                                 |        |                 | attachment when it retires     |
-- +----------------------+-----------------+---------------------------------+--------+-----------------+--------------------------------+
-- | Incarnation counter, | The model       | Attaching and registering       | Owner  | The host        | Never reissued                 |
-- | highest window       |                 | advance them                    |        |                 |                                |
-- +----------------------+-----------------+---------------------------------+--------+-----------------+--------------------------------+
-- | Completion inbox     | The owning host | Any thread offers; the owner    | Any;   | While           | Emptied by each take           |
-- |                      | boundary        | takes                           | STM    | referenced      |                                |
-- +----------------------+-----------------+---------------------------------+--------+-----------------+--------------------------------+
module Hetoimasia.GLFW.Internal.Attachment
  ( -- * Identities and authority
    HostIdentity
  , hostIdentity
  , OwnerAuthority
  , AttachmentId
  , attachmentHost
  , attachmentSession
  , attachmentWindow
  , attachmentIncarnation
  , Acknowledgement
  , acknowledgedAttachment
  , ActiveAttachment
  , activeAttachment

    -- * The model
  , AttachmentModel
  , AttachmentConfigRejected (..)
  , newAttachmentModel
  , modelHost
  , modelSession
  , modelWindowLimit

    -- * Phases, facts, and evidence
  , AttachmentPhase (..)
  , ConstructionState (..)
  , RetirementCause (..)
  , RetirementRequest (..)
  , RetirementFact (..)
  , allRetirementFacts
  , FactOrigin (..)
  , RollbackOutcome (..)
  , AttachmentFailure (..)
  , AttachmentEvidence (..)

    -- * Refusals and answers
  , AttachmentMisuse (..)
  , AttachmentRefusal (..)
  , Registered (..)
  , ClosingAnswer (..)
  , ConstructionAnswer (..)
  , RollbackAnswer (..)
  , RetirementAnswer (..)
  , FactAnswer (..)
  , FailureAnswer (..)

    -- * Window records
  , registerWindow
  , markWindowClosing
  , forgetWindow

    -- * Attachment transitions
  , attachWindow
  , constructionSucceeded
  , constructionFailed
  , beginRetirement
  , recordRetirementFact
  , recordDisposalFailure

    -- * Observation
  , AttachmentStatus (..)
  , AttachmentView (..)
  , attachmentStatus
  , WindowVeto (..)
  , windowVeto
  , liveAttachmentCount
  , windowRecordCount

    -- * Completion notices
  , CompletionInbox
  , InboxCapacityRejected (..)
  , newCompletionInbox
  , CompletionNotice
  , completionNotice
  , noticeTarget
  , noticeFact
  , NoticeAdmission (..)
  , offerCompletion
  , takeCompletions
  , foldCompletions
  ) where

import Control.Concurrent.STM (STM, TVar, newTVar, readTVar, writeTVar)
import Control.Monad (when)
import Data.Foldable (toList)
import Data.List (mapAccumL)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Unique (Unique)
import Hetoimasia.GLFW.Internal.Window (WindowId, windowLocalIdentity, windowSessionIdentity)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Identities and authority

-- | A window host's identity, supplied fresh by the owning boundary.
newtype HostIdentity = HostIdentity Unique
  deriving (Eq)

instance Show HostIdentity where
  show _ = "HostIdentity"

-- | Name a host by a 'Unique' the boundary created for it alone.
hostIdentity ∷ Unique → HostIdentity
hostIdentity = HostIdentity

-- | The authority to change a model, held only by its owner.
newtype OwnerAuthority = OwnerAuthority Unique

-- | One attachment: its host, session, window, and incarnation.
data AttachmentId = AttachmentId !HostIdentity !Unique !WindowId !Natural
  deriving (Eq)

instance Show AttachmentId where
  showsPrec precedence (AttachmentId _ _ window incarnation) =
    showParen (precedence > 10) $
      showString "AttachmentId " . showsPrec 11 window . showChar ' ' . showsPrec 11 incarnation

attachmentHost ∷ AttachmentId → HostIdentity
attachmentHost (AttachmentId identity _ _ _) = identity

attachmentSession ∷ AttachmentId → Unique
attachmentSession (AttachmentId _ identity _ _) = identity

attachmentWindow ∷ AttachmentId → WindowId
attachmentWindow (AttachmentId _ _ window _) = window

-- | Starts at one; never reissued by a model.
attachmentIncarnation ∷ AttachmentId → Natural
attachmentIncarnation (AttachmentId _ _ _ incarnation) = incarnation

-- | Completion authority for exactly one attachment incarnation.
newtype Acknowledgement = Acknowledgement AttachmentId
  deriving (Eq)

instance Show Acknowledgement where
  showsPrec precedence (Acknowledgement identity) =
    showParen (precedence > 10) (showString "Acknowledgement " . showsPrec 11 identity)

acknowledgedAttachment ∷ Acknowledgement → AttachmentId
acknowledgedAttachment (Acknowledgement identity) = identity

-- | The representation of a usable capability. Only 'constructionSucceeded'
-- makes one, and only for a registering attachment whose retirement has not
-- begun.
newtype ActiveAttachment = ActiveAttachment AttachmentId
  deriving (Eq, Show)

activeAttachment ∷ ActiveAttachment → AttachmentId
activeAttachment (ActiveAttachment identity) = identity

-- ---------------------------------------------------------------------------
-- Phases, facts, and evidence

data AttachmentPhase
  = AttachmentRegistering
    -- ^ The window is reserved and construction may be under way.
  | AttachmentActive
    -- ^ Construction and registration completed; a capability was published.
  | AttachmentRetiring
    -- ^ No new use may begin; the retirement facts are being established.
  | AttachmentRetired
    -- ^ Every fact is recorded. Never stored: the entry is removed.
  deriving (Eq, Show)

data ConstructionState
  = ConstructionPending
  | Constructed
  | ConstructionFailed !RollbackOutcome
  deriving (Eq, Show)

-- | Why retirement began. The first cause is kept.
data RetirementCause
  = RetiredByDetach
  | RetiredByWindowClosing
  | RetiredByCancellation
  | RetiredByConstructionFailure
  deriving (Eq, Show)

-- | What an integration may ask of 'beginRetirement'.
data RetirementRequest
  = Detach
    -- ^ Stop using the window while it stays open.
  | Cancel
    -- ^ A cancellation reached a handoff. Counted each time it is recorded.
  deriving (Eq, Show)

data RetirementFact
  = CpuUseRetired
    -- ^ No retained capability or pending producer can submit another use.
  | SubmittedWorkEnded
  | PresentationEnded
  | DependentsDisposed
  deriving (Eq, Ord, Show, Enum, Bounded)

allRetirementFacts ∷ [RetirementFact]
allRetirementFacts = [minBound .. maxBound]

data FactOrigin
  = ReportedEnded
    -- ^ The integration certified the obligation ended.
  | DischargedByRollback
    -- ^ A safe rollback established that the obligation no longer exists.
  deriving (Eq, Show)

data RollbackOutcome
  = RollbackSafe
    -- ^ Rollback established that no dependent can use the window.
  | RollbackUnsafe
    -- ^ Rollback could not establish safety.
  deriving (Eq, Show)

data AttachmentFailure e
  = ConstructionFailure !e !RollbackOutcome
  | DisposalFailure !e
  deriving (Eq, Show)

data AttachmentEvidence e = AttachmentEvidence
  { evidenceFirstFailure ∷ !(Maybe (AttachmentFailure e))
    -- ^ The original failure, never replaced.
  , evidenceLaterFailures ∷ !Natural
  , evidenceCancellations ∷ !Natural
  }
  deriving (Eq, Show)

noEvidence ∷ AttachmentEvidence e
noEvidence = AttachmentEvidence Nothing 0 0

withFailure ∷ AttachmentFailure e → AttachmentEvidence e → AttachmentEvidence e
withFailure failure evidence = case evidenceFirstFailure evidence of
  Nothing → evidence {evidenceFirstFailure = Just failure}
  Just _ → evidence {evidenceLaterFailures = evidenceLaterFailures evidence + 1}

-- ---------------------------------------------------------------------------
-- Refusals and answers

-- | Authority or identity that does not belong to the target.
data AttachmentMisuse
  = ForeignOwnerAuthority
  | ForeignHost
  | ForeignSession
  | AcknowledgementForOtherHost
  | AcknowledgementForOtherSession
  | AcknowledgementForOtherWindow
  | AcknowledgementForOtherIncarnation
  | ReplacedAttachment
    -- ^ The window now holds a later incarnation.
  | UnknownAttachment
    -- ^ This model never issued the incarnation.
  deriving (Eq, Show)

-- | Every refusal leaves the model unchanged: a refused transition returns no
-- model.
data AttachmentRefusal
  = AttachmentMisuse !AttachmentMisuse
  | WindowNotRegistered !WindowId
  | WindowAlreadyRegistered !WindowId
  | WindowHasEnded !WindowId
  | WindowIsClosing !WindowId
  | WindowOccupied !AttachmentId
  | WindowLimitReached !Int
  | WindowStillAttached !AttachmentId
  | NotRetiring !AttachmentPhase
    -- ^ A fact or disposal failure before retirement began.
  | ConstructionStillPending
  | ConstructionAlreadySettled !ConstructionState
  deriving (Eq, Show)

data Registered = Registered
  { registeredAttachment ∷ !AttachmentId
  , registeredAcknowledgement ∷ !Acknowledgement
  }
  deriving (Eq, Show)

data ClosingAnswer
  = WindowNowClosing !(Maybe AttachmentId)
    -- ^ The window's attachment, now retiring, if it has one.
  | WindowAlreadyClosing
  deriving (Eq, Show)

data ConstructionAnswer
  = CapabilityPublished !ActiveAttachment
  | PublicationSuperseded
    -- ^ Retirement began first; the dependents stay registered for it.
  deriving (Eq, Show)

data RollbackAnswer
  = RolledBackAndRetired
  | RollbackRetained ![RetirementFact]
    -- ^ Unsafe: the attachment keeps its window and owes these facts.
  deriving (Eq, Show)

data RetirementAnswer
  = RetirementBegun
  | RetirementAlreadyBegun
  | RetirementAlreadyComplete
  deriving (Eq, Show)

data FactAnswer
  = FactRecorded ![RetirementFact]
    -- ^ The facts still missing, never empty.
  | FactAlreadyRecorded
  | AttachmentNowRetired
  | AttachmentAlreadyRetired
  deriving (Eq, Show)

data FailureAnswer
  = FailureRecorded
  | FailureAfterRetirement
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- The model

data AttachmentModel e = AttachmentModel
  { modelHostIdentity ∷ !HostIdentity
  , modelOwner ∷ !Unique
  , modelSessionIdentity ∷ !Unique
  , modelLimit ∷ !Int
  , modelHighestWindow ∷ !Natural
  , modelNextIncarnation ∷ !Natural
  , modelWindows ∷ !(Map Natural (WindowRecord e))
  }
  deriving (Eq)

data WindowRecord e = WindowRecord
  { recordWindow ∷ !WindowId
  , recordClosing ∷ !Bool
  , recordAttachment ∷ !(Maybe (Attachment e))
  }
  deriving (Eq)

data Attachment e = Attachment
  { attachmentIdentity ∷ !AttachmentId
  , attachmentPhase ∷ !AttachmentPhase
  , attachmentConstruction ∷ !ConstructionState
  , attachmentCause ∷ !(Maybe RetirementCause)
  , attachmentFacts ∷ !(Map RetirementFact FactOrigin)
  , attachmentEvidence ∷ !(AttachmentEvidence e)
  }
  deriving (Eq)

modelHost ∷ AttachmentModel e → HostIdentity
modelHost = modelHostIdentity

modelSession ∷ AttachmentModel e → Unique
modelSession = modelSessionIdentity

modelWindowLimit ∷ AttachmentModel e → Int
modelWindowLimit = modelLimit

newtype AttachmentConfigRejected = WindowLimitBelowOne Int
  deriving (Eq, Show)

-- | An empty model for one host and session, and its owner's authority.
newAttachmentModel ∷ HostIdentity → Unique → Int → Either AttachmentConfigRejected (OwnerAuthority, AttachmentModel e)
newAttachmentModel identity@(HostIdentity owner) session limit
  | limit < 1 = Left (WindowLimitBelowOne limit)
  | otherwise = Right (OwnerAuthority owner, AttachmentModel identity owner session limit 0 1 Map.empty)

type Transition e r = AttachmentModel e → Either AttachmentRefusal (r, AttachmentModel e)

misuse ∷ AttachmentMisuse → Either AttachmentRefusal a
misuse = Left . AttachmentMisuse

owned ∷ OwnerAuthority → AttachmentModel e → Either AttachmentRefusal ()
owned (OwnerAuthority owner) model
  | owner /= modelOwner model = misuse ForeignOwnerAuthority
  | otherwise = Right ()

-- | A window's record, or why it has none.
windowRecord ∷ WindowId → AttachmentModel e → Either AttachmentRefusal (WindowRecord e)
windowRecord window model
  | windowSessionIdentity window /= modelSessionIdentity model = misuse ForeignSession
  | local > modelHighestWindow model = Left (WindowNotRegistered window)
  | otherwise = maybe (Left (WindowHasEnded window)) Right (Map.lookup local (modelWindows model))
  where
    local = windowLocalIdentity window

withRecord ∷ WindowRecord e → AttachmentModel e → AttachmentModel e
withRecord record model =
  model {modelWindows = Map.insert (windowLocalIdentity (recordWindow record)) record (modelWindows model)}

withAttachment ∷ WindowRecord e → Maybe (Attachment e) → AttachmentModel e → AttachmentModel e
withAttachment record attachment = withRecord record {recordAttachment = attachment}

missingFacts ∷ Attachment e → [RetirementFact]
missingFacts attachment = filter (`Map.notMember` attachmentFacts attachment) allRetirementFacts

-- ---------------------------------------------------------------------------
-- Window records

-- | Record a window the session issued after every window already registered.
registerWindow ∷ OwnerAuthority → WindowId → Transition e ()
registerWindow authority window model = do
  owned authority model
  let local = windowLocalIdentity window
  if
    | windowSessionIdentity window /= modelSessionIdentity model → misuse ForeignSession
    | Map.member local (modelWindows model) → Left (WindowAlreadyRegistered window)
    | local <= modelHighestWindow model → Left (WindowHasEnded window)
    | Map.size (modelWindows model) >= modelLimit model → Left (WindowLimitReached (modelLimit model))
    | otherwise →
        Right
          ( ()
          , withRecord (WindowRecord window False Nothing) model {modelHighestWindow = local}
          )

-- | Record that the window's close protocol began. Its attachment, if still
-- registering or active, begins retiring.
markWindowClosing ∷ OwnerAuthority → WindowId → Transition e ClosingAnswer
markWindowClosing authority window model = do
  owned authority model
  record ← windowRecord window model
  if recordClosing record
    then Right (WindowAlreadyClosing, model)
    else do
      let closing = record {recordClosing = True}
          retiring current = case attachmentPhase current of
            AttachmentRetiring → current
            _ → current {attachmentPhase = AttachmentRetiring, attachmentCause = Just RetiredByWindowClosing}
          attachment = retiring <$> recordAttachment record
      Right (WindowNowClosing (attachmentIdentity <$> attachment), withAttachment closing attachment model)

-- | Forget an ended window's record. Refused while an attachment vetoes it.
forgetWindow ∷ OwnerAuthority → WindowId → Transition e ()
forgetWindow authority window model = do
  owned authority model
  record ← windowRecord window model
  case recordAttachment record of
    Just attachment → Left (WindowStillAttached (attachmentIdentity attachment))
    Nothing →
      Right ((), model {modelWindows = Map.delete (windowLocalIdentity window) (modelWindows model)})

-- ---------------------------------------------------------------------------
-- Attachment transitions

-- | Reserve an open, unoccupied window of this host and session. Every refusal
-- is answered before the boundary may begin any acquisition.
attachWindow ∷ OwnerAuthority → HostIdentity → WindowId → Transition e Registered
attachWindow authority requested window model = do
  owned authority model
  when (requested /= modelHostIdentity model) (misuse ForeignHost)
  record ← windowRecord window model
  when (recordClosing record) (Left (WindowIsClosing window))
  case recordAttachment record of
    Just occupant → Left (WindowOccupied (attachmentIdentity occupant))
    Nothing → do
      let incarnation = modelNextIncarnation model
          identity = AttachmentId (modelHostIdentity model) (modelSessionIdentity model) window incarnation
          attachment = Attachment identity AttachmentRegistering ConstructionPending Nothing Map.empty noEvidence
      Right
        ( Registered identity (Acknowledgement identity)
        , withAttachment record (Just attachment) model {modelNextIncarnation = incarnation + 1}
        )

-- | A target resolved against the model: its current record and attachment,
-- or retired.
data Resolved e
  = Current !(WindowRecord e) !(Attachment e)
  | Terminal

resolve ∷ AttachmentId → AttachmentModel e → Either AttachmentMisuse (Resolved e)
resolve (AttachmentId host session window incarnation) model
  | host /= modelHostIdentity model = Left ForeignHost
  | session /= modelSessionIdentity model || windowSessionIdentity window /= session = Left ForeignSession
  | incarnation >= modelNextIncarnation model = Left UnknownAttachment
  | otherwise = case Map.lookup (windowLocalIdentity window) (modelWindows model) of
      Just record
        | Just attachment ← recordAttachment record →
            if attachmentIncarnation (attachmentIdentity attachment) == incarnation
              then Right (Current record attachment)
              else Left ReplacedAttachment
      _ → Right Terminal

matched ∷ AttachmentId → Acknowledgement → Either AttachmentMisuse ()
matched (AttachmentId host session window incarnation) (Acknowledgement (AttachmentId host' session' window' incarnation'))
  | host /= host' = Left AcknowledgementForOtherHost
  | session /= session' = Left AcknowledgementForOtherSession
  | window /= window' = Left AcknowledgementForOtherWindow
  | incarnation /= incarnation' = Left AcknowledgementForOtherIncarnation
  | otherwise = Right ()

authorized ∷ OwnerAuthority → AttachmentId → Acknowledgement → AttachmentModel e → Either AttachmentRefusal (Resolved e)
authorized authority target acknowledgement model = do
  owned authority model
  either misuse Right (matched target acknowledgement >> resolve target model)

-- | Construction and registration completed. Publishes the capability only if
-- retirement has not begun.
constructionSucceeded ∷ OwnerAuthority → AttachmentId → Acknowledgement → Transition e ConstructionAnswer
constructionSucceeded authority target acknowledgement model =
  authorized authority target acknowledgement model >>= \case
    Terminal → Right (PublicationSuperseded, model)
    Current record attachment
      | attachmentConstruction attachment /= ConstructionPending →
          Left (ConstructionAlreadySettled (attachmentConstruction attachment))
      | attachmentPhase attachment == AttachmentRegistering →
          Right
            ( CapabilityPublished (ActiveAttachment target)
            , withAttachment record (Just attachment {attachmentPhase = AttachmentActive, attachmentConstruction = Constructed}) model
            )
      | otherwise →
          Right (PublicationSuperseded, withAttachment record (Just attachment {attachmentConstruction = Constructed}) model)

-- | Construction failed with its original failure, and owned rollback ran.
-- Only a safe rollback retires the attachment.
constructionFailed ∷ OwnerAuthority → AttachmentId → Acknowledgement → e → RollbackOutcome → Transition e RollbackAnswer
constructionFailed authority target acknowledgement failure rollback model =
  authorized authority target acknowledgement model >>= \case
    Terminal → Right (RolledBackAndRetired, model)
    Current record attachment
      | attachmentConstruction attachment /= ConstructionPending →
          Left (ConstructionAlreadySettled (attachmentConstruction attachment))
      | otherwise →
          let failed =
                attachment
                  { attachmentPhase = AttachmentRetiring
                  , attachmentConstruction = ConstructionFailed rollback
                  , attachmentCause = Just (fromMaybe RetiredByConstructionFailure (attachmentCause attachment))
                  , attachmentEvidence = withFailure (ConstructionFailure failure rollback) (attachmentEvidence attachment)
                  }
           in case rollback of
                RollbackSafe → Right (RolledBackAndRetired, withAttachment record Nothing model)
                RollbackUnsafe → Right (RollbackRetained (missingFacts failed), withAttachment record (Just failed) model)

-- | Begin retirement: detach while the window stays open, or record a
-- cancellation at a handoff. A cancellation is counted every time.
beginRetirement ∷ OwnerAuthority → AttachmentId → Acknowledgement → RetirementRequest → Transition e RetirementAnswer
beginRetirement authority target acknowledgement request model =
  authorized authority target acknowledgement model >>= \case
    Terminal → Right (RetirementAlreadyComplete, model)
    Current record attachment →
      let evidence = attachmentEvidence attachment
          counted = case request of
            Cancel → attachment {attachmentEvidence = evidence {evidenceCancellations = evidenceCancellations evidence + 1}}
            Detach → attachment
          cause = case request of
            Cancel → RetiredByCancellation
            Detach → RetiredByDetach
       in case attachmentPhase attachment of
            AttachmentRetiring → Right (RetirementAlreadyBegun, withAttachment record (Just counted) model)
            _ →
              Right
                ( RetirementBegun
                , withAttachment record (Just counted {attachmentPhase = AttachmentRetiring, attachmentCause = Just cause}) model
                )

-- | Certify that one obligation has irrevocably ended. The last missing fact
-- retires the attachment and frees its window.
recordRetirementFact ∷ OwnerAuthority → AttachmentId → Acknowledgement → RetirementFact → Transition e FactAnswer
recordRetirementFact authority target acknowledgement fact model =
  authorized authority target acknowledgement model >>= \case
    Terminal → Right (AttachmentAlreadyRetired, model)
    Current record attachment
      | attachmentPhase attachment /= AttachmentRetiring → Left (NotRetiring (attachmentPhase attachment))
      | attachmentConstruction attachment == ConstructionPending → Left ConstructionStillPending
      | Map.member fact (attachmentFacts attachment) → Right (FactAlreadyRecorded, model)
      | otherwise →
          let recorded = attachment {attachmentFacts = Map.insert fact ReportedEnded (attachmentFacts attachment)}
           in case missingFacts recorded of
                [] → Right (AttachmentNowRetired, withAttachment record Nothing model)
                missing → Right (FactRecorded missing, withAttachment record (Just recorded) model)

-- | Record a failed disposal step. It is evidence only: it establishes no fact
-- and leaves the attachment retiring.
recordDisposalFailure ∷ OwnerAuthority → AttachmentId → Acknowledgement → e → Transition e FailureAnswer
recordDisposalFailure authority target acknowledgement failure model =
  authorized authority target acknowledgement model >>= \case
    Terminal → Right (FailureAfterRetirement, model)
    Current record attachment
      | attachmentPhase attachment /= AttachmentRetiring → Left (NotRetiring (attachmentPhase attachment))
      | otherwise →
          Right
            ( FailureRecorded
            , withAttachment
                record
                (Just attachment {attachmentEvidence = withFailure (DisposalFailure failure) (attachmentEvidence attachment)})
                model
            )

-- ---------------------------------------------------------------------------
-- Observation

data AttachmentView e = AttachmentView
  { viewPhase ∷ !AttachmentPhase
  , viewConstruction ∷ !ConstructionState
  , viewCause ∷ !(Maybe RetirementCause)
  , viewRecorded ∷ !(Map RetirementFact FactOrigin)
  , viewMissing ∷ ![RetirementFact]
  , viewEvidence ∷ !(AttachmentEvidence e)
  }
  deriving (Eq, Show)

data AttachmentStatus e
  = AttachmentLive !(AttachmentView e)
  | AttachmentGone
    -- ^ Retired and removed.
  deriving (Eq, Show)

-- | An attachment's status. Needs no authority.
attachmentStatus ∷ AttachmentId → AttachmentModel e → Either AttachmentMisuse (AttachmentStatus e)
attachmentStatus target model =
  resolve target model >>= \case
    Terminal → Right AttachmentGone
    Current _ attachment →
      Right . AttachmentLive $
        AttachmentView
          { viewPhase = attachmentPhase attachment
          , viewConstruction = attachmentConstruction attachment
          , viewCause = attachmentCause attachment
          , viewRecorded = attachmentFacts attachment
          , viewMissing = missingFacts attachment
          , viewEvidence = attachmentEvidence attachment
          }

data WindowVeto
  = NoAttachmentVeto
    -- ^ This model does not veto destruction; the host's own conditions still apply.
  | VetoedByAttachment !AttachmentId !AttachmentPhase ![RetirementFact]
  deriving (Eq, Show)

-- | Whether an attachment still vetoes the window's destruction.
windowVeto ∷ WindowId → AttachmentModel e → Either AttachmentMisuse WindowVeto
windowVeto window model
  | windowSessionIdentity window /= modelSessionIdentity model = Left ForeignSession
  | otherwise = Right $ case Map.lookup (windowLocalIdentity window) (modelWindows model) >>= recordAttachment of
      Nothing → NoAttachmentVeto
      Just attachment →
        VetoedByAttachment (attachmentIdentity attachment) (attachmentPhase attachment) (missingFacts attachment)

-- | Registering, active, and retiring attachments.
liveAttachmentCount ∷ AttachmentModel e → Int
liveAttachmentCount = length . concatMap (toList . recordAttachment) . Map.elems . modelWindows

-- | Registered windows not yet forgotten.
windowRecordCount ∷ AttachmentModel e → Int
windowRecordCount = Map.size . modelWindows

-- ---------------------------------------------------------------------------
-- Completion notices

-- | A certified fact published by a thread that is not the owner.
data CompletionNotice = CompletionNotice !AttachmentId !Acknowledgement !RetirementFact
  deriving (Eq, Show)

completionNotice ∷ AttachmentId → Acknowledgement → RetirementFact → CompletionNotice
completionNotice = CompletionNotice

noticeTarget ∷ CompletionNotice → AttachmentId
noticeTarget (CompletionNotice target _ _) = target

noticeFact ∷ CompletionNotice → RetirementFact
noticeFact (CompletionNotice _ _ fact) = fact

-- | A bounded set of pending notices, in arrival order.
data CompletionInbox = CompletionInbox !Int !(TVar (Seq CompletionNotice))

newtype InboxCapacityRejected = InboxCapacityBelowOne Int
  deriving (Eq, Show)

newCompletionInbox ∷ Int → STM (Either InboxCapacityRejected CompletionInbox)
newCompletionInbox capacity
  | capacity < 1 = pure (Left (InboxCapacityBelowOne capacity))
  | otherwise = Right . CompletionInbox capacity <$> newTVar Seq.empty

data NoticeAdmission
  = NoticeAdmitted
  | NoticeCoalesced
    -- ^ An equal notice is already pending.
  | NoticeRejectedFull
  deriving (Eq, Show)

-- | Publish a notice from any thread. Never retries, so never waits.
offerCompletion ∷ CompletionInbox → CompletionNotice → STM NoticeAdmission
offerCompletion (CompletionInbox capacity entries) notice = do
  pending ← readTVar entries
  if
    | notice `elem` pending → pure NoticeCoalesced
    | Seq.length pending >= capacity → pure NoticeRejectedFull
    | otherwise → NoticeAdmitted <$ writeTVar entries (pending |> notice)

-- | Take every pending notice, oldest first. Never retries.
takeCompletions ∷ CompletionInbox → STM [CompletionNotice]
takeCompletions (CompletionInbox _ entries) = do
  pending ← readTVar entries
  writeTVar entries Seq.empty
  pure (toList pending)

-- | Fold taken notices on the owner thread, revalidating each as
-- 'recordRetirementFact' does. A refused notice changes nothing.
foldCompletions ∷ OwnerAuthority → [CompletionNotice] → AttachmentModel e → ([(CompletionNotice, Either AttachmentRefusal FactAnswer)], AttachmentModel e)
foldCompletions authority notices model0 = swap (mapAccumL step model0 notices)
  where
    swap (model, answers) = (answers, model)
    step model notice@(CompletionNotice target acknowledgement fact) =
      case recordRetirementFact authority target acknowledgement fact model of
        Left refusal → (model, (notice, Left refusal))
        Right (answer, next) → (next, (notice, Right answer))
