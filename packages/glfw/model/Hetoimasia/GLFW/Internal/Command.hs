-- | Bounded window command admission and completion.
--
-- A 'WindowCommandHost' is the owner's side of one window command service. It
-- is created on the session's owner thread with a capacity, and it hands out
-- the client 'WindowCommandPort', closes admission, reads statistics, and
-- performs a command directly. A port can only submit. Submissions are admitted
-- into a bounded FIFO channel of prepared messages from
-- "Hetoimasia.Foundation.Messaging.Channel"; this module adds the per-request
-- completion that channel deliberately does not provide.
--
-- = Admission
--
-- A 'WindowCommand' is an immutable value: a request to observe, control, or
-- close one window, or to create a window from a 'WindowConfig'. Submitting
-- one issues a request identity, records the submission site and the caller's
-- diagnostic context beside it as a 'CommandOrigin', and prepares the message
-- to normal form on the submitting thread before anything is admitted.
-- 'submitWindowCommand' never waits: it answers 'SubmitFull' when the host holds
-- capacity queued commands and 'SubmitClosed' once admission has ended, and
-- 'SubmitClosed' takes precedence. 'awaitSubmitWindowCommand' is the separate
-- operation that waits for capacity; it is cancellable, and closure ends it with
-- 'WaitClosed'.
--
-- The message and its completion cell are added in one transaction: the
-- message to the channel, and the cell, keyed by request, to the host's pending
-- map. The cell is never inside the message. A full or closed answer, a
-- transaction that rolls back, and a cancellation before that transaction
-- commits leave neither. A cancellation after it commits withdraws nothing: the
-- command stays queued and settles, even if its caller never received the
-- 'CompletionTicket'. Request identities are never reissued, even for a
-- submission that was not admitted; they identify a request, and they do not
-- order requests.
--
-- An admission that committed wakes the session's owner, through
-- "Hetoimasia.GLFW.Internal.Notify"'s policy, so a command submitted while the
-- owner sits in a native wait ends that wait. The command is recorded first and
-- the hint posted after, and the admitting transaction registers the obligation
-- to post it, so the owner's boundaries can see that a wake is owed before the
-- submitting thread has run another instruction. A full or closed answer
-- registers nothing and wakes nothing. The obligation
-- is held from the commit onward — the commit and the wake run under a mask,
-- and the wake itself uninterruptibly — so nothing delivered to the submitting
-- thread can drop it. The waiting operation keeps that protection while staying
-- cancellable: its wait for capacity blocks in a transaction, which is an
-- interruptible operation even under the mask, so a cancellation delivered
-- while it waits aborts it and admits nothing, and no interruptible point
-- separates the commit that follows from the wake it owes. The answer and the ticket
-- never depend on the wake's outcome: an expected platform failure degrades the
-- session's wake path and leaves both untouched, and a programming or lifetime
-- violation propagates to the submitter with the command still admitted and
-- still settling exactly once.
--
-- = Dispositions
--
-- Every admitted command settles exactly once, to one 'Disposition':
--
-- * 'Performed', with prepared 'CommandResult' data;
-- * 'Rejected', with a typed 'CommandRejection', when nothing was applied — a
--   window the executor does not serve, a window that has ended or is closing,
--   a command outside the port's scope, a creation or control refused before any
--   native effect, or a native failure, carried as copied code and description
--   data;
-- * 'Unsupported', when the platform cannot perform a control, with its reason
--   and no native call;
-- * 'Attempted', when a control's native calls were made: whether they returned,
--   reported errors, or stopped part-way through a constraint update, and the
--   revision the sample taken after them published. A returned call is never
--   reported as the state the window reached;
-- * 'NotExecuted', when closure settled it while it was still queued;
-- * 'Interrupted', with its request identity, when its execution or the
--   preparation of its completion data raised. Effects may have been applied;
--   nothing is replayed and nothing is rolled back.
--
-- A settled cell is never written again, and a command never disappears.
-- Completion data is prepared before it is settled. An arbitrary Haskell
-- exception is never serialized into a ticket: the ticket names only the
-- interrupted request, and the exception propagates from the executor with its
-- own type and context.
--
-- = The creation handoff
--
-- A creation that succeeds settles as 'Performed' 'WindowCreated', naming the new
-- window: ordinary data, prepared like every other disposition. The new window's
-- client capabilities — its own command port and its read-only observations —
-- are not data and are never prepared or put inside a message. They travel as a
-- 'WindowClient' written beside the prepared disposition in the settling
-- transaction, and 'pollWindowClient' reads them from the ticket. The executor
-- hands them over only after the window was constructed, registered with its
-- owner, and published its initial observation. A 'WindowClient' carries no
-- native handle and no release, retirement, or creation authority. A creation
-- interrupted before its settlement, including after registration, settles as
-- 'Interrupted' with no capabilities; the window's owner still owns it.
--
-- = Port scope
--
-- A host created by 'newWindowCommandHost' serves every command. A window's own
-- host, created privately for one window, serves only that window: its port can
-- submit anything, but the executor settles a creation as 'Rejected'
-- 'CreationNotPermitted' and a command addressed to another window as 'Rejected'
-- 'WindowNotServed', each without executing it and each costing its dispatch
-- attempt. A window's port therefore grants no authority over another window and
-- no authority to create one.
--
-- = Tickets
--
-- A ticket is persistent and non-consuming. 'pollCompletion' reads it in 'STM'
-- without waiting, as often as desired, and 'awaitCompletion' waits for it from
-- any thread but the owner; cancelling that wait changes nothing about the
-- command, and dropping the ticket cancels nothing. A ticket stays readable
-- after its cell has left the host's bookkeeping and after closure.
--
-- The owner thread is the only thread that executes commands, so no public
-- operation waits for one there. On the owner thread, 'awaitCompletion' of an
-- unsettled ticket and 'awaitSubmitWindowCommand' on a full host fail with
-- 'OwnerThreadWouldWait' instead of waiting forever. The owner uses
-- 'performWindowCommand', the direct checked execution operation, which
-- involves no queue, cell, or ticket.
--
-- = Execution
--
-- An executor claims queued commands in the order their admissions committed.
-- A claim moves the command from queued to active in the transaction that
-- receives it, and the whole claimed lifetime, including the preparation of its
-- completion data, is protected: whatever it raises, synchronous or not, the
-- command settles as 'Interrupted' before the original exception is rethrown.
-- A synchronous failure gains the @execute window command@ operation context,
-- naming the request, the window, the submission site, and the caller's
-- context, so crossing the queue keeps where a request came from; the failure's
-- origin stays at the operation that raised it.
--
-- The executor protocol, 'executeNextWith', is private to this package. Its one
-- production caller is the window host's owner loop in "Hetoimasia.Runtime.GLFW";
-- the test seam's private executor also drives it in CPU examples.
--
-- 'observeWindowCommand' synchronizes the addressed window at an owner
-- boundary, which samples and publishes through
-- "Hetoimasia.GLFW.Internal.Window"'s observation contract, and answers with
-- the revision of the committed observation that followed: a new revision when
-- sampling changed anything, and otherwise the published one the sample
-- matched. It never samples another window.
--
-- A control command executes "Hetoimasia.GLFW.Internal.Window"'s
-- 'controlWindow' on the addressed window and settles as rejected, unsupported,
-- or attempted. A mode command executes 'transitionWindow' and settles as
-- rejected or unsupported when it was refused before any native call with no
-- fallback to take, and otherwise as 'Transitioned' with its outcome and the
-- revision its final sample published.
--
-- 'closeWindowCommand' and 'createWindowCommand' change which windows exist, so
-- only an executor that owns window lifetimes performs them: the window host's
-- owner loop in "Hetoimasia.Runtime.GLFW". The executor over lexically scoped
-- windows, used by 'performWindowCommand' and the test seam, settles them as
-- 'Rejected' 'CloseNotPermitted' and 'CreationNotPermitted'.
--
-- = Bookkeeping
--
-- The pending map holds one cell per queued or active command and nothing
-- else, so it never holds more than the capacity plus the commands being
-- executed. Settlement writes a cell and removes it in one transaction; there is
-- no result queue and no request history.
--
-- = Closure
--
-- 'closeWindowCommands' ends admission and, in the same transaction, settles
-- every command still queued at its commit as 'NotExecuted' and removes it, so
-- no queued command runs afterwards and no ticket waiter is left waiting. A
-- command already claimed is active work: closure neither waits for it nor
-- reports it unexecuted, and it settles through its execution. Closure is
-- finite, never retries, is idempotent, and is not an abort: there is no abort.
--
-- = State
--
-- +----------------------+-------------+-----------------------------+------------------------+-----------------------+----------------------------+
-- | State                | Owner       | Readers and writers         | Thread                 | Lifetime              | Reset or disposal          |
-- +======================+=============+=============================+========================+=======================+============================+
-- | Command channel      | The host    | Ports admit; the executor   | Admit: any; claim and  | The host, while       | Closed by closure; its     |
-- |                      |             | claims; closure drains      | close: owner           | referenced            | backlog settled, never     |
-- |                      |             |                             |                        |                       | reopened                   |
-- +----------------------+-------------+-----------------------------+------------------------+-----------------------+----------------------------+
-- | Pending cells        | The host    | Admission reserves;         | Reserve: any; settle:  | Admission until       | Removed at settlement      |
-- |                      |             | settlement and closure      | owner                  | settlement            |                            |
-- |                      |             | remove                      |                        |                       |                            |
-- +----------------------+-------------+-----------------------------+------------------------+-----------------------+----------------------------+
-- | Active count         | The host    | Claims raise it;            | Owner                  | The host              | Zero whenever nothing is   |
-- |                      |             | settlements lower it        |                        |                       | executing                  |
-- +----------------------+-------------+-----------------------------+------------------------+-----------------------+----------------------------+
-- | Completion cell      | Its ticket  | Settled once, with any      | Settle: owner; read:   | While a ticket        | Never reset                |
-- |                      |             | created window's client     | any                    | references it         |                            |
-- |                      |             | beside the prepared         |                        |                       |                            |
-- |                      |             | disposition; tickets read   |                        |                       |                            |
-- +----------------------+-------------+-----------------------------+------------------------+-----------------------+----------------------------+
-- | Admission flag       | The host    | Closure sets it; direct     | Owner                  | The host              | Never cleared              |
-- |                      |             | performance reads it        |                        |                       |                            |
-- +----------------------+-------------+-----------------------------+------------------------+-----------------------+----------------------------+
-- | Request counter      | The port    | Submissions issue from it   | Any; atomic            | The host              | Never reissued             |
-- +----------------------+-------------+-----------------------------+------------------------+-----------------------+----------------------------+
-- | Port scope           | The host    | Fixed at creation; the      | Any                    | The host              | Immutable                  |
-- |                      |             | executor reads it           |                        |                       |                            |
-- +----------------------+-------------+-----------------------------+------------------------+-----------------------+----------------------------+
-- | Notifier             | The session | Every admission notifies    | Any                    | The session           | The degradation is the     |
-- |                      |             | through it                  |                        |                       | session's; never reset     |
-- +----------------------+-------------+-----------------------------+------------------------+-----------------------+----------------------------+
--
-- None of this is application state, and none of it holds a native handle.
module Hetoimasia.GLFW.Internal.Command
  ( -- * Hosts
    WindowCommandHost
  , newWindowCommandHost
  , windowCommandPort
  , closeWindowCommands
  , CommandStatistics (..)
  , commandStatistics
  , performWindowCommand

    -- * Ports and submission
  , WindowCommandPort
  , SubmitResult (..)
  , submitWindowCommand
  , WaitedSubmission (..)
  , awaitSubmitWindowCommand

    -- * Commands
  , WindowCommand (..)
  , observeWindowCommand
  , closeWindowCommand
  , createWindowCommand
  , commandWindow

    -- * Control commands
  , setWindowTitleCommand
  , setWindowSizeCommand
  , setWindowPositionCommand
  , setSizeConstraintsCommand
  , showWindowCommand
  , hideWindowCommand
  , requestFocusCommand
  , requestAttentionCommand
  , minimizeWindowCommand
  , maximizeWindowCommand
  , restoreWindowCommand

    -- * Mode commands
  , setWindowModeCommand
  , ModeTransition (..)

    -- * Origins
  , RequestId
  , requestLocalIdentity
  , CommandOrigin
  , submittedRequest
  , submittedWindow
  , submittedAt
  , submittedContext

    -- * Completion
  , CompletionTicket
  , ticketOrigin
  , pollCompletion
  , awaitCompletion
  , Disposition (..)
  , CommandResult (..)
  , CommandRejection (..)
  , UnsupportedControl (..)
  , ControlAttempt (..)

    -- * Window clients
  , WindowClient
  , clientWindow
  , clientCommandPort
  , clientObservations
  , clientInputReader
  , clientInputControl
  , clientDemandPublisher
  , pollWindowClient

    -- * Misuse
  , WindowCommandMisuse (..)

    -- * Private executor protocol
  , commandHostSession
  , AdmissionHooks (..)
  , noAdmissionHooks
  , submitWith
  , awaitSubmitWith
  , commandsAdmissionClosed
  , commandHostNotifier
  , ExecutionStep (..)
  , Execution (..)
  , executeNextWith
  , executeCommand
  , observeWindow
  , controlDisposition
  , modeDisposition
  , nativeRejectionOf

    -- * Private window ports
  , PortScope (..)
  , newWindowPortHost
  , newWindowClient
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVar, newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.DeepSeq (NFData (rnf))
import Control.Monad (void)
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , mask
  , mask_
  , rethrowIO
  , tryWithContext
  , uninterruptibleMask_
  )
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Unique (Unique, newUnique)
import GHC.Stack (CallStack, HasCallStack, callStack, getCallStack, srcLocFile, srcLocStartLine)
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (originOperation)
  , FailureSite (..)
  , Operation
  , OperationContext (contextOperation)
  , failureEvidenceInContext
  , operation
  , operationText
  , throwFailure
  , withOperationContext
  )
