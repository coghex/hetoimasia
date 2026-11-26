{-# LANGUAGE OverloadedStrings #-}

-- | Corner masks authored through a real Lua definition: the public @corner_mask@ field of a layer and of a patch value.
--
-- Every example runs a real Lua instance over the production service. What an example asserts is an outcome: the values a script
-- reads back, the refusal a malformed definition meets and what that refusal leaves behind, and the native reads of the same arena
-- through an independent client of the service. Never an order, a time or a count of steps.
module Test.LuaEngine.Terrain.Corners (spec) where

import Control.Exception (evaluate, finally)
import Control.Monad (forM_)
import Data.List (group)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Terrain.Cell (Cell (..), materialIdString, mkColumn, mkZRange, zRangeHi, zRangeLo)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), TileCoord, axisValue, composeTile, mkLocalCoord, tileCoord)
import Hetoimasia.Terrain.Query (Occupied (..), Run (..))
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Shape (cornerMaskValue, keyCorner, keySide, shapeIdValue)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

-- The native side ---------------------------------------------------------------------------------------------

-- | What the scripts print of a cell, from the native cell: air, a side solid as @material:SHAPE@ and a corner solid as
-- @material:cMASK@.
cellKey ∷ Cell → Text
cellKey = \case
  Air → "air"
  Solid material shape → Text.pack (materialIdString material) <> ":" <> Text.pack (show (shapeIdValue shape))
  CornerSolid material corners → Text.pack (materialIdString material) <> ":c" <> Text.pack (show (cornerMaskValue corners))

-- | The keys a cell reply holds: the revision and @air@, and for a solid its material and exactly one discriminator.
replyKeys ∷ Cell → Text
replyKeys = \case
  Air → "2"
  _ → "4"

-- | An independent client of the service, attached to the arena a Lua instance opened under this name, for the body.
withNative ∷ Rig → Text → (Service → ArenaLease → IO a) → IO a
withNative rig name body = do
  let svc = rgService rig
  client ← either (fail . show) pure =<< registerClient svc
  ( do
      attaching ← attachArena svc client (arenaName rig "modules-test" name) >>= either (fail . show) pure
      lease ← await svc attaching >>= either (fail . show) pure
      body svc lease
    )
    `finally` endClient svc client

nativeCell ∷ Service → ArenaLease → (Integer, Integer, Integer) → IO Text
nativeCell svc lease (x, y, z) = do
  tile ← either (fail . show) pure (tileCoord x y z)
  asked ← cellAt svc lease tile >>= either (fail . show) pure
  answer ← await svc asked >>= either (fail . show) pure
  pure (cellKey (cellValue answer) <> " " <> replyKeys (cellValue answer))

-- | The runs of a column over @[lo, hi)@ as @LO-HI:KEY@, each as the service answers it.
nativeColumn ∷ Service → ArenaLease → (Integer, Integer) → (Integer, Integer) → IO Text
nativeColumn svc lease (x, y) (lo, hi) = do
  column ← either (fail . show) pure (mkColumn x y)
  range ← either (fail . show) pure (mkZRange lo hi)
  asked ← columnAt svc lease column range >>= either (fail . show) pure
  answer ← await svc asked >>= either (fail . show) pure
  pure (Text.unwords [Text.pack (show (zRangeLo r)) <> "-" <> Text.pack (show (zRangeHi r)) <> ":" <> cellKey cell | Run r cell ← columnAnswerRuns answer])

-- | The highest occupied cell of a column as @Z:KEY@, or @empty@.
nativeSurface ∷ Service → ArenaLease → (Integer, Integer) → IO Text
nativeSurface svc lease (x, y) = do
  column ← either (fail . show) pure (mkColumn x y)
  asked ← surfaceAt svc lease column >>= either (fail . show) pure
  answer ← await svc asked >>= either (fail . show) pure
  pure $ case surfaceTop answer of
    Nothing → "empty"
    Just (Occupied level material key) →
      Text.pack (show (axisValue level)) <> ":" <> Text.pack (materialIdString material) <> case (keySide key, keyCorner key) of
        (Just shape, _) → ":" <> Text.pack (show (shapeIdValue shape))
        (_, Just corners) → ":c" <> Text.pack (show (cornerMaskValue corners))
        _ → ":missing"

