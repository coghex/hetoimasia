-- | The contained callbacks that record into a window's capture latch, and the
-- operations that take and rethrow what they latched.
--
-- The callbacks run on the session's owner thread, inside the native calls
-- that deliver them, and write only the window's capture latch and input
-- staging, in "Hetoimasia.GLFW.Internal.Window.State". The latch is emptied by
-- the owner boundary's commit in "Hetoimasia.GLFW.Internal.Window.Reconcile",
-- and taken whole by construction and release.
--
-- = Callbacks
--
-- The size, framebuffer size, content scale, position, focus, iconify,
-- maximize, refresh, close, key, character, mouse button, cursor position,
-- cursor enter and leave, and scroll callbacks are contained at the trampoline.
-- Each runs uninterruptibly, copies its fixed payload, records it into the
-- window's capture latch with one non-blocking 'IORef' update, and returns.
-- None calls application code, waits, polls, logs, or destroys anything. Each
-- also offers one record to the session's interaction trace
-- ("Hetoimasia.GLFW.Internal.Trace") before it copies its payload, which an
-- ordinary run, whose trace is stopped, answers with one 'IORef' read. A
-- callback for an attribute the backend cannot report does not run at all, so
-- it records nothing; X11 and Cocoa report every attribute.
-- Anything a callback raises is caught there with its context and latched
-- instead of unwinding into C; only the first is kept, and later ones are
-- counted. The focus callback is the one owner of focus: it coalesces the
-- latest flag into the observation and stages an ordered focus event for the
-- input feed. There is no second focus callback.
module Hetoimasia.GLFW.Internal.Window.Callbacks
  ( windowCallbacks
  , takeCaptures
  , raiseFault
  , rethrowFault
  ) where

