-- | Examples for ordinary window controls, over the test seam.
--
-- Commands are the public "Hetoimasia.GLFW.Command" control constructors,
-- executed by the seam's private command executor over lexically scoped seam
-- windows, or by the window host's owner loop over a seam session. Validation,
-- capability checks, native call attribution, constraint state, and post-call
-- publication are the production model, and nothing initializes GLFW. The
-- seam's private mode transition driver sets the marker a mode transition would.
--
-- Threads are coordinated explicitly, never with a sleep.
module Test.GLFW.Control (spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM, when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (isNothing, mapMaybe)
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLoggerWith, systemMetadata)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (SnapshotReader, cursorRevision, observedCursor, observedValue, readSnapshot)
import Hetoimasia.GLFW.Command
import Hetoimasia.GLFW.Internal.Seam
import Hetoimasia.GLFW.Internal.Window (beginWindowClosing)
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window
import Hetoimasia.Runtime.GLFW
import Hetoimasia.Runtime.Logging (LoggingLifetime, withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Numeric.Natural (Natural)
import Test.GLFW.Support (boundedExample, current, entered, stashed, unexpected)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "GLFW window controls" $ do
  describe "validation" $ do
    it "rejects every invalid argument class before any native call, and an out-of-constraint size once constraints are known"
      (boundedExample testInvalidArguments)
    it "rejects controls addressed to unknown, closing, and closed windows without native effect"
      (boundedExample testUnservedWindows)
    it "rejects controls while a mode transition is in progress, leaving observation and other windows alone"
      (boundedExample testModeTransition)

  describe "dispatch" $
    it "dispatches every control through the owner loop to its addressed window while a second window stays untouched"
      (boundedExample testDispatchEveryControl)

  describe "honest outcomes" $ do
    it "settles controls the modeled Wayland backend cannot perform as unsupported with a reason, and fabricates no unreportable observation"
      (boundedExample testUnsupported)
    it "audits every window operation and report against the pinned Wayland backend, restricting exactly what GLFW answers unavailable"
      (boundedExample testWaylandCapabilityAudit)
    it "attributes a native error to its own command and submission context, never to an unrelated one"
      (boundedExample testNativeErrorAttribution)
    it "reports a failed constraint update's returned, failed, and unattempted calls, refuses sizes until a complete update restores known state"
      (boundedExample testConstraintUpdateFailure)
    it "names a revision a post-call sample published, and stays correct when the latest snapshot has moved beyond it"
      (boundedExample testPostCallRevisions)

-- ---------------------------------------------------------------------------
-- Validation

testInvalidArguments ∷ Expectation
testInvalidArguments = withTwo defaultScript $ \seam _ host first second → do
  let target = windowIdentity first
      run = execute seam host [first, second]
      excluding = sizeConstraints (Extent 100 100) (Extent 400 400) Nothing
      valid = sizeConstraints (Extent 400 300) (Extent 1600 1200) (Just (AspectRatio 4 3))
  before ← current first
  rejected ←
    mapM
      run
      [ setWindowSizeCommand target (Extent 0 48)
      , setWindowSizeCommand target (Extent 64 (-1))
      , setWindowSizeCommand target (Extent tooLarge 48)
      , setWindowPositionCommand target (Placement tooLarge 0)
      , setWindowPositionCommand target (Placement 0 (negate tooLarge - 1))
      , setWindowTitleCommand target "split\NULtitle"
      , setSizeConstraintsCommand target (sizeConstraints (Extent 0 10) (Extent 100 100) Nothing)
      , setSizeConstraintsCommand target (sizeConstraints (Extent 10 10) (Extent tooLarge 100) Nothing)
      , setSizeConstraintsCommand target (sizeConstraints (Extent 900 500) (Extent 800 700) Nothing)
      , setSizeConstraintsCommand target (sizeConstraints (Extent 1 1) (Extent 2000 2000) (Just (AspectRatio 0 1)))
      , setSizeConstraintsCommand target (sizeConstraints (Extent 1 1) (Extent 2000 2000) (Just (AspectRatio 4 tooLarge)))
      , setSizeConstraintsCommand target excluding
      ]
  afterRejections ← current first
  callsAfterRejections ← controlCalls seam
  installed ← run (setSizeConstraintsCommand target valid)
  outside ← mapM (run . setWindowSizeCommand target) [Extent 2000 1500, Extent 801 600, Extent 300 225]
  admitted ← run (setWindowSizeCommand target (Extent 1200 900))
  calls ← controlCalls seam
  rejected
    `shouldBe` map
      (Rejected . ControlRejected target)
      [ ControlExtentRejected 0 48
      , ControlExtentRejected 64 (-1)
      , ControlExtentRejected tooLarge 48
      , ControlPlacementRejected tooLarge 0
      , ControlPlacementRejected 0 (negate tooLarge - 1)
      , ControlTitleRejected
      , ConstraintBoundRejected (Extent 0 10) (Extent 100 100)
      , ConstraintBoundRejected (Extent 10 10) (Extent tooLarge 100)
      , ConstraintBoundsInverted (Extent 900 500) (Extent 800 700)
      , AspectRatioRejected 0 1
      , AspectRatioRejected 4 tooLarge
      , ConstraintsExcludeCurrentSize (Extent 800 600) excluding
      ]
  -- A rejection carries no revision, and publishes none.
  observedRevision afterRejections `shouldBe` observedRevision before
  callsAfterRejections `shouldBe` []
  installed `shouldSatisfy` attemptedCleanly target
  outside
    `shouldBe` [Rejected (ControlRejected target (SizeOutsideConstraints size valid)) | size ← [Extent 2000 1500, Extent 801 600, Extent 300 225]]
  admitted `shouldSatisfy` attemptedCleanly target
  calls `shouldBe` [SetWindowSizeLimits 1 400 300 1600 1200, SetWindowAspectRatio 1 (Just (4, 3)), SetWindowSize 1 1200 900]
  where
    tooLarge = 2147483648

testUnservedWindows ∷ Expectation
testUnservedWindows = do
  seam ← newSeam defaultScript
  stash ← newIORef Nothing
  asProcessMainThread seam $ entered seam $ \session → do
    withWindow session (hiddenTestWindowConfig "closed" 32 24) (writeIORef stash . Just)
    -- Deliberate misuse: the handle escaped its scope to prove it is rejected.
    closed ← stashed stash
    withWindow session (hiddenTestWindowConfig "closing" 64 48) $ \closing →
      withWindow session (hiddenTestWindowConfig "unknown" 64 48) $ \unknown → do
        host ← newWindowCommandHost session 8
        began ← beginWindowClosing (pure ()) (pure True) closing
        let run = execute seam host [closed, closing]
            targets = map windowIdentity [unknown, closing, closed]
        titles ← mapM (\target → run (setWindowTitleCommand target "renamed")) targets
        maximized ← mapM (run . maximizeWindowCommand) targets
        calls ← controlCalls seam
        let expected =
              map Rejected [WindowNotServed (windowIdentity unknown), WindowIsClosing (windowIdentity closing), WindowAlreadyEnded (windowIdentity closed)]
        began `shouldBe` WindowAvailable True
        titles `shouldBe` expected
        maximized `shouldBe` expected
        calls `shouldBe` []

testModeTransition ∷ Expectation
testModeTransition = withTwo defaultScript $ \seam _ host first second → do
  let target = windowIdentity first
      run = execute seam host [first, second]
  seamSetModeTransition seam first True
  during ← mapM run [setWindowSizeCommand target (Extent 640 480), minimizeWindowCommand target, setWindowTitleCommand target "renamed"]
  observed ← run (observeWindowCommand target)
  other ← run (showWindowCommand (windowIdentity second))
  callsDuring ← controlCalls seam
  seamSetModeTransition seam first False
  after ← run (setWindowSizeCommand target (Extent 640 480))
  during `shouldBe` replicate 3 (Rejected (ControlRejected target ModeTransitionInProgress))
  observed `shouldSatisfy` \case
    Performed (ObservationPublished published _) → published == target
    _ → False
  other `shouldSatisfy` attemptedCleanly (windowIdentity second)
  callsDuring `shouldBe` [ShowWindow 2]
  after `shouldSatisfy` attemptedCleanly target

-- ---------------------------------------------------------------------------
-- Dispatch

-- | Every control, through the first window's own port and the real owner
-- loop over a seam session.
testDispatchEveryControl ∷ Expectation
testDispatchEveryControl = do
  seam ← newSeam defaultScript
  stage ← newIORef Nothing
  closing ← newIORef Nothing
  (settled, firstLatest, secondBefore, secondAfter, (afterClose, retainedPort)) ←
    hosted seam configuration $ \host control →
      looping host control $ \turn → case turnNumber turn of
        1 → do
          (first, second) ← twoClients host
          secondBefore ← latest (clientObservations second)
          tickets ← mapM (submit (clientCommandPort first)) (everyControl (clientWindow first))
          writeIORef stage (Just (first, second, secondBefore, tickets))
          pure Continue
        _ → do
          (first, second, secondBefore, tickets) ← slot stage
          settled ← mapM disposition tickets
          readIORef closing >>= \case
            Nothing
              | any isNothing settled → pure Continue
              | otherwise → do
                  started ← closeHostWindow host (clientWindow first)
                  when (started /= CloseStarted) (unexpected ("the first window's close answered " <> show started))
                  ticket ← submit (hostCommandPort host) (setWindowTitleCommand (clientWindow first) "after close")
                  retained ← submitWindowCommand (clientCommandPort first) [] (restoreWindowCommand (clientWindow first))
                  writeIORef closing (Just (ticket, retained))
                  pure Continue
            Just (ticket, retained) →
              disposition ticket >>= \case
                Nothing → pure Continue
                Just afterClose → do
                  firstLatest ← latest (clientObservations first)
                  secondAfter ← latest (clientObservations second)
                  pure (Finish (mapMaybe id settled, firstLatest, secondBefore, secondAfter, (afterClose, retained)))
  calls ← seamCalls seam
  let firstWindow = observedWindow firstLatest
      revisions = mapMaybe revisionOf settled
  length settled `shouldBe` 11
  filter (not . attemptedCleanly firstWindow) settled `shouldBe` []
  -- Each post-call sample published its own revision, in dispatch order.
  and (zipWith (<) revisions (drop 1 revisions)) `shouldBe` True
  all (<= observedRevision firstLatest) revisions `shouldBe` True
  filter isControl calls
    `shouldBe` [ SetWindowTitle 1 "renamed"
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
  sampledAfterEveryControl calls `shouldBe` True
  observedRevision secondAfter `shouldBe` observedRevision secondBefore
  afterClose `shouldBe` Rejected (WindowNotServed firstWindow)
  retainedPort `shouldBe` SubmitClosed
  where
    configuration =
      (defaultHostConfig [hiddenTestWindowConfig "first" 64 48, hiddenTestWindowConfig "second" 64 48])
        { hostCommandCapacity = 16
        , hostCommandBudget = 4
        , hostIdleWait = 0.01
        }

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

-- | Whether every control is followed, before the next control's calls, by a
-- logical size query: the post-call sample. A constraint update's size limits
-- and aspect ratio calls are one control, sampled once after both.
sampledAfterEveryControl ∷ [NativeCall] → Bool
sampledAfterEveryControl = sampled . filter (not . sizeLimits)
  where
    sizeLimits = \case
      SetWindowSizeLimits {} → True
      _ → False
    sampled = \case
      [] → True
      call : rest
        | isControl call → case break isControl rest of
            (between, later) → QueryWindowSize `elem` between && sampled later
        | otherwise → sampled rest

-- ---------------------------------------------------------------------------
-- Honest outcomes

testUnsupported ∷ Expectation
testUnsupported = withTwo defaultScript {scriptWindowCapabilities = const (backendWindowCapabilities Wayland)} $ \seam session host first _ → do
  let target = windowIdentity first
      run = execute seam host [first]
  moved ← run (setWindowPositionCommand target (Placement 10 20))
  focused ← run (requestFocusCommand target)
  titled ← run (setWindowTitleCommand target "still supported")
  _ ← seamDrive seam first DuringPoll [MovedTo 5 5, IconifyChanged True]
  observation ← current first
  calls ← seamCalls seam
  let capabilities = sessionWindowCapabilities session
  map fst (unperformableOperations capabilities) `shouldBe` [SetPositionOperation, FocusOperation, BorderlessOperation]
  map fst (unreportableAttributes capabilities) `shouldBe` [PlacementReport, IconifiedReport]
  moved `shouldSatisfy` unsupportedWith target SetPositionOperation
  focused `shouldSatisfy` unsupportedWith target FocusOperation
  titled `shouldSatisfy` attemptedCleanly target
  (observedPlacement observation, observedIconified observation) `shouldBe` (Unavailable, Unavailable)
  filter isControl calls `shouldBe` [SetWindowTitle 1 "still supported"]
  filter (`elem` [QueryWindowPosition, QueryWindowAttribute IconifiedAttribute]) calls `shouldBe` []
  where
    unsupportedWith target wanted = \case
      Unsupported (UnsupportedControl window operation reason) → window == target && operation == wanted && reason /= ""
      _ → False

-- | The audited Wayland row, against the whole vocabulary rather than the
-- entries it happens to list.
--
-- Of GLFW 3.4's thirteen window operations and eight window reports, the
-- pinned Wayland backend answers @GLFW_FEATURE_UNAVAILABLE@ for the global
-- window position it can neither set nor read, which also denies a borderless
-- placement over a monitor, and always answers false for the iconified
-- attribute; focus is left to the compositor. Everything else it performs or
-- reports. The operations GLFW also refuses on Wayland — the window icon,
-- floating, opacity, and the cursor position — are outside this vocabulary, so
-- the audit adds none of them, and it invents no restriction GLFW does not
-- report. @docs/glfw.md@ records the audit with GLFW's answer cited per entry.
testWaylandCapabilityAudit ∷ Expectation
testWaylandCapabilityAudit = do
  let wayland = backendWindowCapabilities Wayland
      unperformable = unperformableOperations wayland
      unreportable = unreportableAttributes wayland
  -- Every constructor is accounted for: each is either performable or carries
  -- a reason, and nothing outside the vocabulary is listed.
  map fst unperformable `shouldBe` [SetPositionOperation, FocusOperation, BorderlessOperation]
  map fst unreportable `shouldBe` [PlacementReport, IconifiedReport]
  filter (`notElem` map fst unperformable) [minBound .. maxBound]
    `shouldBe` [ SetTitleOperation
               , SetSizeOperation
               , SetConstraintsOperation
               , ShowOperation
               , HideOperation
               , AttentionOperation
               , MinimizeOperation
               , MaximizeOperation
               , RestoreOperation
               , FullscreenOperation
               ]
  filter (`notElem` map fst unreportable) [minBound .. maxBound]
    `shouldBe` [ LogicalExtentReport
               , FramebufferExtentReport
               , ContentScaleReport
               , FocusedReport
               , MaximizedReport
               , VisibleReport
               ]
  -- Nothing is restricted without a reason, and the backends that restrict
  -- nothing say so by listing nothing at all.
  map snd unperformable `shouldSatisfy` all (/= "")
  map snd unreportable `shouldSatisfy` all (/= "")
  mapM_
    ( \backend → do
        map fst (unperformableOperations (backendWindowCapabilities backend)) `shouldBe` []
        map fst (unreportableAttributes (backendWindowCapabilities backend)) `shouldBe` []
    )
    [X11, Cocoa]

testNativeErrorAttribution ∷ Expectation
testNativeErrorAttribution = do
  let script =
        defaultScript
          { scriptWindowControl = \call reporter → case call of
              SetWindowTitle _ "faulty" → reportError reporter platformErrorCode "The title could not be set"
              SetWindowTitle _ "unrelated" → reportErrorFromOtherThread reporter platformErrorCode "An unrelated thread failed"
              _ → pure ()
          }
  withTwo script $ \seam session host first second → do
    let port = windowCommandPort host
    faulty ← submitWindowCommand port [("client", "faulty")] (setWindowTitleCommand (windowIdentity first) "faulty") >>= accepted
    clean ← submitWindowCommand port [("client", "clean")] (setWindowTitleCommand (windowIdentity second) "unrelated") >>= accepted
    firstStep ← seamExecuteNext seam host [first, second]
    secondStep ← seamExecuteNext seam host [first, second]
    asynchronous ← takeAsynchronousReports session
    case firstStep of
      Executed origin (Attempted (ControlAttempt window (ControlNativeError failed reports) (PostCallRevision _))) → do
        origin `shouldBe` ticketOrigin faulty
        submittedContext origin `shouldBe` [("client", "faulty")]
        window `shouldBe` windowIdentity first
        failed `shouldBe` "set window title"
        [(nativeErrorCode reported, nativeErrorDescription reported) | reported ← reportedErrors reports]
          `shouldBe` [(platformErrorCode, "The title could not be set")]
      other → unexpected ("the faulty title did not settle as a native error: " <> show other)
    case secondStep of
      Executed origin settled → do
        origin `shouldBe` ticketOrigin clean
        submittedContext origin `shouldBe` [("client", "clean")]
        settled `shouldSatisfy` attemptedCleanly (windowIdentity second)
      other → unexpected ("the unrelated title was not executed: " <> show other)
    map nativeErrorDescription (reportedErrors asynchronous) `shouldBe` ["An unrelated thread failed"]

testConstraintUpdateFailure ∷ Expectation
testConstraintUpdateFailure = do
  failing ← newIORef Nothing
  let script =
        defaultScript
          { scriptWindowControl = \call reporter → do
              wanted ← readIORef failing
              when (wanted == constraintCallOf call && wanted /= Nothing) $
                reportError reporter platformErrorCode "The constraint call failed"
          }
  withTwo script $ \seam _ host first second → do
    let target = windowIdentity first
        run = execute seam host [first, second]
        wanted = sizeConstraints (Extent 400 300) (Extent 1600 1200) (Just (AspectRatio 4 3))
        indeterminate = Rejected (ControlRejected target ActiveConstraintsIndeterminate)
    writeIORef failing (Just AspectRatioCall)
    partial ← run (setSizeConstraintsCommand target wanted)
    afterPartial ← controlCalls seam
    refused ← run (setWindowSizeCommand target (Extent 1024 768))
    afterRefusal ← controlCalls seam
    otherWindow ← run (setWindowSizeCommand (windowIdentity second) (Extent 1024 768))
    writeIORef failing (Just SizeLimitsCall)
    firstCallFailed ← run (setSizeConstraintsCommand target wanted)
    stillRefused ← run (setWindowSizeCommand target (Extent 1024 768))
    writeIORef failing Nothing
    restored ← run (setSizeConstraintsCommand target wanted)
    admitted ← run (setWindowSizeCommand target (Extent 1024 768))
    outside ← run (setWindowSizeCommand target (Extent 2000 1500))
    partial `shouldSatisfy` failedUpdate target [SizeLimitsCall] AspectRatioCall []
    -- Nothing was rolled back: no call followed the one that failed.
    afterPartial `shouldBe` [SetWindowSizeLimits 1 400 300 1600 1200, SetWindowAspectRatio 1 (Just (4, 3))]
    refused `shouldBe` indeterminate
    afterRefusal `shouldBe` afterPartial
    otherWindow `shouldSatisfy` attemptedCleanly (windowIdentity second)
    firstCallFailed `shouldSatisfy` failedUpdate target [] SizeLimitsCall [AspectRatioCall]
    stillRefused `shouldBe` indeterminate
    restored `shouldSatisfy` attemptedCleanly target
    admitted `shouldSatisfy` attemptedCleanly target
    outside `shouldBe` Rejected (ControlRejected target (SizeOutsideConstraints (Extent 2000 1500) wanted))
  where
    constraintCallOf = \case
      SetWindowSizeLimits {} → Just SizeLimitsCall
      SetWindowAspectRatio {} → Just AspectRatioCall
      _ → Nothing
    failedUpdate target returned failed unattempted = \case
      Attempted (ControlAttempt window (ConstraintUpdateFailed returned' failed' unattempted' reports) (PostCallRevision _)) →
        window == target
          && (returned', failed', unattempted') == (returned, failed, unattempted)
          && map nativeErrorDescription (reportedErrors reports) == ["The constraint call failed"]
      _ → False

testPostCallRevisions ∷ Expectation
testPostCallRevisions = withTwo defaultScript $ \seam _ host first _ → do
  let target = windowIdentity first
      run = execute seam host [first]
  initial ← current first
  shown ← run (showWindowCommand target)
  -- Nothing the sample reads changes, and a new revision is published anyway.
  shownAgain ← run (showWindowCommand target)
  _ ← seamDrive seam first DuringPoll [ResizedTo 1024 768]
  newest ← atomically (readSnapshot (windowObservations first))
  case (revisionOf shown, revisionOf shownAgain) of
    (Just revision, Just again) → do
      revision `shouldSatisfy` (> observedRevision initial)
      again `shouldSatisfy` (> revision)
      -- The client reads only the latest publication, which has moved on.
      cursorRevision (observedCursor newest) `shouldSatisfy` (> again)
      observedLogicalExtent (preparedValue (observedValue newest)) `shouldBe` Observed (Extent 1024 768)
    other → unexpected ("the controls named no post-call revisions: " <> show other)

-- ---------------------------------------------------------------------------
-- Support

-- | A seam session with two hidden windows and a command host, on the
-- designated process main thread. The first window's scripted key is one and
-- the second's two.
withTwo ∷ SeamScript → (Seam → Session → WindowCommandHost → Window → Window → IO a) → IO a
withTwo script body = do
  seam ← newSeam script
  asProcessMainThread seam $ entered seam $ \session →
    withWindow session (hiddenTestWindowConfig "first" 64 48) $ \first →
      withWindow session (hiddenTestWindowConfig "second" 64 48) $ \second → do
        host ← newWindowCommandHost session 16
        body seam session host first second

-- | Submit one command and execute it at once, answering its disposition.
execute ∷ Seam → WindowCommandHost → [Window] → WindowCommand → IO Disposition
execute seam host windows command = do
  ticket ← submitWindowCommand (windowCommandPort host) [("client", "controls")] command >>= accepted
  seamExecuteNext seam host windows >>= \case
    Executed origin settled | origin == ticketOrigin ticket → pure settled
    other → unexpected ("the submitted command was not the one executed: " <> show other)

attemptedCleanly ∷ WindowId → Disposition → Bool
attemptedCleanly target = \case
  Attempted (ControlAttempt window ControlReturned (PostCallRevision _)) → window == target
  _ → False

revisionOf ∷ Disposition → Maybe Natural
revisionOf = \case
  Attempted (ControlAttempt _ _ (PostCallRevision revision)) → Just revision
  _ → Nothing

controlCalls ∷ Seam → IO [NativeCall]
controlCalls seam = filter isControl <$> seamCalls seam

isControl ∷ NativeCall → Bool
isControl = \case
  SetWindowTitle {} → True
  SetWindowSize {} → True
  SetWindowPosition {} → True
  SetWindowSizeLimits {} → True
  SetWindowAspectRatio {} → True
  ShowWindow _ → True
  HideWindow _ → True
  FocusWindow _ → True
  RequestWindowAttention _ → True
  IconifyWindow _ → True
  MaximizeWindow _ → True
  RestoreWindow _ → True
  _ → False

accepted ∷ SubmitResult → IO CompletionTicket
accepted (SubmitAccepted ticket) = pure ticket
accepted other = unexpected ("the submission was not admitted: " <> show other)

submit ∷ WindowCommandPort → WindowCommand → IO CompletionTicket
submit port command = submitWindowCommand port [] command >>= accepted

disposition ∷ CompletionTicket → IO (Maybe Disposition)
disposition = atomically . pollCompletion

latest ∷ SnapshotReader WindowObservation → IO WindowObservation
latest reader = preparedValue . observedValue <$> atomically (readSnapshot reader)

slot ∷ IORef (Maybe a) → IO a
slot ref = readIORef ref >>= maybe (unexpected "nothing was stored by an earlier turn") pure

twoClients ∷ WindowHost → IO (WindowClient, WindowClient)
twoClients host = do
  listed ← atomically (hostWindowIdentities host)
  found ← forM listed $ \window → atomically (hostWindowClient host window)
  case found of
    [Just first, Just second] → pure (first, second)
    _ → unexpected ("expected two windows, found " <> show (length found))

-- | Run an application over a host in the seam's session, on a bound thread
-- designated as the process main thread.
hosted ∷ Seam → HostConfig → (WindowHost → RuntimeControl → IO a) → IO a
hosted seam config =
  asProcessMainThread seam
    . runWindowApplication lifetime "control-example" (allocWindowHostIn (seamSession seam defaultSessionConfig) config) id (\host _ → pure host)

-- | The owner loop with no application events, failing past its turn bound.
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
