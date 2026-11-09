module Test.TerrainRuntime.Spec (spec) where

import qualified Test.TerrainRuntime.Basic as Basic
import qualified Test.TerrainRuntime.Budgets as Budgets
import qualified Test.TerrainRuntime.Closure as Closure
import qualified Test.TerrainRuntime.Credits as Credits
import qualified Test.TerrainRuntime.Hardening as Hardening
import qualified Test.TerrainRuntime.Interleaving as Interleaving
import qualified Test.TerrainRuntime.Lifecycle as Lifecycle
import qualified Test.TerrainRuntime.Limits as Limits
import qualified Test.TerrainRuntime.Offload as Offload
import qualified Test.TerrainRuntime.Opacity as Opacity
import qualified Test.TerrainRuntime.Oracle as Oracle
import qualified Test.TerrainRuntime.Races as Races
import qualified Test.TerrainRuntime.Revalidation as Revalidation
import qualified Test.TerrainRuntime.Store.AdmissionSpec as StoreAdmission
import qualified Test.TerrainRuntime.Store.Allowance as StoreAllowance
import qualified Test.TerrainRuntime.Store.Boundary as StoreBoundary
import qualified Test.TerrainRuntime.Store.Bounds as StoreBounds
import qualified Test.TerrainRuntime.Store.Codec as StoreCodec
import qualified Test.TerrainRuntime.Store.Cycles as StoreCycles
import qualified Test.TerrainRuntime.Store.Evidence as StoreEvidence
import qualified Test.TerrainRuntime.Store.Faults as StoreFaults
import qualified Test.TerrainRuntime.Store.Fuzz as StoreFuzz
import qualified Test.TerrainRuntime.Store.History as StoreHistory
import qualified Test.TerrainRuntime.Store.Identity as StoreIdentity
import qualified Test.TerrainRuntime.Store.Ownership as StoreOwnership
import qualified Test.TerrainRuntime.Store.Readers as StoreReaders
import qualified Test.TerrainRuntime.Store.Replay as StoreReplay
import qualified Test.TerrainRuntime.Store.Trees as StoreTrees
import Test.Hspec (Spec)

spec ∷ Spec
spec = do
  Basic.spec
  Races.spec
  Budgets.spec
  Offload.spec
  Revalidation.spec
  Opacity.spec
  Lifecycle.spec
  Hardening.spec
  Credits.spec
  Limits.spec
  Oracle.spec
  Interleaving.spec
  Closure.spec
  StoreCodec.spec
  StoreTrees.spec
  StoreReplay.spec
  StoreFaults.spec
  StoreIdentity.spec
  StoreReaders.spec
  StoreOwnership.spec
  StoreHistory.spec
  StoreFuzz.spec
  StoreCycles.spec
  StoreEvidence.spec
  StoreAllowance.spec
  StoreAdmission.spec
  StoreBounds.spec
  StoreBoundary.spec
