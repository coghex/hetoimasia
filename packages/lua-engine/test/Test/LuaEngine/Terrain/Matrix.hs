{-# LANGUAGE OverloadedStrings #-}

-- | The matrices of the acceptance section: every expected failure read and unread, the banks a smaller validated profile reaches, the
-- permanent refusals that stay permanent under pressure, the places that stay charged until their work is retired, and releasing twice.
-- Each runs real Lua instances over the real service.
module Test.LuaEngine.Terrain.Matrix (spec) where

import Control.Exception (finally)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Control.Monad (forM_, replicateM_, void)
import Data.Maybe (isJust)
import qualified Hetoimasia.Scripting.Lua.Instance as Instance
import Hetoimasia.Scripting.Lua.Provider (advanceRequestEpoch)
import Hetoimasia.Scripting.Lua.Scheduled (scheduledEndpoint)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (CountLimit (CopiedValueDepth, RequestsPerInstance, RequestsPerVm, SceneDepth), fixedM1Profile)
import Hetoimasia.LuaEngine.Terrain (issuePick, terrainCodes, terrainFailureReply)
import Hetoimasia.Scripting.Lua.Admission (ExpectedFailure (expectedCode))
import Hetoimasia.Scripting.Lua.Provider (ProviderReply (..))
import Hetoimasia.Terrain.Query (QueryError (TooManyRuns), QueryLimits (..), defaultQueryLimits)
import Hetoimasia.Terrain.Residency (ArenaId (..), LimitsSpec (..), Revision (..), mkLimits)
import Hetoimasia.Terrain.Runtime (Config (..), Failure (..), Point (PointCaptured), Precondition (..), Probe (..), closeService, defaultConfig)
import Hetoimasia.Terrain.Source (SourceError (TooManyMaterials), SourceLimits (..), defaultSourceLimits, definitionHeaderBytes, materialRecordBytes)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Request.Profiles (counts)
import Test.LuaEngine.Terrain.Support

-- | An arena whose column (0, 0) alternates solid and air from level 0 for a thousand levels: a column answer over two thousand levels
-- has more than the 1,024 runs the service returns.
altPrelude ∷ [Text]
altPrelude =
  [ "local PATCHES = {}"
  , "for k = 0, 1023 do PATCHES[#PATCHES + 1] = { x = 0, y = 0, z_min = 2 * k, z_max = 2 * k + 1, value = { material = 'soil', shape = 0 } } end"
  , "local ALT = { materials = { 'soil' }, layers = {}, patches = PATCHES }"
  ]

-- | Every expected failure a script can reach, read and then the same call unread, each followed by the next step: the instance runs on.
failures ∷ Script
failures =
  stepsScript
    "DEF"
    altPrelude
    [ Step "alt opened" "return api.terrain.open('alt', ALT)" "return 'ok'"
    , Step "attached" "return api.terrain.attach('main')" "return 'ok'"
    , Step "not_found read" "return api.terrain.attach('nope')" "return 'ok'"
    , Step "not_found unread" "api.terrain.attach('nope') return nil" "return 'ok'"
    , Step "name_in_use read" "return api.terrain.open('main', DEF)" "return 'ok'"
    , Step "name_in_use unread" "api.terrain.open('main', DEF) return nil" "return 'ok'"
    , Step "definition read" "return api.terrain.open('bad', { materials = { 'a', 'a' }, layers = {} })" "return 'ok'"
    , Step "definition unread" "api.terrain.open('bad', { materials = { 'a', 'a' }, layers = {} }) return nil" "return 'ok'"
    , Step "too_large read" "return api.terrain.column(V['alt opened'], {x = 0, y = 0, z_min = 0, z_max = 2048})" "return 'ok'"
    , Step "too_large unread" "api.terrain.column(V['alt opened'], {x = 0, y = 0, z_min = 0, z_max = 2048}) return nil" "return 'ok'"
    , Step "stale_view read" "return api.terrain.remove(A, {x = 0, y = 0, z = 0}, TEST_PICK(1))" "return 'ok'"
    , Step "stale_view unread" "api.terrain.remove(A, {x = 0, y = 0, z = 0}, TEST_PICK(1)) return nil" "return 'ok'"
    , Step "released" "api.terrain.release(A) return nil" "return 'ok'"
    , Step "arena_closed read" "return api.terrain.cell(V['attached'], {x = 0, y = 0, z = 0})" "return 'ok'"
    , Step "arena_closed unread" "api.terrain.cell(V['attached'], {x = 0, y = 0, z = 0}) return nil" "return 'ok'"
    , Step "alive" "return api.terrain.attach('still')" "return 'ok'"
    ]

-- | An instance with a request bank of two: an arena, two reads left untaken, and then each call asked while the bank is full.
fullBank ∷ Script
fullBank =
  script
    { scPrelude =
        terrainPrelude
          <> [ "local function busy(label, ...)"
             , "  local res = table.pack(...)"
             , "  print(label, res.n, res[1] == nil, res[2] and res[2].code)"
             , "end"
             ]
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    local A = t.value"
        , "    self.a = api.terrain.cell(A, {x = 0, y = 0, z = 0})"
        , "    self.b = api.terrain.cell(A, {x = 1, y = 0, z = 0})"
        , "    busy('cell', api.terrain.cell(A, {x = 2, y = 0, z = 0}))"
        , "    busy('column', api.terrain.column(A, {x = 0, y = 0, z_min = 0, z_max = 3}))"
        , "    busy('surface', api.terrain.surface(A, {x = 0, y = 0}))"
        , "    busy('remove', api.terrain.remove(A, {x = 0, y = 0, z = 0}))"
        , "    busy('open', api.terrain.open('second', DEF))"
        , "    busy('attach', api.terrain.attach('main'))"
        , "    print('done') self.s = 1"
        , "  end"
        , "end"
        ]
    }

