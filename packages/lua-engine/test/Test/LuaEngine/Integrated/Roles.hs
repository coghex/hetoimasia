{-# LANGUAGE OverloadedStrings #-}

-- | LFE-23, M1 integrated role failure and status/outcome: the whole session coordinator over a real content root, a
-- real manifest and boot checkpoint, real filtered Lua VMs on real supervised owners, the real module and data
-- services and the facade, with a presentation role beside an independent logical owner. Only the public `runSession` composition
-- is used (`noHarness`): a second instance of a role inside a running session is the session harness's, which these groups do not
-- use; the two-instance cases are in the facade-level groups (`Instances`, `Jobs`, `Capacity`) and in the graphics suite.
--
-- __Injected__: the monotonic clock and timer, the recording sinks, the facade-side status/quit/terminal endpoints
-- are the session's own (not substituted). Every verdict is stated from D-26/D-42/D-76 and the Lua each example
-- wrote; none is computed by the code under test. A scenario that raises stops the session and is raised again.
module Test.LuaEngine.Integrated.Roles (spec) where

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

-- | Both roles over the content that names the shared module.
withShare ∷ Script → Setup
withShare found = addFile ("lua/share.lua", shareFile) (setup (roleScript found))
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

-- | The UI instance prints a line in its init, which an example can park in the sink; nothing else prints in an init.
heldSecond ∷ Script
heldSecond =
  (duo [])
    { scInit = ["share.n = share.n + 1; self.me = share.n", "if api.role == 'presentation' then print('init ui held') end"]
    }

-- Both initialization orders --------------------------------------------------------------------------------------

startingOrders ∷ Spec
startingOrders = describe "both initialization orders" $ do
  it "runs the UI instance from its own init success while the logical init is held, and opens the logical clock only at the joint gate" $
    withSetup (withShare (duo [])) $ \env → do
      let world = seWorld env
      holdSink world "init gameplay"
      outcome ← runScenario env $ \session → do
        awaitSinkEntered world "init gameplay"
        awaitPhase session Presentation Running
        status ← statusNow session
        phasesOf status `shouldBe` (Just Starting, Just Running)
        (roleInitialized <$> gameplayOf status) `shouldBe` Just False
        -- the UI instance has started and armed its cadence while the logical init is parked in its output (all
        -- authored output goes through one sink, so what they print waits behind it)
        awaitRegistration world 1000000
        releaseSink world
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        passTime world 1000000 (elem "update gameplay 1" <$> outLines world)
        passTime world 1000000000 (elem "update ui 1" <$> outLines world)
        -- the logical role's first tick came only after the joint gate opened, which was after the UI init
        out ← outLines world
        named "update gameplay" out `shouldSatisfy` (not . null)
        requestStop session StopQuit
      outVerdict outcome `shouldBe` VerdictSuccess
      outRetired outcome `shouldBe` True

  it "holds the logical role ready, with no tick, when its init finishes first, until the UI instance's init has succeeded" $
    withSetup (withShare heldSecond) $ \env → do
      let world = seWorld env
      -- the UI instance's init is parked in its authored output (the logical init prints nothing, so it does not wait
      -- behind it): a controlled, finite gate the example opens
      holdSink world "init ui held"
      outcome ← runScenario env $ \session → do
        awaitSinkEntered world "init ui held"
        awaitPhase session Gameplay Ready
        status ← statusNow session
        (roleInitialized <$> gameplayOf status) `shouldBe` Just True
        advanceClock world 10000000
        nudge world 5000000
        out0 ← outLines world
        named "update gameplay" out0 `shouldBe` []
        releaseSink world
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitRegistration world 1000
        passTime world 1000000 (elem "update gameplay 1" <$> outLines world)
        requestStop session StopQuit
      outVerdict outcome `shouldBe` VerdictSuccess

  it "ends the whole session when the UI instance's init fails before the joint gate, retires both sides, and lets the late logical success reopen nothing" $
    withSetup (withShare (duo ["if api.role == 'presentation' then error('ui init broke') end"])) $ \env → do
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
          rfMessage found `shouldSatisfy` Text.isInfixOf "ui init broke"
          rfInstance found `shouldSatisfy` (/= Nothing)
        other → expectationFailure ("expected one failure, found " <> show other)

