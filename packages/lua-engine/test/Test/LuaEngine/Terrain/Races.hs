{-# LANGUAGE OverloadedStrings #-}

-- | The one arbitration between a script's cancel and the service's commit, and a request's logical position.
--
-- The terrain owner is held, by the probe, at the commit of a removal: after it was staged, before it is offered to the
-- arbitration. Where the owner stands decides which side of each race wins, never how long anything waits.
module Test.LuaEngine.Terrain.Races (spec) where

import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Control.Exception (finally)
import Control.Monad (void, when)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..))
import Hetoimasia.LuaEngine.Terrain (TerrainHooks (..), noTerrainHooks)
import Hetoimasia.Scripting.Lua.Provider (advanceRequestEpoch)
import Hetoimasia.Scripting.Lua.Scheduled (scheduledEndpoint)
import Hetoimasia.Terrain.Runtime (Point (..), Probe (..))
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

-- | A presentation instance: open and issue a removal.
remover ∷ Script
remover =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate = ["if self.s == 0 then local t = settle(api, self.q) if t then self.arena = t.value self.r = api.terrain.remove(self.arena, {x = 0, y = 0, z = 0}) print('issued') self.s = 1 end end"]
    }

-- | A presentation instance: open, issue a removal and stop; cancel it on the next update; then read the cell.
cancelling ∷ Script
cancelling =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.arena = t.value self.r = api.terrain.remove(self.arena, {x = 0, y = 0, z = 0}) print('issued') self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  print('cancel', api.request.cancel(self.r))"
        , "  print('take', api.request.take(self.r).status)"
        , "  self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0})"
        , "  self.s = 2"
        , "elseif self.s == 2 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('cell', t.value.air, t.value.revision) print('done') self.s = 3 end"
        , "end"
        ]
    }

-- | A presentation instance that removes and waits for the answer, then tries to cancel it.
committing ∷ Script
committing =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.arena = t.value self.r = api.terrain.remove(self.arena, {x = 0, y = 0, z = 0}) self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  if api.request.ready(self.r) then print('cancel after commit', api.request.cancel(self.r)) print('take', api.request.take(self.r).value.changed) print('done') self.s = 2 end"
        , "end"
        ]
    }

-- | A gameplay instance opens an arena (due tick 1) and removes a cell from it (due tick 2); a presentation instance attaches to the
-- arena once it exists and reads the cell over and over, printing what it saw. The gameplay update prints each tick it runs.
logical ∷ Script
logical =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "if api.role == 'gameplay' then self.q = api.terrain.open('g', DEF) end"]
    , scUpdate =
        [ "if api.role == 'gameplay' then"
        , "  local tick = api.time.tick()"
        , "  print('gameplay tick', tick)"
        , "  if self.s == 0 then"
        , "    local t = settle(api, self.q)"
        , "    if t then self.arena = t.value self.q = api.terrain.remove(self.arena, {x = 0, y = 0, z = 0}) print('removal issued at', tick) self.s = 1 end"
        , "  elseif self.s == 1 then"
        , "    local t = settle(api, self.q)"
        , "    if t then print('removal settled at', tick, t.status, t.value.changed, t.value.revision) self.s = 2 end"
        , "  end"
        , "else"
        , "  print('heartbeat')"
        , "  if self.s == 0 then self.q = api.terrain.attach('g') self.s = 1"
        , "  elseif self.s == 1 then"
        , "    local t = settle(api, self.q)"
        , "    if t then if t.status == 'success' then self.arena = t.value self.s = 2 else self.s = 0 end end"
        , "  elseif self.s == 2 then self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 3"
        , "  elseif self.s == 3 then"
        , "    local t = settle(api, self.q)"
        , "    if t then print('observed', t.value.air, t.value.revision) self.s = 2 end"
        , "  end"
        , "end"
        ]
    }

-- | A presentation instance: open and read a cell (the owner is held where that read is captured); then, on the next update, issue a
-- removal behind it and cancel the removal at once; then read the cell again.
cancelsUnprepared ∷ Script
cancelsUnprepared =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.arena = t.value self.read = api.terrain.cell(self.arena, {x = 5, y = 0, z = 0}) self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  self.r = api.terrain.remove(self.arena, {x = 0, y = 0, z = 0})"
        , "  print('cancel', api.request.cancel(self.r))"
        , "  print('take', api.request.take(self.r).status)"
        , "  self.s = 2"
        , "elseif self.s == 2 then"
        , "  local t = settle(api, self.read)"
        , "  if t then self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 3 end"
        , "elseif self.s == 3 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('cell', t.value.air, t.value.revision) print('done') self.s = 4 end"
        , "end"
        ]
    }

