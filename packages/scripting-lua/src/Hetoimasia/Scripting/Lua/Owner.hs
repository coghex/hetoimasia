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
module Hetoimasia.Scripting.Lua.Owner
  ( -- * The lifetime
    VmConfig (..)
  , vmConfig
  , withVmOwner
  , OwnedVm

    -- * Application-owned modules
  , ModuleSource (..)
  , ModuleRef (..)
  , EntryPoint (..)
  , Requirement (..)
  , ModuleHandle
  , CallResult (..)
  , loadModule
  , callEntry
  , maxModules
  , maxSourceBytes
  , maxEntries
  , maxIdentityLength

    -- * Faults across the boundary
  , BoundaryFault (..)
  , FaultOperation (..)
  , FaultReason (..)
  , Effect (..)
  , ModuleProblem (..)

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
      ( ownerChunks
      , ownerGranted
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
import Hetoimasia.Scripting.Lua.Internal.Registration (Registration, emptyRegistration)
import Hetoimasia.Scripting.Lua.Internal.Value (Value, ValueLimits, defaultValueLimits)

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
  }

-- | A configuration over these libraries with no initial chunk, an empty
-- registration, no exposed namespace, the default value limits and no module.
vmConfig ∷ [Library] → VmConfig
vmConfig libraries = VmConfig libraries [] "owner" emptyRegistration [] defaultValueLimits []

-- | Run a body over a VM this owner constructs, and close the VM on every exit.
--
-- The VM is constructed, initialized and closed on the calling thread, which is
-- its execution owner for as long as the lifetime lasts. See the module header
-- for who may use it, how it ends and where a cancellation can land.
withVmOwner ∷ HasCallStack ⇒ VmConfig → (OwnedVm → IO r) → IO r
withVmOwner config =
  withOwnedVm
    (defaultOwnerConfig (vmLibraries config))
      { ownerChunks = vmInitialChunks config
      , ownerName = vmOwnerName config
      , ownerRegistration = vmRegistration config
      , ownerGranted = vmPolicy config
      , ownerLimits = vmValueLimits config
      , ownerModules = vmModules config
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

-- | Call a module's entry point with bounded values.
--
-- The handle must be one this owner issued: a handle another owner issued is
-- refused with 'ModuleHandleForeign', and one used after its owner's lifetime
-- with 'VmClosed'. An optional entry point the module does not define answers
-- 'EntryAbsent' and runs nothing; a required one that is gone is a fault, and an
-- entry point that is present and is not a function is a fault in either case.
callEntry ∷ HasCallStack ⇒ OwnedVm → ModuleHandle → Text → [Value] → IO CallResult
callEntry owned = Module.callEntry (ownedHost owned)
