{-# LANGUAGE OverloadedStrings #-}

-- | The storage outcomes of the terrain facade (TRA-23) over the production backed service, with faults injected at its storage
-- seam: every new expected code read and unread in both roles, the pause and its explicit recovery, storage_full and the growth out
-- of it, and the windows of a growth (held at its reservation, cancelled before and after its commit, its extra's give-back failed).
-- A native call is failed or held by the seam ("Test.LuaEngine.Terrain.Seam"); the script waits at @TEST_WAIT@ while the example
-- arranges the next fault, so every outcome is decided by what the example does and never by time.
module Test.LuaEngine.Terrain.StorageFaults (spec) where

import Control.Concurrent.STM (atomically, check, readTVarIO)
import Control.Exception (finally, onException)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Terrain (noTerrainHooks)
import Hetoimasia.Terrain.Coordinate (decomposeTile, mkLocalCoord, tileCoord)
import Hetoimasia.Terrain.Residency (RegionDemand (..), Revision (..), coverageTile)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Store (StoreSpec (..), maxClaimPages, pageSize, reservePages)
import qualified Hetoimasia.Scripting.Lua.Instance as Instance
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Seam
import Test.LuaEngine.Terrain.Support
import Test.Support.Bounded (bounded)

mib ∷ Integer → Integer
mib n = n * 1024 * 1024

storagePrelude ∷ [Text]
storagePrelude =
  [ "local MIB = 1024 * 1024"
  , -- a valid source too complex to prepare: 1,024 one-level patches two levels apart in one column
    "local P = {}"
  , "for k = 0, 1023 do P[#P + 1] = { x = 0, y = 0, z_min = 2 * k, z_max = 2 * k + 1, value = { material = 'soil', shape = 0 } } end"
  , "local COMPLEX = { materials = { 'soil' }, layers = {}, patches = P }"
  , "local function codes(list) return '{' .. table.concat(list, ',') .. '}' end"
  , "local function brief(v) return v.storage.state .. ' ' .. tostring(v.storage.reason) .. ' ' .. v.discovery.state end"
  ]

-- | Wait until every request the service holds has settled, then until its backed work is at rest.
quiescent ∷ Service → IO ()
quiescent svc =
  bounded (atomically (inspectCensusSTM svc >>= check . all censusSettled . censusRequests) >> atomically (backedAtRestSTM svc >>= check))
    `onException` do
      census ← atomically (inspectCensusSTM svc)
      problems ← inspectBacked svc
      defects ← inspectDefects svc
      jobs ← atomically (inspectStorageJobsSTM svc)
      putStrLn ("not quiescent: settled " <> show (map censusSettled (censusRequests census)) <> "; backed " <> show problems <> "; defects " <> show defects <> "; storage jobs " <> show jobs)

-- | Drive the world until the condition holds, testing it before each drive: a script held at @TEST_WAIT@ is never driven again.
driveUntil ∷ World → IO () → IO Bool → IO ()
driveUntil world drive condition = pumpUntil world (condition >>= \done → if done then pure True else drive >> condition)

-- | When the script reaches @TEST_WAIT(name)@: the service quiescent, this done, and the script let go.
atWait ∷ Rig → World → IO () → Text → IO () → IO ()
atWait rig world drive name action = do
  driveUntil world drive (elem ("entered " <> name) <$> readTVarIO (rgTrace rig))
  quiescent (rgService rig)
  action
  signalRig rig name

-- | 'atWait', answering what the action made.
atWaitGate ∷ Rig → World → IO () → Text → IO a → IO a
atWaitGate rig world drive name action = do
  driveUntil world drive (elem ("entered " <> name) <$> readTVarIO (rgTrace rig))
  quiescent (rgService rig)
  made ← action
  signalRig rig name
  pure made

-- | The gates an example armed, opened on every exit so that no held worker keeps the service's drain waiting.
newtype Held = Held (IORef [SeamGate])

newHeld ∷ IO Held
newHeld = Held <$> newIORef []

holdIn ∷ Held → SeamGate → IO ()
holdIn (Held ref) gate = modifyIORef' ref (gate :)

openHeld ∷ Held → IO ()
openHeld (Held ref) = readIORef ref >>= mapM_ openSeamGate

-- | Say what the scripts printed and where they waited, when an example fails.
explained ∷ Rig → World → IO a → IO a
explained rig world body =
  body `onException` do
    printed ← outLines world
    trace ← readTVarIO (rgTrace rig)
    warned ← errLines world
    putStrLn ("warned: " <> show warned)
    putStrLn ("printed: " <> show printed)
    putStrLn ("trace: " <> show (reverse trace))

-- | Every new expected code, read and unread, through one creator: the three of an open, the three of a paused arena and its
-- recovery, with the status after each, and nothing failed repeated.
faultSteps ∷ Script
faultSteps =
  stepsScript
    "DEF"
    storagePrelude
    [ Step "complex unread" "api.terrain.open('c1', COMPLEX) return nil" "return 'ok'"
    , Step "complex" "return api.terrain.open('c2', COMPLEX)" "return 'ok'"
    , Step "unsupported" "TEST_WAIT('unsupported') api.terrain.open('u1', DEF) return api.terrain.open('u2', DEF)" "return 'ok'"
    , Step "reservation" "TEST_WAIT('reservation') api.terrain.open('r1', DEF) return api.terrain.open('r2', DEF)" "return 'ok'"
    , Step "names free" "TEST_WAIT('clear') return api.terrain.open('u2', DEF)" "return 'ok'"
    , Step "reopened released" "print('reopened release', api.terrain.release(V['names free'])) return nil" "return 'ok'"
    , Step "history" "return api.terrain.remove(A, {x = 3, y = 4, z = 0})" "return tostring(v.changed)"
    , Step "io" "TEST_WAIT('io') return api.terrain.remove(A, {x = 3, y = 4, z = -1})" "return 'ok'"
    , Step "io unread" "api.terrain.remove(A, {x = 5, y = 5, z = 0}) return nil" "return 'ok'"
    , Step "paused removal" "return api.terrain.remove(A, {x = 6, y = 6, z = 0})" "return 'ok'"
    , Step "status io" "TEST_WAIT('io settled') return api.terrain.status(A)" "return brief(v)"
    , Step "integrity" "TEST_WAIT('integrity') return api.terrain.cell(A, {x = 3, y = 4, z = -2})" "return 'ok'"
    , Step "integrity unread" "TEST_WAIT('integrity again') api.terrain.cell(A, {x = 3, y = 4, z = -3}) return nil" "return 'ok'"
    , Step "status both" "TEST_WAIT('both settled') return api.terrain.status(A)" "return brief(v)"
    , Step "grow while paused" "return api.terrain.grow_storage(A, 96 * MIB)" "return tostring(v.changed) .. ' ' .. v.reserved_bytes .. ' ' .. v.storage.state .. ' ' .. tostring(v.storage.reason)"
    , Step "retry persistent" "TEST_WAIT('persist') return api.terrain.retry_storage(A)" "return tostring(v.changed) .. ' ' .. codes(v.cleared) .. ' ' .. codes(v.remaining) .. ' ' .. v.storage.state .. ' ' .. tostring(v.storage.reason)"
    , Step "retry integrity" "TEST_WAIT('heal') return api.terrain.retry_storage(A)" "return tostring(v.changed) .. ' ' .. codes(v.cleared) .. ' ' .. codes(v.remaining) .. ' ' .. v.storage.state .. ' ' .. tostring(v.storage.reason)"
    , Step "retry io" "return api.terrain.retry_storage(A)" "return tostring(v.changed) .. ' ' .. codes(v.cleared) .. ' ' .. codes(v.remaining) .. ' ' .. v.storage.state .. ' ' .. tostring(v.storage.reason)"
    , Step "retry ready" "return api.terrain.retry_storage(A)" "return tostring(v.changed) .. ' ' .. codes(v.cleared) .. ' ' .. codes(v.remaining) .. ' ' .. v.storage.state"
    , Step "not repeated" "return api.terrain.cell(A, {x = 3, y = 4, z = -1})" "return tostring(v.air) .. ' ' .. tostring(v.material)"
    , Step "removal again" "return api.terrain.remove(A, {x = 3, y = 4, z = -1})" "return tostring(v.changed)"
    , Step "status ready" "TEST_WAIT('end') return api.terrain.status(A)" "return brief(v)"
    ]

faultExpected ∷ [Text]
faultExpected =
  [ "complex\tfailure\tsource_complexity"
  , "unsupported\tfailure\tstorage_unsupported"
  , "reservation\tfailure\treservation_failed"
  , "names free\tsuccess\tok"
  , "reopened release\tdone"
  , "history\tsuccess\ttrue"
  , "io\tfailure\tstorage_io"
  , "paused removal\tfailure\tstorage_io"
  , "status io\tsuccess\tpaused storage_io idle"
  , "integrity\tfailure\tstorage_integrity"
  , "status both\tsuccess\tpaused storage_integrity idle"
  , "grow while paused\tsuccess\ttrue 100663296 paused storage_integrity"
  , "retry persistent\tsuccess\tfalse {} {storage_integrity,storage_io} paused storage_integrity"
  , "retry integrity\tsuccess\ttrue {storage_integrity} {storage_io} paused storage_io"
  , "retry io\tsuccess\ttrue {storage_io} {} ready nil"
  , "retry ready\tsuccess\tfalse {} {} ready"
  , "not repeated\tsuccess\tfalse soil"
  , "removal again\tsuccess\ttrue"
  , "status ready\tsuccess\tready nil idle"
  , "done"
  ]

-- | The storage_full trace through Lua: buried removals, one an update, while a reader the example holds pins an old version, until
-- one settles storage_full; another, read and unread, while it holds; the status; then growth out of it while it is paused.
fullScript ∷ Script
fullScript =
  script
    { scPrelude = terrainPrelude <> storagePrelude <> ["local CELLS = {}", "for z = -31, -1 do for y = 0, 15 do for x = 0, 15 do CELLS[#CELLS + 1] = {x = x, y = y, z = z} end end end"]
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF, { storage_bytes = 64 * MIB })", "self.i = 0", "self.n = 0"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.a = t.value self.q = api.terrain.remove(self.a, {x = 0, y = 0, z = -32}) self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  if settle(api, self.q) then TEST_WAIT('pin') self.q = nil self.s = 2 end"
        , "elseif self.s == 2 then"
        , "  if self.q then"
        , "    local t = settle(api, self.q)"
        , "    if t then"
        , "      if t.status == 'success' then self.n = self.n + 1 self.q = nil"
        , "      else print('full', t.error.code) self.full = CELLS[self.i] self.q = nil self.s = 3 end"
        , "    end"
        , "  else self.i = self.i + 1 self.q = api.terrain.remove(self.a, CELLS[self.i]) end"
        , "elseif self.s == 3 then"
        , "  api.terrain.remove(self.a, CELLS[self.i + 2])"
        , "  self.q = api.terrain.remove(self.a, CELLS[self.i + 1]) self.s = 4"
        , "elseif self.s == 4 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('again', t.status, t.error and t.error.code) self.q = api.terrain.status(self.a) self.s = 5 end"
        , "elseif self.s == 5 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('status', t.value.storage.state, t.value.storage.reason, t.value.storage.reserved_bytes) print('discovery', t.value.discovery.state, t.value.discovery.pending_items > 0) TEST_WAIT('unpin') self.q = api.terrain.grow_storage(self.a, 128 * MIB) self.s = 6 end"
        , "elseif self.s == 6 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('grown', t.status, t.value.changed, t.value.reserved_bytes, t.value.storage.state) self.q = api.terrain.cell(self.a, self.full) self.s = 7 end"
        , "elseif self.s == 7 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('refused cell', t.value.air) self.q = api.terrain.remove(self.a, {x = 9, y = 9, z = -2}) self.s = 8 end"
        , "elseif self.s == 8 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('resumed', t.status, t.value.changed) print('committed before the pause', self.n > 0) TEST_WAIT('end') self.q = api.terrain.status(self.a) self.s = 9 end"
        , "elseif self.s == 9 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('final', t.value.storage.state, t.value.discovery.state, t.value.discovery.pending_items) print('done') self.s = 10 end"
        , "end"
        ]
    }

