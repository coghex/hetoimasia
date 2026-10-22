-- | The read pool's scope: what its exit does with queued and started work, a defect in a worker
-- or a sink, a partial startup, a cancellation during the drain, and the root outliving a read.
module Test.Content.ReadPool.Lifecycle (spec) where

import Control.Concurrent (killThread)
import Control.Concurrent.STM (atomically)
import Control.Exception.Context (ExceptionContext)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), Exception, ExceptionWithContext (ExceptionWithContext), SomeException, catch, fromException, rethrowIO, throwIO, tryWithContext)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.ByteString.Char8 as BC
import Hetoimasia.Content.Identity (ContentKey, contentKeyPath, logicalPathBytes)
import Hetoimasia.Content.Inventory (readVerified)
import Hetoimasia.Content.Internal.Types (ContentDefect (ContentDefect), Defect (ReadWorkerEndedOpen, ReadWorkerTerminated))

import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext, composeCleanup)
import Hetoimasia.Content.Internal.Native (Boundary (ReadOpened), productionSeam)
import Hetoimasia.Content.Internal.Pool (PoolHooks (..), noHooks, withPoolWith)
import Hetoimasia.Content.ReadPool
import Hetoimasia.Foundation.Worker (requestStop, Completion (..), GroupReport (..), Result (..), WorkerCancelled (..), WorkerEvidence (GroupExit), workerEvidenceInContext)
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
  notifying
  failing
  exits
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

-- Notifying -------------------------------------------------------------------------------

