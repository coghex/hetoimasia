{-# LANGUAGE DeriveGeneric #-}

-- | Scoped GLFW windows and the observations they publish, written over the
-- session's table of native operations.
--
-- A 'Window' is created inside a live 'Session' by 'windowAssembly', one staged
-- composite that acquires the window's callback storage, its native window,
-- the callbacks' registration, and the snapshot its observations are published
-- through. It is lent to the enclosing scope and released when that scope ends.
-- Collection-backed construction — the window host's dynamic windows in
-- "Hetoimasia.Runtime.GLFW" — reuses the same assembly as one member of a
-- "Hetoimasia.Foundation.Resource.Collection"; there is no second acquisition or
-- cleanup path.
--
-- = Owner, thread, and lifetime
--
-- The owner is the session's owner, the process main thread. Every native call
-- and every owner boundary below runs there, and each checks, before any native
-- call, that it does ('NotSessionOwner') and that the session is live
-- ('SessionEnded'). A window lives until its enclosing scope ends. Its handle
-- turns terminal as the first step of release, after every borrowing scope has
-- ended, and every later operation through it answers 'WindowEnded' without a
-- native call. Identities are the session's identity and a local number the
-- session never reissues, so a later window never answers to an ended one's
-- handle.
--
-- = Creation
--
-- In order:
--
-- 1. The configuration is validated: both dimensions must lie in
--    @1 .. 2147483647@ and the title must contain no NUL, or creation fails
--    with 'WindowConfigRejected' before any conversion to C.
-- 2. The owner thread and liveness are checked, and a session whose teardown
--    safety is already lost refuses with 'SessionPoisoned'.
-- 3. Callback storage is allocated.
-- 4. Every creation hint is reset, then NoAPI, visibility, focus, and focus on
--    show are set explicitly, and the window is created. A live pointer's
--    destruction is registered before any error its creation reported is
--    raised.
-- 5. The callbacks' detach is registered, and then every callback is attached,
--    so an attachment that reports an error or raises part-way is detached
--    before the window is destroyed.
-- 6. The initial observation is sampled at that owner boundary, reconciled
--    with anything the callbacks captured since attachment, prepared, and
--    becomes revision zero of a fresh snapshot.
--
-- A failure at any stage releases exactly what the stages before it acquired,
-- in the release order below, with the triggering failure primary.
--
-- = Observations
--
-- A 'WindowObservation' is immutable and prepared to normal form before it is
-- published. It carries the window's identity, a revision equal to the
-- snapshot's, a 'WindowPhase', and each attribute as an 'Attribute': logical
-- extent, framebuffer extent, content scale, and desktop placement are
-- separate fields. A query that reports only @GLFW_FEATURE_UNAVAILABLE@ yields
-- 'Unavailable'; any other report fails the boundary with 'NativeFailure'.
-- Nothing observed is ever copied from the request. A zero framebuffer extent
-- is an ordinary observation of a window that cannot be drawn to.
--
-- = Callbacks and the reconciliation boundary
--
-- The size, framebuffer size, content scale, position, focus, iconify,
-- maximize, refresh, and close callbacks are contained at the trampoline. Each
-- runs uninterruptibly, copies its fixed payload, records it into the window's
-- capture latch with one non-blocking 'IORef' update, and returns. None calls
-- application code, waits, polls, logs, or destroys anything. Anything a
-- callback raises is caught there with its context and latched instead of
-- unwinding into C; only the first is kept, and later ones are counted.
--
-- Captures are reconciled on the owner thread at an owner boundary: after the
-- initial sampling, and after any owner operation's native calls return,
-- whether they were a setter or a poll. Geometry and attribute captures
-- coalesce to their latest values, so a snapshot preserves no event history. A
-- refresh or a close request always publishes a new revision, even when every
-- sampled attribute is unchanged. Preparation runs in 'IO', outside the
-- trampoline and outside 'STM'. Nothing changes until the commit: after
-- preparation, the captures are cleared, the observation published, and the
-- owner's state written in one masked step with no interruptible operation, so
-- a cancellation before it leaves every capture latched and nothing can
-- separate the three writes. A latched fault is taken and rethrown in one
-- masked step as well, so a cancellation cannot discard it. Once the observation is published, a latched
-- callback fault is rethrown with its original type and context, annotated
-- with the @window callback@ operation, the callback, and the window. An
-- asynchronous exception is rethrown unannotated, so cancellation stays
-- cancellation. If the operation's own native step fails first, its failure
-- propagates and the captures and fault stay latched for the next boundary.
--
-- = Ordinary controls
--
-- 'controlWindow' executes one ordinary control — title, size, position, size
-- constraints, visibility, focus, attention, minimize, maximize, or restore — at
-- an owner boundary. In order, and before any native call:
--
-- 1. pending captures are reconciled, so validation reads the owner's latest
--    observation rather than one a client holds;
-- 2. a window whose close protocol has begun attempts nothing;
-- 3. a window whose mode transition marker is set refuses the control with
--    'ModeTransitionInProgress';
-- 4. an operation the session's 'WindowCapabilities' names as unperformable
--    settles as unsupported, with its reason;
-- 5. the control is validated against the window's constraint state and latest
--    observed logical size, under "Hetoimasia.GLFW.Internal.Control"'s rules.
--
-- Then the native calls are made, each bracketed by the error capture so its
-- reports belong to this control alone, and afterwards every attribute is
-- sampled and a new revision is published even if nothing changed, so the
-- revision the result names was produced by a sample taken after the call. It
-- promises nothing about the window manager's convergence. A control changes no
-- mode and the window's mode transition marker, set only through the private
-- 'setModeTransition', is never changed by one.
--
-- A constraint update marks the window's constraint state indeterminate before
-- its first call and known only after every call returned without a report.
--
-- = Close requests
--
-- A native close request never destroys the window and never exits. It is
-- latched and reconciled into 'observedCloseRequest' as a 'CloseRequest' with
-- its own number, issued in increasing order per window. Rejecting a request
-- clears it only if it is still the latest, so rejecting an older request
-- cannot erase a newer one. What a close request means is the application's
-- decision; this module adds no close policy and no public command.
--
-- = Lifecycle phases
--
-- An observation's 'WindowPhase' records where the window is in its lifetime:
--
-- * 'WindowOpen' from creation;
-- * 'WindowClosing' once an owner has begun the window's close protocol with the
--   private 'beginWindowClosing', published as its own revision in the same
--   transaction as the owner's own record that closing began, so no
--   cancellation can separate the two; reconciliation keeps the phase while
--   callbacks are still attached;
-- * exactly one terminal phase, published by release as the snapshot's last
--   revision before it closes: 'WindowReleased' when every release part
--   succeeded, 'WindowDisposalFailed' when a part failed but release stayed
--   certain, and 'WindowReleaseUncertain' when release could not establish that
--   callbacks and the native window ended safely.
--
-- The terminal phase is computed from two flags the release parts set, not from
-- the exceptions they raise: nothing is formatted, logged, or retained in the
-- observation, and the failures themselves stay on the release's failure path as
-- cleanup evidence. A lexically scoped window never passes through
-- 'WindowClosing'.
--
-- = Release
--
-- Release order is declared, not reversed:
--
-- +---+-----------------------------------+------------------------------------------------+
-- |   | Part                              | Release                                        |
-- +===+===================================+================================================+
-- | 1 | @glfw window callbacks@           | Mark terminal; take any latched fault; detach  |
-- +---+-----------------------------------+------------------------------------------------+
-- | 2 | @glfw window@                     | Destroy the native window                      |
-- +---+-----------------------------------+------------------------------------------------+
-- | 3 | @glfw window callback storage@    | Free the wrappers if release stayed certain;   |
-- |   |                                   | otherwise keep them and poison the session     |
-- +---+-----------------------------------+------------------------------------------------+
-- | 4 | @glfw window observations@        | Publish the terminal observation and close the |
-- |   |                                   | snapshot in one transaction                    |
-- +---+-----------------------------------+------------------------------------------------+
--
-- Each native release reads errors after its call returns, logs nothing, pumps
-- no events, and waits for no other thread. A reported error whose call
-- returned is retained as that part's cleanup failure. After a detach it leaves
-- release certain, as does a callback fault nobody observed; after a destroy it
-- leaves the window's destruction unestablished, so release becomes uncertain. That fault is taken before
-- the detach: it is raised on its own after a detach that succeeded, and
-- retained as a @glfw window callback fault@ cleanup failure beside a detach
-- that raised or reported an error, whose failure stays primary. A detach or
-- destroy that
-- raises instead of returning, a release attempted off the owner thread or
-- after the session ended, or an attachment that raised leaves callback
-- reachability uncertain: the storage is then kept rather than freed beneath
-- native code, the session refuses further windows with 'SessionPoisoned', and
-- its guard is poisoned when it ends. The terminal observation keeps the last
-- observed attributes without querying the destroyed window, and names
-- 'WindowReleased' only when release stayed certain, 'WindowReleaseUncertain'
-- otherwise, or 'WindowDisposalFailed' when a part failed while release stayed
-- certain. Readers may still read it, and receive 'EndOfStream' after it.
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
-- | Constraint state    | The window    | Constraint updates write;  | Owner       | The window          | Known and unconstrained  |
-- |                     |               | controls read              |             |                     | at creation              |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
-- | Mode transition     | The window    | 'setModeTransition'        | Owner       | The window          | Clear at creation        |
-- | marker              |               | writes; controls read      |             |                     |                          |
-- +---------------------+---------------+----------------------------+-------------+---------------------+--------------------------+
--
-- None of this is application state.
module Hetoimasia.GLFW.Internal.Window
  ( -- * Configuration
    WindowConfig (..)
  , defaultWindowConfig
  , hiddenTestWindowConfig
  , WindowConfigRejected (..)
  , validateWindowConfig

    -- * Windows
  , Window
  , windowAssembly
  , windowIdentity
  , windowObservations
  , windowEnded
  , WindowResult (..)
  , synchronizeWindow

    -- * Identity
  , WindowId
  , windowLocalIdentity

    -- * Observations
  , WindowObservation
  , observedWindow
  , observedRevision
  , observedPhase
  , observedLogicalExtent
  , observedFramebufferExtent
  , observedContentScale
  , observedPlacement
  , observedFocused
  , observedIconified
  , observedMaximized
  , observedVisible
  , observedCloseRequest
  , WindowPhase (..)
  , Attribute (..)
  , Extent (..)
  , ContentScale (..)
  , Placement (..)
  , CloseRequest
  , closeRequestWindow
  , closeRequestNumber

    -- * Ordinary controls
  , controlWindow
  , setModeTransition

    -- * Private owner-turn operations
  , EventProcessing (..)
  , processWindowEvents
  , reconcileWindowEvents

    -- * Private owner-boundary drivers
  , windowStep
  , windowStepWith
  , windowSession
  , rejectCloseRequest
  , beginWindowClosing
  , windowNativeHandle
  , windowCallbackOperation
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.DeepSeq (NFData (rnf))
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , evaluate
  , mask_
  , onException
  , rethrowIO
  , try
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (forM_, unless, void, when)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import qualified Data.Text as Text
import Data.Text (Text)
import Data.Unique (Unique)
import Foreign.C.Types (CInt)
import Foreign.Ptr (Ptr, nullPtr)
import GHC.Generics (Generic)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure, withOperationContext)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare)
import Hetoimasia.Foundation.Messaging.Snapshot
  ( SnapshotPublisher
  , SnapshotReader
  , closeSnapshot
  , newSnapshot
  , publish
  , snapshotReader
  )
