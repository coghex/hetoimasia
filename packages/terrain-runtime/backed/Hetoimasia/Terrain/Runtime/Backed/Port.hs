-- | What the terrain service needs to keep its arenas' private files (TRA-22): the worker
-- group the storage backend's two workers start in, the backend's validated configuration
-- (the qualified filesystems and the headroom), the directory the files are created in, and
-- the native adapter.
--
-- The application assembly chooses the group and the directory; the service runs the backend
-- inside its own scope ('Hetoimasia.Terrain.Runtime.withTerrainService'), so the backend
-- outlives every arena and the owner. 'storagePort' is the production adapter; this
-- package's suite builds a port with a seam that injects faults at the native boundary
-- (the constructor is visible only to the package's own private libraries and suite).
module Hetoimasia.Terrain.Runtime.Backed.Port
  ( StoragePort (..)
  , storagePort
  ) where

import Data.ByteString (ByteString)
import Hetoimasia.Foundation.Worker (WorkerGroup)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (Seam, productionSeam)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (StorageConfig)

data StoragePort = StoragePort
  { spGroup ∷ !WorkerGroup
  , spConfig ∷ !StorageConfig
  , -- | The directory, as the bytes the platform names it by (no implicit current directory).
    spDirectory ∷ !ByteString
  , spSeam ∷ !Seam
  }

-- | The production port: the platform's native adapter.
storagePort ∷ WorkerGroup → StorageConfig → ByteString → StoragePort
storagePort group config directory = StoragePort group config directory productionSeam
