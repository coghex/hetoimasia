{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | The windows between a request's commit and its settlement, the session's gate in the commit, the service's banks seen through Lua,
-- the ownership of a handle after many have been issued, and the order of logical reads after a removal. The terrain owner and the
-- adapter are held at named points by gates, so an example decides which side wins by what it does and never by how long it waits.
module Test.LuaEngine.Terrain.Windows (spec) where

import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, finally, try)
import Data.Either (isLeft)
import Control.Monad (unless, void, when)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Profile (CountLimit (CopiedValueDepth, CopiedValueElements, LuaIntegerMaximum, SceneDepth, SceneSprites))
import Hetoimasia.LuaEngine.Terrain (TerrainFacade (..), TerrainHooks (..), noTerrainHooks)
import qualified Hetoimasia.Scripting.Lua.Instance as Instance
import Hetoimasia.Scripting.Lua.Provider (advanceRequestEpoch)
import Hetoimasia.Scripting.Lua.Scheduled (scheduledEndpoint)
import Test.LuaEngine.Request.Profiles (counts)
import Hetoimasia.Terrain.Residency (LimitsSpec (..), Revision (..), mkLimits)
import Hetoimasia.Terrain.Runtime
import Test.Support.Bounded (bounded)
import Hetoimasia.Terrain.Source (LayerSpec (..), SourceSpec (..))
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

soilOverStoneSpec ∷ SourceSpec
soilOverStoneSpec =
  SourceSpec
    { specMaterials = ["soil", "stone"]
    , specLayers =
        [ LayerSpec {layerMin = Nothing, layerMax = Just (-3), layerMaterial = "stone", layerShape = 0}
        , LayerSpec {layerMin = Just (-3), layerMax = Just 1, layerMaterial = "soil", layerShape = 0}
        ]
    , specPatches = []
    }

-- | A presentation instance that opens an arena and removes a cell from it.
remover ∷ Script
remover =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.arena = t.value self.r = api.terrain.remove(self.arena, {x = 0, y = 0, z = 0}) print('issued') self.s = 1 end"
        , "end"
        ]
    }

-- | An instance that attaches to @shared@, asking again while it is not found, and says what each answer was.
attacher ∷ Script
attacher =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.q = api.terrain.attach('shared')"]
    , scUpdate =
        [ "if self.q then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    print('attach', t.status, t.error and t.error.code)"
        , "    if t.status == 'failure' and t.error.code == 'not_found' then self.q = api.terrain.attach('shared') else self.q = nil end"
        , "  end"
        , "end"
        ]
    }

-- | A gameplay instance whose init opens a name with a definition the service fails (a duplicate material), due at tick 1.
failsLogically ∷ Script
failsLogically =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.q = api.terrain.open('dup', { materials = { 'a', 'a' }, layers = {} })", "print('invalid open issued')"]
    , scUpdate = ["if self.q then local t = settle(api, self.q) if t then print('invalid open', t.status, t.error and t.error.code) self.q = nil end end"]
    }

-- | A gameplay instance whose init opens eight names with a definition the service fails, due at tick 1; at tick 1 it opens eight others.
manyFailing ∷ Script
manyFailing =
  script
    { scPrelude = terrainPrelude <> ["local BAD = { materials = { 'a', 'a' }, layers = {} }"]
    , scInit = ["self.s = 0", "self.n = 0", "for i = 1, 8 do api.terrain.open('f' .. i, BAD) end"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  for i = 1, 8 do api.terrain.open('g' .. i, BAD) end"
        , "  print('second round issued') self.s = 1"
        , "elseif self.s == 1 then print('second round settled') self.s = 2 end"
        ]
    }

-- | A presentation instance whose init opens @dup@ with a definition the service fails (a duplicate material).
opensInvalidNow ∷ Script
opensInvalidNow =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.q = api.terrain.open('dup', { materials = { 'a', 'a' }, layers = {} })", "print('invalid open issued')"]
    , scUpdate = ["if self.q then local t = settle(api, self.q) if t then print('invalid open', t.status, t.error and t.error.code) self.q = nil end end"]
    }

-- | A gameplay instance whose init opens a valid name, due at tick 1.
opensLogically ∷ Script
opensLogically =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.q = api.terrain.open('held', DEF)", "print('held open issued')"]
    , scUpdate = ["if self.q then local t = settle(api, self.q) if t then print('held open', t.status, t.error and t.error.code) self.q = nil end end"]
    }

-- | A presentation instance that, when the example says so, opens a name, twice (the second on a second signal), saying each answer.
reopensOnSignal ∷ Text → Script
reopensOnSignal name =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0"]
    , scUpdate =
        [ "if self.s == 0 then TEST_WAIT('first') self.q = api.terrain.open('" <> name <> "', DEF) self.s = 1"
        , "elseif self.s == 1 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('first answer', t.status, t.error and t.error.code) self.s = 2 end"
        , "elseif self.s == 2 then TEST_WAIT('second') self.q = api.terrain.open('" <> name <> "', DEF) self.s = 3"
        , "elseif self.s == 3 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('second answer', t.status, t.error and t.error.code) self.s = 4 end"
        , "end"
        ]
    }

-- | An instance that opens @shared@ and says so.
opener ∷ Script
opener =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.q = api.terrain.open('shared', DEF)"]
    , scUpdate = ["if self.q then local t = settle(api, self.q) if t then print('opened', t.status) self.q = nil end end"]
    }

-- | A gameplay instance that opens a name and cancels the open before its position; a presentation instance that then opens the same name.
cancelledOpen ∷ Script
cancelledOpen =
  script
    { scPrelude = terrainPrelude
    , scInit =
        [ "if api.role == 'gameplay' then"
        , "  self.q = api.terrain.open('held', DEF)"
        , "  print('cancel', api.request.cancel(self.q))"
        , "else"
        , "  self.q = api.terrain.open('held', DEF)"
        , "end"
        ]
    , scUpdate = ["if api.role ~= 'gameplay' and self.q then local t = settle(api, self.q) if t then print('reopen', t.status, t.error and t.error.code) self.q = nil end end"]
    }

