-- | The graphics owner's one handle, and the records its cells hold.
--
-- This module defines representation and documents ownership; it performs no
-- work. It is the single owner state and ledger: the handle is built once, by
-- "Hetoimasia.Runtime.GLFW.Internal.Owner.Start", and every other owner module
-- reads or writes these same cells rather than a copy of them. The owner
-- thread is the only writer of the target table, the geometry cells, the
-- seen-input revisions, the latch and the retained failures; the main thread is
-- the only writer of the port reservations; the custody ledger is written by
-- both, under the stage rules "Hetoimasia.Runtime.GLFW.Internal.Owner.Custody"
-- enforces. Any thread may read.
--
-- = State
--
-- +----------------------+------------------+---------------------------------+--------+---------------------+-------------------------------+
-- | State                | Owner            | Readers and writers             | Thread | Lifetime            | Reset or disposal             |
-- +======================+==================+=================================+========+=====================+===============================+
-- | The handoff          | This lifetime    | See                             | Any    | The owner worker's  | Closed by the exit before the |
-- |                      |                  | "Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff" |        | lifetime            | join                          |
-- +----------------------+------------------+---------------------------------+--------+---------------------+-------------------------------+
-- | The target table     | The graphics     | The owner thread alone writes;  | Owner  | The owner's run     | An entry is removed only      |
-- |                      | owner            | any thread may read it          |        | action              | against a terminal record     |
-- +----------------------+------------------+---------------------------------+--------+---------------------+-------------------------------+
-- | The fatal latch      | This lifetime    | The owner writes once; any      | Any    | The owner worker's  | Never cleared; read by the    |
-- |                      |                  | thread reads                    |        | lifetime            | sentinel and by the exit      |
-- +----------------------+------------------+---------------------------------+--------+---------------------+-------------------------------+
-- | The port reservations| This lifetime    | The main thread alone           | Any    | The owner worker's  | Each is released by the send  |
-- |                      |                  |                                 |        | lifetime            | that spends it                |
-- +----------------------+------------------+---------------------------------+--------+---------------------+-------------------------------+
module Hetoimasia.Runtime.GLFW.Internal.Owner.State
  ( -- * The owner handle
    GraphicsOwner (..)
  , retainedFailureBound

    -- * The owner's own view of one target
  , TargetState (..)
  , Construction (..)
  , constructed
  , TargetStanding (..)
  , standingOf
  , initialEligibility

    -- * Who owes an attachment's settlement
  , Custody (..)
  , Stage (..)

    -- * The latched failure
  , Latched (..)
  , LatchSource (..)
  ) where

import Control.Concurrent.STM (STM, TVar)
import Control.Exception (ExceptionWithContext, SomeException)
import Data.Map.Strict (Map)
import Hetoimasia.Foundation.Time (MonotonicSource)
import Hetoimasia.Foundation.Worker (Worker, WorkerGroup)
import Hetoimasia.GLFW.Internal.Notify (Notifier)
import Hetoimasia.Runtime.GLFW.Internal (Acknowledgement, AttachmentId, CompletionPublisher)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Config (GraphicsOwnerConfig)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Evidence (RollbackEvidence, TargetEvidence)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff (OwnerHandoff, TargetGeometry)
import Hetoimasia.Runtime.GLFW.Internal.RenderDemand (RenderEligibility (RenderDeferred))
import Numeric.Natural (Natural)

-- | One target as the owner holds it.
data TargetState = TargetState
  { targetAcknowledgement ∷ !Acknowledgement
  , targetConstruction ∷ !Construction
  , targetSeen ∷ !Natural
    -- ^ The observation revision the owner has folded.
  , targetEligible ∷ !RenderEligibility
  , targetReleasing ∷ !Bool
  , targetRetirementFailed ∷ !Bool
    -- ^ Its injected retirement raised. It is explicitly unverified from then
    -- on, and no later round or drain invokes that operation again: the
    -- design admits no blind retry, and an operation that failed once may
    -- have disposed part of what it owns. Only independent evidence settles
    -- it.
  }

-- | Where a target's construction settled, which is what decides whether the
-- owner owns anything for it.
data Construction
  = ConstructionPending
  | ConstructionAccepted !TargetEvidence
  | ConstructionPartial !TargetEvidence
    -- ^ Less was built than intended and the owner owns what exists.
  | ConstructionUnverified
    -- ^ The construction raised or was cancelled, so neither acceptance nor a
    -- verified rollback settled it. The owner keeps ownership.
  | ConstructionRolledBack !RollbackEvidence
    -- ^ The backend verified its own rollback, so the owner owns nothing at
    -- all for this target. It is the one settlement whose retirement asks the
    -- backend for nothing: the rollback evidence /is/ the terminal record.
  deriving (Eq, Show)

