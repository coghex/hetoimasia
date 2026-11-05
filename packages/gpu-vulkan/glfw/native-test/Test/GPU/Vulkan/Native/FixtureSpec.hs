-- | The shared fixture's borrower is an owned thread (#596), proven without a session, a display or consent.
--
-- 'Test.GPU.Vulkan.Native.Fixture.runShared' runs the Hspec run on a borrower thread and serves its operations on the calling
-- thread. These examples drive the same dispatch through its test-side seams ('runSharedWith'): a stand-in session replaces the
-- native acquisition, so nothing native is entered, and the way the borrower is started can be exchanged for the unowned start
-- it used before. The borrower is parked wherever the scenario puts it; the scope that serves it is then ended, by a
-- cancellation in each place the serving thread can be waiting, and by a failure that escapes the session. The judgement is the
-- same for every ending: the borrower's thread has ended, and been joined, when the dispatch returns or raises.
--
-- Each ending has a negative control that makes the same judgement about the previous unowned start and requires it to fail, so
-- a regression that could not tell an owned borrower from an unowned one cannot pass. A control records its failed judgement
-- first and then lets go of, stops and joins whatever it left, even if an assertion failed.
--
-- They are selected with @--match "the shared fixture's borrower"@, run with @HETOIMASIA_NATIVE_SESSION@ unset, and acquire
-- nothing: the stand-in session never enters the native layer, and no example asks the consent gate for a session.
module Test.GPU.Vulkan.Native.FixtureSpec (spec) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Exception (AsyncException (ThreadKilled, UserInterrupt), IOException, SomeException, finally, fromException, throwIO, try)
import Control.Monad (void)
import GHC.Conc (BlockReason (BlockedOnSTM))
import Data.List (isInfixOf)
import System.IO.Error (ioeGetErrorString)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Support.Bounded (bounded)
import Test.Support.Cancel (withCancellationAfter)
import Test.Support.Owned (withOwnedThreadOpening)

import Test.GPU.Vulkan.Native.Consent (Consent (Desktop))
import Test.GPU.Vulkan.Native.Fixture (Fixture, Seams (..), Session, SharedReport (..), afterFailureBound, onMain, runSharedWith)
import Test.GPU.Vulkan.Native.Gate (Gate, newGate)
import Test.GPU.Vulkan.Native.Unowned (Boom (..), awaitBlocked, hasEnded, newCleanups, runCleanups, unownedScope)

-- | What a scenario watches of its borrower and its stand-in session.
data Rig = Rig
  { rigThread ∷ !(MVar ThreadId)
  -- ^ The borrower's own thread, filled by the borrower as its first step: the example judges that thread, never the
  -- borrower's say-so.
  , rigParked ∷ !(MVar ())
  -- ^ Filled when the borrower is parked where the scenario wants it.
  , rigGate ∷ !(MVar ())
  -- ^ The gate a parked borrower waits at; no example opens it, so only the scope's end can reach the borrower.
  , rigSessionParked ∷ !(MVar ())
  -- ^ Filled when the stand-in session is being served and waits.
  , rigSessionGate ∷ !(MVar ())
  -- ^ The gate the parked stand-in session waits at.
  }

newRig ∷ IO Rig
newRig = Rig <$> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar <*> newEmptyMVar

recordSelf ∷ Rig → IO ()
recordSelf rig = myThreadId >>= void . tryPutMVar (rigThread rig)

-- | A gate that grants a session without entering one: the stand-in session never asks it, and nothing native is acquired.
newOpenGate ∷ IO Gate
newOpenGate = newGate (Right Desktop)

-- | The borrower of an idle dispatch: it parks without asking for anything.
idleBorrower ∷ Rig → Fixture → IO ()
idleBorrower rig _ = recordSelf rig >> putMVar (rigParked rig) () >> readMVar (rigGate rig)