import Hetoimasia.Foundation.Log (SourceLocation (..))
import Hetoimasia.Foundation.Messaging.Channel
  ( Admission (..)
  , ChannelControl
  , ChannelStatistics (statisticsCapacity, statisticsDepth)
  , Receipt (..)
  , SendResult (..)
  , Sender
  , awaitSend
  , channelReceiver
  , channelSender
  , channelStatistics
  , closeChannel
  , newChannel
  , receive
  , send
  )
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (SnapshotReader)
import Hetoimasia.GLFW.Internal.Attribute (Extent (..), Placement (..))
import Hetoimasia.GLFW.Internal.Capture (Reports, rnfReports)
import Hetoimasia.GLFW.Internal.Demand (DemandPublisher)
import Hetoimasia.GLFW.Internal.Notify (Notifier, dischargeNotification, registerNotification, sessionNotifier)
import Hetoimasia.GLFW.Internal.Input (InputControl, InputReader)
import Hetoimasia.GLFW.Internal.Control
  ( ControlOutcome
  , ControlRejection
  , ControlResult (..)
  , PostCallObservation
  , PresentationKind (..)
  , SizeConstraints
  , WindowControl (..)
  , WindowOperation (..)
  )
import Hetoimasia.GLFW.Internal.Mode (ModeOutcome, ModeRejection, ModeRequest, ModeResult (..), modePresentation, requestedMode)
import Hetoimasia.GLFW.Internal.Session
  ( NativeFailure (..)
  , NativeOutcome
  , Session
  , glfwComponent
  , ownerOperation
  , sessionOwner
  )
