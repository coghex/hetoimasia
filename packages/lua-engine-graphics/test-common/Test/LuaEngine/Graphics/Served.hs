-- | A profile on an owned bound OS thread that outlives the host scope it is served by (#599).
--
-- The native suite runs its complete Hspec profile on a bound OS thread and serves the owner loop on the process main thread:
-- window creation, surfaces and native events belong to the main thread, and the examples' window scopes close and drain only
-- as the host services their commands. The host is therefore a supplier of the profile's own teardown, and a thread that waits
-- for it cannot be joined inside its scope: if the loop is left abnormally (a failure, a cancellation, a latched supervision
-- failure that makes serving the loop again impossible) the join would wait for a thread that waits for a host that has stopped
-- serving. So the thread's scope encloses the host's: the host's own teardown, which retires whatever the profile still holds,
-- runs first, and only then are the thread killed and joined, not interruptibly.
--
-- State owner: the caller owns the host scope and what it hands the profile; the helper owns the input cell and the thread.
-- Thread: the profile's, one bound thread, owned by 'withOwnedBoundThread' (#593) from before the host starts until after it
-- has ended. Lifetime: the call's. Disposal: the facility's release. Nothing here sleeps.
module Test.LuaEngine.Graphics.Served
  ( withProfileBeyond
  ) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Test.Support.Owned (withOwnedBoundThread)

-- | Start the profile on an owned bound thread, where it waits for its input, and run the host scope, which is handed the
-- function that gives the profile its input. The thread is killed and joined when the host scope has ended however it ended,
-- including when it ended before the input was handed over.
withProfileBeyond ∷ (a → IO ()) → ((a → IO ()) → IO r) → IO r
withProfileBeyond profile hostScope = do
  input ← newEmptyMVar
  withOwnedBoundThread (readMVar input >>= profile) $ \_ _ → hostScope (putMVar input)
