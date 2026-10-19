-- | Staging and the commit (requirements 4 and 5): a batch that changes nothing until the tick
-- commits, one snapshot per completed tick, and a tick whose work did not finish committing nothing.
module Test.Domains.Staging (spec) where

import Control.Concurrent.STM (readTVarIO)
import Control.Exception (try)
import Data.Foldable (toList)
import qualified Data.Sequence as Seq
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains
  ( Bounds (boundStaging)
  , Domains (domainsShared)
  , DomainsConfig (configBounds, configGameplaySource, configExtensions)
  , DomainsDefect (TickAlreadyInProgress, TickNotCompleted)
  , Extension (Extension)
  , GameSnapshot (snapTick, snapWorld)
  , Where (InGameplay)
  )
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedCommitted))
import Hetoimasia.Sample.LuaDomains.World (Entity (..), World (worldEntities, worldRandom, worldTick))
import Hetoimasia.Scripting.Lua.Registration (WaitKind (WaitLogical), namespace, waitOperation)
import Hetoimasia.Scripting.Lua.Value (Schema (SInteger))
import Test.Domains.Support
import Test.Hspec

entity ∷ GameSnapshot → Int → Entity
entity snapshot index = Seq.index (worldEntities (snapWorld snapshot)) index

spec ∷ Spec
spec = describe "staging and the commit" $ do
  it "keeps a staged batch invisible, to gameplay's own reads and to everyone else, until the tick commits" $
    withSample
      ( \config →
          config
            { configGameplaySource =
                luaLines
                  [ "function update(self, dt)"
                  , "  fx.record('staged ' .. tostring(staging.move(0, 3, 4)))"
                  , "  local present, x, y, version = world.entity(0)"
                  , "  fx.record('read after staging ' .. x .. ',' .. y .. ',' .. version)"
                  , "  fx.hold('before the commit')"
                  , "  staging.finish()"
                  , "end"
                  ]
            }
      )
      $ \fx _ domains → withReleased fx ["before the commit"] $ do
        collect ← spawn (stepCommitted domains)
        awaitEntered fx "before the commit"
        -- Held inside the tick: the committed world and the snapshot are the initial ones.
        committed ← readTVarIO (sharedCommitted (domainsShared domains))
        (snapshot, revision) ← snapshotNow domains
        (revision, snapTick snapshot, worldTick committed) `shouldBe` (0, 0, 0)
        fmap entityVersion (toList (worldEntities committed)) `shouldBe` replicate 8 0
        fxLines fx `shouldReturn` ["staged true", "read after staging 0,0,0"]
        releaseGate fx "before the commit"
        done ← collect
        (entityX (entity done 0), entityY (entity done 0), entityVersion (entity done 0)) `shouldBe` (3, 4, 1)
        snapTick done `shouldBe` 1

  it "publishes exactly one snapshot for each completed tick, advancing the committed tick by one" $
    withSample id $ \_ _ domains → do
      ticks ← mapM (const (stepCommitted domains >>= \snapshot → (,) (snapTick snapshot) <$> revisionNow domains)) [1 .. 5 ∷ Int]
      ticks `shouldBe` [(n, fromIntegral n) | n ← [1 .. 5 ∷ Word64]]
      committedTick domains `shouldReturn` 5

  it "answers a move past the staging bound as a recoverable refusal and applies only what was staged" $
    withSample
      ( \config →
          config
            { configBounds = (configBounds config) {boundStaging = 2}
            , configGameplaySource =
                luaLines
                  [ "function update(self, dt)"
                  , "  local answers = {}"
                  , "  for i = 1, 4 do answers[i] = tostring(staging.move(i, 1, 0)) end"
                  , "  fx.record(table.concat(answers, ' '))"
                  , "  staging.finish()"
                  , "end"
                  ]
            }
      )
      $ \fx _ domains → do
        snapshot ← stepCommitted domains
        fxLines fx `shouldReturn` ["true true false false"]
        map entityVersion (toList (worldEntities (snapWorld snapshot))) `shouldBe` [0, 1, 1, 0, 0, 0, 0, 0]

  describe "a tick whose work did not finish" $
    mapM_
      unfinished
      [ ("never says it is done", "function update(self, dt) staging.move(0, 1, 0) end")
      , ("waits across the tick after saying it is done", "function update(self, dt) staging.move(0, 1, 0) staging.finish() sched.wait_ticks(5) end")
      ]
  where
    unfinished (label, source) = it ("commits nothing and says so when the update " <> label) $
      withSample (\config → config {configGameplaySource = luaLines [source], configExtensions = withWait (configExtensions config)}) $ \_ _ domains → do
        committedBefore ← readTVarIO (sharedCommitted (domainsShared domains))
        outcome ← try (stepCommitted domains)
        case outcome of
          Left (TickNotCompleted tick) → tick `shouldBe` 1
          Left other → expectationFailure ("a different defect: " <> show other)
          Right _ → expectationFailure "the tick committed"
        -- Nothing was committed or published: the world, its stream and the snapshot are as they were.
        committedAfter ← readTVarIO (sharedCommitted (domainsShared domains))
        committedAfter `shouldBe` committedBefore
        worldRandom committedAfter `shouldBe` worldRandom committedBefore
        revisionNow domains `shouldReturn` 0
        committedTick domains `shouldReturn` 0
        -- The session is halted: a tick that did not complete is not stepped past.
        again ← try (stepCommitted domains)
        case again of
          Left (TickAlreadyInProgress tick) → tick `shouldBe` 1
          Left other → expectationFailure ("a different defect: " <> show other)
          Right _ → expectationFailure "a second tick began"
        revisionNow domains `shouldReturn` 0
    withWait extensions shared =
      extensions shared <> [Extension (namespace "sched" [waitOperation "wait_ticks" WaitLogical [SInteger]]) InGameplay []]