-- | The first instance opens an arena and shares its handle; the second waits until that instance has ended, then releases it.
endedHandle ∷ Script
endedHandle =
  script
    { scPrelude = terrainPrelude <> ["SHARED = SHARED or {}"]
    , scInit = ["self.s = 0", "if api.instance_id == 'inst-1' then self.q = api.terrain.open('e', DEF) end"]
    , scUpdate =
        [ "if api.instance_id == 'inst-1' then"
        , "  if self.s == 0 then local t = settle(api, self.q) if t then SHARED.h = t.value SHARED.opened = true self.s = 1 end end"
        , "else"
        , "  if self.s == 0 and SHARED.opened then self.q = api.terrain.attach('e') self.s = 1"
        , "  elseif self.s == 1 then"
        , "    local t = settle(api, self.q)"
        , "    if t then self.arena = t.value print('B ready') self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 2 end"
        , "  elseif self.s == 2 then"
        , "    local t = settle(api, self.q)"
        , "    if t then"
        , "      if t.status == 'failure' then"
        , "        try('foreign release after the issuer ended', api.terrain.release, SHARED.h)"
        , "        print('done') self.s = 3"
        , "      else self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) end"
        , "    end"
        , "  end"
        , "end"
        ]
    }

-- | An instance that mutates the definition table it passed after the call returned, then reads the arena it opened.
copied ∷ Script
copied =
  script
    { scPrelude = terrainPrelude
    , scInit =
        [ "self.s = 0"
        , "self.def = " <> soilOverStone
        , "self.q = api.terrain.open('copy', self.def)"
        , "-- the table is the script's own again: nothing it does now may reach the request"
        , "self.def.layers[1].material = 'soil'"
        , "self.def.layers[2] = nil"
        , "self.def.materials[2] = 'junk'"
        ]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.arena = t.value self.c = api.terrain.cell(self.arena, {x = 0, y = 0, z = -5}) self.d = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  self.cr = self.cr or settle(api, self.c)"
        , "  self.dr = self.dr or settle(api, self.d)"
        , "  if self.cr and self.dr then print('deep', self.cr.value.material) print('top', self.dr.value.material) print('done') self.s = 2 end"
        , "end"
        ]
    }

-- | An instance that opens an arena and then fails: in its init, or in its shutdown.
failing ∷ Bool → Script
failing inInit =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('f', DEF)"] <> ["error('init failed')" | inInit]
    , scUpdate = ["if self.s == 0 then local t = settle(api, self.q) if t then self.arena = t.value print('opened') self.s = 1 end end"]
    , scShutdown = ["error('shutdown failed')" | not inInit]
    }

-- | A presentation instance that opens a name, waits until the service has committed the open and offered its lease, and cancels it
-- before the host has adopted it; another instance then opens the same name.
cancelAfterOffer ∷ Script
cancelAfterOffer =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.q = api.terrain.open('offered', DEF)", "TEST_AWAIT_OFFER('offered')", "print('cancel', api.request.cancel(self.q))"]
    }

-- | The second instance of the example above.
reopens ∷ Script
reopens =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.q = api.terrain.open('offered', DEF)"]
    , scUpdate = ["if self.q then local t = settle(api, self.q) if t then print('reopen', t.status, t.error and t.error.code) self.q = nil end end"]
    }

-- | An instance that opens a name once and asks for it again many times, and opens invalid definitions, all failing at once.
failingOpens ∷ Script
failingOpens =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('dup', DEF)", "self.n = 0"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.arena = t.value self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  self.pending = {}"
        , "  for i = 1, 8 do self.pending[#self.pending + 1] = api.terrain.open('dup', DEF) end"
        , "  for i = 1, 8 do self.pending[#self.pending + 1] = api.terrain.open('bad' .. i, { materials = {}, layers = {} }) end"
        , "  self.s = 2"
        , "elseif self.s == 2 then"
        , "  local left = 0"
        , "  for i, r in ipairs(self.pending) do if r and settle(api, r) then self.pending[i] = false elseif r then left = left + 1 end end"
        , "  if left == 0 then print('done') self.s = 3 end"
        , "end"
        ]
    }

-- | One cell read of a freshly opened arena, which says its revision.
firstRead ∷ Script
firstRead =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('r', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.c = api.terrain.cell(t.value, {x = 0, y = 0, z = 0}) self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  local c = settle(api, self.c)"
        , "  if c then print('revision', c.status, c.value.revision) print('done') self.s = 2 end"
        , "end"
        ]
    }

-- | A definition of exactly this many authored layers, and one more: the validator's bound on authored runs, through Lua.
manyLayers ∷ Int → Script
manyLayers count =
  script
    { scPrelude = terrainPrelude
    , scInit =
        [ "self.s = 0"
        , "local layers = {}"
        , "for i = 0, " <> Text.pack (show (count - 1)) <> " do layers[#layers + 1] = { z_min = i, z_max = i + 1, material = 'soil', shape = 0 } end"
        , "local ok, q, e = pcall(api.terrain.open, 'many', { materials = { 'soil' }, layers = layers })"
        , "if not ok then print('raised', string.sub(tostring(q), 1, 120)) print('done') self.s = 2 else self.q = q end"
        ]
    , scUpdate =
        [ "if self.s == 0 and self.q then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('many', t.status, t.error and t.error.code) print('done') self.s = 1 end"
        , "end"
        ]
    }

-- | An instance that asks for the arena of another VM, then opens the name of an open its own earlier sibling cancelled after the offer.
attachThenOpen ∷ Script
attachThenOpen =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.attach('offered')"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('attach', t.status, t.error and t.error.code) self.q = api.terrain.open('offered', DEF) self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('reopen', t.status, t.error and t.error.code) self.s = 2 end"
        , "end"
        ]
    }

-- | An instance that, on its second update, attaches after the service has been closed.
attachAfterClose ∷ Script
attachAfterClose =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0"]
    , scUpdate =
        [ "if self.s == 0 then print('ready') self.s = 1"
        , "elseif self.s == 1 then try('attach after close', api.terrain.attach, 'x') print('done') self.s = 2 end"
        ]
    }

-- | An instance that opens an arena one below the revision ceiling and removes an air cell, a solid cell (reaching the ceiling), an air
-- cell again (at the ceiling), and then another solid cell (which would pass it).
atCeiling ∷ Script
atCeiling =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('c', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.arena = t.value self.r = api.terrain.remove(self.arena, {x = 0, y = 0, z = 1}) self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  local r = settle(api, self.r)"
        , "  if r then print('air removal', r.status, r.value.changed, r.value.revision) self.r = api.terrain.remove(self.arena, {x = 0, y = 0, z = 0}) self.s = 2 end"
        , "elseif self.s == 2 then"
        , "  local r = settle(api, self.r)"
        , "  if r then print('solid removal', r.status, r.value.changed, r.value.revision) self.r = api.terrain.remove(self.arena, {x = 0, y = 0, z = 1}) self.s = 3 end"
        , "elseif self.s == 3 then"
        , "  local r = settle(api, self.r)"
        , "  if r then print('air removal at the ceiling', r.status, r.value.changed, r.value.revision) self.r = api.terrain.remove(self.arena, {x = 0, y = 0, z = -1}) print('issued') self.s = 4 end"
        , "end"
        ]
    }

