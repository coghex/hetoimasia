-- | Examples for the Wayland connection-status probe, over the test seam.
--
-- The probe is scripted: each example holds the status the scripted library's
-- probe answers in an 'IORef', and changes it from inside a scripted poll or
-- wait exactly where a compositor would disappear, or before the next
-- processing for a loss that has already happened. The session model — when
-- the probe is resolved, where it runs, what a status other than healthy
-- raises, and that the failure is latched — is the production code, and the
-- seam records every 'ResolveConnectionProbe' and 'ProbeConnection' beside the
-- other native calls, so each example shows the probe running exactly where
-- the contract puts it and nowhere else.
--
-- Close requests are the seam's own 'CloseRequested' events, delivered from
-- inside a poll as GLFW delivers them; its disconnect path, which issues one
-- for every window and reports nothing, is scripted the same way. The
-- application policy that rejects them is 'seamRejectCloseRequest'.
module Test.GLFW.Connection (spec) where

import Control.Exception (displayException)
import Control.Monad (void, when)
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Hetoimasia.Foundation.Resource (withScoped)
import Hetoimasia.GLFW.Internal.Connection (ConnectionStatus (..))
import Hetoimasia.GLFW.Internal.Window (EventProcessing (..), processWindowEvents)
import Hetoimasia.GLFW.Internal.Seam
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window
  ( Window
  , WindowObservation
  , WindowResult (..)
  , closeRequestWindow
  , hiddenTestWindowConfig
  , observedCloseRequest
  , synchronizeWindow
  , windowIdentity
  , withWindow
  )
import Test.GLFW.Support (boundedExample, caughtAs, originOf, unexpected)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldContain, shouldNotBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "GLFW Wayland connection status" $ do
  describe "the probe" $ do
    it "is resolved at Wayland entry and consulted before and after every poll and wait, with no window and with one"
      (boundedExample testHealthyAtBothBoundaries)
    it "is neither resolved nor consulted by an X11 or a Cocoa session"
      (boundedExample testNoProbeOffWayland)
    it "refuses a Wayland session whose library cannot supply it, attributed to initialization, and terminates GLFW"
      (boundedExample testMissingProbeRefusesWayland)

  describe "a confirmed loss" $ do
    it "ends the session when the connection is lost with close requests pending that the application rejects"
      (boundedExample testLossWithRejectedCloseRequests)
    it "ends a session that has no windows"
      (boundedExample testLossWithoutWindows)
    it "ends the session when the connection is lost while the owner is inside a native wait"
      (boundedExample testLossInsideWait)
    it "is not mistaken for an ordinary close request on a healthy connection, which the session survives"
      (boundedExample testHealthyCloseRequestIsNotLoss)
    it "reports a transport closure, a protocol failure, and a probe failure each as itself"
      (boundedExample testCausesDistinguished)
    it "keeps what GLFW reported during the processing beside the cause rather than in its place"
      (boundedExample testReportsKeptBesideCause)

-- ---------------------------------------------------------------------------
-- The probe

testHealthyAtBothBoundaries ∷ Expectation
testHealthyAtBothBoundaries = do
  (seam, _) ← waylandSeam
  asProcessMainThread seam . wayland seam $ \session → do
    processWindowEvents session ProcessPending
    processWindowEvents session (AwaitEventsFor 0.5)
    withWindow session (hiddenTestWindowConfig "probed" 64 48) $ \_ → do
      processWindowEvents session ProcessPending
      processWindowEvents session (AwaitEventsFor 0.5)
  calls ← seamCalls seam
  -- Resolved once, right after the backend was verified.
  takeWhile (/= ResolveConnectionProbe) calls `shouldSatisfy` (QueryPlatform `elem`)
  length (filter (== ResolveConnectionProbe) calls) `shouldBe` 1
  -- Each pump bracketed by one status read on either side, and no other.
  pumpsAndProbes calls
    `shouldBe` concat (replicate 2 [ProbeConnection, PollEvents, ProbeConnection, ProbeConnection, WaitEvents 0.5, ProbeConnection])

