-- | The Lua engine package's component specs, composed under one @LuaEngine@ group, and then, last, the terrain set's
-- multi-capability pass under its own label ("Test.LuaEngine.Terrain.Spec"): nothing runs beside it or after it.
--
-- Every example of the @LuaEngine@ group runs on ONE capability, with the count the process started with put back after it,
-- so a count the process starts with (the lab's @+RTS -N<k>@) reaches the pass and nothing else (as the terrain-runtime
-- suite's runner keeps its phases at their own counts).
module Test.LuaEngine.Spec (spec) where

import Control.Concurrent (getNumCapabilities, setNumCapabilities)
import Control.Exception (finally)
import qualified Test.LuaEngine.Behavior as Behavior
import qualified Test.LuaEngine.Boot as Boot
import qualified Test.LuaEngine.Boundary as Boundary
import qualified Test.LuaEngine.Data.Spec as Data
import qualified Test.LuaEngine.Facade.Spec as Facade
import qualified Test.LuaEngine.Integrated.Spec as Integrated
import qualified Test.LuaEngine.Loader as Loader
import qualified Test.LuaEngine.Manifest.Examples as Examples
import qualified Test.LuaEngine.Manifest.Schema as Schema
import qualified Test.LuaEngine.Manifest.Syntax as Syntax
import qualified Test.LuaEngine.Manifest.Tick as Tick
import qualified Test.LuaEngine.Modules.Spec as Modules
import qualified Test.LuaEngine.Owned as Owned
import qualified Test.LuaEngine.Profile as Profile
import qualified Test.LuaEngine.Request.Spec as Requests
import qualified Test.LuaEngine.Scene.Spec as Scene
import qualified Test.LuaEngine.Session.Spec as Session
import qualified Test.LuaEngine.Terrain.Spec as Terrain
import qualified Test.LuaEngine.TerrainPass as TerrainPass
import qualified Test.LuaEngine.Texture.Spec as Texture
import Test.Hspec (Spec, around_, describe, runIO)
import Test.Support.Capabilities (PassSetting)

spec ∷ PassSetting → Spec
spec pass = do
  describe "LuaEngine" $ do
   started ← runIO getNumCapabilities
   around_ (\example → (setNumCapabilities 1 >> example) `finally` setNumCapabilities started) $ do
    Examples.spec
    Syntax.spec
    Schema.spec
    Tick.spec
    Profile.spec
    Requests.spec
    Data.spec
    Modules.spec
    Texture.spec
    Terrain.spec
    Scene.spec
    Facade.spec
    Session.spec
    Behavior.spec
    Boot.spec
    Loader.spec
    Boundary.spec
    Integrated.spec
    Owned.spec
    TerrainPass.spec
  Terrain.passSpec pass
