-- | The committed packed atlases as the evidence and the CPU suites load them (TRA-17).
--
-- One call finds the sample directory above the working directory, parses the region manifest,
-- decodes each parent image once through the bounded PNG decoder (the colour parent as colour, the
-- normal parent as data), and builds, from that one decode, everything the callers need:
-- the shared coverage plane of each parent (through the generic data-map functions, with the
-- normal parent's opaque texels checked against @unit-normal-rgb-v1@), the style's
-- 'AssetSnapshot' and the independently decoded source canvases the hand model reads. The
-- decoded atlas texels are returned too, so the device evidence uploads the same bytes the
-- coverage was built from. It starts no thread and holds no resource; a caller owns what it
-- uploads.
--
-- State, ownership and lifetime: none. A load reads files and returns values.
module Hetoimasia.Terrain.Render2D.AtlasFixtures
  ( AtlasStyle (..)
  , loadAtlasStyle
  , holedStyle
  , holeAt
  , loadSingleImageStyle
  , SingleImages (..)
  , loadSingleImages
  , bindSingleImages
  , boundPackedTextures
  , findSampleDirectory
  , materialIdOf
  ) where

import Control.Monad (forM)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import qualified Data.Text as Text
import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (..))
import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.Asset.Image.DataMap (NormalEncoding (..), buildBinaryCoverage, checkNormalEncoding)
import Hetoimasia.Asset.Image.PngDecode (DecodePolicy (..), PayloadAccount (..), decodeBoundedWith, m1WorkspaceBytes)
import Hetoimasia.Asset.Image.PngPreflight (m1PngLimits, preflightPng)
import Hetoimasia.Terrain.Atlas.Manifest
import Hetoimasia.Terrain.Cell (MaterialId, mkMaterialId)
import Hetoimasia.Terrain.MapGen.Png (decodeRgba)
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Terrain.MapBake.Catalog (catalogKeys, mapIdentifier)
import Hetoimasia.Terrain.Render2D.Assets (AssetSnapshot, ColourRef (..), mkAssetSnapshot, mkColourAsset, mkMapAsset)
import Hetoimasia.Asset.Image.Region (fullImageViewWith)
import Hetoimasia.Terrain.Render2D.Material (AtlasTextures (..), bindColourParent, bindDataParent, packedTextures)
import Hetoimasia.Terrain.Render2D.AtlasAssets (ParentAtlas (..), ParentKind (..), atlasAssetSnapshot, parentContentDigest)
import Hetoimasia.Terrain.Render2D.Evidence (ArtSource (..))
import System.Directory (doesDirectoryExist, getCurrentDirectory)
import System.FilePath (takeDirectory, (</>))

-- | A loaded style of the committed atlases.
data AtlasStyle = AtlasStyle
  { styleManifest ∷ !AtlasManifest
  , styleColour ∷ !ParentAtlas
  , styleNormal ∷ !ParentAtlas
  , styleColourImage ∷ !DecodedImage
  -- ^ The colour parent as the bounded decoder produced it (premultiplied sRGB colour).
  , styleNormalImage ∷ !DecodedImage
  -- ^ The normal parent as decoded data (raw linear bytes).
  , styleNormalAsColour ∷ !DecodedImage
  -- ^ The same file decoded wrongly, as colour (sRGB, premultiplied): the negative control's
  -- wrong colour-versus-data treatment. Never the style's own texture.
  , styleMaterialIds ∷ ![(MaterialId, String)]
  -- ^ The authored materials the style adopted, with their colour region identities.
  , styleAssets ∷ !AssetSnapshot
  , styleArt ∷ !ArtSource
  -- ^ The source canvases, decoded independently of the atlases.
  }

-- | The nearest @samples/ecce-homo@ at or above the working directory.
findSampleDirectory ∷ IO FilePath
findSampleDirectory = getCurrentDirectory >>= go
  where
    go directory = do
      let candidate = directory </> "samples" </> "ecce-homo"
      found ← doesDirectoryExist candidate
      if found
        then pure candidate
        else
          let parent = takeDirectory directory
           in if parent == directory then ioError (userError "no samples/ecce-homo above the working directory") else go parent

