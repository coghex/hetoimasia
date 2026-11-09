{-# LANGUAGE OverloadedStrings #-}

-- | One VM, one lending and one lease scope, whichever leasing services are injected: no injection has none, terrain alone makes it,
-- graphics alone keeps its own, and both share the graphics scope with its capacity grown by the terrain's. Terrain-disabled
-- compositions keep their namespace and request kinds.
module Test.LuaEngine.Terrain.Composition (spec) where

import Data.Unique (newUnique)
import Hetoimasia.LuaEngine.Facade
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Request (m1Requests)
import Hetoimasia.LuaEngine.Terrain (terrainLeaseCapacity)
import Hetoimasia.Scripting.Lua.Admission (newRequestHandles)
import Hetoimasia.Scripting.Lua.Lease (newLeases)
import Hetoimasia.Scripting.Lua.Lending (newLending)
import Test.Hspec
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
spec = describe "Terrain composition" $ do
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
