-- | Run a transaction of the native layers: 'Control.Concurrent.STM.atomically', except that an attempt which a
-- failure ordered behind diagnostic evidence not yet readable abandoned ('Hetoimasia.GPU.Vulkan.Native.Internal.Evidence')
-- waits for that evidence here, outside any transaction, and runs the transaction again. Nothing of an abandoned
-- attempt is written or published, so the failure's publication never waits on another thread.
--
-- The wait yields between looks and is otherwise not interruptible, as the transaction itself is not: a masked
-- caller's record is not lost to a cancellation while it waits. It is bounded by the other thread's bookkeeping
-- alone (the sink worker publishes its reason right after its claim; a callback sets its alarm right after its
-- arrival), never by a driver, the sink or anything the owner does.
--
-- __State.__ None.
module Hetoimasia.GPU.Vulkan.Native.Atomically
  ( atomically
  ) where

import Control.Concurrent.STM (STM)
import qualified Control.Concurrent.STM as STM
import Control.Exception (try)
import Hetoimasia.GPU.Vulkan.Native.Internal.Evidence (EvidencePending (..))

-- | Run this transaction once it can commit without waiting on diagnostic evidence.
atomically ∷ STM a → IO a
atomically transaction = attempt
  where
    attempt =
      try (STM.atomically transaction) >>= \case
        Right answer → pure answer
        Left (EvidencePending await) → await >> attempt
