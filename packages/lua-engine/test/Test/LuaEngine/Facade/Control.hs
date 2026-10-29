{-# LANGUAGE OverloadedStrings #-}

-- | The session-control bindings of a facade (LFE-26) over injected endpoints: @api.session.status()@,
-- @api.session.quit()@ and the unavailable-state guard @state(...)@ / @api.state(...)@, on real Lua in real
-- instances of real facades. The session's answers are the world's controlled endpoints (a status an example
-- sets, a counter of the quits, a log of the terminal latches), so what a binding asked of the coordinator is
-- exact; the real coordinator's answers are the examples of "Test.LuaEngine.Session.Api".
--
-- What a case prints is what it saw. Nothing sleeps: a segment is held where an example means it to be with
-- the output's sink and released when the example has acted.
module Test.LuaEngine.Facade.Control (spec) where

import Control.Concurrent.STM (readTVarIO)
import Control.Exception (finally)
import Control.Monad (void)
import Data.Foldable (for_)
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Test.Hspec
import Test.LuaEngine.Facade.Support

-- | The phrase the guard reports and raises.
phrase ∷ Text
phrase = "state service not available in this milestone"

running ∷ RoleSample
running = RoleSample True "running" Nothing

-- | The accepted example of a session with both roles running.
bothRunning ∷ StatusSample
bothRunning = StatusSample False (Just running) (Just running)

-- | Run an example over a world whose session answers this status, with one instance of this role serving the
-- script. The status is set before the instance is admitted, so the capture at its @init@'s entry is that.
withSampled ∷ StatusSample → Role → Script → [(FilePath, ByteString)] → (World → RuntimeControl → Fvm → Spawned → IO a) → IO a
withSampled sample role found more body =
  withWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource found) : more)) $ \world control runtime →
    withFvm world runtime (if role == Gameplay then gameplayShape else presentationShape) $ \fvm → do
      setStatus world sample
      spawned ← spawn world fvm "modules-test" mainPath
      body world control fvm spawned

-- | What @api.session.status()@ showed in a presentation @init@ over this status.
shownFor ∷ StatusSample → IO Text
shownFor sample =
  withSampled sample Presentation script {scPrelude = dumpPrelude, scInit = ["print('status ' .. dump(api.session.status()))"]} [] $ \world _ _ _ → do
    out ← outLines world
    case out of
      [line] | Just rest ← Text.stripPrefix "status " line → pure rest
      _ → expectationFailure ("expected one status line, found " <> show out) >> pure ""

-- | A failure with its four required fields and nothing else known.
bare ∷ FailureSample
bare = FailureSample "lua_error" "boom" "gameplay" "update" Nothing Nothing Nothing Nothing

spec ∷ Spec
spec = describe "the session controls (LFE-26)" $ do
  surface
  statusRecord
  capture
  refusals
  quitting
  guardCalls
  guardArguments
  guardFailures

-- The surface -------------------------------------------------------------------------------------------------------

surface ∷ Spec
surface = describe "the surface" $
  it "adds exactly api.session.status and quit, api.state and the global state: no helper namespace, no global quit or status" $
    withSampled bothRunning Presentation script {scInit = probe} [] $ \world _ _ _ →
      outLines world
        >>= ( `shouldBe`
                [ "api content,content_id,instance_id,request,role,session,state,time"
                , "session quit,status"
                , "state function true"
                , "helpers true true true"
                , "aliases true"
                ]
            )
  where
    probe =
      [ "local function keys(t) local k = {} for name in pairs(t) do k[#k + 1] = name end table.sort(k) return table.concat(k, ',') end"
      , "print('api ' .. keys(api))"
      , "print('session ' .. keys(api.session))"
      , "print('state ' .. type(state) .. ' ' .. tostring(rawequal(state, api.state)))"
      , "print('helpers ' .. tostring(hetoimasia_engine == nil) .. ' ' .. tostring(hetoimasia_engine_builder == nil) .. ' ' .. tostring(session_status == nil and session_quit == nil and state_unavailable == nil and terminal == nil and unavailable == nil and E == nil))"
      , "print('aliases ' .. tostring(quit == nil and status == nil and session == nil))"
      ]

-- The status record ------------------------------------------------------------------------------------------------

