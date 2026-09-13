-- | A synthetic multi-part CPU component that follows the component
-- convention in @docs/resources.md@. It exists only for the construction
-- examples and ships in no library; it is not a production optional service.
--
-- The convention it demonstrates:
--
-- * a pure configuration, 'JournalConfig', validated by 'journalConfig' before
--   anything is acquired;
-- * one constructor, 'allocJournal', over
--   'Hetoimasia.Foundation.Recovery.allocComponent';
-- * an opaque handle, 'Journal', exported without its constructor or fields,
--   so its private state is reachable only through 'appendEntry',
--   'journalEntries', 'journalLive', and 'journalStore';
-- * one state table, below, naming every state the component owns.
--
-- A journal is built from two parts: an index holding its entries and a store
-- that must be live for an append. It has two construction alternatives: the
-- in-memory store it tries first and a spill store it falls back to. The
-- component supplies the classifier, because it alone knows which of its
-- failures another alternative can survive; the caller supplies the budget
-- and whether the journal is required.
--
-- The 'Rig' is the test's window onto the effects: every stage records its
-- name in order, and a stage named in the rig's broken set throws.
--
-- == State
--
-- +----------------+----------------------+--------------------------------------+-----------------+----------------------------------+-----------------------------------------+
-- | State          | Owner                | Readers and writers                  | Thread          | Lifetime                         | Reset or disposal                       |
-- +================+======================+======================================+=================+==================================+=========================================+
-- | Entries        | The index part of    | Written by 'appendEntry'; read by    | The thread      | From the index acquisition until | Created empty for each attempt; the     |
-- |                | one 'Journal'        | 'journalEntries'. Nothing else.      | running the     | its release when the enclosing   | rollback or scope release drops it. It |
-- |                |                      |                                      | consumer        | scope exits                      | is never reset in place.                |
-- +----------------+----------------------+--------------------------------------+-----------------+----------------------------------+-----------------------------------------+
-- | Store liveness | The store part of    | Set by the store's acquisition and   | The thread      | From the store acquisition until | Cleared by the store's release, which   |
-- |                | one 'Journal'        | release; read by 'appendEntry' and   | running the     | its release                      | runs before the index's.                |
-- |                |                      | 'journalLive'.                       | consumer        |                                  |                                         |
-- +----------------+----------------------+--------------------------------------+-----------------+----------------------------------+-----------------------------------------+
-- | Configuration  | The caller, as an    | Read by the constructor and          | Any             | The caller's value               | Immutable; a new configuration is a new |
-- |                | immutable value      | 'appendEntry'. Never written.        |                 |                                  | construction.                           |
-- +----------------+----------------------+--------------------------------------+-----------------+----------------------------------+-----------------------------------------+
module Test.Engine.Resources.Journal
  ( -- * Configuration
    JournalConfig
  , JournalConfigFault (..)
  , journalConfig
  , journalCapacity

    -- * Construction
  , Journal
  , Store (..)
  , JournalFault (..)
  , journalOperation
  , spillOperation
  , allocJournal

    -- * Use
  , appendEntry
  , journalEntries
  , journalLive
  , journalStore

    -- * Test rig
  , Rig
  , newRig
  , breakStage
  , rigTrace
  , note
  , journalComponent
  ) where

import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , fromException
  , throwIO
  )
