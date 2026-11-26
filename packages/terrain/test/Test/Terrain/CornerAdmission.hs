-- | Corner cells admitted through the source, the queries, connectivity and
-- discovery.
--
-- A stored cell reads as the tagged key the geometry table lists; the two
-- families never alias; and the three authorities that decide where empty space
-- passes (the opening geometry, the connectivity compiler and discovery) agree
-- on every corner shape beside air, with the worked lower-block case and both
-- sealed valleys checked against literals.
module Test.Terrain.CornerAdmission (spec) where

import Control.Monad (forM_)
import Data.Maybe (fromMaybe, isJust)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Changes (ChangeLimits (..), Changes, RemoveOutcome (..), emptyChanges, removeCell)
import Hetoimasia.Terrain.Connectivity (defaultConnectivityLimits, prepareConnectivity)
import Hetoimasia.Terrain.Coordinate (axisValue)
import Hetoimasia.Terrain.Discovery
import Hetoimasia.Terrain.Opening (airOpenings, connectCells, connectionArea, keyOpenings)
import Hetoimasia.Terrain.Query
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Shape
import Hetoimasia.Terrain.Source
import Test.Hspec
import Test.Terrain.ConnectivityFixtures (compiled, keyAt)
import Test.Terrain.Model

-- | The source cell spec that authors a key: its side identity or its corner mask.
keySpec ∷ String → ShapeKey → CellSpec
keySpec material key = case (keySide key, keyCorner key) of
  (Just shape, _) → SpecSolid material (shapeIdValue shape)
  (Nothing, Just mask) → SpecCorner material (cornerMaskValue mask)
  (Nothing, Nothing) → SpecAir

mustMask ∷ Int → CornerMask
mustMask = either (error . show) id . mkCornerMask

cornerKey ∷ Int → ShapeKey
cornerKey = fromMaybe (error "corner zero") . resolveCorner . mustMask

sideK ∷ Int → ShapeKey
sideK = sideKey . either (error . show) id . mkShapeId

-- | One column at the origin holding the given cells from level 0 up, nothing else.
columnSpec ∷ [CellSpec] → SourceSpec
columnSpec cells = SourceSpec ["stone"] [] [PatchSpec 0 0 z (z + 1) c | (z, c) ← zip [0 ..] cells]

columnSource ∷ [CellSpec] → Source
columnSource = mustSource . columnSpec

readAt ∷ Source → Integer → Cell
readAt source z = cellAt source emptyChanges (mustTile 0 0 z)

runsOver ∷ Source → Integer → Integer → [(Integer, Integer, Cell)]
runsOver source lo hi = case columnRuns defaultQueryLimits source emptyChanges (mustColumn 0 0) (mustRange lo hi) of
  Left e → error (show e)
  Right runs → [(zRangeLo (runRange r), zRangeHi (runRange r), runCell r) | r ← runs]

limitless ∷ ChangeLimits
limitless = ChangeLimits 1000000

removeAt ∷ Source → Changes → Integer → RemoveOutcome
removeAt source changes z = either (error . show) id (removeCell limitless source (mustTile 0 0 z) changes)

spec ∷ Spec
spec = describe "Corner cells through source and reads" $ do
  taggedReads
  sourceForms
  distinctFamilies
  removals
  admission
  agreement

taggedReads ∷ Spec
taggedReads = describe "a stored cell's tagged key" $ do
  it "equals the geometry table's key for each of the 31 occupied keys, and air has none" $ do
    length allShapeKeys `shouldBe` 31
    forM_ allShapeKeys $ \key → do
      let cell = readAt (columnSource [keySpec "stone" key]) 0
      cellShapeKey cell `shouldBe` Just key
      fmap snd (cellOccupant cell) `shouldBe` Just key
    cellShapeKey Air `shouldBe` Nothing
    cellShapeKey (readAt (columnSource [SpecAir]) 0) `shouldBe` Nothing
    cellShapeKey (readAt (columnSource []) 5) `shouldBe` Nothing
  it "is what the highest occupied cell reports with its material, for either family" $
    forM_ allShapeKeys $ \key → do
      let source = columnSource [SpecAir, keySpec "stone" key, SpecAir]
      fmap (\o → (toInteger (axisValue (occupiedLevel o)), materialIdString (occupiedMaterial o), occupiedShape o)) (highestOccupied source emptyChanges (mustColumn 0 0))
        `shouldBe` Just (1, "stone", key)

