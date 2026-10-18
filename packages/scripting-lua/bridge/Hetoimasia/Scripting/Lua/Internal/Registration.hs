-- | What an application registers for its scripts to call, independent of any
-- VM.
--
-- A 'Registration' is plain data and closures: application-named namespaces,
-- each holding named bindings, and the capability types the application's
-- scripts may be handed. It is built once, validated when it is built, and can
-- then be given to any number of owners, each with a policy of its own naming
-- the namespaces it exposes (D-15). It names no concrete namespace of its own:
-- the application assembles what it permits (D-2, P-1).
--
-- = Bindings
--
-- A binding is defined once (D-14), with its kind (P-4), the schemas of its
-- arguments and of its results, and three eligibilities: the trusted direct
-- path, the confined path, and a Lua finalizer during a VM's shutdown. The
-- defaults are the safe ones. A binding is eligible for the direct path and for
-- nothing else, so registration exposes nothing to a mod, and a binding can be
-- made eligible for the confined path only when every schema it declares is a
-- plain bounded value: a capability is a handle into one VM and has no meaning
-- to a process that cannot hold it. A confined eligibility grants nothing by
-- itself: no grant exists in this slice, because the broker that would enforce
-- one (LUA-13) does not.
--
-- The kinds are those of P-4. A snapshot query and an owned state operation
-- answer values; a command or UI intention answers acceptance or a bounded
-- rejection as data; an asynchronous native request is accepted and classified by
-- the registration, and a call to one is refused by the owner as not yet supported
-- (decision A1). A lifecycle operation is classified too, and is refused the same
-- way by an owner that is not granted lifecycle services; an owner that is (LUA-23)
-- runs its action, handing it what the owner was configured with: the engine-owned
-- 'LifecycleContext', never anything the script supplied. The kind that starts
-- asynchronous work is never eligible to run from a finalizer (P-3).
--
-- A scheduler operation ('yieldOperation', 'waitOperation') is a binding that runs
-- no application code: it suspends the coroutine of the task that called it, and
-- the host reports to whatever resumed the task that it yielded, or what it waited
-- for and with which arguments. It is eligible for the direct path only. Where a
-- call to one cannot reach a scheduler it is refused as a typed fault of the call.
--
-- = Bounds
--
-- Every size a registration can have is bounded, and each bound is documented
-- here and pinned by tests at the bound and one past it: 64 namespaces, 256
-- bindings in one, 64 capability types, 16 arguments and 16 results to a
-- binding, schemas nested 8 deep with 64 fields to a record, and names of 1 to
-- 64 ASCII letters, digits and underscores, not starting with a digit.
module Hetoimasia.Scripting.Lua.Internal.Registration
  ( -- * Bindings
    Binding (..)
  , BindingKind (..)
  , Action (..)
  , WaitKind (..)
  , Suspend (..)
  , yieldOperation
  , waitOperation
  , isSuspending
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
  , confinedEligible
  , finalizerEligible
  , withoutDirectPath
  , commandReasonLimit
  , commandResults
    -- * Namespaces and capability types
  , Namespace (..)
  , namespace
  , CapabilityType (..)
  , capabilityType
    -- * The registration
  , Registration
  , registration
  , emptyRegistration
  , registrationNamespaces
  , registrationCapabilityTypes
  , RegistrationRefusal (..)
  , NameProblem (..)
  , NameKind (..)
    -- * Bounds
  , maxNamespaces
  , maxBindingsPerNamespace
  , maxCapabilityTypes
  , maxArity
  , maxSchemaDepth
  , maxRecordFields
  , maxNameLength
    -- * Eligibility
  , confinedEligibleBindings
  , directBindings
  , qualifiedName
    -- * Reading a registration
  , lookupNamespace
  , lookupCapability
  , capabilityNumber
  , capabilityNameOf
  , validName
  , standardGlobals
  , schemaProblem
  ) where

