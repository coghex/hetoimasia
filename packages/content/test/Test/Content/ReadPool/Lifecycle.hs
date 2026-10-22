-- | The read pool's scope: what its exit does with queued and started work, a defect in a worker
-- or a sink, a partial startup, a cancellation during the drain, and the root outliving a read.
module Test.Content.ReadPool.Lifecycle (spec) where

import Control.Concurrent (killThread)
import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), throwIO)
import Hetoimasia.Content.Inventory (readVerified)
import Hetoimasia.Content.Internal.Native (Boundary (ReadOpened), productionSeam)
import Hetoimasia.Content.Internal.Pool (PoolHooks (..), noHooks, withPoolWith)
import Hetoimasia.Content.ReadPool
import Hetoimasia.Foundation.Worker (GroupReport (..), WorkerEvidence (GroupExit), workerEvidenceInContext)
import Test.Content.Inventory.Support (baseSpec, limitsFrom, populate, rootPath, withLayout, withScanned)
import Test.Content.ReadPool.Support
import Test.Content.Support
  ( awaitDone
  , awaitOutcome
  , awaitReached
  , Child
  , childThread
  , failsWith
  , isFinished
  , newPause
  , pauseWhen
  , resumePaused
  , spawn
  )
import Test.Hspec

spec ∷ Spec
spec = do
  closing
  failing
  starting
  draining

-- Closing -------------------------------------------------------------------------------

closing ∷ Spec
closing = describe "closing the scope" $ do
  it "withdraws and tells queued jobs, and lets a started read finish and deliver before the scope ends" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    outcomes ← newOutcomes
    withInventory [("a.bin", "a"), ("b.bin", "b")] $ \root inventory → do
      scope ← spawn $
        withReadPoolUsing (poolOf 1 4) (probeReader probe (readVerified inventory root)) $ \pool → do
          running ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
          awaitStarted probe 1
          queued ← accepted pool (request inventory outcomes OrdinaryRead 64 "b.bin")
          pure (running, queued)
      -- The body returned. The queued job is told it was abandoned and is retired; the started
      -- read is still running, so the scope has not ended.
      seen ← awaitOutcomes outcomes 1
      map snd seen `shouldBe` [SeenAbandoned]
      isFinished scope `shouldReturn` False
      openGate probe "a.bin"
      (running, queued) ← either throwIO pure =<< awaitOutcome scope
      awaitRetired running
      awaitRetired queued
      map snd <$> seenOutcomes outcomes `shouldReturn` [SeenAbandoned, SeenBytes "a"]
      startedPaths probe `shouldReturn` ["a.bin"]

  it "refuses a job after the scope closed, as a closed pool and not a full one" $
    withInventory [("a.bin", "a")] $ \root inventory → do
      pool ← withReadPool (poolOf 1 2) inventory root pure
      outcomes ← newOutcomes
      atomically (reserveSlot pool) `shouldReturn` True
      refused ← atomically (submit pool (request inventory outcomes OrdinaryRead 64 "a.bin"))
      case refused of
        Left PoolIsClosed → pure ()
        Left (PoolHasFailed failure) → expectationFailure ("expected a closed pool, found a failed one: " <> show failure)
        Right _ → expectationFailure "expected a closed pool to refuse the job"
      seenOutcomes outcomes `shouldReturn` []

-- Failing -------------------------------------------------------------------------------

failing ∷ Spec
failing = describe "a defect" $ do
  it "tells the job and every queued job, latches the pool, refuses new jobs and is rethrown by the scope" $ do
    probe ← newProbe
    closeGate probe "boom.bin"
    outcomes ← newOutcomes
    withInventory [("boom.bin", "x"), ("next.bin", "y")] $ \_ inventory → do
      ExceptionWithContext _ failure ←
        failsWith @IOError $
          withReadPoolUsing (poolOf 1 4) (probeReader probe (failingReader (userError "injected reader failure"))) $ \pool → do
            _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "boom.bin")
            awaitStarted probe 1
            queued ← accepted pool (request inventory outcomes OrdinaryRead 64 "next.bin")
            openGate probe "boom.bin"
            latched ← awaitSTM (awaitFailure pool)
            show latched `shouldContain` "injected reader failure"
            awaitRetired queued
            refused ← atomically (submit pool (request inventory outcomes OrdinaryRead 64 "next.bin"))
            -- The reservation of a refused job stays the caller's: it holds none, so this is the
            -- defect of submitting without one, decided after the failure check.
            case refused of
              Left (PoolHasFailed _) → pure ()
              _ → expectationFailure "expected the failed pool to refuse"
      show failure `shouldContain` "injected reader failure"
      seen ← seenOutcomes outcomes
      map fst seen `shouldMatchList` ["boom.bin", "next.bin"]
      all (\(_, s) → case s of SeenDefect _ → True; _ → False) seen `shouldBe` True

  it "is latched when a sink raises, after the job has still been marked done" $ do
    withInventory [("a.bin", "a")] $ \root inventory → do
      ExceptionWithContext _ failure ←
        failsWith @IOError $
          withReadPoolUsing (poolOf 1 2) (readVerified inventory root) $ \pool → do
            _ <- atomically (reserveSlot pool)
            ticket ←
              atomically (submit pool (ReadRequest (keyOf inventory "a.bin") 64 OrdinaryRead (\_ → throwIO (userError "injected sink failure"))))
                >>= either (\_ → fail "refused") pure
            awaitRetired ticket
            _ ← awaitSTM (awaitFailure pool)
            pure ()
      show failure `shouldContain` "injected sink failure"

