-- | Native input callbacks delivering into window feeds.
--
-- Every example injects through the registered C trampoline
-- ('injectKeyForCheck' and its siblings), not through the feed's private
-- producer. Hidden test windows do not receive display-server events, so the
-- fixture owner-thread path is used for every scenario here; that path is
-- recorded with the examples.
module Test.GLFW.Native.Input (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, void)
import Data.Maybe (isJust)
import Foreign.Ptr (Ptr)
import Hetoimasia.Foundation.Failure (operation)
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLoggerWith, systemMetadata)
import Hetoimasia.GLFW.Input
import Hetoimasia.GLFW.Internal.Input
  ( InputFeed
  , Resumption (..)
  , attemptOverflowWarning
  , feedControl
  , feedReader
  , newInputFeed
  , resumeInput
  )
import Hetoimasia.GLFW.Internal.Native
  ( injectCharForCheck
  , injectCursorEnterForCheck
  , injectCursorPosForCheck
  , injectFocusForCheck
  , injectKeyForCheck
  , injectMouseButtonForCheck
  , injectScrollForCheck
  , requestCloseForCheck
  )
import Hetoimasia.GLFW.Internal.Session (NativeWindow)
import Hetoimasia.GLFW.Internal.Window (attachWindowInputFeed, inputStagingCapacity, windowStep)
import Hetoimasia.GLFW.Window
  ( Window
  , WindowResult (..)
  , hiddenTestWindowConfig
  , observedCloseRequest
  , observedCursorPosition
  , observedCursorInside
  , windowEnded
  , windowIdentity
  , withWindow
  )
