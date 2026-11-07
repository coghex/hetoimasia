-- | Examples for the declarative source: validation, the half-open limits and
-- the byte and count bounds.
--
-- Every expected value is a literal or comes from the independent model in
-- "Test.Terrain.Model".
module Test.Terrain.Source (spec) where

import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Coordinate (CoordinateError (..))
import Hetoimasia.Terrain.Changes (emptyChanges)
import Hetoimasia.Terrain.Query
import Hetoimasia.Terrain.Source
import Test.Hspec
import Test.Terrain.Model

refusal ∷ SourceSpec → Maybe SourceError
refusal = either Just (const Nothing) . mkSource defaultSourceLimits

base ∷ SourceSpec
base = SourceSpec ["a", "b"] [] []

withLayers ∷ [LayerSpec] → SourceSpec
withLayers ls = base {specLayers = ls}

withPatches ∷ [PatchSpec] → SourceSpec
withPatches ps = base {specPatches = ps}

spec ∷ Spec
spec = describe "Source definition" $ do
  acceptanceSpec
  materialSpec
  layerSpec
  patchSpec
  limitSpec

acceptanceSpec ∷ Spec
acceptanceSpec = describe "accepting a definition" $ do
  it "accepts the empty definition, whose every cell is air" $ do
    let source = mustSource base
    sourceAuthoredRuns source `shouldBe` 0
    cellAt source emptyChanges (mustTile 3 4 5) `shouldBe` Air
    highestOccupied source emptyChanges (mustColumn 3 4) `shouldBe` Nothing
  it "reports its authored records and materials" $ do
    let source = mustSource soilOverStone {specPatches = [patchAir 1 1 0 1]}
    sourceLayerCount source `shouldBe` 2
    sourcePatchCount source `shouldBe` 1
    sourceAuthoredRuns source `shouldBe` 3
    map materialIdString (sourceMaterials source) `shouldBe` ["soil", "stone"]
  it "accounts a definition with the stated fixed charges" $ do
    -- 64 header + (16 + 4) soil + (16 + 5) stone + 2 layers * 24 + 1 patch * 40.
    sourceDefinitionBytes (mustSource soilOverStone {specPatches = [patchAir 1 1 0 1]}) `shouldBe` 64 + 20 + 21 + 48 + 40
  it "holds the configured soil over stone as ordinary layers" $ do
    let source = mustSource soilOverStone
        at z = fromCell (cellAt source emptyChanges (mustTile 0 0 z))
    at 1 `shouldBe` Nothing
    at 0 `shouldBe` Just ("soil", 0)
    at (-3) `shouldBe` Just ("soil", 0)
    at (-4) `shouldBe` Just ("stone", 0)
    at lowest `shouldBe` Just ("stone", 0)
  it "uses the same mechanism for any thickness and identifiers" $ do
    let thick =
          mustSource
            base
              { specMaterials = ["loam", "granite"]
              , specLayers = [softLayer Nothing (Just 0) "granite" 3, layer 0 4 "loam" 5]
              }
        at z = fromCell (cellAt thick emptyChanges (mustTile 9 (-9) z))
    at 3 `shouldBe` Just ("loam", 5)
    at 4 `shouldBe` Nothing
    at (-1) `shouldBe` Just ("granite", 3)
  it "does not instantiate columns: a source answers any column from the same records" $ do
    let source = mustSource soilOverStone
    sourceLayerCount source `shouldBe` 2
    fromCell (cellAt source emptyChanges (mustTile highest lowest 0)) `shouldBe` Just ("soil", 0)

