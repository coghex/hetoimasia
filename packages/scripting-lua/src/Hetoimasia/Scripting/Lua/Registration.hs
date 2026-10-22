-- | What an application registers for its scripts to call, independent of any
-- VM.
--
-- A 'Registration' holds application-named namespaces, each of named bindings,
-- and the capability types the application's scripts may be handed. It is built
-- once and validated when it is built; it can then be given to any number of
-- owners, each with a policy of its own naming the namespaces it exposes. This
-- package names no concrete namespace: the application assembles what it
-- permits.
--
-- = Bindings
--
-- A binding is defined once, with its kind, the schemas of its arguments and
-- its results, and three eligibilities. The defaults are the safe ones: a
-- binding is eligible for the trusted direct path and for nothing else, so a
-- registration exposes nothing to a mod, and eligibility for the confined path
-- is refused for a binding whose schemas are not all plain bounded values. A
-- confined eligibility grants nothing by itself: no grant exists in this
-- package, and a direct-only binding needs no confined equivalent.
--
-- The kinds are a snapshot query, an owned state operation, a command or UI
-- intention, an asynchronous native request, a lifecycle operation and a
-- scheduler operation. The first three are delivered on the direct path, and so
-- is the last. A command or UI intention answers
-- acceptance, or a bounded rejection, as data: two values, a boolean and the
-- reason text or nil. The last two are accepted and classified here, and a Lua
-- call to one is a typed 'Hetoimasia.Scripting.Lua.Owner.NotYetSupported' fault
-- whose action never runs. A lifecycle operation is delivered, and its action runs, only
-- for an owner configured with a 'LifecycleContext' (see 'lifecycleOperationIn'): the
-- application's runtime hands each owner its own, so one registration shared by owners
-- with different grants tells them apart, and an owner with none keeps the fault. An
-- asynchronous native request is delivered the same way, for an owner configured with a
-- 'RequestContext' (see 'asynchronousNativeRequestIn'), and so is a wait for a request's
-- settlement ('WaitSettlement'); an owner with none keeps the fault for both. The
-- asynchronous kind can never be eligible to run from a Lua finalizer during a VM's close,
-- and neither is a lifecycle operation delivered when a finalizer may call it.
--
-- = Releasing a handle
--
-- Every binding refuses a capability whose application check reports it retired,
-- before its action runs: using what has ended is a fault of the call. An explicit
-- release is the one operation that is run for such a handle, because answering
-- that it has ended is its job ('releaseOperation'). It is declared with the one
-- capability type it releases and takes that handle as its only argument, so what
-- reaches it is never any other value, and the handle is still checked for being
-- authentic: issued by the VM that is calling and of that type. A retired handle
-- given to any other binding, or a retired handle of any other type, is refused as
-- before.
--
-- = Scheduler operations
--
-- A task's code gives control back to whatever resumes it through a scheduler
-- operation: a yield ('yieldOperation'), or a wait for an elapsed deadline or a
-- logical tick ('waitOperation', 'WaitKind'). They are bindings like any other,
-- named by the application and granted by an owner's policy, so a script that is
-- not granted one has none; nothing about them is global. The host runs no
-- application code for one. It suspends the task's coroutine and reports to
-- whoever resumed it that the script yielded, or what it waited for with the
-- arguments it gave, checked against the schemas the operation declares and the
-- owner's limits. A wait's arguments mean whatever the application's scheduler
-- says; the host interprets none. A scheduler operation called anywhere it cannot
-- reach a scheduler is a typed fault of the call
-- ('Hetoimasia.Scripting.Lua.Owner.SuspendRefused'), and is never eligible for
-- the confined path.
--
-- = Recoverable refusals
--
-- A binding refuses a call before its action as a typed fault of the call, and a
-- script that catches the Lua error it saw cannot hide the fault: the operation that
-- ran the script raises it. 'recoverableRefusals' opts one binding out of that, and
-- 'withPrecondition' opts one out and gives it an application check made first. For an
-- opted-in binding the refusals the host makes before the action (a wrong number of
-- arguments, a value of the wrong shape or past a limit, a capability that is not the
-- declared one, foreign or no longer live) and a precondition's refusal reach the
-- script as an ordinary Lua error with a bounded message, @binding: reason@, of at most
-- 'refusalReasonLimit' bytes of reason. @pcall@ catches it, the invocation goes on and
-- can succeed, and the action never ran. A precondition reads engine-owned state, not a
-- script's: a context the owner was configured with ('OwnerContexts') or what the
-- application captured. Busy, a response that no work was admitted, is data the action
-- returns, @nil, {code = "busy", message = text}@ through a result schema, and never an
-- error.
--
-- Nothing else becomes recoverable: an application's failure, a refusal after the
-- action, the host's own failures, a precondition's exception, and a refusal reached
-- from a finalizer keep the typed fault they have. An error a script caught never
-- erases a fault already recorded. Bindings that are not opted in are unchanged.
--
-- = Names and bounds
--
-- A name is 1 to 64 ASCII letters, digits and underscores, not starting with a
-- digit and not a Lua keyword. A namespace may not take the name of a global the
-- standard libraries define ('standardGlobals'). A registration holds at most 64
-- namespaces, a namespace at most 256 bindings, a registration at most 64
-- capability types; a binding has at most 16 arguments and 16 results; a schema
-- nests at most 8 deep and a record has at most 64 fields. Each is pinned by
-- tests at the bound and one past it.
module Hetoimasia.Scripting.Lua.Registration
  ( -- * The registration
    Registration
  , registration
  , emptyRegistration
  , registrationNamespaces
  , registrationCapabilityTypes
  , RegistrationRefusal (..)
  , NameKind (..)
  , NameProblem (..)

    -- * Namespaces
  , Namespace
  , namespace
  , namespaceName
  , namespaceBindings

    -- * Bindings
  , Binding
  , BindingKind (..)
  , CommandResult (..)
  , snapshotQuery
  , stateOperation
  , commandIntention
  , asynchronousNativeRequest
  , lifecycleOperation
  , releaseOperation
  , lifecycleOperationIn
  , LifecycleContext
  , lifecycleContext
  , fromLifecycleContext
  , asynchronousNativeRequestIn
  , RequestContext
  , requestContext
  , fromRequestContext
  , yieldOperation
  , waitOperation
  , WaitKind (..)
  , confinedEligible
  , finalizerEligible
  , withoutDirectPath
  , recoverableRefusals
  , withPrecondition
  , Precondition
  , OwnerContexts (..)
  , refusalReasonLimit
  , bindingRecoverable
  , bindingName
  , bindingKind
  , bindingArguments
  , bindingResults
  , bindingDirect
  , bindingConfined
  , bindingFinalizer
  , commandResults
  , commandReasonLimit

    -- * Capability types
  , CapabilityType
  , capabilityType
  , capabilityName

    -- * What is eligible
  , confinedEligibleBindings
  , qualifiedName

    -- * Bounds and names
  , maxNamespaces
  , maxBindingsPerNamespace
  , maxCapabilityTypes
  , maxArity
  , maxSchemaDepth
  , maxRecordFields
  , maxNameLength
  , validName
  , standardGlobals
  ) where

