-- | The protected host's owned retirement state and its owner-thread drain.
--
-- "Hetoimasia.GLFW.Internal.Attachment" is the pure model of exclusive window
-- attachments and the facts that retire them. This module is the one boundary
-- that owns an instance of it: it holds the model beside its owner authority,
-- the bounded completion inbox other threads publish through, the attachment
-- admission gate, and the trusted retirement protocol each attachment's owner
-- supplied. It makes no native call itself — the protected host lends it the
-- ones it needs to keep native event processing and the session's internal wake
-- support live while it waits — and it names no graphics type.
--
-- It belongs to the private @runtime-glfw-core@ sublibrary. The public
-- attachment contract of "Hetoimasia.Runtime.GLFW" is built over it and
-- re-exports the caller-facing parts — the protocol, its completion policy, the
-- progress answers, and the detach answer — while the state, the model, the
-- drain, and the registrations stay here.
--
-- = What a protected host owns that an ordinary one does not
--
-- 'Hetoimasia.Runtime.GLFW.allocWindowHost' builds a host as an ordinary
-- 'Hetoimasia.Foundation.Resource.Scoped' dependency, whose finalizers cannot
-- implement this contract: they run uninterruptibly, after the application
-- runner has already unwound everything a dependent might still need. Such a
-- host is issued no 'HostIdentity', so an attachment can never name it, and the
-- protected lifetime is the only boundary that makes a 'HostRetirement'.
--
-- = The drain
--
-- 'drainRetirement' runs on the owner thread after supervision has drained
-- every worker and before any window, session, or parent is released. One round
-- is:
--
-- 1. every notice other threads published is taken and folded, revalidated
--    exactly as an owner-thread report is;
-- 2. every pending attachment that still has a progress path is given one
--    bounded opportunity, in registration order, so a stalled attachment cannot
--    starve one that could still retire;
-- 3. every window whose close protocol has begun is offered retirement again,
--    so a chain that has just become safe is destroyed while another chain's
--    window, the shared session, and every borrowed parent stay live;
-- 4. the environment's native event processing runs — a poll when the round
--    made progress, otherwise the finite bound the host configured — keeping
--    both the events retirement needs and the internal wake that ends the wait
--    live.
--
-- The round repeats until no registered attachment is pending. An attachment is
-- pending until the model records every one of its retirement facts: no elapsed
-- time, cancellation, failure, or disposition substitutes for one.
--
-- A step that answers 'RetirementStalled', and one that fails, both withdraw
-- the attachment's progress path: the drain never replays a failed step, and it
-- resumes stepping only when independent evidence — a completion notice for
-- that attachment — arrives. As soon as any pending attachment has no path
-- left, the drain makes one protected diagnostic attempt and keeps waiting; the
-- diagnostic's own failure is retained and unwinds nothing.
--
-- = Failures and cancellation
--
-- The drain never throws. It accumulates what happened in a 'DrainOutcome' that
-- the protected boundary settles against the body's own outcome: the first
-- synchronous failure, the ones retained after it, and the first cancellation
-- delivered during the drain, which is deferred until retirement is safe. A
-- cancellation is also recorded against every attachment it reached as the
-- model's evidence, and establishes no fact.
--
-- Retained evidence is bounded. At most 'retainedFailureLimit' failures are
-- kept beside the first and the rest are counted, so a boundary waiting
-- indefinitely under the stall policy cannot grow without bound. A native pump
-- that fails withdraws itself for the same reason; the drain then waits on the
-- inbox under a finite timer instead, and completion notices still finish
-- retirement.
--
-- = State
--
-- +----------------------+------------------+--------------------------------+--------+------------+--------------------------------+
-- | State                | Owner            | Readers and writers            | Thread | Lifetime   | Reset or disposal              |
-- +======================+==================+================================+========+============+================================+
-- | The attachment model | The protected    | The owner thread writes; any   | Owner; | The host   | Ends with the host; every      |
-- |                      | host lifetime    | thread may read it             | STM    |            | attachment is retired first    |
-- +----------------------+------------------+--------------------------------+--------+------------+--------------------------------+
-- | Attachment admission | The protected    | Closed by quiescence and by    | Any;   | The host   | Closed on every exit,          |
-- |                      | host lifetime    | the host's own exit            | STM    |            | idempotently                   |
-- +----------------------+------------------+--------------------------------+--------+------------+--------------------------------+
-- | Retirement protocols | The protected    | The owner thread registers,    | Owner; | Until the  | Removed when its attachment    |
-- |                      | host lifetime    | withdraws, and prunes them     | STM    | attachment | retires; at most one per       |
-- |                      |                  |                                |        | retires    | window the host may hold       |
-- +----------------------+------------------+--------------------------------+--------+------------+--------------------------------+
-- | The stall diagnostic | The protected    | The owner thread claims it     | Owner  | The host   | Claimed once, never retried    |
-- |                      | host lifetime    |                                |        |            |                                |
-- +----------------------+------------------+--------------------------------+--------+------------+--------------------------------+
module Hetoimasia.Runtime.GLFW.Internal.Retirement
  ( -- * The state a protected host owns
    HostRetirement
  , newHostRetirement
  , retirementIdentity
  , retirementAuthority

    -- * Admission and window records
  , closeAttachmentAdmission
  , attachmentAdmissionOpen
  , recordRegisteredWindow
  , recordClosingWindow
  , forgetRetiredWindow
  , windowRetirementVeto

    -- * The private attachment seam
  , AttachmentProtocol (..)
  , CompletionPolicy (..)
  , RetirementProgress (..)
  , AttachmentOutcome (..)
  , RolledBack (..)
  , attachRetirement
  , pendingAttachments
  , attachmentViewOf
  , certifyRetirementFact
  , windowAttachmentState

    -- * Detaching and in-run progress
  , DetachAnswer (..)
  , detachAttachment
  , ProgressRound (..)
  , noProgressRound
  , advanceRetirements

    -- * Completion notices from other threads
  , CompletionPublisher
  , CompletionPublication (..)
  , completionPublisher
  , publishCompletion

    -- * The drain
  , RetirementEnvironment (..)
  , DrainOutcome (..)
  , noDrainOutcome
  , drainRetirement
  , retainedFailureLimit
  , retirementComponent
  , retirementOperation
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , newTVarIO
  , readTVar
  , registerDelay
  , retry
  , writeTVar
  )
import Control.Exception
  ( Exception (displayException)
  , evaluate
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask_
  , rethrowIO
  , tryWithContext
  )
import Control.Monad (unless, void, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Unique (Unique, newUnique)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, Logger, logWarning, unsafeComponent)
import Hetoimasia.Foundation.Resource (withResourceLabelled)
import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.Foundation.Recovery
  ( AttemptFailure (attemptException)
  , Disposition (..)
  , Outcome (..)
  , RecoveryPolicy (..)
  , Recovered (recoveredValue)
  , Strategy (Retry)
  , Unavailability (unavailableReason)
  , recover
  )
