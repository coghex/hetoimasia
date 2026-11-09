{-# LANGUAGE OverloadedStrings #-}

-- | The bounds on what a script may hold and ask: the request bank's busy answer, the complete-or-too_large column answer, a no-op
-- removal, an expected failure nobody reads, and the unavailable-state guard after a terrain call.
module Test.LuaEngine.Terrain.Limits (spec) where

import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

-- | One instance: fill the request bank with untaken reads and find the next call busy with exactly two values and no handle, take them
-- and find the bank free again.
busy ∷ Script
busy =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.arena = t.value self.held = {}"
        , "    for i = 1, 16 do self.held[i] = api.terrain.cell(self.arena, {x = i, y = 0, z = 0}) end"
        , "    local n = select('#', api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}))"
        , "    local r, e = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0})"
        , "    print('busy', n, r == nil, e.code, type(e.message))"
        , "    print('long column with a full bank', (pcall(api.terrain.column, self.arena, {x = 0, y = 0, z_min = 0, z_max = 8193})))"
        , "    self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  local all = true"
        , "  for i = 1, 16 do if not api.request.ready(self.held[i]) then all = false end end"
        , "  if all then"
        , "    for i = 1, 16 do api.request.take(self.held[i]) end"
        , "    local r, e = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0})"
        , "    print('after taking', r ~= nil, e == nil)"
        , "    self.s = 2"
        , "  end"
        , "end"
        ]
    }

-- | An arena whose column (0, 0) alternates solid and air from level 0: one solid level at every even level below 2,048.
alternating ∷ Script
alternating =
  script
    { scPrelude =
        terrainPrelude
          <> [ "local PATCHES = {}"
             , "for k = 0, 1023 do PATCHES[#PATCHES + 1] = { x = 0, y = 0, z_min = 2 * k, z_max = 2 * k + 1, value = { material = 'soil', shape = 0 } } end"
             , "local ALT = { materials = { 'soil' }, layers = {}, patches = PATCHES }"
             ]
    , scInit = ["self.s = 0", "self.q = api.terrain.open('alt', ALT)"]
    , scUpdate =
        [ "local function runs(t) if t.status ~= 'success' then return t.status .. ':' .. tostring(t.error and t.error.code) end return #t.value.runs end"
        , "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.arena = t.value self.q = nil"
        , "    self.cases = { {'exactly 1024', 0, 1024}, {'1025', 0, 1025}, {'whole', 0, 2048}, {'narrowed', 0, 100} }"
        , "    self.i = 0 self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  if self.q then"
        , "    local t = settle(api, self.q)"
        , "    if t then print(self.label, runs(t)) self.q = nil end"
        , "  end"
        , "  if not self.q then"
        , "    self.i = self.i + 1"
        , "    local c = self.cases[self.i]"
        , "    if c then self.label = c[1] self.q = api.terrain.column(self.arena, {x = 0, y = 0, z_min = c[2], z_max = c[3]})"
        , "    else"
        , "      print('range over 8192 levels', (pcall(api.terrain.column, self.arena, {x = 0, y = 0, z_min = 0, z_max = 8193})))"
        , "      print('done') self.s = 2"
        , "    end"
        , "  end"
        , "end"
        ]
    }

-- | A removal of air changes nothing; a duplicate nobody reads fails nothing; the unavailable-state guard terminates after terrain use.
quiet ∷ Script
quiet =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)", "self.dup = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.arena = t.value self.q = api.terrain.remove(self.arena, {x = 0, y = 0, z = 100}) self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('remove air', t.status, t.value.changed, t.value.revision) print('alive after an unread failure') self.s = 2 end"
        , "elseif self.s == 2 then"
        , "  print('state', pcall(api.state))"
        , "  self.s = 3"
        , "end"
        ]
    }

spec ∷ Spec
spec = describe "Terrain limits" $ do
  it "answers a full request bank with exactly nil and the busy record, and a taken bank with room again" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource busy)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "after taking\ttrue\ttrue"
          printed ← outLines world
          printed `shouldContain` ["busy\t2\ttrue\tbusy\tstring"]
          -- a permanent refusal is not hidden by the full bank: the overlong range is the ordinary error it is with room
          printed `shouldContain` ["long column with a full bank\tfalse"]

  it "answers a column of exactly 1,024 runs, refuses 1,025 as too_large with no partial answer, and answers a narrowed range in full" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource alternating)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          printed
            `shouldBe` [ "exactly 1024\t1024"
                       , "1025\tfailure:too_large"
                       , "whole\tfailure:too_large"
                       , "narrowed\t100"
                       , "range over 8192 levels\tfalse"
                       , "done"
                       ]

  it "reports a removal of air as unchanged, leaves an unread expected failure unfailing, and ends the session at the unavailable-state guard" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource quiet)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "alive after an unread failure"
          printed ← outLines world
          printed `shouldContain` ["remove air\tsuccess\tfalse\t0"]
          -- the guard latches the whole session's terminal failure, even after a successful terrain call
          pumpUntil world (advanceClock world 2000000000 >> (not . null <$> terminalsSeen world))