statusRecord ∷ Spec
statusRecord = describe "api.session.status()" $ do
  it "shows exactly the accepted example for a session with both roles running" $
    shownFor bothRunning
      `shouldReturn` "{gameplay={failed=false,initialized=true,phase=\"running\",present=true},presentation={failed=false,initialized=true,phase=\"running\",present=true},stopping=false}"
  it "shows an absent role as exactly {present=false}, here the gameplay role of a session with only the presentation role" $
    shownFor (StatusSample False Nothing (Just running))
      `shouldReturn` "{gameplay={present=false},presentation={failed=false,initialized=true,phase=\"running\",present=true},stopping=false}"
  it "shows every phase, the historical initialized fact and the whole-session stopping flag as the coordinator has them" $ do
    shownFor (StatusSample False (Just (RoleSample False "starting" Nothing)) (Just running))
      `shouldReturn` "{gameplay={failed=false,initialized=false,phase=\"starting\",present=true},presentation={failed=false,initialized=true,phase=\"running\",present=true},stopping=false}"
    shownFor (StatusSample False (Just (RoleSample True "ready" Nothing)) (Just (RoleSample False "starting" Nothing)))
      `shouldReturn` "{gameplay={failed=false,initialized=true,phase=\"ready\",present=true},presentation={failed=false,initialized=false,phase=\"starting\",present=true},stopping=false}"
    shownFor (StatusSample True (Just (RoleSample True "stopping" Nothing)) (Just (RoleSample True "stopping" Nothing)))
      `shouldReturn` "{gameplay={failed=false,initialized=true,phase=\"stopping\",present=true},presentation={failed=false,initialized=true,phase=\"stopping\",present=true},stopping=true}"
    -- retirement does not undo that an init once succeeded
    shownFor (StatusSample True (Just (RoleSample True "retired" Nothing)) (Just (RoleSample True "retired" Nothing)))
      `shouldReturn` "{gameplay={failed=false,initialized=true,phase=\"retired\",present=true},presentation={failed=false,initialized=true,phase=\"retired\",present=true},stopping=true}"
  it "shows an ordinary logical failure with its required fields alone, and the session not stopping" $
    shownFor (StatusSample False (Just (RoleSample True "stopping" (Just bare))) (Just running))
      `shouldReturn` "{gameplay={failed=true,failure={code=\"lua_error\",message=\"boom\",role=\"gameplay\",stage=\"update\"},initialized=true,phase=\"stopping\",present=true},presentation={failed=false,initialized=true,phase=\"running\",present=true},stopping=false}"
  it "shows every known optional field of a failure and omits each unknown one, the same failure after the role has retired" $ do
    let full = bare {sfContentId = Just "modules-test", sfInstanceId = Just "inst-1", sfPath = Just "lua/main.lua", sfTraceback = Just "stack traceback:\\n\\t[C]: in ?"}
        withSome = bare {sfInstanceId = Just "inst-1", sfTraceback = Just "tb"}
        expectedFull = "failure={code=\"lua_error\",content_id=\"modules-test\",instance_id=\"inst-1\",message=\"boom\",path=\"lua/main.lua\",role=\"gameplay\",stage=\"update\",traceback=\"stack traceback:\\n\\t[C]: in ?\"}"
    for_ ["stopping", "retired"] $ \phase →
      shownFor (StatusSample False (Just (RoleSample True phase (Just full))) Nothing)
        `shouldReturn` ("{gameplay={failed=true," <> expectedFull <> ",initialized=true,phase=\"" <> phase <> "\",present=true},presentation={present=false},stopping=false}")
    shownFor (StatusSample False (Just (RoleSample True "retired" (Just withSome))) Nothing)
      `shouldReturn` "{gameplay={failed=true,failure={code=\"lua_error\",instance_id=\"inst-1\",message=\"boom\",role=\"gameplay\",stage=\"update\",traceback=\"tb\"},initialized=true,phase=\"retired\",present=true},presentation={present=false},stopping=false}"
  it "shows a failed presentation role and a failure that never had an instance, naming no instance it did not have" $
    shownFor (StatusSample True Nothing (Just (RoleSample False "stopping" (Just (FailureSample "module_error" "no" "presentation" "module" (Just "modules-test") Nothing (Just "lua/main.lua") Nothing)))))
      `shouldReturn` "{gameplay={present=false},presentation={failed=true,failure={code=\"module_error\",content_id=\"modules-test\",message=\"no\",path=\"lua/main.lua\",role=\"presentation\",stage=\"module\"},initialized=false,phase=\"stopping\",present=true},stopping=true}"

