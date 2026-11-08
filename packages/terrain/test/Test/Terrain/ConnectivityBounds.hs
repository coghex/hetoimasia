-- | Examples for the bounds, yielding, refusal and growth of the connectivity
-- compiler.
--
-- Every configured limit is tested at its exact admissible boundary (the figure
-- the compilation measured, which must succeed) and one below it (which must be
-- refused with that resource), using the measured figures of a small fixture so
-- the routine run stays quick. Resuming in quanta of 1, 17 and 1,024 steps must
-- give identical topology and keys with no step lost or reset, a discarded
-- continuation must change nothing, and a refusal must leave the input intact
-- and expose no result. Growth is shown at spans of @2^20@ and @2^60@: the
-- structure counts, the accounted bytes, the boundary output and the runtime's
-- own allocation (read with "GHC.Stats" across major collections, the
-- convention of "Test.Terrain.Growth") must not depend on the span, and must
-- grow with the authored complexity. The accounted bytes are admission figures;
-- the measured allocation is neither those nor process RSS, and it is reported
-- beside them rather than substituted for them.
module Test.Terrain.ConnectivityBounds (spec) where

import Control.Exception (evaluate)
import Control.Monad (forM_, unless)
import Data.Maybe (fromMaybe)
import Data.Int (Int64)
import Data.Word (Word64)
import GHC.Conc (getAllocationCounter)
import GHC.Stats (RTSStats (allocated_bytes), getRTSStats, getRTSStatsEnabled)
import Hetoimasia.Terrain.Connectivity
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..), sourceDefinitionBytes)
import System.Mem (performMajorGC)
import Test.Hspec
import Test.Terrain.ConnectivityFixtures
import Test.Terrain.Model

cover ∷ Integer → Integer → Int → [LayerSpec]
cover lo hi shape = [stoneLayer Nothing (Just lo), slabLayer lo hi shape, stoneLayer (Just hi) Nothing]

world ∷ [LayerSpec] → [PatchSpec] → SourceSpec
world layers patches = SourceSpec {specMaterials = ["stone", "slab"], specLayers = layers, specPatches = patches}

airPatch, blockPatch ∷ Integer → Integer → Integer → Integer → PatchSpec
airPatch x y lo hi = PatchSpec x y lo hi SpecAir
blockPatch x y lo hi = PatchSpec x y lo hi (SpecSolid "stone" 0)

defaultSpec ∷ LimitsSpec
defaultSpec =
  LimitsSpec
    { specResultBytes = 16 * 1024 * 1024
    , specPeakBytes = 48 * 1024 * 1024
    , specNodes = 65536
    , specRelations = 262144
    , specWorkSteps = 8388608
    , specQuantumSteps = 1024
    }

limitsOf ∷ LimitsSpec → ConnectivityLimits
limitsOf = either (error . ("limits refused: " <>) . show) id . mkConnectivityLimits

-- | A fixture with patches that split, join and repeat, small enough for many
-- compilations.
fixture ∷ SourceSpec
fixture = world (cover 0 100 1) [airPatch 3 4 10 60, blockPatch 9 9 20 30, airPatch 12 4 30 40, airPatch (-5) 20 0 100]

-- | The recipe of the growth table: @n@ shafts and @n@ splits through a ramp
-- layer of @levels@ levels.
scaled ∷ Int → Integer → SourceSpec
scaled n levels =
  world (cover 0 levels 1) (concat [[airPatch (4 * i) (3 * i) 0 levels, blockPatch (4 * i + 2) (3 * i + 1) (levels `div` 4) (levels `div` 4 + 7)] | i ← map toInteger [1 .. n]])

bytesAllocated ∷ IO a → IO Word64
bytesAllocated action = do
  enabled ← getRTSStatsEnabled
  unless enabled $ expectationFailure "GHC runtime statistics are disabled; build the suite with -with-rtsopts=-T"
  performMajorGC
  began ← allocated_bytes <$> getRTSStats
  _ ← action
  performMajorGC
  ended ← allocated_bytes <$> getRTSStats
  pure (ended - began)