import Control.Exception (ExceptionWithContext, SomeException, evaluate, rethrowIO, try, tryWithContext, uninterruptibleMask_)
import Control.Monad (when)
import Data.Bits (testBit)
import Data.Char (chr)
import Data.IORef (IORef, atomicModifyIORef')
import Data.Text (Text)
import qualified Data.Text as Text
import Foreign.C.Types (CInt)
import Hetoimasia.Foundation.Failure (withOperationContext)
import Hetoimasia.GLFW.Internal.Attribute (ContentScale (..), CursorPosition (..), Extent (..), Placement (..))
import Hetoimasia.GLFW.Internal.Control (WindowCapabilities, WindowReport (..), reportable)
import Hetoimasia.GLFW.Internal.Input
  ( ButtonAction (..)
  , ButtonEvent (..)
  , KeyAction (..)
  , KeyEvent (..)
  , Modifiers (..)
  , ScrollEvent (..)
  )
import Hetoimasia.GLFW.Internal.Session (WindowCallbacks (..), glfwComponent)
import Hetoimasia.GLFW.Internal.Trace (Trace, TraceEvent (..), recordTrace)
import Hetoimasia.GLFW.Internal.Window.Identity (WindowId)
import Hetoimasia.GLFW.Internal.Window.State
  ( CallbackFault (..)
  , Captures (..)
  , StagedInput (..)
  , inputStagingCapacity
  , noCaptures
  , windowCallbackOperation
  , windowIdentifiers
  )

-- | The contained callbacks recording into one window's capture latch. A
-- callback for an attribute the platform cannot report records nothing, so no
-- observation of it is fabricated.
windowCallbacks ∷ WindowCapabilities → Trace → Text → IORef Captures → WindowCallbacks
windowCallbacks capabilities trace label captures =
  WindowCallbacks
    { onWindowSize = \width height →
        reported LogicalExtentReport . contained "window size" $ do
          extent ← extentOf width height
          pure (\latched → latched {capturedSize = Just extent})
    , onFramebufferSize = \width height →
        reported FramebufferExtentReport . contained "framebuffer size" $ do
          extent ← extentOf width height
          pure (\latched → latched {capturedFramebuffer = Just extent})
    , onContentScale = \x y →
        reported ContentScaleReport . contained "content scale" $ do
          scale ← scaleOf x y
          pure (\latched → latched {capturedScale = Just scale})
    , onWindowPosition = \x y →
        reported PlacementReport . contained "window position" $ do
          placement ← placementOf x y
          pure (\latched → latched {capturedPlacement = Just placement})
    , onWindowFocus = \focused →
        reported FocusedReport . contained "window focus" $ do
          flag ← flagOf focused
          pure (\latched → stageInput (StagedFocus flag) (latched {capturedFocused = Just flag}))
    , onWindowIconify = \iconified →
        reported IconifiedReport . contained "window iconify" $ do
          flag ← flagOf iconified
          pure (\latched → latched {capturedIconified = Just flag})
    , onWindowMaximize = \maximized →
        reported MaximizedReport . contained "window maximize" $ do
          flag ← flagOf maximized
          pure (\latched → latched {capturedMaximized = Just flag})
    , onWindowRefresh =
        contained "window refresh" (pure (\latched → latched {capturedRefresh = True}))
    , onWindowClose =
        contained "window close" (pure (\latched → latched {capturedCloses = capturedCloses latched + 1}))
    , onKey = \key scancode action mods →
        contained "window key" $ do
          decoded ← KeyEvent <$> evaluate (fromIntegral key) <*> evaluate (fromIntegral scancode) <*> keyActionOf action <*> modifiersOf mods
          pure (stageInput (StagedKey decoded))
    , onChar = \codepoint →
        contained "window character" $ do
          decoded ← charOf codepoint
          pure (stageInput (StagedChar decoded))
    , onMouseButton = \button action mods →
        contained "window mouse button" $ do
          decodedAction ← buttonActionOf action
          decodedMods ← modifiersOf mods
          decodedButton ← evaluate (fromIntegral button)
          pure $ \latched →
            stageInput
              (StagedButton (ButtonEvent decodedButton decodedAction (capturedCursor latched) decodedMods))
              latched
    , onCursorPos = \x y →
        contained "window cursor position" $ do
          position ← CursorPosition <$> evaluate (realToFrac x) <*> evaluate (realToFrac y)
          pure (\latched → latched {capturedCursor = Just position})
    , onCursorEnter = \entered →
        contained "window cursor enter" $ do
          flag ← flagOf entered
          pure (\latched → latched {capturedCursorInside = Just flag})
    , onScroll = \x y →
        contained "window scroll" $ do
          decoded ← ScrollEvent <$> evaluate (realToFrac x) <*> evaluate (realToFrac y)
          pure (stageInput (StagedScroll decoded))
    }
  where
    reported report callback = when (reportable capabilities report) callback

    -- The trampoline. The payload is copied, and every field forced, inside
    -- the handler; the record is one non-blocking update. Anything raised is
    -- latched with its context rather than unwinding into C, and a failure to
    -- latch it is dropped for the same reason.
    contained ∷ Text → IO (Captures → Captures) → IO ()
    contained name capture = uninterruptibleMask_ $ do
      -- Offered before the payload is copied, so a delivery whose own latching
      -- then faults is still in the order. A stopped trace, which is every
      -- ordinary run, reads one 'IORef' and returns.
      recordTrace trace (CallbackDelivered label name)
      outcome ← tryWithContext capture
      case outcome of
        Right change → record change
        Left caught → do
          latched ← try (record (latchFault name caught))
          either (\(_ ∷ SomeException) → pure ()) pure latched

    record change =
      atomicModifyIORef' captures $ \latched →
        let changed = change latched
         in (changed {capturedGeneration = capturedGeneration latched + 1}, ())

    extentOf width height = Extent <$> evaluate (fromIntegral width) <*> evaluate (fromIntegral height)
    placementOf x y = Placement <$> evaluate (fromIntegral x) <*> evaluate (fromIntegral y)
    scaleOf x y = ContentScale <$> evaluate (realToFrac x) <*> evaluate (realToFrac y)
    flagOf ∷ CInt → IO Bool
    flagOf value = evaluate (value /= 0)
    -- GLFW_RELEASE, GLFW_PRESS, GLFW_REPEAT.
    keyActionOf code = case fromIntegral code ∷ Int of
      0 → pure KeyReleased
      1 → pure KeyPressed
      2 → pure KeyRepeated
      _ → ioError (userError "unknown key action")
    buttonActionOf code = case fromIntegral code ∷ Int of
      0 → pure ButtonReleased
      1 → pure ButtonPressed
      _ → ioError (userError "unknown button action")
    modifiersOf bits = do
      let value = fromIntegral bits ∷ Int
      evaluate
        Modifiers
          { modifierShift = testBit value 0
          , modifierControl = testBit value 1
          , modifierAlt = testBit value 2
          , modifierSuper = testBit value 3
          , modifierCapsLock = testBit value 4
          , modifierNumLock = testBit value 5
          }
    charOf codepoint = do
      let code = fromIntegral codepoint ∷ Int
      evaluate (chr code)

-- | Stage one ordered event, or set the loss latch when the buffer is full.
-- Later events while the latch is set are counted and not stored.
stageInput ∷ StagedInput → Captures → Captures
stageInput event latched
  | capturedInputLoss latched = countLost latched
  | capturedInputCount latched >= inputStagingCapacity = countLost (latched {capturedInputLoss = True})
  | otherwise =
      latched
        { capturedInput = event : capturedInput latched
        , capturedInputCount = capturedInputCount latched + 1
        }
  where
    countLost captures = captures {capturedInputLost = capturedInputLost captures + 1}

latchFault ∷ Text → ExceptionWithContext SomeException → Captures → Captures
latchFault name caught latched = case capturedFault latched of
  Nothing → latched {capturedFault = Just (CallbackFault name caught 0)}
  Just (CallbackFault first kept later) →
    latched {capturedFault = Just (CallbackFault first kept (later + 1))}

takeCaptures ∷ IORef Captures → IO Captures
takeCaptures captures =
  atomicModifyIORef' captures $ \latched →
    (noCaptures {capturedGeneration = capturedGeneration latched}, latched)

raiseFault ∷ WindowId → Captures → IO ()
raiseFault identity pending = mapM_ (rethrowFault (windowIdentifiers identity)) (capturedFault pending)

-- | Rethrow a latched callback fault with its own type and context. A
-- synchronous fault gains the callback operation's context; cancellation is
-- rethrown as it was.
rethrowFault ∷ [(Text, Text)] → CallbackFault → IO a
rethrowFault identifiers (CallbackFault name caught later) =
  withOperationContext
    glfwComponent
    windowCallbackOperation
    (identifiers <> [("callback", name), ("later-faults", Text.pack (show later))])
    (rethrowIO caught)