import Hetoimasia.GLFW.Internal.Window
  ( Window
  , WindowConfig
  , WindowConfigRejected
  , WindowId
  , WindowObservation
  , WindowResult (..)
  , controlWindow
  , observedRevision
  , transitionWindow
  , synchronizeWindow
  , windowCallbackOperation
  , windowIdentity
  , windowLocalIdentity
  )
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Commands and origins

-- | One immutable window command. Its representation is private, so a command
-- is only ever one of the commands this module defines.
data WindowCommand
  = ObserveWindow !WindowId
  | CloseWindow !WindowId
  | CreateWindow !WindowConfig
  | ControlWindow !WindowId !WindowControl
  | ModeWindow !WindowId !ModeRequest
  deriving (Eq, Show)

instance NFData WindowCommand where
  rnf (ObserveWindow window) = rnf window
  rnf (CloseWindow window) = rnf window
  rnf (CreateWindow config) = rnf config
  rnf (ControlWindow window control) = rnf window `seq` rnf control
  rnf (ModeWindow window request) = rnf window `seq` rnf request

-- | Ask the owner to sample the window and publish a fresh observation of it at
-- its next safe boundary.
observeWindowCommand ∷ WindowId → WindowCommand
observeWindowCommand = ObserveWindow

-- | Ask the owner to begin the window's close protocol. Only an executor that
-- owns window lifetimes performs it.
closeWindowCommand ∷ WindowId → WindowCommand
closeWindowCommand = CloseWindow

-- | Ask the owner to create a window from the configuration. Only an executor
-- that owns window lifetimes performs it, and only through a port with creation
-- authority.
createWindowCommand ∷ WindowConfig → WindowCommand
createWindowCommand = CreateWindow

-- | The window a command is addressed to; 'Nothing' for a creation.
commandWindow ∷ WindowCommand → Maybe WindowId
commandWindow (ObserveWindow window) = Just window
commandWindow (CloseWindow window) = Just window
commandWindow (CreateWindow _) = Nothing
commandWindow (ControlWindow window _) = Just window
commandWindow (ModeWindow window _) = Just window

-- | Ask the owner to set the window's title. A title containing a NUL is
-- rejected when the command executes.
setWindowTitleCommand ∷ WindowId → Text → WindowCommand
setWindowTitleCommand window = ControlWindow window . TitleControl

-- | Ask the owner to set the window's logical size. A size that is not positive,
-- not representable, or outside the window's fully known active constraints is
-- rejected when the command executes, and never sent for the platform to clamp.
setWindowSizeCommand ∷ WindowId → Extent → WindowCommand
setWindowSizeCommand window (Extent width height) = ControlWindow window (SizeControl width height)

-- | Ask the owner to move the window's content area to a desktop position.
setWindowPositionCommand ∷ WindowId → Placement → WindowCommand
setWindowPositionCommand window (Placement x y) = ControlWindow window (PositionControl x y)

-- | Ask the owner to replace the window's size constraints. The whole set is
-- validated, against the window's latest observed size too, when the command
-- executes.
setSizeConstraintsCommand ∷ WindowId → SizeConstraints → WindowCommand
setSizeConstraintsCommand window = ControlWindow window . ConstraintsControl

showWindowCommand, hideWindowCommand, requestFocusCommand, requestAttentionCommand ∷ WindowId → WindowCommand
-- | Ask the owner to show the window.
showWindowCommand window = ControlWindow window ShowControl
-- | Ask the owner to hide the window.
hideWindowCommand window = ControlWindow window HideControl
-- | Ask the platform to give the window input focus. The request may be
-- declined; the window's observations report what happened.
requestFocusCommand window = ControlWindow window FocusControl
-- | Ask the platform to draw the user's attention to the window.
requestAttentionCommand window = ControlWindow window AttentionControl

minimizeWindowCommand, maximizeWindowCommand, restoreWindowCommand ∷ WindowId → WindowCommand
-- | Ask the owner to minimize (iconify) the window.
minimizeWindowCommand window = ControlWindow window MinimizeControl
-- | Ask the owner to maximize the window.
maximizeWindowCommand window = ControlWindow window MaximizeControl
-- | Ask the owner to restore a minimized or maximized window.
restoreWindowCommand window = ControlWindow window RestoreControl

-- | Ask the owner to transition the window to a mode, with a fallback. The
-- request, its monitor, and its video mode are validated against the window and
-- the monitors reported when the command executes.
setWindowModeCommand ∷ WindowId → ModeRequest → WindowCommand
setWindowModeCommand = ModeWindow

-- | A request's identity: its host's identity and a local number that host never
-- reissues. Only the local number is displayed.
data RequestId = RequestId !Unique !Natural
  deriving (Eq, Ord)

instance Show RequestId where
  showsPrec precedence (RequestId _ local) =
    showParen (precedence > 10) (showString "RequestId " . showsPrec 11 local)

instance NFData RequestId where
  rnf (RequestId host local) = host `seq` rnf local

-- | The request's number within its host, starting at one.
requestLocalIdentity ∷ RequestId → Natural
requestLocalIdentity (RequestId _ local) = local

-- | Where a request came from, prepared with it.
data CommandOrigin = CommandOrigin
  { originRequestId ∷ !RequestId
  , originTarget ∷ !(Maybe WindowId)
  , originSubmissionSite ∷ !(Maybe FailureSite)
  , originCallerContext ∷ ![(Text, Text)]
  }
  deriving (Eq, Show)

instance NFData CommandOrigin where
  rnf origin =
    rnf (originRequestId origin)
      `seq` rnf (originTarget origin)
      `seq` rnfSite (originSubmissionSite origin)
      `seq` rnf (originCallerContext origin)