-- | The compiled result, forced entirely: structural equality visits every
-- field.
forceResult ∷ Connectivity → IO Bool
forceResult c = evaluate (c == c)

-- | Drive a preparation in quanta of a fixed size, recording the step count
-- after every resume.
drive ∷ Int → ConnectivityLimits → SourceSpec → ([Integer], Either PrepareError (Connectivity, PrepareStats))
drive quantum limits source = go (startPreparation limits (mustSource source)) []
  where
    go preparation seen = case resumePreparation quantum preparation of
      Left e → error ("resume refused: " <> show e)
      Right (Pending next) → go next (workSteps (preparationStats next) : seen)
      Right (Complete result stats) → (reverse (workSteps stats : seen), Right (result, stats))
      Right (Refused e stats) → (reverse (workSteps stats : seen), Left e)

-- | The most the thread allocated while forcing any one single-step resume of a
-- preparation. A step that left work unevaluated for a later one would show as
-- a spike where the work is finally demanded, however small the reported step
-- count is.
worstStepAllocation ∷ SourceSpec → IO Int64
worstStepAllocation source = go (startPreparation defaultConnectivityLimits (mustSource source)) 0
  where
    go preparation worst = do
      started ← getAllocationCounter
      outcome ← case resumePreparation 1 preparation of
        Left e → error (show e)
        Right progress → evaluate progress
      finished ← getAllocationCounter
      let used = started - finished
      case outcome of
        Pending next → go next (max worst used)
        _ → pure (max worst used)