constructed ∷ Construction → Bool
constructed = \case
  ConstructionAccepted _ → True
  _ → False

-- | What the owner's own construction of one target settled as, as any thread
-- may read it.
--
-- It is how an application learns that a target it holds a service for is not
-- usable, and so that it should release it. The owner never releases one on
-- the application's behalf: the attachment is the application's, the window's
-- exclusive slot is the host's, and retiring either from the owner's thread is
-- precisely the cross-thread authority this design does not grant.
data TargetStanding
  = TargetConstructing
  | TargetUsable
  | TargetUnusable !Bool
    -- ^ The target cannot be used. The flag is whether the owner still owns
    -- something for it that its retirement must dispose; 'False' means the
    -- backend verified its own rollback and nothing remains.
  deriving (Eq, Show)

standingOf ∷ Construction → TargetStanding
standingOf = \case
  ConstructionPending → TargetConstructing
  ConstructionAccepted _ → TargetUsable
  ConstructionPartial _ → TargetUnusable True
  ConstructionUnverified → TargetUnusable True
  ConstructionRolledBack _ → TargetUnusable False

-- | A target the main thread has published nothing for yet is deferred: its
-- extent is unknown and nothing known suspends it, which is exactly what
-- 'RenderDeferred' says.
initialEligibility ∷ RenderEligibility
initialEligibility = RenderDeferred

-- | One exact incarnation's settlement obligation.
--
-- Every attachment the owner's protocol registers gets an entry, and it is
-- the single place that says who owes that incarnation's retirement evidence.
-- Before it existed each path decided for itself, and each decided from
-- whether the owner happened to hold the target — which is not the same
-- question, and answered wrongly for an attachment the owner had been told
-- about but had not yet taken.
data Custody = Custody
  { custodyAcknowledgement ∷ !Acknowledgement
    -- ^ The authority its facts are certified or published under.
  , custodyStage ∷ !Stage
  }

-- | Where one incarnation stands between registration and settled.
--
-- The stages advance, with one exception: a claim that could not complete
-- returns 'CustodySettling' to 'CustodyRegistered', so the settlement can be
-- attempted again. Nothing else moves backwards, and 'CustodySettled' is
-- terminal — an incarnation that reaches it can never be announced again,
-- which is what keeps a delayed announcement from reopening a slot the host
-- has already finished with.
data Stage
  = CustodyRegistered
    -- ^ Registered with the host, its acknowledgement recorded, and nobody
    -- told. __The main thread owes its settlement.__ It is the only stage at
    -- which the main thread may settle the attachment itself, because it is
    -- the only one at which no announcement can be in flight.
  | CustodySettling
    -- ^ The main thread has claimed this incarnation's settlement and is
    -- performing it. No announcement may be admitted while it is here, and
    -- the claim is /retryable/: a settlement that could not complete puts it
    -- back at 'CustodyRegistered', and one interrupted part-way can be
    -- claimed again. It becomes 'CustodySettled' only when the facts are
    -- really recorded.
  | CustodyAnnounced
    -- ^ An announcement was admitted to the lifetime port. __The owner owes
    -- its settlement from this instant__, before it has consumed the event:
    -- the event is queued, and the owner will take it.
  | CustodyOwned
    -- ^ The owner has taken the event and holds the target.
  | CustodySettled
    -- ^ Its retirement evidence exists — a terminal record the owner wrote,
    -- or facts the main thread certified because nothing was ever owned.
    -- Nothing further is owed.
  deriving (Eq, Show)

-- | The first failure the owner found, and where it is also kept.
--
-- The latch is notification and never evidence, so every failure it holds is
-- kept somewhere else as well. Which somewhere is what the exit needs: once
-- the supervision sentinel has raised the latch at an application checkpoint,
-- the exit has to leave out the one store entry that is the same failure, and
-- report every other one.
data Latched = Latched
  { latchedSource ∷ !LatchSource
  , latchedFailure ∷ !(ExceptionWithContext SomeException)
  }

