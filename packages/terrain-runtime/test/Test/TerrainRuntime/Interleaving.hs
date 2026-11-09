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
import Hetoimasia.Terrain.Coordinate (RegionCoord, decomposeTile)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Source (SourceSpec)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Fixtures
import Test.TerrainRuntime.Usage (jobStartDisagreements, usageSTM)

data World = World
  { wClients ∷ IORef [Client]
  , wLeases ∷ IORef [ArenaLease]
  , wRequests ∷ IORef [(Request, Host)]
  , wViews ∷ IORef [View]
  , wRandom ∷ IORef Word64
  , wTrouble ∷ IORef [String]
  , wRetiring ∷ IORef Int
  , wJobs ∷ IORef Int
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
  plain <- runIO (newIORef (0 ∷ Int))
  jobsSeen <- runIO (newIORef (0 ∷ Int))
  forM_ [1 .. 24 ∷ Word64] $ \seed →
    it ("keeps every invariant and settles every request exactly once (seed " <> show seed <> ")") $
      runSeed (tightConfig (2, 1, 2) 3 4096) False seed >>= \(n, _, j) → modifyIORef' plain (+ n) >> modifyIORef' jobsSeen (+ j)
  covers "the plain runs" plain
  it "has load jobs the owner ran, each checked at the moment it started, across the plain runs" $ readIORef jobsSeen >>= \n → n `shouldSatisfy` (> 0)
  -- The same, with cancellations, lease releases and client ends injected by the owner
  -- itself inside its preparations, where credits must be held to the safe point.
  injected <- runIO (newIORef (0 ∷ Int))
  forM_ [1 .. 24 ∷ Word64] $ \seed →
    it ("keeps every invariant when releases arrive while a preparation runs (seed " <> show seed <> ")") $
      runSeed (tightConfig (2, 1, 2) 3 4096) True seed >>= \(n, _, _) → modifyIORef' injected (+ n)
  covers "the runs with releases inside preparations" injected
  -- And under capacity pressure that later clears: a bank that holds about two
  -- regions and two commands, so refusals and waits are routine; every request must
  -- still settle once the hosts are granted.
  pressed <- runIO (newIORef (0 ∷ Int))
  forM_ [1 .. 16 ∷ Word64] $ \seed →
    it ("settles every request once pressure clears (seed " <> show seed <> ")") $
      runSeed (microConfigSlots 3) True (seed + 100) >>= \(n, _, _) → modifyIORef' pressed (+ n)
  covers "the runs under capacity pressure" pressed
  -- And under tight service-wide limits (two arenas, a handful of leases and views),
  -- where a closed arena whose snapshot is borrowed is routinely retiring while an
  -- open is admitted or refused. After every step each limit's count must equal the
  -- entities holding the resource of every state, retiring included, and no
  -- admission may exceed it.
  limited <- runIO (newIORef (0 ∷ Int))
  retiringSeen <- runIO (newIORef (0 ∷ Int))
  forM_ [1 .. 24 ∷ Word64] $ \seed →
    it ("counts every resource-holding entity against every limit (seed " <> show seed <> ")") $
      runSeed ((tightConfig (2, 1, 2) 3 4096) {configMaxArenas = 2, configMaxLeases = 5, configMaxViews = 2, configMaxClients = 3}) True (seed + 200) >>= \(n, r, _) → modifyIORef' limited (+ n) >> modifyIORef' retiringSeen (+ r)
  covers "the runs under tight service limits" limited
  it "has steps where a closed arena was still retiring across the runs under tight service limits" $ readIORef retiringSeen >>= \n → n `shouldSatisfy` (> 0)
  where
    -- A single seed may by chance end with no success; a group of them must not.
    covers label counter = it ("has requests that succeed across " <> label) $ readIORef counter >>= \n → n `shouldSatisfy` (> 0)

-- | One seeded run. With the injection on, the owner performs a seeded cancellation,
-- lease release or client end inside each preparation, and the model and table are
-- checked there too, while the credits are held.
runSeed ∷ Config → Bool → Word64 → IO (Int, Int, Int)
runSeed config inject seed = do
  hook <- newIORef Nothing
  let probe = Probe $ \point → case point of
        PointStaging _ | inject → inside hook
        PointCaptured {} | inject → inside hook
        PointJob arena loaded → job hook arena loaded
        _ → pure ()
  withServiceUsing config alwaysAdmitting probe $ \svc → do
        world <- World <$> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef (seed * 7919) <*> newIORef [] <*> newIORef 0 <*> newIORef 0
        writeIORef hook (Just (svc, world))
        -- Two clients and a first arena, so the steps have something to act on.
        forM_ [0, 1 ∷ Int] $ \_ → registerClient svc >>= either (const (pure ())) (\c → modifyIORef' (wClients world) (c :))
        firstClient <- head' <$> readIORef (wClients world)
        forM_ firstClient $ \c → openArena svc c "arena0" thinSoil >>= either (const (pure ())) (\p → await svc p >>= either (const (pure ())) (\l → modifyIORef' (wLeases world) (l :)))
        replicateM_ 300 (harvest world >> randomStep svc world 0 >> checkAll svc world)
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
        readIORef (wTrouble world) >>= (`shouldBe` [])
        -- Every region and arena has ended: nothing is remembered about retrying them.
        inspectRetryMemory svc `shouldReturn` 0
        settleChecks svc
        retiring <- readIORef (wRetiring world)
        jobs <- readIORef (wJobs world)
        pure (length [() | [Succeeded _] <- outcomes], retiring, jobs)
  where
    head' = \case (x : _) → Just x; [] → Nothing
    -- Everything has ended: no charge outlives its holder, so every bank reads zero,
    -- occupied as well as reserved (an arena's whole retained account, a coalescing
    -- excess included, goes back when the arena retires), and so does every slot.
    settledModel m =
      and [ledgerReserved (bankLedger m b) == 0 && ledgerOccupied (bankLedger m b) == 0 | b ← [ResidentBank, EditBank, StagingBank]]
        && slotInUse m CommandSlot == 0
        && slotInUse m LoadJobSlot == 0
        && null (modelArenas m)

-- | The state is coherent, no defect was recorded and every limit's count equals what
-- holds the resource, wherever it is looked at: between steps and inside a borrow.
checkAll ∷ Service → World → IO ()
checkAll svc world = do
    found <- inspectInvariants svc
    defects <- inspectDefects svc
    when (not (null found) || not (null defects)) $
      atomicModifyIORef' (wTrouble world) (\t → ((show found <> show defects) : t, ()))
    found `shouldBe` []
    defects `shouldBe` []
    -- Each limit: what admission counts is what the entities hold, and within the limit.
    rows <- inspectLimits svc
    let off = [row | row ← rows, limitRowCounted row /= limitRowHeld row || limitRowCounted row > limitRowMax row]
    unless (null off) $ atomicModifyIORef' (wTrouble world) (\t → (("limits: " <> show off) : t, ()))
    off `shouldBe` []
    -- Every bank and slot, from the entities alone, in one consistent look: the model's
    -- own arenas (live and retiring), regions, jobs, requests, interests, holds and
    -- views, and the service's own view of each arena the harness still holds a lease on.
    -- (the service's own census and the model, read in one transaction).
    (model, usage) <- atomically ((,) <$> inspectModelSTM svc <*> usageSTM svc)
    unless (null usage) $ atomicModifyIORef' (wTrouble world) (\t → (("usage: " <> show usage) : t, ()))
    usage `shouldBe` []
    when (any ((== ArenaRetiringPhase) . arenaPhase) (modelArenas model)) (modifyIORef' (wRetiring world) (+ 1))

-- | The owner's own release inside a preparation: a seeded choice among cancelling a
-- request, releasing a lease, ending a client, or nothing, then a check that the
-- state is coherent while the credits are held.
inside ∷ IORef (Maybe (Service, World)) → IO ()
inside hook = readIORef hook >>= mapM_ (\(svc, world) → do
  roll <- next world 8
  case roll of
    0 → releaseOne svc world
    1 → releaseOne svc world
    2 → readIORef (wLeases world) >>= pick world >>= mapM_ (void . releaseLease svc)
    3 → readIORef (wClients world) >>= pick world >>= mapM_ (endClient svc)
    _ → pure ()
  found <- inspectInvariants svc
  when (not (null found)) (atomicModifyIORef' (wTrouble world) (\t → (("inside a preparation: " <> show found) : t, ())))
  -- Right after the release, before the owner resumes: every bank, slot and arena is
  -- still charged at least what the service holds (the preparation, and any request or
  -- arena it kept alive, still hold their credits).
  usageHere svc world "inside a preparation after a release")
  where
    releaseOne svc world = readIORef (wRequests world) >>= pick world >>= mapM_ (\(request, _) → void (cancel svc request))

-- | The census and the model, in one transaction, compared; any disagreement is kept as a
-- property failure. Safe on the owner's own thread.
usageHere ∷ Service → World → String → IO ()
usageHere svc world where' = do
  usage <- atomically (usageSTM svc)
  unless (null usage) $ atomicModifyIORef' (wTrouble world) (\t → ((where' <> ": " <> show usage) : t, ()))

-- | The owner is about to run a load job: it recorded the job (with its slot and its
-- reservation and scratch), the model still holds it running in those amounts, and every
-- bank, slot and arena still covers what the service holds.
job ∷ IORef (Maybe (Service, World)) → ArenaId → RegionCoord → IO ()
job hook arena loaded = readIORef hook >>= mapM_ (\(svc, world) → do
  (model, census) <- atomically ((,) <$> inspectModelSTM svc <*> inspectCensusSTM svc)
  let found = jobStartDisagreements census model arena loaded
  unless (null found) $ atomicModifyIORef' (wTrouble world) (\t → (("at a job: " <> show found) : t, ()))
  atomicModifyIORef' (wJobs world) (\n → (n + 1, ())))

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
          void $ withSnapshot svc l [area] $ \_ → do
            -- Often the borrower's own arena is closed while the borrow is held: the
            -- arena is then retiring, and still counts against every limit.
            closing <- next world 3
            when (closing == 0) (void (releaseLease svc l))
            checkAll svc world
            replicateM_ 6 (randomStep svc world (depth + 1) >> checkAll svc world)
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
