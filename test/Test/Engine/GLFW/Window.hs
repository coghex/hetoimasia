-- | Examples for scoped GLFW windows, driven through the private test seam.
--
-- Windows are created with the public "Hetoimasia.GLFW.Window" interface in a
-- session over "Hetoimasia.GLFW.Seam"'s scripted native library, which creates
-- nothing real: validation, hint handling, staged construction, observation,
-- callback containment, and release are the production model's. Callback
-- events are delivered by 'seamDrive' from inside an owner-boundary step, as
-- GLFW delivers them from inside a setter or a poll, and close-request
-- rejection goes through the model's private transition. Neither is a public
-- command.
--
-- The scripted library answers every query with values deliberately different
-- from every request, so an observation that copied its request would be seen.
-- Threads are coordinated with 'MVar's, never with a sleep.
module Test.Engine.GLFW.Window (spec) where

import Control.Concurrent (ThreadId, forkOS)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ErrorCall (ErrorCall)
  , Exception
  , IOException
  , SomeException
  , displayException
  , fromException
  , throwIO
  , toException
  , try
  )
import Control.Monad (forM)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.Text (Text)
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , OperationContext (..)
  , failureEvidence
  , operationText
  )
import Hetoimasia.Foundation.Log (componentText)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot
  ( Update (..)
  , awaitSnapshot
  , cursorRevision
  , observedCursor
  , observedValue
  , readSnapshot
  )
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailures, withScoped)
import Hetoimasia.GLFW.Seam
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window
import System.Timeout (timeout)
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldNotBe
  , shouldReturn
  )

spec ∷ Spec
spec = do
  describe "GLFW window creation" $ do
    it "rejects invalid dimensions and titles before any conversion or native call"
      (boundedExample testInvalidConfigRejected)
    it "resets every creation hint and sets each explicitly before every window"
      (boundedExample testHintsResetPerWindow)
    it "publishes sampled geometry, never the request, and releases in the declared order"
      (boundedExample testCreateObserveRelease)

  describe "GLFW window observations" $ do
    it "coalesces callback captures into one new revision at the owner boundary"
      (boundedExample testCallbacksCoalesce)
    it "represents an attribute the platform cannot provide as unavailable, and accepts a zero framebuffer"
      (boundedExample testUnavailableAndZeroFramebuffer)
    it "publishes a new revision for a refresh even when every attribute is unchanged"
      (boundedExample testRefreshAdvancesRevision)

  describe "GLFW window close requests" $ do
    it "latches close intent with its own identity, never destroys, and keeps a newer request past an older rejection"
      (boundedExample testCloseIntent)

  describe "GLFW window callback containment" $ do
    it "rethrows a fault raised during a setter or a poll at the owner boundary with its context"
      (boundedExample testCallbackFaults)

  describe "GLFW window lifetime" $ do
    it "keeps two live windows independent and never lets a later window answer to an ended handle"
      (boundedExample testIndependentWindows)
    it "rejects window operations from another thread before any native call"
      (boundedExample testOwnerOnly)

  describe "GLFW window release failures" $ do
    it "rolls back a failed initial sampling, then creates another window in the same session"
      (boundedExample testSamplingFailureRollsBack)
    it "keeps callback storage and poisons the session when attaching callbacks raises"
      (boundedExample testAttachFailurePoisons)
    it "keeps callback storage and poisons the session when detaching callbacks raises"
      (boundedExample (testUncertainRelease detachRaises "glfw window callbacks"))
    it "keeps callback storage and poisons the session when destroying the window raises"
      (boundedExample (testUncertainRelease destroyRaises "glfw window"))
    it "retains a native error reported by a destroy that returned, without poisoning"
      (boundedExample testDestroyReportRetained)

-- ---------------------------------------------------------------------------
-- Creation

