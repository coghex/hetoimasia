-- | Windows in the shared session. Every example here creates, uses, and
-- releases its own private window inside one dispatched operation; no window
-- outlives an example or is shared between two.
module Test.GLFW.Native.Window (spec) where

import Hetoimasia.GLFW.Internal.Native (leakResizableHintForCheck, windowResizableForCheck)
import Hetoimasia.GLFW.Internal.Window (windowNativeHandle)
import Hetoimasia.GLFW.Window
  ( Attribute (..)
  , Extent (..)
  , WindowPhase (..)
  , WindowResult (..)
  , hiddenTestWindowConfig
  , observedFramebufferExtent
  , observedPhase
  , observedVisible
  , synchronizeWindow
  , windowEnded
  , windowIdentity
  , withWindow
  )
import Test.GLFW.Native.Support (Shared, currentObservation, owned)
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe, shouldSatisfy)

spec ∷ Shared → Spec
spec shared = describe "private windows" $ do
  it "creates, observes, and releases a hidden non-focusing window, leaving a terminal handle" $ do
    (initial, synchronized, afterEnd, final, ended, identity) ←
      owned shared $ \session → do
        (initial, synchronized, window) ←
          withWindow session (hiddenTestWindowConfig "hetoimasia native example" 320 240) $ \window → do
            initial ← currentObservation window
            synchronized ← synchronizeWindow window
            pure (initial, synchronized, window)
        -- Deliberate misuse: the handle escaped its scope to prove it is terminal.
        afterEnd ← synchronizeWindow window
        final ← currentObservation window
        ended ← windowEnded window
        pure (initial, synchronized, afterEnd, final, ended, windowIdentity window)
    observedFramebufferExtent initial `shouldSatisfy` \case
      Observed (Extent width height) → width > 0 && height > 0
      _ → False
    observedPhase initial `shouldBe` WindowOpen
    observedVisible initial `shouldBe` Observed False
    synchronized `shouldSatisfy` \case
      WindowAvailable _ → True
      WindowEnded _ → False
    afterEnd `shouldBe` WindowEnded identity
    ended `shouldBe` True
    observedPhase final `shouldBe` WindowReleased

  it "resets a stray creation hint before a second live window is created" $ do
    (resizable, visibility, first, second) ←
      owned shared $ \session →
        withWindow session (hiddenTestWindowConfig "first" 200 150) $ \first → do
          leakResizableHintForCheck
          withWindow session (hiddenTestWindowConfig "second" 220 160) $ \second → do
            resizable ← windowResizableForCheck (windowNativeHandle second)
            observations ← mapM currentObservation [first, second]
            pure (resizable, map observedVisible observations, windowIdentity first, windowIdentity second)
    resizable `shouldBe` True
    visibility `shouldBe` [Observed False, Observed False]
    first `shouldNotBe` second

  it "creates another window after one is released in the same session" $ do
    (released, recreated) ←
      owned shared $ \session → do
        released ← withWindow session (hiddenTestWindowConfig "released" 160 120) (pure . windowIdentity)
        recreated ← withWindow session (hiddenTestWindowConfig "recreated" 160 120) (pure . windowIdentity)
        pure (released, recreated)
    released `shouldNotBe` recreated
