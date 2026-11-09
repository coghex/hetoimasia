{-# LANGUAGE OverloadedStrings #-}

-- | The one arbitration between a script's cancel and the service's commit, and a request's logical position.
--
-- The terrain owner is held, by the probe, at the commit of a removal: after it was staged, before it is offered to the
-- arbitration. Where the owner stands decides which side of each race wins, never how long anything waits.
module Test.LuaEngine.Terrain.Races (spec) where

import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

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

spec ∷ Spec
spec = describe "Terrain races" $ do
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
