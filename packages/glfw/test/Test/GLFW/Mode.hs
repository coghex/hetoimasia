-- | Examples for window modes, over the test seam.
--
-- Mode requests are the public "Hetoimasia.GLFW.Command" mode command, executed
-- by the seam's private command executor over lexically scoped seam windows, or
-- by the window host's owner loop over a seam session. Validation, planning,
-- recovery, claims, and publication are the production model, and nothing
-- initializes GLFW.
--
-- The seam tracks each window's decoration, monitor, size, and position, so a
-- query answers what the steps before it set, and delivering a monitor's
-- disconnection takes the windows on it off it at the desktop origin, as GLFW
-- does. Two monitors are scripted: @left@ at a negative desktop origin with a
-- work area offset from both its own origin and the desktop's, and @right@,
-- primary, at the desktop origin with a work area below a bar and three video
-- modes. Windows are created at 800 by 600 at (40, 30).
--
-- Threads are coordinated explicitly, never with a sleep; the transition
-- interval is entered from inside a scripted native step.
module Test.GLFW.Mode (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), SomeException, fromException, throwIO, toException, try)
import Control.Monad (forM, forM_, join, replicateM, when)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLoggerWith, systemMetadata)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (cleanupFailures)
import Hetoimasia.GLFW.Command
import Hetoimasia.GLFW.Internal.Control (ConstraintState (ConstraintsIndeterminate))
import Hetoimasia.GLFW.Internal.Mode (ClaimState (..), NativeConstraints (..), WindowClaim (..), abandonClaims, modeRecoveryObligation, savedPlacement, windowedPlacement, windowedPlan)
import Hetoimasia.GLFW.Internal.Seam
import Hetoimasia.GLFW.Internal.Session (monitorClaims, reconcileMonitorEvents)
import Hetoimasia.GLFW.Internal.Window (EventProcessing (ProcessPending), processWindowEvents, reconcileWindowMode, transitionWindowWith)
import Hetoimasia.GLFW.Mode
import Hetoimasia.GLFW.Monitor
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window
import Hetoimasia.Runtime.GLFW
import Hetoimasia.Runtime.Logging (LoggingLifetime, withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Test.GLFW.Window (boundedExample, caughtAs, current, entered, originOf, unexpected)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "GLFW window modes" $ do
  describe "restoration" $ do
    it "leaves a repeated request inert and never restores stale placement over a window moved since"
      (boundedExample testRepeatedRequests)
    it "keeps the saved placement across windowed, fullscreen, borderless, and windowed, placing borderless over a work area at negative coordinates"
      (boundedExample testPlacementPreserved)
    it "seeds the saved placement from the actual window before a startup transition straight into fullscreen"
      (boundedExample testStartupSeeding)
    it "ends a long chain of transitions at the original placement"
      (boundedExample testLongChain)
    it "keeps a user's windowed move and resize through a later transition and return"
      (boundedExample testUserMoveSurvives)
    it "treats a request as inert only on complete equality with a cleanly applied target"
      (boundedExample testCompleteEquality)
    it "never treats a borderless request as inert after its monitor detached, even before anything refreshed the inventory"
      (boundedExample testBorderlessAfterDetach)
    it "applies a repeated fullscreen request again when the observed size or the monitor's current video mode diverged"
      (boundedExample testFullscreenDivergence)

  describe "validation" $
    it "refuses unrepresentable preferences, budgets, and placements, and unreported video modes, before any native setter"
      (boundedExample testValidation)

  describe "fallback and disconnection" $ do
    it "rejects a disconnected selected monitor without a fallback, and returns to the windowed placement with one"
      (boundedExample testDisconnectedSelection)
    it "falls back through the owner loop when the applied monitor disconnects, deriving a reachable placement and keeping the saved one"
      (boundedExample testDisconnectAfterApplied)
    it "follows a borderless window a later move callback carries onto another monitor's work area through the owner loop, with no synchronization"
      (boundedExample testDelayedBorderlessConvergence)
    it "reports finite exhaustion when no monitor remains to place the window in"
      (boundedExample testEmptyInventory)
    it "recovers through the configured fallback when an observation intervenes before reconciliation, and never repeats it"
      (boundedExample testObservationBeforeReconcile)
    it "recovers when the observation precedes the inventory refresh that ends the identity"
      (boundedExample testObservationBeforeRefresh)
    it "recovers when an observation command intervenes, and a refused request leaves the recovery pending"
      (boundedExample testObservationCommandAndRefusal)
    it "recovers a borderless window from the indeterminate observation its disconnect leaves"
      (boundedExample testBorderlessObservationRecovery)
    it "reports exhaustion once across an intervening observation and never revives it through refreshes, observations, or a reconnect"
      (boundedExample testExhaustionAfterObservation)
    it "only resamples an observed disconnect with no fallback configured, reporting the platform's truth"
      (boundedExample testObservationWithoutFallback)
    it "lets a request settled after the disconnect supersede the pending recovery"
      (boundedExample testSupersededRecovery)
    it "recovers a borderless window moved onto another live monitor by a callback when that monitor disconnects, and never repeats it"
      (boundedExample (testMovedBorderlessCurrentDisconnect MovedByCallback))
    it "recovers a borderless window moved onto another live monitor by a full sample when that monitor disconnects, and never repeats it"
      (boundedExample (testMovedBorderlessCurrentDisconnect MovedBySample))
    it "keeps a borderless window moved by a callback on its live monitor, with no fallback, when the monitor it left disconnects"
      (boundedExample (testMovedBorderlessFormerDisconnect MovedByCallback))
    it "keeps a borderless window moved by a full sample on its live monitor, with no fallback, when the monitor it left disconnects"
      (boundedExample (testMovedBorderlessFormerDisconnect MovedBySample))
    it "keeps the obligation on the ended monitor when the move is observed by a callback after its native disconnect and before the refresh"
      (boundedExample (testMoveBeforeRefresh MovedByCallback))
    it "keeps the obligation on the ended monitor when the move is observed by a full sample after its native disconnect and before the refresh"
      (boundedExample (testMoveBeforeRefresh MovedBySample))
    it "recovers from a confirmed monitor's disconnect across a move callback folded before the refresh that ends it"
      (boundedExample (testConfirmedMonitorDisconnectBeforeRefresh MovedByCallback))
    it "recovers from a confirmed monitor's disconnect across a full sample taken before the refresh that ends it"
      (boundedExample (testConfirmedMonitorDisconnectBeforeRefresh MovedBySample))
    it "only resamples a confirmed monitor's disconnect with no fallback configured, answering the followed obligation once"
      (boundedExample testMovedBorderlessWithoutFallback)
    it "recovers through the owner loop when the monitor a borderless window was moved onto disconnects a turn after the move was confirmed"
      (boundedExample testHostedMovedBorderlessDisconnect)
    it "settles borderless placement the platform cannot perform as unsupported, never as fullscreen"
      (boundedExample testUnsupportedBorderless)
    it "reports a partial native failure with its completed steps and retains the pre-departure geometry for a later return"
      (boundedExample testPartialFailure)
    it "restores the pre-departure geometry through the configured fallback when a departure fails partway"
      (boundedExample testPartialFailureFallback)
    it "restores the pre-departure geometry under constraints that admit it and exclude the stale size"
      (boundedExample testPartialFailureConstraints)
    it "retains the pre-departure geometry when a departure is interrupted after a native step"
      (boundedExample testInterruptedDeparture)
    it "stops recovery when restoring the windowed constraints fails during an attempt's cleanup, and a later refusal makes no setter"
      (boundedExample testCleanupStopsRecovery)
    it "propagates a cleanup that raises instead of reporting, settling its command as interrupted rather than as data"
      (boundedExample testRaisingCleanup)
    it "restores suspended windowed constraints when a windowed return decorates the window but fails to place it"
      (boundedExample testPartialWindowedReturn)
    it "fails a required startup mode under the required policy, rolling the window back, and records an optional one, refused or not"
      (boundedExample testStartupRequirement)

  describe "fullscreen claims" $ do
    it "gives a second window MonitorBusy without native effect or record, including while the first is iconified and with a fallback configured"
      (boundedExample testMonitorBusy)
    it "claims different monitors independently and releases each claim in both close orders"
      (boundedExample testIndependentClaims)
    it "releases a claim as soon as a refresh observes its monitor disconnected"
      (boundedExample testClaimDisconnect)
    it "keeps claims unavailable after an unobserved transition or a failed disposal until a later sample proves release"
      (boundedExample testUncertainClaims)
    it "switches monitors by reserving the destination first and releasing the source only after confirmed departure"
      (boundedExample testMonitorSwitch)
    it "settles the claims of a fullscreen attempt interrupted by a raising native step as uncertain until reconciliation, and releases an unused reservation"
      (boundedExample testInterruptedClaims)
    it "prunes an ended monitor's claim after a refresh that commits and then rethrows a monitor callback fault"
      (boundedExample testPruneOnCallbackFault)
    it "releases a fullscreen reservation cancelled after it was committed and before the first native step"
      (boundedExample testCancelledAfterReservation)

  describe "eligibility" $ do
    it "applies the operation matrix after entering each mode, rejecting ineligible controls before any native setter"
      (boundedExample testOperationMatrix)
    it "refuses controls that depend on an indeterminate presentation until a later synchronization establishes one"
      (boundedExample testIndeterminatePresentation)
    it "refuses commands inside a transition's interval, serves another window there, and admits them after settlement"
      (boundedExample testTransitionInterval)
    it "suspends windowed constraints for borderless, restores them on return, and refuses a placement they exclude"
      (boundedExample testConstraintSuspension)
    it "refuses every transition, and any windowed return, before a setter while a partial constraint update left the constraints indeterminate"
      (boundedExample testIndeterminateConstraints)

  describe "observations" $
    it "names the revision its final sample published, which reports the applied mode and geometry observed"
      (boundedExample testNamedRevision)

-- ---------------------------------------------------------------------------
-- Restoration

testRepeatedRequests ∷ Expectation
testRepeatedRequests = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let run = execute desk [window]
  entering ← run (mode window (fullscreenOn (deskRight desk)))
  beforeRepeat ← modeCalls desk
  repeated ← run (mode window (fullscreenOn (deskRight desk)))
  afterRepeat ← modeCalls desk
  returned ← run (mode window windowed)
  restored ← geometry window
  _ ← seamDrive (deskSeam desk) window DuringPoll [MovedTo 300 200]
  beforeAgain ← modeCalls desk
  again ← run (mode window windowed)
  afterAgain ← modeCalls desk
  moved ← geometry window
  entering `shouldSatisfy` appliedCleanly
  repeated `shouldSatisfy` inertly
  afterRepeat `shouldBe` beforeRepeat
  returned `shouldSatisfy` appliedCleanly
  restored `shouldBe` original
  again `shouldSatisfy` inertly
  afterAgain `shouldBe` beforeAgain
  moved `shouldBe` (Observed (Placement 300 200), Observed (Extent 800 600))

testPlacementPreserved ∷ Expectation
testPlacementPreserved = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let run = execute desk [window]
  settled ← forM [fullscreenOn (deskRight desk), borderlessOn (deskLeft desk), windowed] $ \request → do
    disposition ← run (mode window request)
    record ← recordOf window
    placed ← geometry window
    pure (disposition, modeApplied record, placementOf <$> modeSavedPlacement record, placed)
  calls ← modeCalls desk
  [appliedCleanly disposition | (disposition, _, _, _) ← settled] `shouldBe` [True, True, True]
  [applied | (_, applied, _, _) ← settled]
    `shouldBe` [AppliedFullscreen (deskRight desk), AppliedBorderless (deskLeft desk), AppliedWindowed]
  [saved | (_, _, saved, _) ← settled] `shouldBe` replicate 3 (Just (Placement 40 30, Extent 800 600))
  [placed | (_, _, _, placed) ← settled]
    `shouldBe` [ (Observed (Placement 0 0), Observed (Extent 2560 1440))
               , (Observed (Placement (-1900) 40), Observed (Extent 1880 1000))
               , original
               ]
  calls
    `shouldBe` [ SetWindowMonitor 1 2 0 0 2560 1440 (Just 60)
               , SetWindowDecorated 1 False
               , SetWindowMonitor 1 0 (-1900) 40 1880 1000 Nothing
               , SetWindowDecorated 1 True
               , SetWindowMonitor 1 0 40 30 800 600 Nothing
               ]

testStartupSeeding ∷ Expectation
testStartupSeeding = withDesk tracked $ \desk → do
  let config =
        (hiddenTestWindowConfig "startup" 800 600)
          { windowStartupMode = Just (startupMode (fullscreenOn (deskRight desk)) ModeOptional)
          }
  withWindow (deskSession desk) config $ \window → do
    started ← recordOf window
    startedAt ← geometry window
    returned ← execute desk [window] (mode window windowed)
    after ← geometry window
    modeRequested started `shouldBe` fullscreenMode (deskRight desk) currentVideoMode
    modeApplied started `shouldBe` AppliedFullscreen (deskRight desk)
    placementOf <$> modeSavedPlacement started `shouldBe` Just (Placement 40 30, Extent 800 600)
    startedAt `shouldBe` (Observed (Placement 0 0), Observed (Extent 2560 1440))
    returned `shouldSatisfy` appliedCleanly
    after `shouldBe` original

testLongChain ∷ Expectation
testLongChain = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let run = execute desk [window]
      leg =
        [ fullscreenOn (deskRight desk)
        , borderlessOn (deskLeft desk)
        , fullscreenExact (deskRight desk) 1920 1080 (Just 144)
        , borderlessOn (deskRight desk)
        , fullscreenOn (deskLeft desk)
        , windowed
        , borderlessOn (deskLeft desk)
        ]
  settled ← mapM (run . mode window) (concat (replicate 3 leg) <> [windowed])
  record ← recordOf window
  after ← geometry window
  length settled `shouldBe` 22
  filter (not . appliedCleanly) settled `shouldBe` []
  after `shouldBe` original
  modeApplied record `shouldBe` AppliedWindowed
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 40 30, Extent 800 600)

