-- | A Lua VM owned through a protected IO lifetime, from outside the package.
--
-- 'withVmOwner' is the whole of it: it constructs one VM over an explicit set
-- of standard libraries, loads the initial chunks inside the lifetime, hands the
-- body that VM and only that VM, and closes it on every exit. Where the bridge's
-- own 'Hetoimasia.Scripting.Lua.Bridge.closeVm' leaves closing to the caller,
-- here nothing but the lifetime closes the VM, and a client cannot forget to.
--
-- = One owner per VM
--
-- The VM belongs to the thread that runs the lifetime, its execution owner.
-- Only that thread may run Lua on it, and the body's 'OwnedVm' offers no way to
-- close it, hand it to another owner or adopt it elsewhere: it is not the
-- bridge's @Vm@, so the bridge's operations do not accept it. A reference that
-- escapes the body, or reaches another thread, is refused rather than used: by
-- 'VmNotOwned' from any other thread while the VM is open, and by 'VmClosed'
-- from every thread once the lifetime has ended. A refused use runs no Lua and
-- changes nothing, and its rightful owner goes on using the VM.
--
-- = Any number of owners
--
-- Owners are independent. Any number may be live at once, created and closed in
-- any order, on any threads: none shares a VM, a Lua global state, a registry or
-- a callback table with another, and closing, failing or cancelling one leaves
-- every other one usable with its state and evidence untouched. There is no pool
-- and no scheduler across them; each is a thread running its own lifetime.
--
-- = How a lifetime ends
--
-- The outcome keeps the primary failure's type, value and context, and retains
-- every failure of the close as cleanup evidence that
-- 'Hetoimasia.Foundation.Resource.cleanupFailures' and
-- 'Hetoimasia.Foundation.Resource.cleanupFailuresInContext' read back, which is
-- what a supervisor reads: a cleanup failure stays cleanup, including when a
-- cancellation is the primary failure, and is never raised as a new script
-- error. A construction failure, partway through initialization, closes the VM
-- that was made through the same close before it is raised.
--
-- | Exit                         | Raised                                               |
-- |------------------------------|------------------------------------------------------|
-- | body returns, close succeeds | the body's result                                    |
-- | body fails                   | the body's failure, close failures retained          |
-- | construction fails           | that failure, close failures retained                |
-- | cancellation, any point      | the cancellation, after the VM is closed, close      |
-- |                              | failures retained                                    |
-- | body returns, close fails    | the first close failure, all retained                |
--
-- = Cancellation
--
-- A cancellation is never delivered inside a Lua call, so a thread inside Lua is
-- cancelled when the call returns. During initialization or the body it ends the
-- step and the VM is closed on the way out. During the close it waits: the close
-- cannot be interrupted, it never runs twice, and the dependencies Lua's
-- callbacks borrowed are released only once the state has closed. The owner
-- never detaches a VM it cannot finish closing; it waits for it as the thread
-- running a stuck finalizer does.
--
-- = Bindings, modules and values
--
-- An owner is configured with a 'Registration' the application built and a
-- policy naming the namespaces of it that this owner exposes ('vmPolicy'); every
-- other namespace is invisible to its scripts. The bindings are installed during
-- construction, before any initial chunk or module runs, and the set is fixed
-- for the VM's lifetime. A policy that names a namespace the registration does
-- not declare ends construction, like any other initialization failure.
--
-- Application-owned modules ('ModuleSource') are source the application
-- supplies under a name and version; the host reads nothing from disk. They load
-- at initialization ('vmModules') or from the body ('loadModule'), each in an
-- environment of its own, and are called through the entry points the
-- application declared ('callEntry'). Values cross as bounded copies; see
-- "Hetoimasia.Scripting.Lua.Value" for the rules and the limits.
--
-- = Faults across the boundary
--
-- A refusal of a value, a missing required entry point, a call to a binding of a
-- kind that is not yet delivered and a failed module load are 'BoundaryFault's:
-- ordinary Haskell exceptions that name the owner, the module and entry point or
-- the binding, the operation, the source chunk, a bounded traceback when one was
-- captured, a typed reason and an 'Effect'. A refusal made inside a binding call
-- is a fault of the call: the owner's operation raises it even when the script
-- caught Lua's side of it with @pcall@, so a script cannot hide it. 'Effect'
-- says whether anything had happened by then: 'NoEffect' for a refusal before any
-- Lua or binding action ran, 'LuaRan' once Lua had run, 'BindingRan' once a
-- binding's action had, which means application state may have been changed. A
-- fault never claims that recovery is safe. A Haskell failure raised by a
-- binding's action is not converted: it is re-raised at this boundary with its
-- own type and context.
--
-- = Shutdown
--
-- Before the state closes the owner closes admission: every operation asked of
-- the VM is refused. A callback Lua's finalizers reach runs only if the owner's
-- finalizer allowlist names it, and the allowlist is exactly the bindings of the
-- granted namespaces that the registration declares finalizer-eligible: none by
-- default. Any other binding reached from a finalizer is refused with
-- 'FinalizerRefused', the refusal is retained as cleanup evidence even if the
-- finalizer's script caught the error, and what is retained from finalizers is
-- bounded. A lifecycle binding on the allowlist still executes nothing: it is not
-- yet delivered.
--
-- = Around a callback
--
-- A binding's action runs on a thread of its own for each call. 'withVmOwnerScoped'
-- runs a 'CallbackScope' around each such callback, on the callback's own thread
-- and for exactly its duration, so an owner that holds something can lend it to a
-- callback and take it back whatever the callback does. The scope is handed a
-- 'CallbackSite', which answers whether a thread is one of this VM's callbacks
-- from the record the VM already keeps when it refuses an operation re-entered
-- from a callback, so no one has to take a callback's word for who it is. The
-- scope runs for every callback the VM runs, the initial chunks' and the modules'
-- included, and for a callback a finalizer reaches that the policy lets run. It
-- changes no rule of this module, and 'withVmOwner' is the same lifetime with no
-- scope.
module Hetoimasia.Scripting.Lua.Owner
  ( -- * The lifetime
    VmConfig (..)
  , vmConfig
  , withVmOwner
  , withVmOwnerScoped
  , OwnedVm

    -- * Around a callback
  , CallbackScope (..)
  , CallbackSite (..)
  , noCallbackScope

    -- * Application-owned modules
  , ModuleSource (..)
  , ModuleRef (..)
  , EntryPoint (..)
  , Requirement (..)
  , ModuleHandle
  , CallResult (..)
  , loadModule
  , loadedModule
  , callEntry
  , maxModules
  , maxSourceBytes
  , maxEntries
  , maxIdentityLength

    -- * Tasks
  , Task
  , TaskStart (..)
  , TaskStep (..)
  , WaitRequest (..)
  , startTask
  , resumeTask
  , closeTask

    -- * Faults across the boundary
  , BoundaryFault (..)
  , FaultOperation (..)
  , FaultReason (..)
  , Effect (..)
  , ModuleProblem (..)
  , TaskEnd (..)
  , TaskProblem (..)
  , SuspendRefusal (..)

    -- * Running Lua
  , evalOwned
  , callOwned

    -- * Standard libraries
  , Library (..)

    -- * Chunk names
  , ChunkName
  , chunkName
  , chunkNameText

    -- * Failures
  , LuaFault (..)
  , FaultKind (..)
  , ErrorValue (..)
  , VmClosed (..)
  , VmReentered (..)
  , VmNotOwned (..)
  , FinalizerRefused (..)
  , FinalizerEvidenceTruncated (..)
  , CloseFault (..)
  , CloseFailure (..)
  , CloseSource (..)
  , closeSourceLabel
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import GHC.Stack (HasCallStack)
import Hetoimasia.Scripting.Lua.Internal.Boundary
  ( BoundaryFault (..)
  , Effect (..)
  , FaultOperation (..)
  , FaultReason (..)
  , ModuleProblem (..)
  , ModuleRef (..)
  , SuspendRefusal (..)
  , TaskEnd (..)
  , TaskProblem (..)
  )
import Hetoimasia.Scripting.Lua.Internal.Call (ChunkName, chunkName, chunkNameText)
import Hetoimasia.Scripting.Lua.Internal.Fault
  ( CloseFailure (..)
  , CloseFault (..)
  , CloseSource (..)
  , ErrorValue (..)
  , FaultKind (..)
  , FinalizerEvidenceTruncated (..)
  , FinalizerRefused (..)
  , LuaFault (..)
  , VmClosed (..)
  , VmNotOwned (..)
  , VmReentered (..)
  , closeSourceLabel
  )
import Hetoimasia.Scripting.Lua.Internal.Library (Library (..))
import Hetoimasia.Scripting.Lua.Internal.Module
  ( CallResult (..)
  , EntryPoint (..)
  , ModuleHandle
  , ModuleSource (..)
  , Requirement (..)
  , maxEntries
  , maxIdentityLength
  , maxModules
  , maxSourceBytes
  )
import qualified Hetoimasia.Scripting.Lua.Internal.Module as Module
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnedVm
  , OwnerConfig
      ( ownerCallbackScope
      , ownerChunks
      , ownerGranted
      , ownerLifecycle
      , ownerLimits
      , ownerModules
      , ownerName
      , ownerRegistration
      )
  , callOwned
  , defaultOwnerConfig
  , evalOwned
  , ownedHost
  , withOwnedVm
  )