-- | A growth held at its reservation and cancelled, one whose extra's give-back fails, and the largest allowance a script may name
-- refused its reservation: the old allowance stands until a commit wins.
growthScript ∷ Script
growthScript =
  stepsScript
    "DEF"
    storagePrelude
    [ Step "ready" "TEST_WAIT('ready') return nil" "return 'ok'"
    , Step "held" "local r = api.terrain.grow_storage(A, 128 * MIB) V.held = r TEST_WAIT('held') return nil" "return 'ok'"
    , Step "status while held" "return api.terrain.status(A)" "return v.storage.reserved_bytes .. ' ' .. v.storage.pending_reserved_bytes"
    , Step "cancel while held" "print('cancel while held', api.request.cancel(V.held)) TEST_WAIT('released') return api.terrain.status(A)" "return v.storage.reserved_bytes .. ' ' .. v.storage.pending_reserved_bytes .. ' ' .. v.storage.state"
    , Step "committed" "local r, e = api.terrain.grow_storage(A, 96 * MIB) if r == nil then print('committed busy', e.code, e.message) end return r" "return tostring(v.changed) .. ' ' .. v.reserved_bytes"
    , Step "cancel after the commit" "local r, e = api.terrain.grow_storage(A, 112 * MIB) if r == nil then print('cancel after the commit busy', e.code, e.message) return nil end api.request.wait(r) print('cancel after the commit', api.request.cancel(r)) return r" "return v.reserved_bytes"
    , Step "extra kept" "TEST_WAIT('arm') local r = api.terrain.grow_storage(A, 160 * MIB) V.kept = r TEST_WAIT('allocated') print('cancel allocated', api.request.cancel(r)) TEST_WAIT('give-back failed') return api.terrain.status(A)" "return v.storage.reserved_bytes .. ' ' .. v.storage.pending_reserved_bytes"
    , Step "retry releases the extra" "return api.terrain.retry_storage(A)" "return tostring(v.changed) .. ' ' .. v.storage.state"
    , Step "extra released" "TEST_WAIT('extra released') return api.terrain.status(A)" "return v.storage.reserved_bytes .. ' ' .. v.storage.pending_reserved_bytes"
    , Step "largest refused" "TEST_WAIT('largest') return api.terrain.grow_storage(A, math.maxinteger - MIB + 1)" "return 'ok'"
    , Step "largest open refused" "return api.terrain.open('largest', DEF, { storage_bytes = math.maxinteger - MIB + 1 })" "return 'ok'"
    , Step "after the largest" "TEST_WAIT('cleared') return api.terrain.status(A)" "return v.storage.reserved_bytes .. ' ' .. v.storage.pending_reserved_bytes .. ' ' .. v.storage.state"
    , Step "grown at last" "return api.terrain.grow_storage(A, 160 * MIB)" "return tostring(v.changed) .. ' ' .. v.reserved_bytes"
    ]