materialSpec ∷ Spec
materialSpec = describe "materials" $ do
  it "refuses a duplicate identifier, naming its index" $
    refusal (base {specMaterials = ["a", "b", "a"]}) `shouldBe` Just (DuplicateMaterialId 2 "a")
  it "refuses an empty identifier" $
    refusal (base {specMaterials = ["a", ""]}) `shouldBe` Just (InvalidMaterialId 1 EmptyMaterialId)
  it "refuses a control character and a surrogate code point" $ do
    refusal (base {specMaterials = ["a\nb"]}) `shouldBe` Just (InvalidMaterialId 0 (InvalidMaterialChar '\n'))
    refusal (base {specMaterials = ["a\0"]}) `shouldBe` Just (InvalidMaterialId 0 (InvalidMaterialChar '\0'))
    refusal (base {specMaterials = ["a\xD800"]}) `shouldBe` Just (InvalidMaterialId 0 (InvalidMaterialChar '\xD800'))
  it "accepts an identifier of exactly 64 UTF-8 bytes and refuses 65" $ do
    mkMaterialId (replicate 64 'x') `shouldSatisfy` isRight
    mkMaterialId (replicate 65 'x') `shouldBe` Left (MaterialIdTooLong 64)
  it "counts UTF-8 bytes, not characters" $ do
    mkMaterialId (replicate 32 '\xE9') `shouldSatisfy` isRight
    mkMaterialId (replicate 33 '\xE9') `shouldBe` Left (MaterialIdTooLong 64)
    fmap materialIdBytes (mkMaterialId (replicate 21 '\x20AC')) `shouldBe` Right 63
    mkMaterialId (replicate 22 '\x20AC') `shouldBe` Left (MaterialIdTooLong 64)
    fmap materialIdBytes (mkMaterialId "\x1F600") `shouldBe` Right 4
  it "accepts 4,095 materials and refuses 4,096" $ do
    let names n = ["m" <> show i | i ← [1 .. n ∷ Int]]
    sourceAuthoredRuns <$> mkSource defaultSourceLimits base {specMaterials = names 4095} `shouldBe` Right 0
    refusal base {specMaterials = names 4096} `shouldBe` Just (TooManyMaterials 4095)
  it "refuses a layer or patch naming an undeclared material" $ do
    refusal (withLayers [layer 0 1 "zzz" 0]) `shouldBe` Just (UnknownMaterial (LayerRecord 0) "zzz")
    refusal (withPatches [patchAir 0 0 0 1, patchSolid 0 0 5 6 "zzz" 0]) `shouldBe` Just (UnknownMaterial (PatchRecord 1) "zzz")
  it "refuses an invalid identifier named by a layer rather than passing it through" $
    refusal (withLayers [layer 0 1 "" 0]) `shouldBe` Just (UnknownMaterial (LayerRecord 0) "")
  it "refuses a shape outside 0..15, and keeps all sixteen" $ do
    refusal (withLayers [layer 0 1 "a" 16]) `shouldBe` Just (InvalidShape (LayerRecord 0) 16)
    refusal (withLayers [layer 0 1 "a" (-1)]) `shouldBe` Just (InvalidShape (LayerRecord 0) (-1))
    refusal (withPatches [patchSolid 0 0 0 1 "a" 99]) `shouldBe` Just (InvalidShape (PatchRecord 0) 99)
    let source = mustSource (withLayers [layer (toInteger i) (toInteger i + 1) "a" i | i ← [0 .. 15]])
    [fromCell (cellAt source emptyChanges (mustTile 0 0 (toInteger i))) | i ← [0 .. 15 ∷ Int]]
      `shouldBe` [Just ("a", i) | i ← [0 .. 15]]
  where
    isRight = either (const False) (const True)