testNoProbeOffWayland ∷ Expectation
testNoProbeOffWayland =
  mapM_
    ( \script → do
        seam ← newSeam script {scriptConnectionProbe = Right (unexpected "an X11 or Cocoa session ran the probe")}
        backend ← asProcessMainThread seam . withScoped (seamSession seam defaultSessionConfig) $ \session → do
          processWindowEvents session ProcessPending
          processWindowEvents session (AwaitEventsFor 0.5)
          withWindow session (hiddenTestWindowConfig "unprobed" 64 48) (\_ → processWindowEvents session ProcessPending)
          pure (sessionBackend session)
        calls ← seamCalls seam
        filter (`elem` [ResolveConnectionProbe, ProbeConnection]) calls `shouldBe` []
        pumpsAndProbes calls `shouldBe` [PollEvents, WaitEvents 0.5, PollEvents]
        backend `shouldNotBe` Wayland
    )
    [defaultScript, defaultScript {scriptHostBackend = Just Cocoa, scriptAdmittedBackends = [Cocoa]}]

testMissingProbeRefusesWayland ∷ Expectation
testMissingProbeRefusesWayland = do
  seam ← newSeam defaultScript {scriptConnectionProbe = Left "the scripted library has no probe"}
  (refused, caught) ←
    asProcessMainThread seam (caughtAs (withScoped (seamSession seam waylandConfig) (\_ → pure ())))
  refused `shouldBe` ConnectionProbeUnavailable "the scripted library has no probe"
  originOf caught `shouldBe` Just ("glfw", "initialize", [("backend", "wayland")])
  seamCalls seam
    `shouldReturn` [ QueryPlatformSupported Wayland
                   , CreateErrorCallback
                   , AttachErrorCallback
                   , SetInitHints Wayland
                   , Initialize
                   , QueryPlatform
                   , ResolveConnectionProbe
                   , Terminate
                   , DetachErrorCallback
                   , FreeErrorCallback
                   ]
  seamLiveCallbacks seam `shouldReturn` 0
  -- The refusal rolled back completely: the same platform still enters X11.
  asProcessMainThread seam (withScoped (seamSession seam defaultSessionConfig) (pure . sessionBackend))
    `shouldReturn` X11

-- ---------------------------------------------------------------------------
-- A confirmed loss

-- | GLFW's disconnect path, scripted: the poll that finds the connection gone
-- issues a close request to every window and reports nothing. The application
-- has already rejected an ordinary close request, and would reject these too;
-- the probe after the poll confirms the loss anyway.
testLossWithRejectedCloseRequests ∷ Expectation
testLossWithRejectedCloseRequests = do
  status ← newIORef ConnectionHealthy
  disconnecting ← newIORef False
  seam ←
    newSeam
      defaultScript
        { scriptConnectionProbe = Right (readIORef status)
        , -- The compositor goes during this poll; the close requests queued
          -- for it are then delivered from inside the same call.
          scriptPollEvents = \_ → do
            gone ← readIORef disconnecting
            when gone (atomicWriteIORef status (ConnectionEnded (TransportClosed (Just 32))))
        }
  (failure, caught, rejected, pending, identities, afterCalls) ←
    asProcessMainThread seam . wayland seam $ \session →
      withWindow session (hiddenTestWindowConfig "first" 64 48) $ \first →
        withWindow session (hiddenTestWindowConfig "second" 64 48) $ \second → do
          -- An ordinary close request on a healthy connection, which the
          -- application rejects.
          seamQueueEvents seam first [CloseRequested]
          processWindowEvents session ProcessPending
          request ← synchronized first >>= maybe (unexpected "no close request surfaced") pure . observedCloseRequest
          rejected ← seamRejectCloseRequest seam first request
          -- GLFW's disconnect path: a close request to every window from the
          -- poll that loses the connection, and no report.
          seamQueueEvents seam first [CloseRequested]
          seamQueueEvents seam second [CloseRequested]
          atomicWriteIORef disconnecting True
          (failure, caught) ← caughtAs (processWindowEvents session ProcessPending)
          -- The requests are there for the application, which rejects them
          -- as it rejects every ordinary request; that changes nothing.
          pending ← mapM (fmap (fmap closeRequestWindow . (>>= observedCloseRequest)) . synchronizedMaybe) [first, second]
          mapM_
            (\window → synchronized window >>= mapM_ (void . seamRejectCloseRequest seam window) . observedCloseRequest)
            [first, second]
          before ← length <$> seamCalls seam
          (again, _) ← caughtAs (processWindowEvents session ProcessPending)
          after ← length <$> seamCalls seam
          again `shouldBe` failure
          pure (failure, caught, rejected, pending, map windowIdentity [first, second], after - before)
  rejected `shouldBe` WindowAvailable True
  connectionCause failure `shouldBe` TransportClosed (Just 32)
  connectionBoundary failure `shouldBe` AfterEvents
  originOf caught `shouldBe` Just ("glfw", "process window events", [("events", "poll")])
  pending `shouldBe` map Just identities
  -- Terminal: the later processing raised the latched failure with no call.
  afterCalls `shouldBe` 0