import Hetoimasia.Foundation.Resource (Assembly, acquirePart, releaseRank, restoredStep, withResourceLabelled)
import Hetoimasia.GLFW.Internal.Attribute (Attribute (..), ContentScale (..), Extent (..), Placement (..))
import Hetoimasia.GLFW.Internal.Control
  ( AspectRatio (..)
  , ConstraintCall (..)
  , ConstraintState (..)
  , ControlOutcome (..)
  , ControlRejection (..)
  , ControlResult (..)
  , PostCallObservation (..)
  , SizeConstraints
  , WindowCapabilities
  , WindowControl (..)
  , WindowReport (..)
  , constraintAspectRatio
  , constraintCallOrder
  , constraintMaximum
  , constraintMinimum
  , controlOperation
  , controlOperationText
  , operationGap
  , reportable
  , validateControl
  )
import Hetoimasia.GLFW.Internal.Capture
  ( NativeError (..)
  , Reports (..)
  , hasReports
  , settleStrayOwnerReports
  , takeOwnerReports
  )
import Hetoimasia.GLFW.Internal.Session
  ( Native (..)
  , NativeFailure (..)
  , NativeOutcome (..)
  , NativeWindow
  , Session
  , WindowAttribute (..)
  , WindowCallbackStorage
  , WindowCallbacks (..)
  , WindowHint (..)
  , createWindowOperation
  , destroyWindowOperation
  , glfwComponent
  , nextWindowIdentity
  , ownerOperation
  , poisonSession
  , raiseReported
  , requireUnpoisoned
  , sessionCapture
  , sessionIdentity
  , sessionNative
  , sessionWindowCapabilities
  )
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Configuration