notifying ∷ Spec
notifying = describe "a withdrawn job" $ do
  it "is not retired until its sink has returned, when a defect withdraws it" $ do
    probe ← newProbe
    closeGate probe "boom.bin"
    held ← newGate
    withInventory [("boom.bin", "x"), ("next.bin", "y")] $ \_ inventory → do
      outcomes ← newOutcomes
      failure <-
        failsWith @IOError $
          withReadPoolUsing (poolOf 1 4) (probeReader probe (failingReader (userError "boom"))) $ \pool → do
            _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "boom.bin")
            awaitStarted probe 1
            queued ← accepted pool (ReadRequest (keyOf inventory "next.bin") 64 OrdinaryRead (\_ → holdAt held))
            openGate probe "boom.bin"
            -- The defect withdrew the queued job and its sink is running: the job is not retired,
            -- so a consumer that retires its request on it cannot dispose its borrows yet.
            awaitHeld held
            atomically (retired queued) `shouldReturn` False
            atomically (cancel queued) `shouldReturn` CancelInFlight
            releaseGate held
            awaitRetired queued
      (\(ExceptionWithContext _ raised) -> show raised) failure `shouldContain` "boom"

  it "is not retired until its sink has returned, when the closing scope withdraws it" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    held ← newGate
    tickets ← newEmptyMVar
    withInventory [("a.bin", "a"), ("b.bin", "b")] $ \root inventory → do
      outcomes ← newOutcomes
      scope ← spawn $
        withReadPoolUsing (poolOf 1 4) (probeReader probe (readVerified inventory root)) $ \pool → do
          _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
          awaitStarted probe 1
          queued ← accepted pool (ReadRequest (keyOf inventory "b.bin") 64 OrdinaryRead (\_ → holdAt held))
          putMVar tickets queued
      queued ← takeMVar tickets
      awaitHeld held
      atomically (retired queued) `shouldReturn` False
      isFinished scope `shouldReturn` False
      releaseGate held
      awaitRetired queued
      openGate probe "a.bin"
      awaitDone scope

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

  it "fails the open pool when a worker is terminated by an asynchronous exception the scope did not send, and tells what is queued" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    withInventory [("a.bin", "a"), ("b.bin", "b")] $ \_ inventory → do
      outcomes ← newOutcomes
      ExceptionWithContext _ failure ←
        failsWith @ContentDefect $
          withReadPoolUsing (poolOf 1 4) (probeReader probe (\_ _ → throwIO ThreadKilled)) $ \pool → do
            running ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
            awaitStarted probe 1
            queued ← accepted pool (request inventory outcomes OrdinaryRead 64 "b.bin")
            -- Interest in the running read is withdrawn, so its sink is suppressed; then the reader
            -- is terminated. Nothing but the pool's own failure can tell the queued job.
            atomically (cancel running) `shouldReturn` CancelInFlight
            openGate probe "a.bin"
            awaitRetired queued
            map snd <$> seenOutcomes outcomes >>= \seen → length seen `shouldBe` 1
            seenOutcomes outcomes >>= \seen → case seen of
              [(_, SeenDefect _)] → pure ()
              other → expectationFailure ("expected the queued job told of a defect, found " <> show other)
            _ ← awaitSTM (awaitFailure pool)
            awaitRetired running
      case failure of
        ContentDefect (ReadWorkerTerminated _) → pure ()
        other → expectationFailure ("expected the worker's termination, found " <> show other)

  it "keeps the cleanup evidence of an unexpectedly terminated reader in the pool's failure" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    let terminatedWithEvidence _ _ = do
          Left primary ← tryWithContext @SomeException (throwIO ThreadKilled)
          Left secondary ← tryWithContext @SomeException (throwIO (userError "reader close failure"))
          composed ← composeCleanup (Just primary) [("injected reader close", secondary)]
          rethrowIO (fromMaybe primary composed)
    withInventory [("a.bin", "a"), ("b.bin", "b")] $ \_ inventory → do
      outcomes ← newOutcomes
      ExceptionWithContext trail failure ←
        failsWith @ContentDefect $
          withReadPoolUsing (poolOf 1 4) (probeReader probe terminatedWithEvidence) $ \pool → do
            running ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
            awaitStarted probe 1
            atomically (cancel running) `shouldReturn` CancelInFlight
            openGate probe "a.bin"
            _ ← awaitSTM (awaitFailure pool)
            pure ()
      case failure of
        ContentDefect (ReadWorkerTerminated _) → pure ()
        other → expectationFailure ("expected the worker's termination, found " <> show other)
      map cleanupFailureLabel (cleanupFailuresInContext trail) `shouldContain` ["injected reader close"]

  it "keeps the reader's cleanup evidence and a queued sink's failure beside it" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    let failingWithEvidence _ _ = do
          Left primary ← tryWithContext @SomeException (throwIO (userError "primary reader failure"))
          Left secondary ← tryWithContext @SomeException (throwIO (userError "reader cleanup failure"))
          composed ← composeCleanup (Just primary) [("injected reader cleanup", secondary)]
          rethrowIO (fromMaybe primary composed)
    withInventory [("a.bin", "a"), ("b.bin", "b")] $ \_ inventory → do
      outcomes ← newOutcomes
      ExceptionWithContext trail failure ←
        failsWith @IOError $
          withReadPoolUsing (poolOf 1 4) (probeReader probe failingWithEvidence) $ \pool → do
            _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
            awaitStarted probe 1
            queued <- accepted pool (ReadRequest (keyOf inventory "b.bin") 64 OrdinaryRead (\_ → throwIO (userError "queued sink failure")))
            openGate probe "a.bin"
            awaitRetired queued
            _ ← awaitSTM (awaitFailure pool)
            pure ()
      show failure `shouldContain` "primary reader failure"
      map cleanupFailureLabel (cleanupFailuresInContext trail) `shouldContain` ["injected reader cleanup"]
      map cleanupFailureLabel (cleanupFailuresInContext trail) `shouldContain` ["content read sink"]

-- Exits -----------------------------------------------------------------------------------