-- | A loss with no window at all, found by the probe before the poll: nothing
-- is pumped on the lost connection.
testLossWithoutWindows ∷ Expectation
testLossWithoutWindows = do
  (seam, status) ← waylandSeam
  (failure, before, after) ←
    asProcessMainThread seam . wayland seam $ \session → do
      processWindowEvents session ProcessPending
      atomicWriteIORef status (ConnectionEnded (TransportClosed Nothing))
      before ← seamCalls seam
      (failure, _) ← caughtAs (processWindowEvents session (AwaitEventsFor 0.5))
      after ← seamCalls seam
      pure (failure, length before, drop (length before) after)
  connectionCause failure `shouldBe` TransportClosed Nothing
  connectionBoundary failure `shouldBe` BeforeEvents
  -- One status read, and no wait on the lost connection.
  after `shouldBe` [ProbeConnection]
  before `shouldSatisfy` (> 0)

-- | The owner is inside the scripted wait when the connection goes, and the
-- wait returns; the probe after it confirms the loss.
testLossInsideWait ∷ Expectation
testLossInsideWait = do
  status ← newIORef ConnectionHealthy
  seam ←
    newSeam
      defaultScript
        { scriptConnectionProbe = Right (readIORef status)
        , scriptWaitEvents = \_ _ → atomicWriteIORef status (ConnectionEnded (TransportClosed (Just 32)))
        }
  (failure, calls) ←
    asProcessMainThread seam . wayland seam $ \session →
      withWindow session (hiddenTestWindowConfig "waiting" 64 48) $ \_ → do
        (failure, _) ← caughtAs (processWindowEvents session (AwaitEventsFor 30))
        (failure,) <$> seamCalls seam
  connectionCause failure `shouldBe` TransportClosed (Just 32)
  connectionBoundary failure `shouldBe` AfterEvents
  reverse (take 3 (reverse (pumpsAndProbes calls))) `shouldBe` [ProbeConnection, WaitEvents 30, ProbeConnection]

-- | The negative control: an ordinary close request on a healthy connection is
-- the application's to reject, and the session goes on.
testHealthyCloseRequestIsNotLoss ∷ Expectation
testHealthyCloseRequestIsNotLoss = do
  (seam, _) ← waylandSeam
  (rejected, surfaced, identity, afterward) ←
    asProcessMainThread seam . wayland seam $ \session →
      withWindow session (hiddenTestWindowConfig "asked to close" 64 48) $ \window → do
        seamQueueEvents seam window [CloseRequested]
        processWindowEvents session ProcessPending
        request ← synchronized window >>= maybe (unexpected "no close request surfaced") pure . observedCloseRequest
        rejected ← seamRejectCloseRequest seam window request
        processWindowEvents session ProcessPending
        processWindowEvents session (AwaitEventsFor 0.5)
        afterward ← synchronizeWindow window
        pure (rejected, closeRequestWindow request, windowIdentity window, afterward)
  rejected `shouldBe` WindowAvailable True
  surfaced `shouldBe` identity
  afterward `shouldSatisfy` \case
    WindowAvailable _ → True
    WindowEnded _ → False
  -- Healthy at both boundaries of all three pumps.
  calls ← seamCalls seam
  length (filter (== ProbeConnection) calls) `shouldBe` 6

