-- | What a replay is asked to record, and what it answers, on either side.
--
-- Every mode executes the same operations the same way; they differ only in
-- what they record. That is what lets each timed pass be checked against the
-- evidence pass: the same checksum, the same placements, the same operations
-- executed.
module Parity.Replay
  ( Mode (..)
  , Pass (..)
  , Evidence (..)
  , sampleEvery
  , samePass
  ) where

import qualified Data.Vector.Storable as Storable
import qualified Data.Vector.Storable.Mutable as StorableMutable
import qualified Data.Vector.Unboxed as Unboxed
import Data.Word (Word64)

-- | What a replay records.
data Mode
  = EvidenceMode
    -- ^ Untimed: outcomes, offsets, fragmentation samples and checkpoints.
  | PerOperation (StorableMutable.IOVector Word64)
    -- ^ One clock pair around each operation, accumulated per operation.
  | Intervals (Storable.Vector Word64) (StorableMutable.IOVector Word64)
    -- ^ One clock pair around each interval — pairs of operation indices
    -- @[start, end)@, sorted and disjoint — accumulated per interval.
    -- Operations outside every interval still run, untimed.
  | HeapCount
    -- ^ Untimed. VMA's side reads the C heap's statistics after every
    -- operation; the Haskell side has no counterpart and reads the runtime's
    -- statistics around its windowed passes instead.

-- | One pass's summary.
data Pass = Pass
  { passChecksum ∷ !Word64
    -- ^ The sum of every placed offset plus one.
  , passPlaced ∷ !Word64
  , passExecuted ∷ !Word64
    -- ^ Allocations, and frees of allocations this side placed.
  , passTimedNanoseconds ∷ !Word64
  , passHeapChanges ∷ !Word64
    -- ^ Operations after which the C heap's bytes or blocks in use changed.
  , passHeapFinal ∷ !Word64
    -- ^ C heap bytes in use at the end, above the empty block.
  , passHeapPeak ∷ !Word64
    -- ^ Peak C heap bytes in use, above the empty block.
  }
  deriving (Eq, Show)

-- | Whether two passes did the same work.
samePass ∷ Pass → Pass → Bool
samePass a b =
  (passChecksum a, passPlaced a, passExecuted a) == (passChecksum b, passPlaced b, passExecuted b)

-- | What an evidence pass records.
data Evidence = Evidence
  { evidencePlaced ∷ !(Unboxed.Vector Bool)
    -- ^ Per operation: an allocation this side placed.
  , evidenceOffsets ∷ !(Unboxed.Vector Word64)
  , evidenceSampleFree ∷ !(Unboxed.Vector Word64)
    -- ^ Free bytes after every 'sampleEvery' operations.
  , evidenceSampleLargest ∷ !(Unboxed.Vector Word64)
  , evidenceCheckpointFree ∷ !(Unboxed.Vector Word64)
    -- ^ Per checkpoint ordinal.
  , evidenceCheckpointLargest ∷ !(Unboxed.Vector Word64)
  }

-- | Fragmentation is sampled after every hundred operations.
sampleEvery ∷ Int
sampleEvery = 100
