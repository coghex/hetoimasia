-- | Scoped identities for the script task protocol.
--
-- Every record this model holds — a task, a request, a subscription — is named
-- by an identity that carries its owner with it. An owner is one mod running in
-- one execution domain; a 'SessionKey' adds the session that owner is currently
-- running and the epoch that session is on. Nothing in this package compares a
-- bare local number: a 'TaskName' is meaningless without the 'SessionKey' it
-- was issued under, and the types make it impossible to hold one without the
-- other.
--
-- That is what makes D-8's isolation structural rather than a rule someone has
-- to remember. Two mods may both call their first task @1@; the two 'TaskId's
-- differ in their 'ModId' and are never equal, so a resume, a settlement, a
-- delivery, or an invalidation addressed to one cannot reach the other. The
-- same holds for two domains of one mod, two sessions of one domain, and two
-- epochs of one session.
--
-- Epochs and generations are the two monotonic counters that make staleness
-- visible. An 'Epoch' belongs to a session and advances when its domain is
-- replaced; a 'Generation' belongs to a request name and advances when that
-- name is reused. A reply that names an old epoch or an old generation names a
-- different 'RequestId' than the live one, which is why
-- "Hetoimasia.Scripting.Lua.Internal.Protocol.Session" can reject it at
-- consumption without keeping a separate list of what has gone stale.
--
-- 'Ordinal' is the one counter that is not an identity. It records insertion
-- order for a scheduler this slice does not implement, and it is issued by the
-- session rather than by a task.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( -- * Owners
    ModId (..)
  , ExecutionDomain (..)
  , Owner (..)

    -- * Sessions and epochs
  , SessionId (..)
  , Epoch (..)
  , firstEpoch
  , nextEpoch
  , SessionKey (..)
  , sameLineage
  , Staleness (..)
  , compareScope

    -- * Tasks
  , TaskName (..)
  , TaskId (..)
  , BehaviorId (..)

    -- * Requests
  , RequestName (..)
  , Generation (..)
  , firstGeneration
  , nextGeneration
  , RequestId (..)

    -- * Subscriptions
  , SubscriptionName (..)
  , SubscriptionId (..)
  , EndpointId (..)

    -- * Snapshots
  , SnapshotId (..)

    -- * Insertion order
  , Ordinal (..)
  , firstOrdinal
  , nextOrdinal
  ) where

import Data.Text (Text)
import Data.Word (Word64)

-- | One mod. The engine issues these; a script never chooses its own.
newtype ModId = ModId {modName ∷ Text}
  deriving (Eq, Ord, Show)

-- | The two execution domains D-1 separates.
--
-- They are separate owners, not two priorities of one owner: gameplay's
-- authoritative failure must not stop the interface from reporting it.
data ExecutionDomain
  = -- | The interface. It keeps reporting after a gameplay session fails.
    InterfaceDomain
  | -- | Authoritative gameplay. D-7's stop policy applies to this one.
    GameplayDomain
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One mod in one domain: the unit that owns identities.
data Owner = Owner
  { ownerMod ∷ !ModId
  , ownerDomain ∷ !ExecutionDomain
  }
  deriving (Eq, Ord, Show)

-- | One run of one owner. A replacement domain is a new session, not a reset.
newtype SessionId = SessionId {sessionNumber ∷ Word64}
  deriving (Eq, Ord, Show)

-- | A session's generation of live records.
newtype Epoch = Epoch {epochNumber ∷ Word64}
  deriving (Eq, Ord, Show)

-- | The epoch a session starts on.
firstEpoch ∷ Epoch
firstEpoch = Epoch 0

-- | The epoch that replaces a given one.
nextEpoch ∷ Epoch → Epoch
nextEpoch (Epoch n) = Epoch (n + 1)

-- | The scope every identity in this model carries.
data SessionKey = SessionKey
  { keyOwner ∷ !Owner
  , keySession ∷ !SessionId
  , keyEpoch ∷ !Epoch
  }
  deriving (Eq, Ord, Show)

-- | Whether two scopes are the same session of the same owner, whatever their
-- epochs.
--
-- This is the distinction between an identity that has gone stale and one that
-- was never ours. Both are rejected; they are not the same mistake, and a
-- caller that reports them identically loses the difference between a race
-- against an epoch change and a misrouted message.
sameLineage ∷ SessionKey → SessionKey → Bool
sameLineage left right =
  keyOwner left == keyOwner right && keySession left == keySession right