import Control.Monad (unless, when)
import Data.Char (isAscii, isAsciiLower, isAsciiUpper, isDigit)
import Data.Dynamic (Dynamic, fromDynamic, toDyn)
import Data.Typeable (Typeable)
import Data.List (find, nub)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Hetoimasia.Scripting.Lua.Internal.Value
  ( Schema (..)
  , Value
  , schemaCapabilities
  , schemaDepth
  , schemaDuplicateField
  , schemaFieldCount
  )

-- | The classification of a binding (P-4).
data BindingKind
  = SnapshotQuery
  | OwnedStateOperation
  | CommandOrUiIntention
  | AsynchronousNativeRequest
  | LifecycleOperation
  | -- | A yield or a wait a task's code makes to give control back to whatever
    -- resumes it. Delivered on the direct path only.
    SchedulerOperation
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | What a task's code waits for.
--
-- The host reports the request and its arguments and interprets neither: what a
-- deadline or a tick is, and when one is reached, belong to the scheduler that
-- resumes the task.
data WaitKind
  = -- | An elapsed deadline.
    WaitElapsed
  | -- | A logical tick.
    WaitLogical
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | What a scheduler operation does when a task calls it.
data Suspend
  = -- | Give control back, with nothing to wait for.
    SuspendYield
  | -- | Give control back, naming what to wait for.
    SuspendWait !WaitKind
  deriving (Eq, Show)

-- | How a command or UI intention answers: acceptance, or a bounded rejection.
data CommandResult
  = Accepted
  | -- | A rejection and its reason, at most 'commandReasonLimit' bytes of UTF-8.
    Rejected !Text
  deriving (Eq, Show)

-- | The most a rejection's reason may be, in bytes of UTF-8.
commandReasonLimit ∷ Int
commandReasonLimit = 256

-- | What a command or UI intention hands Lua: whether it was accepted, and the
-- reason it was not.
commandResults ∷ [Schema]
commandResults = [SBoolean, SOptional SText]

-- | What a binding runs.
data Action
  = -- | A snapshot query or an owned state operation: values in, values out.
    ValuesAction ([Value] → IO [Value])
  | CommandAction ([Value] → IO CommandResult)
  | -- | A kind this slice classifies and does not deliver. The action is kept
    -- for the slice that will, and is never run: a Lua call to the binding is
    -- refused as not yet supported before anything else happens.
    ReservedAction ([Value] → IO [Value])
  | -- | A lifecycle operation: refused as not yet supported, and never run, by an
    -- owner configured with no 'LifecycleContext'; run, with the owner's own
    -- context, by one that has it.
    LifecycleAction (LifecycleContext → [Value] → IO [Value])
  | -- | A scheduler operation: no application code runs. The task's coroutine is
    -- suspended and the host is told which operation did it, with the arguments
    -- it was given.
    SuspendAction !Suspend

-- | One binding.
data Binding = Binding
  { bindingName ∷ !Text
  , bindingKind ∷ !BindingKind
  , bindingArguments ∷ ![Schema]
  , bindingResults ∷ ![Schema]
  , bindingDirect ∷ !Bool
    -- ^ Eligible for the trusted direct path. The default.
  , bindingConfined ∷ !Bool
    -- ^ Eligible for the confined path. Never the default, and a grant of
    -- nothing by itself.
  , bindingFinalizer ∷ !Bool
    -- ^ Eligible to run when a Lua finalizer reaches it during the VM's close.
  , bindingAction ∷ Action
  }

-- | A snapshot query: reads a view and answers values.
snapshotQuery ∷ Text → [Schema] → [Schema] → ([Value] → IO [Value]) → Binding
snapshotQuery name arguments results action =
  Binding name SnapshotQuery arguments results True False False (ValuesAction action)

-- | An owned state operation: mutates only the domain's documented state.
stateOperation ∷ Text → [Schema] → [Schema] → ([Value] → IO [Value]) → Binding
stateOperation name arguments results action =
  Binding name OwnedStateOperation arguments results True False False (ValuesAction action)

-- | A command or UI intention: validates and admits, and answers acceptance or a
-- bounded rejection ('commandResults').
commandIntention ∷ Text → [Schema] → ([Value] → IO CommandResult) → Binding
commandIntention name arguments action =
  Binding name CommandOrUiIntention arguments commandResults True False False (CommandAction action)

