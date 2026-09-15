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
  , hostComponent

    -- * The owner loop
  , runOwnerLoop
  , LoopHooks (..)
  , noApplicationEvents
  , Turn (..)
  , TurnStep (..)
  , rejectHostCloseRequest

    -- * Applications
  , runWindowApplication
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeException, bracket_, finally, fromException, rethrowIO, tryWithContext)
import Control.Monad (forM, forM_, void)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Channel (maximumCapacity)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (SnapshotReader, observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (Scoped, allocResource)
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
  , executeNextWith
  , nativeRejectionOf
  , newWindowClient
  , newWindowPortHost
  , controlDisposition
  , modeDisposition
  , observeWindow
  )
import Hetoimasia.GLFW.Internal.Control (WindowCapabilities)
import Hetoimasia.GLFW.Internal.Input (InputFeed, closeInputFeed, feedControl, feedReader, newInputFeed)
import Hetoimasia.GLFW.Internal.Session (ownerOperation, reconcileMonitorEvents, sessionWindowCapabilities)
import Hetoimasia.GLFW.Internal.Window
  ( EventProcessing (..)
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
import Hetoimasia.Runtime.Application (runScopedApplicationWithQuiescence)
import Hetoimasia.Runtime.Logging (LoggingLifetime)
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
    -- At least one, and at least as many as 'hostWindowConfigs'.
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
  , hostIdleWait ∷ !Double
    -- ^ The most seconds an idle turn waits for a native event. Finite, above
    -- zero, and at most 'maximumIdleWait'.
  }
  deriving (Eq, Show)

-- | The platform's own session, the given windows, a limit of 16 live windows,
-- a command capacity of 64, an input capacity of 256, budgets of 16, and a
-- 0.1-second idle wait.
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
    , hostIdleWait = 0.1
    }

-- | A host configuration refused before anything was acquired.
data HostConfigRejected
  = CommandBudgetRejected !Int
  | EventBudgetRejected !Int
  | IdleWaitRejected !Double
  | WindowLimitRejected !Int
    -- ^ The limit is below one, or below the number of configured windows.
  | InputCapacityRejected !Integer
  deriving (Eq, Show)

instance Exception HostConfigRejected

-- | The longest idle wait a configuration may ask for, in seconds.
maximumIdleWait ∷ Double
maximumIdleWait = 60

-- | Check the budgets, the idle wait, the window limit, and the input capacity.
-- The session, window, and command capacity settings are checked by the
-- operations they configure.
validateHostConfig ∷ HostConfig → Either HostConfigRejected ()
validateHostConfig config
  | hostCommandBudget config < 1 = Left (CommandBudgetRejected (hostCommandBudget config))
  | hostEventBudget config < 1 = Left (EventBudgetRejected (hostEventBudget config))
  -- Written so a NaN, which fails every comparison, is refused too.
  | not (wait > 0 && wait <= maximumIdleWait) = Left (IdleWaitRejected wait)
  | limit < 1 || limit < length (hostWindowConfigs config) = Left (WindowLimitRejected limit)
  | input < 1 || input > maximumCapacity = Left (InputCapacityRejected input)
  | otherwise = Right ()
  where
    wait = hostIdleWait config
    limit = hostWindowLimit config
    input = hostInputCapacity config

-- | The component a host's own failures are attributed to.
hostComponent ∷ Component
hostComponent = unsafeComponent "glfw.runtime"

constructOperation, loopOperation, rejectOperation, borrowOperation, closeOperation, honourOperation, bookkeepingOperation ∷ Operation
constructOperation = operation "construct window host"
loopOperation = operation "run owner loop"
rejectOperation = operation "reject close request"
borrowOperation = operation "borrow host window"
closeOperation = operation "close host window"
honourOperation = operation "honour close request"
bookkeepingOperation = operation "read host bookkeeping"

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
  , hostActivityState ∷ !(TVar HostActivity)
  , hostHooks ∷ !HostHooks
  }

-- | Where the private examples interrupt a host. Production passes
-- 'noHostHooks'.
data HostHooks = HostHooks
  { afterRegistration ∷ IO ()
    -- ^ Runs at the end of a window's registration, masked and with nothing
    -- interruptible before it: after the collection and the host have both
    -- registered the window, before its creation's result is published.
  }

noHostHooks ∷ HostHooks
noHostHooks = HostHooks (pure ())

