-- | A cancellation delivered to the example at a chosen moment, by a helper thread the scope owns (#584).
--
-- An example that must be cancelled after the thing under test has reached a stated point starts a helper that waits for
-- that point and then throws 'UserInterrupt' at the example's own thread. The helper is owned
-- ('Test.Support.Owned.withOwnedThread'): when the example ends before the point arrives, whether it failed, returned or was
-- itself cancelled, the helper is stopped and joined with it rather than left waiting for the rest of the process, and a
-- wait on the example's state ends when the example does instead of spinning.
--
-- State owner: the helper owns nothing but its own wait; the caller owns the point it waits for and anything the cancellation
-- is to release. Thread: one helper per scope, started and joined by the scope. Lifetime: the scope's. Disposal: the scope's
-- release. Nothing here sleeps, and nothing but @base@ is used.
module Test.Support.Cancel
  ( withCancellationAfter
  , withCancellationWhenBlocked
  , awaitBlockedSending
  ) where

import Control.Concurrent (ThreadId, myThreadId, throwTo, yield)
import Control.Exception (AsyncException (UserInterrupt), mask_)
import Control.Monad (when)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked, ThreadDied, ThreadFinished), threadStatus)
import Test.Support.Owned (withOwnedThread)

-- | Run the body, and once the event has happened deliver 'UserInterrupt' to the calling thread and then run what follows.
-- The event is a wait that returns when the point has been reached; the helper that waits for it is owned by the scope.
withCancellationAfter ∷ IO () → IO () → IO a → IO a
withCancellationAfter event afterwards body = do
  caller ← myThreadId
  withOwnedThread (event >> deliver caller afterwards) (\_ _ → body)

-- | 'withCancellationAfter', but the cancellation is held back until the calling thread is blocked sending an exception of
-- its own (an end it has asked a held thread to take): the moment the event and that blocking are both true. A calling
-- thread that ends before it ever blocks that way is not cancelled, and what follows does not run.
withCancellationWhenBlocked ∷ IO () → IO () → IO a → IO a
withCancellationWhenBlocked event afterwards body = do
  caller ← myThreadId
  withOwnedThread
    ( do
        event
        blocked ← awaitBlockedSending caller
        when blocked (deliver caller afterwards)
    )
    (\_ _ → body)

-- | Deliver the cancellation and run what follows it, as one step the scope's own release cannot split.
--
-- Once the exception is delivered the caller unwinds, and its release kills this helper. An unmasked helper could be killed
-- in the gap between @throwTo@ returning and @afterwards@ running, and then what the cancellation was to be followed by (a
-- gate opened) would not happen, on a runtime with more than one capability. Masked, the kill waits for the end of the
-- step, and the delivery itself stays interruptible: a caller that never receives it (it is in an uninterruptible release
-- waiting for this helper) is not waited on for ever, because the release's kill ends the delivery. @afterwards@ must not
-- block.
deliver ∷ ThreadId → IO () → IO ()
deliver caller afterwards = mask_ (throwTo caller UserInterrupt >> afterwards)

-- | Wait until the thread is blocked in a @throwTo@ (an end being sent that has not yet been received) and answer 'True'; or
-- answer 'False' when the thread has ended without ever being, because it will never block again. The only wait the runtime
-- offers on another thread's state is a yielding poll, which is why the terminal states matter: without them the poll would
-- never end for a thread that finished first.
awaitBlockedSending ∷ ThreadId → IO Bool
awaitBlockedSending thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnException → pure True
    ThreadFinished → pure False
    ThreadDied → pure False
    _ → yield >> awaitBlockedSending thread
