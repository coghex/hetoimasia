{-# LANGUAGE OverloadedStrings #-}

-- | The Lua status, quit and unavailable-state bindings over the real session coordinator (LFE-26): real
-- filtered Lua VMs on real supervised owners the coordinator starts, over a real content root, manifest and
-- boot checkpoint, an injected clock and a fake timer, recording sinks and explicit gates. The injected-endpoint
-- examples that check each binding on its own are "Test.LuaEngine.Facade.Control"; the conversions that need
-- no Lua are "Test.LuaEngine.Session.Control".
--
-- Nothing sleeps and nothing hangs on purpose. An example knows what has happened from what its Lua printed,
-- from the status, or from a gate it holds (a sink that parks the writer of one line, a harness point that
-- parks the thread that reaches it, a read the pool's reader parks); a scenario that raises stops the
-- session and is raised again, so a failed assertion is never swallowed.
module Test.LuaEngine.Session.Api (spec) where

import Control.Concurrent (throwTo)
import Control.Concurrent.STM (atomically, readTVar, readTVarIO, retry)
import Control.Exception (AsyncException (ThreadKilled), finally)
import Control.Monad (void, when)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec
import Test.LuaEngine.Modules.Support (closeGate, openGate)
import Test.LuaEngine.Session.Support
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "status, quit and the unavailable-state guard" $ do
  statusAtEachHook
  statusAcrossFailures
  statusCapture
  quitting
  guardInSessions

-- Expectations -----------------------------------------------------------------------------------------------------

phrase ∷ Text
phrase = "state service not available in this milestone"

-- | One present, nonfailed role as @dump@ shows it.
roleDump ∷ Bool → Text → Text
roleDump initialized phase = "{failed=false,initialized=" <> flag initialized <> ",phase=\"" <> phase <> "\",present=true}"

flag ∷ Bool → Text
flag found = if found then "true" else "false"

-- | A whole status as @dump@ shows it.
sessionDump ∷ Bool → Text → Text → Text
sessionDump stopping gameplay presentation = "{gameplay=" <> gameplay <> ",presentation=" <> presentation <> ",stopping=" <> flag stopping <> "}"

absent ∷ Text
absent = "{present=false}"

-- | The lines the Lua printed that begin with this prefix, with the prefix removed.
linesWith ∷ Text → World → IO [Text]
linesWith prefix world = (\out → [Text.drop (Text.length prefix) line | line ← out, prefix `Text.isPrefixOf` line]) <$> outLines world

-- | Block until stdout holds exactly this line.
awaitLine ∷ World → Text → IO ()
awaitLine world line = bounded . atomically $ do
  found ← readTVar (wLines world)
  when ((Stdout, line) `notElem` found) retry

-- | Block until stdout holds a line with this prefix.
awaitLine' ∷ World → Text → IO ()
awaitLine' world prefix = bounded . atomically $ do
  found ← readTVar (wLines world)
  when (not (any (\(stream, line) → stream == Stdout && prefix `Text.isPrefixOf` line) found)) retry

-- | Hold these points of the session for the scenario, and always let them go when it ends: an example that fails
-- unwinds at once instead of waiting on a hold of its own.
scenarioHolding ∷ SessionEnv → Recorder → [Point] → (Session → IO ()) → IO SessionOutcome
scenarioHolding env recorder points scenario = do
  mapM_ (holdAt recorder) points
  runScenarioWith env (recordingHarness recorder noHarness) $ \session →
    scenario session `finally` mapM_ (releaseHold recorder) points

g0, p0 ∷ InstanceKey
g0 = InstanceKey Gameplay 0
p0 = InstanceKey Presentation 0

-- | A behavior of both roles that shows the presentation role its status at every hook, and prints the
-- gameplay role's init so that a test can hold it in the output.
uiScript ∷ Script
uiScript =
  printScript
    { scPrelude = dumpPrelude
    , scInit =
        [ "if api.role == 'gameplay' then print('init gameplay') end"
        , "if api.role == 'presentation' then print('ui init ' .. dump(api.session.status())) end"
        ]
    , scUpdate = ["if api.role == 'presentation' then print('ui update ' .. dump(api.session.status())) end"]
    , scShutdown = ["if api.role == 'presentation' then print('ui shutdown ' .. dump(api.session.status())) end"]
    }

-- Status at each hook ----------------------------------------------------------------------------------------------

statusAtEachHook ∷ Spec
statusAtEachHook = describe "api.session.status()" $ do
  it "gives a session of the presentation role alone its own capture at init, at an update and at shutdown, with the gameplay role absent" $
    withSetup ((setup (roleScript uiScript)) {suShape = PresentationAlone}) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Presentation Running
        passTime world 1000000000 (any (Text.isPrefixOf "ui update") <$> outLines world)
        requestStop session StopQuit
        void (awaitRetired session)
      linesWith "ui init " world `shouldReturn` [sessionDump False absent (roleDump False "starting")]
      updates ← linesWith "ui update " world
      updates `shouldSatisfy` (not . null)
      updates `shouldSatisfy` all (== sessionDump False absent (roleDump True "running"))
      -- the shutdown is a hook of its own, begun after the stop: its capture says so, and the historical fact stays
      linesWith "ui shutdown " world `shouldReturn` [sessionDump True absent (roleDump True "stopping")]
      outVerdict outcome `shouldBe` VerdictSuccess

  it "shows starting while the logical init is held, then running, and lets the presentation role run meanwhile without waiting for the logical owner" $
    withSetup (setup (roleScript uiScript)) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      void . scenarioHolding env recorder [Dispatched g0] $ \session → do
        awaitPoint recorder (Dispatched g0)
        awaitPhase session Presentation Running
        passTime world 1000000000 (any (Text.isPrefixOf "ui update") <$> outLines world)
        firstUpdates ← linesWith "ui update " world
        firstUpdates `shouldSatisfy` all (== sessionDump False (roleDump False "starting") (roleDump True "running"))
        releaseHold recorder (Dispatched g0)
        awaitPhase session Gameplay Running
        passTime world 1000000000 (elem (sessionDump False (roleDump True "running") (roleDump True "running")) <$> linesWith "ui update " world)
        requestStop session StopQuit

  it "shows ready, which is the logical role's own init and not the readiness of assets, to a presentation init that begins after it" $
    withSetup (setup (roleScript uiScript)) $ \env → do
      recorder ← newRecorder
      void . scenarioHolding env recorder [Dispatched p0] $ \session → do
        awaitPoint recorder (Dispatched p0)
        awaitPhase session Gameplay Ready
        releaseHold recorder (Dispatched p0)
        awaitPhase session Presentation Running
        requestStop session StopQuit
      linesWith "ui init " (seWorld env) `shouldReturn` [sessionDump False (roleDump True "ready") (roleDump False "starting")]

  it "is refused to the logical role and to a module's top level, as ordinary errors that leave a healthy session healthy" $
    withSetup (setup (roleScript printScript {scPrelude = [], scInit = ["print('status ' .. tostring(pcall(api.session.status)) .. ' ' .. api.role)", "print('quit ' .. tostring(select('#', api.session.quit())) .. ' ' .. api.role)"]})) $ \env → do
      outcome ← runScenario env $ \session → void (awaitRetired session)
      out ← outLines (seWorld env)
      out `shouldSatisfy` elem "status false gameplay"
      out `shouldSatisfy` elem "status true presentation"
      outVerdict outcome `shouldBe` VerdictSuccess

-- Status across a failure ---------------------------------------------------------------------------------------------

statusAcrossFailures ∷ Spec
statusAcrossFailures = describe "api.session.status() across an ordinary logical failure" $ do
  it "shows the first failure with stopping=false while the role's provider holds its retirement, and the same failure, still initialized, once the role has actually retired" $
    withSetup
      ( addFile
          ("lua/slow.bin", "slow")
          (setup (roleScript uiScript {scInit = ["if api.role == 'gameplay' then self.request = api.content.data('lua/slow.bin', {tick_offset = 5}) end"], scUpdate = ["if api.role == 'gameplay' then error('boom') else print('ui update ' .. dump(api.session.status())) end"]}))
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
          void (awaitStatus session (maybe False roleFailed . gameplayOf))
          -- the role is failed and stopping, its provider has not retired what it holds, and the session is not stopping
          passTime world 1000000000 (any (Text.isInfixOf "failed=true") <$> outLines world)
          held ← filter (Text.isInfixOf "failed=true") <$> linesWith "ui update " world
          case held of
            line : _ → do
              line `shouldSatisfy` Text.isInfixOf ",initialized=true,phase=\"stopping\",present=true},presentation="
              line `shouldSatisfy` Text.isSuffixOf (",presentation=" <> roleDump True "running" <> ",stopping=false}")
              mapM_ (line `shouldSatisfy`) [Text.isInfixOf piece | piece ← ["code=\"lua_error\"", "content_id=\"modules-test\"", "instance_id=\"inst-1\"", "role=\"gameplay\"", "stage=\"update\"", "traceback=\"", "boom"]]
              line `shouldNotSatisfy` Text.isInfixOf "path="
            [] → expectationFailure "no update showed the failure"
          openGate probe "lua/slow.bin"
          awaitPhase session Gameplay Retired
          passTime world 1000000000 (any (Text.isInfixOf "phase=\"retired\"") <$> outLines world)
          requestStop session StopQuit
        updates ← linesWith "ui update " world
        let failureOf line = fst (Text.breakOn ",initialized=" (snd (Text.breakOn "failure={" line)))
            stoppingLines = [line | line ← updates, Text.isInfixOf "failed=true" line, Text.isInfixOf "phase=\"stopping\"" line]
            retiredLines = [line | line ← updates, Text.isInfixOf "phase=\"retired\"" line]
        case (stoppingLines, retiredLines) of
          (stoppingLine : _, retiredLine : _) → do
            failureOf retiredLine `shouldBe` failureOf stoppingLine
            retiredLine `shouldSatisfy` Text.isInfixOf ",initialized=true,phase=\"retired\",present=true}"
          other → expectationFailure ("expected a stopping and a retired showing of the failure, found " <> show other)

  it "shows a failure's message cut visibly at the message bound, the coordinator's bounded text and nothing rebuilt" $
    withSetup
      ( (setup (roleScript uiScript {scInit = [], scUpdate = ["if api.role == 'gameplay' then error(string.rep('x', 5000), 0) else local f = api.session.status().gameplay.failure if f then print('long ' .. tostring(#f.message > 3 and #f.message <= 2048) .. ' ' .. f.message:sub(1, 5) .. ' ' .. f.message:sub(-3)) end end"]}))
      )
      $ \env → do
        let world = seWorld env
        void . runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          awaitRegistration world 1000
          nudge world 1000000
          void (awaitStatus session (maybe False roleFailed . gameplayOf))
          passTime world 1000000000 (any (Text.isPrefixOf "long ") <$> outLines world)
          requestStop session StopQuit
        shown ← linesWith "long " world
        -- the message is the coordinator's bounded text: within 2 KiB, and cut visibly where the host's own bound cut it
        take 1 shown `shouldBe` ["true Bound xxx"]

-- Capture -------------------------------------------------------------------------------------------------------

statusCapture ∷ Spec
statusCapture = describe "the capture of a segment" $ do
  it "describes the same moment for every read of the segment, however the coordinator changes meanwhile, and no edit of a result reaches a later read" $
    withSetup ((setup (roleScript capturing)) {suShape = PresentationAlone}) $ \env → do
      let world = seWorld env
      holdSink world "held"
      void . runScenario env $ \session → do
        awaitPhase session Presentation Running
        passTime world 1000000000 (elem "held" <$> readTVarIO (wSinkEntered world))
        -- the coordinator moves on while the update is parked in its output
        requestStop session StopQuit
        stopped ← statusNow session
        statusStopping stopped `shouldBe` True
        releaseSink world
        void (awaitRetired session)
      captures ← mapM (`linesWith` seWorld env) ["first ", "second ", "third "]
      captures `shouldBe` replicate 3 [sessionDump False absent (roleDump True "running")]
      -- the next hook is a new segment with a capture of its own
      linesWith "shutdown " (seWorld env) `shouldReturn` [sessionDump True absent (roleDump True "stopping")]

  it "is refreshed when an invocation resumes after a wait, without changing its dt" $
    withSetup (addFile ("lua/slow.bin", "slow") (setup (roleScript resuming))) $ \env → do
      let world = seWorld env
          probe = ssProbeOf env
      recorder ← newRecorder
      -- the update waits on a read the pool's reader holds, so the resumption is placed by the example and not by a clock
      closeGate probe "lua/slow.bin"
      void . scenarioHolding env recorder [Dispatched g0] $ \session → do
        awaitPoint recorder (Dispatched g0)
        awaitPhase session Presentation Running
        passTime world 1000000000 (any (Text.isPrefixOf "before ") <$> outLines world)
        awaitReadOf env "lua/slow.bin"
        releaseHold recorder (Dispatched g0)
        awaitPhase session Gameplay Running
        openGate probe "lua/slow.bin"
        awaitLine' world "after "
        requestStop session StopQuit
      early ← linesWith "before " (seWorld env)
      late ← linesWith "after " (seWorld env)
      case (early, late) of
        ([first], [second]) → do
          let (firstStatus, firstDt) = Text.breakOn " dt=" first
              (secondStatus, secondDt) = Text.breakOn " dt=" second
          firstStatus `shouldBe` roleDump False "starting"
          secondStatus `shouldBe` roleDump True "running"
          secondDt `shouldBe` firstDt
        other → expectationFailure ("expected one showing before and one after the wait, found " <> show other)

  it "wakes nothing: an event-driven presentation instance with no scheduled hook is not run because the status changed, and its init and shutdown have their own captures" $
    withSetup (setup eventDriven) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      void . scenarioHolding env recorder [Dispatched g0] $ \session → do
        awaitPoint recorder (Dispatched g0)
        awaitPhase session Presentation Running
        releaseHold recorder (Dispatched g0)
        -- gameplay goes from starting to running: the presentation instance, which has no scheduled hook, is not run
        awaitPhase session Gameplay Running
        requestStop session StopQuit
        void (awaitRetired session)
      out ← outLines world
      out
        `shouldBe` [ "ui init " <> sessionDump False (roleDump False "starting") (roleDump False "starting")
                   , "init gameplay"
                   , "ui shutdown " <> sessionDump True (roleDump True "stopping") (roleDump True "stopping")
                   ]

  it "gives two instances of one VM captures of their own: editing one's result changes nothing another reads" $
    withSetup ((setup (roleScript twins)) {suShape = PresentationAlone, suHarness = noHarness {harnessSecond = [Presentation]}}) $ \env → do
      void . runScenario env $ \session → do
        awaitPhase session Presentation Running
        requestStop session StopQuit
      out ← outLines (seWorld env)
      out `shouldSatisfy` elem "second saw unedited true"
  where
    capturing =
      script'
        [ "if self.done then return end self.done = true"
        , "local a = api.session.status()"
        , "print('first ' .. dump(a))"
        , "print('held')"
        , "local b = api.session.status()"
        , "print('second ' .. dump(b))"
        , "a.stopping = true a.presentation.phase = 'edited' a.gameplay.extra = 1"
        , "print('third ' .. dump(api.session.status()))"
        ]
        ["print('shutdown ' .. dump(api.session.status()))"]
    resuming =
      script'
        [ "if self.done then return end self.done = true"
        , "if api.role ~= 'presentation' then return end"
        , "print('before ' .. dump(api.session.status().gameplay) .. ' dt=' .. tostring(dt))"
        , "local read = api.content.data('lua/slow.bin')"
        , "api.request.wait(read)"
        , "print('after ' .. dump(api.session.status().gameplay) .. ' dt=' .. tostring(dt))"
        ]
        []
    script' update shutdown = uiScript {scInit = ["if api.role == 'gameplay' then print('init gameplay') end"], scUpdate = update, scShutdown = shutdown}
    twins =
      uiScript
        { scPrelude = dumpPrelude <> ["local shared = {}"]
        , scInit =
            [ "local mine = api.session.status()"
            , "shared[#shared + 1] = dump(mine)"
            , "mine.stopping = true mine.presentation.phase = 'edited'"
            , "if #shared == 2 then print('second saw unedited ' .. tostring(shared[1] == dump(api.session.status()))) end"
            ]
        , scUpdate = []
        , scShutdown = []
        }
    eventDriven =
      luaMain
        [ "local function dump(v)"
        , "  if type(v) == 'string' then return '\"' .. v .. '\"' end"
        , "  if type(v) ~= 'table' then return tostring(v) end"
        , "  local keys = {}"
        , "  for k in pairs(v) do keys[#keys + 1] = k end"
        , "  table.sort(keys)"
        , "  local parts = {}"
        , "  for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. '=' .. dump(v[k]) end"
        , "  return '{' .. table.concat(parts, ',') .. '}'"
        , "end"
        , "return {"
        , "  gameplay = {every_ticks = 1, init = function(self, api) print('init gameplay') end, update = function() end},"
        , "  presentation = {"
        , "    init = function(self, api) print('ui init ' .. dump(api.session.status())) end,"
        , "    shutdown = function(self, reason) print('ui shutdown ' .. dump(self.api.session.status())) end,"
        , "  },"
        , "}"
        ]

-- Quit ---------------------------------------------------------------------------------------------------------------

quitting ∷ Spec
quitting = describe "api.session.quit()" $ do
  it "from the presentation role's init runs the statements after it, shows the segment's earlier capture, and keeps the logical role from ever taking a tick" $
    withSetup (setup (roleScript printScript {scPrelude = dumpPrelude, scInit = ["if api.role == 'presentation' then api.session.quit() print('after quit ' .. tostring(api.session.status().stopping)) end"]})) $ \env → do
      recorder ← newRecorder
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → void (awaitRetired session)
      out ← outLines (seWorld env)
      out `shouldSatisfy` elem "after quit false"
      points ← recorded recorder
      [tick | GrantIssued tick ← points] `shouldBe` []
      outVerdict outcome `shouldBe` VerdictSuccess
      outQuit outcome `shouldBe` True
      outRetired outcome `shouldBe` True

  it "from the logical role's init stops the whole session too, and a successful init cannot open the startup gate" $
    withSetup (setup (roleScript printScript {scInit = ["if api.role == 'gameplay' then api.session.quit() print('gameplay quit returned') end"], scUpdate = ["print('update ' .. api.role)"]})) $ \env → do
      recorder ← newRecorder
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → void (awaitRetired session)
      out ← outLines (seWorld env)
      out `shouldSatisfy` elem "gameplay quit returned"
      points ← recorded recorder
      [tick | GrantIssued tick ← points] `shouldBe` []
      outVerdict outcome `shouldBe` VerdictSuccess
      outQuit outcome `shouldBe` True

  it "from an update returns, lets the statements after it run, and no ordinary continuation resumes: catching an error cannot cancel the stop" $
    withSetup ((setup (roleScript quitUpdate)) {suShape = PresentationAlone}) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Presentation Running
        passTime world 1000000000 (elem "after quit" <$> outLines world)
        void (awaitRetired session)
      out ← outLines world
      out `shouldSatisfy` elem "quit results 0"
      out `shouldSatisfy` elem "after quit"
      out `shouldSatisfy` elem "caught"
      out `shouldSatisfy` notElem "never"
      outVerdict outcome `shouldBe` VerdictSuccess
      outQuit outcome `shouldBe` True
      outRetired outcome `shouldBe` True

  it "from the logical role's update stops it at the next boundary and the presentation role with it" $
    withSetup (setup (roleScript printScript {scUpdate = ["if api.role == 'gameplay' then api.session.quit() print('gameplay after quit') api.time.wait_ticks(1) print('gameplay never') end"]})) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitRegistration world 1000
        passTime world 1000000 (elem "gameplay after quit" <$> outLines world)
        void (awaitRetired session)
      out ← outLines world
      out `shouldSatisfy` notElem "gameplay never"
      outVerdict outcome `shouldBe` VerdictSuccess
      outQuit outcome `shouldBe` True

  it "may be repeated from both roles' shutdowns without reopening anything or running a shutdown twice" $
    withSetup (setup (roleScript printScript {scShutdown = ["api.session.quit() api.session.quit() print('shutdown ' .. api.role)"]})) $ \env → do
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        void (awaitRetired session)
      out ← outLines (seWorld env)
      length (filter (== "shutdown gameplay") out) `shouldBe` 1
      length (filter (== "shutdown presentation") out) `shouldBe` 1
      outVerdict outcome `shouldBe` VerdictSuccess
      outRetired outcome `shouldBe` True

  it "takes no slot with every place taken, closes new content work at once as an ordinary error and never as busy, keeps cancel and output usable, and does not claim a held provider's retirement" $
    withSetup (addFile ("lua/slow.bin", "slow") ((setup (roleScript filling)) {suShape = PresentationAlone})) $ \env → do
      let world = seWorld env
          probe = ssProbeOf env
      closeGate probe "lua/slow.bin"
      outcome ← runScenario env $ \session → do
        awaitPhase session Presentation Running
        passTime world 1000000000 (elem "after quit" . map (Text.takeWhile (/= '|')) <$> outLines world)
        -- quit returned without waiting for the held reads: the role is stopping and not retired
        status ← statusNow session
        fmap rolePhase (presentationOf status) `shouldBe` Just Stopping
        openGate probe "lua/slow.bin"
        void (awaitRetired session)
      out <- outLines world
      out `shouldSatisfy` any (Text.isPrefixOf "filled ")
      out `shouldSatisfy` elem "after quit|false|string"
      out `shouldSatisfy` any (`elem` ["cancel cancelled", "cancel already_settled"])
      err ← errLines world
      err `shouldSatisfy` any (Text.isSuffixOf "written after quit")
      outVerdict outcome `shouldBe` VerdictSuccess

  it "does not wait for the other role's owner: a logical init parked in its output does not delay the call's return, and the role is not retired until it has" $
    withSetup (setup (roleScript printScript {scInit = ["if api.role == 'presentation' then api.session.quit() print('quit returned') end"]})) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      outcome ← scenarioHolding env recorder [Dispatched g0] $ \session → do
        awaitPoint recorder (Dispatched g0)
        awaitLine world "quit returned"
        status ← statusNow session
        statusStopping status `shouldBe` True
        fmap rolePhase (gameplayOf status) `shouldNotBe` Just Retired
        releaseHold recorder (Dispatched g0)
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictSuccess
      outRetired outcome `shouldBe` True

  it "followed by an uncaught error makes the outcome a failure, and the error is the update's own" $
    withSetup ((setup (roleScript printScript {scUpdate = ["api.session.quit() error('after quit')"]})) {suShape = PresentationAlone}) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Presentation Running
        passTime world 1000000000 (statusStopping <$> statusNow session)
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      outQuit outcome `shouldBe` True
      outRetired outcome `shouldBe` True
      map rfCode (outFailures outcome) `shouldBe` [LuaError]
  where
    quitUpdate =
      printScript
        { scInit = []
        , scUpdate =
            [ "print('quit results ' .. select('#', api.session.quit()))"
            , "print('after quit')"
            , "pcall(function() error('caught') end)"
            , "print('caught')"
            , "api.time.wait_seconds(1)"
            , "print('never')"
            ]
        , scShutdown = []
        }
    filling =
      printScript
        { scInit = []
        , scShutdown = []
        , scUpdate =
            [ "self.reqs = {}"
            , "for i = 1, 40 do"
            , "  local r = api.content.data('lua/slow.bin')"
            , "  if r == nil then break end"
            , "  self.reqs[#self.reqs + 1] = r"
            , "end"
            , "print('filled ' .. #self.reqs)"
            , "api.session.quit()"
            , "local again, refusal = pcall(api.content.data, 'lua/slow.bin')"
            , "print('after quit|' .. tostring(again) .. '|' .. type(refusal))"
            , "print('cancel ' .. api.request.cancel(self.reqs[1]))"
            , "warn('written after quit')"
            ]
        }

-- The unavailable-state guard ---------------------------------------------------------------------------------------

guardInSessions ∷ Spec
guardInSessions = describe "state(...) in a session" $ do
  it "from a module's top level, caught, in both VMs: whole-session failure and no init, with no instance invented and one diagnostic" $
    withSetup (setup moduleCaller) $ \env → do
      outcome ← runScenario env $ \session → void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      outRetired outcome `shouldBe` True
      case outTerminal outcome of
        Nothing → expectationFailure "no terminal failure was latched"
        Just found → do
          rfCode found `shouldBe` StateUnavailable
          rfStage found `shouldBe` OnModule
          rfMessage found `shouldBe` phrase
          rfInstance found `shouldBe` Nothing
          rfContent found `shouldBe` Just "modules-test"
          rfTraceback found `shouldBe` Nothing
      out ← outLines (seWorld env)
      filter (Text.isPrefixOf "init ") out `shouldBe` []
      errLines (seWorld env) `shouldReturn` [phrase]

  it "from an update, caught, ends the whole session after the segment that called it returns: no further update, no gateway for the logical role, one diagnostic, attributed to the presentation instance" $
    withSetup (setup (roleScript printScript {scUpdate = ["if api.role == 'presentation' then pcall(state, 1) print('after catch') else print('update gameplay') end"]})) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Presentation Running
        passTime world 1000000000 (elem "after catch" <$> outLines world)
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      case outTerminal outcome of
        Just found → do
          rfCode found `shouldBe` StateUnavailable
          rfStage found `shouldBe` OnUpdate
          rfRole found `shouldBe` Presentation
          rfContent found `shouldBe` Just "modules-test"
          fmap (Text.isPrefixOf "inst-") (rfInstance found) `shouldBe` Just True
        Nothing → expectationFailure "no terminal failure was latched"
      errLines world `shouldReturn` [phrase]

  it "from both VMs' inits at once claims one diagnostic, makes the failure the whole session's and no role's, and starts nothing" $
    withSetup (setup (roleScript printScript {scInit = ["pcall(state, api.role)", "print('init returned ' .. api.role)"], scUpdate = ["print('update ' .. api.role)"]})) $ \env → do
      outcome ← runScenario env $ \session → void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      outFailures outcome `shouldBe` []
      fmap rfCode (outTerminal outcome) `shouldBe` Just StateUnavailable
      fmap rfStage (outTerminal outcome) `shouldBe` Just OnInit
      outcomeMessages outcome `shouldSatisfy` elem phrase
      out ← outLines (seWorld env)
      out `shouldSatisfy` notElem "update gameplay 1"
      errLines (seWorld env) `shouldReturn` [phrase]

  it "from a shutdown after a quit, and from an update after a quit, makes the outcome a failure however the session was ended" $ do
    withSetup (setup (roleScript printScript {scShutdown = ["pcall(state)"]})) $ \env → do
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      outQuit outcome `shouldBe` True
      fmap rfStage (outTerminal outcome) `shouldBe` Just OnShutdown
      errLines (seWorld env) `shouldReturn` [phrase]
    withSetup ((setup (roleScript printScript {scUpdate = ["api.session.quit() pcall(state) print('after both')"]})) {suShape = PresentationAlone}) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Presentation Running
        passTime world 1000000000 (elem "after both" <$> outLines world)
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      outQuit outcome `shouldBe` True
      fmap rfStage (outTerminal outcome) `shouldBe` Just OnUpdate

  it "cannot erase an earlier failure: the logical role's first failure stays the primary and the role's, the guard is the session's" $
    withSetup (setup (roleScript printScript {scUpdate = ["if api.role == 'gameplay' then error('first failure') else print('ui update') if self.n then pcall(state) end self.n = true end"]})) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitRegistration world 1000
        nudge world 1000000
        void (awaitStatus session (maybe False roleFailed . gameplayOf))
        passTime world 1000000000 (elem "ui update" <$> outLines world)
        passTime world 1000000000 ((>= 2) . length . filter (== "ui update") <$> outLines world)
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      map rfCode (outFailures outcome) `shouldBe` [LuaError]
      fmap rfRole (listToMaybe (outFailures outcome)) `shouldBe` Just Gameplay
      fmap rfCode (outTerminal outcome) `shouldBe` Just StateUnavailable
      take 1 (outcomeMessages outcome) `shouldSatisfy` all (Text.isInfixOf "first failure")
      outcomeMessages outcome `shouldSatisfy` elem phrase

  it "is not hidden by a script that rebinds print and warn, and reports through the session's own stderr sink" $
    withSetup ((setup (roleScript printScript {scInit = ["print = nil", "warn = function() end", "pcall(state)"]})) {suShape = PresentationAlone}) $ \env → do
      outcome ← runScenario env $ \session → void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      errLines (seWorld env) `shouldReturn` [phrase]

  it "latches before the diagnostic is written: with the write held in the sink the failure and the stop are already the session's, and a cancelled caller loses neither" $
    withSetup ((setup (roleScript printScript {scInit = ["pcall(state)"]})) {suShape = PresentationAlone}) $ \env → do
      let world = seWorld env
      holdSink world phrase
      (ended, session) ← runCaught env noHarness $ \driver live → (`finally` releaseSink world) $ do
        awaitSinkEntered world phrase
        held ← outcomeNow live
        fmap rfCode (outTerminal held) `shouldBe` Just StateUnavailable
        status ← statusNow live
        statusStopping status `shouldBe` True
        -- the caller is cancelled while the diagnostic is held in the sink: the latch and the stop belong to the session
        -- and not to the call that wrote, so neither depends on the write finishing. A running segment is not
        -- preempted, so the owner retires once the write returns.
        throwTo driver ThreadKilled
        releaseSink world
        void (awaitRetired live)
      raisedKilled ended `shouldBe` True
      final ← outcomeNow session
      outVerdict final `shouldBe` VerdictFailure
      fmap rfCode (outTerminal final) `shouldBe` Just StateUnavailable

  it "keeps the latch and the primary evidence when the write fails, writes it once and does not retry, and ends the owner as a failure of the host" $ do
    _ ←
      fatalSetup ((setup (roleScript printScript {scInit = ["pcall(state)", "pcall(state)"]})) {suShape = PresentationAlone}) $ \env → do
        let world = seWorld env
        failSinkOn world phrase
        outcome ← runScenario env $ \session → void (awaitRetired session)
        outVerdict outcome `shouldBe` VerdictFailure
        fmap rfCode (outTerminal outcome) `shouldBe` Just StateUnavailable
        -- the guard's failure came first, so it is the primary; the failed sink is a failure of the host beside it
        fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just StateUnavailable
        readTVarIO (wSinkEntered world) `shouldReturn` [phrase]
    pure ()
  where
    moduleCaller =
      roleScript
        printScript
          { scPrelude = ["pcall(state, {})"]
          , scInit = [rolePrint "init"]
          , scUpdate = []
          , scShutdown = []
          }
