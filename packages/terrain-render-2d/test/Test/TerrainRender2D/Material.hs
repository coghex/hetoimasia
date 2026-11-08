-- | The terrain material's pure half (TRA-8): the committed artwork against its
-- provenance, the record layout and packing worked out by hand, the model at
-- hand-stated points, and the adapter's sharing and refusals.
--
-- Every expectation here is stated from the equations of the package README and
-- a cell at the origin of a flat world; none is read from the planner or the model
-- under test.
module Test.TerrainRender2D.Material (spec) where

import Control.Monad (forM_)
import Data.List (sort)
import Data.Word (Word32)
import GHC.Float (castFloatToWord32, castWord32ToFloat)
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Material (MaterialFacts (..), MaterialRecord (..), RecordLayout (..), materialFacts)
import Hetoimasia.Render.TwoD.Material.Backend (materialRef)
import Hetoimasia.Render.TwoD.Oracle.Material (Colour (..), MaterialInput (..), MaterialModel (..), ModelFault (..))
import Hetoimasia.Render.TwoD.Snapshot (Instance (..), Sampler (..))
import Hetoimasia.Terrain.Cell (mkMaterialId)
import Hetoimasia.Terrain.Geometry (FaceKind (..))
import Hetoimasia.Terrain.Render2D.Evidence
import Hetoimasia.Terrain.Render2D.Material
import Hetoimasia.Terrain.Render2D.Plan
import Hetoimasia.Terrain.Shape (Side (..))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.TerrainRender2D.Art

-- | The words of a record as the floats they hold.
floatsOf ∷ [Word32] → [Float]
floatsOf = map castWord32ToFloat

-- | The three faces a lone flat cell at the origin shows, in a view cut at its level.
flatCell ∷ [PlannedFace]
flatCell = either (\e → error (show e)) planFaces (scenePlan ((newScene "flat" [Cell 0 0 0 1 0 "loam"] (96, 80)) {sceneMode = ManualAt 0 0}))

faceOfKind ∷ FaceKind → [PlannedFace] → PlannedFace
faceOfKind kind faces = case [f | f ← faces, faceViewKind f == kind] of
  f : _ → f
  [] → error ("no face of kind " <> show kind)

sheet ∷ ArtSheet
sheet = isoSheet (textureHandle 1 1)

recordOf ∷ PlannedFace → MaterialRecord
recordOf face = either (error . show) id (faceRecord sheet face)

-- | The model's colour at a unit-square point of a record, with a sample that
-- reports the sheet coordinates it was asked for (red the column, green the row).
modelAt ∷ MaterialRecord → (Double, Double) → Either ModelFault Colour
modelAt record point = runMaterialModel terrainModel input
  where
    input =
      MaterialInput
        { materialTexel = Colour 0 0 0 0
        , materialUv = point
        , materialParameter = 0
        , materialRecord = record
        , materialPush = mempty
        , materialSample = \_ (u, v) → Right (Colour u v 0 1)
        , materialSampleScaled = \_ (u, v) _ → Right (Colour u v 0 1)
        }

spec ∷ Spec
spec = describe "Terrain material (TRA-8)" $ do
  artSpec
  recordSpec
  modelSpec
  adapterSpec

-- ---------------------------------------------------------------------------

-- | What the issue states of the approved artwork and the manifest records.
approvedHashes ∷ [(String, String)]
approvedHashes =
  [ ("loam", "f449a06bc3aa76fdf56607c4e4d23ac1cc8c1a67245b8ae5b295dbff621105e1")
  , ("granite", "776a28d3ee45f656ee8f024444c0f2529b4d176da455902e4ac9bfb329d79d1c")
  ]

