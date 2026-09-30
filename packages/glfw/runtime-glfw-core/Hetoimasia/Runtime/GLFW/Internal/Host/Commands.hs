-- | Command execution: fair dispatch across the host's ports, the window
-- creation a command asks for, and the bookkeeping the bounding checks read.
--
-- Every operation here runs on the process main thread, the session's owner,
-- within an owner turn or an owner operation. The ports and their queues are
-- the host's, in "Hetoimasia.Runtime.GLFW.Internal.Host.State"; the dispatch
-- cursor is the one cell this module writes, and only the owner thread does.
-- Clients on any thread submit through the ports themselves, never through
-- this module.
--
-- A hide is the one control that consults a window's graphics attachment
-- first: the attachment's protocol withholds its presentation before the
-- native call ('protocolBeforeHide'), so no owner presents to a window the
-- compositor has unmapped (#357).
module Hetoimasia.Runtime.GLFW.Internal.Host.Commands
  ( dispatchCommands
  , queuedCommands
  , HostBookkeeping (..)
  , hostBookkeeping
  ) where

import Control.Concurrent.STM (STM, atomically, readTVar, readTVarIO)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException, rethrowIO, tryWithContext)
import Control.Monad (forM)
import Data.IORef (readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Failure (Operation, operation)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext)
import Hetoimasia.Foundation.Resource.Collection (CollectionError (..), liveMemberCount)
import Hetoimasia.GLFW.Command
  ( CommandRejection (..)
  , CommandResult (..)
  , CommandStatistics (..)
  , commandStatistics
  )
import Hetoimasia.GLFW.Internal.Command
  ( CommandOrigin
  , Disposition (Attempted)
  , Execution (..)
  , ExecutionStep (..)
  , WindowCommand (..)
  , controlDisposition
  , executeNextWith
  , modeDisposition
  , nativeRejectionOf
  , observeWindow
  )
import Hetoimasia.GLFW.Internal.Control (WindowControl (HideControl))
import Hetoimasia.GLFW.Internal.Session (ownerOperation)
import Hetoimasia.GLFW.Session (SessionMisuse (SessionPoisoned))
import Hetoimasia.GLFW.Window (WindowConfig, WindowId, validateWindowConfig)
import Hetoimasia.Runtime.GLFW.Internal.Host.Config (HostConfig (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.State (HostEntry (..), PortKey (..), WindowHost (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.Windows (CloseStart (..), beginClose, borrowWindow, registerWindow)
import Hetoimasia.Runtime.GLFW.Internal.Retirement (AttachmentProtocol (..), windowAttachmentProtocol)
import Numeric.Natural (Natural)

bookkeepingOperation ∷ Operation
bookkeepingOperation = operation "read host bookkeeping"

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

-- | Commands queued across every port.
queuedCommands ∷ WindowHost → STM Natural
queuedCommands host = do
  queued ← commandsQueued <$> commandStatistics (hostCommands host)
  entries ← readTVar (hostEntries host)
  windows ← forM (Map.elems entries) (fmap commandsQueued . commandStatistics . entryCommands)
  pure (queued + sum windows)

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
        | otherwise → Settled <$> beforeUnmapping host target control (borrowWindow host target entry (controlDisposition target control))
  ModeWindow target request →
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → completed (Left (WindowNotServed target))
      Just entry
        | entryClosing entry → completed (Left (WindowIsClosing target))
        | otherwise → Settled <$> borrowWindow host target entry (modeDisposition target request)
  where
    completed = pure . Completed

-- | Run a control, having the graphics attachment of the window a hide
-- unmaps withhold its presentation first.
--
-- The hold outlives the native call: the owner presents to the window again
-- only once an observation newer than the one it had when the hold began is
-- published, and the hidden window's is. A hide that made no native call — it
-- was refused, or the platform cannot perform it — changed nothing, so its
-- hold is lifted at once. One that raised keeps its hold, since whether the
-- window was unmapped is unknown. Any other control, and a window with no
-- attachment, runs unchanged.
beforeUnmapping ∷ WindowHost → WindowId → WindowControl → IO Disposition → IO Disposition
beforeUnmapping host target control run = case (control, hostRetirementState host) of
  (HideControl, Just retirement) →
    atomically (windowAttachmentProtocol retirement target) >>= \case
      Nothing → run
      Just (attachment, protocol) → do
        lift ← protocolBeforeHide protocol attachment
        disposition ← run
        case disposition of
          Attempted _ → pure ()
          _ → lift
        pure disposition
  _ → run

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
