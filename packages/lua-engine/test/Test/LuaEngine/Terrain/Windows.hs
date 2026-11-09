{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | The windows between a request's commit and its settlement, the session's gate in the commit, the service's banks seen through Lua,
-- the ownership of a handle after many have been issued, and the order of logical reads after a removal. The terrain owner and the
-- adapter are held at named points by gates, so an example decides which side wins by what it does and never by how long it waits.
module Test.LuaEngine.Terrain.Windows (spec) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, finally, try)
import Control.Monad (unless)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Profile (CountLimit (LuaIntegerMaximum))
import Hetoimasia.LuaEngine.Terrain (TerrainFacade (..), TerrainHooks (..), noTerrainHooks)
import Test.LuaEngine.Request.Profiles (counts)
import Hetoimasia.Terrain.Residency (LimitsSpec (..), mkLimits)
import Hetoimasia.Terrain.Runtime
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

-- | An instance that opens an arena one below the revision ceiling and removes an air cell, a solid cell, and then another solid cell.
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
        , "  if r then print('solid removal', r.status, r.value.changed, r.value.revision) self.r = api.terrain.remove(self.arena, {x = 0, y = 0, z = -1}) print('issued') self.s = 3 end"
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
    (_, ExceptionWithContext _ raised) ←
      fatalWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource remover)]) $ \world _ runtime →
        withRigConfig defaultConfig {configFirstRevision = 9223372036854775807} $ \rig →
          withFvm world runtime (presentationOver rig) $ \fvm → do
            _ ← spawn world fvm "modules-test" mainPath
            untilPrinted world "issued"
            -- the owner fails at its next boundary, and the failure is the host's defect
            failed ← try @SomeException (pumpUntil world (advanceClock world 2000000000 >> (pure False)))
            either (\failure → show failure `shouldSatisfy` Text.isInfixOf "ProviderDefect" . Text.pack) (const (expectationFailure "the owner did not fail")) failed
            -- nothing was committed: an observer of the service, which is alive, finds the cell as it was, at the revision it had
            observeCell rig (arenaName rig "modules-test" "main") (0, 0, 0) `shouldReturn` (9223372036854775807, Just "soil")
    show raised `shouldSatisfy` Text.isInfixOf "ProviderDefect" . Text.pack

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

  it "lets removals through up to the revision ceiling, air included, and refuses the one that could pass it with nothing committed" $ do
    (_, ExceptionWithContext _ raised) ←
      fatalWorld (counts [(LuaIntegerMaximum, 40)]) (Layout [("lua/main.lua", scriptSource atCeiling)]) $ \world _ runtime →
        withRigConfig defaultConfig {configFirstRevision = 39} $ \rig →
          withFvm world runtime (presentationOver rig) $ \fvm → do
            _ ← spawn world fvm "modules-test" mainPath
            untilPrinted world "issued"
            printed ← outLines world
            -- below the ceiling air changes nothing, and a solid cell takes the revision to the ceiling itself
            printed `shouldContain` ["air removal\tsuccess\tfalse\t39", "solid removal\tsuccess\ttrue\t40"]
            -- the arena stands at the ceiling: the next removal could pass it and is refused, a defect of the host's
            failed ← try @SomeException (pumpUntil world (advanceClock world 2000000000 >> (pure False)))
            either (\failure → show failure `shouldSatisfy` Text.isInfixOf "ProviderDefect" . Text.pack) (const (expectationFailure "the owner did not fail")) failed
            observeCell rig (arenaName rig "modules-test" "c") (0, 0, -1) `shouldReturn` (40, Just "soil")
    show raised `shouldSatisfy` Text.isInfixOf "ProviderDefect" . Text.pack

  it "gives a logical read ordered after a removal of the same cell the post-removal value and revision, reads prepared before the commit included" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource ordered)]) $ \world control runtime →
        withFvm world runtime (gameplayOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          pumpUntil world (tickBy control fvm 1 >> (elem "surface\t1\t-1\tsoil" <$> outLines world))
          printed ← outLines world
          printed `shouldContain` ["removal\tsuccess\ttrue\t1"]
          printed `shouldContain` ["cell\ttrue\t1"]
          printed `shouldContain` ["column\t1\t-5:-3:false,-3:0:false,0:3:true"]
