-- | The intentions' ledger on every path (#499 requirements 5 and 6): every accepted intention reaches exactly one
-- terminal disposition — applied, rejected as stale, invalidated by a failure, or discarded at a stop — none twice,
-- none retried, none dropped, and after a quiescent run accepted equals their sum. Overload is explicit: the answers
-- are counted by kind and the UI never blocks.
module Test.Domains.Ledger (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Monad (forM, forM_, unless, when)
import Data.List (nub, sort)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains
  ( Answer (Accepted, Closed, Full)
  , Bounds (boundDroppedListed, boundPlaces, boundQueue)
  , Dispositions (..)
  , Domains (domainsShared)
  , DomainsConfig (configBounds, configGameplaySource, configInput, configTicks, configUiSource)
  , GameSnapshot (snapDispositions, snapStatus, snapTick)
  , Placement (placeTick)
  , SessionReport (reportCounts)
  , SessionStatus (Stopped)
  , TickOutcome (TickFailed, TickHalted)
  , retireDomains
  , runSession
  , stepTick
  , requestStop
  , stopSession
  )
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedCounts), submit)
import Hetoimasia.Sample.LuaDomains.Tally (Counts (..), countFull)
import Hetoimasia.Sample.LuaDomains.Intention (Submitted (Submitted))
import Test.Domains.Support
import Test.Hspec

-- | Gameplay's behavior with a failure at this tick, held first at the barrier of that name when asked.
failingAt ∷ Int → Bool → [Text.Text]
failingAt tick hold =
  [ "function update(self, dt)"
  , "  if world.tick() == " <> Text.pack (show tick) <> " then"
  , if hold then "    fx.hold('failing tick')" else "    -- no barrier"
  , "    error('failed at tick " <> Text.pack (show tick) <> "')"
  , "  end"
  , "  staging.move(0, 1, 0)"
  , "  staging.finish()"
  , "end"
  ]

placementsOf ∷ [Answer] → [Placement]
placementsOf answers = [place | Accepted place ← answers]