import Hetoimasia.Scripting.Lua.Internal.Registration (LifecycleContext, Registration, emptyRegistration)
import Hetoimasia.Scripting.Lua.Internal.Task
  ( Task
  , TaskStart (..)
  , TaskStep (..)
  , WaitRequest (..)
  )
import qualified Hetoimasia.Scripting.Lua.Internal.Task as Task
import Hetoimasia.Scripting.Lua.Internal.Value (Value, ValueLimits, defaultValueLimits)
import Hetoimasia.Scripting.Lua.Internal.Vm (CallbackScope (..), CallbackSite (..), noCallbackScope)

-- | What a VM owner constructs.
data VmConfig = VmConfig
  { vmLibraries ∷ [Library]
    -- ^ Exactly the standard libraries the VM opens, in order. There is no way
    -- to open all of them at once, and the empty list opens none.
  , vmInitialChunks ∷ [(ChunkName, ByteString)]
    -- ^ The chunks loaded and run, in order, inside the lifetime and before the
    -- body: initialization. One that fails ends the lifetime with its failure,
    -- after closing the VM.
  , vmOwnerName ∷ Text
    -- ^ How this owner is named in a fault.
  , vmRegistration ∷ Registration
    -- ^ What the application registered. Shared by any number of owners.
  , vmPolicy ∷ [Text]
    -- ^ The namespaces of the registration this owner exposes. Only these are
    -- visible to its scripts.
  , vmValueLimits ∷ ValueLimits
    -- ^ The bounds on every value that crosses for this owner.
  , vmModules ∷ [ModuleSource]
    -- ^ Modules loaded inside the lifetime, in order, after the initial chunks
    -- and before the body. One that fails ends the lifetime with its fault, after
    -- closing the VM.
  , vmLifecycle ∷ Maybe LifecycleContext
    -- ^ What delivers this owner's lifecycle operations ('lifecycleOperationIn'):
    -- an opaque value of the application's runtime, which this library never
    -- reads. 'Nothing', the default, leaves a lifecycle operation answering a typed
    -- 'NotYetSupported' fault whose action never runs.
  }

