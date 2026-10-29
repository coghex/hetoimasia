{-# LANGUAGE OverloadedStrings #-}

-- | How a session stops and drains: a stop that takes no slot, admission closed before anything new is issued,
-- cancellation and release still possible, and a role retired only when what it holds has actually retired.
module Test.LuaEngine.Session.Stop (spec) where

import Control.Concurrent (forkIO, killThread, throwTo)
import Control.Concurrent.MVar (isEmptyMVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), ExceptionWithContext (ExceptionWithContext), MaskingState (MaskedUninterruptible), fromException, getMaskingState, toException, try, uninterruptibleMask_)
import Control.Monad (replicateM_, void)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (elemIndex)
import qualified Data.Text as Text
import Test.Hspec
import Test.LuaEngine.Modules.Support (closeGate, openGate)
import Test.LuaEngine.Session.Support
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "stop and drain" $ do
  fullCapacity
  sharedJobs
  peers
  shutdowns
  barrier
  waits

-- A stop with everything full ---------------------------------------------------------------------------------------------------

fullCapacity ∷ Spec
fullCapacity = describe "with every place taken" $ do
  it "takes no slot to stop, closes new work before anything is issued, and still lets a script cancel and write while it drains" $
    withSetup
      ( addFile
          ("lua/slow.bin", "slow")
          ( (setup (roleScript filling)) {suShape = PresentationAlone}
          )
      )
      $ \env → do
        let world = seWorld env
            probe = ssProbeOf env
        closeGate probe "lua/slow.bin"
        holdSink world "second"
        outcome ← runScenario env $ \session → do
          awaitPhase session Presentation Running
          -- the first refresh asks until the places are full, each request held in the pool
          passTime world 1000000000 (any (Text.isPrefixOf "filled") <$> outLines world)
          -- the second refresh is parked in its output while the session is stopped, repeatedly, from several threads
          nudgeArmed world 1000000 1000000000
          awaitSinkEntered world "second"
          done ← newEmptyMVar
          replicateM_ 4 . forkIO $ do
            requestStop session StopQuit
            requestStop session StopInterrupt
            putMVar done ()
          replicateM_ 4 (bounded (takeMVar done))
          status ← statusNow session
          statusStopping status `shouldBe` True
          fmap rolePhase (presentationOf status) `shouldBe` Just Stopping
          releaseSink world
          -- the held reads are provider work the role still owes: it is not retired while they are held
          void (awaitStatus session (\status' → fmap rolePhase (presentationOf status') == Just Stopping))
          st <- statusNow session
          fmap rolePhase (presentationOf st) `shouldBe` Just Stopping
          openGate probe "lua/slow.bin"
          void (awaitRetired session)
        out ← outLines world
        -- a content request after the stop is an ordinary error, not busy, and cancelling and writing still work
        out `shouldSatisfy` elem "after stop false"
        out `shouldSatisfy` any (`elem` ["cancel cancelled", "cancel already_settled"])
        outVerdict outcome `shouldBe` VerdictInterrupted
        outRetired outcome `shouldBe` True
  where
    filling =
      printScript
        { scInit = []
        , scShutdown = []
        , scUpdate =
            [ "self.n = (self.n or 0) + 1"
            , "if self.n == 1 then"
            , "  self.reqs = {}"
            , "  for i = 1, 40 do"
            , "    local r = api.content.data('lua/slow.bin')"
            , "    if r == nil then break end"
            , "    self.reqs[#self.reqs + 1] = r"
            , "  end"
            , "  print('filled ' .. #self.reqs)"
            , "elseif self.n == 2 then"
            , "  print('second')"
            , "  local ok = pcall(api.content.data, 'lua/slow.bin')"
            , "  print('after stop ' .. tostring(ok))"
            , "  print('cancel ' .. api.request.cancel(self.reqs[1]))"
            , "  warn('written after the stop')"
            , "end"
            ]
        }

-- Module jobs the VM owns -----------------------------------------------------------------------------------------------------------

