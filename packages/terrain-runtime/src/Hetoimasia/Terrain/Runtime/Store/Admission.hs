-- | The storage-aware admission decisions for the edit bank (TRA-20): the
-- division of the 64 MiB edit bank, its all-or-nothing credits and the
-- classification of refusals. The module is documented at its implementation,
-- "Hetoimasia.Terrain.Runtime.Store.Internal.Admission", which lives in the
-- package's private @store@ library so that the storage backend (TRA-21), which
-- charges the same admission, can sit beside it without a dependency cycle through
-- this library. Nothing about the module's behavior changed when it moved.
module Hetoimasia.Terrain.Runtime.Store.Admission
  ( module Hetoimasia.Terrain.Runtime.Store.Internal.Admission
  ) where

import Hetoimasia.Terrain.Runtime.Store.Internal.Admission