-- | How an offered scope relates to the scope that holds a record.
data Staleness
  = -- | Exactly the holding scope.
    ScopeCurrent
  | -- | The same session, an earlier epoch: a record that has been replaced.
    ScopeStale !Epoch !Epoch
  | -- | A later epoch of the same session, which nothing may claim to be.
    ScopeAhead !Epoch !Epoch
  | -- | Another owner or another session entirely.
    ScopeForeign !SessionKey !SessionKey
  deriving (Eq, Show)

-- | Classify an offered scope against the scope a record was issued under.
--
-- The first argument holds the record; the second is what a caller offered.
compareScope ∷ SessionKey → SessionKey → Staleness
compareScope held offered
  | held == offered = ScopeCurrent
  | not (sameLineage held offered) = ScopeForeign held offered
  | keyEpoch offered < keyEpoch held = ScopeStale (keyEpoch held) (keyEpoch offered)
  | otherwise = ScopeAhead (keyEpoch held) (keyEpoch offered)

-- | A task's local number, unique within one 'SessionKey' and never reissued
-- within it.
newtype TaskName = TaskName {taskNumber ∷ Word64}
  deriving (Eq, Ord, Show)

-- | A task's identity: its scope and its local number.
data TaskId = TaskId
  { taskScope ∷ !SessionKey
  , taskName ∷ !TaskName
  }
  deriving (Eq, Ord, Show)

-- | Shared behaviour many small task records reuse (P-5).
--
-- The model carries it and never resolves it: what a behaviour identity names
-- is the VM owner's business.
newtype BehaviorId = BehaviorId {behaviorName ∷ Text}
  deriving (Eq, Ord, Show)

-- | A request's local number. Reusing one requires a new 'Generation'.
newtype RequestName = RequestName {requestNumber ∷ Word64}
  deriving (Eq, Ord, Show)

-- | How many times a 'RequestName' has been used within one scope.
newtype Generation = Generation {generationNumber ∷ Word64}
  deriving (Eq, Ord, Show)

-- | The generation a request name starts on.
firstGeneration ∷ Generation
firstGeneration = Generation 0

-- | The generation that succeeds a given one.
nextGeneration ∷ Generation → Generation
nextGeneration (Generation n) = Generation (n + 1)

-- | A request's identity: scope, local number, and generation (P-7).
data RequestId = RequestId
  { requestScope ∷ !SessionKey
  , requestName ∷ !RequestName
  , requestGeneration ∷ !Generation
  }
  deriving (Eq, Ord, Show)

-- | A subscription's local number.
newtype SubscriptionName = SubscriptionName {subscriptionNumber ∷ Word64}
  deriving (Eq, Ord, Show)

-- | A subscription's identity: scope, local number, and generation.
--
-- It carries a 'Generation' for the same reason a 'RequestId' does. A
-- subscription that ends frees its local number, and a producer's event may
-- still be in flight when the number is registered again; without the
-- generation that event would land in the new subscription's backlog as if it
-- had been meant for it.
data SubscriptionId = SubscriptionId
  { subscriptionScope ∷ !SessionKey
  , subscriptionLocal ∷ !SubscriptionName
  , subscriptionGeneration ∷ !Generation
  }
  deriving (Eq, Ord, Show)

-- | The provider surface a request or subscription names.
--
-- Endpoints declare their own overload policy; see
-- "Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription".
newtype EndpointId = EndpointId {endpointName ∷ Text}
  deriving (Eq, Ord, Show)

-- | The identity of an application snapshot.
--
-- A failure record names the last one that was good (P-8). The model stores
-- the identity and never the snapshot: withholding a new snapshot is not a
-- rollback, and this model owns no application state to roll back.
newtype SnapshotId = SnapshotId {snapshotNumber ∷ Word64}
  deriving (Eq, Ord, Show)

-- | A monotonic insertion ordinal (P-5).
--
-- Issued by the session on admission and on every re-entry into the ready set,
-- so a yielded task orders behind the peers that were already ready. It records
-- what a scheduler needs to choose fairly; choosing is LUA-6's.
newtype Ordinal = Ordinal {ordinalNumber ∷ Word64}
  deriving (Eq, Ord, Show)

-- | The first ordinal a session issues.
firstOrdinal ∷ Ordinal
firstOrdinal = Ordinal 0

-- | The ordinal after a given one.
nextOrdinal ∷ Ordinal → Ordinal
nextOrdinal (Ordinal n) = Ordinal (n + 1)