testInvalidConfigRejected ∷ Expectation
testInvalidConfigRejected = do
  seam ← newSeam defaultScript
  let beyond = fromIntegral (maxBound ∷ Int32) + 1
      configs =
        [ hiddenTestWindowConfig "zero" 0 48
        , hiddenTestWindowConfig "negative" 64 (-1)
        , hiddenTestWindowConfig "beyond" beyond 48
        , hiddenTestWindowConfig "nul\NULtitle" 64 48
        ]
  rejections ← asProcessMainThread seam $ entered seam $ \session →
    forM configs $ \config → do
      (rejected, caught) ← caughtAs (withWindow session config (\_ → pure ()))
      pure (rejected, operationOf caught)
  map fst rejections
    `shouldBe` [ WindowExtentRejected 0 48
               , WindowExtentRejected 64 (-1)
               , WindowExtentRejected beyond 48
               , WindowTitleRejected
               ]
  map snd rejections `shouldBe` replicate 4 (Just ("glfw", "create window"))
  map validateWindowConfig configs `shouldBe` map (Left . fst) rejections
  validateWindowConfig (hiddenTestWindowConfig "largest" (fromIntegral (maxBound ∷ Int32)) 1) `shouldBe` Right ()
  seamCalls seam `shouldReturn` entryCalls <> exitCalls

testHintsResetPerWindow ∷ Expectation
testHintsResetPerWindow = do
  seam ← newSeam defaultScript
  asProcessMainThread seam $ entered seam $ \session → do
    withWindow session (defaultWindowConfig "shown" 32 24) (\_ → pure ())
    withWindow session (hiddenTestWindowConfig "hidden" 64 48) (\_ → pure ())
  calls ← seamCalls seam
  [call | call ← calls, isHintCall call]
    `shouldBe` [ ResetWindowHints
               , SetWindowHint NoClientApi
               , SetWindowHint (VisibleHint True)
               , SetWindowHint (FocusedHint True)
               , SetWindowHint (FocusOnShowHint True)
               , CreateWindow 32 24 "shown"
               , ResetWindowHints
               , SetWindowHint NoClientApi
               , SetWindowHint (VisibleHint False)
               , SetWindowHint (FocusedHint False)
               , SetWindowHint (FocusOnShowHint False)
               , CreateWindow 64 48 "hidden"
               ]
  where
    isHintCall call = case call of
      ResetWindowHints → True
      SetWindowHint _ → True
      CreateWindow {} → True
      _ → False

testCreateObserveRelease ∷ Expectation
testCreateObserveRelease = do
  seam ← newSeam defaultScript
  stash ← newIORef Nothing
  (initial, final, terminal, ended, afterEnd, driveAfterEnd, endOfStream) ←
    asProcessMainThread seam $ entered seam $ \session → do
      initial ← withWindow session (hiddenTestWindowConfig "observed" 64 48) $ \window → do
        writeIORef stash (Just window)
        current window
      -- Deliberate misuse: the handle escaped its scope to prove it is terminal.
      window ← stashed stash
      callsAtEnd ← length <$> seamCalls seam
      afterEnd ← synchronizeWindow window
      driveAfterEnd ← seamDrive seam window DuringPoll [CloseRequested]
      callsAfter ← length <$> seamCalls seam
      callsAfter `shouldBe` callsAtEnd
      observation ← atomically (readSnapshot (windowObservations window))
      next ← atomically (awaitSnapshot (windowObservations window) (observedCursor observation))
      ended ← windowEnded window
      let final = preparedValue (observedValue observation)
          endOfStream = case next of
            EndOfStream → True
            Updated _ → False
      pure (initial, final, windowIdentity window, ended, afterEnd, driveAfterEnd, endOfStream)
  observedWindow initial `shouldBe` terminal
  windowLocalIdentity terminal `shouldBe` 1
  observedRevision initial `shouldBe` 0
  observedPhase initial `shouldBe` WindowOpen
  observedLogicalExtent initial `shouldBe` Observed (Extent 800 600)
  observedFramebufferExtent initial `shouldBe` Observed (Extent 1600 1200)
  observedContentScale initial `shouldBe` Observed (ContentScale 2 2)
  observedPlacement initial `shouldBe` Observed (Placement 40 30)
  map ($ initial) [observedFocused, observedIconified, observedMaximized, observedVisible]
    `shouldBe` replicate 4 (Observed False)
  observedCloseRequest initial `shouldBe` Nothing

  observedPhase final `shouldBe` WindowReleased
  observedRevision final `shouldBe` 1
  observedLogicalExtent final `shouldBe` observedLogicalExtent initial
  observedFramebufferExtent final `shouldBe` observedFramebufferExtent initial
  ended `shouldBe` True
  afterEnd `shouldBe` WindowEnded terminal
  driveAfterEnd `shouldBe` WindowEnded terminal
  endOfStream `shouldBe` True
  seamCalls seam
    `shouldReturn` concat [entryCalls, creationCalls "observed" 64 48 1, releaseCalls 1, exitCalls]
  seamLiveWindowCallbacks seam `shouldReturn` 0

