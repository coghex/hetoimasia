-- | 'Hetoimasia.Run.Serve', the main thread's loop and the session's thread unwinding together, as direct examples
-- over a fake owner: no device, no window. The fake models the dependency that makes a naive join deadlock: the
-- session's cleanup ends only once the owner's retirement has been served, by the drain loop (not the failed ordinary
-- loop) or, when no loop can be served any more, by the application's own protected exit (the example's 'exited').
-- No example sleeps; the ones that interrupt a thread wait until the runtime reports it blocked where the
-- interruption must land.
module Test.Engine.Run.Serve (spec) where

import Control.Concurrent (forkIO, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception
  ( AsyncException (UserInterrupt)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , catch
  , finally
  , fromException
  , mask_
  , throwIO
  , tryWithContext
  )
import Control.Monad (unless, void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import GHC.Conc (BlockReason (BlockedOnException, BlockedOnMVar, BlockedOnSTM))
import Hetoimasia.Foundation.Log (callbackSinkWith, defaultLogFilter)
import Hetoimasia.Run.Settle (withRecordingLifetime)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, displayCleanupFailure, withResource)
import Hetoimasia.Run.Serve (Owner (..), drainAttempts, joinFailure, runOwned, serveSpawned)
import Hetoimasia.Run.Session (awaitDiagnostics, newSessionLinkEndingWith)
import Hetoimasia.Runtime.Logging (failedReportsInContext, withLoggingLifetime)
import Test.Engine.Run.Support (blockedFor, silentLogger)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Support.Bounded (bounded)

-- | What the fake owner has served.
data Fake = Fake
  { fakeRetired ∷ TVar Bool
  , fakeDrains ∷ TVar Int
  , fakeExited ∷ TVar Bool
  -- ^ The application's protected exit has destroyed what the loop could not.
  }

newFake ∷ IO Fake
newFake = Fake <$> newTVarIO False <*> newTVarIO 0 <*> newTVarIO False

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

-- | The session of a window that is destroyed only once retirement has been served.
afterRetirement ∷ Fake → IO ()
afterRetirement fake = atomically (readTVar (fakeRetired fake) >>= check)

-- | Wait until this many lines were noted.
noted ∷ IORef [String] → Int → IO [String]
noted ref count = bounded loop
  where
    loop = readIORef ref >>= \l → if length l >= count then pure l else yield >> loop

failureText ∷ ExceptionWithContext SomeException → String
failureText (ExceptionWithContext _ failure) = show failure

-- | Start the session and serve it, as the command does, over a logging lifetime on a logger that writes nothing.
run ∷ Fake → Owner → IO () → IO a → IO a
run _ owner stopSession session =
  withLoggingLifetime silentLogger $ \lifetime → serveSpawned lifetime owner (\_ → pure ()) stopSession quiet session

spec ∷ Spec
spec = describe "Serve" $ do
  it "answers the session's result when the loop ends because the session did" $ do
    fake ← newFake
    bounded (run fake (ownerWith fake Nothing quiet) quiet (pure (7 ∷ Int))) >>= (`shouldBe` 7)

  it "raises the session's own failure, with its context, when the session fails and the loop is fine" $ do
    fake ← newFake
    let session = withResource (pure ()) (\_ → ioError (userError "session release failed")) (\_ → ioError (userError "session body failed")) ∷ IO ()
    bounded (tryWithContext @SomeException (run fake (ownerWith fake Nothing quiet) quiet session)) >>= \case
      Left (ExceptionWithContext context _) → length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)
      Right _ → expectationFailure "the session's failure was lost"

  it "serves retirement again after the loop fails, until the session settles, and raises the loop's failure" $ do
    fake ← newFake
    stops ← newIORef (0 ∷ Int)
    let stop = atomicModifyIORef' stops (\n → (n + 1, ()))
    bounded (tryWithContext @SomeException (run fake (ownerWith fake (Just "the owner loop failed") quiet) stop (afterRetirement fake))) >>= \case
      Left failure → failureText failure `shouldBe` "user error (the owner loop failed)"
      Right _ → expectationFailure "the loop's failure was lost"
    readTVarIO (fakeRetired fake) >>= (`shouldBe` True)
    readIORef stops >>= (`shouldBe` 1)

  it "keeps the session's cleanup failure beside the loop's failure when both fail" $ do
    fake ← newFake
    let session = afterRetirement fake >> ioError (userError "session cleanup failed")
    bounded (tryWithContext @SomeException (run fake (ownerWith fake (Just "the owner loop failed") quiet) quiet session)) >>= \case
      Left failure@(ExceptionWithContext context _) → do
        failureText failure `shouldBe` "user error (the owner loop failed)"
        map displayCleanupFailure (cleanupFailuresInContext context) `shouldSatisfy` any ("session cleanup failed" `isInfixOf`)
      Right _ → expectationFailure "both failures were lost"

  it "gives the owner back to its application when no loop can be served, without joining a session that still needs it, and joins it after" $ do
    fake ← newFake
    -- The drain never serves anything. The session ends only once the application's exit has destroyed what the
    -- loop could not, which is after the main thread has left 'serve'.
    let session = atomically (readTVar (fakeExited fake) >>= check) >> ioError (userError "session settled against the exit")
        owner = ownerWith fake (Just "the owner loop failed") (ioError (userError "the drain failed too"))
    spawnedRef ← newEmptyMVar
    outcome ← bounded $ tryWithContext @SomeException $ withLoggingLifetime silentLogger $ \lifetime →
      serveSpawned lifetime owner (putMVar spawnedRef) quiet quiet session
    -- Raised at once: every attempt was made, nothing was served, and the session is still unsettled.
    case outcome of
      Left failure → failureText failure `shouldBe` "user error (the owner loop failed)"
      Right _ → expectationFailure "the loop's failure was lost"
    readTVarIO (fakeDrains fake) >>= (`shouldBe` drainAttempts)
    readTVarIO (fakeRetired fake) >>= (`shouldBe` False)
    -- The application's protected exit, then the join: the session's failure is kept beside the loop's.
    atomically (writeTVar (fakeExited fake) True)
    spawned ← takeMVar spawnedRef
    Left original ← pure outcome
    joined ← bounded (joinFailure spawned Nothing original)
    failureText joined `shouldBe` "user error (the owner loop failed)"
    let ExceptionWithContext context _ = joined
    map displayCleanupFailure (cleanupFailuresInContext context) `shouldSatisfy` any ("session settled against the exit" `isInfixOf`)
    -- And only once, however often it is asked.
    again ← joinFailure spawned Nothing joined
    length (cleanupFailuresInContext (let ExceptionWithContext c _ = again in c)) `shouldBe` length (cleanupFailuresInContext context)

  it "stops the session when a cancellation is already pending at the moment the loop is entered" $ do
    fake ← newFake
    stopped ← newTVarIO False
    armed ← newEmptyMVar
    result ← newEmptyMVar
    caller ← newEmptyMVar
    thrower ← newEmptyMVar
    let stop = atomically (writeTVar stopped True)
        -- A session that ends only when it is told to stop.
        session = atomically (readTVar stopped >>= check)
        -- Run masked, after the session exists and before the loop is entered: the cancellation is queued against
        -- this thread (its sender blocked until it can be received), so it can only land when asynchronous
        -- exceptions are first enabled.
        queued _ = do
          -- The sender exists before anything is queued: it throws only once told to, so nothing blocks here with a
          -- cancellation outstanding.
          sender ← takeMVar thrower
          putMVar armed ()
          blockedFor BlockedOnException sender
    _ ← forkIO $ do
      myThreadId >>= putMVar caller
      outcome ← tryWithContext @SomeException $ withLoggingLifetime silentLogger $ \lifetime →
        serveSpawned lifetime (ownerWith fake Nothing quiet) queued stop quiet session
      putMVar result outcome
    me ← takeMVar caller
    sender ← forkIO (takeMVar armed >> throwTo me UserInterrupt)
    putMVar thrower sender
    bounded (takeMVar result) >>= \case
      Left (ExceptionWithContext _ failure) → (fromException failure ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
      Right _ → expectationFailure "the cancellation was lost"
    -- The session was told to stop, and has ended: nothing outlives the call.
    readTVarIO stopped >>= (`shouldBe` True)

  it "joins the session, keeping its failure beside the cancellation, when a cancellation is already queued as the application's failure is caught" $ do
    fake ← newFake
    slot ← newIORef Nothing
    stops ← newIORef (0 ∷ Int)
    thrower ← newEmptyMVar
    armed ← newEmptyMVar
    caller ← newEmptyMVar
    result ← newEmptyMVar
    let stop = atomicModifyIORef' stops (\n → (n + 1, ()))
        owner = ownerWith fake (Just "the owner loop failed") (ioError (userError "the drain failed too"))
        -- Unsettled when the loop is given up on, and ended only by the application's teardown.
        session = atomically (readTVar (fakeExited fake) >>= check) >> ioError (userError "session settled against the exit")
        application =
          withLoggingLifetime silentLogger (\lifetime → serveSpawned lifetime owner (\spawned → writeIORef slot (Just spawned)) stop quiet session)
            `catch` \failure → mask_ $ do
              -- Caught: the application's own teardown. A cancellation is queued against this thread while it is
              -- masked, so it can only land when the failure's continuation first runs unmasked, if it ever does.
              sender ← takeMVar thrower
              putMVar armed ()
              blockedFor BlockedOnException sender
              atomically (writeTVar (fakeExited fake) True)
              throwIO (failure ∷ SomeException)
    _ ← forkIO $ do
      myThreadId >>= putMVar caller
      outcome ← tryWithContext @SomeException (runOwned slot stop application)
      putMVar result outcome
    me ← takeMVar caller
    sender ← forkIO (takeMVar armed >> throwTo me UserInterrupt)
    putMVar thrower sender
    bounded (takeMVar result) >>= \case
      Left (ExceptionWithContext context failure) → do
        (fromException failure ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
        let kept = map displayCleanupFailure (cleanupFailuresInContext context)
        kept `shouldSatisfy` any ("the owner loop failed" `isInfixOf`)
        kept `shouldSatisfy` any ("session settled against the exit" `isInfixOf`)
      Right _ → expectationFailure "the cancellation was lost"
    readIORef stops >>= (`shouldSatisfy` (>= 1))

  it "records a failed diagnostic write on the lifetime, writes nothing more through that path and flushes nothing, however long the drain keeps failing" $ do
    fake ← newFake
    writes ← newTVarIO (0 ∷ Int)
    flushes ← newTVarIO (0 ∷ Int)
    spawnedRef ← newEmptyMVar
    let sink =
          callbackSinkWith
            (\_ → atomically (modifyTVar' writes (+ 1)) >> ioError (userError "the diagnostic sink is broken"))
            (atomically (modifyTVar' flushes (+ 1)))
        owner = ownerWith fake (Just "the owner loop failed") (ioError (userError "the drain failed too"))
        session = atomically (readTVar (fakeExited fake) >>= check)
    outcome ← bounded $ tryWithContext @SomeException $ withRecordingLifetime defaultLogFilter sink $ \lifetime →
      serveSpawned lifetime owner (putMVar spawnedRef) quiet quiet session
    -- Let the session go, as the application's exit does, and wait for it: nothing outlives the example.
    atomically (writeTVar (fakeExited fake) True)
    spawned ← takeMVar spawnedRef
    Left original ← pure outcome
    _ ← bounded (joinFailure spawned Nothing original)
    readTVarIO (fakeDrains fake) >>= (`shouldBe` drainAttempts)
    -- Every drain failed, and only the first of the reports was written: the path was recorded as failed.
    readTVarIO writes >>= (`shouldBe` 1)
    readTVarIO flushes >>= (`shouldBe` 0)
    let ExceptionWithContext context failure = original
    show failure `shouldBe` "user error (the owner loop failed)"
    length (failedReportsInContext context) `shouldBe` 1

  it "remembers a cancellation during the drain and raises it, after the session has settled, with both failures kept beside it" $ do
    fake ← newFake
    order ← newIORef ([] ∷ [String])
    started ← newEmptyMVar
    gate ← newEmptyMVar
    caller ← newEmptyMVar
    result ← newEmptyMVar
    let note line = atomicModifyIORef' order (\l → (l <> [line], ()))
        gated = ownerWith fake (Just "the owner loop failed") (putMVar started () >> takeMVar gate)
        session = (afterRetirement fake >> ioError (userError "session cleanup failed")) `finally` note "session settled"
    _ ← forkIO $ do
      myThreadId >>= putMVar caller
      outcome ← tryWithContext @SomeException (run fake gated quiet session) `finally` note "serve left"
      putMVar result outcome
    me ← takeMVar caller
    takeMVar started
    -- The drain is parked on its gate: interrupt the caller there, then let the drain go.
    blockedFor BlockedOnMVar me
    throwTo me UserInterrupt
    putMVar gate ()
    noted order 2 >>= (`shouldBe` ["session settled", "serve left"])
    bounded (takeMVar result) >>= \case
      Left (ExceptionWithContext context failure) → do
        (fromException failure ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
        let kept = map displayCleanupFailure (cleanupFailuresInContext context)
        kept `shouldSatisfy` any ("the owner loop failed" `isInfixOf`)
        kept `shouldSatisfy` any ("session cleanup failed" `isInfixOf`)
      Right _ → expectationFailure "the cancellation was lost"

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

