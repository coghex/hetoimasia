{-# LANGUAGE OverloadedStrings #-}

-- | Real Lua clients of the real terrain service: open, attach, the three reads, a removal and release, in both roles.
module Test.LuaEngine.Terrain.Basics (spec) where

import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

-- | The soil-over-stone arena read from a presentation instance: open, then a cell of the soil, a column through the layers,
-- the surface, a removal and the same cell again.
roundTrip ∷ Script
roundTrip =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.step = 0", "self.open = api.terrain.open('main', DEF)", "print('open', self.open ~= nil)"]
    , scUpdate =
        [ "if self.step == 0 then"
        , "  local t = settle(api, self.open)"
        , "  if t then print('opened', t.status) self.arena = t.value self.step = 1 self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) end"
        , "elseif self.step == 1 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('cell', t.status, t.value.revision, t.value.air, t.value.material, t.value.shape) self.step = 2 self.q = api.terrain.column(self.arena, {x = 0, y = 0, z_min = -5, z_max = 3}) end"
        , "elseif self.step == 2 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    local runs = {}"
        , "    for _, r in ipairs(t.value.runs) do runs[#runs + 1] = r.z_min .. ':' .. r.z_max .. ':' .. tostring(r.air) .. ':' .. tostring(r.material) end"
        , "    print('column', t.status, t.value.revision, table.concat(runs, ','))"
        , "    self.step = 3 self.q = api.terrain.surface(self.arena, {x = 0, y = 0})"
        , "  end"
        , "elseif self.step == 3 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('surface', t.status, t.value.occupied, t.value.z, t.value.material) self.step = 4 self.q = api.terrain.remove(self.arena, {x = 0, y = 0, z = 0}) end"
        , "elseif self.step == 4 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('remove', t.status, t.value.changed, t.value.revision) self.step = 5 self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) end"
        , "elseif self.step == 5 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('after', t.status, t.value.revision, t.value.air) self.step = 6 print('release', api.terrain.release(self.arena)) end"
        , "end"
        ]
    }

spec ∷ Spec
spec = describe "Terrain basics" $ do
  it "runs the whole surface from a gameplay instance, each request settling at its assigned tick" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource roundTrip)]) $ \world control runtime →
        withFvm world runtime (gameplayOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          pumpUntil world (tickBy control fvm 1 >> (elem "release\tdone" <$> outLines world))
          found ← outLines world
          mapM_ (putStrLn . Text.unpack) found

  it "runs the whole surface from a presentation instance" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource roundTrip)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          pumpUntil world (advanceClock world 2000000000 >> (elem "release\tdone" <$> outLines world))
          found ← outLines world
          mapM_ (putStrLn . Text.unpack) found