-- | The request's identity.
submittedRequest ∷ CommandOrigin → RequestId
submittedRequest = originRequestId

-- | The window the request was addressed to; 'Nothing' for a creation.
submittedWindow ∷ CommandOrigin → Maybe WindowId
submittedWindow = originTarget

-- | Where the request was submitted: the outermost call-stack frame and the
-- whole stack, under the failure module's attribution policy. 'Nothing' only
-- when the caller's call stack was empty.
submittedAt ∷ CommandOrigin → Maybe FailureSite
submittedAt = originSubmissionSite

-- | The diagnostic context the caller supplied, in the order supplied.
submittedContext ∷ CommandOrigin → [(Text, Text)]
submittedContext = originCallerContext

-- | The message a port admits: the command and its origin, and no cell.
data Submission = Submission !CommandOrigin !WindowCommand

instance NFData Submission where
  rnf (Submission origin command) = rnf origin `seq` rnf command

-- | The site a submission was made at.
submissionSite ∷ CallStack → Maybe FailureSite
submissionSite stack = case map located (getCallStack stack) of
  [] → Nothing
  frames → Just (FailureSite (last frames) frames)
  where
    located (name, location) =
      SourceLocation
        { sourceFile = Text.pack (srcLocFile location)
        , sourceLine = srcLocStartLine location
        , sourceFunction = Text.pack name
        }

rnfSite ∷ Maybe FailureSite → ()
rnfSite Nothing = ()
rnfSite (Just (FailureSite location frames)) = rnfLocation location `seq` foldr (seq . rnfLocation) () frames
  where
    rnfLocation (SourceLocation file line function) = rnf file `seq` rnf line `seq` rnf function

-- | The identifiers a failure raised while executing or waiting for a request
-- is given: the request, its window, its submission site, and the caller's
-- context.
originIdentifiers ∷ CommandOrigin → [(Text, Text)]
originIdentifiers origin =
  [("request", Text.pack (show (requestLocalIdentity (originRequestId origin))))]
    <> maybe [] (\window → [("window", Text.pack (show (windowLocalIdentity window)))]) (originTarget origin)
    <> maybe [] (\site → [("submitted-at", siteText site)]) (originSubmissionSite origin)
    <> originCallerContext origin
  where
    siteText site =
      sourceFile (siteLocation site) <> ":" <> Text.pack (show (sourceLine (siteLocation site)))

-- ---------------------------------------------------------------------------
-- Dispositions

-- | How an admitted command settled.
data Disposition
  = Performed !CommandResult
    -- ^ Performed, or requested from the window system.
  | Rejected !CommandRejection
    -- ^ Not performed, for a typed reason; nothing was applied.
  | Unsupported !UnsupportedControl
    -- ^ The platform cannot perform the control; no native call was made.
  | Attempted !ControlAttempt
    -- ^ The control's native calls were made. Whether the window reached the
    -- requested state is what its observations report.
  | Transitioned !ModeTransition
    -- ^ A mode request executed, whether inert, applied, failed, or stopped.
    -- Whether the window reached the mode is what its observations report.
  | NotExecuted
    -- ^ Closure settled it while it was still queued.
  | Interrupted !RequestId
    -- ^ Its execution raised; effects may have been applied, and nothing was
    -- replayed.
  deriving (Eq, Show)

instance NFData Disposition where
  rnf (Performed result) = rnf result
  rnf (Rejected rejection) = rnf rejection
  rnf (Unsupported unsupported) = rnf unsupported
  rnf (Attempted attempt) = rnf attempt
  rnf (Transitioned transition) = rnf transition
  rnf NotExecuted = ()
  rnf (Interrupted request) = rnf request

-- | A control the platform cannot perform.
data UnsupportedControl = UnsupportedControl
  { unsupportedWindow ∷ !WindowId
  , unsupportedOperation ∷ !WindowOperation
  , unsupportedReason ∷ !Text
  }
  deriving (Eq, Show)

instance NFData UnsupportedControl where
  rnf (UnsupportedControl window wanted reason) = rnf window `seq` rnf wanted `seq` rnf reason

-- | A control whose native calls were made.
data ControlAttempt = ControlAttempt
  { attemptedWindow ∷ !WindowId
  , attemptedOutcome ∷ !ControlOutcome
    -- ^ How the native calls returned.
  , attemptedObservation ∷ !PostCallObservation
    -- ^ The revision the sample taken after them published, or why none was.
  }
  deriving (Eq, Show)

instance NFData ControlAttempt where
  rnf (ControlAttempt window outcome observation) = rnf window `seq` rnf outcome `seq` rnf observation

-- | A mode request that executed.
data ModeTransition = ModeTransition
  { transitionedWindow ∷ !WindowId
  , transitionOutcome ∷ !ModeOutcome
  , transitionObservation ∷ !PostCallObservation
    -- ^ The revision the sample taken after the transition published, or why
    -- none was.
  }
  deriving (Eq, Show)

instance NFData ModeTransition where
  rnf (ModeTransition window outcome observation) = rnf window `seq` rnf outcome `seq` rnf observation

-- | What a performed command produced.
data CommandResult
  = ObservationPublished
      { publishedWindow ∷ !WindowId
      , publishedRevision ∷ !Natural
        -- ^ The revision of the committed observation that followed the sample.
      }
  | WindowCreated
      { createdWindow ∷ !WindowId
        -- ^ The new window. Its client capabilities are read from the ticket
        -- with 'pollWindowClient'.
      }
  | WindowCloseBegun
      { closingWindow ∷ !WindowId
        -- ^ The window whose close protocol began: its admission closed and its
        -- queued commands settled. Its disposal is reported by its observations.
      }
  deriving (Eq, Show)

instance NFData CommandResult where
  rnf (ObservationPublished window revision) = rnf window `seq` rnf revision
  rnf (WindowCreated window) = rnf window
  rnf (WindowCloseBegun window) = rnf window

-- | Why a command was not performed.
data CommandRejection
  = WindowNotServed !WindowId
    -- ^ The executor serves no window with this identity.
  | WindowAlreadyEnded !WindowId
    -- ^ The window has ended; no native call was made.
  | WindowNativeFailure
      { failedWindow ∷ !WindowId
      , failedOperation ∷ !(Maybe Text)
        -- ^ The operation the native failure was raised by.
      , failedOutcome ∷ !NativeOutcome
      , failedReports ∷ !Reports
        -- ^ The codes and descriptions GLFW reported, copied.
      }
    -- ^ A native call failed before anything was published.
  | WindowIsClosing !WindowId
    -- ^ The window's close protocol has begun; nothing was performed.
  | CloseNotPermitted !WindowId
    -- ^ The executor does not own this window's lifetime, which ends with its
    -- scope.
  | CreationNotPermitted
    -- ^ The port has no creation authority, or the executor cannot create.
  | WindowConfigInvalid !WindowConfigRejected
    -- ^ The configuration was refused before any native call.
  | WindowCapacityReached !Int
    -- ^ The owner already holds this many live windows, its fixed limit. No
    -- native call was made and nothing waited.
  | WindowCreationPoisoned
    -- ^ An earlier release failure poisoned further creation. No native call was
    -- made.
  | WindowCreationFailed
      { creationOperation ∷ !(Maybe Text)
        -- ^ The operation the native failure was raised by.
      , creationOutcome ∷ !NativeOutcome
      , creationReports ∷ !Reports
        -- ^ The codes and descriptions GLFW reported, copied.
      }
    -- ^ A native call failed during construction, and the rollback released
    -- everything construction had acquired: no window was registered and no
    -- capacity was consumed. A construction whose rollback's own release
    -- failed is never this rejection: the construction failure propagates with
    -- the rollback failure retained as cleanup evidence, interrupting the
    -- command.
  | ControlRejected !WindowId !ControlRejection
    -- ^ A control was refused before any native call.
  | ModeRejected !WindowId !ModeRejection
    -- ^ A mode request was refused before any native call, with no fallback to
    -- take.
  deriving (Eq, Show)

