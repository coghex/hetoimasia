{-# LANGUAGE OverloadedStrings #-}

-- | The namespace of a name is the session's and the instance's content root: a name that exists only under another root or session
-- is not found, and the miss says nothing of it. And the end of a creator's instance closes its arena for the attachments.
module Test.LuaEngine.Terrain.Isolation (spec) where

import Data.Unique (newUnique)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

-- | The first instance opens @x@; the others attach to it and, failing, open @x@ themselves.
byRoot ∷ Script
byRoot =
  script
    { scPrelude = terrainPrelude <> ["OPENED = OPENED or false"]
    , scInit = ["self.s = 0", "if api.instance_id == 'inst-1' then self.q = api.terrain.open('x', DEF) end"]
    , scUpdate =
        [ "if api.instance_id == 'inst-1' then"
        , "  if self.s == 0 then local t = settle(api, self.q) if t then print('A open', api.content_id, t.status) OPENED = true self.s = 1 end end"
        , "else"
        , "  if self.s == 0 and OPENED then self.q = api.terrain.attach('x') self.s = 1"
        , "  elseif self.s == 1 then"
        , "    local t = settle(api, self.q)"
        , "    if t then print('attach from', api.content_id, t.status, t.error and t.error.code) self.q = api.terrain.open('x', DEF) self.s = 2 end"
        , "  elseif self.s == 2 then"
        , "    local t = settle(api, self.q)"
        , "    if t then print('open from', api.content_id, t.status) print('done') self.s = 3 end"
        , "  end"
        , "end"
        ]
    }

-- | An instance that only attaches to @x@, and says what it found.
attachOnly ∷ Script
attachOnly =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.q = api.terrain.attach('x')"]
    , scUpdate =
        [ "if self.q then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('other session attach', t.status, t.error and t.error.code) self.q = nil end"
        , "end"
        ]
    }

-- | The creator opens and stays; the attachment reads until the arena it names is closed.
creatorEnds ∷ Script
creatorEnds =
  script
    { scPrelude = terrainPrelude <> ["SHARED = SHARED or {}"]
    , scInit = ["self.s = 0", "if api.instance_id == 'inst-1' then self.q = api.terrain.open('e', DEF) end"]
    , scUpdate =
        [ "if api.instance_id == 'inst-1' then"
        , "  if self.s == 0 then local t = settle(api, self.q) if t then SHARED.opened = true self.arena = t.value self.s = 1 end end"
        , "else"
        , "  if self.s == 0 and SHARED.opened then self.q = api.terrain.attach('e') self.s = 1"
        , "  elseif self.s == 1 then"
        , "    local t = settle(api, self.q)"
        , "    if t then self.arena = t.value print('B ready') self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 2 end"
        , "  elseif self.s == 2 then"
        , "    local t = settle(api, self.q)"
        , "    if t then"
        , "      if t.status == 'failure' then print('B sees', t.error.code) print('done') self.s = 3"
        , "      else self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) end"
        , "    end"
        , "  end"
        , "end"
        ]
    }

spec ∷ Spec
spec = describe "Terrain isolation" $ do
  it "finds a name only under its own content root and its own session, and says nothing of the others" $
    withRig $ \rig → do
      otherSession ← newUnique
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource byRoot), ("lua/attach.lua", scriptSource attachOnly)]) $ \world _ runtime →
        withFvm world runtime ((presentationOver rig) {shRoots = ["modules-test", "other-root"]}) $ \roots →
          withFvm world runtime (presentationOverSession rig otherSession) $ \elsewhere → do
            _ ← spawn world roots "modules-test" mainPath
            -- another content root of the same session and VM: the name opened under the first is not found, and opening it is its own
            _ ← spawn world roots "other-root" mainPath
            untilPrinted world "open from\tother-root\tsuccess"
            outLines world >>= \printed → printed `shouldContain` ["attach from\tother-root\tfailure\tnot_found"]
            -- another session over the same service: the same root and name are not found there either, though the service holds the name
            _ ← spawn world elsewhere "modules-test" "lua/attach.lua"
            untilPrinted world "other session attach\tfailure\tnot_found"

  it "closes the arena for its attachments when the creator's instance ends, an expected failure and not an error" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource creatorEnds)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          creator ← spawn world fvm "modules-test" mainPath
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "B ready"
          stopSpawned creator
          untilPrinted world "done"
          outLines world >>= \printed → printed `shouldContain` ["B sees\tarena_closed"]
          limitHeld (rgService rig) "arenas" `shouldReturn` 0
