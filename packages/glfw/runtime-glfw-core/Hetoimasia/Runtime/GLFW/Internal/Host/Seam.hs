-- | The private attachment seam: the raw reservation, fact certification, and
-- read access to a protected host's attachment model, for this package's own
-- examples and for the public contract in
-- "Hetoimasia.Runtime.GLFW.Internal.Host.Attachments".
--
-- The model is the host's retirement state, owned by
-- "Hetoimasia.Runtime.GLFW.Internal.Retirement" and issued only by the
-- protected lifetime. Reservation and certification run on the process main
-- thread, the session's owner, and refuse other threads; the readers answer
-- on any thread, and a completion publisher may be used from any thread. An
-- ordinary host has no model, and every operation here answers accordingly
-- before any effect.
module Hetoimasia.Runtime.GLFW.Internal.Host.Seam
  ( hostAttachmentIdentity
  , attachHostWindow
  , faultHostAttachmentMetadata
  , hostCompletionPublisher
  , hostPendingAttachments
  , hostAttachmentView
  , reportHostRetirementFact
  , attachOperation
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (ExceptionWithContext, SomeException, mask)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation)
import Hetoimasia.GLFW.Internal.Attachment
  ( Acknowledgement
  , AttachmentId
  , AttachmentView
  , FactAnswer (..)
  , HostIdentity
  , RetirementFact
  , acknowledgedAttachment
  , attachmentWindow
  )
import Hetoimasia.GLFW.Internal.Session (ownerOperation)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW.Internal.Host.Progress (releaseEarlierCell, resettleRetirementDemand)
import Hetoimasia.Runtime.GLFW.Internal.Host.State (WindowHost (..), windowIdentifiers)
import Hetoimasia.Runtime.GLFW.Internal.Host.Wake (hostNotifier)
import Hetoimasia.Runtime.GLFW.Internal.Retirement
  ( AttachmentOutcome (..)
  , AttachmentProtocol
  , CompletionPolicy
  , CompletionPublisher
  , attachRetirement
  , attachmentViewOf
  , certifyRetirementFact
  , completionPublisher
  , faultProtocolMetadata
  , pendingAttachments
  , retirementIdentity
  )

attachOperation, certifyOperation ∷ Operation
attachOperation = operation "attach host window"
certifyOperation = operation "certify retirement fact"

-- | The host identity a protected host issued, or 'Nothing' for a host built by
-- 'allocWindowHost', 'allocWindowHostIn', or 'allocWindowHostWith'.
--
-- That absence is the whole of why an ordinary host accepts no attachment:
-- without an identity there is nothing an attachment could name, and
-- 'attachHostWindow' answers 'AttachmentHostUnprotected' before any effect.
hostAttachmentIdentity ∷ WindowHost → Maybe HostIdentity
hostAttachmentIdentity = fmap retirementIdentity . hostRetirementState

-- | Reserve a window of a protected host, construct its dependents, and publish
-- the capability, on the owner thread.
--
-- It is available only here, in the private @runtime-glfw-core@ sublibrary, for
-- this package's own examples: no public module exports it. The public
-- attachment contract is LIFE-4's.
--
-- Refuses other threads with 'Hetoimasia.GLFW.Session.NotSessionOwner', and a
-- host with no retirement state with 'AttachmentHostUnprotected', each before
-- any effect.
attachHostWindow ∷ HasCallStack ⇒ WindowHost → WindowId → AttachmentProtocol → IO AttachmentOutcome
attachHostWindow host target protocol =
  ownerOperation (hostSession host) attachOperation (windowIdentifiers target) $
    case hostRetirementState host of
      Nothing → pure AttachmentHostUnprotected
      Just retirement →
        -- The reservation itself releases the cell of any incarnation this
        -- window's slot has moved past, so no later failure, rollback, or
        -- cancellation can leave the host holding it.
        mask (\restore → attachRetirement retirement restore target protocol (releaseEarlierCell host))

