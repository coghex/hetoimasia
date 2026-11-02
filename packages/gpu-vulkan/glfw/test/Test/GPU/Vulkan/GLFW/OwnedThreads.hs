-- | The helper threads of a run that serve its exit are owned (#595): regressions for 'withRunHelper' of
-- "Test.GPU.Vulkan.GLFW.StandIn", each with a negative control. The scene transition's thread is covered beside its rig, in
-- "Test.GPU.Vulkan.GLFW.Targets".
--
-- Two things are judged of an evidence supplier, the helper that publishes what a run's exit needs in order to finish:
--
-- * Ended and joined, however the example ends. The owner never reaches the state the supplier waits for because the example
--   failed (or was cancelled) first; the scope must still end the supplier and join it. The control makes the same judgement of
--   the unowned start the helper replaced.
-- * Not ended before the exit it serves. The supplier's scope must enclose the exit, not only the body that hands it its
--   arguments: it is judged still alive when the exit begins, and the exit finishes only on what it publishes. The control
--   makes the same judgement of the arrangement that scoped the supplier inside the body.
module Test.GPU.Vulkan.GLFW.OwnedThreads (spec) where

import Control.Concurrent (myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (finally)
import Control.Monad (void, when)
import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)
import GHC.Conc (BlockReason (BlockedOnSTM))
import Test.GPU.Vulkan.GLFW.Bound (boundOf, boundedIt)
import Test.GPU.Vulkan.GLFW.StandIn (withRunHelper)
import Test.GPU.Vulkan.GLFW.Unowned
import Test.Hspec (Spec, describe, shouldBe)
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread)

spec ∷ Spec
spec = describe "the helpers that serve a run's exit are owned (#595)" $ do
  for_ endings $ \(label, ending) → do
    itBounded ("has ended and been joined, a supplier whose owner never reached the state it waits for, when the scope returns because " <> label) $
      supplierParked ending withRunHelper >>= (`shouldBe` True)
    itBounded ("negative control: an unowned supplier is left waiting when the scope returns because " <> label) $ do
      cleanups ← newCleanups
      -- The judgement is recorded first; only then is the supplier stopped and joined.
      (supplierParked ending (unownedRunHelper cleanups) >>= (`shouldBe` False)) `finally` runCleanups cleanups
  itBounded "keeps a supplier alive until the exit it serves has begun, and the exit finishes on the evidence it publishes" $
    supplierAliveAtExit enclosingTheRun >>= (`shouldBe` True)
  itBounded "negative control: a supplier scoped inside the body is already ended when the exit begins" $
    supplierAliveAtExit scopedInsideBody >>= (`shouldBe` False)
  where
    itBounded = boundedIt (boundOf 60)

-- | A run helper of a kind of start: what the run's body hands the supplier, and the supplier waiting for it.
type RunHelper = IO () → (() → IO ()) → ((() → IO ()) → IO ()) → IO ()

-- | The helper's former form: a supplier started without a scope, parked until the body hands it what it needs, whose
-- independent stop-and-join is the control's.
unownedRunHelper ∷ Cleanups → RunHelper
unownedRunHelper cleanups open act body = do
  cell ← newTVarIO Nothing
  unownedScope cleanups open (atomically (readTVar cell >>= maybe retry pure) >>= act) $ \_ _ →
    body (atomically . writeTVar cell . Just)

-- | A supplier that waits on a cell nothing in the scenario fills, so it never reaches what it supplies, with the scope ended
-- the way the ending says once it is parked. The answer is whether, when the scope has returned, its thread has ended.
supplierParked ∷ Ending → RunHelper → IO Bool
supplierParked ending helper = do
  never ← newTVarIO False
  who ← newEmptyMVar
  runEnding ending $ \end →
    helper (pure ()) (\() → myThreadId >>= putMVar who >> atomically (readTVar never >>= check)) $ \supply → do
      supply ()
      thread ← readMVar who
      end (blockedFor BlockedOnSTM thread)
  judged ← bounded (readMVar who) >>= hasEnded
  atomically (writeTVar never True)
  pure judged

-- | A run whose exit begins when its body has returned and finishes only on what the supplier publishes. The answer is whether
-- the supplier was still alive when the exit began. The arrangement says how the supplier's scope relates to the run: given
-- the supplier, the body (which hands the supplier what it needs, and returns once the supplier has started) and the exit.
supplierAliveAtExit ∷ ((() → IO ()) → ((() → IO ()) → IO ()) → IO () → IO ()) → IO Bool
supplierAliveAtExit arrange = do
  exitBegun ← newEmptyMVar
  evidence ← newEmptyMVar
  who ← newEmptyMVar
  alive ← newIORef False
  let supplier () = myThreadId >>= putMVar who >> takeMVar exitBegun >> putMVar evidence ()
      body supply = supply () >> void (bounded (readMVar who))
      -- The exit the supplier serves: it ends only when the supplier has published, so an exit that began after the supplier
      -- ended is not waited on (it would never finish).
      exit = do
        thread ← readMVar who
        supplierAlive ← not <$> hasEnded thread
        writeIORef alive supplierAlive
        when supplierAlive (putMVar exitBegun () >> bounded (takeMVar evidence))
  arrange supplier body exit
  readIORef alive

-- | The supplier's scope encloses the whole run, as 'withRunHelper' makes it.
enclosingTheRun ∷ (() → IO ()) → ((() → IO ()) → IO ()) → IO () → IO ()
enclosingTheRun supplier body exit = withRunHelper (pure ()) supplier (\supply → body supply >> exit)

-- | The arrangement of the supplier before the exit was covered: owned, but only for the length of the body.
scopedInsideBody ∷ (() → IO ()) → ((() → IO ()) → IO ()) → IO () → IO ()
scopedInsideBody supplier body exit = do
  cell ← newTVarIO Nothing
  withOwnedThread (atomically (readTVar cell >>= maybe retry pure) >>= supplier) $ \_ _ →
    body (atomically . writeTVar cell . Just)
  exit