-- | An instance that finds the service's clients, arenas or leases all taken.
pressed ∷ Script
pressed =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('first', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.arena = t.value"
        , "    local a, ea = api.terrain.attach('first')"
        , "    print('attach', a == nil, ea and ea.code)"
        , "    local o, eo = api.terrain.open('second', DEF)"
        , "    print('open', o == nil, eo and eo.code)"
        , "    print('done') self.s = 1"
        , "  end"
        , "end"
        ]
    }

-- | One instance churns through arenas; another then releases the first handle the first was issued.
churn ∷ Script
churn =
  script
    { scPrelude = terrainPrelude <> ["SHARED = SHARED or {}"]
    , scInit = ["self.s = 0", "self.i = 1"]
    , scUpdate =
        [ "if api.instance_id == 'inst-1' then"
        , "  if self.s == 0 then self.q = api.terrain.open('c' .. self.i, DEF) self.s = 1"
        , "  elseif self.s == 1 then"
        , "    local t = settle(api, self.q)"
        , "    if t then"
        , "      if self.i == 1 then SHARED.h = t.value end"
        , "      api.terrain.release(t.value)"
        , "      self.i = self.i + 1"
        , "      if self.i > 9 then SHARED.done = true self.s = 2 else self.s = 0 end"
        , "    end"
        , "  end"
        , "elseif SHARED.done and not self.tried then"
        , "  self.tried = true"
        , "  try('foreign release', api.terrain.release, SHARED.h)"
        , "  print('done')"
        , "end"
        ]
    }

-- | A gameplay instance that removes a cell and reads it, its column and its surface, all due at one tick.
ordered ∷ Script
ordered =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('g', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    local a = t.value"
        , "    self.r = api.terrain.remove(a, {x = 0, y = 0, z = 0})"
        , "    self.c = api.terrain.cell(a, {x = 0, y = 0, z = 0})"
        , "    self.k = api.terrain.column(a, {x = 0, y = 0, z_min = -5, z_max = 3})"
        , "    self.u = api.terrain.surface(a, {x = 0, y = 0})"
        , "    print('issued')"
        , "    self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  local r, c, k, u = settle(api, self.r), settle(api, self.c), settle(api, self.k), settle(api, self.u)"
        , "  print('removal', r.status, r.value.changed, r.value.revision)"
        , "  print('cell', c.value.air, c.value.revision)"
        , "  local runs = {}"
        , "  for _, run in ipairs(k.value.runs) do runs[#runs + 1] = run.z_min .. ':' .. run.z_max .. ':' .. tostring(run.air) end"
        , "  print('column', k.value.revision, table.concat(runs, ','))"
        , "  print('surface', u.value.revision, u.value.z, u.value.material)"
        , "  self.s = 2"
        , "end"
        ]
    }

-- | An instance that opens @offered@ and, once it has, releases the arena it was given.
opensThenReleases ∷ Script
opensThenReleases =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('offered', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('first opened', t.status) print('first release', api.terrain.release(t.value)) self.s = 1 end"
        , "end"
        ]
    }

-- | An instance that attaches to @offered@ over and over while it is not found, saying each answer.
observer ∷ Script
observer =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.q = api.terrain.attach('offered')"]
    , scUpdate =
        [ "if self.q then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    print('observer', t.status, t.error and t.error.code)"
        , "    if t.status == 'failure' and t.error.code == 'not_found' then self.q = api.terrain.attach('offered') else self.q = nil end"
        , "  end"
        , "end"
        ]
    }

-- | An instance that opens an arena and, one update after it says it is ready, reads a cell twice: the service is closed in between the
-- host's precheck of the first read and the service's admission of it.
closesBetween ∷ Script
closesBetween =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.arena = t.value print('opened') self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  print('ready') self.s = 2"
        , "elseif self.s == 2 then"
        , "  local ok, e = pcall(api.terrain.cell, self.arena, {x = 0, y = 0, z = 0})"
        , "  print('call', ok, string.find(tostring(e), 'closed', 1, true) ~= nil)"
        , "  local ok2, e2 = pcall(api.terrain.cell, self.arena, {x = 0, y = 0, z = 0})"
        , "  print('again', ok2, string.find(tostring(e2), 'closed', 1, true) ~= nil)"
        , "  print('done') self.s = 3"
        , "end"
        ]
    }

-- | An arena whose column (0, 0) alternates solid and air for eight levels from level 0 (as few layers as the smallest valid copied-value
-- limits let a script hand over), read in a VM with those limits: the eight-run answer of the wide range is one the host could never
-- deliver, and a one-level range is one it can.
tightReads ∷ Script
tightReads =
  script
    { scPrelude =
        terrainPrelude
          <> [ "local ALT = { materials = { 'soil' }, layers = {"
             , "  { z_min = 0, z_max = 1, material = 'soil', shape = 0 }, { z_min = 2, z_max = 3, material = 'soil', shape = 0 },"
             , "  { z_min = 4, z_max = 5, material = 'soil', shape = 0 }, { z_min = 6, z_max = 7, material = 'soil', shape = 0 } } }"
             ]
    , scInit = ["self.s = 0", "self.q = api.terrain.open('tight', ALT)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.arena = t.value"
        , "    local ok, e = pcall(api.terrain.column, self.arena, {x = 0, y = 0, z_min = 0, z_max = 8})"
        , "    print('wide column', ok, string.find(tostring(e), 'narrow the range', 1, true) ~= nil)"
        , "    local okNarrow, narrow = pcall(api.terrain.column, self.arena, {x = 0, y = 0, z_min = 0, z_max = 1})"
        , "    print('narrow column call', okNarrow)"
        , "    if okNarrow then self.q = narrow self.s = 1 else self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 2 end"
        , "  end"
        , "elseif self.s == 1 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('narrow column', t.status, #t.value.runs) self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 2 end"
        , "elseif self.s == 2 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('cell', t.status) self.q = api.terrain.remove(self.arena, {x = 0, y = 0, z = 0}) self.s = 3 end"
        , "elseif self.s == 3 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('remove', t.status, t.value.changed) self.q = api.terrain.surface(self.arena, {x = 0, y = 0}) self.s = 4 end"
        , "elseif self.s == 4 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('surface', t.status) print('done') self.s = 5 end"
        , "end"
        ]
    }

