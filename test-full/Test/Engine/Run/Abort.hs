-- | 'Hetoimasia.Run.Boot.abortable', the preparation's cancellable worker, as direct examples: what a stop
-- returns, what a failed cleanup under it is, what a failure keeps, and that a cancellation of the caller waits for
-- the child. No example sleeps: each is ordered by what the child has said it has reached.
--
-- Every helper thread an example starts is owned by it (#600): the thread has ended and been joined when the example's scope
-- returns, whether the example returned, failed or was cancelled. The one that is held uninterruptibly has its gate opened
-- by the scope itself, which the last examples judge, with the negative control that runs the same scenario over an unowned
-- start.
module Test.Engine.Run.Abort (spec) where

import Control.Concurrent (ThreadId, threadDelay, throwTo, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryReadMVar)
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
import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import GHC.Conc (BlockReason (BlockedOnException, BlockedOnSTM), ThreadStatus (ThreadBlocked), threadStatus)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, withResource)
import Hetoimasia.Run.Boot (abortable)
import Test.Engine.Unowned (Cleanups, Ending, Scope, cleanupLater, endings, hasEnded, newCleanups, ownedScope, runCleanups, runEnding, unownedScope)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread, withOwnedThreadOpening)

spec ∷ Spec
spec = describe "Abort" $ do
  it "answers the action's result when it ends before any stop" $
    bounded (abortable (pure False) (pure (5 ∷ Int))) >>= (`shouldBe` Just 5)

  it "answers Nothing for a stop whose cancellation unwound cleanly, after the child has ended" $ do
    started ← newEmptyMVar
    ended ← newEmptyMVar
    stopped ← newTVarIO False
    -- The stopper waits for the work to start and then asks it to stop; it is owned, so an example that fails before the work
    -- starts does not leave it waiting.
    withOwnedThread (takeMVar started >> atomically (writeTVar stopped True)) $ \_ _ → do
      answer ← bounded (abortable (readTVar stopped) ((putMVar started () >> forever (threadDelay 1000000)) `finally` putMVar ended ()))
      answer `shouldBe` (Nothing ∷ Maybe ())
      tryReadMVar ended >>= (`shouldBe` Just ())

  it "raises, with the cleanup evidence kept, when the cancelled work's cleanup fails: a stop is not an orderly one then" $ do
    started ← newEmptyMVar
    stopped ← newTVarIO False
    let work = withResource (pure ()) (\_ → ioError (userError "preparation release failed")) (\_ → putMVar started () >> forever (threadDelay 1000000))
    withOwnedThread (takeMVar started >> atomically (writeTVar stopped True)) $ \_ _ →
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
    let work = withResource (pure ()) (\_ → ioError (userError "preparation release failed")) (\_ → putMVar started () >> forever (threadDelay 1000000))
    withOwnedThread (tryWithContext @SomeException (abortable (pure False) work) >>= putMVar result) $ \me _ → do
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
    stopped ← newTVarIO False
    let work = withResource (pure ()) (\_ → ioError (userError "preparation release failed")) (\_ → uninterruptibleMask_ (putMVar started () >> takeMVar gate))
    -- The child holds delivery off in the resource's body, so the caller blocks sending its cancellation. Only the example opens
    -- the gate, so the scope opens it too (idempotently) before it kills and joins the caller, on every way out.
    withOwnedThreadOpening (void (tryPutMVar gate ())) (tryWithContext @SomeException (abortable (readTVar stopped) work) >>= putMVar result) $ \me _ → do
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
    started ← newEmptyMVar
    gate ← newEmptyMVar
    log' ← newTVarIO ([] ∷ [String])
    stopped ← newTVarIO False
    let note line = atomically (readTVar log' >>= writeTVar log' . (<> [line]))
        work = uninterruptibleMask_ (putMVar started () >> takeMVar gate) `finally` note "child ended"
        caller = void (tryWithContext @SomeException (abortable (readTVar stopped) work)) `finally` note "caller left"
    -- The gate is opened by the example, and by the scope on any other way out.
    withOwnedThreadOpening (void (tryPutMVar gate ())) caller $ \parent _ → do
      takeMVar started
      atomically (writeTVar stopped True)
      -- The caller sends its cancellation, which the child's held delivery makes wait. Interrupt it only once it is
      -- really blocked there (the runtime says so), so the interruption lands in the sending and not before it.
      bounded (blockedSending parent)
      throwTo parent UserInterrupt
      putMVar gate ()
      seen ← bounded (atomically (readTVar log' >>= \l → if length l < 2 then retry else pure l))
      seen `shouldBe` ["child ended", "caller left"]

  describe "the caller held uninterruptibly by the child it asked to stop is owned (#600)" $
    for_ endings $ \(label, ending) → do
      it ("has ended and been joined, with its child, when the scope returns because " <> label) $ do
        cleanups ← newCleanups
        callerHeldByItsChild ending cleanups ownedScope >>= (`shouldBe` True)
      it ("negative control: an unowned caller is left blocked sending its cancellation when the scope returns because " <> label) $ do
        cleanups ← newCleanups
        -- The judgement is recorded first; only then does anything independent open the gate and stop and join what was left.
        (callerHeldByItsChild ending cleanups (unownedScope cleanups) >>= (`shouldBe` False)) `finally` runCleanups cleanups

-- | The arrangement of the example above, ended the way the ending says in place of the example's own steps: the child
-- holds delivery off in the resource's body, the caller (started in this kind of scope) blocks sending its cancellation to it
-- and the scope ends there. The answer is whether, when the scope has returned, the caller has ended and been joined and so
-- has the child. The caller can only end once the child's gate is opened, which is why the scope is given it.
callerHeldByItsChild ∷ Ending → Cleanups → Scope → IO Bool
callerHeldByItsChild ending cleanups scope = do
  started ← newEmptyMVar
  gate ← newEmptyMVar
  childEnded ← newEmptyMVar
  stopped ← newTVarIO False
  seen ← newIORef Nothing
  let work =
        withResource (pure ()) (\_ → ioError (userError "preparation release failed")) (\_ → uninterruptibleMask_ (putMVar started () >> takeMVar gate))
          `finally` void (tryPutMVar childEnded ())
      caller = void (tryWithContext @SomeException (abortable (readTVar stopped) work))
  -- A control that left the caller blocked also leaves the child held; its end is awaited last, once the gate is opened.
  cleanupLater cleanups (bounded (readMVar childEnded))
  runEnding ending $ \end →
    scope (void (tryPutMVar gate ())) caller $ \me _ → do
      writeIORef seen (Just me)
      takeMVar started
      atomically (writeTVar stopped True)
      end (bounded (blockedSending me))
  readIORef seen >>= maybe (pure False) hasEnded >>= \callerEnded →
    if callerEnded then isJust <$> tryReadMVar childEnded else pure False

-- | Wait until the thread is blocked in a @throwTo@ (an exception being sent that has not yet been received), by
-- looking at its state: a coordination on what the thread is doing, not a wait for time to pass.
blockedSending ∷ ThreadId → IO ()
blockedSending thread = threadStatus thread >>= \status →
  if status == ThreadBlocked BlockedOnException then pure () else yield >> blockedSending thread

-- | Wait until the thread is blocked for this reason.
blockedFor ∷ BlockReason → ThreadId → IO ()
blockedFor reason thread = threadStatus thread >>= \status →
  if status == ThreadBlocked reason then pure () else yield >> blockedFor reason thread
