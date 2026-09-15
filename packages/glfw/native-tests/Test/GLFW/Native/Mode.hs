-- | Window modes in the shared session, on the display server's actual
-- monitors.
--
-- Each example creates its own private windows inside one dispatched operation
-- and performs mode and control commands directly on the owner thread with
-- 'performWindowCommand'. What the platform reports is read through the
-- test-only owner-thread queries of "Hetoimasia.GLFW.Internal.Native", never
-- through a public command.
--
-- A completion names the revision its final sample published. The observation
-- a snapshot holds is only the latest one, so an example captures that exact
-- revision by reading the snapshot on the owner thread immediately after the
-- command settles, before any event is processed: the owner is the only
-- publisher, so nothing can have replaced it, and the example checks that the
-- revision read is the one named. At that same point it compares the state GLFW
-- itself sets synchronously — whether the window is on a monitor, and its
-- decoration — with the test-only queries. Size and position are the display
-- server's: X11 applies them asynchronously, so a query moments after the sample
-- may already differ. A revision records what was sampled at that boundary, not
-- the platform's eventual acknowledgement, so geometry is compared only once the
-- observation and the platform's report agree, within a bound of event waits,
-- and restoration is checked against the platform's report rather than the
-- request.
--
-- The run prints the exercised monitor topology. No automated run can attach or
-- detach a display, so the record states that no hotplug transition was
-- exercised; monitor disconnection is covered by the CPU examples.
module Test.GLFW.Native.Mode (spec) where

import Data.List (find, intercalate)
import qualified Data.Text as Text
import Hetoimasia.GLFW.Command
import Hetoimasia.GLFW.Internal.Native
  ( WindowStateForCheck (..)
  , waitEventsForCheck
  , windowFullscreenForCheck
  , windowPositionForCheck
  , windowSizeForCheck
  , windowStateForCheck
  )
import Hetoimasia.GLFW.Internal.Window (windowNativeHandle)
import Hetoimasia.GLFW.Mode
import Hetoimasia.GLFW.Monitor
import Hetoimasia.GLFW.Session (Session)
import Hetoimasia.GLFW.Window
import Numeric.Natural (Natural)
import System.IO (hFlush, stdout)
import System.Info (os)
import Test.GLFW.Native.Support (Shared, currentObservation, failed, owned)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Shared → Spec
spec shared = describe "window modes" $ do
  it "returns a fullscreen window to its observed windowed placement, each completion naming a revision whose observation matches the platform" $ do
    (initial, checks, restored, saved) ←
      owned shared $ \session → do
        monitor ← selectedMonitor session
        withModeWindows session $ \perform window _ → do
          initial ← settledPlacement window
          full ← perform (mode window (fullscreenOn (monitorIdentity monitor)))
          fullCheck ← namedCheck window full
          back ← perform (mode window windowed)
          backCheck ← namedCheck window back
          restored ← convergeTo window initial
          saved ← modeSavedPlacement . observedMode <$> currentObservation window
          pure (initial, [fullCheck, backCheck], restored, saved)
    mapM_ checkAgrees checks
    map checkApplied checks `shouldSatisfy` \case
      [AppliedFullscreen _, AppliedWindowed] → True
      _ → False
    restored `shouldBe` initial
    (placementOf <$> saved) `shouldBe` Just initial

  it "places a borderless window over the selected monitor's work area and returns it to its windowed placement" $ do
    (initial, area, checks, placed, restored) ←
      owned shared $ \session → do
        monitor ← selectedMonitor session
        area ← workAreaOf monitor
        withModeWindows session $ \perform window _ → do
          initial ← settledPlacement window
          border ← perform (mode window (borderlessOn (monitorIdentity monitor)))
          borderCheck ← namedCheck window border
          placed ← convergeTo window area
          back ← perform (mode window windowed)
          backCheck ← namedCheck window back
          restored ← convergeTo window initial
          pure (initial, area, [borderCheck, backCheck], placed, restored)
    mapM_ checkAgrees checks
    placed `shouldBe` area
    restored `shouldBe` initial

  it "keeps the saved windowed placement when a fullscreen window becomes borderless, and restores it" $ do
    (initial, saved, checks, restored) ←
      owned shared $ \session → do
        monitor ← selectedMonitor session
        withModeWindows session $ \perform window _ → do
          initial ← settledPlacement window
          full ← perform (mode window (fullscreenOn (monitorIdentity monitor)))
          fullCheck ← namedCheck window full
          savedFullscreen ← savedOf window
          border ← perform (mode window (borderlessOn (monitorIdentity monitor)))
          borderCheck ← namedCheck window border
          savedBorderless ← savedOf window
          back ← perform (mode window windowed)
          backCheck ← namedCheck window back
          restored ← convergeTo window initial
          pure (initial, [savedFullscreen, savedBorderless], [fullCheck, borderCheck, backCheck], restored)
    mapM_ checkAgrees checks
    saved `shouldBe` [Just initial, Just initial]
    restored `shouldBe` initial

  it "refuses a second window's request for a claimed monitor without changing the first window's fullscreen configuration or the video mode, and an ordinary resize in fullscreen before its setter" $ do
    (busy, second, before, after, resized, sizeBefore, sizeAfter, first) ←
      owned shared $ \session → do
        monitor ← selectedMonitor session
        let identity = monitorIdentity monitor
        putStrLn ("glfw-native-tests mode topology on " <> os <> ": " <> topology [monitor] <> "; no hotplug transition was exercised")
        hFlush stdout
        withModeWindows session $ \perform first second → do
          owning ← perform (mode first (fullscreenOn identity))
          _ ← namedCheck first owning
          -- The display server applies the fullscreen geometry asynchronously.
          _ ← convergeTo first =<< fullscreenGeometry monitor
          before ← monitorFacts session identity first
          busy ← perform (mode second (modeRequest (fullscreenMode identity (otherPreference monitor)) noModeFallback))
          after ← monitorFacts session identity first
          sizeBefore ← windowSizeForCheck (windowNativeHandle first)
          resized ← perform (setWindowSizeCommand (windowIdentity first) (Extent 300 200))
          sizeAfter ← windowSizeForCheck (windowNativeHandle first)
          _ ← perform (mode first windowed)
          pure (busy, windowIdentity second, before, after, resized, sizeBefore, sizeAfter, windowIdentity first)
    busy `shouldSatisfy` \case
      Rejected (ModeRejected window (MonitorBusy _)) → window == second
      _ → False
    after `shouldBe` before
    resized `shouldBe` Rejected (ControlRejected first (ControlIneligibleInMode FullscreenPresentation))
    sizeAfter `shouldBe` sizeBefore