-- | The first instance opens @shared@ and shares its handle; the second attaches to it, fills its request bank of two, and then uses the
-- first's handle.
foreignUnderPressure ∷ Script
foreignUnderPressure =
  script
    { scPrelude = terrainPrelude <> ["SHARED = SHARED or {}"]
    , scInit = ["self.s = 0", "if api.instance_id == 'inst-1' then self.q = api.terrain.open('shared', DEF) end"]
    , scUpdate =
        [ "if api.instance_id == 'inst-1' then"
        , "  if self.s == 0 then local t = settle(api, self.q) if t then SHARED.h = t.value self.s = 1 end end"
        , "else"
        , "  if self.s == 0 and SHARED.h then self.q = api.terrain.attach('shared') self.s = 1"
        , "  elseif self.s == 1 then"
        , "    local t = settle(api, self.q)"
        , "    if t then"
        , "      self.b = t.value"
        , "      self.r1 = api.terrain.cell(self.b, {x = 0, y = 0, z = 0})"
        , "      self.r2 = api.terrain.cell(self.b, {x = 1, y = 0, z = 0})"
        , "      local full = select('#', api.terrain.cell(self.b, {x = 2, y = 0, z = 0}))"
        , "      print('bank full', full)"
        , "      local ok, e = pcall(api.terrain.cell, SHARED.h, {x = 0, y = 0, z = 0})"
        , "      print('foreign under pressure', ok, string.find(tostring(e), 'another instance', 1, true) ~= nil, string.find(tostring(e), 'busy', 1, true) ~= nil)"
        , "      print('done') self.s = 2"
        , "    end"
        , "  end"
        , "end"
        ]
    }

-- | An instance with a request bank of two that fills it and then asks for a third read on every update, saying what each answer was.
stoppedUnderPressure ∷ Script
stoppedUnderPressure =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.a = t.value"
        , "    self.r1 = api.terrain.cell(self.a, {x = 0, y = 0, z = 0})"
        , "    self.r2 = api.terrain.cell(self.a, {x = 1, y = 0, z = 0})"
        , "    self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  local ok, r, e = pcall(api.terrain.cell, self.a, {x = 2, y = 0, z = 0})"
        , "  if ok then print('try', ok, r == nil and e and e.code or 'accepted')"
        , "  else print('try', ok, string.find(tostring(r), 'stopping', 1, true) ~= nil, string.find(tostring(r), 'busy', 1, true) ~= nil) end"
        , "end"
        ]
    }

-- | An instance with a request bank of two that fills it and then asks for a third read on every update, saying what each answer was:
-- the service is closed by the example in between.
closedUnderPressure ∷ Script
closedUnderPressure =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.a = t.value"
        , "    self.r1 = api.terrain.cell(self.a, {x = 0, y = 0, z = 0})"
        , "    self.r2 = api.terrain.cell(self.a, {x = 1, y = 0, z = 0})"
        , "    self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  local ok, r, e = pcall(api.terrain.cell, self.a, {x = 2, y = 0, z = 0})"
        , "  if ok then print('closed try', ok, r == nil and e and e.code or 'accepted')"
        , "  else print('closed try', ok, string.find(tostring(r), 'closed', 1, true) ~= nil, string.find(tostring(r), 'busy', 1, true) ~= nil) end"
        , "end"
        ]
    }

-- | An instance with a request bank of one: a read the owner is preparing (it is held where that read captures its answer) is cancelled and
-- taken; the place is still charged, as the owner has not finished with what the read borrowed, and is free once it has.
cancelledStayCharged ∷ Script
cancelledStayCharged =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.a = t.value self.r = api.terrain.cell(self.a, {x = 0, y = 0, z = 0}) print('issued') self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  print('cancel', api.request.cancel(self.r))"
        , "  print('take', api.request.take(self.r).status)"
        , "  local r, e = api.terrain.cell(self.a, {x = 1, y = 0, z = 0})"
        , "  print('while preparing', r == nil and e.code or 'accepted')"
        , "  self.s = 2"
        , "elseif self.s == 2 then"
        , "  local r = api.terrain.cell(self.a, {x = 1, y = 0, z = 0})"
        , "  if r ~= nil then print('free') self.s = 3 else print('still busy') end"
        , "end"
        ]
    }

-- | Calls whose refusal is permanent (the answer could never be carried, the cell lies beyond the service's extent), made with the
-- request bank (of one) full and then with it free: each must be the same ordinary error, never busy.
permanentUnderPressure ∷ [Text] → Script
permanentUnderPressure calls =
  script
    { scPrelude =
        terrainPrelude
          <> [ "local function refusal(label, ...)"
             , "  local ok, r, e = pcall(...)"
             , "  if ok then print(label, 'returned', r == nil and e and e.code or 'accepted')"
             , "  else print(label, 'refused', string.find(tostring(r), 'busy', 1, true) == nil) end"
             , "end"
             , "local function each(api, A, phase)"
             ]
          <> ["  refusal(" <> Text.pack (show (Text.unpack label)) <> " .. ' ' .. phase, " <> call <> ")" | call ← calls, let label = last (Text.splitOn "." (Text.takeWhile (/= ',') call))]
          <> ["end"]
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.a = t.value"
        , "    self.r = api.terrain.cell(self.a, {x = 1, y = 0, z = 0})"
        , "    each(api, self.a, 'full')"
        , "    self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  local t = settle(api, self.r)"
        , "  if t then each(api, self.a, 'free') print('done') self.s = 2 end"
        , "end"
        ]
    }

