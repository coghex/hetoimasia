-- | What an interruption cannot undo: a target retirement that returned stays
-- recorded, every injected operation's answer commits with no interruption
-- point after it, and the join waits for a terminal group report.
module Test.GLFW.Owner.Failure.Interruption (spec) where

import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( atomically
  , check
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception
  ( AsyncException (ThreadKilled)
  , MaskingState (MaskedInterruptible)
  , IOException
  , getMaskingState
  , throwTo
  )
import Control.Monad (forM_, void)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import Test.GLFW.Owner.Fixture.Drive
  ( awaitRound
  , awaitStanding
  , awaitTerminal
  , handedOver
  , pumpUntilRetired
  , raisedBy
  , theWindow
  )
import Test.GLFW.Owner.Fixture.Fake (Fake (..), script)
import Test.GLFW.Owner.Fixture.Journal (Note (..), journalled)
import Test.GLFW.Owner.Fixture.Rig (Rig (..), newRig, ownedHost, ownedHostCaught, ownedHostHooked)
import Test.GLFW.Support (boundedExample, caughtAs, quietLogger, unexpected)
import Test.Hspec (Spec, it, shouldBe, shouldContain, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = do
  it "records a target retirement that returned, however it is then cancelled"
    (boundedExample testRetirementRecordSurvivesCancellation)
  it "commits every injected operation's answer with no interruption point after it"
    (boundedExample testOperationAnswersCommitUninterrupted)
  it "waits for a terminal group report however the join is interrupted"
    (boundedExample testJoinAwaitsTerminalReport)

-- | A target retirement that returned is recorded, whatever is delivered to
-- the owner as it returns — so it is never offered a second time.
--
-- The call itself stays interruptible, and a cancellation inside it leaves
-- the target explicitly unverified and the operation spent. What must not
-- happen is a cancellation between the answer and the record of it: the
-- target would be neither retired nor marked, and the drain would offer the
-- operation again, disposing a second time what the backend already disposed.
testRetirementRecordSurvivesCancellation ∷ IO ()
testRetirementRecordSurvivesCancellation = do
  rig ← newRig
  entered ← newTVarIO False
  attempts ← newTVarIO (0 ∷ Int)
  recorded ← newTVarIO []
  script (fakeRetireTarget (rigFake rig)) $ \retire → do
    atomically (modifyTVar' attempts (+ 1))
    atomically (writeTVar entered True)
    pure (targetRetired (Text.pack (show (retiringWindow retire))))
  -- Delivered again and again from the instant the call is entered, so one of
  -- them lands wherever the owner is least protected — inside the call, on
  -- its way out, or after the record.
  let harry = do
        atomically (readTVar entered >>= check)
        ownerThread ← atomically $
          readTVar (fakeThreads (rigFake rig)) >>= \case
            thread : _ → pure thread
            [] → retry
        forM_ [1 ∷ Int .. 20] (\_ → throwTo ownerThread ThreadKilled)
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    service ← handedOver host owner window
    awaitStanding owner service `shouldReturn` TargetUsable
    void (forkIO harry)
    _ ← releaseGraphicsTarget host owner service
    atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
    -- Independent evidence, so this exit finishes whichever way the
    -- retirement settled.
    publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
    acknowledgement ←
      atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
        >>= maybe (unexpected "the attachment kept no acknowledgement") pure
    forM_ allRetirementFacts $ \fact →
      void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
    pumpUntilRetired host control
    -- Captured here rather than returned: the run itself raises the
    -- cancellation at its exit, so the body's value never reaches the caller.
    atomically . writeTVar recorded . Map.keys =<< atomically (readTargetTerminalsNow owner)
  -- However it ended, it ended by raising the cancellation rather than
  -- swallowing it.
  void (raisedBy outcome)
  -- Offered exactly once, over the whole run and its drain, however many
  -- cancellations arrived.
  readTVarIO attempts `shouldReturn` 1
  -- And because it returned, its record exists: a retirement the owner
  -- performed is never one the owner then forgets, and never one the drain
  -- performs a second time.
  readTVarIO recorded >>= \terminals → length terminals `shouldBe` 1

-- | Every injected operation's answer is committed with no interruption
-- point between the two.
--
-- This is the window itself, observed from inside it. A cancellation
-- delivered between a /successful/ backend call and the record of what it
-- returned would discard evidence the backend really established: a
-- construction would stay pending and be built a second time, and a target
-- retirement would be neither recorded nor marked, so the drain would offer
-- it again — disposing a second time what the backend has already disposed.
--
-- There is nothing to race here, and deliberately so. The seam only /looks/:
-- anything that blocked in this window would itself be the interruption point
-- the mask exists to keep out, so what an example can assert is that the
-- window is masked, at every site that has one.
testOperationAnswersCommitUninterrupted ∷ IO ()
testOperationAnswersCommitUninterrupted = do
  rig ← newRig
  states ← newTVarIO []
  let hooks =
        Private.noHostHooks
          { Private.afterOwnerOperation =
              getMaskingState >>= \state → atomically (modifyTVar' states (<> [state]))
          }
  ownedHostHooked hooks quietLogger (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    service ← handedOver host owner window
    awaitStanding owner service `shouldReturn` TargetUsable
    _ ← releaseGraphicsTarget host owner service
    _ ← awaitTerminal owner service
    pumpUntilRetired host control
  -- The owner's startup, one construction and one target retirement, each
  -- masked from the answer through the commit.
  seen ← readTVarIO states
  length seen `shouldSatisfy` (>= 3)
  filter (/= MaskedInterruptible) seen `shouldBe` []

-- | The join is re-entered until it answers a terminal group report,
-- whatever is delivered to the thread waiting in it.
--
-- The exception delivered is an ordinary 'IOException', not an asynchronous
-- one: its type says nothing about how it arrived, and a join that returned
-- on it would let the protected host unwind with the owner never proved
-- terminal. The owner publishes its destruction evidence independently and
-- then stays inside its backend call, so the exit is certainly in the join
-- and not in the wait before it.
testJoinAwaitsTerminalReport ∷ IO ()
testJoinAwaitsTerminalReport = do
  rig ← newRig
  release ← newTVarIO False
  joining ← newEmptyMVar
  script (fakeDestroy (rigFake rig)) $ \_ → do
    putMVar joining ()
    atomically (readTVar release >>= check)
    pure (ownerDestroyed (Text.pack "destroyed"))
  released ← newTVarIO Nothing
  (raised, _) ← caughtAs @IOException $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
      main ← myThreadId
      void . forkIO $ do
        takeMVar joining
        -- The owner's destruction evidence exists, so the exit leaves its
        -- wait and enters the join; the owner is still inside the call.
        publishOwnerDestruction owner (ownerDestroyed (Text.pack "published early"))
        atomically (readOwnerTerminalNow owner >>= check . isJust . ownerDestroyedEvidence)
        throwTo main (userError "delivered during the join")
        -- Nothing of the host's may be released while the owner is unjoined.
        notes ← journalled (rigJournal rig)
        atomically (writeTVar released (Just (filter ended notes)))
        atomically (writeTVar release True)
      void (awaitRound owner 0)
  show raised `shouldContain` "delivered during the join"
  readTVarIO released `shouldReturn` Just []
  notes ← journalled (rigJournal rig)
  notes `shouldContain` [SessionEnded]
  where
    ended = \case
      WindowGone _ → True
      SessionEnded → True
      _ → False
