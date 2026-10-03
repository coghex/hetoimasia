-- | A window's one handle, the records its cells hold, and the narrow
-- operations other window modules update its control state through.
--
-- This module defines representation and documents ownership. The handle is
-- built once, by "Hetoimasia.GLFW.Internal.Window.Construction", on the
-- session's owner thread, and every other window module reads or writes these
-- same cells rather than a copy of them. The window owns every cell, and the
-- owner thread is their only writer apart from the callbacks, which write the
-- capture latch and input staging from inside native calls made on that same
-- thread.
--
-- = State
--
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | State               | Owner         | Readers and writers        | Thread      | Lifetime            | Reset or disposal        |
-- +=====================+===============+============================+=============+=====================+==========================+
-- | Native window       | The window    | Created and destroyed by   | Owner       | The window's scope  | Destroyed at release     |
-- |                     |               | its parts; owner steps use |             |                     |                          |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Callback storage    | The window    | Allocated, attached,       | Owner       | Through the final   | Freed after a certain    |
-- |                     |               | detached, and freed by its |             | native use          | release; kept otherwise  |
-- |                     |               | parts; GLFW invokes it     |             |                     |                          |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Capture latch       | The window    | Callbacks write;           | Callbacks:  | The window          | Emptied at each boundary |
-- |                     |               | boundaries and release     | owner calls |                     |                          |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Input staging       | The window    | Input callbacks write;     | Callbacks:  | The window          | Discarded on overflow or |
-- |                     |               | the owner boundary         | owner       |                     | published, then emptied  |
-- |                     |               | publishes or discards      | publishes   |                     |                          |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Attached input feed | The window    | The host attaches it;      | Owner       | From attachment     | Closed with the window   |
-- |                     |               | the owner boundary         |             | until the window    |                          |
-- |                     |               | publishes into it          |             | ends                |                          |
-- |                     |               | take                       |             |                     |                          |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Current observation | The window    | Boundaries write and then  | Owner       | The window          | Final value retained in  |
-- | and close counter   |               | publish                    |             |                     | the closed snapshot      |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Observation         | The window    | Owner publishes and        | Publish:    | Beyond the window,  | Closed at release; never |
-- | snapshot            |               | closes; readers read       | owner;      | while referenced    | reopened                 |
-- |                     |               |                            | read: any   |                     |                          |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Liveness            | The window    | Release clears it; every   | Owner       | The window          | Never set again          |
-- |                     |               | operation reads it         |             |                     |                          |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Release certainty   | The window    | Uncertain parts clear it;  | Owner       | The window          | Read by the storage and  |
-- |                     |               | later releases read it     |             |                     | observation releases     |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Release failure     | The window    | A failing part sets it;    | Owner       | The window          | Read by the observation  |
-- |                     |               | the observation release    |             |                     | release                  |
-- |                     |               | reads it                   |             |                     |                          |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Windowed and native | The window    | Constraint updates and     | Owner       | The window          | Known, unconstrained,    |
-- | constraint states   |               | transitions write;         |             |                     | and followed at creation |
-- |                     |               | controls and transitions   |             |                     |                          |
-- |                     |               | read                       |             |                     |                          |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Mode transition     | The window    | Transitions set and clear  | Owner       | The window          | Clear at creation        |
-- | marker              |               | it; controls and           |             |                     |                          |
-- |                     |               | transitions read           |             |                     |                          |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Mode record         | The window    | Transitions and their      | Owner       | The window          | Seeded at creation;      |
-- |                     |               | samples write; the         |             |                     | final value retained in  |
-- |                     |               | observation publishes it   |             |                     | the closed snapshot      |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
--
-- None of this is application state.
--
-- = The hide guard
--
-- One field is not a cell: 'windowBeforeHide', an owner-thread action a hide
-- control runs immediately before its native call. A handle built by
-- "Hetoimasia.GLFW.Internal.Window.Construction" carries none. A component
-- that knows more about the window than this package does — the protected
-- host's graphics attachments (#368) — lends a copy carrying its own action
-- with 'guardWindowHide'. The copy shares every cell above, so it is the same
-- window in every respect but this one, and the action is the lender's, not
-- the window's: a lender that installs none leaves hides exactly as they are.
module Hetoimasia.GLFW.Internal.Window.State
  ( -- * The window handle
    Window (..)
  , WindowResult (..)
  , windowIdentity
  , windowObservations
  , windowEnded
  , windowNativeHandle
  , attachWindowInputFeed
  , windowInputFeed
  , guardWindowHide

    -- * The owner's state
  , OwnerState (..)
  , ControlState (..)
  , setConstraintState
  , setNativeConstraints
  , setModeTransition

    -- * The capture latch
  , Captures (..)
  , noCaptures
  , StagedInput (..)
  , inputStagingCapacity
  , CallbackFault (..)

    -- * Naming a window in failures and traces
  , windowCallbackOperation
  , windowIdentifiers
  , traceLabel
  ) where