-- | The creator opens @shared@ and, when the example says so, releases it.
closedCreator ∷ Script
closedCreator =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('shared', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then local t = settle(api, self.q) if t then self.a = t.value print('creator ready') self.s = 1 end"
        , "elseif self.s == 1 then TEST_WAIT('close') print('release', api.terrain.release(self.a)) self.s = 2 end"
        ]
    }

-- | The attached instance (a request bank of one) attaches, reads a cell (the owner is held where the read has captured its answer),
-- takes whatever the read settles as once the arena has been closed under it, and asks again until a place is free.
closedAttached ∷ Script
closedAttached =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.attach('shared')"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t and t.status == 'success' then self.b = t.value self.r = api.terrain.cell(self.b, {x = 0, y = 0, z = 0}) print('read issued') self.s = 1"
        , "  elseif t then print('attach failed', t.status, t.error and t.error.code) self.s = 5 end"
        , "elseif self.s == 1 then"
        , "  if api.request.ready(self.r) then"
        , "    local t = api.request.take(self.r)"
        , "    print('settled', t.status, t.error and t.error.code)"
        , "    local r, e = api.terrain.cell(self.b, {x = 1, y = 0, z = 0})"
        , "    print('after taking', r == nil and e.code or 'accepted')"
        , "    self.s = 2"
        , "  end"
        , "elseif self.s == 2 then"
        , "  local r = api.terrain.cell(self.b, {x = 1, y = 0, z = 0})"
        , "  if r ~= nil then print('free') self.s = 3 else print('still busy') end"
        , "end"
        ]
    }

-- | An instance that opens an arena and reads a cell: the owner is held where the read has captured its answer.
heldRead ∷ Script
heldRead =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.a = t.value self.r = api.terrain.cell(self.a, {x = 0, y = 0, z = 0}) print('read issued') self.s = 1 end"
        , "end"
        ]
    }

-- | The service limited to two regions for one request.
fewRegions ∷ Config
fewRegions = defaultConfig {configLimits = either (error . show) id (mkLimits approved)}
  where
    mib = 1024 * 1024
    approved =
      LimitsSpec
        { specResidentBytes = 256 * mib
        , specEditBytes = 16 * mib
        , specStagingBytes = 128 * mib
        , specLoadJobs = 128
        , specQueuedCommands = 256
        , specPinsPerView = 2
        , specAgingQuanta = 8
        , specQueryRegions = 2
        , specExtentX = 16
        , specExtentY = 16
        , specExtentZ = 32
        , specHoldRegions = 2
        , specCameraRegions = 16
        }

-- | Calls at the edges of the supported coordinate range: the highest and lowest cells, columns and surfaces the facade accepts.
edges ∷ Script
edges =
  stepsScript
    "DEF"
    []
    [ Step "column at the top" "return api.terrain.column(A, {x = 0, y = 0, z_min = (1 << 62) - 4, z_max = 1 << 62})" "return 'ok'"
    , Step "cell at the top" "return api.terrain.cell(A, {x = 0, y = 0, z = (1 << 62) - 1})" "return 'ok'"
    , Step "surface at the high corner" "return api.terrain.surface(A, {x = (1 << 62) - 1, y = (1 << 62) - 1})" "return 'ok'"
    , Step "surface at the low corner" "return api.terrain.surface(A, {x = -(1 << 62), y = -(1 << 62)})" "return 'ok'"
    , Step "cell at the low corner" "return api.terrain.cell(A, {x = -(1 << 62), y = -(1 << 62), z = -(1 << 62)})" "return 'ok'"
    , Step "remove at the top" "return api.terrain.remove(A, {x = (1 << 62) - 1, y = 0, z = (1 << 62) - 1})" "return 'ok'"
    ]

-- | A gameplay instance (a request bank of one) that attaches to @shared@ and, at tick 1, reads a cell, due at tick 2; at tick 2 it takes what
-- the read settled as, and asks again at every tick until a place is free.
closedAttachedLogical ∷ Script
closedAttachedLogical =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.attach('shared')"]
    , scUpdate =
        [ "local tick = api.time.tick()"
        , "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t and t.status == 'success' then self.b = t.value self.r = api.terrain.cell(self.b, {x = 0, y = 0, z = 0}) print('read issued at', tick) self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  local t = settle(api, self.r)"
        , "  if t then"
        , "    print('settled at', tick, t.status, t.error and t.error.code)"
        , "    local r, e = api.terrain.cell(self.b, {x = 1, y = 0, z = 0})"
        , "    print('after taking at', tick, r == nil and e.code or 'accepted')"
        , "    self.s = 2"
        , "  end"
        , "elseif self.s == 2 then"
        , "  local r = api.terrain.cell(self.b, {x = 1, y = 0, z = 0})"
        , "  if r ~= nil then print('free') self.s = 3 else print('still busy') end"
        , "end"
        ]
    }

-- | A gameplay instance that opens an arena (due tick 1) and, at tick 1, reads a cell, due at tick 2.
heldReadLogical ∷ Script
heldReadLogical =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.a = t.value self.r = api.terrain.cell(self.a, {x = 0, y = 0, z = 0}) print('read issued') self.s = 1 end"
        , "end"
        ]
    }

