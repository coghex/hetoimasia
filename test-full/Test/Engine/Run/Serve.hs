-- | 'Hetoimasia.Run.Serve.serve', the main thread's loop and the session's thread unwinding together, as direct
-- examples over a fake owner: no device, no window. The fake models the one dependency that makes a naive join
-- deadlock: the session's cleanup ends only once the owner's retirement has been served, and only the drain loop
-- (not the failed ordinary loop) serves it. No example sleeps; the ones that interrupt a thread wait until the
-- runtime reports it blocked where the interruption must land.
module Test.Engine.Run.Serve (spec) where

import Control.Concurrent (ThreadId, forkIO, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception
  ( AsyncException (UserInterrupt)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , finally
  , tryWithContext
  )
import Control.Monad (unless, void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import GHC.Conc (BlockReason (BlockedOnMVar, BlockedOnSTM), ThreadStatus (ThreadBlocked), threadStatus)
import Hetoimasia.Foundation.Log (Logger, LogFilter (..), callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, displayCleanupFailure, withResource)
import Hetoimasia.Run.Serve (Owner (..), drainAttempts, serve)
import Hetoimasia.Run.Session (awaitDiagnostics, newSessionLinkEndingWith)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Support.Bounded (bounded)

-- | What the fake owner has served.
data Fake = Fake
  { fakeRetired ∷ TVar Bool
  , fakeDrains ∷ TVar Int
  }

newFake ∷ IO Fake
newFake = Fake <$> newTVarIO False <*> newTVarIO 0

spinUntil ∷ IO Bool → IO ()
spinUntil over = over >>= \finished → unless finished (yield >> spinUntil over)

-- | A fake owner. Its ordinary loop fails at once with this, when given one, and otherwise runs the per-turn action
-- until the session is over. Its drain first does the given action (which may fail or wait), then serves
-- retirement, then runs until the session is over.
ownerWith ∷ Fake → Maybe String → IO () → Owner
ownerWith fake failure beforeServing =
  Owner
    { ownerServe = \turn over → maybe (pure ()) (ioError . userError) failure >> spinUntil (turn >> over)
    , ownerDrain = \over → do
        atomically (modifyTVar' (fakeDrains fake) (+ 1))
        beforeServing
        atomically (writeTVar (fakeRetired fake) True)
        spinUntil over
    , ownerWake = pure ()
    }

quiet ∷ IO ()
quiet = pure ()

logger ∷ Logger
logger = mkLogger defaultLogFilter {filterEnabled = False} (callbackSink (\_ → pure ()))

-- | The session of a window that is destroyed only once retirement has been served.
afterRetirement ∷ Fake → IO ()
afterRetirement fake = atomically (readTVar (fakeRetired fake) >>= check)

-- | Wait until a thread is blocked for this reason, by asking the runtime: coordination on what the thread is
-- doing, not a wait for time to pass.
blockedFor ∷ BlockReason → ThreadId → IO ()
blockedFor reason thread = bounded loop
  where
    loop = threadStatus thread >>= \status → unless (status == ThreadBlocked reason) (yield >> loop)

-- | Wait until this many lines were noted.
noted ∷ IORef [String] → Int → IO [String]
noted ref count = bounded loop
  where
    loop = readIORef ref >>= \l → if length l >= count then pure l else yield >> loop

failureText ∷ ExceptionWithContext SomeException → String
failureText (ExceptionWithContext _ failure) = show failure

spec ∷ Spec
spec = describe "Serve" $ do
  it "answers the session's result when the loop ends because the session did" $ do
    fake ← newFake
    bounded (serve logger (ownerWith fake Nothing quiet) quiet quiet (pure (7 ∷ Int))) >>= (`shouldBe` 7)

  it "raises the session's own failure, with its context, when the session fails and the loop is fine" $ do
    fake ← newFake
    let session = withResource (pure ()) (\_ → ioError (userError "session release failed")) (\_ → ioError (userError "session body failed")) ∷ IO ()
    bounded (tryWithContext @SomeException (serve logger (ownerWith fake Nothing quiet) quiet quiet session)) >>= \case
      Left (ExceptionWithContext context _) → length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)
      Right _ → expectationFailure "the session's failure was lost"

  it "serves retirement again after the loop fails, until the session settles, and raises the loop's failure" $ do
    fake ← newFake
    stops ← newIORef (0 ∷ Int)
    let stop = atomicModifyIORef' stops (\n → (n + 1, ()))
    bounded (tryWithContext @SomeException (serve logger (ownerWith fake (Just "the owner loop failed") quiet) stop quiet (afterRetirement fake))) >>= \case
      Left failure → failureText failure `shouldBe` "user error (the owner loop failed)"
      Right _ → expectationFailure "the loop's failure was lost"
    readTVarIO (fakeRetired fake) >>= (`shouldBe` True)
    readIORef stops >>= (`shouldBe` 1)

  it "runs a failing drain again a bounded number of times and still joins the session, which a failed owner settles" $ do
    fake ← newFake
    -- The session settles once the owner has been given up on: after every attempt, none of which served anything.
    let session = atomically (readTVar (fakeDrains fake) >>= check . (>= drainAttempts))
    bounded (tryWithContext @SomeException (serve logger (ownerWith fake (Just "the owner loop failed") (ioError (userError "the drain failed too"))) quiet quiet session)) >>= \case
      Left failure → failureText failure `shouldBe` "user error (the owner loop failed)"
      Right _ → expectationFailure "the loop's failure was lost"
    readTVarIO (fakeDrains fake) >>= (`shouldBe` drainAttempts)
    readTVarIO (fakeRetired fake) >>= (`shouldBe` False)

  it "keeps the session's cleanup failure beside the loop's failure when both fail" $ do
    fake ← newFake
    let session = afterRetirement fake >> ioError (userError "session cleanup failed")
    bounded (tryWithContext @SomeException (serve logger (ownerWith fake (Just "the owner loop failed") quiet) quiet quiet session)) >>= \case
      Left failure@(ExceptionWithContext context _) → do
        failureText failure `shouldBe` "user error (the owner loop failed)"
        map displayCleanupFailure (cleanupFailuresInContext context) `shouldSatisfy` any ("session cleanup failed" `isInfixOf`)
      Right _ → expectationFailure "both failures were lost"

  it "remembers a cancellation during the drain, serves again, and raises it only after the session has settled" $ do
    fake ← newFake
    order ← newIORef ([] ∷ [String])
    started ← newEmptyMVar
    gate ← newEmptyMVar
    caller ← newEmptyMVar
    let note line = atomicModifyIORef' order (\l → (l <> [line], ()))
        gated = ownerWith fake (Just "the owner loop failed") (putMVar started () >> takeMVar gate)
        session = afterRetirement fake `finally` note "session settled"
    _ ← forkIO $ do
      myThreadId >>= putMVar caller
      void (tryWithContext @SomeException (serve logger gated quiet quiet session)) `finally` note "serve left"
    me ← takeMVar caller
    takeMVar started
    -- The drain is parked on its gate: interrupt the caller there, then let the drain go.
    blockedFor BlockedOnMVar me
    throwTo me UserInterrupt
    putMVar gate ()
    noted order 2 >>= (`shouldBe` ["session settled", "serve left"])

  it "joins the session's diagnostics writer before the logger is released, and a cancellation meanwhile waits for it" $ do
    ended ← newTVarIO False
    link ← newSessionLinkEndingWith (readTVar ended)
    order ← newIORef ([] ∷ [String])
    caller ← newEmptyMVar
    let note line = atomicModifyIORef' order (\l → (l <> [line], ()))
    _ ← forkIO $ do
      myThreadId >>= putMVar caller
      void (tryWithContext @SomeException (awaitDiagnostics link)) `finally` note "join returned"
    me ← takeMVar caller
    blockedFor BlockedOnSTM me
    throwTo me UserInterrupt
    note "writer ended"
    atomically (writeTVar ended True)
    noted order 2 >>= (`shouldBe` ["writer ended", "join returned"])