-- | The material identity of an authored name.
materialIdOf ∷ String → IO MaterialId
materialIdOf name = either (\e → ioError (userError (show e))) pure (mkMaterialId name)

-- | Load the committed atlases at one parent version, with the listed materials drawn with the
-- listed colour regions (an authored name and a colour identity such as @colour.loam@).
loadAtlasStyle ∷ Word64 → [(String, String)] → IO AtlasStyle
loadAtlasStyle version materials = do
  sample ← findSampleDirectory
  let atlasDirectory = sample </> "content" </> "textures" </> "terrain-atlas"
      repositoryRoot = takeDirectory (takeDirectory sample)
      failWith what why = ioError (userError (what <> ": " <> why))
  manifestBytes ← ByteString.readFile (atlasDirectory </> "manifest.json")
  manifest ← either (failWith "the atlas manifest" . unlines) pure (parseManifest manifestBytes)
  let account = PayloadAccount (\_ n → pure (n <= m1WorkspaceBytes)) (\_ _ → pure ())
      parent file policy profile = do
        let path = atlasDirectory </> file
        bytes ← ByteString.readFile path
        preflighted ← either (failWith file . show) pure (preflightPng m1PngLimits (Asset (AssetId (Text.pack file)) (FromFile path)) bytes)
        image ← decodeBoundedWith policy account preflighted >>= either (failWith file . show) pure
        level ← case decodedLevels image of
          first : _ → pure first
          [] → failWith file "the decode holds no level"
        let (w, h) = (decodedWidth image, decodedHeight image)
        case profile of
          Just encoding → either (failWith file . show) pure (checkNormalEncoding encoding w h level)
          Nothing → pure ()
        plane ← either (failWith file . show) pure (buildBinaryCoverage w h level)
        let kind = case policy of DecodeColour → ColourParent; DecodeData → DataParent
        pure (ParentAtlas version version plane profile kind (parentContentDigest kind (w, h) level) (length (decodedLevels image)), image)
  (colour, colourImage) ← parent "colour.png" DecodeColour Nothing
  (normal, normalImage) ← parent "normal.png" DecodeData (Just UnitNormalRgbV1)
  (_, normalAsColour) ← parent "normal.png" DecodeColour Nothing
  ids ← forM materials $ \(name, regionName) → (\identity → (identity, regionName)) <$> materialIdOf name
  assets ← either (failWith "the atlas assets" . show) pure (atlasAssetSnapshot version manifest colour normal ids)
  -- The source canvases, from the paths the manifest records, decoded on their own.
  let sources = [(regionId r, regionSourcePath r) | a ← manifestAtlases manifest, r ← atlasRegions a]
  canvases ← forM sources $ \(identity, path) → do
    bytes ← ByteString.readFile (repositoryRoot </> path)
    (_, _, texels) ← either (failWith path) pure (decodeRgba bytes)
    pure (identity, texels)
  let table = Map.fromList canvases
      colourNames = [("loam", "colour.loam"), ("granite", "colour.granite"), ("blanktexture", "colour.blanktexture")]
      colourTable = Map.fromList [(name, Map.findWithDefault ByteString.empty identity table) | (name, identity) ← colourNames]
      texelOf canvasTable name x y = case Map.lookup name canvasTable of
        Nothing → (0, 0, 0, 0)
        Just bytes →
          let base = 4 * (y * 96 + x)
              at i = ByteString.index bytes (base + i)
           in (at 0, at 1, at 2, at 3)
  pure
    AtlasStyle
      { styleManifest = manifest
      , styleColour = colour
      , styleNormal = normal
      , styleColourImage = colourImage
      , styleNormalImage = normalImage
      , styleNormalAsColour = normalAsColour
      , styleMaterialIds = ids
      , styleAssets = assets
      , styleArt = ArtSource {artColour = texelOf colourTable, artMap = texelOf table}
      }

-- | The style's two packed parents bound to two registered textures (the colour handle, then the
-- normal handle), through the checked bindings.
boundPackedTextures ∷ AtlasStyle → TextureHandle → TextureHandle → IO AtlasTextures
boundPackedTextures style colourHandle normalHandle = do
  colour ← either (ioError . userError . show) pure (bindColourParent (styleColour style) colourHandle)
  normal ← either (ioError . userError . show) pure (bindDataParent (styleNormal style) normalHandle)
  pure (packedTextures colour normal)