-- Capture ----------------------------------------------------------------------------------------------------------

capture ∷ Spec
capture = describe "the capture of a segment" $ do
  it "is taken at the entry of the hook and not when the script reads: a change after the entry is not seen by any read of that segment, and the next hook sees it" $
    withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource twice)]) $ \world _ runtime →
      withFvm world runtime presentationShape $ \fvm → do
        setStatus world bothRunning
        holdSink world "first read done"
        spawned ← admitOnly world fvm "modules-test" mainPath
        -- (however the example ends, the sink is let go, so a failed assertion unwinds instead of waiting on the hold)
        (`finally` releaseSink world) $ do
          awaitSinkEntered world "first read done"
          -- the coordinator moves on while the init is parked in its output: the later reads still describe the entry
          setStatus world (StatusSample True (Just (RoleSample True "stopping" Nothing)) (Just (RoleSample True "stopping" Nothing)))
        releaseSink world
        awaitActive spawned
        let stoppedDump = "{gameplay={failed=false,initialized=true,phase=\"stopping\",present=true},presentation={failed=false,initialized=true,phase=\"stopping\",present=true},stopping=true}"
            runningDump = "{gameplay={failed=false,initialized=true,phase=\"running\",present=true},presentation={failed=false,initialized=true,phase=\"running\",present=true},stopping=false}"
        outLines world >>= (`shouldBe` ["first " <> runningDump, "first read done", "second " <> runningDump, "same true"])
        -- the shutdown is a hook of its own and has its own capture, of the status as it is when it begins
        stopSpawned spawned
        void (settledOf spawned)
        outLines world >>= (`shouldBe` ["first " <> runningDump, "first read done", "second " <> runningDump, "same true", "shutdown " <> stoppedDump])
  it "hands every read its own copy: editing a returned table, nested ones included, changes no later read" $
    withSampled (StatusSample False (Just (RoleSample True "stopping" (Just bare))) (Just running)) Presentation edits [] $ \world _ _ _ →
      outLines world >>= (`shouldBe` ["mutated true", "again unchanged true", "failure unchanged true"])
  it "is never captured for the gameplay VM: its call is an ordinary error" $
    withSampled bothRunning Gameplay script {scInit = ["try('gameplay status', api.session.status)"]} [] $ \world _ _ _ → do
      out ← outLines world
      out `shouldSatisfy` all (Text.isInfixOf "status is available to the presentation role only")
      length out `shouldBe` 1
  where
    twice =
      script
        { scPrelude = dumpPrelude
        , scInit =
            [ "local first = api.session.status()"
            , "print('first ' .. dump(first))"
            , "print('first read done')"
            , "local second = api.session.status()"
            , "print('second ' .. dump(second))"
            , "print('same ' .. tostring(dump(first) == dump(second)))"
            ]
        , scShutdown = ["print('shutdown ' .. dump(api.session.status()))"]
        }
    edits =
      script
        { scPrelude = dumpPrelude
        , scInit =
            [ "local before = dump(api.session.status())"
            , "local s = api.session.status()"
            , "s.stopping = true"
            , "s.gameplay.phase = 'edited'"
            , "s.gameplay.failure.message = 'edited'"
            , "s.gameplay.failure.extra = 1"
            , "s.presentation = nil"
            , "print('mutated ' .. tostring(dump(s) ~= before))"
            , "print('again unchanged ' .. tostring(dump(api.session.status()) == before))"
            , "print('failure unchanged ' .. tostring(api.session.status().gameplay.failure.message == 'boom'))"
            ]
        }

-- Refusals ---------------------------------------------------------------------------------------------------------

-- | What a case must come to: an ordinary error holding each reason, or an acceptance.
data Verdict = Refused [Text] | Accepted

data Case = Case Text Text Verdict

caseLua ∷ Case → Text
caseLua (Case label expression _) = "try(" <> Text.pack (show (Text.unpack label)) <> ", function() return " <> expression <> " end)"

