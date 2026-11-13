-- | Discovery through the backed service (requirement 5): removals that open a sealed cavity leave
-- obligations in the arena's store; the owner runs discovery batches through the one publication
-- decision until none remains; what is known is then read back through the arena's file (the
-- knowledge query pins a committed version and reads its pages through the backend: nothing of it
-- is in RAM) and compared with #661's own plain reference run over the same removals, uninterrupted.
-- Batches are made small (one structural update each) so that the drain spans many transactions.
module Test.TerrainRuntime.Backed.Discovery (spec) where

import Control.Concurrent.STM
import Control.Monad (foldM, forM, forM_)
import Data.Maybe (listToMaybe)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (NativeOp (..))
import Test.Hspec
import Test.TerrainRuntime.Fixtures hiding (limitsWith)
import Test.TerrainRuntime.Store.Scenes (Scene (..), envFor, limitsWith, openingA, openingB, sealedStack, twoOpenings)
import qualified Test.TerrainRuntime.Storage.Harness as H

isWrite ∷ NativeOp → Bool
isWrite = \case OpWriteAt {} → True; _ → False

-- | The reference: #661's model over its own in-memory records, every removal applied with its
-- obligation, then discovery stepped until no obligation remains.
reference ∷ Scene → ArenaId → [(Integer, Integer, Integer)] → Either String D.Retained
reference scene aid cells = do
  let env = envFor (limitsWith 64) scene
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

-- | The traces run through the backed service, each against #661's uninterrupted reference: the two
-- openings in both orders, buried removals that change connectivity without revealing anything and
-- then a real opening into them, and a stack opened from below the sky.
traces ∷ [(String, Scene, [(Integer, Integer, Integer)])]
traces =
  [ ("two openings, A then B", twoOpenings, openingA <> openingB)
  , ("two openings, B then A", twoOpenings, openingB <> openingA)
  , ("buried removals in the cave's wall, then opening A", twoOpenings, [(5, 4, 5), (5, 5, 5), (6, 5, 5)] <> openingA)
  , ("a sealed stack opened to the sky", sealedStack, [(3, 3, z) | z ← [2 .. 7]])
  ]

-- | The cells compared: the cavity, its walls and the shafts, around the sky.
compared ∷ [(Integer, Integer, Integer)]
compared = [(x, y, z) | x ← [0 .. 10], y ← [0 .. 5], z ← [2 .. 8]]

