-- | What the terrain set's multi-capability pass runs (#692): the set named once ("Test.LuaEngine.Terrain.Spec"), every example of
-- it under the pass's label but those it names as held out, and none twice, with identities no example of the suite's one-capability tree has. Pure: it walks the
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
  let held = map (("Terrain" :) . Terrain.heldPath) Terrain.heldOut
  let settings = [PassSetting count FromDefault 1 | count ← [2, 4]]
  it "names every module of the set once, with a reason" $ do
    let names = map Terrain.entryModule Terrain.entries
    nub names `shouldBe` names
    forM_ Terrain.entries $ \entry → Terrain.entryReason entry `shouldNotBe` ""
  it "runs every example of the set under the pass's label but those it holds out, and none twice, at 2 and at 4 capabilities" $ do
    inPlace ← examplePaths Terrain.spec
    forM_ settings $ \setting → do
      passPaths ← examplePaths (Terrain.passSpec setting)
      passPaths `shouldBe` map (Terrain.passLabel :) (filter (`notElem` held) inPlace)
      nub passPaths `shouldBe` passPaths
      length passPaths `shouldSatisfy` (> 0)
  it "names each example it holds out once, with a reason naming the issue that returns it, and that example runs in its place" $ do
    inPlace ← examplePaths Terrain.spec
    nub held `shouldBe` held
    forM_ Terrain.heldOut $ \h → do
      length (filter (== ("Terrain" : Terrain.heldPath h)) inPlace) `shouldBe` 1
      Terrain.heldReason h `shouldSatisfy` \reason → '#' `elem` reason
  it "gives the pass's examples identities no example of the set in its place has" $ do
    inPlace ← examplePaths Terrain.spec
    forM_ settings $ \setting → do
      passPaths ← examplePaths (Terrain.passSpec setting)
      (passPaths \\ inPlace) `shouldBe` passPaths
