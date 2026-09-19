-- | What is left behind when a launch fails, when the parent is cancelled, and
-- when a child is killed outright.
--
-- Requirement 7's three cases. The claim under all of them is the same one, and
-- it is about ordering rather than about counting: the admitted owner is
-- released only after the parent has observed a termination. The ledger in
-- "Test.Confinement.Support" is arranged so that this is the only way to
-- release one, so an example that finds it empty has found that an observation
-- happened, not that something decremented hopefully.
--
-- The cancellation case cancels the owner rather than the child. That is the
-- shape the engine will have -- a Haskell thread owns the child and can be torn
-- down by a supervisor -- and it is the case in which bookkeeping is most
-- easily left behind, because the thread that would have tidied up is the one
-- that was interrupted.
module Test.Confinement.Lifetime (spec) where

import Control.Concurrent (forkIO, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import System.Posix.Process (ProcessStatus (Terminated))
import System.Posix.Signals (sigKILL)
import Test.Confinement.Support
  ( Availability
  , Confined (confinedPid)
  , Controls
  , Launch (launchRoot)
  , Ledger
  , Refusal (refusedErrno, refusedLayer)
  , admittedOwners
  , announce
  , awaitReady
  , describeRefusal
  , describeStatus
  , forceStop
  , launchFor
  , observeExit
  , outputClosed
  , releaseAfter
  , stillRunning
  , whenAvailable
  , withLaunch
  , withRoot
  )
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldNotBe)
import Test.Support.Bounded (bounded)

spec ∷ Ledger → Controls → [FilePath] → Availability → Spec
spec ledger available sentinels installed = describe "lifetime" $ do
  it "leaves no admitted owner when initialization fails" $ do
    -- The same real withholding requirement 2 uses, asked here as a lifetime
    -- question: a launch that never produced a child must not have produced
    -- bookkeeping either.
    before ← admittedOwners ledger
    outcome ←
      withLaunch
        ledger
        (launchFor "report" "/nonexistent/hetoimasia-no-root" available sentinels "hetoimasia-init")
        pure
    after ← admittedOwners ledger
    case outcome of
      Right _ → expectationFailure "a launch that could not install a profile started a child"
      Left refusal → do
        refusedLayer refusal `shouldNotBe` "none"
        refusedErrno refusal `shouldNotBe` 0
        after `shouldBe` before
        announce
          ( "PROVED lifetime-initialization-failure "
              <> describeRefusal refusal
              <> " admitted-owners-unchanged=yes"
          )

  it "leaves no live child when the parent's owner is cancelled mid-run" $
    whenAvailable installed "lifetime-cancellation" $ do
      running ← newIORef Nothing
      started ← newEmptyMVar
      finished ← newEmptyMVar
      owner ←
        forkIO $ do
          outcome ←
            try @SomeException $
              withRoot $ \root →
                withLaunch ledger (idle root) $ \launched → case launched of
                  Left _ → putMVar started Nothing
                  Right child → do
                    _ ← awaitReady child
                    writeIORef running (Just child)
                    putMVar started (Just (confinedPid child))
                    -- Parked where a supervisor would find it: the owner is
                    -- waiting on a child that will never finish on its own.
                    blocked ← newEmptyMVar
                    takeMVar blocked
          putMVar finished outcome
      admittedPid ← bounded (takeMVar started)
      case admittedPid of
        Nothing →
          expectationFailure
            "the profile installed for the trial child but refused the cancellation case"
        Just _ → do
          -- Cancelling the owner is not the same as ending the child, which is
          -- the point: the child outlives the cancellation unless the owner's
          -- own teardown runs.
          _ ← forkIO (throwTo owner ThreadKilled)
          _ ← bounded (takeMVar finished)
          child ← readIORef running
          case child of
            Nothing → expectationFailure "the cancelled owner recorded no child"
            Just launched → do
              alive ← stillRunning launched
              alive `shouldBe` False
              owners ← admittedOwners ledger
              owners `shouldBe` []
              announce
                ( "PROVED lifetime-cancellation owner=cancelled child=reaped"
                    <> " admitted-owners=0"
                )

  it "reaps a force-killed child and releases its owner only after observing it" $
    whenAvailable installed "lifetime-forced-exit" $
      withRoot $ \root →
        withLaunch ledger (idle root) $ \launched → case launched of
          Left _ →
            expectationFailure
              "the profile installed for the trial child but refused the forced-exit case"
          Right child → do
            _ ← awaitReady child
            -- Admitted, and still admitted: the kill alone releases nothing.
            beforeKill ← admittedOwners ledger
            beforeKill `shouldBe` [confinedPid child]
            forceStop child
            status ← observeExit child
            duringObservation ← admittedOwners ledger
            duringObservation `shouldBe` [confinedPid child]
            _ ← releaseAfter ledger child
            afterRelease ← admittedOwners ledger
            afterRelease `shouldBe` []
            status `shouldBe` Terminated sigKILL False
            -- And the confined process itself is gone, not only the supervisor
            -- the parent waited on: its output reaches end-of-file, which it
            -- cannot while anything still holds the far end.
            drained ← outputClosed child
            drained `shouldBe` True
            announce
              ( "PROVED lifetime-forced-exit observed="
                  <> describeStatus status
                  <> " confined-process-gone=yes"
                  <> " release-followed-observation=yes admitted-owners=0"
              )
  where
    idle root =
      (launchFor "idle" root available sentinels "hetoimasia-confine-idle")
        {launchRoot = root}