-- | The cells of a region in the order of the Lua index @1 + x + 16 * y + 256 * z@.
tilesOf ∷ RegionCoord → [TileCoord]
tilesOf region = [either (error . show) id (mkLocalCoord x y z >>= composeTile region) | z ← [0 .. 31], y ← [0 .. 15], x ← [0 .. 15]]

-- | The terrain of one region as the scripts print it: its state, its length and each run of equal keys as @COUNTxKEY@.
nativeRegion ∷ Service → ArenaLease → RegionCoord → IO Text
nativeRegion svc lease region =
  withRegionSnapshot
    svc
    lease
    [region]
    ( \case
        Right snapshot → evaluate $ case regionTerrain snapshot region of
          PartReady _ →
            let keys = [case regionCell snapshot tile of PartReady cell → cellKey cell; _ → "missing" | tile ← tilesOf region]
             in "ready " <> Text.pack (show (length keys)) <> " " <> Text.unwords [Text.pack (show (length same)) <> "x" <> key | same@(key : _) ← group keys] <> " true"
          _ → "unavailable"
        Left settlement → fail ("the native regional snapshot did not settle: " <> show settlement)
    )
    >>= either (fail . show) pure

-- The scripts -------------------------------------------------------------------------------------------------

-- | The Lua the examples share: the text of a cell, a column's runs, a surface and one region's terrain, each as 'cellKey' and its
-- siblings make it, and whether a region's cells carry exactly the keys the contract names.
cornerPrelude ∷ [Text]
cornerPrelude =
  [ "local function nkeys(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end"
  , "local function tkey(c) if c.air then return 'air' end if c.corner_mask then return c.material .. ':c' .. c.corner_mask end return c.material .. ':' .. c.shape end"
  , "local function ctext(v) return tkey(v) .. ' ' .. nkeys(v) end"
  , "local function runtext(v)"
  , "  local out = {}"
  , "  for _, r in ipairs(v.runs) do out[#out + 1] = r.z_min .. '-' .. r.z_max .. ':' .. tkey(r) end"
  , "  return table.concat(out, ' ')"
  , "end"
  , "local function stext(v) if not v.occupied then return 'empty' end return v.z .. ':' .. tkey(v) end"
  , "local function rtext(v)"
  , "  local cells = v.terrain.cells or {}"
  , "  local out, prev, n, ok = {}, nil, 0, true"
  , "  for i = 1, #cells do"
  , "    local c = cells[i]"
  , "    if nkeys(c) ~= (c.air and 1 or 3) or (not c.air and (c.shape == nil) == (c.corner_mask == nil)) then ok = false end"
  , "    local k = tkey(c)"
  , "    if k == prev then n = n + 1 else"
  , "      if prev then out[#out + 1] = n .. 'x' .. prev end"
  , "      prev, n = k, 1"
  , "    end"
  , "  end"
  , "  if prev then out[#out + 1] = n .. 'x' .. prev end"
  , "  if v.terrain.state ~= 'ready' then return v.terrain.state end"
  , "  return v.terrain.state .. ' ' .. #cells .. ' ' .. table.concat(out, ' ') .. ' ' .. tostring(ok)"
  , "end"
  ]