-- ---------------------------------------------------------------------------
-- Observations

testCallbacksCoalesce ∷ Expectation
testCallbacksCoalesce = do
  seam ← newSeam defaultScript
  (initial, driven, after, cursor, idle, unchanged) ←
    asProcessMainThread seam $ entered seam $ \session →
      withWindow session (hiddenTestWindowConfig "coalesced" 64 48) $ \window → do
        initial ← current window
        driven ←
          seamDrive
            seam
            window
            DuringPoll
            [ ResizedTo 100 80
            , FramebufferResizedTo 200 160
            , ResizedTo 120 90
            , MovedTo 5 6
            , ContentScaledTo 1.5 1.25
            , FocusChanged True
            , IconifyChanged True
            , MaximizeChanged True
            ]
        observation ← atomically (readSnapshot (windowObservations window))
        idle ← seamDrive seam window DuringSetter []
        unchanged ← current window
        pure
          ( initial
          , driven
          , preparedValue (observedValue observation)
          , cursorRevision (observedCursor observation)
          , idle
          , unchanged
          )
  observedRevision initial `shouldBe` 0
  driven `shouldBe` WindowAvailable ()
  observedRevision after `shouldBe` 1
  cursor `shouldBe` 1
  observedLogicalExtent after `shouldBe` Observed (Extent 120 90)
  observedFramebufferExtent after `shouldBe` Observed (Extent 200 160)
  observedPlacement after `shouldBe` Observed (Placement 5 6)
  observedContentScale after `shouldBe` Observed (ContentScale 1.5 1.25)
  map ($ after) [observedFocused, observedIconified, observedMaximized] `shouldBe` replicate 3 (Observed True)
  observedVisible after `shouldBe` Observed False
  idle `shouldBe` WindowAvailable ()
  unchanged `shouldBe` after

testUnavailableAndZeroFramebuffer ∷ Expectation
testUnavailableAndZeroFramebuffer = do
  seam ←
    newSeam
      defaultScript
        { scriptWindowPosition = \reporter → do
            reportError reporter featureUnavailableCode "The platform does not provide the window position"
            pure (0, 0)
        , scriptFramebufferSize = \_ → pure (0, 0)
        }
  (initial, resized, synchronized) ← asProcessMainThread seam $ entered seam $ \session →
    withWindow session (hiddenTestWindowConfig "nondrawable" 64 48) $ \window → do
      initial ← current window
      _ ← seamDrive seam window DuringPoll [FramebufferResizedTo 20 10, FramebufferResizedTo 0 0]
      resized ← current window
      synchronized ← synchronizeWindow window
      pure (initial, resized, synchronized)
  observedPlacement initial `shouldBe` Unavailable
  observedFramebufferExtent initial `shouldBe` Observed (Extent 0 0)
  observedLogicalExtent initial `shouldBe` Observed (Extent 800 600)
  -- Coalesced back to the value it started at, so nothing changed.
  observedRevision resized `shouldBe` 0
  case synchronized of
    WindowAvailable observation → do
      observedPlacement observation `shouldBe` Unavailable
      observedFramebufferExtent observation `shouldBe` Observed (Extent 0 0)
    WindowEnded _ → expectationFailure "a live window answered as ended"

testRefreshAdvancesRevision ∷ Expectation
testRefreshAdvancesRevision = do
  seam ← newSeam defaultScript
  (initial, refreshed) ← asProcessMainThread seam $ entered seam $ \session →
    withWindow session (hiddenTestWindowConfig "refreshed" 64 48) $ \window → do
      initial ← current window
      _ ← seamDrive seam window DuringPoll [RefreshRequested]
      refreshed ← current window
      pure (initial, refreshed)
  observedRevision refreshed `shouldBe` 1
  sameAttributes initial refreshed `shouldBe` True

-- ---------------------------------------------------------------------------
-- Close requests

