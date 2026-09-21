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
-- | The acknowledgements | This lifetime    | The main thread writes at       | Any    | The host's lifetime | Never removed: a published    |
-- |                      |                  | registration; the owner reads   |        |                     | fact may be owed after the    |
-- |                      |                  |                                 |        |                     | target's own state is gone    |
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
  , readOwnerTargets
  , TargetStanding (..)
  , readTargetStanding
  , ownerTargetAcknowledgement
  , awaitOwnerRound
  , wakeGraphicsHost

    -- * The additive protected-host constructor
  , withGraphicsOwnerHost
  , withGraphicsOwnerHostIn
  , runGraphicsOwnerApplication
  , superviseGraphicsOwner

    -- * Handing targets over, and taking them back
  , GraphicsHandover (..)
  , handOverGraphicsTarget
  , announceGraphicsTarget
  , releaseGraphicsTarget
  , ReleaseAnswer (..)
  , publishGraphicsObservation

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
  , rethrowIO
  , throwIO
  , toException
  , tryWithContext
  )
import Control.Exception.Context (emptyExceptionContext)
import Control.Monad (foldM, forM, forM_, unless, void, when)
import Data.Foldable (for_, traverse_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
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
  ( StopToken
  , Worker
  , WorkerGroup
  , awaitStartup
  , closeWorkerGroup
  , pollCompletion
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
  , hostGraphicsPublisher
  , hostWakeNotifier
  , publishCompletion
  , retirementEnvironmentOf
  , runProtectedWindowApplication
  , withProtectedWindowHostOver
  )
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
  , ownerFailureDisposition ∷ !Disposition
    -- ^ What a terminal owner failure means for the application, at the
    -- supervision sentinel 'superviseGraphicsOwner' registers.
  }

