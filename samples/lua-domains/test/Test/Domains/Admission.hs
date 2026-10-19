-- | Tick assignment cannot race the tick (requirement 7): many admissions raced against the driver's
-- grants, and every accepted intention was settled at exactly the tick it was accepted for.
module Test.Domains.Admission (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Monad (forM, unless, when)
import Data.List (nub, sort)
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains
  ( Answer (Accepted, Full)
  , Bounds (boundPlaces, boundQueue, boundStaleListed)
  , Domains (domainsShared)
  , DomainsConfig (configBounds, configInput)
  , Dispositions (dispApplied, dispStale, dispStaleOmitted)
  , GameSnapshot (snapDispositions, snapTick)
  , Placement (placeTick)
  , Stale (stalePlace)
  , stepTick
  )
import Hetoimasia.Sample.LuaDomains.Intention (Submitted (Submitted))
import Hetoimasia.Sample.LuaDomains.Queue (reserved)
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedQueue), submit)
import Test.Domains.Support
import Test.Hspec

ticks ∷ Word64
ticks = 60

producers ∷ Int
producers = 4

spec ∷ Spec
spec = describe "tick assignment" $
  it "never accepts an intention for a tick that has started: racing admissions are each applied or rejected at the tick they were accepted for" $
    withSample (\config → config {configInput = [], configBounds = (configBounds config) {boundPlaces = 4, boundQueue = 8, boundStaleListed = 4}}) $
      \_ _ domains → do
        let shared = domainsShared domains
        stop ← newTVarIO False
        acceptedBy ← newTVarIO []
        fulls ← newTVarIO (0 ∷ Int)
        let produce number = go
              where
                go = do
                  done ← readTVarIO stop
                  unless done $ do
                    -- Version zero: once the entity has moved, the intention is stale at its tick.
                    answer ← submit shared (Submitted 1 0 (fromIntegral (number `mod` 8)) 0 1 0)
                    case answer of
                      Accepted place → atomically (modifyTVar' acceptedBy (place :))
                      Full → atomically (modifyTVar' fulls (+ 1))
                      _ → pure ()
                    yield
                    go
        collectors ← forM [1 .. producers] (spawn . produce)
        -- Start the ticks once the producers are demonstrably at work: some intentions are taken and
        -- the tick's places are full. Everything after that races the driver.
        waitFor $ do
          taken ← readTVar acceptedBy
          refused ← readTVar fulls
          when (null taken || refused == 0) retry
        snapshots ← generous (mapM (const (stepTick domains)) [1 .. ticks])
        atomically (writeTVar stop True)
        sequence_ collectors
        accepted ← readTVarIO acceptedBy
        let settled = [(snapTick snapshot, place) | snapshot ← snapshots, let d = snapDispositions snapshot, place ← dispApplied d <> map stalePlace (dispStale d)]
            omitted = sum [dispStaleOmitted (snapDispositions snapshot) | snapshot ← snapshots]
            inRun = [place | place ← accepted, placeTick place <= ticks]
            beyond = [place | place ← accepted, placeTick place > ticks]
        -- Each intention settled in the snapshot of the very tick it was accepted for.
        [() | (tick, place) ← settled, placeTick place /= tick] `shouldBe` []
        omitted `shouldBe` 0
        -- Every accepted intention for a tick that ran was settled once, and none twice.
        sort (map snd settled) `shouldBe` sort inRun
        length (nub accepted) `shouldBe` length accepted
        -- What was accepted for the tick after the last is still reserved, not dropped.
        atomically (reserved (sharedQueue shared)) `shouldReturn` length beyond
