-- | A randomized interleaving over the service: submit, cancel, grant, release,
-- close, edit, borrow and demand in a pseudo-random order, with the owner running
-- concurrently, checking after every randomStep that the state is coherent and that no
-- defect was recorded; at the end every accepted request has reached exactly one
-- terminal outcome and every bank is empty.
--
-- The sequence is a function of the seed alone (a small linear congruential
-- generator, no clock), so a failing seed reproduces the same steps; the owner's
-- interleaving between them is whatever the scheduler chose, and the invariants
-- must hold at every point it could have chosen.
module Test.TerrainRuntime.Interleaving (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.STM
import Control.Monad (filterM, forM_, replicateM_, unless, void, when)
import Data.IORef
import Data.Text (pack)
import Data.Word (Word64)
import Hetoimasia.Terrain.Coordinate (decomposeTile)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Source (SourceSpec)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Fixtures

data World = World
  { wClients ∷ IORef [Client]
  , wLeases ∷ IORef [ArenaLease]
  , wRequests ∷ IORef [(Request, Host)]
  , wViews ∷ IORef [View]
  , wRandom ∷ IORef Word64
  , wTrouble ∷ IORef [String]
  }

next ∷ World → Int → IO Int
next world bound = do
  n <- atomicModifyIORef' (wRandom world) (\s → let s' = s * 6364136223846793005 + 1442695040888963407 in (s', s'))
  pure (fromIntegral ((n `div` 65536) `mod` fromIntegral bound))

pick ∷ World → [a] → IO (Maybe a)
pick _ [] = pure Nothing
pick world xs = Just . (xs !!) <$> next world (length xs)

tiles ∷ [(Integer, Integer, Integer)]
tiles = [(x, 0, z) | x ← [0, 1, 16, 17, -16], z ← [0, 1, 32]]

-- | Soil two levels thick over stone: a column's surface sits at level 1 and can be
-- edited down to -1, which is outside the tight extent, so a surface query that an
-- edit supersedes can be refused permanently when it is admitted again.
thinSoil ∷ SourceSpec
thinSoil = layered [(Just (-5), Just 0, "stone", 0), (Just 0, Just 2, "soil", 0)] []

