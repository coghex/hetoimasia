{-# LANGUAGE OverloadedStrings #-}

-- | LFE-23, M1 integrated role failure and status/outcome: the whole session coordinator over a real content root, a
-- real manifest and boot checkpoint, real filtered Lua VMs on real supervised owners, the real module and data
-- services, the facade, and two ordinary presentation instances (the session harness's second slot, admitted and
-- validated like the first) beside an independent logical owner.
--
-- __Injected__: the monotonic clock and timer, the recording sinks, the facade-side status/quit/terminal endpoints
-- are the session's own (not substituted), and the harness's probe points, which a test holds or makes raise to place
-- a stop or a failure in an exact window. Every verdict is stated from D-26/D-42/D-76 and the Lua each example
-- wrote; none is computed by the code under test. A scenario that raises stops the session and is raised again.
module Test.LuaEngine.Integrated.Roles (spec) where

import Control.Exception (finally)
import Control.Monad (forM_, void, when)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec
import Test.LuaEngine.Integrated.Support (dumpOnFailure, named, shareModule)
import Test.LuaEngine.Modules.Support (closeGate, openGate)
import Test.LuaEngine.Session.Support

spec ∷ Spec
spec = describe "M1 integrated role failure, status and outcome" $ do
  startingOrders
  afterStart

-- | The harness's second presentation instance.
p1 ∷ InstanceKey
p1 = InstanceKey Presentation 1

-- | Two presentation instances beside the logical owner, over the content that names the shared module.
twoUi ∷ Script → Setup
twoUi found =
  addFile ("lua/share.lua", shareFile) (setup (roleScript found)) {suHarness = noHarness {harnessSecond = [Presentation]}}
  where
    shareFile = shareModule

-- | Both roles' behavior: the UI instances count themselves through the VM's one shared export and say so; the logical
-- role says when it ran. The extra lines run in @init@ before they say anything.
duo ∷ [Text] → Script
duo extraInit =
  printScript
    { scPrelude = ["local share = import('lua/share.lua')"]
    , scInit =
        [ "share.n = share.n + 1; self.me = share.n"
        ]
          <> extraInit
          <> ["if api.role == 'gameplay' then print('init gameplay') end"]
    , scUpdate =
        [ "if api.role == 'gameplay' then print('update gameplay ' .. api.time.tick()) else print('update ui ' .. self.me) end"
        ]
    , scShutdown = ["print('shutdown ' .. api.role .. ' ' .. self.me .. ' ' .. tostring(reason))"]
    }

-- Both initialization orders --------------------------------------------------------------------------------------

startingOrders ∷ Spec
startingOrders = describe "both initialization orders" $ do
  it "runs both UI instances from their own init successes while the logical init is held, and opens the logical clock only at the joint gate" $
    withSetup (twoUi (duo [])) $ \env → do
      let world = seWorld env
      holdSink world "init gameplay"
      outcome ← runScenario env $ \session → do
        awaitSinkEntered world "init gameplay"
        awaitPhase session Presentation Running
        status ← statusNow session
        phasesOf status `shouldBe` (Just Starting, Just Running)
        (roleInitialized <$> gameplayOf status) `shouldBe` Just False
        -- both UI instances have started and armed their cadence while the logical init is parked in its output (all
        -- authored output goes through one sink, so what they print waits behind it)
        awaitRegistration world 1000000
        releaseSink world
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        passTime world 1000000 (elem "update gameplay 1" <$> outLines world)
        passTime world 1000000000 ((\out → "update ui 1" `elem` out && "update ui 2" `elem` out) <$> outLines world)
        -- the logical role's first tick came only after the joint gate opened, which was after both UI inits
        out ← outLines world
        named "update gameplay" out `shouldSatisfy` (not . null)
        requestStop session StopQuit
      outVerdict outcome `shouldBe` VerdictSuccess
      outRetired outcome `shouldBe` True

  it "holds the logical role ready, with no tick, when its init finishes first, until the second UI instance's init has succeeded" $
    withSetup (twoUi (duo [])) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Dispatched p1)
      outcome ← runScenarioWith env (recordingHarness recorder (suHarness (twoUi (duo [])))) $ \session → (`finally` releaseHold recorder (Dispatched p1)) $ do
        awaitPoint recorder (Dispatched p1)
        awaitPhase session Gameplay Ready
        status ← statusNow session
        (roleInitialized <$> gameplayOf status) `shouldBe` Just True
        advanceClock world 10000000
        nudge world 5000000
        out0 ← outLines world
        named "update gameplay" out0 `shouldBe` []
        releaseHold recorder (Dispatched p1)
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitRegistration world 1000
        passTime world 1000000 (elem "update gameplay 1" <$> outLines world)
        requestStop session StopQuit
      outVerdict outcome `shouldBe` VerdictSuccess

  it "ends the whole session when the second UI instance's init fails before the joint gate, retires both sides, and lets the late logical success reopen nothing" $
    withSetup (twoUi (duo ["if api.role == 'presentation' and self.me == 2 then error('second ui init broke') end"])) $ \env → do
      let world = seWorld env
      -- the logical init is parked in its output, so that its success comes after the failure
      holdSink world "init gameplay"
      outcome ← runScenario env $ \session → do
        awaitSinkEntered world "init gameplay"
        status ← awaitStatus session statusStopping
        statusStopping status `shouldBe` True
        -- the order the example claims: the session is already stopping while the logical init's output is still parked,
        -- so that its success has not happened yet
        (roleInitialized <$> gameplayOf status) `shouldBe` Just False
        outLines world >>= (`shouldSatisfy` notElem "init gameplay")
        releaseSink world
        void (awaitRetired session)
      out ← outLines world
      named "update gameplay" out `shouldBe` []
      outVerdict outcome `shouldBe` VerdictFailure
      outRetired outcome `shouldBe` True
      case outFailures outcome of
        [found] → do
          rfRole found `shouldBe` Presentation
          rfStage found `shouldBe` OnInit
          rfMessage found `shouldSatisfy` Text.isInfixOf "second ui init broke"
          rfInstance found `shouldSatisfy` (/= Nothing)
        other → expectationFailure ("expected one failure, found " <> show other)

