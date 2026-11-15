-- | The examples of the multi-capability pass's own machinery (#685): the setting and its refusals, the guard that fails a pass
-- running on fewer capabilities than it claims, and the identity of what the pass runs. They run once, in the sequential phase,
-- on one capability; the pass itself is "Test.TerrainRuntime.Concurrent".
module Test.TerrainRuntime.Pass (spec) where

import Control.Concurrent (getNumCapabilities, setNumCapabilities)
import Control.Monad (forM_)
import Data.List (nub, (\\))
import Test.Hspec
import Test.Hspec.Core.Spec (Item (..), SpecTree, Tree (..), runSpecM)
import Test.TerrainRuntime.Capabilities
import qualified Test.TerrainRuntime.Concurrent as Concurrent
import qualified Test.TerrainRuntime.Parallel as Parallel

-- | The path of every example of a spec, as the runner and the lab name it.
examplePaths ∷ Spec → IO [[String]]
examplePaths s = concatMap (walk []) . snd <$> runSpecM s
  where
    walk ∷ [String] → SpecTree () → [[String]]
    walk prefix (Node label children) = concatMap (walk (prefix <> [label])) children
    walk prefix (NodeWithCleanup _ _ children) = concatMap (walk prefix) children
    walk prefix (Leaf item) = [prefix <> [itemRequirement item]]

spec ∷ Spec
spec = describe "The capability setting and guard of the multi-capability pass" $ do
  describe "its capability setting" $ do
    it "is 2 when nothing asks for another count" $
      resolvePass Nothing 1 `shouldBe` Right (PassSetting 2 FromDefault 1)
    it "takes the count the process started with when it is 2 or more, as the lab's -N<k> sets it" $ do
      resolvePass Nothing 4 `shouldBe` Right (PassSetting 4 FromRtsOption 4)
      resolvePass Nothing 2 `shouldBe` Right (PassSetting 2 FromRtsOption 2)
    it "takes the environment's count before the started one" $ do
      resolvePass (Just "3") 4 `shouldBe` Right (PassSetting 3 FromEnvironment 4)
      resolvePass (Just "2") 1 `shouldBe` Right (PassSetting 2 FromEnvironment 1)
    it "refuses a count below 2, an empty or non-numeric text, a sign, a fraction, a space and an absurd count, naming the variable" $
      forM_ ["", "0", "1", "-2", "+2", "2.5", " 2", "2 ", "two", "1025", "99999999"] $ \text →
        case resolvePass (Just text) 1 of
          Left why → why `shouldContain` passEnvironmentVariable
          Right ok → expectationFailure ("accepted " <> show text <> " as " <> show ok)
    it "accepts the bounds, 2 and 1024" $ do
      fmap passRequested (resolvePass (Just "2") 1) `shouldBe` Right 2
      fmap passRequested (resolvePass (Just "1024") 1) `shouldBe` Right 1024
  describe "its guard" $ do
    it "fails the example that lowers the capability count while it runs, and a pass on the count it claims passes" $ do
      let setting = PassSetting 2 FromDefault 1
      inPass setting (getNumCapabilities >>= (`shouldBe` 2))
      inPass setting (setNumCapabilities 1) `shouldThrow` anyException
      setNumCapabilities 1
    it "reports the requested count, its source and the effective count" $ do
      setNumCapabilities 2
      line ← passLine (PassSetting 2 FromRtsOption 4)
      setNumCapabilities 1
      line `shouldContain` "requested=2 (+RTS -N) effective=2 (at start 4,"
  describe "what it runs" $ do
    it "names every module of the sequential order once, with a reason for being in the set or out of it" $ do
      let names = map Concurrent.entryModule Concurrent.entries
      nub names `shouldBe` names
      forM_ (map Concurrent.entryDisposition Concurrent.entries) $ \d →
        (case d of Concurrent.Concurrent r → r; Concurrent.Alone r → r) `shouldNotBe` ""
    it "runs the concurrent modules' examples, every one under the pass's label and none twice" $ do
      passPaths ← examplePaths (Concurrent.passSpec (PassSetting 2 FromDefault 1))
      concurrentPaths ← examplePaths (forM_ Concurrent.concurrentEntries Concurrent.entrySpec)
      passPaths `shouldBe` map (Concurrent.passLabel :) concurrentPaths
      nub passPaths `shouldBe` passPaths
      length passPaths `shouldSatisfy` (> 0)
    it "gives the pass's examples identities that no example of the one-capability order or the parallel group has" $ do
      passPaths ← examplePaths (Concurrent.passSpec (PassSetting 2 FromDefault 1))
      sequentialPaths ← examplePaths Concurrent.sequentialSpec
      parallelPaths ← examplePaths Parallel.spec
      (passPaths \\ (sequentialPaths <> parallelPaths)) `shouldBe` passPaths