-- | A configuration over the given operations and initial scene: the label
-- @graphics-owner@, a lifetime port of sixteen events, the process timer, and
-- a required disposition.
graphicsOwnerConfig ∷ GraphicsOperations scene → Prepared scene → GraphicsOwnerConfig scene
graphicsOwnerConfig operations scene =
  GraphicsOwnerConfig
    { ownerOperations = operations
    , ownerLabel = "graphics-owner"
    , ownerScene = scene
    , ownerEventCapacity = 16
    , ownerClockTimer = realtimeOwnerTimer
    , ownerFailureDisposition = Required
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
-- The owner handle

-- | One running supervised graphics owner.
--
-- Its representation is private: no worker group, no backend operation, and no
-- authority over the host can be taken from it.
data GraphicsOwner scene = GraphicsOwner
  { ownerHandoff' ∷ !(OwnerHandoff scene)
  , ownerWorkerHandle ∷ !(Worker ())
  , ownerGroup ∷ !WorkerGroup
  , ownerLatch ∷ !(TVar (Maybe (ExceptionWithContext SomeException)))
  , ownerTargets ∷ !(TVar (Map AttachmentId TargetState))
  , ownerAcknowledged ∷ !(TVar (Map AttachmentId Acknowledgement))
  , ownerGeometryCells ∷ !(TVar (Map AttachmentId TargetGeometry))
  , ownerStarted ∷ !(TVar Bool)
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

-- | What the owner's own construction of one target settled as, or 'Nothing'
-- once the owner no longer holds it.
readTargetStanding ∷ GraphicsOwner scene → AttachmentId → STM (Maybe TargetStanding)
readTargetStanding owner target =
  fmap (standingOf . targetConstruction) . Map.lookup target <$> readTVar (ownerTargets owner)

-- | The terminal owner failure, latched as soon as it was known.
readOwnerFailure ∷ GraphicsOwner scene → STM (Maybe (ExceptionWithContext SomeException))
readOwnerFailure = readTVar . ownerLatch

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
ownerTargetAcknowledgement owner target = Map.lookup target <$> readTVar (ownerAcknowledged owner)

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
wakeGraphicsHost owner = do
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
  ∷ WorkerGroup → WindowHost → GraphicsOwnerConfig scene → IO (GraphicsOwner scene)
startGraphicsOwner group host config = do
  publisher ← maybe (throwIO OwnerHostUnprotected) pure (hostGraphicsPublisher host)
  handoff ←
    newOwnerHandoff
      (hostWindowLimit (hostConfiguration host))
      (max 1 (ownerEventCapacity config))
      (ownerScene config)
  latch ← newTVarIO Nothing
  targets ← newTVarIO Map.empty
  acknowledged ← newTVarIO Map.empty
  geometry ← newTVarIO Map.empty
  started ← newTVarIO False
  reservations ← newTVarIO 0
  let partial worker =
        GraphicsOwner
          handoff
          worker
          group
          latch
          targets
          acknowledged
          geometry
          started
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
  outcome ←
    startWorkerWith group definition (\worker → writeIORef built (Just (partial worker))) awaitStartup
  case outcome of
    Left _ → throwIO OwnerHostUnprotected
    Right (worker, _) → pure (partial worker)

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
      when (isNothing held) (writeTVar (ownerLatch owner) (Just failure))
    -- No further target may be handed over to an owner that has ended.
    closeTargetEvents (ownerHandoff' owner)

-- ---------------------------------------------------------------------------
-- The run loop

-- | The owner's own body: start the backend, then take rounds until a stop.
ownerRun ∷ GraphicsOwner scene → StopToken → IO ()
ownerRun owner token = do
  _ ← graphicsStartOwner operations (OwnerStart (ownerLabel (ownerSettings owner))) >>= evaluate
  -- Recorded as /status/ and nowhere that could be mistaken for permission:
  -- what a successful startup establishes is that whole-owner retirement and
  -- destruction have something to act on, which the drain is told.
  atomically $ do
    writeTVar (ownerStarted owner) True
    writeOwnerPhase (ownerHandoff' owner) OwnerRunning
  wakeGraphicsHost owner
  loop
  where
    operations = ownerOperations (ownerSettings owner)
    loop = do
      stopping ← atomically (stopRequested token)
      unless stopping $ do
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
  constructPending owner
  foldObservations owner
  retireReleased owner
  publishOwed owner
  stopping ← atomically (stopRequested token)
  if stopping
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
    scene ← readOwnerScene handoff
    demand ← readOwnerDemand handoff
    states ← readTVar (ownerTargets owner)
    geometry ← readTVar (ownerGeometryCells owner)
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
  where
    fold' states = \case
      TargetAttached target acknowledgement →
        Map.insertWith
          (\_ existing → existing)
          target
          (TargetState acknowledgement ConstructionPending 0 initialEligibility False)
          states
      TargetReleased target → Map.adjust (\state → state {targetReleasing = True}) target states

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
constructPending owner = do
  states ← readTVarIO (ownerTargets owner)
  forM_ [target | (target, state) ← Map.toAscList states, pending (targetConstruction state)] $ \target → do
    attempted ←
      tryWithContext
        ( graphicsConstructTarget
            (ownerOperations (ownerSettings owner))
            (TargetStart target (attachmentWindow target) (attachmentIncarnation target))
            >>= evaluate
        )
    case attempted of
      Left failure → do
        settle target ConstructionUnverified
        retainFailure owner failure
      Right (TargetConstructed evidence) → settle target (ConstructionAccepted evidence)
      Right (TargetPartial evidence) → settle target (ConstructionPartial evidence)
      Right (TargetRolledBack evidence) → settle target (ConstructionRolledBack evidence)
  where
    pending = \case
      ConstructionPending → True
      _ → False
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
        -- mistake the attempt for the fact, and the target stays in the
        -- owner's table.
        Left failure → retainFailure owner failure
        Right retired → settle (evidenceDetail retired)
  where
    settle evidence = do
      atomically $ do
        recordTargetTerminal (ownerHandoff' owner) target evidence allRetirementFacts
        modifyTVar' (ownerTargets owner) (Map.delete target)
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
  acknowledgements ← readTVarIO (ownerAcknowledged owner)
  forM_ (Map.toAscList records) $ \(target, record) →
    unless (null (terminalOwed record)) $
      for_ (Map.lookup target acknowledgements) (publishTerminal owner target)

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

-- | Wait for the next thing worth a round: a stop, a lifetime event, a fresher
-- observation, or the owner's own deadline.
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
    queued ← (> 0) <$> pendingTargetEvents handoff
    fresher ← observationsAdvanced owner
    elapsed ← expired
    check (stopping || queued || fresher || elapsed)
  where
    handoff = ownerHandoff' owner
    OwnerTimer arm = ownerClockTimer (ownerSettings owner)

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
      either (`absorbOwnerFailure` retired) (const retired)
        <$> tryWithContext (restore (publishOwed owner))

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
  | ownerFailureDisposition (ownerSettings owner) /= Required = pure ()
  | otherwise = atomically $ do
      held ← readTVar (ownerLatch owner)
      when (isNothing held) (writeTVar (ownerLatch owner) (Just failure))

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

withGraphicsOwnerHostOver
  ∷ Logger
  → Maybe (Scoped Session)
  → HostConfig
  → GraphicsOwnerConfig scene
  → (WindowHost → GraphicsOwner scene → IO r)
  → IO r
withGraphicsOwnerHostOver logger sessionScope config ownerConfig use = do
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
    withProtectedWindowHostOver exit logger sessionScope config $ \host → do
      owner ← startGraphicsOwner group host ownerConfig
      writeIORef pending (Just owner)
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
        , policyDisposition = ownerFailureDisposition (ownerSettings owner)
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
              pure held
            traverse_ rethrowIO latched
        )

-- | Close the owner's ordinary admission and ask it to stop.
--
-- The order matters: the host's own quiescence has already closed attachment
-- admission, so nothing can reserve a port slot after this closes the port,
-- and an attachment that got past admission always found the port open.
beginOwnerExit ∷ GraphicsOwner scene → IO ()
beginOwnerExit owner = atomically $ do
  closeTargetEvents (ownerHandoff' owner)
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
  -- The join, after destruction and before the host releases a single window.
  _ ← closeWorkerGroup (ownerGroup owner)
  terminal ← atomically (ownerTerminal (ownerHandoff' owner))
  latched ← readTVarIO (ownerLatch owner)
  unverified ← readTVarIO (ownerTargets owner)
  unverifiedAnswer ←
    if isJust (ownerDestroyedEvidence terminal)
      then pure []
      else do
        logWarning
          logger
          graphicsOwnerComponent
          "The graphics owner ended without verified destruction; its shared state is retained"
          [ ("retired", Text.pack (show (isJust (ownerRetiredEvidence terminal))))
          , ("unverified-targets", Text.pack (show (Map.size unverified)))
          ]
        pure
          [ ExceptionWithContext
              emptyExceptionContext
              (toException (OwnerDestructionUnverified (isJust (ownerRetiredEvidence terminal)) (Map.size unverified)))
          ]
  -- Everything this exit found, in the order it found it: what the wait
  -- absorbed, then the missing destruction, then the owner's own latched
  -- failure. Each is re-raised only now, after the join, so nothing here could
  -- have released a borrowed parent early.
  case awaited <> unverifiedAnswer <> maybe [] pure latched of
    [] → pure ()
    primary : retained → raiseRetainingOwner primary retained

-- | Service the host's bounded native housekeeping until the owner's injected
-- destruction has answered, or its run has ended.
--
-- The main thread performs no owner work here. It polls and waits for native
-- events and retries window retirement — which is exactly what the host's own
-- retirement environment lends the attachment drain, bounded per turn by the
-- host's configured idle wait — and nothing else. The owner's own wake ends
-- each wait as soon as it has something to report.
--
-- It raises nothing. A native pump that fails withdraws itself, its failure
-- kept once rather than repeated every turn, and the wait then runs under a
-- finite timer of the same bound so the owner's evidence can still arrive. A
-- cancellation is absorbed and handed back for the caller to re-raise after
-- the join: cutting this wait short would be exactly the early release of a
-- borrowed parent D-33 forbids, and repeated cancellation may not achieve it
-- either.
awaitOwnerDestruction
  ∷ (∀ a. IO a → IO a)
  → Logger
  → WindowHost
  → GraphicsOwner scene
  → IO [ExceptionWithContext SomeException]
awaitOwnerDestruction restore logger host owner = loop True []
  where
    environment = retirementEnvironmentOf logger host
    bound = max 1 (round (environmentBound environment * 1e6))
    settledNow = do
      terminal ← ownerTerminal (ownerHandoff' owner)
      ended ← isJust <$> pollCompletion (ownerWorkerHandle owner)
      pure (isJust (ownerDestroyedEvidence terminal) || ownerRunEnded terminal || ended)
    attempt found action =
      tryWithContext action >>= \case
        Right () → pure (True, found)
        Left caught@(ExceptionWithContext _ (failure ∷ SomeException))
          | isAsynchronous failure → pure (True, found <> [caught])
          | otherwise → pure (False, found <> [caught])
    loop pumping found = do
      done ← atomically settledNow
      if done
        then pure found
        else
          if pumping
            then do
              (keeps, waited) ← attempt found (restore (environmentAwait environment >>= evaluate))
              (_, retired) ← attempt waited (restore (environmentRetireWindows environment >>= evaluate))
              loop keeps retired
            else do
              expired ← registerDelay bound
              (_, timed) ←
                attempt
                  found
                  (restore (atomically (readTVar expired >>= \elapsed → check elapsed)))
              loop False timed

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
  deriving (Show)

-- | Reserve one open window's exclusive graphics slot for the owner, on the
-- main thread, and hand the target over.
--
-- The port's room is held /before/ anything is reserved, so a full port is
-- answered with nothing attached rather than with an attachment the owner was
-- never told about.
handOverGraphicsTarget ∷ WindowHost → GraphicsOwner scene → WindowId → IO GraphicsHandover
handOverGraphicsTarget host owner window = do
  reserved ← atomically (reserveEvent owner)
  if not reserved
    then pure HandoverPortFull
    else
      tryWithContext (attachWindowGraphics host window (ownerTargetProtocol host owner)) >>= \case
        Left (failure ∷ ExceptionWithContext SomeException) → do
          atomically (releaseEvent owner)
          rethrowIO failure
        Right (GraphicsAttached service) →
          announceReserved owner service >>= \case
            EventAdmitted → pure (TargetHandedOver service)
            -- Unreachable while the host's quiescence closes attachment
            -- admission before the port closes: an attachment that got this
            -- far found the port open. Answered rather than asserted, and the
            -- attachment is detached so nothing is left for an owner that will
            -- never hear of it.
            _ → HandoverOwnerClosed <$ detachWindowGraphics host service
        Right (GraphicsRefused refusal) → do
          atomically (releaseEvent owner)
          pure (HandoverRefused refusal)
        Right other → do
          atomically (releaseEvent owner)
          throwIO (OwnerHandoverUnsettled (Text.pack (show other)))

-- | Tell the owner about a target, for a caller that attached it through
-- 'Hetoimasia.Runtime.GLFW.attachWindowGraphics' itself, or that must offer
-- the same event again after 'HandoverPortFull'.
announceGraphicsTarget ∷ GraphicsOwner scene → GraphicsService → IO EventAdmission
announceGraphicsTarget owner service = do
  reserved ← atomically (reserveEvent owner)
  if not reserved then pure EventRefusedFull else announceReserved owner service

-- | Open the target's observation slot and spend the held reservation.
announceReserved ∷ GraphicsOwner scene → GraphicsService → IO EventAdmission
announceReserved owner service = do
  acknowledgement ← atomically (Map.lookup target <$> readTVar (ownerAcknowledged owner))
  case acknowledgement of
    Nothing → EventPortClosed <$ atomically (releaseEvent owner)
    Just held → do
      _ ← openTargetSlot (ownerHandoff' owner) target
      payload ← prepare (TargetAttached target held)
      admitted ← atomically (sendReservedEvent owner payload)
      unless (admitted == EventAdmitted) (atomically (closeTargetSlot (ownerHandoff' owner) target))
      pure admitted
  where
    target = graphicsAttachment service

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
  | ReleaseNoOp !DetachAnswer
  | ReleasePortFull
    -- ^ The owner's port could not take the event, so nothing was detached.
  deriving (Show)

-- | Retire one target, leaving the owner and every other target live.
--
-- This is D-33's individual close, not its whole-session exit: nothing here
-- joins the owner, retires it, or destroys anything it shares.
releaseGraphicsTarget ∷ WindowHost → GraphicsOwner scene → GraphicsService → IO ReleaseAnswer
releaseGraphicsTarget host owner service = do
  reserved ← atomically (reserveEvent owner)
  if not reserved
    then pure ReleasePortFull
    else
      detachWindowGraphics host service >>= \case
        DetachBegun → do
          payload ← prepare (TargetReleased (graphicsAttachment service))
          _ ← atomically (sendReservedEvent owner payload)
          pure ReleaseBegun
        other → do
          atomically (releaseEvent owner)
          pure (ReleaseNoOp other)

-- ---------------------------------------------------------------------------
-- Port reservations

-- | Hold room for one lifetime event, so a handover that cannot be announced
-- is refused before it reserves a window's slot.
reserveEvent ∷ GraphicsOwner scene → STM Bool
reserveEvent owner = do
  capacity ← handoffEventCapacity (ownerHandoff' owner)
  queued ← pendingTargetEvents (ownerHandoff' owner)
  held ← readTVar (ownerReservations owner)
  if queued + held >= capacity
    then pure False
    else True <$ writeTVar (ownerReservations owner) (held + 1)

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
-- Its step performs no owner work, which is exactly D-33's rule for the main
-- thread: it reports what the owner has published and waits. It establishes no
-- retirement fact of its own — the evidence is the owner's — and it certifies
-- one only to transport a fact the owner's own terminal record already holds
-- and the completion publisher could not carry.
ownerTargetProtocol ∷ WindowHost → GraphicsOwner scene → AttachmentProtocol
ownerTargetProtocol host owner =
  AttachmentProtocol
    { -- Construction is the owner's, on the owner's thread. Registering the
      -- attachment here — before the owner has built anything — is what makes
      -- the window's slot, and therefore the window itself, retained from the
      -- first instant.
      protocolConstruct = \target acknowledgement →
        atomically (modifyTVar' (ownerAcknowledged owner) (Map.insert target acknowledgement))
    , protocolRollback = pure RollbackSafe
    , protocolStep = \target acknowledgement → ownerAwaitStep host owner target acknowledgement
    , protocolCompletion = FiniteCompletion
    , protocolDisposition = ownerFailureDisposition (ownerSettings owner)
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
    Nothing → atomically $ do
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
