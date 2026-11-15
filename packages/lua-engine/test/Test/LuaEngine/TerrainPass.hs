-- | What the terrain set's multi-capability pass runs (#692): the set named once ("Test.LuaEngine.Terrain.Spec"), every example of
-- it under the pass's label and none twice, with identities no example of the suite's one-capability tree has. Pure: it walks the
-- spec trees and runs nothing.
module Test.LuaEngine.TerrainPass (spec) where

import Control.Monad (forM_)
import Data.List (nub, (\\))
import Test.Hspec
import Test.Hspec.Core.Spec (Item (..), SpecTree, Tree (..), runSpecM)
import Test.Support.Capabilities (PassSetting (..), PassSource (FromDefault))
import qualified Test.LuaEngine.Terrain.Spec as Terrain

-- | The path of every example of a spec, as the runner and the lab name it.
examplePaths ∷ Spec → IO [[String]]
examplePaths s = concatMap (walk []) . snd <$> runSpecM s
  where
    walk ∷ [String] → SpecTree () → [[String]]
    walk prefix (Node label children) = concatMap (walk (prefix <> [label])) children
    walk prefix (NodeWithCleanup _ _ children) = concatMap (walk prefix) children
    walk prefix (Leaf item) = [prefix <> [itemRequirement item]]

spec ∷ Spec
spec = describe "The terrain set's multi-capability pass" $ do
  let setting = PassSetting 2 FromDefault 1
  it "names every module of the set once, with a reason" $ do
    let names = map Terrain.entryModule Terrain.entries
    nub names `shouldBe` names
    forM_ Terrain.entries $ \entry → Terrain.entryReason entry `shouldNotBe` ""
  it "runs every example of the set under the pass's label, and none twice" $ do
    passPaths ← examplePaths (Terrain.passSpec setting)
    inPlace ← examplePaths Terrain.spec
    passPaths `shouldBe` map (Terrain.passLabel :) inPlace
    nub passPaths `shouldBe` passPaths
    length passPaths `shouldSatisfy` (> 0)
  it "gives the pass's examples identities no example of the set in its place has" $ do
    passPaths ← examplePaths (Terrain.passSpec setting)
    inPlace ← examplePaths Terrain.spec
    (passPaths \\ inPlace) `shouldBe` passPaths