import Hetoimasia.GLFW.Internal.Attachment
  ( Acknowledgement
  , ActiveAttachment
  , allRetirementFacts
  , AttachmentId
  , AttachmentModel
  , AttachmentPhase (..)
  , AttachmentRefusal (..)
  , AttachmentStatus (..)
  , AttachmentView (..)
  , RetirementAnswer (..)
  , CompletionInbox
  , CompletionNotice
  , ConstructionAnswer (..)
  , HostIdentity
  , NoticeAdmission (..)
  , OwnerAuthority
  , Registered (..)
  , RetirementRequest (..)
  , RollbackOutcome (..)
  , WindowVeto (..)
  , attachWindow
  , attachmentStatus
  , beginRetirement
  , constructionFailed
  , constructionSucceeded
  , FactAnswer (..)
  , RetirementFact
  , recordRetirementFact
  , foldCompletions
  , forgetWindow
  , hostIdentity
  , markWindowClosing
  , newAttachmentModel
  , newCompletionInbox
  , noticeTarget
  , offerCompletion
  , recordDisposalFailure
  , registerWindow
  , takeCompletions
  , windowVeto
  )
import Hetoimasia.GLFW.Internal.Notify (Notifier, dischargeNotification, registerNotification)
import Hetoimasia.GLFW.Window (WindowId)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- The state a protected host owns

-- | The evidence the model records: a failure with the context it propagated
-- with, so its origin and any retained cleanup evidence stay inspectable.
type Evidence = ExceptionWithContext SomeException

-- | The retirement state one protected host owns. Its representation is
-- private: no authority, model, or protocol can be taken from it.
data HostRetirement = HostRetirement
  { retirementHostIdentity ∷ !HostIdentity
  , retirementOwner ∷ !OwnerAuthority
  , retirementState ∷ !(TVar (AttachmentModel Evidence))
  , retirementInbox ∷ !CompletionInbox
  , retirementAdmitting ∷ !(TVar Bool)
  , retirementPublishing ∷ !(TVar Bool)
    -- ^ Whether a completion notice may still be offered. The drain closes it
    -- in the same transaction that finds nothing pending, so no notice — and so
    -- no notification obligation, and no wake — can be registered after the
    -- boundary has decided retirement is over.
  , retirementRegistrations ∷ !(TVar [Registration])
    -- ^ In registration order, at most one per window the host may hold.
  , retirementDiagnosed ∷ !(IORef Bool)
  }

-- | One attachment's registered protocol, and whether it still has a progress
-- path the drain may take.
data Registration = Registration
  { registrationTarget ∷ !AttachmentId
  , registrationAcknowledgement ∷ !Acknowledgement
  , registrationProtocol ∷ !AttachmentProtocol
  , registrationProgressing ∷ !Bool
    -- ^ Withdrawn by a stalled or failed step; restored by independent
    -- evidence.
  }

-- | The component the retirement boundary's own diagnostic is written under.
retirementComponent ∷ Component
retirementComponent = unsafeComponent "glfw.retirement"

-- | The operation a failed retirement step is attributed to.
retirementOperation ∷ Operation
retirementOperation = operation "retire window attachment"

-- | The most failures retained beside the first before later ones are only
-- counted.
retainedFailureLimit ∷ Int
retainedFailureLimit = 8

-- | A window limit the retirement state could not be built from. Unreachable
-- for a host whose configuration 'Hetoimasia.Runtime.GLFW.validateHostConfig'
-- accepted, which already refuses a limit below one; a typed rejection rather
-- than a partial function keeps it that way if the two ever drift apart.
newtype RetirementStateRejected = WindowLimitUnusable Int
  deriving (Eq, Show)

instance Exception RetirementStateRejected

-- | Make the retirement state for one host: an identity only this lifetime
-- issues, an empty model over the session issuing the host's windows, and a
-- completion inbox bounded by the same window limit.
newHostRetirement ∷ HasCallStack ⇒ Unique → Int → IO HostRetirement
newHostRetirement session limit = do
  identity ← hostIdentity <$> newUnique
  (authority, model) ← either rejected pure (newAttachmentModel identity session limit)
  -- One pending notice per fact per window the host may hold: enough that an
  -- integration can publish every obligation it has ended without being
  -- refused, and still bounded by the configuration. The product cannot
  -- overflow, because 'Hetoimasia.Runtime.GLFW.validateHostConfig' refuses a
  -- window limit above 'Hetoimasia.Runtime.GLFW.maximumWindowLimit', which is
  -- chosen so that this many notices is far below 'maxBound'.
  inbox ← atomically (newCompletionInbox (limit * length allRetirementFacts)) >>= either rejected pure
  HostRetirement identity authority
    <$> newTVarIO model
    <*> pure inbox
    <*> newTVarIO True
    <*> newTVarIO True
    <*> newTVarIO []
    <*> newIORef False
  where
    rejected ∷ Show rejection ⇒ rejection → IO a
    rejected _ = throwFailure retirementComponent retirementOperation [] (WindowLimitUnusable limit)

-- | The host identity this lifetime issued. Only an attachment naming it can
-- target this host.
retirementIdentity ∷ HostRetirement → HostIdentity
retirementIdentity = retirementHostIdentity

-- | The owner's authority over the model. It never leaves this sublibrary.
retirementAuthority ∷ HostRetirement → OwnerAuthority
retirementAuthority = retirementOwner

-- ---------------------------------------------------------------------------
-- Admission and window records

-- | Close attachment admission and end new graphics use, in the calling
-- transaction.
--
-- It refuses every later attachment and begins the retirement of every
-- attachment still registering or active, so nothing can start a new use after
-- it commits. It is finite, never retries, and is idempotent: the application's
-- quiescence transaction runs it before the worker drain, and the protected
-- host runs it again on every exit, including when the application never
-- installed a quiescence hook or omitted the host from one. It makes no native
-- call and waits for nothing.
closeAttachmentAdmission ∷ HostRetirement → STM ()
closeAttachmentAdmission retirement = do
  writeTVar (retirementAdmitting retirement) False
  registrations ← readTVar (retirementRegistrations retirement)
  mapM_ (endNewUse retirement) registrations

endNewUse ∷ HostRetirement → Registration → STM ()
endNewUse retirement registration =
  transition
    retirement
    ( \authority →
        fmap snd
          . beginRetirement
            authority
            (registrationTarget registration)
            (registrationAcknowledgement registration)
            Detach
    )

-- | Whether a new attachment may still be reserved.
attachmentAdmissionOpen ∷ HostRetirement → STM Bool
attachmentAdmissionOpen = readTVar . retirementAdmitting