import Control.Exception (ExceptionWithContext, SomeException)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Foreign.Ptr (Ptr)
import Hetoimasia.Foundation.Failure (Operation, operation)
import Hetoimasia.Foundation.Messaging.Snapshot (SnapshotPublisher, SnapshotReader, snapshotReader)
import Hetoimasia.GLFW.Internal.Attribute (ContentScale (..), CursorPosition (..), Extent (..), Placement (..))
import Hetoimasia.GLFW.Internal.Control (ConstraintState (..))
import Hetoimasia.GLFW.Internal.Input (ButtonEvent (..), InputFeed, KeyEvent (..), ScrollEvent (..))
import Hetoimasia.GLFW.Internal.Mode (NativeConstraints (..))
import Hetoimasia.GLFW.Internal.Session (NativeWindow, Session)
import Hetoimasia.GLFW.Internal.Window.Identity (WindowId, windowLocalIdentity)
import Hetoimasia.GLFW.Internal.Window.Observation (WindowObservation)
import Numeric.Natural (Natural)

-- | A scoped window. Its representation is private to this package.
data Window = Window
  { windowSession ∷ !Session
  , windowId ∷ !WindowId
  , windowHandle ∷ !(Ptr NativeWindow)
  , windowLive ∷ !(IORef Bool)
  , windowCaptures ∷ !(IORef Captures)
  , windowOwnerState ∷ !(IORef OwnerState)
  , windowControl ∷ !(IORef ControlState)
  , windowPublisher ∷ !(SnapshotPublisher WindowObservation)
  , windowFeed ∷ !(IORef (Maybe InputFeed))
  , windowBeforeHide ∷ !(IO ())
    -- ^ Run on the owner thread immediately before a hide control's native
    -- call, once every check has admitted it; see 'guardWindowHide'.
  }

-- | What an operation through a handle produced.
data WindowResult a
  = WindowAvailable a
  | WindowEnded !WindowId
    -- ^ The window has ended; no native call was made.
  deriving (Eq, Show)

-- | The window's identity.
windowIdentity ∷ Window → WindowId
windowIdentity = windowId

-- | The read endpoint of the window's observations. It stays readable after the
-- window ends, holding the terminal observation.
windowObservations ∷ Window → SnapshotReader WindowObservation
windowObservations = snapshotReader . windowPublisher

-- | Whether the window has ended. Any thread may ask.
windowEnded ∷ Window → IO Bool
windowEnded window = not <$> readIORef (windowLive window)

-- | Attach the feed this window's owner boundary publishes staged input into.
-- Replacing a feed leaves the previous one untouched; the caller owns closing
-- it. A window with no feed discards staged input at the boundary.
attachWindowInputFeed ∷ Window → InputFeed → IO ()
attachWindowInputFeed window = atomicWriteIORef (windowFeed window) . Just

-- | The feed last attached, if any.
windowInputFeed ∷ Window → IO (Maybe InputFeed)
windowInputFeed window = readIORef (windowFeed window)

-- | The same window, whose hide controls run this action, on the owner thread,
-- immediately before their native call and after every check that could refuse
-- them. A control refused, unsupported, or not attempted runs nothing; one
-- that raises out of the action makes no native call, and the failure
-- propagates. The action replaces any the handle already carried. It must
-- return finitely and pump no native events.
guardWindowHide ∷ IO () → Window → Window
guardWindowHide action window = window {windowBeforeHide = action}

-- | The owner's current observation and the last close request number issued.
data OwnerState = OwnerState !WindowObservation !Natural

-- | What the owner knows about the window's preserved windowed constraints, what
-- the native constraints hold relative to them, and whether its mode transition
-- marker is set.
data ControlState = ControlState
  { stateWindowed ∷ !ConstraintState
  , stateNative ∷ !NativeConstraints
  , stateTransition ∷ !Bool
  }