-- | What the application asks of a window. It is a pure value, validated before
-- anything is acquired or converted to C.
data WindowConfig = WindowConfig
  { windowTitle ∷ !Text
  , windowWidth ∷ !Int
    -- ^ The requested content width in screen coordinates.
  , windowHeight ∷ !Int
    -- ^ The requested content height in screen coordinates.
  , windowVisible ∷ !Bool
    -- ^ Whether the window is shown when created.
  , windowFocused ∷ !Bool
    -- ^ Whether a window shown at creation requests input focus.
  , windowFocusOnShow ∷ !Bool
    -- ^ Whether showing the window later requests input focus.
  }
  deriving (Eq, Show)

instance NFData WindowConfig where
  rnf (WindowConfig title width height visible focused focusOnShow) =
    rnf title `seq` rnf width `seq` rnf height `seq` rnf visible `seq` rnf focused `seq` rnf focusOnShow

-- | A shown window that takes focus, of the given title and logical size.
defaultWindowConfig ∷ Text → Int → Int → WindowConfig
defaultWindowConfig title width height =
  WindowConfig
    { windowTitle = title
    , windowWidth = width
    , windowHeight = height
    , windowVisible = True
    , windowFocused = True
    , windowFocusOnShow = True
    }

-- | The test configuration: hidden, not focused, and not focused when shown.
hiddenTestWindowConfig ∷ Text → Int → Int → WindowConfig
hiddenTestWindowConfig title width height =
  (defaultWindowConfig title width height)
    { windowVisible = False
    , windowFocused = False
    , windowFocusOnShow = False
    }

-- | A configuration no window is created from.
data WindowConfigRejected
  = WindowExtentRejected
      { rejectedWidth ∷ !Int
      , rejectedHeight ∷ !Int
      }
    -- ^ A dimension is not in @1 .. 2147483647@.
  | WindowTitleRejected
    -- ^ The title contains a NUL, which C would truncate.
  deriving (Eq, Show)

instance NFData WindowConfigRejected where
  rnf (WindowExtentRejected width height) = rnf width `seq` rnf height
  rnf WindowTitleRejected = ()

instance Exception WindowConfigRejected

-- | The validated request, in the types the native table takes.
data Request = Request !Text !Int32 !Int32 ![WindowHint]

-- | Check a configuration without acquiring anything.
validateWindowConfig ∷ WindowConfig → Either WindowConfigRejected ()
validateWindowConfig = void . validRequest

validRequest ∷ WindowConfig → Either WindowConfigRejected Request
validRequest config
  | not (inRange (windowWidth config) && inRange (windowHeight config)) =
      Left (WindowExtentRejected (windowWidth config) (windowHeight config))
  | Text.elem '\NUL' (windowTitle config) = Left WindowTitleRejected
  | otherwise =
      Right
        ( Request
            (windowTitle config)
            (fromIntegral (windowWidth config))
            (fromIntegral (windowHeight config))
            [ NoClientApi
            , VisibleHint (windowVisible config)
            , FocusedHint (windowFocused config)
            , FocusOnShowHint (windowFocusOnShow config)
            ]
        )
  where
    inRange dimension = dimension >= 1 && toInteger dimension <= toInteger (maxBound ∷ Int32)

-- ---------------------------------------------------------------------------
-- Identity and observations

-- | A window's identity: its session's identity and a local number that
-- session never reissues. Only the local number is displayed.
data WindowId = WindowId !Unique !Natural
  deriving (Eq, Ord)

instance Show WindowId where
  showsPrec precedence (WindowId _ local) =
    showParen (precedence > 10) (showString "WindowId " . showsPrec 11 local)

instance NFData WindowId where
  rnf (WindowId identity local) = identity `seq` rnf local

-- | The window's number within its session, starting at one.
windowLocalIdentity ∷ WindowId → Natural
windowLocalIdentity (WindowId _ local) = local

-- | Where a window is in its lifetime.
data WindowPhase
  = WindowOpen
    -- ^ Created, live, and not yet closing.
  | WindowClosing
    -- ^ Its owner has begun its close protocol; it is not yet released.
  | WindowReleased
    -- ^ Disposed successfully: callbacks detached and the native window
    -- destroyed, with no release part failing.
  | WindowDisposalFailed
    -- ^ Disposal failed: a release part failed, but release still established
    -- that callbacks and the native window ended safely.
  | WindowReleaseUncertain
    -- ^ Disposal failed, and release could not establish that callbacks and the
    -- native window ended safely.
  deriving (Eq, Show, Generic)

instance NFData WindowPhase

-- | One native close request, numbered in increasing order per window.
data CloseRequest = CloseRequest !WindowId !Natural
  deriving (Eq, Ord, Show)

instance NFData CloseRequest where
  rnf (CloseRequest window number) = rnf window `seq` rnf number

-- | The window the request was made for.
closeRequestWindow ∷ CloseRequest → WindowId
closeRequestWindow (CloseRequest window _) = window

-- | The request's number: one more than the window's previous request.
closeRequestNumber ∷ CloseRequest → Natural
closeRequestNumber (CloseRequest _ number) = number

-- | One immutable observation of a window. Its representation is private, so
-- no observation is ever built outside this package.
data WindowObservation = WindowObservation
  { obsWindow ∷ !WindowId
  , obsRevision ∷ !Natural
  , obsPhase ∷ !WindowPhase
  , obsLogical ∷ !(Attribute Extent)
  , obsFramebuffer ∷ !(Attribute Extent)
  , obsScale ∷ !(Attribute ContentScale)
  , obsPlacement ∷ !(Attribute Placement)
  , obsFocused ∷ !(Attribute Bool)
  , obsIconified ∷ !(Attribute Bool)
  , obsMaximized ∷ !(Attribute Bool)
  , obsVisible ∷ !(Attribute Bool)
  , obsCloseRequest ∷ !(Maybe CloseRequest)
  }
  deriving (Eq, Show)

instance NFData WindowObservation where
  rnf observation =
    rnf (obsWindow observation)
      `seq` rnf (obsRevision observation)
      `seq` rnf (obsPhase observation)
      `seq` rnf (obsLogical observation)
      `seq` rnf (obsFramebuffer observation)
      `seq` rnf (obsScale observation)
      `seq` rnf (obsPlacement observation)
      `seq` rnf (obsFocused observation)
      `seq` rnf (obsIconified observation)
      `seq` rnf (obsMaximized observation)
      `seq` rnf (obsVisible observation)
      `seq` rnf (obsCloseRequest observation)

-- | The window observed.
observedWindow ∷ WindowObservation → WindowId
observedWindow = obsWindow

-- | The observation's revision: zero for the initial observation, and the
-- snapshot's revision for every later one.
observedRevision ∷ WindowObservation → Natural
observedRevision = obsRevision

observedPhase ∷ WindowObservation → WindowPhase
observedPhase = obsPhase

