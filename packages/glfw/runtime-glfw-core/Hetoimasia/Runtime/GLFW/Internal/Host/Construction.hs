-- | Building a window host, closing its admission, and the readers any thread
-- may use.
--
-- A host is built as a 'Scoped' value on the process main thread, which then
-- owns it: the session, the collection, the ports, and every cell of the
-- handle in "Hetoimasia.Runtime.GLFW.Internal.Host.State" are acquired here,
-- and the releases installed here are the host's whole teardown, run on that
-- same thread when its scope ends. 'quiesceWindowHost' is the one step of that
-- teardown any thread may commit early.
module Hetoimasia.Runtime.GLFW.Internal.Host.Construction
  ( -- * Construction
    allocWindowHost
  , allocWindowHostIn
  , allocWindowHostWith
  , allocHostOver

    -- * Quiescence
  , quiesceWindowHost

    -- * Readers
  , hostMonitors
  , hostCommandPort
  , hostCommandStatistics
  , hostWindowCapabilities
  , hostActivity
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, readTVarIO)
import Control.Monad (forM, forM_, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (newIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Messaging.Snapshot (SnapshotReader)
import Hetoimasia.Foundation.Resource (Scoped, allocResource)
import Hetoimasia.Foundation.Resource.Collection (MemberStatus (..), allocCollection, memberStatus)
import Hetoimasia.GLFW.Command
  ( CommandStatistics
  , WindowCommandHost
  , WindowCommandPort
  , closeWindowCommands
  , commandStatistics
  , newWindowCommandHost
  , windowCommandPort
  )
import Hetoimasia.GLFW.Internal.Control (WindowCapabilities)
import Hetoimasia.GLFW.Internal.Demand (DemandSlot, closeDemandSlot, newDemandSlot)
import Hetoimasia.GLFW.Internal.Session (sessionIdentity, sessionWindowCapabilities)
import Hetoimasia.GLFW.Monitor (MonitorInventory, monitorInventory)
import Hetoimasia.GLFW.Session (Session, allocSession)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW.Internal.Graphics
  ( GraphicsCell
  , GraphicsObservation (..)
  , NativeDisposal (..)
  , readGraphicsCell
  , writeGraphicsDisposal
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Config (HostConfig (..), hostComponent, validateHostConfig)
import Hetoimasia.Runtime.GLFW.Internal.Host.Progress (demandRetirementNow, refreshCells)
import Hetoimasia.Runtime.GLFW.Internal.Host.State
  ( HostActivity (..)
  , HostEntry (..)
  , HostHooks
  , HostProtection (..)
  , PortKey (..)
  , RetirementDemand
  , WindowHost (..)
  , noHostHooks
  , noRetirementDemand
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Windows (closeEntryAdmission, registerWindow)
import Hetoimasia.Runtime.GLFW.Internal.Retirement (HostRetirement, closeAttachmentAdmission, newHostRetirement)

constructOperation ∷ Operation
constructOperation = operation "construct window host"

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