-- | What the callbacks recorded since the last boundary took it.
data Captures = Captures
  { capturedSize ∷ !(Maybe Extent)
  , capturedFramebuffer ∷ !(Maybe Extent)
  , capturedScale ∷ !(Maybe ContentScale)
  , capturedPlacement ∷ !(Maybe Placement)
  , capturedFocused ∷ !(Maybe Bool)
  , capturedIconified ∷ !(Maybe Bool)
  , capturedMaximized ∷ !(Maybe Bool)
  , capturedRefresh ∷ !Bool
  , capturedCloses ∷ !Natural
  , capturedFault ∷ !(Maybe CallbackFault)
  , capturedGeneration ∷ !Natural
    -- ^ Advanced by every record, so a commit can tell whether a callback
    -- recorded anything since the captures it folded were read.
  , capturedCursor ∷ !(Maybe CursorPosition)
  , capturedCursorInside ∷ !(Maybe Bool)
  , capturedInput ∷ ![StagedInput]
    -- ^ Ordered input, newest first, at most 'inputStagingCapacity'.
  , capturedInputCount ∷ !Int
  , capturedInputLost ∷ !Natural
    -- ^ Ordered events that could not be staged, counted exactly.
  , capturedInputLoss ∷ !Bool
  }

-- | One ordered input event copied at the trampoline. Cursor motion is not
-- staged: it coalesces onto 'capturedCursor'.
data StagedInput
  = StagedKey !KeyEvent
  | StagedChar !Char
  | StagedButton !ButtonEvent
  | StagedScroll !ScrollEvent
  | StagedFocus !Bool

-- | How many ordered input events one window stages between owner boundaries.
inputStagingCapacity ∷ Int
inputStagingCapacity = 256

-- | The first fault a callback raised since the last boundary, the callback it
-- was raised in, and how many later faults were not kept.
data CallbackFault = CallbackFault !Text !(ExceptionWithContext SomeException) !Natural

noCaptures ∷ Captures
noCaptures =
  Captures
    { capturedSize = Nothing
    , capturedFramebuffer = Nothing
    , capturedScale = Nothing
    , capturedPlacement = Nothing
    , capturedFocused = Nothing
    , capturedIconified = Nothing
    , capturedMaximized = Nothing
    , capturedRefresh = False
    , capturedCloses = 0
    , capturedFault = Nothing
    , capturedGeneration = 0
    , capturedCursor = Nothing
    , capturedCursorInside = Nothing
    , capturedInput = []
    , capturedInputCount = 0
    , capturedInputLost = 0
    , capturedInputLoss = False
    }


-- | The operation a rethrown callback fault is annotated with.
windowCallbackOperation ∷ Operation
windowCallbackOperation = operation "window callback"

windowIdentifiers ∷ WindowId → [(Text, Text)]
windowIdentifiers window = [("window", Text.pack (show (windowLocalIdentity window)))]

-- | How a window names itself in the session's interaction trace: the same
-- local identity 'windowIdentifiers' carries.
traceLabel ∷ WindowId → Text
traceLabel = Text.pack . show . windowLocalIdentity

-- | Record the preserved windowed constraints an ordinary update established,
-- which the native constraints then follow.
setConstraintState ∷ Window → ConstraintState → IO ()
setConstraintState window state =
  atomicModifyIORef' (windowControl window) (\current → (current {stateWindowed = state, stateNative = NativeFollowsWindowed}, ()))

setNativeConstraints ∷ Window → NativeConstraints → IO ()
setNativeConstraints window native =
  atomicModifyIORef' (windowControl window) (\current → (current {stateNative = native}, ()))

-- | Set or clear the window's mode transition marker: the private, owner-internal
-- state ordinary controls and other transitions are refused under while it is
-- set. A transition sets it for its interval, and the seam's private driver
-- sets it in the CPU examples; no public command does.
setModeTransition ∷ Window → Bool → IO ()
setModeTransition window transition =
  atomicModifyIORef' (windowControl window) (\current → (current {stateTransition = transition}, ()))

-- | The native window, for the private drivers in this package only.
windowNativeHandle ∷ Window → Ptr NativeWindow
windowNativeHandle = windowHandle
