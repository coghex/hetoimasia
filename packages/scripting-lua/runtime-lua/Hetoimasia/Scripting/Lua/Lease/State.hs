-- | What the instance leases are made of, and the state their two sides share: the
-- binding actions, which run on a callback thread of their own while the owner's
-- thread is blocked in Lua, and the owner's thread, which drains an instance's
-- holdings when it ends and waits for what the providers retire.
--
-- This is a hidden module of the adapter. "Hetoimasia.Scripting.Lua.Lease" is the
-- binding author's view of it and says what the leases are; this module is where
-- the bookkeeping lives and what the instance layer calls.
--
-- = The bookkeeping
--
-- One 'LeaseState' per owner, in one variable so that every reading and every
-- change is a single transaction. It holds the /scopes/, one for each live
-- instance, and the /slots/, one for each charge against an instance's capacity.
-- A slot is made when a binding reserves capacity, before any stage of its
-- acquisition runs, and it is the key of the handle Lua is given. Keys are issued
-- in order and never again, so a handle that has ended can be told from one that
-- was never issued by its number alone, and a slot that is free again can never
-- be mistaken for a later holding.
--
-- A slot is charged from its reservation until nothing it stands for is left: the
-- resource it holds, while it is live, and every retirement a provider has yet to
-- complete after it was released. That is what bounds the obligations an instance
-- can have outstanding: an acquire-and-release cycle whose retirement is pending
-- keeps its charge, so repeated cycles meet the capacity and are refused.
--
-- = Who touches it, and when
--
-- The binding's action, on the callback thread, reserves, registers, abandons and
-- releases. The owner's thread opens a scope before the instance's first hook,
-- drains it after the instance's @shutdown@, polls the retirements and dissolves
-- the scope when the instance has settled. The owner's thread is blocked inside the
-- Lua call that is running the callback, so the two never act at once; the
-- transactions make the order explicit anyway and the state needs no other
-- protection.
--
-- = State
--
-- Every piece of state here is private to one owner's 'Leases', and none of it is
-- application state:
--
-- * /The next key/: written by every reservation, any thread, for the handle's life;
--   monotone and never rewound.
-- * /The scopes/: the owner's thread opens one before an instance's first hook, closes
--   it when it drains, and dissolves it when the instance has settled; the actions
--   read it.
-- * /The slots/: the actions reserve, register and release them, and the owner's
--   thread drains and polls them; a slot lives from its reservation until nothing it
--   stands for is left, and then it is deleted, unless it holds a retained failure.
-- * /The orphans/: a retirement recorded for a slot that is gone, awaited like the
--   rest and deleted when the provider has finished it.
module Hetoimasia.Scripting.Lua.Lease.State
  ( -- * The handle
    Leases (..)
  , newLeasesHandle
  , bindLeasesHandle
  , runningInstance

    -- * What a lease is
  , Ownership (..)
  , RetirementState (..)
  , Holding (..)
  , Obligation (..)
  , Slot (..)
  , slotPresent
  , SlotPhase (..)
  , Scope (..)
  , LeaseState (..)

    -- * Refusals the engine makes
  , Refusal (..)
  , renderRefusal
  , LeasesViolation (..)
  , LeasesRefused (..)

    -- * Acquiring
  , openScope
  , dissolveScope
  , reserve
  , register
  , abandon
  , retainFailed
  , recordRetirement
  , deferDisposal

    -- * Reading
  , liveKey
  , lookupSlot
  , ScopeSummary (..)
  , summarize
  , pendingFor

    -- * Releasing
  , ReleaseStart (..)
  , beginRelease
  , ReleaseEnd (..)
  , endRelease
  , restoreLive

    -- * The owner's side
  , LeaseHost (..)
  , DrainReport (..)
  , drainScope
  , Retirements (..)
  , retirementsFor
  , adoptReserved
  , releaseKey
  , RetirementEnd (..)
  , serviceRetirements
  , Disposals (..)
  , finishDisposals
  , retirementsReady
  , renderCaught
  , guarded
  , pollObligation
  , anyPending
  , noteScope
  , readScope
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , retry
  , writeTVar
  )