layerSpec ∷ Spec
layerSpec = describe "layers" $ do
  it "accepts touching layers and refuses an overlap" $ do
    mkSource defaultSourceLimits (withLayers [layer 0 5 "a" 0, layer 5 9 "b" 0]) `shouldSatisfy` ok
    refusal (withLayers [layer 0 5 "a" 0, layer 4 9 "b" 0]) `shouldBe` Just (OverlappingLayers 1)
    refusal (withLayers [layer 0 5 "a" 0, layer 0 5 "b" 0]) `shouldBe` Just (OverlappingLayers 1)
  it "refuses a layer that begins before the previous one" $
    refusal (withLayers [layer 5 9 "a" 0, layer 0 2 "b" 0]) `shouldBe` Just (LayersOutOfOrder 1)
  it "refuses empty and inverted intervals" $ do
    refusal (withLayers [layer 3 3 "a" 0]) `shouldBe` Just (InvalidInterval (LayerRecord 0) (EmptyInterval 3 3))
    refusal (withLayers [layer 4 3 "a" 0]) `shouldBe` Just (InvalidInterval (LayerRecord 0) (EmptyInterval 4 3))
  it "treats an omitted lower end as the lowest level and an omitted upper end as one past the highest" $ do
    let source = mustSource (withLayers [softLayer Nothing Nothing "a" 0])
        at z = fromCell (cellAt source emptyChanges (mustTile 0 0 z))
    at lowest `shouldBe` Just ("a", 0)
    at highest `shouldBe` Just ("a", 0)
    at 0 `shouldBe` Just ("a", 0)
  it "keeps the last supported cell, at both limits" $ do
    let at source z = fromCell (cellAt source emptyChanges (mustTile 0 0 z))
        omitted = mustSource (withLayers [softLayer (Just 10) Nothing "a" 0])
        explicit = mustSource (withLayers [layer 10 topEnd "a" 0])
        belowTop = mustSource (withLayers [layer 10 highest "a" 0])
    at omitted highest `shouldBe` Just ("a", 0)
    at explicit highest `shouldBe` Just ("a", 0)
    at belowTop highest `shouldBe` Nothing
    at belowTop (highest - 1) `shouldBe` Just ("a", 0)
  it "tests each endpoint at the exact boundary, one past it and at the lower limit" $ do
    mkSource defaultSourceLimits (withLayers [layer lowest (lowest + 1) "a" 0]) `shouldSatisfy` ok
    mkSource defaultSourceLimits (withLayers [layer highest topEnd "a" 0]) `shouldSatisfy` ok
    refusal (withLayers [layer (lowest - 1) 0 "a" 0]) `shouldBe` Just (InvalidInterval (LayerRecord 0) (LowerOutOfRange (lowest - 1)))
    refusal (withLayers [layer topEnd (topEnd + 1) "a" 0]) `shouldBe` Just (InvalidInterval (LayerRecord 0) (LowerOutOfRange topEnd))
    refusal (withLayers [layer 0 (topEnd + 1) "a" 0]) `shouldBe` Just (InvalidInterval (LayerRecord 0) (UpperOutOfRange (topEnd + 1)))
    refusal (withLayers [layer topEnd topEnd "a" 0]) `shouldBe` Just (InvalidInterval (LayerRecord 0) (LowerOutOfRange topEnd))
    refusal (withLayers [softLayer (Just highest) (Just highest) "a" 0]) `shouldBe` Just (InvalidInterval (LayerRecord 0) (EmptyInterval highest highest))
    refusal (withLayers [softLayer (Just (highest + 1)) Nothing "a" 0]) `shouldBe` Just (InvalidInterval (LayerRecord 0) (LowerOutOfRange topEnd))
    refusal (withLayers [softLayer Nothing (Just lowest) "a" 0]) `shouldBe` Just (InvalidInterval (LayerRecord 0) (EmptyInterval lowest lowest))
  it "validates the whole definition: a late fault leaves no source" $
    refusal (withLayers [layer 0 1 "a" 0, layer 1 2 "b" 0, layer 2 3 "a" 40]) `shouldBe` Just (InvalidShape (LayerRecord 2) 40)
  where
    ok = either (const False) (const True)

