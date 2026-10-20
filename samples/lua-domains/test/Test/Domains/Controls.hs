-- | The UI's control of the gameplay behavior's execution (#499 requirement 12): pause and resume are lifecycle
-- controls the UI owner requests of gameplay through the engine's granted endpoint. The application assigns each a tick
-- and a place in it, the engine applies it at that tick and answers the UI with its own reasons, and every control is
-- counted on every path, including those where the instance or the session ended first.
module Test.Domains.Controls (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Monad (replicateM_, when)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Hetoimasia.Sample.LuaDomains
  ( Domains (domainsShared)
  , DomainsConfig (configAssignHook, configGameplaySource, configInput, configUiSource)
  , GameSnapshot (snapStatus)
  , SessionStatus (Paused, Running)
  , TickOutcome (TickCommitted)
  , retireDomains
  , stepTick
  , stopSession
  )
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedControls, sharedCounts, sharedReceipts, sharedTick))
import Hetoimasia.Sample.LuaDomains.Tally (ControlCounts (..), Counts (..))
import Test.Domains.Support
import Test.Hspec

-- | A UI behavior that does one thing in each update, the nth update doing the nth action, after it has read the
-- settlements of its receipts, and then says the update completed. An action is Lua that may use @control@ and @fx@.
uiActing ∷ [Text] → ByteString
uiActing actions =
  luaLines $
    [ "local updates = 0"
    , "local actions = {"
    ]
      <> ["  function() " <> action <> " end," | action ← actions]
      <> [ "}"
         , "function update(self, dt)"
         , "  updates = updates + 1"
         , "  control.settle()"
         , "  local act = actions[updates]"
         , "  if act then act() end"
         , "  ui.updated()"
         , "end"
         ]

-- | Gameplay's behavior says which tick each of its updates runs in.
recordUpdates ∷ [Text]
recordUpdates = ["function update(self, dt) fx.record('update ' .. world.tick()) staging.finish() end"]

-- | Every control the UI offered was accepted or refused, and every accepted one has one result, or was abandoned.
controlsBalance ∷ Domains → IO ()
controlsBalance domains = do
  counts ← readTVarIO (sharedControls (domainsShared domains))
  controlOffered counts `shouldBe` controlAccepted counts + sum (Map.elems (controlRefused counts))
  controlAccepted counts `shouldBe` controlApplied counts + controlAlready counts + controlNoLonger counts + controlAbandoned counts

-- | Stop the session while the UI is serving, keeping the UI's updates coming as its timer would until the stop has
-- returned: the stop waits for the UI to read the settlements of the controls it asked for.
stopServing ∷ Domains → FakeUi → IO ()
stopServing domains ui = do
  finished ← newTVarIO False
  stopped ← spawn (stopSession domains >> atomically (writeTVar finished True))
  let go = do
        next ← waitFor $ do
          done ← readTVar finished
          held ← readTVar (sharedReceipts (domainsShared domains))
          live ← liveRegistrations ui
          if done then pure False else if held > 0 && not (null live) then pure True else retry
        when next (uiStep domains ui >> go)
  go
  _ ← stopped
  pure ()