sourceForms ∷ Spec
sourceForms = describe "the explicit corner forms" $ do
  it "keep the numeric side inputs and their refusals" $ do
    mkSource defaultSourceLimits (columnSpec [SpecSolid "stone" 3]) `shouldSatisfy` isRight'
    mkSource defaultSourceLimits (columnSpec [SpecSolid "stone" 16]) `shouldBe` Left (InvalidShape (PatchRecord 0) 16)
    mkSource defaultSourceLimits (SourceSpec ["stone"] [LayerSpec Nothing Nothing "stone" (-1)] []) `shouldBe` Left (InvalidShape (LayerRecord 0) (-1))
    readAt (columnSource [SpecSolid "stone" 3]) 0 `shouldBe` cellOf "stone" 3
  it "refuse an out-of-range mask for a patch or a layer, whole, with no partial source" $ do
    mkSource defaultSourceLimits (columnSpec [SpecCorner "stone" 16]) `shouldBe` Left (InvalidCornerMask (PatchRecord 0) 16)
    mkSource defaultSourceLimits (columnSpec [SpecCorner "stone" (-1)]) `shouldBe` Left (InvalidCornerMask (PatchRecord 0) (-1))
    mkSource defaultSourceLimits (columnSpec [SpecAir, SpecCorner "stone" 3, SpecCorner "stone" 99]) `shouldBe` Left (InvalidCornerMask (PatchRecord 2) 99)
    mkSource defaultSourceLimits (SourceSpec ["stone"] [CornerLayerSpec Nothing (Just 0) "stone" 16] []) `shouldBe` Left (InvalidCornerMask (LayerRecord 0) 16)
    mkSource defaultSourceLimits (SourceSpec ["stone"] [CornerLayerSpec Nothing (Just 0) "stone" 5] []) `shouldSatisfy` isRight'
  it "read a layer or a patch of a nonzero mask as that corner solid" $ do
    let source = mustSource (SourceSpec ["stone", "slab"] [cornerLayer 0 2 "slab" 6] [patchCorner 1 0 0 1 "stone" 9])
    readAt source 1 `shouldBe` CornerSolid (mustMaterial "slab") (mustMask 6)
    cellAt source emptyChanges (mustTile 1 0 0) `shouldBe` CornerSolid (mustMaterial "stone") (mustMask 9)
    cellAt source emptyChanges (mustTile 1 0 1) `shouldBe` CornerSolid (mustMaterial "slab") (mustMask 6)
  it "treat mask zero as air that is still a validated, counted record" $ do
    let spec0 = SourceSpec ["stone"] [stoneBelow 0, cornerLayer 0 5 "stone" 0] [patchCorner 0 0 7 8 "stone" 0]
        source = mustSource spec0
    sourceAuthoredRuns source `shouldBe` 3
    mkSource defaultSourceLimits (SourceSpec ["stone"] [cornerLayer 0 5 "ghost" 0] []) `shouldBe` Left (UnknownMaterial (LayerRecord 0) "ghost")
    mkSource defaultSourceLimits (SourceSpec ["stone"] [cornerLayer 0 5 "stone" 0, cornerLayer 4 6 "stone" 0] []) `shouldBe` Left (OverlappingLayers 1)
    mkSource defaultSourceLimits (SourceSpec ["stone"] [cornerLayer 5 5 "stone" 0] []) `shouldSatisfy` isLeft'
    mkSource defaultSourceLimits (SourceSpec ["stone"] [] [PatchSpec 0 0 0 1 (SpecCorner "stone" 0), PatchSpec 0 0 0 1 SpecAir]) `shouldBe` Left (OverlappingPatches 1)
    -- its covered cells read as air, join the air around them, and are never occupied
    readAt source 2 `shouldBe` Air
    cellShapeKey (readAt source 7) `shouldBe` Nothing
    runsOver source (-1) 9 `shouldBe` [(-1, 0, cellOf "stone" 0), (0, 9, Air)]
    fmap (toInteger . axisValue . occupiedLevel) (highestOccupied source emptyChanges (mustColumn 0 0)) `shouldBe` Just (-1)
    highestOccupied (mustSource (SourceSpec ["stone"] [cornerLayer 0 5 "stone" 0] [])) emptyChanges (mustColumn 0 0) `shouldBe` Nothing
  where
    isRight' = either (const False) (const True)
    isLeft' = either (const True) (const False)
    stoneBelow hi = LayerSpec Nothing (Just hi) "stone" 0