sharedJobs ∷ Spec
sharedJobs = describe "shared module jobs" $ do
  it "keeps a job the VM owns until the VM retires it, whoever stopped waiting for it, and retires the role only then" $
    withSetup
      ( addFile
          ("lua/dep.lua", luaMain ["return {}"])
          ( (setup (roleScript printScript {scInit = ["if api.role == 'gameplay' then self.module = api.content.module('lua/dep.lua') end"], scUpdate = []}))
              { suShape = GameplayAlone
              , suHarness = noHarness {harnessSecond = [Gameplay]}
              }
          )
      )
      $ \env → do
        let probe = ssProbeOf env
        closeGate probe "lua/dep.lua"
        void . runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitReadOf env "lua/dep.lua"
          requestStop session StopQuit
          status ← statusNow session
          fmap rolePhase (gameplayOf status) `shouldBe` Just Stopping
          openGate probe "lua/dep.lua"
          awaitPhase session Gameplay Retired

-- A peer's holdings -----------------------------------------------------------------------------------------------------------------------

peers ∷ Spec
peers = describe "the second instance of a VM" $ do
  it "keeps its own holdings distinct while the role's policy ends both: the failed instance shuts down as failed, its peer as stopped, and the role retires when the peer's read has" $
    withSetup
      ( addFile
          ("lua/slow.bin", "slow")
          ( (setup
              ( roleScript
                  printScript
                    { scInit = ["if api.role == 'gameplay' and api.instance_id == 'inst-2' then self.request = api.content.data('lua/slow.bin', {tick_offset = 50}) end"]
                    , scUpdate = ["if api.role == 'gameplay' and api.instance_id == 'inst-1' then error('boom') end"]
                    , scShutdown = ["print('shutdown ' .. api.instance_id .. ' ' .. reason)"]
                    }
              )
            )
              { suHarness = noHarness {harnessSecond = [Gameplay]}
              }
          )
      )
      $ \env → do
        let world = seWorld env
            probe = ssProbeOf env
        closeGate probe "lua/slow.bin"
        void . runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          awaitReadOf env "lua/slow.bin"
          awaitRegistration world 1000
          nudge world 1000000
          status ← awaitStatus session (maybe False roleFailed . gameplayOf)
          fmap (>>= rfInstance) (roleFailure <$> gameplayOf status) `shouldBe` Just (Just "inst-1")
          -- the peer's read is its own provider work: the role has not retired while it is held, the other role goes on
          fmap rolePhase (gameplayOf status) `shouldBe` Just Stopping
          fmap rolePhase (presentationOf status) `shouldBe` Just Running
          openGate probe "lua/slow.bin"
          awaitPhase session Gameplay Retired
          out <- outLines world
          out `shouldSatisfy` elem "shutdown inst-1 failed"
          out `shouldSatisfy` elem "shutdown inst-2 stopped"
          requestStop session StopQuit

-- Shutdowns -----------------------------------------------------------------------------------------------------------------------------------

shutdowns ∷ Spec
shutdowns = describe "shutdown" $ do
  it "runs once, finite, for an instance that has one, and an instance without one is simply stopped" $
    withSetup
      (setup (luaMain ["return { gameplay = { every_ticks = 1, update = function() end }, presentation = { every_seconds = 1, update = function() end, shutdown = function(self, reason) print('shutdown presentation ' .. reason) end } }"]))
      $ \env → do
        let world = seWorld env
        outcome ← runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          requestStop session StopQuit
          requestStop session StopQuit
        out ← outLines world
        out `shouldBe` ["shutdown presentation stopped"]
        outVerdict outcome `shouldBe` VerdictSuccess
        outFailures outcome `shouldBe` []

  it "is skipped for a root whose init failed, and runs for the roots that succeeded, each exactly once" $
    withSetup (setup (roleScript printScript {scInit = ["if api.role == 'presentation' then error('ui init failed') end"]})) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → void (awaitRetired session)
      out ← outLines world
      filter ("shutdown presentation" `Text.isPrefixOf`) out `shouldBe` []
      filter ("shutdown gameplay" `Text.isPrefixOf`) out `shouldSatisfy` (`elem` [[], ["shutdown gameplay stopped"]])
      length (filter ("shutdown" `Text.isPrefixOf`) out) `shouldSatisfy` (<= 1)
      outVerdict outcome `shouldBe` VerdictFailure

