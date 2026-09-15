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
-- maximize, refresh, close, key, character, mouse button, cursor position,
-- cursor enter and leave, and scroll callbacks are contained at the trampoline.
-- Each runs uninterruptibly, copies its fixed payload, records it into the
-- window's capture latch with one non-blocking 'IORef' update, and returns.
-- None calls application code, waits, polls, logs, or destroys anything.
-- Anything a callback raises is caught there with its context and latched
-- instead of unwinding into C; only the first is kept, and later ones are
-- counted. The focus callback is the one owner of focus: it coalesces the
-- latest flag into the observation and stages an ordered focus event for the
-- input feed. There is no second focus callback.
--
-- Captures are reconciled on the owner thread at an owner boundary: after the
-- initial sampling, and after any owner operation's native calls return,
-- whether they were a setter or a poll. Geometry, attribute, and cursor
-- captures coalesce to their latest values, so a snapshot preserves no event
-- history. Ordered input — key, character, button, scroll, and focus
-- transitions — is staged in a bounded buffer of 'inputStagingCapacity' events
-- and is never coalesced. Cursor position is not an input event: it coalesces
-- into the observation and updates the feed's cursor sample, so a later button
-- still carries the coordinates copied when that button callback ran. A
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
-- Staging overflow sets a loss latch that remains set while the buffer is
-- full. At the next owner boundary the latch is checked before any staged
-- event is published: the ambiguous batch is discarded, none of its prefix is
-- replayed, and the window's input feed begins the same overflow reset a full
-- channel would. Close intent and the observation keep updating. One window's
-- loss leaves every other window's feed and commands usable. A feed is
-- attached with 'attachWindowInputFeed' after construction; until then staged
-- input is discarded at the boundary that would have published it, without a
-- reset.
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
-- 4. an operation the window's applied presentation does not admit is refused,
--    under "Hetoimasia.GLFW.Internal.Control"'s eligibility rules;
-- 5. an operation the session's 'WindowCapabilities' names as unperformable
--    settles as unsupported, with its reason;
-- 6. the control is validated against the window's effective constraint state
--    and latest observed logical size, under "Hetoimasia.GLFW.Internal.Control"'s
--    rules.
--
-- Then the native calls are made, each bracketed by the error capture so its
-- reports belong to this control alone, and afterwards every attribute is
-- sampled and a new revision is published even if nothing changed, so the
-- revision the result names was produced by a sample taken after the call. It
-- promises nothing about the window manager's convergence. A control changes no
-- mode and never changes the window's mode transition marker.
--
-- A constraint update marks the window's preserved windowed constraints
-- indeterminate before its first call and known only after every call returned
-- without a report. A size is validated against those constraints only while
-- the native constraints follow them; while a transition has suspended them, or
-- a suspension or restoration stopped part-way, sizes are refused as
-- indeterminate.
--
-- = Window modes
--
-- 'transitionWindow' executes a mode request at an owner boundary under
-- "Hetoimasia.GLFW.Internal.Mode"'s contract. In order: pending captures are
-- reconciled; a closing window attempts nothing; a window whose mode transition
-- marker is set refuses with 'TransitionAlreadyInProgress'; the request is
-- validated; the marker is set, and stays set until the transition settles; the
-- monitor inventory is refreshed, so no decision uses monitors a disconnection
-- has since ended; the window is sampled, and its applied mode and monitor
-- claims are reconciled with that sample; an inert request settles at once; otherwise the target is
-- attempted under "Hetoimasia.Foundation.Recovery"'s 'recover', whose budget is
-- one attempt plus the request's fallback attempts, or those fallback attempts
-- alone when reconciliation starts from the fallback. Each attempt is one complete
-- owned operation. It validates and plans before any native call, reserves a
-- fullscreen monitor last, makes its steps — each bracketed by the error capture,
-- stopping at the first that reports — and samples, reconciles, and publishes
-- before it returns or fails. Its cleanup restores the preserved windowed
-- constraints of a window the attempt left windowed with its native constraints
-- suspended or indeterminate; a cleanup that reports an error stops recovery. The
-- transition settles after one more sample, whose revision it names, with the
-- request and its outcome recorded. A request refused before any native call,
-- with no fallback to take or as 'MonitorBusy', which no fallback answers,
-- records nothing. A cleanup that raises instead of reporting, or a cleanup
-- failure beside a primary failure that is not a mode attempt's, propagates.
--
-- Every full sample — a synchronization, a control's post-call sample, and a
-- transition's samples — derives the applied mode and settles the window's
-- monitor claims before it publishes. A callback-only fold that changes the
-- placement of a window applied borderless re-derives which monitor's work area
-- it is over, from its latest sampled decoration and fullscreen monitor, so a
-- window manager that places it later is reflected without another sample.
--
-- An attempt's constraint cleanup runs only when that attempt made a native step
-- itself, so an attempt refused before any native call makes none.
--
-- An attempt interrupted by anything other than its own failure — a native call
-- that raises, a callback fault, or cancellation — settles before the exception
-- continues: a fullscreen reservation it made before any native step is released
-- as proven unused, and after a native step every claim of the window becomes
-- uncertain and its applied mode indeterminate in the owner's state, so the
-- owner loop's mode reconciliation resamples it and releases what the sample
-- proves unused. The protection that settles an attempt is established before
-- the attempt plans, and a reservation is committed and recorded for it in one
-- masked step, so a cancellation at any point after the reservation, including
-- before the first native step, releases it.
--
-- The transition interval is that execution, from setting the marker to the
-- settlement, on the owner thread. Nothing else executes a command inside it: the
-- owner executes one command at a time, and callbacks only record. The marker
-- therefore guards owner work re-entered from inside a native step, which the CPU
-- examples drive from a scripted step: an ordinary control there is refused with
-- 'ModeTransitionInProgress', another mode request with
-- 'TransitionAlreadyInProgress', and other windows are unaffected.
--
-- Every sample queries the window's decoration and fullscreen monitor beside its
-- other attributes, and the monitor pointer is compared with the inventory's
-- current connections without a refresh. 'reconcileWindowMode' is the owner
-- loop's step after its monitor refresh: a window whose applied mode names an
-- ended monitor identity takes its recorded windowed fallback without another
-- command, or is resampled when it has none; a window whose applied mode is
-- indeterminate is resampled.
--
-- A 'WindowConfig' may carry a startup mode, transitioned during creation after
-- the initial observation seeded the saved placement. A required startup mode
-- that fails fails creation, which rolls back; an optional one leaves the window
-- in whatever presentation it reached, with its outcome recorded — a refusal or an
-- unsupported target included, recorded as a failed target attempt.
--
-- A window's release drops its monitor claims when disposal succeeded, and
-- makes them uncertain otherwise.
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
  , observedDecorated
  , observedFullscreenMonitor
  , observedMode
  , observedCursorPosition
  , observedCursorInside
  , WindowPhase (..)
  , Attribute (..)
  , Extent (..)
  , ContentScale (..)
  , Placement (..)
  , CursorPosition (..)
  , CloseRequest
  , closeRequestWindow
  , closeRequestNumber

    -- * Ordinary controls
  , controlWindow
  , setModeTransition

    -- * Window modes
  , transitionWindow
  , transitionWindowWith
  , reconcileWindowMode

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
  , attachWindowInputFeed
  , windowInputFeed
  , inputStagingCapacity
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.DeepSeq (NFData (rnf))
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , bracket_
  , evaluate
  , fromException
  , mask
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
import Data.List (find)
import Data.Bits (testBit)
import Data.Char (chr)
import Data.Either (isRight)
import Data.Maybe (fromMaybe, isJust, mapMaybe)
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
import qualified Hetoimasia.Foundation.Recovery as Recovery
import Hetoimasia.Foundation.Resource
  ( Assembly
  , CleanupFailure
  , acquirePart
  , cleanupFailureException
  , cleanupFailuresInContext
  , releaseRank
  , restoredStep
  , withResourceLabelled
  )