-- | Stone below level 8 (a side-family layer), a corner-family layer of slab at level 8, an all-low layer of glass at level 9 (air),
-- and over them, one cell each: a corner slope, a side slope, a corner block, a side block, an all-low patch (air) and an explicit air
-- patch in row 5; a column at (3, 6) that alternates side 0, corner 15, side 15 and corner 15; a side solid at (9, 9) that tops its
-- column; and an all-low patch at (10, 10) over the corner layer.
sceneDefinition ∷ Text
sceneDefinition =
  Text.unwords
    [ "{ materials = { 'stone', 'slab', 'glass' },"
    , "  layers = {"
    , "    { z_max = 8, material = 'stone', shape = 0 },"
    , "    { z_min = 8, z_max = 9, material = 'slab', corner_mask = 15 },"
    , "    { z_min = 9, z_max = 10, material = 'glass', corner_mask = 0 } },"
    , "  patches = {"
    , "    { x = 3, y = 5, z_min = 5, z_max = 6, value = { material = 'slab', corner_mask = 9 } },"
    , "    { x = 4, y = 5, z_min = 5, z_max = 6, value = { material = 'slab', shape = 3 } },"
    , "    { x = 5, y = 5, z_min = 5, z_max = 6, value = { material = 'slab', corner_mask = 15 } },"
    , "    { x = 6, y = 5, z_min = 5, z_max = 6, value = { material = 'slab', shape = 0 } },"
    , "    { x = 7, y = 5, z_min = 5, z_max = 6, value = { material = 'slab', corner_mask = 0 } },"
    , "    { x = 8, y = 5, z_min = 5, z_max = 6, value = { air = true } },"
    , "    { x = 3, y = 6, z_min = 5, z_max = 6, value = { material = 'slab', shape = 0 } },"
    , "    { x = 3, y = 6, z_min = 6, z_max = 7, value = { material = 'slab', corner_mask = 15 } },"
    , "    { x = 3, y = 6, z_min = 7, z_max = 8, value = { material = 'slab', shape = 15 } },"
    , "    { x = 3, y = 6, z_min = 8, z_max = 9, value = { material = 'slab', corner_mask = 15 } },"
    , "    { x = 9, y = 9, z_min = 8, z_max = 9, value = { material = 'stone', shape = 15 } },"
    , "    { x = 10, y = 10, z_min = 8, z_max = 9, value = { material = 'slab', corner_mask = 0 } } } }"
    ]

-- | The cells the scene reads, each with the text it must come to: the family a solid reports is the family it was authored in.
cellReads ∷ [(Text, (Integer, Integer, Integer), Text)]
cellReads =
  [ ("corner slope", (3, 5, 5), "slab:c9 4")
  , ("side slope", (4, 5, 5), "slab:3 4")
  , ("corner block", (5, 5, 5), "slab:c15 4")
  , ("side block", (6, 5, 5), "slab:0 4")
  , ("all-low patch", (7, 5, 5), "air 2")
  , ("air patch", (8, 5, 5), "air 2")
  , ("corner layer", (0, 0, 8), "slab:c15 4")
  , ("all-low layer", (0, 0, 9), "air 2")
  , ("side layer", (0, 0, 0), "stone:0 4")
  ]

columnReads ∷ [(Text, (Integer, Integer), (Integer, Integer), Text)]
columnReads =
  [ ("mixed column", (3, 6), (4, 12), "4-5:stone:0 5-6:slab:0 6-7:slab:c15 7-8:slab:15 8-9:slab:c15 9-12:air")
  , ("layered column", (0, 0), (6, 12), "6-8:stone:0 8-9:slab:c15 9-12:air")
  ]

surfaceReads ∷ [(Text, (Integer, Integer), Text)]
surfaceReads =
  [ ("corner surface", (0, 0), "8:slab:c15")
  , ("side surface", (9, 9), "8:stone:15")
  , ("all-low surface", (10, 10), "7:stone:0")
  ]

sceneSteps ∷ [Step]
sceneSteps =
  [Step label ("return api.terrain.cell(A, {x = " <> n x <> ", y = " <> n y <> ", z = " <> n z <> "})") "return ctext(v)" | (label, (x, y, z), _) ← cellReads]
    <> [Step label ("return api.terrain.column(A, {x = " <> n x <> ", y = " <> n y <> ", z_min = " <> n lo <> ", z_max = " <> n hi <> "})") "return runtext(v)" | (label, (x, y), (lo, hi), _) ← columnReads]
    <> [Step label ("return api.terrain.surface(A, {x = " <> n x <> ", y = " <> n y <> "})") "return stext(v)" | (label, (x, y), _) ← surfaceReads]
    <> [Step "region" "return api.terrain.region(A, {x = 0, y = 0, z = 0})" "return rtext(v)"]
  where
    n = Text.pack . show