-- | An asynchronous native request: accepted and classified; a Lua call to it is
-- refused as not yet supported, and the action is never run.
asynchronousNativeRequest ∷ Text → [Schema] → [Schema] → ([Value] → IO [Value]) → Binding
asynchronousNativeRequest name arguments results action =
  Binding name AsynchronousNativeRequest arguments results True False False (ReservedAction action)

-- | A lifecycle operation: accepted and classified. A Lua call to it is refused as
-- not yet supported, and the action never runs, from an owner that was configured
-- with no 'LifecycleContext'; from one that was, the action runs, as a values
-- action does. The action is shared by every owner that registers it, so it learns
-- who is calling from 'lifecycleOperationIn' and not from anything here.
lifecycleOperation ∷ Text → [Schema] → [Schema] → ([Value] → IO [Value]) → Binding
lifecycleOperation name arguments results action = lifecycleOperationIn name arguments results (const action)

-- | A lifecycle operation whose action is handed the 'LifecycleContext' of the owner
-- whose script called it. The context is the owner's own, set when the owner was
-- made and read here by the engine, never taken from a value the script supplied:
-- one registration, shared by owners with different grants, tells them apart by
-- it. Otherwise as 'lifecycleOperation'.
lifecycleOperationIn ∷ Text → [Schema] → [Schema] → (LifecycleContext → [Value] → IO [Value]) → Binding
lifecycleOperationIn name arguments results action =
  Binding name LifecycleOperation arguments results True False False (LifecycleAction action)

-- | What an owner is configured with so that its lifecycle operations are
-- delivered: an opaque value of the application's runtime, which this host library
-- never reads. An owner that has none refuses a lifecycle operation as not yet
-- supported. A client of this library can read one back only as the type it was
-- made from ('fromLifecycleContext').
newtype LifecycleContext = LifecycleContext Dynamic

instance Show LifecycleContext where
  show _ = "<lifecycle context>"

-- | A context holding this value.
lifecycleContext ∷ Typeable a ⇒ a → LifecycleContext
lifecycleContext = LifecycleContext . toDyn

-- | The value a context holds, if it is of this type.
fromLifecycleContext ∷ Typeable a ⇒ LifecycleContext → Maybe a
fromLifecycleContext (LifecycleContext held) = fromDynamic held

-- | A yield: control goes back to whatever resumes the task, which resumes it
-- later. It takes no arguments and answers none.
--
-- Called anywhere that cannot reach a scheduler -- an entry point called once, a
-- module's chunk, a finalizer, a coroutine the script created, a metamethod -- it
-- is refused as a typed fault of the call, never run. It is eligible for the
-- trusted direct path only, and never for the confined path.
yieldOperation ∷ Text → Binding
yieldOperation name =
  Binding name SchedulerOperation [] [] True False False (SuspendAction SuspendYield)

-- | A wait: control goes back with the wait the script asked for and its
-- arguments, which the schemas bound like any other call's. The host reports
-- them and waits for nothing itself. Refused wherever a yield is.
waitOperation ∷ Text → WaitKind → [Schema] → Binding
waitOperation name kind arguments =
  Binding name SchedulerOperation arguments [] True False False (SuspendAction (SuspendWait kind))

-- | Whether a binding is a scheduler operation, which suspends the coroutine it
-- is called from.
isSuspending ∷ Binding → Bool
isSuspending binding = case bindingAction binding of
  SuspendAction _ → True
  _ → False

-- | Declare the binding eligible for the confined path. Refused when the
-- registration is built if any schema it declares is not a bounded copied value.
confinedEligible ∷ Binding → Binding
confinedEligible binding = binding {bindingConfined = True}

-- | Declare the binding eligible to run from a Lua finalizer during the close.
-- Refused when the registration is built for the kind that starts asynchronous
-- work.
finalizerEligible ∷ Binding → Binding
finalizerEligible binding = binding {bindingFinalizer = True}