testCloseIntent ∷ Expectation
testCloseIntent = do
  seam ← newSeam defaultScript
  (identity, first, second, rejectedOlder, kept, rejectedNewer, cleared, coalesced, ended) ←
    asProcessMainThread seam $ entered seam $ \session →
      withWindow session (hiddenTestWindowConfig "closing" 64 48) $ \window → do
        _ ← seamDrive seam window DuringPoll [CloseRequested]
        first ← current window
        _ ← seamDrive seam window DuringSetter [CloseRequested]
        second ← current window
        older ← requestOf first
        newer ← requestOf second
        rejectedOlder ← seamRejectCloseRequest window older
        kept ← current window
        rejectedNewer ← seamRejectCloseRequest window newer
        cleared ← current window
        _ ← seamDrive seam window DuringPoll [CloseRequested, CloseRequested]
        coalesced ← current window
        ended ← windowEnded window
        pure (windowIdentity window, first, second, rejectedOlder, kept, rejectedNewer, cleared, coalesced, ended)
  fmap closeRequestNumber (observedCloseRequest first) `shouldBe` Just 1
  fmap closeRequestNumber (observedCloseRequest second) `shouldBe` Just 2
  fmap closeRequestWindow (observedCloseRequest second) `shouldBe` Just identity
  observedRevision second `shouldBe` 2
  rejectedOlder `shouldBe` WindowAvailable False
  observedCloseRequest kept `shouldBe` observedCloseRequest second
  observedRevision kept `shouldBe` 2
  rejectedNewer `shouldBe` WindowAvailable True
  observedCloseRequest cleared `shouldBe` Nothing
  observedRevision cleared `shouldBe` 3
  fmap closeRequestNumber (observedCloseRequest coalesced) `shouldBe` Just 4
  observedRevision coalesced `shouldBe` 4
  observedPhase coalesced `shouldBe` WindowOpen
  ended `shouldBe` False
  -- No close request destroyed anything: the only destruction is release's.
  seamCalls seam
    `shouldReturn` concat [entryCalls, creationCalls "closing" 64 48 1, releaseCalls 1, exitCalls]
  where
    requestOf observation =
      maybe (unexpected "no close request was observed") pure (observedCloseRequest observation)

-- ---------------------------------------------------------------------------
-- Callback containment

testCallbackFaults ∷ Expectation
testCallbackFaults = do
  seam ← newSeam defaultScript
  ( (setterFault, setterCaught)
    , afterSetter
    , (pollFault, pollCaught)
    , (cancelled, cancelledCaught)
    , recovered
    , afterRecovery
    ) ←
    asProcessMainThread seam $ entered seam $ \session →
      withWindow session (hiddenTestWindowConfig "faulting" 64 48) $ \window → do
        setter ←
          caughtAs
            ( seamDrive
                seam
                window
                DuringSetter
                [ ResizedTo 300 200
                , CallbackRaises (toException (ErrorCall "setter fault"))
                , CallbackRaises (toException (ErrorCall "later fault"))
                , CloseRequested
                ]
            )
        afterSetter ← current window
        poll ← caughtAs (seamDrive seam window DuringPoll [CallbackRaises (toException (ErrorCall "poll fault"))])
        cancellation ← caughtAs (seamDrive seam window DuringPoll [CallbackRaises (toException ThreadKilled)])
        recovered ← seamDrive seam window DuringPoll [ResizedTo 10 10]
        afterRecovery ← current window
        pure (setter, afterSetter, poll, cancellation, recovered, afterRecovery)
  setterFault `shouldBe` ErrorCall "setter fault"
  contextsOf setterCaught
    `shouldBe` [("glfw", "window callback", [("window", "1"), ("callback", "window size"), ("later-faults", "1")])]
  -- Everything captured beside the fault was published before it was rethrown.
  observedLogicalExtent afterSetter `shouldBe` Observed (Extent 300 200)
  fmap closeRequestNumber (observedCloseRequest afterSetter) `shouldBe` Just 1
  pollFault `shouldBe` ErrorCall "poll fault"
  contextsOf pollCaught
    `shouldBe` [("glfw", "window callback", [("window", "1"), ("callback", "window size"), ("later-faults", "0")])]
  cancelled `shouldBe` ThreadKilled
  contextsOf cancelledCaught `shouldBe` []
  recovered `shouldBe` WindowAvailable ()
  observedLogicalExtent afterRecovery `shouldBe` Observed (Extent 10 10)

-- ---------------------------------------------------------------------------
-- Lifetime

