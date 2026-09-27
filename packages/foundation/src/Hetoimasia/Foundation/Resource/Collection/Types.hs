{-# LANGUAGE RoleAnnotations #-}

-- | The representations behind "Hetoimasia.Foundation.Resource.Collection":
-- the collection and its phase, member identities and state, the member
-- token, and the results and rejections its operations report.
--
-- This is a hidden module of the foundation's main library. The public
-- collection module imports it and re-exports 'Collection' and 'Member'
-- without their constructors and the result and rejection types with theirs,
-- so a client can neither build nor take apart a collection or a token; a
-- client importing this module directly is refused. It defines
-- representations and their instances only — every effect, and so every
-- write to the state these types hold, is in the public module, whose module
-- documentation records that state's owner, threads, and lifetime.
--
-- It imports the resource family only through the package-private facade
-- "Hetoimasia.Foundation.Resource.Internal", for the 'Ledger' a live member
-- holds and the 'CleanupFailure' evidence a collection latches.
module Hetoimasia.Foundation.Resource.Collection.Types
  ( -- * Collection state
    Collection (..)
  , Phase (..)
  , Activity (..)

    -- * Members
  , MemberId (..)
  , LiveMember (..)
  , MemberState (..)
  , Member (..)

    -- * Results
  , Retirement (..)
  , MemberStatus (..)

    -- * Rejections
  , CollectionError (..)
  ) where

import Control.Concurrent (ThreadId)
import Control.Exception (Exception, ExceptionWithContext, SomeException)
import Data.IORef (IORef)
import Data.Map.Strict (Map)
import Data.Unique (Unique)
import Data.Word (Word64)
import Hetoimasia.Foundation.Resource.Internal (CleanupFailure, Ledger)

-- | A scoped owner of independently retired members.
--
-- The type is exported without its constructor. A collection is obtained only
-- from 'Hetoimasia.Foundation.Resource.Collection.allocCollection' and is
-- valid only inside the continuation that allocated it.
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

-- | What one call to 'Hetoimasia.Foundation.Resource.Collection.retireMember'
-- did.
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
  = -- | 'Hetoimasia.Foundation.Resource.Collection.allocCollection' was given a
    -- limit below one.
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
