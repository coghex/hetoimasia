-- | The supervised graphics owner: one foundation worker that owns the
-- rendering backend's targets and shared state, beside a protected window host
-- that keeps every GLFW call on the process main thread.
--
-- It is the machinery D-32 asks for and nothing more: worker ownership,
-- explicit bounded handoffs, cancellation and retirement. The backend
-- operations are injected as 'GraphicsOperations', so this package gains no
-- GPU dependency and VK-7 supplies Vulkan operations to this same
-- implementation rather than replacing it.
--
-- = What the owner is, and is not
--
-- It is a 'Hetoimasia.Foundation.Worker.WorkerDefinition' started into a
-- worker group this component owns — separate from the application's ordinary
-- worker group and from the diagnostics worker — so ordinary worker drain does
-- not end it and no automatic join can run before the main thread has
-- serviced retirement.
--
-- It performs __no GLFW operation__. It enters no session, creates no window
-- and no surface, processes no event, and issues no window command: all of
-- those stay on the main thread, and a platform modal loop there still stalls
-- them. The one thing it reaches across is the session's existing cross-thread
-- wake, through 'publishCompletion' and 'wakeGraphicsHost', exactly as any
-- other publishing thread does. That wake is authorized publication, not an
-- owner GLFW operation, and the examples assert the difference.
--
-- = The exit, which is D-33's
--
-- 'withGraphicsOwnerHost' composes the owner with the protected host lifetime
-- so that a whole-session exit runs in this order:
--
-- 1. quiescence closes the host's admission — commands, demand, input, and new
--    graphics use — and then the owner's own lifetime port;
-- 2. ordinary application workers stop and drain, which is the runtime's own
--    ordering and touches the owner's group not at all;
-- 3. the owner stays alive and retires each target and then itself through its
--    injected operations, publishing each certified fact through the host's
--    existing completion publisher;
-- 4. the main-thread protected boundary services bounded native housekeeping
--    through the host's own retirement environment while it awaits verified
--    retirement. It offers each attachment an opportunity that /waits/ and
--    performs no owner work, and it validates each exact attachment's terminal
--    evidence rather than the owner's completion;
-- 5. once the injected whole-owner destruction has returned its evidence, and
--    only then, the boundary joins the owner;
-- 6. the host's windows, session, and parents unwind.
--
-- An individual close or detach is not that: 'releaseGraphicsTarget' retires
-- one target, the owner publishes that target's exact evidence, the main
-- thread acknowledges it and its window is released, and the owner and every
-- other target stay live. Only a whole-host exit requires the final join.
--
-- = What is never permission
--
-- The owner's completion is not evidence. Neither is an empty target set, a
-- cancellation, a timeout, or a cleanup failure. A target is released only
-- against the terminal record its own injected retirement returned, and the
-- owner's borrowed parents are released only against the injected whole-owner
-- destruction's. An owner that ends without the second answers
-- 'OwnerDestructionUnverified', which retains that fact and authorizes
-- nothing — never a disposal, and never a replay of the work that failed.
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

