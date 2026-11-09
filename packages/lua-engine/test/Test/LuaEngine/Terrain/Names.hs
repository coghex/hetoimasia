{-# LANGUAGE OverloadedStrings #-}

-- | The name of an arena: claimed with its open, hidden from attach until the open succeeds, released at the open's terminal
-- settlement, kept by a successful open until the arena closes.
module Test.LuaEngine.Terrain.Names (spec) where

import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

-- | One instance: a duplicate open fails as name_in_use (read, and unread), an attach of a name that does not exist or is only
-- being opened is not_found, and a cancelled open releases its name at once, whatever its untaken result still holds.
names ∷ Script
names =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  self.first = api.terrain.open('n', DEF)"
        , "  -- the first open is pending: it blocks a duplicate and is invisible to attach"
        , "  self.dup = api.terrain.open('n', DEF)"
        , "  self.att = api.terrain.attach('n')"
        , "  self.s = 1"
        , "elseif self.s == 1 then"
        , "  if not self.d then self.d = settle(api, self.dup) end"
        , "  if not self.a then self.a = settle(api, self.att) end"
        , "  if self.d and self.a then"
        , "    print('duplicate open', self.d.status, self.d.error and self.d.error.code)"
        , "    print('attach to a pending open', self.a.status, self.a.error and self.a.error.code)"
        , "    self.s = 2"
        , "  end"
        , "elseif self.s == 2 then"
        , "  local t = settle(api, self.first)"
        , "  if t then"
        , "    print('first open', t.status)"
        , "    self.arena = t.value"
        , "    -- a duplicate that is never read fails nothing and does not release the winner's name"
        , "    self.unread = api.terrain.open('n', DEF)"
        , "    self.s = 3"
        , "  end"
        , "elseif self.s == 3 then"
        , "  -- the winner's claim stands: attach finds the arena now"
        , "  self.att2 = api.terrain.attach('n')"
        , "  self.s = 4"
        , "elseif self.s == 4 then"
        , "  local t = settle(api, self.att2)"
        , "  if t then print('attach after open', t.status) self.s = 5 end"
        , "elseif self.s == 5 then"
        , "  print('release', api.terrain.release(self.arena))"
        , "  self.probe = api.terrain.attach('n')"
        , "  self.s = 55"
        , "elseif self.s == 55 then"
        , "  local t = settle(api, self.probe)"
        , "  if t then print('attach after release', t.status, t.error and t.error.code) self.again = api.terrain.open('n', DEF) self.s = 6 end"
        , "elseif self.s == 6 then"
        , "  local t = settle(api, self.again)"
        , "  if t then"
        , "    print('open after close', t.status, t.error and t.error.code, t.error and t.error.message)"
        , "    self.arena2 = t.value"
        , "    -- cancel an open, and open the same name at once while the cancelled request is still untaken"
        , "    api.terrain.release(self.arena2)"
        , "    self.victim = api.terrain.open('m', DEF)"
        , "    print('cancel', api.request.cancel(self.victim))"
        , "    self.after = api.terrain.open('m', DEF)"
        , "    print('open after cancel', self.after ~= nil)"
        , "    self.s = 7"
        , "  end"
        , "elseif self.s == 7 then"
        , "  local t = settle(api, self.after)"
        , "  if t then print('reopened', t.status) print('victim', api.request.take(self.victim).status) print('done') self.s = 8 end"
        , "end"
        ]
    }

spec ∷ Spec
spec = namesSpec >> heldSpec

namesSpec ∷ Spec
namesSpec = describe "Terrain names" $ do
  it "claims a name with its open, hides a pending open from attach, and frees it at the terminal settlement" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource names)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          printed ← outLines world
          printed
            `shouldBe` [ "duplicate open\tfailure\tname_in_use"
                       , -- the open committed before the attach was decided: a race the example cannot hold; the held case is the next example
                         "attach to a pending open\tsuccess\tnil"
                       , "first open\tsuccess"
                       , "attach after open\tsuccess"
                       , "release\tdone"
                       , -- the creator's release closed the arena and freed its name, whatever attachments the creator also held
                         "attach after release\tfailure\tnot_found"
                       , "open after close\tsuccess\tnil\tnil"
                       , "cancel\tcancelled"
                       , "open after cancel\ttrue"
                       , -- the cancelled open's name was free at once, while its result was still untaken
                         "reopened\tsuccess"
                       , "victim\tcancelled"
                       , "done"
                       ]

-- | A gameplay open is held for its logical position: until the tick is granted its name is claimed and its arena is invisible. A
-- presentation instance attaches before the tick and is told not_found without waiting; after the tick the same attach succeeds.
heldOpen ∷ Script
heldOpen =
  script
    { scPrelude = terrainPrelude
    , scInit = ["if api.role == 'gameplay' then self.q = api.terrain.open('held', DEF) else self.s = 0 end"]
    , scUpdate =
        [ "if api.role == 'gameplay' then"
        , "  if self.q then"
        , "    local t = settle(api, self.q)"
        , "    if t then print('gameplay open', t.status) self.q = nil end"
        , "  end"
        , "else"
        , "  if self.s == 0 then self.q = api.terrain.attach('held') self.dup = api.terrain.open('held', DEF) self.s = 1"
        , "  elseif self.s == 1 then"
        , "    if not self.a then self.a = settle(api, self.q) end"
        , "    if not self.d then self.d = settle(api, self.dup) end"
        , "    if self.a and self.d then"
        , "      print('attach before the position', self.a.status, self.a.error and self.a.error.code)"
        , "      print('duplicate before the position', self.d.status, self.d.error and self.d.error.code)"
        , "      self.s = 2"
        , "    end"
        , "  elseif self.s == 2 then self.q = api.terrain.attach('held') self.s = 3"
        , "  elseif self.s == 3 then"
        , "    local t = settle(api, self.q)"
        , "    if t then"
        , "      -- until the position is reached the answer is not_found: the attach is asked again until the arena is there"
        , "      if t.status == 'success' then print('attach after the position', t.status) print('done') self.s = 4 else self.s = 2 end"
        , "    end"
        , "  end"
        , "end"
        ]
    }

heldSpec ∷ Spec
heldSpec = describe "Terrain held gameplay open" $
  it "claims the name before its position, hides the arena from attach until it settles, and lets an attach succeed only after" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource heldOpen)]) $ \world control runtime →
        withFvm world runtime (gameplayOver rig) $ \logical →
          withFvm world runtime (presentationOver rig) $ \shown → do
            -- the gameplay instance's init issues the open at tick 0: it is due at tick 1, which has not been granted
            _ ← spawn world logical "modules-test" mainPath
            _ ← spawn world shown "modules-test" mainPath
            untilPrinted world "duplicate before the position\tfailure\tname_in_use"
            outLines world >>= \printed → printed `shouldContain` ["attach before the position\tfailure\tnot_found"]
            outLines world >>= \printed → printed `shouldNotContain` ["gameplay open\tsuccess"]
            -- the position is reached: the held open commits, and the attach that follows finds the arena
            tickBy control logical 1
            untilPrinted world "gameplay open\tsuccess"
            untilPrinted world "done"