-- | Every way a worker or the scope can leave, each with the failure and the cleanup evidence it
-- carried: none of it may be lost to a normal-looking return.
exits ∷ Spec
exits = describe "every exit keeps its failure and its evidence" $ do
  it "a reader terminated asynchronously with cleanup evidence after the scope closed the pool (normal drain)" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    pools ← newEmptyMVar
    withInventory [("a.bin", "a")] $ \_ inventory → do
      outcomes ← newOutcomes
      scope ← spawn $
        withReadPoolUsing (poolOf 1 2) (probeReader probe (evidenced ThreadKilled "reader close")) $ \pool → do
          _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
          awaitStarted probe 1
          putMVar pools pool
      pool ← readMVar pools
      -- The body returned and the pool is closed; only now does the started reader die.
      awaitStatus pool (\s → statusPhase s == PoolClosed)
      openGate probe "a.bin"
      outcome ← awaitOutcome scope
      case outcome of
        Right () → expectationFailure "the scope returned success although a worker was terminated"
        Left raised → case fromException raised of
          Just (ExceptionWithContext trail failure) → do
            failure `shouldBe` ContentDefect (ReadWorkerTerminated "thread killed")
            map cleanupFailureLabel (cleanupFailuresInContext trail) `shouldContain` ["reader close"]
          Nothing → expectationFailure ("expected the worker's termination, found " <> show raised)

  it "a reader that raises with cleanup evidence after the scope closed the pool (normal drain)" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    pools ← newEmptyMVar
    withInventory [("a.bin", "a")] $ \_ inventory → do
      outcomes ← newOutcomes
      scope ← spawn $
        withReadPoolUsing (poolOf 1 2) (probeReader probe (evidenced (userError "reader defect") "reader close")) $ \pool → do
          _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
          awaitStarted probe 1
          putMVar pools pool
      pool ← readMVar pools
      awaitStatus pool (\s → statusPhase s == PoolClosed)
      openGate probe "a.bin"
      outcome ← awaitOutcome scope
      case outcome of
        Right () → expectationFailure "the scope returned success although a reader raised"
        Left raised → case fromException raised of
          Just (ExceptionWithContext trail failure) → do
            show (failure ∷ IOError) `shouldContain` "reader defect"
            map cleanupFailureLabel (cleanupFailuresInContext trail) `shouldContain` ["reader close"]
          Nothing → expectationFailure ("expected the reader's failure, found " <> show raised)

  it "a worker cancelled by a failing body keeps the evidence it retained in the group's report" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    withInventory [("a.bin", "a")] $ \_ inventory → do
      outcomes ← newOutcomes
      ExceptionWithContext trail failure ←
        failsWith @IOError $
          withReadPoolUsing (poolOf 1 2) (cancelledAround probe "reader close during cancel") $ \pool → do
            _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
            awaitStarted probe 1
            throwIO (userError "body failure")
      show failure `shouldContain` "body failure"
      case workerEvidenceInContext trail of
        [GroupExit report] →
          [ cleanupFailureLabel found
          | summary ← reportDrained report <> reportExitedBeforeClosing report
          , inner ← resultContexts (completionResult summary)
          , found ← cleanupFailuresInContext inner
          ]
            `shouldContain` ["reader close during cancel"]
        other → expectationFailure ("expected one group report, found " <> show (length other))

  it "a failing body keeps a failure a worker latched while it ran" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    withInventory [("a.bin", "a")] $ \_ inventory → do
      outcomes ← newOutcomes
      ExceptionWithContext trail failure ←
        failsWith @IOError $
          withReadPoolUsing (poolOf 1 2) (probeReader probe (failingReader (userError "latched reader failure"))) $ \pool → do
            _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
            awaitStarted probe 1
            openGate probe "a.bin"
            _ ← awaitSTM (awaitFailure pool)
            throwIO (userError "body failure after the latch")
      show failure `shouldContain` "body failure after the latch"
      map cleanupFailureLabel (cleanupFailuresInContext trail) `shouldContain` ["content read pool worker failure"]

  it "a worker asked to stop from outside while the pool is open serves what is queued, then fails the pool so nothing later waits behind it" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    workers ← newEmptyMVar
    let hooks = noHooks {hookWorkerStarted = \_ worker → putMVar workers worker}
    withInventory [("a.bin", "a"), ("b.bin", "b")] $ \root inventory → do
      outcomes ← newOutcomes
      ExceptionWithContext _ failure ←
        failsWith @ContentDefect $
          withPoolWith hooks (poolOf 1 4) (probeReader probe (readVerified inventory root)) $ \pool → do
            worker ← readMVar workers
            _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
            awaitStarted probe 1
            queued ← accepted pool (request inventory outcomes OrdinaryRead 64 "b.bin")
            -- The stop is asked of the worker, not by the scope. It finishes the work accepted
            -- before the stop and then, seeing the stop with the pool open and idle, ends.
            atomically (requestStop worker)
            openGate probe "a.bin"
            awaitRetired queued
            _ ← awaitSTM (awaitFailure pool)
            map snd <$> seenOutcomes outcomes `shouldReturn` [SeenBytes "a", SeenBytes "b"]
            -- Nothing runs jobs any more: a later request is refused, not left pending.
            _ ← atomically (reserveSlot pool)
            refused ← atomically (submit pool (request inventory outcomes OrdinaryRead 64 "a.bin"))
            case refused of
              Left (PoolHasFailed _) → pure ()
              _ → expectationFailure "expected the failed pool to refuse"
      failure `shouldBe` ContentDefect ReadWorkerEndedOpen

  it "a second worker's failure is kept beside the first, which stays the pool's failure" $ do
    probe ← newProbe
    mapM_ (closeGate probe) ["a.bin", "b.bin"]
    withInventory [("a.bin", "a"), ("b.bin", "b")] $ \_ inventory → do
      outcomes ← newOutcomes
      ExceptionWithContext trail failure ←
        failsWith @IOError $
          withReadPoolUsing (poolOf 2 4) (probeReader probe (\key _ → throwIO (userError ("reader failure " <> show (keyPathText key))))) $ \pool → do
            _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
            _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "b.bin")
            awaitStarted probe 2
            mapM_ (openGate probe) ["a.bin", "b.bin"]
            -- Both readers raise; the scope ends only after both workers did.
            awaitStatus pool (\s → statusActive s == 0 && statusLive s == 0 && statusFailed s)
      show failure `shouldContain` "reader failure"
      map cleanupFailureLabel (cleanupFailuresInContext trail) `shouldContain` ["content read subsequent failure"]

  it "a queued sink that raises while the scope closes fails the scope" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    pools ← newEmptyMVar
    withInventory [("a.bin", "a"), ("b.bin", "b")] $ \root inventory → do
      outcomes ← newOutcomes
      scope ← spawn $
        withReadPoolUsing (poolOf 1 4) (probeReader probe (readVerified inventory root)) $ \pool → do
          _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
          awaitStarted probe 1
          _ ← accepted pool (ReadRequest (keyOf inventory "b.bin") 64 OrdinaryRead (\_ → throwIO (userError "queued sink failure")))
          putMVar pools pool
      -- The scope closed the pool and told the queued job, whose sink raised; the started read is
      -- still to be drained, and then the scope fails.
      pool ← readMVar pools
      awaitStatus pool (\s → statusPhase s == PoolClosed)
      openGate probe "a.bin"
      outcome ← awaitOutcome scope
      case outcome of
        Right () → expectationFailure "the scope returned success although a queued sink raised"
        Left raised → show raised `shouldContain` "queued sink failure"

