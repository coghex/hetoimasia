{-# LANGUAGE RoleAnnotations #-}

-- | The snapshot representation and its state, the publisher, reader, cursor
-- and observation types with their role annotations, the foreign-cursor error,
-- and the publication and update results.
--
-- __Ownership.__ The foundation owns these types. This hidden module of the
-- foundation's main library holds their representations and constructors;
-- "Hetoimasia.Foundation.Messaging.Snapshot" owns every snapshot operation,
-- including the observation and cursor readers, and is the only snapshot
-- module a client imports. It re-exports 'SnapshotPublisher',
-- 'SnapshotReader', 'SnapshotCursor' and 'Observation' without their
-- constructors, so they stay abstract outside the package, and never exports
-- 'Snapshot' or 'State'.
--
-- __Dependencies.__ This module imports "Hetoimasia.Foundation.Messaging.Payload"
-- for the 'Prepared' value a snapshot holds, and nothing from the channel
-- family, logging, or failures.
--
-- __State.__ The module defines the snapshot's state but creates and changes
-- none; the state table in "Hetoimasia.Foundation.Messaging.Snapshot" names its
-- owner, readers and writers.
module Hetoimasia.Foundation.Messaging.Snapshot.Types
  ( -- * Representation
    Snapshot (..)
  , State (..)

    -- * Endpoints
  , SnapshotPublisher (..)
  , SnapshotReader (..)

    -- * Reading
  , SnapshotCursor (..)
  , Observation (..)
  , Update (..)

    -- * Publishing
  , Publication (..)

    -- * Misuse
  , ForeignSnapshotCursor (..)
  ) where

import Control.Concurrent.STM (TVar)
import Control.Exception (Exception)
import Data.Unique (Unique)
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Numeric.Natural (Natural)

-- | The shared representation behind both endpoints.
data Snapshot a = Snapshot
  { snapshotIdentity ∷ !Unique
  , snapshotState ∷ !(TVar (State a))
  }

-- | Everything a transaction reads together, written as one value so the
-- payload and its revision can never be observed apart. The payload field is
-- lazy: storing a handle never forces it.
data State a = State
  { stateValue ∷ Prepared a
  , stateRevision ∷ !Natural
  , stateClosed ∷ !Bool
  }

-- | The publisher endpoint: it publishes, closes, and hands out the read
-- endpoint.
--
-- The role is nominal, as for 'Prepared', so no endpoint can be coerced to a
-- different payload type.
type role SnapshotPublisher nominal

newtype SnapshotPublisher a = SnapshotPublisher (Snapshot a)

-- | An endpoint that can only read and wait.
type role SnapshotReader nominal

newtype SnapshotReader a = SnapshotReader (Snapshot a)

-- | A position in one snapshot's publications: the snapshot's identity and the
-- revision observed. It holds no payload and no reference to the snapshot's
-- state.
type role SnapshotCursor nominal

data SnapshotCursor a = SnapshotCursor !Unique !Natural
  deriving (Eq)

-- | One coherent read: a payload and the cursor of the publication it came
-- from.
type role Observation nominal

data Observation a = Observation (Prepared a) !(SnapshotCursor a)

-- | A cursor from a different snapshot was passed to
-- 'Hetoimasia.Foundation.Messaging.Snapshot.awaitSnapshot'.
--
-- The cursor's revision is kept for diagnosis; its identity is not
-- displayable.
newtype ForeignSnapshotCursor = ForeignSnapshotCursor Natural
  deriving (Eq, Show)

instance Exception ForeignSnapshotCursor

-- Publishing -------------------------------------------------------------------

-- | What a publication did.
data Publication
  = Published
    -- ^ The value was replaced and the revision advanced.
  | PublicationClosed
    -- ^ The snapshot is closed. Nothing changed.
  deriving (Eq, Show)

-- Reading ----------------------------------------------------------------------

-- | What a waiting read found.
data Update a
  = Updated (Observation a)
    -- ^ The newest publication after the cursor's revision.
  | EndOfStream
    -- ^ The snapshot is closed and holds nothing newer than the cursor.