-- | Take the binding off the trusted direct path: no owner installs it there.
withoutDirectPath ∷ Binding → Binding
withoutDirectPath binding = binding {bindingDirect = False}

-- | A named group of bindings, which becomes one global table of an owner that
-- is granted it.
data Namespace = Namespace
  { namespaceName ∷ !Text
  , namespaceBindings ∷ ![Binding]
  }

-- | A namespace of these bindings.
namespace ∷ Text → [Binding] → Namespace
namespace = Namespace

-- | A kind of capability the application hands its scripts, and how it asks
-- whether one is still live. The check runs on every use, before the action of
-- the binding that received the capability, with the key the capability
-- carries; a generation or a session is what it would compare.
data CapabilityType = CapabilityType
  { capabilityName ∷ !Text
  , capabilityLive ∷ Word64 → IO Bool
  }

-- | A capability type, named, with its liveness check.
capabilityType ∷ Text → (Word64 → IO Bool) → CapabilityType
capabilityType = CapabilityType

-- | A validated registration. It can only be had from 'registration'.
data Registration = Registration
  { registrationNamespaces ∷ ![Namespace]
  , registrationCapabilityTypes ∷ ![CapabilityType]
  }

-- | A registration shows the names it holds and nothing else: its actions are
-- closures, which have no representation.
instance Show Registration where
  show reg =
    "Registration "
      <> show
        [ (namespaceName space, map bindingName (namespaceBindings space))
        | space ← registrationNamespaces reg
        ]
      <> " "
      <> show (map capabilityName (registrationCapabilityTypes reg))

-- | A registration with nothing in it.
emptyRegistration ∷ Registration
emptyRegistration = Registration [] []

-- | What kind of name was refused.
data NameKind = NamespaceName | BindingName | CapabilityTypeName
  deriving (Eq, Show)

-- | What is wrong with a name.
data NameProblem
  = NameEmpty
  | NameTooLong !Int
  | -- | A character that is not an ASCII letter, digit or underscore, or a digit
    -- first.
    NameBadCharacter
  | -- | A Lua keyword.
    NameReserved
  | -- | A namespace that would shadow a global the standard libraries define.
    NameShadowsStandardLibrary
  deriving (Eq, Show)

-- | Why a registration was refused.
data RegistrationRefusal
  = InvalidName !NameKind !Text !NameProblem
  | DuplicateNamespace !Text
  | DuplicateBinding !Text !Text
  | DuplicateCapabilityType !Text
  | -- | More of a kind than the bound allows: what, how many, the bound.
    TooManyNamespaces !Int !Int
  | -- | A namespace with too many bindings: its name, how many, the bound.
    TooManyBindings !Text !Int !Int
  | TooManyCapabilityTypes !Int !Int
  | -- | A binding declares more arguments or results than the bound: the
    -- binding, which, how many, the bound.
    ArityTooLarge !Text !Text !Int !Int
  | -- | A schema nests deeper than the bound: the binding, the depth, the bound.
    SchemaTooDeep !Text !Int !Int
  | SchemaTooWide !Text !Int !Int
  | -- | A record declares a field twice: the binding, the field.
    SchemaDuplicateField !Text !Text
  | -- | A schema names a capability type the registration does not declare: the
    -- binding, the type.
    UnknownCapabilityType !Text !Text
  | -- | A confined eligibility on a binding whose schemas are not all plain
    -- bounded values: the binding.
    ConfinedNeedsPlainValues !Text
  | -- | A confined eligibility on a scheduler operation: a coroutine of the
    -- trusted path has no meaning to a process that cannot hold it.
    SchedulerNotConfined !Text
  | -- | A finalizer eligibility on a binding that starts asynchronous work.
    FinalizerCannotStartWork !Text
  | -- | A command or UI intention is declared with results other than the fixed
    -- ones; cannot arise from the constructors, kept so a built value is checked.
    CommandResultsFixed !Text
  deriving (Eq, Show)

maxNamespaces, maxBindingsPerNamespace, maxCapabilityTypes, maxArity, maxSchemaDepth, maxRecordFields, maxNameLength ∷ Int
maxNamespaces = 64
maxBindingsPerNamespace = 256
maxCapabilityTypes = 64
maxArity = 16
maxSchemaDepth = 8
maxRecordFields = 64
maxNameLength = 64

