-- | The helper threads the native examples start (#595): every one is owned, so however the scope that needed it ends (a
-- return, a failure, a timeout of the example, a cancellation) it has ended and been joined before the scope returns
-- ("Test.Support.Owned").
--
-- State owner: each call owns the one thread it starts and the cell that thread answers through. Thread: one helper per
-- call, started and joined by it. Lifetime: the call's. Disposal: the facility's release, which kills a thread that is
-- still waiting and joins it without being interruptible. Nothing here sleeps.
module Test.GPU.Vulkan.Native.Threads
  ( onOtherThread
  , raceOwned
  ) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Monad (void)
import Test.Support.Owned (withOwnedThread, withOwnedThreadOpening)

-- | Run the action on a thread of its own, wait for its answer, and answer it. The thread has ended, and been joined, when
-- this returns, whether the answer was awaited to the end or the wait for it was cancelled or failed.
onOtherThread ∷ IO a → IO a
onOtherThread action = do
  answer ← newEmptyMVar
  withOwnedThread (action >>= putMVar answer) (\_ _ → takeMVar answer)

-- | Start each action on a thread of its own, every one held at a gate until all are started, open the gate, and answer what
-- each answered, in order. The threads are nested scopes, so each has ended, and been joined, when this returns however it
-- ended; a gate that was never opened (the wait for an answer failed first) is opened by the scope that holds the threads
-- at it, before they are stopped.
raceOwned ∷ [IO a] → IO [a]
raceOwned actions = do
  gate ← newEmptyMVar
  answers ← mapM (const newEmptyMVar) actions
  let nest [] body = body
      nest ((action, answer) : rest) body =
        withOwnedThreadOpening (void (tryPutMVar gate ())) (readMVar gate >> action >>= putMVar answer) (\_ _ → nest rest body)
  nest (zip actions answers) (putMVar gate () >> mapM takeMVar answers)