testUserMoveSurvives ∷ Expectation
testUserMoveSurvives = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let run = execute desk [window]
  _ ← seamDrive (deskSeam desk) window DuringPoll [MovedTo 500 400, ResizedTo 640 480]
  entering ← run (mode window (fullscreenOn (deskRight desk)))
  returned ← run (mode window windowed)
  after ← geometry window
  record ← recordOf window
  entering `shouldSatisfy` appliedCleanly
  returned `shouldSatisfy` appliedCleanly
  after `shouldBe` (Observed (Placement 500 400), Observed (Extent 640 480))
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 500 400, Extent 640 480)

testCompleteEquality ∷ Expectation
testCompleteEquality = do
  failing ← newIORef False
  let script =
        tracked
          { scriptWindowControl = \call reporter → case call of
              SetWindowMonitor _ 2 _ _ _ _ _ → readIORef failing >>= \on → when on (reportError reporter platformErrorCode "The monitor could not be set")
              _ → pure ()
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \window → do
    let run = execute desk [window]
        right = deskRight desk
        left = deskLeft desk
    atCurrent ← run (mode window (fullscreenOn right))
    exact ← run (mode window (fullscreenExact right 1920 1080 (Just 144)))
    exactAgain ← run (mode window (fullscreenExact right 1920 1080 (Just 144)))
    otherMonitor ← run (mode window (fullscreenOn left))
    writeIORef failing True
    failedSwitch ← run (mode window (fullscreenOn right))
    writeIORef failing False
    retried ← run (mode window (fullscreenOn right))
    calls ← modeCalls desk
    atCurrent `shouldSatisfy` appliedCleanly
    exact `shouldSatisfy` appliedCleanly
    exactAgain `shouldSatisfy` inertly
    otherMonitor `shouldSatisfy` appliedCleanly
    failedSwitch `shouldSatisfy` stoppedFirst (MonitorStep right (Extent 2560 1440) (Just 60)) ["The monitor could not be set"]
    retried `shouldSatisfy` appliedCleanly
    calls
      `shouldBe` [ SetWindowMonitor 1 2 0 0 2560 1440 (Just 60)
                 , SetWindowMonitor 1 2 0 0 1920 1080 (Just 144)
                 , SetWindowMonitor 1 1 0 0 1920 1080 (Just 60)
                 , SetWindowMonitor 1 2 0 0 2560 1440 (Just 60)
                 , SetWindowMonitor 1 2 0 0 2560 1440 (Just 60)
                 ]

testBorderlessAfterDetach ∷ Expectation
testBorderlessAfterDetach = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let run = execute desk [window]
      left = deskLeft desk
  placed ← run (mode window (borderlessOn left))
  seamSetMonitorTopology (deskSeam desk) (MonitorTopology (Just [(2, rightMonitor)]) 2)
  seamDeliverMonitorEvents (deskSeam desk) [MonitorDetached 1]
  repeated ← run (mode window (borderlessOn left))
  withFallback ← run (mode window (modeRequest (borderlessMode left) (windowedFallback 1)))
  placed `shouldSatisfy` appliedCleanly
  repeated `shouldBe` Rejected (ModeRejected (windowIdentity window) (ModeMonitorDisconnected left))
  outcomeOf withFallback
    `shouldBe` Just
      ( ModeApplied
          WindowedFallbackAttempt
          [DecorationStep True, PlacementStep (Placement 40 30) (Extent 800 600)]
          [ModeAttemptFailure TargetAttempt (RefusedBeforeMutation (ModeMonitorDisconnected left))]
      )

testFullscreenDivergence ∷ Expectation
testFullscreenDivergence = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let run = execute desk [window]
      seam = deskSeam desk
      exact = fullscreenExact (deskRight desk) 1920 1080 (Just 144)
  entering ← run (mode window exact)
  unchanged ← run (mode window exact)
  -- The window's size diverges on the same monitor.
  _ ← seamDrive seam window DuringPoll [ResizedTo 2560 1440]
  resized ← run (mode window exact)
  unchangedAgain ← run (mode window exact)
  -- The monitor's current video mode diverges while the window keeps its size.
  seamSetMonitorTopology seam (MonitorTopology (Just [(1, leftMonitor), (2, rightMonitor)]) 2)
  remoded ← run (mode window exact)
  calls ← filter (\case SetWindowMonitor {} → True; _ → False) <$> modeCalls desk
  entering `shouldSatisfy` appliedCleanly
  unchanged `shouldSatisfy` inertly
  resized `shouldSatisfy` appliedCleanly
  unchangedAgain `shouldSatisfy` inertly
  remoded `shouldSatisfy` appliedCleanly
  calls `shouldBe` replicate 3 (SetWindowMonitor 1 2 0 0 1920 1080 (Just 144))

-- ---------------------------------------------------------------------------
-- Validation

testValidation ∷ Expectation
testValidation = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let run = execute desk [window]
      target = windowIdentity window
      right = deskRight desk
      tooLarge = 2147483648
  rejected ←
    mapM
      (run . mode window)
      [ fullscreenExact right tooLarge 1080 Nothing
      , fullscreenExact right 1920 1080 (Just 0)
      , modeRequest windowedMode (windowedFallback 0)
      , modeRequest windowedMode (windowedFallback 5)
      , fullscreenExact right 1280 720 Nothing
      , fullscreenExact right 1920 1080 (Just 75)
      ]
  settersAfterRejections ← setterCalls desk
  negative ← run (mode window (borderlessOn (deskLeft desk)))
  -- A work area at the edge of the native range, whose centred fallback
  -- placement no native int can hold.
  seamSetMonitorTopology (deskSeam desk) (MonitorTopology (Just [(1, leftMonitor), (2, rightMonitor), (3, farMonitor)]) 2)
  far ← named "far" =<< synchronizeMonitors (deskSession desk)
  atEdge ← run (mode window (borderlessOn far))
  -- Only that monitor remains, so the saved placement is unreachable and is
  -- centred in its work area.
  seamSetMonitorTopology (deskSeam desk) (MonitorTopology (Just [(3, farMonitor)]) 3)
  beforeOverflow ← length <$> seamCalls (deskSeam desk)
  overflowing ← run (mode window windowed)
  settersAfterOverflow ← filter isSetter . drop beforeOverflow <$> seamCalls (deskSeam desk)
  calls ← modeCalls desk
  rejected
    `shouldBe` map
      (Rejected . ModeRejected target)
      [ VideoModeRejected tooLarge 1080 Nothing
      , VideoModeRejected 1920 1080 (Just 0)
      , FallbackAttemptsRejected 0
      , FallbackAttemptsRejected 5
      , VideoModeUnavailable right (exactVideoMode (Extent 1280 720) Nothing)
      , VideoModeUnavailable right (exactVideoMode (Extent 1920 1080) (Just 75))
      ]
  settersAfterRejections `shouldBe` []
  negative `shouldSatisfy` appliedCleanly
  atEdge `shouldSatisfy` appliedCleanly
  overflowing `shouldBe` Rejected (ModeRejected target (PlacementUnrepresentable (Placement 2147484100 200) (Extent 800 600)))
  settersAfterOverflow `shouldBe` []
  calls
    `shouldBe` [ SetWindowDecorated 1 False
               , SetWindowMonitor 1 0 (-1900) 40 1880 1000 Nothing
               , SetWindowDecorated 1 False
               , SetWindowMonitor 1 0 2147483000 0 3000 1000 Nothing
               ]

-- ---------------------------------------------------------------------------
-- Fallback and disconnection

testDisconnectedSelection ∷ Expectation
testDisconnectedSelection = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let run = execute desk [window]
      target = windowIdentity window
      left = deskLeft desk
  seamSetMonitorTopology (deskSeam desk) (MonitorTopology (Just [(2, rightMonitor)]) 2)
  seamDeliverMonitorEvents (deskSeam desk) [MonitorDetached 1]
  refusedFullscreen ← run (mode window (fullscreenOn left))
  refusedBorderless ← run (mode window (borderlessOn left))
  settersAfterRefusals ← setterCalls desk
  entering ← run (mode window (fullscreenOn (deskRight desk)))
  fellBack ← run (mode window (modeRequest (fullscreenMode left currentVideoMode) (windowedFallback 1)))
  after ← geometry window
  refusedFullscreen `shouldBe` Rejected (ModeRejected target (ModeMonitorDisconnected left))
  refusedBorderless `shouldBe` Rejected (ModeRejected target (ModeMonitorDisconnected left))
  settersAfterRefusals `shouldBe` []
  entering `shouldSatisfy` appliedCleanly
  outcomeOf fellBack
    `shouldBe` Just
      ( ModeApplied
          WindowedFallbackAttempt
          [DecorationStep True, PlacementStep (Placement 40 30) (Extent 800 600)]
          [ModeAttemptFailure TargetAttempt (RefusedBeforeMutation (ModeMonitorDisconnected left))]
      )
  after `shouldBe` original

-- | The window host's owner loop over a seam session: a user move, a fullscreen
-- request with a fallback, and then the monitor's disconnection, delivered by a
-- poll, with no further command.
testDisconnectAfterApplied ∷ Expectation
testDisconnectAfterApplied = do
  seam ← newSeam tracked
  stage ← newIORef (0 ∷ Int)
  ticket ← newIORef Nothing
  (record, placed, settled) ←
    hosted seam configuration $ \host control →
      looping host control $ \_ → do
        client ← onlyClient host
        let target = clientWindow client
        readIORef stage >>= \case
          0 → do
            _ ← withHostWindow host target (\window → seamQueueEvents seam window [MovedTo (-1500) 100])
            writeIORef stage 1
            pure Continue
          1 → do
            left ← named "left" . preparedValue . observedValue =<< atomically (readSnapshot (hostMonitors host))
            submitted ← submitWindowCommand (clientCommandPort client) [] (setWindowModeCommand target (modeRequest (fullscreenMode left currentVideoMode) (windowedFallback 2)))
            case submitted of
              SubmitAccepted accepted → writeIORef ticket (Just accepted) >> writeIORef stage 2
              other → unexpected ("the fullscreen request was not admitted: " <> show other)
            pure Continue
          2 → do
            accepted ← readIORef ticket >>= maybe (unexpected "no ticket was stored") pure
            atomically (pollCompletion accepted) >>= \case
              Nothing → pure Continue
              Just disposition → do
                when (not (appliedCleanly disposition)) (unexpected ("the fullscreen request settled as " <> show disposition))
                seamSetMonitorTopology seam (MonitorTopology (Just [(2, rightMonitor)]) 2)
                seamQueueMonitorEvents seam [MonitorDetached 1]
                writeIORef stage 3
                pure Continue
          _ → do
            latest ← preparedValue . observedValue <$> atomically (readSnapshot (clientObservations client))
            let latestRecord = observedMode latest
            pure $ case modeLastOutcome latestRecord of
              Just outcome@(ModeApplied WindowedFallbackAttempt _ _) →
                Finish (latestRecord, (observedPlacement latest, observedLogicalExtent latest), outcome)
              _ → Continue
  settled
    `shouldBe` ModeApplied WindowedFallbackAttempt [DecorationStep True, PlacementStep (Placement 880 432) (Extent 800 600)] []
  modeApplied record `shouldBe` AppliedWindowed
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement (-1500) 100, Extent 800 600)
  placed `shouldBe` (Observed (Placement 880 432), Observed (Extent 800 600))
  where
    configuration = (defaultHostConfig [hiddenTestWindowConfig "first" 800 600]) {hostIdleWait = 0.01}

-- | The window host's owner loop over a seam session: a borderless request over
-- the left monitor, then a move callback, delivered by a poll as a window
-- manager's late placement would be, onto the right monitor's work area.
testDelayedBorderlessConvergence ∷ Expectation
testDelayedBorderlessConvergence = do
  seam ← newSeam tracked
  stage ← newIORef (0 ∷ Int)
  ticket ← newIORef Nothing
  (applied, placed, right) ←
    hosted seam configuration $ \host control →
      looping host control $ \_ → do
        client ← onlyClient host
        let target = clientWindow client
        inventory ← preparedValue . observedValue <$> atomically (readSnapshot (hostMonitors host))
        readIORef stage >>= \case
          0 → do
            left ← named "left" inventory
            submitted ← submitWindowCommand (clientCommandPort client) [] (setWindowModeCommand target (modeRequest (borderlessMode left) noModeFallback))
            case submitted of
              SubmitAccepted accepted → writeIORef ticket (Just accepted) >> writeIORef stage 1
              other → unexpected ("the borderless request was not admitted: " <> show other)
            pure Continue
          1 → do
            accepted ← readIORef ticket >>= maybe (unexpected "no ticket was stored") pure
            atomically (pollCompletion accepted) >>= \case
              Nothing → pure Continue
              Just disposition → do
                when (not (appliedCleanly disposition)) (unexpected ("the borderless request settled as " <> show disposition))
                _ ← withHostWindow host target (\window → seamQueueEvents seam window [MovedTo 100 200])
                writeIORef stage 2
                pure Continue
          _ → do
            right ← named "right" inventory
            latest ← preparedValue . observedValue <$> atomically (readSnapshot (clientObservations client))
            pure $
              if modeApplied (observedMode latest) == AppliedBorderless right
                then Finish (modeApplied (observedMode latest), observedPlacement latest, right)
                else Continue
  applied `shouldBe` AppliedBorderless right
  placed `shouldBe` Observed (Placement 100 200)
  where
    configuration = (defaultHostConfig [hiddenTestWindowConfig "first" 800 600]) {hostIdleWait = 0.01}