spec ∷ Spec
spec = outcomesSpec >> lifecycleSpec

outcomesSpec ∷ Spec
outcomesSpec = describe "Terrain storage outcomes" $ do
  describe "every new expected code, read and unread, and an explicit recovery that repeats nothing" $
    mapM_
      ( \(role, over, drive) →
          it ("from a " <> role <> " creator, the next update running after each") $ do
            faults ← newFaults
            withRigPort defaultConfig noProbe noTerrainHooks (seamPort faults) $ \rig →
              withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource faultSteps)]) $ \world control runtime →
                withFvm world runtime (over rig) $ \fvm → explained rig world $ do
                  spawned ← spawn world fvm "modules-test" mainPath
                  let go = drive world control fvm
                      wait = atWait rig world go
                  wait "unsupported" (addRule faults (-1) isStatFs (FilesystemIs "unqualified"))
                  wait "reservation" (clearRules faults >> addRule faults (-1) isReserve (FailWith 28))
                  wait "clear" (clearRules faults)
                  wait "io" (addRule faults 1 isWrite (FailWith 5))
                  wait "io settled" (pure ())
                  wait "integrity" (addRule faults 1 isRead ZeroBytes)
                  wait "integrity again" (addRule faults 1 isRead ZeroBytes)
                  wait "both settled" (pure ())
                  wait "persist" (addRule faults (-1) isRead ZeroBytes)
                  wait "heal" (clearRules faults)
                  wait "end" (pure ())
                  driveUntil world go (elem "done" <$> outLines world)
                  printed ← outLines world
                  [l | l ← printed, not ("unread" `Text.isInfixOf` l)] `shouldBe` faultExpected
                  -- nothing failed the instance: it is still running, and only its one arena is open
                  phaseOf spawned >>= (`shouldNotBe` Just Instance.Failed)
                  limitHeld (rgService rig) "arenas" `shouldReturn` 1
      )
      [ ("presentation", presentationOver, \world _ _ → advanceClock world 2000000000)
      , ("gameplay", gameplayOver, \_ _ fvm → grantTick fvm)
      ]

  it "settles a removal storage_full, read and unread, while a reader pins old history, reports the pause, and grows out of it while paused" $ do
    faults ← newFaults
    let usable = toInteger reservePages + toInteger maxClaimPages + 1 + 128
        config = defaultConfig {configStore = (configStore defaultConfig) {specAllowanceBytes = mib 64, specOverheadBytes = Just (mib 64 - usable * toInteger pageSize)}}
    withRigPort config noProbe noTerrainHooks (seamPort faults) $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource fullScript)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → explained rig world $ do
          _ ← spawn world fvm "modules-test" mainPath
          let svc = rgService rig
              go = advanceClock world 2000000000
          observer ← either (fail . show) pure =<< registerClient svc
          held ← newHeld
          (`finally` openHeld held) $ do
            -- the pin: a view's load job whose page read is held, in a region far from the removals (armed once the service is at
            -- rest, so the one read it holds is the load's)
            atWait rig world go "pin" $ do
              gate ← addSeamGateOnce faults isRead
              holdIn held gate
              lease ← attachArena svc observer (arenaName rig "modules-test" "main") >>= either (fail . show) pure >>= await svc >>= either (fail . show) pure
              view ← openView svc observer >>= either (fail . show) pure
              let (far, _) = decomposeTile (either (error . show) id (tileCoord 100 100 0))
              _ ← setViewDemand svc view lease [RegionDemand far (either (error . show) coverageTile (mkLocalCoord 0 0 0))] >>= either (fail . show) pure
              awaitSeamGate gate
            driveUntil world go (elem "full\tstorage_full" <$> outLines world)
            driveUntil world go (any ("status\t" `Text.isPrefixOf`) <$> outLines world)
            -- the pin goes, and growth clears the capacity pause
            openHeld held
            atWait rig world go "unpin" (endClient svc observer)
          atWait rig world go "end" (pure ())
          driveUntil world go (elem "done" <$> outLines world)
          printed ← outLines world
          -- discovery is paused with the storage exactly when it has obligations left, and idle otherwise
          let discovery = if "discovery\tpaused\ttrue" `elem` printed then "discovery\tpaused\ttrue" else "discovery\tidle\tfalse"
          printed
            `shouldBe` [ "full\tstorage_full"
                       , "again\tfailure\tstorage_full"
                       , "status\tpaused\tstorage_full\t" <> Text.pack (show (mib 64))
                       , discovery
                       , "grown\tsuccess\ttrue\t" <> Text.pack (show (mib 128)) <> "\tready"
                       , "refused cell\tfalse"
                       , "resumed\tsuccess\ttrue"
                       , "committed before the pause\ttrue"
                       , "final\tready\tidle\t0"
                       , "done"
                       ]

  it "keeps the old allowance while a growth is held at its reservation and after it is cancelled, keeps an extra whose give-back failed charged and visible, and refuses the largest allowance's reservation" $ do
    faults ← newFaults
    withRigPort defaultConfig noProbe noTerrainHooks (seamPort faults) $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource growthScript)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → explained rig world $ do
          _ ← spawn world fvm "modules-test" mainPath
          let go = advanceClock world 2000000000
              svc = rgService rig
          held ← newHeld
          (`finally` openHeld held) $ do
            reserve ← atWaitGate rig world go "ready" (addSeamGate faults isReserve)
            holdIn held reserve
            driveUntil world go (elem "entered held" <$> readTVarIO (rgTrace rig))
            awaitSeamGate reserve
            signalRig rig "held"
            driveUntil world go (elem "entered released" <$> readTVarIO (rgTrace rig))
            openSeamGate reserve
            quiescent svc
            signalRig rig "released"
          kept ← newHeld
          (`finally` openHeld kept) $ do
            allocated ← atWaitGate rig world go "arm" (addSeamGateAfter faults isReserve)
            holdIn kept allocated
            driveUntil world go (elem "entered allocated" <$> readTVarIO (rgTrace rig))
            awaitSeamGate allocated
            signalRig rig "allocated"
            -- the give-back is the next length set: it fails
            driveUntil world go (any ("cancel allocated" `Text.isPrefixOf`) <$> outLines world)
            addRule faults 1 isSetLength (FailWith 5)
            openSeamGate allocated
            driveUntil world go (elem "entered give-back failed" <$> readTVarIO (rgTrace rig))
            quiescent svc
            signalRig rig "give-back failed"
          atWait rig world go "extra released" (pure ())
          atWait rig world go "largest" (addRule faults (-1) isReserve (FailWith 28) >> addRule faults (-1) isSetLength (FailWith 27))
          atWait rig world go "cleared" (clearRules faults)
          driveUntil world go (any ("grown at last\t" `Text.isPrefixOf`) <$> outLines world)
          printed ← outLines world
          let bytes = Text.pack . show . mib
          printed
            `shouldBe` [ "status while held\tsuccess\t" <> bytes 64 <> " 0"
                       , "cancel while held\tcancelled"
                       , "cancel while held\tsuccess\t" <> bytes 64 <> " 0 ready"
                       , "committed\tsuccess\ttrue " <> bytes 96
                       , "cancel after the commit\talready_settled"
                       , "cancel after the commit\tsuccess\t" <> bytes 112
                       , "cancel allocated\tcancelled"
                       , "extra kept\tsuccess\t" <> bytes 112 <> " " <> bytes 48
                       , "retry releases the extra\tsuccess\tfalse ready"
                       , "extra released\tsuccess\t" <> bytes 112 <> " 0"
                       , "largest refused\tfailure\treservation_failed"
                       , "largest open refused\tfailure\treservation_failed"
                       , "after the largest\tsuccess\t" <> bytes 112 <> " 0 ready"
                       , "grown at last\tsuccess\ttrue " <> bytes 160
                       ]

