-- | What an application asks of a window, validated before anything is
-- acquired or converted to C.
--
-- Values only. A configuration is checked on the thread that asks for the
-- window, and the validated request is read once, on the session's owner
-- thread, by "Hetoimasia.GLFW.Internal.Window.Construction".
module Hetoimasia.GLFW.Internal.Window.Config
  ( WindowConfig (..)
  , defaultWindowConfig
  , hiddenTestWindowConfig
  , WindowConfigRejected (..)
  , validateWindowConfig
  , Request (..)
  , validRequest
  ) where

import Control.DeepSeq (NFData (rnf))
import Control.Exception (Exception)
import Control.Monad (void)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.GLFW.Internal.Mode (StartupMode)
import Hetoimasia.GLFW.Internal.Session (WindowHint (..))

-- | What the application asks of a window. It is a pure value, validated before
-- anything is acquired or converted to C.
data WindowConfig = WindowConfig
  { windowTitle ∷ !Text
  , windowWidth ∷ !Int
    -- ^ The requested content width in screen coordinates.
  , windowHeight ∷ !Int
    -- ^ The requested content height in screen coordinates.
  , windowVisible ∷ !Bool
    -- ^ Whether the window is shown when created.
  , windowFocused ∷ !Bool
    -- ^ Whether a window shown at creation requests input focus.
  , windowFocusOnShow ∷ !Bool
    -- ^ Whether showing the window later requests input focus.
  , windowStartupMode ∷ !(Maybe StartupMode)
    -- ^ A mode the window transitions to during creation, after its initial
    -- observation seeded its saved placement.
  }
  deriving (Eq, Show)

instance NFData WindowConfig where
  rnf (WindowConfig title width height visible focused focusOnShow startup) =
    rnf title `seq` rnf width `seq` rnf height `seq` rnf visible `seq` rnf focused `seq` rnf focusOnShow `seq` rnf startup

-- | A shown window that takes focus, of the given title and logical size.
defaultWindowConfig ∷ Text → Int → Int → WindowConfig
defaultWindowConfig title width height =
  WindowConfig
    { windowTitle = title
    , windowWidth = width
    , windowHeight = height
    , windowVisible = True
    , windowFocused = True
    , windowFocusOnShow = True
    , windowStartupMode = Nothing
    }

-- | The test configuration: hidden, not focused, and not focused when shown.
hiddenTestWindowConfig ∷ Text → Int → Int → WindowConfig
hiddenTestWindowConfig title width height =
  (defaultWindowConfig title width height)
    { windowVisible = False
    , windowFocused = False
    , windowFocusOnShow = False
    }

-- | A configuration no window is created from.
data WindowConfigRejected
  = WindowExtentRejected
      { rejectedWidth ∷ !Int
      , rejectedHeight ∷ !Int
      }
    -- ^ A dimension is not in @1 .. 2147483647@.
  | WindowTitleRejected
    -- ^ The title contains a NUL, which C would truncate.
  deriving (Eq, Show)

instance NFData WindowConfigRejected where
  rnf (WindowExtentRejected width height) = rnf width `seq` rnf height
  rnf WindowTitleRejected = ()

instance Exception WindowConfigRejected

-- | The validated request, in the types the native table takes.
data Request = Request !Text !Int32 !Int32 ![WindowHint]

-- | Check a configuration without acquiring anything.
validateWindowConfig ∷ WindowConfig → Either WindowConfigRejected ()
validateWindowConfig = void . validRequest

validRequest ∷ WindowConfig → Either WindowConfigRejected Request
validRequest config
  | not (inRange (windowWidth config) && inRange (windowHeight config)) =
      Left (WindowExtentRejected (windowWidth config) (windowHeight config))
  | Text.elem '\NUL' (windowTitle config) = Left WindowTitleRejected
  | otherwise =
      Right
        ( Request
            (windowTitle config)
            (fromIntegral (windowWidth config))
            (fromIntegral (windowHeight config))
            [ NoClientApi
            , VisibleHint (windowVisible config)
            , FocusedHint (windowFocused config)
            , FocusOnShowHint (windowFocusOnShow config)
            ]
        )
  where
    inRange dimension = dimension >= 1 && toInteger dimension <= toInteger (maxBound ∷ Int32)
