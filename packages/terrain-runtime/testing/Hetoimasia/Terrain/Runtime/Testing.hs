-- | FOR TEST SUITES ONLY. The one way a suite outside this package builds the production terrain service with an injected
-- storage seam: hooks the storage backend's workers run immediately before and after each native operation (to hold a worker at
-- a causal gate), over an adapter whose answers a test may replace (to fail a reservation, a read or a write as the platform
-- would). Nothing else of the service changes: the service, its owner, the storage backend's workers, queue and accounting are
-- the production ones, and an application uses 'Hetoimasia.Terrain.Runtime.storagePort', whose seam is the platform's own with no
-- hooks. Only test suites depend on this library.
module Hetoimasia.Terrain.Runtime.Testing
  ( -- * A port with a seam
    storagePortWithSeam

    -- * The seam
  , Seam (..)
  , productionSeam
  , Native (..)
  , posixNative
  , NativeOp (..)
  , NativeStat (..)
  , NativeFs (..)
  , Fd
  , Errno (..)
  ) where

import Data.ByteString (ByteString)
import Hetoimasia.Foundation.Worker (WorkerGroup)
import Hetoimasia.Terrain.Runtime.Backed.Port (StoragePort (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (Fd, Native (..), NativeFs (..), NativeOp (..), NativeStat (..), Seam (..), posixNative, productionSeam)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (Errno (..), StorageConfig)

-- | 'Hetoimasia.Terrain.Runtime.storagePort' with this seam in place of the platform's own: the worker group the storage
-- backend's two workers start in, its validated configuration, the directory the arenas' files are created in, and the seam.
storagePortWithSeam ∷ WorkerGroup → StorageConfig → ByteString → Seam → StoragePort
storagePortWithSeam = StoragePort
