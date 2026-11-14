-- | The modules that run in parallel, in ONE place, and why each may.
--
-- An example runs in parallel only if it touches no file, thread, clock, runtime statistic or shared mutable state; a shared
-- fixture it reads is immutable and built once ("Test.TerrainRuntime.Store.Depth.Fixture", behind a lock). Each family below is
-- a pure model test: it builds its stores inside its examples (or reads such a fixture), runs the production planner and the
-- independent checker over them in one thread, and prints whole lines. Nothing that measures the process (a live heap,
-- allocated bytes) or depends on scheduling may join this list: the memory rows, every storage and service example and the
-- examples that compile an external client stay sequential, on one capability, after the group
-- ("Test.TerrainRuntime.Isolation"; the order is the guarantee of hspec-core's job queue and the guard is the assertion of it).
-- A new module is added here with its reason, or not at all.
--
-- The group runs on up to eight capabilities (@Main@ sets the capability count to the runner's job count, which @--jobs@ changes).
module Test.TerrainRuntime.Parallel
  ( spec
  , Family (..)
  , families
  ) where

import Control.Monad (forM_)
import qualified Test.TerrainRuntime.Store.Cycles as StoreCycles
import qualified Test.TerrainRuntime.Store.Evidence as StoreEvidence
import qualified Test.TerrainRuntime.Store.Fuzz as StoreFuzz
import qualified Test.TerrainRuntime.Store.FuzzTrees as StoreFuzzTrees
import qualified Test.TerrainRuntime.Store.History as StoreHistory
import qualified Test.TerrainRuntime.Store.Large as StoreLarge
import qualified Test.TerrainRuntime.Store.Protocol as StoreProtocol
import qualified Test.TerrainRuntime.Store.Rebalance as StoreRebalance
import qualified Test.TerrainRuntime.Store.Scattered as StoreScattered
import qualified Test.TerrainRuntime.Store.Trees as StoreTrees
import Test.Hspec (Spec, around_, parallel)
import Test.TerrainRuntime.Isolation (tracked)

-- | A module of the parallel group and the reason it qualifies.
data Family = Family
  { famModule ∷ String
  , famWhy ∷ String
  , famSpec ∷ Spec
  }

families ∷ [Family]
families =
  [ Family "Store.Rebalance" "pure plans of single trees over hand-built and generated stores; one thread, no file, clock or statistic" StoreRebalance.spec
  , Family "Store.Scattered" "pure planning and maintenance over hand-built stores in CAFs (immutable, evaluated once); no file, thread, clock or statistic" StoreScattered.spec
  , Family "Store.Large" "pure planning over a large store built once behind a Fixture lock; no file, thread, clock or statistic" StoreLarge.spec
  , Family "Store.Protocol" "the caller protocol driven over pure plans and windows; no file, thread, clock or statistic" StoreProtocol.spec
  , Family "Store.History" "pure ownership histories over a Fixture store; no file, thread, clock or statistic" StoreHistory.spec
  , Family "Store.Trees" "pure indexes against a reference map; no file, thread, clock or statistic" StoreTrees.spec
  , Family "Store.Evidence (pure part)" "pure histories, bounds, faults and cycles that print whole EVIDENCE lines; its allocation observation (measuredSpec) is sequential" StoreEvidence.pureSpec
  , Family "Store.Fuzz" "pure reads of re-sealed pages of a Fixture store; no file, thread, clock or statistic" StoreFuzz.spec
  , Family "Store.FuzzTrees" "pure reads of re-sealed pages of a Fixture store in five trees; no file, thread, clock or statistic" StoreFuzzTrees.spec
  , Family "Store.Cycles" "pure seeded update, abort, publish, read and reclaim cycles; no file, thread, clock or statistic" StoreCycles.spec
  ]

-- | The group: every family's examples, each on its own capability up to the runner's job count, counted by the isolation guard.
spec ∷ Spec
spec = parallel $ around_ tracked $ forM_ families famSpec