instance NFData CommandRejection where
  rnf (WindowNotServed window) = rnf window
  rnf (WindowAlreadyEnded window) = rnf window
  rnf (WindowNativeFailure window failed outcome reports) =
    rnf window `seq` rnf failed `seq` outcome `seq` rnfReports reports
  rnf (WindowIsClosing window) = rnf window
  rnf (CloseNotPermitted window) = rnf window
  rnf CreationNotPermitted = ()
  rnf (WindowConfigInvalid rejected) = rnf rejected
  rnf (WindowCapacityReached limit) = rnf limit
  rnf WindowCreationPoisoned = ()
  rnf (WindowCreationFailed failed outcome reports) =
    rnf failed `seq` outcome `seq` rnfReports reports
  rnf (ControlRejected window rejection) = rnf window `seq` rnf rejection
  rnf (ModeRejected window rejection) = rnf window `seq` rnf rejection

-- | A command operation that would wait for work only the waiting thread can
-- do.
data WindowCommandMisuse
  = OwnerThreadWouldWait
    -- ^ The owner thread asked to wait for a command's completion, or for
    -- command capacity; only the owner thread can provide either.
  deriving (Eq, Show)

instance Exception WindowCommandMisuse

newHostOperation, submitOperation, awaitCompletionOperation, executeOperation, performOperation ∷ Operation
newHostOperation = operation "new window command host"
submitOperation = operation "submit window command"
awaitCompletionOperation = operation "await window command"
executeOperation = operation "execute window command"
performOperation = operation "perform window command"

-- ---------------------------------------------------------------------------
-- Hosts, ports, and tickets

-- | A completion cell: empty until settled, then settled for good.
type Cell = TVar (Maybe Settlement)

-- | What a cell is settled with: the prepared disposition, and, beside it and
-- never inside it, the capabilities a successful creation hands over.
data Settlement = Settlement !(Prepared Disposition) !(Maybe WindowClient)

-- | The capabilities a client holds for one window: its identity, its own
-- command port, its read-only observations, and its input feed's reader and
-- admission control. Its representation is private: it carries no native
-- handle, no input producer, and no release, retirement, or creation authority,
-- and nothing in it reaches another window.
data WindowClient = WindowClient
  { clientIdentity ∷ !WindowId
  , clientPort ∷ !WindowCommandPort
  , clientReader ∷ !(SnapshotReader WindowObservation)
  , clientInput ∷ !InputReader
  , clientAdmission ∷ !InputControl
  , clientDemand ∷ !DemandPublisher
  }

instance Show WindowClient where
  showsPrec precedence client =
    showParen (precedence > 10) $
      showString "WindowClient " . showsPrec 11 (clientIdentity client)

-- | The window the capabilities are for.
clientWindow ∷ WindowClient → WindowId
clientWindow = clientIdentity

-- | The window's own command port. The executor serves only commands addressed
-- to this window through it, and no creation.
clientCommandPort ∷ WindowClient → WindowCommandPort
clientCommandPort = clientPort

-- | The window's read-only observations. They stay readable after the window
-- ends, holding its terminal observation.
clientObservations ∷ WindowClient → SnapshotReader WindowObservation
clientObservations = clientReader

-- | The reader of the window's input feed: its one logical consumer's
-- capability. Copies share one acknowledgement.
clientInputReader ∷ WindowClient → InputReader
clientInputReader = clientInput

-- | The window's input admission control.
clientInputControl ∷ WindowClient → InputControl
clientInputControl = clientAdmission

-- | The window's demand publisher: the capability a worker uses to ask the
-- owner for a turn for this window. It is rejected once the window's slot has
-- closed, and it can never resurrect the window.
clientDemandPublisher ∷ WindowClient → DemandPublisher
clientDemandPublisher = clientDemand

-- | Build the capabilities for a window from its own command host and input
-- feed.
newWindowClient
  ∷ WindowId
  → WindowCommandHost
  → SnapshotReader WindowObservation
  → InputReader
  → InputControl
  → DemandPublisher
  → WindowClient
newWindowClient identity host = WindowClient identity (hostPort host)

-- | Which commands a host's executor serves.
data PortScope
  = HostScope
    -- ^ Every command.
  | WindowScope !WindowId
    -- ^ Only commands addressed to this window, and no creation.
  deriving (Eq, Show)

-- | The owner's side of a window command service. Its representation is
-- private.
data WindowCommandHost = WindowCommandHost
  { hostSession ∷ !Session
  , hostChannel ∷ !(ChannelControl Submission)
  , hostPort ∷ !WindowCommandPort
  , hostActive ∷ !(TVar Natural)
  , hostNotExecuted ∷ !(Prepared Disposition)
  , hostScope ∷ !PortScope
  }

-- | The client's side of a window command service: it can only submit. Its
-- representation is private, and it carries no native handle and no execution,
-- settlement, or closure authority.
data WindowCommandPort = WindowCommandPort
  { portIdentity ∷ !Unique
  , portOwner ∷ !ThreadId
  , portSender ∷ !(Sender Submission)
  , portPending ∷ !(TVar (Map Natural Cell))
  , portClosed ∷ !(TVar Bool)
  , portNext ∷ !(IORef Natural)
  , portNotifier ∷ !Notifier
    -- ^ How an admission that committed reaches the owner.
  }

-- | A persistent, non-consuming view of one admitted command's completion. Its
-- representation is private.
data CompletionTicket = CompletionTicket
  { ticketRequestOrigin ∷ !CommandOrigin
  , ticketOwner ∷ !ThreadId
  , ticketCell ∷ !Cell
  }

instance Eq CompletionTicket where
  left == right = ticketCell left == ticketCell right

instance Show CompletionTicket where
  showsPrec precedence ticket =
    showParen (precedence > 10) $
      showString "CompletionTicket " . showsPrec 11 (originRequestId (ticketRequestOrigin ticket))

-- | Create an open, empty command host for the session, on its owner thread.
--
-- The owner and liveness are checked first. A capacity below one or above the
-- channel maximum is refused as 'Hetoimasia.Foundation.Messaging.Channel.newChannel'
-- refuses it, attributed to the caller.
newWindowCommandHost ∷ HasCallStack ⇒ Session → Integer → IO WindowCommandHost
newWindowCommandHost session capacity = newScopedHost session capacity HostScope