-- | The globals the standard libraries define, none of which a namespace may
-- take the name of, whichever libraries a particular owner opens.
standardGlobals ∷ [Text]
standardGlobals =
  [ "_G"
  , "_VERSION"
  , "assert"
  , "collectgarbage"
  , "coroutine"
  , "debug"
  , "dofile"
  , "error"
  , "getmetatable"
  , "io"
  , "ipairs"
  , "load"
  , "loadfile"
  , "math"
  , "next"
  , "os"
  , "package"
  , "pairs"
  , "pcall"
  , "print"
  , "rawequal"
  , "rawget"
  , "rawlen"
  , "rawset"
  , "require"
  , "select"
  , "setmetatable"
  , "string"
  , "table"
  , "tonumber"
  , "tostring"
  , "type"
  , "utf8"
  , "warn"
  , "xpcall"
  ]

luaKeywords ∷ [Text]
luaKeywords =
  [ "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if"
  , "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"
  ]

-- | What is wrong with a name, if anything.
validName ∷ Text → Maybe NameProblem
validName name
  | Text.null name = Just NameEmpty
  | Text.length name > maxNameLength = Just (NameTooLong (Text.length name))
  | not (Text.all identifierCharacter name) || isDigit (Text.head name) = Just NameBadCharacter
  | name `elem` luaKeywords = Just NameReserved
  | otherwise = Nothing
  where
    identifierCharacter character = isAscii character && (isAsciiLower character || isAsciiUpper character || isDigit character || character == '_')

-- | Build a registration, refusing it for the first thing wrong with it.
--
-- Refused: an invalid or duplicate name; a namespace that would shadow a
-- standard-library global; a bound passed; a schema too deep or wide, or naming
-- a capability type that is not declared; a confined eligibility on a binding
-- whose schemas carry a capability; a finalizer eligibility on the kind that
-- starts asynchronous work.
registration ∷ [CapabilityType] → [Namespace] → Either RegistrationRefusal Registration
registration capabilities namespaces = do
  when (length capabilities > maxCapabilityTypes) $
    Left (TooManyCapabilityTypes (length capabilities) maxCapabilityTypes)
  when (length namespaces > maxNamespaces) $
    Left (TooManyNamespaces (length namespaces) maxNamespaces)
  mapM_ (\capability → named CapabilityTypeName (capabilityName capability)) capabilities
  case [name | name ← nub names, length (filter (== name) names) > 1] of
    name : _ → Left (DuplicateCapabilityType name)
    [] → Right ()
  mapM_ checkNamespace namespaces
  case [name | name ← nub spaces, length (filter (== name) spaces) > 1] of
    name : _ → Left (DuplicateNamespace name)
    [] → Right ()
  Right (Registration namespaces capabilities)
  where
    names = map capabilityName capabilities
    spaces = map namespaceName namespaces
    named kind name = case validName name of
      Just problem → Left (InvalidName kind name problem)
      Nothing → Right ()
    checkNamespace space = do
      named NamespaceName (namespaceName space)
      when (namespaceName space `elem` standardGlobals) $
        Left (InvalidName NamespaceName (namespaceName space) NameShadowsStandardLibrary)
      when (length (namespaceBindings space) > maxBindingsPerNamespace) $
        Left (TooManyBindings (namespaceName space) (length (namespaceBindings space)) maxBindingsPerNamespace)
      mapM_ (checkBinding space) (namespaceBindings space)
      let bindingNames = map bindingName (namespaceBindings space)
      case [name | name ← nub bindingNames, length (filter (== name) bindingNames) > 1] of
        name : _ → Left (DuplicateBinding (namespaceName space) name)
        [] → Right ()
    checkBinding space binding = do
      let qualified = qualifiedName (namespaceName space) (bindingName binding)
      named BindingName (bindingName binding)
      when (length (bindingArguments binding) > maxArity) $
        Left (ArityTooLarge qualified "arguments" (length (bindingArguments binding)) maxArity)
      when (length (bindingResults binding) > maxArity) $
        Left (ArityTooLarge qualified "results" (length (bindingResults binding)) maxArity)
      let schemas = bindingArguments binding <> bindingResults binding
      mapM_ (checkSchema qualified) schemas
      when (bindingConfined binding && any (not . null . schemaCapabilities) schemas) $
        Left (ConfinedNeedsPlainValues qualified)
      when (bindingConfined binding && bindingKind binding == SchedulerOperation) $
        Left (SchedulerNotConfined qualified)
      when (bindingFinalizer binding && bindingKind binding == AsynchronousNativeRequest) $
        Left (FinalizerCannotStartWork qualified)
      when (bindingKind binding == CommandOrUiIntention && bindingResults binding /= commandResults) $
        Left (CommandResultsFixed qualified)
    checkSchema qualified schema = do
      when (schemaDepth schema > maxSchemaDepth) $
        Left (SchemaTooDeep qualified (schemaDepth schema) maxSchemaDepth)
      when (schemaFieldCount schema > maxRecordFields) $
        Left (SchemaTooWide qualified (schemaFieldCount schema) maxRecordFields)
      case schemaDuplicateField schema of
        Just field → Left (SchemaDuplicateField qualified field)
        Nothing → Right ()
      mapM_
        (\capability → unless (capability `elem` names) (Left (UnknownCapabilityType qualified capability)))
        (schemaCapabilities schema)