import Test.GLFW.Native.Support (Shared, currentObservation, failed, owned)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Shared → Spec
spec shared = describe "native input callbacks" $ do
  it "records that every scenario uses the fixture owner-thread native callback path" $
    injectionPath `shouldBe` "fixture-owner-thread"

  it "delivers key, character, button, and scroll from the registered C callbacks, tagged with window and epoch, and coalesces cursor into the observation" $ do
    (payloads, windows, epochs, cursor, inside) ←
      owned shared $ \session →
        withWindow session (hiddenTestWindowConfig "native input" 320 240) $ \window → do
          feed ← liveFeed window 16
          inject window $ \handle → do
            injectCursorPosForCheck handle 3 4
            injectCursorEnterForCheck handle True
            injectKeyForCheck handle 65 38 glfwPress glfwModShift
            injectCharForCheck handle (fromEnum 'A')
            injectMouseButtonForCheck handle 1 glfwPress 0
            injectScrollForCheck handle 0 1
            injectScrollForCheck handle 0 1
            injectCharForCheck handle (fromEnum 'A')
          (events, _) ← drain feed
          observation ← currentObservation window
          pure
            ( map inputPayload events
            , map inputWindow events
            , map (epochNumber . inputEpoch) events
            , observedCursorPosition observation
            , observedCursorInside observation
            )
    payloads
      `shouldBe` [ KeyInput (KeyEvent 65 38 KeyPressed (noModifiers {modifierShift = True}))
                 , TextInput 'A'
                 , ButtonInput (ButtonEvent 1 ButtonPressed (Just (CursorPosition 3 4)) noModifiers)
                 , ScrollInput (ScrollEvent 0 1)
                 , ScrollInput (ScrollEvent 0 1)
                 , TextInput 'A'
                 ]
    length windows `shouldBe` 6
    epochs `shouldBe` replicate 6 1
    cursor `shouldBe` Just (CursorPosition 3 4)
    inside `shouldBe` Just True
    allEqual windows `shouldBe` True

  it "keeps a button event's captured coordinates after later cursor motion" $ do
    payloads ←
      owned shared $ \session →
        withWindow session (hiddenTestWindowConfig "native button" 320 240) $ \window → do
          feed ← liveFeed window 8
          inject window $ \handle → do
            injectCursorPosForCheck handle 1 2
            injectMouseButtonForCheck handle 0 glfwPress glfwModShift
            injectCursorPosForCheck handle 50 60
            injectCursorPosForCheck handle 70 80
            injectMouseButtonForCheck handle 0 glfwRelease glfwModShift
          (events, _) ← drain feed
          pure (map inputPayload events)
    payloads
      `shouldBe` [ ButtonInput (ButtonEvent 0 ButtonPressed (Just (CursorPosition 1 2)) (noModifiers {modifierShift = True}))
                 , ButtonInput (ButtonEvent 0 ButtonReleased (Just (CursorPosition 70 80)) (noModifiers {modifierShift = True}))
                 ]

  it "saturates the feed from real callbacks, acknowledges, and delivers a fresh press but no press for a key still held" $ do
    payloads ←
      owned shared $ \session →
        withWindow session (hiddenTestWindowConfig "native overflow" 320 240) $ \window → do
          feed ← liveFeed window 2
          inject window $ \handle → do
            injectKeyForCheck handle 65 0 glfwPress 0
            injectCharForCheck handle (fromEnum 'a')
            injectCharForCheck handle (fromEnum 'b')
          token ←
            atomically (readInput (feedReader feed)) >>= \case
              InputResetRequired reset → pure reset
              other → failed ("expected a reset, found " <> show other)
          resetReason token `shouldBe` InputOverflowed
          atomically (acknowledgeReset (feedReader feed) token) `shouldReturn` Right Acknowledged
          void (attemptOverflowWarning quietLogger feed)
          resumeInput feed `shouldReturn` Resumed (resetEpoch token)
          inject window $ \handle → do
            injectKeyForCheck handle 65 0 glfwRepeat 0
            injectKeyForCheck handle 66 0 glfwPress 0
          (events, _) ← drain feed
          pure (map inputPayload events)
    payloads `shouldBe` [KeyInput (KeyEvent 66 0 KeyPressed noModifiers)]

  it "saturates native staging through the registered callbacks and begins the same reset before publishing a prefix" $ do
    delivered ←
      owned shared $ \session →
        withWindow session (hiddenTestWindowConfig "native staging" 160 120) $ \window → do
          feed ← liveFeed window 16
          inject window $ \handle →
            forM_ [1 .. inputStagingCapacity + 1] $ \_ → injectCharForCheck handle (fromEnum 'a')
          atomically (readInput (feedReader feed)) >>= \case
            InputResetRequired token → do
              resetReason token `shouldBe` InputOverflowed
              (events, _) ← drain feed
              pure events
            other → failed ("staging overflow did not reset: " <> show other)
    delivered `shouldBe` []

  it "leaves a second window receiving input when the first window's feed saturates" $ do
    secondPayloads ←
      owned shared $ \session →
        withWindow session (hiddenTestWindowConfig "native one" 200 150) $ \first →
          withWindow session (hiddenTestWindowConfig "native two" 200 150) $ \second → do
            _ ← liveFeed first 1
            feedTwo ← liveFeed second 8
            inject first $ \handle → do
              injectCharForCheck handle (fromEnum 'x')
              injectCharForCheck handle (fromEnum 'y')
            inject second $ \handle → injectCharForCheck handle (fromEnum 'z')
            (events, _) ← drain feedTwo
            pure (map inputPayload events)
    secondPayloads `shouldBe` [TextInput 'z']

  it "rethrows a fault raised inside a real input callback at the owner boundary without crossing C" $ do
    outcome ←
      owned shared $ \session →
        withWindow session (hiddenTestWindowConfig "native fault" 160 120) $ \window → do
          _ ← liveFeed window 8
          try (inject window (\handle → injectKeyForCheck handle 65 0 99 0)) ∷ IO (Either SomeException ())
    case outcome of
      Left _ → pure ()
      Right _ → failed "an unknown key action did not raise at the owner boundary"

  it "keeps a close request visible while a feed is full" $ do
    close ←
      owned shared $ \session →
        withWindow session (hiddenTestWindowConfig "native close" 160 120) $ \window → do
          feed ← liveFeed window 1
          inject window $ \handle → do
            injectCharForCheck handle (fromEnum 'a')
            injectCharForCheck handle (fromEnum 'b')
            requestCloseForCheck handle
          atomically (readInput (feedReader feed)) >>= \case
            InputResetRequired _ → pure ()
            other → failed ("expected a full-feed reset, found " <> show other)
          observedCloseRequest <$> currentObservation window
    close `shouldSatisfy` isJust

  it "removes every input callback before the window is destroyed, with no retained cleanup failure" $ do
    ended ←
      owned shared $ \session → do
        window ←
          withWindow session (hiddenTestWindowConfig "native teardown" 160 120) $ \live → do
            _ ← liveFeed live 4
            inject live $ \handle → injectCharForCheck handle (fromEnum 'q')
            pure live
        windowEnded window
    ended `shouldBe` True

  it "delivers focus loss and gain in native order through the existing focus callback" $ do
    payloads ←
      owned shared $ \session →
        withWindow session (hiddenTestWindowConfig "native focus" 160 120) $ \window → do
          feed ← liveFeed window 8
          inject window $ \handle → do
            injectFocusForCheck handle False
            injectFocusForCheck handle True
          (events, _) ← drain feed
          pure (map inputPayload events)
    payloads `shouldBe` [FocusInput False, FocusInput True]

-- | How these examples inject: hidden windows cannot take display-server
-- events, so every scenario uses the owner-thread trampoline.
injectionPath ∷ String
injectionPath = "fixture-owner-thread"

glfwPress, glfwRelease, glfwRepeat ∷ Int
glfwPress = 1
glfwRelease = 0
glfwRepeat = 2

glfwModShift ∷ Int
glfwModShift = 1

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))

liveFeed ∷ Window → Integer → IO InputFeed
liveFeed window capacity = do
  feed ← newInputFeed (windowIdentity window) capacity True
  attachWindowInputFeed window feed
  atomically (enableInput (feedControl feed)) `shouldReturn` AdmissionOpened
  pure feed

inject ∷ Window → (Ptr NativeWindow → IO ()) → IO ()
inject window action =
  windowStep window (operation "inject input") action >>= \case
    WindowAvailable () → pure ()
    WindowEnded identity → failed ("window ended during inject: " <> show identity)

drain ∷ InputFeed → IO ([InputEvent], InputRead)
drain feed = atomically (go [])
  where
    go taken =
      readInput (feedReader feed) >>= \case
        InputDelivered event → go (event : taken)
        other → pure (reverse taken, other)

allEqual ∷ Eq a ⇒ [a] → Bool
allEqual [] = True
allEqual (first : rest) = all (== first) rest