-- | What one completion named, captured on the owner thread as it settled.
data NamedCheck = NamedCheck
  { checkNamedRevision ∷ Natural
  , checkObservedRevision ∷ Natural
  , checkObservedFullscreen ∷ Maybe Bool
  , checkPlatformFullscreen ∷ Bool
  , checkObservedDecorated ∷ Attribute Bool
  , checkPlatformDecorated ∷ Bool
  , checkApplied ∷ AppliedMode
  }
  deriving (Show)

-- | Read the snapshot and the platform at once after a completion settled.
namedCheck ∷ Window → Disposition → IO NamedCheck
namedCheck window settled = do
  revision ← case settled of
    Transitioned (ModeTransition _ (ModeApplied TargetAttempt _ []) (PostCallRevision named)) → pure named
    other → failed ("the transition did not apply cleanly: " <> show other)
  observation ← currentObservation window
  fullscreen ← windowFullscreenForCheck handle
  state ← windowStateForCheck handle
  pure
    NamedCheck
      { checkNamedRevision = revision
      , checkObservedRevision = observedRevision observation
      , checkObservedFullscreen = case observedFullscreenMonitor observation of
          Observed on → Just (on /= Nothing)
          Unavailable → Nothing
      , checkPlatformFullscreen = fullscreen
      , checkObservedDecorated = observedDecorated observation
      , checkPlatformDecorated = checkDecorated state
      , checkApplied = modeApplied (observedMode observation)
      }
  where
    handle = windowNativeHandle window

checkAgrees ∷ NamedCheck → IO ()
checkAgrees check = do
  checkObservedRevision check `shouldBe` checkNamedRevision check
  checkObservedFullscreen check `shouldBe` Just (checkPlatformFullscreen check)
  checkObservedDecorated check `shouldBe` Observed (checkPlatformDecorated check)

-- | Two private hidden windows in the shared session and a direct executor over
-- them.
withModeWindows ∷ Session → ((WindowCommand → IO Disposition) → Window → Window → IO a) → IO a
withModeWindows session body =
  withWindow session (hiddenTestWindowConfig "moded" 320 240) $ \first →
    withWindow session (hiddenTestWindowConfig "competing" 240 160) $ \second → do
      host ← newWindowCommandHost session 8
      body (performWindowCommand host [first, second]) first second

-- | The platform's primary monitor, or its first when it designates none.
selectedMonitor ∷ Session → IO MonitorDescription
selectedMonitor session =
  inventoryMonitors <$> synchronizeMonitors session >>= \case
    Observed monitors@(firstMonitor : _) → pure (maybe firstMonitor id (find ((== Observed True) . monitorPrimary) monitors))
    Observed [] → failed "the display server exposes no monitor"
    Unavailable → failed "the platform's monitor enumeration was inconsistent"

-- | The geometry a fullscreen window in the monitor's current mode takes.
fullscreenGeometry ∷ MonitorDescription → IO (Placement, Extent)
fullscreenGeometry monitor = case (monitorPosition monitor, monitorCurrentMode monitor) of
  (Observed (MonitorPosition x y), Observed current) → pure (Placement x y, Extent (modeWidth current) (modeHeight current))
  _ → failed "the selected monitor reports no position or current mode"

workAreaOf ∷ MonitorDescription → IO (Placement, Extent)
workAreaOf monitor = case monitorWorkArea monitor of
  Observed (WorkArea x y width height) → pure (Placement x y, Extent width height)
  Unavailable → failed "the selected monitor reports no work area"