-- +----------------------+------------------+---------------------------------+--------+---------------------+-------------------------------+
-- | The fatal latch      | This lifetime    | The owner writes once; any      | Any    | The owner worker's  | Never cleared; read by the    |
-- |                      |                  | thread reads                    |        | lifetime            | sentinel and by the exit      |
-- +----------------------+------------------+---------------------------------+--------+---------------------+-------------------------------+
-- | The port reservations| This lifetime    | The main thread alone           | Any    | The owner worker's  | Each is released by the send  |
-- |                      |                  |                                 |        | lifetime            | that spends it                |
-- +----------------------+------------------+---------------------------------+--------+---------------------+-------------------------------+
module Hetoimasia.Runtime.GLFW.Internal.Owner
  ( -- * The injected backend operations
    GraphicsOperations (..)
  , OwnerStart (..)
  , OwnerReady
  , ownerReady
  , TargetStart (..)
  , TargetHandoff (..)
  , TargetEvidence
  , targetEvidence
  , RollbackEvidence
  , rollbackEvidence
  , OwnerStep (..)
  , TargetStepView (..)
  , StepReport (..)
  , noStepWork
  , NextDeadline (..)
  , TargetRetire (..)
  , TargetRetired
  , targetRetired
  , OwnerRetire (..)
  , OwnerRetired
  , ownerRetired
  , OwnerDestroy (..)
  , OwnerDestroyed
  , ownerDestroyed
  , HasEvidence (..)

    -- * Configuration
  , GraphicsOwnerConfig (..)
  , graphicsOwnerConfig
  , OwnerTimer
  , ownerTimer
  , realtimeOwnerTimer
  , graphicsOwnerComponent

    -- * The owner
  , GraphicsOwner
  , ownerHandoff
  , graphicsOwnerWorker
  , readOwnerStatusNow
  , readOwnerTerminalNow
  , readTargetTerminalsNow
  , readOwnerGeometry
  , readOwnerFailure
  , readOwnerFailures
  , retainedFailureBound
  , readOwnerTargets
  , readOwnerAcknowledged
  , Stage (..)
  , custodyOf
  , readOwnerCustody
  , TargetStanding (..)
  , readTargetStanding
  , ownerTargetAcknowledgement
  , awaitOwnerRound
  , wakeGraphicsHost

    -- * The additive protected-host constructor
  , withGraphicsOwnerHost
  , withGraphicsOwnerHostIn
  , withGraphicsOwnerHostWith
  , runGraphicsOwnerApplication
  , superviseGraphicsOwner

    -- * Handing targets over, and taking them back
  , GraphicsHandover (..)
  , handOverGraphicsTarget
  , announceGraphicsTarget
  , graphicsTargetProtocol
  , releaseGraphicsTarget
  , ReleaseAnswer (..)
  , publishGraphicsObservation

    -- * Independent whole-owner evidence
  , publishOwnerRetirement
  , publishOwnerDestruction

    -- * Failures
  , OwnerDestructionUnverified (..)
  , OwnerHostUnprotected (..)
  , OwnerHandleMissing (..)
  , OwnerHandoverUnsettled (..)
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , check
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , registerDelay
  , writeTVar
  )
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , evaluate
  , fromException
  , mask
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (foldM, forM, forM_, unless, void, when)
import GHC.Stack (HasCallStack)
import Data.Foldable (for_, traverse_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (Component, Logger, logWarning, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare)
import Hetoimasia.Foundation.Recovery (Disposition (Required))
import Hetoimasia.Foundation.Resource (Scoped, withResourceLabelled)
import Hetoimasia.Foundation.Time
  ( Duration
  , Instant
  , MonotonicSource
  , deadlineReached
  , durationNanoseconds
  , readInstant
  , remainingUntil
  )
import Hetoimasia.Foundation.Worker
  ( Completion (completionExit, completionResult)
  , GroupReport (..)
  , Requested (CancelWasRequested)
  , Result (..)
  , RunExit (RunExited)
  , StopToken
  , Worker
  , WorkerGroup
  , awaitStartup
  , closeWorkerGroup
  , requestStop
  , startWorkerWith
  , stopRequested
  , withWorkerGroup
  , workerDefinition
  )
import Hetoimasia.GLFW.Internal.Notify (Notifier, dischargeNotification, registerNotification)
import Hetoimasia.GLFW.Session (Session)
import Hetoimasia.GLFW.Window (WindowId, WindowObservation)
import Hetoimasia.Runtime.GLFW.Internal
  ( Acknowledgement
  , AttachmentId
  , AttachmentProtocol (..)
  , CompletionPolicy (FiniteCompletion)
  , CompletionPublication (..)
  , CompletionPublisher
  , DetachAnswer (..)
  , FactAnswer (..)
  , GraphicsAttachment (..)
  , GraphicsRefusal (..)
  , GraphicsService
  , HostConfig (..)
  , HostHooks (..)
  , noHostHooks
  , NoticeAdmission (..)
  , ProtectedExit (..)
  , RetirementEnvironment (..)
  , RetirementProgress (..)
  , RollbackOutcome (RollbackSafe)
  , WindowHost
  , allRetirementFacts
  , attachWindowGraphics
  , attachmentIncarnation
  , attachmentWindow
  , certifyGraphicsFact
  , completionNotice
  , detachWindowGraphics
  , graphicsAttachment
  , hostConfiguration
  , RolledBack (rolledBackAttachment)
  , hostAttachmentView
  , hostGraphicsPublisher
  , hostPendingAttachments
  , hostWakeNotifier
  , publishCompletion
  , retirementEnvironmentOf
  , runProtectedWindowApplication
  , windowGraphicsService
  , withProtectedWindowHostOver
  )
import Hetoimasia.GLFW.Internal.Attachment (AttachmentPhase (AttachmentRetiring), viewPhase)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff
import Hetoimasia.Runtime.GLFW.Internal.RenderDemand (RenderEligibility (RenderDeferred))
import Hetoimasia.Runtime.Logging (LoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Recognition (Unrecognized)
  , Role (Service)
  , RuntimeControl
  , SupervisedStart
  , WorkerPolicy (..)
  , startSupervised
  )
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Evidence

-- | What a backend operation established, as the owner records it.
--
-- Its representation is a label the backend chose. The owner stores it, hands
-- it back, and never interprets it — and, which is the whole point, never
-- constructs one: a record that exists is a record an injected operation
-- returned. What the label /says/ is the backend's business; that there /is/
-- one is the permission.
newtype OwnerReady = OwnerReady Text
  deriving (Eq, Show)

newtype TargetEvidence = TargetEvidence Text
  deriving (Eq, Show)

newtype RollbackEvidence = RollbackEvidence Text
  deriving (Eq, Show)

newtype TargetRetired = TargetRetired Text
  deriving (Eq, Show)

newtype OwnerRetired = OwnerRetired Text
  deriving (Eq, Show)

newtype OwnerDestroyed = OwnerDestroyed Text
  deriving (Eq, Show)

ownerReady ∷ Text → OwnerReady
ownerReady = OwnerReady

targetEvidence ∷ Text → TargetEvidence
targetEvidence = TargetEvidence

rollbackEvidence ∷ Text → RollbackEvidence
rollbackEvidence = RollbackEvidence

targetRetired ∷ Text → TargetRetired
targetRetired = TargetRetired

ownerRetired ∷ Text → OwnerRetired
ownerRetired = OwnerRetired

ownerDestroyed ∷ Text → OwnerDestroyed
ownerDestroyed = OwnerDestroyed

-- | The label one piece of evidence carries, so a record can be quoted in a
-- diagnostic without anything learning to interpret it.
class HasEvidence a where
  evidenceDetail ∷ a → Text

instance HasEvidence OwnerReady where evidenceDetail (OwnerReady detail) = detail

instance HasEvidence TargetEvidence where evidenceDetail (TargetEvidence detail) = detail

instance HasEvidence RollbackEvidence where evidenceDetail (RollbackEvidence detail) = detail

instance HasEvidence TargetRetired where evidenceDetail (TargetRetired detail) = detail

instance HasEvidence OwnerRetired where evidenceDetail (OwnerRetired detail) = detail

instance HasEvidence OwnerDestroyed where evidenceDetail (OwnerDestroyed detail) = detail

-- ---------------------------------------------------------------------------
-- The injected operation set

-- | What the owner tells its backend when it starts. It carries the owner's
-- own label and nothing else: no session, no window, no native handle, and no
-- GLFW capability of any kind.
newtype OwnerStart = OwnerStart {startingOwner ∷ Text}
  deriving (Eq, Show)

-- | What the owner tells its backend about one target it is to construct.
--
-- The window is an /identity/, not a handle: the backend cannot reach the
-- window through it, and the main thread remains the only thread that can.
data TargetStart = TargetStart
  { startingTarget ∷ !AttachmentId
  , startingWindow ∷ !WindowId
  , startingIncarnation ∷ !Natural
  }
  deriving (Eq, Show)

-- | How a target's construction and its handoff settled.
--
-- The owner retains ownership of whatever a construction left behind until one
-- of exactly two things happens: the backend accepts the target, or the
-- backend verifies its own rollback. 'TargetPartial' is the first case with
-- less built than intended — the owner owns what exists, publishes nothing
-- usable, and must still retire it — and a construction that raises or is
-- cancelled is neither, so the owner keeps the target as unverified and
-- retires it too.
data TargetHandoff
  = TargetConstructed !TargetEvidence
  | TargetPartial !TargetEvidence
    -- ^ Construction did not complete and left resources the owner now owns.
  | TargetRolledBack !RollbackEvidence
    -- ^ Construction failed and the backend verified that nothing remains.
    -- Only this answer lets the owner certify the target's retirement facts
    -- without a retirement of its own.
  deriving (Eq, Show)

-- | What the owner knows about one target when it offers a step.
data TargetStepView = TargetStepView
  { viewTarget ∷ !AttachmentId
  , viewEligibility ∷ !RenderEligibility
  , viewGeometry ∷ !TargetGeometry
  , viewRevision ∷ !Natural
    -- ^ The observation revision this view was folded from, so a backend can
    -- tell a repeated view from a fresh one without comparing observations.
    -- Zero until the main thread has published one.
  , viewConstructed ∷ !Bool
    -- ^ Whether the backend's own construction accepted this target. A view
    -- for a partial or unverified target is offered so the backend can see it,
    -- never as a claim that it is usable.
  }
  deriving (Eq, Show)

-- | One bounded progress step's inputs.
data OwnerStep scene = OwnerStep
  { stepNow ∷ !Instant
  , stepScene ∷ scene
    -- ^ The latest scene any application thread published. It is a
    -- latest-value snapshot, so a stalled publisher leaves the owner the last
    -- coherent one rather than nothing.
  , stepDemand ∷ !OwnerDemand
  , stepTargets ∷ ![TargetStepView]
  }

-- | What one bounded step reports.
--
-- The owner records this; it infers none of it. In particular it never decides
-- from a step's return value that anything retired.
data StepReport = StepReport
  { stepAdvanced ∷ !Bool
    -- ^ Whether this step did work. Status only.
  , stepImmediateWork ∷ !Bool
    -- ^ Whether further work is owed at once, so the owner takes another round
    -- without waiting.
  }
  deriving (Eq, Show)

-- | A step that did nothing and owes nothing.
noStepWork ∷ StepReport
noStepWork = StepReport False False

-- | The earliest absolute instant the backend next wants a round, or nothing.
data NextDeadline
  = NoOwnerDemand
  | OwnerDeadline !Instant
    -- ^ In the host clock's domain, which is the one domain every deadline in
    -- this lifetime belongs to.
  deriving (Eq, Show)

-- | What the owner tells its backend when it retires one target.
data TargetRetire = TargetRetire
  { retiringTarget ∷ !AttachmentId
  , retiringWindow ∷ !WindowId
  , retiringConstructed ∷ !Bool
    -- ^ Whether the backend's construction had accepted it. A partial or
    -- unverified target is retired too, and is told so here.
  }
  deriving (Eq, Show)

-- | What the owner tells its backend when it retires itself.
data OwnerRetire = OwnerRetire
  { retiringStarted ∷ !Bool
    -- ^ Whether the injected startup ever returned. Whole-owner retirement is
    -- offered whatever the answer, because a startup that failed part-way may
    -- still have acquired shared state.
  , retiringUnverified ∷ ![AttachmentId]
    -- ^ Targets whose own retirement produced no evidence. Whole-owner
    -- retirement is independent of how many targets there ever were, and this
    -- names the ones it could not account for rather than hiding them.
  }
  deriving (Eq, Show)

-- | What the owner tells its backend when it destroys itself.
newtype OwnerDestroy = OwnerDestroy {destroyingRetired ∷ Bool}
  deriving (Eq, Show)

-- | The narrow, injected backend operation set.
--
-- Everything the owner can ask a backend to do is here, and nothing here
-- resembles a recording, submission, or resource API: there is no command
-- buffer, no queue, no allocation, and no handle. Nor is there any GLFW
-- capability — no session, window, surface, event pump, or window command —
-- because the owner makes no GLFW call at all.
--
-- Every operation returns /evidence/ rather than a value the owner interprets.
-- The owner records what came back; it never manufactures a record, and a
-- missing record is what "unverified" means everywhere in this module.
data GraphicsOperations scene = GraphicsOperations
  { graphicsStartOwner ∷ OwnerStart → IO OwnerReady
    -- ^ Establish the owner's shared state. It runs on the owner thread,
    -- inside the owner's own protected retirement, before any target exists.
  , graphicsConstructTarget ∷ TargetStart → IO TargetHandoff
    -- ^ Construct one attachment's target and settle its handoff.
  , graphicsStep ∷ OwnerStep scene → IO StepReport
    -- ^ One bounded progress step. It must return finitely.
  , graphicsNextDeadline ∷ IO NextDeadline
    -- ^ The earliest absolute instant the backend next wants a round.
  , graphicsRetireTarget ∷ TargetRetire → IO TargetRetired
    -- ^ Retire one target. Returning is the evidence; raising is not.
  , graphicsRetireOwner ∷ OwnerRetire → IO OwnerRetired
  , graphicsDestroyOwner ∷ OwnerDestroy → IO OwnerDestroyed
    -- ^ Release the owner's shared state. Its evidence is the only thing that
    -- makes releasing the owner's borrowed parents safe.
  }

-- ---------------------------------------------------------------------------
-- Configuration

-- | How the owner waits for an absolute instant nothing else will wake it for.
--
-- It is injected for the same reason the host's clock is: an example must be
-- able to script when a deadline comes due instead of sleeping for it. The
-- action arms a timer for the duration and answers a transaction that becomes
-- true once it has elapsed.
newtype OwnerTimer = OwnerTimer (Duration → IO (STM Bool))

ownerTimer ∷ (Duration → IO (STM Bool)) → OwnerTimer
ownerTimer = OwnerTimer

-- | The process's own timer, which is what production uses.
realtimeOwnerTimer ∷ OwnerTimer
realtimeOwnerTimer = OwnerTimer $ \duration →
  readTVar <$> registerDelay (max 1 (fromIntegral (durationNanoseconds duration `div` 1000)))

-- | What one graphics owner is built from.
data GraphicsOwnerConfig scene = GraphicsOwnerConfig
  { ownerOperations ∷ !(GraphicsOperations scene)
  , ownerLabel ∷ !Text
    -- ^ The worker's label, which its group report and every diagnostic names.
  , ownerScene ∷ !(Prepared scene)
    -- ^ The scene the owner holds before any application thread has published
    -- one. It is the application's own value, prepared by the application, so
    -- this package needs no @NFData@ instance for it.
  , ownerEventCapacity ∷ !Int
    -- ^ How many attachment lifetime events the owner's one ordinary bounded
    -- port holds. At least one.
  , ownerClockTimer ∷ !OwnerTimer
  }

-- | A configuration over the given operations and initial scene: the label
-- @graphics-owner@, a lifetime port of sixteen events, and the process timer.
--
-- There is no disposition to choose. This delivery's graphics owner is
-- __required__: its terminal failure stops the run. An owner-wide optional
-- disposition would have to mean a recognized failure leaves the component
-- unavailable while the run continues, and nothing here implements that — the
-- owner would still latch, still retire, and the supervision sentinel would
-- still classify its failure as unrecognized and so fatal. The per-target
-- required\/optional policy the Vulkan design accepts is a different
-- question, about one target's recovery rather than the owner's, and it is
-- VK-14's.
graphicsOwnerConfig ∷ GraphicsOperations scene → Prepared scene → GraphicsOwnerConfig scene
graphicsOwnerConfig operations scene =
  GraphicsOwnerConfig
    { ownerOperations = operations
    , ownerLabel = "graphics-owner"
    , ownerScene = scene
    , ownerEventCapacity = 16
    , ownerClockTimer = realtimeOwnerTimer
    }

-- | The component the owner's own diagnostics are written under.
graphicsOwnerComponent ∷ Component
graphicsOwnerComponent = unsafeComponent "glfw.graphics-owner"

-- ---------------------------------------------------------------------------
-- The owner's own view of one target

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

-- ---------------------------------------------------------------------------
-- Who owes an attachment's settlement

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

-- | Record an attachment the host has just registered under this owner's
-- protocol. It is never replaced: an incarnation is registered once.
recordRegistered ∷ GraphicsOwner scene → AttachmentId → Acknowledgement → STM ()
recordRegistered owner target acknowledgement =
  modifyTVar'
    (ownerCustody owner)
    (Map.insertWith (\_ existing → existing) target (Custody acknowledgement CustodyRegistered))

-- | Move one incarnation to a later stage, if it has an entry at all.
advanceCustody ∷ GraphicsOwner scene → AttachmentId → Stage → STM ()
advanceCustody owner target stage =
  modifyTVar' (ownerCustody owner) (Map.adjust (\held → held {custodyStage = stage}) target)

-- | The stage one incarnation stands at, or 'Nothing' once it has been
-- forgotten. Any thread may read it; it is the transition state the whole
-- handoff is decided by.
custodyOf ∷ GraphicsOwner scene → AttachmentId → STM (Maybe Stage)
custodyOf owner target = fmap custodyStage . Map.lookup target <$> readTVar (ownerCustody owner)

-- | Every incarnation the ledger still holds, with its stage.
readOwnerCustody ∷ GraphicsOwner scene → STM [(AttachmentId, Stage)]
readOwnerCustody owner = Map.toAscList . Map.map custodyStage <$> readTVar (ownerCustody owner)

-- | Claim the right to settle an owner-unseen attachment on the main thread.
--
-- It answers the acknowledgement only for an incarnation the owner does not
-- owe — one still at 'CustodyRegistered', or one at 'CustodySettling' whose
-- earlier claim did not finish — and moves it to 'CustodySettling' in the
-- same transaction.
--
-- That claim, not the settlement, is what excludes an announcement: settling
-- an attachment means certifying its facts against the host, which is not a
-- transaction and cannot be one, so the stage the claim commits has to hold
-- the exclusion for however long the certification takes. An announcement
-- admitted before this commits leaves the stage at 'CustodyAnnounced' and
-- this answers nothing; one attempted while the claim is held finds
-- 'CustodySettling' and is refused, as is one attempted after the settlement
-- finished and reached 'CustodySettled'.
--
-- The claim is therefore /retryable/ rather than terminal. 'recordSettled'
-- is what makes it terminal, and only once the facts really exist; a claim
-- that could not certify them all puts the stage back at
-- 'CustodyRegistered', so a later opportunity can settle the attachment
-- instead of leaving it claimed by a settlement that never happened.
--
-- Absence from the owner's target table is never consulted, because a queued
-- announcement the owner has not yet taken looks exactly like an attachment
-- it never received.
claimSettlement ∷ GraphicsOwner scene → AttachmentId → STM (Maybe Acknowledgement)
claimSettlement owner target = do
  held ← Map.lookup target <$> readTVar (ownerCustody owner)
  case held of
    -- 'CustodySettling' is claimable too, so a settlement interrupted between
    -- its claim and its facts can be performed again. Nothing else may be:
    -- an announced or owned incarnation is the owner's, and a settled one is
    -- finished.
    Just custody | custodyStage custody `elem` [CustodyRegistered, CustodySettling] → do
      advanceCustody owner target CustodySettling
      pure (Just (custodyAcknowledgement custody))
    _ → pure Nothing

-- | Record that an incarnation's retirement evidence now exists.
recordSettled ∷ GraphicsOwner scene → AttachmentId → STM ()
recordSettled owner target = advanceCustody owner target CustodySettled

-- | The acknowledgement one incarnation is settled under.
custodyAcknowledgementOf ∷ GraphicsOwner scene → AttachmentId → STM (Maybe Acknowledgement)
custodyAcknowledgementOf owner target =
  fmap custodyAcknowledgement . Map.lookup target <$> readTVar (ownerCustody owner)

-- ---------------------------------------------------------------------------
-- The latched failure

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

-- ---------------------------------------------------------------------------
-- The owner handle

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
  , ownerSettings ∷ !(GraphicsOwnerConfig scene)
  }

-- | The handoff state, for a caller that publishes into it or reads from it.
ownerHandoff ∷ GraphicsOwner scene → OwnerHandoff scene
ownerHandoff = ownerHandoff'

-- | The foundation worker, for raw observation of its completion.
graphicsOwnerWorker ∷ GraphicsOwner scene → Worker ()
graphicsOwnerWorker = ownerWorkerHandle

readOwnerStatusNow ∷ GraphicsOwner scene → STM OwnerStatus
readOwnerStatusNow = readOwnerStatus . ownerHandoff'

readOwnerTerminalNow ∷ GraphicsOwner scene → STM OwnerTerminal
readOwnerTerminalNow = ownerTerminal . ownerHandoff'

readTargetTerminalsNow ∷ GraphicsOwner scene → STM (Map AttachmentId TerminalRecord)
readTargetTerminalsNow = targetTerminals . ownerHandoff'

-- | The last coherent framebuffer observation and reported bounds the owner
-- holds per target, which is the state D-30's seam chooses from.
readOwnerGeometry ∷ GraphicsOwner scene → STM (Map AttachmentId TargetGeometry)
readOwnerGeometry = readTVar . ownerGeometryCells

