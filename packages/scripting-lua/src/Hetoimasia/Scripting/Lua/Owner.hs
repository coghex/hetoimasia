-- | A Lua VM owned through a protected IO lifetime, from outside the package.
--
-- 'withVmOwner' is the whole of it: it constructs one VM over an explicit set
-- of standard libraries, loads the initial chunks inside the lifetime, hands the
-- body that VM and only that VM, and closes it on every exit. Where the bridge's
-- own 'Hetoimasia.Scripting.Lua.Bridge.closeVm' leaves closing to the caller,
-- here nothing but the lifetime closes the VM, and a client cannot forget to.
--
-- = Library profiles
--
-- 'vmLibraries' is an explicit list. 'vmLibraryProfile' selects a named surface
-- instead ('vmProfileConfig'); 'LibraryProfileM1' is the filtered surface of the
-- M1 application's owners, either role: base, string, table, math and coroutine
-- without @load@, @loadfile@, @dofile@, @collectgarbage@, @string.dump@,
-- @math.random@ and @math.randomseed@, and no @os@, @io@, @package@, @require@ or
-- @debug@. It is installed during protected construction, after the libraries
-- open and before the bindings, the initial chunks and the modules, so the first
-- authored code already sees the filtered surface. A profile owns the owner's
-- whole library set: selecting one together with an explicit list is refused at
-- construction with 'ProfileWithLibraries'. Owners that do not select a profile
-- are unchanged, and owners are independent whether they do or not. The package
-- README documents the exact surface.
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
-- = Export modules (opt-in)
--
-- Beside those, and replacing none of them, an owner can hold /export modules/:
-- source text under a stable identity ('ExportSource') whose chunk returns exactly
-- one plain table, which the VM keeps as it is, functions, tables and cycles
-- included, instead of copying it across the value boundary. They are evaluated at
-- initialization ('vmExports') or from the body ('evaluateExport'), once per
-- identity per VM, and asked for again with 'retrieveExport'. A failed identity
-- stays failed. 'captureBehavior' validates one field of an export table as a
-- behavior (init, update, shutdown and the two cadence fields), and holds its hook
-- functions, a fresh @self@ and a facade for one instance until 'releaseBehavior'
-- or the VM's close. None of this is a copy and none of it crosses to another VM;
-- the handles are values that name a slot of one VM, checked on every use. The
-- package README documents the contract.
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

    -- * Export modules
  , ExportIdentity (..)
  , ExportSource (..)
  , ExportLimits (..)
  , defaultExportLimits
  , maxExportIdentityBytes
  , ExportHandle
  , ExportOutcome (..)
  , evaluateExport
  , retrieveExport

    -- * The module loader (opt-in)
  , LoaderConfig (..)
  , loaderConfig
  , SourceSupplier (..)
  , SourceAnswer (..)
  , ImportContext (..)
  , ResolvedAddress (..)
  , AddressResolver
  , ModulePhase
  , newModulePhase
  , modulePhaseActive
  , RootRequest (..)
  , RootAdmission (..)
  , RootRefusal (..)
  , SourceDelivery (..)
  , ModuleStatus (..)
  , Blocked (..)
  , AdvanceReport (..)
  , StopReport (..)
  , LoaderCounts (..)
  , admitRoot
  , deliverSource
  , advanceLoader
  , lookupModule
  , stopModuleLoader
  , moduleLoaderCounts

    -- * Captured behaviors
  , FacadeSource (..)
  , Hook (..)
  , CaptureHandle
  , Captured (..)
  , BehaviorShape (..)
  , CadenceField (..)
  , BehaviorProblem (..)
  , captureBehavior
  , releaseBehavior

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
  , ExportShape (..)
  , TaskEnd (..)
  , TaskProblem (..)
  , SuspendRefusal (..)

    -- * Running Lua
  , evalOwned
  , callOwned

    -- * Standard libraries
  , Library (..)
  , LibraryProfile (..)
  , profileLibraries
  , vmProfileConfig

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
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Scripting.Lua.Internal.Boundary
  ( BoundaryFault (..)
  , Effect (..)
  , FaultOperation (..)
  , ExportShape (..)
  , FaultReason (..)
  , ModuleProblem (..)
  , ModuleRef (..)
  , SuspendRefusal (..)
  , TaskEnd (..)
  , TaskProblem (..)
  , blankFault
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
  , luaComponent
  )
import qualified Hetoimasia.Scripting.Lua.Internal.Export as Export
import qualified Hetoimasia.Scripting.Lua.Internal.Loader as Loader
import Hetoimasia.Scripting.Lua.Internal.LoaderTypes
  ( AddressResolver
  , AdvanceReport (..)
  , Blocked (..)
  , ImportContext (..)
  , LoaderConfig (..)
  , LoaderCounts (..)
  , ModulePhase
  , ModuleStatus (..)
  , ResolvedAddress (..)
  , RootAdmission (..)
  , RootRefusal (..)
  , RootRequest (..)
  , SourceAnswer (..)
  , SourceDelivery (..)
  , SourceSupplier (..)
  , StopReport (..)
  , loaderConfig
  , modulePhaseActive
  , newModulePhase
  )
