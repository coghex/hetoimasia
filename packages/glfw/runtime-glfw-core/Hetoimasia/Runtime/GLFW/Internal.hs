-- | The implementation of "Hetoimasia.Runtime.GLFW", with the test-only host
-- hooks the package's own dynamic window examples use to deliver a cancellation
-- at a precise point.
--
-- This module belongs to the private @runtime-glfw-core@ sublibrary, so no
-- package outside @hetoimasia-glfw@ can import it. The public
-- "Hetoimasia.Runtime.GLFW" re-exports everything here except 'HostHooks',
-- 'noHostHooks', and 'allocWindowHostWith', and carries the contract.
module Hetoimasia.Runtime.GLFW.Internal
  ( -- * Hosts
    WindowHost
  , allocWindowHost
  , allocWindowHostIn
  , allocWindowHostWith
  , HostHooks (..)
  , noHostHooks
  , hostMonitors
  , hostCommandPort
  , hostCommandStatistics
  , quiesceWindowHost
  , HostActivity (..)
  , hostActivity
  , hostWindowCapabilities

    -- * The wake path
  , hostWakePath
  , hostNotificationsInFlight
  , reportHostWakeDegradation

    -- * Demand
  , hostDemandPublisher
  , captureHostDemand
  , captureWindowDemand
  , hostDemandStatus
  , windowDemandStatus

    -- * Windows
  , hostWindowIdentities
  , hostWindowClient
  , withHostWindow
  , closeHostWindow
  , honourHostCloseRequest
  , CloseStart (..)
  , HostBookkeeping (..)
  , hostBookkeeping

    -- * Configuration
  , HostConfig (..)
  , defaultHostConfig
  , validateHostConfig
  , HostConfigRejected (..)
  , maximumWindowLimit
  , hostComponent

    -- * The owner loop
  , runOwnerLoop
  , LoopHooks (..)
  , noApplicationEvents
  , Turn (..)
  , TurnStep (..)
  , rejectHostCloseRequest

    -- * The scheduled owner loop
  , runScheduledOwnerLoop
  , ScheduledHooks (..)
  , defaultScheduledHooks
  , noApplicationReadiness
  , ScheduledTurn (..)
  , TurnPacing (..)
  , UpdateSchedule (..)
  , ScheduledStep (..)

    -- * The protected host lifetime
  , withProtectedWindowHost
  , withProtectedWindowHostIn
  , withProtectedWindowHostWith
  , runProtectedWindowApplication

    -- * The private attachment seam
  , hostAttachmentIdentity
  , attachHostWindow
  , hostCompletionPublisher
  , hostPendingAttachments
  , hostAttachmentView
  , reportHostRetirementFact
  , AttachmentProtocol (..)
  , CompletionPolicy (..)
  , RetirementProgress (..)
  , AttachmentOutcome (..)
  , RolledBack (..)
  , MetadataRejection (..)
  , faultHostAttachmentMetadata

    -- * The public attachment contract
  , AttachmentId
  , attachmentWindow
  , attachmentIncarnation
  , Acknowledgement
  , acknowledgedAttachment
  , GraphicsRefusal (..)
  , RetirementFact (..)
  , allRetirementFacts
  , RollbackOutcome (..)
  , FactAnswer (..)
  , CompletionNotice
  , completionNotice
  , NoticeAdmission (..)
  , CompletionPublisher
  , CompletionPublication (..)
  , publishCompletion
  , GraphicsService
  , graphicsWindow
  , graphicsAttachment
  , graphicsIncarnation
  , readGraphicsService
  , GraphicsObservation (..)
  , SlotState (..)
  , NativeDisposal (..)
  , WindowGraphics (..)
  , windowGraphicsService
  , GraphicsAttachment (..)
  , attachWindowGraphics
  , detachWindowGraphics
  , DetachAnswer (..)
  , windowGraphicsStatus
  , hostGraphicsPublisher
  , certifyGraphicsFact
  , RetirementDemand (..)
  , noRetirementDemand
  , hostRetirementDemand

    -- * Applications
  , runWindowApplication
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , bracket_
  , finally
  , fromException
  , mask
  , rethrowIO
  , toException
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Exception.Context (emptyExceptionContext)
import Control.Monad (forM, forM_, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, Logger, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Channel (maximumCapacity)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (SnapshotReader, observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource
  ( Scoped
  , allocResource
  , cleanupFailureException
  , cleanupFailuresInContext
  , withResourceLabelled
  , withScoped
  )
import Hetoimasia.Foundation.Resource.Collection
  ( Collection
  , CollectionError (..)
  , Member
  , MemberStatus (..)
  , Retirement (..)
  , acquireMemberThen
  , allocCollection
  , liveMemberCount
  , memberStatus
  , retireMember
  , withMember
  )
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRejected
  , DurationRequirement (RequirePositive)
  , Instant
  , MonotonicSource
  , convertedDuration
  , convertedRounding
  , deadlineReached
  , durationFromNanoseconds
  , durationFromSeconds
  , durationNanoseconds
  , monotonicSource
  , readInstant
  , remainingUntil
  )
import Hetoimasia.GLFW.Command
  ( CommandRejection (..)
  , CommandResult (..)
  , CommandStatistics (..)
  , WindowClient
  , WindowCommandHost
  , WindowCommandPort
  , closeWindowCommands
  , commandStatistics
  , newWindowCommandHost
  , windowCommandPort
  )
import Hetoimasia.GLFW.Internal.Command
  ( CommandOrigin
  , Execution (..)
  , ExecutionStep (..)
  , WindowCommand (..)
  , commandHostNotifier
  , commandsAdmissionClosed
  , executeNextWith
  , nativeRejectionOf
  , newWindowClient
  , newWindowPortHost
  , controlDisposition
  , modeDisposition
  , observeWindow
  )
import Hetoimasia.GLFW.Internal.Control (WindowCapabilities)
import Hetoimasia.GLFW.Internal.Demand
  ( CapturedDemand (..)
  , DemandPublisher
  , DemandSlot
  , DemandStatus
  , captureDemand
  , closeDemandSlot
  , demandDeadline
  , demandIsImmediate
  , demandPublisher
  , demandStatus
  , newDemandSlot
  )
import Hetoimasia.GLFW.Internal.Notify
  ( DegradationAttempt
  , Notifier
  , attemptDegradationReportWith
  , awaitNotificationsSettled
  , notificationsInFlight
  )
import Hetoimasia.GLFW.Internal.Input
  ( InputFeed
  , attemptOverflowWarning
  , closeInputFeed
  , feedControl
  , feedReader
  , newInputFeed
  , resumeInput
  )
import Hetoimasia.GLFW.Internal.Session
  ( WakePath
  , ownerOperation
  , reconcileMonitorEvents
  , sessionIdentity
  , sessionTrace
  , sessionWakePath
  , sessionWindowCapabilities
  )
import Hetoimasia.GLFW.Internal.Trace (TraceEvent (TurnBegan), recordTrace)
import Hetoimasia.GLFW.Internal.Attachment
  ( Acknowledgement
  , AttachmentId
  , AttachmentPhase (..)
  , AttachmentRefusal
  , AttachmentView
  , CompletionNotice
  , FactAnswer (..)
  , HostIdentity
  , NoticeAdmission (..)
  , RetirementFact (..)
  , RollbackOutcome (..)
  , acknowledgedAttachment
  , activeAttachment
  , allRetirementFacts
  , attachmentIncarnation
  , attachmentWindow
  , completionNotice
  )
import qualified Hetoimasia.GLFW.Internal.Attachment as Model
import Hetoimasia.Runtime.GLFW.Internal.Graphics
  ( GraphicsCell
  , GraphicsObservation (..)
  , GraphicsService
  , NativeDisposal (..)
  , SlotState (..)
  , WindowGraphics (..)
  , graphicsAttachment
  , graphicsIncarnation
  , graphicsWindow
  , newGraphicsCell
  , readGraphicsCell
  , readGraphicsService
  , serviceFor
  , writeGraphicsDisposal
  , writeGraphicsSlot
  )
import Hetoimasia.Runtime.GLFW.Internal.Retirement
  ( AttachmentOutcome (..)
  , AttachmentProtocol (..)
  , CompletionPolicy (..)
  , CompletionPublication (..)
  , CompletionPublisher
  , DetachAnswer (..)
  , DrainOutcome (..)
  , MetadataRejection (..)
  , ProgressRound (..)
  , RolledBack (..)
  , HostRetirement
  , RetirementEnvironment (..)
  , RetirementProgress (..)
  , advanceRetirements
  , anyRetiring
  , attachRetirement
  , cancelAttachment
  , attachmentViewOf
  , certifyRetirementFact
  , closeAttachmentAdmission
  , completionPublisher
  , detachAttachment
  , drainRetirement
  , faultProtocolMetadata
  , forgetRetiredWindow
  , newHostRetirement
  , pendingAttachments
  , publishCompletion
  , recordClosingWindow
  , recordRegisteredWindow
  , retirementIdentity
  , retirementStanding
  , windowAttachmentState
  , windowRetirementVeto
  )
import Hetoimasia.GLFW.Internal.Window
  ( EventProcessing (..)
  , attachWindowInputFeed
  , beginWindowClosing
  , processWindowEvents
  , reconcileWindowEvents
  , reconcileWindowMode
  , rejectCloseRequest
  , windowAssembly
  )
import Hetoimasia.GLFW.Monitor (MonitorInventory, monitorInventory)
import Hetoimasia.GLFW.Session (Session, SessionConfig, SessionMisuse (SessionPoisoned), allocSession, defaultSessionConfig)
import Hetoimasia.GLFW.Window
  ( Attribute (Observed)
  , CloseRequest
  , Window
  , WindowConfig
  , WindowId
  , WindowResult (..)
  , closeRequestWindow
  , observedCloseRequest
  , observedFocused
  , validateWindowConfig
  , windowIdentity
  , windowLocalIdentity
  , windowObservations
  )
import Hetoimasia.Runtime.Application (runManagedApplication)
import Hetoimasia.Runtime.Logging (LoggingLifetime, lifetimeLogger, recordReport)
import Hetoimasia.Runtime.Reporting (ReportResult (ReportFailed), markDiagnostic, raisedByDiagnostic)
import Hetoimasia.Runtime.Supervision (RuntimeControl, checkRuntime)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Configuration

-- | What a host is built from. A pure value, validated before anything is
-- acquired.
data HostConfig = HostConfig
  { hostSessionConfig ∷ !SessionConfig
    -- ^ The session 'allocWindowHost' enters. 'allocWindowHostIn' ignores it.
  , hostWindowConfigs ∷ ![WindowConfig]
    -- ^ The windows created when the host is built, in order. It may be empty.
  , hostWindowLimit ∷ !Int
    -- ^ The most windows the host holds live at once, closing windows included.
    -- At least one, at least as many as 'hostWindowConfigs', and at most
    -- 'maximumWindowLimit'.
  , hostCommandCapacity ∷ !Integer
    -- ^ How many commands the host's port, and each window's own port, holds
    -- queued.
  , hostInputCapacity ∷ !Integer
    -- ^ How many input events each window's feed holds queued. At least one,
    -- and at most 'Hetoimasia.Foundation.Messaging.Channel.maximumCapacity'.
  , hostCommandBudget ∷ !Int
    -- ^ The most commands one turn attempts, across every port. At least one.
  , hostEventBudget ∷ !Int
    -- ^ The most application events one turn dispatches. At least one.
  , hostRetirementBudget ∷ !Int
    -- ^ The most attachment retirement opportunities one turn offers, across
    -- every window with a pending retirement. At least one. Pending retirements
    -- are served in rotating order, so one window's stalled or slow retirement
    -- can never starve another's, and an attachment no round has yet offered an
    -- opportunity to keeps the next turn immediate however short the budget
    -- fell. Once every one of them has been offered and is waiting, the turn
    -- waits toward the earliest instant they named, bounded by 'hostIdleWait':
    -- more waiting attachments than this budget is an ordinary idle host, not a
    -- reason to poll. An ordinary host holds no attachment, so nothing spends
    -- it.
  , hostIdleWait ∷ !Double
    -- ^ The most seconds an idle turn waits for a native event, and the
    -- scheduled path's fallback bound. Finite, above zero, at most
    -- 'maximumIdleWait', and at least one whole nanosecond, so it is always a
    -- positive 'Duration' that never exceeds the seconds configured.
  , hostClock ∷ !MonotonicSource
    -- ^ The monotonic source 'runScheduledOwnerLoop' samples, and the clock
    -- domain every deadline it is given belongs to. 'runOwnerLoop' never reads
    -- it. A seam example configures a 'Hetoimasia.Foundation.Time.scriptedSource'
    -- here and scripts every reading exactly.
  }

-- | Every field but the injected clock, which is an action rather than a value.
instance Show HostConfig where
  show config =
    "HostConfig {hostSessionConfig = "
      <> show (hostSessionConfig config)
      <> ", hostWindowConfigs = "
      <> show (hostWindowConfigs config)
      <> ", hostWindowLimit = "
      <> show (hostWindowLimit config)
      <> ", hostCommandCapacity = "
      <> show (hostCommandCapacity config)
      <> ", hostInputCapacity = "
      <> show (hostInputCapacity config)
      <> ", hostCommandBudget = "
      <> show (hostCommandBudget config)
      <> ", hostEventBudget = "
      <> show (hostEventBudget config)
      <> ", hostRetirementBudget = "
      <> show (hostRetirementBudget config)
      <> ", hostIdleWait = "
      <> show (hostIdleWait config)
      <> ", hostClock = <injected>}"

-- | The platform's own session, the given windows, a limit of 16 live windows,
-- a command capacity of 64, an input capacity of 256, command and event budgets
-- of 16, a retirement budget of 4, a 0.1-second idle wait, and the process's
-- monotonic clock.
defaultHostConfig ∷ [WindowConfig] → HostConfig
defaultHostConfig windows =
  HostConfig
    { hostSessionConfig = defaultSessionConfig
    , hostWindowConfigs = windows
    , hostWindowLimit = 16
    , hostCommandCapacity = 64
    , hostInputCapacity = 256
    , hostCommandBudget = 16
    , hostEventBudget = 16
    , hostRetirementBudget = 4
    , hostIdleWait = 0.1
    , hostClock = monotonicSource
    }

-- | A host configuration refused before anything was acquired.
data HostConfigRejected
  = CommandBudgetRejected !Int
  | EventBudgetRejected !Int
  | RetirementBudgetRejected !Int
  | IdleWaitRejected !Double
  | WindowLimitRejected !Int
    -- ^ The limit is below one, below the number of configured windows, or
    -- above 'maximumWindowLimit'.
  | InputCapacityRejected !Integer
  deriving (Eq, Show)

instance Exception HostConfigRejected

-- | The longest idle wait a configuration may ask for, in seconds.
maximumIdleWait ∷ Double
maximumIdleWait = 60

-- | The most live windows a configuration may ask for.
--
-- Far above what any platform hosts at once, and low enough that every count a
-- host derives from it — the protected host's completion inbox holds one notice
-- per retirement fact per window — is an exact 'Int', never a wrapped one. A
-- configuration above it is refused before anything is acquired, as one below
-- one is.
maximumWindowLimit ∷ Int
maximumWindowLimit = 1024

-- | Check the budgets, the idle wait, the window limit, and the input capacity.
-- The session, window, and command capacity settings are checked by the
-- operations they configure.
validateHostConfig ∷ HostConfig → Either HostConfigRejected ()
validateHostConfig config
  | hostCommandBudget config < 1 = Left (CommandBudgetRejected (hostCommandBudget config))
  | hostEventBudget config < 1 = Left (EventBudgetRejected (hostEventBudget config))
  | hostRetirementBudget config < 1 = Left (RetirementBudgetRejected (hostRetirementBudget config))
  -- Written so a NaN, which fails every comparison, is refused too.
  | not (wait > 0 && wait <= maximumIdleWait) = Left (IdleWaitRejected wait)
  -- A wait of less than a whole nanosecond is no bound the scheduled path could
  -- wait for, so it is refused here rather than rounded up to one.
  | Left _ ← idleWaitDuration config = Left (IdleWaitRejected wait)
  | limit < 1 || limit < length (hostWindowConfigs config) || limit > maximumWindowLimit =
      Left (WindowLimitRejected limit)
  | input < 1 || input > maximumCapacity = Left (InputCapacityRejected input)
  | otherwise = Right ()
  where
    wait = hostIdleWait config
    limit = hostWindowLimit config
    input = hostInputCapacity config

-- | The configured fallback bound as a positive 'Duration', or why those
-- seconds are none. 'validateHostConfig' refuses a configuration this rejects,
-- so an accepted host always has one.
--
-- The bound is an upper bound, so the conversion may never round up past the
-- seconds configured: 'durationFromSeconds' rounds to the nearest nanosecond
-- and reports the rounding it applied, and a positive rounding means the whole
-- nanosecond below is the real bound. A wait that floors to no nanoseconds at
-- all — anything under one, which nearest-rounding would otherwise accept as
-- one — is refused rather than lengthened.
idleWaitDuration ∷ HostConfig → Either DurationRejected Duration
idleWaitDuration config = do
  converted ← durationFromSeconds RequirePositive (hostIdleWait config)
  let nanoseconds = toInteger (durationNanoseconds (convertedDuration converted))
  durationFromNanoseconds
    RequirePositive
    (if convertedRounding converted > 0 then nanoseconds - 1 else nanoseconds)

-- | A duration as the seconds a native timed wait takes.
--
-- This is the GLFW layer's one conversion out of 'Duration', and the scheduled
-- loop waits only for a positive duration, so the value it passes to
-- 'AwaitEventsFor' is always finite and above zero.
waitSeconds ∷ Duration → Double
waitSeconds duration = fromIntegral (durationNanoseconds duration) / 1e9

-- | The component a host's own failures are attributed to.
hostComponent ∷ Component
hostComponent = unsafeComponent "glfw.runtime"

constructOperation, loopOperation, rejectOperation, borrowOperation, closeOperation, honourOperation, bookkeepingOperation, captureOperation, reportOperation, attachOperation, certifyOperation, detachOperation ∷ Operation
constructOperation = operation "construct window host"
loopOperation = operation "run owner loop"
rejectOperation = operation "reject close request"
borrowOperation = operation "borrow host window"
closeOperation = operation "close host window"
honourOperation = operation "honour close request"
bookkeepingOperation = operation "read host bookkeeping"
captureOperation = operation "capture demand"
reportOperation = operation "report wake degradation"
attachOperation = operation "attach host window"
certifyOperation = operation "certify retirement fact"
detachOperation = operation "detach window graphics"

-- ---------------------------------------------------------------------------
-- Hosts

-- | A session, the windows it owns through a scoped collection, and their
-- command bookkeeping, owned together. Its representation is private: no
-- session, collection, member, native handle, executor, or release authority
-- can be taken from it.
data WindowHost = WindowHost
  { hostSession ∷ !Session
  , hostCollection ∷ !Collection
  , hostCommands ∷ !WindowCommandHost
  , hostSettings ∷ !HostConfig
  , hostEntries ∷ !(TVar (Map WindowId HostEntry))
    -- ^ Every window registered and not yet retired, closing ones included.
  , hostBorrowed ∷ !(IORef (Map WindowId Int))
    -- ^ The windows borrowed on the owner thread, with their borrow counts.
  , hostSurfaced ∷ !(IORef (Map WindowId CloseRequest))
  , hostCursor ∷ !(IORef PortKey)
    -- ^ The port the last dispatch attempt served.
  , hostDemandSlot ∷ !DemandSlot
    -- ^ The application's one demand slot, lent to workers as a publisher.
  , hostActivityState ∷ !(TVar HostActivity)
  , hostHooks ∷ !HostHooks
  , hostRetirementState ∷ !(Maybe HostRetirement)
    -- ^ The attachment model and its owner authority, issued only by the
    -- protected lifetime. A host built by 'allocWindowHost' has none, so it can
    -- never be the target of an attachment.
  , hostRetireCursor ∷ !(IORef (Maybe AttachmentId))
    -- ^ The attachment the last turn's retirement round served last, which the
    -- next round rotates after.
  , hostRetirementDemandState ∷ !(TVar RetirementDemand)
    -- ^ What the last round of opportunities left owed, which the scheduled
    -- loop folds into the wait it chooses. Any thread may read it.
  , hostGraphicsCells ∷ !(TVar (Map WindowId GraphicsCell))
    -- ^ One observation cell per window that has an attachment the host has not
    -- yet finished with: never more than one per live window, so repeated
    -- detaching and reattaching grows nothing the host owns. A retained
    -- 'GraphicsService' keeps its own cell after the host drops it.
  }

-- | Where the private examples interrupt a host. Production passes
-- 'noHostHooks'.
data HostHooks = HostHooks
  { afterRegistration ∷ IO ()
    -- ^ Runs at the end of a window's registration, masked and with nothing
    -- interruptible before it: after the collection and the host have both
    -- registered the window, before its creation's result is published.
  , beforePublication ∷ IO ()
    -- ^ Runs inside 'attachWindowGraphics', after the attachment's construction
    -- has settled and before its service is published, so an example can reach
    -- exactly that handoff from another thread.
  , beforeConsumer ∷ WindowHost → IO ()
    -- ^ Runs on the protected lifetime's own consumer path: after its exit
    -- handler is installed and before the consumer it was given is entered, so
    -- whatever this attaches, and however it then fails, is drained exactly as
    -- the consumer's own attachments are. It never runs for a host built as an
    -- ordinary 'Scoped' value, which can hold no attachment.
  }

noHostHooks ∷ HostHooks
noHostHooks = HostHooks (pure ()) (pure ()) (\_ → pure ())

-- | One registered window: its collection member, its own command host, its
-- input feed, the capabilities handed to clients, and whether its close protocol
-- has begun.
data HostEntry = HostEntry
  { entryMember ∷ !(Member Window)
  , entryCommands ∷ !WindowCommandHost
  , entryInput ∷ !InputFeed
  , entryDemand ∷ !DemandSlot
  , entryClient ∷ !WindowClient
  , entryClosing ∷ !Bool
  }

-- | A command port's place in dispatch order: the host's port first, then each
-- window's in registration order.
data PortKey
  = HostPortKey
  | WindowPortKey !WindowId
  deriving (Eq, Ord)

-- | What the owner loop is doing, as clients may observe it.
data HostActivity = HostActivity
  { activityTurn ∷ !Natural
    -- ^ The turn whose event step last began; zero before the first.
  , activityWaiting ∷ !Bool
    -- ^ Whether the owner has begun that turn's finite native wait: set
    -- immediately before the native call and cleared once it returns.
  }
  deriving (Eq, Show)

-- | Enter a session and build a host in it for the rest of the enclosing scope,
-- on the process main thread.
--
-- The configuration is validated first. Then the session is entered, the
-- window collection allocated, the host's command port created, and each
-- configured window created in order as a collection member with its own port.
-- A failure at any stage releases what the stages before it acquired and
-- propagates. When the scope ends, every port's admission closes, every window
-- still registered is released, newest first, and the session ends.
allocWindowHost ∷ HasCallStack ⇒ HostConfig → Scoped WindowHost
allocWindowHost config = allocWindowHostIn (allocSession (hostSessionConfig config)) config

-- | 'allocWindowHost' over a session scope the caller supplies, such as a test
-- seam's session. The host owns the session only if that scope does.
allocWindowHostIn ∷ HasCallStack ⇒ Scoped Session → HostConfig → Scoped WindowHost
allocWindowHostIn = allocWindowHostWith noHostHooks

-- | 'allocWindowHostIn' with the private examples' hooks.
allocWindowHostWith ∷ HasCallStack ⇒ HostHooks → Scoped Session → HostConfig → Scoped WindowHost
allocWindowHostWith = allocHostOver Unprotected

-- | Whether a host owns retirement state, and so whether an attachment may
-- name it. Only 'withProtectedWindowHostWith' builds a 'Protected' one.
data HostProtection = Unprotected | Protected
  deriving (Eq, Show)

-- | The one host construction both lifetimes use. The protected one differs in
-- exactly one thing: it owns the retirement state its exit boundary drains.
allocHostOver ∷ HasCallStack ⇒ HostProtection → HostHooks → Scoped Session → HostConfig → Scoped WindowHost
allocHostOver protection hooks sessionScope config = do
  liftIO (either (throwFailure hostComponent constructOperation []) pure (validateHostConfig config))
  session ← sessionScope
  entries ← liftIO (newTVarIO Map.empty)
  cells ← liftIO (newTVarIO Map.empty)
  retirement ← liftIO $ case protection of
    Unprotected → pure Nothing
    Protected → Just <$> newHostRetirement (sessionIdentity session) (hostWindowLimit config)
  -- Released after the collection's own exit, which is the last thing that can
  -- destroy a window: a window nobody closed is released there and nowhere
  -- else, so this is where a service retained across it learns what that
  -- release settled its window as, and the last place its slot can be brought
  -- up to date. It only ever fills a disposal still pending.
  allocResource (pure ()) (\() → settleRetainedDisposals retirement entries cells)
  -- Released after every later part: the collection's exit releases the
  -- windows still registered once admission has closed.
  collection ← allocCollection (hostWindowLimit config)
  commands ← liftIO (newWindowCommandHost session (hostCommandCapacity config))
  demand ← liftIO newDemandSlot
  -- Released first: every port's admission, every demand slot, and attachment
  -- admission close before any window is released.
  owed ← liftIO (newTVarIO noRetirementDemand)
  allocResource
    (pure ())
    (\() → atomically (closeAdmission commands entries demand retirement cells owed))
  host ←
    liftIO $
      WindowHost session collection commands config entries
        <$> newIORef Map.empty
        <*> newIORef Map.empty
        <*> newIORef HostPortKey
        <*> pure demand
        <*> newTVarIO (HostActivity 0 False)
        <*> pure hooks
        <*> pure retirement
        <*> newIORef Nothing
        <*> pure owed
        <*> pure cells
  liftIO (mapM_ (registerWindow host) (hostWindowConfigs config))
  pure host

-- | The read endpoint of the host session's monitor inventory, which any thread
-- may read. It carries no native pointer and no authority to resolve an
-- identity; resolution is an owner-thread operation of "Hetoimasia.GLFW.Monitor".
hostMonitors ∷ WindowHost → SnapshotReader MonitorInventory
hostMonitors = monitorInventory . hostSession

-- | The host's own client port: the one port with creation authority, which
-- also serves observation and close requests for any window the host owns.
hostCommandPort ∷ WindowHost → WindowCommandPort
hostCommandPort = windowCommandPort . hostCommands

-- | The host port's command bookkeeping, read in one transaction.
hostCommandStatistics ∷ WindowHost → STM CommandStatistics
hostCommandStatistics = commandStatistics . hostCommands

-- | What the host session's windows cannot do or report on its backend. Any
-- thread may read it.
hostWindowCapabilities ∷ WindowHost → WindowCapabilities
hostWindowCapabilities = sessionWindowCapabilities . hostSession

-- | What the owner loop is doing.
hostActivity ∷ WindowHost → STM HostActivity
hostActivity = readTVar . hostActivityState

-- | Close the admission of the host's port and of every window's port, settle
-- every queued command as not executed, and close every window's input feed, in
-- the calling transaction. Finite, non-retrying, and idempotent; it destroys
-- nothing, pumps nothing, waits on nothing, and awaits no input acknowledgement.
quiesceWindowHost ∷ WindowHost → STM ()
quiesceWindowHost host =
  closeAdmission
    (hostCommands host)
    (hostEntries host)
    (hostDemandSlot host)
    (hostRetirementState host)
    (hostGraphicsCells host)
    (hostRetirementDemandState host)

closeAdmission
  ∷ WindowCommandHost
  → TVar (Map WindowId HostEntry)
  → DemandSlot
  → Maybe HostRetirement
  → TVar (Map WindowId GraphicsCell)
  → TVar RetirementDemand
  → STM ()
closeAdmission commands entries demand retirement cells owed = do
  void (closeWindowCommands commands)
  closeDemandSlot demand
  readTVar entries >>= mapM_ closeEntryAdmission
  -- A protected host ends new graphics use in the same finite step: every
  -- attachment still registering or active begins retiring, and no later one is
  -- admitted. It makes no GPU call and waits for nothing.
  mapM_ closeAttachmentAdmission retirement
  -- And every retained service learns it here, rather than on whichever owner
  -- turn happens to come next: a reader that saw the host quiesce must not still
  -- be told its owner is admitting use.
  refreshCells retirement cells
  -- Retirements that have just begun have never been offered an opportunity, so
  -- a turn that still runs must not wait before offering them one.
  demandRetirementNow retirement owed

-- | Tell every cell the host still holds how its window's own release ended.
--
-- 'retireClosing' writes the disposal of a window the close protocol retired;
-- a window nobody closed is released by the collection's exit instead, and this
-- runs after that exit for exactly those. It brings every cell's slot up to
-- date first, so a retirement the drain's last fold completed is never left
-- unreported beside a disposal that is. It reads each member's settled status
-- rather than assuming one, so a release that failed is reported as failed and
-- never as a destruction that happened, and it overwrites nothing: a disposal
-- already recorded stays as it was.
settleRetainedDisposals
  ∷ Maybe HostRetirement → TVar (Map WindowId HostEntry) → TVar (Map WindowId GraphicsCell) → IO ()
settleRetainedDisposals retirement entries cells = do
  -- Whatever the model settled last — a fact folded from a notice on the very
  -- round that ended the drain, for instance — is what every retained cell says
  -- before its disposal is written beside it.
  atomically (refreshCells retirement cells)
  held ← readTVarIO cells
  registered ← readTVarIO entries
  settled ← forM (Map.toList held) $ \(window, cell) →
    forM (Map.lookup window registered) (fmap ((,) cell . disposalOf) . memberStatus . entryMember)
  atomically . forM_ (catMaybes settled) $ \(cell, disposal) → do
    observed ← readGraphicsCell cell
    when (observedDisposal observed == DisposalPending) (writeGraphicsDisposal cell disposal)

-- | What a member's settled status says about its window's native destruction.
-- A member still live settled nothing, so its disposal stays pending.
disposalOf ∷ MemberStatus → NativeDisposal
disposalOf = \case
  MemberRetired → DisposalCompleted
  MemberRetirementFailed _ → DisposalFailed
  MemberLive → DisposalPending

-- | Close one window's admission: its port, its input feed, and its demand
-- slot. Finite, never retries, and idempotent.
closeEntryAdmission ∷ HostEntry → STM ()
closeEntryAdmission entry = do
  void (closeWindowCommands (entryCommands entry))
  closeInputFeed (entryInput entry)
  closeDemandSlot (entryDemand entry)

-- ---------------------------------------------------------------------------
-- The wake path

-- | Whether the session's wake path has degraded, and how its one diagnostic
-- report went. Any thread may read it; every host over the session sees the
-- same state.
hostWakePath ∷ WindowHost → STM WakePath
hostWakePath = readTVar . sessionWakePath . hostSession

-- | How many notification obligations the session's admissions and publications
-- have registered and not yet discharged. Any thread may read it; it is bounded
-- by the work committed and not yet notified.
hostNotificationsInFlight ∷ WindowHost → STM Int
hostNotificationsInFlight = notificationsInFlight . hostNotifier

-- | Claim the session's one degradation report, if one is still owed, at the
-- application's own owner boundary.
--
-- 'runWindowApplication' makes this attempt itself, after quiescence and the
-- worker drain, so an application that uses the ordinary runner never needs it.
-- It is here for one that owns a different shutdown.
--
-- Call it after quiescence. It waits for the notification obligations
-- outstanding, which is bounded only once admission and publication have closed;
-- called while they are open it can wait as long as a worker keeps publishing.
-- A cancellation during that wait completes it uninterruptibly and spends the
-- attempt before it is re-raised. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
reportHostWakeDegradation ∷ HasCallStack ⇒ Logger → WindowHost → IO DegradationAttempt
reportHostWakeDegradation logger host =
  ownerOperation (hostSession host) reportOperation [] $
    mask (\restore → settledAttempt restore logger host)

-- | The runner's own final boundary: the same attempt, over the restore its
-- caller already holds, checked as an owner operation exactly as
-- 'reportHostWakeDegradation' is.
reportHostWakeDegradationAtExit ∷ HasCallStack ⇒ (∀ a. IO a → IO a) → Logger → WindowHost → IO ()
reportHostWakeDegradationAtExit restore logger host =
  ownerOperation (hostSession host) reportOperation [] (void (settledAttempt restore logger host))

hostNotifier ∷ WindowHost → Notifier
hostNotifier = commandHostNotifier . hostCommands

-- | Wait for every registered notification obligation to be discharged, then
-- make the wake path's one guarded reporting attempt.
--
-- The wait is bounded only where no new obligation can be registered — after
-- quiescence has closed admission and publication. A boundary that runs while
-- they are open must use 'promptAttempt' instead, which claims what has already
-- been recorded and waits for nothing.
--
-- The caller has masked, and lends its @restore@ for the one part that must
-- stay interruptible: the write through the injected logger, so a cancellation
-- delivered while the attempt writes reaches it and is recorded as one. This is
-- never a release callback.
--
-- The wait is interruptible too, but a cancellation there may not abandon it: an
-- obligation may be inside a failing post that has not yet recorded what it
-- found, and nothing would be left to claim that degradation. So the wait is
-- completed uninterruptibly — bounded by one empty-event post per obligation
-- outstanding, with no new one possible once admission has closed — and the
-- attempt is then made before the cancellation is re-raised as the primary
-- failure. A failure the attempt raises is retained beside it.
settledAttempt ∷ HasCallStack ⇒ (∀ a. IO a → IO a) → Logger → WindowHost → IO DegradationAttempt
settledAttempt restore logger host =
  tryWithContext (restore (atomically (awaitNotificationsSettled notifier))) >>= \case
    Right () → attempt
    Left interrupted → do
      uninterruptibleMask_ (atomically (awaitNotificationsSettled notifier))
      tryWithContext attempt >>= \case
        Right _ → rethrowIO (interrupted ∷ ExceptionWithContext SomeException)
        Left failed →
          withResourceLabelled
            wakeReportLabel
            (pure ())
            (\() → rethrowIO (failed ∷ ExceptionWithContext SomeException))
            (\() → rethrowIO interrupted)
  where
    notifier = hostNotifier host
    attempt = markedDegradationAttempt restore logger notifier

-- | One wake degradation warning attempt, carrying the runtime's
-- diagnostic-failure identity out of the host.
--
-- The attempt itself is "Hetoimasia.GLFW.Internal.Notify"'s: the @model@
-- component owns the claim, the write, and the settlement, and depends on no
-- runtime module. The identity is added here, where this sublibrary already
-- owns the attempt and already depends on the runtime, so a sink failure that
-- leaves the host is one
-- 'Hetoimasia.Runtime.Reporting.reportTerminalFailureWith' will not write
-- through again and 'Hetoimasia.Runtime.Logging.withLoggingLifetime' will not
-- flush through. Nothing else about the attempt changes: its one-attempt rule,
-- its recorded outcome, and the exception's own type, value, and context are
-- the notifier's, and a cancellation is left exactly as it arrived.
--
-- The mark is what a failure leaving as primary carries. A failure retained
-- beside an application primary is carried by 'recordingDiagnostics' instead,
-- which records it on the logging lifetime rather than marking a failure that
-- no diagnostic raised.
markedDegradationAttempt
  ∷ HasCallStack ⇒ (∀ a. IO a → IO a) → Logger → Notifier → IO DegradationAttempt
markedDegradationAttempt restore logger notifier =
  markDiagnostic (attemptDegradationReportWith restore logger notifier)

-- | The wake path's one guarded reporting attempt, without waiting for
-- anything.
--
-- It claims a degradation already recorded and leaves one still being recorded
-- to the boundary that runs after quiescence, so it can be used while
-- admissions and publications are still being made without ever waiting on a
-- worker that keeps making them.
promptAttempt ∷ HasCallStack ⇒ (∀ a. IO a → IO a) → Logger → WindowHost → IO ()
promptAttempt restore logger host = void (markedDegradationAttempt restore logger (hostNotifier host))

-- | Run @body@, then make the reporting attempt, whatever @body@ did.
--
-- The whole sequence is masked and @body@ runs under the restore, so nothing can
-- be delivered in the handoff between the body ending and the attempt being
-- protected; the attempt is lent that same restore for its logger write.
--
-- A failure the attempt raises after a successful body fails the caller. After a
-- failing or cancelled body the body's failure stays primary and the attempt's
-- is retained beside it as cleanup evidence, carried by a release that only
-- rethrows what was already caught.
retainingReport ∷ ((∀ a. IO a → IO a) → IO ()) → IO r → IO r
retainingReport attempt body = mask $ \restore → do
  outcome ← tryWithContext (restore body)
  reported ← tryWithContext (attempt restore)
  case (outcome, reported) of
    (Right result, Right ()) → pure result
    (Right _, Left failed) → rethrowIO (failed ∷ ExceptionWithContext SomeException)
    (Left primary, Right ()) → rethrowIO (primary ∷ ExceptionWithContext SomeException)
    (Left primary, Left failed) →
      withResourceLabelled
        wakeReportLabel
        (pure ())
        (\() → rethrowIO (failed ∷ ExceptionWithContext SomeException))
        (\() → rethrowIO (primary ∷ ExceptionWithContext SomeException))

-- | The cleanup label a failed reporting attempt is retained under.
wakeReportLabel ∷ Text
wakeReportLabel = "glfw wake degradation report"

-- ---------------------------------------------------------------------------
-- Demand

-- | The application's demand publisher: the capability a worker uses to ask
-- the owner for a turn, immediately or by a deadline. It is one slot for every
-- worker, so concurrent requests combine rather than replace, and it is
-- rejected once the host has quiesced.
hostDemandPublisher ∷ WindowHost → DemandPublisher
hostDemandPublisher host = demandPublisher (hostDemandSlot host) (commandHostNotifier (hostCommands host))

-- | Take the application demand pending for the owner, clearing exactly what
-- was taken, on the owner thread. A publication that commits afterwards stays
-- pending for the next capture. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
captureHostDemand ∷ WindowHost → IO (Maybe CapturedDemand)
captureHostDemand host =
  ownerOperation (hostSession host) captureOperation [] (atomically (captureDemand (hostDemandSlot host)))

-- | 'captureHostDemand' for one window's slot. A window the host no longer
-- holds, and one whose slot has closed, answer 'Nothing'.
captureWindowDemand ∷ WindowHost → WindowId → IO (Maybe CapturedDemand)
captureWindowDemand host target =
  ownerOperation (hostSession host) captureOperation (windowIdentifiers target) $
    atomically $
      Map.lookup target <$> readTVar (hostEntries host) >>= \case
        Nothing → pure Nothing
        Just entry → captureDemand (entryDemand entry)

-- | The application slot's state, read in one transaction without capturing
-- anything. Any thread may read it.
hostDemandStatus ∷ WindowHost → STM DemandStatus
hostDemandStatus = demandStatus . hostDemandSlot

-- | One window's slot state, or 'Nothing' for a window the host no longer
-- holds. Any thread may read it.
windowDemandStatus ∷ WindowHost → WindowId → STM (Maybe DemandStatus)
windowDemandStatus host target =
  Map.lookup target <$> readTVar (hostEntries host) >>= traverse (demandStatus . entryDemand)

-- ---------------------------------------------------------------------------
-- Windows

-- | The identities of the windows the host holds, in registration order: every
-- window created and not yet retired, closing ones included. Any thread may
-- read it; it is bounded by the live-window limit.
hostWindowIdentities ∷ WindowHost → STM [WindowId]
hostWindowIdentities host = Map.keys <$> readTVar (hostEntries host)

-- | The client capabilities of a window the host holds: its own command port
-- and its read-only observations. 'Nothing' once the window has been retired,
-- or for an identity the host never held.
hostWindowClient ∷ WindowHost → WindowId → STM (Maybe WindowClient)
hostWindowClient host target = fmap entryClient . Map.lookup target <$> readTVar (hostEntries host)

-- | Lend a window the host holds to an owner-thread callback, closing or not.
-- A window already retired, or never held, answers 'WindowEnded' without
-- running the callback.
--
-- The window must not escape the callback. While it runs, the window cannot be
-- retired: a close protocol begun meanwhile defers retirement until every
-- borrow has ended. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
withHostWindow ∷ WindowHost → WindowId → (Window → IO r) → IO (WindowResult r)
withHostWindow host target action =
  ownerOperation (hostSession host) borrowOperation (windowIdentifiers target) $
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → pure (WindowEnded target)
      Just entry → WindowAvailable <$> borrowWindow host target entry action

borrowWindow ∷ WindowHost → WindowId → HostEntry → (Window → IO r) → IO r
borrowWindow host target entry action =
  bracket_
    (modifyIORef' (hostBorrowed host) (Map.insertWith (+) target 1))
    (modifyIORef' (hostBorrowed host) (Map.update (\count → if count > 1 then Just (count - 1) else Nothing) target))
    (withMember (hostCollection host) (entryMember entry) action)

-- | How a request to begin a window's close protocol was answered.
data CloseStart
  = CloseStarted
    -- ^ The protocol began now.
  | CloseAlreadyStarted
    -- ^ The window was already closing; nothing changed.
  | CloseNotServed
    -- ^ The host holds no window with this identity; nothing changed.
  | CloseRequestSuperseded
    -- ^ The close request is no longer the window's latest; nothing changed.
  deriving (Eq, Show)

-- | Begin a window's close protocol on the owner thread, as a close command
-- does. Refuses other threads with 'Hetoimasia.GLFW.Session.NotSessionOwner'.
closeHostWindow ∷ WindowHost → WindowId → IO CloseStart
closeHostWindow host target =
  ownerOperation (hostSession host) closeOperation (windowIdentifiers target) (beginClose host target)

-- | Honour a surfaced close request on the owner thread: begin its window's
-- close protocol if the request is still that window's latest, after
-- reconciling what its callbacks captured. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
honourHostCloseRequest ∷ WindowHost → CloseRequest → IO CloseStart
honourHostCloseRequest host request =
  ownerOperation (hostSession host) honourOperation (windowIdentifiers target) $
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → pure CloseNotServed
      Just entry
        | entryClosing entry → pure CloseAlreadyStarted
        | otherwise → do
            latest ←
              borrowWindow host target entry $ \window →
                reconcileWindowEvents window >>= \case
                  WindowEnded _ → pure Nothing
                  WindowAvailable () → latestCloseRequest window
            if latest == Just request then beginClose host target else pure CloseRequestSuperseded
  where
    target = closeRequestWindow request

-- | The close protocol, on the owner thread:
--
-- 1. the window's closing observation is prepared, and nothing has changed yet;
-- 2. in one transaction, masked and with nothing interruptible after it, the
--    window is marked closing, its port's admission closes, its queued commands
--    settle as not executed, its input feed closes without awaiting any
--    acknowledgement, and the 'Hetoimasia.GLFW.Window.WindowClosing'
--    phase is published, so a cancellation can never leave the port closed
--    with the phase unpublished, or the reverse;
-- 3. it is retired through the collection, unless it or another window is
--    borrowed, in which case a later turn retries.
beginClose ∷ WindowHost → WindowId → IO CloseStart
beginClose host target =
  Map.lookup target <$> readTVarIO (hostEntries host) >>= \case
    Nothing → pure CloseNotServed
    Just entry
      | entryClosing entry → pure CloseAlreadyStarted
      | otherwise →
          borrowWindow host target entry (beginWindowClosing (pure ()) (commitClosing host target)) >>= \case
            WindowAvailable True → do
              retireClosing host target entry
              pure CloseStarted
            WindowAvailable False → pure CloseAlreadyStarted
            WindowEnded _ → pure CloseNotServed

-- | The host's half of step 2: mark the window closing, close its port, settle
-- its queue, and close its input feed, answering whether it was still open.
-- Finite and never retries.
commitClosing ∷ WindowHost → WindowId → STM Bool
commitClosing host target =
  Map.lookup target <$> readTVar (hostEntries host) >>= \case
    Just entry | not (entryClosing entry) → do
      modifyTVar' (hostEntries host) (Map.insert target entry {entryClosing = True})
      closeEntryAdmission entry
      -- On a protected host the same step ends the window's new graphics use:
      -- its attachment, if it has one, begins retiring before the close is
      -- answered, and its veto then holds destruction back. Its retained
      -- service is brought up to date here too, so no reader can see the
      -- closing phase published while the service still reports an attached
      -- owner.
      mapM_ (`recordClosingWindow` target) (hostRetirementState host)
      refreshGraphicsCells host
      -- A retirement this close just began has never been offered an
      -- opportunity, so the next turn polls rather than waiting its idle bound
      -- before giving it one. A window with no attachment, and every window of
      -- an ordinary host, leave the demand exactly as they found it.
      markRetirementImmediate host
      pure True
    _ → pure False

-- | Attempt a closing window's retirement. A borrow of another window defers it
-- without calling the collection, and a borrow of this one defers it with the
-- collection's in-use answer. A retirement that succeeded or failed forgets the
-- window: a failed release is latched by the collection as evidence for its
-- exit and is never attempted again, and the window's observations report it.
retireClosing ∷ WindowHost → WindowId → HostEntry → IO ()
retireClosing host target entry = do
  borrowed ← readIORef (hostBorrowed host)
  vetoed ← attachmentVetoes host target
  if vetoed || any (/= target) (Map.keys borrowed)
    then pure ()
    else
      tryWithContext (retireMember (hostCollection host) (entryMember entry)) >>= \case
        Right RetirementInUse → pure ()
        Right _ → forget DisposalCompleted
        Left (caught ∷ ExceptionWithContext SomeException) →
          memberStatus (entryMember entry) >>= \case
            -- The collection latched the failed release as evidence for its own
            -- exit and will never attempt it again. The window is forgotten
            -- either way, and the attachment observation says the disposal
            -- failed rather than claiming a destruction that did not happen.
            MemberRetirementFailed _ → forget DisposalFailed
            _ → rethrowIO caught
  where
    forget disposal = do
      atomically $ do
        modifyTVar' (hostEntries host) (Map.delete target)
        mapM_ (`forgetRetiredWindow` target) (hostRetirementState host)
        -- The window's last attachment learns how its window ended before the
        -- host drops the cell; whoever retains the service keeps that answer.
        cells ← readTVar (hostGraphicsCells host)
        forM_ (Map.lookup target cells) $ \cell → do
          writeGraphicsSlot cell SlotFree []
          writeGraphicsDisposal cell disposal
        writeTVar (hostGraphicsCells host) (Map.delete target cells)
      modifyIORef' (hostSurfaced host) (Map.delete target)

-- | Whether a protected host's attachment still vetoes this window's native
-- destruction. An ordinary host has no attachment and vetoes nothing, so its
-- close protocol is exactly what it was.
attachmentVetoes ∷ WindowHost → WindowId → IO Bool
attachmentVetoes host target = case hostRetirementState host of
  Nothing → pure False
  Just retirement → atomically (windowRetirementVeto retirement target)

-- | Retry the retirement of every closing window, in registration order.
retirePending ∷ WindowHost → IO ()
retirePending host = do
  atomically (refreshGraphicsCells host)
  entries ← readTVarIO (hostEntries host)
  forM_ (Map.toAscList entries) $ \(target, entry) →
    if entryClosing entry then retireClosing host target entry else pure ()

-- | Acquire a window as a collection member and register it with its own port
-- and input feed. The feed starts focused if the window's initial observation
-- observed focus.
--
-- The window's construction runs with the caller's masking state, so a
-- cancellation during it rolls construction back and registers nothing. The
-- host's registration is the collection's handoff: it runs in the masked step
-- that registered the member, with nothing interruptible before it and nothing
-- that blocks inside it, so no cancellation separates the collection's
-- registration from the host's.
registerWindow ∷ WindowHost → WindowConfig → IO WindowClient
registerWindow host config =
  acquireMemberThen (hostCollection host) (windowAssembly (hostSession host) config) $ \member → do
    (identity, reader, feed) ←
      withMember (hostCollection host) member $ \window → do
        let identity = windowIdentity window
            reader = windowObservations window
        focused ← (== Observed True) . observedFocused . preparedValue . observedValue <$> atomically (readSnapshot reader)
        feed ← newInputFeed identity (hostInputCapacity (hostSettings host)) focused
        attachWindowInputFeed window feed
        pure (identity, reader, feed)
    commands ← newWindowPortHost (hostSession host) (hostCommandCapacity (hostSettings host)) identity
    demand ← newDemandSlot
    let client =
          newWindowClient identity commands reader (feedReader feed) (feedControl feed) $
            demandPublisher demand (commandHostNotifier (hostCommands host))
        entry = HostEntry member commands feed demand client False
    -- Registration and the quiescence check commit together, so a window whose
    -- creation was claimed before quiescence and finished after it is
    -- registered already closed: its port, its feed, and its demand slot admit
    -- nothing, and the client its ticket hands over can revive none of them.
    atomically $ do
      quiesced ← commandsAdmissionClosed (hostCommands host)
      when quiesced (closeEntryAdmission entry)
      modifyTVar' (hostEntries host) (Map.insert identity entry)
      -- The model learns of the window in the same step, so an attachment can
      -- never name a window the host does not hold, or miss one it does.
      mapM_ (`recordRegisteredWindow` identity) (hostRetirementState host)
    afterRegistration (hostHooks host)
    pure client

-- | Create a window for a creation command. The configuration and the live
-- limit are checked before any native effect, and poisoning is refused before
-- one too; each is a typed rejection. A native failure during construction
-- whose rollback released everything construction acquired is a typed
-- rejection as well. A construction failure carrying retained cleanup
-- evidence — a rollback whose own release failed — is never downgraded to one:
-- it propagates unchanged, interrupting the command and ending the loop, with
-- the evidence still attached for the collection's exit. Anything else — a
-- cancellation, a callback fault, any other exception — propagates with its
-- cleanup evidence.
createWindow ∷ WindowHost → WindowConfig → IO Execution
createWindow host config = case validateWindowConfig config of
  Left invalid → pure (Completed (Left (WindowConfigInvalid invalid)))
  Right () → do
    live ← liveMemberCount (hostCollection host)
    if live >= limit
      then pure (Completed (Left (WindowCapacityReached limit)))
      else
        tryWithContext (registerWindow host config) >>= \case
          Right client → pure (Created client)
          Left caught@(ExceptionWithContext context failure)
            | _ : _ ← cleanupFailuresInContext context → rethrowIO caught
            | Just CollectionPoisoned ← fromException failure → rejected WindowCreationPoisoned
            | Just SessionPoisoned ← fromException failure → rejected WindowCreationPoisoned
            | Just (MemberLimitReached reached) ← fromException failure → rejected (WindowCapacityReached reached)
            | Just native ← fromException failure
            , Just (failed, outcome, reports) ← nativeRejectionOf (ExceptionWithContext context native) →
                rejected (WindowCreationFailed failed outcome reports)
            | otherwise → rethrowIO caught
  where
    limit = hostWindowLimit (hostSettings host)
    rejected = pure . Completed . Left

-- | Execute one claimed command, from whichever port it was admitted through.
-- Scope was checked by the executor before this runs.
executeHostCommand ∷ WindowHost → CommandOrigin → WindowCommand → IO Execution
executeHostCommand host _ = \case
  CreateWindow config → createWindow host config
  CloseWindow target →
    beginClose host target >>= \case
      CloseStarted → completed (Right (WindowCloseBegun target))
      CloseAlreadyStarted → completed (Left (WindowIsClosing target))
      _ → completed (Left (WindowNotServed target))
  ObserveWindow target →
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → completed (Left (WindowNotServed target))
      Just entry
        | entryClosing entry → completed (Left (WindowIsClosing target))
        | otherwise → Completed <$> borrowWindow host target entry (observeWindow target)
  ControlWindow target control →
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → completed (Left (WindowNotServed target))
      Just entry
        | entryClosing entry → completed (Left (WindowIsClosing target))
        | otherwise → Settled <$> borrowWindow host target entry (controlDisposition target control)
  ModeWindow target request →
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → completed (Left (WindowNotServed target))
      Just entry
        | entryClosing entry → completed (Left (WindowIsClosing target))
        | otherwise → Settled <$> borrowWindow host target entry (modeDisposition target request)
  where
    completed = pure . Completed

-- | What the host holds, for bounding checks: every count is proportional to the
-- live windows, never to how many were ever created.
data HostBookkeeping = HostBookkeeping
  { bookkeepingWindows ∷ !Int
    -- ^ Windows registered and not yet retired.
  , bookkeepingClosing ∷ !Int
    -- ^ Of those, windows whose close protocol has begun.
  , bookkeepingMembers ∷ !Int
    -- ^ Live members of the host's collection.
  , bookkeepingPorts ∷ !Int
    -- ^ Command ports dispatched from: the host's and one per registered window.
  , bookkeepingPendingCells ∷ !Natural
    -- ^ Completion cells held across every port.
  , bookkeepingSurfaced ∷ !Int
    -- ^ Close requests remembered as surfaced.
  , bookkeepingBorrowed ∷ !Int
    -- ^ Windows currently borrowed on the owner thread.
  }
  deriving (Eq, Show)

-- | Read the host's bookkeeping on the owner thread. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
hostBookkeeping ∷ WindowHost → IO HostBookkeeping
hostBookkeeping host =
  ownerOperation (hostSession host) bookkeepingOperation [] $ do
    (entries, cells) ← atomically $ do
      entries ← readTVar (hostEntries host)
      hostCells ← commandsPending <$> commandStatistics (hostCommands host)
      windowCells ← forM (Map.elems entries) (fmap commandsPending . commandStatistics . entryCommands)
      pure (entries, hostCells + sum windowCells)
    members ← liveMemberCount (hostCollection host)
    surfaced ← Map.size <$> readIORef (hostSurfaced host)
    borrowed ← Map.size <$> readIORef (hostBorrowed host)
    pure
      HostBookkeeping
        { bookkeepingWindows = Map.size entries
        , bookkeepingClosing = Map.size (Map.filter entryClosing entries)
        , bookkeepingMembers = members
        , bookkeepingPorts = 1 + Map.size entries
        , bookkeepingPendingCells = cells
        , bookkeepingSurfaced = surfaced
        , bookkeepingBorrowed = borrowed
        }

windowIdentifiers ∷ WindowId → [(Text, Text)]
windowIdentifiers window = [("window", Text.pack (show (windowLocalIdentity window)))]

latestCloseRequest ∷ Window → IO (Maybe CloseRequest)
latestCloseRequest window =
  observedCloseRequest . preparedValue . observedValue <$> atomically (readSnapshot (windowObservations window))

-- ---------------------------------------------------------------------------
-- The owner loop

-- | What the application supplies to the owner loop.
data LoopHooks a = LoopHooks
  { loopLogger ∷ Logger
    -- ^ The injected logger the overflow warning is written through, at a
    -- safe owner boundary outside callbacks.
  , loopEvent ∷ IO Bool
    -- ^ One application event opportunity. 'True' when it dispatched
    -- something, which costs one unit of the event budget; 'False' when nothing
    -- was ready, which ends the turn's event work.
  , loopUpdate ∷ Turn → IO (TurnStep a)
    -- ^ The application-owned update opportunity, once per turn.
  }

-- | An event opportunity that never has anything ready.
noApplicationEvents ∷ IO Bool
noApplicationEvents = pure False

-- | What one turn did, as its update opportunity sees it.
data Turn = Turn
  { turnNumber ∷ !Natural
    -- ^ Starting at one.
  , turnWaited ∷ !Bool
    -- ^ Whether the turn was idle and made a finite native wait.
  , turnCommands ∷ !Int
    -- ^ Commands attempted across every port, rejected ones included.
  , turnEvents ∷ !Int
    -- ^ Application events dispatched.
  , turnCloseRequests ∷ ![CloseRequest]
    -- ^ Close requests surfaced for the first time, in window order.
  }
  deriving (Eq, Show)

-- | Whether the loop continues.
data TurnStep a
  = Continue
  | Finish a
  deriving (Eq, Show)

-- | Run owner turns until 'loopUpdate' answers 'Finish', on the session's owner
-- thread, and return its result once a final control check has passed.
--
-- Another thread is refused with 'Hetoimasia.GLFW.Session.NotSessionOwner'
-- before anything runs. A supervised failure, a native failure, a callback
-- fault rethrown at reconciliation, a command's rethrown interruption, or a
-- hook's failure ends the loop and propagates.
runOwnerLoop ∷ WindowHost → RuntimeControl → LoopHooks a → IO a
runOwnerLoop host control hooks =
  ownerOperation (hostSession host) loopOperation [] $
    reportingAsItEnds (loopLogger hooks) host (turn 1 False)
  where
    settings = hostSettings host
    turn number idle = do
      checkRuntime control
      (queued, retiring) ← atomically ((,) <$> queuedCommands host <*> hostRetirementDemand host)
      -- A retirement the last round advanced, and one that is owed an
      -- opportunity no round has offered it yet, are both work this turn
      -- already has, so the turn polls rather than waiting: a pending
      -- retirement never waits on the idle bound for its first opportunity and
      -- never holds another window's service up. Retirements that have all been
      -- inspected and are waiting are not that work, however many of them the
      -- budget leaves unserved, so an idle turn beside them is idle.
      let waited = idle && queued == 0 && not (retirementImmediate retiring)
      processEvents host number (if waited then AwaitEventsFor (hostIdleWait settings) else ProcessPending)
      work ← turnWork host control (loopLogger hooks) (loopEvent hooks)
      step ← loopUpdate hooks (turnSummary number waited work)
      checkRuntime control
      case step of
        Finish result → pure result
        Continue → turn (number + 1) (workCommands work == 0 && workEvents work == 0)

-- | However a loop ends — a result, a supervised failure, a native failure, or
-- a cancellation — the wake path's one report is claimed before it returns, so
-- a degradation this turn's own work already caused is reported here rather
-- than waiting for shutdown.
--
-- This boundary never waits for an obligation. Admission and publication are
-- still open, and a worker that keeps publishing until supervision stops it
-- would keep new obligations coming, so waiting here would hold the loop's own
-- result back from the quiescence and the drain that would end them. The
-- boundary that does wait is the one after quiescence, where nothing new can be
-- registered.
reportingAsItEnds ∷ Logger → WindowHost → IO r → IO r
reportingAsItEnds logger host = retainingReport (\restore → promptAttempt restore logger host)

-- | What one turn's reconciliation and bounded dispatch produced.
data TurnWork = TurnWork
  { workCommands ∷ !Int
  , workEvents ∷ !Int
  , workCloses ∷ ![CloseRequest]
  }

-- | The work of one turn after its native event processing, in the one order
-- both loops use: reconciliation and feed recovery, a check, bounded command
-- work and recovery again, a check, bounded application event work, and a
-- check.
turnWork ∷ WindowHost → RuntimeControl → Logger → IO Bool → IO TurnWork
turnWork host control logger event = do
  reconcileMonitorEvents (hostSession host)
  reconcileWindowModes host
  -- Before the retirement retry below, so an attachment this turn's own bounded
  -- round made safe releases its window in the same turn rather than the next.
  advanceHostRetirements host
  retirePending host
  closes ← surfaceCloseRequests host
  recoverFeeds logger host
  void (mask (\restore → markedDegradationAttempt restore logger (hostNotifier host)))
  checkRuntime control
  commands ← dispatchCommands host (hostCommandBudget settings)
  recoverFeeds logger host
  checkRuntime control
  events ← dispatchEvents event (hostEventBudget settings)
  checkRuntime control
  pure (TurnWork commands events closes)
  where
    settings = hostSettings host

turnSummary ∷ Natural → Bool → TurnWork → Turn
turnSummary number waited work = Turn number waited (workCommands work) (workEvents work) (workCloses work)

-- | Commands queued across every port.
queuedCommands ∷ WindowHost → STM Natural
queuedCommands host = do
  queued ← commandsQueued <$> commandStatistics (hostCommands host)
  entries ← readTVar (hostEntries host)
  windows ← forM (Map.elems entries) (fmap commandsQueued . commandStatistics . entryCommands)
  pure (queued + sum windows)

-- | Poll, or wait the chosen finite bound, publishing the activity around it.
--
-- The turn number is offered to the session's interaction trace
-- ("Hetoimasia.GLFW.Internal.Trace") first, so the pump's own entry and exit,
-- and every callback delivered between them, are attributable to this turn.
-- The trace is stopped in every ordinary run, which costs one 'IORef' read.
processEvents ∷ WindowHost → Natural → EventProcessing → IO ()
processEvents host number processing = do
  recordTrace (sessionTrace (hostSession host)) (TurnBegan number)
  atomically (writeTVar (hostActivityState host) (HostActivity number waiting))
  processWindowEvents (hostSession host) processing
    `finally` atomically (writeTVar (hostActivityState host) (HostActivity number False))
  where
    waiting = case processing of
      AwaitEventsFor _ → True
      ProcessPending → False

-- | Reconcile the mode of every window the host holds that is not closing, in
-- registration order, after the turn's monitor refresh: a window whose recovery
-- obligation names an ended monitor identity takes its recorded fallback
-- without another command, whatever observations intervened since the
-- disconnect. The obligation is the monitor the last settlement established,
-- or the live monitor an earlier turn's reconciliation confirmed a borderless
-- window had moved onto while both were connected; a move folded in the same
-- turn as a disconnect is judged only by a later turn, against the refreshed
-- inventory, so it never re-points the obligation to an ended monitor.
reconcileWindowModes ∷ WindowHost → IO ()
reconcileWindowModes host = do
  entries ← readTVarIO (hostEntries host)
  forM_ (Map.toAscList entries) $ \(target, entry) →
    if entryClosing entry then pure () else void (borrowWindow host target entry reconcileWindowMode)

-- | Claim each open feed's overflow warning and resume any acknowledged
-- reset, at a safe owner boundary after callbacks have been reconciled.
recoverFeeds ∷ Logger → WindowHost → IO ()
recoverFeeds logger host = do
  entries ← readTVarIO (hostEntries host)
  forM_ (Map.elems entries) $ \entry →
    unless (entryClosing entry) $ do
      void (attemptOverflowWarning logger (entryInput entry))
      void (resumeInput (entryInput entry))

-- | Reconcile every window the host holds, and answer the close requests of
-- windows not closing that were not surfaced before.
surfaceCloseRequests ∷ WindowHost → IO [CloseRequest]
surfaceCloseRequests host = do
  entries ← readTVarIO (hostEntries host)
  fmap catMaybes . forM (Map.toAscList entries) $ \(target, entry) →
    borrowWindow host target entry $ \window →
      reconcileWindowEvents window >>= \case
        WindowEnded _ → pure Nothing
        WindowAvailable ()
          | entryClosing entry → pure Nothing
          | otherwise →
              latestCloseRequest window >>= \case
                Nothing → pure Nothing
                Just request → do
                  surfaced ← Map.lookup target <$> readIORef (hostSurfaced host)
                  if surfaced == Just request
                    then pure Nothing
                    else do
                      modifyIORef' (hostSurfaced host) (Map.insert target request)
                      pure (Just request)

-- | Attempt queued commands, fairly across ports, until the budget is spent or
-- no port has one queued, answering how many were attempted.
--
-- Ports are ordered by 'PortKey'. Each attempt claims the oldest command of the
-- first port after the one the previous attempt served, in that cyclic order,
-- that has one queued, so FIFO holds within each port and no port is attempted
-- twice while another port that had a command queued waits. Windows that are
-- closing have no port to dispatch from.
dispatchCommands ∷ WindowHost → Int → IO Int
dispatchCommands host budget = go 0
  where
    go attempted
      | attempted >= budget = pure attempted
      | otherwise = do
          entries ← readTVarIO (hostEntries host)
          cursor ← readIORef (hostCursor host)
          let ports =
                (HostPortKey, hostCommands host)
                  : [(WindowPortKey target, entryCommands entry) | (target, entry) ← Map.toAscList entries, not (entryClosing entry)]
              (before, after) = span ((<= cursor) . fst) ports
          serve attempted (after <> before)
    serve attempted [] = pure attempted
    serve attempted ((key, commands) : rest) =
      executeNextWith (pure ()) commands (executeHostCommand host) >>= \case
        Executed _ _ → writeIORef (hostCursor host) key >> go (attempted + 1)
        NothingQueued → serve attempted rest
        CommandsEnded → serve attempted rest

-- | Offer event opportunities until the budget is spent or nothing is ready,
-- answering how many dispatched something.
dispatchEvents ∷ IO Bool → Int → IO Int
dispatchEvents opportunity budget = go 0
  where
    go dispatched
      | dispatched >= budget = pure dispatched
      | otherwise = opportunity >>= \ready → if ready then go (dispatched + 1) else pure dispatched

-- | Reject a close request on the owner thread: it is cleared from its window's
-- observation only if it is still that window's latest, and the answer says
-- whether it was. A request for a window the host does not hold answers
-- 'False'.
rejectHostCloseRequest ∷ WindowHost → CloseRequest → IO Bool
rejectHostCloseRequest host request =
  ownerOperation (hostSession host) rejectOperation [] $
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → pure False
      Just entry →
        borrowWindow host target entry (\window → rejectCloseRequest window request) >>= \case
          WindowAvailable cleared → pure cleared
          WindowEnded _ → pure False
  where
    target = closeRequestWindow request

-- ---------------------------------------------------------------------------
-- The scheduled owner loop

-- | The application's own ongoing schedule: what its update opportunity last
-- answered, which the loop stores until the next answer replaces it.
--
-- It is never combined with an earlier answer and never with a captured
-- request, so an old request can never become permanent work and finishing an
-- update implies no immediate demand for another.
data UpdateSchedule
  = NoUpdateDemand
    -- ^ Continue with no deadline of its own.
  | UpdateImmediately
    -- ^ Continue, wanting the next turn now.
  | UpdateBy !Instant
    -- ^ Continue, wanting an opportunity by this absolute instant, in
    -- 'hostClock'\'s domain.
  deriving (Eq, Show)

-- | Whether the scheduled loop continues, and with what schedule.
data ScheduledStep a
  = ContinueWith !UpdateSchedule
  | FinishWith a
  deriving (Eq, Show)

-- | How a scheduled turn's native step was chosen.
data TurnPacing
  = PolledForWork
    -- ^ Work was ready at the inspection: a command queued, an application
    -- event ready, or immediate demand from the schedule or the captured
    -- request.
  | PolledForDeadline
    -- ^ Nothing was ready and the earliest deadline had been reached, so the
    -- turn polled rather than waiting no time at all.
  | WaitedForDeadline !Duration
    -- ^ The wait was the remaining time to the earliest deadline, which was
    -- nearer than the fallback bound.
  | WaitedForFallback !Duration
    -- ^ The wait was the configured fallback bound, because no deadline was
    -- nearer and none may extend it.
  deriving (Eq, Show)

-- | Whether a pacing made a finite native wait.
pacingWaited ∷ TurnPacing → Bool
pacingWaited = \case
  WaitedForDeadline _ → True
  WaitedForFallback _ → True
  PolledForWork → False
  PolledForDeadline → False

-- | The native step a pacing takes. A wait is only ever entered for a positive
-- duration, so no zero or negative timeout reaches GLFW.
pacingProcessing ∷ TurnPacing → EventProcessing
pacingProcessing = \case
  PolledForWork → ProcessPending
  PolledForDeadline → ProcessPending
  WaitedForDeadline remaining → AwaitEventsFor (waitSeconds remaining)
  WaitedForFallback bound → AwaitEventsFor (waitSeconds bound)

-- | What one scheduled turn did, as its update opportunity sees it.
data ScheduledTurn = ScheduledTurn
  { scheduledTurn ∷ !Turn
    -- ^ The same summary the unscheduled loop supplies: the turn number,
    -- whether it waited, its dispatch counts, and the close requests it
    -- surfaced.
  , scheduledNow ∷ !Instant
    -- ^ The instant sampled after the native call returned, so a deadline
    -- reached during the wait is already visible here. Reconciliation,
    -- dispatch, and this update consume the interval after it; the next turn
    -- samples again.
  , scheduledPacing ∷ !TurnPacing
    -- ^ Whether the turn polled or waited, and why.
  , scheduledDemand ∷ !(Maybe CapturedDemand)
    -- ^ The request the turn's own inspection captured from the application's
    -- demand slot, with its revision, or 'Nothing' when none was pending. It is
    -- already consumed: a publication committed after that capture carries a
    -- newer revision and is captured by a later turn.
  }
  deriving (Eq, Show)

-- | What the application supplies to the scheduled owner loop.
data ScheduledHooks a = ScheduledHooks
  { scheduledLogger ∷ Logger
    -- ^ The injected logger the overflow and wake warnings are written through,
    -- as 'loopLogger' is.
  , scheduledReady ∷ IO Bool
    -- ^ Whether an application event is ready, answered without dispatching
    -- one. It runs once per turn, before the native step, and only decides
    -- whether that turn polls; it must neither dispatch nor consume anything,
    -- and it spends none of 'hostEventBudget'. An event published after it
    -- answered is not seen by that turn: a worker that needs prompt service
    -- publishes demand, which wakes the owner.
  , scheduledEvent ∷ IO Bool
    -- ^ One application event opportunity, exactly as 'loopEvent'.
  , scheduledUpdate ∷ ScheduledTurn → IO (ScheduledStep a)
    -- ^ The application-owned update opportunity, once per turn, which answers
    -- the schedule the turns after it are chosen from.
  , scheduledStart ∷ UpdateSchedule
    -- ^ The schedule in force before the first update opportunity has
    -- answered. 'defaultScheduledHooks' leaves it 'NoUpdateDemand'.
  }

-- | An application event readiness query that never has anything ready.
noApplicationReadiness ∷ IO Bool
noApplicationReadiness = pure False

-- | Hooks with no application events, nothing ever ready, and no initial
-- schedule, for a caller that overrides only the fields it uses.
defaultScheduledHooks ∷ Logger → (ScheduledTurn → IO (ScheduledStep a)) → ScheduledHooks a
defaultScheduledHooks logger update =
  ScheduledHooks
    { scheduledLogger = logger
    , scheduledReady = noApplicationReadiness
    , scheduledEvent = noApplicationEvents
    , scheduledUpdate = update
    , scheduledStart = NoUpdateDemand
    }

-- | The deadline of a schedule, if it named one.
scheduleDeadline ∷ UpdateSchedule → Maybe Instant
scheduleDeadline = \case
  UpdateBy due → Just due
  UpdateImmediately → Nothing
  NoUpdateDemand → Nothing

-- | The earlier of the application's own deadline and the captured request's.
earliestDeadline ∷ UpdateSchedule → Maybe CapturedDemand → Maybe Instant
earliestDeadline schedule captured =
  earlierOf (scheduleDeadline schedule) (demandDeadline . capturedRequest =<< captured)

-- | The earlier of two optional deadlines.
earlierOf ∷ Maybe Instant → Maybe Instant → Maybe Instant
earlierOf Nothing later = later
earlierOf earlier Nothing = earlier
earlierOf (Just earlier) (Just later) = Just (min earlier later)

-- | Choose the turn's native step from the sampled instant, the earliest
-- deadline, and whether work is ready.
choosePacing ∷ Duration → Instant → Maybe Instant → Bool → TurnPacing
choosePacing bound now deadline ready
  | ready = PolledForWork
  | Just due ← deadline =
      if deadlineReached now due
        then PolledForDeadline
        else
          let remaining = remainingUntil now due
           in if remaining < bound then WaitedForDeadline remaining else WaitedForFallback bound
  | otherwise = WaitedForFallback bound

-- | Run scheduled owner turns until 'scheduledUpdate' answers 'FinishWith', on
-- the session's owner thread, and return its result once a final control check
-- has passed.
--
-- Each turn samples 'hostClock', captures the application's pending demand,
-- reads the queued command count and the application's readiness in one
-- inspection, and from those and the stored schedule chooses to poll or to wait
-- a finite bound that is at most the earliest deadline and at most the
-- configured fallback. It then resamples the clock and reconciles, dispatches,
-- and offers the update opportunity exactly as 'runOwnerLoop' does, with the
-- same checkpoints, budgets, fair dispatch, retirement, close-request
-- surfacing, and feed recovery.
--
-- 'runOwnerLoop' is untouched by this path and keeps its own behaviour. Another
-- thread is refused with 'Hetoimasia.GLFW.Session.NotSessionOwner' before
-- anything runs, and every failure ends the loop exactly as it ends that one.
runScheduledOwnerLoop ∷ WindowHost → RuntimeControl → ScheduledHooks a → IO a
runScheduledOwnerLoop host control hooks =
  ownerOperation (hostSession host) loopOperation [] $ do
    bound ← either rejectedBound pure (idleWaitDuration settings)
    reportingAsItEnds logger host (turn bound 1 (scheduledStart hooks))
  where
    settings = hostSettings host
    logger = scheduledLogger hooks
    -- Unreachable for a host the construction accepted, which validated these
    -- seconds as a positive duration; a typed rejection rather than a partial
    -- function keeps it that way if the two ever drift apart.
    rejectedBound _ = throwFailure hostComponent loopOperation [] (IdleWaitRejected (hostIdleWait settings))
    turn bound number schedule = do
      checkRuntime control
      inspected ← readInstant (hostClock settings)
      (captured, queued, retiring) ←
        atomically
          ( (,,)
              <$> captureDemand (hostDemandSlot host)
              <*> queuedCommands host
              <*> hostRetirementDemand host
          )
      ready ← scheduledReady hooks
      let immediate =
            schedule == UpdateImmediately
              || maybe False (demandIsImmediate . capturedRequest) captured
              || retirementImmediate retiring
          -- A due retirement step shortens the wait exactly as an application
          -- deadline does, and never lengthens it.
          deadline = earlierOf (earliestDeadline schedule captured) (retirementNextPossible retiring)
          pacing = choosePacing bound inspected deadline (queued > 0 || ready || immediate)
      processEvents host number (pacingProcessing pacing)
      -- The instant the update is given, so a deadline the wait itself reached
      -- is due now rather than on the turn after.
      sampled ← readInstant (hostClock settings)
      work ← turnWork host control logger (scheduledEvent hooks)
      step ←
        scheduledUpdate
          hooks
          ScheduledTurn
            { scheduledTurn = turnSummary number (pacingWaited pacing) work
            , scheduledNow = sampled
            , scheduledPacing = pacing
            , scheduledDemand = captured
            }
      checkRuntime control
      case step of
        FinishWith result → pure result
        ContinueWith next → turn bound (number + 1) next

-- ---------------------------------------------------------------------------
-- Applications

-- | 'Hetoimasia.Runtime.Application.runManagedApplication' with the host's
-- quiescence action and its final notification boundary: the fourth argument
-- finds the host among the application's dependencies.
--
-- The host's dependencies are a managed lifetime rather than a bare scope, so
-- the runner's own order gains one component-owned step and nothing else: the
-- finite quiescence transaction closes admission, publication, and every input
-- feed; supervision then stops and drains every worker; and only then, with
-- every dependency and the application's logger still live, the host waits for
-- the notification obligations its admissions and publications registered and
-- makes the wake path's one guarded reporting attempt. Nothing new can be
-- admitted or published by then, so that attempt cannot be outrun.
--
-- It is the ordinary boundary, so an application needs no reporting call of its
-- own; 'reportHostWakeDegradation' stays available for one that owns a
-- different shutdown. The attempt runs on the calling thread as ordinary
-- interruptible work, not inside a release: a failing sink after a successful
-- run fails the run, and after a failing or cancelled one the original failure
-- stays primary with the attempt's retained beside it.
runWindowApplication
  ∷ HasCallStack
  ⇒ (∀ r. (LoggingLifetime → IO r) → IO r)
  → Text
  → Scoped dependencies
  → (dependencies → WindowHost)
  → (dependencies → RuntimeControl → IO services)
  → (services → RuntimeControl → IO a)
  → IO a
runWindowApplication enterLifetime name dependencies host startup action =
  enterLifetime $ \lifetime →
    runManagedApplication
      (\use → use lifetime)
      name
      ( \use →
          recordingDiagnostics lifetime $
            withScoped dependencies $ \built →
              retainingReport
                (\restore → reportHostWakeDegradationAtExit restore (lifetimeLogger lifetime) (host built))
                (use built)
      )
      (quiesceWindowHost . host)
      startup
      action

-- | Record on the logging lifetime every host lifecycle diagnostic that failed
-- inside @work@, then let what @work@ raised through unchanged.
--
-- A wake degradation warning and a retirement stall diagnostic are both written
-- through the application's own sink, and both leave 'markDiagnostic''s mark on
-- the failure a failing sink raises. When that failure is the one leaving the
-- host, the mark is enough: 'Hetoimasia.Runtime.Reporting.reportTerminalFailure'
-- and 'Hetoimasia.Runtime.Logging.withLoggingLifetime' both read it off the
-- context they are handed.
--
-- When an application failure is already primary, they do not: the boundaries
-- that retain a failed warning — 'retainingReport' and the protected exit's
-- 'settleProtectedOutcome' — keep the application's failure primary, which is
-- what it is, and carry the warning beside it as labelled cleanup evidence.
-- Marking that primary would say a diagnostic raised it, which is false. So the
-- warning is recorded here instead, as the 'ReportFailed' outcome the logging
-- lifetime already has a place for, exactly as a runtime-managed report records
-- its own failed attempt. 'Hetoimasia.Runtime.Application.reportOnce' then makes
-- no further write through that sink, and the lifetime attempts no final flush
-- through it.
--
-- It is the runners' own step, so it wraps everything inside them that can make
-- or retain one of these attempts, and nothing else: it reports nothing, writes
-- nothing, changes no outcome, and adds no annotation to the failure it lets
-- through. A cancellation carries no mark and records nothing. Runtime policy
-- is unchanged; this only tells the lifetime what the host already found.
recordingDiagnostics ∷ LoggingLifetime → IO r → IO r
recordingDiagnostics lifetime work =
  tryWithContext work >>= \case
    Right result → pure result
    Left caught → do
      mapM_ (recordReport lifetime . ReportFailed) (failedDiagnosticsOf caught)
      rethrowIO (caught ∷ ExceptionWithContext SomeException)

-- | The failed lifecycle diagnostics one propagating failure carries: the
-- failure itself when a diagnostic raised it, and every marked failure retained
-- beside it as cleanup evidence, in the order the boundaries found them.
--
-- 'cleanupFailuresInContext' already reports each distinct retained failure
-- once, however many routes reach it, so a warning retained through several
-- scopes is recorded once.
failedDiagnosticsOf ∷ ExceptionWithContext SomeException → [ExceptionWithContext SomeException]
failedDiagnosticsOf caught@(ExceptionWithContext context _) =
  [caught | raisedByDiagnostic context] <> filter diagnostic retained
  where
    retained = map cleanupFailureException (cleanupFailuresInContext context)
    diagnostic (ExceptionWithContext carried _) = raisedByDiagnostic carried

-- ---------------------------------------------------------------------------
-- The protected host lifetime

-- | Enter a session and build an attachment-capable host in it, for one
-- consumer on the calling thread, on the process main thread.
--
-- It builds exactly the host 'allocWindowHost' builds — the same validated
-- configuration, session, scoped collection, host port, configured windows, and
-- admission-closing release — and additionally owns the retirement state of
-- "Hetoimasia.GLFW.Internal.Attachment" under a host identity only this
-- lifetime issues. A host built by 'allocWindowHost' is issued none, so no
-- attachment can ever name it.
--
-- It is the shape
-- 'Hetoimasia.Runtime.Application.runManagedApplication' accepts, and it
-- follows that contract in full: once construction succeeds it invokes the
-- consumer exactly once, synchronously on the calling thread, with every
-- dependency it built live; when construction fails it invokes the consumer not
-- at all. Its exit handler is installed under masking before the host is handed
-- over and before interruptibility is restored for any dependent the consumer
-- constructs, so no exit can escape it.
--
-- __On every exit__ — a normal return, an action failure, a startup failure, a
-- dependency construction failure after host setup, an owner-loop failure, a
-- latched supervised failure, and cancellation — the boundary:
--
-- 1. runs the host's own 'quiesceWindowHost' — every port's admission, every
--    input feed, every demand slot, and attachment admission with new graphics
--    use — idempotently and in one finite transaction, even when the
--    application never installed a quiescence hook or omitted the host from
--    one. This is the host's own safeguard; when the application does install
--    it the runtime's ordering has already done it before the worker drain,
--    which is what keeps a worker from starting a use the drain would then have
--    to wait for. Nothing can be admitted or published after it, so the report
--    in step 3 cannot be outrun;
-- 2. retires every remaining attachment on the owner thread, with the windows,
--    the session, and every parent still live, through the narrow progress path
--    "Hetoimasia.Runtime.GLFW.Internal.Retirement" describes: completion
--    notices folded, one bounded opportunity per pending attachment per round,
--    native event processing and the session's internal wake kept live, finite
--    interruptible waits, and no application hook or supervisor checkpoint;
-- 3. makes the wake path's one guarded degradation report, as
--    'runWindowApplication' does, now that nothing further can be admitted or
--    published;
-- 4. settles the outcome and returns, at which point — and only once every
--    attachment is safe — the windows, the session, and the parents unwind in
--    dependency order.
--
-- __The outcome__ is recorded before any interruptible drain work. A body
-- failure stays primary and every drain, report, and deferred failure is
-- retained beside it under the @glfw protected retirement@ label. After a
-- successful body the first drain failure becomes primary and later ones are
-- retained. A cancellation delivered during the drain is deferred: it is
-- counted against every pending attachment as the model's evidence, never
-- establishes a fact, never replaces a recorded outcome, and is re-raised only
-- once retirement is safe — never before a window, the session, or a parent is
-- released.
withProtectedWindowHost ∷ HasCallStack ⇒ Logger → HostConfig → (WindowHost → IO r) → IO r
withProtectedWindowHost logger config =
  withProtectedWindowHostIn logger (allocSession (hostSessionConfig config)) config

-- | 'withProtectedWindowHost' over a session scope the caller supplies, such as
-- a test seam's session. The host owns the session only if that scope does.
withProtectedWindowHostIn
  ∷ HasCallStack ⇒ Logger → Scoped Session → HostConfig → (WindowHost → IO r) → IO r
withProtectedWindowHostIn = withProtectedWindowHostWith noHostHooks

-- | 'withProtectedWindowHostIn' with the private examples' hooks.
withProtectedWindowHostWith
  ∷ HasCallStack ⇒ HostHooks → Logger → Scoped Session → HostConfig → (WindowHost → IO r) → IO r
withProtectedWindowHostWith hooks logger sessionScope config use =
  -- The scope is entered under this mask, so the handler below is installed
  -- before anything at all can be delivered — including in the handoff out of
  -- the scope's own construction and into the consumer, which is a point the
  -- scope restores at. Each part still acquires exactly as it does for
  -- 'allocWindowHost', which already acquires under a mask of its own, and the
  -- consumer is lent the restore.
  mask $ \restore →
    withScoped (allocHostOver Protected hooks sessionScope config) $ \host → do
      -- Inside the handler, so an attachment this makes is drained however it
      -- then fails; the consumer follows it on the same protected path.
      outcome ← tryWithContext (restore (beforeConsumer hooks host >> use host))
      settleProtectedExit restore logger host outcome

-- | 'runWindowApplication' over a protected host lifetime.
--
-- The third argument builds the application's dependencies inside the logging
-- lifetime, so the protected host can be given the logger its stall diagnostic
-- and its wake report are written through; the fourth finds the host among
-- them. Every other step keeps the runner's order, thread, and labels: the
-- host's quiescence transaction runs before the worker drain, supervision
-- drains, and the protected host's own exit then retires attachments before its
-- windows, session, and parents unwind.
--
-- Parents the host borrows belong outside the protected lifetime, so they
-- outlive retirement; dependents the consumer builds belong inside it.
runProtectedWindowApplication
  ∷ HasCallStack
  ⇒ (∀ r. (LoggingLifetime → IO r) → IO r)
  → Text
  → (LoggingLifetime → (∀ r. (dependencies → IO r) → IO r))
  → (dependencies → WindowHost)
  → (dependencies → RuntimeControl → IO services)
  → (services → RuntimeControl → IO a)
  → IO a
runProtectedWindowApplication enterLifetime name manage host startup action =
  enterLifetime $ \lifetime →
    runManagedApplication
      (\use → use lifetime)
      name
      (\use → recordingDiagnostics lifetime (manage lifetime use))
      (quiesceWindowHost . host)
      startup
      action

-- | What the drain is lent: the owner's own native event processing and the
-- host's configured finite bound. No application hook, no dispatch, and no
-- supervisor checkpoint is among them.
retirementEnvironmentOf ∷ Logger → WindowHost → RetirementEnvironment
retirementEnvironmentOf logger host =
  RetirementEnvironment
    { environmentLogger = logger
    , environmentPoll = processWindowEvents (hostSession host) ProcessPending
    , environmentAwait = processWindowEvents (hostSession host) (AwaitEventsFor bound)
    , environmentRetireWindows = retirePending host
    , environmentBound = bound
    }
  where
    bound = hostIdleWait (hostSettings host)

-- | The protected boundary's exit: the host's own close, the drain, the wake
-- report, and the settled outcome.
settleProtectedExit
  ∷ HasCallStack
  ⇒ (∀ a. IO a → IO a)
  → Logger
  → WindowHost
  → Either (ExceptionWithContext SomeException) r
  → IO r
settleProtectedExit restore logger host outcome = case hostRetirementState host of
  Nothing → either rethrowIO pure outcome
  Just retirement → do
    -- The host's whole admission, not only its attachments': a command
    -- admitted or a demand published after this point would register a
    -- notification obligation the one degradation report below has already
    -- waited past. Idempotent, so it changes nothing when the application's
    -- own quiescence already ran before the worker drain.
    atomically (quiesceWindowHost host)
    drained ← drainRetirement retirement (retirementEnvironmentOf logger host) restore
    reported ← tryWithContext (reportHostWakeDegradationAtExit restore logger host)
    settleProtectedOutcome outcome drained reported

-- | Combine the body's outcome with what the drain and the report found.
--
-- A body failure stays primary. After a successful body the first drain
-- failure becomes primary, then the report's, then the deferred cancellation;
-- everything not chosen is retained beside the primary as labelled cleanup
-- evidence.
settleProtectedOutcome
  ∷ Either (ExceptionWithContext SomeException) r
  → DrainOutcome
  → Either (ExceptionWithContext SomeException) ()
  → IO r
settleProtectedOutcome body drained reported = case body of
  Left primary → raiseRetaining primary afterwards
  Right result → case afterwards of
    [] → pure result
    primary : retained → raiseRetaining primary retained
  where
    afterwards =
      maybe [] pure (drainPrimary drained)
        <> drainRetained drained
        <> elided
        <> either pure (const []) reported
        <> maybe [] pure (drainDeferred drained)
    elided
      | drainElided drained == 0 = []
      | otherwise =
          [ ExceptionWithContext
              emptyExceptionContext
              (toException (RetirementFailuresElided (drainElided drained)))
          ]

-- | Raise one failure with the others retained beside it, each under the
-- protected boundary's own cleanup label, in the order they happened.
--
-- Releases run inside out, so the failure to be recorded first is the innermost
-- scope: the list is reversed before it is folded, and inspection then reports
-- the evidence in the order the boundary found it.
raiseRetaining ∷ ExceptionWithContext SomeException → [ExceptionWithContext SomeException] → IO a
raiseRetaining primary = foldr retainOne (rethrowIO primary) . reverse
  where
    retainOne failure rest =
      withResourceLabelled retirementLabel (pure ()) (\() → rethrowIO failure) (\() → rest)

-- | The cleanup label the protected boundary's retained failures carry.
retirementLabel ∷ Text
retirementLabel = "glfw protected retirement"

-- | How many retirement failures the boundary counted rather than kept, when
-- more arrived than the drain's retained-failure bound keeps.
newtype RetirementFailuresElided = RetirementFailuresElided Natural
  deriving (Eq, Show)

instance Exception RetirementFailuresElided

-- ---------------------------------------------------------------------------
-- The private attachment seam

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

-- ---------------------------------------------------------------------------
-- The public attachment contract

-- | How a request to attach a graphics owner to a window was answered.
--
-- Every refusal is answered before any acquisition effect, and nothing usable
-- is published before construction and registration have both completed.
data GraphicsAttachment
  = GraphicsAttached !GraphicsService
    -- ^ Construction and registration completed and the opaque service was
    -- published.
  | GraphicsSuperseded !AttachmentId
    -- ^ Retirement had already begun by the time the service would have been
    -- published — the window started closing, or the host quiesced, while the
    -- construction ran or in the handoff after it settled. The dependents stay
    -- registered for retirement and nothing usable was published.
  | GraphicsRolledBack !RolledBack
    -- ^ Construction failed and its owned rollback settled. A rollback that
    -- established safety retired the attachment; one that could not keeps the
    -- window, the exclusive slot, and every dependency it left, with its
    -- original and cleanup evidence, for the protected boundary's own drain.
    -- Nothing usable was published either way.
  | GraphicsRefused !GraphicsRefusal
    -- ^ The reservation was refused before any acquisition effect.
  | GraphicsMetadataRejected !MetadataRejection
    -- ^ A declaration the supplied 'AttachmentProtocol' carries raised when the
    -- boundary demanded it, which it does before it reserves anything. No slot
    -- was reserved, no protocol registered, no construction entered, and no
    -- rollback run — there is no attachment to name — and the failure is handed
    -- back with the context it propagated with.
  | GraphicsHostUnprotected
    -- ^ The host was built with the @Scoped@ constructor, so it owns no
    -- retirement state and was issued no identity an attachment could name.
    -- Answered before any effect, and before the owner thread is even checked
    -- against anything the host holds.
  deriving (Show)

-- | Why a window's exclusive graphics slot was not reserved.
--
-- Every one of these is answered before the owner's construction is entered, so
-- a refusal has acquired nothing, published nothing, and left the window's slot
-- exactly as it found it.
data GraphicsRefusal
  = GraphicsWindowClosing !WindowId
    -- ^ The window's close protocol has begun, so no new graphics use may
    -- start on it.
  | GraphicsWindowUnavailable !WindowId
    -- ^ This host holds no such open window, so there is no slot of its to
    -- reserve. It may be a window of another host of the same session, or one
    -- of this host's own that has ended; the two are one answer deliberately,
    -- because telling them apart would need a record of every window this host
    -- ever held, and this boundary keeps nothing that grows with how many
    -- windows were ever made. A window of another /session/ is named as such,
    -- because a session identity is carried by the window itself.
  | GraphicsWindowOccupied !AttachmentId
    -- ^ Another owner holds the window's one exclusive slot, and holds it until
    -- it has safely retired.
  | GraphicsForeignSession
    -- ^ The window belongs to another session.
  | GraphicsAdmissionEnded
    -- ^ Attachment admission has closed — the host has quiesced or is exiting —
    -- so no new graphics use may begin at all.
  | GraphicsSlotUnavailable
    -- ^ The reservation was refused for a reason a reservation is not expected
    -- to produce. Nothing was acquired and nothing changed.
  deriving (Eq, Show)

refusalOf ∷ AttachmentRefusal → GraphicsRefusal
refusalOf = \case
  Model.WindowIsClosing window → GraphicsWindowClosing window
  Model.WindowNotRegistered window → GraphicsWindowUnavailable window
  Model.WindowHasEnded window → GraphicsWindowUnavailable window
  Model.WindowOccupied occupant → GraphicsWindowOccupied occupant
  Model.AttachmentMisuse Model.ForeignSession → GraphicsForeignSession
  _ → GraphicsSlotUnavailable

-- | Attach a graphics owner to one open window of a protected host, on the
-- owner thread.
--
-- The owner is the caller's: it supplies the construction of the dependents,
-- the bounded retirement step, the completion policy those steps are offered
-- under, and how a failed step is classified. This boundary supplies the
-- exclusivity, the ordering, and the retirement rule, and it hands back only
-- the opaque 'GraphicsService': no native pointer, no window, no session, and
-- no destruction, release, or completion authority.
--
-- The protocol's own declarations — its 'protocolCompletion' and its
-- 'protocolDisposition' — are demanded before anything is reserved, because this
-- boundary reads them itself on every later round. One that raises when it is
-- demanded answers 'GraphicsMetadataRejected' having constructed nothing, and
-- never becomes a failure raised out of a running turn or out of the protected
-- exit's own drain.
--
-- Refuses other threads with 'Hetoimasia.GLFW.Session.NotSessionOwner', and a
-- host with no retirement state with 'GraphicsHostUnprotected', each before any
-- effect.
attachWindowGraphics
  ∷ HasCallStack ⇒ WindowHost → WindowId → AttachmentProtocol → IO GraphicsAttachment
attachWindowGraphics host target protocol =
  ownerOperation (hostSession host) attachOperation (windowIdentifiers target) $
    case hostRetirementState host of
      Nothing → pure GraphicsHostUnprotected
      Just retirement →
        -- One protected region covers the reservation, the construction, and
        -- the publication together. The seam's own mask ends when it answers,
        -- and an interruption delivered between there and this answer would
        -- otherwise leave an attachment admitting use that nobody holds a
        -- service to end.
        mask $ \restore → do
          attempted ←
            tryWithContext (attachRetirement retirement restore target protocol (releaseEarlierCell host))
          case attempted of
            Right outcome → settleAttachment host retirement outcome
            Left (caught ∷ ExceptionWithContext SomeException) → do
              -- A construction that was cancelled, and a rollback that could not
              -- establish safety, both leave the attachment retiring and
              -- re-raise rather than answering. That retirement has never been
              -- offered an opportunity either, so a caller that catches this and
              -- keeps running must not wait its idle bound before one.
              atomically (markRetirementImmediate host)
              rethrowIO caught

-- | Turn a settled reservation into the public answer, inside the same
-- protected region that made it.
settleAttachment
  ∷ HasCallStack ⇒ WindowHost → HostRetirement → AttachmentOutcome → IO GraphicsAttachment
settleAttachment host retirement = \case
  AttachmentEstablished active _ → publishOrRetire host retirement (activeAttachment active)
  AttachmentSuperseded identity _ → begunRetiring (GraphicsSuperseded identity)
  AttachmentRolledBack settled → begunRetiring (GraphicsRolledBack settled)
  AttachmentRefused refusal → pure (GraphicsRefused (refusalOf refusal))
  AttachmentMetadataRejected rejected → pure (GraphicsMetadataRejected rejected)
  AttachmentAdmissionClosed → pure (GraphicsRefused GraphicsAdmissionEnded)
  AttachmentHostUnprotected → pure GraphicsHostUnprotected
  where
    -- A superseded publication and a retained rollback both leave something
    -- retiring that no turn has offered an opportunity to yet.
    begunRetiring answer = atomically (markRetirementImmediate host) >> pure answer

-- | Publish the established attachment's service, or — if anything interrupts
-- the handoff — begin its retirement before re-raising.
--
-- The window between an attachment becoming active and its caller holding the
-- service is the one place an interruption could strand the exclusive slot: the
-- attachment is registered, its dependents are built, and no service exists to
-- detach it with, while a running turn deliberately offers no opportunity to an
-- attachment that has not begun retiring. So an interruption here is counted as
-- the model's own evidence and begins exactly the retirement a detach begins,
-- and an owner turn then retires it and frees the slot. It establishes no fact,
-- and the failure is re-raised unchanged.
publishOrRetire
  ∷ HasCallStack ⇒ WindowHost → HostRetirement → AttachmentId → IO GraphicsAttachment
publishOrRetire host retirement identity = do
  attempted ← tryWithContext (beforePublication (hostHooks host) >> publishService host identity)
  case attempted of
    Right answered → pure answered
    Left (caught ∷ ExceptionWithContext SomeException) → do
      atomically $ do
        cancelAttachment retirement identity
        refreshGraphicsCells host
        markRetirementImmediate host
      rethrowIO caught

-- | Stop holding the cell of an incarnation this window's slot has moved past.
--
-- It is finalized as free and then dropped, so the window's own disposal, which
-- belongs to whichever incarnation is its last, can never be written into it.
-- It runs in the transaction that reserves the later incarnation, so every
-- reservation settles it — including one that then fails, rolls back, or is
-- cancelled without ever publishing a service.
releaseEarlierCell ∷ WindowHost → AttachmentId → STM ()
releaseEarlierCell host identity = do
  cells ← readTVar (hostGraphicsCells host)
  forM_ (Map.lookup window cells) $ \cell → do
    observed ← readGraphicsCell cell
    when (observedIncarnation observed < attachmentIncarnation identity) $ do
      writeGraphicsSlot cell SlotFree []
      writeTVar (hostGraphicsCells host) (Map.delete window cells)
  where
    window = attachmentWindow identity

-- | Make the established attachment's observation cell and its service in one
-- transaction, and only while that attachment is still the window's active
-- owner.
--
-- Publication and the check that it is still warranted commit together: a
-- quiescence, a close, or a detach that reached the attachment after its
-- construction settled has already begun its retirement, and this answers
-- 'GraphicsSuperseded' rather than handing an application a service for an
-- owner that may admit no use. The dependents stay registered for retirement
-- exactly as they do when the model supersedes the publication itself.
publishService ∷ WindowHost → AttachmentId → IO GraphicsAttachment
publishService host identity = atomically $ do
  owning ← attachmentStillActive host identity
  if not owning
    then pure (GraphicsSuperseded identity)
    else do
      cell ← newGraphicsCell (attachmentIncarnation identity) allRetirementFacts
      modifyTVar' (hostGraphicsCells host) (Map.insert (attachmentWindow identity) cell)
      refreshGraphicsCells host
      pure (GraphicsAttached (serviceFor identity cell))

-- | Whether this exact attachment still holds its window's slot and still
-- admits new use.
attachmentStillActive ∷ WindowHost → AttachmentId → STM Bool
attachmentStillActive host identity = case hostRetirementState host of
  Nothing → pure False
  Just retirement → do
    occupant ← windowAttachmentState retirement (attachmentWindow identity)
    pure $ case occupant of
      Just (held, phase, _) → held == identity && phase == AttachmentActive
      Nothing → False

-- | Detach a window's current graphics owner while the window stays open, on
-- the owner thread.
--
-- It begins exactly the retirement a close begins, under the same protocol and
-- the same owner turns, and the exclusive slot frees only once every retirement
-- fact is recorded and the owner's dependents are safely disposed. A later
-- attachment then gets a fresh incarnation, against which this one's
-- acknowledgement is refused and releases nothing.
--
-- Detaching an absent or already retiring owner is a typed no-op answer, not a
-- failure. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner', and a host with no retirement
-- state answers 'DetachAbsent'.
detachWindowGraphics ∷ HasCallStack ⇒ WindowHost → GraphicsService → IO DetachAnswer
detachWindowGraphics host service =
  ownerOperation (hostSession host) detachOperation (windowIdentifiers (attachmentWindow target)) $
    case hostRetirementState host of
      Nothing → pure DetachAbsent
      Just retirement → atomically $ do
        answered ← detachAttachment retirement target
        refreshGraphicsCells host
        -- A retirement that has just begun has never been offered an
        -- opportunity, so the next turn polls rather than waiting for one.
        when (answered == DetachBegun) (markRetirementImmediate host)
        pure answered
  where
    target = graphicsAttachment service

-- | What a window's one exclusive graphics slot holds, read in one transaction
-- from any thread.
--
-- It answers without inference: whether an owner is attached, retiring, or
-- absent, which incarnation holds the slot, which retirement facts are still
-- missing, and whether the window's own native destruction has completed. A
-- close ticket's 'Hetoimasia.GLFW.Command.WindowCloseBegun' implies none of
-- them.
windowGraphicsStatus ∷ WindowHost → WindowId → STM WindowGraphics
windowGraphicsStatus host target = case hostRetirementState host of
  Nothing → pure GraphicsWindowUnknown
  Just retirement → do
    held ← Map.member target <$> readTVar (hostEntries host)
    occupant ← windowAttachmentState retirement target
    cells ← readTVar (hostGraphicsCells host)
    case (held, occupant) of
      (False, Nothing) → pure GraphicsWindowUnknown
      (_, Nothing) → pure GraphicsAbsent
      (_, Just (identity, phase, missing)) → do
        disposal ← maybe (pure DisposalPending) (fmap observedDisposal . readGraphicsCell) (Map.lookup target cells)
        pure . GraphicsPresent $
          GraphicsObservation
            { observedIncarnation = attachmentIncarnation identity
            , observedSlot = slotOf phase
            , observedMissing = missing
            , observedDisposal = disposal
            }

-- | The service of the window's current owner, or 'Nothing' when its slot is
-- free, when the host holds no such window, or when the owner's own attachment
-- has not been published yet.
--
-- It builds no new capability: a service is an identity and the observation
-- cell the host already holds for that incarnation, so what comes back here is
-- the very service the attachment published, equal to it and interchangeable
-- with it.
--
-- It exists because a value returned from an operation is not something a
-- runtime can promise to deliver. An interruption can be delivered to the
-- calling thread at the instant 'attachWindowGraphics' restores its masking
-- state — after the attachment is active and its service published, and beyond
-- any handler that operation could install. The attachment is still perfectly
-- reachable; only the caller's copy of the answer was lost. Asking the host by
-- window returns it, so a caller that catches such an interruption and keeps
-- running can always detach what it attached.
windowGraphicsService ∷ WindowHost → WindowId → STM (Maybe GraphicsService)
windowGraphicsService host target = case hostRetirementState host of
  Nothing → pure Nothing
  Just retirement → do
    occupant ← windowAttachmentState retirement target
    cells ← readTVar (hostGraphicsCells host)
    matching ← traverse readGraphicsCell (Map.lookup target cells)
    pure $ do
      (identity, _, _) ← occupant
      cell ← Map.lookup target cells
      observed ← matching
      -- The cell of an incarnation the slot has moved past is dropped when the
      -- later one reserves, so this only ever disagrees when the later
      -- reservation published nothing at all.
      if observedIncarnation observed == attachmentIncarnation identity
        then pure (serviceFor identity cell)
        else Nothing

-- | The capability a thread that is not the owner publishes one certified
-- retirement fact through, or 'Nothing' for a host that owns no attachment
-- state.
--
-- It carries no authority over the model: an admitted notice is revalidated on
-- the owner thread exactly as an owner-thread report is, so one queued for a
-- replaced incarnation is refused when it is folded and touches the replacement
-- not at all. Publishing wakes the owner exactly as a command admission does.
hostGraphicsPublisher ∷ WindowHost → Maybe CompletionPublisher
hostGraphicsPublisher = hostCompletionPublisher

-- | Certify one retirement fact on the owner thread, from inside the owner's
-- own protocol. It is 'reportHostRetirementFact' under the name the public
-- contract uses.
certifyGraphicsFact
  ∷ HasCallStack ⇒ WindowHost → Acknowledgement → RetirementFact → IO (Maybe FactAnswer)
certifyGraphicsFact = reportHostRetirementFact

-- | What the last turn's bounded round of retirement opportunities left owed.
--
-- It is the retirement side of the scheduling arc: the scheduled owner loop
-- reads it in the same inspection that captures demand, so a retirement that
-- wants another opportunity now is not delayed by the idle wait, and one that
-- named an instant is served at it. Any thread may read it; every count is
-- bounded by the live windows.
data RetirementDemand = RetirementDemand
  { retirementPending ∷ !Int
    -- ^ Attachments registered and not yet retired.
  , retirementStalled ∷ !Int
    -- ^ Of those, the ones with no progress path left, which only independent
    -- evidence revives.
  , retirementRefused ∷ !Int
    -- ^ Opportunities the last round refused because their owner declared a
    -- blocking step. The step itself was never run.
  , retirementImmediate ∷ !Bool
    -- ^ Whether another opportunity is wanted at once: the last round advanced
    -- something, or some pending attachment is owed an opportunity it has not
    -- had — one whose retirement no round has yet offered one to, one whose
    -- path fresh evidence has just revived, or one whose latest opportunity
    -- advanced. Attachments that have all been inspected and are waiting owe
    -- nothing, however many of them the budget leaves unserved.
  , retirementNextPossible ∷ !(Maybe Instant)
    -- ^ The earliest instant any waiting attachment is waiting until, in
    -- 'hostClock'\'s domain, across every one of them rather than only the ones
    -- the last round reached.
  }
  deriving (Eq, Show)

-- | No attachment pending and nothing owed, which is what an ordinary host
-- always reports.
noRetirementDemand ∷ RetirementDemand
noRetirementDemand = RetirementDemand 0 0 0 False Nothing

hostRetirementDemand ∷ WindowHost → STM RetirementDemand
hostRetirementDemand = readTVar . hostRetirementDemandState

-- | Record that a retirement wants an opportunity now.
--
-- Every round republishes the demand from its own accounting, so this is only
-- ever read by the turn that follows a transaction the round did not see: one
-- that began a retirement, or one that recorded a retirement fact on the owner
-- thread — which is exactly the turn that would otherwise wait its idle bound
-- before offering that attachment the opportunity it is owed. It says so only
-- when something really is retiring, so an ordinary host, and a protected host
-- with nothing pending, report no demand at all.
markRetirementImmediate ∷ WindowHost → STM ()
markRetirementImmediate host =
  demandRetirementNow (hostRetirementState host) (hostRetirementDemandState host)

demandRetirementNow ∷ Maybe HostRetirement → TVar RetirementDemand → STM ()
demandRetirementNow held owed = case held of
  Nothing → pure ()
  Just retirement → do
    retiring ← anyRetiring retirement
    when retiring (modifyTVar' owed (\demand → demand {retirementImmediate = True}))

-- | Answer the published demand's two scheduling questions from what the
-- registrations now say, for a transaction that changed them between two
-- rounds.
--
-- Only the two the owner loops actually pace themselves by. The counts stay the
-- last round's own accounting, which is what they are documented to report, and
-- a refusal count cannot be recomputed from retained state at all.
--
-- Both are replaced rather than widened, because evidence that retires an
-- attachment withdraws the reasons for hurrying as readily as evidence that
-- revives one creates them: an attachment that has just retired is waiting on
-- nothing and is owed nothing, and carrying either answer forward would pace
-- the next turn by an attachment that no longer exists. Nothing the last round
-- or this window said is lost by that. A retirement begun since the round is
-- registered, progressing, and has never been offered an opportunity, so the
-- standing reports it owed on its own; a round that advanced an attachment
-- which is still pending left it wanting another opportunity, so the standing
-- reports that too; and a round that advanced one to completion has nothing
-- left to offer an opportunity to and released its window in that same turn.
resettleRetirementDemand ∷ WindowHost → STM ()
resettleRetirementDemand host = case hostRetirementState host of
  Nothing → pure ()
  Just retirement → do
    (owed, next) ← retirementStanding retirement
    modifyTVar'
      (hostRetirementDemandState host)
      (\demand → demand {retirementImmediate = owed, retirementNextPossible = next})

-- | Offer one bounded, rotating round of retirement opportunities, and publish
-- what it left owed. An ordinary host has no attachment state and does nothing
-- at all here.
advanceHostRetirements ∷ WindowHost → IO ()
advanceHostRetirements host = case hostRetirementState host of
  Nothing → pure ()
  Just retirement → do
    round' ←
      advanceRetirements retirement (hostRetireCursor host) (hostRetirementBudget (hostSettings host))
    atomically $ do
      refreshGraphicsCells host
      writeTVar (hostRetirementDemandState host) (demandOf round')

demandOf ∷ ProgressRound → RetirementDemand
demandOf round' =
  RetirementDemand
    { retirementPending = roundPending round'
    , retirementStalled = roundStalled round'
    , retirementRefused = roundRefused round'
    , retirementImmediate = roundAdvanced round' > 0 || roundOwed round' > 0
    , retirementNextPossible = roundNextPossible round'
    }

-- | Bring every cell the host holds up to what the model now says about its
-- window's slot.
--
-- A cell whose incarnation no longer holds the slot is finalized as free: it
-- has retired, or a later incarnation replaced it, and either way this one owes
-- nothing more. The disposal a cell already carries is never overwritten here;
-- only the window's own retirement writes one.
refreshGraphicsCells ∷ WindowHost → STM ()
refreshGraphicsCells host = refreshCells (hostRetirementState host) (hostGraphicsCells host)

-- | 'refreshGraphicsCells' over the two pieces alone, for the admission-closing
-- release, which is installed before the host value it belongs to exists.
refreshCells ∷ Maybe HostRetirement → TVar (Map WindowId GraphicsCell) → STM ()
refreshCells held slots = case held of
  Nothing → pure ()
  Just retirement → do
    cells ← readTVar slots
    forM_ (Map.toList cells) $ \(window, cell) → do
      observed ← readGraphicsCell cell
      occupant ← windowAttachmentState retirement window
      case occupant of
        Just (identity, phase, missing)
          | attachmentIncarnation identity == observedIncarnation observed →
              writeGraphicsSlot cell (slotOf phase) missing
        _ → writeGraphicsSlot cell SlotFree []

slotOf ∷ AttachmentPhase → SlotState
slotOf = \case
  AttachmentRegistering → SlotAttached
  AttachmentActive → SlotAttached
  AttachmentRetiring → SlotRetiring
  AttachmentRetired → SlotFree
