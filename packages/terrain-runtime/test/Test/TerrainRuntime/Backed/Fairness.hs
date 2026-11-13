-- | The session's one mutating transaction is shared fairly (requirements 4 and 7): explicit
-- removals in admission order, internal work (discovery) one grant after every 'internalTurn'
-- explicit grants while explicit work waits, and a finite accepted trace finishes.
--
-- The order of grants is the owner's own record ('PointGranted', reported as each grant is made).
-- Nothing sleeps: the removals are admitted with their hosts not yet eligible, all made eligible
-- at once, and the example waits for their settlements.
module Test.TerrainRuntime.Backed.Fairness (spec) where

import Control.Concurrent.STM
import Control.Monad (forM, forM_)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Test.Hspec
import Test.TerrainRuntime.Fixtures hiding (limitsWith)
import Test.TerrainRuntime.Store.Scenes (Scene (..), limitsWith, openingA, twoOpenings)

-- | 'internalTurn' of the owner: explicit grants before internal work gets one while explicit work waits.
turn ∷ Int
turn = 3

spec ∷ Spec
spec = describe "The mutation slot's fairness" $
  it "grants waiting explicit removals in admission order with discovery one grant in every four, and finishes the trace" $ do
    grants ← newTVarIO []
    let probe = Probe $ \case
          PointGranted who _ → atomically (modifyTVar' grants (<> [who]))
          _ → pure ()
    withServiceUsing defaultConfig {configDiscovery = limitsWith 1} alwaysAdmitting probe $ \svc → do
      client ← okOf (registerClient svc)
      lease ← okOf (openArena svc client "cave" (sceneSpec twoOpenings)) >>= await svc >>= expectSuccess
      -- an opening leaves discovery obligations behind: internal work that keeps wanting the slot
      forM_ openingA $ \(x, y, z) → removeCell' svc lease (tile x y z)
      -- nine removals of solid cells, admitted and staged, none eligible yet
      let cells = [(x, 4, 3) | x ← [0 .. 8]]
      hosts ← forM cells $ \(x, y, z) → do
        host ← newHost False
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile x y z) Nothing)
        pure host
      forM_ hosts $ \host → waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      atomically (writeTVar grants [])
      forM_ hosts grant
      forM_ hosts $ \host → waitFor (readTVar (hostSettled host) >>= \s → check (not (null s)))
      order ← readTVarIO grants
      -- every removal changed content, in admission order: their committed revisions increase with it
      settled ← mapM settledOf hosts
      let revisions = [removeRevision r | [Succeeded (ARemoved r)] ← settled]
      length revisions `shouldBe` length hosts
      and (zipWith (<) revisions (drop 1 revisions)) `shouldBe` True
      -- the k-th explicit grant came at most (k - 1) + ceil(k / turn) + 1 grants into the sequence: the earlier
      -- explicit ones, the internal ones the fairness rule let in between, and one already running
      let explicitAt = [i | (i, Just _) ← zip [0 ∷ Int ..] order]
      length explicitAt `shouldBe` length hosts
      forM_ (zip [1 ∷ Int ..] explicitAt) $ \(k, i) → i `shouldSatisfy` (<= (k - 1) + (k + turn - 1) `div` turn + 1)
      -- and discovery was not starved while they waited: it had grants among them
      length [() | Nothing ← take (maximum (0 : explicitAt)) order] `shouldSatisfy` (> 0)
      settleChecks svc