import Hetoimasia.GLFW.Internal.Attribute (Attribute (..), ContentScale (..), CursorPosition (..), Extent (..), Placement (..))
import Hetoimasia.GLFW.Internal.Input
  ( ButtonAction (..)
  , ButtonEvent (..)
  , InputFeed
  , InputPayload (..)
  , KeyAction (..)
  , KeyEvent (..)
  , Modifiers (..)
  , ScrollEvent (..)
  , produceInput
  , recordCursor
  , resetFromStagingOverflow
  )
import Hetoimasia.GLFW.Internal.Control
  ( AspectRatio (..)
  , ConstraintCall (..)
  , ConstraintState (..)
  , ControlOutcome (..)
  , ControlRejection (..)
  , ControlResult (..)
  , PostCallObservation (..)
  , PresentationKind (..)
  , SizeConstraints
  , WindowCapabilities
  , WindowControl (..)
  , WindowOperation (..)
  , WindowReport (..)
  , constraintAspectRatio
  , constraintCallOrder
  , constraintMaximum
  , constraintMinimum
  , controlEligibility
  , controlOperation
  , controlOperationText
  , operationGap
  , reportable
  , validateControl
  )
import Hetoimasia.GLFW.Internal.Mode
  ( AppliedMode (..)
  , ModeAttemptFailure (..)
  , ModeAttemptKind (..)
  , ModeFailure (..)
  , ModeOutcome (..)
  , ModePlan (..)
  , ModeRecord
  , ModeRejection (..)
  , ModeRequest
  , ModeRequirement (..)
  , ModeResult (..)
  , ModeStep (..)
  , NativeConstraints (..)
  , StartupMode
  , appliedPresentation
  , borderlessPlacement
  , borderlessPlan
  , deriveApplied
  , effectiveConstraints
  , fallbackAttempts
  , fullscreenPlan
  , inertRequest
  , initialModeRecord
  , modeApplied
  , modeFallback
  , modeMonitor
  , modePresentation
  , modeRequest
  , modeRequested
  , modeSavedPlacement
  , modeVideoPreference
  , pruneClaims
  , recordApplied
  , recordSaved
  , recordSettled
  , requestedFallback
  , requestedMode
  , reserveClaim
  , savedPlacement
  , selectVideoMode
  , settleClaims
  , abandonClaims
  , disposeClaims
  , startupRequest
  , startupRequirement
  , validateRequest
  , windowedPlacement
  , windowedPlan
  )
import Hetoimasia.GLFW.Internal.Monitor (MonitorId, MonitorResult (..), NativeMonitor, inventoryMonitors, monitorIdentity)
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
  , currentSessionMonitors
  , destroyWindowOperation
  , glfwComponent
  , identifyWindowMonitor
  , liveMonitors
  , nextWindowIdentity
  , ownerOperation
  , poisonSession
  , raiseReported
  , refreshMonitors
  , requireUnpoisoned
  , resolveMonitorPointer
  , sessionCapture
  , sessionClaims
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
  , windowStartupMode ∷ !(Maybe StartupMode)
    -- ^ A mode the window transitions to during creation, after its initial
    -- observation seeded its saved placement.
  }
  deriving (Eq, Show)