-- After a successful start --------------------------------------------------------------------------------------------

afterStart ∷ Spec
afterStart = describe "after a successful start" $ do
  it "stops the logical role alone on its ordinary failure and leaves both UI instances running, the failure latched and attributed while the phase advances, and a later UI stop still ends in a failure" $
    withSetup (twoUi failingLogic) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitRegistration world 1000
        passTime world 2000000 (elem "update gameplay 2" <$> outLines world)
        status ← awaitStatus session (maybe False roleFailed . gameplayOf)
        -- a failure of the logical role is not the whole session's: nothing is stopping, the UI is not failed
        statusStopping status `shouldBe` False
        fmap roleFailed (presentationOf status) `shouldBe` Just False
        let published = gameplayOf status >>= roleFailure
        fmap rfCode published `shouldBe` Just LuaError
        fmap rfStage published `shouldBe` Just OnUpdate
        fmap rfRole published `shouldBe` Just Gameplay
        fmap rfMessage published `shouldSatisfy` maybe False (Text.isInfixOf "boom at 2")
        awaitPhase session Gameplay Retired
        -- the failure stays latched, the same record, as the phase advanced to retired
        retired ← statusNow session
        (gameplayOf retired >>= roleFailure) `shouldBe` published
        -- both UI instances go on serving meanwhile
        passTime world 1000000000 ((\out → "update ui 1" `elem` out && "update ui 2" `elem` out) <$> outLines world)
        requestStop session StopQuit
      out ← outLines world
      -- the logical role was granted nothing after its failing tick
      named "update gameplay" out `shouldBe` ["1", "2"]
      out `shouldSatisfy` elem "shutdown presentation 1 stopped"
      out `shouldSatisfy` elem "shutdown presentation 2 stopped"
      -- stopping the surviving UI later still maps to a failure, never to a success
      outVerdict outcome `shouldBe` VerdictFailure
      outQuit outcome `shouldBe` True
      map rfRole (outFailures outcome) `shouldBe` [Gameplay]
      outRetired outcome `shouldBe` True

  it "ends the whole session when a UI instance fails after the start: both sides are retired through their own shutdowns and the failure names the instance" $
    withSetup (twoUi (duo [] `withUpdate` ["if api.role == 'presentation' and self.me == 2 then error('second ui broke') end"])) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        passTime world 1000000000 (elem "update ui 2" <$> outLines world)
        void (awaitRetired session)
      out ← outLines world
      outVerdict outcome `shouldBe` VerdictFailure
      outRetired outcome `shouldBe` True
      case outFailures outcome of
        found : _ → do
          rfRole found `shouldBe` Presentation
          rfStage found `shouldBe` OnUpdate
          rfMessage found `shouldSatisfy` Text.isInfixOf "second ui broke"
          rfInstance found `shouldSatisfy` (/= Nothing)
        [] → expectationFailure "no failure was published"
      -- every instance that was running was shut down once, the failed one as failed
      length (named "shutdown" out) `shouldBe` 3
      named "shutdown" out `shouldSatisfy` any ("presentation 2 failed" `Text.isPrefixOf`)

  it "ends a healthy UI at once when the failed logical role's cleanup then fails, and keeps the primary failure with the bounded secondary evidence" $ do
    _ ←
      fatalSetup
        (twoUi closingLogic) {suHarness = noHarness {harnessSecond = [Gameplay, Presentation]}}
        $ \env → do
          let world = seWorld env
          outcome ← runScenario env $ \session → do
            awaitPhase session Gameplay Running
            awaitPhase session Presentation Running
            awaitRegistration world 1000
            nudge world 2000000
            void (awaitRetired session)
          out ← outLines world
          out `shouldSatisfy` any ("shutdown presentation" `Text.isPrefixOf`)
          outVerdict outcome `shouldBe` VerdictFailure
          fmap rfRole (outFailures outcome) `shouldSatisfy` (Gameplay `elem`)
          fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just LuaError
          fmap eeCode (erSecondary (outEngine outcome)) `shouldSatisfy` (CleanupFailure `elem`)
    pure ()

  it "keeps the unavailable-state guard terminal when a second UI instance catches it in an update: one diagnostic, the whole session fails after the segment returns, every instance is shut down once, and no role is blamed" $
    withSetup (twoUi ((duo []) {scUpdate = ["if api.role == 'presentation' and self.me == 2 then pcall(state, 1); print('caught ui 2') else print('update ' .. api.role .. ' ' .. self.me) end"]})) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Presentation Running
        passTime world 1000000000 (elem "caught ui 2" <$> outLines world)
        void (awaitRetired session)
      out ← outLines world
      outVerdict outcome `shouldBe` VerdictFailure
      outRetired outcome `shouldBe` True
      outFailures outcome `shouldBe` []
      case outTerminal outcome of
        Just found → do
          rfCode found `shouldBe` StateUnavailable
          rfStage found `shouldBe` OnUpdate
          rfRole found `shouldBe` Presentation
          rfInstance found `shouldSatisfy` (/= Nothing)
        Nothing → expectationFailure "no terminal failure was latched"
      errLines world >>= \err → filter (not . ("share evaluated" `Text.isSuffixOf`)) err `shouldBe` [guardPhrase]
      -- protected cleanup: each instance that was admitted ran its shutdown exactly once
      length (named "shutdown" out) `shouldBe` 3

  it "keeps the guard terminal when a shared module's top level catches it in both VMs: one diagnostic, no init in any instance, the failure the session's and no role's" $
    withSetup ((twoUi (duo [])) {suFiles = [("lua/main.lua", roleScript (duo [])), ("lua/share.lua", luaMain ["pcall(state, 1)", "return {n = 0}"])]}) $ \env → do
      outcome ← runScenario env $ \session → void (awaitRetired session)
      out ← outLines (seWorld env)
      outVerdict outcome `shouldBe` VerdictFailure
      outFailures outcome `shouldBe` []
      fmap rfCode (outTerminal outcome) `shouldBe` Just StateUnavailable
      fmap rfStage (outTerminal outcome) `shouldBe` Just OnModule
      fmap rfInstance (outTerminal outcome) `shouldBe` Just Nothing
      out `shouldBe` []
      errLines (seWorld env) >>= \err → filter (not . ("share evaluated" `Text.isSuffixOf`)) err `shouldBe` [guardPhrase]

  it "quits from the logical role while both UI instances hold every request place: the call returns at once, admission closes as an ordinary error and never busy, cancel and output stay usable, and the role retires only after the held reads have" $
    withSetup (addFile ("lua/slow.bin", "slow") (twoUi saturating)) $ \env → do
      let world = seWorld env
          probe = ssProbeOf env
      closeGate probe "lua/slow.bin"
      recorder ← newRecorder
      holdAt recorder (GrantIntent 1)
      outcome ← runScenarioWith env (recordingHarness recorder (suHarness (twoUi saturating))) $ \session → (`finally` releaseHold recorder (GrantIntent 1)) . dumpOnFailure world [] $ do
        -- the logical role has started and asked for one read in its init; its first tick is held, so that it cannot quit
        -- before both UI instances have filled their places
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        nudge world 1000000
        awaitPoint recorder (GrantIntent 1)
        passTime world 1000000000 ((\out → length (named "filled presentation" out) == 2) <$> outLines world)
        releaseHold recorder (GrantIntent 1)
        passTime world 1000000 (elem "after quit gameplay" <$> outLines world)
        status ← statusNow session
        -- quit returned without waiting for the held reads: both roles are stopping and neither is retired
        fmap rolePhase (gameplayOf status) `shouldSatisfy` (/= Just Retired)
        fmap rolePhase (presentationOf status) `shouldSatisfy` (/= Just Retired)
        statusStopping status `shouldBe` True
        openGate probe "lua/slow.bin"
        void (awaitRetired session)
      out ← outLines world
      -- The compact boundary here is the read pool this example injects: twelve slots, of which each of the two VM
      -- coordinators holds four for its life, so four reads can be held in all, wherever they were asked (the logical init took one), and every ask
      -- beyond them was answered busy with nothing reserved. (The profile's 16 places per instance are not reachable
      -- before the pool is full; the facade's examples cover that bound.)
      let filled = [(role, count, busy) | line ← named "filled" out, [role, _, count, busy] ← [Text.words line]]
      sum [read (Text.unpack count) | (_, count, _) ← filled] `shouldBe` (3 ∷ Int) -- (the logical init holds the fourth)
      map (\(role, _, busy) → (role, busy)) (sort filled) `shouldBe` [("gameplay", "busy"), ("presentation", "busy"), ("presentation", "busy")]
      named "closed" out `shouldBe` ["false string"]
      named "cancel" out `shouldSatisfy` any (`elem` ["cancelled", "already_settled"])
      errLines world >>= \err → err `shouldSatisfy` any (Text.isSuffixOf "written after quit")
      outVerdict outcome `shouldBe` VerdictSuccess
      outQuit outcome `shouldBe` True

  it "reads a status that is one coherent copy within a UI segment, edits of it reaching nobody, and refreshed when the instance resumes after a wait: the logical failure stays latched while its phase advances" $
    withSetup (addFile ("lua/slow.bin", "slow") (twoUi statusReading)) $ \env → do
      let world = seWorld env
          probe = ssProbeOf env
      -- the first UI instance waits on a read the pool's reader holds, so its resumption is placed by the example and not by a clock
      closeGate probe "lua/slow.bin"
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        passTime world 1000000000 (elem "segment waiting" <$> outLines world)
        -- while the instance waits, the logical role fails at its second tick and retires
        void (awaitStatus session (maybe False roleFailed . gameplayOf))
        awaitPhase session Gameplay Retired
        -- the read is let go: the instance resumes and reads the new state; its first reads were untouched by the edits and the change
        openGate probe "lua/slow.bin"
        passTime world 1000000000 (any (Text.isPrefixOf "resumed failed true|") <$> outLines world)
        requestStop session StopQuit
      out ← outLines world
      named "segment" out `shouldBe` ["same true", "unedited true", "before failed false", "waiting"]
      outVerdict outcome `shouldBe` VerdictFailure

  forM_ [("gameplay", GameplayAlone, Gameplay), ("presentation", PresentationAlone, Presentation)] $ \(label, shape, role) →
    it ("ends a session of the " <> label <> " role alone when that role fails after the start: the failure is the session's, with no healthy peer to carry on") $
      withSetup ((setup (roleScript printScript {scInit = [], scUpdate = ["print('update ' .. api.role)", "error('only role broke')"], scShutdown = []})) {suShape = shape}) $ \env → do
        let world = seWorld env
        outcome ← runScenario env $ \session → do
          awaitPhase session role Running
          awaitRegistration world (if role == Gameplay then 1000 else 1000000)
          passTime world 1000000000 (elem ("update " <> if role == Gameplay then "gameplay" else "presentation") <$> outLines world)
          void (awaitRetired session)
        outVerdict outcome `shouldBe` VerdictFailure
        outRetired outcome `shouldBe` True
        map rfRole (outFailures outcome) `shouldBe` [role]
        fmap rfMessage (headMay (outFailures outcome)) `shouldSatisfy` maybe False (Text.isInfixOf "only role broke")

  describe "the same public assembly" $
    forM_ assemblies $ \(label, shape, entries) →
      it ("runs " <> label <> " from the manifest alone, each present role once, and stops with success") $
        withSetup ((setup (roleScript printScript)) {suShape = shape, suEntries = entries, suFiles = [("lua/main.lua", roleScript printScript), ("lua/g.lua", roleScript printScript), ("lua/u.lua", roleScript printScript)]}) $ \env → do
          outcome ← runScenario env $ \session → do
            when (shape /= PresentationAlone) (awaitPhase session Gameplay Running)
            when (shape /= GameplayAlone) (awaitPhase session Presentation Running)
            requestStop session StopQuit
          out ← outLines (seWorld env)
          length (filter (== "init gameplay") out) `shouldBe` (if shape == PresentationAlone then 0 else 1)
          length (filter (== "init presentation") out) `shouldBe` (if shape == GameplayAlone then 0 else 1)
          outVerdict outcome `shouldBe` VerdictSuccess
          outRetired outcome `shouldBe` True
  where
    headMay found = case found of
      first : _ → Just first
      [] → Nothing
    guardPhrase = "state service not available in this milestone"
    assemblies =
      [ ("the common entry for both roles", BothRoles', Nothing)
      , ("separate entries for both roles", BothRoles', Just ("lua/g.lua", "lua/u.lua"))
      , ("the gameplay role alone on a common entry", GameplayAlone, Nothing)
      , ("the gameplay role alone on its own entry", GameplayAlone, Just ("lua/g.lua", "lua/u.lua"))
      , ("the presentation role alone on a common entry", PresentationAlone, Nothing)
      , ("the presentation role alone on its own entry", PresentationAlone, Just ("lua/g.lua", "lua/u.lua"))
      ]
    statusReading =
      (duo [])
        { scPrelude = scPrelude (duo []) <> dumpPrelude
        , scUpdate =
            [ "if api.role == 'gameplay' then"
            , "  local t = api.time.tick()"
            , "  print('update gameplay ' .. t)"
            , "  if t == 2 then error('logic broke at ' .. t) end"
            , "  return"
            , "end"
            , "if self.me ~= 1 or self.done then return end"
            , "self.done = true"
            , "local first = api.session.status()"
            , "local second = api.session.status()"
            , "print('segment same ' .. tostring(dump(first) == dump(second)))"
            , "first.stopping = true first.gameplay.failed = true"
            , "print('segment unedited ' .. tostring(dump(second) == dump(api.session.status())))"
            , "print('segment before failed ' .. tostring(api.session.status().gameplay.failed))"
            , "print('segment waiting')"
            , "api.request.wait((api.content.data('lua/slow.bin')))"
            , "local after = api.session.status()"
            , "print('resumed failed ' .. tostring(after.gameplay.failed) .. '|' .. tostring(after.gameplay.phase))"
            ]
        }
    saturating =
      (duo ["if api.role == 'gameplay' then self.first = api.content.data('lua/slow.bin', {tick_offset = 1000}) end"])
        { scUpdate =
            [ "if self.reqs then return end"
            , "self.reqs = {}"
            , "local busy"
            , "for i = 1, 40 do"
            , "  local r, e = api.content.data('lua/slow.bin')"
            , "  if r == nil then busy = e.code break end"
            , "  self.reqs[#self.reqs + 1] = r"
            , "end"
            , "print('filled ' .. api.role .. ' ' .. self.me .. ' ' .. #self.reqs .. ' ' .. tostring(busy))"
            , "if api.role == 'gameplay' then"
            , "  api.session.quit()"
            , "  print('after quit gameplay')"
            , "  local ok, e = pcall(api.content.data, 'lua/slow.bin')"
            , "  print('closed ' .. tostring(ok) .. ' ' .. type(e))"
            , "  print('cancel ' .. tostring(api.request.cancel(self.first)))"
            , "  warn('written after quit')"
            , "end"
            ]
        }
    withUpdate found extra = found {scUpdate = scUpdate found <> extra}
    failingLogic =
      (duo [])
        { scUpdate =
            [ "if api.role == 'gameplay' then"
            , "  local t = api.time.tick()"
            , "  print('update gameplay ' .. t)"
            , "  if t == 2 then error('boom at ' .. t) end"
            , "else"
            , "  print('update ui ' .. self.me)"
            , "end"
            ]
        }
    closingLogic =
      (duo [])
        { scUpdate =
            [ "if api.role == 'gameplay' then"
            , "  if self.me == 1 then"
            , "    if api.time.tick() == 2 then error('boom') end"
            , "  else"
            , "    local guard <close> = setmetatable({}, {__close = function() error('close failed') end})"
            , "    api.time.wait_ticks(100)"
            , "  end"
            , "end"
            ]
        }