import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeAsyncException, SomeException, evaluate, fromException, mask, mask_, throwIO, try)
import Control.Monad (forM, forM_, when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (Down))
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Typeable (Typeable)
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Resource (Assembly, cleanupFailureException, cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Foundation.Resource.OwnedCollection
  ( Member
  , OwnedCollection
  , OwnerCapability
  , acquireOwnedMemberThen
  , retireOwnedMember
  )
import Hetoimasia.Scripting.Lua.Lending.Loan (Lending)
import Hetoimasia.Scripting.Lua.Retention

-- The handle ----------------------------------------------------------------------

-- | What an application gives one scheduled owner to hold its instances' leases
-- through, and its bindings use to acquire and release them.
--
-- Like the 'Lending' it is made over, it serves one owner: there is no registry of
-- owners and no lookup by thread.
data Leases = Leases
  { leasesLending ∷ !Lending
    -- ^ The handle the owner lends its collection through.
  , leasesCapacity ∷ !Int
    -- ^ What one instance may have charged at once: the resources it holds and the
    -- retirements its released ones still await.
  , leasesState ∷ !(TVar LeaseState)
  , leasesRunning ∷ !(IORef (Maybe (IO (Maybe Word64))))
    -- ^ How a binding asks which instance's Lua is running: the owner's, set when it
    -- takes the handle.
  }

-- | A handle for a collection lent through @lending@, with room for @capacity@
-- charges per instance. The capacity must be at least one; the caller checks.
newLeasesHandle ∷ Lending → Int → IO Leases
newLeasesHandle lending capacity =
  Leases lending capacity
    <$> newTVarIO (LeaseState 1 Map.empty Map.empty [])
    <*> newIORef Nothing

-- | Take the handle for an owner, telling it how to find the instance whose Lua is
-- running. A handle serves one owner because the 'Lending' it is made over does: the
-- owner takes that first, and refuses a second with 'LendingInUse'.
bindLeasesHandle ∷ Leases → IO (Maybe Word64) → IO ()
bindLeasesHandle leases running = writeIORef (leasesRunning leases) (Just running)

-- | The instance whose Lua the owner's thread is running right now, if there is
-- one. Nothing before an owner has taken the handle.
runningInstance ∷ Leases → IO (Maybe Word64)
runningInstance leases =
  readIORef (leasesRunning leases) >>= maybe (pure Nothing) id

-- What a lease is ------------------------------------------------------------------

-- | Who owns what a lease protects.
data Ownership
  = -- | The instance owns the resource: its release destroys it.
    InstanceOwned
  | -- | The application or another user owns the resource: the lease is the
    -- instance's interest in it, and its release drops that and nothing else.
    ApplicationOwned
  deriving (Eq, Show)

-- | A held resource, typed so that only a borrower that asks for its type gets it.
data Holding = ∀ a. Typeable a ⇒ Holding !(Member a)

-- | Where a slot is in its life.
data SlotPhase
  = -- | Capacity is reserved and the acquisition is running. No handle exists.
    SlotConstructing
  | -- | The resource is held and registered, and its handle may be in Lua's hands.
    SlotLive
  | -- | Its release is running. The handle is already revoked.
    SlotReleasing
  | -- | Released. What it still holds is a retirement the provider has yet to
    -- complete.
    SlotReleased
  | -- | A release or a retirement failed. The failure is retained, nothing is
    -- retried and nothing is reported as reclaimed.
    SlotFailed !(ExceptionWithContext SomeException)

-- | One charge against an instance's capacity.
data Slot = Slot
  { slotInstance ∷ !Word64
  , slotOwnership ∷ !Ownership
  , slotPhase ∷ !SlotPhase
  , slotHolding ∷ !(Maybe Holding)
  , slotRetained ∷ !Retained
    -- ^ The retirements it awaits, and the disposals of what they need, handed over by the
    -- assembly's releases: run, in order, once every one of them has completed, and never
    -- if one fails.
  }

-- | An instance's scope.
data Scope = Scope
  { scopeOpen ∷ !Bool
    -- ^ Whether it accepts acquisitions: until the instance's holdings are drained.
  , scopeDrained ∷ !Int
    -- ^ The holdings the end released.
  , scopeAwaited ∷ !Int
    -- ^ The retirements that completed after the end began.
  , scopeFailed ∷ !Int
    -- ^ The release and retirement failures.
  , scopeNotes ∷ ![Text]
    -- ^ A bounded rendering of each failure, oldest first.
  }

data LeaseState = LeaseState
  { lsNext ∷ !Word64
  , lsScopes ∷ !(Map Word64 Scope)
  , lsSlots ∷ !(Map Word64 Slot)
  , lsOrphans ∷ ![Obligation]
  }

-- Refusals --------------------------------------------------------------------------

-- | Why the engine refused a binding's call to reserve capacity.
data Refusal
  = -- | The binding is called by no instance: a task, or a module's own chunk.
    NoInstance
  | -- | The calling instance has no scope.
    NoScope
  | -- | The scope has been drained: the instance is ending.
    ScopeClosed
  | -- | The instance's capacity is charged: what it is, and what is charged.
    CapacityExhausted !Int !Int
  | -- | The handle is another instance's: it acquired it.
    NotTheOwner
  | -- | The lease holds a resource of another type than the one asked for.
    WrongType
  | -- | A release that is already running.
    ReleaseRunning
  | -- | The lease has ended.
    LeaseEnded
  deriving (Eq, Show)

-- | A refusal as a reason a script reads.
renderRefusal ∷ Refusal → Text
renderRefusal = \case
  NoInstance -> "a lease is held by an instance, and no instance is running"
  NoScope -> "the running instance has no lease scope"
  ScopeClosed -> "the instance's leases are being released: it is ending"
  CapacityExhausted capacity charged ->
    "the instance's lease capacity is exhausted: "
      <> Text.pack (show charged)
      <> " of "
      <> Text.pack (show capacity)
      <> " charged, counting released resources whose retirement is not complete"
  NotTheOwner -> "the lease belongs to another instance"
  WrongType -> "the lease holds a resource of another type"
  ReleaseRunning -> "the lease is being released"
  LeaseEnded -> "the lease has ended"

-- | What is wrong with the way an owner was given its leases.
data LeasesViolation
  = -- | The capacity per instance is below one: what was given.
    CapacityBelowOne !Int
  | -- | The owner hosts no instances, so nothing holds a lease.
    LeasesNeedInstances
  | -- | The owner lends no collection, so nothing can be acquired.
    LeasesNeedLending
  | -- | The leases were made over another handle than the one the owner lends through.
    LeasesLendingMismatch
  | -- | The owner's collection is too small to hold every instance at its capacity:
    -- the members it holds, and the members the instances could hold at once.
    LeasesMembersTooFew !Int !Int
  deriving (Eq, Show)

-- | Leases were refused, and nothing was made. Every violation.
newtype LeasesRefused = LeasesRefused (NonEmpty LeasesViolation)
  deriving (Eq, Show)

instance Exception LeasesRefused

-- Acquiring --------------------------------------------------------------------------

-- | Give an instance its scope. Idempotent.
openScope ∷ Leases → Word64 → STM ()
openScope leases number =
  modifyTVar' (leasesState leases) $ \state →
    state {lsScopes = Map.insertWith (\_ held → held) number (Scope True 0 0 0 []) (lsScopes state)}

-- | Take an instance's scope away, once it has settled. What it still has charged
-- is not: the slots are the owner's to poll and retain.
dissolveScope ∷ Leases → Word64 → STM ()
dissolveScope leases number =
  modifyTVar' (leasesState leases) $ \state →
    state {lsScopes = Map.delete number (lsScopes state)}

-- | How many slots an instance has charged.
chargedBy ∷ LeaseState → Word64 → Int
chargedBy state number = Map.size (Map.filter ((== number) . slotInstance) (lsSlots state))

-- | Reserve one charge of the instance's capacity and issue the key of the handle
-- it will be given, before any stage of the acquisition has run.
reserve ∷ Leases → Word64 → Ownership → STM (Either Refusal Word64)
reserve leases number ownership = do
  state ← readTVar (leasesState leases)
  case Map.lookup number (lsScopes state) of
    Nothing → pure (Left NoScope)
    Just scope
      | not (scopeOpen scope) → pure (Left ScopeClosed)
      | charged >= leasesCapacity leases → pure (Left (CapacityExhausted (leasesCapacity leases) charged))
      | otherwise → do
          let key = lsNext state
          writeTVar (leasesState leases) state
            { lsNext = key + 1
            , lsSlots = Map.insert key (Slot number ownership SlotConstructing Nothing noRetained) (lsSlots state)
            }
          pure (Right key)
      where
        charged = chargedBy state number

-- | Record the registered resource: the slot is live, and its handle may be given
-- to Lua. Runs in the step that registered the member, masked.
register ∷ Leases → Word64 → Holding → STM ()
register leases key holding =
  modifyTVar' (leasesState leases) $ \state →
    state {lsSlots = Map.adjust (\slot → slot {slotPhase = SlotLive, slotHolding = Just holding}) key (lsSlots state)}

-- | Give back a reservation whose acquisition did not complete. A slot that is
-- registered is not touched: its holding is the scope's, and the drain finds it. One
-- that has retirements pending keeps its charge until they complete.
abandon ∷ Leases → Word64 → STM ()
abandon leases key =
  modifyTVar' (leasesState leases) $ \state →
    state {lsSlots = Map.update undo key (lsSlots state)}
  where
    undo slot = case slotPhase slot of
      SlotConstructing
        | not (retainedPending (slotRetained slot)) → Nothing
        | otherwise → Just slot {slotPhase = SlotReleased}
      _ → Just slot

-- | A reservation whose building failed and whose rollback could not be proven: a stage's release
-- raised, so what it held may not be retired. The slot stays, failed, and keeps its charge; nothing is
-- reported as reclaimed, and whatever was charged beside it (the credits that were to transfer to the
-- resource) stays charged with it. The failure is the evidence.
retainFailed ∷ Leases → Word64 → ExceptionWithContext SomeException → STM ()
retainFailed leases key failure =
  modifyTVar' (leasesState leases) $ \state →
    state {lsSlots = Map.adjust (\slot → slot {slotPhase = SlotFailed failure, slotHolding = Nothing}) key (lsSlots state)}

-- | Whether a slot is still charged: reserved, live, releasing, or released with a provider's retirement
-- of what it held still to complete. A slot is gone once nothing is charged to it any more.
slotPresent ∷ Leases → Word64 → STM Bool
slotPresent leases key = Map.member key . lsSlots <$> readTVar (leasesState leases)

-- | Record a retirement the provider has yet to complete, charged to the slot the
-- release belongs to. A slot that is gone cannot be charged: the retirement is
-- still awaited, as an orphan.
recordRetirement ∷ Leases → Word64 → Text → STM RetirementState → STM ()
recordRetirement leases key label poll =
  modifyTVar' (leasesState leases) $ \state →
    let obligation = Obligation label poll
     in case Map.lookup key (lsSlots state) of
          Just slot →
            state {lsSlots = Map.insert key slot {slotRetained = retain obligation (slotRetained slot)} (lsSlots state)}
          Nothing → state {lsOrphans = lsOrphans state <> [obligation]}

-- | Hand a disposal to the slot's pending retirements: it is kept until every one of
-- them has completed. A slot with none pending has nothing to wait for, and the
-- disposal is handed back to be run now.
deferDisposal ∷ Leases → Word64 → IO () → STM (Maybe (IO ()))
deferDisposal leases key disposal = do
  state ← readTVar (leasesState leases)
  case Map.lookup key (lsSlots state) of
    Just slot → do
      let (held, now) = defer disposal (slotRetained slot)
      writeTVar (leasesState leases) state {lsSlots = Map.insert key slot {slotRetained = held} (lsSlots state)}
      pure now
    Nothing → pure (Just disposal)

-- Reading ------------------------------------------------------------------------------

-- | Whether a handle's lease is live: registered, and not released. The
-- application's own check for the handle's type.
liveKey ∷ Leases → Word64 → STM Bool
liveKey leases key = do
  state ← readTVar (leasesState leases)
  pure $ case Map.lookup key (lsSlots state) of
    Just slot → case slotPhase slot of
      SlotLive → True
      _ → False
    Nothing → False

-- | A slot by key.
lookupSlot ∷ Leases → Word64 → STM (Maybe Slot)
lookupSlot leases key = Map.lookup key . lsSlots <$> readTVar (leasesState leases)

-- | An instance's leases at a glance.
data ScopeSummary = ScopeSummary
  { summaryLive ∷ !Int
    -- ^ Resources held and registered.
  , summaryConstructing ∷ !Int
  , summaryPending ∷ !Int
    -- ^ Retirements the providers have yet to complete.
  , summaryCharged ∷ !Int
    -- ^ Everything charged against the capacity.
  , summaryCapacity ∷ !Int
  , summaryFailures ∷ !Int
  }
  deriving (Eq, Show)

-- | One instance's summary, in one transaction.
summarize ∷ Leases → Word64 → STM ScopeSummary
summarize leases number = do
  state ← readTVar (leasesState leases)
  let mine = [slot | slot ← Map.elems (lsSlots state), slotInstance slot == number]
      live = [() | slot ← mine, SlotLive ← [slotPhase slot]]
      constructing = [() | slot ← mine, SlotConstructing ← [slotPhase slot]]
      failed = [() | slot ← mine, SlotFailed _ ← [slotPhase slot]]
  pure
    ScopeSummary
      { summaryLive = length live
      , summaryConstructing = length constructing
      , summaryPending = sum (map (length . retainedObligations . slotRetained) mine)
      , summaryCharged = length mine
      , summaryCapacity = leasesCapacity leases
      , summaryFailures = length failed + maybe 0 scopeFailed (Map.lookup number (lsScopes state))
      }

-- | The retirements an instance's slots still await.
pendingFor ∷ Leases → Word64 → STM Int
pendingFor leases number = do
  state ← readTVar (leasesState leases)
  pure (sum [length (retainedObligations (slotRetained slot)) | slot ← Map.elems (lsSlots state), slotInstance slot == number])

-- | An instance's scope, while it has one.
readScope ∷ Leases → Word64 → STM (Maybe Scope)
readScope leases number = Map.lookup number . lsScopes <$> readTVar (leasesState leases)

-- | Note a failure on an instance's scope: bounded, oldest first.
noteScope ∷ Leases → Word64 → Text → STM ()
noteScope leases number note =
  modifyTVar' (leasesState leases) $ \state →
    state {lsScopes = Map.adjust bump number (lsScopes state)}
  where
    bump scope =
      scope
        { scopeFailed = scopeFailed scope + 1
        , scopeNotes = take noteLimit (scopeNotes scope <> [Text.take noteWidth note])
        }

noteLimit, noteWidth ∷ Int
noteLimit = 8
noteWidth = 512

-- Releasing ----------------------------------------------------------------------------

-- | What beginning a release found.
data ReleaseStart
  = -- | The lease was live and is revoked now: its holding, to retire.
    StartLive !Holding
  | -- | The lease was released and a provider's retirement is pending. Nothing is
    -- restarted.
    StartRetiring
  | -- | The lease ended whole.
    StartEnded
  | -- | A release or a retirement of it failed: the failure, retained.
    StartFailed !(ExceptionWithContext SomeException)
  | -- | Refused.
    StartRefused !Refusal

-- | Revoke a live lease and take its holding, once. The instance that asks is the
-- one that acquired it, or the lease has ended.
beginRelease ∷ Leases → Maybe Word64 → Word64 → STM ReleaseStart
beginRelease leases caller key = do
  state ← readTVar (leasesState leases)
  case Map.lookup key (lsSlots state) of
    Nothing → pure StartEnded
    Just slot
      | Nothing ← caller → pure (StartRefused NoInstance)
      | caller /= Just (slotInstance slot) → pure (StartRefused NotTheOwner)
      | otherwise → case (slotPhase slot, slotHolding slot) of
          (SlotLive, Just holding) → do
            writeTVar (leasesState leases) state
              { lsSlots = Map.insert key slot {slotPhase = SlotReleasing} (lsSlots state)
              }
            pure (StartLive holding)
          (SlotLive, Nothing) → pure (StartRefused WrongType)
          (SlotReleased, _) → pure StartRetiring
          (SlotFailed failure, _) → pure (StartFailed failure)
          (SlotReleasing, _) → pure (StartRefused ReleaseRunning)
          (SlotConstructing, _) → pure (StartRefused ReleaseRunning)

-- | What a release came to.
data ReleaseEnd
  = -- | The release completed and nothing is left to retire.
    EndedWhole
  | -- | The release completed and a provider's retirement is pending.
    EndedRetiring
  | -- | The release failed.
    EndedFailed !(ExceptionWithContext SomeException)

-- | Record what a release came to, and free the slot when nothing is left of it.
endRelease ∷ Leases → Word64 → Either (ExceptionWithContext SomeException) () → STM ReleaseEnd
endRelease leases key outcome = do
  state ← readTVar (leasesState leases)
  case Map.lookup key (lsSlots state) of
    Nothing → pure EndedWhole
    Just slot → case outcome of
      Left failure → do
        writeTVar (leasesState leases) state
          { lsSlots = Map.insert key slot {slotPhase = SlotFailed failure, slotHolding = Nothing} (lsSlots state)
          }
        pure (EndedFailed failure)
      Right () → do
        let pending = retainedPending (slotRetained slot)
        writeTVar (leasesState leases) state
          { lsSlots =
              if pending
                then Map.insert key slot {slotPhase = SlotReleased, slotHolding = Nothing} (lsSlots state)
                else Map.delete key (lsSlots state)
          }
        pure (if pending then EndedRetiring else EndedWhole)

-- | Put a lease back to live: its release was refused before it ran anything, so
-- nothing of it has ended.
restoreLive ∷ Leases → Word64 → STM ()
restoreLive leases key =
  modifyTVar' (leasesState leases) $ \state →
    state {lsSlots = Map.adjust (\slot → case slotPhase slot of SlotReleasing → slot {slotPhase = SlotLive}; _ → slot) key (lsSlots state)}

-- The owner's side ------------------------------------------------------------------------

-- | What the owner's thread holds to do its part: the leases, and the collection
-- and the capability it holds on its own thread.
data LeaseHost = LeaseHost
  { lhLeases ∷ !Leases
  , lhCollection ∷ !OwnedCollection
  , lhCapability ∷ !OwnerCapability
  }

-- | What draining an instance's scope came to.
data DrainReport = DrainReport
  { drainReleased ∷ !Int
    -- ^ The holdings released.
  , drainFailures ∷ ![ExceptionWithContext SomeException]
    -- ^ What their releases raised, in the order they were attempted.
  }

-- | Release every holding an instance has registered, newest acquisition first and
-- each one's parts in the order its assembly declared, attempting every one whatever
-- another does.
--
-- It closes the scope first, so nothing is acquired once the drain has begun, and it
-- runs on the owner's thread through the capability the owner holds. A holding
-- already released, or retired by the instance, is skipped: draining an instance
-- again after a failure of the host interrupted it finds what is left. The whole
-- drain is masked: a release is uninterruptible, and a cancellation lands after the
-- last holding has been attempted.
drainScope ∷ LeaseHost → Word64 → IO DrainReport
drainScope host number = mask_ $ do
  let leases = lhLeases host
  keys ← atomically $ do
    modifyTVar' (leasesState leases) $ \state →
      state {lsScopes = Map.adjust (\scope → scope {scopeOpen = False}) number (lsScopes state)}
    state ← readTVar (leasesState leases)
    pure
      [ key
      | (key, slot) ← sortOn (Down . fst) (Map.toList (lsSlots state))
      , slotInstance slot == number
      , isLive (slotPhase slot)
      ]
  results ← forM keys (releaseKey host number)
  let failures = [failure | Left failure ← results]
      released = length [() | Right () ← results]
  atomically $ modifyTVar' (leasesState leases) $ \state →
    state {lsScopes = Map.adjust (\scope → scope {scopeDrained = scopeDrained scope + released}) number (lsScopes state)}
  pure (DrainReport released failures)
  where
    isLive = \case
      SlotLive → True
      _ → False

-- | Release one live holding of an instance on the owner's thread: revoke the lease, retire
-- its member through the owner's capability and record how it went. A holding already released
-- is skipped. Masked by the caller, as the drain is.
releaseKey ∷ LeaseHost → Word64 → Word64 → IO (Either (ExceptionWithContext SomeException) ())
releaseKey host number key = do
  let leases = lhLeases host
  started ← atomically (beginRelease leases (Just number) key)
  case started of
    StartLive (Holding member) → do
      outcome ← guarded (retireOwnedMember (lhCollection host) (lhCapability host) member)
      ended ← atomically (endRelease leases key (() <$ outcome))
      pure $ case ended of
        EndedFailed failure → Left failure
        _ → Right ()
    _ → pure (Right ())

-- | What a release hands the engine when its resource is retired by a provider that finishes
-- later: see "Hetoimasia.Scripting.Lua.Lease".
data Retirements = Retirements
  { retireAsynchronously ∷ Text → STM RetirementState → IO ()
    -- ^ Record that the release has handed the resource to its provider, under a label that
    -- names it in evidence, and say how to ask the provider where it has got to. Called from
    -- the part's release: it never waits, and the reading must not retry, and it only reads
    -- (what it writes is not kept). It may read TVars that more than one reading shares. The
    -- lease keeps its charge, and its owner stays live, until the reading says
    -- 'ProviderComplete' or 'ProviderFailed'.
  , afterRetirement ∷ IO () → IO ()
    -- ^ Hand over a dependency the retirements need. Called from the release of the part that
    -- owns the dependency, which must be ranked after the parts being retired: the disposal is
    -- run once every retirement the lease has recorded has completed, uninterruptibly on the
    -- owner's thread and before the instance's stop completion settles, and never before. At
    -- once, inside the release, if none is pending. If a provider reports its retirement failed
    -- the disposal never runs: the dependency is retained, as the resource is, and the failure
    -- is the evidence.
  }

-- | What the release of the parts of one slot's lease is given to record a retirement with.
retirementsFor ∷ Leases → Word64 → Retirements
retirementsFor leases key =
  Retirements
    { retireAsynchronously = \label poll → atomically (recordRetirement leases key label poll)
    , afterRetirement = \disposal → atomically (deferDisposal leases key disposal) >>= mapM_ id
    }

-- | Build the resource of a lease an admission reserved, into that reservation, on the owner's
-- thread through the capability it holds, as a binding acquires through a lent one: the
-- assembly's stages roll back exactly as they completed if one fails, and the member and its
-- record come to exist together, in the masked step that registers the member. The reserved
-- slot becomes live, and the capacity it was charged against is the one the live resource
-- keeps. A failure leaves the reservation given back (unless a stage's retirement is pending, which
-- keeps its charge), notes any rollback release that failed on the instance's scope as cleanup
-- evidence, and is answered, whole, for the owner to raise.
adoptReserved
  ∷ (HasCallStack, Typeable a)
  ⇒ LeaseHost
  → Word64
  → Word64
  → (Retirements → Assembly a)
  → IO (Either (ExceptionWithContext SomeException) ())
adoptReserved host number key build = mask $ \_ → do
  let leases = lhLeases host
  outcome ←
    guarded $
      acquireOwnedMemberThen (lhCollection host) (lhCapability host) (build (retirementsFor leases key)) $ \member →
        atomically (register leases key (Holding member))
  case outcome of
    Right () → pure (Right ())
    Left failure@(ExceptionWithContext context _) → do
      notes ← forM (cleanupFailuresInContext context) $ \cleanup → do
        rendered ← renderCaught (cleanupFailureException cleanup)
        pure ("a rollback release failed: " <> cleanupFailureLabel cleanup <> ": " <> rendered)
      atomically $ do
        -- A rollback release that raised leaves the resource's retirement unproven: the reservation
        -- stays charged, failed, and so do the credits beside it. Without one, it is given back (unless a
        -- stage's retirement is pending, which keeps it).
        if null (cleanupFailuresInContext context) then abandon leases key else retainFailed leases key failure
        forM_ notes (noteScope leases number)
      pure (Left failure)

-- | The disposals of one slot whose last retirement has completed, to be run. The slot
-- is kept until they have been, so that a disposal that fails can be retained on it:
-- 'finishDisposals' says how they went.
data Disposals = Disposals
  { disposalsKey ∷ !Word64
  , disposalsInstance ∷ !Word64
  , disposalsActions ∷ ![IO ()]
  }

-- | Record how a slot's disposals went: it is gone when they all succeeded, and holds the
-- failure of the first that did not, which every later release of it answers.
finishDisposals ∷ Leases → Word64 → Maybe (ExceptionWithContext SomeException) → STM ()
finishDisposals leases key failure =
  modifyTVar' (leasesState leases) $ \state →
    state {lsSlots = Map.update settle key (lsSlots state)}
  where
    settle slot = case (failure, slotPhase slot) of
      (Nothing, _) → Nothing
      (Just _, SlotFailed _) → Just slot
      (Just retained, _) → Just slot {slotPhase = SlotFailed retained, slotHolding = Nothing}

-- | A retirement that came to an end.
data RetirementEnd = RetirementEnd
  { endedInstance ∷ !(Maybe Word64)
  , endedLabel ∷ !Text
  , endedFailure ∷ !(Maybe (ExceptionWithContext SomeException))
  }

-- | Read every pending retirement and take away the ones the providers have
-- finished: a completed one gives its charge back, and a failed one is retained on
-- its slot and reported. Answers what ended, and the disposals of the slots whose last
-- retirement has completed, to be run: the disposals of a slot with a failed retirement
-- are kept with it and never run.
--
-- Run on the owner's thread. It never waits: a provider's reading is a transaction
-- that must not retry.
serviceRetirements ∷ Leases → STM ([RetirementEnd], [Disposals])
serviceRetirements leases = do
  state ← readTVar (leasesState leases)
  swept ← forM (Map.toList (lsSlots state)) $ \(key, slot) → do
    (retained, finished', due) ← sweep (isFailed (slotPhase slot)) (slotRetained slot)
    let ended = [(finishedLabel done, finishedFailure done) | done ← finished']
        remaining = retainedObligations retained
        failed = [failure | (_, Just failure) ← ended]
        phase' = case (slotPhase slot, failed) of
          (SlotFailed existing, _) → SlotFailed existing
          (_, failure : _) → SlotFailed failure
          (phase, []) → phase
        slot' = slot {slotRetained = retained, slotPhase = phase'}
        finished = null remaining && isReleased phase'
        completions = [RetirementEnd (Just (slotInstance slot)) label failure | (label, failure) ← ended]
        -- A slot with nothing left to wait for and no failure gives its disposals up, and is
        -- kept until they have been run.
        disposing = not (null due)
        disposals = [Disposals key (slotInstance slot) due | disposing]
        slot'' = slot'
    pure ((key, if finished && not disposing then Nothing else Just slot''), completions, disposals)
  (orphans, endedOrphans') ← pollAll (lsOrphans state)
  let endedOrphans = [(finishedLabel done, finishedFailure done) | done ← endedOrphans']
      ended = concat [completions | (_, completions, _) ← swept] <> [RetirementEnd Nothing label failure | (label, failure) ← endedOrphans]
  writeTVar (leasesState leases) state
    { lsSlots = Map.fromList [(key, slot) | ((key, Just slot), _, _) ← swept]
    , lsOrphans = orphans
    , lsScopes = foldr bumpScope (lsScopes state) ended
    }
  pure (ended, concat [disposals | (_, _, disposals) ← swept])
  where
    -- Counted when the end was already waiting for it: a retirement that completed while
    -- the instance still lived was never waited for.
    bumpScope ended scopes = case (endedInstance ended, endedFailure ended) of
      (Just number, Nothing) → Map.adjust (\scope → if scopeOpen scope then scope else scope {scopeAwaited = scopeAwaited scope + 1}) number scopes
      _ → scopes
    isReleased = \case
      SlotReleased → True
      _ → False
    isFailed = \case
      SlotFailed _ → True
      _ → False

-- | An exception as the bounded line a settlement keeps. Rendering is the exception's
-- own code, which may throw as well: that is rendered too, not raised.
renderCaught ∷ ExceptionWithContext SomeException → IO Text
renderCaught (ExceptionWithContext _ raised) = do
  rendered ← try @SomeException (evaluate (let text = Text.take noteWidth (Text.pack (show raised)) in Text.length text `seq` text))
  case rendered of
    Right text → pure text
    Left failure
      | Just (async ∷ SomeAsyncException) ← fromException failure → throwIO async
      | otherwise → pure "an exception that could not be rendered"

-- | Retry until some pending retirement has been finished by its provider.
retirementsReady ∷ Leases → STM ()
retirementsReady leases = do
  state ← readTVar (leasesState leases)
  let pending = concatMap (retainedObligations . slotRetained) (Map.elems (lsSlots state)) <> lsOrphans state
  readings ← forM pending pollObligation
  when (null [() | reading ← readings, finished reading]) retry
  where
    finished = \case
      ProviderPending → False
      _ → True

-- | Whether any retirement is pending anywhere.
anyPending ∷ Leases → STM Bool
anyPending leases = do
  state ← readTVar (leasesState leases)
  pure (any (retainedPending . slotRetained) (Map.elems (lsSlots state)) || not (null (lsOrphans state)))
