{-# LANGUAGE OverloadedStrings #-}

-- | The windows between a request's commit and its settlement, the session's gate in the commit, the service's banks seen through Lua,
-- the ownership of a handle after many have been issued, and the order of logical reads after a removal. The terrain owner and the
-- adapter are held at named points by gates, so an example decides which side wins by what it does and never by how long it waits.
module Test.LuaEngine.Terrain.Windows (spec) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), finally)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Terrain (TerrainHooks (..), noTerrainHooks)
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
            pumpUntil world (advanceClock world 2000000000 >> (pure False))
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