-- | A gameplay instance over two arenas: it warms a cell of the second at tick 1; at tick 3 it asks the first, whose region is not resident,
-- for a removal (position 1 of tick 4), and then the second, whose cell is, for another (position 2).
inverted ∷ Script
inverted =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.x = api.terrain.open('x', DEF)", "self.y = api.terrain.open('y', DEF)"]
    , scUpdate =
        [ "local tick = api.time.tick()"
        , "if self.s == 0 then"
        , "  self.xa = self.xa or settle(api, self.x)"
        , "  self.ya = self.ya or settle(api, self.y)"
        , "  if self.xa and self.ya then self.w = api.terrain.cell(self.ya.value, {x = 0, y = 0, z = 0}) self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  local t = settle(api, self.w)"
        , "  if t then print('warm at', tick) self.s = 2 end"
        , "elseif self.s == 2 then"
        , "  self.r1 = api.terrain.remove(self.xa.value, {x = 0, y = 0, z = 0})"
        , "  self.r2 = api.terrain.remove(self.ya.value, {x = 0, y = 0, z = 0})"
        , "  print('issued at', tick) self.s = 3"
        , "elseif self.s == 3 then"
        , "  local a, b = settle(api, self.r1), settle(api, self.r2)"
        , "  print('r1 at', tick, a.status, a.value.changed, a.value.revision)"
        , "  print('r2 at', tick, b.status, b.value.changed, b.value.revision)"
        , "  self.s = 4"
        , "end"
        ]
    }

-- | A presentation instance that opens an arena of its own and, when the example says so, reads a cell of a region nobody has read and
-- cancels the read on its next update.
holder ∷ Script
holder =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('z', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.z = t.value"
        , "    TEST_WAIT('go')"
        , "    self.e = api.terrain.cell(self.z, {x = 16, y = 0, z = 0})"
        , "    print('E issued') self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  print('E cancel', api.request.cancel(self.e)) self.s = 2"
        , "end"
        ]
    }

-- | A gameplay instance: open (due tick 1), then issue a removal (due tick 2) and cancel it in the same update; read the cell at tick 3.
logicalCancel ∷ Script
logicalCancel =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "local tick = api.time.tick()"
        , "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.arena = t.value"
        , "    self.r = api.terrain.remove(self.arena, {x = 0, y = 0, z = 0})"
        , "    print('cancel at', tick, api.request.cancel(self.r))"
        , "    self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  print('take at', tick, api.request.take(self.r).status)"
        , "  self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 2"
        , "elseif self.s == 2 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('cell at', tick, t.value.air, t.value.revision) print('done') self.s = 3 end"
        , "end"
        ]
    }

spec ∷ Spec
spec = arbitration >> racesSpec >> windowsSpec