patchSpec ∷ Spec
patchSpec = describe "patches" $ do
  it "refuses overlapping patches in one column and accepts them in different columns or touching" $ do
    refusal (withPatches [patchAir 1 2 0 5, patchAir 1 2 4 9]) `shouldBe` Just (OverlappingPatches 1)
    refusal (withPatches [patchAir 1 2 0 5, patchSolid 1 2 4 5 "a" 0]) `shouldBe` Just (OverlappingPatches 1)
    refusal (withPatches [patchAir 1 2 4 9, patchAir 1 2 0 5]) `shouldBe` Just (OverlappingPatches 1)
    refusal (withPatches [patchAir 1 2 0 5, patchAir 2 1 0 5, patchAir 1 2 5 9]) `shouldBe` Nothing
    refusal (withPatches [patchAir 1 2 0 5, patchAir 1 2 0 5]) `shouldBe` Just (OverlappingPatches 1)
  it "refuses a coordinate outside the supported range, on each axis" $ do
    refusal (withPatches [patchAir (highest + 1) 0 0 1]) `shouldBe` Just (InvalidPatchCoordinate 0 (AxisOutOfRange (highest + 1)))
    refusal (withPatches [patchAir 0 (lowest - 1) 0 1]) `shouldBe` Just (InvalidPatchCoordinate 0 (AxisOutOfRange (lowest - 1)))
    refusal (withPatches [patchAir highest lowest 0 1]) `shouldBe` Nothing
  it "tests the patch interval at the exact boundary, one past it and at the lower limit" $ do
    refusal (withPatches [patchAir 0 0 highest topEnd]) `shouldBe` Nothing
    refusal (withPatches [patchAir 0 0 lowest (lowest + 1)]) `shouldBe` Nothing
    refusal (withPatches [patchAir 0 0 0 (topEnd + 1)]) `shouldBe` Just (InvalidInterval (PatchRecord 0) (UpperOutOfRange (topEnd + 1)))
    refusal (withPatches [patchAir 0 0 (lowest - 1) 0]) `shouldBe` Just (InvalidInterval (PatchRecord 0) (LowerOutOfRange (lowest - 1)))
    refusal (withPatches [patchAir 0 0 topEnd topEnd]) `shouldBe` Just (InvalidInterval (PatchRecord 0) (LowerOutOfRange topEnd))
    refusal (withPatches [patchAir 0 0 7 7]) `shouldBe` Just (InvalidInterval (PatchRecord 0) (EmptyInterval 7 7))
    refusal (withPatches [patchAir 0 0 8 7]) `shouldBe` Just (InvalidInterval (PatchRecord 0) (EmptyInterval 8 7))
  it "reaches the last supported cell with a patch, and overrides the base only where it covers" $ do
    let source = mustSource (withPatches [patchSolid 0 0 highest topEnd "a" 7])
        at x z = fromCell (cellAt source emptyChanges (mustTile x 0 z))
    at 0 highest `shouldBe` Just ("a", 7)
    at 0 (highest - 1) `shouldBe` Nothing
    at 1 highest `shouldBe` Nothing
  it "lets an air patch open a cavity in a layer and a solid patch fill the air" $ do
    let source =
          mustSource
            base
              { specLayers = [layer (-10) 0 "a" 0]
              , specPatches = [patchAir 2 2 (-6) (-2), patchSolid 2 2 5 8 "b" 3]
              }
        at z = fromCell (cellAt source emptyChanges (mustTile 2 2 z))
    [at z | z ← [-7, -6, -3, -2, -1]] `shouldBe` [Just ("a", 0), Nothing, Nothing, Just ("a", 0), Just ("a", 0)]
    [at z | z ← [4, 5, 7, 8]] `shouldBe` [Nothing, Just ("b", 3), Just ("b", 3), Nothing]
    fromCell (cellAt source emptyChanges (mustTile 3 2 (-4))) `shouldBe` Just ("a", 0)