-- | The content area's size in screen coordinates.
observedLogicalExtent ∷ WindowObservation → Attribute Extent
observedLogicalExtent = obsLogical

-- | The framebuffer's size in pixels. A zero extent is a valid observation of a
-- window that cannot currently be drawn to.
observedFramebufferExtent ∷ WindowObservation → Attribute Extent
observedFramebufferExtent = obsFramebuffer

observedContentScale ∷ WindowObservation → Attribute ContentScale
observedContentScale = obsScale

observedPlacement ∷ WindowObservation → Attribute Placement
observedPlacement = obsPlacement

observedFocused ∷ WindowObservation → Attribute Bool
observedFocused = obsFocused

observedIconified ∷ WindowObservation → Attribute Bool
observedIconified = obsIconified

observedMaximized ∷ WindowObservation → Attribute Bool
observedMaximized = obsMaximized

observedVisible ∷ WindowObservation → Attribute Bool
observedVisible = obsVisible

-- | The latest close request nobody has rejected, if any.
observedCloseRequest ∷ WindowObservation → Maybe CloseRequest
observedCloseRequest = obsCloseRequest

-- ---------------------------------------------------------------------------
-- Windows

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

-- | The owner's current observation and the last close request number issued.
data OwnerState = OwnerState !WindowObservation !Natural

-- | What the owner knows about the window's active size constraints, and whether
-- its mode transition marker is set.
data ControlState = ControlState !ConstraintState !Bool

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
  }

-- | The first fault a callback raised since the last boundary, the callback it
-- was raised in, and how many later faults were not kept.
data CallbackFault = CallbackFault !Text !(ExceptionWithContext SomeException) !Natural

noCaptures ∷ Captures
noCaptures = Captures Nothing Nothing Nothing Nothing Nothing Nothing Nothing False 0 Nothing 0

-- | Samples taken together at one boundary.
data Sample = Sample
  { sampleLogical ∷ !(Attribute Extent)
  , sampleFramebuffer ∷ !(Attribute Extent)
  , sampleScale ∷ !(Attribute ContentScale)
  , samplePlacement ∷ !(Attribute Placement)
  , sampleFocused ∷ !(Attribute Bool)
  , sampleIconified ∷ !(Attribute Bool)
  , sampleMaximized ∷ !(Attribute Bool)
  , sampleVisible ∷ !(Attribute Bool)
  }

synchronizeOperation, sampleOperation, attachOperation, detachOperation ∷ Operation
synchronizeOperation = operation "synchronize window"
sampleOperation = operation "sample window"
attachOperation = operation "attach window callbacks"
detachOperation = operation "detach window callbacks"

-- | The operation a rethrown callback fault is annotated with.
windowCallbackOperation ∷ Operation
windowCallbackOperation = operation "window callback"

windowIdentifiers ∷ WindowId → [(Text, Text)]
windowIdentifiers window = [("window", Text.pack (show (windowLocalIdentity window)))]

-- | Construct a window in a live session, through the session's native table.
windowAssembly ∷ Session → WindowConfig → Assembly Window
windowAssembly session config = do
  request ←
    restoredStep $
      either (throwFailure glfwComponent createWindowOperation titled) pure (validRequest config)
  local ←
    restoredStep $ ownerOperation session createWindowOperation titled $ do
      requireUnpoisoned session createWindowOperation titled
      nextWindowIdentity session
  let identity = WindowId (sessionIdentity session) local
      identifiers = windowIdentifiers identity
  live ← restoredStep (newIORef True)
  captures ← restoredStep (newIORef noCaptures)
  control ← restoredStep (newIORef (ControlState (ConstraintsKnown Nothing) False))
  certain ← restoredStep (newIORef True)
  failed ← restoredStep (newIORef False)
  storage ←
    acquirePart
      "glfw window callback storage"
      (releaseRank 2)
      (nativeNewWindowCallbacks native (windowCallbacks (sessionWindowCapabilities session) captures))
      (noteFailure failed . freeStorage session certain)
  (handle, created) ←
    acquirePart
      "glfw window"
      (releaseRank 1)
      (createNative session request identifiers)
      (\(handle, _) → noteFailure failed (destroyNative session certain identifiers handle))
  restoredStep (raiseReported createWindowOperation identifiers NativeCallReturned created)
  -- The detach is registered before any callback is attached, so an
  -- attachment that reported an error, raised part-way, or was interrupted is
  -- detached before the window is destroyed.
  acquirePart
    "glfw window callbacks"
    (releaseRank 0)
    (pure ())
    (\() → noteFailure failed (detachCallbacks session live certain captures identifiers handle))
  restoredStep (attachCallbacks session certain identifiers handle storage)
  sample ← restoredStep (ownerOperation session sampleOperation identifiers (sampleAll session identifiers handle))
  pending ← restoredStep (takeCaptures captures)
  restoredStep (raiseFault identity pending)
  let (initial, issued) = reconciled identity (Just sample) pending (blankObservation identity sample) 0
  prepared ← restoredStep (prepare initial)
  ownerState ← restoredStep (newIORef (OwnerState initial issued))
  publisher ←
    acquirePart
      "glfw window observations"
      (releaseRank 3)
      (newSnapshot prepared)
      (closeObservations live certain failed ownerState)
  pure
    Window
      { windowSession = session
      , windowId = identity
      , windowHandle = handle
      , windowLive = live
      , windowCaptures = captures
      , windowOwnerState = ownerState
      , windowControl = control
      , windowPublisher = publisher
      }
  where
    native = sessionNative session
    titled = [("title", windowTitle config)]

blankObservation ∷ WindowId → Sample → WindowObservation
blankObservation identity sample =
  WindowObservation
    { obsWindow = identity
    , obsRevision = 0
    , obsPhase = WindowOpen
    , obsLogical = sampleLogical sample
    , obsFramebuffer = sampleFramebuffer sample
    , obsScale = sampleScale sample
    , obsPlacement = samplePlacement sample
    , obsFocused = sampleFocused sample
    , obsIconified = sampleIconified sample
    , obsMaximized = sampleMaximized sample
    , obsVisible = sampleVisible sample
    , obsCloseRequest = Nothing
    }

createNative ∷ Session → Request → [(Text, Text)] → IO (Ptr NativeWindow, Reports)
createNative session (Request title width height hints) identifiers = do
  settleStrayOwnerReports capture
  nativeResetWindowHints native
  mapM_ (nativeSetWindowHint native) hints
  handle ← nativeCreateWindow native width height title
  reports ← takeOwnerReports capture
  when (handle == nullPtr) $
    throwFailure glfwComponent createWindowOperation identifiers (NativeFailure NativeCallFailed reports)
  pure (handle, reports)
  where
    native = sessionNative session
    capture = sessionCapture session