-- | A borrower that asks for the session and parks once the request has been answered, whatever the answer: the dispatch
-- answers a pending request when it ends (with the failure, or that the session has gone), so a borrower that simply returned
-- then would end by itself and the unowned start could not be told from the owned one by it.
parkingBorrower ∷ Rig → Fixture → IO ()
parkingBorrower rig fixture = do
  recordSelf rig
  answered ← try @SomeException (onMain fixture (\_ → pure ()))
  -- The answer is the session's failure or that it has gone. The scope's own kill is neither: a borrower that took it for an
  -- answer and parked would hold the scope's join for ever, which is exactly what ownership must not allow it to hide.
  case answered of
    Left failure | fromException failure == Just ThreadKilled → throwIO failure
    _ → pure ()
  putMVar (rigParked rig) ()
  readMVar (rigGate rig)

-- | A session that is being served: it says so and waits, until the dispatch's end reaches the thread serving it.
servingSession ∷ Rig → Session
servingSession rig _ _ _ = putMVar (rigSessionParked rig) () >> readMVar (rigSessionGate rig)

-- | A session that fails to start, as any failure that is not a cancellation does.
failingSession ∷ Session
failingSession _ _ _ = throwIO Boom

-- | A session in which the thread serving it is cancelled: the cancellation escapes the session as itself.
interruptedSession ∷ Session
interruptedSession _ _ _ = throwIO UserInterrupt

-- | A session the dispatch never reaches.
unreachedSession ∷ Session
unreachedSession _ _ _ = throwIO (userError "the stand-in session was entered, though no operation was requested")

ownedSeams ∷ Session → Seams
ownedSeams session = Seams {seamSession = session, seamBorrow = withOwnedThreadOpening, seamFailureBound = afterFailureBound}

spec ∷ Spec
spec = describe "the shared fixture's borrower is owned (#596)" $ do
  describe "the borrower is ended and joined, and its work reported, as before" $ do
    it "returns the borrower's result with the report when nothing was requested" $ do
      gate ← newOpenGate
      (value, report) ← bounded (runSharedWith (ownedSeams unreachedSession) gate (\_ → pure (42 ∷ Int)))
      (value, reportAcquisitions report, reportFailure report) `shouldBe` (42, 0, Nothing)

    it "reports a session that failed and still returns what the borrower finished with, after the wait for it" $ do
      rig ← newRig
      gate ← newOpenGate
      let borrower fixture = recordSelf rig >> void (try @SomeException (onMain fixture (\_ → pure ()))) >> pure (7 ∷ Int)
      (value, report) ← bounded (runSharedWith (ownedSeams failingSession) gate borrower)
      (value, reportAcquisitions report, reportFailure report) `shouldBe` (7, 1, Just "Boom")
      judge rig True

    it "raises the borrower's own failure, after the borrower has been joined" $ do
      rig ← newRig
      gate ← newOpenGate
      outcome ← try @Boom (void (bounded (runSharedWith (ownedSeams unreachedSession) gate (\_ → recordSelf rig >> throwIO Boom))))
      outcome `shouldBe` Left Boom
      judge rig True

  scenario "serving is cancelled while the dispatch is idle and the borrower is parked" idleCancelled
  scenario "serving is cancelled while the session is being served and the borrower waits for it" servingCancelled
  scenario "serving is cancelled while the dispatch waits for a borrower parked after the session failed" failureCancelled
  scenario "the session failed, was reported, and the borrower is parked where nothing ends it (no cancellation follows)" failureBounded
  scenario "a cancellation escapes the session, which is not a failure of the session, while the borrower waits for it" escapesTheSession

-- | One way the dispatch can end with the borrower parked. It runs the dispatch, with the seams built from the session it
-- chooses, ends it the way it says, and checks that it ended that way (the example is cancelled, or the cancellation escaped
-- the session as itself).
type Scenario = Rig → (Session → Seams) → IO ()

-- | The scenario run twice with the same judgement: through the facility, where the borrower must have ended and been joined,
-- and through the unowned start, where it must not have.
scenario ∷ String → Scenario → Spec
scenario label run = do
  it ("has ended and been joined when " <> label) $ do
    rig ← newRig
    run rig ownedSeams
    judge rig True

  it ("negative control: the unowned start leaves the borrower running when " <> label) $ do
    rig ← newRig
    cleanups ← newCleanups
    -- The judgement is recorded first, about what the dispatch left; only then does anything independent stop and join the
    -- borrower, even if an assertion before it failed. The unowned start registers its own stop-and-join with the control.
    ( do
        run rig (\session → Seams {seamSession = session, seamBorrow = unownedScope cleanups, seamFailureBound = afterFailureBound})
        judge rig False
      )
      `finally` runCleanups cleanups
    judge rig True

