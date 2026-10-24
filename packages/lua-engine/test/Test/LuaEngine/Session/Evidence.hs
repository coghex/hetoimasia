{-# LANGUAGE OverloadedStrings #-}

-- | What a session keeps of its failures: the first failure of a role is the role's whatever follows, every
-- failure is accounted, diagnostics are bounded at code points, and a failure outranks an interruption however
-- the two arrive.
module Test.LuaEngine.Session.Evidence (spec) where

import Control.Concurrent (throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (AsyncException (ThreadKilled), ExceptionWithContext (ExceptionWithContext), SomeException, rethrowIO, throwIO, toException, tryWithContext)
import Control.Exception.Context (emptyExceptionContext)
import Control.Monad (void, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (LogEntry (entryMessage), callbackSink, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, composeCleanup, displayCleanupFailure)
import Hetoimasia.Scripting.Lua.Scheduler (TimerBackend (..))
import Test.Hspec
import Test.LuaEngine.Session.Support

spec ∷ Spec
spec = describe "evidence" $ do
  cancellations
  rawCompletions
  sources
  releases
  histories
  otherSessions
  it "keeps a role's first failure and its attribution while a later failure of the same role is accounted beside it" $
    withSetup
      ( (setup (roleScript printScript {scInit = [], scUpdate = ["if api.role == 'gameplay' and api.instance_id == 'inst-1' then error('first failure') end"], scShutdown = ["if api.instance_id == 'inst-2' then error('second failure') end"]}))
          { suShape = GameplayAlone
          , suHarness = noHarness {harnessSecond = [Gameplay]}
          }
      )
      $ \env → do
        let world = seWorld env
        outcome ← runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitRegistration world 1000
          nudge world 1000000
          void (awaitRetired session)
        case outFailures outcome of
          [found] → do
            rfInstance found `shouldBe` Just "inst-1"
            rfMessage found `shouldSatisfy` Text.isInfixOf "first failure"
            rfStage found `shouldBe` OnUpdate
          other → expectationFailure ("expected the first failure alone, found " <> show other)
        -- the sibling's failure to shut down is accounted, in order, beside the first and does not replace it
        let report = outEngine outcome
        fmap (Text.isInfixOf "first failure" . eeMessage) (erPrimary report) `shouldBe` Just True
        map eeMessage (erSecondary report) `shouldSatisfy` any (Text.isInfixOf "second failure")
        reportAccounted report `shouldBe` 2

  it "holds a script's diagnostic, whatever its text, to the bounds, and keeps the record whole" $
    withSetup ((setup (roleScript printScript {scInit = [], scUpdate = ["error(string.rep('\\xC3\\xA9', 5000))"]})) {suShape = GameplayAlone}) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        nudge world 1000000
        void (awaitRetired session)
      case outFailures outcome of
        [found] → do
          utf8Bytes (rfMessage found) `shouldSatisfy` (<= 2048)
          Text.unpack (rfMessage found) `shouldSatisfy` all (/= '\xFFFD')
          maybe 0 utf8Bytes (rfTraceback found) `shouldSatisfy` (<= 8192)
          recordBytes found `shouldSatisfy` (<= 16384)
          rfCode found `shouldBe` LuaError
          rfRole found `shouldBe` Gameplay
        other → expectationFailure ("expected one failure, found " <> show other)

  it "cuts the diagnostic of a terminal failure at a code point, ending in a visible marker, before it is published" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let wide = Text.replicate 6000 "\x20AC"
          terminal = (newRoleFailure StateUnavailable OnUpdate Presentation wide) {rfTraceback = Just wide, rfInstance = Just (Text.replicate 400 "i")}
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        void (latchTerminalFailure session terminal)
        void (awaitRetired session)
      case outTerminal outcome of
        Just found → do
          utf8Bytes (rfMessage found) `shouldSatisfy` (<= 2048)
          rfMessage found `shouldSatisfy` Text.isSuffixOf "..."
          Text.unpack (rfMessage found) `shouldSatisfy` all (/= '\xFFFD')
          maybe 0 utf8Bytes (rfTraceback found) `shouldSatisfy` (<= 8192)
          maybe 0 utf8Bytes (rfInstance found) `shouldSatisfy` (<= 128)
          recordBytes found `shouldSatisfy` (<= 16384)
          rfCode found `shouldBe` StateUnavailable
        Nothing → expectationFailure "the terminal failure was not published"

  it "lets a failure outrank an interruption: a hook that fails while the interrupted session stops makes the outcome a failure, and the interruption is still recorded" $
    withSetup (setup (roleScript printScript {scShutdown = ["if api.role == 'gameplay' then error('shutdown failed') end"]})) $ \env → do
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopInterrupt
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      outInterrupted outcome `shouldBe` True
      outQuit outcome `shouldBe` False
      fmap rfStage (outFailures outcome) `shouldBe` [OnShutdown]
      fmap rfRole (outFailures outcome) `shouldBe` [Gameplay]

  it "ranks an interruption over a normal quit when both are asked, whichever comes first" $
    mapM_
      ( \order → withSetup (setup (roleScript printScript)) $ \env → do
          outcome ← runScenario env $ \session → do
            awaitPhase session Gameplay Running
            awaitPhase session Presentation Running
            mapM_ (requestStop session) order
          outVerdict outcome `shouldBe` VerdictInterrupted
          outQuit outcome `shouldBe` True
          outInterrupted outcome `shouldBe` True
      )
      [[StopQuit, StopInterrupt], [StopInterrupt, StopQuit]]

  it "publishes a failure through the outcome endpoint as soon as it latches, before the session has ended" $
    withSetup (setup (roleScript printScript {scInit = [], scUpdate = ["if api.role == 'gameplay' then error('boom') end"]})) $ \env → do
      let world = seWorld env
      void . runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitRegistration world 1000
        nudge world 1000000
        void (awaitStatus session (maybe False roleFailed . gameplayOf))
        now ← outcomeNow session
        outVerdict now `shouldBe` VerdictFailure
        outRetired now `shouldBe` False
        fmap rfRole (outFailures now) `shouldBe` [Gameplay]
        requestStop session StopQuit

-- | A harness that records, with these protections removed.
recording ∷ Recorder → [Protection] → Harness
recording recorder removedProtections = (recordingHarness recorder noHarness) {harnessRemoved = removedProtections}

entriesOf ∷ SessionOutcome → [EngineEntry]
entriesOf outcome = maybe [] pure (erPrimary (outEngine outcome)) <> erSecondary (outEngine outcome)

-- | An exception with the context it was caught with, as a probe throws it.
caught ∷ Text.Text → Caught
caught message = ExceptionWithContext emptyExceptionContext (toException (userError (Text.unpack message)))

-- | A cancellation that carries these cleanup failures, as one that unwound through scopes whose releases failed does.
cancellationWith ∷ [Text.Text] → IO Caught
cancellationWith messages =
  composeCleanup (Just (ExceptionWithContext emptyExceptionContext (toException ThreadKilled))) [("release", caught message) | message ← messages]
    >>= maybe (throwIO (userError "no exception was composed")) pure

-- An exception that crosses from one session to another -------------------------------------------------------------------

-- | What the session did with an exception an earlier or an inner session raised, which it catches and raises again: it
-- is not one this session has accounted, whatever the mark it carries says, so it is accounted and raised as this
-- session's own.
otherSessions ∷ Spec
otherSessions = describe "an exception another session raised" $ do
  mapM_
    ( \(label, first) →
        it ("is accounted and raised again by a later session that catches it and rethrows it from its callback: " <> label) $
          withSetup (setup (roleScript printScript)) $ \env → do
            earlier ← tryWithContext @SomeException (runSession (scenarioSpec env noHarness) (\_ → first))
            carried ← case earlier of
              Left found → pure found
              Right _ → throwIO (userError "the first session did not raise")
            handle ← newEmptyMVar
            later ← tryWithContext @SomeException (runSession (scenarioSpec env noHarness) (\session → putMVar handle session >> rethrowIO carried))
            case (later, carried) of
              (Left (ExceptionWithContext _ raised), ExceptionWithContext _ original) → show raised `shouldBe` show original
              (Right _, _) → expectationFailure "the second session took the exception for one it had accounted, and returned"
            session ← readMVar handle
            found ← outcomeNow session
            outRetired found `shouldBe` True
    )
    [ ("a failure", throwIO (userError "the first session's callback failed"))
    , ("a cancellation", throwIO ThreadKilled)
    ]

  it "is not taken for the later session's own timer backend failing when it is one the earlier session's timer backend raised" $
    withSetup (setup (roleScript printScript)) {suShape = GameplayAlone} $ \env → do
      let world = seWorld env
          failing = case worldTimer world of
            TimerBackend arm → TimerBackend $ \microseconds wake → arm microseconds wake >>= \cancel → pure (cancel >> throwIO (userError "the earlier timer's cancel failed"))
          env' = env {seSpec = (seSpec env) {sxTimer = failing}}
      (earlier, _) ← runCaught env' noHarness $ \_ session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        requestStop session StopQuit
        void (awaitRetired session)
      carried ← case earlier of
        Left found → pure found
        Right _ → throwIO (userError "the earlier session did not raise the timer backend's failure")
      handle ← newEmptyMVar
      later ← tryWithContext @SomeException (runSession (scenarioSpec env noHarness) (\session → putMVar handle session >> rethrowIO carried))
      case later of
        Left (ExceptionWithContext _ raised) → show raised `shouldSatisfy` Text.isInfixOf "pacing timer" . Text.pack
        Right _ → expectationFailure "the later session returned"
      session ← readMVar handle
      found ← outcomeNow session
      -- an exception like any other of this session, not a failure of its own timer's cleanup
      [() | entry ← entriesOf found, eeCode entry == CleanupFailure, Text.isInfixOf "pacing timer" (eeMessage entry)] `shouldBe` []
      [() | entry ← entriesOf found, eeCode entry == HostFailure, Text.isInfixOf "the earlier timer's cancel failed" (eeMessage entry)] `shouldSatisfy` (not . null)

  it "is accounted by an outer session when an inner one raises it from the outer session's callback, and the outer outcome is a failure" $
    withSetup (setup (roleScript printScript)) $ \env → do
      handle ← newEmptyMVar
      outer ←
        tryWithContext @SomeException . runSession (scenarioSpec env noHarness) $ \session → do
          putMVar handle session
          void (runSession (scenarioSpec env noHarness) (\_ → throwIO (userError "the inner session's callback failed")))
      case outer of
        Left (ExceptionWithContext _ raised) → show raised `shouldSatisfy` Text.isInfixOf "the inner session's callback failed" . Text.pack
        Right _ → expectationFailure "the outer session took the inner session's exception for one it had accounted, and returned"
      session ← readMVar handle
      found ← outcomeNow session
      outVerdict found `shouldBe` VerdictFailure
      outcomeMessages found `shouldSatisfy` any (Text.isInfixOf "the inner session's callback failed")

-- What a cancellation carries --------------------------------------------------------------------------------------------------

cancellations ∷ Spec
cancellations = describe "the cleanup a cancellation carries" $ do
  it "raises the cancellation as itself with the timer's failed disposal beside it, and makes the outcome a failure" $
      withSetup (setup (roleScript printScript)) {suShape = GameplayAlone} $ \env → do
        let world = seWorld env
            failing = case worldTimer world of
              TimerBackend arm → TimerBackend $ \microseconds wake → arm microseconds wake >>= \cancel → pure (cancel >> throwIO (userError "timer cancel failed"))
            env' = env {seSpec = (seSpec env) {sxTimer = failing}}
        (ended, session) ← runCaught env' noHarness $ \driver session → do
          awaitPhase session Gameplay Running
          awaitRegistration world 1000
          throwTo driver ThreadKilled
          void (awaitRetired session)
        case ended of
          Left (ExceptionWithContext attached raised) → do
            raisedMessage ended `shouldSatisfy` (not . Text.null)
            show raised `shouldSatisfy` (== "thread killed") . Text.unpack . Text.pack
            map displayCleanupFailure (cleanupFailuresInContext attached) `shouldSatisfy` any (Text.isInfixOf "timer cancel failed" . Text.pack)
          Right _ → expectationFailure "the cancellation was lost"
        found ← outcomeNow session
        outVerdict found `shouldBe` VerdictFailure
        length [entry | entry ← entriesOf found, Text.isInfixOf "timer cancel failed" (eeMessage entry)] `shouldBe` 1
        outRetired found `shouldBe` True

  it "accounts every cleanup failure a cancellation carries, once each, whatever its text, and does not make the cancellation a failure of the engine" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      cancelled ← cancellationWith ["same text", "same text", "another"]
      failWith recorder (Built Presentation BuildOwner) cancelled
      (ended, session) ← runCaught env (recording recorder []) $ \_ session → void (awaitStatus session retiredBoth)
      raisedKilled ended `shouldBe` True
      found ← outcomeNow session
      -- distinct failures with identical text both count; the cancellation itself is none
      length (entriesOf found) `shouldBe` 3
      length [entry | entry ← entriesOf found, Text.isInfixOf "same text" (eeMessage entry)] `shouldBe` 2
      mapM_ (\entry → eeCode entry `shouldBe` CleanupFailure) (entriesOf found)
      outVerdict found `shouldBe` VerdictFailure

  describe "with the accounting of what a cancellation carries removed (a negative control)" $
    it "loses what the cancellation carried and reports a success, which the proof above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        recorder ← newRecorder
        cancelled ← cancellationWith ["same text", "another"]
        failWith recorder (Built Presentation BuildOwner) cancelled
        (ended, session) ← runCaught env (recording recorder [ProtectCancellationEvidence]) $ \_ session → void (awaitStatus session retiredBoth)
        raisedKilled ended `shouldBe` True
        found ← outcomeNow session
        entriesOf found `shouldBe` []
        outVerdict found `shouldBe` VerdictSuccess

  it "keeps the first cancellation as the one raised when more arrive while the session unwinds, and loses none of the cleanup" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      cancelled ← cancellationWith ["carried by the first"]
      failWith recorder (Built Presentation BuildOwner) cancelled
      -- the teardown's first boundary is always told, and holds the driver while the first cancellation is cleaned up
      holdAt recorder Unwinding
      (ended, session) ← runCaught env (recording recorder []) $ \driver _ → do
        awaitPoint recorder Unwinding
        -- a second and a third cancellation land while the first is being cleaned up
        throwTo driver ThreadKilled
        throwTo driver ThreadKilled
        releaseHold recorder Unwinding
      case ended of
        Left (ExceptionWithContext attached _) → map displayCleanupFailure (cleanupFailuresInContext attached) `shouldSatisfy` any (Text.isInfixOf "carried by the first" . Text.pack)
        Right _ → expectationFailure "the cancellation was lost"
      raisedKilled ended `shouldBe` True
      found ← outcomeNow session
      length [entry | entry ← entriesOf found, Text.isInfixOf "carried by the first" (eeMessage entry)] `shouldBe` 1

-- | A suspended coroutine whose close fails when the owner retires.
suspending ∷ Script
suspending =
  printScript
    { scInit = []
    , scUpdate =
        [ "if api.time.tick() == 1 then"
        , "  print('suspended')"
        , "  local guard <close> = setmetatable({}, {__close = function() error('close failed') end})"
        , "  api.time.wait_ticks(100)"
        , "end"
        ]
    }

-- | Run a gameplay-only session whose owner retires with a failing close, under the given protections, and answer its
-- outcome. The owner's failure is one supervision raises at its boundary as well, hence the setup.
retiringWithFailingClose ∷ [Protection] → IO SessionOutcome
retiringWithFailingClose removedProtections = do
  result ← newIORef Nothing
  _ ←
    fatalSetup (setup (roleScript suspending)) {suShape = GameplayAlone} $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      (_, session) ← runCaught env (recording recorder removedProtections) $ \_ session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        passTime world 1000000 (elem "suspended" <$> outLines world)
        requestStop session StopQuit
        void (awaitStatus session (maybe False ((== Retired) . rolePhase) . gameplayOf))
      outcomeNow session >>= writeIORef result . Just
  readIORef result >>= maybe (throwIO (userError "the example did not finish")) pure

rawCompletions ∷ Spec
rawCompletions = describe "the evidence of how an owner ended" $ do
  it "is read from its raw completion, whatever supervision has latched, and counted once" $ do
    found ← retiringWithFailingClose []
    length [entry | entry ← entriesOf found, eeCode entry == CleanupFailure, Text.isInfixOf "close failed" (eeMessage entry)] `shouldBe` 1
    outVerdict found `shouldBe` VerdictFailure

  describe "with the raw completion not read (a negative control)" $
    it "loses the cleanup the owner retained, which the proof above detects" $ do
      found ← retiringWithFailingClose [ProtectRawCompletion]
      length [entry | entry ← entriesOf found, eeCode entry == CleanupFailure, Text.isInfixOf "close failed" (eeMessage entry)] `shouldBe` 0

-- Where a failure comes from, and what bounds it ----------------------------------------------------------------------------------

sources ∷ Spec
sources = describe "where a failure comes from" $ do
  it "counts an exception of an asynchronous type that a release itself raised as a failure of that cleanup, and the session still returns" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      failAt recorder (Released (ReleaseBuild Gameplay BuildFacade)) (toException ThreadKilled)
      (ended, session) ← runCaught env (recording recorder []) $ \_ session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        void (awaitStatus session (maybe False ((== Stopping) . rolePhase) . gameplayOf))
        void (awaitStatus session (maybe False ((== Retired) . rolePhase) . presentationOf))
      -- it was a failure of a release, not a cancellation of the caller: the call returns
      ended `shouldSatisfy` either (const False) (const True)
      found ← outcomeNow session
      outVerdict found `shouldBe` VerdictFailure
      length [entry | entry ← entriesOf found, eeCode entry == CleanupFailure, Text.isInfixOf "gameplay" (eeMessage entry)] `shouldBe` 1

  it "does not make a cancellation of the caller alone a failure of the host" $
    withSetup (setup (roleScript printScript)) $ \env → do
      (ended, session) ← runCaught env noHarness $ \driver session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        throwTo driver ThreadKilled
        void (awaitRetired session)
      raisedKilled ended `shouldBe` True
      found ← outcomeNow session
      outVerdict found `shouldBe` VerdictSuccess
      outFailures found `shouldBe` []
      erPrimary (outEngine found) `shouldBe` Nothing

  it "keeps a failure of the engine and counts every one beyond the sixteen summaries, never dropping the failure bit" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      cause ← composeCleanup (Just (caught "construction failed")) [("release", caught (Text.pack ("cleanup " <> show n))) | n ← [1 .. 20 ∷ Int]]
      maybe (pure ()) (failWith recorder (Built Presentation BuildOwner)) cause
      (_, session) ← runCaught env (recording recorder []) $ \_ session → void (awaitStatus session retiredBoth)
      found ← outcomeNow session
      let report = outEngine found
      outVerdict found `shouldBe` VerdictFailure
      fmap (Text.isInfixOf "construction failed" . eeMessage) (erPrimary report) `shouldBe` Just True
      length (erSecondary report) `shouldBe` 16
      erOmitted report `shouldBe` 4
      reportAccounted report `shouldBe` 21

  it "carries a missing settlement as a failure of the host's contract, never silently, and an intact one as nothing" $
    mapM_
      ( \(hidden, expected) →
          withSetup (setup (roleScript printScript)) {suShape = GameplayAlone} $ \env → do
            let harness = noHarness {harnessHideSettlement = \key → hidden && key == InstanceKey Gameplay 0}
            (ended, session) ← runCaught env harness $ \_ session → do
              awaitPhase session Gameplay Running
              requestStop session StopQuit
              void (awaitRetired session)
            ended `shouldSatisfy` either (const False) (const True)
            found ← outcomeNow session
            outVerdict found `shouldBe` expected
            outcomeMessages found `shouldSatisfy` (\messages → any (Text.isInfixOf "had no settlement") messages == hidden)
            kept ← historyNow session
            Map.member (InstanceKey Gameplay 0) (historyFacts kept) `shouldBe` not hidden
      )
      [(True, VerdictFailure), (False, VerdictSuccess)]

-- What a failed release carries --------------------------------------------------------------------------------------------------

-- | An exception that carries these cleanup failures beside itself, as a release does that unwound through scopes.
composedWith ∷ Text.Text → [Text.Text] → IO Caught
composedWith primary carried =
  composeCleanup (Just (caught primary)) [("inner release", caught message) | message ← carried]
    >>= maybe (throwIO (userError "no exception was composed")) pure

releases ∷ Spec
releases = describe "the cleanup failures a failed release carries" $ do
  it "accounts the release's own failure and every cleanup failure it carries, each once, when the session ends normally" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      carried ← composedWith "the facade's release failed" ["first carried", "second carried", "third carried"]
      failWith recorder (Released (ReleaseBuild Gameplay BuildFacade)) carried
      (ended, session) ← runCaught env (recording recorder []) $ \_ session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        void (awaitStatus session (maybe False ((== Retired) . rolePhase) . presentationOf))
      ended `shouldSatisfy` either (const False) (const True)
      found ← outcomeNow session
      length (entriesOf found) `shouldBe` 4
      length [entry | entry ← entriesOf found, Text.isInfixOf "carried" (eeMessage entry)] `shouldBe` 3
      length [entry | entry ← entriesOf found, Text.isInfixOf "the facade's release failed" (eeMessage entry)] `shouldBe` 1

  it "accounts the same when the driver is cancelled, and raises the cancellation with all of it beside it" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      carried ← composedWith "the facade's release failed" ["first carried", "second carried"]
      failWith recorder (Released (ReleaseBuild Gameplay BuildFacade)) carried
      (ended, session) ← runCaught env (recording recorder []) $ \driver session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        throwTo driver ThreadKilled
        void (awaitStatus session (maybe False ((== Retired) . rolePhase) . presentationOf))
      raisedKilled ended `shouldBe` True
      found ← outcomeNow session
      length (entriesOf found) `shouldBe` 3
      case ended of
        Left (ExceptionWithContext attached _) → map displayCleanupFailure (cleanupFailuresInContext attached) `shouldSatisfy` any (Text.isInfixOf "first carried" . Text.pack)
        Right _ → expectationFailure "the cancellation was lost"

  it "accounts both the hook and the backend when the timer's release fails twice, as the two halves of one release" $
    withSetup (setup (roleScript printScript)) {suShape = GameplayAlone} $ \env → do
      let world = seWorld env
          failing = case worldTimer world of
            TimerBackend arm → TimerBackend $ \microseconds wake → arm microseconds wake >>= \cancel → pure (cancel >> throwIO (userError "timer cancel failed"))
          env' = env {seSpec = (seSpec env) {sxTimer = failing}}
      recorder ← newRecorder
      failAt recorder (Released ReleaseTimer) (toException (userError "timer hook failed"))
      (ended, session) ← runCaught env' (recording recorder []) $ \driver session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        throwTo driver ThreadKilled
        void (awaitRetired session)
      raisedKilled ended `shouldBe` True
      found ← outcomeNow session
      outcomeMessages found `shouldSatisfy` any (Text.isInfixOf "timer hook failed")
      outcomeMessages found `shouldSatisfy` any (Text.isInfixOf "timer cancel failed")

  it "counts a cancel the pacing timer's backend raises while the session runs as a failure of that cleanup, even of an asynchronous type, and not as a cancellation" $
    withSetup (setup (roleScript printScript)) {suShape = GameplayAlone} $ \env → do
      let world = seWorld env
          failing = case worldTimer world of
            TimerBackend arm → TimerBackend $ \microseconds wake → arm microseconds wake >>= \cancel → pure (cancel >> throwIO ThreadKilled)
          env' = env {seSpec = (seSpec env) {sxTimer = failing}}
      (ended, session) ← runCaught env' noHarness $ \_ session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        -- the stop closes the logical role's ticks, and the driver cancels the registration it armed
        requestStop session StopQuit
        void (awaitRetired session)
      -- what the backend raised is raised as itself, a failure of the cleanup, not as a cancellation of the caller
      raisedKilled ended `shouldBe` False
      raisedMessage ended `shouldSatisfy` Text.isInfixOf "pacing timer"
      found ← outcomeNow session
      outVerdict found `shouldBe` VerdictFailure
      length [entry | entry ← entriesOf found, eeCode entry == CleanupFailure, Text.isInfixOf "pacing timer" (eeMessage entry)] `shouldBe` 1

  it "accounts every cleanup failure the backend's cancel carries when the timer is disposed of with a registration armed, each once" $
    withSetup (setup (roleScript printScript)) {suShape = GameplayAlone} $ \env → do
      let world = seWorld env
      carried ← composedWith "timer cancel failed" ["disposal cleanup one", "disposal cleanup two"]
      let failing = case worldTimer world of
            TimerBackend arm → TimerBackend $ \microseconds wake → arm microseconds wake >>= \cancel → pure (cancel >> rethrowIO carried)
          env' = env {seSpec = (seSpec env) {sxTimer = failing}}
      (ended, session) ← runCaught env' noHarness $ \driver session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        -- the driver is cancelled with a registration armed, so the final disposal cancels it and the backend raises
        throwTo driver ThreadKilled
        void (awaitRetired session)
      raisedKilled ended `shouldBe` True
      found ← outcomeNow session
      outVerdict found `shouldBe` VerdictFailure
      mapM_
        (\wanted → length [entry | entry ← entriesOf found, Text.isInfixOf wanted (eeMessage entry)] `shouldBe` 1)
        ["timer cancel failed", "disposal cleanup one", "disposal cleanup two"]

  it "accounts the cleanup the hook and the backend each carry when the timer's release fails twice, to any depth" $
    withSetup (setup (roleScript printScript)) {suShape = GameplayAlone} $ \env → do
      let world = seWorld env
      viaBackend ← composedWith "timer cancel failed" ["backend cleanup one", "backend cleanup two"]
      viaHook ← composedWith "timer hook failed" ["hook cleanup one"]
      let failing = case worldTimer world of
            TimerBackend arm → TimerBackend $ \microseconds wake → arm microseconds wake >>= \cancel → pure (cancel >> rethrowIO viaBackend)
          env' = env {seSpec = (seSpec env) {sxTimer = failing}}
      recorder ← newRecorder
      failWith recorder (Released ReleaseTimer) viaHook
      (ended, session) ← runCaught env' (recording recorder []) $ \driver session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        throwTo driver ThreadKilled
        void (awaitRetired session)
      raisedKilled ended `shouldBe` True
      found ← outcomeNow session
      mapM_
        (\wanted → length [entry | entry ← entriesOf found, Text.isInfixOf wanted (eeMessage entry)] `shouldBe` 1)
        ["timer cancel failed", "timer hook failed", "backend cleanup one", "backend cleanup two", "hook cleanup one"]

  it "accounts the cleanup failures a failing sink's exception carries" $
    withSetup (setup (roleScript printScript)) $ \env → do
      carried ← composedWith "the sink failed" ["sink cleanup one", "sink cleanup two"]
      let logger = mkLogger defaultLogFilter . callbackSink $ \entry → when (entryMessage entry == "session starting") (rethrowIO carried)
          env' = env {seSpec = (seSpec env) {sxLogger = logger}}
      (_, session) ← runCaught env' noHarness $ \_ session → void (awaitStatus session statusStopping)
      found ← outcomeNow session
      outcomeMessages found `shouldSatisfy` any (Text.isInfixOf "sink cleanup one")
      outcomeMessages found `shouldSatisfy` any (Text.isInfixOf "sink cleanup two")

-- What the settlements prove -----------------------------------------------------------------------------------------------------

historyOfKey ∷ Session → InstanceKey → IO (Maybe InstanceFact)
historyOfKey session key = Map.lookup key . historyFacts <$> historyNow session

histories ∷ Spec
histories = describe "the history a settlement proves" $ do
  it "tells a shutdown skipped because the init never succeeded from every other ending" $
    withSetup (setup (roleScript printScript {scInit = ["if api.role == 'presentation' then error('ui init failed') end"]})) $ \env → do
      (_, session) ← runCaught env noHarness $ \_ session → void (awaitRetired session)
      failedInit ← historyOfKey session (InstanceKey Presentation 0)
      -- no success, and a shutdown skipped because none ran
      fmap ifInitialized failedInit `shouldBe` Just False
      fmap ifShutdown failedInit `shouldBe` Just FactShutdownSkippedNoInit
      fmap ifEnded failedInit `shouldBe` Just EndedFailed

  it "keeps an init that succeeded when the instance went on to fail" $
    withSetup ((setup (roleScript printScript {scInit = [], scUpdate = ["error('boom')"]})) {suShape = GameplayAlone}) $ \env → do
      let world = seWorld env
      (_, session) ← runCaught env noHarness $ \_ session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        nudge world 1000000
        void (awaitRetired session)
      failedLater ← historyOfKey session (InstanceKey Gameplay 0)
      fmap ifInitialized failedLater `shouldBe` Just True
      fmap ifEnded failedLater `shouldBe` Just EndedFailed
      fmap ifShutdown failedLater `shouldSatisfy` (/= Just FactShutdownSkippedNoInit)

  it "tells an instance whose owner ended by a failure of the host, after its init, from one whose init never succeeded" $ do
    _ ←
      fatalSetup (setup (roleScript printScript {scInit = [], scUpdate = ["if api.role == 'presentation' then print('ui update') end"]})) $ \env → do
        let world = seWorld env
        failSinkOn world "ui update"
        (_, session) ← runCaught env noHarness $ \_ session → do
          awaitPhase session Presentation Running
          nudge world 1000000000
          void (awaitRetired session)
        unsafe ← historyOfKey session (InstanceKey Presentation 0)
        fmap ifInitialized unsafe `shouldBe` Just True
        fmap ifShutdown unsafe `shouldBe` Just FactShutdownSkippedUnsafe
    pure ()