testEmptyInventory ∷ Expectation
testEmptyInventory = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  entering ← execute desk [window] (mode window (modeRequest (fullscreenMode (deskLeft desk) currentVideoMode) (windowedFallback 1)))
  seamSetMonitorTopology seam noMonitors
  seamDeliverMonitorEvents seam [MonitorDetached 1, MonitorDetached 2]
  reconcileMonitorEvents (deskSession desk)
  beforeReconciliation ← setterCalls desk
  reconciled ← reconcileWindowMode window
  afterReconciliation ← setterCalls desk
  record ← recordOf window
  claims ← monitorClaims (deskSession desk)
  entering `shouldSatisfy` appliedCleanly
  let unreachable = ModeAttemptFailure WindowedFallbackAttempt (RefusedBeforeMutation NoReachablePlacement)
  -- One configured fallback attempt, and no more.
  reconciled `shouldBe` WindowAvailable (Just (ModeFailed [unreachable]))
  afterReconciliation `shouldBe` beforeReconciliation
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 40 30, Extent 800 600)
  modeLastOutcome record `shouldBe` Just (ModeFailed [unreachable])
  claims `shouldBe` Map.empty

-- | Fullscreen with a fallback, then the monitor's disconnect: an ordinary
-- observation folded between the inventory refresh and the mode reconciliation
-- reports the platform's truthful post-disconnect windowed state, and the
-- recovery survives it, restoring the saved placement. Once settled, neither
-- another reconciliation nor another observation restarts it.
testObservationBeforeReconcile ∷ Expectation
testObservationBeforeReconcile = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  entering ← execute desk [window] (mode window (modeRequest (fullscreenMode (deskLeft desk) currentVideoMode) (windowedFallback 1)))
  seamSetMonitorTopology seam (MonitorTopology (Just [(2, rightMonitor)]) 2)
  seamDeliverMonitorEvents seam [MonitorDetached 1]
  reconcileMonitorEvents (deskSession desk)
  observed ← synchronizeWindow window
  postDisconnect ← geometry window
  reconciled ← reconcileWindowMode window
  settledCalls ← setterCalls desk
  record ← recordOf window
  restored ← geometry window
  repeated ← reconcileWindowMode window
  reobserved ← synchronizeWindow window
  afterSettlement ← setterCalls desk
  entering `shouldSatisfy` appliedCleanly
  appliedOf observed `shouldBe` Just AppliedWindowed
  postDisconnect `shouldBe` (Observed (Placement 0 0), Observed (Extent 1920 1080))
  reconciled `shouldBe` WindowAvailable (Just recovered)
  modeApplied record `shouldBe` AppliedWindowed
  modeLastOutcome record `shouldBe` Just recovered
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 40 30, Extent 800 600)
  restored `shouldBe` original
  repeated `shouldBe` WindowAvailable Nothing
  appliedOf reobserved `shouldBe` Just AppliedWindowed
  afterSettlement `shouldBe` settledCalls
  where
    recovered = ModeApplied WindowedFallbackAttempt [DecorationStep True, PlacementStep (Placement 40 30) (Extent 800 600)] []

-- | The platform clears the window's fullscreen monitor before the monitor
-- callback's refresh ends its identity, so an observation taken between the
-- native disconnect and the refresh already reports the windowed truth. The
-- refresh that ends the identity still triggers the configured recovery.
testObservationBeforeRefresh ∷ Expectation
testObservationBeforeRefresh = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  entering ← execute desk [window] (mode window (modeRequest (fullscreenMode (deskLeft desk) currentVideoMode) (windowedFallback 1)))
  seamSetMonitorTopology seam (MonitorTopology (Just [(2, rightMonitor)]) 2)
  seamDeliverMonitorEvents seam [MonitorDetached 1]
  observed ← synchronizeWindow window
  postDisconnect ← geometry window
  reconcileMonitorEvents (deskSession desk)
  reconciled ← reconcileWindowMode window
  record ← recordOf window
  restored ← geometry window
  entering `shouldSatisfy` appliedCleanly
  appliedOf observed `shouldBe` Just AppliedWindowed
  postDisconnect `shouldBe` (Observed (Placement 0 0), Observed (Extent 1920 1080))
  reconciled `shouldBe` WindowAvailable (Just recovered)
  modeApplied record `shouldBe` AppliedWindowed
  modeLastOutcome record `shouldBe` Just recovered
  restored `shouldBe` original
  where
    recovered = ModeApplied WindowedFallbackAttempt [DecorationStep True, PlacementStep (Placement 40 30) (Extent 800 600)] []

-- | An observation through the window command port intervenes the same way,
-- and a later request refused before any native call is not retained by the
-- record: the pending recovery is still owed afterwards.
testObservationCommandAndRefusal ∷ Expectation
testObservationCommandAndRefusal = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
      target = windowIdentity window
  entering ← execute desk [window] (mode window (modeRequest (fullscreenMode (deskLeft desk) currentVideoMode) (windowedFallback 1)))
  seamSetMonitorTopology seam (MonitorTopology (Just [(2, rightMonitor)]) 2)
  seamDeliverMonitorEvents seam [MonitorDetached 1]
  reconcileMonitorEvents (deskSession desk)
  observed ← execute desk [window] (observeWindowCommand target)
  recordAfterObservation ← recordOf window
  beforeRefusal ← setterCalls desk
  refused ← execute desk [window] (mode window (fullscreenOn (deskLeft desk)))
  afterRefusal ← setterCalls desk
  reconciled ← reconcileWindowMode window
  restored ← geometry window
  entering `shouldSatisfy` appliedCleanly
  observed `shouldSatisfy` \case
    Performed (ObservationPublished published _) → published == target
    _ → False
  modeApplied recordAfterObservation `shouldBe` AppliedWindowed
  refused `shouldBe` Rejected (ModeRejected target (ModeMonitorDisconnected (deskLeft desk)))
  afterRefusal `shouldBe` beforeRefusal
  reconciled `shouldBe` WindowAvailable (Just recovered)
  restored `shouldBe` original
  where
    recovered = ModeApplied WindowedFallbackAttempt [DecorationStep True, PlacementStep (Placement 40 30) (Extent 800 600)] []

-- | The disconnect does not move a borderless window: after the refresh its
-- origin lies over no live monitor's work area, so the observation is
-- indeterminate — and the configured recovery still runs from it. That is not
-- the resample-only indeterminate state an interrupted attempt leaves, which
-- has no ended monitor.
testBorderlessObservationRecovery ∷ Expectation
testBorderlessObservationRecovery = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  entering ← execute desk [window] (mode window (modeRequest (borderlessMode (deskLeft desk)) (windowedFallback 1)))
  seamSetMonitorTopology seam (MonitorTopology (Just [(2, rightMonitor)]) 2)
  seamDeliverMonitorEvents seam [MonitorDetached 1]
  reconcileMonitorEvents (deskSession desk)
  observed ← synchronizeWindow window
  reconciled ← reconcileWindowMode window
  record ← recordOf window
  restored ← geometry window
  entering `shouldSatisfy` appliedCleanly
  appliedOf observed `shouldBe` Just AppliedIndeterminate
  reconciled `shouldBe` WindowAvailable (Just recovered)
  modeApplied record `shouldBe` AppliedWindowed
  modeLastOutcome record `shouldBe` Just recovered
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 40 30, Extent 800 600)
  restored `shouldBe` original
  where
    recovered = ModeApplied WindowedFallbackAttempt [DecorationStep True, PlacementStep (Placement 40 30) (Extent 800 600)] []

-- | Exhaustion settles the recovery too: with no monitor left to place the
-- window in, the fallback reports honestly across an intervening observation,
-- and no later refresh, observation, or reconnection at a reused address under
-- a new identity revives it.
testExhaustionAfterObservation ∷ Expectation
testExhaustionAfterObservation = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  entering ← execute desk [window] (mode window (modeRequest (fullscreenMode (deskLeft desk) currentVideoMode) (windowedFallback 1)))
  seamSetMonitorTopology seam noMonitors
  seamDeliverMonitorEvents seam [MonitorDetached 1, MonitorDetached 2]
  observed ← synchronizeWindow window
  reconcileMonitorEvents (deskSession desk)
  reconciled ← reconcileWindowMode window
  settledCalls ← setterCalls desk
  record ← recordOf window
  repeated ← reconcileWindowMode window
  reobserved ← synchronizeWindow window
  seamSetMonitorTopology seam (MonitorTopology (Just [(1, leftMonitor), (2, rightMonitor)]) 2)
  seamDeliverMonitorEvents seam [MonitorAttached 1, MonitorAttached 2]
  reconcileMonitorEvents (deskSession desk)
  afterReconnect ← reconcileWindowMode window
  finalCalls ← setterCalls desk
  entering `shouldSatisfy` appliedCleanly
  appliedOf observed `shouldBe` Just AppliedWindowed
  reconciled `shouldBe` WindowAvailable (Just (ModeFailed [unreachable]))
  modeLastOutcome record `shouldBe` Just (ModeFailed [unreachable])
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 40 30, Extent 800 600)
  repeated `shouldBe` WindowAvailable Nothing
  appliedOf reobserved `shouldBe` Just AppliedWindowed
  afterReconnect `shouldBe` WindowAvailable Nothing
  finalCalls `shouldBe` settledCalls
  where
    unreachable = ModeAttemptFailure WindowedFallbackAttempt (RefusedBeforeMutation NoReachablePlacement)

-- | With no fallback configured, an observed disconnect is only resampled: the
-- observation keeps reporting the platform's post-disconnect state, no
-- recovery invents a placement, and the saved placement is preserved. That
-- resample answers the obligation, so a later reconciliation samples nothing
-- again — the owner loop reconciles every turn.
testObservationWithoutFallback ∷ Expectation
testObservationWithoutFallback = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  entering ← execute desk [window] (mode window (fullscreenOn (deskLeft desk)))
  seamSetMonitorTopology seam (MonitorTopology (Just [(2, rightMonitor)]) 2)
  seamDeliverMonitorEvents seam [MonitorDetached 1]
  reconcileMonitorEvents (deskSession desk)
  observed ← synchronizeWindow window
  beforeReconciliation ← setterCalls desk
  reconciled ← reconcileWindowMode window
  record ← recordOf window
  postDisconnect ← geometry window
  afterReconciliation ← setterCalls desk
  callsAfterAnswer ← seamCalls seam
  repeated ← reconcileWindowMode window
  callsAfterRepeat ← seamCalls seam
  entering `shouldSatisfy` appliedCleanly
  appliedOf observed `shouldBe` Just AppliedWindowed
  reconciled `shouldBe` WindowAvailable Nothing
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 40 30, Extent 800 600)
  postDisconnect `shouldBe` (Observed (Placement 0 0), Observed (Extent 1920 1080))
  afterReconciliation `shouldBe` beforeReconciliation
  repeated `shouldBe` WindowAvailable Nothing
  callsAfterRepeat `shouldBe` callsAfterAnswer

-- | A mode request that executes after the disconnect and settles takes over
-- the record, whatever the pending recovery was: no stale recovery undoes it.
testSupersededRecovery ∷ Expectation
testSupersededRecovery = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  entering ← execute desk [window] (mode window (modeRequest (fullscreenMode (deskLeft desk) currentVideoMode) (windowedFallback 1)))
  seamSetMonitorTopology seam (MonitorTopology (Just [(2, rightMonitor)]) 2)
  seamDeliverMonitorEvents seam [MonitorDetached 1]
  reconcileMonitorEvents (deskSession desk)
  _ ← synchronizeWindow window
  settled ← execute desk [window] (mode window windowed)
  afterSettled ← setterCalls desk
  reconciled ← reconcileWindowMode window
  record ← recordOf window
  afterReconciliation ← setterCalls desk
  entering `shouldSatisfy` appliedCleanly
  outcomeOf settled `shouldBe` Just (ModeApplied TargetAttempt [DecorationStep True, PlacementStep (Placement 40 30) (Extent 800 600)] [])
  reconciled `shouldBe` WindowAvailable Nothing
  modeApplied record `shouldBe` AppliedWindowed
  afterReconciliation `shouldBe` afterSettled

-- | How a borderless window's move onto the right monitor's work area is
-- observed: a move callback folded at a poll boundary, re-deriving the applied
-- mode from the folded placement alone, or a full sample taken after the poll
-- delivered the callback, re-deriving it from the sample.
data MovePath = MovedByCallback | MovedBySample
  deriving (Eq, Show)

-- | Observe the window moved to a placement through the given path, and answer
-- its published applied mode.
observeMove ∷ MovePath → Desk → Window → Int → Int → IO AppliedMode
observeMove path desk window x y = do
  let seam = deskSeam desk
  case path of
    MovedByCallback → do
      _ ← seamDrive seam window DuringPoll [MovedTo x y]
      pure ()
    MovedBySample → do
      seamQueueEvents seam window [MovedTo x y]
      processWindowEvents (deskSession desk) ProcessPending
      _ ← synchronizeWindow window
      pure ()
  modeApplied <$> recordOf window

-- | Enter borderless over the left monitor with one fallback attempt, move the
-- window onto the right monitor's work area while both are connected, and
-- confirm the move at a reconciliation against the unchanged inventory: no
-- outcome, no setter, and the recovery now owed to the right monitor.
movedBorderlessConfirmed ∷ MovePath → Desk → Window → IO ()
movedBorderlessConfirmed path desk window = do
  entering ← execute desk [window] (mode window (modeRequest (borderlessMode (deskLeft desk)) (windowedFallback 1)))
  entered' ← recordOf window
  moved ← observeMove path desk window 100 200
  beforeConfirmation ← setterCalls desk
  confirmed ← reconcileWindowMode window
  afterConfirmation ← setterCalls desk
  confirmedRecord ← recordOf window
  entering `shouldSatisfy` appliedCleanly
  modeRecoveryObligation entered' `shouldBe` Just (deskLeft desk)
  moved `shouldBe` AppliedBorderless (deskRight desk)
  confirmed `shouldBe` WindowAvailable Nothing
  afterConfirmation `shouldBe` beforeConfirmation
  modeRecoveryObligation confirmedRecord `shouldBe` Just (deskRight desk)
  modeApplied confirmedRecord `shouldBe` AppliedBorderless (deskRight desk)