testCausesDistinguished ∷ Expectation
testCausesDistinguished = do
  outcomes ←
    mapM
      ( \cause → do
          (seam, status) ← waylandSeam
          asProcessMainThread seam . wayland seam $ \session → do
            atomicWriteIORef status (ConnectionEnded cause)
            (failure, caught) ← caughtAs (processWindowEvents session ProcessPending)
            pure (connectionCause failure, displayed caught, originOf caught)
      )
      [TransportClosed (Just 32), ProtocolFailure, ProbeFailure "the scripted poll failed"]
  map (\(cause, _, _) → cause) outcomes
    `shouldBe` [TransportClosed (Just 32), ProtocolFailure, ProbeFailure "the scripted poll failed"]
  case map (\(_, shown, _) → shown) outcomes of
    [transport, protocol, probe] → do
      transport `shouldContain` "transport closed"
      protocol `shouldContain` "protocol error"
      probe `shouldContain` "probe failed"
      probe `shouldContain` "the scripted poll failed"
      mapM_ (`shouldContain` "terminal") [transport, protocol, probe]
    other → unexpected ("expected three failures, found " <> show (length other))
  map (\(_, _, origin) → origin) outcomes
    `shouldBe` replicate 3 (Just ("glfw", "process window events", [("events", "poll")]))
  where
    displayed = displayException

-- | A poll that reports an error and loses the connection fails with the loss,
-- carrying the report, not with a native failure that hides it.
testReportsKeptBesideCause ∷ Expectation
testReportsKeptBesideCause = do
  status ← newIORef ConnectionHealthy
  seam ←
    newSeam
      defaultScript
        { scriptConnectionProbe = Right (readIORef status)
        , scriptPollEvents = \reporter → do
            reportError reporter 0x00010008 "Wayland: scripted flush failure"
            atomicWriteIORef status (ConnectionEnded (TransportClosed (Just 32)))
        }
  failure ←
    asProcessMainThread seam . wayland seam $ \session →
      fst <$> caughtAs (processWindowEvents session ProcessPending)
  connectionCause failure `shouldBe` TransportClosed (Just 32)
  map nativeErrorDescription (reportedErrors (connectionReports failure))
    `shouldBe` ["Wayland: scripted flush failure"]

-- ---------------------------------------------------------------------------
-- Helpers

waylandConfig ∷ SessionConfig
waylandConfig = defaultSessionConfig {requestedBackend = Just Wayland}

-- | A Linux seam whose probe answers the status held in the returned 'IORef'.
waylandSeam ∷ IO (Seam, IORef ConnectionStatus)
waylandSeam = do
  status ← newIORef ConnectionHealthy
  seam ← newSeam defaultScript {scriptConnectionProbe = Right (readIORef status)}
  pure (seam, status)

-- | Enter a Wayland session over the seam.
wayland ∷ Seam → (Session → IO r) → IO r
wayland seam = withScoped (seamSession seam waylandConfig)

-- | The pumps and status reads, in order, without anything else.
pumpsAndProbes ∷ [NativeCall] → [NativeCall]
pumpsAndProbes = filter $ \case
  PollEvents → True
  WaitEvents _ → True
  ProbeConnection → True
  _ → False

synchronized ∷ Window → IO WindowObservation
synchronized window =
  synchronizeWindow window >>= \case
    WindowAvailable observation → pure observation
    WindowEnded _ → unexpected "a live window answered as ended"

synchronizedMaybe ∷ Window → IO (Maybe WindowObservation)
synchronizedMaybe window =
  synchronizeWindow window >>= \case
    WindowAvailable observation → pure (Just observation)
    WindowEnded _ → pure Nothing