import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Internal.Registration hiding
  ( bindingArguments
  , bindingConfined
  , bindingPreconditions
  , bindingRecoverable
  , bindingDirect
  , bindingFinalizer
  , bindingKind
  , bindingName
  , bindingResults
  , capabilityName
  , namespaceBindings
  , namespaceName
  , registrationCapabilityTypes
  , registrationNamespaces
  )
import qualified Hetoimasia.Scripting.Lua.Internal.Registration as Internal
import Hetoimasia.Scripting.Lua.Value (Schema)

-- The readings below are ordinary functions and not the record labels of the
-- types they read: a label that is exported can be used in a record update, and
-- an update would build a registration, a namespace or a binding that skipped
-- the validation 'registration' applies. Nothing here can be updated.

-- | The namespaces of a registration, in the order they were given.
registrationNamespaces ∷ Registration → [Namespace]
registrationNamespaces = Internal.registrationNamespaces

-- | The capability types of a registration, in the order they were given.
registrationCapabilityTypes ∷ Registration → [CapabilityType]
registrationCapabilityTypes = Internal.registrationCapabilityTypes

-- | A namespace's name.
namespaceName ∷ Namespace → Text
namespaceName = Internal.namespaceName

-- | A namespace's bindings.
namespaceBindings ∷ Namespace → [Binding]
namespaceBindings = Internal.namespaceBindings

-- | A capability type's name.
capabilityName ∷ CapabilityType → Text
capabilityName = Internal.capabilityName

-- | A binding's name.
bindingName ∷ Binding → Text
bindingName = Internal.bindingName

-- | A binding's kind.
bindingKind ∷ Binding → BindingKind
bindingKind = Internal.bindingKind

-- | The schemas of a binding's arguments.
bindingArguments ∷ Binding → [Schema]
bindingArguments = Internal.bindingArguments

-- | The schemas of a binding's results.
bindingResults ∷ Binding → [Schema]
bindingResults = Internal.bindingResults

-- | Whether the binding is eligible for the trusted direct path.
bindingDirect ∷ Binding → Bool
bindingDirect = Internal.bindingDirect

-- | Whether the binding is eligible for the confined path.
bindingConfined ∷ Binding → Bool
bindingConfined = Internal.bindingConfined

-- | Whether the binding is eligible to run from a Lua finalizer.
bindingFinalizer ∷ Binding → Bool
bindingFinalizer = Internal.bindingFinalizer

-- | Whether the binding is opted in to ordinary Lua errors for the refusals made
-- before its action ('recoverableRefusals', 'withPrecondition').
bindingRecoverable ∷ Binding → Bool
bindingRecoverable = Internal.bindingRecoverable
