-- | Boot interface for the window identity, so the input feed can name a
-- window without importing the window model that publishes into it.
module Hetoimasia.GLFW.Internal.Window
  ( WindowId
  , windowLocalIdentity
  ) where

import Control.DeepSeq (NFData)
import Numeric.Natural (Natural)

data WindowId

instance Eq WindowId
instance Ord WindowId
instance Show WindowId
instance NFData WindowId

windowLocalIdentity ∷ WindowId → Natural
