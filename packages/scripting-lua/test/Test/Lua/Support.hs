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
  , cancelling
    -- * Bridge bookkeeping
  , referenceSlot
  ) where

import Control.Concurrent (ThreadId, forkIO, throwTo)
import Control.Concurrent.MVar (MVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar)
import Control.Exception (Exception, SomeException, bracket, mask, try)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Foreign.C (CInt)
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

-- | Cancel a VM's execution owner, and do not go on until the cancellation has
-- actually been delivered.
--
-- @throwTo@ returns when its exception is delivered, so a sender that has
-- returned is a cancellation that has landed. Waiting for that sender is what
-- makes an example about cancellation an example rather than a race: nothing
-- after it is reasoning about a throw that might still be in flight.
--
-- The owner is the thread that called into the VM. While it is inside the
-- native call the cancellation cannot be delivered, so the sender runs on a
-- thread of its own and @release@ is what lets the call return -- after which
-- delivery, and this, complete.
cancelling ∷ Exception e ⇒ ThreadId → e → IO () → IO ()
cancelling owner exception release = do
  sent ← newEmptyMVar
  _ ← forkIO (throwTo owner exception >> putMVar sent ())
  release
  bounded (takeMVar sent)

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
