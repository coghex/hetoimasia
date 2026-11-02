-- | The helper threads the native examples start are owned (#595): regressions for the start-and-wait helper
-- ("Test.GPU.Vulkan.Native.Threads"), each with a negative control.
--
-- The scenario parks the helper's action where only the scope's end can reach it, and ends the scope the way the example
-- says (the body fails, or the example is cancelled). The judgement is that, when the scope has returned, the thread has ended
-- and been joined. It holds through the helper; the control makes the same judgement of the unowned start the helper replaced
-- ('forkIO (action >>= putMVar answer)') and it must fail. The control records its failed judgement first and then stops and
-- joins what it left ('runCleanups'). The stepper and killer of "Test.GPU.Vulkan.Native.Generations" are covered beside the
-- rig that owns them.
module Test.GPU.Vulkan.Native.OwnedThreads (spec) where

import Control.Concurrent (myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception (finally)
import Control.Monad (void)
import Data.Foldable (for_)
import GHC.Conc (BlockReason (BlockedOnMVar))
import Test.GPU.Vulkan.Native.Threads (withOtherThread)
import Test.GPU.Vulkan.Native.Unowned
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "the start-and-wait helper owns its thread (#595)" $
  for_ endings $ \(label, ending) → do
    it ("has ended and been joined when the scope returns because " <> label) $ do
      cleanups ← newCleanups
      parkedHelper ending cleanups withOtherThread >>= (`shouldBe` True)
    it ("negative control: an unowned start leaves the thread parked when the scope returns because " <> label) $ do
      cleanups ← newCleanups
      -- The judgement is recorded first; only then is the parked helper let go, stopped and joined.
      (parkedHelper ending cleanups (unownedOtherThread cleanups) >>= (`shouldBe` False)) `finally` runCleanups cleanups

-- | The start-and-wait helper of a kind of start: the action on a thread of its own, and the wait for its answer handed to
-- the body.
type OtherThread = IO () → (IO () → IO ()) → IO ()

-- | The helper's former form: a thread started without a scope, whose independent stop-and-join is the control's.
unownedOtherThread ∷ Cleanups → OtherThread
unownedOtherThread cleanups action body = do
  answer ← newEmptyMVar
  unownedScope cleanups (pure ()) (action >>= putMVar answer) (\_ _ → body (takeMVar answer))

-- | An action parked on a cell nothing in the scenario fills, in the helper of this kind of start, with the scope ended the
-- way the ending says while it is parked. The answer is whether, when the scope has returned, its thread has ended.
parkedHelper ∷ Ending → Cleanups → OtherThread → IO Bool
parkedHelper ending cleanups helper = do
  never ← newEmptyMVar
  who ← newEmptyMVar
  -- Held by the continuation, so the runtime never takes the parked wait for a deadlock; and let go, last, by the control.
  cleanupLater cleanups (void (tryPutMVar never ()))
  runEnding ending $ \end →
    helper (myThreadId >>= putMVar who >> readMVar never) $ \_ → do
      thread ← readMVar who
      end (blockedFor BlockedOnMVar thread)
  judged ← bounded (readMVar who) >>= hasEnded
  void (tryPutMVar never ())
  pure judged