instance NFData WindowConfig where
  rnf (WindowConfig title width height visible focused focusOnShow startup) =
    rnf title `seq` rnf width `seq` rnf height `seq` rnf visible `seq` rnf focused `seq` rnf focusOnShow `seq` rnf startup

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
    , windowStartupMode = Nothing
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
  , obsDecorated ∷ !(Attribute Bool)
  , obsMonitor ∷ !(Attribute (Maybe MonitorId))
  , obsMode ∷ !ModeRecord
  , obsCursor ∷ !(Maybe CursorPosition)
    -- ^ Latest cursor callback; 'Nothing' until one has run.
  , obsCursorInside ∷ !(Maybe Bool)
    -- ^ Latest enter/leave callback; 'Nothing' until one has run.
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
      `seq` rnf (obsDecorated observation)
      `seq` rnf (obsMonitor observation)
      `seq` rnf (obsMode observation)
      `seq` rnf (obsCursor observation)
      `seq` rnf (obsCursorInside observation)

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

-- | The decoration GLFW holds for the window, which it applies whenever the
-- window is not on a monitor.
observedDecorated ∷ WindowObservation → Attribute Bool
observedDecorated = obsDecorated

-- | The monitor GLFW reports a fullscreen window on: 'Observed' 'Nothing' for a
-- window on no monitor, and 'Unavailable' for a monitor no current identity
-- names.
observedFullscreenMonitor ∷ WindowObservation → Attribute (Maybe MonitorId)
observedFullscreenMonitor = obsMonitor

-- | The owner's mode record as of this observation: the requested mode, the
-- applied mode reconciled from what was sampled, the saved windowed placement,
-- and the last outcome.
observedMode ∷ WindowObservation → ModeRecord
observedMode = obsMode

-- | The latest cursor position a cursor callback recorded, if any. Cursor
-- motion coalesces: an observation keeps only the last sample, never a trail.
observedCursorPosition ∷ WindowObservation → Maybe CursorPosition
observedCursorPosition = obsCursor

-- | Whether the cursor is inside the content area, as the latest enter or leave
-- callback reported it, if any has.
observedCursorInside ∷ WindowObservation → Maybe Bool
observedCursorInside = obsCursorInside

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
  , windowFeed ∷ !(IORef (Maybe InputFeed))
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
  , sampleDecorated ∷ !(Attribute Bool)
  , sampleMonitor ∷ !(Attribute (Maybe MonitorId))
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
  feed ← restoredStep (newIORef Nothing)
  control ← restoredStep (newIORef (ControlState (ConstraintsKnown Nothing) NativeFollowsWindowed False))
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
  monitors ← restoredStep (currentSessionMonitors session)
  let seeded = case (samplePlacement sample, sampleLogical sample) of
        (Observed position, Observed extent) → Just (savedPlacement position extent)
        _ → Nothing
      record = initialModeRecord (deriveApplied monitors (sampleMonitor sample) (sampleDecorated sample) (samplePlacement sample)) seeded
      (initial, issued) = reconciled identity (Just sample) pending (blankObservation identity sample record) 0
  prepared ← restoredStep (prepare initial)
  ownerState ← restoredStep (newIORef (OwnerState initial issued))
  publisher ←
    acquirePart
      "glfw window observations"
      (releaseRank 3)
      (newSnapshot prepared)
      (closeObservations session local live certain failed ownerState)
  let window =
        Window
          { windowSession = session
          , windowId = identity
          , windowHandle = handle
          , windowLive = live
          , windowCaptures = captures
          , windowOwnerState = ownerState
          , windowControl = control
          , windowPublisher = publisher
          , windowFeed = feed
          }
  forM_ (windowStartupMode config) (restoredStep . startWindowMode window)
  pure window
  where
    native = sessionNative session
    titled = [("title", windowTitle config)]

blankObservation ∷ WindowId → Sample → ModeRecord → WindowObservation
blankObservation identity sample record =
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
    , obsDecorated = sampleDecorated sample
    , obsMonitor = sampleMonitor sample
    , obsMode = record
    , obsCursor = Nothing
    , obsCursorInside = Nothing
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

closeObservations
  ∷ Session → Natural → IORef Bool → IORef Bool → IORef Bool → IORef OwnerState → SnapshotPublisher WindowObservation → IO ()
closeObservations session local live certain failed ownerState publisher = do
  atomicWriteIORef live False
  safe ← readIORef certain
  failing ← readIORef failed
  atomicModifyIORef' (sessionClaims session) (\claims → (disposeClaims local (safe && not failing) claims, ()))
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
          pure (\latched → stageInput (StagedFocus flag) (latched {capturedFocused = Just flag}))
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
    , onKey = \key scancode action mods →
        contained "window key" $ do
          decoded ← KeyEvent <$> evaluate (fromIntegral key) <*> evaluate (fromIntegral scancode) <*> keyActionOf action <*> modifiersOf mods
          pure (stageInput (StagedKey decoded))
    , onChar = \codepoint →
        contained "window character" $ do
          decoded ← charOf codepoint
          pure (stageInput (StagedChar decoded))
    , onMouseButton = \button action mods →
        contained "window mouse button" $ do
          decodedAction ← buttonActionOf action
          decodedMods ← modifiersOf mods
          decodedButton ← evaluate (fromIntegral button)
          pure $ \latched →
            stageInput
              (StagedButton (ButtonEvent decodedButton decodedAction (capturedCursor latched) decodedMods))
              latched
    , onCursorPos = \x y →
        contained "window cursor position" $ do
          position ← CursorPosition <$> evaluate (realToFrac x) <*> evaluate (realToFrac y)
          pure (\latched → latched {capturedCursor = Just position})
    , onCursorEnter = \entered →
        contained "window cursor enter" $ do
          flag ← flagOf entered
          pure (\latched → latched {capturedCursorInside = Just flag})
    , onScroll = \x y →
        contained "window scroll" $ do
          decoded ← ScrollEvent <$> evaluate (realToFrac x) <*> evaluate (realToFrac y)
          pure (stageInput (StagedScroll decoded))
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
    -- GLFW_RELEASE, GLFW_PRESS, GLFW_REPEAT.
    keyActionOf code = case fromIntegral code ∷ Int of
      0 → pure KeyReleased
      1 → pure KeyPressed
      2 → pure KeyRepeated
      _ → ioError (userError "unknown key action")
    buttonActionOf code = case fromIntegral code ∷ Int of
      0 → pure ButtonReleased
      1 → pure ButtonPressed
      _ → ioError (userError "unknown button action")
    modifiersOf bits = do
      let value = fromIntegral bits ∷ Int
      evaluate
        Modifiers
          { modifierShift = testBit value 0
          , modifierControl = testBit value 1
          , modifierAlt = testBit value 2
          , modifierSuper = testBit value 3
          , modifierCapsLock = testBit value 4
          , modifierNumLock = testBit value 5
          }
    charOf codepoint = do
      let code = fromIntegral codepoint ∷ Int
      evaluate (chr code)