-- Starting -------------------------------------------------------------------------------

starting ∷ Spec
starting = describe "a partial startup" $
  it "drains the workers already started before the failure leaves the scope" $ do
    let hooks = noHooks {hookWorkerStart = \index → if index == 1 then throwIO (userError "injected start failure") else pure ()}
    withInventory [("a.bin", "a")] $ \root inventory → do
      ExceptionWithContext evidence failure ←
        failsWith @IOError (withPoolWith hooks (poolOf 3 4) (readVerified inventory root) (\_ → pure ()))
      show failure `shouldContain` "injected start failure"
      case workerEvidenceInContext evidence of
        -- The worker may have seen the closed pool and returned before the group began to close,
        -- or be drained by it; either way the group's report accounts for the one worker started.
        [GroupExit report] → (length (reportDrained report) + length (reportExitedBeforeClosing report)) `shouldBe` 1
        other → expectationFailure ("expected one group report, found " <> show (length other) <> " evidence entries")

-- Draining -------------------------------------------------------------------------------

draining ∷ Spec
draining = describe "the drain" $ do
  it "settles the interrupted job as abandoned when the owner is cancelled under a started read" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    outcomes ← newOutcomes
    withInventory [("a.bin", "a")] $ \root inventory → do
      scope ← spawn $
        withReadPoolUsing (poolOf 1 2) (probeReader probe (readVerified inventory root)) $ \pool → do
          ticket ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
          awaitStarted probe 1
          pure ticket
      -- The body has returned and the scope is waiting for the read; cancelling its thread makes
      -- the group cancel the worker, whose gated read is interruptible.
      awaitStarted probe 1
      killer ← cancelling scope
      _ ← awaitOutcome scope
      awaitDone killer
      map snd <$> seenOutcomes outcomes `shouldReturn` [SeenAbandoned]
      activeNow probe `shouldReturn` 0

  it "keeps waiting through further cancellations while a read cannot be interrupted, then ends" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    uninterruptiblyGated probe "a.bin"
    outcomes ← newOutcomes
    withInventory [("a.bin", "a")] $ \root inventory → do
      scope ← spawn $
        withReadPoolUsing (poolOf 1 2) (probeReader probe (readVerified inventory root)) $ \pool → do
          ticket ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
          awaitStarted probe 1
          pure ticket
      awaitStarted probe 1
      killers ← mapM (const (cancelling scope)) [1, 2 ∷ Int]
      isFinished scope `shouldReturn` False
      openGate probe "a.bin"
      awaitDone scope
      mapM_ awaitDone killers
      activeNow probe `shouldReturn` 0
      -- The read finished its work; its delivery was withdrawn by the cancellation that landed
      -- as it left the uninterruptible gate, so the job is told it was abandoned.
      map snd <$> seenOutcomes outcomes `shouldReturn` [SeenAbandoned]

  it "ends the root's scope only after the pool's, so a started read keeps its root" $ do
    pause ← newPause
    outcomes ← newOutcomes
    withLayout $ \tree → do
      populate (rootPath tree) [("a.bin", "payload")]
      let seam = pauseWhen (\case ReadOpened _ → True; _ → False) pause productionSeam
      outer ← spawn $
        withScanned seam (limitsFrom baseSpec) (rootPath tree) $ \root inventory →
          withReadPool (poolOf 1 2) inventory root $ \pool → do
            ticket ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
            -- The read holds its file open at the boundary before the body returns.
            awaitReached pause
            pure ticket
      -- The body has returned and the scopes are unwinding, which must wait for the read.
      awaitReached pause
      isFinished outer `shouldReturn` False
      resumePaused pause
      ticket ← either throwIO pure =<< awaitOutcome outer
      awaitRetired ticket
      map snd <$> seenOutcomes outcomes `shouldReturn` [SeenBytes "payload"]

-- | Cancel the scope's thread from a thread of its own: delivery to a thread that is draining
-- inside an uninterruptible region waits for that region, and the example must not.
cancelling ∷ Child a → IO (Child ())
cancelling scope = spawn (killThread (childThread scope))