-- | The approved limits with only this much room for retained edits.
smallEdits ∷ Config
smallEdits = defaultConfig {configLimits = either (error . show) id (mkLimits approved)}
  where
    mib = 1024 * 1024
    approved =
      LimitsSpec
        { specResidentBytes = 256 * mib
        , specEditBytes = 1024
        , specStagingBytes = 128 * mib
        , specLoadJobs = 128
        , specQueuedCommands = 256
        , specPinsPerView = 2
        , specAgingQuanta = 8
        , specQueryRegions = 257
        , specExtentX = 16
        , specExtentY = 16
        , specExtentZ = 32
        , specHoldRegions = 256
        , specCameraRegions = 16384
        }

-- | Removals of one cell after another until the service has no room to retain another edit.
exhausting ∷ Script
exhausting =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.i = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.arena = t.value self.q = nil self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  if self.q then"
        , "    local t = settle(api, self.q)"
        , "    if t then self.q = nil end"
        , "  end"
        , "  if not self.q then"
        , "    local res = table.pack(api.terrain.remove(self.arena, {x = self.i, y = 0, z = 0}))"
        , "    if res[1] == nil then"
        , "      print('busy', res.n, res[2].code)"
        , "      self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 2"
        , "    else self.q = res[1] self.i = self.i + 1 end"
        , "  end"
        , "elseif self.s == 2 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('first edit kept', t.value.air) self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = -5}) self.s = 3 end"
        , "elseif self.s == 3 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('read still served', t.status, t.value.material) print('done') self.s = 4 end"
        , "end"
        ]
    }

