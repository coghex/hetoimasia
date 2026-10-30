-- | 'Hetoimasia.Run.Boot.abortable', the preparation's cancellable worker, as direct examples: what a stop
-- returns, what a failed cleanup under it is, what a failure keeps, and that a cancellation of the caller waits for
-- the child. No example sleeps: each is ordered by what the child has said it has reached.
module Test.Engine.Run.Abort (spec) where

import Control.Concurrent (ThreadId, forkIO, myThreadId, threadDelay, throwTo, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryReadMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception
  ( AsyncException (UserInterrupt)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , finally
  , fromException
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (forever, void)
import GHC.Conc (BlockReason (BlockedOnException, BlockedOnSTM), ThreadStatus (ThreadBlocked), threadStatus)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, withResource)
import Hetoimasia.Run.Boot (abortable)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "Abort" $ do
  it "answers the action's result when it ends before any stop" $
    bounded (abortable (pure False) (pure (5 ∷ Int))) >>= (`shouldBe` Just 5)

  it "answers Nothing for a stop whose cancellation unwound cleanly, after the child has ended" $ do
    started ← newEmptyMVar
    ended ← newEmptyMVar
    stopped ← newTVarIO False
    _ ← forkIO (takeMVar started >> atomically (writeTVar stopped True))
    answer ← bounded (abortable (readTVar stopped) ((putMVar started () >> forever (threadDelay 1000000)) `finally` putMVar ended ()))
    answer `shouldBe` (Nothing ∷ Maybe ())
    tryReadMVar ended >>= (`shouldBe` Just ())

  it "raises, with the cleanup evidence kept, when the cancelled work's cleanup fails: a stop is not an orderly one then" $ do
    started ← newEmptyMVar
    stopped ← newTVarIO False
    _ ← forkIO (takeMVar started >> atomically (writeTVar stopped True))
    let work = withResource (pure ()) (\_ → ioError (userError "preparation release failed")) (\_ → putMVar started () >> forever (threadDelay 1000000))
    bounded (tryWithContext @SomeException (abortable (readTVar stopped) work)) >>= \case
      Left (ExceptionWithContext context _) → length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)
      Right answered → expectationFailure ("a failed cleanup was reported as " <> show (fmap (const ()) answered))

  it "keeps the context of the child's own failure when it ends first" $ do
    let work = withResource (pure ()) (\_ → ioError (userError "release failed")) (\_ → ioError (userError "body failed") ∷ IO ())
    bounded (tryWithContext @SomeException (abortable (pure False) work)) >>= \case
      Left (ExceptionWithContext context _) → length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)
      Right _ → expectationFailure "the child's failure was lost"

  it "keeps the child's failed cleanup beside a cancellation of the caller that arrives while it waits" $ do
    started ← newEmptyMVar
    result ← newEmptyMVar
    caller ← newEmptyMVar
    let work = withResource (pure ()) (\_ → ioError (userError "preparation release failed")) (\_ → putMVar started () >> forever (threadDelay 1000000))
    _ ← forkIO $ do
      myThreadId >>= putMVar caller
      tryWithContext @SomeException (abortable (pure False) work) >>= putMVar result
    me ← takeMVar caller
    takeMVar started
    bounded (blockedFor BlockedOnSTM me)
    throwTo me UserInterrupt
    bounded (takeMVar result) >>= \case
      Left (ExceptionWithContext context failure) → do
        (fromException failure ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
        length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)
      Right _ → expectationFailure "the caller's cancellation was lost"

  it "keeps the child's failed cleanup beside a cancellation of the caller that arrives while it sends its own" $ do
    started ← newEmptyMVar
    gate ← newEmptyMVar
    result ← newEmptyMVar
    caller ← newEmptyMVar
    stopped ← newTVarIO False
    let work = withResource (pure ()) (\_ → ioError (userError "preparation release failed")) (\_ → uninterruptibleMask_ (putMVar started () >> takeMVar gate))
    _ ← forkIO $ do
      myThreadId >>= putMVar caller
      tryWithContext @SomeException (abortable (readTVar stopped) work) >>= putMVar result
    me ← takeMVar caller
    takeMVar started
    atomically (writeTVar stopped True)
    bounded (blockedSending me)
    throwTo me UserInterrupt
    putMVar gate ()
    bounded (takeMVar result) >>= \case
      Left (ExceptionWithContext context failure) → do
        (fromException failure ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
        length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)
      Right _ → expectationFailure "the caller's cancellation was lost"

  it "raises a cancellation of the caller only after the child has actually ended, even when the child holds delivery off" $ do
    caller ← newEmptyMVar
    started ← newEmptyMVar
    gate ← newEmptyMVar
    log' ← newTVarIO ([] ∷ [String])
    stopped ← newTVarIO False
    let note line = atomically (readTVar log' >>= writeTVar log' . (<> [line]))
        work = uninterruptibleMask_ (putMVar started () >> takeMVar gate) `finally` note "child ended"
    _ ← forkIO $ do
      me ← myThreadId
      putMVar caller me
      void (tryWithContext @SomeException (abortable (readTVar stopped) work)) `finally` note "caller left"
    parent ← takeMVar caller
    takeMVar started
    atomically (writeTVar stopped True)
    -- The caller sends its cancellation, which the child's held delivery makes wait. Interrupt it only once it is
    -- really blocked there (the runtime says so), so the interruption lands in the sending and not before it.
    bounded (blockedSending parent)
    throwTo parent UserInterrupt
    putMVar gate ()
    seen ← bounded (atomically (readTVar log' >>= \l → if length l < 2 then retry else pure l))
    seen `shouldBe` ["child ended", "caller left"]

-- | Wait until the thread is blocked in a @throwTo@ (an exception being sent that has not yet been received), by
-- looking at its state: a coordination on what the thread is doing, not a wait for time to pass.
blockedSending ∷ ThreadId → IO ()
blockedSending thread = threadStatus thread >>= \status →
  if status == ThreadBlocked BlockedOnException then pure () else yield >> blockedSending thread

-- | Wait until the thread is blocked for this reason.
blockedFor ∷ BlockReason → ThreadId → IO ()
blockedFor reason thread = threadStatus thread >>= \status →
  if status == ThreadBlocked reason then pure () else yield >> blockedFor reason thread
