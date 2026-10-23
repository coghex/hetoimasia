{-# LANGUAGE OverloadedStrings #-}

-- | The accepted authoring example (P-72), run on real Lua through the real facade: supplied @util@ and
-- @room@ modules, a request place held by another instance so that the first attempt is busy, an
-- explicit retry from a later update, and one accepted load delivered at its fixed offset.
module Test.LuaEngine.Facade.Authoring (spec) where

import Data.ByteString (ByteString)
import Hetoimasia.LuaEngine.Profile (CountLimit (RequestsPerInstance, RequestsPerVm))
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (Active))
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Request.Profiles (counts)

-- | The files of the example.
layout ∷ Layout
layout =
  Layout
    [ ("lua/util.lua", luaMain ["print('util evaluated')", "return {answer = 42}"])
    , ("lua/room.lua", luaMain ["print('room evaluated')", "return {id = 'room', mark = function() return 'room!' end}"])
    , ("data.bin", "bytes")
    , ("lua/hold.lua", holder)
    , ("lua/main.lua", verbatim)
    , ("lua/traced.lua", traced)
    ]

-- | An instance that holds the VM's only request place until tick 6.
holder ∷ ByteStringLines
holder =
  luaMain
    [ "return {"
    , "  gameplay = {"
    , "    every_ticks = 1,"
    , "    init = function(self, api)"
    , "      self.request = api.content.data('data.bin', {tick_offset = 6})"
    , "    end,"
    , "    update = function(self, dt)"
    , "      local api = self.api"
    , "      if self.request and api.request.ready(self.request) then"
    , "        local result = api.request.take(self.request)"
    , "        self.request = nil"
    , "        print('hold took ' .. result.status .. ' at tick ' .. api.time.tick())"
    , "      end"
    , "    end"
    , "  },"
    , "  presentation = {}"
    , "}"
    ]

-- | The accepted example, verbatim.
verbatim ∷ ByteStringLines
verbatim =
  luaMain
    [ "local util = import(\"lua/util.lua\")"
    , "local function start_room(self)"
    , "  local request, refusal = self.api.content.module("
    , "    \"lua/room.lua\", {tick_offset = 3})"
    , "  if not request then"
    , "    assert(refusal.code == \"busy\")"
    , "    return -- self.want_room stays true for a later update"
    , "  end"
    , "  self.request, self.want_room = request, false"
    , "end"
    , "return {"
    , "  gameplay = {"
    , "    every_ticks = 1,"
    , "    init = function(self, api)"
    , "      self.util = util"
    , "      self.want_room = true"
    , "      start_room(self)"
    , "    end,"
    , "    update = function(self, dt_seconds)"
    , "      local api = self.api"
    , "      if self.want_room then start_room(self) end"
    , "      if self.request and api.request.ready(self.request) then"
    , "        local result = api.request.take(self.request)"
    , "        self.request = nil"
    , "        if result.status == \"success\" then self.room = result.value end"
    , "      end"
    , "    end"
    , "  },"
    , "  presentation = {}"
    , "}"
    ]

-- | The same example with a line printed at each point the example describes.
traced ∷ ByteStringLines
traced =
  luaMain
    [ "local util = import(\"lua/util.lua\")"
    , "local function start_room(self)"
    , "  local request, refusal = self.api.content.module("
    , "    \"lua/room.lua\", {tick_offset = 3})"
    , "  if not request then"
    , "    assert(refusal.code == \"busy\")"
    , "    print('busy at tick ' .. self.api.time.tick())"
    , "    return"
    , "  end"
    , "  print('accepted at tick ' .. self.api.time.tick())"
    , "  self.request, self.want_room = request, false"
    , "end"
    , "return {"
    , "  gameplay = {"
    , "    every_ticks = 1,"
    , "    init = function(self, api)"
    , "      self.util = util"
    , "      self.want_room = true"
    , "      start_room(self)"
    , "    end,"
    , "    update = function(self, dt_seconds)"
    , "      local api = self.api"
    , "      if self.want_room then start_room(self) end"
    , "      if self.request and api.request.ready(self.request) then"
    , "        local result = api.request.take(self.request)"
    , "        self.request = nil"
    , "        if result.status == \"success\" then"
    , "          self.room = result.value"
    , "          print('room taken at tick ' .. api.time.tick() .. ' same=' .. tostring(self.room == import('lua/room.lua')) .. ' ' .. self.room.mark())"
    , "        end"
    , "      end"
    , "    end"
    , "  },"
    , "  presentation = {}"
    , "}"
    ]

type ByteStringLines = ByteString

spec ∷ Spec
spec = describe "the accepted authoring example" $ do
  it "retries after a busy refusal from a later update and receives one accepted load at its fixed offset" $
    withWorld tiny layout $ \world control runtime → withFvm world runtime gameplayShape $ \fvm → do
      _ ← spawn world fvm "modules-test" "lua/hold.lua"
      _ ← spawn world fvm "modules-test" "lua/traced.lua"
      tickBy control fvm 12
      outLines world
        >>= ( `shouldBe`
                [ "util evaluated"
                , "busy at tick 0"
                , "busy at tick 1"
                , "busy at tick 2"
                , "busy at tick 3"
                , "busy at tick 4"
                , "busy at tick 5"
                , "hold took success at tick 6"
                , "accepted at tick 6"
                , "room evaluated"
                , "room taken at tick 9 same=true room!"
                ]
            )
  it "runs the example as written, with no failure, and evaluates each supplied module once" $
    withWorld tiny layout $ \world control runtime → withFvm world runtime gameplayShape $ \fvm → do
      holder' ← spawn world fvm "modules-test" "lua/hold.lua"
      asWritten ← spawn world fvm "modules-test" "lua/main.lua"
      tickBy control fvm 12
      phaseOf holder' >>= (`shouldBe` Just Active)
      phaseOf asWritten >>= (`shouldBe` Just Active)
      outLines world >>= (`shouldBe` ["util evaluated", "hold took success at tick 6", "room evaluated"])
  where
    tiny = counts [(RequestsPerInstance, 1), (RequestsPerVm, 1)]
