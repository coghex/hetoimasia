-- | Owner boundaries: running owner work against a window and then
-- reconciling it, the private drivers built on that, close requests and the
-- closing phase, and the owner turn's one event pump.
--
-- Everything here runs on the session's owner thread, and each boundary checks
-- that it does, and that the session is live, before any native call. A
-- boundary writes the window's observation only through
-- "Hetoimasia.GLFW.Internal.Window.Reconcile"'s commit, except that rejecting a
-- close request and beginning the closing phase each publish and record one
-- revision of their own, in one masked step.
--
-- = Close requests
--
-- A native close request never destroys the window and never exits. It is
-- latched and reconciled into 'observedCloseRequest' as a 'CloseRequest' with
-- its own number, issued in increasing order per window. Rejecting a request
-- clears it only if it is still the latest, so rejecting an older request
-- cannot erase a newer one. What a close request means is the application's
-- decision; this module adds no close policy and no public command.
module Hetoimasia.GLFW.Internal.Window.Boundary
  ( -- * Owner boundaries
    atBoundary
  , synchronizeWindow
  , windowStep
  , windowStepWith

    -- * Close requests and the closing phase
  , rejectCloseRequest
  , beginWindowClosing

    -- * The owner turn
  , EventProcessing (..)
  , processWindowEvents
  , reconcileWindowEvents
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (mask_)
import Control.Monad (void, when)
import Data.IORef (readIORef, writeIORef)
import Foreign.Ptr (Ptr)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Failure (Operation, operation)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Messaging.Snapshot (publish)
import Hetoimasia.GLFW.Internal.Capture (settleStrayOwnerReports, takeOwnerReports)
import Hetoimasia.GLFW.Internal.Connection (EventBoundary (..))
import Hetoimasia.GLFW.Internal.Session
  ( Native (..)
  , NativeOutcome (..)
  , NativeWindow
  , Session
  , ownerOperation
  , raiseReported
  , requireConnection
  , sessionCapture
  , sessionNative
  , sessionTrace
  )
import Hetoimasia.GLFW.Internal.Trace (PumpMode (..), recordingPump)
import Hetoimasia.GLFW.Internal.Window.Observation (CloseRequest, WindowObservation (..), WindowPhase (..))
import Hetoimasia.GLFW.Internal.Window.Reconcile (commitObservation, raiseLatchedFault, reconcileWindow)
import Hetoimasia.GLFW.Internal.Window.Sample (sampleAll)
import Hetoimasia.GLFW.Internal.Window.State (OwnerState (..), Window (..), WindowResult (..), windowIdentifiers)

synchronizeOperation ∷ Operation
synchronizeOperation = operation "synchronize window"

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
--
-- On Wayland the session's connection-status probe runs immediately before the
-- poll or wait and immediately after it, whether or not the session has
-- windows ('requireConnection'). A connection found unusable before the call
-- fails the processing with 'ConnectionFailed' and pumps nothing; one found
-- unusable after it fails the processing with that cause rather than with
-- whatever GLFW reported, which the failure keeps beside it. Either way the
-- session latches the failure and every later processing raises it without a
-- native call. X11 and Cocoa sessions make no probe call.
processWindowEvents ∷ Session → EventProcessing → IO ()
processWindowEvents session processing =
  ownerOperation session processEventsOperation identifiers $ do
    settleStrayOwnerReports capture
    requireConnection session processEventsOperation identifiers BeforeEvents
    recordingPump (sessionTrace session) mode $ case processing of
      ProcessPending → nativePollEvents native
      AwaitEventsFor seconds → nativeWaitEventsTimeout native seconds
    requireConnection session processEventsOperation identifiers AfterEvents
    reports ← takeOwnerReports capture
    raiseReported processEventsOperation identifiers NativeCallReturned reports
  where
    native = sessionNative session
    capture = sessionCapture session
    mode = case processing of
      ProcessPending → PolledEvents
      AwaitEventsFor seconds → WaitedForEvents seconds
    identifiers = case processing of
      ProcessPending → [("events", "poll")]
      AwaitEventsFor seconds → [("events", "wait"), ("seconds", Text.pack (show seconds))]

-- | Reconcile what a window's callbacks captured since its last boundary,
-- publishing a new revision if anything changed, and rethrow a latched callback
-- fault: an owner boundary with no native step of its own. An ended window
-- answers 'WindowEnded'.
reconcileWindowEvents ∷ Window → IO (WindowResult ())
reconcileWindowEvents window = atBoundary (pure ()) window reconcileEventsOperation (pure ())
