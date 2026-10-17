-- | The representations behind "Hetoimasia.Foundation.Resource.OwnedCollection":
-- the collection, its owner capability, the gate that serializes its users, and
-- the rejections its operations report.
--
-- This is a hidden module of the foundation's main library. The public module
-- imports it and re-exports 'OwnedCollection' and 'OwnerCapability' without
-- their constructors and the rejection type with its own, so a client can
-- neither build nor take apart a collection or a capability; a client importing
-- this module directly is refused. It defines representations and their
-- instances only — every effect, and so every write to the state these types
-- hold, is in the public module, whose module documentation records that
-- state's owner, threads, and lifetime.
--
-- The member token, its state, the phase, and the result types are the thread-
-- owned collection's, from "Hetoimasia.Foundation.Resource.Collection.Types":
-- they say nothing about who owns the collection, and sharing them keeps a
-- token's status readable the same way from either kind of collection.
module Hetoimasia.Foundation.Resource.OwnedCollection.Types
  ( -- * Collection state
    OwnedCollection (..)
  , Gate (..)
  , Admission (..)

    -- * The capability
  , OwnerCapability (..)

    -- * Rejections
  , OwnedCollectionError (..)
  ) where

import Control.Concurrent (ThreadId)
import Control.Concurrent.STM (TVar)
import Control.Exception (Exception)
import Data.IORef (IORef)
import Data.Map.Strict (Map)
import Data.Unique (Unique)
import Data.Word (Word64)
import Hetoimasia.Foundation.Resource.Collection.Types
  ( Activity
  , LiveMember
  , MemberId
  , Phase
  )
import Hetoimasia.Foundation.Resource.Internal (CleanupFailure)

-- | A scoped owner of independently retired members, owned by a capability
-- instead of a thread.
--
-- The type is exported without its constructor. A collection is obtained only
-- from 'Hetoimasia.Foundation.Resource.OwnedCollection.allocOwnedCollection'
-- and is valid only inside the continuation that allocated it.
data OwnedCollection = OwnedCollection
  { ownedIdentity ∷ !Unique
  , ownedLimit ∷ !Int
  , ownedGate ∷ !(TVar Gate)
  , ownedPhase ∷ !(IORef Phase)
  , ownedBorrows ∷ !(IORef Int)
  , ownedNextMember ∷ !(IORef Word64)
  , ownedLive ∷ !(IORef (Map MemberId LiveMember))
  , ownedLatched ∷ !(IORef [CleanupFailure])
    -- ^ Newest first.
  }

-- | Who may be inside the collection, and whether anyone may enter.
--
-- Every operation is admitted through this one cell, in one transaction that
-- also reads the capability it was given, so admission and the capability's
-- validity cannot disagree.
data Gate = Gate
  { gateAdmission ∷ !Admission
  , gateHolder ∷ !(Maybe (ThreadId, Int))
    -- ^ The thread currently inside an operation, with how many nested
    -- operations it has open. 'Nothing' when no operation is running.
  , gateExiting ∷ !(Maybe ThreadId)
    -- ^ The thread running the scope's exit, once the exit has begun: the one
    -- thread that may still read the live count while members are released.
  }

-- | Whether new operations are admitted.
data Admission
  = -- | Operations are admitted, one thread at a time.
    Admitting
  | -- | The scope is ending: nothing new is admitted, and the exit waits for
    -- the operation inside to finish.
    Draining
  | -- | The scope has exited.
    Shut
  deriving (Eq)

-- | The authority to use one collection, with no thread attached.
--
-- It is created with the collection, can be lent for a bounded time, and is
-- unforgeable: the constructor is not exported, so a client can only be given
-- one. A capability issued for one collection means nothing to another.
data OwnerCapability
  = -- | What presenting no authority looks like.
    NoCapability
  | -- | The collection that issued it, and whether it is still valid. A lent
    -- capability's flag is cleared when the lending ends; the original's never
    -- is.
    OwnerCapability !Unique !(TVar Bool)

-- | A rejected operation. Every rejection is raised before the operation has
-- any acquisition, borrowing, or release effect.
data OwnedCollectionError
  = -- | 'Hetoimasia.Foundation.Resource.OwnedCollection.allocOwnedCollection'
    -- was given a limit below one.
    OwnedInvalidMemberLimit !Int
  | -- | The operation presented no capability.
    CapabilityMissing
  | -- | The capability was issued for a different collection.
    CapabilityForeign
  | -- | The capability was lent and the lending has ended.
    CapabilityStale
  | -- | Another thread is inside an operation of this collection. Operations
    -- are serialized, and a competing one is refused at once instead of
    -- queueing.
    ConcurrentPresentation
  | -- | The token was issued by a different collection.
    OwnedForeignMember
  | -- | The collection was already doing this when the call re-entered it. A
    -- call made while the scope is ending reports 'Closing', whichever thread
    -- made it.
    OwnedReentered !Activity
  | -- | The collection's scope has exited.
    OwnedClosed
  | -- | An acquisition would exceed the live-member limit, which is carried.
    OwnedLimitReached !Int
  | -- | A release failure has poisoned further acquisition.
    OwnedPoisoned
  | -- | The member has been retired, so it cannot be borrowed.
    OwnedMemberNotLive
  deriving (Eq, Show)

instance Exception OwnedCollectionError
