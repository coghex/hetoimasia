{-# LANGUAGE OverloadedStrings #-}

-- | Strict dot-call validation (P-73 section 6, P-74): every schema of the facade, table-driven on real
-- Lua. A case is a label and a Lua expression the example runs under @pcall@ inside a hook of a real
-- instance; the example prints what it saw and the table below says what it must have been: an
-- ordinary Lua error naming a reason, or an acceptance. Arity follows Lua's real call count (an
-- explicit @nil@ is an argument); nothing is coerced; a table with a metatable is refused setup any
-- metamethod could run; a phase or role that may not call is refused setup anything is suspended.
module Test.LuaEngine.Facade.Validation (spec) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (Active))
import Test.Hspec
import Test.LuaEngine.Facade.Support

-- | What a case must have come to.
data Verdict
  = -- | An ordinary Lua error whose message holds each of these.
    Refused [Text]
  | -- | A call that returned (the first result is @true@).
    Accepted

data Case = Case Text Text Verdict

-- | The Lua of a case.
caseLua ∷ Case → Text
caseLua (Case label expression _) = "try(" <> Text.pack (show (Text.unpack label)) <> ", function() return " <> expression <> " end)"

-- | Check every case against the lines the instance printed.
checkCases ∷ [Case] → [Text] → Expectation
checkCases cases printed = mapM_ check cases
  where
    check found@(Case label _ verdict) = case [Text.drop (Text.length prefix) line | line ← printed, prefix `Text.isPrefixOf` line] of
      [seen] → verify found seen verdict
      [] → expectationFailure ("the case " <> show label <> " printed nothing; printed: " <> show printed)
      many → expectationFailure ("the case " <> show label <> " printed " <> show (length many) <> " lines")
      where
        prefix = label <> " => "
    verify (Case label _ _) seen = \case
      Accepted
        | "true" `Text.isPrefixOf` seen → pure ()
        | otherwise → expectationFailure (show label <> " must be accepted, but: " <> Text.unpack seen)
      Refused reasons
        | "false ; " `Text.isPrefixOf` seen && all (`Text.isInfixOf` seen) reasons → pure ()
        | otherwise → expectationFailure (show label <> " must be refused with " <> show reasons <> ", but: " <> Text.unpack seen)

-- | Run the cases in the hook, give the instance what it needs, and check what it printed.
inInit ∷ Role → [Text] → [Case] → Expectation
inInit role setup cases =
  withOneIn role fixedM1Profile script {scInit = setup <> map caseLua cases} files $ \world _ _ _ →
    outLines world >>= checkCases cases

inUpdate ∷ [Text] → [Case] → Expectation
inUpdate setup cases =
  withOneIn Gameplay fixedM1Profile script {scInit = setup, scUpdate = ["if self.ran then return end self.ran = true"] <> map caseLua cases} files $ \world control fvm _ → do
    tickBy control fvm 1
    outLines world >>= checkCases cases

inShutdown ∷ [Case] → Expectation
inShutdown cases =
  withOneIn Gameplay fixedM1Profile script {scShutdown = map caseLua cases} files $ \world _ _ spawned → do
    stopSpawned spawned
    _ ← settledOf spawned
    outLines world >>= checkCases cases

-- | The content the cases ask for.
files ∷ [(FilePath, ByteString)]
files = [("lua/a.lua", "return {id = 'a'}"), ("data.bin", "xx")]