import Control.Monad (when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Recovery
  ( AttemptFailure (attemptException, attemptKind)
  , AttemptKind (..)
  , Disposition
  , Outcome
  , RecoveryPolicy (..)
  , Strategy (..)
  , allocComponent
  )
import Hetoimasia.Foundation.Resource
  ( Assembly
  , Scoped
  , acquirePart
  , releaseRank
  , restoredStep
  )

-- | A validated journal configuration. Only 'journalConfig' builds one.
newtype JournalConfig = JournalConfig Int
  deriving (Eq, Show)

-- | Why a configuration was rejected.
newtype JournalConfigFault = NonPositiveCapacity Int
  deriving (Eq, Show)

instance Exception JournalConfigFault

-- | Validate a capacity purely, before any construction runs.
journalConfig ∷ Int → Either JournalConfigFault JournalConfig
journalConfig capacity
  | capacity < 1 = Left (NonPositiveCapacity capacity)
  | otherwise = Right (JournalConfig capacity)

journalCapacity ∷ JournalConfig → Int
journalCapacity (JournalConfig capacity) = capacity

-- | Which construction alternative produced a journal.
data Store = MemoryStore | SpillStore
  deriving (Eq, Show)

-- | The component's own failures.
data JournalFault
  = StageBroken Text
    -- ^ A stage the rig was told to break. Another alternative may survive it.
  | JournalFull Int
  | StoreReleased
  deriving (Eq, Show)

instance Exception JournalFault

-- | The opaque handle. Its constructor and fields are not exported.
data Journal = Journal
  { journalConfiguration ∷ !JournalConfig
  , journalKind ∷ !Store
  , journalIndex ∷ !(IORef [Text])
  , journalStoreLive ∷ !(IORef Bool)
  }

-- | The test's record of effects and the stages it has broken.
data Rig = Rig
  { rigEntries ∷ !(IORef [Text])
  , rigBroken ∷ !(IORef [Text])
  }

newRig ∷ IO Rig
newRig = Rig <$> newIORef [] <*> newIORef []

-- | Make the named stage throw 'StageBroken' from now on.
breakStage ∷ Rig → Text → IO ()
breakStage rig name = atomicModifyIORef' (rigBroken rig) (\broken → (name : broken, ()))

-- | Every stage and note recorded so far, oldest first.
rigTrace ∷ Rig → IO [Text]
rigTrace rig = reverse <$> readIORef (rigEntries rig)

-- | Record a caller's own step in the same trace.
note ∷ Rig → Text → IO ()
note rig entry = atomicModifyIORef' (rigEntries rig) (\entries → (entry : entries, ()))

journalComponent ∷ Component
journalComponent = unsafeComponent "test.journal"

-- | The name the journal's construction is recovered under.
journalOperation ∷ Operation
journalOperation = operation "journal"

-- | The name of the spill-store alternative.
spillOperation ∷ Operation
spillOperation = operation "spill"

-- | Record a stage, then throw if the rig broke it. A broken stage carries an
-- engine origin naming it, so an example can tell attempts apart.
stage ∷ Rig → Text → IO ()
stage rig name = do
  note rig name
  broken ← readIORef (rigBroken rig)
  when (name `elem` broken) $
    throwFailure journalComponent journalOperation [("stage", name)] (StageBroken name)

-- | The component's one constructor.
--
-- The caller chooses the disposition and the total attempt budget; the
-- component chooses which of its failures another alternative can survive.
-- A broken stage is recognized: the memory store falls back to the spill
-- store, and a failed spill store retries the memory store. Anything else is
-- unrecognized and propagates.
allocJournal ∷ Rig → Disposition → Int → JournalConfig → Scoped (Outcome Journal)
allocJournal rig disposition budget config =
  allocComponent journalOperation policy (assembly MemoryStore)
  where
    policy =
      RecoveryPolicy
        { policyDisposition = disposition
        , policyBudget = budget
        , policyClassifier = classify
        , policyWait = \_ → pure ()
        }

    classify failure = pure $ case attemptException failure of
      ExceptionWithContext _ exception → case fromException exception of
        Just (StageBroken _) → Just $ case attemptKind failure of
          FallbackAttempt _ → Retry
          _ → Fallback spillOperation (pure (assembly SpillStore))
        _ → Nothing

    assembly ∷ Store → Assembly Journal
    assembly kind = do
      let named step = prefix kind <> step
      index ←
        acquirePart (named "index") (releaseRank 1)
          (stage rig (named "acquire index") *> newIORef [])
          (\_ → stage rig (named "release index"))
      live ←
        acquirePart (named "store") (releaseRank 0)
          (stage rig (named "acquire store") *> newIORef True)
          (\slot → writeIORef slot False *> stage rig (named "release store"))
      restoredStep (stage rig (named "bind"))
      pure (Journal config kind index live)

    prefix MemoryStore = "memory: "
    prefix SpillStore = "spill: "

-- | Append an entry. The store must be live and the configured capacity must
-- not be exceeded.
appendEntry ∷ Journal → Text → IO ()
appendEntry journal entry = do
  live ← readIORef (journalStoreLive journal)
  when (not live) $ throwIO StoreReleased
  let capacity = journalCapacity (journalConfiguration journal)
  full ← atomicModifyIORef' (journalIndex journal) $ \entries →
    if length entries >= capacity then (entries, True) else (entries <> [entry], False)
  when full $ throwIO (JournalFull capacity)

journalEntries ∷ Journal → IO [Text]
journalEntries = readIORef . journalIndex

journalLive ∷ Journal → IO Bool
journalLive = readIORef . journalStoreLive

journalStore ∷ Journal → Store
journalStore = journalKind