-- | A status in the form the scripts print it ('show' of the copied record): what the service's own status says, rendered by the
-- example, to compare with what the script was handed at the same moment.
rendered ∷ ArenaStatus → Text
rendered s =
  "{content_revision="
    <> revision (statusContentRevision s)
    <> ",discovery={pending_items="
    <> figure (statusPendingItems s)
    <> ",state="
    <> discovery
    <> "},knowledge_revision="
    <> revision (statusKnowledgeRevision s)
    <> ",storage={pending_reclaim_bytes="
    <> figure (statusPendingReclaimBytes s)
    <> ",pending_reserved_bytes="
    <> figure (statusPendingReservedBytes s)
    <> reason
    <> ",reserved_bytes="
    <> figure (statusReservedBytes s)
    <> ",state="
    <> state
    <> ",used_bytes="
    <> figure (statusUsedBytes s)
    <> "}}"
  where
    figure = Text.pack . show
    revision (Revision w) = figure w
    discovery = case statusDiscovery s of
      DiscoveryIdle → "idle"
      DiscoveryPending → "pending"
      DiscoveryPaused → "paused"
    (state, reason) = case statusStorage s of
      StorageReady → ("ready", "")
      StoragePaused conds → ("paused", ",reason=" <> worst conds)
    worst conds
      | CondIntegrity `elem` conds = "storage_integrity"
      | CondIo `elem` conds = "storage_io"
      | otherwise = "storage_full"

