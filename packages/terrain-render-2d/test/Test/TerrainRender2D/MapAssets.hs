-- | TRA-14: the canonical cutout and unit-normal map assets, proved
-- independently of the code that bakes them.
--
-- The committed PNGs under @samples/ecce-homo/content/textures/facemap/@ are
-- decoded and compared texel by texel with "Test.TerrainRender2D.MapAssets.Reference",
-- which works from the P-9 height table by its own method and states every
-- expected byte by hand. The baker's pure evaluation is compared with it at
-- exact rational boundary points, where the tie rule decides. The generator is
-- driven through its command-line function over temporary directories, and its
-- negative controls change copies, never the committed files.
--
-- This is CPU proof of the assets only. Sampling by the GPU, raster edges,
-- picking, lighting, depth composition and offscreen readback remain TRA-15,
-- TRA-16 and TRA-17.
module Test.TerrainRender2D.MapAssets (spec) where

import Control.Monad (forM, forM_, when)
import qualified Data.ByteString as ByteString
import Data.Char (toUpper)
import Data.List (nub, sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Hetoimasia.Terrain.Geometry (Coverage (..), FaceKind (..), V3 (..), sideCoverage)
import Hetoimasia.Terrain.MapBake.Bake
  ( Facet (..)
  , MapProblem (..)
  , MixedTexel (..)
  , Texel (..)
  , canvasProblems
  , decodeNormal
  , mixedAt
  , opaqueNormalValid
  , ordinaryAt
  )
import Hetoimasia.Terrain.MapBake.Catalog
  ( Lookup (..)
  , MapKey (..)
  , MapRole (..)
  , allLookups
  , catalogBound
  , catalogKeys
  , lookupFor
  , mapFileName
  , mapIdentifier
  )
import Hetoimasia.Terrain.MapGen.Cli (Outcome (..), runCli)
import Hetoimasia.Terrain.MapGen.Evidence (JoinedView (..), evidenceFiles, joinedTitleLines, textWidth)
import Hetoimasia.Terrain.MapGen.Generate (Discrepancy (..), compareCatalog, describeDiscrepancy, generate)
import Hetoimasia.Terrain.MapGen.Inputs (loadInputs)
import Hetoimasia.Terrain.MapGen.Png (decodeRgba, encodeRgba)
import Hetoimasia.Terrain.Opening (airOpenings, connectCells, shapeOpenings)
import Hetoimasia.Terrain.Coordinate (tileCoord)
import Hetoimasia.Terrain.Shape
  ( ShapeId
  , Side (..)
  , ViewFacing (..)
  , allShapeIds
  , allViewFacings
  , mkShapeId
  , shapeFromSides
  , shapeIdValue
  , viewShape
  )
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, listDirectory, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.TerrainRender2D.Art (Json (..), field, findUpwards, loadFile, parseJson, sha256Hex, texturesDirectory)
import Test.TerrainRender2D.MapAssets.Reference

-- ---------------------------------------------------------------------------
-- Loading

catalogDirectory ∷ FilePath
catalogDirectory = texturesDirectory </> "facemap"

type Texels = ByteString.ByteString

texel ∷ Texels → Int → Int → (Int, Int, Int, Int)
texel bytes x y = (at 0, at 1, at 2, at 3)
  where
    at c = fromIntegral (ByteString.index bytes (4 * (y * 96 + x) + c))

allTexelCoordinates ∷ [(Int, Int)]
allTexelCoordinates = [(i, j) | j ← [0 .. 63], i ← [0 .. 95]]

decodeTexels ∷ String → ByteString.ByteString → IO Texels
decodeTexels name bytes = case decodeRgba bytes of
  Right (96, 64, texels) → pure texels
  Right (w, h, _) → expectationFailure' (name <> " is " <> show w <> "x" <> show h) >> pure ByteString.empty
  Left why → expectationFailure' (name <> ": " <> why) >> pure ByteString.empty

expectationFailure' ∷ String → IO ()
expectationFailure' = expectationFailure

loadMap ∷ MapKey → IO Texels
loadMap key = loadFile (catalogDirectory </> mapFileName key) >>= decodeTexels (mapFileName key)

loadPlain ∷ FilePath → IO Texels
loadPlain relative = loadFile relative >>= decodeTexels relative

centre ∷ Int → Int → (Rational, Rational)
centre i j = (fromIntegral i + 1 / 2, fromIntegral j + 1 / 2)

shapeNamed ∷ Int → ShapeId
shapeNamed n = either (error . show) id (mkShapeId n)

-- | The reference's frontmost facet at every texel centre, per shape, computed once.
refOrdinaryTables ∷ [Map.Map (Int, Int) (Maybe RefHit)]
refOrdinaryTables =
  [Map.fromList [((i, j), refFrontmost (solidConstraints shape) (centre i j)) | (i, j) ← allTexelCoordinates] | shape ← allShapeIds]

refMixedTables ∷ [Map.Map (Int, Int) RefMixed]
refMixedTables = [Map.fromList [((i, j), refMixed shape (centre i j)) | (i, j) ← allTexelCoordinates] | shape ← allShapeIds]

refOrdinary ∷ ShapeId → Map.Map (Int, Int) (Maybe RefHit)
refOrdinary shape = refOrdinaryTables !! shapeIdValue shape

refMixedAt ∷ ShapeId → Map.Map (Int, Int) RefMixed
refMixedAt shape = refMixedTables !! shapeIdValue shape

bytesOf ∷ RefFacet → (Int, Int, Int, Int)
bytesOf facet = let (r, g, b) = expectedBytes facet in (r, g, b, 255)

clear ∷ (Int, Int, Int, Int)
clear = (0, 0, 0, 0)

-- ---------------------------------------------------------------------------

spec ∷ Spec
spec = describe "TRA-14 canonical cutout and normal-map assets" $ do
  catalogSpec
  beforeAll (forM catalogKeys (\key → (,) key <$> loadMap key)) $ do
    referenceSpec
    mixedSpec
    normalsSpec
  tieSpec
  beforeAll (forM catalogKeys (\key → (,) key <$> loadMap key)) $ do
    joinedSpec
    openingSpec
  samplingSpec
  defectSpec
  generatorSpec
  provenanceSpec

-- ---------------------------------------------------------------------------
-- The catalog and its rotated lookup

-- | One positive quarter turn of a four-bit mask: N→E→S→W→N, written by hand.
turnMask ∷ Int → Int
turnMask b = (b * 2) `mod` 16 + b `div` 8

facingTurnsExpected ∷ ViewFacing → Int
facingTurnsExpected FaceSouth = 0
facingTurnsExpected FaceWest = 3
facingTurnsExpected FaceNorth = 2
facingTurnsExpected FaceEast = 1

expectedView ∷ ViewFacing → Int → Int
expectedView facing world = iterate turnMask world !! facingTurnsExpected facing

two ∷ Int → String
two n = (if n < 10 then "0" else "") <> show n

catalogSpec ∷ Spec
catalogSpec = describe "the catalog and its lookup" $ do
  it "holds exactly the 46 authored maps: 16 ordinary and a known/cover pair for each of the 15 nonflat shapes" $ do
    length catalogKeys `shouldBe` 46
    catalogBound `shouldBe` 46
    length [() | MapKey Ordinary _ ← catalogKeys] `shouldBe` 16
    sort [shapeIdValue s | MapKey KnownPart s ← catalogKeys] `shouldBe` [1 .. 15]
    sort [shapeIdValue s | MapKey FogPart s ← catalogKeys] `shouldBe` [1 .. 15]
    length (nub (map mapIdentifier catalogKeys)) `shouldBe` 46
    length (nub (map mapFileName catalogKeys)) `shouldBe` 46

  it "selects, for every world shape and facing, the catalog entry of the shape turned by the facing's quarter turns" $
    forM_ allViewFacings $ \facing → forM_ [0 .. 15] $ \world → do
      let entry = lookupFor facing (shapeNamed world)
          view = expectedView facing world
      shapeIdValue (lookupView entry) `shouldBe` view
      lookupOrdinary entry `shouldBe` MapKey Ordinary (shapeNamed view)
      lookupFullFog entry `shouldBe` MapKey Ordinary (shapeNamed 0)
      fmap (\(k, f) → (mapIdentifier k, mapIdentifier f)) (lookupMixed entry)
        `shouldBe` (if view == 0 then Nothing else Just ("mixed." <> two view <> ".known", "mixed." <> two view <> ".fog"))

  it "turns the sixteen world identities as a bijection at every facing, and four quarter turns restore each" $ do
    forM_ allViewFacings $ \facing →
      sort [shapeIdValue (lookupView (lookupFor facing (shapeNamed w))) | w ← [0 .. 15]] `shouldBe` [0 .. 15]
    forM_ [0 .. 15] $ \world → do
      iterate turnMask world !! 4 `shouldBe` world
      -- East is one turn and West three: selecting through one after the other is the identity.
      let east = shapeIdValue (viewShape FaceEast (shapeNamed world))
      shapeIdValue (viewShape FaceWest (shapeNamed east)) `shouldBe` world
    length allLookups `shouldBe` 64

  it "keeps identities 0 and 15 fixed under every facing and distinct from each other" $
    forM_ allViewFacings $ \facing → do
      shapeIdValue (lookupView (lookupFor facing (shapeNamed 0))) `shouldBe` 0
      shapeIdValue (lookupView (lookupFor facing (shapeNamed 15))) `shouldBe` 15
      lookupOrdinary (lookupFor facing (shapeNamed 15)) `shouldNotBe` lookupOrdinary (lookupFor facing (shapeNamed 0))

-- ---------------------------------------------------------------------------
-- Every committed map against the independent reference

type Loaded = [(MapKey, Texels)]

mapOf ∷ Loaded → MapRole → Int → Texels
mapOf loaded role shape = fromMaybe ByteString.empty (lookup (MapKey role (shapeNamed shape)) loaded)

referenceSpec ∷ SpecWith Loaded
referenceSpec = describe "the committed maps against the independent reference" $ do
  it "are 96 x 64 RGBA8 canvases whose every texel has binary alpha and, where opaque, a profile-valid normal" $ \loaded →
    forM_ loaded $ \(key, texels) → do
      ByteString.length texels `shouldBe` 4 * 96 * 64
      [ (key, i, j, a)
        | (i, j) ← allTexelCoordinates
        , let (r, g, b, a) = texel texels i j
        , a `notElem` [0, 255] || (a == 255 && not (opaqueNormalValid (fromIntegral r, fromIntegral g, fromIntegral b)))
        ]
        `shouldBe` []
      canvasProblems texels `shouldBe` []

  it "match, at every texel of every ordinary map, the frontmost facet the reference finds and its hand-stated normal bytes" $ \loaded →
    forM_ [0 .. 15] $ \shape → do
      let texels = mapOf loaded Ordinary shape
          table = refOrdinary (shapeNamed shape)
          mismatches =
            [ (shape, i, j, texel texels i j, expected)
            | (i, j) ← allTexelCoordinates
            , let expected = maybe clear (bytesOf . refFacet) (fromMaybe Nothing (Map.lookup (i, j) table))
            , texel texels i j /= expected
            ]
      take 3 mismatches `shouldBe` []

  it "have no texel centre on a facet, ridge, wall or silhouette edge: every ray strictly misses or crosses one facet's interior" $ \_ →
    forM_ [0 .. 15] $ \shape →
      forM_ (Map.toList (refOrdinary (shapeNamed shape))) $ \((i, j), hit) →
        case hit of
          Nothing → pure ()
          Just h → do
            (shape, i, j, refTight h) `shouldBe` (shape, i, j, 1)
            fst (refSpan h) < snd (refSpan h) `shouldBe` True

  it "draw ID 15 as the four-faced half-height peak, not the old flat alias" $ \loaded → do
    let peak = mapOf loaded Ordinary 15
        flat = mapOf loaded Ordinary 0
        colours t = sort (nub [(r, g, b) | (i, j) ← allTexelCoordinates, let (r, g, b, a) = texel t i j, a == 255])
    colours peak `shouldBe` sort [(128, 38, 218), (218, 128, 218), (128, 218, 218), (38, 128, 218)]
    peak `shouldNotBe` flat
    -- The opaque area is the cube's hexagon less the walls: the peak's silhouette is the diamond.
    length [() | (i, j) ← allTexelCoordinates, let (_, _, _, a) = texel peak i j, a == 255] `shouldSatisfy` (< length [() | (i, j) ← allTexelCoordinates, let (_, _, _, a) = texel flat i j, a == 255])

-- ---------------------------------------------------------------------------
-- The mixed pairs

mixedSpec ∷ SpecWith Loaded
mixedSpec = describe "the mixed known-solid and cover maps" $ do
  it "match the independent reference of the solid-plus-cover cube at every texel" $ \loaded →
    forM_ [1 .. 15] $ \shape → do
      let known = mapOf loaded KnownPart shape
          fog = mapOf loaded FogPart shape
          table = refMixedAt (shapeNamed shape)
          expectKnown (RefKnown f) = bytesOf f
          expectKnown _ = clear
          expectFog (RefFog f) = bytesOf f
          expectFog _ = clear
      take 3 [(shape, i, j) | (i, j) ← allTexelCoordinates, let r = fromMaybe RefClear (Map.lookup (i, j) table), texel known i j /= expectKnown r || texel fog i j /= expectFog r] `shouldBe` []

  it "have disjoint alpha masks whose union is the full-cell cover, identity 0's map, at every texel" $ \loaded → do
    let full = mapOf loaded Ordinary 0
    forM_ [1 .. 15] $ \shape → do
      let known = mapOf loaded KnownPart shape
          fog = mapOf loaded FogPart shape
          alpha t i j = let (_, _, _, a) = texel t i j in a
      [(shape, i, j) | (i, j) ← allTexelCoordinates, alpha known i j == 255, alpha fog i j == 255] `shouldBe` []
      [(shape, i, j) | (i, j) ← allTexelCoordinates, max (alpha known i j) (alpha fog i j) /= alpha full i j] `shouldBe` []

  it "show the known solid only on the camera-facing walls and never through the cover, with the cover's own normals" $ \loaded →
    forM_ [1 .. 15] $ \shape → do
      let known = mapOf loaded KnownPart shape
          fog = mapOf loaded FogPart shape
          ordinary = mapOf loaded Ordinary shape
          wallBytes = [(255, 128, 128), (128, 255, 128)]
          rgb t i j = let (r, g, b, _) = texel t i j in (r, g, b)
      -- Known texels are walls, and the ordinary map shows the same wall there.
      [ (shape, i, j)
        | (i, j) ← allTexelCoordinates
        , let (_, _, _, a) = texel known i j
        , a == 255
        , rgb known i j `notElem` wallBytes || texel known i j /= texel ordinary i j
        ]
        `shouldBe` []
      -- The cover carries only the cube's top and two walls.
      sort (nub [rgb fog i j | (i, j) ← allTexelCoordinates, let (_, _, _, a) = texel fog i j, a == 255])
        `shouldSatisfy` all (`elem` [(128, 128, 255), (255, 128, 128), (128, 255, 128)])

  it "have empty known parts and a cover equal to identity 0 for shapes whose east and south walls are lowered to the base; other shapes show both" $ \loaded → do
    let opaque t = length [() | (i, j) ← allTexelCoordinates, let (_, _, _, a) = texel t i j, a == 255]
    forM_ [6, 7, 14, 15] $ \shape → do
      opaque (mapOf loaded KnownPart shape) `shouldBe` 0
      mapOf loaded FogPart shape `shouldBe` mapOf loaded Ordinary 0
    forM_ ([1 .. 15] `without` [6, 7, 14, 15]) $ \shape → do
      opaque (mapOf loaded KnownPart shape) `shouldSatisfy` (> 0)
      opaque (mapOf loaded FogPart shape) `shouldSatisfy` (> 0)
  where
    without xs ys = [x | x ← xs, x `notElem` ys]

-- ---------------------------------------------------------------------------
-- Normals

normalsSpec ∷ SpecWith Loaded
normalsSpec = describe "the encoded normals" $ do
  it "encode the stated actual orientations: flat-up (128,128,255), the W ramp (38,128,218) decoding to (-1,0,1)/sqrt 2, and the cardinal walls" $ \_ → do
    expectedBytes (RefTop Nothing) `shouldBe` (128, 128, 255)
    expectedBytes (RefTop (Just West)) `shouldBe` (38, 128, 218)
    case decodeNormal (38, 128, 218) of
      Just (x, y, z) → do
        abs (x + sqrt 0.5) < 1e-12 `shouldBe` True
        y `shouldBe` 0
        abs (z - sqrt 0.5) < 1e-12 `shouldBe` True
      Nothing → expectationFailure "the W ramp bytes decode to no vector"
    decodeNormal (128, 128, 128) `shouldBe` Nothing
    -- Every hand-stated byte triple decodes to its facet's exact unit normal, within the quantization of the profile.
    forM_ [RefTop Nothing, RefTop (Just North), RefTop (Just East), RefTop (Just South), RefTop (Just West), RefWall East, RefWall South] $ \facet → do
      let (a, b, c) = refNormal facet
          len = sqrt (fromRational (a * a + b * b + c * c)) ∷ Double
          (r, g, bl) = expectedBytes facet
      case decodeNormal (fromIntegral r, fromIntegral g, fromIntegral bl) of
        Just (x, y, z) → do
          abs (x - fromRational a / len) < 1e-9 `shouldBe` True
          abs (y - fromRational b / len) < 1e-9 `shouldBe` True
          abs (z - fromRational c / len) < 1e-9 `shouldBe` True
        Nothing → expectationFailure ("undecodable " <> show facet)

  it "carry exactly the facets each catalog shape's solid shows, with no averaged or smoothed colour" $ \loaded → do
    let colours shape = sort (nub [(r, g, b) | (i, j) ← allTexelCoordinates, let (r, g, b, a) = texel (mapOf loaded Ordinary shape) i j, a == 255])
        e = (255, 128, 128)
        s = (128, 255, 128)
        up = (128, 128, 255)
        n' = (128, 38, 218)
        e' = (218, 128, 218)
        s' = (128, 218, 218)
        w' = (38, 128, 218)
    colours 0 `shouldBe` sort [up, e, s]
    colours 1 `shouldBe` sort [n', e, s]
    colours 8 `shouldBe` sort [w', e, s]
    colours 5 `shouldBe` sort [n', s', e]
    colours 10 `shouldBe` sort [e', w', s]
    colours 15 `shouldBe` sort [n', e', s', w']

  it "keep the same world-fixed surface under all four facings: back-rotated, the ramp normals of a view are those of the world shape" $ \loaded →
    forM_ allViewFacings $ \facing → forM_ [0 .. 15] $ \world → do
      let entry = lookupFor facing (shapeNamed world)
          view = shapeIdValue (lookupView entry)
          texels = mapOf loaded Ordinary view
          -- Ramp and flat tops carry a positive Z; decode, turn the XY part back, round to the lattice.
          viewTops = nub [(r, g, b) | (i, j) ← allTexelCoordinates, let (r, g, b, a) = texel texels i j, a == 255, b == 218 || b == 255 && r == 128 && g == 128]
          back (r, g, b) =
            let (x, y) = (r - 128, g - 128)
                turnsBack = (4 - facingTurnsExpected facing) `mod` 4
                (x', y') = iterate (\(a, c) → (negate c, a)) (x, y) !! turnsBack
             in (x', y', b - 128)
          expectedWorld =
            sort
              ( if world == 0
                  then [(0, 0, 127)]
                  else [ramp side | (side, mask) ← [(North, 1), (East, 2), (South, 4), (West, 8)], world `div` mask `mod` 2 == 1]
              )
          ramp North = (0, -90, 90)
          ramp East = (90, 0, 90)
          ramp South = (0, 90, 90)
          ramp West = (-90, 0, 90)
      sort (nub (map back viewTops)) `shouldBe` expectedWorld

-- ---------------------------------------------------------------------------
-- The tie rule

sameFacet ∷ Facet → RefFacet → Bool
sameFacet (Facet kind (V3 a b c)) facet = kindOf facet == kind && refNormal facet == (a, b, c)
  where
    kindOf (RefTop _) = TopFace
    kindOf (RefWall side) = WallFace side
    kindOf RefBottom = BottomFace

-- | Canvas positions of the lattice @{0, 1/4, 1/2, 3/4, 1}^3@ of every unit-cell
-- point: vertices, edge and facet midpoints, ridge points and boundary points.
latticeCanvas ∷ [(Rational, Rational)]
latticeCanvas =
  nub
    [ (48 + 48 * (x - y), 16 + 24 * (x + y) - 16 * z)
    | x ← steps
    , y ← steps
    , z ← steps
    ]
  where
    steps = [0, 1 / 4, 1 / 2, 3 / 4, 1]

tieSpec ∷ Spec
tieSpec = describe "the closed-solid shared-edge and facet tie rule" $ do
  it "gives the baker and the independent reference the same facet at every lattice boundary and interior point, for ordinary maps" $
    forM_ allShapeIds $ \shape → do
      let disagreements =
            [ (shapeIdValue shape, point, found, expected)
            | point ← latticeCanvas
            , let found = ordinaryAt shape point
            , let expected = fmap refFacet (refFrontmost (solidConstraints shape) point)
            , not (agrees found expected)
            ]
          agrees Clear Nothing = True
          agrees (Surface facet) (Just ref) = sameFacet facet ref
          agrees _ _ = False
      take 3 disagreements `shouldBe` []
      -- Not vacuous: boundary points where more than one facet is tight, or the line only touches.
      let ties = [() | point ← latticeCanvas, Just hit ← [refFrontmost (solidConstraints shape) point], refTight hit > 1]
      length ties `shouldSatisfy` (> 10)

  it "gives the baker and the independent reference the same known/cover part and facet at every lattice point, for mixed pairs" $
    forM_ (filter ((/= 0) . shapeIdValue) allShapeIds) $ \shape → do
      let disagreements =
            [ (shapeIdValue shape, point, found, expected)
            | point ← latticeCanvas
            , let found = mixedAt shape point
            , let expected = refMixed shape point
            , not (agrees found expected)
            ]
          agrees MixedClear RefClear = True
          agrees (MixedKnown f) (RefKnown r) = sameFacet f r
          agrees (MixedFog f) (RefFog r) = sameFacet f r
          agrees _ _ = False
      take 3 disagreements `shouldBe` []

  it "resolves hand-stated shared edges: a ridge to the first ramp, a ramp/wall edge to the ramp, a touched corner to the first wall" $ do
    let at (x, y, z) = (48 + 48 * (x - y), 16 + 24 * (x + y) - 16 * z) ∷ (Rational, Rational)
        expectFacet shape point facet = do
          fmap refFacet (refFrontmost (solidConstraints (shapeNamed shape)) point) `shouldBe` Just facet
          case ordinaryAt (shapeNamed shape) point of
            Surface found → sameFacet found facet `shouldBe` True
            Clear → expectationFailure "the baker found nothing"
    -- NS: the ridge z = y = 1 - y meets the N and S ramps; the first in canonical order is N.
    expectFacet 5 (at (1 / 2, 1 / 2, 1 / 2)) (RefTop (Just North))
    -- W: z = x meets the east wall at its top edge; a top face precedes a wall.
    expectFacet 8 (at (1, 1 / 2, 1)) (RefTop (Just West))
    -- The cube's nearest bottom corner is touched by the line alone; the walls precede the base, East first.
    expectFacet 0 (at (1, 1, 0)) (RefWall East)
    -- The flat top meets the south wall along an edge: the top.
    expectFacet 0 (at (1 / 2, 1, 1)) (RefTop Nothing)
    -- Mixed W: the solid's wall at (1/2, 1, 1/2) lies on the ramp's edge; the closed solid owns it.
    mixedAt (shapeNamed 8) (at (1 / 2, 1, 1 / 2)) `shouldSatisfy` isKnown
    refMixed (shapeNamed 8) (at (1 / 2, 1, 1 / 2)) `shouldSatisfy` isRefKnown
    -- Just above it, the cover.
    mixedAt (shapeNamed 8) (at (1 / 2, 1, 3 / 4)) `shouldSatisfy` isFog
    refMixed (shapeNamed 8) (at (1 / 2, 1, 3 / 4)) `shouldSatisfy` isRefFog
  where
    isKnown (MixedKnown _) = True
    isKnown _ = False
    isFog (MixedFog _) = True
    isFog _ = False
    isRefKnown (RefKnown _) = True
    isRefKnown _ = False
    isRefFog (RefFog _) = True
    isRefFog _ = False

-- ---------------------------------------------------------------------------
-- Joined cells

-- | A scene of cells at view-frame offsets, each a catalog shape in the view
-- frame at level 0.
type Scene = [((Int, Int), Int)]

-- | The scene's canvas pixels, painted far to near by the exact key
-- @(x + y, x, y)@ with the committed ordinary maps, against the frontmost
-- point of the cells' solids themselves.
paintedAgainstTruth ∷ Loaded → Scene → [((Int, Int), (Int, Int, Int, Int), (Int, Int, Int, Int))]
paintedAgainstTruth loaded scene =
  [ ((u, v), painted, truth)
  | v ← [minV .. maxV]
  , u ← [minU .. maxU]
  , let painted = foldl (paint u v) clear (sortOn key scene)
  , let truth = frontmost u v
  , painted /= truth
  ]
  where
    key ((x, y), _) = (x + y, x, y)
    origin (x, y) = (48 * (x - y), 24 * (x + y))
    minU = minimum [fst (origin p) | (p, _) ← scene]
    maxU = maximum [fst (origin p) + 95 | (p, _) ← scene]
    minV = minimum [snd (origin p) | (p, _) ← scene]
    maxV = maximum [snd (origin p) + 63 | (p, _) ← scene]
    local p u v = (u - fst (origin p), v - snd (origin p))
    inside (i, j) = i >= 0 && i < 96 && j >= 0 && j < 64
    paint u v below (p, shape) =
      let (i, j) = local p u v
          t = texel (mapOf loaded Ordinary shape) i j
       in if inside (i, j) && (\(_, _, _, a) → a == 255) t then t else below
    -- The truth: for each cell whose canvas covers the pixel, the reference's frontmost
    -- point of that cell's solid; the highest height along the shared line is nearest the camera.
    frontmost u v =
      case sortOn (negate . fst)
        [ (z, bytesOf (refFacet h))
        | (p, shape) ← scene
        , let (i, j) = local p u v
        , inside (i, j)
        , Just h ← [fromMaybe Nothing (Map.lookup (i, j) (refOrdinary (shapeNamed shape)))]
        , let (_, _, z) = refPoint h
        ] of
        (_, bytes) : _ → bytes
        [] → clear

joinedSpec ∷ SpecWith Loaded
joinedSpec = describe "joined cells composed by the planner's far-to-near key" $ do
  let scenes ∷ [(String, Scene)]
      scenes =
        [ ("a ramp, a block and a peak side by side", [((0, 0), 8), ((1, 0), 0), ((2, 0), 15), ((0, 1), 1), ((1, 1), 4)])
        , ("opposing ramps and the diagonal ridge forms", [((0, 0), 2), ((1, 0), 8), ((0, 1), 5), ((1, 1), 10), ((2, 1), 3)])
        ]
  forM_ scenes $ \(name, scene) →
    it ("paints " <> name <> " to the same frontmost surface as the solids' own geometry") $ \loaded →
      take 3 (paintedAgainstTruth loaded scene) `shouldBe` []

openingSpec ∷ SpecWith Loaded
openingSpec = describe "the logical catalog's openings and closed controls agree with the maps" $ do
  it "show a camera-facing wall in full exactly where the logical side is closed, and less of it where the side opens to air" $ \loaded → do
    let wallCount t colour = length [() | (i, j) ← allTexelCoordinates, let (r, g, bl, a) = texel t i j, a == 255, (r, g, bl) == colour]
        fullEast = wallCount (mapOf loaded Ordinary 0) (255, 128, 128)
        fullSouth = wallCount (mapOf loaded Ordinary 0) (128, 255, 128)
        tileAt x y z = either (error . show) id (tileCoord x y z)
        b = tileAt 1 0 0
        east = tileAt 2 0 0
        south = tileAt 1 1 0
    forM_ [0 .. 15] $ \shape → do
      let t = mapOf loaded Ordinary shape
          openings = shapeOpenings (shapeNamed shape)
          opensEast = not (null (connectCells b openings east airOpenings))
          opensSouth = not (null (connectCells b openings south airOpenings))
      -- Logical: a side opens to air exactly where its wall coverage is below full.
      opensEast `shouldBe` (sideCoverage (shapeNamed shape) East /= FullCoverage)
      opensSouth `shouldBe` (sideCoverage (shapeNamed shape) South /= FullCoverage)
      -- Visual: the map shows the whole wall only for a closed side.
      (wallCount t (255, 128, 128) == fullEast) `shouldBe` not opensEast
      (wallCount t (128, 255, 128) == fullSouth) `shouldBe` not opensSouth
      -- A side with no wall at all is a lowered edge.
      (wallCount t (255, 128, 128) == 0) `shouldBe` (sideCoverage (shapeNamed shape) East == NoCoverage)
      (wallCount t (128, 255, 128) == 0) `shouldBe` (sideCoverage (shapeNamed shape) South == NoCoverage)

  it "treat the full block as the closed control and the diagonal path through a west ramp as open" $ \loaded → do
    let tileAt x y z = either (error . show) id (tileCoord x y z)
        a = tileAt 0 0 0
        b = tileAt 1 0 0
        c = tileAt 1 1 0
        throughRamp shape = not (null (connectCells a airOpenings b (shapeOpenings shape))) && not (null (connectCells b (shapeOpenings shape) c airOpenings))
    throughRamp (shapeNamed 8) `shouldBe` True
    throughRamp (shapeNamed 0) `shouldBe` False
    -- The closed control's map is the whole cube, with both camera-facing walls in full.
    sort (nub [(r, g, bl) | (i, j) ← allTexelCoordinates, let (r, g, bl, al) = texel (mapOf loaded Ordinary 0) i j, al == 255])
      `shouldBe` [(128, 128, 255), (128, 255, 128), (255, 128, 128)]

-- ---------------------------------------------------------------------------
-- Sampling, and colour against map coverage

-- | The NEUTRAL normalized sampling rule these map-asset examples use for the baked maps: @i = min (w - 1) (floor
-- (clamp u 0 1 * w))@, the asset-level reference (@sampleIndex@). The terrain material and picker sample with the
-- owner's 2026-11-09 Q-13 bias, @+ 1/128@ inside the floor, defined once in
-- "Hetoimasia.Terrain.Render2D.TexelRule"; these examples do not exercise that rule.
texelIndex ∷ Int → Rational → Int
texelIndex size u = min (size - 1) (floor (max 0 (min 1 u) * fromIntegral size))

samplingSpec ∷ Spec
samplingSpec = describe "downstream sampling, colour coverage and the cover colour" $ do
  it "uses nearest, clamp-to-edge selection with the higher index at an interior boundary and the last texel at the outer edge" $ do
    map (texelIndex 96) [0, 1 / 96, 1 / 192, 95 / 96, 1, -1 / 2, 2, 1 / 96 - 1 / 100000] `shouldBe` [0, 1, 0, 95, 95, 0, 95, 0]
    map (texelIndex 64) [0, 1 / 64, 63 / 64, 1, 3] `shouldBe` [0, 1, 63, 63, 63]

  it "multiplies colour alpha by map alpha and keeps a texel at a product of at least one half, which for binary alpha is the AND" $ do
    let survives colourAlpha mapAlpha = (fromIntegral colourAlpha / 255 * fromIntegral mapAlpha / 255 ∷ Double) >= 0.5
    [survives c m | c ← [0, 255 ∷ Int], m ← [0, 255 ∷ Int]] `shouldBe` [False, False, False, True]

  it "keeps colour holes and map holes independent: a synthetic colour hole removes coverage the map keeps, and a map hole removes coverage the colour keeps" $ do
    let mapAlpha = [255, 255, 0, 0] ∷ [Int]
        colourAlpha = [255, 0, 255, 0] ∷ [Int]
        covered = zipWith (\c m → c == 255 && m == 255) colourAlpha mapAlpha
    covered `shouldBe` [True, False, False, False]

  it "leaves the imported loam, granite and blank bytes untouched and has every map inside the loam, so the product equals the cutout (the art is a superset by 96 edge texels)" $ do
    loam ← loadPlain (texturesDirectory </> "loam.png")
    flat ← loadMap (MapKey Ordinary (shapeNamed 0))
    forM_ catalogKeys $ \key → do
      texels ← loadMap key
      [ (key, i, j)
        | (i, j) ← allTexelCoordinates
        , let (_, _, _, m) = texel texels i j
        , let (_, _, _, c) = texel loam i j
        , m == 255 && c /= 255
        ]
        `shouldBe` []
    length [() | (i, j) ← allTexelCoordinates, let (_, _, _, c) = texel loam i j, let (_, _, _, m) = texel flat i j, c == 255, m == 0] `shouldBe` 96

  it "covers every texel assigned to fog with the imported blank's opaque (66,63,64), unresized and unthresholded" $ do
    blankBytes ← loadFile (texturesDirectory </> "blanktexture.png")
    sha256Hex blankBytes `shouldBe` "c747223e0f788c942d1e8699735ac4a26a011599b6442c707b91c29f42f2f90e"
    blank ← decodeTexels "blanktexture.png" blankBytes
    forM_ ([MapKey Ordinary (shapeNamed 0)] <> [MapKey FogPart (shapeNamed n) | n ← [1 .. 15]]) $ \key → do
      texels ← loadMap key
      [ (key, i, j, texel blank i j)
        | (i, j) ← allTexelCoordinates
        , let (_, _, _, m) = texel texels i j
        , m == 255
        , texel blank i j /= (66, 63, 64, 255)
        ]
        `shouldBe` []

  it "preserves raw intermediate normal bytes through the pinned encoder, and refuses the legacy face-weight (0,255,0) as a normal" $ do
    let sample = ByteString.pack (concat (replicate (96 * 64) [38, 128, 218, 255]))
    case decodeRgba (encodeRgba 96 64 sample) of
      Right (96, 64, back) → back `shouldBe` sample
      other → expectationFailure ("the PNG round trip failed: " <> show (fmap (\(w, h, _) → (w, h)) other))
    opaqueNormalValid (0, 255, 0) `shouldBe` False
    legacyE ← loadPlain ("samples/ecce-homo/reference/synarchy-3777d437/facemap/isoface_slope_e.png")
    texel legacyE 48 2 `shouldBe` (0, 255, 0, 255)
    canvasProblems legacyE `shouldSatisfy` (not . null)
    forM_ allShapeIds $ \shape → do
      let name = legacyFile (shapeIdValue shape)
      legacy ← loadPlain ("samples/ecce-homo/reference/synarchy-3777d437/facemap/" <> name)
      canvasProblems legacy `shouldSatisfy` (not . null)

legacyFile ∷ Int → FilePath
legacyFile 0 = "isoface.png"
legacyFile n = "isoface_slope_" <> (["n", "e", "ne", "s", "ns", "es", "nes", "w", "nw", "ew", "new", "sw", "nsw", "esw", "nesw"] !! (n - 1)) <> ".png"

-- ---------------------------------------------------------------------------
-- The reproduced reference defect

defectSpec ∷ Spec
defectSpec = describe "the reproduced reference defect (issue #655's N/E counterexample)" $ do
  it "has the pinned E and N masks, E texel (48,2) opaque face-weight green and N's first opaque rows 39,39,38,38,37,37,36,36" $ do
    eBytes ← loadFile "samples/ecce-homo/reference/synarchy-3777d437/facemap/isoface_slope_e.png"
    nBytes ← loadFile "samples/ecce-homo/reference/synarchy-3777d437/facemap/isoface_slope_n.png"
    sha256Hex eBytes `shouldBe` "b63967d34e447e487a504ddf97b723d4c4f7cd642b1a319f44fe88eb55ab2c1d"
    sha256Hex nBytes `shouldBe` "1e0d2e7e559a004821d3b02150ed650ebfa6360fd77648164010efb9fb3c6310"
    e ← decodeTexels "e" eBytes
    n ← decodeTexels "n" nBytes
    texel e 48 2 `shouldBe` (0, 255, 0, 255)
    [head' [j | j ← [0 .. 63], let (_, _, _, a) = texel n c j, a == 255] | c ← [0 .. 7]] `shouldBe` [39, 39, 38, 38, 37, 37, 36, 36]

  it "has the unit-cell surface E shows at texel (48,2), turned three quarter turns, fall in N's projection [0,6] x [23.5,27] where N is transparent" $ do
    nBytes ← loadFile "samples/ecce-homo/reference/synarchy-3777d437/facemap/isoface_slope_n.png"
    n ← decodeTexels "n" nBytes
    let eShape = shapeFromSides [East]
        samples = [(48 + fromIntegral a / 4, 2 + fromIntegral b / 4) | a ← [0 .. 4 ∷ Int], b ← [0 .. 4 ∷ Int]] ∷ [(Rational, Rational)]
        turnOnce (x, y) = (1 - y, x)
        turnThrice p = turnOnce (turnOnce (turnOnce p))
        project (x, y, z) = (48 + 48 * (x - y), 16 + 24 * (x + y) - 16 * z)
        landed =
          [ project (x', y', z)
          | pos ← samples
          , Just hit ← [refFrontmost (solidConstraints eShape) pos]
          , refFacet hit == RefTop (Just East)
          , let (x, y, z) = refPoint hit
          , let (x', y') = turnThrice (x, y)
          ]
    length landed `shouldBe` 25
    forM_ landed $ \(u, v) → do
      (u >= 0 && u <= 6 && v >= 23.5 && v <= 27) `shouldBe` True
      let (_, _, _, a) = texel n (floor u) (floor v)
      a `shouldBe` 0
  where
    head' xs = case xs of x : _ → x; [] → -1 ∷ Int

-- ---------------------------------------------------------------------------
-- The generator

copyCatalog ∷ FilePath → IO ()
copyCatalog destination = do
  source ← findUpwards catalogDirectory
  createDirectoryIfMissing True destination
  names ← listDirectory source
  forM_ names $ \name → copyFile (source </> name) (destination </> name)

sampleDirectory ∷ IO FilePath
sampleDirectory = findUpwards "samples/ecce-homo"

readAll ∷ FilePath → IO [(FilePath, ByteString.ByteString)]
readAll directory = do
  names ← sort <$> listDirectory directory
  forM names $ \name → (,) name <$> ByteString.readFile (directory </> name)

generatorSpec ∷ Spec
generatorSpec = describe "the generator" $ do
  it "passes its read-only check against the committed catalog without being told where the repository is, and rewrites nothing" $ do
    committed ← findUpwards catalogDirectory
    filesBefore ← readAll committed
    outcome ← runCli ["--check"]
    outcomeExit outcome `shouldBe` 0
    filesAfter ← readAll committed
    filesAfter `shouldBe` filesBefore

  it "regenerates, in two independent temporary runs, identical files that equal the committed catalog byte for byte" $
    withSystemTempDirectory "tra14-a" $ \first → withSystemTempDirectory "tra14-b" $ \second → do
      sample ← sampleDirectory
      one ← runCli ["--output", first, "--sample", sample]
      two' ← runCli ["--output", second, "--sample", sample]
      outcomeExit one `shouldBe` 0
      outcomeExit two' `shouldBe` 0
      a ← readAll first
      b ← readAll second
      a `shouldBe` b
      committed ← findUpwards catalogDirectory >>= readAll
      a `shouldBe` committed
      length a `shouldBe` 47
      -- The reports differ only in the first line, which names each run's own directory.
      drop 1 (outcomeOut one) `shouldBe` drop 1 (outcomeOut two')

  it "writes evidence sheets whose every title line fits inside its canvas, deterministically" $ do
    sample ← sampleDirectory
    loaded ← loadInputs sample
    case loaded of
      Left problems → expectationFailure (unlines problems)
      Right inputs → do
        let files = evidenceFiles inputs
            width name = case lookup name files >>= either (const Nothing) (\(w, _, _) → Just w) . decodeRgba of
              Just w → w
              Nothing → -1
        forM_ [(FaceSouth, "south"), (FaceWest, "west"), (FaceNorth, "north"), (FaceEast, "east")] $ \(facing, name) → do
          forM_ [(NormalsView, "normals"), (ArtView, "art")] $ \(view, suffix) → do
            let titles = joinedTitleLines facing view
                imageWidth = width ("joined-" <> name <> "-" <> suffix <> ".png")
            imageWidth `shouldSatisfy` (>= 16 + maximum (map (textWidth 2) titles))
          width ("comparison-" <> name <> ".png") `shouldSatisfy` (>= 16 + textWidth 2 ("CPU GENERATED IMAGE EVIDENCE - NOT AN ENGINE SCREENSHOT - FACING " <> map toUpper name <> " - terrain-mapgen/1"))
        map fst files `shouldSatisfy` ("evidence-index.json" `elem`)
        evidenceFiles inputs `shouldBe` files

  it "refuses usage it cannot satisfy: no mode, two modes and an unknown argument" $ do
    outcomeExit <$> runCli [] >>= (`shouldBe` 2)
    outcomeExit <$> runCli ["--check", "--output", "x"] >>= (`shouldBe` 2)
    outcomeExit <$> runCli ["--frobnicate"] >>= (`shouldBe` 2)

  it "detects, by identity and path and without rewriting, a changed map, a missing map, an unexpected file and a changed manifest entry" $
    withSystemTempDirectory "tra14-check" $ \directory → do
      sample ← sampleDirectory
      copyCatalog directory
      -- A changed map: one shape's PNG swapped for another's.
      swapped ← ByteString.readFile (directory </> "shape_03_ne.png")
      ByteString.writeFile (directory </> "shape_05_ns.png") swapped
      -- A missing map.
      removeFile (directory </> "shape_09_nw.png")
      -- An unexpected file.
      ByteString.writeFile (directory </> "shape_99_extra.png") (ByteString.pack [1, 2, 3])
      -- A changed manifest entry.
      manifest ← ByteString.readFile (directory </> "manifest.json")
      ByteString.writeFile (directory </> "manifest.json") (replaceBytes "\"id\": \"shape.03\"" "\"id\": \"shape.33\"" manifest)
      filesBefore ← readAll directory
      outcome ← runCli ["--check", "--catalog", directory, "--sample", sample]
      outcomeExit outcome `shouldBe` 1
      let report = unlines (outcomeErr outcome)
      report `shouldContain` "changed: shape_05_ns.png"
      report `shouldContain` "missing: shape_09_nw.png"
      report `shouldContain` "unexpected: shape_99_extra.png"
      report `shouldContain` "changed: manifest.json"
      report `shouldContain` "shape.33"
      filesAfter ← readAll directory
      filesAfter `shouldBe` filesBefore

  it "reports an invalid alpha, an invalid normal and a wrong length as problems, and a changed texel as a changed file" $
    withSystemTempDirectory "tra14-fixture" $ \directory → do
      sample ← sampleDirectory
      copyCatalog directory
      good ← loadMap (MapKey Ordinary (shapeNamed 8))
      let at i j = 4 * (j * 96 + i)
          setTexel i j rgba = ByteString.concat [ByteString.take (at i j) good, ByteString.pack rgba, ByteString.drop (at i j + 4) good]
          -- (50, 40) is opaque in the W map.
          zeroChannel = setTexel 50 40 [0, 128, 218, 255]
          halfAlpha = setTexel 50 40 [38, 128, 218, 128]
          zeroVector = setTexel 50 40 [128, 128, 128, 255]
      canvasProblems good `shouldBe` []
      canvasProblems zeroChannel `shouldBe` [InvalidNormal 50 40 (0, 128, 218)]
      canvasProblems halfAlpha `shouldBe` [NonBinaryAlpha 50 40 128]
      canvasProblems zeroVector `shouldSatisfy` (not . null)
      canvasProblems (ByteString.drop 4 good) `shouldBe` [WrongLength (4 * 96 * 64 - 4)]
      -- A transparent texel's RGB is ignored.
      canvasProblems (setTexel 0 0 [9, 9, 9, 0]) `shouldBe` []
      -- The same fixture as a committed file is a changed file.
      ByteString.writeFile (directory </> "shape_08_w.png") (encodeRgba 96 64 zeroChannel)
      outcome ← runCli ["--check", "--catalog", directory, "--sample", sample]
      outcomeExit outcome `shouldBe` 1
      unlines (outcomeErr outcome) `shouldContain` "changed: shape_08_w.png"

  it "refuses an input that is missing or has another hash, naming it, and writes nothing" $
    withSystemTempDirectory "tra14-inputs" $ \directory → do
      outcome ← runCli ["--check", "--sample", directory]
      outcomeExit outcome `shouldBe` 1
      unlines (outcomeErr outcome) `shouldContain` "missing input"
      sample ← sampleDirectory
      copyTree sample directory
      removeFile (directory </> "content" </> "textures" </> "blanktexture.png")
      ByteString.writeFile (directory </> "content" </> "textures" </> "loam.png") (ByteString.pack [0])
      second ← runCli ["--check", "--sample", directory]
      outcomeExit second `shouldBe` 1
      unlines (outcomeErr second) `shouldContain` "blanktexture.png"
      unlines (outcomeErr second) `shouldContain` "loam.png has SHA-256"
      loaded ← loadInputs directory
      either length (const 0) loaded `shouldBe` 2

  it "compares file sets by name: a regenerated set and itself differ nowhere, and any one change is exactly one discrepancy" $ do
    sample ← sampleDirectory
    loaded ← loadInputs sample
    case loaded of
      Left problems → expectationFailure (unlines problems)
      Right inputs → do
        let files = generate inputs
        compareCatalog files files `shouldBe` []
        let changed = [(n, if n == "shape_00_flat.png" then ByteString.pack [0] else b) | (n, b) ← files]
        map describeDiscrepancy (compareCatalog files changed) `shouldSatisfy` all (\d → "shape_00_flat.png" `isInfixOf'` d)
        compareCatalog files (drop 1 files) `shouldSatisfy` (\ds → length ds == 1 && all isMissing ds)
  where
    isMissing (Missing _) = True
    isMissing _ = False

isInfixOf' ∷ String → String → Bool
isInfixOf' needle haystack = any (\n → take (length needle) (drop n haystack) == needle) [0 .. length haystack - length needle]

replaceBytes ∷ String → String → ByteString.ByteString → ByteString.ByteString
replaceBytes from to bytes = ByteString.pack (map (fromIntegral . fromEnum) (go (map (toEnum . fromIntegral) (ByteString.unpack bytes))))
  where
    go [] = []
    go text@(c : rest)
      | take (length from) text == from = to <> go (drop (length from) text)
      | otherwise = c : go rest

copyTree ∷ FilePath → FilePath → IO ()
copyTree source destination = do
  createDirectoryIfMissing True destination
  names ← listDirectory source
  forM_ names $ \name → do
    isFile ← doesFileExist (source </> name)
    if isFile then copyFile (source </> name) (destination </> name) else copyTree (source </> name) (destination </> name)

-- ---------------------------------------------------------------------------
-- Provenance and the manifest

provenanceSpec ∷ Spec
provenanceSpec = describe "the manifest and provenance record" $ do
  it "lists every authored map with its dimensions, role, SHA-256 and opaque count, the bound, the profile and the rotated lookup" $ do
    manifest ← loadFile (catalogDirectory </> "manifest.json") >>= parseOrFail
    (field "profile" manifest, field "kind" manifest, field "coverage" manifest) `shouldBe` (Just (JString "unit-normal-rgb-v1"), Just (JString "data"), Just (JString "binary"))
    field "bound" manifest `shouldBe` Just (JNumber 46)
    entries ← case field "maps" manifest of
      Just (JArray es) → pure es
      _ → expectationFailure "no maps" >> pure []
    length entries `shouldBe` 46
    forM_ (zip catalogKeys entries) $ \(key, entry) → do
      bytes ← loadFile (catalogDirectory </> mapFileName key)
      texels ← decodeTexels (mapFileName key) bytes
      field "id" entry `shouldBe` Just (JString (mapIdentifier key))
      field "path" entry `shouldBe` Just (JString (mapFileName key))
      field "sha256" entry `shouldBe` Just (JString (sha256Hex bytes))
      field "width" entry `shouldBe` Just (JNumber 96)
      field "height" entry `shouldBe` Just (JNumber 64)
      field "shape" entry `shouldBe` Just (JNumber (toInteger (shapeIdValue (mapShape key))))
      field "opaqueTexels" entry `shouldBe` Just (JNumber (toInteger (length [() | (i, j) ← allTexelCoordinates, let (_, _, _, a) = texel texels i j, a == 255])))
    lookups ← case field "lookup" manifest of
      Just (JArray ls) → pure ls
      _ → expectationFailure "no lookup" >> pure []
    length lookups `shouldBe` 64
    forM_ (zip [(f, w) | f ← [("south", FaceSouth), ("west", FaceWest), ("north", FaceNorth), ("east", FaceEast)], w ← [0 .. 15 ∷ Int]] lookups) $ \(((name, facing), world), entry) → do
      let view = expectedView facing world
      field "facing" entry `shouldBe` Just (JString name)
      field "world" entry `shouldBe` Just (JNumber (toInteger world))
      field "view" entry `shouldBe` Just (JNumber (toInteger view))
      field "ordinary" entry `shouldBe` Just (JString ("shape." <> two view))
      field "known" entry `shouldBe` (if view == 0 then Nothing else Just (JString ("mixed." <> two view <> ".known")))
      field "fog" entry `shouldBe` (if view == 0 then Nothing else Just (JString ("mixed." <> two view <> ".fog")))
      field "fullFog" entry `shouldBe` Just (JString "shape.00")

  it "groups maps that share bytes, so deduplication never loses an authored identity" $ do
    manifest ← loadFile (catalogDirectory </> "manifest.json") >>= parseOrFail
    digests ← forM catalogKeys $ \key → (\b → (sha256Hex b, mapIdentifier key)) <$> loadFile (catalogDirectory </> mapFileName key)
    let groups = [(d, [i | (d', i) ← digests, d' == d]) | d ← nub (map fst digests), length [() | (d', _) ← digests, d' == d] > 1]
    case field "sharedBytes" manifest of
      Just (JArray listed) →
        sort [(h, [i | JString i ← is]) | l ← listed, Just (JString h) ← [field "sha256" l], Just (JArray is) ← [field "maps" l]] `shouldBe` sort groups
      _ → expectationFailure "no sharedBytes"
    -- The cover of every shape with no known part is the full cover, as one shared group.
    concatMap snd groups `shouldSatisfy` (\ids → all (`elem` ids) ["mixed.06.fog", "mixed.07.fog", "mixed.14.fog", "mixed.15.fog", "shape.00"])

  it "records the unchanged loam and granite, the imported blank, the sixteen reference-only masks and the generated maps, and resolves no reference mask as a normal map" $ do
    provenance ← loadFile (texturesDirectory </> "provenance.json") >>= parseOrFail
    manifestBytes ← loadFile (catalogDirectory </> "manifest.json")
    (field "assets" provenance >>= \a → case a of JArray es → Just (length es); _ → Nothing) `shouldBe` Just 2
    blankEntry ← maybe (expectationFailure "no importedBlank" >> pure (JObject [])) pure (field "importedBlank" provenance)
    field "sha256" blankEntry `shouldBe` Just (JString "c747223e0f788c942d1e8699735ac4a26a011599b6442c707b91c29f42f2f90e")
    field "sourcePath" blankEntry `shouldBe` Just (JString "assets/textures/utility/blanktexture.png")
    masks ← case field "referenceOnlyMasks" provenance >>= field "masks" of
      Just (JArray ms) → pure ms
      _ → expectationFailure "no reference masks" >> pure []
    length masks `shouldBe` 16
    forM_ masks $ \mask → case (field "destination" mask, field "sha256" mask, field "sourcePath" mask) of
      (Just (JString destination), Just (JString digest), Just (JString source)) → do
        bytes ← loadFile destination
        sha256Hex bytes `shouldBe` digest
        ("samples/ecce-homo/reference/" `isInfixOf'` destination) `shouldBe` True
        ("facemap/" `isInfixOf'` source) `shouldBe` True
        -- Reference only: the generated manifest never names it.
        (reverse (takeWhile (/= '/') (reverse destination)) `isInfixOf'` map (toEnum . fromIntegral) (ByteString.unpack manifestBytes)) `shouldBe` False
      other → expectationFailure ("malformed reference mask entry: " <> show other)
    (field "referenceOnlyMasks" provenance >>= field "label") `shouldSatisfy` maybe False (\l → case l of JString s → "not unit-normal-rgb-v1" `isInfixOf'` s; _ → False)
    (field "source" provenance >>= field "revision") `shouldBe` Just (JString "3777d437ea00e1302bf55162ad5693fee4879187")

  it "is 96 x 64 with binary alpha and the pinned opaque RGB, as colour art kept apart from the normal data" $ do
    blank ← loadPlain (texturesDirectory </> "blanktexture.png")
    forM_ allTexelCoordinates $ \(i, j) → do
      let (r, g, b, a) = texel blank i j
      a `elem` [0, 255] `shouldBe` True
      when (a == 255) $ (r, g, b) `shouldBe` (66, 63, 64)
  where
    parseOrFail bytes = either (\e → expectationFailure e >> pure (JObject [])) pure (parseJson bytes)