distinctFamilies ∷ Spec
distinctFamilies = describe "side and corner keys of one material" $ do
  it "never coalesce into one run: side 0, corner 15 and side 15 stay apart in a column read" $ do
    let source = columnSource [SpecSolid "stone" 0, SpecCorner "stone" 15, SpecCorner "stone" 15, SpecSolid "stone" 15, SpecSolid "stone" 0, SpecSolid "stone" 0]
    runsOver source 0 6
      `shouldBe` [ (0, 1, cellOf "stone" 0)
                 , (1, 3, CornerSolid (mustMaterial "stone") (mustMask 15))
                 , (3, 4, cellOf "stone" 15)
                 , (4, 6, cellOf "stone" 0)
                 ]
  it "read as distinct keys in a cell, in the highest occupied cell and in a layer pair" $ do
    cellShapeKey (readAt (columnSource [SpecSolid "stone" 0]) 0) `shouldBe` Just (sideK 0)
    cellShapeKey (readAt (columnSource [SpecCorner "stone" 15]) 0) `shouldBe` Just (cornerKey 15)
    sideK 0 `shouldSatisfy` (/= cornerKey 15)
    sideK 15 `shouldSatisfy` (/= cornerKey 15)
    let top spec' = fmap occupiedShape (highestOccupied (mustSource spec') emptyChanges (mustColumn 0 0))
    top (SourceSpec ["stone"] [LayerSpec Nothing (Just 4) "stone" 0] []) `shouldBe` Just (sideK 0)
    top (SourceSpec ["stone"] [CornerLayerSpec Nothing (Just 4) "stone" 15] []) `shouldBe` Just (cornerKey 15)
    runsOver (mustSource (SourceSpec ["stone"] [LayerSpec Nothing (Just 2) "stone" 0, CornerLayerSpec (Just 2) (Just 4) "stone" 15] [])) 0 4
      `shouldBe` [(0, 2, cellOf "stone" 0), (2, 4, CornerSolid (mustMaterial "stone") (mustMask 15))]

removals ∷ Spec
removals = describe "removing a corner cell" $ do
  it "retains the removal as for a side cell, and the cell then reads as air" $ do
    let source = columnSource [SpecCorner "stone" 6, SpecSolid "stone" 6, SpecCorner "stone" 9]
        first = removeAt source emptyChanges 2
    removeChanged first `shouldBe` True
    cellAt source (removeResult first) (mustTile 0 0 2) `shouldBe` Air
    cellShapeKey (cellAt source (removeResult first) (mustTile 0 0 1)) `shouldBe` Just (sideK 6)
    fmap occupiedShape (highestOccupied source (removeResult first) (mustColumn 0 0)) `shouldBe` Just (sideK 6)
    removeChanged (removeAt source (removeResult first) 2) `shouldBe` False
  it "records nothing for a corner-zero cell, which is air" $ do
    let source = columnSource [SpecCorner "stone" 0]
    removeChanged (removeAt source emptyChanges 0) `shouldBe` False

admission ∷ Spec
admission = describe "connectivity" $ do
  it "compiles a source holding every corner mask beside side shapes" $ do
    let patches =
          [PatchSpec m 0 0 1 (SpecCorner "stone" (fromInteger m)) | m ← [1 .. 15]]
            <> [PatchSpec (20 + s) 0 0 1 (SpecSolid "stone" (fromInteger s)) | s ← [0 .. 15]]
        world = SourceSpec ["stone"] [LayerSpec Nothing (Just 0) "stone" 0] patches
    prepareConnectivity defaultConnectivityLimits (mustSource world) `shouldSatisfy` either (const False) (const True)

