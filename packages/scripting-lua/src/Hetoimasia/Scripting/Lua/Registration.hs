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
-- intention, an asynchronous native request and a lifecycle operation. The first
-- three are delivered on the direct path. A command or UI intention answers
-- acceptance, or a bounded rejection, as data: two values, a boolean and the
-- reason text or nil. The last two are accepted and classified here, and a Lua
-- call to one is a typed 'Hetoimasia.Scripting.Lua.Owner.NotYetSupported' fault
-- whose action never runs. The asynchronous kind can never be eligible to run
-- from a Lua finalizer during a VM's close.
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

import Hetoimasia.Scripting.Lua.Internal.Registration