-- | The right monitor alone, and the left alone, as the scripted platform
-- enumerates them after the other's disconnect.
rightOnly, leftOnly ∷ MonitorTopology
rightOnly = MonitorTopology (Just [(2, rightMonitor)]) 2
leftOnly = MonitorTopology (Just [(1, leftMonitor)]) 1

-- | The windowed fallback's return to the saved placement, which lies inside
-- the right monitor's work area, and its centred placement in the left
-- monitor's work area when only the left remains.
recoveredOnRight, recoveredOnLeft ∷ ModeOutcome
recoveredOnRight = ModeApplied WindowedFallbackAttempt [DecorationStep True, PlacementStep (Placement 40 30) (Extent 800 600)] []
recoveredOnLeft = ModeApplied WindowedFallbackAttempt [DecorationStep True, PlacementStep (Placement (-1360) 240) (Extent 800 600)] []

-- | A borderless window moved onto the right monitor while both were connected,
-- then the right monitor's disconnect: the recovery follows the window, so the
-- configured fallback runs, placing the window in the remaining monitor's work
-- area and keeping the saved placement; once settled, neither another
-- reconciliation nor another observation repeats it.
testMovedBorderlessCurrentDisconnect ∷ MovePath → Expectation
testMovedBorderlessCurrentDisconnect path = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  movedBorderlessConfirmed path desk window
  seamSetMonitorTopology seam leftOnly
  seamDeliverMonitorEvents seam [MonitorDetached 2]
  reconcileMonitorEvents (deskSession desk)
  reconciled ← reconcileWindowMode window
  settledCalls ← setterCalls desk
  record ← recordOf window
  restored ← geometry window
  repeated ← reconcileWindowMode window
  reobserved ← synchronizeWindow window
  repeatedAgain ← reconcileWindowMode window
  afterSettlement ← setterCalls desk
  reconciled `shouldBe` WindowAvailable (Just recoveredOnLeft)
  modeApplied record `shouldBe` AppliedWindowed
  modeLastOutcome record `shouldBe` Just recoveredOnLeft
  modeRecoveryObligation record `shouldBe` Nothing
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 40 30, Extent 800 600)
  restored `shouldBe` (Observed (Placement (-1360) 240), Observed (Extent 800 600))
  repeated `shouldBe` WindowAvailable Nothing
  appliedOf reobserved `shouldBe` Just AppliedWindowed
  repeatedAgain `shouldBe` WindowAvailable Nothing
  afterSettlement `shouldBe` settledCalls

-- | The same move, then the left monitor's disconnect instead: the window
-- stands on its connected monitor, so no fallback runs and no setter is
-- called, the borderless presentation is kept, and later reconciliations and
-- observations leave it alone.
testMovedBorderlessFormerDisconnect ∷ MovePath → Expectation
testMovedBorderlessFormerDisconnect path = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  movedBorderlessConfirmed path desk window
  seamSetMonitorTopology seam rightOnly
  seamDeliverMonitorEvents seam [MonitorDetached 1]
  reconcileMonitorEvents (deskSession desk)
  beforeReconciliation ← seamCalls seam
  reconciled ← reconcileWindowMode window
  afterReconciliation ← seamCalls seam
  record ← recordOf window
  placed ← geometry window
  reobserved ← synchronizeWindow window
  repeated ← reconcileWindowMode window
  finalCalls ← setterCalls desk
  reconciled `shouldBe` WindowAvailable Nothing
  afterReconciliation `shouldBe` beforeReconciliation
  modeApplied record `shouldBe` AppliedBorderless (deskRight desk)
  modeRecoveryObligation record `shouldBe` Just (deskRight desk)
  modeLastOutcome record `shouldSatisfy` \case
    Just (ModeApplied TargetAttempt _ []) → True
    _ → False
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 40 30, Extent 800 600)
  -- Borderless over the left work area keeps that area's extent; only the
  -- position moved.
  placed `shouldBe` (Observed (Placement 100 200), Observed (Extent 1880 1000))
  appliedOf reobserved `shouldBe` Just (AppliedBorderless (deskRight desk))
  repeated `shouldBe` WindowAvailable Nothing
  finalCalls `shouldSatisfy` all (\case SetWindowMonitor {} → True; SetWindowDecorated {} → True; _ → False)

-- | The left monitor disconnects natively, and before the refresh that ends
-- its identity a move onto the right monitor is observed — a callback folded
-- against the inventory the refresh has not yet corrected, or a full sample
-- taken against it. The observation reports borderless on the right, but the
-- move was never confirmed while both monitors were live, so the obligation
-- stays with the ended monitor and the configured fallback runs from the
-- refresh.
testMoveBeforeRefresh ∷ MovePath → Expectation
testMoveBeforeRefresh path = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  entering ← execute desk [window] (mode window (modeRequest (borderlessMode (deskLeft desk)) (windowedFallback 1)))
  seamSetMonitorTopology seam rightOnly
  seamDeliverMonitorEvents seam [MonitorDetached 1]
  moved ← observeMove path desk window 100 200
  beforeRefresh ← recordOf window
  reconcileMonitorEvents (deskSession desk)
  reconciled ← reconcileWindowMode window
  record ← recordOf window
  restored ← geometry window
  repeated ← reconcileWindowMode window
  entering `shouldSatisfy` appliedCleanly
  moved `shouldBe` AppliedBorderless (deskRight desk)
  modeRecoveryObligation beforeRefresh `shouldBe` Just (deskLeft desk)
  reconciled `shouldBe` WindowAvailable (Just recoveredOnRight)
  modeApplied record `shouldBe` AppliedWindowed
  modeLastOutcome record `shouldBe` Just recoveredOnRight
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 40 30, Extent 800 600)
  restored `shouldBe` original
  repeated `shouldBe` WindowAvailable Nothing

-- | After a confirmed move onto the right monitor, the right monitor
-- disconnects natively and a further observation — another move, still over
-- the right monitor's work area, through the given path alone — intervenes
-- before the refresh that ends its identity, still deriving borderless on the
-- right against the stale inventory. The obligation followed the window, so
-- the refresh triggers the configured fallback into the remaining monitor.
testConfirmedMonitorDisconnectBeforeRefresh ∷ MovePath → Expectation
testConfirmedMonitorDisconnectBeforeRefresh path = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  movedBorderlessConfirmed path desk window
  seamSetMonitorTopology seam leftOnly
  seamDeliverMonitorEvents seam [MonitorDetached 2]
  movedAgain ← observeMove path desk window 120 220
  beforeRefresh ← recordOf window
  reconcileMonitorEvents (deskSession desk)
  reconciled ← reconcileWindowMode window
  record ← recordOf window
  restored ← geometry window
  repeated ← reconcileWindowMode window
  movedAgain `shouldBe` AppliedBorderless (deskRight desk)
  modeRecoveryObligation beforeRefresh `shouldBe` Just (deskRight desk)
  reconciled `shouldBe` WindowAvailable (Just recoveredOnLeft)
  modeApplied record `shouldBe` AppliedWindowed
  modeLastOutcome record `shouldBe` Just recoveredOnLeft
  modeRecoveryObligation record `shouldBe` Nothing
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 40 30, Extent 800 600)
  restored `shouldBe` (Observed (Placement (-1360) 240), Observed (Extent 800 600))
  repeated `shouldBe` WindowAvailable Nothing

-- | With no fallback configured, the confirmed monitor's disconnect is only
-- resampled: the one resample reports the window left over no live work area
-- and answers the followed obligation, no setter is called, and the saved
-- placement is preserved. Once a later observation establishes the window
-- over the remaining monitor, a further reconciliation samples nothing.
testMovedBorderlessWithoutFallback ∷ Expectation
testMovedBorderlessWithoutFallback = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  entering ← execute desk [window] (mode window (borderlessOn (deskLeft desk)))
  moved ← observeMove MovedByCallback desk window 100 200
  confirmed ← reconcileWindowMode window
  confirmedRecord ← recordOf window
  settersBefore ← setterCalls desk
  seamSetMonitorTopology seam leftOnly
  seamDeliverMonitorEvents seam [MonitorDetached 2]
  reconcileMonitorEvents (deskSession desk)
  beforeAnswer ← seamCalls seam
  reconciled ← reconcileWindowMode window
  afterAnswer ← seamCalls seam
  answered ← recordOf window
  _ ← observeMove MovedBySample desk window (-1500) 100
  relocated ← recordOf window
  beforeRepeat ← seamCalls seam
  repeated ← reconcileWindowMode window
  afterRepeat ← seamCalls seam
  settersAfter ← setterCalls desk
  entering `shouldSatisfy` appliedCleanly
  moved `shouldBe` AppliedBorderless (deskRight desk)
  confirmed `shouldBe` WindowAvailable Nothing
  modeRecoveryObligation confirmedRecord `shouldBe` Just (deskRight desk)
  reconciled `shouldBe` WindowAvailable Nothing
  length afterAnswer `shouldSatisfy` (> length beforeAnswer)
  modeApplied answered `shouldBe` AppliedIndeterminate
  modeRecoveryObligation answered `shouldBe` Nothing
  placementOf <$> modeSavedPlacement answered `shouldBe` Just (Placement 40 30, Extent 800 600)
  modeApplied relocated `shouldBe` AppliedBorderless (deskLeft desk)
  modeRecoveryObligation relocated `shouldBe` Nothing
  repeated `shouldBe` WindowAvailable Nothing
  afterRepeat `shouldBe` beforeRepeat
  settersAfter `shouldBe` settersBefore

-- | The window host's owner loop: a borderless request over the left monitor
-- with a fallback, a move callback onto the right monitor delivered by a poll,
-- a further turn for the loop's reconciliation to confirm the move while both
-- monitors are connected, then the right monitor's disconnect delivered by a
-- later poll. The loop's reconciliation after that turn's refresh takes the
-- configured fallback into the remaining monitor.
testHostedMovedBorderlessDisconnect ∷ Expectation
testHostedMovedBorderlessDisconnect = do
  seam ← newSeam tracked
  stage ← newIORef (0 ∷ Int)
  ticket ← newIORef Nothing
  observedAt ← newIORef Nothing
  (record, placed, settled) ←
    hosted seam configuration $ \host control →
      looping host control $ \turn → do
        client ← onlyClient host
        let target = clientWindow client
        inventory ← preparedValue . observedValue <$> atomically (readSnapshot (hostMonitors host))
        latest ← preparedValue . observedValue <$> atomically (readSnapshot (clientObservations client))
        readIORef stage >>= \case
          0 → do
            left ← named "left" inventory
            submitted ← submitWindowCommand (clientCommandPort client) [] (setWindowModeCommand target (modeRequest (borderlessMode left) (windowedFallback 1)))
            case submitted of
              SubmitAccepted accepted → writeIORef ticket (Just accepted) >> writeIORef stage 1
              other → unexpected ("the borderless request was not admitted: " <> show other)
            pure Continue
          1 → do
            accepted ← readIORef ticket >>= maybe (unexpected "no ticket was stored") pure
            atomically (pollCompletion accepted) >>= \case
              Nothing → pure Continue
              Just disposition → do
                when (not (appliedCleanly disposition)) (unexpected ("the borderless request settled as " <> show disposition))
                _ ← withHostWindow host target (\window → seamQueueEvents seam window [MovedTo 100 200])
                writeIORef stage 2
                pure Continue
          2 → do
            right ← named "right" inventory
            when (modeApplied (observedMode latest) == AppliedBorderless right) $ do
              writeIORef observedAt (Just (turnNumber turn))
              writeIORef stage 3
            pure Continue
          3 → do
            observed ← readIORef observedAt >>= maybe (unexpected "no observation turn was stored") pure
            -- The turn after the move was published has reconciled the window
            -- against an inventory holding both monitors.
            when (turnNumber turn > observed) $ do
              seamSetMonitorTopology seam leftOnly
              seamQueueMonitorEvents seam [MonitorDetached 2]
              writeIORef stage 4
            pure Continue
          _ → do
            let latestRecord = observedMode latest
            pure $ case modeLastOutcome latestRecord of
              Just outcome@(ModeApplied WindowedFallbackAttempt _ _) →
                Finish (latestRecord, (observedPlacement latest, observedLogicalExtent latest), outcome)
              _ → Continue
  settled `shouldBe` recoveredOnLeft
  modeApplied record `shouldBe` AppliedWindowed
  modeRecoveryObligation record `shouldBe` Nothing
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 40 30, Extent 800 600)
  placed `shouldBe` (Observed (Placement (-1360) 240), Observed (Extent 800 600))
  where
    configuration = (defaultHostConfig [hiddenTestWindowConfig "first" 800 600]) {hostIdleWait = 0.01}