-- | Create an open, empty command host serving only one window, on the
-- session's owner thread, with the checks of 'newWindowCommandHost'.
newWindowPortHost ∷ HasCallStack ⇒ Session → Integer → WindowId → IO WindowCommandHost
newWindowPortHost session capacity = newScopedHost session capacity . WindowScope

newScopedHost ∷ HasCallStack ⇒ Session → Integer → PortScope → IO WindowCommandHost
newScopedHost session capacity scope =
  ownerOperation session newHostOperation [("capacity", Text.pack (show capacity))] $ do
    control ← newChannel capacity
    identity ← newUnique
    pending ← newTVarIO Map.empty
    closed ← newTVarIO False
    next ← newIORef 1
    active ← newTVarIO 0
    notExecuted ← prepare NotExecuted
    let port =
          WindowCommandPort
            identity
            (sessionOwner session)
            (channelSender control)
            pending
            closed
            next
            (sessionNotifier session)
    pure (WindowCommandHost session control port active notExecuted scope)

-- | The rejection a command outside the host's scope settles with, if it is.
outOfScope ∷ WindowCommandHost → WindowCommand → Maybe CommandRejection
outOfScope host command = case (hostScope host, command) of
  (HostScope, _) → Nothing
  (WindowScope _, CreateWindow _) → Just CreationNotPermitted
  (WindowScope served, _) → case commandWindow command of
    Just target | target /= served → Just (WindowNotServed target)
    _ → Nothing

-- | The host's client port.
windowCommandPort ∷ WindowCommandHost → WindowCommandPort
windowCommandPort = hostPort

-- | The session a host serves, for the private executor.
commandHostSession ∷ WindowCommandHost → Session
commandHostSession = hostSession

-- | The notifier the host's admissions reach the owner through, for the host
-- that lends demand publishers over the same session.
commandHostNotifier ∷ WindowCommandHost → Notifier
commandHostNotifier = portNotifier . hostPort

-- | Whether the host's admission has ended, read in the calling transaction.
-- Never retries.
commandsAdmissionClosed ∷ WindowCommandHost → STM Bool
commandsAdmissionClosed = readTVar . portClosed . hostPort

-- | One coherent observation of a host's bookkeeping.
data CommandStatistics = CommandStatistics
  { commandsCapacity ∷ !Natural
  , commandsQueued ∷ !Natural
    -- ^ Admitted and not yet claimed or settled by closure.
  , commandsActive ∷ !Natural
    -- ^ Claimed and not yet settled.
  , commandsPending ∷ !Natural
    -- ^ Completion cells held: always queued plus active.
  }
  deriving (Eq, Show)

-- | Read the host's bookkeeping in one transaction.
commandStatistics ∷ WindowCommandHost → STM CommandStatistics
commandStatistics host = do
  channel ← channelStatistics (hostChannel host)
  active ← readTVar (hostActive host)
  pending ← readTVar (portPending (hostPort host))
  pure
    CommandStatistics
      { commandsCapacity = statisticsCapacity channel
      , commandsQueued = statisticsDepth channel
      , commandsActive = active
      , commandsPending = fromIntegral (Map.size pending)
      }

-- | End admission and settle every queued command as 'NotExecuted', returning
-- how many this call settled. Idempotent, finite, and never waits; a command
-- already claimed is left to settle through its execution.
closeWindowCommands ∷ WindowCommandHost → STM Natural
closeWindowCommands host = do
  writeTVar (portClosed port) True
  closeChannel (hostChannel host)
  drain 0
  where
    port = hostPort host
    drain settled =
      receive (channelReceiver (hostChannel host)) >>= \case
        Received entry → do
          let Submission origin _ = preparedValue entry
          cell ← pendingCell port origin
          _ ← settleCell port origin cell (Settlement (hostNotExecuted host) Nothing)
          drain (settled + 1)
        -- A closed channel never answers 'Empty'; either way nothing is queued.
        Empty → pure settled
        Terminated _ → pure settled

-- ---------------------------------------------------------------------------
-- Submission

-- | What an immediate submission did.
data SubmitResult
  = SubmitAccepted !CompletionTicket
    -- ^ Admitted; the ticket reports its completion.
  | SubmitFull
    -- ^ The host holds capacity queued commands. Nothing was admitted.
  | SubmitClosed
    -- ^ Admission has ended. Nothing was admitted.
  deriving (Eq, Show)

-- | What a waiting submission did.
data WaitedSubmission
  = WaitAccepted !CompletionTicket
  | WaitClosed
    -- ^ Admission ended before capacity was available. Nothing was admitted.
  deriving (Eq, Show)

-- | Where the private admission examples interrupt a submission.
data AdmissionHooks = AdmissionHooks
  { beforeAdmission ∷ IO ()
    -- ^ After preparation, before the admission transaction.
  , duringAdmission ∷ STM ()
    -- ^ Inside the admission transaction, after the message and its cell were
    -- added.
  , afterAdmission ∷ IO ()
    -- ^ After the admission committed, before the ticket is returned.
  }

noAdmissionHooks ∷ AdmissionHooks
noAdmissionHooks = AdmissionHooks (pure ()) (pure ()) (pure ())

-- | Submit a command without waiting, with the caller's diagnostic context.
--
-- The origin and the message are prepared on the calling thread first; a
-- failure raised while preparing them propagates and admits nothing.
submitWindowCommand ∷ HasCallStack ⇒ WindowCommandPort → [(Text, Text)] → WindowCommand → IO SubmitResult
submitWindowCommand = submitWith noAdmissionHooks

-- | 'submitWindowCommand', interrupted where the hooks say.
submitWith ∷ HasCallStack ⇒ AdmissionHooks → WindowCommandPort → [(Text, Text)] → WindowCommand → IO SubmitResult
submitWith hooks port context command = do
  (origin, prepared) ← prepareSubmission port callStack context command
  beforeAdmission hooks
  -- The admission never retries, so under this mask nothing can be delivered
  -- between its commit and the notification it owes.
  mask_ $ do
    submitted ← atomically $
      send (portSender port) prepared >>= \case
        Accepted → do
          ticket ← reserve port origin
          -- The obligation is registered here, in the admitting transaction, so
          -- a rolled-back admission registers none and a committed one is
          -- visible to every boundary at once.
          registerNotification (portNotifier port)
          duringAdmission hooks
          pure (SubmitAccepted ticket)
        Full → pure SubmitFull
        Closed → pure SubmitClosed
    case submitted of
      SubmitAccepted _ → notifyAdmission hooks port
      _ → pure ()
    pure submitted

-- | Submit a command, waiting for capacity while admission is open.
--
-- The wait is cancellable, and a cancellation delivered before admission
-- commits admits nothing. On the owner thread a full host fails with
-- 'OwnerThreadWouldWait' instead of waiting.
awaitSubmitWindowCommand ∷ HasCallStack ⇒ WindowCommandPort → [(Text, Text)] → WindowCommand → IO WaitedSubmission
awaitSubmitWindowCommand = awaitSubmitWith noAdmissionHooks

