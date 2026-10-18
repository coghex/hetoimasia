-- | Resources a script instance holds, owned by the engine and not by the script.
--
-- This is LUA-22. An instance's @init@, its callbacks and its @shutdown@ call
-- bindings, and some of those bindings acquire resources for the instance: a
-- connection, a timer, an interest in a shared asset, a native object. Whether the
-- script ever stores what it was handed, overwrites it, forgets it, raises before
-- it can use it, or defines a @shutdown@ that cleans up, the engine releases what
-- the instance acquired when the instance ends (@docs/lua_instance_contract.md@,
-- \"Automatic resource ownership\", D-27). A binding that needs the script to clean
-- up after it is not qualified for this interface.
--
-- = The scope
--
-- Each instance has a /scope/ the engine makes before the instance's first hook and
-- dissolves when the instance settles. It is held in Haskell, in the state of the
-- owner's 'Leases'; nothing in @self@, in a module's globals or in any Lua value
-- can erase, replace or forge it, because none of them can reach it. A script
-- holds /handles/: capabilities ("Hetoimasia.Scripting.Lua.Value") whose key names
-- a lease, issued by the VM and checked by the value boundary before a binding's
-- action runs.
--
-- The scope is built on the owner's capability-owned collection
-- ("Hetoimasia.Scripting.Lua.Lending", LUA-25), which every owner of instances that
-- holds leases lends to its VM's synchronous callbacks. One collection serves all
-- the owner's instances and each instance's scope keeps its own bookkeeping over
-- it, so what one instance holds is never another's to release. A binding's
-- operations run on its callback's thread through the capability the owner lent for
-- that callback; the drain at an instance's end runs on the owner's thread through
-- the capability the owner holds. Neither assumes a binding runs on the owner's
-- thread.
--
-- = Acquiring
--
-- A binding that runs for an instance, in a hook or a callback, acquires with
-- 'acquireOwned' or 'acquireShared'. Each does three things before it returns, and
-- none of them can be left half done:
--
-- 1. /Reserves capacity/ in the instance's scope, before any stage runs. An
--    instance's capacity is bounded ('newLeases'), and the bound counts both the
--    resources it holds and the ones it released whose provider has not yet proved
--    them retired, so a script cannot grow what is outstanding without limit by
--    acquiring and releasing in a loop. When it is exhausted the call is refused:
--    the engine raises the refusal, unmarked as application code, so the script
--    sees a Lua error it may catch, the invocation is faulted whatever the script
--    does with that error (decision C1), and no host failure is made of it. No stage
--    has run and nothing was charged.
-- 2. /Acquires/ through a staged 'Assembly', with every guarantee of
--    "Hetoimasia.Foundation.Resource.OwnedCollection": a failing stage rolls back
--    exactly the stages that completed, registers nothing and gives Lua no handle.
--    A constructor's own failure is a failure of application code and ends the
--    owner under its policy, unconverted; a binding author who wants a recoverable
--    refusal returns it as data instead. A rollback whose release fails is a
--    cleanup failure.
-- 3. /Registers/ the obligation, in the masked step that registered the member, so
--    that a cancellation or a failure to publish the result cannot land between
--    having a resource and having a record of it.
--
-- Only then does the action have a 'Lease' to turn into a handle ('leaseHandle').
-- There is no interval in which Lua holds a resource whose cleanup depends on the
-- script's next statement.
--
-- = Whose resource it is
--
-- The two ways to acquire make the binding author choose.
--
-- * 'acquireOwned': the instance owns what the assembly builds, and releasing the
--   lease destroys it.
-- * 'acquireShared': the instance has taken an interest in a resource that lives on
--   with its owner (a shared asset, a world object), and releasing the lease drops
--   the interest and nothing else. Another instance's lease on the same asset, and
--   the application's own, are untouched.
--
-- A handle stays owned by the instance that acquired it. Caching it in a module's
-- global or in another instance's @self@ does not extend its lifetime: when the
-- acquiring instance ends, every later use of the handle is refused as retired
-- ('Hetoimasia.Scripting.Lua.Value.RuleRetiredHandle'), and an instance resource is
-- never promoted to shared lifetime. Keys are issued in order and never again, so
-- the capacity an ended lease gave back cannot make its old handle live again.
--
-- = Using a handle
--
-- A binding that is given a handle checks nothing itself. The value boundary has
-- checked that it was issued by this VM, is of the declared type and, through
-- 'leaseLive', that its lease has not ended; a handle whose lease has ended is
-- refused before the binding's action runs. 'withLease' then borrows the held
-- resource for the action. A handle used by an instance other than the one that
-- acquired it is refused.
--
-- = Releasing early
--
-- A script may release a handle before its instance ends, through a binding made
-- with 'Hetoimasia.Scripting.Lua.Registration.releaseOperation'. That is the one
-- operation run for a handle whose lease has ended, so releasing twice is not an
-- error, and the one that answers it ('releaseLease'):
--
-- * 'Released': the first release, and the resource is retired.
-- * 'Retiring': the lease is revoked and the provider's retirement of the resource
--   is pending ('retireAsynchronously'). A repeated release answers it again and
--   does not restart anything.
-- * 'AlreadyReleased': the lease ended whole earlier. Nothing runs.
--
-- A release that fails answers neither. Its failure is retained on the lease and is
-- the answer to every later release of it, the native cleanup is never run again,
-- and the failure ends the owner as cleanup failures do. An invalid or missing Lua
-- value is an ordinary argument error and never stops the engine from releasing the
-- instance's other holdings.
--
-- = The end
--
-- On every path by which an instance ends (a failed @init@, a stop, a faulted
-- invocation including a failure of a closing handler, a one-shot's completion, the
-- owner's retirement, and a @shutdown@ that is absent or raises) the instance's
-- remaining holdings are released on the owner's thread after its @shutdown@ hook has
-- run or been skipped. Handles stay usable inside @shutdown@. The holdings are
-- released newest acquisition first, each one's parts in the order its assembly
-- declared, and a release that fails does not stop the others from being attempted.
-- Nothing a script wrote is involved: Lua finalizers and to-be-closed handlers are
-- never the owners of essential cleanup.
--
-- A release that fails is a cleanup failure. It is retained beside the instance's
-- primary failure, which stays primary, in the instance's settlement
-- ('Hetoimasia.Scripting.Lua.Instance.failureSecondary'), and it is cleanup
-- evidence on the owner's outcome, so it ends the owner at once through supervision
-- and is fatal under every policy, an optional owner whose classifier recognizes
-- every exception included. A failed release is never retried and never reported
-- as reclaimed.
--
-- = Retirement that completes later
--
-- Some resources are retired by a provider that finishes later: a native object a
-- device is still using, say. The assembly's release for such a part does not wait.
-- It revokes the part and records the obligation with 'retireAsynchronously', and
-- the lease stays charged against the instance's capacity until the provider proves
-- it complete, which the provider does by changing the state it handed the engine.
--
-- The owner awaits completion outside the collection's uninterruptible releases, in
-- its own protected lifetime, as @docs/resources.md@ asks of a release:
--
-- * the instance's stop completion settles only after its obligations have
--   completed, so nothing is reported as reclaimed merely because Lua stopped;
-- * an owner whose obligations are pending stays live, and so does everything its
--   exit keeps, through a stop and through a cancellation, as a stuck segment keeps
--   it live: nothing is disposed before the provider says it is safe;
-- * a retirement the provider reports failed is retained as cleanup evidence and is
--   fatal, and the lease it belonged to answers that failure and never success.
--
-- What a retirement needs is handed to it the same way ('afterRetirement'): the release of
-- the part that owns a dependency defers its disposal, and the engine runs it once the
-- provider has proved the retirement complete, so a dependency is never disposed under a
-- retirement still using it.
--
-- Rolling back a failed constructor is no exception: a stage it rolled back
-- whose provider has not finished keeps its charge and its owner's life until it has.
--
-- = What the application does
--
-- It makes a 'Lending' and, over it, a 'Leases' ('newLeases'); closes its bindings
-- over the 'Leases'; declares the handle types with 'leaseCapabilityType' so that
-- the boundary asks 'leaseLive'; and gives the owner both, with
-- 'Hetoimasia.Scripting.Lua.Scheduled.scheduledLending' and
-- 'Hetoimasia.Scripting.Lua.Scheduled.scheduledLeases', on an owner that hosts
-- instances. A handle serves one owner. @packages\/scripting-lua\/README.md@ says
-- how to qualify an instance-lifetime binding.
module Hetoimasia.Scripting.Lua.Lease
  ( -- * The handle
    Leases
  , newLeases
  , LeasesRefused (..)
  , LeasesViolation (..)

    -- * Acquiring
  , Lease
  , leaseKey
  , leaseOwnership
  , leaseHandle
  , Ownership (..)
  , acquireOwned
  , acquireShared
  , Retirements
  , retireAsynchronously
  , afterRetirement
  , RetirementState (..)

    -- * Using
  , withLease

    -- * Releasing
  , releaseLease
  , ReleaseAnswer (..)

    -- * The application's check
  , leaseLive
  , leaseCapabilityType

    -- * Reading
  , ScopeSummary (..)
  , instanceLeases
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, mask, rethrowIO, throwIO, tryWithContext)
import Control.Monad (forM, forM_)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import Data.Typeable (Typeable, gcast)
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Foundation.Resource (Assembly, acquirePart, cleanupFailureException, cleanupFailureLabel, cleanupFailuresInContext, releaseRank)
import Hetoimasia.Foundation.Resource.OwnedCollection (MemberStatus (MemberLive), Retirement (AlreadyRetired, Retired, RetirementInUse), memberStatus)
import Hetoimasia.Scripting.Lua.Instance.Types (InstanceId (instanceLocal))
import Hetoimasia.Scripting.Lua.Internal.Fault (CallRefusal (CallRefusal))
import Hetoimasia.Scripting.Lua.Lease.State
import Hetoimasia.Scripting.Lua.Lending
  ( Lending
  , acquireLentThen
  , lentToCallback
  , liveLentCount
  , retireLent
  , withLentMember
  )
import Hetoimasia.Scripting.Lua.Registration (CapabilityType, capabilityType)
import Hetoimasia.Scripting.Lua.Runtime.Shared (runtimeComponent)
import Hetoimasia.Scripting.Lua.Value (Value (VCapability), capability)

-- | A leased resource: the key of the handle a script is given for it, and whose
-- resource it is.
data Lease a = Lease !Word64 !Ownership
  deriving (Eq, Show)

-- | The key of the capability that stands for the lease. Issued once and never again.
leaseKey ∷ Lease a → Word64
leaseKey (Lease key _) = key

-- | Whose resource the lease protects.
leaseOwnership ∷ Lease a → Ownership
leaseOwnership (Lease _ ownership) = ownership

-- | The capability a script is handed for a lease, of the declared type.
leaseHandle ∷ Text → Lease a → Value
leaseHandle typeName lease = VCapability (capability typeName (leaseKey lease))

-- | A handle for the collection @lending@ lends, with room for @capacity@ charges
-- for each instance: the resources it holds, and the ones it released that their
-- providers have yet to prove retired.
--
-- Refused with 'CapacityBelowOne' for a capacity below one.
newLeases ∷ HasCallStack ⇒ Lending → Int → IO Leases
newLeases lending capacity
  | capacity < 1 = throwFailure runtimeComponent (operation "new-leases") [] (LeasesRefused (CapacityBelowOne capacity :| []))
  | otherwise = newLeasesHandle lending capacity

-- | What a release hands the engine when its resource is retired by a provider that
-- finishes later.
data Retirements = Retirements
  { retireAsynchronously ∷ Text → STM RetirementState → IO ()
    -- ^ Record that the release has handed the resource to its provider, under a
    -- label that names it in evidence, and say how to ask the provider where it has
    -- got to. Called from the part's release: it never waits, and the reading
    -- must not retry. The lease keeps its charge, and its owner stays live, until
    -- the reading says 'ProviderComplete' or 'ProviderFailed'.
  , afterRetirement ∷ IO () → IO ()
    -- ^ Hand over a dependency the retirements need. Called from the release of the
    -- part that owns the dependency, which must be ranked after the parts being
    -- retired: the disposal is run once every retirement the lease has recorded has
    -- completed, uninterruptibly on the owner's thread and before the instance's stop
    -- completion settles, and never before. At once, inside the release, if none is
    -- pending. If a provider reports its retirement failed the disposal never runs: the
    -- dependency is retained, as the resource is, and the failure is the evidence.
  }

-- | Acquire a resource the instance owns, through a staged assembly. See the module
-- header for the three steps and their guarantees.
--
-- The assembly is given the means to record an asynchronous retirement for its own
-- releases. Releasing the lease releases the assembly's parts in their declared
-- order and destroys the resource.
--
-- The resource's type is how a binding asks for it again ('withLease'), and a
-- handle of a lease that holds another type is refused.
acquireOwned ∷ (HasCallStack, Typeable a) ⇒ Leases → (Retirements → Assembly a) → IO (Lease a)
acquireOwned leases = acquireWith leases InstanceOwned

-- | Take the instance's interest in a resource that lives on with its owner. The
-- first action takes the interest and answers what the instance uses; the second
-- drops it, and nothing else, when the lease is released.
acquireShared ∷ (HasCallStack, Typeable a) ⇒ Leases → Text → IO a → (a → IO ()) → IO (Lease a)
acquireShared leases label take' drop' =
  acquireWith leases ApplicationOwned (\_ → acquirePart label (releaseRank 0) take' drop')

acquireWith ∷ (HasCallStack, Typeable a) ⇒ Leases → Ownership → (Retirements → Assembly a) → IO (Lease a)
acquireWith leases ownership build = do
  loan ← lentToCallback (leasesLending leases)
  -- The loan is asked for its use before anything is charged: a loan that has
  -- ended, or a thread the callback started, is refused here with no effect.
  _ ← liveLentCount loan
  caller ← runningInstance leases
  number ← maybe (refuse NoInstance) pure caller
  mask $ \restore → do
    reserved ← atomically (reserve leases number ownership)
    key ← either refuse pure reserved
    -- Nothing between the reservation and its end may leave it charged: whatever
    -- ends the acquisition without a registered lease gives the reservation back.
    outcome ←
      tryWithContext @SomeException . restore $
        acquireLentThen loan (build (retirementsFor leases key)) $ \member → do
          -- Masked, in the step that registered the member, and with nothing
          -- interruptible before it: the member and its record come to exist together.
          atomically (register leases key (Holding member))
          pure (Lease key ownership)
    case outcome of
      Right lease → pure lease
      Left failure@(ExceptionWithContext context _) → do
        -- A stage whose rollback release failed is a cleanup failure the exception carries
        -- to supervision, and is kept for the instance's settlement beside whatever else
        -- failed, in the step that gives the reservation back. The constructor's own
        -- exception is rethrown as it was.
        notes ← forM (cleanupFailuresInContext context) $ \cleanup → do
          rendered ← renderCaught (cleanupFailureException cleanup)
          pure ("a rollback release failed: " <> cleanupFailureLabel cleanup <> ": " <> rendered)
        atomically $ do
          abandon leases key
          forM_ notes (noteScope leases number)
        rethrowIO failure

-- | What the release of a lease's parts is given to record a retirement with.
retirementsFor ∷ Leases → Word64 → Retirements
retirementsFor leases key =
  Retirements
    { retireAsynchronously = \label poll → atomically (recordRetirement leases key label poll)
    , afterRetirement = \disposal → atomically (deferDisposal leases key disposal) >>= mapM_ id
    }

-- | Borrow the resource a lease holds, for the duration of the action.
--
-- Refused when the lease has ended, when it was acquired by another instance and when
-- it holds a resource of another type. The action runs with the collection's
-- borrowing rules: it may borrow other live members, and must not let the resource
-- escape.
withLease ∷ (HasCallStack, Typeable a) ⇒ Leases → Word64 → (a → IO r) → IO r
withLease leases key use = do
  loan ← lentToCallback (leasesLending leases)
  caller ← runningInstance leases
  found ← atomically (lookupSlot leases key)
  case found of
    Nothing → refuse LeaseEnded
    Just slot
      | caller /= Just (slotInstance slot) → refuse NotTheOwner
      | otherwise → case (slotPhase slot, slotHolding slot) of
          (SlotLive, Just (Holding member)) → case gcast member of
            Just typed → withLentMember loan typed use
            Nothing → refuse WrongType
          _ → refuse LeaseEnded

-- | What an explicit release answered.
data ReleaseAnswer
  = -- | The first release, and the resource is retired.
    Released
  | -- | The lease is revoked and the provider's retirement is pending. Asking again
    -- does not restart it.
    Retiring
  | -- | The lease ended whole earlier. Nothing ran.
    AlreadyReleased
  deriving (Eq, Show)

-- | Release a lease before its instance ends.
--
-- The first release revokes the handle, releases the resource on this callback's
-- thread and answers 'Released', or 'Retiring' when a provider's retirement is
-- pending. Releasing again answers 'AlreadyReleased' or 'Retiring' and runs nothing.
--
-- A release that fails raises its failure: a cleanup failure, which ends the owner as
-- they do, and it is the answer to every later release of the lease. The native
-- cleanup is never run a second time. Refused when the lease is another instance's.
releaseLease ∷ HasCallStack ⇒ Leases → Word64 → IO ReleaseAnswer
releaseLease leases key = do
  loan ← lentToCallback (leasesLending leases)
  _ ← liveLentCount loan
  caller ← runningInstance leases
  mask $ \_ → do
    started ← atomically (beginRelease leases caller key)
    case started of
      StartEnded → pure AlreadyReleased
      StartRetiring → pure Retiring
      StartFailed failure → rethrowIO failure
      StartRefused refusal → refuse refusal
      StartLive (Holding member) → do
        outcome ← tryWithContext @SomeException (retireLent loan member)
        status ← memberStatus member
        case (outcome, status) of
          -- The collection refused before it released anything: nothing of the lease
          -- has ended.
          (Left failure, MemberLive) → do
            atomically (restoreLive leases key)
            rethrowIO failure
          (Right RetirementInUse, _) → do
            atomically (restoreLive leases key)
            refuse ReleaseRunning
          (Right Retired, _) → settled
          (Right AlreadyRetired, _) → settled
          (Left failure, _) → do
            ended ← atomically (endRelease leases key (Left failure))
            case ended of
              EndedFailed retained → do
                rendered ← renderCaught retained
                forM_ caller $ \number →
                  atomically (noteScope leases number ("an early release failed: " <> rendered))
                rethrowIO retained
              _ → rethrowIO failure
  where
    settled = do
      ended ← atomically (endRelease leases key (Right ()))
      pure $ case ended of
        EndedRetiring → Retiring
        _ → Released

-- | Whether a handle's lease is live: the application's own check for a lease
-- handle's type, run by the value boundary before a binding's action.
leaseLive ∷ Leases → Word64 → IO Bool
leaseLive leases key = atomically (liveKey leases key)

-- | A capability type for lease handles, named, whose liveness is the lease's.
leaseCapabilityType ∷ Leases → Text → CapabilityType
leaseCapabilityType leases name = capabilityType name (leaseLive leases)

-- | One instance's leases at a glance, in one transaction.
instanceLeases ∷ Leases → InstanceId → STM ScopeSummary
instanceLeases leases identity = summarize leases (instanceLocal identity)

-- | Refuse the call, as the engine: a fault of the call and not a failure of the
-- application's code.
refuse ∷ Refusal → IO a
refuse = throwIO . CallRefusal . renderRefusal