attachCallbacks
  ∷ Session → IORef Bool → [(Text, Text)] → Ptr NativeWindow → WindowCallbackStorage → IO ()
attachCallbacks session certain identifiers handle storage = do
  settleStrayOwnerReports capture
  -- An attachment that raises may have registered some callbacks, so the
  -- storage is kept and the session poisoned.
  nativeAttachWindowCallbacks native handle storage `onException` atomicWriteIORef certain False
  reports ← takeOwnerReports capture
  raiseReported attachOperation identifiers NativeCallReturned reports
  where
    native = sessionNative session
    capture = sessionCapture session

-- | A release that makes a native call: only on the owner thread of a live
-- session. Anything else, or a native call that raises, leaves release
-- uncertain. When @uncertainOnReport@ holds, a call that returned but reported
-- an error leaves release uncertain too, because what it releases was not
-- established to have ended.
nativeRelease ∷ Session → IORef Bool → Bool → Operation → [(Text, Text)] → IO () → IO ()
nativeRelease session certain uncertainOnReport operationName identifiers release = do
  ownerOperation session operationName identifiers (pure ()) `onException` atomicWriteIORef certain False
  settleStrayOwnerReports capture
  release `onException` atomicWriteIORef certain False
  reports ← takeOwnerReports capture
  when (uncertainOnReport && hasReports reports) $ atomicWriteIORef certain False
  raiseReported operationName identifiers NativeCallReturned reports
  where
    capture = sessionCapture session

detachCallbacks
  ∷ Session → IORef Bool → IORef Bool → IORef Captures → [(Text, Text)] → Ptr NativeWindow → IO ()
detachCallbacks session live certain captures identifiers handle = do
  atomicWriteIORef live False
  -- A fault latched after the last boundary is taken before the detach, so
  -- neither a detach that raises nor one that reports an error can abandon it.
  pending ← takeCaptures captures
  detached ∷ Either (ExceptionWithContext SomeException) () ←
    tryWithContext $
      nativeRelease session certain False detachOperation identifiers $
        nativeDetachWindowCallbacks (sessionNative session) handle
  case (detached, capturedFault pending) of
    (Right (), Nothing) → pure ()
    (Right (), Just fault) → rethrowFault identifiers fault
    (Left failure, Nothing) → rethrowIO failure
    -- The detach's failure stays primary and the fault is retained beside it
    -- as a labelled cleanup failure, under the resource failure table.
    (Left failure, Just fault) →
      withResourceLabelled
        "glfw window callback fault"
        (pure ())
        (\() → rethrowFault identifiers fault)
        (\() → rethrowIO failure)

destroyNative ∷ Session → IORef Bool → [(Text, Text)] → Ptr NativeWindow → IO ()
destroyNative session certain identifiers handle =
  nativeRelease session certain True destroyWindowOperation identifiers $
    nativeDestroyWindow (sessionNative session) handle

-- | Record that a release part failed, for the terminal phase, and let the
-- failure continue on its path unchanged.
noteFailure ∷ IORef Bool → IO () → IO ()
noteFailure failed release = release `onException` atomicWriteIORef failed True

freeStorage ∷ Session → IORef Bool → WindowCallbackStorage → IO ()
freeStorage session certain storage = do
  safe ← readIORef certain
  if safe
    then nativeFreeWindowCallbacks (sessionNative session) storage
    else poisonSession session

closeObservations ∷ IORef Bool → IORef Bool → IORef Bool → IORef OwnerState → SnapshotPublisher WindowObservation → IO ()
closeObservations live certain failed ownerState publisher = do
  atomicWriteIORef live False
  safe ← readIORef certain
  failing ← readIORef failed
  OwnerState current issued ← readIORef ownerState
  let final =
        current
          { obsRevision = obsRevision current + 1
          , obsPhase = terminalPhase safe failing
          }
  prepared ← prepare final
  atomically (publish publisher prepared >> closeSnapshot publisher)
  writeIORef ownerState (OwnerState final issued)
  where
    terminalPhase safe failing
      | not safe = WindowReleaseUncertain
      | failing = WindowDisposalFailed
      | otherwise = WindowReleased

-- ---------------------------------------------------------------------------
-- Callbacks

-- | The contained callbacks recording into one window's capture latch. A
-- callback for an attribute the platform cannot report records nothing, so no
-- observation of it is fabricated.
windowCallbacks ∷ WindowCapabilities → IORef Captures → WindowCallbacks
windowCallbacks capabilities captures =
  WindowCallbacks
    { onWindowSize = \width height →
        reported LogicalExtentReport . contained "window size" $ do
          extent ← extentOf width height
          pure (\latched → latched {capturedSize = Just extent})
    , onFramebufferSize = \width height →
        reported FramebufferExtentReport . contained "framebuffer size" $ do
          extent ← extentOf width height
          pure (\latched → latched {capturedFramebuffer = Just extent})
    , onContentScale = \x y →
        reported ContentScaleReport . contained "content scale" $ do
          scale ← scaleOf x y
          pure (\latched → latched {capturedScale = Just scale})
    , onWindowPosition = \x y →
        reported PlacementReport . contained "window position" $ do
          placement ← placementOf x y
          pure (\latched → latched {capturedPlacement = Just placement})
    , onWindowFocus = \focused →
        reported FocusedReport . contained "window focus" $ do
          flag ← flagOf focused
          pure (\latched → latched {capturedFocused = Just flag})
    , onWindowIconify = \iconified →
        reported IconifiedReport . contained "window iconify" $ do
          flag ← flagOf iconified
          pure (\latched → latched {capturedIconified = Just flag})
    , onWindowMaximize = \maximized →
        reported MaximizedReport . contained "window maximize" $ do
          flag ← flagOf maximized
          pure (\latched → latched {capturedMaximized = Just flag})
    , onWindowRefresh =
        contained "window refresh" (pure (\latched → latched {capturedRefresh = True}))
    , onWindowClose =
        contained "window close" (pure (\latched → latched {capturedCloses = capturedCloses latched + 1}))
    }
  where
    reported report callback = when (reportable capabilities report) callback

    -- The trampoline. The payload is copied, and every field forced, inside
    -- the handler; the record is one non-blocking update. Anything raised is
    -- latched with its context rather than unwinding into C, and a failure to
    -- latch it is dropped for the same reason.
    contained ∷ Text → IO (Captures → Captures) → IO ()
    contained name capture = uninterruptibleMask_ $ do
      outcome ← tryWithContext capture
      case outcome of
        Right change → record change
        Left caught → do
          latched ← try (record (latchFault name caught))
          either (\(_ ∷ SomeException) → pure ()) pure latched

    record change =
      atomicModifyIORef' captures $ \latched →
        let changed = change latched
         in (changed {capturedGeneration = capturedGeneration latched + 1}, ())

    extentOf width height = Extent <$> evaluate (fromIntegral width) <*> evaluate (fromIntegral height)
    placementOf x y = Placement <$> evaluate (fromIntegral x) <*> evaluate (fromIntegral y)
    scaleOf x y = ContentScale <$> evaluate (realToFrac x) <*> evaluate (realToFrac y)
    flagOf ∷ CInt → IO Bool
    flagOf value = evaluate (value /= 0)

