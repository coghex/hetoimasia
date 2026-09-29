-- | What one graphics owner is built from: its injected operations, its label
-- and initial scene, its lifetime port's capacity, and the timer it waits for
-- its own deadlines with.
--
-- Values only. The configuration is fixed when the owner starts and is read by
-- the owner thread; an 'OwnerTimer' is armed on the owner thread by its wait
-- and by its exit drain.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Config
  ( GraphicsOwnerConfig (..)
  , graphicsOwnerConfig
  , OwnerTimer (..)
  , ownerTimer
  , realtimeOwnerTimer
  , graphicsOwnerComponent
  ) where

import Control.Concurrent.STM (STM, readTVar, registerDelay)
import Data.Text (Text)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Hetoimasia.Foundation.Time (Duration, durationNanoseconds)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Operations (GraphicsOperations)

-- | How the owner waits for an absolute instant nothing else will wake it for.
--
-- It is injected for the same reason the host's clock is: an example must be
-- able to script when a deadline comes due instead of sleeping for it. The
-- action arms a timer for the duration and answers a transaction that becomes
-- true once it has elapsed.
newtype OwnerTimer = OwnerTimer (Duration → IO (STM Bool))

ownerTimer ∷ (Duration → IO (STM Bool)) → OwnerTimer
ownerTimer = OwnerTimer

-- | The process's own timer, which is what production uses.
realtimeOwnerTimer ∷ OwnerTimer
realtimeOwnerTimer = OwnerTimer $ \duration →
  readTVar <$> registerDelay (max 1 (fromIntegral (durationNanoseconds duration `div` 1000)))

-- | What one graphics owner is built from.
data GraphicsOwnerConfig scene = GraphicsOwnerConfig
  { ownerOperations ∷ !(GraphicsOperations scene)
  , ownerLabel ∷ !Text
    -- ^ The worker's label, which its group report and every diagnostic names.
  , ownerScene ∷ !(Prepared scene)
    -- ^ The scene the owner holds before any application thread has published
    -- one. It is the application's own value, prepared by the application, so
    -- this package needs no @NFData@ instance for it.
  , ownerEventCapacity ∷ !Int
    -- ^ How many attachment lifetime events the owner's one ordinary bounded
    -- port holds. At least one.
  , ownerClockTimer ∷ !OwnerTimer
  }

-- | A configuration over the given operations and initial scene: the label
-- @graphics-owner@, a lifetime port of sixteen events, and the process timer.
--
-- There is no disposition to choose. This delivery's graphics owner is
-- __required__: its terminal failure stops the run. An owner-wide optional
-- disposition would have to mean a recognized failure leaves the component
-- unavailable while the run continues, and nothing here implements that — the
-- owner would still latch, still retire, and the supervision sentinel would
-- still classify its failure as unrecognized and so fatal. The per-target
-- required\/optional policy the Vulkan design accepts is a different
-- question, about one target's recovery rather than the owner's, and it is
-- VK-14's.
graphicsOwnerConfig ∷ GraphicsOperations scene → Prepared scene → GraphicsOwnerConfig scene
graphicsOwnerConfig operations scene =
  GraphicsOwnerConfig
    { ownerOperations = operations
    , ownerLabel = "graphics-owner"
    , ownerScene = scene
    , ownerEventCapacity = 16
    , ownerClockTimer = realtimeOwnerTimer
    }

-- | The component the owner's own diagnostics are written under.
graphicsOwnerComponent ∷ Component
graphicsOwnerComponent = unsafeComponent "glfw.graphics-owner"
