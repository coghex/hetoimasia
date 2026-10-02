-- | The window host's one handle, and the records its cells hold.
--
-- This module defines representation and documents ownership; it performs no
-- work. The handle is built once, by
-- "Hetoimasia.Runtime.GLFW.Internal.Host.Construction", and every other host
-- module reads or writes these same cells rather than a copy of them.
--
-- The host is owned by the process main thread: the session's owner thread,
-- which constructs it, runs its owner loops, and releases it. That thread is
-- the only writer of every cell, with three exceptions that commit in STM and
-- may come from any thread: the host's quiescence transaction, which closes the
-- admission recorded in the registry and the demand slots, and whatever an
-- interposed lifetime closes beside them; a worker's demand
-- publication; and a completion notice's publication. The 'IORef' cells —
-- borrows, surfaced close requests, and the two rotation cursors — are read
-- and written by the owner thread alone. Any thread may read the 'TVar' cells.
--
-- Every cell lives exactly as long as the host's scope. The registry and the
-- graphics cells shrink as windows retire, so nothing the host holds grows with
-- how many windows were ever created.
module Hetoimasia.Runtime.GLFW.Internal.Host.State
  ( -- * The host handle
    WindowHost (..)
  , HostProtection (..)
  , hostConfiguration
  , hostSessionOf
  , hostRetirementOf

    -- * Where the private examples interrupt a host
  , HostHooks (..)
  , noHostHooks

    -- * The registry
  , HostEntry (..)
  , PortKey (..)
  , windowIdentifiers

    -- * What clients may observe
  , HostActivity (..)
  , RetirementDemand (..)
  , noRetirementDemand
  ) where

import Control.Concurrent.STM (STM, TVar)
import Data.IORef (IORef)
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource.Collection (Collection, Member)
import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GLFW.Command (WindowClient, WindowCommandHost)
import Hetoimasia.GLFW.Internal.Attachment (AttachmentId)
import Hetoimasia.GLFW.Internal.Demand (DemandSlot)
import Hetoimasia.GLFW.Internal.Input (InputFeed)
import Hetoimasia.GLFW.Session (Session)
import Hetoimasia.GLFW.Window (CloseRequest, Window, WindowId, windowLocalIdentity)
import Hetoimasia.Runtime.GLFW.Internal.Graphics (GraphicsCell)
import Hetoimasia.Runtime.GLFW.Internal.Host.Config (HostConfig)
import Hetoimasia.Runtime.GLFW.Internal.Retirement (HostRetirement)
import Numeric.Natural (Natural)

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
  , hostInterposedQuiescence ∷ STM ()
    -- ^ What a lifetime interposed on the protected exit closes in the host's
    -- own quiescence transaction, after the host's admission: the graphics
    -- owner's publications. Fixed at construction; every other host does
    -- nothing here.
  }

-- | Where the private examples interrupt a host. Production passes
-- 'noHostHooks'.
data HostHooks = HostHooks
  { afterRegistration ∷ IO ()
    -- ^ Runs at the end of a window's registration, masked and with nothing
    -- interruptible before it: after the collection and the host have both
    -- registered the window, before its creation's result is published.
  , afterPublication ∷ IO ()
    -- ^ Runs inside 'attachWindowGraphics', after the attachment has settled
    -- and its service has been published, and outside the handler that would
    -- have begun its retirement. It is the one way to reach an attachment
    -- that is /active/ and whose caller never received the answer, which is
    -- otherwise unreachable: the window between publication and the caller's
    -- own next step is masked.
  , beforePublication ∷ IO ()
    -- ^ Runs inside 'attachWindowGraphics', after the attachment's construction
    -- has settled and before its service is published, so an example can reach
    -- exactly that handoff from another thread.
  , afterOwnerOperation ∷ IO ()
    -- ^ Runs on the owner's own thread, after one injected backend operation
    -- has returned and before the state it settles is committed — the window
    -- in which losing the answer would mean offering the operation again. It
    -- is the only way to observe that window, and an example may only look
    -- from it: anything that blocks here would /create/ the interruption
    -- point the mask exists to keep out.
  , afterDestructionSnapshot ∷ IO ()
    -- ^ Runs on the protected exit's main thread, on every turn of the wait
    -- for the graphics owner's destruction: after that turn's one coherent
    -- snapshot of the owner's terminal record and targets has been read, and
    -- before the exit acts on it. An example may block here — via STM, never
    -- on the owner's thread — until the owner has published more than the
    -- snapshot holds, which is how it shows that the turn decides from the
    -- snapshot alone rather than from a later, mixed read.
  , beforeConsumer ∷ WindowHost → IO ()
    -- ^ Runs on the protected lifetime's own consumer path: after its exit
    -- handler is installed and before the consumer it was given is entered, so
    -- whatever this attaches, and however it then fails, is drained exactly as
    -- the consumer's own attachments are. It never runs for a host built as an
    -- ordinary 'Scoped' value, which can hold no attachment.
  }

noHostHooks ∷ HostHooks
noHostHooks = HostHooks (pure ()) (pure ()) (pure ()) (pure ()) (pure ()) (\_ → pure ())

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

-- | Whether a host owns retirement state, and so whether an attachment may
-- name it. Only 'withProtectedWindowHostWith' builds a 'Protected' one.
data HostProtection = Unprotected | Protected
  deriving (Eq, Show)

-- | The validated configuration the host was built from.
hostConfiguration ∷ WindowHost → HostConfig
hostConfiguration = hostSettings

-- | The session the host owns, for the surface bridge. It is never exported by
-- a public module.
hostSessionOf ∷ WindowHost → Session
hostSessionOf = hostSession

-- | The host's retirement state, or 'Nothing' for a host built by the
-- @Scoped@ constructors, for the surface bridge.
hostRetirementOf ∷ WindowHost → Maybe HostRetirement
hostRetirementOf = hostRetirementState

-- | The identifiers a failure about one window is annotated with.
windowIdentifiers ∷ WindowId → [(Text, Text)]
windowIdentifiers window = [("window", Text.pack (show (windowLocalIdentity window)))]

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
