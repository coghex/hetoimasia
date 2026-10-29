-- | The boundary between the window provider (LFE-18) and the protected hosts it borrows.
--
-- The provider ("Hetoimasia.LuaEngine.Graphics.Window.Provider") never names a GLFW window, a Vulkan
-- surface or a session. It asks a 'Port' for everything native, and a 'Port' answers in the few
-- facts below. The production port ("Hetoimasia.LuaEngine.Graphics.Window.Host") is built over a
-- running 'Hetoimasia.GPU.Vulkan.GLFW.VulkanHost'; this package's lifecycle tests build ports whose
-- native creation, client handoff, attachment, admission, close observation and retirement are each
-- held or let go by the example, so every race is driven without a window.
--
-- = Identities
--
-- A port numbers what it makes ('CreateToken' for an issued command, 'WindowToken' for a window and
-- the one attachment it will have). Tokens are issued in order and never again, so a stale or foreign
-- token can never name a later window even if a native slot is reused. The provider keeps tokens;
-- the port keeps whatever native value stands behind each.
--
-- = The threads a port knows
--
-- * /The process main thread/: 'portAttach' (a surface is created through GLFW inside the window's
--   attachment and handed to the owner, and a deferred announcement is repeated) runs there and only
--   there, from the provider's 'Hetoimasia.LuaEngine.Graphics.Window.Provider.windowMainStep'.
-- * /Any other thread/: issuing a creation or a close command is a nonblocking submission to the
--   host's bounded command port; every reading is a transaction.
--
-- = Waiting without polling
--
-- A port never sleeps and never polls. Every fact the provider waits for is read in a transaction
-- (a ticket's outcome, a standing, a window's own close observation, a retirement reading), so the
-- provider's one pump wakes when the variable it read changes. 'portQueueRoom' is the capacity of the
-- host's command queue, a state rather than a change.
module Hetoimasia.LuaEngine.Graphics.Window.Port
  ( -- * The port
    Port (..)

    -- * Identities
  , CreateToken (..)
  , WindowToken (..)

    -- * Creation
  , CreateIssue (..)
  , CreateOutcome (..)

    -- * Attachment (main thread)
  , AttachOutcome (..)
  , Standing (..)

    -- * Closing
  , CloseBegin (..)

    -- * Retirement
  , Retirement (..)
  , GraphicsRetirement (..)
  , NativeRetirement (..)
  , retirementComplete

    -- * Faults
  , Fatal (..)
  , fatalText
  ) where

import Control.Concurrent.STM (STM)
import Data.Text (Text)
import Data.Word (Word64)
import Numeric.Natural (Natural)

-- | An issued creation command, before its window is known.
newtype CreateToken = CreateToken Word64
  deriving (Eq, Ord, Show)

-- | One window, its client and its one attachment. Never reissued.
newtype WindowToken = WindowToken Word64
  deriving (Eq, Ord, Show)

-- | A fault the provider treats as fatal to the whole session, with bounded evidence. It is never a
-- @window_error@, never busy and never a cancellation. A fault of retirement (a disposal that failed, graphics that
-- could not retire) is a cleanup failure; anything else is a failure of the host.
data Fatal
  = Fatal !Text
  | CleanupFatal !Text
  deriving (Eq, Show)

-- | The bounded evidence of a fault.
fatalText ∷ Fatal → Text
fatalText = \case
  Fatal why → why
  CleanupFatal why → why

-- | Everything the provider asks of the hosts, over the capability @target@ a ready window yields to
-- the later scene adapter (it is opaque here).
data Port target = Port
  { portIssueCreate ∷ Text → Int → Int → IO CreateIssue
    -- ^ Issue a creation command for a visible, decorated, resizable window with no client API, of
    -- this title and size preference. Nonblocking, any thread. The window it makes is registered by
    -- the host before the ticket settles, so an uncollected ticket never makes an untracked window:
    -- the provider keeps the token from the moment this returns.
  , portCreateOutcome ∷ CreateToken → STM (Maybe CreateOutcome)
    -- ^ Where an issued creation stands: 'Nothing' while it is queued or running.
  , portAttach ∷ WindowToken → IO AttachOutcome
    -- ^ Main thread only. The first call hands the window to the graphics owner (creating its
    -- surface under its attachment and announcing it); a later call repeats a deferred
    -- announcement, never building a second surface or window.
  , portStanding ∷ WindowToken → STM Standing
    -- ^ The graphics owner's answer for the window's attachment.
  , portCloseRequest ∷ WindowToken → STM Natural
    -- ^ The newest /genuine/ native close request latched in this window's own observations since its
    -- creation handoff, by its per-window number (zero when none). A window's closing phase, its
    -- end, a native destruction notice and any close the provider itself begun are not requests.
  , portBeginClose ∷ WindowToken → IO CloseBegin
    -- ^ Begin the window's close protocol (normal use and admission close, its attachment begins
    -- retiring). Idempotent and nonblocking. It reports the close begun, never native destruction.
  , portRetirement ∷ WindowToken → STM Retirement
    -- ^ The two separate outcomes retirement is: graphics use and the attachment, and the native
    -- window. A close ticket, a worker exit and a scope exit are neither.
  , portTarget ∷ WindowToken → STM (Maybe target)
    -- ^ The capability to publish a scene to this window's incarnation, once its target is usable.
  , portOwnerFailure ∷ STM (Maybe Fatal)
    -- ^ A terminal failure of the session's graphics or window owner, if one has latched.
  , portQueueRoom ∷ STM Bool
    -- ^ Whether the host's bounded command queue has room for a command now. A state, not a change: a queue
    -- that filled and drained between a refusal and the reading cannot be missed, because the reading is of the
    -- capacity itself. The provider waits on it, in the transaction that decides, for a command the queue refused.
  , portWakeMain ∷ IO ()
    -- ^ Ask the process main thread's owner loop for a turn, so 'portAttach' work is served without
    -- a Lua poll, a frame or a texture. Nonblocking.
  }