spec ∷ Spec
spec = describe "the UI's control of the gameplay behavior" $ do
  describe "pause and resume" $ do
    it "are applied at the ticks they were assigned: the status the ticks commit is running, paused, running" $
      withSample (\config → config {configInput = [], configUiSource = uiActing ["control.pause()", "control.resume()"]}) $ \_ ui domains → do
        (first, _) ← snapshotNow domains
        uiStep domains ui
        paused ← stepCommitted domains
        uiStep domains ui
        resumed ← stepCommitted domains
        later ← stepCommitted domains
        map snapStatus [first, paused, resumed, later] `shouldBe` [Running, Paused, Running, Running]
        uiStep domains ui
        counts ← readTVarIO (sharedControls (domainsShared domains))
        (controlAccepted counts, controlApplied counts) `shouldBe` (2, 2)
        controlsBalance domains

    it "pause the behavior only: its update does not run while paused, nor in the tick that resumes it, and the first update is a full interval later; ticks and accepted intentions go on" $
      withSample (\config → config {configInput = [], configGameplaySource = luaLines recordUpdates, configUiSource = uiActing ["control.pause()", "control.resume()"]}) $ \fx ui domains → do
        uiStep domains ui
        -- Tick one is paused, with intentions accepted for it; tick two is paused too.
        accepted ← mapM (offer domains) [0, 1, 2]
        replicateM_ 2 (stepCommitted domains)
        uiStep domains ui
        -- Resumed in tick three, which runs no update; the first update is the tick after.
        replicateM_ 4 (stepCommitted domains)
        fxLines fx `shouldReturn` ["update 4", "update 5", "update 6"]
        counts ← readTVarIO (sharedCounts (domainsShared domains))
        (length accepted, countApplied counts + countStale counts) `shouldBe` (3, 3)

    it "repeated and contradictory requests in one tick are applied in order: a request for the state it is already in is accepted, and settles as already in that state" $
      withSample
        ( \config →
            config
              { configInput = []
              , configUiSource = uiActing ["control.pause() control.pause() control.resume() control.resume()", "control.pause() control.resume()", ""]
              }
        )
        $ \_ ui domains → do
          uiStep domains ui
          _ ← stepCommitted domains
          uiStep domains ui
          _ ← stepCommitted domains
          uiStep domains ui
          counts ← readTVarIO (sharedControls (domainsShared domains))
          (controlAccepted counts, controlApplied counts, controlAlready counts, controlNoLonger counts) `shouldBe` (6, 4, 2, 0)
          controlsBalance domains

  describe "for a session that will not run the control" $ do
    it "refuses a request made after the session failed, as unassigned, and nothing is owed for it" $
      withSample (\config → config {configInput = [], configGameplaySource = luaLines ["function update(self, dt) error('boom') end"], configUiSource = uiActing ["fx.record('answer ' .. tostring(control.pause()) .. ' ' .. tostring(select(2, control.pause())))"]}) $ \_ ui domains → do
        _ ← stepTick domains
        uiStep domains ui
        counts ← readTVarIO (sharedControls (domainsShared domains))
        (controlOffered counts, controlAccepted counts, Map.toList (controlRefused counts)) `shouldBe` (2, 0, [("unassigned", 2)])
        controlsBalance domains

    it "refuses a request made after the stop began, as unassigned" $
      withSample (\config → config {configInput = [], configUiSource = uiActing ["control.pause()"]}) $ \_ ui domains → do
        _ ← stopSession domains
        _ ← pure ui
        counts ← readTVarIO (sharedControls (domainsShared domains))
        controlOffered counts `shouldBe` 0
        controlsBalance domains

    it "settles a control that was accepted but never applied when the session is stopped, as no longer applicable, and the UI observes it" $
      withSample (\config → config {configInput = [], configUiSource = uiActing ["control.pause()", "", "", "", ""]}) $ \_ ui domains → do
        uiStep domains ui
        stopServing domains ui
        counts ← readTVarIO (sharedControls (domainsShared domains))
        (controlAccepted counts, controlNoLonger counts, controlApplied counts, controlAbandoned counts) `shouldBe` (1, 1, 0, 0)
        controlsBalance domains

  describe "when the UI ends first" $
    it "reports a receipt it had not read as abandoned, apart from the settlements, and the accepted control still applies" $
      withSample (\config → config {configInput = [], configUiSource = uiActing ["control.pause()", "error('ui failed')"]}) $ \_ ui domains → do
        uiStep domains ui
        tickUi domains ui
        -- The UI failed before the control's tick began, with its receipt unread.
        _ ← waitFor (readTVar (sharedReceipts (domainsShared domains)) >>= \held → when (held > 0) retry)
        paused ← stepCommitted domains
        snapStatus paused `shouldBe` Paused
        _ ← retireDomains domains
        counts ← readTVarIO (sharedControls (domainsShared domains))
        (controlAccepted counts, controlAbandoned counts, controlApplied counts) `shouldBe` (1, 1, 0)
        controlsBalance domains

  describe "serialization with the tick" $
    it "holds the tick's begin from the control's assignment until the engine has admitted the control: a tick attempted in that interval does not begin, and the control is applied in the tick it was assigned, never late" $ do
      probe ← newEmptyMVar
      result ← newEmptyMVar
      withSample (\config → config {configInput = [], configAssignHook = readMVar probe >>= id, configUiSource = uiActing ["control.pause()", ""]}) $ \_ ui domains → do
        putMVar probe $ do
          -- On the UI owner's thread, after the assignment and before the admission: the driver tries to begin the tick.
          collect ← spawn (stepTick domains)
          replicateM_ 2000 yield
          began ← toList <$> readTVarIO (sharedTick (domainsShared domains))
          putMVar result (collect, began)
        uiStep domains ui
        (collect, began) ← readMVar result
        began `shouldSatisfy` null
        outcome ← collect
        case outcome of
          TickCommitted snapshot → snapStatus snapshot `shouldBe` Paused
          other → expectationFailure ("the tick did not commit: " <> show other)
        uiStep domains ui
        counts ← readTVarIO (sharedControls (domainsShared domains))
        (controlApplied counts, controlNoLonger counts) `shouldBe` (1, 0)
        controlsBalance domains
