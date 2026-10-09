-- | The private bridge fixture.
--
-- Everything the examples need that a client outside this package may not have:
-- installing a Haskell callback, scoping a VM's lifetime around a body, and
-- reading the bridge's stack and registry bookkeeping. It reaches the package's
-- private bridge sublibrary, which is exactly why it lives beside the suite
-- rather than in the shared test-support library.
--
-- 'runScoped' is deliberately not @withResource@. A Lua close runs finalizers
-- and must not be interrupted part-way, and the resource contract's release
-- discipline is written for releases that may block under an uninterruptible
-- mask; wiring an unrestricted @lua_close@ into one would be claiming a
-- property this slice has not established. The protected owner facility that
-- will make that claim is LUA-2's.
module Test.Lua.Support
  ( -- * Lifetimes
    acquireVm
  , withVm
  , ScopeFailure (..)
  , runScoped
    -- * What the fixture observed
  , interpreterAcquisitions
    -- * Observing what a VM did
  , Recorder
  , newRecorder
  , recordingCallback
  , recorded
    -- * Cancelling an owner
  , Runner
  , Settled (..)
  , settling
  , cancelling
  , awaitSettled
  , observedCancellation
    -- * Observing an owner that may never return
  , detached
    -- * Bridge bookkeeping
  , referenceSlot
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent (ThreadId, forkIO, throwTo, yield)
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar_
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  , tryTakeMVar
  )
import Control.Exception
  ( Exception
  , ErrorCall (ErrorCall)
  , SomeException
  , allowInterrupt
  , bracket
  , fromException
  , mask
  , rethrowIO
  , throwIO
  , try
  , tryWithContext
  )
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Foreign.C (CInt)
import GHC.Conc
  ( BlockReason (BlockedOnException)
  , ThreadStatus (..)
  , threadStatus
  )
import Hetoimasia.Scripting.Lua.Bridge (Library, Vm, closeVm, newVm)
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (NoResult)
  , installCallback
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (probeReferenceSlot)
import System.IO.Unsafe (unsafePerformIO)
import Test.Support.Bounded (bounded)

-- | How many interpreters this suite's fixture has constructed.
--
-- One counter for the whole process, because the claim it supports is about
-- the whole process: a group of examples that acquires nothing while it runs
-- created no VM. It is the fixture's counter rather than the bridge's, so
-- 'acquireVm' is the only construction site the suite has — every example
-- below, and every example in the suite, goes through it rather than calling
-- 'newVm' itself.
acquisitionCounter ∷ IORef Int
acquisitionCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE acquisitionCounter #-}

-- | Construct a VM, counting the acquisition.
acquireVm ∷ [Library] → IO Vm
acquireVm libraries = do
  atomicModifyIORef' acquisitionCounter (\count → (count + 1, ()))
  newVm libraries

-- | How many interpreters have been acquired so far.
interpreterAcquisitions ∷ IO Int
interpreterAcquisitions = readIORef acquisitionCounter

-- | Run a body over a VM and close it afterwards.
--
-- For the examples whose subject is not the close itself.
withVm ∷ [Library] → (Vm → IO a) → IO a
withVm libraries = bracket (acquireVm libraries) closeVm

-- | How a scoped body and its close failed, with the precedence between them
-- recorded in the shape rather than left to the reader.
data ScopeFailure
  = -- | The body failed. Its failure is the one the caller is owed; a close
    -- failure that happened as well is retained beside it, never dropped.
    BodyFailed !SomeException !(Maybe SomeException)
  | -- | The body succeeded and the close failed.
    CloseFailed !SomeException

-- | Run a body over a VM, then close the VM terminally, keeping both failures.
--
-- The close runs whether the body succeeded, failed, or was cancelled, and the
-- body's failure takes precedence over the close's.
runScoped ∷ Vm → (Vm → IO a) → IO (Either ScopeFailure a)
runScoped vm body = mask $ \restore → do
  ran ← try (restore (body vm))
  closed ← try (closeVm vm)
  pure $ case (ran, closed) of
    (Right value, Right ()) → Right value
    (Right _, Left failure) → Left (CloseFailed failure)
    (Left failure, Right ()) → Left (BodyFailed failure Nothing)
    (Left failure, Left alsoFailed) → Left (BodyFailed failure (Just alsoFailed))

-- | What a VM's callbacks recorded, newest last.
newtype Recorder = Recorder (MVar [Text])

-- | A fresh recorder.
newRecorder ∷ IO Recorder
newRecorder = Recorder <$> newMVar []

-- | Install a callback that records its own name when Lua calls it.
recordingCallback ∷ Vm → Recorder → Text → IO ()
recordingCallback vm (Recorder slot) name =
  installCallback
    vm
    name
    (modifyMVar_ slot (pure . (<> [name])) >> pure NoResult)
    (pure ())

-- | A VM's execution owner, running an example's operation on a thread of its
-- own so that the example can cancel it. See 'settling'.
data Runner a = Runner !ThreadId !(MVar (Settled a))

-- | What a runner published: how its operation ended, and what was waiting for
-- it afterwards.
data Settled a = Settled
  { settledOperation ∷ !(Either SomeException a)
  -- ^ How the operation ended: its result, its own exception, or a
  -- cancellation delivered while it ran.
  , settledAfter ∷ !(Maybe SomeException)
  -- ^ A cancellation that was still pending when the operation had already
  -- ended, delivered at the one place the runner offers for it.
  }