checkCases ∷ [Case] → [Text] → Expectation
checkCases cases printed = mapM_ check cases
  where
    check (Case label _ verdict) = case [Text.drop (Text.length prefix) line | line ← printed, prefix `Text.isPrefixOf` line] of
      [seen] → verify label seen verdict
      other → expectationFailure ("the case " <> show label <> " printed " <> show (length other) <> " lines; printed: " <> show printed)
      where
        prefix = label <> " => "
    verify label seen = \case
      Accepted
        | "true" `Text.isPrefixOf` seen → pure ()
        | otherwise → expectationFailure (show label <> " must be accepted, but: " <> Text.unpack seen)
      Refused reasons
        | "false ; " `Text.isPrefixOf` seen && all (`Text.isInfixOf` seen) reasons → pure ()
        | otherwise → expectationFailure (show label <> " must be refused with " <> show reasons <> ", but: " <> Text.unpack seen)

refusals ∷ Spec
refusals = describe "a misuse" $ do
  it "is an ordinary Lua error before the coordinator is observed or a stop is requested, and leaves the session as healthy as it was" $
    withSampled bothRunning Presentation script {scInit = map caseLua misuses <> ["print('still serving ' .. api.role)"]} [] $ \world _ _ _ → do
      out ← outLines world
      checkCases misuses out
      out `shouldSatisfy` elem "still serving presentation"
      quitsSeen world `shouldReturn` 0
      terminalsSeen world `shouldReturn` []
  it "refuses status to the gameplay role and lets either role quit, in every hook" $ do
    withSampled bothRunning Gameplay script {scInit = [caseLua refusedStatus]} [] $ \world _ _ _ → do
      outLines world >>= checkCases [refusedStatus]
      quitsSeen world `shouldReturn` 0
  it "takes nothing from metadata a script overwrites: a gameplay instance that edits its own role, api or self is still refused status, and the facade its hooks captured still quits" $
    withSampled bothRunning Gameplay script {scInit = ["api.role = 'presentation'", "self.api = nil", "try('edited status', function() return api.session.status() end)", "api.session.quit()"]} [] $ \world _ _ _ → do
      outLines world >>= checkCases [Case "edited status" "" (Refused ["status is available to the presentation role only"])]
      quitsSeen world `shouldReturn` 1
  it "refuses another instance's captured facade and a module's top level, for status and quit alike, before the coordinator is asked" $
    withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource twins), ("lua/share.lua", luaMain ["return {apis = {}}"]), ("lua/late.lua", luaMain (tryPrelude <> late))]) $ \world _ runtime →
      withFvm world runtime presentationShape $ \fvm → do
        setStatus world bothRunning
        _ ← spawn world fvm "modules-test" mainPath
        _ ← spawn world fvm "modules-test" mainPath
        -- the second instance's init tries the first one's facade and asks for a module that tries it again
        out ← awaitOut world 4
        checkCases
          [ Case "foreign status" "" (Refused ["this facade belongs to another instance"])
          , Case "foreign quit" "" (Refused ["this facade belongs to another instance"])
          , Case "late status" "" (Refused ["services are not available while a module is evaluated"])
          , Case "late quit" "" (Refused ["services are not available while a module is evaluated"])
          ]
          out
        quitsSeen world `shouldReturn` 0
        terminalsSeen world `shouldReturn` []
  where
    twins =
      script
        { scPrelude = ["local share = import('lua/share.lua')"]
        , scInit =
            [ "share.apis[#share.apis + 1] = api"
            , "if #share.apis == 2 then"
            , "  try('foreign status', share.apis[1].session.status)"
            , "  try('foreign quit', share.apis[1].session.quit)"
            , "  api.content.module('lua/late.lua')"
            , "end"
            ]
        }
    late =
      [ "local share = import('lua/share.lua')"
      , "try('late status', share.apis[1].session.status)"
      , "try('late quit', share.apis[1].session.quit)"
      , "return {}"
      ]
    refusedStatus = Case "status init" "api.session.status()" (Refused ["status is available to the presentation role only"])
    misuses =
      [ Case "status explicit nil" "api.session.status(nil)" (Refused ["expected 0 values, found 1"])
      , Case "status extra" "api.session.status(1)" (Refused ["expected 0 values, found 1"])
      , Case "status colon" "api.session:status()" (Refused ["expected 0 values, found 1"])
      , Case "status self" "api.session.status(api.session)" (Refused ["expected 0 values, found 1"])
      , Case "quit explicit nil" "api.session.quit(nil)" (Refused ["expected 0 values, found 1"])
      , Case "quit extra" "api.session.quit(true)" (Refused ["expected 0 values, found 1"])
      , Case "quit colon" "api.session:quit()" (Refused ["expected 0 values, found 1"])
      , Case "quit with a reason" "api.session.quit('now', 1)" (Refused ["expected 0 values, found 2"])
      , Case "no global quit" "quit()" (Refused ["attempt to call a nil value"])
      , Case "no global status" "status()" (Refused ["attempt to call a nil value"])
      ]