-- | Stage one ordered event, or set the loss latch when the buffer is full.
-- Later events while the latch is set are counted and not stored.
stageInput ∷ StagedInput → Captures → Captures
stageInput event latched
  | capturedInputLoss latched = countLost latched
  | capturedInputCount latched >= inputStagingCapacity = countLost (latched {capturedInputLoss = True})
  | otherwise =
      latched
        { capturedInput = event : capturedInput latched
        , capturedInputCount = capturedInputCount latched + 1
        }
  where
    countLost captures = captures {capturedInputLost = capturedInputLost captures + 1}

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
    <*> sampled (nativeWindowAttribute native handle DecoratedAttribute)
    <*> (sampled (nativeWindowMonitor native handle) >>= identified)
  where
    identified ∷ Attribute (Ptr NativeMonitor) → IO (Attribute (Maybe MonitorId))
    identified = \case
      Observed pointer → identifyWindowMonitor session pointer
      Unavailable → pure Unavailable
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
        , obsCursor = maybe (obsCursor observation) Just (capturedCursor pending)
        , obsCursorInside = maybe (obsCursorInside observation) Just (capturedCursorInside pending)
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
          , obsDecorated = sampleDecorated taken
          , obsMonitor = sampleMonitor taken
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
reconcileWith forced = reconcileAdjusted forced id

