-- | Window mode transitions: validating a request, running it under
-- "Hetoimasia.Foundation.Recovery"'s boundary one owned attempt at a time,
-- settling it, a window's startup mode, and the owner loop's mode
-- reconciliation.
--
-- Everything here runs on the session's owner thread, at an owner boundary.
-- It owns the window's mode transition marker for a transition's interval,
-- through "Hetoimasia.GLFW.Internal.Window.State"'s 'setModeTransition', and
-- the recorded request and outcome in the window's mode record. Each attempt
-- is "Hetoimasia.GLFW.Internal.Window.ModeAttempt"'s; the pure planning is
-- "Hetoimasia.GLFW.Internal.Mode"'s.
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
-- loop's step after its monitor refresh: a window whose recorded recovery
-- obligation names an ended monitor identity takes its recorded windowed
-- fallback without another command, or is resampled once when it has none, the
-- resample answering the obligation; a window whose applied mode is
-- indeterminate is resampled. The obligation is the monitor identity the last
-- settlement's own sample established, so the observations that truthfully
-- report the platform's post-disconnect state — before the refresh or after it
-- — do not erase it. Only that reconciliation moves it, and only for a
-- borderless window whose observed monitor and owed monitor are both live in
-- the refreshed inventory: a legitimate move between two connected monitors is
-- thereby told apart from an observation made after a disconnect, which
-- derives against the inventory the refresh has not yet corrected.
--
-- A 'WindowConfig' may carry a startup mode, transitioned during creation after
-- the initial observation seeded the saved placement. A required startup mode
-- that fails fails creation, which rolls back; an optional one leaves the window
-- in whatever presentation it reached, with its outcome recorded — a refusal or an
-- unsupported target included, recorded as a failed target attempt.
module Hetoimasia.GLFW.Internal.Window.ModeTransition
  ( transitionWindow
  , transitionWindowWith
  , startWindowMode
  , reconcileWindowMode
  ) where

import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , bracket_
  , fromException
  , rethrowIO
  , tryWithContext
  )
import Control.Monad (void, when)
import Data.IORef (readIORef)
import Data.Maybe (mapMaybe)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import qualified Hetoimasia.Foundation.Recovery as Recovery
import Hetoimasia.Foundation.Resource (CleanupFailure, cleanupFailureException, cleanupFailuresInContext)
import Hetoimasia.GLFW.Internal.Capture (Reports (..))
import Hetoimasia.GLFW.Internal.Mode
  ( AppliedMode (..)
  , ModeAttemptFailure (..)
  , ModeAttemptKind (..)
  , ModeFailure (..)
  , ModeOutcome (..)
  , ModeRejection (..)
  , ModeRequest
  , ModeRequirement (..)
  , ModeResult (..)
  , ModeStep
  , StartupMode
  , fallbackAttempts
  , followedMonitor
  , inertRequest
  , modeApplied
  , modeFallback
  , modeRecoveryObligation
  , modeRequest
  , modeRequested
  , recordRecoveryCleared
  , recordRecoveryFollowed
  , recordSettled
  , requestedFallback
  , requestedMode
  , startupRequest
  , startupRequirement
  , validateRequest
  )
import Hetoimasia.GLFW.Internal.Session (NativeFailure (..), currentSessionMonitors, glfwComponent, liveMonitors, refreshMonitors)
import Hetoimasia.GLFW.Internal.Window.Boundary (atBoundary)
import Hetoimasia.GLFW.Internal.Window.ModeAttempt (modeAttempt, samplePresentation, transitionOperation, withRecord)
import Hetoimasia.GLFW.Internal.Window.Observation (WindowObservation (..), WindowPhase (..))
import Hetoimasia.GLFW.Internal.Window.Reconcile (raiseLatchedFault, reconcileAdjusted, reconcileWindow)
import Hetoimasia.GLFW.Internal.Window.State
  ( ControlState (..)
  , OwnerState (..)
  , Window (..)
  , WindowResult (..)
  , setModeTransition
  , windowIdentifiers
  )

windowedFallbackOperation, reconcileModeOperation ∷ Operation
windowedFallbackOperation = operation "fall back to windowed mode"
reconcileModeOperation = operation "reconcile window mode"

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

-- | Reconcile a window's mode after a monitor refresh, at an owner boundary: take
-- the recorded windowed fallback when the monitor identity its recovery is owed
-- to has ended, answering its outcome, or resample when there is no fallback or
-- the applied mode is indeterminate. The obligation is the one the last
-- settlement's own sample established, so an ordinary observation that already
-- reports the platform's post-disconnect state — windowed at the desktop origin,
-- or indeterminate for a borderless window left over no live work area — does
-- not erase it, and the refresh that ends the identity triggers it however the
-- two were ordered. The obligation follows a borderless window only here, and
-- only when the refreshed inventory finds both the owed monitor and the one the
-- applied mode now stands on live ('followedMonitor'): the move is then a
-- legitimate one between connected monitors, recorded and published before any
-- disconnect is judged against it, while an observation made after a native
-- disconnect and before the refresh leaves the obligation owed to the ended
-- identity, so the recovery still runs. With no fallback the resample answers
-- the obligation, so a settled window is not resampled again on later turns. A
-- closing window, and one inside a transition, are left alone.
reconcileWindowMode ∷ Window → IO (WindowResult (Maybe ModeOutcome))
reconcileWindowMode window =
  atBoundary (pure ()) window reconcileModeOperation $ do
    OwnerState current _ ← readIORef (windowOwnerState window)
    ControlState _ _ transition ← readIORef (windowControl window)
    live ← liveMonitors (windowSession window)
    let record = obsMode current
        ended = any (`notElem` live) (modeRecoveryObligation record)
    if obsPhase current /= WindowOpen || transition
      then pure Nothing
      else case followedMonitor live record of
        -- A confirmed move between live monitors: the obligation moves with
        -- the window, and nothing has ended.
        Just followed → Nothing <$ reconcileAdjusted False (withRecord (recordRecoveryFollowed followed)) (pure ()) window Nothing
        Nothing
          | ended && fallbackAttempts (modeFallback record) > 0 →
              runTransition (pure ()) window ModeOptional (modeRequest (modeRequested record) (modeFallback record)) WindowedFallbackAttempt >>= \case
                ModeSettled outcome _ → pure (Just outcome)
                _ → pure Nothing
          | otherwise →
              Nothing
                <$ when
                  (ended || modeApplied record == AppliedIndeterminate)
                  -- A resample reached through an ended obligation carries no
                  -- fallback: publishing the truth answers the obligation.
                  (void (samplePresentation False window (if ended then recordRecoveryCleared else id)))