-- Quit -------------------------------------------------------------------------------------------------------------

quitting ∷ Spec
quitting = describe "api.session.quit()" $ do
  it "asks the coordinator for a normal stop from either role's init, update and shutdown, returns no value, and may be repeated" $ do
    withSampled bothRunning Gameplay script {scInit = [call "init"], scUpdate = [call "update"], scShutdown = [call "shutdown"]} [] $ \world control fvm spawned → do
      quitsSeen world `shouldReturn` 2
      tickBy control fvm 1
      quitsSeen world `shouldReturn` 4
      stopSpawned spawned
      void (settledOf spawned)
      quitsSeen world `shouldReturn` 6
      outLines world >>= (`shouldBe` ["init 0", "update 0", "shutdown 0"])
    withSampled bothRunning Presentation script {scInit = [call "init"], scShutdown = [call "shutdown"]} [] $ \world _ _ spawned → do
      quitsSeen world `shouldReturn` 2
      stopSpawned spawned
      void (settledOf spawned)
      quitsSeen world `shouldReturn` 4
      terminalsSeen world `shouldReturn` []
  it "runs the statements after it, and a status read after it is the segment's capture" $
    withSampled bothRunning Presentation script {scPrelude = dumpPrelude, scInit = ["api.session.quit()", "print('after quit ' .. dump(api.session.status().stopping))"]} [] $ \world _ _ _ → do
      outLines world >>= (`shouldBe` ["after quit false"])
      quitsSeen world `shouldReturn` 1
  where
    call hook = "print('" <> hook <> " ' .. select('#', api.session.quit())) api.session.quit()"

-- The unavailable-state guard -------------------------------------------------------------------------------------

-- | A script that calls the guard from each place with both spellings, caught, and prints what it saw.
guardScript ∷ Script
guardScript =
  script
    { scInit = [probe "init"]
    , scUpdate = [probe "update"]
    , scShutdown = [probe "shutdown"]
    }
  where
    probe hook = "try('" <> hook <> " global', state, 1) try('" <> hook <> " api', api.state, 2)"