-- | Where in its life a removal is when it is cancelled: before the owner has prepared it, after it was prepared and before it was
-- published as staged, and on the logical timeline before its position. The epoch of the owner's requests ends one the same way.
windowsSpec ∷ Spec
windowsSpec = describe "Terrain cancel windows" $ do
  it "leaves no edit for a removal cancelled before the owner prepared it" $ do
    gate ← newGate
    withRigProbe defaultConfigForRaces (gatedProbe (\p → case p of PointCaptured {} → True; _ → False) gate) $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource cancelsUnprepared)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → (`finally` openGate gate) $ do
          _ ← spawn world fvm "modules-test" mainPath
          -- the owner stands where the earlier read is captured; the script's next update issues the removal behind it and cancels it, so it
          -- is not prepared when it is cancelled
          pumpUntilReached world gate
          untilPrinted world "take\tcancelled"
          openGate gate
          untilPrinted world "done"
          printed ← outLines world
          printed `shouldContain` ["cancel\tcancelled", "take\tcancelled", "cell\tfalse\t0"]

  it "leaves no edit for a removal cancelled after the owner prepared it, before it was published as staged" $ do
    gate ← newGate
    withRigProbe defaultConfigForRaces (gatedProbe (\p → case p of PointStaging _ → True; _ → False) gate) $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource cancelling)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → (`finally` openGate gate) $ do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "issued"
          awaitReached gate
          untilPrinted world "cancel\tcancelled"
          openGate gate
          untilPrinted world "done"
          outLines world >>= \printed → printed `shouldContain` ["take\tcancelled", "cell\tfalse\t0"]

  it "leaves terrain unchanged for a logical removal cancelled before its position, and lets its tick begin" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource logicalCancel)]) $ \world control runtime →
        withFvm world runtime (gameplayOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          pumpUntil world (tickBy control fvm 1 >> (elem "done" <$> outLines world))
          printed ← outLines world
          printed `shouldContain` ["cancel at\t1\tcancelled", "take at\t2\tcancelled"]
          -- the cell is as authored when the later tick reads it, and the ticks went on past the cancelled removal's position
          printed `shouldSatisfy` any (\line → "cell at\t" `Text.isPrefixOf` line && "\tfalse\t0" `Text.isSuffixOf` line)

  it "stages two logical removals in the opposite order of their places and commits them in the order of their places, across two arenas" $ do
    gate ← newGate
    armed ← newIORef True
    stagings ← newIORef ([] ∷ [String])
    commits ← newIORef ([] ∷ [String])
    let -- the owner is held while it loads the one region the holder's read asks for, so that the removals arrive behind it
        probe = Probe $ \point → case point of
          PointJob _ region
            | region == RegionCoord 1 0 0 → do
                go ← atomicModifyIORef' armed (\a → (False, a))
                when go (holdAt gate)
          PointStaging rid → modifyIORef' stagings (show rid :)
          PointCommitted rid _ → modifyIORef' commits (show rid :)
          _ → pure ()
    withRigProbe defaultConfigForRaces probe $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource inverted), ("lua/holder.lua", scriptSource holder)]) $ \world control runtime →
        withFvm world runtime (gameplayOver rig) $ \gameplayVm →
          withFvm world runtime (presentationOver rig) $ \shown → (`finally` openGate gate) $ do
            _ ← spawn world gameplayVm "modules-test" mainPath
            _ ← admitOnly world shown "modules-test" "lua/holder.lua"
            -- tick 1 settles the opens and issues the warming read; tick 2 settles it: the second arena's cell is resident, the first's is not
            pumpUntil world (tickBy control gameplayVm 1 >> (elem "warm at\t2" <$> outLines world))
            -- the holder reads a cell of a region nobody has read, and the owner is held loading it
            signalRig rig "go"
            pumpUntilReached world gate
            -- the holder cancels that read while its job is held; tick 3 issues the two removals, which wait behind the job
            untilPrinted world "E cancel\tcancelled"
            pumpUntil world (tickBy control gameplayVm 1 >> (elem "issued at\t3" <$> outLines world))
            -- the job is released: the owner prepares the removal whose cell is resident first, and the other when its region has loaded
            openGate gate
            pumpUntil world (tickBy control gameplayVm 1 >> (any (Text.isPrefixOf "r2 at") <$> outLines world))
            printed ← outLines world
            printed `shouldContain` ["r1 at\t4\tsuccess\ttrue\t1", "r2 at\t4\tsuccess\ttrue\t1"]
            staged ← reverse <$> readIORef stagings
            committed ← reverse <$> readIORef commits
            -- two removals, prepared in one order and committed in the opposite: the places decided the commits, not the preparation
            length staged `shouldBe` 2
            committed `shouldBe` reverse staged

  it "cancels a staged removal when the owner's request epoch changes, and commits nothing" $ do
    gate ← newGate
    probe ← removalProbe gate
    withRigProbe defaultConfigForRaces probe $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource remover)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → (`finally` openGate gate) $ do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "issued"
          awaitReached gate
          -- the owner stands at the commit of the staged removal; the owner's requests move to a new epoch
          void (advanceRequestEpoch (scheduledEndpoint (fvOwner fvm)))
          pumpUntil world (advanceClock world 2000000000 >> (pure True))
          openGate gate
          observeCell rig (arenaName rig "modules-test" "main") (0, 0, 0) `shouldReturn` (0, Just "soil")