-- | Each status the script takes, printed under its label, at a moment the example holds still: fresh, after an edit, while discovery
-- of the edit is held, while a reader pins retired history, once the pin has gone, and after its own copy was changed.
statusSteps ∷ Script
statusSteps =
  stepsScript
    "DEF"
    storagePrelude
    [ Step "fresh" "TEST_WAIT('fresh') return api.terrain.status(A)" "return show(v)"
    , Step "edit" "TEST_WAIT('edit') return api.terrain.remove(A, {x = 0, y = 0, z = 0})" "return 'ok'"
    , Step "after the edit" "TEST_WAIT('after the edit') return api.terrain.status(A)" "return show(v)"
    , Step "edit held" "TEST_WAIT('arm discovery') return api.terrain.remove(A, {x = 1, y = 0, z = 0})" "return 'ok'"
    , Step "discovery held" "TEST_WAIT('discovery held') return api.terrain.status(A)" "return show(v)"
    , Step "pinned edits" "TEST_WAIT('pin') for i = 2, 9 do api.terrain.remove(A, {x = i, y = 0, z = 0}) end return api.terrain.remove(A, {x = 10, y = 0, z = 0})" "return 'ok'"
    , Step "pinned" "TEST_WAIT('pinned') return api.terrain.status(A)" "return v.storage.pending_reclaim_bytes .. ' ' .. v.storage.used_bytes"
    , Step "unpinned" "TEST_WAIT('unpinned') return api.terrain.status(A)" "return show(v)"
    , Step "copy changed" "return api.terrain.status(A)" "v.storage.reserved_bytes = 1 v.storage.state = 'changed' v.extra = true return 'changed'"
    , Step "copy again" "return api.terrain.status(A)" "return show(v)"
    ]