spec ∷ Spec
spec = describe "Discovery through the backed service" $ do
  forM_ traces $ \(label, scene, cells) →
   it ("drains the obligations through the decision, and what the store knows is the reference's: " <> label) $
    withService defaultConfig {configDiscovery = limitsWith 1} $ \svc → do
      client ← okOf (registerClient svc)
      lease ← okOf (openArena svc client "cave" (sceneSpec scene)) >>= await svc >>= expectSuccess
      forM_ cells $ \(x, y, z) → removeCell' svc lease (tile x y z)
      -- the owner drains discovery on its own: no request asks for it
      waitFor $ arenaStatusSTM svc lease >>= \case
        Right st → check (statusDiscovery st == DiscoveryIdle)
        Left _ → retry
      answers ← forM compared $ \(x, y, z) → okOf (knowledgeAt svc lease (tile x y z)) >>= await svc >>= expectSuccess
      incarnation ← case answers of a : _ → pure (knowledgeIncarnation a); [] → fail "no answer"
      expected ← either fail pure (reference scene incarnation cells)
      let env = envFor (limitsWith 64) scene
      forM_ (zip compared answers) $ \((x, y, z), answer) →
        (((x, y, z), Right (knowledgeValue answer)) `shouldBe` ((x, y, z), D.observedValue (D.queryCell env (D.retainedProvider expected) (tile x y z))))
      status ← arenaStatus svc lease >>= expectRight
      statusPendingItems status `shouldBe` 0
      settleChecks svc

  it "after every committed batch, what the store knows and the work it keeps are the uninterrupted reference's after as many batches" $ do
    probe ← H.newProbe
    withServiceSeam quiet defaultConfig {configDiscovery = limitsWith 1} alwaysAdmitting noProbe (H.seamFor probe) $ \svc → do
      client ← okOf (registerClient svc)
      lease ← okOf (openArena svc client "cave" (sceneSpec twoOpenings)) >>= await svc >>= expectSuccess
      -- one opening's three removals, admitted and staged with their hosts not yet eligible
      hosts ← forM openingA $ \(x, y, z) → do
        host ← newHost False
        _ ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile x y z) Nothing)
        pure host
      forM_ hosts $ \host → waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      -- every write is held at the seam and let through one at a time: between two looks at the store
      -- at most one transaction commits. The three removals are granted first (internal work waits its
      -- turn while they wait), then each discovery batch.
      first ← H.addGate probe isWrite
      atomically (forM_ hosts $ \host → writeTVar (hostEligible host) True)
      let incarnation = ArenaId 0
          env = envFor (limitsWith 1) twoOpenings
      -- the reference, uninterrupted: the removals, then one batch at a time until no obligation remains
      removed ← either fail pure (referenceRemoved env incarnation openingA)
      states ← either fail pure (referenceBatches env removed)
      let expectedAt r = ([D.observedValue (D.queryCell env (D.retainedProvider r) (tile x y z)) | (x, y, z) ← row], D.pendingObligations (D.retainedHeader r))
          settledAll = and <$> mapM (\h → not . null <$> readTVar (hostSettled h)) hosts
          look = do
            answers ← forM row $ \(x, y, z) → okOf (knowledgeAt svc lease (tile x y z)) >>= await svc >>= expectSuccess
            status ← arenaStatus svc lease >>= expectRight
            pure ([Right (knowledgeValue a) | a ← answers], statusPendingItems status)
          -- one look per committed state once the removals have committed, each found in the reference
          step gate seen = do
            held ← waitFor $
              (readTVar (H.gReached gate) >>= \n → check (n >= 1) >> pure True)
                `orElse` (do done ← settledAll; check done; idle ← arenaStatusSTM svc lease; case idle of Right st | statusDiscovery st == DiscoveryIdle → pure False; _ → retry)
            done ← atomically settledAll
            seen' ← if not done then pure seen else do
              observed ← look
              pure $ case seen of
                -- the same committed state as the last look (a write of a batch still in progress)
                o : _ | o == observed → seen
                _ → observed : seen
            if held
              then do
                next ← H.addGate probe isWrite
                H.openGate gate
                step next seen'
              else H.openGate gate >> pure seen'
      seen ← reverse <$> step first []
      -- every committed state was looked at, in order, from the one the removals left to the drained one,
      -- and each is the reference's after as many batches (consecutive equal states counted once)
      let collapse = \case
            a : rest@(b : _) | a == b → collapse rest
            a : rest → a : collapse rest
            [] → []
          expected = collapse (map expectedAt states)
          firstDifference = listToMaybe [i | (i, a, b) ← zip3 [0 ∷ Int ..] seen expected, a /= b]
      -- (a failure names where the sequences part: their lengths, their remaining work, the first index)
      (length seen, map snd seen, firstDifference) `shouldBe` (length expected, map snd expected, Nothing)
      settleChecks svc
  where
    row = [(x, 0, z) | x ← [0 .. 10], z ← [4 .. 8]]

-- | #661's model, the removals applied with their obligations.
referenceRemoved ∷ D.Env → ArenaId → [(Integer, Integer, Integer)] → Either String D.Retained
referenceRemoved env aid =
  foldM
    ( \r (x, y, z) → case D.stageRemoval env (D.retainedHeader r) (D.retainedProvider r) (D.allowanceOf (D.envLimits env)) (tile x y z) of
        Right (D.Staged cand) → either (Left . show) Right (D.applyCandidate cand r)
        Right D.NoChange → Right r
        other → Left ("reference removal: " <> show other)
    )
    (D.newRetained aid)

-- | Every state of the reference's drain: before the first batch, after each, ending idle.
referenceBatches ∷ D.Env → D.Retained → Either String [D.Retained]
referenceBatches env = go (0 ∷ Int)
  where
    go n r
      | n > 10000 = Left "the reference did not drain"
      | otherwise = case D.stepDiscovery env (D.retainedHeader r) (D.retainedProvider r) (D.allowanceOf (D.envLimits env)) of
          Right D.Idle → Right [r]
          Right (D.Progress cand _) → either (Left . show) Right (D.applyCandidate cand r) >>= fmap (r :) . go (n + 1)
          other → Left ("reference discovery: " <> show other)
