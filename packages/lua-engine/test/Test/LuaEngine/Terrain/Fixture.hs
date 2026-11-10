{-# LANGUAGE OverloadedStrings #-}

-- | The declarative fixture of the acceptance section: stone under a stack of sixteen solid levels, one of each shape identity, with an
-- authored air gap above every one; a column carved wholly to air; whole-slope removal, an unchanged neighbourhood, a removal of air,
-- the script's own tables mutated after a call, and removals that survive real eviction and reload.
module Test.LuaEngine.Terrain.Fixture (spec) where

import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Terrain.Residency (modelRegions)
import Hetoimasia.Terrain.Runtime (inspectModel)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

-- | Stone below level 0; then, for each shape identity @i@ from 0 to 15, one solid level @2i@ of that shape (stone and soil
-- alternating) with an authored air gap at level @2i + 1@; and column (1, 1) carved to air over every supported level.
fixture ∷ [Text]
fixture =
  [ "local FIX = { materials = { 'soil', 'stone' }, layers = { { z_max = 0, material = 'stone', shape = 0 }"
  , "  , { z_min = 0, z_max = 1, material = 'stone', shape = 0 }, { z_min = 2, z_max = 3, material = 'soil', shape = 1 }"
  , "  , { z_min = 4, z_max = 5, material = 'stone', shape = 2 }, { z_min = 6, z_max = 7, material = 'soil', shape = 3 }"
  , "  , { z_min = 8, z_max = 9, material = 'stone', shape = 4 }, { z_min = 10, z_max = 11, material = 'soil', shape = 5 }"
  , "  , { z_min = 12, z_max = 13, material = 'stone', shape = 6 }, { z_min = 14, z_max = 15, material = 'soil', shape = 7 }"
  , "  , { z_min = 16, z_max = 17, material = 'stone', shape = 8 }, { z_min = 18, z_max = 19, material = 'soil', shape = 9 }"
  , "  , { z_min = 20, z_max = 21, material = 'stone', shape = 10 }, { z_min = 22, z_max = 23, material = 'soil', shape = 11 }"
  , "  , { z_min = 24, z_max = 25, material = 'stone', shape = 12 }, { z_min = 26, z_max = 27, material = 'soil', shape = 13 }"
  , "  , { z_min = 28, z_max = 29, material = 'stone', shape = 14 }, { z_min = 30, z_max = 31, material = 'soil', shape = 15 } },"
  , "  patches = { { x = 1, y = 1, z_min = -(1 << 62), z_max = 1 << 62, value = { air = true } } } }"
  , "local function runs(v)"
  , "  local out = {}"
  , "  for _, r in ipairs(v.runs) do out[#out + 1] = r.z_min .. ':' .. r.z_max .. ':' .. tostring(r.air) .. ':' .. tostring(r.material) .. ':' .. tostring(r.shape) end"
  , "  return v.revision .. ' ' .. table.concat(out, ',')"
  , "end"
  , "local function cell(v) return v.revision .. ' ' .. tostring(v.air) .. ' ' .. tostring(v.material) .. ' ' .. tostring(v.shape) end"
  ]

-- | The runs of the column (0, 0) from level 0 to 32, as the fixture authors them: the sixteen solid levels with their shapes and
-- materials, and an air gap after each, the last gap running to the end of the range.
authoredRuns ∷ Text
authoredRuns = Text.intercalate "," (concat [solid i <> gap i | i ← [0 .. 15 ∷ Int]])
  where
    material i = if even i then "stone" else "soil"
    solid i = [Text.pack (show (2 * i)) <> ":" <> Text.pack (show (2 * i + 1)) <> ":false:" <> material i <> ":" <> Text.pack (show i)]
    gap i = [Text.pack (show (2 * i + 1)) <> ":" <> Text.pack (show (if i == 15 then 32 else 2 * i + 2)) <> ":true:nil:nil"]

spec ∷ Spec
spec = describe "Terrain fixture" $ do
  it "authors air gaps and all sixteen shape identities, and reads each back, complete, with an absent surface and a whole-slope removal that leaves its neighbours" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource program)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          -- the authored runs, shapes and materials, air gaps included, and nothing coalesced across them
          printed `shouldContain` ["column\tsuccess\t0 " <> authoredRuns]
          -- a column carved wholly to air has no surface; one that is not has its highest solid level
          printed `shouldContain` ["no surface\tsuccess\t0 false"]
          printed `shouldContain` ["surface\tsuccess\t0 true 30 soil 15"]
          -- the slope of shape 5 at level 10 goes entirely; the air gap above it, the solid below, and a neighbouring column stay as authored
          printed `shouldContain` ["slope removal\tsuccess\ttrue 1"]
          printed `shouldContain` ["slope after\tsuccess\t1 true nil nil"]
          printed `shouldContain` ["gap above\tsuccess\t1 true nil nil", "solid below\tsuccess\t1 false stone 4", "neighbour column\tsuccess\t1 false soil 5", "neighbour level\tsuccess\t1 false stone 6"]
          -- a removal of air changes nothing and keeps the revision
          printed `shouldContain` ["air removal\tsuccess\tfalse 1"]
          -- the script's own tables, mutated after a call, changed neither the request nor a later answer
          printed `shouldContain` ["argument mutated\tsuccess\t1 true nil nil", "result mutated\tsuccess\t1 true nil nil", "again\tsuccess\t1 true nil nil"]
  it "keeps its retained removals across real eviction and reload of the regions they were made in" $
    withRigConfig tightRigConfig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource offload)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrintedBy world spawned "done"
          printed ← outLines world
          -- every removal changed content, and every removed cell is air, at the arena's revision, after the regions were evicted and loaded again
          mapM_ (\n → printed `shouldContain` ["removal " <> Text.pack (show n) <> "\tsuccess\ttrue " <> Text.pack (show n)]) [1 .. length places]
          mapM_ (\n → printed `shouldContain` ["after " <> Text.pack (show n) <> "\tsuccess\t" <> Text.pack (show (length places)) <> " true nil nil"]) [1 .. length places]
          -- and a cell nobody removed is as authored
          printed `shouldContain` ["untouched\tsuccess\t" <> Text.pack (show (length places)) <> " false stone 0"]
          -- eviction really happened: the service holds fewer regions resident than the removals touched (eighteen)
          model ← inspectModel (rgService rig)
          length (modelRegions model) `shouldSatisfy` (< length places)