guardCalls ∷ Spec
guardCalls = describe "state(...) and api.state(...)" $ do
  it "latch the terminal failure first from every hook of both roles, attributed to the executing role, stage, content and instance, raise the one fixed error whichever spelling, and report once" $ do
    withSampled bothRunning Gameplay guardScript [] $ \world control fvm spawned → do
      tickBy control fvm 1
      stopSpawned spawned
      void (settledOf spawned)
      let who = Just (spId spawned)
      terminalsSeen world
        >>= (`shouldBe` concat [[TerminalContext Gameplay stage (Just "modules-test") who, TerminalContext Gameplay stage (Just "modules-test") who] | stage ← [TerminalInit, TerminalUpdate, TerminalShutdown]])
      out ← outLines world
      out `shouldBe` [hook <> " " <> spelling <> " => false ; " <> phrase | hook ← ["init", "update", "shutdown"], spelling ← ["global", "api"]]
      -- one diagnostic is claimed across all six calls, and it is exactly the phrase
      errLines world >>= (`shouldBe` [phrase])
    withSampled bothRunning Presentation guardScript [] $ \world _ _ spawned → do
      stopSpawned spawned
      void (settledOf spawned)
      let who = Just (spId spawned)
      terminalsSeen world
        >>= (`shouldBe` concat [[TerminalContext Presentation stage (Just "modules-test") who, TerminalContext Presentation stage (Just "modules-test") who] | stage ← [TerminalInit, TerminalShutdown]])
      errLines world >>= (`shouldBe` [phrase])
  it "are reachable from an authored module's top level before any hook, with no instance invented, and from a module a hook has evaluated" $
    withWorld fixedM1Profile (Layout [("lua/main.lua", luaMain (tryPrelude <> topLevel)), ("lua/late.lua", luaMain (tryPrelude <> lateLevel))]) $ \world _ runtime →
      withFvm world runtime presentationShape $ \fvm → do
        spawned ← spawn world fvm "modules-test" mainPath
        awaitActive spawned
        -- the module the init asked for arrives on its own: wait for what it prints
        void (awaitOut world 3)
        terminalsSeen world >>= (`shouldBe` [TerminalContext Presentation TerminalModule (Just "modules-test") Nothing, TerminalContext Presentation TerminalModule (Just "modules-test") Nothing])
        outLines world >>= (`shouldBe` ["top state => false ; " <> phrase, "top is a function true", "late state => false ; " <> phrase])
        errLines world >>= (`shouldBe` [phrase])
  it "take precedence over every role, phase and arity rule, also through a facade another instance or a module kept and after a quit" $
    withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource twins), ("lua/share.lua", luaMain ["return {apis = {}}"]), ("lua/late.lua", luaMain (tryPrelude <> lateKept))]) $ \world control runtime →
      withFvm world runtime gameplayShape $ \fvm → do
        first ← spawn world fvm "modules-test" mainPath
        second ← spawn world fvm "modules-test" mainPath
        -- the late module is requested by the second and evaluated at the tick it is delivered at
        tickBy control fvm 2
        out ← outLines world
        -- the second instance called the first one's facade: the guard is attributed to the instance that executed it
        terminalsSeen world
          >>= (`shouldBe` [ TerminalContext Gameplay TerminalInit (Just "modules-test") (Just (spId first))
                          , TerminalContext Gameplay TerminalInit (Just "modules-test") (Just (spId second))
                          , TerminalContext Gameplay TerminalInit (Just "modules-test") (Just (spId second))
                          , TerminalContext Gameplay TerminalModule (Just "modules-test") Nothing
                          ]
                      )
        out `shouldSatisfy` elem ("kept by the first, called by the second => false ; " <> phrase)
        out `shouldSatisfy` elem ("kept, from a module top level => false ; " <> phrase)
        out `shouldSatisfy` elem ("after quit => false ; " <> phrase)
        quitsSeen world `shouldReturn` 1
  where
    topLevel =
      [ "try('top state', state, {})"
      , "print('top is a function ' .. tostring(type(state) == 'function'))"
      , "return {presentation = {init = function(self, api) api.content.module('lua/late.lua') end}, gameplay = {every_ticks = 1, init = function() end, update = function() end}}"
      ]
    lateLevel =
      [ "try('late state', state)"
      , "return {}"
      ]
    twins =
      script
        { scPrelude = ["local share = import('lua/share.lua')"]
        , scInit =
            [ "share.apis[#share.apis + 1] = api"
            , "if #share.apis == 1 then try('the first', api.state) end"
            , "if #share.apis == 2 then"
            , "  try('kept by the first, called by the second', share.apis[1].state)"
            , "  api.session.quit()"
            , "  try('after quit', state)"
            , "  api.content.module('lua/late.lua')"
            , "end"
            ]
        }
    lateKept =
      [ "local share = import('lua/share.lua')"
      , "try('kept, from a module top level', share.apis[1].state)"
      , "return {}"
      ]

