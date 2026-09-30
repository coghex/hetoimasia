-- | One owned mode attempt: the native interpreter of a plan from
-- "Hetoimasia.GLFW.Internal.Mode", with the monitor reservation, the
-- constraint restoration, and the settlement of an interrupted attempt that
-- make it one complete operation.
--
-- It runs on the session's owner thread, inside a transition's interval, with
-- the window's mode transition marker set by
-- "Hetoimasia.GLFW.Internal.Window.ModeTransition". It writes the session's
-- monitor claims, the window's native constraint state through
-- "Hetoimasia.GLFW.Internal.Window.State"'s 'setNativeConstraints', and the
-- window's observation through
-- "Hetoimasia.GLFW.Internal.Window.Reconcile"'s commit. The transition
-- contract it serves is documented in
-- "Hetoimasia.GLFW.Internal.Window.ModeTransition".
module Hetoimasia.GLFW.Internal.Window.ModeAttempt
  ( modeAttempt
  , samplePresentation
  , withRecord
  , transitionOperation
  ) where

import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , fromException
  , mask
  , mask_
  , rethrowIO
  , tryWithContext
  )
import Control.Monad (when)
import Data.Either (isRight)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (fromMaybe, isJust)
import Foreign.Ptr (Ptr, nullPtr)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Resource (withResourceLabelled)
import Hetoimasia.GLFW.Internal.Attribute (Attribute (..), Extent (..), Placement (..))
import Hetoimasia.GLFW.Internal.Capture (hasReports)
import Hetoimasia.GLFW.Internal.Control
  ( AspectRatio (..)
  , ConstraintState (..)
  , PostCallObservation (..)
  , PresentationKind (..)
  , WindowOperation (..)
  , constraintAspectRatio
  , constraintMaximum
  , constraintMinimum
  , operationGap
  )
import Hetoimasia.GLFW.Internal.Mode
  ( AppliedMode (..)
  , ModeAttemptFailure (..)
  , ModeAttemptKind (..)
  , ModeFailure (..)
  , ModePlan (..)
  , ModeRecord
  , ModeRejection (..)
  , ModeRequest
  , ModeStep (..)
  , NativeConstraints (..)
  , SavedPlacement
  , abandonClaims
  , borderlessPlacement
  , borderlessPlan
  , fullscreenPlan
  , modeApplied
  , modeMonitor
  , modePresentation
  , modeSavedPlacement
  , modeVideoPreference
  , pruneClaims
  , recordApplied
  , recordSaved
  , requestedMode
  , reserveClaim
  , savedPlacement
  , selectVideoMode
  , settleClaims
  , windowedPlacement
  , windowedPlan
  )
import Hetoimasia.GLFW.Internal.Monitor (MonitorId, MonitorResult (..), NativeMonitor, inventoryMonitors, monitorIdentity)
import Hetoimasia.GLFW.Internal.Session
  ( Native (..)
  , NativeFailure (..)
  , NativeOutcome (..)
  , glfwComponent
  , liveMonitors
  , refreshMonitors
  , resolveMonitorPointer
  , sessionClaims
  , sessionNative
  , sessionWindowCapabilities
  )
import Hetoimasia.GLFW.Internal.Window.Identity (windowLocalIdentity)
import Hetoimasia.GLFW.Internal.Window.Observation (WindowObservation (..))
import Hetoimasia.GLFW.Internal.Window.Reconcile (raiseLatchedFault, reconcileAdjusted)
import Hetoimasia.GLFW.Internal.Window.Sample (reportsDuring, sampleAll)
import Hetoimasia.GLFW.Internal.Window.State
  ( ControlState (..)
  , OwnerState (..)
  , Window (..)
  , setNativeConstraints
  , windowIdentifiers
  )

transitionOperation, restoreConstraintsOperation ∷ Operation
transitionOperation = operation "transition window mode"
restoreConstraintsOperation = operation "restore window constraints"

-- | One complete owned attempt: validate and plan, make the steps, and sample,
-- answering the steps or failing with a 'ModeAttemptFailure'. A departure from
-- an applied windowed presentation retains the geometry it departed from as
-- the saved placement whether every step returns or one reports partway, so a
-- later windowed return restores it; the failed attempt's target placement is
-- never recorded. Its cleanup restores the preserved windowed constraints of a
-- window it left windowed with them suspended.
modeAttempt ∷ IO () → Window → ModeRequest → ModeAttemptKind → IO (ModeAttemptKind, [ModeStep])
modeAttempt afterReservation window request kind =
  withResourceLabelled "glfw window constraint restoration" (newIORef False) (restoreLeftWindowed window) $ \disturbed → do
   reservation ← newIORef Nothing
   departing ← newIORef Nothing
   -- The protection that settles an interrupted attempt is in place before the
   -- attempt plans, and its handler runs masked.
   mask $ \restore → do
     attempted ∷ Either (ExceptionWithContext SomeException) (ModeAttemptKind, [ModeStep]) ←
       tryWithContext (restore (attemptBody disturbed reservation departing))
     case attempted of
       Right value → pure value
       Left caught@(ExceptionWithContext _ raised)
         | Just (_ ∷ ModeAttemptFailure) ← fromException raised → rethrowIO caught
         | otherwise → do
             reserved ← readIORef reservation
             leaving ← readIORef departing
             abandonAttempt window disturbed reserved leaving
             rethrowIO caught
  where
    attemptBody disturbed reservation departing = do
      OwnerState current _ ← readIORef (windowOwnerState window)
      ControlState windowed native _ ← readIORef (windowControl window)
      let record = obsMode current
          leaving = case (modeApplied record, obsPlacement current, obsLogical current) of
            (AppliedWindowed, Observed position, Observed extent)
              | target /= WindowedPresentation → Just (savedPlacement position extent)
            _ → Nothing
      writeIORef departing leaving
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
        Left failure → samplePresentation True window (maybe id recordSaved leaving) >> failWith failure
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
-- claims under 'abandonClaims', and, after a native step, the windowed geometry
-- it departed from retained as the saved placement and an indeterminate applied
-- mode in the owner's state, which the next mode reconciliation resamples and
-- publishes.
abandonAttempt ∷ Window → IORef Bool → Maybe MonitorId → Maybe SavedPlacement → IO ()
abandonAttempt window disturbed reserved leaving = do
  stepped ← readIORef disturbed
  atomicModifyIORef' (sessionClaims (windowSession window)) $ \claims →
    (abandonClaims (windowLocalIdentity (windowId window)) reserved stepped claims, ())
  when stepped $
    atomicModifyIORef' (windowOwnerState window) $ \(OwnerState current issued) →
      (OwnerState current {obsMode = recordApplied AppliedIndeterminate (maybe id recordSaved leaving (obsMode current))} issued, ())

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

-- | Apply a change to an observation's mode record.
withRecord ∷ (ModeRecord → ModeRecord) → WindowObservation → WindowObservation
withRecord change observation = observation {obsMode = change (obsMode observation)}

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