latchFault ∷ Text → ExceptionWithContext SomeException → Captures → Captures
latchFault name caught latched = case capturedFault latched of
  Nothing → latched {capturedFault = Just (CallbackFault name caught 0)}
  Just (CallbackFault first kept later) →
    latched {capturedFault = Just (CallbackFault first kept (later + 1))}

takeCaptures ∷ IORef Captures → IO Captures
takeCaptures captures =
  atomicModifyIORef' captures $ \latched →
    (noCaptures {capturedGeneration = capturedGeneration latched}, latched)

raiseFault ∷ WindowId → Captures → IO ()
raiseFault identity pending = mapM_ (rethrowFault (windowIdentifiers identity)) (capturedFault pending)

-- | Rethrow a latched callback fault with its own type and context. A
-- synchronous fault gains the callback operation's context; cancellation is
-- rethrown as it was.
rethrowFault ∷ [(Text, Text)] → CallbackFault → IO a
rethrowFault identifiers (CallbackFault name caught later) =
  withOperationContext
    glfwComponent
    windowCallbackOperation
    (identifiers <> [("callback", name), ("later-faults", Text.pack (show later))])
    (rethrowIO caught)

-- ---------------------------------------------------------------------------
-- Owner boundaries

-- | Sample every attribute, each query bracketed by the error capture. An
-- attribute the platform cannot report is 'Unavailable' without a query.
sampleAll ∷ Session → [(Text, Text)] → Ptr NativeWindow → IO Sample
sampleAll session identifiers handle =
  Sample
    <$> gated LogicalExtentReport (uncurry Extent <$> nativeWindowSize native handle)
    <*> gated FramebufferExtentReport (uncurry Extent <$> nativeFramebufferSize native handle)
    <*> gated ContentScaleReport (uncurry ContentScale <$> nativeContentScale native handle)
    <*> gated PlacementReport (uncurry Placement <$> nativeWindowPosition native handle)
    <*> gated FocusedReport (nativeWindowAttribute native handle FocusedAttribute)
    <*> gated IconifiedReport (nativeWindowAttribute native handle IconifiedAttribute)
    <*> gated MaximizedReport (nativeWindowAttribute native handle MaximizedAttribute)
    <*> gated VisibleReport (nativeWindowAttribute native handle VisibleAttribute)
  where
    native = sessionNative session
    capture = sessionCapture session
    gated ∷ WindowReport → IO a → IO (Attribute a)
    gated report query
      | reportable (sessionWindowCapabilities session) report = sampled query
      | otherwise = pure Unavailable
    sampled ∷ IO a → IO (Attribute a)
    sampled query = do
      settleStrayOwnerReports capture
      value ← query
      reports ← takeOwnerReports capture
      if not (hasReports reports)
        then Observed <$> evaluate value
        else
          if onlyUnavailable reports
            then pure Unavailable
            else throwFailure glfwComponent sampleOperation identifiers (NativeFailure NativeCallReturned reports)
    onlyUnavailable reports =
      reportsLost reports == 0
        && callbackFaults reports == 0
        && all ((== nativeFeatureUnavailable native) . nativeErrorCode) (reportedErrors reports)

