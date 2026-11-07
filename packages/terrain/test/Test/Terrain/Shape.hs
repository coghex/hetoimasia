-- | Examples for the 16-shape catalog: identity, names, the mask and exact
-- quarter-turn rotation, including the view-facing selection.
--
-- The expected tables come from "Test.Terrain.Fixtures", which the library
-- neither reads nor writes.
module Test.Terrain.Shape (spec) where

import Control.Monad (forM_)
import Data.List (nub)
import Hetoimasia.Terrain.Shape
import Test.Hspec
import Test.QuickCheck
import Test.Terrain.Fixtures

shape ∷ Int → ShapeId
shape identity = either (error . show) id (mkShapeId identity)

value ∷ ShapeId → Int
value = shapeIdValue

letters ∷ [Side] → String
letters = map letter
  where
    letter North = 'N'
    letter East = 'E'
    letter South = 'S'
    letter West = 'W'

spec ∷ Spec
spec = describe "Shapes" $ do
  identitySpec
  maskSpec
  rotationSpec
  facingSpec

identitySpec ∷ Spec
identitySpec = describe "the catalog" $ do
  it "supports exactly the identities 0 to 15" $
    map (fmap shapeIdValue . mkShapeId) [0 .. 15] `shouldBe` map Right [0 .. 15]
  it "refuses an unsupported identity instead of normalizing it to flat" $ do
    mkShapeId 16 `shouldBe` Left (UnsupportedShapeId 16)
    mkShapeId (-1) `shouldBe` Left (UnsupportedShapeId (-1))
    mkShapeId 255 `shouldBe` Left (UnsupportedShapeId 255)
    mkShapeId 256 `shouldBe` Left (UnsupportedShapeId 256)
    mkShapeId minBound `shouldBe` Left (UnsupportedShapeId minBound)
    mkShapeId maxBound `shouldBe` Left (UnsupportedShapeId maxBound)
  it "lists all sixteen in identity order" $
    map value allShapeIds `shouldBe` [0 .. 15]
  it "names every identity canonically" $
    map shapeName allShapeIds `shouldBe` shapeNameTable
  it "keeps the authored identities 0 and 15 distinct" $ do
    shape 0 `shouldNotBe` shape 15
    shapeName (shape 0) `shouldNotBe` shapeName (shape 15)
    shapeName (shape 15) `shouldBe` "NESW"
  it "keeps NS and EW distinct" $ do
    shape 5 `shouldNotBe` shape 10
    (shapeName (shape 5), shapeName (shape 10)) `shouldBe` ("NS", "EW")
  it "has sixteen distinct identities" $
    length (nub (map value allShapeIds)) `shouldBe` 16

maskSpec ∷ Spec
maskSpec = describe "the mask" $ do
  it "gives North, East, South and West the bits 1, 2, 4 and 8" $
    map sideBit allSides `shouldBe` [1, 2, 4, 8]
  it "orders the sides North, East, South, West" $
    allSides `shouldBe` [North, East, South, West]
  it "names the sides each identity's bits select" $
    map (letters . shapeSides) allShapeIds `shouldBe` shapeSidesTable
  it "builds an identity back from its sides, and ignores the order and repeats given" $ do
    forM_ allShapeIds $ \s → shapeFromSides (shapeSides s) `shouldBe` s
    shapeFromSides [West, North, North] `shouldBe` shape 9
    shapeFromSides [] `shouldBe` shape 0

rotationSpec ∷ Spec
rotationSpec = describe "quarter turns" $ do
  it "turns North to East to South to West to North" $ do
    map (rotateSide (turns 1)) allSides `shouldBe` [East, South, West, North]
    map (rotateSide (turns 2)) allSides `shouldBe` [South, West, North, East]
    map (rotateSide (turns 3)) allSides `shouldBe` [West, North, East, South]
  it "matches the independent table for every identity and every turn" $
    forM_ (zip allShapeIds rotationTable) $ \(s, expected) →
      map (\count → value (rotateShape (turns count) s)) [0 .. 3] `shouldBe` expected
  it "restores the starting shape after four turns" $
    forM_ allShapeIds $ \s → iterate (rotateShape (turns 1)) s !! 4 `shouldBe` s
  it "leaves 0 and 15 fixed and exchanges NS with EW" $ do
    forM_ [0 .. 3] $ \count → do
      rotateShape (turns count) (shape 0) `shouldBe` shape 0
      rotateShape (turns count) (shape 15) `shouldBe` shape 15
    rotateShape (turns 1) (shape 5) `shouldBe` shape 10
    rotateShape (turns 1) (shape 10) `shouldBe` shape 5
    rotateShape (turns 2) (shape 5) `shouldBe` shape 5
  it "normalizes turn counts, including negative ones" $ do
    turns 5 `shouldBe` turns 1
    turns (-1) `shouldBe` turns 3
    turns 4 `shouldBe` turns 0
    turnCount (turns (-7)) `shouldBe` 1
    turnCount (addTurns (turns 3) (turns 2)) `shouldBe` 1
    inverseTurns (turns 1) `shouldBe` turns 3
  it "composes: turning by a then b is turning by their sum" $
    property $ forAll ((,,) <$> choose (0, 15) <*> choose (-9, 9) <*> choose (-9, 9)) $ \(s, p, q) →
      rotateShape (turns q) (rotateShape (turns p) (shape s)) === rotateShape (addTurns (turns p) (turns q)) (shape s)
  it "preserves the number of set bits" $
    forM_ allShapeIds $ \s →
      forM_ [0 .. 3] $ \count →
        length (shapeSides (rotateShape (turns count) s)) `shouldBe` length (shapeSides s)

facingSpec ∷ Spec
facingSpec = describe "view facings" $ do
  it "turns South 0, West 3, North 2 and East 1 positive quarter turns" $
    map (turnCount . facingTurns) allViewFacings `shouldBe` [0, 3, 2, 1]
  it "selects, for every identity, the mask the reference's view mapping selects" $
    forM_ (zip allViewFacings viewTable) $ \(facing, (_, expected)) →
      map (value . viewShape facing) allShapeIds `shouldBe` expected
  it "turns an East mask into North at the West facing, West at North and South at East" $ do
    value (viewShape FaceWest (shape 2)) `shouldBe` 1
    value (viewShape FaceNorth (shape 2)) `shouldBe` 8
    value (viewShape FaceEast (shape 2)) `shouldBe` 4
  it "keeps the world identity: the view selection is undone exactly" $
    forM_ allViewFacings $ \facing →
      forM_ allShapeIds $ \s → worldShape facing (viewShape facing s) `shouldBe` s
  it "selects 0 and 15 at every facing, so their identities survive a view change" $
    forM_ allViewFacings $ \facing → do
      viewShape facing (shape 0) `shouldBe` shape 0
      viewShape facing (shape 15) `shouldBe` shape 15