-- | 'reconcileWith', applying @adjust@ to the folded observation before it is
-- compared and prepared: how a transition publishes its mode record beside the
-- sample it was reconciled with.
reconcileAdjusted ∷ Bool → (WindowObservation → WindowObservation) → IO () → Window → Maybe Sample → IO ()
reconcileAdjusted forced adjust interruption window sample = do
  pending ← readIORef (windowCaptures window)
  derived ← case sample of
    Just taken → presentationFrom window taken
    Nothing
      | isJust (capturedPlacement pending) → borderlessFrom window
      | otherwise → pure id
  OwnerState current issued ← readIORef (windowOwnerState window)
  let (reconciledObservation, issued') = reconciled (windowId window) sample pending current issued
      folded = adjust (derived reconciledObservation)
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
              , capturedCursor = capturedCursor latched
              , capturedCursorInside = capturedCursorInside latched
              }
          , True
          )
        else (latched, False)
    when cleared $ do
      forM_ prepared (commitObservation window next issued')
      -- Publication is bounded STM and evaluation. It stays uninterruptible
      -- so a cancellation cannot admit a prefix and drop the rest.
      uninterruptibleMask_ (publishCapturedInput window pending)
    interruption
    pure cleared
  unless committed (reconcileAdjusted forced adjust interruption window sample)

-- | Settle a window's monitor claims with a full sample, and answer how its
-- applied mode changes: derived from the sample against the current monitors.
presentationFrom ∷ Window → Sample → IO (WindowObservation → WindowObservation)
presentationFrom window taken = do
  monitors ← currentSessionMonitors session
  live ← liveMonitors session
  atomicModifyIORef' (sessionClaims session) $ \claims →
    (settleClaims (windowLocalIdentity (windowId window)) (sampleMonitor taken) (pruneClaims live claims), ())
  let applied = deriveApplied monitors (sampleMonitor taken) (sampleDecorated taken) (samplePlacement taken)
  pure (\observation → observation {obsMode = recordApplied applied (obsMode observation)})
  where
    session = windowSession window

-- | How a callback-only fold changes a borderless window's applied mode: its
-- monitor is re-derived from the folded placement, with the decoration and
-- fullscreen monitor of its latest sample. Any other applied mode depends on no
-- placement, and is left alone.
borderlessFrom ∷ Window → IO (WindowObservation → WindowObservation)
borderlessFrom window = do
  monitors ← currentSessionMonitors (windowSession window)
  pure $ \observation → case modeApplied (obsMode observation) of
   AppliedBorderless _ →
     let applied = deriveApplied monitors (obsMonitor observation) (obsDecorated observation) (obsPlacement observation)
      in observation {obsMode = recordApplied applied (obsMode observation)}
   _ → observation

-- | Publish a prepared observation and record it as the owner's current one.
-- The caller must be masked: neither write is interruptible, so the two cannot
-- be separated.
commitObservation ∷ Window → WindowObservation → Natural → Prepared WindowObservation → IO ()
commitObservation window next issued prepared = do
  _ ← atomically (publish (windowPublisher window) prepared)
  writeIORef (windowOwnerState window) (OwnerState next issued)

-- | Publish staged input into the attached feed, if any. Loss is checked
-- before any captured prefix is admitted: a latched overflow discards the
-- batch and starts the same reset a full channel would. Cursor samples update
-- the feed even when the batch is discarded, so a later button still has a
-- position after resumption.
publishCapturedInput ∷ Window → Captures → IO ()
publishCapturedInput window pending = do
  feed ← readIORef (windowFeed window)
  forM_ feed $ \attached → do
    forM_ (capturedCursor pending) (recordCursor attached)
    if capturedInputLoss pending
      then do
        let lost = capturedInputLost pending + fromIntegral (capturedInputCount pending)
        void (resetFromStagingOverflow attached lost (capturedFocused pending))
      else mapM_ (admitStaged attached) (reverse (capturedInput pending))
  where
    admitStaged feed = \case
      StagedKey event → void (produceInput feed (KeyInput event))
      StagedChar character → void (produceInput feed (TextInput character))
      StagedButton event → void (produceInput feed (ButtonInput event))
      StagedScroll event → void (produceInput feed (ScrollInput event))
      StagedFocus focused → void (produceInput feed (FocusInput focused))

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
   ControlState windowed native transition ← readIORef (windowControl window)
   decide current (effectiveConstraints native windowed) transition
  where
   wanted = controlOperation control
   decide current constraints transition
     | obsPhase current /= WindowOpen = pure ControlWindowClosing
     | transition = pure (ControlRefused ModeTransitionInProgress)
     | Left rejected ← controlEligibility (appliedPresentation (modeApplied (obsMode current))) wanted =
         pure (ControlRefused rejected)
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

-- | Record the preserved windowed constraints an ordinary update established,
-- which the native constraints then follow.
setConstraintState ∷ Window → ConstraintState → IO ()
setConstraintState window state =
  atomicModifyIORef' (windowControl window) (\current → (current {stateWindowed = state, stateNative = NativeFollowsWindowed}, ()))

setNativeConstraints ∷ Window → NativeConstraints → IO ()
setNativeConstraints window native =
  atomicModifyIORef' (windowControl window) (\current → (current {stateNative = native}, ()))

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
-- state ordinary controls and other transitions are refused under while it is
-- set. A transition sets it for its interval, and the seam's private driver
-- sets it in the CPU examples; no public command does.
setModeTransition ∷ Window → Bool → IO ()
setModeTransition window transition =
  atomicModifyIORef' (windowControl window) (\current → (current {stateTransition = transition}, ()))

-- ---------------------------------------------------------------------------
-- Window modes

transitionOperation, windowedFallbackOperation, reconcileModeOperation, restoreConstraintsOperation ∷ Operation
transitionOperation = operation "transition window mode"
windowedFallbackOperation = operation "fall back to windowed mode"
reconcileModeOperation = operation "reconcile window mode"
restoreConstraintsOperation = operation "restore window constraints"

-- | Execute an optional mode request at an owner boundary, under the module's
-- window mode contract. An ended window answers 'WindowEnded' without a native
-- call. A callback fault rethrown at a boundary, a native call that raises
-- instead of returning, a native failure a monitor refresh raises, and
-- cancellation propagate.
transitionWindow ∷ Window → ModeRequest → IO (WindowResult ModeResult)
transitionWindow = transitionWindowWith (pure ())

-- | 'transitionWindow', running @afterReservation@ immediately after a fullscreen
-- attempt has committed its monitor reservation, before its first native step.
-- Production passes @pure ()@; the CPU examples deliver a cancellation there.
transitionWindowWith ∷ IO () → Window → ModeRequest → IO (WindowResult ModeResult)
transitionWindowWith afterReservation window = transitionAt afterReservation window ModeOptional

transitionAt ∷ IO () → Window → ModeRequirement → ModeRequest → IO (WindowResult ModeResult)
transitionAt afterReservation window requirement request =
  atBoundary (pure ()) window transitionOperation $ do
   reconcileWindow (pure ()) window Nothing
   raiseLatchedFault window
   OwnerState current _ ← readIORef (windowOwnerState window)
   ControlState _ _ transition ← readIORef (windowControl window)
   decide current transition
  where
   decide current transition
     | obsPhase current /= WindowOpen = pure ModeWindowClosing
     | transition = pure (ModeRefused TransitionAlreadyInProgress)
     | Left rejected ← validateRequest request = case requirement of
         ModeRequired →
           throwFailure
             glfwComponent
             transitionOperation
             (windowIdentifiers (windowId window))
             (ModeAttemptFailure TargetAttempt (RefusedBeforeMutation rejected))
         ModeOptional → pure (ModeRefused rejected)
     | otherwise = runTransition afterReservation window requirement request TargetAttempt

-- | Run a validated request, with the marker set, starting from the given
-- attempt.
runTransition ∷ IO () → Window → ModeRequirement → ModeRequest → ModeAttemptKind → IO ModeResult
runTransition afterReservation window requirement request first =
  bracket_ (setModeTransition window True) (setModeTransition window False) $ do
   _ ← refreshMonitors (windowSession window)
   _ ← samplePresentation False window id
   OwnerState current _ ← readIORef (windowOwnerState window)
   ControlState _ native _ ← readIORef (windowControl window)
   monitors ← currentSessionMonitors (windowSession window)
   let inert =
         first == TargetAttempt
           && inertRequest (obsMode current) native monitors (obsPlacement current) (obsLogical current) (requestedMode request)
   outcome ← if inert then pure ModeInert else recovering afterReservation window requirement request first
   case outcome of
     ModeFailed [ModeAttemptFailure TargetAttempt (RefusedBeforeMutation rejection)]
       | withoutFallback || refusedOutright rejection → pure (ModeRefused rejection)
     ModeFailed [ModeAttemptFailure TargetAttempt (UnsupportedTarget reason)]
       | withoutFallback → pure (ModeUnsupported reason)
     _ → ModeSettled outcome <$> samplePresentation True window (recordSettled request outcome)
  where
   withoutFallback = fallbackAttempts (requestedFallback request) == 0

-- | Attempt the request under the recovery boundary, turning its result into an
-- outcome. Cancellation, and anything a required request does not recover,
-- propagates.
recovering ∷ IO () → Window → ModeRequirement → ModeRequest → ModeAttemptKind → IO ModeOutcome
recovering afterReservation window requirement request first = do
  recovered ∷ Either (ExceptionWithContext SomeException) (Recovery.Outcome (ModeAttemptKind, [ModeStep])) ←
   tryWithContext (Recovery.recover transitionOperation policy (modeAttempt afterReservation window request first))
  case recovered of
   Right (Recovery.Available available) →
     let (kind, steps) = Recovery.recoveredValue available
      in pure (ModeApplied kind steps (attemptFailures (Recovery.recoveredFailures available)))
   Right (Recovery.Unavailable unavailable) →
     pure (ModeFailed (attemptFailures (Recovery.unavailableEarlier unavailable <> [Recovery.unavailableReason unavailable])))
   Left caught@(ExceptionWithContext context raised)
     | requirement == ModeOptional
     , Nothing ← (fromException raised ∷ Maybe SomeAsyncException)
     , Just latest ← fromException raised →
         case cleanupFailuresInContext context of
           [] → pure (ModeFailed (earlier context <> [latest]))
           cleanups
             | Just reports ← cleanupReports cleanups → pure (ModeRecoveryStopped (earlier context <> [latest]) reports)
             | otherwise → rethrowIO caught
     | otherwise → rethrowIO caught
  where
   fallback = requestedFallback request
   earlier context = concatMap (attemptFailures . Recovery.historyAttempts) (take 1 (Recovery.recoveryHistoryInContext context))
   policy =
     Recovery.RecoveryPolicy
       { Recovery.policyDisposition = case requirement of
           ModeRequired → Recovery.Required
           ModeOptional → Recovery.Optional
       , Recovery.policyBudget = case first of
           TargetAttempt → 1 + fallbackAttempts fallback
           WindowedFallbackAttempt → fallbackAttempts fallback
       , Recovery.policyClassifier = pure . classify
       , Recovery.policyWait = const (pure ())
       }
   classify attempted = case Recovery.attemptException attempted of
     ExceptionWithContext _ raised
       | fallbackAttempts fallback > 0
       , Just (ModeAttemptFailure _ how) ← fromException raised
       , recognized how →
           Just (Recovery.Fallback windowedFallbackOperation (modeAttempt afterReservation window request WindowedFallbackAttempt))
     _ → Nothing
   recognized = \case
     RefusedBeforeMutation rejection → not (refusedOutright rejection)
     UnsupportedTarget _ → True
     StoppedPartway {} → True

-- | A busy monitor and a transition already in progress are refusals, never
-- reasons to move the window, whatever fallback the request carries.
refusedOutright ∷ ModeRejection → Bool
refusedOutright = \case
  TransitionAlreadyInProgress → True
  MonitorBusy _ → True
  _ → False

attemptFailures ∷ [Recovery.AttemptFailure] → [ModeAttemptFailure]
attemptFailures = mapMaybe $ \attempted → case Recovery.attemptException attempted of
  ExceptionWithContext _ raised → fromException raised

-- | The reports of cleanup failures that are all native failures reported by a
-- returning call, combined; 'Nothing' when any is something else, which is not
-- representable as data.
cleanupReports ∷ [CleanupFailure] → Maybe Reports
cleanupReports cleanups = combined <$> traverse native cleanups
  where
   native cleanup = case cleanupFailureException cleanup of
     ExceptionWithContext _ raised → nativeReports <$> fromException raised
   combined reports =
     Reports (concatMap reportedErrors reports) (sum (map reportsLost reports)) (sum (map callbackFaults reports))

-- | One complete owned attempt: validate and plan, make the steps, and sample,
-- answering the steps or failing with a 'ModeAttemptFailure'. Its cleanup
-- restores the preserved windowed constraints of a window it left windowed
-- with them suspended.
modeAttempt ∷ IO () → Window → ModeRequest → ModeAttemptKind → IO (ModeAttemptKind, [ModeStep])
modeAttempt afterReservation window request kind =
  withResourceLabelled "glfw window constraint restoration" (newIORef False) (restoreLeftWindowed window) $ \disturbed → do
   reservation ← newIORef Nothing
   -- The protection that settles an interrupted attempt is in place before the
   -- attempt plans, and its handler runs masked.
   mask $ \restore → do
     attempted ∷ Either (ExceptionWithContext SomeException) (ModeAttemptKind, [ModeStep]) ←
       tryWithContext (restore (attemptBody disturbed reservation))
     case attempted of
       Right value → pure value
       Left caught@(ExceptionWithContext _ raised)
         | Just (_ ∷ ModeAttemptFailure) ← fromException raised → rethrowIO caught
         | otherwise → readIORef reservation >>= abandonAttempt window disturbed >> rethrowIO caught
  where
    attemptBody disturbed reservation = do
      OwnerState current _ ← readIORef (windowOwnerState window)
      ControlState windowed native _ ← readIORef (windowControl window)
      let record = obsMode current
          leaving = case (modeApplied record, obsPlacement current, obsLogical current) of
            (AppliedWindowed, Observed position, Observed extent)
              | target /= WindowedPresentation → Just (savedPlacement position extent)
            _ → Nothing
      (plan, pointer) ← case (target, modeMonitor mode, modeVideoPreference mode) of
        (BorderlessPresentation, Just monitor, _) → do
          unsupported BorderlessOperation
          inventory ← refreshMonitors session
          description ← maybe (refuse (ModeMonitorDisconnected monitor)) pure (described monitor (inventoryMonitors inventory))
          placement ← refused (borderlessPlacement description)
          plan ← refused (borderlessPlan native windowed placement)
          pure (plan, Nothing)
        (FullscreenPresentation, Just monitor, Just preference) → do
          unsupported FullscreenOperation
          -- A window whose windowed constraints are indeterminate could never be
          -- validly returned to windowed presentation, so it does not leave it.
          when (windowed == ConstraintsIndeterminate) (refuse WindowedConstraintsIndeterminate)
          resolveMonitorPointer session monitor >>= \case
            MonitorDisconnected _ → refuse (ModeMonitorDisconnected monitor)
            MonitorAvailable (description, resolved) → do
              (extent, refresh) ← refused (selectVideoMode preference description)
              live ← liveMonitors session
              -- The reservation and the handler's record of it commit together.
              reserved ← mask_ $ do
                committed ← atomicModifyIORef' (sessionClaims session) $ \claims →
                  case reserveClaim local monitor (pruneClaims live claims) of
                    Left busy → (claims, Left busy)
                    Right next → (next, Right ())
                when (isRight committed) (writeIORef reservation (Just monitor))
                pure committed
              either (refuse . MonitorBusy) pure reserved
              afterReservation
              pure (fullscreenPlan monitor extent refresh, Just resolved)
        _ → do
          inventory ← refreshMonitors session
          placement ← refused (windowedPlacement windowed (modeSavedPlacement record) (inventoryMonitors inventory))
          plan ← refused (windowedPlan native windowed placement)
          pure (plan, Nothing)
      runModeSteps window disturbed pointer plan >>= \case
        Right steps → (kind, steps) <$ samplePresentation True window (maybe id recordSaved leaving)
        Left failure → samplePresentation True window id >> failWith failure
    session = windowSession window
    local = windowLocalIdentity (windowId window)
    mode = requestedMode request
    target = case kind of
      WindowedFallbackAttempt → WindowedPresentation
      TargetAttempt → modePresentation mode
    failWith ∷ ModeFailure → IO a
    failWith how =
      throwFailure glfwComponent transitionOperation (windowIdentifiers (windowId window)) (ModeAttemptFailure kind how)
    refuse ∷ ModeRejection → IO a
    refuse = failWith . RefusedBeforeMutation
    refused ∷ Either ModeRejection b → IO b
    refused = either refuse pure
    unsupported wanted = mapM_ (failWith . UnsupportedTarget) (operationGap (sessionWindowCapabilities session) wanted)
    described monitor = \case
      Observed descriptions → find ((== monitor) . monitorIdentity) descriptions
      Unavailable → Nothing

-- | Settle an attempt interrupted by something other than its own failure: its
-- claims under 'abandonClaims', and, after a native step, an indeterminate
-- applied mode in the owner's state, which the next mode reconciliation resamples
-- and publishes.
abandonAttempt ∷ Window → IORef Bool → Maybe MonitorId → IO ()
abandonAttempt window disturbed reserved = do
  stepped ← readIORef disturbed
  atomicModifyIORef' (sessionClaims (windowSession window)) $ \claims →
    (abandonClaims (windowLocalIdentity (windowId window)) reserved stepped claims, ())
  when stepped $
    atomicModifyIORef' (windowOwnerState window) $ \(OwnerState current issued) →
      (OwnerState current {obsMode = recordApplied AppliedIndeterminate (obsMode current)} issued, ())

-- | Make a plan's steps in order, stopping at the first that reports an error.
-- The native constraint state is indeterminate from a constraint step's start
-- until every step has returned.
runModeSteps ∷ Window → IORef Bool → Maybe (Ptr NativeMonitor) → ModePlan → IO (Either ModeFailure [ModeStep])
runModeSteps window disturbed pointer (ModePlan steps after) = go [] steps
  where
    native = sessionNative (windowSession window)
    handle = windowHandle window
    go returned [] = Right (reverse returned) <$ mapM_ (setNativeConstraints window) after
    go returned (step : rest) = do
      writeIORef disturbed True
      when (isJust after && constraintStep step) (setNativeConstraints window NativeIndeterminate)
      reports ← reportsDuring (windowSession window) (call step)
      if hasReports reports
        then pure (Left (StoppedPartway (reverse returned) step rest reports))
        else go (step : returned) rest
    constraintStep = \case
      ClearSizeLimitsStep → True
      ClearAspectRatioStep → True
      SizeLimitsStep _ _ → True
      AspectRatioStep _ → True
      _ → False
    call = \case
      ClearSizeLimitsStep → nativeClearWindowSizeLimits native handle
      ClearAspectRatioStep → nativeSetWindowAspectRatio native handle Nothing
      DecorationStep decorated → nativeSetWindowDecorated native handle decorated
      PlacementStep (Placement x y) (Extent width height) →
        nativeSetWindowMonitor native handle nullPtr (fromIntegral x) (fromIntegral y) (fromIntegral width) (fromIntegral height) Nothing
      -- A fullscreen plan always carries the pointer its resolution returned in
      -- this boundary.
      MonitorStep _ (Extent width height) refresh →
        nativeSetWindowMonitor native handle (fromMaybe nullPtr pointer) 0 0 (fromIntegral width) (fromIntegral height) (fromIntegral <$> refresh)
      SizeLimitsStep lower upper →
        nativeSetWindowSizeLimits
          native
          handle
          (fromIntegral (extentWidth lower))
          (fromIntegral (extentHeight lower))
          (fromIntegral (extentWidth upper))
          (fromIntegral (extentHeight upper))
      AspectRatioStep ratio →
        nativeSetWindowAspectRatio native handle ((\(AspectRatio numerator denominator) → (fromIntegral numerator, fromIntegral denominator)) <$> ratio)

-- | Sample the window, reconcile its applied mode and its monitor claims with
-- the sample, apply @adjust@ to its mode record, and publish: a new revision even
-- when nothing changed if @forced@ holds. A sample that reports errors leaves
-- the applied mode indeterminate and the window's claims uncertain, publishes
-- the record without a sample, and is answered as data.
samplePresentation ∷ Bool → Window → (ModeRecord → ModeRecord) → IO PostCallObservation
samplePresentation forced window adjust =
  tryWithContext (sampleAll session identifiers (windowHandle window)) >>= \case
    Left (ExceptionWithContext _ failure) → do
      settle Unavailable
      reconcileAdjusted forced (withRecord (adjust . recordApplied AppliedIndeterminate)) (pure ()) window Nothing
      raiseLatchedFault window
      pure (PostCallSampleFailed (nativeOutcome failure) (nativeReports failure))
    Right sample → do
      reconcileAdjusted forced (withRecord adjust) (pure ()) window (Just sample)
      raiseLatchedFault window
      OwnerState current _ ← readIORef (windowOwnerState window)
      pure (PostCallRevision (obsRevision current))
  where
    session = windowSession window
    identifiers = windowIdentifiers (windowId window)
    settle observed = do
      live ← liveMonitors session
      atomicModifyIORef' (sessionClaims session) $ \claims →
        (settleClaims (windowLocalIdentity (windowId window)) observed (pruneClaims live claims), ())
    withRecord change observation = observation {obsMode = change (obsMode observation)}

-- | Transition a window to its startup mode during creation. An optional
-- startup request refused before any native call, or whose target the
-- platform cannot perform, with no fallback to take, is recorded as a failed
-- target attempt, so the degradation stays observable.
startWindowMode ∷ Window → StartupMode → IO ()
startWindowMode window startup =
  transitionAt (pure ()) window (startupRequirement startup) request >>= \case
    WindowAvailable (ModeRefused rejection) → recordStartup (RefusedBeforeMutation rejection)
    WindowAvailable (ModeUnsupported reason) → recordStartup (UnsupportedTarget reason)
    _ → pure ()
  where
    request = startupRequest startup
    recordStartup how =
      void . atBoundary (pure ()) window transitionOperation $
        samplePresentation True window (recordSettled request (ModeFailed [ModeAttemptFailure TargetAttempt how]))

-- | An attempt's cleanup: when the attempt made a native step, restore the
-- preserved windowed constraints of a window it left windowed with its native
-- constraints suspended or indeterminate. A call that reports an error fails
-- the cleanup.
restoreLeftWindowed ∷ Window → IORef Bool → IO ()
restoreLeftWindowed window disturbed = do
  stepped ← readIORef disturbed
  OwnerState current _ ← readIORef (windowOwnerState window)
  ControlState windowed native _ ← readIORef (windowControl window)
  case (stepped, modeApplied (obsMode current), native, windowed) of
    (True, AppliedWindowed, NativeSuspended, ConstraintsKnown preserved) → restore preserved
    (True, AppliedWindowed, NativeIndeterminate, ConstraintsKnown preserved) → restore preserved
    _ → pure ()
  where
    session = windowSession window
    nativeTable = sessionNative session
    handle = windowHandle window
    restore preserved = do
      setNativeConstraints window NativeIndeterminate
      mapM_ restoring (calls preserved)
      setNativeConstraints window NativeFollowsWindowed
    restoring call = do
      reports ← reportsDuring session call
      when (hasReports reports) $
        throwFailure
          glfwComponent
          restoreConstraintsOperation
          (windowIdentifiers (windowId window))
          (NativeFailure NativeCallReturned reports)
    calls = \case
      Nothing → [nativeClearWindowSizeLimits nativeTable handle, nativeSetWindowAspectRatio nativeTable handle Nothing]
      Just preserved →
        [ nativeSetWindowSizeLimits
            nativeTable
            handle
            (fromIntegral (extentWidth (constraintMinimum preserved)))
            (fromIntegral (extentHeight (constraintMinimum preserved)))
            (fromIntegral (extentWidth (constraintMaximum preserved)))
            (fromIntegral (extentHeight (constraintMaximum preserved)))
        , nativeSetWindowAspectRatio nativeTable handle $
            (\(AspectRatio numerator denominator) → (fromIntegral numerator, fromIntegral denominator))
              <$> constraintAspectRatio preserved
        ]

-- | Reconcile a window's mode after a monitor refresh, at an owner boundary: take
-- the recorded windowed fallback when the applied mode names an ended monitor
-- identity, answering its outcome, or resample when there is no fallback or the
-- applied mode is indeterminate. A closing window, and one inside a transition,
-- are left alone.
reconcileWindowMode ∷ Window → IO (WindowResult (Maybe ModeOutcome))
reconcileWindowMode window =
  atBoundary (pure ()) window reconcileModeOperation $ do
    OwnerState current _ ← readIORef (windowOwnerState window)
    ControlState _ _ transition ← readIORef (windowControl window)
    live ← liveMonitors (windowSession window)
    let record = obsMode current
        ended = any (`notElem` live) (appliedMonitor (modeApplied record))
    if obsPhase current /= WindowOpen || transition
      then pure Nothing
      else
        if ended && fallbackAttempts (modeFallback record) > 0
          then
            runTransition (pure ()) window ModeOptional (modeRequest (modeRequested record) (modeFallback record)) WindowedFallbackAttempt >>= \case
              ModeSettled outcome _ → pure (Just outcome)
              _ → pure Nothing
          else Nothing <$ when (ended || modeApplied record == AppliedIndeterminate) (void (samplePresentation False window id))
  where
    appliedMonitor = \case
      AppliedBorderless monitor → Just monitor
      AppliedFullscreen monitor → Just monitor
      _ → Nothing

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
