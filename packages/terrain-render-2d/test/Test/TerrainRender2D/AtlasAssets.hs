-- | TRA-17: the style's assets as checked regions of shared atlas planes, planned and picked.
--
-- The committed packed atlases are loaded the way the runtime loads them ('loadAtlasParents') and
-- adapted to an 'AssetSnapshot'. Every expectation is derived independently of that adaptation:
-- a region's covered texels are the alpha of the independently decoded source image, the
-- packed-versus-single-image comparisons run the same scenes through both snapshots, and the
-- synthetic parents (different sizes, nonzero origins, high-contrast neighbours, transparent
-- padding) state their coverage by formula and the expected pick of every texel by hand.
module Test.TerrainRender2D.AtlasAssets (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import Data.Either (isLeft)
import Data.Word (Word64)
import Hetoimasia.Asset.Image.DataMap (CoveragePlane, NormalEncoding (..), buildBinaryCoverage)
import Hetoimasia.Asset.Image.Region (mkImageRegion, mkRegionView, regionOriginX, regionOriginY, regionViewCoverageAt, regionViewParent, regionViewParentExtent, regionViewRegion)
import Hetoimasia.Terrain.Atlas.Manifest
import Hetoimasia.Terrain.MapBake.Catalog (catalogKeys, mapIdentifier)
import Hetoimasia.Terrain.MapGen.Png (decodeRgba)
import Hetoimasia.Terrain.Render2D.Assets
import Hetoimasia.Terrain.Render2D.AtlasAssets
import Hetoimasia.Terrain.Render2D.CellPick (CellHit (..), CellPickResult (..))
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Test.Hspec
import Test.TerrainRender2D.Art (loadFile)
import Test.TerrainRender2D.CellFixtures

spec ∷ Spec
spec = describe "AtlasAssets" $ do
  recoverySpec
  equivalenceSpec
  syntheticSpec
  refusalSpec

-- | The covered texels of a source image: alpha 255. The source is decoded with JuicyPixels from
-- the repository path the manifest records, never read back through the atlas.
sourceCoverage ∷ FilePath → IO (Int → Int → Bool)
sourceCoverage path = do
  bytes ← loadFile path
  case decodeRgba bytes of
    Right (96, 64, texels) → pure (\x y → ByteString.index texels (4 * (y * 96 + x) + 3) == 255)
    _ → fail (path <> " is not a 96 x 64 RGBA8 PNG")

colourRefs ∷ [(String, ColourRef)]
colourRefs =
  [ ("colour.loam", ColourMaterial stoneId)
  , ("colour.granite", ColourMaterial soilId)
  , ("colour.blanktexture", ColourBlank)
  ]

viewAgrees ∷ (Int → Int → Bool) → (Word → Word → Maybe Bool) → [(Int, Int)]
viewAgrees expected actual = [(x, y) | y ← [0 .. 63], x ← [0 .. 95], actual (fromIntegral x) (fromIntegral y) /= Just (expected x y)]

recoverySpec ∷ Spec
recoverySpec = describe "regions of the committed packed atlases" $ do
  it "cover exactly the texels their independently decoded sources cover, for every colour and map" $ do
    (manifest, _, _) ← loadAtlasParents 3
    assets ← loadAtlasAssets 3
    forM_ colourRefs $ \(identity, ref) → do
      path ← sourceOf' manifest identity
      covered ← sourceCoverage path
      view ← maybe (fail ("no region view for " <> identity)) pure (colourCoverage assets ref)
      (identity, viewAgrees covered (\x y → regionViewCoverageAt view (fromIntegral x) (fromIntegral y))) `shouldBe` (identity, [])
    forM_ catalogKeys $ \key → do
      path ← sourceOf' manifest (mapIdentifier key)
      covered ← sourceCoverage path
      view ← maybe (fail ("no region view for " <> mapIdentifier key)) pure (mapCoverage assets key)
      (mapIdentifier key, viewAgrees covered (\x y → regionViewCoverageAt view (fromIntegral x) (fromIntegral y))) `shouldBe` (mapIdentifier key, [])
  it "share one parent plane per atlas, of different extents, at nonzero origins" $ do
    assets ← loadAtlasAssets 3
    let viewOf key = maybe (fail (mapIdentifier key)) pure (mapCoverage assets key)
        keyOf n = case drop n catalogKeys of
          k : _ → k
          [] → error "catalog"
    blank ← maybe (fail "blank") pure (colourCoverage assets ColourBlank)
    first' ← viewOf (keyOf 0)
    last' ← viewOf (keyOf 45)
    -- The colour parent is 288 x 64 and the normal parent 768 x 384: unequal in both dimensions.
    regionViewParentExtent blank `shouldBe` (288, 64)
    regionViewParentExtent first' `shouldBe` (768, 384)
    -- Every map is a view of the one normal plane, which is held once, not copied per region.
    regionViewParent first' `shouldBe` regionViewParent last'
    -- shape.00 is the first cell of the grid; the last catalog map is at column 5 of row 5.
    (regionOriginX (regionViewRegion first'), regionOriginY (regionViewRegion first')) `shouldBe` (0, 0)
    (regionOriginX (regionViewRegion last'), regionOriginY (regionViewRegion last')) `shouldBe` (480, 320)
    -- The blank colour is the third colour region: origin (192, 0).
    (regionOriginX (regionViewRegion blank), regionOriginY (regionViewRegion blank)) `shouldBe` (192, 0)
  it "gives distinct identities to different style versions of the same regions" $ do
    a ← loadAtlasAssets 3
    b ← loadAtlasAssets 4
    assetIdentity a `shouldSatisfy` (/= assetIdentity b)
    a2 ← loadAtlasAssets 3
    assetIdentity a `shouldBe` assetIdentity a2
  where
    sourceOf' manifest identity = case findRegion manifest identity of
      Just (_, r) → pure (regionSourcePath r)
      Nothing → fail ("the manifest has no " <> identity)

-- ---------------------------------------------------------------------------
-- Packed atlases and single images plan and pick alike

summary ∷ CellQuad → String
summary q = show (quadColour q, quadMap q, quadPart q, quadCell q, rectOf' q)
  where
    rectOf' quad = case quadTarget quad of TargetRect l t r b → (l, t, r, b)

pickSummary ∷ CellPickResult → String
pickSummary (CellPickHit h) = show ("hit", hitCell h, hitPart h)
pickSummary other = show other

equivalenceSpec ∷ Spec
equivalenceSpec = describe "the packed atlases and the single-image files" $ do
  it "plan and pick alike for all 16 identities, four facings and the ordinary, mixed and fog roles" $ do
    packed ← loadAtlasAssets 5
    single ← loadAssets 5
    let roles shape = [KnownAll, Undisc] <> [KnownSolid | shape /= 0]
        scenes = [sceneOf facing 1 [OCell 0 0 0 shape know] | facing ← [FaceSouth, FaceWest, FaceNorth, FaceEast], shape ← [0 .. 15], know ← roles shape]
    length scenes `shouldBe` 4 * (16 * 2 + 15)
    forM_ scenes $ \scene → do
      let planPacked = planScene packed scene
          planSingle = planScene single scene
      map summary (cellPlanQuads planPacked) `shouldBe` map summary (cellPlanQuads planSingle)
      case cellPlanQuads planSingle of
        [] → pure ()
        q : _ → do
          let TargetRect l t _ _ = quadTarget q
              origin = (floor l ∷ Int, floor t ∷ Int)
              points = [(fst origin + x, snd origin + y) | y ← [0, 3 .. 63], x ← [0, 3 .. 95]]
          forM_ points $ \p → pickSummary (pickPixel planPacked p) `shouldBe` pickSummary (pickPixel planSingle p)

-- ---------------------------------------------------------------------------
-- Synthetic parents: other sizes, nonzero origins, neighbours and padding

stoneRegion, blankRegion, soilRegion ∷ (Word, Word)
stoneRegion = (96, 0)
blankRegion = (0, 0)
soilRegion = (192, 0)

-- | A 288 x 64 colour parent: the blank and soil regions fully covered, the stone region (at
-- origin (96, 0)) covered where (i + j) mod 3 is not 0, in its own local coordinates.
colourParentPlane ∷ CoveragePlane
colourParentPlane = planeOf 288 64 $ \x y → x < 96 || x >= 192 || (x - 96 + y) `mod` 3 /= 0

-- | A 768 x 384 normal parent: uncovered everywhere (transparent padding) except the region at
-- origin (192, 128), covered except local columns 40 to 49.
normalParentPlane ∷ CoveragePlane
normalParentPlane = planeOf 768 384 $ \x y → x >= 192 && x < 288 && y >= 128 && y < 192 && not (x - 192 >= 40 && x - 192 < 50)

planeOf ∷ Word → Word → (Word → Word → Bool) → CoveragePlane
planeOf w h covered = either (error . show) id (buildBinaryCoverage (fromIntegral w) (fromIntegral h) bytes)
  where
    bytes = ByteString.pack (concat [[0, 0, 0, if covered x y then 255 else 0] | y ← [0 .. h - 1], x ← [0 .. w - 1]])

syntheticSnapshot ∷ Word64 → (Word, Word) → (Word, Word) → AssetSnapshot
syntheticSnapshot version stone normalOrigin =
  either (error . show) id (mkAssetSnapshot version blank [(stoneId, stoneAsset), (soilId, soilAsset)] maps)
  where
    viewAt plane (x, y) = either (error . show) id (mkImageRegion (fromIntegral x) (fromIntegral y) 96 64 >>= mkRegionView version 11 plane)
    colourAt ref origin = either (error . show) id (mkColourAsset ref version version (viewAt colourParentPlane origin))
    blank = colourAt ColourBlank blankRegion
    stoneAsset = colourAt (ColourMaterial stoneId) stone
    soilAsset = colourAt (ColourMaterial soilId) soilRegion
    maps = [(key, either (error . show) id (mkMapAsset key version version (Just UnitNormalRgbV1) (viewAt normalParentPlane normalOrigin))) | key ← catalogKeys]

syntheticSpec ∷ Spec
syntheticSpec = describe "synthetic parents with nonzero origins, neighbours and transparent padding" $ do
  let oneCell = sceneOf FaceSouth 0 [OCell 0 0 0 0 KnownAll]
      pixelsOf plan = case cellPlanQuads plan of
        [q] → let TargetRect l t r b = quadTarget q in ((floor l, floor t), (r - l, b - t))
        other → error ("expected one quad, found " <> show (length other))
      hits snapshot = do
        let plan = planScene snapshot oneCell
            ((l, t), extent) = pixelsOf plan
        extent `shouldBe` (96, 64)
        pure [(x, y) | y ← [0 .. 63], x ← [0 .. 95], isHitResult (pickPixel plan (l + x, t + y))]
      -- Expected by hand: the stone colour is covered where (i + j) mod 3 /= 0, and the normal
      -- region where local column i is outside 40..49.
      expected = [(x, y) | y ← [0 .. 63], x ← [0 .. 95], (x + y) `mod` 3 /= 0, not (x >= 40 && x < 50)]
  it "picks exactly the texels both regions cover, reading each at its own origin" $ do
    found ← hits (syntheticSnapshot 7 stoneRegion (192, 128))
    found `shouldBe` expected
  it "never reads a neighbour: a mis-added origin is not a hit anywhere it should not be" $ do
    -- The stone region moved to the fully covered blank cell would cover every texel the map
    -- covers; the same scene with the correct origin does not.
    wrong ← hits (syntheticSnapshot 7 blankRegion (192, 128))
    wrong `shouldSatisfy` (/= expected)
    wrong `shouldBe` [(x, y) | y ← [0 .. 63], x ← [0 .. 95], not (x >= 40 && x < 50)]
  it "treats a normal region moved onto transparent padding as covering nothing" $ do
    found ← hits (syntheticSnapshot 7 stoneRegion (0, 0))
    found `shouldBe` []
  it "invalidates a stale identity when only a region's rectangle changes on the same parent" $
    assetIdentity (syntheticSnapshot 7 stoneRegion (192, 128)) `shouldSatisfy` (/= assetIdentity (syntheticSnapshot 7 blankRegion (192, 128)))
  where
    isHitResult (CellPickHit _) = True
    isHitResult _ = False

-- ---------------------------------------------------------------------------
-- Refusals

refusalSpec ∷ Spec
refusalSpec = describe "adapting the loaded atlases refuses an unusable style whole" $ do
  let materials = [(stoneId, "colour.loam"), (soilId, "colour.granite")]
      build manifest colour normal = atlasAssetSnapshot 3 manifest colour normal materials
  it "builds from the committed manifest and both parents" $ do
    (manifest, colour, normal) ← loadAtlasParents 3
    build manifest colour normal `shouldSatisfy` either (const False) (const True)
  it "refuses a parent whose extent is not the manifest's, such as the two parents swapped" $ do
    (manifest, colour, normal) ← loadAtlasParents 3
    -- Swapped, the colour slot holds a parent decoded as data: refused by kind before extent.
    build manifest normal colour `shouldBe` Left (AtlasParentKind "colour" DataParent)
    -- A colour-kind parent with the normal parent's plane has the wrong extent.
    build manifest colour {parentCoverage = parentCoverage normal} normal `shouldBe` Left (AtlasParentExtent "colour" 768 384 288 64)
  it "refuses a parent checked against the wrong numeric profile" $ do
    (manifest, colour, normal) ← loadAtlasParents 3
    build manifest colour normal {parentProfile = Nothing} `shouldBe` Left (AtlasParentProfile "normal" Nothing)
    build manifest colour {parentProfile = Just UnitNormalRgbV1} normal `shouldBe` Left (AtlasParentProfile "colour" (Just UnitNormalRgbV1))
  it "refuses a texture and coverage of different versions, so an old plane is never paired with a new texture" $ do
    (manifest, colour, normal) ← loadAtlasParents 3
    build manifest colour {parentCoverageVersion = 9} normal `shouldSatisfy` isLeft
  it "refuses an invalid manifest and a material naming an absent colour" $ do
    (manifest, colour, normal) ← loadAtlasParents 3
    let dropNormal atlas = if atlasName atlas == normalAtlasName then atlas {atlasRegions = drop 1 (atlasRegions atlas)} else atlas
        broken = manifest {manifestAtlases = map dropNormal (manifestAtlases manifest)}
    build broken colour normal `shouldSatisfy` isLeft
    atlasAssetSnapshot 3 manifest colour normal [(stoneId, "colour.nope")] `shouldBe` Left (AtlasUnknownColour "colour.nope")
  it "changes the style's identity when two regions swap origins on the same parent" $ do
    (manifest, colour, normal) ← loadAtlasParents 3
    let swap atlas
          | atlasName atlas == normalAtlasName = atlas {atlasRegions = map move (atlasRegions atlas)}
          | otherwise = atlas
        a0 = region "shape.00"
        a1 = region "shape.01"
        region identity = case findRegion manifest identity of
          Just (_, r) → r
          Nothing → error identity
        move r
          | regionId r == "shape.00" = r {regionX = regionX a1, regionY = regionY a1}
          | regionId r == "shape.01" = r {regionX = regionX a0, regionY = regionY a0}
          | otherwise = r
        atlases = map swap (manifestAtlases manifest)
        swapped = manifest {manifestAtlases = atlases, manifestLayout = layoutIdentity atlases}
    original ← either (fail . show) pure (build manifest colour normal)
    exchanged ← either (fail . show) pure (build swapped colour normal)
    assetIdentity original `shouldSatisfy` (/= assetIdentity exchanged)
  it "refuses a layout identity that was not recomputed after a rectangle moved" $ do
    (manifest, colour, normal) ← loadAtlasParents 3
    -- mixed.15.fog moves from (480, 320) to the unused grid cell at (576, 320): a rectangle that
    -- fits, overlaps nothing and leaves the stated layout identity stale.
    let move atlas = atlas {atlasRegions = [if regionId r == "mixed.15.fog" then r {regionX = 576} else r | r ← atlasRegions atlas]}
        stale = manifest {manifestAtlases = map (\a → if atlasName a == normalAtlasName then move a else a) (manifestAtlases manifest)}
    case build stale colour normal of
      Left (AtlasManifestInvalid [LayoutMismatch _ _]) → pure ()
      other → expectationFailure ("expected a layout mismatch alone, got " <> show other)