spec ∷ Spec
spec = describe "validation" $ do
  describe "api.content.module" $ do
    it "refuses a mistaken call, a wrong type and an unknown or misshapen option as ordinary errors, and takes nil as an omitted option" $
      inInit Gameplay [] $
        [ Case "module colon" "api.content:module('lua/a.lua')" (Refused ["content_module"])
        , Case "module no arguments" "api.content.module()" (Refused ["expected 2 values, found 0"])
        , Case "module trailing nil beyond the maximum" "api.content.module('lua/a.lua', nil, nil)" (Refused ["expected 2 values, found 3"])
        , Case "module extra table" "api.content.module('lua/a.lua', {}, {})" (Refused ["expected 2 values, found 3"])
        , Case "module path number" "api.content.module(42)" (Refused ["expected byte string"])
        , Case "module path table" "api.content.module({})" (Refused ["expected byte string"])
        , Case "module options string" "api.content.module('lua/a.lua', 'x')" (Refused ["expected record"])
        , Case "module options number" "api.content.module('lua/a.lua', 3)" (Refused ["expected record"])
        , Case "module unknown option" "api.content.module('lua/a.lua', {bogus = 1})" (Refused ["unknown field bogus"])
        , Case "module optional is not a module option" "api.content.module('lua/a.lua', {optional = false})" (Refused ["unknown field optional"])
        , Case "module options with a metatable" "api.content.module('lua/a.lua', setmetatable({}, {__index = function() error('boom') end}))" (Refused ["metatable"])
        , Case "module options with a protected metatable" "api.content.module('lua/a.lua', setmetatable({}, {__metatable = false}))" (Refused ["metatable"])
        , Case "module options array" "api.content.module('lua/a.lua', {1})" (Refused ["not a record"])
        , Case "module explicit nil options" "api.content.module('lua/a.lua', nil)" Accepted
        , Case "module nil field is absent" "api.content.module('lua/a.lua', {tick_offset = nil, root = nil})" Accepted
        ]
    it "refuses a tick offset that is not a Lua integer from 1, and a root that is not an enabled identifier" $
      inInit Gameplay [] $
        [ Case "offset numeric string" "api.content.module('lua/a.lua', {tick_offset = '3'})" (Refused ["expected integer, found string"])
        , Case "offset float" "api.content.module('lua/a.lua', {tick_offset = 3.5})" (Refused ["a float where an integer is declared"])
        , Case "offset 1.0 is not 1" "api.content.module('lua/a.lua', {tick_offset = 1.0})" (Refused ["a float where an integer is declared"])
        , Case "offset zero" "api.content.module('lua/a.lua', {tick_offset = 0})" (Refused ["tick_offset must be an integer from 1"])
        , Case "offset negative" "api.content.module('lua/a.lua', {tick_offset = -4})" (Refused ["tick_offset must be an integer from 1"])
        , Case "offset beyond the tick" "api.content.module('lua/a.lua', {tick_offset = math.maxinteger})" Accepted
        , Case "offset 1" "api.content.module('lua/a.lua', {tick_offset = 1})" Accepted
        , Case "root number" "api.content.module('lua/a.lua', {root = 5})" (Refused ["expected text, found integer"])
        , Case "root uppercase" "api.content.module('lua/a.lua', {root = 'Game'})" (Refused ["is not a content identifier"])
        , Case "root empty" "api.content.module('lua/a.lua', {root = ''})" (Refused ["is not a content identifier"])
        , Case "root leading digit" "api.content.module('lua/a.lua', {root = '1game'})" (Refused ["is not a content identifier"])
        , Case "root with a slash" "api.content.module('lua/a.lua', {root = 'a/b'})" (Refused ["is not a content identifier"])
        , Case "root 65 characters" "api.content.module('lua/a.lua', {root = 'a' .. string.rep('b', 64)})" (Refused ["is not a content identifier"])
        , Case "root a valid identifier that is not enabled" "api.content.module('lua/a.lua', {root = 'other'})" (Refused ["is not enabled"])
        , Case "root the game's own" "api.content.module('lua/a.lua', {root = 'modules-test'})" Accepted
        ]
    it "checks every path boundary of the content identity policy before any provider is asked" $
      inInit Gameplay [] $
        [ Case ("module path " <> label) ("api.content.module(" <> expression <> ")") (Refused ["is not a content address"])
        | (label, expression) ←
            [ ("empty", "''")
            , ("leading slash", "'/lua/a.lua'")
            , ("trailing slash", "'lua/'")
            , ("double slash", "'lua//a.lua'")
            , ("dot segment", "'lua/./a.lua'")
            , ("dot-dot segment", "'lua/../a.lua'")
            , ("backslash", "'lua\\\\a.lua'")
            , ("colon", "'lua:a.lua'")
            , ("url", "'file:///a.lua'")
            , ("control character", "'lua/\\1.lua'")
            , ("nul", "'lua/\\0.lua'")
            , ("invalid utf-8", "'lua/\\255.lua'")
            , ("1025 bytes", "string.rep('a', 1025)")
            , ("256-byte segment", "'lua/' .. string.rep('a', 256)")
            , ("33 segments", "string.rep('a/', 32) .. 'a'")
            ]
        ]
        <> [ Case "module path at the segment limit" "api.content.module('lua/' .. string.rep('a', 255))" Accepted
           , Case "module path at 32 segments" "api.content.module(string.rep('a/', 31) .. 'a')" Accepted
           , Case "module path past the crossing ceiling" "api.content.module(string.rep('a', 17 * 1024 * 1024))" (Refused ["argument 1"])
           ]

  describe "api.content.data" $ do
    it "takes the optional flag as a boolean only, and false is a value and not an omission" $
      inInit Gameplay [] $
        [ Case "data colon" "api.content:data('data.bin')" (Refused ["content_data"])
        , Case "data optional false" "api.content.data('data.bin', {optional = false})" Accepted
        , Case "data optional true" "api.content.data('data.bin', {optional = true})" Accepted
        , Case "data optional nil" "api.content.data('data.bin', {optional = nil})" Accepted
        , Case "data optional string" "api.content.data('data.bin', {optional = 'true'})" (Refused ["expected boolean"])
        , Case "data optional number" "api.content.data('data.bin', {optional = 1})" (Refused ["expected boolean"])
        , Case "data unknown option" "api.content.data('data.bin', {bogus = true})" (Refused ["unknown field bogus"])
        , Case "data offset float" "api.content.data('data.bin', {tick_offset = 2.0})" (Refused ["a float where an integer is declared"])
        , Case "data root" "api.content.data('data.bin', {root = 'modules-test', tick_offset = 2})" Accepted
        , Case "data extra" "api.content.data('data.bin', {}, nil)" (Refused ["expected 2 values, found 3"])
        , Case "data path with a dot-dot" "api.content.data('../data.bin')" (Refused ["is not a content address"])
        ]
    it "refuses the tick offset from a presentation instance even when it is 1, and takes the rest" $
      inInit Presentation [] $
        [ Case "presentation offset 1" "api.content.data('data.bin', {tick_offset = 1})" (Refused ["tick_offset is not accepted from a presentation instance"])
        , Case "presentation module offset" "api.content.module('lua/a.lua', {tick_offset = 5})" (Refused ["tick_offset is not accepted from a presentation instance"])
        , Case "presentation data" "api.content.data('data.bin')" Accepted
        , Case "presentation module" "api.content.module('lua/a.lua')" Accepted
        ]

  describe "api.request" $ do
    it "refuses a missing, extra, mistaken or foreign argument as an ordinary error and answers a live handle" $
      inInit Gameplay ["local h = api.content.data('data.bin')"] $
        [ Case "ready live" "api.request.ready(h)" Accepted
        , Case "ready no argument" "api.request.ready()" (Refused ["expected 1 values, found 0"])
        , Case "ready explicit nil" "api.request.ready(nil)" (Refused ["expected capability data_request, found nil"])
        , Case "ready trailing nil" "api.request.ready(h, nil)" (Refused ["expected 1 values, found 2"])
        , Case "ready colon" "api.request:ready(h)" (Refused ["expected 1 values, found 2"])
        , Case "ready number" "api.request.ready(42)" (Refused ["data_request"])
        , Case "ready function" "api.request.ready(print)" (Refused ["a function cannot be passed"])
        , Case "ready table" "api.request.ready({})" (Refused ["data_request"])
        , Case "take trailing nil" "api.request.take(h, nil)" (Refused ["expected 1 values, found 2"])
        , Case "cancel number" "api.request.cancel(1)" (Refused ["data_request"])
        , Case "wait in init" "api.request.wait(h)" (Refused ["not available in init"])
        ]
    it "refuses a take of a spent handle and a wait outside an update" $
      inUpdate
        ["self.h = api.content.data('data.bin')"]
        [ Case "ready setup it settles" "api.request.ready(self.h)" Accepted
        , Case "wait is accepted in an update" "api.request.wait(self.h)" Accepted
        , Case "first take" "api.request.take(self.h)" Accepted
        , Case "second take of the spent handle" "api.request.take(self.h)" (Refused ["has ended"])
        , Case "ready of the spent handle" "api.request.ready(self.h)" (Refused ["has ended"])
        , Case "cancel of the spent handle" "api.request.cancel(self.h)" (Refused ["has ended"])
        ]
    it "refuses a content request and a wait in shutdown, and still answers a clock" $
      inShutdown
        [ Case "shutdown module" "api.content.module('lua/a.lua')" (Refused ["not available in shutdown"])
        , Case "shutdown data" "api.content.data('data.bin')" (Refused ["not available in shutdown"])
        , Case "shutdown wait_ticks" "api.time.wait_ticks(1)" (Refused ["not available in shutdown"])
        , Case "shutdown yield" "api.time.yield()" (Refused ["not available in shutdown"])
        , Case "shutdown tick" "api.time.tick()" Accepted
        ]

  describe "api.time" $ do
    it "refuses the other role's clock and every wait in init, takes only its exact arguments, and reads a clock in init" $
      inInit Gameplay [] $
        [ Case "tick" "api.time.tick()" Accepted
        , Case "tick trailing nil" "api.time.tick(nil)" (Refused ["expected 0 values, found 1"])
        , Case "tick colon" "api.time:tick()" (Refused ["expected 0 values, found 1"])
        , Case "tick_seconds" "api.time.tick_seconds()" Accepted
        , Case "tick_seconds extra" "api.time.tick_seconds(1)" (Refused ["expected 0 values, found 1"])
        , Case "seconds on gameplay" "api.time.seconds()" (Refused ["available to presentation only"])
        , Case "wait_seconds on gameplay" "api.time.wait_seconds(1)" (Refused ["available to presentation only"])
        , Case "wait_ticks in init" "api.time.wait_ticks(1)" (Refused ["not available in init"])
        , Case "yield in init" "api.time.yield()" (Refused ["not available in init"])
        ]
    it "refuses the gameplay clock and waits on a presentation instance" $
      inInit Presentation [] $
        [ Case "seconds" "api.time.seconds()" Accepted
        , Case "seconds extra" "api.time.seconds(nil)" (Refused ["expected 0 values, found 1"])
        , Case "tick on presentation" "api.time.tick()" (Refused ["available to gameplay only"])
        , Case "tick_seconds on presentation" "api.time.tick_seconds()" (Refused ["available to gameplay only"])
        , Case "wait_ticks on presentation" "api.time.wait_ticks(1)" (Refused ["available to gameplay only"])
        , Case "wait_seconds in init" "api.time.wait_seconds(1)" (Refused ["not available in init"])
        ]
    it "checks a tick wait's count and target before anything is suspended" $
      inUpdate
        []
        [ Case "wait_ticks zero" "api.time.wait_ticks(0)" (Refused ["whole number of ticks from 1"])
        , Case "wait_ticks negative" "api.time.wait_ticks(-3)" (Refused ["whole number of ticks from 1"])
        , Case "wait_ticks 1.0 is not 1" "api.time.wait_ticks(1.0)" (Refused ["a float where an integer is declared"])
        , Case "wait_ticks fraction" "api.time.wait_ticks(1.5)" (Refused ["a float where an integer is declared"])
        , Case "wait_ticks numeric string" "api.time.wait_ticks('1')" (Refused ["expected integer, found string"])
        , Case "wait_ticks nil" "api.time.wait_ticks(nil)" (Refused ["expected integer"])
        , Case "wait_ticks no argument" "api.time.wait_ticks()" (Refused ["expected 1 values, found 0"])
        , Case "wait_ticks extra nil" "api.time.wait_ticks(1, nil)" (Refused ["expected 1 values, found 2"])
        , Case "wait_ticks past the largest tick" "api.time.wait_ticks(math.maxinteger)" (Refused ["would end past the largest tick"])
        , Case "yield extra" "api.time.yield(nil)" (Refused ["expected 0 values, found 1"])
        , Case "request past the tick ceiling" "api.content.module('lua/a.lua', {tick_offset = math.maxinteger})" (Refused ["the tick and offset pass the ceiling"])
        , Case "request to the tick ceiling exactly" "api.content.module('lua/a.lua', {tick_offset = math.maxinteger - 1})" Accepted
        ]

  describe "ordinary errors" $
    it "can be caught without poisoning a healthy invocation" $
      withOneIn Gameplay fixedM1Profile
        script
          { scInit =
              [ "local ok = pcall(function() return api.content.module() end)"
              , "print('refused ' .. tostring(not ok))"
              ]
          , scUpdate = ["if self.ran then return end self.ran = true", "print('update ran')"]
          }
        files
        $ \world control fvm spawned → do
          tickBy control fvm 1
          outLines world >>= (`shouldBe` ["refused true", "update ran"])
          phaseOf spawned >>= (`shouldBe` Just Active)
