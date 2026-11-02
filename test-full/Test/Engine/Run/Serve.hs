-- | 'Hetoimasia.Run.Serve', the main thread's loop and the session's thread unwinding together, as direct examples
-- over a fake owner: no device, no window. The fake models the dependency that makes a naive join deadlock: the
-- session's cleanup ends only once the owner's retirement has been served, by the drain loop (not the failed ordinary
-- loop) or, when no loop can be served any more, by the application's own protected exit (the example's 'exited').
-- No example sleeps; the ones that interrupt a thread wait until the runtime reports it blocked where the
-- interruption must land.
--
-- Every helper thread an example starts is owned by it (#600): the caller of the production scope, the sender that
-- interrupts it and the writers that queue in a held sink have ended and been joined when the example's scope returns,
-- whether it returned, failed or was cancelled. A sender supplies what its caller's wait needs, so its scope encloses the
-- caller's. What the caller holds the production session at is opened by the scope ('withOwnedThreadOpening'), so a
-- caller ended early does not leave the session running.
module Test.Engine.Run.Serve (spec) where

import Control.Concurrent (ThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, stateTVar, writeTVar)
import Control.Exception
  ( AsyncException (UserInterrupt)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , catch
  , finally
  , fromException
  , mask
  , mask_
  , throwIO
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (replicateM_, unless, void, when)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Maybe (isJust)
import GHC.Conc (BlockReason (BlockedOnException, BlockedOnMVar, BlockedOnSTM))
import Hetoimasia.Foundation.Log (callbackSinkWith, defaultLogFilter, logInfo, unsafeComponent)
import Hetoimasia.Run.Settle (answering, bestEffort, pathFailed, withRecordingLifetime)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, displayCleanupFailure, withResource)
import Hetoimasia.Run.Serve (Owner (..), drainAttempts, joinFailure, runOwned, serveSpawned)
import Hetoimasia.Run.Session (awaitDiagnostics, newSessionLinkEndingWith)
import Hetoimasia.Runtime.Logging (failedReportsInContext, lifetimeLogger, withLoggingLifetime)
import Test.Engine.Run.Support (blockedFor, silentLogger)
import Test.Engine.Unowned (Cleanups, Ending, Scope, cleanupLater, endings, hasEnded, newCleanups, ownedScope, runCleanups, runEnding, unownedScope)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThreadOpening)

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

-- | The end of a session that takes many scheduling steps (a count of yields, never a duration), so that a caller that did not
-- join it would return long before it ended.
slowly ∷ IO ()
slowly = replicateM_ 2000 yield

-- | Join the production session a caller started, if it started one, without being interruptible. The session is a thread of
-- the production scope, not the example's: when a caller is ended inside the queued callback the loop's failure handling,
-- which would stop and join it, is never entered, so the caller's own end is made to include the session's. The callback says
-- (@reached@) that the session exists, which it does from the moment the callback runs, because the callback is the
-- recorder of the masked step that starts it; the session says (@ended@) that it has ended. The caller's opening has stopped
-- the session before this runs, so the wait ends.
joinSession ∷ MVar () → MVar () → IO ()
joinSession reached ended = uninterruptibleMask_ (tryReadMVar reached >>= \started → when (isJust started) (readMVar ended))