import Hetoimasia.Scripting.Lua.Internal.ExportTypes
  ( BehaviorProblem (..)
  , BehaviorShape (..)
  , CadenceField (..)
  , CaptureHandle
  , Captured (..)
  , ExportHandle
  , ExportIdentity (..)
  , FacadeSource (..)
  , ExportLimits (..)
  , ExportOutcome (..)
  , ExportSource (..)
  , Hook (..)
  , defaultExportLimits
  , maxExportIdentityBytes
  )
import Hetoimasia.Scripting.Lua.Internal.Library (Library (..), LibraryProfile (..), profileLibraries)
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
      , ownerExportLimits
      , ownerExports
      , ownerLoader
      , ownerModules
      , ownerName
      , ownerProfile
      , ownerRegistration
      , ownerRequests
      )
  , callOwned
  , defaultOwnerConfig
  , evalOwned
  , ownedHost
  , ownedLoader
  , withOwnedVm
  )
import Hetoimasia.Scripting.Lua.Internal.Registration (LifecycleContext, Registration, RequestContext, emptyRegistration)
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
    -- to open all of them at once, and the empty list opens none. Must be empty
    -- when 'vmLibraryProfile' is set.
  , vmLibraryProfile ∷ Maybe LibraryProfile
    -- ^ A library profile in place of an explicit list. 'Nothing', the default of
    -- 'vmConfig', opens exactly 'vmLibraries'. A profile owns the owner's whole
    -- standard-library set, so selecting one together with a non-empty
    -- 'vmLibraries' is refused at construction, before any authored code runs,
    -- with a 'BoundaryFault' of reason 'ProfileWithLibraries'. See
    -- 'vmProfileConfig'.
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
  , vmExports ∷ [ExportSource]
    -- ^ Export modules evaluated inside the lifetime, in order, after the modules
    -- and before the body, and asked for with 'retrieveExport'. One that fails is a
    -- sticky failure of its identity and does not end the lifetime; a Haskell
    -- failure that reaches a callback while one runs does. Empty by default.
  , vmExportLimits ∷ ExportLimits
    -- ^ The source and identity ceilings export modules are held to, from the
    -- application's profile: 'defaultExportLimits' is one mebibyte of source and
    -- 256 identities. A limit of zero refuses every new identity or every source.
  , vmRequests ∷ Maybe RequestContext
    -- ^ What delivers this owner's asynchronous native requests
    -- ('asynchronousNativeRequestIn') and a wait for one's settlement: an opaque
    -- value of the application's runtime, which this library never reads. 'Nothing',
    -- the default, leaves both answering a typed 'NotYetSupported' fault whose action
    -- never runs.
  , vmLoader ∷ Maybe LoaderConfig
    -- ^ The owner's module loader: ordered import chains whose modules can @import@
    -- and suspend on a dependency's verified source. 'Nothing', the default, gives an
    -- owner none, and an export module evaluated by 'evaluateExport' has no @import@.
    -- The loader's seams are the application's own: where source comes from, how an
    -- import's path and root become an identity, and when a root may begin.
  }

-- | A configuration over these libraries with no initial chunk, an empty
-- registration, no exposed namespace, the default value limits and no module.
vmConfig ∷ [Library] → VmConfig
vmConfig libraries = VmConfig libraries Nothing [] "owner" emptyRegistration [] defaultValueLimits [] Nothing [] defaultExportLimits Nothing Nothing

