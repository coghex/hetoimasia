-- | The host's demand slots: the application's one, and each window's.
--
-- The slots are the host's, in "Hetoimasia.Runtime.GLFW.Internal.Host.State",
-- and their protocol is "Hetoimasia.GLFW.Internal.Demand"'s. Workers on any
-- thread publish through the capabilities lent here; only the owner thread,
-- the process main thread, captures. Status reads answer on any thread.
module Hetoimasia.Runtime.GLFW.Internal.Host.Demand
  ( hostDemandPublisher
  , captureHostDemand
  , captureWindowDemand
  , hostDemandStatus
  , windowDemandStatus
  ) where

import Control.Concurrent.STM (STM, atomically, readTVar)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Failure (Operation, operation)
import Hetoimasia.GLFW.Internal.Command (commandHostNotifier)
import Hetoimasia.GLFW.Internal.Demand (CapturedDemand, DemandPublisher, DemandStatus, captureDemand, demandPublisher, demandStatus)
import Hetoimasia.GLFW.Internal.Session (ownerOperation)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW.Internal.Host.State (HostEntry (..), WindowHost (..), windowIdentifiers)

captureOperation ∷ Operation
captureOperation = operation "capture demand"

-- | The application's demand publisher: the capability a worker uses to ask
-- the owner for a turn, immediately or by a deadline. It is one slot for every
-- worker, so concurrent requests combine rather than replace, and it is
-- rejected once the host has quiesced.
hostDemandPublisher ∷ WindowHost → DemandPublisher
hostDemandPublisher host = demandPublisher (hostDemandSlot host) (commandHostNotifier (hostCommands host))

-- | Take the application demand pending for the owner, clearing exactly what
-- was taken, on the owner thread. A publication that commits afterwards stays
-- pending for the next capture. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
captureHostDemand ∷ WindowHost → IO (Maybe CapturedDemand)
captureHostDemand host =
  ownerOperation (hostSession host) captureOperation [] (atomically (captureDemand (hostDemandSlot host)))

-- | 'captureHostDemand' for one window's slot. A window the host no longer
-- holds, and one whose slot has closed, answer 'Nothing'.
captureWindowDemand ∷ WindowHost → WindowId → IO (Maybe CapturedDemand)
captureWindowDemand host target =
  ownerOperation (hostSession host) captureOperation (windowIdentifiers target) $
    atomically $
      Map.lookup target <$> readTVar (hostEntries host) >>= \case
        Nothing → pure Nothing
        Just entry → captureDemand (entryDemand entry)

-- | The application slot's state, read in one transaction without capturing
-- anything. Any thread may read it.
hostDemandStatus ∷ WindowHost → STM DemandStatus
hostDemandStatus = demandStatus . hostDemandSlot

-- | One window's slot state, or 'Nothing' for a window the host no longer
-- holds. Any thread may read it.
windowDemandStatus ∷ WindowHost → WindowId → STM (Maybe DemandStatus)
windowDemandStatus host target =
  Map.lookup target <$> readTVar (hostEntries host) >>= traverse (demandStatus . entryDemand)