-- | What is wrong with a schema a module's entry point declares, against this
-- registration's capability types, if anything: nested too deep, a record too
-- wide, a field declared twice, a capability type the registration does not
-- declare.
schemaProblem ∷ Registration → Schema → Maybe Text
schemaProblem reg schema
  | schemaDepth schema > maxSchemaDepth = Just "the schema nests too deep"
  | schemaFieldCount schema > maxRecordFields = Just "a record declares too many fields"
  | Just field ← schemaDuplicateField schema = Just ("the record field " <> field <> " is declared twice")
  | (unknown : _) ← [name | name ← schemaCapabilities schema, name `notElem` map capabilityName (registrationCapabilityTypes reg)] =
      Just ("the capability type " <> unknown <> " is not declared")
  | otherwise = Nothing

-- | @namespace.binding@: how a binding is named in diagnostics, and how the
-- finalizer allowlist names it.
qualifiedName ∷ Text → Text → Text
qualifiedName space name = space <> "." <> name

-- | A namespace of the registration, by name.
lookupNamespace ∷ Registration → Text → Maybe Namespace
lookupNamespace reg name = find ((== name) . namespaceName) (registrationNamespaces reg)

-- | A capability type of the registration, by name.
lookupCapability ∷ Registration → Text → Maybe CapabilityType
lookupCapability reg name = find ((== name) . capabilityName) (registrationCapabilityTypes reg)

-- | The number a capability type is given in a handle: its place in the
-- registration.
capabilityNumber ∷ Registration → Text → Maybe Word32
capabilityNumber reg name =
  fromIntegral <$> lookup name (zip (map capabilityName (registrationCapabilityTypes reg)) [0 ∷ Int ..])

-- | The capability type a handle's number stands for.
capabilityNameOf ∷ Registration → Word32 → Maybe Text
capabilityNameOf reg number = case drop (fromIntegral number) (registrationCapabilityTypes reg) of
  capability : _ → Just (capabilityName capability)
  [] → Nothing

-- | The bindings declared eligible for the confined path, by namespace and name.
-- Nothing here exposes one: eligibility grants nothing, and no grant exists yet.
confinedEligibleBindings ∷ Registration → [(Text, Text)]
confinedEligibleBindings reg =
  [ (namespaceName space, bindingName binding)
  | space ← registrationNamespaces reg
  , binding ← namespaceBindings space
  , bindingConfined binding
  ]

-- | The bindings of one namespace that are eligible for the trusted direct path.
directBindings ∷ Namespace → [Binding]
directBindings = filter bindingDirect . namespaceBindings
