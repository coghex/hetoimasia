-- | The VM owner: one Lua interpreter held through a protected IO lifetime.
--
-- 'withOwnedVm' is bracket-shaped and is deliberately not an ordinary
-- 'Hetoimasia.Foundation.Resource.withResource' release. An unrestricted
-- @lua_close@ runs every pending finalizer, and a finalizer is arbitrary Lua
-- that can call into Haskell, so a close can run for as long as foreign code
-- runs. A scope's release runs under @uninterruptibleMask_@ and assumes it
-- blocks for a controlled time; wiring a close into one would claim a bound
-- this close does not have. So the owner masks the close itself, runs it once,
-- and composes its failures with the primary one through the foundation's
-- public evidence seam ('Hetoimasia.Foundation.Resource.composeCleanup').
--
-- = The lifetime
--
-- The owner runs on one thread, the execution owner, which is the thread that
-- enters 'withOwnedVm'. In order:
--
-- 1. The interpreter and its control state are allocated, masked. A failure
--    here, an allocation failure, leaves nothing to close and nothing behind.
-- 2. Initialization runs with the caller's masking state restored: the
--    fixture hook, the standard libraries in order, the second hook, and the
--    initial chunks in order. A failure at any step ends initialization.
-- 3. The body runs, over the 'OwnedVm' only, unless initialization failed.
-- 4. The VM is closed, whatever the exits before it, through 'closeVm': it
--    enters its shutdown phase, admits no operation, runs Lua's finalizers
--    under the owner's finalizer allowlist, closes the state and only then
--    releases the callback dependencies it retained. Masked, once; a failure of
--    the close is collected, never retried.
-- 5. A cancellation that arrived while the owner was masked, which is any that
--    arrived during the close, is taken at one place, and the outcome is
--    composed.
--
-- A VM is never reachable half-constructed: the body does not run unless every
-- initialization step succeeded, and the VM that a failed step leaves is closed
-- through the same close before the failure is raised.
--
-- = Cancellation
--
-- Where a cancellation can land is established by what the bridge already
-- proves, not assumed. A thread inside a Lua call is not cancelled by an
-- asynchronous exception: the call is @safe@, and the exception waits for it to
-- return, which the hazard probes show with a thread that never dies while it
-- is inside Lua. Every bridge operation is masked and the exception lands at the
-- boundary after the call's bookkeeping. So a cancellation of the owner:
--
-- * before the lifetime begins lands outside it, with nothing constructed;
-- * during initialization or the body is delivered when the operation that was
--   inside Lua returns and the owner's restored masking state allows it, and it
--   ends that step; the owner then closes the VM, so nothing is left live;
-- * during the close is deferred. The close is masked, so it neither lands inside
--   the close nor stops it, and the dependencies are released only after
--   @lua_close@ returned; each release runs uninterruptibly, as a scope's does,
--   so a cancellation neither lands inside one nor is mistaken for its failure.
--   It is taken after the close, at the allowances below.
--
-- Repeated cancellation cannot abandon the VM or release anything early,
-- because nothing in the close can be interrupted, and cannot start a second
-- close, because the phase moves once. If a finalizer never returns, the owner
-- waits for it as the thread that runs it does: it never detaches the VM and
-- never releases a dependency under it.
--
-- A cancellation still pending when the close has finished is recorded and
-- propagated then, after safe teardown: the owner takes every pending one with
-- allowances inside a catcher of its own, so that the cleanup evidence can travel
-- with the first and a later one cannot supersede it.
-- It becomes the primary failure, and the close's failures are retained on it as
-- cleanup evidence, which keeps it classifiable as a cancellation and as
-- cleanup. A cancellation that arrives after the body already failed supersedes
-- the body's failure, as it would for any scope, and the body's failure stays
-- reachable beside it as the failure it was handling. A second cancellation,
-- when the first is already the primary failure, is absorbed by it.
--
-- = Evidence
--
-- Whatever ends the lifetime keeps its own type, value and context. The close's
-- failures, every finalizer failure and release failure with the context it was
-- caught with, are retained beside it as cleanup evidence: through
-- 'Hetoimasia.Foundation.Resource.cleanupFailures' and
-- 'Hetoimasia.Foundation.Resource.cleanupFailuresInContext', which is what a
-- supervisor reads, and under labels naming their source. A close failure with
-- no other failure is the primary one, and is also retained as evidence, so a
-- supervisor classifies it as cleanup and never as a script's own error.
module Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnerConfig (..)
  , defaultOwnerConfig
  , OwnedVm
  , ownedInternalVm
  , ownedHost
  , withOwnedVm
  , evalOwned
  , callOwned
  ) where