-- | Record a window the host has just registered, in the transaction that
-- registered it. A refusal leaves the model unchanged; the host's own
-- bookkeeping stays authoritative for a window no attachment can name.
recordRegisteredWindow ∷ HostRetirement → WindowId → STM ()
recordRegisteredWindow retirement window =
  transition retirement (\authority → fmap snd . registerWindow authority window)

-- | Record that a window's close protocol has begun, in the transaction that
-- began it: its attachment, if it has one, stops admitting new graphics use.
recordClosingWindow ∷ HostRetirement → WindowId → STM ()
recordClosingWindow retirement window =
  transition retirement (\authority → fmap snd . markWindowClosing authority window)

-- | Forget an ended window's record, once nothing attaches to it.
forgetRetiredWindow ∷ HostRetirement → WindowId → STM ()
forgetRetiredWindow retirement window =
  transition retirement (\authority → fmap snd . forgetWindow authority window)

-- | Whether an attachment still vetoes a window's native destruction.
--
-- A window of another session, and one the model never held, veto nothing: the
-- host's own close protocol and its ordinary CPU borrows still decide.
windowRetirementVeto ∷ HostRetirement → WindowId → STM Bool
windowRetirementVeto retirement window = do
  model ← readTVar (retirementState retirement)
  pure $ case windowVeto window model of
    Right (VetoedByAttachment{}) → True
    _ → False

transition
  ∷ HostRetirement
  → (OwnerAuthority → AttachmentModel Evidence → Either AttachmentRefusal (AttachmentModel Evidence))
  → STM ()
transition retirement step = do
  model ← readTVar (retirementState retirement)
  case step (retirementOwner retirement) model of
    Left _ → pure ()
    Right next → writeTVar (retirementState retirement) next

-- ---------------------------------------------------------------------------
-- The private attachment seam

-- | What one bounded owner-thread opportunity did.
data RetirementProgress
  = RetirementAdvanced
    -- ^ The step made finite progress. It may have certified a fact; the model
    -- alone decides whether the attachment is now retired.
  | RetirementAwaiting
    -- ^ No progress this round, and progress may still become possible: the
    -- step keeps its path and is offered another opportunity. It names no
    -- instant, so a running loop learns nothing about when to come back and
    -- offers the next opportunity on its own pace.
  | RetirementAwaitingUntil !Instant
    -- ^ 'RetirementAwaiting' with the absolute instant at which progress may
    -- next be possible, in the host's own 'Hetoimasia.Runtime.GLFW.hostClock'
    -- domain. A running scheduled loop folds it into the turn it waits for, so
    -- a due retirement step is not delayed by the idle wait; the exit drain,
    -- which has its own finite bound and its own wake, treats it exactly as
    -- 'RetirementAwaiting'.
  | RetirementStalled
    -- ^ No safe progress path exists. The step withdraws its path; the
    -- attachment, its window, the session, and every parent are retained, and
    -- only independent evidence revives it.
  deriving (Eq, Show)

-- | What an integration declares about the steps it will be offered.
--
-- The boundary cannot inspect arbitrary backend @IO@ to prove it returns, so
-- finite, nonblocking progress is the trusted backend's own contract. What this
-- declaration adds is the one case the boundary /can/ refuse: an owner that says
-- its step would block. Budgets bound how many opportunities a turn offers, and
-- neither this nor a budget is a wall-clock guarantee about a native call.
data CompletionPolicy
  = FiniteCompletion
    -- ^ Every step returns finitely without waiting on a GPU, a worker, or a
    -- native event pump.
  | BlockingCompletion
    -- ^ The owner declares that its step would block. Every opportunity is
    -- refused before the step runs, the path is withdrawn, and the refusal is
    -- reported; the attachment keeps its window until independent evidence
    -- retires it.
  deriving (Eq, Show)

-- | The trusted, narrow protocol an integration supplies when it attaches.
--
-- Every callback runs on the owner thread, outside every transaction, native
-- callback, and release. None may wait on a worker, pump native events, or make
-- a GPU call: 'protocolStep' is one bounded opportunity that must return
-- finitely.
data AttachmentProtocol = AttachmentProtocol
  { protocolConstruct ∷ AttachmentId → Acknowledgement → IO ()
    -- ^ Build the dependents. It runs after the reservation and after this
    -- protocol's own registration, so a cancellation during it leaves nothing
    -- outside registration. Its failure is kept with the rollback's outcome.
  , protocolRollback ∷ IO RollbackOutcome
    -- ^ The owned rollback a failed construction runs. Only 'RollbackSafe'
    -- retires the attachment; 'RollbackUnsafe' retains it until every fact is
    -- certified separately.
  , protocolStep ∷ AttachmentId → Acknowledgement → IO RetirementProgress
    -- ^ One bounded retirement opportunity.
  , protocolCompletion ∷ CompletionPolicy
    -- ^ What the integration declares about those steps. A 'BlockingCompletion'
    -- owner is refused every opportunity without its step being run.
  , protocolDisposition ∷ Disposition
    -- ^ Whether a recognized failed step leaves this component unavailable or
    -- fails the application. Neither authorizes destroying an unsafe dependent.
  , protocolRecognizes ∷ AttemptFailure → IO Bool
    -- ^ Whether a failed step is one this integration recognizes. An
    -- unrecognized failure is fatal whatever the disposition says, as are a
    -- cancellation and a failure that retained cleanup evidence.
  }

-- | How a request to attach was answered.
data AttachmentOutcome
  = AttachmentEstablished !ActiveAttachment !Acknowledgement
    -- ^ Construction and registration completed and the capability was
    -- published.
  | AttachmentSuperseded !AttachmentId !Acknowledgement
    -- ^ Construction completed after retirement had begun. The dependents stay
    -- registered for retirement; nothing usable was published.
  | AttachmentRolledBack !RolledBack
    -- ^ Construction failed and its owned rollback settled.
  | AttachmentRefused !AttachmentRefusal
    -- ^ The model refused the reservation, before any acquisition.
  | AttachmentAdmissionClosed
    -- ^ Attachment admission has closed; nothing was reserved.
  | AttachmentHostUnprotected
    -- ^ The host owns no retirement state, so it was issued no identity an
    -- attachment could name. Answered before any effect.
  deriving (Show)

-- | What a failed construction's owned rollback settled.
--
-- A safe rollback retires the attachment, which removes it and the evidence
-- with it, so the original failure is handed back here rather than left only in
-- a model entry that no longer exists. The integration that attached owns it
-- from this point: this boundary raises it for nobody, exactly as it raises no
-- construction failure.
data RolledBack = RolledBack
  { rolledBackAttachment ∷ !AttachmentId
  , rolledBackOutcome ∷ !RollbackOutcome
    -- ^ 'RollbackUnsafe' whenever the rollback itself failed or was cancelled:
    -- a rollback that did not complete established no safety.
  , rolledBackFailure ∷ !Evidence
    -- ^ The construction's original failure, never replaced.
  , rolledBackRollback ∷ !(Maybe Evidence)
    -- ^ The rollback's own failure, retained beside it.
  }

