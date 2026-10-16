-- | Cancelling an owner: where a cancellation lands, and what survives it.
--
-- A cancellation cannot be delivered to a thread inside a Lua call: the call is
-- @safe@ and the exception waits for it to return. That is what makes the
-- owner's contract checkable without sleeps. An example blocks the owner inside
-- a callback of its own, waits until the cancellation is observed queued
-- against the owner ('cancelling' does that: its sender is blocked delivering),
-- and only then lets the callback return. Nothing here depends on timing.
--
-- Cancellation before the lifetime, during initialization and during the body
-- ends that step and the VM is closed on the way out. A cancellation during the
-- close is deferred: the close is masked, so it does not land inside it, the
-- dependencies are released after the state has closed, the close does not run
-- twice however often the owner is cancelled, and the cancellation is raised
-- afterwards with the close's failures retained on it as cleanup evidence.
module Test.Lua.Owner.Cancellation (spec) where

import Control.Concurrent (ThreadId, forkIO, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( AsyncException (UserInterrupt)
  , SomeException
  , WhileHandling (WhileHandling)
  , annotateIO
  , fromException
  , mask_
  , someExceptionContext
  , throwIO
  , try
  )
import Control.Exception.Context (getExceptionAnnotations)
import Control.Monad (replicateM)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Set as Set
import Data.Text (Text)
import GHC.Conc (BlockReason (BlockedOnException, BlockedOnMVar), ThreadStatus (ThreadBlocked), threadStatus)
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailures)
import Hetoimasia.Scripting.Lua.Bridge (chunkName)
import Hetoimasia.Scripting.Lua.Internal.Callback (CallbackResult (NoResult), installCallback)
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnerConfig (ownerAfterLibraries, ownerAllowlist, ownerChunks)
  , evalOwned
  , ownedInternalVm
  , withOwnedVm
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (Phase (Closed), vmPhase)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Owner.Support
import Test.Lua.Support (Settled (settledOperation), awaitSettled, cancelling, observedCancellation, settling)
import Test.Support.Bounded (bounded)

-- | A callback Lua can call that blocks the owner's thread in Lua until the
-- example lets it return.
data Hold = Hold
  { holdEntered ∷ !(MVar ())
  , holdRelease ∷ !(MVar ())
  }

newHold ∷ IO Hold
newHold = Hold <$> newEmptyMVar <*> newEmptyMVar

-- | Install @hold@, which notes that it is waiting, signals, waits for the
-- release, and notes that it left.
holdCallback ∷ Finalizing → Hold → OwnerConfig → OwnerConfig
holdCallback finalizing hold config =
  config
    { ownerAfterLibraries = \vm → do
        ownerAfterLibraries config vm
        installCallback
          vm
          "hold"
          ( do
              note (finalizingEvents finalizing) "hold: waiting"
              putMVar (holdEntered hold) ()
              takeMVar (holdRelease hold)
              note (finalizingEvents finalizing) "hold: left"
              pure NoResult
          )
          (pure ())
    , ownerAllowlist = Set.insert "hold" (ownerAllowlist config)
    }

-- | Install @slow@, whose retained release blocks until the example lets it
-- return: a dependency the close releases after the interpreter has closed, and
-- that a cancellation of the owner must neither interrupt nor be taken for the
-- failure of.
slowRelease ∷ Finalizing → Hold → OwnerConfig → OwnerConfig
slowRelease finalizing hold config =
  config
    { ownerAfterLibraries = \vm → do
        ownerAfterLibraries config vm
        installCallback
          vm
          "slow"
          (pure NoResult)
          ( do
              note (finalizingEvents finalizing) "slow release: waiting"
              putMVar (holdEntered hold) ()
              takeMVar (holdRelease hold)
              note (finalizingEvents finalizing) "slow release: left"
          )
    }

-- | A guard whose finalizer calls @hold@ when the state closes.
holdingGuard ∷ OwnerConfig → OwnerConfig
holdingGuard config =
  config
    { ownerChunks =
        ownerChunks config
          <> [(chunkName "hold guard", "hold_guard = setmetatable({}, {__gc = function() hold() end})")]
    }

