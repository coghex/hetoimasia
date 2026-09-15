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
-- A 'WindowCommand' is an immutable value addressed to one window. Submitting
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
-- = Dispositions
--
-- Every admitted command settles exactly once, to one 'Disposition':
--
-- * 'Performed', with prepared 'CommandResult' data;
-- * 'Rejected', with a typed 'CommandRejection', when nothing was applied — a
--   window the executor does not serve, a window that has ended, or a native
--   failure, carried as copied code and description data;
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
-- The executor protocol, 'executeNextWith', is private to this package. This
-- slice drives it only through the test seam's private executor; the owner's
-- event loop drains it in a later slice.
--
-- The one command is 'observeWindowCommand'. Executing it synchronizes the
-- addressed window at an owner boundary, which samples and publishes through
-- "Hetoimasia.GLFW.Internal.Window"'s observation contract, and answers with
-- the revision of the committed observation that followed: a new revision when
-- sampling changed anything, and otherwise the published one the sample
-- matched. It never samples another window.
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
-- | Completion cell      | Its ticket  | Settled once; tickets read  | Settle: owner; read:   | While a ticket        | Never reset                |
-- |                      |             |                             | any                    | references it         |                            |
-- +----------------------+-------------+-----------------------------+------------------------+-----------------------+----------------------------+
-- | Admission flag       | The host    | Closure sets it; direct     | Owner                  | The host              | Never cleared              |
-- |                      |             | performance reads it        |                        |                       |                            |
-- +----------------------+-------------+-----------------------------+------------------------+-----------------------+----------------------------+
-- | Request counter      | The port    | Submissions issue from it   | Any; atomic            | The host              | Never reissued             |
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
  , WindowCommand
  , observeWindowCommand
  , commandWindow

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

    -- * Misuse
  , WindowCommandMisuse (..)

    -- * Private executor protocol
  , commandHostSession
  , AdmissionHooks (..)
  , noAdmissionHooks
  , submitWith
  , ExecutionStep (..)
  , executeNextWith
  , executeCommand
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVar, newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.DeepSeq (NFData (rnf))
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , mask
  , rethrowIO
  , tryWithContext
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
import Hetoimasia.GLFW.Internal.Capture (NativeError (..), Reports (..))
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
  , WindowId
  , WindowResult (..)
  , observedRevision
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
newtype WindowCommand = ObserveWindow WindowId
  deriving (Eq, Show)

instance NFData WindowCommand where
  rnf (ObserveWindow window) = rnf window

-- | Ask the owner to sample the window and publish a fresh observation of it at
-- its next safe boundary.
observeWindowCommand ∷ WindowId → WindowCommand
observeWindowCommand = ObserveWindow

-- | The window a command is addressed to.
commandWindow ∷ WindowCommand → WindowId
commandWindow (ObserveWindow window) = window

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
  , originTarget ∷ !WindowId
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

-- | The window the request was addressed to.
submittedWindow ∷ CommandOrigin → WindowId
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
  [ ("request", Text.pack (show (requestLocalIdentity (originRequestId origin))))
  , ("window", Text.pack (show (windowLocalIdentity (originTarget origin))))
  ]
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
  | NotExecuted
    -- ^ Closure settled it while it was still queued.
  | Interrupted !RequestId
    -- ^ Its execution raised; effects may have been applied, and nothing was
    -- replayed.
  deriving (Eq, Show)

instance NFData Disposition where
  rnf (Performed result) = rnf result
  rnf (Rejected rejection) = rnf rejection
  rnf NotExecuted = ()
  rnf (Interrupted request) = rnf request

-- | What a performed command produced.
data CommandResult = ObservationPublished
  { publishedWindow ∷ !WindowId
  , publishedRevision ∷ !Natural
    -- ^ The revision of the committed observation that followed the sample.
  }
  deriving (Eq, Show)

instance NFData CommandResult where
  rnf (ObservationPublished window revision) = rnf window `seq` rnf revision

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
  deriving (Eq, Show)

instance NFData CommandRejection where
  rnf (WindowNotServed window) = rnf window
  rnf (WindowAlreadyEnded window) = rnf window
  rnf (WindowNativeFailure window failed outcome reports) =
    rnf window `seq` rnf failed `seq` outcome `seq` rnfReports reports

rnfReports ∷ Reports → ()
rnfReports reports =
  foldr (seq . rnfError) () (reportedErrors reports)
    `seq` rnf (reportsLost reports)
    `seq` rnf (callbackFaults reports)
  where
    rnfError reported =
      rnf (nativeErrorCode reported)
        `seq` rnf (nativeErrorDescription reported)
        `seq` nativeErrorTruncated reported
        `seq` nativeErrorThread reported
        `seq` ()

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
type Cell = TVar (Maybe (Prepared Disposition))

