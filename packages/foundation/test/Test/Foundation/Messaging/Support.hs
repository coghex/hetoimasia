-- | Coordination fixtures the channel and snapshot examples share.
--
-- A gate is an 'MVar' a thread waits on, and 'awaitBlockedOnSTM' decides that a
-- thread has parked in a transaction. No fixture sleeps; 'boundedExample' only
-- stops an example that has already hung.
module Test.Foundation.Messaging.Support
  ( -- * Coordination
    Gate
  , newGate
  , openGate
  , awaitBlockedOnSTM
  , boundedExample
  ) where

import Control.Concurrent (ThreadId, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, tryPutMVar)
import Control.Monad (void)
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (ThreadBlocked), threadStatus)
import System.Timeout (timeout)
import Test.Hspec (Expectation, expectationFailure)

-- | A one-shot signal a thread waits on. Opening it twice is harmless.
type Gate = MVar ()

newGate ∷ IO Gate
newGate = newEmptyMVar

openGate ∷ Gate → IO ()
openGate gate = void (tryPutMVar gate ())

-- | Wait until a thread is parked in an STM transaction.
awaitBlockedOnSTM ∷ ThreadId → IO ()
awaitBlockedOnSTM thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnSTM → pure ()
    _ → yield >> awaitBlockedOnSTM thread

-- | Stop an example that has already hung. Never a concurrency assertion.
boundedExample ∷ Expectation → Expectation
boundedExample action =
  timeout (30 * 1000 * 1000) action
    >>= maybe (expectationFailure "the example did not finish within its bound") pure