spec ∷ Spec
spec = describe "cancellation" $ do
  it "leaves nothing constructed when it is cancelled before the lifetime begins" $ do
    started ← newEmptyMVar
    constructed ← newIORef False
    result ← newEmptyMVar
    finalizing ← newFinalizing
    let config = (finalizingConfig finalizing) {ownerAfterLibraries = \_ → writeIORef constructed True}
    -- Forked masked, so the thread's own handler is in place before the
    -- cancellation can reach it; it is interruptible at the wait for the start.
    owner ← mask_ (forkIO (try @SomeException (takeMVar started >> withOwnedVm config (\_ → pure ())) >>= putMVar result))
    throwTo owner UserInterrupt
    outcome ← bounded (takeMVar result)
    either (\raised → fromException raised) (const Nothing) outcome `shouldBe` Just UserInterrupt
    readIORef constructed >>= (`shouldBe` False)
    events (finalizingEvents finalizing) >>= (`shouldBe` [])

  it "ends initialization when cancelled inside an initial chunk, closing the VM before the cancellation is raised" $ do
    finalizing ← newFinalizing
    hold ← newHold
    bodyRan ← newIORef False
    let base = holdCallback finalizing hold (finalizingConfig finalizing)
        config = base {ownerChunks = ownerChunks base <> [(chunkName "holding", "hold()")]}
    runner ← settling (withOwnedVm config (\_ → writeIORef bodyRan True))
    bounded (takeMVar (holdEntered hold))
    cancelling runner UserInterrupt (putMVar (holdRelease hold) ())
    settled ← awaitSettled runner
    observedCancellation settled `shouldBe` Just UserInterrupt
    readIORef bodyRan >>= (`shouldBe` False)
    -- The VM was closed on the way out, its finalizer reached with the
    -- dependency live, and nothing failed in the close.
    events (finalizingEvents finalizing)
      >>= (`shouldBe` ["hold: waiting", "hold: left", "finalizer: dependency live", "release"])
    evidenceIn settled `shouldBe` []

  it "ends the body when cancelled inside a chunk it runs, closing the VM before the cancellation is raised" $ do
    finalizing ← newFinalizing
    hold ← newHold
    afterwards ← newIORef False
    let config = holdCallback finalizing hold (finalizingConfig finalizing)
    runner ←
      settling $
        withOwnedVm config $ \owned → do
          evalOwned owned (chunkName "holding") "hold()"
          writeIORef afterwards True
    bounded (takeMVar (holdEntered hold))
    cancelling runner UserInterrupt (putMVar (holdRelease hold) ())
    settled ← awaitSettled runner
    observedCancellation settled `shouldBe` Just UserInterrupt
    readIORef afterwards >>= (`shouldBe` False)
    events (finalizingEvents finalizing)
      >>= (`shouldBe` ["hold: waiting", "hold: left", "finalizer: dependency live", "release"])
    evidenceIn settled `shouldBe` []

  it "defers a cancellation that arrives during the close, releases dependencies only after it, and raises the cancellation with the close's failure as cleanup evidence" $ do
    finalizing ← newFinalizing
    hold ← newHold
    vmRef ← newCaptured
    let config = holdingGuard (holdCallback finalizing hold (failingReleaseConfig finalizing))
    runner ← settling (withOwnedVm config (\owned → capture vmRef (ownedInternalVm owned)))
    -- The body has returned and the close is running its finalizers: the owner is
    -- inside the one that holds.
    bounded (takeMVar (holdEntered hold))
    cancelling runner UserInterrupt (putMVar (holdRelease hold) ())
    settled ← awaitSettled runner
    observedCancellation settled `shouldBe` Just UserInterrupt
    -- The finalizer waited for the release rather than being cancelled out of the
    -- close, and the dependency was released only once it had left.
    logged ← events (finalizingEvents finalizing)
    logged `shouldSatisfy` before "hold: waiting" "hold: left"
    logged `shouldSatisfy` before "hold: left" "release"
    length (filter (== "release") logged) `shouldBe` 1
    length (filter (== "finalizer: dependency live") logged) `shouldBe` 1
    -- The cancellation is primary, and the failed release is cleanup evidence on
    -- it, as a supervisor reads it.
    evidenceIn settled `shouldBe` ["lua release"]
    cancelledOutcome settled `shouldBe` True
    captured vmRef >>= \case
      Nothing → expectationFailure "the body did not run"
      Just vm → vmPhase vm >>= (`shouldBe` Closed)

  it "raises a cancellation during a close that also fails with every close failure retained, each with its own context" $ do
    finalizing ← newFinalizing
    hold ← newHold
    let config = holdingGuard (holdCallback finalizing hold (failingCloseConfig finalizing))
    runner ← settling (withOwnedVm config (\_ → pure ()))
    bounded (takeMVar (holdEntered hold))
    cancelling runner UserInterrupt (putMVar (holdRelease hold) ())
    settled ← awaitSettled runner
    observedCancellation settled `shouldBe` Just UserInterrupt
    evidenceIn settled `shouldBe` ["lua finalizer", "lua release"]
    case settledOperation settled of
      Right () → expectationFailure "the cancellation was lost"
      Left raised → map cleanupFailureLabel (cleanupFailures raised) `shouldBe` ["lua finalizer", "lua release"]

  it "survives repeated cancellation of the closing owner: no early release, no second close, and the evidence still on what it raises" $ do
    finalizing ← newFinalizing
    hold ← newHold
    let config = holdingGuard (holdCallback finalizing hold (failingReleaseConfig finalizing))
    (owner, slot) ← ownerThread config (\_ → pure ())
    bounded (takeMVar (holdEntered hold))
    senders ←
      replicateM 4 $ do
        done ← newEmptyMVar
        sender ← forkIO (throwTo owner UserInterrupt >> putMVar done ())
        pure (sender, done)
    -- Every one of the four cancellations is queued against the owner, which is
    -- inside Lua and cannot take any of them yet.
    mapM_ (bounded . awaitBlockedOnException . fst) senders
    -- Nothing has been released while it waits, and the dependency is live.
    events (finalizingEvents finalizing) >>= (`shouldSatisfy` notElem "release")
    putMVar (holdRelease hold) ()
    outcome ← bounded (takeMVar slot)
    mapM_ (bounded . takeMVar . snd) senders
    case outcome of
      Right () → expectationFailure "the cancellation was lost"
      Left failure → do
        causeOf failure `shouldBe` Just UserInterrupt
        asyncCancellation failure `shouldBe` True
        -- None of the later cancellations superseded the one that carries the
        -- close's failure.
        evidenceLabels failure `shouldBe` ["lua release"]
    logged ← events (finalizingEvents finalizing)
    length (filter (== "release") logged) `shouldBe` 1
    length (filter (== "finalizer: dependency live") logged) `shouldBe` 1
    length (filter (== "hold: left") logged) `shouldBe` 1
    logged `shouldSatisfy` before "hold: left" "release"

  it "keeps the evidence on the cancellation however many are queued, past any fixed count" $ do
    finalizing ← newFinalizing
    hold ← newHold
    let config = holdingGuard (holdCallback finalizing hold (failingReleaseConfig finalizing))
        queued = 1500
    (owner, slot) ← ownerThread config (\_ → pure ())
    bounded (takeMVar (holdEntered hold))
    senders ←
      replicateM queued $ do
        done ← newEmptyMVar
        sender ← forkIO (throwTo owner UserInterrupt >> putMVar done ())
        pure (sender, done)
    mapM_ (bounded . awaitBlockedOnException . fst) senders
    putMVar (holdRelease hold) ()
    outcome ← bounded (takeMVar slot)
    mapM_ (bounded . takeMVar . snd) senders
    case outcome of
      Right () → expectationFailure "the cancellation was lost"
      Left failure → do
        causeOf failure `shouldBe` Just UserInterrupt
        -- Not one of the queued cancellations was left to supersede the
        -- exception that carries the close's failure.
        evidenceLabels failure `shouldBe` ["lua release"]

  it "does not take a cancellation that arrives while a retained release blocks for that release's failure, and raises it ahead of an earlier close failure" $ do
    finalizing ← newFinalizing
    hold ← newHold
    let config = slowRelease finalizing hold (failingFinalizerConfig finalizing)
    (owner, slot) ← ownerThread config (\_ → pure ())
    -- The close has run its finalizers, one of which failed, and is releasing: the
    -- owner is inside the retained release, and is observed blocked on its wait.
    -- That wait is a blocking operation of Haskell's own, which a cancellation
    -- could interrupt if the release were interruptible, so the example waits
    -- until the owner is in it rather than assuming it is.
    bounded (takeMVar (holdEntered hold))
    bounded (awaitBlockedOnMVar owner)
    done ← newEmptyMVar
    sender ← forkIO (throwTo owner UserInterrupt >> putMVar done ())
    -- Uninterruptible, the release cannot take the cancellation: it stays queued
    -- against the owner, with the sender blocked delivering it. An interruptible
    -- release would take it at once and the sender would finish, which this wait
    -- would never see.
    bounded (awaitBlockedOnException sender)
    putMVar (holdRelease hold) ()
    outcome ← bounded (takeMVar slot)
    bounded (takeMVar done)
    -- The release was not interrupted: it waited, and it left.
    logged ← events (finalizingEvents finalizing)
    logged `shouldSatisfy` before "slow release: waiting" "slow release: left"
    -- The cancellation is the primary failure, with the finalizer's failure as
    -- cleanup evidence, and is not itself an entry of that evidence.
    case outcome of
      Right () → expectationFailure "the cancellation was lost"
      Left failure → do
        causeOf failure `shouldBe` Just UserInterrupt
        asyncCancellation failure `shouldBe` True
        evidenceLabels failure `shouldBe` ["lua finalizer"]

  it "raises a cancellation that arrives during the close ahead of the body's failure, leaving that failure reachable beside it" $ do
    finalizing ← newFinalizing
    hold ← newHold
    let config = holdingGuard (holdCallback finalizing hold (finalizingConfig finalizing))
    runner ←
      settling
        (withOwnedVm config (\_ → annotateIO (Marker "body context") (throwIO (BodyBroke "body")) ∷ IO ()))
    bounded (takeMVar (holdEntered hold))
    cancelling runner UserInterrupt (putMVar (holdRelease hold) ())
    settled ← awaitSettled runner
    observedCancellation settled `shouldBe` Just UserInterrupt
    case settledOperation settled of
      Right () → expectationFailure "the cancellation was lost"
      Left raised → do
        let handled = [inner | WhileHandling inner ← getExceptionAnnotations (someExceptionContext raised)]
        [fromException inner | inner ← handled] `shouldBe` [Just (BodyBroke "body")]