artSpec ∷ Spec
artSpec = describe "the approved artwork" $ do
  it "matches the hashes recorded for it, byte for byte, and its provenance manifest" $ do
    manifestBytes ← loadFile (texturesDirectory <> "/provenance.json")
    manifest ← either (ioError . userError) pure (parseJson manifestBytes)
    let assets = case field "assets" manifest of
          Just (JArray entries) → entries
          _ → []
    length assets `shouldBe` 2
    forM_ approvedHashes $ \(name, expected) → do
      approved ← loadApproved name
      sha256Hex (approvedBytes approved) `shouldBe` expected
      let entry = [e | e ← assets, field "name" e == Just (JString name)]
      case entry of
        [e] → do
          field "sha256" e `shouldBe` Just (JString expected)
          field "destination" e `shouldBe` Just (JString (approvedPath approved))
          field "sourcePath" e `shouldBe` Just (JString ("assets/textures/world/" <> name <> "/" <> name <> ".png"))
          field "width" e `shouldBe` Just (JNumber (toInteger (decodedWidth (approvedDecoded approved))))
          field "height" e `shouldBe` Just (JNumber (toInteger (decodedHeight (approvedDecoded approved))))
        _ → ioError (userError ("the manifest has no single entry for " <> name))
    (field "source" manifest >>= field "revision") `shouldBe` Just (JString "3777d437ea00e1302bf55162ad5693fee4879187")

  it "is 96 x 64 colour art with binary alpha, so the decoded mark routes it to the cutout path" $
    forM_ (map fst approvedHashes) $ \name → do
      approved ← loadApproved name
      let decoded = approvedDecoded approved
      (decodedWidth decoded, decodedHeight decoded) `shouldBe` (96, 64)
      decodedFormat decoded `shouldBe` TexelRgba8Srgb
      decodedBinaryAlpha decoded `shouldBe` True

  it "is the cube's hexagon: transparent at the three corners it leaves, opaque in its middle" $
    forM_ (map fst approvedHashes) $ \name → do
      approved ← loadApproved name
      let art = artPixelsOf (approvedDecoded approved)
          alphaAt x y = let (_, _, _, a) = artTexel art x y in a
      [alphaAt 0 0, alphaAt 95 0, alphaAt 0 63, alphaAt 95 63, alphaAt 0 20, alphaAt 95 43] `shouldBe` [0, 0, 0, 0, 0, 0]
      [alphaAt 48 0, alphaAt 47 63, alphaAt 0 23, alphaAt 95 40, alphaAt 48 32] `shouldBe` [255, 255, 255, 255, 255]

-- ---------------------------------------------------------------------------