-- | The same terrain as single images: every logical identity is its own full-image parent (one
-- region covering the whole image, so every region has origin (0, 0), extent 96 x 64 and parent
-- extent 96 x 64), each with a distinct coverage version. The images are the source files the
-- manifest records, decoded through the bounded decoder.
data SingleImages = SingleImages
  { singleAssets ∷ !AssetSnapshot
  , singleImages ∷ ![(String, DecodedImage, ParentAtlas)]
  -- ^ Each identity, its decode and the parent it was validated as, in manifest order.
  }

-- | Load the single-image style at one snapshot version.
loadSingleImages ∷ Word64 → [(String, String)] → IO SingleImages
loadSingleImages version materials = do
  sample ← findSampleDirectory
  let atlasDirectory = sample </> "content" </> "textures" </> "terrain-atlas"
      repositoryRoot = takeDirectory (takeDirectory sample)
      failWith what why = ioError (userError (what <> ": " <> why))
      account = PayloadAccount (\_ n → pure (n <= m1WorkspaceBytes)) (\_ _ → pure ())
  manifest ← ByteString.readFile (atlasDirectory </> "manifest.json") >>= either (failWith "the atlas manifest" . unlines) pure . parseManifest
  let sources = [(regionId r, regionSourcePath r) | a ← manifestAtlases manifest, r ← atlasRegions a]
  loaded ← forM (zip [0 ∷ Int ..] sources) $ \(index, (identity, path)) → do
    bytes ← ByteString.readFile (repositoryRoot </> path)
    let isColour = take 7 identity == "colour."
    preflighted ← either (failWith identity . show) pure (preflightPng m1PngLimits (Asset (AssetId (Text.pack identity)) (FromFile path)) bytes)
    image ← decodeBoundedWith (if isColour then DecodeColour else DecodeData) account preflighted >>= either (failWith identity . show) pure
    level ← case decodedLevels image of
      first : _ → pure first
      [] → failWith identity "no level"
    case (isColour, checkNormalEncoding UnitNormalRgbV1 (decodedWidth image) (decodedHeight image) level) of
      (False, Left refusal) → failWith identity (show refusal)
      _ → pure ()
    plane ← either (failWith identity . show) pure (buildBinaryCoverage (decodedWidth image) (decodedHeight image) level)
    let parentVersion = 1000 + fromIntegral index ∷ Word64
        kind = if isColour then ColourParent else DataParent
        parent = ParentAtlas parentVersion parentVersion plane (if isColour then Nothing else Just UnitNormalRgbV1) kind (parentContentDigest kind (decodedWidth image, decodedHeight image) level) 1
    pure (identity, image, parent)
  let table = Map.fromList [(identity, parent) | (identity, _, parent) ← loaded]
      viewOf identity = do
        parent ← maybe (failWith identity "not loaded") pure (Map.lookup identity table)
        view ← either (failWith identity . show) pure (fullImageViewWith (parentContent parent) (parentCoverageVersion parent) (parentCoverage parent))
        pure (parentCoverageVersion parent, view)
      colourAsset ref identity = do
        (v, view) ← viewOf identity
        either (failWith identity . show) pure (mkColourAsset ref v v view)
  blank ← colourAsset ColourBlank "colour.blanktexture"
  coloured ← forM materials $ \(name, regionName) → do
    material ← materialIdOf name
    asset ← colourAsset (ColourMaterial material) regionName
    pure (material, asset)
  maps ← forM catalogKeys $ \key → do
    (v, view) ← viewOf (mapIdentifier key)
    asset ← either (failWith (mapIdentifier key) . show) pure (mkMapAsset key v v (Just UnitNormalRgbV1) view)
    pure (key, asset)
  snapshot ← either (failWith "the single-image assets" . show) pure (mkAssetSnapshot version blank coloured maps)
  pure (SingleImages snapshot loaded)