-- | A real Lua instance of this script, run to its @done@, and what it printed.
withRun ∷ Rig → Script → (World → IO a) → IO a
withRun rig steps body =
  withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource steps)]) $ \world _ runtime →
    withFvm world runtime (presentationOver rig) $ \fvm → do
      _ ← spawn world fvm "modules-test" mainPath
      body world

finished ∷ World → IO [Text]
finished world = do
  stepUntil world (elem "done" <$> outLinesSTM world)
  outLines world

-- | One refusal of the decode, a layer or a patch value the contract does not allow.
refusals ∷ [Case]
refusals =
  [ Case "layer corner_mask 16" (open (layer "material = 'soil', corner_mask = 16")) (Refused ["corner mask 0 .. 15"])
  , Case "layer corner_mask -1" (open (layer "material = 'soil', corner_mask = -1")) (Refused ["corner mask 0 .. 15"])
  , Case "layer corner_mask a float" (open (layer "material = 'soil', corner_mask = 1.0")) (Refused ["a float where an integer is declared"])
  , Case "layer corner_mask a string" (open (layer "material = 'soil', corner_mask = '1'")) (Refused ["expected integer"])
  , Case "layer corner_mask a boolean" (open (layer "material = 'soil', corner_mask = true")) (Refused ["expected integer"])
  , Case "layer shape and corner_mask" (open (layer "material = 'soil', shape = 0, corner_mask = 15")) (Refused ["both a shape and a corner_mask"])
  , Case "layer zero shape and zero corner_mask" (open (layer "material = 'soil', shape = 0, corner_mask = 0")) (Refused ["both a shape and a corner_mask"])
  , Case "layer neither" (open (layer "material = 'soil'")) (Refused ["shape", "corner_mask"])
  , Case "layer corner_mask without a material" (open (layer "corner_mask = 15")) (Refused ["material"])
  , Case "layer corner_mask a stray field" (open (layer "material = 'soil', corner_mask = 15, tint = 1")) (Refused ["tint"])
  , Case "patch corner_mask 16" (open (patch "{ material = 'soil', corner_mask = 16 }")) (Refused ["corner mask 0 .. 15"])
  , Case "patch corner_mask -1" (open (patch "{ material = 'soil', corner_mask = -1 }")) (Refused ["corner mask 0 .. 15"])
  , Case "patch corner_mask a float" (open (patch "{ material = 'soil', corner_mask = 3.0 }")) (Refused ["a float where an integer is declared"])
  , Case "patch corner_mask a string" (open (patch "{ material = 'soil', corner_mask = '3' }")) (Refused ["expected integer"])
  , Case "patch shape and corner_mask" (open (patch "{ material = 'soil', shape = 0, corner_mask = 3 }")) (Refused ["both a shape and a corner_mask"])
  , Case "patch material alone" (open (patch "{ material = 'soil' }")) (Refused ["shape", "corner_mask"])
  , Case "patch corner_mask without a material" (open (patch "{ corner_mask = 3 }")) (Refused ["patch value"])
  , Case "patch shape without a material" (open (patch "{ shape = 3 }")) (Refused ["patch value"])
  , Case "patch air false alone" (open (patch "{ air = false }")) (Refused ["patch value"])
  , Case "patch air and a corner_mask" (open (patch "{ air = true, corner_mask = 3 }")) (Refused ["air carries no material, shape or corner_mask"])
  , Case "patch air and a zero corner_mask" (open (patch "{ air = true, corner_mask = 0 }")) (Refused ["air carries no material, shape or corner_mask"])
  , Case "patch air and a shape" (open (patch "{ air = true, shape = 3 }")) (Refused ["air carries no material, shape or corner_mask"])
  , Case "patch air and a material" (open (patch "{ air = true, material = 'soil' }")) (Refused ["air carries no material, shape or corner_mask"])
  , Case "patch air and a material and a corner_mask" (open (patch "{ air = true, material = 'soil', corner_mask = 3 }")) (Refused ["air carries no material, shape or corner_mask"])
  , Case "patch solid and air = true and a corner_mask" (open (patch "{ air = true, material = 'soil', corner_mask = 3, shape = 1 }")) (Refused ["air carries no material, shape or corner_mask"])
  ]
  where
    open definition = "api.terrain.open('refused', " <> definition <> ")"
    layer fields = "{ materials = { 'soil' }, layers = { { " <> fields <> " } } }"
    patch value = "{ materials = { 'soil' }, layers = {}, patches = { { x = 0, y = 0, z_min = 0, z_max = 1, value = " <> value <> " } } }"

