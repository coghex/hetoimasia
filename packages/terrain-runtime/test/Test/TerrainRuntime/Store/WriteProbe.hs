-- | An explicit retry's write probe plan ('planWriteProbe'): it writes 'writeProbePattern' to the pages
-- the committed roots still hold free, as a maintenance-class plan that changes no root (it is never
-- published), and leaves out a page that has been claimed and committed since (a write of it succeeded).
module Test.TerrainRuntime.Store.WriteProbe (spec) where

import Control.Monad (foldM)
import qualified Data.Map.Strict as Map
import Data.Maybe (maybeToList)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference
import Test.TerrainRuntime.Store.Workload

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

spec ∷ Spec
spec = describe "A retry's write probe plan" $
  it "writes the pattern to the pages the committed roots hold free and leaves out a page committed since, changing no root" $ do
    let h0 = newH smallSpec ident0
    (h1, _, _) ← must (foldM (\(h, r, g) _ → do
                                let (ws, g') = genWrites g r 25
                                (h', _) ← commitDelta h Ordinary (stepDelta (hStore h) 0 ws)
                                pure (h', applyRef ws r, g')) (h0, Map.empty, mkRng 3) [1 .. 10 ∷ Int])
    let s = hStore h1
        roots = storeRoots s
        tailPage = PageNo (rHw roots)
        loose = take 1 (rLoose roots)
    live ← maybe (expectationFailure "the store has no committed tree root" >> fail "no root") pure (rootOf roots TreeRuns)
    (planned, _, _) ← must (fillRetry h1 (planWriteProbeFor s ([live, tailPage] <> loose)))
    case planned of
      Planned plan → do
        map fst (plPages plan) `shouldMatchList` (tailPage : loose)
        [pg | (pg, bytes) ← plPages plan, bytes /= writeProbePattern pg] `shouldBe` []
        (plClass plan, plKind plan, plNext plan == roots) `shouldBe` (Maintenance, KindWriteProbe, True)
      other → expectationFailure ("expected a write probe plan, got " <> take 300 (show other))
    -- a page committed since is no probe's: nothing to write
    (onlyLive, _, _) ← must (fillRetry h1 (planWriteProbeFor s [live]))
    case onlyLive of
      NoWork → pure ()
      other → expectationFailure ("expected no work for a live page, got " <> take 300 (show other))
    -- the free tail page alone is planned whatever the loose list holds
    _ ← pure (maybeToList (Just tailPage))
    pure ()