-- | An instance that releases its arena twice at once, and once more after the release has retired.
releasesTwice ∷ Script
releasesTwice =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.n = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.a = t.value"
        , "    print('first release', api.terrain.release(self.a))"
        , "    print('second release', api.terrain.release(self.a))"
        , "    self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  self.n = self.n + 1"
        , "  if self.n >= 4 then print('late release', api.terrain.release(self.a)) print('done') self.s = 2 end"
        , "end"
        ]
    }

-- | Definitions whose decode and whose validator could both reject: the decode layer rejects first, as an ordinary error, and a definition
-- only the validator rejects is the expected failure.
precedence ∷ Script
precedence =
  stepsScript
    "DEF"
    []
    [ Step "both" "local ok, e = pcall(api.terrain.open, 'p', { materials = { 'a', 'a' }, layers = { { material = 'a', shape = 1.0 } } }) print('both layers', ok, string.find(tostring(e), 'float', 1, true) ~= nil) return nil" "return 'ok'"
    , Step "validator only" "return api.terrain.open('q', { materials = { 'a', 'a' }, layers = {} })" "return 'ok'"
    ]

-- | The accounted bytes of a definition of this many materials, each named by 64 bytes: the validator's byte accounting.
accounted ∷ Int → Int
accounted materials = fromIntegral definitionHeaderBytes + materials * (fromIntegral materialRecordBytes + 64)

-- | The most materials, of 64 bytes each, a definition may name within the validator's 256 KiB.
mostWithin256KiB ∷ Int
mostWithin256KiB = last (takeWhile ((<= 256 * 1024) . accounted) [0 .. 4095])

-- | A definition of exactly the most materials the 256 KiB bound allows, and of one more.
bounded256 ∷ Script
bounded256 =
  stepsScript
    "DEF"
    [ "local function mats(n) local m = {} for i = 1, n do m[i] = 'm' .. string.format('%063d', i) end return m end" ]
    [ Step "at the bound" ("return api.terrain.open('at', { materials = mats(" <> Text.pack (show mostWithin256KiB) <> "), layers = {} })") "return 'ok'"
    , Step "past the bound" ("return api.terrain.open('past', { materials = mats(" <> Text.pack (show (mostWithin256KiB + 1)) <> "), layers = {} })") "return 'ok'"
    ]

-- | The creator opens an arena and reads it on every update; the second instance attaches and says so, and is stopped by the example.
sharedCreator ∷ Script
sharedCreator =
  script
    { scPrelude = terrainPrelude <> ["SHARED = SHARED or {}"]
    , scInit = ["self.s = 0", "if api.instance_id == 'inst-1' then self.q = api.terrain.open('shared', DEF) end"]
    , scUpdate =
        [ "if api.instance_id == 'inst-1' then"
        , "  if self.s == 0 then"
        , "    local t = settle(api, self.q)"
        , "    if t then self.a = t.value SHARED.opened = true self.s = 1 self.q = api.terrain.cell(self.a, {x = 0, y = 0, z = 0}) end"
        , "  else"
        , "    local t = settle(api, self.q)"
        , "    if t then print('creator read', t.status) self.q = api.terrain.cell(self.a, {x = 0, y = 0, z = 0}) end"
        , "  end"
        , "else"
        , "  if self.s == 0 and SHARED.opened then self.q = api.terrain.attach('shared') self.s = 1"
        , "  elseif self.s == 1 then local t = settle(api, self.q) if t then print('attached', t.status) self.s = 2 end end"
        , "end"
        ]
    }

-- | The first instance opens an arena and shares its @api.terrain@; the second calls that captured table with the first's handle.
capturedFacade ∷ Script
capturedFacade =
  script
    { scPrelude = terrainPrelude <> ["SHARED = SHARED or {}"]
    , scInit = ["self.s = 0", "if api.instance_id == 'inst-1' then self.q = api.terrain.open('captured', DEF) end"]
    , scUpdate =
        [ "if api.instance_id == 'inst-1' then"
        , "  if self.s == 0 then local t = settle(api, self.q) if t then SHARED.terrain = api.terrain SHARED.h = t.value self.s = 1 end end"
        , "elseif SHARED.h and self.s == 0 then"
        , "  self.s = 1"
        , "  local ok, e = pcall(function() return SHARED.terrain.cell(SHARED.h, {x = 0, y = 0, z = 0}) end)"
        , "  print('captured facade', ok, string.sub(tostring(e), 1, 160))"
        , "  print('done')"
        , "end"
        ]
    }

-- | An instance with a request bank of two, full of results nobody has taken, that cancels, releases its arena and goes on.
fullQueue ∷ Script
fullQueue =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.a = t.value self.held = {}"
        , "    self.held[1] = api.terrain.cell(self.a, {x = 0, y = 0, z = 0})"
        , "    self.held[2] = api.terrain.cell(self.a, {x = 1, y = 0, z = 0})"
        , "    print('full', select('#', api.terrain.cell(self.a, {x = 2, y = 0, z = 0})))"
        , "    print('cancel', api.request.cancel(self.held[1]))"
        , "    print('release', api.terrain.release(self.a))"
        , "    print('done') self.s = 1"
        , "  end"
        , "end"
        ]
    }

-- | An instance with an unread expected terrain failure, and then a required request of another service that fails.
unrelatedRequired ∷ Script
unrelatedRequired =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.unread = api.terrain.attach('nope')"]
    , scUpdate =
        [ "self.s = self.s + 1"
        , "if self.s < 6 then print('alive', self.s)"
        , "elseif self.s == 6 then self.r = api.content.data('missing.bin') print('required issued') end"
        ]
    }