-- | Definitions the decode accepts and the validator refuses: each is the expected @definition@ failure, so each is read and
-- leaves nothing (no arena, no name, no lease). A record that authors corner mask zero is still a solid record until it is checked.
probes ∷ [(Text, Text)]
probes =
  [ ("zero mask with an undeclared material", "{ materials = { 'stone' }, layers = { { material = 'ghost', corner_mask = 0 } } }")
  , ("zero mask layers overlapping", "{ materials = { 'stone' }, layers = { { z_max = 4, material = 'stone', shape = 0 }, { z_min = 2, z_max = 6, material = 'stone', corner_mask = 0 } } }")
  , ("zero mask with an empty interval", "{ materials = { 'stone' }, layers = { { z_min = 3, z_max = 3, material = 'stone', corner_mask = 0 } } }")
  , ("zero mask patches overlapping an air patch", "{ materials = { 'stone' }, layers = {}, patches = { { x = 0, y = 0, z_min = 0, z_max = 2, value = { material = 'stone', corner_mask = 0 } }, { x = 0, y = 0, z_min = 1, z_max = 3, value = { air = true } } } }")
  , ("zero mask patch with an undeclared material", "{ materials = { 'stone' }, layers = {}, patches = { { x = 0, y = 0, z_min = 0, z_max = 1, value = { material = 'ghost', corner_mask = 0 } } } }")
  ]

-- | A definition made only of all-low records over a declared material: it opens, and every cell reads as air.
allLowDefinition ∷ Text
allLowDefinition =
  "{ materials = { 'glass' }, layers = { { z_min = 0, z_max = 4, material = 'glass', corner_mask = 0 } }, patches = { { x = 0, y = 0, z_min = 0, z_max = 1, value = { material = 'glass', corner_mask = 0 } } } }"