-- The all-owner stop barrier ----------------------------------------------------------------------------------------------------

-- | How a driver leaves.
data Leaving = Cancelled | Threw
  deriving (Eq, Show)

-- | A harness that records, and the example's own changes to it.
recording ∷ Recorder → [Protection] → Harness
recording recorder removedProtections = (recordingHarness recorder noHarness) {harnessRemoved = removedProtections}

barrier ∷ Spec
barrier = describe "the all-owner stop barrier" $ do
  mapM_
    ( \(reversed, leaving) →
        it ("hands every constructed owner its stop before the first wait, " <> orderName reversed <> ", the driver " <> leavingName leaving) $
          withSetup (setup (roleScript printScript)) {suReversed = reversed} $ \env → do
            let world = seWorld env
            recorder ← newRecorder
            -- the logical owner is parked in a hook of the host: it cannot end, so the teardown has an owner to wait for
            -- and the first wait is certain to begin; the other role is free to end during the pass
            holdAt recorder (Dispatched (InstanceKey Gameplay 0))
            holdAt recorder (Awaiting Gameplay)
            -- (the driver throws when the other role's init is accounted, which the parked owner never reaches)
            when' (leaving == Threw) $ do
              holdAt recorder (Committed "InitSucceeded")
              failAt recorder (Committed "InitSucceeded") (toException (userError "the driver failed"))
            (ended, session) ← runCaught env (recording recorder []) $ \driver session → do
              awaitPoint recorder (Dispatched (InstanceKey Gameplay 0))
              case leaving of
                Cancelled → pumpUntil world (elem "init presentation" <$> outLines world) >> throwTo driver ThreadKilled
                Threw → releaseHold recorder (Committed "InitSucceeded")
              -- the barrier ran and the first wait is about to begin: both owners have their stop, and nothing is retired
              awaitPoint recorder (Awaiting Gameplay)
              found ← historyNow session
              historyStopped found `shouldBe` [Gameplay, Presentation]
              status ← statusNow session
              statusStopping status `shouldBe` True
              retiredBoth status `shouldBe` False
              releaseHold recorder (Awaiting Gameplay)
              releaseHold recorder (Dispatched (InstanceKey Gameplay 0))
            raisedBy leaving ended
            found ← outcomeNow session
            outRetired found `shouldBe` True
    )
    [(reversed, leaving) | reversed ← [False, True], leaving ← [Cancelled, Threw]]

  mapM_
    ( \(reversed, slow) →
        it ("stops the peer of a role whose owner does not end, while that owner is held: " <> orderName reversed <> ", " <> show slow <> " slow") $
          withSetup (setup (roleScript printScript)) {suReversed = reversed} $ \env → do
            let world = seWorld env
                fast = if slow == Gameplay then Presentation else Gameplay
            recorder ← newRecorder
            -- the slow role's owner is parked in a hook of the host: it cannot end, and cannot see a stop
            holdAt recorder (Dispatched (InstanceKey slow 0))
            (ended, session) ← runCaught env (recording recorder []) $ \driver session → do
              awaitPoint recorder (Dispatched (InstanceKey slow 0))
              pumpUntil world (elem ("init " <> roleWord fast) <$> outLines world)
              throwTo driver ThreadKilled
              -- the barrier stops the fast role while the slow one is held: its shutdown runs and it is retired
              pumpUntil world (elem ("shutdown " <> roleWord fast <> " stopped") <$> outLines world)
              status <- statusNow session
              fmap rolePhase (pickRole slow status) `shouldBe` Just Stopping
              fmap roleFailed (pickRole slow status) `shouldBe` Just False
              releaseHold recorder (Dispatched (InstanceKey slow 0))
            raisedBy Cancelled ended
            out <- outLines world
            out `shouldSatisfy` elem ("shutdown " <> roleWord slow <> " stopped")
            found <- outcomeNow session
            outRetired found `shouldBe` True
            outFailures found `shouldBe` []
    )
    [(reversed, slow) | reversed ← [False, True], slow ← [Gameplay, Presentation]]

  -- the control: with the barrier removed each scope stops its own owner alone, and the protection's absence shows
  describe "with the barrier removed (a negative control)" $ do
    it "hands the innermost scope's owner alone its stop before the first wait, which is what the proof above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        let world = seWorld env
        recorder ← newRecorder
        -- the innermost scope's owner is parked in a hook of the host, so that scope's wait is certain to begin
        holdAt recorder (Dispatched (InstanceKey Presentation 0))
        holdAt recorder (Awaiting Presentation)
        (ended, session) ← runCaught env (recording recorder [ProtectBarrier]) $ \driver session → do
          awaitPoint recorder (Dispatched (InstanceKey Presentation 0))
          pumpUntil world (elem "init gameplay" <$> outLines world)
          throwTo driver ThreadKilled
          awaitPoint recorder (Awaiting Presentation)
          found ← historyNow session
          historyStopped found `shouldBe` [Presentation]
          releaseHold recorder (Awaiting Presentation)
          releaseHold recorder (Dispatched (InstanceKey Presentation 0))
        raisedBy Cancelled ended
        -- the other scope stops its owner afterwards, so the session still ends
        found ← outcomeNow session
        outRetired found `shouldBe` True

    it "leaves the peer of a held owner running, which the behavioural proof above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        let world = seWorld env
        recorder ← newRecorder
        holdAt recorder (Dispatched (InstanceKey Presentation 0))
        (ended, _) ← runCaught env (recording recorder [ProtectBarrier]) $ \driver _ → do
          awaitPoint recorder (Dispatched (InstanceKey Presentation 0))
          pumpUntil world (elem "init gameplay" <$> outLines world)
          throwTo driver ThreadKilled
          awaitPoint recorder (Awaiting Presentation)
          out ← outLines world
          out `shouldSatisfy` notElem "shutdown gameplay stopped"
          releaseHold recorder (Dispatched (InstanceKey Presentation 0))
        raisedBy Cancelled ended
        out ← outLines world
        out `shouldSatisfy` elem "shutdown gameplay stopped"
  where
    orderName reversed = if reversed then "presentation listed first" else "gameplay listed first"
    leavingName = \case
      Cancelled → "cancelled"
      Threw → "throwing"
    when' condition action = if condition then action else pure ()
    pickRole role status = if role == Gameplay then statusGameplay status else statusPresentation status

-- | The session raised what leaving the way it did raises: a cancellation as itself, or the driver's own failure.
raisedBy ∷ Leaving → Either Caught SessionOutcome → Expectation
raisedBy leaving ended = case (leaving, ended) of
  (Cancelled, Left (ExceptionWithContext _ raised)) → fromException raised `shouldBe` Just ThreadKilled
  (Threw, Left (ExceptionWithContext _ raised)) → show raised `shouldSatisfy` Text.isInfixOf "the driver failed" . Text.pack
  (_, Right _) → expectationFailure "the exception was lost"

-- Waits stay interruptible ---------------------------------------------------------------------------------------------------------------

waits ∷ Spec
waits = describe "masking and waits" $ do
  it "refuses an entry that is uninterruptibly masked before it acquires anything, and tells nobody" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      told ← newIORef False
      result ← try (uninterruptibleMask_ (runSession (scenarioSpec env (recording recorder [])) (\_ → writeIORef told True)))
      case result of
        Left (SessionRefused why) → why `shouldSatisfy` Text.isInfixOf "uninterruptibly masked"
        Right _ → expectationFailure "an uninterruptibly masked entry was accepted"
      readIORef told `shouldReturn` False
      recorded recorder `shouldReturn` []

  it "runs the protocol's waits under the caller's own mask, never an uninterruptible one" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      states ← newIORef []
      let base = recording recorder []
          harness =
            base
              { harnessProbe = \point → do
                  harnessProbe base point
                  case point of
                    Awaiting _ → getMaskingState >>= \state → readIORef states >>= writeIORef states . (<> [state])
                    _ → pure ()
              }
      let world = seWorld env
      -- an owner parked in a hook of the host makes the wait certain to happen; it is let go once the wait was observed
      holdAt recorder (Dispatched (InstanceKey Presentation 0))
      (ended, _) ← runCaught env harness $ \driver session → do
        awaitPoint recorder (Dispatched (InstanceKey Presentation 0))
        pumpUntil world (elem "init gameplay" <$> outLines world)
        throwTo driver ThreadKilled
        awaitPoint recorder (Awaiting Presentation)
        releaseHold recorder (Dispatched (InstanceKey Presentation 0))
        void (awaitRetired session)
      raisedBy Cancelled ended
      masks ← readIORef states
      masks `shouldSatisfy` (not . null)
      masks `shouldSatisfy` notElem MaskedUninterruptible

  describe "the wait for an owner" $ do
    mapM_
      ( \(removedProtections, label, interruptible) →
          it label $
            withSetup (setup (roleScript printScript)) $ \env → do
              let world = seWorld env
              recorder ← newRecorder
              holdAt recorder (Dispatched (InstanceKey Presentation 0))
              delivered ← newEmptyMVar
              (ended, _) ← runCaught env ((recording recorder removedProtections)) $ \driver _ → do
                awaitPoint recorder (Dispatched (InstanceKey Presentation 0))
                pumpUntil world (elem "init gameplay" <$> outLines world)
                throwTo driver ThreadKilled
                awaitPoint recorder (Awaiting Presentation)
                -- the probe is told before the wait begins: the second cancellation is sent only once the driver is
                -- observed parked in the wait itself (in its STM transaction, interruptibly or not)
                awaitBlockedOnSTM driver
                -- a second cancellation is sent while the wait is outstanding
                thrower ← forkIO (throwTo driver ThreadKilled >> putMVar delivered ())
                if interruptible
                  then bounded (takeMVar delivered)
                  else do
                    -- the wait is uninterruptible: the thrower is blocked in its throw and nothing was delivered
                    awaitBlockedOnException thrower
                    isEmptyMVar delivered `shouldReturn` True
                    -- withdraw the throw that cannot land, so that it does not land after the example
                    killThread thrower
                releaseHold recorder (Dispatched (InstanceKey Presentation 0))
              raisedKilled ended `shouldBe` True
      )
      [ ([], "is interruptible: a cancellation sent while it is outstanding is delivered at once, and retained", True)
      , ([ProtectInterruptibleWait], "is not interruptible when the protection is removed (a negative control), which the proof above detects", False)
      ]

  it "keeps waiting for an owner that does not end through every cancellation, and releases only after it has" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Dispatched (InstanceKey Presentation 0))
      (ended, _) ← runCaught env (recording recorder []) $ \driver session → do
        awaitPoint recorder (Dispatched (InstanceKey Presentation 0))
        pumpUntil world (elem "init gameplay" <$> outLines world)
        throwTo driver ThreadKilled
        awaitPoint recorder (Awaiting Presentation)
        -- the probe is told before the wait begins: the driver is observed parked in the wait before it is interrupted
        awaitBlockedOnSTM driver
        -- the wait is interrupted again and again, and is still the one outstanding wait: nothing of the held role is
        -- retired or released while its owner is held
        replicateM_ 3 (throwTo driver ThreadKilled)
        status ← statusNow session
        fmap rolePhase (statusPresentation status) `shouldBe` Just Stopping
        soFar ← recorded recorder
        [built | Released (ReleaseBuild Presentation built) ← soFar] `shouldBe` []
        releaseHold recorder (Dispatched (InstanceKey Presentation 0))
      raisedBy Cancelled ended
      points ← recorded recorder
      -- every release of a role came after that role's owner had ended
      mapM_
        ( \role → do
            let endedAt = elemIndex (OwnerEnded role) points
                releasedAt = [index | (index, Released (ReleaseBuild released _)) ← zip [0 ∷ Int ..] points, released == role]
            endedAt `shouldSatisfy` maybe False (\index → all (> index) releasedAt)
        )
        [Gameplay, Presentation]
