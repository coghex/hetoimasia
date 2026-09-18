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
    withVm
  , ScopeFailure (..)
  , runScoped
    -- * Observing what a VM did
  , Recorder
  , newRecorder
  , recordingCallback
  , recorded
    -- * Bridge bookkeeping
  , referenceSlot
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (SomeException, bracket, mask, try)
import Data.Text (Text)
import Foreign.C (CInt)
import Hetoimasia.Scripting.Lua.Bridge (Library, Vm, closeVm, newVm)
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (NoResult)
  , installCallback
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (probeReferenceSlot)

-- | Run a body over a VM and close it afterwards.
--
-- For the examples whose subject is not the close itself.
withVm ∷ [Library] → (Vm → IO a) → IO a
withVm libraries = bracket (newVm libraries) closeVm

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