spec ∷ Spec
spec = describe "A randomized interleaving over the service" $ do
  forM_ [1 .. 24 ∷ Word64] $ \seed →
    it ("keeps every invariant and settles every request exactly once (seed " <> show seed <> ")") $
      withService (tightConfig (2, 1, 2) 3 4096) $ \svc → do
        world <- World <$> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef (seed * 7919) <*> newIORef []
        -- Two clients and a first arena, so the steps have something to act on.
        forM_ [0, 1 ∷ Int] $ \_ → registerClient svc >>= either (const (pure ())) (\c → modifyIORef' (wClients world) (c :))
        firstClient <- head' <$> readIORef (wClients world)
        forM_ firstClient $ \c → openArena svc c "arena0" thinSoil >>= either (const (pure ())) (\p → await svc p >>= either (const (pure ())) (\l → modifyIORef' (wLeases world) (l :)))
        replicateM_ 300 (harvest world >> randomStep svc world 0 >> check' svc world)
        -- Every host is granted and every result taken as it settles: no request may
        -- stay waiting on a refusal that will never clear, so all of them settle.
        requests <- readIORef (wRequests world)
        forM_ requests $ \(_, host) → grant host
        bounded (settleAll svc requests)
        -- Wind down: every client ends.
        forM_ requests $ \(request, _) → retire svc request
        readIORef (wViews world) >>= mapM_ (closeView svc)
        readIORef (wClients world) >>= mapM_ (endClient svc)
        readIORef (wLeases world) >>= mapM_ (void . releaseLease svc)
        waitFor (inspectModelSTM svc >>= \m → check (settledModel m))
        forM_ requests $ \(request, host) → do
          retire svc request
          settled <- settledOf host
          (request, length settled) `shouldBe` (request, 1)
        outcomes <- mapM (settledOf . snd) requests
        length [() | [Succeeded _] <- outcomes] `shouldSatisfy` (>= 1)
        readIORef (wTrouble world) >>= (`shouldBe` [])
        settleChecks svc
  where
    head' = \case (x : _) → Just x; [] → Nothing
    check' svc world = do
      found <- inspectInvariants svc
      defects <- inspectDefects svc
      when (not (null found) || not (null defects)) $
        atomicModifyIORef' (wTrouble world) (\t → ((show found <> show defects) : t, ()))
      found `shouldBe` []
      defects `shouldBe` []
    settledModel m =
      and [ledgerReserved (bankLedger m b) == 0 | b ← [ResidentBank, EditBank, StagingBank]]
        && slotInUse m CommandSlot == 0
        && slotInUse m LoadJobSlot == 0

-- | Leases that have settled since the last look become usable.
harvest ∷ World → IO ()
harvest world = do
  requests <- readIORef (wRequests world)
  forM_ requests $ \(_, host) → do
    settled <- settledOf host
    forM_ settled $ \outcome → case outcome of
      Succeeded (AOpened lease) → remember lease
      Succeeded (AAttached lease) → remember lease
      _ → pure ()
  where
    remember lease = modifyIORef' (wLeases world) (\known → if lease `elem` known then known else lease : known)

randomStep ∷ Service → World → Int → IO ()
randomStep svc world depth = do
  roll <- next world 100
  clients <- readIORef (wClients world)
  leases <- readIORef (wLeases world)
  case roll of
    r
      | r < 5 → when (length clients < 3) $ registerClient svc >>= either (const (pure ())) (\c → modifyIORef' (wClients world) (c :))
      | r < 14 → withClient $ \c → do
          name <- pack . ("arena" <>) . show <$> next world 3
          opened c name
      | r < 18 → withClient $ \c → do
          name <- pack . ("arena" <>) . show <$> next world 3
          host <- newHost True
          submit host =<< attachArenaWith svc (hostEndpoint svc Nothing host) c name
      | r < 43 → withLease $ \l → do
          Just (x, y, z) <- pick world tiles
          host <- newHost =<< fmap (== 0) (next world 3)
          kind <- next world 3
          submit host =<< case kind of
            0 → cellWith svc (hostEndpoint svc Nothing host) l (tile x y z)
            1 → columnWith svc (hostEndpoint svc Nothing host) l (column x y) (range 0 2)
            _ → surfaceWith svc (hostEndpoint svc Nothing host) l (column x y)
      | r < 68 → withLease $ \l → do
          Just (x, y, z) <- pick world tiles
          host <- newHost =<< fmap (/= 0) (next world 3)
          submit host =<< removeWith svc (hostEndpoint svc Nothing host) l (tile x y z) Nothing
      | r < 73 → do
          requests <- readIORef (wRequests world)
          pick world requests >>= mapM_ (\(request, _) → void (cancel svc request))
      | r < 87 → do
          requests <- readIORef (wRequests world)
          pick world requests >>= mapM_ (\(_, host) → grant host)
      | r < 88 → pick world leases >>= mapM_ (void . releaseLease svc)
      | r < 89 → pick world clients >>= mapM_ (endClient svc)
      | r < 93 → viewStep
      | r < 98 && depth < 2 → withLease $ \l → do
          Just (x, y, z) <- pick world tiles
          let (area, _) = decomposeTile (tile x y z)
          void $ withSnapshot svc l [area] $ \_ → replicateM_ 6 (randomStep svc world (depth + 1))
      | otherwise → yield
  where
    withClient k = readIORef (wClients world) >>= pick world >>= mapM_ k
    withLease k = readIORef (wLeases world) >>= pick world >>= mapM_ k
    opened c name = do
      host <- newHost True
      r <- openArenaWith svc (hostEndpoint svc Nothing host) c name thinSoil
      submit host r
      -- The creator's lease arrives through the host; remember it once settled.
      settled <- settledOf host
      forM_ settled $ \s → case s of
        Succeeded (AOpened lease) → modifyIORef' (wLeases world) (lease :)
        _ → pure ()
    submit host = \case
      Right request → do
        modifyIORef' (wRequests world) ((request, host) :)
        -- Leases that settled by now become usable.
        settled <- settledOf host
        forM_ settled $ \s → case s of
          Succeeded (AOpened lease) → modifyIORef' (wLeases world) (lease :)
          Succeeded (AAttached lease) → modifyIORef' (wLeases world) (lease :)
          _ → pure ()
      Left _ → pure ()
    viewStep = do
      views <- readIORef (wViews world)
      leases <- readIORef (wLeases world)
      kind <- next world 4
      case (kind, views, leases) of
        (0, _, _) → withClientView
        (1, v : _, l : _) → do
          Just (x, y, z) <- pick world tiles
          let (area, local) = decomposeTile (tile x y z)
          _ <- setViewDemand svc v l [RegionDemand area (coverageTile local)]
          pure ()
        (2, v : _, _) → void (clearViewDemand svc v)
        (3, v : _, _) → closeView svc v >> modifyIORef' (wViews world) (drop 1)
        _ → pure ()
    withClientView = do
      clients <- readIORef (wClients world)
      pick world clients >>= mapM_ (\c → openView svc c >>= either (const (pure ())) (\v → modifyIORef' (wViews world) (v :)))

-- | Take every settled result until every request has settled. A request stuck
-- waiting on a permanent refusal would never settle, and this would time out.
settleAll ∷ Service → [(Request, Host)] → IO ()
settleAll svc requests = do
  forM_ requests $ \(request, host) → do
    settled <- settledOf host
    when (not (null settled)) (retire svc request)
  unsettled <- filterM (\(_, host) → null <$> settledOf host) requests
  unless (null unsettled) (yield >> settleAll svc unsettled)