-- | A video mode preference other than the first window's: an exact mode of
-- another size when the monitor reports one, and the current mode otherwise.
otherPreference ∷ MonitorDescription → VideoModePreference
otherPreference monitor = case (monitorCurrentMode monitor, monitorVideoModes monitor) of
  (Observed current, Observed modes)
    | Just other ← find (\candidate → (modeWidth candidate, modeHeight candidate) /= (modeWidth current, modeHeight current)) modes →
        exactVideoMode (Extent (modeWidth other) (modeHeight other)) Nothing
  _ → currentVideoMode

-- | Whether the first window is fullscreen, its size, and the monitor's current
-- video mode, as the platform reports them.
monitorFacts ∷ Session → MonitorId → Window → IO (Bool, (Int, Int), Maybe (Int, Int))
monitorFacts session identity window = do
  fullscreen ← windowFullscreenForCheck (windowNativeHandle window)
  size ← windowSizeForCheck (windowNativeHandle window)
  resolved ← resolveMonitor session identity
  let current = case resolved of
        MonitorAvailable description → case monitorCurrentMode description of
          Observed videoMode → Just (modeWidth videoMode, modeHeight videoMode)
          Unavailable → Nothing
        MonitorDisconnected _ → Nothing
  pure (fullscreen, size, current)

savedOf ∷ Window → IO (Maybe (Placement, Extent))
savedOf window = fmap placementOf . modeSavedPlacement . observedMode <$> currentObservation window

placementOf ∷ SavedPlacement → (Placement, Extent)
placementOf saved = (savedPosition saved, savedExtent saved)

platformPlacement ∷ Window → IO (Placement, Extent)
platformPlacement window = do
  (x, y) ← windowPositionForCheck (windowNativeHandle window)
  (width, height) ← windowSizeForCheck (windowNativeHandle window)
  pure (Placement x y, Extent width height)

-- | The window's placement once its observation and the platform agree.
settledPlacement ∷ Window → IO (Placement, Extent)
settledPlacement window =
  converge window $ \observation → do
    platform ← platformPlacement window
    let observed = (observedPlacement observation, observedLogicalExtent observation)
    pure (observed == (Observed (fst platform), Observed (snd platform)), platform)

-- | The window's placement once both its sampled observation and the platform
-- report the target, or when the bound runs out. The platform is queried after
-- the sample, so requiring both rules out a platform that advanced past a stale
-- observation; the answer is the observation's placement when it and the
-- platform agree, and the platform's otherwise.
convergeTo ∷ Window → (Placement, Extent) → IO (Placement, Extent)
convergeTo window target =
  converge window $ \observation → do
    platform ← platformPlacement window
    let observed = (observedPlacement observation, observedLogicalExtent observation)
        wanted = (Observed (fst target), Observed (snd target))
    pure (observed == wanted && platform == target, if observed == (Observed (fst platform), Observed (snd platform)) then target else platform)

-- | Synchronize the window until the check holds, waiting for native events in
-- between, and answer the check's value from the last attempt either way.
converge ∷ Window → (WindowObservation → IO (Bool, r)) → IO r
converge window check = attempt turnBound
  where
    attempt remaining = do
      observation ←
        synchronizeWindow window >>= \case
          WindowAvailable observation → pure observation
          WindowEnded _ → failed "a live window answered as ended"
      (holds, value) ← check observation
      if holds || remaining == 0
        then pure value
        else waitEventsForCheck 0.05 >> attempt (remaining - 1 ∷ Natural)

-- | At most five seconds of 50 ms event waits.
turnBound ∷ Natural
turnBound = 100

mode ∷ Window → ModeRequest → WindowCommand
mode window = setWindowModeCommand (windowIdentity window)

fullscreenOn, borderlessOn ∷ MonitorId → ModeRequest
fullscreenOn identity = modeRequest (fullscreenMode identity currentVideoMode) noModeFallback
borderlessOn identity = modeRequest (borderlessMode identity) noModeFallback

windowed ∷ ModeRequest
windowed = modeRequest windowedMode noModeFallback

-- | One line recording each monitor as the run observed it.
topology ∷ [MonitorDescription] → String
topology descriptions = intercalate "; " (map describeMonitor descriptions)
  where
    describeMonitor description =
      intercalate
        " "
        [ show (monitorIdentity description)
        , attribute (show . Text.unpack) (monitorName description)
        , "at " <> attribute (\(MonitorPosition x y) → show (x, y)) (monitorPosition description)
        , "work area " <> attribute (\(WorkArea x y width height) → show (x, y, width, height)) (monitorWorkArea description)
        , "mode " <> attribute (\current → show (modeWidth current) <> "x" <> show (modeHeight current)) (monitorCurrentMode description)
        , "modes " <> attribute (show . length) (monitorVideoModes description)
        , "primary " <> attribute show (monitorPrimary description)
        ]
    attribute ∷ (a → String) → Attribute a → String
    attribute shown = \case
      Observed value → shown value
      Unavailable → "unavailable"