testIndependentWindows ∷ Expectation
testIndependentWindows = do
  seam ← newSeam defaultScript
  ( outerId
    , innerId
    , laterId
    , innerObserved
    , outerBefore
    , innerAfterEnd
    , outerDriven
    , outerAfter
    , staleRejection
    ) ←
    asProcessMainThread seam $ entered seam $ \session →
      withWindow session (hiddenTestWindowConfig "outer" 64 48) $ \outer → do
        (inner, innerObserved, outerBefore) ←
          withWindow session (hiddenTestWindowConfig "inner" 32 24) $ \inner → do
            _ ← seamDrive seam inner DuringPoll [ResizedTo 111 99, CloseRequested]
            innerObserved ← current inner
            outerBefore ← current outer
            pure (inner, innerObserved, outerBefore)
        innerAfterEnd ← synchronizeWindow inner
        outerDriven ← seamDrive seam outer DuringPoll [ResizedTo 50 40]
        outerAfter ← current outer
        innerRequest ← maybe (unexpected "no close request") pure (observedCloseRequest innerObserved)
        (laterId, staleRejection) ←
          withWindow session (hiddenTestWindowConfig "later" 16 12) $ \later → do
            afterLater ← synchronizeWindow inner
            afterLater `shouldBe` WindowEnded (windowIdentity inner)
            rejection ← seamRejectCloseRequest later innerRequest
            pure (windowIdentity later, rejection)
        pure
          ( windowIdentity outer
          , windowIdentity inner
          , laterId
          , innerObserved
          , outerBefore
          , innerAfterEnd
          , outerDriven
          , outerAfter
          , staleRejection
          )
  map windowLocalIdentity [outerId, innerId, laterId] `shouldBe` [1, 2, 3]
  laterId `shouldNotBe` innerId
  observedRevision innerObserved `shouldBe` 1
  observedLogicalExtent innerObserved `shouldBe` Observed (Extent 111 99)
  observedRevision outerBefore `shouldBe` 0
  observedCloseRequest outerBefore `shouldBe` Nothing
  innerAfterEnd `shouldBe` WindowEnded innerId
  outerDriven `shouldBe` WindowAvailable ()
  observedRevision outerAfter `shouldBe` 1
  observedLogicalExtent outerAfter `shouldBe` Observed (Extent 50 40)
  staleRejection `shouldBe` WindowAvailable False
  seamLiveWindowCallbacks seam `shouldReturn` 0

testOwnerOnly ∷ Expectation
testOwnerOnly = do
  seam ← newSeam defaultScript
  (synchronizing, driving, callsBefore, callsAfter) ← asProcessMainThread seam $ entered seam $ \session →
    withWindow session (hiddenTestWindowConfig "owned" 64 48) $ \window → do
      callsBefore ← length <$> seamCalls seam
      synchronizing ← onThread forkOS (fst <$> caughtAs (synchronizeWindow window))
      driving ← onThread forkOS (fst <$> caughtAs (seamDrive seam window DuringSetter [RefreshRequested]))
      callsAfter ← length <$> seamCalls seam
      pure (synchronizing, driving, callsBefore, callsAfter)
  synchronizing `shouldBe` NotSessionOwner
  driving `shouldBe` NotSessionOwner
  callsAfter `shouldBe` callsBefore

-- ---------------------------------------------------------------------------
-- Release failures

testSamplingFailureRollsBack ∷ Expectation
testSamplingFailureRollsBack = do
  firstAttempt ← firstTimeOnly
  seam ←
    newSeam
      defaultScript
        { scriptWindowSize = \reporter → do
            failing ← firstAttempt
            if failing then reportError reporter 0x00010008 "size query failed" else pure ()
            pure (800, 600)
        }
  ((failure, caught), secondId) ← asProcessMainThread seam $ entered seam $ \session → do
    rejected ← caughtAs (withWindow session (hiddenTestWindowConfig "unsampled" 64 48) (\_ → pure ()))
    secondId ← withWindow session (hiddenTestWindowConfig "sampled" 64 48) (pure . windowIdentity)
    pure (rejected, secondId)
  nativeOutcome failure `shouldBe` NativeCallReturned
  map nativeErrorCode (reportedErrors (nativeReports failure)) `shouldBe` [0x00010008]
  originOf caught `shouldBe` Just ("glfw", "sample window", [("window", "1")])
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` []
  -- The failed window's identity is not reissued.
  windowLocalIdentity secondId `shouldBe` 2
  seamCalls seam
    `shouldReturn` concat
      [ entryCalls
      , take 8 (creationCalls "unsampled" 64 48 1)
      , [QueryWindowSize]
      , releaseCalls 1
      , creationCalls "sampled" 64 48 2
      , releaseCalls 2
      , exitCalls
      ]
  seamLiveWindowCallbacks seam `shouldReturn` 0

testAttachFailurePoisons ∷ Expectation
testAttachFailurePoisons = do
  seam ← newSeam defaultScript {scriptAttachWindowCallbacks = \_ → throwIO (userError "attach failed")}
  ((failure, caught), (refused, refusedCaught)) ← asProcessMainThread seam $ entered seam $ \session → do
    rejected ← caughtAs (withWindow session (hiddenTestWindowConfig "unattached" 64 48) (\_ → pure ()))
    refusal ← caughtAs (withWindow session (hiddenTestWindowConfig "refused" 64 48) (\_ → pure ()))
    pure (rejected, refusal)
  displayException (failure ∷ IOException) `shouldBe` "user error (attach failed)"
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` []
  refused `shouldBe` SessionPoisoned
  operationOf refusedCaught `shouldBe` Just ("glfw", "create window")
  seamLiveWindowCallbacks seam `shouldReturn` 1
  (poisoned, _) ← asProcessMainThread seam (caughtAs (entered seam (\_ → pure ())))
  poisoned `shouldBe` SessionPoisoned
  seamCalls seam
    `shouldReturn` concat
      [ entryCalls
      , take 8 (creationCalls "unattached" 64 48 1)
      , [DestroyWindow 1]
      , [Terminate, DetachErrorCallback]
      ]