-- | Install an after-acquisition metadata fault on one of a protected host's
-- registrations, for this package's own examples.
--
-- 'attachHostWindow' demands a protocol's declarations before it reserves
-- anything, so a protocol that survived attaching holds evaluated, immutable
-- values that cannot begin raising later. The containment a running owner turn
-- and the protected drain owe a registration they read every round is real all
-- the same, and this is how the examples that assert it reach that state
-- without weakening the preflight they also assert. An unprotected host holds
-- no registration and changes nothing.
--
-- It is available only here, in the private @runtime-glfw-core@ sublibrary: no
-- public module exports it, and nothing in production calls it.
faultHostAttachmentMetadata ∷ WindowHost → AttachmentId → CompletionPolicy → STM ()
faultHostAttachmentMetadata host target completion =
  mapM_ (\retirement → faultProtocolMetadata retirement target completion) (hostRetirementState host)

-- | The capability another thread publishes a certified fact through, or
-- 'Nothing' for an unprotected host. Publishing wakes the owner exactly as a
-- command admission does.
hostCompletionPublisher ∷ WindowHost → Maybe CompletionPublisher
hostCompletionPublisher host =
  (\retirement → completionPublisher retirement (hostNotifier host)) <$> hostRetirementState host

-- | The attachments the host still holds, in registration order. Any thread may
-- read it; it is bounded by the live-window limit.
hostPendingAttachments ∷ WindowHost → STM [AttachmentId]
hostPendingAttachments = maybe (pure []) pendingAttachments . hostRetirementState

-- | One attachment's phase, construction state, recorded and missing facts, and
-- evidence. 'Nothing' once it has retired. Any thread may read it.
hostAttachmentView
  ∷ WindowHost → AttachmentId → STM (Maybe (AttachmentView (ExceptionWithContext SomeException)))
hostAttachmentView host target = maybe (pure Nothing) (`attachmentViewOf` target) (hostRetirementState host)

-- | Certify one retirement fact on the owner thread, for an attachment's own
-- protocol. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
--
-- An unprotected host, and a target this host's model refuses, answer
-- 'Nothing'; the refusal changes nothing.
--
-- A fact the model did not already hold revives that attachment's withdrawn
-- progress path, so the next owner turn or drain round offers it one bounded
-- opportunity. That is the same rule a notice published through
-- 'hostCompletionPublisher' obeys once it is folded: the evidence decides, not
-- the transport. A duplicate fact and a refusal establish nothing and revive
-- nothing.
--
-- Evidence recorded here also resettles the published demand, in the same
-- transaction that records it. The two transports need that said in different
-- places: a notice is folded by the very round that reads the demand, so that
-- round's own accounting already sees what it changed, and the wake the notice
-- registered is what ends the wait it was published into. A fact certified
-- directly on the owner thread has neither — it is recorded between two rounds,
-- with no wake to ride — so without this the turn after it would still be
-- pacing itself by registrations that have since moved: waiting its idle bound
-- before offering the attachment the opportunity this evidence revived, or
-- waiting for an instant named by an attachment this very fact retired. Only
-- evidence the model did not already hold resettles anything; a duplicate and a
-- refusal establish nothing and leave the demand exactly as the last round
-- published it.
reportHostRetirementFact
  ∷ HasCallStack ⇒ WindowHost → Acknowledgement → RetirementFact → IO (Maybe FactAnswer)
reportHostRetirementFact host acknowledgement fact =
  ownerOperation (hostSession host) certifyOperation (windowIdentifiers (attachmentWindow target)) $
    case hostRetirementState host of
      Nothing → pure Nothing
      Just retirement → atomically $ do
        answered ← certifyRetirementFact retirement target acknowledgement fact
        case answered of
          Right (FactRecorded _) → resettleRetirementDemand host
          Right AttachmentNowRetired → resettleRetirementDemand host
          _ → pure ()
        pure (either (const Nothing) Just answered)
  where
    target = acknowledgedAttachment acknowledgement
