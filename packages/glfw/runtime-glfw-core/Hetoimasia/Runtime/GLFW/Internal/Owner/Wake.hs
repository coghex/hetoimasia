-- | The one cross-thread capability the graphics owner holds: waking the
-- host's main thread through the session's existing notifier.
--
-- It runs on whichever thread publishes — the owner thread after a round, a
-- retained failure or its drain, or a thread publishing independent
-- whole-owner evidence. The notifier is the host's, owned by the session; this
-- module adds no state and grants the owner no GLFW operation.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Wake
  ( wakeGraphicsHost
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception (mask_)
import Control.Monad (void)
import Hetoimasia.GLFW.Internal.Notify (dischargeNotification, registerNotification)
import Hetoimasia.Runtime.GLFW.Internal.Owner.State (GraphicsOwner (ownerNotifier))

-- | Wake the host's main thread, exactly as an admitted completion notice
-- does.
--
-- This is the authorized cross-thread publication D-29 leaves open, not a GLFW
-- operation of the owner's: the obligation is registered in one transaction
-- and discharged by one call, which is the session's own wake machinery and
-- the same path a command admission takes. Everything else GLFW owns stays on
-- the main thread.
wakeGraphicsHost ∷ GraphicsOwner scene → IO ()
wakeGraphicsHost owner = mask_ $ do
  -- Masked as 'publishCompletion' masks its own: an obligation registered and
  -- then not discharged is one the protected exit waits for forever, and a
  -- cancellation delivered between the two would leave exactly that.
  atomically (registerNotification (ownerNotifier owner))
  void (dischargeNotification (ownerNotifier owner))