testUnsupportedBorderless ∷ Expectation
testUnsupportedBorderless =
  withDesk tracked {scriptWindowCapabilities = const (backendWindowCapabilities Wayland)} $ \desk →
    withWindowIn desk "first" $ \window → do
      let run = execute desk [window]
          target = windowIdentity window
      unsupported ← run (mode window (borderlessOn (deskRight desk)))
      settersAfter ← modeCalls desk
      observation ← current window
      withFallback ← run (mode window (modeRequest (borderlessMode (deskRight desk)) (windowedFallback 1)))
      let startup = (hiddenTestWindowConfig "startup" 800 600) {windowStartupMode = Just (startupMode (borderlessOn (deskRight desk)) ModeOptional)}
      startedRecord ← withWindow (deskSession desk) startup recordOf
      modeLastOutcome startedRecord `shouldSatisfy` \case
        Just (ModeFailed [ModeAttemptFailure TargetAttempt (UnsupportedTarget reason)]) → reason /= ""
        _ → False
      modeApplied startedRecord `shouldBe` AppliedWindowed
      unsupported `shouldSatisfy` \case
        Unsupported (UnsupportedControl window' BorderlessOperation reason) → window' == target && reason /= ""
        _ → False
      settersAfter `shouldBe` []
      observedFullscreenMonitor observation `shouldBe` Observed Nothing
      modeApplied (observedMode observation) `shouldBe` AppliedWindowed
      -- The modeled platform reports no placement, so none was seeded to fall
      -- back to either.
      outcomeOf withFallback `shouldSatisfy` \case
        Just
          ( ModeFailed
              [ ModeAttemptFailure TargetAttempt (UnsupportedTarget _)
                , ModeAttemptFailure WindowedFallbackAttempt (RefusedBeforeMutation NoReachablePlacement)
                ]
            ) → True
        _ → False

-- | A departure whose target placement reports a failure has still partially
-- left windowed presentation: the attempt retains the geometry it departed
-- from — the user's latest move and resize — while the failed borderless
-- target never enters the restoration cache, so a later explicit windowed
-- return restores where the user left the window.
testPartialFailure ∷ Expectation
testPartialFailure = do
  let script =
        tracked
          { scriptWindowControl = \call reporter → case call of
              SetWindowMonitor _ 0 (-1900) 40 1880 1000 _ → reportError reporter platformErrorCode "The window could not be placed"
              _ → pure ()
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \window → do
    _ ← seamDrive (deskSeam desk) window DuringPoll [MovedTo 111 222, ResizedTo 640 480]
    partial ← execute desk [window] (mode window (borderlessOn (deskLeft desk)))
    recordAfter ← recordOf window
    callsAfterPartial ← modeCalls desk
    returned ← execute desk [window] (mode window windowed)
    restored ← geometry window
    record ← recordOf window
    partial `shouldSatisfy` stoppedPartwayAfter [DecorationStep False] (PlacementStep (Placement (-1900) 40) (Extent 1880 1000)) ["The window could not be placed"]
    callsAfterPartial `shouldBe` [SetWindowDecorated 1 False, SetWindowMonitor 1 0 (-1900) 40 1880 1000 Nothing]
    -- The retained placement is the pre-departure (111,222), 640x480, never
    -- the failed target's (-1900,40), 1880x1000.
    placementOf <$> modeSavedPlacement recordAfter `shouldBe` Just (Placement 111 222, Extent 640 480)
    modeRequested recordAfter `shouldBe` borderlessMode (deskLeft desk)
    -- What was observed: an undecorated window over the right monitor's work
    -- area, where the user left it.
    modeApplied recordAfter `shouldBe` AppliedBorderless (deskRight desk)
    returned `shouldSatisfy` appliedCleanly
    restored `shouldBe` (Observed (Placement 111 222), Observed (Extent 640 480))
    placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 111 222, Extent 640 480)

-- | The configured fallback of a departure that failed partway is itself a
-- windowed return: it places the window at the retained pre-departure
-- geometry, which the scripted failure — matching only the borderless target
-- placement — leaves reachable.
testPartialFailureFallback ∷ Expectation
testPartialFailureFallback = do
  let script =
        tracked
          { scriptWindowControl = \call reporter → case call of
              SetWindowMonitor _ 0 (-1900) 40 1880 1000 _ → reportError reporter platformErrorCode "The window could not be placed"
              _ → pure ()
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \window → do
    _ ← seamDrive (deskSeam desk) window DuringPoll [MovedTo 111 222, ResizedTo 640 480]
    settled ← execute desk [window] (mode window (modeRequest (borderlessMode (deskLeft desk)) (windowedFallback 1)))
    record ← recordOf window
    restored ← geometry window
    calls ← modeCalls desk
    outcomeOf settled `shouldSatisfy` \case
      Just (ModeApplied WindowedFallbackAttempt steps [ModeAttemptFailure TargetAttempt (StoppedPartway returned at unattempted reports)]) →
        steps == [DecorationStep True, PlacementStep (Placement 111 222) (Extent 640 480)]
          && returned == [DecorationStep False]
          && at == PlacementStep (Placement (-1900) 40) (Extent 1880 1000)
          && null unattempted
          && reportedTexts reports == ["The window could not be placed"]
      _ → False
    placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 111 222, Extent 640 480)
    restored `shouldBe` (Observed (Placement 111 222), Observed (Extent 640 480))
    modeApplied record `shouldBe` AppliedWindowed
    calls
      `shouldBe` [ SetWindowDecorated 1 False
                 , SetWindowMonitor 1 0 (-1900) 40 1880 1000 Nothing
                 , SetWindowDecorated 1 True
                 , SetWindowMonitor 1 0 111 222 640 480 Nothing
                 ]

-- | Preserved constraints admit sizes only, so they are what proves the
-- retained geometry restores under constraint: resized to an admitted size the
-- stale seeded size violates, a partial departure followed by a windowed
-- return succeeds at the latest geometry, where a stale cache would refuse
-- 'PlacementExcluded'.
testPartialFailureConstraints ∷ Expectation
testPartialFailureConstraints = do
  let script =
        tracked
          { scriptWindowControl = \call reporter → case call of
              SetWindowMonitor _ 0 (-1900) 40 1880 1000 _ → reportError reporter platformErrorCode "The window could not be placed"
              _ → pure ()
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \window → do
    let run = execute desk [window]
        target = windowIdentity window
        constraints = sizeConstraints (Extent 400 300) (Extent 700 500) Nothing
    _ ← seamDrive (deskSeam desk) window DuringPoll [ResizedTo 640 480]
    installed ← run (setSizeConstraintsCommand target constraints)
    partial ← run (mode window (borderlessOn (deskLeft desk)))
    recordAfter ← recordOf window
    beforeReturn ← length <$> seamCalls (deskSeam desk)
    returned ← run (mode window windowed)
    returnCalls ← filter isModeCall . drop beforeReturn <$> seamCalls (deskSeam desk)
    restored ← geometry window
    installed `shouldSatisfy` attempted
    partial `shouldSatisfy` stoppedPartwayAfter [ClearSizeLimitsStep, ClearAspectRatioStep, DecorationStep False] (PlacementStep (Placement (-1900) 40) (Extent 1880 1000)) ["The window could not be placed"]
    -- The retained placement is the admitted (40,30), 640x480, not the stale
    -- seeded 800x600 the constraints exclude.
    placementOf <$> modeSavedPlacement recordAfter `shouldBe` Just (Placement 40 30, Extent 640 480)
    returned `shouldSatisfy` appliedCleanly
    returnCalls
      `shouldBe` [ SetWindowDecorated 1 True
                 , SetWindowMonitor 1 0 40 30 640 480 Nothing
                 , SetWindowSizeLimits 1 400 300 700 500
                 , SetWindowAspectRatio 1 Nothing
                 ]
    restored `shouldBe` (Observed (Placement 40 30), Observed (Extent 640 480))

-- | A departure interrupted by an exception that is not its own attempt
-- failure, after a native step ran, settles its command as interrupted and its
-- applied mode indeterminate — and still retains the pre-departure geometry,
-- so after the reconciliation's resample an explicit windowed return restores
-- where the user left the window.
testInterruptedDeparture ∷ Expectation
testInterruptedDeparture = do
  let script =
        tracked
          { scriptWindowControl = \call _reporter → case call of
              SetWindowMonitor _ 0 (-1900) 40 1880 1000 _ → throwIO (userError "the placement raised")
              _ → pure ()
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \window → do
    _ ← seamDrive (deskSeam desk) window DuringPoll [MovedTo 111 222, ResizedTo 640 480]
    ticket ← submit (windowCommandPort (deskHost desk)) (mode window (borderlessOn (deskLeft desk)))
    raised ← try @SomeException (seamExecuteNext (deskSeam desk) (deskHost desk) [window])
    settled ← atomically (pollCompletion ticket)
    reconciled ← reconcileWindowMode window
    afterReconcile ← recordOf window
    returned ← execute desk [window] (mode window windowed)
    restored ← geometry window
    record ← recordOf window
    case raised of
      Left caught → do
        (fromException caught ∷ Maybe ModeAttemptFailure) `shouldSatisfy` \case
          Nothing → True
          Just _ → False
        length (cleanupFailures caught) `shouldBe` 0
      Right step → unexpected ("the raising step settled as data: " <> show step)
    settled `shouldBe` Just (Interrupted (submittedRequest (ticketOrigin ticket)))
    -- The interrupted attempt settled the applied mode indeterminate; the
    -- reconciliation resamples and publishes the platform's truth.
    reconciled `shouldBe` WindowAvailable Nothing
    modeApplied afterReconcile `shouldBe` AppliedBorderless (deskRight desk)
    placementOf <$> modeSavedPlacement afterReconcile `shouldBe` Just (Placement 111 222, Extent 640 480)
    returned `shouldSatisfy` appliedCleanly
    restored `shouldBe` (Observed (Placement 111 222), Observed (Extent 640 480))
    modeApplied record `shouldBe` AppliedWindowed
    placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 111 222, Extent 640 480)

testCleanupStopsRecovery ∷ Expectation
testCleanupStopsRecovery = do
  failing ← newIORef False
  let script =
        tracked
          { scriptWindowControl = \call reporter → readIORef failing >>= \on → when on $ case call of
              SetWindowDecorated _ False → reportError reporter platformErrorCode "The decoration could not be set"
              SetWindowSizeLimits {} → reportError reporter platformErrorCode "The size limits could not be restored"
              _ → pure ()
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \window → do
    let run = execute desk [window]
        target = windowIdentity window
    installed ← run (setSizeConstraintsCommand target (sizeConstraints (Extent 100 100) (Extent 3000 3000) Nothing))
    writeIORef failing True
    stopped ← run (mode window (modeRequest (borderlessMode (deskLeft desk)) (windowedFallback 2)))
    writeIORef failing False
    calls ← modeCalls desk
    refusedSize ← run (setWindowSizeCommand target (Extent 640 480))
    installed `shouldSatisfy` attempted
    outcomeOf stopped `shouldSatisfy` \case
      Just
        ( ModeRecoveryStopped
            [ ModeAttemptFailure
                TargetAttempt
                (StoppedPartway [ClearSizeLimitsStep, ClearAspectRatioStep] (DecorationStep False) [PlacementStep _ _] _)
              ]
            cleanup
          ) → reportedTexts cleanup == ["The size limits could not be restored"]
      _ → False
    -- No fallback followed the failed cleanup: nothing placed the window.
    calls
      `shouldBe` [ SetWindowSizeLimits 1 100 100 3000 3000
                 , SetWindowAspectRatio 1 Nothing
                 , ClearWindowSizeLimits 1
                 , SetWindowAspectRatio 1 Nothing
                 , SetWindowDecorated 1 False
                 , SetWindowSizeLimits 1 100 100 3000 3000
                 ]
    refusedSize `shouldBe` Rejected (ControlRejected target ActiveConstraintsIndeterminate)
    -- A request refused before any native call runs no cleanup of its own, even
    -- though the constraints are still indeterminate.
    seamSetMonitorTopology (deskSeam desk) (MonitorTopology (Just [(2, rightMonitor)]) 2)
    seamDeliverMonitorEvents (deskSeam desk) [MonitorDetached 1]
    beforeRefusal ← length <$> seamCalls (deskSeam desk)
    refusedAfterStop ← run (mode window (borderlessOn (deskLeft desk)))
    settersAfterRefusal ← filter isSetter . drop beforeRefusal <$> seamCalls (deskSeam desk)
    refusedAfterStop `shouldBe` Rejected (ModeRejected target (ModeMonitorDisconnected (deskLeft desk)))
    settersAfterRefusal `shouldBe` []

testRaisingCleanup ∷ Expectation
testRaisingCleanup = do
  failing ← newIORef False
  let script =
        tracked
          { scriptWindowControl = \call reporter → readIORef failing >>= \on → when on $ case call of
              SetWindowDecorated _ False → reportError reporter platformErrorCode "The decoration could not be set"
              SetWindowSizeLimits {} → throwIO (userError "the restoration raised")
              _ → pure ()
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \window → do
    let target = windowIdentity window
    installed ← execute desk [window] (setSizeConstraintsCommand target (sizeConstraints (Extent 100 100) (Extent 3000 3000) Nothing))
    writeIORef failing True
    ticket ← submit (windowCommandPort (deskHost desk)) (mode window (modeRequest (borderlessMode (deskLeft desk)) (windowedFallback 2)))
    raised ← try @SomeException (seamExecuteNext (deskSeam desk) (deskHost desk) [window])
    writeIORef failing False
    settled ← atomically (pollCompletion ticket)
    calls ← modeCalls desk
    installed `shouldSatisfy` attempted
    case raised of
      Left caught → do
        (fromException caught ∷ Maybe ModeAttemptFailure) `shouldSatisfy` \case
          Just (ModeAttemptFailure TargetAttempt (StoppedPartway {})) → True
          _ → False
        length (cleanupFailures caught) `shouldBe` 1
      Right step → unexpected ("the raising cleanup settled as data: " <> show step)
    settled `shouldBe` Just (Interrupted (submittedRequest (ticketOrigin ticket)))
    filter (\case SetWindowMonitor {} → True; _ → False) calls `shouldBe` []

testPartialWindowedReturn ∷ Expectation
testPartialWindowedReturn = do
  failing ← newIORef False
  let script =
        tracked
          { scriptWindowControl = \call reporter → case call of
              SetWindowMonitor _ 0 40 30 _ _ _ →
                readIORef failing >>= \on → when on (reportError reporter platformErrorCode "The window could not be placed")
              _ → pure ()
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \window → do
    let run = execute desk [window]
        target = windowIdentity window
        constraints = sizeConstraints (Extent 400 300) (Extent 1600 1200) (Just (AspectRatio 4 3))
    installed ← run (setSizeConstraintsCommand target constraints)
    borderless ← run (mode window (borderlessOn (deskLeft desk)))
    writeIORef failing True
    beforeReturn ← length <$> seamCalls (deskSeam desk)
    partial ← run (mode window windowed)
    writeIORef failing False
    returnCalls ← filter isModeCall . drop beforeReturn <$> seamCalls (deskSeam desk)
    record ← recordOf window
    admitted ← run (setWindowSizeCommand target (Extent 1024 768))
    outside ← run (setWindowSizeCommand target (Extent 1000 1000))
    installed `shouldSatisfy` attempted
    borderless `shouldSatisfy` appliedCleanly
    partial `shouldSatisfy` stoppedPartwayAfter [DecorationStep True] (PlacementStep (Placement 40 30) (Extent 800 600)) ["The window could not be placed"] . withoutUnattempted
    -- The cleanup restored the preserved constraints of the window it left
    -- windowed.
    returnCalls
      `shouldBe` [ SetWindowDecorated 1 True
                 , SetWindowMonitor 1 0 40 30 800 600 Nothing
                 , SetWindowSizeLimits 1 400 300 1600 1200
                 , SetWindowAspectRatio 1 (Just (4, 3))
                 ]
    modeApplied record `shouldBe` AppliedWindowed
    admitted `shouldSatisfy` attempted
    outside `shouldBe` Rejected (ControlRejected target (SizeOutsideConstraints (Extent 1000 1000) constraints))
  where
    -- The steps not attempted after the placement are the restoration the
    -- cleanup then made.
    withoutUnattempted = \case
      Transitioned (ModeTransition window' (ModeFailed [ModeAttemptFailure TargetAttempt (StoppedPartway returned at _ reports)]) observation) →
        Transitioned (ModeTransition window' (ModeFailed [ModeAttemptFailure TargetAttempt (StoppedPartway returned at [] reports)]) observation)
      other → other

testStartupRequirement ∷ Expectation
testStartupRequirement = withDesk tracked $ \desk → do
  let seam = deskSeam desk
      left = deskLeft desk
  seamSetMonitorTopology seam (MonitorTopology (Just [(2, rightMonitor)]) 2)
  seamDeliverMonitorEvents seam [MonitorDetached 1]
  let required = (hiddenTestWindowConfig "required" 800 600) {windowStartupMode = Just (startupMode (fullscreenOn left) ModeRequired)}
      optional =
        required {windowStartupMode = Just (startupMode (modeRequest (fullscreenMode left currentVideoMode) (windowedFallback 1)) ModeOptional)}
  (failure, caught) ← caughtAs (withWindow (deskSession desk) required (\_ → pure ()))
  calls ← seamCalls seam
  live ← seamLiveWindowCallbacks seam
  recorded ← withWindow (deskSession desk) optional recordOf
  refusedStartup ← withWindow (deskSession desk) required {windowStartupMode = Just (startupMode (fullscreenOn left) ModeOptional)} recordOf
  invalidStartup ←
    withWindow (deskSession desk) required {windowStartupMode = Just (startupMode (modeRequest windowedMode (windowedFallback 0)) ModeOptional)} recordOf
  failure `shouldBe` ModeAttemptFailure TargetAttempt (RefusedBeforeMutation (ModeMonitorDisconnected left))
  originOf caught `shouldBe` Just ("glfw", "transition window mode", [("window", "1")])
  filter isModeCall calls `shouldBe` []
  (DestroyWindow 1 `elem` calls) `shouldBe` True
  live `shouldBe` 0
  modeRequested refusedStartup `shouldBe` fullscreenMode left currentVideoMode
  modeApplied refusedStartup `shouldBe` AppliedWindowed
  modeLastOutcome refusedStartup
    `shouldBe` Just (ModeFailed [ModeAttemptFailure TargetAttempt (RefusedBeforeMutation (ModeMonitorDisconnected left))])
  modeLastOutcome invalidStartup
    `shouldBe` Just (ModeFailed [ModeAttemptFailure TargetAttempt (RefusedBeforeMutation (FallbackAttemptsRejected 0))])
  modeLastOutcome recorded
    `shouldBe` Just
      ( ModeApplied
          WindowedFallbackAttempt
          [DecorationStep True, PlacementStep (Placement 40 30) (Extent 800 600)]
          [ModeAttemptFailure TargetAttempt (RefusedBeforeMutation (ModeMonitorDisconnected left))]
      )

-- ---------------------------------------------------------------------------
-- Fullscreen claims

testMonitorBusy ∷ Expectation
testMonitorBusy = withDesk tracked $ \desk →
  withWindowIn desk "first" $ \first → withWindowIn desk "second" $ \second → do
    let run = execute desk [first, second]
        right = deskRight desk
        busyFor = Rejected (ModeRejected (windowIdentity second) (MonitorBusy right))
    owning ← run (mode first (fullscreenOn right))
    beforeBusy ← length <$> seamCalls (deskSeam desk)
    busy ← run (mode second (fullscreenExact right 1920 1080 (Just 144)))
    settersAfterBusy ← filter isSetter . drop beforeBusy <$> seamCalls (deskSeam desk)
    minimized ← run (minimizeWindowCommand (windowIdentity first))
    _ ← seamDrive (deskSeam desk) first DuringPoll [IconifyChanged True]
    beforeIconified ← length <$> seamCalls (deskSeam desk)
    busyWhileIconified ← run (mode second (fullscreenOn right))
    busyWithFallback ← run (mode second (modeRequest (fullscreenMode right currentVideoMode) (windowedFallback 2)))
    settersWhileIconified ← filter isSetter . drop beforeIconified <$> seamCalls (deskSeam desk)
    secondRecord ← recordOf second
    firstObservation ← current first
    claims ← monitorClaims (deskSession desk)
    owning `shouldSatisfy` appliedCleanly
    busy `shouldBe` busyFor
    settersAfterBusy `shouldBe` []
    minimized `shouldSatisfy` attempted
    busyWhileIconified `shouldBe` busyFor
    busyWithFallback `shouldBe` busyFor
    settersWhileIconified `shouldBe` []
    modeRequested secondRecord `shouldBe` windowedMode
    modeLastOutcome secondRecord `shouldBe` Nothing
    observedIconified firstObservation `shouldBe` Observed True
    observedFullscreenMonitor firstObservation `shouldBe` Observed (Just right)
    claims `shouldBe` Map.fromList [(right, WindowClaim 1 ClaimHeld)]

testIndependentClaims ∷ Expectation
testIndependentClaims = forM_ [True, False] $ \leftClosesFirst → withDesk tracked $ \desk → do
  let (inner, outer) = if leftClosesFirst then (deskLeft desk, deskRight desk) else (deskRight desk, deskLeft desk)
  withWindowIn desk "outer" $ \outerWindow → do
    withWindowIn desk "inner" $ \innerWindow → do
      let run = execute desk [outerWindow, innerWindow]
      outerOwned ← run (mode outerWindow (fullscreenOn outer))
      innerOwned ← run (mode innerWindow (fullscreenOn inner))
      both ← monitorClaims (deskSession desk)
      outerOwned `shouldSatisfy` appliedCleanly
      innerOwned `shouldSatisfy` appliedCleanly
      both `shouldBe` Map.fromList [(outer, WindowClaim 1 ClaimHeld), (inner, WindowClaim 2 ClaimHeld)]
    afterInner ← monitorClaims (deskSession desk)
    afterInner `shouldBe` Map.fromList [(outer, WindowClaim 1 ClaimHeld)]
    withWindowIn desk "third" $ \third → do
      reused ← execute desk [third] (mode third (fullscreenOn inner))
      stillOwned ← execute desk [third] (mode third (fullscreenOn outer))
      reused `shouldSatisfy` appliedCleanly
      stillOwned `shouldBe` Rejected (ModeRejected (windowIdentity third) (MonitorBusy outer))
  afterOuter ← monitorClaims (deskSession desk)
  afterOuter `shouldBe` Map.empty
  withWindowIn desk "fourth" $ \fourth →
    execute desk [fourth] (mode fourth (fullscreenOn outer)) >>= (`shouldSatisfy` appliedCleanly)

testClaimDisconnect ∷ Expectation
testClaimDisconnect = withDesk tracked $ \desk →
  withWindowIn desk "first" $ \first → withWindowIn desk "second" $ \second → do
    let run = execute desk [first, second]
        seam = deskSeam desk
        left = deskLeft desk
    owning ← run (mode first (fullscreenOn left))
    -- The same display, reconnected at another address: a new identity.
    seamSetMonitorTopology seam (MonitorTopology (Just [(2, rightMonitor), (3, leftMonitor)]) 2)
    seamDeliverMonitorEvents seam [MonitorDetached 1, MonitorAttached 3]
    reconnected ← named "left" =<< synchronizeMonitors (deskSession desk)
    afterRefresh ← monitorClaims (deskSession desk)
    stale ← run (mode second (fullscreenOn left))
    fresh ← run (mode second (fullscreenOn reconnected))
    claims ← monitorClaims (deskSession desk)
    owning `shouldSatisfy` appliedCleanly
    afterRefresh `shouldBe` Map.empty
    (reconnected == left) `shouldBe` False
    stale `shouldBe` Rejected (ModeRejected (windowIdentity second) (ModeMonitorDisconnected left))
    fresh `shouldSatisfy` appliedCleanly
    claims `shouldBe` Map.fromList [(reconnected, WindowClaim 2 ClaimHeld)]

testUncertainClaims ∷ Expectation
testUncertainClaims = do
  unobservable ← newIORef False
  failingSwitch ← newIORef False
  failingDestroy ← newIORef False
  let script =
        tracked
          { scriptWindowMonitor = \reporter →
              readIORef unobservable >>= \on → when on (reportError reporter platformErrorCode "The window's monitor could not be read")
          , scriptWindowControl = \call reporter → case call of
              SetWindowMonitor _ 1 _ _ _ _ _ →
                readIORef failingSwitch >>= \on → when on (reportError reporter platformErrorCode "The monitor could not be set")
              _ → pure ()
          , scriptDestroyWindow = \reporter →
              readIORef failingDestroy >>= \on → when on (reportError reporter platformErrorCode "The window could not be destroyed")
          }
  withDesk script $ \desk → withWindowIn desk "bystander" $ \bystander → do
    let left = deskLeft desk
        right = deskRight desk
        claims = monitorClaims (deskSession desk)
        busy monitor = Rejected (ModeRejected (windowIdentity bystander) (MonitorBusy monitor))
    withWindowIn desk "switching" $ \switching → do
      let run = execute desk [bystander, switching]
      owning ← run (mode switching (fullscreenOn right))
      writeIORef failingSwitch True
      writeIORef unobservable True
      unobserved ← run (mode switching (fullscreenOn left))
      uncertain ← claims
      busyLeft ← run (mode bystander (fullscreenOn left))
      busyRight ← run (mode bystander (fullscreenOn right))
      writeIORef failingSwitch False
      writeIORef unobservable False
      synchronized ← synchronizeWindow switching
      proven ← claims
      freed ← run (mode bystander (fullscreenOn left))
      returned ← run (mode bystander windowed)
      owning `shouldSatisfy` appliedCleanly
      unobserved `shouldSatisfy` \case
        Transitioned (ModeTransition _ (ModeFailed [ModeAttemptFailure TargetAttempt (StoppedPartway [] (MonitorStep _ _ _) [] _)]) (PostCallSampleFailed _ _)) → True
        _ → False
      uncertain `shouldBe` Map.fromList [(left, WindowClaim 2 ClaimUncertain), (right, WindowClaim 2 ClaimUncertain)]
      busyLeft `shouldBe` busy left
      busyRight `shouldBe` busy right
      appliedOf synchronized `shouldBe` Just (AppliedFullscreen right)
      proven `shouldBe` Map.fromList [(right, WindowClaim 2 ClaimHeld)]
      freed `shouldSatisfy` appliedCleanly
      returned `shouldSatisfy` appliedCleanly
    afterRelease ← claims
    afterRelease `shouldBe` Map.empty
    -- A disposal that could not establish the window was destroyed.
    disposal ← try @SomeException . withWindowIn desk "disposed" $ \disposed → do
      owning ← execute desk [disposed] (mode disposed (fullscreenOn right))
      writeIORef failingDestroy True
      pure owning
    writeIORef failingDestroy False
    afterFailedDisposal ← claims
    stillBusy ← execute desk [bystander] (mode bystander (fullscreenOn right))
    either (const (pure ())) (`shouldSatisfy` appliedCleanly) disposal
    either (const True) (const False) disposal `shouldBe` True
    afterFailedDisposal `shouldBe` Map.fromList [(right, WindowClaim 3 ClaimUncertain)]
    stillBusy `shouldBe` busy right

testMonitorSwitch ∷ Expectation
testMonitorSwitch = do
  failing ← newIORef False
  let script =
        tracked
          { scriptWindowControl = \call reporter → case call of
              SetWindowMonitor 1 2 _ _ _ _ _ → readIORef failing >>= \on → when on (reportError reporter platformErrorCode "The monitor could not be set")
              _ → pure ()
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \first → withWindowIn desk "second" $ \second → do
    let run = execute desk [first, second]
        left = deskLeft desk
        right = deskRight desk
        claims = monitorClaims (deskSession desk)
    firstOwned ← run (mode first (fullscreenOn left))
    secondOwned ← run (mode second (fullscreenOn right))
    beforeOccupied ← length <$> seamCalls (deskSeam desk)
    occupied ← run (mode first (fullscreenOn right))
    settersOccupied ← filter isSetter . drop beforeOccupied <$> seamCalls (deskSeam desk)
    firstAfterOccupied ← observedFullscreenMonitor <$> current first
    claimsOccupied ← claims
    released ← run (mode second windowed)
    claimsReleased ← claims
    writeIORef failing True
    failedSwitch ← run (mode first (fullscreenOn right))
    writeIORef failing False
    claimsFailed ← claims
    switched ← run (mode first (fullscreenOn right))
    claimsSwitched ← claims
    reclaimed ← run (mode second (fullscreenOn left))
    firstOwned `shouldSatisfy` appliedCleanly
    secondOwned `shouldSatisfy` appliedCleanly
    occupied `shouldBe` Rejected (ModeRejected (windowIdentity first) (MonitorBusy right))
    settersOccupied `shouldBe` []
    firstAfterOccupied `shouldBe` Observed (Just left)
    claimsOccupied `shouldBe` Map.fromList [(left, WindowClaim 1 ClaimHeld), (right, WindowClaim 2 ClaimHeld)]
    released `shouldSatisfy` appliedCleanly
    claimsReleased `shouldBe` Map.fromList [(left, WindowClaim 1 ClaimHeld)]
    failedSwitch `shouldSatisfy` stoppedFirst (MonitorStep right (Extent 2560 1440) (Just 60)) ["The monitor could not be set"]
    -- The source was never left, and the destination's reservation was proven
    -- unused.
    claimsFailed `shouldBe` Map.fromList [(left, WindowClaim 1 ClaimHeld)]
    switched `shouldSatisfy` appliedCleanly
    claimsSwitched `shouldBe` Map.fromList [(right, WindowClaim 1 ClaimHeld)]
    reclaimed `shouldSatisfy` appliedCleanly

testInterruptedClaims ∷ Expectation
testInterruptedClaims = do
  raising ← newIORef False
  let script =
        tracked
          { scriptWindowControl = \call _ → case call of
              SetWindowMonitor 1 2 _ _ _ _ _ → readIORef raising >>= \on → when on (throwIO (userError "the monitor step raised"))
              _ → pure ()
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \first → withWindowIn desk "second" $ \second → do
    let right = deskRight desk
        left = deskLeft desk
        claims = monitorClaims (deskSession desk)
    writeIORef raising True
    ticket ← submit (windowCommandPort (deskHost desk)) (mode first (fullscreenOn right))
    raised ← try @SomeException (seamExecuteNext (deskSeam desk) (deskHost desk) [first, second])
    writeIORef raising False
    settled ← atomically (pollCompletion ticket)
    afterInterruption ← claims
    busy ← execute desk [first, second] (mode second (fullscreenOn right))
    reconciled ← reconcileWindowMode first
    afterReconciliation ← claims
    freed ← execute desk [first, second] (mode second (fullscreenOn right))
    either (const True) (const False) raised `shouldBe` True
    settled `shouldBe` Just (Interrupted (submittedRequest (ticketOrigin ticket)))
    afterInterruption `shouldBe` Map.fromList [(right, WindowClaim 1 ClaimUncertain)]
    busy `shouldBe` Rejected (ModeRejected (windowIdentity second) (MonitorBusy right))
    reconciled `shouldBe` WindowAvailable Nothing
    afterReconciliation `shouldBe` Map.empty
    freed `shouldSatisfy` appliedCleanly
    -- An attempt interrupted before any native step releases only the
    -- reservation it made, and never a claim it held before.
    abandonClaims 1 (Just right) False (Map.fromList [(right, WindowClaim 1 ClaimReserved), (left, WindowClaim 2 ClaimHeld)])
      `shouldBe` Map.fromList [(left, WindowClaim 2 ClaimHeld)]
    abandonClaims 1 (Just right) False (Map.fromList [(right, WindowClaim 1 ClaimHeld)])
      `shouldBe` Map.fromList [(right, WindowClaim 1 ClaimHeld)]
    abandonClaims 1 (Just right) True (Map.fromList [(right, WindowClaim 1 ClaimReserved), (left, WindowClaim 1 ClaimHeld)])
      `shouldBe` Map.fromList [(right, WindowClaim 1 ClaimUncertain), (left, WindowClaim 1 ClaimUncertain)]

testCancelledAfterReservation ∷ Expectation
testCancelledAfterReservation = withDesk tracked $ \desk → withWindowIn desk "first" $ \first → withWindowIn desk "second" $ \second → do
  let right = deskRight desk
  reservedWhenCancelled ← newIORef Map.empty
  -- The cancellation arrives exactly once the reservation has committed, before
  -- any native step.
  let cancel = monitorClaims (deskSession desk) >>= writeIORef reservedWhenCancelled >> throwIO ThreadKilled
  cancelled ← try @AsyncException (transitionWindowWith cancel first (fullscreenOn right))
  atCancellation ← readIORef reservedWhenCancelled
  afterCancellation ← monitorClaims (deskSession desk)
  setters ← setterCalls desk
  taken ← execute desk [first, second] (mode second (fullscreenOn right))
  cancelled `shouldBe` Left ThreadKilled
  atCancellation `shouldBe` Map.fromList [(right, WindowClaim 1 ClaimReserved)]
  afterCancellation `shouldBe` Map.empty
  setters `shouldBe` []
  taken `shouldSatisfy` appliedCleanly

testPruneOnCallbackFault ∷ Expectation
testPruneOnCallbackFault = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let seam = deskSeam desk
  owning ← execute desk [window] (mode window (fullscreenOn (deskLeft desk)))
  before ← monitorClaims (deskSession desk)
  seamSetMonitorTopology seam (MonitorTopology (Just [(2, rightMonitor)]) 2)
  seamDeliverMonitorEvents seam [MonitorDetached 1, MonitorEventRaises 1 (toException (ErrorCall "the monitor callback raised"))]
  faulted ← try @ErrorCall (synchronizeMonitors (deskSession desk))
  after ← monitorClaims (deskSession desk)
  owning `shouldSatisfy` appliedCleanly
  before `shouldBe` Map.fromList [(deskLeft desk, WindowClaim 1 ClaimHeld)]
  faulted `shouldSatisfy` either (== ErrorCall "the monitor callback raised") (const False)
  after `shouldBe` Map.empty

-- ---------------------------------------------------------------------------
-- Eligibility

testOperationMatrix ∷ Expectation
testOperationMatrix = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let run = execute desk [window]
      target = windowIdentity window
  matrix ← forM [(windowed, WindowedPresentation), (borderlessOn (deskLeft desk), BorderlessPresentation), (fullscreenOn (deskRight desk), FullscreenPresentation)] $
    \(request, kind) → do
      entered' ← run (mode window request)
      before ← length <$> seamCalls (deskSeam desk)
      settled ← mapM run (everyControl target)
      setters ← filter isSetter . drop before <$> seamCalls (deskSeam desk)
      pure (kind, entered', settled, setters)
  forM_ matrix $ \(kind, entered', settled, setters) → do
    entered' `shouldSatisfy` \disposition → inertly disposition || appliedCleanly disposition
    [refusal | Rejected (ControlRejected _ refusal) ← settled] `shouldBe` replicate (length (ineligible kind)) (ControlIneligibleInMode kind)
    length (filter attempted settled) `shouldBe` 11 - length (ineligible kind)
    setters `shouldBe` expectedSetters kind
  where
    ineligible = \case
      WindowedPresentation → []
      BorderlessPresentation → [SetSizeOperation, SetPositionOperation, SetConstraintsOperation, MaximizeOperation]
      FullscreenPresentation → [SetSizeOperation, SetPositionOperation, SetConstraintsOperation, ShowOperation, HideOperation, MaximizeOperation]
    expectedSetters = \case
      WindowedPresentation →
        [ SetWindowTitle 1 "renamed"
        , SetWindowSize 1 640 480
        , SetWindowPosition 1 10 20
        , SetWindowSizeLimits 1 100 100 2000 2000
        , SetWindowAspectRatio 1 Nothing
        , ShowWindow 1
        , HideWindow 1
        , FocusWindow 1
        , RequestWindowAttention 1
        , IconifyWindow 1
        , MaximizeWindow 1
        , RestoreWindow 1
        ]
      BorderlessPresentation →
        [SetWindowTitle 1 "renamed", ShowWindow 1, HideWindow 1, FocusWindow 1, RequestWindowAttention 1, IconifyWindow 1, RestoreWindow 1]
      FullscreenPresentation →
        [SetWindowTitle 1 "renamed", FocusWindow 1, RequestWindowAttention 1, IconifyWindow 1, RestoreWindow 1]

testIndeterminatePresentation ∷ Expectation
testIndeterminatePresentation = do
  unobservable ← newIORef False
  let script =
        tracked
          { scriptWindowMonitor = \reporter →
              readIORef unobservable >>= \on → when on (reportError reporter platformErrorCode "The window's monitor could not be read")
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \window → do
    let run = execute desk [window]
        target = windowIdentity window
    entering ← run (mode window (fullscreenOn (deskRight desk)))
    writeIORef unobservable True
    unobserved ← run (mode window (borderlessOn (deskLeft desk)))
    record ← recordOf window
    refusedSize ← run (setWindowSizeCommand target (Extent 640 480))
    refusedShow ← run (showWindowCommand target)
    titled ← run (setWindowTitleCommand target "still eligible")
    writeIORef unobservable False
    synchronized ← synchronizeWindow window
    reconciledRecord ← recordOf window
    ineligible ← run (setWindowSizeCommand target (Extent 640 480))
    returned ← run (mode window windowed)
    admitted ← run (setWindowSizeCommand target (Extent 640 480))
    entering `shouldSatisfy` appliedCleanly
    unobserved `shouldSatisfy` \case
      Transitioned (ModeTransition _ (ModeApplied TargetAttempt _ []) (PostCallSampleFailed _ _)) → True
      _ → False
    modeApplied record `shouldBe` AppliedIndeterminate
    refusedSize `shouldBe` Rejected (ControlRejected target ControlModeIndeterminate)
    refusedShow `shouldBe` Rejected (ControlRejected target ControlModeIndeterminate)
    titled `shouldSatisfy` \case
      Attempted (ControlAttempt _ ControlReturned _) → True
      _ → False
    appliedOf synchronized `shouldBe` Just (AppliedBorderless (deskLeft desk))
    modeApplied reconciledRecord `shouldBe` AppliedBorderless (deskLeft desk)
    ineligible `shouldBe` Rejected (ControlRejected target (ControlIneligibleInMode BorderlessPresentation))
    returned `shouldSatisfy` appliedCleanly
    admitted `shouldSatisfy` attempted

-- | A scripted native step inside the first window's return to windowed
-- executes three commands queued on a second host: an ordinary control and a
-- mode request for the first window, and a control for the second.
testTransitionInterval ∷ Expectation
testTransitionInterval = do
  inside ← newIORef (pure ())
  let script =
        tracked
          { scriptWindowControl = \call _ → case call of
              SetWindowDecorated 1 True → join (atomicModifyIORef' inside (\action → (pure (), action)))
              _ → pure ()
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \first → withWindowIn desk "second" $ \second → do
    let run = execute desk [first, second]
    borderless ← run (mode first (borderlessOn (deskLeft desk)))
    interval ← newWindowCommandHost (deskSession desk) 8
    tickets ←
      mapM
        (submit (windowCommandPort interval))
        [ setWindowSizeCommand (windowIdentity first) (Extent 640 480)
        , mode first (fullscreenOn (deskRight desk))
        , setWindowTitleCommand (windowIdentity second) "served"
        ]
    stepsInside ← newIORef []
    writeIORef inside $ replicateM 3 (seamExecuteNext (deskSeam desk) interval [first, second]) >>= writeIORef stepsInside
    returned ← run (mode first windowed)
    executed ← readIORef stepsInside
    settledInside ← mapM (atomically . pollCompletion) tickets
    afterSettlement ← run (setWindowSizeCommand (windowIdentity first) (Extent 640 480))
    borderless `shouldSatisfy` appliedCleanly
    returned `shouldSatisfy` appliedCleanly
    length executed `shouldBe` 3
    case settledInside of
      [Just size, Just transition, Just title] → do
        size `shouldBe` Rejected (ControlRejected (windowIdentity first) ModeTransitionInProgress)
        transition `shouldBe` Rejected (ModeRejected (windowIdentity first) TransitionAlreadyInProgress)
        title `shouldSatisfy` attempted
      other → unexpected ("the commands inside the interval did not all settle: " <> show other)
    afterSettlement `shouldSatisfy` attempted

testConstraintSuspension ∷ Expectation
testConstraintSuspension = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  let run = execute desk [window]
      target = windowIdentity window
      constraints = sizeConstraints (Extent 400 300) (Extent 1600 1200) (Just (AspectRatio 4 3))
  installed ← run (setSizeConstraintsCommand target constraints)
  beforeSuspension ← length <$> seamCalls (deskSeam desk)
  borderless ← run (mode window (borderlessOn (deskLeft desk)))
  returned ← run (mode window windowed)
  suspension ← filter isModeCall . drop beforeSuspension <$> seamCalls (deskSeam desk)
  admitted ← run (setWindowSizeCommand target (Extent 1024 768))
  outside ← run (setWindowSizeCommand target (Extent 1000 1000))
  -- A resize the constraints exclude, carried into the saved placement.
  _ ← seamDrive (deskSeam desk) window DuringPoll [ResizedTo 801 600]
  entering ← run (mode window (fullscreenOn (deskRight desk)))
  beforeRefusal ← length <$> seamCalls (deskSeam desk)
  refused ← run (mode window windowed)
  exhausted ← run (mode window (modeRequest windowedMode (windowedFallback 1)))
  settersAfterRefusal ← filter isSetter . drop beforeRefusal <$> seamCalls (deskSeam desk)
  record ← recordOf window
  let excluded = RefusedBeforeMutation (PlacementExcluded (Extent 801 600) constraints)
  installed `shouldSatisfy` attempted
  borderless `shouldSatisfy` appliedCleanly
  returned `shouldSatisfy` appliedCleanly
  suspension
    `shouldBe` [ ClearWindowSizeLimits 1
               , SetWindowAspectRatio 1 Nothing
               , SetWindowDecorated 1 False
               , SetWindowMonitor 1 0 (-1900) 40 1880 1000 Nothing
               , SetWindowDecorated 1 True
               , SetWindowMonitor 1 0 40 30 800 600 Nothing
               , SetWindowSizeLimits 1 400 300 1600 1200
               , SetWindowAspectRatio 1 (Just (4, 3))
               ]
  admitted `shouldSatisfy` attempted
  outside `shouldBe` Rejected (ControlRejected target (SizeOutsideConstraints (Extent 1000 1000) constraints))
  entering `shouldSatisfy` appliedCleanly
  refused `shouldBe` Rejected (ModeRejected target (PlacementExcluded (Extent 801 600) constraints))
  outcomeOf exhausted `shouldBe` Just (ModeFailed [ModeAttemptFailure TargetAttempt excluded, ModeAttemptFailure WindowedFallbackAttempt excluded])
  settersAfterRefusal `shouldBe` []
  modeApplied record `shouldBe` AppliedFullscreen (deskRight desk)
  placementOf <$> modeSavedPlacement record `shouldBe` Just (Placement 40 30, Extent 801 600)

testIndeterminateConstraints ∷ Expectation
testIndeterminateConstraints = do
  failing ← newIORef False
  let script =
        tracked
          { scriptWindowControl = \call reporter → case call of
              SetWindowAspectRatio {} →
                readIORef failing >>= \on → when on (reportError reporter platformErrorCode "The aspect ratio could not be set")
              _ → pure ()
          }
  withDesk script $ \desk → withWindowIn desk "first" $ \window → do
    let run = execute desk [window]
        target = windowIdentity window
        refused = Rejected (ModeRejected target WindowedConstraintsIndeterminate)
        indeterminate = RefusedBeforeMutation WindowedConstraintsIndeterminate
    writeIORef failing True
    partial ← run (setSizeConstraintsCommand target (sizeConstraints (Extent 400 300) (Extent 1600 1200) (Just (AspectRatio 4 3))))
    writeIORef failing False
    beforeTransitions ← length <$> seamCalls (deskSeam desk)
    fullscreen ← run (mode window (fullscreenOn (deskRight desk)))
    fullscreenWithFallback ← run (mode window (modeRequest (fullscreenMode (deskRight desk) currentVideoMode) (windowedFallback 1)))
    borderless ← run (mode window (borderlessOn (deskLeft desk)))
    setters ← filter isSetter . drop beforeTransitions <$> seamCalls (deskSeam desk)
    record ← recordOf window
    monitors ← inventoryMonitors <$> synchronizeMonitors (deskSession desk)
    let saved = savedPlacement (Placement 40 30) (Extent 800 600)
    partial `shouldSatisfy` \case
      Attempted (ControlAttempt _ (ConstraintUpdateFailed [SizeLimitsCall] AspectRatioCall [] _) _) → True
      _ → False
    fullscreen `shouldBe` refused
    outcomeOf fullscreenWithFallback
      `shouldBe` Just (ModeFailed [ModeAttemptFailure TargetAttempt indeterminate, ModeAttemptFailure WindowedFallbackAttempt indeterminate])
    borderless `shouldBe` refused
    setters `shouldBe` []
    modeApplied record `shouldBe` AppliedWindowed
    -- A windowed return is refused whatever the native constraints hold, so no
    -- window placed by the mode controller escapes validation.
    windowedPlacement ConstraintsIndeterminate (Just saved) monitors `shouldBe` Left WindowedConstraintsIndeterminate
    windowedPlan NativeFollowsWindowed ConstraintsIndeterminate saved `shouldBe` Left WindowedConstraintsIndeterminate
    windowedPlan NativeSuspended ConstraintsIndeterminate saved `shouldBe` Left WindowedConstraintsIndeterminate

-- ---------------------------------------------------------------------------
-- Observations

testNamedRevision ∷ Expectation
testNamedRevision = withDesk tracked $ \desk → withWindowIn desk "first" $ \window → do
  settled ← execute desk [window] (mode window (fullscreenExact (deskRight desk) 1920 1080 (Just 144)))
  -- Nothing publishes between the settlement and this read: the owner thread is
  -- the only publisher, and it is here.
  observation ← current window
  case settled of
    Transitioned (ModeTransition _ outcome (PostCallRevision revision)) → do
      revision `shouldBe` observedRevision observation
      outcome `shouldBe` ModeApplied TargetAttempt [MonitorStep (deskRight desk) (Extent 1920 1080) (Just 144)] []
      observedFullscreenMonitor observation `shouldBe` Observed (Just (deskRight desk))
      observedLogicalExtent observation `shouldBe` Observed (Extent 1920 1080)
      observedPlacement observation `shouldBe` Observed (Placement 0 0)
      modeApplied (observedMode observation) `shouldBe` AppliedFullscreen (deskRight desk)
      modeLastOutcome (observedMode observation) `shouldBe` Just outcome
    other → unexpected ("the fullscreen request named no revision: " <> show other)

-- ---------------------------------------------------------------------------
-- Support

leftMonitor, rightMonitor, farMonitor ∷ ScriptedMonitor
leftMonitor = (scriptedMonitor "left" (-1920, 0) (1920, 1080)) {scriptedWorkArea = (-1900, 40, 1880, 1000)}
rightMonitor =
  (scriptedMonitor "right" (0, 0) (2560, 1440))
    { scriptedWorkArea = (0, 25, 2560, 1415)
    , scriptedVideoModes = Just [NativeVideoMode 2560 1440 8 8 8 60, NativeVideoMode 1920 1080 8 8 8 60, NativeVideoMode 1920 1080 8 8 8 144]
    }
farMonitor = scriptedMonitor "far" (2147483000, 0) (3000, 1000)

-- | Both monitors, the right one primary, with the seam tracking window
-- geometry.
tracked ∷ SeamScript
tracked = defaultScript {scriptMonitorTopology = MonitorTopology (Just [(1, leftMonitor), (2, rightMonitor)]) 2, scriptTrackWindows = True}

data Desk = Desk
  { deskSeam ∷ Seam
  , deskSession ∷ Session
  , deskHost ∷ WindowCommandHost
  , deskLeft ∷ MonitorId
  , deskRight ∷ MonitorId
  }

-- | A seam session with a command host and the two monitors' identities, on the
-- designated process main thread.
withDesk ∷ SeamScript → (Desk → IO a) → IO a
withDesk script body = do
  seam ← newSeam script
  asProcessMainThread seam $ entered seam $ \session → do
    host ← newWindowCommandHost session 16
    inventory ← synchronizeMonitors session
    left ← named "left" inventory
    right ← named "right" inventory
    body (Desk seam session host left right)

withWindowIn ∷ Desk → Text → (Window → IO a) → IO a
withWindowIn desk title = withWindow (deskSession desk) (hiddenTestWindowConfig title 800 600)

named ∷ Text → MonitorInventory → IO MonitorId
named name inventory = case inventoryMonitors inventory of
  Observed descriptions →
    maybe (unexpected ("no monitor is named " <> show name)) (pure . monitorIdentity) (find ((== Observed name) . monitorName) descriptions)
  Unavailable → unexpected "the scripted enumeration was inconsistent"

-- | Submit one command and execute it at once, answering its disposition.
execute ∷ Desk → [Window] → WindowCommand → IO Disposition
execute desk windows command = do
  ticket ← submit (windowCommandPort (deskHost desk)) command
  seamExecuteNext (deskSeam desk) (deskHost desk) windows >>= \case
    Executed origin settled | origin == ticketOrigin ticket → pure settled
    other → unexpected ("the submitted command was not the one executed: " <> show other)

submit ∷ WindowCommandPort → WindowCommand → IO CompletionTicket
submit port command =
  submitWindowCommand port [("client", "modes")] command >>= \case
    SubmitAccepted ticket → pure ticket
    other → unexpected ("the submission was not admitted: " <> show other)

mode ∷ Window → ModeRequest → WindowCommand
mode window = setWindowModeCommand (windowIdentity window)

fullscreenOn, borderlessOn ∷ MonitorId → ModeRequest
fullscreenOn monitor = modeRequest (fullscreenMode monitor currentVideoMode) noModeFallback
borderlessOn monitor = modeRequest (borderlessMode monitor) noModeFallback

fullscreenExact ∷ MonitorId → Int → Int → Maybe Int → ModeRequest
fullscreenExact monitor width height refresh = modeRequest (fullscreenMode monitor (exactVideoMode (Extent width height) refresh)) noModeFallback

windowed ∷ ModeRequest
windowed = modeRequest windowedMode noModeFallback

appliedOf ∷ WindowResult WindowObservation → Maybe AppliedMode
appliedOf = \case
  WindowAvailable observation → Just (modeApplied (observedMode observation))
  WindowEnded _ → Nothing

recordOf ∷ Window → IO ModeRecord
recordOf window = observedMode <$> current window

geometry ∷ Window → IO (Attribute Placement, Attribute Extent)
geometry window = (\observation → (observedPlacement observation, observedLogicalExtent observation)) <$> current window

-- | Where every window starts.
original ∷ (Attribute Placement, Attribute Extent)
original = (Observed (Placement 40 30), Observed (Extent 800 600))

placementOf ∷ SavedPlacement → (Placement, Extent)
placementOf saved = (savedPosition saved, savedExtent saved)

outcomeOf ∷ Disposition → Maybe ModeOutcome
outcomeOf = \case
  Transitioned (ModeTransition _ outcome _) → Just outcome
  _ → Nothing

-- | The target itself applied, with no failure first, and a sample published.
appliedCleanly ∷ Disposition → Bool
appliedCleanly = \case
  Transitioned (ModeTransition _ (ModeApplied TargetAttempt _ []) (PostCallRevision _)) → True
  _ → False

inertly ∷ Disposition → Bool
inertly = \case
  Transitioned (ModeTransition _ ModeInert (PostCallRevision _)) → True
  _ → False

-- | The target attempt stopped at its first step, with these reports.
stoppedFirst ∷ ModeStep → [Text] → Disposition → Bool
stoppedFirst = stoppedPartwayAfter []

stoppedPartwayAfter ∷ [ModeStep] → ModeStep → [Text] → Disposition → Bool
stoppedPartwayAfter returned at reported = \case
  Transitioned (ModeTransition _ (ModeFailed [ModeAttemptFailure TargetAttempt (StoppedPartway returned' at' [] reports)]) (PostCallRevision _)) →
    returned' == returned && at' == at && reportedTexts reports == reported
  _ → False

reportedTexts ∷ Reports → [Text]
reportedTexts = map nativeErrorDescription . reportedErrors

attempted ∷ Disposition → Bool
attempted = \case
  Attempted (ControlAttempt _ ControlReturned (PostCallRevision _)) → True
  _ → False

everyControl ∷ WindowId → [WindowCommand]
everyControl target =
  [ setWindowTitleCommand target "renamed"
  , setWindowSizeCommand target (Extent 640 480)
  , setWindowPositionCommand target (Placement 10 20)
  , setSizeConstraintsCommand target (sizeConstraints (Extent 100 100) (Extent 2000 2000) Nothing)
  , showWindowCommand target
  , hideWindowCommand target
  , requestFocusCommand target
  , requestAttentionCommand target
  , minimizeWindowCommand target
  , maximizeWindowCommand target
  , restoreWindowCommand target
  ]

modeCalls ∷ Desk → IO [NativeCall]
modeCalls desk = filter isModeCall <$> seamCalls (deskSeam desk)

setterCalls ∷ Desk → IO [NativeCall]
setterCalls desk = filter isSetter <$> seamCalls (deskSeam desk)

isModeCall ∷ NativeCall → Bool
isModeCall = \case
  SetWindowMonitor {} → True
  SetWindowDecorated {} → True
  ClearWindowSizeLimits _ → True
  SetWindowSizeLimits {} → True
  SetWindowAspectRatio {} → True
  _ → False

-- | Every call that changes a window.
isSetter ∷ NativeCall → Bool
isSetter call =
  isModeCall call || case call of
    SetWindowTitle {} → True
    SetWindowSize {} → True
    SetWindowPosition {} → True
    ShowWindow _ → True
    HideWindow _ → True
    FocusWindow _ → True
    RequestWindowAttention _ → True
    IconifyWindow _ → True
    MaximizeWindow _ → True
    RestoreWindow _ → True
    _ → False

onlyClient ∷ WindowHost → IO WindowClient
onlyClient host =
  atomically (hostWindowIdentities host) >>= \case
    [window] → atomically (hostWindowClient host window) >>= maybe (unexpected "the window has no client") pure
    other → unexpected ("expected one window, found " <> show (length other))

hosted ∷ Seam → HostConfig → (WindowHost → RuntimeControl → IO a) → IO a
hosted seam config =
  asProcessMainThread seam
    . runWindowApplication lifetime "mode-example" (allocWindowHostIn (seamSession seam defaultSessionConfig) config) id (\host _ → pure host)

looping ∷ WindowHost → RuntimeControl → (Turn → IO (TurnStep a)) → IO a
looping host control update =
  runOwnerLoop host control . LoopHooks quietLogger noApplicationEvents $ \turn →
    if turnNumber turn > 400
      then unexpected "the example did not finish within its turn bound"
      else update turn

lifetime ∷ (LoggingLifetime → IO r) → IO r
lifetime = withLoggingLifetime quietLogger

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))

-- | @GLFW_PLATFORM_ERROR@.
platformErrorCode ∷ Int
platformErrorCode = 0x00010008
