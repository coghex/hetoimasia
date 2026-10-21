-- | The UI's control of the gameplay behavior's execution (#499 requirement 12): pause and resume are lifecycle
-- controls the UI owner requests of gameplay through the engine's granted endpoint. The application assigns each a tick
-- and a place in it, the engine applies it at that tick and answers the UI with its own reasons, and every control is
-- counted on every path, including those where the instance or the session ended first.
module Test.Domains.Controls (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (readTVar, readTVarIO, retry)
import Control.Exception (try)
import Control.Monad (replicateM_, when)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Maybe (isNothing)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Hetoimasia.Sample.LuaDomains
  ( Bounds (boundPendingControls)
  , Domains (domainsShared)
  , DomainsConfig (configAssignHook, configGameplaySource, configInput, configTicks, configUiSource)
  , DomainsDefect (TickNotCompleted)
  , GameSnapshot (snapStatus)
  , SessionStatus (Paused, Running)
  , TickOutcome (TickCommitted)
  , defaultBounds
  , retireDomains
  , stepTick
  , stopSession
  )
import Hetoimasia.Sample.LuaDomains.Session (SessionState (sessionEnded))
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedControls, sharedCounts, sharedReceipts, sharedSession, sharedTick))
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

  describe "the engine's reservations" $
    it "leave the stop room whatever the UI holds: controls beyond the pending bound are refused, and a stop with the bound's worth unread completes" $
      withSample (\config → config {configInput = [], configUiSource = uiActing ["for i = 1, 8 do control.pause() end", "", "", "", "", "", ""]}) $ \_ ui domains → do
        let allowed = boundPendingControls defaultBounds
        uiStep domains ui
        held ← readTVarIO (sharedControls (domainsShared domains))
        (controlAccepted held, Map.toList (controlRefused held)) `shouldBe` (allowed, [("unassigned", 8 - allowed)])
        stopServing domains ui
        settled ← readTVarIO (sharedControls (domainsShared domains))
        (controlAccepted settled, controlNoLonger settled) `shouldBe` (allowed, allowed)
        controlsBalance domains

  describe "a control is no proof that an update did not run" $
    it "does not commit a tick whose update began and did not finish because a redundant resume was assigned to it" $
      withSample (\config → config {configInput = [], configGameplaySource = luaLines ["function update(self, dt) staging.move(0, 1, 0) end"], configUiSource = uiActing ["control.resume()", ""]}) $ \_ ui domains → do
        uiStep domains ui
        outcome ← try (stepCommitted domains)
        case outcome of
          Left (TickNotCompleted tick) → tick `shouldBe` 1
          Left other → expectationFailure ("a different defect: " <> show other)
          Right _ → expectationFailure "the tick committed"

  describe "a finite session's last tick" $
    it "takes no control for a tick that cannot run: a request made while the last tick runs is refused as unassigned" $
      withSample (\config → config {configInput = [], configTicks = Just 1, configGameplaySource = luaLines ["function update(self, dt) fx.hold('last') staging.finish() end"], configUiSource = uiActing ["control.pause()", ""]}) $ \fx ui domains →
        withReleased fx ["last"] $ do
          _ ← driving domains (awaitEntered fx "last" >> uiStep domains ui >> releaseGate fx "last")
          counts ← readTVarIO (sharedControls (domainsShared domains))
          (controlOffered counts, controlAccepted counts, Map.toList (controlRefused counts)) `shouldBe` (1, 0, [("unassigned", 1)])
          controlsBalance domains

  describe "a target that ends between the assignment and the admission" $
    it "answers the request as the engine does, closed or unknown_target and never late, and the sample counts it as it was said, owing nothing for it" $ do
      probe ← newEmptyMVar
      withSample (\config → config {configInput = [], configAssignHook = readMVar probe >>= id, configUiSource = uiActing ["control.pause()", ""]}) $ \fx ui domains →
        withReleased fx ["assigned"] $ do
          putMVar probe (holdAt fx "assigned")
          tickUi domains ui
          -- The request has its tick and its place, and the engine has not admitted it: the session is stopped now, and
          -- the instance it names has ended when the UI goes on.
          awaitEntered fx "assigned"
          -- The stop is the application thread's, and it retires the UI owner, which is held in the request: the gate is
          -- opened from a thread of its own once the session has ended, with the instance it names settled.
          _ ← alongside (waitFor (readTVar (sharedSession (domainsShared domains)) >>= \state → when (isNothing (sessionEnded state)) retry) >> releaseGate fx "assigned") (stopSession domains)
          counts ← readTVarIO (sharedControls (domainsShared domains))
          (controlOffered counts, controlAccepted counts) `shouldBe` (1, 0)
          Map.toList (controlRefused counts) `shouldSatisfy` (\refused → refused `elem` [[("closed", 1)], [("unknown_target", 1)]])
          controlsBalance domains

  describe "serialization with the tick" $
    it "holds the tick's begin from the control's assignment until the engine has admitted the control: a tick attempted in that interval does not begin, and the control is applied in the tick it was assigned, never late" $ do
      probe ← newEmptyMVar
      withSample (\config → config {configInput = [], configAssignHook = readMVar probe >>= id, configUiSource = uiActing ["control.pause()", ""]}) $ \fx ui domains → withReleased fx ["assigned"] $ do
        -- On the UI owner's thread, after the assignment and before the admission, which is held open: the driver tries to
        -- begin the tick, and it does not begin.
        putMVar probe (holdAt fx "assigned")
        tickUi domains ui
        awaitEntered fx "assigned"
        outcome ←
          driving
            domains
            ( do
                replicateM_ 2000 yield
                began ← toList <$> readTVarIO (sharedTick (domainsShared domains))
                began `shouldSatisfy` null
                releaseGate fx "assigned"
            )
        awaitUpdates domains 1
        case outcome of
          TickCommitted snapshot → snapStatus snapshot `shouldBe` Paused
          other → expectationFailure ("the tick did not commit: " <> show other)
        uiStep domains ui
        counts ← readTVarIO (sharedControls (domainsShared domains))
        (controlApplied counts, controlNoLonger counts) `shouldBe` (1, 0)
        controlsBalance domains
