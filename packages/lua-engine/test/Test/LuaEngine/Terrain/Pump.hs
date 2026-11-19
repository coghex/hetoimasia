{-# LANGUAGE OverloadedStrings #-}

-- | The examples of the pump the terrain set steps its scripts with (#692): 'stepNext' and what is built on it in
-- "Test.LuaEngine.Facade.Support", over real supervised presentation and gameplay owners and the world's fake timer; one example
-- holds a peer VM in its update at the terrain rig's @TEST_WAIT@ fixture. Every wait is coordinated (a registration, a thread parked
-- in a transaction, a printed line, a fixture entered), each under the standard bound. A helper thread's own outcome is the
-- example's: what it raised is raised again where the example waits.
module Test.LuaEngine.Terrain.Pump (spec) where

import Control.Concurrent (ThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (SomeException, finally, throwIO, try)
import Data.IORef (readIORef)
import Data.Text (Text)
import Data.Word (Word64)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Scheduled (scheduledEndpoint, ticksOutstanding)
import Hetoimasia.Scripting.Lua.Scheduler (TimerBackend (..))
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support (Rig (rgTrace), gameplayOver, presentationOver, signalRig, withRig)
import Test.Support.Bounded (bounded)
import Test.Support.Owned (withOwnedThread)

-- | A script whose every update prints how many updates it has run.
counter ∷ Script
counter = script {scInit = ["self.n = 0"], scUpdate = ["self.n = self.n + 1", "print('n=' .. self.n)"]}

-- | A script whose every update waits at the rig's fixture until the example signals @hold@.
held ∷ Script
held = script {scUpdate = ["TEST_WAIT('hold')"]}

-- | One second of a VM's clock, in nanoseconds.
oneSecond ∷ Word64
oneSecond = 1000000000

counted ∷ Int → [Text]
counted n = ["n=" <> Text.pack (show k) | k ← [1 .. n]]

-- | 'withOwnedThread' whose body is given a wait for the action's end that answers what it returned, and raises again what it
-- raised (a failure of the action is the example's, not the end of a thread).
withChild ∷ IO a → (ThreadId → IO a → IO b) → IO b
withChild action body = do
  outcome ← newEmptyMVar
  withOwnedThread (try @SomeException action >>= putMVar outcome) $ \thread ended →
    body thread (ended >> takeMVar outcome >>= either throwIO pure)

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
      _ ← bounded (awaitOut world 4)
      awaitTimers world 1
      outLines world `shouldReturn` counted 4

  it "waits, without waking anything, for a registration that has not appeared, and wakes it once when it does" $
    withCounterVm $ \world fvm →
      withChild (stepOnce world) $ \stepping ended → do
        -- nothing is registered: the step waits in its transaction
        awaitBlockedOnSTM stepping
        outLines world `shouldReturn` []
        -- the instance's first point is registered when its init has run: the step wakes exactly that one
        _ ← spawn world fvm "modules-test" mainPath
        ended
        _ ← bounded (awaitOut world 1)
        awaitTimers world 1
        outLines world `shouldReturn` counted 1

  it "never wakes a cancelled registration, and wakes the next one armed" $
    withWorld fixedM1Profile (Layout []) $ \world _ _ → do
      first ← newTVarIO False
      second ← newTVarIO False
      let TimerBackend arm = worldTimer world
      cancel ← arm 1000 (atomically (writeTVar first True))
      cancel
      withChild (stepOnce world) $ \stepping ended → do
        awaitBlockedOnSTM stepping
        _ ← arm 2000 (atomically (writeTVar second True))
        ended
      (,) <$> readTVarIO first <*> readTVarIO second `shouldReturn` (False, True)

  it "stops when the condition holds, with nothing registered, and claims nothing when it already holds" $
    withWorld fixedM1Profile (Layout []) $ \world _ _ → do
      stop ← newTVarIO False
      withChild (stepUntil world (readTVar stop)) $ \stepping ended → do
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

  it "steps one VM while a peer is held in its update: the peer's clock stays at the deadline that woke it, and no step waits for it" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource counter), ("lua/held.lua", scriptSource held)]) $ \world _ runtime →
        -- however the example ends, the peer is let go before its owner is retired
        withFvm world runtime (presentationOver rig) $ \peer → (`finally` signalRig rig "hold") $ withFvm world runtime presentationShape $ \fvm → do
          -- a VM's reading of the clock: the world's, plus how far the step moved that VM on
          let reading vm = (+) <$> readIORef (wClock world) <*> vmAhead vm
          _ ← spawn world peer "modules-test" "lua/held.lua"
          -- the step wakes the peer's first point, a second on its clock, and the peer stays in that update
          stepUntil world (elem "entered hold" <$> readTVar (rgTrace rig))
          reading peer `shouldReturn` oneSecond
          _ ← spawn world fvm "modules-test" mainPath
          stepUntil world (elem "n=3" <$> outLinesSTM world)
          awaitTimers world 1
          -- three updates of the other VM, each one second on its own clock, and nothing more; the peer is where it was
          outLines world `shouldReturn` counted 3
          reading fvm `shouldReturn` 3 * oneSecond
          reading peer `shouldReturn` oneSecond
          readTVarIO (rgTrace rig) `shouldReturn` ["entered hold"]
          signalRig rig "hold"
          -- let go, the peer ends that update and arms its next point: the step never ran it again meanwhile
          awaitTimers world 2
          readTVarIO (rgTrace rig) `shouldReturn` ["released hold", "entered hold"]
          reading peer `shouldReturn` oneSecond

  it "grants a gameplay VM one tick at a time: waiting for the third update's line grants three ticks" $
    withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource counter)]) $ \world control runtime →
      withFvm world runtime gameplayShape $ \fvm → do
        _ ← spawn world fvm "modules-test" mainPath
        tickUntil fvm (elem "n=3" <$> outLinesSTM world)
        -- the tick that ran the third update completes, and no other was granted
        awaitTickDone control fvm
        outLines world `shouldReturn` counted 3

  it "drives a presentation VM on while the gameplay VM beside it is held in a granted tick, and grants that VM no other tick" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource counter), ("lua/held.lua", scriptSource held)]) $ \world control runtime →
        -- however the example ends, the gameplay VM is let go before its owner is retired
        withFvm world runtime (gameplayOver rig) $ \gameplay → (`finally` signalRig rig "hold") $ withFvm world runtime presentationShape $ \shown → do
          let outstanding = atomically (ticksOutstanding (scheduledEndpoint (fvOwner gameplay)))
          _ ← spawn world gameplay "modules-test" "lua/held.lua"
          -- the first granted tick runs the gameplay VM's update, which stays at the fixture: that tick is outstanding
          tickUntil gameplay (elem "entered hold" <$> readTVar (rgTrace rig))
          outstanding `shouldReturn` 1
          _ ← spawn world shown "modules-test" mainPath
          -- the drive needs three presentation updates while the tick is outstanding: it steps the presentation VM, three times
          tickAndStepUntil gameplay world (elem "n=3" <$> outLinesSTM world)
          awaitTimers world 1
          outLines world `shouldReturn` counted 3
          outstanding `shouldReturn` 1
          readTVarIO (rgTrace rig) `shouldReturn` ["entered hold"]
          -- let go, the gameplay VM ends that update and its tick completes; no other tick was granted meanwhile
          signalRig rig "hold"
          awaitTickDone control gameplay
          readTVarIO (rgTrace rig) `shouldReturn` ["released hold", "entered hold"]