-- | Run an operation as a VM's owner on a thread of its own, and make every way
-- it can end a result that is stored once.
--
-- The operation runs with the masking state of the caller. That is the
-- exposure it has anywhere else: the VM masks its own operations, and a
-- cancellation that is aimed at the thread is delivered when the VM's
-- protected region has been left, which this runner does not change.
--
-- What it does change is the handoff after the operation, which a bare
-- @forkIO@ leaves open. A cancellation delivered at the moment the operation's
-- own exception has been caught is raised outside the catcher, and a runner
-- that publishes afterwards is killed before it does. So the runner is forked
-- masked, catches the operation's outcome masked, and publishes masked. A
-- cancellation that has still not been delivered by then is taken at
-- 'allowInterrupt', inside a catcher of its own, so it is observed rather than
-- lost: the result records it as 'settledAfter'. Whichever way the operation
-- ends, one 'Settled' is stored.
settling ∷ IO a → IO (Runner a)
settling operation = do
  slot ← newEmptyMVar
  thread ← mask $ \restore → forkIO $ do
    ended ← try @SomeException (restore operation)
    pending ← try @SomeException allowInterrupt
    putMVar slot (Settled ended (either Just (const Nothing) pending))
  pure (Runner thread slot)

-- | Cancel a runner with its request pending against it before it is let go,
-- and do not go on until the request has been taken.
--
-- The runner is inside the VM's native call, where a cancellation cannot be
-- delivered, so @throwTo@ blocks: a sender that has started has shown nothing,
-- but a sender observed blocked in @throwTo@ (@BlockedOnException@) is a
-- request queued against the owner. That is the ordering this guarantees, and
-- it is checked rather than assumed: the sender is waited for until it is
-- blocked there, and it is a failure if it finishes or dies first, because then
-- the request was not pending against an owner that could not take it. Only
-- then does @release@ run, so the owner cannot return from the call, take the
-- VM's bookkeeping, or end its operation without the cancellation already
-- waiting for it.
--
-- What it does not guarantee is where the request is delivered afterwards. The
-- VM defers delivery through its own bookkeeping, and it lands wherever the
-- runner first allows it: inside the operation, or, once the operation has
-- ended, at 'settling''s own allowance. This returns when the sender's
-- @throwTo@ has returned, which is when the request has been taken by the
-- runner, or the runner has ended. 'awaitSettled' and 'observedCancellation'
-- are what show that the runner observed it.
cancelling ∷ Exception e ⇒ Runner a → e → IO () → IO ()
cancelling (Runner owner _) exception release = do
  sent ← newEmptyMVar
  sender ← forkIO (throwTo owner exception >> putMVar sent ())
  bounded (awaitPending sender)
  release
  bounded (takeMVar sent)

-- | Wait until a sender is blocked delivering its exception to a thread that
-- cannot take it yet.
awaitPending ∷ ThreadId → IO ()
awaitPending sender = do
  status ← threadStatus sender
  case status of
    ThreadBlocked BlockedOnException → pure ()
    ThreadFinished →
      throwIO (ErrorCall "the cancellation was delivered before its owner was released")
    ThreadDied → throwIO (ErrorCall "the sender of the cancellation died")
    _ → yield *> awaitPending sender

-- | Wait for a runner's one result, and for its handoff to be complete.
--
-- A second result would not go unnoticed: one published while the first was
-- still unread blocks its runner, which never ends, and one published after it
-- was read is found afterwards. Both fail the example, so a handoff that was
-- left blocked cannot pass as a success.
awaitSettled ∷ Runner a → IO (Settled a)
awaitSettled (Runner thread slot) = do
  settled ← bounded (takeMVar slot)
  bounded (awaitEnded thread)
  extra ← tryTakeMVar slot
  case extra of
    Nothing → pure settled
    Just _ → throwIO (ErrorCall "a runner stored a second result")

-- | Wait until a thread has ended.
awaitEnded ∷ ThreadId → IO ()
awaitEnded thread = do
  status ← threadStatus thread
  case status of
    ThreadFinished → pure ()
    ThreadDied → pure ()
    _ → yield *> awaitEnded thread

-- | The cancellation the runner observed, wherever it landed: inside the
-- operation, or after it. Nothing means the runner never saw one.
observedCancellation ∷ Exception e ⇒ Settled a → Maybe e
observedCancellation settled =
  either fromException (const Nothing) (settledOperation settled)
    <|> (settledAfter settled >>= fromException)

-- | Run a body as a VM's owner on a thread of its own, and wait for it under a
-- bound.
--
-- For an example whose failure would leave the owner inside a @safe@ foreign
-- call for good. Bounding the owner itself would not do: a timeout is an
-- asynchronous exception, and one aimed at a thread inside Lua is never
-- delivered. So the owner is forked and the bound is on this thread, which is
-- never inside Lua and can always be interrupted. The body's own cleanup,
-- closing its VM included, runs on the owner's thread; a stuck owner is left
-- where it is rather than cancelled, joined, or closed, and the example fails
-- within the bound.
detached ∷ IO a → IO a
detached body = do
  outcome ← newEmptyMVar
  _ ← mask $ \restore → forkIO (tryWithContext @SomeException (restore body) >>= putMVar outcome)
  bounded (takeMVar outcome) >>= either rethrowIO pure

-- | The registry slot a temporary reference would take right now.
--
-- The bridge takes no registry reference of its own, so this answers the same
-- slot before and after every operation. A move would mean it had left one
-- behind.
referenceSlot ∷ Vm → IO CInt
referenceSlot = probeReferenceSlot

-- | Read a recorder.
recorded ∷ Recorder → IO [Text]
recorded (Recorder slot) = readMVar slot