detachRaises, destroyRaises ∷ SeamScript
detachRaises = defaultScript {scriptDetachWindowCallbacks = \_ → throwIO (userError "release raised")}
destroyRaises = defaultScript {scriptDestroyWindow = \_ → throwIO (userError "release raised")}

testUncertainRelease ∷ SeamScript → Text → Expectation
testUncertainRelease script label = do
  seam ← newSeam script
  stash ← newIORef Nothing
  ((failure, caught), final, (refused, _)) ← asProcessMainThread seam $ entered seam $ \session → do
    released ← caughtAs (withWindow session (hiddenTestWindowConfig "uncertain" 64 48) (writeIORef stash . Just))
    window ← stashed stash
    final ← current window
    refusal ← caughtAs (withWindow session (hiddenTestWindowConfig "refused" 64 48) (\_ → pure ()))
    pure (released, final, refusal)
  displayException (failure ∷ IOException) `shouldBe` "user error (release raised)"
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` [label]
  observedPhase final `shouldBe` WindowReleaseUncertain
  refused `shouldBe` SessionPoisoned
  -- The wrappers are kept rather than freed beneath native code.
  seamLiveWindowCallbacks seam `shouldReturn` 1
  (poisoned, _) ← asProcessMainThread seam (caughtAs (entered seam (\_ → pure ())))
  poisoned `shouldBe` SessionPoisoned
  seamCalls seam
    `shouldReturn` concat
      [ entryCalls
      , creationCalls "uncertain" 64 48 1
      , [DetachWindowCallbacks 1, DestroyWindow 1]
      , [Terminate, DetachErrorCallback]
      ]

testDestroyReportRetained ∷ Expectation
testDestroyReportRetained = do
  firstAttempt ← firstTimeOnly
  seam ←
    newSeam
      defaultScript
        { scriptDestroyWindow = \reporter → do
            reporting ← firstAttempt
            if reporting then reportError reporter 0x00010008 "destroy reported" else pure ()
        }
  stash ← newIORef Nothing
  ((failure, caught), final, secondId) ← asProcessMainThread seam $ entered seam $ \session → do
    released ← caughtAs (withWindow session (hiddenTestWindowConfig "reported" 64 48) (writeIORef stash . Just))
    window ← stashed stash
    final ← current window
    secondId ← withWindow session (hiddenTestWindowConfig "after" 64 48) (pure . windowIdentity)
    pure (released, final, secondId)
  failure
    `shouldBe` NativeFailure NativeCallReturned (Reports [NativeError 0x00010008 "destroy reported" False ProcessMainThread] 0 0)
  originOf caught `shouldBe` Just ("glfw", "destroy window", [("window", "1")])
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` ["glfw window"]
  observedPhase final `shouldBe` WindowReleased
  windowLocalIdentity secondId `shouldBe` 2
  seamLiveWindowCallbacks seam `shouldReturn` 0
  asProcessMainThread seam (entered seam (pure . sessionBackend)) `shouldReturn` X11

-- ---------------------------------------------------------------------------
-- Support

