-- | What the finite-call adapter and the scheduled owners share: the runtime
-- boundary and the identities it issues, the refusal of a wait from a Lua
-- callback, the readiness wait, and the treatment a request's strings and
-- values get on the producer's thread.
--
-- Nothing here is new behaviour. It is the code "Hetoimasia.Scripting.Lua.Runtime"
-- had, moved so that both kinds of owner use the one definition.
module Hetoimasia.Scripting.Lua.Runtime.Shared
  ( LuaRuntime (..)
  , newLuaRuntime
  , issueOwnerId
  , runtimeComponent
  , refuseCallbackWait
  , readiness
  , compact
  , compactRef
  , compactName
  , clip
  ) where

import Control.Concurrent.STM (STM, TVar, orElse, readTVar, retry)
import Control.Monad (when)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Unique (Unique, newUnique)
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Runtime.Supervision
  ( RuntimeControl
  , SupervisedWorker
  , WorkerStatus (WorkerLive)
  , workerStatus
  )
import Hetoimasia.Scripting.Lua.Internal.Value (Capability (capabilityTypeName))
import Hetoimasia.Scripting.Lua.Internal.Vm (runningLuaCallback)
import Hetoimasia.Scripting.Lua.Owner (ModuleRef (ModuleRef, moduleRefName, moduleRefVersion), maxIdentityLength)
import Hetoimasia.Scripting.Lua.Registration (maxNameLength)
import Hetoimasia.Scripting.Lua.Runtime.Types (CallbackWaitRefused (CallbackWaitRefused), OwnerId (OwnerId))
import Hetoimasia.Scripting.Lua.Value (Value (VBytes, VCapability, VList, VRecord, VText))

-- | The runtime boundary owners are created in: the supervision control they
-- are started under, and the identities issued so far.
--
-- Make one for each 'withSupervision' invocation. It belongs to the
-- application thread, as the 'RuntimeControl' it holds does.
data LuaRuntime = LuaRuntime
  { runtimeControl ∷ !RuntimeControl
  , runtimeScope ∷ !Unique
  , runtimeIssued ∷ !(IORef Word64)
  }

-- | A runtime boundary over a supervision control.
newLuaRuntime ∷ RuntimeControl → IO LuaRuntime
newLuaRuntime control = LuaRuntime control <$> newUnique <*> newIORef 0

-- | The next identity of a runtime, never an earlier one.
issueOwnerId ∷ LuaRuntime → IO OwnerId
issueOwnerId runtime =
  OwnerId (runtimeScope runtime) <$> atomicModifyIORef' (runtimeIssued runtime) (\issued → (issued + 1, issued + 1))

runtimeComponent ∷ Component
runtimeComponent = unsafeComponent "scripting.lua.runtime"

-- | Refuse, at once, a wait asked from a thread that is running a Lua callback.
refuseCallbackWait ∷ HasCallStack ⇒ Text → IO ()
refuseCallbackWait name = do
  inside ← runningLuaCallback
  when inside $
    throwFailure runtimeComponent (operation name) [] (CallbackWaitRefused name)

-- | Ready, or the worker's terminal status: whichever comes first, so that a
-- failed initializer never leaves the wait hanging.
readiness ∷ TVar (Maybe a) → SupervisedWorker () → STM (Maybe a)
readiness handoff worker =
  (readTVar handoff >>= maybe retry (pure . Just))
    `orElse` ( workerStatus worker >>= \case
                 WorkerLive → retry
                 _ → pure Nothing
             )

-- | The routing strings of a call get the same treatment as its values: they are
-- copied, and one longer than any valid identity or name is cut to one character
-- past the longest valid one, which can only be refused, and which is as much of
-- it as a refusal will ever quote.
compactRef ∷ ModuleRef → ModuleRef
compactRef ref =
  ModuleRef (clip maxIdentityLength (moduleRefName ref)) (clip maxIdentityLength (moduleRefVersion ref))

compactName ∷ Text → Text
compactName = clip maxNameLength

clip ∷ Int → Text → Text
clip limit = Text.copy . Text.take (limit + 1)

-- | Compact what the queue keeps. The value limits count the bytes a value
-- encodes to, and a capability is 21 of them whatever its type's name is; but
-- the queue keeps the value as it was given, and a string that is a slice of a
-- larger one keeps the larger one's whole buffer alive while the call waits.
-- So every string in an accepted call is copied to a buffer of its own, which
-- the limits do bound, and a capability's type name is first cut to one
-- character past 'maxNameLength': no registered type has a longer name, so a
-- longer one can only be refused, and what is kept is enough to never match one
-- and as much as the refusal will ever quote.
compact ∷ Value → Value
compact = \case
  VBytes bytes → VBytes (ByteString.copy bytes)
  VText text → VText (Text.copy text)
  VCapability held →
    VCapability held {capabilityTypeName = Text.copy (Text.take (maxNameLength + 1) (capabilityTypeName held))}
  VList items → VList (map compact items)
  VRecord entries → VRecord [(Text.copy name, compact item) | (name, item) ← entries]
  value → value