recordSpec ∷ Spec
recordSpec = describe "the record" $ do
  it "has one handle and 23 words, within the renderer's record limits" $ do
    recordLayout `shouldBe` RecordLayout 1 23
    recordWordCount `shouldBe` 23
    maxMaskVertices `shouldBe` 8
    forM_ flatCell $ \face → do
      let MaterialRecord handles ws = recordOf face
      handles `shouldBe` [textureHandle 1 1]
      length ws `shouldBe` recordWordCount

  -- A flat cell at the origin cut at its level: the camera's reference is the
  -- plane z = 1, so the cell's origin projects to (0, -8), the sheet's corner to
  -- (-48, -24) and the three faces' sheet coordinates follow from the equations
  -- sx = 48 (x - y), sy = 24 (x + y) - 16 z.
  it "puts the top's art coordinates at (u - v + 1) / 2 and 3 (u + v) / 8, by hand" $ do
    let MaterialRecord _ ws = recordOf (faceOfKind TopFace flatCell)
    take 6 (floatsOf ws) `shouldBe` [0.5, -0.5, 0.5, 0.375, 0.375, 0]

  it "puts the East wall's art coordinates at 1 - u / 2 and (3 + 3 u + 2 v) / 8, by hand" $ do
    let MaterialRecord _ ws = recordOf (faceOfKind (WallFace East) flatCell)
    take 6 (floatsOf ws) `shouldBe` [-0.5, 0, 1, 0.375, 0.25, 0.375]

  it "puts the South wall's art coordinates at u / 2 and (3 + 3 u + 2 v) / 8, by hand" $ do
    let MaterialRecord _ ws = recordOf (faceOfKind (WallFace South) flatCell)
    take 6 (floatsOf ws) `shouldBe` [0.5, 0, 0, 0.375, 0.25, 0.375]

  it "holds each flat face's mask as the unit square's four corners and zeros after them" $
    forM_ flatCell $ \face → do
      let MaterialRecord _ ws = recordOf face
      case drop 6 ws of
        count : coordinates → do
          count `shouldBe` 4
          sort (pairUp (take (2 * fromIntegral count) (floatsOf coordinates))) `shouldBe` sort [(0, 0), (1, 0), (1, 1), (0, 1)]
          drop (2 * fromIntegral count) coordinates `shouldBe` replicate (16 - 8) 0
        [] → expectationFailure "the record has no vertex count"

  it "is the same for a cell wherever it stands, and differs by material only in its handle" $ do
    let other = either (\e → error (show e)) planFaces (scenePlan ((newScene "moved" [Cell 3 (-2) 0 1 0 "granite"] (96, 80)) {sceneMode = ManualAt 0 0, sceneAnchor = (3, -2)}))
        recordsOf faces = [recordOf face | face ← faces]
    map recordWords (recordsOf other) `shouldBe` map recordWords (recordsOf flatCell)

  -- TRA-13 (D-49): identity 15 is the central half-height peak. It used to share
  -- identity 0's three flat faces; these are the new expectations, not a weakened
  -- compatibility check.
  it "records identity 15 as the four triangular sloping faces of the peak, not the three flat faces of identity 0" $ do
    let facesOf shape = either (\e → error (show e)) planFaces (scenePlan ((newScene "ids" [Cell 0 0 0 1 shape "loam"] (96, 80)) {sceneMode = ManualAt 0 0}))
    map faceShape (facesOf 0) `shouldSatisfy` all (/= faceShape (head' (facesOf 15)))
    length (facesOf 0) `shouldBe` 3
    length (facesOf 15) `shouldBe` 4
    map faceViewKind (facesOf 15) `shouldBe` replicate 4 TopFace
    map recordOf (facesOf 0) `shouldSatisfy` (/= take 3 (map recordOf (facesOf 15)))
    forM_ (facesOf 15) $ \face → do
      let MaterialRecord _ ws = recordOf face
      case drop 6 ws of
        count : _ → count `shouldBe` 3
        [] → expectationFailure "the record has no vertex count"

  it "refuses what it cannot represent, never approximating: a mask of too few or too many vertices" $ do
    let face = faceOfKind TopFace flatCell
    faceRecord sheet face {faceMask = take 2 (faceMask face)} `shouldBe` Left (MaskVertexCount 2)
    faceRecord sheet face {faceMask = take 9 (cycle (faceMask face))} `shouldBe` Left (MaskVertexCount 9)
  where
    head' = \case
      f : _ → f
      [] → error "no face"
    pairUp = \case
      a : b : rest → (a, b) : pairUp rest
      _ → []

-- ---------------------------------------------------------------------------

modelSpec ∷ Spec
modelSpec = describe "the model" $ do
  let top = recordOf (faceOfKind TopFace flatCell)
      east = recordOf (faceOfKind (WallFace East) flatCell)
      south = recordOf (faceOfKind (WallFace South) flatCell)
      sampledAt record point = case modelAt record point of
        Right (Colour u v _ a) → Just (u, v, a)
        _ → Nothing

  it "samples the sheet where the art coordinates say, orientation by orientation" $ do
    -- The centre of each face is a hand-worked point of the hexagon (96 x 64):
    -- the top's centre is (48, 24), the East wall's (72, 44), the South wall's (24, 44).
    sampledAt top (0.5, 0.5) `shouldBe` Just (0.5, 0.375, 1)
    sampledAt east (0.5, 0.5) `shouldBe` Just (0.75, 0.6875, 1)
    sampledAt south (0.5, 0.5) `shouldBe` Just (0.25, 0.6875, 1)

  it "is transparent black outside the mask and an alpha on the cutout threshold within a mask edge's tolerance" $ do
    -- An East wall of the N ramp is the triangle (0, 1), (1, 1), (1, 0) in (u, v):
    -- hand-stated from the solid z <= y at x = 1, with v = 1 - z.
    let triangle = maskRecord [(0, 1), (1, 1), (1, 0)]
        coverage point = case modelAt triangle point of
          Right (Colour _ _ _ a) → Just a
          _ → Nothing
    coverage (0.9, 0.9) `shouldBe` Just 1
    coverage (0.2, 0.2) `shouldBe` Just 0
    coverage (0.5, 0.5) `shouldBe` Just 0.5
    maskCoverage [(0, 1), (1, 1), (1, 0)] (0.8, 0.8) `shouldBe` Inside
    maskCoverage [(0, 1), (1, 1), (1, 0)] (0.2, 0.2) `shouldBe` Outside
    maskCoverage [(0, 1), (1, 1), (1, 0)] (0.5, 0.5) `shouldBe` Boundary
    maskCoverage [(0, 1), (1, 1), (1, 0)] (0.5 + 0.5 * boundaryTolerance, 0.5) `shouldBe` Boundary
    maskCoverage [(0, 1), (1, 1), (1, 0)] (0.5 - 10 * boundaryTolerance, 0.5) `shouldBe` Outside
    maskCoverage [(1, 0), (1, 1), (0, 1)] (0.8, 0.8) `shouldBe` Inside

  it "decides a mask the same for either orientation of its vertices" $ do
    let polygon = [(0.1, 0.1), (0.9, 0.2), (0.7, 0.9), (0.2, 0.8)]
        points = [(x / 10, y / 10) | x ← [0 .. 10], y ← [0 .. 10]]
    map (maskCoverage polygon) points `shouldBe` map (maskCoverage (reverse polygon)) points

  it "draws nothing for a record that does not have the layout" $
    modelAt (MaterialRecord [] []) (0.5, 0.5) `shouldBe` Right (Colour 0 0 0 0)

  it "reports the art's own undecided samples as indeterminate, never as a pass" $ do
    let faulting = runMaterialModel terrainModel input
        input =
          MaterialInput
            { materialTexel = Colour 0 0 0 0
            , materialUv = (0.5, 0.5)
            , materialParameter = 0
            , materialRecord = top
            , materialPush = mempty
            , materialSample = \handle _ → Left (SampleNearTexelBoundary handle)
            , materialSampleScaled = \handle _ _ → Left (SampleNearTexelBoundary handle)
            }
    faulting `shouldBe` Left (SampleNearTexelBoundary (textureHandle 1 1))

-- ---------------------------------------------------------------------------

adapterSpec ∷ Spec
adapterSpec = describe "adapting a plan" $ do
  let loamId = either (error . show) id (mkMaterialId "loam")
      graniteId = either (error . show) id (mkMaterialId "granite")
      style = styleFromList [(loamId, isoSheet (textureHandle 1 1)), (graniteId, isoSheet (textureHandle 2 1))]
      twoCells = either (\e → error (show e)) planFaces (scenePlan ((newScene "two" [Cell 0 0 0 1 0 "loam", Cell 2 (-1) 0 1 0 "granite"] (480, 240)) {sceneMode = ManualAt 0 0}))

  it "shares a record between faces that need an equal one, and gives each material its own" $
    case adaptFaces style twoCells of
      Left refused → expectationFailure (show refused)
      Right adapted → do
        length (adaptedFaces adapted) `shouldBe` length twoCells
        -- Three kinds of face for each of two materials; six faces, six or fewer records, here exactly six.
        length twoCells `shouldBe` 6
        length (adaptedRecords adapted) `shouldBe` 6
        sort (map adaptedParameter (adaptedFaces adapted)) `shouldBe` [0 .. 5]

  it "shares across cells of one material wherever they stand" $ do
    let faces = either (\e → error (show e)) planFaces (scenePlan ((newScene "same" [Cell 0 0 0 1 0 "loam", Cell 2 0 0 1 0 "loam", Cell 0 3 0 1 0 "loam"] (480, 320)) {sceneMode = ManualAt 0 0}))
    fmap (length . adaptedRecords) (adaptFaces style faces) `shouldBe` Right 3
    fmap (length . adaptedFaces) (adaptFaces style faces) `shouldBe` Right 9

  it "refuses a material the style does not name, rather than drawing it with another's art" $ do
    let missing = either (error . show) id (mkMaterialId "lava")
        faces = [f {faceMaterial = missing} | f ← flatCell]
    adaptFaces style faces `shouldBe` Left (NoArt missing)

  it "builds the instance a view draws: the face's quad and depth key, the sheet as its texture, nearest sampling and its record as the parameter word" $
    case adaptFaces style twoCells of
      Left refused → expectationFailure (show refused)
      Right adapted → do
        let reference = materialRef 7 (MaterialFacts True recordLayout 0)
        forM_ (adaptedFaces adapted) $ \entry → do
          let instanceOf = adaptedInstance reference entry
              face = adaptedFace entry
          instanceTransform instanceOf `shouldBe` faceQuad face
          instanceDepthKey instanceOf `shouldBe` faceDepthKey face
          instanceTexture instanceOf `shouldBe` sheetTexture (adaptedSheet entry)
          instanceSampler instanceOf `shouldBe` SamplerNearest
          instanceParameter instanceOf `shouldBe` adaptedParameter entry
          instanceMaterial instanceOf `shouldBe` reference
        materialFacts reference `shouldBe` MaterialFacts True recordLayout 0
        length (adaptedRecords adapted) `shouldBe` 6

-- | A record whose mask is these vertices and whose art map is the identity, for
-- examples of the model's coverage alone.
maskRecord ∷ [(Float, Float)] → MaterialRecord
maskRecord vertices = MaterialRecord [textureHandle 1 1] (map castFloatToWord32 [1, 0, 0, 0, 1, 0] <> [fromIntegral (length vertices)] <> coordinates <> padding)
  where
    coordinates = concat [[castFloatToWord32 x, castFloatToWord32 y] | (x, y) ← vertices]
    padding = replicate (2 * maxMaskVertices - length coordinates) 0
