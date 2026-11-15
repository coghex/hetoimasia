-- | The session's one mutating transaction is shared fairly (requirements 4 and 7): explicit
-- removals in admission order, internal work one grant after every 'internalTurn' explicit grants
-- while explicit work waits, and a finite accepted trace finishes. Internal turns rotate over
-- (arena, kind): reclamation that a stream of removals keeps wanting does not keep discovery from
-- PUBLISHING, and one arena's internal work does not keep another's from its turns.
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
spec = describe "The mutation slot's fairness" $ do
  it "grants waiting explicit removals in admission order with internal work one grant in every four, discovery publishing among them, and finishes the trace" $ do
    grants ← newTVarIO []
    -- the grants and discovery's publications in one order: Left a grant (Just a request, Nothing
    -- internal work), Right a discovery commit
    let probe = Probe $ \case
          PointGranted who _ → atomically (modifyTVar' grants (<> [Left who]))
          PointDiscoveryCommitted _ → atomically (modifyTVar' grants (<> [Right ()]))
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
      -- every host becomes eligible in ONE transaction: from then on all nine explicit removals wait at
      -- once (granting them one by one would let internal work take the slot legitimately in between)
      atomically $ do
        writeTVar grants []
        forM_ hosts $ \host → writeTVar (hostEligible host) True
      forM_ hosts $ \host → waitFor (readTVar (hostSettled host) >>= \s → check (not (null s)))
      events ← readTVarIO grants
      let order = [who | Left who ← events]
      -- every removal changed content, in admission order: their committed revisions increase with it
      settled ← mapM settledOf hosts
      let revisions = [removeRevision r | [Succeeded (ARemoved r)] ← settled]
      length revisions `shouldBe` length hosts
      and (zipWith (<) revisions (drop 1 revisions)) `shouldBe` True
      -- the k-th explicit grant came at most (k - 1) + ceil(k / turn) + 1 grants into the sequence: the earlier
      -- explicit ones, the internal ones the fairness rule let in between, and one already running
      let explicitAt = [i | (i, Just _) ← zip [0 ∷ Int ..] order]
      length explicitAt `shouldBe` length hosts
      -- (a violation is reported with the whole order of grants: Just a request, Nothing internal work)
      ([(k, i) | (k, i) ← zip [1 ∷ Int ..] explicitAt, i > (k - 1) + (k + turn - 1) `div` turn + 1], order) `shouldBe` ([], order)
      -- and discovery was not starved while they waited: it PUBLISHED among them (a discovery commit
      -- before the last explicit grant; an internal grant alone may be reclamation)
      let lastExplicit = maximum (0 : [i | (i, Left (Just _)) ← zip [0 ∷ Int ..] events])
      length [() | Right () ← take lastExplicit events] `shouldSatisfy` (> 0)
      settleChecks svc

  -- arena "stream" (opened first, so first in every fixed order) takes a stream of removals, each of
  -- which retires pages, so it has internal work wanted at every internal turn; arena "cave" has
  -- internal work too (discovery obligations, and the pages its openings retired)
  it "gives another arena's internal work a turn within one rotation while one arena's removals keep its own internal work wanted" $ do
    internalGrants ← newTVarIO []
    explicitGrants ← newTVarIO (0 ∷ Int)
    let probe = Probe $ \case
          PointGranted (Just _) _ → atomically (modifyTVar' explicitGrants (+ 1))
          PointGranted Nothing aid → atomically (readTVar explicitGrants >>= \n → modifyTVar' internalGrants (<> [(aid, n)]))
          _ → pure ()
    withServiceUsing defaultConfig {configDiscovery = limitsWith 1} alwaysAdmitting probe $ \svc → do
      client ← okOf (registerClient svc)
      stream ← okOf (openArena svc client "stream" soilOverStone) >>= await svc >>= expectSuccess
      cave ← okOf (openArena svc client "cave" (sceneSpec twoOpenings)) >>= await svc >>= expectSuccess
      caveId ← maybe (fail "cave vanished") (pure . viewIncarnation) =<< inspectArena svc cave
      forM_ openingA $ \(x, y, z) → removeCell' svc cave (tile x y z)
      -- twelve removals: four internal turns (one after every three explicit grants) within the stream,
      -- as many as there are (arena, kind) pairs to rotate over
      let cells = [(x, 4, 3) | x ← [0 .. 11]]
      hosts ← forM cells $ \(x, y, z) → do
        host ← newHost False
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing host) stream (tile x y z) Nothing)
        pure host
      forM_ hosts $ \host → waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      atomically $ do
        writeTVar internalGrants []
        writeTVar explicitGrants 0
        forM_ hosts $ \host → writeTVar (hostEligible host) True
      forM_ hosts $ \host → waitFor (readTVar (hostSettled host) >>= \s → check (not (null s)))
      -- the cave's internal work had a grant while the stream's removals were still being granted: the
      -- rotation reaches it within one rotation of the internal turns
      granted ← readTVarIO internalGrants
      ([n | (aid, n) ← granted, aid == caveId, n < length hosts], granted) `shouldSatisfy` (not . null . fst)
      settleChecks svc
