-- | Deterministic fixtures for the connectivity specs.
--
-- Every generated case is a pure function of its seed, drawn from a SplitMix64
-- stream, so a failure names the seed that reproduces it and nothing depends on
-- a clock or an ambient random state. Three families are built:
--
-- * a /sealed room/: a finite box whose four sides and whose floor and ceiling
--   are full blocks (the sides by a ring of single-column patches, the floor and
--   ceiling by layers), filled by a default layer of one kind and random
--   patches. The room's interior is an exact finite space, so a flood of the
--   window around it is the exact expected topology, with no outside to leak
--   into;
-- * a /covered open world/: the same layers without the side ring, patches in a
--   core region and a window one cell wider than the core on every side. The
--   default content outside the core is translation invariant, so the window
--   reproduces the connectivity of the unbounded plane for the cells inside it;
-- * an /open-top world/ placed so that its air reaches the real upper limit,
--   which makes the exterior classification checkable in a window.
module Test.Terrain.ConnectivityFixtures
  ( -- * Random stream
    Rng
  , rng
  , draw
  , R
  , runR

    -- * Cases
  , Case (..)
  , sealedRoom
  , coveredOpen
  , openTop
  , stoneLayer
  , slabLayer

    -- * Compiling
  , compiled
  , compiledWith
  , mustCompile
  , statsOf
  , keyAt
  , voidAt
  ) where

import Data.Bits (shiftR, xor)
import Data.Word (Word64)
import Hetoimasia.Terrain.Connectivity
import Hetoimasia.Terrain.Source (SourceSpec (..), LayerSpec (..), PatchSpec (..), CellSpec (..))
import Test.Terrain.ConnectivityOracle (Cell3, Window (..))
import Test.Terrain.Model (highest, lowest, mustSource, mustTile, topEnd)

-- | A SplitMix64 stream.
newtype Rng = Rng Word64

rng ∷ Int → Rng
rng seed = Rng (fromIntegral seed * 0x9E3779B97F4A7C15 + 0x1234567)

-- | The next 64 bits and the advanced stream.
draw ∷ Rng → (Word64, Rng)
draw (Rng s) = (z2 `xor` (z2 `shiftR` 31), Rng s')
  where
    s' = s + 0x9E3779B97F4A7C15
    z1 = (s' `xor` (s' `shiftR` 30)) * 0xBF58476D1CE4E5B9
    z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94D049BB133111EB

-- | A tiny state monad over the stream.
newtype R a = R (Rng → (a, Rng))

instance Functor R where
  fmap f (R g) = R $ \s → let (a, s') = g s in (f a, s')

