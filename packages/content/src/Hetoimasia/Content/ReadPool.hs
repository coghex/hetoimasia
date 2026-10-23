-- | The owned, bounded pool of verified-read workers (LFE-10).
--
-- 'Hetoimasia.Content.Inventory.readVerified' is synchronous. A consumer that must not block its
-- own thread (the Lua provider, and later the module and texture sources) hands a
-- 'ReadRequest' to a 'ReadPool' instead: a fixed number of worker threads, started once for a
-- session inside the scopes of the root and the inventory they borrow, each running one verified
-- read at a time over a queue whose size is bounded by reservations the consumers made.
--
-- The pool is not a general executor. It runs verified reads and nothing else; it caches nothing
-- and deduplicates nothing; it never retries, never polls and never starts a thread for a request;
-- and a job it accepted is never refused for want of room, because it was submitted against a slot
-- its consumer reserved first ('reserveSlot', in the consumer's own admission transaction).
--
-- * 'submit' only enqueues, in STM, and returns the consumer's 'ReadTicket'.
-- * Workers take the oldest job of the strongest 'ReadPriority'. A worker releases its execution
--   slot when the job's sink returned; it waits for nothing the consumer owns.
-- * 'cancel' withdraws a job that no worker took without a file ever being opened; a job a worker
--   took runs to its end with its sink suppressed. 'retired' says when either has happened.
-- * The scope's exit stops admission, withdraws and tells every queued job, and drains every read
--   already started before the root and inventory can be released.
--
-- See @packages/content/README.md@ for the contract: each state's owner, thread and lifetime, the
-- job transitions, the transfer of the verified buffer and the failure classification.
module Hetoimasia.Content.ReadPool
  ( -- * The pool
    ReadPool
  , PoolSpec
  , poolSpec
  , specWorkers
  , specSlots
  , PoolSpecRefusal (..)
  , withReadPool
  , VerifiedRead
  , withReadPoolUsing

    -- * Capacity
  , reserveSlot
  , releaseSlot

    -- * Jobs
  , ReadRequest (..)
  , ReadPriority (..)
  , ReadResult (..)
  , SubmitRefusal (..)
  , ReadTicket
  , submit
  , cancel
  , withdrawQueued
  , CancelOutcome (..)
  , retired
  , ticketKey

    -- * Observation
  , PoolStatus (..)
  , PoolPhase (..)
  , status
  , awaitFailure
  , poolFailureEvidence
  ) where

import Hetoimasia.Content.Internal.Inventory.Types (Inventory)
import Hetoimasia.Content.Internal.Pool hiding (poolSlots, poolWorkers, withPool, withPoolWith)
import qualified Hetoimasia.Content.Internal.Pool as Pool
import Hetoimasia.Content.Internal.Root (ContentRoot)

-- | Run a body over a pool of verified reads of this inventory through this root.
--
-- Call it inside the root's scope. The root and the inventory are borrowed for every read; the
-- scope's exit closes admission, withdraws and tells the queued jobs ('ReadAbandoned'), and
-- waits, uninterruptibly of nothing but the reads themselves, until every read already started
-- has settled, so the root closes after them. A body that returns while a worker has failed
-- rethrows that failure; one that fails reports it with the group's evidence.
withReadPool ∷ PoolSpec → Inventory → ContentRoot → (ReadPool → IO a) → IO a
withReadPool = Pool.withPool

-- | 'withReadPool' over a reader the caller supplies: how verified bytes are produced for a key
-- within an allowance. Production passes @'Hetoimasia.Content.Inventory.readVerified' inventory
-- root@ through 'withReadPool'; this exists so a caller can wrap that reader to gate, count or
-- fail a read, and says so where it does. Whatever the reader borrows must outlive the scope.
withReadPoolUsing ∷ PoolSpec → VerifiedRead → (ReadPool → IO a) → IO a
withReadPoolUsing = Pool.withPoolWith noHooks

-- | The worker threads of a specification: the most reads in flight.
specWorkers ∷ PoolSpec → Int
specWorkers = Pool.poolWorkers

-- | The slot capacity of a specification.
specSlots ∷ PoolSpec → Int
specSlots = Pool.poolSlots