-- | 'awaitSubmitWindowCommand', interrupted where the hooks say.
awaitSubmitWith ∷ HasCallStack ⇒ AdmissionHooks → WindowCommandPort → [(Text, Text)] → WindowCommand → IO WaitedSubmission
awaitSubmitWith hooks port context command = do
  (origin, prepared) ← prepareSubmission port callStack context command
  beforeAdmission hooks
  caller ← myThreadId
  if caller == portOwner port
    then mask_ $ do
      submitted ← atomically $
        send (portSender port) prepared >>= \case
          Accepted → do
            ticket ← reserve port origin
            registerNotification (portNotifier port)
            duringAdmission hooks
            pure (Just (WaitAccepted ticket))
          Full → pure Nothing
          Closed → pure (Just WaitClosed)
      case submitted of
        Just (WaitAccepted _) → notifyAdmission hooks port
        _ → pure ()
      maybe (throwFailure glfwComponent submitOperation (originIdentifiers origin) OwnerThreadWouldWait) pure submitted
    else mask_ $ do
      -- The mask is never restored around this transaction, and it does not
      -- have to be: a transaction blocked in 'retry' is an interruptible
      -- operation, so a cancellation is still delivered to a waiter that is
      -- waiting for capacity, and it aborts that transaction without admitting
      -- anything. Once the transaction has committed there is no interruptible
      -- point before the notification, so no admission can lose the wake it
      -- owes.
      submitted ← atomically $
        awaitSend (portSender port) prepared >>= \case
          Admitted → do
            ticket ← reserve port origin
            registerNotification (portNotifier port)
            duringAdmission hooks
            pure (WaitAccepted ticket)
          AdmissionClosed → pure WaitClosed
      case submitted of
        WaitAccepted _ → notifyAdmission hooks port
        WaitClosed → pure ()
      pure submitted

-- | Discharge the obligation the admitting transaction registered,
-- uninterruptibly, so nothing delivered to the submitting thread can drop it.
-- The wake's outcome never changes the submission's answer; a programming or
-- lifetime violation it raises propagates with the command still admitted and
-- the obligation already discharged.
notifyAdmission ∷ AdmissionHooks → WindowCommandPort → IO ()
notifyAdmission hooks port =
  uninterruptibleMask_ (afterAdmission hooks >> void (dischargeNotification (portNotifier port)))

-- | Issue a request identity and prepare the origin and the message.
prepareSubmission
  ∷ WindowCommandPort → CallStack → [(Text, Text)] → WindowCommand → IO (CommandOrigin, Prepared Submission)
prepareSubmission port stack context command = do
  local ← atomicModifyIORef' (portNext port) (\next → (next + 1, next))
  let origin =
        CommandOrigin
          { originRequestId = RequestId (portIdentity port) local
          , originTarget = commandWindow command
          , originSubmissionSite = submissionSite stack
          , originCallerContext = context
          }
  prepared ← prepare (Submission origin command)
  let Submission forced _ = preparedValue prepared
  pure (forced, prepared)

-- | Reserve an admitted request's cell, inside its admission transaction.
reserve ∷ WindowCommandPort → CommandOrigin → STM CompletionTicket
reserve port origin = do
  cell ← newTVar Nothing
  modifyTVar' (portPending port) (Map.insert (originKey origin) cell)
  pure (CompletionTicket origin (portOwner port) cell)

originKey ∷ CommandOrigin → Natural
originKey = requestLocalIdentity . originRequestId

-- | The cell admission reserved for a request received from the channel.
pendingCell ∷ WindowCommandPort → CommandOrigin → STM Cell
pendingCell port origin =
  Map.lookup (originKey origin) <$> readTVar (portPending port) >>= \case
    Just cell → pure cell
    -- Unreachable: a cell is added in the transaction that admits its message,
    -- and removed only in a transaction that has already received it.
    Nothing → error "a received window command has no completion cell"

-- | Settle a cell unless it is already settled, and remove it from the
-- bookkeeping. Answers the disposition the cell holds.
settleCell ∷ WindowCommandPort → CommandOrigin → Cell → Settlement → STM Disposition
settleCell port origin cell settlement = do
  Settlement settled _ ←
    readTVar cell >>= \case
      Just existing → pure existing
      Nothing → settlement <$ writeTVar cell (Just settlement)
  modifyTVar' (portPending port) (Map.delete (originKey origin))
  pure (preparedValue settled)

-- ---------------------------------------------------------------------------
-- Tickets

-- | Where the ticket's request came from.
ticketOrigin ∷ CompletionTicket → CommandOrigin
ticketOrigin = ticketRequestOrigin

-- | The disposition, if the command has settled. Never waits.
pollCompletion ∷ CompletionTicket → STM (Maybe Disposition)
pollCompletion ticket = fmap (\(Settlement disposition _) → preparedValue disposition) <$> readTVar (ticketCell ticket)

-- | The capabilities a settled creation handed over: 'Just' only once the
-- command has settled as 'Performed' 'WindowCreated'. Never waits, and may be
-- read as often as desired.
pollWindowClient ∷ CompletionTicket → STM (Maybe WindowClient)
pollWindowClient ticket = (>>= \(Settlement _ client) → client) <$> readTVar (ticketCell ticket)

-- | Wait for the command to settle and return its disposition. It may be
-- repeated, and cancelling it affects nothing but the wait.
--
-- On the owner thread an unsettled ticket fails with 'OwnerThreadWouldWait'
-- instead of waiting; a settled one returns at once.
awaitCompletion ∷ HasCallStack ⇒ CompletionTicket → IO Disposition
awaitCompletion ticket = do
  caller ← myThreadId
  if caller == ticketOwner ticket
    then
      atomically (pollCompletion ticket)
        >>= maybe
          ( throwFailure
              glfwComponent
              awaitCompletionOperation
              (originIdentifiers (ticketRequestOrigin ticket))
              OwnerThreadWouldWait
          )
          pure
    else atomically (pollCompletion ticket >>= maybe retry pure)

-- ---------------------------------------------------------------------------
-- Execution

-- | What one executor step did.
data ExecutionStep
  = Executed !CommandOrigin !Disposition
    -- ^ It claimed the oldest queued command, which settled so.
  | NothingQueued
  | CommandsEnded
    -- ^ Admission has ended and nothing is queued.
  deriving (Eq, Show)

-- | What an execution produced: completion data, or a created window's
-- capabilities, from which the executor prepares 'WindowCreated' itself.
data Execution
  = Completed !(Either CommandRejection CommandResult)
  | Settled !Disposition
  | Created !WindowClient

-- | Claim the oldest queued command, execute it with @work@, prepare its
-- completion data, and settle it, on the owner thread.
--
-- The claim and the protection of its whole lifetime begin together, so no
-- interruption can separate them. @afterClaim@ runs first inside that
-- protection; production passes @pure ()@. A command outside the host's
-- 'PortScope' is settled as rejected without calling @work@. Anything raised
-- afterwards settles the command as 'Interrupted', with no capabilities, and is
-- rethrown with its context, gaining the execute operation's context if it is
-- synchronous. A created window's capabilities are written beside its prepared
-- disposition in the settling transaction.
executeNextWith
  ∷ IO ()
  → WindowCommandHost
  → (CommandOrigin → WindowCommand → IO Execution)
  → IO ExecutionStep
