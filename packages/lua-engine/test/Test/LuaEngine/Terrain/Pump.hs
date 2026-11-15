{-# LANGUAGE OverloadedStrings #-}

-- | The examples of the pump the terrain set steps its scripts with (#692): 'stepNext' and what is built on it in
-- "Test.LuaEngine.Facade.Support", over real supervised presentation and gameplay owners and the world's fake timer. Every wait
-- is coordinated (a registration, a thread parked in a transaction, a printed line); the only timed wait is the bound the last
-- examples make fire on purpose, short, around an operation that can never end otherwise.
module Test.LuaEngine.Terrain.Pump (spec) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (ErrorCall (ErrorCall), throwIO, try)
import Data.Either (isLeft)
import Data.IORef (readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Scheduler (TimerBackend (..))
import System.Timeout (timeout)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.Support.Owned (withOwnedThread)

-- | A script whose every update prints how many updates it has run.
counter ∷ Script
counter = script {scInit = ["self.n = 0"], scUpdate = ["self.n = self.n + 1", "print('n=' .. self.n)"]}

counted ∷ Int → [Text]
counted n = ["n=" <> Text.pack (show k) | k ← [1 .. n]]

-- | A bound that fires after a fifth of a second: for an operation that must be ended by the bound around the whole of it.
shortBound ∷ IO () → IO ()
shortBound action = timeout 200000 action >>= maybe (throwIO (ErrorCall "the bound fired")) pure

-- | Run a body over one presentation VM of the counter, not yet admitted.
withCounterVm ∷ (World → Fvm → IO a) → IO a
withCounterVm body =
  withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource counter)]) $ \world _ runtime →
    withFvm world runtime presentationShape (body world)

spec ∷ Spec
spec = describe "The Lua test pump" $ do
  it "wakes one update at a time: waiting for the third update's line runs three updates, and the fourth only at another step" $
    withCounterVm $ \world fvm → do
      _ ← spawn world fvm "modules-test" mainPath
      stepUntil world (elem "n=3" <$> outLinesSTM world)
      -- the owner has ended the third update's turn (its next registration is live), and nothing else wakes it
      awaitTimers world 1
      outLines world `shouldReturn` counted 3
      stepOnce world
      _ ← awaitOut world 4
      awaitTimers world 1
      outLines world `shouldReturn` counted 4

  it "waits, without waking anything, for a registration that has not appeared, and wakes it once when it does" $
    withCounterVm $ \world fvm →
      withOwnedThread (stepOnce world) $ \stepping ended → do
        -- nothing is registered: the step waits in its transaction
        awaitBlockedOnSTM stepping
        outLines world `shouldReturn` []
        -- the instance's first point is registered when its init has run: the step wakes exactly that one
        _ ← spawn world fvm "modules-test" mainPath
        ended
        _ ← awaitOut world 1
        awaitTimers world 1
        outLines world `shouldReturn` counted 1

  it "never wakes a cancelled registration, and wakes the next one armed" $
    withWorld fixedM1Profile (Layout []) $ \world _ _ → do
      first ← newTVarIO False
      second ← newTVarIO False
      let TimerBackend arm = worldTimer world
      cancel ← arm 1000 (atomically (writeTVar first True))
      cancel
      withOwnedThread (stepOnce world) $ \stepping ended → do
        awaitBlockedOnSTM stepping
        _ ← arm 2000 (atomically (writeTVar second True))
        ended
      (,) <$> readTVarIO first <*> readTVarIO second `shouldReturn` (False, True)

  it "stops when the condition holds, with nothing registered, and claims nothing when it already holds" $
    withWorld fixedM1Profile (Layout []) $ \world _ _ → do
      stop ← newTVarIO False
      withOwnedThread (stepUntil world (readTVar stop)) $ \stepping ended → do
        awaitBlockedOnSTM stepping
        atomically (writeTVar stop True)
        ended
      woken ← newTVarIO False
      let TimerBackend arm = worldTimer world
      _ ← arm 1000 (atomically (writeTVar woken True))
      stepUntil world (pure True)
      readTVarIO woken `shouldReturn` False
      liveTimers world `shouldReturn` 1

  it "moves the clock of the VM it wakes to exactly the registration's deadline, and the world's only for a registration of no VM" $ do
    withWorld fixedM1Profile (Layout []) $ \world _ _ → do
      let TimerBackend arm = worldTimer world
      _ ← arm 1500 (pure ())
      stepOnce world
      readIORef (wClock world) `shouldReturn` 1500000
    withCounterVm $ \world fvm → do
      _ ← spawn world fvm "modules-test" mainPath
      stepUntil world (elem "n=2" <$> outLinesSTM world)
      -- the VM ran two updates a second apart on its own clock: the world's clock, which every other VM reads, did not move
      readIORef (wClock world) `shouldReturn` 0

  it "bounds the whole pumping operation once: steps that each end are still ended by the bound around them" $
    withCounterVm $ \world fvm → do
      _ ← spawn world fvm "modules-test" mainPath
      ended ← try @ErrorCall (stepUntilWithin shortBound world (pure False))
      ended `shouldSatisfy` isLeft
      length <$> outLines world >>= (`shouldSatisfy` (> 0))

  it "fails by the bound, rather than waiting on, a registration that never appears" $
    withWorld fixedM1Profile (Layout []) $ \world _ _ → do
      ended ← try @ErrorCall (stepUntilWithin shortBound world (pure False))
      ended `shouldSatisfy` isLeft

  it "grants a gameplay VM one tick at a time: waiting for the third update's line grants three ticks" $
    withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource counter)]) $ \world control runtime →
      withFvm world runtime gameplayShape $ \fvm → do
        _ ← spawn world fvm "modules-test" mainPath
        tickUntil fvm (elem "n=3" <$> outLinesSTM world)
        -- the tick that ran the third update completes, and no other was granted
        awaitTickDone control fvm
        outLines world `shouldReturn` counted 3