-- | A configuration over these libraries with no initial chunk, an empty
-- registration, no exposed namespace, the default value limits and no module.
vmConfig ∷ [Library] → VmConfig
vmConfig libraries = VmConfig libraries [] "owner" emptyRegistration [] defaultValueLimits [] Nothing

-- | Run a body over a VM this owner constructs, and close the VM on every exit.
--
-- The VM is constructed, initialized and closed on the calling thread, which is
-- its execution owner for as long as the lifetime lasts. See the module header
-- for who may use it, how it ends and where a cancellation can land.
withVmOwner ∷ HasCallStack ⇒ VmConfig → (OwnedVm → IO r) → IO r
withVmOwner = withVmOwnerScoped noCallbackScope

-- | 'withVmOwner' with a scope run around each of the VM's callbacks. See
-- "Around a callback" in the module header, and 'CallbackScope' for what the scope
-- may and may not do.
withVmOwnerScoped ∷ HasCallStack ⇒ CallbackScope → VmConfig → (OwnedVm → IO r) → IO r
withVmOwnerScoped scope config =
  withOwnedVm
    (defaultOwnerConfig (vmLibraries config))
      { ownerChunks = vmInitialChunks config
      , ownerName = vmOwnerName config
      , ownerRegistration = vmRegistration config
      , ownerGranted = vmPolicy config
      , ownerLimits = vmValueLimits config
      , ownerModules = vmModules config
      , ownerCallbackScope = scope
      , ownerLifecycle = vmLifecycle config
      }