-- | Fold captures, and then a sample if one was taken, into an observation.
-- Returns the observation with its revision unchanged, and the close counter.
reconciled ∷ WindowId → Maybe Sample → Captures → WindowObservation → Natural → (WindowObservation, Natural)
reconciled identity sample pending current issued =
  (sampledOver (captured current), issued')
  where
    closes = capturedCloses pending
    issued' = issued + closes
    captured observation =
      observation
        { obsLogical = maybe (obsLogical observation) Observed (capturedSize pending)
        , obsFramebuffer = maybe (obsFramebuffer observation) Observed (capturedFramebuffer pending)
        , obsScale = maybe (obsScale observation) Observed (capturedScale pending)
        , obsPlacement = maybe (obsPlacement observation) Observed (capturedPlacement pending)
        , obsFocused = maybe (obsFocused observation) Observed (capturedFocused pending)
        , obsIconified = maybe (obsIconified observation) Observed (capturedIconified pending)
        , obsMaximized = maybe (obsMaximized observation) Observed (capturedMaximized pending)
        , obsCloseRequest =
            if closes > 0 then Just (CloseRequest identity issued') else obsCloseRequest observation
        }
    sampledOver observation = case sample of
      Nothing → observation
      Just taken →
        observation
          { obsLogical = sampleLogical taken
          , obsFramebuffer = sampleFramebuffer taken
          , obsScale = sampleScale taken
          , obsPlacement = samplePlacement taken
          , obsFocused = sampleFocused taken
          , obsIconified = sampleIconified taken
          , obsMaximized = sampleMaximized taken
          , obsVisible = sampleVisible taken
          }

-- | Fold the latched captures, and a sample if one was taken, into the current
-- observation, and publish a new revision if anything changed or a refresh or
-- close request was captured.
--
-- Nothing is mutated until the commit. The captures are read, not taken, and
-- the next observation is computed and prepared. Only then, masked and with no
-- interruptible operation, are the captures cleared, the snapshot published,
-- and the owner state written, so a cancellation or a failure before the commit
-- leaves the captures latched and the snapshot and owner state as they were,
-- and nothing can land between the three writes. If a callback recorded
-- anything between the read and the commit, the fold starts again from the
-- newer captures. A latched fault stays latched for 'raiseLatchedFault'.
--
-- @interruption@ runs at the preparation point, after preparation and before
-- the commit. Production passes @pure ()@; the test seam uses it to deliver a
-- cancellation exactly there.
reconcileWindow ∷ IO () → Window → Maybe Sample → IO ()
reconcileWindow = reconcileWith False

-- | 'reconcileWindow', publishing a new revision even when nothing changed if
-- @forced@ holds.
reconcileWith ∷ Bool → IO () → Window → Maybe Sample → IO ()
reconcileWith forced interruption window sample = do
  pending ← readIORef (windowCaptures window)
  OwnerState current issued ← readIORef (windowOwnerState window)
  let (folded, issued') = reconciled (windowId window) sample pending current issued
      signalled = capturedRefresh pending || capturedCloses pending > 0
      next = folded {obsRevision = obsRevision current + 1}
  prepared ← if forced || folded /= current || signalled then Just <$> prepare next else pure Nothing
  interruption
  committed ← mask_ $ do
    cleared ← atomicModifyIORef' (windowCaptures window) $ \latched →
      if capturedGeneration latched == capturedGeneration pending
        then
          ( noCaptures
              { capturedGeneration = capturedGeneration latched
              , capturedFault = capturedFault latched
              }
          , True
          )
        else (latched, False)
    when cleared $ forM_ prepared (commitObservation window next issued')
    pure cleared
  unless committed (reconcileWith forced interruption window sample)

-- | Publish a prepared observation and record it as the owner's current one.
-- The caller must be masked: neither write is interruptible, so the two cannot
-- be separated.
commitObservation ∷ Window → WindowObservation → Natural → Prepared WindowObservation → IO ()
commitObservation window next issued prepared = do
  _ ← atomically (publish (windowPublisher window) prepared)
  writeIORef (windowOwnerState window) (OwnerState next issued)

-- | Take a latched callback fault and rethrow it, in one masked step, so a
-- cancellation cannot discard the fault between the take and the rethrow.
raiseLatchedFault ∷ Window → IO ()
raiseLatchedFault window = mask_ $ do
  fault ← atomicModifyIORef' (windowCaptures window) $ \latched →
    (latched {capturedFault = Nothing}, capturedFault latched)
  mapM_ (rethrowFault (windowIdentifiers (windowId window))) fault

-- | Run owner work at a boundary: answer 'WindowEnded' without a native call
-- once the window has ended, check the owner and liveness, run the work, then
-- reconcile the captures and rethrow any latched callback fault. If the work
-- raises, its failure propagates and the captures stay latched.
atBoundary ∷ IO () → Window → Operation → IO a → IO (WindowResult a)
atBoundary interruption window operationName work = do
  live ← readIORef (windowLive window)
  if not live
    then pure (WindowEnded (windowId window))
    else ownerOperation (windowSession window) operationName identifiers $ do
      value ← work
      reconcileWindow interruption window Nothing
      raiseLatchedFault window
      pure (WindowAvailable value)
  where
    identifiers = windowIdentifiers (windowId window)

-- | Sample the window at an owner boundary and publish what changed.
synchronizeWindow ∷ Window → IO (WindowResult WindowObservation)
synchronizeWindow window =
  atBoundary (pure ()) window synchronizeOperation $ do
    sample ← sampleAll (windowSession window) (windowIdentifiers (windowId window)) (windowHandle window)
    reconcileWindow (pure ()) window (Just sample)
    raiseLatchedFault window
    OwnerState current _ ← readIORef (windowOwnerState window)
    pure current

-- | Run one callback-producing native step at an owner boundary: the private
-- driver setters, polls, and tests use. Errors reported during the step fail
-- it; captures are reconciled after it returns.
windowStep ∷ Window → Operation → (Ptr NativeWindow → IO a) → IO (WindowResult a)
windowStep = windowStepWith (pure ())

-- | 'windowStep', running @interruption@ at the reconciliation's preparation
-- point, after preparation and before the commit.
windowStepWith ∷ IO () → Window → Operation → (Ptr NativeWindow → IO a) → IO (WindowResult a)
windowStepWith interruption window operationName step =
  atBoundary interruption window operationName $ do
    settleStrayOwnerReports capture
    value ← step (windowHandle window)
    reports ← takeOwnerReports capture
    raiseReported operationName (windowIdentifiers (windowId window)) NativeCallReturned reports
    pure value
  where
    capture = sessionCapture (windowSession window)

-- | Reject a close request: the private state transition an application close
-- policy will use. Pending captures are reconciled first, and the request is
-- cleared only if it is still the latest, so an older rejection never erases a
-- newer request. Answers whether it was cleared.
rejectCloseRequest ∷ Window → CloseRequest → IO (WindowResult Bool)
rejectCloseRequest window request =
  atBoundary (pure ()) window (operation "reject close request") $ do
    reconcileWindow (pure ()) window Nothing
    raiseLatchedFault window
    OwnerState current issued ← readIORef (windowOwnerState window)
    if obsCloseRequest current == Just request
      then do
        let next = current {obsRevision = obsRevision current + 1, obsCloseRequest = Nothing}
        prepared ← prepare next
        mask_ (commitObservation window next issued prepared)
        pure True
      else pure False

-- | Begin the window's close protocol: publish a revision whose phase is
-- 'WindowClosing' in the same transaction as the owner's @commit@, then
-- reconcile pending captures at the boundary.
--
-- The closing observation is prepared first, and @interruption@ runs after
-- that preparation; production passes @pure ()@, and the examples use it to
-- deliver a cancellation there. Until then nothing has changed. Then, masked and
-- with no interruptible operation, one transaction runs @commit@ and, only if it
-- answers 'True', publishes the closing observation, and the owner's current
-- observation is recorded. So the owner's record that closing began and the
-- published phase commit together or not at all. @commit@ must be finite and
-- must never retry.
--
-- Answers whether closing began: 'False', with nothing published and @commit@
-- not run, for a window that is not open, and 'False', with nothing published,
-- when @commit@ declines. The window stays live, and its callbacks attached,
-- until it is released.
beginWindowClosing ∷ IO () → STM Bool → Window → IO (WindowResult Bool)
beginWindowClosing interruption commit window =
  atBoundary (pure ()) window (operation "begin window closing") $ do
    OwnerState current issued ← readIORef (windowOwnerState window)
    if obsPhase current /= WindowOpen
      then pure False
      else do
        let next = current {obsRevision = obsRevision current + 1, obsPhase = WindowClosing}
        prepared ← prepare next
        interruption
        mask_ $ do
          committed ← atomically $ do
            proceed ← commit
            when proceed (void (publish (windowPublisher window) prepared))
            pure proceed
          when committed (writeIORef (windowOwnerState window) (OwnerState next issued))
          pure committed

-- ---------------------------------------------------------------------------
-- Ordinary controls

controlWindowOperation ∷ Operation
controlWindowOperation = operation "control window"

-- | Execute one ordinary control at an owner boundary, under the module's
-- ordinary control contract. An ended window answers 'WindowEnded' without a
-- native call. A callback fault rethrown at the boundary, and a native call that
-- raises instead of returning, propagate.
controlWindow ∷ Window → WindowControl → IO (WindowResult ControlResult)
controlWindow window control =
  atBoundary (pure ()) window controlWindowOperation $ do
    reconcileWindow (pure ()) window Nothing
    raiseLatchedFault window
    OwnerState current _ ← readIORef (windowOwnerState window)
    ControlState constraints transition ← readIORef (windowControl window)
    decide current constraints transition
  where
    wanted = controlOperation control
    decide current constraints transition
      | obsPhase current /= WindowOpen = pure ControlWindowClosing
      | transition = pure (ControlRefused ModeTransitionInProgress)
      | Just reason ← operationGap (sessionWindowCapabilities (windowSession window)) wanted =
          pure (ControlUnsupported wanted reason)
      | Left rejected ← validateControl constraints (obsLogical current) control =
          pure (ControlRefused rejected)
      | otherwise = do
          outcome ← applyControl window control
          ControlAttempted outcome <$> postCallObservation window

-- | Make a validated control's native calls.
applyControl ∷ Window → WindowControl → IO ControlOutcome
applyControl window control = case control of
  TitleControl title → single (nativeSetWindowTitle native handle title)
  SizeControl width height → single (nativeSetWindowSize native handle (fromIntegral width) (fromIntegral height))
  PositionControl x y → single (nativeSetWindowPosition native handle (fromIntegral x) (fromIntegral y))
  ConstraintsControl constraints → applyConstraints window constraints
  ShowControl → single (nativeShowWindow native handle)
  HideControl → single (nativeHideWindow native handle)
  FocusControl → single (nativeFocusWindow native handle)
  AttentionControl → single (nativeRequestWindowAttention native handle)
  MinimizeControl → single (nativeIconifyWindow native handle)
  MaximizeControl → single (nativeMaximizeWindow native handle)
  RestoreControl → single (nativeRestoreWindow native handle)
  where
    native = sessionNative (windowSession window)
    handle = windowHandle window
    single call = do
      reports ← reportsDuring (windowSession window) call
      pure $
        if hasReports reports
          then ControlNativeError (controlOperationText (controlOperation control)) reports
          else ControlReturned

-- | Apply a validated constraint set in 'constraintCallOrder', stopping at the
-- first call that reports an error. The constraint state is indeterminate from
-- before the first call until every call has returned without a report.
applyConstraints ∷ Window → SizeConstraints → IO ControlOutcome
applyConstraints window constraints = do
  setConstraintState window ConstraintsIndeterminate
  apply [] constraintCallOrder
  where
    native = sessionNative (windowSession window)
    handle = windowHandle window
    apply _ [] = ControlReturned <$ setConstraintState window (ConstraintsKnown (Just constraints))
    apply returned (call : rest) = do
      reports ← reportsDuring (windowSession window) (nativeCall call)
      if hasReports reports
        then pure (ConstraintUpdateFailed (reverse returned) call rest reports)
        else apply (call : returned) rest
    nativeCall SizeLimitsCall =
      nativeSetWindowSizeLimits
        native
        handle
        (fromIntegral (extentWidth (constraintMinimum constraints)))
        (fromIntegral (extentHeight (constraintMinimum constraints)))
        (fromIntegral (extentWidth (constraintMaximum constraints)))
        (fromIntegral (extentHeight (constraintMaximum constraints)))
    nativeCall AspectRatioCall =
      nativeSetWindowAspectRatio native handle $
        (\(AspectRatio numerator denominator) → (fromIntegral numerator, fromIntegral denominator))
          <$> constraintAspectRatio constraints

setConstraintState ∷ Window → ConstraintState → IO ()
setConstraintState window state =
  atomicModifyIORef' (windowControl window) (\(ControlState _ transition) → (ControlState state transition, ()))

-- | The reports made on the owner thread during one native call.
reportsDuring ∷ Session → IO () → IO Reports
reportsDuring session call = do
  settleStrayOwnerReports capture
  call
  takeOwnerReports capture
  where
    capture = sessionCapture session

-- | Sample the window after an attempted control and publish a new revision,
-- answering it. A sample that reports errors publishes nothing and is answered
-- as data; a callback fault rethrown at the boundary propagates.
postCallObservation ∷ Window → IO PostCallObservation
postCallObservation window =
  tryWithContext (sampleAll (windowSession window) (windowIdentifiers (windowId window)) (windowHandle window)) >>= \case
    Left (ExceptionWithContext _ failure) →
      pure (PostCallSampleFailed (nativeOutcome failure) (nativeReports failure))
    Right sample → do
      reconcileWith True (pure ()) window (Just sample)
      raiseLatchedFault window
      OwnerState current _ ← readIORef (windowOwnerState window)
      pure (PostCallRevision (obsRevision current))

-- | Set or clear the window's mode transition marker: the private, owner-internal
-- state ordinary controls are refused under while it is set. No public command
-- sets it; a mode transition is its only intended producer.
setModeTransition ∷ Window → Bool → IO ()
setModeTransition window transition =
  atomicModifyIORef' (windowControl window) (\(ControlState constraints _) → (ControlState constraints transition, ()))

-- | How an owner turn processes native events.
data EventProcessing
  = ProcessPending
    -- ^ Process the events already pending, without waiting.
  | AwaitEventsFor !Double
    -- ^ Wait at most this many seconds for an event, then process every
    -- pending event.
  deriving (Eq, Show)

processEventsOperation, reconcileEventsOperation ∷ Operation
processEventsOperation = operation "process window events"
reconcileEventsOperation = operation "reconcile window events"

-- | Process native events once on the owner thread: the one event pump the
-- private owner turn uses.
--
-- The owner and liveness are checked first. Callbacks GLFW makes inside the call
-- only record into their windows' capture latches, so nothing is reconciled
-- here: each window's captures are reconciled at its next owner boundary, such
-- as 'reconcileWindowEvents'. An error reported on the owner thread during the
-- call fails it with 'NativeFailure', attributed to @process window events@.
processWindowEvents ∷ Session → EventProcessing → IO ()
processWindowEvents session processing =
  ownerOperation session processEventsOperation identifiers $ do
    settleStrayOwnerReports capture
    case processing of
      ProcessPending → nativePollEvents native
      AwaitEventsFor seconds → nativeWaitEventsTimeout native seconds
    reports ← takeOwnerReports capture
    raiseReported processEventsOperation identifiers NativeCallReturned reports
  where
    native = sessionNative session
    capture = sessionCapture session
    identifiers = case processing of
      ProcessPending → [("events", "poll")]
      AwaitEventsFor seconds → [("events", "wait"), ("seconds", Text.pack (show seconds))]

-- | Reconcile what a window's callbacks captured since its last boundary,
-- publishing a new revision if anything changed, and rethrow a latched callback
-- fault: an owner boundary with no native step of its own. An ended window
-- answers 'WindowEnded'.
reconcileWindowEvents ∷ Window → IO (WindowResult ())
reconcileWindowEvents window = atBoundary (pure ()) window reconcileEventsOperation (pure ())

-- | The native window, for the private drivers in this package only.
windowNativeHandle ∷ Window → Ptr NativeWindow
windowNativeHandle = windowHandle
