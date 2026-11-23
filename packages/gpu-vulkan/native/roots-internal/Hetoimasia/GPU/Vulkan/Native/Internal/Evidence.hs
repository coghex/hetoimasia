-- | A transaction attempt that must not wait for diagnostic evidence inside its publication.
--
-- When a failure of the owner's own is ordered behind a diagnostic failure whose evidence another thread has not yet
-- made readable (a sink failure's reason, or a failure that arrived behind a void claim), the attempt abandons itself
-- ('evidencePending'): it writes and publishes nothing. 'Hetoimasia.GPU.Vulkan.Native.Atomically.atomically' then
-- waits for that evidence outside any transaction and runs the transaction again, which claims the capture's order
-- afresh, as a rerun of an abandoned attempt always does.
--
-- __State.__ None.
module Hetoimasia.GPU.Vulkan.Native.Internal.Evidence
  ( EvidencePending (..)
  , evidencePending
  ) where

import Control.Concurrent.STM (STM, throwSTM)
import Control.Exception (Exception)

-- | Abandon this attempt until the wait outside it has returned.
newtype EvidencePending = EvidencePending (IO ())

instance Show EvidencePending where
  show _ = "EvidencePending"

instance Exception EvidencePending

-- | Abandon the attempt: nothing it wrote is kept, and the wait runs outside it.
evidencePending ∷ IO () → STM a
evidencePending = throwSTM . EvidencePending
