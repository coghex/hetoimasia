{-# LANGUAGE OverloadedStrings #-}

-- | What a script may hand the terrain calls, and what each rejection is.
--
-- The decode layer and the validator are classified here, one case each: every rejection of the copy or the decode is an
-- ordinary Lua error raised before admission, with no request, arena or credit left behind and no metamethod run; every
-- rejection of the validator of a definition that decoded completely is the expected @definition@ failure.
module Test.LuaEngine.Terrain.Validation (spec) where

import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

-- | A definition with one layer and this field replaced, for a case that varies one thing.
layer ∷ Text → Text
layer fields = "{ materials = { 'soil' }, layers = { { " <> fields <> " } } }"

-- | Rejections of the decode layer: ordinary errors, raised before anything is admitted.
decodeCases ∷ [Case]
decodeCases =
  [ Case "colon call" "api.terrain:open('a', DEF)" (Refused ["terrain_open"])
  , Case "no arguments" "api.terrain.open()" (Refused ["expected 2 values, found 0"])
  , Case "one argument" "api.terrain.open('a')" (Refused ["expected 2 values, found 1"])
  , Case "three arguments" "api.terrain.open('a', DEF, nil)" (Refused ["expected 2 values, found 3"])
  , Case "name a number" "api.terrain.open(5, DEF)" (Refused ["expected"])
  , Case "empty name" "api.terrain.open('', DEF)" (Refused ["name is empty"])
  , Case "name over the limit" "api.terrain.open(string.rep('n', 129), DEF)" (Refused ["longer than 128"])
  , Case "name with invalid UTF-8" "api.terrain.open('\\xff', DEF)" (Refused ["UTF-8"])
  , Case "definition not a table" "api.terrain.open('a', 5)" (Refused ["expected record"])
  , Case "definition without materials" "api.terrain.open('a', { layers = {} })" (Refused ["materials"])
  , Case "definition without layers" "api.terrain.open('a', { materials = {} })" (Refused ["layers"])
  , Case "definition with an extra field" "api.terrain.open('a', { materials = {}, layers = {}, extra = 1 })" (Refused ["extra"])
  , Case "materials a string" "api.terrain.open('a', { materials = 'soil', layers = {} })" (Refused ["expected list"])
  , Case "material a number" "api.terrain.open('a', { materials = { 5 }, layers = {} })" (Refused ["expected"])
  , Case "materials sparse" "api.terrain.open('a', { materials = { [1] = 'a', [3] = 'b' }, layers = {} })" (Refused ["not a sequence"])
  , Case "material empty" "api.terrain.open('a', { materials = { '' }, layers = {} })" (Refused ["material identifier is empty"])
  , Case "material over 64 bytes" "api.terrain.open('a', { materials = { string.rep('m', 65) }, layers = {} })" (Refused ["longer than 64 bytes"])
  , Case "material with invalid UTF-8" "api.terrain.open('a', { materials = { '\\xff' }, layers = {} })" (Refused ["UTF-8"])
  , Case "layer a number" "api.terrain.open('a', { materials = {}, layers = { 5 } })" (Refused ["expected record"])
  , Case "layer without a material" "api.terrain.open('a', { materials = {}, layers = { { shape = 0 } } })" (Refused ["material"])
  , Case "layer without a shape" "api.terrain.open('a', { materials = { 'soil' }, layers = { { material = 'soil' } } })" (Refused ["shape"])
  , Case "layer with an extra field" "api.terrain.open('a', { materials = { 'soil' }, layers = { { material = 'soil', shape = 0, tint = 1 } } })" (Refused ["tint"])
  , Case "shape 16" ("api.terrain.open('a', " <> layer "material = 'soil', shape = 16" <> ")") (Refused ["shape identity 0 .. 15"])
  , Case "shape -1" ("api.terrain.open('a', " <> layer "material = 'soil', shape = -1" <> ")") (Refused ["shape identity 0 .. 15"])
  , Case "shape an integral float" ("api.terrain.open('a', " <> layer "material = 'soil', shape = 1.0" <> ")") (Refused ["a float where an integer is declared"])
  , Case "shape a string" ("api.terrain.open('a', " <> layer "material = 'soil', shape = '1'" <> ")") (Refused ["expected integer"])
  , Case "z_min a float" ("api.terrain.open('a', " <> layer "z_min = 0.0, material = 'soil', shape = 0" <> ")") (Refused ["a float where an integer is declared"])
  , Case "z_min below the supported range" ("api.terrain.open('a', " <> layer "z_min = -(1 << 62) - 1, material = 'soil', shape = 0" <> ")") (Refused ["z_min"])
  , Case "z_min the highest level plus one" ("api.terrain.open('a', " <> layer "z_min = 1 << 62, material = 'soil', shape = 0" <> ")") (Refused ["z_min"])
  , Case "z_max one past the endpoint" ("api.terrain.open('a', " <> layer "z_max = (1 << 62) + 1, material = 'soil', shape = 0" <> ")") (Refused ["z_max"])
  , Case "patch coordinate out of range" "api.terrain.open('a', { materials = {}, layers = {}, patches = { { x = 1 << 62, y = 0, z_min = 0, z_max = 1, value = { air = true } } } })" (Refused ["patch's x"])
  , Case "patch without a value" "api.terrain.open('a', { materials = {}, layers = {}, patches = { { x = 0, y = 0, z_min = 0, z_max = 1 } } })" (Refused ["value"])
  , Case "patch value air and a material" "api.terrain.open('a', { materials = { 'soil' }, layers = {}, patches = { { x = 0, y = 0, z_min = 0, z_max = 1, value = { air = true, material = 'soil', shape = 0 } } } })" (Refused ["air carries no material"])
  , Case "patch value neither" "api.terrain.open('a', { materials = { 'soil' }, layers = {}, patches = { { x = 0, y = 0, z_min = 0, z_max = 1, value = {} } } })" (Refused ["patch value"])
  , Case "patches not a list" "api.terrain.open('a', { materials = {}, layers = {}, patches = 5 })" (Refused ["expected list"])
  , Case "function in a definition" "api.terrain.open('a', { materials = {}, layers = {}, patches = function() end })" (Refused ["function"])
  , Case "a cycle" "(function() local d = { materials = {}, layers = {} } d.layers = d return api.terrain.open('a', d) end)()" (Refused ["contains itself"])
  , Case "a metatable with traps" "api.terrain.open('a', setmetatable({ materials = {}, layers = {} }, { __index = function() hit = true end, __len = function() hit = true return 0 end, __pairs = function() hit = true end }))" (Refused ["metatable"])
  , Case "cell: handle a string" "api.terrain.cell('x', { x = 0, y = 0, z = 0 })" (Refused ["expected capability"])
  , Case "cell: one argument" "api.terrain.cell(A)" (Refused ["expected 2 values, found 1"])
  , Case "cell: coordinate a float" "api.terrain.cell(A, { x = 0.0, y = 0, z = 0 })" (Refused ["a float where an integer is declared"])
  , Case "cell: coordinate a string" "api.terrain.cell(A, { x = '0', y = 0, z = 0 })" (Refused ["expected integer"])
  , Case "cell: coordinate out of range" "api.terrain.cell(A, { x = 1 << 62, y = 0, z = 0 })" (Refused ["supported range"])
  , Case "cell: coordinate low boundary" "api.terrain.cell(A, { x = -(1 << 62), y = 0, z = 0 })" Accepted
  , Case "cell: coordinate high boundary" "api.terrain.cell(A, { x = (1 << 62) - 1, y = 0, z = 0 })" Accepted
  , Case "cell: coordinate below the boundary" "api.terrain.cell(A, { x = -(1 << 62) - 1, y = 0, z = 0 })" (Refused ["supported range"])
  , Case "cell: missing field" "api.terrain.cell(A, { x = 0, y = 0 })" (Refused ["z"])
  , Case "cell: extra field" "api.terrain.cell(A, { x = 0, y = 0, z = 0, w = 1 })" (Refused ["w"])
  , Case "column: inverted range" "api.terrain.column(A, { x = 0, y = 0, z_min = 3, z_max = 3 })" (Refused ["greater than z_min"])
  , Case "column: range upper end above 2^62" "api.terrain.column(A, { x = 0, y = 0, z_min = 0, z_max = (1 << 62) + 1 })" (Refused ["z_max"])
  , Case "surface: extra argument" "api.terrain.surface(A, { x = 0, y = 0 }, nil)" (Refused ["expected 2 values, found 3"])
  , Case "remove: pick a number" "api.terrain.remove(A, { x = 0, y = 0, z = 0 }, 5)" (Refused ["expected capability"])
  , Case "remove: pick a table" "api.terrain.remove(A, { x = 0, y = 0, z = 0 }, {})" (Refused ["expected capability"])
  , Case "remove: pick an arena handle" "api.terrain.remove(A, { x = 0, y = 0, z = 0 }, A)" (Refused ["expected a terrain_pick handle"])
  , Case "release: no arguments" "api.terrain.release()" (Refused ["expected 1 values, found 0"])
  , Case "release: not a handle" "api.terrain.release('x')" (Refused ["expected capability"])
  , Case "attach: empty name" "api.terrain.attach('')" (Refused ["name is empty"])
  , Case "attach: a number" "api.terrain.attach(5)" (Refused ["expected"])
  ]

spec ∷ Spec
spec = describe "Terrain validation" $ do
  it "refuses every copy and decode rejection as an ordinary error, before admission, and runs no metamethod" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource checks)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          pumpUntil world (advanceClock world 2000000000 >> (elem "done" <$> outLines world))
          printed ← outLines world
          checkCases decodeCases printed
          -- No metamethod ran.
          printed `shouldContain` ["trap\tfalse"]
          -- and no refusal kept a place of the request bank: the accepted boundary cases hold theirs, and every other place is free
          let accepted = length [() | Case _ _ Accepted ← decodeCases]
          printed `shouldContain` ["places after the refusals\t" <> Text.pack (show (16 - accepted))]
          -- Nothing a refused call did reached the service: the one arena the example opened, and its one lease, are all it holds.
          limitHeld (rgService rig) "arenas" `shouldReturn` 1
          limitHeld (rgService rig) "leases" `shouldReturn` 1
  where
    -- The arena the handle cases use is opened first; the rest of the cases run in the update that finds it open.
    checks =
      script
        { scPrelude = terrainPrelude <> ["hit = false", "local A"]
        , scInit = ["self.open = api.terrain.open('main', DEF)"]
        , scUpdate =
            [ "if not self.ran then"
            , "  local t = settle(api, self.open)"
            , "  if t then"
            , "    self.ran = true"
            , "    A = t.value"
            ]
              <> map (("    " <>) . caseLua) decodeCases
              <> [ "    print('trap', hit)"
                 , -- every refused call above was refused before admission: had one kept a place of the request bank, the the sixteen reads below would not all be taken
                   "    local taken = 0"
                 , "    for i = 1, 16 do if api.terrain.cell(A, {x = i, y = 0, z = 0}) ~= nil then taken = taken + 1 end end"
                 , "    print('places after the refusals', taken)"
                 , "    print('done')"
                 , "  end"
                 , "end"
                 ]
        }
