-- | The cleanup failures an owner keeps until its end reports them.
--
-- An owner keeps the failures of its cleanup (the failure of closing a coroutine, of a release, of a
-- retirement, of a settlement) in lists that nothing else reads until the owner's turn ends, and each
-- is fatal: it ends the owner as a failure however the rest of its work came to. 'Evidence' is the one
-- way to keep one, and it publishes, in the same masked step, a notice any thread can read in STM that
-- the owner holds a failure that will end it. The application's wait for the owner's accounting reads that
-- notice, so it cannot complete in the interval between a failure being kept and the owner ending.
-- There is no way to write the list without the notice, and none to take a failure out of it.
module Hetoimasia.Scripting.Lua.Cleanup
  ( Evidence
  , newEvidence
  , retainCleanup
  , retainedCleanup
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (mask_)
import Control.Monad (unless)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)

-- | A list of cleanup failures the owner holds, and the notice that it holds any.
data Evidence a = Evidence !(IORef [a]) !(STM ())

-- | An empty list, given the transaction that publishes that the owner holds a failure.
newEvidence ∷ STM () → IO (Evidence a)
newEvidence notice = (`Evidence` notice) <$> newIORef []

-- | Keep these failures, and publish the notice, in one masked step: a cancellation cannot come between
-- and leave a failure kept that nothing published.
retainCleanup ∷ Evidence a → [a] → IO ()
retainCleanup (Evidence ref notice) found =
  unless (null found) . mask_ $ do
    atomically notice
    modifyIORef' ref (<> found)

-- | What is kept, oldest first.
retainedCleanup ∷ Evidence a → IO [a]
retainedCleanup (Evidence ref _) = readIORef ref
