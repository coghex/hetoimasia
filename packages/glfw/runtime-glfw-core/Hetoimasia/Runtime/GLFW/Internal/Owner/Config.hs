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
import Hetoimasia.Foundation.Time (Duration, Instant, durationNanoseconds)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Operations (GraphicsOperations)

-- | How the owner waits for an absolute instant nothing else will wake it for.
--
-- It is injected for the same reason the host's clock is: an example must be
-- able to script when a deadline comes due instead of sleeping for it.
--
-- The owner reads its clock once for each arming, and gives the action two
-- things from that one reading: the deadline it is waiting for, an instant of
-- the owner's own clock, and the duration that remained until it at that
-- reading. Both its own wait and its exit drain's wait arm it this way; the
-- drain's fallback deadline, when the backend names none, is the fallback
-- interval after the drain's reading. The action arms a timer and answers a
-- transaction that becomes true once the deadline has come.
--
-- A timer that reads a clock decides expiry by comparing that clock with the
-- deadline it was given. It never reads the clock again to start an interval
-- of the given duration: the clock may have moved since the owner's reading,
-- and an interval started from a later reading ends after the owner's
-- deadline, so the owner sleeps past it. A timer with no clock of its own
-- uses the duration, as the process's timer does.
newtype OwnerTimer = OwnerTimer (Instant → Duration → IO (STM Bool))

-- | A timer from an action given each arming's deadline and the duration that
-- remained until it at the owner's reading.
ownerTimer ∷ (Instant → Duration → IO (STM Bool)) → OwnerTimer
ownerTimer = OwnerTimer

-- | The process's own timer, which is what production uses: one real-time
-- delay of the remaining duration, of at least a microsecond. Real time keeps
-- moving after the owner's reading, so the delay ends at most the time the
-- owner took to arm it after its deadline.
realtimeOwnerTimer ∷ OwnerTimer
realtimeOwnerTimer = OwnerTimer $ \_ duration →
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
