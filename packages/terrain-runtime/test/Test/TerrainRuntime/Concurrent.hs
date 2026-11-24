-- | The concurrent set, in ONE place, and why each module is in it or out of it (#685).
--
-- THE SET. A module is /concurrent/ when its examples start a thread, drive the production service (and so its owner thread) or
-- the storage workers, or wait on a gate: the races that only show when two threads execute at the same instant live there. The
-- concurrent modules run twice: in their place in the sequential order, on one capability, where their gated orders are what
-- the existing evidence rests on, and once more, last, in the multi-capability pass ("Test.TerrainRuntime.Isolation", the
-- pass's capability count in "Test.TerrainRuntime.Capabilities"): the very same examples, under the label 'passLabel', beside nothing
-- else and after every other example. Everything else is /alone/ and appears here with its reason; a module is added to this
-- table as one or the other, or not at all.
--
-- THE RULE. Nothing that measures the process may join the set: a live-heap, allocation or runtime-statistic reading is valid on
-- one capability only (it needs @-T@ and one capability), the examples that compile an external client run the compiler and
-- measure nothing of the runtime but belong to no concurrency, and a pure example starts no thread. The measurements assert it
-- themselves ('Test.TerrainRuntime.Isolation.assertSequential' fails on more than one capability), so a measurement placed in the
-- set fails the pass; the pure families are #681's parallel group ("Test.TerrainRuntime.Parallel") and never run here.
module Test.TerrainRuntime.Concurrent
  ( Disposition (..)
  , Entry (..)
  , entries
  , concurrentEntries
  , sequentialSpec
  , passSpec
  , passLabel
  ) where

import Control.Monad (forM_)
import Test.Hspec (Spec, around_, beforeAll_, describe)
import Test.TerrainRuntime.Capabilities (PassSetting, enterPass, inPass, passLine)
import qualified Test.TerrainRuntime.Isolation as Isolation
import Test.TerrainRuntime.Output (printLine)
import qualified Test.TerrainRuntime.OutputSpec as OutputSpec
import qualified Test.TerrainRuntime.Basic as Basic
import qualified Test.TerrainRuntime.Budgets as Budgets
import qualified Test.TerrainRuntime.Closure as Closure
import qualified Test.TerrainRuntime.Credits as Credits
import qualified Test.TerrainRuntime.Hardening as Hardening
import qualified Test.TerrainRuntime.Interleaving as Interleaving
import qualified Test.TerrainRuntime.HostPublished as HostPublished
import qualified Test.TerrainRuntime.Lifecycle as Lifecycle
import qualified Test.TerrainRuntime.Limits as Limits
import qualified Test.TerrainRuntime.Offload as Offload
import qualified Test.TerrainRuntime.Opacity as Opacity
import qualified Test.TerrainRuntime.Oracle as Oracle
import qualified Test.TerrainRuntime.Races as Races
import qualified Test.TerrainRuntime.Preparation as Preparation
import qualified Test.TerrainRuntime.Regional as Regional
import qualified Test.TerrainRuntime.Revalidation as Revalidation
import qualified Test.TerrainRuntime.Storage.Classes as StorageClasses
import qualified Test.TerrainRuntime.Storage.Growth as StorageGrowth
import qualified Test.TerrainRuntime.Storage.Io as StorageIo
import qualified Test.TerrainRuntime.Storage.Lifecycle as StorageLifecycle
import qualified Test.TerrainRuntime.Storage.Lifetime as StorageLifetime
import qualified Test.TerrainRuntime.Storage.Boundary as StorageBoundary
import qualified Test.TerrainRuntime.Storage.Memory as StorageMemory
import qualified Test.TerrainRuntime.Storage.Opacity as StorageOpacity
import qualified Test.TerrainRuntime.Storage.Open as StorageOpen
import qualified Test.TerrainRuntime.Backed.Compile as BackedCompile
import qualified Test.TerrainRuntime.Backed.Discovery as BackedDiscovery
import qualified Test.TerrainRuntime.Backed.Creator as BackedCreator
import qualified Test.TerrainRuntime.Backed.Fairness as BackedFairness
import qualified Test.TerrainRuntime.Backed.Pressure as BackedPressure
import qualified Test.TerrainRuntime.Backed.Held as BackedHeld
import qualified Test.TerrainRuntime.Backed.Loop as BackedLoop
import qualified Test.TerrainRuntime.Backed.Recovery as BackedRecovery
import qualified Test.TerrainRuntime.Backed.Ranges as BackedRanges
import qualified Test.TerrainRuntime.Store.WriteProbe as StoreWriteProbe
import qualified Test.TerrainRuntime.Storage.Filesystem as StorageFilesystem
import qualified Test.TerrainRuntime.Backed.Outcomes as BackedOutcomes
import qualified Test.TerrainRuntime.Backed.Pause as BackedPause
import qualified Test.TerrainRuntime.Backed.Service as BackedService
import qualified Test.TerrainRuntime.Backed.Sweep as BackedSweep
import qualified Test.TerrainRuntime.Backed.Txn as BackedTxn
import qualified Test.TerrainRuntime.Store.AdmissionSpec as StoreAdmission
import qualified Test.TerrainRuntime.Store.Allowance as StoreAllowance
import qualified Test.TerrainRuntime.Store.Boundary as StoreBoundary
import qualified Test.TerrainRuntime.Store.Bounds as StoreBounds
import qualified Test.TerrainRuntime.Store.Codec as StoreCodec
import qualified Test.TerrainRuntime.Store.Depth as StoreDepth
import qualified Test.TerrainRuntime.Store.Evidence as StoreEvidence
import qualified Test.TerrainRuntime.Store.Faults as StoreFaults
import qualified Test.TerrainRuntime.Store.Keys as StoreKeys
import qualified Test.TerrainRuntime.Store.Memory as StoreMemory
import qualified Test.TerrainRuntime.Store.Identity as StoreIdentity
import qualified Test.TerrainRuntime.Store.Ownership as StoreOwnership
import qualified Test.TerrainRuntime.Store.Readers as StoreReaders
import qualified Test.TerrainRuntime.Store.Replay as StoreReplay

-- | Whether a module's examples run in the multi-capability pass.
data Disposition
  = -- | In the set, for this reason.
    Concurrent String
  | -- | Out of the set, for this reason; it runs on one capability, in its place in the order, as before.
    Alone String
  deriving (Eq, Show)

-- | A module of the sequential order, its disposition and its examples.
data Entry = Entry
  { entryModule ∷ String
  , entryDisposition ∷ Disposition
  , entrySpec ∷ Spec
  }

-- | Every module that runs after the parallel group, in the order it runs.
entries ∷ [Entry]
entries =
  [ Entry "Isolation" (Alone "the harness's own examples: they set the capability count to prove their guards") Isolation.spec
  , Entry "OutputSpec" (Alone "the oracle of the printed lines runs nested runners at their own job counts") OutputSpec.spec
  , Entry "Basic" (Concurrent "drives the production service: its owner thread and its arbitration") Basic.spec
  , Entry "Races" (Concurrent "cancellation and closure against the owner, ordered by gates") Races.spec
  , Entry "Budgets" (Concurrent "concurrent admissions and credits on owned threads") Budgets.spec
  , Entry "Offload" (Concurrent "the service across repeated eviction and reload") Offload.spec
  , Entry "Revalidation" (Concurrent "staged work revalidated by the owner after a committed edit") Revalidation.spec
  , Entry "Preparation" (Concurrent "an open's palette and an answer's settlement prepared on the owner before staging, and the arbitration's races around it, ordered by eligibility and gates") Preparation.spec
  , Entry "Opacity" (Alone "compiles an external client with ghc; measures and races nothing") Opacity.spec
  , Entry "Lifecycle" (Concurrent "startup, body cancellation and an unexpected owner exit, on owned threads") Lifecycle.spec
  , Entry "Hardening" (Concurrent "forged and released authority, and closure under load, on owned threads and gates") Hardening.spec
  , Entry "Credits" (Concurrent "credits returned at the owner's acknowledgement") Credits.spec
  , Entry "Limits" (Concurrent "the service's limits reached through the owner") Limits.spec
  , Entry "Oracle" (Concurrent "the service against an independent model, through the owner") Oracle.spec
  , Entry "Interleaving" (Concurrent "orders of the owner's work, ordered by gates") Interleaving.spec
  , Entry "Closure" (Concurrent "closure against pending work, ordered by gates") Closure.spec
  , Entry "HostPublished" (Concurrent "an attachment issued through a creator lease, against closure and cancellation, ordered by a host that is not yet eligible") HostPublished.spec
  , Entry "Store.Codec" (Alone pureStore) StoreCodec.spec
  , Entry "Store.Replay" (Alone pureStore) StoreReplay.spec
  , Entry "Store.Faults" (Alone pureStore) StoreFaults.spec
  , Entry "Store.Identity" (Alone pureStore) StoreIdentity.spec
  , Entry "Store.Readers" (Alone pureStore) StoreReaders.spec
  , Entry "Store.Ownership" (Alone pureStore) StoreOwnership.spec
  , Entry "Store.WriteProbe" (Alone pureStore) StoreWriteProbe.spec
  , Entry "Storage.Filesystem" (Alone "one thread: a file profile through a recording seam; no worker and no gate") StorageFilesystem.spec
  , Entry "Backed.Outcomes" (Alone "the owner's decisions of the storage and store outcomes: pure, no STM, thread or I/O") BackedOutcomes.spec
  , Entry "Backed.Pause" (Concurrent "the backed service pausing an arena, on the owner and the workers") BackedPause.spec
  , Entry "Backed.Compile" (Concurrent "opens compiled in quanta on the owner, gated") BackedCompile.spec
  , Entry "Backed.Discovery" (Concurrent "discovery drained through the decision on the owner") BackedDiscovery.spec
  , Entry "Backed.Fairness" (Concurrent "fair scheduling of the owner's and the workers' work, gated") BackedFairness.spec
  , Entry "Backed.Creator" (Concurrent "creator-only growth and retry on the owner, gated") BackedCreator.spec
  , Entry "Backed.Pressure" (Concurrent "admission under pressure, with the workers held") BackedPressure.spec
  , Entry "Backed.Held" (Concurrent "closes that wait for held native calls") BackedHeld.spec
  , Entry "Backed.Loop" (Concurrent "the owner's loop on owned threads") BackedLoop.spec
  , Entry "Backed.Recovery" (Concurrent "recovery after a failure at each step, on the owner and the workers") BackedRecovery.spec
  , Entry "Backed.Ranges" (Concurrent "range reads through the backend, gated") BackedRanges.spec
  , Entry "Backed.Service" (Concurrent "the backed service end to end: owner, workers and gates") BackedService.spec
  , Entry "Backed.Sweep" (Concurrent "a physical-truth sweep after every step of a removal, on the service") BackedSweep.spec
  , Entry "Backed.Txn" (Concurrent "the session's one mutating transaction, on the service") BackedTxn.spec
  , Entry "Regional" (Concurrent "regional snapshots admitted, built, settled, taken and delivered through the owner and the workers, ordered by gates; its retention examples walk a build's own value, not the process's heap") Regional.spec
  , Entry "Store.Keys" (Alone pureStore) StoreKeys.spec
  , Entry "Store.Memory" (Alone measures) StoreMemory.spec
  , Entry "Store.Depth" (Alone measures) StoreDepth.spec
  , Entry "Store.Evidence (measured part)" (Alone measures) StoreEvidence.measuredSpec
  , Entry "Store.Allowance" (Alone pureStore) StoreAllowance.spec
  , Entry "Store.Admission" (Alone pureStore) StoreAdmission.spec
  , Entry "Store.Bounds" (Alone measures) StoreBounds.spec
  , Entry "Store.Boundary" (Alone "compiles an external client with ghc; the store beneath it is pure") StoreBoundary.spec
  , Entry "Storage.Open" (Concurrent "opens real files through the production adapter, with the descriptor kept from a child process") StorageOpen.spec
  , Entry "Storage.Io" (Concurrent "transfers on the two workers") StorageIo.spec
  , Entry "Storage.Lifetime" (Concurrent "handles outliving their borrowers, on the workers") StorageLifetime.spec
  , Entry "Storage.Growth" (Concurrent "checked growth prepared and committed through the workers") StorageGrowth.spec
  , Entry "Storage.Memory (floor, rules, spec, spec2-4)" (Alone measures) (StorageMemory.floorSpec >> StorageMemory.rulesSpec >> StorageMemory.spec >> StorageMemory.spec2 >> StorageMemory.spec3 >> StorageMemory.spec4)
  , Entry "Storage.Boundary" (Concurrent "the bounded queue and the saturated workers") StorageBoundary.spec
  , Entry "Storage.Classes" (Concurrent "explicit-before-camera and fair scheduling on the workers") StorageClasses.spec
  , Entry "Storage.Lifecycle" (Concurrent "close, cancellation and held calls on the workers") StorageLifecycle.spec
  , Entry "Storage.Opacity" (Alone "compiles an external client with ghc; measures and races nothing") StorageOpacity.spec
  ]
  where
    pureStore = "a pure model: no thread, file, clock or gate"
    measures = "measures the process (a live heap or allocated bytes): valid on one capability, beside nothing"

-- | The modules of the multi-capability pass, in their order.
concurrentEntries ∷ [Entry]
concurrentEntries = [e | e ← entries, isConcurrent (entryDisposition e)]
  where
    isConcurrent (Concurrent _) = True
    isConcurrent (Alone _) = False

-- | The sequential order: every module, one example at a time, each on one capability behind the isolation guard.
sequentialSpec ∷ Spec
sequentialSpec = forM_ entries entrySpec

-- | The label of the pass: a fixed text, so that an example's identity is the same at every capability count.
passLabel ∷ String
passLabel = "The multi-capability pass"

-- | The concurrent modules once more, last: before the first example the pass sets and prints its count; around each example it
-- sets the count, fails if a parallel example is running or the runtime does not report the count, and checks it again at the end.
passSpec ∷ PassSetting → Spec
passSpec setting =
  describe passLabel
    $ beforeAll_ (enterPass setting >> passLine setting >>= printLine)
    $ around_ (\example → Isolation.passGuard setting >> inPass setting example)
    $ forM_ concurrentEntries entrySpec
