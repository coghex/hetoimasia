{-# LANGUAGE OverloadedStrings #-}

-- | Two instances of one VM sharing a named arena: each its own lease, foreign handles refused, the creator's exit invalidating the
-- attachment (an expected failure of the attached lease's requests, not an error), a fresh incarnation on reopening, and the
-- attached client's release leaving its creator alive.
module Test.LuaEngine.Terrain.Ownership (spec) where

import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

-- | Instance 1 (A) creates the arena; instance 2 (B) attaches. The two coordinate through a global table, which is shared by the
-- instances of one VM and is the only thing they share: the handles are their own.
twoInstances ∷ Script
twoInstances =
  script
    { scPrelude = terrainPrelude <> ["SHARED = {}"]
    , scInit =
        [ "self.s = 0"
        , "if api.instance_id == 'inst-1' then self.q = api.terrain.open('shared', DEF) end"
        ]
    , scUpdate =
        [ "if api.instance_id == 'inst-1' then"
        , "  if self.s == 0 then"
        , "    local t = settle(api, self.q)"
        , "    if t then print('A open', t.status) self.arena = t.value SHARED.arena_a = t.value SHARED.opened = true self.s = 1 end"
        , "  elseif self.s == 1 and SHARED.b_ready then"
        , "    print('A release', api.terrain.release(self.arena)) SHARED.a_released = true self.s = 2"
        , "  elseif self.s == 2 and SHARED.b_closed_seen then"
        , "    self.q = api.terrain.open('shared', DEF) self.s = 3"
        , "  elseif self.s == 3 then"
        , "    local t = settle(api, self.q)"
        , "    if t then print('A reopen', t.status) SHARED.reopened = true self.s = 4 end"
        , "  end"
        , "else"
        , "  if self.s == 0 and SHARED.opened then self.q = api.terrain.attach('shared') self.s = 1"
        , "  elseif self.s == 1 then"
        , "    local t = settle(api, self.q)"
        , "    if t then print('B attach', t.status) self.arena = t.value self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 2 end"
        , "  elseif self.s == 2 then"
        , "    local t = settle(api, self.q)"
        , "    if t then"
        , "      print('B cell', t.status, t.value.material)"
        , "      try('B foreign cell', api.terrain.cell, SHARED.arena_a, {x = 0, y = 0, z = 0})"
        , "      try('B foreign release', api.terrain.release, SHARED.arena_a)"
        , "      SHARED.b_ready = true self.s = 3"
        , "    end"
        , "  elseif self.s == 3 and SHARED.a_released then"
        , "    self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 4"
        , "  elseif self.s == 4 then"
        , "    local t = settle(api, self.q)"
        , "    if t then print('B closed cell', t.status, t.error and t.error.code) SHARED.b_closed_seen = true self.s = 5 end"
        , "  elseif self.s == 5 and SHARED.reopened then"
        , "    self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 6"
        , "  elseif self.s == 6 then"
        , "    local t = settle(api, self.q)"
        , "    if t then print('B old lease after reopen', t.status, t.error and t.error.code) print('B release', api.terrain.release(self.arena)) print('B alive') self.s = 7 end"
        , "  end"
        , "end"
        ]
    }

spec ∷ Spec
spec = describe "Terrain ownership" $ do
  it "gives each instance its own lease, refuses a peer's handle, closes the arena with the creator's lease and never revives it" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource twoInstances)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          _ ← spawn world fvm "modules-test" mainPath
          pumpUntil world (advanceClock world 2000000000 >> (elem "B alive" <$> outLines world))
          printed ← outLines world
          printed
            `shouldBe` [ "A open\tsuccess"
                       , "B attach\tsuccess"
                       , "B cell\tsuccess\tsoil"
                       , -- another instance's handle is an ordinary error, for a query and for a release alike
                         "B foreign cell => false ; hetoimasia_engine.terrain_cell: the arena belongs to another instance"
                       , "B foreign release => false ; hetoimasia_engine.terrain_release: the arena belongs to another instance"
                       , "A release\tdone"
                       , -- the attached lease is still B's; the arena it named is closed: an expected failure, never an error
                         "B closed cell\tfailure\tarena_closed"
                       , "A reopen\tsuccess"
                       , -- the same name again is a fresh incarnation: the old lease is not revived
                         "B old lease after reopen\tfailure\tarena_closed"
                       , "B release\tdone"
                       , "B alive"
                       ]
          -- Both instances are still running: the failures failed neither.
          limitHeld (rgService rig) "arenas" `shouldReturn` 1
