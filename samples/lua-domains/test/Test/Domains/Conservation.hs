-- | Exactly once, with revalidation, and conservation of intentions (requirement 8): after the run is
-- quiescent, accepted equals applied plus rejected as stale, none was applied twice and none was
-- dropped; and a finite session closes to the ticks beyond its last without losing what it accepted.
module Test.Domains.Conservation (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Monad (forM, forM_, unless, when)
import Data.List (nub, sort)
import qualified Data.Sequence as Seq
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains
  ( Answer (Accepted, Closed, Full)
  , Bounds (boundPlaces, boundQueue, boundStaleListed)
  , Dispositions (dispApplied, dispStale, dispStaleOmitted)
  , Domains (domainsShared)
  , DomainsConfig (configBounds, configInput, configTicks)
  , GameSnapshot (snapDispositions, snapWorld)
  , Placement (placeTick)
  , SessionReport (reportCounts, reportTicks)
  , Stale (stalePlace)
  , runSession
  )
import Hetoimasia.Sample.LuaDomains.Intention (Submitted (Submitted))
import Hetoimasia.Sample.LuaDomains.Queue (reserved)
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedCounts, sharedQueue), submit)
import Hetoimasia.Sample.LuaDomains.Tally (Counts (..), countFull)
import Hetoimasia.Sample.LuaDomains.World (Entity (entityVersion), World (worldEntities))
import Test.Domains.Support
import Test.Hspec

bounds ∷ Bounds → Bounds
bounds b = b {boundPlaces = 4, boundQueue = 8, boundStaleListed = 4}

spec ∷ Spec
spec = describe "conservation of intentions" $ do
  it "settles every accepted intention exactly once across a workload of full, stale and valid intentions interleaved with ticks" $
    withSample (\config → config {configInput = [], configBounds = bounds (configBounds config)}) $ \_ _ domains → do
      let shared = domainsShared domains
      answers ← newTVarIO []
      snapshots ← generous . forM [1 .. 30 ∷ Int] $ \_ → do
        current ← snapshotNow domains
        let versionOf index = entityVersion (Seq.index (worldEntities (snapWorld (fst current))) index)
            submitted =
              [ Submitted 1 0 0 (fromIntegral (versionOf 0)) 1 0 -- valid
              , Submitted 1 0 0 (fromIntegral (versionOf 0)) 0 1 -- the same entity and version: stale in sequence
              , Submitted 1 0 1 (fromIntegral (versionOf 1)) 1 1 -- valid
              , Submitted 1 0 2 (fromIntegral (versionOf 2) + 100) 1 0 -- a version that never was: stale
              , Submitted 1 0 3 (fromIntegral (versionOf 3)) 0 1 -- valid, or full when the places are taken
              , Submitted 1 0 4 (fromIntegral (versionOf 4)) 1 0 -- full
              ]
        forM_ submitted $ \one → submit shared one >>= \answer → atomically (modifyTVar' answers (answer :))
        stepCommitted domains
      given ← readTVarIO answers
      counts ← readTVarIO (sharedCounts shared)
      let accepted = [place | Accepted place ← given]
          settled = [place | snapshot ← snapshots, let d = snapDispositions snapshot, place ← dispApplied d <> map stalePlace (dispStale d)]
      -- The answers and the counters agree, and the full answers happened.
      length accepted `shouldBe` countAccepted counts
      length [() | Full _ ← given] `shouldBe` countFull counts
      countFull counts `shouldSatisfy` (> 0)
      -- Applied and stale both happened, and together they are what was accepted.
      countApplied counts `shouldSatisfy` (> 0)
      countStale counts `shouldSatisfy` (> 0)
      countAccepted counts `shouldBe` countApplied counts + countStale counts
      sum [dispStaleOmitted (snapDispositions snapshot) | snapshot ← snapshots] `shouldBe` 0
      -- None was applied twice and none was dropped: the settled places are the accepted ones.
      sort settled `shouldBe` sort accepted
      length (nub settled) `shouldBe` length settled
      atomically (reserved (sharedQueue shared)) `shouldReturn` 0

  it "closes a finite session to the ticks beyond its last: exactly its ticks are committed and nothing accepted is left unsettled" $
    withSample (\config → config {configInput = [], configTicks = Just 25, configBounds = bounds (configBounds config)}) $ \_ _ domains → do
      let shared = domainsShared domains
      stop ← newTVarIO False
      acceptedBy ← newTVarIO ([] ∷ [Placement])
      closedSeen ← newTVarIO (0 ∷ Int)
      let produce number = go
            where
              go = do
                done ← readTVarIO stop
                unless done $ do
                  answer ← submit shared (Submitted 1 0 (fromIntegral (number `mod` 8)) 0 1 0)
                  case answer of
                    Accepted place → atomically (modifyTVar' acceptedBy (place :))
                    Closed → atomically (modifyTVar' closedSeen (+ 1))
                    _ → pure ()
                  yield
                  go
      collectors ← forM [1 .. 4 ∷ Int] (spawn . produce)
      waitFor (readTVar acceptedBy >>= \taken → when (null taken) retry)
      -- The producers race every grant, the last one included.
      report ← generous (runSession domains)
      -- Past the last tick the queue answers closed, and nothing more is accepted.
      waitFor (readTVar closedSeen >>= \seen → when (seen == 0) retry)
      atomically (writeTVar stop True)
      sequence_ collectors
      reportTicks report `shouldBe` 25
      revisionNow domains `shouldReturn` 25
      -- The report was read when the owners were retired, before any producer need have met a
      -- closed queue, so it says nothing of closed answers. It satisfies the law on its own; the
      -- closed answers are read afresh, once the producers have joined.
      let atRetirement = reportCounts report
      countAccepted atRetirement `shouldBe` countApplied atRetirement + countStale atRetirement
      counts ← readTVarIO (sharedCounts shared)
      countAccepted counts `shouldBe` countAccepted atRetirement
      countClosed counts `shouldSatisfy` (> 0)
      atomically (reserved (sharedQueue shared)) `shouldReturn` 0
      accepted ← readTVarIO acceptedBy
      [place | place ← accepted, placeTick place > (25 ∷ Word64)] `shouldBe` []
      length accepted `shouldBe` countAccepted counts