-- | Load a module from the owner's body, in an environment of its own.
--
-- Refused before anything runs, with 'NoEffect': an identity the owner already
-- holds (there is no live reload), an invalid identity or entry point, source or
-- entry points past their bounds. A required entry point the source does not
-- define as a function fails the load, naming module and entry. The owner's
-- thread only; used by any other thread it is refused with 'VmNotOwned', and
-- once the lifetime has ended with 'VmClosed'.
loadModule ∷ HasCallStack ⇒ OwnedVm → ModuleSource → IO ModuleHandle
loadModule owned = Module.loadModule (ownedHost owned)

-- | The handle of a module this owner has loaded, by identity: how the body gets
-- at a module supplied through 'vmModules', which loaded before the body ran.
-- 'Nothing' for an identity the owner has not loaded. The owner's thread only,
-- and refused with 'VmClosed' once the lifetime has ended.
loadedModule ∷ HasCallStack ⇒ OwnedVm → ModuleRef → IO (Maybe ModuleHandle)
loadedModule owned = Module.loadedModule (ownedHost owned)

-- | Call a module's entry point with bounded values.
--
-- The handle must be one this owner issued: a handle another owner issued is
-- refused with 'ModuleHandleForeign', and one used after its owner's lifetime
-- with 'VmClosed'. An optional entry point the module does not define answers
-- 'EntryAbsent' and runs nothing; a required one that is gone is a fault, and an
-- entry point that is present and is not a function is a fault in either case.
callEntry ∷ HasCallStack ⇒ OwnedVm → ModuleHandle → Text → [Value] → IO CallResult
callEntry owned = Module.callEntry (ownedHost owned)

-- | Run a module's entry point as a task: a Lua coroutine of this VM, up to its
-- first yield, wait or return.
--
-- The handle, the entry point and its arguments are checked exactly as
-- 'callEntry' checks them, and refused before anything runs with 'NoEffect'. An
-- optional entry point the module does not define answers 'TaskEntryAbsent' and
-- runs nothing. A failure of the first segment, a script error, a refused value,
-- an exhausted allocator or a binding's own failure, is raised exactly as
-- 'callEntry' raises it, and leaves no task behind. The owner's thread only.
--
-- The task is not a value: it names a coroutine of this VM, is refused by any
-- other owner, and is never something a script can be handed.
startTask ∷ HasCallStack ⇒ OwnedVm → ModuleHandle → Text → [Value] → IO TaskStart
startTask owned = Task.startTask (ownedHost owned)

-- | Run a suspended task's next segment, after the yield or wait it stopped at.
--
-- Each segment ends as 'startTask' does: with the entry point's results
-- ('Completed'), a yield ('Yielded'), or a wait ('Waiting'). A segment that fails
-- is raised, and the task is closed by the host, running its pending
-- to-be-closed variables, and cannot be resumed again. A task that has returned,
-- failed or been closed, and one another owner issued, is refused with a
-- 'TaskRefused' fault and 'NoEffect'.
resumeTask ∷ HasCallStack ⇒ OwnedVm → Task → IO TaskStep
resumeTask owned = Task.resumeTask (ownedHost owned)

-- | Close a suspended task, running its pending to-be-closed variables on the
-- owner's thread.
--
-- An error one of them raises is raised with the close, as a 'BoundaryFault'
-- whose reason is a script failure. Closing is terminal and idempotent: the task
-- is closed even if that failed, and closing a task that has ended does nothing.
closeTask ∷ HasCallStack ⇒ OwnedVm → Task → IO ()
closeTask owned = Task.closeTask (ownedHost owned)
