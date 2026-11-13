-- | Discovery through the backed service (requirement 5): removals that open a sealed cavity leave
-- obligations in the arena's store; the owner runs discovery batches through the one publication
-- decision until none remains; what is known is then read back through the arena's file (the
-- knowledge query pins a committed version and reads its pages through the backend: nothing of it
-- is in RAM) and compared with #661's own plain reference run over the same removals, uninterrupted.
-- Batches are made small (one structural update each) so that the drain spans many transactions.
module Test.TerrainRuntime.Backed.Discovery (spec) where

import Control.Concurrent.STM
import Control.Monad (foldM, forM, forM_)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime
import Test.Hspec
import Test.TerrainRuntime.Fixtures hiding (limitsWith)
import Test.TerrainRuntime.Store.Scenes (Scene (..), envFor, limitsWith, openingA, openingB, twoOpenings)

-- | The reference: #661's model over its own in-memory records, every removal applied with its
-- obligation, then discovery stepped until no obligation remains.
reference ∷ ArenaId → [(Integer, Integer, Integer)] → Either String D.Retained
reference aid cells = do
  let env = envFor (limitsWith 64) twoOpenings
      apply r cand = either (Left . show) Right (D.applyCandidate cand r)
  removed ← foldM
    ( \r (x, y, z) → case D.stageRemoval env (D.retainedHeader r) (D.retainedProvider r) (D.allowanceOf (D.envLimits env)) (tile x y z) of
        Right (D.Staged cand) → apply r cand
        Right D.NoChange → Right r
        other → Left ("reference removal: " <> show other)
    )
    (D.newRetained aid)
    cells
  let drain n r
        | n > (10000 ∷ Int) = Left "the reference did not drain"
        | otherwise = case D.stepDiscovery env (D.retainedHeader r) (D.retainedProvider r) (D.allowanceOf (D.envLimits env)) of
            Right D.Idle → Right r
            Right (D.Progress cand _) → apply r cand >>= drain (n + 1)
            other → Left ("reference discovery: " <> show other)
  drain 0 removed

-- | The cells compared: the cavity, its walls and the shafts, around the sky.
compared ∷ [(Integer, Integer, Integer)]
compared = [(x, y, z) | x ← [0 .. 10], y ← [0 .. 4], z ← [4 .. 8]]

spec ∷ Spec
spec = describe "Discovery through the backed service" $
  it "drains the obligations of two openings through the decision, and what the store knows is the reference's" $
    withService defaultConfig {configDiscovery = limitsWith 1} $ \svc → do
      client ← okOf (registerClient svc)
      lease ← okOf (openArena svc client "cave" (sceneSpec twoOpenings)) >>= await svc >>= expectSuccess
      let cells = openingA <> openingB
      forM_ cells $ \(x, y, z) → removeCell' svc lease (tile x y z)
      -- the owner drains discovery on its own: no request asks for it
      waitFor $ arenaStatusSTM svc lease >>= \case
        Right st → check (statusDiscovery st == DiscoveryIdle)
        Left _ → retry
      answers ← forM compared $ \(x, y, z) → okOf (knowledgeAt svc lease (tile x y z)) >>= await svc >>= expectSuccess
      incarnation ← case answers of a : _ → pure (knowledgeIncarnation a); [] → fail "no answer"
      expected ← either fail pure (reference incarnation cells)
      let env = envFor (limitsWith 64) twoOpenings
      forM_ (zip compared answers) $ \((x, y, z), answer) →
        (((x, y, z), Right (knowledgeValue answer)) `shouldBe` ((x, y, z), D.observedValue (D.queryCell env (D.retainedProvider expected) (tile x y z))))
      status ← arenaStatus svc lease >>= expectRight
      statusPendingItems status `shouldBe` 0
      settleChecks svc