-- | The thread of the borrower has ended and been joined (or has not), judged from the thread itself.
judge ∷ Rig → Bool → IO ()
judge rig expected = tryReadMVar (rigThread rig) >>= maybe (pure False) hasEnded >>= (`shouldBe` expected)

-- | What the helper that delivers a cancellation does afterwards: look at the two gates, without opening either. The helper is
-- the only running thread that can reach them while the scenario's threads wait, and a thread blocked on an MVar nothing
-- running can reach is, to the runtime, deadlocked: it is thrown @BlockedIndefinitelyOnMVar@ before the cancellation is
-- delivered, which is a different ending. Reading keeps the gates reachable until the cancellation is delivered.
keepReachable ∷ Rig → IO ()
keepReachable rig = void (tryReadMVar (rigGate rig)) >> void (tryReadMVar (rigSessionGate rig))

-- | The example is cancelled, as itself, by the thread that delivers it, and not by the bound.
endsCancelled ∷ IO a → IO ()
endsCancelled action = try @AsyncException (void (bounded action)) >>= (`shouldBe` Left UserInterrupt)

-- | Cancelled while the serving thread waits for a first operation (the borrower is parked and asks for nothing).
idleCancelled ∷ Scenario
idleCancelled rig seamsFor = do
  gate ← newOpenGate
  caller ← myThreadId
  endsCancelled . withCancellationAfter (readMVar (rigParked rig) >> awaitBlocked (== BlockedOnSTM) caller) (keepReachable rig) $
    runSharedWith (seamsFor unreachedSession) gate (idleBorrower rig)

-- | Cancelled while the serving thread is inside the session, which waits, and the borrower waits for the session's answer.
servingCancelled ∷ Scenario
servingCancelled rig seamsFor = do
  gate ← newOpenGate
  caller ← myThreadId
  endsCancelled . withCancellationAfter (readMVar (rigSessionParked rig) >> awaitBlocked (const True) caller) (keepReachable rig) $
    runSharedWith (seamsFor (servingSession rig)) gate (parkingBorrower rig)

-- | The session failed in the way the dispatch catches and reports, and the borrower, told so, parked: the serving thread
-- waits, as it always did, for the borrower's result, and is cancelled there.
failureCancelled ∷ Scenario
failureCancelled rig seamsFor = do
  gate ← newOpenGate
  caller ← myThreadId
  endsCancelled . withCancellationAfter (readMVar (rigParked rig) >> awaitBlocked (== BlockedOnSTM) caller) (keepReachable rig) $
    runSharedWith (seamsFor failingSession) gate (parkingBorrower rig)

-- | The session failed in the way the dispatch catches and reports, the borrower parked, and nothing cancels the example: the
-- bound on the wait for the borrower expires (stated as zero, which needs no timing), the dispatch raises, and the borrower has
-- been stopped and joined by the scope's release without any second cancellation.
failureBounded ∷ Scenario
failureBounded rig seamsFor = do
  gate ← newOpenGate
  outcome ← try @IOException (void (bounded (runSharedWith (seamsFor failingSession) {seamFailureBound = 0} gate (parkingBorrower rig))))
  case outcome of
    Left failure → ioeGetErrorString failure `shouldSatisfy` isInfixOf "the session failed: Boom"
    Right () → expectationFailure "the dispatch returned though its borrower was still parked after the session failed"

-- | The serving thread is cancelled inside the session: the cancellation is not a failure of the session, so it ends the
-- dispatch as itself instead of being reported and followed by a wait for a borrower nothing now ends.
escapesTheSession ∷ Scenario
escapesTheSession rig seamsFor = do
  gate ← newOpenGate
  endsCancelled (runSharedWith (seamsFor interruptedSession) gate (parkingBorrower rig))