-- | A gameplay creator whose growth is prepared before its position and committed at it, and another cancelled before it; beside it, a
-- presentation instance that runs while the gameplay owner waits.
logicalGrowth ∷ Script
logicalGrowth =
  script
    { scPrelude = terrainPrelude <> storagePrelude
    , scInit = ["self.s = 0", "if api.role == 'gameplay' then self.q = api.terrain.open('main', DEF) end", "self.n = 0"]
    , scUpdate =
        [ "if api.role == 'presentation' then self.n = self.n + 1 print('presentation', self.n) return end"
        , "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.a = t.value self.q = api.terrain.grow_storage(self.a, 96 * MIB) print('asked') self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    print('grown', t.status, t.value.changed, t.value.reserved_bytes)"
        , "    local r = api.terrain.grow_storage(self.a, 128 * MIB)"
        , "    print('cancel before its position', api.request.cancel(r))"
        , "    self.q = api.terrain.status(self.a) self.s = 2"
        , "  end"
        , "elseif self.s == 2 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('after the cancel', t.value.storage.reserved_bytes) print('done') self.s = 3 end"
        , "end"
        ]
    }

-- | A creator whose growth is held at its reservation when its instance is stopped.
growthAtEnd ∷ Script
growthAtEnd =
  script
    { scPrelude = terrainPrelude <> storagePrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.a = t.value TEST_WAIT('arm') self.g = api.terrain.grow_storage(self.a, 128 * MIB) TEST_WAIT('held') print('held') self.s = 1 end"
        , "end"
        ]
    }

