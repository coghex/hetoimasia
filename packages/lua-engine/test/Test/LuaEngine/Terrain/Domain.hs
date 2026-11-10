{-# LANGUAGE OverloadedStrings #-}

-- | The expected domain failures of the terrain calls: recoverable results that do not fail the instance, read or unread, and the
-- validator's rejections of a definition that decoded completely.
module Test.LuaEngine.Terrain.Domain (spec) where

import Data.Text (Text)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

-- | A definition whose one run is these fields, for a case that varies one thing.
oneLayer ∷ Text → Text
oneLayer fields = "{ materials = { 'soil', 'stone' }, layers = { " <> fields <> " } }"

-- | Each rejection of the validator, as the definition a script hands: the label, and the definition.
semanticCases ∷ [(Text, Text)]
semanticCases =
  [ ("overlapping layers", oneLayer "{ z_min = 0, z_max = 5, material = 'soil', shape = 0 }, { z_min = 3, z_max = 8, material = 'stone', shape = 0 }")
  , ("unordered layers", oneLayer "{ z_min = 5, z_max = 8, material = 'soil', shape = 0 }, { z_min = 0, z_max = 3, material = 'stone', shape = 0 }")
  , ("unknown material", oneLayer "{ z_min = 0, z_max = 3, material = 'basalt', shape = 0 }")
  , ("empty interval", oneLayer "{ z_min = 3, z_max = 3, material = 'soil', shape = 0 }")
  , ("inverted interval", oneLayer "{ z_min = 5, z_max = 3, material = 'soil', shape = 0 }")
  , ("duplicate materials", "{ materials = { 'soil', 'soil' }, layers = {} }")
  , ("control character in a material", "{ materials = { 'so\\1il' }, layers = {} }")
  , ("overlapping patches", "{ materials = { 'soil' }, layers = {}, patches = { { x = 0, y = 0, z_min = 0, z_max = 5, value = { material = 'soil', shape = 0 } }, { x = 0, y = 0, z_min = 4, z_max = 6, value = { air = true } } } }")
  , ("patch with an unknown material", "{ materials = { 'soil' }, layers = {}, patches = { { x = 0, y = 0, z_min = 0, z_max = 5, value = { material = 'basalt', shape = 0 } } } }")
  ]

-- | The script that opens each semantically bad definition in turn and prints what its request settled as.
semantic ∷ Script
semantic =
  script
    { scPrelude = terrainPrelude <> ["local cases = {"] <> [ "  { " <> label' <> ", " <> definition <> " }," | (label, definition) ← semanticCases, let label' = "'" <> label <> "'" ] <> ["}", "local index = 0"]
    , scInit = ["self.pending = nil"]
    , scUpdate =
        [ "if self.pending then"
        , "  local t = settle(api, self.pending)"
        , "  if t then print(self.label, t.status, t.error and t.error.code) self.pending = nil end"
        , "end"
        , "if not self.pending and index < #cases then"
        , "  index = index + 1"
        , "  self.label = cases[index][1]"
        , "  local r, e = api.terrain.open('arena', cases[index][2])"
        , "  if r == nil then print(self.label, 'busy', e.code) else self.pending = r end"
        , "elseif not self.pending then print('done') end"
        ]
    }

spec ∷ Spec
spec = describe "Terrain domain failures" $ do
  it "settles every validator rejection of a decoded definition as the expected definition failure, with no arena and no name left" $
    withRig $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource semantic)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          pumpUntil world (advanceClock world 2000000000 >> (elem "done" <$> outLines world))
          printed ← outLines world
          mapM_ (\(label, _) → printed `shouldContain` [label <> "\tfailure\tdefinition"]) semanticCases
          limitHeld (rgService rig) "arenas" `shouldReturn` 0
          limitHeld (rgService rig) "leases" `shouldReturn` 0