guardArguments ∷ Spec
guardArguments = describe "the unavailable-state guard's arguments" $ do
  it "are never inspected, stringified or traversed, and no metamethod of theirs runs, for any spelling or call style" $
    withSampled bothRunning Presentation touching [] $ \world _ _ _ → do
      outLines world >>= (`shouldBe` ["touched none", "calls 8"])
      length <$> terminalsSeen world `shouldReturn` 8
  it "are not needed: the call takes none, and a call with many is the same terminal call" $
    withSampled bothRunning Presentation script {scInit = ["try('none', state)", "try('many', state, 1, 2, 3, nil, nil, 'x', {}, print)"]} [] $ \world _ _ _ →
      outLines world >>= (`shouldBe` ["none => false ; " <> phrase, "many => false ; " <> phrase])
  where
    touching =
      script
        { scInit =
            [ "local touched = {}"
            , "local function note(name) return function() touched[#touched + 1] = name return 'x' end end"
            , "local meta = {"
            , "  __index = note('index'), __newindex = note('newindex'), __call = note('call'), __tostring = note('tostring'),"
            , "  __len = note('len'), __eq = note('eq'), __lt = note('lt'), __le = note('le'), __concat = note('concat'),"
            , "  __pairs = note('pairs'), __close = note('close'), __unm = note('unm'), __name = 'trap',"
            , "}"
            , "local cyclic = setmetatable({}, meta)"
            , "rawset(cyclic, 'self', cyclic)"
            , "pcall(state, cyclic)"
            , "pcall(state, cyclic, cyclic, nil)"
            , "pcall(api.state, cyclic)"
            , "pcall(function() return api:state(cyclic) end)"
            , "pcall(function() return state(cyclic, setmetatable({}, meta)) end)"
            , "pcall(state, setmetatable({}, {__metatable = false}))"
            , "pcall(state, string.rep('x', 100000))"
            , "pcall(state, coroutine.create(function() end), print)"
            , "print('touched ' .. (#touched == 0 and 'none' or table.concat(touched, ',')))"
            , "print('calls 8')"
            ]
        }

guardFailures ∷ Spec
guardFailures = describe "the guard's latch and its diagnostic" $ do
  it "survive a script that rebinds print, warn or its globals and a caught error: the retained closure still latches and reports" $
    withSampled bothRunning Presentation script {scInit = ["local kept = api.state", "print = nil", "warn = nil", "state = nil", "pcall(kept)", "pcall(kept)"]} [] $ \world _ _ _ → do
      terminalsSeen world >>= (\latched → length latched `shouldBe` 2)
      errLines world >>= (`shouldBe` [phrase])
  it "latch before the diagnostic is written: a sink that fails ends the owner as a failure of the host, the latch is already asked for, and nothing is retried" $ do
    seen ← newIORef ([] ∷ [TerminalContext], [] ∷ [Text])
    (_, raised) ←
      fatalWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource script {scInit = ["local ok = pcall(state, 1)", "print('after ' .. tostring(ok))", "pcall(state, 2)"]})]) $ \world control runtime → do
        failSinkOn world phrase
        withFvm world runtime presentationShape $ \fvm → do
          _ ← admitOnly world fvm "modules-test" mainPath
          void (awaitEnded control fvm) `finally` (((,) <$> terminalsSeen world <*> readTVarIO (wSinkEntered world)) >>= writeIORef seen)
    (latched, handed) ← readIORef seen
    -- the terminal latch was asked for, once, before the sink was handed the line; the sink was handed it once; no retry
    latched `shouldBe` [TerminalContext Presentation TerminalInit (Just "modules-test") (Just "inst-1")]
    handed `shouldBe` [phrase]
    Text.pack (show raised) `shouldSatisfy` Text.isInfixOf "OutputFailure"
  it "write nothing when the latch itself cannot be made: the failure is the host's and ends the owner whatever the script did with the stand-in error, and no diagnostic is claimed" $ do
    seen ← newIORef ([] ∷ [TerminalContext], [] ∷ [Text], [] ∷ [Text])
    (_, raised) ←
      fatalWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource script {scInit = ["local ok = pcall(state, 1)", "print('after ' .. tostring(ok))"]})]) $ \world control runtime → do
        failTerminals world
        withFvm world runtime presentationShape $ \fvm → do
          _ ← admitOnly world fvm "modules-test" mainPath
          void (awaitEnded control fvm) `finally` (((,,) <$> terminalsSeen world <*> readTVarIO (wSinkEntered world) <*> outLines world) >>= writeIORef seen)
    (latched, handed, printed) ← readIORef seen
    length latched `shouldBe` 1
    -- no sink was handed the diagnostic: the only line it was handed is the script's own
    handed `shouldBe` ["after false"]
    -- the script caught the stand-in error and went on; the failure was the host's all the same
    printed `shouldBe` ["after false"]
    Text.pack (show raised) `shouldSatisfy` Text.isInfixOf "the terminal latch failed"
