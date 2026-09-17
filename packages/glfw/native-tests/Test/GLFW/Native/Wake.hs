-- | The session's wake capability, and the admission that owes one, against a
-- real native wait in the shared session.
--
-- Each example runs inside one dispatched operation, so the production finite
-- wait runs on the process main thread that owns the session, through the same
-- owner operation the window host's loop uses. A worker thread wakes it with the
-- production capability, and only once the shim reports that wait's own
-- sequence number read on both sides of observing its thread blocked in the
-- kernel ('blockedWaitForCheck'); that observation posts nothing, so the only
-- empty events posted are the production wakes under test. As each wait returns,
-- the shim records its sequence number and whether a production wake was posted
-- while it was in progress ('takeLastWaitForCheck').
--
-- No example sleeps. Each wait is bounded by 'waitBound', which is far beyond any
-- wake's latency; a wait that returned without reaching it returned on an
-- event, and one that reached it fails the example rather than passing. Each
-- example prints one evidence line.
module Test.GLFW.Native.Wake (spec) where

import Control.Concurrent (ThreadId, forkIO, forkOS, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (SomeException, displayException, finally, try)
import Control.Monad (replicateM, when)
import GHC.Clock (getMonotonicTime)
import Hetoimasia.GLFW.Command
  ( Disposition (NotExecuted)
  , SubmitResult (..)
  , closeWindowCommands
  , createWindowCommand
  , newWindowCommandHost
  , pollCompletion
  , submitWindowCommand
  , windowCommandPort
  )
import Hetoimasia.GLFW.Internal.Native (blockedWaitForCheck, takeLastWaitForCheck)
import Hetoimasia.GLFW.Internal.Window (EventProcessing (..), processWindowEvents)
import Hetoimasia.GLFW.Session (Session, SessionWake, WakeOutcome (..), sessionWake, wakeSession)
import Hetoimasia.GLFW.Window (hiddenTestWindowConfig)
import Numeric.Natural (Natural)
import System.IO (hFlush, stdout)
import Test.GLFW.Native.Support (Shared, failed, owned)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Shared → Spec
spec shared = describe "session wake" $ do
  it "ends a wait the owner thread entered and was blocked inside, with a worker's production wake" $ do
    evidence ← owned shared $ \session → do
      settle session
      wokenWait forkIO session (sessionWake session) 1 0
    evidenceLine "worker wake" evidence
    waitOutcomes evidence `shouldBe` [WakePosted]
    waitReturned evidence `shouldBe` Just (waitBlocked evidence)
    waitWoken evidence `shouldBe` True
    waitSpurious evidence `shouldBe` 0

  it "returns an entered wait once for repeated wakes, and leaves at most one spurious return before the next wait blocks" $ do
    (repeated, next) ← owned shared $ \session → do
      let wake = sessionWake session
      settle session
      repeated ← wokenWait forkOS session wake 3 0
      next ← wokenWait forkIO session wake 1 (waitBlocked repeated)
      pure (repeated, next)
    evidenceLine "repeated wakes" repeated
    evidenceLine "next wait" next
    waitOutcomes repeated `shouldBe` replicate 3 WakePosted
    waitReturned repeated `shouldBe` Just (waitBlocked repeated)
    waitWoken repeated `shouldBe` True
    waitSpurious repeated `shouldBe` 0
    waitWoken next `shouldBe` True
    waitSpurious next `shouldSatisfy` (<= 1)

  it "ends an entered wait through the production admission path, with a command a worker submitted" $ do
    (evidence, disposition, settled) ← owned shared $ \session → do
      settle session
      -- The wake is the production admission's own, not a wake this example
      -- posts: the worker only submits a command through the ordinary port.
      host ← newWindowCommandHost session 4
      let port = windowCommandPort host
          command = createWindowCommand (hiddenTestWindowConfig "native admission wake" 64 48)
      evidence ← wokenWaitBy forkIO session 0 (submitWindowCommand port [] command)
      -- Nothing executed it, so no window was created in the shared session:
      -- closure settles the command the wake announced.
      settled ← atomically (closeWindowCommands host)
      disposition ← case waitOutcomes evidence of
        SubmitAccepted ticket → atomically (pollCompletion ticket)
        other → failed ("the submission was not admitted: " <> show other)
      pure (evidence, disposition, settled)
    evidenceLine "admission wake" evidence
    waitReturned evidence `shouldBe` Just (waitBlocked evidence)
    waitWoken evidence `shouldBe` True
    waitSpurious evidence `shouldBe` 0
    settled `shouldBe` 1
    disposition `shouldBe` Just NotExecuted

  it "returns at most one wait early for spurious wakes posted while no wait was in progress" $ do
    (spurious, evidence) ← owned shared $ \session → do
      let wake = sessionWake session
      (floor', _) ← takeLastWaitForCheck
      spurious ← replicateM 3 (wakeSession wake)
      evidence ← wokenWait forkOS session wake 1 floor'
      pure (spurious, evidence)
    evidenceLine "spurious wakes" evidence
    spurious `shouldBe` replicate 3 WakePosted
    waitWoken evidence `shouldBe` True
    waitSpurious evidence `shouldSatisfy` (<= 1)

-- | What one woken wait showed, with whatever the worker's own action answered.
data WaitEvidence a = WaitEvidence
  { waitBlocked ∷ Natural
    -- ^ The sequence number of the wait the worker observed blocked, and woke.
  , waitOutcomes ∷ a
  , waitReturned ∷ Maybe Natural
    -- ^ The sequence number of the wait that returned woken, if one did.
  , waitWoken ∷ Bool
  , waitSpurious ∷ Int
    -- ^ Waits that returned, before the woken one, without being observed blocked.
  , waitSeconds ∷ Double
    -- ^ How long the woken wait's owner operation took, against 'waitBound'.
  }

-- | Wait on the owner thread until a worker started by @fork@, having observed a
-- wait later than @after@ blocked inside GLFW, wakes it @wakes@ times. Waits
-- that return unwoken first are counted as spurious, up to 'spuriousLimit'.
wokenWait ∷ (IO () → IO ThreadId) → Session → SessionWake → Int → Natural → IO (WaitEvidence [WakeOutcome])
wokenWait fork session wake wakes after = wokenWaitBy fork session after (replicateM wakes (wakeSession wake))

-- | 'wokenWait' over any action the worker runs once it has observed a wait
-- later than @after@ blocked inside GLFW — a wake, or an admission that owes
-- one.
wokenWaitBy ∷ (IO () → IO ThreadId) → Session → Natural → IO a → IO (WaitEvidence a)
wokenWaitBy fork session after act = do
  ownerDone ← newTVarIO False
  worker ← newEmptyMVar
  _ ← fork (try (observeAndWake ownerDone) >>= putMVar worker)
  let loop spurious = do
        started ← getMonotonicTime
        processWindowEvents session (AwaitEventsFor waitBound)
        seconds ← subtract started <$> getMonotonicTime
        (returned, woken) ← takeLastWaitForCheck
        when (seconds >= waitBound) $
          failed ("wait " <> show returned <> " reached its bound of " <> show waitBound <> " seconds instead of returning on a wake")
        if woken || spurious >= spuriousLimit
          then pure (returned, woken, spurious, seconds)
          else loop (spurious + 1)
  (returned, woken, spurious, seconds) ← loop 0 `finally` atomically (writeTVar ownerDone True)
  takeMVar worker >>= \case
    Left failure → failed ("the waking worker failed: " <> displayException (failure ∷ SomeException))
    Right Nothing → failed "the worker never observed a wait blocked inside GLFW"
    Right (Just (blocked, outcomes)) →
      pure
        WaitEvidence
          { waitBlocked = blocked
          , waitOutcomes = outcomes
          , waitReturned = if woken then Just returned else Nothing
          , waitWoken = woken
          , waitSpurious = spurious
          , waitSeconds = seconds
          }
  where
    observeAndWake ownerDone = do
      done ← readTVarIO ownerDone
      if done
        then pure Nothing
        else
          blockedWaitForCheck >>= \case
            Just blocked | blocked > after → do
              outcomes ← act
              pure (Just (blocked, outcomes))
            _ → yield >> observeAndWake ownerDone

-- | Process whatever an earlier example left pending, so the next wait can only
-- return on this example's wakes, and clear the last wait's record.
settle ∷ Session → IO ()
settle session = do
  processWindowEvents session ProcessPending
  _ ← takeLastWaitForCheck
  pure ()

-- | The bound on each wait: far beyond a wake's latency, so reaching it means
-- the wake did not end the wait.
waitBound ∷ Double
waitBound = 60

-- | How many waits may return without being woken before an example stops
-- waiting for one that blocks.
spuriousLimit ∷ Int
spuriousLimit = 3

evidenceLine ∷ Show a ⇒ String → WaitEvidence a → IO ()
evidenceLine label evidence = do
  putStrLn
    ( "glfw-native-tests wake evidence: "
        <> label
        <> ": wait "
        <> show (waitBlocked evidence)
        <> " observed blocked before the worker's "
        <> show (waitOutcomes evidence)
        <> "; wait "
        <> maybe "none" show (waitReturned evidence)
        <> " returned woken after "
        <> show (waitSpurious evidence)
        <> " spurious return(s), in "
        <> show (waitSeconds evidence)
        <> "s of a "
        <> show waitBound
        <> "s bound"
    )
  hFlush stdout
