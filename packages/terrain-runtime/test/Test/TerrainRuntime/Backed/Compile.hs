-- | Opening an arena compiles its source in bounded quanta under the service's own compile
-- account (owner decision 2026-11-13, option B), through the production owner and compiler.
--
-- The account's figures are derived by the ONE function that charges real work ('sharedCharge'):
-- the per-arena bound is it at the compiler's result and node limits, and the account is every
-- other arena's bound plus one compilation's peak. A source the compiler accepts cannot pass the
-- per-arena bound, so its one-past figure is the compiler's own refusal, @source_complexity@
-- naming the bound. The exact and one-past examples run under validated reduced limits; one pins
-- the figures at the approved default limits.
module Test.TerrainRuntime.Backed.Compile (spec) where

import qualified Hetoimasia.Terrain.Connectivity as C
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Source (defaultSourceLimits, mkSource)
import Test.Hspec
import Test.TerrainRuntime.Fixtures

-- | The compiler's figures for the fixture source, at the default limits.
fixtureStats ∷ IO C.PrepareStats
fixtureStats = case mkSource defaultSourceLimits soilOverStone of
  Left e → fail ("the fixture source was refused: " <> show e)
  Right src → either (fail . show) (pure . snd) (C.prepareConnectivity C.defaultConnectivityLimits src)

-- | The default limits with the result bound set.
withResult ∷ Integer → C.ConnectivityLimits
withResult bytes =
  either (error . show) id $
    C.mkConnectivityLimits
      C.LimitsSpec
        { C.specResultBytes = bytes
        , C.specPeakBytes = toInteger (C.limitPeakBytes C.defaultConnectivityLimits)
        , C.specNodes = toInteger (C.limitNodes C.defaultConnectivityLimits)
        , C.specRelations = toInteger (C.limitRelations C.defaultConnectivityLimits)
        , C.specWorkSteps = toInteger (C.limitWorkSteps C.defaultConnectivityLimits)
        , C.specQuantumSteps = toInteger (C.limitQuantumSteps C.defaultConnectivityLimits)
        }

spec ∷ Spec
spec = describe "The compile account" $ do
  it "pins the per-arena bound and the account at the approved default limits: 18 MiB and 102 MiB for four arenas" $ do
    perArenaBound C.defaultConnectivityLimits `shouldBe` 16 * 1024 * 1024 + 32 * 65536
    compileAccountFor 4 C.defaultConnectivityLimits `shouldBe` 3 * (16 * 1024 * 1024 + 32 * 65536) + 48 * 1024 * 1024

  it "opens an arena whose connectivity is exactly the result bound, and refuses one byte less as source_complexity naming the bound" $ do
    stats ← fixtureStats
    let exact = C.workResultBytes stats
    withService defaultConfig {configConnectivity = withResult exact} $ \svc → do
      _ ← openMain svc "main"
      settleChecks svc
    withService defaultConfig {configConnectivity = withResult (exact - 1)} $ \svc → do
      client ← okOf (registerClient svc)
      outcome ← okOf (openArena svc client "main" soilOverStone) >>= await svc
      case outcome of
        Left (Failed (StorageFailed (FaultComplexity resource needed limit))) → do
          resource `shouldBe` "ResultBytes"
          limit `shouldBe` fromInteger (exact - 1)
          needed `shouldSatisfy` (> limit)
        other → expectationFailure ("expected source_complexity, got " <> show other)
      settleChecks svc
