-- | What the read-pool examples share: trees scanned over the production adapter, a probe that
-- wraps the verified reader to count, order and gate reads, recording sinks, and bounded waits.
--
-- Nothing here sleeps. An example knows what has happened by blocking in STM on a gate, a count
-- or a recorded outcome, within a bound that turns a stuck example into a failure.
--
-- Evidence from the real adapter and evidence that is injected are kept apart by name: the
-- 'Probe' wraps the real @readVerified@ (so a gated read still opens and hashes a real file) and
-- 'failingReader' replaces it outright, so an example's text says which it uses.
module Test.Content.ReadPool.Support
  ( -- * Specifications
    poolOf

    -- * Trees
  , withInventory
  , withRealPool
  , keyOf

    -- * Waiting
  , awaitSTM
  , awaitStatus
  , awaitRetired
  , pathBytes

    -- * Holding a hook
  , HoldGate
  , newGate
  , holdAt
  , awaitHeld
  , releaseGate

    -- * The probe
  , Probe
  , newProbe
  , probeReader
  , uninterruptiblyGated
  , closeGate
  , openGate
  , awaitStarted
  , startedPaths
  , readsStarted
  , maxActive
  , activeNow

    -- * Outcomes
  , Seen (..)
  , Outcomes
  , newOutcomes
  , recordingSink
  , seenOutcomes
  , awaitOutcomes
  , summarize

    -- * Submitting
  , request
  , accepted

    -- * Injected faults
  , failingReader
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
import Control.Exception (finally, throwIO, uninterruptibleMask_)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Set (Set)
import qualified Data.Set as Set
import Hetoimasia.Content (ContentRoot)
import Hetoimasia.Content.Identity (ContentKey, contentKeyPath, logicalPathBytes)
import Hetoimasia.Content.Inventory (Inventory, ReadOutcome, ReadFailure (..))
import Hetoimasia.Content.Internal.Native (productionSeam)
import Hetoimasia.Content.ReadPool
import Test.Content.Inventory.Support (baseSpec, keyFor, limitsFrom, populate, rootPath, withLayout, withScanned)
import Test.Support.Bounded (bounded)

-- | A specification the example knows is valid.
poolOf ∷ Int → Int → PoolSpec
poolOf workers slots = either (\refusal → error ("invalid fixture pool " <> show (workers, slots) <> ": " <> show refusal)) id (poolSpec workers slots)

-- | A temporary root holding these files, scanned over the production adapter, and the root and
-- inventory borrowed for the body. The scan limits are 'baseSpec': 4 KiB per file.
withInventory ∷ [(FilePath, ByteString)] → (ContentRoot → Inventory → IO a) → IO a
withInventory files use = withLayout $ \tree → do
  populate (rootPath tree) files
  withScanned productionSeam (limitsFrom baseSpec) (rootPath tree) use

-- | The production pool over a real root and inventory.
withRealPool ∷ PoolSpec → [(FilePath, ByteString)] → (Inventory → ReadPool → IO a) → IO a
withRealPool spec files use = withInventory files $ \root inventory → withReadPool spec inventory root (use inventory)

-- | The key a reference names in the inventory's root.
keyOf ∷ Inventory → ByteString → ContentKey
keyOf = keyFor

-- | Wait, within the bound, for a transaction.
awaitSTM ∷ STM a → IO a
awaitSTM = bounded . atomically

-- | Wait until the pool's status satisfies this.
awaitStatus ∷ ReadPool → (PoolStatus → Bool) → IO ()
awaitStatus pool wanted = awaitSTM $ do
  reading ← status pool
  unless (wanted reading) retry

-- | Wait until a job has retired.
awaitRetired ∷ ReadTicket → IO ()
awaitRetired ticket = awaitSTM $ do
  done ← retired ticket
  unless done retry

-- | A reference spelled as bytes.
pathBytes ∷ FilePath → ByteString
pathBytes = BC.pack

-- | A point a hook can hold a worker at: it records that it was reached and waits to be released.
data HoldGate = HoldGate (TVar Bool) (TVar Bool)

newGate ∷ IO HoldGate
newGate = HoldGate <$> newTVarIO False <*> newTVarIO False

-- | Reach the gate and wait until it is released.
holdAt ∷ HoldGate → IO ()
holdAt (HoldGate reached released) = do
  atomically (writeTVar reached True)
  atomically $ readTVar released >>= \open → unless open retry

-- | Wait until some worker reached the gate.
awaitHeld ∷ HoldGate → IO ()
awaitHeld (HoldGate reached _) = awaitSTM $ readTVar reached >>= \seen → unless seen retry

releaseGate ∷ HoldGate → IO ()
releaseGate (HoldGate _ released) = atomically (writeTVar released True)

-- The probe -------------------------------------------------------------------------------

-- | What the wrapped reader did: the paths it was asked to read in the order it began them, how
-- many reads are inside it, the most that were at once, and the paths whose gate is closed.
data Probe = Probe
  { prStarted ∷ !(TVar [ByteString])
  , prActive ∷ !(TVar Int)
  , prMax ∷ !(TVar Int)
  , prClosed ∷ !(TVar (Set ByteString))
  , prUninterruptible ∷ !(TVar (Set ByteString))
  }

newProbe ∷ IO Probe
newProbe = Probe <$> newTVarIO [] <*> newTVarIO 0 <*> newTVarIO 0 <*> newTVarIO Set.empty <*> newTVarIO Set.empty

pathOf ∷ ContentKey → ByteString
pathOf = logicalPathBytes . contentKeyPath

-- | Wrap a verified reader: record that a read began, count it as active, wait while the path's
-- gate is closed, read, and count it out again however it ended. The gate wait is a blocking STM
-- transaction, so it is interrupted by a cancellation unless the path was marked
-- 'uninterruptiblyGated'.
probeReader ∷ Probe → (ContentKey → Int → IO a) → ContentKey → Int → IO a
probeReader probe inner key allowance = do
  let path = pathOf key
  atomically $ do
    modifyTVar' (prStarted probe) (<> [path])
    active ← readTVar (prActive probe)
    writeTVar (prActive probe) (active + 1)
    modifyTVar' (prMax probe) (max (active + 1))
  ( do
      let waitOpen = do
            closed ← readTVar (prClosed probe)
            if Set.member path closed then retry else pure ()
      stubborn ← atomically (Set.member path <$> readTVar (prUninterruptible probe))
      if stubborn then uninterruptibleMask_ (atomically waitOpen) else atomically waitOpen
      inner key allowance
    )
    `finally` atomically (modifyTVar' (prActive probe) (subtract 1))

-- | Close the gate of a path: a read of it waits when it reaches the gate.
closeGate ∷ Probe → ByteString → IO ()
closeGate probe path = atomically (modifyTVar' (prClosed probe) (Set.insert path))

-- | Open the gate of a path.
openGate ∷ Probe → ByteString → IO ()
openGate probe path = atomically (modifyTVar' (prClosed probe) (Set.delete path))

-- | The wait at this path's gate cannot be interrupted: a cancellation is delivered only when the
-- read leaves the gate.
uninterruptiblyGated ∷ Probe → ByteString → IO ()
uninterruptiblyGated probe path = atomically (modifyTVar' (prUninterruptible probe) (Set.insert path))

-- | Wait until this many reads have begun.
awaitStarted ∷ Probe → Int → IO ()
awaitStarted probe wanted = awaitSTM $ do
  started ← readTVar (prStarted probe)
  unless (length started >= wanted) retry

-- | The paths the reader began, oldest first.
startedPaths ∷ Probe → IO [ByteString]
startedPaths probe = atomically (readTVar (prStarted probe))

-- | How many reads began.
readsStarted ∷ Probe → IO Int
readsStarted probe = length <$> startedPaths probe

-- | The most reads that were inside the reader at once.
maxActive ∷ Probe → IO Int
maxActive probe = atomically (readTVar (prMax probe))

-- | The reads inside the reader now.
activeNow ∷ Probe → IO Int
activeNow probe = atomically (readTVar (prActive probe))

-- Outcomes ----------------------------------------------------------------------------------

-- | What a sink was told, reduced to something comparable.
data Seen
  = SeenBytes !ByteString
  | SeenRefused !ReadOutcome
  | SeenDefect !String
  | SeenAbandoned
  deriving (Eq, Show)

summarize ∷ ReadResult → Seen
summarize = \case
  ReadSucceeded bytes → SeenBytes bytes
  ReadFailed (ReadFailure _ _ outcome) → SeenRefused outcome
  ReadDefect failure → SeenDefect (show failure)
  ReadAbandoned → SeenAbandoned

-- | Every sink call, in order, by the path it was for.
type Outcomes = TVar [(ByteString, Seen)]

newOutcomes ∷ IO Outcomes
newOutcomes = newTVarIO []

-- | A sink that records, and does nothing else.
recordingSink ∷ Outcomes → ContentKey → ReadResult → IO ()
recordingSink outcomes key result = atomically (modifyTVar' outcomes (<> [(pathOf key, summarize result)]))

seenOutcomes ∷ Outcomes → IO [(ByteString, Seen)]
seenOutcomes = atomically . readTVar

-- | Wait until this many sink calls were recorded, and answer them.
awaitOutcomes ∷ Outcomes → Int → IO [(ByteString, Seen)]
awaitOutcomes outcomes wanted = awaitSTM $ do
  seen ← readTVar outcomes
  if length seen >= wanted then pure seen else retry

-- Submitting --------------------------------------------------------------------------------

-- | A request for this path in this inventory, recording into these outcomes.
request ∷ Inventory → Outcomes → ReadPriority → Int → ByteString → ReadRequest
request inventory outcomes priority allowance path =
  let key = keyOf inventory path
   in ReadRequest key allowance priority (recordingSink outcomes key)

-- | Reserve a slot and submit, requiring both to succeed.
accepted ∷ ReadPool → ReadRequest → IO ReadTicket
accepted pool asked = do
  atomically (reserveSlot pool) >>= \case
    True → pure ()
    False → fail "the pool had no slot to reserve"
  atomically (submit pool asked) >>= \case
    Right ticket → pure ticket
    Left refusal → fail ("the pool refused a job: " <> case refusal of PoolIsClosed → "closed"; PoolHasFailed e → "failed: " <> show e)

-- Injected faults ------------------------------------------------------------------------

-- | A reader that raises this instead of reading. Injected: no file is involved.
failingReader ∷ IOError → ContentKey → Int → IO a
failingReader failure _ _ = throwIO failure
