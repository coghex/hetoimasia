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

import Control.Concurrent.STM
import Control.Exception (try)
import Control.Monad (forM_)
import Hetoimasia.Terrain.Cell (zRangeHi, zRangeLo)
import qualified Hetoimasia.Terrain.Connectivity as C
import Hetoimasia.Terrain.Query (Run (..))
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Source (CellSpec (..), PatchSpec (..), SourceSpec (..), defaultSourceLimits, mkSource)
import Test.Hspec
import Test.TerrainRuntime.Fixtures

-- | The compiler's figures for the fixture source, at the default limits.
fixtureStats ∷ IO C.PrepareStats
fixtureStats = case mkSource defaultSourceLimits soilOverStone of
  Left e → fail ("the fixture source was refused: " <> show e)
  Right src → either (fail . show) (pure . snd) (C.prepareConnectivity C.defaultConnectivityLimits src)

-- | The default limits with the result bound set.
withResult ∷ Integer → C.ConnectivityLimits
withResult bytes = limitsOf bytes (toInteger (C.limitPeakBytes C.defaultConnectivityLimits)) (toInteger (C.limitNodes C.defaultConnectivityLimits))

-- | The default limits with the result, peak and node bounds set (validated).
limitsOf ∷ Integer → Integer → Integer → C.ConnectivityLimits
limitsOf bytes peak nodes =
  either (error . show) id $
    C.mkConnectivityLimits
      C.LimitsSpec
        { C.specResultBytes = bytes
        , C.specPeakBytes = peak
        , C.specNodes = nodes
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

  it "refuses the baseline's 2,048-level alternating column as source_complexity at the compiled-result bound (16,777,224 against 16,777,216), publishes nothing and releases the name" $
    withService defaultConfig $ \svc → do
      client ← okOf (registerClient svc)
      -- the fixture the Lua column examples used before #665: 1,024 one-level soil patches two levels apart in air
      let alternating = SourceSpec ["soil"] [] [PatchSpec 0 0 (2 * k) (2 * k + 1) (SpecSolid "soil" 0) | k ← [0 .. 1023]]
      outcome ← okOf (openArena svc client "alt" alternating) >>= await svc
      case outcome of
        Left (Failed (StorageFailed (FaultComplexity resource needed limit))) →
          (resource, needed, limit) `shouldBe` ("ResultBytes", 16777224, 16777216)
        other → expectationFailure ("expected source_complexity, got " <> show other)
      -- nothing was published, and the name is free again
      lease ← okOf (openArena svc client "alt" soilOverStone) >>= await svc >>= expectSuccess
      _ ← readCell svc lease (tile 0 0 0)
      settleChecks svc

  it "constructs a service whose compile account holds every arena the cap admits at its bound exactly, and refuses one byte of peak less at construction" $ do
    let result = 1024 * 1024
        nodes = 1024
        bound = result + 32 * nodes
    -- the account is three arenas at their bound and one compilation's peak; with the peak at one
    -- arena's bound it holds four arenas at their bound exactly
    withService defaultConfig {configMaxArenas = 4, configConnectivity = limitsOf result bound nodes} $ \svc →
      atomically (inspectCompileSTM svc) `shouldReturn` (0, fromInteger (4 * bound))
    -- one byte of peak less: four open arenas would not fit, so the configuration is refused
    try (withService defaultConfig {configMaxArenas = 4, configConnectivity = limitsOf result (bound - 1) nodes} (\_ → pure ())) >>= \case
      Left (ConfigCompileBank needed account) → (needed, account) `shouldBe` (4 * bound, 4 * bound - 1)
      Left other → expectationFailure ("expected the compile account refused, got " <> show other)
      Right () → expectationFailure "a compile account that cannot hold the cap was accepted"

  it "fits four arenas at their per-arena bound with the fourth compiling (the account exactly full), and still admits a maximal column query beside them" $ do
    stats ← fixtureStats
    -- limits at which the fixture is a maximal arena: its result and node figures are the bounds
    let result = C.workResultBytes stats
        nodes = C.workNodes stats
        bound = result + 32 * nodes
        peak = max bound (C.workPeakBytes stats)
        account = 3 * bound + peak
    service ← newTVarIO Nothing
    seen ← newTVarIO []
    -- at each compilation's start (its peak charged, no quantum run yet), what the account holds
    let probe = Probe $ \case
          PointCompiling _ → readTVarIO service >>= mapM_ (\svc → atomically (inspectCompileSTM svc >>= \u → modifyTVar' seen (<> [u])))
          _ → pure ()
    withServiceUsing defaultConfig {configMaxArenas = 4, configConnectivity = limitsOf result peak nodes} alwaysAdmitting probe $ \svc → do
      atomically (writeTVar service (Just svc))
      client ← okOf (registerClient svc)
      leases ← mapM (\name → okOf (openArena svc client name soilOverStone) >>= await svc >>= expectSuccess) ["a", "b", "c", "d"]
      -- the k-th compilation ran beside k arenas each holding exactly the per-arena bound; the fourth
      -- filled the account exactly
      readTVarIO seen `shouldReturn` [(fromInteger (k * bound + peak), fromInteger account) | k ← [0 .. 3]]
      atomically (inspectCompileSTM svc) `shouldReturn` (fromInteger (4 * bound), fromInteger account)
      -- a maximal column query: 8,192 levels across 257 regions, the residency model's largest request
      -- (179,020,032 resident bytes at the approved limits), admitted with the four arenas open
      forM_ (take 1 leases) $ \lease → do
        answer ← okOf (columnAt svc lease (column 0 0) (range 16 (16 + 8192))) >>= await svc >>= expectSuccess
        sum [zRangeHi (runRange r) - zRangeLo (runRange r) | r ← columnAnswerRuns answer] `shouldBe` 8192
      settleChecks svc