-- | Bind every single-image parent to the handle it was registered under (by identity).
bindSingleImages ∷ SingleImages → Map.Map String TextureHandle → Either String AtlasTextures
bindSingleImages images handles = do
  bound' ← traverse one (singleImages images)
  pure (AtlasTextures [t | (True, t) ← bound'] [t | (False, t) ← bound'])
  where
    one (identity, _, parent) = do
      handle ← maybe (Left ("no handle for " <> identity)) Right (Map.lookup identity handles)
      let isColour = take 7 identity == "colour."
      texture ← either (Left . show) Right ((if isColour then bindColourParent else bindDataParent) parent handle)
      pure (isColour, texture)

-- | The single-image style with synthetic handles, one distinct handle per image: the snapshot, the
-- textures and the handle each identity was given.
loadSingleImageStyle ∷ Word64 → [(String, String)] → IO (AssetSnapshot, AtlasTextures, Map.Map String TextureHandle)
loadSingleImageStyle version materials = do
  images ← loadSingleImages version materials
  let handles = Map.fromList [(identity, textureHandle (fromIntegral (100 + index)) 1) | (index, (identity, _, _)) ← zip [0 ∷ Int ..] (singleImages images)]
  textures ← either (ioError . userError) pure (bindSingleImages images handles)
  pure (singleAssets images, textures, handles)


-- | Whether the colour texel at this local position of a region is a hole in the holed style: an
-- opaque-looking texel of the colour art made fully transparent, in 8 x 8 blocks, on a pattern that
-- has nothing to do with any shape's map (so colour holes and map holes are independent).
holeAt ∷ Int → Int → Bool
holeAt x y = (x `div` 8 + y `div` 8) `mod` 3 == 0

-- | The same style with transparent holes punched in the colour art of loam and granite: the colour
-- atlas image, its binary coverage plane and content identity, the adopted assets and the
-- independent source art all agree on the holes (a texel is a hole in each, by 'holeAt'). The normal
-- atlas is untouched, so a covered pixel needs the colour texel AND the map texel opaque.
holedStyle ∷ AtlasStyle → Either String AtlasStyle
holedStyle style = do
  level ← case decodedLevels (styleColourImage style) of
    first : _ → Right first
    [] → Left "the colour atlas holds no level"
  let atlasW = fromIntegral (decodedWidth (styleColourImage style)) ∷ Int
      manifest = styleManifest style
      regionOf identity = case findRegion manifest identity of
        Just (_, r) → Right (fromIntegral (regionX r) ∷ Int, fromIntegral (regionY r) ∷ Int, fromIntegral (regionW r) ∷ Int, fromIntegral (regionH r) ∷ Int)
        Nothing → Left ("no region " <> identity)
  regions ← traverse regionOf ["colour.loam", "colour.granite"]
  let holeIndexes =
        [ 4 * ((ry + y) * atlasW + (rx + x)) + c
        | (rx, ry, rw, rh) ← regions
        , y ← [0 .. rh - 1]
        , x ← [0 .. rw - 1]
        , holeAt x y
        , c ← [0 .. 3]
        ]
      holed = ByteString.pack [if i `elem'` marks then 0 else b | (i, b) ← zip [0 ..] (ByteString.unpack level)]
      marks = holeIndexSet holeIndexes
      elem' i set = Map.member i set
      newImage = (styleColourImage style) {decodedLevels = holed : drop 1 (decodedLevels (styleColourImage style))}
      (w, h) = (decodedWidth newImage, decodedHeight newImage)
  plane ← either (Left . show) Right (buildBinaryCoverage w h holed)
  let old = styleColour style
      colour = old {parentCoverage = plane, parentContent = parentContentDigest ColourParent (w, h) holed}
  assets ← either (Left . show) Right (atlasAssetSnapshot (parentTextureVersion old) manifest colour (styleNormal style) (styleMaterialIds style))
  let art = styleArt style
      holedArt name x y = case lookup name [("loam", ()), ("granite", ())] of
        Just () | holeAt x y → (0, 0, 0, 0)
        _ → artColour art name x y
  pure style {styleColour = colour, styleColourImage = newImage, styleAssets = assets, styleArt = art {artColour = holedArt}}
  where
    holeIndexSet = Map.fromList . map (\i → (i, ()))