-- | A caller that runs the action, and a sender that interrupts it with a cancellation once it is armed, both in scopes of the
-- given kind (#600). The sender supplies what the caller's wait needs (the blocked sending it waits for), so its scope
-- encloses the caller's: on the way out the caller is ended first and the sender, which it may still be waiting for, after.
-- The first action is what the caller must be let go of before it can end, run in the caller's release before it is killed.
-- The body is given the caller and the sender.
withInterruptedCaller ∷ Scope → IO () → MVar () → IO () → (ThreadId → ThreadId → IO ()) → IO ()
withInterruptedCaller scope open armed caller body = do
  callerVar ← newEmptyMVar
  scope (pure ()) (readMVar callerVar >>= \me → takeMVar armed >> throwTo me UserInterrupt) $ \sender _ →
    scope open caller $ \me _ → putMVar callerVar me >> body me sender

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
    thrower ← newEmptyMVar
    reached ← newEmptyMVar
    sessionEnded ← newEmptyMVar
    let stop = atomically (writeTVar stopped True)
        -- A session that ends only when it is told to stop.
        session = atomically (readTVar stopped >>= check) `finally` (slowly >> void (tryPutMVar sessionEnded ()))
        -- Run masked, after the session exists and before the loop is entered: the cancellation is queued against
        -- this thread (its sender blocked until it can be received), so it can only land when asynchronous
        -- exceptions are first enabled.
        queued _ = do
          void (tryPutMVar reached ())
          -- The sender exists before anything is queued: it throws only once told to, so nothing blocks here with a
          -- cancellation outstanding.
          sender ← takeMVar thrower
          putMVar armed ()
          blockedFor BlockedOnException sender
        caller =
          ( do
              outcome ← tryWithContext @SomeException $ withLoggingLifetime silentLogger $ \lifetime →
                serveSpawned lifetime (ownerWith fake Nothing quiet) queued stop quiet session
              putMVar result outcome
          )
            `finally` joinSession reached sessionEnded
    withInterruptedCaller ownedScope stop armed caller $ \_ sender → do
      putMVar thrower sender
      bounded (takeMVar result) >>= \case
        Left (ExceptionWithContext _ failure) → (fromException failure ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
        Right _ → expectationFailure "the cancellation was lost"
      -- The session was told to stop, and has ended: nothing outlives the call.
      readTVarIO stopped >>= (`shouldBe` True)
    -- And it had already ended when the scope returned: the caller's end included the session's.
    tryReadMVar sessionEnded >>= (`shouldBe` Just ())

  describe "a caller parked in the queued callback before it is armed, with its sender, is owned (#600)" $
    for_ endings $ \(label, ending) → do
      it ("has ended and been joined, with its sender and the production session, when the scope returns because " <> label) $ do
        cleanups ← newCleanups
        callerBeforeArmed ending cleanups ownedScope >>= (`shouldBe` True)
      it ("negative control: an unowned caller and sender are left parked when the scope returns because " <> label) $ do
        cleanups ← newCleanups
        -- The judgement is recorded first; only then does anything independent stop the session and end what was left.
        (callerBeforeArmed ending cleanups (unownedScope cleanups) >>= (`shouldBe` False)) `finally` runCleanups cleanups

  it "joins the session, keeping its failure beside the cancellation, when a cancellation is already queued as the application's failure is caught" $ do
    fake ← newFake
    slot ← newIORef Nothing
    stops ← newIORef (0 ∷ Int)
    thrower ← newEmptyMVar
    armed ← newEmptyMVar
    result ← newEmptyMVar
    reached ← newEmptyMVar
    sessionEnded ← newEmptyMVar
    let stop = atomicModifyIORef' stops (\n → (n + 1, ()))
        owner = ownerWith fake (Just "the owner loop failed") (ioError (userError "the drain failed too"))
        -- Unsettled when the loop is given up on, and ended only by the application's teardown.
        session = (atomically (readTVar (fakeExited fake) >>= check) >> ioError (userError "session settled against the exit")) `finally` (slowly >> void (tryPutMVar sessionEnded ()))
        application =
          withLoggingLifetime silentLogger (\lifetime → serveSpawned lifetime owner (\spawned → writeIORef slot (Just spawned) >> void (tryPutMVar reached ())) stop quiet session)
            `catch` \failure → mask_ $ do
              -- Caught: the application's own teardown. A cancellation is queued against this thread while it is
              -- masked, so it can only land when the failure's continuation first runs unmasked, if it ever does.
              sender ← takeMVar thrower
              putMVar armed ()
              blockedFor BlockedOnException sender
              atomically (writeTVar (fakeExited fake) True)
              throwIO (failure ∷ SomeException)
        caller =
          ( do
              outcome ← tryWithContext @SomeException (runOwned slot stop application)
              putMVar result outcome
          )
            `finally` joinSession reached sessionEnded
    -- The session is ended by the application's exit, which a caller ended early never reaches: the scope makes it, and the
    -- caller's end includes the session's.
    withInterruptedCaller ownedScope (atomically (writeTVar (fakeExited fake) True)) armed caller $ \_ sender → do
      putMVar thrower sender
      bounded (takeMVar result) >>= \case
        Left (ExceptionWithContext context failure) → do
          (fromException failure ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
          let kept = map displayCleanupFailure (cleanupFailuresInContext context)
          kept `shouldSatisfy` any ("the owner loop failed" `isInfixOf`)
          kept `shouldSatisfy` any ("session settled against the exit" `isInfixOf`)
        Right _ → expectationFailure "the cancellation was lost"
      readIORef stops >>= (`shouldSatisfy` (>= 1))
    tryReadMVar sessionEnded >>= (`shouldBe` Just ())

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
    result ← newEmptyMVar
    let note line = atomicModifyIORef' order (\l → (l <> [line], ()))
        gated = ownerWith fake (Just "the owner loop failed") (putMVar started () >> takeMVar gate)
        session = (afterRetirement fake >> ioError (userError "session cleanup failed")) `finally` note "session settled"
        caller = do
          outcome ← tryWithContext @SomeException (run fake gated quiet session) `finally` note "serve left"
          putMVar result outcome
    -- The drain is parked on its gate, which only the example fills; the scope fills it too, idempotently, on any other way out.
    withOwnedThreadOpening (void (tryPutMVar gate ())) caller $ \me _ → do
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
    let note line = atomicModifyIORef' order (\l → (l <> [line], ()))
        caller = void (tryWithContext @SomeException (awaitDiagnostics link)) `finally` note "join returned"
    -- The join waits for the writer to end, which only the example lets it; the scope lets it too on any other way out.
    withOwnedThreadOpening (atomically (writeTVar ended True)) caller $ \me _ → do
      blockedFor BlockedOnSTM me
      throwTo me UserInterrupt
      note "writer ended"
      atomically (writeTVar ended True)
      noted order 2 >>= (`shouldBe` ["writer ended", "join returned"])

  it "records a sink's refusal even when a cancellation is queued while the sink throws, so nothing is written or flushed through it afterwards" $ do
    calls ← newTVarIO (0 ∷ Int)
    flushes ← newTVarIO (0 ∷ Int)
    thrower ← newEmptyMVar
    armed ← newEmptyMVar
    result ← newEmptyMVar
    let component = unsafeComponent "run.test"
        write _ = do
          firstCall ← atomically (stateTVar calls (\n → (n == 0, n + 1)))
          when firstCall . mask_ $ do
            -- Inside the sink's own masked region (as a handle's write is) a cancellation is queued against the
            -- writer, and the sink then fails: the cancellation can only land once that region is left.
            sender ← takeMVar thrower
            putMVar armed ()
            blockedFor BlockedOnException sender
            ioError (userError "the diagnostic sink broke")
        sink = callbackSinkWith write (atomically (modifyTVar' flushes (+ 1)))
        caller =
          void . tryWithContext @SomeException . withRecordingLifetime defaultLogFilter sink $ \lifetime → mask $ \restore → do
            _ ← tryWithContext @SomeException (restore (logInfo (lifetimeLogger lifetime) component "one" []))
            recorded ← pathFailed lifetime
            -- Another report through the same lifetime, as an enclosing boundary would make.
            _ ← tryWithContext @SomeException (logInfo (lifetimeLogger lifetime) component "two" [])
            -- Take the queued cancellation here, so the lifetime ends normally and its own finalization is observed.
            _ ← tryWithContext @SomeException (restore (pure ()))
            putMVar result recorded
    withInterruptedCaller ownedScope (pure ()) armed caller $ \_ sender → do
      putMVar thrower sender
      bounded (takeMVar result) >>= (`shouldBe` True)
      readTVarIO calls >>= (`shouldBe` 1)
      readTVarIO flushes >>= (`shouldBe` 0)

  it "hands the outcome of a job to its waiter even when a cancellation is queued as the job fails, and lets the cancellation go on" $ do
    answer ← newEmptyMVar
    thrower ← newEmptyMVar
    armed ← newEmptyMVar
    result ← newEmptyMVar
    let job = mask_ $ do
          sender ← takeMVar thrower
          putMVar armed ()
          blockedFor BlockedOnException sender
          ioError (userError "the job failed") ∷ IO ()
        caller = putMVar result =<< tryWithContext @SomeException (answering answer job)
    withInterruptedCaller ownedScope (pure ()) armed caller $ \_ sender → do
      putMVar thrower sender
      -- The waiter has its answer, and it is the job's own failure: it is not left waiting.
      bounded (takeMVar answer) >>= \case
        Left failure → show failure `shouldBe` "user error (the job failed)"
        Right () → expectationFailure "the job's failure was lost"
      -- And the cancellation that was queued against the runner was not swallowed.
      bounded (takeMVar result) >>= \case
        Left (ExceptionWithContext _ failure) → (fromException failure ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
        Right () → expectationFailure "the cancellation was swallowed"

  it "ignores a failure to write a best-effort line but lets a cancellation go on" $ do
    bestEffort (ioError (userError "the line could not be written"))
    gate ← newEmptyMVar
    started ← newEmptyMVar
    result ← newEmptyMVar
    -- Held at a take the scope's kill interrupts, so nothing has to be opened for it.
    withOwnedThreadOpening (pure ()) (putMVar result =<< tryWithContext @SomeException (bestEffort (putMVar started () >> takeMVar gate))) $ \me _ → do
      takeMVar started
      blockedFor BlockedOnMVar me
      throwTo me UserInterrupt
      bounded (takeMVar result) >>= \case
        Left (ExceptionWithContext _ failure) → (fromException failure ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
        Right () → expectationFailure "the cancellation was swallowed"

  it "refuses a writer that queued behind a failing write without touching the sink or flushing it" $ do
    calls ← newTVarIO (0 ∷ Int)
    flushes ← newTVarIO (0 ∷ Int)
    inside ← newEmptyMVar
    release ← newEmptyMVar
    doneA ← newEmptyMVar
    doneB ← newEmptyMVar
    let component = unsafeComponent "run.test"
        write _ = do
          firstCall ← atomically (stateTVar calls (\n → (n == 0, n + 1)))
          -- The first write is held inside the sink, and then fails; any other call would succeed.
          when firstCall $ do
            putMVar inside ()
            takeMVar release
            ioError (userError "the diagnostic sink broke")
        sink = callbackSinkWith write (atomically (modifyTVar' flushes (+ 1)))
    recorded ← withRecordingLifetime defaultLogFilter sink $ \lifetime → do
      let say name = tryWithContext @SomeException (logInfo (lifetimeLogger lifetime) component name [])
      -- The writers are inside the lifetime and end before it is released. The first is held in the sink until the example
      -- releases it, so the scope releases it too (idempotently) before it kills and joins; the second waits its turn behind
      -- the first, and is ended first on the way out.
      withOwnedThreadOpening (void (tryPutMVar release ())) (say "a" >>= putMVar doneA) $ \_ _ → do
        takeMVar inside
        -- A second writer arrives while the first is inside the sink: it must wait its turn, not pass the check.
        withOwnedThreadOpening (pure ()) (say "b" >>= putMVar doneB) $ \writerB _ → do
          blockedFor BlockedOnMVar writerB
          putMVar release ()
          void (bounded (takeMVar doneA))
          refused ← bounded (takeMVar doneB)
          -- It found the path failed when its turn came: refused, without a call.
          either (const (pure ())) (const (expectationFailure "the queued writer's write was accepted")) refused
      pathFailed lifetime
    recorded `shouldBe` True
    readTVarIO calls >>= (`shouldBe` 1)
    readTVarIO flushes >>= (`shouldBe` 0)

-- | A caller of the production scope parked in the queued callback before it is armed, with its sender, its scope ended the
-- way the ending says (#600): whether, when the scope has returned, the caller, the sender and the production session the
-- caller had started have all ended. Nothing is handed to the caller, so it is parked at the take that hands it its
-- sender; the production session is the thing the caller's callback leaves running if the caller is ended there, because
-- the loop's failure handling is never entered, so the scope stops it through its opening.
callerBeforeArmed ∷ Ending → Cleanups → Scope → IO Bool
callerBeforeArmed ending cleanups scope = do
  fake ← newFake
  stopped ← newTVarIO False
  armed ← newEmptyMVar
  thrower ← newEmptyMVar
  result ← newEmptyMVar
  sessionEnded ← newEmptyMVar
  reached ← newEmptyMVar
  seen ← newIORef []
  let stop = atomically (writeTVar stopped True)
      session = atomically (readTVar stopped >>= check) `finally` (slowly >> void (tryPutMVar sessionEnded ()))
      queued _ = do
        -- The session has been started: the callback runs after it, and the caller is parked at the take below.
        putMVar reached ()
        sender ← takeMVar thrower
        putMVar armed ()
        blockedFor BlockedOnException sender
      caller =
        ( do
            outcome ← tryWithContext @SomeException $ withLoggingLifetime silentLogger $ \lifetime →
              serveSpawned lifetime (ownerWith fake Nothing quiet) queued stop quiet session
            putMVar result outcome
        )
          `finally` joinSession reached sessionEnded
  -- A control that left the caller parked also leaves the session running; its end is awaited last, once it is stopped.
  cleanupLater cleanups (bounded (readMVar sessionEnded))
  runEnding ending $ \end →
    withInterruptedCaller scope stop armed caller $ \me sender → do
      writeIORef seen [me, sender]
      end (readMVar reached >> blockedFor BlockedOnMVar me)
  threads ← readIORef seen
  ended ← and <$> mapM hasEnded threads
  -- The session is a thread of the production scope, not of this example's. The caller's end included its end, so it has
  -- already ended when the scope has returned: nothing is waited for here.
  sessionDone ← isJust <$> tryReadMVar sessionEnded
  pure (ended && sessionDone)
