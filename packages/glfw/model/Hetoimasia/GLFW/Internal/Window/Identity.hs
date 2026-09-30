-- | A window's identity: the leaf both the window model and the input feed
-- name a window by.
--
-- Values only. An identity is issued once, on the session's owner thread, by
-- "Hetoimasia.GLFW.Internal.Window.Construction", from the session's identity
-- and a local number the session never reissues; it is immutable and any
-- thread may read it. The constructor is private to this module, so no other
-- module can forge one.
module Hetoimasia.GLFW.Internal.Window.Identity
  ( WindowId
  , issuedWindowId
  , windowLocalIdentity
  , windowSessionIdentity
  ) where

import Control.DeepSeq (NFData (rnf))
import Data.Unique (Unique)
import Numeric.Natural (Natural)

-- | A window's identity: its session's identity and a local number that
-- session never reissues. Only the local number is displayed.
data WindowId = WindowId !Unique !Natural
  deriving (Eq, Ord)

instance Show WindowId where
  showsPrec precedence (WindowId _ local) =
    showParen (precedence > 10) (showString "WindowId " . showsPrec 11 local)

instance NFData WindowId where
  rnf (WindowId identity local) = identity `seq` rnf local


-- | The identity a session issues for its window with this local number.
issuedWindowId ∷ Unique → Natural → WindowId
issuedWindowId = WindowId

-- | The window's number within its session, starting at one.
windowLocalIdentity ∷ WindowId → Natural
windowLocalIdentity (WindowId _ local) = local

-- | The identity of the session that issued the window.
windowSessionIdentity ∷ WindowId → Unique
windowSessionIdentity (WindowId identity _) = identity