-- | What issuing a creation came to.
data CreateIssue
  = -- | The command is in the host's bounded queue: this token stands for it.
    CreateIssued !CreateToken
  | -- | The host's bounded command queue had no room. Pressure: the accepted request stays pending
    -- and the provider issues it again when the queue changes. It is never a busy answer.
    CreateQueueFull
  | -- | The host no longer takes commands (its admission ended): the session is stopping.
    CreateClosed
  | -- | The host refused the command for a reason that is the adapter's fault after its own
    -- validation (a poisoned creation, an invalid configuration, a capacity it was sized for).
    CreateFault !Fatal
  deriving (Eq, Show)

-- | How an issued creation settled.
data CreateOutcome
  = -- | The native window exists, registered and tracked, with its client captured. It is not yet
    -- evidence of graphics readiness.
    Created !WindowToken
  | -- | A clean, verified refusal: the host rolled back exactly what it acquired and consumed no
    -- capacity. The only creation outcome that is a @window_error@. Bounded text.
    CreateRefusedClean !Text
  | -- | The command was settled without being performed because the host closed (not executed):
    -- cancellation, stop or cleanup, never @window_error@.
    CreateNotExecuted
  | -- | Anything else: an interrupted ticket, retained rollback evidence, a poisoned host.
    CreateFatal !Fatal
  deriving (Eq, Show)

-- | What attaching a window to the graphics owner came to (main thread).
data AttachOutcome
  = -- | The surface was created under the attachment and the owner has been told.
    AttachAnnounced
  | -- | Attached with its surface deposited, but the owner's bounded port was full. It stays under
    -- the owner's bounded progress and is announced again; no second surface or window.
    AttachDeferred
  | -- | The owner has not yet leased an instance to the surface bridge: nothing was attached.
    -- Bounded waiting on the same window; hand over again once the owner is ready.
    AttachRootsPending
  | -- | The owner's admission ended, the handover was superseded, or the window is closing because
    -- of this adapter's own cleanup or the session's stop: the cancellation path, never
    -- @window_error@.
    AttachEnded
  | -- | The owner refused the target and verified its own rollback: a @window_error@. Bounded text.
    AttachRefusedClean !Text
  | -- | A fatal host fault (unsafe or retained rollback evidence, a failed session, a pending
    -- diagnostic, an occupied slot, a foreign session).
    AttachFault !Fatal
  deriving (Eq, Show)

-- | The graphics owner's answer for one attachment.
data Standing
  = -- | Not attached yet, or attached and not yet announced, or the owner is still constructing.
    StandingPending
  | -- | The target was admitted: the window can accept scene publication.
    StandingUsable
  | -- | The owner rolled the target back and verified that nothing remains: a @window_error@.
    StandingRefusedClean !Text
  | -- | The target ended because of this adapter's own close or the session's stop.
    StandingEnded
  | -- | Partial or unverified construction, or any other state that is not clean: fatal.
    StandingFatal !Fatal
  deriving (Eq, Show)

-- | What beginning a close came to.
data CloseBegin
  = -- | The close protocol began, or had already begun: idempotent.
    CloseBegun
  | -- | The host's bounded queue had no room; retried when it changes.
    CloseQueueFull
  | -- | The host no longer serves the window (it has ended, or never held it).
    CloseGone
  | CloseFault !Fatal
  deriving (Eq, Show)

-- | The two outcomes retirement is, observed separately.
data Retirement = Retirement
  { retirementGraphics ∷ !GraphicsRetirement
  , retirementNative ∷ !NativeRetirement
  }
  deriving (Eq, Show)

-- | Whether graphics use and the attachment have retired.
data GraphicsRetirement
  = GraphicsInUse
  | GraphicsRetired
  | GraphicsRetireFailed !Fatal
  deriving (Eq, Show)

-- | Whether the native window has been destroyed.
data NativeRetirement
  = NativePending
  | NativeDisposed
  | -- | The release failed: recorded, never attempted twice, never reported as destroyed.
    NativeDisposalFailed !Fatal
  deriving (Eq, Show)

-- | Both outcomes are in, and neither failed.
retirementComplete ∷ Retirement → Bool
retirementComplete (Retirement GraphicsRetired NativeDisposed) = True
retirementComplete _ = False
