-- | Ordinary window controls in the shared session.
--
-- Each example creates its own private windows inside one dispatched operation
-- and performs control commands directly on the owner thread with
-- 'performWindowCommand'. What the platform reports is read through the
-- test-only owner-thread queries of "Hetoimasia.GLFW.Internal.Native", never
-- through a public command. The out-of-range resize is the test-only native
-- stimulus 'setWindowSizeForCheck', distinct from the public command path, and
-- the installed limits are read back from the platform with
-- 'sizeLimitsForCheck'. Whether a programmatic resize is clamped is the
-- platform's decision: Cocoa's content limits bound only the user's resizing,
-- so its reported size may be the unclamped request, while an X11 window
-- manager may clamp to the size hints.
--
-- Window managers apply requests asynchronously, so an example waits for native
-- events between observations, within a bound of turns, and compares the
-- observation with what the platform reports rather than with the request
-- wherever the platform decides the result.
module Test.GLFW.Native.Control (spec) where

import Control.Monad (void)
import Data.Text (Text)
import Hetoimasia.GLFW.Command
import Hetoimasia.GLFW.Internal.Native
  ( WindowStateForCheck (..)
  , setWindowSizeForCheck
  , sizeLimitsForCheck
  , waitEventsForCheck
  , windowPositionForCheck
  , windowSizeForCheck
  , windowStateForCheck
  , windowTitleForCheck
  )
import Hetoimasia.GLFW.Internal.Window (windowNativeHandle)
import Hetoimasia.GLFW.Session (Session)
import Hetoimasia.GLFW.Window
import Numeric.Natural (Natural)
import Test.GLFW.Native.Support (Shared, currentObservation, failed, owned)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Shared → Spec
spec shared = describe "window controls" $ do
  it "applies a title, a valid size, a position, and constraints to the addressed window while a second window stays unchanged" $ do
    (dispositions, applied, untouchedBefore, untouchedAfter) ←
      owned shared $ \session →
        withTwo session $ \perform addressed untouched → do
          before ← nativeFacts untouched
          let target = windowIdentity addressed
          dispositions ←
            mapM
              perform
              [ setWindowTitleCommand target "renamed native window"
              , setWindowSizeCommand target (Extent 300 200)
              , setWindowPositionCommand target (Placement 120 90)
              , setSizeConstraintsCommand target (sizeConstraints (Extent 160 120) (Extent 640 480) Nothing)
              ]
          applied ←
            converge addressed $ \_ → do
              facts ← nativeFacts addressed
              pure (facts == (Just "renamed native window", (300, 200), (120, 90)), facts)
          after ← nativeFacts untouched
          pure (dispositions, applied, before, after)
    dispositions `shouldSatisfy` all returnedWithRevision
    applied `shouldBe` (Just "renamed native window", (300, 200), (120, 90))
    untouchedAfter `shouldBe` untouchedBefore

  it "reflects showing and then hiding a window in its observations" $ do
    (shown, hidden) ←
      owned shared $ \session →
        withTwo session $ \perform window _ → do
          let target = windowIdentity window
          void (perform (showWindowCommand target))
          shown ← converge window (\observation → pure (observedVisible observation == Observed True, observedVisible observation))
          void (perform (hideWindowCommand target))
          hidden ← converge window (\observation → pure (observedVisible observation == Observed False, observedVisible observation))
          pure (shown, hidden)
    shown `shouldBe` Observed True
    hidden `shouldBe` Observed False

  it "installs size limits on the addressed window only, refuses a public out-of-constraint size, and observes the platform's actual size after a test-only out-of-range resize" $ do
    (installed, refused, (addressedLimits, untouchedLimits), (observed, reported)) ←
      owned shared $ \session →
        withTwo session $ \perform window untouched → do
          let target = windowIdentity window
              constraints = sizeConstraints (Extent 200 150) (Extent 400 300) Nothing
          installed ← perform (setSizeConstraintsCommand target constraints)
          refused ← perform (setWindowSizeCommand target (Extent 1000 1000))
          limits ← (,) <$> sizeLimitsForCheck (windowNativeHandle window) <*> sizeLimitsForCheck (windowNativeHandle untouched)
          setWindowSizeForCheck (windowNativeHandle window) 1000 1000
          agreed ← converge window $ \observation → do
            (width, height) ← windowSizeForCheck (windowNativeHandle window)
            let reported = Observed (Extent width height)
            pure (observedLogicalExtent observation == reported && reported /= Observed (Extent 320 240), (observedLogicalExtent observation, reported))
          pure (installed, refused, limits, agreed)
    installed `shouldSatisfy` returnedWithRevision
    refused `shouldSatisfy` \case
      Rejected (ControlRejected _ (SizeOutsideConstraints (Extent 1000 1000) _)) → True
      _ → False
    -- The platform itself holds the installed limits for the addressed window,
    -- and not for the other one.
    addressedLimits `shouldBe` Just (Just 200, Just 150, Just 400, Just 300)
    untouchedLimits `shouldSatisfy` (/= addressedLimits)
    observed `shouldBe` reported
    -- The size is the platform's: clamped into the limits by a platform that
    -- clamps programmatic resizes, or the unclamped request where the limits
    -- bound only the user's resizing, as on Cocoa. Nothing else.
    reported `shouldSatisfy` \case
      Observed (Extent width height) → within width height || (width, height) == (1000, 1000)
      Unavailable → False

  it "follows minimize, maximize, and restore each with an observation checked against what the platform reports" $ do
    steps ←
      owned shared $ \session →
        withTwo session $ \perform window _ → do
          let target = windowIdentity window
          mapM
            ( \command → do
                settled ← perform (command target)
                agreed ← converge window $ \observation → do
                  state ← windowStateForCheck (windowNativeHandle window)
                  let observedState = (observedIconified observation, observedMaximized observation, observedVisible observation)
                      reportedState = (Observed (checkIconified state), Observed (checkMaximized state), Observed (checkVisible state))
                  pure (observedState == reportedState, (observedState, reportedState))
                pure (settled, agreed)
            )
            [minimizeWindowCommand, maximizeWindowCommand, restoreWindowCommand]
    length steps `shouldBe` 3
    mapM_ (\(settled, (observedState, reportedState)) → do
      settled `shouldSatisfy` attemptedWithRevision
      observedState `shouldBe` reportedState) steps

  it "settles focus and attention requests by their native call outcome, without asserting that either was granted" $ do
    settled ←
      owned shared $ \session →
        withTwo session $ \perform window _ → do
          let target = windowIdentity window
          mapM perform [requestFocusCommand target, requestAttentionCommand target]
    settled `shouldSatisfy` all attemptedWithRevision

  it "orders post-call revisions and tolerates a latest snapshot that has already advanced beyond them" $ do
    (revisions, newest) ←
      owned shared $ \session →
        withTwo session $ \perform window _ → do
          let target = windowIdentity window
          first ← perform (setWindowTitleCommand target "first title")
          second ← perform (setWindowTitleCommand target "second title")
          setWindowSizeForCheck (windowNativeHandle window) 260 180
          _ ← converge window $ \observation → do
            (width, height) ← windowSizeForCheck (windowNativeHandle window)
            pure (observedLogicalExtent observation == Observed (Extent width height), ())
          void (synchronizeWindow window)
          newest ← observedRevision <$> currentObservation window
          pure (map revisionOf [first, second], newest)
    case revisions of
      [Just first, Just second] → do
        second `shouldSatisfy` (> first)
        newest `shouldSatisfy` (>= second)
      other → failed ("the titles named no post-call revisions: " <> show other)