spec ∷ Spec
spec = describe "Source connectivity bounds" $ do
  describe "limit validation" $ do
    it "accepts the approved initial bounds" $ do
      let l = defaultConnectivityLimits
      (limitResultBytes l, limitPeakBytes l) `shouldBe` (16 * 1024 * 1024, 48 * 1024 * 1024)
      (limitNodes l, limitRelations l, limitWorkSteps l, limitQuantumSteps l) `shouldBe` (65536, 262144, 8388608, 1024)
      mkConnectivityLimits defaultSpec `shouldBe` Right defaultConnectivityLimits
    forM_
      [ ("result bytes", \s → s {specResultBytes = 0}, LimitNotPositive FieldResultBytes 0)
      , ("peak bytes", \s → s {specPeakBytes = -1}, LimitNotPositive FieldPeakBytes (-1))
      , ("nodes", \s → s {specNodes = 0}, LimitNotPositive FieldNodes 0)
      , ("relations", \s → s {specRelations = 0}, LimitNotPositive FieldRelations 0)
      , ("work", \s → s {specWorkSteps = 0}, LimitNotPositive FieldWorkSteps 0)
      , ("quantum", \s → s {specQuantumSteps = 0}, LimitNotPositive FieldQuantumSteps 0)
      , ("result bytes above the ceiling", \s → s {specResultBytes = 2 ^ (40 ∷ Int) + 1}, LimitUnrepresentable FieldResultBytes (2 ^ (40 ∷ Int) + 1) (2 ^ (40 ∷ Int)))
      , ("nodes above the ceiling", \s → s {specNodes = 2 ^ (32 ∷ Int) + 1}, LimitUnrepresentable FieldNodes (2 ^ (32 ∷ Int) + 1) (2 ^ (32 ∷ Int)))
      , ("work above the ceiling", \s → s {specWorkSteps = 2 ^ (48 ∷ Int) + 1}, LimitUnrepresentable FieldWorkSteps (2 ^ (48 ∷ Int) + 1) (2 ^ (48 ∷ Int)))
      , ("a quantum above 1,024", \s → s {specQuantumSteps = 1025}, LimitUnrepresentable FieldQuantumSteps 1025 1024)
      , ("a peak below the result", \s → s {specPeakBytes = specResultBytes s - 1}, PeakBelowResult (16 * 1024 * 1024 - 1) (16 * 1024 * 1024))
      ]
      $ \(label, change, expected) →
        it ("refuses " <> label <> " by field, never clamping") $
          mkConnectivityLimits (change defaultSpec) `shouldBe` Left expected
    it "accepts each ceiling exactly" $ do
      mkConnectivityLimits defaultSpec {specResultBytes = 2 ^ (40 ∷ Int), specPeakBytes = 2 ^ (40 ∷ Int)} `shouldSatisfy` isRight'
      mkConnectivityLimits defaultSpec {specNodes = 2 ^ (32 ∷ Int), specRelations = 2 ^ (32 ∷ Int), specWorkSteps = 2 ^ (48 ∷ Int), specQuantumSteps = 1} `shouldSatisfy` isRight'

  describe "resuming" $ do
    let source = mustSource fixture
    it "refuses a request of zero, a negative count or more than the configured maximum, never clamping" $ do
      let start = startPreparation defaultConnectivityLimits source
          small = startPreparation (limitsOf defaultSpec {specQuantumSteps = 8}) source
      forM_ [(0, QuantumNotPositive 0), (-5, QuantumNotPositive (-5)), (1025, QuantumAboveLimit 1025 1024)] $ \(q, e) →
        either Just (const Nothing) (resumePreparation q start) `shouldBe` Just e
      either Just (const Nothing) (resumePreparation 9 small) `shouldBe` Just (QuantumAboveLimit 9 8)
      either (const False) (const True) (resumePreparation 8 small) `shouldBe` True
    forM_ [1, 17, 1024] $ \quantum →
      it ("yields the same topology and keys in quanta of " <> show quantum) $ do
        let (steps, result) = drive quantum defaultConnectivityLimits fixture
            (_, reference) = drive 1024 defaultConnectivityLimits fixture
        case (result, reference) of
          (Right (c, stats), Right (c', stats')) → do
            c `shouldBe` c'
            workSteps stats `shouldBe` workSteps stats'
            workResultBytes stats `shouldBe` workResultBytes stats'
            workPeakBytes stats `shouldBe` workPeakBytes stats'
            -- No step is lost or reset: the count only grows, by at most a
            -- quantum at a time, and ends at the total.
            and (zipWith (<=) steps (drop 1 steps)) `shouldBe` True
            and (zipWith (\a b → b - a <= toInteger quantum) (0 : steps) steps) `shouldBe` True
            last steps `shouldBe` workSteps stats
            workMaxQuantum stats `shouldSatisfy` (<= toInteger quantum)
            length steps `shouldSatisfy` (>= fromInteger (workSteps stats `div` toInteger quantum))
          _ → expectationFailure "a compilation was refused"
    it "reaches the same keys whatever the order or number of queries asked" $ do
      let (c, _) = mustCompile defaultConnectivityLimits fixture
          cells = [(x, y, z) | x ← [-6 .. 14], y ← [3, 4, 5, 9, 20], z ← [0, 15, 25, 35, 99]]
      map (keyAt c) cells `shouldBe` map (keyAt c) cells
      map (keyAt c) (reverse cells) `shouldBe` reverse (map (keyAt c) cells)
    it "discards a continuation without affecting any other value" $ do
      let (reference, _) = mustCompile defaultConnectivityLimits fixture
          half = case resumePreparation 300 (startPreparation defaultConnectivityLimits (mustSource fixture)) of
            Right (Pending p) → workSteps (preparationStats p)
            _ → 0
      half `shouldBe` 300
      -- The dropped continuation was never published and a fresh one gives the
      -- same value.
      fst (mustCompile defaultConnectivityLimits fixture) `shouldBe` reference

  describe "every bound at its exact boundary" $ do
    let (_, measured) = mustCompile defaultConnectivityLimits fixture
        figures =
          [ ("structural nodes", StructuralNodes, workNodes measured, \s v → s {specNodes = v})
          , ("portal relations", PortalRelations, workRelations measured, \s v → s {specRelations = v})
          , ("total work", WorkSteps, workSteps measured, \s v → s {specWorkSteps = v})
          , ("result bytes", ResultBytes, workResultBytes measured, \s v → s {specResultBytes = v})
          , ("peak bytes", PeakBytes, workPeakBytes measured, \s v → s {specPeakBytes = v, specResultBytes = min v (specResultBytes s)})
          ]
    it "measures a fixture with nodes, relations, temporaries and many steps" $ do
      workNodes measured `shouldSatisfy` (> 4)
      workRelations measured `shouldSatisfy` (> 4)
      workPeakBytes measured `shouldSatisfy` (> workResultBytes measured)
      workSteps measured `shouldSatisfy` (> 1024)
    forM_ figures $ \(label, resource, needed, set) → do
      it ("completes with exactly " <> show needed <> " " <> label) $ do
        let r = prepareConnectivity (limitsOf (set defaultSpec needed)) (mustSource fixture)
        fmap snd r `shouldBe` Right measured
      it ("refuses with " <> label <> " one short") $ do
        case prepareConnectivity (limitsOf (set defaultSpec (needed - 1))) (mustSource fixture) of
          Left (Complexity (Refusal got figure limit)) → do
            got `shouldBe` resource
            limit `shouldBe` needed - 1
            figure `shouldSatisfy` (> limit)
          other → expectationFailure ("expected a refusal naming " <> show resource <> ", got " <> show (fmap snd other))
    it "keeps source-definition bytes out of the result and peak figures" $ do
      -- Declaring a thousand more materials makes the definition far larger and
      -- leaves the geometry, and so every accounted figure, unchanged.
      let heavy = fixture {specMaterials = specMaterials fixture ++ ["extra-" <> show i | i ← [1 .. 1000 ∷ Int]]}
      sourceDefinitionBytes (mustSource heavy) `shouldSatisfy` (> sourceDefinitionBytes (mustSource fixture) + 10000)
      statsOf heavy `shouldBe` measured
      -- And the empty world is exactly its charged parts: the header, seven
      -- cuts, two nodes, one relation, two members and one class.
      workResultBytes (statsOf (world [] []))
        `shouldBe` toInteger (headerResultBytes + 7 * cutResultBytes + 2 * nodeResultBytes + relationResultBytes + 2 * memberResultBytes + classResultBytes)
    it "refuses at the first exhausted resource, in a stable order" $ do
      let tight = limitsOf defaultSpec {specNodes = 1, specRelations = 1}
      case prepareConnectivity tight (mustSource fixture) of
        Left (Complexity (Refusal resource _ _)) → resource `shouldBe` StructuralNodes
        other → expectationFailure ("unexpected " <> show (fmap snd other))

  describe "work stays inside the step that pays for it" $ do
    it "allocates a bounded amount in any one-step resume, whatever the size" $ do
      small ← worstStepAllocation (scaled 2 (2 ^ (60 ∷ Int)))
      large ← worstStepAllocation (scaled 8 (2 ^ (60 ∷ Int)))
      putStrLn ("worst single-step allocation, bytes: n=2 " <> show small <> ", n=8 " <> show large)
      -- Megabytes at the relation-to-canonical transition, before the fold's
      -- accumulators were forced inside their steps.
      small `shouldSatisfy` (< 262144)
      large `shouldSatisfy` (< 262144)
      large `shouldSatisfy` (<= 2 * small + 65536)

  describe "temporaries are charged with no node at all" $ do
    let solid = world [stoneLayer Nothing Nothing] [blockPatch (5 * i) 0 0 5 | i ← [1 .. 200]]
        measured = statsOf solid
    it "builds a lattice of boxes that hold no void" $ do
      workNodes measured `shouldBe` 0
      workLatticeCells measured `shouldSatisfy` (> 20000)
      workPeakBytes measured `shouldSatisfy` (> workResultBytes measured + 100000)
    it "completes with exactly the measured peak and is refused one short, naming the peak" $ do
      let at p = prepareConnectivity (limitsOf defaultSpec {specPeakBytes = p, specResultBytes = min p 16777216}) (mustSource solid)
      fmap snd (at (workPeakBytes measured)) `shouldBe` Right measured
      case at (workPeakBytes measured - 1) of
        Left (Complexity (Refusal PeakBytes figure limit)) → (limit, figure > limit) `shouldBe` (workPeakBytes measured - 1, True)
        other → expectationFailure ("unexpected " <> show (fmap snd other))

  describe "valid but excessive complexity" $ do
    let scattered :: Int -> SourceSpec
        scattered n = world (cover 0 10 1) [airPatch (7 * i) (11 * i) 0 10 | i ← map toInteger [1 .. n]]
    it "refuses a source whose connectivity needs more than 65,536 nodes, with the typed resource" $ do
      case prepareConnectivity defaultConnectivityLimits (mustSource (scattered 120)) of
        Left (Complexity (Refusal resource figure limit)) → (resource, figure, limit) `shouldBe` (StructuralNodes, 65537, 65536)
        other → expectationFailure ("unexpected " <> show (fmap snd other))
    it "refuses a lattice larger than the remaining work before taking any of it" $ do
      let patches = [airPatch (5 * i) (9 * i) 0 5 | i ← map toInteger [1 .. 700 ∷ Int]]
          big = world [stoneLayer Nothing Nothing] patches
      case prepareConnectivity defaultConnectivityLimits (mustSource big) of
        Left (Complexity (Refusal resource figure limit)) → do
          resource `shouldBe` WorkSteps
          limit `shouldBe` 8388608
          figure `shouldSatisfy` (> 8388608)
        other → expectationFailure ("unexpected " <> show (fmap snd other))
    it "refuses by a limit lower than a test source needs, and exposes no result" $ do
      let original = mustSource fixture
          limits = limitsOf defaultSpec {specWorkSteps = 1200}
          (steps, outcome) = drive 17 limits fixture
      case outcome of
        Left (Complexity (Refusal WorkSteps _ 1200)) → pure ()
        other → expectationFailure ("unexpected " <> show (fmap snd other))
      last steps `shouldSatisfy` (<= 1200)
      -- The input is the same value afterwards and still compiles.
      mustSource fixture `shouldBe` original
      fmap snd (prepareConnectivity defaultConnectivityLimits original) `shouldSatisfy` isRight'

  describe "growth" $ do
    it "records structure, steps, quantum maxima and accounted bytes that do not depend on the span" $ do
      forM_ [0, 1, 2, 4, 8] $ \n → do
        let at levels = statsOf (scaled n levels)
            narrow = at (2 ^ (20 ∷ Int))
            wide = at (2 ^ (60 ∷ Int))
        putStrLn (row n narrow wide)
        let shape s = (workLatticeCells s, workNodes s, workRelations s, workSteps s, workMaxQuantum s, workResultBytes s, workPeakBytes s)
        shape narrow `shouldBe` shape wide
    it "grows with the authored complexity, not the span" $ do
      let steps n = workSteps (statsOf (scaled n (2 ^ (60 ∷ Int))))
          nodes n = workNodes (statsOf (scaled n (2 ^ (60 ∷ Int))))
      steps 2 `shouldSatisfy` (> steps 1)
      steps 8 `shouldSatisfy` (> steps 4)
      nodes 4 `shouldSatisfy` (> nodes 2)
    it "describes the boundary and the ranges of a component with the same size at both spans" $ do
      let sizes levels =
            let (c, _) = mustCompile defaultConnectivityLimits (scaled 3 levels)
                k = fromMaybe (error "no component") (keyAt c (8, 7, 5))
             in (length (fromMaybe [] (componentBoundary c k)), length (fromMaybe [] (componentRanges c k)), length (fromMaybe [] (componentRelations c k)))
      sizes (2 ^ (20 ∷ Int)) `shouldBe` sizes (2 ^ (60 ∷ Int))
      -- At most six faces per box of the class, and never a face per tile: the
      -- component spans 2^60 levels.
      let (b, r, rel) = sizes (2 ^ (60 ∷ Int))
      b `shouldSatisfy` (<= 6 * r)
      r `shouldSatisfy` (<= fromInteger (workNodes (statsOf (scaled 3 (2 ^ (60 ∷ Int))))))
      rel `shouldSatisfy` (<= fromInteger (workRelations (statsOf (scaled 3 (2 ^ (60 ∷ Int))))))
    it "allocates the same for spans of 2^20 and 2^60 levels, and more for more patches" $ do
      let build n levels = case prepareConnectivity defaultConnectivityLimits (mustSource (scaled n levels)) of
            Right (c, _) → forceResult c
            Left e → error (show e)
      _ ← evaluate (length (show (scaled 4 (2 ^ (20 ∷ Int)))) + length (show (scaled 4 (2 ^ (60 ∷ Int)))))
      _ ← build 4 (2 ^ (20 ∷ Int))
      narrow ← bytesAllocated (build 4 (2 ^ (20 ∷ Int)))
      wide ← bytesAllocated (build 4 (2 ^ (60 ∷ Int)))
      few ← bytesAllocated (build 1 (2 ^ (60 ∷ Int)))
      many ← bytesAllocated (build 8 (2 ^ (60 ∷ Int)))
      putStrLn ("measured allocation, bytes: n=4 span 2^20 " <> show narrow <> ", n=4 span 2^60 " <> show wide <> ", n=1 span 2^60 " <> show few <> ", n=8 span 2^60 " <> show many)
      let s = statsOf (scaled 4 (2 ^ (60 ∷ Int)))
      putStrLn ("accounted admission bytes for n=4: result " <> show (workResultBytes s) <> ", peak " <> show (workPeakBytes s) <> " (not RSS, not allocation)")
      -- The span must not matter, within a constant factor and slack.
      (narrow <= 2 * wide + 1048576, wide <= 2 * narrow + 1048576) `shouldBe` (True, True)
      -- No per-level expansion of 2^20 levels could fit this budget.
      wide `shouldSatisfy` (<= 512 * 1024 * 1024)
      -- More authored complexity costs more.
      many `shouldSatisfy` (> few)
    it "allocates for a covered layer at the cost of its boxes, not its levels" $ do
      let build levels = case prepareConnectivity defaultConnectivityLimits (mustSource (world (cover 0 levels 1) [])) of
            Right (c, _) → forceResult c
            Left e → error (show e)
      _ ← build 1000
      small ← bytesAllocated (build 1000)
      huge ← bytesAllocated (build (2 ^ (60 ∷ Int)))
      (small <= 2 * huge + 1048576, huge <= 2 * small + 1048576) `shouldBe` (True, True)
  where
    isRight' (Right _) = True
    isRight' (Left _) = False
    row n narrow wide =
      "TRA-18 growth n="
        <> show n
        <> " | span 2^20: "
        <> figs narrow
        <> " | span 2^60: "
        <> figs wide
    figs s =
      "boxes "
        <> show (workLatticeCells s)
        <> " nodes "
        <> show (workNodes s)
        <> " relations "
        <> show (workRelations s)
        <> " steps "
        <> show (workSteps s)
        <> " maxQuantum "
        <> show (workMaxQuantum s)
        <> " resultBytes "
        <> show (workResultBytes s)
        <> " peakBytes "
        <> show (workPeakBytes s)