import Control.Concurrent (myThreadId)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , allowInterrupt
  , catch
  , fromException
  , mask
  , rethrowIO
  , tryWithContext
  )
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.Maybe (isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Resource (composeCleanup)
import Hetoimasia.Scripting.Lua.Internal.Binding (installRegistration)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Scripting.Lua.Internal.Boundary
  ( Boundary (Boundary)
  , FaultOperation (OpenLibraries)
  , FaultReason (ProfileWithLibraries)
  , blankFault
  )
import Hetoimasia.Scripting.Lua.Internal.Call (ChunkName, callGlobal, evalChunk)
import Hetoimasia.Scripting.Lua.Internal.Module (Host, ModuleSource, loadModule, newHost)
import Hetoimasia.Scripting.Lua.Internal.Registration
  ( Binding (bindingFinalizer, bindingName)
  , LifecycleContext
  , RequestContext
  , Namespace (namespaceBindings, namespaceName)
  , Registration
  , emptyRegistration
  , lookupNamespace
  , qualifiedName
  )
import Hetoimasia.Scripting.Lua.Internal.Value (ValueLimits, defaultValueLimits)
import Hetoimasia.Scripting.Lua.Internal.Fault (luaComponent)
import Hetoimasia.Scripting.Lua.Internal.Library (Library, LibraryProfile)
import Hetoimasia.Scripting.Lua.Internal.Vm
  ( CallbackScope
  , FinalizerPolicy (FinalizersAllow)
  , Vm
  , VmSpec (VmSpec)
  , allocateVm
  , cleanupEvidence
  , closeVm
  , noCallbackScope
  , openLibraries
  , openProfile
  , vmIdentity
  )

-- | What an owner is built from.
--
-- The first two fields are the public configuration; the rest are this
-- package's own fixtures' controls, which the public module does not offer: an
-- added finalizer allowlist, empty by default (the registration's
-- finalizer-eligible bindings, among the granted namespaces, are always on it),
-- and the hooks and allocation budget that make every construction step
-- reachable by an example.
data OwnerConfig = OwnerConfig
  { ownerLibraries ∷ ![Library]
    -- ^ Exactly the standard libraries the VM opens, in order. The empty list
    -- opens none. Must be empty when 'ownerProfile' is set.
  , ownerProfile ∷ !(Maybe LibraryProfile)
    -- ^ A library profile the VM opens in place of an explicit list, filtered
    -- before 'ownerAfterLibraries' and so before any binding, initial chunk or
    -- module. Nothing by default. A profile together with a non-empty
    -- 'ownerLibraries' ends construction with a typed refusal.
  , ownerChunks ∷ ![(ChunkName, ByteString)]
    -- ^ The initial chunks, loaded and run in order inside the lifetime.
  , ownerAllowlist ∷ !(Set Text)
    -- ^ The names of the callbacks a Lua finalizer may run during the VM's
    -- shutdown. Empty by default: no finalizer may call into Haskell.
  , ownerBudget ∷ !(Maybe Int)
    -- ^ A byte budget for the interpreter's allocator, so that an example can
    -- make memory run out at a chosen point of the construction.
  , ownerAfterAllocation ∷ !(Vm → IO ())
    -- ^ A step run first, once the VM exists and before it opens anything.
  , ownerAfterLibraries ∷ !(Vm → IO ())
    -- ^ A step run after the libraries are open and before the initial chunks:
    -- where an example installs the callbacks its chunks call.
  , ownerName ∷ !Text
    -- ^ How the owner is named in a fault.
  , ownerRegistration ∷ Registration
    -- ^ What the application registered. Shared by any number of owners.
  , ownerGranted ∷ ![Text]
    -- ^ The namespaces of the registration this owner exposes: its policy.
  , ownerLimits ∷ !ValueLimits
    -- ^ The bounds on every value that crosses for this owner.
  , ownerModules ∷ ![ModuleSource]
    -- ^ The application-owned modules loaded after the initial chunks, in order.
  , ownerCallbackScope ∷ !CallbackScope
    -- ^ What runs around each of the VM's callbacks, on the callback's thread.
    -- Nothing by default.
  , ownerLifecycle ∷ !(Maybe LifecycleContext)
    -- ^ What delivers this owner's lifecycle operations. Nothing by default: they
    -- are refused as not yet supported.
  , ownerRequests ∷ !(Maybe RequestContext)
    -- ^ What delivers this owner's asynchronous requests. Nothing by default: they
    -- are refused as not yet supported.
  }

-- | An owner over these libraries with no initial chunk, an empty finalizer
-- allowlist, Lua's own allocator and no fixture steps.
defaultOwnerConfig ∷ [Library] → OwnerConfig
defaultOwnerConfig libraries =
  OwnerConfig
    { ownerLibraries = libraries
    , ownerProfile = Nothing
    , ownerChunks = []
    , ownerAllowlist = Set.empty
    , ownerBudget = Nothing
    , ownerAfterAllocation = \_ → pure ()
    , ownerAfterLibraries = \_ → pure ()
    , ownerName = "owner"
    , ownerRegistration = emptyRegistration
    , ownerGranted = []
    , ownerLimits = defaultValueLimits
    , ownerModules = []
    , ownerCallbackScope = noCallbackScope
    , ownerLifecycle = Nothing
    , ownerRequests = Nothing
    }

-- | The names of the bindings a Lua finalizer may run during this owner's close:
-- exactly the granted bindings the registration declares finalizer-eligible,
-- qualified by their namespace, together with any name the fixture allowlist
-- adds.
finalizerAllowlist ∷ OwnerConfig → Set Text
finalizerAllowlist config =
  Set.union (ownerAllowlist config) . Set.fromList $
    [ qualifiedName (namespaceName space) (bindingName binding)
    | name ← ownerGranted config
    , Just space ← [lookupNamespace (ownerRegistration config) name]
    , binding ← namespaceBindings space
    , bindingFinalizer binding
    ]

-- | The VM an owner holds, as its body sees it.
--
-- It is a reference, not the VM's lifetime: it can outlive the body, and once the
-- lifetime has ended every use of it is refused with
-- 'Hetoimasia.Scripting.Lua.Internal.Fault.VmClosed'. Used by any thread but the
-- execution owner's while the VM is open, it is refused with
-- 'Hetoimasia.Scripting.Lua.Internal.Fault.VmNotOwned'. It names no Lua state,
-- stack index, registry reference, coroutine, closure or native address, and no
-- way to close the VM: only the lifetime closes it.
data OwnedVm = OwnedVm !Vm !Host

-- | The bridge's own VM behind an owned one, for this package's fixtures.
ownedInternalVm ∷ OwnedVm → Vm
ownedInternalVm (OwnedVm vm _) = vm

-- | What loads and calls modules in this owner's VM.
ownedHost ∷ OwnedVm → Host
ownedHost (OwnedVm _ host) = host

-- | Run a body over a VM this owner constructed, and close the VM on every
-- exit. See the module header for the lifetime, the cancellation points and the
-- evidence.
withOwnedVm ∷ HasCallStack ⇒ OwnerConfig → (OwnedVm → IO r) → IO r
withOwnedVm config body = mask $ \restore → do
  self ← myThreadId
  -- Masked, and the VM is this owner's from the return: from here nothing is
  -- interruptible until the handler below is installed.
  vm ← allocateVm (VmSpec (ownerBudget config) (Just self) (FinalizersAllow (finalizerAllowlist config)) (ownerCallbackScope config))
  let boundary = Boundary (ownerName config) (vmIdentity vm) (ownerRegistration config) (ownerLimits config) (ownerLifecycle config) (ownerRequests config)
  host ← newHost vm boundary
  ran ← tryWithContext @SomeException $ restore $ do
    ownerAfterAllocation config vm
    openStandardLibraries boundary vm config
    ownerAfterLibraries config vm
    -- Before any initial chunk or module can run, and inside the lifetime, so a
    -- failure here ends construction like any other step.
    installRegistration boundary vm (ownerGranted config)
    traverse_ (uncurry (evalChunk vm)) (ownerChunks config)
    traverse_ (loadModule host) (ownerModules config)
    body (OwnedVm vm host)
  -- The ordinary close: masked, once, never retried, and not uninterruptible
  -- beyond what a blocked finalizer needs.
  closed ← tryWithContext @SomeException (closeVm vm)
  -- Every cancellation that arrived while masked is taken here, inside a catcher
  -- of its own, so the close's evidence can be attached to the first and none
  -- is left pending to supersede it when the owner stops being masked.
  late ← pendingCancellation
  finish ran closed late

-- | Open the owner's standard libraries: its explicit list, or its profile.
--
-- A profile owns the whole set, so one selected together with a list is refused
-- here, before a library opens and so before any authored code can run, and the
-- refusal ends construction like any other failed step: the VM is closed through
-- the same close.
openStandardLibraries ∷ HasCallStack ⇒ Boundary → Vm → OwnerConfig → IO ()
openStandardLibraries boundary vm config = case ownerProfile config of
  Nothing → openLibraries vm (ownerLibraries config)
  Just profile
    | null (ownerLibraries config) → openProfile vm profile
    | otherwise →
        throwFailure luaComponent (operation "open-libraries") [("profile", Text.pack (show profile))] $
          blankFault boundary OpenLibraries (ProfileWithLibraries profile (ownerLibraries config))

-- | Take every cancellation still pending against the owner, and answer the
-- first, which is the one the owner raises. Later ones are absorbed by it: the
-- owner is already ending by a cancellation, and one left pending would be
-- delivered the moment the owner stops being masked, replacing the exception
-- that carries the close's evidence.
--
-- Each allowance delivers at most one pending exception, so this asks until none
-- is delivered. It has no count to stop at, because any count would leave
-- cancellations pending past it: the evidence has to survive every cancellation
-- that is queued when the close finishes, however many. It ends when the queue
-- does, and the queue is whatever other threads have already sent; the owner is
-- closed by then and waiting here costs nothing. A thread that cancels the owner
-- without end keeps it here, as it would keep any masked region.
pendingCancellation ∷ IO (Either (ExceptionWithContext SomeException) ())
pendingCancellation = go (Right ())
  where
    go first = do
      taken ← tryWithContext @SomeException allowInterrupt
      case taken of
        Right () → pure first
        Left cancellation → go (either Left (const (Left cancellation)) first)

-- | Compose how the lifetime ended into what the owner raises or returns.
finish
  ∷ Either (ExceptionWithContext SomeException) r
  → Either (ExceptionWithContext SomeException) ()
  → Either (ExceptionWithContext SomeException) ()
  → IO r
finish ran closed late = do
  let evidence = either cleanupEvidence (const []) closed
  case (ran, late) of
    -- Cancelled after safe teardown, and nothing else was ending the lifetime
    -- as a cancellation: the cancellation is primary, carrying the evidence.
    (Left earlier, Left cancellation)
      | not (isCancellation earlier) → do
          raised ← composeCleanup (Just cancellation) evidence
          -- Raised while handling the failure it supersedes, so that failure
          -- stays reachable from its context.
          rethrowIO earlier `catch` \(_ ∷ SomeException) → raise raised
    (Right _, Left cancellation) → composeCleanup (Just cancellation) evidence >>= raise
    -- Anything else: the primary failure, if there is one, with the evidence.
    _ → do
      composed ← composeCleanup (either Just (const Nothing) ran) evidence
      case composed of
        Just failure → rethrowIO failure
        Nothing → either rethrowIO pure ran
  where
    -- 'composeCleanup' answers a failure whenever it is given a primary one.
    raise ∷ Maybe (ExceptionWithContext SomeException) → IO a
    raise = \case
      Just failure → rethrowIO failure
      Nothing → error "composeCleanup dropped the primary failure it was given"
    isCancellation (ExceptionWithContext _ exception) =
      isJust (fromException exception ∷ Maybe SomeAsyncException)

-- | Load and run a chunk in the owner's VM.
evalOwned ∷ HasCallStack ⇒ OwnedVm → ChunkName → ByteString → IO ()
evalOwned (OwnedVm vm _) = evalChunk vm

-- | Call a global function the owner's VM defines.
callOwned ∷ HasCallStack ⇒ OwnedVm → Text → IO ()
callOwned (OwnedVm vm _) = callGlobal vm