lifecycleSpec ∷ Spec
lifecycleSpec = describe "Terrain storage status and lifetimes" $ do
  it "hands a script the service's own coherent status: fresh, after an edit, while discovery is pending, while a reader pins retired history and after, and a copy whose change changes nothing" $ do
    faults ← newFaults
    discoveryGate ← newGate
    disarmGate discoveryGate
    let selects = \case PointDiscoveryGranted {} → True; _ → False
    pinned ← newHeld
    (`finally` (openGate discoveryGate >> openHeld pinned)) $
      withRigPort defaultConfig (gatedProbe selects discoveryGate) noTerrainHooks (seamPort faults) $ \rig →
        withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource statusSteps)]) $ \world _ runtime →
          withFvm world runtime (presentationOver rig) $ \fvm → explained rig world $ do
            _ ← spawn world fvm "modules-test" mainPath
            let svc = rgService rig
                go = advanceClock world 2000000000
                -- the script reaches its next wait in the very update it printed the status it took: what it printed is published when
                -- that update returns, so each status is compared at the end, with the service's own status read while the script waited
                reached name = driveUntil world go (elem ("entered " <> name) <$> readTVarIO (rgTrace rig))
            observer ← either (fail . show) pure =<< registerClient svc
            lease ← attachArena svc observer (arenaName rig "modules-test" "main") >>= either (fail . show) pure >>= await svc >>= either (fail . show) pure
            let ownStatus = arenaStatus svc lease >>= either (fail . show) pure
            atWait rig world go "fresh" (pure ())
            reached "edit"
            fresh ← ownStatus
            signalRig rig "edit"
            atWait rig world go "after the edit" (pure ())
            reached "arm discovery"
            edited ← ownStatus
            (statusContentRevision edited, statusUsedBytes edited > statusUsedBytes fresh) `shouldBe` (Revision 1, True)
            -- discovery of the next edit is held at its grant: its obligations are pending, and the status says so without waiting for it
            armGate discoveryGate
            signalRig rig "arm discovery"
            reached "discovery held"
            awaitReached discoveryGate
            signalRig rig "discovery held"
            reached "pin"
            discovering ← ownStatus
            (statusDiscovery discovering, statusPendingItems discovering > 0) `shouldBe` (DiscoveryPending, True)
            openGate discoveryGate
            quiescent svc
            -- a reader pins an old version (a view's load, its page read held): what later edits retire cannot be reclaimed
            gate ← addSeamGateOnce faults isRead
            holdIn pinned gate
            view ← openView svc observer >>= either (fail . show) pure
            let (far, _) = decomposeTile (either (error . show) id (tileCoord 100 100 0))
            _ ← setViewDemand svc view lease [RegionDemand far (either (error . show) coverageTile (mkLocalCoord 0 0 0))] >>= either (fail . show) pure
            awaitSeamGate gate
            signalRig rig "pin"
            reached "pinned"
            bounded (atomically (inspectCensusSTM svc >>= check . all censusSettled . censusRequests))
            signalRig rig "pinned"
            reached "unpinned"
            held ← ownStatus
            statusPendingReclaimBytes held `shouldSatisfy` (> 0)
            -- the pin goes: the view closes, its held read returns, and the service reclaims what was retired
            clearViewDemand svc view >>= either (fail . show) pure
            closeView svc view
            openHeld pinned
            quiescent svc
            released ← ownStatus
            statusPendingReclaimBytes released `shouldSatisfy` (< statusPendingReclaimBytes held)
            signalRig rig "unpinned"
            driveUntil world go (elem "done" <$> outLines world)
            printed ← outLines world
            printed
              `shouldContain` [ "fresh\tsuccess\t" <> rendered fresh
                              , "edit\tsuccess\tok"
                              , "after the edit\tsuccess\t" <> rendered edited
                              , "edit held\tsuccess\tok"
                              , "discovery held\tsuccess\t" <> rendered discovering
                              ]
            -- the reading under the pin: retired history waiting to be reclaimed, a part of what is used
            case [Text.words (Text.drop (Text.length "pinned\tsuccess\t") l) | l ← printed, "pinned\tsuccess\t" `Text.isPrefixOf` l] of
              [[reclaim, used]] → (read (Text.unpack reclaim) > (0 ∷ Integer), read (Text.unpack reclaim) <= (read (Text.unpack used) ∷ Integer)) `shouldBe` (True, True)
              other → expectationFailure ("the pinned status printed " <> show other)
            printed `shouldContain` ["unpinned\tsuccess\t" <> rendered released, "copy changed\tsuccess\tchanged", "copy again\tsuccess\t" <> rendered released, "done"]

  it "holds a gameplay growth unreserved and uncommitted before its position, commits it at its tick, keeps the allowance a growth cancelled before its position would change, and lets presentation run" $ do
    faults ← newFaults
    withRigPort defaultConfig noProbe noTerrainHooks (seamPort faults) $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource logicalGrowth)]) $ \world control runtime →
        withFvm world runtime (gameplayOver rig) $ \logical →
          withFvm world runtime (presentationOver rig) $ \presentation → explained rig world $ do
            _ ← spawn world logical "modules-test" mainPath
            _ ← spawn world presentation "modules-test" mainPath
            let svc = rgService rig
            driveUntil world (tickBy control logical 1) (elem "asked" <$> outLines world)
            observer ← either (fail . show) pure =<< registerClient svc
            lease ← attachArena svc observer (arenaName rig "modules-test" "main") >>= either (fail . show) pure >>= await svc >>= either (fail . show) pure
            -- no tick is granted: the growth neither reserves nor commits before its position (#665 grants a growth the slot only once
            -- its host is eligible), its request is unsettled, and the presentation instance runs
            ((\s → (statusReservedBytes s, statusPendingReservedBytes s)) <$> (arenaStatus svc lease >>= either (fail . show) pure)) `shouldReturn` (fromInteger (mib 64), 0)
            (any (not . censusSettled) . censusRequests <$> atomically (inspectCensusSTM svc)) `shouldReturn` True
            earlier ← length . filter ("presentation\t" `Text.isPrefixOf`) <$> outLines world
            driveUntil world (advanceClock world 2000000000) ((> earlier + 2) . length . filter ("presentation\t" `Text.isPrefixOf`) <$> outLines world)
            outLines world >>= (`shouldNotSatisfy` any ("grown\t" `Text.isPrefixOf`))
            -- the tick: the growth commits, and the next is cancelled before its position
            driveUntil world (tickBy control logical 1) (elem "done" <$> outLines world)
            printed ← outLines world
            [l | l ← printed, not ("presentation\t" `Text.isPrefixOf` l)]
              `shouldBe` [ "asked"
                         , "grown\tsuccess\ttrue\t" <> Text.pack (show (mib 96))
                         , "cancel before its position\tcancelled"
                         , "after the cancel\t" <> Text.pack (show (mib 96))
                         , "done"
                         ]
            quiescent svc
            s ← arenaStatus svc lease >>= either (fail . show) pure
            (statusReservedBytes s, statusPendingReservedBytes s) `shouldBe` (fromInteger (mib 96), 0)

  it "retires a growth held at its reservation when its creator's instance ends: the arena closes, the extra is given back, and nothing is left" $ do
    faults ← newFaults
    held ← newHeld
    (`finally` openHeld held) $
      withRigPort defaultConfig noProbe noTerrainHooks (seamPort faults) $ \rig →
        withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource growthAtEnd)]) $ \world _ runtime →
          withFvm world runtime (presentationOver rig) $ \fvm → explained rig world $ do
            spawned ← spawn world fvm "modules-test" mainPath
            let go = advanceClock world 2000000000
                svc = rgService rig
            gate ← atWaitGate rig world go "arm" (addSeamGate faults isReserve)
            holdIn held gate
            driveUntil world go (elem "entered held" <$> readTVarIO (rgTrace rig))
            awaitSeamGate gate
            signalRig rig "held"
            driveUntil world go (elem "held" <$> outLines world)
            stopSpawned spawned
            driveUntil world go ((== Just Instance.Stopped) <$> phaseOf spawned)
            openHeld held
            driveUntil world go ((== 0) <$> limitHeld svc "arenas")
            quiescent svc
            limitHeld svc "leases" `shouldReturn` 0
            inspectBacked svc `shouldReturn` []
            inspectInvariants svc `shouldReturn` []