instance Show RolledBack where
  showsPrec precedence settled =
    showParen (precedence > 10) $
      showString "RolledBack "
        . showsPrec 11 (rolledBackAttachment settled)
        . showChar ' '
        . showsPrec 11 (rolledBackOutcome settled)
        . showString " (construction: "
        . showString (displayException (rolledBackFailure settled))
        . showString ")"
        . maybe id (\failed → showString " (rollback: " . showString (displayException failed) . showString ")") (rolledBackRollback settled)

-- | Reserve a window, register the protocol, construct, and publish — in that
-- order and no other.
--
-- The reservation and the protocol's registration commit together under the
-- caller's mask, before construction begins, so a cancellation at any handoff
-- leaves the attachment registered and retiring rather than a constructed
-- dependent outside registration. Nothing usable is published until
-- construction and registration have both completed.
--
-- A refusal answers before any acquisition. A construction failure runs the
-- owned rollback, keeps the original failure with the rollback's outcome as the
-- attachment's evidence, and answers 'AttachmentRolledBack'; a cancellation is
-- counted against the attachment and then re-raised.
attachRetirement
  ∷ HasCallStack
  ⇒ HostRetirement
  → (∀ a. IO a → IO a)
  → WindowId
  → AttachmentProtocol
  → IO AttachmentOutcome
attachRetirement retirement restore window protocol = do
  reserved ← atomically reserve
  case reserved of
    Left refusal → pure refusal
    Right registered → do
      let target = registeredAttachment registered
          acknowledgement = registeredAcknowledgement registered
      -- Forced inside the boundary that catches it: a callback may return a
      -- value that raises when it is demanded, and demanding it afterwards
      -- would leave the reservation pending with nothing able to settle it.
      tryWithContext (restore (protocolConstruct protocol target acknowledgement >>= evaluate)) >>= \case
        Right () → settleConstructed retirement target acknowledgement
        Left caught → settleFailed retirement restore protocol target acknowledgement caught
  where
    reserve = do
      open ← readTVar (retirementAdmitting retirement)
      if not open
        then pure (Left AttachmentAdmissionClosed)
        else do
          model ← readTVar (retirementState retirement)
          case attachWindow (retirementOwner retirement) (retirementHostIdentity retirement) window model of
            Left refusal → pure (Left (AttachmentRefused refusal))
            Right (registered, next) → do
              writeTVar (retirementState retirement) next
              -- Registered before construction begins: whatever a construction
              -- leaves behind is already this attachment's to retire.
              addRegistration
                retirement
                ( Registration
                    (registeredAttachment registered)
                    (registeredAcknowledgement registered)
                    protocol
                    True
                )
              pure (Right registered)

settleConstructed ∷ HostRetirement → AttachmentId → Acknowledgement → IO AttachmentOutcome
settleConstructed retirement target acknowledgement = atomically $ do
  model ← readTVar (retirementState retirement)
  case constructionSucceeded (retirementOwner retirement) target acknowledgement model of
    Left refusal → pure (AttachmentRefused refusal)
    Right (answer, next) → do
      writeTVar (retirementState retirement) next
      pure $ case answer of
        CapabilityPublished active → AttachmentEstablished active acknowledgement
        PublicationSuperseded → AttachmentSuperseded target acknowledgement

settleFailed
  ∷ HostRetirement
  → (∀ a. IO a → IO a)
  → AttachmentProtocol
  → AttachmentId
  → Acknowledgement
  → Evidence
  → IO AttachmentOutcome
settleFailed retirement restore protocol target acknowledgement caught@(ExceptionWithContext _ failure) = do
  when cancelled (atomically (countCancellation retirement target acknowledgement))
  -- The rollback is trusted but not infallible, and construction must leave
  -- pending whatever it does: a rollback that raised or was cancelled
  -- established no safety, so the attachment is retained owing every fact
  -- rather than left pending, where no fact could ever be recorded and the
  -- drain could never finish.
  attempted ← tryWithContext (restore (protocolRollback protocol >>= evaluate))
  let outcome = either (const RollbackUnsafe) id attempted
      rolledBack = either Just (const Nothing) attempted
  atomically $ do
    model ← readTVar (retirementState retirement)
    case constructionFailed (retirementOwner retirement) target acknowledgement caught outcome model of
      Left _ → pure ()
      Right (_, next) → writeTVar (retirementState retirement) next
    -- Retained beside the construction failure the model already keeps first,
    -- for a retained attachment. A safe rollback removed the entry, and the
    -- answer below carries both failures instead.
    mapM_ (recordFailure retirement target acknowledgement) rolledBack
    pruneRegistrations retirement
  let settled = RolledBack target outcome caught rolledBack
  case (cancelled, rolledBack) of
    -- The construction's own cancellation stays primary; a rollback failure of
    -- any kind is retained beside it.
    (True, Nothing) → rethrowIO caught
    (True, Just failed) → raiseRetaining failed caught
    -- A cancellation the rollback received is still this thread's to answer,
    -- and is never traded for a synchronous construction failure, which is
    -- retained beside it instead.
    (False, Just failed)
      | isCancellation (exceptionOf failed) → raiseRetaining caught failed
    (False, _) → pure (AttachmentRolledBack settled)
  where
    cancelled = isCancellation failure

-- | Raise the primary failure with another retained beside it as this
-- boundary's own cleanup evidence.
raiseRetaining ∷ Evidence → Evidence → IO a
raiseRetaining retained primary =
  withResourceLabelled rollbackLabel (pure ()) (\() → rethrowIO retained) (\() → rethrowIO primary)

-- | The cleanup label a failed rollback is retained under.
rollbackLabel ∷ Text
rollbackLabel = "glfw attachment rollback"

-- | The attachments the model still holds, in registration order.
pendingAttachments ∷ HostRetirement → STM [AttachmentId]
pendingAttachments retirement = map registrationTarget <$> livePending retirement

livePending ∷ HostRetirement → STM [Registration]
livePending retirement = do
  model ← readTVar (retirementState retirement)
  registrations ← readTVar (retirementRegistrations retirement)
  pure (filter (live model . registrationTarget) registrations)

live ∷ AttachmentModel Evidence → AttachmentId → Bool
live model target = case attachmentStatus target model of
  Right (AttachmentLive _) → True
  _ → False

