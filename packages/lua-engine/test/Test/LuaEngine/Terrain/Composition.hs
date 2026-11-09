{-# LANGUAGE OverloadedStrings #-}

-- | One VM, one lending and one lease scope, whichever leasing services are injected: no injection has none, terrain alone makes it,
-- graphics alone keeps its own, and both share the graphics scope with its capacity grown by the terrain's. Terrain-disabled
-- compositions keep their namespace and request kinds.
module Test.LuaEngine.Terrain.Composition (spec) where

import Control.Exception (finally)

import Data.Unique (newUnique)
import Hetoimasia.LuaEngine.Facade
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Request (m1Requests)
import Hetoimasia.LuaEngine.Terrain (terrainLeaseCapacity)
import Hetoimasia.Scripting.Lua.Admission (newRequestHandles)
import Hetoimasia.Scripting.Lua.Lease (newLeases)
import Hetoimasia.Scripting.Lua.Lending (newLending)
import Test.Hspec
import Test.LuaEngine.Facade.Graphics (answerTexture, awaitHanded, files, finishAll, injection, newGfx)
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support
import Hetoimasia.Terrain.Runtime (defaultConfig)

-- | A graphics injection that makes only its lease scope: what the composition needs of it. Its capacity is 100 beside what the
-- VM's other services ask for.
scopeOnly ∷ GraphicsInjection
scopeOnly = GraphicsInjection $ \vm → do
  lending ← newLending
  leases ← newLeases lending (100 + gvSharedCapacity vm)
  pure
    GraphicsServices
      { gsLending = lending
      , gsLeases = leases
      , gsLeaseCapacity = 100 + gvSharedCapacity vm
      , gsTypes = []
      , gsEndpoints = []
      , gsDeclare = \_ → pure ()
      , gsForget = \_ → pure ()
      , gsTextureCheck = \_ _ _ _ _ _ → pure Nothing
      , gsTextureStart = \_ _ _ _ _ → pure (GraphicsRefused "not used")
      , gsWindowCheck = \_ _ _ _ _ _ → pure Nothing
      , gsWindowStart = \_ _ _ _ _ → pure (GraphicsRefused "not used")
      , gsPublish = \_ _ → error "not used"
      , gsIssued = \_ _ → pure ()
      , gsReleaseCheck = \_ _ → pure Nothing
      , gsRelease = \_ → pure "done"
      , gsInput = Nothing
      }

spec ∷ Spec
spec = composition >> coexist

composition ∷ Spec
composition = describe "Terrain composition" $ do
  let compose graphics terrain = do
        handles ← newRequestHandles
        requests ← either (\refused → expectationFailure' (show refused)) pure (m1Requests fixedM1Profile handles)
        session ← newUnique
        composeVmServices fixedM1Profile Presentation requests (pure True) session graphics terrain
      expectationFailure' = ioError . userError

  it "makes no scope for a VM with no leasing service, and keeps its facade without terrain" $ do
    VmServices graphics terrain scope ← compose Nothing Nothing
    fmap (const ()) graphics `shouldBe` Nothing
    fmap (const ()) terrain `shouldBe` Nothing
    fmap (\(_, _, capacity) → capacity) scope `shouldBe` Nothing

  it "makes the scope for terrain alone, with the capacity its service's lease cap and the profile derive" $
    withRig $ \rig → do
      VmServices _ terrain scope ← compose Nothing (Just (terrainInjection' rig))
      fmap (const ()) terrain `shouldBe` Just ()
      fmap (\(_, _, capacity) → capacity) scope `shouldBe` Just (terrainLeaseCapacity fixedM1Profile defaultConfig)

  it "composes both over the graphics scope alone, its capacity grown by the terrain's, and allocates no second scope" $
    withRig $ \rig → do
      VmServices graphics terrain scope ← compose (Just scopeOnly) (Just (terrainInjection' rig))
      fmap (const ()) terrain `shouldBe` Just ()
      let terrainCapacity = terrainLeaseCapacity fixedM1Profile defaultConfig
      fmap (\(_, _, capacity) → capacity) scope `shouldBe` Just (100 + terrainCapacity)
      fmap gsLeaseCapacity graphics `shouldBe` Just (100 + terrainCapacity)
      -- the scope the owner is configured with exists, and the capacity above is the one scope's: there is no second
      fmap (const ()) scope `shouldBe` Just ()
  where
    terrainInjection' = fst . maybe (error "no injection") id . shTerrain . presentationOver

-- | One instance that holds a texture and a terrain arena in the one scope: releasing either leaves the other usable.
both ∷ Script
both =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.t = api.content.texture('images/quad.png')", "self.a = api.terrain.open('main', DEF)"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  if api.request.ready(self.t) and api.request.ready(self.a) then"
        , "    local t, a = api.request.take(self.t), api.request.take(self.a)"
        , "    print('held', t.status, a.status)"
        , "    self.tex = t.value.texture self.arena = a.value"
        , "    print('texture release', api.texture.release(self.tex))"
        , "    self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  local c = settle(api, self.q)"
        , "  if c then print('cell after the texture release', c.status, c.value.material) print('arena release', api.terrain.release(self.arena)) print('done') self.s = 2 end"
        , "end"
        ]
    }

coexist ∷ Spec
coexist = describe "Terrain with graphics in one VM" $
  it "holds a texture and an arena in the one shared scope, and releases each without disturbing the other" $
    withRig $ \rig → do
      gx ← newGfx
      ( withWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource both) : files)) $ \world _ runtime →
          withFvm world runtime ((presentationOver rig) {shGraphics = Just (injection gx)}) $ \fvm → do
            spawned ← spawn world fvm "modules-test" mainPath
            awaitHanded gx 1
            answerTexture gx 0
            untilPrintedBy world spawned "done"
            printed ← outLines world
            printed `shouldContain` ["held\tsuccess\tsuccess"]
            printed `shouldContain` ["cell after the texture release\tsuccess\tsoil"]
            printed `shouldContain` ["arena release\tdone"]
            finishAll gx
        )
        `finally` finishAll gx