limitSpec ∷ Spec
limitSpec = describe "definition bounds" $ do
  it "states the approved initial limits" $
    defaultSourceLimits `shouldBe` SourceLimits {limitDefinitionBytes = 262144, limitAuthoredRuns = 8192}
  it "accepts exactly 8,192 authored runs and refuses 8,193" $ do
    let layers n = [layer (toInteger i) (toInteger i + 1) "a" 0 | i ← [0 .. (n ∷ Int) - 1]]
    sourceAuthoredRuns <$> mkSource defaultSourceLimits (withLayers (layers 8192)) `shouldBe` Right 8192
    refusal (withLayers (layers 8193)) `shouldBe` Just (TooManyAuthoredRuns 8192)
  it "counts layers and patches together toward the runs" $ do
    -- 8,000 layers and 192 patches are 199,680 accounted bytes plus the fixed
    -- charges: the run bound, not the byte bound, is what decides.
    let layers = [layer (toInteger i) (toInteger i + 1) "a" 0 | i ← [0 .. 7999 ∷ Int]]
        patches n = [patchAir (toInteger i) 0 0 1 | i ← [0 .. (n ∷ Int) - 1]]
    sourceAuthoredRuns <$> mkSource defaultSourceLimits base {specLayers = layers, specPatches = patches 192} `shouldBe` Right 8192
    refusal base {specLayers = layers, specPatches = patches 193} `shouldBe` Just (TooManyAuthoredRuns 8192)
  it "accepts exactly 262,144 accounted bytes and refuses one more" $ do
    -- 64 header + (16 + 24) one material + 6,551 patches * 40 = 262,144.
    let patches = [patchAir (toInteger i) 0 0 1 | i ← [0 .. 6550 ∷ Int]]
        named n = base {specMaterials = [replicate n 'm'], specLayers = [], specPatches = patches}
    sourceDefinitionBytes <$> mkSource defaultSourceLimits (named 24) `shouldBe` Right 262144
    refusal (named 25) `shouldBe` Just (DefinitionTooLarge 262145 262144)
  it "decides the byte bound for any caller-supplied limit, at and one past the total" $ do
    let definition = soilOverStone {specPatches = [patchAir 0 0 0 1]}
        total = sourceDefinitionBytes (mustSource definition)
    mkSource defaultSourceLimits {limitDefinitionBytes = total} definition `shouldSatisfy` either (const False) (const True)
    mkSource defaultSourceLimits {limitDefinitionBytes = total - 1} definition
      `shouldBe` Left (DefinitionTooLarge (toInteger total) (total - 1))
  it "decides the run bound for any caller-supplied limit, at and one past" $ do
    let definition = soilOverStone {specPatches = [patchAir 0 0 0 1]}
    mkSource defaultSourceLimits {limitAuthoredRuns = 3} definition `shouldSatisfy` either (const False) (const True)
    mkSource defaultSourceLimits {limitAuthoredRuns = 2} definition `shouldBe` Left (TooManyAuthoredRuns 2)
  it "lets a run limit of maxBound neither wrap nor bypass the byte limit" $ do
    -- 64 header + (16 + 1) material + 24 layer = 105 accounted bytes.
    let one = SourceSpec ["a"] [layer 0 1 "a" 0] []
        huge = SourceLimits {limitDefinitionBytes = 105, limitAuthoredRuns = maxBound}
    fmap sourceLayerCount (mkSource huge one) `shouldBe` Right 1
    fmap sourceDefinitionBytes (mkSource huge one) `shouldBe` Right 105
    mkSource huge {limitDefinitionBytes = 81} one `shouldBe` Left (DefinitionTooLarge 105 81)
    mkSource huge {limitDefinitionBytes = 104} one `shouldBe` Left (DefinitionTooLarge 105 104)
    fmap sourceLayerCount (mkSource SourceLimits {limitDefinitionBytes = maxBound, limitAuthoredRuns = maxBound} one) `shouldBe` Right 1
    -- A tight byte limit refuses a long list without reading all of it.
    -- The reported total is then the accounted bytes of what was read: at least
    -- the limit, not the full 2,490.
    mkSource huge {limitDefinitionBytes = 1000} (withLayers [layer (toInteger i) (toInteger i + 1) "a" 0 | i ← [0 .. 99 ∷ Int]])
      `shouldSatisfy` either (\e → case e of DefinitionTooLarge total 1000 → total > 1000 && total < 2490; _ → False) (const False)
    mkSource huge {limitDefinitionBytes = 1000} (withLayers [layer (toInteger i) (toInteger i + 1) "a" 0 | i ← [0 ∷ Int ..]])
      `shouldSatisfy` either (\e → case e of DefinitionTooLarge {} → True; _ → False) (const False)
  it "refuses an oversized definition before validating a single record" $ do
    -- The records after the count bound are never reached: a shape fault in the
    -- 10,000th layer is not what is reported.
    let layers = [layer (toInteger i) (toInteger i + 1) "a" 0 | i ← [0 .. 9998 ∷ Int]] <> [layer 9999 10000 "a" 77]
    refusal (withLayers layers) `shouldBe` Just (TooManyAuthoredRuns 8192)
  it "refuses a definition whose list is not finite without traversing it" $ do
    let endless = [layer (toInteger i) (toInteger i + 1) "a" 0 | i ← [0 ∷ Int ..]]
    refusal (withLayers endless) `shouldBe` Just (TooManyAuthoredRuns 8192)
    refusal base {specMaterials = cycle ["x"]} `shouldBe` Just (TooManyMaterials 4095)
    refusal base {specMaterials = [replicate 100000 'z']} `shouldBe` Just (InvalidMaterialId 0 (MaterialIdTooLong 64))