spec ∷ Spec
spec = describe "the ledger of intentions on every path" $ do
  describe "a failure" $ do
    it "invalidates what had no committed disposition: the failing tick's intentions, and those accepted for ticks that never began; earlier results stand" $
      withSample (\config → config {configInput = [], configGameplaySource = luaLines (failingAt 2 True)}) $ \fx _ domains → withReleased fx ["failing tick"] $ do
        -- Tick one commits: its three intentions are applied or stale, and that stands.
        first ← mapM (offer domains) [0, 1, 2]
        _ ← stepCommitted domains
        settledBefore ← atomically (readTVar (sharedCounts (domainsShared domains)))
        (countApplied settledBefore + countStale settledBefore) `shouldBe` 3
        -- Tick two is for two more, and is held at the barrier before it fails; two more are accepted for tick three.
        second ← mapM (offer domains) [3, 4]
        (outcome, third) ← do
          sideResult ← newEmptyMVar
          o ← driving domains (do awaitEntered fx "failing tick"; offered ← mapM (offer domains) [5, 6]; putMVar sideResult offered; releaseGate fx "failing tick")
          offered ← readMVar sideResult
          pure (o, offered)
        snapshot ← case outcome of
          TickFailed found → pure found
          other → fail ("expected the session to fail, found " <> show other)
        -- Four intentions had no terminal disposition: tick two's, applied only into the discarded batch, and tick three's.
        dispInvalidated (snapDispositions snapshot) `shouldBe` placementsOf (second <> third)
        dispInvalidatedOmitted (snapDispositions snapshot) `shouldBe` 0
        counts ← atomically (readTVar (sharedCounts (domainsShared domains)))
        (countInvalidated counts, countApplied counts, countStale counts, countDiscarded counts) `shouldBe` (4, countApplied settledBefore, countStale settledBefore, 0)
        -- The world and the committed tick are the last good ones: nothing of the failing tick's intentions is in them.
        snapTick snapshot `shouldBe` 1
        _ ← pure first
        balanced domains
        -- Nothing is applied twice or retried: another tick does not begin, and the ledger does not move.
        stepTick domains >>= (`shouldSatisfy` isHalted)
        balanced domains
        atomically (readTVar (sharedCounts (domainsShared domains))) `shouldReturn` counts

    it "invalidates what is pending when the session fails before its first tick, accepted or not yet applied" $
      withSample (\config → config {configInput = [], configGameplaySource = luaLines (failingAt 1 False)}) $ \_ _ domains → do
        accepted ← mapM (offer domains) [0, 1, 2]
        snapshot ← stepTick domains >>= \case
          TickFailed found → pure found
          other → fail ("expected the session to fail, found " <> show other)
        dispInvalidated (snapDispositions snapshot) `shouldBe` placementsOf accepted
        balanced domains
        -- Admission is closed: the UI is told so, at once, and nothing more is accepted.
        offer domains 0 `shouldReturn` Closed
        balanced domains

    it "lists at most the bound of invalidated intentions, and counts the rest" $
      withSample
        ( \config →
            config
              { configInput = []
              , configGameplaySource = luaLines (failingAt 1 False)
              , configBounds = (configBounds config) {boundDroppedListed = 2, boundPlaces = 8, boundQueue = 12}
              }
        )
        $ \_ _ domains → do
          _ ← mapM (offer domains) [0 .. 4]
          snapshot ← stepTick domains >>= \case
            TickFailed found → pure found
            other → fail ("expected the session to fail, found " <> show other)
          (length (dispInvalidated (snapDispositions snapshot)), dispInvalidatedOmitted (snapDispositions snapshot)) `shouldBe` (2, 3)
          counts ← readTVarIO (sharedCounts (domainsShared domains))
          countInvalidated counts `shouldBe` 5
          balanced domains

  describe "a stop" $ do
    it "discards what is pending: accepted for ticks that never began, listed in the final snapshot" $
      withSample (\config → config {configInput = []}) $ \_ _ domains → do
        accepted ← mapM (offer domains) [0, 1, 2, 3]
        _ ← stopSession domains
        (snapshot, revision) ← snapshotNow domains
        revision `shouldBe` 1
        snapStatus snapshot `shouldBe` Stopped
        dispDiscarded (snapDispositions snapshot) `shouldBe` placementsOf accepted
        counts ← readTVarIO (sharedCounts (domainsShared domains))
        (countAccepted counts, countDiscarded counts, countApplied counts) `shouldBe` (4, 4, 0)
        balanced domains
        offer domains 0 `shouldReturn` Closed

    it "discards the held tick's intentions and the open ones when a stop is requested while a segment is held, and commits nothing" $
      withSample (\config → config {configInput = [], configGameplaySource = luaLines ["function update(self, dt) fx.hold('held') staging.finish() end"]}) $ \fx _ domains → withReleased fx ["held"] $ do
        sealed ← mapM (offer domains) [0, 1]
        openResult ← newEmptyMVar
        outcome ←
          driving
            domains
            ( do
                awaitEntered fx "held"
                putMVar openResult =<< mapM (offer domains) [2, 3]
                -- The stop is asked for from a thread of its own and finalized on the application thread: the segment is
                -- not preempted, so the stop has begun when admission has closed and it has not finished.
                requestStop domains
                waitFor (awaitClosed domains)
                revisionNow domains `shouldReturn` 0
                releaseGate fx "held"
            )
        open ← readMVar openResult
        outcome `shouldSatisfy` isHalted
        _ ← stopSession domains
        (snapshot, revision) ← snapshotNow domains
        (revision, snapTick snapshot, snapStatus snapshot) `shouldBe` (1, 0, Stopped)
        dispDiscarded (snapDispositions snapshot) `shouldBe` placementsOf (sealed <> open)
        balanced domains

  describe "a clean run" $
    it "settles every accepted intention as applied or stale, with nothing invalidated or discarded" $
      withSample (\config → config {configInput = []}) $ \_ _ domains → do
        forM_ [1 .. 12 ∷ Int] $ \tick → do
          _ ← mapM (offer domains) [tick `mod` 8, (tick + 3) `mod` 8]
          stepCommitted domains
        _ ← retireDomains domains
        counts ← readTVarIO (sharedCounts (domainsShared domains))
        (countInvalidated counts, countDiscarded counts) `shouldBe` (0, 0)
        countAccepted counts `shouldBe` countApplied counts + countStale counts
        balanced domains

  describe "overload" $ do
    it "answers full at once from a UI that floods the intention binding, counts it by cause, and never blocks the UI, with gameplay held" $
      withSample
        ( \config →
            config
              { configInput = []
              , configBounds = (configBounds config) {boundPlaces = 4, boundQueue = 6}
              , configGameplaySource = luaLines ["function update(self, dt) fx.hold('held') staging.finish() end"]
              , configUiSource =
                  luaLines
                    [ "function update(self, dt)"
                    , "  local accepted, full = 0, 0"
                    , "  for i = 1, 40 do"
                    , "    local ok, reason = intent.submit(view.session(), 0, i % 8, 0, 1, 0)"
                    , "    if ok then accepted = accepted + 1 elseif reason == 'full' then full = full + 1 end"
                    , "  end"
                    , "  fx.record('flood ' .. accepted .. ' ' .. full)"
                    , "  ui.updated()"
                    , "end"
                    ]
              }
        )
        $ \fx ui domains → withReleased fx ["held"] $ do
          _ ←
            driving
              domains
              ( do
                  awaitEntered fx "held"
                  -- Tick one holds nothing (no intention was accepted before it began); the UI floods tick two's places.
                  tickUi domains ui
                  awaitUpdates domains 1
                  fxLines fx `shouldReturn` ["flood 4 36"]
                  counts ← readTVarIO (sharedCounts (domainsShared domains))
                  (countAccepted counts, countFull counts, countFullPlaces counts) `shouldBe` (4, 36, 36)
                  releaseGate fx "held"
              )
          pure ()

    it "adds up when several producers on threads of their own offer while ticks run: the counts are the offers, and nothing accepted is lost or duplicated" $
      withSample (\config → config {configInput = [], configTicks = Just 30, configBounds = (configBounds config) {boundPlaces = 4, boundQueue = 6}}) $ \_ _ domains → do
        let shared = domainsShared domains
        stop ← newTVarIO False
        answers ← newTVarIO ([] ∷ [Answer])
        let produce number = go (0 ∷ Int)
              where
                go n = do
                  done ← readTVarIO stop
                  unless done $ do
                    answer ← submit shared (Submitted 1 0 (fromIntegral ((number + n) `mod` 8)) 0 1 0)
                    atomically (modifyTVar' answers (answer :))
                    yield
                    go (n + 1)
        collectors ← forM [1 .. 6 ∷ Int] (spawn . produce)
        waitFor $ do
          held ← readTVar answers
          when (length held < 30) retry
        report ← generous (runSession domains)
        waitFor $ do
          held ← readTVar answers
          when (null [() | Closed ← held]) retry
        atomically (writeTVar stop True)
        sequence_ collectors
        offered ← readTVarIO answers
        counts ← readTVarIO (sharedCounts shared)
        -- Every offer was answered once and counted once.
        length offered `shouldBe` countAccepted counts + countFull counts + countClosed counts + countRefused counts + countMalformed counts
        length [() | Accepted _ ← offered] `shouldBe` countAccepted counts
        length [() | Full _ ← offered] `shouldBe` countFull counts
        -- None accepted was lost or duplicated: the report's ledger balanced, and no place was handed out twice.
        let places = placementsOf offered
        length (nub places) `shouldBe` length places
        countAccepted (reportCounts report) `shouldBe` countApplied (reportCounts report) + countStale (reportCounts report)
        sort [placeTick place | place ← places, placeTick place > (30 ∷ Word64)] `shouldBe` []
        balanced domains
  where
    isHalted = \case
      TickHalted → True
      _ → False
