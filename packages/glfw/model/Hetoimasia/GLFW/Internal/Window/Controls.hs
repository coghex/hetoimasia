-- | Ordinary window controls: the native interpreter of
-- "Hetoimasia.GLFW.Internal.Control"'s pure eligibility and validation rules.
--
-- A control runs on the session's owner thread, at an owner boundary. It reads
-- the window's observation and control state, and writes the preserved
-- windowed constraints only through
-- "Hetoimasia.GLFW.Internal.Window.State"'s 'setConstraintState'. It never
-- changes the window's mode or its mode transition marker.
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
-- A hide runs the window's hide guard ('guardWindowHide') after every check
-- above has admitted it and immediately before its native call, so the guard
-- runs exactly when the call is about to be made.
--
-- A constraint update marks the window's preserved windowed constraints
-- indeterminate before its first call and known only after every call returned
-- without a report. A size is validated against those constraints only while
-- the native constraints follow them; while a transition has suspended them, or
-- a suspension or restoration stopped part-way, sizes are refused as
-- indeterminate.
module Hetoimasia.GLFW.Internal.Window.Controls
  ( controlWindow
  ) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), tryWithContext)
import Data.IORef (readIORef)
import Hetoimasia.Foundation.Failure (Operation, operation)
import Hetoimasia.GLFW.Internal.Attribute (Extent (..))
import Hetoimasia.GLFW.Internal.Capture (hasReports)
import Hetoimasia.GLFW.Internal.Control
  ( AspectRatio (..)
  , ConstraintCall (..)
  , ConstraintState (..)
  , ControlOutcome (..)
  , ControlRejection (..)
  , ControlResult (..)
  , PostCallObservation (..)
  , SizeConstraints
  , WindowControl (..)
  , constraintAspectRatio
  , constraintCallOrder
  , constraintMaximum
  , constraintMinimum
  , controlEligibility
  , controlOperation
  , controlOperationText
  , operationGap
  , validateControl
  )
import Hetoimasia.GLFW.Internal.Mode (appliedPresentation, effectiveConstraints, modeApplied)
import Hetoimasia.GLFW.Internal.Session (Native (..), NativeFailure (..), sessionNative, sessionWindowCapabilities)
import Hetoimasia.GLFW.Internal.Window.Boundary (atBoundary)
import Hetoimasia.GLFW.Internal.Window.Observation (WindowObservation (..), WindowPhase (..))
import Hetoimasia.GLFW.Internal.Window.Reconcile (raiseLatchedFault, reconcileWindow, reconcileWith)
import Hetoimasia.GLFW.Internal.Window.Sample (reportsDuring, sampleAll)
import Hetoimasia.GLFW.Internal.Window.State
  ( ControlState (..)
  , OwnerState (..)
  , Window (..)
  , WindowResult
  , setConstraintState
  , windowIdentifiers
  )

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
  HideControl → windowBeforeHide window >> single (nativeHideWindow native handle)
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