racesSpec ∷ Spec
racesSpec = describe "Terrain races" $ do
  it "holds a late removal's tick while the presentation VM keeps reading, changes nothing before the position, and releases the tick when it commits" $ do
    gate ← newGate
    probe ← removalProbe gate
    withRigProbe defaultConfigForRaces probe $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource logical)]) $ \world control runtime →
        withFvm world runtime (gameplayOver rig) $ \logicalVm →
          withFvm world runtime (presentationOver rig) $ \shown → do
            _ ← spawn world logicalVm "modules-test" mainPath
            _ ← spawn world shown "modules-test" mainPath
            -- tick 1: the open settles at its position, and the update issues the removal (due tick 2)
            tickBy control logicalVm 1
            untilPrinted world "removal issued at\t1"
            -- the presentation instance finds the arena and reads soil at revision 0: the removal is only staged
            untilPrinted world "observed\tfalse\t0"
            -- tick 2 is granted, and the owner stands at the removal's commit: the tick must not begin
            grantTick logicalVm
            awaitReached gate
            tickTwos ← length . filter (== "gameplay tick\t2") <$> outLines world
            tickTwos `shouldBe` 0
            -- the presentation VM carries on meanwhile: no Lua callback waits for the held request, so its updates keep running
            beats ← length . filter (== "heartbeat") <$> outLines world
            pumpUntil world (advanceClock world 2000000000 >> ((>= beats + 3) . length . filter (== "heartbeat") <$> outLines world))
            outLines world >>= \printed → printed `shouldNotContain` ["gameplay tick\t2"]
            -- the commit goes through: the tick begins, the removal settles at it, and the arena shows the edit
            openGate gate
            awaitTickDone control logicalVm
            untilPrinted world "removal settled at\t2\tsuccess\ttrue\t1"
            untilPrinted world "observed\ttrue\t1"
            printed ← outLines world
            -- the edit was never visible before the removal's commit, and never undone after
            let observed = [line | line ← printed, "observed" `Text.isPrefixOf` line]
            observed `shouldSatisfy` (\seen → "observed\ttrue\t1" `elem` seen && all (`elem` ["observed\tfalse\t0", "observed\ttrue\t1"]) seen)
            reverse (dropWhile (== "observed\ttrue\t1") (reverse observed)) `shouldSatisfy` all (== "observed\tfalse\t0")

  it "leaves no edit when the script's cancel wins before the commit, and answers already_settled when the commit won" $ do
    gate ← newGate
    probe ← removalProbe gate
    withRigProbe defaultConfigForRaces probe $ \rig → do
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource cancelling)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "issued"
          -- the removal is staged and the owner holds it at the commit; the script's cancel is next
          awaitReached gate
          untilPrinted world "cancel\tcancelled"
          openGate gate
          untilPrinted world "done"
          printed ← outLines world
          -- the cancel won: nothing was edited, and the cell is as it was
          printed `shouldContain` ["take\tcancelled", "cell\tfalse\t0"]
    -- and with the owner not held, the commit wins the race
    disarmGate gate
    withRigProbe defaultConfigForRaces noProbeForRaces $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource committing)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          printed ← outLines world
          printed `shouldContain` ["cancel after commit\talready_settled", "take\ttrue"]

-- | The window between a script's cancel winning in the host and the service being told: the service's commit is attempted there, and
-- the request's eligibility alone decides it. The owner is held at the commit and the cancelling thread at the telling; the owner is
-- let go first, and its commit must find the request already settled and make no edit.
arbitration ∷ Spec
arbitration = describe "Terrain arbitration" $
  it "refuses a commit attempted after the host settled the request as cancelled and before the service was told" $ do
    commitGate ← newGate
    tellGate ← newGate
    probe ← removalProbe commitGate
    withRigHooks defaultConfigForRaces probe noTerrainHooks {hookCancelling = holdAt tellGate} $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource cancelling)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "issued"
          awaitReached commitGate
          -- the script's next update cancels: the host settles it, and the cancelling thread stops before telling the service
          pumpUntil world (advanceClock world 2000000000 >> (pure True))
          awaitReached tellGate
          -- the owner attempts the commit now: the request is settled in the host, so it is not eligible and nothing is committed
          openGate commitGate
          -- the telling goes on and the script reads the cell: no edit was made
          openGate tellGate
          untilPrinted world "done"
          outLines world >>= \printed → printed `shouldContain` ["cell\tfalse\t0"]