-- After a successful start --------------------------------------------------------------------------------------------

afterStart ∷ Spec
afterStart = describe "after a successful start" $ do
  it "stops the logical role alone on its ordinary failure and leaves the UI instance running, the failure latched and attributed while the phase advances, and a later UI stop still ends in a failure" $
    withSetup (withShare failingLogic) $ \env → do
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
        -- the UI instance goes on serving meanwhile
        passTime world 1000000000 (elem "update ui 1" <$> outLines world)
        requestStop session StopQuit
      out ← outLines world
      -- the logical role was granted nothing after its failing tick
      named "update gameplay" out `shouldBe` ["1", "2"]
      out `shouldSatisfy` elem "shutdown presentation 1 stopped"
      -- stopping the surviving UI later still maps to a failure, never to a success
      outVerdict outcome `shouldBe` VerdictFailure
      outQuit outcome `shouldBe` True
      map rfRole (outFailures outcome) `shouldBe` [Gameplay]
      outRetired outcome `shouldBe` True

  it "ends the whole session when a UI instance fails after the start: both sides are retired through their own shutdowns and the failure names the instance" $
    withSetup (withShare (duo [] `withUpdate` ["if api.role == 'presentation' then error('ui broke') end"])) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        passTime world 1000000000 (elem "update ui 1" <$> outLines world)
        void (awaitRetired session)
      out ← outLines world
      outVerdict outcome `shouldBe` VerdictFailure
      outRetired outcome `shouldBe` True
      case outFailures outcome of
        found : _ → do
          rfRole found `shouldBe` Presentation
          rfStage found `shouldBe` OnUpdate
          rfMessage found `shouldSatisfy` Text.isInfixOf "ui broke"
          rfInstance found `shouldSatisfy` (/= Nothing)
        [] → expectationFailure "no failure was published"
      -- every instance that was running was shut down once, the failed one as failed
      length (named "shutdown" out) `shouldBe` 2
      named "shutdown" out `shouldSatisfy` any ("presentation 1 failed" `Text.isPrefixOf`)

  it "keeps the unavailable-state guard terminal when the UI instance catches it in an update: one diagnostic, the whole session fails after the segment returns, every instance is shut down once, and no role is blamed" $
    withSetup (withShare ((duo []) {scUpdate = ["if api.role == 'presentation' then pcall(state, 1); print('caught ui') else print('update ' .. api.role .. ' ' .. self.me) end"]})) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Presentation Running
        passTime world 1000000000 (elem "caught ui" <$> outLines world)
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
      length (named "shutdown" out) `shouldBe` 2

  it "keeps the guard terminal when a shared module's top level catches it in both VMs: one diagnostic, no init in any instance, the failure the session's and no role's" $
    withSetup ((withShare (duo [])) {suFiles = [("lua/main.lua", roleScript (duo [])), ("lua/share.lua", luaMain ["pcall(state, 1)", "return {n = 0}"])]}) $ \env → do
      outcome ← runScenario env $ \session → void (awaitRetired session)
      out ← outLines (seWorld env)
      outVerdict outcome `shouldBe` VerdictFailure
      outFailures outcome `shouldBe` []
      fmap rfCode (outTerminal outcome) `shouldBe` Just StateUnavailable
      fmap rfStage (outTerminal outcome) `shouldBe` Just OnModule
      fmap rfInstance (outTerminal outcome) `shouldBe` Just Nothing
      out `shouldBe` []
      errLines (seWorld env) >>= \err → filter (not . ("share evaluated" `Text.isSuffixOf`)) err `shouldBe` [guardPhrase]

  it "quits from the logical role while the UI instance holds every request place it can: the call returns at once, admission closes as an ordinary error and never busy, cancel and output stay usable, and the role that holds reads retires only after they have returned" $
    withSetup (addFile ("lua/gate.bin", "gg") (addFile ("lua/slow.bin", "slow") (withShare saturating))) $ \env → do
      let world = seWorld env
          probe = ssProbeOf env
      closeGate probe "lua/slow.bin"
      closeGate probe "lua/gate.bin"
      outcome ← runScenario env $ \session → dumpOnFailure world [] $ do
        -- the logical role's first update asks for a read the reader holds and waits for it, so that it cannot quit before
        -- the UI instance has filled its places
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        nudge world 1000000
        awaitReadOf env "lua/gate.bin"
        passTime world 1000000000 ((\out → length (named "filled presentation" out) == 1) <$> outLines world)
        openGate probe "lua/gate.bin"
        passTime world 2000000 (elem "after quit gameplay" <$> outLines world)
        status ← statusNow session
        -- quit returned without waiting for the held reads: the session is stopping, and the UI role, whose reads are still held,
        -- is not retired (the logical role holds nothing and retires on its own)
        fmap rolePhase (presentationOf status) `shouldSatisfy` (/= Just Retired)
        statusStopping status `shouldBe` True
        openGate probe "lua/slow.bin"
        void (awaitRetired session)
      out ← outLines world
      -- The compact boundary here is the read pool this example injects: twelve slots, of which each of the two VM
      -- coordinators holds four for its life, so four reads can be held in all, wherever they were asked (the logical role's
      -- own gated read took one), and every ask beyond them was answered busy with nothing reserved. (The profile's 16 places
      -- per instance are not reachable before the pool is full; the facade's examples cover that bound.)
      let filled = [(role, count, busy) | line ← named "filled" out, [role, _, count, busy] ← [Text.words line]]
      sum [read (Text.unpack count) | (_, count, _) ← filled] `shouldBe` (3 ∷ Int)
      map (\(role, _, busy) → (role, busy)) (sort filled) `shouldBe` [("gameplay", "busy"), ("presentation", "busy")]
      named "closed" out `shouldBe` ["false string"]
      named "cancel" out `shouldSatisfy` any (`elem` ["cancelled", "already_settled"])
      errLines world >>= \err → err `shouldSatisfy` any (Text.isSuffixOf "written after quit")
      outVerdict outcome `shouldBe` VerdictSuccess
      outQuit outcome `shouldBe` True

  it "reads a status that is one coherent copy within a UI segment, edits of it reaching nobody, and refreshed when the instance resumes after a wait: the logical failure stays latched while its phase advances" $
    withSetup (addFile ("lua/hold.bin", "hold") (addFile ("lua/slow.bin", "slow") (withShare statusReading))) $ \env → do
      let world = seWorld env
          probe = ssProbeOf env
      -- the first UI instance waits on a read the pool's reader holds, so its resumption is placed by the example and not by a
      -- clock; the logical role's failure waits on another, so that it cannot come before the instance has taken its first sample
      closeGate probe "lua/slow.bin"
      closeGate probe "lua/hold.bin"
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitRegistration world 1000
        nudge world 1000000
        passTime world 1000000000 (elem "segment waiting" <$> outLines world)
        -- the logical role is let go: it fails at its second tick and retires, while the instance still waits
        openGate probe "lua/hold.bin"
        passTime world 2000000 ((maybe False roleFailed . gameplayOf <$> statusNow session))
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
            , "  if t == 1 then api.request.wait((api.content.data('lua/hold.bin'))) end"
            , "  if t > 1 then error('logic broke at ' .. t) end"
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
      (duo [])
        { scUpdate =
            [ "if self.reqs then return end"
            , "if api.role == 'gameplay' then"
            , "  self.first = api.content.data('lua/gate.bin')"
            , "  api.request.wait(self.first)"
            , "end"
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