-- | The program of the first example.
program ∷ Script
program =
  stepsScript
    "FIX"
    fixture
    [ Step "column" "return api.terrain.column(A, {x = 0, y = 0, z_min = 0, z_max = 32})" "return runs(v)"
    , Step "no surface" "return api.terrain.surface(A, {x = 1, y = 1})" "return v.revision .. ' ' .. tostring(v.occupied)"
    , Step "surface" "return api.terrain.surface(A, {x = 0, y = 0})" "return v.revision .. ' ' .. tostring(v.occupied) .. ' ' .. tostring(v.z) .. ' ' .. tostring(v.material) .. ' ' .. tostring(v.shape)"
    , Step "slope removal" "return api.terrain.remove(A, {x = 0, y = 0, z = 10})" "return tostring(v.changed) .. ' ' .. v.revision"
    , Step "slope after" "return api.terrain.cell(A, {x = 0, y = 0, z = 10})" "return cell(v)"
    , Step "gap above" "return api.terrain.cell(A, {x = 0, y = 0, z = 11})" "return cell(v)"
    , Step "solid below" "return api.terrain.cell(A, {x = 0, y = 0, z = 8})" "return cell(v)"
    , Step "neighbour column" "return api.terrain.cell(A, {x = 1, y = 0, z = 10})" "return cell(v)"
    , Step "neighbour level" "return api.terrain.cell(A, {x = 0, y = 0, z = 12})" "return cell(v)"
    , Step "air removal" "return api.terrain.remove(A, {x = 0, y = 0, z = 11})" "return tostring(v.changed) .. ' ' .. v.revision"
    , Step "argument mutated" "local at = {x = 0, y = 0, z = 10} local r = api.terrain.cell(A, at) at.x = 99 at.z = 7 return r" "return cell(v)"
    , Step "result mutated" "return api.terrain.cell(A, {x = 0, y = 0, z = 10})" "local before = cell(v) v.revision = 12345 v.air = false v.material = 'junk' return before"
    , Step "again" "return api.terrain.cell(A, {x = 0, y = 0, z = 10})" "return cell(v)"
    ]

-- | The removals and reads of the offload example: each in its own region, and each at a cell inside the extent (two by one by two cells)
-- the tight limits name.
places ∷ [(Int, Int, Int)]
places = [(16 * i, 16 * j, z) | i ← [-1 .. 1], j ← [-1 .. 1], z ← [0, -32]]

at ∷ (Int, Int, Int) → Text
at (x, y, z) = "{x = " <> Text.pack (show x) <> ", y = " <> Text.pack (show y) <> ", z = " <> Text.pack (show z) <> "}"
offload ∷ Script
offload =
  stepsScript
    "FIX"
    fixture
    ( [Step ("removal " <> Text.pack (show n)) ("return api.terrain.remove(A, " <> at place <> ")") "return tostring(v.changed) .. ' ' .. v.revision" | (n, place) ← zip [1 :: Int ..] places]
        <> [Step ("after " <> Text.pack (show n)) ("return api.terrain.cell(A, " <> at place <> ")") "return cell(v)" | (n, place) ← zip [1 :: Int ..] places]
        <> [Step "untouched" "return api.terrain.cell(A, {x = 1, y = 0, z = 0})" "return cell(v)"]
    )
