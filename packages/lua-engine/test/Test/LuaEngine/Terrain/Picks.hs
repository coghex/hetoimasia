{-# LANGUAGE OverloadedStrings #-}

-- | The pick seam: an opaque typed authority that carries a displayed snapshot's incarnation and content revision to the removal as
-- its precondition. The authorities here are host-made fixtures (TRA-10 issues the real ones); Lua has no constructor.
module Test.LuaEngine.Terrain.Picks (spec) where

import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Terrain (issuePick)
import Hetoimasia.Terrain.Residency (ArenaId (..), Revision (..))
import Hetoimasia.Terrain.Runtime (Precondition (..))
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

-- | A removal with a stale pick, a matching pick, another instance's pick and a forged one.
picking ∷ Script
picking =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.arena = t.value"
        , "    try('foreign pick', api.terrain.remove, self.arena, {x = 0, y = 0, z = 0}, TEST_PICK(3))"
        , "    try('forged pick', api.terrain.remove, self.arena, {x = 0, y = 0, z = 0}, TEST_PICK(99))"
        , "    self.q = api.terrain.remove(self.arena, {x = 0, y = 0, z = 0}, TEST_PICK(2))"
        , "    self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    print('stale pick', t.status, t.error and t.error.code)"
        , "    self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 2"
        , "  end"
        , "elseif self.s == 2 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    print('cell after the stale pick', t.value.air, t.value.revision)"
        , "    self.q = api.terrain.remove(self.arena, {x = 0, y = 0, z = 0}, TEST_PICK(1)) self.s = 3"
        , "  end"
        , "elseif self.s == 3 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('matching pick', t.status, t.value.changed, t.value.revision) print('done') self.s = 4 end"
        , "end"
        ]
    }

spec ∷ Spec
spec = describe "Terrain pick seam" $
  it "removes nothing for a stale, foreign or forged authority and removes through the same atomic path for a matching one" $
    withRig $ \rig → do
      -- the first arena of a fresh service is incarnation 0 at content revision 0; the first instance of the VM is inst-1
      _ ← issuePick (rgPicks rig) "inst-1" (Precondition (ArenaId 0) (Revision 0))
      _ ← issuePick (rgPicks rig) "inst-1" (Precondition (ArenaId 0) (Revision 5))
      _ ← issuePick (rgPicks rig) "inst-2" (Precondition (ArenaId 0) (Revision 0))
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource picking)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          printed `shouldContain` ["stale pick\tfailure\tstale_view"]
          printed `shouldContain` ["cell after the stale pick\tfalse\t0"]
          printed `shouldContain` ["matching pick\tsuccess\ttrue\t1"]
          -- another instance's authority and a forged one are ordinary errors, before any removal
          printed `shouldSatisfy` any ("foreign pick => false ; " `Text.isPrefixOf`)
          printed `shouldSatisfy` any ("forged pick => false ; " `Text.isPrefixOf`)