-- | The targets the owner still holds, whose retirement is therefore
-- unfinished. An entry leaves this table only against a terminal record.
readOwnerTargets ∷ GraphicsOwner scene → STM [AttachmentId]
readOwnerTargets owner = Map.keys <$> readTVar (ownerTargets owner)

-- | The attachments the owner still holds an acknowledgement for, which is
-- bounded by the windows the host may hold live and not by how many
-- incarnations they have had.
readOwnerAcknowledged ∷ GraphicsOwner scene → STM [AttachmentId]
readOwnerAcknowledged owner = Map.keys <$> readTVar (ownerCustody owner)

-- | What the owner's own construction of one target settled as, or 'Nothing'
-- once the owner no longer holds it.
readTargetStanding ∷ GraphicsOwner scene → AttachmentId → STM (Maybe TargetStanding)
readTargetStanding owner target =
  fmap (standingOf . targetConstruction) . Map.lookup target <$> readTVar (ownerTargets owner)

-- | The terminal owner failure, latched as soon as it was known. It is the
-- notification, not the evidence: 'readOwnerFailures' is the evidence.
readOwnerFailure ∷ GraphicsOwner scene → STM (Maybe (ExceptionWithContext SomeException))
readOwnerFailure owner = fmap latchedFailure <$> readTVar (ownerLatch owner)

-- | Every failure the owner retained, oldest first.
readOwnerFailures ∷ GraphicsOwner scene → STM [ExceptionWithContext SomeException]
readOwnerFailures = readTVar . ownerRetained

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

-- | The acknowledgement the host gave one attachment's protocol, which is what
-- the owner publishes that attachment's certified facts under.
--
-- It is kept after the target's own state is gone, because a fact may still be
-- owed once the target has been retired, and it is readable so that a
-- composition which must supply /independent/ evidence for an attachment the
-- owner could not account for has the authority to publish it. It is
-- completion authority for that one incarnation and nothing else: it names no
-- window, no session, and no resource.
ownerTargetAcknowledgement ∷ GraphicsOwner scene → AttachmentId → STM (Maybe Acknowledgement)
ownerTargetAcknowledgement = custodyAcknowledgementOf