executeNextWith afterClaim host work =
  ownerOperation (hostSession host) executeOperation [] $ mask $ \restore →
    atomically claim >>= \case
      Nothing → atomically (readTVar (portClosed port)) >>= \closed →
        pure (if closed then CommandsEnded else NothingQueued)
      Just (origin, command, cell) → do
        outcome ∷ Either (ExceptionWithContext SomeException) Settlement ←
          tryWithContext . restore $
            withOperationContext glfwComponent executeOperation (originIdentifiers origin) $ do
              afterClaim
              execution ← maybe (work origin command) (pure . Completed . Left) (outOfScope host command)
              case execution of
                Completed result → (`Settlement` Nothing) <$> prepare (either Rejected Performed result)
                Settled disposition → (`Settlement` Nothing) <$> prepare disposition
                Created client → (`Settlement` Just client) <$> prepare (Performed (WindowCreated (clientIdentity client)))
        case outcome of
          Right settlement → Executed origin <$> atomically (finish origin cell settlement)
          Left caught → do
            interrupted ← prepare (Interrupted (originRequestId origin))
            _ ← atomically (finish origin cell (Settlement interrupted Nothing))
            rethrowIO caught
  where
    port = hostPort host
    claim =
      receive (channelReceiver (hostChannel host)) >>= \case
        Received entry → do
          let Submission origin command = preparedValue entry
          cell ← pendingCell port origin
          modifyTVar' (hostActive host) (+ 1)
          pure (Just (origin, command, cell))
        Empty → pure Nothing
        Terminated _ → pure Nothing
    finish origin cell prepared = do
      modifyTVar' (hostActive host) (subtract 1)
      settleCell port origin cell prepared

-- | Execute a command against the lexically scoped windows an executor serves.
-- They cannot be closed early or added to.
executeCommand ∷ [Window] → CommandOrigin → WindowCommand → IO Execution
executeCommand windows _ = fmap Settled . runCommand windows

runCommand ∷ [Window] → WindowCommand → IO Disposition
runCommand windows = \case
  ObserveWindow target → maybe (notServed target) (fmap (either Rejected Performed) . observeWindow target) (served target)
  CloseWindow target → pure (Rejected (maybe (WindowNotServed target) (const (CloseNotPermitted target)) (served target)))
  CreateWindow _ → pure (Rejected CreationNotPermitted)
  ControlWindow target control → maybe (notServed target) (controlDisposition target control) (served target)
  ModeWindow target request → maybe (notServed target) (modeDisposition target request) (served target)
  where
    served target = find ((== target) . windowIdentity) windows
    notServed = pure . Rejected . WindowNotServed

-- | Execute a control on one window at an owner boundary and settle it: an
-- ended window as 'WindowAlreadyEnded', a closing one as 'WindowIsClosing', and
-- otherwise as rejected, unsupported, or attempted. A callback fault rethrown at
-- the boundary, and anything else raised, propagates.
controlDisposition ∷ WindowId → WindowControl → Window → IO Disposition
controlDisposition target control window =
  controlWindow window control >>= \case
    WindowEnded _ → pure (Rejected (WindowAlreadyEnded target))
    WindowAvailable ControlWindowClosing → pure (Rejected (WindowIsClosing target))
    WindowAvailable (ControlRefused rejection) → pure (Rejected (ControlRejected target rejection))
    WindowAvailable (ControlUnsupported wanted reason) → pure (Unsupported (UnsupportedControl target wanted reason))
    WindowAvailable (ControlAttempted outcome observation) → pure (Attempted (ControlAttempt target outcome observation))

-- | Execute a mode request on one window at an owner boundary and settle it: an
-- ended window as 'WindowAlreadyEnded', a closing one as 'WindowIsClosing', a
-- request refused before any native call with no fallback as 'ModeRejected', a
-- target the platform cannot perform with no fallback as 'Unsupported', and
-- otherwise as 'Transitioned'. Anything raised propagates.
modeDisposition ∷ WindowId → ModeRequest → Window → IO Disposition
modeDisposition target request window =
  transitionWindow window request >>= \case
    WindowEnded _ → pure (Rejected (WindowAlreadyEnded target))
    WindowAvailable ModeWindowClosing → pure (Rejected (WindowIsClosing target))
    WindowAvailable (ModeRefused rejection) → pure (Rejected (ModeRejected target rejection))
    WindowAvailable (ModeUnsupported reason) → pure (Unsupported (UnsupportedControl target wanted reason))
    WindowAvailable (ModeSettled outcome observation) → pure (Transitioned (ModeTransition target outcome observation))
  where
    wanted = case modePresentation (requestedMode request) of
      FullscreenPresentation → FullscreenOperation
      _ → BorderlessOperation

-- | Synchronize one window at an owner boundary and answer the revision that
-- followed. A native failure raised by the sampling is a typed rejection; a
-- callback fault rethrown at the boundary, and anything else, propagates.
observeWindow ∷ WindowId → Window → IO (Either CommandRejection CommandResult)
observeWindow target window =
  tryWithContext (synchronizeWindow window) >>= \case
    Right (WindowAvailable observation) →
      pure (Right (ObservationPublished target (observedRevision observation)))
    Right (WindowEnded _) → pure (Left (WindowAlreadyEnded target))
    Left caught → case nativeRejectionOf caught of
      Just (failed, outcome, reports) →
        pure
          ( Left
              WindowNativeFailure
                { failedWindow = target
                , failedOperation = failed
                , failedOutcome = outcome
                , failedReports = reports
                }
          )
      Nothing → rethrowIO caught

-- | The copied data of a native failure raised by a native call, or 'Nothing'
-- for a callback fault rethrown at an owner boundary, which is not that call's
-- native failure whatever its type.
nativeRejectionOf ∷ ExceptionWithContext NativeFailure → Maybe (Maybe Text, NativeOutcome, Reports)
nativeRejectionOf (ExceptionWithContext context failure)
  | any ((== windowCallbackOperation) . contextOperation) (failureContexts evidence) = Nothing
  | otherwise = Just (failedName (failureCause evidence), nativeOutcome failure, nativeReports failure)
  where
    evidence = failureEvidenceInContext context
    failedName (EngineOrigin origin) = Just (operationText (originOperation origin))
    failedName NativeCause = Nothing

-- | Perform a command directly on the owner thread: the checked execution
-- operation for the thread that cannot wait for a ticket.
--
-- The owner and liveness are checked first. After closure it performs nothing
-- and answers 'NotExecuted'. No queue, cell, or ticket is involved, and a
-- Haskell exception propagates unchanged.
performWindowCommand ∷ WindowCommandHost → [Window] → WindowCommand → IO Disposition
performWindowCommand host windows command =
  ownerOperation (hostSession host) performOperation identifiers $ do
    closed ← readTVarIO (portClosed (hostPort host))
    if closed
      then pure NotExecuted
      else do
        result ← maybe (runCommand windows command) (pure . Rejected) (outOfScope host command)
        preparedValue <$> prepare result
  where
    identifiers = maybe [] (\window → [("window", Text.pack (show (windowLocalIdentity window)))]) (commandWindow command)
