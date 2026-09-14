{-# LANGUAGE RoleAnnotations #-}

-- | Latest-value snapshots of prepared payloads, read through checked cursors.
--
-- A snapshot is created in 'IO' by its publisher with 'newSnapshot', from a
-- prepared initial value, and returns the publisher endpoint,
-- 'SnapshotPublisher'. The publisher hands out the read endpoint,
-- 'SnapshotReader', with 'snapshotReader'. A reader can read and wait; it cannot
-- publish or close. Every endpoint is abstract and every operation is an
-- ordinary function; no 'TVar' or other private state escapes.
--
-- __Identity.__ Every 'newSnapshot' call creates a snapshot with a fresh
-- identity. A new lifetime is always a new snapshot: there is no way to reset
-- or reopen an old one, and its revisions never restart.
--
-- __Publication and revision.__ 'publish' takes a 'Prepared' payload and
-- replaces the value together with its revision in one write, so no reader
-- ever sees a value paired with another publication's revision. The initial
-- value has revision zero and every committed publication advances the
-- revision by one, including publication of an equal value: no 'Eq' instance is
-- needed and no content is compared. Revisions are 'Natural' and never wrap. A
-- transaction that rolls back changes neither value nor revision.
--
-- __Observations and cursors.__ 'readSnapshot' returns an 'Observation': the
-- current 'Prepared' payload, read with 'observedValue', and a 'SnapshotCursor'
-- naming this snapshot and the revision observed, read with 'observedCursor'.
-- Reading changes nothing any other reader can see. The observed payload is
-- the very handle that was published, so it can be published or forwarded
-- unchanged without 'NFData' or evaluation.
--
-- __Waiting.__ 'awaitSnapshot' takes a cursor. It returns 'Updated' with the
-- newest publication after the cursor's revision, and its new cursor; a reader
-- that missed intermediate publications receives only the newest. With nothing
-- newer, it returns 'EndOfStream' once the snapshot is closed and retries only
-- while it is open. No per-reader acknowledgement state is kept: each reader
-- advances only the cursor it holds, and waiting again from an older cursor may
-- return the current value again.
--
-- __Cursor mismatch.__ A cursor from a different snapshot raises
-- 'ForeignSnapshotCursor' through 'throwFailureSTM', with engine origin, before
-- the value, revision, or terminal flag is read and before any wait, whether the
-- target snapshot is open or closed. Identities are compared exactly, never by
-- revision or hash, so a retained cursor from an earlier lifetime is rejected
-- by its replacement.
--
-- __Close.__ 'closeSnapshot' ends publication. It is idempotent, never executes
-- 'retry', and wakes waiting readers. It keeps the last value, and its cursor,
-- for current reads, and it does not advance the revision: a waiter holding an
-- unseen final publication receives it before 'EndOfStream'. Publishing after
-- close returns 'PublicationClosed' and changes nothing. A closed snapshot never
-- reopens.
--
-- __Where waiting is safe.__ Every operation is an 'STM' action, so a wait
-- composes with @awaitSupervised@ from the runtime package's
-- @Hetoimasia.Runtime.Supervision@ on the application thread, and with a
-- worker's 'Hetoimasia.Foundation.Worker.awaitStopRequest' through
-- 'Control.Monad.STM.orElse'. Never wait inside a release; close is the
-- operation a release may use.
--
-- __Ownership.__ Any number of threads may hold the publisher or a reader. One
-- logical publisher per snapshot is an ownership convention the owner keeps,
-- not something the types enforce. A snapshot grants no lifetime ownership over
-- anything a value refers to: a native resource inside a published value stays
-- owned, and released, by the scope that owns it.
--
-- __Transaction hygiene.__ No operation evaluates a payload, reads a clock,
-- logs, invokes a callback, or uses 'GHC.Conc.unsafeIOToSTM'. The only failure
-- raised inside 'STM' is the cursor mismatch.
--
-- __State.__ One snapshot owns its value, revision, and terminal flag; each
-- reader owns its own last revision, as the cursor it holds.
--
-- +---------------------+------------------------------------------------+-------------+-------------------------------------------+
-- | State               | Readers and writers                            | Thread      | Lifetime and reset                        |
-- +=====================+================================================+=============+===========================================+
-- | Snapshot value      | 'publish' writes; 'readSnapshot' and           | Any holder  | From construction until replaced; kept    |
-- |                     | 'awaitSnapshot' read                           | of an       | after close; lives while referenced       |
-- |                     |                                                | endpoint    |                                           |
-- +---------------------+------------------------------------------------+-------------+-------------------------------------------+
-- | Revision            | Written with the value by 'publish'; read with | Any holder  | Zero at construction; never reset, never  |
-- |                     | it                                             |             | wraps, unchanged by close                 |
-- +---------------------+------------------------------------------------+-------------+-------------------------------------------+
-- | Terminal flag       | 'closeSnapshot' writes; 'publish' and          | Any holder  | Open until the first close; never reopens |
-- |                     | 'awaitSnapshot' read                           |             |                                           |
-- +---------------------+------------------------------------------------+-------------+-------------------------------------------+
-- | Reader's last       | The reader that holds the cursor; no other     | That        | As long as the reader keeps the cursor;   |
-- | revision            | party reads or writes it                       | reader's    | the snapshot keeps no copy                |
-- +---------------------+------------------------------------------------+-------------+-------------------------------------------+
--
-- See @docs/messaging.md@ for the same contract in prose.
module Hetoimasia.Foundation.Messaging.Snapshot
  ( -- * Construction
    SnapshotPublisher
  , newSnapshot
  , SnapshotReader
  , snapshotReader

    -- * Publishing
  , Publication (..)
  , publish
  , closeSnapshot

    -- * Reading
  , Observation
  , observedValue
  , observedCursor
  , SnapshotCursor
  , cursorRevision
  , readSnapshot
  , Update (..)
  , awaitSnapshot

    -- * Misuse
  , ForeignSnapshotCursor (..)
  , messagingComponent
  , awaitSnapshotOperation
  ) where

import Control.Concurrent.STM (STM, TVar, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (Exception)
import Data.Text (pack)
import Data.Unique (Unique, newUnique)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailureSTM)
import Hetoimasia.Foundation.Messaging.Channel (messagingComponent)
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

-- | The observed payload, the very handle that was published.
observedValue ∷ Observation a → Prepared a
observedValue (Observation value _) = value

-- | The cursor of the observed publication.
observedCursor ∷ Observation a → SnapshotCursor a
observedCursor (Observation _ cursor) = cursor

-- | The revision a cursor observed: zero for the initial value, and one more
-- for each publication after it.
cursorRevision ∷ SnapshotCursor a → Natural
cursorRevision (SnapshotCursor _ revision) = revision

-- | A cursor from a different snapshot was passed to 'awaitSnapshot'.
--
-- The cursor's revision is kept for diagnosis; its identity is not
-- displayable.
newtype ForeignSnapshotCursor = ForeignSnapshotCursor Natural
  deriving (Eq, Show)

instance Exception ForeignSnapshotCursor

-- | The operation a cursor mismatch names as its origin.
awaitSnapshotOperation ∷ Operation
awaitSnapshotOperation = operation "await-snapshot"

-- | Create an open snapshot with a fresh identity, holding the initial value at
-- revision zero.
newSnapshot ∷ Prepared a → IO (SnapshotPublisher a)
newSnapshot initial = do
  identity ← newUnique
  SnapshotPublisher . Snapshot identity <$> newTVarIO (State initial 0 False)

-- | The snapshot's read endpoint.
snapshotReader ∷ SnapshotPublisher a → SnapshotReader a
snapshotReader (SnapshotPublisher snapshot) = SnapshotReader snapshot

-- Publishing -------------------------------------------------------------------

-- | What a publication did.
data Publication
  = Published
    -- ^ The value was replaced and the revision advanced.
  | PublicationClosed
    -- ^ The snapshot is closed. Nothing changed.
  deriving (Eq, Show)

-- | Replace the value and advance the revision, unless the snapshot is closed.
-- Never waits, and never compares or forces the payload.
publish ∷ SnapshotPublisher a → Prepared a → STM Publication
publish (SnapshotPublisher snapshot) payload = do
  state ← readTVar (snapshotState snapshot)
  if stateClosed state
    then pure PublicationClosed
    else
      Published
        <$ writeTVar (snapshotState snapshot) (State payload (stateRevision state + 1) False)

-- | End publication, keeping the last value and its revision. Idempotent; it
-- never waits and never reopens a snapshot.
closeSnapshot ∷ SnapshotPublisher a → STM ()
closeSnapshot (SnapshotPublisher snapshot) = do
  state ← readTVar (snapshotState snapshot)
  if stateClosed state
    then pure ()
    else writeTVar (snapshotState snapshot) state {stateClosed = True}

-- Reading ----------------------------------------------------------------------

-- | Read the current value and its cursor. Never waits, and changes nothing.
readSnapshot ∷ SnapshotReader a → STM (Observation a)
readSnapshot (SnapshotReader snapshot) = observe snapshot <$> readTVar (snapshotState snapshot)

-- | What a waiting read found.
data Update a
  = Updated (Observation a)
    -- ^ The newest publication after the cursor's revision.
  | EndOfStream
    -- ^ The snapshot is closed and holds nothing newer than the cursor.

-- | Wait for a publication newer than the cursor.
--
-- Returns the newest one at once if it exists, 'EndOfStream' if the snapshot is
-- closed with nothing newer, and retries only while it is open with nothing
-- newer. A cursor from another snapshot throws 'ForeignSnapshotCursor' through
-- 'throwFailureSTM', attributed to the caller with the cursor's revision as an
-- identifier, before the snapshot's state is read.
awaitSnapshot ∷ HasCallStack ⇒ SnapshotReader a → SnapshotCursor a → STM (Update a)
awaitSnapshot (SnapshotReader snapshot) (SnapshotCursor identity seen)
  | identity /= snapshotIdentity snapshot =
      throwFailureSTM
        messagingComponent
        awaitSnapshotOperation
        [("cursor-revision", pack (show seen))]
        (ForeignSnapshotCursor seen)
  | otherwise = do
      state ← readTVar (snapshotState snapshot)
      if stateRevision state > seen
        then pure (Updated (observe snapshot state))
        else if stateClosed state then pure EndOfStream else retry

observe ∷ Snapshot a → State a → Observation a
observe snapshot state =
  Observation (stateValue state) (SnapshotCursor (snapshotIdentity snapshot) (stateRevision state))