-- | A configuration over a library profile, otherwise as 'vmConfig' makes it.
--
-- The profile's libraries are opened and filtered during protected construction,
-- before the bindings, any initial chunk or any module, so the first authored
-- code already sees the filtered surface. A small client:
--
-- > withVmOwner (vmProfileConfig LibraryProfileM1) $ \owner →
-- >   evalOwned owner (chunkName "check") "assert(load == nil and os == nil and string.dump == nil)"
vmProfileConfig ∷ LibraryProfile → VmConfig
vmProfileConfig profile = (vmConfig []) {vmLibraryProfile = Just profile}

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
      { ownerProfile = vmLibraryProfile config
      , ownerChunks = vmInitialChunks config
      , ownerName = vmOwnerName config
      , ownerRegistration = vmRegistration config
      , ownerGranted = vmPolicy config
      , ownerLimits = vmValueLimits config
      , ownerModules = vmModules config
      , ownerCallbackScope = scope
      , ownerLifecycle = vmLifecycle config
      , ownerRequests = vmRequests config
      , ownerExports = vmExports config
      , ownerExportLimits = vmExportLimits config
      , ownerLoader = vmLoader config
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

-- | Evaluate an export module from the owner's body, or answer what its identity
-- already came to.
--
-- The chunk must return exactly one table with no metatable, which the VM keeps as
-- it is. What the identity came to is sticky: asking again answers the same table,
-- or the same failure, and runs nothing, however the second ask's bytes differ. An
-- identity that is empty or past 'maxExportIdentityBytes', and a new identity
-- while the owner holds as many as 'vmExportLimits' allows (failed and in-progress
-- ones included), are refused with 'NoEffect' and no record; source past the limit
-- is never compiled and is a failed identity that counts. The owner's thread only;
-- used by any other thread it is refused with 'VmNotOwned', and once the lifetime
-- has ended with 'VmClosed'.
evaluateExport ∷ HasCallStack ⇒ OwnedVm → ExportSource → IO ExportOutcome
evaluateExport owned = Export.evaluateExport (ownedHost owned)

-- | What an identity came to, without evaluating anything: 'Nothing' for an
-- identity the owner holds no record of. The same table, or the same failure, as
-- every earlier answer for it. The owner's thread only.
retrieveExport ∷ HasCallStack ⇒ OwnedVm → ExportIdentity → IO (Maybe ExportOutcome)
retrieveExport owned = Export.retrieveExport (ownedHost owned)

-- | Validate the field named by the text of the export table a handle names as a
-- behavior, and capture it with a facade.
--
-- The field must be a plain table whose only keys are @init@, @update@,
-- @shutdown@, @every_ticks@ and @every_seconds@, each hook absent or a function.
-- It is read by raw access, so no metamethod, indexing function or conversion
-- runs, and at most six of its entries are visited: nothing walks the library
-- exports around it. A behavior that does not fit is answered as a
-- 'BehaviorProblem' and holds nothing; a fault ('BoundaryFault') is a handle that
-- is not this owner's, a facade past the value limits, or an allocation that
-- failed, and holds nothing either. On success the capture holds the very hook
-- functions, a fresh @self@ table whose @api@ is the facade, and the facade, until
-- 'releaseBehavior' or the VM's close; later changes to the tables it was read
-- from do not reach it. The owner's thread only.
captureBehavior ∷ HasCallStack ⇒ OwnedVm → ExportHandle → Text → FacadeSource → IO (Either BehaviorProblem Captured)
captureBehavior owned = Export.captureBehavior (ownedHost owned)

-- | Let go of a capture. Idempotent; refused for a handle another owner issued.
-- The owner's thread only.
releaseBehavior ∷ HasCallStack ⇒ OwnedVm → CaptureHandle → IO ()
releaseBehavior owned = Export.releaseBehavior (ownedHost owned)

-- | The owner's loader, or the fault that it has none.
loaderOf ∷ HasCallStack ⇒ OwnedVm → IO Loader.Loader
loaderOf owned = case ownedLoader owned of
  Just loader → pure loader
  Nothing →
    throwFailure luaComponent (operation "module-loader") [] $
      (blankFault (Module.hostBoundary (ownedHost owned)) EvaluateExport (ModuleRefused NoModuleLoader))

-- | Ask the owner's loader to evaluate a root. See "Hetoimasia.Scripting.Lua.Internal.Loader"
-- for the loader's contract; the package README documents it. A new identity is
-- recorded as pending, its source asked for through the supplier and it is queued
-- after the roots already admitted. The owner's thread only.
admitRoot ∷ HasCallStack ⇒ OwnedVm → RootRequest → IO RootAdmission
admitRoot owned request = loaderOf owned >>= (`Loader.admitRoot` request)

-- | Deliver the verified source, or the failure, the supplier found for an identity
-- the loader asked about. It evaluates nothing: advance the loader. A delivery after the
-- loader has stopped, for an identity it holds no interest in, or a second one for an
-- identity, changes nothing. The owner's thread only.
deliverSource ∷ HasCallStack ⇒ OwnedVm → ExportIdentity → SourceAnswer → IO SourceDelivery
deliverSource owned identity answer = loaderOf owned >>= \loader → Loader.deliverSource loader identity answer

-- | Run the loader as far as it can go: start the next eligible root whose source has
-- arrived, evaluate dependencies depth first, resume importers with what they asked
-- for. It returns when the chain waits for a source, the head of the queue is not
-- eligible, or nothing is queued. The owner's thread only.
advanceLoader ∷ HasCallStack ⇒ OwnedVm → IO AdvanceReport
advanceLoader owned = loaderOf owned >>= Loader.advanceLoader

-- | What an identity is: its exports, its sticky failure, pending, evaluating,
-- stopped, or unknown. Evaluates nothing. The owner's thread only.
lookupModule ∷ HasCallStack ⇒ OwnedVm → ExportIdentity → IO ModuleStatus
lookupModule owned identity = loaderOf owned >>= \loader → Loader.lookupModule loader identity

-- | Stop the owner's loader: admission closes, every suspended module is closed on the
-- owner, every source interest is withdrawn and every identity that was pending or
-- evaluating reads 'ModuleStopped'. Terminal and idempotent; the lifetime does it too
-- before the VM closes. The owner's thread only.
stopModuleLoader ∷ HasCallStack ⇒ OwnedVm → IO StopReport
stopModuleLoader owned = loaderOf owned >>= Loader.stopLoader

-- | The loader's own bookkeeping: identities by state, the active chain's depth and
-- the source interests acquired, released and held.
moduleLoaderCounts ∷ HasCallStack ⇒ OwnedVm → IO LoaderCounts
moduleLoaderCounts owned = loaderOf owned >>= Loader.loaderCounts