keyPathText ∷ ContentKey → String
keyPathText = BC.unpack . logicalPathBytes . contentKeyPath

-- | The context a worker's failed or cancelled outcome carries.
resultContexts ∷ Result () → [ExceptionContext]
resultContexts = \case
  Failed (ExceptionWithContext inner _) → [inner]
  Cancelled (ExceptionWithContext inner _) → [inner]
  Succeeded () → []

-- | A reader that raises this, with a cleanup failure of this label retained beside it.
evidenced ∷ Exception e ⇒ e → Text → ContentKey → Int → IO a
evidenced raised label _ _ = do
  Left primary ← tryWithContext @SomeException (throwIO raised)
  Left secondary ← tryWithContext @SomeException (throwIO (userError "cleanup failure"))
  composed ← composeCleanup (Just primary) [(label, secondary)]
  rethrowIO (fromMaybe primary composed)

-- | A reader held at the probe's gate which, when the scope's drain cancels it, fails its own
-- cleanup too: the cancellation arrives with cleanup evidence retained.
cancelledAround ∷ Probe → Text → ContentKey → Int → IO a
cancelledAround probe label key allowance =
  probeReader probe (\_ _ → throwIO (userError "never reached")) key allowance
    `catch` \WorkerCancelled → do
      Left primary ← tryWithContext @SomeException (throwIO WorkerCancelled)
      Left secondary ← tryWithContext @SomeException (throwIO (userError "cleanup failure"))
      composed ← composeCleanup (Just primary) [(label, secondary)]
      rethrowIO (fromMaybe primary composed)

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
      -- The job was settled exactly once. Whether the cancellation (delivered by the group's own
      -- helper thread, asynchronously) reached the worker as it left the gate decides which: the
      -- read's bytes, or the job told it was abandoned. Both are the drain doing its work.
      outcomes' ← map snd <$> seenOutcomes outcomes
      outcomes' `shouldSatisfy` (`elem` [[SeenAbandoned], [SeenBytes "a"]])

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