-- | The labels of the cleanup evidence on how an owner's operation ended.
evidenceIn ∷ Settled a → [Text]
evidenceIn settled = case settledOperation settled of
  Right _ → []
  Left raised → map cleanupFailureLabel (cleanupFailures raised)

-- | Whether the operation ended by a cancellation.
cancelledOutcome ∷ Settled a → Bool
cancelledOutcome settled = observedCancellation settled == Just UserInterrupt

-- | Whether the first entry comes before the second, both present.
before ∷ Text → Text → [Text] → Bool
before earlier later logged = case (lookup' earlier, lookup' later) of
  (Just first, Just second) → first < second
  _ → False
  where
    lookup' entry = lookup entry (zip logged [0 ∷ Int ..])

-- | Wait until a thread is blocked on an @MVar@, which is where a retained
-- release that waits for the example stands.
awaitBlockedOnMVar ∷ ThreadId → IO ()
awaitBlockedOnMVar thread = do
  status ← threadStatus thread
  case status of
    ThreadBlocked BlockedOnMVar → pure ()
    _ → yield *> awaitBlockedOnMVar thread

-- | Wait until a thread is blocked delivering an exception to a thread that
-- cannot take it yet.
awaitBlockedOnException ∷ ThreadId → IO ()
awaitBlockedOnException sender = do
  status ← threadStatus sender
  case status of
    ThreadBlocked BlockedOnException → pure ()
    _ → yield *> awaitBlockedOnException sender