-- | One registered window: its collection member, its own command host, its
-- input feed, the capabilities handed to clients, and whether its close protocol
-- has begun.
data HostEntry = HostEntry
  { entryMember ∷ !(Member Window)
  , entryCommands ∷ !WindowCommandHost
  , entryInput ∷ !InputFeed
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
allocWindowHostWith hooks sessionScope config = do
  liftIO (either (throwFailure hostComponent constructOperation []) pure (validateHostConfig config))
  session ← sessionScope
  -- Released after every later part: the collection's exit releases the
  -- windows still registered once admission has closed.
  collection ← allocCollection (hostWindowLimit config)
  commands ← liftIO (newWindowCommandHost session (hostCommandCapacity config))
  entries ← liftIO (newTVarIO Map.empty)
  -- Released first: every port's admission closes before any window is released.
  allocResource (pure ()) (\() → atomically (closeAdmission commands entries))
  host ←
    liftIO $
      WindowHost session collection commands config entries
        <$> newIORef Map.empty
        <*> newIORef Map.empty
        <*> newIORef HostPortKey
        <*> newTVarIO (HostActivity 0 False)
        <*> pure hooks
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
quiesceWindowHost host = closeAdmission (hostCommands host) (hostEntries host)

closeAdmission ∷ WindowCommandHost → TVar (Map WindowId HostEntry) → STM ()
closeAdmission commands entries = do
  void (closeWindowCommands commands)
  readTVar entries >>= mapM_ (\entry → void (closeWindowCommands (entryCommands entry)) >> closeInputFeed (entryInput entry))

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
      void (closeWindowCommands (entryCommands entry))
      closeInputFeed (entryInput entry)
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
  if any (/= target) (Map.keys borrowed)
    then pure ()
    else
      tryWithContext (retireMember (hostCollection host) (entryMember entry)) >>= \case
        Right RetirementInUse → pure ()
        Right _ → forget
        Left (caught ∷ ExceptionWithContext SomeException) →
          memberStatus (entryMember entry) >>= \case
            MemberRetirementFailed _ → forget
            _ → rethrowIO caught
  where
    forget = do
      atomically (modifyTVar' (hostEntries host) (Map.delete target))
      modifyIORef' (hostSurfaced host) (Map.delete target)

-- | Retry the retirement of every closing window, in registration order.
retirePending ∷ WindowHost → IO ()
retirePending host = do
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
    (identity, reader) ←
      withMember (hostCollection host) member (\window → pure (windowIdentity window, windowObservations window))
    focused ← (== Observed True) . observedFocused . preparedValue . observedValue <$> atomically (readSnapshot reader)
    commands ← newWindowPortHost (hostSession host) (hostCommandCapacity (hostSettings host)) identity
    feed ← newInputFeed identity (hostInputCapacity (hostSettings host)) focused
    let client = newWindowClient identity commands reader (feedReader feed) (feedControl feed)
    atomically (modifyTVar' (hostEntries host) (Map.insert identity (HostEntry member commands feed client False)))
    afterRegistration (hostHooks host)
    pure client

-- | Create a window for a creation command. The configuration and the live
-- limit are checked before any native effect, and poisoning is refused before
-- one too; each is a typed rejection. A native failure during construction,
-- after its rollback, is a typed rejection as well. Anything else — a
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
  { loopEvent ∷ IO Bool
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
  ownerOperation (hostSession host) loopOperation [] (turn 1 False)
  where
    settings = hostSettings host
    turn number idle = do
      checkRuntime control
      queued ← atomically (queuedCommands host)
      let waited = idle && queued == 0
      processEvents host number waited
      reconcileMonitorEvents (hostSession host)
      reconcileWindowModes host
      retirePending host
      closes ← surfaceCloseRequests host
      checkRuntime control
      commands ← dispatchCommands host (hostCommandBudget settings)
      checkRuntime control
      events ← dispatchEvents (loopEvent hooks) (hostEventBudget settings)
      checkRuntime control
      step ← loopUpdate hooks (Turn number waited commands events closes)
      checkRuntime control
      case step of
        Finish result → pure result
        Continue → turn (number + 1) (commands == 0 && events == 0)

-- | Commands queued across every port.
queuedCommands ∷ WindowHost → STM Natural
queuedCommands host = do
  queued ← commandsQueued <$> commandStatistics (hostCommands host)
  entries ← readTVar (hostEntries host)
  windows ← forM (Map.elems entries) (fmap commandsQueued . commandStatistics . entryCommands)
  pure (queued + sum windows)

-- | Poll, or wait the configured bound, publishing the activity around it.
processEvents ∷ WindowHost → Natural → Bool → IO ()
processEvents host number waited = do
  atomically (writeTVar (hostActivityState host) (HostActivity number waited))
  processWindowEvents (hostSession host) processing
    `finally` atomically (writeTVar (hostActivityState host) (HostActivity number False))
  where
    processing
      | waited = AwaitEventsFor (hostIdleWait (hostSettings host))
      | otherwise = ProcessPending

-- | Reconcile the mode of every window the host holds that is not closing, in
-- registration order, after the turn's monitor refresh: a window whose applied
-- mode names an ended monitor takes its recorded fallback without another
-- command.
reconcileWindowModes ∷ WindowHost → IO ()
reconcileWindowModes host = do
  entries ← readTVarIO (hostEntries host)
  forM_ (Map.toAscList entries) $ \(target, entry) →
    if entryClosing entry then pure () else void (borrowWindow host target entry reconcileWindowMode)

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
-- Applications

-- | 'Hetoimasia.Runtime.Application.runScopedApplicationWithQuiescence' with
-- the host's quiescence action: the fourth argument finds the host among the
-- application's dependencies.
runWindowApplication
  ∷ HasCallStack
  ⇒ (∀ r. (LoggingLifetime → IO r) → IO r)
  → Text
  → Scoped dependencies
  → (dependencies → WindowHost)
  → (dependencies → RuntimeControl → IO services)
  → (services → RuntimeControl → IO a)
  → IO a
runWindowApplication enterLifetime name dependencies host =
  runScopedApplicationWithQuiescence enterLifetime name dependencies (quiesceWindowHost . host)