spec ∷ Spec
spec = describe "Terrain corner masks" $ do
  it "authors a layer, patches, an all-low record and a mixed-family scene from Lua, and every read agrees with the native read" $
    withRig $ \rig →
      withRun rig (stepsScript "SCENE" (["local SCENE = " <> sceneDefinition] <> cornerPrelude) sceneSteps) $ \world → do
        printed ← finished world
        withNative rig "main" $ \svc lease → do
          let line label text = label <> "\tsuccess\t" <> text
          forM_ cellReads $ \(label, at, expected) → do
            native ← nativeCell svc lease at
            -- the native answer is what was authored, and the reply is the native answer
            native `shouldBe` expected
            printed `shouldContain` [line label native]
          forM_ columnReads $ \(label, at, range, expected) → do
            native ← nativeColumn svc lease at range
            native `shouldBe` expected
            printed `shouldContain` [line label native]
          forM_ surfaceReads $ \(label, at, expected) → do
            native ← nativeSurface svc lease at
            native `shouldBe` expected
            printed `shouldContain` [line label native]
          native ← nativeRegion svc lease (RegionCoord 0 0 0)
          printed `shouldContain` [line "region" native]
          -- the region holds every family the scene authored
          native `shouldSatisfy` ("slab:c9" `Text.isInfixOf`)
          native `shouldSatisfy` ("slab:c15" `Text.isInfixOf`)
          native `shouldSatisfy` ("slab:3" `Text.isInfixOf`)
          native `shouldSatisfy` ("stone:15" `Text.isInfixOf`)

  it "refuses every malformed corner definition as an ordinary error before admission, and leaves what was open as it was" $
    withRig $ \rig →
      withRun rig refusalScript $ \world → do
        stepUntil world (elem "done" <$> outLinesSTM world)
        printed ← outLines world
        checkCases refusals printed
        -- every refusal was raised before admission: none kept a place of the request bank
        printed `shouldContain` ["places after the refusals\t16"]
        -- the arena the example had open is the only one, with its one lease, and reads as it did
        limitHeld (rgService rig) "arenas" `shouldReturn` 1
        limitHeld (rgService rig) "leases" `shouldReturn` 1
        observeCell rig (arenaName rig "modules-test" "main") (0, 0, 0) `shouldReturn` (0, Just "soil")

  it "checks a zero-mask record as a solid before it reads as air, and a refused definition leaves its name free" $
    withRig $ \rig →
      withRun rig probeScript $ \world → do
        printed ← finished world
        mapM_ (\(label, _) → printed `shouldContain` [label <> "\tfailure\tdefinition"]) probes
        -- the all-low definition opens under the name every refused one used, and nothing in it is occupied
        printed `shouldContain` ["open\tsuccess"]
        printed `shouldContain` ["cell\tsuccess\tair 2"]
        printed `shouldContain` ["column\tsuccess\t0-4:air"]
        printed `shouldContain` ["surface\tsuccess\tempty"]
        observeCell rig (arenaName rig "modules-test" "probe") (0, 0, 0) `shouldReturn` (0, Nothing)
        limitHeld (rgService rig) "arenas" `shouldReturn` 1
  where
    refusalScript =
      script
        { scPrelude = terrainPrelude <> ["local A"]
        , scInit = ["self.open = api.terrain.open('main', DEF)"]
        , scUpdate =
            [ "if not self.ran then"
            , "  local t = settle(api, self.open)"
            , "  if t then"
            , "    self.ran = true"
            , "    A = t.value"
            ]
              <> map (("    " <>) . caseLua) refusals
              <> [ "    local taken = 0"
                 , "    for i = 1, 16 do if api.terrain.cell(A, {x = i, y = 0, z = 0}) ~= nil then taken = taken + 1 end end"
                 , "    print('places after the refusals', taken)"
                 , "    print('done')"
                 , "  end"
                 , "end"
                 ]
        }

    probeScript =
      script
        { scPrelude =
            terrainPrelude
              <> cornerPrelude
              <> ["local GOOD = " <> allLowDefinition, "local PROBES = {"]
              <> ["  { " <> Text.pack (show (Text.unpack label)) <> ", " <> definition <> " }," | (label, definition) ← probes]
              <> ["}"]
        , scInit = ["self.phase = 'probe'", "self.i = 0"]
        , scUpdate =
            [ "if self.phase == 'probe' then"
            , "  if self.q then"
            , "    local t = settle(api, self.q)"
            , "    if t then print(PROBES[self.i][1], t.status, t.error and t.error.code) self.q = nil end"
            , "  end"
            , "  if not self.q then"
            , "    self.i = self.i + 1"
            , "    local p = PROBES[self.i]"
            , "    if p then self.q = api.terrain.open('probe', p[2]) else self.phase = 'open' self.q = api.terrain.open('probe', GOOD) end"
            , "  end"
            , "elseif self.phase == 'open' then"
            , "  local t = settle(api, self.q)"
            , "  if t then"
            , "    print('open', t.status)"
            , "    self.arena = t.value"
            , "    self.phase = 'cell'"
            , "    self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0})"
            , "  end"
            , "elseif self.phase == 'cell' then"
            , "  local t = settle(api, self.q)"
            , "  if t then"
            , "    print('cell', t.status, ctext(t.value))"
            , "    self.phase = 'column'"
            , "    self.q = api.terrain.column(self.arena, {x = 0, y = 0, z_min = 0, z_max = 4})"
            , "  end"
            , "elseif self.phase == 'column' then"
            , "  local t = settle(api, self.q)"
            , "  if t then"
            , "    print('column', t.status, runtext(t.value))"
            , "    self.phase = 'surface'"
            , "    self.q = api.terrain.surface(self.arena, {x = 0, y = 0})"
            , "  end"
            , "elseif self.phase == 'surface' then"
            , "  local t = settle(api, self.q)"
            , "  if t then print('surface', t.status, stext(t.value)) print('done') self.phase = 'done' end"
            , "end"
            ]
        }