-- | The owner's side of a window command service. Its representation is
-- private.
data WindowCommandHost = WindowCommandHost
  { hostSession ∷ !Session
  , hostChannel ∷ !(ChannelControl Submission)
  , hostPort ∷ !WindowCommandPort
  , hostActive ∷ !(TVar Natural)
  , hostNotExecuted ∷ !(Prepared Disposition)
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
newWindowCommandHost session capacity =
  ownerOperation session newHostOperation [("capacity", Text.pack (show capacity))] $ do
    control ← newChannel capacity
    identity ← newUnique
    pending ← newTVarIO Map.empty
    closed ← newTVarIO False
    next ← newIORef 1
    active ← newTVarIO 0
    notExecuted ← prepare NotExecuted
    let port = WindowCommandPort identity (sessionOwner session) (channelSender control) pending closed next
    pure (WindowCommandHost session control port active notExecuted)

-- | The host's client port.
windowCommandPort ∷ WindowCommandHost → WindowCommandPort
windowCommandPort = hostPort

-- | The session a host serves, for the private executor.
commandHostSession ∷ WindowCommandHost → Session
commandHostSession = hostSession

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
          _ ← settleCell port origin cell (hostNotExecuted host)
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
  submitted ← atomically $
    send (portSender port) prepared >>= \case
      Accepted → do
        ticket ← reserve port origin
        duringAdmission hooks
        pure (SubmitAccepted ticket)
      Full → pure SubmitFull
      Closed → pure SubmitClosed
  case submitted of
    SubmitAccepted _ → afterAdmission hooks
    _ → pure ()
  pure submitted

-- | Submit a command, waiting for capacity while admission is open.
--
-- The wait is cancellable, and a cancellation delivered before admission
-- commits admits nothing. On the owner thread a full host fails with
-- 'OwnerThreadWouldWait' instead of waiting.
awaitSubmitWindowCommand ∷ HasCallStack ⇒ WindowCommandPort → [(Text, Text)] → WindowCommand → IO WaitedSubmission
awaitSubmitWindowCommand port context command = do
  (origin, prepared) ← prepareSubmission port callStack context command
  caller ← myThreadId
  if caller == portOwner port
    then do
      submitted ← atomically $
        send (portSender port) prepared >>= \case
          Accepted → Just . WaitAccepted <$> reserve port origin
          Full → pure Nothing
          Closed → pure (Just WaitClosed)
      maybe (throwFailure glfwComponent submitOperation (originIdentifiers origin) OwnerThreadWouldWait) pure submitted
    else atomically $
      awaitSend (portSender port) prepared >>= \case
        Admitted → WaitAccepted <$> reserve port origin
        AdmissionClosed → pure WaitClosed

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
settleCell ∷ WindowCommandPort → CommandOrigin → Cell → Prepared Disposition → STM Disposition
settleCell port origin cell disposition = do
  settled ←
    readTVar cell >>= \case
      Just existing → pure existing
      Nothing → disposition <$ writeTVar cell (Just disposition)
  modifyTVar' (portPending port) (Map.delete (originKey origin))
  pure (preparedValue settled)

-- ---------------------------------------------------------------------------
-- Tickets

-- | Where the ticket's request came from.
ticketOrigin ∷ CompletionTicket → CommandOrigin
ticketOrigin = ticketRequestOrigin

-- | The disposition, if the command has settled. Never waits.
pollCompletion ∷ CompletionTicket → STM (Maybe Disposition)
pollCompletion ticket = fmap preparedValue <$> readTVar (ticketCell ticket)

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

-- | Claim the oldest queued command, execute it with @work@, prepare its
-- completion data, and settle it, on the owner thread.
--
-- The claim and the protection of its whole lifetime begin together, so no
-- interruption can separate them. @afterClaim@ runs first inside that
-- protection; production passes @pure ()@. Anything raised afterwards settles
-- the command as 'Interrupted' and is rethrown with its context, gaining the
-- execute operation's context if it is synchronous.
executeNextWith
  ∷ IO ()
  → WindowCommandHost
  → (CommandOrigin → WindowCommand → IO (Either CommandRejection CommandResult))
  → IO ExecutionStep
executeNextWith afterClaim host work =
  ownerOperation (hostSession host) executeOperation [] $ mask $ \restore →
    atomically claim >>= \case
      Nothing → atomically (readTVar (portClosed port)) >>= \closed →
        pure (if closed then CommandsEnded else NothingQueued)
      Just (origin, command, cell) → do
        outcome ∷ Either (ExceptionWithContext SomeException) (Prepared Disposition) ←
          tryWithContext . restore $
            withOperationContext glfwComponent executeOperation (originIdentifiers origin) $ do
              afterClaim
              result ← work origin command
              prepare (either Rejected Performed result)
        case outcome of
          Right prepared → Executed origin <$> atomically (finish origin cell prepared)
          Left caught → do
            interrupted ← prepare (Interrupted (originRequestId origin))
            _ ← atomically (finish origin cell interrupted)
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

-- | Execute a command against the windows an executor serves.
executeCommand ∷ [Window] → CommandOrigin → WindowCommand → IO (Either CommandRejection CommandResult)
executeCommand windows _ = runCommand windows

runCommand ∷ [Window] → WindowCommand → IO (Either CommandRejection CommandResult)
runCommand windows (ObserveWindow target) =
  case find ((== target) . windowIdentity) windows of
    Nothing → pure (Left (WindowNotServed target))
    Just window →
      tryWithContext (synchronizeWindow window) >>= \case
        Right (WindowAvailable observation) →
          pure (Right (ObservationPublished target (observedRevision observation)))
        Right (WindowEnded _) → pure (Left (WindowAlreadyEnded target))
        Left caught@(ExceptionWithContext context failure)
          -- A callback fault rethrown at the boundary is not the sampling's
          -- native failure, whatever its type.
          | raisedByCallback evidence → rethrowIO caught
          | otherwise →
              pure
                ( Left
                    WindowNativeFailure
                      { failedWindow = target
                      , failedOperation = failedName (failureCause evidence)
                      , failedOutcome = nativeOutcome failure
                      , failedReports = nativeReports failure
                      }
                )
          where
            evidence = failureEvidenceInContext context
  where
    raisedByCallback evidence =
      any ((== windowCallbackOperation) . contextOperation) (failureContexts evidence)
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
  ownerOperation (hostSession host) performOperation [("window", Text.pack (show (windowLocalIdentity (commandWindow command))))] $ do
    closed ← readTVarIO (portClosed (hostPort host))
    if closed
      then pure NotExecuted
      else do
        result ← runCommand windows command
        preparedValue <$> prepare (either Rejected Performed result)
