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
-- whose action never runs. The asynchronous kind can never be eligible to run
-- from a Lua finalizer during a VM's close.
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
  , lifecycleOperationIn
  , LifecycleContext
  , lifecycleContext
  , fromLifecycleContext
  , yieldOperation
  , waitOperation
  , WaitKind (..)
  , confinedEligible
  , finalizerEligible
  , withoutDirectPath
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