spec ∷ Spec
spec = describe "Terrain windows and banks" $ do
  it "commits nothing, and fails the host, when the removal's revision is one no Lua integer holds (a provider defect, never a wrapped number)" $ do
    staged ← newEmptyMVar
    commits ← newIORef (0 ∷ Int)
    reached ← newIORef False
    let -- the owner stages the removal (where the host records its defect), and commits nothing
        probe = Probe $ \point → case point of
          PointStaging _ → void (tryPutMVar staged ())
          PointCommitted _ _ → atomicModifyIORef' commits (\seen → (seen + 1, ()))
          _ → pure ()
    (_, ExceptionWithContext _ raised) ←
      fatalWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource remover)]) $ \world _ runtime →
        withRigProbe defaultConfig {configFirstRevision = 9223372036854775807} probe $ \rig →
          withFvm world runtime (presentationOver rig) $ \fvm → do
            _ ← spawn world fvm "modules-test" mainPath
            untilPrinted world "issued"
            bounded (takeMVar staged)
            writeIORef reached True
    -- the owner failed with the host's defect, the body ran to its end, and the service committed nothing
    show raised `shouldSatisfy` Text.isInfixOf "ProviderDefect" . Text.pack
    readIORef reached `shouldReturn` True
    readIORef commits `shouldReturn` 0

  it "answers retained-edit exhaustion as the same immediate busy, evicts no earlier edit and still serves a read" $
    withRigConfig smallEdits $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource exhausting)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          printed `shouldContain` ["busy\t2\tbusy"]
          printed `shouldContain` ["first edit kept\ttrue"]
          printed `shouldContain` ["read still served\tsuccess\tstone"]

  it "refuses a commit once the session takes no new work, between the removal's preparation and its commit" $ do
    gate ← newGate
    probe ← removalProbe gate
    takes ← newTVarIO True
    withRigProbe defaultConfigForRaces probe $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource remover)]) $ \world _ runtime →
        withFvm world runtime ((presentationOver rig) {shTakesWork = readTVar takes}) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "issued"
          -- the prepared removal is held at the commit; the session's stop wins before the owner attempts it
          awaitReached gate
          atomically (writeTVar takes False)
          openGate gate
          -- an observer of the service finds the cell as it was: nothing was committed after the session closed admission
          observeCell rig (arenaName rig "modules-test" "main") (0, 0, 0) `shouldReturn` (0, Just "soil")

  it "answers an attach to an open the service committed but the host has not adopted as not_found at once, in every VM, and finds it after" $ do
    gate ← newGate
    withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookAdopting = holdAt gate} $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource opener), ("lua/attach.lua", scriptSource attacher)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \creatorVm →
          withFvm world runtime (presentationOver rig) $ \otherVm → do
            _ ← spawn world otherVm "modules-test" "lua/attach.lua"
            _ ← spawn world creatorVm "modules-test" mainPath
            -- the service has committed the open and the host's adoption of it is held: the other VM keeps asking and is never told it is there
            awaitReached gate
            -- an attach decided now finds a name only the service has settled: it answers not_found at once, without waiting for the adoption
            notFound ← length . filter (== "attach\tfailure\tnot_found") <$> outLines world
            pumpUntil world (advanceClock world 2000000000 >> ((> notFound) . length . filter (== "attach\tfailure\tnot_found") <$> outLines world))
            outLines world >>= \printed → printed `shouldNotContain` ["attach\tsuccess\tnil"]
            openGate gate
            untilPrinted world "attach\tsuccess\tnil"

  it "settles arena_closed, and publishes no lease, for an attach whose arena closed between its commit and its adoption" $ do
    gate ← newGate
    withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookAdopted = holdAt gate} $ \rig → do
      Right client ← registerClient (rgService rig)
      Right opening ← openArena (rgService rig) client (arenaName rig "modules-test" "shared") soilOverStoneSpec
      Right ownerLease ← await (rgService rig) opening
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource attacher)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          -- the attach is committed and its adoption held: the creator closes the arena now
          awaitReached gate
          _ ← releaseLease (rgService rig) ownerLease
          openGate gate
          untilPrinted world "attach\tfailure\tarena_closed"
          -- no lease of the closed arena is left: the creator's was released, the attachment's never published
          limitHeld (rgService rig) "leases" `shouldReturn` 0

  it "answers busy, with nothing reserved, when the service's client bank is full for an attach" $
    withRigConfig defaultConfig {configMaxClients = 1} $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource pressed)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          outLines world >>= \printed → printed `shouldContain` ["attach\ttrue\tbusy"]

  it "answers busy for an open when the service's arena bank is full, and again when its lease bank is" $ do
    mapM_
      ( \config → withRigConfig config $ \rig →
          withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource pressed)]) $ \world _ runtime →
            withFvm world runtime (presentationOver rig) $ \fvm → do
              _ ← spawn world fvm "modules-test" mainPath
              untilPrinted world "done"
              outLines world >>= \printed → printed `shouldContain` ["open\ttrue\tbusy"]
      )
      [defaultConfig {configMaxArenas = 1}, defaultConfig {configMaxLeases = 1}]

  it "refuses another instance's released handle after many handles have been issued since" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource churn)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          outLines world >>= \printed →
            printed `shouldSatisfy` any (\line → "foreign release => false ; " `Text.isPrefixOf` line && "another instance" `Text.isInfixOf` line)

  it "frees a cancelled open's name at the host's settlement, while the service has not yet been told" $ do
    tellGate ← newGate
    (`finally` openGate tellGate) $
     withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookCancelling = holdAt tellGate} $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource cancelledOpen)]) $ \world _ runtime →
        withFvm world runtime (gameplayOver rig) $ \logical →
          withFvm world runtime (presentationOver rig) $ \shown → do
            -- the instance's init cancels its own held open, and is held at the telling, so it is admitted without waiting for it to serve
            _ ← admitOnly world logical "modules-test" mainPath
            -- the host has settled the held open as cancelled and the telling of the service is held
            awaitReached tellGate
            _ ← spawn world shown "modules-test" mainPath
            untilPrinted world "reopen\tsuccess\tnil"
            openGate tellGate

  it "gives back the attach client of an attach that was refused busy, so the bank is not charged for it" $
    withRigConfig defaultConfig {configMaxClients = 2, configMaxLeases = 1} $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource pressed)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          outLines world >>= \printed → printed `shouldContain` ["attach\ttrue\tbusy"]
          -- only the instance's owner client is held: the refused attach's client was given back
          limitHeld (rgService rig) "clients" `shouldReturn` 1

  it "refuses another instance's handle after its issuer has ended and the arena is closed" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource endedHandle)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          issuer ← spawn world fvm "modules-test" mainPath
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "B ready"
          stopSpawned issuer
          untilPrinted world "done"
          outLines world >>= \printed →
            printed `shouldSatisfy` any (\line → "foreign release after the issuer ended => false ; " `Text.isPrefixOf` line && "another instance" `Text.isInfixOf` line)

  it "decides a request from a copy of the definition: the script's later mutation of its table changes nothing" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource copied)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          outLines world >>= \printed → printed `shouldContain` ["deep\tstone", "top\tsoil"]

  it "leaves no arena, lease or client behind when an instance fails in its init, or in its shutdown, holding an open or an arena" $
    mapM_
      ( \inInit →
          withRig $ \rig →
            withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource (failing inInit))]) $ \world _ runtime →
              withFvm world runtime (presentationOver rig) $ \fvm → do
                spawned ← admitOnly world fvm "modules-test" mainPath
                unless inInit $ untilPrinted world "opened" >> stopSpawned spawned
                failure ← settledFailure spawned
                failure `shouldSatisfy` isJust
                limitHeld (rgService rig) "arenas" `shouldReturn` 0
                limitHeld (rgService rig) "leases" `shouldReturn` 0
                -- the application forgets an instance it has observed end, as the session does: its terrain client ends with it
                limitHeld (rgService rig) "clients" `shouldReturn` 1
                forgetInstance (fvFacade fvm) (spId spawned)
                limitHeld (rgService rig) "clients" `shouldReturn` 0
      )
      [True, False]

  it "frees a cancelled open's name while the service has not been told, also when its lease was already offered" $ do
    tellGate ← newGate
    (`finally` openGate tellGate) $
      withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookCancelling = holdAt tellGate} $ \rig →
        withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource cancelAfterOffer), ("lua/second.lua", scriptSource reopens)]) $ \world _ runtime →
          withFvm world runtime (presentationOver rig) $ \first →
            withFvm world runtime (presentationOver rig) $ \second → do
              -- the service committed the open and offered its lease; the script cancelled it before the host adopted it, and the
              -- telling of the service is held
              _ ← admitOnly world first "modules-test" mainPath
              awaitReached tellGate
              _ ← spawn world second "modules-test" "lua/second.lua"
              untilPrinted world "reopen\tsuccess\tnil"
              openGate tellGate

  it "keeps no claim of an open that has ended: repeated duplicate and invalid opens leave the registry empty once the instance is forgotten" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource failingOpens)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          -- what is left is bounded by what is still open: the one arena the instance holds has ended its request
          forgetInstance (fvFacade fvm) (spId spawned)
          (Map.size <$> readTVarIO (tfClaims (rgFacade rig))) >>= (`shouldBe` 0)

  it "publishes a revision the profile's integer ceiling holds, and settles a host defect for the first one above it" $ do
    mapM_
      ( \(first, expectDefect) →
          if expectDefect
            then do
              (_, ExceptionWithContext _ raised) ←
                fatalWorld (counts [(LuaIntegerMaximum, 40)]) (Layout [("lua/main.lua", scriptSource firstRead)]) $ \world _ runtime →
                  withRigConfig defaultConfig {configFirstRevision = first} $ \rig →
                    withFvm world runtime (presentationOver rig) $ \fvm → do
                      _ ← spawn world fvm "modules-test" mainPath
                      pumpUntil world (advanceClock world 2000000000 >> (pure False))
              show raised `shouldSatisfy` Text.isInfixOf "ProviderDefect" . Text.pack
            else
              withWorld (counts [(LuaIntegerMaximum, 40)]) (Layout [("lua/main.lua", scriptSource firstRead)]) $ \world _ runtime →
                withRigConfig defaultConfig {configFirstRevision = first} $ \rig →
                  withFvm world runtime (presentationOver rig) $ \fvm → do
                    _ ← spawn world fvm "modules-test" mainPath
                    untilPrinted world "done"
                    outLines world >>= \printed → printed `shouldContain` ["revision\tsuccess\t40"]
      )
      [(40, False), (41, True)]

  it "accepts a definition of exactly the validator's 8,192 authored runs through Lua and refuses one more as a definition failure, leaving no arena" $ do
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource (manyLayers 8192))]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          outLines world >>= \printed → printed `shouldContain` ["many\tsuccess\tnil"]
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource (manyLayers 8193))]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          outLines world >>= \printed → do
            printed `shouldContain` ["many\tfailure\tdefinition"]
          limitHeld (rgService rig) "arenas" `shouldReturn` 0

  it "keeps an arena attachable-never and its name held while the lease of a cancelled open is being revoked, and lets another opener finish the revocation" $ do
    releaseGate ← newGate
    (`finally` openGate releaseGate) $
      withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookReleasing = holdAt releaseGate} $ \rig →
        withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource cancelAfterOffer), ("lua/second.lua", scriptSource attachThenOpen)]) $ \world _ runtime →
          withFvm world runtime (presentationOver rig) $ \first →
            withFvm world runtime (presentationOver rig) $ \second → do
              -- the lease was offered and the script cancelled the open; the service's release of the lease is held
              _ ← admitOnly world first "modules-test" mainPath
              awaitReached releaseGate
              _ ← spawn world second "modules-test" "lua/second.lua"
              -- the arena is still live, but it is not an open's that settled: nobody can attach to it...
              untilPrinted world "attach\tfailure\tnot_found"
              -- ...and its name is free for another open, which finishes the revocation itself
              untilPrinted world "reopen\tsuccess\tnil"
              openGate releaseGate

  it "answers an attach's refusal as ordinary when the service is closed before the instance's first attach client" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource attachAfterClose)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "ready"
          closeService (rgService rig)
          untilPrinted world "done"
          outLines world >>= \printed →
            printed `shouldSatisfy` any (\line → "attach after close => false ; " `Text.isPrefixOf` line && "closed" `Text.isInfixOf` line)

  it "lets removals through up to the revision ceiling, a removal of air at the ceiling included, and refuses the one that would pass it with nothing committed" $ do
    staged ← newEmptyMVar
    stagings ← newIORef (0 ∷ Int)
    commits ← newIORef (0 ∷ Int)
    reached ← newIORef False
    let -- the fourth removal, the one the ceiling refuses, is staged and never committed
        probe = Probe $ \point → case point of
          PointStaging _ → do
            n ← atomicModifyIORef' stagings (\seen → (seen + 1, seen + 1))
            when (n == 4) (void (tryPutMVar staged ()))
          PointCommitted _ _ → atomicModifyIORef' commits (\seen → (seen + 1, ()))
          _ → pure ()
    (_, ExceptionWithContext _ raised) ←
      fatalWorld (counts [(LuaIntegerMaximum, 40)]) (Layout [("lua/main.lua", scriptSource atCeiling)]) $ \world _ runtime →
        withRigProbe defaultConfig {configFirstRevision = 39} probe $ \rig →
          withFvm world runtime (presentationOver rig) $ \fvm → do
            _ ← spawn world fvm "modules-test" mainPath
            untilPrinted world "issued"
            printed ← outLines world
            -- below the ceiling air changes nothing, and a solid cell takes the revision to the ceiling itself
            printed `shouldContain` ["air removal\tsuccess\tfalse\t39", "solid removal\tsuccess\ttrue\t40"]
            -- at the ceiling a removal of air still succeeds, unchanged, at the revision it finds: it needs no revision beyond the ceiling
            printed `shouldContain` ["air removal at the ceiling\tsuccess\tfalse\t40"]
            -- the arena stands at the ceiling: a removal that would change it needs the next revision and is refused, a defect of the host's
            bounded (takeMVar staged)
            writeIORef reached True
    show raised `shouldSatisfy` Text.isInfixOf "ProviderDefect" . Text.pack
    readIORef reached `shouldReturn` True
    -- and nothing of it was committed: the three removals that ended at or below the ceiling committed (two of them unchanged), the fourth did not
    readIORef commits `shouldReturn` 3

  it "leaves no arena or lease behind when the host's adoption of an offered lease fails" $ do
    reached ← newIORef False
    (_, ExceptionWithContext _ _) ←
      fatalWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource opener)]) $ \world _ runtime →
        withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookAdopting = ioError (userError "adoption failed")} $ \rig →
          withFvm world runtime (presentationOver rig) $ \fvm → do
            _ ← admitOnly world fvm "modules-test" mainPath
            failed ← try @SomeException (pumpUntil world (advanceClock world 2000000000 >> (pure False)))
            failed `shouldSatisfy` isLeft
            limitHeld (rgService rig) "arenas" `shouldReturn` 0
            limitHeld (rgService rig) "leases" `shouldReturn` 0
            writeIORef reached True
    readIORef reached `shouldReturn` True

  it "recomputes a logical cell, column and surface read ordered after a removal of the same cell, after the removal committed, and reports the post-removal values and revision" $ do
    prepared ← newEmptyMVar
    events ← newIORef ([] ∷ [String])
    let -- what the owner does, in order: a read captures its answer at a revision, a removal is staged, a removal commits
        probe = Probe $ \point → do
          let note event = atomicModifyIORef' events (\seen → (event : seen, event : seen))
          seen ← case point of
            PointCaptured _ _ (Revision w) → note ("capture " <> show w)
            PointStaging _ → note "staged"
            PointCommitted _ (Revision w) → note ("commit " <> show w)
            _ → readIORef events
          -- the three reads and the removal are prepared against revision 0, before anything commits
          when (length (filter (== "capture 0") seen) >= 3 && "staged" `elem` seen) (void (tryPutMVar prepared ()))
    withRigProbe defaultConfigForRaces probe $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource ordered)]) $ \world control runtime →
        withFvm world runtime (gameplayOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          -- tick 1 settles the open and issues the removal, the cell, the column and the surface, all due at tick 2
          pumpUntil world (tickBy control fvm 1 >> (elem "issued" <$> outLines world))
          -- the stale captures exist before the commit: the owner has prepared all four against revision 0, and tick 2 has not begun
          bounded (takeMVar prepared)
          readIORef events >>= \seen → "commit 1" `shouldNotSatisfy` (`elem` seen)
          pumpUntil world (tickBy control fvm 1 >> (elem "surface\t1\t-1\tsoil" <$> outLines world))
          printed ← outLines world
          printed `shouldContain` ["removal\tsuccess\ttrue\t1"]
          printed `shouldContain` ["cell\ttrue\t1"]
          printed `shouldContain` ["column\t1\t-5:-3:false,-3:0:false,0:3:true"]
          -- and each was prepared again after it: captures at the new revision (at least one for each of the three) follow the commit, and none at the old one
          order ← reverse <$> readIORef events
          let (prior, following) = break (== "commit 1") order
          length (filter (== "capture 0") prior) `shouldBe` 3
          prior `shouldSatisfy` ("staged" `elem`)
          take 1 following `shouldBe` ["commit 1"]
          drop 1 following `shouldSatisfy` (\recaptured → length recaptured >= 3 && all (== "capture 1") recaptured)

  it "keeps a later open of a name hidden from attach until it settles, though an earlier open of the name lets go of its own hold after it was offered" $ do
    releaseGate ← newGate
    adoptGate ← newGate
    armed ← newIORef False
    let -- the first adoption after the example arms it is held, and none after
        holdFirstAdoption = do
          go ← atomicModifyIORef' armed (\a → (False, a))
          when go (holdAt adoptGate)
    withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookRevoked = holdAt releaseGate, hookAdopting = holdFirstAdoption} $ \rig →
        withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource opensThenReleases), ("lua/second.lua", scriptSource reopens), ("lua/observer.lua", scriptSource observer)]) $ \world _ runtime →
          withFvm world runtime (presentationOver rig) $ \first →
            withFvm world runtime (presentationOver rig) $ \second →
              withFvm world runtime (presentationOver rig) $ \third → do
                (`finally` (openGate releaseGate >> openGate adoptGate)) $ do
                  -- the first instance's arena is released: the service has freed the name, and the open has not yet let go of its hold
                  _ ← admitOnly world first "modules-test" mainPath
                  pumpUntilReached world releaseGate
                  -- a later open of the name is committed and offered, and the host's adoption of it is held
                  writeIORef armed True
                  _ ← admitOnly world second "modules-test" "lua/second.lua"
                  pumpUntilReached world adoptGate
                  _ ← spawn world third "modules-test" "lua/observer.lua"
                  untilPrinted world "observer\tfailure\tnot_found"
                  -- the first open lets go now: it is its own hold it lets go of, and the later open's stands
                  openGate releaseGate
                  asked ← length . filter (== "observer\tfailure\tnot_found") <$> outLines world
                  pumpUntil world (advanceClock world 2000000000 >> ((> asked + 2) . length . filter (== "observer\tfailure\tnot_found") <$> outLines world))
                  outLines world >>= \printed → printed `shouldNotContain` ["observer\tsuccess\tnil"]
                  openGate adoptGate
                  untilPrinted world "observer\tsuccess\tnil"

  it "refuses a read whose largest answer the VM's copied-value limits could never carry as an ordinary error, and never fails the host" $
    mapM_
      ( \(depth, narrowCarried) →
          withRig $ \rig →
            withWorld (counts [(CopiedValueDepth, depth), (SceneDepth, 3), (CopiedValueElements, 30), (SceneSprites, 1)]) (Layout [("lua/main.lua", scriptSource tightReads)]) $ \world _ runtime →
              withFvm world runtime (presentationOver rig) $ \fvm → do
                spawned ← spawn world fvm "modules-test" mainPath
                untilPrintedBy world spawned "done"
                printed ← outLines world
                -- the wide range is refused by the host's own judgement of its largest answer, before the service is handed it
                printed `shouldContain` ["wide column\tfalse\ttrue"]
                -- depth 4 carries a one-run column answer; depth 3 carries no column answer at all, and refuses each range the same way
                printed `shouldContain` ["narrow column call\t" <> (if narrowCarried then "true" else "false")]
                when narrowCarried (printed `shouldContain` ["narrow column\tsuccess\t1"])
                -- what fits is unaffected, and the instance was never failed
                printed `shouldContain` ["cell\tsuccess", "remove\tsuccess\ttrue", "surface\tsuccess"]
      )
      [(4, True), (3, False)]

  it "answers a service that closed after the host's precheck as the same permanent refusal, with nothing reserved, and a closed service before it the same way" $ do
    gate ← newGate
    armed ← newIORef False
    let holdFirst = do
          go ← atomicModifyIORef' armed (\a → (False, a))
          when go (holdAt gate)
    withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookSubmitting = holdFirst} $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource closesBetween)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "ready"
          -- the next update's read passes the precheck (the service admits), is admitted by the host, and is held before the service's own
          -- admission: the service closes there
          writeIORef armed True
          pumpUntilReached world gate
          closeService (rgService rig)
          openGate gate
          untilPrinted world "done"
          printed ← outLines world
          -- the service refused the hand-off: a permanent, ordinary refusal that names the closure; and the next call is refused by the precheck
          printed `shouldContain` ["call\tfalse\ttrue", "again\tfalse\ttrue"]
          -- the refused hand-off left no request in the service (a closed service holds nothing it was asked since), and the service is coherent
          census ← atomically (inspectCensusSTM (rgService rig))
          length (censusRequests census) `shouldBe` 0
          inspectInvariants (rgService rig) `shouldReturn` []

  it "releases at once the lease an open built, when its instance stops between the build and the settlement, and leaves no arena or lease" $ do
    gate ← newGate
    withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookAdopted = holdAt gate} $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource opener)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → (`finally` openGate gate) $ do
          spawned ← admitOnly world fvm "modules-test" mainPath
          -- the host has built the lease into the instance's and not yet settled the request (the handle is not published): the instance stops
          pumpUntilReached world gate
          stopSpawned spawned
          openGate gate
          failure ← settledFailure spawned
          isJust failure `shouldBe` False
          -- the lease that was built and never published was released with the request's end: no arena and no lease are left
          limitHeld (rgService rig) "arenas" `shouldReturn` 0
          limitHeld (rgService rig) "leases" `shouldReturn` 0

  it "releases at once the lease an attach built, when its instance stops between the build and the settlement, leaving only the creator's lease" $ do
    gate ← newGate
    withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookAdopted = holdAt gate} $ \rig → do
      Right client ← registerClient (rgService rig)
      Right opening ← openArena (rgService rig) client (arenaName rig "modules-test" "shared") soilOverStoneSpec
      Right _ ← await (rgService rig) opening
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource attacher)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → (`finally` openGate gate) $ do
          spawned ← admitOnly world fvm "modules-test" mainPath
          pumpUntilReached world gate
          stopSpawned spawned
          openGate gate
          failure ← settledFailure spawned
          isJust failure `shouldBe` False
          -- the attach's lease, built and never published, was released: the creator's is the only lease left, and its arena is live
          limitHeld (rgService rig) "arenas" `shouldReturn` 1
          limitHeld (rgService rig) "leases" `shouldReturn` 1

  it "frees the name of an open that an epoch cancelled between its build and its publication, for another VM's open of it" $ do
    gate ← newGate
    armed ← newIORef True
    let -- only the first open's adoption is held, where its lease is built and not published; the second's goes through
        holdFirst = do
          go ← atomicModifyIORef' armed (\a → (False, a))
          when go (holdAt gate)
    withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookAdopted = holdFirst} $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource opener)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \first →
          withFvm world runtime (presentationOver rig) $ \second → (`finally` openGate gate) $ do
            _ ← admitOnly world first "modules-test" mainPath
            pumpUntilReached world gate
            -- the owner's requests move to a new epoch: the open is cancelled, and the host's owner is held with the lease built, unpublished
            void (advanceRequestEpoch (scheduledEndpoint (fvOwner first)))
            -- another VM opens the name: it is free from the cancellation, not from the first owner's next boundary
            _ ← admitOnly world second "modules-test" mainPath
            untilPrinted world "opened\tsuccess"
            openGate gate

  it "holds the name of an open the service failed until the host settles it, against another VM's open, and frees it then" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource failsLogically), ("lua/other.lua", scriptSource (reopensOnSignal "dup"))]) $ \world control runtime →
        withFvm world runtime (gameplayOver rig) $ \gameplayVm →
          withFvm world runtime (presentationOver rig) $ \shown → do
            _ ← spawn world gameplayVm "modules-test" mainPath
            _ ← admitOnly world shown "modules-test" "lua/other.lua"
            -- the definition failed in the service at once, and the host holds that failure for tick 1: the name is still the first open's
            signalRig rig "first"
            untilPrinted world "first answer\tfailure\tname_in_use"
            -- the tick is granted and the first open is settled: the name is free
            pumpUntil world (tickBy control gameplayVm 1 >> (elem "invalid open\tfailure\tdefinition" <$> outLines world))
            signalRig rig "second"
            untilPrinted world "second answer\tsuccess\tnil"

  it "frees the name of a pending logical open that an epoch cancelled, for another VM's open of it" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource opensLogically), ("lua/other.lua", scriptSource (reopensOnSignal "held"))]) $ \world _ runtime →
        withFvm world runtime (gameplayOver rig) $ \gameplayVm →
          withFvm world runtime (presentationOver rig) $ \shown → do
            _ ← spawn world gameplayVm "modules-test" mainPath
            _ ← admitOnly world shown "modules-test" "lua/other.lua"
            -- the open is held for tick 1 and holds the name: a duplicate is refused
            signalRig rig "first"
            untilPrinted world "first answer\tfailure\tname_in_use"
            -- the owner's requests move to a new epoch: the open is cancelled, and the name is free from the host's settlement
            void (advanceRequestEpoch (scheduledEndpoint (fvOwner gameplayVm)))
            signalRig rig "second"
            untilPrinted world "second answer\tsuccess\tnil"

  it "frees the name of a pending logical open whose instance ended, for another VM's open of it" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource opensLogically), ("lua/other.lua", scriptSource (reopensOnSignal "held"))]) $ \world control runtime →
        withFvm world runtime (gameplayOver rig) $ \gameplayVm →
          withFvm world runtime (presentationOver rig) $ \shown → do
            opener' ← spawn world gameplayVm "modules-test" mainPath
            _ ← admitOnly world shown "modules-test" "lua/other.lua"
            signalRig rig "first"
            untilPrinted world "first answer\tfailure\tname_in_use"
            stopSpawned opener'
            pumpUntil world (tickBy control gameplayVm 1 >> ((/= Just Instance.Active) <$> phaseOf opener'))
            signalRig rig "second"
            untilPrinted world "second answer\tsuccess\tnil"

  it "arbitrates the name of a failed open and of a normal open as one decision: no open is admitted between another's consultation and its admission" $ do
    gate ← newGate
    armed ← newIORef True
    events ← newIORef ([] ∷ [String])
    let note event = modifyIORef' events (event :)
        holdFirst = do
          note "checked"
          go ← atomicModifyIORef' armed (\a → (False, a))
          when go (holdAt gate)
    withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookChecked = holdFirst, hookSubmitting = note "submitting"} $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource opensInvalidNow), ("lua/other.lua", scriptSource (reopensOnSignal "dup"))]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \shown →
          withFvm world runtime (presentationOver rig) $ \otherVm → (`finally` openGate gate) $ do
            _ ← admitOnly world shown "modules-test" "lua/other.lua"
            -- the normal open has consulted the failed opens (none) and is about to be admitted: held inside the critical section
            signalRig rig "first"
            pumpUntilReached world gate
            -- the other VM's open of the name (an invalid definition) is issued while it is held
            _ ← admitOnly world otherVm "modules-test" mainPath
            -- released, the first open is admitted and the second after it: the second's consultation did not come between the first's
            -- consultation and its admission (without the critical section it comes first, while the first is held)
            openGate gate
            pumpUntil world (advanceClock world 2000000000 >> ((>= 4) . length <$> readIORef events))
            readIORef events >>= \seen → reverse seen `shouldBe` ["checked", "submitting", "checked", "submitting"]
            untilPrinted world "first answer\tsuccess\tnil"
            untilPrinted world "invalid open\tfailure\tdefinition"
            -- the other instance goes on to the second wait it has in its script: let it
            signalRig rig "second"

  it "keeps the failed opens' names only while the host has not settled them, whatever names they used, and none once their instance is forgotten" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource manyFailing)]) $ \world control runtime →
        withFvm world runtime (gameplayOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          let held = Map.size <$> readTVarIO (tfFailedOpens (rgFacade rig))
          -- eight failed opens of eight names wait for tick 1
          held `shouldReturn` 8
          -- tick 1 settles them, and issues eight more of other names: the first eight were swept as the next were entered
          pumpUntil world (tickBy control fvm 1 >> (elem "second round issued" <$> outLines world))
          held >>= (`shouldSatisfy` (<= 8))
          pumpUntil world (tickBy control fvm 1 >> (elem "second round settled" <$> outLines world))
          -- the instance is forgotten: nothing is left of any of them
          forgetInstance (fvFacade fvm) (spId spawned)
          held `shouldReturn` 0
          (Map.size <$> readTVarIO (tfClaims (rgFacade rig))) >>= (`shouldBe` 0)

