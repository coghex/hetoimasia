-- | A scoped collection of independent resources owned by a capability instead
-- of a thread, each of which can be retired before the scope ends.
--
-- "Hetoimasia.Foundation.Resource.Collection" accepts calls only from the thread
-- that entered its scope. That is the right owner for a window loop, and the
-- wrong one for an owner whose work runs on threads it does not control: a Lua
-- binding's callback runs on a fresh thread for each call while the owner's own
-- thread is blocked inside the Lua call that made it. This collection keeps
-- every guarantee that one gives, and replaces the owner thread with an explicit
-- authority. The existing collection and its contract are unchanged.
--
-- 'allocOwnedCollection' allocates the collection for the rest of the enclosing
-- scope and returns it with its 'OwnerCapability'. Every member operation takes
-- the capability: 'acquireOwnedMember', 'acquireOwnedMemberThen',
-- 'withOwnedMember', 'retireOwnedMember' and 'liveOwnedMemberCount'. The
-- capability is how the owner proves its authority, so it belongs to the owner,
-- and the owner decides who else holds it: 'lendCapability' hands out a
-- capability that is valid for exactly the duration of an action, on whatever
-- thread that action runs. The scope's thread owns the lifetime and nothing
-- else.
--
-- The rules, all enforced before any acquisition or release effect runs:
--
-- * __A valid capability of this collection.__ An operation presenting
--   'noCapability' fails with 'CapabilityMissing'; one issued for another
--   collection with 'CapabilityForeign'; and one whose lending has ended with
--   'CapabilityStale'. The capability a collection is allocated with never
--   goes stale, and after the scope has exited every operation is 'OwnedClosed'.
-- * __One user at a time.__ Operations are serialized: while one thread is
--   inside an operation, an operation presented by a different thread fails with
--   'ConcurrentPresentation' at once. Nothing queues, and nothing is assumed
--   apart. The thread that is inside an operation may make the nested calls the
--   rules below allow.
-- * __A bounded live set.__ The collection holds at most the positive limit it
--   was allocated with; 'OwnedLimitReached' rejects an acquisition beyond it
--   before its 'Assembly' runs. A failed acquisition consumes no capacity, and a
--   retired member frees its slot.
-- * __No reentry while busy.__ An 'Assembly', a release, or a borrowing callback
--   runs user code, which could call back into the same collection. An
--   acquisition, borrow, or retirement made by the running thread while the
--   collection is acquiring, retiring, or closing is rejected with
--   'OwnedReentered'. Borrowing is a separate, lighter state: a borrowing
--   callback may borrow other live members, retiring the member it borrows
--   returns 'RetirementInUse', and acquiring or retiring any other member from
--   inside it is rejected. 'liveOwnedMemberCount' only reads, so the running
--   thread may call it at any time.
-- * __Foreign tokens are misuse.__ A 'Member' presented to a collection that did
--   not issue it fails with 'OwnedForeignMember'.
--
-- Acquisition, retirement, poisoning, cleanup evidence and the exit's failure
-- table are those of "Hetoimasia.Foundation.Resource.Collection", and
-- @docs/resources.md@ states them once for both. In short: an acquisition runs
-- its 'Assembly' under the staged protection of
-- 'Hetoimasia.Foundation.Resource.withComposite', registers the finished release
-- while still masked, and only then returns the token, and
-- 'acquireOwnedMemberThen' runs its handoff in that same masked step. A
-- retirement claims a member's release exactly once and makes the member
-- terminal, answering 'AlreadyRetired' or rethrowing the stored failure without
-- calling the release again. A release failure poisons further acquisition and
-- is latched, so the scope's exit follows the failure table of
-- 'Hetoimasia.Foundation.Resource.withResource'.
--
-- = Leaving the scope
--
-- The scope's exit is serialized with the operations like any other user. It
-- first closes admission: from then on an operation made on any thread is
-- rejected with @'OwnedReentered' 'Closing'@, and nothing new begins. The one
-- exception is the thread running the exit, which may still call
-- 'liveOwnedMemberCount' (a release at exit can inspect the collection it is
-- being released from, as one of the thread-owned collection's can); no other
-- thread may. It then
-- waits for the operation that was already admitted, an acquisition, a handoff,
-- a borrow or a retirement, to finish, and only then releases the live members,
-- newest first, each member's parts in the order its 'Assembly' declared. The
-- wait is uninterruptible, because no member can be released safely under a
-- user of the collection and a cancellation of the scope must not abandon one
-- (@docs/vision.md@: retain resources until safe release is established). It is
-- the price of a collection other threads can use: an operation that never
-- returns holds its scope's exit, and an operation is bounded user code, like a
-- release, which a scope also waits for. Once the exit has run, every operation
-- is rejected with 'OwnedClosed'.
--
-- A borrowed value follows the borrowing contract of
-- 'Hetoimasia.Foundation.Resource.withResource': it must not escape the
-- callback. A 'Member' is an identity that owns nothing, so it may be retained
-- past retirement and past the scope, where 'memberStatus' still reports its
-- terminal state.
--
-- Members must be independent. A dependency shared by members belongs outside
-- the collection's scope, and a dependency between two members belongs in one
-- composite or another explicit owner.
--
-- = State
--
-- Every piece of state this module holds, all of it private to one collection:
--
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | State             | Owner            | Readers, writers   | Thread    | Lifetime           | Reset or disposal   |
-- +===================+==================+====================+===========+====================+=====================+
-- | Gate: admission   | The collection   | Every operation    | Any       | The scope          | Shut at exit;       |
-- | and the thread    |                  | enters and leaves  |           |                    | never reopened      |
-- | inside            |                  | it; exit closes it |           |                    |                     |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Capability        | The capability   | Read by every      | Any       | Allocation, or one | Cleared when the    |
-- | validity          | and its lender   | operation; cleared |           | lending            | lending ends; the   |
-- |                   |                  | by the lending     |           |                    | original never      |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Phase             | The collection   | Every operation    | The one   | The scope          | Closed at exit;     |
-- |                   |                  | reads it; acquire, | inside    |                    | never reopened      |
-- |                   |                  | retire, and exit   |           |                    |                     |
-- |                   |                  | write it           |           |                    |                     |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Active borrows    | The collection   | 'withOwnedMember'  | The one   | The scope          | Each borrow drops   |
-- |                   |                  | writes; acquire    | inside    |                    | its count on every  |
-- |                   |                  | and retire read    |           |                    | exit                |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Member identity   | The collection   | 'acquireOwned-     | The one   | The scope          | Monotone; never     |
-- | counter           |                  | Member'            | inside    |                    | reused              |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Live-member       | The collection   | Acquire inserts;   | The one   | Registration until | Entry removed at    |
-- | ledger            |                  | retire and exit    | inside    | retirement or exit | retirement; emptied |
-- |                   |                  | remove             |           |                    | at exit             |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Latched cleanup   | The collection   | Written by failed  | The one   | First failure      | Handed to the exit  |
-- | failures          |                  | retirements and    | inside    | until exit         | outcome and cleared |
-- |                   |                  | rollbacks; read by |           |                    |                     |
-- |                   |                  | acquire and exit   |           |                    |                     |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Member state:     | The collection   | Borrows read the   | The one   | Registration until | Replaced by a       |
-- | value, release,   | while live       | value; retire and  | inside    | retirement or exit | terminal state      |
-- | borrow count      |                  | exit take the      |           |                    | holding no value or |
-- |                   |                  | release            |           |                    | release             |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Terminal member   | Whoever retains  | 'memberStatus'     | Any       | As long as the     | Immutable; a failed |
-- | state             | the token        |                    |           | token is retained  | state keeps only    |
-- |                   |                  |                    |           |                    | its exception       |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
--
-- The gate is what makes the unprotected references safe: only the thread inside
-- an operation, or the exit once it has drained the gate, touches the phase, the
-- counters, the ledger, the latched failures and a live member's state, and the
-- gate's transitions order those accesses between threads. None of this is
-- application state. Owner-side bookkeeping is proportional to the live members,
-- not to the number ever acquired.
--
-- The representations of that state are defined in the library's hidden
-- "Hetoimasia.Foundation.Resource.OwnedCollection.Types" and, for the member
-- token and results, "Hetoimasia.Foundation.Resource.Collection.Types"; this
-- module owns every operation that creates, reads, or writes them, and
-- re-exports the types.
--
-- This module takes no logger and imports no logging, runtime, messaging,
-- scripting, or native windowing module. It is built through the foundation's
-- package-private resource facade, "Hetoimasia.Foundation.Resource.Internal", so
-- neither 'Scoped' nor a composite's release is exposed, and every type is
-- exported closed.
--
-- See @docs/resources.md@, "Capability-owned resource collections", for the same
-- contract in prose.
module Hetoimasia.Foundation.Resource.OwnedCollection
  ( -- * Collection lifetime
    OwnedCollection
  , allocOwnedCollection
  , liveOwnedMemberCount

    -- * The capability
  , OwnerCapability
  , noCapability
  , lendCapability

    -- * Members
  , Member
  , acquireOwnedMember
  , acquireOwnedMemberThen
  , withOwnedMember
  , retireOwnedMember
  , Retirement (..)
  , memberStatus
  , MemberStatus (..)

    -- * Rejections
  , OwnedCollectionError (..)
  , Activity (..)
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM
  ( STM
  , atomically
  , check
  , modifyTVar'
  , newTVarIO
  , readTVar
  , writeTVar
  )
import Control.Exception
  ( ExceptionWithContext
  , SomeException
  , finally
  , mask
  , mask_
  , rethrowIO
  , throwIO
  , uninterruptibleMask_
  )
import Control.Monad (unless, when)
import Data.Foldable (traverse_)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import Data.Unique (newUnique)
import Hetoimasia.Foundation.Resource.Collection.Types
  ( Activity (..)
  , LiveMember (..)
  , Member (..)
  , MemberId (..)
  , MemberState (..)
  , MemberStatus (..)
  , Phase (..)
  , Retirement (..)
  )
import Hetoimasia.Foundation.Resource.Internal
  ( Assembly
  , CleanupFailure
  , Scoped (Scoped)
  , assembleSeparately
  , cleanupFailureException
  , releaseAcquired
  , retainCleanupFailures
  , tryScope
  )
import Hetoimasia.Foundation.Resource.OwnedCollection.Types
  ( Admission (..)
  , Gate (..)
  , OwnedCollection (..)
  , OwnedCollectionError (..)
  , OwnerCapability (..)
  )

-- | Allocate a collection holding at most @limit@ live members for the rest of
-- the enclosing scope, with the capability that owns it.
--
-- A limit below one is rejected with 'OwnedInvalidMemberLimit' before the
-- collection exists. The capability is valid until the scope exits.
--
-- When the enclosing continuation returns or throws, admission closes, the
-- operation already admitted, if any, finishes, and every live member is
-- released, newest registration first, each attempted exactly once. The outcome
-- follows the failure table: a successful body with no cleanup failure returns
-- its result; a successful body with a latched or final cleanup failure fails
-- with the first of them, retaining all; a failing or cancelled body propagates
-- its own exception, retaining all.
allocOwnedCollection ∷ Int → Scoped (OwnedCollection, OwnerCapability)
allocOwnedCollection limit = Scoped $ \continue → do
  when (limit < 1) (throwIO (OwnedInvalidMemberLimit limit))
  mask $ \restore → do
    allocated ← newOwnedCollection limit
    outcome ← tryScope (restore (continue allocated))
    failures ← closeOwnedCollection (fst allocated)
    case (outcome, failures) of
      (Right result, []) → pure result
      (Right _, first : _) →
        rethrowIO (retainCleanupFailures failures (cleanupFailureException first))
      (Left primary, _) → rethrowIO (retainCleanupFailures failures primary)

-- | What presenting no authority looks like. Every operation refuses it with
-- 'CapabilityMissing', before any effect.
noCapability ∷ OwnerCapability
noCapability = NoCapability

-- | Lend a capability for the duration of an action.
--
-- The capability the action receives is a different one from the one it was
-- derived from, valid for this action and no longer. It can be used on whatever
-- thread the action gives it to, and it is revoked on every exit from the
-- action, whether it returns, raises, or is cancelled: any later use of it, or
-- of a copy of it, fails with 'CapabilityStale' before any effect. An operation
-- it admitted before the revocation is not interrupted; revocation prevents
-- further admissions. The capability lent from is untouched.
--
-- The capability to lend from must itself be valid: 'noCapability' fails with
-- 'CapabilityMissing' and a stale one with 'CapabilityStale', before the action
-- runs. Whether it belongs to a particular collection is checked, as always, when
-- the lent capability is presented. The action runs with the caller's masking
-- state.
lendCapability ∷ OwnerCapability → (OwnerCapability → IO r) → IO r
lendCapability parent action = mask $ \restore → do
  refusal ← atomically (capabilityRefusal parent)
  traverse_ throwIO refusal
  case parent of
    NoCapability → throwIO CapabilityMissing
    OwnerCapability issuer _ → do
      flag ← newTVarIO True
      restore (action (OwnerCapability issuer flag))
        `finally` atomically (writeTVar flag False)

-- | The number of members currently live. Rejected with 'OwnedClosed' once the
-- collection's scope has exited. Reading it while the collection is busy changes
-- nothing, so the thread inside an operation may call it, and so may the thread
-- running the scope's exit while it releases members; another thread is refused
-- with 'ConcurrentPresentation', or with @'OwnedReentered' 'Closing'@ once the
-- exit has begun.
liveOwnedMemberCount ∷ OwnedCollection → OwnerCapability → IO Int
liveOwnedMemberCount collection capability =
  mask_ . inGate collection capability Reading $
    Map.size <$> readIORef (ownedLive collection)

-- | Build one member from an 'Assembly' and register it.
--
-- The capability, the gate, the collection's phase, any active borrow,
-- poisoning, and the live-member limit are checked in that order before the
-- assembly runs. Each part's label and rank are evaluated at that part's own
-- stage, as in 'Hetoimasia.Foundation.Resource.withComposite'.
--
-- A failing stage rolls back exactly the parts acquired so far and propagates
-- its failure with their cleanup failures retained; no member is registered and
-- no capacity is consumed. A rollback release that failed also poisons the
-- collection. The token is returned only after registration.
acquireOwnedMember ∷ OwnedCollection → OwnerCapability → Assembly a → IO (Member a)
acquireOwnedMember collection capability assembly =
  acquireOwnedMemberThen collection capability assembly pure

-- | 'acquireOwnedMember', then hand the token to @handoff@ before returning, in
-- the masked step that registered it.
--
-- The assembly runs with the caller's masking state, exactly as in
-- 'acquireOwnedMember', so a cancellation during construction rolls it back and
-- registers nothing. Once the member is registered, @handoff@ runs masked with no
-- interruptible operation before it, so an owner can record the token in its own
-- bookkeeping without a cancellation landing between the two registrations.
-- @handoff@ must not block: a blocking operation inside it is interruptible, and
-- it holds the collection's gate. It may borrow members. If it raises, the
-- member stays registered, the collection's exit releases it, and the failure
-- propagates.
acquireOwnedMemberThen
  ∷ OwnedCollection → OwnerCapability → Assembly a → (Member a → IO b) → IO b
acquireOwnedMemberThen collection capability assembly handoff = mask $ \restore →
  inGate collection capability Mutating $ do
    requireOpen collection
    requireNoBorrow collection
    latched ← readIORef (ownedLatched collection)
    unless (null latched) (throwIO OwnedPoisoned)
    live ← readIORef (ownedLive collection)
    when (Map.size live >= ownedLimit collection) $
      throwIO (OwnedLimitReached (ownedLimit collection))
    identifier ← atomicModifyIORef' (ownedNextMember collection) $ \issued →
      (issued + 1, MemberId issued)
    writeIORef (ownedPhase collection) (PhaseBusy Acquiring)
    built ← assembleSeparately restore assembly
    writeIORef (ownedPhase collection) PhaseOpen
    case built of
      Left (primary, failures) → do
        latch collection failures
        rethrowIO (retainCleanupFailures failures primary)
      Right (ledger, value) → do
        -- Still masked, and nothing below is interruptible: the release is
        -- registered before the token exists.
        state ← newIORef (MemberHeld value ledger 0)
        modifyIORef' (ownedLive collection) (Map.insert identifier (LiveMember state))
        handoff (Member (ownedIdentity collection) identifier state)

-- | Lend a live member's value to a callback.
--
-- The capability, the token's collection, the phase, and liveness are checked
-- first; a retired member is 'OwnedMemberNotLive'. The callback runs with the
-- caller's masking state, may borrow other live members, and must not let the
-- value escape. The borrow is dropped on every exit from the callback. The gate
-- is held for the borrow's whole duration, so another thread presenting the
-- capability meanwhile is refused with 'ConcurrentPresentation', and the
-- collection's exit waits for the borrow to end.
withOwnedMember
  ∷ OwnedCollection → OwnerCapability → Member a → (a → IO r) → IO r
withOwnedMember collection capability member@(Member _ _ state) action = mask $ \restore →
  inGate collection capability Mutating $ do
    requireOwnMember collection member
    requireOpen collection
    held ← readIORef state
    case held of
      MemberHeld value ledger borrows → do
        writeIORef state (MemberHeld value ledger (borrows + 1))
        modifyIORef' (ownedBorrows collection) (+ 1)
        outcome ← tryScope (restore (action value))
        modifyIORef' (ownedBorrows collection) (subtract 1)
        modifyIORef' state dropBorrow
        either rethrowIO pure outcome
      _ → throwIO OwnedMemberNotLive
  where
    dropBorrow (MemberHeld value ledger borrows) = MemberHeld value ledger (borrows - 1)
    dropBorrow terminal = terminal

-- | Release one member before the collection's scope ends.
--
-- After the capability, the token's collection, and the phase are checked, a
-- member that a running callback borrows answers 'RetirementInUse'. While any
-- callback is borrowing, retiring any other member, live or already terminal, is
-- rejected with @'OwnedReentered' 'Borrowing'@. Otherwise a terminal member
-- answers from its stored state: 'AlreadyRetired' after a successful release, or
-- its stored failure rethrown after a failed one. A live member leaves the ledger
-- and its parts are released in their declared order, each exactly once and
-- uninterruptibly.
--
-- A release that fails leaves the member in a failed terminal state, poisons and
-- latches the collection, and propagates the first cleanup failure's exception
-- with every cleanup failure retained.
retireOwnedMember ∷ OwnedCollection → OwnerCapability → Member a → IO Retirement
retireOwnedMember collection capability member@(Member _ identifier state) =
  mask_ . inGate collection capability Mutating $ do
    requireOwnMember collection member
    requireOpen collection
    held ← readIORef state
    case held of
      MemberHeld _ _ borrows | borrows > 0 → pure RetirementInUse
      _ → do
        requireNoBorrow collection
        retireUnborrowed held
  where
    retireUnborrowed held = case held of
      MemberReleased → pure AlreadyRetired
      MemberReleaseFailed failure → rethrowIO failure
      MemberHeld _ ledger _ → do
        writeIORef (ownedPhase collection) (PhaseBusy Retiring)
        modifyIORef' (ownedLive collection) (Map.delete identifier)
        failures ← releaseAcquired ledger
        settled ← settle state failures
        latch collection failures
        writeIORef (ownedPhase collection) PhaseOpen
        maybe (pure Retired) rethrowIO settled

-- | A member's state, readable from any thread and after the collection has
-- exited. A terminal state never changes.
memberStatus ∷ Member a → IO MemberStatus
memberStatus (Member _ _ state) = do
  held ← readIORef state
  pure $ case held of
    MemberHeld {} → MemberLive
    MemberReleased → MemberRetired
    MemberReleaseFailed failure → MemberRetirementFailed failure

newOwnedCollection ∷ Int → IO (OwnedCollection, OwnerCapability)
newOwnedCollection limit = do
  identity ← newUnique
  collection ←
    OwnedCollection identity limit
      <$> newTVarIO (Gate Admitting Nothing Nothing)
      <*> newIORef PhaseOpen
      <*> newIORef 0
      <*> newIORef 0
      <*> newIORef Map.empty
      <*> newIORef []
  capability ← OwnerCapability identity <$> newTVarIO True
  pure (collection, capability)

-- | Close admission, wait for the operation already admitted, then release every
-- live member, newest registration first. The caller is masked. Returns every
-- cleanup failure the collection observed, latched ones first, in observation
-- order.
--
-- The wait is uninterruptible: the members cannot be released under a user of
-- the collection, and a cancellation of the scope must not abandon the release.
closeOwnedCollection ∷ OwnedCollection → IO [CleanupFailure]
closeOwnedCollection collection = do
  self ← myThreadId
  atomically (modifyTVar' (ownedGate collection) (\gate → gate {gateAdmission = Draining, gateExiting = Just self}))
  uninterruptibleMask_ . atomically $ do
    gate ← readTVar (ownedGate collection)
    check (isNothing (gateHolder gate))
  writeIORef (ownedPhase collection) (PhaseBusy Closing)
  live ← atomicModifyIORef' (ownedLive collection) (Map.empty,)
  drained ← traverse (releaseAtExit . snd) (Map.toDescList live)
  latched ← atomicModifyIORef' (ownedLatched collection) ([],)
  writeIORef (ownedPhase collection) PhaseClosed
  atomically (modifyTVar' (ownedGate collection) (\gate → gate {gateAdmission = Shut}))
  pure (reverse latched <> concat drained)
  where
    releaseAtExit (LiveMember state) = do
      held ← readIORef state
      case held of
        MemberHeld _ ledger _ → do
          failures ← releaseAcquired ledger
          _ ← settle state failures
          pure failures
        _ → pure []

-- | Record a member's terminal state from the failures its release produced,
-- returning the failure a retirement propagates, if any.
settle
  ∷ IORef (MemberState a)
  → [CleanupFailure]
  → IO (Maybe (ExceptionWithContext SomeException))
settle state failures = case failures of
  [] → Nothing <$ writeIORef state MemberReleased
  first : _ → do
    let failure = retainCleanupFailures failures (cleanupFailureException first)
    Just failure <$ writeIORef state (MemberReleaseFailed failure)

latch ∷ OwnedCollection → [CleanupFailure] → IO ()
latch collection failures =
  modifyIORef' (ownedLatched collection) (reverse failures <>)

-- | What an operation does to the collection.
data Access
  = -- | It changes the collection, or lends its members.
    Mutating
  | -- | It only reads, and so the thread running the scope's exit may make it.
    Reading

-- | Run an operation as the collection's one active user, admitting it first and
-- leaving on every exit. The caller is masked.
--
-- Admission reads the capability and the gate in one transaction, so a
-- capability cannot be revoked between its check and the operation's entry. A
-- refusal is raised before the operation has any effect. A read by the exiting
-- thread is admitted without holding the gate, since the exit is the only user
-- by then.
inGate ∷ OwnedCollection → OwnerCapability → Access → IO a → IO a
inGate collection capability access operation = do
  self ← myThreadId
  admitted ← atomically (admit collection capability access self)
  case admitted of
    Left refusal → throwIO refusal
    Right True → operation `finally` leave collection
    Right False → operation

-- | Why a capability is not valid for this collection, if it is not.
capabilityRefusal ∷ OwnerCapability → STM (Maybe OwnedCollectionError)
capabilityRefusal capability = case capability of
  NoCapability → pure (Just CapabilityMissing)
  OwnerCapability _ flag → do
    valid ← readTVar flag
    pure (if valid then Nothing else Just CapabilityStale)

-- | Admit one operation of the thread @self@, or say why not. Answers whether it
-- now holds the gate. Writes only when it admits and holds.
admit
  ∷ OwnedCollection
  → OwnerCapability
  → Access
  → ThreadId
  → STM (Either OwnedCollectionError Bool)
admit collection capability access self = case capability of
  OwnerCapability issuer _
    | issuer /= ownedIdentity collection → pure (Left CapabilityForeign)
  _ → do
    refused ← capabilityRefusal capability
    case refused of
      Just refusal → pure (Left refusal)
      Nothing → do
        gate ← readTVar (ownedGate collection)
        case gateAdmission gate of
          Shut → pure (Left OwnedClosed)
          Draining → pure $ case access of
            Reading | gateExiting gate == Just self → Right False
            _ → Left (OwnedReentered Closing)
          Admitting → case gateHolder gate of
            Nothing → Right True <$ writeTVar (ownedGate collection) gate {gateHolder = Just (self, 1)}
            Just (holder, depth)
              | holder == self ->
                  Right True <$ writeTVar (ownedGate collection) gate {gateHolder = Just (self, depth + 1)}
              | otherwise → pure (Left ConcurrentPresentation)

-- | Leave one operation: the thread's nesting drops by one, and the gate is free
-- once it is back to none.
leave ∷ OwnedCollection → IO ()
leave collection = atomically . modifyTVar' (ownedGate collection) $ \gate →
  case gateHolder gate of
    Just (thread, depth) | depth > 1 → gate {gateHolder = Just (thread, depth - 1)}
    _ → gate {gateHolder = Nothing}

requireOwnMember ∷ OwnedCollection → Member a → IO ()
requireOwnMember collection (Member issuer _ _) =
  when (issuer /= ownedIdentity collection) (throwIO OwnedForeignMember)

requireOpen ∷ OwnedCollection → IO ()
requireOpen collection = do
  phase ← readIORef (ownedPhase collection)
  case phase of
    PhaseOpen → pure ()
    PhaseBusy activity → throwIO (OwnedReentered activity)
    PhaseClosed → throwIO OwnedClosed

requireNoBorrow ∷ OwnedCollection → IO ()
requireNoBorrow collection = do
  borrows ← readIORef (ownedBorrows collection)
  when (borrows > 0) (throwIO (OwnedReentered Borrowing))