-- | Stone below level 2, with the cell at level 1 of the origin column a corner
-- bank, a block (or air) under it at level 0, and air above the ground.
bankWorld ∷ Int → CellSpec → SourceSpec
bankWorld mask below =
  SourceSpec
    ["stone"]
    [LayerSpec Nothing (Just 2) "stone" 0]
    [PatchSpec 0 0 0 1 below, PatchSpec 0 0 1 2 (SpecCorner "stone" mask)]

discoveryOf ∷ SourceSpec → (TileCoordLike → Observed CellKnowledge)
discoveryOf world = \tile → queryCell env (retainedProvider (newRetained (ArenaId 1))) (mustTile' tile)
  where
    source = mustSource world
    env = mkEnv defaultDiscoveryLimits source (compiled world)
    mustTile' (x, y, z) = mustTile x y z

type TileCoordLike = (Integer, Integer, Integer)

knownOf ∷ (TileCoordLike → Observed CellKnowledge) → TileCoordLike → (SolidKnowledge, VoidKnowledge)
knownOf at tile = case observedValue (at tile) of
  Right k → (cellSolid k, cellVoid k)
  Left e → error (show e)

agreement ∷ Spec
agreement = describe "the opening geometry, the compiler and discovery" $ do
  it "expose the lower solid under a NW-high bank over x+y>1 and discover it known" $
    forM_ [SpecSolid "stone" 0, SpecCorner "stone" 15] $ \block → do
      let at = discoveryOf (bankWorld 1 block)
      snd (knownOf at (0, 0, 1)) `shouldBe` VoidKnown
      fst (knownOf at (0, 0, 0)) `shouldBe` SolidKnown
  it "connect the voids when air replaces that block, and report the shared opening as area one half" $ do
    let world = bankWorld 1 SpecAir
        c = compiled world
        at = discoveryOf world
    (isJust (keyAt c (0, 0, 0)), keyAt c (0, 0, 0) == keyAt c (0, 0, 1)) `shouldBe` (True, True)
    snd (knownOf at (0, 0, 0)) `shouldBe` VoidKnown
    sum (map connectionArea (connectCells (mustTile 0 0 0) airOpenings (mustTile 0 0 1) (keyOpenings (cornerKey 1)))) `shouldBe` (1 / 2)
  it "open no route and expose no solid through either low-diagonal valley's base" $
    forM_ [5, 10] $ \mask → do
      let sealedBelow = discoveryOf (bankWorld mask (SpecSolid "stone" 0))
          airBelow = bankWorld mask SpecAir
          c = compiled airBelow
      snd (knownOf sealedBelow (0, 0, 1)) `shouldBe` VoidKnown
      fst (knownOf sealedBelow (0, 0, 0)) `shouldBe` SolidUnknown
      (keyAt c (0, 0, 0), keyAt c (0, 0, 1)) `shouldSatisfy` (\(a, b) → isJust a && isJust b && a /= b)
      snd (knownOf (discoveryOf airBelow) (0, 0, 0)) `shouldBe` VoidUnknown
      connectCells (mustTile 0 0 0) airOpenings (mustTile 0 0 1) (keyOpenings (cornerKey mask)) `shouldBe` []
  it "agree for every key beside air: a connection exists, the compiler joins the voids and discovery knows the lower void" $
    forM_ allShapeKeys $ \key → do
      let world =
            SourceSpec
              ["stone"]
              [LayerSpec Nothing (Just 2) "stone" 0]
              [PatchSpec 0 0 0 1 SpecAir, PatchSpec 0 0 1 2 (keySpec "stone" key)]
          joined = not (null (connectCells (mustTile 0 0 0) airOpenings (mustTile 0 0 1) (keyOpenings key)))
          c = compiled world
          lowerKnown = snd (knownOf (discoveryOf world) (0, 0, 0)) == VoidKnown
          -- a key with no void at all (a full block) has no component to join
          topHasVoid = isJust (keyAt c (0, 0, 1))
      (topHasVoid && keyAt c (0, 0, 0) == keyAt c (0, 0, 1)) `shouldBe` joined
      lowerKnown `shouldBe` joined