-- | The registrations of attachments that have actually begun retiring.
--
-- A running host holds active attachments too, and an active one owes nothing
-- yet: the model refuses every retirement fact before retirement has begun, so
-- offering it an opportunity would spend a step that could establish nothing and
-- could only end by withdrawing a path the window's own close still needs. The
-- exit drain has no such distinction to make, because closing admission has
-- already begun the retirement of every attachment it holds.
retiringPending ∷ HostRetirement → STM [Registration]
retiringPending retirement = do
  model ← readTVar (retirementState retirement)
  registrations ← readTVar (retirementRegistrations retirement)
  pure (filter (retiringIn model . registrationTarget) registrations)

retiringIn ∷ AttachmentModel Evidence → AttachmentId → Bool
retiringIn model target = case attachmentStatus target model of
  Right (AttachmentLive view) → viewPhase view == AttachmentRetiring
  _ → False

-- | Certify one retirement fact on the owner thread, revalidating the target
-- and its acknowledgement exactly as a folded notice is.
--
-- The last missing fact retires the attachment and frees its window; nothing
-- else does.
certifyRetirementFact
  ∷ HostRetirement
  → AttachmentId
  → Acknowledgement
  → RetirementFact
  → STM (Either AttachmentRefusal FactAnswer)
certifyRetirementFact retirement target acknowledgement fact = do
  model ← readTVar (retirementState retirement)
  case recordRetirementFact (retirementOwner retirement) target acknowledgement fact model of
    Left refusal → pure (Left refusal)
    Right (answer, next) → do
      writeTVar (retirementState retirement) next
      pruneRegistrations retirement
      pure (Right answer)

-- | One attachment's view: its phase, construction state, recorded and missing
-- facts, and its evidence. 'Nothing' once it has retired.
attachmentViewOf ∷ HostRetirement → AttachmentId → STM (Maybe (AttachmentView Evidence))
attachmentViewOf retirement target = do
  model ← readTVar (retirementState retirement)
  pure $ case attachmentStatus target model of
    Right (AttachmentLive view) → Just view
    _ → Nothing

-- | What a window's one exclusive slot holds now: the attachment occupying it,
-- its phase, and the retirement facts it still owes.
--
-- 'Nothing' means the slot is free — either the model holds no record for the
-- window, or it holds one with no attachment. It needs no authority and any
-- thread may read it.
windowAttachmentState
  ∷ HostRetirement → WindowId → STM (Maybe (AttachmentId, AttachmentPhase, [RetirementFact]))
windowAttachmentState retirement window = do
  model ← readTVar (retirementState retirement)
  pure $ case windowVeto window model of
    Right (VetoedByAttachment target phase missing) → Just (target, phase, missing)
    _ → Nothing

-- ---------------------------------------------------------------------------
-- Detaching

-- | How a request to detach a window's current owner was answered.
data DetachAnswer
  = DetachBegun
    -- ^ Retirement began now. The slot frees only once every fact is recorded.
  | DetachAlreadyRetiring
    -- ^ The attachment was already retiring — through a close, an earlier
    -- detach, or quiescence. Nothing changed.
  | DetachAbsent
    -- ^ No attachment of this incarnation holds the window: it has already
    -- retired, or the slot was taken by a later one. Nothing changed and
    -- nothing was released.
  deriving (Eq, Show)

-- | Ask one attachment to retire while its window stays open, on the owner
-- thread.
--
-- It begins exactly the retirement a close begins — the same facts, the same
-- protocol, the same owner turns — and it frees the exclusive slot only once
-- the model records every fact. The acknowledgement comes from the registration
-- the boundary already holds, so a caller needs no completion authority of its
-- own to ask.
detachAttachment ∷ HostRetirement → AttachmentId → STM DetachAnswer
detachAttachment retirement target = do
  registrations ← readTVar (retirementRegistrations retirement)
  case find ((== target) . registrationTarget) registrations of
    Nothing → pure DetachAbsent
    Just registration → do
      model ← readTVar (retirementState retirement)
      case beginRetirement
        (retirementOwner retirement)
        target
        (registrationAcknowledgement registration)
        Detach
        model of
        Left _ → pure DetachAbsent
        Right (answer, next) → do
          writeTVar (retirementState retirement) next
          pure $ case answer of
            RetirementBegun → DetachBegun
            RetirementAlreadyBegun → DetachAlreadyRetiring
            RetirementAlreadyComplete → DetachAbsent

-- ---------------------------------------------------------------------------
-- In-run progress

-- | What one running turn's bounded round of opportunities found.
--
-- It is the retirement side of the scheduling arc: 'roundAdvanced' says another
-- opportunity is wanted now, and 'roundNextPossible' is the earliest instant any
-- awaiting owner named, which a scheduled loop folds into the wait it chooses so
-- a due step is not delayed by the idle bound.
data ProgressRound = ProgressRound
  { roundOffered ∷ !Int
    -- ^ Opportunities offered, at most the budget.
  , roundAdvanced ∷ !Int
    -- ^ Of those, the ones that made finite progress.
  , roundPending ∷ !Int
    -- ^ Attachments still registered and not yet retired, after the round.
  , roundDeferred ∷ !Int
    -- ^ Pending attachments the budget could not reach this round, which is
    -- itself a reason to come back at once.
  , roundStalled ∷ !Int
    -- ^ Pending attachments with no progress path left.
  , roundRefused ∷ !Int
    -- ^ Opportunities refused because their owner declared a blocking step.
  , roundNextPossible ∷ !(Maybe Instant)
    -- ^ The earliest instant an awaiting owner named, if any did.
  }
  deriving (Eq, Show)

noProgressRound ∷ ProgressRound
noProgressRound = ProgressRound 0 0 0 0 0 0 Nothing

-- | Offer one bounded, rotating round of retirement opportunities on the owner
-- thread, for a host that is still running.
--
-- It folds whatever other threads published, then gives at most @budget@ pending
-- attachments one opportunity each, starting after the attachment the previous
-- round served last, so one window's pending retirement can never starve
-- another's and never blocks that window's commands, close, or attachment. Each
-- opportunity either advances finitely, names when progress may next be
-- possible, keeps its path without naming one, withdraws it, or is refused
-- outright for declaring that it would block.
--
-- A recognized failure under an optional disposition leaves the component
-- unavailable with its evidence, which is never permission to destroy a
-- dependent. Any other failure, and a cancellation, is recorded as the
-- attachment's evidence and re-raised after its path has been withdrawn: the
-- step is never replayed, and ending the loop hands the rest to the protected
-- boundary's own drain.
advanceRetirements
  ∷ HostRetirement → IORef (Maybe AttachmentId) → Int → IO ProgressRound