instance Applicative R where
  pure a = R (\s → (a, s))
  R f <*> R g = R $ \s → let (h, s') = f s; (a, s'') = g s' in (h a, s'')

instance Monad R where
  R g >>= f = R $ \s → let (a, s') = g s; R h = f a in h s'

runR ∷ R a → Int → a
runR (R f) seed = fst (f (rng seed))

-- | A number in @[0, n)@.
below ∷ Int → R Int
below n = R $ \s → let (w, s') = draw s in (fromIntegral (w `mod` fromIntegral n), s')

-- | A generated case: the source, the window to flood and the cells to compare.
data Case = Case
  { caseName ∷ String
  , caseSpec ∷ SourceSpec
  , caseWindow ∷ Window
  , caseInner ∷ Cell3 → Bool
  }

stoneLayer ∷ Maybe Integer → Maybe Integer → LayerSpec
stoneLayer lo hi = LayerSpec lo hi "stone" 0

slabLayer ∷ Integer → Integer → Int → LayerSpec
slabLayer lo hi = LayerSpec (Just lo) (Just hi) "slab"

clampPatch ∷ Integer → Integer → Integer → Integer → CellSpec → [PatchSpec]
clampPatch x y lo hi value
  | x < lowest || x > highest || y < lowest || y > highest = []
  | max lowest lo >= min topEnd hi = []
  | otherwise = [PatchSpec x y (max lowest lo) (min topEnd hi) value]

block ∷ CellSpec
block = SpecSolid "stone" 0

randomContent ∷ R CellSpec
randomContent = do
  r ← below 20
  if r < 4
    then pure SpecAir
    else
      if r < 7
        then pure block
        else do
          shape ← below 15
          pure (SpecSolid "slab" (shape + 1))

-- | Random disjoint patches in the columns of a region, each a vertical
-- interval of one content inside @[zLo, zHi)@.
randomPatches ∷ [(Integer, Integer)] → Integer → Integer → R [PatchSpec]
randomPatches columns zLo zHi = concat <$> mapM column columns
  where
    column (x, y) = do
      present ← below 8
      if present >= 5
        then pure []
        else do
          count ← (+ 1) <$> below 2
          go x y zLo count
    go _ _ _ 0 = pure []
    go x y from n
      | from >= zHi = pure []
      | otherwise = do
          gap ← below 3
          len ← (+ 1) <$> below 3
          let lo = from + toInteger gap
              hi = min zHi (lo + toInteger len)
          if lo >= zHi
            then pure []
            else do
              value ← randomContent
              rest ← go x y hi (n - 1 ∷ Int)
              pure (clampPatch x y lo hi value ++ rest)

layersFor ∷ Maybe Int → Integer → Integer → [LayerSpec]
layersFor def lo hi =
  [stoneLayer Nothing (Just lo) | lo > lowest]
    ++ [slabLayer lo hi s | Just s ← [def]]
    ++ [stoneLayer (Just hi) Nothing | hi < topEnd]

-- | A sealed room at the given origin: a footprint of @w × d@ cells and @h@
-- levels, the default layer's shape (or air), and random interior patches.
sealedRoom ∷ String → (Integer, Integer, Integer) → (Int, Int, Int) → Maybe Int → Int → Case
sealedRoom name (ox, oy, oz) (w, d, h) def seed =
  Case
    { caseName = name
    , caseSpec = SourceSpec ["stone", "slab"] (layersFor def oz (oz + toInteger h)) (ring ++ interior)
    , caseWindow = Window (ox - 1, ox + toInteger w + 1) (oy - 1, oy + toInteger d + 1) (oz - 4, oz + toInteger h + 4)
    , caseInner = const True
    }
  where
    perimeter =
      [(x, y) | x ← [ox - 1 .. ox + toInteger w], y ← [oy - 1, oy + toInteger d]]
        ++ [(x, y) | y ← [oy .. oy + toInteger d - 1], x ← [ox - 1, ox + toInteger w]]
    ring = concat [clampPatch x y (oz - 3) (oz + toInteger h + 3) block | (x, y) ← perimeter]
    columns = [(x, y) | x ← [ox .. ox + toInteger w - 1], y ← [oy .. oy + toInteger d - 1]]
    interior = runR (randomPatches columns (oz - 2) (oz + toInteger h + 2)) seed

-- | A covered world with a core of patches and no side ring. The compared cells
-- reach @margin@ cells past the core on every side, and the window one more, so
-- the bulk boxes of a default family (rows, columns, levels) beyond the core are
-- compared as well as the boxes the patches cut.
coveredOpen ∷ String → Integer → (Integer, Integer, Integer) → (Int, Int, Int) → Maybe Int → Int → Case
coveredOpen name margin (ox, oy, oz) (w, d, h) def seed =
  Case
    { caseName = name
    , caseSpec = SourceSpec ["stone", "slab"] (layersFor def oz (oz + toInteger h)) interior
    , caseWindow = Window (ox - margin - 1, ox + toInteger w + margin + 1) (oy - margin - 1, oy + toInteger d + margin + 1) (oz - 4, oz + toInteger h + 4)
    , caseInner = \(x, y, _) → x >= ox - margin && x < ox + toInteger w + margin && y >= oy - margin && y < oy + toInteger d + margin
    }
  where
    columns = [(x, y) | x ← [ox .. ox + toInteger w - 1], y ← [oy .. oy + toInteger d - 1]]
    interior = runR (randomPatches columns (oz - 2) (oz + toInteger h + 2)) seed

-- | A world whose air reaches the real upper limit: stone below @oz@, a slab of
-- the default kind on @[oz, oz + h)@ and air above it up to the limit, with
-- patches in a core. The window reaches the limit, so the exterior
-- classification is checkable.
openTop ∷ String → (Integer, Integer) → (Int, Int, Int) → Int → Int → Case
openTop name (ox, oy) (w, d, h) gap seed =
  Case
    { caseName = name
    , caseSpec = SourceSpec ["stone", "slab"] [stoneLayer Nothing (Just oz), slabLayer oz (oz + toInteger h) slabShape] interior
    , caseWindow = Window (ox - 2, ox + toInteger w + 2) (oy - 2, oy + toInteger d + 2) (oz - 3, topEnd)
    , caseInner = \(x, y, _) → x >= ox - 1 && x < ox + toInteger w + 1 && y >= oy - 1 && y < oy + toInteger d + 1
    }
  where
    oz = topEnd - toInteger h - toInteger gap
    slabShape = 1 + seed `mod` 15
    columns = [(x, y) | x ← [ox .. ox + toInteger w - 1], y ← [oy .. oy + toInteger d - 1]]
    interior = runR (randomPatches columns (oz - 2) topEnd) seed

-- ---------------------------------------------------------------------------
-- Compiling

-- | Compile under the approved defaults, failing the example on a refusal.
compiled ∷ SourceSpec → Connectivity
compiled = compiledWith defaultConnectivityLimits

compiledWith ∷ ConnectivityLimits → SourceSpec → Connectivity
compiledWith limits = fst . mustCompile limits

mustCompile ∷ ConnectivityLimits → SourceSpec → (Connectivity, PrepareStats)
mustCompile limits spec = case prepareConnectivity limits (mustSource spec) of
  Right result → result
  Left e → error ("compilation refused: " <> show e)

statsOf ∷ SourceSpec → PrepareStats
statsOf = snd . mustCompile defaultConnectivityLimits

-- | The component of the void of the cell at a coordinate.
keyAt ∷ Connectivity → (Integer, Integer, Integer) → Maybe ComponentKey
keyAt c (x, y, z) = componentOf c (mustTile x y z)

voidAt ∷ Connectivity → (Integer, Integer, Integer) → VoidLookup
voidAt c (x, y, z) = lookupVoid c (mustTile x y z) 0