-- | Wait until the owner has completed a round beyond the one given, or has
-- ended.
--
-- It is coordination for a caller that must observe the owner's progress
-- without reading a clock; the owner never waits for anybody to call it.
awaitOwnerRound ∷ GraphicsOwner scene → Natural → STM OwnerStatus
awaitOwnerRound owner seen = do
  status ← readOwnerStatus (ownerHandoff' owner)
  finished ← ownerRunEnded <$> ownerTerminal (ownerHandoff' owner)
  check (statusRounds status > seen || finished)
  pure status

-- | Wake the host's main thread, exactly as an admitted completion notice
-- does.
--
-- This is the authorized cross-thread publication D-29 leaves open, not a GLFW
-- operation of the owner's: the obligation is registered in one transaction
-- and discharged by one call, which is the session's own wake machinery and
-- the same path a command admission takes. Everything else GLFW owns stays on
-- the main thread.
wakeGraphicsHost ∷ GraphicsOwner scene → IO ()
wakeGraphicsHost owner = mask_ $ do
  -- Masked as 'publishCompletion' masks its own: an obligation registered and
  -- then not discharged is one the protected exit waits for forever, and a
  -- cancellation delivered between the two would leave exactly that.
  atomically (registerNotification (ownerNotifier owner))
  void (dischargeNotification (ownerNotifier owner))

-- ---------------------------------------------------------------------------
-- Failures

-- | The owner's run ended without the injected whole-owner destruction
-- returning evidence.
--
-- It retains that fact and authorizes nothing. It is never permission to
-- dispose the owner's shared state, and never permission to run the work that
-- failed again.
data OwnerDestructionUnverified = OwnerDestructionUnverified
  { unverifiedRetired ∷ !Bool
    -- ^ Whether whole-owner /retirement/ did return evidence, which
    -- destruction then did not follow.
  , unverifiedTargets ∷ !Int
    -- ^ How many targets the owner still held whose own retirement produced no
    -- evidence either.
  }
  deriving (Eq, Show)

instance Exception OwnerDestructionUnverified

-- | A graphics owner was asked for over a host that owns no retirement state,
-- so no attachment could ever name it and no fact could be published to it.
data OwnerHostUnprotected = OwnerHostUnprotected
  deriving (Eq, Show)

instance Exception OwnerHostUnprotected

-- | The owner's run action found no handle naming it.
--
-- Unreachable: the starter's preparation step fills that cell before the
-- child runs any of its definition. It is a typed failure rather than a silent
-- success, so a future change to the start handoff cannot turn an owner that
-- never ran into one that appears to have finished.
data OwnerHandleMissing = OwnerHandleMissing
  deriving (Eq, Show)

instance Exception OwnerHandleMissing

-- | A handover settled as something a handover is not expected to produce.
-- Nothing was left attached.
newtype OwnerHandoverUnsettled = OwnerHandoverUnsettled Text
  deriving (Eq, Show)

instance Exception OwnerHandoverUnsettled

-- ---------------------------------------------------------------------------
-- Starting the owner

-- | Build the handoff, start the worker, and answer the handle.
startGraphicsOwner
  ∷ WorkerGroup
  → WindowHost
  → GraphicsOwnerConfig scene
  → (GraphicsOwner scene → IO ())
  → IO (GraphicsOwner scene)
startGraphicsOwner group host config publish = do
  publisher ← maybe (throwIO OwnerHostUnprotected) pure (hostGraphicsPublisher host)
  handoff ←
    newOwnerHandoff
      (hostWindowLimit (hostConfiguration host))
      (max 1 (ownerEventCapacity config))
      (ownerScene config)
  latch ← newTVarIO Nothing
  delivered ← newTVarIO False
  retained ← newTVarIO []
  targets ← newTVarIO Map.empty
  custody ← newTVarIO Map.empty
  geometry ← newTVarIO Map.empty
  seenInputs ← newTVarIO (0, 0)
  started ← newTVarIO False
  reservations ← newTVarIO 0
  let partial worker =
        GraphicsOwner
          handoff
          worker
          group
          latch
          delivered
          retained
          targets
          custody
          geometry
          seenInputs
          (hostPendingAttachments host)
          (retiringAttachments host)
          started
          (retainedFailureBound (hostWindowLimit (hostConfiguration host)))
          reservations
          (hostWakeNotifier host)
          publisher
          (hostClock (hostConfiguration host))
          config
  -- The worker is registered and forked before a handle naming it exists, so
  -- the run action takes it from this cell. The starter's own preparation step
  -- fills it, which runs under the start's mask after the fork and before the
  -- gate that lets the child run any of its definition — so the run action
  -- never finds it empty.
  built ← newIORef Nothing
  let definition =
        workerDefinition
          (ownerLabel config)
          -- Nothing driver-shaped is allocated here and nothing is released
          -- here: every acquisition and every release the backend owns happens
          -- inside the run action's own protected retirement, which D-33
          -- requires and a 'Scoped' startup release could not provide.
          (\_ → pure ())
          (\token () → readIORef built >>= maybe (throwIO OwnerHandleMissing) (`runOwnerAction` token))
  -- The preparation step runs under the start's own mask, after the fork and
  -- before the gate that lets the child run any of its definition. Publishing
  -- the handle there — to the run action's own cell and to whatever composed
  -- this owner — is what leaves no instant at which a live owner exists that
  -- the protected exit cannot see.
  let publishHandle worker = do
        let owner = partial worker
        writeIORef built (Just owner)
        publish owner
  outcome ← startWorkerWith group definition publishHandle awaitStartup
  case outcome of
    Left _ → throwIO OwnerHostUnprotected
    Right (worker, _) → pure (partial worker)

-- | The attachments this host's model says are retiring.
retiringAttachments ∷ WindowHost → STM [AttachmentId]
retiringAttachments host = do
  pending ← hostPendingAttachments host
  views ← traverse (hostAttachmentView host) pending
  pure [target | (target, Just view) ← zip pending views, viewPhase view == AttachmentRetiring]

-- | The owner's whole run: the protected retirement, the body, and the settled
-- outcome.
runOwnerAction ∷ GraphicsOwner scene → StopToken → IO ()
runOwnerAction owner token = mask $ \restore → do
  -- The protected retirement is installed here, first, before a single
  -- dependent is constructed: from this line on, every way this action can end
  -- — an expected stop, a startup failure, a run failure, and a cancellation —
  -- leaves through the same drain.
  outcome ← tryWithContext (restore (ownerRun owner token))
  latchFailure owner outcome
  -- Unconditionally, and before the drain takes its final backlog: a normal
  -- stop ends the run without a failure to latch, and 'graphicsOwnerWorker'
  -- is public, so any caller can cause one. Closing here is what makes that
  -- single take sound — nothing can be admitted after it, so nothing can be
  -- admitted that the take will miss.
  atomically (closeOwnerPublications (ownerHandoff' owner))
  started ← readTVarIO (ownerStarted owner)
  drained ← ownerDrain owner restore started
  atomically (recordOwnerEnded (ownerHandoff' owner))
  wakeGraphicsHost owner
  settleOwnerOutcome outcome drained

-- | Latch a terminal owner failure as soon as it is known, and close the
-- admission it affects, without waiting for retirement to finish.
--
-- A cancellation is not a terminal failure and is never latched: it is what an
-- owner asked to stop is entitled to receive, the drain defers it, and the
-- worker's own outcome already carries it. Admission closes for it all the
-- same, because a cancelled owner is one no further target may be handed to.
latchFailure ∷ GraphicsOwner scene → Either (ExceptionWithContext SomeException) a → IO ()
latchFailure owner = \case
  Right _ → pure ()
  Left failure@(ExceptionWithContext _ exception) → atomically $ do
    unless (isAsynchronous exception) $ do
      held ← readTVar (ownerLatch owner)
      when (isNothing held) (writeTVar (ownerLatch owner) (Just (Latched LatchedByRunEnd failure)))
    -- Every publication into the handoff, not only the lifetime port: an
    -- owner that has ended reads none of them again, and a publisher told its
    -- demand or its scene was accepted by one would be told a falsehood.
    closeOwnerPublications (ownerHandoff' owner)

-- ---------------------------------------------------------------------------
-- The run loop

-- | The owner's own body: start the backend, then take rounds until a stop.
ownerRun ∷ GraphicsOwner scene → StopToken → IO ()
ownerRun owner token = do
  ready ← graphicsStartOwner operations (OwnerStart (ownerLabel (ownerSettings owner))) >>= evaluate
  -- Recorded exactly as it came back, and as /status/ rather than anywhere
  -- that could be mistaken for permission: what a successful startup
  -- establishes is that whole-owner retirement and destruction have something
  -- to act on, which the drain is told separately. It stays readable through
  -- retirement and after the owner has ended.
  atomically $ do
    recordOwnerStarted (ownerHandoff' owner) (evidenceDetail ready)
    writeTVar (ownerStarted owner) True
    writeOwnerPhase (ownerHandoff' owner) OwnerRunning
  wakeGraphicsHost owner
  loop
  where
    operations = ownerOperations (ownerSettings owner)
    loop = do
      ending ← atomically (ownerEnding owner token)
      unless ending $ do
        immediate ← ownerRound owner token
        unless immediate (ownerWait owner token)
        loop

-- | One bounded round: take the lifetime events, construct what is owed, fold
-- the observations, retire what was released, publish what is owed, and offer
-- the backend one step.
--
-- It answers whether another round is owed at once.
ownerRound ∷ GraphicsOwner scene → StopToken → IO Bool
ownerRound owner token = do
  takeLifetimeEvents owner
  foldHostRetirements owner
  constructPending owner
  foldObservations owner
  retireReleased owner
  publishOwed owner
  forgetValidatedTargets owner
  ending ← atomically (ownerEnding owner token)
  if ending
    then pure True
    else do
      (report, deadline) ← offerStep owner
      atomically
        ( writeOwnerProgress
            (ownerHandoff' owner)
            (stepAdvanced report)
            (stepImmediateWork report)
            (deadlineInstant deadline)
        )
      wakeGraphicsHost owner
      pure (stepImmediateWork report)

-- | Whether this round is the owner's last: its owner asked it to stop, or a
-- failure its disposition calls terminal has been latched.
--
-- A latched required failure ends the run action exactly as a stop does, which
-- is what takes the owner into the protected drain rather than leaving it
-- running with a failure recorded behind it.
ownerEnding ∷ GraphicsOwner scene → StopToken → STM Bool
ownerEnding owner token = do
  stopping ← stopRequested token
  latched ← isJust <$> readTVar (ownerLatch owner)
  pure (stopping || latched)

deadlineInstant ∷ NextDeadline → Maybe Instant
deadlineInstant = \case
  NoOwnerDemand → Nothing
  OwnerDeadline due → Just due

-- | Offer the backend one bounded step, and ask it for its next deadline.
--
-- Everything the step is given is read in one transaction, so a backend never
-- sees one target's observation from this round beside another's from the
-- last.
offerStep ∷ GraphicsOwner scene → IO (StepReport, NextDeadline)
offerStep owner = do
  now ← readInstant (ownerClock owner)
  (scene, demand, views) ← atomically $ do
    (scene, sceneRevision) ← readOwnerSceneAt handoff
    (demand, demandRevision) ← readOwnerDemandAt handoff
    states ← readTVar (ownerTargets owner)
    geometry ← readTVar (ownerGeometryCells owner)
    -- Recorded in the same transaction the step's inputs were read in, so the
    -- wait below can never conclude that a publication this step did not see
    -- has already been folded.
    writeTVar (ownerSeenInputs owner) (demandRevision, sceneRevision)
    pure (scene, demand, map (stepView geometry) (Map.toAscList states))
  report ← graphicsStep operations (OwnerStep now scene demand views) >>= evaluate
  deadline ← graphicsNextDeadline operations >>= evaluate
  pure (report, deadline)
  where
    handoff = ownerHandoff' owner
    operations = ownerOperations (ownerSettings owner)
    stepView geometry (target, state) =
      TargetStepView
        { viewTarget = target
        , viewEligibility = targetEligible state
        , viewGeometry = Map.findWithDefault noTargetGeometry target geometry
        , viewRevision = targetSeen state
        , viewConstructed = constructed (targetConstruction state)
        }

-- | Fold every lifetime event the port holds, oldest first.
takeLifetimeEvents ∷ GraphicsOwner scene → IO ()
takeLifetimeEvents owner = atomically $ do
  events ← takeTargetEvents (ownerHandoff' owner)
  modifyTVar' (ownerTargets owner) (\states → foldl fold' states events)
  -- The ledger already said the owner owed each of these from the instant its
  -- announcement was admitted; this records that it has now taken it.
  forM_ [target | TargetAttached target _ ← events] (\target → advanceCustody owner target CustodyOwned)
  where
    fold' states = \case
      TargetAttached target acknowledgement →
        Map.insertWith
          (\_ existing → existing)
          target
          (TargetState acknowledgement ConstructionPending 0 initialEligibility False False)
          states
      TargetReleased target → Map.adjust (\state → state {targetReleasing = True}) target states

-- | Mark every target whose attachment the host has begun retiring.
--
-- 'releaseGraphicsTarget' sends a 'TargetReleased' event, but it is not the
-- only way an attachment starts retiring: a window's own close protocol
-- begins it, and so does the host's quiescence, and neither passes through
-- the lifetime port. An owner that waited for the event would leave such a
-- target unretired, its terminal evidence unproduced, and its window unable
-- to finish closing while the owner stayed live.
--
-- So the owner reads the host's model instead of waiting to be told. That is
-- idempotent — a target already releasing is unchanged — and it needs nothing
-- of the application.
foldHostRetirements ∷ GraphicsOwner scene → IO ()
foldHostRetirements owner = atomically $ do
  retiring ← ownerRetiring owner
  modifyTVar' (ownerTargets owner) $ \states →
    foldl (\held target → Map.adjust (\state → state {targetReleasing = True}) target held) states retiring

-- | Whether the host has begun retiring a target the owner holds and has not
-- yet marked.
retirementsBegun ∷ GraphicsOwner scene → STM Bool
retirementsBegun owner = do
  retiring ← ownerRetiring owner
  states ← readTVar (ownerTargets owner)
  pure (any (\target → maybe False (not . targetReleasing) (Map.lookup target states)) retiring)

-- | Construct every target the backend has not settled yet.
--
-- Ownership is retained until the backend accepts the target or verifies its
-- own rollback. A construction that raises, or is cancelled, settles as
-- neither: the target stays, marked unverified, and the owner keeps whatever
-- it left behind.
--
-- No settlement here releases anything. A target that cannot be used is
-- /reported/ through 'readTargetStanding', and the attachment it belongs to is
-- retired when the main thread releases it or when the whole host exits —
-- because the attachment and its window's exclusive slot are the main
-- thread's, and taking them from the owner's thread is the cross-thread
-- authority this design withholds.
constructPending ∷ GraphicsOwner scene → IO ()
constructPending owner = readTVarIO (ownerTargets owner) >>= go . unsettled
  where
    unsettled states = [target | (target, state) ← Map.toAscList states, pending (targetConstruction state)]
    pending = \case
      ConstructionPending → True
      _ → False
    go [] = pure ()
    go (target : rest) = do
      -- A terminal failure stops the round where it happened: the next target
      -- is not constructed into an owner that is already retiring.
      terminal ← isJust <$> readTVarIO (ownerLatch owner)
      unless terminal (construct target >> go rest)
    construct target =
      tryWithContext
        ( graphicsConstructTarget
            (ownerOperations (ownerSettings owner))
            (TargetStart target (attachmentWindow target) (attachmentIncarnation target))
            >>= evaluate
        )
        >>= \case
          Left failure → do
            settle target ConstructionUnverified
            retainFailure owner failure
          Right (TargetConstructed evidence) → settle target (ConstructionAccepted evidence)
          Right (TargetPartial evidence) → settle target (ConstructionPartial evidence)
          Right (TargetRolledBack evidence) → settle target (ConstructionRolledBack evidence)
    settle target settlement =
      atomically
        ( modifyTVar'
            (ownerTargets owner)
            (Map.adjust (\state → state {targetConstruction = settlement}) target)
        )

-- | Fold every target's latest observation into the eligibility and geometry
-- the owner holds.
foldObservations ∷ GraphicsOwner scene → IO ()
foldObservations owner = atomically $ do
  observations ← readTargetObservations (ownerHandoff' owner)
  states ← readTVar (ownerTargets owner)
  let fresh =
        [ (target, observation)
        | (target, Just observation) ← observations
        , Just state ← [Map.lookup target states]
        , targetRevision observation > targetSeen state
        ]
  writeTVar (ownerTargets owner) (foldl foldState states fresh)
  modifyTVar' (ownerGeometryCells owner) (\geometry → foldl foldGeometry geometry fresh)
  where
    foldState held (target, observation) =
      Map.adjust
        (\state → state {targetSeen = targetRevision observation, targetEligible = targetEligibility observation})
        target
        held
    foldGeometry held (target, observation) =
      Map.insert
        target
        ( observeGeometry
            (observationFramebuffer observation)
            (targetBounds observation)
            (Map.findWithDefault noTargetGeometry target held)
        )
        held

-- | Retire every target the main thread released, through the injected
-- operation, and record exactly what it returned.
retireReleased ∷ GraphicsOwner scene → IO ()
retireReleased owner = do
  states ← readTVarIO (ownerTargets owner)
  forM_ [entry | entry@(_, state) ← Map.toAscList states, targetReleasing state] (uncurry (retireOneTarget owner))

retireOneTarget ∷ GraphicsOwner scene → AttachmentId → TargetState → IO ()
retireOneTarget _ _ state
  -- Failed once already, so it is not offered again. The target stays in the
  -- owner's table, explicitly unverified, and whole-owner retirement is told
  -- about it by name.
  | targetRetirementFailed state = pure ()
retireOneTarget owner target state = case targetConstruction state of
  -- The backend verified its own rollback, so there is nothing of the owner's
  -- to retire and nothing to ask it for. The rollback evidence it returned is
  -- the terminal record.
  ConstructionRolledBack evidence → settle (evidenceDetail evidence)
  _ →
    tryWithContext
      ( graphicsRetireTarget
          (ownerOperations (ownerSettings owner))
          (TargetRetire target (attachmentWindow target) (constructed (targetConstruction state)))
          >>= evaluate
      )
      >>= \case
        -- A failed retirement preserves its evidence and manufactures no
        -- acknowledgement: no record is written, so nothing downstream can
        -- mistake the attempt for the fact, the target stays in the owner's
        -- table, and it is marked so that nothing offers the operation again.
        Left failure → do
          atomically
            ( modifyTVar'
                (ownerTargets owner)
                (Map.adjust (\held → held {targetRetirementFailed = True}) target)
            )
          retainFailure owner failure
        Right retired → settle (evidenceDetail retired)
  where
    settle evidence = do
      atomically $ do
        recordTargetTerminal (ownerHandoff' owner) target evidence allRetirementFacts
        recordSettled owner target
        modifyTVar' (ownerTargets owner) (Map.delete target)
        -- The geometry is this incarnation's alone and nothing reads it once
        -- the target is retired, so it goes with the target rather than
        -- accumulating one entry per incarnation a window has ever had.
        modifyTVar' (ownerGeometryCells owner) (Map.delete target)
        closeTargetSlot (ownerHandoff' owner) target
      publishTerminal owner target (targetAcknowledgement state)

-- | Offer every fact a terminal record still owes to the host's completion
-- publisher.
--
-- A refusal leaves the fact owed. That is what makes the record the retention
-- and the publisher only the transport: a full inbox delays publication and
-- can never lose a fact.
publishOwed ∷ GraphicsOwner scene → IO ()
publishOwed owner = do
  records ← atomically (targetTerminals (ownerHandoff' owner))
  acknowledgements ← readTVarIO (ownerCustody owner)
  forM_ (Map.toAscList records) $ \(target, record) →
    unless (null (terminalOwed record)) $
      for_ (custodyAcknowledgement <$> Map.lookup target acknowledgements) (publishTerminal owner target)

-- | Offer this target's owed facts once, under the acknowledgement its
-- attachment was given.
publishTerminal ∷ GraphicsOwner scene → AttachmentId → Acknowledgement → IO ()
publishTerminal owner target acknowledgement = do
  held ← atomically (targetTerminal (ownerHandoff' owner) target)
  for_ held $ \record →
    forM_ (terminalOwed record) $ \fact →
      publishCompletion (ownerPublisher owner) (completionNotice target acknowledgement fact) >>= \case
        CompletionOffered NoticeAdmitted → published fact
        -- An equal notice is already pending, so the transport is already
        -- carrying this fact and the record stops owing it.
        CompletionOffered NoticeCoalesced → published fact
        CompletionOffered NoticeRejectedFull → pure ()
        CompletionClosed → pure ()
  where
    published fact = atomically (recordPublishedFact (ownerHandoff' owner) target fact)

-- | Forget the cells of every attachment that has validated the facts its
-- terminal record established.
--
-- An attachment leaves the host's own pending set only once its model holds
-- every retirement fact, so that — and not the owner's own bookkeeping — is
-- what says the record has done its work. A target the owner still holds is
-- never forgotten, however the host's set reads.
--
-- Without this the retained cells would be keyed by incarnation and grow with
-- every detach-and-reattach cycle. With it they are bounded by the windows the
-- host may hold live, which is what the handoff's contract promises.
forgetValidatedTargets ∷ GraphicsOwner scene → IO ()
forgetValidatedTargets owner = atomically $ do
  validated ← validatedTargets owner
  forM_ validated $ \target → do
    forgetTargetTerminal (ownerHandoff' owner) target
    modifyTVar' (ownerCustody owner) (Map.delete target)
    modifyTVar' (ownerGeometryCells owner) (Map.delete target)

-- | The attachments whose cells the owner may now forget.
--
-- Two kinds qualify, and both by the same test: the owner holds the target no
-- longer and the host's own model no longer has the attachment pending.
--
-- One is a target the owner retired and whose record's facts the attachment
-- has since validated. The other never reached the owner at all — a handover
-- interrupted after this protocol recorded its acknowledgement and before the
-- owner was told, whose attach then settled with a safe rollback. It leaves
-- an acknowledgement and no record, so waiting for a record to prune it would
-- keep one per cancelled attempt for the host's whole life.
--
-- An attachment between its registration and its announcement is /pending/,
-- so it is never mistaken for either.
validatedTargets ∷ GraphicsOwner scene → STM [AttachmentId]
validatedTargets owner = do
  records ← Map.keys <$> targetTerminals (ownerHandoff' owner)
  acknowledged ← Map.keys <$> readTVar (ownerCustody owner)
  held ← readTVar (ownerTargets owner)
  pending ← ownerPending owner
  pure
    [ target
    | target ← records <> filter (`notElem` records) acknowledged
    , not (Map.member target held)
    , target `notElem` pending
    ]

-- | Wait for the next thing worth a round: a stop, a lifetime event, a fresher
-- observation, newly published demand or a newer scene, or the owner's own
-- deadline.
--
-- The owner's deadlines are its own: nothing here waits for the main thread to
-- wake it, so a main loop that never posts an event, and a main thread stalled
-- in a platform modal loop, neither starve the owner nor delay a deadline it
-- set for itself.
ownerWait ∷ GraphicsOwner scene → StopToken → IO ()
ownerWait owner token = do
  status ← atomically (readOwnerStatus handoff)
  expired ← case statusNextDeadline status of
    Nothing → pure (pure False)
    Just due → do
      now ← readInstant (ownerClock owner)
      if deadlineReached now due then pure (pure True) else arm (remainingUntil now due)
  atomically $ do
    stopping ← stopRequested token
    failing ← isJust <$> readTVar (ownerLatch owner)
    queued ← (> 0) <$> pendingTargetEvents handoff
    fresher ← observationsAdvanced owner
    published ← inputsAdvanced owner
    -- An attachment that has just validated the facts one of the owner's
    -- records established is work of the owner's own: the round that follows
    -- releases the cells that record was holding. Without it those cells
    -- would wait for some unrelated reason to wake the owner, and a host
    -- whose windows are all idle would give it none.
    prunable ← not . null <$> validatedTargets owner
    -- A window closed from the main thread begins its attachment's retirement
    -- without an event, so an idle owner has to wake for that too.
    closing ← retirementsBegun owner
    elapsed ← expired
    check (stopping || failing || queued || fresher || published || prunable || closing || elapsed)
  where
    handoff = ownerHandoff' owner
    OwnerTimer arm = ownerClockTimer (ownerSettings owner)

-- | Whether the demand or the scene has been published since the owner's last
-- step read them.
--
-- Immediate demand is the case that makes this necessary rather than merely
-- tidy: an owner with no deadline and no event of its own would otherwise
-- sleep through a publisher asking for a frame now.
inputsAdvanced ∷ GraphicsOwner scene → STM Bool
inputsAdvanced owner = do
  (_, demandRevision) ← readOwnerDemandAt (ownerHandoff' owner)
  (_, sceneRevision) ← readOwnerSceneAt (ownerHandoff' owner)
  (seenDemand, seenScene) ← readTVar (ownerSeenInputs owner)
  pure (demandRevision > seenDemand || sceneRevision > seenScene)

-- | Whether any target's observation is newer than the one the owner folded.
observationsAdvanced ∷ GraphicsOwner scene → STM Bool
observationsAdvanced owner = do
  observations ← readTargetObservations (ownerHandoff' owner)
  states ← readTVar (ownerTargets owner)
  pure $
    or
      [ targetRevision observation > targetSeen state
      | (target, Just observation) ← observations
      , Just state ← [Map.lookup target states]
      ]

-- ---------------------------------------------------------------------------
-- The owner's own drain

-- | What one owner drain accumulated.
data OwnerDrain = OwnerDrain
  { drainFailures ∷ ![ExceptionWithContext SomeException]
  , drainCancellation ∷ !(Maybe (ExceptionWithContext SomeException))
  }

noOwnerDrain ∷ OwnerDrain
noOwnerDrain = OwnerDrain [] Nothing

-- | Retire every target the owner still holds, then the owner itself, then
-- destroy it — whatever ended the run action.
--
-- It raises nothing. Every failure and every cancellation is accumulated and
-- handed back, so a cancellation delivered here cannot skip retirement still
-- owed and repeated cancellation cannot release a borrowed parent early: each
-- is absorbed and re-raised only after every operation this drain owes has
-- been offered, in dependency order — every target, then the owner, then its
-- destruction.
ownerDrain ∷ GraphicsOwner scene → (∀ a. IO a → IO a) → Bool → IO OwnerDrain
ownerDrain owner restore started = do
  atomically (writeOwnerPhase (ownerHandoff' owner) OwnerRetiring)
  -- The port is closed by now, so this takes its whole backlog and nothing can
  -- arrive after it. It matters: a target announced between the owner's last
  -- round and its stop is an attachment the main thread is already holding a
  -- window for, and an owner that never took the event would leave it with no
  -- evidence to validate and no path to one.
  takeLifetimeEvents owner
  afterTargets ← drainTargets noOwnerDrain
  unverified ← Map.keys <$> readTVarIO (ownerTargets owner)
  (retiredEvidence, afterRetire) ←
    absorbing afterTargets (graphicsRetireOwner operations (OwnerRetire started unverified) >>= evaluate)
  for_ retiredEvidence (atomically . recordOwnerRetired (ownerHandoff' owner) . evidenceDetail)
  atomically (writeOwnerPhase (ownerHandoff' owner) OwnerDestroying)
  terminal ← atomically (ownerTerminal (ownerHandoff' owner))
  (destroyedEvidence, afterDestroy) ←
    absorbing
      afterRetire
      (graphicsDestroyOwner operations (OwnerDestroy (isJust (ownerRetiredEvidence terminal))) >>= evaluate)
  for_ destroyedEvidence (atomically . recordOwnerDestroyed (ownerHandoff' owner) . evidenceDetail)
  atomically (writeOwnerPhase (ownerHandoff' owner) OwnerFinished)
  pure afterDestroy
  where
    operations = ownerOperations (ownerSettings owner)
    absorbing ∷ OwnerDrain → IO a → IO (Maybe a, OwnerDrain)
    absorbing accumulated action =
      tryWithContext (restore action) >>= \case
        Right value → pure (Just value, accumulated)
        Left failure → pure (Nothing, absorbOwnerFailure failure accumulated)
    -- Every remaining target is retired before the owner is, in the order the
    -- model registered them, and a failure of one does not stop the next. A
    -- target the backend never constructed is retired too, and is told so:
    -- what the owner owns for it may be nothing, but the attachment's own
    -- terminal evidence is owed either way.
    drainTargets accumulated = do
      states ← readTVarIO (ownerTargets owner)
      retired ←
        foldM
          ( \held (target, state) →
              either (`absorbOwnerFailure` held) (const held)
                <$> tryWithContext (restore (retireOneTarget owner target state))
          )
          accumulated
          (Map.toAscList states)
      published ←
        either (`absorbOwnerFailure` retired) (const retired)
          <$> tryWithContext (restore (publishOwed owner))
      either (`absorbOwnerFailure` published) (const published)
        <$> tryWithContext (forgetValidatedTargets owner)

-- | Keep a synchronous failure; defer the first cancellation and absorb the
-- rest, so repeated cancellation cannot cut the drain short.
absorbOwnerFailure ∷ ExceptionWithContext SomeException → OwnerDrain → OwnerDrain
absorbOwnerFailure caught@(ExceptionWithContext _ failure) accumulated
  | isAsynchronous failure =
      accumulated {drainCancellation = maybe (Just caught) Just (drainCancellation accumulated)}
  | otherwise = accumulated {drainFailures = drainFailures accumulated <> [caught]}

isAsynchronous ∷ SomeException → Bool
isAsynchronous failure = isJust (fromException failure ∷ Maybe SomeAsyncException)

-- | Keep one failure the owner found while it kept running.
--
-- A cancellation is never kept here: it ends the run action and reaches the
-- drain as one, where it is deferred rather than recorded as the owner's
-- terminal failure.
--
-- Whether a synchronous one is /latched/ follows the established disposition,
-- because that is the question the disposition answers: a 'Required' graphics
-- owner's failure stops the run, and an 'Optional' one leaves the component
-- unavailable and the run going. Neither is ever permission to destroy
-- anything, and the target it happened to keeps its window either way.
retainFailure ∷ GraphicsOwner scene → ExceptionWithContext SomeException → IO ()
retainFailure owner failure@(ExceptionWithContext _ exception)
  | isAsynchronous exception = rethrowIO failure
  | otherwise = do
      atomically $ do
        -- Notification and evidence are separate. The latch keeps the first
        -- failure, because that is what a supervision sentinel can wait on;
        -- the retained list keeps every one of them with its own context,
        -- because a drain that failed three operations has three things to
        -- report and a latch would keep one.
        held ← readTVar (ownerLatch owner)
        when (isNothing held) (writeTVar (ownerLatch owner) (Just (Latched LatchedWhileRunning failure)))
        modifyTVar' (ownerRetained owner) (\kept → take (ownerRetainedLimit owner) (kept <> [failure]))
        -- Terminal for a required owner, so the admission it affects closes
        -- here rather than at the exit: no further target may be handed to an
        -- owner that is about to retire, and none may be constructed by the
        -- round this failure interrupted. The latch stays for supervision.
        closeOwnerPublications (ownerHandoff' owner)
      -- The main thread is told at once, so a checkpoint can raise while
      -- retirement is still to come.
      wakeGraphicsHost owner

-- | Settle the run action's own outcome against what the drain found.
--
-- The body's failure stays primary; the drain's are retained beside it under
-- the owner's cleanup label, and the deferred cancellation is re-raised only
-- once every operation the drain owed has been offered.
settleOwnerOutcome ∷ Either (ExceptionWithContext SomeException) () → OwnerDrain → IO ()
settleOwnerOutcome body drained = case body of
  Left primary → raiseRetainingOwner primary afterwards
  Right () → case afterwards of
    [] → pure ()
    primary : retained → raiseRetainingOwner primary retained
  where
    afterwards = drainFailures drained <> maybe [] pure (drainCancellation drained)

raiseRetainingOwner
  ∷ ExceptionWithContext SomeException → [ExceptionWithContext SomeException] → IO ()
raiseRetainingOwner primary = foldr retainOne (rethrowIO primary) . reverse
  where
    retainOne failure rest =
      withResourceLabelled ownerRetirementLabel (pure ()) (\() → rethrowIO failure) (\() → rest)

-- | The cleanup label the owner's retained failures carry.
ownerRetirementLabel ∷ Text
ownerRetirementLabel = "glfw graphics owner retirement"

-- ---------------------------------------------------------------------------
-- The additive protected-host constructor

-- | 'Hetoimasia.Runtime.GLFW.withProtectedWindowHost' with one supervised
-- graphics owner beside it.
--
-- Every existing constructor keeps its signature and its behaviour; this one
-- is additive and takes the owner's injected operations. See the module header
-- for the exit order, which is D-33's.
withGraphicsOwnerHost
  ∷ Logger
  → HostConfig
  → GraphicsOwnerConfig scene
  → (WindowHost → GraphicsOwner scene → IO r)
  → IO r
withGraphicsOwnerHost logger = withGraphicsOwnerHostOver logger Nothing

-- | 'withGraphicsOwnerHost' over a session scope the caller supplies, such as
-- a test seam's session.
withGraphicsOwnerHostIn
  ∷ Logger
  → Scoped Session
  → HostConfig
  → GraphicsOwnerConfig scene
  → (WindowHost → GraphicsOwner scene → IO r)
  → IO r
withGraphicsOwnerHostIn logger sessionScope = withGraphicsOwnerHostOver logger (Just sessionScope)

-- | 'withGraphicsOwnerHostIn' with the private examples' host hooks.
--
-- It is available only here, in the private @runtime-glfw-core@ sublibrary:
-- no public module exports it, and nothing in production calls it. The
-- examples that must deliver a cancellation, or a quiescence, at exactly the
-- handoff between an attachment's construction and its publication have no
-- other way to reach that instant, and asserting what the boundary does there
-- is worth more than the seam costs.
withGraphicsOwnerHostWith
  ∷ HostHooks
  → Logger
  → Scoped Session
  → HostConfig
  → GraphicsOwnerConfig scene
  → (WindowHost → GraphicsOwner scene → IO r)
  → IO r
withGraphicsOwnerHostWith hooks logger sessionScope =
  withGraphicsOwnerHostAll hooks logger (Just sessionScope)

withGraphicsOwnerHostOver
  ∷ Logger
  → Maybe (Scoped Session)
  → HostConfig
  → GraphicsOwnerConfig scene
  → (WindowHost → GraphicsOwner scene → IO r)
  → IO r
withGraphicsOwnerHostOver = withGraphicsOwnerHostAll noHostHooks

withGraphicsOwnerHostAll
  ∷ HostHooks
  → Logger
  → Maybe (Scoped Session)
  → HostConfig
  → GraphicsOwnerConfig scene
  → (WindowHost → GraphicsOwner scene → IO r)
  → IO r
withGraphicsOwnerHostAll hooks logger sessionScope config ownerConfig use = do
  -- The exit runs after the consumer has returned, so it reads the owner from
  -- a cell the consumer filled rather than from a value it could be given. An
  -- exit that finds none is a host whose owner never started, which still
  -- quiesces, drains, and unwinds exactly as an owner-less protected host does.
  pending ← newIORef Nothing
  let exit =
        ProtectedExit
          { exitBeforeDrain = \_ _ → readIORef pending >>= traverse_ beginOwnerExit
          , exitAfterDrain = \host restore → readIORef pending >>= traverse_ (finishOwnerExit restore logger host)
          }
  -- The group's own scope sits outside the protected host lifetime
  -- deliberately: D-33 forbids an automatic join that could run before the
  -- main thread has serviced retirement, and the exit's own
  -- 'closeWorkerGroup' — after verified destruction and before any window is
  -- released — is the join that matters. By the time this scope ends the group
  -- has already drained, so its automatic join finds it settled.
  withWorkerGroup $ \group →
    withProtectedWindowHostOver hooks exit logger sessionScope config $ \host → do
      owner ← startGraphicsOwner group host ownerConfig (writeIORef pending . Just)
      use host owner

-- | 'Hetoimasia.Runtime.GLFW.runProtectedWindowApplication' over a host that
-- owns a graphics owner.
--
-- Every step keeps the runner's order, thread, and labels. The application's
-- own quiescence still runs before the ordinary worker drain, supervision
-- still drains the ordinary group, and the owner's group is untouched by
-- either: its exit is the protected boundary's, in D-33's order.
runGraphicsOwnerApplication
  ∷ (∀ r. (LoggingLifetime → IO r) → IO r)
  → Text
  → (LoggingLifetime → (∀ r. (dependencies → IO r) → IO r))
  → (dependencies → WindowHost)
  → (dependencies → RuntimeControl → IO services)
  → (services → RuntimeControl → IO a)
  → IO a
runGraphicsOwnerApplication = runProtectedWindowApplication

-- | Register the sentinel that makes a terminal owner failure visible at the
-- application's own supervision checkpoints.
--
-- The owner's worker group is the component's, not the application's, so
-- supervision observes nothing of it on its own: a separate group provides no
-- connection at all. This registers one ordinary supervised service in the
-- application's group whose whole job is to wait on the owner's fatal latch
-- and fail with what it holds. A failure latched /before/ this ran — during
-- the owner's startup, before the application even reached its own startup
-- callback — is therefore seen the moment the sentinel is registered, because
-- the latch is durable and the sentinel reads it rather than an event it
-- might have missed.
--
-- It waits on a latch and nothing else, so it cannot delay retirement: the
-- owner keeps retiring while the application's checkpoint raises.
superviseGraphicsOwner ∷ RuntimeControl → GraphicsOwner scene → IO (SupervisedStart ())
superviseGraphicsOwner control owner = startSupervised control policy definition
  where
    policy =
      WorkerPolicy
        { policyRole = Service
        , policyDisposition = Required
        , policyComponent = graphicsOwnerComponent
        , policyClassifier = \_ → pure Unrecognized
        }
    definition =
      workerDefinition
        (ownerLabel (ownerSettings owner) <> ".supervision")
        (\_ → pure ())
        ( \token () → do
            latched ← atomically $ do
              held ← readTVar (ownerLatch owner)
              stopping ← stopRequested token
              check (isJust held || stopping)
              -- Recorded in the same transaction that takes it, so the exit
              -- can never read a latch this sentinel is about to raise and
              -- conclude that nobody has. From here the runtime owns
              -- reporting that failure at the application's own checkpoint,
              -- and the exit leaves it out of what it raises.
              when (isJust held) (writeTVar (ownerDelivered owner) True)
              pure (latchedFailure <$> held)
            traverse_ rethrowIO latched
        )

-- | Close the owner's ordinary admission and ask it to stop.
--
-- The order matters: the host's own quiescence has already closed attachment
-- admission, so nothing can reserve a port slot after this closes the port,
-- and an attachment that got past admission always found the port open.
beginOwnerExit ∷ GraphicsOwner scene → IO ()
beginOwnerExit owner = atomically $ do
  closeOwnerPublications (ownerHandoff' owner)
  requestStop (ownerWorkerHandle owner)

-- | Await verified whole-owner destruction while servicing bounded
-- housekeeping, then join.
--
-- The attachment drain has already returned, which means every attachment's
-- own terminal evidence was validated — never the owner's completion. What is
-- still owed is the owner's own: its shared state was acquired before any
-- target existed and outlives the last one, so an empty target set proves
-- nothing here, and neither does the worker ending.
finishOwnerExit ∷ (∀ a. IO a → IO a) → Logger → WindowHost → GraphicsOwner scene → IO ()
finishOwnerExit restore logger host owner = do
  awaited ← awaitOwnerDestruction restore logger host owner
  -- The join, after verified destruction and before the host releases a single
  -- window. It is reached only once the evidence exists, so it can never be
  -- what lets an unverified owner's parents go — and it absorbs cancellation,
  -- because escaping it would let the host unwind with the owner still live,
  -- which is the very thing the wait above refused to do.
  (report, interrupted) ← joinAbsorbing (ownerGroup owner) []
  -- Everything this exit found, in the order it found it: what the wait
  -- absorbed, what the owner survived, what its own run and drain failed
  -- with, and last the cancellations the join absorbed. Each is raised only
  -- now, after the join.
  kept ← readTVarIO (ownerRetained owner)
  -- The latch itself is deliberately absent. It is notification — what the
  -- supervision sentinel waits on — and every failure it can hold is already
  -- in exactly one of the stores beside it, so raising it here as well would
  -- report a single failed operation twice.
  --
  -- That is only half of it, because the sentinel raises the latch at the
  -- application's own checkpoint, where it becomes the composition's primary
  -- failure. Once it has, the store entry that is that same failure has
  -- already been reported and this exit must leave it out — while still
  -- reporting every failure the sentinel did not raise.
  delivered ← readTVarIO (ownerDelivered owner)
  latched ← readTVarIO (ownerLatch owner)
  (survived, fromWorker) ← case (delivered, latchedSource <$> latched) of
    (True, Just LatchedWhileRunning) →
      -- The first retained failure is the one the sentinel raised, and the
      -- rest are still this exit's to report. The worker's outcome is
      -- untouched: that latch ended the run without a failure of its own, so
      -- the outcome carries only what the drain found.
      pure (drop 1 kept, drainFailuresOf report)
    (True, Just LatchedByRunEnd) →
      -- The sentinel raised the failure that ended the run, which is exactly
      -- what the worker's outcome carries, so this exit reports none of that
      -- outcome. Nothing distinct is lost with it: whatever the drain found
      -- is retained inside that same outcome, and the group's own scope —
      -- which closes after this exit, outside the protected host lifetime —
      -- reports it there. Re-raising it here would retain a second copy of
      -- each, under a fresh identity that inspection cannot fold together.
      pure (kept, [])
    _ → pure (kept, drainFailuresOf report)
  case awaited <> survived <> fromWorker <> interrupted of
    [] → pure ()
    primary : rest → raiseRetainingOwner primary rest

-- | Join the owner's group, absorbing cancellation until it has drained.
--
-- 'closeWorkerGroup' is idempotent and answers the same report once the group
-- has drained, so a cancellation delivered during the wait is kept and the
-- join is entered again rather than abandoned.
-- | The most interruptions a join keeps while it waits for its report. It is
-- not evidence the contract promises to report in full — each is the same
-- interruption arriving again — so a small bound is honest here.
joinFailureBound ∷ Int
joinFailureBound = 8

joinAbsorbing
  ∷ WorkerGroup
  → [ExceptionWithContext SomeException]
  → IO (GroupReport, [ExceptionWithContext SomeException])
joinAbsorbing group found =
  tryWithContext (closeWorkerGroup group) >>= \case
    Right report → pure (report, found)
    -- Every failure, not only an asynchronous one. What matters is not the
    -- exception's type but how it arrived: an ordinary 'IOException'
    -- delivered with 'throwTo' is indistinguishable here from one the join
    -- itself raised, and returning on either would let the protected host
    -- unwind with the owner never proved terminal. So the join is entered
    -- again — it is documented idempotent, and re-entering it replays no
    -- backend disposal, which the owner's own drain owns — and the failure
    -- is kept for the caller to raise once a report really exists.
    Left caught → joinAbsorbing group (take joinFailureBound (found <> [caught]))

-- | What the joined owner's own run and drain failed with.
--
-- The worker's outcome is the only place a failure of its protected drain is
-- recorded — a 'graphicsRetireOwner' that failed while the destruction after
-- it succeeded leaves no latch and no missing evidence — so a host exit that
-- discarded this report would call that run a success.
drainFailuresOf ∷ GroupReport → [ExceptionWithContext SomeException]
drainFailuresOf report =
  [ failure
  | summary ←
      reportExitedBeforeClosing report <> reportDrained report <> reportObservedFailures report
  , failure ← case completionResult summary of
      Failed caught → [caught]
      -- A cancellation somebody asked for is not a failure to report: the
      -- owner's own drain already deferred it, finished every operation it
      -- owed, and re-raised it in order, which is the contract being kept
      -- rather than broken. One nobody asked for is a different matter, and
      -- is reported like any other outcome.
      Cancelled caught | not (requestedCancel (completionExit summary)) → [caught]
      _ → []
  ]
  where
    requestedCancel = \case
      RunExited _ CancelWasRequested → True
      _ → False

-- | Service the host's bounded native housekeeping until the owner's injected
-- destruction has answered.
--
-- The main thread performs no owner work here. It polls and waits for native
-- events and retries window retirement — which is exactly what the host's own
-- retirement environment lends the attachment drain, bounded per turn by the
-- host's configured idle wait — and nothing else. The owner's own wake ends
-- each wait as soon as it has something to report.
--
-- __It returns for the evidence and for nothing else.__ Not for the owner's
-- run ending, not for its worker becoming terminal, and not for an empty
-- target set: none of those establishes that the owner's shared state was
-- released, and returning on one would let the boundary unwind the windows,
-- the session and every borrowed parent behind it. An owner that ended without
-- the evidence therefore retains them, exactly as a stalled attachment retains
-- its window, and says so once through 'OwnerDestructionUnverified' under
-- 'graphicsOwnerComponent'. Only independent evidence —
-- 'publishOwnerDestruction', from a thread that established it — ends the wait
-- after that, and operator process termination remains the escape. No timeout
-- grants the authority, because a timeout is not evidence.
--
-- It raises nothing. A native pump that fails withdraws itself, its failure
-- kept once rather than repeated every turn, and the wait then runs under a
-- finite timer of the same bound. A cancellation is absorbed and handed back
-- for the caller to re-raise after the join: cutting this wait short would be
-- exactly the early release D-33 forbids, and repeated cancellation may not
-- achieve it either.
awaitOwnerDestruction
  ∷ (∀ a. IO a → IO a)
  → Logger
  → WindowHost
  → GraphicsOwner scene
  → IO [ExceptionWithContext SomeException]
awaitOwnerDestruction restore logger host owner = loop True False []
  where
    environment = retirementEnvironmentOf logger host
    bound = max 1 (round (environmentBound environment * 1e6))
    attempt found action =
      tryWithContext action >>= \case
        Right () → pure (True, found)
        Left caught@(ExceptionWithContext _ (failure ∷ SomeException))
          | isAsynchronous failure → pure (True, found <> [caught])
          | otherwise → pure (False, found <> [caught])
    loop pumping declared found = do
      verified ← atomically (ownerDestructionVerified (ownerHandoff' owner))
      if verified
        then pure found
        else do
          -- Said once, the first turn the owner is known to have ended with
          -- nothing established. It is a diagnostic and never an authority:
          -- the wait continues after it, and its own failure is retained
          -- rather than allowed to unwind what the wait is retaining.
          ended ← atomically (ownerRunEnded <$> ownerTerminal (ownerHandoff' owner))
          (declared', afterReport) ←
            if declared || not ended
              then pure (declared, found)
              else (,) True . snd <$> attempt found (restore (declareUnverified owner logger))
          if pumping
            then do
              (keeps, waited) ← attempt afterReport (restore (environmentAwait environment >>= evaluate))
              (_, retired) ← attempt waited (restore (environmentRetireWindows environment >>= evaluate))
              loop keeps declared' retired
            else do
              expired ← registerDelay bound
              (_, timed) ←
                attempt
                  afterReport
                  (restore (atomically (readTVar expired >>= \elapsed → check elapsed)))
              loop False declared' timed

-- | The one diagnostic an unverified owner destruction owes, and the typed
-- failure it records.
--
-- The warning says what is being retained; the failure is what the exit hands
-- back, retained beside whatever else it found, so a run whose owner could not
-- destroy its own state reports that even when independent evidence later let
-- the boundary finish. It is never authority: it is raised into the wait's own
-- accumulator, the wait continues, and nothing is released because of it.
declareUnverified ∷ GraphicsOwner scene → Logger → IO ()
declareUnverified owner logger = do
  terminal ← atomically (ownerTerminal (ownerHandoff' owner))
  unverified ← readTVarIO (ownerTargets owner)
  logWarning
    logger
    graphicsOwnerComponent
    "The graphics owner ended without verified destruction; its shared state, the windows, the session and every parent are retained"
    [ ("retired", Text.pack (show (isJust (ownerRetiredEvidence terminal))))
    , ("unverified-targets", Text.pack (show (Map.size unverified)))
    ]
    >>= evaluate
  throwIO (OwnerDestructionUnverified (isJust (ownerRetiredEvidence terminal)) (Map.size unverified))

-- | Publish whole-owner retirement evidence a thread other than the owner
-- established.
--
-- It is the same shape the attachment model already has for retirement facts:
-- which transport carried the evidence decides nothing, and only that it was
-- /established/ does. Nothing here establishes it — the caller must have.
publishOwnerRetirement ∷ GraphicsOwner scene → OwnerRetired → IO ()
publishOwnerRetirement owner evidence = do
  atomically (recordOwnerRetired (ownerHandoff' owner) (evidenceDetail evidence))
  wakeGraphicsHost owner

-- | Publish whole-owner destruction evidence a thread other than the owner
-- established.
--
-- This is the independent evidence that ends a retained exit, and the only
-- thing besides the owner's own injected destruction that can. A composition
-- that publishes one it did not establish has destroyed nothing and has
-- authorized the release of everything the owner borrowed; that is exactly the
-- mistake the whole contract exists to prevent, and no code here can catch it.
publishOwnerDestruction ∷ GraphicsOwner scene → OwnerDestroyed → IO ()
publishOwnerDestruction owner evidence = do
  atomically (recordOwnerDestroyed (ownerHandoff' owner) (evidenceDetail evidence))
  wakeGraphicsHost owner

-- ---------------------------------------------------------------------------
-- Handing targets over

-- | How a handover settled.
data GraphicsHandover
  = TargetHandedOver !GraphicsService
    -- ^ The window's exclusive slot is reserved, the attachment is registered,
    -- and the owner has been told. The owner constructs the target on its own
    -- thread; its terminal record and the service's observation say what
    -- became of it.
  | HandoverRefused !GraphicsRefusal
    -- ^ The host refused the reservation, before any effect.
  | HandoverPortFull
    -- ^ The owner's bounded lifetime port could not take the event, so nothing
    -- was reserved, attached, or constructed. It is backpressure, reported
    -- here rather than swallowed: the caller may offer the same window again.
  | HandoverOwnerClosed
    -- ^ The owner's admission has ended. Nothing is left attached.
  | HandoverSuperseded !AttachmentId
    -- ^ The host's admission closed while the reservation was being made, so
    -- nothing usable was published. The attachment it left behind has been
    -- retired: the owner never received it and owned nothing for it. It is
    -- named so a caller can see which incarnation that was.
  | HandoverRolledBack !RolledBack
    -- ^ The reservation settled as a rollback, whose attachment — if it left
    -- one — has been retired for the same reason.
  deriving (Show)

-- | Reserve one open window's exclusive graphics slot for the owner, on the
-- main thread, and hand the target over.
--
-- The port's room is held /before/ anything is reserved, so a full port is
-- answered with nothing attached rather than with an attachment the owner was
-- never told about.
handOverGraphicsTarget ∷ WindowHost → GraphicsOwner scene → WindowId → IO GraphicsHandover
handOverGraphicsTarget host owner window =
  -- One protected region covers the reservation, the attachment and the
  -- announcement together. Only the attachment itself is restored, because
  -- only it runs for an unbounded time; everything either side of it is a
  -- finite, non-retrying transaction, so no cancellation can land in the gap
  -- between holding the port's room and spending it, or between reserving the
  -- window's slot and telling the owner about it.
  mask $ \restore → do
    reserved ← atomically (reserveEvent owner)
    case reserved of
      ReservationFull → pure HandoverPortFull
      -- Nothing is attached at all: an owner whose admission has ended will
      -- never hear of anything, so there is nothing to be gained by
      -- reserving a window's slot and settling it again afterwards.
      ReservationClosed → pure HandoverOwnerClosed
      ReservationHeld →
        tryWithContext (restore (attachWindowGraphics host window (graphicsTargetProtocol host owner))) >>= \case
          Left (failure ∷ ExceptionWithContext SomeException) → do
            -- A cancellation delivered inside that call can leave the window's
            -- slot reserved and its protocol registered while the call itself
            -- raises: with the service published and the answer lost, or
            -- retiring with no service ever published. Both leave an
            -- attachment whose retirement evidence only the owner can produce,
            -- so both are announced before this propagates.
            --
            -- The reservation and the protocol's registration commit together
            -- before construction begins, and this protocol's own construction
            -- is one finite transaction, so an attachment that exists at all
            -- has already recorded the acknowledgement this announcement needs.
            recovered ← atomically (recoverableTarget owner window)
            case recovered of
              Just target →
                announceReserved owner target >>= \case
                  EventAdmitted → pure ()
                  -- The owner's admission closed in the same moment — a
                  -- terminal owner failure does that — so it will never hear
                  -- of this attachment and owns nothing for it. Settling it
                  -- here is the difference between a window the host drain
                  -- releases and one it waits on for evidence nobody will
                  -- produce.
                  _ → void (retireStranded host owner target)
              -- Nothing of this window's is pending, so whatever the attach
              -- settled as, it left no attachment. Any acknowledgement this
              -- protocol recorded for it is dropped here rather than at some
              -- later owner round: an owner blocked in its startup or its
              -- step takes no rounds, and one acknowledgement per cancelled
              -- attempt is exactly the unbounded growth the cells must not
              -- have.
              Nothing → atomically (releaseEvent owner >> forgetStrandedCustody owner window)
            rethrowIO failure
          Right (GraphicsAttached service) →
            announceReserved owner (graphicsAttachment service) >>= \case
              EventAdmitted → pure (TargetHandedOver service)
              -- The owner's admission closed between the reservation and the
              -- send, which a terminal owner failure can do at any moment.
              _ → HandoverOwnerClosed <$ void (retireUnannounced host owner service)
          Right (GraphicsRefused refusal) → do
            atomically (releaseEvent owner)
            pure (HandoverRefused refusal)
          -- Quiescence won between the reservation and the publication. The
          -- attachment is registered and retiring, and its acknowledgement is
          -- recorded, but nothing usable was published and the owner was
          -- never told — so the owner owns nothing for it and its facts are
          -- certified here, exactly as an unannounced handover's are. Left
          -- alone it would be an attachment whose evidence nothing was ever
          -- going to produce, and the protected drain would wait for it.
          Right (GraphicsSuperseded target) → do
            atomically (releaseEvent owner)
            void (retireStranded host owner target)
            pure (HandoverSuperseded target)
          -- A construction that failed and rolled back. This protocol's own
          -- construction is one finite transaction that cannot fail, so this
          -- is reachable only through a cancellation inside the reservation;
          -- either way the owner never received the target and owns nothing
          -- for it, and an unsafe rollback leaves it retiring and owed the
          -- same certification.
          Right (GraphicsRolledBack settled) → do
            atomically (releaseEvent owner)
            void (retireStranded host owner (rolledBackAttachment settled))
            pure (HandoverRolledBack settled)
          Right other → do
            atomically (releaseEvent owner)
            throwIO (OwnerHandoverUnsettled (Text.pack (show other)))

-- | Tell the owner about a target, for a caller that attached it through
-- 'Hetoimasia.Runtime.GLFW.attachWindowGraphics' itself, or that must offer
-- the same event again after 'HandoverPortFull'.
announceGraphicsTarget ∷ GraphicsOwner scene → GraphicsService → IO EventAdmission
announceGraphicsTarget owner service = mask_ $ do
  reserved ← atomically (reserveEvent owner)
  case reserved of
    ReservationFull → pure EventRefusedFull
    ReservationClosed → pure EventPortClosed
    ReservationHeld → announceReserved owner (graphicsAttachment service)

-- | Install the target's observation slot, queue its announcement, and spend
-- the held reservation — all in one transaction.
--
-- The whole admission commits together or not at all: the incarnation's stage
-- is checked, the host is asked whether that exact attachment is still one of
-- its own pending ones, the slot is installed, and the event is queued. A
-- delayed announcement for an incarnation the slot has moved past therefore
-- cannot reopen anything, and neither can one racing the main thread's own
-- settlement of the same attachment — whichever transaction commits first
-- decides, and the other is refused.
announceReserved ∷ GraphicsOwner scene → AttachmentId → IO EventAdmission
announceReserved owner target = do
  held ← atomically (custodyAcknowledgementOf owner target)
  case held of
    Nothing → EventPortClosed <$ atomically (releaseEvent owner)
    Just acknowledgement → do
      -- Allocated outside the transaction because a snapshot cannot be made
      -- inside one; discarded unspent if the admission below refuses.
      slot ← prepareTargetSlot
      payload ← prepare (TargetAttached target acknowledgement)
      atomically $ do
        stage ← custodyOf owner target
        pending ← ownerPending owner
        if stage /= Just CustodyRegistered || target `notElem` pending
          then EventPortClosed <$ releaseEvent owner
          else do
            _ ← installTargetSlot (ownerHandoff' owner) target slot
            admitted ← offerTargetEvent (ownerHandoff' owner) payload
            releaseEvent owner
            if admitted == EventAdmitted
              then EventAdmitted <$ advanceCustody owner target CustodyAnnounced
              else admitted <$ closeTargetSlot (ownerHandoff' owner) target

-- | Retire an attachment the owner never received, on the owner thread.
--
-- It is the one case where the main thread establishes a target's retirement
-- facts itself, and the ledger is what makes it safe: 'claimSettlement'
-- answers only for an incarnation still at 'CustodyRegistered', which is
-- exactly the stage at which no announcement is queued and none can be
-- admitted afterwards. So the owner never received this attachment, never
-- entered its construction, and owns nothing for it — there is no backend
-- work to have ended, and leaving it retiring would retain its window
-- against a retirement nothing was ever going to perform.
--
-- An incarnation the owner does owe — announced, or held — answers nothing
-- here and is left to the owner, whose own drain retires it. Absence from
-- the owner's target table is never consulted, because a queued announcement
-- the owner has not yet taken looks exactly like an attachment it never
-- received.
retireUnannounced ∷ HasCallStack ⇒ WindowHost → GraphicsOwner scene → GraphicsService → IO Bool
retireUnannounced host owner service = do
  answered ← detachWindowGraphics host service
  -- An attachment already retiring — a close, a quiescence, or an earlier
  -- detach got there first — is owed its facts exactly as one this call began
  -- is. Only an absent one is owed nothing, because there is nothing left.
  if answered == DetachAbsent
    then pure False
    else retireStranded host owner (graphicsAttachment service)

-- | Settle an attachment the owner never received, naming it by identity, and
-- answer whether this call was the one that settled it.
retireStranded ∷ HasCallStack ⇒ WindowHost → GraphicsOwner scene → AttachmentId → IO Bool
retireStranded host owner target = mask_ $
  -- Masked from the claim through the facts, so a cancellation cannot leave
  -- the ledger claimed with nothing recorded. Every step is a finite,
  -- non-retrying transaction or an owner-thread certification, so nothing
  -- here can block. The claim is retryable besides, which is what makes that
  -- belt as well as braces.
  atomically (claimSettlement owner target) >>= \case
    Nothing → pure False
    Just acknowledgement → do
      -- Its retirement has to have begun before a fact can be recorded at
      -- all: 'certifyGraphicsFact' refuses one for an attachment that is
      -- still active. A settlement that ignored that refusal would mark the
      -- ledger terminal with nothing recorded and stall the drain for good.
      retiring ← atomically (elem target <$> ownerRetiring owner)
      unless retiring (beginStrandedRetirement host target)
      answers ← forM allRetirementFacts (certifyGraphicsFact host acknowledgement)
      atomically $ do
        pending ← ownerPending owner
        let gone = target `notElem` pending
        if gone || all isJust answers
          then do
            recordSettled owner target
            -- Forgotten here rather than at some later owner round: the
            -- entry is owed to nobody, and the owner whose round would
            -- otherwise prune it may be one that never takes another.
            when gone (modifyTVar' (ownerCustody owner) (Map.delete target))
            pure True
          else do
            -- Nothing was recorded, so nothing was settled. It goes back to
            -- where it was, and the paths that may announce or settle it are
            -- free to try again.
            advanceCustody owner target CustodyRegistered
            pure False

-- | Begin the retirement of an attachment nobody has begun, so its facts can
-- be recorded.
--
-- The service is asked of the host rather than held, because an attachment
-- whose answer was lost has one the caller never received. An incarnation the
-- window's slot has moved past is not this one and is left alone.
beginStrandedRetirement ∷ HasCallStack ⇒ WindowHost → AttachmentId → IO ()
beginStrandedRetirement host target =
  atomically (windowGraphicsService host (attachmentWindow target)) >>= \case
    Just service | graphicsAttachment service == target → void (detachWindowGraphics host service)
    _ → pure ()

-- | Forget every ledger entry this window left behind that names no
-- attachment the host still has pending and no target the owner holds.
forgetStrandedCustody ∷ GraphicsOwner scene → WindowId → STM ()
forgetStrandedCustody owner window = do
  entries ← Map.keys <$> readTVar (ownerCustody owner)
  held ← readTVar (ownerTargets owner)
  pending ← ownerPending owner
  forM_
    [ target
    | target ← entries
    , attachmentWindow target == window
    , not (Map.member target held)
    , target `notElem` pending
    ]
    (\target → modifyTVar' (ownerCustody owner) (Map.delete target))

-- | The attachment this window's slot holds that the owner has not been told
-- about, if there is one.
--
-- It is found from the ledger rather than from a published service, because
-- an attachment interrupted before its service was published has no service
-- and still needs its retirement evidence produced. Only an incarnation the
-- ledger still says nobody was told about is a candidate: one already
-- announced is the owner's, and one already settled needs nothing.
recoverableTarget ∷ GraphicsOwner scene → WindowId → STM (Maybe AttachmentId)
recoverableTarget owner window = do
  entries ← Map.toList <$> readTVar (ownerCustody owner)
  pending ← ownerPending owner
  pure $
    listToMaybe
      [ target
      | (target, custody) ← entries
      , custodyStage custody == CustodyRegistered
      , attachmentWindow target == window
      , target `elem` pending
      ]

-- | Publish one target's latest observation and render eligibility, from the
-- main thread, as its own monotonic revision.
publishGraphicsObservation
  ∷ GraphicsOwner scene
  → GraphicsService
  → Natural
  → WindowObservation
  → RenderEligibility
  → Maybe ExtentBounds
  → IO ObservationPublication
publishGraphicsObservation owner service revision observation eligibility bounds = do
  payload ← prepare (Just (TargetObservation revision observation eligibility bounds))
  atomically (publishTargetObservation (ownerHandoff' owner) (graphicsAttachment service) payload)

-- | What a release answered.
data ReleaseAnswer
  = ReleaseBegun
    -- ^ The attachment is retiring and the owner has been told. Its window is
    -- released once the owner's own retirement evidence has been validated;
    -- the owner and every other target stay live.
  | ReleaseSettled
    -- ^ The owner was never told about this incarnation, so there was nothing
    -- to tell it and no room on its port to hold: the attachment is retiring
    -- and its facts were certified here, because nothing of the owner's
    -- exists for it.
  | ReleaseOwnerRetires
    -- ^ The owner owes this incarnation — it was announced, or it holds the
    -- target — and the event could not be delivered, so the owner's own drain
    -- produces its evidence rather than a release event.
  | ReleaseNoOp !DetachAnswer
  | ReleasePortFull
    -- ^ The owner's port could not take the event, so nothing was detached.
  deriving (Show)

-- | Retire one target, leaving the owner and every other target live.
--
-- This is D-33's individual close, not its whole-session exit: nothing here
-- joins the owner, retires it, or destroys anything it shares.
releaseGraphicsTarget ∷ WindowHost → GraphicsOwner scene → GraphicsService → IO ReleaseAnswer
releaseGraphicsTarget host owner service = mask_ $ do
  -- Masked through settlement, so a cancellation can never begin the
  -- attachment's retirement and then fail to tell the owner, which would
  -- leave a retiring attachment whose evidence nothing was going to produce.
  -- Every step is a finite, non-retrying transaction.
  stage ← atomically (custodyOf owner target)
  if stage == Just CustodyRegistered
    then
      -- Nobody was ever told about this incarnation, so there is nothing to
      -- tell and no room to hold for telling it. A port that happens to be
      -- full is not an obstacle to a release that needs no event, and
      -- answering 'ReleasePortFull' here would leave the caller retrying
      -- something it never needed.
      detachWithoutEvent host owner service
    else do
      reserved ← atomically (reserveEvent owner)
      case reserved of
        ReservationFull → pure ReleasePortFull
        -- The owner's admission has ended, so no event can reach it. The
        -- detach still happens: an attachment's retirement has to begin
        -- before any evidence for it can be recorded at all, and the owner's
        -- own drain — or this attachment's protocol step — is what produces
        -- it. Withholding the detach would leave the caller's release
        -- unperformed.
        ReservationClosed → detachWithoutEvent host owner service
        ReservationHeld →
          -- A detach that raises gives the held room back rather than
          -- spending it on an event there is now nothing to send.
          tryWithContext (detachWindowGraphics host service) >>= \case
            Left (failure ∷ ExceptionWithContext SomeException) → do
              atomically (releaseEvent owner)
              rethrowIO failure
            Right DetachBegun → do
              payload ← prepare (TargetReleased target)
              admitted ← atomically (sendReservedEvent owner payload)
              if admitted == EventAdmitted
                then pure ReleaseBegun
                else do
                  -- The retirement has begun and the event could not be
                  -- delivered. The owner owes this incarnation — the ledger
                  -- says it was announced or taken — so its own drain
                  -- produces the evidence; settling it here would be the main
                  -- thread claiming a retirement that is not its to claim.
                  settled ← retireStranded host owner target
                  pure (if settled then ReleaseSettled else ReleaseOwnerRetires)
            Right other → do
              atomically (releaseEvent owner)
              pure (ReleaseNoOp other)
  where
    target = graphicsAttachment service

-- | Begin one attachment's retirement with no event to carry it, and settle
-- it here if the owner was never told about it.
--
-- It is the shape both eventless releases take: the one nobody was told
-- about, and the one whose owner's admission has already ended. The claim is
-- what decides between them, because an announcement can win the race
-- against any stage read that preceded it.
detachWithoutEvent
  ∷ HasCallStack ⇒ WindowHost → GraphicsOwner scene → GraphicsService → IO ReleaseAnswer
detachWithoutEvent host owner service =
  tryWithContext (detachWindowGraphics host service) >>= \case
    Left (failure ∷ ExceptionWithContext SomeException) → rethrowIO failure
    Right DetachAbsent → pure (ReleaseNoOp DetachAbsent)
    Right _ → do
      settled ← retireStranded host owner (graphicsAttachment service)
      pure (if settled then ReleaseSettled else ReleaseOwnerRetires)

-- ---------------------------------------------------------------------------
-- Port reservations

-- | Hold room for one lifetime event, so a handover that cannot be announced
-- is refused before it reserves a window's slot.
-- | What a reservation attempt found.
data Reservation
  = ReservationHeld
  | ReservationFull
    -- ^ The port is open and every place in it is spoken for.
  | ReservationClosed
    -- ^ Admission has ended. Nothing the port carries can be delivered again,
    -- so a caller must not go on to attach something the owner will never
    -- hear of.
  deriving (Eq, Show)

-- | Hold room for one lifetime event, so a handover that cannot be announced
-- is refused before it reserves a window's slot.
--
-- Closure is checked here rather than at the send, because the two answers
-- mean different things to a caller: a full port may have room in a moment
-- and is worth retrying, while a closed one never will. Discovering closure
-- only at the send would mean attaching first and settling afterwards, once
-- per attempt, on an owner that will take no further round.
reserveEvent ∷ GraphicsOwner scene → STM Reservation
reserveEvent owner = do
  open ← targetEventsOpen (ownerHandoff' owner)
  capacity ← handoffEventCapacity (ownerHandoff' owner)
  queued ← pendingTargetEvents (ownerHandoff' owner)
  held ← readTVar (ownerReservations owner)
  if not open
    then pure ReservationClosed
    else
      if queued + held >= capacity
        then pure ReservationFull
        else ReservationHeld <$ writeTVar (ownerReservations owner) (held + 1)

-- | Give back a reservation the caller did not spend.
releaseEvent ∷ GraphicsOwner scene → STM ()
releaseEvent owner = modifyTVar' (ownerReservations owner) (\held → if held == 0 then 0 else held - 1)

-- | Spend a held reservation on one event. The room was held, so this is never
-- refused for fullness; a closed port still refuses.
sendReservedEvent ∷ GraphicsOwner scene → Prepared TargetEvent → STM EventAdmission
sendReservedEvent owner payload = do
  admitted ← offerTargetEvent (ownerHandoff' owner) payload
  releaseEvent owner
  pure admitted

-- ---------------------------------------------------------------------------
-- The attachment protocol every owner target is registered under

-- | The protocol the main thread registers for an owner target.
--
-- 'handOverGraphicsTarget' registers it. It is public for the caller that
-- attaches through 'Hetoimasia.Runtime.GLFW.attachWindowGraphics' itself and
-- announces afterwards: an attachment registered under any other protocol is
-- one the owner can never publish evidence for, because the acknowledgement
-- it would publish under was given to that other protocol.
--
-- Its step performs no owner work, which is exactly D-33's rule for the main
-- thread: it reports what the owner has published and waits. It establishes no
-- retirement fact of its own — the evidence is the owner's — and it certifies
-- one only to transport a fact the owner's own terminal record already holds
-- and the completion publisher could not carry.
graphicsTargetProtocol ∷ WindowHost → GraphicsOwner scene → AttachmentProtocol
graphicsTargetProtocol host owner =
  AttachmentProtocol
    { -- Construction is the owner's, on the owner's thread. Registering the
      -- attachment here — before the owner has built anything — is what makes
      -- the window's slot, and therefore the window itself, retained from the
      -- first instant.
      protocolConstruct = \target acknowledgement →
        atomically (recordRegistered owner target acknowledgement)
    , protocolRollback = pure RollbackSafe
    , protocolStep = \target acknowledgement → ownerAwaitStep host owner target acknowledgement
    , protocolCompletion = FiniteCompletion
    , protocolDisposition = Required
    , protocolRecognizes = \_ → pure False
    }

-- | One bounded main-thread opportunity for an owner target.
--
-- It returns at once, having done no owner work:
--
-- * when the owner has written this target's terminal record, the step
--   /transports/ the facts that record establishes, on the owner thread, and
--   nothing more. It establishes nothing: the evidence existed before the step
--   ran, and a record is only ever written by the owner against what an
--   injected operation returned. It offers every one of them each time,
--   because the completion publisher's admission says only that the transport
--   took a notice — a notice offered before the attachment began retiring is
--   admitted and then refused by the model, so "admitted" is never proof the
--   model holds the fact. A duplicate is answered as one and changes nothing;
--   the step advances only when something was really recorded;
-- * an owner whose run has ended without this target's record leaves no
--   progress path at all, so the step stalls: the window, the session, and
--   every parent stay retained, and only independent evidence revives it;
-- * otherwise it waits, naming the owner's own published deadline when it has
--   one so a running scheduled loop is not delayed past it.
ownerAwaitStep
  ∷ WindowHost → GraphicsOwner scene → AttachmentId → Acknowledgement → IO RetirementProgress
ownerAwaitStep host owner target acknowledgement = do
  record ← atomically (targetTerminal (ownerHandoff' owner) target)
  case record of
    Just _ → do
      answers ← forM allRetirementFacts $ \fact → do
        answered ← certifyGraphicsFact host acknowledgement fact
        when (isJust answered) (atomically (recordPublishedFact (ownerHandoff' owner) target fact))
        pure answered
      pure (if any recorded answers then RetirementAdvanced else RetirementAwaiting)
    Nothing → do
      -- No record, so the owner has established nothing for this target. If
      -- the ledger still says nobody was ever told about it — an
      -- announcement refused, or a close that won before one was made — then
      -- nothing of the owner's exists for it and this step settles it. It is
      -- the same claim every other path makes and under the same condition,
      -- and having it here is what makes it a backstop: a retirement the
      -- main thread began without a release of its own arrives here and
      -- nowhere else.
      settled ← retireStranded host owner target
      if settled
        then pure RetirementAdvanced
        else atomically $ do
          terminal ← ownerTerminal (ownerHandoff' owner)
          status ← readOwnerStatus (ownerHandoff' owner)
          pure $
            if ownerRunEnded terminal
              then RetirementStalled
              else maybe RetirementAwaiting RetirementAwaitingUntil (statusNextDeadline status)
  where
    recorded = \case
      Just (FactRecorded _) → True
      Just AttachmentNowRetired → True
      _ → False