advanceRetirements retirement cursor budget = do
  void (foldNotices retirement)
  pending ← atomically (retiringPending retirement)
  served ← readIORef cursor
  let ordered = rotateAfter served pending
      offered = take (max 0 budget) (filter registrationProgressing ordered)
  round' ← foldStep noProgressRound offered
  writeIORef cursor (registrationTarget <$> lastOf offered)
  settled ← atomically (retiringPending retirement)
  pure
    round'
      { roundPending = length settled
      , roundStalled = length (filter (not . registrationProgressing) settled)
      , roundDeferred = max 0 (length (filter registrationProgressing settled) - roundOffered round')
      }
  where
    foldStep accumulated [] = pure accumulated
    foldStep accumulated (registration : rest) = do
      next ← offerOne retirement accumulated registration
      foldStep next rest
    lastOf [] = Nothing
    lastOf entries = Just (last entries)

-- | The pending attachments, starting after the one served last. An identity
-- the list no longer holds leaves the order as it is, so a retired attachment
-- never skips the ones registered after it.
rotateAfter ∷ Maybe AttachmentId → [Registration] → [Registration]
rotateAfter Nothing pending = pending
rotateAfter (Just served) pending = case break ((== served) . registrationTarget) pending of
  (_, []) → pending
  (before, at' : after) → after <> before <> [at']

offerOne ∷ HostRetirement → ProgressRound → Registration → IO ProgressRound
offerOne retirement accumulated registration
  | protocolCompletion protocol == BlockingCompletion = do
      withdraw
      pure counted {roundRefused = roundRefused counted + 1}
  | otherwise = do
      attempted ←
        tryWithContext . recover retirementOperation (stepPolicy protocol) $
          protocolStep protocol target acknowledgement >>= evaluate
      case attempted of
        Right (Available recovered) → settle (recoveredValue recovered)
        Right (Unavailable unavailability) → do
          atomically
            (recordFailure retirement target acknowledgement (attemptException (unavailableReason unavailability)))
          withdraw
          pure counted
        Left caught → do
          atomically (recordFailure retirement target acknowledgement caught)
          withdraw
          rethrowIO caught
  where
    counted = accumulated {roundOffered = roundOffered accumulated + 1}
    target = registrationTarget registration
    acknowledgement = registrationAcknowledgement registration
    protocol = registrationProtocol registration
    withdraw = atomically (writeProgressing retirement target False)
    settle = \case
      RetirementAdvanced → do
        atomically (pruneRegistrations retirement)
        pure counted {roundAdvanced = roundAdvanced counted + 1}
      RetirementAwaiting → pure counted
      RetirementAwaitingUntil due →
        pure counted {roundNextPossible = Just (maybe due (min due) (roundNextPossible counted))}
      RetirementStalled → withdraw >> pure counted

-- | The one recovery policy a retirement step is attempted under, on the owner
-- turn and in the drain alike: one attempt, never replayed, classified by the
-- integration's own recognition.
stepPolicy ∷ AttachmentProtocol → RecoveryPolicy a
stepPolicy protocol =
  RecoveryPolicy
    { policyDisposition = protocolDisposition protocol
    , policyBudget = 1
    , policyClassifier = \failure → recognized <$> protocolRecognizes protocol failure
    , policyWait = \_ → pure ()
    }
  where
    recognized accepted = if accepted then Just Retry else Nothing

-- ---------------------------------------------------------------------------
-- Completion notices from other threads

-- | The capability a thread that is not the owner publishes a certified fact
-- through. It holds no authority over the model and no native handle: an
-- admitted notice is revalidated on the owner thread exactly as an owner-thread
-- report is.
data CompletionPublisher = CompletionPublisher !(TVar Bool) !CompletionInbox !Notifier

completionPublisher ∷ HostRetirement → Notifier → CompletionPublisher
completionPublisher retirement =
  CompletionPublisher (retirementPublishing retirement) (retirementInbox retirement)

-- | What one offered notice did.
data CompletionPublication
  = CompletionOffered !NoticeAdmission
  | CompletionClosed
    -- ^ The boundary has already found retirement complete, so nothing further
    -- may be published: a later notice could register a notification obligation
    -- the one degradation report has already passed.
  deriving (Eq, Show)

-- | Offer one notice and wake the owner, from any thread.
--
-- The offer never waits. An admitted notice registers its notification
-- obligation in the same transaction that admitted it, and that obligation is
-- discharged by exactly one wake call, so a notice published while the owner is
-- inside its finite retirement wait ends that wait, and a wake that finds the
-- session terminal enters GLFW not at all. A coalesced, rejected, or closed
-- notice registers nothing and wakes nobody.
--
-- Admission is decided in the same transaction as the offer, and the drain
-- closes it in the same transaction that finds nothing pending, so a notice is
-- either folded by the drain or refused outright — never accepted after the
-- boundary has stopped looking.
publishCompletion ∷ CompletionPublisher → CompletionNotice → IO CompletionPublication
publishCompletion (CompletionPublisher publishing inbox notifier) notice = mask_ $ do
  published ← atomically $ do
    open ← readTVar publishing
    if not open
      then pure CompletionClosed
      else do
        admission ← offerCompletion inbox notice
        when (admission == NoticeAdmitted) (registerNotification notifier)
        pure (CompletionOffered admission)
  when (published == CompletionOffered NoticeAdmitted) (void (dischargeNotification notifier))
  pure published

-- ---------------------------------------------------------------------------
-- The drain

-- | What the protected host lends the drain.
data RetirementEnvironment = RetirementEnvironment
  { environmentLogger ∷ Logger
    -- ^ The application's injected logger, for the one stall diagnostic.
  , environmentPoll ∷ IO ()
    -- ^ Process the native events pending, without waiting.
  , environmentAwait ∷ IO ()
    -- ^ Wait the host's configured finite bound for a native event, then
    -- process what is pending. The session's internal wake ends it early.
  , environmentRetireWindows ∷ IO ()
    -- ^ Retry the retirement of every window whose close protocol has begun.
    -- A window whose own attachment has just become safe is destroyed here,
    -- while another chain's window, the shared session, and every borrowed
    -- parent stay live; the final unwind still waits for every dependent.
  , environmentBound ∷ Double
    -- ^ That bound, in seconds, for the stall diagnostic to name and for the
    -- fallback timer to use.
  }

-- | What one drain accumulated. It never throws: the protected boundary
-- settles this against the body's own outcome.
data DrainOutcome = DrainOutcome
  { drainPrimary ∷ !(Maybe Evidence)
    -- ^ The first synchronous failure the drain raised, which becomes primary
    -- only if the body succeeded.
  , drainRetained ∷ ![Evidence]
    -- ^ Later failures, oldest first, bounded by 'retainedFailureLimit'.
  , drainElided ∷ !Natural
    -- ^ Failures beyond that bound, counted rather than kept.
  , drainDeferred ∷ !(Maybe Evidence)
    -- ^ The first cancellation delivered during the drain, re-raised only once
    -- retirement is safe and never in place of a recorded outcome. Every
    -- cancellation is also counted against each pending attachment as the
    -- model's own evidence, so repeated cancellation is retained there.
  }

noDrainOutcome ∷ DrainOutcome
noDrainOutcome = DrainOutcome Nothing [] 0 Nothing

-- | Retire every attachment the host still holds, on the owner thread.
--
-- It returns only when no registered attachment is pending, which is the only
-- thing that makes releasing the host's windows, its session, and its parents
-- safe. It raises nothing: every failure and every cancellation is accumulated
-- and handed back.
drainRetirement ∷ HasCallStack ⇒ HostRetirement → RetirementEnvironment → (∀ a. IO a → IO a) → IO DrainOutcome
drainRetirement retirement environment restore = go True noDrainOutcome
  where
    go pumping outcome = do
      revived ← foldNotices retirement
      sealed ← atomically (sealIfFinished retirement)
      pending ← atomically (livePending retirement)
      if sealed
        then pure outcome
        else do
          (advanced, stepped) ← opportunities retirement restore pending outcome
          let progressed = revived || advanced
          -- Every round, not only one that made progress: a chain that became
          -- safe before the drain began, and whose destruction a borrow then
          -- deferred, must not stay tied to a chain that only awaits or stalls.
          -- The retry itself replays no failed disposal: a window whose
          -- retirement failed is forgotten rather than attempted again.
          settled ←
            tryWithContext (restore (environmentRetireWindows environment >>= evaluate))
              >>= \attempted → absorb retirement attempted stepped
          -- Every round, whether or not another chain progressed: a chain with
          -- no path left is retaining its window, the session, and its parents
          -- now, and one beside it that is merely awaiting must not be able to
          -- keep that from ever being said.
          diagnosed ← declareStall retirement environment restore settled
          (pumping', waited) ← waitRound retirement environment restore pumping progressed diagnosed
          go pumping' waited

-- | Find whether retirement is over, and close publication in the same
-- transaction if it is.
--
-- Whatever a publisher committed before this transaction is folded here; a
-- publisher that commits after it is refused. Nothing in between can leave a
-- notice unfolded or an obligation the one degradation report would miss.
sealIfFinished ∷ HostRetirement → STM Bool
sealIfFinished retirement = do
  pending ← livePending retirement
  if not (null pending)
    then pure False
    else do
      _ ← fold retirement
      remaining ← livePending retirement
      if null remaining
        then True <$ writeTVar (retirementPublishing retirement) False
        else pure False

-- | Take every pending notice and fold it, revalidating each exactly as an
-- owner-thread report is.
--
-- Only a notice that actually recorded new evidence counts as progress and
-- revives a withdrawn path: a refusal, and a duplicate fact the model already
-- holds, establish nothing, so neither may make a failed disposal run again.
foldNotices ∷ HostRetirement → IO Bool
foldNotices = atomically . fold

fold ∷ HostRetirement → STM Bool
fold retirement = do
  notices ← takeCompletions (retirementInbox retirement)
  if null notices
    then pure False
    else do
      model ← readTVar (retirementState retirement)
      let (answers, next) = foldCompletions (retirementOwner retirement) notices model
          recorded = [notice | (notice, Right answer) ← answers, established answer]
      writeTVar (retirementState retirement) next
      mapM_ (reviveRegistration retirement . noticeTarget) recorded
      pruneRegistrations retirement
      pure (not (null recorded))

-- | Whether one folded notice established evidence the model did not already
-- hold.
established ∷ FactAnswer → Bool
established = \case
  FactRecorded _ → True
  AttachmentNowRetired → True
  FactAlreadyRecorded → False
  AttachmentAlreadyRetired → False

-- | Give each pending attachment that still has a progress path one bounded
-- opportunity, in registration order.
opportunities
  ∷ HostRetirement
  → (∀ a. IO a → IO a)
  → [Registration]
  → DrainOutcome
  → IO (Bool, DrainOutcome)
opportunities retirement restore pending outcome0 =
  foldStep (False, outcome0) (filter registrationProgressing pending)
  where
    foldStep accumulated [] = pure accumulated
    foldStep (advanced, outcome) (registration : rest) = do
      (progressed, next) ← opportunity retirement restore registration outcome
      foldStep (advanced || progressed, next) rest

opportunity
  ∷ HostRetirement
  → (∀ a. IO a → IO a)
  → Registration
  → DrainOutcome
  → IO (Bool, DrainOutcome)
opportunity retirement restore registration outcome
  -- Refused before the step runs, exactly as a running turn refuses it: an
  -- owner that declares its step would block is never given the opportunity,
  -- and the stall policy then retains its window, the session, and every parent
  -- until independent evidence arrives.
  | protocolCompletion protocol == BlockingCompletion = withdraw >> pure (False, outcome)
  | otherwise =
      tryWithContext (restore (recover retirementOperation (stepPolicy protocol) step)) >>= settleAttempt
  where
    step = protocolStep protocol target (registrationAcknowledgement registration)
    settleAttempt = \case
      Right (Available recovered) → settleProgress (recoveredValue recovered)
      -- A recognized failure under an optional disposition: the component is
      -- unavailable, which is never permission to destroy its dependent. Its
      -- evidence is kept exactly as a fatal step's is.
      Right (Unavailable unavailability) → do
        atomically
          ( recordFailure
              retirement
              target
              (registrationAcknowledgement registration)
              (attemptException (unavailableReason unavailability))
          )
        withdraw
        pure (False, outcome)
      Left caught@(ExceptionWithContext _ failure)
        -- Withdrawn as a failed step is: an interrupted step may have disposed
        -- part of what it owns, and nothing here knows whether running it again
        -- would be safe. Independent evidence revives it.
        | isCancellation failure → withdraw >> ((,) False <$> absorb retirement (Left caught) outcome)
        | otherwise → do
            -- Evidence, never a fact: the step is withdrawn rather than
            -- replayed, and the attachment is not safe.
            atomically (recordFailure retirement target (registrationAcknowledgement registration) caught)
            withdraw
            pure (False, retainFailure caught outcome)
    target = registrationTarget registration
    protocol = registrationProtocol registration
    withdraw = atomically (writeProgressing retirement target False)
    settleProgress = \case
      RetirementAdvanced → atomically (pruneRegistrations retirement) >> pure (True, outcome)
      RetirementAwaiting → pure (False, outcome)
      -- The drain has its own finite bound and its own wake, so an instant is
      -- nothing it waits for: it is the running loop's to schedule against.
      RetirementAwaitingUntil _ → pure (False, outcome)
      RetirementStalled → withdraw >> pure (False, outcome)

-- | The one protected diagnostic the stall policy owes, claimed once whatever
-- it records.
--
-- It is owed as soon as any live attachment has no progress path left, not only
-- when every one of them has: that chain is retaining its window, the session,
-- and its parents from this round on, and a chain beside it that is merely
-- awaiting must not be able to keep that from ever being reported. The entry
-- names how many of the attachments still pending are stalled.
--
-- Its own failure is retained rather than raised: a failing diagnostic may not
-- unwind the scopes the stall is retaining. No retirement timeout is configured
-- in this slice; were one added it could only annotate this entry, never grant
-- authority to destroy anything.
declareStall
  ∷ HasCallStack
  ⇒ HostRetirement
  → RetirementEnvironment
  → (∀ a. IO a → IO a)
  → DrainOutcome
  → IO DrainOutcome
declareStall retirement environment restore outcome = do
  pending ← atomically (livePending retirement)
  let stalled = filter (not . registrationProgressing) pending
  claimed ←
    if null stalled
      then pure False
      else atomicModifyIORef' (retirementDiagnosed retirement) (\made → (True, not made))
  if not claimed
    then pure outcome
    else do
      attempted ←
        tryWithContext . restore $
          logWarning
            (environmentLogger environment)
            retirementComponent
            "An attachment has no safe progress path; its window, the session, and every parent are retained"
            [ ("stalled", Text.pack (show (length stalled)))
            , ("attachments", Text.pack (show (length pending)))
            , ("wait", Text.pack (show (environmentBound environment)))
            ]
            -- Forced here, inside the attempt: a sink whose result raises when
            -- demanded may not escape and unwind what the stall is retaining.
            >>= evaluate
      absorb retirement attempted outcome

-- | The round's native step, and the finite wait that ends it.
--
-- A round that made progress polls, so work already available is taken without
-- waiting. A round that made none waits the host's configured bound, which the
-- session's internal wake ends as soon as another thread publishes a notice. A
-- pump that fails withdraws itself — its failure is retained once rather than
-- repeated every round — and the drain then waits on the inbox under a finite
-- timer instead, so completion notices can still finish retirement.
waitRound
  ∷ HostRetirement
  → RetirementEnvironment
  → (∀ a. IO a → IO a)
  → Bool
  → Bool
  → DrainOutcome
  → IO (Bool, DrainOutcome)
waitRound retirement environment restore pumping progressed outcome
  | not pumping = (,) False <$> timedRound
  | otherwise = do
      attempted ←
        tryWithContext . restore $
          (if progressed then environmentPoll environment else environmentAwait environment) >>= evaluate
      (,) (keepsPumping attempted) <$> absorb retirement attempted outcome
  where
    -- A synchronous native failure withdraws the pump; a cancellation does not.
    keepsPumping = \case
      Right () → True
      Left caught → isCancellation (exceptionOf caught)
    timedRound = do
      expired ← registerDelay (max 1 (round (environmentBound environment * 1e6)))
      attempted ← tryWithContext (restore (atomically (readTVar expired >>= \done → unless done retry)))
      absorb retirement attempted outcome

-- ---------------------------------------------------------------------------
-- Accumulating what the drain found

-- | Fold one attempt's outcome into the accumulator.
--
-- A cancellation is deferred, and counted against every attachment still
-- pending as the model's own evidence, so repeated cancellation is retained
-- where the attachment's other evidence already lives. A synchronous failure is
-- kept as the drain's first, or retained after it.
absorb ∷ HostRetirement → Either Evidence () → DrainOutcome → IO DrainOutcome
absorb retirement attempted outcome = case attempted of
  Right () → pure outcome
  Left caught
    | isCancellation (exceptionOf caught) → do
        atomically (countCancellations retirement)
        pure (deferCancellation caught outcome)
    | otherwise → pure (retainFailure caught outcome)

exceptionOf ∷ Evidence → SomeException
exceptionOf (ExceptionWithContext _ failure) = failure

isCancellation ∷ SomeException → Bool
isCancellation failure = isJust (fromException failure ∷ Maybe SomeAsyncException)

retainFailure ∷ Evidence → DrainOutcome → DrainOutcome
retainFailure failure outcome = case drainPrimary outcome of
  Nothing → outcome {drainPrimary = Just failure}
  Just _
    | length (drainRetained outcome) < retainedFailureLimit →
        outcome {drainRetained = drainRetained outcome <> [failure]}
    | otherwise → outcome {drainElided = drainElided outcome + 1}

deferCancellation ∷ Evidence → DrainOutcome → DrainOutcome
deferCancellation cancellation outcome =
  outcome {drainDeferred = Just (fromMaybe cancellation (drainDeferred outcome))}

-- ---------------------------------------------------------------------------
-- Registrations

addRegistration ∷ HostRetirement → Registration → STM ()
addRegistration retirement registration =
  readTVar (retirementRegistrations retirement)
    >>= writeTVar (retirementRegistrations retirement) . (<> [registration])

writeProgressing ∷ HostRetirement → AttachmentId → Bool → STM ()
writeProgressing retirement target progressing =
  readTVar (retirementRegistrations retirement)
    >>= writeTVar (retirementRegistrations retirement) . map adjust
  where
    adjust registration
      | registrationTarget registration == target = registration {registrationProgressing = progressing}
      | otherwise = registration

-- | Independent evidence revives a withdrawn progress path.
reviveRegistration ∷ HostRetirement → AttachmentId → STM ()
reviveRegistration retirement target = writeProgressing retirement target True

-- | Forget the registrations of attachments the model has retired, so the
-- bookkeeping stays bounded by the attachments still live.
pruneRegistrations ∷ HostRetirement → STM ()
pruneRegistrations retirement = do
  model ← readTVar (retirementState retirement)
  readTVar (retirementRegistrations retirement)
    >>= writeTVar (retirementRegistrations retirement) . filter (live model . registrationTarget)

-- ---------------------------------------------------------------------------
-- Model helpers

-- | Count one cancellation against every attachment still pending. It
-- establishes no fact: cancellation is not completion.
countCancellations ∷ HostRetirement → STM ()
countCancellations retirement = livePending retirement >>= mapM_ count
  where
    count registration =
      transition
        retirement
        ( \authority →
            fmap snd
              . beginRetirement
                authority
                (registrationTarget registration)
                (registrationAcknowledgement registration)
                Cancel
        )

countCancellation ∷ HostRetirement → AttachmentId → Acknowledgement → STM ()
countCancellation retirement target acknowledgement =
  transition retirement (\authority → fmap snd . beginRetirement authority target acknowledgement Cancel)

recordFailure ∷ HostRetirement → AttachmentId → Acknowledgement → Evidence → STM ()
recordFailure retirement target acknowledgement failure =
  transition retirement (\authority → fmap snd . recordDisposalFailure authority target acknowledgement failure)