entered ∷ Seam → (Session → IO r) → IO r
entered seam = withScoped (seamSession seam defaultSessionConfig)

current ∷ Window → IO WindowObservation
current window = preparedValue . observedValue <$> atomically (readSnapshot (windowObservations window))

stashed ∷ IORef (Maybe Window) → IO Window
stashed stash = readIORef stash >>= maybe (unexpected "no window was stashed") pure

sameAttributes ∷ WindowObservation → WindowObservation → Bool
sameAttributes left right =
  and
    [ observedLogicalExtent left == observedLogicalExtent right
    , observedFramebufferExtent left == observedFramebufferExtent right
    , observedContentScale left == observedContentScale right
    , observedPlacement left == observedPlacement right
    , map ($ left) flags == map ($ right) flags
    , observedCloseRequest left == observedCloseRequest right
    , observedPhase left == observedPhase right
    ]
  where
    flags = [observedFocused, observedIconified, observedMaximized, observedVisible]

-- | The native calls of a successful entry on the default script's platform.
entryCalls ∷ [NativeCall]
entryCalls =
  [ QueryPlatformSupported X11
  , CreateErrorCallback
  , AttachErrorCallback
  , SetInitHints X11
  , Initialize
  , QueryPlatform
  ]

-- | The native calls of a complete, safe session teardown.
exitCalls ∷ [NativeCall]
exitCalls = [Terminate, DetachErrorCallback, FreeErrorCallback]

-- | The native calls of a successful hidden window's creation, through its
-- initial sampling.
creationCalls ∷ Text → Int32 → Int32 → Int → [NativeCall]
creationCalls title width height key =
  [ CreateWindowCallbacks
  , ResetWindowHints
  , SetWindowHint NoClientApi
  , SetWindowHint (VisibleHint False)
  , SetWindowHint (FocusedHint False)
  , SetWindowHint (FocusOnShowHint False)
  , CreateWindow width height title
  , AttachWindowCallbacks key
  , QueryWindowSize
  , QueryFramebufferSize
  , QueryContentScale
  , QueryWindowPosition
  , QueryWindowAttribute FocusedAttribute
  , QueryWindowAttribute IconifiedAttribute
  , QueryWindowAttribute MaximizedAttribute
  , QueryWindowAttribute VisibleAttribute
  ]

-- | The native calls of a certain window release.
releaseCalls ∷ Int → [NativeCall]
releaseCalls key = [DetachWindowCallbacks key, DestroyWindow key, FreeWindowCallbacks]

-- | An action answering 'True' the first time it runs and 'False' after.
firstTimeOnly ∷ IO (IO Bool)
firstTimeOnly = do
  flag ← newIORef True
  pure (atomicModifyIORef' flag (\first → (False, first)))

-- | Run an action on a new thread and wait for its outcome.
onThread ∷ (IO () → IO ThreadId) → IO a → IO a
onThread fork action = do
  finished ← newEmptyMVar
  _ ← fork (try action >>= putMVar finished)
  outcome ← takeMVar finished
  either (throwIO ∷ SomeException → IO a) pure outcome

-- | The typed failure an action raised, beside the exception as caught.
caughtAs ∷ Exception e ⇒ IO a → IO (e, SomeException)
caughtAs action = do
  outcome ← try action
  case outcome of
    Right _ → unexpected "the action returned instead of failing"
    Left caught → case fromException caught of
      Just typed → pure (typed, caught)
      Nothing → unexpected ("the action failed with " <> displayException caught)

unexpected ∷ String → IO a
unexpected message = expectationFailure message >> ioError (userError message)

originOf ∷ SomeException → Maybe (Text, Text, [(Text, Text)])
originOf caught = case failureCause (failureEvidence caught) of
  EngineOrigin origin →
    Just
      ( componentText (originComponent origin)
      , operationText (originOperation origin)
      , originIdentifiers origin
      )
  NativeCause → Nothing

operationOf ∷ SomeException → Maybe (Text, Text)
operationOf caught = (\(component, operationName, _) → (component, operationName)) <$> originOf caught

contextsOf ∷ SomeException → [(Text, Text, [(Text, Text)])]
contextsOf caught =
  [ (componentText (contextComponent context), operationText (contextOperation context), contextIdentifiers context)
  | context ← failureContexts (failureEvidence caught)
  ]

boundedExample ∷ Expectation → Expectation
boundedExample action = do
  finished ← timeout (30 * 1000 * 1000) action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"
