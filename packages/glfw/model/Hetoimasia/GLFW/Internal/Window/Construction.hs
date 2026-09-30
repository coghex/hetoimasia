-- | Constructing a window and releasing it: the staged assembly, its native
-- parts, and the terminal observation release publishes.
--
-- Construction and release run on the session's owner thread. The assembly
-- acquires every cell of "Hetoimasia.GLFW.Internal.Window.State"'s handle and
-- registers each part's release, so the window's whole lifetime, from its
-- callback storage to its closed snapshot, is owned here and nowhere else.
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
-- A window's release drops its monitor claims when disposal succeeded, and
-- makes them uncertain otherwise.
module Hetoimasia.GLFW.Internal.Window.Construction
  ( windowAssembly
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext, SomeException, onException, rethrowIO, tryWithContext)
import Control.Monad (forM_, when)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Foreign.Ptr (Ptr, nullPtr)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Messaging.Snapshot (SnapshotPublisher, closeSnapshot, newSnapshot, publish)
import Hetoimasia.Foundation.Resource (Assembly, acquirePart, releaseRank, restoredStep, withResourceLabelled)
import Hetoimasia.GLFW.Internal.Attribute (Attribute (..))
import Hetoimasia.GLFW.Internal.Capture (Reports, hasReports, settleStrayOwnerReports, takeOwnerReports)
import Hetoimasia.GLFW.Internal.Control (ConstraintState (..))
import Hetoimasia.GLFW.Internal.Mode
  ( ModeRecord
  , NativeConstraints (..)
  , deriveApplied
  , disposeClaims
  , initialModeRecord
  , savedPlacement
  )
import Hetoimasia.GLFW.Internal.Session
  ( Native (..)
  , NativeFailure (..)
  , NativeOutcome (..)
  , NativeWindow
  , Session
  , WindowCallbackStorage
  , createWindowOperation
  , currentSessionMonitors
  , destroyWindowOperation
  , glfwComponent
  , nextWindowIdentity
  , ownerOperation
  , poisonSession
  , raiseReported
  , requireUnpoisoned
  , sessionCapture
  , sessionClaims
  , sessionIdentity
  , sessionNative
  , sessionTrace
  , sessionWindowCapabilities
  )
import Hetoimasia.GLFW.Internal.Window.Callbacks (raiseFault, rethrowFault, takeCaptures, windowCallbacks)
import Hetoimasia.GLFW.Internal.Window.Config (Request (..), WindowConfig (..), validRequest)
import Hetoimasia.GLFW.Internal.Window.Identity (WindowId, issuedWindowId)
import Hetoimasia.GLFW.Internal.Window.ModeTransition (startWindowMode)
import Hetoimasia.GLFW.Internal.Window.Observation (WindowObservation (..), WindowPhase (..))
import Hetoimasia.GLFW.Internal.Window.Reconcile (reconciled)
import Hetoimasia.GLFW.Internal.Window.Sample (Sample (..), sampleAll, sampleOperation)
import Hetoimasia.GLFW.Internal.Window.State
  ( Captures (..)
  , ControlState (..)
  , OwnerState (..)
  , Window (..)
  , noCaptures
  , traceLabel
  , windowIdentifiers
  )
import Numeric.Natural (Natural)

attachOperation, detachOperation ∷ Operation
attachOperation = operation "attach window callbacks"
detachOperation = operation "detach window callbacks"

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
  let identity = issuedWindowId (sessionIdentity session) local
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
      ( nativeNewWindowCallbacks
          native
          (windowCallbacks (sessionWindowCapabilities session) (sessionTrace session) (traceLabel identity) captures)
      )
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