-- | Whether a size lies within the clamping example's installed limits.
within ∷ Int → Int → Bool
within width height = width >= 200 && width <= 400 && height >= 150 && height <= 300

-- | Two private hidden windows in the shared session and a direct executor over
-- them.
withTwo ∷ Session → ((WindowCommand → IO Disposition) → Window → Window → IO a) → IO a
withTwo session body =
  withWindow session (hiddenTestWindowConfig "controlled" 320 240) $ \addressed →
    withWindow session (hiddenTestWindowConfig "untouched" 240 160) $ \untouched → do
      host ← newWindowCommandHost session 8
      body (performWindowCommand host [addressed, untouched]) addressed untouched

-- | What the platform reports of a window's title, size, and position.
nativeFacts ∷ Window → IO (Maybe Text, (Int, Int), (Int, Int))
nativeFacts window =
  (,,)
    <$> windowTitleForCheck (windowNativeHandle window)
    <*> windowSizeForCheck (windowNativeHandle window)
    <*> windowPositionForCheck (windowNativeHandle window)

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
        else waitEventsForCheck 0.05 >> attempt (remaining - 1)

-- | At most five seconds of 50 ms event waits.
turnBound ∷ Natural
turnBound = 100

returnedWithRevision ∷ Disposition → Bool
returnedWithRevision = \case
  Attempted (ControlAttempt _ ControlReturned (PostCallRevision _)) → True
  _ → False

-- | Any native call outcome, with a post-call revision.
attemptedWithRevision ∷ Disposition → Bool
attemptedWithRevision = \case
  Attempted (ControlAttempt _ _ (PostCallRevision _)) → True
  _ → False

revisionOf ∷ Disposition → Maybe Natural
revisionOf = \case
  Attempted (ControlAttempt _ _ (PostCallRevision revision)) → Just revision
  _ → Nothing