spec ∷ Spec
spec = describe "Terrain matrices" $ do
  it "reads, and leaves unread, each expected failure a script can reach, and the instance runs its next update after each" $
    withRig $ \rig → do
      -- the one authority this example issues is for the first arena of a fresh service at a revision it never has: a stale view
      _ ← issuePick (rgPicks rig) "inst-1" (Precondition (ArenaId 0) (Revision 5))
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource failures)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          forM_ [("not_found", "not_found read"), ("name_in_use", "name_in_use read"), ("definition", "definition read"), ("too_large", "too_large read"), ("stale_view", "stale_view read"), ("arena_closed", "arena_closed read")] $ \(code, label) →
            printed `shouldContain` [label <> "\tfailure\t" <> code]
          -- an unread failure prints nothing and fails nothing: the instance went on to its next step, and the last one
          forM_ ["not_found unread", "name_in_use unread", "definition unread", "too_large unread", "stale_view unread", "arena_closed unread"] $ \label →
            printed `shouldNotSatisfy` any ((label <> "\t") `Text.isPrefixOf`)
          printed `shouldContain` ["alive\tfailure\tnot_found"]

  it "maps every failure the service can settle to a code the host declared, source_failure included, or to the host's own defect" $ do
    forM_ [NotFound, ArenaClosed, StaleView, Definition (TooManyMaterials 4095), TooLarge (TooManyRuns 1024), SourceFailure "a region could not be read", NameInUse] $ \failure →
      case terrainFailureReply failure of
        ProviderExpected found → expectedCode found `shouldSatisfy` (`elem` terrainCodes)
        other → expectationFailure (show failure <> " was not an expected failure: " <> take 80 (show other))
    -- the seven codes are exactly the ones the failures above map to
    terrainCodes `shouldMatchList` ["not_found", "arena_closed", "stale_view", "definition", "source_failure", "too_large", "name_in_use"]
    -- what the service never declared to a script is the host's defect, never a code
    forM_ [Superseded "overtaken", HostFailure "an accounting defect"] $ \failure →
      case terrainFailureReply failure of
        ProviderFailure _ → pure ()
        other → expectationFailure (show failure <> " must be a defect, found " <> take 80 (show other))

  it "reaches each request bank of a smaller validated profile with exactly two values, and no call that was refused busy reached the service" $
    withRig $ \rig →
      withWorld (counts [(RequestsPerInstance, 2), (RequestsPerVm, 2)]) (Layout [("lua/main.lua", scriptSource fullBank)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          forM_ ["cell", "column", "surface", "remove", "open", "attach"] $ \label →
            printed `shouldContain` [label <> "\t2\ttrue\tbusy"]
          -- the refused opens made no arena and no lease, and the refused attach holds no client: only the one arena, its lease and the owner client
          limitHeld (rgService rig) "arenas" `shouldReturn` 1
          limitHeld (rgService rig) "leases" `shouldReturn` 1
          limitHeld (rgService rig) "clients" `shouldReturn` 1

  it "refuses another instance's handle as an ordinary error, never busy, while the caller's request bank is full" $
    withRig $ \rig →
      withWorld (counts [(RequestsPerInstance, 2), (RequestsPerVm, 4)]) (Layout [("lua/main.lua", scriptSource foreignUnderPressure)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          printed ← outLines world
          printed `shouldContain` ["bank full\t2"]
          printed `shouldContain` ["foreign under pressure\tfalse\ttrue\tfalse"]

  it "refuses a call of a stopping session as an ordinary error, never busy, while the request bank is full" $
    withRig $ \rig →
      withWorld (counts [(RequestsPerInstance, 2), (RequestsPerVm, 2)]) (Layout [("lua/main.lua", scriptSource stoppedUnderPressure)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          -- the bank is full and the session takes work: busy
          untilPrinted world "try\ttrue\tbusy"
          -- the session stops, the bank is as full, and the answer is the refusal of a stopping session
          setAdmission world AdmissionStopping
          untilPrinted world "try\tfalse\ttrue\tfalse"
          setAdmission world AdmissionOpen

  it "refuses a call of a closed service as an ordinary error, never busy, while the request bank is full" $
    withRig $ \rig →
      withWorld (counts [(RequestsPerInstance, 2), (RequestsPerVm, 2)]) (Layout [("lua/main.lua", scriptSource closedUnderPressure)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "closed try\ttrue\tbusy"
          closeService (rgService rig)
          untilPrinted world "closed try\tfalse\ttrue\tfalse"

  it "keeps the place of a cancelled and taken request charged until the owner has finished preparing it" $ do
    gate ← newGate
    -- the owner is held where the read has captured its answer: it is running the read's preparation when the script cancels it
    withRigProbe defaultConfigForRaces (gatedProbe (\p → case p of PointCaptured {} → True; _ → False) gate) $ \rig →
      withWorld (counts [(RequestsPerInstance, 1), (RequestsPerVm, 1)]) (Layout [("lua/main.lua", scriptSource cancelledStayCharged)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → (`finally` openGate gate) $ do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "issued"
          awaitReached gate
          -- cancelled and taken, and still charged: its borrowed data and credits are the owner's until its preparation exits
          untilPrintedBy world spawned "while preparing\tbusy"
          outLines world >>= \printed → printed `shouldContain` ["cancel\tcancelled", "take\tcancelled"]
          -- and it stays so over further updates while the owner is held
          pumpUntil world (advanceClock world 2000000000 >> ((>= 3) . length . filter (== "still busy") <$> outLines world))
          outLines world >>= \printed → printed `shouldNotContain` ["free"]
          openGate gate
          untilPrintedBy world spawned "free"

  it "refuses a call whose largest answer the VM's limits could never carry as an ordinary error before any bank, with the bank full or free, and no work reaches the service" $ do
    captured ← newIORef (0 ∷ Int)
    let probe = Probe $ \point → case point of
          PointCaptured {} → atomicModifyIORef' captured (\seen → (seen + 1, ()))
          _ → pure ()
        calls = ["api.terrain.column, A, {x = 0, y = 0, z_min = 0, z_max = 9}", "api.terrain.column, A, {x = 0, y = 0, z_min = 0, z_max = 2}"]
    withRigProbe defaultConfigForRaces probe $ \rig →
      withWorld (counts [(CopiedValueDepth, 3), (SceneDepth, 3), (RequestsPerInstance, 1), (RequestsPerVm, 1)]) (Layout [("lua/main.lua", scriptSource (permanentUnderPressure calls))]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          forM_ ["full", "free"] $ \phase →
            printed `shouldContain` ["column " <> phase <> "\trefused\ttrue"]
          -- only the one read the example itself made reached the owner
          readIORef captured `shouldReturn` 1

  it "refuses a cell beyond the service's extent as an ordinary error before any bank, with the bank full or free, and a cell inside it as busy or served" $ do
    captured ← newIORef (0 ∷ Int)
    let probe = Probe $ \point → case point of
          PointCaptured {} → atomicModifyIORef' captured (\seen → (seen + 1, ()))
          _ → pure ()
        calls = ["api.terrain.cell, A, {x = 2, y = 0, z = 0}", "api.terrain.remove, A, {x = 0, y = 1, z = 0}", "api.terrain.column, A, {x = 0, y = 0, z_min = 0, z_max = 3}"]
    withRigProbe tightRigConfig probe $ \rig →
      withWorld (counts [(RequestsPerInstance, 1), (RequestsPerVm, 1)]) (Layout [("lua/main.lua", scriptSource (permanentUnderPressure calls))]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          forM_ ["cell", "remove", "column"] $ \label →
            forM_ ["full", "free"] $ \phase →
              printed `shouldContain` [label <> " " <> phase <> "\trefused\ttrue"]
          readIORef captured `shouldReturn` 1

  it "keeps the place of a read that an arena's closure failed charged until the owner has finished preparing it" $ do
    gate ← newGate
    withRigProbe defaultConfigForRaces (gatedProbe (\p → case p of PointCaptured {} → True; _ → False) gate) $ \rig →
      withWorld (counts [(RequestsPerInstance, 1), (RequestsPerVm, 2)]) (Layout [("lua/main.lua", scriptSource closedCreator), ("lua/attached.lua", scriptSource closedAttached)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \creatorVm →
         withFvm world runtime (presentationOver rig) $ \attachedVm → (`finally` openGate gate) $ do
          creatorSpawn ← spawn world creatorVm "modules-test" mainPath
          -- the creator's arena is published: the attached instance's attach finds it
          untilPrintedBy world creatorSpawn "creator ready"
          attachedSpawn ← spawn world attachedVm "modules-test" "lua/attached.lua"
          -- it reads, and its read is being prepared (the owner is held where it captured its answer) when the creator releases the arena
          untilPrintedBy world attachedSpawn "read issued"
          awaitReached gate
          signalRig rig "close"
          -- the read settles arena_closed; taken, its place is still charged: the owner has not finished with what the read borrowed
          untilPrinted world "after taking\tbusy"
          outLines world >>= \printed → printed `shouldContain` ["settled\tfailure\tarena_closed"]
          pumpUntil world (advanceClock world 2000000000 >> ((>= 3) . length . filter (== "still busy") <$> outLines world))
          outLines world >>= \printed → printed `shouldNotContain` ["free"]
          openGate gate
          untilPrinted world "free"

  forM_
    [ ("the service's closure failed", \_ rig → closeService (rgService rig))
    , ("an epoch cancelled", \fvm _ → void (advanceRequestEpoch (scheduledEndpoint (fvOwner fvm))))
    , ("its instance's end left", \_ _ → pure ())
    ]
    $ \(how, event) →
      it ("does not let an instance end while the owner is still preparing a read that " <> how) $ do
        gate ← newGate
        withRigProbe defaultConfigForRaces (gatedProbe (\p → case p of PointCaptured {} → True; _ → False) gate) $ \rig →
          withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource heldRead)]) $ \world _ runtime →
            withFvm world runtime (presentationOver rig) $ \fvm → (`finally` openGate gate) $ do
              spawned ← spawn world fvm "modules-test" mainPath
              untilPrintedBy world spawned "read issued"
              awaitReached gate
              -- the read is ended some way while the owner is preparing it, and its instance is asked to end
              event fvm rig
              stopSpawned spawned
              pumpUntil world (advanceClock world 2000000000 >> ((== Just Instance.Stopping) <$> phaseOf spawned))
              -- the instance is not over while the owner holds what the read borrowed: its end waits for the work's retirement
              replicateM_ 5 (advanceClock world 2000000000)
              phaseOf spawned >>= (`shouldBe` Just Instance.Stopping)
              openGate gate
              pumpUntil world (advanceClock world 2000000000 >> ((/= Just Instance.Stopping) <$> phaseOf spawned))

  it "refuses a column range over the service's configured level limit as an ordinary error before any bank, with the bank full or free" $ do
    captured ← newIORef (0 ∷ Int)
    let probe = Probe $ \point → case point of
          PointCaptured {} → atomicModifyIORef' captured (\seen → (seen + 1, ()))
          _ → pure ()
        calls = ["api.terrain.column, A, {x = 0, y = 0, z_min = 0, z_max = 2}"]
    withRigProbe defaultConfig {configQueryLimits = defaultQueryLimits {limitRangeLevels = 1}} probe $ \rig →
      withWorld (counts [(RequestsPerInstance, 1), (RequestsPerVm, 1)]) (Layout [("lua/main.lua", scriptSource (permanentUnderPressure calls))]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          forM_ ["full", "free"] $ \phase → printed `shouldContain` ["column " <> phase <> "\trefused\ttrue"]
          readIORef captured `shouldReturn` 1

  it "refuses a column range over the service's per-request region limit as an ordinary error before any bank, with the bank full or free" $ do
    captured ← newIORef (0 ∷ Int)
    let probe = Probe $ \point → case point of
          PointCaptured {} → atomicModifyIORef' captured (\seen → (seen + 1, ()))
          _ → pure ()
        calls = ["api.terrain.column, A, {x = 0, y = 0, z_min = 0, z_max = 96}"]
    withRigProbe fewRegions probe $ \rig →
      withWorld (counts [(RequestsPerInstance, 1), (RequestsPerVm, 1)]) (Layout [("lua/main.lua", scriptSource (permanentUnderPressure calls))]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          forM_ ["full", "free"] $ \phase → printed `shouldContain` ["column " <> phase <> "\trefused\ttrue"]
          readIORef captured `shouldReturn` 1

  it "accepts the cells, columns and surfaces at the edges of the supported coordinate range, so that no region the service would call unsupported is ever demanded" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource edges)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          forM_ ["column at the top", "cell at the top", "surface at the high corner", "surface at the low corner", "cell at the low corner", "remove at the top"] $ \label →
            printed `shouldContain` [label <> "\tsuccess\tok"]

  it "keeps the place of a read that an arena's closure failed before its logical position charged, through the tick that serves it, until the owner has finished preparing it" $ do
    gate ← newGate
    withRigProbe defaultConfigForRaces (gatedProbe (\p → case p of PointCaptured {} → True; _ → False) gate) $ \rig →
      withWorld (counts [(RequestsPerInstance, 1), (RequestsPerVm, 2)]) (Layout [("lua/main.lua", scriptSource closedCreator), ("lua/attached.lua", scriptSource closedAttachedLogical)]) $ \world control runtime →
        withFvm world runtime (presentationOver rig) $ \creatorVm →
          withFvm world runtime (gameplayOver rig) $ \gameplayVm → (`finally` openGate gate) $ do
            creatorSpawn ← spawn world creatorVm "modules-test" mainPath
            untilPrintedBy world creatorSpawn "creator ready"
            _ ← spawn world gameplayVm "modules-test" "lua/attached.lua"
            -- tick 1 settles the attach and issues the read, due at tick 2: the owner is held where the read captured its answer
            pumpUntil world (tickBy control gameplayVm 1 >> (elem "read issued at\t1" <$> outLines world))
            awaitReached gate
            -- the arena is closed under the read before its tick: it fails arena_closed, and its failure waits for its position
            signalRig rig "close"
            pumpUntil world (advanceClock world 2000000000 >> (elem "release\tdone" <$> outLines world))
            -- tick 2 serves it: the instance takes it, and the place is still charged, however many ticks pass, while the owner is held
            pumpUntil world (tickBy control gameplayVm 1 >> (elem "after taking at\t2\tbusy" <$> outLines world))
            outLines world >>= \printed → printed `shouldContain` ["settled at\t2\tfailure\tarena_closed"]
            pumpUntil world (tickBy control gameplayVm 1 >> ((>= 3) . length . filter (== "still busy") <$> outLines world))
            outLines world >>= \printed → printed `shouldNotContain` ["free"]
            openGate gate
            pumpUntil world (tickBy control gameplayVm 1 >> (elem "free" <$> outLines world))

  forM_
    [ ("the service's closure failed", \_ rig → closeService (rgService rig))
    , ("an epoch cancelled", \fvm _ → void (advanceRequestEpoch (scheduledEndpoint (fvOwner fvm))))
    , ("its instance's end left", \_ _ → pure ())
    ]
    $ \(how, event) →
      it ("does not let a gameplay instance end while the owner is still preparing a read, made at a logical position, that " <> how) $ do
        gate ← newGate
        withRigProbe defaultConfigForRaces (gatedProbe (\p → case p of PointCaptured {} → True; _ → False) gate) $ \rig →
          withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource heldReadLogical)]) $ \world control runtime →
            withFvm world runtime (gameplayOver rig) $ \fvm → (`finally` openGate gate) $ do
              spawned ← spawn world fvm "modules-test" mainPath
              pumpUntil world (tickBy control fvm 1 >> (elem "read issued" <$> outLines world))
              awaitReached gate
              event fvm rig
              stopSpawned spawned
              pumpUntil world (tickBy control fvm 1 >> ((== Just Instance.Stopping) <$> phaseOf spawned))
              replicateM_ 3 (tickBy control fvm 1)
              phaseOf spawned >>= (`shouldBe` Just Instance.Stopping)
              openGate gate
              pumpUntil world (tickBy control fvm 1 >> ((/= Just Instance.Stopping) <$> phaseOf spawned))

  forM_
    [ ("an epoch cancelled it", \fvm → void (advanceRequestEpoch (scheduledEndpoint (fvOwner fvm))))
    , ("its instance's end left it", \_ → pure ())
    ]
    $ \(how, event) →
      it ("does not let a gameplay instance end while the owner is still preparing a read, made at a logical position, that an arena's closure failed before its position and " <> how) $ do
        gate ← newGate
        withRigProbe defaultConfigForRaces (gatedProbe (\p → case p of PointCaptured {} → True; _ → False) gate) $ \rig →
          withWorld (counts [(RequestsPerInstance, 1), (RequestsPerVm, 2)]) (Layout [("lua/main.lua", scriptSource closedCreator), ("lua/attached.lua", scriptSource closedAttachedLogical)]) $ \world control runtime →
            withFvm world runtime (presentationOver rig) $ \creatorVm →
              withFvm world runtime (gameplayOver rig) $ \fvm → (`finally` openGate gate) $ do
                creatorSpawn ← spawn world creatorVm "modules-test" mainPath
                untilPrintedBy world creatorSpawn "creator ready"
                spawned ← spawn world fvm "modules-test" "lua/attached.lua"
                pumpUntil world (tickBy control fvm 1 >> (elem "read issued at\t1" <$> outLines world))
                awaitReached gate
                -- the closure fails the read before its position: its failure is held for the tick, and it leaves the provider's work owed
                signalRig rig "close"
                pumpUntil world (advanceClock world 2000000000 >> (elem "release\tdone" <$> outLines world))
                event fvm
                stopSpawned spawned
                pumpUntil world (tickBy control fvm 1 >> ((== Just Instance.Stopping) <$> phaseOf spawned))
                replicateM_ 3 (tickBy control fvm 1)
                phaseOf spawned >>= (`shouldBe` Just Instance.Stopping)
                openGate gate
                pumpUntil world (tickBy control fvm 1 >> ((/= Just Instance.Stopping) <$> phaseOf spawned))

  it "answers a second release of one's own arena without error, before and after the first has retired" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource releasesTwice)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          printed `shouldContain` ["first release\tdone"]
          printed `shouldSatisfy` any (\line → "second release\t" `Text.isPrefixOf` line && any (`Text.isSuffixOf` line) ["retiring", "already_released"])
          printed `shouldContain` ["late release\talready_released"]

  it "refuses, as an ordinary error before anything is admitted, a definition both layers could reject, and settles a definition only the validator rejects" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource precedence)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          printed `shouldContain` ["both layers\tfalse\ttrue", "validator only\tfailure\tdefinition"]
          -- the refused call reached no request: only the validator-only open did, and it left no arena
          limitHeld (rgService rig) "arenas" `shouldReturn` 1

  it "accepts a definition of exactly the validator's 256 KiB and settles one byte-accounted past it as a definition failure" $ do
    mostWithin256KiB `shouldSatisfy` (< 4095)
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource bounded256)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          printed `shouldContain` ["at the bound\tsuccess\tok", "past the bound\tfailure\tdefinition"]

  it "refuses at composition a service configured above 256 KiB of definition, and above 8,192 levels of range, so that no larger definition or range can be accepted" $ do
    refusesComposition defaultConfig {configSourceLimits = defaultSourceLimits {limitDefinitionBytes = 512 * 1024}} "limitDefinitionBytes"
    refusesComposition defaultConfig {configQueryLimits = defaultQueryLimits {limitRangeLevels = 16384}} "limitRangeLevels"

  it "enforces a service's smaller definition limit through Lua: a definition within 256 KiB but over the service's limit is a definition failure" $
    withRigConfig defaultConfig {configSourceLimits = defaultSourceLimits {limitDefinitionBytes = 128 * 1024}} $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource bounded256)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          printed `shouldContain` ["at the bound\tfailure\tdefinition", "past the bound\tfailure\tdefinition"]

  it "leaves the creator alive and its arena served when an attached instance ends" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource sharedCreator)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          attached ← spawn world fvm "modules-test" mainPath
          untilPrinted world "attached\tsuccess"
          stopSpawned attached
          seen ← length . filter (== "creator read\tsuccess") <$> outLines world
          pumpUntil world (advanceClock world 2000000000 >> ((> seen + 2) . length . filter (== "creator read\tsuccess") <$> outLines world))
          limitHeld (rgService rig) "arenas" `shouldReturn` 1

  it "refuses another instance's captured api.terrain table as an ordinary error" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource capturedFacade)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          outLines world >>= \printed → printed `shouldSatisfy` any (\line → "captured facade\tfalse\t" `Text.isPrefixOf` line)

  it "still permits cancel, release and an orderly end with the request queue full" $
    withRig $ \rig →
      withWorld (counts [(RequestsPerInstance, 2), (RequestsPerVm, 2)]) (Layout [("lua/main.lua", scriptSource fullQueue)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          printed `shouldContain` ["full\t2"]
          printed `shouldSatisfy` any (\line → "cancel\t" `Text.isPrefixOf` line)
          printed `shouldContain` ["release\tdone"]
          stopSpawned spawned
          settledFailure spawned >>= \failure → isJust failure `shouldBe` False
          limitHeld (rgService rig) "arenas" `shouldReturn` 0

  it "does not weaken the failure of an unrelated required request: an unread terrain failure fails nothing, and the required one still fails the instance" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource unrelatedRequired)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          pumpUntil world (advanceClock world 2000000000 >> ((== Just Instance.Failed) <$> phaseOf spawned))
          printed ← outLines world
          -- five updates ran with the unread failure settled; only the required request's failure ended the instance
          printed `shouldContain` ["alive\t5"]
          failure ← settledFailure spawned
          fmap fst (requestFailureOf failure) `shouldBe` Just "data"