-- | Where a latched failure is also kept.
data LatchSource
  = LatchedWhileRunning
    -- ^ A target's construction or retirement the owner caught and carried on
    -- from. It is also the /first/ entry of 'ownerRetained': 'retainFailure'
    -- latches only when nothing is latched yet, and appends in the same
    -- transaction, so the failure that latched is the first one retained.
  | LatchedByRunEnd
    -- ^ The failure that ended the run. It is carried by the worker's own
    -- outcome, with everything the drain contributed retained beside it, and
    -- 'ownerRetained' is empty — any retained failure would have latched
    -- first and left this one unlatched.

-- | One running supervised graphics owner.
--
-- Its representation is private: no worker group, no backend operation, and no
-- authority over the host can be taken from it.
data GraphicsOwner scene = GraphicsOwner
  { ownerHandoff' ∷ !(OwnerHandoff scene)
  , ownerWorkerHandle ∷ !(Worker ())
  , ownerGroup ∷ !WorkerGroup
  , ownerLatch ∷ !(TVar (Maybe Latched))
    -- ^ The first failure, for /notification/: it is what the supervision
    -- sentinel waits on. It is deliberately not the store, because a latch
    -- keeps one failure and a drain can produce several, and it records
    -- /where/ that failure is also kept so the exit can tell whether it has
    -- already been reported.
  , ownerDelivered ∷ !(TVar Bool)
    -- ^ Whether the supervision sentinel has raised the latched failure at
    -- the application's own checkpoint. From that moment the runtime owns
    -- reporting it, and the exit must not report it a second time.
  , ownerRetained ∷ !(TVar [ExceptionWithContext SomeException])
    -- ^ The failures the owner /survived/ — a target's construction or
    -- retirement that it caught and carried on from — with the context each
    -- propagated with, oldest first and bounded by 'retainedFailureBound'.
    --
    -- A failure that ended the run is deliberately not here: the worker's own
    -- outcome carries it, the exit reads that back from the group report, and
    -- keeping it in both would report the same failure twice. Between the two
    -- stores every failure is reported exactly once.
  , ownerTargets ∷ !(TVar (Map AttachmentId TargetState))
  , ownerCustody ∷ !(TVar (Map AttachmentId Custody))
  , ownerGeometryCells ∷ !(TVar (Map AttachmentId TargetGeometry))
  , ownerSeenInputs ∷ !(TVar (Natural, Natural))
    -- ^ The demand and scene snapshot revisions the owner's last step read.
    -- Its wait compares them, so a publication into either really does wake
    -- an idle owner rather than sitting until something else does.
  , ownerPending ∷ !(STM [AttachmentId])
    -- ^ The host's own pending-attachment set, read only. It is what tells the
    -- owner that an exact attachment has validated the facts it established,
    -- which is the one thing that lets it forget that incarnation's cells.
  , ownerRetiring ∷ !(STM [AttachmentId])
    -- ^ The attachments the host's own model says have begun retiring, read
    -- only. A window's close begins that without anything passing through the
    -- lifetime port — no @detach@ call is involved at all — so the owner
    -- learns it by looking rather than by being told, which is idempotent by
    -- construction and puts no obligation on the application.
  , ownerStarted ∷ !(TVar Bool)
  , ownerRetainedLimit ∷ !Int
    -- ^ How many failures the owner keeps, derived from the host's own window
    -- limit rather than chosen: a round can fail one construction and one
    -- retirement for every window the host may hold live, and the owner's own
    -- startup, retirement and destruction can each fail once beside them.
  , ownerReservations ∷ !(TVar Natural)
  , ownerNotifier ∷ !Notifier
  , ownerPublisher ∷ !CompletionPublisher
  , ownerClock ∷ !MonotonicSource
  , ownerSettled ∷ !(IO ())
    -- ^ The private examples' own seam, run after an injected operation has
    -- returned and before the state it settles is committed. Production
    -- passes 'noHostHooks', whose is @pure ()@.
  , ownerSettings ∷ !(GraphicsOwnerConfig scene)
  }

-- | The most failures an owner over a host of this many windows keeps.
--
-- It is derived rather than chosen, because a chosen number silently discards
-- evidence the contract promises is readable: one retirement round can offer
-- 'graphicsRetireTarget' for every window the host may hold live, and every
-- one of them can fail. Two per window covers a construction and a retirement
-- each; the four beside them cover the owner's own startup, whole-owner
-- retirement, destruction, and one more.
retainedFailureBound ∷ Int → Int
retainedFailureBound limit = 2 * max 1 limit + 4
