-- | How much of a store family runs, and the fixtures a family builds only when one of its examples runs.
--
-- A protected family of the store suite (a class-closing property, or an example backed by a negative control, a
-- mutation or an independent oracle) has two depths. The ROUTINE depth is a fixed, deterministic, strictly smaller set
-- of the family's parameters (seeds, histories, limits, progress points, sizes) that still catches every control
-- recorded for the family (@docs/evidence/terrain/suite-budget/README.md@ lists them); it is what @terrain-runtime-tests@
-- runs. The FULL depth is the family's original parameter set; the optional probe @terrain-runtime-full-depth-tests@
-- runs it (@docs/test_classification.md@, @docs/test_suites.md@). A family module exports @spec@ (routine) and
-- @fullSpec@ (full), both built from one definition that takes a 'Depth', so the two cannot drift apart: the routine
-- parameters are chosen by 'atDepth' next to the full ones.
--
-- A large fixture is built by the first example that reads it, not while the spec tree is constructed ('Fixture').
-- A run that selects no example builds none, a focused run of a module builds only what that module's selected
-- examples read, and a fixture several examples share is built once. Each build prints one @FIXTURE built <name>@
-- line, which is the construction record the evidence quotes.
--
-- State: a 'Fixture' owns one cell, written by the first 'readFixture' of the process and then only read; the specs
-- run sequentially on one thread, and the lock makes a concurrent reader wait for the build rather than start a
-- second one. It is never reset or disposed: it holds immutable values for the life of the process.
module Test.TerrainRuntime.Store.Depth
  ( Depth (..)
  , atDepth
  , Fixture
  , newFixture
  , readFixture
  , fixtureBuilds
  , lazily
  , spec
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Control.Exception (ErrorCall (..), throwIO, try)
import System.IO.Unsafe (unsafeInterleaveIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Test.Hspec
import Test.TerrainRuntime.Output (printLine)
import Test.TerrainRuntime.Isolation (assertSequential)

-- | The depth of a family: its fixed smaller representative, or its original parameters.
data Depth = Routine | Full
  deriving stock (Eq, Show)

-- | The routine value at the routine depth, the original value at the full depth.
atDepth ∷ Depth → a → a → a
atDepth Routine routine _ = routine
atDepth Full _ full = full

-- | A value built the first time it is read, at most once per process.
data Fixture a = Fixture
  { fxName ∷ String
  , fxBuild ∷ IO a
  , fxCell ∷ MVar (Maybe a)
  , fxBuilds ∷ IORef Int
  }

-- | A fixture that is not built yet. Cheap: it runs nothing until 'readFixture'.
newFixture ∷ String → IO a → IO (Fixture a)
newFixture name build = Fixture name build <$> newMVar Nothing <*> newIORef 0

-- | The value, built (and recorded on the output) by the first read. A build that fails leaves the fixture unbuilt and
-- rethrows, so the example that read it fails with the build's own failure.
readFixture ∷ Fixture a → IO a
readFixture fx = modifyMVar (fxCell fx) $ \cell → case cell of
  Just v → pure (cell, v)
  Nothing → do
    v ← fxBuild fx
    atomicModifyIORef' (fxBuilds fx) (\n → (n + 1, ()))
    printLine ("FIXTURE built " <> fxName fx)
    pure (Just v, v)

-- | An action run by the first read of its result (lazy IO), recorded as a fixture, after checking that nothing runs beside it
-- ("Test.TerrainRuntime.Isolation": it measures the whole process): the measured rows of a module are read by the examples that need them, not built while the spec tree is constructed.
lazily ∷ String → IO a → IO a
lazily name act = do
  fx ← newFixture name (assertSequential name >> act)
  unsafeInterleaveIO (readFixture fx)

-- | How many times the fixture was built: 0 before its first read, 1 after.
fixtureBuilds ∷ Fixture a → IO Int
fixtureBuilds fx = readMVar (fxCell fx) >> readIORef (fxBuilds fx)

spec ∷ Spec
spec = describe "a fixture built when it is first read" $ do
  it "is not built by being created, and is built once however often it is read" $ do
    built ← newIORef (0 ∷ Int)
    fx ← newFixture "Depth.spec counted" (atomicModifyIORef' built (\n → (n + 1, n + 1)))
    fixtureBuilds fx >>= (`shouldBe` 0)
    readIORef built >>= (`shouldBe` 0)
    first ← readFixture fx
    second ← readFixture fx
    (first, second) `shouldBe` (1, 1)
    fixtureBuilds fx >>= (`shouldBe` 1)
    readIORef built >>= (`shouldBe` 1)
  it "is not recorded as built when its build fails, and the next read builds again" $ do
    attempts ← newIORef (0 ∷ Int)
    fx ← newFixture "Depth.spec failing" $ do
      n ← atomicModifyIORef' attempts (\k → (k + 1, k + 1))
      if n == 1 then throwIO (ErrorCall "the first build fails") else pure n
    r ← try (readFixture fx)
    r `shouldBe` Left (ErrorCall "the first build fails")
    fixtureBuilds fx >>= (`shouldBe` 0)
    readFixture fx >>= (`shouldBe` 2)
    fixtureBuilds fx >>= (`shouldBe` 1)
  it "chooses the routine value at the routine depth and the original at the full depth" $ do
    atDepth Routine (1 ∷ Int) 2 `shouldBe` 1
    atDepth Full (1 ∷ Int) 2 `shouldBe` 2
