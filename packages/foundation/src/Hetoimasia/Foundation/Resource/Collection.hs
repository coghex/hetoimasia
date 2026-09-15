{-# LANGUAGE RoleAnnotations #-}

-- | A scoped collection of independent resources owned by one thread, each of
-- which can be retired before the scope ends.
--
-- Every other lifetime "Hetoimasia.Foundation.Resource" offers is lexical: a
-- resource lives until its enclosing 'withScoped' continuation ends, and
-- 'Hetoimasia.Foundation.Resource.locally' ends a whole inner group at once. A
-- 'Collection' is for resources whose lifetimes end when the application
-- decides — windows created while running and closed in any order — without
-- giving up the scope as their final owner.
--
-- 'allocCollection' allocates the collection for the rest of the enclosing
-- scope. 'acquireMember' builds one member from an ordinary 'Assembly' and
-- returns an opaque 'Member' token, and 'acquireMemberThen' also hands that
-- token to an owner's registration before any cancellation can intervene;
-- 'withMember' lends that member's value to a
-- callback; 'retireMember' releases it early. Whatever is still live when the
-- scope ends is released then, newest registration first, each member's parts
-- in the order its 'Assembly' declared with
-- 'Hetoimasia.Foundation.Resource.releaseRank'. The collection cannot outlive
-- its scope: once that exit has run, every operation on it is rejected with
-- 'CollectionClosed'.
--
-- The rules, all enforced before any acquisition or release effect runs:
--
-- * __One owner thread.__ The thread that entered the scope owns the
--   collection. 'acquireMember', 'withMember', 'retireMember', and
--   'liveMemberCount' called from any other thread fail with
--   'NotOwnerThread'. Only 'memberStatus', which reads a token's own terminal
--   state, may be called from anywhere.
-- * __A bounded live set.__ The collection holds at most the positive limit it
--   was allocated with; 'MemberLimitReached' rejects an acquisition beyond it
--   before its 'Assembly' runs. A failed acquisition consumes no capacity, and
--   a retired member frees its slot.
-- * __No reentry while busy.__ An 'Assembly', a release, or a borrowing
--   callback runs user code on the owner thread, which could call back into
--   the same collection. An acquisition, borrow, or retirement made while that
--   collection is acquiring, retiring, or closing is rejected with
--   'CollectionReentered'. Borrowing is a separate, lighter state: a borrowing
--   callback may borrow other live members, retiring the member it borrows
--   returns 'RetirementInUse', and acquiring or retiring any other member from
--   inside it is rejected.
-- * __Foreign tokens are misuse.__ A 'Member' presented to a collection that
--   did not issue it fails with 'ForeignMember'.
--
-- An acquisition runs its 'Assembly' under the same staged protection as
-- 'Hetoimasia.Foundation.Resource.withComposite': a failing stage rolls back
-- exactly the parts acquired so far and propagates its own failure with the
-- ordered cleanup evidence retained beside it, and no member is registered.
-- On success the finished release is registered in the collection while still
-- masked, with no interruptible operation in between, and only then is the
-- token returned. A cancellation arriving at that handoff leaves a registered
-- member that the scope's exit releases. An owner that must record the token in
-- its own bookkeeping uses 'acquireMemberThen', whose handoff runs in that same
-- masked step, so no cancellation separates the collection's registration from
-- the owner's.
--
-- Retirement claims a member's release exactly once and makes the member
-- terminal. Retiring it again returns 'AlreadyRetired' if the release
-- succeeded, and rethrows the stored failure — the same exception, context,
-- and cleanup identities — without calling the release again if it failed.
--
-- Any release failure poisons the collection: an early retirement that threw,
-- a rollback release that threw during a failed acquisition, or both. Further
-- acquisition is rejected with 'CollectionPoisoned', while live members stay
-- borrowable and retirable. The failure is also latched, so catching the
-- exception an early retirement threw cannot make the scope succeed: at exit,
-- with a successful body, the first latched cleanup failure is primary and
-- every cleanup failure is retained beside it; with a failing or cancelled
-- body that exception stays primary with the same evidence retained. This is
-- the failure table of 'Hetoimasia.Foundation.Resource.withResource' applied
-- to everything the collection released. A construction failure whose rollback
-- succeeded does not poison.
--
-- A borrowed value follows the borrowing contract of
-- 'Hetoimasia.Foundation.Resource.withResource': it must not escape the
-- callback. A 'Member' is not a borrowed value. It is an identity that owns
-- nothing, so it may be retained past retirement and past the scope, where
-- 'memberStatus' still reports its terminal state; it holds neither the
-- collection nor the member's value.
--
-- Members must be independent. A dependency shared by members belongs outside
-- the collection's scope, and a dependency between two members belongs in one
-- composite or another explicit owner.
--
-- = State
--
-- Following the module authoring guide, every piece of state this module
-- holds, all of it private to one collection:
--
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | State             | Owner            | Readers, writers   | Thread    | Lifetime           | Reset or disposal   |
-- +===================+==================+====================+===========+====================+=====================+
-- | Phase             | The collection   | Every operation    | Owner     | The scope          | Closed at exit;     |
-- |                   |                  | reads it; acquire, |           |                    | never reopened      |
-- |                   |                  | retire, and exit   |           |                    |                     |
-- |                   |                  | write it           |           |                    |                     |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Active borrows    | The collection   | 'withMember'       | Owner     | The scope          | Each borrow drops   |
-- |                   |                  | writes; acquire    |           |                    | its count on every  |
-- |                   |                  | and retire read    |           |                    | exit                |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Member identity   | The collection   | 'acquireMember'    | Owner     | The scope          | Monotone; never     |
-- | counter           |                  |                    |           |                    | reused              |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Live-member       | The collection   | 'acquireMember'    | Owner     | Registration until | Entry removed at    |
-- | ledger            |                  | inserts; retire    |           | retirement or exit | retirement; emptied |
-- |                   |                  | and exit remove    |           |                    | at exit             |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Latched cleanup   | The collection   | Written by failed  | Owner     | First failure      | Handed to the exit  |
-- | failures          |                  | retirements and    |           | until exit         | outcome and cleared |
-- |                   |                  | rollbacks; read by |           |                    |                     |
-- |                   |                  | acquire and exit   |           |                    |                     |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Member state:     | The collection   | Borrows read the   | Owner     | Registration until | Replaced by a       |
-- | value, release,   | while live       | value; retire and  |           | retirement or exit | terminal state      |
-- | borrow count      |                  | exit take the      |           |                    | holding no value or |
-- |                   |                  | release            |           |                    | release             |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
-- | Terminal member   | Whoever retains  | 'memberStatus'     | Any       | As long as the     | Immutable; a failed |
-- | state             | the token        |                    |           | token is retained  | state keeps only    |
-- |                   |                  |                    |           |                    | its exception       |
-- +-------------------+------------------+--------------------+-----------+--------------------+---------------------+
--
-- None of this is application state. Owner-side bookkeeping is proportional to
-- the live members, not to the number ever acquired.
--
-- This module takes no logger and imports no logging, runtime, messaging, or
-- native windowing module. It is built through the foundation library's hidden
-- implementation seam, so neither 'Scoped' nor a composite's release is
-- exposed, and every type is exported closed.
--
-- See @docs/resources.md@, "Scoped resource collections", for the same
-- contract in prose.
module Hetoimasia.Foundation.Resource.Collection
  ( -- * Collection lifetime
    Collection
  , allocCollection
  , liveMemberCount

    -- * Members
  , Member
  , acquireMember
  , acquireMemberThen
  , withMember
  , retireMember
  , Retirement (..)
  , memberStatus
  , MemberStatus (..)

    -- * Rejections
  , CollectionError (..)
  , Activity (..)
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Exception
  ( Exception
  , ExceptionWithContext
  , SomeException
  , mask
  , mask_
  , rethrowIO
  , throwIO
  )
import Control.Monad (unless, when)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Unique (Unique, newUnique)
import Data.Word (Word64)
import Hetoimasia.Foundation.Resource.Internal
  ( Assembly
  , CleanupFailure
  , Ledger
  , Scoped (Scoped)
  , assembleSeparately
  , cleanupFailureException
  , releaseAcquired
  , retainCleanupFailures
  , tryScope
  )

-- | A scoped owner of independently retired members.
--
-- The type is exported without its constructor. A collection is obtained only
-- from 'allocCollection' and is valid only inside the continuation that
-- allocated it.
data Collection = Collection
  { collectionIdentity ∷ !Unique
  , collectionOwner ∷ !ThreadId
  , collectionLimit ∷ !Int
  , collectionPhase ∷ !(IORef Phase)
  , collectionBorrows ∷ !(IORef Int)
  , collectionNextMember ∷ !(IORef Word64)
  , collectionLive ∷ !(IORef (Map MemberId LiveMember))
  , collectionLatched ∷ !(IORef [CleanupFailure])
    -- ^ Newest first.
  }

-- | What the collection is doing on its owner thread. Borrowing is tracked
-- separately, because a borrow does not exclude another borrow.
data Phase
  = PhaseOpen
  | PhaseBusy !Activity
  | PhaseClosed

-- | Identity of one member within its collection, in registration order.
newtype MemberId = MemberId Word64
  deriving (Eq, Ord)

-- | The collection's reference to a live member's state, whatever its type.
data LiveMember = ∀ a. LiveMember !(IORef (MemberState a))

-- | One member's state. The value is deliberately lazy: forcing it during
-- registration could throw after construction succeeded and before its
-- release was registered.
data MemberState a
  = MemberHeld a !Ledger !Int
  | MemberReleased
  | MemberReleaseFailed !(ExceptionWithContext SomeException)

-- | An opaque token for one member of one collection.
--
-- It carries the issuing collection's identity, the member's identity, and a
-- reference to that member's state, and nothing else: not the collection, and
-- once the member is terminal, not its value or its release. The type is
-- exported without its constructor, and its parameter is nominal, so a token
-- cannot be coerced into a token for a different type sharing a
-- representation.
data Member a = Member !Unique !MemberId !(IORef (MemberState a))

type role Member nominal

-- | What one call to 'retireMember' did.
data Retirement
  = -- | The release was attempted now and succeeded.
    Retired
  | -- | The member was already retired successfully; nothing ran.
    AlreadyRetired
  | -- | The member is borrowed by a callback still running; nothing ran.
    RetirementInUse
  deriving (Eq, Show)

-- | A member's state as seen through its token.
data MemberStatus
  = MemberLive
  | -- | Released successfully, early or at the collection's exit.
    MemberRetired
  | -- | Its release was attempted and failed, early or at the collection's
    -- exit. The exception is the one that retirement propagated or retained,
    -- with its context and cleanup evidence.
    MemberRetirementFailed (ExceptionWithContext SomeException)

-- | A rejected collection operation. Every rejection is raised before the
-- operation has any acquisition, borrowing, or release effect.
data CollectionError
  = -- | 'allocCollection' was given a limit below one.
    InvalidMemberLimit !Int
  | -- | The calling thread is not the thread that entered the collection's scope.
    NotOwnerThread
  | -- | The token was issued by a different collection.
    ForeignMember
  | -- | The collection was already doing this when the call re-entered it.
    CollectionReentered !Activity
  | -- | The collection's scope has exited.
    CollectionClosed
  | -- | An acquisition would exceed the live-member limit, which is carried.
    MemberLimitReached !Int
  | -- | A release failure has poisoned further acquisition.
    CollectionPoisoned
  | -- | The member has been retired, so it cannot be borrowed.
    MemberNotLive
  deriving (Eq, Show)

instance Exception CollectionError

-- | What a collection was doing when an operation re-entered it.
data Activity
  = Acquiring
  | Borrowing
  | Retiring
  | Closing
  deriving (Eq, Show)

-- | Allocate a collection holding at most @limit@ live members for the rest of
-- the enclosing scope.
--
-- A limit below one is rejected with 'InvalidMemberLimit' before the
-- collection exists. The thread entering the scope becomes its owner.
--
-- When the enclosing continuation returns or throws, admission closes and
-- every live member is released, newest registration first, each attempted
-- exactly once. The outcome follows the failure table: a successful body with
-- no cleanup failure returns its result; a successful body with a latched or
-- final cleanup failure fails with the first of them, retaining all; a failing
-- or cancelled body propagates its own exception, retaining all.
allocCollection ∷ Int → Scoped Collection
allocCollection limit = Scoped $ \continue → do
  when (limit < 1) (throwIO (InvalidMemberLimit limit))
  mask $ \restore → do
    collection ← newCollection limit
    outcome ← tryScope (restore (continue collection))
    failures ← closeCollection collection
    case (outcome, failures) of
      (Right result, []) → pure result
      (Right _, first : _) →
        rethrowIO (retainCleanupFailures failures (cleanupFailureException first))
      (Left primary, _) → rethrowIO (retainCleanupFailures failures primary)

-- | The number of members currently live. Owner thread only; rejected with
-- 'CollectionClosed' once the collection's scope has exited. Reading it while
-- the collection is busy changes nothing, so it is not a reentry.
liveMemberCount ∷ Collection → IO Int
liveMemberCount collection = do
  requireOwner collection
  phase ← readIORef (collectionPhase collection)
  case phase of
    PhaseClosed → throwIO CollectionClosed
    _ → Map.size <$> readIORef (collectionLive collection)

-- | Build one member from an 'Assembly' and register it.
--
-- The owner thread, the collection's phase, any active borrow, poisoning, and
-- the live-member limit are checked in that order before the assembly runs.
-- Each part's label and rank are evaluated at that part's own stage, as in
-- 'Hetoimasia.Foundation.Resource.withComposite'.
--
-- A failing stage rolls back exactly the parts acquired so far and propagates
-- its failure with their cleanup failures retained; no member is registered
-- and no capacity is consumed. A rollback release that failed also poisons
-- the collection. The token is returned only after registration.
acquireMember ∷ Collection → Assembly a → IO (Member a)
acquireMember collection assembly = acquireMemberThen collection assembly pure

-- | 'acquireMember', then hand the token to @handoff@ before returning, in the
-- masked step that registered it.
--
-- The assembly runs with the caller's masking state, exactly as in
-- 'acquireMember', so a cancellation during construction rolls it back and
-- registers nothing. Once the member is registered, @handoff@ runs masked with
-- no interruptible operation before it, so an owner can record the token in its
-- own bookkeeping without a cancellation landing between the two
-- registrations. @handoff@ must not block: a blocking operation inside it is
-- interruptible. It may borrow members. If it raises, the member stays
-- registered, the collection's exit releases it, and the failure propagates.
acquireMemberThen ∷ Collection → Assembly a → (Member a → IO b) → IO b
acquireMemberThen collection assembly handoff = mask $ \restore → do
  requireOwner collection
  requireOpen collection
  requireNoBorrow collection
  latched ← readIORef (collectionLatched collection)
  unless (null latched) (throwIO CollectionPoisoned)
  live ← readIORef (collectionLive collection)
  when (Map.size live >= collectionLimit collection) $
    throwIO (MemberLimitReached (collectionLimit collection))
  identifier ← atomicModifyIORef' (collectionNextMember collection) $ \issued →
    (issued + 1, MemberId issued)
  writeIORef (collectionPhase collection) (PhaseBusy Acquiring)
  built ← assembleSeparately restore assembly
  writeIORef (collectionPhase collection) PhaseOpen
  case built of
    Left (primary, failures) → do
      latch collection failures
      rethrowIO (retainCleanupFailures failures primary)
    Right (ledger, value) → do
      -- Still masked, and nothing below is interruptible: the release is
      -- registered before the token exists.
      state ← newIORef (MemberHeld value ledger 0)
      modifyIORef' (collectionLive collection) (Map.insert identifier (LiveMember state))
      handoff (Member (collectionIdentity collection) identifier state)

-- | Lend a live member's value to a callback.
--
-- The owner thread, the token's collection, the phase, and liveness are
-- checked first; a retired member is 'MemberNotLive'. The callback runs with
-- the caller's masking state, may borrow other live members, and must not let
-- the value escape. The borrow is dropped on every exit from the callback.
withMember ∷ Collection → Member a → (a → IO r) → IO r
withMember collection member@(Member _ _ state) action = mask $ \restore → do
  requireOwner collection
  requireOwnMember collection member
  requireOpen collection
  held ← readIORef state
  case held of
    MemberHeld value ledger borrows → do
      writeIORef state (MemberHeld value ledger (borrows + 1))
      modifyIORef' (collectionBorrows collection) (+ 1)
      outcome ← tryScope (restore (action value))
      modifyIORef' (collectionBorrows collection) (subtract 1)
      modifyIORef' state dropBorrow
      either rethrowIO pure outcome
    _ → throwIO MemberNotLive
  where
    dropBorrow (MemberHeld value ledger borrows) = MemberHeld value ledger (borrows - 1)
    dropBorrow terminal = terminal

-- | Release one member before the collection's scope ends.
--
-- After the owner thread, the token's collection, and the phase are checked,
-- a member that a running callback borrows answers 'RetirementInUse'. While
-- any callback is borrowing, retiring any other member — live or already
-- terminal — is rejected with 'CollectionReentered' 'Borrowing'. Otherwise a
-- terminal member answers from its stored state: 'AlreadyRetired' after a
-- successful release, or its stored failure rethrown after a failed one. A
-- live member leaves the ledger and its parts are released in their declared
-- order, each exactly once and uninterruptibly.
--
-- A release that fails leaves the member in a failed terminal state, poisons
-- and latches the collection, and propagates the first cleanup failure's
-- exception with every cleanup failure retained.
retireMember ∷ Collection → Member a → IO Retirement
retireMember collection member@(Member _ identifier state) = mask_ $ do
  requireOwner collection
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
        writeIORef (collectionPhase collection) (PhaseBusy Retiring)
        modifyIORef' (collectionLive collection) (Map.delete identifier)
        failures ← releaseAcquired ledger
        settled ← settle state failures
        latch collection failures
        writeIORef (collectionPhase collection) PhaseOpen
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

newCollection ∷ Int → IO Collection
newCollection limit =
  Collection
    <$> newUnique
    <*> myThreadId
    <*> pure limit
    <*> newIORef PhaseOpen
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef Map.empty
    <*> newIORef []

-- | Close admission and release every live member, newest registration first.
-- The caller is masked. Returns every cleanup failure the collection observed,
-- latched ones first, in observation order.
closeCollection ∷ Collection → IO [CleanupFailure]
closeCollection collection = do
  writeIORef (collectionPhase collection) (PhaseBusy Closing)
  live ← atomicModifyIORef' (collectionLive collection) (Map.empty,)
  drained ← traverse (releaseAtExit . snd) (Map.toDescList live)
  latched ← atomicModifyIORef' (collectionLatched collection) ([],)
  writeIORef (collectionPhase collection) PhaseClosed
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

latch ∷ Collection → [CleanupFailure] → IO ()
latch collection failures =
  modifyIORef' (collectionLatched collection) (reverse failures <>)

requireOwner ∷ Collection → IO ()
requireOwner collection = do
  caller ← myThreadId
  when (caller /= collectionOwner collection) (throwIO NotOwnerThread)

requireOwnMember ∷ Collection → Member a → IO ()
requireOwnMember collection (Member issuer _ _) =
  when (issuer /= collectionIdentity collection) (throwIO ForeignMember)

requireOpen ∷ Collection → IO ()
requireOpen collection = do
  phase ← readIORef (collectionPhase collection)
  case phase of
    PhaseOpen → pure ()
    PhaseBusy activity → throwIO (CollectionReentered activity)
    PhaseClosed → throwIO CollectionClosed

requireNoBorrow ∷ Collection → IO ()
requireNoBorrow collection = do
  borrows ← readIORef (collectionBorrows collection)
  when (borrows > 0) (throwIO (CollectionReentered Borrowing))
